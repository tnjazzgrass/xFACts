# ============================================================================
# xFACts Control Center - Platform Monitoring Page
# Location: E:\xFACts-ControlCenter\scripts\routes\PlatformMonitoring.ps1
# Version: Tracked in dbo.System_Metadata (component: ControlCenter.Platform)
# ============================================================================

Add-PodeRoute -Method Get -Path '/platform-monitoring' -Authentication 'ADLogin' -ScriptBlock {

    $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/admin'
    if (-not $access.HasAccess) {
        Write-PodeHtmlResponse -Value (Get-AccessDeniedHtml -DisplayName $access.DisplayName -PageRoute '/admin') -StatusCode 403
        return
    }

    $html = @'

<!DOCTYPE html>
<html>
<head>
    <title>Platform Monitoring - xFACts Control Center</title>
    <link rel="stylesheet" href="/css/platform-monitoring.css">
    <link rel="stylesheet" href="/css/engine-events.css">
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
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
        <a href="/dm-operations" class="nav-link">DM Operations</a>
        <span class="nav-separator">|</span>
        <a href="/departmental/business-services" class="nav-link">Business Services</a>
        <a href="/departmental/business-intelligence" class="nav-link">Business Intelligence</a>
        <a href="/departmental/client-relations" class="nav-link">Client Relations</a>
        <span class="nav-spacer"></span>
        <a href="/admin" class="nav-link nav-admin" title="Administration">&#9881;</a>
    </nav>

    <div class="page-wrap">
        <!-- Header -->
        <div class="header-bar">
            <div class="header-left">
                <h1><a href="docs/pages/cc/controlcenter-cc-platform.html" target="_blank">Platform Monitoring</a></h1>
                <div class="pm-subtitle">Measuring the resource impact of xFACts on the server environment</div>
            </div>
            <div class="header-right">
                <div class="refresh-info">Updated: <span id="last-update">-</span>
                    <button class="page-refresh-btn" onclick="PM.pageRefresh()" title="Refresh all data">&#8635;</button>
                </div>
            </div>
        </div>

        <!-- Connection Error -->
        <div id="connection-error" class="pm-error"></div>

        <!-- Narrative Summary Strip -->
        <div class="pm-narrative" id="narrative-strip">
            <div class="pm-narrative-accent"></div>
            <div class="pm-narrative-text" id="narrative-text">Loading summary...</div>
        </div>

        <!-- Main Content -->
        <div class="pm-content">

            <!-- TOP SECTION -->
            <div class="pm-top-section">
                <!-- Left: Performance frame -->
                <div class="pm-card-frame">
                    <div class="pm-card-frame-title"><span>Platform Performance <span class="pm-info-icon" onclick="PM.showInfo('perf-section')">?</span></span> <span class="refresh-badge-action" title="Refreshes on server or time range selection">&#128260;</span></div>
                    <div class="pm-card-grid">
                        <div class="pm-card"><div class="pm-card-header"><span class="pm-card-title">Active Sessions</span><span class="pm-info-icon" onclick="PM.showInfo('active-sessions')">?</span></div><div class="pm-card-body"><div class="pm-card-val" id="card-sessions">-</div></div></div>
                        <div class="pm-card"><div class="pm-card-header"><span class="pm-card-title">Total Queries</span><span class="pm-info-icon" onclick="PM.showInfo('total-queries')">?</span></div><div class="pm-card-body"><div class="pm-card-val" id="card-queries">-</div></div></div>
                        <div class="pm-card"><div class="pm-card-header"><span class="pm-card-title">Avg Duration (ms)</span><span class="pm-info-icon" onclick="PM.showInfo('avg-duration')">?</span></div><div class="pm-card-body"><div class="pm-card-val" id="card-avg-dur">-</div></div></div>
                        <div class="pm-card alert clickable" onclick="PM.openSlideout('blocking')"><div class="pm-card-header"><span class="pm-card-title">Blocking Events</span><span class="pm-info-icon" onclick="event.stopPropagation(); PM.showInfo('blocking-events')">?</span></div><div class="pm-card-body dual"><div class="pm-card-dual"><div class="pm-card-val" id="card-blocked-by">-</div><div class="pm-card-sublbl">blocked by others</div></div><div class="pm-card-dual-sep"></div><div class="pm-card-dual"><div class="pm-card-val" id="card-caused-by">-</div><div class="pm-card-sublbl">caused by xFACts</div></div></div></div>
                        <div class="pm-card alert clickable" onclick="PM.openSlideout('lrq')"><div class="pm-card-header"><span class="pm-card-title">LRQ Crossovers</span><span class="pm-info-icon" onclick="event.stopPropagation(); PM.showInfo('lrq-crossovers')">?</span></div><div class="pm-card-body"><div class="pm-card-val" id="card-lrq">-</div></div></div>
                        <div class="pm-card alert"><div class="pm-card-header"><span class="pm-card-title">Open Transactions</span><span class="pm-info-icon" onclick="PM.showInfo('open-transactions')">?</span></div><div class="pm-card-body"><div class="pm-card-val" id="card-open-tx">-</div></div></div>
                    </div>
                </div>

                <!-- Center: Hero -->
                <div class="pm-hero-col">
                    <div class="pm-hero-gauge">
                        <canvas id="gauge-chart" width="260" height="260"></canvas>
                        <div class="pm-hero-overlay">
                            <div class="pm-hero-pct" id="gauge-pct">-</div>
                            <div class="pm-hero-label">CPU IMPACT <span class="pm-info-icon hero-info" onclick="PM.showInfo('cpu-impact')">?</span></div>
                        </div>
                    </div>
                    <div class="pm-hero-detail" id="gauge-detail">-</div>
                    <div class="pm-hero-server" id="gauge-server">ALL SERVERS</div>

                    <!-- Mini Gauges as Server Selectors -->
                    <div class="pm-server-selector">
                        <div class="pm-server-all active" id="srv-all" onclick="PM.selectServer('all')">ALL</div>
                        <div class="pm-mini-gauges" id="mini-gauges"></div>
                    </div>
                </div>

                <!-- Right: API frame -->
                <div class="pm-card-frame api-frame">
                    <div class="pm-card-frame-title api-frame-title"><span>Control Center API <span class="pm-info-icon api-info" onclick="PM.showInfo('api-section')">?</span></span> <span class="refresh-badge-action" title="Refreshes on server or time range selection">&#128260;</span></div>
                    <div class="pm-card-grid">
                        <div class="pm-card api"><div class="pm-card-header"><span class="pm-card-title api">API Requests</span><span class="pm-info-icon api-info" onclick="PM.showInfo('api-requests')">?</span></div><div class="pm-card-body"><div class="pm-card-val" id="card-api-reqs">-</div></div></div>
                        <div class="pm-card api"><div class="pm-card-header"><span class="pm-card-title api">API Req/Min</span><span class="pm-info-icon api-info" onclick="PM.showInfo('api-rpm')">?</span></div><div class="pm-card-body"><div class="pm-card-val" id="card-api-rpm">-</div></div></div>
                        <div class="pm-card api"><div class="pm-card-header"><span class="pm-card-title api">API Avg (ms)</span><span class="pm-info-icon api-info" onclick="PM.showInfo('api-avg')">?</span></div><div class="pm-card-body"><div class="pm-card-val" id="card-api-avg">-</div></div></div>
                        <div class="pm-card api"><div class="pm-card-header"><span class="pm-card-title api">API P95 (ms)</span><span class="pm-info-icon api-info" onclick="PM.showInfo('api-p95')">?</span></div><div class="pm-card-body"><div class="pm-card-val" id="card-api-p95">-</div></div></div>
                        <div class="pm-card api clickable" onclick="PM.openSlideout('api-users')"><div class="pm-card-header"><span class="pm-card-title api">API Users</span><span class="pm-info-icon api-info" onclick="event.stopPropagation(); PM.showInfo('api-users')">?</span></div><div class="pm-card-body"><div class="pm-card-val" id="card-api-users">-</div></div></div>
                        <div class="pm-card api clickable" onclick="PM.openSlideout('api-errors')"><div class="pm-card-header"><span class="pm-card-title api">API Errors</span><span class="pm-info-icon api-info" onclick="event.stopPropagation(); PM.showInfo('api-errors')">?</span></div><div class="pm-card-body"><div class="pm-card-val" id="card-api-errors">-</div></div></div>
                    </div>
                </div>
            </div>

            <!-- BOTTOM: 3-column -->
            <div class="pm-bottom-section">
                <div class="pm-col-frame">
                    <div class="section-header"><h3 class="section-title platform-title">Process Breakdown <span class="pm-info-icon" onclick="PM.showInfo('process-breakdown')">?</span></h3><span class="refresh-badge-action" title="Refreshes on server or time range selection">&#128260;</span></div>
                    <div class="pm-table-scroll" id="process-table-wrap"><div class="pm-loading">Loading...</div></div>
                </div>
                <div class="pm-col-frame pm-chart-col">
                    <div class="section-header">
                        <h3 class="section-title">CPU Impact Over Time <span class="pm-info-icon" onclick="PM.showInfo('cpu-trend')">?</span></h3>
                        <div class="section-header-right">
                            <div class="pm-time-controls">
                            <button class="pm-time-btn active" data-range="1h" onclick="PM.setRange('1h')">1h</button>
                            <button class="pm-time-btn" data-range="12h" onclick="PM.setRange('12h')">12h</button>
                            <button class="pm-time-btn" data-range="24h" onclick="PM.setRange('24h')">24h</button>
                            <button class="pm-time-btn" data-range="7d" onclick="PM.setRange('7d')">7d</button>
                            <button class="pm-time-btn" data-range="custom" onclick="PM.openDateModal()">Custom</button>
                            </div>
                            <span class="refresh-badge-action" title="Refreshes on server or time range selection">&#128260;</span>
                        </div>
                    </div>
                    <div class="pm-chart-inner"><canvas id="trend-chart"></canvas></div>
                </div>
                <div class="pm-col-frame">
                    <div class="section-header"><h3 class="section-title api-title">Top API Endpoints <span class="pm-info-icon api-info" onclick="PM.showInfo('api-endpoints')">?</span></h3><span class="refresh-badge-action" title="Refreshes on server or time range selection">&#128260;</span></div>
                    <div class="pm-table-scroll" id="api-table-wrap"><div class="pm-loading">Loading...</div></div>
                </div>
            </div>
        </div>
    </div>

    <!-- Info Modal -->
    <div id="info-modal-overlay" class="pm-modal-overlay" onclick="PM.closeInfo(event)">
        <div class="pm-info-modal">
            <div class="pm-info-modal-header">
                <h3 id="info-modal-title">-</h3>
                <button class="pm-modal-close" onclick="PM.closeInfo()">&times;</button>
            </div>
            <div class="pm-info-modal-body" id="info-modal-body"></div>
        </div>
    </div>

    <!-- Slideout Panel -->
    <div id="slideout-overlay" class="pm-slideout-overlay" onclick="PM.closeSlideout()"></div>
    <div id="slideout-panel" class="pm-slideout">
        <div class="pm-slideout-header">
            <h3 id="slideout-title">-</h3>
            <button class="pm-modal-close" onclick="PM.closeSlideout()">&times;</button>
        </div>
        <div class="pm-slideout-summary" id="slideout-summary"></div>
        <div class="pm-slideout-body" id="slideout-body"></div>
    </div>

    <!-- Date Modal -->
    <div id="date-modal-overlay" class="pm-modal-overlay">
        <div class="pm-modal">
            <div class="pm-modal-header"><h3>Custom Date Range</h3><button class="pm-modal-close" onclick="PM.closeDateModal()">&times;</button></div>
            <div class="pm-modal-body">
                <div class="pm-date-field"><label for="date-from">From</label><input type="date" id="date-from"></div>
                <div class="pm-date-field"><label for="date-to">To</label><input type="date" id="date-to"></div>
            </div>
            <div class="pm-modal-footer">
                <button class="pm-modal-btn cancel" onclick="PM.closeDateModal()">Cancel</button>
                <button class="pm-modal-btn apply" onclick="PM.applyCustomRange()">Apply</button>
            </div>
        </div>
    </div>

    <script src="/js/platform-monitoring.js"></script>
    <script src="/js/engine-events.js"></script>
</body>
</html>
'@
    Write-PodeHtmlResponse -Value $html
}
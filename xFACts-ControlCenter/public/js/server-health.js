/* ============================================================================
   xFACts Control Center - Server Health JavaScript
   Location: E:\xFACts-ControlCenter\public\js\server-health.js
   Version: Tracked in dbo.System_Metadata (component: ServerOps.ServerHealth)
   ============================================================================ */

// ============================================================================
// CONFIGURATION
// ============================================================================

// Engine events — process map for shared WebSocket module (engine-events.js)
var ENGINE_PROCESSES = {
    'Collect-DMVMetrics':      { slug: 'dmv'},
    'Collect-XEEvents':        { slug: 'xe'},
    'Collect-ServerHealth':    { slug: 'disk'},
    'Send-DiskHealthSummary':  { slug: 'disksummary'}
};

// Live polling (Refresh Architecture)
var PAGE_REFRESH_INTERVAL = 5;    // Default; overridden by GlobalConfig on load
var livePollingTimer = null;
var pageLoadDate = new Date().toDateString();

var trendChart = null;
var miniGaugeCharts = {};
var openTransData = [];

// Page hooks for engine-events.js shared module
function onPageResumed() {
    pageRefresh();
}
function onSessionExpired() {
    stopLivePolling();
}

// Thresholds - loaded from GlobalConfig API on init, these are fallback defaults
var thresholds = {
    ple: { warning: 1000, critical: 300, crisis: 100 },
    bufferCache: { warning: 99, critical: 95, crisis: 80 },
    memoryGrants: { warning: 1, critical: 5, crisis: 10 },
    lazyWrites: { warning: 20, critical: 50, crisis: 100 },
    zombies: { warning: 200, critical: 500, crisis: 800 },
    zombieIdleMinutes: 60,
    openTransactions: { warning: 1, critical: 5, crisis: 10 },
    openTransIdleMinutes: 5,
    blockedSessions: { warning: 1, critical: 5, crisis: 10 }
};

// Metric metadata
var metricInfo = {
    ple: {
        title: 'Page Life Expectancy (PLE)',
        desc: 'How long (in seconds) a data page stays in the buffer cache. Higher = better memory.',
        trendable: true, trendMetric: 'ple',
        thresholds: [
            { class: 'healthy', text: 'Healthy: > 1,000 seconds' },
            { class: 'warning', text: 'Warning: 301-1,000 seconds' },
            { class: 'critical', text: 'Critical: 101-300 seconds' },
            { class: 'crisis', text: 'Crisis: <= 100 seconds' }
        ]
    },
    bufferCache: {
        title: 'Buffer Cache Hit Ratio',
        desc: 'Percentage of pages found in memory vs disk. Should be near 100%.',
        trendable: true, trendMetric: 'buffer_cache',
        thresholds: [
            { class: 'healthy', text: 'Healthy: > 99%' },
            { class: 'warning', text: 'Warning: 96-99%' },
            { class: 'critical', text: 'Critical: 81-95%' },
            { class: 'crisis', text: 'Crisis: <= 80%' }
        ]
    },
    memoryGrants: {
        title: 'Memory Grants Pending',
        desc: 'Queries waiting for memory. Should be zero. Click for trend.',
        trendable: true, trendMetric: 'memory_grants',
        thresholds: [
            { class: 'healthy', text: 'Healthy: 0' },
            { class: 'warning', text: 'Warning: 1-4' },
            { class: 'critical', text: 'Critical: 5-9' },
            { class: 'crisis', text: 'Crisis: >= 10' }
        ]
    },
    lazyWrites: {
        title: 'Lazy Writes/sec',
        desc: 'Pages flushed due to memory pressure. High = bad.',
        trendable: false,
        thresholds: [
            { class: 'healthy', text: 'Healthy: < 20/sec' },
            { class: 'warning', text: 'Warning: 20-49/sec' },
            { class: 'critical', text: 'Critical: 50-99/sec' },
            { class: 'crisis', text: 'Crisis: >= 100/sec' }
        ]
    },
    connections: { 
        title: 'Active Connections', 
        desc: 'Total user sessions connected. Click for trend.', 
        trendable: true, trendMetric: 'connections',
        thresholds: [] 
    },
    jdbcConnections: { 
        title: 'JDBC Connections', 
        desc: 'Java app sessions. Primary zombie source. Click for trend.', 
        trendable: true, trendMetric: 'jdbc_connections',
        thresholds: [] 
    },
    zombies: {
        title: 'Zombie Connections',
        desc: 'JDBC sessions idle beyond threshold. Click to eradicate!',
        trendable: true, trendMetric: 'zombie_count', clickAction: 'zombie',
        thresholds: [
            { class: 'healthy', text: 'Healthy: < 200' },
            { class: 'warning', text: 'Warning: 200-499' },
            { class: 'critical', text: 'Critical: 500-799' },
            { class: 'crisis', text: 'Crisis: >= 800' }
        ]
    },
    openTransactions: {
        title: 'Open Transactions',
        desc: 'Idle sessions with uncommitted work. Click for details.',
        trendable: false, clickAction: 'openTrans',
        thresholds: [
            { class: 'healthy', text: 'Healthy: 0' },
            { class: 'warning', text: 'Warning: 1-4' },
            { class: 'critical', text: 'Critical: 5-9' },
            { class: 'crisis', text: 'Crisis: >= 10' }
        ]
    },
    blockedSessions: {
        title: 'Blocked Sessions',
        desc: 'Sessions waiting on locks. Click for blocking chain details.',
        trendable: false, clickAction: 'blocking',
        thresholds: [
            { class: 'healthy', text: 'Healthy: 0' },
            { class: 'warning', text: 'Warning: 1-4' },
            { class: 'critical', text: 'Critical: 5-9' },
            { class: 'crisis', text: 'Crisis: >= 10' }
        ]
    },
    leadBlocker: { title: 'Lead Blocker', desc: 'SPID at head of blocking chain.', trendable: false, thresholds: [] },
    longestWait: {
        title: 'Longest Wait Time',
        desc: 'How long the longest blocked session has waited. Informational only.',
        trendable: false,
        thresholds: []
    },
    activeRequests: { title: 'Active Requests', desc: 'Currently executing queries. Click for details.', trendable: false, clickAction: 'activeRequests', thresholds: [] }
};

// ============================================================================
// UTILITY FUNCTIONS
// ============================================================================
function getStatus(value, thresholdKey, higherIsBetter) {
    var t = thresholds[thresholdKey];
    if (!t) return 'healthy';
    if (higherIsBetter) {
        if (value > t.warning) return 'healthy';
        if (value > t.critical) return 'warning';
        if (value > t.crisis) return 'critical';
        return 'crisis';
    } else {
        if (value < t.warning) return 'healthy';
        if (value < t.critical) return 'warning';
        if (value < t.crisis) return 'critical';
        return 'crisis';
    }
}

function getStatusText(status) {
    var map = { healthy: 'Healthy', warning: 'Warning', critical: 'Critical', crisis: 'Crisis' };
    return map[status] || '-';
}

function getStatusColor(status) {
    var map = { healthy: '#4ec9b0', warning: '#dcdcaa', critical: '#f48771', crisis: '#ff4444' };
    return map[status] || '#888';
}

function formatNumber(num) {
    if (num === null || num === undefined) return '-';
    if (num >= 1000000) return (num / 1000000).toFixed(1) + 'M';
    if (num >= 1000) return (num / 1000).toFixed(1) + 'K';
    return num.toLocaleString();
}

function formatDecimal(num, decimals) {
    if (num === null || num === undefined) return '-';
    return parseFloat(num).toFixed(decimals || 1);
}

// ============================================================================
// WIDGET BUILDERS
// ============================================================================
function createInfoButton(infoKey) {
    var info = metricInfo[infoKey];
    if (!info) return '';
    
    var thresholdHtml = '';
    if (info.thresholds && info.thresholds.length > 0) {
        thresholdHtml = '<ul>' + info.thresholds.map(function(t) {
            return '<li class="' + t.class + '">' + t.text + '</li>';
        }).join('') + '</ul>';
    }
    
    return '<div class="tooltip-container">' +
        '<button class="info-btn" onclick="event.stopPropagation()">?</button>' +
        '<div class="tooltip"><h4>' + info.title + '</h4><p>' + info.desc + '</p>' + thresholdHtml + '</div></div>';
}

function getClickHandler(infoKey, rawValue) {
    var info = metricInfo[infoKey];
    if (!info) return '';
    if (info.clickAction === 'zombie') return ' onclick="openZombieModal(' + rawValue + ')"';
    if (info.clickAction === 'openTrans') return ' onclick="openTransPanel()"';
    if (info.clickAction === 'blocking') return ' onclick="openBlockingPanel()"';
    if (info.clickAction === 'activeRequests') return ' onclick="openRequestsPanel()"';
    if (info.trendable) return ' onclick="openTrendModal(\'' + infoKey + '\', \'' + info.trendMetric + '\')"';
    return '';
}

function isClickable(infoKey) {
    var info = metricInfo[infoKey];
    return info && (info.clickAction || info.trendable);
}

function createSimpleWidget(label, value, unit, status, infoKey, rawValue) {
    var color = getStatusColor(status);
    var clickable = isClickable(infoKey);
    var handler = getClickHandler(infoKey, rawValue || 0);
    var frameClass = (status !== 'healthy') ? ' card-' + status : '';
    var cls = 'metric-widget' + frameClass + (clickable ? ' clickable' : '');
    
    return '<div class="' + cls + '"' + handler + '>' +
        '<div class="metric-header"><div class="metric-label">' + label + '</div>' + createInfoButton(infoKey) + '</div>' +
        '<div class="metric-value" style="color:' + color + ';margin-top:20px;">' + value + '</div>' +
        '<div class="metric-unit">' + unit + '</div>' +
        '<div class="metric-status status-' + status + '">' + getStatusText(status) + '</div></div>';
}

function createSegmentedGauge(value, status, numSegments, maxValue) {
    numSegments = numSegments || 40;
    maxValue = maxValue || (thresholds.ple.warning * 2.5);
    var fillRatio = Math.min(value / maxValue, 1);
    var filledCount = Math.round(fillRatio * numSegments);
    
    var html = '<div class="segment-bar">';
    for (var i = 0; i < numSegments; i++) {
        html += '<div class="segment' + (i < filledCount ? ' active-' + status : '') + '"></div>';
    }
    return html + '</div>';
}

function createSegmentedWidget(label, value, unit, status, infoKey, rawValue, numSegments, maxValue) {
    var color = getStatusColor(status);
    var clickable = isClickable(infoKey);
    var handler = getClickHandler(infoKey, rawValue || 0);
    var frameClass = (status !== 'healthy') ? ' card-' + status : '';
    var cls = 'metric-widget' + frameClass + (clickable ? ' clickable' : '');
    
    return '<div class="' + cls + '"' + handler + '>' +
        '<div class="metric-header"><div class="metric-label">' + label + '</div>' + createInfoButton(infoKey) + '</div>' +
        createSegmentedGauge(rawValue, status, numSegments, maxValue) +
        '<div class="metric-value" style="color:' + color + ';">' + value + '</div>' +
        '<div class="metric-unit">' + unit + '</div>' +
        '<div class="metric-status status-' + status + '">' + getStatusText(status) + '</div></div>';
}

function createSpeedometerGauge(percentage, status) {
    var rotation = (percentage / 100) * 180 - 90;
    return '<div class="speedometer"><svg viewBox="0 0 140 85">' +
        '<path class="speedo-zone" d="M 20 70 A 50 50 0 0 1 38 28" style="stroke:rgba(244,135,113,0.4);"/>' +
        '<path class="speedo-zone" d="M 38 28 A 50 50 0 0 1 70 20" style="stroke:rgba(220,220,170,0.4);"/>' +
        '<path class="speedo-zone" d="M 70 20 A 50 50 0 0 1 120 70" style="stroke:rgba(78,201,176,0.4);"/>' +
        '<g style="transform-origin:70px 70px;transform:rotate(' + rotation + 'deg);">' +
        '<polygon class="speedo-needle" points="70,70 67,25 73,25"/></g>' +
        '<circle cx="70" cy="70" r="8" class="speedo-center"/>' +
        '<text x="12" y="82" class="speedo-label">0</text><text x="112" y="82" class="speedo-label">100</text>' +
        '</svg></div>';
}

function createSpeedometerWidget(label, value, unit, status, infoKey, percentage) {
    var color = getStatusColor(status);
    var clickable = isClickable(infoKey);
    var handler = getClickHandler(infoKey, percentage || 0);
    var frameClass = (status !== 'healthy') ? ' card-' + status : '';
    var cls = 'metric-widget' + frameClass + (clickable ? ' clickable' : '');
    
    return '<div class="' + cls + '"' + handler + '>' +
        '<div class="metric-header"><div class="metric-label">' + label + '</div>' + createInfoButton(infoKey) + '</div>' +
        createSpeedometerGauge(percentage, status) +
        '<div class="metric-value" style="color:' + color + ';">' + value + '</div>' +
        '<div class="metric-unit">' + unit + '</div>' +
        '<div class="metric-status status-' + status + '">' + getStatusText(status) + '</div></div>';
}

function createZombieWidget(label, value, unit, status, infoKey, rawValue) {
    var maxVal = thresholds.zombies.crisis;
    return createSegmentedWidget(label, value, unit, status, infoKey, rawValue, 40, maxVal);
}

// ============================================================================
// ZOMBIE MODAL
// ============================================================================
function openZombieModal(count) {
    var server = getCurrentServer();
    
    document.getElementById('zombie-modal-body').innerHTML = 
        '<div class="zombie-icon">&#129503;&#128299;</div>' +
        '<div class="zombie-message">Are you sure you want to eradicate<br><span class="zombie-count">' + count + '</span> zombies?</div>' +
        '<div class="zombie-threshold">JDBC connections idle > ' + thresholds.zombieIdleMinutes + ' minutes on ' + server + '</div>';
    
    document.getElementById('zombie-modal-footer').innerHTML = 
        '<button class="btn btn-secondary" onclick="closeZombieModal()">Never Mind</button>' +
        '<button class="btn btn-danger" onclick="executeZombieKill()">&#128299; Double Tap Them</button>';
    
    document.getElementById('zombie-modal').classList.remove('hidden');
}

function closeZombieModal() {
    document.getElementById('zombie-modal').classList.add('hidden');
}

async function executeZombieKill() {
    var server = getCurrentServer();
    var footer = document.getElementById('zombie-modal-footer');
    footer.innerHTML = '<button class="btn btn-secondary" disabled>Executing...</button>';
    
    try {
        var result = await engineFetch('/api/server-health/kill-zombies?server=' + encodeURIComponent(server), { method: 'POST' });
        if (!result) return;
        
        if (result.Error) {
            document.getElementById('zombie-modal-body').innerHTML = 
                '<div class="result-error"><div style="font-size:32px;margin-bottom:10px;">&#128128;</div>Error: ' + result.Error + '</div>';
        } else {
            document.getElementById('zombie-modal-body').innerHTML = 
                '<div class="result-success"><div style="font-size:32px;margin-bottom:10px;">&#9989;</div>' +
                'Successfully eradicated <strong>' + result.killed_count + '</strong> zombies!</div>';
            setTimeout(function() { refreshConnections(server); }, 1000);
        }
        footer.innerHTML = '<button class="btn btn-secondary" onclick="closeZombieModal()">Close</button>';
    } catch (err) {
        document.getElementById('zombie-modal-body').innerHTML = '<div class="result-error">Failed: ' + err.message + '</div>';
        footer.innerHTML = '<button class="btn btn-secondary" onclick="closeZombieModal()">Close</button>';
    }
}

// ============================================================================
// OPEN TRANSACTIONS PANEL
// ============================================================================
function openTransPanel() {
    document.getElementById('trans-overlay').classList.add('open');
    document.getElementById('trans-panel').classList.add('open');
    loadOpenTransactions();
}

function closeTransPanel() {
    document.getElementById('trans-overlay').classList.remove('open');
    document.getElementById('trans-panel').classList.remove('open');
}

async function loadOpenTransactions() {
    var server = getCurrentServer();
    var body = document.getElementById('trans-panel-body');
    body.innerHTML = '<div class="loading">Loading...</div>';
    
    try {
        var data = await engineFetch('/api/server-health/open-transactions?server=' + encodeURIComponent(server));
        if (!data) return;
        
        if (data.Error) { body.innerHTML = '<div class="error">Error: ' + data.Error + '</div>'; return; }
        
        openTransData = data;
        if (!data || data.length === 0) { body.innerHTML = '<div class="no-data">No open transactions found. &#127881;</div>'; return; }
        
        var html = '<table class="trans-table"><thead><tr><th>SPID</th><th>Login</th><th>Program</th><th>Host</th><th>DB</th><th>Idle</th></tr></thead><tbody>';
        for (var i = 0; i < data.length; i++) {
            var row = data[i];
            var idleClass = row.idle_minutes > 60 ? 'idle-critical' : (row.idle_minutes > 15 ? 'idle-warning' : '');
            var idleDisplay = row.idle_minutes < 60 ? row.idle_minutes + 'm' : (row.idle_minutes / 60).toFixed(1) + 'h';
            html += '<tr><td class="spid">' + row.session_id + '</td>' +
                '<td>' + (row.login_name || '-') + '</td>' +
                '<td>' + ((row.program_name || '-').substring(0, 20)) + '</td>' +
                '<td>' + (row.host_name || '-') + '</td>' +
                '<td>' + (row.database_name || '-') + '</td>' +
                '<td class="' + idleClass + '">' + idleDisplay + '</td></tr>';
        }
        body.innerHTML = html + '</tbody></table>';
    } catch (err) {
        body.innerHTML = '<div class="error">Error: ' + err.message + '</div>';
    }
}

function copyKillScript() {
    if (!openTransData || openTransData.length === 0) { alert('No open transactions.'); return; }
    var script = '-- Kill script for open transactions\n-- Server: ' + getCurrentServer() + '\n\n';
    openTransData.forEach(function(r) { script += 'KILL ' + r.session_id + '; -- ' + (r.login_name||'') + '\n'; });
    navigator.clipboard.writeText(script).then(function() { alert('KILL script copied!'); });
}

// ============================================================================
// BLOCKING PANEL
// ============================================================================
var blockingData = { blockers: [], blocked: [] };

function openBlockingPanel() {
    document.getElementById('blocking-overlay').classList.add('open');
    document.getElementById('blocking-panel').classList.add('open');
    loadBlockingDetails();
}

function closeBlockingPanel() {
    document.getElementById('blocking-overlay').classList.remove('open');
    document.getElementById('blocking-panel').classList.remove('open');
}

async function loadBlockingDetails() {
    var server = getCurrentServer();
    var body = document.getElementById('blocking-panel-body');
    body.innerHTML = '<div class="loading">Loading...</div>';
    
    try {
        var data = await engineFetch('/api/server-health/blocking-details?server=' + encodeURIComponent(server));
        if (!data) return;
        
        if (data.Error) { body.innerHTML = '<div class="error">Error: ' + data.Error + '</div>'; return; }
        
        blockingData = data;
        
        if ((!data.blockers || data.blockers.length === 0) && (!data.blocked || data.blocked.length === 0)) {
            body.innerHTML = '<div class="no-data">No blocking detected. &#127881;</div>';
            return;
        }
        
        var html = '';
        
        // Lead Blockers section
        if (data.blockers && data.blockers.length > 0) {
            html += '<div class="blocker-section"><h4>&#128683; Lead Blocker' + (data.blockers.length > 1 ? 's' : '') + '</h4>';
            data.blockers.forEach(function(b) {
                var statusClass = b.status === 'sleeping' ? 'sleeping' : '';
                html += '<div class="blocker-card lead-blocker">' +
                    '<div class="blocker-header">' +
                    '<span class="blocker-spid">SPID ' + b.spid + '</span>' +
                    '<span class="blocker-status ' + statusClass + '">' + (b.status || 'unknown') + '</span>' +
                    '</div>' +
                    '<div class="blocker-details">' +
                    'Login: <span>' + (b.login_name || '-') + '</span><br>' +
                    'Host: <span>' + (b.host_name || '-') + '</span><br>' +
                    'Program: <span>' + (b.program_name || '-').substring(0, 40) + '</span><br>' +
                    'Database: <span>' + (b.database_name || '-') + '</span>' +
                    (b.duration_seconds ? '<br>Duration: <span>' + formatDuration(b.duration_seconds) + '</span>' : '') +
                    '</div>';
                if (b.query_text) {
                    html += '<div class="blocker-query">' + escapeHtml(b.query_text) + '</div>';
                }
                html += '</div>';
            });
            html += '</div>';
        }
        
        // Blocked Sessions section
        if (data.blocked && data.blocked.length > 0) {
            html += '<div class="blocker-section blocked"><h4>&#9203; Blocked Sessions (' + data.blocked.length + ')</h4>';
            data.blocked.forEach(function(b) {
                html += '<div class="blocker-card">' +
                    '<div class="blocker-header">' +
                    '<span class="blocker-spid">SPID ' + b.spid + '</span>' +
                    '<span class="wait-info">' + formatDuration(b.wait_seconds) + ' wait</span>' +
                    '</div>' +
                    '<div class="blocked-by">Blocked by: <span>SPID ' + b.blocker_spid + '</span></div>' +
                    '<div class="blocker-details">' +
                    'Login: <span>' + (b.login_name || '-') + '</span><br>' +
                    'Host: <span>' + (b.host_name || '-') + '</span><br>' +
                    'Database: <span>' + (b.database_name || '-') + '</span><br>' +
                    'Wait Type: <span>' + (b.wait_type || '-') + '</span>' +
                    '</div>';
                if (b.query_text) {
                    html += '<div class="blocker-query">' + escapeHtml(b.query_text) + '</div>';
                }
                html += '</div>';
            });
            html += '</div>';
        }
        
        body.innerHTML = html;
    } catch (err) {
        body.innerHTML = '<div class="error">Error: ' + err.message + '</div>';
    }
}

function formatDuration(seconds) {
    if (seconds === null || seconds === undefined) return '-';
    if (seconds < 60) return Math.round(seconds) + 's';
    if (seconds < 3600) return Math.round(seconds / 60) + 'm ' + Math.round(seconds % 60) + 's';
    return Math.floor(seconds / 3600) + 'h ' + Math.round((seconds % 3600) / 60) + 'm';
}

function escapeHtml(text) {
    if (!text) return '';
    return text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

function copyBlockerKillScript() {
    if (!blockingData.blockers || blockingData.blockers.length === 0) { alert('No blockers to kill.'); return; }
    var script = '-- Kill script for lead blockers\n-- Server: ' + getCurrentServer() + '\n-- WARNING: Review before executing!\n\n';
    blockingData.blockers.forEach(function(b) { script += 'KILL ' + b.spid + '; -- ' + (b.login_name||'') + ' - ' + (b.program_name||'') + '\n'; });
    navigator.clipboard.writeText(script).then(function() { alert('KILL script copied!'); });
}

// ============================================================================
// ACTIVE REQUESTS PANEL
// ============================================================================
function openRequestsPanel() {
    document.getElementById('requests-overlay').classList.add('open');
    document.getElementById('requests-panel').classList.add('open');
    loadActiveRequests();
}

function closeRequestsPanel() {
    document.getElementById('requests-overlay').classList.remove('open');
    document.getElementById('requests-panel').classList.remove('open');
}

function refreshActiveRequests() {
    loadActiveRequests();
}

async function loadActiveRequests() {
    var server = getCurrentServer();
    var body = document.getElementById('requests-panel-body');
    body.innerHTML = '<div class="loading">Loading...</div>';
    
    try {
        var data = await engineFetch('/api/server-health/active-requests?server=' + encodeURIComponent(server));
        if (!data) return;
        
        if (data.Error) { body.innerHTML = '<div class="error">Error: ' + data.Error + '</div>'; return; }
        
        if (!data || data.length === 0) {
            body.innerHTML = '<div class="no-data">No active requests at this moment.</div>';
            return;
        }
        
        // Count by status
        var running = data.filter(function(r) { return r.status === 'running'; }).length;
        var runnable = data.filter(function(r) { return r.status === 'runnable'; }).length;
        var suspended = data.filter(function(r) { return r.status === 'suspended'; }).length;
        
        var html = '<div style="margin-bottom:10px;color:#888;font-size:12px;">' + 
            data.length + ' active request' + (data.length !== 1 ? 's' : '') + 
            ' <span style="color:#4ec9b0;">(' + running + ' running</span>, ' +
            '<span style="color:#dcdcaa;">' + runnable + ' runnable</span>, ' +
            '<span style="color:#f48771;">' + suspended + ' suspended</span>)' +
            '</div>';
        
        data.forEach(function(r) {
            var cardClass = 'request-card';
            var durationClass = '';
            if (r.duration_seconds > 300) { cardClass += ' very-long-running'; durationClass = 'critical'; }
            else if (r.duration_seconds > 60) { cardClass += ' long-running'; durationClass = 'warning'; }
            
            // Status color matching card breakdown
            var statusColor = '#4ec9b0'; // running = teal
            if (r.status === 'runnable') statusColor = '#dcdcaa'; // yellow
            else if (r.status === 'suspended') statusColor = '#f48771'; // coral
            
            html += '<div class="' + cardClass + '">' +
                '<div class="request-header">' +
                '<span class="request-spid">SPID ' + r.session_id + ' <span style="color:' + statusColor + '; font-weight:500; text-transform:uppercase; font-size:10px; margin-left:6px;">' + (r.status || 'unknown') + '</span></span>' +
                '<span class="request-duration ' + durationClass + '">' + formatDuration(r.duration_seconds) + '</span>' +
                '</div>' +
                '<div class="request-details">' +
                'Login: <span>' + (r.login_name || '-') + '</span><br>' +
                'Host: <span>' + (r.host_name || '-') + '</span><br>' +
                'Program: <span>' + (r.program_name || '-').substring(0, 40) + '</span><br>' +
                'Database: <span>' + (r.database_name || '-') + '</span> | ' +
                'Command: <span>' + (r.command || '-') + '</span>' +
                '</div>' +
                '<div class="request-stats">' +
                '<span>CPU: <span class="stat-value">' + formatNumber(r.cpu_time) + 'ms</span></span>' +
                '<span>Reads: <span class="stat-value">' + formatNumber(r.logical_reads) + '</span></span>' +
                '<span>Writes: <span class="stat-value">' + formatNumber(r.writes) + '</span></span>' +
                '</div>';
            
            if (r.wait_type) {
                var waitClass = r.blocking_session_id ? 'blocked' : '';
                html += '<div class="request-wait ' + waitClass + '">' +
                    'Waiting: ' + r.wait_type + ' (' + formatDuration(r.wait_seconds) + ')';
                if (r.blocking_session_id) {
                    html += ' - Blocked by SPID ' + r.blocking_session_id;
                }
                html += '</div>';
            }
            
            if (r.query_text) {
                html += '<div class="request-query">' + escapeHtml(r.query_text) + '</div>';
            }
            
            html += '</div>';
        });
        
        body.innerHTML = html;
    } catch (err) {
        body.innerHTML = '<div class="error">Error: ' + err.message + '</div>';
    }
}

// ============================================================================
// TREND MODAL
// ============================================================================
var currentTrendMetric = null;
var currentTrendHours = 24;

function openTrendModal(infoKey, metric) {
    var server = getCurrentServer();
    var info = metricInfo[infoKey];
    currentTrendMetric = metric;
    currentTrendHours = 24;
    
    document.getElementById('trend-modal-title').textContent = info.title + ' Trend';
    document.getElementById('trend-metric-name').textContent = info.title;
    
    // Reset button states
    var buttons = document.querySelectorAll('.trend-range-btn');
    buttons.forEach(function(btn) {
        btn.classList.remove('active');
        if (btn.dataset.hours === '24') btn.classList.add('active');
    });
    
    document.getElementById('trend-modal').classList.remove('hidden');
    loadTrendData(metric, server, 24);
}

function selectTrendRange(hours) {
    currentTrendHours = hours;
    var server = getCurrentServer();
    
    // Update button states
    var buttons = document.querySelectorAll('.trend-range-btn');
    buttons.forEach(function(btn) {
        btn.classList.remove('active');
        if (parseInt(btn.dataset.hours) === hours) btn.classList.add('active');
    });
    
    loadTrendData(currentTrendMetric, server, hours);
}

function closeTrendModal() {
    document.getElementById('trend-modal').classList.add('hidden');
    if (trendChart) { trendChart.destroy(); trendChart = null; }
    currentTrendMetric = null;
}

async function loadTrendData(metric, server, hours) {
    var loadingEl = document.getElementById('trend-loading');
    var noteEl = document.getElementById('trend-aggregation-note');
    loadingEl.classList.remove('hidden');
    noteEl.textContent = '';
    
    try {
        var data = await engineFetch('/api/server-health/trend?metric=' + metric + '&server=' + encodeURIComponent(server) + '&hours=' + hours);
        if (!data) return;
        loadingEl.classList.add('hidden');
        
        if (data.Error) { 
            document.getElementById('trend-current-value').textContent = 'Error'; 
            noteEl.textContent = data.Error;
            return; 
        }
        
        if (data.length > 0) {
            document.getElementById('trend-current-value').textContent = formatNumber(data[data.length - 1].value);
        } else {
            document.getElementById('trend-current-value').textContent = 'No data';
        }
        
        // Show aggregation note for longer time ranges
        if (hours > 24) {
            noteEl.textContent = 'Showing hourly averages for ' + (hours === 168 ? '7 days' : '30 days');
        }
        
        renderTrendChart(data, metric, hours);
    } catch (err) { 
        loadingEl.classList.add('hidden');
        document.getElementById('trend-current-value').textContent = 'Error'; 
        noteEl.textContent = err.message;
    }
}

function renderTrendChart(data, metric, hours) {
    var ctx = document.getElementById('trend-chart').getContext('2d');
    if (trendChart) trendChart.destroy();
    
    // Adjust date format based on time range
    var dateFormat = hours <= 24 
        ? { hour: '2-digit', minute: '2-digit' }
        : hours <= 168 
            ? { month: 'short', day: 'numeric', hour: '2-digit' }
            : { month: 'short', day: 'numeric' };
    
    trendChart = new Chart(ctx, {
        type: 'line',
        data: {
            labels: data.map(function(d) { 
                return new Date(d.timestamp).toLocaleDateString('en-US', dateFormat); 
            }),
            datasets: [{
                label: metric,
                data: data.map(function(d) { return d.value; }),
                borderColor: '#4ec9b0',
                backgroundColor: 'rgba(78,201,176,0.1)',
                fill: true,
                tension: 0.3,
                pointRadius: hours <= 24 ? 0 : 2,
                pointHoverRadius: 4
            }]
        },
        options: {
            responsive: true,
            maintainAspectRatio: false,
            plugins: { legend: { display: false } },
            scales: {
                x: { 
                    grid: { color: '#333' }, 
                    ticks: { 
                        color: '#888', 
                        maxTicksLimit: hours <= 24 ? 12 : (hours <= 168 ? 7 : 10),
                        maxRotation: 45
                    } 
                },
                y: { grid: { color: '#333' }, ticks: { color: '#888' } }
            },
            interaction: {
                intersect: false,
                mode: 'index'
            }
        }
    });
}

// ============================================================================
// ERROR HANDLING
// ============================================================================
function showError(msg) {
    var el = document.getElementById('connection-error');
    el.textContent = msg;
    el.style.display = 'block';
}
function hideError() { document.getElementById('connection-error').style.display = 'none'; }

// ============================================================================
// DATA LOADING
// ============================================================================
async function loadThresholds() {
    try {
        var data = await engineFetch('/api/config/thresholds');
        if (!data) return;
        
        // Map GlobalConfig names to our threshold structure
        if (data.threshold_ple_warning) thresholds.ple.warning = data.threshold_ple_warning;
        if (data.threshold_ple_critical) thresholds.ple.critical = data.threshold_ple_critical;
        if (data.threshold_ple_crisis) thresholds.ple.crisis = data.threshold_ple_crisis;
        
        if (data.threshold_buffer_cache_warning) thresholds.bufferCache.warning = data.threshold_buffer_cache_warning;
        if (data.threshold_buffer_cache_critical) thresholds.bufferCache.critical = data.threshold_buffer_cache_critical;
        if (data.threshold_buffer_cache_crisis) thresholds.bufferCache.crisis = data.threshold_buffer_cache_crisis;
        
        if (data.threshold_memory_grants_warning) thresholds.memoryGrants.warning = data.threshold_memory_grants_warning;
        if (data.threshold_memory_grants_critical) thresholds.memoryGrants.critical = data.threshold_memory_grants_critical;
        if (data.threshold_memory_grants_crisis) thresholds.memoryGrants.crisis = data.threshold_memory_grants_crisis;
        
        if (data.threshold_lazy_writes_warning) thresholds.lazyWrites.warning = data.threshold_lazy_writes_warning;
        if (data.threshold_lazy_writes_critical) thresholds.lazyWrites.critical = data.threshold_lazy_writes_critical;
        if (data.threshold_lazy_writes_crisis) thresholds.lazyWrites.crisis = data.threshold_lazy_writes_crisis;
        
        if (data.threshold_zombie_count_warning) thresholds.zombies.warning = data.threshold_zombie_count_warning;
        if (data.threshold_zombie_count_critical) thresholds.zombies.critical = data.threshold_zombie_count_critical;
        if (data.threshold_zombie_count_crisis) thresholds.zombies.crisis = data.threshold_zombie_count_crisis;
        if (data.threshold_zombie_idle_minutes) thresholds.zombieIdleMinutes = data.threshold_zombie_idle_minutes;
        
        if (data.threshold_open_trans_warning) thresholds.openTransactions.warning = data.threshold_open_trans_warning;
        if (data.threshold_open_trans_critical) thresholds.openTransactions.critical = data.threshold_open_trans_critical;
        if (data.threshold_open_trans_crisis) thresholds.openTransactions.crisis = data.threshold_open_trans_crisis;
        if (data.threshold_open_trans_idle_minutes) thresholds.openTransIdleMinutes = data.threshold_open_trans_idle_minutes;
        
        if (data.threshold_blocked_sessions_warning) thresholds.blockedSessions.warning = data.threshold_blocked_sessions_warning;
        if (data.threshold_blocked_sessions_critical) thresholds.blockedSessions.critical = data.threshold_blocked_sessions_critical;
        if (data.threshold_blocked_sessions_crisis) thresholds.blockedSessions.crisis = data.threshold_blocked_sessions_crisis;
        
        console.log('Thresholds loaded from GlobalConfig');
    } catch (err) { console.log('Using default thresholds:', err); }
}

async function loadServers() {
    try {
        var servers = await engineFetch('/api/servers');
        if (!servers) return;
        var tabContainer = document.getElementById('server-tabs');
        if (servers.Error) { tabContainer.innerHTML = '<span class="loading-inline">Error loading servers</span>'; return; }
        
        // Store servers list and set default to first server (server_id 1)
        window.serverList = servers;
        window.currentServer = servers.length > 0 ? servers[0].server_name : null;
        
        // Build mini gauge shells
        var html = '';
        servers.forEach(function(s, index) {
            var id = 'mg-' + s.server_name.replace(/[^a-zA-Z0-9]/g, '_');
            var sel = index === 0 ? ' selected' : '';
            html += '<div class="mini-gauge' + sel + '" data-server="' + s.server_name + '" onclick="selectServer(\'' + s.server_name + '\')">' +
                '<div class="mini-gauge-wrap"><canvas id="' + id + '" width="60" height="60"></canvas></div>' +
                '<div class="mini-gauge-pct na" id="' + id + '-pct">-</div>' +
                '<div class="mini-gauge-name">' + s.server_name + '</div></div>';
        });
        tabContainer.innerHTML = html;
        
        if (window.currentServer) {
            refreshAll();
            refreshServerInfo(window.currentServer);
        }
    } catch (err) { document.getElementById('server-tabs').innerHTML = '<span class="loading-inline">Error loading servers</span>'; }
}

function selectServer(serverName) {
    window.currentServer = serverName;
    
    // Update gauge active states
    document.querySelectorAll('.mini-gauge').forEach(function(g) {
        g.classList.toggle('selected', g.getAttribute('data-server') === serverName);
    });
    
    // Refresh everything for the new server
    refreshAll();
    refreshServerInfo(serverName);
}

async function refreshCpuGauges() {
    try {
        var data = await engineFetch('/api/server-health/cpu-gauges');
        if (!data) return;
        if (data.Error || !data.length) return;
        
        data.forEach(function(s) {
            var id = 'mg-' + s.server_name.replace(/[^a-zA-Z0-9]/g, '_');
            var pctEl = document.getElementById(id + '-pct');
            var canvas = document.getElementById(id);
            if (!canvas) return;
            
            var pct = s.cpu_pct;
            var color = '#555';
            
            if (pct === null || pct === undefined) {
                if (pctEl) { pctEl.textContent = 'N/A'; pctEl.className = 'mini-gauge-pct na'; }
            } else {
                if (pctEl) {
                    pctEl.textContent = pct + '%';
                    if (pct < 50) { color = '#4ec9b0'; pctEl.className = 'mini-gauge-pct green'; }
                    else if (pct < 80) { color = '#dcdcaa'; pctEl.className = 'mini-gauge-pct yellow'; }
                    else { color = '#f48771'; pctEl.className = 'mini-gauge-pct red'; }
                }
            }
            
            // Semi-circle doughnut gauge
            var display = pct || 0;
            display = Math.min(display, 100);
            
            // Destroy existing chart if any
            var existing = Chart.getChart(canvas);
            if (existing) existing.destroy();
            
            miniGaugeCharts[id] = new Chart(canvas.getContext('2d'), {
                type: 'doughnut',
                data: { datasets: [{ data: [display, 100 - display], backgroundColor: [color, '#333'], borderWidth: 0, circumference: 180, rotation: 270 }] },
                options: { responsive: false, cutout: '65%', plugins: { legend: { display: false }, tooltip: { enabled: false } }, animation: { duration: 400 } }
            });
        });
    } catch (err) { /* CPU gauges are non-critical, fail silently */ }
}

function getCurrentServer() {
    return window.currentServer || 'DM-PROD-DB';
}

// ── Live sections: refresh on GlobalConfig timer ──
async function refreshLiveSections() {
    var server = getCurrentServer();
    if (!server) return;
    hideError();
    await loadLiveData();
    updateTimestamp();
}

async function loadLiveData() {
    var server = getCurrentServer();
    if (!server) return;
    await Promise.all([
        refreshMemory(server),
        refreshConnections(server),
        refreshActivity(server),
        refreshAGHealth(server),
        refreshCpuGauges()
    ]);
}

// ── Event-driven sections: refresh on orchestrator PROCESS_COMPLETED ──
async function refreshEventSections() {
    var server = getCurrentServer();
    if (!server) return;
    await Promise.all([
        refreshXEActivity(server),
        refreshDiskSpace(server)
    ]);
    updateTimestamp();
}

// ── Manual refresh / full reload ──
async function refreshAll() {
    var server = getCurrentServer();
    if (!server) return;
    hideError();
    await Promise.all([
        refreshMemory(server),
        refreshConnections(server),
        refreshActivity(server),
        refreshAGHealth(server),
        refreshCpuGauges(),
        refreshXEActivity(server),
        refreshDiskSpace(server),
        refreshServerInfo(server)
    ]);
    updateTimestamp();
}

function pageRefresh() {
    var btn = document.querySelector('.page-refresh-btn');
    if (btn) {
        btn.classList.add('spinning');
        btn.addEventListener('animationend', function() {
            btn.classList.remove('spinning');
        }, { once: true });
    }
    refreshAll();
}

function updateTimestamp() {
    document.getElementById('last-update').textContent = new Date().toLocaleTimeString();
}

// Called by engine-events.js when a relevant PROCESS_COMPLETED event arrives
function onEngineProcessCompleted(processName, event) {
    refreshEventSections();
}

async function refreshMemory(server) {
    var container = document.getElementById('memory-metrics');
    try {
        var data = await engineFetch('/api/server-health/memory?server=' + encodeURIComponent(server));
        if (!data) return;
        if (data.Error) { container.innerHTML = '<div class="error">' + data.Error + '</div>'; showError(data.Error); return; }
        if (!data || data.ple === null) { container.innerHTML = '<div class="no-data">No data</div>'; return; }
        
        container.innerHTML = 
            createSegmentedWidget('Page Life Expectancy', formatNumber(data.ple), 'seconds', getStatus(data.ple, 'ple', true), 'ple', data.ple) +
            createSpeedometerWidget('Buffer Cache Hit Ratio', formatDecimal(data.buffer_cache_hit_ratio, 1) + '%', '', getStatus(data.buffer_cache_hit_ratio, 'bufferCache', true), 'bufferCache', data.buffer_cache_hit_ratio) +
            createSimpleWidget('Memory Grants Pending', data.memory_grants_pending, 'queries waiting', getStatus(data.memory_grants_pending, 'memoryGrants', false), 'memoryGrants') +
            createSimpleWidget('Lazy Writes/sec', data.lazy_writes_sec || 0, 'pages flushed', getStatus(data.lazy_writes_sec || 0, 'lazyWrites', false), 'lazyWrites');
    } catch (err) { container.innerHTML = '<div class="error">' + err.message + '</div>'; }
}

async function refreshConnections(server) {
    var container = document.getElementById('connection-metrics');
    try {
        var data = await engineFetch('/api/server-health/connections?server=' + encodeURIComponent(server));
        if (!data) return;
        if (data.Error) { container.innerHTML = '<div class="error">' + data.Error + '</div>'; return; }
        if (!data) { container.innerHTML = '<div class="no-data">No data</div>'; return; }
        
        var openTransUnit = data.open_trans_count === 0 ? 'none' : 
            'SPID ' + data.oldest_open_trans_spid + ' (' + (data.oldest_open_trans_idle_min < 60 ? data.oldest_open_trans_idle_min + 'm' : (data.oldest_open_trans_idle_min/60).toFixed(1) + 'h') + ' idle)';
        
        container.innerHTML = 
            createSimpleWidget('Active Connections', formatNumber(data.total_connections), 'sessions', 'healthy', 'connections') +
            createSimpleWidget('JDBC Connections', formatNumber(data.jdbc_connections), 'Java sessions', 'healthy', 'jdbcConnections') +
            createZombieWidget('Zombie Connections', data.zombie_count, 'idle JDBC', getStatus(data.zombie_count, 'zombies', false), 'zombies', data.zombie_count) +
            createSimpleWidget('Open Transactions', data.open_trans_count || 0, openTransUnit, getStatus(data.open_trans_count || 0, 'openTransactions', false), 'openTransactions', data.open_trans_count);
    } catch (err) { container.innerHTML = '<div class="error">' + err.message + '</div>'; }
}

async function refreshActivity(server) {
    var container = document.getElementById('activity-metrics');
    try {
        var data = await engineFetch('/api/server-health/activity?server=' + encodeURIComponent(server));
        if (!data) return;
        if (data.Error) { container.innerHTML = '<div class="error">' + data.Error + '</div>'; return; }
        if (!data) { container.innerHTML = '<div class="no-data">No data</div>'; return; }
        
        var blockedStatus = getStatus(data.blocked_sessions, 'blockedSessions', false);
        var blockerValue = data.lead_blocker_spid ? 'SPID ' + data.lead_blocker_spid : 'None';
        var blockerUnit = data.lead_blocker_spid ? 'blocking ' + data.blocked_sessions : 'no blocking';
        var waitValue = data.longest_wait_seconds < 60 ? formatDecimal(data.longest_wait_seconds, 1) : formatDecimal(data.longest_wait_seconds / 60, 1);
        var waitUnit = data.longest_wait_seconds === 0 ? 'no waits' : (data.longest_wait_seconds < 60 ? 'seconds' : 'minutes');
        
        // Build active requests breakdown for subtitle
        var activeBreakdown = '<span style="color:#4ec9b0">' + (data.running_count || 0) + '</span> running &middot; ' +
                              '<span style="color:#dcdcaa">' + (data.runnable_count || 0) + '</span> runnable &middot; ' +
                              '<span style="color:#f48771">' + (data.suspended_count || 0) + '</span> suspended';
        
        container.innerHTML = 
            createSimpleWidget('Blocked Sessions', data.blocked_sessions, 'waiting', blockedStatus, 'blockedSessions') +
            createSimpleWidget('Lead Blocker', blockerValue, blockerUnit, data.lead_blocker_spid ? blockedStatus : 'healthy', 'leadBlocker') +
            createSimpleWidget('Longest Wait', waitValue, waitUnit, 'healthy', 'longestWait') +
            createSimpleWidget('Active Requests', data.active_requests, activeBreakdown, 'healthy', 'activeRequests');
    } catch (err) { container.innerHTML = '<div class="error">' + err.message + '</div>'; }
}

async function refreshServerInfo(server) {
    var container = document.getElementById('server-info');
    try {
        var data = await engineFetch('/api/server-health/info?server=' + encodeURIComponent(server));
        if (!data) return;
        if (data.Error) { container.innerHTML = '<div class="error">Error</div>'; return; }
        
        container.innerHTML = 
            '<div class="server-name-header">' + server + '</div>' +
            '<div class="info-row"><span class="info-label">Version</span><span class="info-value">' + data.version_short + '</span></div>' +
            '<div class="info-row"><span class="info-label">Edition</span><span class="info-value">' + data.edition + '</span></div>' +
            '<div class="info-row"><span class="info-label">Memory</span><span class="info-value">' + data.total_memory_gb + ' GB</span></div>' +
            '<div class="info-row"><span class="info-label">CPUs</span><span class="info-value">' + data.cpu_count + '</span></div>' +
            '<div class="info-row"><span class="info-label">Uptime</span><span class="info-value">' + data.uptime + '</span></div>' +
            '<div class="info-row"><span class="info-label">AG Role</span><span class="info-value ' + (data.ag_role === 'PRIMARY' ? 'primary' : 'secondary') + '">' + (data.ag_role || 'N/A') + '</span></div>';
    } catch (err) { container.innerHTML = '<div class="error">' + err.message + '</div>'; }
}

async function refreshDiskSpace(server) {
    var container = document.getElementById('disk-space');
    try {
        var data = await engineFetch('/api/server-health/disks?server=' + encodeURIComponent(server));
        if (!data) return;
        if (data.Error) { container.innerHTML = '<div class="error">Disk unavailable</div>'; return; }
        if (!data || data.length === 0) { container.innerHTML = '<div class="no-data">No disk data</div>'; return; }
        
        container.innerHTML = data.map(function(disk) {
            var status = disk.used_pct >= 95 ? 'crisis' : (disk.used_pct >= 90 ? 'critical' : (disk.used_pct >= 80 ? 'warning' : 'healthy'));
            var segments = '';
            for (var i = 0; i < 40; i++) {
                segments += '<div class="disk-segment' + (i < Math.round(disk.used_pct / 100 * 40) ? ' active-' + status : '') + '"></div>';
            }
            return '<div class="disk-item"><div class="disk-header"><span class="disk-label">' + disk.drive + '</span><span class="disk-free">' + disk.free_display + ' free</span></div><div class="disk-segment-bar">' + segments + '</div></div>';
        }).join('');
    } catch (err) { container.innerHTML = '<div class="error">' + err.message + '</div>'; }
}

// ============================================================================
// AG HEALTH PANEL
// ============================================================================
var currentAGDetailServer = null;

async function refreshAGHealth(server) {
    var container = document.getElementById('ag-health');
    try {
        var data = await engineFetch('/api/server-health/ag-status?server=' + encodeURIComponent(server));
        if (!data) return;
        
        if (data.Error) {
            container.innerHTML = '<div class="ag-not-available">AG data unavailable</div>';
            return;
        }
        
        if (!data.is_ag_member) {
            container.innerHTML = '<div class="ag-not-available">Not in Availability Group</div>';
            return;
        }
        
        // Find primary and secondary replicas
        var primary = null;
        var secondary = null;
        if (data.replicas && data.replicas.length > 0) {
            data.replicas.forEach(function(r) {
                if (r.role === 'PRIMARY') primary = r;
                else if (r.role === 'SECONDARY') secondary = r;
            });
        }
        
        // Determine overall card status for frame coloring
        var syncClass = data.ag_sync_health === 'HEALTHY' ? 'healthy' : 
                       (data.ag_sync_health === 'PARTIALLY_HEALTHY' ? 'warning' : 'critical');
        // Only add frame color class for non-healthy states
        var cardClass = 'ag-summary-card' + (syncClass !== 'healthy' ? ' ' + syncClass : '');
        
        var primaryServer = primary ? primary.server_name : 'Unknown';
        var secondaryServer = secondary ? secondary.server_name : 'Unknown';
        
        var html = '<div class="' + cardClass + '">' +
            '<div class="ag-summary-row">' +
                '<span class="ag-summary-label">Primary</span>' +
                '<span class="ag-summary-value ag-summary-link" onclick="selectReplicaAndShowDetail(\'' + primaryServer + '\')">' + primaryServer + '</span>' +
            '</div>' +
            '<div class="ag-summary-row">' +
                '<span class="ag-summary-label">Secondary</span>' +
                '<span class="ag-summary-value ag-summary-link" onclick="selectReplicaAndShowDetail(\'' + secondaryServer + '\')">' + secondaryServer + '</span>' +
            '</div>' +
            '<div class="ag-summary-row">' +
                '<span class="ag-summary-label">Sync Health</span>' +
                '<span class="ag-summary-badge ' + syncClass + '">' + (data.ag_sync_health || 'Unknown') + '</span>' +
            '</div>' +
            '</div>';
        
        container.innerHTML = html;
    } catch (err) {
        container.innerHTML = '<div class="ag-not-available">AG data unavailable</div>';
    }
}

function selectReplicaAndShowDetail(serverName) {
    // Switch the main dashboard to this server
    if (window.currentServer !== serverName) {
        selectServer(serverName);
    }
    // Open the detail slideout
    openAGDetailPanel(serverName);
}

function openAGDetailPanel(serverName) {
    currentAGDetailServer = serverName;
    document.getElementById('ag-detail-overlay').classList.add('open');
    document.getElementById('ag-detail-panel').classList.add('open');
    document.getElementById('ag-detail-server').textContent = '(' + serverName + ')';
    loadAGReplicaDetail(serverName);
}

function closeAGDetailPanel() {
    document.getElementById('ag-detail-overlay').classList.remove('open');
    document.getElementById('ag-detail-panel').classList.remove('open');
    currentAGDetailServer = null;
}

function refreshAGDetailPanel() {
    if (currentAGDetailServer) {
        loadAGReplicaDetail(currentAGDetailServer);
    }
}

async function loadAGReplicaDetail(serverName) {
    var body = document.getElementById('ag-detail-panel-body');
    body.innerHTML = '<div class="loading">Loading...</div>';
    
    try {
        var data = await engineFetch('/api/server-health/ag-replica-detail?server=' + encodeURIComponent(serverName));
        if (!data) return;
        
        if (data.Error) { body.innerHTML = '<div class="error">Error: ' + data.Error + '</div>'; return; }
        
        var html = '';
        
        // Replica summary
        if (data.replica) {
            var r = data.replica;
            var roleClass = r.role === 'PRIMARY' ? 'primary' : 'secondary';
            var healthClass = r.sync_health === 'HEALTHY' ? 'healthy' : 
                             (r.sync_health === 'PARTIALLY_HEALTHY' ? 'warning' : 'critical');
            
            html += '<div class="ag-detail-summary">' +
                '<div class="ag-detail-role ' + roleClass + '">' + r.role + '</div>' +
                '<div class="ag-detail-health ' + healthClass + '">' + r.sync_health + '</div>' +
                '</div>';
            
            html += '<div class="ag-detail-info">' +
                '<div class="ag-detail-row"><span>AG Name:</span><span>' + (r.ag_name || '-') + '</span></div>' +
                '<div class="ag-detail-row"><span>Operational State:</span><span>' + (r.operational_state || '-') + '</span></div>' +
                '<div class="ag-detail-row"><span>Connected State:</span><span>' + (r.connected_state || '-') + '</span></div>' +
                '<div class="ag-detail-row"><span>Recovery Health:</span><span>' + (r.recovery_health || '-') + '</span></div>' +
                '<div class="ag-detail-row"><span>Page Life Expectancy:</span><span class="stat-value">' + formatNumber(data.ple) + ' sec</span></div>' +
                '</div>';
        }
        
        // Database details
        if (data.databases && data.databases.length > 0) {
            html += '<div class="ag-databases-header">Database Details</div>';
            
            data.databases.forEach(function(db) {
                var dbHealthClass = db.sync_health === 'HEALTHY' ? 'healthy' : 
                                   (db.sync_health === 'PARTIALLY_HEALTHY' ? 'warning' : 'critical');
                var suspendedBadge = db.is_suspended ? 
                    '<span class="suspended-badge">SUSPENDED' + (db.suspend_reason ? ': ' + db.suspend_reason : '') + '</span>' : '';
                
                html += '<div class="ag-database-card">' +
                    '<div class="ag-database-header">' +
                    '<span class="ag-database-name">' + db.database_name + '</span>' +
                    '<span class="ag-database-state ' + dbHealthClass + '">' + db.sync_state + '</span>' +
                    '</div>' +
                    suspendedBadge;
                
                // Queue metrics (most relevant for secondary)
                html += '<div class="ag-database-metrics">' +
                    '<div class="ag-metric"><span class="ag-metric-label">Send Queue:</span><span class="ag-metric-value">' + formatBytes(db.log_send_queue_kb) + '</span></div>' +
                    '<div class="ag-metric"><span class="ag-metric-label">Send Rate:</span><span class="ag-metric-value">' + formatBytes(db.log_send_rate_kbps) + '/s</span></div>' +
                    '<div class="ag-metric"><span class="ag-metric-label">Redo Queue:</span><span class="ag-metric-value">' + formatBytes(db.redo_queue_kb) + '</span></div>' +
                    '<div class="ag-metric"><span class="ag-metric-label">Redo Rate:</span><span class="ag-metric-value">' + formatBytes(db.redo_rate_kbps) + '/s</span></div>';
                
                if (db.estimated_catchup_seconds !== null) {
                    html += '<div class="ag-metric"><span class="ag-metric-label">Est. Catchup:</span><span class="ag-metric-value">' + formatDuration(db.estimated_catchup_seconds) + '</span></div>';
                }
                html += '</div>';
                
                // Timestamps
                html += '<div class="ag-database-times">' +
                    '<div>Last Commit: ' + (db.last_commit_time || '-') + '</div>' +
                    '<div>Last Hardened: ' + (db.last_hardened_time || '-') + '</div>' +
                    '<div>Last Redone: ' + (db.last_redone_time || '-') + '</div>' +
                    '</div>';
                
                html += '</div>';
            });
        }
        
        body.innerHTML = html || '<div class="no-data">No AG data available</div>';
    } catch (err) {
        body.innerHTML = '<div class="error">Error: ' + err.message + '</div>';
    }
}

function formatBytes(kb) {
    if (kb === null || kb === undefined) return '-';
    if (kb === 0) return '0 KB';
    if (kb < 1024) return kb + ' KB';
    if (kb < 1024 * 1024) return (kb / 1024).toFixed(1) + ' MB';
    return (kb / (1024 * 1024)).toFixed(2) + ' GB';
}

// ============================================================================
// XE ACTIVITY PANEL
// ============================================================================
var xeActivityWindowMinutes = 15;

async function refreshXEActivity(server) {
    var container = document.getElementById('xe-activity');
    try {
        var data = await engineFetch('/api/server-health/xe-activity?server=' + encodeURIComponent(server) + '&minutes=' + xeActivityWindowMinutes);
        if (!data) return;
        
        if (data.Error) {
            container.innerHTML = '<div class="error">XE data unavailable</div>';
            return;
        }
        
        // Determine status classes based on counts
        var lrqClass = data.lrq_count > 10 ? 'critical' : (data.lrq_count > 5 ? 'warning' : '');
        var blockingClass = data.blocking_count > 5 ? 'critical' : (data.blocking_count > 0 ? 'warning' : '');
        var deadlockClass = data.deadlock_count > 0 ? 'critical' : '';
        var lsInClass = data.ls_inbound_count > 50 ? 'warning' : '';
        var lsOutClass = data.ls_outbound_count > 50 ? 'warning' : '';
        var agClass = data.ag_events_count > 0 ? 'warning' : '';
        var sysClass = ''; // System Health events are informational, no color escalation
        
        // Map text status to card frame class
        function cardFrame(cls) {
            if (cls === 'critical') return ' card-critical';
            if (cls === 'warning') return ' card-warning';
            return '';
        }
        
        var timeLabel = '<div class="xe-card-time">Last ' + xeActivityWindowMinutes + ' min</div>';
        
        container.innerHTML = 
            '<div class="xe-card' + cardFrame(lrqClass) + '" onclick="openXEDetail(\'lrq\')">' +
                '<div class="xe-card-label">Long Running Queries</div>' +
                '<div class="xe-card-value ' + lrqClass + '">' + (data.lrq_count || 0) + '</div>' +
                timeLabel +
            '</div>' +
            '<div class="xe-card' + cardFrame(blockingClass) + '" onclick="openXEDetail(\'blocking\')">' +
                '<div class="xe-card-label">Blocking</div>' +
                '<div class="xe-card-value ' + blockingClass + '">' + (data.blocking_count || 0) + '</div>' +
                timeLabel +
            '</div>' +
            '<div class="xe-card' + cardFrame(deadlockClass) + '" onclick="openXEDetail(\'deadlock\')">' +
                '<div class="xe-card-label">Deadlocks</div>' +
                '<div class="xe-card-value ' + deadlockClass + '">' + (data.deadlock_count || 0) + '</div>' +
                timeLabel +
            '</div>' +
            '<div class="xe-card' + cardFrame(lsInClass) + '" onclick="openXEDetail(\'ls_inbound\')">' +
                '<div class="xe-card-label">Linked Server Inbound</div>' +
                '<div class="xe-card-value ' + lsInClass + '">' + (data.ls_inbound_count || 0) + '</div>' +
                timeLabel +
            '</div>' +
            '<div class="xe-card' + cardFrame(lsOutClass) + '" onclick="openXEDetail(\'ls_outbound\')">' +
                '<div class="xe-card-label">Linked Server Outbound</div>' +
                '<div class="xe-card-value ' + lsOutClass + '">' + (data.ls_outbound_count || 0) + '</div>' +
                timeLabel +
            '</div>' +
            '<div class="xe-card' + cardFrame(agClass) + '" onclick="openXEDetail(\'ag_health\')">' +
                '<div class="xe-card-label">AG Events</div>' +
                '<div class="xe-card-value ' + agClass + '">' + (data.ag_events_count || 0) + '</div>' +
                timeLabel +
            '</div>' +
            '<div class="xe-card' + cardFrame(sysClass) + '" onclick="openXEDetail(\'system_health\')">' +
                '<div class="xe-card-label">System Health</div>' +
                '<div class="xe-card-value ' + sysClass + '">' + (data.system_health_count || 0) + '</div>' +
                timeLabel +
            '</div>';
    } catch (err) {
        container.innerHTML = '<div class="error">XE data unavailable</div>';
    }
}

function openTimeWindowSelector() {
    // Highlight the currently active button
    document.querySelectorAll('.xe-time-btn').forEach(function(btn) {
        btn.classList.toggle('active', parseInt(btn.getAttribute('data-minutes'), 10) === xeActivityWindowMinutes);
    });
    document.getElementById('xe-time-modal').classList.remove('hidden');
}

function closeTimeWindowModal() {
    document.getElementById('xe-time-modal').classList.add('hidden');
}

function applyTimeWindow(minutes) {
    xeActivityWindowMinutes = minutes;
    document.getElementById('recent-activity-window').textContent = minutes;
    closeTimeWindowModal();
    var server = getCurrentServer();
    if (server) refreshXEActivity(server);
}

function openXEDetail(eventType) {
    switch(eventType) {
        case 'lrq': openXELRQPanel(); break;
        case 'blocking': openXEBlockingPanel(); break;
        case 'deadlock': openXEDeadlockPanel(); break;
        case 'ls_inbound': openXELSInboundPanel(); break;
        case 'ls_outbound': openXELSOutboundPanel(); break;
        case 'ag_health': openXEAGEventsPanel(); break;
        case 'system_health': openXESystemHealthPanel(); break;
        default: console.log('Unknown XE event type:', eventType);
    }
}

// ============================================================================
// XE LONG RUNNING QUERIES PANEL
// ============================================================================
function openXELRQPanel() {
    document.getElementById('xe-lrq-overlay').classList.add('open');
    document.getElementById('xe-lrq-panel').classList.add('open');
    document.getElementById('xe-lrq-time-window').textContent = '(last ' + xeActivityWindowMinutes + ' minutes)';
    loadXELRQDetail();
}

function closeXELRQPanel() {
    document.getElementById('xe-lrq-overlay').classList.remove('open');
    document.getElementById('xe-lrq-panel').classList.remove('open');
}

function refreshXELRQPanel() {
    document.getElementById('xe-lrq-time-window').textContent = '(last ' + xeActivityWindowMinutes + ' minutes)';
    loadXELRQDetail();
}

async function loadXELRQDetail() {
    var server = getCurrentServer();
    var body = document.getElementById('xe-lrq-panel-body');
    body.innerHTML = '<div class="loading">Loading...</div>';
    
    try {
        var data = await engineFetch('/api/server-health/lrq-detail?server=' + encodeURIComponent(server) + '&minutes=' + xeActivityWindowMinutes);
        if (!data) return;
        
        if (data.Error) { body.innerHTML = '<div class="error">Error: ' + data.Error + '</div>'; return; }
        
        if (!data || data.length === 0) {
            body.innerHTML = '<div class="no-data">No long running queries in the last ' + xeActivityWindowMinutes + ' minutes.</div>';
            return;
        }
        
        // Calculate total executions
        var totalExecutions = data.reduce(function(sum, s) { return sum + s.execution_count; }, 0);
        
        var html = '<div style="margin-bottom:10px;color:#888;font-size:12px;">' + 
            totalExecutions + ' long running quer' + (totalExecutions !== 1 ? 'ies' : 'y') + 
            ' from ' + data.length + ' session' + (data.length !== 1 ? 's' : '') +
            ' in the last ' + xeActivityWindowMinutes + ' minutes</div>';
        
        data.forEach(function(s, idx) {
            var avgDurationSec = s.avg_duration_ms / 1000;
            var maxDurationSec = s.max_duration_ms / 1000;
            var durationClass = '';
            if (maxDurationSec > 300) durationClass = 'critical';
            else if (maxDurationSec > 60) durationClass = 'warning';
            
            var queryText = s.recent_sql_text || null;
            var hasQuery = queryText && queryText.trim().length > 0;
            
            html += '<div class="request-card">' +
                '<div class="request-header">' +
                '<span class="request-spid">SPID ' + (s.session_id || '-') + 
                    ' <span style="color:#4ec9b0;font-size:12px;margin-left:8px;">' + s.execution_count + ' Execution' + (s.execution_count !== 1 ? 's' : '') + '</span></span>' +
                '<span class="request-duration ' + durationClass + '">avg ' + formatDuration(avgDurationSec) + '</span>' +
                '</div>' +
                '<div class="request-details">' +
                'Database: <span>' + (s.database_name || '-') + '</span> | ' +
                'User: <span>' + (s.username || '-') + '</span><br>' +
                'Host: <span>' + (s.client_hostname || '-') + '</span><br>' +
                'App: <span>' + (s.client_app_name || '-').substring(0, 60) + '</span>' +
                '</div>' +
                '<div class="request-stats">' +
                '<span>Max: <span class="stat-value">' + formatDuration(maxDurationSec) + '</span></span>' +
                '<span>Total CPU: <span class="stat-value">' + formatNumber(s.total_cpu_ms) + 'ms</span></span>' +
                '<span>Total Reads: <span class="stat-value">' + formatNumber(s.total_reads) + '</span></span>' +
                '<span>Total Writes: <span class="stat-value">' + formatNumber(s.total_writes) + '</span></span>' +
                '</div>' +
                '<div style="font-size:11px;color:#666;margin-top:6px;">' +
                'First: ' + s.first_occurrence + ' | Last: ' + s.last_occurrence +
                '</div>';
            
            // Add query text section if available
            if (hasQuery) {
                html += '<div class="query-text-section">' +
                    '<div class="query-text-label">Most Recent Query:</div>' +
                    '<div class="query-text-scroll">' + escapeHtml(queryText) + '</div>' +
                    '</div>';
            }
            
            html += '</div>';
        });
        
        body.innerHTML = html;
    } catch (err) {
        body.innerHTML = '<div class="error">Error: ' + err.message + '</div>';
    }
}

// ============================================================================
// XE BLOCKING EVENTS PANEL
// ============================================================================
function openXEBlockingPanel() {
    document.getElementById('xe-blocking-overlay').classList.add('open');
    document.getElementById('xe-blocking-panel').classList.add('open');
    document.getElementById('xe-blocking-time-window').textContent = '(last ' + xeActivityWindowMinutes + ' minutes)';
    loadXEBlockingDetail();
}

function closeXEBlockingPanel() {
    document.getElementById('xe-blocking-overlay').classList.remove('open');
    document.getElementById('xe-blocking-panel').classList.remove('open');
}

function refreshXEBlockingPanel() {
    document.getElementById('xe-blocking-time-window').textContent = '(last ' + xeActivityWindowMinutes + ' minutes)';
    loadXEBlockingDetail();
}

async function loadXEBlockingDetail() {
    var server = getCurrentServer();
    var body = document.getElementById('xe-blocking-panel-body');
    body.innerHTML = '<div class="loading">Loading...</div>';
    
    try {
        var data = await engineFetch('/api/server-health/blocking-detail?server=' + encodeURIComponent(server) + '&minutes=' + xeActivityWindowMinutes);
        if (!data) return;
        
        if (data.Error) { body.innerHTML = '<div class="error">Error: ' + data.Error + '</div>'; return; }
        
        if (!data || data.length === 0) {
            body.innerHTML = '<div class="no-data">No blocking events in the last ' + xeActivityWindowMinutes + ' minutes.</div>';
            return;
        }
        
        // Calculate total blocking events
        var totalEvents = data.reduce(function(sum, b) { return sum + b.blocking_count; }, 0);
        
        var html = '<div style="margin-bottom:10px;color:#888;font-size:12px;">' + 
            totalEvents + ' blocking event' + (totalEvents !== 1 ? 's' : '') + 
            ' caused by ' + data.length + ' blocker' + (data.length !== 1 ? 's' : '') +
            ' in the last ' + xeActivityWindowMinutes + ' minutes</div>';
        
        data.forEach(function(b, idx) {
            var avgWaitSec = b.avg_wait_ms / 1000;
            var maxWaitSec = b.max_wait_ms / 1000;
            var waitClass = '';
            if (maxWaitSec > 120) waitClass = 'critical';
            else if (maxWaitSec > 60) waitClass = 'warning';
            
            // Build blocker query section if available
            var blockerQuerySection = '';
            if (b.blocker_query_text) {
                blockerQuerySection = '<div class="query-text-section">' +
                    '<div class="query-text-label">Blocker Query:</div>' +
                    '<div class="query-text-scroll">' + escapeHtml(b.blocker_query_text) + '</div>' +
                    '</div>';
            }
            
            // Build expand/collapse for victims
            var victimsSection = '';
            if (b.victims_count > 0) {
                var expandId = 'blocking-victims-' + idx;
                victimsSection = '<div class="expand-collapse-section">' +
                    '<div class="expand-toggle" onclick="toggleBlockingVictims(' + idx + ', ' + (b.blocked_by_spid || 'null') + ')">' +
                    '<span class="expand-icon" id="expand-icon-' + idx + '">▶</span> ' +
                    '<span>Show ' + b.victims_count + ' Blocked Session' + (b.victims_count !== 1 ? 's' : '') + '</span>' +
                    '</div>' +
                    '<div class="expand-content" id="' + expandId + '" style="display:none;">' +
                    '<div class="loading">Loading victims...</div>' +
                    '</div>' +
                    '</div>';
            }
            
            html += '<div class="request-card">' +
                '<div class="request-header">' +
                '<span class="request-spid">SPID ' + (b.blocked_by_spid || '-') + 
                    ' <span style="color:#f48771;font-size:12px;margin-left:8px;">' + b.blocking_count + ' Block' + (b.blocking_count !== 1 ? 's' : '') + '</span>' +
                    ' <span style="color:#dcdcaa;font-size:11px;margin-left:4px;">(' + b.victims_count + ' victim' + (b.victims_count !== 1 ? 's' : '') + ')</span></span>' +
                '<span class="request-duration ' + waitClass + '">max ' + formatDuration(maxWaitSec) + '</span>' +
                '</div>' +
                '<div class="request-details">' +
                'Database: <span>' + (b.blocked_by_database || '-') + '</span> | ' +
                'Login: <span>' + (b.blocked_by_login || '-') + '</span><br>' +
                'Host: <span>' + (b.blocked_by_host_name || '-') + '</span> | ' +
                'Status: <span>' + (b.blocked_by_status || '-') + '</span><br>' +
                'App: <span>' + (b.blocked_by_client_app || '-').substring(0, 60) + '</span>' +
                '</div>' +
                '<div class="request-stats">' +
                '<span>Avg Wait: <span class="stat-value">' + formatDuration(avgWaitSec) + '</span></span>' +
                '<span>Total Wait: <span class="stat-value">' + formatDuration(b.total_wait_ms / 1000) + '</span></span>' +
                '</div>' +
                '<div style="font-size:11px;color:#666;margin-top:6px;">' +
                'First: ' + b.first_occurrence + ' | Last: ' + b.last_occurrence +
                '</div>' +
                blockerQuerySection +
                victimsSection +
                '</div>';
        });
        
        body.innerHTML = html;
    } catch (err) {
        body.innerHTML = '<div class="error">Error: ' + err.message + '</div>';
    }
}

// Toggle expand/collapse for blocking victims
async function toggleBlockingVictims(idx, blockerSpid) {
    var contentDiv = document.getElementById('blocking-victims-' + idx);
    var iconSpan = document.getElementById('expand-icon-' + idx);
    
    if (contentDiv.style.display === 'none') {
        // Expand - load victims
        contentDiv.style.display = 'block';
        iconSpan.textContent = '▼';
        
        // Check if already loaded
        if (contentDiv.innerHTML.indexOf('Loading') === -1 && contentDiv.innerHTML.indexOf('victim-card') !== -1) {
            return; // Already loaded
        }
        
        var server = getCurrentServer();
        var url = '/api/server-health/blocking-victims?server=' + encodeURIComponent(server) + '&minutes=' + xeActivityWindowMinutes;
        if (blockerSpid !== null) {
            url += '&blocker_spid=' + blockerSpid;
        }
        
        try {
            var victims = await engineFetch(url);
            if (!victims) return;
            
            if (victims.Error) {
                contentDiv.innerHTML = '<div class="error">Error: ' + victims.Error + '</div>';
                return;
            }
            
            if (!victims || victims.length === 0) {
                contentDiv.innerHTML = '<div class="no-data">No victim details available.</div>';
                return;
            }
            
            var html = '';
            victims.forEach(function(v) {
                var waitSec = (v.blocked_wait_time_ms || 0) / 1000;
                var waitClass = waitSec > 60 ? 'critical' : (waitSec > 30 ? 'warning' : '');
                
                html += '<div class="victim-card">' +
                    '<div class="victim-header">' +
                    '<span class="victim-spid">SPID ' + (v.blocked_spid || '-') + '</span>' +
                    '<span class="victim-wait ' + waitClass + '">' + formatDuration(waitSec) + ' wait</span>' +
                    '</div>' +
                    '<div class="victim-details">' +
                    '<span>' + v.event_timestamp + '</span> | ' +
                    '<span>' + (v.blocked_database || '-') + '</span> | ' +
                    '<span>' + (v.blocked_login || '-') + '</span>' +
                    '</div>' +
                    '<div class="victim-details">' +
                    'Wait: <span>' + (v.blocked_wait_type || '-') + '</span>' +
                    (v.blocked_wait_resource ? ' on <span style="font-family:monospace;font-size:11px;">' + escapeHtml(v.blocked_wait_resource.substring(0, 60)) + '</span>' : '') +
                    '</div>';
                
                if (v.blocked_query_text) {
                    html += '<div class="query-text-section" style="margin-top:6px;">' +
                        '<div class="query-text-label">Blocked Query:</div>' +
                        '<div class="query-text-scroll">' + escapeHtml(v.blocked_query_text) + '</div>' +
                        '</div>';
                }
                
                html += '</div>';
            });
            
            contentDiv.innerHTML = html;
        } catch (err) {
            contentDiv.innerHTML = '<div class="error">Error: ' + err.message + '</div>';
        }
    } else {
        // Collapse
        contentDiv.style.display = 'none';
        iconSpan.textContent = '▶';
    }
}

// ============================================================================
// XE LINKED SERVER INBOUND PANEL
// ============================================================================
function openXELSInboundPanel() {
    document.getElementById('xe-ls-inbound-overlay').classList.add('open');
    document.getElementById('xe-ls-inbound-panel').classList.add('open');
    document.getElementById('xe-ls-inbound-time-window').textContent = '(last ' + xeActivityWindowMinutes + ' minutes)';
    loadXELSInboundDetail();
}

function closeXELSInboundPanel() {
    document.getElementById('xe-ls-inbound-overlay').classList.remove('open');
    document.getElementById('xe-ls-inbound-panel').classList.remove('open');
}

function refreshXELSInboundPanel() {
    document.getElementById('xe-ls-inbound-time-window').textContent = '(last ' + xeActivityWindowMinutes + ' minutes)';
    loadXELSInboundDetail();
}

async function loadXELSInboundDetail() {
    var server = getCurrentServer();
    var body = document.getElementById('xe-ls-inbound-panel-body');
    body.innerHTML = '<div class="loading">Loading...</div>';
    
    try {
        var data = await engineFetch('/api/server-health/ls-inbound-detail?server=' + encodeURIComponent(server) + '&minutes=' + xeActivityWindowMinutes);
        if (!data) return;
        
        if (data.Error) { body.innerHTML = '<div class="error">Error: ' + data.Error + '</div>'; return; }
        
        if (!data || data.length === 0) {
            body.innerHTML = '<div class="no-data">No inbound linked server queries in the last ' + xeActivityWindowMinutes + ' minutes.</div>';
            return;
        }
        
        // Calculate total executions
        var totalExecutions = data.reduce(function(sum, r) { return sum + (r.execution_count || 1); }, 0);
        
        var html = '<div style="margin-bottom:10px;color:#888;font-size:12px;">' + 
            totalExecutions + ' inbound quer' + (totalExecutions !== 1 ? 'ies' : 'y') + 
            ' (' + data.length + ' unique) from remote servers in the last ' + xeActivityWindowMinutes + ' minutes</div>';
        
        data.forEach(function(r) {
            var maxDurationSec = (r.max_duration_ms || 0) / 1000;
            var durationClass = '';
            if (maxDurationSec > 60) durationClass = 'critical';
            else if (maxDurationSec > 10) durationClass = 'warning';
            
            html += '<div class="request-card">' +
                '<div class="request-header">' +
                '<span class="request-spid">From: ' + (r.client_hostname || 'Unknown') + 
                    ' <span style="color:#4ec9b0;font-size:12px;margin-left:8px;">' + (r.execution_count || 1) + ' Execution' + ((r.execution_count || 1) !== 1 ? 's' : '') + '</span></span>' +
                '<span class="request-duration ' + durationClass + '">max ' + formatDuration(maxDurationSec) + '</span>' +
                '</div>' +
                '<div class="request-details">' +
                'Database: <span>' + (r.database_name || '-') + '</span> | ' +
                'User: <span>' + (r.username || '-') + '</span> | ' +
                'SPID: <span>' + (r.session_id || '-') + '</span><br>' +
                'App: <span>' + (r.client_app_name || '-').substring(0, 50) + '</span>' +
                '</div>' +
                '<div class="request-stats">' +
                '<span>Total Duration: <span class="stat-value">' + formatDuration((r.total_duration_ms || 0) / 1000) + '</span></span>' +
                '<span>Total CPU: <span class="stat-value">' + formatNumber(r.total_cpu_time_ms) + 'ms</span></span>' +
                '<span>Total Reads: <span class="stat-value">' + formatNumber(r.total_logical_reads) + '</span></span>' +
                '</div>' +
                '<div style="font-size:11px;color:#666;margin-top:6px;">' +
                'First: ' + r.first_event_timestamp + ' | Last: ' + r.last_event_timestamp +
                '</div>';
            
            if (r.sql_text) {
                html += '<div class="request-query">' + escapeHtml(r.sql_text) + '</div>';
            }
            
            html += '</div>';
        });
        
        body.innerHTML = html;
    } catch (err) {
        body.innerHTML = '<div class="error">Error: ' + err.message + '</div>';
    }
}

// ============================================================================
// XE LINKED SERVER OUTBOUND PANEL
// ============================================================================
function openXELSOutboundPanel() {
    document.getElementById('xe-ls-outbound-overlay').classList.add('open');
    document.getElementById('xe-ls-outbound-panel').classList.add('open');
    document.getElementById('xe-ls-outbound-time-window').textContent = '(last ' + xeActivityWindowMinutes + ' minutes)';
    loadXELSOutboundDetail();
}

function closeXELSOutboundPanel() {
    document.getElementById('xe-ls-outbound-overlay').classList.remove('open');
    document.getElementById('xe-ls-outbound-panel').classList.remove('open');
}

function refreshXELSOutboundPanel() {
    document.getElementById('xe-ls-outbound-time-window').textContent = '(last ' + xeActivityWindowMinutes + ' minutes)';
    loadXELSOutboundDetail();
}

async function loadXELSOutboundDetail() {
    var server = getCurrentServer();
    var body = document.getElementById('xe-ls-outbound-panel-body');
    body.innerHTML = '<div class="loading">Loading...</div>';
    
    try {
        var data = await engineFetch('/api/server-health/ls-outbound-detail?server=' + encodeURIComponent(server) + '&minutes=' + xeActivityWindowMinutes);
        if (!data) return;
        
        if (data.Error) { body.innerHTML = '<div class="error">Error: ' + data.Error + '</div>'; return; }
        
        if (!data || data.length === 0) {
            body.innerHTML = '<div class="no-data">No outbound linked server queries in the last ' + xeActivityWindowMinutes + ' minutes.</div>';
            return;
        }
        
        // Calculate total executions
        var totalExecutions = data.reduce(function(sum, r) { return sum + (r.execution_count || 1); }, 0);
        
        var html = '<div style="margin-bottom:10px;color:#888;font-size:12px;">' + 
            totalExecutions + ' outbound quer' + (totalExecutions !== 1 ? 'ies' : 'y') + 
            ' (' + data.length + ' unique) to remote servers in the last ' + xeActivityWindowMinutes + ' minutes</div>';
        
        data.forEach(function(r) {
            var maxDurationSec = (r.max_duration_ms || 0) / 1000;
            var durationClass = '';
            if (maxDurationSec > 60) durationClass = 'critical';
            else if (maxDurationSec > 10) durationClass = 'warning';
            
            html += '<div class="request-card">' +
                '<div class="request-header">' +
                '<span class="request-spid">SPID ' + (r.session_id || '-') + 
                    ' <span style="color:#4ec9b0;font-size:12px;margin-left:8px;">' + (r.execution_count || 1) + ' Execution' + ((r.execution_count || 1) !== 1 ? 's' : '') + '</span></span>' +
                '<span class="request-duration ' + durationClass + '">max ' + formatDuration(maxDurationSec) + '</span>' +
                '</div>' +
                '<div class="request-details">' +
                'Database: <span>' + (r.database_name || '-') + '</span> | ' +
                'User: <span>' + (r.username || '-') + '</span><br>' +
                'Host: <span>' + (r.client_hostname || '-') + '</span> | ' +
                'App: <span>' + (r.client_app_name || '-').substring(0, 50) + '</span>' +
                '</div>' +
                '<div class="request-stats">' +
                '<span>Total Duration: <span class="stat-value">' + formatDuration((r.total_duration_ms || 0) / 1000) + '</span></span>' +
                '<span>Total CPU: <span class="stat-value">' + formatNumber(r.total_cpu_time_ms) + 'ms</span></span>' +
                '<span>Total Reads: <span class="stat-value">' + formatNumber(r.total_logical_reads) + '</span></span>' +
                '</div>' +
                '<div style="font-size:11px;color:#666;margin-top:6px;">' +
                'First: ' + r.first_event_timestamp + ' | Last: ' + r.last_event_timestamp +
                '</div>';
            
            if (r.sql_text) {
                html += '<div class="request-query">' + escapeHtml(r.sql_text) + '</div>';
            }
            
            html += '</div>';
        });
        
        body.innerHTML = html;
    } catch (err) {
        body.innerHTML = '<div class="error">Error: ' + err.message + '</div>';
    }
}

// ============================================================================
// XE DEADLOCK EVENTS PANEL
// ============================================================================
function openXEDeadlockPanel() {
    document.getElementById('xe-deadlock-overlay').classList.add('open');
    document.getElementById('xe-deadlock-panel').classList.add('open');
    document.getElementById('xe-deadlock-time-window').textContent = '(last ' + xeActivityWindowMinutes + ' minutes)';
    loadXEDeadlockDetail();
}

function closeXEDeadlockPanel() {
    document.getElementById('xe-deadlock-overlay').classList.remove('open');
    document.getElementById('xe-deadlock-panel').classList.remove('open');
}

function refreshXEDeadlockPanel() {
    document.getElementById('xe-deadlock-time-window').textContent = '(last ' + xeActivityWindowMinutes + ' minutes)';
    loadXEDeadlockDetail();
}

async function loadXEDeadlockDetail() {
    var server = getCurrentServer();
    var body = document.getElementById('xe-deadlock-panel-body');
    body.innerHTML = '<div class="loading">Loading...</div>';
    
    try {
        var data = await engineFetch('/api/server-health/deadlock-detail?server=' + encodeURIComponent(server) + '&minutes=' + xeActivityWindowMinutes);
        if (!data) return;
        
        if (data.Error) { body.innerHTML = '<div class="error">Error: ' + data.Error + '</div>'; return; }
        
        if (!data || data.length === 0) {
            body.innerHTML = '<div class="no-data">No deadlocks in the last ' + xeActivityWindowMinutes + ' minutes.</div>';
            return;
        }
        
        var html = '<div style="margin-bottom:10px;color:#888;font-size:12px;">' + 
            data.length + ' deadlock' + (data.length !== 1 ? 's' : '') + 
            ' in the last ' + xeActivityWindowMinutes + ' minutes</div>';
        
        data.forEach(function(d) {
            var categoryClass = d.deadlock_category === 'COMPLEX' ? 'critical' : 'warning';
            var categoryLabel = d.deadlock_category || 'STANDARD';
            
            html += '<div class="request-card">' +
                '<div class="request-header">' +
                '<span class="request-spid">' + d.event_timestamp + 
                    ' <span style="font-size:11px;color:#888;margin-left:8px;">' + (d.process_count || 2) + ' processes</span></span>' +
                '<span class="request-duration ' + categoryClass + '">' + categoryLabel + '</span>' +
                '</div>';
            
            // Victim section
            html += '<div style="margin:10px 0;padding:10px;background:#3a2020;border-radius:4px;border-left:3px solid #f48771;">' +
                '<div style="color:#f48771;font-weight:500;margin-bottom:6px;">&#10006; VICTIM (Killed)</div>' +
                '<div class="request-details" style="margin:0;">' +
                'SPID: <span>' + (d.victim_spid || '-') + '</span> | ' +
                'Database: <span>' + (d.victim_database || '-') + '</span> | ' +
                'Login: <span>' + (d.victim_login || '-') + '</span><br>' +
                'Host: <span>' + (d.victim_host_name || '-') + '</span> | ' +
                'App: <span>' + (d.victim_client_app || '-').substring(0, 50) + '</span>' +
                '</div>';
            if (d.victim_query_text) {
                html += '<div class="request-query" style="margin-top:6px;">' + escapeHtml(d.victim_query_text) + '</div>';
            }
            html += '</div>';
            
            // Survivor section
            html += '<div style="margin:10px 0;padding:10px;background:#203a20;border-radius:4px;border-left:3px solid #4ec9b0;">' +
                '<div style="color:#4ec9b0;font-weight:500;margin-bottom:6px;">&#10004; SURVIVOR (Completed)</div>' +
                '<div class="request-details" style="margin:0;">' +
                'SPID: <span>' + (d.survivor_spid || '-') + '</span> | ' +
                'Database: <span>' + (d.survivor_database || '-') + '</span> | ' +
                'Login: <span>' + (d.survivor_login || '-') + '</span><br>' +
                'Host: <span>' + (d.survivor_host_name || '-') + '</span> | ' +
                'App: <span>' + (d.survivor_client_app || '-').substring(0, 50) + '</span>' +
                '</div>';
            if (d.survivor_query_text) {
                html += '<div class="request-query" style="margin-top:6px;">' + escapeHtml(d.survivor_query_text) + '</div>';
            }
            html += '</div>';
            
            html += '</div>';
        });
        
        body.innerHTML = html;
    } catch (err) {
        body.innerHTML = '<div class="error">Error: ' + err.message + '</div>';
    }
}

// ============================================================================
// XE AG HEALTH EVENTS PANEL
// ============================================================================
function openXEAGEventsPanel() {
    document.getElementById('xe-ag-events-overlay').classList.add('open');
    document.getElementById('xe-ag-events-panel').classList.add('open');
    document.getElementById('xe-ag-events-time-window').textContent = '(last ' + xeActivityWindowMinutes + ' minutes)';
    loadXEAGEventsDetail();
}

function closeXEAGEventsPanel() {
    document.getElementById('xe-ag-events-overlay').classList.remove('open');
    document.getElementById('xe-ag-events-panel').classList.remove('open');
}

function refreshXEAGEventsPanel() {
    document.getElementById('xe-ag-events-time-window').textContent = '(last ' + xeActivityWindowMinutes + ' minutes)';
    loadXEAGEventsDetail();
}

async function loadXEAGEventsDetail() {
    var server = getCurrentServer();
    var body = document.getElementById('xe-ag-events-panel-body');
    body.innerHTML = '<div class="loading">Loading...</div>';
    
    try {
        var data = await engineFetch('/api/server-health/ag-events-detail?server=' + encodeURIComponent(server) + '&minutes=' + xeActivityWindowMinutes);
        if (!data) return;
        
        if (data.Error) { body.innerHTML = '<div class="error">Error: ' + data.Error + '</div>'; return; }
        
        if (!data || data.length === 0) {
            body.innerHTML = '<div class="no-data">No AG health events in the last ' + xeActivityWindowMinutes + ' minutes.</div>';
            return;
        }
        
        var html = '<div style="margin-bottom:10px;color:#888;font-size:12px;">' + 
            data.length + ' AG event' + (data.length !== 1 ? 's' : '') + 
            ' in the last ' + xeActivityWindowMinutes + ' minutes</div>';
        
        data.forEach(function(e) {
            var stateClass = '';
            if (e.event_type.includes('failover') || e.event_type.includes('lease_expired') || e.error_number) stateClass = 'critical';
            else if (e.event_type.includes('state_change')) stateClass = 'warning';
            
            html += '<div class="request-card">' +
                '<div class="request-header">' +
                '<span class="request-spid">' + e.event_timestamp + '</span>' +
                '<span class="request-duration ' + stateClass + '">' + e.event_type + '</span>' +
                '</div>' +
                '<div class="request-details">' +
                'AG: <span>' + (e.ag_name || '-') + '</span> | ' +
                'Replica: <span>' + (e.replica_name || '-') + '</span>';
            
            if (e.database_name) {
                html += ' | Database: <span>' + e.database_name + '</span>';
            }
            
            html += '</div>';
            
            if (e.previous_state || e.current_state) {
                html += '<div style="margin-top:8px;padding:8px;background:#2a2a2a;border-radius:4px;font-size:12px;">' +
                    '<span style="color:#f48771;">' + (e.previous_state || '?') + '</span>' +
                    ' <span style="color:#888;">â†’</span> ' +
                    '<span style="color:#4ec9b0;">' + (e.current_state || '?') + '</span>' +
                    '</div>';
            }
            
            if (e.error_number) {
                html += '<div style="font-size:11px;color:#f48771;margin-top:6px;">Error ' + e.error_number + ': ' + (e.error_message || '') + '</div>';
            }
            
            html += '</div>';
        });
        
        body.innerHTML = html;
    } catch (err) {
        body.innerHTML = '<div class="error">Error: ' + err.message + '</div>';
    }
}

// ============================================================================
// XE SYSTEM HEALTH EVENTS PANEL
// ============================================================================
function openXESystemHealthPanel() {
    document.getElementById('xe-system-health-overlay').classList.add('open');
    document.getElementById('xe-system-health-panel').classList.add('open');
    document.getElementById('xe-system-health-time-window').textContent = '(last ' + xeActivityWindowMinutes + ' minutes)';
    loadXESystemHealthDetail();
}

function closeXESystemHealthPanel() {
    document.getElementById('xe-system-health-overlay').classList.remove('open');
    document.getElementById('xe-system-health-panel').classList.remove('open');
}

function refreshXESystemHealthPanel() {
    document.getElementById('xe-system-health-time-window').textContent = '(last ' + xeActivityWindowMinutes + ' minutes)';
    loadXESystemHealthDetail();
}

async function loadXESystemHealthDetail() {
    var server = getCurrentServer();
    var body = document.getElementById('xe-system-health-panel-body');
    body.innerHTML = '<div class="loading">Loading...</div>';
    
    try {
        var data = await engineFetch('/api/server-health/system-health-detail?server=' + encodeURIComponent(server) + '&minutes=' + xeActivityWindowMinutes);
        if (!data) return;
        
        if (data.Error) { body.innerHTML = '<div class="error">Error: ' + data.Error + '</div>'; return; }
        
        if (!data || data.length === 0) {
            body.innerHTML = '<div class="no-data">No system health events in the last ' + xeActivityWindowMinutes + ' minutes.</div>';
            return;
        }
        
        var html = '<div style="margin-bottom:10px;color:#888;font-size:12px;">' + 
            data.length + ' system health event' + (data.length !== 1 ? 's' : '') + 
            ' in the last ' + xeActivityWindowMinutes + ' minutes</div>';
        
        data.forEach(function(e) {
            var eventClass = '';
            if (e.event_type.includes('error') || e.component_state === 'error') eventClass = 'critical';
            else if (e.component_state === 'warning') eventClass = 'warning';
            
            html += '<div class="request-card">' +
                '<div class="request-header">' +
                '<span class="request-spid">' + e.event_timestamp + '</span>' +
                '<span class="request-duration ' + eventClass + '">' + e.event_type + '</span>' +
                '</div>' +
                '<div class="request-details">';
            
            var details = [];
            if (e.session_id) details.push('SPID: <span>' + e.session_id + '</span>');
            if (e.error_code) details.push('Error: <span>' + e.error_code + '</span>');
            if (e.client_hostname) details.push('Host: <span>' + e.client_hostname + '</span>');
            if (e.client_app_name) details.push('App: <span>' + e.client_app_name.substring(0, 40) + '</span>');
            if (e.wait_type) details.push('Wait: <span>' + e.wait_type + '</span>');
            if (e.component_type) details.push('Component: <span>' + e.component_type + '</span>');
            if (e.component_state) details.push('State: <span>' + e.component_state + '</span>');
            
            html += details.join(' | ') || '-';
            html += '</div>';
            
            var stats = [];
            if (e.duration_ms) stats.push('<span>Duration: <span class="stat-value">' + formatDuration(e.duration_ms / 1000) + '</span></span>');
            if (e.os_error) stats.push('<span>OS Error: <span class="stat-value">' + e.os_error + '</span></span>');
            if (e.calling_api_name) stats.push('<span>API: <span class="stat-value">' + e.calling_api_name + '</span></span>');
            
            if (stats.length > 0) {
                html += '<div class="request-stats">' + stats.join('') + '</div>';
            }
            
            html += '</div>';
        });
        
        body.innerHTML = html;
    } catch (err) {
        body.innerHTML = '<div class="error">Error: ' + err.message + '</div>';
    }
}

// ============================================================================
// INITIALIZATION
// ============================================================================
document.addEventListener('DOMContentLoaded', async function() {
    await loadRefreshInterval();
    loadThresholds();
    loadServers();
    startAutoRefresh();
    connectEngineEvents();
    initEngineCardClicks();
    startLivePolling();
});

function startAutoRefresh() {
    // Lightweight timer — only checks for overnight date change (page reload)
    // All data refresh is handled by live polling timer + event-driven via onEngineProcessCompleted
    setInterval(function() {
        var today = new Date().toDateString();
        if (today !== pageLoadDate) {
            window.location.reload();
        }
    }, 60000);
}

// ============================================================================
// LIVE POLLING (Refresh Architecture)
// ============================================================================
// Live sections: Memory, Connections, Current Activity, AG Health, CPU Gauges
// These query production DMVs directly and change independently of collectors.
//
// Event-driven sections: XE Activity, Disk Space
// These refresh on orchestrator PROCESS_COMPLETED via onEngineProcessCompleted().
//
// See: Refresh Architecture doc, Section 2.1 / 2.2
// ============================================================================

/**
 * Loads the page-specific refresh interval from GlobalConfig via shared API.
 * Called once on page init. Falls back to default if API unavailable.
 */
async function loadRefreshInterval() {
    try {
        var data = await engineFetch('/api/config/refresh-interval?page=serverhealth');
        if (data) {
            // engineFetch handles auth and returns parsed JSON
            PAGE_REFRESH_INTERVAL = data.interval || 5;
        }
    } catch (e) {
        // API unavailable — use default. Not worth logging; page works fine.
    }
}

/**
 * Starts the live polling timer using the GlobalConfig interval.
 * Timer calls refreshLiveSections() which reloads all live sections on the page.
 */
function startLivePolling() {
    if (livePollingTimer) clearInterval(livePollingTimer);
    livePollingTimer = setInterval(function() {
        if (enginePageHidden || engineSessionExpired) return;
        refreshLiveSections();
    }, PAGE_REFRESH_INTERVAL * 1000);
}

/**
 * Stops live polling. Used by smart polling (activity-aware) when the page
 * detects no orchestrator activity and live data would be unchanged.
 */
function stopLivePolling() {
    if (livePollingTimer) {
        clearInterval(livePollingTimer);
        livePollingTimer = null;
    }
}

// ============================================================================
// LEGACY ENGINE STATUS — REMOVED
// ============================================================================
// Engine indicator cards (DMV, XE, Disk) are now driven by the shared
// engine-events.js WebSocket module. The following functions were removed:
//   - loadEngineStatus()       — polled /api/server-health/engine-status every 5s
//   - startEngineTicker()      — 1-second countdown ticker
//   - tickEngineIndicator()    — per-card state/countdown renderer
//   - fmtEngineCountdown()     — countdown time formatter
// See: RealTime_Engine_Events_Architecture.md
// ============================================================================

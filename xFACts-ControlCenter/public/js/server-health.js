/* ============================================================================
   xFACts Control Center - Server Health JavaScript (server-health.js)
   Location: E:\xFACts-ControlCenter\public\js\server-health.js
   Version: Tracked in dbo.System_Metadata (component: ServerOps.ServerHealth)

   Page logic for the Server Health dashboard: the engine process map and
   action dispatch tables, the metric thresholds and metric metadata, the
   page boot function, the live and event-driven section refreshers, the
   metric widget and gauge builders, the modal and slideout open/close and
   detail loaders, and the page lifecycle hooks the shared bootloader calls.

   FILE ORGANIZATION
   -----------------
   CONSTANTS: ENGINE PROCESSES
   CONSTANTS: ACTION DISPATCH
   CONSTANTS: THRESHOLDS
   CONSTANTS: METRIC INFO
   STATE: PAGE STATE
   FUNCTIONS: INITIALIZATION
   FUNCTIONS: LIVE POLLING
   FUNCTIONS: REFRESH ORCHESTRATION
   FUNCTIONS: UTILITIES
   FUNCTIONS: WIDGET BUILDERS
   FUNCTIONS: SERVER SELECTOR
   FUNCTIONS: LIVE SECTIONS
   FUNCTIONS: SERVER INFO AND DISK
   FUNCTIONS: AG HEALTH
   FUNCTIONS: XE ACTIVITY
   FUNCTIONS: ZOMBIE MODAL
   FUNCTIONS: OPEN TRANSACTIONS PANEL
   FUNCTIONS: BLOCKING PANEL
   FUNCTIONS: ACTIVE REQUESTS PANEL
   FUNCTIONS: TREND MODAL
   FUNCTIONS: XE TIME WINDOW
   FUNCTIONS: XE LRQ PANEL
   FUNCTIONS: XE BLOCKING PANEL
   FUNCTIONS: XE DEADLOCK PANEL
   FUNCTIONS: XE LINKED SERVER PANELS
   FUNCTIONS: XE AG EVENTS PANEL
   FUNCTIONS: XE SYSTEM HEALTH PANEL
   FUNCTIONS: PAGE LIFECYCLE HOOKS
   ============================================================================ */

/* ============================================================================
   CONSTANTS: ENGINE PROCESSES
   ----------------------------------------------------------------------------
   The orchestrator process map consumed by the shared engine-events module.
   Keys match Orchestrator.ProcessRegistry.process_name; slugs match
   cc_engine_slug for the four Server Health collection processes.
   Prefix: srv
   ============================================================================ */

/* Engine process map: process_name to engine card slug. */
var srv_ENGINE_PROCESSES = {
    'Collect-DMVMetrics':     { slug: 'dmv' },
    'Collect-XEEvents':       { slug: 'xe' },
    'Collect-ServerHealth':   { slug: 'disk' },
    'Send-DiskHealthSummary': { slug: 'disksummary' }
};

/* ============================================================================
   CONSTANTS: ACTION DISPATCH
   ----------------------------------------------------------------------------
   The click-action dispatch table mapping every data-action-click value on
   the page (static route markup and JS-rendered markup alike) to its handler
   function. Routed by the shared delegated listener registered in srv_init.
   Prefix: srv
   ============================================================================ */

/* Click-action dispatch table for all page-local data-action-click values. */
const srv_clickActions = {
    'srv-select-server':                  srv_selectServer,
    'srv-open-trend-modal':               srv_openTrendModal,
    'srv-open-zombie-modal':              srv_openZombieModal,
    'srv-open-trans-panel':               srv_openTransPanel,
    'srv-open-blocking-panel':            srv_openBlockingPanel,
    'srv-open-requests-panel':            srv_openRequestsPanel,
    'srv-open-xe-detail':                 srv_openXEDetail,
    'srv-select-replica-detail':          srv_selectReplicaAndShowDetail,
    'srv-toggle-blocking-victims':        srv_toggleBlockingVictims,
    'srv-open-time-window':               srv_openTimeWindowSelector,
    'srv-apply-time-window':              srv_applyTimeWindow,
    'srv-close-time-window-modal':        srv_closeTimeWindowModal,
    'srv-close-zombie-modal':             srv_closeZombieModal,
    'srv-execute-zombie-kill':            srv_executeZombieKill,
    'srv-select-trend-range':             srv_selectTrendRange,
    'srv-close-trend-modal':              srv_closeTrendModal,
    'srv-close-trans-slideout':           srv_closeTransPanel,
    'srv-copy-kill-script':               srv_copyKillScript,
    'srv-close-blocking-slideout':        srv_closeBlockingPanel,
    'srv-copy-blocker-kill-script':       srv_copyBlockerKillScript,
    'srv-close-requests-slideout':        srv_closeRequestsPanel,
    'srv-refresh-active-requests':        srv_refreshActiveRequests,
    'srv-close-xe-lrq-slideout':          srv_closeXELRQPanel,
    'srv-refresh-xe-lrq':                 srv_refreshXELRQPanel,
    'srv-close-xe-blocking-slideout':     srv_closeXEBlockingPanel,
    'srv-refresh-xe-blocking':            srv_refreshXEBlockingPanel,
    'srv-close-xe-deadlock-slideout':     srv_closeXEDeadlockPanel,
    'srv-refresh-xe-deadlock':            srv_refreshXEDeadlockPanel,
    'srv-close-xe-ls-inbound-slideout':   srv_closeXELSInboundPanel,
    'srv-refresh-xe-ls-inbound':          srv_refreshXELSInboundPanel,
    'srv-close-xe-ls-outbound-slideout':  srv_closeXELSOutboundPanel,
    'srv-refresh-xe-ls-outbound':         srv_refreshXELSOutboundPanel,
    'srv-close-xe-ag-events-slideout':    srv_closeXEAGEventsPanel,
    'srv-refresh-xe-ag-events':           srv_refreshXEAGEventsPanel,
    'srv-close-ag-detail-slideout':       srv_closeAGDetailPanel,
    'srv-refresh-ag-detail':              srv_refreshAGDetailPanel,
    'srv-close-xe-system-health-slideout': srv_closeXESystemHealthPanel,
    'srv-refresh-xe-system-health':       srv_refreshXESystemHealthPanel
};

/* ============================================================================
   CONSTANTS: THRESHOLDS
   ----------------------------------------------------------------------------
   The fallback metric threshold defaults. Overwritten at boot by the values
   loaded from GlobalConfig; used as-is when the config API is unavailable.
   Prefix: srv
   ============================================================================ */

/* Fallback metric threshold defaults, overwritten from GlobalConfig at boot. */
const srv_defaultThresholds = {
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

/* ============================================================================
   CONSTANTS: METRIC INFO
   ----------------------------------------------------------------------------
   Per-metric display metadata: titles, descriptions, trend capability, click
   actions, and threshold legend rows rendered into the metric info tooltips.
   Prefix: srv
   ============================================================================ */

/* Per-metric display metadata for widget labels, tooltips, and click wiring. */
const srv_metricInfo = {
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

/* ============================================================================
   STATE: PAGE STATE
   ----------------------------------------------------------------------------
   Mutable page state: the live-resolved thresholds, the chart instances, the
   cached panel datasets, the current trend and time-window selections, the
   active AG detail server, and the live-polling timer and interval.
   Prefix: srv
   ============================================================================ */

/* Live-resolved thresholds, seeded from the defaults and updated from config. */
var srv_thresholds = JSON.parse(JSON.stringify(srv_defaultThresholds));

/* The active trend chart instance, or null when the trend modal is closed. */
var srv_trendChart = null;

/* Map of mini-gauge canvas id to its Chart.js instance. */
var srv_miniGaugeCharts = {};

/* The most recent open-transactions dataset, used to build the KILL script. */
var srv_openTransData = [];

/* The most recent blocking dataset, used to build the blocker KILL script. */
var srv_blockingData = { blockers: [], blocked: [] };

/* The metric key currently shown in the trend modal, or null when closed. */
var srv_currentTrendMetric = null;

/* The trend range in hours currently selected in the trend modal. */
var srv_currentTrendHours = 24;

/* The Extended Events activity time window in minutes. */
var srv_xeActivityWindowMinutes = 15;

/* The server whose replica detail slideout is open, or null when closed. */
var srv_currentAGDetailServer = null;

/* The live-section poll interval in seconds, loaded from GlobalConfig at boot. */
var srv_pageRefreshInterval = 5;

/* The live-polling setInterval handle, or null when polling is stopped. */
var srv_livePollingTimer = null;

/* The date the page was loaded, used to force a reload across a date change. */
var srv_pageLoadDate = new Date().toDateString();

/* The currently selected server name, or null before the server list loads. */
var srv_currentServer = null;

/* The loaded server list from the servers API. */
var srv_serverList = [];

/* ============================================================================
   FUNCTIONS: INITIALIZATION
   ----------------------------------------------------------------------------
   The page boot function invoked by the shared bootloader after the module
   loads. Registers the delegated click listener, connects engine events,
   loads configuration and the server list, and starts live polling.
   Prefix: srv
   ============================================================================ */

/* Boots the page: wires the click dispatcher, engine events, config, and data. */
function srv_init() {
    document.body.addEventListener('click', srv_dispatchClick);
    document.body.addEventListener('mouseover', srv_handleTooltipOver);
    document.body.addEventListener('mouseout', srv_handleTooltipOut);
    cc_connectEngineEvents();
    srv_loadRefreshInterval();
    srv_loadThresholds();
    srv_loadServers();
    srv_startAutoReload();
    srv_startLivePolling();
}

/* ============================================================================
   FUNCTIONS: LIVE POLLING
   ----------------------------------------------------------------------------
   The live-section polling timer and the daily auto-reload checker. Live
   sections poll on the GlobalConfig interval and pause while the tab is hidden
   or the session has expired; event-driven sections refresh via the hooks.
   Prefix: srv
   ============================================================================ */

/* Routes a delegated body click to its handler via the dispatch table. */
function srv_dispatchClick(event) {
    var el = event.target.closest('[data-action-click]');
    if (!el) return;
    var action = el.getAttribute('data-action-click');
    var handler = srv_clickActions[action];
    if (handler) handler(el, event);
}

/* Loads the page live-poll interval from GlobalConfig, falling back to default. */
async function srv_loadRefreshInterval() {
    try {
        var data = await cc_engineFetch('/api/config/refresh-interval?page=serverhealth');
        if (data) srv_pageRefreshInterval = data.interval || 5;
    } catch (e) { /* config unavailable; default interval stands */ }
}

/* Loads metric thresholds from GlobalConfig, overwriting the defaults. */
async function srv_loadThresholds() {
    try {
        var data = await cc_engineFetch('/api/config/thresholds');
        if (!data) return;

        if (data.threshold_ple_warning) srv_thresholds.ple.warning = data.threshold_ple_warning;
        if (data.threshold_ple_critical) srv_thresholds.ple.critical = data.threshold_ple_critical;
        if (data.threshold_ple_crisis) srv_thresholds.ple.crisis = data.threshold_ple_crisis;

        if (data.threshold_buffer_cache_warning) srv_thresholds.bufferCache.warning = data.threshold_buffer_cache_warning;
        if (data.threshold_buffer_cache_critical) srv_thresholds.bufferCache.critical = data.threshold_buffer_cache_critical;
        if (data.threshold_buffer_cache_crisis) srv_thresholds.bufferCache.crisis = data.threshold_buffer_cache_crisis;

        if (data.threshold_memory_grants_warning) srv_thresholds.memoryGrants.warning = data.threshold_memory_grants_warning;
        if (data.threshold_memory_grants_critical) srv_thresholds.memoryGrants.critical = data.threshold_memory_grants_critical;
        if (data.threshold_memory_grants_crisis) srv_thresholds.memoryGrants.crisis = data.threshold_memory_grants_crisis;

        if (data.threshold_lazy_writes_warning) srv_thresholds.lazyWrites.warning = data.threshold_lazy_writes_warning;
        if (data.threshold_lazy_writes_critical) srv_thresholds.lazyWrites.critical = data.threshold_lazy_writes_critical;
        if (data.threshold_lazy_writes_crisis) srv_thresholds.lazyWrites.crisis = data.threshold_lazy_writes_crisis;

        if (data.threshold_zombie_count_warning) srv_thresholds.zombies.warning = data.threshold_zombie_count_warning;
        if (data.threshold_zombie_count_critical) srv_thresholds.zombies.critical = data.threshold_zombie_count_critical;
        if (data.threshold_zombie_count_crisis) srv_thresholds.zombies.crisis = data.threshold_zombie_count_crisis;
        if (data.threshold_zombie_idle_minutes) srv_thresholds.zombieIdleMinutes = data.threshold_zombie_idle_minutes;

        if (data.threshold_open_trans_warning) srv_thresholds.openTransactions.warning = data.threshold_open_trans_warning;
        if (data.threshold_open_trans_critical) srv_thresholds.openTransactions.critical = data.threshold_open_trans_critical;
        if (data.threshold_open_trans_crisis) srv_thresholds.openTransactions.crisis = data.threshold_open_trans_crisis;
        if (data.threshold_open_trans_idle_minutes) srv_thresholds.openTransIdleMinutes = data.threshold_open_trans_idle_minutes;

        if (data.threshold_blocked_sessions_warning) srv_thresholds.blockedSessions.warning = data.threshold_blocked_sessions_warning;
        if (data.threshold_blocked_sessions_critical) srv_thresholds.blockedSessions.critical = data.threshold_blocked_sessions_critical;
        if (data.threshold_blocked_sessions_crisis) srv_thresholds.blockedSessions.crisis = data.threshold_blocked_sessions_crisis;
    } catch (err) { /* config unavailable; default thresholds stand */ }
}

/* Starts the live-section polling timer on the configured interval. */
function srv_startLivePolling() {
    if (srv_livePollingTimer) clearInterval(srv_livePollingTimer);
    srv_livePollingTimer = setInterval(function() {
        if (cc_enginePageHidden || cc_engineSessionExpired) return;
        srv_refreshLiveSections();
    }, srv_pageRefreshInterval * 1000);
}

/* Stops the live-section polling timer. */
function srv_stopLivePolling() {
    if (srv_livePollingTimer) {
        clearInterval(srv_livePollingTimer);
        srv_livePollingTimer = null;
    }
}

/* Reloads the page when the calendar date changes (overnight rollover). */
function srv_startAutoReload() {
    setInterval(function() {
        var today = new Date().toDateString();
        if (today !== srv_pageLoadDate) window.location.reload();
    }, 60000);
}

/* ============================================================================
   FUNCTIONS: REFRESH ORCHESTRATION
   ----------------------------------------------------------------------------
   The refresh orchestrators: the live-section set polled on the timer, the
   event-driven set refreshed when an engine process completes, the full
   refresh used on server select and manual refresh, and the timestamp update.
   Prefix: srv
   ============================================================================ */

/* Refreshes the live sections and updates the timestamp. */
async function srv_refreshLiveSections() {
    var server = srv_getCurrentServer();
    if (!server) return;
    srv_hideError();
    await srv_loadLiveData();
    srv_updateTimestamp();
}

/* Loads all live sections for the current server in parallel. */
async function srv_loadLiveData() {
    var server = srv_getCurrentServer();
    if (!server) return;
    await Promise.all([
        srv_refreshMemory(server),
        srv_refreshConnections(server),
        srv_refreshActivity(server),
        srv_refreshAGHealth(server),
        srv_refreshCpuGauges()
    ]);
}

/* Refreshes the event-driven sections (XE activity and disk space). */
async function srv_refreshEventSections() {
    var server = srv_getCurrentServer();
    if (!server) return;
    await Promise.all([
        srv_refreshXEActivity(server),
        srv_refreshDiskSpace(server)
    ]);
    srv_updateTimestamp();
}

/* Refreshes every section for the current server (full reload). */
async function srv_refreshAll() {
    var server = srv_getCurrentServer();
    if (!server) return;
    srv_hideError();
    await Promise.all([
        srv_refreshMemory(server),
        srv_refreshConnections(server),
        srv_refreshActivity(server),
        srv_refreshAGHealth(server),
        srv_refreshCpuGauges(),
        srv_refreshXEActivity(server),
        srv_refreshDiskSpace(server),
        srv_refreshServerInfo(server)
    ]);
    srv_updateTimestamp();
}

/* Writes the current time into the shared last-update timestamp element. */
function srv_updateTimestamp() {
    document.getElementById('cc-last-update').textContent = new Date().toLocaleTimeString();
}

/* Shows the connection error banner with a message. */
function srv_showError(msg) {
    var el = document.getElementById('srv-connection-error');
    if (!el) return;
    el.textContent = msg;
    el.style.display = 'block';
}

/* Hides the connection error banner. */
function srv_hideError() {
    var el = document.getElementById('srv-connection-error');
    if (el) el.style.display = 'none';
}

/* ============================================================================
   FUNCTIONS: UTILITIES
   ----------------------------------------------------------------------------
   Page formatting and status helpers: threshold-to-status resolution, status
   label and color lookups, number, decimal, duration, and byte formatters.
   Prefix: srv
   ============================================================================ */

/* Resolves a metric value to a status tier using its threshold set. */
function srv_getStatus(value, thresholdKey, higherIsBetter) {
    var t = srv_thresholds[thresholdKey];
    if (!t) return 'healthy';
    if (higherIsBetter) {
        if (value > t.warning) return 'healthy';
        if (value > t.critical) return 'warning';
        if (value > t.crisis) return 'critical';
        return 'crisis';
    }
    if (value < t.warning) return 'healthy';
    if (value < t.critical) return 'warning';
    if (value < t.crisis) return 'critical';
    return 'crisis';
}

/* Maps a status tier to its display label. */
function srv_getStatusText(status) {
    var map = { healthy: 'Healthy', warning: 'Warning', critical: 'Critical', crisis: 'Crisis' };
    return map[status] || '-';
}

/* Maps a status tier to its display color. */
function srv_getStatusColor(status) {
    var map = { healthy: '#4ec9b0', warning: '#dcdcaa', critical: '#f48771', crisis: '#ff4444' };
    return map[status] || '#888';
}

/* Formats a number with K/M suffixes for large values. */
function srv_formatNumber(num) {
    if (num === null || num === undefined) return '-';
    if (num >= 1000000) return (num / 1000000).toFixed(1) + 'M';
    if (num >= 1000) return (num / 1000).toFixed(1) + 'K';
    return num.toLocaleString();
}

/* Formats a number to a fixed number of decimal places. */
function srv_formatDecimal(num, decimals) {
    if (num === null || num === undefined) return '-';
    return parseFloat(num).toFixed(decimals || 1);
}

/* Formats a duration in seconds as a compact h/m/s string. */
function srv_formatDuration(seconds) {
    if (seconds === null || seconds === undefined) return '-';
    if (seconds < 60) return Math.round(seconds) + 's';
    if (seconds < 3600) return Math.round(seconds / 60) + 'm ' + Math.round(seconds % 60) + 's';
    return Math.floor(seconds / 3600) + 'h ' + Math.round((seconds % 3600) / 60) + 'm';
}

/* Formats a kilobyte value as KB/MB/GB. */
function srv_formatBytes(kb) {
    if (kb === null || kb === undefined) return '-';
    if (kb === 0) return '0 KB';
    if (kb < 1024) return kb + ' KB';
    if (kb < 1024 * 1024) return (kb / 1024).toFixed(1) + ' MB';
    return (kb / (1024 * 1024)).toFixed(2) + ' GB';
}

/* Copies text to the clipboard via execCommand and reports the outcome. */
function srv_copyToClipboard(text, successMessage) {
    var ta = document.createElement('textarea');
    ta.value = text;
    ta.style.position = 'fixed';
    ta.style.top = '-9999px';
    ta.style.left = '-9999px';
    ta.setAttribute('readonly', '');
    document.body.appendChild(ta);
    ta.select();

    var ok = false;
    try { ok = document.execCommand('copy'); } catch (e) { ok = false; }
    document.body.removeChild(ta);

    if (ok) {
        cc_showAlert(successMessage || 'Copied to clipboard.', { title: 'Copied' });
    } else {
        cc_showAlert('Unable to copy to the clipboard. Your browser may have blocked the action.', { title: 'Copy Failed' });
    }
}

/* Shows the metric tooltip when the pointer enters its trigger container. */
function srv_handleTooltipOver(event) {
    var container = event.target.closest('.srv-tooltip-container');
    if (!container) return;
    var tip = container.querySelector('.srv-tooltip');
    if (tip) tip.classList.add('srv-tooltip-visible');
}

/* Hides the metric tooltip when the pointer leaves its trigger container. */
function srv_handleTooltipOut(event) {
    var container = event.target.closest('.srv-tooltip-container');
    if (!container) return;
    if (container.contains(event.relatedTarget)) return;
    var tip = container.querySelector('.srv-tooltip');
    if (tip) tip.classList.remove('srv-tooltip-visible');
}

/* ============================================================================
   FUNCTIONS: WIDGET BUILDERS
   ----------------------------------------------------------------------------
   The metric widget builders: the info tooltip button, the click-attribute
   builder, and the simple, segmented, speedometer, and zombie widget
   factories plus the segmented-bar and speedometer gauge SVG builders.
   Prefix: srv
   ============================================================================ */

/* Builds the info tooltip button and panel for a metric. */
function srv_createInfoButton(infoKey) {
    var info = srv_metricInfo[infoKey];
    if (!info) return '';
    var thresholdHtml = '';
    if (info.thresholds && info.thresholds.length > 0) {
        thresholdHtml = '<ul>' + info.thresholds.map(function(t) {
            return '<li class="srv-tt-' + t.class + '">' + t.text + '</li>';
        }).join('') + '</ul>';
    }
    return '<div class="srv-tooltip-container">' +
        '<button class="srv-info-btn">?</button>' +
        '<div class="srv-tooltip"><div class="srv-tooltip-title">' + info.title + '</div><p class="srv-tooltip-text">' + info.desc + '</p>' + thresholdHtml + '</div></div>';
}

/* Builds the data-action-click and argument attributes for a metric widget. */
function srv_clickAttrs(infoKey, rawValue) {
    var info = srv_metricInfo[infoKey];
    if (!info) return '';
    if (info.clickAction === 'zombie') return ' data-action-click="srv-open-zombie-modal" data-action-srv-count="' + (rawValue || 0) + '"';
    if (info.clickAction === 'openTrans') return ' data-action-click="srv-open-trans-panel"';
    if (info.clickAction === 'blocking') return ' data-action-click="srv-open-blocking-panel"';
    if (info.clickAction === 'activeRequests') return ' data-action-click="srv-open-requests-panel"';
    if (info.trendable) return ' data-action-click="srv-open-trend-modal" data-action-srv-info="' + infoKey + '" data-action-srv-metric="' + info.trendMetric + '"';
    return '';
}

/* Reports whether a metric widget is clickable. */
function srv_isClickable(infoKey) {
    var info = srv_metricInfo[infoKey];
    return info && (info.clickAction || info.trendable);
}

/* Builds a simple value metric widget. */
function srv_createSimpleWidget(label, value, unit, status, infoKey, rawValue) {
    var color = srv_getStatusColor(status);
    var clickable = srv_isClickable(infoKey);
    var attrs = srv_clickAttrs(infoKey, rawValue || 0);
    var frameClass = (status !== 'healthy') ? ' srv-card-' + status : '';
    var cls = 'srv-metric-widget' + frameClass + (clickable ? ' srv-clickable' : '');
    return '<div class="' + cls + '"' + attrs + '>' +
        '<div class="srv-metric-header"><div class="srv-metric-label">' + label + '</div>' + srv_createInfoButton(infoKey) + '</div>' +
        '<div class="srv-metric-value" style="color:' + color + ';margin-top:20px;">' + value + '</div>' +
        '<div class="srv-metric-unit">' + unit + '</div>' +
        '<div class="srv-metric-status srv-status-' + status + '">' + srv_getStatusText(status) + '</div></div>';
}

/* Builds the segmented bar gauge markup. */
function srv_createSegmentedGauge(value, status, numSegments, maxValue) {
    numSegments = numSegments || 40;
    maxValue = maxValue || (srv_thresholds.ple.warning * 2.5);
    var fillRatio = Math.min(value / maxValue, 1);
    var filledCount = Math.round(fillRatio * numSegments);
    var html = '<div class="srv-segment-bar">';
    for (var i = 0; i < numSegments; i++) {
        html += '<div class="srv-segment' + (i < filledCount ? ' srv-active-' + status : '') + '"></div>';
    }
    return html + '</div>';
}

/* Builds a metric widget with a segmented bar gauge. */
function srv_createSegmentedWidget(label, value, unit, status, infoKey, rawValue, numSegments, maxValue) {
    var color = srv_getStatusColor(status);
    var clickable = srv_isClickable(infoKey);
    var attrs = srv_clickAttrs(infoKey, rawValue || 0);
    var frameClass = (status !== 'healthy') ? ' srv-card-' + status : '';
    var cls = 'srv-metric-widget' + frameClass + (clickable ? ' srv-clickable' : '');
    return '<div class="' + cls + '"' + attrs + '>' +
        '<div class="srv-metric-header"><div class="srv-metric-label">' + label + '</div>' + srv_createInfoButton(infoKey) + '</div>' +
        srv_createSegmentedGauge(rawValue, status, numSegments, maxValue) +
        '<div class="srv-metric-value" style="color:' + color + ';">' + value + '</div>' +
        '<div class="srv-metric-unit">' + unit + '</div>' +
        '<div class="srv-metric-status srv-status-' + status + '">' + srv_getStatusText(status) + '</div></div>';
}

/* Builds the speedometer gauge SVG markup. */
function srv_createSpeedometerGauge(percentage, status) {
    var rotation = (percentage / 100) * 180 - 90;
    return '<div class="srv-speedometer"><svg class="srv-speedometer-svg" viewBox="0 0 140 85">' +
        '<path class="srv-speedo-zone" d="M 20 70 A 50 50 0 0 1 38 28" style="stroke:rgba(244,135,113,0.4);"/>' +
        '<path class="srv-speedo-zone" d="M 38 28 A 50 50 0 0 1 70 20" style="stroke:rgba(220,220,170,0.4);"/>' +
        '<path class="srv-speedo-zone" d="M 70 20 A 50 50 0 0 1 120 70" style="stroke:rgba(78,201,176,0.4);"/>' +
        '<g style="transform-origin:70px 70px;transform:rotate(' + rotation + 'deg);">' +
        '<polygon class="srv-speedo-needle" points="70,70 67,25 73,25"/></g>' +
        '<circle cx="70" cy="70" r="8" class="srv-speedo-center"/>' +
        '<text x="12" y="82" class="srv-speedo-label">0</text><text x="112" y="82" class="srv-speedo-label">100</text>' +
        '</svg></div>';
}

/* Builds a metric widget with a speedometer gauge. */
function srv_createSpeedometerWidget(label, value, unit, status, infoKey, percentage) {
    var color = srv_getStatusColor(status);
    var clickable = srv_isClickable(infoKey);
    var attrs = srv_clickAttrs(infoKey, percentage || 0);
    var frameClass = (status !== 'healthy') ? ' srv-card-' + status : '';
    var cls = 'srv-metric-widget' + frameClass + (clickable ? ' srv-clickable' : '');
    return '<div class="' + cls + '"' + attrs + '>' +
        '<div class="srv-metric-header"><div class="srv-metric-label">' + label + '</div>' + srv_createInfoButton(infoKey) + '</div>' +
        srv_createSpeedometerGauge(percentage, status) +
        '<div class="srv-metric-value" style="color:' + color + ';">' + value + '</div>' +
        '<div class="srv-metric-unit">' + unit + '</div>' +
        '<div class="srv-metric-status srv-status-' + status + '">' + srv_getStatusText(status) + '</div></div>';
}

/* Builds the zombie-count widget (segmented gauge scaled to the crisis level). */
function srv_createZombieWidget(label, value, unit, status, infoKey, rawValue) {
    var maxVal = srv_thresholds.zombies.crisis;
    return srv_createSegmentedWidget(label, value, unit, status, infoKey, rawValue, 40, maxVal);
}

/* ============================================================================
   FUNCTIONS: SERVER SELECTOR
   ----------------------------------------------------------------------------
   The server selector: loading the server list into the header tabs, handling
   a server selection, refreshing the per-server CPU mini gauges, and resolving
   the current server.
   Prefix: srv
   ============================================================================ */

/* Loads the server list and builds the header mini-gauge selector tabs. */
async function srv_loadServers() {
    try {
        var servers = await cc_engineFetch('/api/servers');
        if (!servers) return;
        var tabContainer = document.getElementById('srv-server-tabs');
        if (servers.Error) { tabContainer.innerHTML = '<span class="srv-loading-inline">Error loading servers</span>'; return; }

        srv_serverList = servers;
        srv_currentServer = servers.length > 0 ? servers[0].server_name : null;

        var html = '';
        servers.forEach(function(s, index) {
            var id = 'srv-mg-' + s.server_name.replace(/[^a-zA-Z0-9]/g, '_');
            var sel = index === 0 ? ' srv-selected' : '';
            var nameSel = index === 0 ? ' srv-mini-gauge-name-selected' : '';
            html += '<div class="srv-mini-gauge' + sel + '" data-srv-server="' + s.server_name + '" data-action-click="srv-select-server" data-action-srv-server="' + s.server_name + '">' +
                '<div class="srv-mini-gauge-wrap"><canvas class="srv-mini-gauge-canvas" id="' + id + '" width="60" height="60"></canvas></div>' +
                '<div class="srv-mini-gauge-pct srv-gauge-na" id="' + id + '-pct">-</div>' +
                '<div class="srv-mini-gauge-name' + nameSel + '">' + s.server_name + '</div></div>';
        });
        tabContainer.innerHTML = html;

        if (srv_currentServer) {
            srv_refreshAll();
            srv_refreshServerInfo(srv_currentServer);
        }
    } catch (err) {
        document.getElementById('srv-server-tabs').innerHTML = '<span class="srv-loading-inline">Error loading servers</span>';
    }
}

/* Handles a server selection: updates the active gauge and refreshes the page. */
function srv_selectServer(el) {
    var serverName = el.getAttribute('data-action-srv-server');
    srv_currentServer = serverName;
    document.querySelectorAll('.srv-mini-gauge').forEach(function(g) {
        var isSel = g.getAttribute('data-srv-server') === serverName;
        g.classList.toggle('srv-selected', isSel);
        var nameEl = g.querySelector('.srv-mini-gauge-name');
        if (nameEl) nameEl.classList.toggle('srv-mini-gauge-name-selected', isSel);
    });
    srv_refreshAll();
    srv_refreshServerInfo(serverName);
}

/* Refreshes the per-server CPU mini gauges. */
async function srv_refreshCpuGauges() {
    try {
        var data = await cc_engineFetch('/api/server-health/cpu-gauges');
        if (!data) return;
        if (data.Error || !data.length) return;

        data.forEach(function(s) {
            var id = 'srv-mg-' + s.server_name.replace(/[^a-zA-Z0-9]/g, '_');
            var pctEl = document.getElementById(id + '-pct');
            var canvas = document.getElementById(id);
            if (!canvas) return;

            var pct = s.cpu_pct;
            var color = '#555';

            if (pct === null || pct === undefined) {
                if (pctEl) { pctEl.textContent = 'N/A'; pctEl.className = 'srv-mini-gauge-pct srv-gauge-na'; }
            } else if (pctEl) {
                pctEl.textContent = pct + '%';
                if (pct < 50) { color = '#4ec9b0'; pctEl.className = 'srv-mini-gauge-pct srv-gauge-green'; }
                else if (pct < 80) { color = '#dcdcaa'; pctEl.className = 'srv-mini-gauge-pct srv-gauge-yellow'; }
                else { color = '#f48771'; pctEl.className = 'srv-mini-gauge-pct srv-gauge-red'; }
            }

            var display = Math.min(pct || 0, 100);
            var existing = Chart.getChart(canvas);
            if (existing) existing.destroy();

            srv_miniGaugeCharts[id] = new Chart(canvas.getContext('2d'), {
                type: 'doughnut',
                data: { datasets: [{ data: [display, 100 - display], backgroundColor: [color, '#333'], borderWidth: 0, circumference: 180, rotation: 270 }] },
                options: { responsive: false, cutout: '65%', plugins: { legend: { display: false }, tooltip: { enabled: false } }, animation: { duration: 400 } }
            });
        });
    } catch (err) { /* CPU gauges are non-critical; fail silently */ }
}

/* Resolves the current server, falling back to the primary database server. */
function srv_getCurrentServer() {
    return srv_currentServer || 'DM-PROD-DB';
}

/* ============================================================================
   FUNCTIONS: LIVE SECTIONS
   ----------------------------------------------------------------------------
   The live metric section refreshers driven by the polling timer: memory,
   connections, and current activity. Each fetches its endpoint and renders
   metric widgets into its section container.
   Prefix: srv
   ============================================================================ */

/* Refreshes the memory metrics section. */
async function srv_refreshMemory(server) {
    var container = document.getElementById('srv-memory-metrics');
    try {
        var data = await cc_engineFetch('/api/server-health/memory?server=' + encodeURIComponent(server));
        if (!data) return;
        if (data.Error) { container.innerHTML = '<div class="srv-error">' + data.Error + '</div>'; srv_showError(data.Error); return; }
        if (data.ple === null) { container.innerHTML = '<div class="srv-no-data">No data</div>'; return; }

        container.innerHTML =
            srv_createSegmentedWidget('Page Life Expectancy', srv_formatNumber(data.ple), 'seconds', srv_getStatus(data.ple, 'ple', true), 'ple', data.ple) +
            srv_createSpeedometerWidget('Buffer Cache Hit Ratio', srv_formatDecimal(data.buffer_cache_hit_ratio, 1) + '%', '', srv_getStatus(data.buffer_cache_hit_ratio, 'bufferCache', true), 'bufferCache', data.buffer_cache_hit_ratio) +
            srv_createSimpleWidget('Memory Grants Pending', data.memory_grants_pending, 'queries waiting', srv_getStatus(data.memory_grants_pending, 'memoryGrants', false), 'memoryGrants') +
            srv_createSimpleWidget('Lazy Writes/sec', data.lazy_writes_sec || 0, 'pages flushed', srv_getStatus(data.lazy_writes_sec || 0, 'lazyWrites', false), 'lazyWrites');
    } catch (err) { container.innerHTML = '<div class="srv-error">' + err.message + '</div>'; }
}

/* Refreshes the connections metrics section. */
async function srv_refreshConnections(server) {
    var container = document.getElementById('srv-connection-metrics');
    try {
        var data = await cc_engineFetch('/api/server-health/connections?server=' + encodeURIComponent(server));
        if (!data) return;
        if (data.Error) { container.innerHTML = '<div class="srv-error">' + data.Error + '</div>'; return; }

        var openTransUnit = data.open_trans_count === 0 ? 'none' :
            'SPID ' + data.oldest_open_trans_spid + ' (' + (data.oldest_open_trans_idle_min < 60 ? data.oldest_open_trans_idle_min + 'm' : (data.oldest_open_trans_idle_min / 60).toFixed(1) + 'h') + ' idle)';

        container.innerHTML =
            srv_createSimpleWidget('Active Connections', srv_formatNumber(data.total_connections), 'sessions', 'healthy', 'connections') +
            srv_createSimpleWidget('JDBC Connections', srv_formatNumber(data.jdbc_connections), 'Java sessions', 'healthy', 'jdbcConnections') +
            srv_createZombieWidget('Zombie Connections', data.zombie_count, 'idle JDBC', srv_getStatus(data.zombie_count, 'zombies', false), 'zombies', data.zombie_count) +
            srv_createSimpleWidget('Open Transactions', data.open_trans_count || 0, openTransUnit, srv_getStatus(data.open_trans_count || 0, 'openTransactions', false), 'openTransactions', data.open_trans_count);
    } catch (err) { container.innerHTML = '<div class="srv-error">' + err.message + '</div>'; }
}

/* Refreshes the current activity metrics section. */
async function srv_refreshActivity(server) {
    var container = document.getElementById('srv-activity-metrics');
    try {
        var data = await cc_engineFetch('/api/server-health/activity?server=' + encodeURIComponent(server));
        if (!data) return;
        if (data.Error) { container.innerHTML = '<div class="srv-error">' + data.Error + '</div>'; return; }

        var blockedStatus = srv_getStatus(data.blocked_sessions, 'blockedSessions', false);
        var blockerValue = data.lead_blocker_spid ? 'SPID ' + data.lead_blocker_spid : 'None';
        var blockerUnit = data.lead_blocker_spid ? 'blocking ' + data.blocked_sessions : 'no blocking';
        var waitValue = data.longest_wait_seconds < 60 ? srv_formatDecimal(data.longest_wait_seconds, 1) : srv_formatDecimal(data.longest_wait_seconds / 60, 1);
        var waitUnit = data.longest_wait_seconds === 0 ? 'no waits' : (data.longest_wait_seconds < 60 ? 'seconds' : 'minutes');

        var activeBreakdown = '<span style="color:#4ec9b0">' + (data.running_count || 0) + '</span> running &middot; ' +
                              '<span style="color:#dcdcaa">' + (data.runnable_count || 0) + '</span> runnable &middot; ' +
                              '<span style="color:#f48771">' + (data.suspended_count || 0) + '</span> suspended';

        container.innerHTML =
            srv_createSimpleWidget('Blocked Sessions', data.blocked_sessions, 'waiting', blockedStatus, 'blockedSessions') +
            srv_createSimpleWidget('Lead Blocker', blockerValue, blockerUnit, data.lead_blocker_spid ? blockedStatus : 'healthy', 'leadBlocker') +
            srv_createSimpleWidget('Longest Wait', waitValue, waitUnit, 'healthy', 'longestWait') +
            srv_createSimpleWidget('Active Requests', data.active_requests, activeBreakdown, 'healthy', 'activeRequests');
    } catch (err) { container.innerHTML = '<div class="srv-error">' + err.message + '</div>'; }
}

/* ============================================================================
   FUNCTIONS: SERVER INFO AND DISK
   ----------------------------------------------------------------------------
   The right-column info panels: the server info properties and the disk space
   per-drive usage bars.
   Prefix: srv
   ============================================================================ */

/* Refreshes the server info panel. */
async function srv_refreshServerInfo(server) {
    var container = document.getElementById('srv-server-info');
    try {
        var data = await cc_engineFetch('/api/server-health/info?server=' + encodeURIComponent(server));
        if (!data) return;
        if (data.Error) { container.innerHTML = '<div class="srv-error">Error</div>'; return; }

        container.innerHTML =
            '<div class="srv-server-name-header">' + server + '</div>' +
            '<div class="srv-info-row"><span class="srv-info-label">Version</span><span class="srv-info-value">' + data.version_short + '</span></div>' +
            '<div class="srv-info-row"><span class="srv-info-label">Edition</span><span class="srv-info-value">' + data.edition + '</span></div>' +
            '<div class="srv-info-row"><span class="srv-info-label">Memory</span><span class="srv-info-value">' + data.total_memory_gb + ' GB</span></div>' +
            '<div class="srv-info-row"><span class="srv-info-label">CPUs</span><span class="srv-info-value">' + data.cpu_count + '</span></div>' +
            '<div class="srv-info-row"><span class="srv-info-label">Uptime</span><span class="srv-info-value">' + data.uptime + '</span></div>' +
            '<div class="srv-info-row"><span class="srv-info-label">AG Role</span><span class="srv-info-value ' + (data.ag_role === 'PRIMARY' ? 'srv-value-primary' : 'srv-value-secondary') + '">' + (data.ag_role || 'N/A') + '</span></div>';
    } catch (err) { container.innerHTML = '<div class="srv-error">' + err.message + '</div>'; }
}

/* Refreshes the disk space panel. */
async function srv_refreshDiskSpace(server) {
    var container = document.getElementById('srv-disk-space');
    try {
        var data = await cc_engineFetch('/api/server-health/disks?server=' + encodeURIComponent(server));
        if (!data) return;
        if (data.Error) { container.innerHTML = '<div class="srv-error">Disk unavailable</div>'; return; }
        if (!data || data.length === 0) { container.innerHTML = '<div class="srv-no-data">No disk data</div>'; return; }

        container.innerHTML = data.map(function(disk) {
            var status = disk.used_pct >= 95 ? 'crisis' : (disk.used_pct >= 90 ? 'critical' : (disk.used_pct >= 80 ? 'warning' : 'healthy'));
            var segments = '';
            for (var i = 0; i < 40; i++) {
                segments += '<div class="srv-disk-segment' + (i < Math.round(disk.used_pct / 100 * 40) ? ' srv-active-' + status : '') + '"></div>';
            }
            return '<div class="srv-disk-item"><div class="srv-disk-header"><span class="srv-disk-label">' + disk.drive + '</span><span class="srv-disk-free">' + disk.free_display + ' free</span></div><div class="srv-disk-segment-bar">' + segments + '</div></div>';
        }).join('');
    } catch (err) { container.innerHTML = '<div class="srv-error">' + err.message + '</div>'; }
}

/* ============================================================================
   FUNCTIONS: AG HEALTH
   ----------------------------------------------------------------------------
   The availability group health panel and its replica detail slideout: the
   summary card, the replica-and-detail open/close/refresh handlers, and the
   replica detail loader rendering per-database synchronization metrics.
   Prefix: srv
   ============================================================================ */

/* Refreshes the AG health summary panel. */
async function srv_refreshAGHealth(server) {
    var container = document.getElementById('srv-ag-health');
    try {
        var data = await cc_engineFetch('/api/server-health/ag-status?server=' + encodeURIComponent(server));
        if (!data) return;
        if (data.Error) { container.innerHTML = '<div class="srv-ag-not-available">AG data unavailable</div>'; return; }
        if (!data.is_ag_member) { container.innerHTML = '<div class="srv-ag-not-available">Not in Availability Group</div>'; return; }

        var primary = null;
        var secondary = null;
        if (data.replicas && data.replicas.length > 0) {
            data.replicas.forEach(function(r) {
                if (r.role === 'PRIMARY') primary = r;
                else if (r.role === 'SECONDARY') secondary = r;
            });
        }

        var syncClass = data.ag_sync_health === 'HEALTHY' ? 'healthy' :
                       (data.ag_sync_health === 'PARTIALLY_HEALTHY' ? 'warning' : 'critical');
        var cardClass = 'srv-ag-summary-card' + (syncClass !== 'healthy' ? ' srv-card-' + syncClass : '');

        var primaryServer = primary ? primary.server_name : 'Unknown';
        var secondaryServer = secondary ? secondary.server_name : 'Unknown';

        container.innerHTML = '<div class="' + cardClass + '">' +
            '<div class="srv-ag-summary-row">' +
                '<span class="srv-ag-summary-label">Primary</span>' +
                '<span class="srv-ag-summary-value srv-ag-summary-link" data-action-click="srv-select-replica-detail" data-action-srv-server="' + primaryServer + '">' + primaryServer + '</span>' +
            '</div>' +
            '<div class="srv-ag-summary-row">' +
                '<span class="srv-ag-summary-label">Secondary</span>' +
                '<span class="srv-ag-summary-value srv-ag-summary-link" data-action-click="srv-select-replica-detail" data-action-srv-server="' + secondaryServer + '">' + secondaryServer + '</span>' +
            '</div>' +
            '<div class="srv-ag-summary-row">' +
                '<span class="srv-ag-summary-label">Sync Health</span>' +
                '<span class="srv-ag-summary-badge srv-badge-' + syncClass + '">' + (data.ag_sync_health || 'Unknown') + '</span>' +
            '</div>' +
            '</div>';
    } catch (err) {
        container.innerHTML = '<div class="srv-ag-not-available">AG data unavailable</div>';
    }
}

/* Switches to a replica and opens its detail slideout. */
function srv_selectReplicaAndShowDetail(el) {
    var serverName = el.getAttribute('data-action-srv-server');
    if (srv_currentServer !== serverName) {
        srv_currentServer = serverName;
        document.querySelectorAll('.srv-mini-gauge').forEach(function(g) {
            var isSel = g.getAttribute('data-srv-server') === serverName;
            g.classList.toggle('srv-selected', isSel);
            var nameEl = g.querySelector('.srv-mini-gauge-name');
            if (nameEl) nameEl.classList.toggle('srv-mini-gauge-name-selected', isSel);
        });
        srv_refreshAll();
        srv_refreshServerInfo(serverName);
    }
    srv_openAGDetailPanel(serverName);
}

/* Opens the AG replica detail slideout for a server. */
function srv_openAGDetailPanel(serverName) {
    srv_currentAGDetailServer = serverName;
    srv_openSlide('srv-slideout-ag-detail');
    document.getElementById('srv-ag-detail-server').textContent = '(' + serverName + ')';
    srv_loadAGReplicaDetail(serverName);
}

/* Closes the AG replica detail slideout. */
function srv_closeAGDetailPanel(target, event) {
    if (srv_ignoreSlideClick('srv-slideout-ag-detail', target, event)) return;
    srv_closeSlide('srv-slideout-ag-detail');
    srv_currentAGDetailServer = null;
}

/* Reloads the AG replica detail for the open server. */
function srv_refreshAGDetailPanel() {
    if (srv_currentAGDetailServer) srv_loadAGReplicaDetail(srv_currentAGDetailServer);
}

/* Loads and renders the AG replica detail content. */
async function srv_loadAGReplicaDetail(serverName) {
    var body = document.getElementById('srv-ag-detail-panel-body');
    body.innerHTML = '<div class="srv-loading">Loading...</div>';
    try {
        var data = await cc_engineFetch('/api/server-health/ag-replica-detail?server=' + encodeURIComponent(serverName));
        if (!data) return;
        if (data.Error) { body.innerHTML = '<div class="srv-error">Error: ' + data.Error + '</div>'; return; }

        var html = '';
        if (data.replica) {
            var r = data.replica;
            var roleClass = r.role === 'PRIMARY' ? 'srv-role-primary' : 'srv-role-secondary';
            var healthClass = r.sync_health === 'HEALTHY' ? 'srv-badge-healthy' :
                             (r.sync_health === 'PARTIALLY_HEALTHY' ? 'srv-badge-warning' : 'srv-badge-critical');
            html += '<div class="srv-ag-detail-summary">' +
                '<div class="srv-ag-detail-role ' + roleClass + '">' + r.role + '</div>' +
                '<div class="srv-ag-detail-health ' + healthClass + '">' + r.sync_health + '</div>' +
                '</div>';
            html += '<div class="srv-ag-detail-info">' +
                '<div class="srv-ag-detail-row"><span>AG Name:</span><span>' + (r.ag_name || '-') + '</span></div>' +
                '<div class="srv-ag-detail-row"><span>Operational State:</span><span>' + (r.operational_state || '-') + '</span></div>' +
                '<div class="srv-ag-detail-row"><span>Connected State:</span><span>' + (r.connected_state || '-') + '</span></div>' +
                '<div class="srv-ag-detail-row"><span>Recovery Health:</span><span>' + (r.recovery_health || '-') + '</span></div>' +
                '<div class="srv-ag-detail-row"><span>Page Life Expectancy:</span><span class="srv-stat-value">' + srv_formatNumber(data.ple) + ' sec</span></div>' +
                '</div>';
        }

        if (data.databases && data.databases.length > 0) {
            html += '<div class="srv-ag-databases-header">Database Details</div>';
            data.databases.forEach(function(db) {
                var dbHealthClass = db.sync_health === 'HEALTHY' ? 'srv-badge-healthy' :
                                   (db.sync_health === 'PARTIALLY_HEALTHY' ? 'srv-badge-warning' : 'srv-badge-critical');
                var suspendedBadge = db.is_suspended ?
                    '<span class="srv-suspended-badge">SUSPENDED' + (db.suspend_reason ? ': ' + db.suspend_reason : '') + '</span>' : '';

                html += '<div class="srv-ag-database-card">' +
                    '<div class="srv-ag-database-header">' +
                    '<span class="srv-ag-database-name">' + db.database_name + '</span>' +
                    '<span class="srv-ag-database-state ' + dbHealthClass + '">' + db.sync_state + '</span>' +
                    '</div>' +
                    suspendedBadge +
                    '<div class="srv-ag-database-metrics">' +
                    '<div class="srv-ag-metric"><span class="srv-ag-metric-label">Send Queue:</span><span class="srv-ag-metric-value">' + srv_formatBytes(db.log_send_queue_kb) + '</span></div>' +
                    '<div class="srv-ag-metric"><span class="srv-ag-metric-label">Send Rate:</span><span class="srv-ag-metric-value">' + srv_formatBytes(db.log_send_rate_kbps) + '/s</span></div>' +
                    '<div class="srv-ag-metric"><span class="srv-ag-metric-label">Redo Queue:</span><span class="srv-ag-metric-value">' + srv_formatBytes(db.redo_queue_kb) + '</span></div>' +
                    '<div class="srv-ag-metric"><span class="srv-ag-metric-label">Redo Rate:</span><span class="srv-ag-metric-value">' + srv_formatBytes(db.redo_rate_kbps) + '/s</span></div>' +
                    (db.estimated_catchup_seconds !== null ? '<div class="srv-ag-metric"><span class="srv-ag-metric-label">Est. Catchup:</span><span class="srv-ag-metric-value">' + srv_formatDuration(db.estimated_catchup_seconds) + '</span></div>' : '') +
                    '</div>' +
                    '<div class="srv-ag-database-times">' +
                    '<div>Last Commit: ' + (db.last_commit_time || '-') + '</div>' +
                    '<div>Last Hardened: ' + (db.last_hardened_time || '-') + '</div>' +
                    '<div>Last Redone: ' + (db.last_redone_time || '-') + '</div>' +
                    '</div>' +
                    '</div>';
            });
        }

        body.innerHTML = html || '<div class="srv-no-data">No AG data available</div>';
    } catch (err) {
        body.innerHTML = '<div class="srv-error">Error: ' + err.message + '</div>';
    }
}

/* ============================================================================
   FUNCTIONS: XE ACTIVITY
   ----------------------------------------------------------------------------
   The Extended Events activity section: the activity-card refresher that
   renders the seven category cards, and the dispatcher that opens the matching
   detail slideout when a card is clicked.
   Prefix: srv
   ============================================================================ */

/* Refreshes the Extended Events activity cards. */
async function srv_refreshXEActivity(server) {
    var container = document.getElementById('srv-xe-activity');
    try {
        var data = await cc_engineFetch('/api/server-health/xe-activity?server=' + encodeURIComponent(server) + '&minutes=' + srv_xeActivityWindowMinutes);
        if (!data) return;
        if (data.Error) { container.innerHTML = '<div class="srv-error">XE data unavailable</div>'; return; }

        var lrqClass = data.lrq_count > 10 ? 'critical' : (data.lrq_count > 5 ? 'warning' : '');
        var blockingClass = data.blocking_count > 5 ? 'critical' : (data.blocking_count > 0 ? 'warning' : '');
        var deadlockClass = data.deadlock_count > 0 ? 'critical' : '';
        var lsInClass = data.ls_inbound_count > 50 ? 'warning' : '';
        var lsOutClass = data.ls_outbound_count > 50 ? 'warning' : '';
        var agClass = data.ag_events_count > 0 ? 'warning' : '';
        var sysClass = '';

        var timeLabel = '<div class="srv-xe-card-time">Last ' + srv_xeActivityWindowMinutes + ' min</div>';

        container.innerHTML =
            srv_xeCard(lrqClass, 'lrq', 'Long Running Queries', data.lrq_count, timeLabel) +
            srv_xeCard(blockingClass, 'blocking', 'Blocking', data.blocking_count, timeLabel) +
            srv_xeCard(deadlockClass, 'deadlock', 'Deadlocks', data.deadlock_count, timeLabel) +
            srv_xeCard(lsInClass, 'ls_inbound', 'Linked Server Inbound', data.ls_inbound_count, timeLabel) +
            srv_xeCard(lsOutClass, 'ls_outbound', 'Linked Server Outbound', data.ls_outbound_count, timeLabel) +
            srv_xeCard(agClass, 'ag_health', 'AG Events', data.ag_events_count, timeLabel) +
            srv_xeCard(sysClass, 'system_health', 'System Health', data.system_health_count, timeLabel);
    } catch (err) {
        container.innerHTML = '<div class="srv-error">XE data unavailable</div>';
    }
}

/* Builds a single Extended Events activity card. */
function srv_xeCard(cls, eventType, label, count, timeLabel) {
    var frame = cls === 'critical' ? ' srv-card-critical' : (cls === 'warning' ? ' srv-card-warning' : '');
    var valueClass = cls === 'critical' ? ' srv-card-critical' : (cls === 'warning' ? ' srv-card-warning' : '');
    return '<div class="srv-xe-card' + frame + '" data-action-click="srv-open-xe-detail" data-action-srv-event="' + eventType + '">' +
        '<div class="srv-xe-card-label">' + label + '</div>' +
        '<div class="srv-xe-card-value' + valueClass + '">' + (count || 0) + '</div>' +
        timeLabel +
        '</div>';
}

/* Opens the detail slideout matching the clicked activity card. */
function srv_openXEDetail(el) {
    var eventType = el.getAttribute('data-action-srv-event');
    switch (eventType) {
        case 'lrq': srv_openXELRQPanel(); break;
        case 'blocking': srv_openXEBlockingPanel(); break;
        case 'deadlock': srv_openXEDeadlockPanel(); break;
        case 'ls_inbound': srv_openXELSInboundPanel(); break;
        case 'ls_outbound': srv_openXELSOutboundPanel(); break;
        case 'ag_health': srv_openXEAGEventsPanel(); break;
        case 'system_health': srv_openXESystemHealthPanel(); break;
        default: break;
    }
}

/* ============================================================================
   FUNCTIONS: ZOMBIE MODAL
   ----------------------------------------------------------------------------
   The shared overlay open/close helpers and the zombie-kill modal: opening the
   confirmation, closing it with a backdrop guard, and executing the kill with
   a success or error result.
   Prefix: srv
   ============================================================================ */

/* Opens a static slide overlay using the shared cc-open mechanics. */
function srv_openSlide(id) {
    var overlay = document.getElementById(id);
    overlay.classList.add('cc-open');
    requestAnimationFrame(function() {
        var dialog = overlay.querySelector('.cc-dialog');
        if (dialog) dialog.classList.add('cc-open');
    });
}

/* Closes a static slide overlay, animating the dialog out before hiding. */
function srv_closeSlide(id) {
    var overlay = document.getElementById(id);
    var dialog = overlay.querySelector('.cc-dialog');
    if (dialog) {
        dialog.addEventListener('transitionend', function() {
            overlay.classList.remove('cc-open');
        }, { once: true });
        dialog.classList.remove('cc-open');
    } else {
        overlay.classList.remove('cc-open');
    }
}

/* Reports whether a slide-overlay click is an interior click to be ignored. */
function srv_ignoreSlideClick(id, target, event) {
    return event && target.id === id && event.target !== target;
}

/* Reports whether a modal-overlay click is an interior click to be ignored. */
function srv_ignoreModalClick(id, target, event) {
    return event && target.id === id && event.target !== target;
}

/* Opens the zombie-kill confirmation modal. */
function srv_openZombieModal(el) {
    var count = el.getAttribute('data-action-srv-count');
    var server = srv_getCurrentServer();
    document.getElementById('srv-zombie-modal-body').innerHTML =
        '<div class="srv-zombie-icon">&#129503;&#128299;</div>' +
        '<div class="srv-zombie-message">Are you sure you want to eradicate <span class="srv-zombie-count" id="srv-zombie-kill-count">' + count + '</span> zombies?</div>' +
        '<div class="srv-zombie-threshold" id="srv-zombie-threshold-info">JDBC connections idle &gt; ' + srv_thresholds.zombieIdleMinutes + ' minutes on ' + server + '</div>';
    document.getElementById('srv-zombie-modal-footer').innerHTML =
        '<button class="cc-dialog-btn-cancel" data-action-click="srv-close-zombie-modal">Never Mind</button>' +
        '<button class="cc-dialog-btn-danger" data-action-click="srv-execute-zombie-kill">&#128299; Double Tap Them</button>';
    document.getElementById('srv-modal-zombie').classList.remove('cc-hidden');
}

/* Closes the zombie-kill modal, ignoring interior clicks. */
function srv_closeZombieModal(target, event) {
    if (srv_ignoreModalClick('srv-modal-zombie', target, event)) return;
    document.getElementById('srv-modal-zombie').classList.add('cc-hidden');
}

/* Executes the zombie kill and reports the result. */
async function srv_executeZombieKill() {
    var server = srv_getCurrentServer();
    var body = document.getElementById('srv-zombie-modal-body');
    var footer = document.getElementById('srv-zombie-modal-footer');
    footer.innerHTML = '<button class="cc-dialog-btn-cancel" disabled>Executing...</button>';
    try {
        var result = await cc_engineFetch('/api/server-health/kill-zombies?server=' + encodeURIComponent(server), { method: 'POST' });
        if (!result) {
            footer.innerHTML = '<button class="cc-dialog-btn-cancel" data-action-click="srv-close-zombie-modal">Close</button>';
            return;
        }
        if (result.Error) {
            body.innerHTML = '<div class="srv-result-error"><div class="srv-result-icon">&#128128;</div>Error: ' + result.Error + '</div>';
        } else {
            body.innerHTML = '<div class="srv-result-success"><div class="srv-result-icon">&#9989;</div>Successfully eradicated <span class="srv-zombie-count">' + result.killed_count + '</span> zombies!</div>';
            setTimeout(function() { srv_refreshConnections(server); }, 1000);
        }
        footer.innerHTML = '<button class="cc-dialog-btn-cancel" data-action-click="srv-close-zombie-modal">Close</button>';
    } catch (err) {
        body.innerHTML = '<div class="srv-result-error">Failed: ' + err.message + '</div>';
        footer.innerHTML = '<button class="cc-dialog-btn-cancel" data-action-click="srv-close-zombie-modal">Close</button>';
    }
}

/* ============================================================================
   FUNCTIONS: OPEN TRANSACTIONS PANEL
   ----------------------------------------------------------------------------
   The open transactions slideout: opening and closing it, loading the open
   transaction rows into a table, and copying a KILL script for them.
   Prefix: srv
   ============================================================================ */

/* Opens the open transactions slideout. */
function srv_openTransPanel() {
    srv_openSlide('srv-slideout-trans');
    srv_loadOpenTransactions();
}

/* Closes the open transactions slideout, ignoring interior clicks. */
function srv_closeTransPanel(target, event) {
    if (srv_ignoreSlideClick('srv-slideout-trans', target, event)) return;
    srv_closeSlide('srv-slideout-trans');
}

/* Loads and renders the open transactions table. */
async function srv_loadOpenTransactions() {
    var server = srv_getCurrentServer();
    var body = document.getElementById('srv-trans-panel-body');
    body.innerHTML = '<div class="srv-loading">Loading...</div>';
    try {
        var data = await cc_engineFetch('/api/server-health/open-transactions?server=' + encodeURIComponent(server));
        if (!data) return;
        if (data.Error) { body.innerHTML = '<div class="srv-error">Error: ' + data.Error + '</div>'; return; }
        srv_openTransData = data;
        if (!data || data.length === 0) { body.innerHTML = '<div class="srv-no-data">No open transactions found.</div>'; return; }

        var html = '<table class="srv-trans-table"><thead><tr><th class="srv-trans-th">SPID</th><th class="srv-trans-th">Login</th><th class="srv-trans-th">Program</th><th class="srv-trans-th">Host</th><th class="srv-trans-th">DB</th><th class="srv-trans-th">Idle</th></tr></thead><tbody>';
        for (var i = 0; i < data.length; i++) {
            var row = data[i];
            var idleClass = row.idle_minutes > 60 ? 'srv-idle-critical' : (row.idle_minutes > 15 ? 'srv-idle-warning' : '');
            var idleDisplay = row.idle_minutes < 60 ? row.idle_minutes + 'm' : (row.idle_minutes / 60).toFixed(1) + 'h';
            html += '<tr class="srv-trans-row"><td class="srv-trans-td srv-trans-spid">' + row.session_id + '</td>' +
                '<td class="srv-trans-td">' + (row.login_name || '-') + '</td>' +
                '<td class="srv-trans-td">' + ((row.program_name || '-').substring(0, 20)) + '</td>' +
                '<td class="srv-trans-td">' + (row.host_name || '-') + '</td>' +
                '<td class="srv-trans-td">' + (row.database_name || '-') + '</td>' +
                '<td class="srv-trans-td ' + idleClass + '">' + idleDisplay + '</td></tr>';
        }
        body.innerHTML = html + '</tbody></table>';
    } catch (err) {
        body.innerHTML = '<div class="srv-error">Error: ' + err.message + '</div>';
    }
}

/* Copies a KILL script for the open transactions to the clipboard. */
function srv_copyKillScript() {
    if (!srv_openTransData || srv_openTransData.length === 0) {
        cc_showAlert('No open transactions to generate a KILL script for.', { title: 'Nothing to Copy' });
        return;
    }
    var script = '-- Kill script for open transactions\n-- Server: ' + srv_getCurrentServer() + '\n\n';
    srv_openTransData.forEach(function(r) { script += 'KILL ' + r.session_id + '; -- ' + (r.login_name || '') + '\n'; });
    srv_copyToClipboard(script, 'KILL script copied to clipboard.');
}

/* ============================================================================
   FUNCTIONS: BLOCKING PANEL
   ----------------------------------------------------------------------------
   The live blocking details slideout: opening and closing it, loading the
   lead-blocker and blocked-session cards, and copying a KILL script for the
   lead blockers.
   Prefix: srv
   ============================================================================ */

/* Opens the blocking details slideout. */
function srv_openBlockingPanel() {
    srv_openSlide('srv-slideout-blocking');
    srv_loadBlockingDetails();
}

/* Closes the blocking details slideout, ignoring interior clicks. */
function srv_closeBlockingPanel(target, event) {
    if (srv_ignoreSlideClick('srv-slideout-blocking', target, event)) return;
    srv_closeSlide('srv-slideout-blocking');
}

/* Loads and renders the blocking details. */
async function srv_loadBlockingDetails() {
    var server = srv_getCurrentServer();
    var body = document.getElementById('srv-blocking-panel-body');
    body.innerHTML = '<div class="srv-loading">Loading...</div>';
    try {
        var data = await cc_engineFetch('/api/server-health/blocking-details?server=' + encodeURIComponent(server));
        if (!data) return;
        if (data.Error) { body.innerHTML = '<div class="srv-error">Error: ' + data.Error + '</div>'; return; }
        srv_blockingData = data;
        if ((!data.blockers || data.blockers.length === 0) && (!data.blocked || data.blocked.length === 0)) {
            body.innerHTML = '<div class="srv-no-data">No blocking detected.</div>';
            return;
        }

        var html = '';
        if (data.blockers && data.blockers.length > 0) {
            html += '<div class="srv-blocker-section"><div class="srv-blocker-section-title">Lead Blocker' + (data.blockers.length > 1 ? 's' : '') + '</div>';
            data.blockers.forEach(function(b) {
                var statusClass = b.status === 'sleeping' ? ' srv-status-sleeping' : '';
                html += '<div class="srv-blocker-card srv-lead-blocker">' +
                    '<div class="srv-blocker-header">' +
                    '<span class="srv-blocker-spid">SPID ' + b.spid + '</span>' +
                    '<span class="srv-blocker-status' + statusClass + '">' + (b.status || 'unknown') + '</span>' +
                    '</div>' +
                    '<div class="srv-blocker-details">' +
                    'Login: <span class="srv-detail-value">' + (b.login_name || '-') + '</span><br>' +
                    'Host: <span class="srv-detail-value">' + (b.host_name || '-') + '</span><br>' +
                    'Program: <span class="srv-detail-value">' + (b.program_name || '-').substring(0, 40) + '</span><br>' +
                    'Database: <span class="srv-detail-value">' + (b.database_name || '-') + '</span>' +
                    (b.duration_seconds ? '<br>Duration: <span class="srv-detail-value">' + srv_formatDuration(b.duration_seconds) + '</span>' : '') +
                    '</div>' +
                    (b.query_text ? '<div class="srv-blocker-query">' + cc_escapeHtml(b.query_text) + '</div>' : '') +
                    '</div>';
            });
            html += '</div>';
        }

        if (data.blocked && data.blocked.length > 0) {
            html += '<div class="srv-blocker-section srv-section-blocked"><div class="srv-blocker-section-title srv-blocker-section-title-blocked">Blocked Sessions (' + data.blocked.length + ')</div>';
            data.blocked.forEach(function(b) {
                html += '<div class="srv-blocker-card">' +
                    '<div class="srv-blocker-header">' +
                    '<span class="srv-blocker-spid">SPID ' + b.spid + '</span>' +
                    '<span class="srv-wait-info">' + srv_formatDuration(b.wait_seconds) + ' wait</span>' +
                    '</div>' +
                    '<div class="srv-blocked-by">Blocked by: <span class="srv-blocked-by-value">SPID ' + b.blocker_spid + '</span></div>' +
                    '<div class="srv-blocker-details">' +
                    'Login: <span class="srv-detail-value">' + (b.login_name || '-') + '</span><br>' +
                    'Host: <span class="srv-detail-value">' + (b.host_name || '-') + '</span><br>' +
                    'Database: <span class="srv-detail-value">' + (b.database_name || '-') + '</span><br>' +
                    'Wait Type: <span class="srv-detail-value">' + (b.wait_type || '-') + '</span>' +
                    '</div>' +
                    (b.query_text ? '<div class="srv-blocker-query">' + cc_escapeHtml(b.query_text) + '</div>' : '') +
                    '</div>';
            });
            html += '</div>';
        }

        body.innerHTML = html;
    } catch (err) {
        body.innerHTML = '<div class="srv-error">Error: ' + err.message + '</div>';
    }
}

/* Copies a KILL script for the lead blockers to the clipboard. */
function srv_copyBlockerKillScript() {
    if (!srv_blockingData.blockers || srv_blockingData.blockers.length === 0) {
        cc_showAlert('No lead blockers to generate a KILL script for.', { title: 'Nothing to Copy' });
        return;
    }
    var script = '-- Kill script for lead blockers\n-- Server: ' + srv_getCurrentServer() + '\n-- WARNING: Review before executing!\n\n';
    srv_blockingData.blockers.forEach(function(b) { script += 'KILL ' + b.spid + '; -- ' + (b.login_name || '') + ' - ' + (b.program_name || '') + '\n'; });
    srv_copyToClipboard(script, 'KILL script copied to clipboard.');
}

/* ============================================================================
   FUNCTIONS: ACTIVE REQUESTS PANEL
   ----------------------------------------------------------------------------
   The active requests slideout: opening, closing, refreshing, and loading the
   currently executing requests with their status breakdown and per-request
   detail cards.
   Prefix: srv
   ============================================================================ */

/* Opens the active requests slideout. */
function srv_openRequestsPanel() {
    srv_openSlide('srv-slideout-requests');
    srv_loadActiveRequests();
}

/* Closes the active requests slideout, ignoring interior clicks. */
function srv_closeRequestsPanel(target, event) {
    if (srv_ignoreSlideClick('srv-slideout-requests', target, event)) return;
    srv_closeSlide('srv-slideout-requests');
}

/* Reloads the active requests list. */
function srv_refreshActiveRequests() {
    srv_loadActiveRequests();
}

/* Loads and renders the active requests. */
async function srv_loadActiveRequests() {
    var server = srv_getCurrentServer();
    var body = document.getElementById('srv-requests-panel-body');
    body.innerHTML = '<div class="srv-loading">Loading...</div>';
    try {
        var data = await cc_engineFetch('/api/server-health/active-requests?server=' + encodeURIComponent(server));
        if (!data) return;
        if (data.Error) { body.innerHTML = '<div class="srv-error">Error: ' + data.Error + '</div>'; return; }
        if (!data || data.length === 0) { body.innerHTML = '<div class="srv-no-data">No active requests at this moment.</div>'; return; }

        var running = data.filter(function(r) { return r.status === 'running'; }).length;
        var runnable = data.filter(function(r) { return r.status === 'runnable'; }).length;
        var suspended = data.filter(function(r) { return r.status === 'suspended'; }).length;

        var html = '<div class="srv-panel-summary">' +
            data.length + ' active request' + (data.length !== 1 ? 's' : '') +
            ' <span style="color:#4ec9b0;">(' + running + ' running</span>, ' +
            '<span style="color:#dcdcaa;">' + runnable + ' runnable</span>, ' +
            '<span style="color:#f48771;">' + suspended + ' suspended</span>)' +
            '</div>';

        data.forEach(function(r) {
            var cardClass = 'srv-request-card';
            var durationClass = '';
            if (r.duration_seconds > 300) { cardClass += ' srv-very-long-running'; durationClass = ' srv-duration-critical'; }
            else if (r.duration_seconds > 60) { cardClass += ' srv-long-running'; durationClass = ' srv-duration-warning'; }

            var statusColor = '#4ec9b0';
            if (r.status === 'runnable') statusColor = '#dcdcaa';
            else if (r.status === 'suspended') statusColor = '#f48771';

            html += '<div class="' + cardClass + '">' +
                '<div class="srv-request-header">' +
                '<span class="srv-request-spid">SPID ' + r.session_id + ' <span style="color:' + statusColor + ';font-weight:500;text-transform:uppercase;font-size:10px;margin-left:6px;">' + (r.status || 'unknown') + '</span></span>' +
                '<span class="srv-request-duration' + durationClass + '">' + srv_formatDuration(r.duration_seconds) + '</span>' +
                '</div>' +
                '<div class="srv-request-details">' +
                'Login: <span class="srv-detail-value">' + (r.login_name || '-') + '</span><br>' +
                'Host: <span class="srv-detail-value">' + (r.host_name || '-') + '</span><br>' +
                'Program: <span class="srv-detail-value">' + (r.program_name || '-').substring(0, 40) + '</span><br>' +
                'Database: <span class="srv-detail-value">' + (r.database_name || '-') + '</span> | ' +
                'Command: <span class="srv-detail-value">' + (r.command || '-') + '</span>' +
                '</div>' +
                '<div class="srv-request-stats">' +
                '<span>CPU: <span class="srv-stat-value">' + srv_formatNumber(r.cpu_time) + 'ms</span></span>' +
                '<span>Reads: <span class="srv-stat-value">' + srv_formatNumber(r.logical_reads) + '</span></span>' +
                '<span>Writes: <span class="srv-stat-value">' + srv_formatNumber(r.writes) + '</span></span>' +
                '</div>';

            if (r.wait_type) {
                var waitClass = r.blocking_session_id ? ' srv-wait-blocked' : '';
                html += '<div class="srv-request-wait' + waitClass + '">' +
                    'Waiting: ' + r.wait_type + ' (' + srv_formatDuration(r.wait_seconds) + ')' +
                    (r.blocking_session_id ? ' - Blocked by SPID ' + r.blocking_session_id : '') +
                    '</div>';
            }
            if (r.query_text) {
                html += '<div class="srv-request-query">' + cc_escapeHtml(r.query_text) + '</div>';
            }
            html += '</div>';
        });

        body.innerHTML = html;
    } catch (err) {
        body.innerHTML = '<div class="srv-error">Error: ' + err.message + '</div>';
    }
}

/* ============================================================================
   FUNCTIONS: TREND MODAL
   ----------------------------------------------------------------------------
   The metric trend modal: opening it for a metric, selecting a range, closing
   it, loading the trend data, and rendering the trend line chart.
   Prefix: srv
   ============================================================================ */

/* Opens the trend modal for a metric and loads the default 24h range. */
function srv_openTrendModal(el) {
    var infoKey = el.getAttribute('data-action-srv-info');
    var metric = el.getAttribute('data-action-srv-metric');
    var server = srv_getCurrentServer();
    var info = srv_metricInfo[infoKey];
    srv_currentTrendMetric = metric;
    srv_currentTrendHours = 24;

    document.getElementById('srv-trend-modal-title').textContent = info.title + ' Trend';
    document.getElementById('srv-trend-metric-name').textContent = info.title;

    document.querySelectorAll('#srv-modal-trend .srv-trend-range-btn').forEach(function(btn) {
        btn.classList.toggle('srv-active', btn.getAttribute('data-action-srv-hours') === '24');
    });

    document.getElementById('srv-modal-trend').classList.remove('cc-hidden');
    srv_loadTrendData(metric, server, 24);
}

/* Selects a trend range and reloads the chart. */
function srv_selectTrendRange(el) {
    var hours = parseInt(el.getAttribute('data-action-srv-hours'), 10);
    srv_currentTrendHours = hours;
    var server = srv_getCurrentServer();
    document.querySelectorAll('#srv-modal-trend .srv-trend-range-btn').forEach(function(btn) {
        btn.classList.toggle('srv-active', parseInt(btn.getAttribute('data-action-srv-hours'), 10) === hours);
    });
    srv_loadTrendData(srv_currentTrendMetric, server, hours);
}

/* Closes the trend modal and destroys its chart, ignoring interior clicks. */
function srv_closeTrendModal(target, event) {
    if (srv_ignoreModalClick('srv-modal-trend', target, event)) return;
    document.getElementById('srv-modal-trend').classList.add('cc-hidden');
    if (srv_trendChart) { srv_trendChart.destroy(); srv_trendChart = null; }
    srv_currentTrendMetric = null;
}

/* Loads the trend data for a metric and renders the chart. */
async function srv_loadTrendData(metric, server, hours) {
    var loadingEl = document.getElementById('srv-trend-loading');
    var noteEl = document.getElementById('srv-trend-aggregation-note');
    loadingEl.classList.remove('cc-hidden');
    noteEl.textContent = '';
    try {
        var data = await cc_engineFetch('/api/server-health/trend?metric=' + metric + '&server=' + encodeURIComponent(server) + '&hours=' + hours);
        if (!data) return;
        loadingEl.classList.add('cc-hidden');
        if (data.Error) {
            document.getElementById('srv-trend-current-value').textContent = 'Error';
            noteEl.textContent = data.Error;
            return;
        }
        document.getElementById('srv-trend-current-value').textContent = data.length > 0 ? srv_formatNumber(data[data.length - 1].value) : 'No data';
        if (hours > 24) {
            noteEl.textContent = 'Showing hourly averages for ' + (hours === 168 ? '7 days' : '30 days');
        }
        srv_renderTrendChart(data, metric, hours);
    } catch (err) {
        loadingEl.classList.add('cc-hidden');
        document.getElementById('srv-trend-current-value').textContent = 'Error';
        noteEl.textContent = err.message;
    }
}

/* Renders the trend line chart. */
function srv_renderTrendChart(data, metric, hours) {
    var ctx = document.getElementById('srv-trend-chart').getContext('2d');
    if (srv_trendChart) srv_trendChart.destroy();

    var dateFormat = hours <= 24
        ? { hour: '2-digit', minute: '2-digit' }
        : hours <= 168
            ? { month: 'short', day: 'numeric', hour: '2-digit' }
            : { month: 'short', day: 'numeric' };

    srv_trendChart = new Chart(ctx, {
        type: 'line',
        data: {
            labels: data.map(function(d) { return new Date(d.timestamp).toLocaleDateString('en-US', dateFormat); }),
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
                x: { grid: { color: '#333' }, ticks: { color: '#888', maxTicksLimit: hours <= 24 ? 12 : (hours <= 168 ? 7 : 10), maxRotation: 45 } },
                y: { grid: { color: '#333' }, ticks: { color: '#888' } }
            },
            interaction: { intersect: false, mode: 'index' }
        }
    });
}

/* ============================================================================
   FUNCTIONS: XE TIME WINDOW
   ----------------------------------------------------------------------------
   The Extended Events time-window selector modal: opening it with the active
   choice highlighted, closing it, and applying a new window that refreshes the
   activity cards.
   Prefix: srv
   ============================================================================ */

/* Opens the XE time-window selector modal. */
function srv_openTimeWindowSelector() {
    document.querySelectorAll('#srv-modal-xe-time .srv-xe-time-btn').forEach(function(btn) {
        btn.classList.toggle('srv-active', parseInt(btn.getAttribute('data-action-srv-minutes'), 10) === srv_xeActivityWindowMinutes);
    });
    document.getElementById('srv-modal-xe-time').classList.remove('cc-hidden');
}

/* Closes the XE time-window selector modal, ignoring interior clicks. */
function srv_closeTimeWindowModal(target, event) {
    if (srv_ignoreModalClick('srv-modal-xe-time', target, event)) return;
    document.getElementById('srv-modal-xe-time').classList.add('cc-hidden');
}

/* Applies a new XE activity time window and refreshes the cards. */
function srv_applyTimeWindow(el) {
    var minutes = parseInt(el.getAttribute('data-action-srv-minutes'), 10);
    srv_xeActivityWindowMinutes = minutes;
    document.getElementById('srv-recent-activity-window').textContent = minutes;
    document.getElementById('srv-modal-xe-time').classList.add('cc-hidden');
    var server = srv_getCurrentServer();
    if (server) srv_refreshXEActivity(server);
}

/* ============================================================================
   FUNCTIONS: XE LRQ PANEL
   ----------------------------------------------------------------------------
   The Extended Events long-running-queries slideout: opening, closing,
   refreshing, and loading the aggregated long-running query sessions.
   Prefix: srv
   ============================================================================ */

/* Opens the long-running-queries slideout. */
function srv_openXELRQPanel() {
    srv_openSlide('srv-slideout-xe-lrq');
    document.getElementById('srv-xe-lrq-time-window').textContent = '(last ' + srv_xeActivityWindowMinutes + ' minutes)';
    srv_loadXELRQDetail();
}

/* Closes the long-running-queries slideout, ignoring interior clicks. */
function srv_closeXELRQPanel(target, event) {
    if (srv_ignoreSlideClick('srv-slideout-xe-lrq', target, event)) return;
    srv_closeSlide('srv-slideout-xe-lrq');
}

/* Reloads the long-running-queries detail. */
function srv_refreshXELRQPanel() {
    document.getElementById('srv-xe-lrq-time-window').textContent = '(last ' + srv_xeActivityWindowMinutes + ' minutes)';
    srv_loadXELRQDetail();
}

/* Loads and renders the long-running-queries detail. */
async function srv_loadXELRQDetail() {
    var server = srv_getCurrentServer();
    var body = document.getElementById('srv-xe-lrq-panel-body');
    body.innerHTML = '<div class="srv-loading">Loading...</div>';
    try {
        var data = await cc_engineFetch('/api/server-health/lrq-detail?server=' + encodeURIComponent(server) + '&minutes=' + srv_xeActivityWindowMinutes);
        if (!data) return;
        if (data.Error) { body.innerHTML = '<div class="srv-error">Error: ' + data.Error + '</div>'; return; }
        if (!data || data.length === 0) { body.innerHTML = '<div class="srv-no-data">No long running queries in the last ' + srv_xeActivityWindowMinutes + ' minutes.</div>'; return; }

        var totalExecutions = data.reduce(function(sum, s) { return sum + s.execution_count; }, 0);
        var html = '<div class="srv-panel-summary">' +
            totalExecutions + ' long running quer' + (totalExecutions !== 1 ? 'ies' : 'y') +
            ' from ' + data.length + ' session' + (data.length !== 1 ? 's' : '') +
            ' in the last ' + srv_xeActivityWindowMinutes + ' minutes</div>';

        data.forEach(function(s) {
            var avgDurationSec = s.avg_duration_ms / 1000;
            var maxDurationSec = s.max_duration_ms / 1000;
            var durationClass = '';
            if (maxDurationSec > 300) durationClass = ' srv-duration-critical';
            else if (maxDurationSec > 60) durationClass = ' srv-duration-warning';

            var queryText = s.recent_sql_text || null;
            var hasQuery = queryText && queryText.trim().length > 0;

            html += '<div class="srv-request-card">' +
                '<div class="srv-request-header">' +
                '<span class="srv-request-spid">SPID ' + (s.session_id || '-') +
                    ' <span style="color:#4ec9b0;font-size:12px;margin-left:8px;">' + s.execution_count + ' Execution' + (s.execution_count !== 1 ? 's' : '') + '</span></span>' +
                '<span class="srv-request-duration' + durationClass + '">avg ' + srv_formatDuration(avgDurationSec) + '</span>' +
                '</div>' +
                '<div class="srv-request-details">' +
                'Database: <span class="srv-detail-value">' + (s.database_name || '-') + '</span> | ' +
                'User: <span class="srv-detail-value">' + (s.username || '-') + '</span><br>' +
                'Host: <span class="srv-detail-value">' + (s.client_hostname || '-') + '</span><br>' +
                'App: <span class="srv-detail-value">' + (s.client_app_name || '-').substring(0, 60) + '</span>' +
                '</div>' +
                '<div class="srv-request-stats">' +
                '<span>Max: <span class="srv-stat-value">' + srv_formatDuration(maxDurationSec) + '</span></span>' +
                '<span>Total CPU: <span class="srv-stat-value">' + srv_formatNumber(s.total_cpu_ms) + 'ms</span></span>' +
                '<span>Total Reads: <span class="srv-stat-value">' + srv_formatNumber(s.total_reads) + '</span></span>' +
                '<span>Total Writes: <span class="srv-stat-value">' + srv_formatNumber(s.total_writes) + '</span></span>' +
                '</div>' +
                '<div class="srv-query-meta">First: ' + s.first_occurrence + ' | Last: ' + s.last_occurrence + '</div>' +
                (hasQuery ? '<div class="srv-query-text-section"><div class="srv-query-text-label">Most Recent Query:</div><div class="srv-query-text-scroll">' + cc_escapeHtml(queryText) + '</div></div>' : '') +
                '</div>';
        });

        body.innerHTML = html;
    } catch (err) {
        body.innerHTML = '<div class="srv-error">Error: ' + err.message + '</div>';
    }
}

/* ============================================================================
   FUNCTIONS: XE BLOCKING PANEL
   ----------------------------------------------------------------------------
   The Extended Events blocking slideout: opening, closing, refreshing, loading
   the aggregated blocking events, and the expand/collapse loader for the
   per-blocker victim sessions.
   Prefix: srv
   ============================================================================ */

/* Opens the XE blocking slideout. */
function srv_openXEBlockingPanel() {
    srv_openSlide('srv-slideout-xe-blocking');
    document.getElementById('srv-xe-blocking-time-window').textContent = '(last ' + srv_xeActivityWindowMinutes + ' minutes)';
    srv_loadXEBlockingDetail();
}

/* Closes the XE blocking slideout, ignoring interior clicks. */
function srv_closeXEBlockingPanel(target, event) {
    if (srv_ignoreSlideClick('srv-slideout-xe-blocking', target, event)) return;
    srv_closeSlide('srv-slideout-xe-blocking');
}

/* Reloads the XE blocking detail. */
function srv_refreshXEBlockingPanel() {
    document.getElementById('srv-xe-blocking-time-window').textContent = '(last ' + srv_xeActivityWindowMinutes + ' minutes)';
    srv_loadXEBlockingDetail();
}

/* Loads and renders the XE blocking detail. */
async function srv_loadXEBlockingDetail() {
    var server = srv_getCurrentServer();
    var body = document.getElementById('srv-xe-blocking-panel-body');
    body.innerHTML = '<div class="srv-loading">Loading...</div>';
    try {
        var data = await cc_engineFetch('/api/server-health/blocking-detail?server=' + encodeURIComponent(server) + '&minutes=' + srv_xeActivityWindowMinutes);
        if (!data) return;
        if (data.Error) { body.innerHTML = '<div class="srv-error">Error: ' + data.Error + '</div>'; return; }
        if (!data || data.length === 0) { body.innerHTML = '<div class="srv-no-data">No blocking events in the last ' + srv_xeActivityWindowMinutes + ' minutes.</div>'; return; }

        var totalEvents = data.reduce(function(sum, b) { return sum + b.blocking_count; }, 0);
        var html = '<div class="srv-panel-summary">' +
            totalEvents + ' blocking event' + (totalEvents !== 1 ? 's' : '') +
            ' caused by ' + data.length + ' blocker' + (data.length !== 1 ? 's' : '') +
            ' in the last ' + srv_xeActivityWindowMinutes + ' minutes</div>';

        data.forEach(function(b, idx) {
            var avgWaitSec = b.avg_wait_ms / 1000;
            var maxWaitSec = b.max_wait_ms / 1000;
            var waitClass = '';
            if (maxWaitSec > 120) waitClass = ' srv-duration-critical';
            else if (maxWaitSec > 60) waitClass = ' srv-duration-warning';

            var blockerQuerySection = b.blocker_query_text
                ? '<div class="srv-query-text-section"><div class="srv-query-text-label">Blocker Query:</div><div class="srv-query-text-scroll">' + cc_escapeHtml(b.blocker_query_text) + '</div></div>'
                : '';

            var victimsSection = '';
            if (b.victims_count > 0) {
                victimsSection = '<div class="srv-expand-collapse-section">' +
                    '<div class="srv-expand-toggle" data-action-click="srv-toggle-blocking-victims" data-action-srv-idx="' + idx + '" data-action-srv-spid="' + (b.blocked_by_spid || '') + '">' +
                    '<span class="srv-expand-icon" id="srv-expand-icon-' + idx + '">&#9654;</span> ' +
                    '<span>Show ' + b.victims_count + ' Blocked Session' + (b.victims_count !== 1 ? 's' : '') + '</span>' +
                    '</div>' +
                    '<div class="srv-expand-content srv-hidden" id="srv-blocking-victims-' + idx + '">' +
                    '<div class="srv-loading">Loading victims...</div>' +
                    '</div>' +
                    '</div>';
            }

            html += '<div class="srv-request-card">' +
                '<div class="srv-request-header">' +
                '<span class="srv-request-spid">SPID ' + (b.blocked_by_spid || '-') +
                    ' <span style="color:#f48771;font-size:12px;margin-left:8px;">' + b.blocking_count + ' Block' + (b.blocking_count !== 1 ? 's' : '') + '</span>' +
                    ' <span style="color:#dcdcaa;font-size:11px;margin-left:4px;">(' + b.victims_count + ' victim' + (b.victims_count !== 1 ? 's' : '') + ')</span></span>' +
                '<span class="srv-request-duration' + waitClass + '">max ' + srv_formatDuration(maxWaitSec) + '</span>' +
                '</div>' +
                '<div class="srv-request-details">' +
                'Database: <span class="srv-detail-value">' + (b.blocked_by_database || '-') + '</span> | ' +
                'Login: <span class="srv-detail-value">' + (b.blocked_by_login || '-') + '</span><br>' +
                'Host: <span class="srv-detail-value">' + (b.blocked_by_host_name || '-') + '</span> | ' +
                'Status: <span class="srv-detail-value">' + (b.blocked_by_status || '-') + '</span><br>' +
                'App: <span class="srv-detail-value">' + (b.blocked_by_client_app || '-').substring(0, 60) + '</span>' +
                '</div>' +
                '<div class="srv-request-stats">' +
                '<span>Avg Wait: <span class="srv-stat-value">' + srv_formatDuration(avgWaitSec) + '</span></span>' +
                '<span>Total Wait: <span class="srv-stat-value">' + srv_formatDuration(b.total_wait_ms / 1000) + '</span></span>' +
                '</div>' +
                '<div class="srv-query-meta">First: ' + b.first_occurrence + ' | Last: ' + b.last_occurrence + '</div>' +
                blockerQuerySection +
                victimsSection +
                '</div>';
        });

        body.innerHTML = html;
    } catch (err) {
        body.innerHTML = '<div class="srv-error">Error: ' + err.message + '</div>';
    }
}

/* Toggles and lazily loads the victim sessions for a blocker. */
async function srv_toggleBlockingVictims(el) {
    var idx = el.getAttribute('data-action-srv-idx');
    var spidAttr = el.getAttribute('data-action-srv-spid');
    var blockerSpid = spidAttr ? parseInt(spidAttr, 10) : null;
    var contentDiv = document.getElementById('srv-blocking-victims-' + idx);
    var iconSpan = document.getElementById('srv-expand-icon-' + idx);

    if (contentDiv.classList.contains('srv-hidden')) {
        contentDiv.classList.remove('srv-hidden');
        iconSpan.innerHTML = '&#9660;';
        if (contentDiv.innerHTML.indexOf('Loading') === -1 && contentDiv.innerHTML.indexOf('srv-victim-card') !== -1) return;

        var server = srv_getCurrentServer();
        var url = '/api/server-health/blocking-victims?server=' + encodeURIComponent(server) + '&minutes=' + srv_xeActivityWindowMinutes;
        if (blockerSpid !== null && !isNaN(blockerSpid)) url += '&blocker_spid=' + blockerSpid;

        try {
            var victims = await cc_engineFetch(url);
            if (!victims) return;
            if (victims.Error) { contentDiv.innerHTML = '<div class="srv-error">Error: ' + victims.Error + '</div>'; return; }
            if (!victims || victims.length === 0) { contentDiv.innerHTML = '<div class="srv-no-data">No victim details available.</div>'; return; }

            var html = '';
            victims.forEach(function(v) {
                var waitSec = (v.blocked_wait_time_ms || 0) / 1000;
                var waitClass = waitSec > 60 ? ' srv-wait-critical' : (waitSec > 30 ? ' srv-wait-warning' : '');
                html += '<div class="srv-victim-card">' +
                    '<div class="srv-victim-header">' +
                    '<span class="srv-victim-spid">SPID ' + (v.blocked_spid || '-') + '</span>' +
                    '<span class="srv-victim-wait' + waitClass + '">' + srv_formatDuration(waitSec) + ' wait</span>' +
                    '</div>' +
                    '<div class="srv-victim-details">' +
                    '<span class="srv-victim-value">' + v.event_timestamp + '</span> | ' +
                    '<span class="srv-victim-value">' + (v.blocked_database || '-') + '</span> | ' +
                    '<span class="srv-victim-value">' + (v.blocked_login || '-') + '</span>' +
                    '</div>' +
                    '<div class="srv-victim-details">' +
                    'Wait: <span class="srv-victim-value">' + (v.blocked_wait_type || '-') + '</span>' +
                    (v.blocked_wait_resource ? ' on <span class="srv-victim-value">' + cc_escapeHtml(v.blocked_wait_resource.substring(0, 60)) + '</span>' : '') +
                    '</div>' +
                    (v.blocked_query_text ? '<div class="srv-query-text-section"><div class="srv-query-text-label">Blocked Query:</div><div class="srv-query-text-scroll">' + cc_escapeHtml(v.blocked_query_text) + '</div></div>' : '') +
                    '</div>';
            });
            contentDiv.innerHTML = html;
        } catch (err) {
            contentDiv.innerHTML = '<div class="srv-error">Error: ' + err.message + '</div>';
        }
    } else {
        contentDiv.classList.add('srv-hidden');
        iconSpan.innerHTML = '&#9654;';
    }
}

/* ============================================================================
   FUNCTIONS: XE DEADLOCK PANEL
   ----------------------------------------------------------------------------
   The Extended Events deadlock slideout: opening, closing, refreshing, and
   loading the deadlock events with their victim and survivor detail blocks.
   Prefix: srv
   ============================================================================ */

/* Opens the XE deadlock slideout. */
function srv_openXEDeadlockPanel() {
    srv_openSlide('srv-slideout-xe-deadlock');
    document.getElementById('srv-xe-deadlock-time-window').textContent = '(last ' + srv_xeActivityWindowMinutes + ' minutes)';
    srv_loadXEDeadlockDetail();
}

/* Closes the XE deadlock slideout, ignoring interior clicks. */
function srv_closeXEDeadlockPanel(target, event) {
    if (srv_ignoreSlideClick('srv-slideout-xe-deadlock', target, event)) return;
    srv_closeSlide('srv-slideout-xe-deadlock');
}

/* Reloads the XE deadlock detail. */
function srv_refreshXEDeadlockPanel() {
    document.getElementById('srv-xe-deadlock-time-window').textContent = '(last ' + srv_xeActivityWindowMinutes + ' minutes)';
    srv_loadXEDeadlockDetail();
}

/* Loads and renders the XE deadlock detail. */
async function srv_loadXEDeadlockDetail() {
    var server = srv_getCurrentServer();
    var body = document.getElementById('srv-xe-deadlock-panel-body');
    body.innerHTML = '<div class="srv-loading">Loading...</div>';
    try {
        var data = await cc_engineFetch('/api/server-health/deadlock-detail?server=' + encodeURIComponent(server) + '&minutes=' + srv_xeActivityWindowMinutes);
        if (!data) return;
        if (data.Error) { body.innerHTML = '<div class="srv-error">Error: ' + data.Error + '</div>'; return; }
        if (!data || data.length === 0) { body.innerHTML = '<div class="srv-no-data">No deadlocks in the last ' + srv_xeActivityWindowMinutes + ' minutes.</div>'; return; }

        var html = '<div class="srv-panel-summary">' +
            data.length + ' deadlock' + (data.length !== 1 ? 's' : '') +
            ' in the last ' + srv_xeActivityWindowMinutes + ' minutes</div>';

        data.forEach(function(d) {
            var categoryClass = d.deadlock_category === 'COMPLEX' ? ' srv-duration-critical' : ' srv-duration-warning';
            var categoryLabel = d.deadlock_category || 'STANDARD';

            html += '<div class="srv-request-card">' +
                '<div class="srv-request-header">' +
                '<span class="srv-request-spid">' + d.event_timestamp +
                    ' <span style="font-size:11px;color:#888;margin-left:8px;">' + (d.process_count || 2) + ' processes</span></span>' +
                '<span class="srv-request-duration' + categoryClass + '">' + categoryLabel + '</span>' +
                '</div>' +
                '<div class="srv-deadlock-victim">' +
                '<div class="srv-deadlock-victim-label">VICTIM (Killed)</div>' +
                '<div class="srv-request-details">' +
                'SPID: <span class="srv-detail-value">' + (d.victim_spid || '-') + '</span> | ' +
                'Database: <span class="srv-detail-value">' + (d.victim_database || '-') + '</span> | ' +
                'Login: <span class="srv-detail-value">' + (d.victim_login || '-') + '</span><br>' +
                'Host: <span class="srv-detail-value">' + (d.victim_host_name || '-') + '</span> | ' +
                'App: <span class="srv-detail-value">' + (d.victim_client_app || '-').substring(0, 50) + '</span>' +
                '</div>' +
                (d.victim_query_text ? '<div class="srv-request-query">' + cc_escapeHtml(d.victim_query_text) + '</div>' : '') +
                '</div>' +
                '<div class="srv-deadlock-survivor">' +
                '<div class="srv-deadlock-survivor-label">SURVIVOR (Completed)</div>' +
                '<div class="srv-request-details">' +
                'SPID: <span class="srv-detail-value">' + (d.survivor_spid || '-') + '</span> | ' +
                'Database: <span class="srv-detail-value">' + (d.survivor_database || '-') + '</span> | ' +
                'Login: <span class="srv-detail-value">' + (d.survivor_login || '-') + '</span><br>' +
                'Host: <span class="srv-detail-value">' + (d.survivor_host_name || '-') + '</span> | ' +
                'App: <span class="srv-detail-value">' + (d.survivor_client_app || '-').substring(0, 50) + '</span>' +
                '</div>' +
                (d.survivor_query_text ? '<div class="srv-request-query">' + cc_escapeHtml(d.survivor_query_text) + '</div>' : '') +
                '</div>' +
                '</div>';
        });

        body.innerHTML = html;
    } catch (err) {
        body.innerHTML = '<div class="srv-error">Error: ' + err.message + '</div>';
    }
}

/* ============================================================================
   FUNCTIONS: XE LINKED SERVER PANELS
   ----------------------------------------------------------------------------
   The Extended Events linked-server inbound and outbound slideouts: opening,
   closing, refreshing, and loading the aggregated remote query activity in
   each direction.
   Prefix: srv
   ============================================================================ */

/* Opens the linked-server inbound slideout. */
function srv_openXELSInboundPanel() {
    srv_openSlide('srv-slideout-xe-ls-inbound');
    document.getElementById('srv-xe-ls-inbound-time-window').textContent = '(last ' + srv_xeActivityWindowMinutes + ' minutes)';
    srv_loadXELSInboundDetail();
}

/* Closes the linked-server inbound slideout, ignoring interior clicks. */
function srv_closeXELSInboundPanel(target, event) {
    if (srv_ignoreSlideClick('srv-slideout-xe-ls-inbound', target, event)) return;
    srv_closeSlide('srv-slideout-xe-ls-inbound');
}

/* Reloads the linked-server inbound detail. */
function srv_refreshXELSInboundPanel() {
    document.getElementById('srv-xe-ls-inbound-time-window').textContent = '(last ' + srv_xeActivityWindowMinutes + ' minutes)';
    srv_loadXELSInboundDetail();
}

/* Loads and renders the linked-server inbound detail. */
async function srv_loadXELSInboundDetail() {
    var server = srv_getCurrentServer();
    var body = document.getElementById('srv-xe-ls-inbound-panel-body');
    body.innerHTML = '<div class="srv-loading">Loading...</div>';
    try {
        var data = await cc_engineFetch('/api/server-health/ls-inbound-detail?server=' + encodeURIComponent(server) + '&minutes=' + srv_xeActivityWindowMinutes);
        if (!data) return;
        if (data.Error) { body.innerHTML = '<div class="srv-error">Error: ' + data.Error + '</div>'; return; }
        if (!data || data.length === 0) { body.innerHTML = '<div class="srv-no-data">No inbound linked server queries in the last ' + srv_xeActivityWindowMinutes + ' minutes.</div>'; return; }

        var totalExecutions = data.reduce(function(sum, r) { return sum + (r.execution_count || 1); }, 0);
        var html = '<div class="srv-panel-summary">' +
            totalExecutions + ' inbound quer' + (totalExecutions !== 1 ? 'ies' : 'y') +
            ' (' + data.length + ' unique) from remote servers in the last ' + srv_xeActivityWindowMinutes + ' minutes</div>';

        data.forEach(function(r) {
            var maxDurationSec = (r.max_duration_ms || 0) / 1000;
            var durationClass = '';
            if (maxDurationSec > 60) durationClass = ' srv-duration-critical';
            else if (maxDurationSec > 10) durationClass = ' srv-duration-warning';

            html += '<div class="srv-request-card">' +
                '<div class="srv-request-header">' +
                '<span class="srv-request-spid">From: ' + (r.client_hostname || 'Unknown') +
                    ' <span style="color:#4ec9b0;font-size:12px;margin-left:8px;">' + (r.execution_count || 1) + ' Execution' + ((r.execution_count || 1) !== 1 ? 's' : '') + '</span></span>' +
                '<span class="srv-request-duration' + durationClass + '">max ' + srv_formatDuration(maxDurationSec) + '</span>' +
                '</div>' +
                '<div class="srv-request-details">' +
                'Database: <span class="srv-detail-value">' + (r.database_name || '-') + '</span> | ' +
                'User: <span class="srv-detail-value">' + (r.username || '-') + '</span> | ' +
                'SPID: <span class="srv-detail-value">' + (r.session_id || '-') + '</span><br>' +
                'App: <span class="srv-detail-value">' + (r.client_app_name || '-').substring(0, 50) + '</span>' +
                '</div>' +
                '<div class="srv-request-stats">' +
                '<span>Total Duration: <span class="srv-stat-value">' + srv_formatDuration((r.total_duration_ms || 0) / 1000) + '</span></span>' +
                '<span>Total CPU: <span class="srv-stat-value">' + srv_formatNumber(r.total_cpu_time_ms) + 'ms</span></span>' +
                '<span>Total Reads: <span class="srv-stat-value">' + srv_formatNumber(r.total_logical_reads) + '</span></span>' +
                '</div>' +
                '<div class="srv-query-meta">First: ' + r.first_event_timestamp + ' | Last: ' + r.last_event_timestamp + '</div>' +
                (r.sql_text ? '<div class="srv-request-query">' + cc_escapeHtml(r.sql_text) + '</div>' : '') +
                '</div>';
        });

        body.innerHTML = html;
    } catch (err) {
        body.innerHTML = '<div class="srv-error">Error: ' + err.message + '</div>';
    }
}

/* Opens the linked-server outbound slideout. */
function srv_openXELSOutboundPanel() {
    srv_openSlide('srv-slideout-xe-ls-outbound');
    document.getElementById('srv-xe-ls-outbound-time-window').textContent = '(last ' + srv_xeActivityWindowMinutes + ' minutes)';
    srv_loadXELSOutboundDetail();
}

/* Closes the linked-server outbound slideout, ignoring interior clicks. */
function srv_closeXELSOutboundPanel(target, event) {
    if (srv_ignoreSlideClick('srv-slideout-xe-ls-outbound', target, event)) return;
    srv_closeSlide('srv-slideout-xe-ls-outbound');
}

/* Reloads the linked-server outbound detail. */
function srv_refreshXELSOutboundPanel() {
    document.getElementById('srv-xe-ls-outbound-time-window').textContent = '(last ' + srv_xeActivityWindowMinutes + ' minutes)';
    srv_loadXELSOutboundDetail();
}

/* Loads and renders the linked-server outbound detail. */
async function srv_loadXELSOutboundDetail() {
    var server = srv_getCurrentServer();
    var body = document.getElementById('srv-xe-ls-outbound-panel-body');
    body.innerHTML = '<div class="srv-loading">Loading...</div>';
    try {
        var data = await cc_engineFetch('/api/server-health/ls-outbound-detail?server=' + encodeURIComponent(server) + '&minutes=' + srv_xeActivityWindowMinutes);
        if (!data) return;
        if (data.Error) { body.innerHTML = '<div class="srv-error">Error: ' + data.Error + '</div>'; return; }
        if (!data || data.length === 0) { body.innerHTML = '<div class="srv-no-data">No outbound linked server queries in the last ' + srv_xeActivityWindowMinutes + ' minutes.</div>'; return; }

        var totalExecutions = data.reduce(function(sum, r) { return sum + (r.execution_count || 1); }, 0);
        var html = '<div class="srv-panel-summary">' +
            totalExecutions + ' outbound quer' + (totalExecutions !== 1 ? 'ies' : 'y') +
            ' (' + data.length + ' unique) to remote servers in the last ' + srv_xeActivityWindowMinutes + ' minutes</div>';

        data.forEach(function(r) {
            var maxDurationSec = (r.max_duration_ms || 0) / 1000;
            var durationClass = '';
            if (maxDurationSec > 60) durationClass = ' srv-duration-critical';
            else if (maxDurationSec > 10) durationClass = ' srv-duration-warning';

            html += '<div class="srv-request-card">' +
                '<div class="srv-request-header">' +
                '<span class="srv-request-spid">SPID ' + (r.session_id || '-') +
                    ' <span style="color:#4ec9b0;font-size:12px;margin-left:8px;">' + (r.execution_count || 1) + ' Execution' + ((r.execution_count || 1) !== 1 ? 's' : '') + '</span></span>' +
                '<span class="srv-request-duration' + durationClass + '">max ' + srv_formatDuration(maxDurationSec) + '</span>' +
                '</div>' +
                '<div class="srv-request-details">' +
                'Database: <span class="srv-detail-value">' + (r.database_name || '-') + '</span> | ' +
                'User: <span class="srv-detail-value">' + (r.username || '-') + '</span><br>' +
                'Host: <span class="srv-detail-value">' + (r.client_hostname || '-') + '</span> | ' +
                'App: <span class="srv-detail-value">' + (r.client_app_name || '-').substring(0, 50) + '</span>' +
                '</div>' +
                '<div class="srv-request-stats">' +
                '<span>Total Duration: <span class="srv-stat-value">' + srv_formatDuration((r.total_duration_ms || 0) / 1000) + '</span></span>' +
                '<span>Total CPU: <span class="srv-stat-value">' + srv_formatNumber(r.total_cpu_time_ms) + 'ms</span></span>' +
                '<span>Total Reads: <span class="srv-stat-value">' + srv_formatNumber(r.total_logical_reads) + '</span></span>' +
                '</div>' +
                '<div class="srv-query-meta">First: ' + r.first_event_timestamp + ' | Last: ' + r.last_event_timestamp + '</div>' +
                (r.sql_text ? '<div class="srv-request-query">' + cc_escapeHtml(r.sql_text) + '</div>' : '') +
                '</div>';
        });

        body.innerHTML = html;
    } catch (err) {
        body.innerHTML = '<div class="srv-error">Error: ' + err.message + '</div>';
    }
}

/* ============================================================================
   FUNCTIONS: XE AG EVENTS PANEL
   ----------------------------------------------------------------------------
   The Extended Events availability-group events slideout: opening, closing,
   refreshing, and loading the AG health events with their state transitions.
   Prefix: srv
   ============================================================================ */

/* Opens the XE AG events slideout. */
function srv_openXEAGEventsPanel() {
    srv_openSlide('srv-slideout-xe-ag-events');
    document.getElementById('srv-xe-ag-events-time-window').textContent = '(last ' + srv_xeActivityWindowMinutes + ' minutes)';
    srv_loadXEAGEventsDetail();
}

/* Closes the XE AG events slideout, ignoring interior clicks. */
function srv_closeXEAGEventsPanel(target, event) {
    if (srv_ignoreSlideClick('srv-slideout-xe-ag-events', target, event)) return;
    srv_closeSlide('srv-slideout-xe-ag-events');
}

/* Reloads the XE AG events detail. */
function srv_refreshXEAGEventsPanel() {
    document.getElementById('srv-xe-ag-events-time-window').textContent = '(last ' + srv_xeActivityWindowMinutes + ' minutes)';
    srv_loadXEAGEventsDetail();
}

/* Loads and renders the XE AG events detail. */
async function srv_loadXEAGEventsDetail() {
    var server = srv_getCurrentServer();
    var body = document.getElementById('srv-xe-ag-events-panel-body');
    body.innerHTML = '<div class="srv-loading">Loading...</div>';
    try {
        var data = await cc_engineFetch('/api/server-health/ag-events-detail?server=' + encodeURIComponent(server) + '&minutes=' + srv_xeActivityWindowMinutes);
        if (!data) return;
        if (data.Error) { body.innerHTML = '<div class="srv-error">Error: ' + data.Error + '</div>'; return; }
        if (!data || data.length === 0) { body.innerHTML = '<div class="srv-no-data">No AG health events in the last ' + srv_xeActivityWindowMinutes + ' minutes.</div>'; return; }

        var html = '<div class="srv-panel-summary">' +
            data.length + ' AG event' + (data.length !== 1 ? 's' : '') +
            ' in the last ' + srv_xeActivityWindowMinutes + ' minutes</div>';

        data.forEach(function(e) {
            var stateClass = '';
            if (e.event_type.includes('failover') || e.event_type.includes('lease_expired') || e.error_number) stateClass = ' srv-duration-critical';
            else if (e.event_type.includes('state_change')) stateClass = ' srv-duration-warning';

            html += '<div class="srv-request-card">' +
                '<div class="srv-request-header">' +
                '<span class="srv-request-spid">' + e.event_timestamp + '</span>' +
                '<span class="srv-request-duration' + stateClass + '">' + e.event_type + '</span>' +
                '</div>' +
                '<div class="srv-request-details">' +
                'AG: <span class="srv-detail-value">' + (e.ag_name || '-') + '</span> | ' +
                'Replica: <span class="srv-detail-value">' + (e.replica_name || '-') + '</span>' +
                (e.database_name ? ' | Database: <span class="srv-detail-value">' + e.database_name + '</span>' : '') +
                '</div>' +
                ((e.previous_state || e.current_state) ? '<div class="srv-state-transition"><span class="srv-state-from">' + (e.previous_state || '?') + '</span> &rarr; <span class="srv-state-to">' + (e.current_state || '?') + '</span></div>' : '') +
                (e.error_number ? '<div class="srv-event-error">Error ' + e.error_number + ': ' + (e.error_message || '') + '</div>' : '') +
                '</div>';
        });

        body.innerHTML = html;
    } catch (err) {
        body.innerHTML = '<div class="srv-error">Error: ' + err.message + '</div>';
    }
}

/* ============================================================================
   FUNCTIONS: XE SYSTEM HEALTH PANEL
   ----------------------------------------------------------------------------
   The Extended Events system-health slideout: opening, closing, refreshing,
   and loading the system health events with their detail and stat lines.
   Prefix: srv
   ============================================================================ */

/* Opens the XE system health slideout. */
function srv_openXESystemHealthPanel() {
    srv_openSlide('srv-slideout-xe-system-health');
    document.getElementById('srv-xe-system-health-time-window').textContent = '(last ' + srv_xeActivityWindowMinutes + ' minutes)';
    srv_loadXESystemHealthDetail();
}

/* Closes the XE system health slideout, ignoring interior clicks. */
function srv_closeXESystemHealthPanel(target, event) {
    if (srv_ignoreSlideClick('srv-slideout-xe-system-health', target, event)) return;
    srv_closeSlide('srv-slideout-xe-system-health');
}

/* Reloads the XE system health detail. */
function srv_refreshXESystemHealthPanel() {
    document.getElementById('srv-xe-system-health-time-window').textContent = '(last ' + srv_xeActivityWindowMinutes + ' minutes)';
    srv_loadXESystemHealthDetail();
}

/* Loads and renders the XE system health detail. */
async function srv_loadXESystemHealthDetail() {
    var server = srv_getCurrentServer();
    var body = document.getElementById('srv-xe-system-health-panel-body');
    body.innerHTML = '<div class="srv-loading">Loading...</div>';
    try {
        var data = await cc_engineFetch('/api/server-health/system-health-detail?server=' + encodeURIComponent(server) + '&minutes=' + srv_xeActivityWindowMinutes);
        if (!data) return;
        if (data.Error) { body.innerHTML = '<div class="srv-error">Error: ' + data.Error + '</div>'; return; }
        if (!data || data.length === 0) { body.innerHTML = '<div class="srv-no-data">No system health events in the last ' + srv_xeActivityWindowMinutes + ' minutes.</div>'; return; }

        var html = '<div class="srv-panel-summary">' +
            data.length + ' system health event' + (data.length !== 1 ? 's' : '') +
            ' in the last ' + srv_xeActivityWindowMinutes + ' minutes</div>';

        data.forEach(function(e) {
            var eventClass = '';
            if (e.event_type.includes('error') || e.component_state === 'error') eventClass = ' srv-duration-critical';
            else if (e.component_state === 'warning') eventClass = ' srv-duration-warning';

            var details = [];
            if (e.session_id) details.push('SPID: <span class="srv-detail-value">' + e.session_id + '</span>');
            if (e.error_code) details.push('Error: <span class="srv-detail-value">' + e.error_code + '</span>');
            if (e.client_hostname) details.push('Host: <span class="srv-detail-value">' + e.client_hostname + '</span>');
            if (e.client_app_name) details.push('App: <span class="srv-detail-value">' + e.client_app_name.substring(0, 40) + '</span>');
            if (e.wait_type) details.push('Wait: <span class="srv-detail-value">' + e.wait_type + '</span>');
            if (e.component_type) details.push('Component: <span class="srv-detail-value">' + e.component_type + '</span>');
            if (e.component_state) details.push('State: <span class="srv-detail-value">' + e.component_state + '</span>');

            var stats = [];
            if (e.duration_ms) stats.push('<span>Duration: <span class="srv-stat-value">' + srv_formatDuration(e.duration_ms / 1000) + '</span></span>');
            if (e.os_error) stats.push('<span>OS Error: <span class="srv-stat-value">' + e.os_error + '</span></span>');
            if (e.calling_api_name) stats.push('<span>API: <span class="srv-stat-value">' + e.calling_api_name + '</span></span>');

            html += '<div class="srv-request-card">' +
                '<div class="srv-request-header">' +
                '<span class="srv-request-spid">' + e.event_timestamp + '</span>' +
                '<span class="srv-request-duration' + eventClass + '">' + e.event_type + '</span>' +
                '</div>' +
                '<div class="srv-request-details">' + (details.join(' | ') || '-') + '</div>' +
                (stats.length > 0 ? '<div class="srv-request-stats">' + stats.join('') + '</div>' : '') +
                '</div>';
        });

        body.innerHTML = html;
    } catch (err) {
        body.innerHTML = '<div class="srv-error">Error: ' + err.message + '</div>';
    }
}

/* ============================================================================
   FUNCTIONS: PAGE LIFECYCLE HOOKS
   ----------------------------------------------------------------------------
   The lifecycle hooks the shared bootloader invokes: a full refresh on manual
   page refresh, a live refresh on tab resume, stopping live polling on session
   expiry, and refreshing the event-driven sections when an engine process
   completes.
   Prefix: srv
   ============================================================================ */

/* Refreshes all sections when the user clicks the page refresh button. */
function srv_onPageRefresh() {
    srv_refreshAll();
}

/* Refreshes live sections when the tab regains visibility. */
function srv_onPageResumed() {
    srv_refreshLiveSections();
}

/* Stops live polling when the auth session ends. */
function srv_onSessionExpired() {
    srv_stopLivePolling();
}

/* Refreshes the event-driven sections when a watched engine process completes. */
function srv_onEngineProcessCompleted(processName, event) {
    srv_refreshEventSections();
}

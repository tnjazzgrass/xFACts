/* ============================================================================
   xFACts Control Center - JBoss Monitoring
   Location: E:\xFACts-ControlCenter\public\js\jboss-monitoring.js

   Version: Tracked in dbo.System_Metadata (component: JBoss)

   Page-specific JS for the JBoss Monitoring dashboard. Chrome-level
   behavior (connection banner, page refresh, engine cards, modals) is
   provided by engine-events.js per the CC Page Chrome Contract
   (Development Guidelines Section 5.12). This file contains data loading,
   rendering, delta tracking, and JBoss-specific interaction logic only.

   CHANGELOG
   ---------
   2026-04-30  Phase 4 (Chrome Standardization, modal migration): three
               local modal/dialog systems migrated to the shared
               xf-modal-* infrastructure.
                 - Info modal: showInfo() / closeInfoModal() now toggle
                   .hidden on the xf-modal-overlay element. Body content
                   is still populated from the INFO dictionary.
                 - DM Switch modal: openSwitchModal() / closeSwitchModal()
                   toggle .hidden on the overlay; the doSwitchServer() flow
                   adds .dm-locked during the ~90-second operation to hide
                   the close X.
                 - Confirm dialog: local showConfirm() / cancelConfirm() /
                   executeConfirm() / pendingConfirm variable removed.
                   The one call site in selectServer() now uses the shared
                   Promise-based showConfirm() from engine-events.js with
                   confirmClass=xf-modal-btn-danger.
   2026-04-30  Phase 4 (Chrome Standardization): aligned with shared chrome
               contract. Removed local showError() / hideError() functions
               that targeted the legacy 'connection-error' element ID --
               connection state is now handled exclusively by
               updateConnectionBanner() in engine-events.js. API failure
               logging shifted to console.error. Removed local pageRefresh()
               (the shared version in engine-events.js handles button spin
               animation and delegates to onPageRefresh() defined here).
               Migrated raw fetch() calls in loadServerStatus,
               loadQueueStatus, and loadRefreshInterval to engineFetch()
               for consistent session-expiry / idle-pause / hidden-tab
               handling across all API calls on this page.
   2026-03-18  Renamed from dm-monitoring.js. Routes -> /api/jboss-monitoring/*.
               Engine process -> Collect-JBossMetrics. Page -> jboss-monitoring.
   2026-03-09  Delta seeding: seed snapshotState and queueDeltaState from
               API-provided previous snapshot on first load. Deltas display
               immediately without waiting for a second collection cycle.
               Added undertow_bytes_sent and undertow_processing_ms to
               DELTA_FIELDS. HTTP Server card expanded: Data Sent and
               Processing Time as delta rows, Max Request as standalone row.
   2026-03-08  Phase 3: Info modal system with plain-English explainers.
               Cumulative counter delta detection (tx, undertow, ds).
               Transactions card redesign with per-counter rows.
               JMS Queues accordion (replaced slideout).
               HTTP Server card delta indicators.
   2026-03-08  Phase 2b: Redesigned card layout with mini-cards, gauge bars,
               status badges, tooltips. Removed OS Process section (redundant
               with Management API JVM metrics). Added working set to JVM card.
   2026-03-08  Phase 2: Full metric card rendering, queue slideout
   2026-03-08  Added "Users" badge, server switch modal, confirm dialog
   2026-03-07  Initial implementation
   ============================================================================ */

// ============================================================================
// STATE
// ============================================================================

var ENGINE_PROCESSES = { 'Collect-JBossMetrics': { slug: 'jboss' } };
var pageLoadDate = new Date().toDateString();
setInterval(function() { if (new Date().toDateString() !== pageLoadDate) window.location.reload(); }, 60000);

// Page hooks for engine-events.js shared module
function onPageResumed() { refreshAll(); }
function onPageRefresh() { refreshAll(); }
function onEngineProcessCompleted(processName) { if (processName === 'Collect-JBossMetrics') refreshEventSections(); }

var refreshInterval = null, refreshSeconds = 60;
var serverData = [], queueData = {}, activeServer = null, switchingServer = false;

// === DELTA TRACKING ===
// Stores snapshot state per server_id for cumulative counter delta detection.
// Only updates baseline when collected_dttm changes (new collector output).
// If the page refreshes but returns the same snapshot, last-known deltas are preserved.
var snapshotState = {};

// Queue-level delta tracking. Keyed by server_id, stores per-queue messages_added
// baselines and deltas. Same collected_dttm gating as snapshotState.
var queueDeltaState = {};

// Track which queue accordions are open so they survive re-renders
var openAccordions = {};

document.addEventListener('DOMContentLoaded', function() {
    loadRefreshInterval();
    loadActiveServer();
    loadServerStatus();
    loadQueueStatus();
    connectEngineEvents();
    initEngineCardClicks();
});

// ============================================================================
// REFRESH INTERVAL & AUTO-REFRESH
// ============================================================================

function loadRefreshInterval() {
    engineFetch('/api/config/refresh-interval?page=jboss-monitoring').then(function(d){
        if (d && d.interval_seconds) refreshSeconds = d.interval_seconds;
        startAutoRefresh();
    }).catch(function(){ startAutoRefresh(); });
}

function startAutoRefresh() {
    if (refreshInterval) clearInterval(refreshInterval);
    refreshInterval = setInterval(function() {
        loadServerStatus();
        loadQueueStatus();
        loadActiveServer();
    }, refreshSeconds * 1000);
}

function refreshAll() { loadServerStatus(); loadQueueStatus(); loadActiveServer(); }
function refreshEventSections() { loadServerStatus(); loadQueueStatus(); }

// ============================================================================
// API CALLS
// ============================================================================

function loadActiveServer() {
    engineFetch('/api/jboss-monitoring/active-server').then(function(d){
        if (!d || d.Error) return;
        activeServer = d.active_server;
        renderUsersBadge();
    }).catch(function(){});
}

function loadServerStatus() {
    engineFetch('/api/jboss-monitoring/status').then(function(data){
        if (!data) return;
        if (data.error) { console.error('Server status:', data.error); return; }
        serverData = data.servers || [];

        // Seed delta baselines from API-provided previous snapshot (first load only)
        for (var i = 0; i < serverData.length; i++) {
            var s = serverData[i];
            if (s.prev_collected_dttm && !snapshotState[s.server_id]) {
                var prevValues = { server_uptime_hours: s.prev_server_uptime_hours || null };
                for (var j = 0; j < DELTA_FIELDS.length; j++) {
                    var f = DELTA_FIELDS[j];
                    prevValues[f] = (s['prev_' + f] !== null && s['prev_' + f] !== undefined) ? s['prev_' + f] : null;
                }
                snapshotState[s.server_id] = {
                    collected_dttm: s.prev_collected_dttm,
                    values: prevValues,
                    deltas: {}
                };
            }
        }

        renderServers(serverData);
        updateTimestamp(data.timestamp);
    }).catch(function(err){ console.error('Failed to load server status:', err.message); });
}

function loadQueueStatus() {
    engineFetch('/api/jboss-monitoring/queue-status').then(function(data){
        if (!data) return;
        if (data.error) { console.error('Queue status:', data.error); return; }
        queueData = {};
        var s = data.servers || [];

        // Seed queue delta baselines from API-provided previous cycle (first load only)
        for (var i = 0; i < s.length; i++) {
            var sv = s[i];
            if (sv.prev_collected_dttm && !queueDeltaState[sv.server_id]) {
                var prevValues = {};
                var qs = sv.queues || [];
                for (var j = 0; j < qs.length; j++) {
                    if (qs[j].prev_messages_added !== null && qs[j].prev_messages_added !== undefined) {
                        prevValues[qs[j].queue_name] = qs[j].prev_messages_added;
                    }
                }
                queueDeltaState[sv.server_id] = {
                    collected_dttm: sv.prev_collected_dttm,
                    values: prevValues,
                    deltas: {}
                };
            }
            queueData[sv.server_id] = sv;
        }

        if (serverData.length > 0) renderServers(serverData);
    }).catch(function(err){ console.error('Failed to load queue status:', err.message); });
}

// ============================================================================
// DELTA COMPUTATION
// ============================================================================
// Returns an object with delta values for all tracked cumulative counters.
// Only updates the baseline when collected_dttm changes (new snapshot from collector).
// If the page refreshes but the same snapshot is returned, the last-known deltas are preserved.
// Detects JBoss restarts via uptime drop or counter decrease and resets baseline.

var DELTA_FIELDS = [
    'tx_committed', 'tx_timed_out', 'tx_rollbacks', 'tx_aborted', 'tx_heuristics',
    'undertow_request_count', 'undertow_error_count', 'undertow_bytes_sent',
    'undertow_processing_ms', 'ds_timed_out'
];

function computeDeltas(server) {
    var sid = server.server_id;
    var state = snapshotState[sid];

    // If same snapshot as last render (collector hasn't produced a new row),
    // return last-known deltas without updating baseline
    if (state && state.collected_dttm === server.collected_dttm) {
        return state.deltas;
    }

    // Start with last-known deltas as fallback (or null if first load)
    var deltas = {};
    for (var i = 0; i < DELTA_FIELDS.length; i++) {
        deltas[DELTA_FIELDS[i]] = (state && state.deltas) ? state.deltas[DELTA_FIELDS[i]] : null;
    }

    if (state) {
        var prev = state.values;

        // Detect JBoss restart: uptime dropped (or cumulative counters reset)
        var restarted = false;
        if (prev.server_uptime_hours !== null && server.server_uptime_hours !== null
            && server.server_uptime_hours < prev.server_uptime_hours) {
            restarted = true;
        }
        // Also detect restart if any cumulative counter went DOWN
        if (!restarted) {
            for (var i = 0; i < DELTA_FIELDS.length; i++) {
                var f = DELTA_FIELDS[i];
                if (prev[f] !== null && prev[f] !== undefined
                    && server[f] !== null && server[f] !== undefined
                    && server[f] < prev[f]) {
                    restarted = true;
                    break;
                }
            }
        }

        if (restarted) {
            // Restart confirmed -- reset all deltas to null
            for (var i = 0; i < DELTA_FIELDS.length; i++) deltas[DELTA_FIELDS[i]] = null;
        } else {
            // Compute deltas only for fields where both prev and current are non-null
            for (var i = 0; i < DELTA_FIELDS.length; i++) {
                var f = DELTA_FIELDS[i];
                if (prev[f] !== null && prev[f] !== undefined
                    && server[f] !== null && server[f] !== undefined) {
                    deltas[f] = server[f] - prev[f];
                }
                // If current is null (API hiccup), delta stays at last-known value from fallback above
            }
        }
    }

    // Store current values as new baseline -- but preserve previous known-good
    // values for any field that came back null (partial snapshot)
    var values = {};
    var prevValues = (state && state.values) ? state.values : {};
    values.server_uptime_hours = (server.server_uptime_hours !== null && server.server_uptime_hours !== undefined)
        ? server.server_uptime_hours : (prevValues.server_uptime_hours || null);
    for (var i = 0; i < DELTA_FIELDS.length; i++) {
        var f = DELTA_FIELDS[i];
        values[f] = (server[f] !== null && server[f] !== undefined) ? server[f] : (prevValues[f] || null);
    }

    snapshotState[sid] = {
        collected_dttm: server.collected_dttm,
        values: values,
        deltas: deltas
    };

    return deltas;
}

// ============================================================================
// RENDER SERVER CARDS
// ============================================================================

function renderServers(servers) {
    if (!servers || servers.length === 0) {
        for (var i = 0; i < 3; i++) {
            var b = document.getElementById('server-body-' + i);
            if (b) b.innerHTML = '<div class="no-data">No data</div>';
        }
        return;
    }
    for (var i = 0; i < servers.length && i < 3; i++) renderServerCard(i, servers[i]);
    renderUsersBadge();
}

function renderServerCard(index, server) {
    var nameEl = document.getElementById('server-name-' + index);
    var roleEl = document.getElementById('server-role-' + index);
    var bodyEl = document.getElementById('server-body-' + index);
    var cardEl = document.getElementById('server-card-' + index);
    if (!nameEl || !bodyEl) return;

    var nameHtml = server.server_name;
    if (server.is_domain_controller) nameHtml += '<span class="dc-badge">DC</span>';
    nameEl.innerHTML = nameHtml;
    roleEl.textContent = server.server_role || '';

    cardEl.className = 'server-card';
    if (server.http_error_message || (server.http_status_code !== 200 && server.http_status_code !== null)) {
        cardEl.classList.add('card-critical');
    }

    if (!server.collected_dttm) {
        bodyEl.innerHTML = '<div class="no-data">No snapshots collected yet</div>';
        return;
    }

    // Compute deltas for this server
    var deltas = computeDeltas(server);

    var h = '';

    // === STATUS BADGES ROW ===
    h += '<div class="status-badges-row">';
    var httpOk = server.http_status_code === 200 && !server.http_error_message;
    h += '<div class="status-badge ' + (httpOk ? 'badge-ok' : 'badge-fail') + '">';
    h += '<span class="badge-dot ' + (httpOk ? 'dot-ok' : 'dot-fail') + '"></span><span class="badge-text">HTTP</span>';
    if (httpOk && server.http_response_ms !== null) h += '<span class="badge-detail">' + server.http_response_ms + 'ms</span>';
    h += '</div>';

    var svcOk = server.service_state === 'Running';
    h += '<div class="status-badge ' + (svcOk ? 'badge-ok' : 'badge-fail') + '">';
    h += '<span class="badge-dot ' + (svcOk ? 'dot-ok' : 'dot-fail') + '"></span><span class="badge-text">Service</span></div>';

    if (server.api_server_state) {
        var jOk = server.api_server_state === 'running';
        var jWarn = server.api_server_state === 'reload-required';
        var jCls = jOk ? 'badge-ok' : (jWarn ? 'badge-warn' : 'badge-fail');
        var jDot = jOk ? 'dot-ok' : (jWarn ? 'dot-warn' : 'dot-fail');
        h += '<div class="status-badge ' + jCls + '">';
        h += '<span class="badge-dot ' + jDot + '"></span><span class="badge-text">JBoss</span>';
        if (!jOk) h += '<span class="badge-detail">' + server.api_server_state + '</span>';
        h += '</div>';
    }

    if (server.server_uptime_hours !== null && server.server_uptime_hours !== undefined && !isNaN(Number(server.server_uptime_hours))) {
        h += '<div class="badges-spacer"></div>';
        h += '<div class="status-badge badge-neutral">';
        h += '<span class="badge-text uptime-label">Uptime</span><span class="badge-text uptime-text">' + formatUptime(server.server_uptime_hours) + '</span></div>';
    }
    h += '</div>';

    if (server.http_error_message) h += '<div class="alert-row">' + escapeHtml(server.http_error_message) + '</div>';

    // === MINI-CARD: JVM Heap ===
    if (server.jvm_heap_used_mb !== null) {
        var hp = Math.round((server.jvm_heap_used_mb / server.jvm_heap_max_mb) * 100);
        var hCls = hp >= 90 ? 'critical' : (hp >= 75 ? 'warning' : 'healthy');
        var hBar = hp >= 90 ? 'bar-critical' : (hp >= 75 ? 'bar-warning' : 'bar-healthy');
        h += '<div class="mini-card">';
        h += '<div class="mini-card-header"><span class="mini-card-title">JVM Heap <span class="info-icon" onclick="event.stopPropagation();showInfo(\'jvm-heap\')">?</span></span>';
        h += '<span class="mini-card-value ' + hCls + '">' + hp + '%</span></div>';
        h += '<div class="gauge-bar"><div class="gauge-fill ' + hBar + '" style="width:' + Math.min(hp, 100) + '%"></div></div>';
        h += '<div class="mini-card-detail"><span>' + fmtN(server.jvm_heap_used_mb) + ' / ' + fmtN(server.jvm_heap_max_mb) + ' MB</span></div>';
        var ex = [];
        if (server.jvm_nonheap_used_mb !== null) ex.push('Non-heap: ' + fmtN(server.jvm_nonheap_used_mb) + ' MB');
        if (server.jboss_working_set_mb !== null) ex.push('OS: ' + fmtN(server.jboss_working_set_mb) + ' MB');
        if (ex.length > 0) h += '<div class="mini-card-secondary">' + ex.join(' &middot; ') + '</div>';
        h += '</div>';
    }

    // === MINI-CARD: JVM Threads ===
    if (server.jvm_thread_count !== null) {
        var tp = server.jvm_thread_peak > 0 ? Math.round((server.jvm_thread_count / server.jvm_thread_peak) * 100) : 0;
        var tBar = tp >= 95 ? 'bar-warning' : 'bar-healthy';
        h += '<div class="mini-card">';
        h += '<div class="mini-card-header"><span class="mini-card-title">Threads <span class="info-icon" onclick="event.stopPropagation();showInfo(\'jvm-threads\')">?</span></span>';
        h += '<span class="mini-card-value">' + fmtN(server.jvm_thread_count) + '</span></div>';
        h += '<div class="gauge-bar"><div class="gauge-fill ' + tBar + '" style="width:' + Math.min(tp, 100) + '%"></div></div>';
        h += '<div class="mini-card-detail"><span>Peak: ' + fmtN(server.jvm_thread_peak) + '</span></div>';
        h += '</div>';
    }

    // === MINI-CARD: Datasource Pool ===
    if (server.ds_active_count !== null) {
        var dp = server.ds_active_count > 0 ? Math.round((server.ds_in_use_count / server.ds_active_count) * 100) : 0;
        var dCls = dp >= 80 ? 'critical' : (dp >= 50 ? 'warning' : 'healthy');
        var dBar = dp >= 80 ? 'bar-critical' : (dp >= 50 ? 'bar-warning' : 'bar-healthy');
        h += '<div class="mini-card">';
        h += '<div class="mini-card-header"><span class="mini-card-title">DB Pool <span class="info-icon" onclick="event.stopPropagation();showInfo(\'db-pool\')">?</span></span>';
        h += '<span class="mini-card-value ' + dCls + '">' + server.ds_in_use_count + ' / ' + server.ds_active_count + '</span></div>';
        h += '<div class="gauge-bar"><div class="gauge-fill ' + dBar + '" style="width:' + Math.min(dp, 100) + '%"></div></div>';
        h += '<div class="mini-card-detail">';
        h += '<span>Idle: ' + server.ds_idle_count + '</span>';
        h += '<span>Peak: ' + server.ds_max_used_count + '</span>';
        h += '<span>' + server.ds_avg_get_time_ms + 'ms avg</span>';
        h += '</div>';
        if (server.ds_wait_count > 0) h += '<div class="alert-row">&#9888; ' + server.ds_wait_count + ' threads waiting for connections</div>';
        h += '</div>';
    }

    // === MINI-CARD: Transactions ===
    if (server.tx_committed !== null) {
        h += '<div class="mini-card">';
        h += '<div class="mini-card-header"><span class="mini-card-title">Transactions <span class="info-icon" onclick="event.stopPropagation();showInfo(\'transactions\')">?</span></span></div>';
        h += '<div class="tx-rows">';

        // In-flight (real-time, not cumulative -- no delta needed)
        h += buildTxRow('In-flight', server.tx_inflight, null, null, server.tx_inflight > 0);

        // Committed (delta = throughput indicator -- green/good)
        h += buildDeltaRow('Committed', server.tx_committed, deltas.tx_committed, 'good');

        // Timed Out (red -- something is wrong)
        h += buildDeltaRow('Timed out', server.tx_timed_out, deltas.tx_timed_out, 'critical', server.tx_committed);

        // Rollbacks (yellow -- worth noticing)
        h += buildDeltaRow('Rollbacks', server.tx_rollbacks, deltas.tx_rollbacks, 'alert', server.tx_committed);

        // Heuristics (white/informational -- but % of total provides context)
        h += buildDeltaRow('Heuristics', server.tx_heuristics, deltas.tx_heuristics, 'info', server.tx_committed);

        h += '</div>'; // .tx-rows
        h += '</div>'; // .mini-card
    }

    // === MINI-CARD: HTTP Server ===
    if (server.undertow_request_count !== null) {
        h += '<div class="mini-card">';
        h += '<div class="mini-card-header"><span class="mini-card-title">HTTP Server <span class="info-icon" onclick="event.stopPropagation();showInfo(\'http-server\')">?</span></span></div>';
        h += '<div class="tx-rows">';

        h += buildDeltaRow('Requests', server.undertow_request_count, deltas.undertow_request_count, 'good');
        h += buildDeltaRow('Errors', server.undertow_error_count, deltas.undertow_error_count, 'critical');
        h += buildDeltaRow('Data sent', server.undertow_bytes_sent, deltas.undertow_bytes_sent, 'good');
        h += buildDeltaRow('Processing', server.undertow_processing_ms, deltas.undertow_processing_ms, 'info');

        // Max request time (high-water mark, not cumulative -- standalone display)
        h += '<div class="delta-row"><span class="delta-label">Max request</span>';
        h += '<span class="delta-zero">' + (server.undertow_max_proc_ms !== null ? fmtN(server.undertow_max_proc_ms) + ' ms' : '&mdash;') + '</span>';
        h += '<span class="delta-cumulative"></span></div>';

        h += '</div>'; // .tx-rows

        if (server.io_worker_queue_size > 0) h += '<div class="alert-row">&#9888; IO queue: ' + server.io_worker_queue_size + ' waiting</div>';
        h += '</div>'; // .mini-card
    }

    // === MINI-CARD: JMS Queues ===
    var sq = queueData[server.server_id];
    if (sq) {
        var queueDeltas = computeQueueDeltas(sq);
        var queueStats = classifyQueues(sq.queues || [], queueDeltas);
        // Default accordion to open (user can collapse manually)
        var isOpen = openAccordions[server.server_id] !== undefined ? openAccordions[server.server_id] : true;
        var inactiveOpen = openAccordions['inactive-' + server.server_id] || false;

        h += '<div class="mini-card queue-card' + (isOpen ? ' accordion-open' : '') + '">';
        h += '<div class="mini-card-header queue-accordion-trigger" onclick="toggleQueueAccordion(' + server.server_id + ')">';
        h += '<span class="mini-card-title">JMS Queues <span class="info-icon" onclick="event.stopPropagation();showInfo(\'jms-queues\')">?</span></span>';

        // Headline
        if (queueStats.stuck > 0) {
            h += '<span class="mini-card-value critical">' + queueStats.stuck + ' <span class="mini-card-unit">stuck</span></span>';
        } else if (queueStats.active.length > 0) {
            h += '<span class="mini-card-value">' + queueStats.active.length + ' <span class="mini-card-unit">active</span></span>';
        } else {
            h += '<span class="mini-card-value healthy">Idle</span>';
        }
        h += '<span class="accordion-arrow' + (isOpen ? ' open' : '') + '">&#9660;</span>';
        h += '</div>';

        // Summary line (always visible)
        if (queueStats.stuck > 0) {
            h += '<div class="alert-row">' + queueStats.stuck + ' queue' + (queueStats.stuck !== 1 ? 's' : '') + ' stuck &mdash; pending messages with no consumers or no delivery</div>';
        } else if (queueStats.totalAdded > 0) {
            h += '<div class="queue-summary-ok">' + queueStats.active.length + ' queue' + (queueStats.active.length !== 1 ? 's' : '') + ' active &middot; ' + fmtN(queueStats.totalAdded) + ' messages this cycle</div>';
        } else if (queueStats.processing > 0) {
            h += '<div class="queue-summary-ok">' + queueStats.processing + ' queue' + (queueStats.processing !== 1 ? 's' : '') + ' processing &mdash; ' + fmtN(queueStats.totalPending) + ' in flight</div>';
        }

        // Accordion body
        h += '<div class="queue-accordion-body' + (isOpen ? ' open' : '') + '" id="queue-accordion-' + server.server_id + '">';

        // Active queues
        if (queueStats.active.length > 0) {
            h += buildQueueTable(queueStats.active, true);
        } else {
            h += '<div class="queue-idle-msg">No queue activity this cycle</div>';
        }

        // Inactive queues toggle
        if (queueStats.inactive.length > 0) {
            h += '<div class="queue-inactive-toggle" onclick="event.stopPropagation();toggleInactiveQueues(' + server.server_id + ')">';
            h += '<span class="queue-inactive-arrow' + (inactiveOpen ? ' open' : '') + '">&#9654;</span> ';
            h += queueStats.inactive.length + ' inactive queue' + (queueStats.inactive.length !== 1 ? 's' : '');
            h += '</div>';
            h += '<div class="queue-inactive-body' + (inactiveOpen ? ' open' : '') + '" id="queue-inactive-' + server.server_id + '">';
            h += buildQueueTable(queueStats.inactive, false);
            h += '</div>';
        }

        h += '</div>'; // .queue-accordion-body
        h += '</div>'; // .mini-card
    }

    h += '<div class="card-footer">Collected: ' + server.collected_dttm + '</div>';
    bodyEl.innerHTML = h;
}

// ============================================================================
// DELTA ROW BUILDER
// ============================================================================
// Renders a single counter row with delta indicator and muted cumulative total.
// severity: 'good' (green), 'critical' (red), 'alert' (yellow), 'info' (white) when delta > 0
// pctOf: optional total to compute percentage (e.g. committed count for tx counters)

function buildDeltaRow(label, cumulative, delta, severity, pctOf) {
    var h = '<div class="delta-row">';
    h += '<span class="delta-label">' + label + '</span>';

    // Delta indicator (left side of value area)
    if (delta !== null && delta > 0) {
        var cls = severity === 'critical' ? 'delta-critical' : (severity === 'alert' ? 'delta-alert' : (severity === 'good' ? 'delta-good' : 'delta-info'));
        h += '<span class="' + cls + '">' + fmtDelta(label, delta) + ' this cycle</span>';
    } else if (delta !== null && delta === 0) {
        h += '<span class="delta-zero">0 this cycle</span>';
    } else {
        // null = first load or restart, show dash
        h += '<span class="delta-zero">&mdash;</span>';
    }

    // Cumulative total (right side, always muted) with "since restart" label
    var cumStr = fmtCumulative(label, cumulative);
    if (pctOf && pctOf > 0 && cumulative !== null && cumulative !== undefined && cumulative > 0) {
        var pct = (cumulative / pctOf * 100);
        cumStr += '<span class="delta-pct"> (' + (pct < 0.01 ? '&lt;0.01' : (pct < 1 ? pct.toFixed(2) : pct.toFixed(1))) + '%)</span>';
    }
    h += '<span class="delta-cumulative">' + cumStr + ' since restart</span>';
    h += '</div>';
    return h;
}

// Format delta value with context-appropriate units
function fmtDelta(label, delta) {
    if (label === 'Data sent') return formatBytes(delta);
    if (label === 'Processing') return fmtN(delta) + ' ms';
    return fmtC(delta);
}

// Format cumulative value with context-appropriate units
function fmtCumulative(label, value) {
    if (label === 'Data sent') return formatBytes(value);
    if (label === 'Processing') return fmtC(value) + ' ms';
    return fmtC(value);
}

// Non-delta row (for in-flight which is real-time, not cumulative)
function buildTxRow(label, value, delta, cumulative, isActive) {
    var h = '<div class="delta-row">';
    h += '<span class="delta-label">' + label + '</span>';
    if (isActive) {
        h += '<span class="delta-running">' + fmtN(value) + ' active</span>';
    } else {
        h += '<span class="delta-info">' + fmtN(value) + '</span>';
    }
    h += '<span class="delta-cumulative"></span>'; // empty for alignment
    h += '</div>';
    return h;
}

// ============================================================================
// QUEUE DELTA COMPUTATION
// ============================================================================
// Computes per-queue messages_added deltas for a server.
// Returns a map of queue_name -> delta (or null if first load).

function computeQueueDeltas(serverQueue) {
    var sid = serverQueue.server_id;
    var state = queueDeltaState[sid];
    var qs = serverQueue.queues || [];

    // Same snapshot? Return last-known deltas
    if (state && state.collected_dttm === serverQueue.collected_dttm) {
        return state.deltas;
    }

    var deltas = {};
    var prevDeltas = (state && state.deltas) ? state.deltas : {};
    for (var i = 0; i < qs.length; i++) {
        deltas[qs[i].queue_name] = (prevDeltas[qs[i].queue_name] !== undefined) ? prevDeltas[qs[i].queue_name] : null;
    }

    if (state) {
        var prevValues = state.values;
        for (var i = 0; i < qs.length; i++) {
            var qn = qs[i].queue_name;
            var cur = qs[i].messages_added;
            var prev = prevValues[qn];
            if (prev !== null && prev !== undefined && cur !== null && cur !== undefined) {
                if (cur < prev) {
                    // Counter went down = JBoss restart, reset all to null
                    for (var j = 0; j < qs.length; j++) deltas[qs[j].queue_name] = null;
                    break;
                }
                deltas[qn] = cur - prev;
            }
        }
    }

    var values = {};
    var prevVals = (state && state.values) ? state.values : {};
    for (var i = 0; i < qs.length; i++) {
        var qn = qs[i].queue_name;
        values[qn] = (qs[i].messages_added !== null && qs[i].messages_added !== undefined)
            ? qs[i].messages_added : (prevVals[qn] || null);
    }

    queueDeltaState[sid] = {
        collected_dttm: serverQueue.collected_dttm,
        values: values,
        deltas: deltas
    };

    return deltas;
}

// ============================================================================
// QUEUE CLASSIFICATION
// ============================================================================
// Categorizes queues using both current state and deltas.
// Active: messages_added delta > 0, or message_count > 0, or delivering_count > 0
// Also identifies stuck queues (pending but no consumers or no delivery).

function classifyQueues(queues, queueDeltas) {
    var stats = { stuck: 0, processing: 0, totalPending: 0, active: [], inactive: [], totalAdded: 0 };
    for (var i = 0; i < queues.length; i++) {
        var q = queues[i];
        var addedDelta = (queueDeltas && queueDeltas[q.queue_name] !== null && queueDeltas[q.queue_name] !== undefined)
            ? queueDeltas[q.queue_name] : null;

        if (q.message_count > 0) {
            stats.totalPending += q.message_count;
            if (q.consumer_count === 0 || q.delivering_count === 0) {
                stats.stuck++;
            } else {
                stats.processing++;
            }
        }

        if (addedDelta !== null && addedDelta > 0) stats.totalAdded += addedDelta;

        var isActive = (addedDelta !== null && addedDelta > 0)
            || q.message_count > 0
            || q.delivering_count > 0;

        if (isActive) {
            stats.active.push({ queue: q, delta: addedDelta });
        } else {
            stats.inactive.push({ queue: q, delta: addedDelta });
        }
    }
    return stats;
}

// ============================================================================
// QUEUE ACCORDION TOGGLES
// ============================================================================

function toggleQueueAccordion(serverId) {
    openAccordions[serverId] = !openAccordions[serverId];
    var body = document.getElementById('queue-accordion-' + serverId);
    if (!body) return;
    var card = body.closest('.queue-card');
    var arrow = card ? card.querySelector('.accordion-arrow') : null;
    if (openAccordions[serverId]) {
        body.classList.add('open');
        if (card) card.classList.add('accordion-open');
        if (arrow) arrow.classList.add('open');
    } else {
        body.classList.remove('open');
        if (card) card.classList.remove('accordion-open');
        if (arrow) arrow.classList.remove('open');
    }
}

function toggleInactiveQueues(serverId) {
    var key = 'inactive-' + serverId;
    openAccordions[key] = !openAccordions[key];
    var body = document.getElementById('queue-inactive-' + serverId);
    if (!body) return;
    var toggle = body.previousElementSibling;
    var arrow = toggle ? toggle.querySelector('.queue-inactive-arrow') : null;
    if (openAccordions[key]) {
        body.classList.add('open');
        if (arrow) arrow.classList.add('open');
    } else {
        body.classList.remove('open');
        if (arrow) arrow.classList.remove('open');
    }
}

// ============================================================================
// QUEUE TABLE BUILDER
// ============================================================================
// Builds a queue table from an array of {queue, delta} objects.
// showDelta: whether to show the "This Cycle" column (for active table)

function buildQueueTable(items, showDelta) {
    if (items.length === 0) return '';
    var h = '<table class="queue-table-inline"><thead><tr>';
    h += '<th class="q-name">Queue</th>';
    if (showDelta) h += '<th class="q-num">This Cycle</th>';
    h += '<th class="q-num">Pending</th>';
    h += '<th class="q-num">Delivering</th>';
    h += '<th class="q-num">Consumers</th>';
    h += '<th class="q-num">Total Added</th>';
    h += '</tr></thead><tbody>';
    for (var i = 0; i < items.length; i++) {
        var qi = items[i].queue;
        var delta = items[i].delta;
        var isStuck = qi.message_count > 0 && (qi.consumer_count === 0 || qi.delivering_count === 0);
        var isDeadConsumer = qi.consumer_count === 0 && qi.messages_added > 0 && qi.message_count === 0;
        var rc = isStuck ? ' class="queue-alert"' : (isDeadConsumer ? ' class="queue-warn"' : '');
        h += '<tr' + rc + '>';
        h += '<td class="q-name">' + qi.queue_name + '</td>';
        if (showDelta) {
            if (delta !== null && delta > 0) {
                h += '<td class="q-num q-delta-active">' + fmtN(delta) + '</td>';
            } else {
                h += '<td class="q-num q-delta-zero">' + (delta !== null ? '0' : '&mdash;') + '</td>';
            }
        }
        h += '<td class="q-num">' + fmtN(qi.message_count) + '</td>';
        h += '<td class="q-num">' + fmtN(qi.delivering_count) + '</td>';
        h += '<td class="q-num">' + fmtN(qi.consumer_count) + '</td>';
        h += '<td class="q-num">' + fmtN(qi.messages_added) + '</td>';
        h += '</tr>';
    }
    h += '</tbody></table>';
    return h;
}

// ============================================================================
// INFO MODAL (Help Bubbles)
// ============================================================================
// Opens the shared xf-modal-overlay with help content from the INFO
// dictionary. Static body markup is in JBossMonitoring.ps1; this function
// populates the title and body and toggles the overlay visibility.

var INFO = {
    'overview': {
        title: 'Understanding This Page',
        body: '<p>This page monitors the three JBoss application servers. These servers run <strong>JBoss</strong> &mdash; the application server that hosts Debt Manager. Every time you open DM, run a job, post a payment, or load a batch, JBoss is the engine doing the work.</p>' +
            '<p>Think of each server card as a dashboard for one engine:</p>' +
            '<div class="info-list">' +
                '<div class="info-item"><strong>Status badges</strong> (top row) are the quick health check &mdash; is the front door open, is the engine running, is JBoss responding?</div>' +
                '<div class="info-item"><strong>JVM Heap</strong> is how much memory the engine is using. Like a car&rsquo;s fuel gauge, but for RAM.</div>' +
                '<div class="info-item"><strong>Threads</strong> are how many things the engine is doing at once. Each user action, each batch process, each scheduled job uses threads.</div>' +
                '<div class="info-item"><strong>DB Pool</strong> is the pipeline between JBoss and the database. JBoss keeps a pool of database connections open and ready. When the pool runs low, things slow down.</div>' +
                '<div class="info-item"><strong>Transactions</strong> are the work units. A committed transaction is a completed operation. Timeouts and rollbacks mean something went wrong.</div>' +
                '<div class="info-item"><strong>HTTP Server</strong> is the web server layer inside JBoss that handles all incoming requests &mdash; page loads, API calls, everything.</div>' +
                '<div class="info-item"><strong>JMS Queues</strong> are internal work queues. When you trigger a batch or a job, it gets placed in a queue and processed in order. If queues back up, work is waiting.</div>' +
            '</div>' +
            '<p>The key insight: <strong>these queues are independent per server, not shared.</strong> When a server freezes, all its queued work stops. The other servers can&rsquo;t pick it up. That&rsquo;s why we monitor each server separately.</p>'
    },
    'status-badges': {
        title: 'Status Badges',
        body: '<p>The status badges across the top of each card are the fastest health check:</p>' +
            '<div class="info-list">' +
                '<div class="info-item"><strong>HTTP</strong> &mdash; Can we reach the server? Every 60 seconds, xFACts hits the DM splash page. If it responds with HTTP 200, the server is alive. The number in parentheses is the response time in milliseconds. Under 50ms is fast; over 500ms is sluggish. If this badge goes red, the server is unreachable &mdash; likely frozen or down.</div>' +
                '<div class="info-item"><strong>Service</strong> &mdash; Is the Windows service running? This checks the actual DebtManager-Host service on the server. It can show Running even when the application is frozen (which is the whole problem &mdash; the process is alive but not responding).</div>' +
                '<div class="info-item"><strong>JBoss</strong> &mdash; Is the application server in a healthy state? Values: <em>running</em> (good), <em>reload-required</em> (config change needs a restart), <em>stopped</em> (down). This comes from the JBoss Management API and only appears when API access is available.</div>' +
                '<div class="info-item"><strong>Uptime</strong> &mdash; How long since the last OS reboot. If one server shows significantly less uptime than the others, it was recently restarted. Useful for context when looking at metrics that reset on restart.</div>' +
            '</div>'
    },
    'jvm-heap': {
        title: 'JVM Heap Memory',
        body: '<p>JBoss runs inside a Java Virtual Machine (JVM), and the <strong>heap</strong> is the chunk of memory Java uses to store everything the application is working with &mdash; user sessions, cached data, objects being processed, queued work items.</p>' +
            '<p>The percentage bar shows how full the heap is relative to its configured maximum (typically 8 GB per server).</p>' +
            '<div class="info-thresholds">' +
                '<span><span class="info-green">&#9679; Under 75%</span> &mdash; Normal. Java&rsquo;s garbage collector has room to work.</span>' +
                '<span><span class="info-yellow">&#9679; 75% &ndash; 90%</span> &mdash; Elevated. Garbage collection runs more frequently, which can slow things down. Worth watching but not necessarily a problem.</span>' +
                '<span><span class="info-red">&#9679; Over 90%</span> &mdash; Critical. Java is spending more time cleaning up memory than doing useful work. Performance degrades significantly. If it hits 100%, the application may freeze entirely.</span>' +
            '</div>' +
            '<p><strong>Non-heap</strong> is memory Java uses for its own internals (class definitions, compiled code). It grows slowly and is rarely a concern.</p>' +
            '<p><strong>OS (Working Set)</strong> is the total memory the JBoss process uses from the operating system&rsquo;s perspective. This is always larger than the heap because it includes non-heap, native memory, and OS overhead.</p>'
    },
    'jvm-threads': {
        title: 'JVM Threads',
        body: '<p>A <strong>thread</strong> is a unit of work inside JBoss. Every user request, every background job, every internal process runs on a thread. More threads = more things happening simultaneously.</p>' +
            '<p>The gauge bar shows current threads relative to the <strong>peak</strong> (highest thread count since restart). This helps you see if the server is approaching its historical maximum.</p>' +
            '<p>Typical patterns:</p>' +
            '<div class="info-list">' +
                '<div class="info-item"><strong>Stable thread count (~150&ndash;300)</strong> &mdash; Normal. JBoss reuses threads from a pool.</div>' +
                '<div class="info-item"><strong>Climbing thread count</strong> &mdash; Potential concern. Could indicate requests piling up (threads waiting on slow operations) or a thread leak.</div>' +
                '<div class="info-item"><strong>Thread count near peak</strong> &mdash; The server is as busy as it&rsquo;s ever been. Not necessarily bad, but worth correlating with other metrics.</div>' +
            '</div>'
    },
    'db-pool': {
        title: 'Database Connection Pool',
        body: '<p>JBoss keeps a <strong>pool</strong> of pre-opened database connections ready to use. When application code needs to query the database, it borrows a connection from the pool, uses it, and returns it. This is much faster than opening a new connection every time.</p>' +
            '<p><strong>In-use / Active</strong> shows how many connections are currently borrowed vs. how many exist in the pool total.</p>' +
            '<div class="info-list">' +
                '<div class="info-item"><strong>Idle</strong> &mdash; Connections sitting in the pool waiting to be used. More idle = more headroom.</div>' +
                '<div class="info-item"><strong>Peak</strong> &mdash; Highest concurrent in-use count since restart. The historical high-water mark.</div>' +
                '<div class="info-item"><strong>Avg get time</strong> &mdash; Average time to borrow a connection. Under 5ms is normal. Rising times mean contention.</div>' +
            '</div>' +
            '<div class="info-thresholds">' +
                '<span><span class="info-green">&#9679; Under 50% utilization</span> &mdash; Plenty of room.</span>' +
                '<span><span class="info-yellow">&#9679; 50% &ndash; 80%</span> &mdash; Getting busy. Watch the trend.</span>' +
                '<span><span class="info-red">&#9679; Over 80%</span> &mdash; Pool is under pressure. If it hits 100%, threads start waiting and the application slows down.</span>' +
            '</div>' +
            '<p>If you see <strong>"threads waiting for connections"</strong>, the pool is exhausted. Application threads are blocked until a connection is returned. This directly impacts response times and can cascade into a freeze.</p>'
    },
    'transactions': {
        title: 'Transactions',
        body: '<p>A <strong>transaction</strong> is a unit of database work &mdash; a query, an update, a batch of operations that either all succeed or all fail. Every time DM saves data, posts a payment, or processes a batch, it&rsquo;s wrapped in a transaction.</p>' +
            '<p>Each row shows <strong>"this cycle"</strong> (the change since last collection, ~60 seconds ago) and the <strong>cumulative total</strong> since JBoss started.</p>' +
            '<div class="info-list">' +
                '<div class="info-item"><strong>In-flight</strong> &mdash; Transactions currently in progress. A few at a time is normal. A sustained high number means transactions are taking longer than usual.</div>' +
                '<div class="info-item"><strong>Committed</strong> &mdash; Successfully completed transactions. This is the throughput indicator. Higher during business hours, lower at night. <span class="info-green">Informational, not concerning.</span></div>' +
                '<div class="info-item"><strong>Timed out</strong> &mdash; Transactions that took longer than the 15-minute timeout. <span class="info-red">Any increase means something was stuck for a long time.</span> This is rare and always worth investigating.</div>' +
                '<div class="info-item"><strong>Rollbacks</strong> &mdash; Transactions that were intentionally reversed by the application. <span class="info-yellow">Some rollbacks are normal</span> (validation failures, duplicate checks). A sudden spike may indicate a problem.</div>' +
                '<div class="info-item"><strong>Heuristics</strong> &mdash; Rare edge cases where the transaction manager had to make a unilateral decision about a two-phase commit. Typically stays at zero or a small constant. Not usually concerning unless it&rsquo;s actively growing.</div>' +
            '</div>'
    },
    'http-server': {
        title: 'HTTP Server (Undertow)',
        body: '<p><strong>Undertow</strong> is the web server built into JBoss. It handles every HTTP request that comes into the DM application &mdash; page loads, API calls, file downloads, everything. Think of it as the front desk: all traffic passes through here.</p>' +
            '<p>Like the Transactions card, this shows <strong>"this cycle"</strong> deltas (changes since last collection) alongside cumulative totals.</p>' +
            '<div class="info-list">' +
                '<div class="info-item"><strong>Requests</strong> &mdash; Total HTTP requests handled. The "this cycle" number shows how busy the server is right now. Higher during business hours, lower at night. This is informational, not concerning by itself.</div>' +
                '<div class="info-item"><strong>Errors</strong> &mdash; HTTP requests that returned an error. <span class="info-green">Zero is the goal.</span> <span class="info-red">Any increase here needs attention</span> &mdash; it could mean application errors, misconfigured endpoints, or server-side failures.</div>' +
                '<div class="info-item"><strong>Data sent</strong> &mdash; Bytes served this cycle and total since restart. A spike in data with stable request count could mean large reports or file exports are being pulled.</div>' +
                '<div class="info-item"><strong>Processing</strong> &mdash; Total server-side processing time spent handling requests. Combined with request count, gives a sense of how hard the server is working. Requires <code>record-request-start-time</code> to be enabled on the Undertow HTTP listener (pending next JBoss restart).</div>' +
                '<div class="info-item"><strong>Max request</strong> &mdash; The single slowest HTTP request the server has handled since JBoss started. A high-water mark that resets on restart. Useful for spotting outlier requests. Also requires <code>record-request-start-time</code>.</div>' +
            '</div>' +
            '<p>If you see <span class="info-red">"IO queue: N waiting"</span> at the bottom, that means incoming requests are piling up faster than Undertow can process them. The server is overwhelmed &mdash; this typically only happens during a freeze or extreme load.</p>'
    },
    'jms-queues': {
        title: 'JMS Queues',
        body: '<p><strong>JMS (Java Message Service) queues</strong> are how JBoss organizes internal work. When you trigger an action in DM &mdash; release a batch, start a payment import, generate a document &mdash; it doesn&rsquo;t happen immediately in your browser session. Instead, a <em>message</em> gets placed in a queue, and a background <em>consumer</em> picks it up and processes it.</p>' +
            '<p>This is the same concept as a print queue: you click "print" and the job goes into a queue where the printer processes it when it&rsquo;s ready.</p>' +
            '<p><strong>Key concepts:</strong></p>' +
            '<div class="info-list">' +
                '<div class="info-item"><strong>Pending</strong> &mdash; Messages waiting to be picked up. Zero is healthy. A sustained non-zero means work is backing up &mdash; consumers aren&rsquo;t keeping pace.</div>' +
                '<div class="info-item"><strong>Delivering</strong> &mdash; Messages picked up by a consumer but not yet finished. These are in-flight. High delivering with stable pending = normal processing. High delivering with rising pending = consumers are stuck.</div>' +
                '<div class="info-item"><strong>Consumers</strong> &mdash; The number of background workers listening on this queue. Zero consumers on an active queue means nobody is processing work. The requestQueue typically has ~70 consumers; most others have 1&ndash;6.</div>' +
                '<div class="info-item"><strong>Added</strong> &mdash; Total messages ever added to this queue since JBoss started. The difference between snapshots shows throughput.</div>' +
            '</div>' +
            '<p><strong>Critical fact: Queues are independent per server.</strong> They are not shared across the three DM app servers. When APP2 freezes, all work queued on APP2 stops. APP and APP3 cannot pick it up. Each server&rsquo;s queues are an isolated world.</p>' +
            '<p>Click the queue card to expand the full queue table with per-queue details.</p>'
    }
};

function showInfo(key) {
    var info = INFO[key];
    if (!info) return;
    document.getElementById('info-modal-title').textContent = info.title;
    document.getElementById('info-modal-body').innerHTML = info.body;
    document.getElementById('info-modal-overlay').classList.remove('hidden');
}

function closeInfoModal() {
    document.getElementById('info-modal-overlay').classList.add('hidden');
}

// ============================================================================
// USERS BADGE
// ============================================================================

function renderUsersBadge() {
    var e = document.querySelector('.users-badge');
    if (e) e.remove();
    if (!activeServer || !serverData || serverData.length === 0) return;
    for (var i = 0; i < serverData.length; i++) {
        if (serverData[i].server_name.toUpperCase() === activeServer.toUpperCase()) {
            var hdr = document.querySelector('#server-card-' + i + ' .server-card-header');
            if (!hdr) return;
            var b = document.createElement('span');
            b.className = 'users-badge';
            b.textContent = 'Users';
            b.title = 'SharePoint Debt Manager link points here';
            if (window.isAdmin) {
                b.classList.add('clickable');
                b.title = 'Click to change SharePoint link target';
                b.onclick = function(ev) { ev.stopPropagation(); openSwitchModal(); };
            }
            hdr.appendChild(b);
            return;
        }
    }
}

// ============================================================================
// SERVER SWITCH MODAL (DM Picker)
// ============================================================================
// Uses shared xf-modal-overlay + xf-modal classes; visibility toggled via
// .hidden class. The .dm-locked class on the overlay during the switch
// operation hides the close X (per CSS rule) and shows not-allowed cursor.

function openSwitchModal() {
    if (!window.isAdmin) return;
    var overlay = document.getElementById('dm-modal-overlay');
    overlay.classList.remove('hidden');
    if (!switchingServer) {
        document.getElementById('dm-status').textContent = '';
        document.getElementById('dm-status').className = 'dm-status';
    }
    renderModalButtons();
}

function closeSwitchModal() {
    if (switchingServer) return;
    document.getElementById('dm-modal-overlay').classList.add('hidden');
}

function renderModalButtons() {
    document.querySelectorAll('.dm-server-btn').forEach(function(btn) {
        var s = btn.getAttribute('data-server');
        if (s.toUpperCase() === (activeServer || '').toUpperCase()) {
            btn.classList.add('active');
            btn.disabled = true;
        } else {
            btn.classList.remove('active');
            btn.disabled = false;
        }
    });
}

function selectServer(server) {
    if (server.toUpperCase() === (activeServer || '').toUpperCase()) return;
    var from = activeServer ? activeServer.replace('DM-PROD-', '') : '?';
    var to = server.replace('DM-PROD-', '');
    closeSwitchModal();

    // Use shared showConfirm() from engine-events.js (Promise-based)
    showConfirm('Redirect SharePoint link from ' + from + ' to ' + to + '?\n\nThis immediately affects all users.', {
        title: 'Switch DM App Server',
        confirmLabel: 'Switch to ' + to,
        confirmClass: 'xf-modal-btn-danger'
    }).then(function(confirmed) {
        if (confirmed) {
            openSwitchModal();
            doSwitchServer(server);
        }
    });
}

function doSwitchServer(server) {
    switchingServer = true;
    var overlay = document.getElementById('dm-modal-overlay');
    overlay.classList.add('dm-locked');
    document.querySelectorAll('.dm-server-btn').forEach(function(b) { b.disabled = true; });
    setModalStatus('Switching to ' + server.replace('DM-PROD-', '') + '... May take up to 90 seconds.', 'working');

    engineFetch('/api/jboss-monitoring/switch-server', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ target_server: server })
    }).then(function(d) {
        switchingServer = false;
        overlay.classList.remove('dm-locked');
        if (!d) { renderModalButtons(); return; }
        if (d.Error) { setModalStatus(d.Error, 'error'); renderModalButtons(); return; }
        activeServer = d.active_server;
        renderModalButtons();
        renderUsersBadge();
        setModalStatus('Switched to ' + d.active_server.replace('DM-PROD-', '') + ' by ' + d.performed_by, 'success');
    }).catch(function(e) {
        switchingServer = false;
        overlay.classList.remove('dm-locked');
        setModalStatus(e.message, 'error');
        renderModalButtons();
    });
}

function setModalStatus(msg, type) {
    var el = document.getElementById('dm-status');
    el.textContent = msg;
    el.className = 'dm-status ' + (type || '');
}

// ============================================================================
// HELPERS
// ============================================================================

function fmtN(n) { if (n === null || n === undefined) return '-'; return n.toLocaleString(); }
var formatNumber = fmtN;

function fmtC(n) {
    if (n === null || n === undefined) return '-';
    if (n >= 1000000) return (n / 1000000).toFixed(1) + 'M';
    if (n >= 10000)   return (n / 1000).toFixed(0) + 'K';
    if (n >= 1000)    return (n / 1000).toFixed(1) + 'K';
    return n.toLocaleString();
}

function formatBytes(b) {
    if (b === null || b === undefined) return '-';
    if (b >= 1073741824) return (b / 1073741824).toFixed(1) + ' GB';
    if (b >= 1048576)    return (b / 1048576).toFixed(1) + ' MB';
    if (b >= 1024)       return (b / 1024).toFixed(0) + ' KB';
    return b + ' B';
}

function formatUptime(hours) {
    if (hours === null || hours === undefined) return '-';
    hours = Number(hours);
    if (isNaN(hours)) return '-';
    var d = Math.floor(hours / 24), r = Math.floor(hours % 24);
    return d > 0 ? d + 'd ' + r + 'h' : r + 'h';
}

function escapeHtml(s) {
    if (!s) return '';
    var d = document.createElement('div');
    d.textContent = s;
    return d.innerHTML;
}

function updateTimestamp(ts) {
    var el = document.getElementById('last-update');
    if (el && ts) el.textContent = ts;
}

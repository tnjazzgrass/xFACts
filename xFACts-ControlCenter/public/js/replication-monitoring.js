/* ============================================================================
   xFACts Control Center - Replication Monitoring JavaScript
   Location: E:\xFACts-ControlCenter\public\js\replication-monitoring.js
   Version: Tracked in dbo.System_Metadata (component: ServerOps.Replication)
   ============================================================================ */

// ============================================================================
// CONFIGURATION
// ============================================================================

// Engine events — process map for shared WebSocket module (engine-events.js)
var ENGINE_PROCESSES = {
    'Collect-ReplicationHealth': { slug: 'replication'}
};

// Live polling (Refresh Architecture — plumbing ready, not currently active)
var PAGE_REFRESH_INTERVAL = 10;   // Default; overridden by GlobalConfig on load

// Page hooks for engine-events.js shared module
function onPageResumed() { pageRefresh(); }
function onSessionExpired() { stopPolling(); }
var livePollingTimer = null;
var pageLoadDate = new Date().toDateString();

var queueChart = null;
var latencyChart = null;
var throughputChart = null;

var queueMinutes = 60;
var latencyMinutes = 60;
var throughputMinutes = 60;

var eventDate = new Date().getFullYear() + '-' + String(new Date().getMonth() + 1).padStart(2, '0') + '-' + String(new Date().getDate()).padStart(2, '0');
var eventAgentFilter = 'ALL';
var eventAgents = []; // Built dynamically from agent cards data
var eventCorrelationMode = false;

var thresholds = {
    replication_queue_warning_threshold: 5000,
    replication_queue_critical_threshold: 50000,
    replication_latency_warning_ms: 30000,
    replication_latency_critical_ms: 120000
};

// Chart colors by publication
var chartColors = {
    'BIDATALoad': { line: '#4ec9b0', fill: 'rgba(78, 201, 176, 0.08)' },
    'Azure_BIDATA_Load': { line: '#569cd6', fill: 'rgba(86, 156, 214, 0.08)' },
    'BIDATA_Load_POC': { line: '#dcdcaa', fill: 'rgba(220, 220, 170, 0.08)' },
    'crs5_oltp': { line: '#c586c0', fill: 'rgba(197, 134, 192, 0.08)' }
};

function getColor(name) {
    return chartColors[name] || { line: '#888', fill: 'rgba(136, 136, 136, 0.08)' };
}

// ============================================================================
// SECTION INFO / TOOLTIPS
// ============================================================================
var sectionInfo = {
    'agent-status': {
        title: 'Agent Status',
        body: '<p><strong>What am I looking at?</strong></p>' +
            '<p>Each card represents a replication agent &mdash; a background process that moves data from one server to another. ' +
            'Think of them as conveyor belts moving database changes between systems.</p>' +
            '<p><strong>Agent Types:</strong></p>' +
            '<p><em>Log Reader</em> &mdash; Reads changes from the source database\'s transaction log and passes them to the distribution database. ' +
            'There\'s one Log Reader for all publications. If this stops, nothing moves.</p>' +
            '<p><em>Distribution</em> &mdash; Delivers changes from the distribution database to each subscriber. ' +
            'Each subscriber has its own Distribution agent.</p>' +
            '<p><strong>Key Metrics:</strong></p>' +
            '<p><em>Pending</em> &mdash; Commands waiting to be delivered. Zero or low single digits is normal. ' +
            'A rising number means the agent is falling behind.</p>' +
            '<p><em>Delivery Rate</em> &mdash; How fast the agent is processing commands (commands per second).</p>' +
            '<p><em>Latency</em> &mdash; Round-trip time for a test token to travel the full pipeline. ' +
            'Low single-digit milliseconds is healthy.</p>' +
            '<p><strong>Status Badges:</strong></p>' +
            '<p><span style="color:#4ec9b0;">IDLE</span> = Healthy, waiting for new work &nbsp; ' +
            '<span style="color:#4ec9b0;">RUNNING</span> = Actively delivering &nbsp; ' +
            '<span style="color:#dcdcaa;">RETRYING</span> = Hit an error, trying again &nbsp; ' +
            '<span style="color:#f48771;">STOPPED</span> = Not running (expected during BIDATA builds) &nbsp; ' +
            '<span style="color:#f48771;">FAILED</span> = Something is wrong</p>'
    },
    'queue-depth': {
        title: 'Queue Depth',
        body: '<p><strong>What am I looking at?</strong></p>' +
            '<p>This chart shows how many commands are waiting to be delivered to each subscriber over time. ' +
            'Think of it as the "inbox" for each destination server.</p>' +
            '<p><strong>What\'s normal?</strong></p>' +
            '<p>During regular operations, you\'ll see low numbers (single or double digits) bouncing around near zero. ' +
            'This means replication is keeping up with changes as they happen.</p>' +
            '<p><strong>What to watch for:</strong></p>' +
            '<p><em>Gradual climb</em> &mdash; The agent is falling behind. Could be slow network, busy subscriber, or heavy publisher activity.</p>' +
            '<p><em>Sudden spike then flat line</em> &mdash; Agent was stopped (e.g., BIDATA build window). ' +
            'Commands pile up while the agent is off, then drain quickly when it restarts. This is expected behavior.</p>' +
            '<p><em>Spike that doesn\'t drain</em> &mdash; Agent restarted but can\'t catch up. Needs investigation.</p>'
    },
    'latency': {
        title: 'End-to-End Latency',
        body: '<p><strong>What am I looking at?</strong></p>' +
            '<p>Every few minutes, xFACts sends a "tracer token" through the replication pipeline &mdash; ' +
            'a tiny test message that travels the same path as real data. This chart shows how long each token ' +
            'took to complete the full journey.</p>' +
            '<p><strong>The three hops:</strong></p>' +
            '<p>1. <em>Publisher &rarr; Distributor</em> (Log Reader picks it up)<br>' +
            '2. <em>Distributor &rarr; Subscriber</em> (Distribution agent delivers it)<br>' +
            'Total = sum of both hops</p>' +
            '<p><strong>What\'s normal?</strong></p>' +
            '<p>Single-digit milliseconds. Your pipeline is fast &mdash; changes typically arrive at subscribers ' +
            'within a few milliseconds of being committed on the publisher.</p>' +
            '<p><strong>What to watch for:</strong></p>' +
            '<p><em>Spikes</em> &mdash; Brief spikes during heavy activity are normal. Sustained high latency means ' +
            'something in the pipeline is bottlenecked.</p>' +
            '<p><em>Missing data points</em> &mdash; If an agent is stopped, tracer tokens can\'t complete the journey. ' +
            'Gaps in the chart during BIDATA build windows are expected.</p>'
    },
    'throughput': {
        title: 'Delivery Rate',
        body: '<p><strong>What am I looking at?</strong></p>' +
            '<p>This chart shows how fast each agent is delivering commands, measured in commands per second. ' +
            'The Y-axis uses a logarithmic scale because the Log Reader typically operates at a much higher rate ' +
            'than the Distribution agents.</p>' +
            '<p><strong>Why the different scales?</strong></p>' +
            '<p>The <em>Log Reader</em> reads ALL changes from the transaction log for every publication, ' +
            'so its rate is always the highest. Distribution agents only deliver changes for their specific ' +
            'subscriber, so their rates are lower.</p>' +
            '<p><strong>Note about this metric:</strong></p>' +
            '<p>The delivery rate shown is a cumulative average reported by SQL Server, not a point-in-time rate. ' +
            'This means it tends to be stable over time and doesn\'t show moment-to-moment spikes. ' +
            'For real-time throughput changes, the Queue Depth chart is a better indicator.</p>' +
            '<p><strong>What to watch for:</strong></p>' +
            '<p><em>Rate drops to zero</em> &mdash; Agent is stopped or failed.<br>' +
            '<em>Significant rate change</em> &mdash; Could indicate a change in workload patterns or performance issues.</p>'
    },
    'event-log': {
        title: 'Event Log',
        body: '<p><strong>What am I looking at?</strong></p>' +
            '<p>A timeline of significant events &mdash; when agents start, stop, change state, or encounter errors. ' +
            'Think of it as the "what happened" record.</p>' +
            '<p><strong>Event Types:</strong></p>' +
            '<p><span style="color:#4ec9b0;">AGENT START</span> &mdash; An agent began running<br>' +
            '<span style="color:#f48771;">AGENT STOP</span> &mdash; An agent was stopped<br>' +
            '<span style="color:#569cd6;">STATE CHANGE</span> &mdash; Agent transitioned between states<br>' +
            '<span style="color:#dcdcaa;">RETRY</span> &mdash; Agent hit an error and is retrying<br>' +
            '<span style="color:#f48771;">ERROR</span> &mdash; An error was detected</p>' +
            '<p><strong>BIDATA_BUILD tag:</strong></p>' +
            '<p>When an agent stop correlates with an active BIDATA build, it\'s tagged with ' +
            '<span style="color:#569cd6;">BIDATA_BUILD</span>. This means the stop was expected &mdash; ' +
            'Distribution agents are intentionally stopped during the nightly build to prevent replication ' +
            'from interfering with the data load process.</p>'
    }
};

function createInfoIcon(sectionKey) {
    return '<span class="info-icon" onclick="openInfoPanel(\'' + sectionKey + '\')" title="What is this?">&#9432;</span>';
}

function openInfoPanel(sectionKey) {
    var info = sectionInfo[sectionKey];
    if (!info) return;
    
    document.getElementById('info-panel-title').textContent = info.title;
    document.getElementById('info-panel-body').innerHTML = info.body;
    document.getElementById('info-overlay').classList.add('open');
    document.getElementById('info-panel').classList.add('open');
}

function closeInfoPanel() {
    document.getElementById('info-overlay').classList.remove('open');
    document.getElementById('info-panel').classList.remove('open');
}

// ============================================================================
// REFRESH ARCHITECTURE
// ============================================================================
// All sections are event-driven (data populated by Collect-ReplicationHealth
// on a 60-second orchestrator cycle). Live polling plumbing is ready for
// future use. Time-range buttons on charts are action-driven client-side
// controls that re-fetch with different parameters.
// See: Refresh Architecture doc, Section 6.8
// ============================================================================

async function loadRefreshInterval() {
    try {
        var data = await engineFetch('/api/config/refresh-interval?page=replication');
        if (data) {
            // engineFetch handles auth and returns parsed JSON
            PAGE_REFRESH_INTERVAL = data.interval || 10;
        }
    } catch (e) {
        // API unavailable — use default
    }
}

function startLivePolling() {
    if (livePollingTimer) clearInterval(livePollingTimer);
    livePollingTimer = setInterval(function() {
        if (enginePageHidden || engineSessionExpired) return;
        refreshLiveSections();
    }, PAGE_REFRESH_INTERVAL * 1000);
}

function stopLivePolling() {
    if (livePollingTimer) {
        clearInterval(livePollingTimer);
        livePollingTimer = null;
    }
}

function startAutoRefresh() {
    setInterval(function() {
        var today = new Date().toDateString();
        if (today !== pageLoadDate) {
            window.location.reload();
        }
    }, 60000);
}

// ── Live sections: placeholder for future direct polling ──
function refreshLiveSections() {
    // Currently unused — all sections are event-driven.
    updateTimestamp();
}

// ── Event-driven sections: refresh on orchestrator PROCESS_COMPLETED ──
function refreshEventSections() {
    loadAgentStatus();
    refreshAllCharts();
    loadEvents();
    updateTimestamp();
}

// ── Manual refresh: everything ──
function refreshAll() {
    loadAgentStatus();
    loadQueueChart();
    loadLatencyChart();
    loadThroughputChart();
    loadEvents();
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
    var el = document.getElementById('last-update');
    if (el) el.textContent = new Date().toLocaleTimeString();
}

// Called by engine-events.js when a relevant PROCESS_COMPLETED event arrives
function onEngineProcessCompleted(processName, event) {
    refreshEventSections();
}

// ============================================================================
// INITIALIZATION
// ============================================================================
document.addEventListener('DOMContentLoaded', async function() {
    // Inject info panel HTML
    injectInfoPanel();
    
    // Inject info icons into section headers
    injectInfoIcons();
    
    await loadRefreshInterval();
    loadThresholds();
    
    // Initialize event log date picker to today
    var datePicker = document.getElementById('event-date-picker');
    if (datePicker) datePicker.value = eventDate;
    
    refreshAll();
    connectEngineEvents();
    initEngineCardClicks();
    startAutoRefresh();
    
    // Time button handlers
    document.querySelectorAll('.time-btn').forEach(function(btn) {
        btn.addEventListener('click', function() {
            var chart = this.getAttribute('data-chart');
            var minutes = parseInt(this.getAttribute('data-minutes'));
            
            // Update active state for this chart's buttons
            this.parentElement.querySelectorAll('.time-btn').forEach(function(b) { b.classList.remove('active'); });
            this.classList.add('active');
            
            // Destroy chart so it rebuilds fresh with new time range
            if (chart === 'queue') { queueMinutes = minutes; if (queueChart) { queueChart.destroy(); queueChart = null; } loadQueueChart(); }
            else if (chart === 'latency') { latencyMinutes = minutes; if (latencyChart) { latencyChart.destroy(); latencyChart = null; } loadLatencyChart(); }
            else if (chart === 'throughput') { throughputMinutes = minutes; if (throughputChart) { throughputChart.destroy(); throughputChart = null; } loadThroughputChart(); }
        });
    });
});

function injectInfoPanel() {
    var panelHtml = '<div id="info-overlay" class="info-overlay" onclick="closeInfoPanel()"></div>' +
        '<div id="info-panel" class="info-panel">' +
        '<div class="info-panel-header">' +
        '<h3 id="info-panel-title"></h3>' +
        '<button class="info-panel-close" onclick="closeInfoPanel()">&times;</button>' +
        '</div>' +
        '<div id="info-panel-body" class="info-panel-body"></div>' +
        '</div>';
    document.body.insertAdjacentHTML('beforeend', panelHtml);
}

function injectInfoIcons() {
    var mappings = [
        { title: 'Agent Status', key: 'agent-status' },
        { title: 'Queue Depth', key: 'queue-depth' },
        { title: 'End-to-End Latency', key: 'latency' },
        { title: 'Delivery Rate', key: 'throughput' },
        { title: 'Event Log', key: 'event-log' }
    ];
    
    var headers = document.querySelectorAll('.section-title');
    headers.forEach(function(header) {
        mappings.forEach(function(m) {
            if (header.textContent.trim() === m.title) {
                header.innerHTML = header.textContent + ' ' + createInfoIcon(m.key);
            }
        });
    });
}

// ============================================================================
// THRESHOLDS
// ============================================================================
function loadThresholds() {
    engineFetch('/api/replication/thresholds')
        .then(function(data) {
            if (!data) return;
            if (!data.Error) {
                Object.keys(data).forEach(function(k) { thresholds[k] = parseInt(data[k]); });
            }
        })
        .catch(function() {});
}

// ============================================================================
// AGENT STATUS CARDS
// ============================================================================
function loadAgentStatus() {
    engineFetch('/api/replication/agent-status')
        .then(function(data) {
            if (!data) return;
            if (data.Error) { showError('Agent status: ' + data.Error); return; }
            clearError();
            
            // Capture agent list for event log filter
            eventAgents = (data || []).map(function(a) {
                var label = a.publication_name;
                if (a.agent_type === 'LogReader') label += ' (Log Reader)';
                else if (a.subscriber_name) label = a.subscriber_name;
                return { id: a.publication_registry_id, label: label, agent_type: a.agent_type };
            });
            renderEventAgentFilter();
            
            renderAgentCards(data);
            updateTimestamp();
        })
        .catch(function(err) { showError('Failed to load agent status: ' + err.message); });
}

function renderAgentCards(agents) {
    var container = document.getElementById('agent-cards');
    if (!agents || agents.length === 0) {
        container.innerHTML = '<div class="no-data">No agents discovered yet.</div>';
        return;
    }
    
    var html = '';
    agents.forEach(function(a) {
        var statusClass = getStatusClass(a.run_status);
        var statusText = getStatusText(a.run_status);
        var badgeClass = getBadgeClass(a.run_status);
        
        // Check for stopped message quirk
        if (a.run_status === 2 && a.agent_message && a.agent_message.indexOf('successfully stopped') > -1) {
            statusClass = 'stopped';
            statusText = 'Stopped';
            badgeClass = 'badge-stopped';
        }
        
        // Queue depth coloring
        var queueClass = 'queue-healthy';
        var pendingCount = a.pending_command_count;
        if (pendingCount !== null && pendingCount !== undefined) {
            if (pendingCount >= thresholds.replication_queue_critical_threshold) queueClass = 'queue-critical';
            else if (pendingCount >= thresholds.replication_queue_warning_threshold) queueClass = 'queue-warning';
        }
        
        html += '<div class="agent-card status-' + statusClass + '">';
        
        // Header
        html += '<div class="agent-card-header">';
        html += '<div>';
        html += '<div class="agent-card-title">' + escapeHtml(a.publication_name);
        if (a.agent_type === 'LogReader') {
            html += ' <span class="agent-type-tag tag-logreader">Log Reader</span>';
        } else {
            var tagClass = (a.subscription_type_desc || '').toLowerCase().indexOf('push') >= 0 ? 'tag-push' : 'tag-pull';
            html += ' <span class="agent-type-tag ' + tagClass + '">' + escapeHtml(a.subscription_type_desc) + '</span>';
        }
        html += '</div>';
        if (a.agent_type !== 'LogReader') {
            html += '<div class="agent-card-subtitle">' + escapeHtml(a.subscriber_name) + '</div>';
        } else {
            var serverName = 'DM-PROD-DB';
            if (a.agent_name && a.publisher_db) {
                var dbIdx = a.agent_name.indexOf(a.publisher_db);
                if (dbIdx > 1) serverName = a.agent_name.substring(0, dbIdx - 1);
            }
            html += '<div class="agent-card-subtitle">' + escapeHtml(serverName) + '</div>';
        }
        html += '</div>';
        html += '<span class="agent-status-badge ' + badgeClass + '">' + statusText + '</span>';
        html += '</div>';
        
        // Metrics
        html += '<div class="agent-card-metrics">';
        
        // Queue depth (Distribution only)
        if (a.agent_type === 'Distribution') {
            html += '<div class="agent-metric">';
            html += '<div class="agent-metric-label">Pending</div>';
            html += '<div class="agent-metric-value ' + queueClass + '">' + 
                formatNumber(pendingCount) + '</div>';
            html += '</div>';
        }
        
        // Delivered commands (LogReader only)
        if (a.agent_type === 'LogReader') {
            html += '<div class="agent-metric">';
            html += '<div class="agent-metric-label">Delivered</div>';
            html += '<div class="agent-metric-value">' + 
                (a.delivered_commands !== null ? formatNumber(a.delivered_commands) : '-') + '</div>';
            html += '</div>';
        }
        
        // Delivery rate
        html += '<div class="agent-metric">';
        html += '<div class="agent-metric-label">Delivery Rate</div>';
        html += '<div class="agent-metric-value">' + 
            (a.delivery_rate !== null ? formatNumber(Math.round(a.delivery_rate)) : '-') + 
            ' <span class="agent-metric-unit">cmd/s</span></div>';
        html += '</div>';
        
        // Latency (Distribution only)
        if (a.agent_type === 'Distribution') {
            html += '<div class="agent-metric">';
            html += '<div class="agent-metric-label">Latency</div>';
            html += '<div class="agent-metric-value">' + 
                (a.latest_latency_ms !== null ? a.latest_latency_ms + ' <span class="agent-metric-unit">ms</span>' : '-') + 
                '</div>';
            html += '</div>';
        }
        
        // Est. Processing (LogReader only)
        if (a.agent_type === 'LogReader') {
            html += '<div class="agent-metric">';
            html += '<div class="agent-metric-label">Backlog</div>';
            html += '<div class="agent-metric-value">' + 
                (a.estimated_processing_seconds !== null ? a.estimated_processing_seconds + ' <span class="agent-metric-unit">sec</span>' : '-') + 
                '</div>';
            html += '</div>';
        }
        
        // Last action time
        html += '<div class="agent-metric">';
        html += '<div class="agent-metric-label">Last Activity</div>';
        html += '<div class="agent-metric-value" style="font-size:12px;">' + 
            formatTimeAgo(a.agent_action_dttm) + '</div>';
        html += '</div>';
        
        html += '</div>'; // metrics
        html += '</div>'; // card
    });
    
    container.innerHTML = html;
}

// ============================================================================
// CHARTS
// ============================================================================
function getHiddenLabels(chart) {
    // Capture which datasets are currently hidden via legend toggle
    var hidden = {};
    if (chart && chart.data && chart.data.datasets) {
        chart.data.datasets.forEach(function(ds, i) {
            if (chart.getDatasetMeta(i).hidden) {
                hidden[ds.label] = true;
            }
        });
    }
    return hidden;
}

function applyHiddenLabels(chart, hiddenLabels) {
    // Restore hidden state after dataset replacement
    if (chart && chart.data && chart.data.datasets) {
        chart.data.datasets.forEach(function(ds, i) {
            if (hiddenLabels[ds.label]) {
                chart.getDatasetMeta(i).hidden = true;
            }
        });
    }
}

function refreshAllCharts() {
    loadQueueChart();
    loadLatencyChart();
    loadThroughputChart();
}

function loadQueueChart() {
    engineFetch('/api/replication/queue-history?minutes=' + queueMinutes)
        .then(function(data) {
            if (!data) return;
            if (data.Error) return;
            renderQueueChart(data);
        })
        .catch(function() {});
}

function loadLatencyChart() {
    engineFetch('/api/replication/latency-history?minutes=' + latencyMinutes)
        .then(function(data) {
            if (!data) return;
            if (data.Error) return;
            renderLatencyChart(data);
        })
        .catch(function() {});
}

function loadThroughputChart() {
    engineFetch('/api/replication/throughput-history?minutes=' + throughputMinutes)
        .then(function(data) {
            if (!data) return;
            if (data.Error) return;
            renderThroughputChart(data);
        })
        .catch(function() {});
}

function renderQueueChart(data) {
    var ctx = document.getElementById('queue-chart').getContext('2d');
    
    // Group by publication
    var series = {};
    data.forEach(function(d) {
        if (!series[d.publication_name]) series[d.publication_name] = [];
        series[d.publication_name].push({
            x: new Date(d.collected_dttm),
            y: d.pending_command_count
        });
    });
    
    var datasets = Object.keys(series).map(function(name) {
        var color = getColor(name);
        return {
            label: name,
            data: series[name],
            borderColor: color.line,
            backgroundColor: color.fill,
            borderWidth: 1.5,
            pointRadius: 0,
            pointHitRadius: 8,
            tension: 0.3,
            fill: true
        };
    });
    
    // Update in place if chart exists (preserves legend toggle state)
    if (queueChart) {
        var hidden = getHiddenLabels(queueChart);
        queueChart.data.datasets = datasets;
        applyHiddenLabels(queueChart, hidden);
        queueChart.update('none');
        return;
    }
    queueChart = new Chart(ctx, {
        type: 'line',
        data: { datasets: datasets },
        options: getChartOptions('Pending Commands', false)
    });
}

function renderLatencyChart(data) {
    var ctx = document.getElementById('latency-chart').getContext('2d');
    
    var series = {};
    data.forEach(function(d) {
        var key = d.publication_name;
        if (!series[key]) series[key] = [];
        series[key].push({
            x: new Date(d.collected_dttm),
            y: d.total_latency_ms
        });
    });
    
    var datasets = Object.keys(series).map(function(name) {
        var color = getColor(name);
        return {
            label: name,
            data: series[name],
            borderColor: color.line,
            backgroundColor: color.fill,
            borderWidth: 1.5,
            pointRadius: 2,
            pointHitRadius: 8,
            tension: 0.3,
            fill: false
        };
    });
    
    if (latencyChart) {
        var hidden = getHiddenLabels(latencyChart);
        latencyChart.data.datasets = datasets;
        applyHiddenLabels(latencyChart, hidden);
        latencyChart.update('none');
        return;
    }
    latencyChart = new Chart(ctx, {
        type: 'line',
        data: { datasets: datasets },
        options: getChartOptions('Latency (ms)', false)
    });
}

function renderThroughputChart(data) {
    var ctx = document.getElementById('throughput-chart').getContext('2d');
    
    var series = {};
    data.forEach(function(d) {
        var key = d.publication_name + (d.agent_type === 'LogReader' ? ' (LR)' : '');
        if (!series[key]) series[key] = { name: d.publication_name, data: [] };
        series[key].data.push({
            x: new Date(d.collected_dttm),
            y: d.delivery_rate
        });
    });
    
    var datasets = Object.keys(series).map(function(key) {
        var color = getColor(series[key].name);
        return {
            label: key,
            data: series[key].data,
            borderColor: color.line,
            backgroundColor: color.fill,
            borderWidth: 1.5,
            pointRadius: 0,
            pointHitRadius: 8,
            tension: 0.3,
            fill: false
        };
    });
    
    if (throughputChart) {
        var hidden = getHiddenLabels(throughputChart);
        throughputChart.data.datasets = datasets;
        applyHiddenLabels(throughputChart, hidden);
        throughputChart.update('none');
        return;
    }
    throughputChart = new Chart(ctx, {
        type: 'line',
        data: { datasets: datasets },
        options: getChartOptions('Commands/sec', true)
    });
}

function getChartOptions(yLabel, logarithmic) {
    return {
        responsive: true,
        maintainAspectRatio: false,
        interaction: {
            mode: 'index',
            intersect: false
        },
        plugins: {
            legend: {
                display: true,
                position: 'top',
                labels: {
                    color: '#888',
                    font: { size: 11 },
                    boxWidth: 12,
                    padding: 12
                }
            },
            tooltip: {
                backgroundColor: '#333',
                titleColor: '#d4d4d4',
                bodyColor: '#d4d4d4',
                borderColor: '#555',
                borderWidth: 1,
                titleFont: { size: 11 },
                bodyFont: { size: 11 },
                padding: 8,
                callbacks: {
                    title: function(items) {
                        if (items.length > 0) {
                            return items[0].raw.x.toLocaleString();
                        }
                        return '';
                    },
                    label: function(context) {
                        return context.dataset.label + ': ' + formatNumber(context.raw.y);
                    }
                }
            }
        },
        scales: {
            x: {
                type: 'time',
                time: {
                    displayFormats: {
                        minute: 'HH:mm',
                        hour: 'HH:mm',
                        day: 'MMM d'
                    }
                },
                grid: { color: 'rgba(255,255,255,0.05)' },
                ticks: { color: '#666', font: { size: 10 }, maxRotation: 0 }
            },
            y: {
                type: logarithmic ? 'logarithmic' : 'linear',
                beginAtZero: !logarithmic,
                grid: { color: 'rgba(255,255,255,0.05)' },
                ticks: { 
                    color: '#666', 
                    font: { size: 10 },
                    callback: function(value) { return formatNumber(value); }
                },
                title: {
                    display: true,
                    text: yLabel,
                    color: '#666',
                    font: { size: 11 }
                }
            }
        }
    };
}

// ============================================================================
// EVENT LOG
// ============================================================================
function loadEvents() {
    var url = '/api/replication/events';
    if (eventCorrelationMode) {
        url += '?correlated=1';
        if (eventAgentFilter !== 'ALL') url += '&agent=' + eventAgentFilter;
    } else {
        url += '?date=' + eventDate;
        if (eventAgentFilter !== 'ALL') url += '&agent=' + eventAgentFilter;
    }
    
    engineFetch(url)
        .then(function(data) {
            if (!data) return;
            if (data.Error) return;
            renderEvents(data);
        })
        .catch(function() {});
}

function onEventDateChange() {
    var picker = document.getElementById('event-date-picker');
    if (picker && picker.value) {
        eventDate = picker.value;
        // Switching date exits correlation mode
        if (eventCorrelationMode) {
            eventCorrelationMode = false;
            document.getElementById('btn-correlated').classList.remove('active');
            document.getElementById('event-date-picker').disabled = false;
        }
        loadEvents();
    }
}

function toggleCorrelationMode() {
    eventCorrelationMode = !eventCorrelationMode;
    var btn = document.getElementById('btn-correlated');
    var picker = document.getElementById('event-date-picker');
    
    if (eventCorrelationMode) {
        btn.classList.add('active');
        picker.disabled = true;
    } else {
        btn.classList.remove('active');
        picker.disabled = false;
    }
    loadEvents();
}

function setEventAgentFilter(agentId) {
    eventAgentFilter = agentId;
    // Update button highlights
    document.querySelectorAll('.event-agent-btn').forEach(function(b) {
        b.classList.toggle('active', b.getAttribute('data-agent') === String(agentId));
    });
    loadEvents();
}

function renderEventAgentFilter() {
    var container = document.getElementById('event-agent-filter');
    if (!container) return;
    
    var html = '<button class="event-agent-btn active" data-agent="ALL" onclick="setEventAgentFilter(\'ALL\')">All</button>';
    eventAgents.forEach(function(a) {
        html += '<button class="event-agent-btn" data-agent="' + a.id + '" onclick="setEventAgentFilter(\'' + a.id + '\')">' + escapeHtml(a.label) + '</button>';
    });
    container.innerHTML = html;
}

function renderEvents(data) {
    var container = document.getElementById('event-log');
    
    if (!data.events || data.events.length === 0) {
        var msg = eventCorrelationMode ? 'No correlated events found' : 'No events for ' + eventDate;
        container.innerHTML = '<div class="no-data">' + msg + '</div>';
        return;
    }
    
    container.innerHTML = buildEventRows(data.events);
}

function buildEventRows(events) {
    var html = '';
    events.forEach(function(e) {
        html += '<div class="event-row">';
        html += '<span class="event-time">' + formatEventTime(e.event_dttm) + '</span>';
        html += '<span class="event-type-badge event-type-' + e.event_type + '">' + 
            e.event_type.replace('_', ' ') + '</span>';
        html += '<span class="event-publication">' + escapeHtml(e.publication_name) + 
            ' <span class="event-agent-type">(' + e.agent_type + ')</span></span>';
        
        // Always render transition span for column alignment
        html += '<span class="event-transition">';
        if (e.previous_state_desc || e.current_state_desc) {
            if (e.previous_state_desc) {
                html += '<span class="state-from">' + e.previous_state_desc + '</span>';
                html += '<span class="state-arrow">&rarr;</span>';
            }
            if (e.current_state_desc) {
                html += '<span class="state-to">' + e.current_state_desc + '</span>';
            }
        }
        html += '</span>';
        
        // Correlation badge (between transition and message)
        if (e.correlation_source) {
            html += '<span class="event-correlation" title="' + escapeHtml(e.correlation_source) + '">B</span>';
        }
        
        // Message takes remaining space
        html += '<span class="event-message">';
        if (e.event_message && e.event_message.indexOf('Performance stats') === -1) {
            html += '<span class="event-message-text" title="' + escapeHtml(e.event_message) + '">' + 
                escapeHtml(e.event_message) + '</span>';
        }
        html += '</span>';
        
        html += '</div>';
    });
    return html;
}

// ============================================================================
// HELPER FUNCTIONS
// ============================================================================
function getStatusClass(runStatus) {
    switch (runStatus) {
        case 1: return 'healthy';
        case 2: return 'healthy';
        case 3: return 'idle';
        case 4: return 'warning';
        case 5: return 'critical';
        case 6: return 'stopped';
        default: return 'unknown';
    }
}

function getStatusText(runStatus) {
    switch (runStatus) {
        case 1: return 'Started';
        case 2: return 'Running';
        case 3: return 'Idle';
        case 4: return 'Retrying';
        case 5: return 'Failed';
        case 6: return 'Stopped';
        default: return 'Unknown';
    }
}

function getBadgeClass(runStatus) {
    switch (runStatus) {
        case 1: return 'badge-started';
        case 2: return 'badge-running';
        case 3: return 'badge-idle';
        case 4: return 'badge-retrying';
        case 5: return 'badge-failed';
        case 6: return 'badge-stopped';
        default: return 'badge-unknown';
    }
}

function formatNumber(n) {
    if (n === null || n === undefined) return '-';
    if (n >= 1000000) return (n / 1000000).toFixed(1) + 'M';
    if (n >= 1000) return (n / 1000).toFixed(1) + 'K';
    return n.toLocaleString();
}

function formatTimeAgo(dateStr) {
    if (!dateStr) return '-';
    var diff = (new Date() - new Date(dateStr)) / 1000;
    if (isNaN(diff)) return '-';
    if (diff < 60) return Math.round(diff) + 's ago';
    if (diff < 3600) return Math.round(diff / 60) + 'm ago';
    if (diff < 86400) return Math.round(diff / 3600) + 'h ago';
    return Math.round(diff / 86400) + 'd ago';
}

function formatEventTime(dateStr) {
    if (!dateStr) return '-';
    var d = new Date(dateStr);
    if (isNaN(d.getTime())) return '-';
    var time = d.toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false });
    if (eventCorrelationMode) {
        var date = (d.getMonth() + 1) + '/' + d.getDate();
        return date + ' ' + time;
    }
    return time;
}

function escapeHtml(text) {
    if (!text) return '';
    return text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

function updateTimestamp() {
    document.getElementById('last-update').textContent = new Date().toLocaleTimeString();
}

function showError(msg) {
    var el = document.getElementById('connection-error');
    el.textContent = msg;
    el.classList.add('visible');
}

function clearError() {
    document.getElementById('connection-error').classList.remove('visible');
}

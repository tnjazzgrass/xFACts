/* ============================================================================
   xFACts Control Center - Replication Monitoring JavaScript (replication-monitoring.js)
   Location: E:\xFACts-ControlCenter\public\js\replication-monitoring.js
   Version: Tracked in dbo.System_Metadata (component: ServerOps.Replication)

   Page-specific JS for the Replication Monitoring dashboard. Universal
   chrome (WebSocket events, connection banner, page refresh button, idle
   detection, session expiry, shared modals, formatting utilities) is
   provided by cc-shared.js. This file contains the data loading and
   rendering logic for the agent status cards, the queue / latency /
   throughput line charts with their per-chart time-range controls, the
   event log with date and agent filters and BIDATA-correlation mode,
   and the section info panel that surfaces explanatory text on each
   section header.

   FILE ORGANIZATION
   -----------------
   CONSTANTS: ENGINE PROCESSES
   CONSTANTS: SECTION INFO TEXT
   CONSTANTS: CHART COLORS
   CONSTANTS: THRESHOLD DEFAULTS
   STATE: PAGE STATE
   INITIALIZATION: PAGE BOOT
   FUNCTIONS: REFRESH
   FUNCTIONS: INFO PANEL
   FUNCTIONS: AGENT STATUS
   FUNCTIONS: CHARTS
   FUNCTIONS: EVENT LOG
   FUNCTIONS: HELPERS
   FUNCTIONS: PAGE LIFECYCLE HOOKS
   ============================================================================ */

/* ============================================================================
   CONSTANTS: ENGINE PROCESSES
   ----------------------------------------------------------------------------
   The ENGINE_PROCESSES contract: a map from orchestrator process names to
   engine card slugs that cc-shared.js reads at startup to wire up the
   engine indicator subsystem. The Replication Monitoring page has a
   single collector, Collect-ReplicationHealth, that drives every section
   on the page on its 60-second cycle.
   Prefix: (none)
   ============================================================================ */

/* Maps orchestrator process names to engine card slugs. cc-shared.js
   reads this at startup; each entry binds a process to a card on the
   page. Card refreshes for the bound process happen automatically via
   onEngineProcessCompleted. */
const ENGINE_PROCESSES = {
    'Collect-ReplicationHealth': { slug: 'replication' }
};

/* ============================================================================
   CONSTANTS: SECTION INFO TEXT
   ----------------------------------------------------------------------------
   The static body text shown by the section info panel. Keys correspond
   to the data-section attributes the info icons carry; values hold the
   modal title and the HTML body. Stored as a constant rather than fetched
   from the server because the text is documentation, not operational
   data, and never varies per request.
   Prefix: rpm
   ============================================================================ */

/* Per-section explanatory text shown when the user clicks the info icon
   in a section header. Each entry has a title and an HTML body. */
const rpm_SECTION_INFO = {
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

/* Section header titles paired with their info-panel keys. The info
   icon injection routine looks up section headers by these titles and
   appends an icon that opens the matching info panel entry. */
const rpm_INFO_ICON_MAPPINGS = [
    { title: 'Agent Status', key: 'agent-status' },
    { title: 'Queue Depth', key: 'queue-depth' },
    { title: 'End-to-End Latency', key: 'latency' },
    { title: 'Delivery Rate', key: 'throughput' },
    { title: 'Event Log', key: 'event-log' }
];

/* ============================================================================
   CONSTANTS: CHART COLORS
   ----------------------------------------------------------------------------
   Per-publication line and fill colors used by all three charts (queue,
   latency, throughput). Keyed by publication name; falls back to a
   neutral gray for any publication not in the map.
   Prefix: rpm
   ============================================================================ */

/* Maps publication names to chart line/fill colors. Used by all three
   line charts (queue, latency, throughput) so a publication has a
   consistent color across charts. */
const rpm_CHART_COLORS = {
    'BIDATALoad':         { line: '#4ec9b0', fill: 'rgba(78, 201, 176, 0.08)' },
    'Azure_BIDATA_Load':  { line: '#569cd6', fill: 'rgba(86, 156, 214, 0.08)' },
    'BIDATA_Load_POC':    { line: '#dcdcaa', fill: 'rgba(220, 220, 170, 0.08)' },
    'crs5_oltp':          { line: '#c586c0', fill: 'rgba(197, 134, 192, 0.08)' }
};

/* Fallback color for any publication not in rpm_CHART_COLORS. */
const rpm_CHART_COLOR_FALLBACK = { line: '#888', fill: 'rgba(136, 136, 136, 0.08)' };

/* ============================================================================
   CONSTANTS: THRESHOLD DEFAULTS
   ----------------------------------------------------------------------------
   Default thresholds used to color the agent status cards before the
   /api/replication/thresholds endpoint responds. Once the response lands,
   these values are merged into rpm_thresholds with any per-installation
   overrides taking precedence.
   Prefix: rpm
   ============================================================================ */

/* Default queue and latency thresholds. Overridden at page load by
   rpm_loadThresholds with values from the thresholds API. */
const rpm_THRESHOLD_DEFAULTS = {
    replication_queue_warning_threshold:  5000,
    replication_queue_critical_threshold: 50000,
    replication_latency_warning_ms:       30000,
    replication_latency_critical_ms:      120000
};

/* ============================================================================
   STATE: PAGE STATE
   ----------------------------------------------------------------------------
   Module-scope mutable state for the Replication Monitoring UI: the
   page-load date for midnight rollover detection, the three Chart.js
   instance handles, the per-chart time-range selection, the event log
   date/agent/correlation filters, the cached agent list that backs the
   event log filter buttons, and the runtime thresholds that drive the
   agent card status colors.
   Prefix: rpm
   ============================================================================ */

/* Date string captured at page load. Compared against the current date
   inside the auto-refresh timer to trigger a full reload at midnight. */
var rpm_pageLoadDate = new Date().toDateString();

/* Chart.js instance for the Queue Depth chart, or null when not yet
   created. Re-rendered in place to preserve legend toggle state. */
var rpm_queueChart = null;

/* Chart.js instance for the End-to-End Latency chart, or null when not
   yet created. */
var rpm_latencyChart = null;

/* Chart.js instance for the Delivery Rate chart, or null when not yet
   created. */
var rpm_throughputChart = null;

/* Active time range for the Queue Depth chart in minutes. Updated by
   the time-range buttons; passed to the queue-history API. */
var rpm_queueMinutes = 60;

/* Active time range for the End-to-End Latency chart in minutes. */
var rpm_latencyMinutes = 60;

/* Active time range for the Delivery Rate chart in minutes. */
var rpm_throughputMinutes = 60;

/* Active date filter for the event log, in YYYY-MM-DD format.
   Initialized to today on page boot; updated by the date picker. */
var rpm_eventDate = new Date().getFullYear() + '-' +
    String(new Date().getMonth() + 1).padStart(2, '0') + '-' +
    String(new Date().getDate()).padStart(2, '0');

/* Active agent filter for the event log. 'ALL' shows every agent;
   any other value is a publication_registry_id rendered as a string. */
var rpm_eventAgentFilter = 'ALL';

/* Cached agent list from the most recent agent-status response. Used
   to render the per-agent filter buttons above the event log. */
var rpm_eventAgents = [];

/* Whether the event log is in correlation mode (showing all
   BIDATA-correlated events across dates) or normal mode (filtered by
   rpm_eventDate). Toggled by the Correlated button. */
var rpm_eventCorrelationMode = false;

/* Runtime thresholds, initialized from rpm_THRESHOLD_DEFAULTS and
   overwritten with per-installation overrides loaded by
   rpm_loadThresholds from the thresholds API. */
var rpm_thresholds = {
    replication_queue_warning_threshold:  rpm_THRESHOLD_DEFAULTS.replication_queue_warning_threshold,
    replication_queue_critical_threshold: rpm_THRESHOLD_DEFAULTS.replication_queue_critical_threshold,
    replication_latency_warning_ms:       rpm_THRESHOLD_DEFAULTS.replication_latency_warning_ms,
    replication_latency_critical_ms:      rpm_THRESHOLD_DEFAULTS.replication_latency_critical_ms
};

/* ============================================================================
   INITIALIZATION: PAGE BOOT
   ----------------------------------------------------------------------------
   Single DOMContentLoaded handler that injects the info panel HTML and
   icons, loads the threshold overrides from the API, primes the date
   picker, runs the initial data load, registers the engine-events
   chrome with cc-shared.js, and wires the delegated click handlers for
   the info icons, the chart time-range buttons, and the event-log
   agent filter buttons.
   Prefix: (none)
   ============================================================================ */

document.addEventListener('DOMContentLoaded', async function() {
    rpm_injectInfoPanel();
    rpm_injectInfoIcons();

    rpm_loadThresholds();
    var datePicker = document.getElementById('event-date-picker');
    if (datePicker) datePicker.value = rpm_eventDate;

    rpm_refreshAll();
    connectEngineEvents();
    initEngineCardClicks();
    rpm_startAutoRefresh();

    document.body.addEventListener('click', rpm_onInfoIconClick);
    document.body.addEventListener('click', rpm_onTimeButtonClick);
    document.getElementById('event-agent-filter').addEventListener('click', rpm_onEventAgentFilterClick);
});

/* ============================================================================
   FUNCTIONS: REFRESH
   ----------------------------------------------------------------------------
   The page's refresh paths. All sections are event-driven (data
   populated by Collect-ReplicationHealth on a 60-second orchestrator
   cycle), so there is no live-polling timer; the auto-refresh timer
   only checks for midnight rollover. The refresh-all path runs a full
   reload; the refresh-event path runs everything except the chart
   loaders since charts re-render in place from cached series.
   Prefix: rpm
   ============================================================================ */

/* Refreshes every section on the page from its API endpoint. Called
   by the manual refresh button (via the onPageRefresh hook), by the
   onPageResumed hook on tab resume, and by the page boot handler. */
function rpm_refreshAll() {
    rpm_loadAgentStatus();
    rpm_loadQueueChart();
    rpm_loadLatencyChart();
    rpm_loadThroughputChart();
    rpm_loadEvents();
    rpm_updateTimestamp();
}

/* Refreshes the event-driven sections. Called by the
   onEngineProcessCompleted hook when Collect-ReplicationHealth
   finishes; runs the agent cards, all three charts, and the event log. */
function rpm_refreshEventSections() {
    rpm_loadAgentStatus();
    rpm_refreshAllCharts();
    rpm_loadEvents();
    rpm_updateTimestamp();
}

/* Starts the midnight-rollover check. Lightweight 60-second timer that
   reloads the page when the date changes. */
function rpm_startAutoRefresh() {
    setInterval(function() {
        var today = new Date().toDateString();
        if (today !== rpm_pageLoadDate) {
            window.location.reload();
        }
    }, 60000);
}

/* ============================================================================
   FUNCTIONS: INFO PANEL
   ----------------------------------------------------------------------------
   The "what is this?" info panel that explains each section. The panel
   HTML is injected once at page boot; the info icons are injected into
   matching section header titles; clicking an icon opens the panel
   with the section's pre-authored explanation.
   Prefix: rpm
   ============================================================================ */

/* Builds the info icon HTML for a section. The data-section attribute
   carries the section key so the delegated click handler can look up
   the matching info entry. */
function rpm_createInfoIcon(sectionKey) {
    return '<span class="info-icon" data-section="' + sectionKey + '" title="What is this?">&#9432;</span>';
}

/* Opens the info panel and populates it with the section's
   pre-authored title and body. No-op if the section key is unknown. */
function rpm_openInfoPanel(sectionKey) {
    var info = rpm_SECTION_INFO[sectionKey];
    if (!info) return;

    document.getElementById('info-panel-title').textContent = info.title;
    document.getElementById('info-panel-body').innerHTML = info.body;
    document.getElementById('info-overlay').classList.add('open');
    document.getElementById('info-panel').classList.add('open');
}

/* Closes the info panel and its overlay. Wired up from the overlay
   click and the close button (both bound directly when the panel is
   injected). */
function rpm_closeInfoPanel() {
    document.getElementById('info-overlay').classList.remove('open');
    document.getElementById('info-panel').classList.remove('open');
}

/* Injects the info panel HTML into the document body. The overlay and
   close button listeners are bound directly here since both are
   singletons that exist for the lifetime of the page after injection. */
function rpm_injectInfoPanel() {
    var panelHtml = '<div id="info-overlay" class="info-overlay"></div>' +
        '<div id="info-panel" class="info-panel">' +
        '<div class="info-panel-header">' +
        '<h3 id="info-panel-title"></h3>' +
        '<button class="info-panel-close">&times;</button>' +
        '</div>' +
        '<div id="info-panel-body" class="info-panel-body"></div>' +
        '</div>';
    document.body.insertAdjacentHTML('beforeend', panelHtml);

    document.getElementById('info-overlay').addEventListener('click', rpm_closeInfoPanel);
    document.querySelector('#info-panel .info-panel-close').addEventListener('click', rpm_closeInfoPanel);
}

/* Walks the page's section header titles and appends an info icon to
   any header whose text matches an entry in rpm_INFO_ICON_MAPPINGS. */
function rpm_injectInfoIcons() {
    var headers = document.querySelectorAll('.section-title');
    headers.forEach(function(header) {
        rpm_INFO_ICON_MAPPINGS.forEach(function(m) {
            if (header.textContent.trim() === m.title) {
                header.innerHTML = header.textContent + ' ' + rpm_createInfoIcon(m.key);
            }
        });
    });
}

/* Delegated click handler for info icons. Looks for a clicked element
   carrying a data-section attribute and opens the matching info panel. */
function rpm_onInfoIconClick(event) {
    var icon = event.target.closest('.info-icon');
    if (!icon) return;
    rpm_openInfoPanel(icon.dataset.section);
}

/* ============================================================================
   FUNCTIONS: AGENT STATUS
   ----------------------------------------------------------------------------
   The per-agent status cards: one card per replication agent (Log
   Reader and per-subscriber Distribution agents). Each card shows run
   state, key metrics (pending count, delivery rate, latency, last
   action), and a status badge. Threshold-driven coloring on the
   pending count flags falling-behind agents. Loading the agent list
   also populates the event log's agent filter, since the two views
   share the same agent inventory.
   Prefix: rpm
   ============================================================================ */

/* Loads threshold overrides from the API and merges them into the
   runtime thresholds. Falls back silently to the defaults if the API
   is unavailable. */
function rpm_loadThresholds() {
    engineFetch('/api/replication/thresholds')
        .then(function(data) {
            if (!data) return;
            if (!data.Error) {
                Object.keys(data).forEach(function(k) {
                    rpm_thresholds[k] = parseInt(data[k], 10);
                });
            }
        })
        .catch(function() {});
}

/* Loads the agent status data, populates the event log agent filter
   list as a side effect, and re-renders the cards. Updates the page
   timestamp on success. */
function rpm_loadAgentStatus() {
    engineFetch('/api/replication/agent-status')
        .then(function(data) {
            if (!data) return;
            if (data.Error) { rpm_showError('Agent status: ' + data.Error); return; }
            rpm_clearError();

            rpm_eventAgents = (data || []).map(function(a) {
                var label = a.publication_name;
                if (a.agent_type === 'LogReader') label += ' (Log Reader)';
                else if (a.subscriber_name) label = a.subscriber_name;
                return { id: a.publication_registry_id, label: label, agent_type: a.agent_type };
            });
            rpm_renderEventAgentFilter();

            rpm_renderAgentCards(data);
            rpm_updateTimestamp();
        })
        .catch(function(err) { rpm_showError('Failed to load agent status: ' + err.message); });
}

/* Renders the per-agent status cards. One card per agent with run-state
   coloring, queue-depth coloring derived from the loaded thresholds,
   and metric panels that vary by agent type (Log Reader vs
   Distribution). */
function rpm_renderAgentCards(agents) {
    var container = document.getElementById('agent-cards');
    if (!agents || agents.length === 0) {
        container.innerHTML = '<div class="no-data">No agents discovered yet.</div>';
        return;
    }

    var html = '';
    agents.forEach(function(a) {
        var statusClass = rpm_getStatusClass(a.run_status);
        var statusText = rpm_getStatusText(a.run_status);
        var badgeClass = rpm_getBadgeClass(a.run_status);

        /* SQL Server reports "successfully stopped" as run_status=2; treat
           that case as Stopped rather than Running. */
        if (a.run_status === 2 && a.agent_message && a.agent_message.indexOf('successfully stopped') > -1) {
            statusClass = 'stopped';
            statusText = 'Stopped';
            badgeClass = 'badge-stopped';
        }

        var queueClass = 'queue-healthy';
        var pendingCount = a.pending_command_count;
        if (pendingCount !== null && pendingCount !== undefined) {
            if (pendingCount >= rpm_thresholds.replication_queue_critical_threshold) queueClass = 'queue-critical';
            else if (pendingCount >= rpm_thresholds.replication_queue_warning_threshold) queueClass = 'queue-warning';
        }

        html += '<div class="agent-card status-' + statusClass + '">';

        /* Header. */
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

        /* Metrics. */
        html += '<div class="agent-card-metrics">';

        if (a.agent_type === 'Distribution') {
            html += '<div class="agent-metric">';
            html += '<div class="agent-metric-label">Pending</div>';
            html += '<div class="agent-metric-value ' + queueClass + '">' + rpm_formatNumber(pendingCount) + '</div>';
            html += '</div>';
        }

        if (a.agent_type === 'LogReader') {
            html += '<div class="agent-metric">';
            html += '<div class="agent-metric-label">Delivered</div>';
            html += '<div class="agent-metric-value">' +
                (a.delivered_commands !== null ? rpm_formatNumber(a.delivered_commands) : '-') + '</div>';
            html += '</div>';
        }

        html += '<div class="agent-metric">';
        html += '<div class="agent-metric-label">Delivery Rate</div>';
        html += '<div class="agent-metric-value">' +
            (a.delivery_rate !== null ? rpm_formatNumber(Math.round(a.delivery_rate)) : '-') +
            ' <span class="agent-metric-unit">cmd/s</span></div>';
        html += '</div>';

        if (a.agent_type === 'Distribution') {
            html += '<div class="agent-metric">';
            html += '<div class="agent-metric-label">Latency</div>';
            html += '<div class="agent-metric-value">' +
                (a.latest_latency_ms !== null ? a.latest_latency_ms + ' <span class="agent-metric-unit">ms</span>' : '-') +
                '</div>';
            html += '</div>';
        }

        if (a.agent_type === 'LogReader') {
            html += '<div class="agent-metric">';
            html += '<div class="agent-metric-label">Backlog</div>';
            html += '<div class="agent-metric-value">' +
                (a.estimated_processing_seconds !== null ? a.estimated_processing_seconds + ' <span class="agent-metric-unit">sec</span>' : '-') +
                '</div>';
            html += '</div>';
        }

        html += '<div class="agent-metric">';
        html += '<div class="agent-metric-label">Last Activity</div>';
        html += '<div class="agent-metric-value agent-metric-time">' + rpm_formatTimeAgo(a.agent_action_dttm) + '</div>';
        html += '</div>';

        html += '</div>';
        html += '</div>';
    });

    container.innerHTML = html;
}

/* ============================================================================
   FUNCTIONS: CHARTS
   ----------------------------------------------------------------------------
   The three line charts (queue depth, latency, delivery rate). Each
   chart has its own time-range selector and its own API endpoint;
   re-renders happen in place to preserve legend toggle state when
   data refreshes. The chart-options builder produces shared Chart.js
   configuration with per-chart Y-axis labels and an optional
   logarithmic scale (used by the throughput chart since the Log Reader
   typically operates an order of magnitude faster than the
   Distribution agents).
   Prefix: rpm
   ============================================================================ */

/* Loads and re-renders all three charts. Called by
   rpm_refreshEventSections. Each chart fetches its own time-windowed
   data so they can be advanced independently. */
function rpm_refreshAllCharts() {
    rpm_loadQueueChart();
    rpm_loadLatencyChart();
    rpm_loadThroughputChart();
}

/* Loads the queue history for the active time range and renders the
   queue chart. */
function rpm_loadQueueChart() {
    engineFetch('/api/replication/queue-history?minutes=' + rpm_queueMinutes)
        .then(function(data) {
            if (!data) return;
            if (data.Error) return;
            rpm_renderQueueChart(data);
        })
        .catch(function() {});
}

/* Loads the latency history for the active time range and renders the
   latency chart. */
function rpm_loadLatencyChart() {
    engineFetch('/api/replication/latency-history?minutes=' + rpm_latencyMinutes)
        .then(function(data) {
            if (!data) return;
            if (data.Error) return;
            rpm_renderLatencyChart(data);
        })
        .catch(function() {});
}

/* Loads the throughput history for the active time range and renders
   the throughput chart. */
function rpm_loadThroughputChart() {
    engineFetch('/api/replication/throughput-history?minutes=' + rpm_throughputMinutes)
        .then(function(data) {
            if (!data) return;
            if (data.Error) return;
            rpm_renderThroughputChart(data);
        })
        .catch(function() {});
}

/* Renders the queue chart. On first render builds the Chart.js
   instance; on subsequent renders updates the datasets in place and
   preserves any legend toggle state the user had set. */
function rpm_renderQueueChart(data) {
    var ctx = document.getElementById('queue-chart').getContext('2d');

    var series = {};
    data.forEach(function(d) {
        if (!series[d.publication_name]) series[d.publication_name] = [];
        series[d.publication_name].push({
            x: new Date(d.collected_dttm),
            y: d.pending_command_count
        });
    });

    var datasets = Object.keys(series).map(function(name) {
        var color = rpm_getColor(name);
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

    if (rpm_queueChart) {
        var hidden = rpm_getHiddenLabels(rpm_queueChart);
        rpm_queueChart.data.datasets = datasets;
        rpm_applyHiddenLabels(rpm_queueChart, hidden);
        rpm_queueChart.update('none');
        return;
    }
    rpm_queueChart = new Chart(ctx, {
        type: 'line',
        data: { datasets: datasets },
        options: rpm_getChartOptions('Pending Commands', false)
    });
}

/* Renders the latency chart. On first render builds the Chart.js
   instance; on subsequent renders updates the datasets in place. */
function rpm_renderLatencyChart(data) {
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
        var color = rpm_getColor(name);
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

    if (rpm_latencyChart) {
        var hidden = rpm_getHiddenLabels(rpm_latencyChart);
        rpm_latencyChart.data.datasets = datasets;
        rpm_applyHiddenLabels(rpm_latencyChart, hidden);
        rpm_latencyChart.update('none');
        return;
    }
    rpm_latencyChart = new Chart(ctx, {
        type: 'line',
        data: { datasets: datasets },
        options: rpm_getChartOptions('Latency (ms)', false)
    });
}

/* Renders the throughput chart on a logarithmic Y axis. Series keys
   suffix '(LR)' for Log Reader rows so the legend distinguishes the
   Log Reader from same-publication Distribution agents. */
function rpm_renderThroughputChart(data) {
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
        var color = rpm_getColor(series[key].name);
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

    if (rpm_throughputChart) {
        var hidden = rpm_getHiddenLabels(rpm_throughputChart);
        rpm_throughputChart.data.datasets = datasets;
        rpm_applyHiddenLabels(rpm_throughputChart, hidden);
        rpm_throughputChart.update('none');
        return;
    }
    rpm_throughputChart = new Chart(ctx, {
        type: 'line',
        data: { datasets: datasets },
        options: rpm_getChartOptions('Commands/sec', true)
    });
}

/* Builds the shared Chart.js options object. The Y-axis label is
   per-chart; logarithmic mode is used by the throughput chart since
   the Log Reader rate is roughly an order of magnitude higher than
   the Distribution agents'. */
function rpm_getChartOptions(yLabel, logarithmic) {
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
                        return context.dataset.label + ': ' + rpm_formatNumber(context.raw.y);
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
                    callback: function(value) { return rpm_formatNumber(value); }
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

/* Captures which dataset labels are currently hidden via the legend
   toggle, so they can be reapplied after the dataset array is
   replaced. */
function rpm_getHiddenLabels(chart) {
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

/* Restores per-label hidden state after a dataset replacement. Used
   together with rpm_getHiddenLabels to preserve legend toggles across
   data refreshes. */
function rpm_applyHiddenLabels(chart, hiddenLabels) {
    if (chart && chart.data && chart.data.datasets) {
        chart.data.datasets.forEach(function(ds, i) {
            if (hiddenLabels[ds.label]) {
                chart.getDatasetMeta(i).hidden = true;
            }
        });
    }
}

/* Looks up the line/fill color for a publication. Returns a neutral
   gray fallback for any publication not in rpm_CHART_COLORS. */
function rpm_getColor(name) {
    return rpm_CHART_COLORS[name] || rpm_CHART_COLOR_FALLBACK;
}

/* Delegated click handler for the chart time-range buttons. Reads the
   chart and minutes from the clicked button's data attributes,
   updates the active state for that chart's button group, destroys
   the chart instance so it rebuilds with the new time range, and
   triggers a fresh load. */
function rpm_onTimeButtonClick(event) {
    var btn = event.target.closest('.time-btn');
    if (!btn) return;

    var chart = btn.getAttribute('data-chart');
    var minutes = parseInt(btn.getAttribute('data-minutes'), 10);

    btn.parentElement.querySelectorAll('.time-btn').forEach(function(b) { b.classList.remove('active'); });
    btn.classList.add('active');

    if (chart === 'queue') {
        rpm_queueMinutes = minutes;
        if (rpm_queueChart) { rpm_queueChart.destroy(); rpm_queueChart = null; }
        rpm_loadQueueChart();
    } else if (chart === 'latency') {
        rpm_latencyMinutes = minutes;
        if (rpm_latencyChart) { rpm_latencyChart.destroy(); rpm_latencyChart = null; }
        rpm_loadLatencyChart();
    } else if (chart === 'throughput') {
        rpm_throughputMinutes = minutes;
        if (rpm_throughputChart) { rpm_throughputChart.destroy(); rpm_throughputChart = null; }
        rpm_loadThroughputChart();
    }
}

/* ============================================================================
   FUNCTIONS: EVENT LOG
   ----------------------------------------------------------------------------
   The event log on the right side of the page: a timeline of agent
   start/stop/state-change/retry/error events for the selected date,
   filtered by agent and optionally restricted to BIDATA-correlated
   events. The agent filter buttons are rebuilt every time the agent
   list changes; the date picker and correlation toggle re-fetch on
   every change.
   Prefix: rpm
   ============================================================================ */

/* Loads events for the active filters (date or correlation mode +
   agent filter) and renders them. */
function rpm_loadEvents() {
    var url = '/api/replication/events';
    if (rpm_eventCorrelationMode) {
        url += '?correlated=1';
        if (rpm_eventAgentFilter !== 'ALL') url += '&agent=' + rpm_eventAgentFilter;
    } else {
        url += '?date=' + rpm_eventDate;
        if (rpm_eventAgentFilter !== 'ALL') url += '&agent=' + rpm_eventAgentFilter;
    }

    engineFetch(url)
        .then(function(data) {
            if (!data) return;
            if (data.Error) return;
            rpm_renderEvents(data);
        })
        .catch(function() {});
}

/* Date picker change handler. Updates the active date and exits
   correlation mode if it was active (since dates and correlation are
   mutually exclusive views). Wired up from Backup.ps1's date picker. */
function rpm_onEventDateChange() {
    var picker = document.getElementById('event-date-picker');
    if (picker && picker.value) {
        rpm_eventDate = picker.value;
        if (rpm_eventCorrelationMode) {
            rpm_eventCorrelationMode = false;
            document.getElementById('btn-correlated').classList.remove('active');
            document.getElementById('event-date-picker').disabled = false;
        }
        rpm_loadEvents();
    }
}

/* Toggles correlation mode on the event log. In correlation mode the
   date picker is disabled and the API returns all BIDATA-correlated
   events across dates. Wired up from ReplicationMonitoring.ps1's
   Correlated button. */
function rpm_toggleCorrelationMode() {
    rpm_eventCorrelationMode = !rpm_eventCorrelationMode;
    var btn = document.getElementById('btn-correlated');
    var picker = document.getElementById('event-date-picker');

    if (rpm_eventCorrelationMode) {
        btn.classList.add('active');
        picker.disabled = true;
    } else {
        btn.classList.remove('active');
        picker.disabled = false;
    }
    rpm_loadEvents();
}

/* Sets the active agent filter for the event log and reloads events.
   Updates the active state across the filter buttons. */
function rpm_setEventAgentFilter(agentId) {
    rpm_eventAgentFilter = agentId;
    document.querySelectorAll('.event-agent-btn').forEach(function(b) {
        b.classList.toggle('active', b.getAttribute('data-agent') === String(agentId));
    });
    rpm_loadEvents();
}

/* Delegated click handler for the event log agent filter buttons.
   Reads the clicked button's data-agent value and applies the filter. */
function rpm_onEventAgentFilterClick(event) {
    var btn = event.target.closest('.event-agent-btn');
    if (!btn) return;
    rpm_setEventAgentFilter(btn.getAttribute('data-agent'));
}

/* Renders the agent filter buttons above the event log: an "All"
   button plus one per known agent. Called whenever the agent list
   changes after an agent-status load. */
function rpm_renderEventAgentFilter() {
    var container = document.getElementById('event-agent-filter');
    if (!container) return;

    var html = '<button class="event-agent-btn active" data-agent="ALL">All</button>';
    rpm_eventAgents.forEach(function(a) {
        html += '<button class="event-agent-btn" data-agent="' + a.id + '">' + escapeHtml(a.label) + '</button>';
    });
    container.innerHTML = html;
}

/* Renders the event log body: shows an empty-state message when no
   events match, otherwise hands the event array to the row builder. */
function rpm_renderEvents(data) {
    var container = document.getElementById('event-log');

    if (!data.events || data.events.length === 0) {
        var msg = rpm_eventCorrelationMode ? 'No correlated events found' : 'No events for ' + rpm_eventDate;
        container.innerHTML = '<div class="no-data">' + msg + '</div>';
        return;
    }

    container.innerHTML = rpm_buildEventRows(data.events);
}

/* Builds the HTML for the event rows. Each row shows time, type
   badge, publication / agent type, optional state transition, an
   optional BIDATA correlation badge, and the event message. The
   transition span is always rendered (even when empty) so columns
   align across rows that do and don't carry transition data. */
function rpm_buildEventRows(events) {
    var html = '';
    events.forEach(function(e) {
        html += '<div class="event-row">';
        html += '<span class="event-time">' + rpm_formatEventTime(e.event_dttm) + '</span>';
        html += '<span class="event-type-badge event-type-' + e.event_type + '">' +
            e.event_type.replace('_', ' ') + '</span>';
        html += '<span class="event-publication">' + escapeHtml(e.publication_name) +
            ' <span class="event-agent-type">(' + e.agent_type + ')</span></span>';

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

        if (e.correlation_source) {
            html += '<span class="event-correlation" title="' + escapeHtml(e.correlation_source) + '">B</span>';
        }

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

/* ============================================================================
   FUNCTIONS: HELPERS
   ----------------------------------------------------------------------------
   Page-local display formatters and lookup utilities: agent run-status
   class / text / badge mapping, number / time-ago / event-time
   formatting, the page timestamp updater, and the connection-error
   banner controls. The standard escapeHtml from cc-shared.js handles
   HTML escaping; these helpers handle the per-page display formats not
   covered by cc-shared.
   Prefix: rpm
   ============================================================================ */

/* Maps a SQL Server replication agent run_status code to the CSS
   status class used on the agent card root. */
function rpm_getStatusClass(runStatus) {
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

/* Maps a SQL Server replication agent run_status code to a display
   label. */
function rpm_getStatusText(runStatus) {
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

/* Maps a SQL Server replication agent run_status code to the CSS
   class used on the status badge. */
function rpm_getBadgeClass(runStatus) {
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

/* Formats a number with a K / M suffix above one thousand / one
   million; returns a locale-formatted string for smaller values; "-"
   for null or undefined. */
function rpm_formatNumber(n) {
    if (n === null || n === undefined) return '-';
    if (n >= 1000000) return (n / 1000000).toFixed(1) + 'M';
    if (n >= 1000) return (n / 1000).toFixed(1) + 'K';
    return n.toLocaleString();
}

/* Formats a date string as a "X ago" relative duration: "30s ago",
   "5m ago", "3h ago", "2d ago". Returns "-" for null or unparseable
   input. */
function rpm_formatTimeAgo(dateStr) {
    if (!dateStr) return '-';
    var diff = (new Date() - new Date(dateStr)) / 1000;
    if (isNaN(diff)) return '-';
    if (diff < 60) return Math.round(diff) + 's ago';
    if (diff < 3600) return Math.round(diff / 60) + 'm ago';
    if (diff < 86400) return Math.round(diff / 3600) + 'h ago';
    return Math.round(diff / 86400) + 'd ago';
}

/* Formats a date string as the event log timestamp: HH:MM:SS in
   single-date mode, M/D HH:MM:SS in correlation mode (which spans
   dates). Returns "-" for null or unparseable input. */
function rpm_formatEventTime(dateStr) {
    if (!dateStr) return '-';
    var d = new Date(dateStr);
    if (isNaN(d.getTime())) return '-';
    var time = d.toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false });
    if (rpm_eventCorrelationMode) {
        var date = (d.getMonth() + 1) + '/' + d.getDate();
        return date + ' ' + time;
    }
    return time;
}

/* Updates the live "last updated" timestamp display in the page
   header. */
function rpm_updateTimestamp() {
    var el = document.getElementById('last-update');
    if (el) el.textContent = new Date().toLocaleTimeString();
}

/* Shows the inline connection error banner with a message. The
   ReplicationMonitoring.ps1 route still renders a 'connection-error'
   element; once the route is migrated to the cc-shared
   'connection-banner' element these helpers will be removed in favor
   of cc-shared's updateConnectionBanner. */
function rpm_showError(msg) {
    var el = document.getElementById('connection-error');
    if (!el) return;
    el.textContent = msg;
    el.classList.add('visible');
}

/* Hides the inline connection error banner. */
function rpm_clearError() {
    var el = document.getElementById('connection-error');
    if (!el) return;
    el.classList.remove('visible');
}

/* ============================================================================
   FUNCTIONS: PAGE LIFECYCLE HOOKS
   ----------------------------------------------------------------------------
   Hooks invoked by cc-shared.js. The shared module probes for these via
   typeof === 'function' and calls them at the appropriate moment in the
   page lifecycle, so they are not prefixed (the shared module reads
   them by name).
   Prefix: (none)
   ============================================================================ */

/* Called by cc-shared.js's pageRefresh when the user clicks the page
   refresh button. cc-shared.js drives the spin animation; this hook
   does the actual data reload. */
function onPageRefresh() {
    rpm_refreshAll();
}

/* Called by cc-shared.js when the page becomes visible again after
   being hidden. cc-shared.js drives the spin animation; this hook
   does the actual data reload so the user sees current data. */
function onPageResumed() {
    rpm_refreshAll();
}

/* Called by cc-shared.js when an orchestrator process listed in
   ENGINE_PROCESSES completes. Refreshes the event-driven sections so
   the UI picks up the freshly collected data. */
function onEngineProcessCompleted(processName, event) {
    rpm_refreshEventSections();
}
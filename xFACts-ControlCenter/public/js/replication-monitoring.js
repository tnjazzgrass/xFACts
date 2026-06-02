/* ============================================================================
   xFACts Control Center - Replication Monitoring (replication-monitoring.js)
   Location: E:\xFACts-ControlCenter\public\js\replication-monitoring.js
   Version: Tracked in dbo.System_Metadata (component: ServerOps.Replication)

   Page-specific JS for the Replication Monitoring dashboard. Universal
   chrome (WebSocket events, connection banner, page refresh button, idle
   detection, session expiry, shared modals, formatting utilities) is
   provided by cc-shared.js. This file contains the data loading and
   rendering logic for the agent status cards, the queue / latency /
   throughput line charts with their per-chart time-range controls, the
   event log with date and agent filters and BIDATA-correlation mode, and
   the section help panel that surfaces explanatory text from each section
   header.

   FILE ORGANIZATION
   -----------------
   CONSTANTS: ENGINE PROCESSES
   CONSTANTS: SECTION INFO TEXT
   CONSTANTS: CHART COLORS
   CONSTANTS: THRESHOLD DEFAULTS
   CONSTANTS: DISPATCH TABLES
   STATE: PAGE STATE
   FUNCTIONS: INITIALIZATION
   FUNCTIONS: REFRESH
   FUNCTIONS: INFO PANEL
   FUNCTIONS: AGENT STATUS
   FUNCTIONS: CHARTS
   FUNCTIONS: EVENT LOG
   FUNCTIONS: ACTION HANDLERS
   FUNCTIONS: FORMATTERS
   FUNCTIONS: PAGE LIFECYCLE HOOKS
   ============================================================================ */

/* ============================================================================
   CONSTANTS: ENGINE PROCESSES
   ----------------------------------------------------------------------------
   Name contract with cc-shared.js. Maps process names registered in
   Orchestrator.ProcessRegistry to their engine card slugs. The identifier
   is rpm_ENGINE_PROCESSES so cc-shared.js can resolve it via
   window[cc_pagePrefix + '_ENGINE_PROCESSES'] using the data-cc-prefix
   value declared on <body>. The Replication Monitoring page has a single
   collector, Collect-ReplicationHealth, that drives every section on its
   60-second cycle.
   Prefix: rpm
   ============================================================================ */

/* Maps orchestrator process names to engine card slugs. cc-shared.js reads
   this from a separate script at startup via
   window[cc_pagePrefix + '_ENGINE_PROCESSES']. Top-level const and let
   declarations in classic scripts do NOT add to window -- only var
   declarations and function declarations do -- so this MUST use var, not
   const, even though the value is never reassigned. Card refreshes for the
   bound process happen automatically via rpm_onEngineProcessCompleted. */
var rpm_ENGINE_PROCESSES = {
    'Collect-ReplicationHealth': { slug: 'replication' }
};

/* ============================================================================
   CONSTANTS: SECTION INFO TEXT
   ----------------------------------------------------------------------------
   The static body text shown by the section help panel. Keys correspond to
   the section keys the info icons carry; values hold the panel title and
   the HTML body. Stored as a constant rather than fetched from the server
   because the text is documentation, not operational data, and never
   varies per request. Inline status keywords are tinted via page-local
   rpm-info-* classes from replication-monitoring.css rather than inline
   styles.
   Prefix: rpm
   ============================================================================ */

/* Per-section explanatory text shown when the user clicks the info icon in
   a section header. Each entry has a title and an HTML body. */
const rpm_sectionInfo = {
    'agent-status': {
        title: 'Agent Status',
        body: '<p class="cc-dialog-paragraph"><span class="cc-dialog-strong">What am I looking at?</span></p>' +
            '<p class="cc-dialog-paragraph">Each card represents a replication agent &mdash; a background process that moves data from one server to another. ' +
            'Think of them as conveyor belts moving database changes between systems.</p>' +
            '<p class="cc-dialog-paragraph"><span class="cc-dialog-strong">Agent Types:</span></p>' +
            '<p class="cc-dialog-paragraph"><span class="rpm-info-em">Log Reader</span> &mdash; Reads changes from the source database\'s transaction log and passes them to the distribution database. ' +
            'There\'s one Log Reader for all publications. If this stops, nothing moves.</p>' +
            '<p class="cc-dialog-paragraph"><span class="rpm-info-em">Distribution</span> &mdash; Delivers changes from the distribution database to each subscriber. ' +
            'Each subscriber has its own Distribution agent.</p>' +
            '<p class="cc-dialog-paragraph"><span class="cc-dialog-strong">Key Metrics:</span></p>' +
            '<p class="cc-dialog-paragraph"><span class="rpm-info-em">Pending</span> &mdash; Commands waiting to be delivered. Zero or low single digits is normal. ' +
            'A rising number means the agent is falling behind.</p>' +
            '<p class="cc-dialog-paragraph"><span class="rpm-info-em">Delivery Rate</span> &mdash; How fast the agent is processing commands (commands per second).</p>' +
            '<p class="cc-dialog-paragraph"><span class="rpm-info-em">Latency</span> &mdash; Round-trip time for a test token to travel the full pipeline. ' +
            'Low single-digit milliseconds is healthy.</p>' +
            '<p class="cc-dialog-paragraph"><span class="cc-dialog-strong">Status Badges:</span></p>' +
            '<p class="cc-dialog-paragraph"><span class="rpm-info-teal">IDLE</span> = Healthy, waiting for new work &nbsp; ' +
            '<span class="rpm-info-teal">RUNNING</span> = Actively delivering &nbsp; ' +
            '<span class="rpm-info-amber">RETRYING</span> = Hit an error, trying again &nbsp; ' +
            '<span class="rpm-info-orange">STOPPED</span> = Not running (expected during BIDATA builds) &nbsp; ' +
            '<span class="rpm-info-orange">FAILED</span> = Something is wrong</p>'
    },
    'queue-depth': {
        title: 'Queue Depth',
        body: '<p class="cc-dialog-paragraph"><span class="cc-dialog-strong">What am I looking at?</span></p>' +
            '<p class="cc-dialog-paragraph">This chart shows how many commands are waiting to be delivered to each subscriber over time. ' +
            'Think of it as the "inbox" for each destination server.</p>' +
            '<p class="cc-dialog-paragraph"><span class="cc-dialog-strong">What\'s normal?</span></p>' +
            '<p class="cc-dialog-paragraph">During regular operations, you\'ll see low numbers (single or double digits) bouncing around near zero. ' +
            'This means replication is keeping up with changes as they happen.</p>' +
            '<p class="cc-dialog-paragraph"><span class="cc-dialog-strong">What to watch for:</span></p>' +
            '<p class="cc-dialog-paragraph"><span class="rpm-info-em">Gradual climb</span> &mdash; The agent is falling behind. Could be slow network, busy subscriber, or heavy publisher activity.</p>' +
            '<p class="cc-dialog-paragraph"><span class="rpm-info-em">Sudden spike then flat line</span> &mdash; Agent was stopped (e.g., BIDATA build window). ' +
            'Commands pile up while the agent is off, then drain quickly when it restarts. This is expected behavior.</p>' +
            '<p class="cc-dialog-paragraph"><span class="rpm-info-em">Spike that doesn\'t drain</span> &mdash; Agent restarted but can\'t catch up. Needs investigation.</p>'
    },
    'latency': {
        title: 'End-to-End Latency',
        body: '<p class="cc-dialog-paragraph"><span class="cc-dialog-strong">What am I looking at?</span></p>' +
            '<p class="cc-dialog-paragraph">Every few minutes, xFACts sends a "tracer token" through the replication pipeline &mdash; ' +
            'a tiny test message that travels the same path as real data. This chart shows how long each token ' +
            'took to complete the full journey.</p>' +
            '<p class="cc-dialog-paragraph"><span class="cc-dialog-strong">The three hops:</span></p>' +
            '<p class="cc-dialog-paragraph">1. <span class="rpm-info-em">Publisher &rarr; Distributor</span> (Log Reader picks it up)<br>' +
            '2. <span class="rpm-info-em">Distributor &rarr; Subscriber</span> (Distribution agent delivers it)<br>' +
            'Total = sum of both hops</p>' +
            '<p class="cc-dialog-paragraph"><span class="cc-dialog-strong">What\'s normal?</span></p>' +
            '<p class="cc-dialog-paragraph">Single-digit milliseconds. Your pipeline is fast &mdash; changes typically arrive at subscribers ' +
            'within a few milliseconds of being committed on the publisher.</p>' +
            '<p class="cc-dialog-paragraph"><span class="cc-dialog-strong">What to watch for:</span></p>' +
            '<p class="cc-dialog-paragraph"><span class="rpm-info-em">Spikes</span> &mdash; Brief spikes during heavy activity are normal. Sustained high latency means ' +
            'something in the pipeline is bottlenecked.</p>' +
            '<p class="cc-dialog-paragraph"><span class="rpm-info-em">Missing data points</span> &mdash; If an agent is stopped, tracer tokens can\'t complete the journey. ' +
            'Gaps in the chart during BIDATA build windows are expected.</p>'
    },
    'throughput': {
        title: 'Delivery Rate',
        body: '<p class="cc-dialog-paragraph"><span class="cc-dialog-strong">What am I looking at?</span></p>' +
            '<p class="cc-dialog-paragraph">This chart shows how fast each agent is delivering commands, measured in commands per second. ' +
            'The Y-axis uses a logarithmic scale because the Log Reader typically operates at a much higher rate ' +
            'than the Distribution agents.</p>' +
            '<p class="cc-dialog-paragraph"><span class="cc-dialog-strong">Why the different scales?</span></p>' +
            '<p class="cc-dialog-paragraph">The <span class="rpm-info-em">Log Reader</span> reads ALL changes from the transaction log for every publication, ' +
            'so its rate is always the highest. Distribution agents only deliver changes for their specific ' +
            'subscriber, so their rates are lower.</p>' +
            '<p class="cc-dialog-paragraph"><span class="cc-dialog-strong">Note about this metric:</span></p>' +
            '<p class="cc-dialog-paragraph">The delivery rate shown is a cumulative average reported by SQL Server, not a point-in-time rate. ' +
            'This means it tends to be stable over time and doesn\'t show moment-to-moment spikes. ' +
            'For real-time throughput changes, the Queue Depth chart is a better indicator.</p>' +
            '<p class="cc-dialog-paragraph"><span class="cc-dialog-strong">What to watch for:</span></p>' +
            '<p class="cc-dialog-paragraph"><span class="rpm-info-em">Rate drops to zero</span> &mdash; Agent is stopped or failed.<br>' +
            '<span class="rpm-info-em">Significant rate change</span> &mdash; Could indicate a change in workload patterns or performance issues.</p>'
    },
    'event-log': {
        title: 'Event Log',
        body: '<p class="cc-dialog-paragraph"><span class="cc-dialog-strong">What am I looking at?</span></p>' +
            '<p class="cc-dialog-paragraph">A timeline of significant events &mdash; when agents start, stop, change state, or encounter errors. ' +
            'Think of it as the "what happened" record.</p>' +
            '<p class="cc-dialog-paragraph"><span class="cc-dialog-strong">Event Types:</span></p>' +
            '<p class="cc-dialog-paragraph"><span class="rpm-info-teal">AGENT START</span> &mdash; An agent began running<br>' +
            '<span class="rpm-info-orange">AGENT STOP</span> &mdash; An agent was stopped<br>' +
            '<span class="rpm-info-blue">STATE CHANGE</span> &mdash; Agent transitioned between states<br>' +
            '<span class="rpm-info-amber">RETRY</span> &mdash; Agent hit an error and is retrying<br>' +
            '<span class="rpm-info-orange">ERROR</span> &mdash; An error was detected</p>' +
            '<p class="cc-dialog-paragraph"><span class="cc-dialog-strong">BIDATA_BUILD tag:</span></p>' +
            '<p class="cc-dialog-paragraph">When an agent stop correlates with an active BIDATA build, it\'s tagged with ' +
            '<span class="rpm-info-blue">BIDATA_BUILD</span>. This means the stop was expected &mdash; ' +
            'Distribution agents are intentionally stopped during the nightly build to prevent replication ' +
            'from interfering with the data load process.</p>'
    }
};

/* Section header titles paired with their info-panel keys. The info icon
   injection routine looks up section headers by these titles and appends
   an icon that opens the matching info panel entry. */
const rpm_infoIconMappings = [
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
   latency, throughput). Keyed by publication name; falls back to a neutral
   gray for any publication not in the map.
   Prefix: rpm
   ============================================================================ */

/* Maps publication names to chart line/fill colors. Used by all three line
   charts (queue, latency, throughput) so a publication has a consistent
   color across charts. */
const rpm_chartColors = {
    'BIDATALoad':         { line: '#4ec9b0', fill: 'rgba(78, 201, 176, 0.08)' },
    'Azure_BIDATA_Load':  { line: '#569cd6', fill: 'rgba(86, 156, 214, 0.08)' },
    'BIDATA_Load_POC':    { line: '#dcdcaa', fill: 'rgba(220, 220, 170, 0.08)' },
    'crs5_oltp':          { line: '#c586c0', fill: 'rgba(197, 134, 192, 0.08)' }
};

/* Fallback color for any publication not in rpm_chartColors. */
const rpm_chartColorFallback = { line: '#888', fill: 'rgba(136, 136, 136, 0.08)' };

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
const rpm_thresholdDefaults = {
    replication_queue_warning_threshold:  5000,
    replication_queue_critical_threshold: 50000,
    replication_latency_warning_ms:       30000,
    replication_latency_critical_ms:      120000
};

/* ============================================================================
   CONSTANTS: DISPATCH TABLES
   ----------------------------------------------------------------------------
   Per-event dispatch tables consumed by the delegated event listeners
   registered in rpm_init. Each table maps page-local data-action-<event>
   values to handler functions. Shared cc-* actions are handled by
   cc-shared.js and never appear here.
   Prefix: rpm
   ============================================================================ */

/* Page-local click action dispatch table. */
const rpm_clickActions = {
    'rpm-set-time-range':       rpm_setTimeRange,
    'rpm-toggle-correlation':   rpm_toggleCorrelationMode,
    'rpm-open-info':            rpm_openInfoPanelFromTarget,
    'rpm-close-info':           rpm_closeInfoPanel,
    'rpm-set-agent-filter':     rpm_setEventAgentFilterFromTarget
};

/* Page-local change action dispatch table. */
const rpm_changeActions = {
    'rpm-event-date-change': rpm_onEventDateChange
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

/* setInterval handle for the midnight-rollover check. */
var rpm_refreshTimer = null;

/* Chart.js instance for the Queue Depth chart, or null when not yet
   created. Re-rendered in place to preserve legend toggle state. */
var rpm_queueChart = null;

/* Chart.js instance for the End-to-End Latency chart, or null when not yet
   created. */
var rpm_latencyChart = null;

/* Chart.js instance for the Delivery Rate chart, or null when not yet
   created. */
var rpm_throughputChart = null;

/* Active time range for the Queue Depth chart in minutes. Updated by the
   time-range buttons; passed to the queue-history API. */
var rpm_queueMinutes = 60;

/* Active time range for the End-to-End Latency chart in minutes. */
var rpm_latencyMinutes = 60;

/* Active time range for the Delivery Rate chart in minutes. */
var rpm_throughputMinutes = 60;

/* Active date filter for the event log, in YYYY-MM-DD format. Initialized
   to today on page boot; updated by the date picker. */
var rpm_eventDate = new Date().getFullYear() + '-' +
    String(new Date().getMonth() + 1).padStart(2, '0') + '-' +
    String(new Date().getDate()).padStart(2, '0');

/* Active agent filter for the event log. 'ALL' shows every agent; any other
   value is a publication_registry_id rendered as a string. */
var rpm_eventAgentFilter = 'ALL';

/* Cached agent list from the most recent agent-status response. Used to
   render the per-agent filter buttons above the event log. */
var rpm_eventAgents = [];

/* Whether the event log is in correlation mode (showing all
   BIDATA-correlated events across dates) or normal mode (filtered by
   rpm_eventDate). Toggled by the Correlated button. */
var rpm_eventCorrelationMode = false;

/* Runtime thresholds, initialized from rpm_thresholdDefaults and
   overwritten with per-installation overrides loaded by rpm_loadThresholds
   from the thresholds API. */
var rpm_thresholds = {
    replication_queue_warning_threshold:  rpm_thresholdDefaults.replication_queue_warning_threshold,
    replication_queue_critical_threshold: rpm_thresholdDefaults.replication_queue_critical_threshold,
    replication_latency_warning_ms:       rpm_thresholdDefaults.replication_latency_warning_ms,
    replication_latency_critical_ms:      rpm_thresholdDefaults.replication_latency_critical_ms
};

/* ============================================================================
   FUNCTIONS: INITIALIZATION
   ----------------------------------------------------------------------------
   The mandatory rpm_init function called by the cc-shared.js bootloader
   after this module loads. Injects the info icons into the section headers,
   loads the threshold overrides, primes the date picker, runs the first
   data load, starts the midnight-rollover timer, connects to the engine
   event stream, and registers the page's delegated click and change
   listeners.
   Prefix: rpm
   ============================================================================ */

/* Page boot function. Called by the cc-shared.js bootloader after this
   module is loaded. Injects the section info icons, loads page
   configuration, performs the initial data load, starts the
   midnight-rollover timer, wires the engine subsystem, and registers the
   delegated listeners that route data-action values to the dispatch
   tables. */
function rpm_init() {
    rpm_injectInfoIcons();
    rpm_loadThresholds();

    var datePicker = document.getElementById('rpm-event-date-picker');
    if (datePicker) datePicker.value = rpm_eventDate;

    rpm_refreshAll();
    cc_connectEngineEvents();
    rpm_startAutoRefresh();

    document.body.addEventListener('click', rpm_handleClickAction);
    document.body.addEventListener('change', rpm_handleChangeAction);
}

/* ============================================================================
   FUNCTIONS: REFRESH
   ----------------------------------------------------------------------------
   The page's refresh paths. All sections are event-driven (data populated
   by Collect-ReplicationHealth on a 60-second orchestrator cycle), so there
   is no live-polling timer; the auto-refresh timer only checks for midnight
   rollover. The refresh-all path runs a full reload; the refresh-event path
   runs the agent cards, all three charts, and the event log when the
   collector completes.
   Prefix: rpm
   ============================================================================ */

/* Refreshes every section on the page from its API endpoint. Called by the
   rpm_onPageRefresh and rpm_onPageResumed hooks and by the page boot
   function. */
function rpm_refreshAll() {
    rpm_loadAgentStatus();
    rpm_loadQueueChart();
    rpm_loadLatencyChart();
    rpm_loadThroughputChart();
    rpm_loadEvents();
    rpm_updateTimestamp();
}

/* Refreshes the event-driven sections. Called by the
   rpm_onEngineProcessCompleted hook when Collect-ReplicationHealth
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
    rpm_refreshTimer = setInterval(function() {
        var today = new Date().toDateString();
        if (today !== rpm_pageLoadDate) {
            window.location.reload();
        }
    }, 60000);
}

/* ============================================================================
   FUNCTIONS: INFO PANEL
   ----------------------------------------------------------------------------
   The "what is this?" help panel that explains each section. The panel
   itself is a static slide dialog declared in ReplicationMonitoring.ps1
   consuming the shared cc-slide-overlay / cc-dialog chrome. The info icons
   are injected into matching section header titles at boot; clicking an
   icon opens the panel with the section's pre-authored explanation.
   Prefix: rpm
   ============================================================================ */

/* Builds the info icon button HTML for a section. The data-action-click
   value routes through rpm_clickActions; the data-action-rpm-section
   argument carries the section key the handler reads. */
function rpm_createInfoIcon(sectionKey) {
    return '<button class="rpm-info-icon" data-action-click="rpm-open-info" data-action-rpm-section="' +
        sectionKey + '" title="What is this?">&#9432;</button>';
}

/* Walks the page's section header titles and appends an info icon to any
   header whose text matches an entry in rpm_infoIconMappings. */
function rpm_injectInfoIcons() {
    var headers = document.querySelectorAll('.cc-section-title');
    headers.forEach(function(header) {
        rpm_infoIconMappings.forEach(function(m) {
            if (header.textContent.trim() === m.title) {
                header.innerHTML = header.textContent + ' ' + rpm_createInfoIcon(m.key);
            }
        });
    });
}

/* Opens the help panel for a section key. Populates the shared dialog title
   and body, reveals the overlay, then adds cc-open to the dialog on the
   next animation frame so the slide-in transition animates from the
   off-screen position. No-op if the section key is unknown. */
function rpm_openInfoPanel(sectionKey) {
    var info = rpm_sectionInfo[sectionKey];
    if (!info) return;

    document.getElementById('rpm-info-title').textContent = info.title;
    document.getElementById('rpm-info-body').innerHTML = info.body;

    var overlay = document.getElementById('rpm-slideout-info');
    var dialog = overlay.querySelector('.cc-dialog');
    overlay.classList.add('cc-open');
    requestAnimationFrame(function() {
        dialog.classList.add('cc-open');
    });
}

/* Opens the help panel from a clicked info icon. Reads the section key from
   the icon's data-action-rpm-section argument attribute. */
function rpm_openInfoPanelFromTarget(target) {
    rpm_openInfoPanel(target.dataset.actionRpmSection);
}

/* Closes the help panel. Removes cc-open from the dialog first to start the
   slide-out transition; removes cc-open from the overlay when the transition
   finishes so the dimmer stays in place during the slide-out. Wired from the
   close button and the overlay backdrop via the rpm-close-info click action.
   The dispatcher passes the matched action element as target. When target is
   the overlay itself, the click is only a dismiss if it landed directly on the
   backdrop (event.target === target); a click that bubbled up from the dialog
   interior is ignored. When target is the close button, the panel always
   closes. */
function rpm_closeInfoPanel(target, event) {
    if (event && target.id === 'rpm-slideout-info' && event.target !== target) {
        return;
    }
    var overlay = document.getElementById('rpm-slideout-info');
    var dialog = overlay.querySelector('.cc-dialog');
    dialog.addEventListener('transitionend', function handler() {
        dialog.removeEventListener('transitionend', handler);
        overlay.classList.remove('cc-open');
    });
    dialog.classList.remove('cc-open');
}

/* ============================================================================
   FUNCTIONS: AGENT STATUS
   ----------------------------------------------------------------------------
   The per-agent status cards: one card per replication agent (Log Reader
   and per-subscriber Distribution agents). Each card shows run state, key
   metrics (pending count, delivery rate, latency, last action), and a
   status badge. Threshold-driven coloring on the pending count flags
   falling-behind agents. Loading the agent list also populates the event
   log's agent filter, since the two views share the same agent inventory.
   Prefix: rpm
   ============================================================================ */

/* Loads threshold overrides from the API and merges them into the runtime
   thresholds. Falls back silently to the defaults if the API is
   unavailable. */
function rpm_loadThresholds() {
    cc_engineFetch('/api/replication/thresholds')
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

/* Loads the agent status data, populates the event log agent filter list as
   a side effect, and re-renders the cards. Updates the page timestamp on
   success. */
function rpm_loadAgentStatus() {
    cc_engineFetch('/api/replication/agent-status')
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
   coloring, queue-depth coloring derived from the loaded thresholds, and
   metric panels that vary by agent type (Log Reader vs Distribution). */
function rpm_renderAgentCards(agents) {
    var container = document.getElementById('rpm-agent-cards');
    if (!agents || agents.length === 0) {
        container.innerHTML = '<div class="rpm-no-data">No agents discovered yet.</div>';
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
            badgeClass = 'rpm-badge-stopped';
        }

        var queueClass = 'rpm-queue-healthy';
        var pendingCount = a.pending_command_count;
        if (pendingCount !== null && pendingCount !== undefined) {
            if (pendingCount >= rpm_thresholds.replication_queue_critical_threshold) queueClass = 'rpm-queue-critical';
            else if (pendingCount >= rpm_thresholds.replication_queue_warning_threshold) queueClass = 'rpm-queue-warning';
        }

        html += '<div class="rpm-agent-card rpm-status-' + statusClass + '">';

        /* Header. */
        html += '<div class="rpm-agent-card-header">';
        html += '<div>';
        html += '<div class="rpm-agent-card-title">' + cc_escapeHtml(a.publication_name);
        if (a.agent_type === 'LogReader') {
            html += ' <span class="rpm-agent-type-tag rpm-tag-logreader">Log Reader</span>';
        } else {
            var tagClass = (a.subscription_type_desc || '').toLowerCase().indexOf('push') >= 0 ? 'rpm-tag-push' : 'rpm-tag-pull';
            html += ' <span class="rpm-agent-type-tag ' + tagClass + '">' + cc_escapeHtml(a.subscription_type_desc) + '</span>';
        }
        html += '</div>';
        if (a.agent_type !== 'LogReader') {
            html += '<div class="rpm-agent-card-subtitle">' + cc_escapeHtml(a.subscriber_name) + '</div>';
        } else {
            var serverName = 'DM-PROD-DB';
            if (a.agent_name && a.publisher_db) {
                var dbIdx = a.agent_name.indexOf(a.publisher_db);
                if (dbIdx > 1) serverName = a.agent_name.substring(0, dbIdx - 1);
            }
            html += '<div class="rpm-agent-card-subtitle">' + cc_escapeHtml(serverName) + '</div>';
        }
        html += '</div>';
        html += '<span class="rpm-agent-status-badge ' + badgeClass + '">' + statusText + '</span>';
        html += '</div>';

        /* Metrics. */
        html += '<div class="rpm-agent-card-metrics">';

        if (a.agent_type === 'Distribution') {
            html += '<div class="rpm-agent-metric">';
            html += '<div class="rpm-agent-metric-label">Pending</div>';
            html += '<div class="rpm-agent-metric-value ' + queueClass + '">' + rpm_formatNumber(pendingCount) + '</div>';
            html += '</div>';
        }

        if (a.agent_type === 'LogReader') {
            html += '<div class="rpm-agent-metric">';
            html += '<div class="rpm-agent-metric-label">Delivered</div>';
            html += '<div class="rpm-agent-metric-value">' +
                (a.delivered_commands !== null ? rpm_formatNumber(a.delivered_commands) : '-') + '</div>';
            html += '</div>';
        }

        html += '<div class="rpm-agent-metric">';
        html += '<div class="rpm-agent-metric-label">Delivery Rate</div>';
        html += '<div class="rpm-agent-metric-value">' +
            (a.delivery_rate !== null ? rpm_formatNumber(Math.round(a.delivery_rate)) : '-') +
            ' <span class="rpm-agent-metric-unit">cmd/s</span></div>';
        html += '</div>';

        if (a.agent_type === 'Distribution') {
            html += '<div class="rpm-agent-metric">';
            html += '<div class="rpm-agent-metric-label">Latency</div>';
            html += '<div class="rpm-agent-metric-value">' +
                (a.latest_latency_ms !== null ? a.latest_latency_ms + ' <span class="rpm-agent-metric-unit">ms</span>' : '-') +
                '</div>';
            html += '</div>';
        }

        if (a.agent_type === 'LogReader') {
            html += '<div class="rpm-agent-metric">';
            html += '<div class="rpm-agent-metric-label">Backlog</div>';
            html += '<div class="rpm-agent-metric-value">' +
                (a.estimated_processing_seconds !== null ? a.estimated_processing_seconds + ' <span class="rpm-agent-metric-unit">sec</span>' : '-') +
                '</div>';
            html += '</div>';
        }

        html += '<div class="rpm-agent-metric">';
        html += '<div class="rpm-agent-metric-label">Last Activity</div>';
        html += '<div class="rpm-agent-metric-value rpm-agent-metric-time">' + rpm_formatTimeAgo(a.agent_action_dttm) + '</div>';
        html += '</div>';

        html += '</div>';
        html += '</div>';
    });

    container.innerHTML = html;
}

/* ============================================================================
   FUNCTIONS: CHARTS
   ----------------------------------------------------------------------------
   The three line charts (queue depth, latency, delivery rate). Each chart
   has its own time-range selector and its own API endpoint; re-renders
   happen in place to preserve legend toggle state when data refreshes. The
   chart-options builder produces shared Chart.js configuration with
   per-chart Y-axis labels and an optional logarithmic scale (used by the
   throughput chart since the Log Reader typically operates an order of
   magnitude faster than the Distribution agents).
   Prefix: rpm
   ============================================================================ */

/* Loads and re-renders all three charts. Called by
   rpm_refreshEventSections. Each chart fetches its own time-windowed data
   so they can be advanced independently. */
function rpm_refreshAllCharts() {
    rpm_loadQueueChart();
    rpm_loadLatencyChart();
    rpm_loadThroughputChart();
}

/* Loads the queue history for the active time range and renders the queue
   chart. */
function rpm_loadQueueChart() {
    cc_engineFetch('/api/replication/queue-history?minutes=' + rpm_queueMinutes)
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
    cc_engineFetch('/api/replication/latency-history?minutes=' + rpm_latencyMinutes)
        .then(function(data) {
            if (!data) return;
            if (data.Error) return;
            rpm_renderLatencyChart(data);
        })
        .catch(function() {});
}

/* Loads the throughput history for the active time range and renders the
   throughput chart. */
function rpm_loadThroughputChart() {
    cc_engineFetch('/api/replication/throughput-history?minutes=' + rpm_throughputMinutes)
        .then(function(data) {
            if (!data) return;
            if (data.Error) return;
            rpm_renderThroughputChart(data);
        })
        .catch(function() {});
}

/* Renders the queue chart. On first render builds the Chart.js instance; on
   subsequent renders updates the datasets in place and preserves any legend
   toggle state the user had set. */
function rpm_renderQueueChart(data) {
    var ctx = document.getElementById('rpm-queue-chart').getContext('2d');

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

/* Renders the latency chart. On first render builds the Chart.js instance;
   on subsequent renders updates the datasets in place. */
function rpm_renderLatencyChart(data) {
    var ctx = document.getElementById('rpm-latency-chart').getContext('2d');

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

/* Renders the throughput chart on a logarithmic Y axis. Series keys suffix
   '(LR)' for Log Reader rows so the legend distinguishes the Log Reader
   from same-publication Distribution agents. */
function rpm_renderThroughputChart(data) {
    var ctx = document.getElementById('rpm-throughput-chart').getContext('2d');

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

/* Builds the shared Chart.js options object. The Y-axis label is per-chart;
   logarithmic mode is used by the throughput chart since the Log Reader
   rate is roughly an order of magnitude higher than the Distribution
   agents'. */
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

/* Captures which dataset labels are currently hidden via the legend toggle,
   so they can be reapplied after the dataset array is replaced. */
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
   together with rpm_getHiddenLabels to preserve legend toggles across data
   refreshes. */
function rpm_applyHiddenLabels(chart, hiddenLabels) {
    if (chart && chart.data && chart.data.datasets) {
        chart.data.datasets.forEach(function(ds, i) {
            if (hiddenLabels[ds.label]) {
                chart.getDatasetMeta(i).hidden = true;
            }
        });
    }
}

/* Looks up the line/fill color for a publication. Returns a neutral gray
   fallback for any publication not in rpm_chartColors. */
function rpm_getColor(name) {
    return rpm_chartColors[name] || rpm_chartColorFallback;
}

/* ============================================================================
   FUNCTIONS: EVENT LOG
   ----------------------------------------------------------------------------
   The event log on the right side of the page: a timeline of agent
   start/stop/state-change/retry/error events for the selected date,
   filtered by agent and optionally restricted to BIDATA-correlated events.
   The agent filter buttons are rebuilt every time the agent list changes;
   the date picker and correlation toggle re-fetch on every change.
   Prefix: rpm
   ============================================================================ */

/* Loads events for the active filters (date or correlation mode + agent
   filter) and renders them. */
function rpm_loadEvents() {
    var url = '/api/replication/events';
    if (rpm_eventCorrelationMode) {
        url += '?correlated=1';
        if (rpm_eventAgentFilter !== 'ALL') url += '&agent=' + rpm_eventAgentFilter;
    } else {
        url += '?date=' + rpm_eventDate;
        if (rpm_eventAgentFilter !== 'ALL') url += '&agent=' + rpm_eventAgentFilter;
    }

    cc_engineFetch(url)
        .then(function(data) {
            if (!data) return;
            if (data.Error) return;
            rpm_renderEvents(data);
        })
        .catch(function() {});
}

/* Date picker change handler. Updates the active date and exits correlation
   mode if it was active (since dates and correlation are mutually exclusive
   views). Wired up from the date picker via
   data-action-change="rpm-event-date-change". */
function rpm_onEventDateChange() {
    var picker = document.getElementById('rpm-event-date-picker');
    if (picker && picker.value) {
        rpm_eventDate = picker.value;
        if (rpm_eventCorrelationMode) {
            rpm_eventCorrelationMode = false;
            document.getElementById('rpm-btn-correlated').classList.remove('rpm-active');
            picker.disabled = false;
        }
        rpm_loadEvents();
    }
}

/* Toggles correlation mode on the event log. In correlation mode the date
   picker is disabled and the API returns all BIDATA-correlated events
   across dates. Wired up from the Correlated button via
   data-action-click="rpm-toggle-correlation". */
function rpm_toggleCorrelationMode() {
    rpm_eventCorrelationMode = !rpm_eventCorrelationMode;
    var btn = document.getElementById('rpm-btn-correlated');
    var picker = document.getElementById('rpm-event-date-picker');

    if (rpm_eventCorrelationMode) {
        btn.classList.add('rpm-active');
        picker.disabled = true;
    } else {
        btn.classList.remove('rpm-active');
        picker.disabled = false;
    }
    rpm_loadEvents();
}

/* Sets the active agent filter for the event log and reloads events.
   Updates the active state across the filter buttons. */
function rpm_setEventAgentFilter(agentId) {
    rpm_eventAgentFilter = agentId;
    document.querySelectorAll('.rpm-event-agent-btn').forEach(function(b) {
        b.classList.toggle('rpm-active', b.getAttribute('data-action-rpm-agent') === String(agentId));
    });
    rpm_loadEvents();
}

/* Sets the agent filter from a clicked filter button. Reads the agent value
   from the button's data-action-rpm-agent argument attribute. */
function rpm_setEventAgentFilterFromTarget(target) {
    rpm_setEventAgentFilter(target.dataset.actionRpmAgent);
}

/* Renders the agent filter buttons above the event log: an "All" button
   plus one per known agent. Called whenever the agent list changes after an
   agent-status load. */
function rpm_renderEventAgentFilter() {
    var container = document.getElementById('rpm-event-agent-filter');
    if (!container) return;

    var html = '<button class="rpm-event-agent-btn rpm-active" data-action-click="rpm-set-agent-filter" data-action-rpm-agent="ALL">All</button>';
    rpm_eventAgents.forEach(function(a) {
        html += '<button class="rpm-event-agent-btn" data-action-click="rpm-set-agent-filter" data-action-rpm-agent="' +
            a.id + '">' + cc_escapeHtml(a.label) + '</button>';
    });
    container.innerHTML = html;
}

/* Renders the event log body: shows an empty-state message when no events
   match, otherwise hands the event array to the row builder. */
function rpm_renderEvents(data) {
    var container = document.getElementById('rpm-event-log');

    if (!data.events || data.events.length === 0) {
        var msg = rpm_eventCorrelationMode ? 'No correlated events found' : 'No events for ' + rpm_eventDate;
        container.innerHTML = '<div class="rpm-no-data">' + msg + '</div>';
        return;
    }

    container.innerHTML = rpm_buildEventRows(data.events);
}

/* Builds the HTML for the event rows. Each row shows time, type badge,
   publication / agent type, optional state transition, an optional BIDATA
   correlation badge, and the event message. The transition span is always
   rendered (even when empty) so columns align across rows that do and don't
   carry transition data. */
function rpm_buildEventRows(events) {
    var html = '';
    events.forEach(function(e) {
        html += '<div class="rpm-event-row">';
        html += '<span class="rpm-event-time">' + rpm_formatEventTime(e.event_dttm) + '</span>';
        html += '<span class="rpm-event-type-badge rpm-event-type-' + e.event_type + '">' +
            e.event_type.replace('_', ' ') + '</span>';
        html += '<span class="rpm-event-publication">' + cc_escapeHtml(e.publication_name) +
            ' <span class="rpm-event-agent-type">(' + e.agent_type + ')</span></span>';

        html += '<span class="rpm-event-transition">';
        if (e.previous_state_desc || e.current_state_desc) {
            if (e.previous_state_desc) {
                html += '<span class="rpm-state-from">' + e.previous_state_desc + '</span>';
                html += '<span class="rpm-state-arrow">&rarr;</span>';
            }
            if (e.current_state_desc) {
                html += '<span class="rpm-state-to">' + e.current_state_desc + '</span>';
            }
        }
        html += '</span>';

        if (e.correlation_source) {
            html += '<span class="rpm-event-correlation" title="' + cc_escapeHtml(e.correlation_source) + '">B</span>';
        }

        html += '<span class="rpm-event-message">';
        if (e.event_message && e.event_message.indexOf('Performance stats') === -1) {
            html += '<span class="rpm-event-message-text" title="' + cc_escapeHtml(e.event_message) + '">' +
                cc_escapeHtml(e.event_message) + '</span>';
        }
        html += '</span>';

        html += '</div>';
    });
    return html;
}

/* ============================================================================
   FUNCTIONS: ACTION HANDLERS
   ----------------------------------------------------------------------------
   The page's delegated click and change dispatchers, plus the time-range
   button handler. Each dispatcher examines event.target for the nearest
   element carrying a data-action-<event> attribute, looks the value up in
   the matching dispatch table, and invokes the handler with (target,
   event). The bootloader's shared listener handles cc-* actions; these
   listeners handle every page-local action.
   Prefix: rpm
   ============================================================================ */

/* Delegated dispatcher for page-local click actions. Looks up the action
   value in rpm_clickActions and invokes the matching handler. Actions
   beginning with cc- are skipped (handled by cc-shared.js); an unknown
   action logs a warning and is ignored. */
function rpm_handleClickAction(event) {
    var target = event.target.closest('[data-action-click]');
    if (!target) return;
    var action = target.getAttribute('data-action-click');
    if (!action || action.indexOf('cc-') === 0) return;
    var handler = rpm_clickActions[action];
    if (!handler) {
        console.warn('[rpm] Unknown page click action: ' + action);
        return;
    }
    handler(target, event);
}

/* Delegated dispatcher for page-local change actions. Looks up the action
   value in rpm_changeActions and invokes the matching handler. */
function rpm_handleChangeAction(event) {
    var target = event.target.closest('[data-action-change]');
    if (!target) return;
    var action = target.getAttribute('data-action-change');
    if (!action || action.indexOf('cc-') === 0) return;
    var handler = rpm_changeActions[action];
    if (!handler) {
        console.warn('[rpm] Unknown page change action: ' + action);
        return;
    }
    handler(target, event);
}

/* Applies a chart time range from a clicked time-range button. Reads the
   chart and minutes from the button's data-action-rpm-chart and
   data-action-rpm-minutes argument attributes, updates the active state for
   that chart's button group, destroys the chart instance so it rebuilds
   with the new range, and triggers a fresh load. */
function rpm_setTimeRange(target) {
    var chart = target.dataset.actionRpmChart;
    var minutes = parseInt(target.dataset.actionRpmMinutes, 10);

    target.parentElement.querySelectorAll('.rpm-time-btn').forEach(function(b) { b.classList.remove('rpm-active'); });
    target.classList.add('rpm-active');

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
   FUNCTIONS: FORMATTERS
   ----------------------------------------------------------------------------
   Page-local display formatters and lookup utilities: agent run-status
   class / text / badge mapping, number / time-ago / event-time formatting,
   the page timestamp updater, and the connection-error banner controls. The
   standard cc_escapeHtml from cc-shared.js handles HTML escaping; these
   helpers handle the per-page display formats not covered by cc-shared.
   Prefix: rpm
   ============================================================================ */

/* Maps a SQL Server replication agent run_status code to the CSS status
   class used on the agent card root. */
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

/* Maps a SQL Server replication agent run_status code to a display label. */
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

/* Maps a SQL Server replication agent run_status code to the CSS class used
   on the status badge. */
function rpm_getBadgeClass(runStatus) {
    switch (runStatus) {
        case 1: return 'rpm-badge-started';
        case 2: return 'rpm-badge-running';
        case 3: return 'rpm-badge-idle';
        case 4: return 'rpm-badge-retrying';
        case 5: return 'rpm-badge-failed';
        case 6: return 'rpm-badge-stopped';
        default: return 'rpm-badge-unknown';
    }
}

/* Formats a number with a K / M suffix above one thousand / one million;
   returns a locale-formatted string for smaller values; "-" for null or
   undefined. */
function rpm_formatNumber(n) {
    if (n === null || n === undefined) return '-';
    if (n >= 1000000) return (n / 1000000).toFixed(1) + 'M';
    if (n >= 1000) return (n / 1000).toFixed(1) + 'K';
    return n.toLocaleString();
}

/* Formats a date string as a "X ago" relative duration: "30s ago", "5m
   ago", "3h ago", "2d ago". Returns "-" for null or unparseable input. */
function rpm_formatTimeAgo(dateStr) {
    if (!dateStr) return '-';
    var diff = (new Date() - new Date(dateStr)) / 1000;
    if (isNaN(diff)) return '-';
    if (diff < 60) return Math.round(diff) + 's ago';
    if (diff < 3600) return Math.round(diff / 60) + 'm ago';
    if (diff < 86400) return Math.round(diff / 3600) + 'h ago';
    return Math.round(diff / 86400) + 'd ago';
}

/* Formats a date string as the event log timestamp: HH:MM:SS in single-date
   mode, M/D HH:MM:SS in correlation mode (which spans dates). Returns "-"
   for null or unparseable input. */
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

/* Updates the live "last updated" timestamp display in the page header. */
function rpm_updateTimestamp() {
    var el = document.getElementById('cc-last-update');
    if (el) el.textContent = new Date().toLocaleTimeString();
}

/* Shows the inline connection error banner with a message, reusing the
   shared connection banner's disconnected state. */
function rpm_showError(msg) {
    var el = document.getElementById('cc-connection-banner');
    if (!el) return;
    el.textContent = msg;
    el.classList.add('cc-disconnected');
}

/* Hides the inline connection error banner. */
function rpm_clearError() {
    var el = document.getElementById('cc-connection-banner');
    if (!el) return;
    el.textContent = '';
    el.classList.remove('cc-disconnected');
}

/* ============================================================================
   FUNCTIONS: PAGE LIFECYCLE HOOKS
   ----------------------------------------------------------------------------
   Hooks invoked by cc-shared.js. The shared module resolves these via
   window[cc_pagePrefix + '_<name>'] at runtime, using the data-cc-prefix
   value declared on <body>. Each hook is rpm_-prefixed and exposed at the
   page-local namespace so the shared module's lookup pattern finds it.
   Prefix: rpm
   ============================================================================ */

/* Called by cc-shared.js when the user clicks the page refresh button.
   cc-shared.js drives the spin animation; this hook does the actual data
   reload. */
function rpm_onPageRefresh() {
    rpm_refreshAll();
}

/* Called by cc-shared.js when the page becomes visible again after being
   hidden. cc-shared.js drives the spin animation; this hook does the actual
   data reload so the user sees current data. */
function rpm_onPageResumed() {
    rpm_refreshAll();
}

/* Called by cc-shared.js when an orchestrator process listed in
   rpm_ENGINE_PROCESSES completes. Refreshes the event-driven sections so
   the UI picks up the freshly collected data. */
function rpm_onEngineProcessCompleted(processName, event) {
    rpm_refreshEventSections();
}

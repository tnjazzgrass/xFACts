/* ============================================================================
   xFACts Control Center - JBoss Monitoring (jboss-monitoring.js)
   Location: E:\xFACts-ControlCenter\public\js\jboss-monitoring.js
   Version: Tracked in dbo.System_Metadata (component: JBoss)

   Page-specific JavaScript for the JBoss Monitoring dashboard: loads the
   per-server metric snapshot and JMS queue snapshot, computes cumulative
   counter and per-queue deltas, renders the three-column server grid with its
   status badges, gauge mini-cards, transaction and HTTP delta rows, and the
   JMS queue accordion, and drives the server-metric info modal and the admin
   DM app-server switch flow. Chrome behavior (engine cards, connection banner,
   page refresh, idle/visibility handling, the shared fetch wrapper, and the
   alert/confirm modals) is owned by cc-shared.js; this file consumes it.

   FILE ORGANIZATION
   -----------------
   CONSTANTS: ENGINE PROCESSES
   CONSTANTS: ACTION DISPATCH
   CONSTANTS: DELTA FIELDS
   CONSTANTS: INFO CONTENT
   STATE: PAGE STATE
   FUNCTIONS: INITIALIZATION
   FUNCTIONS: ACTION DISPATCH
   FUNCTIONS: REFRESH AND DATA LOADING
   FUNCTIONS: DELTA COMPUTATION
   FUNCTIONS: SERVER CARD RENDERING
   FUNCTIONS: DELTA ROW BUILDERS
   FUNCTIONS: QUEUE LOGIC
   FUNCTIONS: QUEUE TABLE BUILDER
   FUNCTIONS: INFO MODAL
   FUNCTIONS: USERS BADGE
   FUNCTIONS: SWITCH MODAL
   FUNCTIONS: FORMAT HELPERS
   FUNCTIONS: PAGE LIFECYCLE HOOKS
   ============================================================================ */

/* ============================================================================
   CONSTANTS: ENGINE PROCESSES
   ----------------------------------------------------------------------------
   Maps the orchestrator process that drives this page's engine card to its
   slug. Read by cc-shared.js to populate and update the JBOSS engine card.
   Prefix: jbm
   ============================================================================ */

/* Engine-card process map consumed by cc-shared.js (declared var per spec). */
var jbm_ENGINE_PROCESSES = {
    'Collect-JBossMetrics': { slug: 'jboss' }
};

/* ============================================================================
   CONSTANTS: ACTION DISPATCH
   ----------------------------------------------------------------------------
   The page-local click-action dispatch table. Maps every jbm- data-action-click
   value declared in the page markup (and in JS-rendered card markup) to its
   handler. Routed by the delegated listener registered in jbm_init.
   Prefix: jbm
   ============================================================================ */

/* Page-local click-action handlers keyed by data-action-click value. */
const jbm_clickActions = {
    'jbm-show-info':       jbm_onShowInfo,
    'jbm-close-info':      jbm_onCloseInfo,
    'jbm-close-switch':    jbm_onCloseSwitch,
    'jbm-select-server':   jbm_onSelectServer,
    'jbm-toggle-queue':    jbm_onToggleQueue,
    'jbm-toggle-inactive': jbm_onToggleInactive,
    'jbm-open-switch':     jbm_onOpenSwitch
};

/* ============================================================================
   CONSTANTS: DELTA FIELDS
   ----------------------------------------------------------------------------
   The cumulative counter fields tracked for this-cycle delta computation.
   Prefix: jbm
   ============================================================================ */

/* Cumulative counters tracked for per-cycle delta detection. */
const jbm_DELTA_FIELDS = [
    'tx_committed', 'tx_timed_out', 'tx_rollbacks', 'tx_aborted', 'tx_heuristics',
    'undertow_request_count', 'undertow_error_count', 'undertow_bytes_sent',
    'undertow_processing_ms', 'ds_timed_out'
];

/* ============================================================================
   CONSTANTS: INFO CONTENT
   ----------------------------------------------------------------------------
   Plain-English help content for the server-metric info modal, keyed by the
   info-key carried on each "?" icon. Body markup uses page-local jbm- classes
   and renders inside the shared dialog body.
   Prefix: jbm
   ============================================================================ */

/* Help-modal content keyed by metric info-key. */
const jbm_INFO = {
    'overview': {
        title: 'Understanding This Page',
        body: '<p>This page monitors the three JBoss application servers. These servers run <strong>JBoss</strong> &mdash; the application server that hosts Debt Manager. Every time you open DM, run a job, post a payment, or load a batch, JBoss is the engine doing the work.</p>' +
            '<p>Think of each server card as a dashboard for one engine:</p>' +
            '<div class="jbm-info-list">' +
                '<div class="jbm-info-item"><strong>Status badges</strong> (top row) are the quick health check &mdash; is the front door open, is the engine running, is JBoss responding?</div>' +
                '<div class="jbm-info-item"><strong>JVM Heap</strong> is how much memory the engine is using. Like a car&rsquo;s fuel gauge, but for RAM.</div>' +
                '<div class="jbm-info-item"><strong>Threads</strong> are how many things the engine is doing at once. Each user action, each batch process, each scheduled job uses threads.</div>' +
                '<div class="jbm-info-item"><strong>DB Pool</strong> is the pipeline between JBoss and the database. JBoss keeps a pool of database connections open and ready. When the pool runs low, things slow down.</div>' +
                '<div class="jbm-info-item"><strong>Transactions</strong> are the work units. A committed transaction is a completed operation. Timeouts and rollbacks mean something went wrong.</div>' +
                '<div class="jbm-info-item"><strong>HTTP Server</strong> is the web server layer inside JBoss that handles all incoming requests &mdash; page loads, API calls, everything.</div>' +
                '<div class="jbm-info-item"><strong>JMS Queues</strong> are internal work queues. When you trigger a batch or a job, it gets placed in a queue and processed in order. If queues back up, work is waiting.</div>' +
            '</div>' +
            '<p>The key insight: <strong>these queues are independent per server, not shared.</strong> When a server freezes, all its queued work stops. The other servers can&rsquo;t pick it up. That&rsquo;s why we monitor each server separately.</p>'
    },
    'status-badges': {
        title: 'Status Badges',
        body: '<p>The status badges across the top of each card are the fastest health check:</p>' +
            '<div class="jbm-info-list">' +
                '<div class="jbm-info-item"><strong>HTTP</strong> &mdash; Can we reach the server? Every 60 seconds, xFACts hits the DM splash page. If it responds with HTTP 200, the server is alive. The number in parentheses is the response time in milliseconds. Under 50ms is fast; over 500ms is sluggish. If this badge goes red, the server is unreachable &mdash; likely frozen or down.</div>' +
                '<div class="jbm-info-item"><strong>Service</strong> &mdash; Is the Windows service running? This checks the actual DebtManager-Host service on the server. It can show Running even when the application is frozen (which is the whole problem &mdash; the process is alive but not responding).</div>' +
                '<div class="jbm-info-item"><strong>JBoss</strong> &mdash; Is the application server in a healthy state? Values: <em>running</em> (good), <em>reload-required</em> (config change needs a restart), <em>stopped</em> (down). This comes from the JBoss Management API and only appears when API access is available.</div>' +
                '<div class="jbm-info-item"><strong>Uptime</strong> &mdash; How long since the last OS reboot. If one server shows significantly less uptime than the others, it was recently restarted. Useful for context when looking at metrics that reset on restart.</div>' +
            '</div>'
    },
    'jvm-heap': {
        title: 'JVM Heap Memory',
        body: '<p>JBoss runs inside a Java Virtual Machine (JVM), and the <strong>heap</strong> is the chunk of memory Java uses to store everything the application is working with &mdash; user sessions, cached data, objects being processed, queued work items.</p>' +
            '<p>The percentage bar shows how full the heap is relative to its configured maximum (typically 8 GB per server).</p>' +
            '<div class="jbm-info-thresholds">' +
                '<span class="jbm-info-thresholds-line"><span class="jbm-info-green">&#9679; Under 75%</span> &mdash; Normal. Java&rsquo;s garbage collector has room to work.</span>' +
                '<span class="jbm-info-thresholds-line"><span class="jbm-info-yellow">&#9679; 75% &ndash; 90%</span> &mdash; Elevated. Garbage collection runs more frequently, which can slow things down. Worth watching but not necessarily a problem.</span>' +
                '<span class="jbm-info-thresholds-line"><span class="jbm-info-red">&#9679; Over 90%</span> &mdash; Critical. Java is spending more time cleaning up memory than doing useful work. Performance degrades significantly. If it hits 100%, the application may freeze entirely.</span>' +
            '</div>' +
            '<p><strong>Non-heap</strong> is memory Java uses for its own internals (class definitions, compiled code). It grows slowly and is rarely a concern.</p>' +
            '<p><strong>OS (Working Set)</strong> is the total memory the JBoss process uses from the operating system&rsquo;s perspective. This is always larger than the heap because it includes non-heap, native memory, and OS overhead.</p>'
    },
    'jvm-threads': {
        title: 'JVM Threads',
        body: '<p>A <strong>thread</strong> is a unit of work inside JBoss. Every user request, every background job, every internal process runs on a thread. More threads = more things happening simultaneously.</p>' +
            '<p>The gauge bar shows current threads relative to the <strong>peak</strong> (highest thread count since restart). This helps you see if the server is approaching its historical maximum.</p>' +
            '<p>Typical patterns:</p>' +
            '<div class="jbm-info-list">' +
                '<div class="jbm-info-item"><strong>Stable thread count (~150&ndash;300)</strong> &mdash; Normal. JBoss reuses threads from a pool.</div>' +
                '<div class="jbm-info-item"><strong>Climbing thread count</strong> &mdash; Potential concern. Could indicate requests piling up (threads waiting on slow operations) or a thread leak.</div>' +
                '<div class="jbm-info-item"><strong>Thread count near peak</strong> &mdash; The server is as busy as it&rsquo;s ever been. Not necessarily bad, but worth correlating with other metrics.</div>' +
            '</div>'
    },
    'db-pool': {
        title: 'Database Connection Pool',
        body: '<p>JBoss keeps a <strong>pool</strong> of pre-opened database connections ready to use. When application code needs to query the database, it borrows a connection from the pool, uses it, and returns it. This is much faster than opening a new connection every time.</p>' +
            '<p><strong>In-use / Active</strong> shows how many connections are currently borrowed vs. how many exist in the pool total.</p>' +
            '<div class="jbm-info-list">' +
                '<div class="jbm-info-item"><strong>Idle</strong> &mdash; Connections sitting in the pool waiting to be used. More idle = more headroom.</div>' +
                '<div class="jbm-info-item"><strong>Peak</strong> &mdash; Highest concurrent in-use count since restart. The historical high-water mark.</div>' +
                '<div class="jbm-info-item"><strong>Avg get time</strong> &mdash; Average time to borrow a connection. Under 5ms is normal. Rising times mean contention.</div>' +
            '</div>' +
            '<div class="jbm-info-thresholds">' +
                '<span class="jbm-info-thresholds-line"><span class="jbm-info-green">&#9679; Under 50% utilization</span> &mdash; Plenty of room.</span>' +
                '<span class="jbm-info-thresholds-line"><span class="jbm-info-yellow">&#9679; 50% &ndash; 80%</span> &mdash; Getting busy. Watch the trend.</span>' +
                '<span class="jbm-info-thresholds-line"><span class="jbm-info-red">&#9679; Over 80%</span> &mdash; Pool is under pressure. If it hits 100%, threads start waiting and the application slows down.</span>' +
            '</div>' +
            '<p>If you see <strong>"threads waiting for connections"</strong>, the pool is exhausted. Application threads are blocked until a connection is returned. This directly impacts response times and can cascade into a freeze.</p>'
    },
    'transactions': {
        title: 'Transactions',
        body: '<p>A <strong>transaction</strong> is a unit of database work &mdash; a query, an update, a batch of operations that either all succeed or all fail. Every time DM saves data, posts a payment, or processes a batch, it&rsquo;s wrapped in a transaction.</p>' +
            '<p>Each row shows <strong>"this cycle"</strong> (the change since last collection, ~60 seconds ago) and the <strong>cumulative total</strong> since JBoss started.</p>' +
            '<div class="jbm-info-list">' +
                '<div class="jbm-info-item"><strong>In-flight</strong> &mdash; Transactions currently in progress. A few at a time is normal. A sustained high number means transactions are taking longer than usual.</div>' +
                '<div class="jbm-info-item"><strong>Committed</strong> &mdash; Successfully completed transactions. This is the throughput indicator. Higher during business hours, lower at night. <span class="jbm-info-green">Informational, not concerning.</span></div>' +
                '<div class="jbm-info-item"><strong>Timed out</strong> &mdash; Transactions that took longer than the 15-minute timeout. <span class="jbm-info-red">Any increase means something was stuck for a long time.</span> This is rare and always worth investigating.</div>' +
                '<div class="jbm-info-item"><strong>Rollbacks</strong> &mdash; Transactions that were intentionally reversed by the application. <span class="jbm-info-yellow">Some rollbacks are normal</span> (validation failures, duplicate checks). A sudden spike may indicate a problem.</div>' +
                '<div class="jbm-info-item"><strong>Heuristics</strong> &mdash; Rare edge cases where the transaction manager had to make a unilateral decision about a two-phase commit. Typically stays at zero or a small constant. Not usually concerning unless it&rsquo;s actively growing.</div>' +
            '</div>'
    },
    'http-server': {
        title: 'HTTP Server (Undertow)',
        body: '<p><strong>Undertow</strong> is the web server built into JBoss. It handles every HTTP request that comes into the DM application &mdash; page loads, API calls, file downloads, everything. Think of it as the front desk: all traffic passes through here.</p>' +
            '<p>Like the Transactions card, this shows <strong>"this cycle"</strong> deltas (changes since last collection) alongside cumulative totals.</p>' +
            '<div class="jbm-info-list">' +
                '<div class="jbm-info-item"><strong>Requests</strong> &mdash; Total HTTP requests handled. The "this cycle" number shows how busy the server is right now. Higher during business hours, lower at night. This is informational, not concerning by itself.</div>' +
                '<div class="jbm-info-item"><strong>Errors</strong> &mdash; HTTP requests that returned an error. <span class="jbm-info-green">Zero is the goal.</span> <span class="jbm-info-red">Any increase here needs attention</span> &mdash; it could mean application errors, misconfigured endpoints, or server-side failures.</div>' +
                '<div class="jbm-info-item"><strong>Data sent</strong> &mdash; Bytes served this cycle and total since restart. A spike in data with stable request count could mean large reports or file exports are being pulled.</div>' +
                '<div class="jbm-info-item"><strong>Processing</strong> &mdash; Total server-side processing time spent handling requests. Combined with request count, gives a sense of how hard the server is working. Requires <code>record-request-start-time</code> to be enabled on the Undertow HTTP listener (pending next JBoss restart).</div>' +
                '<div class="jbm-info-item"><strong>Max request</strong> &mdash; The single slowest HTTP request the server has handled since JBoss started. A high-water mark that resets on restart. Useful for spotting outlier requests. Also requires <code>record-request-start-time</code>.</div>' +
            '</div>' +
            '<p>If you see <span class="jbm-info-red">"IO queue: N waiting"</span> at the bottom, that means incoming requests are piling up faster than Undertow can process them. The server is overwhelmed &mdash; this typically only happens during a freeze or extreme load.</p>'
    },
    'jms-queues': {
        title: 'JMS Queues',
        body: '<p><strong>JMS (Java Message Service) queues</strong> are how JBoss organizes internal work. When you trigger an action in DM &mdash; release a batch, start a payment import, generate a document &mdash; it doesn&rsquo;t happen immediately in your browser session. Instead, a <em>message</em> gets placed in a queue, and a background <em>consumer</em> picks it up and processes it.</p>' +
            '<p>This is the same concept as a print queue: you click "print" and the job goes into a queue where the printer processes it when it&rsquo;s ready.</p>' +
            '<p><strong>Key concepts:</strong></p>' +
            '<div class="jbm-info-list">' +
                '<div class="jbm-info-item"><strong>Pending</strong> &mdash; Messages waiting to be picked up. Zero is healthy. A sustained non-zero means work is backing up &mdash; consumers aren&rsquo;t keeping pace.</div>' +
                '<div class="jbm-info-item"><strong>Delivering</strong> &mdash; Messages picked up by a consumer but not yet finished. These are in-flight. High delivering with stable pending = normal processing. High delivering with rising pending = consumers are stuck.</div>' +
                '<div class="jbm-info-item"><strong>Consumers</strong> &mdash; The number of background workers listening on this queue. Zero consumers on an active queue means nobody is processing work. The requestQueue typically has ~70 consumers; most others have 1&ndash;6.</div>' +
                '<div class="jbm-info-item"><strong>Added</strong> &mdash; Total messages ever added to this queue since JBoss started. The difference between snapshots shows throughput.</div>' +
            '</div>' +
            '<p><strong>Critical fact: Queues are independent per server.</strong> They are not shared across the three DM app servers. When APP2 freezes, all work queued on APP2 stops. APP and APP3 cannot pick it up. Each server&rsquo;s queues are an isolated world.</p>' +
            '<p>Click the queue card to expand the full queue table with per-queue details.</p>'
    }
};

/* ============================================================================
   STATE: PAGE STATE
   ----------------------------------------------------------------------------
   Mutable page state: the auto-refresh timer and interval, the most recent
   server and queue data, the active DM server and admin switch gate, the
   in-progress switch flag, the delta-tracking baselines, and the set of open
   accordions preserved across re-renders.
   Prefix: jbm
   ============================================================================ */

/* Handle for the auto-refresh interval timer (null when not running). */
var jbm_refreshInterval = null;

/* Auto-refresh cadence in seconds (overwritten from the page refresh config). */
var jbm_refreshSeconds = 60;

/* Most recent per-server metric snapshot array. */
var jbm_serverData = [];

/* Most recent per-server queue snapshot, keyed by server_id. */
var jbm_queueData = {};

/* The currently active DM app server (SharePoint link target), or null. */
var jbm_activeServer = null;

/* Whether the current viewer may switch the active server (admin gate from the API). */
var jbm_canSwitch = false;

/* Whether a server switch is currently in progress (locks the switch modal). */
var jbm_switchingServer = false;

/* Per-server snapshot baselines for cumulative counter delta detection. */
var jbm_snapshotState = {};

/* Per-server queue baselines for per-queue messages-added delta detection. */
var jbm_queueDeltaState = {};

/* Which queue accordions are open, preserved across re-renders. */
var jbm_openAccordions = {};

/* ============================================================================
   FUNCTIONS: INITIALIZATION
   ----------------------------------------------------------------------------
   The page boot function invoked by cc-shared.js after the module loads.
   Registers the delegated click listener, connects engine events, and kicks
   off the initial data loads.
   Prefix: jbm
   ============================================================================ */

/* Boots the page: registers the delegated click dispatcher, connects shared
   engine events, and loads initial server, queue, active-server, and refresh
   data. */
function jbm_init() {
    document.body.addEventListener('click', jbm_dispatchClick);

    cc_connectEngineEvents();

    jbm_loadRefreshInterval();
    jbm_loadActiveServer();
    jbm_loadServerStatus();
    jbm_loadQueueStatus();
}

/* ============================================================================
   FUNCTIONS: ACTION DISPATCH
   ----------------------------------------------------------------------------
   The delegated click dispatcher registered on document.body by jbm_init.
   Routes page-local jbm- data-action-click values to their handler in the
   jbm_clickActions table.
   Prefix: jbm
   ============================================================================ */

/* Delegated click dispatcher: routes jbm- data-action-click values to their
   handler in jbm_clickActions. */
function jbm_dispatchClick(event) {
    var target = event.target.closest('[data-action-click]');
    if (!target) return;
    var action = target.getAttribute('data-action-click');
    if (!action || action.indexOf('jbm-') !== 0) return;
    var handler = jbm_clickActions[action];
    if (handler) handler(target, event);
}

/* ============================================================================
   FUNCTIONS: REFRESH AND DATA LOADING
   ----------------------------------------------------------------------------
   Loads the auto-refresh cadence and drives the periodic and on-demand
   reloads of server status, queue status, and the active server.
   Prefix: jbm
   ============================================================================ */

/* Loads the page refresh cadence from config, then starts auto-refresh. */
function jbm_loadRefreshInterval() {
    cc_engineFetch('/api/config/refresh-interval?page=jboss-monitoring').then(function(d) {
        if (d && d.interval_seconds) jbm_refreshSeconds = d.interval_seconds;
        jbm_startAutoRefresh();
    }).catch(function() { jbm_startAutoRefresh(); });
}

/* Starts (or restarts) the auto-refresh interval timer. */
function jbm_startAutoRefresh() {
    if (jbm_refreshInterval) clearInterval(jbm_refreshInterval);
    jbm_refreshInterval = setInterval(function() {
        jbm_loadServerStatus();
        jbm_loadQueueStatus();
        jbm_loadActiveServer();
    }, jbm_refreshSeconds * 1000);
}

/* Reloads all data sources (server, queue, active server). */
function jbm_refreshAll() {
    jbm_loadServerStatus();
    jbm_loadQueueStatus();
    jbm_loadActiveServer();
}

/* Reloads the event-driven sections (server and queue status). */
function jbm_refreshEventSections() {
    jbm_loadServerStatus();
    jbm_loadQueueStatus();
}

/* Loads the active DM server and the admin switch gate, then renders the badge. */
function jbm_loadActiveServer() {
    cc_engineFetch('/api/jboss-monitoring/active-server').then(function(d) {
        if (!d || d.Error) return;
        jbm_activeServer = d.active_server;
        jbm_canSwitch = (d.CanSwitch === true);
        jbm_renderUsersBadge();
    }).catch(function() {});
}

/* Loads the per-server metric snapshot, seeds delta baselines on first load,
   and renders the server cards. */
function jbm_loadServerStatus() {
    cc_engineFetch('/api/jboss-monitoring/status').then(function(data) {
        if (!data) return;
        if (data.error) { console.error('Server status:', data.error); return; }
        jbm_serverData = data.servers || [];

        // Seed delta baselines from the API-provided previous snapshot (first load only)
        for (var i = 0; i < jbm_serverData.length; i++) {
            var s = jbm_serverData[i];
            if (s.prev_collected_dttm && !jbm_snapshotState[s.server_id]) {
                var prevValues = { server_uptime_hours: s.prev_server_uptime_hours || null };
                for (var j = 0; j < jbm_DELTA_FIELDS.length; j++) {
                    var f = jbm_DELTA_FIELDS[j];
                    prevValues[f] = (s['prev_' + f] !== null && s['prev_' + f] !== undefined) ? s['prev_' + f] : null;
                }
                jbm_snapshotState[s.server_id] = {
                    collected_dttm: s.prev_collected_dttm,
                    values: prevValues,
                    deltas: {}
                };
            }
        }

        jbm_renderServers(jbm_serverData);
        jbm_updateTimestamp(data.timestamp);
    }).catch(function(err) { console.error('Failed to load server status:', err.message); });
}

/* Loads the per-server queue snapshot, seeds queue delta baselines on first
   load, and re-renders the server cards. */
function jbm_loadQueueStatus() {
    cc_engineFetch('/api/jboss-monitoring/queue-status').then(function(data) {
        if (!data) return;
        if (data.error) { console.error('Queue status:', data.error); return; }
        jbm_queueData = {};
        var s = data.servers || [];

        // Seed queue delta baselines from the API-provided previous cycle (first load only)
        for (var i = 0; i < s.length; i++) {
            var sv = s[i];
            if (sv.prev_collected_dttm && !jbm_queueDeltaState[sv.server_id]) {
                var prevValues = {};
                var qs = sv.queues || [];
                for (var j = 0; j < qs.length; j++) {
                    if (qs[j].prev_messages_added !== null && qs[j].prev_messages_added !== undefined) {
                        prevValues[qs[j].queue_name] = qs[j].prev_messages_added;
                    }
                }
                jbm_queueDeltaState[sv.server_id] = {
                    collected_dttm: sv.prev_collected_dttm,
                    values: prevValues,
                    deltas: {}
                };
            }
            jbm_queueData[sv.server_id] = sv;
        }

        if (jbm_serverData.length > 0) jbm_renderServers(jbm_serverData);
    }).catch(function(err) { console.error('Failed to load queue status:', err.message); });
}

/* ============================================================================
   FUNCTIONS: DELTA COMPUTATION
   ----------------------------------------------------------------------------
   Computes this-cycle deltas for cumulative counters, gated on collected_dttm
   so a same-snapshot re-render preserves last-known deltas, and resets the
   baseline on a detected JBoss restart.
   Prefix: jbm
   ============================================================================ */

/* Returns this-cycle deltas for all tracked counters for one server, updating
   the per-server baseline only when a new snapshot is seen. */
function jbm_computeDeltas(server) {
    var sid = server.server_id;
    var state = jbm_snapshotState[sid];

    // Same snapshot as last render: return last-known deltas without updating baseline
    if (state && state.collected_dttm === server.collected_dttm) {
        return state.deltas;
    }

    // Start with last-known deltas as fallback (or null on first load)
    var deltas = {};
    for (var i = 0; i < jbm_DELTA_FIELDS.length; i++) {
        deltas[jbm_DELTA_FIELDS[i]] = (state && state.deltas) ? state.deltas[jbm_DELTA_FIELDS[i]] : null;
    }

    if (state) {
        var prev = state.values;

        // Detect JBoss restart: uptime dropped, or any cumulative counter went down
        var restarted = false;
        if (prev.server_uptime_hours !== null && server.server_uptime_hours !== null
            && server.server_uptime_hours < prev.server_uptime_hours) {
            restarted = true;
        }
        if (!restarted) {
            for (var i = 0; i < jbm_DELTA_FIELDS.length; i++) {
                var f = jbm_DELTA_FIELDS[i];
                if (prev[f] !== null && prev[f] !== undefined
                    && server[f] !== null && server[f] !== undefined
                    && server[f] < prev[f]) {
                    restarted = true;
                    break;
                }
            }
        }

        if (restarted) {
            // Restart confirmed: reset all deltas to null
            for (var i = 0; i < jbm_DELTA_FIELDS.length; i++) deltas[jbm_DELTA_FIELDS[i]] = null;
        } else {
            // Compute deltas only where both prev and current are non-null
            for (var i = 0; i < jbm_DELTA_FIELDS.length; i++) {
                var f = jbm_DELTA_FIELDS[i];
                if (prev[f] !== null && prev[f] !== undefined
                    && server[f] !== null && server[f] !== undefined) {
                    deltas[f] = server[f] - prev[f];
                }
            }
        }
    }

    // Store current values as the new baseline, preserving last known-good for null fields
    var values = {};
    var prevValues = (state && state.values) ? state.values : {};
    values.server_uptime_hours = (server.server_uptime_hours !== null && server.server_uptime_hours !== undefined)
        ? server.server_uptime_hours : (prevValues.server_uptime_hours || null);
    for (var i = 0; i < jbm_DELTA_FIELDS.length; i++) {
        var f = jbm_DELTA_FIELDS[i];
        values[f] = (server[f] !== null && server[f] !== undefined) ? server[f] : (prevValues[f] || null);
    }

    jbm_snapshotState[sid] = {
        collected_dttm: server.collected_dttm,
        values: values,
        deltas: deltas
    };

    return deltas;
}

/* ============================================================================
   FUNCTIONS: SERVER CARD RENDERING
   ----------------------------------------------------------------------------
   Renders the three server cards from the metric snapshot: status badges,
   the JVM/threads/DB-pool gauge mini-cards, the transaction and HTTP delta
   cards, and the JMS queue accordion.
   Prefix: jbm
   ============================================================================ */

/* Renders all server cards, or a no-data placeholder when there is no data. */
function jbm_renderServers(servers) {
    if (!servers || servers.length === 0) {
        for (var i = 0; i < 3; i++) {
            var b = document.getElementById('jbm-server-body-' + i);
            if (b) b.innerHTML = '<div class="jbm-no-data">No data</div>';
        }
        return;
    }
    for (var i = 0; i < servers.length && i < 3; i++) jbm_renderServerCard(i, servers[i]);
    jbm_renderUsersBadge();
}

/* Renders one server card at the given column index from its server object. */
function jbm_renderServerCard(index, server) {
    var nameEl = document.getElementById('jbm-server-name-' + index);
    var roleEl = document.getElementById('jbm-server-role-' + index);
    var bodyEl = document.getElementById('jbm-server-body-' + index);
    var cardEl = document.getElementById('jbm-server-card-' + index);
    if (!nameEl || !bodyEl) return;

    var nameHtml = server.server_name;
    if (server.is_domain_controller) nameHtml += '<span class="jbm-dc-badge">DC</span>';
    nameEl.innerHTML = nameHtml;
    roleEl.textContent = server.server_role || '';

    cardEl.className = 'jbm-server-card';
    if (server.http_error_message || (server.http_status_code !== 200 && server.http_status_code !== null)) {
        cardEl.classList.add('jbm-card-critical');
    }

    if (!server.collected_dttm) {
        bodyEl.innerHTML = '<div class="jbm-no-data">No snapshots collected yet</div>';
        return;
    }

    var deltas = jbm_computeDeltas(server);

    var h = '';

    // Status badges row
    h += '<div class="jbm-status-badges-row">';
    var httpOk = server.http_status_code === 200 && !server.http_error_message;
    h += '<div class="jbm-status-badge ' + (httpOk ? 'jbm-badge-ok' : 'jbm-badge-fail') + '">';
    h += '<span class="jbm-badge-dot ' + (httpOk ? 'jbm-dot-ok' : 'jbm-dot-fail') + '"></span><span class="jbm-badge-text">HTTP</span>';
    if (httpOk && server.http_response_ms !== null) h += '<span class="jbm-badge-detail">' + server.http_response_ms + 'ms</span>';
    h += '</div>';

    var svcOk = server.service_state === 'Running';
    h += '<div class="jbm-status-badge ' + (svcOk ? 'jbm-badge-ok' : 'jbm-badge-warn') + '">';
    h += '<span class="jbm-badge-dot ' + (svcOk ? 'jbm-dot-ok' : 'jbm-dot-warn') + '"></span><span class="jbm-badge-text">Service</span>';
    h += '</div>';

    if (server.api_server_state) {
        var jbOk = server.api_server_state === 'running';
        h += '<div class="jbm-status-badge ' + (jbOk ? 'jbm-badge-ok' : 'jbm-badge-warn') + '">';
        h += '<span class="jbm-badge-dot ' + (jbOk ? 'jbm-dot-ok' : 'jbm-dot-warn') + '"></span><span class="jbm-badge-text">JBoss</span>';
        h += '<span class="jbm-badge-detail">' + server.api_server_state + '</span>';
        h += '</div>';
    }

    h += '<span class="jbm-badges-spacer"></span>';
    if (server.server_uptime_hours !== null) {
        h += '<div class="jbm-status-badge jbm-badge-neutral"><span class="jbm-uptime-label">up</span><span class="jbm-uptime-text">' + jbm_formatUptime(server.server_uptime_hours) + '</span></div>';
    }
    h += '</div>';

    if (server.http_error_message) h += '<div class="jbm-alert-row">' + cc_escapeHtml(server.http_error_message) + '</div>';

    // Mini-card: JVM Heap
    if (server.jvm_heap_used_mb !== null && server.jvm_heap_max_mb) {
        var hp = server.jvm_heap_max_mb > 0 ? Math.round((server.jvm_heap_used_mb / server.jvm_heap_max_mb) * 100) : 0;
        var hCls = hp >= 90 ? 'jbm-value-critical' : (hp >= 75 ? 'jbm-value-warning' : 'jbm-value-healthy');
        var hBar = hp >= 90 ? 'jbm-bar-critical' : (hp >= 75 ? 'jbm-bar-warning' : 'jbm-bar-healthy');
        h += '<div class="jbm-mini-card">';
        h += '<div class="jbm-mini-card-header"><span class="jbm-mini-card-title">JVM Heap <button type="button" class="jbm-info-icon" data-action-click="jbm-show-info" data-action-jbm-info-key="jvm-heap">?</button></span>';
        h += '<span class="jbm-mini-card-value ' + hCls + '">' + hp + '<span class="jbm-mini-card-unit">%</span></span></div>';
        h += '<div class="jbm-gauge-bar"><div class="jbm-gauge-fill ' + hBar + '" style="width:' + Math.min(hp, 100) + '%"></div></div>';
        h += '<div class="jbm-mini-card-detail"><span class="jbm-mini-card-detail-item">' + jbm_fmtN(server.jvm_heap_used_mb) + ' / ' + jbm_fmtN(server.jvm_heap_max_mb) + ' MB</span></div>';
        var ex = [];
        if (server.jvm_nonheap_used_mb !== null) ex.push('Non-heap: ' + jbm_fmtN(server.jvm_nonheap_used_mb) + ' MB');
        if (server.jboss_working_set_mb !== null) ex.push('OS: ' + jbm_fmtN(server.jboss_working_set_mb) + ' MB');
        if (ex.length > 0) h += '<div class="jbm-mini-card-secondary">' + ex.join(' &middot; ') + '</div>';
        h += '</div>';
    }

    // Mini-card: JVM Threads
    if (server.jvm_thread_count !== null) {
        var tp = server.jvm_thread_peak > 0 ? Math.round((server.jvm_thread_count / server.jvm_thread_peak) * 100) : 0;
        var tBar = tp >= 95 ? 'jbm-bar-warning' : 'jbm-bar-healthy';
        h += '<div class="jbm-mini-card">';
        h += '<div class="jbm-mini-card-header"><span class="jbm-mini-card-title">Threads <button type="button" class="jbm-info-icon" data-action-click="jbm-show-info" data-action-jbm-info-key="jvm-threads">?</button></span>';
        h += '<span class="jbm-mini-card-value">' + jbm_fmtN(server.jvm_thread_count) + '</span></div>';
        h += '<div class="jbm-gauge-bar"><div class="jbm-gauge-fill ' + tBar + '" style="width:' + Math.min(tp, 100) + '%"></div></div>';
        h += '<div class="jbm-mini-card-detail"><span class="jbm-mini-card-detail-item">Peak: ' + jbm_fmtN(server.jvm_thread_peak) + '</span></div>';
        h += '</div>';
    }

    // Mini-card: Datasource Pool
    if (server.ds_active_count !== null) {
        var dp = server.ds_active_count > 0 ? Math.round((server.ds_in_use_count / server.ds_active_count) * 100) : 0;
        var dCls = dp >= 80 ? 'jbm-value-critical' : (dp >= 50 ? 'jbm-value-warning' : 'jbm-value-healthy');
        var dBar = dp >= 80 ? 'jbm-bar-critical' : (dp >= 50 ? 'jbm-bar-warning' : 'jbm-bar-healthy');
        h += '<div class="jbm-mini-card">';
        h += '<div class="jbm-mini-card-header"><span class="jbm-mini-card-title">DB Pool <button type="button" class="jbm-info-icon" data-action-click="jbm-show-info" data-action-jbm-info-key="db-pool">?</button></span>';
        h += '<span class="jbm-mini-card-value ' + dCls + '">' + server.ds_in_use_count + ' / ' + server.ds_active_count + '</span></div>';
        h += '<div class="jbm-gauge-bar"><div class="jbm-gauge-fill ' + dBar + '" style="width:' + Math.min(dp, 100) + '%"></div></div>';
        h += '<div class="jbm-mini-card-detail">';
        h += '<span class="jbm-mini-card-detail-item">Idle: ' + server.ds_idle_count + '</span>';
        h += '<span class="jbm-mini-card-detail-item">Peak: ' + server.ds_max_used_count + '</span>';
        h += '<span class="jbm-mini-card-detail-item">' + server.ds_avg_get_time_ms + 'ms avg</span>';
        h += '</div>';
        if (server.ds_wait_count > 0) h += '<div class="jbm-alert-row">&#9888; ' + server.ds_wait_count + ' threads waiting for connections</div>';
        h += '</div>';
    }

    // Mini-card: Transactions
    if (server.tx_committed !== null) {
        h += '<div class="jbm-mini-card">';
        h += '<div class="jbm-mini-card-header"><span class="jbm-mini-card-title">Transactions <button type="button" class="jbm-info-icon" data-action-click="jbm-show-info" data-action-jbm-info-key="transactions">?</button></span></div>';
        h += '<div class="jbm-tx-rows">';
        h += jbm_buildTxRow('In-flight', server.tx_inflight, server.tx_inflight > 0);
        h += jbm_buildDeltaRow('Committed', server.tx_committed, deltas.tx_committed, 'good');
        h += jbm_buildDeltaRow('Timed out', server.tx_timed_out, deltas.tx_timed_out, 'critical', server.tx_committed);
        h += jbm_buildDeltaRow('Rollbacks', server.tx_rollbacks, deltas.tx_rollbacks, 'alert', server.tx_committed);
        h += jbm_buildDeltaRow('Heuristics', server.tx_heuristics, deltas.tx_heuristics, 'info', server.tx_committed);
        h += '</div>';
        h += '</div>';
    }

    // Mini-card: HTTP Server
    if (server.undertow_request_count !== null) {
        h += '<div class="jbm-mini-card">';
        h += '<div class="jbm-mini-card-header"><span class="jbm-mini-card-title">HTTP Server <button type="button" class="jbm-info-icon" data-action-click="jbm-show-info" data-action-jbm-info-key="http-server">?</button></span></div>';
        h += '<div class="jbm-tx-rows">';
        h += jbm_buildDeltaRow('Requests', server.undertow_request_count, deltas.undertow_request_count, 'good');
        h += jbm_buildDeltaRow('Errors', server.undertow_error_count, deltas.undertow_error_count, 'critical');
        h += jbm_buildDeltaRow('Data sent', server.undertow_bytes_sent, deltas.undertow_bytes_sent, 'good');
        h += jbm_buildDeltaRow('Processing', server.undertow_processing_ms, deltas.undertow_processing_ms, 'info');
        h += '<div class="jbm-delta-row"><span class="jbm-delta-label">Max request</span>';
        h += '<span class="jbm-delta-zero">' + (server.undertow_max_proc_ms !== null ? jbm_fmtN(server.undertow_max_proc_ms) + ' ms' : '&mdash;') + '</span>';
        h += '<span class="jbm-delta-cumulative"></span></div>';
        h += '</div>';
        if (server.io_worker_queue_size > 0) h += '<div class="jbm-alert-row">&#9888; IO queue: ' + server.io_worker_queue_size + ' waiting</div>';
        h += '</div>';
    }

    // Mini-card: JMS Queues
    var sq = jbm_queueData[server.server_id];
    if (sq) {
        var queueDeltas = jbm_computeQueueDeltas(sq);
        var queueStats = jbm_classifyQueues(sq.queues || [], queueDeltas);
        var isOpen = jbm_openAccordions[server.server_id] !== undefined ? jbm_openAccordions[server.server_id] : true;
        var inactiveOpen = jbm_openAccordions['inactive-' + server.server_id] || false;

        h += '<div class="jbm-mini-card jbm-queue-card">';
        h += '<div class="jbm-mini-card-header jbm-queue-accordion-trigger" data-action-click="jbm-toggle-queue" data-action-jbm-server-id="' + server.server_id + '">';
        h += '<span class="jbm-mini-card-title">JMS Queues <button type="button" class="jbm-info-icon" data-action-click="jbm-show-info" data-action-jbm-info-key="jms-queues">?</button></span>';

        if (queueStats.stuck > 0) {
            h += '<span class="jbm-mini-card-value jbm-value-critical">' + queueStats.stuck + ' <span class="jbm-mini-card-unit">stuck</span></span>';
        } else if (queueStats.active.length > 0) {
            h += '<span class="jbm-mini-card-value">' + queueStats.active.length + ' <span class="jbm-mini-card-unit">active</span></span>';
        } else {
            h += '<span class="jbm-mini-card-value jbm-value-healthy">Idle</span>';
        }
        h += '<span class="jbm-accordion-arrow' + (isOpen ? ' jbm-accordion-arrow-open' : '') + '">&#9660;</span>';
        h += '</div>';

        if (queueStats.stuck > 0) {
            h += '<div class="jbm-alert-row">' + queueStats.stuck + ' queue' + (queueStats.stuck !== 1 ? 's' : '') + ' stuck &mdash; pending messages with no consumers or no delivery</div>';
        } else if (queueStats.totalAdded > 0) {
            h += '<div class="jbm-queue-summary-ok">' + queueStats.active.length + ' queue' + (queueStats.active.length !== 1 ? 's' : '') + ' active &middot; ' + jbm_fmtN(queueStats.totalAdded) + ' messages this cycle</div>';
        } else if (queueStats.processing > 0) {
            h += '<div class="jbm-queue-summary-ok">' + queueStats.processing + ' queue' + (queueStats.processing !== 1 ? 's' : '') + ' processing &mdash; ' + jbm_fmtN(queueStats.totalPending) + ' in flight</div>';
        }

        h += '<div class="jbm-queue-accordion-body' + (isOpen ? ' jbm-queue-accordion-body-open' : '') + '" id="jbm-queue-accordion-' + server.server_id + '">';

        if (queueStats.active.length > 0) {
            h += jbm_buildQueueTable(queueStats.active, true);
        } else {
            h += '<div class="jbm-queue-idle-msg">No queue activity this cycle</div>';
        }

        if (queueStats.inactive.length > 0) {
            h += '<div class="jbm-queue-inactive-toggle" data-action-click="jbm-toggle-inactive" data-action-jbm-server-id="' + server.server_id + '">';
            h += '<span class="jbm-queue-inactive-arrow' + (inactiveOpen ? ' jbm-queue-inactive-arrow-open' : '') + '">&#9654;</span> ';
            h += queueStats.inactive.length + ' inactive queue' + (queueStats.inactive.length !== 1 ? 's' : '');
            h += '</div>';
            h += '<div class="jbm-queue-inactive-body' + (inactiveOpen ? ' jbm-queue-inactive-body-open' : '') + '" id="jbm-queue-inactive-' + server.server_id + '">';
            h += jbm_buildQueueTable(queueStats.inactive, false);
            h += '</div>';
        }

        h += '</div>';
        h += '</div>';
    }

    h += '<div class="jbm-card-footer">Collected: ' + server.collected_dttm + '</div>';
    bodyEl.innerHTML = h;
}

/* ============================================================================
   FUNCTIONS: DELTA ROW BUILDERS
   ----------------------------------------------------------------------------
   Builds the per-counter rows shown inside the Transactions and HTTP Server
   mini-cards: a delta indicator plus a muted cumulative total.
   Prefix: jbm
   ============================================================================ */

/* Builds a counter row with a this-cycle delta indicator and a muted
   since-restart cumulative total. */
function jbm_buildDeltaRow(label, cumulative, delta, severity, pctOf) {
    var h = '<div class="jbm-delta-row">';
    h += '<span class="jbm-delta-label">' + label + '</span>';

    if (delta !== null && delta > 0) {
        var cls = severity === 'critical' ? 'jbm-delta-critical' : (severity === 'alert' ? 'jbm-delta-alert' : (severity === 'good' ? 'jbm-delta-good' : 'jbm-delta-info'));
        h += '<span class="' + cls + '">' + jbm_fmtDelta(label, delta) + ' this cycle</span>';
    } else if (delta !== null && delta === 0) {
        h += '<span class="jbm-delta-zero">0 this cycle</span>';
    } else {
        h += '<span class="jbm-delta-zero">&mdash;</span>';
    }

    var cumStr = jbm_fmtCumulative(label, cumulative);
    if (pctOf && pctOf > 0 && cumulative !== null && cumulative !== undefined && cumulative > 0) {
        var pct = (cumulative / pctOf * 100);
        cumStr += '<span class="jbm-delta-pct"> (' + (pct < 0.01 ? '&lt;0.01' : (pct < 1 ? pct.toFixed(2) : pct.toFixed(1))) + '%)</span>';
    }
    h += '<span class="jbm-delta-cumulative">' + cumStr + ' since restart</span>';
    h += '</div>';
    return h;
}

/* Builds a non-delta row for a real-time (non-cumulative) value such as
   in-flight transactions. */
function jbm_buildTxRow(label, value, isActive) {
    var h = '<div class="jbm-delta-row">';
    h += '<span class="jbm-delta-label">' + label + '</span>';
    if (isActive) {
        h += '<span class="jbm-delta-running">' + jbm_fmtN(value) + ' active</span>';
    } else {
        h += '<span class="jbm-delta-info">' + jbm_fmtN(value) + '</span>';
    }
    h += '<span class="jbm-delta-cumulative"></span>';
    h += '</div>';
    return h;
}

/* ============================================================================
   FUNCTIONS: QUEUE LOGIC
   ----------------------------------------------------------------------------
   Computes per-queue messages-added deltas and classifies queues into active,
   inactive, stuck, and processing groups.
   Prefix: jbm
   ============================================================================ */

/* Returns per-queue this-cycle messages-added deltas for one server, gated on
   collected_dttm and reset on a counter decrease (JBoss restart). */
function jbm_computeQueueDeltas(serverQueue) {
    var sid = serverQueue.server_id;
    var state = jbm_queueDeltaState[sid];
    var qs = serverQueue.queues || [];

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

    jbm_queueDeltaState[sid] = {
        collected_dttm: serverQueue.collected_dttm,
        values: values,
        deltas: deltas
    };

    return deltas;
}

/* Classifies a server's queues into active/inactive and counts stuck and
   processing queues using current state and computed deltas. */
function jbm_classifyQueues(queues, queueDeltas) {
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

/* ============================================================================
   FUNCTIONS: QUEUE TABLE BUILDER
   ----------------------------------------------------------------------------
   Builds the per-queue detail table rendered inside the accordion body. Every
   element carries a jbm- class (no element or descendant selectors in CSS).
   Prefix: jbm
   ============================================================================ */

/* Builds a per-queue detail table from an array of {queue, delta} items,
   optionally including the this-cycle delta column. */
function jbm_buildQueueTable(items, showDelta) {
    if (items.length === 0) return '';
    var h = '<table class="jbm-qtable"><thead><tr>';
    h += '<th class="jbm-q-th jbm-q-name">Queue</th>';
    if (showDelta) h += '<th class="jbm-q-th jbm-q-num">This Cycle</th>';
    h += '<th class="jbm-q-th jbm-q-num">Pending</th>';
    h += '<th class="jbm-q-th jbm-q-num">Delivering</th>';
    h += '<th class="jbm-q-th jbm-q-num">Consumers</th>';
    h += '<th class="jbm-q-th jbm-q-num">Total Added</th>';
    h += '</tr></thead><tbody>';
    for (var i = 0; i < items.length; i++) {
        var qi = items[i].queue;
        var delta = items[i].delta;
        var isStuck = qi.message_count > 0 && (qi.consumer_count === 0 || qi.delivering_count === 0);
        var isDeadConsumer = qi.consumer_count === 0 && qi.messages_added > 0 && qi.message_count === 0;
        var rowCls = 'jbm-q-row' + (isStuck ? ' jbm-q-row-alert' : (isDeadConsumer ? ' jbm-q-row-warn' : ''));
        var cellCls = 'jbm-q-cell' + (isStuck ? ' jbm-q-cell-alert' : '');
        var nameCls = 'jbm-q-cell jbm-q-name' + (isDeadConsumer ? ' jbm-q-name-warn' : '') + (isStuck ? ' jbm-q-cell-alert' : '');
        h += '<tr class="' + rowCls + '">';
        h += '<td class="' + nameCls + '">' + qi.queue_name + '</td>';
        if (showDelta) {
            if (delta !== null && delta > 0) {
                h += '<td class="jbm-q-cell jbm-q-num jbm-q-delta-active">' + jbm_fmtN(delta) + '</td>';
            } else {
                h += '<td class="jbm-q-cell jbm-q-num jbm-q-delta-zero">' + (delta !== null ? '0' : '&mdash;') + '</td>';
            }
        }
        h += '<td class="' + cellCls + ' jbm-q-num">' + jbm_fmtN(qi.message_count) + '</td>';
        h += '<td class="' + cellCls + ' jbm-q-num">' + jbm_fmtN(qi.delivering_count) + '</td>';
        h += '<td class="' + cellCls + ' jbm-q-num">' + jbm_fmtN(qi.consumer_count) + '</td>';
        h += '<td class="' + cellCls + ' jbm-q-num">' + jbm_fmtN(qi.messages_added) + '</td>';
        h += '</tr>';
    }
    h += '</tbody></table>';
    return h;
}

/* Toggles a server's queue accordion open or closed and updates its arrow. */
function jbm_onToggleQueue(target) {
    var serverId = target.getAttribute('data-action-jbm-server-id');
    jbm_openAccordions[serverId] = !jbm_openAccordions[serverId];
    var body = document.getElementById('jbm-queue-accordion-' + serverId);
    if (!body) return;
    var card = body.closest('.jbm-queue-card');
    var arrow = card ? card.querySelector('.jbm-accordion-arrow') : null;
    if (jbm_openAccordions[serverId]) {
        body.classList.add('jbm-queue-accordion-body-open');
        if (arrow) arrow.classList.add('jbm-accordion-arrow-open');
    } else {
        body.classList.remove('jbm-queue-accordion-body-open');
        if (arrow) arrow.classList.remove('jbm-accordion-arrow-open');
    }
}

/* Toggles a server's inactive-queues section open or closed. */
function jbm_onToggleInactive(target) {
    var serverId = target.getAttribute('data-action-jbm-server-id');
    var key = 'inactive-' + serverId;
    jbm_openAccordions[key] = !jbm_openAccordions[key];
    var body = document.getElementById('jbm-queue-inactive-' + serverId);
    if (!body) return;
    var arrow = target.querySelector('.jbm-queue-inactive-arrow');
    if (jbm_openAccordions[key]) {
        body.classList.add('jbm-queue-inactive-body-open');
        if (arrow) arrow.classList.add('jbm-queue-inactive-arrow-open');
    } else {
        body.classList.remove('jbm-queue-inactive-body-open');
        if (arrow) arrow.classList.remove('jbm-queue-inactive-arrow-open');
    }
}

/* ============================================================================
   FUNCTIONS: INFO MODAL
   ----------------------------------------------------------------------------
   Opens and closes the server-metric help modal, populating the shared dialog
   body from the jbm_INFO content map.
   Prefix: jbm
   ============================================================================ */

/* Opens the info modal for the metric named by the icon's info-key. */
function jbm_onShowInfo(target) {
    var key = target.getAttribute('data-action-jbm-info-key');
    var info = jbm_INFO[key];
    if (!info) return;
    document.getElementById('jbm-info-title').textContent = info.title;
    document.getElementById('jbm-info-body').innerHTML = info.body;
    document.getElementById('jbm-modal-info').classList.remove('cc-hidden');
}

/* Closes the info modal on backdrop click or close control, ignoring interior
   click bubbling. */
function jbm_onCloseInfo(target, event) {
    if (event && target.id === 'jbm-modal-info' && event.target !== target) {
        return;
    }
    document.getElementById('jbm-modal-info').classList.add('cc-hidden');
}

/* ============================================================================
   FUNCTIONS: USERS BADGE
   ----------------------------------------------------------------------------
   Renders the "Users" pill on the active server's card; for admins the pill
   becomes a clickable affordance that opens the switch picker.
   Prefix: jbm
   ============================================================================ */

/* Renders (or re-renders) the Users badge on the active server's card header. */
function jbm_renderUsersBadge() {
    var e = document.querySelector('.jbm-users-badge');
    if (e) e.remove();
    if (!jbm_activeServer || !jbm_serverData || jbm_serverData.length === 0) return;
    for (var i = 0; i < jbm_serverData.length; i++) {
        if (jbm_serverData[i].server_name.toUpperCase() === jbm_activeServer.toUpperCase()) {
            var hdr = document.querySelector('#jbm-server-card-' + i + ' .jbm-server-card-header');
            if (!hdr) return;
            var b = document.createElement('span');
            b.className = 'jbm-users-badge';
            b.textContent = 'Users';
            b.title = 'SharePoint Debt Manager link points here';
            if (jbm_canSwitch) {
                b.classList.add('jbm-users-badge-clickable');
                b.title = 'Click to change SharePoint link target';
                b.setAttribute('data-action-click', 'jbm-open-switch');
            }
            hdr.appendChild(b);
            return;
        }
    }
}

/* ============================================================================
   FUNCTIONS: SWITCH MODAL
   ----------------------------------------------------------------------------
   Drives the admin DM app-server switch: opening the picker, rendering the
   picker buttons, confirming via the shared confirm modal, and performing the
   switch with a locked, in-progress state.
   Prefix: jbm
   ============================================================================ */

/* Opens the switch picker (admins only), resets the status line, and renders
   the picker buttons. */
function jbm_onOpenSwitch() {
    if (!jbm_canSwitch) return;
    document.getElementById('jbm-modal-switch').classList.remove('cc-hidden');
    if (!jbm_switchingServer) {
        var st = document.getElementById('jbm-switch-status');
        st.textContent = '';
        st.className = 'jbm-switch-status';
    }
    jbm_renderSwitchButtons();
}

/* Closes the switch modal on backdrop click or close control, unless a switch
   is in progress, ignoring interior click bubbling. */
function jbm_onCloseSwitch(target, event) {
    if (jbm_switchingServer) return;
    if (event && target.id === 'jbm-modal-switch' && event.target !== target) {
        return;
    }
    document.getElementById('jbm-modal-switch').classList.add('cc-hidden');
}

/* Marks the picker button for the active server and disables it. */
function jbm_renderSwitchButtons() {
    var btns = document.querySelectorAll('.jbm-switch-btn');
    for (var i = 0; i < btns.length; i++) {
        var btn = btns[i];
        var s = btn.getAttribute('data-action-jbm-server');
        if (s.toUpperCase() === (jbm_activeServer || '').toUpperCase()) {
            btn.classList.add('jbm-switch-btn-active');
            btn.disabled = true;
        } else {
            btn.classList.remove('jbm-switch-btn-active');
            btn.disabled = false;
        }
    }
}

/* Handles a picker button click: confirms the destructive switch via the
   shared confirm modal, then performs it. */
function jbm_onSelectServer(target) {
    var server = target.getAttribute('data-action-jbm-server');
    if (server.toUpperCase() === (jbm_activeServer || '').toUpperCase()) return;
    var from = jbm_activeServer ? jbm_activeServer.replace('DM-PROD-', '') : '?';
    var to = server.replace('DM-PROD-', '');
    jbm_closeSwitchModal();

    cc_showConfirm('Redirect SharePoint link from ' + from + ' to ' + to + '?\n\nThis immediately affects all users.', {
        title: 'Switch DM App Server',
        confirmLabel: 'Switch to ' + to,
        confirmClass: 'cc-dialog-btn-danger'
    }).then(function(confirmed) {
        if (confirmed) {
            jbm_onOpenSwitch();
            jbm_doSwitchServer(server);
        }
    });
}

/* Performs the server switch: locks the modal, posts the switch request, and
   reports the outcome on the status line. */
function jbm_doSwitchServer(server) {
    jbm_switchingServer = true;
    var closeBtn = document.querySelector('#jbm-modal-switch .cc-dialog-close');
    if (closeBtn) closeBtn.classList.add('jbm-switch-locked');
    var btns = document.querySelectorAll('.jbm-switch-btn');
    for (var i = 0; i < btns.length; i++) btns[i].disabled = true;
    jbm_setSwitchStatus('Switching to ' + server.replace('DM-PROD-', '') + '... May take up to 90 seconds.', 'working');

    cc_engineFetch('/api/jboss-monitoring/switch-server', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ target_server: server })
    }).then(function(d) {
        jbm_switchingServer = false;
        if (closeBtn) closeBtn.classList.remove('jbm-switch-locked');
        if (!d) { jbm_renderSwitchButtons(); return; }
        if (d.Error) { jbm_setSwitchStatus(d.Error, 'error'); jbm_renderSwitchButtons(); return; }
        jbm_activeServer = d.active_server;
        jbm_renderSwitchButtons();
        jbm_renderUsersBadge();
        jbm_setSwitchStatus('Switched to ' + d.active_server.replace('DM-PROD-', '') + ' by ' + d.performed_by, 'success');
    }).catch(function(e) {
        jbm_switchingServer = false;
        if (closeBtn) closeBtn.classList.remove('jbm-switch-locked');
        jbm_setSwitchStatus(e.message, 'error');
        jbm_renderSwitchButtons();
    });
}

/* Hides the switch modal (used after confirm, before the locked switch run). */
function jbm_closeSwitchModal() {
    if (jbm_switchingServer) return;
    document.getElementById('jbm-modal-switch').classList.add('cc-hidden');
}

/* Sets the switch status line text and severity class. */
function jbm_setSwitchStatus(msg, type) {
    var el = document.getElementById('jbm-switch-status');
    el.textContent = msg;
    el.className = 'jbm-switch-status' + (type ? ' jbm-switch-status-' + type : '');
}

/* ============================================================================
   FUNCTIONS: FORMAT HELPERS
   ----------------------------------------------------------------------------
   Number, compact-number, byte, and uptime formatters, plus the per-label
   delta and cumulative formatters and the timestamp updater.
   Prefix: jbm
   ============================================================================ */

/* Formats a number with thousands separators, or a dash when null. */
function jbm_fmtN(n) {
    if (n === null || n === undefined) return '-';
    return n.toLocaleString();
}

/* Formats a number compactly with K/M suffixes for large values. */
function jbm_fmtC(n) {
    if (n === null || n === undefined) return '-';
    if (n >= 1000000) return (n / 1000000).toFixed(1) + 'M';
    if (n >= 10000)   return (n / 1000).toFixed(0) + 'K';
    if (n >= 1000)    return (n / 1000).toFixed(1) + 'K';
    return n.toLocaleString();
}

/* Formats a byte count with B/KB/MB/GB units. */
function jbm_formatBytes(b) {
    if (b === null || b === undefined) return '-';
    if (b >= 1073741824) return (b / 1073741824).toFixed(1) + ' GB';
    if (b >= 1048576)    return (b / 1048576).toFixed(1) + ' MB';
    if (b >= 1024)       return (b / 1024).toFixed(0) + ' KB';
    return b + ' B';
}

/* Formats an uptime in hours as a days-and-hours string. */
function jbm_formatUptime(hours) {
    if (hours === null || hours === undefined) return '-';
    hours = Number(hours);
    if (isNaN(hours)) return '-';
    var d = Math.floor(hours / 24), r = Math.floor(hours % 24);
    return d > 0 ? d + 'd ' + r + 'h' : r + 'h';
}

/* Formats a delta value with units appropriate to its counter label. */
function jbm_fmtDelta(label, delta) {
    if (label === 'Data sent') return jbm_formatBytes(delta);
    if (label === 'Processing') return jbm_fmtN(delta) + ' ms';
    return jbm_fmtC(delta);
}

/* Formats a cumulative value with units appropriate to its counter label. */
function jbm_fmtCumulative(label, value) {
    if (label === 'Data sent') return jbm_formatBytes(value);
    if (label === 'Processing') return jbm_fmtC(value) + ' ms';
    return jbm_fmtC(value);
}

/* Updates the chrome last-update timestamp from an API timestamp. */
function jbm_updateTimestamp(ts) {
    var el = document.getElementById('cc-last-update');
    if (el && ts) el.textContent = ts;
}

/* ============================================================================
   FUNCTIONS: PAGE LIFECYCLE HOOKS
   ----------------------------------------------------------------------------
   The lifecycle callbacks cc-shared.js invokes: full refresh on manual refresh
   and on tab resume, and event-driven section refresh when the JBoss collector
   completes.
   Prefix: jbm
   ============================================================================ */

/* Refreshes all data when the user clicks the page refresh button. */
function jbm_onPageRefresh() {
    jbm_refreshAll();
}

/* Refreshes all data when the tab regains visibility. */
function jbm_onPageResumed() {
    jbm_refreshAll();
}

/* Refreshes the event-driven sections when the JBoss collector completes. */
function jbm_onEngineProcessCompleted(processName) {
    if (processName === 'Collect-JBossMetrics') jbm_refreshEventSections();
}

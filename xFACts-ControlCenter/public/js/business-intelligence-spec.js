/* ============================================================================
   xFACts Control Center - Business Intelligence JavaScript (business-intelligence.js)
   Location: E:\xFACts-ControlCenter\public\js\business-intelligence.js
   Version: Tracked in dbo.System_Metadata (component: DeptOps.BusinessIntelligence)

   Page-specific JS for the Business Intelligence departmental dashboard.
   Universal chrome (refresh button, idle detection, session expiry,
   visibility resume, formatting utilities) is provided by cc-shared.js.
   This file contains the Notice Recon tile: a row of clickable status
   badges (one per reconciliation process) backed by a daily executions
   feed, plus a detail slideout that surfaces the per-execution summary
   and step-by-step results when a badge is clicked. To enable a planned
   process, flip its 'active' flag in biz_NR_PROCESSES.

   FILE ORGANIZATION
   -----------------
   CONSTANTS: ENGINE PROCESSES
   CONSTANTS: PROCESS CONFIGURATION
   CONSTANTS: PAGE CONFIGURATION
   STATE: PAGE STATE
   INITIALIZATION: PAGE BOOT
   FUNCTIONS: REFRESH
   FUNCTIONS: NOTICE RECON
   FUNCTIONS: DETAIL SLIDEOUT
   FUNCTIONS: HELPERS
   FUNCTIONS: PAGE LIFECYCLE HOOKS
   ============================================================================ */


/* ============================================================================
   CONSTANTS: ENGINE PROCESSES
   ----------------------------------------------------------------------------
   The ENGINE_PROCESSES contract: a map from orchestrator process names to
   engine card slugs that cc-shared.js reads at startup. The Business
   Intelligence page does not subscribe to any orchestrator collectors,
   but still calls connectEngineEvents() to opt into the platform chrome
   behaviors (refresh button spin, idle pause, session expiry handling,
   visibility-resume refresh). Per JS spec section 7.4, the banner is
   required and the value is the empty object when the page has no
   collectors.
   Prefix: (none)
   ============================================================================ */

/* Empty engine process map. cc-shared.js reads this at startup; the
   empty value means no WebSocket subscriptions are wired up but the
   chrome behaviors (idle, visibility, session expiry, refresh button
   spin) still register. */
const ENGINE_PROCESSES = {};


/* ============================================================================
   CONSTANTS: PROCESS CONFIGURATION
   ----------------------------------------------------------------------------
   The Notice Recon process list. Each entry has a display name and an
   'active' flag. Inactive processes render as future-state placeholder
   badges; flipping the flag to true enables a process without any other
   code changes. Listed in display order, left-to-right.
   Prefix: biz
   ============================================================================ */

/* Notice Recon process configuration. Listed in display order. The
   'active' flag controls whether the badge renders normally or as a
   future-state placeholder; flip to true to enable a planned process. */
const biz_NR_PROCESSES = [
    { name: 'SndRight',   active: true  },
    { name: 'Revspring',  active: true  },
    { name: 'Validation', active: true  },
    { name: 'FAND',       active: false }
];


/* ============================================================================
   CONSTANTS: PAGE CONFIGURATION
   ----------------------------------------------------------------------------
   Module-level configuration constants for this page. The refresh
   interval default is overwritten at load time from GlobalConfig.
   Prefix: biz
   ============================================================================ */

/* Default auto-refresh interval in milliseconds. Overwritten at page
   load by biz_loadRefreshInterval from GlobalConfig (ControlCenter |
   refresh_business_intelligence_seconds). 60 seconds matches the
   cadence of the upstream Notice Recon collector. */
const biz_REFRESH_INTERVAL_DEFAULT = 60000;


/* ============================================================================
   STATE: PAGE STATE
   ----------------------------------------------------------------------------
   Module-scope mutable state for the Business Intelligence UI: the
   active refresh interval, the auto-refresh timer handle, and the two
   lookup caches that back the badge updater and the slideout. The
   caches are keyed two ways - by process name (for badge updates) and
   by execution id (for future slideout lookups by id) - and are
   rebuilt every time the executions feed is loaded.
   Prefix: biz
   ============================================================================ */

/* Effective auto-refresh interval in milliseconds. Starts at the
   default and is overwritten by biz_loadRefreshInterval if GlobalConfig
   has a value. */
var biz_refreshInterval = biz_REFRESH_INTERVAL_DEFAULT;

/* setInterval handle for the auto-refresh timer, or null when not
   running. */
var biz_refreshTimer = null;

/* Today's executions keyed by process_name. Used by biz_updateBadges
   to map a process to its current execution and by biz_openDetail
   when a badge is clicked. Rebuilt on every loadNoticeRecon. */
var biz_executionsByName = {};

/* Today's executions keyed by execution_id. Used by biz_openDetail
   when called with a numeric id (e.g. from a future deep-link or
   notification click). Rebuilt on every loadNoticeRecon. */
var biz_executionsById = {};


/* ============================================================================
   INITIALIZATION: PAGE BOOT
   ----------------------------------------------------------------------------
   Single DOMContentLoaded handler that paints the badge skeleton,
   registers the engine-events chrome with cc-shared.js, loads the
   refresh interval from GlobalConfig, runs the page's first data
   load, and wires the delegated click handler for the badges plus
   the document-level Escape key handler for the slideout.
   Prefix: (none)
   ============================================================================ */

document.addEventListener('DOMContentLoaded', function() {
    biz_renderBadgeSkeleton();
    connectEngineEvents();
    biz_loadRefreshInterval();
    biz_loadNoticeRecon();

    document.getElementById('nr-badges').addEventListener('click', biz_onBadgeClick);
    document.addEventListener('keydown', biz_onDocumentKeydown);
});


/* ============================================================================
   FUNCTIONS: REFRESH
   ----------------------------------------------------------------------------
   The page's refresh paths. Auto-refresh runs Notice Recon on a
   configurable interval; the manual refresh button (chrome from
   cc-shared.js) re-triggers Notice Recon via the onPageRefresh hook.
   Prefix: biz
   ============================================================================ */

/* Loads the page-specific refresh interval from GlobalConfig via the
   shared refresh-interval API. Starts the auto-refresh timer once the
   interval is known (or immediately at the default if the API is
   unavailable). */
function biz_loadRefreshInterval() {
    fetch('/api/config/refresh-interval?page=business_intelligence')
        .then(function(r) { return r.json(); })
        .then(function(data) {
            if (data && data.interval) {
                biz_refreshInterval = data.interval * 1000;
            }
            biz_startAutoRefresh();
        })
        .catch(function() { biz_startAutoRefresh(); });
}

/* Starts the auto-refresh timer. Reloads Notice Recon at the
   configured interval; replaces any prior timer so the call is
   idempotent. */
function biz_startAutoRefresh() {
    if (biz_refreshTimer) clearInterval(biz_refreshTimer);
    biz_refreshTimer = setInterval(function() {
        biz_loadNoticeRecon();
    }, biz_refreshInterval);
}


/* ============================================================================
   FUNCTIONS: NOTICE RECON
   ----------------------------------------------------------------------------
   The Notice Recon tile: a row of status badges, one per reconciliation
   process. The badge skeleton is painted once at boot so the tile has
   its final layout immediately; the executions feed updates the status
   class on each badge in place (no re-render means no flicker). A
   delegated click handler on the badge container opens the detail
   slideout for the clicked process.
   Prefix: biz
   ============================================================================ */

/* Loads the daily Notice Recon executions feed and updates the badge
   row. Hides the connection error banner on success; shows it on
   failure with the underlying error message. */
function biz_loadNoticeRecon() {
    fetch('/api/business-intelligence/notice-recon')
        .then(function(r) {
            if (!r.ok) throw new Error('HTTP ' + r.status);
            return r.json();
        })
        .then(function(data) {
            biz_hideConnectionError();
            biz_updateBadges(data.executions || []);
            biz_updateTimestamp();
        })
        .catch(function(err) {
            biz_showConnectionError('Failed to load Notice Recon data: ' + err.message);
        });
}

/* Renders the initial badge row with all processes in 'pending' state.
   Applied once at page boot so the tile has its final layout
   immediately, before the first API response arrives. Inactive
   processes render with the 'future' modifier class. */
function biz_renderBadgeSkeleton() {
    var container = document.getElementById('nr-badges');
    if (!container) return;

    var html = '';
    biz_NR_PROCESSES.forEach(function(p) {
        var extraClass = p.active ? '' : ' future';
        html += '<div class="nr-badge pending' + extraClass + '" '
              + 'data-process="' + biz_escAttr(p.name) + '">'
              + escapeHtml(p.name)
              + '</div>';
    });
    container.innerHTML = html;
}

/* Updates badge status classes from the executions feed. Rebuilds the
   two execution lookup caches as a side effect, then walks the badge
   row and applies each badge's current status class without
   re-rendering (in-place class swap = no flicker). */
function biz_updateBadges(executions) {
    biz_executionsByName = {};
    biz_executionsById = {};
    executions.forEach(function(ex) {
        biz_executionsByName[ex.process_name] = ex;
        biz_executionsById[ex.execution_id] = ex;
    });

    var container = document.getElementById('nr-badges');
    if (!container) return;

    biz_NR_PROCESSES.forEach(function(p) {
        var badge = container.querySelector('[data-process="' + biz_cssEscape(p.name) + '"]');
        if (!badge) return;

        var ex = biz_executionsByName[p.name];
        var statusClass = ex ? biz_getStatusClass(ex.status) : 'pending';

        badge.className = 'nr-badge ' + statusClass + (p.active ? '' : ' future');
    });
}

/* Delegated click handler for the badge row. Reads the clicked
   badge's data-process and opens the detail slideout for that
   process. */
function biz_onBadgeClick(event) {
    var badge = event.target.closest('.nr-badge');
    if (!badge) return;
    biz_openDetail(badge.dataset.process);
}


/* ============================================================================
   FUNCTIONS: DETAIL SLIDEOUT
   ----------------------------------------------------------------------------
   The execution detail slideout that opens when a badge is clicked.
   The slideout body shows a summary card (status, duration, record
   counts, start time) plus a per-step table that loads from a second
   endpoint. The Escape key listener on the document level closes the
   slideout from anywhere.
   Prefix: biz
   ============================================================================ */

/* Opens the execution detail slideout. Accepts either a process name
   (string, from a badge click) or an execution id (number, reserved
   for future use such as deep-links). For a process with no execution
   today, shows a "not yet run" or "not yet deployed" message
   depending on whether the process is active. */
function biz_openDetail(processNameOrId) {
    var ex = null;
    var processName = null;
    var procConfig = null;

    if (typeof processNameOrId === 'string') {
        processName = processNameOrId;
        ex = biz_executionsByName[processName] || null;
        procConfig = biz_NR_PROCESSES.filter(function(p) { return p.name === processName; })[0] || null;
    } else {
        ex = biz_executionsById[processNameOrId] || null;
        if (ex) processName = ex.process_name;
    }

    var title = document.getElementById('nr-detail-title');
    var content = document.getElementById('nr-detail-content');
    var overlay = document.getElementById('nr-detail-overlay');
    var panel = document.getElementById('nr-detail-panel');

    title.textContent = (processName || 'Notice Recon') + ' \u2014 Execution Detail';

    if (ex) {
        content.innerHTML = biz_renderSummary(ex)
            + '<div class="slideout-section">'
            + '<div class="slideout-section-title">Steps</div>'
            + '<div id="nr-detail-steps" class="loading">Loading steps...</div>'
            + '</div>';

        fetch('/api/business-intelligence/notice-recon-steps?execution_id=' + ex.execution_id)
            .then(function(r) {
                if (!r.ok) throw new Error('HTTP ' + r.status);
                return r.json();
            })
            .then(function(data) {
                biz_renderSteps(data.steps || []);
            })
            .catch(function(err) {
                var stepsEl = document.getElementById('nr-detail-steps');
                if (stepsEl) stepsEl.innerHTML = '<div class="slideout-empty">Failed to load steps: ' + escapeHtml(err.message) + '</div>';
            });
    } else {
        var message = (procConfig && !procConfig.active)
            ? 'This process has not yet been deployed.'
            : 'This process has not yet run today.';
        content.innerHTML = '<div class="slideout-empty">' + escapeHtml(message) + '</div>';
    }

    overlay.classList.add('open');
    panel.classList.add('open');
}

/* Closes the detail slideout. Wired up from the slideout overlay
   click and close button in BusinessIntelligence.ps1, and from the
   document-level Escape key handler. */
function biz_closeDetail() {
    var overlay = document.getElementById('nr-detail-overlay');
    var panel = document.getElementById('nr-detail-panel');
    if (overlay) overlay.classList.remove('open');
    if (panel) panel.classList.remove('open');
}

/* Renders the slideout summary header: a row of stat tiles showing
   the execution's status, duration, total records, DM update count,
   and start time. */
function biz_renderSummary(ex) {
    var statusClass = biz_getStatusClass(ex.status);
    var durationStr = ex.duration_seconds !== null ? biz_formatDuration(ex.duration_seconds) : '-';
    var timeStr = ex.start_time ? formatTimeOfDay(ex.start_time) : '-';

    return '<div class="slideout-summary">'
        + '<div class="slideout-stat">'
        + '<div class="slideout-stat-value"><span class="nr-status-pill ' + statusClass + '">' + escapeHtml(ex.status) + '</span></div>'
        + '<div class="slideout-stat-label">Status</div>'
        + '</div>'
        + '<div class="slideout-stat">'
        + '<div class="slideout-stat-value">' + durationStr + '</div>'
        + '<div class="slideout-stat-label">Duration</div>'
        + '</div>'
        + '<div class="slideout-stat">'
        + '<div class="slideout-stat-value">' + biz_formatNumber(ex.total_records) + '</div>'
        + '<div class="slideout-stat-label">Total Records</div>'
        + '</div>'
        + '<div class="slideout-stat">'
        + '<div class="slideout-stat-value">' + biz_formatNumber(ex.records_updated_dm) + '</div>'
        + '<div class="slideout-stat-label">DM Updates</div>'
        + '</div>'
        + '<div class="slideout-stat">'
        + '<div class="slideout-stat-value">' + timeStr + '</div>'
        + '<div class="slideout-stat-label">Start Time</div>'
        + '</div>'
        + '</div>';
}

/* Renders the per-step table inside the slideout. Each row shows the
   step number, name, status pill, duration, row count, and message;
   error messages render in red and supplant the regular message. */
function biz_renderSteps(steps) {
    var container = document.getElementById('nr-detail-steps');
    if (!container) return;

    if (steps.length === 0) {
        container.innerHTML = '<div class="slideout-empty">No steps found for this execution</div>';
        return;
    }

    container.classList.remove('loading');

    var html = '<table class="slideout-table">'
        + '<thead><tr>'
        + '<th>#</th><th>Step</th><th>Status</th><th>Duration</th><th class="align-right">Rows</th><th>Message</th>'
        + '</tr></thead><tbody>';

    steps.forEach(function(step) {
        var statusClass = biz_getStatusClass(step.status);
        var durationStr = step.duration_seconds > 0 ? step.duration_seconds + 's' : '<1s';
        var rowsStr = step.rows_affected !== null ? biz_formatNumber(step.rows_affected) : '-';
        var msgStr;
        if (step.error_message) {
            msgStr = '<span class="step-error-message">' + escapeHtml(step.error_message) + '</span>';
        } else {
            msgStr = escapeHtml(step.message || '');
        }

        html += '<tr>'
            + '<td>' + step.step_number + '</td>'
            + '<td>' + escapeHtml(step.step_name) + '</td>'
            + '<td><span class="nr-status-pill ' + statusClass + '">' + escapeHtml(step.status) + '</span></td>'
            + '<td>' + durationStr + '</td>'
            + '<td class="align-right">' + rowsStr + '</td>'
            + '<td>' + msgStr + '</td>'
            + '</tr>';
    });

    html += '</tbody></table>';
    container.innerHTML = html;
}

/* Document-level keydown handler. Closes the detail slideout on
   Escape; other keys are ignored. Bound at page boot so the slideout
   is dismissable from anywhere on the page. */
function biz_onDocumentKeydown(event) {
    if (event.key === 'Escape') biz_closeDetail();
}


/* ============================================================================
   FUNCTIONS: HELPERS
   ----------------------------------------------------------------------------
   Page-local display formatters and value-coercion utilities: status
   class mapping, duration / number formatting, attribute and CSS
   selector escaping, the page timestamp updater, and the connection
   error banner controls. The standard escapeHtml and formatTimeOfDay
   from cc-shared.js handle HTML escaping and time-of-day rendering;
   these helpers handle the per-page formats not covered by cc-shared.
   Prefix: biz
   ============================================================================ */

/* Maps a status string ("success", "warning", "error", "failed",
   "running") to a CSS class. Unknown or null statuses map to
   "pending". */
function biz_getStatusClass(status) {
    if (!status) return 'pending';
    switch (status.toLowerCase()) {
        case 'success': return 'success';
        case 'warning': return 'warning';
        case 'error':
        case 'failed':  return 'error';
        case 'running': return 'running';
        default:        return 'pending';
    }
}

/* Formats a duration in seconds as a short display string. Below 60
   seconds renders as "Xs"; above renders as "Mm Ss". */
function biz_formatDuration(seconds) {
    if (seconds < 60) return seconds + 's';
    var m = Math.floor(seconds / 60);
    var s = seconds % 60;
    return m + 'm ' + s + 's';
}

/* Formats a number with thousands separators. Returns "-" for null
   or undefined. */
function biz_formatNumber(n) {
    if (n === null || n === undefined) return '-';
    return n.toLocaleString();
}

/* Escapes a value for safe use inside an HTML attribute (between
   double quotes). Distinct from escapeHtml because attribute escaping
   needs to handle the quote character; HTML body escaping does not.
   Returns empty string for null or undefined. */
function biz_escAttr(str) {
    if (!str) return '';
    return String(str).replace(/&/g, '&amp;').replace(/"/g, '&quot;');
}

/* Escapes a value for safe use inside a querySelector attribute
   selector. Uses CSS.escape when available; falls back to a regex
   for older browsers. */
function biz_cssEscape(str) {
    if (window.CSS && typeof window.CSS.escape === 'function') {
        return window.CSS.escape(str);
    }
    return String(str).replace(/([^a-zA-Z0-9_-])/g, '\\$1');
}

/* Updates the live "last updated" timestamp display in the page
   header. Renders as "h:mm:ss AM/PM" with seconds for finer-grained
   freshness signal than the page-level formatTimeOfDay. */
function biz_updateTimestamp() {
    var el = document.getElementById('last-update');
    if (!el) return;

    var now = new Date();
    var h = now.getHours();
    var m = now.getMinutes();
    var s = now.getSeconds();
    var ampm = h >= 12 ? 'PM' : 'AM';
    h = h % 12 || 12;
    el.textContent = h + ':' + (m < 10 ? '0' : '') + m + ':' + (s < 10 ? '0' : '') + s + ' ' + ampm;
}

/* Shows the inline connection error banner with a message. The
   BusinessIntelligence.ps1 route still renders a 'connection-error'
   element; once the route is migrated to the cc-shared
   'connection-banner' element this helper will be removed in favor of
   cc-shared's updateConnectionBanner. */
function biz_showConnectionError(msg) {
    var el = document.getElementById('connection-error');
    if (!el) return;
    el.textContent = msg;
    el.style.display = 'block';
}

/* Hides the inline connection error banner. */
function biz_hideConnectionError() {
    var el = document.getElementById('connection-error');
    if (!el) return;
    el.style.display = 'none';
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
    biz_loadNoticeRecon();
}

/* Called by cc-shared.js when the page becomes visible again after
   being hidden. cc-shared.js drives the spin animation; this hook
   does the actual data reload so the user sees current data. */
function onPageResumed() {
    biz_loadNoticeRecon();
}

/* Called by cc-shared.js when the session is detected as expired.
   Stops the auto-refresh timer so we do not keep firing fetches that
   would just return the login page. */
function onSessionExpired() {
    if (biz_refreshTimer) {
        clearInterval(biz_refreshTimer);
        biz_refreshTimer = null;
    }
}

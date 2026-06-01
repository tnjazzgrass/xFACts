/* ============================================================================
   xFACts Control Center - Business Intelligence JavaScript (business-intelligence.js)
   Location: E:\xFACts-ControlCenter\public\js\business-intelligence.js
   Version: Tracked in dbo.System_Metadata (component: DeptOps.BusinessIntelligence)

   Page-specific JS for the Business Intelligence departmental dashboard.
   Universal chrome (refresh button, idle detection, session expiry,
   visibility resume, formatting utilities, connection banner) is provided
   by cc-shared.js. This file contains the Notice Recon tile: a row of
   clickable status badges (one per reconciliation process) backed by a
   daily executions feed, plus a detail slideout that surfaces the
   per-execution summary and step-by-step results when a badge is clicked.
   To enable a planned process, flip its 'active' flag in biz_NR_PROCESSES.

   FILE ORGANIZATION
   -----------------
   CONSTANTS: ENGINE PROCESSES
   CONSTANTS: ACTION DISPATCH TABLES
   CONSTANTS: PROCESS CONFIGURATION
   CONSTANTS: PAGE CONFIGURATION
   STATE: PAGE STATE
   FUNCTIONS: INITIALIZATION
   FUNCTIONS: REFRESH
   FUNCTIONS: NOTICE RECON
   FUNCTIONS: DETAIL SLIDEOUT
   FUNCTIONS: HELPERS
   FUNCTIONS: PAGE LIFECYCLE HOOKS
   ============================================================================ */

/* ============================================================================
   CONSTANTS: ENGINE PROCESSES
   ----------------------------------------------------------------------------
   The engine processes contract: a map from orchestrator process names to
   engine card slugs that cc-shared.js reads at startup. The Business
   Intelligence page does not subscribe to any orchestrator collectors, but
   still calls cc_connectEngineEvents() to opt into the platform chrome
   behaviors (refresh button spin, idle pause, session expiry handling,
   visibility-resume refresh, connection banner). The value is the empty
   object because the page has no engine cards.
   Prefix: biz
   ============================================================================ */

/* Empty engine process map. cc-shared.js reads this at startup; the empty
   value means no WebSocket subscriptions are wired up but the chrome
   behaviors (idle, visibility, session expiry, refresh button spin,
   connection banner) still register. */
var biz_ENGINE_PROCESSES = {};

/* ============================================================================
   CONSTANTS: ACTION DISPATCH TABLES
   ----------------------------------------------------------------------------
   Per-event dispatch tables connecting this page's data-action-<event>
   attribute values to handler functions. The bootloader registers the
   shared chrome listeners; biz_init registers one delegated listener per
   non-empty table below on document.body. Keys carry the biz- page prefix;
   values are bare handler references defined elsewhere in this file.
   Prefix: biz
   ============================================================================ */

/* Click-action dispatch table. Routes data-action-click values: a Notice
   Recon badge opens the execution detail slideout for its process; the
   slideout overlay and close button dismiss the slideout. */
const biz_clickActions = {
    'biz-open-detail':     biz_openDetail,
    'biz-close-detail':    biz_closeDetail
};

/* ============================================================================
   CONSTANTS: PROCESS CONFIGURATION
   ----------------------------------------------------------------------------
   The Notice Recon process list. Each entry has a display name and an
   'active' flag. Inactive processes render as future-state placeholder
   badges; flipping the flag to true enables a process without any other
   code changes. Listed in display order, left-to-right.
   Prefix: biz
   ============================================================================ */

/* Notice Recon process configuration. Listed in display order. The 'active'
   flag controls whether the badge renders normally or as a future-state
   placeholder; flip to true to enable a planned process. */
const biz_NR_PROCESSES = [
    { name: 'SndRight',   active: true  },
    { name: 'Revspring',  active: true  },
    { name: 'Validation', active: true  },
    { name: 'FAND',       active: false }
];

/* ============================================================================
   CONSTANTS: PAGE CONFIGURATION
   ----------------------------------------------------------------------------
   Module-level configuration constants for this page. The refresh interval
   default is overwritten at load time from GlobalConfig.
   Prefix: biz
   ============================================================================ */

/* Default auto-refresh interval in milliseconds. Overwritten at page load
   by biz_loadRefreshInterval from GlobalConfig (ControlCenter |
   refresh_business_intelligence_seconds). 60 seconds matches the cadence of
   the upstream Notice Recon collector. */
const biz_REFRESH_INTERVAL_DEFAULT = 60000;

/* ============================================================================
   STATE: PAGE STATE
   ----------------------------------------------------------------------------
   Module-scope mutable state for the Business Intelligence UI: the active
   refresh interval, the auto-refresh timer handle, and the two lookup caches
   that back the badge updater and the slideout. The caches are keyed two
   ways - by process name (for badge updates) and by execution id (for
   slideout lookups by id) - and are rebuilt every time the executions feed
   is loaded.
   Prefix: biz
   ============================================================================ */

/* Effective auto-refresh interval in milliseconds. Starts at the default and
   is overwritten by biz_loadRefreshInterval if GlobalConfig has a value. */
var biz_refreshInterval = biz_REFRESH_INTERVAL_DEFAULT;

/* setInterval handle for the auto-refresh timer, or null when not running. */
var biz_refreshTimer = null;

/* Today's executions keyed by process_name. Used by biz_updateBadges to map
   a process to its current execution and by biz_openDetail when a badge is
   clicked. Rebuilt on every biz_loadNoticeRecon. */
var biz_executionsByName = {};

/* Today's executions keyed by execution_id. Used by biz_openDetail when
   called with a numeric id. Rebuilt on every biz_loadNoticeRecon. */
var biz_executionsById = {};

/* ============================================================================
   FUNCTIONS: INITIALIZATION
   ----------------------------------------------------------------------------
   Page boot entry point invoked by the cc-shared.js bootloader after this
   module loads. Paints the badge skeleton, registers the engine-events
   chrome with cc-shared.js, loads the refresh interval, runs the first data
   load, registers the delegated click listener for page actions, and wires
   the document-level Escape key handler for the slideout.
   Prefix: biz
   ============================================================================ */

/* Page boot function. Called by the cc-shared.js bootloader by computed
   name (biz_init) after the page module loads. */
function biz_init() {
    biz_renderBadgeSkeleton();
    cc_connectEngineEvents();
    biz_loadRefreshInterval();
    biz_loadNoticeRecon();

    document.body.addEventListener('click', biz_handleClick);
    document.addEventListener('keydown', biz_onDocumentKeydown);
}

/* ============================================================================
   FUNCTIONS: REFRESH
   ----------------------------------------------------------------------------
   The page's refresh paths. Auto-refresh runs Notice Recon on a configurable
   interval; the manual refresh button (chrome from cc-shared.js) re-triggers
   Notice Recon via the biz_onPageRefresh hook.
   Prefix: biz
   ============================================================================ */

/* Loads the page-specific refresh interval from GlobalConfig via the shared
   refresh-interval API. Starts the auto-refresh timer once the interval is
   known (or immediately at the default if the API is unavailable). */
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

/* Starts the auto-refresh timer. Reloads Notice Recon at the configured
   interval; replaces any prior timer so the call is idempotent. */
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
   process. The badge skeleton is painted once at boot so the tile has its
   final layout immediately; the executions feed updates the status class on
   each badge in place (no re-render means no flicker). A delegated click
   handler on document.body opens the detail slideout for the clicked badge.
   Prefix: biz
   ============================================================================ */

/* Delegated click handler registered on document.body in biz_init. Looks up
   the clicked element's data-action-click value in biz_clickActions and
   invokes the matching handler with the matched element. Page-local actions
   only (biz- prefix); cc- actions are handled by the shared bootloader
   listener. */
function biz_handleClick(event) {
    var target = event.target.closest('[data-action-click]');
    if (!target) return;

    var action = target.getAttribute('data-action-click');
    if (!action || action.indexOf('biz-') !== 0) return;

    var handler = biz_clickActions[action];
    if (handler) handler(target, event);
}

/* Loads the daily Notice Recon executions feed and updates the badge row.
   Hides the page data-error strip on success; shows it on failure with the
   underlying error message. */
function biz_loadNoticeRecon() {
    fetch('/api/business-intelligence/notice-recon')
        .then(function(r) {
            if (!r.ok) throw new Error('HTTP ' + r.status);
            return r.json();
        })
        .then(function(data) {
            biz_hideError();
            biz_updateBadges(data.executions || []);
            biz_updateTimestamp();
        })
        .catch(function(err) {
            biz_showError('Failed to load Notice Recon data: ' + err.message);
        });
}

/* Renders the initial badge row with all processes in pending state. Applied
   once at page boot so the tile has its final layout immediately, before the
   first API response arrives. Inactive processes render with the future
   modifier class. Each badge carries the click action plus its process name
   as an argument attribute. */
function biz_renderBadgeSkeleton() {
    var container = document.getElementById('biz-nr-badges');
    if (!container) return;

    var html = '';
    biz_NR_PROCESSES.forEach(function(p) {
        var stateClass = p.active ? 'biz-nr-badge-pending' : 'biz-nr-badge-future';
        html += '<div class="biz-nr-badge ' + stateClass + '" '
              + 'data-action-click="biz-open-detail" '
              + 'data-action-biz-process="' + biz_escAttr(p.name) + '">'
              + cc_escapeHtml(p.name)
              + '</div>';
    });
    container.innerHTML = html;
}

/* Updates badge status classes from the executions feed. Rebuilds the two
   execution lookup caches as a side effect, then walks the badge row and
   applies each badge's current status class without re-rendering (in-place
   class swap = no flicker). */
function biz_updateBadges(executions) {
    biz_executionsByName = {};
    biz_executionsById = {};
    executions.forEach(function(ex) {
        biz_executionsByName[ex.process_name] = ex;
        biz_executionsById[ex.execution_id] = ex;
    });

    var container = document.getElementById('biz-nr-badges');
    if (!container) return;

    biz_NR_PROCESSES.forEach(function(p) {
        var badge = container.querySelector('[data-action-biz-process="' + biz_cssEscape(p.name) + '"]');
        if (!badge) return;

        var ex = biz_executionsByName[p.name];
        var stateClass = ex ? biz_getStatusClass(ex.status) : 'biz-nr-badge-pending';
        if (!p.active) stateClass = 'biz-nr-badge-future';

        badge.className = 'biz-nr-badge ' + stateClass;
        badge.setAttribute('data-action-click', 'biz-open-detail');
        badge.setAttribute('data-action-biz-process', p.name);
    });
}

/* ============================================================================
   FUNCTIONS: DETAIL SLIDEOUT
   ----------------------------------------------------------------------------
   The execution detail slideout that opens when a badge is clicked. The
   slideout body shows a summary card (status, duration, record counts, start
   time) plus a per-step table that loads from a second endpoint. The Escape
   key listener on the document level closes the slideout from anywhere. The
   open/close handlers follow the shared static slide-overlay pattern.
   Prefix: biz
   ============================================================================ */

/* Opens the execution detail slideout for a clicked badge. The dispatcher
   passes the badge element; the process name is read from its argument
   attribute. For a process with no execution today, shows a "not yet run" or
   "not yet deployed" message depending on whether the process is active. */
function biz_openDetail(target) {
    var processName = target.getAttribute('data-action-biz-process');
    var ex = biz_executionsByName[processName] || null;
    var procConfig = biz_NR_PROCESSES.filter(function(p) { return p.name === processName; })[0] || null;

    var title = document.getElementById('biz-nr-detail-title');
    var content = document.getElementById('biz-nr-detail-content');

    title.textContent = (processName || 'Notice Recon') + ' \u2014 Execution Detail';

    if (ex) {
        content.innerHTML = biz_renderSummary(ex)
            + '<div class="cc-slide-section">'
            + '<div class="cc-slide-section-title">Steps</div>'
            + '<div id="biz-nr-detail-steps" class="cc-slide-empty">Loading steps\u2026</div>'
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
                var stepsEl = document.getElementById('biz-nr-detail-steps');
                if (stepsEl) stepsEl.innerHTML = '<div class="cc-slide-empty">Failed to load steps: ' + cc_escapeHtml(err.message) + '</div>';
            });
    } else {
        var message = (procConfig && !procConfig.active)
            ? 'This process has not yet been deployed.'
            : 'This process has not yet run today.';
        content.innerHTML = '<div class="cc-slide-empty">' + cc_escapeHtml(message) + '</div>';
    }

    biz_showDetail();
}

/* Opens the slideout via the shared static slide-overlay pattern: add cc-open
   to the overlay, then add cc-open to the inner dialog inside a
   requestAnimationFrame so the transition runs. */
function biz_showDetail() {
    var overlay = document.getElementById('biz-nr-detail-overlay');
    var dialog = overlay.querySelector('.cc-dialog');
    overlay.classList.add('cc-open');
    requestAnimationFrame(function() {
        dialog.classList.add('cc-open');
    });
}

/* Closes the detail slideout via the shared static slide-overlay pattern:
   attach a one-shot transitionend listener on the inner dialog that removes
   cc-open from the overlay, then remove cc-open from the dialog. Wired from
   the overlay click, the close button, and the document-level Escape key.
   The dialog is nested inside the overlay, so a click that originated inside
   the dialog body (not the close button) is ignored to avoid dismissing the
   panel when the user interacts with its content. */
function biz_closeDetail(target, event) {
    var overlay = document.getElementById('biz-nr-detail-overlay');
    var dialog = overlay.querySelector('.cc-dialog');
    if (event) {
        var onCloseButton = event.target.closest('.cc-dialog-close');
        var insideDialog = dialog.contains(event.target);
        if (insideDialog && !onCloseButton) return;
    }
    dialog.addEventListener('transitionend', function handler() {
        dialog.removeEventListener('transitionend', handler);
        overlay.classList.remove('cc-open');
    });
    dialog.classList.remove('cc-open');
}

/* Renders the slideout summary header: a row of stat tiles showing the
   execution's status, duration, total records, DM update count, and start
   time. */
function biz_renderSummary(ex) {
    var statusClass = biz_getStatusClass(ex.status);
    var durationStr = ex.duration_seconds !== null ? biz_formatDuration(ex.duration_seconds) : '-';
    var timeStr = ex.start_time ? cc_formatTimeOfDay(ex.start_time) : '-';

    return '<div class="cc-slide-summary">'
        + '<div class="cc-slide-stat">'
        + '<div class="cc-slide-stat-value"><span class="biz-nr-status-pill ' + biz_getPillClass(ex.status) + '">' + cc_escapeHtml(ex.status) + '</span></div>'
        + '<div class="cc-slide-stat-label">Status</div>'
        + '</div>'
        + '<div class="cc-slide-stat">'
        + '<div class="cc-slide-stat-value">' + durationStr + '</div>'
        + '<div class="cc-slide-stat-label">Duration</div>'
        + '</div>'
        + '<div class="cc-slide-stat">'
        + '<div class="cc-slide-stat-value">' + biz_formatNumber(ex.total_records) + '</div>'
        + '<div class="cc-slide-stat-label">Total Records</div>'
        + '</div>'
        + '<div class="cc-slide-stat">'
        + '<div class="cc-slide-stat-value">' + biz_formatNumber(ex.records_updated_dm) + '</div>'
        + '<div class="cc-slide-stat-label">DM Updates</div>'
        + '</div>'
        + '<div class="cc-slide-stat">'
        + '<div class="cc-slide-stat-value">' + timeStr + '</div>'
        + '<div class="cc-slide-stat-label">Start Time</div>'
        + '</div>'
        + '</div>';
}

/* Renders the per-step table inside the slideout. Each row shows the step
   number, name, status pill, duration, row count, and message; error
   messages render in the error style and supplant the regular message. */
function biz_renderSteps(steps) {
    var container = document.getElementById('biz-nr-detail-steps');
    if (!container) return;

    if (steps.length === 0) {
        container.innerHTML = '<div class="cc-slide-empty">No steps found for this execution</div>';
        return;
    }

    container.classList.remove('cc-slide-empty');

    var html = '<table class="cc-slide-table">'
        + '<thead><tr>'
        + '<th class="cc-slide-table-th">#</th>'
        + '<th class="cc-slide-table-th">Step</th>'
        + '<th class="cc-slide-table-th">Status</th>'
        + '<th class="cc-slide-table-th">Duration</th>'
        + '<th class="cc-slide-table-th cc-align-right">Rows</th>'
        + '<th class="cc-slide-table-th">Message</th>'
        + '</tr></thead><tbody>';

    steps.forEach(function(step) {
        var durationStr = step.duration_seconds > 0 ? step.duration_seconds + 's' : '<1s';
        var rowsStr = step.rows_affected !== null ? biz_formatNumber(step.rows_affected) : '-';
        var msgStr;
        if (step.error_message) {
            msgStr = '<span class="biz-nr-step-error">' + cc_escapeHtml(step.error_message) + '</span>';
        } else {
            msgStr = cc_escapeHtml(step.message || '');
        }

        html += '<tr>'
            + '<td class="cc-slide-table-td">' + step.step_number + '</td>'
            + '<td class="cc-slide-table-td">' + cc_escapeHtml(step.step_name) + '</td>'
            + '<td class="cc-slide-table-td"><span class="biz-nr-status-pill ' + biz_getPillClass(step.status) + '">' + cc_escapeHtml(step.status) + '</span></td>'
            + '<td class="cc-slide-table-td">' + durationStr + '</td>'
            + '<td class="cc-slide-table-td cc-align-right">' + rowsStr + '</td>'
            + '<td class="cc-slide-table-td">' + msgStr + '</td>'
            + '</tr>';
    });

    html += '</tbody></table>';
    container.innerHTML = html;
}

/* Document-level keydown handler. Closes the detail slideout on Escape; other
   keys are ignored. Bound at page boot so the slideout is dismissable from
   anywhere on the page. */
function biz_onDocumentKeydown(event) {
    if (event.key === 'Escape') biz_closeDetail();
}

/* ============================================================================
   FUNCTIONS: HELPERS
   ----------------------------------------------------------------------------
   Page-local display formatters, value-coercion utilities, the page
   timestamp updater, and the page data-error strip controls. The shared
   cc_escapeHtml and cc_formatTimeOfDay from
   cc-shared.js handle HTML escaping and time-of-day rendering; these helpers
   handle the per-page formats not covered by cc-shared.
   Prefix: biz
   ============================================================================ */

/* Maps a status string to the badge state class (success, warning, error,
   running). Unknown or null statuses map to pending. */
function biz_getStatusClass(status) {
    return 'biz-nr-badge-' + biz_statusToken(status);
}

/* Maps a status string to the status-pill state class. Shares the token
   mapping with biz_getStatusClass. */
function biz_getPillClass(status) {
    return 'biz-nr-status-pill-' + biz_statusToken(status);
}

/* Maps a status string ("success", "warning", "error", "failed", "running")
   to a state token. Unknown or null statuses map to "pending". */
function biz_statusToken(status) {
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

/* Formats a duration in seconds as a short display string. Below 60 seconds
   renders as "Xs"; above renders as "Mm Ss". */
function biz_formatDuration(seconds) {
    if (seconds < 60) return seconds + 's';
    var m = Math.floor(seconds / 60);
    var s = seconds % 60;
    return m + 'm ' + s + 's';
}

/* Formats a number with thousands separators. Returns "-" for null or
   undefined. */
function biz_formatNumber(n) {
    if (n === null || n === undefined) return '-';
    return n.toLocaleString();
}

/* Escapes a value for safe use inside an HTML attribute (between double
   quotes). Distinct from cc_escapeHtml because attribute escaping needs to
   handle the quote character. Returns empty string for null or undefined. */
function biz_escAttr(str) {
    if (!str) return '';
    return String(str).replace(/&/g, '&amp;').replace(/"/g, '&quot;');
}

/* Escapes a value for safe use inside a querySelector attribute selector.
   Uses CSS.escape when available; falls back to a regex for older
   browsers. */
function biz_cssEscape(str) {
    if (window.CSS && typeof window.CSS.escape === 'function') {
        return window.CSS.escape(str);
    }
    return String(str).replace(/([^a-zA-Z0-9_-])/g, '\\$1');
}

/* Updates the live "last updated" timestamp display in the page header.
   Renders as "h:mm:ss AM/PM" with seconds for a finer-grained freshness
   signal than the page-level cc_formatTimeOfDay. */
function biz_updateTimestamp() {
    var el = document.getElementById('cc-last-update');
    if (!el) return;

    var now = new Date();
    var h = now.getHours();
    var m = now.getMinutes();
    var s = now.getSeconds();
    var ampm = h >= 12 ? 'PM' : 'AM';
    h = h % 12 || 12;
    el.textContent = h + ':' + (m < 10 ? '0' : '') + m + ':' + (s < 10 ? '0' : '') + s + ' ' + ampm;
}

/* Shows the page-local data-error strip with a message. This strip reports a
   Notice Recon data-fetch failure; it is distinct from the shared connection
   banner, which reflects WebSocket lifecycle state. */
function biz_showError(msg) {
    var el = document.getElementById('biz-nr-error');
    if (!el) return;
    el.textContent = msg;
    el.classList.add('biz-nr-error-visible');
}

/* Hides the page-local data-error strip. */
function biz_hideError() {
    var el = document.getElementById('biz-nr-error');
    if (!el) return;
    el.textContent = '';
    el.classList.remove('biz-nr-error-visible');
}

/* ============================================================================
   FUNCTIONS: PAGE LIFECYCLE HOOKS
   ----------------------------------------------------------------------------
   Hooks invoked by cc-shared.js by computed name (biz_<hookSuffix>). The
   shared module resolves these on the window object and calls them at the
   appropriate moment in the page lifecycle.
   Prefix: biz
   ============================================================================ */

/* Called by cc-shared.js when the user clicks the page refresh button.
   cc-shared.js drives the spin animation; this hook does the actual data
   reload. */
function biz_onPageRefresh() {
    biz_loadNoticeRecon();
}

/* Called by cc-shared.js when the page becomes visible again after being
   hidden. cc-shared.js drives the spin animation; this hook does the actual
   data reload so the user sees current data. */
function biz_onPageResumed() {
    biz_loadNoticeRecon();
}

/* Called by cc-shared.js when the session is detected as expired. Stops the
   auto-refresh timer so we do not keep firing fetches that would just return
   the login page. */
function biz_onSessionExpired() {
    if (biz_refreshTimer) {
        clearInterval(biz_refreshTimer);
        biz_refreshTimer = null;
    }
}

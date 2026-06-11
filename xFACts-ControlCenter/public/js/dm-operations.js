/* ============================================================================
   xFACts Control Center - DM Operations (dm-operations.js)
   Location: E:\xFACts-ControlCenter\public\js\dm-operations.js
   Version: Tracked in dbo.System_Metadata (component: DmOps)

   Page module for the DM Operations dashboard. Loaded by the cc-shared.js
   bootloader, which invokes dmo_init after the module loads. Renders the
   lifetime totals, per-process Today stats, and the year/month/day execution
   history accordion; drives the batch-detail slideout, the click-and-drag
   schedule modal, and the admin control cluster (schedule / abort / launch)
   shown when the API reports the user may manage the process. Consumes the
   shared fetch wrapper, formatting helpers, name lookups, and styled modals
   from cc-shared.js.

   FILE ORGANIZATION
   -----------------
   CONSTANTS: ENGINE PROCESSES
   CONSTANTS: DISPATCH TABLES
   CONSTANTS: DISPLAY LOOKUPS
   STATE: LIFECYCLE
   STATE: HISTORY EXPANSION
   STATE: SCHEDULE DRAG
   FUNCTIONS: INITIALIZATION
   FUNCTIONS: ACTION DISPATCH
   FUNCTIONS: FORMATTING UTILITIES
   FUNCTIONS: BADGE BUILDERS
   FUNCTIONS: DATA LOADING
   FUNCTIONS: TARGET SERVER BADGES
   FUNCTIONS: ADMIN CONTROLS
   FUNCTIONS: TOTALS RENDERING
   FUNCTIONS: TODAY RENDERING
   FUNCTIONS: EXECUTION HISTORY RENDERING
   FUNCTIONS: BATCH DRILL-DOWN
   FUNCTIONS: BATCH DETAIL SLIDEOUT
   FUNCTIONS: SCHEDULE MODAL
   FUNCTIONS: SCHEDULE DRAG
   FUNCTIONS: ABORT AND LAUNCH
   FUNCTIONS: REFRESH AND POLLING
   FUNCTIONS: PAGE LIFECYCLE HOOKS
   ============================================================================ */

/* ============================================================================
   CONSTANTS: ENGINE PROCESSES
   ----------------------------------------------------------------------------
   Maps the Orchestrator.ProcessRegistry process names to their engine-card
   slugs for the shared engine-indicator system in cc-shared.js. The slugs
   match Orchestrator.ProcessRegistry.cc_engine_slug (archive, shell).
   Prefix: dmo
   ============================================================================ */

/* Engine-card process map consumed by the cc-shared.js engine indicator
   system. Keys are ProcessRegistry process names; slugs match cc_engine_slug. */
const dmo_ENGINE_PROCESSES = {
    'Execute-DmConsumerArchive': { slug: 'archive' },
    'Execute-DmShellPurge':      { slug: 'shell' }
};

/* ============================================================================
   CONSTANTS: DISPATCH TABLES
   ----------------------------------------------------------------------------
   Maps the page's data-action-click values to handler functions. Routed by
   dmo_handleClick, which is registered as a delegated listener on
   document.body in dmo_init. Keys carry the dmo- page prefix.
   Prefix: dmo
   ============================================================================ */

/* Click-action dispatch table. Keys match data-action-click values emitted in
   the page route markup and in JS-rendered markup; values are handlers. */
const dmo_clickActions = {
    'dmo-open-schedule':         dmo_openScheduleModal,
    'dmo-close-schedule':        dmo_closeScheduleModal,
    'dmo-set-paint-mode':        dmo_setSchedulePaintMode,
    'dmo-toggle-abort':          dmo_toggleAbort,
    'dmo-open-launch':           dmo_openLaunchModal,
    'dmo-close-launch':          dmo_closeLaunchModal,
    'dmo-confirm-launch':        dmo_confirmLaunch,
    'dmo-toggle-history':        dmo_toggleHistorySection,
    'dmo-toggle-day-batches':    dmo_toggleDayBatches,
    'dmo-open-batch-detail':     dmo_openBatchDetail,
    'dmo-close-batch-detail':    dmo_closeBatchDetail,
    'dmo-sort-batch-detail':     dmo_sortBatchDetail,
    'dmo-set-archive-filter':    dmo_setArchiveFilter,
    'dmo-set-history-filter':    dmo_setHistoryFilter
};

/* ============================================================================
   CONSTANTS: DISPLAY LOOKUPS
   ----------------------------------------------------------------------------
   Page-local display constants. Day-of-week ordering for the schedule grid
   (Sunday first, matching the 1-indexed database day_of_week). Month and day
   names come from cc-shared.js (cc_MONTH_NAMES / cc_DAY_NAMES).
   Prefix: dmo
   ============================================================================ */

/* Day-of-week render order for the schedule grid, 1-indexed Sunday-first to
   match the database day_of_week column. */
const dmo_DAY_ORDER = [1, 2, 3, 4, 5, 6, 7];

/* Schedule grid value-to-state-class map (0=blocked, 1=full, 2=reduced). */
const dmo_CELL_CLASS = { 0: 'dmo-blocked', 1: 'dmo-full', 2: 'dmo-reduced' };

/* Schedule grid value-to-label map (0=blocked, 1=full, 2=reduced). */
const dmo_CELL_LABEL = { 0: 'Blocked', 1: 'Full', 2: 'Reduced' };

/* Live polling interval in seconds; overwritten by the configured value on
   load when GlobalConfig supplies one. */
const dmo_DEFAULT_REFRESH_SECONDS = 30;

/* ============================================================================
   STATE: LIFECYCLE
   ----------------------------------------------------------------------------
   Mutable runtime state backing the page's polling lifecycle, the per-process
   abort flags, and the per-process launch capability reported by the API.
   Prefix: dmo
   ============================================================================ */

/* The live polling interval handle; null when polling is stopped. */
var dmo_livePollingTimer = null;

/* The active live polling interval in seconds. */
var dmo_refreshSeconds = 30;

/* The date the page was loaded; compared on refresh to force a reload across
   a midnight rollover so day-scoped views stay current. */
var dmo_pageLoadDate = new Date().toDateString();

/* Consecutive fetch-failure count; drives the connection-error message after
   repeated failures. */
var dmo_consecutiveErrors = 0;

/* Current abort-flag state per process, keyed by API process key. */
var dmo_abortState = { archive: false, shellpurge: false };

/* Whether the current user may launch processes, reported per process by the
   lifetime-totals API (same value on both; admin is per-user). */
var dmo_canLaunch = false;

/* Current Archive totals line-of-business filter (ALL, WFAARCH1, WFAARCH3). */
var dmo_currentArchiveFilter = 'ALL';

/* Current Archive history line-of-business filter (ALL, WFAARCH1, WFAARCH3).
   Independent of the totals filter; scopes the history section via refetch. */
var dmo_currentHistoryFilter = 'ALL';

/* Last lifetime-totals payload, retained so the Archive filter re-renders
   without refetch. */
var dmo_lastLifetimeData = null;

/* ============================================================================
   STATE: HISTORY EXPANSION
   ----------------------------------------------------------------------------
   Tracks which execution-history accordion sections are expanded so the state
   survives a refresh, plus a per-day batch-list cache to avoid re-fetching an
   already-loaded day after a refresh.
   Prefix: dmo
   ============================================================================ */

/* Expanded-accordion-section flags keyed by section key; survives refreshes. */
var dmo_expandedSections = {};

/* Per-day batch lists keyed by 'arch-batches-YYYY-MM-DD' or
   'shell-batches-YYYY-MM-DD'; repopulates inner tables without re-fetching. */
var dmo_dayBatchCache = {};

/* ============================================================================
   STATE: SCHEDULE DRAG
   ----------------------------------------------------------------------------
   Mutable state for the click-and-drag schedule editor: which process is open,
   whether a drag is in progress, the cells under the active drag selection,
   and the paint value being applied.
   Prefix: dmo
   ============================================================================ */

/* The API process key whose schedule is open in the modal; null when closed. */
var dmo_currentScheduleProcess = null;

/* Whether a schedule-cell drag selection is currently in progress. */
var dmo_isDragging = false;

/* The cells collected in the active drag selection. */
var dmo_dragSelectedCells = [];

/* The paint value (0/1/2) being applied by the active drag. */
var dmo_dragPaintValue = 1;

/* ============================================================================
   FUNCTIONS: INITIALIZATION
   ----------------------------------------------------------------------------
   The page boot function invoked by the cc-shared.js bootloader after this
   module loads. Registers the page's delegated listeners, performs the
   initial data load, connects engine events, and starts polling.
   Prefix: dmo
   ============================================================================ */

/* Page boot entry point invoked by cc-shared.js after the module loads. */
function dmo_init() {
    /* Register the delegated click dispatcher for the page's actions. */
    document.body.addEventListener('click', dmo_handleClick);

    /* Document-level mouse listeners drive the schedule-grid drag selection.
       Document-level binding is permitted for delegation; the grid is rendered
       dynamically each time the modal opens, so per-cell binding is avoided. */
    document.addEventListener('mousedown', dmo_handleScheduleMouseDown);
    document.addEventListener('mouseover', dmo_handleScheduleMouseOver);
    document.addEventListener('mouseup', dmo_handleScheduleMouseUp);

    /* Initial data load and one-shot target-server badge load. */
    dmo_refreshAll();
    dmo_loadTargetServers();

    /* Connect engine events via the shared module (also wires engine-card
       clicks at the document level inside cc-shared.js). */
    cc_connectEngineEvents();

    /* Start live polling. */
    dmo_startPolling();
}

/* ============================================================================
   FUNCTIONS: ACTION DISPATCH
   ----------------------------------------------------------------------------
   The delegated click dispatcher that routes the page's data-action-click
   values to their handler functions via the dmo_clickActions table.
   Registered on document.body in dmo_init.
   Prefix: dmo
   ============================================================================ */

/* Delegated click dispatcher. Resolves the nearest element carrying a
   data-action-click attribute and routes dmo- actions to their handlers. */
function dmo_handleClick(event) {
    var target = event.target.closest('[data-action-click]');
    if (!target) {
        return;
    }
    var action = target.getAttribute('data-action-click');
    if (!action || action.indexOf('dmo-') !== 0) {
        return;
    }
    var handler = dmo_clickActions[action];
    if (handler) {
        handler(target, event);
    }
}

/* ============================================================================
   FUNCTIONS: FORMATTING UTILITIES
   ----------------------------------------------------------------------------
   Number, duration, and time formatting helpers used across the renderers,
   plus the schedule grid's value-to-class/label/hour-label converters. HTML
   escaping and month/day name lookups come from cc-shared.js.
   Prefix: dmo
   ============================================================================ */

/* Formats a number with thousands separators; returns a dash for null. */
function dmo_formatNumber(num) {
    if (num === null || num === undefined) {
        return '-';
    }
    return num.toLocaleString();
}

/* Formats a duration in seconds as a compact h/m/s string. */
function dmo_formatDuration(seconds) {
    if (seconds === null || seconds === undefined || seconds === 0) {
        return '-';
    }
    if (seconds < 60) {
        return Math.round(seconds) + 's';
    }
    if (seconds < 3600) {
        var mins = Math.floor(seconds / 60);
        var secs = Math.round(seconds % 60);
        return mins + 'm ' + secs + 's';
    }
    var hours = Math.floor(seconds / 3600);
    var hmins = Math.floor((seconds % 3600) / 60);
    return hours + 'h ' + hmins + 'm';
}

/* Formats a millisecond duration by delegating to dmo_formatDuration. */
function dmo_formatMs(ms) {
    if (ms === null || ms === undefined) {
        return '-';
    }
    return dmo_formatDuration(ms / 1000);
}

/* Extracts the time portion from a 'YYYY-MM-DD HH:mm:ss' timestamp. */
function dmo_formatTimeOnly(dttm) {
    if (!dttm) {
        return '-';
    }
    var parts = dttm.split(' ');
    return parts.length > 1 ? parts[1] : dttm;
}

/* Formats an hour (0-23) as a compact 12-hour label with a/p suffix. */
function dmo_formatHour(h) {
    if (h === 0) {
        return '12a';
    }
    if (h < 12) {
        return h + 'a';
    }
    if (h === 12) {
        return '12p';
    }
    return (h - 12) + 'p';
}

/* Returns the schedule-cell state class for a cell value (0/1/2). */
function dmo_cellClass(value) {
    return dmo_CELL_CLASS[value] || dmo_CELL_CLASS[0];
}

/* Returns the schedule-cell human label for a cell value (0/1/2). */
function dmo_cellLabel(value) {
    return dmo_CELL_LABEL[value] || dmo_CELL_LABEL[0];
}

/* ============================================================================
   FUNCTIONS: BADGE BUILDERS
   ----------------------------------------------------------------------------
   Build the inline status, BIDATA, and schedule-mode pill badges, plus the
   colored delete-order prefix chip. All emit dmo- prefixed classes and escape
   their text via cc_escapeHtml.
   Prefix: dmo
   ============================================================================ */

/* Builds a status pill badge with the appropriate state class. */
function dmo_statusBadge(status) {
    if (!status) {
        return '<span class="dmo-status-badge dmo-unknown">-</span>';
    }
    var cls = 'dmo-status-badge';
    var s = status.toLowerCase();
    if (s === 'success') {
        cls += ' dmo-success';
    } else if (s === 'failed' || s === 'error') {
        cls += ' dmo-failed';
    } else if (s === 'skipped') {
        cls += ' dmo-skipped';
    } else if (s === 'running' || s === 'in progress' || s === 'inprogress') {
        cls += ' dmo-running';
    } else {
        cls += ' dmo-unknown';
    }
    return '<span class="' + cls + '">' + cc_escapeHtml(status) + '</span>';
}

/* Builds a BIDATA migration-status pill badge with the appropriate state class. */
function dmo_bidataBadge(status) {
    if (!status) {
        return '<span class="dmo-bidata-badge dmo-unknown">-</span>';
    }
    var cls = 'dmo-bidata-badge';
    var s = status.toLowerCase();
    if (s === 'success') {
        cls += ' dmo-success';
    } else if (s === 'failed') {
        cls += ' dmo-failed';
    } else if (s === 'skipped') {
        cls += ' dmo-skipped';
    } else if (s === 'running' || s === 'in progress' || s === 'inprogress') {
        cls += ' dmo-running';
    } else {
        cls += ' dmo-unknown';
    }
    return '<span class="' + cls + '">' + cc_escapeHtml(status) + '</span>';
}

/* Builds a schedule-mode pill badge with the appropriate state class. */
function dmo_modeBadge(mode) {
    if (!mode) {
        return '<span class="dmo-mode-badge dmo-unknown">-</span>';
    }
    var cls = 'dmo-mode-badge';
    var m = mode.toLowerCase();
    if (m === 'full') {
        cls += ' dmo-full';
    } else if (m === 'reduced') {
        cls += ' dmo-reduced';
    } else if (m === 'manual') {
        cls += ' dmo-manual';
    } else if (m === 'retry') {
        cls += ' dmo-retry';
    } else {
        cls += ' dmo-unknown';
    }
    return '<span class="' + cls + '">' + cc_escapeHtml(mode) + '</span>';
}

/* Builds a line-of-business badge (1P / 3P) from the batch's source workgroup. */
function dmo_workgroupBadge(workgroup) {
    if (workgroup === 'WFAARCH1') {
        return '<span class="dmo-wg-badge dmo-wg-1p">1P</span>';
    }
    if (workgroup === 'WFAARCH3') {
        return '<span class="dmo-wg-badge dmo-wg-3p">3P</span>';
    }
    return '<span class="dmo-wg-badge dmo-unknown">-</span>';
}

/* Builds the colored delete-order prefix chip (A/AU/AB/C/CU) plus the
   remaining order text. */
function dmo_deleteOrderHtml(deleteOrder) {
    if (!deleteOrder) {
        return '';
    }
    var prefix = '';
    var rest = deleteOrder;
    var m = deleteOrder.match(/^(AU|CU|AB|A|C)(.*)$/);
    if (m) {
        prefix = m[1];
        rest = m[2];
    }
    var cls = 'dmo-order-prefix dmo-order-' + prefix.toLowerCase();
    return '<span class="' + cls + '">' + cc_escapeHtml(prefix) + '</span>' + cc_escapeHtml(rest);
}

/* ============================================================================
   FUNCTIONS: DATA LOADING
   ----------------------------------------------------------------------------
   Fetches each section's data via the shared fetch wrapper and routes the
   result to its renderer. The lifetime-totals loader also captures the
   per-process abort and launch-capability flags that drive the admin controls.
   Prefix: dmo
   ============================================================================ */

/* Loads the per-process lifetime totals and updates abort/launch state. */
async function dmo_loadLifetimeTotals() {
    try {
        var data = await cc_engineFetch('/api/dmops/lifetime-totals');
        if (!data) {
            return;
        }

        dmo_abortState.archive = data.Archive.Aborted;
        dmo_abortState.shellpurge = data.ShellPurge.Aborted;
        dmo_canLaunch = data.Archive.CanLaunch;

        dmo_lastLifetimeData = data;
        dmo_renderArchiveTotals(data);
        dmo_renderShellTotals(data);
        dmo_renderAdminControls('archive');
        dmo_renderAdminControls('shellpurge');
        dmo_consecutiveErrors = 0;
    } catch (error) {
        dmo_consecutiveErrors++;
        console.error('Failed to load lifetime totals:', error);
        if (dmo_consecutiveErrors >= 3) {
            var archEl = document.getElementById('dmo-archive-totals');
            var shellEl = document.getElementById('dmo-shell-totals');
            if (archEl)  { archEl.innerHTML  = '<div class="cc-slide-empty">Unable to connect to server</div>'; }
            if (shellEl) { shellEl.innerHTML = '<div class="cc-slide-empty">Unable to connect to server</div>'; }
        }
    }
}

/* Loads today's per-process running totals. */
async function dmo_loadToday() {
    try {
        var data = await cc_engineFetch('/api/dmops/today');
        if (!data) {
            return;
        }
        dmo_renderToday('dmo-archive-today', data.Archive, true);
        dmo_renderToday('dmo-shell-today', data.ShellPurge, false);
    } catch (error) {
        console.error('Failed to load today stats:', error);
    }
}

/* Loads the per-process daily execution history. The Archive history honors
   the line-of-business filter (server-side); ShellPurge is always unfiltered. */
async function dmo_loadExecutionHistory() {
    try {
        var url = '/api/dmops/execution-history?workgroup=' + encodeURIComponent(dmo_currentHistoryFilter);
        var data = await cc_engineFetch(url);
        if (!data) {
            return;
        }
        dmo_renderExecutionHistory('dmo-archive-history', data.Archive, true);
        dmo_renderExecutionHistory('dmo-shell-history', data.ShellPurge, false);
    } catch (error) {
        console.error('Failed to load execution history:', error);
    }
}

/* ============================================================================
   FUNCTIONS: TARGET SERVER BADGES
   ----------------------------------------------------------------------------
   One-shot load of the per-process target-server environment badges. Values
   come from GlobalConfig and rarely change, so they are loaded once at page
   boot rather than on the refresh cycle.
   Prefix: dmo
   ============================================================================ */

/* Loads the per-process target servers and applies the environment badges. */
async function dmo_loadTargetServers() {
    try {
        var data = await cc_engineFetch('/api/dmops/target-servers');
        if (!data) {
            return;
        }
        dmo_applyTargetBadge('dmo-archive-target-badge', data.Archive);
        dmo_applyTargetBadge('dmo-shell-target-badge', data.ShellPurge);
    } catch (error) {
        console.error('Failed to load target servers:', error);
    }
}

/* Applies the environment class and label to a single target-server badge. */
function dmo_applyTargetBadge(elementId, info) {
    var el = document.getElementById(elementId);
    if (!el) {
        return;
    }

    el.classList.remove('dmo-env-test', 'dmo-env-prod', 'dmo-env-unknown');

    var server = info && info.Server ? info.Server : null;
    var env = info && info.Environment ? String(info.Environment) : null;

    if (env) {
        var envUpper = env.toUpperCase();
        if (envUpper.indexOf('TEST') !== -1) {
            el.classList.add('dmo-env-test');
        } else if (envUpper.indexOf('PROD') !== -1) {
            el.classList.add('dmo-env-prod');
        } else {
            el.classList.add('dmo-env-unknown');
        }
        el.textContent = env;
    } else {
        el.classList.add('dmo-env-unknown');
        el.textContent = 'unknown';
    }

    el.title = server ? ('Target server: ' + server) : 'No target server configured';
}

/* ============================================================================
   FUNCTIONS: ADMIN CONTROLS
   ----------------------------------------------------------------------------
   Renders the admin control cluster (Schedule, Abort, Launch) into a process's
   Today-section header placeholder when the API reports the user may manage
   the process. Non-admins get an empty cluster because dmo_canLaunch is false.
   Prefix: dmo
   ============================================================================ */

/* Renders or clears the admin control cluster for one process. The process
   argument is the API process key ('archive' or 'shellpurge'). */
function dmo_renderAdminControls(process) {
    var containerId = process === 'archive' ? 'dmo-archive-admin-controls' : 'dmo-shell-admin-controls';
    var container = document.getElementById(containerId);
    if (!container) {
        return;
    }

    if (!dmo_canLaunch) {
        container.innerHTML = '';
        return;
    }

    var aborted = dmo_abortState[process];
    var abortClass = 'dmo-action-btn dmo-abort-btn' + (aborted ? ' dmo-active' : '');
    var abortText = aborted ? '\u25A0 ABORT SET' : '\u25A0 Abort';
    var abortTitle = aborted ? 'Click to clear abort flag' : 'Emergency stop';

    var html = '';
    html += '<button class="dmo-action-btn dmo-schedule-btn" data-action-click="dmo-open-schedule" ' +
        'data-dmo-process="' + process + '" title="Edit execution schedule">\u25F7 Schedule</button>';
    html += '<button class="dmo-action-btn dmo-launch-btn" data-action-click="dmo-open-launch" ' +
        'data-dmo-process="' + process + '" title="Manually launch this process">\u25B6 Launch</button>';
    html += '<button class="' + abortClass + '" data-action-click="dmo-toggle-abort" ' +
        'data-dmo-process="' + process + '" title="' + abortTitle + '">' + abortText + '</button>';

    container.innerHTML = html;
}

/* ============================================================================
   FUNCTIONS: TOTALS RENDERING
   ----------------------------------------------------------------------------
   Renders the Archive totals (2x2, scoped to the active 1P/3P/ALL filter) and
   the Shell totals (1x2) from the self-contained per-process response objects.
   Remaining counts use subtractive math: the OLTP baseline minus the rows
   processed since the baseline was sampled. The Archive filter re-renders from
   retained data (dmo_lastLifetimeData) with no refetch.
   Prefix: dmo
   ============================================================================ */

/* Renders the Archive 2x2 totals cards for the active line-of-business filter. */
function dmo_renderArchiveTotals(data) {
    var container = document.getElementById('dmo-archive-totals');
    if (!container) { return; }

    var a = data.Archive;
    var bw = a.ByWorkgroup || {};

    // Select the slice for the active filter; fall back to All.
    var slice = bw[dmo_currentArchiveFilter] || bw.All || {
        Consumers: a.Consumers, Accounts: a.Accounts, RowsDeleted: a.RowsDeleted,
        Exceptions: a.Exceptions, Batches: a.Batches, Remaining: a.Remaining
    };
    var r = slice.Remaining || {};

    var consumersRemaining = (r.ConsumersBaseline !== null && r.ConsumersBaseline !== undefined)
        ? (r.ConsumersBaseline - (r.ConsumersSinceBaseline || 0))
        : null;
    var accountsRemaining = (r.AccountsBaseline !== null && r.AccountsBaseline !== undefined)
        ? (r.AccountsBaseline - (r.AccountsSinceBaseline || 0))
        : null;

    // BaselineDttm lives on the top-level Archive.Remaining (shared sample time).
    var ar = a.Remaining || {};
    var archiveBaselineSub = ar.BaselineDttm ? ('as of ' + ar.BaselineDttm.split(' ')[1]) : '';

    var html = '';

    html += '<div class="dmo-summary-card">' +
        '<div class="dmo-summary-card-label">Consumers Archived</div>' +
        '<div class="dmo-summary-card-value dmo-archive">' + dmo_formatNumber(slice.Consumers) + '</div>' +
        '<div class="dmo-summary-card-sub">' + dmo_formatNumber(slice.Batches) + ' batches' +
            (slice.Exceptions > 0 ? ' \u00B7 ' + dmo_formatNumber(slice.Exceptions) + ' exceptions' : '') +
        '</div>' +
    '</div>';

    html += '<div class="dmo-summary-card">' +
        '<div class="dmo-summary-card-label">Consumers Remaining</div>' +
        '<div class="dmo-summary-card-value dmo-remaining">' + (consumersRemaining !== null ? dmo_formatNumber(consumersRemaining) : '\u2014') + '</div>' +
        '<div class="dmo-summary-card-sub">' + (archiveBaselineSub || 'awaiting baseline') + '</div>' +
    '</div>';

    html += '<div class="dmo-summary-card">' +
        '<div class="dmo-summary-card-label">Accounts Archived</div>' +
        '<div class="dmo-summary-card-value dmo-archive">' + dmo_formatNumber(slice.Accounts) + '</div>' +
        '<div class="dmo-summary-card-sub">' + dmo_formatNumber(slice.RowsDeleted) + ' rows deleted</div>' +
    '</div>';

    html += '<div class="dmo-summary-card">' +
        '<div class="dmo-summary-card-label">Accounts Remaining</div>' +
        '<div class="dmo-summary-card-value dmo-remaining">' + (accountsRemaining !== null ? dmo_formatNumber(accountsRemaining) : '\u2014') + '</div>' +
        '<div class="dmo-summary-card-sub">in archive workgroups</div>' +
    '</div>';

    container.innerHTML = html;
}

/* Renders the Shell Purge 1x2 totals cards. */
function dmo_renderShellTotals(data) {
    var container = document.getElementById('dmo-shell-totals');
    if (!container) { return; }

    var p = data.ShellPurge;
    var pr = p.Remaining || {};

    var shellRemaining = (pr.Baseline !== null && pr.Baseline !== undefined)
        ? (pr.Baseline - (pr.SinceBaseline || 0))
        : null;
    var shellBaselineSub = pr.BaselineDttm ? ('as of ' + pr.BaselineDttm.split(' ')[1]) : '';

    var html = '';

    html += '<div class="dmo-summary-card">' +
        '<div class="dmo-summary-card-label">Shells Purged</div>' +
        '<div class="dmo-summary-card-value dmo-purge">' + dmo_formatNumber(p.Consumers) + '</div>' +
        '<div class="dmo-summary-card-sub">' + dmo_formatNumber(p.Batches) + ' batches</div>' +
    '</div>';

    html += '<div class="dmo-summary-card">' +
        '<div class="dmo-summary-card-label">Shells Remaining</div>' +
        '<div class="dmo-summary-card-value dmo-remaining">' + (shellRemaining !== null ? dmo_formatNumber(shellRemaining) : '\u2014') + '</div>' +
        '<div class="dmo-summary-card-sub">' + (shellBaselineSub || 'awaiting baseline') + '</div>' +
    '</div>';

    container.innerHTML = html;
}

/* Sets the Archive line-of-business filter and re-renders from retained data. */
function dmo_setArchiveFilter(target) {
    dmo_currentArchiveFilter = target.getAttribute('data-dmo-filter');

    var buttons = document.querySelectorAll('#dmo-archive-filter .dmo-filter-btn');
    buttons.forEach(function(btn) {
        btn.classList.toggle('dmo-filter-active', btn.getAttribute('data-dmo-filter') === dmo_currentArchiveFilter);
    });

    if (dmo_lastLifetimeData) {
        dmo_renderArchiveTotals(dmo_lastLifetimeData);
    }
}

/* Sets the Archive history line-of-business filter and refetches the history
   section scoped to the selection. Clears expansion state and the day-batch
   cache so the rebuilt tree and any drilldowns reflect the new scope. */
function dmo_setHistoryFilter(target) {
    dmo_currentHistoryFilter = target.getAttribute('data-dmo-filter');

    var buttons = document.querySelectorAll('#dmo-history-filter .dmo-filter-btn');
    buttons.forEach(function(btn) {
        btn.classList.toggle('dmo-filter-active', btn.getAttribute('data-dmo-filter') === dmo_currentHistoryFilter);
    });

    dmo_expandedSections = {};
    dmo_dayBatchCache = {};
    dmo_loadExecutionHistory();
}

/* ============================================================================
   FUNCTIONS: TODAY RENDERING
   ----------------------------------------------------------------------------
   Renders a process's Today stat grid. Archive shows accounts, exceptions, and
   BIDATA failures in addition to the shared stats; shell purge shows the
   common subset. Warning and danger figures appear only when nonzero.
   Prefix: dmo
   ============================================================================ */

/* Renders one process's Today stat grid into the given container. */
function dmo_renderToday(containerId, data, isArchive) {
    var container = document.getElementById(containerId);
    var colorClass = isArchive ? 'dmo-archive' : 'dmo-purge';

    if (data.Batches === 0) {
        container.innerHTML = '<div class="cc-slide-empty">No activity today</div>';
        return;
    }

    var html = '<div class="dmo-today-stats">';
    html += '<div class="dmo-today-stat"><div class="dmo-today-stat-value ' + colorClass + '">' + dmo_formatNumber(data.Batches) + '</div><div class="dmo-today-stat-label">Batches</div></div>';
    html += '<div class="dmo-today-stat"><div class="dmo-today-stat-value ' + colorClass + '">' + dmo_formatNumber(data.Consumers) + '</div><div class="dmo-today-stat-label">Consumers</div></div>';
    if (isArchive) {
        html += '<div class="dmo-today-stat"><div class="dmo-today-stat-value">' + dmo_formatNumber(data.Accounts) + '</div><div class="dmo-today-stat-label">Accounts</div></div>';
    }
    html += '<div class="dmo-today-stat"><div class="dmo-today-stat-value">' + dmo_formatNumber(data.RowsDeleted) + '</div><div class="dmo-today-stat-label">Rows</div></div>';
    html += '<div class="dmo-today-stat"><div class="dmo-today-stat-value">' + dmo_formatDuration(data.TotalSeconds) + '</div><div class="dmo-today-stat-label">Runtime</div></div>';

    if (isArchive) {
        if (data.Exceptions && data.Exceptions > 0) {
            html += '<div class="dmo-today-stat"><div class="dmo-today-stat-value dmo-warn">' + dmo_formatNumber(data.Exceptions) + '</div><div class="dmo-today-stat-label">Exceptions</div></div>';
        }
        if (data.BidataFailed && data.BidataFailed > 0) {
            html += '<div class="dmo-today-stat"><div class="dmo-today-stat-value dmo-danger">' + dmo_formatNumber(data.BidataFailed) + '</div><div class="dmo-today-stat-label">BIDATA Failed</div></div>';
        }
    }

    if (data.FailedBatches && data.FailedBatches > 0) {
        html += '<div class="dmo-today-stat"><div class="dmo-today-stat-value dmo-danger">' + dmo_formatNumber(data.FailedBatches) + '</div><div class="dmo-today-stat-label">Failed</div></div>';
    }

    html += '</div>';
    container.innerHTML = html;
}

/* ============================================================================
   FUNCTIONS: EXECUTION HISTORY RENDERING
   ----------------------------------------------------------------------------
   Renders the year/month/day execution-history accordion for one process and
   re-applies any expansion state that survived a refresh. Years expand to a
   month summary table; months expand to a day table; days expand to a per-day
   batch table loaded on demand.
   Prefix: dmo
   ============================================================================ */

/* Renders one process's execution-history accordion into the given container. */
function dmo_renderExecutionHistory(containerId, days, isArchive) {
    var container = document.getElementById(containerId);

    if (!days || days.length === 0) {
        container.innerHTML = '<div class="cc-slide-empty">No execution history</div>';
        return;
    }

    var years = {};
    var yearOrder = [];

    days.forEach(function(row) {
        var y = row.run_year;
        var m = row.run_month;

        if (!years[y]) {
            years[y] = { months: {}, monthOrder: [], totalAccounts: 0, totalConsumers: 0, totalRows: 0 };
            yearOrder.push(y);
        }
        if (!years[y].months[m]) {
            years[y].months[m] = { days: [], totalAccounts: 0, totalConsumers: 0, totalRows: 0, totalBatches: 0, totalSeconds: 0, totalExceptions: 0, bidataFailed: 0, failedBatches: 0 };
            years[y].monthOrder.push(m);
        }

        years[y].months[m].days.push(row);
        years[y].months[m].totalConsumers += row.consumers;
        years[y].months[m].totalRows += row.rows_deleted;
        years[y].months[m].totalBatches += row.batches;
        years[y].months[m].totalSeconds += row.total_seconds;
        years[y].months[m].failedBatches += (row.failed_batches || 0);
        if (isArchive) {
            years[y].months[m].totalAccounts += (row.accounts || 0);
            years[y].months[m].totalExceptions += (row.exceptions || 0);
            years[y].months[m].bidataFailed += (row.bidata_failed || 0);
        }

        years[y].totalConsumers += row.consumers;
        years[y].totalRows += row.rows_deleted;
        if (isArchive) {
            years[y].totalAccounts += (row.accounts || 0);
        }
    });

    var prefix = isArchive ? 'arch' : 'shell';
    var html = '<div class="dmo-history-tree">';

    yearOrder.forEach(function(year) {
        var yd = years[year];
        var yearKey = prefix + '-year-' + year;
        var yearExpanded = dmo_expandedSections[yearKey] || false;

        html += '<div class="dmo-history-year">';
        html += '<div class="dmo-year-header" data-action-click="dmo-toggle-history" data-dmo-section-key="' + yearKey + '" id="' + yearKey + '-header">';
        html += '<span class="dmo-expand-icon">' + (yearExpanded ? '\u25BC' : '\u25B6') + '</span>';
        html += '<span class="dmo-year-label">' + year + '</span>';
        html += '<div class="dmo-year-stats">';
        html += '<span class="dmo-year-stat dmo-processed">' + dmo_formatNumber(yd.totalConsumers) + ' consumers</span>';
        if (isArchive) {
            html += '<span class="dmo-year-stat dmo-processed">' + dmo_formatNumber(yd.totalAccounts) + ' accounts</span>';
        }
        html += '</div>';
        html += '</div>';

        html += '<div class="dmo-year-content' + (yearExpanded ? '' : ' dmo-collapsed') + '" id="' + yearKey + '-body">';

        var monthColCount = isArchive ? 7 : 6;

        html += '<table class="dmo-month-summary-table"><thead><tr>';
        html += '<th class="dmo-month-summary-th"></th><th class="dmo-month-summary-th">Month</th><th class="dmo-month-summary-th dmo-right">Batches</th>';
        html += '<th class="dmo-month-summary-th dmo-right">Consumers</th>';
        if (isArchive) {
            html += '<th class="dmo-month-summary-th dmo-right">Accounts</th>';
        }
        html += '<th class="dmo-month-summary-th dmo-right">Rows</th><th class="dmo-month-summary-th dmo-right">Time</th>';
        html += '</tr></thead>';

        yd.monthOrder.forEach(function(month) {
            var md = years[year].months[month];
            var monthKey = prefix + '-month-' + year + '-' + month;
            var monthExpanded = dmo_expandedSections[monthKey] || false;

            html += '<tbody>';
            html += '<tr class="dmo-month-row" data-action-click="dmo-toggle-history" data-dmo-section-key="' + monthKey + '" id="' + monthKey + '-header">';
            html += '<td class="dmo-month-summary-td dmo-expand-cell"><span class="dmo-expand-icon">' + (monthExpanded ? '\u25BC' : '\u25B6') + '</span></td>';
            html += '<td class="dmo-month-summary-td dmo-month-cell">' + cc_MONTH_NAMES[month] + '</td>';
            html += '<td class="dmo-month-summary-td dmo-right">' + dmo_formatNumber(md.totalBatches) + '</td>';
            html += '<td class="dmo-month-summary-td dmo-right">' + dmo_formatNumber(md.totalConsumers) + '</td>';
            if (isArchive) {
                html += '<td class="dmo-month-summary-td dmo-right">' + dmo_formatNumber(md.totalAccounts) + '</td>';
            }
            html += '<td class="dmo-month-summary-td dmo-right">' + dmo_formatNumber(md.totalRows) + '</td>';
            html += '<td class="dmo-month-summary-td dmo-right">' + dmo_formatDuration(md.totalSeconds) + '</td>';
            html += '</tr>';

            html += '<tr class="dmo-month-details' + (monthExpanded ? '' : ' dmo-collapsed') + '" id="' + monthKey + '-body"><td class="dmo-month-summary-td" colspan="' + monthColCount + '">';
            html += '<div class="dmo-month-details-content">';

            var dayColCount = isArchive ? 8 : 6;
            html += '<table class="dmo-day-table"><thead><tr>';
            html += '<th class="dmo-day-table-th"></th><th class="dmo-day-table-th">Day</th><th class="dmo-day-table-th">Date</th>';
            html += '<th class="dmo-day-table-th dmo-right">Batches</th>';
            html += '<th class="dmo-day-table-th dmo-right">Consumers</th>';
            if (isArchive) {
                html += '<th class="dmo-day-table-th dmo-right">Accounts</th>';
            }
            html += '<th class="dmo-day-table-th dmo-right">Rows</th>';
            html += '<th class="dmo-day-table-th dmo-right">Time</th>';
            if (isArchive) {
                html += '<th class="dmo-day-table-th dmo-right">Exc</th>';
            }
            html += '</tr></thead><tbody>';

            md.days.forEach(function(day) {
                var dateParts = day.run_date.split('-');
                var dayDisplay = dateParts[1] + '/' + dateParts[2];
                var dayKey = prefix + '-batches-' + day.run_date;
                var dayExpanded = dmo_expandedSections[dayKey] || false;
                var rowWarnClass = (day.failed_batches > 0 || (isArchive && day.bidata_failed > 0)) ? ' dmo-row-warn' : '';

                html += '<tr class="dmo-day-row' + rowWarnClass + '" data-action-click="dmo-toggle-day-batches" data-dmo-process="' + (isArchive ? 'archive' : 'shellpurge') + '" data-dmo-date="' + day.run_date + '" id="' + dayKey + '-header">';
                html += '<td class="dmo-day-table-td dmo-expand-cell"><span class="dmo-expand-icon">' + (dayExpanded ? '\u25BC' : '\u25B6') + '</span></td>';
                html += '<td class="dmo-day-table-td">' + day.day_of_week.substring(0, 3) + '</td>';
                html += '<td class="dmo-day-table-td">' + dayDisplay + '</td>';
                html += '<td class="dmo-day-table-td dmo-right">' + dmo_formatNumber(day.batches) +
                    (day.failed_batches > 0 ? ' <span class="dmo-cell-fail">(' + day.failed_batches + ' failed)</span>' : '') +
                    '</td>';
                html += '<td class="dmo-day-table-td dmo-right">' + dmo_formatNumber(day.consumers) + '</td>';
                if (isArchive) {
                    html += '<td class="dmo-day-table-td dmo-right">' + dmo_formatNumber(day.accounts || 0) + '</td>';
                }
                html += '<td class="dmo-day-table-td dmo-right">' + dmo_formatNumber(day.rows_deleted) + '</td>';
                html += '<td class="dmo-day-table-td dmo-right">' + dmo_formatDuration(day.total_seconds) + '</td>';
                if (isArchive) {
                    var excText = (day.exceptions || 0) > 0 ? dmo_formatNumber(day.exceptions) : '-';
                    var bidataNote = (day.bidata_failed || 0) > 0 ? ' <span class="dmo-cell-fail" title="BIDATA migration failed in ' + day.bidata_failed + ' batch(es)">\u26A0</span>' : '';
                    html += '<td class="dmo-day-table-td dmo-right">' + excText + bidataNote + '</td>';
                }
                html += '</tr>';

                html += '<tr class="dmo-day-batches' + (dayExpanded ? '' : ' dmo-collapsed') + '" id="' + dayKey + '-body">';
                html += '<td class="dmo-day-table-td" colspan="' + dayColCount + '"><div class="dmo-day-batches-content" id="' + dayKey + '-content">';
                html += '<div class="cc-slide-empty">Loading batches\u2026</div>';
                html += '</div></td>';
                html += '</tr>';
            });

            html += '</tbody></table></div></td></tr>';
            html += '</tbody>';
        });

        html += '</table></div></div>';
    });

    html += '</div>';
    container.innerHTML = html;

    dmo_applyHistoryExpansion(prefix);
    dmo_repopulateExpandedDays(prefix);
}

/* Applies the surviving expansion state to year/month/day sections after a
   re-render by toggling the collapsed data attribute. */
function dmo_applyHistoryExpansion(prefix) {
    Object.keys(dmo_expandedSections).forEach(function(key) {
        if (!dmo_expandedSections[key]) {
            return;
        }
        if (key.indexOf(prefix + '-') !== 0) {
            return;
        }
        var body = document.getElementById(key + '-body');
        if (body) {
            body.classList.remove('dmo-collapsed');
        }
    });
}

/* Re-renders or re-fetches the batch list for any day section that was
   expanded prior to the refresh. */
function dmo_repopulateExpandedDays(prefix) {
    Object.keys(dmo_expandedSections).forEach(function(key) {
        if (!dmo_expandedSections[key]) {
            return;
        }
        if (key.indexOf(prefix + '-batches-') !== 0) {
            return;
        }
        var date = key.substring((prefix + '-batches-').length);
        var process = prefix === 'arch' ? 'archive' : 'shellpurge';
        if (dmo_dayBatchCache[key]) {
            dmo_renderBatches(process, date, dmo_dayBatchCache[key]);
        } else {
            dmo_loadBatchesByDay(process, date);
        }
    });
}

/* Toggles a year or month accordion section open or closed. */
function dmo_toggleHistorySection(target) {
    var key = target.getAttribute('data-dmo-section-key');
    if (!key) {
        return;
    }
    var header = document.getElementById(key + '-header');
    var body = document.getElementById(key + '-body');
    if (!header || !body) {
        return;
    }
    var icon = header.querySelector('.dmo-expand-icon');
    var collapsed = body.classList.contains('dmo-collapsed');

    if (collapsed) {
        body.classList.remove('dmo-collapsed');
        if (icon) {
            icon.innerHTML = '\u25BC';
        }
        dmo_expandedSections[key] = true;
    } else {
        body.classList.add('dmo-collapsed');
        if (icon) {
            icon.innerHTML = '\u25B6';
        }
        dmo_expandedSections[key] = false;
    }
}

/* ============================================================================
   FUNCTIONS: BATCH DRILL-DOWN
   ----------------------------------------------------------------------------
   Expands a day row to its per-day batch table, fetching the batch list on
   first expand and caching it for subsequent re-renders. Batch rows open the
   batch-detail slideout.
   Prefix: dmo
   ============================================================================ */

/* Toggles a day's per-batch sub-table, loading the batch list on first open. */
function dmo_toggleDayBatches(target) {
    var process = target.getAttribute('data-dmo-process');
    var date = target.getAttribute('data-dmo-date');
    if (!process || !date) {
        return;
    }
    var prefix = process === 'archive' ? 'arch' : 'shell';
    var key = prefix + '-batches-' + date;
    var header = document.getElementById(key + '-header');
    var body = document.getElementById(key + '-body');
    if (!header || !body) {
        return;
    }
    var icon = header.querySelector('.dmo-expand-icon');
    var collapsed = body.classList.contains('dmo-collapsed');

    if (collapsed) {
        body.classList.remove('dmo-collapsed');
        if (icon) {
            icon.innerHTML = '\u25BC';
        }
        dmo_expandedSections[key] = true;

        if (dmo_dayBatchCache[key]) {
            dmo_renderBatches(process, date, dmo_dayBatchCache[key]);
        } else {
            dmo_loadBatchesByDay(process, date);
        }
    } else {
        body.classList.add('dmo-collapsed');
        if (icon) {
            icon.innerHTML = '\u25B6';
        }
        dmo_expandedSections[key] = false;
    }
}

/* Fetches the batch list for a given process and date. */
async function dmo_loadBatchesByDay(process, date) {
    var prefix = process === 'archive' ? 'arch' : 'shell';
    var key = prefix + '-batches-' + date;
    var contentEl = document.getElementById(key + '-content');
    if (!contentEl) {
        return;
    }

    contentEl.innerHTML = '<div class="cc-slide-empty">Loading batches\u2026</div>';

    try {
        var url = '/api/dmops/' + process + '/batches-by-day?date=' + encodeURIComponent(date);
        if (process === 'archive') {
            url += '&workgroup=' + encodeURIComponent(dmo_currentHistoryFilter);
        }
        var batches = await cc_engineFetch(url);
        if (!batches) {
            return;
        }

        dmo_dayBatchCache[key] = batches;
        dmo_renderBatches(process, date, batches);
    } catch (error) {
        console.error('Failed to load batches for ' + date + ':', error);
        contentEl.innerHTML = '<div class="cc-slide-empty">Error loading batches: ' + cc_escapeHtml(error.message) + '</div>';
    }
}

/* Renders the per-day batch table for a process and date. */
function dmo_renderBatches(process, date, batches) {
    var prefix = process === 'archive' ? 'arch' : 'shell';
    var key = prefix + '-batches-' + date;
    var contentEl = document.getElementById(key + '-content');
    if (!contentEl) {
        return;
    }

    if (!batches || batches.length === 0) {
        contentEl.innerHTML = '<div class="cc-slide-empty">No batch detail available</div>';
        return;
    }

    var isArchive = process === 'archive';
    var html = '<table class="dmo-batch-table"><thead>';

    html += '<tr>';
    html += '<th class="dmo-batch-table-th" rowspan="2">#</th>';
    html += '<th class="dmo-batch-table-th" rowspan="2">Started</th>';
    html += '<th class="dmo-batch-table-th" rowspan="2">Mode</th>';
    html += '<th class="dmo-batch-table-th dmo-right" rowspan="2">Duration</th>';
    html += '<th class="dmo-batch-table-th" rowspan="2">Status</th>';
    if (isArchive) {
        html += '<th class="dmo-batch-table-th" rowspan="2">BIDATA</th>';
        html += '<th class="dmo-batch-table-th" rowspan="2">LOB</th>';
    }
    html += '<th class="dmo-batch-table-th dmo-batch-counts-header" colspan="' + (isArchive ? 4 : 2) + '">Counts</th>';
    html += '</tr>';
    html += '<tr>';
    html += '<th class="dmo-batch-table-th dmo-right">Consumers</th>';
    if (isArchive) {
        html += '<th class="dmo-batch-table-th dmo-right">Accounts</th>';
    }
    html += '<th class="dmo-batch-table-th dmo-right">Rows</th>';
    if (isArchive) {
        html += '<th class="dmo-batch-table-th dmo-right">Exc</th>';
    }
    html += '</tr></thead><tbody>';

    batches.forEach(function(b) {
        var rowClass = '';
        if (b.status === 'Failed') {
            rowClass = ' dmo-row-failed';
        } else if (isArchive && b.bidata_status === 'Failed') {
            rowClass = ' dmo-row-warn';
        }

        html += '<tr class="dmo-batch-row' + rowClass + '" data-action-click="dmo-open-batch-detail" data-dmo-process="' + process + '" data-dmo-batch-id="' + b.batch_id + '" title="Click for full BatchDetail">';
        html += '<td class="dmo-batch-table-td dmo-batch-id">' + b.batch_id + ((isArchive && b.batch_retry) ? ' <span class="dmo-retry-badge" title="Retry of batch ' + b.retry_batch_id + '">R</span>' : '') + '</td>';
        html += '<td class="dmo-batch-table-td">' + cc_escapeHtml(dmo_formatTimeOnly(b.batch_start_dttm)) + '</td>';
        html += '<td class="dmo-batch-table-td">' + dmo_modeBadge(b.schedule_mode) + '</td>';
        html += '<td class="dmo-batch-table-td dmo-right">' + dmo_formatMs(b.duration_ms) + '</td>';
        html += '<td class="dmo-batch-table-td">' + dmo_statusBadge(b.status) + '</td>';
        if (isArchive) {
            html += '<td class="dmo-batch-table-td">' + dmo_bidataBadge(b.bidata_status) + '</td>';
            html += '<td class="dmo-batch-table-td">' + dmo_workgroupBadge(b.source_workgroup) + '</td>';
        }
        html += '<td class="dmo-batch-table-td dmo-right">' + dmo_formatNumber(b.consumer_count) + '</td>';
        if (isArchive) {
            html += '<td class="dmo-batch-table-td dmo-right">' + dmo_formatNumber(b.account_count) + '</td>';
        }
        html += '<td class="dmo-batch-table-td dmo-right">' + dmo_formatNumber(b.total_rows_deleted) + '</td>';
        if (isArchive) {
            html += '<td class="dmo-batch-table-td dmo-right">' + ((b.exception_count > 0) ? '<span class="dmo-cell-warn">' + b.exception_count + '</span>' : '-') + '</td>';
        }
        html += '</tr>';
    });

    html += '</tbody></table>';
    contentEl.innerHTML = html;
}

/* ============================================================================
   FUNCTIONS: BATCH DETAIL SLIDEOUT
   ----------------------------------------------------------------------------
   Opens the batch-detail slideout for a single batch, fetches its full detail
   rows, and renders the summary header plus the sortable per-table step list.
   The slideout uses the shared cc-open slide mechanics with a guarded close.
   Prefix: dmo
   ============================================================================ */

/* Opens the batch-detail slideout and loads the batch's detail rows. */
async function dmo_openBatchDetail(target) {
    var process = target.getAttribute('data-dmo-process');
    var batchId = target.getAttribute('data-dmo-batch-id');
    if (!process || !batchId) {
        return;
    }

    var overlay = document.getElementById('dmo-slideout-batch-detail');
    var dialog = overlay.querySelector('.cc-dialog');
    overlay.classList.add('cc-open');
    requestAnimationFrame(function() {
        dialog.classList.add('cc-open');
    });

    document.getElementById('dmo-slideout-batch-detail-title').textContent = 'Batch ' + batchId;
    var body = document.getElementById('dmo-slideout-batch-detail-body');
    body.innerHTML = '<div class="cc-slide-empty">Loading batch detail\u2026</div>';

    try {
        var url = '/api/dmops/' + process + '/batch-detail/' + encodeURIComponent(batchId);
        var data = await cc_engineFetch(url);
        if (!data) {
            return;
        }
        dmo_renderBatchDetail(process, data);
    } catch (error) {
        body.innerHTML = '<div class="cc-slide-empty">Error loading batch detail: ' + cc_escapeHtml(error.message) + '</div>';
    }
}

/* Closes the batch-detail slideout, guarding against interior clicks. */
function dmo_closeBatchDetail(target, event) {
    if (event && target.id === 'dmo-slideout-batch-detail' && event.target !== target) {
        return;
    }
    var overlay = document.getElementById('dmo-slideout-batch-detail');
    var dialog = overlay.querySelector('.cc-dialog');
    dialog.addEventListener('transitionend', function handler() {
        dialog.removeEventListener('transitionend', handler);
        overlay.classList.remove('cc-open');
    });
    dialog.classList.remove('cc-open');
}

/* Renders the batch-detail summary header and sortable step table. */
function dmo_renderBatchDetail(process, data) {
    var s = data.Summary;
    var details = data.Details || [];
    var isArchive = process === 'archive';
    var body = document.getElementById('dmo-slideout-batch-detail-body');

    var html = '<div class="dmo-batch-detail-header">';

    html += '<div class="dmo-batch-detail-line">';
    html += '<span class="dmo-bd-label">Started</span><span class="dmo-bd-value">' + cc_escapeHtml(s.batch_start_dttm || '-') + '</span>';
    html += '<span class="dmo-bd-label">Ended</span><span class="dmo-bd-value">' + cc_escapeHtml(s.batch_end_dttm || '-') + '</span>';
    html += '<span class="dmo-bd-label">Duration</span><span class="dmo-bd-value">' + dmo_formatMs(s.duration_ms) + '</span>';
    html += '<span class="dmo-bd-label">Mode</span><span class="dmo-bd-value">' + dmo_modeBadge(s.schedule_mode) + '</span>';
    html += '<span class="dmo-bd-label">Status</span><span class="dmo-bd-value">' + dmo_statusBadge(s.status) + '</span>';
    if (isArchive) {
        html += '<span class="dmo-bd-label">BIDATA</span><span class="dmo-bd-value">' + dmo_bidataBadge(s.bidata_status) + '</span>';
    }
    html += '</div>';

    html += '<div class="dmo-batch-detail-line">';
    html += '<span class="dmo-bd-label">Consumers</span><span class="dmo-bd-value">' + dmo_formatNumber(s.consumer_count) + '</span>';
    if (isArchive) {
        html += '<span class="dmo-bd-label">Accounts</span><span class="dmo-bd-value">' + dmo_formatNumber(s.account_count) + '</span>';
    }
    html += '<span class="dmo-bd-label">Rows</span><span class="dmo-bd-value">' + dmo_formatNumber(s.total_rows_deleted) + '</span>';
    if (isArchive) {
        html += '<span class="dmo-bd-label">Exceptions</span><span class="dmo-bd-value">' + dmo_formatNumber(s.exception_count || 0) + '</span>';
    }
    html += '<span class="dmo-bd-label">Tables (proc/skip/fail)</span><span class="dmo-bd-value">' +
        dmo_formatNumber(s.tables_processed) + ' / ' +
        dmo_formatNumber(s.tables_skipped) + ' / ' +
        dmo_formatNumber(s.tables_failed) + '</span>';
    html += '<span class="dmo-bd-label">Executed By</span><span class="dmo-bd-value">' + cc_escapeHtml(s.executed_by || '-') + '</span>';
    html += '</div>';

    if (isArchive && s.batch_retry) {
        html += '<div class="dmo-batch-detail-line dmo-last"><span class="dmo-bd-label">Retry Of</span><span class="dmo-bd-value">' + s.retry_batch_id + '</span></div>';
    }
    if (s.error_message) {
        html += '<div class="dmo-batch-detail-error">Error: ' + cc_escapeHtml(s.error_message) + '</div>';
    }

    html += '</div>';

    if (details.length === 0) {
        html += '<div class="cc-slide-empty">No detail rows recorded for this batch</div>';
    } else {
        html += '<table class="dmo-batch-detail-table" id="dmo-batch-detail-table"><thead><tr>';
        html += '<th class="dmo-batch-detail-th" data-action-click="dmo-sort-batch-detail" data-dmo-col="delete_order" data-dmo-type="text">Order</th>';
        html += '<th class="dmo-batch-detail-th" data-action-click="dmo-sort-batch-detail" data-dmo-col="table_name" data-dmo-type="text">Table</th>';
        html += '<th class="dmo-batch-detail-th" data-action-click="dmo-sort-batch-detail" data-dmo-col="pass_description" data-dmo-type="text">Pass</th>';
        html += '<th class="dmo-batch-detail-th dmo-right" data-action-click="dmo-sort-batch-detail" data-dmo-col="rows_affected" data-dmo-type="num">Rows</th>';
        html += '<th class="dmo-batch-detail-th dmo-right" data-action-click="dmo-sort-batch-detail" data-dmo-col="duration_ms" data-dmo-type="num">Duration</th>';
        html += '<th class="dmo-batch-detail-th" data-action-click="dmo-sort-batch-detail" data-dmo-col="status" data-dmo-type="text">Status</th>';
        html += '<th class="dmo-batch-detail-th">Error</th>';
        html += '</tr></thead><tbody>';

        details.forEach(function(d) {
            var rowClass = 'dmo-batch-detail-row';
            if (d.status && d.status.toLowerCase() === 'failed') {
                rowClass += ' dmo-row-failed';
            }
            html += '<tr class="' + rowClass + '">';
            html += '<td class="dmo-batch-detail-td">' + dmo_deleteOrderHtml(d.delete_order) + '</td>';
            html += '<td class="dmo-batch-detail-td">' + cc_escapeHtml(d.table_name) + '</td>';
            html += '<td class="dmo-batch-detail-td">' + cc_escapeHtml(d.pass_description || '') + '</td>';
            html += '<td class="dmo-batch-detail-td dmo-right">' + dmo_formatNumber(d.rows_affected) + '</td>';
            html += '<td class="dmo-batch-detail-td dmo-right">' + dmo_formatMs(d.duration_ms) + '</td>';
            html += '<td class="dmo-batch-detail-td">' + dmo_statusBadge(d.status) + '</td>';
            html += '<td class="dmo-batch-detail-td dmo-bd-error-cell" title="' + cc_escapeHtml(d.error_message || '') + '">' + cc_escapeHtml(d.error_message || '') + '</td>';
            html += '</tr>';
        });

        html += '</tbody></table>';
    }

    body.innerHTML = html;
}

/* Sorts the batch-detail step table by the clicked column. */
function dmo_sortBatchDetail(target) {
    var table = document.getElementById('dmo-batch-detail-table');
    if (!table) {
        return;
    }
    var col = target.getAttribute('data-dmo-col');
    var type = target.getAttribute('data-dmo-type');
    var headers = table.querySelectorAll('thead th');
    var index = -1;
    for (var i = 0; i < headers.length; i++) {
        if (headers[i].getAttribute('data-dmo-col') === col) {
            index = i;
            break;
        }
    }
    if (index < 0) {
        return;
    }

    var asc = !(target.getAttribute('data-dmo-sort') === 'asc');
    headers.forEach(function(h) {
        h.removeAttribute('data-dmo-sort');
        h.classList.remove('dmo-sorted-asc', 'dmo-sorted-desc');
    });
    target.setAttribute('data-dmo-sort', asc ? 'asc' : 'desc');
    target.classList.add(asc ? 'dmo-sorted-asc' : 'dmo-sorted-desc');

    var tbody = table.querySelector('tbody');
    var rows = Array.prototype.slice.call(tbody.querySelectorAll('tr'));
    rows.sort(function(a, b) {
        var av = a.cells[index].textContent.trim();
        var bv = b.cells[index].textContent.trim();
        if (type === 'num') {
            var an = parseFloat(av.replace(/[^0-9.\-]/g, '')) || 0;
            var bn = parseFloat(bv.replace(/[^0-9.\-]/g, '')) || 0;
            return asc ? (an - bn) : (bn - an);
        }
        return asc ? av.localeCompare(bv) : bv.localeCompare(av);
    });
    rows.forEach(function(r) {
        tbody.appendChild(r);
    });
}

/* ============================================================================
   FUNCTIONS: SCHEDULE MODAL
   ----------------------------------------------------------------------------
   Opens the schedule modal for a process, fetches its weekly grid, and renders
   the three-state click-and-drag editor. The modal uses the shared cc-hidden
   toggle with a guarded close. One modal instance serves both processes.
   Prefix: dmo
   ============================================================================ */

/* Opens the schedule modal for the process named on the clicked control. */
async function dmo_openScheduleModal(target) {
    var process = target.getAttribute('data-dmo-process');
    if (!process) {
        return;
    }
    dmo_currentScheduleProcess = process;

    var title = process === 'archive' ? 'Archive Schedule' : 'Shell Purge Schedule';
    document.getElementById('dmo-modal-schedule-title').textContent = title;
    document.getElementById('dmo-modal-schedule').classList.remove('cc-hidden');

    var body = document.getElementById('dmo-modal-schedule-body');
    body.innerHTML = '<div class="cc-slide-empty">Loading schedule\u2026</div>';

    try {
        var url = '/api/dmops/' + process + '/schedule';
        var data = await cc_engineFetch(url);
        if (!data) {
            return;
        }
        dmo_renderScheduleModal(data);
    } catch (error) {
        body.innerHTML = '<div class="cc-slide-empty">Error loading schedule: ' + cc_escapeHtml(error.message) + '</div>';
    }
}

/* Closes the schedule modal, guarding against interior clicks, and resets the
   drag state. */
function dmo_closeScheduleModal(target, event) {
    if (event && target.id === 'dmo-modal-schedule' && event.target !== target) {
        return;
    }
    document.getElementById('dmo-modal-schedule').classList.add('cc-hidden');
    dmo_currentScheduleProcess = null;
    dmo_resetDragState();
}

/* Renders the schedule editor grid from the weekly schedule data. */
function dmo_renderScheduleModal(scheduleData) {
    var body = document.getElementById('dmo-modal-schedule-body');

    var html = '';

    html += '<div class="dmo-schedule-mode-selector">';
    html += '<span class="dmo-schedule-mode-label">Paint mode:</span>';
    html += '<button class="dmo-schedule-mode-btn dmo-active-full" id="dmo-mode-btn-1" data-action-click="dmo-set-paint-mode" data-dmo-mode="1">Full</button>';
    html += '<button class="dmo-schedule-mode-btn" id="dmo-mode-btn-2" data-action-click="dmo-set-paint-mode" data-dmo-mode="2">Reduced</button>';
    html += '<button class="dmo-schedule-mode-btn" id="dmo-mode-btn-0" data-action-click="dmo-set-paint-mode" data-dmo-mode="0">Blocked</button>';
    html += '<span class="dmo-schedule-drag-hint">Click or drag to paint cells</span>';
    html += '</div>';

    html += '<div class="dmo-schedule-legend">';
    html += '<div class="dmo-schedule-legend-item"><div class="dmo-schedule-legend-box dmo-full"></div><span>Full</span></div>';
    html += '<div class="dmo-schedule-legend-item"><div class="dmo-schedule-legend-box dmo-reduced"></div><span>Reduced</span></div>';
    html += '<div class="dmo-schedule-legend-item"><div class="dmo-schedule-legend-box dmo-blocked"></div><span>Blocked</span></div>';
    html += '</div>';

    html += '<div class="dmo-schedule-grid">';

    html += '<div class="dmo-schedule-hour-labels"><div class="dmo-schedule-day-label"></div>';
    html += '<div class="dmo-schedule-hours">';
    for (var h = 0; h < 24; h++) {
        html += '<div class="dmo-schedule-hour-label">' + dmo_formatHour(h) + '</div>';
    }
    html += '</div></div>';

    for (var d = 0; d < dmo_DAY_ORDER.length; d++) {
        var day = dmo_DAY_ORDER[d];
        var daySchedule = null;
        for (var i = 0; i < scheduleData.length; i++) {
            if (scheduleData[i].DayOfWeek === day) {
                daySchedule = scheduleData[i];
                break;
            }
        }
        if (!daySchedule) {
            daySchedule = {};
        }

        html += '<div class="dmo-schedule-row">';
        html += '<div class="dmo-schedule-day-label">' + cc_DAY_NAMES[day] + '</div>';
        html += '<div class="dmo-schedule-hours">';

        for (var hh = 0; hh < 24; hh++) {
            var hourKey = 'Hr' + hh.toString().padStart(2, '0');
            var value = daySchedule[hourKey] !== undefined ? daySchedule[hourKey] : 0;
            var cellClass = dmo_cellClass(value);

            html += '<div class="dmo-schedule-cell ' + cellClass + '" ' +
                'data-dmo-day="' + day + '" data-dmo-hour="' + hh + '" data-dmo-value="' + value + '" ' +
                'title="' + cc_DAY_NAMES[day] + ' ' + dmo_formatHour(hh) + ' \u2014 ' + dmo_cellLabel(value) + '">' +
                '</div>';
        }

        html += '</div></div>';
    }

    html += '</div>';
    body.innerHTML = html;
}

/* Sets the active paint value and updates the mode-button selection. */
function dmo_setSchedulePaintMode(target) {
    var mode = parseInt(target.getAttribute('data-dmo-mode'), 10);
    dmo_dragPaintValue = mode;
    [0, 1, 2].forEach(function(m) {
        var btn = document.getElementById('dmo-mode-btn-' + m);
        if (!btn) {
            return;
        }
        btn.className = 'dmo-schedule-mode-btn';
        if (m === mode) {
            var activeClass = m === 1 ? 'dmo-active-full' : m === 2 ? 'dmo-active-reduced' : 'dmo-active-blocked';
            btn.classList.add(activeClass);
        }
    });
}

/* ============================================================================
   FUNCTIONS: SCHEDULE DRAG
   ----------------------------------------------------------------------------
   Drives the click-and-drag cell painting via document-level mouse listeners
   registered in dmo_init. The grid is rendered dynamically, so per-cell
   binding is avoided; the handlers resolve cells via closest on the cell
   class and apply the painted value as a single transactional batch update.
   Prefix: dmo
   ============================================================================ */

/* Begins a drag selection when the press lands on a schedule cell. */
function dmo_handleScheduleMouseDown(event) {
    var cell = event.target.closest('.dmo-schedule-cell');
    if (!cell) {
        return;
    }
    event.preventDefault();
    dmo_isDragging = true;
    dmo_dragSelectedCells = [cell];
    cell.classList.add('dmo-drag-selected');
}

/* Extends the active drag selection as the pointer moves over cells. */
function dmo_handleScheduleMouseOver(event) {
    if (!dmo_isDragging) {
        return;
    }
    var cell = event.target.closest('.dmo-schedule-cell');
    if (!cell) {
        return;
    }
    if (dmo_dragSelectedCells.indexOf(cell) === -1) {
        dmo_dragSelectedCells.push(cell);
        cell.classList.add('dmo-drag-selected');
    }
}

/* Commits the active drag selection when the press is released. */
function dmo_handleScheduleMouseUp() {
    if (!dmo_isDragging) {
        return;
    }
    dmo_applyDragSelection();
}

/* Applies the painted value to the selected cells and persists the change as
   a single transactional batch update. */
async function dmo_applyDragSelection() {
    if (!dmo_isDragging || dmo_dragSelectedCells.length === 0) {
        dmo_resetDragState();
        return;
    }

    var cells = dmo_dragSelectedCells.slice();
    var paintValue = dmo_dragPaintValue;
    var process = dmo_currentScheduleProcess;

    dmo_resetDragState();

    var updates = [];
    cells.forEach(function(cell) {
        var currentValue = parseInt(cell.getAttribute('data-dmo-value'), 10);
        if (currentValue !== paintValue) {
            updates.push({
                DayOfWeek: parseInt(cell.getAttribute('data-dmo-day'), 10),
                Hour: parseInt(cell.getAttribute('data-dmo-hour'), 10),
                Value: paintValue
            });
        }
        cell.classList.remove('dmo-drag-selected');
    });

    if (updates.length === 0) {
        return;
    }

    cells.forEach(function(cell) {
        cell.className = 'dmo-schedule-cell ' + dmo_cellClass(paintValue);
        cell.setAttribute('data-dmo-value', paintValue);
        cell.classList.add('dmo-saving');

        var day = parseInt(cell.getAttribute('data-dmo-day'), 10);
        var hour = parseInt(cell.getAttribute('data-dmo-hour'), 10);
        cell.title = cc_DAY_NAMES[day] + ' ' + dmo_formatHour(hour) + ' \u2014 ' + dmo_cellLabel(paintValue);
    });

    try {
        await cc_engineFetch('/api/dmops/schedule/update-batch', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ Process: process, Updates: updates })
        });

        cells.forEach(function(cell) {
            cell.classList.remove('dmo-saving');
        });
    } catch (error) {
        console.error('Schedule update failed:', error);
        var url = '/api/dmops/' + process + '/schedule';
        var data = await cc_engineFetch(url);
        if (data) {
            dmo_renderScheduleModal(data);
        }
    }
}

/* Clears the active drag selection state and any lingering selection styling. */
function dmo_resetDragState() {
    dmo_isDragging = false;
    dmo_dragSelectedCells.forEach(function(cell) {
        if (cell && cell.classList) {
            cell.classList.remove('dmo-drag-selected');
        }
    });
    dmo_dragSelectedCells = [];
}

/* ============================================================================
   FUNCTIONS: ABORT AND LAUNCH
   ----------------------------------------------------------------------------
   The admin abort toggle and the manual launch flow. Abort confirms only when
   setting the flag. Launch opens a confirmation modal, then posts to the
   launch endpoint. Both re-render the affected admin control cluster.
   Prefix: dmo
   ============================================================================ */

/* Toggles a process's abort flag, confirming before setting it. */
async function dmo_toggleAbort(target) {
    var process = target.getAttribute('data-dmo-process');
    if (!process) {
        return;
    }
    var newState = !dmo_abortState[process];
    var label = process === 'archive' ? 'Archive' : 'Shell Purge';

    if (newState) {
        var confirmed = await cc_showConfirm(
            'Set ' + label + ' abort flag? This will stop the process after the current batch completes.',
            {
                title: 'Confirm Abort',
                confirmLabel: 'Set Abort Flag',
                confirmClass: 'cc-dialog-btn-danger'
            }
        );
        if (!confirmed) {
            return;
        }
    }

    try {
        await cc_engineFetch('/api/dmops/abort', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ Process: process, Abort: newState })
        });

        dmo_abortState[process] = newState;
        dmo_renderAdminControls(process);
    } catch (error) {
        cc_showAlert('Failed to update abort flag: ' + error.message, { title: 'Error' });
    }
}

/* Opens the launch confirmation modal for the process on the clicked control. */
function dmo_openLaunchModal(target) {
    var process = target.getAttribute('data-dmo-process');
    if (!process) {
        return;
    }
    var label = process === 'archive' ? 'Archive' : 'Shell Purge';
    var launchProcess = process === 'archive' ? 'archive' : 'shell';

    document.getElementById('dmo-modal-launch-title').textContent = 'Launch ' + label;
    document.getElementById('dmo-modal-launch-body').innerHTML =
        '<p class="cc-dialog-paragraph">Manually launch the ' + cc_escapeHtml(label) +
        ' process now? It will start a new run on its configured target server.</p>';
    document.getElementById('dmo-modal-launch-footer').innerHTML =
        '<button class="cc-dialog-btn-cancel" data-action-click="dmo-close-launch">Cancel</button>' +
        '<button class="cc-dialog-btn-primary" data-action-click="dmo-confirm-launch" data-dmo-process="' + launchProcess + '">Launch</button>';

    document.getElementById('dmo-modal-launch').classList.remove('cc-hidden');
}

/* Closes the launch confirmation modal, guarding against interior clicks. */
function dmo_closeLaunchModal(target, event) {
    if (event && target.id === 'dmo-modal-launch' && event.target !== target) {
        return;
    }
    document.getElementById('dmo-modal-launch').classList.add('cc-hidden');
}

/* Posts the launch request for the confirmed process and reports the result. */
async function dmo_confirmLaunch(target) {
    var process = target.getAttribute('data-dmo-process');
    if (!process) {
        return;
    }
    document.getElementById('dmo-modal-launch').classList.add('cc-hidden');

    try {
        var result = await cc_engineFetch('/api/dmops/launch-process', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ Process: process })
        });
        if (!result) {
            return;
        }
        cc_showAlert(result.Message || 'Process launched.', { title: 'Launch' });
    } catch (error) {
        cc_showAlert('Failed to launch process: ' + error.message, { title: 'Error' });
    }
}

/* ============================================================================
   FUNCTIONS: REFRESH AND POLLING
   ----------------------------------------------------------------------------
   Reloads all refresh-cycle sections and manages the live polling interval.
   Called from dmo_init, the page lifecycle hooks, and the polling timer.
   Prefix: dmo
   ============================================================================ */

/* Reloads all refresh-cycle sections and stamps the last-updated time. */
async function dmo_refreshAll() {
    await Promise.all([
        dmo_loadLifetimeTotals(),
        dmo_loadToday(),
        dmo_loadExecutionHistory()
    ]);
    var stamp = document.getElementById('cc-last-update');
    if (stamp) {
        stamp.textContent = new Date().toLocaleTimeString();
    }
}

/* Starts the live polling interval if not already running. */
function dmo_startPolling() {
    if (dmo_livePollingTimer) {
        return;
    }
    dmo_refreshSeconds = dmo_DEFAULT_REFRESH_SECONDS;
    dmo_livePollingTimer = setInterval(dmo_onPageRefresh, dmo_refreshSeconds * 1000);
}

/* Stops the live polling interval. */
function dmo_stopPolling() {
    if (dmo_livePollingTimer) {
        clearInterval(dmo_livePollingTimer);
        dmo_livePollingTimer = null;
    }
}

/* ============================================================================
   FUNCTIONS: PAGE LIFECYCLE HOOKS
   ----------------------------------------------------------------------------
   The lifecycle hooks invoked by cc-shared.js: the page refresh reload, the
   tab-resume refresh, the session-expiry polling stop, and the engine-process
   completion refresh. Read by exact name from the shared module.
   Prefix: dmo
   ============================================================================ */

/* Reloads all page data; invoked by the shared page-refresh handler. Forces a
   full reload across a midnight rollover so day-scoped views stay current. */
async function dmo_onPageRefresh() {
    var now = new Date().toDateString();
    if (now !== dmo_pageLoadDate) {
        dmo_pageLoadDate = now;
        window.location.reload();
        return;
    }
    await dmo_refreshAll();
}

/* Resumes data loading when the tab regains visibility. */
function dmo_onPageResumed() {
    dmo_refreshAll();
}

/* Stops live polling when the session expires. */
function dmo_onSessionExpired() {
    dmo_stopPolling();
}

/* Refreshes data when an engine process completes. */
function dmo_onEngineProcessCompleted() {
    dmo_refreshAll();
}

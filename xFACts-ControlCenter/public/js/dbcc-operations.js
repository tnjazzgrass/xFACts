/* ============================================================================
   xFACts Control Center - DBCC Operations JavaScript (dbcc-operations.js)
   Location: E:\xFACts-ControlCenter\public\js\dbcc-operations.js
   Version: Tracked in dbo.System_Metadata (component: ServerOps.DBCC)

   Client-side logic for the DBCC Operations page: live integrity-check
   progress polling, today's execution list, the year/month/day execution
   history accordion, the schedule overview, and the three schedule modals
   (pending queue, server schedule detail, database schedule edit). Boots
   via dbc_init and routes user interaction through per-event dispatch
   tables; chrome concerns (fetch, polling visibility, engine cards, page
   refresh) are handled by cc-shared.js.

   FILE ORGANIZATION
   -----------------
   CONSTANTS: ENGINE PROCESSES
   CONSTANTS: CONFIGURATION
   CONSTANTS: ACTION DISPATCH
   STATE: PAGE STATE
   FUNCTIONS: INITIALIZATION
   FUNCTIONS: LIVE POLLING
   FUNCTIONS: DATA LOADING
   FUNCTIONS: LIVE PROGRESS
   FUNCTIONS: PENDING QUEUE MODAL
   FUNCTIONS: TODAY'S EXECUTIONS
   FUNCTIONS: EXECUTION HISTORY
   FUNCTIONS: SCHEDULE OVERVIEW
   FUNCTIONS: SCHEDULE DETAIL MODAL
   FUNCTIONS: SCHEDULE EDIT MODAL
   FUNCTIONS: FORMATTING
   FUNCTIONS: PAGE LIFECYCLE HOOKS
   ============================================================================ */

/* ============================================================================
   CONSTANTS: ENGINE PROCESSES
   ----------------------------------------------------------------------------
   Maps the orchestrator process this page cares about to its engine-card
   slug. Read by cc-shared.js for engine-card click handling and completion
   routing. Declared with var per the engine-processes rule.
   Prefix: dbc
   ============================================================================ */

/* The orchestrator process whose engine card appears on this page. */
var dbc_ENGINE_PROCESSES = {
    'Execute-DBCC': { slug: 'dbcc' }
};

/* ============================================================================
   CONSTANTS: CONFIGURATION
   ----------------------------------------------------------------------------
   Immutable lookup tables and option lists used across rendering: month
   names for the history accordion, weekday option list and time-of-day
   option list for the edit form selects, and the check-mode/replica-override
   option sets for the edit form badge pills.
   Prefix: dbc
   ============================================================================ */

/* Weekday options for the schedule edit-form day selects (value matches DATEPART weekday). */
const dbc_DAY_OPTIONS = [
    { value: 1, label: 'Sunday' },
    { value: 2, label: 'Monday' },
    { value: 3, label: 'Tuesday' },
    { value: 4, label: 'Wednesday' },
    { value: 5, label: 'Thursday' },
    { value: 6, label: 'Friday' },
    { value: 7, label: 'Saturday' }
];

/* Hourly time-of-day options for the schedule edit-form time selects. */
const dbc_TIME_OPTIONS = dbc_buildTimeOptions();

/* The four DBCC operation keys in display order, with their API operation names. */
const dbc_OPERATION_KEYS = [
    { key: 'checkdb', label: 'CHECKDB', op: 'CHECKDB' },
    { key: 'checkalloc', label: 'CHECKALLOC', op: 'CHECKALLOC' },
    { key: 'checkcatalog', label: 'CHECKCATALOG', op: 'CHECKCATALOG' },
    { key: 'checkconstraints', label: 'CHECKCONSTRAINTS', op: 'CHECKCONSTRAINTS' }
];

/* Check-mode badge-pill options for the edit form. */
const dbc_CHECK_MODE_OPTIONS = [
    { value: 'NONE', label: 'None', pill: 'dbc-pill-none' },
    { value: 'PHYSICAL_ONLY', label: 'Physical Only', pill: 'dbc-pill-physical' },
    { value: 'FULL', label: 'Full', pill: 'dbc-pill-full' }
];

/* Replica-override badge-pill options for the edit form (AG listener databases only). */
const dbc_REPLICA_OPTIONS = [
    { value: '', label: 'Default', pill: 'dbc-pill-default' },
    { value: 'PRIMARY', label: 'Primary', pill: 'dbc-pill-primary' },
    { value: 'SECONDARY', label: 'Secondary', pill: 'dbc-pill-secondary' }
];

/* ============================================================================
   CONSTANTS: ACTION DISPATCH
   ----------------------------------------------------------------------------
   Per-event dispatch tables mapping data-action-<event> values declared in
   emitted markup to handler functions. Registered as delegated listeners on
   document.body inside dbc_init.
   Prefix: dbc
   ============================================================================ */

/* Maps data-action-click values to their handler functions. */
const dbc_clickActions = {
    'dbc-open-pending':        dbc_openPending,
    'dbc-close-pending':       dbc_closePending,
    'dbc-open-schedule':       dbc_openScheduleModal,
    'dbc-close-schedule':      dbc_closeScheduleModal,
    'dbc-open-edit':           dbc_openEditModal,
    'dbc-close-edit':          dbc_closeEditModal,
    'dbc-toggle-year':         dbc_toggleYear,
    'dbc-toggle-month':        dbc_toggleMonth,
    'dbc-toggle-day':          dbc_toggleDay,
    'dbc-toggle-detail':       dbc_toggleDetailRow,
    'dbc-toggle-op':           dbc_toggleEditOp,
    'dbc-select-mode':         dbc_selectCheckMode,
    'dbc-select-replica':      dbc_selectReplica,
    'dbc-save-edits':          dbc_saveScheduleEdits
};

/* ============================================================================
   STATE: PAGE STATE
   ----------------------------------------------------------------------------
   Mutable runtime state: the live polling timer, the page-load date for the
   midnight-rollover reload, the configured refresh interval, the admin flag
   derived from the schedule API, and the data caches the modals read from.
   Prefix: dbc
   ============================================================================ */

/* Interval timer handle for the live-progress / today's-executions poll. */
var dbc_livePollingTimer = null;

/* Day-of-load string; a change at the interval tick triggers a page reload. */
var dbc_pageLoadDate = new Date().toDateString();

/* Configured live refresh interval in seconds (overridden from GlobalConfig). */
var dbc_refreshInterval = 10;

/* Whether the current user is an admin, as reported by the schedule API. */
var dbc_isAdmin = false;

/* Cached pending operations from the most recent live-progress response. */
var dbc_currentPendingOps = [];

/* Cached schedule rows from the most recent schedule-overview response. */
var dbc_currentScheduleData = [];

/* The server name currently shown in the schedule detail modal, or null. */
var dbc_currentScheduleServer = null;

/* The schedule_id currently shown in the edit modal, or null. */
var dbc_editScheduleId = null;

/* The check_mode the edit modal opened with (used to detect a change on save). */
var dbc_editOriginalCheckMode = null;

/* ============================================================================
   FUNCTIONS: INITIALIZATION
   ----------------------------------------------------------------------------
   The page boot function invoked by cc-shared.js after the module loads.
   Registers the page's delegated click listener, performs the initial data
   load, and starts the live polling and midnight-rollover timers.
   Prefix: dbc
   ============================================================================ */

/* Boots the page: registers the delegated click dispatcher, loads the
   configured refresh interval, fetches all panels, and starts polling. */
function dbc_init() {
    document.body.addEventListener('click', function(event) {
        var target = event.target.closest('[data-action-click]');
        if (!target) {
            return;
        }
        var action = target.getAttribute('data-action-click');
        var handler = dbc_clickActions[action];
        if (handler) {
            handler(target, event);
        }
    });

    document.addEventListener('keydown', function(event) {
        if (event.key === 'Escape') {
            dbc_closeEditModal();
            dbc_closeScheduleModal();
            dbc_closePending();
        }
    });

    setInterval(dbc_checkDateRollover, 60000);

    cc_connectEngineEvents();

    dbc_loadRefreshInterval().then(function() {
        dbc_startLivePolling();
    });
    dbc_loadAllData();
    dbc_loadLiveProgress();
}

/* ============================================================================
   FUNCTIONS: LIVE POLLING
   ----------------------------------------------------------------------------
   The interval-driven refresh timers: the live-progress / today's-executions
   poll on the configured interval, and the midnight date-rollover reload.
   Prefix: dbc
   ============================================================================ */

/* Reloads the page when the calendar day changes so the date-scoped panels
   reset cleanly at midnight. */
function dbc_checkDateRollover() {
    if (new Date().toDateString() !== dbc_pageLoadDate) {
        window.location.reload();
    }
}

/* Starts (or restarts) the live polling timer that refreshes live progress
   and today's executions on the configured interval. */
function dbc_startLivePolling() {
    if (dbc_livePollingTimer) {
        clearInterval(dbc_livePollingTimer);
    }
    dbc_livePollingTimer = setInterval(function() {
        dbc_loadLiveProgress();
        dbc_loadTodaysExecutions();
        dbc_updateTimestamp();
    }, dbc_refreshInterval * 1000);
}

/* Stops the live polling timer. */
function dbc_stopLivePolling() {
    if (dbc_livePollingTimer) {
        clearInterval(dbc_livePollingTimer);
        dbc_livePollingTimer = null;
    }
}

/* ============================================================================
   FUNCTIONS: DATA LOADING
   ----------------------------------------------------------------------------
   Top-level fetch orchestration: the configured refresh interval, the
   parallel initial load of the non-live panels, and the last-updated
   timestamp refresh.
   Prefix: dbc
   ============================================================================ */

/* Loads the page's configured live refresh interval from GlobalConfig. */
async function dbc_loadRefreshInterval() {
    try {
        var data = await cc_engineFetch('/api/config/refresh-interval?page=dbcc-operations');
        if (data && data.interval) {
            dbc_refreshInterval = data.interval;
        }
    } catch (e) {
        /* Keep the default interval on failure. */
    }
}

/* Loads the three non-live panels in parallel and stamps the timestamp. */
async function dbc_loadAllData() {
    await Promise.all([
        dbc_loadTodaysExecutions(),
        dbc_loadExecutionHistory(),
        dbc_loadScheduleOverview()
    ]);
    dbc_updateTimestamp();
}

/* Writes the current time into the last-updated chrome element. */
function dbc_updateTimestamp() {
    var el = document.getElementById('cc-last-update');
    if (el) {
        el.textContent = new Date().toLocaleTimeString();
    }
}

/* ============================================================================
   FUNCTIONS: LIVE PROGRESS
   ----------------------------------------------------------------------------
   Fetches and renders the active-operations panel: in-progress DBCC checks
   with percent-complete bars, and the pending-count badge. Caches the
   pending operations for the pending-queue modal.
   Prefix: dbc
   ============================================================================ */

/* Fetches the live-progress payload and renders it. */
async function dbc_loadLiveProgress() {
    try {
        var data = await cc_engineFetch('/api/dbcc/live-progress');
        if (!data) {
            return;
        }
        if (data.Error) {
            return;
        }
        dbc_renderLiveProgress(data);
    } catch (e) {
        /* Transient fetch failure; the next poll retries. */
    }
}

/* Renders running operations as progress cards and updates the pending badge. */
function dbc_renderLiveProgress(data) {
    var container = document.getElementById('dbc-live-progress');

    if (data.IsActive && data.ActiveOps && data.ActiveOps.length > 0) {
        var runningOps = data.ActiveOps.filter(function(op) { return op.Status === 'IN_PROGRESS'; });
        dbc_currentPendingOps = data.ActiveOps.filter(function(op) { return op.Status === 'PENDING'; });

        dbc_updatePendingBadge(dbc_currentPendingOps.length);

        if (runningOps.length > 0) {
            var html = '';
            runningOps.forEach(function(op) {
                html += dbc_renderRunningOpCard(op);
            });
            container.innerHTML = html;
            dbc_applyProgressWidths(container, runningOps);
        } else {
            container.innerHTML = '<div class="dbc-no-activity">No operations currently running &mdash; '
                + dbc_currentPendingOps.length + ' pending</div>';
        }
    } else {
        dbc_currentPendingOps = [];
        dbc_updatePendingBadge(0);
        container.innerHTML = '<div class="dbc-no-activity">No active executions</div>';
    }
}

/* Builds the markup for a single running-operation progress card. */
function dbc_renderRunningOpCard(op) {
    var html = '<div class="dbc-live-op-card dbc-running">';
    html += '<div class="dbc-live-op-header">';
    html += '<div class="dbc-live-op-title-block">';
    html += '<div class="dbc-live-op-title">';
    html += '<span class="dbc-op-badge ' + dbc_opBadgeClass(op.Operation) + '">' + cc_escapeHtml(op.Operation) + '</span>';
    html += ' <span class="dbc-live-op-db">' + cc_escapeHtml(op.DatabaseName) + '</span>';
    html += '</div>';

    var subtitleParts = [];
    if (op.CheckMode) {
        subtitleParts.push(op.CheckMode);
    }
    if (op.MaxDop) {
        subtitleParts.push('MAXDOP ' + op.MaxDop);
    }
    if (subtitleParts.length > 0) {
        html += '<div class="dbc-live-op-subtitle">' + cc_escapeHtml(subtitleParts.join(' \u00B7 ')) + '</div>';
    }
    html += '</div>';

    html += '<span class="dbc-status-badge dbc-running">';
    html += '<span class="cc-spinning-gear">&#9881;</span> RUNNING</span>';
    html += '</div>';

    html += '<div class="dbc-live-op-stats">';
    html += dbc_renderOpStat('Server', op.ServerName);
    if (op.ExecutedOnServer && op.ExecutedOnServer !== op.ServerName) {
        html += dbc_renderOpStat('Target', op.ExecutedOnServer);
    }
    if (op.ElapsedSeconds !== null) {
        html += dbc_renderOpStat('Elapsed', dbc_formatDuration(op.ElapsedSeconds));
    }
    if (op.EtaSeconds !== null && op.EtaSeconds > 0) {
        html += dbc_renderOpStat('ETA', dbc_formatDuration(op.EtaSeconds));
    }
    html += '</div>';

    var pct = op.PercentComplete !== null ? op.PercentComplete : 0;
    var pctDisplay = op.PercentComplete !== null ? pct.toFixed(1) + '%' : 'Calculating...';
    html += '<div class="dbc-progress-track">';
    html += '<div class="dbc-progress-fill"></div>';
    html += '<span class="dbc-progress-text">' + cc_escapeHtml(pctDisplay) + '</span>';
    html += '</div>';

    html += '</div>';
    return html;
}

/* Sets each rendered progress-fill bar's width from its operation's percent
   complete. Width is a per-row runtime value, so it is applied via the DOM
   style property after insertion rather than baked into the markup string. */
function dbc_applyProgressWidths(container, runningOps) {
    var fills = container.querySelectorAll('.dbc-progress-fill');
    for (var i = 0; i < fills.length && i < runningOps.length; i++) {
        var op = runningOps[i];
        var pct = op.PercentComplete !== null ? op.PercentComplete : 0;
        fills[i].style.width = pct + '%';
    }
}

/* Builds the markup for a single labeled stat inside a live-op card. */
function dbc_renderOpStat(label, value) {
    return '<div class="dbc-live-op-stat-label">' + cc_escapeHtml(label) + ':'
        + ' <span class="dbc-live-op-stat-value">' + cc_escapeHtml(value) + '</span></div>';
}

/* Shows or hides the pending-count badge in the Today's Executions header. */
function dbc_updatePendingBadge(count) {
    var badge = document.getElementById('dbc-pending-count-badge');
    if (count > 0) {
        badge.textContent = count;
        badge.classList.remove('cc-hidden');
    } else {
        badge.classList.add('cc-hidden');
    }
}

/* ============================================================================
   FUNCTIONS: PENDING QUEUE MODAL
   ----------------------------------------------------------------------------
   Opens the static pending-queue modal and renders the cached pending
   operations as a table.
   Prefix: dbc
   ============================================================================ */

/* Opens the pending-queue modal and renders the cached pending operations. */
function dbc_openPending() {
    dbc_renderPendingQueue(dbc_currentPendingOps);
    document.getElementById('dbc-modal-pending').classList.remove('cc-hidden');
}

/* Closes the pending-queue modal. Ignores clicks bubbling from the dialog interior. */
function dbc_closePending(target, event) {
    if (event && target && target.id === 'dbc-modal-pending' && event.target !== target) {
        return;
    }
    document.getElementById('dbc-modal-pending').classList.add('cc-hidden');
}

/* Renders the pending operations into the modal body as a table. */
function dbc_renderPendingQueue(ops) {
    var body = document.getElementById('dbc-pending-body');

    if (!ops || ops.length === 0) {
        body.innerHTML = '<div class="dbc-no-activity">No pending operations</div>';
        return;
    }

    var html = '<table class="dbc-history-table">';
    html += '<thead><tr>';
    html += '<th class="dbc-history-table-th">Operation</th>';
    html += '<th class="dbc-history-table-th">Database</th>';
    html += '<th class="dbc-history-table-th">Server</th>';
    html += '<th class="dbc-history-table-th">Queued</th>';
    html += '</tr></thead><tbody>';

    ops.forEach(function(op) {
        html += '<tr>';
        html += '<td class="dbc-history-table-td"><span class="dbc-op-badge ' + dbc_opBadgeClass(op.Operation) + '">'
            + cc_escapeHtml(op.Operation) + '</span>';
        if (op.CheckMode) {
            html += ' <span class="dbc-annotation">' + cc_escapeHtml(op.CheckMode) + '</span>';
        }
        html += '</td>';
        html += '<td class="dbc-history-table-td">' + cc_escapeHtml(op.DatabaseName) + '</td>';
        html += '<td class="dbc-history-table-td">' + cc_escapeHtml(op.ServerName) + '</td>';
        html += '<td class="dbc-history-table-td">'
            + (op.QueueWaitSeconds !== null ? dbc_formatDuration(op.QueueWaitSeconds) + ' ago' : '-') + '</td>';
        html += '</tr>';
    });

    html += '</tbody></table>';
    body.innerHTML = html;
}

/* ============================================================================
   FUNCTIONS: TODAY'S EXECUTIONS
   ----------------------------------------------------------------------------
   Fetches and renders the day's completed and in-progress executions as a
   compact columnar list.
   Prefix: dbc
   ============================================================================ */

/* Fetches today's executions and renders them. */
async function dbc_loadTodaysExecutions() {
    try {
        var data = await cc_engineFetch('/api/dbcc/todays-executions');
        if (!data) {
            return;
        }
        if (data.error || data.Error) {
            return;
        }
        dbc_renderTodaysExecutions(data);
    } catch (e) {
        /* Transient fetch failure; the next poll retries. */
    }
}

/* Renders today's executions as a list of columnar rows. */
function dbc_renderTodaysExecutions(data) {
    var container = document.getElementById('dbc-todays-executions');

    if (!data || data.length === 0) {
        container.innerHTML = '<div class="dbc-no-activity">No executions today</div>';
        return;
    }

    var html = '<div class="dbc-todays-list">';
    data.forEach(function(row) {
        html += dbc_renderTodayRow(row);
    });
    html += '</div>';
    container.innerHTML = html;
}

/* Builds the markup for a single today's-executions row. */
function dbc_renderTodayRow(row) {
    var isRunning = row.status === 'IN_PROGRESS';
    var rowState = row.status === 'FAILED' ? ' dbc-row-failed'
        : row.status === 'ERRORS_FOUND' ? ' dbc-row-errors'
        : isRunning ? ' dbc-row-running' : '';

    var html = '<div class="dbc-today-row' + rowState + '">';
    html += '<span class="dbc-op-badge dbc-today-op ' + dbc_opBadgeClass(row.operation) + '">'
        + cc_escapeHtml(row.operation) + '</span>';
    html += '<span class="dbc-today-server">' + cc_escapeHtml(row.server_name) + '</span>';
    html += '<span class="dbc-today-db">' + cc_escapeHtml(row.database_name) + '</span>';

    if (isRunning && row.elapsed_seconds !== null) {
        html += '<span class="dbc-today-duration">' + dbc_formatDuration(row.elapsed_seconds) + '</span>';
    } else if (row.duration_seconds !== null) {
        html += '<span class="dbc-today-duration">' + dbc_formatDuration(row.duration_seconds) + '</span>';
    } else {
        html += '<span class="dbc-today-duration">-</span>';
    }

    if (isRunning) {
        html += '<span class="dbc-today-time">-</span>';
    } else {
        html += '<span class="dbc-today-time">' + dbc_formatDateShort(row.completed_dttm) + '</span>';
    }

    html += '<span class="dbc-today-mode">' + (row.check_mode ? cc_escapeHtml(row.check_mode) : '') + '</span>';

    html += '<span class="dbc-today-status"><span class="dbc-status-badge ' + dbc_statusBadgeClass(row.status) + '">';
    if (isRunning) {
        html += '<span class="cc-spinning-gear">&#9881;</span> ';
    }
    html += cc_escapeHtml(row.status) + '</span></span>';

    html += '</div>';
    return html;
}

/* ============================================================================
   FUNCTIONS: EXECUTION HISTORY
   ----------------------------------------------------------------------------
   Fetches the execution-history summary and renders the year/month/day
   accordion. Day rows lazily fetch their per-operation detail on first
   expand. Expansion state is toggled via the dbc-expanded class.
   Prefix: dbc
   ============================================================================ */

/* Fetches the execution-history summary and renders the accordion. */
async function dbc_loadExecutionHistory() {
    try {
        var data = await cc_engineFetch('/api/dbcc/execution-history');
        if (!data) {
            return;
        }
        if (data.error || data.Error) {
            return;
        }
        dbc_renderExecutionHistory(data);
    } catch (e) {
        /* Transient fetch failure; refreshed on engine completion. */
    }
}

/* Groups the history rows by year then month and renders the accordion tree. */
function dbc_renderExecutionHistory(data) {
    var container = document.getElementById('dbc-execution-history');

    if (!data || data.length === 0) {
        container.innerHTML = '<div class="dbc-no-activity">No execution history available</div>';
        return;
    }

    var grouped = dbc_groupHistoryByYearMonth(data);
    var html = '<div class="dbc-history-tree">';
    grouped.yearOrder.forEach(function(year) {
        html += dbc_renderHistoryYear(year, grouped.years[year]);
    });
    html += '</div>';
    container.innerHTML = html;
}

/* Builds the year/month grouping structure with rolled-up counts. */
function dbc_groupHistoryByYearMonth(data) {
    var years = {};
    var yearOrder = [];

    data.forEach(function(row) {
        var y = row.run_year;
        var m = row.run_month;

        if (!years[y]) {
            years[y] = { months: {}, monthOrder: [], totalOps: 0, successCount: 0, failedCount: 0, errorsCount: 0 };
            yearOrder.push(y);
        }
        if (!years[y].months[m]) {
            years[y].months[m] = { days: [], totalOps: 0, successCount: 0, failedCount: 0, errorsCount: 0 };
            years[y].monthOrder.push(m);
        }

        years[y].months[m].days.push(row);
        years[y].months[m].totalOps += row.operation_count;
        years[y].months[m].successCount += row.success_count;
        years[y].months[m].failedCount += row.failed_count;
        years[y].months[m].errorsCount += row.errors_found_count;

        years[y].totalOps += row.operation_count;
        years[y].successCount += row.success_count;
        years[y].failedCount += row.failed_count;
        years[y].errorsCount += row.errors_found_count;
    });

    return { years: years, yearOrder: yearOrder };
}

/* Builds the markup for a single year block and its month summary table. */
function dbc_renderHistoryYear(year, yd) {
    var html = '<div class="dbc-history-year">';
    html += '<div class="dbc-year-header" data-action-click="dbc-toggle-year" data-action-dbc-year="' + year + '">';
    html += '<span class="dbc-expand-icon" id="dbc-year-icon-' + year + '">&#9654;</span>';
    html += '<span class="dbc-year-label">' + year + '</span>';
    html += '<div class="dbc-year-stats">';
    html += '<span class="dbc-year-stat">' + yd.totalOps + ' executions</span>';
    html += '<span class="dbc-year-stat dbc-success">' + (yd.successCount + yd.errorsCount) + ' succeeded</span>';
    html += '<span class="dbc-year-stat dbc-failed">' + (yd.failedCount > 0 ? yd.failedCount + ' failed' : '-') + '</span>';
    html += '</div>';
    html += '</div>';

    html += '<div class="dbc-year-content" id="dbc-year-body-' + year + '">';
    html += '<table class="dbc-month-table"><thead><tr>';
    html += '<th class="dbc-month-table-th"></th>';
    html += '<th class="dbc-month-table-th">Month</th>';
    html += '<th class="dbc-month-table-th">Executions</th>';
    html += '<th class="dbc-month-table-th">Succeeded</th>';
    html += '<th class="dbc-month-table-th">Failed</th>';
    html += '</tr></thead>';

    yd.monthOrder.forEach(function(month) {
        html += dbc_renderHistoryMonth(year, month, yd.months[month]);
    });

    html += '</table>';
    html += '</div>';
    html += '</div>';
    return html;
}

/* Builds the markup for a single month summary row and its day-detail body. */
function dbc_renderHistoryMonth(year, month, md) {
    var monthKey = year + '-' + month;

    var html = '<tbody>';
    html += '<tr class="dbc-month-row" data-action-click="dbc-toggle-month" data-action-dbc-month="' + monthKey + '">';
    html += '<td class="dbc-month-table-td dbc-expand-cell"><span class="dbc-expand-icon" id="dbc-month-icon-' + monthKey + '">&#9654;</span></td>';
    html += '<td class="dbc-month-table-td dbc-month-cell">' + cc_MONTH_NAMES[month] + '</td>';
    html += '<td class="dbc-month-table-td">' + md.totalOps + '</td>';
    html += '<td class="dbc-month-table-td dbc-success-cell">' + (md.successCount + md.errorsCount) + '</td>';
    html += '<td class="dbc-month-table-td dbc-fail-cell">' + (md.failedCount > 0 ? md.failedCount : '-') + '</td>';
    html += '</tr>';

    html += '<tr class="dbc-month-details-row" id="dbc-month-body-' + monthKey + '">';
    html += '<td class="dbc-month-details-td" colspan="5"><div class="dbc-month-details-content">';
    html += '<table class="dbc-history-table"><thead><tr>';
    html += '<th class="dbc-history-table-th"></th>';
    html += '<th class="dbc-history-table-th">Day</th>';
    html += '<th class="dbc-history-table-th">Date</th>';
    html += '<th class="dbc-history-table-th">Runs</th>';
    html += '<th class="dbc-history-table-th">Executions</th>';
    html += '<th class="dbc-history-table-th">Duration</th>';
    html += '<th class="dbc-history-table-th">Succeeded</th>';
    html += '<th class="dbc-history-table-th">Failed</th>';
    html += '<th class="dbc-history-table-th">Warnings</th>';
    html += '</tr></thead><tbody>';

    md.days.forEach(function(day) {
        html += dbc_renderHistoryDay(day);
    });

    html += '</tbody></table>';
    html += '</div></td></tr>';
    html += '</tbody>';
    return html;
}

/* Builds the markup for a single day summary row and its lazy-load detail row. */
function dbc_renderHistoryDay(day) {
    var dateParts = day.run_date.split('-');
    var dayDisplay = dateParts[1] + '/' + dateParts[2];

    var html = '<tr class="dbc-history-row" data-action-click="dbc-toggle-day" data-action-dbc-date="' + day.run_date + '">';
    html += '<td class="dbc-history-table-td dbc-expand-cell"><span class="dbc-expand-icon" id="dbc-day-icon-' + day.run_date + '">&#9654;</span></td>';
    html += '<td class="dbc-history-table-td">' + cc_escapeHtml(day.day_of_week) + '</td>';
    html += '<td class="dbc-history-table-td">' + dayDisplay + '</td>';
    html += '<td class="dbc-history-table-td">' + day.run_count + '</td>';
    html += '<td class="dbc-history-table-td">' + day.operation_count + '</td>';
    html += '<td class="dbc-history-table-td">' + dbc_formatDuration(day.total_duration_seconds) + '</td>';
    html += '<td class="dbc-history-table-td dbc-success-cell">' + (day.success_count + day.errors_found_count) + '</td>';
    html += '<td class="dbc-history-table-td dbc-fail-cell">' + (day.failed_count > 0 ? day.failed_count : '-') + '</td>';
    html += '<td class="dbc-history-table-td dbc-warning-cell">' + (day.errors_found_count > 0 ? day.errors_found_count : '-') + '</td>';
    html += '</tr>';

    html += '<tr class="dbc-day-detail-row" id="dbc-day-body-' + day.run_date + '">';
    html += '<td class="dbc-day-detail-td" colspan="9"><div class="dbc-day-detail-content"><div class="dbc-loading">Loading...</div></div></td>';
    html += '</tr>';
    return html;
}

/* Toggles a year body open or closed and swaps its chevron glyph. */
function dbc_toggleYear(target) {
    var year = target.getAttribute('data-action-dbc-year');
    var body = document.getElementById('dbc-year-body-' + year);
    var icon = document.getElementById('dbc-year-icon-' + year);
    dbc_toggleExpand(body, icon);
}

/* Toggles a month detail row open or closed and swaps its chevron glyph. */
function dbc_toggleMonth(target) {
    var monthKey = target.getAttribute('data-action-dbc-month');
    var body = document.getElementById('dbc-month-body-' + monthKey);
    var icon = document.getElementById('dbc-month-icon-' + monthKey);
    dbc_toggleExpand(body, icon);
}

/* Toggles a day detail row, lazily loading its per-operation table on first open. */
async function dbc_toggleDay(target) {
    var date = target.getAttribute('data-action-dbc-date');
    var body = document.getElementById('dbc-day-body-' + date);
    var icon = document.getElementById('dbc-day-icon-' + date);
    if (!body) {
        return;
    }

    if (body.classList.contains('dbc-expanded')) {
        body.classList.remove('dbc-expanded');
        if (icon) {
            icon.innerHTML = '&#9654;';
        }
        return;
    }

    var content = body.querySelector('.dbc-day-detail-content');
    if (content && content.querySelector('.dbc-loading')) {
        try {
            var data = await cc_engineFetch('/api/dbcc/execution-history-day?date=' + encodeURIComponent(date));
            if (data && !data.error && !data.Error) {
                dbc_renderDayDetail(content, data);
            } else {
                content.innerHTML = '<div class="dbc-no-activity">Failed to load detail</div>';
            }
        } catch (e) {
            content.innerHTML = '<div class="dbc-no-activity">Failed to load detail</div>';
        }
    }

    body.classList.add('dbc-expanded');
    if (icon) {
        icon.innerHTML = '&#9660;';
    }
}

/* Renders the per-operation detail table for an expanded day. */
function dbc_renderDayDetail(container, data) {
    if (!data || data.length === 0) {
        container.innerHTML = '<div class="dbc-no-activity">No operations this day</div>';
        return;
    }

    var html = '<table class="dbc-history-table"><thead><tr>';
    html += '<th class="dbc-history-table-th">Operation</th>';
    html += '<th class="dbc-history-table-th">Server</th>';
    html += '<th class="dbc-history-table-th">Database</th>';
    html += '<th class="dbc-history-table-th">Started</th>';
    html += '<th class="dbc-history-table-th">Completed</th>';
    html += '<th class="dbc-history-table-th">Duration</th>';
    html += '<th class="dbc-history-table-th">Status</th>';
    html += '</tr></thead><tbody>';

    data.forEach(function(op) {
        html += dbc_renderDayDetailOpRow(op);
    });

    html += '</tbody></table>';
    container.innerHTML = html;
}

/* Builds the markup for one operation row in the day-detail table, plus its
   expandable error/output detail row when present. */
function dbc_renderDayDetailOpRow(op) {
    var isFailed = op.status === 'FAILED';
    var isWarning = op.status === 'ERRORS_FOUND';
    var rowState = isFailed ? ' dbc-row-failed' : (isWarning ? ' dbc-row-warning' : '');
    var hasError = op.error_details && op.error_details.length > 0;
    var hasSummary = op.dbcc_summary_output && op.dbcc_summary_output.length > 0;
    var isExpandable = hasError || hasSummary;

    var rowClass = 'dbc-history-row' + rowState;
    var rowAttrs = '';
    if (isExpandable) {
        rowAttrs = ' data-action-click="dbc-toggle-detail" data-action-dbc-logid="' + op.log_id + '"';
    }

    var html = '<tr class="' + rowClass + '"' + rowAttrs + '>';
    html += '<td class="dbc-history-table-td"><span class="dbc-op-badge ' + dbc_opBadgeClass(op.operation) + '">'
        + cc_escapeHtml(op.operation) + '</span>';
    if (op.check_mode) {
        html += ' <span class="dbc-annotation">' + cc_escapeHtml(op.check_mode) + '</span>';
    }
    html += '</td>';
    html += '<td class="dbc-history-table-td">' + cc_escapeHtml(op.server_name);
    if (op.executed_on_server && op.executed_on_server !== op.server_name) {
        html += ' <span class="dbc-annotation">(' + cc_escapeHtml(op.executed_on_server) + ')</span>';
    }
    html += '</td>';
    html += '<td class="dbc-history-table-td">' + cc_escapeHtml(op.database_name) + '</td>';
    html += '<td class="dbc-history-table-td">' + dbc_formatTimestamp(op.started_dttm) + '</td>';
    html += '<td class="dbc-history-table-td">' + dbc_formatTimestamp(op.completed_dttm) + '</td>';
    html += '<td class="dbc-history-table-td">' + dbc_formatDuration(op.duration_seconds) + '</td>';
    html += '<td class="dbc-history-table-td"><span class="dbc-status-badge ' + dbc_statusBadgeClass(op.status) + '">'
        + cc_escapeHtml(op.status) + '</span>';
    if (isExpandable) {
        html += ' <span class="dbc-inline-chevron">&#9660;</span>';
    }
    html += '</td>';
    html += '</tr>';

    if (isExpandable) {
        html += '<tr class="dbc-detail-row" id="dbc-detail-row-' + op.log_id + '">';
        html += '<td class="dbc-detail-td" colspan="7"><div class="dbc-detail-content">';
        if (hasError) {
            html += '<div class="dbc-detail-label">Error Details</div>';
            html += '<div class="dbc-detail-text dbc-error-text">' + cc_escapeHtml(op.error_details) + '</div>';
        }
        if (hasSummary) {
            if (hasError) {
                html += '<div class="dbc-detail-gap"></div>';
            }
            html += '<div class="dbc-detail-label">DBCC Output</div>';
            html += '<div class="dbc-detail-text">' + cc_escapeHtml(op.dbcc_summary_output) + '</div>';
        }
        html += '</div></td></tr>';
    }

    return html;
}

/* Toggles an operation's error/output detail row open or closed. */
function dbc_toggleDetailRow(target) {
    var logId = target.getAttribute('data-action-dbc-logid');
    var row = document.getElementById('dbc-detail-row-' + logId);
    if (row) {
        row.classList.toggle('dbc-expanded');
    }
}

/* Shared expand/collapse for the class-based accordion bodies (year, month). */
function dbc_toggleExpand(body, icon) {
    if (!body) {
        return;
    }
    if (body.classList.contains('dbc-expanded')) {
        body.classList.remove('dbc-expanded');
        if (icon) {
            icon.innerHTML = '&#9654;';
        }
    } else {
        body.classList.add('dbc-expanded');
        if (icon) {
            icon.innerHTML = '&#9660;';
        }
    }
}

/* ============================================================================
   FUNCTIONS: SCHEDULE OVERVIEW
   ----------------------------------------------------------------------------
   Fetches the schedule configuration, captures the admin flag, caches the
   rows for the modals, and renders the server list with click-through to
   the per-server detail modal.
   Prefix: dbc
   ============================================================================ */

/* Fetches the schedule overview, records the admin flag, and renders it. */
async function dbc_loadScheduleOverview() {
    try {
        var data = await cc_engineFetch('/api/dbcc/schedule');
        if (!data) {
            return;
        }
        if (data.Error) {
            return;
        }
        if (typeof data.IsAdmin !== 'undefined') {
            dbc_isAdmin = data.IsAdmin === true;
        }
        var schedules = data.Schedules;
        if (!schedules) {
            schedules = [];
        } else if (!Array.isArray(schedules)) {
            schedules = [schedules];
        }
        dbc_renderScheduleOverview(schedules);
    } catch (e) {
        /* Loaded once on boot; failure leaves the loading placeholder. */
    }
}

/* Groups the schedule rows by server and renders the clickable server list. */
function dbc_renderScheduleOverview(rows) {
    var container = document.getElementById('dbc-schedule-overview');

    if (!rows || rows.length === 0) {
        container.innerHTML = '<div class="dbc-no-activity">No DBCC schedules configured</div>';
        return;
    }

    dbc_currentScheduleData = rows;

    var servers = {};
    var serverOrder = [];
    rows.forEach(function(row) {
        if (!servers[row.server_name]) {
            servers[row.server_name] = { serverName: row.server_name, serverEnabled: row.server_enabled, databases: [] };
            serverOrder.push(row.server_name);
        }
        servers[row.server_name].databases.push(row);
    });

    var html = '<div class="dbc-schedule-list">';
    serverOrder.forEach(function(serverName) {
        html += dbc_renderScheduleServerRow(servers[serverName]);
    });
    html += '</div>';
    container.innerHTML = html;
}

/* Builds the markup for a single server row in the schedule overview. */
function dbc_renderScheduleServerRow(server) {
    var isDisabled = !server.serverEnabled;
    var dbCount = server.databases.length;
    var overrideCount = server.databases.filter(function(db) { return db.replica_override; }).length;
    var rowClass = 'dbc-schedule-row' + (isDisabled ? ' dbc-disabled' : '');

    var html = '<div class="' + rowClass + '" data-action-click="dbc-open-schedule" data-action-dbc-server="' + cc_escapeHtml(server.serverName) + '">';
    html += '<span class="dbc-schedule-server">' + cc_escapeHtml(server.serverName) + '</span>';
    if (overrideCount > 0) {
        html += '<span class="dbc-schedule-override" title="' + overrideCount + ' database(s) with replica override">&#9888; ' + overrideCount + '</span>';
    } else {
        html += '<span></span>';
    }
    html += '<span class="dbc-schedule-count">' + dbCount + ' database(s)</span>';
    html += '<span class="dbc-schedule-status">';
    html += isDisabled
        ? '<span class="dbc-status-badge dbc-failed">Disabled</span>'
        : '<span class="dbc-status-badge dbc-success">Active</span>';
    html += '</span>';
    html += '</div>';
    return html;
}

/* ============================================================================
   FUNCTIONS: SCHEDULE DETAIL MODAL
   ----------------------------------------------------------------------------
   Opens the static server-schedule modal and renders the per-database
   schedule table. The edit pencil is rendered only for admin users.
   Prefix: dbc
   ============================================================================ */

/* Opens the schedule detail modal for the clicked server. */
function dbc_openScheduleModal(target) {
    var serverName = target.getAttribute('data-action-dbc-server');
    dbc_currentScheduleServer = serverName;
    var serverDbs = dbc_currentScheduleData.filter(function(row) { return row.server_name === serverName; });

    document.getElementById('dbc-schedule-title').textContent = serverName + ' \u2014 DBCC Schedule';
    dbc_renderScheduleDetail(serverDbs);
    document.getElementById('dbc-modal-schedule').classList.remove('cc-hidden');
}

/* Closes the schedule detail modal. Ignores clicks bubbling from the interior. */
function dbc_closeScheduleModal(target, event) {
    if (event && target && target.id === 'dbc-modal-schedule' && event.target !== target) {
        return;
    }
    document.getElementById('dbc-modal-schedule').classList.add('cc-hidden');
    dbc_currentScheduleServer = null;
}

/* Re-renders the open schedule detail modal from the current cached data. */
function dbc_refreshScheduleModal() {
    if (!dbc_currentScheduleServer) {
        return;
    }
    var serverDbs = dbc_currentScheduleData.filter(function(row) { return row.server_name === dbc_currentScheduleServer; });
    dbc_renderScheduleDetail(serverDbs);
}

/* Renders the per-database schedule table inside the detail modal. */
function dbc_renderScheduleDetail(databases) {
    var body = document.getElementById('dbc-schedule-body');

    if (!databases || databases.length === 0) {
        body.innerHTML = '<div class="dbc-no-activity">No databases configured</div>';
        return;
    }

    var html = '<table class="dbc-detail-table"><thead><tr>';
    html += '<th class="dbc-detail-table-th dbc-detail-override-col"></th>';
    html += '<th class="dbc-detail-table-th">Database</th>';
    html += '<th class="dbc-detail-table-th">Mode</th>';
    html += '<th class="dbc-detail-table-th">CHECKDB</th>';
    html += '<th class="dbc-detail-table-th">CHECKALLOC</th>';
    html += '<th class="dbc-detail-table-th">CHECKCATALOG</th>';
    html += '<th class="dbc-detail-table-th">CHECKCONST.</th>';
    if (dbc_isAdmin) {
        html += '<th class="dbc-detail-table-th"></th>';
    }
    html += '</tr></thead><tbody>';

    databases.forEach(function(row) {
        html += dbc_renderScheduleDetailRow(row);
    });

    html += '</tbody></table>';
    body.innerHTML = html;
}

/* Builds the markup for a single database row in the schedule detail table. */
function dbc_renderScheduleDetailRow(row) {
    var isDisabled = !row.is_enabled || !row.server_enabled;
    var hasOverride = row.replica_override ? true : false;
    var rowClass = 'dbc-detail-table-row' + (isDisabled ? ' dbc-disabled' : '');

    var html = '<tr class="' + rowClass + '">';
    html += '<td class="dbc-detail-table-td dbc-detail-override-col">';
    if (hasOverride) {
        html += '<span class="dbc-detail-override-icon" title="Replica override: ' + cc_escapeHtml(row.replica_override) + '">&#9888;</span>';
    }
    html += '</td>';
    html += '<td class="dbc-detail-table-td dbc-detail-db">' + cc_escapeHtml(row.database_name) + '</td>';
    html += '<td class="dbc-detail-table-td dbc-detail-mode">' + dbc_formatCheckMode(row.check_mode) + '</td>';
    html += '<td class="dbc-detail-table-td">' + dbc_formatScheduleCell(row.checkdb_enabled, row.checkdb_run_day, row.checkdb_run_time) + '</td>';
    html += '<td class="dbc-detail-table-td">' + dbc_formatScheduleCell(row.checkalloc_enabled, row.checkalloc_run_day, row.checkalloc_run_time) + '</td>';
    html += '<td class="dbc-detail-table-td">' + dbc_formatScheduleCell(row.checkcatalog_enabled, row.checkcatalog_run_day, row.checkcatalog_run_time) + '</td>';
    html += '<td class="dbc-detail-table-td">' + dbc_formatScheduleCell(row.checkconstraints_enabled, row.checkconstraints_run_day, row.checkconstraints_run_time) + '</td>';
    if (dbc_isAdmin) {
        html += '<td class="dbc-detail-table-td"><span class="dbc-edit-icon" data-action-click="dbc-open-edit" data-action-dbc-schedid="'
            + row.schedule_id + '" title="Edit schedule">&#128197;</span></td>';
    }
    html += '</tr>';
    return html;
}

/* ============================================================================
   FUNCTIONS: SCHEDULE EDIT MODAL
   ----------------------------------------------------------------------------
   Opens the static edit modal for a single database schedule: check-mode and
   replica-override badge pills, per-operation enable toggles with day/time
   selects, and the save orchestration that posts each changed value to its
   endpoint. Admin-only; the edit pencil that opens it is rendered only for
   admins, and the endpoints enforce admin server-side.
   Prefix: dbc
   ============================================================================ */

/* Opens the edit modal and loads the schedule detail for the given schedule. */
async function dbc_openEditModal(target) {
    var scheduleId = target.getAttribute('data-action-dbc-schedid');
    dbc_editScheduleId = parseInt(scheduleId, 10);
    document.getElementById('dbc-edit-body').innerHTML = '<div class="dbc-loading">Loading...</div>';
    document.getElementById('dbc-edit-actions').innerHTML = '';
    document.getElementById('dbc-modal-edit').classList.remove('cc-hidden');

    try {
        var data = await cc_engineFetch('/api/dbcc/schedule-detail?schedule_id=' + dbc_editScheduleId);
        if (!data || data.Error) {
            document.getElementById('dbc-edit-body').innerHTML = '<div class="dbc-no-activity">Failed to load schedule</div>';
            return;
        }
        dbc_renderEditForm(data);
    } catch (e) {
        document.getElementById('dbc-edit-body').innerHTML = '<div class="dbc-no-activity">Failed to load schedule</div>';
    }
}

/* Closes the edit modal. Ignores clicks bubbling from the dialog interior. */
function dbc_closeEditModal(target, event) {
    if (event && target && target.id === 'dbc-modal-edit' && event.target !== target) {
        return;
    }
    document.getElementById('dbc-modal-edit').classList.add('cc-hidden');
    dbc_editScheduleId = null;
    dbc_editOriginalCheckMode = null;
}

/* Renders the edit form body and footer for the loaded schedule detail. */
function dbc_renderEditForm(data) {
    document.getElementById('dbc-edit-title').textContent = data.database_name + ' \u2014 ' + data.server_name;

    var isAGListener = data.server_type === 'AG_LISTENER';
    var currentOverride = data.replica_override || null;
    var currentCheckMode = data.check_mode || 'NONE';
    dbc_editOriginalCheckMode = currentCheckMode;

    var html = '';
    html += '<div class="dbc-edit-section-header">Database Options</div>';
    html += dbc_renderCheckModeRow(currentCheckMode);
    if (isAGListener) {
        html += dbc_renderReplicaRow(currentOverride);
    }
    html += '<div class="dbc-edit-section-header">Operations</div>';
    dbc_OPERATION_KEYS.forEach(function(opDef) {
        html += dbc_renderEditOpRow(opDef, data);
    });
    html += '<div class="dbc-edit-status" id="dbc-edit-status"></div>';

    document.getElementById('dbc-edit-body').innerHTML = html;
    document.getElementById('dbc-edit-actions').innerHTML =
        '<button class="cc-dialog-btn-cancel" data-action-click="dbc-close-edit">Cancel</button>'
        + '<button class="cc-dialog-btn-primary" data-action-click="dbc-save-edits">Save Changes</button>';
}

/* Builds the check-mode badge-pill row. */
function dbc_renderCheckModeRow(currentCheckMode) {
    var html = '<div class="dbc-edit-option-row">';
    html += '<span class="dbc-edit-option-label">Check mode</span>';
    html += '<div class="dbc-edit-option-badges" id="dbc-checkmode-group">';
    dbc_CHECK_MODE_OPTIONS.forEach(function(opt) {
        var activeClass = opt.value === currentCheckMode ? ' dbc-active' : '';
        html += '<span class="dbc-badge-pill ' + opt.pill + activeClass + '" '
            + 'data-action-click="dbc-select-mode" data-action-dbc-value="' + opt.value + '">'
            + opt.label + '</span>';
    });
    html += '</div></div>';
    return html;
}

/* Builds the replica-override badge-pill row (AG listener databases only). */
function dbc_renderReplicaRow(currentOverride) {
    var html = '<div class="dbc-edit-option-row">';
    html += '<span class="dbc-edit-option-label">Target replica</span>';
    html += '<div class="dbc-edit-option-badges" id="dbc-replica-group">';
    dbc_REPLICA_OPTIONS.forEach(function(opt) {
        var isActive = (opt.value === '' && !currentOverride) || (opt.value === currentOverride);
        var activeClass = isActive ? ' dbc-active' : '';
        html += '<span class="dbc-badge-pill ' + opt.pill + activeClass + '" '
            + 'data-action-click="dbc-select-replica" data-action-dbc-value="' + opt.value + '">'
            + opt.label + '</span>';
    });
    html += '</div></div>';
    return html;
}

/* Builds one operation's enable toggle plus day and time selects. */
function dbc_renderEditOpRow(opDef, data) {
    var enabled = data[opDef.key + '_enabled'];
    var day = data[opDef.key + '_run_day'];
    var time = data[opDef.key + '_run_time'];
    var disabledAttr = enabled ? '' : ' disabled';

    var html = '<div class="dbc-edit-op-row">';
    html += '<span class="dbc-edit-op-label">' + opDef.label + '</span>';
    html += '<span class="dbc-edit-toggle" data-action-click="dbc-toggle-op" data-action-dbc-op="' + opDef.key + '">';
    html += '<span class="dbc-edit-toggle-track' + (enabled ? ' dbc-on' : '') + '" id="dbc-toggle-' + opDef.key + '">';
    html += '<span class="dbc-edit-toggle-knob"></span>';
    html += '</span></span>';

    html += '<select class="dbc-edit-select" id="dbc-day-' + opDef.key + '"' + disabledAttr + '>';
    html += '<option value="">Day...</option>';
    dbc_DAY_OPTIONS.forEach(function(d) {
        var sel = day === d.value ? ' selected' : '';
        html += '<option value="' + d.value + '"' + sel + '>' + d.label + '</option>';
    });
    html += '</select>';

    html += '<select class="dbc-edit-select" id="dbc-time-' + opDef.key + '"' + disabledAttr + '>';
    html += '<option value="">Time...</option>';
    dbc_TIME_OPTIONS.forEach(function(t) {
        var sel = time === t.value ? ' selected' : '';
        html += '<option value="' + t.value + '"' + sel + '>' + t.label + '</option>';
    });
    html += '</select>';

    html += '</div>';
    return html;
}

/* Selects a check-mode badge pill, warning when NONE would disable CHECKDB. */
function dbc_selectCheckMode(target) {
    dbc_activatePill(target);
    var selectedMode = target.getAttribute('data-action-dbc-value');
    var statusEl = document.getElementById('dbc-edit-status');

    if (selectedMode === 'NONE') {
        var checkdbTrack = document.getElementById('dbc-toggle-' + dbc_OPERATION_KEYS[0].key);
        if (checkdbTrack && checkdbTrack.classList.contains('dbc-on')) {
            statusEl.textContent = 'CHECKDB will be disabled when check mode is set to None';
            statusEl.className = 'dbc-edit-status dbc-error';
        }
    } else if (statusEl.textContent.toLowerCase().indexOf('check mode') !== -1) {
        statusEl.textContent = '';
        statusEl.className = 'dbc-edit-status';
    }
}

/* Selects a replica-override badge pill. */
function dbc_selectReplica(target) {
    dbc_activatePill(target);
}

/* Marks the clicked pill active and clears the active state from its siblings. */
function dbc_activatePill(pill) {
    var group = pill.parentElement;
    var pills = group.querySelectorAll('.dbc-badge-pill');
    pills.forEach(function(p) { p.classList.remove('dbc-active'); });
    pill.classList.add('dbc-active');
}

/* Toggles an operation on or off, enabling or disabling its day/time selects. */
function dbc_toggleEditOp(target) {
    var opKey = target.getAttribute('data-action-dbc-op');
    var track = document.getElementById('dbc-toggle-' + opKey);
    var daySelect = document.getElementById('dbc-day-' + opKey);
    var timeSelect = document.getElementById('dbc-time-' + opKey);
    var statusEl = document.getElementById('dbc-edit-status');

    if (track.classList.contains('dbc-on')) {
        track.classList.remove('dbc-on');
        daySelect.disabled = true;
        timeSelect.disabled = true;
    } else {
        if (opKey === 'checkdb' && dbc_getSelectedCheckMode() === 'NONE') {
            statusEl.textContent = 'Set check mode to Physical Only or Full before enabling CHECKDB';
            statusEl.className = 'dbc-edit-status dbc-error';
            return;
        }
        track.classList.add('dbc-on');
        daySelect.disabled = false;
        timeSelect.disabled = false;
    }

    statusEl.textContent = '';
    statusEl.className = 'dbc-edit-status';
}

/* Returns the currently selected check-mode value, or null. */
function dbc_getSelectedCheckMode() {
    var group = document.getElementById('dbc-checkmode-group');
    if (!group) {
        return null;
    }
    var active = group.querySelector('.dbc-badge-pill.dbc-active');
    return active ? active.getAttribute('data-action-dbc-value') : null;
}

/* Returns the selected replica override (null when Default), or undefined when absent. */
function dbc_getSelectedReplicaOverride() {
    var group = document.getElementById('dbc-replica-group');
    if (!group) {
        return undefined;
    }
    var active = group.querySelector('.dbc-badge-pill.dbc-active');
    if (!active) {
        return undefined;
    }
    var val = active.getAttribute('data-action-dbc-value');
    return val === '' ? null : val;
}

/* Saves all changed edit-form values, posting each to its endpoint in turn. */
async function dbc_saveScheduleEdits() {
    if (!dbc_editScheduleId) {
        return;
    }

    var statusEl = document.getElementById('dbc-edit-status');
    var saveBtn = document.querySelector('#dbc-edit-actions .cc-dialog-btn-primary');

    statusEl.textContent = 'Saving...';
    statusEl.className = 'dbc-edit-status';
    if (saveBtn) {
        saveBtn.disabled = true;
    }

    var errors = [];
    var saved = 0;

    var selectedCheckMode = dbc_getSelectedCheckMode();
    if (selectedCheckMode !== null && selectedCheckMode !== dbc_editOriginalCheckMode) {
        var modeResult = await dbc_postScheduleChange('/api/dbcc/schedule/check-mode', {
            schedule_id: dbc_editScheduleId,
            check_mode: selectedCheckMode
        });
        if (modeResult.ok) {
            saved++;
        } else {
            errors.push('Check Mode: ' + modeResult.error);
        }
    }

    if (errors.length > 0) {
        dbc_finishSave(statusEl, saveBtn, errors, saved, false);
        return;
    }

    for (var i = 0; i < dbc_OPERATION_KEYS.length; i++) {
        var opDef = dbc_OPERATION_KEYS[i];
        var track = document.getElementById('dbc-toggle-' + opDef.key);
        var daySelect = document.getElementById('dbc-day-' + opDef.key);
        var timeSelect = document.getElementById('dbc-time-' + opDef.key);

        var opResult = await dbc_postScheduleChange('/api/dbcc/schedule/update', {
            schedule_id: dbc_editScheduleId,
            operation: opDef.op,
            enabled: track.classList.contains('dbc-on'),
            run_day: daySelect.value ? parseInt(daySelect.value, 10) : null,
            run_time: timeSelect.value || null
        });
        if (opResult.ok) {
            saved++;
        } else {
            errors.push(opDef.op + ': ' + opResult.error);
        }
    }

    var replicaOverride = dbc_getSelectedReplicaOverride();
    if (replicaOverride !== undefined) {
        var replicaResult = await dbc_postScheduleChange('/api/dbcc/schedule/replica-override', {
            schedule_id: dbc_editScheduleId,
            replica_override: replicaOverride
        });
        if (replicaResult.ok) {
            saved++;
        } else {
            errors.push('Replica Override: ' + replicaResult.error);
        }
    }

    dbc_finishSave(statusEl, saveBtn, errors, saved, true);
}

/* Posts a single schedule change and normalizes the result to {ok, error}. */
async function dbc_postScheduleChange(url, payload) {
    try {
        var result = await cc_engineFetch(url, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload)
        });
        if (result && result.Success) {
            return { ok: true };
        }
        return { ok: false, error: (result && result.Error) ? result.Error : 'Unknown error' };
    } catch (e) {
        return { ok: false, error: e.message };
    }
}

/* Renders the save outcome and, on full success, refreshes and closes the modal. */
function dbc_finishSave(statusEl, saveBtn, errors, saved, allowClose) {
    if (saveBtn) {
        saveBtn.disabled = false;
    }

    if (errors.length > 0) {
        statusEl.textContent = 'Errors: ' + errors.join('; ');
        statusEl.className = 'dbc-edit-status dbc-error';
        return;
    }

    statusEl.textContent = saved + ' item(s) updated';
    statusEl.className = 'dbc-edit-status dbc-success';

    if (allowClose) {
        dbc_loadScheduleOverview().then(function() {
            dbc_refreshScheduleModal();
        });
        setTimeout(dbc_closeEditModal, 600);
    }
}

/* ============================================================================
   FUNCTIONS: FORMATTING
   ----------------------------------------------------------------------------
   Page-specific formatters and class-name mappers with no shared-utility
   equivalent: DBCC duration/relative-time rendering, the status and
   operation badge class mappers, check-mode and schedule-cell rendering,
   and the build-once time-of-day option list.
   Prefix: dbc
   ============================================================================ */

/* Formats a duration in seconds as a compact h/m/s string. */
function dbc_formatDuration(seconds) {
    if (seconds === null || seconds === undefined) {
        return '-';
    }
    if (seconds < 60) {
        return Math.round(seconds) + 's';
    }
    if (seconds < 3600) {
        return Math.floor(seconds / 60) + 'm ' + Math.round(seconds % 60) + 's';
    }
    return Math.floor(seconds / 3600) + 'h ' + Math.floor((seconds % 3600) / 60) + 'm';
}

/* Formats a datetime string as a short relative/absolute label for the day list. */
function dbc_formatDateShort(dateStr) {
    if (!dateStr) {
        return '-';
    }
    var date = new Date(dateStr);
    var diffDays = Math.floor((new Date() - date) / 86400000);
    if (diffDays === 0) {
        return date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    }
    if (diffDays === 1) {
        return 'Yesterday';
    }
    if (diffDays < 7) {
        return diffDays + 'd ago';
    }
    return date.toLocaleDateString();
}

/* Extracts the time-of-day portion from a "yyyy-MM-dd HH:mm:ss" timestamp. */
function dbc_formatTimestamp(ts) {
    if (!ts) {
        return '-';
    }
    var parts = ts.split(' ');
    return parts.length > 1 ? parts[1] : ts;
}

/* Formats an "HH:mm" schedule time as a 12-hour time label. */
function dbc_formatTime(timeStr) {
    if (!timeStr) {
        return '-';
    }
    var parts = timeStr.split(':');
    if (parts.length < 2) {
        return timeStr;
    }
    var hours = parseInt(parts[0], 10);
    var ampm = hours >= 12 ? 'PM' : 'AM';
    var displayHour = hours % 12;
    if (displayHour === 0) {
        displayHour = 12;
    }
    return displayHour + ':' + parts[1] + ' ' + ampm;
}

/* Maps an execution status to its status-badge state class. */
function dbc_statusBadgeClass(status) {
    switch (status) {
        case 'SUCCESS':      return 'dbc-success';
        case 'FAILED':       return 'dbc-failed';
        case 'ERRORS_FOUND': return 'dbc-errors-found';
        case 'IN_PROGRESS':  return 'dbc-running';
        case 'PENDING':      return 'dbc-pending';
        default:             return 'dbc-never-run';
    }
}

/* Maps a DBCC operation name to its operation-badge state class. */
function dbc_opBadgeClass(operation) {
    switch (operation) {
        case 'CHECKDB':          return 'dbc-op-checkdb';
        case 'CHECKALLOC':       return 'dbc-op-checkalloc';
        case 'CHECKCATALOG':     return 'dbc-op-checkcatalog';
        case 'CHECKCONSTRAINTS': return 'dbc-op-checkconstraints';
        case 'CHECKTABLE':       return 'dbc-op-checktable';
        default:                 return '';
    }
}

/* Renders a check-mode value as a labeled, color-coded span for the detail table. */
function dbc_formatCheckMode(mode) {
    if (!mode || mode === 'NONE') {
        return '<span class="dbc-mode-off">&mdash;</span>';
    }
    if (mode === 'PHYSICAL_ONLY') {
        return '<span class="dbc-mode-physical">PHYSICAL</span>';
    }
    if (mode === 'FULL') {
        return '<span class="dbc-mode-full">FULL</span>';
    }
    return '<span class="dbc-mode-physical">' + cc_escapeHtml(mode) + '</span>';
}

/* Renders a single operation's schedule cell (day + time, or a dash when off). */
function dbc_formatScheduleCell(enabled, runDay, runTime) {
    if (!enabled) {
        return '<span class="dbc-detail-cell dbc-disabled">&mdash;</span>';
    }
    var dayName = cc_DAY_NAMES[runDay] || '?';
    return '<span class="dbc-detail-cell dbc-enabled">' + dayName + ' ' + dbc_formatTime(runTime) + '</span>';
}

/* Builds the hourly time-of-day option list used by the edit-form time selects. */
function dbc_buildTimeOptions() {
    var options = [];
    for (var h = 0; h < 24; h++) {
        var ampm = h >= 12 ? 'PM' : 'AM';
        var displayH = h % 12;
        if (displayH === 0) {
            displayH = 12;
        }
        var hh = h < 10 ? '0' + h : '' + h;
        options.push({ value: hh + ':00', label: displayH + ':00 ' + ampm });
    }
    return options;
}

/* ============================================================================
   FUNCTIONS: PAGE LIFECYCLE HOOKS
   ----------------------------------------------------------------------------
   Callbacks invoked by cc-shared.js: manual page refresh, tab resume,
   session expiry, and orchestrator process completion. Each delegates to the
   relevant data loaders.
   Prefix: dbc
   ============================================================================ */

/* Reloads all panels when the user clicks the page refresh button. */
function dbc_onPageRefresh() {
    dbc_loadAllData();
    dbc_loadLiveProgress();
}

/* Reloads all panels when the tab regains visibility. */
function dbc_onPageResumed() {
    dbc_loadAllData();
    dbc_loadLiveProgress();
}

/* Stops live polling when the session expires. */
function dbc_onSessionExpired() {
    dbc_stopLivePolling();
}

/* Refreshes the execution panels when a DBCC engine process completes. */
function dbc_onEngineProcessCompleted() {
    dbc_loadTodaysExecutions();
    dbc_loadExecutionHistory();
}

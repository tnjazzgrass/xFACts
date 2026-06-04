/* ============================================================================
   xFACts Control Center - JobFlow Monitoring page script (jobflow-monitoring.js)
   Location: E:\xFACts-ControlCenter\public\js\jobflow-monitoring.js
   Version: Tracked in dbo.System_Metadata (component: JobFlow)

   JobFlow Monitoring page script for the Job Flow Monitoring page.

   FILE ORGANIZATION
   -----------------
   CONSTANTS: ENGINE PROCESSES
   CONSTANTS: STATIC LOOKUPS
   STATE: PAGE STATE
   FUNCTIONS: INITIALIZATION
   FUNCTIONS: ACTION DISPATCH TABLES
   FUNCTIONS: REFRESH ORCHESTRATION
   FUNCTIONS: SECTION DATA LOADERS
   FUNCTIONS: SLIDEOUT CONTROL
   FUNCTIONS: FLOW DAY DETAILS
   FUNCTIONS: HISTORY DAY DETAILS
   FUNCTIONS: JOB TABLE BUILDER
   FUNCTIONS: APP SERVER TASKS
   FUNCTIONS: LIVE ACTIVITY RENDER
   FUNCTIONS: PROCESS STATUS RENDER
   FUNCTIONS: DAILY SUMMARY RENDER
   FUNCTIONS: STALL SLIDEOUTS
   FUNCTIONS: EXECUTION HISTORY RENDER
   FUNCTIONS: DAY DETAILS RENDER
   FUNCTIONS: PENDING AND AD-HOC SLIDEOUTS
   FUNCTIONS: CONFIGSYNC MODAL
   FUNCTIONS: CONFIGSYNC FORMS
   FUNCTIONS: CONFIGSYNC SAVE
   FUNCTIONS: UTILITIES
   FUNCTIONS: PAGE LIFECYCLE HOOKS
   ============================================================================ */

/* ============================================================================
   CONSTANTS: ENGINE PROCESSES
   ----------------------------------------------------------------------------
   The orchestrator process map consumed by the shared engine-events bootloader
   in cc-shared.js. Declared with var (not const) so it becomes a window
   property the shared module can resolve by the jfm_ prefix. The shared module
   reads the slug for DOM id resolution on the engine card.
   Prefix: jfm
   ============================================================================ */

/* Maps the JobFlow orchestrator process name to its engine-card slug. */
var jfm_ENGINE_PROCESSES = {
    'Monitor-JobFlow': { slug: 'jobflow' }
};

/* ============================================================================
   CONSTANTS: STATIC LOOKUPS
   ----------------------------------------------------------------------------
   Page-wide immutable lookups: month names for history labels, the process
   short-name and icon maps for the status grid, and the validation verdict
   styling map for the day-detail slideout.
   Prefix: jfm
   ============================================================================ */

/* Month names indexed 1-12 (index 0 unused) for history display. */
const jfm_MONTH_NAMES = ['', 'January', 'February', 'March', 'April', 'May', 'June',
                         'July', 'August', 'September', 'October', 'November', 'December'];

/* Status-card icon glyphs (HTML entities) keyed by process short name. */
const jfm_PROCESS_ICONS = {
    'Flow Config Sync':        '&#x21BB;',
    'Flow Detection':          '&#x25C9;',
    'Completed Jobs Capture':  '&#x2913;',
    'Flow Progress':           '&#x25B6;',
    'Flow State Transitions':  '&#x21C4;',
    'Stall Detection':         '&#x23F8;',
    'Flow Validation':         '&#x2714;',
    'Missing Flows':           '&#x26A0;'
};

/* ============================================================================
   STATE: PAGE STATE
   ----------------------------------------------------------------------------
   Mutable page state: the live polling timer and its configured interval, the
   page-load date for the daily reload check, the slideout job filter, the
   cached datasets the slideouts re-render from, and the app-task staging maps.
   Prefix: jfm
   ============================================================================ */

/* Live-section polling interval in seconds (overridden from GlobalConfig). */
var jfm_pageRefreshInterval = 30;

/* Handle for the live-section polling timer. */
var jfm_livePollingTimer = null;

/* Handle for the daily reload-check timer. */
var jfm_dailyReloadTimer = null;

/* The date the page was loaded, used to trigger a reload after midnight. */
var jfm_pageLoadDate = new Date().toDateString();

/* Current slideout job filter: 'ALL' or 'FAILED'. */
var jfm_slideoutJobFilter = 'ALL';

/* Cached pending-queue jobs for the pending slideout. */
var jfm_currentPendingData = null;

/* Cached ad-hoc jobs for the ad-hoc slideout. */
var jfm_currentAdhocData = null;

/* Cached stall episodes for the stall slideout. */
var jfm_currentStallEpisodes = [];

/* Original app-task enablement keyed by flow then server. */
var jfm_appTasksOriginalState = {};

/* Staged app-task changes keyed by flow ({ from, to }). */
var jfm_appTasksPendingChanges = {};

/* The list of application servers returned by the app-tasks API. */
var jfm_appTasksServerList = [];

/* The full app-tasks API response, retained for grid re-render. */
var jfm_appTasksData = null;

/* Cached configsync API response. */
var jfm_configSyncData = null;

/* Currently selected configsync flow object. */
var jfm_configSyncSelectedFlow = null;

/* Task Scheduler data for the selected configsync flow. */
var jfm_configSyncTaskSchedule = null;

/* ============================================================================
   FUNCTIONS: INITIALIZATION
   ----------------------------------------------------------------------------
   The page entry point invoked by the cc-shared bootloader once the module
   loads. Wires the shared engine card, registers the page's delegated action
   listeners, loads the live polling interval, performs the initial data load,
   and starts the page-local timers.
   Prefix: jfm
   ============================================================================ */

/* Page entry point. Called by the cc-shared bootloader after this module
   loads. Connects shared engine events, registers delegated click/change
   listeners that route jfm- actions to the page dispatch tables, then loads
   data and starts the live and daily timers. */
function jfm_init() {
    cc_connectEngineEvents();

    document.body.addEventListener('click', function(event) {
        jfm_handleAction('click', jfm_clickActions, event);
    });
    document.body.addEventListener('change', function(event) {
        jfm_handleAction('change', jfm_changeActions, event);
    });

    jfm_loadRefreshInterval().then(function() {
        jfm_refreshAll();
        jfm_startLivePolling();
    });

    jfm_startDailyReloadCheck();
}

/* ============================================================================
   FUNCTIONS: ACTION DISPATCH TABLES
   ----------------------------------------------------------------------------
   The delegated dispatcher and the click/change action maps. Handlers receive
   (target, event); argument values travel on data-* attributes of the target
   element and are read inside the handler.
   Prefix: jfm
   ============================================================================ */

/* Delegated action dispatcher for the page. Finds the nearest element
   declaring data-action-<event>, routes jfm- values to the supplied page
   dispatch table, and invokes the handler with (target, event). cc- values
   are handled by the shared dispatcher and ignored here. */
function jfm_handleAction(eventName, table, event) {
    const attr = 'data-action-' + eventName;
    const target = event.target.closest('[' + attr + ']');
    if (!target) {
        return;
    }
    const action = target.getAttribute(attr);
    if (!action || action.indexOf('jfm-') !== 0) {
        return;
    }
    const handler = table[action];
    if (handler) {
        handler(target, event);
    }
}

/* Click-action dispatch table for page-local jfm- click actions. */
const jfm_clickActions = {
    'jfm-open-pending-queue':       function(target, event) { jfm_openPendingQueueSlideout(); },
    'jfm-open-tasks':               function(target, event) { jfm_openTasksModal(); },
    'jfm-close-tasks':              function(target, event) { jfm_closeTasksModal(target, event); },
    'jfm-close-slideout':          function(target, event) { jfm_closeSlideout(target, event); },
    'jfm-close-confirm':           function(target, event) { jfm_closeConfirmModal(target, event); },
    'jfm-show-apply-confirmation': function(target, event) { jfm_showApplyConfirmation(); },
    'jfm-cancel-all-changes':      function(target, event) { jfm_cancelAllChanges(); },
    'jfm-apply-all-changes':       function(target, event) { jfm_applyAllChanges(); },
    'jfm-stage-task-change':       function(target, event) { jfm_stageTaskChange(target.getAttribute('data-flow-code'), target.getAttribute('data-server')); },
    'jfm-toggle-failed-filter':    function(target, event) { jfm_toggleFailedFilter(); },
    'jfm-open-stall-episodes':     function(target, event) { jfm_openStallEpisodesSlideout(); },
    'jfm-load-stall-history':      function(target, event) { jfm_loadStallHistory(); },
    'jfm-open-adhoc':              function(target, event) { jfm_openAdhocSlideout(); },
    'jfm-open-configsync':         function(target, event) { jfm_openConfigSyncModal(); },
    'jfm-close-configsync':        function(target, event) { jfm_closeConfigSyncModal(target, event); },
    'jfm-close-cs-confirm':        function(target, event) { jfm_closeConfigSyncConfirmation(target, event); },
    'jfm-confirm-and-save-configsync': function(target, event) { jfm_confirmAndSaveConfigSync(); },
    'jfm-load-flow-day':           function(target, event) { jfm_loadFlowDayDetails(parseInt(target.getAttribute('data-job-sqnc-id'), 10), target.getAttribute('data-flow-code')); },
    'jfm-load-day':                function(target, event) { jfm_loadDayDetails(target.getAttribute('data-date')); },
    'jfm-toggle-year':             function(target, event) { jfm_toggleYear(target); },
    'jfm-toggle-month':            function(target, event) { jfm_toggleMonthGroup(target); },
    'jfm-select-flow-type':        function(target, event) { jfm_selectFlowType(target.getAttribute('data-flow-type'), target); },
    'jfm-save-configsync':         function(target, event) { jfm_saveConfigSync(); }
};

/* Change-action dispatch table for page-local jfm- change actions. */
const jfm_changeActions = {
    'jfm-configsync-flow-selected': function(target, event) { jfm_onConfigSyncFlowSelected(); },
    'jfm-cs-schedule-type-changed': function(target, event) { jfm_onCsScheduleTypeChanged(); }
};

/* ============================================================================
   FUNCTIONS: REFRESH ORCHESTRATION
   ----------------------------------------------------------------------------
   The live/event/manual refresh split. Live sections (Live Activity) refresh
   on the GlobalConfig polling timer; event-driven sections (Daily Summary,
   Process Status, Execution History) refresh when the orchestrator signals a
   completed process; manual refresh reloads everything.
   Prefix: jfm
   ============================================================================ */

/* Loads the live polling interval from GlobalConfig, falling back to the
   default when the endpoint is unavailable. */
async function jfm_loadRefreshInterval() {
    try {
        const data = await cc_engineFetch('/api/config/refresh-interval?page=jobflow');
        if (data) {
            jfm_pageRefreshInterval = data.interval || 30;
        }
    } catch (e) {
        // Endpoint unavailable; keep the default interval.
    }
}

/* Starts (or restarts) the live-section polling timer. */
function jfm_startLivePolling() {
    if (jfm_livePollingTimer) {
        clearInterval(jfm_livePollingTimer);
    }
    jfm_livePollingTimer = setInterval(jfm_refreshLiveSections, jfm_pageRefreshInterval * 1000);
}

/* Starts the once-a-minute check that reloads the page after midnight so the
   day-scoped views roll over to the new date. */
function jfm_startDailyReloadCheck() {
    jfm_dailyReloadTimer = setInterval(function() {
        if (new Date().toDateString() !== jfm_pageLoadDate) {
            location.reload();
        }
    }, 60000);
}

/* Refreshes the live sections (Live Activity) and the timestamp. */
function jfm_refreshLiveSections() {
    jfm_loadLiveActivity();
    jfm_updateTimestamp();
}

/* Refreshes the event-driven sections after an orchestrator completion. */
function jfm_refreshEventSections() {
    jfm_loadProcessStatus();
    jfm_loadDailySummary();
    jfm_loadExecutionHistory();
    jfm_updateTimestamp();
}

/* Refreshes every section (used on initial load and manual refresh). */
function jfm_refreshAll() {
    jfm_loadLiveActivity();
    jfm_loadProcessStatus();
    jfm_loadDailySummary();
    jfm_loadExecutionHistory();
    jfm_updateTimestamp();
}

/* Writes the current time into the shared last-update chrome element. */
function jfm_updateTimestamp() {
    const el = document.getElementById('cc-last-update');
    if (el) {
        el.textContent = new Date().toLocaleTimeString('en-US', { hour12: false });
    }
}

/* ============================================================================
   FUNCTIONS: SECTION DATA LOADERS
   ----------------------------------------------------------------------------
   Fetch-and-render entry points for each page section, using the shared fetch
   wrapper. Each tolerates a null return (hidden tab, idle, or expired session)
   and surfaces API errors via the shared alert modal.
   Prefix: jfm
   ============================================================================ */

/* Loads the Live Activity section (executing jobs + pending badge). */
function jfm_loadLiveActivity() {
    cc_engineFetch('/api/jobflow/live-activity')
        .then(function(data) {
            if (!data) return;
            if (data.error) { cc_showAlert('Live activity: ' + data.error); return; }
            jfm_renderExecutingJobs(data.executing || []);
            jfm_currentPendingData = data.pending || [];
            jfm_updatePendingBadge(jfm_currentPendingData.length);
            jfm_updateTimestamp();
        })
        .catch(function(err) { cc_showAlert('Failed to load live activity: ' + err.message); });
}

/* Loads the Process Status grid. */
function jfm_loadProcessStatus() {
    cc_engineFetch('/api/jobflow/status')
        .then(function(data) {
            if (!data) return;
            if (data.error) { cc_showAlert('Process status: ' + data.error); return; }
            jfm_renderProcessStatus(data.processes || [], data.stall_count, data.stall_threshold);
        })
        .catch(function(err) { cc_showAlert('Failed to load process status: ' + err.message); });
}

/* Loads the Daily Summary section. */
function jfm_loadDailySummary() {
    cc_engineFetch('/api/jobflow/todays-summary')
        .then(function(data) {
            if (!data) return;
            if (data.error) { cc_showAlert('Daily summary: ' + data.error); return; }
            jfm_renderDailySummary(data);
        })
        .catch(function(err) { cc_showAlert('Failed to load daily summary: ' + err.message); });
}

/* Loads the Execution History tree. */
function jfm_loadExecutionHistory() {
    cc_engineFetch('/api/jobflow/history')
        .then(function(data) {
            if (!data) return;
            if (data.error) { cc_showAlert('Execution history: ' + data.error); return; }
            jfm_renderExecutionHistory(data);
        })
        .catch(function(err) { cc_showAlert('Failed to load execution history: ' + err.message); });
}

/* ============================================================================
   FUNCTIONS: SLIDEOUT CONTROL
   ----------------------------------------------------------------------------
   Open/close mechanics for the flow/day/pending/ad-hoc/stall slideout, plus
   the job filter that re-renders the active slideout body. Open adds cc-open
   to the overlay then the inner dialog on the next frame so the slide
   transition runs; close reverses the inner dialog and removes cc-open from
   the overlay after the transition ends.
   Prefix: jfm
   ============================================================================ */

/* Opens the flow slideout, sliding the inner dialog in on the next frame. */
function jfm_openSlideout() {
    const overlay = document.getElementById('jfm-slideout-flow');
    const dialog = overlay.querySelector('.cc-dialog');
    overlay.classList.add('cc-open');
    requestAnimationFrame(function() {
        dialog.classList.add('cc-open');
    });
}

/* Closes the flow slideout, removing cc-open from the overlay once the inner
   dialog's slide-out transition completes. */
function jfm_closeSlideout(target, event) {
    const overlay = document.getElementById('jfm-slideout-flow');
    if (event && event.target !== target) {
        return;
    }
    const dialog = overlay.querySelector('.cc-dialog');
    dialog.classList.remove('cc-open');
    dialog.addEventListener('transitionend', function onEnd() {
        overlay.classList.remove('cc-open');
        dialog.removeEventListener('transitionend', onEnd);
    }, { once: true });
}

/* Sets the slideout title text. */
function jfm_setSlideoutTitle(title) {
    document.getElementById('jfm-slideout-title').textContent = title;
}

/* Toggles the slideout job filter between ALL and FAILED and re-renders. */
function jfm_toggleFailedFilter() {
    jfm_slideoutJobFilter = (jfm_slideoutJobFilter === 'FAILED') ? 'ALL' : 'FAILED';
    const body = document.getElementById('jfm-slideout-body');
    if (body._lastRender) {
        body._lastRender();
    }
}

/* Returns jobs filtered by the active slideout filter. */
function jfm_filterJobs(jobs) {
    if (jfm_slideoutJobFilter === 'FAILED') {
        return jobs.filter(function(j) { return j.is_failed; });
    }
    return jobs;
}

/* ============================================================================
   FUNCTIONS: FLOW DAY DETAILS
   ----------------------------------------------------------------------------
   Loads and renders the per-flow, per-day execution breakdown shown in the
   slideout when a flow row in the Daily Summary is clicked.
   Prefix: jfm
   ============================================================================ */

/* Loads the day's executions for one flow and renders them in the slideout. */
function jfm_loadFlowDayDetails(jobSqncId, flowCode) {
    jfm_slideoutJobFilter = 'ALL';
    jfm_setSlideoutTitle(flowCode + ' - Today');
    document.getElementById('jfm-slideout-body').innerHTML = '<div class="jfm-loading">Loading...</div>';
    jfm_openSlideout();

    cc_engineFetch('/api/jobflow/flow-day-details?job_sqnc_id=' + jobSqncId)
        .then(function(data) {
            if (!data) return;
            if (data.error) {
                document.getElementById('jfm-slideout-body').innerHTML = '<div class="cc-slide-empty">Error: ' + data.error + '</div>';
                return;
            }
            const body = document.getElementById('jfm-slideout-body');
            body._lastRender = function() { jfm_renderFlowDayDetails(data); };
            jfm_renderFlowDayDetails(data);
        })
        .catch(function(err) {
            document.getElementById('jfm-slideout-body').innerHTML = '<div class="cc-slide-empty">Failed to load: ' + err.message + '</div>';
        });
}

/* Renders the per-flow day execution groups into the slideout body. */
function jfm_renderFlowDayDetails(data) {
    const body = document.getElementById('jfm-slideout-body');

    if (!data.executions || data.executions.length === 0) {
        body.innerHTML = '<div class="cc-slide-empty">No executions found</div>';
        return;
    }

    var totalFailedJobs = 0;
    data.executions.forEach(function(exec) {
        if (exec.jobs) totalFailedJobs += exec.jobs.filter(function(j) { return j.is_failed; }).length;
    });

    var failedStatClass = 'cc-slide-stat';
    var failedStatAction = '';
    if (totalFailedJobs > 0) {
        failedStatClass += ' jfm-stat-clickable' + (jfm_slideoutJobFilter === 'FAILED' ? ' jfm-stat-filter-active' : '');
        failedStatAction = ' data-action-click="jfm-toggle-failed-filter"';
    }

    var html = '<div class="cc-slide-summary">';
    html += '<div class="cc-slide-stat"><div class="cc-slide-stat-label">Executions</div><div class="cc-slide-stat-value">' + data.execution_count + '</div></div>';
    html += '<div class="cc-slide-stat"><div class="cc-slide-stat-label">Total Jobs</div><div class="cc-slide-stat-value">' + data.total_jobs + '</div></div>';
    html += '<div class="' + failedStatClass + '"' + failedStatAction + '><div class="cc-slide-stat-label">Failed</div><div class="cc-slide-stat-value ' + (totalFailedJobs > 0 ? 'jfm-stat-value-failed' : '') + '">' + totalFailedJobs + '</div></div>';
    html += '<div class="cc-slide-stat"><div class="cc-slide-stat-label">Records</div><div class="cc-slide-stat-value">' + (data.total_records ? data.total_records.toLocaleString() : '-') + '</div></div>';
    html += '</div>';

    data.executions.forEach(function(exec) {
        var execFailedCount = exec.jobs ? exec.jobs.filter(function(j) { return j.is_failed; }).length : 0;
        if (jfm_slideoutJobFilter === 'FAILED' && execFailedCount === 0) return;

        var statusClass = (exec.execution_state === 'COMPLETE' || exec.execution_state === 'VALIDATED') ? 'complete' : (exec.execution_state === 'FAILED' ? 'failed' : 'detected');
        var hasFailures = exec.failed_jobs > 0;

        var durationDisplay = '-';
        if (exec.duration_seconds != null) {
            var h = Math.floor(exec.duration_seconds / 3600);
            var m = Math.floor((exec.duration_seconds % 3600) / 60);
            var s = exec.duration_seconds % 60;
            durationDisplay = String(h).padStart(2, '0') + ':' + String(m).padStart(2, '0') + ':' + String(s).padStart(2, '0');
        }

        var statusLabel = statusClass === 'complete' ? 'Complete' : (statusClass === 'failed' ? 'Failed' : 'In Progress');

        html += '<div class="jfm-execution-group">';
        html += '<div class="jfm-execution-header">';
        html += '<span class="jfm-execution-time">' + durationDisplay + '</span>';
        html += '<span class="jfm-execution-stats">' + (exec.expected_jobs || exec.completed_jobs || 0) + ' jobs';
        if (hasFailures) html += ', <span class="jfm-stat-value-failed">' + exec.failed_jobs + ' failed</span>';
        html += '</span>';
        html += '<span class="jfm-execution-duration"><span class="jfm-execution-start-label">Start </span>' + (exec.start_time || '-') + '</span>';
        html += '<span class="jfm-flow-status-badge jfm-flow-status-badge-' + statusClass + '">' + statusLabel + '</span>';
        html += '</div>';

        if (exec.jobs && exec.jobs.length > 0) {
            var displayJobs = jfm_filterJobs(exec.jobs);
            if (displayJobs.length > 0) {
                html += jfm_buildJobsTable(displayJobs, false);
            }
        }
        html += '</div>';
    });

    body.innerHTML = html;
}

/* ============================================================================
   FUNCTIONS: HISTORY DAY DETAILS
   ----------------------------------------------------------------------------
   Loads and renders the full day's flow and ad-hoc job breakdown shown in the
   slideout when a day row in the Execution History is clicked.
   Prefix: jfm
   ============================================================================ */

/* Loads all executions for a date and renders them in the slideout. */
function jfm_loadDayDetails(date) {
    jfm_slideoutJobFilter = 'ALL';
    jfm_setSlideoutTitle('Executions: ' + jfm_formatDisplayDate(date));
    document.getElementById('jfm-slideout-body').innerHTML = '<div class="jfm-loading">Loading...</div>';
    jfm_openSlideout();

    cc_engineFetch('/api/jobflow/history-detail?date=' + date)
        .then(function(data) {
            if (!data) return;
            if (data.error) {
                document.getElementById('jfm-slideout-body').innerHTML = '<div class="cc-slide-empty">Error: ' + data.error + '</div>';
                return;
            }
            const body = document.getElementById('jfm-slideout-body');
            body._lastRender = function() { jfm_renderDayDetails(data); };
            jfm_renderDayDetails(data);
        })
        .catch(function(err) {
            document.getElementById('jfm-slideout-body').innerHTML = '<div class="cc-slide-empty">Failed to load: ' + err.message + '</div>';
        });
}

/* ============================================================================
   FUNCTIONS: JOB TABLE BUILDER
   ----------------------------------------------------------------------------
   Shared builder for the slideout job tables (flow-day executions, day-detail
   flow groups, and ad-hoc lists). Emits the shared cc-slide-table chrome with
   page-specific cell coloring; the withUser flag adds the executed-by column
   used by ad-hoc tables.
   Prefix: jfm
   ============================================================================ */

/* Builds a slideout job table from a job array. withUser adds a User column
   and widens the error-row colspan to match. */
function jfm_buildJobsTable(jobs, withUser) {
    var cols = withUser ? 12 : 11;
    var html = '<table class="cc-slide-table"><thead><tr><th class="cc-slide-table-th"></th><th class="cc-slide-table-th jfm-job-th-order">#</th><th class="cc-slide-table-th">Job</th><th class="cc-slide-table-th">Start</th><th class="cc-slide-table-th">End</th><th class="cc-slide-table-th">Total</th><th class="cc-slide-table-th">Success</th><th class="cc-slide-table-th">Failed</th><th class="cc-slide-table-th">Duration</th><th class="cc-slide-table-th">Rate</th>';
    if (withUser) html += '<th class="cc-slide-table-th">User</th>';
    html += '<th class="cc-slide-table-th">Log ID</th></tr></thead><tbody>';

    jobs.forEach(function(job) {
        var jobTitle = job.job_full_name ? cc_escapeHtml(job.job_full_name) : '';
        var badgeClass = job.is_failed ? 'jfm-job-status-badge-failed' : 'jfm-job-status-badge-success';
        var badgeLabel = job.is_failed ? 'FAILED' : 'SUCCESS';
        html += '<tr class="cc-slide-table-row">';
        html += '<td class="cc-slide-table-td"><span class="jfm-job-status-badge ' + badgeClass + '">' + badgeLabel + '</span></td>';
        html += '<td class="cc-slide-table-td jfm-job-cell-exec-order">' + (job.execution_order != null ? job.execution_order : '-') + '</td>';
        html += '<td class="cc-slide-table-td" title="' + jobTitle + '">' + cc_escapeHtml(job.job_name) + '</td>';
        html += '<td class="cc-slide-table-td">' + (job.start_time || '-') + '</td>';
        html += '<td class="cc-slide-table-td">' + (job.end_time || '-') + '</td>';
        html += '<td class="cc-slide-table-td">' + (job.total_records !== null ? job.total_records.toLocaleString() : '-') + '</td>';
        html += '<td class="cc-slide-table-td jfm-job-cell-success">' + (job.succeeded_count !== null ? job.succeeded_count.toLocaleString() : '-') + '</td>';
        html += '<td class="cc-slide-table-td jfm-job-cell-failed">' + (job.failed_count || 0) + '</td>';
        html += '<td class="cc-slide-table-td">' + (job.duration || '-') + '</td>';
        html += '<td class="cc-slide-table-td">' + (job.records_per_second ? job.records_per_second.toFixed(1) + '/s' : '-') + '</td>';
        if (withUser) html += '<td class="cc-slide-table-td">' + (job.executed_by ? cc_escapeHtml(job.executed_by) : '-') + '</td>';
        html += '<td class="cc-slide-table-td jfm-job-cell-log-id">' + (job.job_log_id || '-') + '</td></tr>';
        if (job.error_message) {
            html += '<tr class="cc-slide-table-row"><td class="jfm-error-row-cell" colspan="' + cols + '"><span class="jfm-error-message">' + cc_escapeHtml(job.error_message) + '</span></td></tr>';
        }
    });

    html += '</tbody></table>';
    return html;
}

/* ============================================================================
   FUNCTIONS: APP SERVER TASKS
   ----------------------------------------------------------------------------
   The App Server Tasks modal: loading task state across servers, staging
   single-server enable/disable changes per flow, rendering the grid with
   staged states, and the batch apply/cancel flow with its confirmation.
   Prefix: jfm
   ============================================================================ */

/* Opens the tasks modal and loads current task state. */
function jfm_openTasksModal() {
    document.getElementById('jfm-modal-tasks').classList.remove('cc-hidden');
    jfm_loadAppTasks();
}

/* Closes the tasks modal and discards staged changes. */
function jfm_closeTasksModal(target, event) {
    if (event && event.target !== target) {
        return;
    }
    jfm_appTasksPendingChanges = {};
    document.getElementById('jfm-modal-tasks').classList.add('cc-hidden');
}

/* Loads scheduled-task state across the application servers. */
function jfm_loadAppTasks() {
    document.getElementById('jfm-tasks-grid').innerHTML = '<div class="jfm-loading">Loading tasks from application servers...</div>';
    jfm_hideApplyChangesButton();

    cc_engineFetch('/api/jobflow/app-tasks')
        .then(function(data) {
            if (!data) return;
            if (data.error) {
                document.getElementById('jfm-tasks-grid').innerHTML = '<div class="jfm-task-error">Error: ' + data.error + '</div>';
                return;
            }

            jfm_appTasksData = data;
            jfm_appTasksServerList = data.servers || ['DM-PROD-APP', 'DM-PROD-APP2', 'DM-PROD-APP3'];
            jfm_appTasksOriginalState = {};
            jfm_appTasksPendingChanges = {};

            data.tasks.forEach(function(task) {
                jfm_appTasksOriginalState[task.flow_code] = {};
                jfm_appTasksServerList.forEach(function(server) {
                    jfm_appTasksOriginalState[task.flow_code][server] = (task.states[server] === 'Ready');
                });
            });

            jfm_renderAppTasksGrid();
            jfm_updatePendingChangesUI();
        })
        .catch(function(err) {
            document.getElementById('jfm-tasks-grid').innerHTML = '<div class="jfm-task-error">Failed to load tasks: ' + err.message + '</div>';
        });
}

/* Stages a single-server enable/disable change for a flow, then re-renders. */
function jfm_stageTaskChange(flowCode, clickedServer) {
    var original = jfm_appTasksOriginalState[flowCode];
    var pending = jfm_appTasksPendingChanges[flowCode];

    var currentEnabled = null;
    jfm_appTasksServerList.forEach(function(server) {
        if (original[server]) currentEnabled = server;
    });

    if (pending) {
        currentEnabled = pending.to;
    }

    if (pending) {
        if (clickedServer === pending.to) {
            delete jfm_appTasksPendingChanges[flowCode];
        } else if (clickedServer === pending.from) {
            delete jfm_appTasksPendingChanges[flowCode];
        } else {
            jfm_appTasksPendingChanges[flowCode] = { from: pending.from, to: clickedServer };
        }
    } else {
        if (original[clickedServer]) {
            jfm_appTasksPendingChanges[flowCode] = { from: clickedServer, to: null };
        } else {
            jfm_appTasksPendingChanges[flowCode] = { from: currentEnabled, to: clickedServer };
        }
    }

    jfm_renderAppTasksGrid();
    jfm_updatePendingChangesUI();
}

/* Renders the server/flow task grid with original and staged states. */
function jfm_renderAppTasksGrid() {
    var container = document.getElementById('jfm-tasks-grid');
    if (!jfm_appTasksData || !jfm_appTasksData.tasks || jfm_appTasksData.tasks.length === 0) {
        container.innerHTML = '<div class="jfm-task-error">No scheduled tasks found</div>';
        return;
    }

    var html = '<div class="jfm-tasks-header jfm-tasks-header-flow">Flow</div>';
    jfm_appTasksServerList.forEach(function(server) {
        html += '<div class="jfm-tasks-header">' + server.replace('DM-PROD-', '') + '</div>';
    });

    jfm_appTasksData.tasks.forEach(function(task) {
        var flowCode = task.flow_code;
        var pending = jfm_appTasksPendingChanges[flowCode];
        var hasEnabled = task.has_enabled;
        var rowClass = 'jfm-task-row-flow';

        if (!hasEnabled && (!pending || pending.to === null)) {
            rowClass += ' jfm-task-row-flow-warning';
        }

        var flowTitle = task.flow_name ? cc_escapeHtml(task.flow_name) : '';
        html += '<div class="' + rowClass + '" title="' + flowTitle + '">' + cc_escapeHtml(flowCode) + '</div>';

        jfm_appTasksServerList.forEach(function(server) {
            var originalEnabled = jfm_appTasksOriginalState[flowCode][server];
            var cellClass = 'jfm-task-cell';
            var statusClass = 'jfm-task-status';
            var icon = '&#9675;';

            if (pending) {
                if (server === pending.from && pending.from !== null) {
                    cellClass += ' jfm-task-cell-pending-disable';
                    statusClass += ' jfm-task-status-pending-disable';
                    icon = '&#9679;';
                } else if (server === pending.to && pending.to !== null) {
                    cellClass += ' jfm-task-cell-pending-enable';
                    statusClass += ' jfm-task-status-pending-enable';
                    icon = '&#9679;';
                } else if (originalEnabled) {
                    cellClass += ' jfm-task-cell-enabled';
                    statusClass += ' jfm-task-status-enabled';
                    icon = '&#9679;';
                } else {
                    cellClass += ' jfm-task-cell-disabled';
                    statusClass += ' jfm-task-status-disabled';
                }
            } else {
                if (originalEnabled) {
                    cellClass += ' jfm-task-cell-enabled';
                    statusClass += ' jfm-task-status-enabled';
                    icon = '&#9679;';
                } else {
                    cellClass += ' jfm-task-cell-disabled';
                    statusClass += ' jfm-task-status-disabled';
                }
            }

            html += '<div class="' + cellClass + '" data-action-click="jfm-stage-task-change" data-flow-code="' + cc_escapeHtml(flowCode) + '" data-server="' + server + '">';
            html += '<span class="' + statusClass + '">' + icon + '</span></div>';
        });
    });

    container.innerHTML = html;
}

/* Updates the staged-changes indicator and Apply button visibility. */
function jfm_updatePendingChangesUI() {
    var changeCount = Object.keys(jfm_appTasksPendingChanges).length;
    var indicator = document.getElementById('jfm-pending-changes-indicator');
    var applyBtn = document.getElementById('jfm-btn-apply-changes');

    if (changeCount > 0) {
        indicator.textContent = 'Pending Changes: ' + changeCount;
        indicator.classList.remove('jfm-hidden');
        applyBtn.classList.remove('jfm-hidden');
    } else {
        indicator.classList.add('jfm-hidden');
        applyBtn.classList.add('jfm-hidden');
    }
}

/* Hides the staged-changes indicator and Apply button. */
function jfm_hideApplyChangesButton() {
    document.getElementById('jfm-pending-changes-indicator').classList.add('jfm-hidden');
    document.getElementById('jfm-btn-apply-changes').classList.add('jfm-hidden');
}

/* Builds and shows the staged-change confirmation modal. */
function jfm_showApplyConfirmation() {
    var changes = [];
    for (var flowCode in jfm_appTasksPendingChanges) {
        var change = jfm_appTasksPendingChanges[flowCode];
        var fromName = change.from ? change.from.replace('DM-PROD-', '') : 'None';
        var toName = change.to ? change.to.replace('DM-PROD-', '') : 'None';
        changes.push({ flowCode: flowCode, from: fromName, to: toName });
    }

    var html = '<div class="jfm-confirm-changes-list">';
    changes.forEach(function(c) {
        html += '<div class="jfm-confirm-change-item">Move <span class="jfm-confirm-change-flow">' + cc_escapeHtml(c.flowCode) + '</span> from <span class="jfm-confirm-from-server">' + c.from + '</span> to <span class="jfm-confirm-to-server">' + c.to + '</span></div>';
    });
    html += '</div>';

    document.getElementById('jfm-confirm-changes-body').innerHTML = html;
    document.getElementById('jfm-modal-confirm').classList.remove('cc-hidden');
}

/* Closes the staged-change confirmation modal. */
function jfm_closeConfirmModal(target, event) {
    if (event && event.target !== target) {
        return;
    }
    document.getElementById('jfm-modal-confirm').classList.add('cc-hidden');
}

/* Discards all staged changes and re-renders the grid. */
function jfm_cancelAllChanges() {
    jfm_appTasksPendingChanges = {};
    jfm_renderAppTasksGrid();
    jfm_updatePendingChangesUI();
    jfm_closeConfirmModal();
}

/* Applies all staged task changes via the batch endpoint, then refreshes. */
function jfm_applyAllChanges() {
    var changes = [];
    for (var flowCode in jfm_appTasksPendingChanges) {
        var change = jfm_appTasksPendingChanges[flowCode];
        if (change.from) {
            changes.push({ server: change.from, flow_code: flowCode, enable: false });
        }
        if (change.to) {
            changes.push({ server: change.to, flow_code: flowCode, enable: true });
        }
    }

    if (changes.length === 0) {
        jfm_closeConfirmModal();
        return;
    }

    document.getElementById('jfm-confirm-changes-body').innerHTML = '<div class="jfm-loading">Applying changes...</div>';

    cc_engineFetch('/api/jobflow/app-tasks/batch', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ changes: changes })
    })
        .then(function(data) {
            if (!data) return;
            jfm_closeConfirmModal();

            if (data.error) {
                cc_showAlert('Failed to apply changes: ' + data.error);
                jfm_loadAppTasks();
                return;
            }

            if (!data.success) {
                var failedMsg = 'Some changes failed: ';
                data.results.forEach(function(r) {
                    if (!r.success) {
                        failedMsg += r.flow_code + ' on ' + r.server.replace('DM-PROD-', '') + ': ' + r.error + '; ';
                    }
                });
                if (data.rollback_attempted) {
                    failedMsg += 'Rollback was attempted for successful changes.';
                }
                cc_showAlert(failedMsg);
            }

            jfm_loadAppTasks();
        })
        .catch(function(err) {
            jfm_closeConfirmModal();
            cc_showAlert('Failed to apply changes: ' + err.message);
            jfm_loadAppTasks();
        });
}

/* ============================================================================
   FUNCTIONS: LIVE ACTIVITY RENDER
   ----------------------------------------------------------------------------
   Renders the executing-jobs table in the Live Activity section, the pending
   jobs in the pending slideout, and the pending-count badge in the header.
   Prefix: jfm
   ============================================================================ */

/* Renders the currently-executing jobs table. */
function jfm_renderExecutingJobs(jobs) {
    var container = document.getElementById('jfm-executing-jobs');

    if (!jobs || jobs.length === 0) {
        container.innerHTML = '<div class="jfm-no-activity">No jobs currently executing</div>';
        return;
    }

    var html = '<table class="jfm-activity-table"><thead><tr>';
    html += '<th class="jfm-activity-th">Job</th><th class="jfm-activity-th">Flow</th><th class="jfm-activity-th">Progress</th><th class="jfm-activity-th">Success</th><th class="jfm-activity-th">Failed</th><th class="jfm-activity-th">ETA</th><th class="jfm-activity-th">Rate</th><th class="jfm-activity-th">Log ID</th>';
    html += '</tr></thead><tbody>';

    jobs.forEach(function(job) {
        var progress = 0;
        var progressText = '-';
        if (job.total_records && job.total_records > 0) {
            progress = Math.round((job.completed_records / job.total_records) * 100);
            progressText = job.completed_records.toLocaleString() + ' / ' + job.total_records.toLocaleString();
        } else if (job.completed_records > 0) {
            progressText = job.completed_records.toLocaleString() + ' processed';
        }

        var jobTitle = job.job_full_name ? cc_escapeHtml(job.job_full_name) : '';

        html += '<tr class="jfm-activity-row">';
        html += '<td class="jfm-activity-td"><span class="jfm-job-name" title="' + jobTitle + '">' + cc_escapeHtml(job.job_name) + '</span></td>';
        html += '<td class="jfm-activity-td">';
        if (job.flow_code) {
            html += '<span class="jfm-flow-badge">' + cc_escapeHtml(job.flow_code) + '</span>';
        } else {
            html += '<span class="jfm-flow-code-adhoc">ad-hoc</span>';
        }
        html += '</td><td class="jfm-activity-td">';
        if (job.total_records && job.total_records > 0) {
            html += '<div class="jfm-progress-bar-container">';
            html += '<div class="jfm-progress-bar" data-progress="' + progress + '"></div>';
            html += '<span class="jfm-progress-text">' + progressText + '</span></div>';
        } else {
            html += '<span class="jfm-rate-value">' + progressText + '</span>';
        }
        html += '</td>';
        html += '<td class="jfm-activity-td jfm-activity-cell-success">' + (job.success_count || 0).toLocaleString() + '</td>';
        html += '<td class="jfm-activity-td jfm-activity-cell-failed">' + (job.failure_count || 0).toLocaleString() + '</td>';
        html += '<td class="jfm-activity-td"><span class="jfm-eta-value">' + (job.time_remaining || '-') + '</span></td>';
        html += '<td class="jfm-activity-td"><span class="jfm-rate-value">' + (job.records_per_second ? job.records_per_second + '/s' : '-') + '</span></td>';
        html += '<td class="jfm-activity-td jfm-activity-cell-log-id">' + (job.job_log_id || '-') + '</td>';
        html += '</tr>';
    });

    html += '</tbody></table>';
    container.innerHTML = html;

    jfm_applyProgressWidths(container);
}

/* Applies each progress bar's width from its data-progress attribute (avoids
   inline style attributes in the generated markup). */
function jfm_applyProgressWidths(container) {
    var bars = container.querySelectorAll('.jfm-progress-bar');
    bars.forEach(function(bar) {
        bar.style.width = bar.getAttribute('data-progress') + '%';
    });
}

/* Renders the pending-queue jobs into the slideout body. */
function jfm_renderPendingJobs(jobs) {
    var body = document.getElementById('jfm-slideout-body');

    if (!jobs || jobs.length === 0) {
        body.innerHTML = '<div class="cc-slide-empty">No jobs currently pending</div>';
        return;
    }

    var html = '<div class="jfm-pending-summary"><span class="jfm-pending-total">' + jobs.length + ' jobs in queue</span></div>';
    html += '<table class="cc-slide-table"><thead><tr><th class="cc-slide-table-th">Job</th><th class="cc-slide-table-th">Flow</th><th class="cc-slide-table-th">Queued</th></tr></thead><tbody>';

    jobs.forEach(function(job) {
        html += '<tr class="cc-slide-table-row"><td class="cc-slide-table-td"><span class="jfm-job-name">' + cc_escapeHtml(job.job_name) + '</span></td><td class="cc-slide-table-td">';
        if (job.flow_code) {
            html += '<span class="jfm-flow-badge">' + cc_escapeHtml(job.flow_code) + '</span>';
        } else {
            html += '<span class="jfm-flow-code-adhoc">ad-hoc</span>';
        }
        html += '</td><td class="cc-slide-table-td jfm-rate-value">' + (job.queued_time || '-') + '</td></tr>';
    });

    html += '</tbody></table>';
    body.innerHTML = html;
}

/* Updates the header pending-count badge, hiding it at zero. */
function jfm_updatePendingBadge(count) {
    var badge = document.getElementById('jfm-pending-count-badge');
    if (count > 0) {
        badge.textContent = count;
        badge.classList.remove('jfm-hidden');
    } else {
        badge.classList.add('jfm-hidden');
    }
}

/* ============================================================================
   FUNCTIONS: PROCESS STATUS RENDER
   ----------------------------------------------------------------------------
   Renders the orchestrator process-status grid, applying severity colors per
   card with special handling for the stall and config-sync cards, and wiring
   the config-sync card to open the configuration modal.
   Prefix: jfm
   ============================================================================ */

/* Renders the process-status grid from the status API response. */
function jfm_renderProcessStatus(processes, stallCount, stallThreshold) {
    var container = document.getElementById('jfm-process-status');

    if (!processes || processes.length === 0) {
        container.innerHTML = '<div class="jfm-no-activity">No process status available</div>';
        return;
    }

    var threshold = stallThreshold || 6;
    var html = '';

    processes.forEach(function(proc) {
        var name = proc.short_name || proc.process_name;
        var icon = jfm_PROCESS_ICONS[name] || '&#x2022;';
        var count = proc.last_result_count;
        var countDisplay = (count !== null && count !== undefined) ? count : '-';
        var timeDisplay = proc.time_ago || '-';

        var cardClass = proc.status_class || 'healthy';

        if (name === 'Stall Detection') {
            if (stallCount === null || stallCount === undefined || stallCount === 0) {
                cardClass = 'healthy';
            } else if (stallCount < threshold) {
                cardClass = 'warning';
            } else {
                cardClass = 'error';
            }
        }

        if (name === 'Flow Config Sync' && count !== null && count !== undefined && count > 0) {
            cardClass = 'warning';
        }

        var cardColorClass = (cardClass !== 'healthy') ? ' jfm-status-card-' + cardClass : '';

        var actionAttr = '';
        var clickableClass = '';
        if (name === 'Flow Config Sync') {
            actionAttr = ' data-action-click="jfm-open-configsync"';
            clickableClass = ' jfm-status-card-clickable';
        }

        var countColorClass = ' jfm-status-card-count-healthy';
        if (cardClass === 'warning') countColorClass = ' jfm-status-card-count-warning';
        if (cardClass === 'error') countColorClass = ' jfm-status-card-count-error';

        html += '<div class="jfm-status-card' + cardColorClass + clickableClass + '"' + actionAttr + '>';
        html += '<div class="jfm-status-card-header"><span class="jfm-status-card-name">' + cc_escapeHtml(name) + '</span><span class="jfm-status-card-icon">' + icon + '</span></div>';
        html += '<div class="jfm-status-card-count' + countColorClass + '">' + countDisplay + '</div>';
        html += '<div class="jfm-status-card-time">' + timeDisplay + '</div>';
        html += '</div>';
    });

    container.innerHTML = html;
}

/* ============================================================================
   FUNCTIONS: DAILY SUMMARY RENDER
   ----------------------------------------------------------------------------
   Renders the Daily Summary section: the total-jobs, flows, and stall-events
   cards; the clickable per-flow list; and the ad-hoc jobs entry. Caches the
   ad-hoc and stall datasets for their slideouts.
   Prefix: jfm
   ============================================================================ */

/* Renders the Daily Summary from the todays-summary API response. */
function jfm_renderDailySummary(data) {
    var container = document.getElementById('jfm-daily-summary');
    var flowCount = (data.flows || []).length;
    var adhocCount = (data.adhoc_jobs || []).length;
    var completedFlows = (data.flows || []).filter(function(f) { return f.execution_state === 'COMPLETE' || f.execution_state === 'VALIDATED'; }).length;
    var failedFlows = (data.flows || []).filter(function(f) { return f.execution_state === 'FAILED'; }).length;
    var inProgressFlows = flowCount - completedFlows - failedFlows;

    jfm_currentAdhocData = data.adhoc_jobs || [];
    jfm_currentStallEpisodes = data.stall_episodes || [];

    var totalExecutions = (data.flows || []).reduce(function(sum, f) { return sum + (f.execution_count || 1); }, 0);
    var stallEventCount = jfm_currentStallEpisodes.length;

    var html = '<div class="jfm-summary-cards">';

    html += '<div class="jfm-summary-card"><div class="jfm-summary-card-label">TOTAL JOBS</div><div class="jfm-summary-card-value">' + (data.total_jobs || 0).toLocaleString() + '</div>';
    html += '<div class="jfm-summary-card-detail"><span class="jfm-summary-detail-muted">All executions</span></div></div>';

    html += '<div class="jfm-summary-card"><div class="jfm-summary-card-label">FLOWS</div><div class="jfm-summary-card-value">' + flowCount + '</div><div class="jfm-summary-card-detail">';
    if (completedFlows > 0) html += '<span class="jfm-summary-detail-success">' + completedFlows + ' done</span>';
    if (inProgressFlows > 0) html += '<span class="jfm-summary-detail-in-progress">' + inProgressFlows + ' active</span>';
    if (failedFlows > 0) html += '<span class="jfm-summary-detail-failed">' + failedFlows + ' failed</span>';
    if (flowCount === 0) html += '<span class="jfm-summary-detail-muted">None today</span>';
    if (totalExecutions > flowCount) html += '<span class="jfm-summary-detail-muted">(' + totalExecutions + ' runs)</span>';
    html += '</div></div>';

    var stallCardClass = 'jfm-summary-card jfm-summary-card-clickable';
    if (stallEventCount > 0) stallCardClass += ' jfm-summary-card-stall-active';
    html += '<div class="' + stallCardClass + '" data-action-click="jfm-open-stall-episodes"><div class="jfm-summary-card-label">STALL EVENTS</div>';
    html += '<div class="jfm-summary-card-value' + (stallEventCount > 0 ? ' jfm-summary-card-value-stall' : '') + '">' + stallEventCount + '</div>';
    html += '<div class="jfm-summary-card-detail">';
    if (stallEventCount === 0) {
        html += '<span class="jfm-summary-detail-success">No stalls today</span>';
    } else {
        var unresolvedCount = jfm_currentStallEpisodes.filter(function(e) { return !e.resolved; }).length;
        if (unresolvedCount > 0) {
            html += '<span class="jfm-summary-detail-failed">' + unresolvedCount + ' ongoing</span>';
        } else {
            html += '<span class="jfm-summary-detail-muted">All resolved</span>';
        }
    }
    html += '</div><span class="jfm-card-click-arrow">&#x25B6;</span></div>';

    html += '</div>';

    if (flowCount > 0) {
        html += '<div class="jfm-summary-section"><div class="jfm-summary-section-title">Flows</div><div class="jfm-summary-items">';
        data.flows.forEach(function(flow) {
            var statusClass = (flow.execution_state === 'COMPLETE' || flow.execution_state === 'VALIDATED') ? 'complete' : (flow.execution_state === 'FAILED' ? 'failed' : 'detected');
            var execCount = flow.execution_count || 1;
            var flowNameDisplay = flow.flow_name ? cc_escapeHtml(flow.flow_name) : '';
            var execLabel = execCount > 1 ? ' (' + execCount + ' runs)' : '';
            var flowStatusLabel = statusClass === 'complete' ? 'Complete' : (statusClass === 'failed' ? 'Failed' : 'In Progress');
            html += '<div class="jfm-flow-item jfm-flow-item-clickable" data-action-click="jfm-load-flow-day" data-job-sqnc-id="' + flow.job_sqnc_id + '" data-flow-code="' + cc_escapeHtml(flow.flow_code) + '">';
            html += '<div class="jfm-flow-item-left"><span class="jfm-flow-code">' + cc_escapeHtml(flow.flow_code) + '</span><span class="jfm-flow-name jfm-flow-name-' + statusClass + '">' + flowNameDisplay + '</span></div>';
            html += '<div class="jfm-flow-item-right">';
            html += '<span class="jfm-flow-jobs">' + (flow.expected_jobs || flow.completed_jobs || 0) + ' jobs' + execLabel + '</span>';
            html += '<span class="jfm-flow-succeeded">' + (flow.completed_jobs || 0) + ' succeeded</span>';
            html += '<span class="jfm-flow-failed">' + ((flow.failed_jobs || 0) > 0 ? flow.failed_jobs + ' failed' : '') + '</span>';
            html += '<span class="jfm-flow-duration">' + (flow.duration || '-') + '</span>';
            html += '<span class="jfm-flow-status-badge jfm-flow-status-badge-' + statusClass + '">' + flowStatusLabel + '</span>';
            html += '<span class="jfm-flow-arrow">&#x25B6;</span>';
            html += '</div></div>';
        });
        html += '</div></div>';
    }

    if (adhocCount > 0) {
        html += '<div class="jfm-summary-section"><div class="jfm-summary-section-title jfm-summary-section-title-clickable" data-action-click="jfm-open-adhoc">Ad Hoc Jobs (' + adhocCount + ') <span class="jfm-section-arrow">&#x25B6;</span></div></div>';
    }

    container.innerHTML = html;
}

/* ============================================================================
   FUNCTIONS: STALL SLIDEOUTS
   ----------------------------------------------------------------------------
   Renders today's stall episodes and the 90-day stall history into the
   slideout, including the per-episode rows with their status, badges, and
   resolution chips, plus the date-grouped history layout.
   Prefix: jfm
   ============================================================================ */

/* Builds the markup for a single stall-episode row. */
function jfm_buildStallEpisodeRow(ep, idx) {
    var statusClass = ep.resolved ? 'resolved' : 'ongoing';
    var statusIcon = ep.resolved ? '&#x2714;' : '&#x25CF;';
    var resLabel = ep.resolved ? 'Resolved' : 'Ongoing';
    var endDisplay = ep.resolved && ep.end_time ? ep.end_time : 'ongoing';

    var durationDisplay = '-';
    if (ep.start_time && ep.end_time && ep.resolved) {
        var sp = ep.start_time.split(':');
        var ep2 = ep.end_time.split(':');
        var diffMin = (parseInt(ep2[0]) * 60 + parseInt(ep2[1])) - (parseInt(sp[0]) * 60 + parseInt(sp[1]));
        if (diffMin < 0) diffMin += 1440;
        if (diffMin >= 60) {
            durationDisplay = Math.floor(diffMin / 60) + 'h ' + (diffMin % 60) + 'm';
        } else {
            durationDisplay = diffMin + 'm';
        }
    } else if (!ep.resolved) {
        durationDisplay = 'ongoing';
    }

    var alertBadge = ep.alert_sent ? '<span class="jfm-stall-ep-alert-badge">Alert</span>' : '';
    var overnightBadge = ep.crosses_midnight ? '<span class="jfm-stall-ep-overnight-badge">Overnight</span>' : '';

    var html = '<div class="jfm-stall-episode-row">';
    html += '<span class="jfm-stall-ep-icon jfm-stall-ep-icon-' + statusClass + '">' + statusIcon + '</span>';
    html += '<span class="jfm-stall-ep-num">Episode ' + (idx + 1) + '</span>';
    html += '<span class="jfm-stall-ep-field"><span class="jfm-stall-ep-label">Start</span> ' + ep.start_time + '</span>';
    html += '<span class="jfm-stall-ep-field"><span class="jfm-stall-ep-label">End</span> ' + endDisplay + '</span>';
    html += '<span class="jfm-stall-ep-field"><span class="jfm-stall-ep-label">Duration</span> ' + durationDisplay + '</span>';
    html += '<span class="jfm-stall-ep-field"><span class="jfm-stall-ep-label">Polls</span> ' + ep.polls + '</span>';
    html += overnightBadge;
    html += alertBadge;
    html += '<span class="jfm-stall-ep-resolution jfm-stall-ep-resolution-' + statusClass + '">' + resLabel + '</span>';
    html += '</div>';
    return html;
}

/* Opens the slideout showing today's stall episodes. */
function jfm_openStallEpisodesSlideout() {
    jfm_setSlideoutTitle('Stall Events Today');
    var body = document.getElementById('jfm-slideout-body');

    if (!jfm_currentStallEpisodes || jfm_currentStallEpisodes.length === 0) {
        body.innerHTML = '<div class="cc-slide-empty">No stall events today</div><div class="jfm-stall-history-link"><button class="jfm-stall-history-btn" data-action-click="jfm-load-stall-history">View All History</button></div>';
        jfm_openSlideout();
        return;
    }

    var html = '<div class="jfm-stall-episodes">';
    jfm_currentStallEpisodes.forEach(function(ep, idx) {
        html += jfm_buildStallEpisodeRow(ep, idx);
    });
    html += '</div>';
    html += '<div class="jfm-stall-history-link"><button class="jfm-stall-history-btn" data-action-click="jfm-load-stall-history">View All History</button></div>';
    body.innerHTML = html;
    jfm_openSlideout();
}

/* Loads and renders the 90-day stall history into the slideout. */
function jfm_loadStallHistory() {
    jfm_setSlideoutTitle('Stall Event History');
    var body = document.getElementById('jfm-slideout-body');
    body.innerHTML = '<div class="jfm-loading">Loading history...</div>';

    cc_engineFetch('/api/jobflow/stall-history?days=90')
        .then(function(data) {
            if (!data) return;
            if (!data.dates || data.dates.length === 0) {
                body.innerHTML = '<div class="cc-slide-empty">No stall events in the last 90 days</div>';
                return;
            }

            var html = '<div class="jfm-stall-history-summary">';
            html += '<span class="jfm-stall-history-range">' + data.dates_with_events + ' day' + (data.dates_with_events === 1 ? '' : 's') + ' with events (last 90 days)</span>';
            html += '</div>';

            data.dates.forEach(function(dateGroup) {
                var alertBadge = dateGroup.alert_count > 0 ? '<span class="jfm-stall-date-alert">' + dateGroup.alert_count + ' alert' + (dateGroup.alert_count === 1 ? '' : 's') + '</span>' : '';
                var stallTimeStr = '';
                if (dateGroup.total_stall_minutes != null && dateGroup.total_stall_minutes > 0) {
                    if (dateGroup.total_stall_minutes >= 60) {
                        stallTimeStr = Math.floor(dateGroup.total_stall_minutes / 60) + 'h ' + (dateGroup.total_stall_minutes % 60) + 'm';
                    } else {
                        stallTimeStr = dateGroup.total_stall_minutes + 'm';
                    }
                    stallTimeStr = '<span class="jfm-stall-date-total-time">Total: ' + stallTimeStr + '</span>';
                }
                html += '<div class="jfm-stall-date-group">';
                html += '<div class="jfm-stall-date-header"><span class="jfm-stall-date-val">' + dateGroup.date + '</span><span class="jfm-stall-date-dow">' + dateGroup.day_of_week + '</span><span class="jfm-stall-date-episodes-count">' + dateGroup.episode_count + ' episode' + (dateGroup.episode_count === 1 ? '' : 's') + '</span>' + stallTimeStr + alertBadge + '</div>';
                html += '<div class="jfm-stall-date-episodes">';
                dateGroup.episodes.forEach(function(ep, idx) {
                    html += jfm_buildStallEpisodeRow(ep, idx);
                });
                html += '</div></div>';
            });

            body.innerHTML = html;
        })
        .catch(function(err) {
            body.innerHTML = '<div class="cc-slide-empty">Error loading stall history</div>';
        });
}

/* ============================================================================
   FUNCTIONS: EXECUTION HISTORY RENDER
   ----------------------------------------------------------------------------
   Renders the year/month history tree and its lazily-loaded month-day table,
   and provides the expand/collapse toggles for year and month rows. Toggle
   chevrons use Unicode escapes when assigned via textContent.
   Prefix: jfm
   ============================================================================ */

/* Renders the year-grouped execution history tree. */
function jfm_renderExecutionHistory(data) {
    var container = document.getElementById('jfm-execution-history');
    var countEl = document.getElementById('jfm-history-count');

    if (!data || !data.years || data.years.length === 0) {
        container.innerHTML = '<div class="jfm-no-activity">No execution history available</div>';
        countEl.textContent = '';
        return;
    }

    countEl.textContent = (data.total_job_count || 0).toLocaleString() + ' jobs';

    var html = '<div class="jfm-history-tree">';

    data.years.forEach(function(yearData) {
        var yearJobs = 0, yearSuccess = 0, yearFailed = 0;
        yearData.months.forEach(function(md) {
            yearJobs += md.total_jobs || 0;
            yearSuccess += md.successful_jobs || 0;
            yearFailed += md.failed_jobs || 0;
        });

        html += '<div class="jfm-history-year" data-year="' + yearData.year + '">';
        html += '<div class="jfm-year-header" data-action-click="jfm-toggle-year">';
        html += '<span class="jfm-expand-icon">&#x25B6;</span>';
        html += '<span class="jfm-year-label">' + yearData.year + '</span>';
        html += '<div class="jfm-year-stats">';
        html += '<span class="jfm-year-stat">' + yearJobs.toLocaleString() + ' jobs</span>';
        html += '<span class="jfm-year-stat jfm-year-stat-success">' + yearSuccess.toLocaleString() + ' succeeded</span>';
        html += '<span class="jfm-year-stat jfm-year-stat-failed">' + (yearFailed > 0 ? yearFailed.toLocaleString() + ' failed' : '-') + '</span>';
        html += '</div>';
        html += '</div>';
        html += '<div class="jfm-year-content" data-collapsed="true">';
        html += '<table class="jfm-month-summary-table"><thead><tr><th class="jfm-month-summary-th"></th><th class="jfm-month-summary-th">Month</th><th class="jfm-month-summary-th">Flows</th><th class="jfm-month-summary-th">Jobs</th><th class="jfm-month-summary-th">Succeeded</th><th class="jfm-month-summary-th">Failed</th></tr></thead>';

        yearData.months.forEach(function(monthData) {
            html += '<tbody class="jfm-month-group" data-month="' + monthData.month + '">';
            html += '<tr class="jfm-month-row" data-action-click="jfm-toggle-month">';
            html += '<td class="jfm-month-summary-td jfm-month-cell-expand"><span class="jfm-expand-icon">&#x25B6;</span></td>';
            html += '<td class="jfm-month-summary-td jfm-month-cell-name">' + jfm_MONTH_NAMES[monthData.month] + '</td>';
            html += '<td class="jfm-month-summary-td">' + (monthData.distinct_flows || 0) + '</td>';
            html += '<td class="jfm-month-summary-td">' + (monthData.total_jobs || 0).toLocaleString() + '</td>';
            html += '<td class="jfm-month-summary-td jfm-month-cell-success">' + (monthData.successful_jobs || 0).toLocaleString() + '</td>';
            html += '<td class="jfm-month-summary-td jfm-month-cell-fail">' + (monthData.failed_jobs > 0 ? monthData.failed_jobs.toLocaleString() : '-') + '</td>';
            html += '</tr>';
            html += '<tr class="jfm-month-details" data-collapsed="true"><td colspan="6">';
            html += '<div class="jfm-month-details-content" data-year="' + yearData.year + '" data-month="' + monthData.month + '"><div class="jfm-loading">Loading...</div></div>';
            html += '</td></tr></tbody>';
        });

        html += '</table></div></div>';
    });

    html += '</div>';
    container.innerHTML = html;

    jfm_applyHistoryCollapse(container);
}

/* Applies the initial collapsed state to the history tree, hiding every year
   content block and month detail row that the markup marks data-collapsed.
   Keeps the starting display in sync with the attribute the toggles read. */
function jfm_applyHistoryCollapse(container) {
    container.querySelectorAll('.jfm-year-content').forEach(function(el) {
        if (el.getAttribute('data-collapsed') === 'true') { el.style.display = 'none'; }
    });
    container.querySelectorAll('.jfm-month-details').forEach(function(el) {
        if (el.getAttribute('data-collapsed') === 'true') { el.style.display = 'none'; }
    });
}

/* Renders the day rows for an expanded month into the month detail container. */
function jfm_renderMonthDays(container, days) {
    var html = '<table class="jfm-history-table"><thead><tr><th class="jfm-history-th"></th><th class="jfm-history-th">Day</th><th class="jfm-history-th">Date</th><th class="jfm-history-th">Flows</th><th class="jfm-history-th">Jobs</th><th class="jfm-history-th">Succeeded</th><th class="jfm-history-th">Failed</th></tr></thead><tbody>';

    days.forEach(function(dayData, idx) {
        var statusClass = 'success';
        if (dayData.failed_jobs > 0 && dayData.failed_jobs < dayData.total_jobs) statusClass = 'warning';
        else if (dayData.failed_jobs > 0 && dayData.failed_jobs === dayData.total_jobs) statusClass = 'error';

        var dateParts = dayData.date.split('-');
        var rowClass = idx % 2 === 0 ? 'jfm-history-row' : 'jfm-history-row jfm-history-row-odd';
        html += '<tr class="' + rowClass + '" data-action-click="jfm-load-day" data-date="' + dayData.date + '">';
        html += '<td class="jfm-history-td"><span class="jfm-status-indicator jfm-status-indicator-' + statusClass + '"></span></td>';
        html += '<td class="jfm-history-td">' + dayData.day_of_week + '</td>';
        html += '<td class="jfm-history-td">' + dateParts[1] + '/' + dateParts[2] + '</td>';
        html += '<td class="jfm-history-td">' + (dayData.flow_count || 0) + '</td>';
        html += '<td class="jfm-history-td">' + (dayData.total_jobs || 0) + '</td>';
        html += '<td class="jfm-history-td jfm-history-cell-success">' + (dayData.successful_jobs || 0) + '</td>';
        html += '<td class="jfm-history-td jfm-history-cell-fail">' + (dayData.failed_jobs > 0 ? dayData.failed_jobs : '-') + '</td>';
        html += '</tr>';
    });

    html += '</tbody></table>';
    container.innerHTML = html;
}

/* Toggles a year group open/closed, collapsing other years and their months. */
function jfm_toggleYear(header) {
    var yearDiv = header.parentElement;
    var content = header.nextElementSibling;
    var icon = header.querySelector('.jfm-expand-icon');
    var isOpening = content.getAttribute('data-collapsed') === 'true';

    if (isOpening) {
        document.querySelectorAll('.jfm-history-year').forEach(function(otherYear) {
            if (otherYear !== yearDiv) {
                var oc = otherYear.querySelector('.jfm-year-content');
                oc.setAttribute('data-collapsed', 'true');
                oc.style.display = 'none';
                otherYear.querySelector('.jfm-year-header .jfm-expand-icon').textContent = '\u25B6';
                otherYear.querySelectorAll('.jfm-month-details').forEach(function(md) { md.setAttribute('data-collapsed', 'true'); md.style.display = 'none'; });
                otherYear.querySelectorAll('.jfm-month-row .jfm-expand-icon').forEach(function(mi) { mi.textContent = '\u25B6'; });
            }
        });
        content.querySelectorAll('.jfm-month-details').forEach(function(md) { md.setAttribute('data-collapsed', 'true'); md.style.display = 'none'; });
        content.querySelectorAll('.jfm-month-row .jfm-expand-icon').forEach(function(mi) { mi.textContent = '\u25B6'; });
    }
    content.setAttribute('data-collapsed', isOpening ? 'false' : 'true');
    content.style.display = isOpening ? 'block' : 'none';
    icon.textContent = isOpening ? '\u25BC' : '\u25B6';
}

/* Toggles a month group open/closed, lazily loading its day rows on first open. */
function jfm_toggleMonthGroup(row) {
    var tbody = row.closest('tbody.jfm-month-group');
    var detailsRow = tbody.querySelector('.jfm-month-details');
    var icon = row.querySelector('.jfm-expand-icon');
    var isOpen = detailsRow.getAttribute('data-collapsed') === 'false';

    if (!isOpen) {
        var yearContent = tbody.closest('.jfm-year-content');
        yearContent.querySelectorAll('.jfm-month-details').forEach(function(md) { md.setAttribute('data-collapsed', 'true'); md.style.display = 'none'; });
        yearContent.querySelectorAll('.jfm-month-row .jfm-expand-icon').forEach(function(mi) { mi.textContent = '\u25B6'; });
    }
    detailsRow.setAttribute('data-collapsed', isOpen ? 'true' : 'false');
    detailsRow.style.display = isOpen ? 'none' : 'table-row';
    icon.textContent = isOpen ? '\u25B6' : '\u25BC';

    if (!isOpen) {
        var contentDiv = detailsRow.querySelector('.jfm-month-details-content');
        if (contentDiv && contentDiv.querySelector('.jfm-loading')) {
            jfm_loadMonthDays(contentDiv.getAttribute('data-year'), contentDiv.getAttribute('data-month'), contentDiv);
        }
    }
}

/* Loads the day rows for a month into the supplied container. */
function jfm_loadMonthDays(year, month, container) {
    cc_engineFetch('/api/jobflow/history-month?year=' + year + '&month=' + month)
        .then(function(data) {
            if (!data) return;
            if (data.error) { container.innerHTML = '<div class="jfm-no-activity">Error loading data</div>'; return; }
            jfm_renderMonthDays(container, data.days || []);
        })
        .catch(function(err) { container.innerHTML = '<div class="jfm-no-activity">Failed to load: ' + err.message + '</div>'; });
}

/* ============================================================================
   FUNCTIONS: DAY DETAILS RENDER
   ----------------------------------------------------------------------------
   Renders the full day's flow groups and ad-hoc jobs in the slideout, with the
   per-flow validation verdict badge and the failed-jobs filter stat.
   Prefix: jfm
   ============================================================================ */

/* Builds the validation verdict badge for a flow in the day-details view. */
function jfm_buildValidationBadge(status) {
    if (!status) {
        return '<span class="jfm-validation-badge jfm-validation-badge-none" title="Not validated">Unvalidated</span>';
    }
    var valClass = 'jfm-validation-badge-success';
    var valLabel = 'Validated';
    if (status === 'CRITICAL_FAILURE' || status === 'SYSTEM_FAILURE') {
        valClass = 'jfm-validation-badge-error';
        valLabel = status === 'CRITICAL_FAILURE' ? 'Critical' : 'System Failure';
    } else if (status === 'PARTIAL_FAILURE' || status === 'BUSINESS_REJECTION') {
        valClass = 'jfm-validation-badge-warning';
        valLabel = status === 'PARTIAL_FAILURE' ? 'Partial' : 'Rejected';
    } else if (status === 'MISSING_JOBS') {
        valClass = 'jfm-validation-badge-error';
        valLabel = 'Missing Jobs';
    } else if (status === 'FLOW_NOT_RUN') {
        valClass = 'jfm-validation-badge-dimmed';
        valLabel = 'Not Run';
    }
    return '<span class="jfm-validation-badge ' + valClass + '" title="Validation: ' + cc_escapeHtml(status) + '">' + valLabel + '</span>';
}

/* Renders a full day's flows and ad-hoc jobs into the slideout body. */
function jfm_renderDayDetails(data) {
    var body = document.getElementById('jfm-slideout-body');
    var hasFlows = data.flows && data.flows.length > 0;
    var hasAdhoc = data.adhoc_jobs && data.adhoc_jobs.length > 0;

    if (!hasFlows && !hasAdhoc) {
        body.innerHTML = '<div class="cc-slide-empty">No executions found for this date</div>';
        return;
    }

    var totalFailedJobs = 0;
    if (hasFlows) {
        data.flows.forEach(function(flow) {
            if (flow.jobs) totalFailedJobs += flow.jobs.filter(function(j) { return j.is_failed; }).length;
        });
    }
    if (hasAdhoc) {
        totalFailedJobs += data.adhoc_jobs.filter(function(j) { return j.is_failed; }).length;
    }

    var failedStatClass = 'cc-slide-stat';
    var failedStatAction = '';
    if (totalFailedJobs > 0) {
        failedStatClass += ' jfm-stat-clickable' + (jfm_slideoutJobFilter === 'FAILED' ? ' jfm-stat-filter-active' : '');
        failedStatAction = ' data-action-click="jfm-toggle-failed-filter"';
    }

    var html = '<div class="cc-slide-summary">';
    html += '<div class="cc-slide-stat"><div class="cc-slide-stat-label">Flows</div><div class="cc-slide-stat-value">' + (data.flows ? data.flows.length : 0) + '</div></div>';
    html += '<div class="cc-slide-stat"><div class="cc-slide-stat-label">Ad Hoc</div><div class="cc-slide-stat-value">' + (data.adhoc_jobs ? data.adhoc_jobs.length : 0) + '</div></div>';
    html += '<div class="cc-slide-stat"><div class="cc-slide-stat-label">Total Jobs</div><div class="cc-slide-stat-value">' + (data.total_jobs || 0) + '</div></div>';
    html += '<div class="' + failedStatClass + '"' + failedStatAction + '><div class="cc-slide-stat-label">Failed</div><div class="cc-slide-stat-value ' + (totalFailedJobs > 0 ? 'jfm-stat-value-failed' : '') + '">' + totalFailedJobs + '</div></div>';
    html += '</div>';

    if (hasFlows) {
        html += '<div class="cc-slide-section-title">Flows (' + data.flows.length + ')</div>';
        data.flows.forEach(function(flow) {
            var flowFailedCount = flow.jobs ? flow.jobs.filter(function(j) { return j.is_failed; }).length : 0;
            if (jfm_slideoutJobFilter === 'FAILED' && flowFailedCount === 0) return;

            var hasFailures = flow.failed_jobs > 0;
            var valIcon = jfm_buildValidationBadge(flow.validation_status);
            var flowGroupStatusLabel = hasFailures ? 'Warning' : 'Complete';
            var flowGroupStatusClass = hasFailures ? 'warning' : 'complete';
            html += '<div class="jfm-flow-group"><div class="jfm-flow-group-header">';
            var flowLabel = cc_escapeHtml(flow.flow_code);
            if (flow.exec_hour_label) flowLabel += ' &mdash; ' + cc_escapeHtml(flow.exec_hour_label);
            html += '<span class="jfm-flow-code">' + flowLabel + '</span>';
            html += '<span class="jfm-flow-status-badge jfm-flow-status-badge-' + flowGroupStatusClass + '">' + flowGroupStatusLabel + '</span>' + valIcon;
            html += '<span class="jfm-flow-group-stats">' + flow.total_jobs + ' jobs' + (hasFailures ? ', <span class="jfm-stat-value-failed">' + flow.failed_jobs + ' failed</span>' : '') + '</span>';
            if (flow.duration) html += '<span class="jfm-flow-group-time">' + flow.duration + '</span>';
            html += '</div>';
            if (flow.jobs && flow.jobs.length > 0) {
                var displayJobs = jfm_filterJobs(flow.jobs);
                if (displayJobs.length > 0) {
                    html += jfm_buildJobsTable(displayJobs, false);
                }
            }
            html += '</div>';
        });
    }

    if (hasAdhoc) {
        var adhocDisplay = jfm_filterJobs(data.adhoc_jobs);
        if (adhocDisplay.length > 0) {
            html += '<div class="cc-slide-section-title">Ad Hoc Jobs (' + data.adhoc_jobs.length + ')</div>';
            html += jfm_buildJobsTable(adhocDisplay, true);
        }
    }
    body.innerHTML = html;
}

/* ============================================================================
   FUNCTIONS: PENDING AND AD-HOC SLIDEOUTS
   ----------------------------------------------------------------------------
   Opens the slideout for the pending queue and the ad-hoc job list, rendering
   from the datasets cached during the live and daily-summary loads.
   Prefix: jfm
   ============================================================================ */

/* Opens the pending-queue slideout. */
function jfm_openPendingQueueSlideout() {
    jfm_setSlideoutTitle('Pending Queue');
    jfm_renderPendingJobs(jfm_currentPendingData);
    jfm_openSlideout();
}

/* Opens the ad-hoc jobs slideout. */
function jfm_openAdhocSlideout() {
    jfm_setSlideoutTitle('Ad Hoc Jobs - Today');
    jfm_renderAdhocDetails(jfm_currentAdhocData);
    jfm_openSlideout();
}

/* Renders the ad-hoc job summary and table into the slideout body. */
function jfm_renderAdhocDetails(jobs) {
    var body = document.getElementById('jfm-slideout-body');

    if (!jobs || jobs.length === 0) {
        body.innerHTML = '<div class="cc-slide-empty">No ad hoc jobs today</div>';
        return;
    }

    var completedCount = jobs.filter(function(j) { return !j.is_failed; }).length;
    var failedCount = jobs.filter(function(j) { return j.is_failed; }).length;

    var html = '<div class="cc-slide-summary">';
    html += '<div class="cc-slide-stat"><div class="cc-slide-stat-label">Total</div><div class="cc-slide-stat-value">' + jobs.length + '</div></div>';
    html += '<div class="cc-slide-stat"><div class="cc-slide-stat-label">Succeeded</div><div class="cc-slide-stat-value jfm-stat-value-success">' + completedCount + '</div></div>';
    html += '<div class="cc-slide-stat"><div class="cc-slide-stat-label">Failed</div><div class="cc-slide-stat-value jfm-stat-value-failed">' + failedCount + '</div></div>';
    html += '</div>';

    html += '<div class="cc-slide-section-title">Jobs (' + jobs.length + ')</div>';
    html += jfm_buildJobsTable(jobs, true);
    body.innerHTML = html;
}

/* ============================================================================
   FUNCTIONS: CONFIGSYNC MODAL
   ----------------------------------------------------------------------------
   The flow configuration sync modal: opening and loading flow configs, the
   flow selector, the read-only view for aligned flows, and the editable views
   for new, deactivated, and reactivated flows.
   Prefix: jfm
   ============================================================================ */

/* Opens the configsync modal and loads flow configuration data. */
function jfm_openConfigSyncModal() {
    document.getElementById('jfm-modal-configsync').classList.remove('cc-hidden');
    document.getElementById('jfm-configsync-body').innerHTML = '<div class="jfm-loading">Loading flow configurations...</div>';
    document.getElementById('jfm-configsync-footer-actions').innerHTML = '';
    jfm_loadConfigSyncData();
}

/* Closes the configsync modal and clears its cached state. */
function jfm_closeConfigSyncModal(target, event) {
    if (event && event.target !== target) {
        return;
    }
    document.getElementById('jfm-modal-configsync').classList.add('cc-hidden');
    jfm_configSyncData = null;
    jfm_configSyncSelectedFlow = null;
    jfm_configSyncTaskSchedule = null;
}

/* Loads all flow configurations for the configsync modal. */
function jfm_loadConfigSyncData() {
    cc_engineFetch('/api/jobflow/configsync')
        .then(function(data) {
            if (!data) return;
            if (data.error) {
                document.getElementById('jfm-configsync-body').innerHTML = '<div class="jfm-cs-error">Error: ' + cc_escapeHtml(data.error) + '</div>';
                return;
            }
            jfm_configSyncData = data;
            jfm_renderConfigSyncSelector(data);
        })
        .catch(function(err) {
            document.getElementById('jfm-configsync-body').innerHTML = '<div class="jfm-cs-error">Failed to load: ' + cc_escapeHtml(err.message) + '</div>';
        });
}

/* Populates the flow selector dropdown and shows the alignment summary. */
function jfm_renderConfigSyncSelector(data) {
    var select = document.getElementById('jfm-configsync-flow-select');
    if (!select) return;

    var html = '<option value="">-- Select a flow --</option>';

    var hasMisaligned = false;
    data.flows.forEach(function(flow) {
        if (flow.misalignment_type) {
            if (!hasMisaligned) {
                html += '<optgroup label="&#9888; Needs Attention">';
                hasMisaligned = true;
            }
            var label = '\u26A0 ' + cc_escapeHtml(flow.flow_code);
            if (flow.misalignment_type === 'NEW') label += ' \u2014 New Flow';
            else if (flow.misalignment_type === 'DEACTIVATED') label += ' \u2014 Deactivated in DM';
            else if (flow.misalignment_type === 'REACTIVATED') label += ' \u2014 Reactivated in DM';
            html += '<option value="' + flow.config_id + '">' + label + '</option>';
        }
    });
    if (hasMisaligned) html += '</optgroup>';

    var activeFlows = data.flows.filter(function(f) { return !f.misalignment_type && f.dm_is_active !== false; });
    var inactiveFlows = data.flows.filter(function(f) { return !f.misalignment_type && f.dm_is_active === false; });

    if (activeFlows.length > 0) {
        html += '<optgroup label="Active Flows">';
        activeFlows.forEach(function(flow) {
            html += '<option value="' + flow.config_id + '">' + cc_escapeHtml(flow.flow_code) + ' \u2014 ' + cc_escapeHtml(flow.expected_schedule) + '</option>';
        });
        html += '</optgroup>';
    }

    if (inactiveFlows.length > 0) {
        html += '<optgroup label="Inactive Flows">';
        inactiveFlows.forEach(function(flow) {
            html += '<option value="' + flow.config_id + '">' + cc_escapeHtml(flow.flow_code) + ' \u2014 inactive</option>';
        });
        html += '</optgroup>';
    }

    select.innerHTML = html;

    var body = document.getElementById('jfm-configsync-body');
    if (data.misaligned_count > 0) {
        body.innerHTML = '<div class="jfm-cs-summary-banner jfm-cs-summary-banner-warning">' +
            '<span class="jfm-cs-banner-icon">&#9888;</span> ' +
            data.misaligned_count + ' flow' + (data.misaligned_count > 1 ? 's' : '') + ' need' + (data.misaligned_count === 1 ? 's' : '') + ' attention. Select a flow above to review.' +
            '</div>';
    } else {
        body.innerHTML = '<div class="jfm-cs-summary-banner jfm-cs-summary-banner-healthy">' +
            '<span class="jfm-cs-banner-icon">&#10004;</span> All flows are aligned between DM and xFACts. Select any flow to view its configuration.' +
            '</div>';
    }
    document.getElementById('jfm-configsync-footer-actions').innerHTML = '';
}

/* Handles flow selection: routes to the editable or read-only view. */
function jfm_onConfigSyncFlowSelected() {
    var select = document.getElementById('jfm-configsync-flow-select');
    var configId = parseInt(select.value, 10);
    jfm_configSyncTaskSchedule = null;

    if (!configId || !jfm_configSyncData) {
        jfm_renderConfigSyncSelector(jfm_configSyncData);
        return;
    }

    var flow = null;
    for (var i = 0; i < jfm_configSyncData.flows.length; i++) {
        if (jfm_configSyncData.flows[i].config_id === configId) {
            flow = jfm_configSyncData.flows[i];
            break;
        }
    }

    if (!flow) return;
    jfm_configSyncSelectedFlow = flow;

    if (flow.misalignment_type) {
        jfm_renderConfigSyncEditable(flow);
    } else {
        jfm_renderConfigSyncReadOnly(flow);
    }
}

/* Renders the read-only configuration view for an aligned flow. */
function jfm_renderConfigSyncReadOnly(flow) {
    var body = document.getElementById('jfm-configsync-body');
    var html = '';

    html += '<div class="jfm-cs-flow-header">';
    html += '<span class="jfm-cs-flow-code">' + cc_escapeHtml(flow.flow_code) + '</span>';
    if (flow.flow_name) html += '<span class="jfm-cs-flow-name">' + cc_escapeHtml(flow.flow_name) + '</span>';
    html += '</div>';

    html += '<div class="jfm-cs-badges">';
    html += '<span class="jfm-cs-badge ' + (flow.dm_is_active ? 'jfm-cs-badge-active' : 'jfm-cs-badge-inactive') + '">' + (flow.dm_is_active ? 'Active in DM' : 'Inactive in DM') + '</span>';
    html += '<span class="jfm-cs-badge ' + (flow.is_monitored ? 'jfm-cs-badge-active' : 'jfm-cs-badge-inactive') + '">' + (flow.is_monitored ? 'Monitored' : 'Not Monitored') + '</span>';
    html += '<span class="jfm-cs-badge jfm-cs-badge-neutral">' + cc_escapeHtml(flow.expected_schedule) + '</span>';
    html += '</div>';

    html += '<div class="jfm-cs-section-header">Monitoring Configuration</div>';
    html += '<div class="jfm-cs-detail-grid">';
    html += jfm_csDetailRow('Schedule', flow.expected_schedule);
    html += jfm_csDetailRow('Monitored', flow.is_monitored ? 'Yes' : 'No');
    html += jfm_csDetailRow('Alert on Missing', flow.alert_on_missing ? 'Yes' : 'No');
    html += jfm_csDetailRow('Alert on Failure', flow.alert_on_critical_failure ? 'Yes' : 'No');
    html += jfm_csDetailRow('Effective From', flow.effective_start_date || '-');
    html += jfm_csDetailRow('Effective Until', flow.effective_end_date || 'No expiration');
    if (flow.notes) html += jfm_csDetailRow('Notes', flow.notes);
    html += '</div>';

    if (flow.schedule) {
        html += '<div class="jfm-cs-section-header">Schedule Details</div>';
        html += '<div class="jfm-cs-detail-grid">';
        html += jfm_csDetailRow('Type', flow.schedule.schedule_type);
        html += jfm_csDetailRow('Start Time', flow.schedule.expected_start_time || '-');
        html += jfm_csDetailRow('Tolerance', flow.schedule.start_time_tolerance_minutes + ' min');
        if (flow.schedule.schedule_frequency) html += jfm_csDetailRow('Frequency', 'Every ' + flow.schedule.schedule_frequency + ' hours');
        if (flow.schedule.schedule_day_of_week) html += jfm_csDetailRow('Day of Week', jfm_csDayName(flow.schedule.schedule_day_of_week));
        if (flow.schedule.schedule_day_of_month) html += jfm_csDetailRow('Day of Month', jfm_csOrdinal(flow.schedule.schedule_day_of_month));
        if (flow.schedule.schedule_week_of_month) html += jfm_csDetailRow('Week of Month', jfm_csOrdinal(flow.schedule.schedule_week_of_month));
        html += jfm_csDetailRow('Schedule Active', flow.schedule.is_active ? 'Yes' : 'No');
        html += '</div>';
    }

    html += '<div class="jfm-cs-section-header">Audit</div>';
    html += '<div class="jfm-cs-detail-grid">';
    html += jfm_csDetailRow('Last DM Sync', flow.dm_last_sync_dttm || 'Never');
    html += jfm_csDetailRow('Last Modified', flow.modified_dttm || '-');
    html += jfm_csDetailRow('Modified By', flow.modified_by || '-');
    html += '</div>';

    body.innerHTML = html;
    document.getElementById('jfm-configsync-footer-actions').innerHTML = '';
}

/* Renders the editable view for a misaligned flow (new/deactivated/reactivated). */
function jfm_renderConfigSyncEditable(flow) {
    var body = document.getElementById('jfm-configsync-body');
    var html = '';

    html += '<div class="jfm-cs-flow-header">';
    html += '<span class="jfm-cs-flow-code">' + cc_escapeHtml(flow.flow_code) + '</span>';
    if (flow.flow_name) html += '<span class="jfm-cs-flow-name">' + cc_escapeHtml(flow.flow_name) + '</span>';
    html += '</div>';

    if (flow.misalignment_type === 'NEW') {
        html += '<div class="jfm-cs-banner jfm-cs-banner-new">' +
            '<strong>New Flow Detected</strong><br>' +
            'This flow exists in Debt Manager but hasn\'t been configured in xFACts yet. ' +
            'Choose how this flow should be monitored.' +
            '</div>';
        html += jfm_renderNewFlowForm(flow);
    }
    else if (flow.misalignment_type === 'DEACTIVATED') {
        html += '<div class="jfm-cs-banner jfm-cs-banner-deactivated">' +
            '<strong>Flow Deactivated in DM</strong><br>' +
            'This flow was deactivated in Debt Manager but is still being monitored by xFACts. ' +
            'Recommended action: disable monitoring and end-date the configuration.' +
            '</div>';
        html += jfm_renderDeactivateForm(flow);
    }
    else if (flow.misalignment_type === 'REACTIVATED') {
        var prevSchedule = flow.schedule ? flow.schedule.schedule_type : 'unknown';
        var prevTime = flow.schedule ? flow.schedule.expected_start_time : '';
        html += '<div class="jfm-cs-banner jfm-cs-banner-reactivated">' +
            '<strong>Flow Reactivated in DM</strong><br>' +
            'This flow was reactivated in Debt Manager. Previously scheduled as ' + cc_escapeHtml(prevSchedule) +
            (prevTime ? ' at ' + cc_escapeHtml(prevTime) : '') + '. ' +
            'Review the schedule and re-enable monitoring.' +
            '</div>';
        html += jfm_renderReactivateForm(flow);
    }

    body.innerHTML = html;

    if (flow.misalignment_type === 'NEW') {
        jfm_queryTaskSchedule(flow.flow_code);
    } else {
        jfm_updateConfigSyncFooter();
    }
}

/* ============================================================================
   FUNCTIONS: CONFIGSYNC FORMS
   ----------------------------------------------------------------------------
   The new-flow forms (Task Scheduler lookup, scheduled-flow form, and the
   no-task chooser), the schedule-type field toggling, and the deactivate and
   reactivate forms. The chooser uses the clicked element passed by the
   dispatcher to highlight the selection.
   Prefix: jfm
   ============================================================================ */

/* Renders the new-flow area placeholder while Task Scheduler is queried. */
function jfm_renderNewFlowForm(flow) {
    var html = '<div id="jfm-cs-new-flow-area">';
    html += '<div class="jfm-cs-task-loading" id="jfm-cs-task-status">' +
        '<span class="jfm-cs-spinner"></span> Checking Task Scheduler for ' + cc_escapeHtml(flow.flow_code) + '...' +
        '</div>';
    html += '</div>';
    return html;
}

/* Queries Task Scheduler for a flow and renders the matching new-flow form. */
function jfm_queryTaskSchedule(flowCode) {
    cc_engineFetch('/api/jobflow/configsync/task-schedule?flow_code=' + encodeURIComponent(flowCode))
        .then(function(data) {
            if (!data) return;
            if (data.error) {
                document.getElementById('jfm-cs-task-status').innerHTML = '<span class="jfm-cs-error-text">Error querying Task Scheduler: ' + cc_escapeHtml(data.error) + '</span>';
                return;
            }
            jfm_configSyncTaskSchedule = data;

            if (data.task_found && data.parsed_schedule && data.parsed_schedule.schedule_type) {
                jfm_renderScheduledFlowForm(data.parsed_schedule);
            } else {
                jfm_renderNoTaskForm();
            }
        })
        .catch(function(err) {
            document.getElementById('jfm-cs-task-status').innerHTML = '<span class="jfm-cs-error-text">Failed to query Task Scheduler: ' + cc_escapeHtml(err.message) + '</span>';
        });
}

/* Renders the scheduled-flow form prefilled from parsed Task Scheduler data. */
function jfm_renderScheduledFlowForm(parsed) {
    var area = document.getElementById('jfm-cs-new-flow-area');
    var html = '<div class="jfm-cs-task-found">Task Scheduler entry found. Review the detected schedule below.</div>';
    html += '<div class="jfm-cs-section-header">Schedule</div>';
    html += '<div class="jfm-cs-form-grid">';

    html += '<div class="jfm-cs-form-group">';
    html += '<label>Schedule Type</label>';
    html += '<select id="jfm-cs-schedule-type" class="jfm-cs-form-control" data-action-change="jfm-cs-schedule-type-changed">';
    var types = ['DAILY', 'WEEKLY', 'MONTHLY', 'EVERY_N_HOURS'];
    types.forEach(function(t) {
        html += '<option value="' + t + '"' + (parsed.schedule_type === t ? ' selected' : '') + '>' + t + '</option>';
    });
    html += '</select></div>';

    html += '<div class="jfm-cs-form-group">';
    html += '<label>Start Time</label>';
    html += '<input type="time" id="jfm-cs-start-time" class="jfm-cs-form-control" value="' + (parsed.expected_start_time || '22:00') + '">';
    html += '</div>';

    html += '<div class="jfm-cs-form-group">';
    html += '<label>Tolerance (min)</label>';
    html += '<input type="number" id="jfm-cs-tolerance" class="jfm-cs-form-control" value="30" min="0" max="240">';
    html += '</div>';

    html += '<div class="jfm-cs-form-group' + (parsed.schedule_type !== 'EVERY_N_HOURS' ? ' jfm-cs-hidden' : '') + '" id="jfm-cs-frequency-group">';
    html += '<label>Every N Hours</label>';
    html += '<input type="number" id="jfm-cs-frequency" class="jfm-cs-form-control" value="' + (parsed.schedule_frequency || 4) + '" min="1" max="24">';
    html += '</div>';

    var showDow = parsed.schedule_type === 'WEEKLY' || (parsed.schedule_type === 'MONTHLY' && parsed.schedule_week_of_month);
    html += '<div class="jfm-cs-form-group' + (!showDow ? ' jfm-cs-hidden' : '') + '" id="jfm-cs-dow-group">';
    html += '<label>Day of Week</label>';
    html += '<select id="jfm-cs-day-of-week" class="jfm-cs-form-control">';
    var days = [['1', 'Sunday'], ['2', 'Monday'], ['3', 'Tuesday'], ['4', 'Wednesday'], ['5', 'Thursday'], ['6', 'Friday'], ['7', 'Saturday']];
    days.forEach(function(d) {
        html += '<option value="' + d[0] + '"' + (parsed.schedule_day_of_week == d[0] ? ' selected' : '') + '>' + d[1] + '</option>';
    });
    html += '</select></div>';

    var showDom = parsed.schedule_type === 'MONTHLY' && parsed.schedule_day_of_month && !parsed.schedule_week_of_month;
    html += '<div class="jfm-cs-form-group' + (!showDom ? ' jfm-cs-hidden' : '') + '" id="jfm-cs-dom-group">';
    html += '<label>Day of Month</label>';
    html += '<input type="number" id="jfm-cs-day-of-month" class="jfm-cs-form-control" value="' + (parsed.schedule_day_of_month || 1) + '" min="1" max="31">';
    html += '</div>';

    var showWom = parsed.schedule_type === 'MONTHLY' && parsed.schedule_week_of_month;
    html += '<div class="jfm-cs-form-group' + (!showWom ? ' jfm-cs-hidden' : '') + '" id="jfm-cs-wom-group">';
    html += '<label>Week of Month</label>';
    html += '<select id="jfm-cs-week-of-month" class="jfm-cs-form-control">';
    var weeks = [['1', '1st'], ['2', '2nd'], ['3', '3rd'], ['4', '4th'], ['5', '5th (last)']];
    weeks.forEach(function(w) {
        html += '<option value="' + w[0] + '"' + (parsed.schedule_week_of_month == w[0] ? ' selected' : '') + '>' + w[1] + '</option>';
    });
    html += '</select></div>';

    html += '</div>';

    html += '<div class="jfm-cs-section-header">Alert Settings</div>';
    html += '<div class="jfm-cs-checkbox-row">';
    html += '<label class="jfm-cs-checkbox"><input type="checkbox" id="jfm-cs-alert-missing" checked> Alert on Missing</label>';
    html += '<label class="jfm-cs-checkbox"><input type="checkbox" id="jfm-cs-alert-failure" checked> Alert on Failure</label>';
    html += '<label class="jfm-cs-checkbox"><input type="checkbox" id="jfm-cs-monitored" checked> Monitored</label>';
    html += '</div>';

    area.innerHTML = html;
    jfm_configSyncSelectedFlow._action = 'configure_new';
    jfm_configSyncSelectedFlow._flowType = 'SCHEDULED';
    jfm_updateConfigSyncFooter();
}

/* Renders the no-task chooser when no Task Scheduler entry exists. */
function jfm_renderNoTaskForm() {
    var area = document.getElementById('jfm-cs-new-flow-area');
    var html = '<div class="jfm-cs-task-not-found">' +
        '<span class="jfm-cs-banner-icon">&#8505;</span> No Task Scheduler entry found for this flow. How is it executed?' +
        '</div>';

    html += '<div class="jfm-cs-chooser">';
    html += '<div class="jfm-cs-chooser-option" data-action-click="jfm-select-flow-type" data-flow-type="VARIABLE">';
    html += '<div class="jfm-cs-chooser-title">Triggered by External Process</div>';
    html += '<div class="jfm-cs-chooser-desc">Initiated by an external system or API call (e.g., SendRight). Monitor for failures only.</div>';
    html += '</div>';

    html += '<div class="jfm-cs-chooser-option" data-action-click="jfm-select-flow-type" data-flow-type="ON-DEMAND">';
    html += '<div class="jfm-cs-chooser-title">Executed Manually in DM</div>';
    html += '<div class="jfm-cs-chooser-desc">Run by a human through the DM user interface. No monitoring needed.</div>';
    html += '</div>';

    html += '<div class="jfm-cs-chooser-option" data-action-click="jfm-select-flow-type" data-flow-type="SCHEDULED">';
    html += '<div class="jfm-cs-chooser-title">Runs on a Regular Schedule</div>';
    html += '<div class="jfm-cs-chooser-desc">Should have a Task Scheduler entry but doesn\'t yet. Create the scheduled task first, then configure here.</div>';
    html += '</div>';
    html += '</div>';

    area.innerHTML = html;
    document.getElementById('jfm-configsync-footer-actions').innerHTML = '';
}

/* Handles a no-task chooser selection, building the matching preview. */
function jfm_selectFlowType(type, target) {
    document.querySelectorAll('.jfm-cs-chooser-option').forEach(function(el) { el.classList.remove('jfm-cs-chooser-option-selected'); });
    if (target) target.classList.add('jfm-cs-chooser-option-selected');

    var existing = document.getElementById('jfm-cs-type-details');
    if (existing) existing.remove();

    if (type === 'VARIABLE' || type === 'ON-DEMAND') {
        var monitored = type === 'VARIABLE' ? 'Yes' : 'No';
        var alertMissing = 'No';
        var alertFailure = type === 'VARIABLE' ? 'Yes' : 'No';

        var details = document.createElement('div');
        details.id = 'jfm-cs-type-details';
        details.className = 'jfm-cs-type-summary';
        details.innerHTML = '<div class="jfm-cs-section-header">Configuration Preview</div>' +
            '<div class="jfm-cs-detail-grid">' +
            jfm_csDetailRow('Schedule', type) +
            jfm_csDetailRow('Monitored', monitored) +
            jfm_csDetailRow('Alert on Missing', alertMissing) +
            jfm_csDetailRow('Alert on Failure', alertFailure) +
            '</div>';
        document.getElementById('jfm-cs-new-flow-area').appendChild(details);

        jfm_configSyncSelectedFlow._action = 'configure_new';
        jfm_configSyncSelectedFlow._flowType = type;
        jfm_updateConfigSyncFooter();
    }
    else if (type === 'SCHEDULED') {
        var info = document.createElement('div');
        info.id = 'jfm-cs-type-details';
        info.className = 'jfm-cs-type-summary jfm-cs-info-box';
        info.innerHTML = '<span class="jfm-cs-banner-icon">&#8505;</span> ' +
            'Create the scheduled task on the app server first, then re-open this dialog. ' +
            'The task should follow the naming convention: <strong>DM Night Job - ' + cc_escapeHtml(jfm_configSyncSelectedFlow.flow_code) + '</strong>';
        document.getElementById('jfm-cs-new-flow-area').appendChild(info);

        jfm_configSyncSelectedFlow._action = null;
        jfm_configSyncSelectedFlow._flowType = null;
        document.getElementById('jfm-configsync-footer-actions').innerHTML = '';
    }
}

/* Shows/hides the schedule sub-fields when the schedule type changes. */
function jfm_onCsScheduleTypeChanged() {
    var type = document.getElementById('jfm-cs-schedule-type').value;

    document.getElementById('jfm-cs-frequency-group').classList.toggle('jfm-cs-hidden', type !== 'EVERY_N_HOURS');
    document.getElementById('jfm-cs-dow-group').classList.toggle('jfm-cs-hidden', type !== 'WEEKLY' && type !== 'MONTHLY');
    document.getElementById('jfm-cs-dom-group').classList.toggle('jfm-cs-hidden', type !== 'MONTHLY');
    document.getElementById('jfm-cs-wom-group').classList.toggle('jfm-cs-hidden', type !== 'MONTHLY');

    if (type === 'MONTHLY') {
        document.getElementById('jfm-cs-dow-group').classList.remove('jfm-cs-hidden');
        document.getElementById('jfm-cs-wom-group').classList.remove('jfm-cs-hidden');
        document.getElementById('jfm-cs-dom-group').classList.remove('jfm-cs-hidden');
    }
}

/* Renders the deactivate form and sets the action. */
function jfm_renderDeactivateForm(flow) {
    var html = '<div class="jfm-cs-section-header">Changes to Apply</div>';
    html += '<div class="jfm-cs-detail-grid">';
    html += jfm_csDetailRow('Set Monitored', 'No');
    html += jfm_csDetailRow('Set End Date', 'Today (' + new Date().toISOString().split('T')[0] + ')');
    if (flow.schedule) {
        html += jfm_csDetailRow('Schedule', 'Will be deactivated');
    }
    html += '</div>';

    jfm_configSyncSelectedFlow._action = 'deactivate';
    return html;
}

/* Renders the reactivate form and sets the action. */
function jfm_renderReactivateForm(flow) {
    var html = '<div class="jfm-cs-section-header">Previous Configuration</div>';
    html += '<div class="jfm-cs-detail-grid">';
    if (flow.schedule) {
        html += jfm_csDetailRow('Schedule Type', flow.schedule.schedule_type);
        html += jfm_csDetailRow('Start Time', flow.schedule.expected_start_time || '-');
        html += jfm_csDetailRow('Tolerance', flow.schedule.start_time_tolerance_minutes + ' min');
        if (flow.schedule.schedule_day_of_week) html += jfm_csDetailRow('Day of Week', jfm_csDayName(flow.schedule.schedule_day_of_week));
        if (flow.schedule.schedule_day_of_month) html += jfm_csDetailRow('Day of Month', jfm_csOrdinal(flow.schedule.schedule_day_of_month));
        if (flow.schedule.schedule_week_of_month) html += jfm_csDetailRow('Week of Month', jfm_csOrdinal(flow.schedule.schedule_week_of_month));
    }
    html += '</div>';

    html += '<div class="jfm-cs-section-header">Re-enable Settings</div>';
    html += '<div class="jfm-cs-checkbox-row">';
    html += '<label class="jfm-cs-checkbox"><input type="checkbox" id="jfm-cs-react-monitored" checked> Enable Monitoring</label>';
    html += '</div>';

    jfm_configSyncSelectedFlow._action = 'reactivate';
    return html;
}

/* ============================================================================
   FUNCTIONS: CONFIGSYNC SAVE
   ----------------------------------------------------------------------------
   The footer action button, the confirmation dialog summarizing the staged
   changes, and the save executor that posts the configuration to the API.
   Prefix: jfm
   ============================================================================ */

/* Renders the footer save button appropriate to the selected flow's action. */
function jfm_updateConfigSyncFooter() {
    var footer = document.getElementById('jfm-configsync-footer-actions');
    var flow = jfm_configSyncSelectedFlow;
    if (!flow || !flow.misalignment_type || !flow._action) {
        footer.innerHTML = '';
        return;
    }

    var label = 'Apply Changes';
    if (flow._action === 'deactivate') label = 'Deactivate Flow';
    else if (flow._action === 'reactivate') label = 'Reactivate Flow';
    else if (flow._action === 'configure_new') label = 'Save Configuration';

    footer.innerHTML = '<button class="jfm-cs-btn jfm-cs-btn-primary" data-action-click="jfm-save-configsync">' + label + '</button>';
}

/* Builds and shows the configsync confirmation dialog. */
function jfm_showConfigSyncConfirmation() {
    var flow = jfm_configSyncSelectedFlow;
    if (!flow || !flow._action) return;

    var html = '<div class="jfm-cs-confirm-header">' + cc_escapeHtml(flow.flow_code) + '</div>';
    html += '<div class="jfm-cs-confirm-subheader">The following changes will be applied:</div>';
    html += '<div class="jfm-cs-confirm-changes">';

    if (flow._action === 'configure_new') {
        if (flow._flowType === 'VARIABLE') {
            html += jfm_csConfirmRow('Schedule Type', 'VARIABLE');
            html += jfm_csConfirmRow('Monitored', 'Yes');
            html += jfm_csConfirmRow('Alert on Missing', 'No');
            html += jfm_csConfirmRow('Alert on Failure', 'Yes');
        }
        else if (flow._flowType === 'ON-DEMAND') {
            html += jfm_csConfirmRow('Schedule Type', 'ON-DEMAND');
            html += jfm_csConfirmRow('Monitored', 'No');
            html += jfm_csConfirmRow('Alert on Missing', 'No');
            html += jfm_csConfirmRow('Alert on Failure', 'No');
        }
        else {
            var schedType = document.getElementById('jfm-cs-schedule-type').value;
            var startTime = document.getElementById('jfm-cs-start-time').value;
            var tolerance = document.getElementById('jfm-cs-tolerance').value;
            var monitored = document.getElementById('jfm-cs-monitored').checked;
            var alertMissing = document.getElementById('jfm-cs-alert-missing').checked;
            var alertFailure = document.getElementById('jfm-cs-alert-failure').checked;

            html += jfm_csConfirmRow('Schedule Type', schedType);
            html += jfm_csConfirmRow('Start Time', startTime);
            html += jfm_csConfirmRow('Tolerance', tolerance + ' minutes');

            if (schedType === 'EVERY_N_HOURS') {
                html += jfm_csConfirmRow('Frequency', 'Every ' + document.getElementById('jfm-cs-frequency').value + ' hours');
            }
            if (schedType === 'WEEKLY') {
                var dowW = document.getElementById('jfm-cs-day-of-week');
                html += jfm_csConfirmRow('Day of Week', dowW.options[dowW.selectedIndex].text);
            }
            if (schedType === 'MONTHLY') {
                var domM = document.getElementById('jfm-cs-day-of-month').value;
                var womM = document.getElementById('jfm-cs-week-of-month');
                var dowM = document.getElementById('jfm-cs-day-of-week');
                if (womM.value && dowM.value) {
                    html += jfm_csConfirmRow('Schedule', womM.options[womM.selectedIndex].text + ' ' + dowM.options[dowM.selectedIndex].text);
                } else if (domM) {
                    html += jfm_csConfirmRow('Day of Month', jfm_csOrdinal(parseInt(domM, 10)));
                }
            }

            html += jfm_csConfirmRow('Monitored', monitored ? 'Yes' : 'No');
            html += jfm_csConfirmRow('Alert on Missing', alertMissing ? 'Yes' : 'No');
            html += jfm_csConfirmRow('Alert on Failure', alertFailure ? 'Yes' : 'No');
            html += '<div class="jfm-cs-confirm-note">A new Schedule row will be created.</div>';
        }
    }
    else if (flow._action === 'deactivate') {
        html += jfm_csConfirmRow('Monitored', 'No (was Yes)');
        html += jfm_csConfirmRow('Effective End Date', new Date().toISOString().split('T')[0]);
        if (flow.schedule) {
            html += jfm_csConfirmRow('Schedule', 'Will be deactivated');
        }
    }
    else if (flow._action === 'reactivate') {
        var monitoredR = document.getElementById('jfm-cs-react-monitored').checked;
        html += jfm_csConfirmRow('Monitored', monitoredR ? 'Yes' : 'No');
        html += jfm_csConfirmRow('Effective End Date', 'Cleared');
        if (flow.schedule) {
            html += jfm_csConfirmRow('Schedule', 'Will be reactivated');
        }
    }

    html += '</div>';

    document.getElementById('jfm-cs-confirm-body').innerHTML = html;
    document.getElementById('jfm-modal-cs-confirm').classList.remove('cc-hidden');
}

/* Closes the configsync confirmation dialog. */
function jfm_closeConfigSyncConfirmation(target, event) {
    if (event && event.target !== target) {
        return;
    }
    document.getElementById('jfm-modal-cs-confirm').classList.add('cc-hidden');
}

/* Confirmation handler: closes the dialog and executes the save. */
function jfm_confirmAndSaveConfigSync() {
    jfm_closeConfigSyncConfirmation();
    jfm_executeConfigSyncSave();
}

/* Save entry point: opens the confirmation dialog before saving. */
function jfm_saveConfigSync() {
    jfm_showConfigSyncConfirmation();
}

/* Posts the staged configuration to the save endpoint and reloads on success. */
function jfm_executeConfigSyncSave() {
    var flow = jfm_configSyncSelectedFlow;
    if (!flow || !flow._action) return;

    var payload = {
        action: flow._action,
        config_id: flow.config_id,
        job_sqnc_id: flow.job_sqnc_id,
        flow_code: flow.flow_code
    };

    if (flow._action === 'configure_new') {
        if (flow._flowType === 'VARIABLE') {
            payload.expected_schedule = 'VARIABLE';
            payload.is_monitored = true;
            payload.alert_on_missing = false;
            payload.alert_on_critical_failure = true;
        }
        else if (flow._flowType === 'ON-DEMAND') {
            payload.expected_schedule = 'ON-DEMAND';
            payload.is_monitored = false;
            payload.alert_on_missing = false;
            payload.alert_on_critical_failure = false;
        }
        else {
            var schedType = document.getElementById('jfm-cs-schedule-type').value;
            payload.expected_schedule = schedType;
            payload.is_monitored = document.getElementById('jfm-cs-monitored').checked;
            payload.alert_on_missing = document.getElementById('jfm-cs-alert-missing').checked;
            payload.alert_on_critical_failure = document.getElementById('jfm-cs-alert-failure').checked;

            payload.schedule = {
                schedule_type: schedType,
                expected_start_time: document.getElementById('jfm-cs-start-time').value + ':00',
                start_time_tolerance_minutes: parseInt(document.getElementById('jfm-cs-tolerance').value, 10) || 30
            };

            if (schedType === 'EVERY_N_HOURS') {
                payload.schedule.schedule_frequency = parseInt(document.getElementById('jfm-cs-frequency').value, 10) || 4;
            }
            if (schedType === 'WEEKLY' || schedType === 'MONTHLY') {
                var dow = document.getElementById('jfm-cs-day-of-week').value;
                if (dow) payload.schedule.schedule_day_of_week = parseInt(dow, 10);
            }
            if (schedType === 'MONTHLY') {
                var dom = document.getElementById('jfm-cs-day-of-month').value;
                var wom = document.getElementById('jfm-cs-week-of-month').value;
                if (dom) payload.schedule.schedule_day_of_month = parseInt(dom, 10);
                if (wom) payload.schedule.schedule_week_of_month = parseInt(wom, 10);
            }
        }
    }
    else if (flow._action === 'reactivate') {
        payload.is_monitored = document.getElementById('jfm-cs-react-monitored').checked;
    }

    var btn = document.querySelector('#jfm-configsync-footer-actions .jfm-cs-btn-primary');
    if (btn) { btn.disabled = true; btn.textContent = 'Saving...'; }

    cc_engineFetch('/api/jobflow/configsync/save', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload)
    })
        .then(function(data) {
            if (!data) return;
            if (data.error) {
                cc_showAlert('Save failed: ' + data.error);
                if (btn) { btn.disabled = false; btn.textContent = 'Retry'; }
                return;
            }

            var body = document.getElementById('jfm-configsync-body');
            body.innerHTML = '<div class="jfm-cs-summary-banner jfm-cs-summary-banner-healthy">' +
                '<span class="jfm-cs-banner-icon">&#10004;</span> ' +
                cc_escapeHtml(flow.flow_code) + ' updated successfully.' +
                '</div>';
            document.getElementById('jfm-configsync-footer-actions').innerHTML = '';

            setTimeout(function() {
                jfm_loadConfigSyncData();
                jfm_loadProcessStatus();
            }, 1500);
        })
        .catch(function(err) {
            cc_showAlert('Save failed: ' + err.message);
            if (btn) { btn.disabled = false; btn.textContent = 'Retry'; }
        });
}

/* ============================================================================
   FUNCTIONS: UTILITIES
   ----------------------------------------------------------------------------
   Small formatting helpers shared across the page: a display-date formatter
   for slideout titles, and the configsync detail/confirm row builders, day
   name, and ordinal formatters.
   Prefix: jfm
   ============================================================================ */

/* Formats a YYYY-MM-DD date as "Month D, YYYY" without timezone shift. */
function jfm_formatDisplayDate(dateStr) {
    if (!dateStr) return '-';
    var parts = dateStr.split('-');
    if (parts.length !== 3) return dateStr;
    var month = parseInt(parts[1], 10);
    var day = parseInt(parts[2], 10);
    return jfm_MONTH_NAMES[month] + ' ' + day + ', ' + parseInt(parts[0], 10);
}

/* Builds a label/value pair for the configsync detail grid. */
function jfm_csDetailRow(label, value) {
    return '<div class="jfm-cs-detail-label">' + cc_escapeHtml(label) + '</div>' +
           '<div class="jfm-cs-detail-value">' + cc_escapeHtml(value || '-') + '</div>';
}

/* Builds a label/value row for the configsync confirmation dialog. */
function jfm_csConfirmRow(label, value) {
    return '<div class="jfm-cs-confirm-row">' +
        '<span class="jfm-cs-confirm-label">' + cc_escapeHtml(label) + ':</span> ' +
        '<span class="jfm-cs-confirm-value">' + cc_escapeHtml(value) + '</span>' +
        '</div>';
}

/* Returns the weekday name for a 1-7 day-of-week number. */
function jfm_csDayName(num) {
    var names = { 1: 'Sunday', 2: 'Monday', 3: 'Tuesday', 4: 'Wednesday', 5: 'Thursday', 6: 'Friday', 7: 'Saturday' };
    return names[num] || num;
}

/* Returns the ordinal form of a number (1st, 2nd, 3rd, ...). */
function jfm_csOrdinal(num) {
    var suffix = 'th';
    if (num === 1 || num === 21 || num === 31) suffix = 'st';
    else if (num === 2 || num === 22) suffix = 'nd';
    else if (num === 3 || num === 23) suffix = 'rd';
    return num + suffix;
}

/* ============================================================================
   FUNCTIONS: PAGE LIFECYCLE HOOKS
   ----------------------------------------------------------------------------
   Hooks invoked by the cc-shared engine module: a manual/refresh-button
   refresh, tab-resume refresh, session-expiry cleanup, and the
   orchestrator process-completed trigger that refreshes the event sections.
   Prefix: jfm
   ============================================================================ */

/* Refresh-button hook: reloads every section. */
function jfm_onPageRefresh() {
    jfm_refreshAll();
}

/* Tab-resume hook: reloads every section when the tab becomes visible. */
function jfm_onPageResumed() {
    jfm_refreshAll();
}

/* Session-expiry hook: stops the page-local live polling timer. */
function jfm_onSessionExpired() {
    if (jfm_livePollingTimer) {
        clearInterval(jfm_livePollingTimer);
        jfm_livePollingTimer = null;
    }
}

/* Process-completed hook: refreshes the event-driven sections. */
function jfm_onEngineProcessCompleted(processName, event) {
    jfm_refreshEventSections();
}

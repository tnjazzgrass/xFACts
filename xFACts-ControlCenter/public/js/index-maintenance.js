/* ============================================================================
   xFACts Control Center - Index Maintenance Client Logic (index-maintenance.js)
   Location: E:\xFACts-ControlCenter\public\js\index-maintenance.js
   Version: Tracked in dbo.System_Metadata (component: ServerOps.Index)

   Client-side logic for the Index Maintenance dashboard. Loads and renders
   live activity, process status, the index queue, active rebuild execution,
   and the database overview; drives the detail slideouts for each engine
   process and the queue; manages the interactive per-database maintenance
   schedule grid with click-drag editing; and gates the admin-only manual
   launch flow on a server-provided per-process flag. Engine indicator cards,
   the shared fetch wrapper, connection banners, and page-refresh chrome are
   provided by cc-shared.js.

   FILE ORGANIZATION
   -----------------
   CONSTANTS: ENGINE PROCESSES
   CONSTANTS: PROCESS METADATA
   CONSTANTS: ACTION DISPATCH TABLES
   STATE: POLLING STATE
   STATE: SCHEDULE DRAG STATE
   FUNCTIONS: INITIALIZATION
   FUNCTIONS: ACTION DISPATCH
   FUNCTIONS: FORMATTING UTILITIES
   FUNCTIONS: OVERLAY OPEN AND CLOSE
   FUNCTIONS: LIVE ACTIVITY
   FUNCTIONS: PROCESS STATUS
   FUNCTIONS: MANUAL LAUNCH
   FUNCTIONS: PROCESS DETAIL SLIDEOUTS
   FUNCTIONS: ACTIVE EXECUTION
   FUNCTIONS: QUEUE
   FUNCTIONS: DATABASE OVERVIEW
   FUNCTIONS: SCHEDULE EDITOR
   FUNCTIONS: SCHEDULE DRAG SELECTION
   FUNCTIONS: REFRESH AND POLLING
   FUNCTIONS: PAGE LIFECYCLE HOOKS
   ============================================================================ */

/* ============================================================================
   CONSTANTS: ENGINE PROCESSES
   ----------------------------------------------------------------------------
   Maps Orchestrator.ProcessRegistry process names to their engine-card slugs
   so cc-shared.js can route WebSocket engine events to the correct card.
   Declared with var per the engine-processes rule.
   Prefix: idx
   ============================================================================ */

/* Engine process-to-slug map consumed by cc-shared.js for engine-card events. */
var idx_ENGINE_PROCESSES = {
    'Sync-IndexRegistry':       { slug: 'sync' },
    'Scan-IndexFragmentation':  { slug: 'scan' },
    'Execute-IndexMaintenance': { slug: 'execute' },
    'Update-IndexStatistics':   { slug: 'stats' }
};

/* ============================================================================
   CONSTANTS: PROCESS METADATA
   ----------------------------------------------------------------------------
   Display lookups for the four engine processes: human-readable card titles,
   per-process metric labels, and the short badge labels used on the admin
   launch control and the launch confirmation dialog.
   Prefix: idx
   ============================================================================ */

/* Human-readable process-card titles keyed by process name. */
const idx_processDescriptions = {
    'SYNC':    'Registry Sync',
    'SCAN':    'Frag Scan',
    'EXECUTE': 'Rebuild',
    'STATS':   'Stats Update'
};

/* Per-process metric row labels keyed by process name. */
const idx_processMetricLabels = {
    'SYNC':    { processed: 'Updated',   added: 'New',       skipped: 'Dropped' },
    'SCAN':    { processed: 'Scanned',   added: 'Queued',    skipped: 'Removed' },
    'EXECUTE': { processed: 'Rebuilt',   added: 'Succeeded', skipped: 'Deferred' },
    'STATS':   { processed: 'Evaluated', added: 'Updated',   skipped: 'Skipped' }
};

/* Short labels for the admin launch badge keyed by process name. */
const idx_badgeLabels = {
    'SYNC':    'Sync',
    'SCAN':    'Scan',
    'EXECUTE': 'Execute',
    'STATS':   'Stats'
};

/* Full labels for the launch confirmation dialog keyed by process name. */
const idx_launchLabels = {
    'SYNC':    'Registry Sync',
    'SCAN':    'Frag Scan',
    'EXECUTE': 'Rebuild',
    'STATS':   'Stats Update'
};

/* Maps a process name to its detail-slideout open action. */
const idx_processDetailActions = {
    'SYNC':    'idx-open-sync',
    'SCAN':    'idx-open-scan',
    'EXECUTE': 'idx-open-execute',
    'STATS':   'idx-open-stats'
};

/* ============================================================================
   CONSTANTS: ACTION DISPATCH TABLES
   ----------------------------------------------------------------------------
   Per-event dispatch tables mapping this page's data-action-<event> values to
   handler functions. Registered as delegated listeners on document.body in
   idx_init. Keys carry the idx- page prefix; values are bare function
   references defined in this file.
   Prefix: idx
   ============================================================================ */

/* Click-action dispatch table for the page. */
const idx_clickActions = {
    'idx-open-queue-details': idx_openQueueDetails,
    'idx-close-queue':        idx_closeQueue,
    'idx-open-sync':          idx_openSyncDetails,
    'idx-close-sync':         idx_closeSync,
    'idx-open-scan':          idx_openScanDetails,
    'idx-close-scan':         idx_closeScan,
    'idx-open-execute':       idx_openExecuteDetails,
    'idx-close-execute':      idx_closeExecute,
    'idx-open-stats':         idx_openStatsDetails,
    'idx-close-stats':        idx_closeStats,
    'idx-open-schedule':      idx_openSchedule,
    'idx-close-schedule':     idx_closeSchedule,
    'idx-confirm-launch':     idx_confirmLaunch,
    'idx-execute-launch':     idx_executeLaunch,
    'idx-close-launch':       idx_closeLaunch
};

/* ============================================================================
   STATE: POLLING STATE
   ----------------------------------------------------------------------------
   Mutable runtime state for the page's live-polling timer, the configured
   refresh interval, and the page-load date used to force a daily reload.
   Prefix: idx
   ============================================================================ */

/* Live-polling interval in seconds; overwritten from GlobalConfig on init. */
var idx_pageRefreshInterval = 5;

/* Handle for the live-polling setInterval, or null when not polling. */
var idx_livePollingTimer = null;

/* The date the page was loaded, used to trigger a reload on date rollover. */
var idx_pageLoadDate = new Date().toDateString();

/* ============================================================================
   STATE: SCHEDULE DRAG STATE
   ----------------------------------------------------------------------------
   Mutable state backing the click-drag selection in the maintenance schedule
   grid: the database currently being edited and the in-progress drag
   selection (active flag, collected cells, target value, and schedule type).
   Prefix: idx
   ============================================================================ */

/* The DatabaseId whose schedule is currently open in the slideout. */
var idx_currentScheduleDatabaseId = null;

/* The database name currently open in the schedule slideout. */
var idx_currentScheduleDatabaseName = null;

/* Whether a schedule-cell drag selection is currently in progress. */
var idx_isDragging = false;

/* The cells collected in the active drag selection. */
var idx_dragSelectedCells = [];

/* The target allowed/blocked value being applied by the active drag. */
var idx_dragTargetValue = null;

/* The schedule type ('standard' or 'holiday') of the active drag. */
var idx_dragScheduleType = null;

/* ============================================================================
   FUNCTIONS: INITIALIZATION
   ----------------------------------------------------------------------------
   The page boot function invoked by the cc-shared.js bootloader after this
   module loads. Registers the page's delegated listeners, performs the
   initial data load, connects engine events, and starts polling.
   Prefix: idx
   ============================================================================ */

/* Page boot entry point invoked by cc-shared.js after the module loads. */
function idx_init() {
    /* Register the delegated click dispatcher for the page's actions. */
    document.body.addEventListener('click', idx_handleClick);

    /* Document-level mouse listeners drive the schedule-grid drag selection.
       Document-level binding is permitted for delegation; the grid itself is
       rendered dynamically, so per-cell binding is avoided. */
    document.addEventListener('mousedown', idx_handleScheduleMouseDown);
    document.addEventListener('mouseover', idx_handleScheduleMouseOver);
    document.addEventListener('mouseup', idx_handleScheduleMouseUp);

    /* Load the configured refresh interval, then do the initial render. */
    idx_loadRefreshInterval().then(function() {
        idx_refreshAll();
        idx_startLivePolling();
    });

    /* Connect engine events via the shared module (also wires engine-card
       clicks at the document level inside cc-shared.js). */
    cc_connectEngineEvents();

    /* Force a reload on date rollover so day-scoped views stay current. */
    idx_startAutoRefresh();

    /* Fallback refresh for event-driven sections until orchestration is
       live and engine events drive them. */
    setInterval(idx_refreshEventSections, 30000);
}

/* ============================================================================
   FUNCTIONS: ACTION DISPATCH
   ----------------------------------------------------------------------------
   The delegated click dispatcher that routes the page's data-action-click
   values to their handler functions via the idx_clickActions table.
   Registered on document.body in idx_init.
   Prefix: idx
   ============================================================================ */

/* Delegated click dispatcher. Resolves the nearest element carrying a
   data-action-click attribute and routes idx- actions to their handlers. */
function idx_handleClick(event) {
    var target = event.target.closest('[data-action-click]');
    if (!target) {
        return;
    }
    var action = target.getAttribute('data-action-click');
    if (!action || action.indexOf('idx-') !== 0) {
        return;
    }
    var handler = idx_clickActions[action];
    if (handler) {
        handler(target, event);
    }
}

/* ============================================================================
   FUNCTIONS: FORMATTING UTILITIES
   ----------------------------------------------------------------------------
   Local display formatters for durations, counts, and timestamps used across
   the page's render functions.
   Prefix: idx
   ============================================================================ */

/* Formats a second count as a compact duration string. */
function idx_formatDuration(seconds) {
    if (seconds === null || seconds === undefined) return '-';
    if (seconds < 60) return Math.round(seconds) + 's';
    if (seconds < 3600) {
        var mins = Math.floor(seconds / 60);
        var secs = Math.round(seconds % 60);
        return mins + 'm ' + secs + 's';
    }
    var hours = Math.floor(seconds / 3600);
    var hmins = Math.floor((seconds % 3600) / 60);
    return hours + 'h ' + hmins + 'm';
}

/* Formats a millisecond count as a compact duration string. */
function idx_formatDurationMs(ms) {
    if (ms === null || ms === undefined) return '-';
    if (ms < 1000) return ms + 'ms';
    return idx_formatDuration(ms / 1000);
}

/* Formats a number with locale thousands separators, or '-' when absent. */
function idx_formatNumber(num) {
    if (num === null || num === undefined) return '-';
    return num.toLocaleString();
}

/* Formats a second count as a relative "time ago" string. */
function idx_formatTimeAgo(seconds) {
    if (seconds === null || seconds === undefined) return '-';
    if (seconds < 60) return 'just now';
    if (seconds < 3600) return Math.floor(seconds / 60) + 'm ago';
    if (seconds < 86400) return Math.floor(seconds / 3600) + 'h ' + Math.floor((seconds % 3600) / 60) + 'm ago';
    return Math.floor(seconds / 86400) + 'd ago';
}

/* Formats a date string as a full locale date-time, or '-' when absent. */
function idx_formatDateTime(dateStr) {
    if (!dateStr) return '-';
    var date = new Date(dateStr);
    return date.toLocaleString();
}

/* Formats a date string compactly: time today, 'Yesterday', Nd ago, or date. */
function idx_formatDateShort(dateStr) {
    if (!dateStr) return '-';
    var date = new Date(dateStr);
    var now = new Date();
    var diffMs = now - date;
    var diffDays = Math.floor(diffMs / (1000 * 60 * 60 * 24));
    if (diffDays === 0) {
        return date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    } else if (diffDays === 1) {
        return 'Yesterday';
    } else if (diffDays < 7) {
        return diffDays + 'd ago';
    }
    return date.toLocaleDateString();
}

/* Formats an hour (0-23) as a compact 12-hour label (e.g. '12a', '3p'). */
function idx_formatHour(h) {
    if (h === 0) return '12a';
    if (h < 12) return h + 'a';
    if (h === 12) return '12p';
    return (h - 12) + 'p';
}

/* Writes the current time into the shared last-update chrome element. */
function idx_updateTimestamp() {
    var el = document.getElementById('cc-last-update');
    if (el) el.textContent = new Date().toLocaleTimeString();
}

/* ============================================================================
   FUNCTIONS: OVERLAY OPEN AND CLOSE
   ----------------------------------------------------------------------------
   Open and close handlers for the six detail slideouts and the launch modal.
   Slideouts follow the static slide-overlay pattern (cc-open on overlay then
   dialog); the launch modal follows the static-modal pattern (cc-hidden
   toggle). Close handlers dismiss on backdrop click and explicit controls.
   Prefix: idx
   ============================================================================ */

/* Opens a slideout by id using the static slide-overlay pattern. */
function idx_openSlideout(slideoutId) {
    var overlay = document.getElementById(slideoutId);
    var dialog = overlay.querySelector('.cc-dialog');
    overlay.classList.add('cc-open');
    requestAnimationFrame(function() {
        dialog.classList.add('cc-open');
    });
}

/* Closes a slideout by id using the static slide-overlay pattern. */
function idx_closeSlideout(slideoutId, target, event) {
    if (event && target.id === slideoutId && event.target !== target) {
        return;
    }
    var overlay = document.getElementById(slideoutId);
    var dialog = overlay.querySelector('.cc-dialog');
    dialog.addEventListener('transitionend', function handler() {
        dialog.removeEventListener('transitionend', handler);
        overlay.classList.remove('cc-open');
    });
    dialog.classList.remove('cc-open');
}

/* Closes the queue details slideout. */
function idx_closeQueue(target, event) {
    idx_closeSlideout('idx-slideout-queue', target, event);
}

/* Closes the sync details slideout. */
function idx_closeSync(target, event) {
    idx_closeSlideout('idx-slideout-sync', target, event);
}

/* Closes the scan details slideout. */
function idx_closeScan(target, event) {
    idx_closeSlideout('idx-slideout-scan', target, event);
}

/* Closes the execute details slideout. */
function idx_closeExecute(target, event) {
    idx_closeSlideout('idx-slideout-execute', target, event);
}

/* Closes the stats details slideout. */
function idx_closeStats(target, event) {
    idx_closeSlideout('idx-slideout-stats', target, event);
}

/* Closes the schedule slideout and clears the active schedule database. */
function idx_closeSchedule(target, event) {
    if (event && target.id === 'idx-slideout-schedule' && event.target !== target) {
        return;
    }
    idx_closeSlideout('idx-slideout-schedule', target, event);
    idx_currentScheduleDatabaseId = null;
    idx_currentScheduleDatabaseName = null;
}

/* ============================================================================
   FUNCTIONS: LIVE ACTIVITY
   ----------------------------------------------------------------------------
   Loads and renders the live-activity widget: either the currently-running
   processes or, when idle, the last completed activity with its status.
   Prefix: idx
   ============================================================================ */

/* Loads and renders the live-activity widget. */
async function idx_loadLiveActivity() {
    try {
        var data = await cc_engineFetch('/api/index/live-activity');
        if (!data) return;

        var container = document.getElementById('idx-live-activity');

        if (data.IsRunning && data.RunningProcesses.length > 0) {
            var runningHtml = '<div class="idx-activity-stack">';
            for (var i = 0; i < data.RunningProcesses.length; i++) {
                var proc = data.RunningProcesses[i];
                runningHtml +=
                    '<div class="idx-activity-widget idx-running">' +
                        '<div class="idx-activity-header">' +
                            '<div class="idx-activity-title">' + cc_escapeHtml(proc.ProcessName) + '</div>' +
                            '<span class="idx-activity-badge idx-running"><span class="cc-spinning-gear">&#9881;</span> Running</span>' +
                        '</div>' +
                        '<div class="idx-activity-stats">' +
                            '<div class="idx-activity-stat">' +
                                '<span>Elapsed:</span>' +
                                '<span class="idx-activity-stat-value">' + idx_formatDuration(proc.ElapsedSeconds) + '</span>' +
                            '</div>' +
                            '<div class="idx-activity-stat">' +
                                '<span>Completed:</span>' +
                                '<span class="idx-activity-stat-value">' + idx_formatNumber(proc.CompletedCount) + ' indexes</span>' +
                            '</div>' +
                        '</div>' +
                    '</div>';
            }
            runningHtml += '</div>';
            container.innerHTML = runningHtml;
        } else if (data.LastActivity) {
            var la = data.LastActivity;
            var badgeState = la.LastStatus === 'SUCCESS' ? 'idx-success' :
                             la.LastStatus === 'FAILED' ? 'idx-failed' :
                             la.LastStatus === 'PARTIAL' ? 'idx-partial' : 'idx-unknown';
            var widgetState = la.LastStatus === 'FAILED' ? ' idx-idle-failed' :
                              la.LastStatus === 'PARTIAL' ? ' idx-idle-partial' : '';
            container.innerHTML =
                '<div class="idx-activity-widget' + widgetState + '">' +
                    '<div class="idx-activity-header">' +
                        '<div class="idx-activity-title">Last Activity</div>' +
                        '<span class="idx-activity-badge ' + badgeState + '">' + cc_escapeHtml(la.LastStatus) + '</span>' +
                    '</div>' +
                    '<div class="idx-activity-stats">' +
                        '<div class="idx-activity-stat">' +
                            '<span class="idx-activity-stat-value">' + cc_escapeHtml(la.ProcessName) + '</span>' +
                            '<span>completed ' + idx_formatTimeAgo(la.SecondsAgo) + '</span>' +
                        '</div>' +
                        '<div class="idx-activity-stat">' +
                            '<span>Duration:</span>' +
                            '<span class="idx-activity-stat-value">' + idx_formatDuration(la.DurationSeconds) + '</span>' +
                        '</div>' +
                    '</div>' +
                '</div>';
        } else {
            container.innerHTML = '<div class="idx-no-active">No activity recorded</div>';
        }
    } catch (error) {
        console.error('Error loading live activity:', error);
    }
}

/* ============================================================================
   FUNCTIONS: PROCESS STATUS
   ----------------------------------------------------------------------------
   Loads and renders the four process-status cards. Each card is a button so
   it can carry a click action that opens the matching detail slideout; the
   admin launch badge is rendered only when the server marks the process
   CanLaunch for the current user.
   Prefix: idx
   ============================================================================ */

/* Loads and renders the process-status cards. */
async function idx_loadProcessStatus() {
    try {
        var processes = await cc_engineFetch('/api/index/process-status');
        if (!processes) return;

        var container = document.getElementById('idx-process-status');

        if (!processes || processes.length === 0) {
            container.innerHTML = '<div class="cc-slide-empty">No process data available</div>';
            return;
        }

        var html = '';
        for (var i = 0; i < processes.length; i++) {
            var proc = processes[i];
            var statusState = proc.LastStatus ? 'idx-' + proc.LastStatus.toLowerCase().replace('_', '-') : '';
            var labels = idx_processMetricLabels[proc.ProcessName] || { processed: 'Processed', added: 'Added', skipped: 'Skipped' };
            var openAction = idx_processDetailActions[proc.ProcessName] || '';

            /* Admin launch badge: rendered only when the server flags the
               process CanLaunch for this user. The launch endpoint enforces
               the real permission check. */
            var badge = '';
            if (proc.CanLaunch) {
                var badgeLabel = idx_badgeLabels[proc.ProcessName] || proc.ProcessName;
                badge =
                    '<button class="idx-admin-launch-badge" data-action-click="idx-confirm-launch" ' +
                    'data-action-idx-process="' + cc_escapeHtml(proc.ProcessName) + '" ' +
                    'title="Launch ' + cc_escapeHtml(badgeLabel) + '">' + cc_escapeHtml(badgeLabel) + '</button>';
            }

            html +=
                '<div class="idx-process-card ' + statusState + '">' +
                    '<button class="idx-process-card-hit" data-action-click="' + openAction + '" ' +
                    'title="View ' + cc_escapeHtml(idx_processDescriptions[proc.ProcessName] || proc.ProcessName) + ' details"></button>' +
                    '<div class="idx-process-header">' +
                        '<span class="idx-process-name">' + cc_escapeHtml(idx_processDescriptions[proc.ProcessName] || proc.ProcessName) + '</span>' +
                        '<span class="idx-process-status ' + statusState + '">' + cc_escapeHtml(proc.LastStatus || 'N/A') + '</span>' +
                    '</div>' +
                    '<div class="idx-process-metrics">' +
                        '<div class="idx-process-metric">' +
                            '<span class="idx-process-metric-label">Last Run</span>' +
                            '<span class="idx-process-metric-value">' + idx_formatDateShort(proc.CompletedDttm) + '</span>' +
                        '</div>' +
                        '<div class="idx-process-metric">' +
                            '<span class="idx-process-metric-label">' + cc_escapeHtml(labels.processed) + '</span>' +
                            '<span class="idx-process-metric-value">' + idx_formatNumber(proc.ItemsProcessed) + '</span>' +
                        '</div>' +
                        '<div class="idx-process-metric">' +
                            '<span class="idx-process-metric-label">Duration</span>' +
                            '<span class="idx-process-metric-value">' + idx_formatDuration(proc.DurationSeconds) + '</span>' +
                        '</div>' +
                    '</div>' +
                    badge +
                '</div>';
        }

        container.innerHTML = html;
        idx_updateTimestamp();
    } catch (error) {
        console.error('Error loading process status:', error);
    }
}

/* ============================================================================
   FUNCTIONS: MANUAL LAUNCH
   ----------------------------------------------------------------------------
   The admin manual-launch flow: a confirmation modal, the launch request, and
   the result display. Visibility of the launch control is server-gated; the
   launch endpoint performs the authoritative permission check.
   Prefix: idx
   ============================================================================ */

/* Opens the launch confirmation modal for the clicked process. */
function idx_confirmLaunch(target) {
    var processName = target.getAttribute('data-action-idx-process');
    var label = idx_launchLabels[processName] || processName;

    document.getElementById('idx-modal-launch-body').innerHTML =
        '<p class="cc-dialog-paragraph">Launch <span class="cc-dialog-strong">' + cc_escapeHtml(label) + '</span>?</p>' +
        '<p class="cc-dialog-paragraph cc-last">This will execute with the -Execute flag.</p>';

    document.getElementById('idx-modal-launch-footer').innerHTML =
        '<button class="cc-dialog-btn-cancel" data-action-click="idx-close-launch">Cancel</button>' +
        '<button class="cc-dialog-btn-primary" data-action-click="idx-execute-launch" ' +
        'data-action-idx-process="' + cc_escapeHtml(processName) + '">Launch</button>';

    document.getElementById('idx-modal-launch').classList.remove('cc-hidden');
}

/* Closes the launch confirmation modal. */
function idx_closeLaunch(target, event) {
    if (event && target.id === 'idx-modal-launch' && event.target !== target) {
        return;
    }
    document.getElementById('idx-modal-launch').classList.add('cc-hidden');
}

/* Sends the launch request for the confirmed process and shows the result. */
async function idx_executeLaunch(target) {
    var processName = target.getAttribute('data-action-idx-process');
    var footer = document.getElementById('idx-modal-launch-footer');
    footer.innerHTML = '<button class="cc-dialog-btn-cancel" disabled>Launching...</button>';
    try {
        var result = await cc_engineFetch('/api/index/launch-process', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ Process: processName })
        });
        if (!result) return;
        if (result.Error) {
            document.getElementById('idx-modal-launch-body').innerHTML =
                '<p class="cc-dialog-paragraph cc-last">' + cc_escapeHtml(result.Error) + '</p>';
        } else {
            document.getElementById('idx-modal-launch-body').innerHTML =
                '<p class="cc-dialog-paragraph cc-last cc-dialog-strong">&#10003; ' + cc_escapeHtml(result.Message) + '</p>';
        }
        footer.innerHTML = '<button class="cc-dialog-btn-cancel" data-action-click="idx-close-launch">Close</button>';
    } catch (err) {
        document.getElementById('idx-modal-launch-body').innerHTML =
            '<p class="cc-dialog-paragraph cc-last">Failed: ' + cc_escapeHtml(err.message) + '</p>';
        footer.innerHTML = '<button class="cc-dialog-btn-cancel" data-action-click="idx-close-launch">Close</button>';
    }
}

/* ============================================================================
   FUNCTIONS: PROCESS DETAIL SLIDEOUTS
   ----------------------------------------------------------------------------
   Open handlers for the four engine-process detail slideouts (sync, scan,
   execute, stats). Each opens its slideout, fetches the last run's detail,
   and renders summary stats plus per-database and per-index tables.
   Prefix: idx
   ============================================================================ */

/* Opens and populates the registry-sync detail slideout. */
async function idx_openSyncDetails() {
    idx_openSlideout('idx-slideout-sync');
    var body = document.getElementById('idx-slideout-sync-body');
    body.innerHTML = '<div class="cc-slide-empty">Loading...</div>';
    try {
        var data = await cc_engineFetch('/api/index/sync-details');
        if (!data) return;

        var html =
            '<div class="cc-slide-section">' +
                '<div class="cc-slide-section-title">Run Summary</div>' +
                '<div class="cc-slide-summary">' +
                    idx_statCard(idx_formatNumber(data.Summary.TotalUpdated), 'Updated') +
                    idx_statCard(idx_formatNumber(data.Summary.TotalAdded), 'New') +
                    idx_statCard(idx_formatNumber(data.Summary.TotalDropped), 'Dropped') +
                '</div>' +
                idx_runMetaLine(data.Summary.StartedDttm, data.Summary.DurationSeconds) +
            '</div>';

        if (data.ByDatabase && data.ByDatabase.length > 0) {
            html += idx_sectionTableOpen('By Database', ['Server', 'Database', 'Updated', 'New', 'Dropped']);
            for (var i = 0; i < data.ByDatabase.length; i++) {
                var db = data.ByDatabase[i];
                html += '<tr class="cc-slide-table-row">' +
                    idx_td(db.ServerName) + idx_td(db.DatabaseName) +
                    idx_td(idx_formatNumber(db.ItemsProcessed)) + idx_td(idx_formatNumber(db.ItemsAdded)) +
                    idx_td(idx_formatNumber(db.ItemsSkipped)) + '</tr>';
            }
            html += '</tbody></table></div>';
        }

        if (data.AddedIndexes && data.AddedIndexes.length > 0) {
            html += idx_sectionTableOpen('Newly Discovered Indexes', ['Database', 'Table', 'Index']);
            for (var j = 0; j < data.AddedIndexes.length; j++) {
                var ai = data.AddedIndexes[j];
                html += '<tr class="cc-slide-table-row">' +
                    idx_td(ai.DatabaseName) + idx_td(ai.TableName) + idx_td(ai.IndexName) + '</tr>';
            }
            html += '</tbody></table></div>';
        }

        if (data.DroppedIndexes && data.DroppedIndexes.length > 0) {
            html += idx_sectionTableOpen('Dropped Indexes Detected', ['Database', 'Table', 'Index']);
            for (var k = 0; k < data.DroppedIndexes.length; k++) {
                var di = data.DroppedIndexes[k];
                html += '<tr class="cc-slide-table-row">' +
                    idx_td(di.DatabaseName) + idx_td(di.TableName) + idx_td(di.IndexName) + '</tr>';
            }
            html += '</tbody></table></div>';
        }

        var hasDetail = (data.ByDatabase && data.ByDatabase.length) ||
                        (data.AddedIndexes && data.AddedIndexes.length) ||
                        (data.DroppedIndexes && data.DroppedIndexes.length);
        if (!hasDetail) {
            html += '<div class="cc-slide-empty">No detailed data available for last run</div>';
        }

        body.innerHTML = html;
    } catch (error) {
        body.innerHTML = '<div class="cc-slide-empty">Error loading sync details: ' + cc_escapeHtml(error.message) + '</div>';
    }
}

/* Opens and populates the fragmentation-scan detail slideout. */
async function idx_openScanDetails() {
    idx_openSlideout('idx-slideout-scan');
    var body = document.getElementById('idx-slideout-scan-body');
    body.innerHTML = '<div class="cc-slide-empty">Loading...</div>';
    try {
        var data = await cc_engineFetch('/api/index/scan-details');
        if (!data) return;

        var html =
            '<div class="cc-slide-section">' +
                '<div class="cc-slide-section-title">Run Summary</div>' +
                '<div class="cc-slide-summary">' +
                    idx_statCard(idx_formatNumber(data.Summary.TotalScanned), 'Scanned') +
                    idx_statCard(idx_formatNumber(data.Summary.TotalQueued), 'Queued') +
                    idx_statCard(idx_formatNumber(data.Summary.TotalRemoved), 'Removed') +
                '</div>' +
                idx_runMetaLine(data.Summary.StartedDttm, data.Summary.DurationSeconds) +
            '</div>';

        if (data.ScannedIndexes && data.ScannedIndexes.length > 0) {
            html += idx_sectionTableOpen('Fragmentation Found (' + data.ScannedIndexes.length + ' indexes)',
                ['Server', 'Database', 'Index', 'Frag%', 'Pages', 'Queued']);
            for (var i = 0; i < data.ScannedIndexes.length; i++) {
                var idxRow = data.ScannedIndexes[i];
                var fragPct = parseFloat(idxRow.FragmentationPct) || 0;
                var queued = idxRow.WasQueued ? '<span class="cc-dialog-strong">&#10004;</span>' : '';
                html += '<tr class="cc-slide-table-row">' +
                    idx_td(idxRow.ServerName) + idx_td(idxRow.DatabaseName) +
                    idx_tdTitle(idxRow.IndexName, idxRow.SchemaName + '.' + idxRow.TableName) +
                    idx_td(fragPct.toFixed(1) + '%') + idx_td(idx_formatNumber(idxRow.PageCount)) +
                    '<td class="cc-slide-table-td cc-align-right">' + queued + '</td>' + '</tr>';
            }
            html += '</tbody></table></div>';
        } else {
            html += '<div class="cc-slide-empty">No indexes were scanned in the last run</div>';
        }

        body.innerHTML = html;
    } catch (error) {
        body.innerHTML = '<div class="cc-slide-empty">Error loading scan details: ' + cc_escapeHtml(error.message) + '</div>';
    }
}

/* Opens and populates the index-maintenance (rebuild) detail slideout. */
async function idx_openExecuteDetails() {
    idx_openSlideout('idx-slideout-execute');
    var body = document.getElementById('idx-slideout-execute-body');
    body.innerHTML = '<div class="cc-slide-empty">Loading...</div>';
    try {
        var data = await cc_engineFetch('/api/index/execute-details');
        if (!data) return;

        var html =
            '<div class="cc-slide-section">' +
                '<div class="cc-slide-section-title">Run Summary</div>' +
                '<div class="cc-slide-summary">' +
                    idx_statCard(idx_formatNumber(data.Summary.TotalRebuilt), 'Rebuilt') +
                    idx_statCard(idx_formatNumber(data.Summary.TotalFailed), 'Failed') +
                    idx_statCard(idx_formatNumber(data.Summary.TotalDeferred), 'Deferred') +
                '</div>' +
                idx_runMetaLine(data.Summary.StartedDttm, data.Summary.DurationSeconds) +
            '</div>';

        if (data.RebuiltIndexes && data.RebuiltIndexes.length > 0) {
            html += idx_sectionTableOpen('Rebuilt Indexes',
                ['Server', 'Database', 'Index', 'Before', 'After', 'Duration']);
            for (var i = 0; i < data.RebuiltIndexes.length; i++) {
                var ri = data.RebuiltIndexes[i];
                var after = ri.FragmentationAfter !== null ? ri.FragmentationAfter.toFixed(1) + '%' : '-';
                html += '<tr class="cc-slide-table-row">' +
                    idx_td(ri.ServerName) + idx_td(ri.DatabaseName) +
                    idx_tdTitle(ri.IndexName, ri.SchemaName + '.' + ri.TableName) +
                    idx_td(ri.FragmentationBefore.toFixed(1) + '%') + idx_td(after) +
                    idx_td(idx_formatDuration(ri.DurationSeconds)) + '</tr>';
            }
            html += '</tbody></table></div>';
        } else {
            html += '<div class="cc-slide-empty">No indexes were rebuilt in the last run</div>';
        }

        body.innerHTML = html;
    } catch (error) {
        body.innerHTML = '<div class="cc-slide-empty">Error loading execute details: ' + cc_escapeHtml(error.message) + '</div>';
    }
}

/* Opens and populates the statistics-update detail slideout. */
async function idx_openStatsDetails() {
    idx_openSlideout('idx-slideout-stats');
    var body = document.getElementById('idx-slideout-stats-body');
    body.innerHTML = '<div class="cc-slide-empty">Loading...</div>';
    try {
        var data = await cc_engineFetch('/api/index/stats-details');
        if (!data) return;

        var evaluated = data.Summary ? data.Summary.TotalEvaluated : 0;
        var started = data.Summary ? data.Summary.StartedDttm : null;
        var dur = data.Summary ? data.Summary.DurationSeconds : 0;

        var html =
            '<div class="cc-slide-section">' +
                '<div class="cc-slide-section-title">Run Summary</div>' +
                '<div class="cc-slide-summary">' +
                    idx_statCard(idx_formatNumber(evaluated || 0), 'Evaluated') +
                    idx_statCard(idx_formatNumber(data.TotalModifications), 'Modifications') +
                    idx_statCard(idx_formatNumber(data.TotalStaleness), 'Staleness') +
                '</div>' +
                idx_runMetaLine(started, dur || 0) +
            '</div>';

        if (data.ByDatabase && data.ByDatabase.length > 0) {
            html += idx_sectionTableOpen('By Database',
                ['Server', 'Database', 'Modifications', 'Staleness', 'Duration']);
            for (var i = 0; i < data.ByDatabase.length; i++) {
                var db = data.ByDatabase[i];
                html += '<tr class="cc-slide-table-row">' +
                    idx_td(db.ServerName) + idx_td(db.DatabaseName) +
                    idx_td(idx_formatNumber(db.ModificationCount)) +
                    idx_td(db.StalenessCount > 0 ? idx_formatNumber(db.StalenessCount) : '-') +
                    idx_td(idx_formatDurationMs(db.DurationMs)) + '</tr>';
            }
            html += '</tbody></table></div>';
        }

        if (data.Failures && data.Failures.length > 0) {
            html += idx_sectionTableOpen('Failures (' + data.Failures.length + ')',
                ['Database', 'Stat Name', 'Error']);
            for (var j = 0; j < data.Failures.length; j++) {
                var fail = data.Failures[j];
                html += '<tr class="cc-slide-table-row">' +
                    idx_td(fail.DatabaseName) + idx_td(fail.StatName || '-') +
                    idx_td(fail.ErrorMessage || '-') + '</tr>';
            }
            html += '</tbody></table></div>';
        }

        if (!(data.ByDatabase && data.ByDatabase.length)) {
            html += '<div class="cc-slide-empty">No detailed data available for last run</div>';
        }

        body.innerHTML = html;
    } catch (error) {
        body.innerHTML = '<div class="cc-slide-empty">Error loading stats details: ' + cc_escapeHtml(error.message) + '</div>';
    }
}

/* Builds a slide-summary stat card with the given value and label. */
function idx_statCard(value, label) {
    return '<div class="cc-slide-stat">' +
        '<div class="cc-slide-stat-value">' + value + '</div>' +
        '<div class="cc-slide-stat-label">' + cc_escapeHtml(label) + '</div>' +
    '</div>';
}

/* Builds the run meta line (start time and duration) for a detail summary. */
function idx_runMetaLine(startedDttm, durationSeconds) {
    return '<div class="cc-slide-section-title">Run: ' + idx_formatDateTime(startedDttm) +
        ' | Duration: ' + idx_formatDuration(durationSeconds) + '</div>';
}

/* Opens a slide section containing a table with the given title and headers. */
function idx_sectionTableOpen(title, headers) {
    var head = '';
    for (var i = 0; i < headers.length; i++) {
        head += '<th class="cc-slide-table-th">' + cc_escapeHtml(headers[i]) + '</th>';
    }
    return '<div class="cc-slide-section">' +
        '<div class="cc-slide-section-title">' + cc_escapeHtml(title) + '</div>' +
        '<table class="cc-slide-table"><thead><tr>' + head + '</tr></thead><tbody>';
}

/* Builds a slide-table data cell. */
function idx_td(value) {
    return '<td class="cc-slide-table-td">' + cc_escapeHtml(value) + '</td>';
}

/* Builds a slide-table data cell with a hover title. */
function idx_tdTitle(value, title) {
    return '<td class="cc-slide-table-td" title="' + cc_escapeHtml(title) + '">' + cc_escapeHtml(value) + '</td>';
}

/* ============================================================================
   FUNCTIONS: ACTIVE EXECUTION
   ----------------------------------------------------------------------------
   Loads and renders real-time rebuild progress cards, one per in-flight
   index rebuild, with a progress bar and step/row/elapsed/ETA stats.
   Prefix: idx
   ============================================================================ */

/* Loads and renders the active-execution rebuild cards. */
async function idx_loadActiveExecution() {
    try {
        var data = await cc_engineFetch('/api/index/active-execution');
        if (!data) return;

        var container = document.getElementById('idx-active-execution');

        if (!data.IsExecuting || !data.ActiveRebuilds || data.ActiveRebuilds.length === 0) {
            container.innerHTML = '<div class="idx-no-active">No index rebuilds currently in progress</div>';
            return;
        }

        container.innerHTML = '';
        for (var i = 0; i < data.ActiveRebuilds.length; i++) {
            var rebuild = data.ActiveRebuilds[i];
            var card = document.createElement('div');
            card.className = 'idx-rebuild-card';
            card.innerHTML =
                '<div class="idx-rebuild-header">' +
                    '<div>' +
                        '<div class="idx-rebuild-index">' + cc_escapeHtml(rebuild.IndexName) + '</div>' +
                        '<div class="idx-rebuild-location">' + cc_escapeHtml(rebuild.ServerName) + ' / ' + cc_escapeHtml(rebuild.DatabaseName) + '</div>' +
                    '</div>' +
                    '<div class="idx-rebuild-percent">' + rebuild.PercentComplete.toFixed(1) + '%</div>' +
                '</div>' +
                '<div class="idx-rebuild-progress-bar">' +
                    '<div class="idx-rebuild-progress-fill"></div>' +
                '</div>' +
                '<div class="idx-rebuild-stats">' +
                    '<div class="idx-rebuild-stat"><span>Step:</span> <span class="idx-rebuild-stat-value">' + cc_escapeHtml(rebuild.CurrentStep) + '</span></div>' +
                    '<div class="idx-rebuild-stat"><span>Rows:</span> <span class="idx-rebuild-stat-value">' + idx_formatNumber(rebuild.RowsProcessed) + ' / ' + idx_formatNumber(rebuild.TotalRows) + '</span></div>' +
                    '<div class="idx-rebuild-stat"><span>Elapsed:</span> <span class="idx-rebuild-stat-value">' + idx_formatDuration(rebuild.ElapsedSeconds) + '</span></div>' +
                    '<div class="idx-rebuild-stat"><span>ETA:</span> <span class="idx-rebuild-stat-value">' + idx_formatDuration(rebuild.EstimatedSecondsLeft) + '</span></div>' +
                '</div>';
            /* Progress width is a runtime-computed value with no class
               equivalent; set it as a style property after insertion. */
            var fill = card.querySelector('.idx-rebuild-progress-fill');
            fill.style.width = rebuild.PercentComplete + '%';
            container.appendChild(card);
        }
    } catch (error) {
        console.error('Error loading active execution:', error);
    }
}

/* ============================================================================
   FUNCTIONS: QUEUE
   ----------------------------------------------------------------------------
   Loads and renders the compact queue summary (clickable to open the full
   queue detail slideout) and the queue detail table inside the slideout.
   Prefix: idx
   ============================================================================ */

/* Loads and renders the compact index-queue summary. */
async function idx_loadQueueSummary() {
    try {
        var summary = await cc_engineFetch('/api/index/queue-summary');
        if (!summary) return;

        var container = document.getElementById('idx-queue-summary');

        if (!summary || summary.length === 0) {
            container.innerHTML = idx_queueEmptyButton();
            return;
        }

        var byStatus = {};
        var total = null;
        for (var i = 0; i < summary.length; i++) {
            var item = summary[i];
            if (item.Status === 'TOTAL') {
                total = item;
            } else {
                byStatus[item.Status] = item;
            }
        }

        if (total && total.ItemCount === 0) {
            container.innerHTML = idx_queueEmptyButton();
            return;
        }

        var pending = byStatus['PENDING'] || { ItemCount: 0 };
        var scheduled = byStatus['SCHEDULED'] || { ItemCount: 0 };
        var deferred = byStatus['DEFERRED'] || { ItemCount: 0 };

        var html = '<button class="idx-clickable" data-action-click="idx-open-queue-details">' +
            '<div class="idx-queue-summary-grid">' +
                '<div class="idx-queue-stat-card">' +
                    '<div class="idx-queue-stat-value idx-pending">' + pending.ItemCount + '</div>' +
                    '<div class="idx-queue-stat-label">Pending</div>' +
                '</div>' +
                '<div class="idx-queue-stat-card">' +
                    '<div class="idx-queue-stat-value idx-scheduled">' + scheduled.ItemCount + '</div>' +
                    '<div class="idx-queue-stat-label">Scheduled</div>' +
                '</div>' +
                '<div class="idx-queue-stat-card">' +
                    '<div class="idx-queue-stat-value idx-deferred">' + deferred.ItemCount + '</div>' +
                    '<div class="idx-queue-stat-label">Deferred</div>' +
                '</div>' +
            '</div>';

        if (total) {
            html += '<div class="idx-queue-totals-line">' +
                '<span class="idx-total-item"><span class="idx-total-label">TOTAL ITEMS:</span> <span class="idx-total-value">' + total.ItemCount + '</span></span>' +
                '<span class="idx-total-item"><span class="idx-total-label">TOTAL PAGES:</span> <span class="idx-total-value">' + idx_formatNumber(total.TotalPages) + '</span></span>' +
                '<span class="idx-total-item"><span class="idx-total-label">EST. RUNTIME:</span> <span class="idx-total-value">' + idx_formatDuration(total.TotalSecondsOnline) + '</span></span>' +
            '</div>';
        }

        html += '</button>';
        container.innerHTML = html;
    } catch (error) {
        console.error('Error loading queue summary:', error);
        document.getElementById('idx-queue-summary').innerHTML = idx_queueEmptyButton();
    }
}

/* Builds the empty-queue clickable button shown when the queue has no items. */
function idx_queueEmptyButton() {
    return '<button class="idx-clickable" data-action-click="idx-open-queue-details">' +
        '<div class="cc-slide-empty">Queue is empty</div></button>';
}

/* Opens and populates the queue detail slideout. */
async function idx_openQueueDetails() {
    idx_openSlideout('idx-slideout-queue');
    var body = document.getElementById('idx-slideout-queue-body');
    body.innerHTML = '<div class="cc-slide-empty">Loading...</div>';
    try {
        var items = await cc_engineFetch('/api/index/queue-details');
        if (!items) return;

        if (!items || items.length === 0) {
            body.innerHTML = '<div class="cc-slide-empty">Queue is empty</div>';
            return;
        }

        var html = '<table class="cc-slide-table"><thead><tr>' +
            '<th class="cc-slide-table-th">Database</th>' +
            '<th class="cc-slide-table-th">Index</th>' +
            '<th class="cc-slide-table-th">Frag%</th>' +
            '<th class="cc-slide-table-th">Pages</th>' +
            '<th class="cc-slide-table-th">Est.</th>' +
            '<th class="cc-slide-table-th">Status</th>' +
            '<th class="cc-slide-table-th">Pri</th>' +
            '</tr></thead><tbody>';

        for (var i = 0; i < items.length; i++) {
            var item = items[i];
            var statusState = 'idx-' + item.Status.toLowerCase().replace('_', '-');
            html += '<tr class="cc-slide-table-row">' +
                idx_tdTitle(item.DatabaseName, item.ServerName) +
                idx_tdTitle(item.IndexName, item.SchemaName + '.' + item.TableName + '.' + item.IndexName) +
                idx_td(item.FragmentationPct.toFixed(1) + '%') +
                idx_td(idx_formatNumber(item.PageCount)) +
                idx_td(idx_formatDuration(item.EstimatedSecondsOnline)) +
                '<td class="cc-slide-table-td"><span class="idx-status-badge ' + statusState + '">' + cc_escapeHtml(item.Status) + '</span></td>' +
                idx_td(item.PriorityScore) + '</tr>';
        }

        html += '</tbody></table>';
        body.innerHTML = html;
    } catch (error) {
        body.innerHTML = '<div class="cc-slide-empty">Error loading queue details: ' + cc_escapeHtml(error.message) + '</div>';
    }
}

/* ============================================================================
   FUNCTIONS: DATABASE OVERVIEW
   ----------------------------------------------------------------------------
   Loads and renders the database overview grouped into index-maintenance and
   statistics-only databases, with per-row health indicators and a schedule
   icon that opens the per-database schedule editor.
   Prefix: idx
   ============================================================================ */

/* Loads and renders the database overview. */
async function idx_loadDatabaseHealth() {
    try {
        var data = await cc_engineFetch('/api/index/database-health');
        if (!data) return;

        var container = document.getElementById('idx-database-health');

        if (!data.Databases || data.Databases.length === 0) {
            container.innerHTML = '<div class="cc-slide-empty">No databases registered</div>';
            return;
        }

        var indexDbs = data.Databases.filter(function(db) { return db.IndexMaintenanceEnabled; });
        var statsDbs = data.Databases.filter(function(db) { return !db.IndexMaintenanceEnabled && db.StatsMaintenanceEnabled; });

        var html = '';

        if (indexDbs.length > 0) {
            html += '<div class="idx-database-group">' +
                '<div class="idx-database-group-header">Index Maintenance</div>' +
                '<table class="cc-slide-table"><thead><tr>' +
                    '<th class="cc-slide-table-th">Server</th>' +
                    '<th class="cc-slide-table-th"></th>' +
                    '<th class="cc-slide-table-th">Database</th>' +
                    '<th class="cc-slide-table-th">Total</th>' +
                    '<th class="cc-slide-table-th">Frag</th>' +
                    '<th class="cc-slide-table-th">Queue</th>' +
                    '<th class="cc-slide-table-th">Last Scan</th>' +
                '</tr></thead><tbody>';
            for (var i = 0; i < indexDbs.length; i++) {
                var db = indexDbs[i];
                var healthState = 'idx-good';
                if (db.InQueue > 0) healthState = 'idx-warning';
                if (db.InQueue > 10) healthState = 'idx-critical';
                html += '<tr class="cc-slide-table-row">' +
                    '<td class="cc-slide-table-td"><span class="idx-health-indicator ' + healthState + '"></span>' + cc_escapeHtml(db.ServerName) + '</td>' +
                    '<td class="cc-slide-table-td idx-schedule-icon-cell">' +
                        '<button class="idx-schedule-icon" data-action-click="idx-open-schedule" ' +
                        'data-action-idx-database-id="' + cc_escapeHtml(db.DatabaseId) + '" ' +
                        'data-action-idx-server="' + cc_escapeHtml(db.ServerName) + '" ' +
                        'data-action-idx-database="' + cc_escapeHtml(db.DatabaseName) + '" ' +
                        'title="View/Edit Schedule">&#128197;</button>' +
                    '</td>' +
                    idx_td(db.DatabaseName) +
                    idx_td(idx_formatNumber(db.TotalIndexes)) +
                    idx_td(db.FragmentedCount) +
                    idx_td(db.InQueue) +
                    idx_td(idx_formatDateShort(db.LastScanDate)) + '</tr>';
            }
            html += '</tbody></table></div>';
        }

        if (statsDbs.length > 0) {
            html += '<div class="idx-database-group">' +
                '<div class="idx-database-group-header">Statistics Only</div>' +
                '<table class="cc-slide-table"><thead><tr>' +
                    '<th class="cc-slide-table-th">Server</th>' +
                    '<th class="cc-slide-table-th">Database</th>' +
                    '<th class="cc-slide-table-th">Total</th>' +
                    '<th class="cc-slide-table-th">Last Scan</th>' +
                '</tr></thead><tbody>';
            for (var j = 0; j < statsDbs.length; j++) {
                var sdb = statsDbs[j];
                html += '<tr class="cc-slide-table-row">' +
                    idx_td(sdb.ServerName) + idx_td(sdb.DatabaseName) +
                    idx_td(idx_formatNumber(sdb.TotalIndexes)) +
                    idx_td(idx_formatDateShort(sdb.LastScanDate)) + '</tr>';
            }
            html += '</tbody></table></div>';
        }

        container.innerHTML = html;
    } catch (error) {
        console.error('Error loading database health:', error);
    }
}

/* ============================================================================
   FUNCTIONS: SCHEDULE EDITOR
   ----------------------------------------------------------------------------
   Opens the per-database maintenance schedule slideout and renders the
   interactive standard and holiday schedule grids of toggleable hour cells.
   Prefix: idx
   ============================================================================ */

/* Opens the schedule slideout for a database and loads its schedule. */
async function idx_openSchedule(target) {
    var databaseId = target.getAttribute('data-action-idx-database-id');
    var serverName = target.getAttribute('data-action-idx-server');
    var databaseName = target.getAttribute('data-action-idx-database');

    idx_currentScheduleDatabaseId = databaseId;
    idx_currentScheduleDatabaseName = databaseName;

    document.getElementById('idx-slideout-schedule-title').textContent =
        'Maintenance Schedule: ' + serverName + ' / ' + databaseName;

    idx_openSlideout('idx-slideout-schedule');
    var body = document.getElementById('idx-slideout-schedule-body');
    body.innerHTML = '<div class="cc-slide-empty">Loading schedule...</div>';

    try {
        var data = await cc_engineFetch('/api/index/schedule/' + databaseId);
        if (!data) return;
        idx_renderScheduleGrid(data.Schedule, data.HolidaySchedule);
    } catch (error) {
        body.innerHTML = '<div class="cc-slide-empty">Error loading schedule: ' + cc_escapeHtml(error.message) + '</div>';
    }
}

/* Renders the standard and holiday schedule grids into the slideout body. */
function idx_renderScheduleGrid(schedule, holidaySchedule) {
    var body = document.getElementById('idx-slideout-schedule-body');
    var h;

    var html = '<div class="idx-schedule-container">' +
        '<div class="idx-schedule-legend">' +
            '<div class="idx-schedule-legend-item"><div class="idx-schedule-legend-box idx-allowed"></div><span>Maintenance Allowed</span></div>' +
            '<div class="idx-schedule-legend-item"><div class="idx-schedule-legend-box idx-blocked"></div><span>Blocked</span></div>' +
            '<div class="idx-schedule-legend-item idx-schedule-drag-hint"><span>&#128161; Click or drag to select multiple cells</span></div>' +
        '</div>' +
        '<div class="idx-schedule-section-header">Standard Schedule</div>' +
        '<div class="idx-schedule-grid" data-idx-schedule-type="standard">';

    html += '<div class="idx-schedule-hour-labels"><div class="idx-schedule-day-label"></div>';
    for (h = 0; h < 24; h++) {
        html += '<div class="idx-schedule-hour-label">' + idx_formatHour(h) + '</div>';
    }
    html += '</div>';

    for (var d = 0; d < cc_DAY_ORDER.length; d++) {
        var day = cc_DAY_ORDER[d];
        var daySchedule = null;
        for (var s = 0; s < schedule.length; s++) {
            if (schedule[s].DayOfWeek === day) { daySchedule = schedule[s]; break; }
        }
        if (!daySchedule) daySchedule = {};

        html += '<div class="idx-schedule-row">' +
            '<div class="idx-schedule-day-label">' + cc_DAY_NAMES[day] + '</div>' +
            '<div class="idx-schedule-hours">';
        for (var hour = 0; hour < 24; hour++) {
            var hourKey = 'Hr' + (hour < 10 ? '0' + hour : hour);
            var isAllowed = daySchedule[hourKey] === true;
            var cellState = isAllowed ? 'idx-allowed' : 'idx-blocked';
            html += '<div class="idx-schedule-cell ' + cellState + '" ' +
                'data-idx-day="' + day + '" data-idx-hour="' + hour + '" data-idx-schedule-type="standard" ' +
                'title="' + cc_DAY_NAMES[day] + ' ' + idx_formatHour(hour) + ' - ' + (isAllowed ? 'Allowed' : 'Blocked') + '"></div>';
        }
        html += '</div></div>';
    }
    html += '</div>';

    if (holidaySchedule) {
        html += '<div class="idx-schedule-section-header">Holiday Schedule</div>' +
            '<div class="idx-schedule-grid" data-idx-schedule-type="holiday">';
        html += '<div class="idx-schedule-hour-labels"><div class="idx-schedule-day-label"></div>';
        for (h = 0; h < 24; h++) {
            html += '<div class="idx-schedule-hour-label">' + idx_formatHour(h) + '</div>';
        }
        html += '</div>';
        html += '<div class="idx-schedule-row"><div class="idx-schedule-day-label">Holiday</div><div class="idx-schedule-hours">';
        for (var hh = 0; hh < 24; hh++) {
            var hKey = 'Hr' + (hh < 10 ? '0' + hh : hh);
            var hAllowed = holidaySchedule[hKey] === true;
            var hState = hAllowed ? 'idx-allowed' : 'idx-blocked';
            html += '<div class="idx-schedule-cell ' + hState + '" ' +
                'data-idx-hour="' + hh + '" data-idx-schedule-type="holiday" ' +
                'title="Holiday ' + idx_formatHour(hh) + ' - ' + (hAllowed ? 'Allowed' : 'Blocked') + '"></div>';
        }
        html += '</div></div></div>';
    } else {
        html += '<div class="idx-schedule-no-holiday">No holiday schedule configured for this database.</div>';
    }

    html += '</div>';
    body.innerHTML = html;
}

/* ============================================================================
   FUNCTIONS: SCHEDULE DRAG SELECTION
   ----------------------------------------------------------------------------
   Document-delegated click-drag selection for schedule cells. mousedown
   starts a selection and flips the target value, mouseover extends it, and
   mouseup commits the batch via the schedule update API. Mouse events are
   not in the recognized action-attribute set, so they are handled by
   document-level delegated listeners bound once in idx_init.
   Prefix: idx
   ============================================================================ */

/* Begins a drag selection when a schedule cell receives mousedown. */
function idx_handleScheduleMouseDown(event) {
    var cell = event.target.closest('.idx-schedule-cell');
    if (!cell) return;
    event.preventDefault();
    if (!idx_currentScheduleDatabaseId) return;

    var day = cell.getAttribute('data-idx-day');
    var hour = cell.getAttribute('data-idx-hour');
    var scheduleType = cell.getAttribute('data-idx-schedule-type');

    idx_isDragging = true;
    idx_dragScheduleType = scheduleType;
    idx_dragSelectedCells = [{ cell: cell, day: day, hour: hour }];

    var wasAllowed = cell.classList.contains('idx-allowed');
    idx_dragTargetValue = !wasAllowed;

    cell.classList.add('idx-drag-selected');
}

/* Extends the active drag selection as the pointer moves over cells. */
function idx_handleScheduleMouseOver(event) {
    if (!idx_isDragging) return;
    var cell = event.target.closest('.idx-schedule-cell');
    if (!cell) return;

    var scheduleType = cell.getAttribute('data-idx-schedule-type');
    if (scheduleType !== idx_dragScheduleType) return;

    var day = cell.getAttribute('data-idx-day');
    var hour = cell.getAttribute('data-idx-hour');

    var alreadySelected = idx_dragSelectedCells.some(function(c) {
        return c.day === day && c.hour === hour;
    });
    if (!alreadySelected) {
        idx_dragSelectedCells.push({ cell: cell, day: day, hour: hour });
        cell.classList.add('idx-drag-selected');
    }
}

/* Commits the active drag selection on mouseup anywhere in the document. */
function idx_handleScheduleMouseUp() {
    if (!idx_isDragging) return;
    idx_applyDragSelection();
}

/* Applies the collected drag selection by posting a batch schedule update. */
async function idx_applyDragSelection() {
    if (!idx_isDragging || idx_dragSelectedCells.length === 0) {
        idx_resetDragState();
        return;
    }

    var cellsToUpdate = idx_dragSelectedCells.slice();
    var targetValue = idx_dragTargetValue;
    var scheduleType = idx_dragScheduleType;

    idx_resetDragState();

    cellsToUpdate.forEach(function(entry) {
        entry.cell.classList.add('idx-saving');
        entry.cell.classList.remove('idx-drag-selected');
    });

    try {
        var apiUrl;
        var requestBody;
        if (scheduleType === 'holiday') {
            apiUrl = '/api/index/schedule/holiday/update-batch';
            requestBody = {
                DatabaseId: idx_currentScheduleDatabaseId,
                Updates: cellsToUpdate.map(function(entry) {
                    return { Hour: parseInt(entry.hour, 10), Allowed: targetValue };
                })
            };
        } else {
            apiUrl = '/api/index/schedule/update-batch';
            requestBody = {
                DatabaseId: idx_currentScheduleDatabaseId,
                Updates: cellsToUpdate.map(function(entry) {
                    return { DayOfWeek: parseInt(entry.day, 10), Hour: parseInt(entry.hour, 10), Allowed: targetValue };
                })
            };
        }

        await cc_engineFetch(apiUrl, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(requestBody)
        });

        cellsToUpdate.forEach(function(entry) {
            entry.cell.classList.remove('idx-saving');
            entry.cell.classList.toggle('idx-allowed', targetValue);
            entry.cell.classList.toggle('idx-blocked', !targetValue);
            var dayLabel = scheduleType === 'holiday' ? 'Holiday' : cc_DAY_NAMES[parseInt(entry.day, 10)];
            entry.cell.title = dayLabel + ' ' + idx_formatHour(parseInt(entry.hour, 10)) + ' - ' + (targetValue ? 'Allowed' : 'Blocked');
        });
    } catch (error) {
        console.error('Error updating schedule:', error);
        cellsToUpdate.forEach(function(entry) {
            entry.cell.classList.remove('idx-saving');
            entry.cell.classList.toggle('idx-allowed', !targetValue);
            entry.cell.classList.toggle('idx-blocked', targetValue);
            var dayLabel = scheduleType === 'holiday' ? 'Holiday' : cc_DAY_NAMES[parseInt(entry.day, 10)];
            entry.cell.title = dayLabel + ' ' + idx_formatHour(parseInt(entry.hour, 10)) + ' - ' + (!targetValue ? 'Allowed' : 'Blocked');
        });
        cc_showAlert('Failed to update schedule. Please try again.', { title: 'Schedule Update Failed' });
    }
}

/* Resets the schedule drag state and clears any lingering selection styling. */
function idx_resetDragState() {
    idx_isDragging = false;
    idx_dragTargetValue = null;
    idx_dragScheduleType = null;
    idx_dragSelectedCells.forEach(function(entry) {
        entry.cell.classList.remove('idx-drag-selected');
    });
    idx_dragSelectedCells = [];
}

/* ============================================================================
   FUNCTIONS: REFRESH AND POLLING
   ----------------------------------------------------------------------------
   The page's live-polling loop, the daily auto-reload, and the grouped
   refresh functions for live, event-driven, and full-page refreshes. The
   shared fetch wrapper handles hidden-tab and session-expiry skipping.
   Prefix: idx
   ============================================================================ */

/* Loads the configured page refresh interval from GlobalConfig. */
async function idx_loadRefreshInterval() {
    try {
        var data = await cc_engineFetch('/api/config/refresh-interval?page=indexmaintenance');
        if (data) {
            idx_pageRefreshInterval = data.interval || 5;
        }
    } catch (e) {
        /* API unavailable - use default. */
    }
}

/* Starts the live-polling timer for the live sections. */
function idx_startLivePolling() {
    if (idx_livePollingTimer) clearInterval(idx_livePollingTimer);
    idx_livePollingTimer = setInterval(idx_refreshLiveSections, idx_pageRefreshInterval * 1000);
}

/* Stops the live-polling timer. */
function idx_stopLivePolling() {
    if (idx_livePollingTimer) {
        clearInterval(idx_livePollingTimer);
        idx_livePollingTimer = null;
    }
}

/* Reloads the page when the calendar date rolls over from the load date. */
function idx_startAutoRefresh() {
    setInterval(function() {
        var today = new Date().toDateString();
        if (today !== idx_pageLoadDate) {
            window.location.reload();
        }
    }, 60000);
}

/* Refreshes the live sections (live activity and active execution). */
function idx_refreshLiveSections() {
    idx_loadLiveActivity();
    idx_loadActiveExecution();
    idx_updateTimestamp();
}

/* Refreshes the event-driven sections (process status, queue, databases). */
function idx_refreshEventSections() {
    idx_loadProcessStatus();
    idx_loadQueueSummary();
    idx_loadDatabaseHealth();
    idx_updateTimestamp();
}

/* Refreshes every section on the page. */
function idx_refreshAll() {
    idx_loadLiveActivity();
    idx_loadProcessStatus();
    idx_loadActiveExecution();
    idx_loadQueueSummary();
    idx_loadDatabaseHealth();
    idx_updateTimestamp();
}

/* ============================================================================
   FUNCTIONS: PAGE LIFECYCLE HOOKS
   ----------------------------------------------------------------------------
   Lifecycle callbacks invoked by cc-shared.js: full refresh on manual page
   refresh and on tab resume, polling stop on session expiry, and an
   event-driven refresh when a tracked engine process completes.
   Prefix: idx
   ============================================================================ */

/* Invoked by cc-shared.js when the user clicks the page refresh button. */
function idx_onPageRefresh() {
    idx_refreshAll();
}

/* Invoked by cc-shared.js when the tab regains visibility. */
function idx_onPageResumed() {
    idx_refreshAll();
}

/* Invoked by cc-shared.js when the session is detected as expired. */
function idx_onSessionExpired() {
    idx_stopLivePolling();
}

/* Invoked by cc-shared.js when a tracked engine process completes. */
function idx_onEngineProcessCompleted() {
    idx_refreshEventSections();
}

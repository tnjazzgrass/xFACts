/* ============================================================================
   xFACts Control Center - Backup Monitoring (backup.js)
   Location: E:\xFACts-ControlCenter\public\js\backup.js
   Version: Tracked in dbo.System_Metadata (component: ServerOps.Backup)

   Page-specific JS for the Backup Monitoring dashboard. Universal chrome
   (WebSocket events, connection banner, page refresh button, idle
   detection, session expiry, shared modals, formatting utilities) is
   provided by cc-shared.js. This file contains the data loading and
   rendering logic for the pipeline status cards, the network/AWS queue
   cards, the retention cards with their drill-down slideouts, the
   active backup/copy/upload tables, the storage gauges, and the
   pipeline and queue detail modals.

   FILE ORGANIZATION
   -----------------
   CONSTANTS: ENGINE PROCESSES
   CONSTANTS: PAGE CONFIGURATION
   CONSTANTS: DISPATCH TABLES
   STATE: PAGE STATE
   FUNCTIONS: INITIALIZATION
   FUNCTIONS: LIVE POLLING
   FUNCTIONS: API CALLS
   FUNCTIONS: PIPELINE STATUS
   FUNCTIONS: QUEUE STATUS
   FUNCTIONS: RETENTION
   FUNCTIONS: ACTIVE OPERATIONS
   FUNCTIONS: STORAGE
   FUNCTIONS: DETAIL MODAL
   FUNCTIONS: ACTION HANDLERS
   FUNCTIONS: FORMATTERS
   FUNCTIONS: PAGE LIFECYCLE HOOKS
   ============================================================================ */

/* ============================================================================
   CONSTANTS: ENGINE PROCESSES
   ----------------------------------------------------------------------------
   Name contract with cc-shared.js. Maps process names registered in
   Orchestrator.ProcessRegistry to their engine card slugs. The
   identifier is bkp_ENGINE_PROCESSES so cc-shared.js can resolve it via
   window[cc_pagePrefix + '_ENGINE_PROCESSES'] using the data-cc-prefix
   value declared on <body>.
   Prefix: bkp
   ============================================================================ */

/* Maps orchestrator process names to engine card slugs. cc-shared.js
   reads this from a separate script at startup via
   window[cc_pagePrefix + '_ENGINE_PROCESSES']. Top-level const and let
   declarations in classic scripts do NOT add to window -- only var
   declarations and function declarations do -- so this MUST use var,
   not const, even though the value is never reassigned. Card refreshes
   for the bound process happen automatically via
   bkp_onEngineProcessCompleted. */
var bkp_ENGINE_PROCESSES = {
    'Collect-BackupStatus':      { slug: 'collection' },
    'Process-BackupNetworkCopy': { slug: 'networkcopy' },
    'Process-BackupAWSUpload':   { slug: 'awsupload' },
    'Process-BackupRetention':   { slug: 'retention' }
};

/* ============================================================================
   CONSTANTS: PAGE CONFIGURATION
   ----------------------------------------------------------------------------
   Static configuration values for the backup page. The refresh interval
   default is overwritten at load time from GlobalConfig.
   Prefix: bkp
   ============================================================================ */

/* Default live-polling interval in seconds. Overwritten at page boot by
   bkp_loadRefreshInterval from GlobalConfig (ControlCenter |
   refresh_backup_seconds). 5 seconds keeps the active-operations table
   responsive to in-progress backups starting and stopping. */
const bkp_PAGE_REFRESH_INTERVAL_DEFAULT = 5;

/* ============================================================================
   CONSTANTS: DISPATCH TABLES
   ----------------------------------------------------------------------------
   Per-event dispatch tables consumed by the delegated event listeners
   registered in bkp_init. Each table maps page-local data-action-<event>
   values to handler functions. Shared cc-* actions are handled by
   cc-shared.js and never appear here.
   Prefix: bkp
   ============================================================================ */

/* Page-local click action dispatch table. */
const bkp_clickActions = {
    'bkp-open-pipeline-detail':   bkp_openPipelineDetail,
    'bkp-open-queue-detail':      bkp_openQueueDetail,
    'bkp-open-retention-detail':  bkp_openRetentionDetail,
    'bkp-modal-close':            bkp_closeDetailModal,
    'bkp-modal-close-on-overlay': bkp_closeDetailModalOnOverlay,
    'bkp-slideout-close':         bkp_closeRetentionSlideout,
    'bkp-toggle-accordion':       bkp_toggleAccordion
};

/* ============================================================================
   STATE: PAGE STATE
   ----------------------------------------------------------------------------
   Module-scope mutable state for the Backup Monitoring UI: the live-poll
   and auto-refresh timer handles, the cached scheduled retention time,
   the cached pending-retention totals that back the retention cards, the
   cached queue data that backs the queue cards, and the page-load date
   for midnight rollover detection.
   Prefix: bkp
   ============================================================================ */

/* Effective live-polling interval in seconds. Starts at the default and
   is overwritten by bkp_loadRefreshInterval if GlobalConfig has a value. */
var bkp_pageRefreshInterval = bkp_PAGE_REFRESH_INTERVAL_DEFAULT;

/* setInterval handle for the live-polling timer, or null when not running. */
var bkp_livePollingTimer = null;

/* setInterval handle for the midnight-rollover check. */
var bkp_refreshTimer = null;

/* Date string captured at page load. Compared against the current date
   inside the auto-refresh timer to trigger a full reload at midnight. */
var bkp_pageLoadDate = new Date().toDateString();

/* Cached scheduled time for the retention process from the pipeline
   status API. Drives the "Runs ..." note under the retention cards. */
var bkp_retentionScheduledTime = null;

/* Cached pending-retention totals from the storage status API. Drives
   the counts and sizes shown on the local and network retention cards. */
var bkp_pendingRetention = {
    local:   { file_count: 0, total_bytes: 0 },
    network: { file_count: 0, total_bytes: 0 }
};

/* Cached queue data from the queue status API. Backs the network and
   AWS queue cards; rendered by bkp_renderQueueStatus. */
var bkp_queueData = {
    network_copy: { file_count: 0, total_bytes: 0 },
    aws_upload:   { file_count: 0, total_bytes: 0 }
};

/* ============================================================================
   FUNCTIONS: INITIALIZATION
   ----------------------------------------------------------------------------
   The mandatory bkp_init function called by the cc-shared.js bootloader
   after this module loads. Performs one-time page setup, runs the first
   data load, starts the live-polling and midnight-rollover timers,
   connects to the engine event stream, and registers the page's
   delegated click listener.
   Prefix: bkp
   ============================================================================ */

/* Page boot function. Called by the cc-shared.js bootloader after this
   module is loaded. Loads page configuration, performs the initial data
   load, starts background timers, wires the engine subsystem, and
   registers the delegated click listener that routes data-action-click
   values to bkp_clickActions. */
async function bkp_init() {
    await bkp_loadRefreshInterval();
    await bkp_loadAllData();
    await bkp_loadActiveOperations();
    bkp_startAutoRefresh();
    cc_connectEngineEvents();
    bkp_startLivePolling();

    document.body.addEventListener('click', bkp_handleClickAction);
}

/* ============================================================================
   FUNCTIONS: LIVE POLLING
   ----------------------------------------------------------------------------
   The page's refresh loop. Live polling reloads the active-operations
   section at the configured interval; the auto-refresh timer reloads
   the entire page at midnight. The refresh-all path is invoked by the
   page lifecycle hooks; the live-polling path runs independently for
   the in-progress sections.
   Prefix: bkp
   ============================================================================ */

/* Loads the page-specific refresh interval from GlobalConfig via the
   shared refresh-interval API. Falls back to the default constant if
   the API is unavailable. */
async function bkp_loadRefreshInterval() {
    try {
        var data = await cc_engineFetch('/api/config/refresh-interval?page=backup');
        if (data) {
            bkp_pageRefreshInterval = data.interval || bkp_PAGE_REFRESH_INTERVAL_DEFAULT;
        }
    } catch (e) {
        /* API unavailable - default already in effect. */
    }
}

/* Loads all event-driven sections in parallel and updates the page
   timestamp. Called by the page boot function and by bkp_refreshAll. */
async function bkp_loadAllData() {
    await Promise.all([
        bkp_loadPipelineStatus(),
        bkp_loadQueueStatus(),
        bkp_loadStorageStatus()
    ]);
    bkp_updateTimestamp();
}

/* Starts the midnight-rollover check. Lightweight 60-second timer that
   reloads the page when the date changes. All operational data refresh
   is event-driven via bkp_onEngineProcessCompleted. */
function bkp_startAutoRefresh() {
    bkp_refreshTimer = setInterval(function() {
        var today = new Date().toDateString();
        if (today !== bkp_pageLoadDate) {
            window.location.reload();
        }
    }, 60000);
}

/* Starts the live-polling timer for the active-operations section.
   Skips polling when the tab is hidden or the session is expired so we
   do not burn fetches that cc_engineFetch would short-circuit anyway. */
function bkp_startLivePolling() {
    if (bkp_livePollingTimer) clearInterval(bkp_livePollingTimer);
    bkp_livePollingTimer = setInterval(function() {
        if (cc_enginePageHidden || cc_engineSessionExpired) return;
        bkp_refreshLiveSections();
    }, bkp_pageRefreshInterval * 1000);
}

/* Stops live polling. Called by the bkp_onSessionExpired hook when
   cc-shared.js detects the session has expired so we do not keep firing
   fetches that will be short-circuited. */
function bkp_stopLivePolling() {
    if (bkp_livePollingTimer) {
        clearInterval(bkp_livePollingTimer);
        bkp_livePollingTimer = null;
    }
}

/* Refreshes the live-polling section (active operations) and updates
   the page timestamp. Called by the live-polling timer. */
function bkp_refreshLiveSections() {
    bkp_loadLiveData();
    bkp_updateTimestamp();
}

/* Loads data for the live-polling section. Active Operations is the
   only live section; it shows running backups, network copies, and
   AWS uploads, which start and stop independently of collector cycles. */
async function bkp_loadLiveData() {
    await bkp_loadActiveOperations();
}

/* Refreshes everything on the page. Called by the manual refresh button
   (via the bkp_onPageRefresh hook), by the bkp_onPageResumed hook on tab
   resume, and by bkp_onEngineProcessCompleted when an orchestrator
   process finishes. */
function bkp_refreshAll() {
    bkp_loadAllData();
    bkp_loadActiveOperations();
}

/* ============================================================================
   FUNCTIONS: API CALLS
   ----------------------------------------------------------------------------
   Per-section fetchers for the page's API endpoints. Each fetcher reads
   one endpoint, validates the response, dispatches to the section's
   renderer, and updates page-level state where relevant. Errors are
   logged to the console; the connection banner from cc-shared.js
   handles user-facing connection state.
   Prefix: bkp
   ============================================================================ */

/* Loads the active-operations data and re-renders the table. Updates
   the page timestamp on success. */
function bkp_loadActiveOperations() {
    return cc_engineFetch('/api/backup/active-operations')
        .then(function(data) {
            if (!data) return;
            if (data.error) { console.error('Active operations:', data.error); return; }
            bkp_renderActiveOperations(data);
            bkp_updateTimestamp();
        })
        .catch(function(err) { console.error('Failed to load active operations:', err.message); });
}

/* Loads the pipeline status data and re-renders the pipeline cards.
   Caches the retention scheduled time used by the retention card's
   schedule note, then re-renders retention so the note picks up. */
function bkp_loadPipelineStatus() {
    return cc_engineFetch('/api/backup/pipeline-status')
        .then(function(data) {
            if (!data) return;
            if (data.error) { console.error('Pipeline status:', data.error); return; }
            if (data.retention_scheduled_time) {
                bkp_retentionScheduledTime = data.retention_scheduled_time;
            }
            bkp_renderPipelineStatus(data.processes);
            bkp_renderRetentionStatus();
        })
        .catch(function(err) { console.error('Failed to load pipeline status:', err.message); });
}

/* Loads the storage status data and re-renders the storage gauges.
   Caches pending-retention totals used by the retention cards, then
   re-renders retention so the counts pick up. */
function bkp_loadStorageStatus() {
    return cc_engineFetch('/api/backup/storage-status')
        .then(function(data) {
            if (!data) return;
            if (data.error) { console.error('Storage status:', data.error); return; }
            if (data.pending_retention) {
                bkp_pendingRetention = data.pending_retention;
            }
            bkp_renderStorageStatus(data);
            bkp_renderRetentionStatus();
        })
        .catch(function(err) { console.error('Failed to load storage status:', err.message); });
}

/* Loads the queue status data and re-renders the queue cards. Caches
   the response into bkp_queueData so re-renders without a fresh fetch
   can use it. */
function bkp_loadQueueStatus() {
    return cc_engineFetch('/api/backup/queue-status')
        .then(function(data) {
            if (!data) return;
            if (data.error) { console.error('Queue status:', data.error); return; }
            bkp_queueData = data;
            bkp_renderQueueStatus();
        })
        .catch(function(err) { console.error('Failed to load queue status:', err.message); });
}

/* ============================================================================
   FUNCTIONS: PIPELINE STATUS
   ----------------------------------------------------------------------------
   The pipeline status cards: one card per orchestrator process, showing
   run state, last run time, file/byte counts, and a status badge.
   Clicking a card opens the pipeline detail modal with a file-level
   breakdown of the most recent run. The status class and badge come
   from helpers that translate raw event data into UI state.
   Prefix: bkp
   ============================================================================ */

/* Renders the pipeline status cards. One card per process; each card
   shows run state, last run, file/byte counts, and a status badge.
   Cards declare data-action-click="bkp-open-pipeline-detail" so the
   delegated click listener routes through bkp_clickActions. */
function bkp_renderPipelineStatus(processes) {
    var container = document.getElementById('bkp-pipeline-status');
    var html = '<div class="bkp-pipeline-grid">';

    processes.forEach(function(proc) {
        var statusClass = bkp_getProcessStatusClass(proc);
        var isRunning = proc.started_dttm && !proc.completed_dttm;
        var lastRun = isRunning ? 'Running...' : (proc.completed_dttm ? bkp_formatDateTime(proc.completed_dttm) : 'Never');
        var badge = bkp_getProcessBadge(proc, statusClass);

        var cardClass = 'bkp-pipeline-card bkp-clickable';
        if (statusClass) cardClass += ' ' + statusClass;
        var timeClass = 'bkp-pipeline-time';
        if (statusClass) timeClass += ' ' + statusClass;

        html += '<div class="' + cardClass + '" data-action-click="bkp-open-pipeline-detail" data-process-name="' + cc_escapeHtml(proc.process_name) + '">';
        html += '<div class="bkp-pipeline-card-header">';
        html += '<span class="bkp-pipeline-name">' + bkp_formatProcessName(proc.process_name) + '</span>';
        html += '<span class="bkp-pipeline-status-badge ' + badge.badgeClass + '">' + badge.label + '</span>';
        html += '</div>';
        html += '<div class="bkp-pipeline-card-body">';
        html += '<div class="' + timeClass + '">' + lastRun + '</div>';

        if (proc.last_files_processed !== null && proc.last_files_processed > 0) {
            html += '<div class="bkp-pipeline-detail">' + proc.last_files_processed + ' files';
            if (proc.last_bytes_processed) {
                html += ' (' + bkp_formatBytesShort(proc.last_bytes_processed) + ')';
            }
            html += '</div>';
        }

        html += '</div></div>';
    });

    html += '</div>';
    container.innerHTML = html;
}

/* Returns the status CSS class for a pipeline card. Failed runs are
   critical; running processes have their own class; otherwise the age
   of the last completion drives the warning/critical thresholds, with
   retention having looser thresholds because it runs daily. */
function bkp_getProcessStatusClass(proc) {
    if (proc.last_status === 'FAILED') return 'bkp-status-critical';
    if (proc.started_dttm && !proc.completed_dttm) return 'bkp-status-running';

    var minutes = proc.minutes_since_completion;
    if (minutes === null) return 'bkp-status-unknown';

    if (proc.process_name === 'RETENTION') {
        if (minutes > 48 * 60) return 'bkp-status-critical';
        if (minutes > 25 * 60) return 'bkp-status-warning';
        return '';
    }
    if (minutes > 30) return 'bkp-status-critical';
    if (minutes > 10) return 'bkp-status-warning';
    return '';
}

/* Returns the badge label and class for a pipeline card based on the
   raw process state and the resolved status class. */
function bkp_getProcessBadge(proc, statusClass) {
    if (proc.last_status === 'FAILED') return { label: 'FAILED', badgeClass: 'bkp-failed' };
    if (statusClass === 'bkp-status-running') return { label: 'RUNNING', badgeClass: 'bkp-running' };
    if (statusClass === 'bkp-status-critical') return { label: 'STALE', badgeClass: 'bkp-failed' };
    if (statusClass === 'bkp-status-warning') return { label: 'DELAYED', badgeClass: 'bkp-warning' };
    if (statusClass === 'bkp-status-unknown') return { label: 'UNKNOWN', badgeClass: 'bkp-unknown' };
    return { label: 'SUCCESS', badgeClass: 'bkp-success' };
}

/* Opens the pipeline detail modal for a single process. Loads the
   file-level breakdown of the most recent run and renders it; shows a
   placeholder for COLLECTION (file-level detail not yet available). */
function bkp_openPipelineDetail(target) {
    var processName = target.dataset.processName;
    var titles = {
        'COLLECTION':   'Collection -- Last Run',
        'NETWORK_COPY': 'Network Copy -- Last Run',
        'AWS_UPLOAD':   'AWS Upload -- Last Run',
        'RETENTION':    'Retention -- Last Run'
    };

    bkp_openDetailModal(titles[processName] || processName);
    var body = document.getElementById('bkp-detail-body');
    body.innerHTML = '<div class="bkp-loading">Loading...</div>';

    if (processName === 'COLLECTION') {
        body.innerHTML = '<div class="bkp-detail-empty">File-level detail not yet available for Collection.<br>Summary data is shown on the card.</div>';
        return;
    }

    cc_engineFetch('/api/backup/pipeline-detail?process=' + processName)
        .then(function(data) {
            if (!data) { body.innerHTML = '<div class="bkp-detail-empty">Failed to load data</div>'; return; }
            if (data.error) { body.innerHTML = '<div class="bkp-detail-empty">Error: ' + cc_escapeHtml(data.error) + '</div>'; return; }
            bkp_renderPipelineModal(body, data);
        })
        .catch(function(err) {
            body.innerHTML = '<div class="bkp-detail-empty">Failed to load: ' + cc_escapeHtml(err.message) + '</div>';
        });
}

/* Renders the pipeline detail modal: a summary bar across the top and
   a per-file table below. The summary shows status, run time, file
   count, total bytes, and duration; the table shows per-file status,
   server, database, file name, size, and duration. */
function bkp_renderPipelineModal(container, data) {
    var html = '';

    if (data.summary) {
        var s = data.summary;
        var statusClass = s.last_status === 'SUCCESS' ? 'bkp-summary-status-success'
            : s.last_status === 'PARTIAL' ? 'bkp-summary-status-partial'
            : 'bkp-summary-status-failed';

        html += '<div class="bkp-detail-summary">';
        html += '<span class="bkp-detail-summary-item"><span class="bkp-detail-summary-value ' + statusClass + '">' + (s.last_status || '-') + '</span></span>';
        html += '<span class="bkp-detail-summary-item">Run: <span class="bkp-detail-summary-value">' + (s.started_dttm ? bkp_formatDateTime(s.started_dttm) : '-') + '</span></span>';
        html += '<span class="bkp-detail-summary-item">Files: <span class="bkp-detail-summary-value">' + s.last_files_processed + '</span></span>';
        if (s.last_bytes_processed > 0) {
            html += '<span class="bkp-detail-summary-item">Size: <span class="bkp-detail-summary-value">' + bkp_formatBytesShort(s.last_bytes_processed) + '</span></span>';
        }
        html += '<span class="bkp-detail-summary-item">Duration: <span class="bkp-detail-summary-value">' + bkp_formatDurationMs(s.last_duration_ms) + '</span></span>';
        html += '</div>';

        if (s.last_error_message) {
            html += '<div class="bkp-detail-error-caption">' + cc_escapeHtml(s.last_error_message) + '</div>';
        }
    }

    if (!data.files || data.files.length === 0) {
        html += '<div class="bkp-detail-empty">No file detail recorded for this run</div>';
    } else {
        html += '<table class="bkp-detail-table">';
        html += '<thead><tr>';
        html += '<th class="bkp-detail-table-th">Status</th>';
        html += '<th class="bkp-detail-table-th">Server</th>';
        html += '<th class="bkp-detail-table-th">Database</th>';
        html += '<th class="bkp-detail-table-th">File</th>';
        html += '<th class="bkp-detail-table-th bkp-align-right">Size</th>';
        html += '<th class="bkp-detail-table-th bkp-align-right">Duration</th>';
        html += '</tr></thead><tbody>';
        data.files.forEach(function(f) {
            var statusCss = f.status === 'SUCCESS' ? 'bkp-status-success' : 'bkp-status-failed';
            html += '<tr class="bkp-detail-table-row">';
            html += '<td class="bkp-detail-table-td ' + statusCss + '">' + cc_escapeHtml(f.status) + '</td>';
            html += '<td class="bkp-detail-table-td">' + cc_escapeHtml(f.server_name || '-') + '</td>';
            html += '<td class="bkp-detail-table-td">' + cc_escapeHtml(f.database_name || '-') + '</td>';
            html += '<td class="bkp-detail-table-td">' + cc_escapeHtml(f.file_name || '-') + '</td>';
            html += '<td class="bkp-detail-table-td bkp-align-right">' + (f.bytes_processed > 0 ? bkp_formatBytesShort(f.bytes_processed) : '-') + '</td>';
            html += '<td class="bkp-detail-table-td bkp-align-right">' + bkp_formatDurationMs(f.duration_ms) + '</td>';
            html += '</tr>';
            if (f.error_message) {
                html += '<tr><td colspan="6" class="bkp-detail-error-caption">' + cc_escapeHtml(f.error_message) + '</td></tr>';
            }
        });
        html += '</tbody></table>';
    }

    container.innerHTML = html;
}

/* ============================================================================
   FUNCTIONS: QUEUE STATUS
   ----------------------------------------------------------------------------
   The network and AWS queue cards: each shows a pending file count and
   total size. When the queue has files, the card is clickable and opens
   the queue detail modal showing every pending file with backup
   metadata.
   Prefix: bkp
   ============================================================================ */

/* Renders the network and AWS queue cards. Each card shows the pending
   file count and total size; cards with content are clickable and
   declare data-action-click="bkp-open-queue-detail". */
function bkp_renderQueueStatus() {
    var container = document.getElementById('bkp-queue-status');
    var html = '<div class="bkp-card-pair">';

    html += bkp_renderQueueCard('network', 'Network', bkp_queueData.network_copy, '&#128193;');
    html += bkp_renderQueueCard('aws',     'AWS',     bkp_queueData.aws_upload,   '&#9729;');

    html += '</div>';
    container.innerHTML = html;
}

/* Builds the HTML for one queue card. Cards without pending files render
   non-clickable with an "Empty" detail caption. */
function bkp_renderQueueCard(type, label, queue, icon) {
    var clickable = queue.file_count > 0;
    var cardClass = 'bkp-status-card' + (clickable ? ' bkp-clickable' : '');
    var dataAttrs = clickable
        ? ' data-action-click="bkp-open-queue-detail" data-queue-type="' + type + '"'
        : '';
    var detail = queue.total_bytes > 0 ? bkp_formatBytesShort(queue.total_bytes) : 'Empty';

    var html = '<div class="' + cardClass + '"' + dataAttrs + '>';
    html += '<div class="bkp-card-content">';
    html += '<div class="bkp-card-label">' + label + '</div>';
    html += '<div class="bkp-card-value">' + queue.file_count + '</div>';
    html += '<div class="bkp-card-detail">' + detail + '</div>';
    html += '</div>';
    html += '<div class="bkp-card-icon">' + icon + '</div>';
    html += '</div>';
    return html;
}

/* Opens the queue detail modal for a queue type ('network' or 'aws').
   Loads the per-file breakdown and renders it. */
function bkp_openQueueDetail(target) {
    var type = target.dataset.queueType;
    var titles = { 'network': 'Network Copy Queue', 'aws': 'AWS Upload Queue' };
    bkp_openDetailModal(titles[type] || type);
    var body = document.getElementById('bkp-detail-body');
    body.innerHTML = '<div class="bkp-loading">Loading...</div>';

    cc_engineFetch('/api/backup/queue-detail?type=' + type)
        .then(function(data) {
            if (!data) { body.innerHTML = '<div class="bkp-detail-empty">Failed to load data</div>'; return; }
            if (data.error) { body.innerHTML = '<div class="bkp-detail-empty">Error: ' + cc_escapeHtml(data.error) + '</div>'; return; }
            bkp_renderQueueModal(body, data);
        })
        .catch(function(err) {
            body.innerHTML = '<div class="bkp-detail-empty">Failed to load: ' + cc_escapeHtml(err.message) + '</div>';
        });
}

/* Renders the queue detail modal: a summary bar with totals plus a
   per-file table showing backup type, server, database, file name,
   backup date, and size. */
function bkp_renderQueueModal(container, data) {
    if (!data.files || data.files.length === 0) {
        container.innerHTML = '<div class="bkp-detail-empty">Queue is empty</div>';
        return;
    }

    var html = '';
    html += '<div class="bkp-detail-summary">';
    html += '<span class="bkp-detail-summary-item">Pending: <span class="bkp-detail-summary-value">' + data.total_count + ' files</span></span>';
    html += '<span class="bkp-detail-summary-item">Total: <span class="bkp-detail-summary-value">' + bkp_formatBytesShort(data.total_bytes) + '</span></span>';
    html += '</div>';

    html += '<table class="bkp-detail-table">';
    html += '<thead><tr>';
    html += '<th class="bkp-detail-table-th">Type</th>';
    html += '<th class="bkp-detail-table-th">Server</th>';
    html += '<th class="bkp-detail-table-th">Database</th>';
    html += '<th class="bkp-detail-table-th">File</th>';
    html += '<th class="bkp-detail-table-th">Backup Date</th>';
    html += '<th class="bkp-detail-table-th bkp-align-right">Size</th>';
    html += '</tr></thead><tbody>';
    data.files.forEach(function(f) {
        html += '<tr class="bkp-detail-table-row">';
        html += '<td class="bkp-detail-table-td"><span class="bkp-backup-type-badge bkp-type-' + f.backup_type.toLowerCase() + '">' + cc_escapeHtml(f.backup_type) + '</span></td>';
        html += '<td class="bkp-detail-table-td">' + cc_escapeHtml(f.server_name) + '</td>';
        html += '<td class="bkp-detail-table-td">' + cc_escapeHtml(f.database_name) + '</td>';
        html += '<td class="bkp-detail-table-td">' + cc_escapeHtml(f.file_name) + '</td>';
        html += '<td class="bkp-detail-table-td">' + bkp_formatDateTime(f.backup_finish_dttm) + '</td>';
        html += '<td class="bkp-detail-table-td bkp-align-right">' + bkp_formatBytesShort(f.file_size_bytes) + '</td>';
        html += '</tr>';
    });
    html += '</tbody></table>';

    container.innerHTML = html;
}

/* ============================================================================
   FUNCTIONS: RETENTION
   ----------------------------------------------------------------------------
   The local and network retention cards plus their drill-down slideouts.
   The cards show counts and sizes of files pending retention pruning;
   clicking a clickable card opens a slideout listing those files grouped
   by server then by database. Each group is collapsible via the
   slideout's accordion behavior.
   Prefix: bkp
   ============================================================================ */

/* Renders the local and network retention cards. Each card shows the
   pending retention file count and total size; cards with content are
   clickable. The schedule note below the cards shows when the retention
   process is next scheduled to run. */
function bkp_renderRetentionStatus() {
    var container = document.getElementById('bkp-retention-status');
    var retentionTime = bkp_retentionScheduledTime
        ? bkp_formatScheduledTime(bkp_retentionScheduledTime)
        : 'Unknown';

    var html = '<div class="bkp-card-pair">';
    html += bkp_renderRetentionCard('local',   'Local',   bkp_pendingRetention.local);
    html += bkp_renderRetentionCard('network', 'Network', bkp_pendingRetention.network);
    html += '</div>';
    html += '<div class="bkp-retention-schedule-note">Runs ' + retentionTime + '</div>';

    container.innerHTML = html;
}

/* Builds the HTML for one retention card. Cards without pending files
   render non-clickable. */
function bkp_renderRetentionCard(type, label, pending) {
    var clickable = pending.file_count > 0;
    var cardClass = 'bkp-status-card' + (clickable ? ' bkp-clickable' : '');
    var dataAttrs = clickable
        ? ' data-action-click="bkp-open-retention-detail" data-bkp-retention-type="' + type + '"'
        : '';

    var html = '<div class="' + cardClass + '"' + dataAttrs + '>';
    html += '<div class="bkp-card-content">';
    html += '<div class="bkp-card-label">' + label + '</div>';
    html += '<div class="bkp-card-value">' + pending.file_count + '</div>';
    html += '<div class="bkp-card-detail">' + bkp_formatBytesShort(pending.total_bytes) + '</div>';
    html += '</div>';
    html += '<div class="bkp-card-icon">&#128465;</div>';
    html += '</div>';
    return html;
}

/* Opens the retention detail slideout for a retention type ('local' or
   'network'). Loads the candidate file list and renders it as a nested
   server / database accordion. The outer overlay ID follows the
   bkp-{type}-retention-overlay pattern from Backup.ps1; the dialog
   inside is found via querySelector (it carries no ID of its own).
   The dialog's cc-open is applied on the next animation frame so the
   slide-in transition animates from the off-screen position (the dialog
   isn't rendered until the overlay's display:none is removed by the
   first add). */
function bkp_openRetentionDetail(target) {
    var type = target.dataset.bkpRetentionType;
    var overlayId = 'bkp-' + type + '-retention-overlay';
    var bodyId    = 'bkp-' + type + '-retention-body';

    var overlay = document.getElementById(overlayId);
    var dialog  = overlay.querySelector('.cc-dialog');
    overlay.classList.add('cc-open');
    requestAnimationFrame(function() {
        dialog.classList.add('cc-open');
    });

    var body = document.getElementById(bodyId);
    body.innerHTML = '<div class="bkp-loading">Loading retention candidates...</div>';

    cc_engineFetch('/api/backup/retention-candidates?type=' + type)
        .then(function(data) {
            if (!data) { body.innerHTML = '<div class="cc-slide-empty">Failed to load data</div>'; return; }
            if (data.error) { body.innerHTML = '<div class="cc-slide-empty">Error: ' + cc_escapeHtml(data.error) + '</div>'; return; }
            bkp_renderRetentionSlideout(body, data, type);
        })
        .catch(function(err) {
            body.innerHTML = '<div class="cc-slide-empty">Failed to load: ' + cc_escapeHtml(err.message) + '</div>';
        });
}

/* Closes the retention slideout for the given type. Reads the type from
   the clicked element's data-bkp-type argument attribute (set on
   both the overlay and the close button in Backup.ps1). The dialog's
   cc-open is removed first to start the slide-out transition; the
   overlay's cc-open is removed when the transition finishes so the
   dimmer stays in place during the slide-out. */
function bkp_closeRetentionSlideout(target) {
    var type = target.dataset.bkpType;
    if (!type) return;
    var overlayId = 'bkp-' + type + '-retention-overlay';
    var overlay = document.getElementById(overlayId);
    var dialog  = overlay.querySelector('.cc-dialog');
    dialog.addEventListener('transitionend', function handler() {
        dialog.removeEventListener('transitionend', handler);
        overlay.classList.remove('cc-open');
    });
    dialog.classList.remove('cc-open');
}

/* Renders the retention slideout body: a summary bar showing total
   files / size / database count, then a server-then-database accordion
   tree where each leaf is a file table grouped by backup type. */
function bkp_renderRetentionSlideout(container, data, type) {
    if (!data.files || data.files.length === 0) {
        container.innerHTML = '<div class="cc-slide-empty">No retention candidates</div>';
        return;
    }

    var html = '';

    html += '<div class="cc-slide-summary">';
    html += '<div class="cc-slide-stat"><div class="cc-slide-stat-value">' + data.total_count + '</div><div class="cc-slide-stat-label">Files</div></div>';
    html += '<div class="cc-slide-stat"><div class="cc-slide-stat-value">' + bkp_formatBytesShort(data.total_bytes) + '</div><div class="cc-slide-stat-label">Total Size</div></div>';

    var dbSet = {};
    data.files.forEach(function(f) { dbSet[f.server_name + '|' + f.database_name] = true; });
    html += '<div class="cc-slide-stat"><div class="cc-slide-stat-value">' + Object.keys(dbSet).length + '</div><div class="cc-slide-stat-label">Databases</div></div>';
    html += '</div>';

    /* Group by server, then by database. */
    var servers = {};
    data.files.forEach(function(f) {
        if (!servers[f.server_name]) {
            servers[f.server_name] = { files: [], bytes: 0, databases: {} };
        }
        servers[f.server_name].files.push(f);
        servers[f.server_name].bytes += f.file_size_bytes;

        if (!servers[f.server_name].databases[f.database_name]) {
            servers[f.server_name].databases[f.database_name] = { files: [], bytes: 0, cutoff_dttm: f.cutoff_dttm, chain_count: f.chain_count };
        }
        servers[f.server_name].databases[f.database_name].files.push(f);
        servers[f.server_name].databases[f.database_name].bytes += f.file_size_bytes;
    });

    var serverNames = Object.keys(servers).sort();
    serverNames.forEach(function(serverName) {
        var server = servers[serverName];
        var serverId = 'bkp-ret-srv-' + type + '-' + serverName.replace(/[^a-zA-Z0-9]/g, '_');

        html += '<div class="cc-slide-accordion-header" data-action-click="bkp-toggle-accordion" data-accordion-id="' + serverId + '" id="' + serverId + '-header">';
        html += '<span class="cc-slide-accordion-label">' + cc_escapeHtml(serverName) + '</span>';
        html += '<span class="cc-slide-accordion-stats">' + server.files.length + ' files &middot; ' + bkp_formatBytesShort(server.bytes) + '</span>';
        html += '<span class="cc-slide-accordion-chevron" id="' + serverId + '-chevron">&#9654;</span>';
        html += '</div>';
        html += '<div class="cc-slide-accordion-body" id="' + serverId + '-body">';

        var dbNames = Object.keys(server.databases).sort();
        dbNames.forEach(function(dbName) {
            var db = server.databases[dbName];
            var dbId = serverId + '-' + dbName.replace(/[^a-zA-Z0-9]/g, '_');

            html += '<div class="cc-slide-accordion-header" data-action-click="bkp-toggle-accordion" data-accordion-id="' + dbId + '" id="' + dbId + '-header">';
            html += '<span class="cc-slide-accordion-label">' + cc_escapeHtml(dbName) + '</span>';
            html += '<span class="cc-slide-accordion-stats">' + db.files.length + ' files &middot; ' + bkp_formatBytesShort(db.bytes) + '</span>';
            html += '<span class="cc-slide-accordion-chevron" id="' + dbId + '-chevron">&#9654;</span>';
            html += '</div>';
            html += '<div class="cc-slide-accordion-body" id="' + dbId + '-body">';

            html += '<div class="cc-slide-accordion-cutoff">Keeping ' + db.chain_count + ' newest FULL chain(s) &mdash; cutoff: ' + bkp_formatDateTime(db.cutoff_dttm) + '</div>';

            html += '<table class="cc-slide-table">';
            html += '<thead><tr>';
            html += '<th class="cc-slide-table-th">Type</th>';
            html += '<th class="cc-slide-table-th">File</th>';
            html += '<th class="cc-slide-table-th">Backup Date</th>';
            html += '<th class="cc-slide-table-th cc-align-right">Size</th>';
            html += '</tr></thead><tbody>';
            db.files.forEach(function(f) {
                html += '<tr class="cc-slide-table-row">';
                html += '<td class="cc-slide-table-td"><span class="bkp-backup-type-badge bkp-type-' + f.backup_type.toLowerCase() + '">' + cc_escapeHtml(f.backup_type) + '</span></td>';
                html += '<td class="cc-slide-table-td">' + cc_escapeHtml(f.file_name) + '</td>';
                html += '<td class="cc-slide-table-td">' + bkp_formatDateTime(f.backup_finish_dttm) + '</td>';
                html += '<td class="cc-slide-table-td cc-align-right">' + bkp_formatBytesShort(f.file_size_bytes) + '</td>';
                html += '</tr>';
            });
            html += '</tbody></table>';
            html += '</div>';
        });

        html += '</div>';
    });

    container.innerHTML = html;
}

/* Toggles the expanded state of an accordion section by its data-accordion-id.
   Adds or removes the 'cc-expanded' class on the body (controls display) and
   the chevron (controls rotation). The header itself carries no .cc-expanded
   state in cc-shared.css; it's the body and chevron that change visually. */
function bkp_toggleAccordion(target) {
    var id = target.dataset.accordionId;
    if (!id) return;
    var body = document.getElementById(id + '-body');
    var chevron = document.getElementById(id + '-chevron');
    if (body) body.classList.toggle('cc-expanded');
    if (chevron) chevron.classList.toggle('cc-expanded');
}

/* ============================================================================
   FUNCTIONS: ACTIVE OPERATIONS
   ----------------------------------------------------------------------------
   The active-operations table: three vertically stacked groups showing
   currently running backups, in-progress network copies, and in-progress
   AWS uploads. Each group renders an empty state when nothing is active.
   This is the only live-polling section on the page.
   Prefix: bkp
   ============================================================================ */

/* Renders the active operations groups: running backups, in-progress
   network copies, and in-progress AWS uploads. Each group either
   renders a table or a "no active ..." empty state. */
function bkp_renderActiveOperations(data) {
    var container = document.getElementById('bkp-active-operations');
    var html = '';

    html += bkp_renderBackupsInProgress(data.backups_in_progress);
    html += bkp_renderNetworkCopiesInProgress(data.network_copies_in_progress);
    html += bkp_renderAwsUploadsInProgress(data.aws_uploads_in_progress);

    container.innerHTML = html;
}

/* Renders the "Backups In Progress" group: backup operations currently
   running on physical SQL servers (BACKUP DATABASE / BACKUP LOG). */
function bkp_renderBackupsInProgress(backups) {
    var html = '<div class="bkp-operation-group">';
    html += '<div class="bkp-operation-group-header"><span class="bkp-op-icon">&#128190;</span> Backups In Progress</div>';

    if (backups && backups.length > 0) {
        html += '<table class="bkp-operation-table">';
        html += '<thead><tr>';
        html += '<th class="bkp-operation-table-th">Server</th>';
        html += '<th class="bkp-operation-table-th">Database</th>';
        html += '<th class="bkp-operation-table-th">Type</th>';
        html += '<th class="bkp-operation-table-th">Progress</th>';
        html += '<th class="bkp-operation-table-th">Elapsed</th>';
        html += '<th class="bkp-operation-table-th">ETA</th>';
        html += '</tr></thead><tbody>';

        backups.forEach(function(backup) {
            var commandType = backup.command.replace('BACKUP ', '').replace('RESTORE ', 'R:');
            html += '<tr class="bkp-operation-table-row">';
            html += '<td class="bkp-operation-table-td">' + cc_escapeHtml(backup.server_name) + '</td>';
            html += '<td class="bkp-operation-table-td">' + cc_escapeHtml(backup.database_name || '-') + '</td>';
            html += '<td class="bkp-operation-table-td">' + cc_escapeHtml(commandType) + '</td>';
            html += '<td class="bkp-operation-table-td">' + bkp_renderProgressBar(backup.percent_complete, false) + '</td>';
            html += '<td class="bkp-operation-table-td">' + bkp_formatMinutes(backup.elapsed_minutes) + '</td>';
            html += '<td class="bkp-operation-table-td">' + bkp_formatMinutes(backup.eta_minutes) + '</td>';
            html += '</tr>';
        });

        html += '</tbody></table>';
    } else {
        html += '<div class="bkp-no-activity">No active backups</div>';
    }
    html += '</div>';
    return html;
}

/* Renders the "Network Copies In Progress" group: file copies in flight
   to the network backup share. Progress is estimated; percentages and
   ETAs carry a tilde to convey that. */
function bkp_renderNetworkCopiesInProgress(copies) {
    var html = '<div class="bkp-operation-group">';
    html += '<div class="bkp-operation-group-header"><span class="bkp-op-icon">&#128193;</span> Network Copies In Progress</div>';

    if (copies && copies.length > 0) {
        html += '<table class="bkp-operation-table">';
        html += '<thead><tr>';
        html += '<th class="bkp-operation-table-th">Server</th>';
        html += '<th class="bkp-operation-table-th">Database</th>';
        html += '<th class="bkp-operation-table-th">File</th>';
        html += '<th class="bkp-operation-table-th">Size</th>';
        html += '<th class="bkp-operation-table-th">Progress</th>';
        html += '<th class="bkp-operation-table-th">Elapsed</th>';
        html += '<th class="bkp-operation-table-th">ETA</th>';
        html += '</tr></thead><tbody>';

        copies.forEach(function(file) {
            html += '<tr class="bkp-operation-table-row">';
            html += '<td class="bkp-operation-table-td">' + cc_escapeHtml(file.server_name) + '</td>';
            html += '<td class="bkp-operation-table-td">' + cc_escapeHtml(file.database_name) + '</td>';
            html += '<td class="bkp-operation-table-td bkp-operation-file-name">' + cc_escapeHtml(file.file_name) + '</td>';
            html += '<td class="bkp-operation-table-td">' + bkp_formatBytes(file.file_size_bytes) + '</td>';
            html += '<td class="bkp-operation-table-td">' + bkp_renderProgressBar(file.percent_complete, true) + '</td>';
            html += '<td class="bkp-operation-table-td">' + bkp_formatMinutes(file.elapsed_minutes) + '</td>';
            html += '<td class="bkp-operation-table-td">' + bkp_formatMinutes(file.eta_minutes) + '~</td>';
            html += '</tr>';
        });

        html += '</tbody></table>';
    } else {
        html += '<div class="bkp-no-activity">No active network copies</div>';
    }
    html += '</div>';
    return html;
}

/* Renders the "AWS Uploads In Progress" group: file uploads in flight to
   the S3 archive. Same shape as network copies; progress is estimated. */
function bkp_renderAwsUploadsInProgress(uploads) {
    var html = '<div class="bkp-operation-group">';
    html += '<div class="bkp-operation-group-header"><span class="bkp-op-icon">&#9729;</span> AWS Uploads In Progress</div>';

    if (uploads && uploads.length > 0) {
        html += '<table class="bkp-operation-table">';
        html += '<thead><tr>';
        html += '<th class="bkp-operation-table-th">Server</th>';
        html += '<th class="bkp-operation-table-th">Database</th>';
        html += '<th class="bkp-operation-table-th">File</th>';
        html += '<th class="bkp-operation-table-th">Size</th>';
        html += '<th class="bkp-operation-table-th">Progress</th>';
        html += '<th class="bkp-operation-table-th">Elapsed</th>';
        html += '<th class="bkp-operation-table-th">ETA</th>';
        html += '</tr></thead><tbody>';

        uploads.forEach(function(file) {
            html += '<tr class="bkp-operation-table-row">';
            html += '<td class="bkp-operation-table-td">' + cc_escapeHtml(file.server_name) + '</td>';
            html += '<td class="bkp-operation-table-td">' + cc_escapeHtml(file.database_name) + '</td>';
            html += '<td class="bkp-operation-table-td bkp-operation-file-name">' + cc_escapeHtml(file.file_name) + '</td>';
            html += '<td class="bkp-operation-table-td">' + bkp_formatBytes(file.file_size_bytes) + '</td>';
            html += '<td class="bkp-operation-table-td">' + bkp_renderProgressBar(file.percent_complete, true) + '</td>';
            html += '<td class="bkp-operation-table-td">' + bkp_formatMinutes(file.elapsed_minutes) + '</td>';
            html += '<td class="bkp-operation-table-td">' + bkp_formatMinutes(file.eta_minutes) + '~</td>';
            html += '</tr>';
        });

        html += '</tbody></table>';
    } else {
        html += '<div class="bkp-no-activity">No active AWS uploads</div>';
    }
    html += '</div>';
    return html;
}

/* Builds the progress bar HTML for one active operation row. The
   estimated flag adds a tilde to the percent label to convey that the
   value is an estimate (network copies and AWS uploads, which lack
   direct progress reporting). */
function bkp_renderProgressBar(percent, estimated) {
    var suffix = estimated ? '%~' : '%';
    var html = '<div class="bkp-progress-bar-container">';
    html += '<div class="bkp-progress-bar" style="width: ' + percent + '%"></div>';
    html += '<span class="bkp-progress-text">' + percent.toFixed(1) + suffix + '</span>';
    html += '</div>';
    return html;
}

/* ============================================================================
   FUNCTIONS: STORAGE
   ----------------------------------------------------------------------------
   The storage section: an 80-segment gauge per local backup drive plus
   a single network storage gauge. Free space below configurable
   thresholds drives the warning and critical color states. The gauge
   builder produces consistent visual output for every drive.
   Prefix: bkp
   ============================================================================ */

/* Renders the storage section: a row per local drive plus the network
   storage row. Each row has a header line with the path / free space
   and an 80-segment gauge underneath. */
function bkp_renderStorageStatus(data) {
    var container = document.getElementById('bkp-storage-status');
    var html = '';

    html += '<div class="bkp-storage-group">';
    html += '<div class="bkp-storage-group-header">Local Backup Drives</div>';

    if (data.local_drives && data.local_drives.length > 0) {
        data.local_drives.forEach(function(drive) {
            html += bkp_renderLocalDriveRow(drive);
        });
    } else {
        html += '<div class="bkp-no-data">No backup drive data</div>';
    }
    html += '</div>';

    html += '<div class="bkp-storage-group">';
    html += '<div class="bkp-storage-group-header">Network Storage</div>';
    html += bkp_renderNetworkStorageRow(data.network_storage);
    html += '</div>';

    container.innerHTML = html;
}

/* Builds the HTML for one local drive row: label, free-space stats,
   and the 80-segment gauge bar. */
function bkp_renderLocalDriveRow(drive) {
    var usedPercent = 100 - drive.percent_free;
    var statusClass = bkp_getStorageStatusClass(drive.percent_free);
    var labelClass = 'bkp-drive-label' + (statusClass ? ' ' + statusClass : '');

    var html = '<div class="bkp-storage-drive">';
    html += '<div class="bkp-drive-header">';
    html += '<span class="' + labelClass + '">' + cc_escapeHtml(drive.server_name) + ' ' + drive.drive_letter + ':</span>';
    html += '<span class="bkp-drive-stats">' + bkp_formatMB(drive.free_space_mb) + ' free (' + drive.percent_free.toFixed(0) + '%)</span>';
    html += '</div>';
    html += bkp_renderSegmentGauge(usedPercent, statusClass, 80);
    html += '</div>';
    return html;
}

/* Builds the HTML for the network storage row, or a configured-off
   placeholder when no network root is set in GlobalConfig. Errors from
   the network probe render as an inline error message in place of the
   gauge. */
function bkp_renderNetworkStorageRow(storage) {
    if (!storage) {
        return '<div class="bkp-no-data">Not configured</div>';
    }

    if (storage.error) {
        var html = '<div class="bkp-storage-drive">';
        html += '<div class="bkp-drive-header">';
        html += '<span class="bkp-drive-label">' + cc_escapeHtml(storage.path) + '</span>';
        html += '</div>';
        html += '<div class="bkp-storage-error">' + cc_escapeHtml(storage.error) + '</div>';
        html += '</div>';
        return html;
    }

    var usedPercent = 100 - storage.percent_free;
    var statusClass = bkp_getStorageStatusClass(storage.percent_free);
    var labelClass = 'bkp-drive-label' + (statusClass ? ' ' + statusClass : '');

    var rowHtml = '<div class="bkp-storage-drive">';
    rowHtml += '<div class="bkp-drive-header">';
    rowHtml += '<span class="' + labelClass + '">' + cc_escapeHtml(storage.path) + '</span>';
    rowHtml += '<span class="bkp-drive-stats">' + bkp_formatMB(storage.free_space_mb) + ' free (' + storage.percent_free.toFixed(0) + '%)</span>';
    rowHtml += '</div>';
    rowHtml += bkp_renderSegmentGauge(usedPercent, statusClass, 80);
    rowHtml += '</div>';
    return rowHtml;
}

/* Returns the storage status modifier class for a drive based on percent
   free space. Below 10% is bkp-critical; below 20% is bkp-warning;
   otherwise an empty string (no modifier class). The returned value
   matches the modifier classes on .bkp-drive-label. */
function bkp_getStorageStatusClass(percentFree) {
    if (percentFree < 10) return 'bkp-critical';
    if (percentFree < 20) return 'bkp-warning';
    return '';
}

/* Builds the 80-segment gauge HTML for a single drive. Segments fill
   left-to-right based on the used percent; the active segment color is
   driven by the storage status class via the active-* modifier. */
function bkp_renderSegmentGauge(percent, statusClass, numSegments) {
    numSegments = numSegments || 80;
    var filledCount = Math.round((percent / 100) * numSegments);
    var activeClass;

    if (statusClass === 'bkp-critical') activeClass = 'bkp-active-critical';
    else if (statusClass === 'bkp-warning') activeClass = 'bkp-active-warning';
    else activeClass = 'bkp-active-healthy';

    var html = '<div class="bkp-segment-bar">';
    for (var i = 0; i < numSegments; i++) {
        html += '<div class="bkp-segment' + (i < filledCount ? ' ' + activeClass : '') + '"></div>';
    }
    return html + '</div>';
}

/* ============================================================================
   FUNCTIONS: DETAIL MODAL
   ----------------------------------------------------------------------------
   The shared pipeline-and-queue detail modal. The modal HTML is
   statically declared in Backup.ps1; these functions toggle the .hidden
   class on the overlay element and set the modal title. Render functions
   (bkp_renderPipelineModal, bkp_renderQueueModal) populate the modal
   body for their respective use cases.
   Prefix: bkp
   ============================================================================ */

/* Opens the detail modal with a given title. Reveals the modal overlay
   by removing the .hidden class. */
function bkp_openDetailModal(title) {
    document.getElementById('bkp-detail-title').textContent = title;
    document.getElementById('bkp-modal-detail-overlay').classList.remove('cc-hidden');
}

/* Closes the detail modal. Hides the modal overlay by adding the
   .hidden class. Wired up from the close button via data-action-click. */
function bkp_closeDetailModal() {
    document.getElementById('bkp-modal-detail-overlay').classList.add('cc-hidden');
}

/* Closes the detail modal only when the overlay itself is clicked (not
   the dialog inside it). Wired up from the overlay via
   data-action-click="bkp-modal-close-on-overlay". */
function bkp_closeDetailModalOnOverlay(target, event) {
    if (event.target === target) {
        bkp_closeDetailModal();
    }
}

/* ============================================================================
   FUNCTIONS: ACTION HANDLERS
   ----------------------------------------------------------------------------
   The page's delegated click dispatcher. Examines event.target for the
   nearest [data-action-click] ancestor, looks up the action value in
   bkp_clickActions, and invokes the handler with (target, event). The
   bootloader's shared listener handles cc-* actions; this listener
   handles every page-local action declared on Backup.ps1's rendered
   markup or on JS-rendered markup.
   Prefix: bkp
   ============================================================================ */

/* Delegated dispatcher for page-local click actions. Looks up the
   action value in bkp_clickActions and invokes the matching handler.
   Actions beginning with cc- are skipped (handled by cc-shared.js); an
   unknown action logs a warning and is ignored. */
function bkp_handleClickAction(event) {
    var target = event.target.closest('[data-action-click]');
    if (!target) return;
    var action = target.getAttribute('data-action-click');
    if (!action || action.indexOf('cc-') === 0) return;
    var handler = bkp_clickActions[action];
    if (!handler) {
        console.warn('[bkp] Unknown page click action: ' + action);
        return;
    }
    handler(target, event);
}

/* ============================================================================
   FUNCTIONS: FORMATTERS
   ----------------------------------------------------------------------------
   Page-local display formatters: timestamp display, scheduled-time
   parsing, byte/MB sizing, duration / minutes rendering, and the
   process-name lookup. The standard cc_escapeHtml from cc-shared.js
   handles HTML attribute and content escaping; these helpers handle the
   per-page display formats not covered by cc-shared.
   Prefix: bkp
   ============================================================================ */

/* Updates the live "last updated" timestamp display in the page
   header. */
function bkp_updateTimestamp() {
    var now = new Date();
    document.getElementById('cc-last-update').textContent = now.toLocaleTimeString();
}

/* Maps an internal process name to its display label. */
function bkp_formatProcessName(name) {
    var names = {
        'COLLECTION':   'Collection',
        'NETWORK_COPY': 'Network Copy',
        'AWS_UPLOAD':   'AWS Upload',
        'RETENTION':    'Retention'
    };
    return names[name] || name;
}

/* Formats a TIME-of-day string ("HH:MM:SS") relative to now. Returns
   "today 2 PM" or "tomorrow 2 PM" depending on whether the run time has
   already passed today. */
function bkp_formatScheduledTime(timeStr) {
    var parts = timeStr.split(':');
    var hour = parseInt(parts[0], 10);
    var now = new Date();
    var runTime = new Date(now);
    runTime.setHours(hour, parseInt(parts[1] || 0, 10), 0, 0);

    var prefix = (now > runTime) ? 'tomorrow ' : 'today ';
    return prefix + bkp_formatHour(hour);
}

/* Formats a 24-hour clock value as a 12-hour display string with AM/PM.
   Returns "12 AM", "12 PM", "3 AM", "3 PM", etc. */
function bkp_formatHour(hour) {
    if (hour === 0) return '12 AM';
    if (hour === 12) return '12 PM';
    if (hour < 12) return hour + ' AM';
    return (hour - 12) + ' PM';
}

/* Formats a byte count as a long-form size string with one decimal
   place: "1.5 GB", "300.0 MB". Returns "0 B" for zero or null. */
function bkp_formatBytes(bytes) {
    if (bytes === 0 || bytes === null) return '0 B';
    var units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var i = 0;
    var size = bytes;
    while (size >= 1024 && i < units.length - 1) {
        size /= 1024;
        i++;
    }
    return size.toFixed(1) + ' ' + units[i];
}

/* Formats a byte count as a short-form size string: "1.5G", "300M".
   Megabytes and below are rendered with no decimal; gigabytes and above
   are rendered with one decimal. */
function bkp_formatBytesShort(bytes) {
    if (bytes === 0 || bytes === null) return '0';
    if (bytes >= 1099511627776) return (bytes / 1099511627776).toFixed(1) + 'T';
    if (bytes >= 1073741824)    return (bytes / 1073741824).toFixed(1) + 'G';
    if (bytes >= 1048576)       return (bytes / 1048576).toFixed(0) + 'M';
    if (bytes >= 1024)          return (bytes / 1024).toFixed(0) + 'K';
    return bytes + 'B';
}

/* Formats a megabyte count as a display size string. Above 1 TB renders
   as "X.X TB"; above 1 GB as "X GB"; otherwise "X MB". */
function bkp_formatMB(mb) {
    if (mb === 0 || mb === null) return '0 MB';
    if (mb >= 1048576) return (mb / 1048576).toFixed(1) + ' TB';
    if (mb >= 1024)    return (mb / 1024).toFixed(0) + ' GB';
    return mb + ' MB';
}

/* Formats a minute count as a duration string: "< 1m", "30m", "2h 15m".
   Returns "-" for null or zero. */
function bkp_formatMinutes(minutes) {
    if (minutes === null || minutes === 0) return '-';
    if (minutes < 1) return '< 1m';
    if (minutes < 60) return Math.round(minutes) + 'm';
    var hours = Math.floor(minutes / 60);
    var mins = Math.round(minutes % 60);
    return hours + 'h ' + mins + 'm';
}

/* Formats a millisecond duration as a short display string. Below 1
   second renders in milliseconds; below 1 minute in seconds with one
   decimal; minutes and above with one decimal. Returns "-" for null or
   zero. */
function bkp_formatDurationMs(ms) {
    if (!ms || ms <= 0) return '-';
    if (ms < 1000) return ms + 'ms';
    var sec = ms / 1000;
    if (sec < 60) return sec.toFixed(1) + 's';
    var min = sec / 60;
    return min.toFixed(1) + 'm';
}

/* Formats an ISO datetime string as a short display: "M/D h:mm AM/PM".
   Returns "-" for null. */
function bkp_formatDateTime(dateTimeStr) {
    if (!dateTimeStr) return '-';
    var d = new Date(dateTimeStr);
    var month = d.getMonth() + 1;
    var day = d.getDate();
    var hours = d.getHours();
    var mins = d.getMinutes();
    var ampm = hours >= 12 ? 'PM' : 'AM';
    hours = hours % 12;
    hours = hours ? hours : 12;
    mins = mins < 10 ? '0' + mins : mins;
    return month + '/' + day + ' ' + hours + ':' + mins + ' ' + ampm;
}

/* ============================================================================
   FUNCTIONS: PAGE LIFECYCLE HOOKS
   ----------------------------------------------------------------------------
   Hooks invoked by cc-shared.js. The shared module resolves these via
   window[cc_pagePrefix + '_<name>'] at runtime, using the data-cc-prefix
   value declared on <body>. Each hook is bkp_-prefixed and exposed at
   the page-local namespace so the shared module's lookup pattern finds
   it.
   Prefix: bkp
   ============================================================================ */

/* Called by cc-shared.js when the user clicks the page refresh button.
   cc-shared.js drives the spin animation; this hook does the actual
   data reload. */
function bkp_onPageRefresh() {
    bkp_refreshAll();
}

/* Called by cc-shared.js when the page becomes visible again after
   being hidden. cc-shared.js drives the spin animation; this hook does
   the actual data reload so the user sees current data. */
function bkp_onPageResumed() {
    bkp_refreshAll();
}

/* Called by cc-shared.js when the session is detected as expired.
   Stops the live-polling timer so we do not keep firing fetches that
   cc_engineFetch will short-circuit. */
function bkp_onSessionExpired() {
    bkp_stopLivePolling();
}

/* Called by cc-shared.js when an orchestrator process listed in
   bkp_ENGINE_PROCESSES completes. Refreshes the event-driven sections
   (pipeline, queue, retention, storage) since fresh data is now
   available. */
function bkp_onEngineProcessCompleted(processName, event) {
    bkp_refreshAll();
}

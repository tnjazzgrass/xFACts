/* ============================================================================
   xFACts Control Center - Backup Monitoring JavaScript (backup.js)
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
   STATE: PAGE STATE
   INITIALIZATION: PAGE BOOT
   FUNCTIONS: LIVE POLLING
   FUNCTIONS: API CALLS
   FUNCTIONS: PIPELINE STATUS
   FUNCTIONS: QUEUE STATUS
   FUNCTIONS: RETENTION
   FUNCTIONS: ACTIVE OPERATIONS
   FUNCTIONS: STORAGE
   FUNCTIONS: DETAIL MODAL
   FUNCTIONS: FORMATTERS
   FUNCTIONS: PAGE LIFECYCLE HOOKS
   ============================================================================ */


/* ============================================================================
   CONSTANTS: ENGINE PROCESSES
   ----------------------------------------------------------------------------
   The ENGINE_PROCESSES contract: a map from orchestrator process names to
   engine card slugs that cc-shared.js reads at startup to wire up the
   engine indicator subsystem. The Backup Monitoring page has four
   collectors driving its event-driven sections: Collect-BackupStatus
   harvests pipeline state, Process-BackupNetworkCopy moves files to
   network storage, Process-BackupAWSUpload pushes files to AWS, and
   Process-BackupRetention prunes expired backups.
   Prefix: (none)
   ============================================================================ */

/* Maps orchestrator process names to engine card slugs. cc-shared.js
   reads this at startup; each entry binds a process to a card on the
   page. Card refreshes for the bound process happen automatically via
   onEngineProcessCompleted. */
const ENGINE_PROCESSES = {
    'Collect-BackupStatus':      { slug: 'collection' },
    'Process-BackupNetworkCopy': { slug: 'networkcopy' },
    'Process-BackupAWSUpload':   { slug: 'awsupload' },
    'Process-BackupRetention':   { slug: 'retention' }
};


/* ============================================================================
   CONSTANTS: PAGE CONFIGURATION
   ----------------------------------------------------------------------------
   Module-level configuration constants for this page. The refresh
   interval default is overwritten at load time from GlobalConfig.
   Prefix: bkp
   ============================================================================ */

/* Default live-polling interval in seconds. Overwritten at page load by
   bkp_loadRefreshInterval from GlobalConfig (ControlCenter |
   refresh_backup_seconds). 5 seconds keeps the active-operations table
   responsive to in-progress backups starting and stopping. */
const bkp_PAGE_REFRESH_INTERVAL_DEFAULT = 5;


/* ============================================================================
   STATE: PAGE STATE
   ----------------------------------------------------------------------------
   Module-scope mutable state for the Backup Monitoring UI: the live-poll
   and auto-refresh timer handles, the cached scheduled retention time,
   the cached pending-retention totals that back the retention cards,
   the cached queue data that backs the queue cards, and the page-load
   date for midnight rollover detection.
   Prefix: bkp
   ============================================================================ */

/* Effective live-polling interval in seconds. Starts at the default and
   is overwritten by bkp_loadRefreshInterval if GlobalConfig has a value. */
var bkp_pageRefreshInterval = bkp_PAGE_REFRESH_INTERVAL_DEFAULT;

/* setInterval handle for the live-polling timer, or null when not
   running. */
var bkp_livePollingTimer = null;

/* setInterval handle for the midnight-rollover check. */
var bkp_refreshTimer = null;

/* Date string captured at page load. Compared against the current date
   inside the auto-refresh timer to trigger a full reload at midnight. */
var bkp_pageLoadDate = new Date().toDateString();

/* Cached scheduled time for the retention process from
   bkp_loadPipelineStatus. Drives the "Runs ..." note under the
   retention cards. */
var bkp_retentionScheduledTime = null;

/* Cached pending-retention totals from bkp_loadStorageStatus. Drives the
   counts and sizes shown on the local and network retention cards. */
var bkp_pendingRetention = {
    local:   { file_count: 0, total_bytes: 0 },
    network: { file_count: 0, total_bytes: 0 }
};

/* Cached queue data from bkp_loadQueueStatus. Backs the network and AWS
   queue cards; rendered by bkp_renderQueueStatus. */
var bkp_queueData = {
    network_copy: { file_count: 0, total_bytes: 0 },
    aws_upload:   { file_count: 0, total_bytes: 0 }
};


/* ============================================================================
   INITIALIZATION: PAGE BOOT
   ----------------------------------------------------------------------------
   Single DOMContentLoaded handler that loads the refresh interval from
   GlobalConfig, runs the page's first data load, starts the live-polling
   and midnight-rollover timers, registers the engine-events chrome with
   cc-shared.js, and wires the delegated click handlers for the rendered
   cards and the retention slideout panels.
   Prefix: (none)
   ============================================================================ */

document.addEventListener('DOMContentLoaded', async function() {
    await bkp_loadRefreshInterval();
    await bkp_loadAllData();
    await bkp_loadActiveOperations();
    bkp_startAutoRefresh();
    connectEngineEvents();
    initEngineCardClicks();
    bkp_startLivePolling();

    document.getElementById('pipeline-status').addEventListener('click', bkp_onPipelineStatusClick);
    document.getElementById('queue-status').addEventListener('click', bkp_onQueueStatusClick);
    document.getElementById('retention-status').addEventListener('click', bkp_onRetentionStatusClick);
    document.getElementById('local-retention-body').addEventListener('click', bkp_onRetentionSlideoutClick);
    document.getElementById('network-retention-body').addEventListener('click', bkp_onRetentionSlideoutClick);
});


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
        var data = await engineFetch('/api/config/refresh-interval?page=backup');
        if (data) {
            bkp_pageRefreshInterval = data.interval || bkp_PAGE_REFRESH_INTERVAL_DEFAULT;
        }
    } catch (e) {
        /* API unavailable - default already in effect. */
    }
}

/* Loads all event-driven sections in parallel and updates the page
   timestamp. Called by the page boot handler and by bkp_refreshAll. */
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
   is event-driven via onEngineProcessCompleted. */
function bkp_startAutoRefresh() {
    bkp_refreshTimer = setInterval(function() {
        var today = new Date().toDateString();
        if (today !== bkp_pageLoadDate) {
            window.location.reload();
        }
    }, 60000);
}

/* Starts the live-polling timer for the active-operations section.
   Skips when the tab is hidden or the session is expired so we do not
   burn fetches that engineFetch would short-circuit. */
function bkp_startLivePolling() {
    if (bkp_livePollingTimer) clearInterval(bkp_livePollingTimer);
    bkp_livePollingTimer = setInterval(function() {
        if (enginePageHidden || engineSessionExpired) return;
        bkp_refreshLiveSections();
    }, bkp_pageRefreshInterval * 1000);
}

/* Stops live polling. Called by the onSessionExpired hook when
   cc-shared.js detects the session has expired so we do not keep
   firing fetches that will be short-circuited. */
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
   (via the onPageRefresh hook), by the onPageResumed hook on tab
   resume, and by onEngineProcessCompleted when an orchestrator process
   finishes. */
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
    return engineFetch('/api/backup/active-operations')
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
    return engineFetch('/api/backup/pipeline-status')
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
    return engineFetch('/api/backup/storage-status')
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
    return engineFetch('/api/backup/queue-status')
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
   The pipeline status cards: one card per orchestrator process,
   showing run state, last run time, file/byte counts, and a status
   badge. Clicking a card opens the pipeline detail modal with a
   file-level breakdown of the most recent run. The status class and
   badge come from helpers that translate raw event data into UI state.
   Prefix: bkp
   ============================================================================ */

/* Renders the pipeline status cards. One card per process; each card
   shows run state, last run, file/byte counts, and a status badge. */
function bkp_renderPipelineStatus(processes) {
    var container = document.getElementById('pipeline-status');
    var html = '<div class="pipeline-grid">';

    processes.forEach(function(proc) {
        var statusClass = bkp_getProcessStatusClass(proc);
        var isRunning = proc.started_dttm && !proc.completed_dttm;
        var lastRun = isRunning ? 'Running...' : (proc.completed_dttm ? bkp_formatDateTime(proc.completed_dttm) : 'Never');
        var badge = bkp_getProcessBadge(proc, statusClass);

        html += '<div class="pipeline-card ' + statusClass + ' clickable" data-process-name="' + escapeHtml(proc.process_name) + '">';
        html += '<div class="pipeline-card-header">';
        html += '<span class="pipeline-name">' + bkp_formatProcessName(proc.process_name) + '</span>';
        html += '<span class="pipeline-status-badge ' + badge.badgeClass + '">' + badge.label + '</span>';
        html += '</div>';
        html += '<div class="pipeline-card-body">';
        html += '<div class="pipeline-time">' + lastRun + '</div>';

        if (proc.last_files_processed !== null && proc.last_files_processed > 0) {
            html += '<div class="pipeline-detail">' + proc.last_files_processed + ' files';
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
    if (proc.last_status === 'FAILED') return 'status-critical';
    if (proc.started_dttm && !proc.completed_dttm) return 'status-running';

    var minutes = proc.minutes_since_completion;
    if (minutes === null) return 'status-unknown';

    if (proc.process_name === 'RETENTION') {
        if (minutes > 48 * 60) return 'status-critical';
        if (minutes > 25 * 60) return 'status-warning';
        return '';
    }
    if (minutes > 30) return 'status-critical';
    if (minutes > 10) return 'status-warning';
    return '';
}

/* Returns the badge label and class for a pipeline card based on the
   raw process state and the resolved status class. */
function bkp_getProcessBadge(proc, statusClass) {
    if (proc.last_status === 'FAILED') return { label: 'FAILED', badgeClass: 'failed' };
    if (statusClass === 'status-running') return { label: 'RUNNING', badgeClass: 'running' };
    if (statusClass === 'status-critical') return { label: 'STALE', badgeClass: 'failed' };
    if (statusClass === 'status-warning') return { label: 'DELAYED', badgeClass: 'warning' };
    if (statusClass === 'status-unknown') return { label: 'UNKNOWN', badgeClass: 'unknown' };
    return { label: 'SUCCESS', badgeClass: 'success' };
}

/* Delegated click handler for the pipeline status cards. Reads the
   clicked card's data-process-name and opens the pipeline detail
   modal. */
function bkp_onPipelineStatusClick(event) {
    var card = event.target.closest('.pipeline-card.clickable');
    if (!card) return;
    bkp_openPipelineDetail(card.dataset.processName);
}

/* Opens the pipeline detail modal for a single process. Loads the
   file-level breakdown of the most recent run and renders it; shows a
   placeholder for COLLECTION (file-level detail not yet available). */
function bkp_openPipelineDetail(processName) {
    var titles = {
        'COLLECTION':   'Collection -- Last Run',
        'NETWORK_COPY': 'Network Copy -- Last Run',
        'AWS_UPLOAD':   'AWS Upload -- Last Run',
        'RETENTION':    'Retention -- Last Run'
    };

    bkp_openDetailModal(titles[processName] || processName);
    var body = document.getElementById('detail-modal-body');
    body.innerHTML = '<div class="loading">Loading...</div>';

    if (processName === 'COLLECTION') {
        body.innerHTML = '<div class="detail-empty">File-level detail not yet available for Collection.<br>Summary data is shown on the card.</div>';
        return;
    }

    engineFetch('/api/backup/pipeline-detail?process=' + processName)
        .then(function(data) {
            if (!data) { body.innerHTML = '<div class="detail-empty">Failed to load data</div>'; return; }
            if (data.error) { body.innerHTML = '<div class="detail-empty">Error: ' + escapeHtml(data.error) + '</div>'; return; }
            bkp_renderPipelineModal(body, data);
        })
        .catch(function(err) {
            body.innerHTML = '<div class="detail-empty">Failed to load: ' + escapeHtml(err.message) + '</div>';
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
        var statusClass = s.last_status === 'SUCCESS' ? 'summary-status-success'
            : s.last_status === 'PARTIAL' ? 'summary-status-partial'
            : 'summary-status-failed';

        html += '<div class="detail-summary">';
        html += '<span class="summary-item"><span class="' + statusClass + '">' + (s.last_status || '-') + '</span></span>';
        html += '<span class="summary-item">Run: <span class="summary-value">' + (s.started_dttm ? bkp_formatDateTime(s.started_dttm) : '-') + '</span></span>';
        html += '<span class="summary-item">Files: <span class="summary-value">' + s.last_files_processed + '</span></span>';
        if (s.last_bytes_processed > 0) {
            html += '<span class="summary-item">Size: <span class="summary-value">' + bkp_formatBytesShort(s.last_bytes_processed) + '</span></span>';
        }
        html += '<span class="summary-item">Duration: <span class="summary-value">' + bkp_formatDurationMs(s.last_duration_ms) + '</span></span>';
        html += '</div>';

        if (s.last_error_message) {
            html += '<div class="detail-error-message">' + escapeHtml(s.last_error_message) + '</div>';
        }
    }

    if (!data.files || data.files.length === 0) {
        html += '<div class="detail-empty">No file detail recorded for this run</div>';
    } else {
        html += '<table class="detail-table">';
        html += '<thead><tr><th>Status</th><th>Server</th><th>Database</th><th>File</th><th class="align-right">Size</th><th class="align-right">Duration</th></tr></thead>';
        html += '<tbody>';
        data.files.forEach(function(f) {
            var statusCss = f.status === 'SUCCESS' ? 'status-success' : 'status-failed';
            html += '<tr>';
            html += '<td class="' + statusCss + '">' + escapeHtml(f.status) + '</td>';
            html += '<td>' + escapeHtml(f.server_name || '-') + '</td>';
            html += '<td>' + escapeHtml(f.database_name || '-') + '</td>';
            html += '<td>' + escapeHtml(f.file_name || '-') + '</td>';
            html += '<td class="align-right">' + (f.bytes_processed > 0 ? bkp_formatBytesShort(f.bytes_processed) : '-') + '</td>';
            html += '<td class="align-right">' + bkp_formatDurationMs(f.duration_ms) + '</td>';
            html += '</tr>';
            if (f.error_message) {
                html += '<tr><td colspan="6" class="error-detail">' + escapeHtml(f.error_message) + '</td></tr>';
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
   total size. When the queue has files, the card is clickable and
   opens the queue detail modal showing every pending file with backup
   metadata.
   Prefix: bkp
   ============================================================================ */

/* Renders the network and AWS queue cards. Each card shows the pending
   file count and total size; cards with content are clickable. */
function bkp_renderQueueStatus() {
    var container = document.getElementById('queue-status');
    var html = '<div class="card-pair">';

    var netClickable = bkp_queueData.network_copy.file_count > 0;
    html += '<div class="status-card' + (netClickable ? ' clickable' : '') + '" data-queue-type="network">';
    html += '<div class="card-content">';
    html += '<div class="card-label">Network</div>';
    html += '<div class="card-value">' + bkp_queueData.network_copy.file_count + '</div>';
    html += '<div class="card-detail">' + (bkp_queueData.network_copy.total_bytes > 0 ? bkp_formatBytesShort(bkp_queueData.network_copy.total_bytes) : 'Empty') + '</div>';
    html += '</div>';
    html += '<div class="card-icon">&#128193;</div>';
    html += '</div>';

    var awsClickable = bkp_queueData.aws_upload.file_count > 0;
    html += '<div class="status-card' + (awsClickable ? ' clickable' : '') + '" data-queue-type="aws">';
    html += '<div class="card-content">';
    html += '<div class="card-label">AWS</div>';
    html += '<div class="card-value">' + bkp_queueData.aws_upload.file_count + '</div>';
    html += '<div class="card-detail">' + (bkp_queueData.aws_upload.total_bytes > 0 ? bkp_formatBytesShort(bkp_queueData.aws_upload.total_bytes) : 'Empty') + '</div>';
    html += '</div>';
    html += '<div class="card-icon">&#9729;</div>';
    html += '</div>';

    html += '</div>';
    container.innerHTML = html;
}

/* Delegated click handler for the queue status cards. Opens the queue
   detail modal for the clicked queue type, but only if the card is
   marked clickable (queues with no pending files are not clickable). */
function bkp_onQueueStatusClick(event) {
    var card = event.target.closest('.status-card.clickable');
    if (!card) return;
    bkp_openQueueDetail(card.dataset.queueType);
}

/* Opens the queue detail modal for a queue type ('network' or 'aws').
   Loads the per-file breakdown and renders it. */
function bkp_openQueueDetail(type) {
    var titles = { 'network': 'Network Copy Queue', 'aws': 'AWS Upload Queue' };
    bkp_openDetailModal(titles[type] || type);
    var body = document.getElementById('detail-modal-body');
    body.innerHTML = '<div class="loading">Loading...</div>';

    engineFetch('/api/backup/queue-detail?type=' + type)
        .then(function(data) {
            if (!data) { body.innerHTML = '<div class="detail-empty">Failed to load data</div>'; return; }
            if (data.error) { body.innerHTML = '<div class="detail-empty">Error: ' + escapeHtml(data.error) + '</div>'; return; }
            bkp_renderQueueModal(body, data);
        })
        .catch(function(err) {
            body.innerHTML = '<div class="detail-empty">Failed to load: ' + escapeHtml(err.message) + '</div>';
        });
}

/* Renders the queue detail modal: a summary bar with totals plus a
   per-file table showing backup type, server, database, file name,
   backup date, and size. */
function bkp_renderQueueModal(container, data) {
    var html = '';

    if (!data.files || data.files.length === 0) {
        html += '<div class="detail-empty">Queue is empty</div>';
        container.innerHTML = html;
        return;
    }

    html += '<div class="detail-summary">';
    html += '<span class="summary-item">Pending: <span class="summary-value">' + data.total_count + ' files</span></span>';
    html += '<span class="summary-item">Total: <span class="summary-value">' + bkp_formatBytesShort(data.total_bytes) + '</span></span>';
    html += '</div>';

    html += '<table class="detail-table">';
    html += '<thead><tr><th>Type</th><th>Server</th><th>Database</th><th>File</th><th>Backup Date</th><th class="align-right">Size</th></tr></thead>';
    html += '<tbody>';
    data.files.forEach(function(f) {
        html += '<tr>';
        html += '<td><span class="backup-type-badge type-' + f.backup_type.toLowerCase() + '">' + escapeHtml(f.backup_type) + '</span></td>';
        html += '<td>' + escapeHtml(f.server_name) + '</td>';
        html += '<td>' + escapeHtml(f.database_name) + '</td>';
        html += '<td>' + escapeHtml(f.file_name) + '</td>';
        html += '<td>' + bkp_formatDateTime(f.backup_finish_dttm) + '</td>';
        html += '<td class="align-right">' + bkp_formatBytesShort(f.file_size_bytes) + '</td>';
        html += '</tr>';
    });
    html += '</tbody></table>';

    container.innerHTML = html;
}


/* ============================================================================
   FUNCTIONS: RETENTION
   ----------------------------------------------------------------------------
   The local and network retention cards plus their drill-down
   slideouts. The cards show counts and sizes of files pending retention
   pruning; clicking a clickable card opens a slideout listing those
   files grouped by server then by database. Each group is collapsible
   via the slideout's accordion behavior.
   Prefix: bkp
   ============================================================================ */

/* Renders the local and network retention cards. Each card shows the
   pending retention file count and total size; cards with content are
   clickable. The schedule note below the cards shows when the
   retention process is next scheduled to run. */
function bkp_renderRetentionStatus() {
    var container = document.getElementById('retention-status');
    var retentionTime = bkp_retentionScheduledTime
        ? bkp_formatScheduledTime(bkp_retentionScheduledTime)
        : 'Unknown';

    var html = '<div class="card-pair">';

    var localClickable = bkp_pendingRetention.local.file_count > 0;
    html += '<div class="status-card' + (localClickable ? ' clickable' : '') + '" data-retention-type="local">';
    html += '<div class="card-content">';
    html += '<div class="card-label">Local</div>';
    html += '<div class="card-value">' + bkp_pendingRetention.local.file_count + '</div>';
    html += '<div class="card-detail">' + bkp_formatBytesShort(bkp_pendingRetention.local.total_bytes) + '</div>';
    html += '</div>';
    html += '<div class="card-icon">&#128465;</div>';
    html += '</div>';

    var networkClickable = bkp_pendingRetention.network.file_count > 0;
    html += '<div class="status-card' + (networkClickable ? ' clickable' : '') + '" data-retention-type="network">';
    html += '<div class="card-content">';
    html += '<div class="card-label">Network</div>';
    html += '<div class="card-value">' + bkp_pendingRetention.network.file_count + '</div>';
    html += '<div class="card-detail">' + bkp_formatBytesShort(bkp_pendingRetention.network.total_bytes) + '</div>';
    html += '</div>';
    html += '<div class="card-icon">&#128465;</div>';
    html += '</div>';

    html += '</div>';
    html += '<div class="retention-schedule-note">Runs ' + retentionTime + '</div>';

    container.innerHTML = html;
}

/* Delegated click handler for the retention status cards. Opens the
   retention detail slideout for the clicked retention type, but only
   if the card is marked clickable. */
function bkp_onRetentionStatusClick(event) {
    var card = event.target.closest('.status-card.clickable');
    if (!card) return;
    bkp_openRetentionDetail(card.dataset.retentionType);
}

/* Opens the retention detail slideout for a retention type ('local' or
   'network'). Loads the candidate file list and renders it as a nested
   server / database accordion. */
function bkp_openRetentionDetail(type) {
    var panelId = type + '-retention';
    document.getElementById(panelId + '-overlay').classList.add('open');
    document.getElementById(panelId + '-panel').classList.add('open');

    var body = document.getElementById(panelId + '-body');
    body.innerHTML = '<div class="loading">Loading retention candidates...</div>';

    engineFetch('/api/backup/retention-candidates?type=' + type)
        .then(function(data) {
            if (!data) { body.innerHTML = '<div class="slideout-empty">Failed to load data</div>'; return; }
            if (data.error) { body.innerHTML = '<div class="slideout-empty">Error: ' + escapeHtml(data.error) + '</div>'; return; }
            bkp_renderRetentionSlideout(body, data, type);
        })
        .catch(function(err) {
            body.innerHTML = '<div class="slideout-empty">Failed to load: ' + escapeHtml(err.message) + '</div>';
        });
}

/* Closes a retention slideout for a retention type. Wired up from the
   slideout's overlay click and close button in Backup.ps1. */
function bkp_closeRetentionPanel(type) {
    var panelId = type + '-retention';
    document.getElementById(panelId + '-overlay').classList.remove('open');
    document.getElementById(panelId + '-panel').classList.remove('open');
}

/* Renders the retention slideout body: a summary bar showing total
   files / size / database count, then a server-then-database accordion
   tree where each leaf is a file table grouped by backup type. */
function bkp_renderRetentionSlideout(container, data, type) {
    if (!data.files || data.files.length === 0) {
        container.innerHTML = '<div class="slideout-empty">No retention candidates</div>';
        return;
    }

    var html = '';

    html += '<div class="slideout-summary">';
    html += '<div class="slideout-stat"><div class="slideout-stat-value">' + data.total_count + '</div><div class="slideout-stat-label">Files</div></div>';
    html += '<div class="slideout-stat"><div class="slideout-stat-value">' + bkp_formatBytesShort(data.total_bytes) + '</div><div class="slideout-stat-label">Total Size</div></div>';

    var dbSet = {};
    data.files.forEach(function(f) { dbSet[f.server_name + '|' + f.database_name] = true; });
    html += '<div class="slideout-stat"><div class="slideout-stat-value">' + Object.keys(dbSet).length + '</div><div class="slideout-stat-label">Databases</div></div>';
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
        var serverId = 'ret-srv-' + type + '-' + serverName.replace(/[^a-zA-Z0-9]/g, '_');

        html += '<div class="slideout-accordion-header" data-accordion-id="' + serverId + '" id="' + serverId + '-header">';
        html += '<span class="accordion-label">' + escapeHtml(serverName) + '</span>';
        html += '<span class="accordion-stats">' + server.files.length + ' files &middot; ' + bkp_formatBytesShort(server.bytes) + '</span>';
        html += '<span class="accordion-chevron">&#9654;</span>';
        html += '</div>';
        html += '<div class="slideout-accordion-body" id="' + serverId + '-body">';

        var dbNames = Object.keys(server.databases).sort();
        dbNames.forEach(function(dbName) {
            var db = server.databases[dbName];
            var dbId = serverId + '-' + dbName.replace(/[^a-zA-Z0-9]/g, '_');

            html += '<div class="slideout-accordion-header" data-accordion-id="' + dbId + '" id="' + dbId + '-header">';
            html += '<span class="accordion-label">' + escapeHtml(dbName) + '</span>';
            html += '<span class="accordion-stats">' + db.files.length + ' files &middot; ' + bkp_formatBytesShort(db.bytes) + '</span>';
            html += '<span class="accordion-chevron">&#9654;</span>';
            html += '</div>';
            html += '<div class="slideout-accordion-body" id="' + dbId + '-body">';

            html += '<div class="slideout-accordion-cutoff">Keeping ' + db.chain_count + ' newest FULL chain(s) &mdash; cutoff: ' + bkp_formatDateTime(db.cutoff_dttm) + '</div>';

            html += '<table class="slideout-table">';
            html += '<thead><tr><th>Type</th><th>File</th><th>Backup Date</th><th class="align-right">Size</th></tr></thead>';
            html += '<tbody>';
            db.files.forEach(function(f) {
                html += '<tr>';
                html += '<td><span class="backup-type-badge type-' + f.backup_type.toLowerCase() + '">' + escapeHtml(f.backup_type) + '</span></td>';
                html += '<td>' + escapeHtml(f.file_name) + '</td>';
                html += '<td>' + bkp_formatDateTime(f.backup_finish_dttm) + '</td>';
                html += '<td class="align-right">' + bkp_formatBytesShort(f.file_size_bytes) + '</td>';
                html += '</tr>';
            });
            html += '</tbody></table>';
            html += '</div>';
        });

        html += '</div>';
    });

    container.innerHTML = html;
}

/* Delegated click handler for the retention slideout panels. Reads the
   clicked accordion header's data-accordion-id and toggles its
   expanded state. Bound to both the local and network slideout body
   containers. */
function bkp_onRetentionSlideoutClick(event) {
    var header = event.target.closest('.slideout-accordion-header');
    if (!header) return;
    bkp_toggleAccordion(header.dataset.accordionId);
}

/* Toggles the expanded state of an accordion section by id. Adds or
   removes the 'expanded' class on both the header and the body. */
function bkp_toggleAccordion(id) {
    var header = document.getElementById(id + '-header');
    var body = document.getElementById(id + '-body');
    header.classList.toggle('expanded');
    body.classList.toggle('expanded');
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
    var container = document.getElementById('active-operations');
    var html = '';

    /* Backups in progress. */
    html += '<div class="operation-group">';
    html += '<div class="operation-group-header"><span class="op-icon">&#128190;</span> Backups In Progress</div>';

    if (data.backups_in_progress && data.backups_in_progress.length > 0) {
        html += '<table class="operation-table">';
        html += '<thead><tr><th>Server</th><th>Database</th><th>Type</th><th>Progress</th><th>Elapsed</th><th>ETA</th></tr></thead>';
        html += '<tbody>';

        data.backups_in_progress.forEach(function(backup) {
            var commandType = backup.command.replace('BACKUP ', '').replace('RESTORE ', 'R:');
            html += '<tr>';
            html += '<td>' + escapeHtml(backup.server_name) + '</td>';
            html += '<td>' + escapeHtml(backup.database_name || '-') + '</td>';
            html += '<td>' + escapeHtml(commandType) + '</td>';
            html += '<td><div class="progress-bar-container"><div class="progress-bar" style="width: ' + backup.percent_complete + '%"></div><span class="progress-text">' + backup.percent_complete.toFixed(1) + '%</span></div></td>';
            html += '<td>' + bkp_formatMinutes(backup.elapsed_minutes) + '</td>';
            html += '<td>' + bkp_formatMinutes(backup.eta_minutes) + '</td>';
            html += '</tr>';
        });

        html += '</tbody></table>';
    } else {
        html += '<div class="no-activity">No active backups</div>';
    }
    html += '</div>';

    /* Network copies in progress. */
    html += '<div class="operation-group">';
    html += '<div class="operation-group-header"><span class="op-icon">&#128193;</span> Network Copies In Progress</div>';

    if (data.network_copies_in_progress && data.network_copies_in_progress.length > 0) {
        html += '<table class="operation-table">';
        html += '<thead><tr><th>Server</th><th>Database</th><th>File</th><th>Size</th><th>Progress</th><th>Elapsed</th><th>ETA</th></tr></thead>';
        html += '<tbody>';

        data.network_copies_in_progress.forEach(function(file) {
            html += '<tr>';
            html += '<td>' + escapeHtml(file.server_name) + '</td>';
            html += '<td>' + escapeHtml(file.database_name) + '</td>';
            html += '<td class="file-name">' + escapeHtml(file.file_name) + '</td>';
            html += '<td>' + bkp_formatBytes(file.file_size_bytes) + '</td>';
            html += '<td><div class="progress-bar-container"><div class="progress-bar" style="width: ' + file.percent_complete + '%"></div><span class="progress-text">' + file.percent_complete.toFixed(1) + '%~</span></div></td>';
            html += '<td>' + bkp_formatMinutes(file.elapsed_minutes) + '</td>';
            html += '<td>' + bkp_formatMinutes(file.eta_minutes) + '~</td>';
            html += '</tr>';
        });

        html += '</tbody></table>';
    } else {
        html += '<div class="no-activity">No active network copies</div>';
    }
    html += '</div>';

    /* AWS uploads in progress. */
    html += '<div class="operation-group">';
    html += '<div class="operation-group-header"><span class="op-icon">&#9729;</span> AWS Uploads In Progress</div>';

    if (data.aws_uploads_in_progress && data.aws_uploads_in_progress.length > 0) {
        html += '<table class="operation-table">';
        html += '<thead><tr><th>Server</th><th>Database</th><th>File</th><th>Size</th><th>Progress</th><th>Elapsed</th><th>ETA</th></tr></thead>';
        html += '<tbody>';

        data.aws_uploads_in_progress.forEach(function(file) {
            html += '<tr>';
            html += '<td>' + escapeHtml(file.server_name) + '</td>';
            html += '<td>' + escapeHtml(file.database_name) + '</td>';
            html += '<td class="file-name">' + escapeHtml(file.file_name) + '</td>';
            html += '<td>' + bkp_formatBytes(file.file_size_bytes) + '</td>';
            html += '<td><div class="progress-bar-container"><div class="progress-bar" style="width: ' + file.percent_complete + '%"></div><span class="progress-text">' + file.percent_complete.toFixed(1) + '%~</span></div></td>';
            html += '<td>' + bkp_formatMinutes(file.elapsed_minutes) + '</td>';
            html += '<td>' + bkp_formatMinutes(file.eta_minutes) + '~</td>';
            html += '</tr>';
        });

        html += '</tbody></table>';
    } else {
        html += '<div class="no-activity">No active AWS uploads</div>';
    }
    html += '</div>';

    container.innerHTML = html;
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
    var container = document.getElementById('storage-status');
    var html = '';

    html += '<div class="storage-group">';
    html += '<div class="storage-group-header">Local Backup Drives</div>';

    if (data.local_drives && data.local_drives.length > 0) {
        data.local_drives.forEach(function(drive) {
            var usedPercent = 100 - drive.percent_free;
            var statusClass = bkp_getStorageStatusClass(drive.percent_free);

            html += '<div class="storage-drive ' + statusClass + '">';
            html += '<div class="drive-header">';
            html += '<span class="drive-label">' + escapeHtml(drive.server_name) + ' ' + drive.drive_letter + ':</span>';
            html += '<span class="drive-stats">' + bkp_formatMB(drive.free_space_mb) + ' free (' + drive.percent_free.toFixed(0) + '%)</span>';
            html += '</div>';
            html += bkp_createSegmentGauge(usedPercent, statusClass, 80);
            html += '</div>';
        });
    } else {
        html += '<div class="no-data">No backup drive data</div>';
    }
    html += '</div>';

    html += '<div class="storage-group">';
    html += '<div class="storage-group-header">Network Storage</div>';

    if (data.network_storage) {
        if (data.network_storage.error) {
            html += '<div class="storage-drive">';
            html += '<div class="drive-header">';
            html += '<span class="drive-label">' + escapeHtml(data.network_storage.path) + '</span>';
            html += '</div>';
            html += '<div class="storage-error">' + escapeHtml(data.network_storage.error) + '</div>';
            html += '</div>';
        } else {
            var netUsedPercent = 100 - data.network_storage.percent_free;
            var netStatusClass = bkp_getStorageStatusClass(data.network_storage.percent_free);

            html += '<div class="storage-drive ' + netStatusClass + '">';
            html += '<div class="drive-header">';
            html += '<span class="drive-label">' + escapeHtml(data.network_storage.path) + '</span>';
            html += '<span class="drive-stats">' + bkp_formatMB(data.network_storage.free_space_mb) + ' free (' + data.network_storage.percent_free.toFixed(0) + '%)</span>';
            html += '</div>';
            html += bkp_createSegmentGauge(netUsedPercent, netStatusClass, 80);
            html += '</div>';
        }
    } else {
        html += '<div class="no-data">Not configured</div>';
    }
    html += '</div>';

    container.innerHTML = html;
}

/* Returns the status CSS class for a storage drive based on percent
   free space. Below 10% is critical; below 20% is warning; otherwise
   no special status. */
function bkp_getStorageStatusClass(percentFree) {
    if (percentFree < 10) return 'storage-critical';
    if (percentFree < 20) return 'storage-warning';
    return '';
}

/* Builds the 80-segment gauge HTML for a single drive. Segments fill
   left-to-right based on the used percent; the active segment color
   is driven by the storage status class. */
function bkp_createSegmentGauge(percent, statusClass, numSegments) {
    numSegments = numSegments || 80;
    var filledCount = Math.round((percent / 100) * numSegments);
    var activeClass;

    if (statusClass === 'storage-critical') activeClass = 'active-critical';
    else if (statusClass === 'storage-warning') activeClass = 'active-warning';
    else activeClass = 'active-healthy';

    var html = '<div class="segment-bar">';
    for (var i = 0; i < numSegments; i++) {
        html += '<div class="segment' + (i < filledCount ? ' ' + activeClass : '') + '"></div>';
    }
    return html + '</div>';
}


/* ============================================================================
   FUNCTIONS: DETAIL MODAL
   ----------------------------------------------------------------------------
   The shared pipeline-and-queue detail modal. The modal HTML is
   statically declared in Backup.ps1; these functions toggle the
   .hidden class on the overlay element and set the modal title.
   Render functions (bkp_renderPipelineModal, bkp_renderQueueModal)
   populate the modal body for their respective use cases.
   Prefix: bkp
   ============================================================================ */

/* Opens the detail modal with a given title. Reveals the modal overlay
   by removing the .hidden class. */
function bkp_openDetailModal(title) {
    document.getElementById('detail-modal-title').textContent = title;
    document.getElementById('detail-modal-overlay').classList.remove('hidden');
}

/* Closes the detail modal. Hides the modal overlay by adding the
   .hidden class. Wired up from the modal's overlay click and close
   button in Backup.ps1. */
function bkp_closeDetailModal() {
    document.getElementById('detail-modal-overlay').classList.add('hidden');
}


/* ============================================================================
   FUNCTIONS: FORMATTERS
   ----------------------------------------------------------------------------
   Page-local display formatters: timestamp display, scheduled-time
   parsing, byte/MB sizing, duration / minutes rendering, and the
   process-name lookup. The standard escapeHtml from cc-shared.js
   handles HTML attribute and content escaping; these helpers handle
   the per-page display formats not covered by cc-shared.
   Prefix: bkp
   ============================================================================ */

/* Updates the live "last updated" timestamp display in the page
   header. */
function bkp_updateTimestamp() {
    var now = new Date();
    document.getElementById('last-update').textContent = now.toLocaleTimeString();
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
   "today 2 PM" or "tomorrow 2 PM" depending on whether the run time
   has already passed today. */
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
   Megabytes and below are rendered with no decimal; gigabytes and
   above are rendered with one decimal. */
function bkp_formatBytesShort(bytes) {
    if (bytes === 0 || bytes === null) return '0';
    if (bytes >= 1099511627776) return (bytes / 1099511627776).toFixed(1) + 'T';
    if (bytes >= 1073741824)    return (bytes / 1073741824).toFixed(1) + 'G';
    if (bytes >= 1048576)       return (bytes / 1048576).toFixed(0) + 'M';
    if (bytes >= 1024)          return (bytes / 1024).toFixed(0) + 'K';
    return bytes + 'B';
}

/* Formats a megabyte count as a display size string. Above 1 TB
   renders as "X.X TB"; above 1 GB as "X GB"; otherwise "X MB". */
function bkp_formatMB(mb) {
    if (mb === 0 || mb === null) return '0 MB';
    if (mb >= 1048576) return (mb / 1048576).toFixed(1) + ' TB';
    if (mb >= 1024)    return (mb / 1024).toFixed(0) + ' GB';
    return mb + ' MB';
}

/* Formats a minute count as a duration string: "< 1m", "30m",
   "2h 15m". Returns "-" for null or zero. */
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
   decimal; minutes and above with one decimal. Returns "-" for null
   or zero. */
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
    bkp_refreshAll();
}

/* Called by cc-shared.js when the page becomes visible again after
   being hidden. cc-shared.js drives the spin animation; this hook
   does the actual data reload so the user sees current data. */
function onPageResumed() {
    bkp_refreshAll();
}

/* Called by cc-shared.js when the session is detected as expired.
   Stops the live-polling timer so we do not keep firing fetches that
   engineFetch will short-circuit. */
function onSessionExpired() {
    bkp_stopLivePolling();
}

/* Called by cc-shared.js when an orchestrator process listed in
   ENGINE_PROCESSES completes. Refreshes the event-driven sections
   (pipeline, queue, retention, storage) since fresh data is now
   available. */
function onEngineProcessCompleted(processName, event) {
    bkp_refreshAll();
}

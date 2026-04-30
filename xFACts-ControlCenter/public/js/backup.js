/* ============================================================================
   xFACts Control Center - Backup Monitoring JavaScript
   Location: E:\xFACts-ControlCenter\public\js\backup.js
   Version: Tracked in dbo.System_Metadata (component: ServerOps.Backup)

   Page-specific JS for the Backup Monitoring dashboard. Chrome-level
   behavior (connection banner, page refresh, engine cards, modals) is
   provided by engine-events.js per the CC Page Chrome Contract
   (Development Guidelines Section 5.12). This file contains data loading,
   rendering, and Backup-specific interaction logic only.

   CHANGELOG
   ---------
   2026-04-30  Phase 4 (Chrome Standardization, modal migration): the
               pipeline/queue detail modal now uses the shared xf-modal-*
               classes from engine-events.css. openDetailModal /
               closeDetailModal target the new detail-modal-overlay
               element ID and toggle the .hidden class for visibility
               (replacing the old detail-modal element ID). Render
               function class names updated from .modal-summary /
               .modal-table / .modal-empty to .detail-summary /
               .detail-table / .detail-empty matching the renamed CSS
               sub-components in backup.css.
   2026-04-30  Phase 4 (Chrome Standardization): aligned with shared chrome
               contract. Removed local showError() / clearError() functions
               that targeted the legacy 'connection-error' element ID --
               connection state display is now handled exclusively by
               updateConnectionBanner() in engine-events.js. API failure
               logging shifted to console.error. Removed local pageRefresh()
               (the shared version in engine-events.js handles button spin
               animation and delegates to onPageRefresh() defined here).
   ============================================================================ */

// ============================================================================
// STATE
// ============================================================================

var retentionScheduledTime = null;
var pageLoadDate = new Date().toDateString();

// Cache for retention data (loaded with storage)
var pendingRetention = { local: { file_count: 0, total_bytes: 0 }, network: { file_count: 0, total_bytes: 0 } };

// Engine events -- process map for shared WebSocket module (engine-events.js)
var ENGINE_PROCESSES = {
    'Collect-BackupStatus':      { slug: 'collection'},
    'Process-BackupNetworkCopy': { slug: 'networkcopy'},
    'Process-BackupAWSUpload':   { slug: 'awsupload'},
    'Process-BackupRetention':   { slug: 'retention'}
};

// Live polling (Refresh Architecture)
var PAGE_REFRESH_INTERVAL = 5;    // Default; overridden by GlobalConfig on load

// Page hooks for engine-events.js shared module
function onPageResumed()    { refreshAll(); }
function onPageRefresh()    { refreshAll(); }
function onSessionExpired() { stopLivePolling(); }

var livePollingTimer = null;
var refreshTimer = null;

// ============================================================================
// INITIALIZATION
// ============================================================================

document.addEventListener('DOMContentLoaded', async function() {
    await loadRefreshInterval();
    await loadAllData();
    await loadActiveOperations();
    startAutoRefresh();
    connectEngineEvents();
    initEngineCardClicks();
    startLivePolling();
});

async function loadAllData() {
    await Promise.all([
        loadPipelineStatus(),
        loadQueueStatus(),
        loadStorageStatus()
    ]);
    updateTimestamp();
}

function startAutoRefresh() {
    // Lightweight timer -- only checks for overnight date change (page reload)
    // All data refresh is event-driven via onEngineProcessCompleted
    refreshTimer = setInterval(function() {
        var today = new Date().toDateString();
        if (today !== pageLoadDate) {
            window.location.reload();
        }
    }, 60000);
}

// Called by engine-events.js when a relevant PROCESS_COMPLETED event arrives
function onEngineProcessCompleted(processName, event) {
    loadAllData();
}

// ============================================================================
// LIVE POLLING (Refresh Architecture)
// ============================================================================
// Active Operations is the only live polling section on this page.
// It shows currently running backups, network copies, and AWS uploads
// which can start/stop independently of orchestrator collector cycles.
//
// See: Refresh Architecture doc, Section 2.2 (Live Polling Mode)
// ============================================================================

/**
 * Loads the page-specific refresh interval from GlobalConfig via shared API.
 * Called once on page init. Falls back to default if API unavailable.
 */
async function loadRefreshInterval() {
    try {
        var data = await engineFetch('/api/config/refresh-interval?page=backup');
        if (data) {
            PAGE_REFRESH_INTERVAL = data.interval || 5;
        }
    } catch (e) {
        // API unavailable -- use default. Not worth logging; page works fine.
    }
}

/**
 * Starts the live polling timer using the GlobalConfig interval.
 * Timer calls refreshLiveSections() which reloads all live sections on the page.
 */
function startLivePolling() {
    if (livePollingTimer) clearInterval(livePollingTimer);
    livePollingTimer = setInterval(function() {
        refreshLiveSections();
    }, PAGE_REFRESH_INTERVAL * 1000);
}

/**
 * Stops live polling. Used by smart polling (activity-aware) when the page
 * detects no orchestrator activity and live data would be unchanged.
 */
function stopLivePolling() {
    if (enginePageHidden || engineSessionExpired) return;
    if (livePollingTimer) {
        clearInterval(livePollingTimer);
        livePollingTimer = null;
    }
}

/**
 * Reloads all live polling sections and updates the page timestamp.
 * Called by the live polling timer and by manual refresh.
 */
function refreshLiveSections() {
    loadLiveData();
    updateTimestamp();
}

/**
 * Loads data for all live polling sections on this page.
 * Active Operations is the only live section -- it shows running backups,
 * network copies, and AWS uploads which change independently of collectors.
 */
async function loadLiveData() {
    await loadActiveOperations();
}

// ============================================================================
// MANUAL REFRESH
// ============================================================================
// pageRefresh() is provided by engine-events.js -- it handles the button
// spin animation and calls onPageRefresh() defined above. refreshAll() is
// the data-loading worker called by both manual refresh and engine events.

function refreshAll() {
    loadAllData();
    loadActiveOperations();
}

// ============================================================================
// API CALLS
// ============================================================================

function loadActiveOperations() {
    return engineFetch('/api/backup/active-operations')
        .then(function(data) {
            if (!data) return;
            if (data.error) { console.error('Active operations:', data.error); return; }
            renderActiveOperations(data);
            updateTimestamp();
        })
        .catch(function(err) { console.error('Failed to load active operations:', err.message); });
}

function loadPipelineStatus() {
    return engineFetch('/api/backup/pipeline-status')
        .then(function(data) {
            if (!data) return;
            if (data.error) { console.error('Pipeline status:', data.error); return; }
            if (data.retention_scheduled_time) {
                retentionScheduledTime = data.retention_scheduled_time;
            }
            renderPipelineStatus(data.processes);
            renderRetentionStatus();
        })
        .catch(function(err) { console.error('Failed to load pipeline status:', err.message); });
}

function loadStorageStatus() {
    return engineFetch('/api/backup/storage-status')
        .then(function(data) {
            if (!data) return;
            if (data.error) { console.error('Storage status:', data.error); return; }
            // Cache retention data for the retention section
            if (data.pending_retention) {
                pendingRetention = data.pending_retention;
            }
            renderStorageStatus(data);
            // Re-render retention with updated data
            renderRetentionStatus();
        })
        .catch(function(err) { console.error('Failed to load storage status:', err.message); });
}

function loadQueueStatus() {
    return engineFetch('/api/backup/queue-status')
        .then(function(data) {
            if (!data) return;
            if (data.error) { console.error('Queue status:', data.error); return; }
            window.queueData = data;
            renderQueueStatus();
        })
        .catch(function(err) { console.error('Failed to load queue status:', err.message); });
}

// ============================================================================
// RENDER FUNCTIONS
// ============================================================================

function renderPipelineStatus(processes) {
    var container = document.getElementById('pipeline-status');
    var html = '<div class="pipeline-grid">';

    processes.forEach(function(proc) {
        var statusClass = getProcessStatusClass(proc);
        var isRunning = proc.started_dttm && !proc.completed_dttm;
        var lastRun = isRunning ? 'Running...' : (proc.completed_dttm ? formatDateTime(proc.completed_dttm) : 'Never');

        // Badge pill label and class
        var badge = getProcessBadge(proc, statusClass);

        html += '<div class="pipeline-card ' + statusClass + ' clickable" onclick="openPipelineDetail(\'' + proc.process_name + '\')">';
        html += '<div class="pipeline-card-header">';
        html += '<span class="pipeline-name">' + formatProcessName(proc.process_name) + '</span>';
        html += '<span class="pipeline-status-badge ' + badge.badgeClass + '">' + badge.label + '</span>';
        html += '</div>';
        html += '<div class="pipeline-card-body">';
        html += '<div class="pipeline-time">' + lastRun + '</div>';

        if (proc.last_files_processed !== null && proc.last_files_processed > 0) {
            html += '<div class="pipeline-detail">' + proc.last_files_processed + ' files';
            if (proc.last_bytes_processed) {
                html += ' (' + formatBytesShort(proc.last_bytes_processed) + ')';
            }
            html += '</div>';
        }

        html += '</div></div>';
    });

    html += '</div>';
    container.innerHTML = html;
}

function renderQueueStatus() {
    var container = document.getElementById('queue-status');
    var queueData = window.queueData || { network_copy: { file_count: 0, total_bytes: 0 }, aws_upload: { file_count: 0, total_bytes: 0 } };

    var html = '<div class="card-pair">';

    // Network Queue
    var netClickable = queueData.network_copy.file_count > 0;
    html += '<div class="status-card' + (netClickable ? ' clickable' : '') + '"' + (netClickable ? ' onclick="openQueueDetail(\'network\')"' : '') + '>';
    html += '<div class="card-content">';
    html += '<div class="card-label">Network</div>';
    html += '<div class="card-value">' + queueData.network_copy.file_count + '</div>';
    html += '<div class="card-detail">' + (queueData.network_copy.total_bytes > 0 ? formatBytesShort(queueData.network_copy.total_bytes) : 'Empty') + '</div>';
    html += '</div>';
    html += '<div class="card-icon">&#128193;</div>';
    html += '</div>';

    // AWS Queue
    var awsClickable = queueData.aws_upload.file_count > 0;
    html += '<div class="status-card' + (awsClickable ? ' clickable' : '') + '"' + (awsClickable ? ' onclick="openQueueDetail(\'aws\')"' : '') + '>';
    html += '<div class="card-content">';
    html += '<div class="card-label">AWS</div>';
    html += '<div class="card-value">' + queueData.aws_upload.file_count + '</div>';
    html += '<div class="card-detail">' + (queueData.aws_upload.total_bytes > 0 ? formatBytesShort(queueData.aws_upload.total_bytes) : 'Empty') + '</div>';
    html += '</div>';
    html += '<div class="card-icon">&#9729;</div>';
    html += '</div>';

    html += '</div>';
    container.innerHTML = html;
}

function renderRetentionStatus() {
    var container = document.getElementById('retention-status');
    var retentionTime = retentionScheduledTime
        ? formatScheduledTime(retentionScheduledTime)
        : 'Unknown';

    var html = '<div class="card-pair">';

    // Local Retention
    var localClickable = pendingRetention.local.file_count > 0;
    html += '<div class="status-card' + (localClickable ? ' clickable' : '') + '"' + (localClickable ? ' onclick="openRetentionDetail(\'local\')"' : '') + '>';
    html += '<div class="card-content">';
    html += '<div class="card-label">Local</div>';
    html += '<div class="card-value">' + pendingRetention.local.file_count + '</div>';
    html += '<div class="card-detail">' + formatBytesShort(pendingRetention.local.total_bytes) + '</div>';
    html += '</div>';
    html += '<div class="card-icon">&#128465;</div>';
    html += '</div>';

    // Network Retention
    var networkClickable = pendingRetention.network.file_count > 0;
    html += '<div class="status-card' + (networkClickable ? ' clickable' : '') + '"' + (networkClickable ? ' onclick="openRetentionDetail(\'network\')"' : '') + '>';
    html += '<div class="card-content">';
    html += '<div class="card-label">Network</div>';
    html += '<div class="card-value">' + pendingRetention.network.file_count + '</div>';
    html += '<div class="card-detail">' + formatBytesShort(pendingRetention.network.total_bytes) + '</div>';
    html += '</div>';
    html += '<div class="card-icon">&#128465;</div>';
    html += '</div>';

    html += '</div>';
    html += '<div class="retention-schedule-note">Runs ' + retentionTime + '</div>';

    container.innerHTML = html;
}

function renderActiveOperations(data) {
    var container = document.getElementById('active-operations');
    var html = '';

    // Backups In Progress section
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
            html += '<td>' + formatMinutes(backup.elapsed_minutes) + '</td>';
            html += '<td>' + formatMinutes(backup.eta_minutes) + '</td>';
            html += '</tr>';
        });

        html += '</tbody></table>';
    } else {
        html += '<div class="no-activity">No active backups</div>';
    }
    html += '</div>';

    // Network Copies In Progress section
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
            html += '<td>' + formatBytes(file.file_size_bytes) + '</td>';
            html += '<td><div class="progress-bar-container"><div class="progress-bar" style="width: ' + file.percent_complete + '%"></div><span class="progress-text">' + file.percent_complete.toFixed(1) + '%~</span></div></td>';
            html += '<td>' + formatMinutes(file.elapsed_minutes) + '</td>';
            html += '<td>' + formatMinutes(file.eta_minutes) + '~</td>';
            html += '</tr>';
        });

        html += '</tbody></table>';
    } else {
        html += '<div class="no-activity">No active network copies</div>';
    }
    html += '</div>';

    // AWS Uploads In Progress section
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
            html += '<td>' + formatBytes(file.file_size_bytes) + '</td>';
            html += '<td><div class="progress-bar-container"><div class="progress-bar" style="width: ' + file.percent_complete + '%"></div><span class="progress-text">' + file.percent_complete.toFixed(1) + '%~</span></div></td>';
            html += '<td>' + formatMinutes(file.elapsed_minutes) + '</td>';
            html += '<td>' + formatMinutes(file.eta_minutes) + '~</td>';
            html += '</tr>';
        });

        html += '</tbody></table>';
    } else {
        html += '<div class="no-activity">No active AWS uploads</div>';
    }
    html += '</div>';

    container.innerHTML = html;
}

function renderStorageStatus(data) {
    var container = document.getElementById('storage-status');
    var html = '';

    // Local drives section
    html += '<div class="storage-group">';
    html += '<div class="storage-group-header">Local Backup Drives</div>';

    if (data.local_drives && data.local_drives.length > 0) {
        data.local_drives.forEach(function(drive) {
            var usedPercent = 100 - drive.percent_free;
            var statusClass = getStorageStatusClass(drive.percent_free);

            html += '<div class="storage-drive ' + statusClass + '">';
            html += '<div class="drive-header">';
            html += '<span class="drive-label">' + escapeHtml(drive.server_name) + ' ' + drive.drive_letter + ':</span>';
            html += '<span class="drive-stats">' + formatMB(drive.free_space_mb) + ' free (' + drive.percent_free.toFixed(0) + '%)</span>';
            html += '</div>';
            html += createSegmentGauge(usedPercent, statusClass, 80);
            html += '</div>';
        });
    } else {
        html += '<div class="no-data">No backup drive data</div>';
    }
    html += '</div>';

    // Network storage section
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
            var netStatusClass = getStorageStatusClass(data.network_storage.percent_free);

            html += '<div class="storage-drive ' + netStatusClass + '">';
            html += '<div class="drive-header">';
            html += '<span class="drive-label">' + escapeHtml(data.network_storage.path) + '</span>';
            html += '<span class="drive-stats">' + formatMB(data.network_storage.free_space_mb) + ' free (' + data.network_storage.percent_free.toFixed(0) + '%)</span>';
            html += '</div>';
            html += createSegmentGauge(netUsedPercent, netStatusClass, 80);
            html += '</div>';
        }
    } else {
        html += '<div class="no-data">Not configured</div>';
    }
    html += '</div>';

    container.innerHTML = html;
}

// ============================================================================
// GAUGE BUILDER - 80 Segment
// ============================================================================
function createSegmentGauge(percent, statusClass, numSegments) {
    numSegments = numSegments || 80;
    var filledCount = Math.round((percent / 100) * numSegments);
    var activeClass = 'active';

    if (statusClass === 'storage-critical') activeClass = 'active-critical';
    else if (statusClass === 'storage-warning') activeClass = 'active-warning';
    else activeClass = 'active-healthy';

    var html = '<div class="segment-bar">';
    for (var i = 0; i < numSegments; i++) {
        html += '<div class="segment' + (i < filledCount ? ' ' + activeClass : '') + '"></div>';
    }
    return html + '</div>';
}

// ============================================================================
// PIPELINE STATUS HELPERS
// ============================================================================
function getProcessStatusClass(proc) {
    if (proc.last_status === 'FAILED') return 'status-critical';
    if (proc.started_dttm && !proc.completed_dttm) return 'status-running';

    var minutes = proc.minutes_since_completion;
    if (minutes === null) return 'status-unknown';

    if (proc.process_name === 'RETENTION') {
        if (minutes > 48 * 60) return 'status-critical';
        if (minutes > 25 * 60) return 'status-warning';
        return '';
    } else {
        if (minutes > 30) return 'status-critical';
        if (minutes > 10) return 'status-warning';
        return '';
    }
}

function getProcessBadge(proc, statusClass) {
    if (proc.last_status === 'FAILED') return { label: 'FAILED', badgeClass: 'failed' };
    if (statusClass === 'status-running') return { label: 'RUNNING', badgeClass: 'running' };
    if (statusClass === 'status-critical') return { label: 'STALE', badgeClass: 'failed' };
    if (statusClass === 'status-warning') return { label: 'DELAYED', badgeClass: 'warning' };
    if (statusClass === 'status-unknown') return { label: 'UNKNOWN', badgeClass: 'unknown' };
    return { label: 'SUCCESS', badgeClass: 'success' };
}

// ============================================================================
// RETENTION SLIDEOUT
// ============================================================================

function openRetentionDetail(type) {
    var panelId = type + '-retention';
    document.getElementById(panelId + '-overlay').classList.add('open');
    document.getElementById(panelId + '-panel').classList.add('open');

    var body = document.getElementById(panelId + '-body');
    body.innerHTML = '<div class="loading">Loading retention candidates...</div>';

    engineFetch('/api/backup/retention-candidates?type=' + type)
        .then(function(data) {
            if (!data) { body.innerHTML = '<div class="slideout-empty">Failed to load data</div>'; return; }
            if (data.error) { body.innerHTML = '<div class="slideout-empty">Error: ' + escapeHtml(data.error) + '</div>'; return; }
            renderRetentionSlideout(body, data, type);
        })
        .catch(function(err) {
            body.innerHTML = '<div class="slideout-empty">Failed to load: ' + escapeHtml(err.message) + '</div>';
        });
}

function closeRetentionPanel(type) {
    var panelId = type + '-retention';
    document.getElementById(panelId + '-overlay').classList.remove('open');
    document.getElementById(panelId + '-panel').classList.remove('open');
}

function renderRetentionSlideout(container, data, type) {
    if (!data.files || data.files.length === 0) {
        container.innerHTML = '<div class="slideout-empty">No retention candidates</div>';
        return;
    }

    var typeLabel = type === 'local' ? 'Local' : 'Network';
    var html = '';

    // Summary stats
    html += '<div class="slideout-summary">';
    html += '<div class="slideout-stat"><div class="slideout-stat-value">' + data.total_count + '</div><div class="slideout-stat-label">Files</div></div>';
    html += '<div class="slideout-stat"><div class="slideout-stat-value">' + formatBytesShort(data.total_bytes) + '</div><div class="slideout-stat-label">Total Size</div></div>';

    // Count unique databases
    var dbSet = {};
    data.files.forEach(function(f) { dbSet[f.server_name + '|' + f.database_name] = true; });
    html += '<div class="slideout-stat"><div class="slideout-stat-value">' + Object.keys(dbSet).length + '</div><div class="slideout-stat-label">Databases</div></div>';
    html += '</div>';

    // Group by server, then by database
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

    // Render server accordions
    var serverNames = Object.keys(servers).sort();
    serverNames.forEach(function(serverName) {
        var server = servers[serverName];
        var serverId = 'ret-srv-' + type + '-' + serverName.replace(/[^a-zA-Z0-9]/g, '_');

        html += '<div class="slideout-accordion-header" onclick="toggleAccordion(\'' + serverId + '\')" id="' + serverId + '-header">';
        html += '<span class="accordion-label">' + escapeHtml(serverName) + '</span>';
        html += '<span class="accordion-stats">' + server.files.length + ' files &middot; ' + formatBytesShort(server.bytes) + '</span>';
        html += '<span class="accordion-chevron">&#9654;</span>';
        html += '</div>';
        html += '<div class="slideout-accordion-body" id="' + serverId + '-body">';

        // Database sub-accordions
        var dbNames = Object.keys(server.databases).sort();
        dbNames.forEach(function(dbName) {
            var db = server.databases[dbName];
            var dbId = serverId + '-' + dbName.replace(/[^a-zA-Z0-9]/g, '_');

            html += '<div class="slideout-accordion-header" onclick="toggleAccordion(\'' + dbId + '\')" id="' + dbId + '-header">';
            html += '<span class="accordion-label">' + escapeHtml(dbName) + '</span>';
            html += '<span class="accordion-stats">' + db.files.length + ' files &middot; ' + formatBytesShort(db.bytes) + '</span>';
            html += '<span class="accordion-chevron">&#9654;</span>';
            html += '</div>';
            html += '<div class="slideout-accordion-body" id="' + dbId + '-body">';

            // Cutoff info
            html += '<div class="slideout-accordion-cutoff">Keeping ' + db.chain_count + ' newest FULL chain(s) &mdash; cutoff: ' + formatDateTime(db.cutoff_dttm) + '</div>';

            // File table
            html += '<table class="slideout-table">';
            html += '<thead><tr><th>Type</th><th>File</th><th>Backup Date</th><th class="align-right">Size</th></tr></thead>';
            html += '<tbody>';
            db.files.forEach(function(f) {
                html += '<tr>';
                html += '<td><span class="backup-type-badge type-' + f.backup_type.toLowerCase() + '">' + escapeHtml(f.backup_type) + '</span></td>';
                html += '<td>' + escapeHtml(f.file_name) + '</td>';
                html += '<td>' + formatDateTime(f.backup_finish_dttm) + '</td>';
                html += '<td class="align-right">' + formatBytesShort(f.file_size_bytes) + '</td>';
                html += '</tr>';
            });
            html += '</tbody></table>';
            html += '</div>';
        });

        html += '</div>';
    });

    container.innerHTML = html;
}

function toggleAccordion(id) {
    var header = document.getElementById(id + '-header');
    var body = document.getElementById(id + '-body');
    header.classList.toggle('expanded');
    body.classList.toggle('expanded');
}

// ============================================================================
// PIPELINE & QUEUE DETAIL MODALS
// ============================================================================
// Uses the shared xf-modal-* system from engine-events.css. The modal HTML
// is statically declared in Backup.ps1; openDetailModal/closeDetailModal
// toggle the .hidden class on the overlay element to show/hide it.
// Render functions populate the body with .detail-* sub-components defined
// in backup.css (.detail-summary, .detail-table, .detail-empty).

function openDetailModal(title) {
    document.getElementById('detail-modal-title').textContent = title;
    document.getElementById('detail-modal-overlay').classList.remove('hidden');
}

function closeDetailModal() {
    document.getElementById('detail-modal-overlay').classList.add('hidden');
}

function openPipelineDetail(processName) {
    var titles = {
        'COLLECTION':   'Collection -- Last Run',
        'NETWORK_COPY': 'Network Copy -- Last Run',
        'AWS_UPLOAD':   'AWS Upload -- Last Run',
        'RETENTION':    'Retention -- Last Run'
    };

    openDetailModal(titles[processName] || processName);
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
            renderPipelineModal(body, data);
        })
        .catch(function(err) {
            body.innerHTML = '<div class="detail-empty">Failed to load: ' + escapeHtml(err.message) + '</div>';
        });
}

function renderPipelineModal(container, data) {
    var html = '';

    // Summary bar
    if (data.summary) {
        var s = data.summary;
        var statusClass = s.last_status === 'SUCCESS' ? 'summary-status-success'
            : s.last_status === 'PARTIAL' ? 'summary-status-partial'
            : 'summary-status-failed';

        html += '<div class="detail-summary">';
        html += '<span class="summary-item"><span class="' + statusClass + '">' + (s.last_status || '-') + '</span></span>';
        html += '<span class="summary-item">Run: <span class="summary-value">' + (s.started_dttm ? formatDateTime(s.started_dttm) : '-') + '</span></span>';
        html += '<span class="summary-item">Files: <span class="summary-value">' + s.last_files_processed + '</span></span>';
        if (s.last_bytes_processed > 0) {
            html += '<span class="summary-item">Size: <span class="summary-value">' + formatBytesShort(s.last_bytes_processed) + '</span></span>';
        }
        html += '<span class="summary-item">Duration: <span class="summary-value">' + formatDurationMs(s.last_duration_ms) + '</span></span>';
        html += '</div>';

        if (s.last_error_message) {
            html += '<div style="font-size: 11px; color: #f48771; font-style: italic; margin-bottom: 12px; padding: 0 4px;">' + escapeHtml(s.last_error_message) + '</div>';
        }
    }

    // File table
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
            html += '<td class="align-right">' + (f.bytes_processed > 0 ? formatBytesShort(f.bytes_processed) : '-') + '</td>';
            html += '<td class="align-right">' + formatDurationMs(f.duration_ms) + '</td>';
            html += '</tr>';
            if (f.error_message) {
                html += '<tr><td colspan="6" class="error-detail">' + escapeHtml(f.error_message) + '</td></tr>';
            }
        });
        html += '</tbody></table>';
    }

    container.innerHTML = html;
}

function openQueueDetail(type) {
    var titles = { 'network': 'Network Copy Queue', 'aws': 'AWS Upload Queue' };
    openDetailModal(titles[type] || type);
    var body = document.getElementById('detail-modal-body');
    body.innerHTML = '<div class="loading">Loading...</div>';

    engineFetch('/api/backup/queue-detail?type=' + type)
        .then(function(data) {
            if (!data) { body.innerHTML = '<div class="detail-empty">Failed to load data</div>'; return; }
            if (data.error) { body.innerHTML = '<div class="detail-empty">Error: ' + escapeHtml(data.error) + '</div>'; return; }
            renderQueueModal(body, data);
        })
        .catch(function(err) {
            body.innerHTML = '<div class="detail-empty">Failed to load: ' + escapeHtml(err.message) + '</div>';
        });
}

function renderQueueModal(container, data) {
    var html = '';

    if (!data.files || data.files.length === 0) {
        html += '<div class="detail-empty">Queue is empty</div>';
        container.innerHTML = html;
        return;
    }

    // Summary
    html += '<div class="detail-summary">';
    html += '<span class="summary-item">Pending: <span class="summary-value">' + data.total_count + ' files</span></span>';
    html += '<span class="summary-item">Total: <span class="summary-value">' + formatBytesShort(data.total_bytes) + '</span></span>';
    html += '</div>';

    // File table
    html += '<table class="detail-table">';
    html += '<thead><tr><th>Type</th><th>Server</th><th>Database</th><th>File</th><th>Backup Date</th><th class="align-right">Size</th></tr></thead>';
    html += '<tbody>';
    data.files.forEach(function(f) {
        html += '<tr>';
        html += '<td><span class="backup-type-badge type-' + f.backup_type.toLowerCase() + '">' + escapeHtml(f.backup_type) + '</span></td>';
        html += '<td>' + escapeHtml(f.server_name) + '</td>';
        html += '<td>' + escapeHtml(f.database_name) + '</td>';
        html += '<td>' + escapeHtml(f.file_name) + '</td>';
        html += '<td>' + formatDateTime(f.backup_finish_dttm) + '</td>';
        html += '<td class="align-right">' + formatBytesShort(f.file_size_bytes) + '</td>';
        html += '</tr>';
    });
    html += '</tbody></table>';

    container.innerHTML = html;
}

// ============================================================================
// HELPER FUNCTIONS
// ============================================================================

function formatDurationMs(ms) {
    if (!ms || ms <= 0) return '-';
    if (ms < 1000) return ms + 'ms';
    var sec = ms / 1000;
    if (sec < 60) return sec.toFixed(1) + 's';
    var min = sec / 60;
    return min.toFixed(1) + 'm';
}

function getStorageStatusClass(percentFree) {
    if (percentFree < 10) return 'storage-critical';
    if (percentFree < 20) return 'storage-warning';
    return '';
}

function formatProcessName(name) {
    var names = {
        'COLLECTION':   'Collection',
        'NETWORK_COPY': 'Network Copy',
        'AWS_UPLOAD':   'AWS Upload',
        'RETENTION':    'Retention'
    };
    return names[name] || name;
}

function formatTimeAgo(minutes) {
    if (minutes === null) return 'Never';
    if (minutes < 1) return 'Just now';
    if (minutes < 60) return minutes + 'm ago';
    var hours = Math.floor(minutes / 60);
    if (hours < 24) return hours + 'h ago';
    var days = Math.floor(hours / 24);
    return days + 'd ago';
}

function formatScheduledTime(timeStr) {
    // Parse TIME value like "02:00:00" or "20:00:00" from ProcessRegistry
    var parts = timeStr.split(':');
    var hour = parseInt(parts[0], 10);
    var now = new Date();
    var runTime = new Date(now);
    runTime.setHours(hour, parseInt(parts[1] || 0, 10), 0, 0);

    var prefix = (now > runTime) ? 'tomorrow ' : 'today ';
    return prefix + formatHour(hour);
}

function formatHour(hour) {
    if (hour === 0) return '12 AM';
    if (hour === 12) return '12 PM';
    if (hour < 12) return hour + ' AM';
    return (hour - 12) + ' PM';
}

function formatBytes(bytes) {
    if (bytes === 0 || bytes === null) return '0 B';
    var units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var i = 0;
    var size = bytes;
    while (size >= 1024 && i < units.length - 1) { size /= 1024; i++; }
    return size.toFixed(1) + ' ' + units[i];
}

function formatBytesShort(bytes) {
    if (bytes === 0 || bytes === null) return '0';
    if (bytes >= 1099511627776) return (bytes / 1099511627776).toFixed(1) + 'T';
    if (bytes >= 1073741824)    return (bytes / 1073741824).toFixed(1) + 'G';
    if (bytes >= 1048576)       return (bytes / 1048576).toFixed(0) + 'M';
    if (bytes >= 1024)          return (bytes / 1024).toFixed(0) + 'K';
    return bytes + 'B';
}

function formatMB(mb) {
    if (mb === 0 || mb === null) return '0 MB';
    if (mb >= 1048576) return (mb / 1048576).toFixed(1) + ' TB';
    if (mb >= 1024)    return (mb / 1024).toFixed(0) + ' GB';
    return mb + ' MB';
}

function formatMinutes(minutes) {
    if (minutes === null || minutes === 0) return '-';
    if (minutes < 1) return '< 1m';
    if (minutes < 60) return Math.round(minutes) + 'm';
    var hours = Math.floor(minutes / 60);
    var mins = Math.round(minutes % 60);
    return hours + 'h ' + mins + 'm';
}

function formatTime(dateTimeStr) {
    if (!dateTimeStr) return '-';
    var d = new Date(dateTimeStr);
    return d.toLocaleTimeString();
}

function formatDateTime(dateTimeStr) {
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

function escapeHtml(text) {
    if (!text) return '';
    var div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
}

function updateTimestamp() {
    var now = new Date();
    document.getElementById('last-update').textContent = now.toLocaleTimeString();
}

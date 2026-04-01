// ============================================================================
// xFACts Control Center - DBCC Operations JavaScript
// Location: E:\xFACts-ControlCenter\public\js\dbcc-operations.js
// Version: Tracked in dbo.System_Metadata (component: ServerOps.DBCC)
// ============================================================================

// ============================================================================
// CONFIGURATION
// ============================================================================

var ENGINE_PROCESSES = {
    'Execute-DBCC': { slug: 'dbcc' }
};

var PAGE_REFRESH_INTERVAL = 10;

function onPageResumed() { pageRefresh(); }
function onSessionExpired() { stopLivePolling(); }
var livePollingTimer = null;
var pageLoadDate = new Date().toDateString();

var DAY_NAMES = { 1: 'Sun', 2: 'Mon', 3: 'Tue', 4: 'Wed', 5: 'Thu', 6: 'Fri', 7: 'Sat' };

// ============================================================================
// UTILITY FUNCTIONS
// ============================================================================

function formatDuration(seconds) {
    if (seconds === null || seconds === undefined) return '-';
    if (seconds < 60) return Math.round(seconds) + 's';
    if (seconds < 3600) {
        var mins = Math.floor(seconds / 60);
        var secs = Math.round(seconds % 60);
        return mins + 'm ' + secs + 's';
    }
    var hours = Math.floor(seconds / 3600);
    var mins = Math.floor((seconds % 3600) / 60);
    return hours + 'h ' + mins + 'm';
}

function formatTimeAgo(seconds) {
    if (seconds === null || seconds === undefined) return '-';
    if (seconds < 60) return 'just now';
    if (seconds < 3600) return Math.floor(seconds / 60) + 'm ago';
    if (seconds < 86400) return Math.floor(seconds / 3600) + 'h ' + Math.floor((seconds % 3600) / 60) + 'm ago';
    return Math.floor(seconds / 86400) + 'd ago';
}

function formatDateTime(dateStr) {
    if (!dateStr) return '-';
    var date = new Date(dateStr);
    return date.toLocaleString();
}

function formatDateShort(dateStr) {
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
    } else {
        return date.toLocaleDateString();
    }
}

function escapeHtml(str) {
    if (!str) return '';
    return String(str).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

function formatTime(timeStr) {
    if (!timeStr) return '-';
    var parts = timeStr.split(':');
    if (parts.length < 2) return timeStr;
    var hours = parseInt(parts[0], 10);
    var minutes = parts[1];
    var ampm = hours >= 12 ? 'PM' : 'AM';
    var displayHour = hours % 12;
    if (displayHour === 0) displayHour = 12;
    return displayHour + ':' + minutes + ' ' + ampm;
}

function statusBadgeClass(status) {
    switch (status) {
        case 'SUCCESS': return 'success';
        case 'FAILED': return 'failed';
        case 'ERRORS_FOUND': return 'errors-found';
        case 'IN_PROGRESS': return 'running';
        case 'PENDING': return 'pending';
        default: return 'never-run';
    }
}

function opBadgeClass(operation) {
    switch (operation) {
        case 'CHECKDB': return 'checkdb';
        case 'CHECKALLOC': return 'checkalloc';
        case 'CHECKCATALOG': return 'checkcatalog';
        case 'CHECKCONSTRAINTS': return 'checkconstraints';
        case 'CHECKTABLE': return 'checktable';
        default: return '';
    }
}

function showError(message) {
    var errorDiv = document.getElementById('connection-error');
    errorDiv.textContent = message;
    errorDiv.classList.add('visible');
}

function clearError() {
    var errorDiv = document.getElementById('connection-error');
    errorDiv.classList.remove('visible');
}

function updateTimestamp() {
    document.getElementById('last-update').textContent = new Date().toLocaleTimeString();
}

// ============================================================================
// INITIALIZATION
// ============================================================================

document.addEventListener('DOMContentLoaded', async function() {
    await loadRefreshInterval();
    await loadAllData();
    await loadLiveProgress();
    startAutoRefresh();
    connectEngineEvents();
    initEngineCardClicks();
    startLivePolling();

    document.getElementById('btn-pending-queue').addEventListener('click', function() {
        openPendingPanel();
    });

    document.addEventListener('keydown', function(e) {
        if (e.key === 'Escape') {
            closeEditModal();
            closeScheduleModal();
            closePendingPanel();
        }
    });
});

async function loadRefreshInterval() {
    try {
        var data = await engineFetch('/api/config/refresh-interval?page=dbcc-operations');
        if (data && data.interval) {
            PAGE_REFRESH_INTERVAL = data.interval;
        }
    } catch (e) {}
}

async function loadAllData() {
    await Promise.all([
        loadTodaysExecutions(),
        loadExecutionHistory(),
        loadScheduleOverview()
    ]);
    updateTimestamp();
}

// ============================================================================
// REFRESH ARCHITECTURE
// ============================================================================

function startAutoRefresh() {
    setInterval(function() {
        if (new Date().toDateString() !== pageLoadDate) window.location.reload();
    }, 60000);
}

function startLivePolling() {
    if (livePollingTimer) clearInterval(livePollingTimer);
    livePollingTimer = setInterval(function() {
        loadLiveProgress();
        loadTodaysExecutions();
        updateTimestamp();
    }, PAGE_REFRESH_INTERVAL * 1000);
}

function stopLivePolling() {
    if (enginePageHidden || engineSessionExpired) return;
    if (livePollingTimer) {
        clearInterval(livePollingTimer);
        livePollingTimer = null;
    }
}

function onEngineProcessCompleted(processName, event) {
    loadTodaysExecutions();
    loadExecutionHistory();
}

function pageRefresh() {
    var btn = document.querySelector('.page-refresh-btn');
    if (btn) {
        btn.classList.add('spinning');
        btn.addEventListener('animationend', function() {
            btn.classList.remove('spinning');
        }, { once: true });
    }
    loadAllData();
    loadLiveProgress();
}

// ============================================================================
// LIVE PROGRESS
// ============================================================================

async function loadLiveProgress() {
    try {
        var data = await engineFetch('/api/dbcc/live-progress');
        if (!data) return;
        if (data.Error) { showError('Live progress: ' + data.Error); return; }
        clearError();
        renderLiveProgress(data);
    } catch (e) {}
}

var currentPendingOps = [];

function renderLiveProgress(data) {
    var container = document.getElementById('live-progress');

    if (data.IsActive && data.ActiveOps && data.ActiveOps.length > 0) {
        var runningOps = data.ActiveOps.filter(function(op) { return op.Status === 'IN_PROGRESS'; });
        currentPendingOps = data.ActiveOps.filter(function(op) { return op.Status === 'PENDING'; });

        updatePendingBadge(currentPendingOps.length);

        if (runningOps.length > 0) {
            var html = '';
            runningOps.forEach(function(op) {
                html += '<div class="live-op-card status-running">';
                html += '<div class="live-op-header">';
                html += '<div class="live-op-title-block">';
                html += '<div class="live-op-title">';
                html += '<span class="op-badge ' + opBadgeClass(op.Operation) + '">' + escapeHtml(op.Operation) + '</span>';
                html += ' <span class="db-name">' + escapeHtml(op.DatabaseName) + '</span>';
                html += '</div>';
                var subtitleParts = [];
                if (op.CheckMode) subtitleParts.push(op.CheckMode);
                if (op.MaxDop) subtitleParts.push('MAXDOP ' + op.MaxDop);
                if (subtitleParts.length > 0) {
                    html += '<div class="live-op-subtitle">' + subtitleParts.join(' \u00B7 ') + '</div>';
                }
                html += '</div>';
                html += '<span class="status-badge running">';
                html += '<span class="spinning-gear" style="font-size:9px">&#9881;</span> RUNNING</span>';
                html += '</div>';

                html += '<div class="live-op-stats">';
                html += '<div class="live-op-stat"><span class="label">Server:</span> <span class="value">' + escapeHtml(op.ServerName) + '</span></div>';

                if (op.ExecutedOnServer && op.ExecutedOnServer !== op.ServerName) {
                    html += '<div class="live-op-stat"><span class="label">Target:</span> <span class="value">' + escapeHtml(op.ExecutedOnServer) + '</span></div>';
                }

                if (op.ElapsedSeconds !== null) {
                    html += '<div class="live-op-stat"><span class="label">Elapsed:</span> <span class="value">' + formatDuration(op.ElapsedSeconds) + '</span></div>';
                }

                if (op.EtaSeconds !== null && op.EtaSeconds > 0) {
                    html += '<div class="live-op-stat"><span class="label">ETA:</span> <span class="value">' + formatDuration(op.EtaSeconds) + '</span></div>';
                }

                html += '</div>';

                var pct = op.PercentComplete !== null ? op.PercentComplete : 0;
                var pctDisplay = op.PercentComplete !== null ? pct.toFixed(1) + '%' : 'Calculating...';
                html += '<div class="progress-bar-container">';
                html += '<div class="progress-bar" style="width: ' + pct + '%"></div>';
                html += '<span class="progress-text">' + pctDisplay + '</span>';
                html += '</div>';

                html += '</div>';
            });
            container.innerHTML = html;
        } else {
            container.innerHTML = '<div class="no-activity">No operations currently running &mdash; ' + currentPendingOps.length + ' pending</div>';
        }
    }
    else {
        currentPendingOps = [];
        updatePendingBadge(0);
        container.innerHTML = '<div class="no-activity">No active executions</div>';
    }
}

function updatePendingBadge(count) {
    var badge = document.getElementById('pending-count-badge');
    if (count > 0) {
        badge.textContent = count;
        badge.classList.remove('hidden');
    } else {
        badge.classList.add('hidden');
    }
}

// ============================================================================
// PENDING QUEUE MODAL
// ============================================================================

function openPendingPanel() {
    renderPendingQueue(currentPendingOps);
    document.getElementById('pending-modal-overlay').classList.remove('hidden');
}

function closePendingPanel() {
    document.getElementById('pending-modal-overlay').classList.add('hidden');
}

function renderPendingQueue(ops) {
    var body = document.getElementById('pending-panel-body');

    if (!ops || ops.length === 0) {
        body.innerHTML = '<div class="no-activity">No pending operations</div>';
        return;
    }

    var html = '<table class="history-table">';
    html += '<thead><tr><th>Operation</th><th>Database</th><th>Server</th><th>Queued</th></tr></thead>';
    html += '<tbody>';

    ops.forEach(function(op) {
        html += '<tr>';
        html += '<td><span class="op-badge ' + opBadgeClass(op.Operation) + '">' + escapeHtml(op.Operation) + '</span>';
        if (op.CheckMode) {
            html += ' <span style="color:#666;font-size:10px">' + escapeHtml(op.CheckMode) + '</span>';
        }
        html += '</td>';
        html += '<td>' + escapeHtml(op.DatabaseName) + '</td>';
        html += '<td>' + escapeHtml(op.ServerName) + '</td>';
        html += '<td>' + (op.QueueWaitSeconds !== null ? formatDuration(op.QueueWaitSeconds) + ' ago' : '-') + '</td>';
        html += '</tr>';
    });

    html += '</tbody></table>';
    body.innerHTML = html;
}

// ============================================================================
// TODAY'S EXECUTIONS
// ============================================================================

async function loadTodaysExecutions() {
    try {
        var data = await engineFetch('/api/dbcc/todays-executions');
        if (!data) return;
        if (data.error || data.Error) return;
        renderTodaysExecutions(data);
    } catch (e) {}
}

function renderTodaysExecutions(data) {
    var container = document.getElementById('todays-executions');

    if (!data || data.length === 0) {
        container.innerHTML = '<div class="no-activity">No executions today</div>';
        return;
    }

    var html = '<div class="todays-list">';

    data.forEach(function(row) {
        var isRunning = row.status === 'IN_PROGRESS';
        var rowClass = row.status === 'FAILED' ? 'today-row-failed' :
                       row.status === 'ERRORS_FOUND' ? 'today-row-errors' :
                       isRunning ? 'today-row-running' : '';

        html += '<div class="today-row ' + rowClass + '">';
        html += '<span class="op-badge ' + opBadgeClass(row.operation) + '">' + row.operation + '</span>';
        html += '<span class="today-server">' + escapeHtml(row.server_name) + '</span>';
        html += '<span class="today-db">' + escapeHtml(row.database_name) + '</span>';

        if (isRunning && row.elapsed_seconds !== null) {
            html += '<span class="today-duration">' + formatDuration(row.elapsed_seconds) + '</span>';
        } else if (row.duration_seconds !== null) {
            html += '<span class="today-duration">' + formatDuration(row.duration_seconds) + '</span>';
        } else {
            html += '<span class="today-duration">-</span>';
        }

        if (isRunning) {
            html += '<span class="today-time">-</span>';
        } else {
            html += '<span class="today-time">' + formatDateShort(row.completed_dttm) + '</span>';
        }

        html += '<span class="today-mode">' + (row.check_mode ? escapeHtml(row.check_mode) : '') + '</span>';

        html += '<span class="today-status"><span class="status-badge ' + statusBadgeClass(row.status) + '">';
        if (isRunning) {
            html += '<span class="spinning-gear" style="font-size:9px">&#9881;</span> ';
        }
        html += row.status + '</span></span>';

        html += '</div>';
    });

    html += '</div>';
    container.innerHTML = html;
}

// ============================================================================
// EXECUTION HISTORY (Year → Month → Day accordion)
// ============================================================================

var MONTH_NAMES = ['', 'January', 'February', 'March', 'April', 'May', 'June',
                   'July', 'August', 'September', 'October', 'November', 'December'];

async function loadExecutionHistory() {
    try {
        var data = await engineFetch('/api/dbcc/execution-history');
        if (!data) return;
        if (data.error || data.Error) return;
        renderExecutionHistory(data);
    } catch (e) {}
}

function renderExecutionHistory(data) {
    var container = document.getElementById('execution-history');

    if (!data || data.length === 0) {
        container.innerHTML = '<div class="no-activity">No execution history available</div>';
        return;
    }

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

    var html = '<div class="history-tree">';

    yearOrder.forEach(function(year) {
        var yd = years[year];

        html += '<div class="history-year">';
        html += '<div class="year-header" onclick="toggleHistorySection(\'year-' + year + '\')" id="year-' + year + '-header">';
        html += '<span class="expand-icon">&#9654;</span>';
        html += '<span class="year-label">' + year + '</span>';
        html += '<div class="year-stats">';
        html += '<span class="year-stat">' + yd.totalOps + ' executions</span>';
        html += '<span class="year-stat success">' + (yd.successCount + yd.errorsCount) + ' succeeded</span>';
        html += '<span class="year-stat failed">' + (yd.failedCount > 0 ? yd.failedCount + ' failed' : '-') + '</span>';
        html += '</div>';
        html += '</div>';

        html += '<div class="year-content" id="year-' + year + '-body" style="display:none;">';

        html += '<table class="month-summary-table"><thead><tr>';
        html += '<th></th><th>Month</th><th>Executions</th><th>Succeeded</th><th>Failed</th>';
        html += '</tr></thead>';

        yd.monthOrder.forEach(function(month) {
            var md = yd.months[month];
            var monthKey = year + '-' + month;

            html += '<tbody class="month-group">';
            html += '<tr class="month-row" onclick="toggleHistorySection(\'month-' + monthKey + '\')" id="month-' + monthKey + '-header">';
            html += '<td class="expand-cell"><span class="expand-icon">&#9654;</span></td>';
            html += '<td class="month-cell">' + MONTH_NAMES[month] + '</td>';
            html += '<td>' + md.totalOps + '</td>';
            html += '<td class="success-cell">' + (md.successCount + md.errorsCount) + '</td>';
            html += '<td class="fail-cell">' + (md.failedCount > 0 ? md.failedCount : '-') + '</td>';
            html += '</tr>';

            html += '<tr class="month-details" id="month-' + monthKey + '-body" style="display:none;"><td colspan="5">';
            html += '<div class="month-details-content">';
            html += '<table class="history-table"><thead><tr>';
            html += '<th></th><th>Day</th><th>Date</th><th>Runs</th><th>Executions</th><th>Duration</th><th>Succeeded</th><th>Failed</th><th>Warnings</th>';
            html += '</tr></thead><tbody>';

            md.days.forEach(function(day) {
                var dateParts = day.run_date.split('-');
                var dayDisplay = dateParts[1] + '/' + dateParts[2];

                html += '<tr class="day-row" onclick="toggleDayDetail(\'' + day.run_date + '\', this)">';
                html += '<td class="expand-cell"><span class="expand-icon">&#9654;</span></td>';
                html += '<td>' + day.day_of_week + '</td>';
                html += '<td>' + dayDisplay + '</td>';
                html += '<td>' + day.run_count + '</td>';
                html += '<td>' + day.operation_count + '</td>';
                html += '<td>' + formatDuration(day.total_duration_seconds) + '</td>';
                html += '<td class="success-cell">' + (day.success_count + day.errors_found_count) + '</td>';
                html += '<td class="fail-cell">' + (day.failed_count > 0 ? day.failed_count : '-') + '</td>';
                html += '<td class="warning-cell">' + (day.errors_found_count > 0 ? day.errors_found_count : '-') + '</td>';
                html += '</tr>';

                html += '<tr class="day-detail-row" id="day-' + day.run_date + '-body" style="display:none;">';
                html += '<td colspan="9"><div class="day-detail-content"><div class="loading">Loading...</div></div></td>';
                html += '</tr>';
            });

            html += '</tbody></table>';
            html += '</div>';
            html += '</td></tr>';
            html += '</tbody>';
        });

        html += '</table>';
        html += '</div>';
        html += '</div>';
    });

    html += '</div>';
    container.innerHTML = html;
}

function toggleHistorySection(key) {
    var header = document.getElementById(key + '-header');
    var body = document.getElementById(key + '-body');
    if (!header || !body) return;
    var icon = header.querySelector('.expand-icon');

    if (body.style.display === 'none' || body.style.display === '') {
        body.style.display = key.startsWith('month-') ? 'table-row' : 'block';
        icon.textContent = '\u25BC';
    } else {
        body.style.display = 'none';
        icon.textContent = '\u25B6';
    }
}

async function toggleDayDetail(dateStr, rowEl) {
    var detailRow = document.getElementById('day-' + dateStr + '-body');
    if (!detailRow) return;
    var icon = rowEl.querySelector('.expand-icon');
    var contentDiv = detailRow.querySelector('.day-detail-content');

    if (detailRow.style.display !== 'none') {
        detailRow.style.display = 'none';
        if (icon) icon.textContent = '\u25B6';
        return;
    }

    if (contentDiv && contentDiv.querySelector('.loading')) {
        try {
            var data = await engineFetch('/api/dbcc/execution-history-day?date=' + encodeURIComponent(dateStr));
            if (data && !data.error && !data.Error) {
                renderDayDetail(contentDiv, data);
            } else {
                contentDiv.innerHTML = '<div class="no-activity">Failed to load detail</div>';
            }
        } catch (e) {
            contentDiv.innerHTML = '<div class="no-activity">Failed to load detail</div>';
        }
    }

    detailRow.style.display = 'table-row';
    if (icon) icon.textContent = '\u25BC';
}

function renderDayDetail(container, data) {
    if (!data || data.length === 0) {
        container.innerHTML = '<div class="no-activity">No operations this day</div>';
        return;
    }

    var html = '<table class="history-table">';
    html += '<thead><tr><th>Operation</th><th>Server</th><th>Database</th><th>Started</th><th>Completed</th><th>Duration</th><th>Status</th></tr></thead>';
    html += '<tbody>';

    data.forEach(function(op) {
        var isFailed = op.status === 'FAILED';
        var isWarning = op.status === 'ERRORS_FOUND';
        var opRowClass = isFailed ? 'row-failed' : (isWarning ? 'row-warning' : '');
        var hasError = op.error_details && op.error_details.length > 0;
        var hasSummary = op.dbcc_summary_output && op.dbcc_summary_output.length > 0;
        var isExpandable = hasError || hasSummary;

        html += '<tr class="' + opRowClass + (isExpandable ? ' expandable' : '') + '"' +
                 (isExpandable ? ' onclick="toggleDetailRow(' + op.log_id + ')"' : '') + '>';
        html += '<td><span class="op-badge ' + opBadgeClass(op.operation) + '">' + op.operation + '</span>';
        if (op.check_mode) html += ' <span style="color:#666;font-size:10px">' + escapeHtml(op.check_mode) + '</span>';
        html += '</td>';
        html += '<td>' + escapeHtml(op.server_name);
        if (op.executed_on_server && op.executed_on_server !== op.server_name) {
            html += ' <span style="color:#666;font-size:10px">(' + escapeHtml(op.executed_on_server) + ')</span>';
        }
        html += '</td>';
        html += '<td>' + escapeHtml(op.database_name) + '</td>';
        html += '<td>' + formatTimestamp(op.started_dttm) + '</td>';
        html += '<td>' + formatTimestamp(op.completed_dttm) + '</td>';
        html += '<td>' + formatDuration(op.duration_seconds) + '</td>';
        html += '<td><span class="status-badge ' + statusBadgeClass(op.status) + '">' + op.status + '</span>';
        if (isExpandable) html += ' <span style="color:#666;font-size:9px">&#9660;</span>';
        html += '</td>';
        html += '</tr>';

        if (isExpandable) {
            var detailContent = '';
            if (hasError) {
                detailContent = '<div class="detail-label">Error Details</div><div class="detail-text error-text">' + escapeHtml(op.error_details) + '</div>';
            }
            if (hasSummary) {
                if (detailContent) detailContent += '<div style="margin-top:8px;"></div>';
                detailContent += '<div class="detail-label">DBCC Output</div><div class="detail-text">' + escapeHtml(op.dbcc_summary_output) + '</div>';
            }

            html += '<tr class="detail-expand-row" id="detail-row-' + op.log_id + '">';
            html += '<td colspan="7"><div class="detail-expand-content">' + detailContent + '</div></td>';
            html += '</tr>';
        }
    });

    html += '</tbody></table>';
    container.innerHTML = html;
}

function toggleDetailRow(logId) {
    var row = document.getElementById('detail-row-' + logId);
    if (row) {
        row.classList.toggle('expanded');
    }
}

function formatTimestamp(ts) {
    if (!ts) return '-';
    var parts = ts.split(' ');
    return parts.length > 1 ? parts[1] : ts;
}

// ============================================================================
// SCHEDULE OVERVIEW
// ============================================================================

async function loadScheduleOverview() {
    try {
        var data = await engineFetch('/api/dbcc/schedule');
        if (!data) return;
        if (data.error || data.Error) return;
        renderScheduleOverview(data);
    } catch (e) {}
}

var currentScheduleData = [];

function renderScheduleOverview(data) {
    var container = document.getElementById('schedule-overview');

    if (!data || data.length === 0) {
        container.innerHTML = '<div class="no-activity">No DBCC schedules configured</div>';
        return;
    }

    currentScheduleData = data;

    var servers = {};
    var serverOrder = [];
    data.forEach(function(row) {
        if (!servers[row.server_name]) {
            servers[row.server_name] = {
                serverName: row.server_name,
                serverId: row.server_id,
                serverEnabled: row.server_enabled,
                databases: []
            };
            serverOrder.push(row.server_name);
        }
        servers[row.server_name].databases.push(row);
    });

    var html = '<div class="schedule-server-list">';

    serverOrder.forEach(function(serverName) {
        var server = servers[serverName];
        var isDisabled = !server.serverEnabled;
        var dbCount = server.databases.length;
        var overrideCount = server.databases.filter(function(db) { return db.replica_override; }).length;
        var rowClass = isDisabled ? 'schedule-server-row schedule-server-row-disabled' : 'schedule-server-row';

        html += '<div class="' + rowClass + '" onclick="openScheduleModal(\'' + escapeHtml(serverName) + '\')">';
        html += '<span class="schedule-server-name">' + escapeHtml(serverName) + '</span>';
        if (overrideCount > 0) {
            html += '<span class="schedule-override-badge" title="' + overrideCount + ' database(s) with replica override">&#9888; ' + overrideCount + '</span>';
        } else {
            html += '<span></span>';
        }
        html += '<span class="schedule-db-count">' + dbCount + ' database(s)</span>';
        html += '<span class="schedule-server-status">';
        if (isDisabled) {
            html += '<span class="status-badge failed">Disabled</span>';
        } else {
            html += '<span class="status-badge success">Active</span>';
        }
        html += '</span>';
        html += '</div>';
    });

    html += '</div>';
    container.innerHTML = html;
}

// ============================================================================
// SCHEDULE DETAIL MODAL
// ============================================================================

var currentScheduleServer = null;

function openScheduleModal(serverName) {
    currentScheduleServer = serverName;
    var serverDbs = currentScheduleData.filter(function(row) {
        return row.server_name === serverName;
    });

    document.getElementById('schedule-modal-title').textContent = serverName + ' — DBCC Schedule';
    renderScheduleDetail(serverDbs);
    document.getElementById('schedule-modal-overlay').classList.remove('hidden');
}

function closeScheduleModal() {
    document.getElementById('schedule-modal-overlay').classList.add('hidden');
    currentScheduleServer = null;
}

function refreshServerModal() {
    if (!currentScheduleServer) return;
    var serverDbs = currentScheduleData.filter(function(row) {
        return row.server_name === currentScheduleServer;
    });
    renderScheduleDetail(serverDbs);
}

function renderScheduleDetail(databases) {
    var body = document.getElementById('schedule-modal-body');

    if (!databases || databases.length === 0) {
        body.innerHTML = '<div class="no-activity">No databases configured</div>';
        return;
    }

    var html = '<table class="schedule-detail-table">';
    html += '<thead><tr>';
    html += '<th class="schedule-detail-override-col"></th>';
    html += '<th>Database</th>';
    html += '<th>Mode</th>';
    html += '<th>CHECKDB</th>';
    html += '<th>CHECKALLOC</th>';
    html += '<th>CHECKCATALOG</th>';
    html += '<th>CHECKCONST.</th>';
    if (window.isAdmin) html += '<th></th>';
    html += '</tr></thead>';
    html += '<tbody>';

    databases.forEach(function(row) {
        var isEffectivelyDisabled = !row.is_enabled || !row.server_enabled;
        var hasOverride = row.replica_override ? true : false;

        html += '<tr' + (isEffectivelyDisabled ? ' style="opacity:0.4"' : '') + '>';
        html += '<td class="schedule-detail-override-col">';
        if (hasOverride) {
            html += '<span class="schedule-override-icon" title="Replica override: ' + row.replica_override + '">&#9888;</span>';
        }
        html += '</td>';
        html += '<td class="schedule-detail-db">' + escapeHtml(row.database_name) + '</td>';
        html += '<td class="schedule-detail-mode">' + formatCheckMode(row.check_mode) + '</td>';
        html += '<td>' + formatScheduleCell(row.checkdb_enabled, row.checkdb_run_day, row.checkdb_run_time) + '</td>';
        html += '<td>' + formatScheduleCell(row.checkalloc_enabled, row.checkalloc_run_day, row.checkalloc_run_time) + '</td>';
        html += '<td>' + formatScheduleCell(row.checkcatalog_enabled, row.checkcatalog_run_day, row.checkcatalog_run_time) + '</td>';
        html += '<td>' + formatScheduleCell(row.checkconstraints_enabled, row.checkconstraints_run_day, row.checkconstraints_run_time) + '</td>';

        if (window.isAdmin) {
            html += '<td><span class="schedule-edit-icon" onclick="event.stopPropagation(); openEditModal(' + row.schedule_id + ')" title="Edit schedule">&#128197;</span></td>';
        }

        html += '</tr>';
    });

    html += '</tbody></table>';
    body.innerHTML = html;
}

function formatCheckMode(mode) {
    if (!mode || mode === 'NONE') return '<span style="color:#555">&mdash;</span>';
    if (mode === 'PHYSICAL_ONLY') return '<span style="color:#9cdcfe;font-size:11px">PHYSICAL</span>';
    if (mode === 'FULL') return '<span style="color:#dcdcaa;font-size:11px">FULL</span>';
    return '<span style="font-size:11px">' + escapeHtml(mode) + '</span>';
}

// ============================================================================
// SCHEDULE EDIT MODAL
// ============================================================================

var editScheduleId = null;
var editOriginalCheckMode = null;

var DAY_OPTIONS = [
    { value: 1, label: 'Sunday' },
    { value: 2, label: 'Monday' },
    { value: 3, label: 'Tuesday' },
    { value: 4, label: 'Wednesday' },
    { value: 5, label: 'Thursday' },
    { value: 6, label: 'Friday' },
    { value: 7, label: 'Saturday' }
];

var TIME_OPTIONS = [];
for (var h = 0; h < 24; h++) {
    var ampm = h >= 12 ? 'PM' : 'AM';
    var displayH = h % 12;
    if (displayH === 0) displayH = 12;
    var hh = h < 10 ? '0' + h : '' + h;
    TIME_OPTIONS.push({ value: hh + ':00', label: displayH + ':00 ' + ampm });
}

async function openEditModal(scheduleId) {
    editScheduleId = scheduleId;
    document.getElementById('edit-modal-body').innerHTML = '<div class="loading">Loading...</div>';
    document.getElementById('edit-modal-footer').innerHTML = '';
    document.getElementById('edit-modal-overlay').classList.remove('hidden');

    try {
        var data = await engineFetch('/api/dbcc/schedule-detail?schedule_id=' + scheduleId);
        if (!data || data.Error) {
            document.getElementById('edit-modal-body').innerHTML = '<div class="no-activity">Failed to load schedule</div>';
            return;
        }
        renderEditForm(data);
    } catch (e) {
        document.getElementById('edit-modal-body').innerHTML = '<div class="no-activity">Failed to load schedule</div>';
    }
}

function closeEditModal() {
    document.getElementById('edit-modal-overlay').classList.add('hidden');
    editScheduleId = null;
    editOriginalCheckMode = null;
}

function renderEditForm(data) {
    document.getElementById('edit-modal-title').textContent = data.database_name + ' — ' + data.server_name;

    var isAGListener = data.server_type === 'AG_LISTENER';
    var currentOverride = data.replica_override || null;
    var currentCheckMode = data.check_mode || 'NONE';
    editOriginalCheckMode = currentCheckMode;

    var ops = [
        { key: 'checkdb', label: 'CHECKDB', enabled: data.checkdb_enabled, day: data.checkdb_run_day, time: data.checkdb_run_time },
        { key: 'checkalloc', label: 'CHECKALLOC', enabled: data.checkalloc_enabled, day: data.checkalloc_run_day, time: data.checkalloc_run_time },
        { key: 'checkcatalog', label: 'CHECKCATALOG', enabled: data.checkcatalog_enabled, day: data.checkcatalog_run_day, time: data.checkcatalog_run_time },
        { key: 'checkconstraints', label: 'CHECKCONSTRAINTS', enabled: data.checkconstraints_enabled, day: data.checkconstraints_run_day, time: data.checkconstraints_run_time }
    ];

    var html = '';

    html += '<div class="edit-section-header">Database Options</div>';

    html += '<div class="edit-option-row">';
    html += '<span class="edit-option-label">Check mode</span>';
    html += '<div class="edit-option-badges" id="checkmode-badge-group">';
    var modeOptions = [
        { value: 'NONE', label: 'None' },
        { value: 'PHYSICAL_ONLY', label: 'Physical Only' },
        { value: 'FULL', label: 'Full' }
    ];
    modeOptions.forEach(function(opt) {
        var isActive = opt.value === currentCheckMode;
        html += '<span class="edit-badge-pill' + (isActive ? ' active' : '') + '" ';
        html += 'data-value="' + opt.value + '" ';
        html += 'onclick="selectBadgePill(this, \'checkmode\')">';
        html += opt.label + '</span>';
    });
    html += '</div>';
    html += '</div>';

    if (isAGListener) {
        html += '<div class="edit-option-row">';
        html += '<span class="edit-option-label">Target replica</span>';
        html += '<div class="edit-option-badges" id="replica-badge-group">';
        var replicaOptions = [
            { value: '', label: 'Default' },
            { value: 'PRIMARY', label: 'Primary' },
            { value: 'SECONDARY', label: 'Secondary' }
        ];
        replicaOptions.forEach(function(opt) {
            var isActive = (opt.value === '' && !currentOverride) || (opt.value === currentOverride);
            html += '<span class="edit-badge-pill' + (isActive ? ' active' : '') + '" ';
            html += 'data-value="' + opt.value + '" ';
            html += 'onclick="selectBadgePill(this, \'replica\')">';
            html += opt.label + '</span>';
        });
        html += '</div>';
        html += '</div>';
    }

    html += '<div class="edit-section-header">Operations</div>';

    ops.forEach(function(op) {
        var isOn = op.enabled;
        var disabledAttr = isOn ? '' : 'disabled';

        html += '<div class="edit-op-row" data-op="' + op.key + '">';
        html += '<span class="edit-op-label">' + op.label + '</span>';
        html += '<span class="edit-toggle" onclick="toggleEditOp(\'' + op.key + '\')">';
        html += '<span class="edit-toggle-track ' + (isOn ? 'on' : '') + '" id="edit-toggle-' + op.key + '">';
        html += '<span class="edit-toggle-knob"></span>';
        html += '</span></span>';

        html += '<select class="edit-select" id="edit-day-' + op.key + '" ' + disabledAttr + '>';
        html += '<option value="">Day...</option>';
        DAY_OPTIONS.forEach(function(d) {
            var sel = op.day === d.value ? ' selected' : '';
            html += '<option value="' + d.value + '"' + sel + '>' + d.label + '</option>';
        });
        html += '</select>';

        html += '<select class="edit-select" id="edit-time-' + op.key + '" ' + disabledAttr + '>';
        html += '<option value="">Time...</option>';
        TIME_OPTIONS.forEach(function(t) {
            var sel = op.time === t.value ? ' selected' : '';
            html += '<option value="' + t.value + '"' + sel + '>' + t.label + '</option>';
        });
        html += '</select>';

        html += '</div>';
    });

    html += '<div class="edit-status" id="edit-status"></div>';

    document.getElementById('edit-modal-body').innerHTML = html;
    document.getElementById('edit-modal-footer').innerHTML =
        '<button class="btn-cancel" onclick="closeEditModal()">Cancel</button>' +
        '<button class="btn-save" onclick="saveScheduleEdits()">Save Changes</button>';
}

function selectBadgePill(pill, groupType) {
    var group = pill.parentElement;
    var pills = group.querySelectorAll('.edit-badge-pill');
    pills.forEach(function(p) { p.classList.remove('active'); });
    pill.classList.add('active');

    if (groupType === 'checkmode') {
        var selectedMode = pill.getAttribute('data-value');
        var statusEl = document.getElementById('edit-status');

        if (selectedMode === 'NONE') {
            var checkdbTrack = document.getElementById('edit-toggle-checkdb');
            if (checkdbTrack && checkdbTrack.classList.contains('on')) {
                statusEl.textContent = 'CHECKDB will be disabled when check mode is set to None';
                statusEl.className = 'edit-status error';
            }
        } else {
            if (statusEl.textContent.indexOf('check mode') !== -1 || statusEl.textContent.indexOf('Check mode') !== -1) {
                statusEl.textContent = '';
                statusEl.className = 'edit-status';
            }
        }
    }
}

function toggleEditOp(opKey) {
    var track = document.getElementById('edit-toggle-' + opKey);
    var daySelect = document.getElementById('edit-day-' + opKey);
    var timeSelect = document.getElementById('edit-time-' + opKey);

    var isOn = track.classList.contains('on');

    if (isOn) {
        track.classList.remove('on');
        daySelect.disabled = true;
        timeSelect.disabled = true;
    } else {
        if (opKey === 'checkdb') {
            var selectedMode = getSelectedCheckMode();
            if (selectedMode === 'NONE') {
                var statusEl = document.getElementById('edit-status');
                statusEl.textContent = 'Set check mode to Physical Only or Full before enabling CHECKDB';
                statusEl.className = 'edit-status error';
                return;
            }
        }

        track.classList.add('on');
        daySelect.disabled = false;
        timeSelect.disabled = false;
    }

    var statusEl = document.getElementById('edit-status');
    statusEl.textContent = '';
    statusEl.className = 'edit-status';
}

function getSelectedCheckMode() {
    var group = document.getElementById('checkmode-badge-group');
    if (!group) return null;
    var active = group.querySelector('.edit-badge-pill.active');
    if (!active) return null;
    return active.getAttribute('data-value');
}

function getSelectedReplicaOverride() {
    var group = document.getElementById('replica-badge-group');
    if (!group) return undefined;
    var active = group.querySelector('.edit-badge-pill.active');
    if (!active) return undefined;
    var val = active.getAttribute('data-value');
    return val === '' ? null : val;
}

async function saveScheduleEdits() {
    if (!editScheduleId) return;

    var ops = ['checkdb', 'checkalloc', 'checkcatalog', 'checkconstraints'];
    var opNames = { checkdb: 'CHECKDB', checkalloc: 'CHECKALLOC', checkcatalog: 'CHECKCATALOG', checkconstraints: 'CHECKCONSTRAINTS' };
    var statusEl = document.getElementById('edit-status');
    var saveBtn = document.querySelector('.btn-save');

    statusEl.textContent = 'Saving...';
    statusEl.className = 'edit-status';
    if (saveBtn) saveBtn.disabled = true;

    var errors = [];
    var saved = 0;

    var selectedCheckMode = getSelectedCheckMode();
    if (selectedCheckMode !== null && selectedCheckMode !== editOriginalCheckMode) {
        try {
            var modeResult = await engineFetch('/api/dbcc/schedule/check-mode', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    schedule_id: editScheduleId,
                    check_mode: selectedCheckMode
                })
            });

            if (modeResult && modeResult.Success) {
                saved++;
            } else if (modeResult && modeResult.Error) {
                errors.push('Check Mode: ' + modeResult.Error);
            }
        } catch (e) {
            errors.push('Check Mode: ' + e.message);
        }
    }

    if (errors.length > 0) {
        if (saveBtn) saveBtn.disabled = false;
        statusEl.textContent = 'Errors: ' + errors.join('; ');
        statusEl.className = 'edit-status error';
        return;
    }

    for (var i = 0; i < ops.length; i++) {
        var opKey = ops[i];
        var track = document.getElementById('edit-toggle-' + opKey);
        var daySelect = document.getElementById('edit-day-' + opKey);
        var timeSelect = document.getElementById('edit-time-' + opKey);

        var enabled = track.classList.contains('on');
        var runDay = daySelect.value ? parseInt(daySelect.value) : null;
        var runTime = timeSelect.value || null;

        try {
            var result = await engineFetch('/api/dbcc/schedule/update', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    schedule_id: editScheduleId,
                    operation: opNames[opKey],
                    enabled: enabled,
                    run_day: runDay,
                    run_time: runTime
                })
            });

            if (result && result.Success) {
                saved++;
            } else if (result && result.Error) {
                errors.push(opNames[opKey] + ': ' + result.Error);
            }
        } catch (e) {
            errors.push(opNames[opKey] + ': ' + e.message);
        }
    }

    var replicaOverride = getSelectedReplicaOverride();
    if (replicaOverride !== undefined) {
        try {
            var replicaResult = await engineFetch('/api/dbcc/schedule/replica-override', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    schedule_id: editScheduleId,
                    replica_override: replicaOverride
                })
            });

            if (replicaResult && replicaResult.Success) {
                saved++;
            } else if (replicaResult && replicaResult.Error) {
                errors.push('Replica Override: ' + replicaResult.Error);
            }
        } catch (e) {
            errors.push('Replica Override: ' + e.message);
        }
    }

    if (saveBtn) saveBtn.disabled = false;

    if (errors.length > 0) {
        statusEl.textContent = 'Errors: ' + errors.join('; ');
        statusEl.className = 'edit-status error';
    } else {
        statusEl.textContent = saved + ' item(s) updated';
        statusEl.className = 'edit-status success';

        await loadScheduleOverview();
        refreshServerModal();

        setTimeout(function() {
            closeEditModal();
        }, 600);
    }
}

function formatScheduleCell(enabled, runDay, runTime) {
    if (!enabled) {
        return '<span class="schedule-detail-cell disabled">&mdash;</span>';
    }

    var dayName = DAY_NAMES[runDay] || '?';
    var timeDisplay = formatTime(runTime);

    return '<span class="schedule-detail-cell enabled">' + dayName + ' ' + timeDisplay + '</span>';
}

// ============================================================================
// xFACts Control Center - DM Operations JavaScript
// Location: E:\xFACts-ControlCenter\public\js\dm-operations.js
// Version: Tracked in dbo.System_Metadata (component: ControlCenter.DmOperations)
// ============================================================================

// ============================================================================
// CONFIGURATION
// ============================================================================

// Engine events — process map for shared WebSocket module (engine-events.js)
var ENGINE_PROCESSES = {
    'Execute-DmArchive':    { slug: 'archive' },
    'Execute-DmShellPurge': { slug: 'shellpurge' }
};

// Live polling
var PAGE_REFRESH_INTERVAL = 30;
var livePollingTimer = null;
var pageLoadDate = new Date().toDateString();

// Page hooks for engine-events.js shared module
function onPageResumed() { pageRefresh(); }
function onSessionExpired() { stopPolling(); }

// ----------------------------------------------------------------------------
// State
// ----------------------------------------------------------------------------
var consecutiveErrors = 0;
var currentAbortState = { archive: false, shellpurge: false };

// Track expanded accordion sections across refreshes
var expandedSections = {};

// Schedule drag state
var isDragging = false;
var dragSelectedCells = [];
var dragPaintValue = 1;
var currentScheduleProcess = null;

// Day constants
var DAY_NAMES = { 1: 'Sun', 2: 'Mon', 3: 'Tue', 4: 'Wed', 5: 'Thu', 6: 'Fri', 7: 'Sat' };
var DAY_ORDER = [2, 3, 4, 5, 6, 7, 1]; // Mon-Sun display order
var MONTH_NAMES = ['', 'January', 'February', 'March', 'April', 'May', 'June',
                   'July', 'August', 'September', 'October', 'November', 'December'];

// ============================================================================
// UTILITY FUNCTIONS
// ============================================================================

function formatNumber(num) {
    if (num === null || num === undefined) return '-';
    return num.toLocaleString();
}

function formatDuration(seconds) {
    if (seconds === null || seconds === undefined || seconds === 0) return '-';
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

function formatHour(h) {
    if (h === 0) return '12a';
    if (h < 12) return h + 'a';
    if (h === 12) return '12p';
    return (h - 12) + 'p';
}

function getCellClass(value) {
    switch (value) {
        case 1: return 'full';
        case 2: return 'reduced';
        default: return 'blocked';
    }
}

function getCellLabel(value) {
    switch (value) {
        case 1: return 'Full';
        case 2: return 'Reduced';
        default: return 'Blocked';
    }
}

// ============================================================================
// DATA LOADING
// ============================================================================

async function loadLifetimeTotals() {
    try {
        var data = await engineFetch('/api/dmops/lifetime-totals');
        if (!data) return;
        
        currentAbortState.archive = data.ArchiveAborted;
        currentAbortState.shellpurge = data.ShellPurgeAborted;
        updateAbortButtons();
        
        renderLifetimeTotals(data);
        consecutiveErrors = 0;
    } catch (error) {
        consecutiveErrors++;
        console.error('Failed to load lifetime totals:', error);
        if (consecutiveErrors >= 3) {
            document.getElementById('lifetime-totals').innerHTML =
                '<div class="no-activity">Unable to connect to server</div>';
        }
    }
}

async function loadToday() {
    try {
        var data = await engineFetch('/api/dmops/today');
        if (!data) return;
        renderToday('archive-today', data.Archive, true);
        renderToday('shellpurge-today', data.ShellPurge, false);
    } catch (error) {
        console.error('Failed to load today stats:', error);
    }
}

async function loadExecutionHistory() {
    try {
        var data = await engineFetch('/api/dmops/execution-history');
        if (!data) return;
        renderExecutionHistory('archive-history', data.Archive, true);
        renderExecutionHistory('shellpurge-history', data.ShellPurge, false);
    } catch (error) {
        console.error('Failed to load execution history:', error);
    }
}

// ============================================================================
// RENDERING — Lifetime Totals
// ============================================================================

function renderLifetimeTotals(data) {
    var container = document.getElementById('lifetime-totals');
    var a = data.Archive;
    var p = data.ShellPurge;
    var r = data.Remaining;
    
    // Calculate remaining with subtractive math
    var archiveRemaining = r.ArchiveBaseline !== null ? (r.ArchiveBaseline - r.ArchiveSinceBaseline) : null;
    var shellRemaining = r.ShellBaseline !== null ? (r.ShellBaseline - r.ShellSinceBaseline) : null;
    
    var archiveRemainingSub = '';
    if (r.BaselineDttm) {
        archiveRemainingSub = 'as of ' + r.BaselineDttm.split(' ')[1];
    }
    
    var shellRemainingSub = '';
    if (r.ExclusionCount > 0) {
        shellRemainingSub = formatNumber(r.ExclusionCount) + ' excluded';
    }
    
    container.innerHTML =
        '<div class="summary-card">' +
            '<div class="summary-card-label">Accounts Archived</div>' +
            '<div class="summary-card-value archive">' + formatNumber(a.Accounts) + '</div>' +
            '<div class="summary-card-sub">' + formatNumber(a.Consumers) + ' consumers · ' + formatNumber(a.Batches) + ' batches</div>' +
        '</div>' +
        '<div class="summary-card">' +
            '<div class="summary-card-label">Archive Remaining</div>' +
            '<div class="summary-card-value remaining">' + (archiveRemaining !== null ? formatNumber(archiveRemaining) : '—') + '</div>' +
            '<div class="summary-card-sub">' + (archiveRemainingSub || 'awaiting baseline') + '</div>' +
        '</div>' +
        '<div class="summary-card">' +
            '<div class="summary-card-label">Shells Purged</div>' +
            '<div class="summary-card-value purge">' + formatNumber(p.Consumers) + '</div>' +
            '<div class="summary-card-sub">' + formatNumber(p.Batches) + ' batches</div>' +
        '</div>' +
        '<div class="summary-card">' +
            '<div class="summary-card-label">Shells Remaining</div>' +
            '<div class="summary-card-value remaining">' + (shellRemaining !== null ? formatNumber(shellRemaining) : '—') + '</div>' +
            '<div class="summary-card-sub">' + (shellRemainingSub || 'awaiting baseline') + '</div>' +
        '</div>';
}

// ============================================================================
// RENDERING — Today Stats
// ============================================================================

function renderToday(containerId, data, isArchive) {
    var container = document.getElementById(containerId);
    var colorClass = isArchive ? 'archive' : 'purge';
    
    if (data.Batches === 0) {
        container.innerHTML = '<div class="no-activity">No activity today</div>';
        return;
    }
    
    var html = '<div class="today-stats">';
    html += '<div class="today-stat"><div class="today-stat-value ' + colorClass + '">' + formatNumber(data.Batches) + '</div><div class="today-stat-label">Batches</div></div>';
    if (isArchive) {
        html += '<div class="today-stat"><div class="today-stat-value ' + colorClass + '">' + formatNumber(data.Accounts) + '</div><div class="today-stat-label">Accounts</div></div>';
    }
    html += '<div class="today-stat"><div class="today-stat-value ' + colorClass + '">' + formatNumber(data.Consumers) + '</div><div class="today-stat-label">Consumers</div></div>';
    html += '<div class="today-stat"><div class="today-stat-value">' + formatNumber(data.RowsDeleted) + '</div><div class="today-stat-label">Rows</div></div>';
    html += '<div class="today-stat"><div class="today-stat-value">' + formatDuration(data.TotalSeconds) + '</div><div class="today-stat-label">Runtime</div></div>';
    html += '</div>';
    
    container.innerHTML = html;
}

// ============================================================================
// RENDERING — Execution History (Year → Month → Day accordion)
// ============================================================================

function renderExecutionHistory(containerId, days, isArchive) {
    var container = document.getElementById(containerId);
    
    if (!days || days.length === 0) {
        container.innerHTML = '<div class="no-activity">No execution history</div>';
        return;
    }
    
    // Group by year → month → day
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
            years[y].months[m] = { days: [], totalAccounts: 0, totalConsumers: 0, totalRows: 0, totalBatches: 0, totalSeconds: 0 };
            years[y].monthOrder.push(m);
        }
        
        years[y].months[m].days.push(row);
        years[y].months[m].totalConsumers += row.consumers;
        years[y].months[m].totalRows += row.rows_deleted;
        years[y].months[m].totalBatches += row.batches;
        years[y].months[m].totalSeconds += row.total_seconds;
        if (isArchive) years[y].months[m].totalAccounts += (row.accounts || 0);
        
        years[y].totalConsumers += row.consumers;
        years[y].totalRows += row.rows_deleted;
        if (isArchive) years[y].totalAccounts += (row.accounts || 0);
    });
    
    var prefix = isArchive ? 'arch' : 'shell';
    var html = '<div class="history-tree">';
    
    yearOrder.forEach(function(year) {
        var yd = years[year];
        var yearKey = prefix + '-year-' + year;
        var yearExpanded = expandedSections[yearKey] || false;
        
        html += '<div class="history-year">';
        html += '<div class="year-header" onclick="toggleHistorySection(\'' + yearKey + '\')" id="' + yearKey + '-header">';
        html += '<span class="expand-icon">' + (yearExpanded ? '&#9660;' : '&#9654;') + '</span>';
        html += '<span class="year-label">' + year + '</span>';
        html += '<div class="year-stats">';
        if (isArchive) {
            html += '<span class="year-stat processed">' + formatNumber(yd.totalAccounts) + ' accounts</span>';
        }
        html += '<span class="year-stat processed">' + formatNumber(yd.totalConsumers) + ' consumers</span>';
        html += '</div>';
        html += '</div>';
        
        html += '<div class="year-content" id="' + yearKey + '-body" style="display:' + (yearExpanded ? 'block' : 'none') + ';">';
        
        var colCount = isArchive ? 6 : 5;
        html += '<table class="month-summary-table"><thead><tr>';
        html += '<th></th><th>Month</th><th class="right">Batches</th>';
        if (isArchive) html += '<th class="right">Accounts</th>';
        html += '<th class="right">Consumers</th>';
        html += '<th class="right">Rows</th><th class="right">Time</th>';
        html += '</tr></thead>';
        
        yd.monthOrder.forEach(function(month) {
            var md = years[year].months[month];
            var monthKey = prefix + '-month-' + year + '-' + month;
            var monthExpanded = expandedSections[monthKey] || false;
            
            html += '<tbody class="month-group">';
            html += '<tr class="month-row" onclick="toggleHistorySection(\'' + monthKey + '\')" id="' + monthKey + '-header">';
            html += '<td class="expand-cell"><span class="expand-icon">' + (monthExpanded ? '&#9660;' : '&#9654;') + '</span></td>';
            html += '<td class="month-cell">' + MONTH_NAMES[month] + '</td>';
            html += '<td class="right">' + formatNumber(md.totalBatches) + '</td>';
            if (isArchive) html += '<td class="right">' + formatNumber(md.totalAccounts) + '</td>';
            html += '<td class="right">' + formatNumber(md.totalConsumers) + '</td>';
            html += '<td class="right">' + formatNumber(md.totalRows) + '</td>';
            html += '<td class="right">' + formatDuration(md.totalSeconds) + '</td>';
            html += '</tr>';
            
            // Day rows (hidden by default, or shown if expanded)
            html += '<tr class="month-details" id="' + monthKey + '-body" style="display:' + (monthExpanded ? 'table-row' : 'none') + ';"><td colspan="' + colCount + '">';
            html += '<div class="month-details-content">';
            html += '<table class="day-table"><thead><tr>';
            html += '<th>Day</th><th>Date</th><th class="right">Batches</th>';
            if (isArchive) html += '<th class="right">Accounts</th>';
            html += '<th class="right">Consumers</th>';
            html += '<th class="right">Rows</th><th class="right">Time</th>';
            html += '</tr></thead><tbody>';
            
            md.days.forEach(function(day) {
                var dateParts = day.run_date.split('-');
                var dayDisplay = dateParts[1] + '/' + dateParts[2];
                
                html += '<tr>';
                html += '<td>' + day.day_of_week.substring(0, 3) + '</td>';
                html += '<td>' + dayDisplay + '</td>';
                html += '<td class="right">' + formatNumber(day.batches) + '</td>';
                if (isArchive) html += '<td class="right">' + formatNumber(day.accounts || 0) + '</td>';
                html += '<td class="right">' + formatNumber(day.consumers) + '</td>';
                html += '<td class="right">' + formatNumber(day.rows_deleted) + '</td>';
                html += '<td class="right">' + formatDuration(day.total_seconds) + '</td>';
                html += '</tr>';
            });
            
            html += '</tbody></table></div></td></tr>';
            html += '</tbody>';
        });
        
        html += '</table></div></div>';
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
        body.style.display = key.indexOf('-month-') !== -1 ? 'table-row' : 'block';
        if (icon) icon.innerHTML = '&#9660;';
        expandedSections[key] = true;
    } else {
        body.style.display = 'none';
        if (icon) icon.innerHTML = '&#9654;';
        expandedSections[key] = false;
    }
}

// ============================================================================
// SCHEDULE MODAL — Editable Grid with Three-State Drag
// ============================================================================

async function openScheduleModal(process) {
    currentScheduleProcess = process;
    var title = process === 'archive' ? 'Archive Schedule' : 'Shell Purge Schedule';
    document.getElementById('schedule-panel-title').textContent = title;
    
    document.getElementById('schedule-overlay').classList.add('active');
    document.getElementById('schedule-panel').classList.add('active');
    
    var body = document.getElementById('schedule-panel-body');
    body.innerHTML = '<div class="loading">Loading schedule...</div>';
    
    try {
        var url = '/api/dmops/' + process + '/schedule';
        var data = await engineFetch(url);
        if (!data) return;
        renderScheduleModal(data, process);
    } catch (error) {
        body.innerHTML = '<div class="no-activity">Error loading schedule: ' + error.message + '</div>';
    }
}

function closeSchedulePanel() {
    document.getElementById('schedule-overlay').classList.remove('active');
    document.getElementById('schedule-panel').classList.remove('active');
    currentScheduleProcess = null;
    resetDragState();
}

function renderScheduleModal(scheduleData, process) {
    var body = document.getElementById('schedule-panel-body');
    
    var html = '<div class="schedule-modal-grid">';
    
    // Paint mode selector
    html += '<div class="schedule-mode-selector">';
    html += '<label>Paint mode:</label>';
    html += '<button class="schedule-mode-btn active-full" id="mode-btn-1" onclick="setSchedulePaintMode(1)">Full</button>';
    html += '<button class="schedule-mode-btn" id="mode-btn-2" onclick="setSchedulePaintMode(2)">Reduced</button>';
    html += '<button class="schedule-mode-btn" id="mode-btn-0" onclick="setSchedulePaintMode(0)">Blocked</button>';
    html += '<span class="schedule-drag-hint">Click or drag to paint cells</span>';
    html += '</div>';
    
    // Legend
    html += '<div class="schedule-legend" style="margin-bottom:12px">';
    html += '<div class="schedule-legend-item"><div class="schedule-legend-box full"></div><span>Full</span></div>';
    html += '<div class="schedule-legend-item"><div class="schedule-legend-box reduced"></div><span>Reduced</span></div>';
    html += '<div class="schedule-legend-item"><div class="schedule-legend-box blocked"></div><span>Blocked</span></div>';
    html += '</div>';
    
    // Grid
    html += '<div class="schedule-grid" onmouseup="handleScheduleMouseUp()" onmouseleave="handleScheduleMouseLeave()">';
    
    // Hour labels
    html += '<div class="schedule-hour-labels"><div class="schedule-day-label"></div>';
    html += '<div class="schedule-hours">';
    for (var h = 0; h < 24; h++) {
        html += '<div class="schedule-hour-label">' + formatHour(h) + '</div>';
    }
    html += '</div></div>';
    
    // Day rows
    for (var d = 0; d < DAY_ORDER.length; d++) {
        var day = DAY_ORDER[d];
        var daySchedule = null;
        for (var i = 0; i < scheduleData.length; i++) {
            if (scheduleData[i].DayOfWeek === day) { daySchedule = scheduleData[i]; break; }
        }
        if (!daySchedule) daySchedule = {};
        
        html += '<div class="schedule-row">';
        html += '<div class="schedule-day-label">' + DAY_NAMES[day] + '</div>';
        html += '<div class="schedule-hours">';
        
        for (var h = 0; h < 24; h++) {
            var hourKey = 'Hr' + h.toString().padStart(2, '0');
            var value = daySchedule[hourKey] !== undefined ? daySchedule[hourKey] : 0;
            var cellClass = getCellClass(value);
            
            html += '<div class="schedule-cell ' + cellClass + '" ' +
                'data-day="' + day + '" data-hour="' + h + '" data-value="' + value + '" ' +
                'onmousedown="handleScheduleMouseDown(event, this)" ' +
                'onmouseover="handleScheduleMouseOver(this)" ' +
                'title="' + DAY_NAMES[day] + ' ' + formatHour(h) + ' — ' + getCellLabel(value) + '">' +
                '</div>';
        }
        
        html += '</div></div>';
    }
    
    html += '</div></div>';
    body.innerHTML = html;
}

// Paint mode
function setSchedulePaintMode(mode) {
    dragPaintValue = mode;
    [0, 1, 2].forEach(function(m) {
        var btn = document.getElementById('mode-btn-' + m);
        if (!btn) return;
        btn.className = 'schedule-mode-btn';
        if (m === mode) {
            var activeClass = m === 1 ? 'active-full' : m === 2 ? 'active-reduced' : 'active-blocked';
            btn.classList.add(activeClass);
        }
    });
}

// Drag handlers
function handleScheduleMouseDown(event, cell) {
    event.preventDefault();
    isDragging = true;
    dragSelectedCells = [cell];
    cell.classList.add('drag-selected');
}

function handleScheduleMouseOver(cell) {
    if (!isDragging) return;
    if (dragSelectedCells.indexOf(cell) === -1) {
        dragSelectedCells.push(cell);
        cell.classList.add('drag-selected');
    }
}

function handleScheduleMouseUp() {
    if (!isDragging) return;
    applyDragSelection();
}

function handleScheduleMouseLeave() {
    if (!isDragging) return;
    applyDragSelection();
}

async function applyDragSelection() {
    if (!isDragging || dragSelectedCells.length === 0) {
        resetDragState();
        return;
    }
    
    var cells = dragSelectedCells.slice();
    var paintValue = dragPaintValue;
    var process = currentScheduleProcess;
    
    resetDragState();
    
    var updates = [];
    cells.forEach(function(cell) {
        var currentValue = parseInt(cell.getAttribute('data-value'));
        if (currentValue !== paintValue) {
            updates.push({
                DayOfWeek: parseInt(cell.getAttribute('data-day')),
                Hour: parseInt(cell.getAttribute('data-hour')),
                Value: paintValue
            });
        }
        cell.classList.remove('drag-selected');
    });
    
    if (updates.length === 0) return;
    
    // Optimistic update
    cells.forEach(function(cell) {
        cell.className = 'schedule-cell ' + getCellClass(paintValue);
        cell.setAttribute('data-value', paintValue);
        cell.classList.add('saving');
        
        var day = parseInt(cell.getAttribute('data-day'));
        var hour = parseInt(cell.getAttribute('data-hour'));
        cell.title = DAY_NAMES[day] + ' ' + formatHour(hour) + ' — ' + getCellLabel(paintValue);
    });
    
    try {
        await engineFetch('/api/dmops/schedule/update-batch', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ Process: process, Updates: updates })
        });
        
        cells.forEach(function(cell) { cell.classList.remove('saving'); });
    } catch (error) {
        console.error('Schedule update failed:', error);
        var url = '/api/dmops/' + process + '/schedule';
        var data = await engineFetch(url);
        if (data) renderScheduleModal(data, process);
    }
}

function resetDragState() {
    isDragging = false;
    dragSelectedCells.forEach(function(cell) {
        if (cell && cell.classList) cell.classList.remove('drag-selected');
    });
    dragSelectedCells = [];
}

// ============================================================================
// ABORT TOGGLE
// ============================================================================

async function toggleAbort(process) {
    var newState = !currentAbortState[process];
    var label = process === 'archive' ? 'Archive' : 'Shell Purge';
    
    if (newState) {
        if (!confirm('Set ' + label + ' abort flag? This will stop the process after the current batch completes.')) {
            return;
        }
    }
    
    try {
        await engineFetch('/api/dmops/abort', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ Process: process, Abort: newState })
        });
        
        currentAbortState[process] = newState;
        updateAbortButtons();
    } catch (error) {
        alert('Failed to update abort flag: ' + error.message);
    }
}

function updateAbortButtons() {
    var archAbort = document.getElementById('archive-abort-btn');
    var purgeAbort = document.getElementById('shellpurge-abort-btn');
    var archSchedule = document.getElementById('archive-schedule-btn');
    var purgeSchedule = document.getElementById('shellpurge-schedule-btn');
    
    // Show admin-only buttons
    if (window.isAdmin) {
        if (archAbort) archAbort.style.display = '';
        if (purgeAbort) purgeAbort.style.display = '';
        if (archSchedule) archSchedule.style.display = '';
        if (purgeSchedule) purgeSchedule.style.display = '';
    }
    
    if (archAbort) {
        archAbort.classList.toggle('active', currentAbortState.archive);
        archAbort.innerHTML = currentAbortState.archive ? '&#9632; ABORT SET' : '&#9632; Abort';
        archAbort.title = currentAbortState.archive ? 'Click to clear abort flag' : 'Emergency stop';
    }
    
    if (purgeAbort) {
        purgeAbort.classList.toggle('active', currentAbortState.shellpurge);
        purgeAbort.innerHTML = currentAbortState.shellpurge ? '&#9632; ABORT SET' : '&#9632; Abort';
        purgeAbort.title = currentAbortState.shellpurge ? 'Click to clear abort flag' : 'Emergency stop';
    }
}

// ============================================================================
// REFRESH & POLLING
// ============================================================================

async function onPageRefresh() {
    var now = new Date().toDateString();
    if (now !== pageLoadDate) {
        pageLoadDate = now;
        window.location.reload();
        return;
    }
    
    await Promise.all([
        loadLifetimeTotals(),
        loadToday(),
        loadExecutionHistory()
    ]);
    
    document.getElementById('last-update').textContent = new Date().toLocaleTimeString();
}

function startPolling() {
    if (livePollingTimer) return;
    
    fetch('/api/config/refresh-interval?page=dm_operations')
        .then(function(r) { return r.ok ? r.json() : null; })
        .then(function(data) {
            if (data && data.interval && !data.default) {
                PAGE_REFRESH_INTERVAL = data.interval;
            }
            livePollingTimer = setInterval(pageRefresh, PAGE_REFRESH_INTERVAL * 1000);
        })
        .catch(function() {
            livePollingTimer = setInterval(pageRefresh, PAGE_REFRESH_INTERVAL * 1000);
        });
}

function stopPolling() {
    if (livePollingTimer) {
        clearInterval(livePollingTimer);
        livePollingTimer = null;
    }
}

// ============================================================================
// INITIALIZATION
// ============================================================================

document.addEventListener('DOMContentLoaded', function() {
    updateAbortButtons();
    pageRefresh();
    startPolling();
    connectEngineEvents();
});

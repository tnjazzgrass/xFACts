// ============================================================================
// xFACts Control Center - DM Operations JavaScript
// Location: E:\xFACts-ControlCenter\public\js\dm-operations.js
// Version: Tracked in dbo.System_Metadata (component: DmOps.Archive)
// ============================================================================

// ============================================================================
// CONFIGURATION
// ============================================================================

// Engine events — process map for shared WebSocket module (engine-events.js)
var ENGINE_PROCESSES = {
    'Execute-DmConsumerArchive': { slug: 'archive' },
    'Execute-DmShellPurge':      { slug: 'shellpurge' }
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

// Per-day batch lists keyed by 'arch-batches-YYYY-MM-DD' or 'shell-batches-YYYY-MM-DD'.
// Populated on day-row expand. Used to repopulate the inner table after a refresh
// without re-fetching unless the day still appears in the latest summary.
var dayBatchCache = {};

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

function formatMs(ms) {
    if (ms === null || ms === undefined) return '-';
    return formatDuration(ms / 1000);
}

function formatTimeOnly(dttm) {
    if (!dttm) return '-';
    // dttm is "YYYY-MM-DD HH:mm:ss"
    var parts = dttm.split(' ');
    return parts.length > 1 ? parts[1] : dttm;
}

function formatHour(h) {
    if (h === 0) return '12a';
    if (h < 12) return h + 'a';
    if (h === 12) return '12p';
    return (h - 12) + 'p';
}

function escapeHtml(str) {
    if (str === null || str === undefined) return '';
    var div = document.createElement('div');
    div.appendChild(document.createTextNode(String(str)));
    return div.innerHTML;
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

// ----------------------------------------------------------------------------
// Status / mode badges
// ----------------------------------------------------------------------------
function statusBadge(status) {
    if (!status) return '<span class="status-badge unknown">-</span>';
    var cls = 'status-badge';
    var s = status.toLowerCase();
    if (s === 'success')  cls += ' success';
    else if (s === 'failed' || s === 'error') cls += ' failed';
    else if (s === 'skipped') cls += ' skipped';
    else if (s === 'running' || s === 'in progress' || s === 'inprogress') cls += ' running';
    else cls += ' unknown';
    return '<span class="' + cls + '">' + escapeHtml(status) + '</span>';
}

function bidataBadge(status) {
    if (!status) return '<span class="bidata-badge unknown">-</span>';
    var cls = 'bidata-badge';
    var s = status.toLowerCase();
    if (s === 'success')  cls += ' success';
    else if (s === 'failed') cls += ' failed';
    else if (s === 'skipped') cls += ' skipped';
    else if (s === 'running' || s === 'in progress' || s === 'inprogress') cls += ' running';
    else cls += ' unknown';
    return '<span class="' + cls + '">' + escapeHtml(status) + '</span>';
}

function modeBadge(mode) {
    if (!mode) return '<span class="mode-badge unknown">-</span>';
    var cls = 'mode-badge';
    var m = mode.toLowerCase();
    if (m === 'full') cls += ' full';
    else if (m === 'reduced') cls += ' reduced';
    else if (m === 'manual') cls += ' manual';
    else if (m === 'retry') cls += ' retry';
    else cls += ' unknown';
    return '<span class="' + cls + '">' + escapeHtml(mode) + '</span>';
}

// Color the delete_order prefix (A/AB/C/AU/CU) consistently across the page
function deleteOrderHtml(deleteOrder) {
    if (!deleteOrder) return '';
    var prefix = '';
    var rest = deleteOrder;
    // Match longest prefix first
    var m = deleteOrder.match(/^(AU|CU|AB|A|C)(.*)$/);
    if (m) { prefix = m[1]; rest = m[2]; }
    var cls = 'order-prefix order-' + prefix.toLowerCase();
    return '<span class="' + cls + '">' + escapeHtml(prefix) + '</span>' + escapeHtml(rest);
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

// ----------------------------------------------------------------------------
// Target Server Badges (Archive / ShellPurge)
// One-shot load on page init — values come from GlobalConfig and rarely change,
// so they aren't tied to the regular refresh cycle. Reload the page to pick up
// config changes.
// ----------------------------------------------------------------------------
async function loadTargetServers() {
    try {
        var data = await engineFetch('/api/dmops/target-servers');
        if (!data) return;
        applyTargetBadge('archive-target-badge', data.Archive);
        applyTargetBadge('shellpurge-target-badge', data.ShellPurge);
    } catch (error) {
        console.error('Failed to load target servers:', error);
    }
}

function applyTargetBadge(elementId, info) {
    var el = document.getElementById(elementId);
    if (!el) return;

    // Reset modifier classes
    el.classList.remove('env-test', 'env-prod', 'env-unknown');

    var server = info && info.Server ? info.Server : null;
    var env    = info && info.Environment ? String(info.Environment) : null;

    if (env) {
        var envUpper = env.toUpperCase();
        if (envUpper.indexOf('TEST') !== -1) {
            el.classList.add('env-test');
        } else if (envUpper.indexOf('PROD') !== -1) {
            el.classList.add('env-prod');
        } else {
            el.classList.add('env-unknown');
        }
        el.textContent = env;
    } else {
        el.classList.add('env-unknown');
        el.textContent = 'unknown';
    }

    el.title = server ? ('Target server: ' + server) : 'No target server configured';
}

// ============================================================================
// RENDERING — Lifetime Totals (6 tiles)
// Tiles: Consumers Archived, Consumers Remaining, Accounts Archived, Accounts Remaining,
//        Shells Purged, Shells Remaining
// ============================================================================

function renderLifetimeTotals(data) {
    var container = document.getElementById('lifetime-totals');
    var a = data.Archive;
    var p = data.ShellPurge;
    var r = data.Remaining;

    // Subtractive math for live remaining
    var consumersRemaining = (r.ArchiveConsumersBaseline !== null && r.ArchiveConsumersBaseline !== undefined)
        ? (r.ArchiveConsumersBaseline - (r.ArchiveConsumersSinceBaseline || 0))
        : null;
    var accountsRemaining = (r.ArchiveAccountsBaseline !== null && r.ArchiveAccountsBaseline !== undefined)
        ? (r.ArchiveAccountsBaseline - (r.ArchiveAccountsSinceBaseline || 0))
        : null;
    var shellRemaining = (r.ShellBaseline !== null && r.ShellBaseline !== undefined)
        ? (r.ShellBaseline - (r.ShellSinceBaseline || 0))
        : null;

    var baselineSub = '';
    if (r.BaselineDttm) {
        baselineSub = 'as of ' + r.BaselineDttm.split(' ')[1];
    }

    container.innerHTML =
        // --- Consumers Archived (primary metric for the unified consumer archive) ---
        '<div class="summary-card">' +
            '<div class="summary-card-label">Consumers Archived</div>' +
            '<div class="summary-card-value archive">' + formatNumber(a.Consumers) + '</div>' +
            '<div class="summary-card-sub">' + formatNumber(a.Batches) + ' batches' +
                (a.Exceptions > 0 ? ' &middot; ' + formatNumber(a.Exceptions) + ' exceptions' : '') +
            '</div>' +
        '</div>' +
        // --- Consumers Remaining (TC_ARCH gated) ---
        '<div class="summary-card">' +
            '<div class="summary-card-label">Consumers Remaining</div>' +
            '<div class="summary-card-value remaining">' + (consumersRemaining !== null ? formatNumber(consumersRemaining) : '&mdash;') + '</div>' +
            '<div class="summary-card-sub">' + (baselineSub || 'awaiting baseline') + '</div>' +
        '</div>' +
        // --- Accounts Archived (secondary context metric) ---
        '<div class="summary-card">' +
            '<div class="summary-card-label">Accounts Archived</div>' +
            '<div class="summary-card-value archive">' + formatNumber(a.Accounts) + '</div>' +
            '<div class="summary-card-sub">' + formatNumber(a.RowsDeleted) + ' rows deleted</div>' +
        '</div>' +
        // --- Accounts Remaining (accounts on TC_ARCH-tagged consumers) ---
        '<div class="summary-card">' +
            '<div class="summary-card-label">Accounts Remaining</div>' +
            '<div class="summary-card-value remaining">' + (accountsRemaining !== null ? formatNumber(accountsRemaining) : '&mdash;') + '</div>' +
            '<div class="summary-card-sub">on TC_ARCH consumers</div>' +
        '</div>' +
        // --- Shells Purged ---
        '<div class="summary-card">' +
            '<div class="summary-card-label">Shells Purged</div>' +
            '<div class="summary-card-value purge">' + formatNumber(p.Consumers) + '</div>' +
            '<div class="summary-card-sub">' + formatNumber(p.Batches) + ' batches</div>' +
        '</div>' +
        // --- Shells Remaining ---
        '<div class="summary-card">' +
            '<div class="summary-card-label">Shells Remaining</div>' +
            '<div class="summary-card-value remaining">' + (shellRemaining !== null ? formatNumber(shellRemaining) : '&mdash;') + '</div>' +
            '<div class="summary-card-sub">' + (baselineSub || 'awaiting baseline') + '</div>' +
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
    html += '<div class="today-stat"><div class="today-stat-value ' + colorClass + '">' + formatNumber(data.Consumers) + '</div><div class="today-stat-label">Consumers</div></div>';
    if (isArchive) {
        html += '<div class="today-stat"><div class="today-stat-value">' + formatNumber(data.Accounts) + '</div><div class="today-stat-label">Accounts</div></div>';
    }
    html += '<div class="today-stat"><div class="today-stat-value">' + formatNumber(data.RowsDeleted) + '</div><div class="today-stat-label">Rows</div></div>';
    html += '<div class="today-stat"><div class="today-stat-value">' + formatDuration(data.TotalSeconds) + '</div><div class="today-stat-label">Runtime</div></div>';

    if (isArchive) {
        // Show exceptions and BIDATA failures only when nonzero — no noise on quiet days
        if (data.Exceptions && data.Exceptions > 0) {
            html += '<div class="today-stat"><div class="today-stat-value warn">' + formatNumber(data.Exceptions) + '</div><div class="today-stat-label">Exceptions</div></div>';
        }
        if (data.BidataFailed && data.BidataFailed > 0) {
            html += '<div class="today-stat"><div class="today-stat-value danger">' + formatNumber(data.BidataFailed) + '</div><div class="today-stat-label">BIDATA Failed</div></div>';
        }
    }

    if (data.FailedBatches && data.FailedBatches > 0) {
        html += '<div class="today-stat"><div class="today-stat-value danger">' + formatNumber(data.FailedBatches) + '</div><div class="today-stat-label">Failed</div></div>';
    }

    html += '</div>';
    container.innerHTML = html;
}

// ============================================================================
// RENDERING — Execution History (Year → Month → Day → Batches accordion)
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
        if (isArchive) years[y].totalAccounts += (row.accounts || 0);
    });

    var prefix = isArchive ? 'arch' : 'shell';
    var process = isArchive ? 'archive' : 'shellpurge';
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
        html += '<span class="year-stat processed">' + formatNumber(yd.totalConsumers) + ' consumers</span>';
        if (isArchive) {
            html += '<span class="year-stat processed">' + formatNumber(yd.totalAccounts) + ' accounts</span>';
        }
        html += '</div>';
        html += '</div>';

        html += '<div class="year-content" id="' + yearKey + '-body" style="display:' + (yearExpanded ? 'block' : 'none') + ';">';

        // Month summary table — column count varies by isArchive
        var monthColCount = isArchive ? 7 : 6;

        html += '<table class="month-summary-table"><thead><tr>';
        html += '<th></th><th>Month</th><th class="right">Batches</th>';
        html += '<th class="right">Consumers</th>';
        if (isArchive) html += '<th class="right">Accounts</th>';
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
            html += '<td class="right">' + formatNumber(md.totalConsumers) + '</td>';
            if (isArchive) html += '<td class="right">' + formatNumber(md.totalAccounts) + '</td>';
            html += '<td class="right">' + formatNumber(md.totalRows) + '</td>';
            html += '<td class="right">' + formatDuration(md.totalSeconds) + '</td>';
            html += '</tr>';

            // Day rows
            html += '<tr class="month-details" id="' + monthKey + '-body" style="display:' + (monthExpanded ? 'table-row' : 'none') + ';"><td colspan="' + monthColCount + '">';
            html += '<div class="month-details-content">';

            // Day-summary table
            var dayColCount = isArchive ? 8 : 6;
            html += '<table class="day-table"><thead><tr>';
            html += '<th></th><th>Day</th><th>Date</th>';
            html += '<th class="right">Batches</th>';
            html += '<th class="right">Consumers</th>';
            if (isArchive) html += '<th class="right">Accounts</th>';
            html += '<th class="right">Rows</th>';
            html += '<th class="right">Time</th>';
            if (isArchive) html += '<th class="right">Exc</th>';
            html += '</tr></thead><tbody>';

            md.days.forEach(function(day) {
                var dateParts = day.run_date.split('-');
                var dayDisplay = dateParts[1] + '/' + dateParts[2];
                var dayKey = prefix + '-batches-' + day.run_date;
                var dayExpanded = expandedSections[dayKey] || false;
                var rowFailedClass = (day.failed_batches > 0 || (isArchive && day.bidata_failed > 0)) ? ' row-warn' : '';

                // The day-summary row is now clickable; clicking expands the per-batch sub-table
                html += '<tr class="day-row' + rowFailedClass + '" onclick="toggleDayBatches(\'' + process + '\',\'' + day.run_date + '\')" id="' + dayKey + '-header">';
                html += '<td class="expand-cell"><span class="expand-icon">' + (dayExpanded ? '&#9660;' : '&#9654;') + '</span></td>';
                html += '<td>' + day.day_of_week.substring(0, 3) + '</td>';
                html += '<td>' + dayDisplay + '</td>';
                html += '<td class="right">' + formatNumber(day.batches) +
                    (day.failed_batches > 0 ? ' <span class="cell-fail">(' + day.failed_batches + ' failed)</span>' : '') +
                    '</td>';
                html += '<td class="right">' + formatNumber(day.consumers) + '</td>';
                if (isArchive) html += '<td class="right">' + formatNumber(day.accounts || 0) + '</td>';
                html += '<td class="right">' + formatNumber(day.rows_deleted) + '</td>';
                html += '<td class="right">' + formatDuration(day.total_seconds) + '</td>';
                if (isArchive) {
                    var excText = (day.exceptions || 0) > 0 ? formatNumber(day.exceptions) : '-';
                    var bidataNote = (day.bidata_failed || 0) > 0 ? ' <span class="cell-fail" title="BIDATA migration failed in ' + day.bidata_failed + ' batch(es)">&#9888;</span>' : '';
                    html += '<td class="right">' + excText + bidataNote + '</td>';
                }
                html += '</tr>';

                // Batch-list row, hidden by default
                html += '<tr class="day-batches" id="' + dayKey + '-body" style="display:' + (dayExpanded ? 'table-row' : 'none') + ';">';
                html += '<td colspan="' + dayColCount + '"><div class="day-batches-content" id="' + dayKey + '-content">';
                html += '<div class="loading">Loading batches&hellip;</div>';
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

    // For any day section that was already expanded prior to refresh, re-render its
    // cached batch list (or re-fetch if needed).
    Object.keys(expandedSections).forEach(function(key) {
        if (!expandedSections[key]) return;
        if (key.indexOf(prefix + '-batches-') !== 0) return;
        var date = key.substring((prefix + '-batches-').length);
        if (dayBatchCache[key]) {
            renderBatches(process, date, dayBatchCache[key]);
        } else {
            loadBatchesByDay(process, date);
        }
    });
}

function toggleHistorySection(key) {
    var header = document.getElementById(key + '-header');
    var body = document.getElementById(key + '-body');
    if (!header || !body) return;
    var icon = header.querySelector('.expand-icon');

    if (body.style.display === 'none' || body.style.display === '') {
        body.style.display = (key.indexOf('-month-') !== -1) ? 'table-row' : 'block';
        if (icon) icon.innerHTML = '&#9660;';
        expandedSections[key] = true;
    } else {
        body.style.display = 'none';
        if (icon) icon.innerHTML = '&#9654;';
        expandedSections[key] = false;
    }
}

// ============================================================================
// DAY -> BATCHES drill-down
// ============================================================================

function toggleDayBatches(process, date) {
    var prefix = process === 'archive' ? 'arch' : 'shell';
    var key = prefix + '-batches-' + date;
    var header = document.getElementById(key + '-header');
    var body = document.getElementById(key + '-body');
    if (!header || !body) return;
    var icon = header.querySelector('.expand-icon');

    if (body.style.display === 'none' || body.style.display === '') {
        body.style.display = 'table-row';
        if (icon) icon.innerHTML = '&#9660;';
        expandedSections[key] = true;

        // Use cached batch list if we have it; otherwise fetch
        if (dayBatchCache[key]) {
            renderBatches(process, date, dayBatchCache[key]);
        } else {
            loadBatchesByDay(process, date);
        }
    } else {
        body.style.display = 'none';
        if (icon) icon.innerHTML = '&#9654;';
        expandedSections[key] = false;
    }
}

async function loadBatchesByDay(process, date) {
    var prefix = process === 'archive' ? 'arch' : 'shell';
    var key = prefix + '-batches-' + date;
    var contentEl = document.getElementById(key + '-content');
    if (!contentEl) return;

    contentEl.innerHTML = '<div class="loading">Loading batches&hellip;</div>';

    try {
        var url = '/api/dmops/' + process + '/batches-by-day?date=' + encodeURIComponent(date);
        var batches = await engineFetch(url);
        if (!batches) return; // hidden tab / session expired

        dayBatchCache[key] = batches;
        renderBatches(process, date, batches);
    } catch (error) {
        console.error('Failed to load batches for ' + date + ':', error);
        contentEl.innerHTML = '<div class="no-activity">Error loading batches: ' + escapeHtml(error.message) + '</div>';
    }
}

function renderBatches(process, date, batches) {
    var prefix = process === 'archive' ? 'arch' : 'shell';
    var key = prefix + '-batches-' + date;
    var contentEl = document.getElementById(key + '-content');
    if (!contentEl) return;

    if (!batches || batches.length === 0) {
        contentEl.innerHTML = '<div class="no-activity">No batch detail available</div>';
        return;
    }

    var isArchive = process === 'archive';
    var html = '<table class="batch-table"><thead>';

    // Two-line header pattern — first line groups context, second line is per-batch metrics
    html += '<tr>';
    html += '<th rowspan="2">#</th>';
    html += '<th rowspan="2">Started</th>';
    html += '<th rowspan="2">Mode</th>';
    html += '<th rowspan="2" class="right">Duration</th>';
    html += '<th rowspan="2">Status</th>';
    if (isArchive) html += '<th rowspan="2">BIDATA</th>';
    html += '<th colspan="' + (isArchive ? 4 : 2) + '" class="batch-counts-header">Counts</th>';
    html += '</tr>';
    html += '<tr>';
    html += '<th class="right">Consumers</th>';
    if (isArchive) html += '<th class="right">Accounts</th>';
    html += '<th class="right">Rows</th>';
    if (isArchive) html += '<th class="right">Exc</th>';
    html += '</tr></thead><tbody>';

    batches.forEach(function(b) {
        var rowClass = '';
        if (b.status === 'Failed') rowClass = ' row-failed';
        else if (isArchive && b.bidata_status === 'Failed') rowClass = ' row-warn';

        // Click on the batch row -> open slide-out
        html += '<tr class="batch-row' + rowClass + '" onclick="openBatchDetailPanel(\'' + process + '\',' + b.batch_id + ')" title="Click for full BatchDetail">';
        html += '<td class="batch-id">' + b.batch_id + (b.batch_retry ? ' <span class="retry-badge" title="Retry of batch ' + b.retry_batch_id + '">R</span>' : '') + '</td>';
        html += '<td>' + escapeHtml(formatTimeOnly(b.batch_start_dttm)) + '</td>';
        html += '<td>' + modeBadge(b.schedule_mode) + '</td>';
        html += '<td class="right">' + formatMs(b.duration_ms) + '</td>';
        html += '<td>' + statusBadge(b.status) + '</td>';
        if (isArchive) html += '<td>' + bidataBadge(b.bidata_status) + '</td>';
        html += '<td class="right">' + formatNumber(b.consumer_count) + '</td>';
        if (isArchive) html += '<td class="right">' + formatNumber(b.account_count) + '</td>';
        html += '<td class="right">' + formatNumber(b.total_rows_deleted) + '</td>';
        if (isArchive) {
            html += '<td class="right">' + ((b.exception_count > 0) ? '<span class="cell-warn">' + b.exception_count + '</span>' : '-') + '</td>';
        }
        html += '</tr>';
    });

    html += '</tbody></table>';
    contentEl.innerHTML = html;
}

// ============================================================================
// BATCH DETAIL SLIDE-OUT (full BatchDetail rows for a single batch)
// ============================================================================

async function openBatchDetailPanel(process, batchId) {
    document.getElementById('batch-detail-overlay').classList.add('active');
    document.getElementById('batch-detail-panel').classList.add('active');

    document.getElementById('batch-detail-title').textContent = 'Batch ' + batchId;
    var body = document.getElementById('batch-detail-body');
    body.innerHTML = '<div class="loading">Loading batch detail&hellip;</div>';

    try {
        var url = '/api/dmops/' + process + '/batch-detail/' + encodeURIComponent(batchId);
        var data = await engineFetch(url);
        if (!data) return;
        renderBatchDetailPanel(process, data);
    } catch (error) {
        body.innerHTML = '<div class="no-activity">Error loading batch detail: ' + escapeHtml(error.message) + '</div>';
    }
}

function closeBatchDetailPanel() {
    document.getElementById('batch-detail-overlay').classList.remove('active');
    document.getElementById('batch-detail-panel').classList.remove('active');
}

function renderBatchDetailPanel(process, data) {
    var s = data.Summary;
    var details = data.Details || [];
    var isArchive = process === 'archive';
    var body = document.getElementById('batch-detail-body');

    // ---- Header summary (two-line layout, mirroring the batch row + end time) ----
    var html = '<div class="batch-detail-header">';

    html += '<div class="batch-detail-line">';
    html += '<span class="bd-label">Started</span><span class="bd-value">' + escapeHtml(s.batch_start_dttm || '-') + '</span>';
    html += '<span class="bd-label">Ended</span><span class="bd-value">' + escapeHtml(s.batch_end_dttm || '-') + '</span>';
    html += '<span class="bd-label">Duration</span><span class="bd-value">' + formatMs(s.duration_ms) + '</span>';
    html += '<span class="bd-label">Mode</span><span class="bd-value">' + modeBadge(s.schedule_mode) + '</span>';
    html += '<span class="bd-label">Status</span><span class="bd-value">' + statusBadge(s.status) + '</span>';
    if (isArchive) {
        html += '<span class="bd-label">BIDATA</span><span class="bd-value">' + bidataBadge(s.bidata_status) + '</span>';
    }
    html += '</div>';

    html += '<div class="batch-detail-line">';
    html += '<span class="bd-label">Consumers</span><span class="bd-value">' + formatNumber(s.consumer_count) + '</span>';
    if (isArchive) {
        html += '<span class="bd-label">Accounts</span><span class="bd-value">' + formatNumber(s.account_count) + '</span>';
    }
    html += '<span class="bd-label">Rows</span><span class="bd-value">' + formatNumber(s.total_rows_deleted) + '</span>';
    if (isArchive) {
        html += '<span class="bd-label">Exceptions</span><span class="bd-value">' + formatNumber(s.exception_count || 0) + '</span>';
    }
    html += '<span class="bd-label">Tables (proc/skip/fail)</span><span class="bd-value">' +
        formatNumber(s.tables_processed) + ' / ' +
        formatNumber(s.tables_skipped) + ' / ' +
        formatNumber(s.tables_failed) + '</span>';
    html += '<span class="bd-label">Executed By</span><span class="bd-value">' + escapeHtml(s.executed_by || '-') + '</span>';
    html += '</div>';

    if (s.batch_retry) {
        html += '<div class="batch-detail-line"><span class="bd-label">Retry Of</span><span class="bd-value">' + s.retry_batch_id + '</span></div>';
    }
    if (s.error_message) {
        html += '<div class="batch-detail-error"><strong>Error:</strong> ' + escapeHtml(s.error_message) + '</div>';
    }

    html += '</div>'; // /.batch-detail-header

    // ---- Sortable BatchDetail table ----
    if (details.length === 0) {
        html += '<div class="no-activity">No detail rows recorded for this batch</div>';
    } else {
        html += '<table class="batch-detail-table" id="batch-detail-table"><thead><tr>';
        html += '<th data-col="delete_order" data-type="text" onclick="sortBatchDetail(this)">Order</th>';
        html += '<th data-col="table_name" data-type="text" onclick="sortBatchDetail(this)">Table</th>';
        html += '<th data-col="pass_description" data-type="text" onclick="sortBatchDetail(this)">Pass</th>';
        html += '<th data-col="rows_affected" data-type="num" onclick="sortBatchDetail(this)" class="right">Rows</th>';
        html += '<th data-col="duration_ms" data-type="num" onclick="sortBatchDetail(this)" class="right">Duration</th>';
        html += '<th data-col="status" data-type="text" onclick="sortBatchDetail(this)">Status</th>';
        html += '<th data-col="error_message" data-type="text">Error</th>';
        html += '</tr></thead><tbody>';

        details.forEach(function(d) {
            var rowClass = '';
            if (d.status && d.status.toLowerCase() === 'failed') rowClass = ' row-failed';
            html += '<tr class="' + rowClass + '">';
            html += '<td>' + deleteOrderHtml(d.delete_order) + '</td>';
            html += '<td>' + escapeHtml(d.table_name) + '</td>';
            html += '<td>' + escapeHtml(d.pass_description || '') + '</td>';
            html += '<td class="right">' + formatNumber(d.rows_affected) + '</td>';
            html += '<td class="right">' + formatMs(d.duration_ms) + '</td>';
            html += '<td>' + statusBadge(d.status) + '</td>';
            html += '<td class="bd-error-cell" title="' + escapeHtml(d.error_message || '') + '">' + escapeHtml(d.error_message || '') + '</td>';
            html += '</tr>';
        });

        html += '</tbody></table>';
    }

    body.innerHTML = html;
}

// Simple inline column sorter for the BatchDetail table
function sortBatchDetail(thEl) {
    var table = document.getElementById('batch-detail-table');
    if (!table) return;
    var col = thEl.getAttribute('data-col');
    var type = thEl.getAttribute('data-type');
    var headers = table.querySelectorAll('thead th');
    var index = -1;
    for (var i = 0; i < headers.length; i++) {
        if (headers[i].getAttribute('data-col') === col) { index = i; break; }
    }
    if (index < 0) return;

    var asc = !(thEl.getAttribute('data-sort') === 'asc');
    headers.forEach(function(h) { h.removeAttribute('data-sort'); h.classList.remove('sorted-asc', 'sorted-desc'); });
    thEl.setAttribute('data-sort', asc ? 'asc' : 'desc');
    thEl.classList.add(asc ? 'sorted-asc' : 'sorted-desc');

    var tbody = table.querySelector('tbody');
    var rows = Array.prototype.slice.call(tbody.querySelectorAll('tr'));
    rows.sort(function(a, b) {
        var av = a.cells[index].textContent.trim();
        var bv = b.cells[index].textContent.trim();
        if (type === 'num') {
            // Strip commas and unit suffixes for sorting
            var an = parseFloat(av.replace(/[^0-9.\-]/g, '')) || 0;
            var bn = parseFloat(bv.replace(/[^0-9.\-]/g, '')) || 0;
            return asc ? (an - bn) : (bn - an);
        }
        return asc ? av.localeCompare(bv) : bv.localeCompare(av);
    });
    rows.forEach(function(r) { tbody.appendChild(r); });
}

// ============================================================================
// SCHEDULE MODAL — Editable Grid with Three-State Drag (unchanged)
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

    html += '<div class="schedule-mode-selector">';
    html += '<label>Paint mode:</label>';
    html += '<button class="schedule-mode-btn active-full" id="mode-btn-1" onclick="setSchedulePaintMode(1)">Full</button>';
    html += '<button class="schedule-mode-btn" id="mode-btn-2" onclick="setSchedulePaintMode(2)">Reduced</button>';
    html += '<button class="schedule-mode-btn" id="mode-btn-0" onclick="setSchedulePaintMode(0)">Blocked</button>';
    html += '<span class="schedule-drag-hint">Click or drag to paint cells</span>';
    html += '</div>';

    html += '<div class="schedule-legend" style="margin-bottom:12px">';
    html += '<div class="schedule-legend-item"><div class="schedule-legend-box full"></div><span>Full</span></div>';
    html += '<div class="schedule-legend-item"><div class="schedule-legend-box reduced"></div><span>Reduced</span></div>';
    html += '<div class="schedule-legend-item"><div class="schedule-legend-box blocked"></div><span>Blocked</span></div>';
    html += '</div>';

    html += '<div class="schedule-grid" onmouseup="handleScheduleMouseUp()" onmouseleave="handleScheduleMouseLeave()">';

    html += '<div class="schedule-hour-labels"><div class="schedule-day-label"></div>';
    html += '<div class="schedule-hours">';
    for (var h = 0; h < 24; h++) {
        html += '<div class="schedule-hour-label">' + formatHour(h) + '</div>';
    }
    html += '</div></div>';

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

        for (var hh = 0; hh < 24; hh++) {
            var hourKey = 'Hr' + hh.toString().padStart(2, '0');
            var value = daySchedule[hourKey] !== undefined ? daySchedule[hourKey] : 0;
            var cellClass = getCellClass(value);

            html += '<div class="schedule-cell ' + cellClass + '" ' +
                'data-day="' + day + '" data-hour="' + hh + '" data-value="' + value + '" ' +
                'onmousedown="handleScheduleMouseDown(event, this)" ' +
                'onmouseover="handleScheduleMouseOver(this)" ' +
                'title="' + DAY_NAMES[day] + ' ' + formatHour(hh) + ' — ' + getCellLabel(value) + '">' +
                '</div>';
        }

        html += '</div></div>';
    }

    html += '</div></div>';
    body.innerHTML = html;
}

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
                Hour:      parseInt(cell.getAttribute('data-hour')),
                Value:     paintValue
            });
        }
        cell.classList.remove('drag-selected');
    });

    if (updates.length === 0) return;

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

    // Confirm only when SETTING the abort flag — clearing it requires no prompt.
    if (newState) {
        var confirmed = await showConfirm(
            'Set ' + label + ' abort flag? This will stop the process after the current batch completes.',
            {
                title: 'Confirm Abort',
                confirmLabel: 'Set Abort Flag',
                confirmClass: 'xf-modal-btn-danger'
            }
        );
        if (!confirmed) return;
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
        showAlert('Failed to update abort flag: ' + error.message, {
            title: 'Error',
            icon: '&#10005;',
            iconColor: '#f48771'
        });
    }
}

function updateAbortButtons() {
    var archAbort = document.getElementById('archive-abort-btn');
    var purgeAbort = document.getElementById('shellpurge-abort-btn');
    var archSchedule = document.getElementById('archive-schedule-btn');
    var purgeSchedule = document.getElementById('shellpurge-schedule-btn');

    if (window.isAdmin) {
        if (archAbort)     archAbort.style.display = '';
        if (purgeAbort)    purgeAbort.style.display = '';
        if (archSchedule)  archSchedule.style.display = '';
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
    loadTargetServers();
    startPolling();
    connectEngineEvents();
});

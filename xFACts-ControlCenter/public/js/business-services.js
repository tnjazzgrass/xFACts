/* ============================================================================
   xFACts Control Center - Business Services JavaScript
   Location: E:\xFACts-ControlCenter\public\js\business-services.js
   Version: Tracked in dbo.System_Metadata (component: DeptOps.BusinessServices)
   ============================================================================ */

// ============================================================================
// CONFIGURATION
// ============================================================================

// ENGINE_PROCESSES: maps orchestrator process names to card slugs.
// Countdown intervals provided by orchestrator via WebSocket -- no hardcoded values.
var ENGINE_PROCESSES = {
    'Collect-BSReviewRequests':    { slug: 'collect' },
    'Distribute-BSReviewRequests': { slug: 'distribute' }
};

// Live polling (Refresh Architecture)
var PAGE_REFRESH_INTERVAL = 60;   // Default; overridden by GlobalConfig on load

// Page hooks for engine-events.js shared module
function onPageResumed() { pageRefresh(); }
function onSessionExpired() { stopPolling(); }
var livePollingTimer = null;
var pageLoadDate = new Date().toDateString();

var monthNames = ['', 'January', 'February', 'March', 'April', 'May', 'June',
                  'July', 'August', 'September', 'October', 'November', 'December'];

// State
var selectedGroupFilter = '0'; // 0 = ALL
var historyGroupList = [];

// ============================================================================
// INITIALIZATION
// ============================================================================
document.addEventListener('DOMContentLoaded', function() {
    loadLiveActivity();
    loadDistribution();
    loadHistory();

    loadRefreshInterval();
    startAutoRefresh();
    startLivePolling();
    connectEngineEvents();
    initEngineCardClicks();
});

// ============================================================================
// REFRESH ARCHITECTURE
// ============================================================================

/**
 * Midnight rollover check -- reloads the page when the date changes.
 * Lightweight 60-second timer; all data refresh is handled by
 * live polling (Live Activity) and engine events (Distribution, History).
 */
function startAutoRefresh() {
    setInterval(function() {
        var today = new Date().toDateString();
        if (today !== pageLoadDate) {
            window.location.reload();
        }
    }, 60000);
}

/**
 * Called by engine-events.js when a relevant PROCESS_COMPLETED event arrives.
 * Refreshes all event-driven sections.
 */
function onEngineProcessCompleted(processName, event) {
    refreshEventSections();
}

/**
 * Refreshes all event-driven sections (Distribution + History).
 */
function refreshEventSections() {
    loadDistribution();
    loadHistory();
}

/**
 * Refreshes all live polling sections (Live Activity).
 */
function refreshLiveSections() {
    loadLiveActivity();
    updateTimestamp((new Date()).toLocaleTimeString());
}

/**
 * Refreshes all sections -- called by page refresh button.
 */
function refreshAll() {
    loadLiveActivity();
    loadDistribution();
    loadHistory();
    updateTimestamp((new Date()).toLocaleTimeString());
}

/**
 * Page-level refresh button handler with spinner animation.
 */
function pageRefresh() {
    var btn = document.querySelector('.page-refresh-btn');
    if (btn) {
        btn.classList.add('spinning');
        btn.addEventListener('animationend', function() {
            btn.classList.remove('spinning');
        }, { once: true });
    }
    refreshAll();
}

// ============================================================================
// LIVE POLLING (Refresh Architecture)
// ============================================================================

/**
 * Loads the page-specific refresh interval from GlobalConfig via shared API.
 */
async function loadRefreshInterval() {
    try {
        var data = await engineFetch('/api/config/refresh-interval?page=businessservices');
        if (data) {
            // engineFetch handles auth and returns parsed JSON
            PAGE_REFRESH_INTERVAL = data.interval || 60;
        }
    } catch (e) {
        // API unavailable -- use default
    }
}

/**
 * Starts the live polling timer for Live Activity section.
 */
function startLivePolling() {
    if (livePollingTimer) clearInterval(livePollingTimer);
    livePollingTimer = setInterval(function() {
        if (enginePageHidden || engineSessionExpired) return;
        refreshLiveSections();
    }, PAGE_REFRESH_INTERVAL * 1000);
}

function stopLivePolling() {
    if (livePollingTimer) {
        clearInterval(livePollingTimer);
        livePollingTimer = null;
    }
}

// ============================================================================
// LIVE ACTIVITY
// ============================================================================
function loadLiveActivity() {
    engineFetch('/api/business-services/live-activity')
        .then(function(data) {
            if (!data) return;
            clearConnectionError();
            renderLiveActivity(data.groups);
            updateTimestamp(data.timestamp);
        })
        .catch(function(err) {
            showConnectionError('Failed to load live activity: ' + err.message);
        });
}

function renderLiveActivity(groups) {
    var container = document.getElementById('live-activity-cards');
    var loading = document.getElementById('live-activity-loading');
    
    loading.classList.add('hidden');
    container.classList.remove('hidden');
    
    if (!groups || groups.length === 0) {
        container.innerHTML = '<div class="no-activity">No group data available</div>';
        return;
    }
    
    var html = '';
    
    groups.forEach(function(g) {
        var urgencyClass = '';
        if (g.unassigned > 50) urgencyClass = 'card-warning';
        if (g.unassigned > 200) urgencyClass = 'card-critical';
        
        html += '<div class="activity-card ' + urgencyClass + '">';
        html += '<div class="activity-card-title">' + escapeHtml(g.group_name) + ' (' + escapeHtml(g.group_short_name) + ')</div>';
        html += '<div class="activity-card-metrics-5">';
        html += '<div class="metric"><span class="metric-value">' + g.total_open + '</span><span class="metric-label">Open</span></div>';
        html += '<div class="metric"><span class="metric-value metric-assigned">' + g.assigned + '</span><span class="metric-label">Assigned</span></div>';
        html += '<div class="metric"><span class="metric-value metric-unassigned">' + g.unassigned + '</span><span class="metric-label">Unassigned</span></div>';
        html += '<div class="metric"><span class="metric-value metric-new">' + g.new_today + '</span><span class="metric-label">New Today</span></div>';
        html += '<div class="metric"><span class="metric-value metric-completed">' + g.closed_today + '</span><span class="metric-label">Closed Today</span></div>';
        html += '</div></div>';
    });
    
    container.innerHTML = html;
}

// ============================================================================
// DISTRIBUTION FLIP CARDS
// ============================================================================
function loadDistribution() {
    engineFetch('/api/business-services/distribution')
        .then(function(data) {
            if (!data) return;
            renderDistribution(data.groups);
        })
        .catch(function(err) {
            var container = document.getElementById('distribution-cards');
            container.innerHTML = '<div class="no-activity">Failed to load distribution data</div>';
            container.classList.remove('hidden');
            document.getElementById('distribution-loading').classList.add('hidden');
        });
}

function renderDistribution(groups) {
    var container = document.getElementById('distribution-cards');
    var loading = document.getElementById('distribution-loading');
    
    loading.classList.add('hidden');
    container.classList.remove('hidden');
    
    if (!groups || groups.length === 0) {
        container.innerHTML = '<div class="no-activity">No distribution groups configured</div>';
        return;
    }
    
    var html = '';
    
    groups.forEach(function(g) {
        // Calculate totals for the front of the card
        var totalAssigned = 0;
        var totalCap = 0;
        var totalCompletedToday = 0;
        
        g.users.forEach(function(u) {
            totalAssigned += u.currently_assigned;
            totalCap += u.assignment_cap;
            totalCompletedToday += u.completed_today;
        });
        
        var newToday = g.new_today || 0;
        var fillPct = totalCap > 0 ? Math.round((totalAssigned / totalCap) * 100) : 0;
        
        html += '<div class="flip-card" onclick="this.classList.toggle(\'flipped\')">';
        
        // Front
        html += '<div class="flip-card-front">';
        html += '<div class="flip-card-title">' + escapeHtml(g.group_short_name) + '</div>';
        html += '<div class="flip-card-subtitle">' + g.users.length + ' users</div>';
        html += '<div class="flip-card-big-number">' + totalAssigned + '<span class="flip-card-of">/ ' + totalCap + '</span></div>';
        html += '<div class="flip-card-progress"><div class="flip-card-progress-fill" style="width:' + Math.min(fillPct, 100) + '%"></div><span class="flip-card-progress-text">' + totalAssigned + ' / ' + totalCap + '</span></div>';
        html += '<div class="flip-card-footer-row">';
        html += '<span class="flip-footer-stat flip-new">' + newToday + ' new today</span>';
        html += '<span class="flip-footer-stat flip-completed">' + totalCompletedToday + ' completed today</span>';
        html += '</div>';
        html += '<div class="flip-card-hint">Click for user details</div>';
        html += '</div>';
        
        // Back
        html += '<div class="flip-card-back">';
        html += '<div class="flip-card-title">' + escapeHtml(g.group_short_name) + ' Users</div>';
        
        g.users.forEach(function(u) {
            var userPct = u.assignment_cap > 0 ? Math.round((u.currently_assigned / u.assignment_cap) * 100) : 0;
            var userClass = userPct >= 90 ? 'user-full' : (userPct >= 70 ? 'user-high' : '');
            
            html += '<div class="dist-user ' + userClass + '">';
            html += '<div class="dist-user-name">' + escapeHtml(u.display_name) + '</div>';
            html += '<div class="dist-user-stats">';
            html += '<span class="dist-stat">' + u.currently_assigned + ' / ' + u.assignment_cap + '</span>';
            html += '<span class="dist-completed">' + u.completed_today + ' today</span>';
            html += '</div>';
            html += '<div class="dist-user-bar"><div class="dist-user-bar-fill" style="width:' + Math.min(userPct, 100) + '%"></div></div>';
            html += '</div>';
        });
        
        html += '<div class="flip-card-hint">Click to flip back</div>';
        html += '</div>';
        
        html += '</div>';
    });
    
    container.innerHTML = html;
}

// ============================================================================
// HISTORY - Year/Month/Day drill-down
// ============================================================================
function loadHistory() {
    var url = '/api/business-services/history?group=' + selectedGroupFilter;
    
    engineFetch(url)
        .then(function(data) {
            if (!data) return;
            if (data.groups) {
                historyGroupList = data.groups;
                renderGroupBadges(data.groups);
            }
            renderHistory(data.years, data.total_count);
        })
        .catch(function(err) {
            var container = document.getElementById('history-tree');
            container.innerHTML = '<div class="no-activity">Failed to load history: ' + err.message + '</div>';
            container.classList.remove('hidden');
            document.getElementById('history-loading').classList.add('hidden');
        });
}

function renderGroupBadges(groups) {
    var container = document.getElementById('group-badges');
    
    var html = '<span class="group-badge ' + (selectedGroupFilter === '0' ? 'active' : '') + '" onclick="selectGroupFilter(\'0\')">All</span>';
    
    groups.forEach(function(g) {
        var gid = g.group_id.toString();
        var activeClass = (selectedGroupFilter === gid) ? 'active' : '';
        html += '<span class="group-badge ' + activeClass + '" onclick="selectGroupFilter(\'' + gid + '\')">' + escapeHtml(g.group_short_name) + '</span>';
    });
    
    container.innerHTML = html;
}

function selectGroupFilter(groupId) {
    selectedGroupFilter = groupId;
    loadHistory();
}

function renderHistory(years, totalCount) {
    var container = document.getElementById('history-tree');
    var loading = document.getElementById('history-loading');
    var countEl = document.getElementById('history-count');
    
    loading.classList.add('hidden');
    container.classList.remove('hidden');
    
    countEl.textContent = totalCount ? totalCount.toLocaleString() + ' requests' : '';
    
    if (!years || years.length === 0) {
        container.innerHTML = '<div class="no-activity">No history data available</div>';
        return;
    }
    
    var html = '<div class="history-tree">';
    
    years.forEach(function(yearData) {
        html += '<div class="history-year">';
        html += '<div class="year-header" onclick="toggleYear(this)">';
        html += '<span class="expand-icon">&#9654;</span>';
        html += '<span class="year-label">' + yearData.year + '</span>';
        html += '<div class="year-stats">';
        html += '<span class="year-stat">' + yearData.received.toLocaleString() + ' received</span>';
        html += '<span class="year-stat completed">' + yearData.completed.toLocaleString() + ' completed</span>';
        html += '</div>';
        html += '</div>';
        html += '<div class="year-content" style="display:none;">';
        html += '<table class="history-table"><thead><tr>';
        html += '<th></th><th>Month</th><th>Received</th><th>Completed</th>';
        html += '</tr></thead>';
        
        yearData.months.forEach(function(monthData) {
            html += '<tbody class="month-group">';
            html += '<tr class="month-row" onclick="toggleMonth(this, ' + yearData.year + ', ' + monthData.month + ')">';
            html += '<td class="expand-cell"><span class="expand-icon">&#9654;</span></td>';
            html += '<td class="month-cell">' + monthNames[monthData.month] + '</td>';
            html += '<td>' + monthData.received.toLocaleString() + '</td>';
            html += '<td class="completed-cell">' + monthData.completed.toLocaleString() + '</td>';
            html += '</tr>';
            html += '<tr class="month-details" style="display:none;"><td colspan="4">';
            html += '<div class="month-details-content" data-year="' + yearData.year + '" data-month="' + monthData.month + '">';
            html += '<div class="loading">Loading...</div></div></td></tr>';
            html += '</tbody>';
        });
        
        html += '</table></div></div>';
    });
    
    html += '</div>';
    container.innerHTML = html;
}

function toggleYear(el) {
    var content = el.nextElementSibling;
    var icon = el.querySelector('.expand-icon');
    if (content.style.display === 'none') {
        content.style.display = 'block';
        icon.innerHTML = '&#9660;';
    } else {
        content.style.display = 'none';
        icon.innerHTML = '&#9654;';
    }
}

function toggleMonth(el, year, month) {
    var tbody = el.closest('tbody');
    var detailRow = tbody.querySelector('.month-details');
    var icon = el.querySelector('.expand-icon');
    var contentDiv = tbody.querySelector('.month-details-content');
    
    if (detailRow.style.display === 'none') {
        detailRow.style.display = '';
        icon.innerHTML = '&#9660;';
        
        // Load day-level data if not already loaded
        if (contentDiv.querySelector('.loading')) {
            loadMonthDays(contentDiv, year, month);
        }
    } else {
        detailRow.style.display = 'none';
        icon.innerHTML = '&#9654;';
    }
}

function loadMonthDays(container, year, month) {
    var url = '/api/business-services/history-month?year=' + year + '&month=' + month + '&group=' + selectedGroupFilter;
    
    engineFetch(url)
        .then(function(data) {
            if (!data) return;
            renderMonthDays(container, data.days);
        })
        .catch(function(err) {
            container.innerHTML = '<div class="no-activity">Error loading month data</div>';
        });
}

function renderMonthDays(container, days) {
    if (!days || days.length === 0) {
        container.innerHTML = '<div class="no-activity">No activity this month</div>';
        return;
    }
    
    var html = '<table class="history-table day-table"><thead><tr>';
    html += '<th>Day</th><th>Date</th><th>Received</th><th>Completed</th>';
    html += '</tr></thead><tbody>';
    
    days.forEach(function(d, idx) {
        html += '<tr class="day-row ' + (idx % 2 === 0 ? '' : 'row-odd') + '" onclick="loadDayDetail(\'' + d.date + '\')">';
        html += '<td>' + d.day_of_week + '</td>';
        var dateParts = d.date.split('-');
        html += '<td>' + dateParts[1] + '/' + dateParts[2] + '</td>';
        html += '<td>' + d.received + '</td>';
        html += '<td class="completed-cell">' + d.completed + '</td>';
        html += '</tr>';
    });
    
    html += '</tbody></table>';
    container.innerHTML = html;
}

// ============================================================================
// DAY DETAIL SLIDEOUT
// ============================================================================
function loadDayDetail(date) {
    openSlideout('Completions: ' + formatDisplayDate(date));
    
    var url = '/api/business-services/history-day?date=' + date + '&group=' + selectedGroupFilter;
    
    engineFetch(url)
        .then(function(data) {
            if (!data) return;
            renderDayDetail(data);
        })
        .catch(function(err) {
            document.getElementById('slideout-body').innerHTML = '<div class="no-activity">Error loading day details</div>';
        });
}

function renderDayDetail(data) {
    var body = document.getElementById('slideout-body');
    var html = '';
    
    // Group summary cards
    if (data.groups && data.groups.length > 0) {
        html += '<div class="slideout-section-title">Group Summary</div>';
        html += '<div class="slideout-group-cards">';
        data.groups.forEach(function(g) {
            // Only show groups that had activity
            if (g.completed === 0 && g.received === 0) return;
            html += '<div class="slideout-group-card">';
            html += '<div class="slideout-group-name">' + escapeHtml(g.group_short_name) + '</div>';
            html += '<div class="slideout-group-metrics">';
            html += '<span class="sg-metric sg-completed">' + g.completed + ' completed</span>';
            html += '<span class="sg-metric sg-received">' + g.received + ' received</span>';
            html += '</div></div>';
        });
        html += '</div>';
    }
    
    // User breakdown - completions
    if (data.users && data.users.length > 0) {
        html += '<div class="slideout-section-title">Completions by User</div>';
        html += '<table class="slideout-table"><thead><tr>';
        html += '<th>Group</th><th>User</th><th>Completed</th>';
        html += '</tr></thead><tbody>';
        
        data.users.forEach(function(u) {
            html += '<tr class="user-detail-row" onclick="loadUserDayRequests(\'' + data.date + '\', \'' + escapeJs(u.username) + '\')">';
            html += '<td>' + escapeHtml(u.group_short_name) + '</td>';
            html += '<td>' + escapeHtml(u.username) + '</td>';
            html += '<td class="completed-cell">' + u.completed + '</td>';
            html += '</tr>';
        });
        
        html += '</tbody></table>';
    } else {
        html += '<div class="no-activity">No completions on this day</div>';
    }
    
    body.innerHTML = html;
}

// ============================================================================
// USER DAY REQUESTS (within slideout)
// ============================================================================
function loadUserDayRequests(date, username) {
    var displayName = username === '(Unknown)' ? 'Unknown User' : username;
    document.getElementById('slideout-title').textContent = displayName + ' - ' + formatDisplayDate(date);
    document.getElementById('slideout-body').innerHTML = '<div class="loading">Loading requests...</div>';
    
    var url = '/api/business-services/history-user-day?date=' + date + '&username=' + encodeURIComponent(username) + '&group=' + selectedGroupFilter;
    
    engineFetch(url)
        .then(function(data) {
            if (!data) return;
            renderUserDayRequests(data);
        })
        .catch(function(err) {
            document.getElementById('slideout-body').innerHTML = '<div class="no-activity">Error loading requests</div>';
        });
}

function renderUserDayRequests(data) {
    var body = document.getElementById('slideout-body');
    
    if (!data.requests || data.requests.length === 0) {
        body.innerHTML = '<div class="no-activity">No requests found</div>';
        return;
    }
    
    var html = '<div class="slideout-count">' + data.count + ' request(s) completed</div>';
    html += '<table class="slideout-table requests-table"><thead><tr>';
    html += '<th>Consumer #</th><th>Consumer Name</th><th>Workgroup</th><th>Group</th><th>Completed</th><th></th>';
    html += '</tr></thead><tbody>';
    
    data.requests.forEach(function(r) {
        var commentBtn = r.has_comment ? '<button class="btn btn-xs btn-comment" onclick="event.stopPropagation(); openRequestDetail(' + r.tracking_id + ')" title="View comment">&#128172;</button>' : '';
        
        html += '<tr>';
        html += '<td class="mono">' + escapeHtml(r.consumer_number || '') + '</td>';
        html += '<td>' + escapeHtml(r.consumer_name || '') + '</td>';
        html += '<td>' + escapeHtml(r.workgroup || '') + '</td>';
        html += '<td>' + escapeHtml(r.group_short_name || '') + '</td>';
        html += '<td class="completed-cell">' + escapeHtml(r.completion_date || '') + '</td>';
        html += '<td>' + commentBtn + '</td>';
        html += '</tr>';
    });
    
    html += '</tbody></table>';
    
    // Back button
    html += '<button class="btn btn-sm btn-back" onclick="loadDayDetail(\'' + data.date + '\')">&#8592; Back to day summary</button>';
    
    body.innerHTML = html;
}

// ============================================================================
// REQUEST DETAIL MODAL
// ============================================================================
function openRequestDetail(trackingId) {
    document.getElementById('detail-modal').classList.remove('hidden');
    document.getElementById('detail-modal-body').innerHTML = '<div class="loading">Loading...</div>';
    
    engineFetch('/api/business-services/request-detail?id=' + trackingId)
        .then(function(data) {
            if (!data) return;
            renderRequestDetail(data);
        })
        .catch(function(err) {
            document.getElementById('detail-modal-body').innerHTML = '<div class="no-activity">Error loading detail</div>';
        });
}

function renderRequestDetail(data) {
    var body = document.getElementById('detail-modal-body');
    document.getElementById('detail-modal-title').textContent = 'Request #' + data.dm_request_id;
    
    var html = '<div class="detail-grid">';
    html += detailRow('Consumer', (data.consumer_number || '') + ' - ' + (data.consumer_name || ''));
    html += detailRow('Workgroup', data.workgroup || '-');
    html += detailRow('Group', data.group_name || '-');
    html += detailRow('Requested By', data.requesting_user || '-');
    html += detailRow('Request Date', data.request_date || '-');
    html += detailRow('Assigned To', data.assigned_user || '-');
    html += detailRow('Status', data.is_completed ? 'Completed' : 'Open');
    
    if (data.is_completed) {
        html += detailRow('Completed By', data.completed_user || '-');
        html += detailRow('Completion Date', data.completion_date || '-');
    }
    html += '</div>';
    
    // Comment section
    html += '<div class="detail-comment-section">';
    html += '<div class="detail-comment-label">Comment</div>';
    if (data.comment) {
        html += '<div class="detail-comment-text">' + escapeHtml(data.comment) + '</div>';
    } else {
        html += '<div class="detail-comment-empty">No comment</div>';
    }
    html += '</div>';
    
    body.innerHTML = html;
}

function detailRow(label, value) {
    return '<div class="detail-field"><span class="detail-label">' + label + '</span><span class="detail-value">' + escapeHtml(value) + '</span></div>';
}

function closeDetailModal() {
    document.getElementById('detail-modal').classList.add('hidden');
}

// ============================================================================
// SLIDEOUT PANEL
// ============================================================================
function openSlideout(title) {
    document.getElementById('slideout-title').textContent = title;
    document.getElementById('slideout-body').innerHTML = '<div class="loading">Loading...</div>';
    document.getElementById('slideout').classList.add('open');
    document.getElementById('slideout-backdrop').classList.add('visible');
}

function closeSlideout() {
    document.getElementById('slideout').classList.remove('open');
    document.getElementById('slideout-backdrop').classList.remove('visible');
}

// ============================================================================
// UI HELPERS
// ============================================================================
function updateTimestamp(ts) {
    var el = document.getElementById('last-update');
    if (el && ts) {
        var parts = ts.split(' ');
        el.textContent = parts.length > 1 ? parts[1] : ts;
    }
}

function showConnectionError(msg) {
    var el = document.getElementById('connection-error');
    el.textContent = msg;
    el.classList.add('visible');
}

function clearConnectionError() {
    document.getElementById('connection-error').classList.remove('visible');
}

function formatDisplayDate(dateStr) {
    if (!dateStr) return '';
    var parts = dateStr.split('-');
    if (parts.length === 3) return parts[1] + '/' + parts[2] + '/' + parts[0];
    return dateStr;
}

function escapeHtml(str) {
    if (!str) return '';
    return str.toString()
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#039;');
}

function escapeJs(str) {
    if (!str) return '';
    return str.toString()
        .replace(/\\/g, '\\\\')
        .replace(/'/g, "\\'")
        .replace(/"/g, '\\"');
}

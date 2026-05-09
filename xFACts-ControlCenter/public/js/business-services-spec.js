/* ============================================================================
   xFACts Control Center - Business Services JavaScript (business-services.js)
   Location: E:\xFACts-ControlCenter\public\js\business-services.js
   Version: Tracked in dbo.System_Metadata (component: DeptOps.BusinessServices)

   Page-specific JS for the Business Services departmental page. Universal
   chrome (WebSocket events, connection banner, page refresh button, idle
   detection, session expiry, shared modals, formatting utilities) is
   provided by cc-shared.js. This file contains the data loading and
   rendering logic for the live activity cards, the distribution flip
   cards, the year/month/day history drill-down, the day-detail slideout
   with per-user request lists, and the request detail modal.

   FILE ORGANIZATION
   -----------------
   CONSTANTS: ENGINE PROCESSES
   CONSTANTS: PAGE CONFIGURATION
   STATE: PAGE STATE
   INITIALIZATION: PAGE BOOT
   FUNCTIONS: LIVE POLLING
   FUNCTIONS: LIVE ACTIVITY
   FUNCTIONS: DISTRIBUTION
   FUNCTIONS: HISTORY TREE
   FUNCTIONS: DAY DETAIL
   FUNCTIONS: REQUEST DETAIL MODAL
   FUNCTIONS: SLIDEOUT PANEL
   FUNCTIONS: UTILITIES
   FUNCTIONS: PAGE LIFECYCLE HOOKS
   ============================================================================ */


/* ============================================================================
   CONSTANTS: ENGINE PROCESSES
   ----------------------------------------------------------------------------
   The ENGINE_PROCESSES contract: a map from orchestrator process names to
   engine card slugs that cc-shared.js reads at startup to wire up the
   engine indicator subsystem. The Business Services page has two
   collectors driving its event-driven sections (Distribution and
   History): Collect-BSReviewRequests harvests new request data, and
   Distribute-BSReviewRequests assigns fresh requests to users.
   Prefix: (none)
   ============================================================================ */

/* Maps orchestrator process names to engine card slugs. cc-shared.js
   reads this at startup; each entry binds a process to a card on the
   page. Card refreshes for the bound process happen automatically via
   onEngineProcessCompleted. */
const ENGINE_PROCESSES = {
    'Collect-BSReviewRequests':    { slug: 'collect' },
    'Distribute-BSReviewRequests': { slug: 'distribute' }
};


/* ============================================================================
   CONSTANTS: PAGE CONFIGURATION
   ----------------------------------------------------------------------------
   Module-level configuration constants for this page. The refresh
   interval default is overwritten at load time from GlobalConfig.
   Prefix: bsv
   ============================================================================ */

/* Default live-polling interval in seconds. Overwritten at page load by
   bsv_loadRefreshInterval from GlobalConfig (ControlCenter |
   refresh_businessservices_seconds). 60 seconds keeps the live activity
   counts reasonably fresh without burning fetches. */
const bsv_PAGE_REFRESH_INTERVAL_DEFAULT = 60;


/* ============================================================================
   STATE: PAGE STATE
   ----------------------------------------------------------------------------
   Module-scope mutable state for the Business Services UI: the
   live-poll and auto-refresh timer handles, page-load date for midnight
   rollover detection, the active group filter for the history tree, and
   the cached list of distribution groups used to render the badge row.
   Prefix: bsv
   ============================================================================ */

/* Effective live-polling interval in seconds. Starts at the default and
   is overwritten by bsv_loadRefreshInterval if GlobalConfig has a value. */
var bsv_pageRefreshInterval = bsv_PAGE_REFRESH_INTERVAL_DEFAULT;

/* setInterval handle for the live-polling timer, or null when not
   running. */
var bsv_livePollingTimer = null;

/* setInterval handle for the midnight-rollover check. */
var bsv_autoRefreshTimer = null;

/* Date string captured at page load. Compared against the current date
   inside the auto-refresh timer to trigger a full reload at midnight. */
var bsv_pageLoadDate = new Date().toDateString();

/* Active group filter for the history tree. '0' means "All Groups";
   any other value is a specific group_id rendered as a string. */
var bsv_selectedGroupFilter = '0';

/* Cached list of distribution groups from the most recent loadHistory
   response. Backs the rendered badge row above the history tree. */
var bsv_historyGroupList = [];


/* ============================================================================
   INITIALIZATION: PAGE BOOT
   ----------------------------------------------------------------------------
   Single DOMContentLoaded handler that does the page's first data load
   for all three sections, reads the refresh interval from GlobalConfig,
   starts the auto-refresh and live-polling timers, and registers the
   engine-events chrome with cc-shared.js.
   Prefix: (none)
   ============================================================================ */

document.addEventListener('DOMContentLoaded', function() {
    bsv_loadLiveActivity();
    bsv_loadDistribution();
    bsv_loadHistory();

    bsv_loadRefreshInterval();
    bsv_startAutoRefresh();
    bsv_startLivePolling();
    connectEngineEvents();
    initEngineCardClicks();

    document.getElementById('distribution-cards').addEventListener('click', bsv_onDistributionClick);
    document.getElementById('group-badges').addEventListener('click', bsv_onGroupBadgesClick);
    document.getElementById('history-tree').addEventListener('click', bsv_onHistoryTreeClick);
    document.getElementById('slideout-body').addEventListener('click', bsv_onSlideoutBodyClick);
});


/* ============================================================================
   FUNCTIONS: LIVE POLLING
   ----------------------------------------------------------------------------
   The page's refresh loop. Live polling reloads the live-activity
   section at the configured interval; the auto-refresh timer reloads
   the entire page at midnight. The refresh-all and refresh-event paths
   are split because Distribution and History are event-driven (refreshed
   when an engine process completes) while Live Activity is interval-
   driven.
   Prefix: bsv
   ============================================================================ */

/* Loads the page-specific refresh interval from GlobalConfig via the
   shared refresh-interval API. Falls back to the default constant if
   the API is unavailable. */
async function bsv_loadRefreshInterval() {
    try {
        var data = await engineFetch('/api/config/refresh-interval?page=businessservices');
        if (data) {
            bsv_pageRefreshInterval = data.interval || bsv_PAGE_REFRESH_INTERVAL_DEFAULT;
        }
    } catch (e) {
        /* API unavailable - default already in effect. */
    }
}

/* Starts the midnight-rollover check. Lightweight 60-second timer that
   reloads the page when the date changes - cheaper than rebuilding the
   queue UI from a cross-day query result set. */
function bsv_startAutoRefresh() {
    bsv_autoRefreshTimer = setInterval(function() {
        var today = new Date().toDateString();
        if (today !== bsv_pageLoadDate) {
            window.location.reload();
        }
    }, 60000);
}

/* Starts the live-polling timer for the live-activity section. Skips
   when the tab is hidden or the session is expired so we don't burn
   fetches that engineFetch would short-circuit anyway. */
function bsv_startLivePolling() {
    if (bsv_livePollingTimer) clearInterval(bsv_livePollingTimer);
    bsv_livePollingTimer = setInterval(function() {
        if (enginePageHidden || engineSessionExpired) return;
        bsv_refreshLiveSections();
    }, bsv_pageRefreshInterval * 1000);
}

/* Stops live polling. Called by the onSessionExpired hook when
   cc-shared.js detects the session has expired so we don't keep
   firing fetches that will be short-circuited. */
function bsv_stopLivePolling() {
    if (bsv_livePollingTimer) {
        clearInterval(bsv_livePollingTimer);
        bsv_livePollingTimer = null;
    }
}

/* Refreshes only the live-activity section. Called by the live-polling
   timer; updates the page timestamp once data lands. */
function bsv_refreshLiveSections() {
    bsv_loadLiveActivity();
    bsv_updateTimestamp((new Date()).toLocaleTimeString());
}

/* Refreshes the event-driven sections (Distribution and History).
   Called by the onEngineProcessCompleted hook when a relevant
   orchestrator process finishes. */
function bsv_refreshEventSections() {
    bsv_loadDistribution();
    bsv_loadHistory();
}

/* Refreshes everything on the page. Called by the manual refresh
   button (via the onPageRefresh hook) and by the onPageResumed hook on
   tab resume. */
function bsv_refreshAll() {
    bsv_loadLiveActivity();
    bsv_loadDistribution();
    bsv_loadHistory();
    bsv_updateTimestamp((new Date()).toLocaleTimeString());
}


/* ============================================================================
   FUNCTIONS: LIVE ACTIVITY
   ----------------------------------------------------------------------------
   The top-of-page live activity cards: one card per work group, showing
   real-time counts of open, assigned, unassigned, new-today, and
   closed-today requests. Threshold-based urgency colors highlight
   groups with high unassigned counts.
   Prefix: bsv
   ============================================================================ */

/* Loads live activity data and re-renders the cards. Updates the page
   timestamp and clears the connection error banner on success. */
function bsv_loadLiveActivity() {
    engineFetch('/api/business-services/live-activity')
        .then(function(data) {
            if (!data) return;
            bsv_clearConnectionError();
            bsv_renderLiveActivity(data.groups);
            bsv_updateTimestamp(data.timestamp);
        })
        .catch(function(err) {
            bsv_showConnectionError('Failed to load live activity: ' + err.message);
        });
}

/* Renders the live activity cards: one per group, showing the five
   real-time counts. Urgency class is derived from the unassigned count
   and applied to the card root. */
function bsv_renderLiveActivity(groups) {
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


/* ============================================================================
   FUNCTIONS: DISTRIBUTION
   ----------------------------------------------------------------------------
   The Distribution flip cards: one per group, showing the front face
   with aggregate assignment metrics and the back face with per-user
   detail. Click anywhere on a card to flip; the back face shows each
   user's currently-assigned count, cap, and completed-today count.
   Prefix: bsv
   ============================================================================ */

/* Loads the distribution data and re-renders the flip cards. */
function bsv_loadDistribution() {
    engineFetch('/api/business-services/distribution')
        .then(function(data) {
            if (!data) return;
            bsv_renderDistribution(data.groups);
        })
        .catch(function(err) {
            var container = document.getElementById('distribution-cards');
            container.innerHTML = '<div class="no-activity">Failed to load distribution data</div>';
            container.classList.remove('hidden');
            document.getElementById('distribution-loading').classList.add('hidden');
        });
}

/* Renders the per-group distribution flip cards. Each card has a front
   face (group totals: assigned-of-cap, fill percentage, new today,
   completed today) and a back face (user list with per-user assignment
   counts and progress bars). Clicking the card toggles between faces. */
function bsv_renderDistribution(groups) {
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
        /* Calculate totals for the front of the card. */
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

        html += '<div class="flip-card">';

        /* Front face. */
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

        /* Back face. */
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

/* Delegated click handler for the distribution flip cards. Toggles the
   'flipped' state on the .flip-card element nearest the click. */
function bsv_onDistributionClick(event) {
    var card = event.target.closest('.flip-card');
    if (!card) return;
    card.classList.toggle('flipped');
}


/* ============================================================================
   FUNCTIONS: HISTORY TREE
   ----------------------------------------------------------------------------
   The Year/Month/Day drill-down view of historical request volume.
   Loads aggregate yearly counts on first render; expanding a year
   shows per-month rows; expanding a month lazy-loads per-day rows from
   a separate endpoint. The group filter badges above the tree scope
   every level of the drill-down.
   Prefix: bsv
   ============================================================================ */

/* Loads the history tree data scoped to the active group filter. The
   response carries the available group list (used to render the filter
   badges) and the pre-aggregated year/month rows. */
function bsv_loadHistory() {
    var url = '/api/business-services/history?group=' + bsv_selectedGroupFilter;

    engineFetch(url)
        .then(function(data) {
            if (!data) return;
            if (data.groups) {
                bsv_historyGroupList = data.groups;
                bsv_renderGroupBadges(data.groups);
            }
            bsv_renderHistory(data.years, data.total_count);
        })
        .catch(function(err) {
            var container = document.getElementById('history-tree');
            container.innerHTML = '<div class="no-activity">Failed to load history: ' + err.message + '</div>';
            container.classList.remove('hidden');
            document.getElementById('history-loading').classList.add('hidden');
        });
}

/* Renders the group filter badges above the history tree. The 'All'
   badge is always present; one badge per known group. Clicking a badge
   sets the active filter and reloads the history. */
function bsv_renderGroupBadges(groups) {
    var container = document.getElementById('group-badges');

    var html = '<span class="group-badge ' + (bsv_selectedGroupFilter === '0' ? 'active' : '') + '" data-group-id="0">All</span>';

    groups.forEach(function(g) {
        var gid = g.group_id.toString();
        var activeClass = (bsv_selectedGroupFilter === gid) ? 'active' : '';
        html += '<span class="group-badge ' + activeClass + '" data-group-id="' + gid + '">' + escapeHtml(g.group_short_name) + '</span>';
    });

    container.innerHTML = html;
}

/* Sets the active group filter and reloads the history tree. Called
   from the delegated click handler on the group badges container. */
function bsv_selectGroupFilter(groupId) {
    bsv_selectedGroupFilter = groupId;
    bsv_loadHistory();
}

/* Renders the year/month rows in the history tree. Years are
   collapsible; each year's months render as table rows that expand to
   show day-level detail when clicked. */
function bsv_renderHistory(years, totalCount) {
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
        html += '<div class="year-header">';
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
            html += '<tr class="month-row" data-year="' + yearData.year + '" data-month="' + monthData.month + '">';
            html += '<td class="expand-cell"><span class="expand-icon">&#9654;</span></td>';
            html += '<td class="month-cell">' + MONTH_NAMES[monthData.month] + '</td>';
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

/* Toggles the expanded state of a year row in the history tree.
   Called from the delegated click handler on the history tree. */
function bsv_toggleYear(el) {
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

/* Toggles the expanded state of a month row. On first expansion,
   lazy-loads the per-day data for that month. Subsequent toggles use
   the already-rendered content. */
function bsv_toggleMonth(el, year, month) {
    var tbody = el.closest('tbody');
    var detailRow = tbody.querySelector('.month-details');
    var icon = el.querySelector('.expand-icon');
    var contentDiv = tbody.querySelector('.month-details-content');

    if (detailRow.style.display === 'none') {
        detailRow.style.display = '';
        icon.innerHTML = '&#9660;';

        /* Load day-level data if not already loaded. */
        if (contentDiv.querySelector('.loading')) {
            bsv_loadMonthDays(contentDiv, year, month);
        }
    } else {
        detailRow.style.display = 'none';
        icon.innerHTML = '&#9654;';
    }
}

/* Fetches the per-day data for a single month and hands the result to
   the renderer. Used for the lazy-load branch of bsv_toggleMonth. */
function bsv_loadMonthDays(container, year, month) {
    var url = '/api/business-services/history-month?year=' + year + '&month=' + month + '&group=' + bsv_selectedGroupFilter;

    engineFetch(url)
        .then(function(data) {
            if (!data) return;
            bsv_renderMonthDays(container, data.days);
        })
        .catch(function(err) {
            container.innerHTML = '<div class="no-activity">Error loading month data</div>';
        });
}

/* Renders the per-day rows for a single month inside the month's
   expanded detail row. Each day is clickable and opens the day-detail
   slideout. */
function bsv_renderMonthDays(container, days) {
    if (!days || days.length === 0) {
        container.innerHTML = '<div class="no-activity">No activity this month</div>';
        return;
    }

    var html = '<table class="history-table day-table"><thead><tr>';
    html += '<th>Day</th><th>Date</th><th>Received</th><th>Completed</th>';
    html += '</tr></thead><tbody>';

    days.forEach(function(d, idx) {
        html += '<tr class="day-row ' + (idx % 2 === 0 ? '' : 'row-odd') + '" data-date="' + d.date + '">';
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

/* Delegated click handler for the group filter badges. Reads the
   data-group-id from the clicked badge and applies the filter. */
function bsv_onGroupBadgesClick(event) {
    var badge = event.target.closest('.group-badge');
    if (!badge) return;
    bsv_selectGroupFilter(badge.dataset.groupId);
}

/* Delegated click handler for the history tree. Routes to the
   appropriate toggle or load action based on which row class was
   clicked: year header (toggle expand), month row (toggle expand and
   lazy-load days), or day row (open the day-detail slideout). */
function bsv_onHistoryTreeClick(event) {
    var yearHeader = event.target.closest('.year-header');
    if (yearHeader) {
        bsv_toggleYear(yearHeader);
        return;
    }
    var monthRow = event.target.closest('.month-row');
    if (monthRow) {
        bsv_toggleMonth(monthRow, parseInt(monthRow.dataset.year, 10), parseInt(monthRow.dataset.month, 10));
        return;
    }
    var dayRow = event.target.closest('.day-row');
    if (dayRow) {
        bsv_loadDayDetail(dayRow.dataset.date);
    }
}


/* ============================================================================
   FUNCTIONS: DAY DETAIL
   ----------------------------------------------------------------------------
   The day-detail slideout panel and its drill-down to per-user request
   lists. Opening a day detail shows group-level summary cards plus the
   per-user completion table; clicking a user row swaps the slideout
   content to show that user's individual completed requests for the
   day, with a back-link to return to the day summary.
   Prefix: bsv
   ============================================================================ */

/* Loads the day-detail data and renders it into the slideout. Opens
   the slideout with a loading state, then fills it with the response. */
function bsv_loadDayDetail(date) {
    bsv_openSlideout('Completions: ' + bsv_formatDisplayDate(date));

    var url = '/api/business-services/history-day?date=' + date + '&group=' + bsv_selectedGroupFilter;

    engineFetch(url)
        .then(function(data) {
            if (!data) return;
            bsv_renderDayDetail(data);
        })
        .catch(function(err) {
            document.getElementById('slideout-body').innerHTML = '<div class="no-activity">Error loading day details</div>';
        });
}

/* Renders the day-summary view inside the slideout: group cards (one
   per group with activity that day) and a per-user completion table
   (rows clickable to drill into that user's individual requests). */
function bsv_renderDayDetail(data) {
    var body = document.getElementById('slideout-body');
    var html = '';

    /* Group summary cards. */
    if (data.groups && data.groups.length > 0) {
        html += '<div class="slideout-section-title">Group Summary</div>';
        html += '<div class="slideout-group-cards">';
        data.groups.forEach(function(g) {
            /* Only show groups that had activity. */
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

    /* User breakdown - completions. */
    if (data.users && data.users.length > 0) {
        html += '<div class="slideout-section-title">Completions by User</div>';
        html += '<table class="slideout-table"><thead><tr>';
        html += '<th>Group</th><th>User</th><th>Completed</th>';
        html += '</tr></thead><tbody>';

        data.users.forEach(function(u) {
            html += '<tr class="user-detail-row" data-date="' + escapeHtml(data.date) + '" data-username="' + escapeHtml(u.username) + '">';
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

/* Loads a single user's completed requests for a single day and
   renders them in the slideout, replacing the day-summary view. */
function bsv_loadUserDayRequests(date, username) {
    var displayName = username === '(Unknown)' ? 'Unknown User' : username;
    document.getElementById('slideout-title').textContent = displayName + ' - ' + bsv_formatDisplayDate(date);
    document.getElementById('slideout-body').innerHTML = '<div class="loading">Loading requests...</div>';

    var url = '/api/business-services/history-user-day?date=' + date + '&username=' + encodeURIComponent(username) + '&group=' + bsv_selectedGroupFilter;

    engineFetch(url)
        .then(function(data) {
            if (!data) return;
            bsv_renderUserDayRequests(data);
        })
        .catch(function(err) {
            document.getElementById('slideout-body').innerHTML = '<div class="no-activity">Error loading requests</div>';
        });
}

/* Renders the per-user request table in the slideout. Each row carries
   a comment indicator (clickable to open the request detail modal)
   and a back-link returns to the day-summary view. */
function bsv_renderUserDayRequests(data) {
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
        var commentBtn = r.has_comment ? '<button class="btn btn-xs btn-comment" data-tracking-id="' + r.tracking_id + '" title="View comment">&#128172;</button>' : '';

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

    /* Back button. */
    html += '<button class="btn btn-sm btn-back" data-date="' + escapeHtml(data.date) + '">&#8592; Back to day summary</button>';

    body.innerHTML = html;
}

/* Delegated click handler for the slideout body. Routes to the
   appropriate action based on which row or button was clicked: the
   comment button (open request detail modal), the back button (return
   to day summary), or a user-detail row (drill into per-user
   requests). The button checks come first so a button click inside a
   row doesn't also fire the row's drill-down. */
function bsv_onSlideoutBodyClick(event) {
    var commentBtn = event.target.closest('.btn-comment');
    if (commentBtn) {
        bsv_openRequestDetail(parseInt(commentBtn.dataset.trackingId, 10));
        return;
    }
    var backBtn = event.target.closest('.btn-back');
    if (backBtn) {
        bsv_loadDayDetail(backBtn.dataset.date);
        return;
    }
    var userRow = event.target.closest('.user-detail-row');
    if (userRow) {
        bsv_loadUserDayRequests(userRow.dataset.date, userRow.dataset.username);
    }
}


/* ============================================================================
   FUNCTIONS: REQUEST DETAIL MODAL
   ----------------------------------------------------------------------------
   The request detail modal: a separate overlay (independent from the
   slideout) that shows the full record for a single tracking_id,
   including the comment text. Opened from the comment-icon button on
   user-day request rows.
   Prefix: bsv
   ============================================================================ */

/* Opens the request detail modal and fetches the record by tracking_id.
   Populates the modal body with the rendered detail or an error
   message. */
function bsv_openRequestDetail(trackingId) {
    document.getElementById('detail-modal').classList.remove('hidden');
    document.getElementById('detail-modal-body').innerHTML = '<div class="loading">Loading...</div>';

    engineFetch('/api/business-services/request-detail?id=' + trackingId)
        .then(function(data) {
            if (!data) return;
            bsv_renderRequestDetail(data);
        })
        .catch(function(err) {
            document.getElementById('detail-modal-body').innerHTML = '<div class="no-activity">Error loading detail</div>';
        });
}

/* Renders the full request detail inside the modal: a label/value
   grid for every field plus the comment block. The completion fields
   are conditional on the request being completed. */
function bsv_renderRequestDetail(data) {
    var body = document.getElementById('detail-modal-body');
    document.getElementById('detail-modal-title').textContent = 'Request #' + data.dm_request_id;

    var html = '<div class="detail-grid">';
    html += bsv_detailRow('Consumer', (data.consumer_number || '') + ' - ' + (data.consumer_name || ''));
    html += bsv_detailRow('Workgroup', data.workgroup || '-');
    html += bsv_detailRow('Group', data.group_name || '-');
    html += bsv_detailRow('Requested By', data.requesting_user || '-');
    html += bsv_detailRow('Request Date', data.request_date || '-');
    html += bsv_detailRow('Assigned To', data.assigned_user || '-');
    html += bsv_detailRow('Status', data.is_completed ? 'Completed' : 'Open');

    if (data.is_completed) {
        html += bsv_detailRow('Completed By', data.completed_user || '-');
        html += bsv_detailRow('Completion Date', data.completion_date || '-');
    }
    html += '</div>';

    /* Comment section. */
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

/* Builds the HTML for a single label/value row in the request detail
   grid. Reused for every field rendered by bsv_renderRequestDetail. */
function bsv_detailRow(label, value) {
    return '<div class="detail-field"><span class="detail-label">' + label + '</span><span class="detail-value">' + escapeHtml(value) + '</span></div>';
}

/* Closes the request detail modal. Wired up from the modal's close
   button in the page template. */
function bsv_closeDetailModal() {
    document.getElementById('detail-modal').classList.add('hidden');
}


/* ============================================================================
   FUNCTIONS: SLIDEOUT PANEL
   ----------------------------------------------------------------------------
   The slideout panel that presents the day-detail view. Distinct from
   the request detail modal: the slideout slides in from the right and
   stays on top of the page (with a backdrop), while the modal is a
   centered overlay. The slideout reuses one DOM node for both day
   summary and per-user request views.
   Prefix: bsv
   ============================================================================ */

/* Opens the slideout panel with a given title and a loading state in
   the body. Callers populate the body once their data lands. */
function bsv_openSlideout(title) {
    document.getElementById('slideout-title').textContent = title;
    document.getElementById('slideout-body').innerHTML = '<div class="loading">Loading...</div>';
    document.getElementById('slideout').classList.add('open');
    document.getElementById('slideout-backdrop').classList.add('visible');
}

/* Closes the slideout panel and its backdrop. Wired up from the
   close-button click and from the backdrop click. */
function bsv_closeSlideout() {
    document.getElementById('slideout').classList.remove('open');
    document.getElementById('slideout-backdrop').classList.remove('visible');
}


/* ============================================================================
   FUNCTIONS: UTILITIES
   ----------------------------------------------------------------------------
   Page-local helpers: timestamp display, the inline connection-error
   banner, and MM/DD/YYYY display formatting. The standard escapeHtml
   from cc-shared.js handles HTML attribute and content escaping.
   Prefix: bsv
   ============================================================================ */

/* Updates the live "last updated" timestamp display in the page
   header. The expected input is a localized time string; if a full
   timestamp ('YYYY-MM-DD HH:MM:SS') is passed in, only the time
   portion is shown. */
function bsv_updateTimestamp(ts) {
    var el = document.getElementById('last-update');
    if (el && ts) {
        var parts = ts.split(' ');
        el.textContent = parts.length > 1 ? parts[1] : ts;
    }
}

/* Shows the inline connection error banner with a message. Used when
   the live-activity API call fails outside of session-expiry, which
   is handled by cc-shared.js. */
function bsv_showConnectionError(msg) {
    var el = document.getElementById('connection-error');
    el.textContent = msg;
    el.classList.add('visible');
}

/* Hides the inline connection error banner. Called on successful
   live-activity load. */
function bsv_clearConnectionError() {
    document.getElementById('connection-error').classList.remove('visible');
}

/* Formats an ISO date string (YYYY-MM-DD) as a US display date
   (MM/DD/YYYY). Returns the input unchanged if it doesn't split
   cleanly into three parts. */
function bsv_formatDisplayDate(dateStr) {
    if (!dateStr) return '';
    var parts = dateStr.split('-');
    if (parts.length === 3) return parts[1] + '/' + parts[2] + '/' + parts[0];
    return dateStr;
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
    bsv_refreshAll();
}

/* Called by cc-shared.js when the page becomes visible again after
   being hidden. cc-shared.js drives the spin animation; this hook
   does the actual data reload so the user sees current data. */
function onPageResumed() {
    bsv_refreshAll();
}

/* Called by cc-shared.js when the session is detected as expired.
   Stops the live-polling timer so we don't keep firing fetches that
   engineFetch will short-circuit. */
function onSessionExpired() {
    bsv_stopLivePolling();
}

/* Called by cc-shared.js when an orchestrator process listed in
   ENGINE_PROCESSES completes. Refreshes the event-driven sections
   (Distribution and History) since fresh data is now available. */
function onEngineProcessCompleted(processName, event) {
    bsv_refreshEventSections();
}

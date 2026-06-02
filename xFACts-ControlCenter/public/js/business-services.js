/* ============================================================================
   xFACts Control Center - Business Services JavaScript (business-services.js)
   Location: E:\xFACts-ControlCenter\public\js\business-services.js
   Version: Tracked in dbo.System_Metadata (component: DeptOps.BusinessServices)

   Page-specific JS for the Business Services departmental page. Universal
   chrome (WebSocket engine events, connection banner, page refresh button,
   idle detection, session expiry, shared modals, formatting utilities) is
   provided by cc-shared.js and invoked through the bootloader contract. This
   file contains the data loading and rendering logic for the live activity
   cards, the distribution flip cards, the year/month/day history drill-down,
   the day-detail slideout with per-user request lists, and the request detail
   modal. The bootloader calls bsv_init after this module loads.

   FILE ORGANIZATION
   -----------------
   CONSTANTS: ENGINE PROCESSES
   CONSTANTS: PAGE CONFIGURATION
   CONSTANTS: ACTION DISPATCH TABLES
   STATE: PAGE STATE
   FUNCTIONS: INITIALIZATION
   FUNCTIONS: ACTION DISPATCH
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
   The bsv_ENGINE_PROCESSES contract: a map from orchestrator process names to
   engine card slugs that cc-shared.js reads at startup to wire up the engine
   indicator subsystem. The Business Services page has two collectors driving
   its event-driven sections (Distribution and History): Collect-BSReviewRequests
   harvests new request data, and Distribute-BSReviewRequests assigns fresh
   requests to users.
   Prefix: bsv
   ============================================================================ */

/* Maps orchestrator process names to engine card slugs. cc-shared.js reads
   this at startup via window['bsv_ENGINE_PROCESSES']; each entry binds a
   process to a card on the page. Card refreshes for the bound process happen
   automatically through the bsv_onEngineProcessCompleted hook. Declared with
   var per the JS spec engine-processes rule. */
var bsv_ENGINE_PROCESSES = {
    'Collect-BSReviewRequests':    { slug: 'collect' },
    'Distribute-BSReviewRequests': { slug: 'distribute' }
};

/* ============================================================================
   CONSTANTS: PAGE CONFIGURATION
   ----------------------------------------------------------------------------
   Module-level immutable configuration for this page: the month-name lookup
   used by the history tree and the default live-polling interval. The refresh
   interval default is overwritten at load time from GlobalConfig.
   Prefix: bsv
   ============================================================================ */

/* Month names lookup, 1-indexed so a SQL month number maps directly without
   subtraction. Index 0 is intentional empty padding. Read as
   bsv_MONTH_NAMES[1] === 'January'. */
const bsv_MONTH_NAMES = ['', 'January', 'February', 'March', 'April', 'May', 'June',
                         'July', 'August', 'September', 'October', 'November', 'December'];

/* Default live-polling interval in seconds. Overwritten at page load by
   bsv_loadRefreshInterval from GlobalConfig (ControlCenter |
   refresh_businessservices_seconds). 60 seconds keeps the live activity counts
   reasonably fresh without burning fetches. */
const bsv_PAGE_REFRESH_INTERVAL_DEFAULT = 60;

/* ============================================================================
   CONSTANTS: ACTION DISPATCH TABLES
   ----------------------------------------------------------------------------
   Per-event dispatch tables mapping this page's data-action-<event> values to
   handler functions. The bootloader's shared listeners handle cc- actions;
   the page-local listeners registered in bsv_init route bsv- actions through
   these tables.
   Prefix: bsv
   ============================================================================ */

/* Page-local click-action dispatch table. Maps bsv- data-action-click values
   to handler functions defined in this file. */
const bsv_clickActions = {
    'bsv-flip-card':         bsv_handleFlipCard,
    'bsv-select-group':      bsv_handleSelectGroup,
    'bsv-toggle-year':       bsv_handleToggleYear,
    'bsv-toggle-month':      bsv_handleToggleMonth,
    'bsv-open-day-detail':   bsv_handleOpenDayDetail,
    'bsv-open-user-day':     bsv_handleOpenUserDay,
    'bsv-back-to-day':       bsv_handleBackToDay,
    'bsv-open-request-detail': bsv_handleOpenRequestDetail,
    'bsv-close-slideout':    bsv_closeSlideout,
    'bsv-close-modal':       bsv_closeDetailModal
};

/* ============================================================================
   STATE: PAGE STATE
   ----------------------------------------------------------------------------
   Module-scope mutable state for the Business Services UI: the live-poll and
   auto-refresh timer handles, the page-load date for midnight rollover
   detection, the active group filter for the history tree, the effective
   refresh interval, and the cached list of distribution groups used to render
   the badge row.
   Prefix: bsv
   ============================================================================ */

/* Effective live-polling interval in seconds. Starts at the default and is
   overwritten by bsv_loadRefreshInterval if GlobalConfig has a value. */
var bsv_pageRefreshInterval = bsv_PAGE_REFRESH_INTERVAL_DEFAULT;

/* setInterval handle for the live-polling timer, or null when not running. */
var bsv_livePollingTimer = null;

/* setInterval handle for the midnight-rollover check, or null when not
   running. */
var bsv_autoRefreshTimer = null;

/* Date string captured at page load. Compared against the current date inside
   the auto-refresh timer to trigger a full reload at midnight. */
var bsv_pageLoadDate = new Date().toDateString();

/* Active group filter for the history tree. '0' means "All Groups"; any other
   value is a specific group_id rendered as a string. */
var bsv_selectedGroupFilter = '0';

/* Cached list of distribution groups from the most recent history response.
   Backs the rendered badge row above the history tree. */
var bsv_historyGroupList = [];

/* ============================================================================
   FUNCTIONS: INITIALIZATION
   ----------------------------------------------------------------------------
   The page boot function invoked by the cc-shared.js bootloader after this
   module loads. Registers the page-local delegated event listeners, performs
   the first data load for all three sections, reads the refresh interval from
   GlobalConfig, starts the refresh timers, and registers the engine-events
   chrome with cc-shared.js.
   Prefix: bsv
   ============================================================================ */

/* Page boot entry point. The bootloader resolves window['bsv_init'] and calls
   it once after the module loads. Registers one delegated click listener per
   stable container for page-local actions, loads each section, starts the
   refresh timers, and hands the engine subsystem to cc-shared.js. */
function bsv_init() {
    document.body.addEventListener('click', bsv_handleClick);

    bsv_loadLiveActivity();
    bsv_loadDistribution();
    bsv_loadHistory();

    bsv_loadRefreshInterval();
    bsv_startAutoRefresh();
    bsv_startLivePolling();
    cc_connectEngineEvents();
}

/* ============================================================================
   FUNCTIONS: ACTION DISPATCH
   ----------------------------------------------------------------------------
   The page-local delegated click dispatcher. Registered on document.body in
   bsv_init, it resolves the action value on the clicked element and routes it
   through the bsv_clickActions table to the matching handler.
   Prefix: bsv
   ============================================================================ */

/* Delegated click dispatcher for page-local actions. Resolves the nearest
   element carrying data-action-click, looks the value up in bsv_clickActions,
   and invokes the handler with the matched element and the event. cc- actions
   are handled by the bootloader's own shared listener and ignored here. */
function bsv_handleClick(event) {
    var target = event.target.closest('[data-action-click]');
    if (!target) {
        return;
    }
    var action = target.getAttribute('data-action-click');
    var handler = bsv_clickActions[action];
    if (handler) {
        handler(target, event);
    }
}

/* ============================================================================
   FUNCTIONS: LIVE POLLING
   ----------------------------------------------------------------------------
   The page's refresh loop. Live polling reloads the live-activity section at
   the configured interval; the auto-refresh timer reloads the entire page at
   midnight. The refresh-all and refresh-event paths are split because
   Distribution and History are event-driven (refreshed when an engine process
   completes) while Live Activity is interval-driven.
   Prefix: bsv
   ============================================================================ */

/* Loads the page-specific refresh interval from GlobalConfig via the shared
   refresh-interval API. Falls back to the default constant if the API is
   unavailable. */
async function bsv_loadRefreshInterval() {
    try {
        var data = await cc_engineFetch('/api/config/refresh-interval?page=businessservices');
        if (data) {
            bsv_pageRefreshInterval = data.interval || bsv_PAGE_REFRESH_INTERVAL_DEFAULT;
        }
    } catch (e) {
        /* API unavailable - default already in effect. */
    }
}

/* Starts the midnight-rollover check. Lightweight 60-second timer that reloads
   the page when the date changes - cheaper than rebuilding the history UI from
   a cross-day query result set. */
function bsv_startAutoRefresh() {
    bsv_autoRefreshTimer = setInterval(function() {
        var today = new Date().toDateString();
        if (today !== bsv_pageLoadDate) {
            window.location.reload();
        }
    }, 60000);
}

/* Starts the live-polling timer for the live-activity section. The fetch goes
   through cc_engineFetch, which returns null when the tab is hidden, the
   session is expired, or polling is idle-paused, so the refresh becomes a safe
   no-op in those states without reading shared chrome state directly. */
function bsv_startLivePolling() {
    if (bsv_livePollingTimer) {
        clearInterval(bsv_livePollingTimer);
    }
    bsv_livePollingTimer = setInterval(bsv_refreshLiveSections, bsv_pageRefreshInterval * 1000);
}

/* Stops live polling. Called by the bsv_onSessionExpired hook when cc-shared.js
   detects the session has expired so we do not keep firing fetches that
   cc_engineFetch would short-circuit. */
function bsv_stopLivePolling() {
    if (bsv_livePollingTimer) {
        clearInterval(bsv_livePollingTimer);
        bsv_livePollingTimer = null;
    }
}

/* Refreshes only the live-activity section. Called by the live-polling timer;
   updates the page timestamp once data lands. */
function bsv_refreshLiveSections() {
    bsv_loadLiveActivity();
    bsv_updateTimestamp((new Date()).toLocaleTimeString());
}

/* Refreshes the event-driven sections (Distribution and History). Called by
   the bsv_onEngineProcessCompleted hook when a relevant orchestrator process
   finishes. */
function bsv_refreshEventSections() {
    bsv_loadDistribution();
    bsv_loadHistory();
}

/* Refreshes everything on the page. Called by the bsv_onPageRefresh hook (the
   manual refresh button) and by the bsv_onPageResumed hook on tab resume. */
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
   real-time counts of open, assigned, unassigned, new-today, and closed-today
   requests. Threshold-based urgency colors highlight groups with high
   unassigned counts.
   Prefix: bsv
   ============================================================================ */

/* Loads live activity data and re-renders the cards. Updates the page
   timestamp and clears the connection error banner on success. */
function bsv_loadLiveActivity() {
    cc_engineFetch('/api/business-services/live-activity')
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

/* Renders the live activity cards: one per group, showing the five real-time
   counts. Urgency class is derived from the unassigned count and applied to
   the card root. */
function bsv_renderLiveActivity(groups) {
    var container = document.getElementById('bsv-live-activity-cards');
    var loading = document.getElementById('bsv-live-activity-loading');

    loading.classList.add('bsv-hidden');
    container.classList.remove('bsv-hidden');

    if (!groups || groups.length === 0) {
        container.innerHTML = '<div class="bsv-no-activity">No group data available</div>';
        return;
    }

    var html = '';

    groups.forEach(function(g) {
        var urgencyClass = '';
        if (g.unassigned > 50) urgencyClass = ' bsv-card-warning';
        if (g.unassigned > 200) urgencyClass = ' bsv-card-critical';

        html += '<div class="bsv-activity-card' + urgencyClass + '">';
        html += '<div class="bsv-activity-card-title">' + cc_escapeHtml(g.group_name) + ' (' + cc_escapeHtml(g.group_short_name) + ')</div>';
        html += '<div class="bsv-activity-card-metrics-5">';
        html += '<div class="bsv-metric"><span class="bsv-metric-value">' + g.total_open + '</span><span class="bsv-metric-label">Open</span></div>';
        html += '<div class="bsv-metric"><span class="bsv-metric-value bsv-metric-assigned">' + g.assigned + '</span><span class="bsv-metric-label">Assigned</span></div>';
        html += '<div class="bsv-metric"><span class="bsv-metric-value bsv-metric-unassigned">' + g.unassigned + '</span><span class="bsv-metric-label">Unassigned</span></div>';
        html += '<div class="bsv-metric"><span class="bsv-metric-value bsv-metric-new">' + g.new_today + '</span><span class="bsv-metric-label">New Today</span></div>';
        html += '<div class="bsv-metric"><span class="bsv-metric-value bsv-metric-completed">' + g.closed_today + '</span><span class="bsv-metric-label">Closed Today</span></div>';
        html += '</div></div>';
    });

    container.innerHTML = html;
}

/* ============================================================================
   FUNCTIONS: DISTRIBUTION
   ----------------------------------------------------------------------------
   The Distribution flip cards: one per group, showing the front face with
   aggregate assignment metrics and the back face with per-user detail. Click
   anywhere on a card to flip; the back face shows each user's currently-
   assigned count, cap, and completed-today count.
   Prefix: bsv
   ============================================================================ */

/* Loads the distribution data and re-renders the flip cards. */
function bsv_loadDistribution() {
    cc_engineFetch('/api/business-services/distribution')
        .then(function(data) {
            if (!data) return;
            bsv_renderDistribution(data.groups);
        })
        .catch(function(err) {
            var container = document.getElementById('bsv-distribution-cards');
            container.innerHTML = '<div class="bsv-no-activity">Failed to load distribution data</div>';
            container.classList.remove('bsv-hidden');
            document.getElementById('bsv-distribution-loading').classList.add('bsv-hidden');
        });
}

/* Renders the per-group distribution flip cards. Each card has a front face
   (group totals: assigned-of-cap, fill percentage, new today, completed today)
   and a back face (user list with per-user assignment counts and progress
   bars). The card carries data-action-click so a click toggles between faces. */
function bsv_renderDistribution(groups) {
    var container = document.getElementById('bsv-distribution-cards');
    var loading = document.getElementById('bsv-distribution-loading');

    loading.classList.add('bsv-hidden');
    container.classList.remove('bsv-hidden');

    if (!groups || groups.length === 0) {
        container.innerHTML = '<div class="bsv-no-activity">No distribution groups configured</div>';
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

        html += '<div class="bsv-flip-card" data-action-click="bsv-flip-card">';

        /* Front face. */
        html += '<div class="bsv-flip-card-front">';
        html += '<div class="bsv-flip-card-title">' + cc_escapeHtml(g.group_short_name) + '</div>';
        html += '<div class="bsv-flip-card-subtitle">' + g.users.length + ' users</div>';
        html += '<div class="bsv-flip-card-big-number">' + totalAssigned + '<span class="bsv-flip-card-of">/ ' + totalCap + '</span></div>';
        html += '<div class="bsv-flip-card-progress"><div class="bsv-flip-card-progress-fill" style="width:' + Math.min(fillPct, 100) + '%"></div><span class="bsv-flip-card-progress-text">' + totalAssigned + ' / ' + totalCap + '</span></div>';
        html += '<div class="bsv-flip-card-footer-row">';
        html += '<span class="bsv-flip-new">' + newToday + ' new today</span>';
        html += '<span class="bsv-flip-completed">' + totalCompletedToday + ' completed today</span>';
        html += '</div>';
        html += '<div class="bsv-flip-card-hint">Click for user details</div>';
        html += '</div>';

        /* Back face. */
        html += '<div class="bsv-flip-card-back">';
        html += '<div class="bsv-flip-card-title">' + cc_escapeHtml(g.group_short_name) + ' Users</div>';

        g.users.forEach(function(u) {
            var userPct = u.assignment_cap > 0 ? Math.round((u.currently_assigned / u.assignment_cap) * 100) : 0;
            var userClass = userPct >= 90 ? ' bsv-user-full' : (userPct >= 70 ? ' bsv-user-high' : '');

            html += '<div class="bsv-dist-user">';
            html += '<div class="bsv-dist-user-name' + userClass + '">' + cc_escapeHtml(u.display_name) + '</div>';
            html += '<div class="bsv-dist-user-stats">';
            html += '<span class="bsv-dist-stat">' + u.currently_assigned + ' / ' + u.assignment_cap + '</span>';
            html += '<span class="bsv-dist-completed">' + u.completed_today + ' today</span>';
            html += '</div>';
            html += '<div class="bsv-dist-user-bar"><div class="bsv-dist-user-bar-fill' + userClass + '" style="width:' + Math.min(userPct, 100) + '%"></div></div>';
            html += '</div>';
        });

        html += '<div class="bsv-flip-card-hint">Click to flip back</div>';
        html += '</div>';

        html += '</div>';
    });

    container.innerHTML = html;
}

/* Toggles the flipped state on the clicked distribution flip card. The state
   class goes on the two faces (the elements whose transform changes), not the
   card root. Dispatched from the bsv-flip-card click action. */
function bsv_handleFlipCard(target, event) {
    var front = target.querySelector('.bsv-flip-card-front');
    var back = target.querySelector('.bsv-flip-card-back');
    if (front) {
        front.classList.toggle('bsv-flipped');
    }
    if (back) {
        back.classList.toggle('bsv-flipped');
    }
}

/* ============================================================================
   FUNCTIONS: HISTORY TREE
   ----------------------------------------------------------------------------
   The Year/Month/Day drill-down view of historical request volume. Loads
   aggregate yearly counts on first render; expanding a year shows per-month
   rows; expanding a month lazy-loads per-day rows from a separate endpoint.
   The group filter badges above the tree scope every level of the drill-down.
   Prefix: bsv
   ============================================================================ */

/* Loads the history tree data scoped to the active group filter. The response
   carries the available group list (used to render the filter badges) and the
   pre-aggregated year/month rows. */
function bsv_loadHistory() {
    var url = '/api/business-services/history?group=' + bsv_selectedGroupFilter;

    cc_engineFetch(url)
        .then(function(data) {
            if (!data) return;
            if (data.groups) {
                bsv_historyGroupList = data.groups;
                bsv_renderGroupBadges(data.groups);
            }
            bsv_renderHistory(data.years, data.total_count);
        })
        .catch(function(err) {
            var container = document.getElementById('bsv-history-tree');
            container.innerHTML = '<div class="bsv-no-activity">Failed to load history: ' + err.message + '</div>';
            container.classList.remove('bsv-hidden');
            document.getElementById('bsv-history-loading').classList.add('bsv-hidden');
        });
}

/* Renders the group filter badges above the history tree. The 'All' badge is
   always present; one badge per known group. Each badge carries its group id
   so the delegated click handler can apply the filter. */
function bsv_renderGroupBadges(groups) {
    var container = document.getElementById('bsv-group-badges');

    var allActive = bsv_selectedGroupFilter === '0' ? ' bsv-active' : '';
    var html = '<span class="bsv-group-badge' + allActive + '" data-action-click="bsv-select-group" data-action-bsv-group-id="0">All</span>';

    groups.forEach(function(g) {
        var gid = g.group_id.toString();
        var activeClass = (bsv_selectedGroupFilter === gid) ? ' bsv-active' : '';
        html += '<span class="bsv-group-badge' + activeClass + '" data-action-click="bsv-select-group" data-action-bsv-group-id="' + cc_escapeHtml(gid) + '">' + cc_escapeHtml(g.group_short_name) + '</span>';
    });

    container.innerHTML = html;
}

/* Sets the active group filter and reloads the history tree. Dispatched from
   the bsv-select-group click action; reads the group id from the badge's
   argument attribute. */
function bsv_handleSelectGroup(target, event) {
    bsv_selectedGroupFilter = target.getAttribute('data-action-bsv-group-id');
    bsv_loadHistory();
}

/* Renders the year/month rows in the history tree. Years are collapsible; each
   year's months render as table rows that expand to show day-level detail when
   clicked. */
function bsv_renderHistory(years, totalCount) {
    var container = document.getElementById('bsv-history-tree');
    var loading = document.getElementById('bsv-history-loading');
    var countEl = document.getElementById('bsv-history-count');

    loading.classList.add('bsv-hidden');
    container.classList.remove('bsv-hidden');

    countEl.textContent = totalCount ? totalCount.toLocaleString() + ' requests' : '';

    if (!years || years.length === 0) {
        container.innerHTML = '<div class="bsv-no-activity">No history data available</div>';
        return;
    }

    var html = '';

    years.forEach(function(yearData) {
        html += '<div class="bsv-history-year">';
        html += '<div class="bsv-year-header" data-action-click="bsv-toggle-year">';
        html += '<span class="bsv-expand-icon">&#9654;</span>';
        html += '<span class="bsv-year-label">' + yearData.year + '</span>';
        html += '<div class="bsv-year-stats">';
        html += '<span class="bsv-year-stat">' + yearData.received.toLocaleString() + ' received</span>';
        html += '<span class="bsv-year-stat bsv-completed">' + yearData.completed.toLocaleString() + ' completed</span>';
        html += '</div>';
        html += '</div>';
        html += '<div class="bsv-year-content" style="display:none;">';
        html += '<table class="bsv-history-table"><thead><tr>';
        html += '<th class="bsv-history-table-th"></th><th class="bsv-history-table-th">Month</th><th class="bsv-history-table-th">Received</th><th class="bsv-history-table-th">Completed</th>';
        html += '</tr></thead>';

        yearData.months.forEach(function(monthData) {
            html += '<tbody>';
            html += '<tr class="bsv-month-row" data-action-click="bsv-toggle-month" data-action-bsv-year="' + yearData.year + '" data-action-bsv-month="' + monthData.month + '">';
            html += '<td class="bsv-history-table-td bsv-expand-cell"><span class="bsv-expand-icon">&#9654;</span></td>';
            html += '<td class="bsv-history-table-td bsv-month-cell">' + bsv_MONTH_NAMES[monthData.month] + '</td>';
            html += '<td class="bsv-history-table-td">' + monthData.received.toLocaleString() + '</td>';
            html += '<td class="bsv-history-table-td bsv-completed-cell">' + monthData.completed.toLocaleString() + '</td>';
            html += '</tr>';
            html += '<tr class="bsv-month-details" style="display:none;"><td colspan="4">';
            html += '<div class="bsv-month-details-content" data-year="' + yearData.year + '" data-month="' + monthData.month + '">';
            html += '<div class="bsv-loading">Loading...</div></div></td></tr>';
            html += '</tbody>';
        });

        html += '</table></div></div>';
    });

    container.innerHTML = html;
}

/* Toggles the expanded state of a year row in the history tree. Dispatched
   from the bsv-toggle-year click action on the year header. */
function bsv_handleToggleYear(target, event) {
    var content = target.nextElementSibling;
    var icon = target.querySelector('.bsv-expand-icon');
    if (content.style.display === 'none') {
        content.style.display = 'block';
        icon.innerHTML = '&#9660;';
    } else {
        content.style.display = 'none';
        icon.innerHTML = '&#9654;';
    }
}

/* Toggles the expanded state of a month row. On first expansion, lazy-loads
   the per-day data for that month. Dispatched from the bsv-toggle-month click
   action; reads the year and month from the row's argument attributes. */
function bsv_handleToggleMonth(target, event) {
    var year = parseInt(target.getAttribute('data-action-bsv-year'), 10);
    var month = parseInt(target.getAttribute('data-action-bsv-month'), 10);
    var tbody = target.closest('tbody');
    var detailRow = tbody.querySelector('.bsv-month-details');
    var icon = target.querySelector('.bsv-expand-icon');
    var contentDiv = tbody.querySelector('.bsv-month-details-content');

    if (detailRow.style.display === 'none') {
        detailRow.style.display = '';
        icon.innerHTML = '&#9660;';

        /* Load day-level data if not already loaded. */
        if (contentDiv.querySelector('.bsv-loading')) {
            bsv_loadMonthDays(contentDiv, year, month);
        }
    } else {
        detailRow.style.display = 'none';
        icon.innerHTML = '&#9654;';
    }
}

/* Fetches the per-day data for a single month and hands the result to the
   renderer. Used for the lazy-load branch of bsv_handleToggleMonth. */
function bsv_loadMonthDays(container, year, month) {
    var url = '/api/business-services/history-month?year=' + year + '&month=' + month + '&group=' + bsv_selectedGroupFilter;

    cc_engineFetch(url)
        .then(function(data) {
            if (!data) return;
            bsv_renderMonthDays(container, data.days);
        })
        .catch(function(err) {
            container.innerHTML = '<div class="bsv-no-activity">Error loading month data</div>';
        });
}

/* Renders the per-day rows for a single month inside the month's expanded
   detail row. Each day carries its date so the delegated handler can open the
   day-detail slideout. */
function bsv_renderMonthDays(container, days) {
    if (!days || days.length === 0) {
        container.innerHTML = '<div class="bsv-no-activity">No activity this month</div>';
        return;
    }

    var html = '<table class="bsv-history-table"><thead><tr>';
    html += '<th class="bsv-history-table-th">Day</th><th class="bsv-history-table-th">Date</th><th class="bsv-history-table-th">Received</th><th class="bsv-history-table-th">Completed</th>';
    html += '</tr></thead><tbody>';

    days.forEach(function(d, idx) {
        var rowClass = idx % 2 === 0 ? 'bsv-day-row' : 'bsv-day-row bsv-row-odd';
        html += '<tr class="' + rowClass + '" data-action-click="bsv-open-day-detail" data-action-bsv-date="' + d.date + '">';
        html += '<td class="bsv-history-table-td">' + d.day_of_week + '</td>';
        var dateParts = d.date.split('-');
        html += '<td class="bsv-history-table-td">' + dateParts[1] + '/' + dateParts[2] + '</td>';
        html += '<td class="bsv-history-table-td">' + d.received + '</td>';
        html += '<td class="bsv-history-table-td bsv-completed-cell">' + d.completed + '</td>';
        html += '</tr>';
    });

    html += '</tbody></table>';
    container.innerHTML = html;
}

/* ============================================================================
   FUNCTIONS: DAY DETAIL
   ----------------------------------------------------------------------------
   The day-detail slideout panel and its drill-down to per-user request lists.
   Opening a day detail shows group-level summary cards plus the per-user
   completion table; clicking a user row swaps the slideout content to show
   that user's individual completed requests for the day, with a back-link to
   return to the day summary.
   Prefix: bsv
   ============================================================================ */

/* Opens the day-detail slideout for a given date. Dispatched from the
   bsv-open-day-detail click action on a day row; reads the date from the row's
   argument attribute. */
function bsv_handleOpenDayDetail(target, event) {
    bsv_loadDayDetail(target.getAttribute('data-action-bsv-date'));
}

/* Loads the day-detail data and renders it into the slideout. Opens the
   slideout with a loading state, then fills it with the response. */
function bsv_loadDayDetail(date) {
    bsv_openSlideout('Completions: ' + bsv_formatDisplayDate(date));

    var url = '/api/business-services/history-day?date=' + date + '&group=' + bsv_selectedGroupFilter;

    cc_engineFetch(url)
        .then(function(data) {
            if (!data) return;
            bsv_renderDayDetail(data);
        })
        .catch(function(err) {
            document.getElementById('bsv-detail-slideout-body').innerHTML = '<div class="bsv-no-activity">Error loading day details</div>';
        });
}

/* Renders the day-summary view inside the slideout: group cards (one per group
   with activity that day) and a per-user completion table (rows carry the date
   and username so a click drills into that user's individual requests). */
function bsv_renderDayDetail(data) {
    var body = document.getElementById('bsv-detail-slideout-body');
    var html = '';

    /* Group summary cards. */
    if (data.groups && data.groups.length > 0) {
        html += '<div class="bsv-slideout-section-title">Group Summary</div>';
        html += '<div class="bsv-slideout-group-cards">';
        data.groups.forEach(function(g) {
            /* Only show groups that had activity. */
            if (g.completed === 0 && g.received === 0) return;
            html += '<div class="bsv-slideout-group-card">';
            html += '<div class="bsv-slideout-group-name">' + cc_escapeHtml(g.group_short_name) + '</div>';
            html += '<div class="bsv-slideout-group-metrics">';
            html += '<span class="bsv-sg-metric bsv-sg-completed">' + g.completed + ' completed</span>';
            html += '<span class="bsv-sg-metric bsv-sg-received">' + g.received + ' received</span>';
            html += '</div></div>';
        });
        html += '</div>';
    }

    /* User breakdown - completions. */
    if (data.users && data.users.length > 0) {
        html += '<div class="bsv-slideout-section-title">Completions by User</div>';
        html += '<table class="bsv-slideout-table"><thead><tr>';
        html += '<th class="bsv-slideout-table-th">Group</th><th class="bsv-slideout-table-th">User</th><th class="bsv-slideout-table-th">Completed</th>';
        html += '</tr></thead><tbody>';

        data.users.forEach(function(u) {
            html += '<tr class="bsv-user-detail-row" data-action-click="bsv-open-user-day" data-action-bsv-date="' + cc_escapeHtml(data.date) + '" data-action-bsv-username="' + cc_escapeHtml(u.username) + '">';
            html += '<td class="bsv-slideout-table-td">' + cc_escapeHtml(u.group_short_name) + '</td>';
            html += '<td class="bsv-slideout-table-td">' + cc_escapeHtml(u.username) + '</td>';
            html += '<td class="bsv-slideout-table-td bsv-completed-cell">' + u.completed + '</td>';
            html += '</tr>';
        });

        html += '</tbody></table>';
    } else {
        html += '<div class="bsv-no-activity">No completions on this day</div>';
    }

    body.innerHTML = html;
}

/* Opens the per-user request list for a day. Dispatched from the
   bsv-open-user-day click action on a user-detail row; reads the date and
   username from the row's argument attributes. */
function bsv_handleOpenUserDay(target, event) {
    var date = target.getAttribute('data-action-bsv-date');
    var username = target.getAttribute('data-action-bsv-username');
    bsv_loadUserDayRequests(date, username);
}

/* Loads a single user's completed requests for a single day and renders them
   in the slideout, replacing the day-summary view. */
function bsv_loadUserDayRequests(date, username) {
    var displayName = username === '(Unknown)' ? 'Unknown User' : username;
    document.getElementById('bsv-detail-slideout-title').textContent = displayName + ' - ' + bsv_formatDisplayDate(date);
    document.getElementById('bsv-detail-slideout-body').innerHTML = '<div class="bsv-loading">Loading requests...</div>';

    var url = '/api/business-services/history-user-day?date=' + date + '&username=' + encodeURIComponent(username) + '&group=' + bsv_selectedGroupFilter;

    cc_engineFetch(url)
        .then(function(data) {
            if (!data) return;
            bsv_renderUserDayRequests(data);
        })
        .catch(function(err) {
            document.getElementById('bsv-detail-slideout-body').innerHTML = '<div class="bsv-no-activity">Error loading requests</div>';
        });
}

/* Renders the per-user request table in the slideout. Each comment button
   carries its tracking id (opens the request detail modal) and the back-link
   carries the date (returns to the day-summary view). */
function bsv_renderUserDayRequests(data) {
    var body = document.getElementById('bsv-detail-slideout-body');

    if (!data.requests || data.requests.length === 0) {
        body.innerHTML = '<div class="bsv-no-activity">No requests found</div>';
        return;
    }

    var html = '<div class="bsv-slideout-count">' + data.count + ' request(s) completed</div>';
    html += '<table class="bsv-slideout-table"><thead><tr>';
    html += '<th class="bsv-slideout-table-th">Consumer #</th><th class="bsv-slideout-table-th">Consumer Name</th><th class="bsv-slideout-table-th">Workgroup</th><th class="bsv-slideout-table-th">Group</th><th class="bsv-slideout-table-th">Completed</th><th class="bsv-slideout-table-th"></th>';
    html += '</tr></thead><tbody>';

    data.requests.forEach(function(r) {
        var commentBtn = r.has_comment ? '<button class="bsv-btn bsv-btn-xs bsv-btn-comment" data-action-click="bsv-open-request-detail" data-action-bsv-tracking-id="' + r.tracking_id + '" title="View comment">&#128172;</button>' : '';

        html += '<tr>';
        html += '<td class="bsv-slideout-table-td bsv-mono">' + cc_escapeHtml(r.consumer_number || '') + '</td>';
        html += '<td class="bsv-slideout-table-td">' + cc_escapeHtml(r.consumer_name || '') + '</td>';
        html += '<td class="bsv-slideout-table-td">' + cc_escapeHtml(r.workgroup || '') + '</td>';
        html += '<td class="bsv-slideout-table-td">' + cc_escapeHtml(r.group_short_name || '') + '</td>';
        html += '<td class="bsv-slideout-table-td bsv-completed-cell">' + cc_escapeHtml(r.completion_date || '') + '</td>';
        html += '<td class="bsv-slideout-table-td">' + commentBtn + '</td>';
        html += '</tr>';
    });

    html += '</tbody></table>';

    /* Back button. */
    html += '<button class="bsv-btn bsv-btn-sm bsv-btn-back" data-action-click="bsv-back-to-day" data-action-bsv-date="' + cc_escapeHtml(data.date) + '">&#8592; Back to day summary</button>';

    body.innerHTML = html;
}

/* Returns to the day-summary view from the per-user request list. Dispatched
   from the bsv-back-to-day click action; reads the date from the button's
   argument attribute. */
function bsv_handleBackToDay(target, event) {
    bsv_loadDayDetail(target.getAttribute('data-action-bsv-date'));
}

/* ============================================================================
   FUNCTIONS: REQUEST DETAIL MODAL
   ----------------------------------------------------------------------------
   The request detail modal: a separate overlay (independent from the slideout)
   that shows the full record for a single tracking id, including the comment
   text. Opened from the comment-icon button on user-day request rows.
   Prefix: bsv
   ============================================================================ */

/* Opens the request detail modal. Dispatched from the bsv-open-request-detail
   click action on a comment button; reads the tracking id from the button's
   argument attribute. */
function bsv_handleOpenRequestDetail(target, event) {
    bsv_openRequestDetail(parseInt(target.getAttribute('data-action-bsv-tracking-id'), 10));
}

/* Opens the request detail modal and fetches the record by tracking id.
   Populates the modal body with the rendered detail or an error message. */
function bsv_openRequestDetail(trackingId) {
    document.getElementById('bsv-modal-detail').classList.remove('cc-hidden');
    document.getElementById('bsv-detail-modal-body').innerHTML = '<div class="bsv-loading">Loading...</div>';

    cc_engineFetch('/api/business-services/request-detail?id=' + trackingId)
        .then(function(data) {
            if (!data) return;
            bsv_renderRequestDetail(data);
        })
        .catch(function(err) {
            document.getElementById('bsv-detail-modal-body').innerHTML = '<div class="bsv-no-activity">Error loading detail</div>';
        });
}

/* Renders the full request detail inside the modal: a label/value grid for
   every field plus the comment block. The completion fields are conditional on
   the request being completed. */
function bsv_renderRequestDetail(data) {
    var body = document.getElementById('bsv-detail-modal-body');
    document.getElementById('bsv-detail-modal-title').textContent = 'Request #' + data.dm_request_id;

    var html = '<div class="bsv-detail-grid">';
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
    html += '<div class="bsv-detail-comment-section">';
    html += '<div class="bsv-detail-comment-label">Comment</div>';
    if (data.comment) {
        html += '<div class="bsv-detail-comment-text">' + cc_escapeHtml(data.comment) + '</div>';
    } else {
        html += '<div class="bsv-detail-comment-empty">No comment</div>';
    }
    html += '</div>';

    body.innerHTML = html;
}

/* Builds the HTML for a single label/value row in the request detail grid.
   Reused for every field rendered by bsv_renderRequestDetail. */
function bsv_detailRow(label, value) {
    return '<div class="bsv-detail-field"><span class="bsv-detail-label">' + label + '</span><span class="bsv-detail-value">' + cc_escapeHtml(value) + '</span></div>';
}

/* Closes the request detail modal. Wired from the close button and the overlay
   backdrop via the bsv-close-modal click action. The dispatcher passes the
   matched action element as target. When target is the overlay itself, the click
   is only a dismiss if it landed directly on the backdrop (event.target ===
   target); a click that bubbled up from the dialog interior is ignored. When
   target is the close button, the modal always closes. */
function bsv_closeDetailModal(target, event) {
    if (event && target.id === 'bsv-modal-detail' && event.target !== target) {
        return;
    }
    document.getElementById('bsv-modal-detail').classList.add('cc-hidden');
}

/* ============================================================================
   FUNCTIONS: SLIDEOUT PANEL
   ----------------------------------------------------------------------------
   The slideout panel that presents the day-detail view. Distinct from the
   request detail modal: the slideout slides in from the right over a dimmer,
   while the modal is a centered overlay. The slideout reuses one dialog for
   both the day summary and per-user request views. Open and close follow the
   shared static slide-overlay pattern (cc-open on the overlay and on the inner
   cc-dialog, with a transitionend-driven close).
   Prefix: bsv
   ============================================================================ */

/* Opens the slideout panel with a given title and a loading state in the body.
   Adds cc-open to the overlay, then adds cc-open to the inner cc-dialog inside
   a requestAnimationFrame callback so the slide-in transition runs. Callers
   populate the body once their data lands. */
function bsv_openSlideout(title) {
    document.getElementById('bsv-detail-slideout-title').textContent = title;
    document.getElementById('bsv-detail-slideout-body').innerHTML = '<div class="bsv-loading">Loading...</div>';

    var overlay = document.getElementById('bsv-slideout-detail');
    var dialog = overlay.querySelector('.cc-dialog');
    overlay.classList.add('cc-open');
    requestAnimationFrame(function() {
        dialog.classList.add('cc-open');
    });
}

/* Closes the slideout panel. Attaches a one-shot transitionend listener to the
   inner cc-dialog that removes cc-open from the overlay once the slide-out
   transition finishes, then removes cc-open from the dialog to start it. Wired
   from the close button and the overlay backdrop via the bsv-close-slideout
   click action. The dispatcher passes the matched action element as target. When
   target is the overlay itself, the click is only a dismiss if it landed
   directly on the backdrop (event.target === target); a click that bubbled up
   from the dialog interior is ignored. When target is the close button, the
   slideout always closes. */
function bsv_closeSlideout(target, event) {
    if (event && target.id === 'bsv-slideout-detail' && event.target !== target) {
        return;
    }
    var overlay = document.getElementById('bsv-slideout-detail');
    var dialog = overlay.querySelector('.cc-dialog');
    dialog.addEventListener('transitionend', function handler() {
        dialog.removeEventListener('transitionend', handler);
        overlay.classList.remove('cc-open');
    });
    dialog.classList.remove('cc-open');
}

/* ============================================================================
   FUNCTIONS: UTILITIES
   ----------------------------------------------------------------------------
   Page-local helpers: timestamp display, the inline connection-error banner,
   and MM/DD/YYYY display formatting. The standard cc_escapeHtml from
   cc-shared.js handles HTML escaping.
   Prefix: bsv
   ============================================================================ */

/* Updates the live "last updated" timestamp display in the page header. The
   expected input is a localized time string; if a full timestamp
   ('YYYY-MM-DD HH:MM:SS') is passed in, only the time portion is shown. */
function bsv_updateTimestamp(ts) {
    var el = document.getElementById('cc-last-update');
    if (el && ts) {
        var parts = ts.split(' ');
        el.textContent = parts.length > 1 ? parts[1] : ts;
    }
}

/* Shows the inline connection error message inside the live-activity content
   area. Used when the live-activity API call fails outside of session expiry,
   which is handled by cc-shared.js. */
function bsv_showConnectionError(msg) {
    var el = document.getElementById('bsv-connection-error');
    if (!el) return;
    el.textContent = msg;
    el.classList.remove('bsv-hidden');
}

/* Hides the inline connection error message. Called on successful
   live-activity load. */
function bsv_clearConnectionError() {
    var el = document.getElementById('bsv-connection-error');
    if (!el) return;
    el.classList.add('bsv-hidden');
}

/* Formats an ISO date string (YYYY-MM-DD) as a US display date (MM/DD/YYYY).
   Returns the input unchanged if it does not split cleanly into three parts. */
function bsv_formatDisplayDate(dateStr) {
    if (!dateStr) return '';
    var parts = dateStr.split('-');
    if (parts.length === 3) return parts[1] + '/' + parts[2] + '/' + parts[0];
    return dateStr;
}

/* ============================================================================
   FUNCTIONS: PAGE LIFECYCLE HOOKS
   ----------------------------------------------------------------------------
   Hooks invoked by cc-shared.js. The shared module resolves each via
   window['bsv_<hook>'] and calls it at the appropriate moment in the page
   lifecycle.
   Prefix: bsv
   ============================================================================ */

/* Called by cc-shared.js when the user clicks the page refresh button.
   cc-shared.js drives the spin animation; this hook does the actual data
   reload. */
function bsv_onPageRefresh() {
    bsv_refreshAll();
}

/* Called by cc-shared.js when the page becomes visible again after being
   hidden. cc-shared.js drives the spin animation; this hook does the actual
   data reload so the user sees current data. */
function bsv_onPageResumed() {
    bsv_refreshAll();
}

/* Called by cc-shared.js when the session is detected as expired. Stops the
   live-polling timer so we do not keep firing fetches that cc_engineFetch will
   short-circuit. */
function bsv_onSessionExpired() {
    bsv_stopLivePolling();
}

/* Called by cc-shared.js when an orchestrator process listed in
   bsv_ENGINE_PROCESSES completes. Refreshes the event-driven sections
   (Distribution and History) since fresh data is now available. */
function bsv_onEngineProcessCompleted(processName, event) {
    bsv_refreshEventSections();
}

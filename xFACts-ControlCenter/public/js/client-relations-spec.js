/* ============================================================================
   xFACts Control Center - Client Relations JavaScript (client-relations.js)
   Location: E:\xFACts-ControlCenter\public\js\client-relations.js
   Version: Tracked in dbo.System_Metadata (component: DeptOps.ClientRelations)

   Page-specific JS for the Client Relations departmental page. Universal
   chrome (WebSocket events, connection banner, page refresh button, idle
   detection, session expiry, shared modals, formatting utilities) is
   provided by cc-shared.js. This file contains data loading and
   rendering logic for the Reg F queue display: summary cards, the
   reason-filter badges, the consumer/account expandable queue table,
   and the search/filter behavior.

   FILE ORGANIZATION
   -----------------
   CONSTANTS: ENGINE PROCESSES
   CONSTANTS: PAGE CONFIGURATION
   STATE: PAGE STATE
   INITIALIZATION: PAGE BOOT
   FUNCTIONS: LIVE POLLING
   FUNCTIONS: DATA LOADING
   FUNCTIONS: CONSUMER GROUPING
   FUNCTIONS: SUMMARY CARDS
   FUNCTIONS: REASON FILTER BADGES
   FUNCTIONS: QUEUE TABLE
   FUNCTIONS: FILTERING
   FUNCTIONS: UTILITIES
   FUNCTIONS: PAGE LIFECYCLE HOOKS
   ============================================================================ */

/* ============================================================================
   CONSTANTS: ENGINE PROCESSES
   ----------------------------------------------------------------------------
   The ENGINE_PROCESSES contract: a map from orchestrator process names to
   engine card slugs that cc-shared.js reads at startup to wire up the
   engine indicator subsystem. The Client Relations page has no
   orchestrator-driven collectors today, so the map is empty; the banner
   and declaration are still required because cc-shared.js's
   connectEngineEvents() reads the identifier by exact name on init.
   Prefix: (none)
   ============================================================================ */

/* Maps orchestrator process names to engine card slugs. cc-shared.js
   reads this at startup; an empty object means no engine cards on this
   page. Future collectors get added here together with their
   onEngineProcessCompleted hook. */
const ENGINE_PROCESSES = {};

/* ============================================================================
   CONSTANTS: PAGE CONFIGURATION
   ----------------------------------------------------------------------------
   Module-level configuration constants for this page. The refresh
   interval default is overwritten at load time from GlobalConfig.
   Prefix: clr
   ============================================================================ */

/* Default live-polling interval in seconds. Overwritten at page load by
   clr_loadRefreshInterval from GlobalConfig (ControlCenter |
   refresh_clientrelations_seconds). 1800 = 30 minutes; the queue is
   slow-changing so frequent polls would be wasted. */
const clr_PAGE_REFRESH_INTERVAL_DEFAULT = 1800;

/* ============================================================================
   STATE: PAGE STATE
   ----------------------------------------------------------------------------
   Module-scope mutable state for the Reg F queue UI: the live-poll timer
   handle, page-load date for midnight rollover detection, the cached
   query result rows, the consumer-grouped index built from those rows,
   the per-consumer expand/collapse state, and the active filter values.
   Prefix: clr
   ============================================================================ */

/* Effective refresh interval in seconds. Starts at the default and is
   overwritten by clr_loadRefreshInterval if GlobalConfig has a value. */
var clr_pageRefreshInterval = clr_PAGE_REFRESH_INTERVAL_DEFAULT;

/* setInterval handle for the live-polling timer, or null when not
   running. */
var clr_livePollingTimer = null;

/* setInterval handle for the midnight-rollover check. */
var clr_autoRefreshTimer = null;

/* Date string captured at page load. Compared against the current date
   inside the auto-refresh timer to trigger a full reload at midnight. */
var clr_pageLoadDate = new Date().toDateString();

/* Cached account-level rows from the most recent /api/client-relations/regf-queue
   response. Source data for the consumer grouping rebuild. */
var clr_allRows = [];

/* Consumer-grouped index built from clr_allRows: keyed by consumer
   number, each entry holds { consumer fields, accounts: [...] }. Rebuilt
   on every successful queue load. */
var clr_consumerGroups = {};

/* Per-consumer expand/collapse state for the queue table. Keyed by
   consumer number; truthy value means the consumer's accounts sub-table
   is currently expanded. */
var clr_expandedConsumers = {};

/* Active rejection-reason filter for the queue table. 'ALL' shows every
   account; any other value filters to accounts whose rejection_reason
   matches. */
var clr_activeReasonFilter = 'ALL';

/* Active search term for the queue table, lowercased and trimmed. Empty
   string means no search filter. */
var clr_searchTerm = '';

/* ============================================================================
   INITIALIZATION: PAGE BOOT
   ----------------------------------------------------------------------------
   Single DOMContentLoaded handler that does the page's first data load,
   reads the refresh interval from GlobalConfig, starts the auto-refresh
   and live-polling timers, registers the engine-events chrome with
   cc-shared.js, and binds the search input listener.
   Prefix: (none)
   ============================================================================ */

document.addEventListener('DOMContentLoaded', function() {
    clr_loadRegFQueue();

    clr_loadRefreshInterval();
    clr_startAutoRefresh();
    clr_startLivePolling();
    connectEngineEvents();

    /* Search input - re-renders on each keystroke. */
    document.getElementById('queue-search').addEventListener('input', function() {
        clr_searchTerm = this.value.trim().toLowerCase();
        clr_renderQueue();
    });

    /* Delegated click on the reason-filters container. The badges are
       re-rendered into innerHTML on every refresh, so binding here once
       on the stable container survives re-renders without listener
       accumulation. */
    document.getElementById('reason-filters').addEventListener('click', function(e) {
        var badge = e.target.closest('.filter-badge');
        if (!badge || !this.contains(badge)) return;
        var prev = this.querySelector('.filter-badge.active');
        if (prev) prev.classList.remove('active');
        badge.classList.add('active');
        clr_activeReasonFilter = badge.getAttribute('data-reason');
        clr_renderQueue();
    });

    /* Delegated click on the queue-table container. The consumer rows are
       re-rendered into innerHTML on every refresh, so binding here once
       on the stable container survives re-renders without listener
       accumulation. */
    document.getElementById('queue-table').addEventListener('click', function(e) {
        var row = e.target.closest('.consumer-row');
        if (!row || !this.contains(row)) return;
        var consumerKey = row.getAttribute('data-consumer');
        clr_expandedConsumers[consumerKey] = !clr_expandedConsumers[consumerKey];
        clr_renderQueue();
    });
});

/* ============================================================================
   FUNCTIONS: LIVE POLLING
   ----------------------------------------------------------------------------
   The page's refresh loop. Live polling reloads the queue at the
   configured interval; the auto-refresh timer reloads the entire page at
   midnight to pick up the new day's queue rows. The refresh-interval
   loader pulls the page-specific interval from GlobalConfig at startup.
   Prefix: clr
   ============================================================================ */

/* Loads the page-specific refresh interval from GlobalConfig via the
   shared refresh-interval API. Falls back to the default constant if
   the API is unavailable. */
async function clr_loadRefreshInterval() {
    try {
        var data = await engineFetch('/api/config/refresh-interval?page=clientrelations');
        if (data) {
            clr_pageRefreshInterval = data.interval || clr_PAGE_REFRESH_INTERVAL_DEFAULT;
        }
    } catch (e) {
        /* API unavailable - default already in effect. */
    }
}

/* Starts the midnight-rollover check. Lightweight 60-second timer that
   reloads the page when the date changes - cheaper than rebuilding the
   queue UI from a cross-day query result set. */
function clr_startAutoRefresh() {
    clr_autoRefreshTimer = setInterval(function() {
        var today = new Date().toDateString();
        if (today !== clr_pageLoadDate) {
            window.location.reload();
        }
    }, 60000);
}

/* Starts the live-polling timer that reloads the queue at the configured
   interval. Skips when the tab is hidden or the session is expired so
   we don't burn fetches that engineFetch would short-circuit anyway. */
function clr_startLivePolling() {
    if (clr_livePollingTimer) clearInterval(clr_livePollingTimer);
    clr_livePollingTimer = setInterval(function() {
        if (enginePageHidden || engineSessionExpired) return;
        clr_loadRegFQueue();
    }, clr_pageRefreshInterval * 1000);
}

/* Stops live polling. Called by the onSessionExpired hook when
   cc-shared.js detects the session has expired so we don't keep
   firing fetches that will be short-circuited. */
function clr_stopLivePolling() {
    if (clr_livePollingTimer) {
        clearInterval(clr_livePollingTimer);
        clr_livePollingTimer = null;
    }
}

/* Refreshes everything on the page. Called by the manual refresh button
   (via the onPageRefresh hook) and by the onPageResumed hook on tab
   resume. Forces a fresh fetch to bypass any server-side cache. */
function clr_refreshAll() {
    clr_loadRegFQueue(true);
}

/* ============================================================================
   FUNCTIONS: DATA LOADING
   ----------------------------------------------------------------------------
   Single API call that returns the entire current Reg F queue. The
   response is cached into clr_allRows, the consumer-grouped index is
   rebuilt, and every section of the page is re-rendered from the new
   data.
   Prefix: clr
   ============================================================================ */

/* Loads the Reg F queue from the API and re-renders every section. The
   forceRefresh flag passes through to the API to bypass server-side
   cache; used for manual refresh and on-resume so the user always sees
   current data. */
function clr_loadRegFQueue(forceRefresh) {
    var url = '/api/client-relations/regf-queue';
    if (forceRefresh) url += '?refresh=true';

    engineFetch(url)
        .then(function(data) {
            if (!data) return;
            clr_clearConnectionError();
            clr_allRows = data.rows || [];
            clr_buildConsumerGroups();
            clr_renderSummaryCards();
            clr_renderReasonFilters();
            clr_renderQueue();
            clr_updateTimestamp(data.timestamp);
        })
        .catch(function(err) {
            clr_showConnectionError('Failed to load Reg F queue: ' + err.message);
        });
}

/* ============================================================================
   FUNCTIONS: CONSUMER GROUPING
   ----------------------------------------------------------------------------
   The query returns one row per account. Accounts share a consumer
   (one consumer can have many accounts). The UI groups by consumer and
   renders each consumer as a parent row with an expandable sub-table of
   their accounts.
   Prefix: clr
   ============================================================================ */

/* Rebuilds clr_consumerGroups from clr_allRows. Each unique
   consumer_number becomes a group entry holding the consumer's display
   fields plus an array of that consumer's account rows. The earliest
   queue_date across the consumer's accounts is hoisted to the consumer
   level for sorting. */
function clr_buildConsumerGroups() {
    clr_consumerGroups = {};

    for (var i = 0; i < clr_allRows.length; i++) {
        var row = clr_allRows[i];
        var key = row.consumer_number || '(Unknown)';

        if (!clr_consumerGroups[key]) {
            clr_consumerGroups[key] = {
                consumer_number: row.consumer_number,
                consumer_name: row.consumer_name,
                company: row.company,
                queue_date: row.queue_date,
                queue_reason: row.queue_reason,
                letter: row.letter,
                letter_strategy: row.letter_strategy,
                accounts: []
            };
        }
        clr_consumerGroups[key].accounts.push(row);

        /* Keep earliest queue_date at consumer level. */
        if (row.queue_date && clr_compareDates(row.queue_date, clr_consumerGroups[key].queue_date) < 0) {
            clr_consumerGroups[key].queue_date = row.queue_date;
        }
    }

    /* Sort accounts within each consumer by queue_date ASC. */
    var keys = Object.keys(clr_consumerGroups);
    for (var k = 0; k < keys.length; k++) {
        clr_consumerGroups[keys[k]].accounts.sort(function(a, b) {
            return clr_compareDates(a.queue_date, b.queue_date);
        });
    }
}

/* ============================================================================
   FUNCTIONS: SUMMARY CARDS
   ----------------------------------------------------------------------------
   Top-of-page summary tiles: total consumers, total accounts, and a
   per-rejection-reason breakdown. Threshold-based coloring (warning at
   medium counts, critical at high counts) is applied to the consumer
   and account totals.
   Prefix: clr
   ============================================================================ */

/* Renders the summary cards above the queue table. Uses
   clr_consumerGroups for the consumer count and clr_allRows for the
   account totals and rejection-reason breakdown. */
function clr_renderSummaryCards() {
    var container = document.getElementById('summary-cards');
    var loading = document.getElementById('summary-loading');

    var totalAccounts = clr_allRows.length;
    var totalConsumers = Object.keys(clr_consumerGroups).length;

    /* Count accounts by rejection_reason. */
    var reasonCounts = {};
    for (var i = 0; i < clr_allRows.length; i++) {
        var reason = clr_allRows[i].rejection_reason || 'Unknown';
        reasonCounts[reason] = (reasonCounts[reason] || 0) + 1;
    }

    var html = '';

    /* Total Consumers card with threshold coloring. */
    var consumerClass = totalConsumers > 500 ? 'card-critical' : (totalConsumers > 250 ? 'card-warning' : '');
    html += '<div class="summary-card ' + consumerClass + '">';
    html += '  <div class="summary-card-value">' + totalConsumers.toLocaleString() + '</div>';
    html += '  <div class="summary-card-label">Consumers</div>';
    html += '</div>';

    /* Total Accounts card with threshold coloring. */
    var accountClass = totalAccounts > 1000 ? 'card-critical' : (totalAccounts > 500 ? 'card-warning' : '');
    html += '<div class="summary-card ' + accountClass + '">';
    html += '  <div class="summary-card-value">' + totalAccounts.toLocaleString() + '</div>';
    html += '  <div class="summary-card-label">Accounts</div>';
    html += '</div>';

    /* Reason breakdown cards in canonical order. */
    var reasonOrder = [
        'Zero Dollar Original Charges Received',
        'No Reg F Data In DM',
        'Unaccounted For Balance Discrepancy',
        'Letter Requested',
        'Other Reason'
    ];

    for (var r = 0; r < reasonOrder.length; r++) {
        var orderedReason = reasonOrder[r];
        var count = reasonCounts[orderedReason] || 0;
        if (count === 0) continue;

        html += '<div class="summary-card">';
        html += '  <div class="summary-card-value">' + count.toLocaleString() + '</div>';
        html += '  <div class="summary-card-label">' + clr_getReasonShortName(orderedReason) + '</div>';
        html += '</div>';
    }

    /* Any reasons not in the canonical list. */
    var knownReasons = {};
    for (var r2 = 0; r2 < reasonOrder.length; r2++) { knownReasons[reasonOrder[r2]] = true; }
    var otherKeys = Object.keys(reasonCounts);
    for (var o = 0; o < otherKeys.length; o++) {
        if (!knownReasons[otherKeys[o]]) {
            html += '<div class="summary-card">';
            html += '  <div class="summary-card-value">' + reasonCounts[otherKeys[o]].toLocaleString() + '</div>';
            html += '  <div class="summary-card-label">' + escapeHtml(otherKeys[o]) + '</div>';
            html += '</div>';
        }
    }

    loading.classList.add('hidden');
    container.innerHTML = html;
    container.classList.remove('hidden');
}

/* Maps a full rejection-reason string to its short display label. Used
   on summary cards and in account sub-tables where horizontal space is
   tight. */
function clr_getReasonShortName(reason) {
    var names = {
        'Zero Dollar Original Charges Received': 'Zero Dollar',
        'No Reg F Data In DM': 'No Reg F Data',
        'Unaccounted For Balance Discrepancy': 'Balance Discrepancy',
        'Letter Requested': 'Letter Requested',
        'Other Reason': 'Other'
    };
    return names[reason] || reason;
}

/* ============================================================================
   FUNCTIONS: REASON FILTER BADGES
   ----------------------------------------------------------------------------
   Pill badges below the summary cards for filtering the queue table by
   account-level rejection reason. The 'All' badge is always present;
   one badge per distinct reason in the current data set.
   Prefix: clr
   ============================================================================ */

/* Renders the reason filter badges and binds their click handlers.
   Badges are computed from clr_allRows so the set adapts to the current
   data. */
function clr_renderReasonFilters() {
    var container = document.getElementById('reason-filters');

    /* Collect unique rejection reasons. */
    var reasons = {};
    for (var i = 0; i < clr_allRows.length; i++) {
        var reason = clr_allRows[i].rejection_reason || 'Unknown';
        reasons[reason] = (reasons[reason] || 0) + 1;
    }

    var html = '<span class="filter-badge' + (clr_activeReasonFilter === 'ALL' ? ' active' : '') + '" data-reason="ALL">All</span>';

    var sortedReasons = Object.keys(reasons).sort();
    for (var r = 0; r < sortedReasons.length; r++) {
        var sortedReason = sortedReasons[r];
        var isActive = clr_activeReasonFilter === sortedReason ? ' active' : '';
        html += '<span class="filter-badge' + isActive + '" data-reason="' + clr_escapeAttr(sortedReason) + '">' + clr_getReasonShortName(sortedReason) + '</span>';
    }

    container.innerHTML = html;
}

/* ============================================================================
   FUNCTIONS: QUEUE TABLE
   ----------------------------------------------------------------------------
   Two-level table: the main rows are consumers (one per consumer
   number); each consumer can be expanded to show a sub-table of their
   accounts. Sorting is by earliest queue_date ASC at the consumer level
   and within each consumer's account list.
   Prefix: clr
   ============================================================================ */

/* Renders the consumer/account queue table with expand-on-click rows.
   Applies the active reason filter and search term, sorts by earliest
   queue_date, and binds the click handler that toggles each consumer's
   expanded state. */
function clr_renderQueue() {
    var container = document.getElementById('queue-table');
    var loading = document.getElementById('queue-loading');

    var filtered = clr_getFilteredGroups();
    var sortedKeys = Object.keys(filtered).sort(function(a, b) {
        return clr_compareDates(filtered[a].queue_date, filtered[b].queue_date);
    });

    if (sortedKeys.length === 0) {
        loading.classList.add('hidden');
        container.innerHTML = '<div class="no-data">No consumers match the current filters</div>';
        container.classList.remove('hidden');
        return;
    }

    var html = '<table class="queue-table">';
    html += '<thead><tr>';
    html += '<th class="col-expand"></th>';
    html += '<th>Letter</th>';
    html += '<th>Queue Date</th>';
    html += '<th>Queue Reason</th>';
    html += '<th>Consumer #</th>';
    html += '<th>Consumer Name</th>';
    html += '<th>Company</th>';
    html += '<th>Letter Strategy</th>';
    html += '<th class="col-count">Accounts</th>';
    html += '</tr></thead>';
    html += '<tbody>';

    for (var i = 0; i < sortedKeys.length; i++) {
        var key = sortedKeys[i];
        var group = filtered[key];
        var acctCount = group.accounts.length;
        var isExpanded = clr_expandedConsumers[key] || false;

        html += '<tr class="consumer-row" data-consumer="' + clr_escapeAttr(key) + '">';
        html += '<td class="col-expand"><span class="expand-icon">' + (isExpanded ? '&#9660;' : '&#9654;') + '</span></td>';
        html += '<td>' + escapeHtml(group.letter || '-') + '</td>';
        html += '<td>' + (group.queue_date || '-') + '</td>';
        html += '<td><span class="reason-badge reason-' + clr_getQueueReasonClass(group.queue_reason) + '">' + escapeHtml(group.queue_reason || '-') + '</span></td>';
        html += '<td>' + escapeHtml(group.consumer_number || '-') + '</td>';
        html += '<td>' + escapeHtml(group.consumer_name || '-') + '</td>';
        html += '<td>' + escapeHtml(group.company || '-') + '</td>';
        html += '<td>' + escapeHtml(group.letter_strategy || '-') + '</td>';
        html += '<td class="col-count"><span class="account-count-badge">' + acctCount + '</span></td>';
        html += '</tr>';

        /* Account detail rows - sub-table with column order matching query output. */
        if (isExpanded) {
            html += '<tr class="account-row">';
            html += '<td></td>';
            html += '<td colspan="8">';
            html += '<div class="account-detail-container">';
            html += '<table class="account-sub-table">';
            html += '<thead><tr>';
            html += '<th>Letter</th>';
            html += '<th>Queue Date</th>';
            html += '<th>Rejection Reason</th>';
            html += '<th>NB Batch</th>';
            html += '<th>Account #</th>';
            html += '<th>Creditor Ref</th>';
            html += '<th>Creditor Group</th>';
            html += '<th>Creditor</th>';
            html += '<th>Creditor Name</th>';
            html += '<th>Letter Strategy</th>';
            html += '<th>Placement</th>';
            html += '<th>Released</th>';
            html += '<th>Bal at DoS</th>';
            html += '<th>Fees</th>';
            html += '<th>Interest</th>';
            html += '<th>Current Bal</th>';
            html += '<th>Payments</th>';
            html += '</tr></thead>';
            html += '<tbody>';

            for (var j = 0; j < group.accounts.length; j++) {
                var acct = group.accounts[j];
                html += '<tr>';
                html += '<td>' + escapeHtml(acct.letter || '-') + '</td>';
                html += '<td>' + (acct.queue_date || '-') + '</td>';
                html += '<td><span class="reason-badge reason-' + clr_getReasonClass(acct.rejection_reason) + '">' + clr_getReasonShortName(acct.rejection_reason || '-') + '</span></td>';
                html += '<td>' + escapeHtml(acct.new_business_batch || '-') + '</td>';
                html += '<td>' + escapeHtml(acct.consumer_account_number || '-') + '</td>';
                html += '<td>' + escapeHtml(acct.creditor_reference || '-') + '</td>';
                html += '<td>' + escapeHtml(acct.creditor_group || '-') + '</td>';
                html += '<td>' + escapeHtml(acct.creditor || '-') + '</td>';
                html += '<td>' + escapeHtml(acct.creditor_name || '-') + '</td>';
                html += '<td>' + escapeHtml(acct.letter_strategy || '-') + '</td>';
                html += '<td>' + (acct.placement_date || '-') + '</td>';
                html += '<td>' + (acct.date_released || '-') + '</td>';
                html += '<td class="text-right">' + clr_formatCurrency(acct.bal_at_dos) + '</td>';
                html += '<td class="text-right">' + clr_formatCurrency(acct.calculated_fees) + '</td>';
                html += '<td class="text-right">' + clr_formatCurrency(acct.calculated_interest) + '</td>';
                html += '<td class="text-right">' + clr_formatCurrency(acct.current_balance) + '</td>';
                html += '<td class="text-right">' + clr_formatCurrency(acct.calculated_payments) + '</td>';
                html += '</tr>';
            }

            html += '</tbody></table>';
            html += '</div>';
            html += '</td>';
            html += '</tr>';
        }
    }

    html += '</tbody></table>';

    loading.classList.add('hidden');
    container.innerHTML = html;
    container.classList.remove('hidden');
}

/* ============================================================================
   FUNCTIONS: FILTERING
   ----------------------------------------------------------------------------
   Composite filter pipeline applied to the consumer-grouped data: first
   account-level filtering by rejection reason, then consumer-level
   filtering by search term. Consumers whose accounts all get filtered
   out of the rejection-reason pass are dropped entirely.
   Prefix: clr
   ============================================================================ */

/* Returns a filtered copy of clr_consumerGroups: applies the active
   rejection-reason filter at account level, then the search term at
   consumer level. Consumers with no accounts after the reason filter
   are excluded. */
function clr_getFilteredGroups() {
    var filtered = {};
    var keys = Object.keys(clr_consumerGroups);

    for (var i = 0; i < keys.length; i++) {
        var key = keys[i];
        var group = clr_consumerGroups[key];

        /* Filter accounts by rejection reason. */
        var matchingAccounts = [];
        for (var j = 0; j < group.accounts.length; j++) {
            var acct = group.accounts[j];

            if (clr_activeReasonFilter !== 'ALL' && acct.rejection_reason !== clr_activeReasonFilter) {
                continue;
            }
            matchingAccounts.push(acct);
        }

        if (matchingAccounts.length === 0) continue;

        /* Apply search filter at consumer level. */
        if (clr_searchTerm) {
            var haystack = (
                (group.consumer_number || '') + ' ' +
                (group.consumer_name || '') + ' ' +
                (group.company || '')
            ).toLowerCase();

            if (haystack.indexOf(clr_searchTerm) === -1) continue;
        }

        filtered[key] = {
            consumer_number: group.consumer_number,
            consumer_name: group.consumer_name,
            company: group.company,
            queue_date: group.queue_date,
            queue_reason: group.queue_reason,
            letter: group.letter,
            letter_strategy: group.letter_strategy,
            accounts: matchingAccounts
        };
    }

    return filtered;
}

/* ============================================================================
   FUNCTIONS: UTILITIES
   ----------------------------------------------------------------------------
   Page-local helpers: timestamp display, the inline connection-error
   banner, attribute-safe escaping (the standard escapeHtml in
   cc-shared.js encodes characters that are valid inside attribute
   values, so this page keeps its own narrower escape for that one use),
   currency formatting, MM/DD/YYYY date parsing and comparison, and
   reason-class lookups for badge styling.
   Prefix: clr
   ============================================================================ */

/* Updates the live "last updated" timestamp display in the header bar. */
function clr_updateTimestamp(ts) {
    document.getElementById('last-update').textContent = ts || '-';
}

/* Shows the inline connection error banner with a message. Used when
   the queue API call fails outside of session-expiry, which is handled
   by cc-shared.js. */
function clr_showConnectionError(msg) {
    var el = document.getElementById('connection-error');
    el.textContent = msg;
    el.classList.add('visible');
}

/* Hides the inline connection error banner. Called on successful queue
   load. */
function clr_clearConnectionError() {
    var el = document.getElementById('connection-error');
    el.textContent = '';
    el.classList.remove('visible');
}

/* Attribute-safe escaping for values placed inside HTML attribute
   contexts (e.g., data-* attributes on filter badges). Narrower than
   cc-shared.js's escapeHtml: only escapes & and " because attribute
   contexts don't require escaping < or >. */
function clr_escapeAttr(str) {
    if (str === null || str === undefined) return '';
    return String(str).replace(/&/g, '&amp;').replace(/"/g, '&quot;');
}

/* Formats a numeric value as a US-format currency string ($1,234.56).
   Returns '-' for null/undefined/empty values. Returns the original
   value as a fallback if it can't be parsed as a number. */
function clr_formatCurrency(val) {
    if (val === null || val === undefined || val === '') return '-';
    var num = parseFloat(val);
    if (isNaN(num)) return val;
    return '$' + num.toFixed(2).replace(/\B(?=(\d{3})+(?!\d))/g, ',');
}

/* Compares two MM/DD/YYYY date strings, returning a negative, zero, or
   positive number per Array.sort convention. Null/empty dates sort
   after non-null dates. */
function clr_compareDates(a, b) {
    if (!a && !b) return 0;
    if (!a) return 1;
    if (!b) return -1;
    var pa = clr_parseDateMdy(a);
    var pb = clr_parseDateMdy(b);
    return pa - pb;
}

/* Parses an MM/DD/YYYY string to a millisecond timestamp. Returns 0
   for null/empty/malformed input. */
function clr_parseDateMdy(str) {
    if (!str) return 0;
    var parts = str.split('/');
    if (parts.length !== 3) return 0;
    return new Date(parseInt(parts[2]), parseInt(parts[0]) - 1, parseInt(parts[1])).getTime();
}

/* Maps a queue_reason string to a CSS class suffix used by the
   reason-badge styling. Currently 'letter' for 'Letter Requested' and
   'other' for everything else. */
function clr_getQueueReasonClass(reason) {
    if (!reason) return 'other';
    if (reason === 'Letter Requested') return 'letter';
    return 'other';
}

/* Maps a rejection_reason string to a CSS class suffix used by the
   reason-badge styling on account-level rows. */
function clr_getReasonClass(reason) {
    if (!reason) return 'other';
    if (reason.indexOf('Zero Dollar') >= 0) return 'zero-dollar';
    if (reason.indexOf('No Reg F') >= 0) return 'no-data';
    if (reason.indexOf('Unaccounted') >= 0) return 'discrepancy';
    if (reason.indexOf('Letter') >= 0) return 'letter';
    return 'other';
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
    clr_refreshAll();
}

/* Called by cc-shared.js when the page becomes visible again after
   being hidden. cc-shared.js drives the spin animation; this hook
   does the actual data reload so the user sees current data. */
function onPageResumed() {
    clr_refreshAll();
}

/* Called by cc-shared.js when the session is detected as expired.
   Stops the live-polling timer so we don't keep firing fetches that
   engineFetch will short-circuit. */
function onSessionExpired() {
    clr_stopLivePolling();
}

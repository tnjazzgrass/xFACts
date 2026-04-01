/* ============================================================================
   xFACts Control Center - Client Relations JavaScript
   Location: E:\xFACts-ControlCenter\public\js\client-relations.js
   Version: Tracked in dbo.System_Metadata (component: DeptOps.ClientRelations)
   ============================================================================ */

// ============================================================================
// CONFIGURATION
// ============================================================================

// ENGINE_PROCESSES: maps orchestrator process names to card slugs.
// Empty for now -- plumbing ready for future collectors.
var ENGINE_PROCESSES = {};

// Live polling (Refresh Architecture)
var PAGE_REFRESH_INTERVAL = 1800;   // Default 30 min; overridden by GlobalConfig on load

// Page hooks for engine-events.js shared module
function onPageResumed() { pageRefresh(); }
function onSessionExpired() { stopPolling(); }
var livePollingTimer = null;
var pageLoadDate = new Date().toDateString();

// State
var allRows = [];
var consumerGroups = {};
var expandedConsumers = {};
var activeReasonFilter = 'ALL';
var searchTerm = '';

// ============================================================================
// INITIALIZATION
// ============================================================================
document.addEventListener('DOMContentLoaded', function() {
    loadRegFQueue();

    loadRefreshInterval();
    startAutoRefresh();
    startLivePolling();
    connectEngineEvents();
    initEngineCardClicks();

    // Search input
    document.getElementById('queue-search').addEventListener('input', function() {
        searchTerm = this.value.trim().toLowerCase();
        renderQueue();
    });
});

// ============================================================================
// REFRESH ARCHITECTURE
// ============================================================================

/**
 * Midnight rollover check -- reloads the page when the date changes.
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
 * Ready for future collectors -- refreshes all event-driven sections.
 */
function onEngineProcessCompleted(processName, event) {
    refreshEventSections();
}

/**
 * Refreshes all event-driven sections.
 * No event-driven sections yet -- placeholder for future collectors.
 */
function refreshEventSections() {
    // Future: refresh sections populated by xFACts collectors
}

/**
 * Refreshes all live polling sections.
 */
function refreshLiveSections() {
    loadRegFQueue();
}

/**
 * Refreshes all sections -- called by page refresh button.
 * Uses forceRefresh to bypass server-side cache.
 */
function refreshAll() {
    loadRegFQueue(true);
}

/**
 * Page-level refresh button handler with spinner animation.
 * Bypasses cache for manual refresh.
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
        var data = await engineFetch('/api/config/refresh-interval?page=clientrelations');
        if (data) {
            // engineFetch handles auth and returns parsed JSON
            PAGE_REFRESH_INTERVAL = data.interval || 1800;
        }
    } catch (e) {
        // API unavailable -- use default
    }
}

/**
 * Starts the live polling timer.
 * Uses normal (non-forced) refresh to leverage server-side cache.
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
// DATA LOADING
// ============================================================================
function loadRegFQueue(forceRefresh) {
    var url = '/api/client-relations/regf-queue';
    if (forceRefresh) url += '?refresh=true';
    
    engineFetch(url)
        .then(function(data) {
            if (!data) return;
            clearConnectionError();
            allRows = data.rows || [];
            buildConsumerGroups();
            renderSummaryCards();
            renderReasonFilters();
            renderQueue();
            updateTimestamp(data.timestamp);
        })
        .catch(function(err) {
            showConnectionError('Failed to load Reg F queue: ' + err.message);
        });
}

// ============================================================================
// CONSUMER GROUPING
// ============================================================================
function buildConsumerGroups() {
    consumerGroups = {};
    
    for (var i = 0; i < allRows.length; i++) {
        var row = allRows[i];
        var key = row.consumer_number || '(Unknown)';
        
        if (!consumerGroups[key]) {
            consumerGroups[key] = {
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
        consumerGroups[key].accounts.push(row);
        
        // Keep earliest queue_date at consumer level
        if (row.queue_date && compareDates(row.queue_date, consumerGroups[key].queue_date) < 0) {
            consumerGroups[key].queue_date = row.queue_date;
        }
    }
    
    // Sort accounts within each consumer by queue_date ASC
    var keys = Object.keys(consumerGroups);
    for (var k = 0; k < keys.length; k++) {
        consumerGroups[keys[k]].accounts.sort(function(a, b) {
            return compareDates(a.queue_date, b.queue_date);
        });
    }
}

// ============================================================================
// SUMMARY CARDS
// ============================================================================
function renderSummaryCards() {
    var container = document.getElementById('summary-cards');
    var loading = document.getElementById('summary-loading');
    
    var totalAccounts = allRows.length;
    var totalConsumers = Object.keys(consumerGroups).length;
    
    // Count by rejection reason (account-level detail)
    var reasonCounts = {};
    for (var i = 0; i < allRows.length; i++) {
        var reason = allRows[i].rejection_reason || 'Unknown';
        reasonCounts[reason] = (reasonCounts[reason] || 0) + 1;
    }
    
    var html = '';
    
    // Total Consumers card - threshold coloring
    var consumerClass = totalConsumers > 500 ? 'card-critical' : (totalConsumers > 250 ? 'card-warning' : '');
    html += '<div class="summary-card ' + consumerClass + '">';
    html += '  <div class="summary-card-value">' + totalConsumers.toLocaleString() + '</div>';
    html += '  <div class="summary-card-label">Consumers</div>';
    html += '</div>';
    
    // Total Accounts card - threshold coloring
    var accountClass = totalAccounts > 1000 ? 'card-critical' : (totalAccounts > 500 ? 'card-warning' : '');
    html += '<div class="summary-card ' + accountClass + '">';
    html += '  <div class="summary-card-value">' + totalAccounts.toLocaleString() + '</div>';
    html += '  <div class="summary-card-label">Accounts</div>';
    html += '</div>';
    
    // Reason breakdown cards (account-level rejection reasons)
    var reasonOrder = [
        'Zero Dollar Original Charges Received',
        'No Reg F Data In DM',
        'Unaccounted For Balance Discrepancy',
        'Letter Requested',
        'Other Reason'
    ];
    
    for (var r = 0; r < reasonOrder.length; r++) {
        var reason = reasonOrder[r];
        var count = reasonCounts[reason] || 0;
        if (count === 0) continue;
        
        html += '<div class="summary-card">';
        html += '  <div class="summary-card-value">' + count.toLocaleString() + '</div>';
        html += '  <div class="summary-card-label">' + getReasonShortName(reason) + '</div>';
        html += '</div>';
    }
    
    // Any reasons not in our known list
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

function getReasonShortName(reason) {
    var names = {
        'Zero Dollar Original Charges Received': 'Zero Dollar',
        'No Reg F Data In DM': 'No Reg F Data',
        'Unaccounted For Balance Discrepancy': 'Balance Discrepancy',
        'Letter Requested': 'Letter Requested',
        'Other Reason': 'Other'
    };
    return names[reason] || reason;
}

// ============================================================================
// REASON FILTER BADGES
// ============================================================================
function renderReasonFilters() {
    var container = document.getElementById('reason-filters');
    
    // Collect unique rejection reasons (account-level)
    var reasons = {};
    for (var i = 0; i < allRows.length; i++) {
        var reason = allRows[i].rejection_reason || 'Unknown';
        reasons[reason] = (reasons[reason] || 0) + 1;
    }
    
    var html = '<span class="filter-badge' + (activeReasonFilter === 'ALL' ? ' active' : '') + '" data-reason="ALL">All</span>';
    
    var sortedReasons = Object.keys(reasons).sort();
    for (var r = 0; r < sortedReasons.length; r++) {
        var reason = sortedReasons[r];
        var isActive = activeReasonFilter === reason ? ' active' : '';
        html += '<span class="filter-badge' + isActive + '" data-reason="' + escapeAttr(reason) + '">' + getReasonShortName(reason) + '</span>';
    }
    
    container.innerHTML = html;
    
    // Bind click handlers
    container.querySelectorAll('.filter-badge').forEach(function(badge) {
        badge.addEventListener('click', function() {
            container.querySelectorAll('.filter-badge').forEach(function(b) { b.classList.remove('active'); });
            this.classList.add('active');
            activeReasonFilter = this.getAttribute('data-reason');
            renderQueue();
        });
    });
}

// ============================================================================
// QUEUE TABLE
// ============================================================================
function renderQueue() {
    var container = document.getElementById('queue-table');
    var loading = document.getElementById('queue-loading');
    
    var filtered = getFilteredGroups();
    var sortedKeys = Object.keys(filtered).sort(function(a, b) {
        return compareDates(filtered[a].queue_date, filtered[b].queue_date);
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
        var isExpanded = expandedConsumers[key] || false;
        
        html += '<tr class="consumer-row" data-consumer="' + escapeAttr(key) + '">';
        html += '<td class="col-expand"><span class="expand-icon">' + (isExpanded ? '&#9660;' : '&#9654;') + '</span></td>';
        html += '<td>' + escapeHtml(group.letter || '-') + '</td>';
        html += '<td>' + (group.queue_date || '-') + '</td>';
        html += '<td><span class="reason-badge reason-' + getQueueReasonClass(group.queue_reason) + '">' + escapeHtml(group.queue_reason || '-') + '</span></td>';
        html += '<td>' + escapeHtml(group.consumer_number || '-') + '</td>';
        html += '<td>' + escapeHtml(group.consumer_name || '-') + '</td>';
        html += '<td>' + escapeHtml(group.company || '-') + '</td>';
        html += '<td>' + escapeHtml(group.letter_strategy || '-') + '</td>';
        html += '<td class="col-count"><span class="account-count-badge">' + acctCount + '</span></td>';
        html += '</tr>';
        
        // Account detail rows -- sub-table with column order matching query output
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
                html += '<td><span class="reason-badge reason-' + getReasonClass(acct.rejection_reason) + '">' + getReasonShortName(acct.rejection_reason || '-') + '</span></td>';
                html += '<td>' + escapeHtml(acct.new_business_batch || '-') + '</td>';
                html += '<td>' + escapeHtml(acct.consumer_account_number || '-') + '</td>';
                html += '<td>' + escapeHtml(acct.creditor_reference || '-') + '</td>';
                html += '<td>' + escapeHtml(acct.creditor_group || '-') + '</td>';
                html += '<td>' + escapeHtml(acct.creditor || '-') + '</td>';
                html += '<td>' + escapeHtml(acct.creditor_name || '-') + '</td>';
                html += '<td>' + escapeHtml(acct.letter_strategy || '-') + '</td>';
                html += '<td>' + (acct.placement_date || '-') + '</td>';
                html += '<td>' + (acct.date_released || '-') + '</td>';
                html += '<td class="text-right">' + formatCurrency(acct.bal_at_dos) + '</td>';
                html += '<td class="text-right">' + formatCurrency(acct.calculated_fees) + '</td>';
                html += '<td class="text-right">' + formatCurrency(acct.calculated_interest) + '</td>';
                html += '<td class="text-right">' + formatCurrency(acct.current_balance) + '</td>';
                html += '<td class="text-right">' + formatCurrency(acct.calculated_payments) + '</td>';
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
    
    // Bind expand/collapse click handlers
    container.querySelectorAll('.consumer-row').forEach(function(row) {
        row.addEventListener('click', function() {
            var consumerKey = this.getAttribute('data-consumer');
            expandedConsumers[consumerKey] = !expandedConsumers[consumerKey];
            renderQueue();
        });
    });
}

// ============================================================================
// FILTERING
// ============================================================================
function getFilteredGroups() {
    var filtered = {};
    var keys = Object.keys(consumerGroups);
    
    for (var i = 0; i < keys.length; i++) {
        var key = keys[i];
        var group = consumerGroups[key];
        
        // Filter accounts by rejection reason (account-level)
        var matchingAccounts = [];
        for (var j = 0; j < group.accounts.length; j++) {
            var acct = group.accounts[j];
            
            if (activeReasonFilter !== 'ALL' && acct.rejection_reason !== activeReasonFilter) {
                continue;
            }
            matchingAccounts.push(acct);
        }
        
        if (matchingAccounts.length === 0) continue;
        
        // Apply search filter at consumer level
        if (searchTerm) {
            var haystack = (
                (group.consumer_number || '') + ' ' +
                (group.consumer_name || '') + ' ' +
                (group.company || '')
            ).toLowerCase();
            
            if (haystack.indexOf(searchTerm) === -1) continue;
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

// ============================================================================
// UTILITY FUNCTIONS
// ============================================================================
function updateTimestamp(ts) {
    document.getElementById('last-update').textContent = ts || '-';
}

function showConnectionError(msg) {
    var el = document.getElementById('connection-error');
    el.textContent = msg;
    el.classList.add('visible');
}

function clearConnectionError() {
    var el = document.getElementById('connection-error');
    el.textContent = '';
    el.classList.remove('visible');
}

function escapeHtml(str) {
    if (str === null || str === undefined) return '';
    return String(str).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

function escapeAttr(str) {
    if (str === null || str === undefined) return '';
    return String(str).replace(/&/g, '&amp;').replace(/"/g, '&quot;');
}

function formatCurrency(val) {
    if (val === null || val === undefined || val === '') return '-';
    var num = parseFloat(val);
    if (isNaN(num)) return val;
    return '$' + num.toFixed(2).replace(/\B(?=(\d{3})+(?!\d))/g, ',');
}

function compareDates(a, b) {
    if (!a && !b) return 0;
    if (!a) return 1;
    if (!b) return -1;
    var pa = parseDateMdy(a);
    var pb = parseDateMdy(b);
    return pa - pb;
}

function parseDateMdy(str) {
    if (!str) return 0;
    var parts = str.split('/');
    if (parts.length !== 3) return 0;
    return new Date(parseInt(parts[2]), parseInt(parts[0]) - 1, parseInt(parts[1])).getTime();
}

function getQueueReasonClass(reason) {
    if (!reason) return 'other';
    if (reason === 'Letter Requested') return 'letter';
    return 'other';
}

function getReasonClass(reason) {
    if (!reason) return 'other';
    if (reason.indexOf('Zero Dollar') >= 0) return 'zero-dollar';
    if (reason.indexOf('No Reg F') >= 0) return 'no-data';
    if (reason.indexOf('Unaccounted') >= 0) return 'discrepancy';
    if (reason.indexOf('Letter') >= 0) return 'letter';
    return 'other';
}

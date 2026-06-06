/* ============================================================================
   xFACts Control Center - Client Portal (client-portal.js)
   Location: E:\xFACts-ControlCenter\public\js\client-portal.js
   Version: Tracked in dbo.System_Metadata (component: Tools.ClientPortal)

   Page-specific JavaScript for the Client Portal lookup tool: loads the
   reference lookup tables, runs consumer searches, and renders the four
   portal views (search, results, consumer detail with five tabs, account
   detail with three tabs). Handles client-filter resolution, lazy per-tab
   loading, the system-notes event toggles, the SSN reveal control, and all
   value formatting and lookup-code resolution. Chrome behavior (the shared
   fetch wrapper, alert/confirm modals, page refresh, idle and visibility
   handling) is owned by cc-shared.js; this file consumes it.

   FILE ORGANIZATION
   -----------------
   CONSTANTS: ACTION DISPATCH
   CONSTANTS: TAG DISPLAY MAP
   STATE: PAGE STATE
   FUNCTIONS: INITIALIZATION
   FUNCTIONS: ACTION DISPATCH
   FUNCTIONS: LOOKUPS AND CLIENT FILTER
   FUNCTIONS: VIEW NAVIGATION
   FUNCTIONS: LOOKUP RESOLUTION
   FUNCTIONS: FORMATTING
   FUNCTIONS: STATUS BADGE
   FUNCTIONS: SEARCH
   FUNCTIONS: CONSUMER DETAIL
   FUNCTIONS: CONSUMER TABS
   FUNCTIONS: ACCOUNT DETAIL
   FUNCTIONS: ACCOUNT TABS
   ============================================================================ */

/* ============================================================================
   CONSTANTS: ACTION DISPATCH
   ----------------------------------------------------------------------------
   The page-local dispatch tables, one per event type used by the page. Each
   maps a clp- data-action-<event> value declared in the page markup (and in
   JS-rendered markup) to its handler. Routed by the delegated listeners
   registered in clp_init.
   Prefix: clp
   ============================================================================ */

/* Page-local click-action handlers keyed by data-action-click value. */
const clp_clickActions = {
    'clp-do-search':              clp_doSearch,
    'clp-show-search':            clp_showSearch,
    'clp-show-results':           clp_showResults,
    'clp-back-to-consumer':       clp_backToConsumer,
    'clp-switch-consumer-tab':    clp_switchConsumerTab,
    'clp-switch-account-tab':     clp_switchAccountTab,
    'clp-toggle-consumer-events': clp_toggleConsumerEvents,
    'clp-toggle-account-events':  clp_toggleAccountEvents,
    'clp-select-consumer':        clp_selectConsumer,
    'clp-select-account':         clp_selectAccount,
    'clp-toggle-ssn':             clp_toggleSsn
};

/* Page-local keydown-action handlers keyed by data-action-keydown value. */
const clp_keydownActions = {
    'clp-search-on-enter': clp_searchOnEnter
};

/* Page-local input-action handlers keyed by data-action-input value. */
const clp_inputActions = {
    'clp-resolve-client-filter': clp_resolveClientFilter
};

/* ============================================================================
   CONSTANTS: TAG DISPLAY MAP
   ----------------------------------------------------------------------------
   Maps Debt Manager tag short names to the badge label and color used to
   render consumer and account status badges. Display text and color are
   presentation concerns not stored in crs5_oltp, so they are mapped here.
   Prefix: clp
   ============================================================================ */

/* Status-badge label and color keyed by DM tag short name. */
const clp_TAG_DISPLAY_MAP = {
    'TA_CSNEW': { display: 'ACT', color: 'green' },
    'TA_CSACT': { display: 'ACT', color: 'green' },
    'TA_CSPIF': { display: 'PIF', color: 'blue' },
    'TA_CSDSP': { display: 'DSP', color: 'gray' },
    'TA_CSBNK': { display: 'BNK', color: 'orange' },
    'TA_CSLGL': { display: 'LGL', color: 'purple' },
    'TA_CSRET': { display: 'RTN', color: 'red' },
    'TA_CSSIF': { display: 'SIF', color: 'blue' },
    'TA_CSHLD': { display: 'ACT', color: 'green' },
    'TA_CSINS': { display: 'INS', color: 'yellow' },
    'TA_CSRTR': { display: 'ACT', color: 'green' },
    'TA_CSWCP': { display: 'ACT', color: 'green' },
    'TA_CSCLS': { display: 'RTN', color: 'red' },
    'TC_CSACT': { display: 'ACT', color: 'green' },
    'TC_CSATY': { display: 'ATY', color: 'red' },
    'TC_CSHLD': { display: 'ACT', color: 'green' },
    'TC_CSPLN': { display: 'ACT', color: 'green' },
    'TC_CSBKP': { display: 'ACT', color: 'green' },
    'TC_CSBNK': { display: 'BNK', color: 'orange' },
    'TC_CSDCS': { display: 'ACT', color: 'green' },
    'TC_CSCEA': { display: 'ACT', color: 'green' }
};

/* ============================================================================
   STATE: PAGE STATE
   ----------------------------------------------------------------------------
   Mutable page state: the loaded lookup tables and portal event-code set, the
   current search results, the selected consumer and account, the cached
   per-consumer accounts and event lists, the system-notes toggle flags, and
   the client-filter debounce handle.
   Prefix: clp
   ============================================================================ */

/* The loaded reference lookup tables, or null before they load. */
var clp_lookups = null;

/* Whether the reference lookup tables have finished loading. */
var clp_lookupsLoaded = false;

/* The set of result codes classified as portal (non-system) events. */
var clp_portalEventCodes = new Set();

/* The most recent consumer search result list. */
var clp_searchResults = [];

/* The currently selected consumer object, or null. */
var clp_selectedConsumer = null;

/* The currently selected consumer id, or null. */
var clp_selectedConsumerId = null;

/* The currently selected account id, or null. */
var clp_selectedAccountId = null;

/* The cached accounts payload for the selected consumer, or null. */
var clp_consumerAccounts = null;

/* Whether all consumer events (including system notes) are shown. */
var clp_showAllConsumerEvents = false;

/* Whether all account events (including system notes) are shown. */
var clp_showAllAccountEvents = false;

/* The cached consumer event list, or null before it loads. */
var clp_consumerEvents = null;

/* The cached account event list, or null before it loads. */
var clp_accountEvents = null;

/* The debounce timer handle for client-filter resolution. */
var clp_clientFilterDebounce = null;

/* ============================================================================
   FUNCTIONS: INITIALIZATION
   ----------------------------------------------------------------------------
   The page boot function invoked by cc-shared.js after the module loads.
   Registers the delegated click, keydown, and input listeners and loads the
   reference lookup tables.
   Prefix: clp
   ============================================================================ */

/* Boots the page: registers the delegated event dispatchers and loads the
   reference lookup tables. */
function clp_init() {
    document.body.addEventListener('click', clp_dispatchClick);
    document.body.addEventListener('keydown', clp_dispatchKeydown);
    document.body.addEventListener('input', clp_dispatchInput);

    clp_loadLookups();
}

/* ============================================================================
   FUNCTIONS: ACTION DISPATCH
   ----------------------------------------------------------------------------
   The delegated dispatchers registered on document.body by clp_init. Each
   routes clp- data-action-<event> values to their handler in the matching
   dispatch table.
   Prefix: clp
   ============================================================================ */

/* Delegated click dispatcher: routes clp- data-action-click values to their
   handler in clp_clickActions. */
function clp_dispatchClick(event) {
    var target = event.target.closest('[data-action-click]');
    if (!target) return;
    var action = target.getAttribute('data-action-click');
    if (!action || action.indexOf('clp-') !== 0) return;
    var handler = clp_clickActions[action];
    if (handler) handler(target, event);
}

/* Delegated keydown dispatcher: routes clp- data-action-keydown values to
   their handler in clp_keydownActions. */
function clp_dispatchKeydown(event) {
    var target = event.target.closest('[data-action-keydown]');
    if (!target) return;
    var action = target.getAttribute('data-action-keydown');
    if (!action || action.indexOf('clp-') !== 0) return;
    var handler = clp_keydownActions[action];
    if (handler) handler(target, event);
}

/* Delegated input dispatcher: routes clp- data-action-input values to their
   handler in clp_inputActions. */
function clp_dispatchInput(event) {
    var target = event.target.closest('[data-action-input]');
    if (!target) return;
    var action = target.getAttribute('data-action-input');
    if (!action || action.indexOf('clp-') !== 0) return;
    var handler = clp_inputActions[action];
    if (handler) handler(target, event);
}

/* ============================================================================
   FUNCTIONS: LOOKUPS AND CLIENT FILTER
   ----------------------------------------------------------------------------
   Loads the reference lookup tables that resolve DM codes to display text,
   builds the portal event-code set, updates the lookup-status readout, and
   resolves the optional creditor/group client filter with debouncing.
   Prefix: clp
   ============================================================================ */

/* Loads the reference lookup tables and seeds the portal event-code set. */
async function clp_loadLookups() {
    try {
        var json = await cc_engineFetch('/api/client-portal/lookups');
        if (!json) return;
        if (json.error) throw new Error(json.error);
        clp_lookups = json.data;

        if (clp_lookups.portal_event_codes) {
            clp_lookups.portal_event_codes.forEach(function (r) {
                clp_portalEventCodes.add(r.rslt_cd);
            });
        }

        clp_lookupsLoaded = true;
        var statusEl = document.getElementById('clp-lookup-status');
        if (statusEl) statusEl.textContent = 'Ready';
    } catch (err) {
        var statusEl = document.getElementById('clp-lookup-status');
        if (statusEl) {
            statusEl.textContent = 'Lookup load failed';
            statusEl.classList.add('clp-lookup-error');
        }
        console.error('Failed to load lookups:', err);
    }
}

/* Debounced handler for the client-filter input: schedules creditor
   resolution and clears the count chip when the field is emptied. */
function clp_resolveClientFilter(target) {
    clearTimeout(clp_clientFilterDebounce);
    var val = target.value.trim();
    var countEl = document.getElementById('clp-client-filter-count');
    if (!val) {
        countEl.classList.add('clp-hidden');
        return;
    }
    clp_clientFilterDebounce = setTimeout(function () {
        clp_lookupClientFilter(val);
    }, 500);
}

/* Resolves a creditor/group filter to a count and updates the count chip. */
async function clp_lookupClientFilter(filter) {
    var countEl = document.getElementById('clp-client-filter-count');
    try {
        var json = await cc_engineFetch('/api/client-portal/creditors?filter=' + encodeURIComponent(filter));
        if (!json) return;
        if (json.error) {
            countEl.textContent = 'Not found';
            countEl.classList.remove('clp-hidden', 'clp-filter-ok');
            countEl.classList.add('clp-filter-error');
            return;
        }
        countEl.textContent = json.count + ' creditor' + (json.count !== 1 ? 's' : '');
        countEl.classList.remove('clp-hidden', 'clp-filter-error');
        countEl.classList.add('clp-filter-ok');
    } catch (err) {
        countEl.textContent = 'Error';
        countEl.classList.remove('clp-hidden', 'clp-filter-ok');
        countEl.classList.add('clp-filter-error');
    }
}

/* ============================================================================
   FUNCTIONS: VIEW NAVIGATION
   ----------------------------------------------------------------------------
   Switches between the four portal views by toggling the clp-active state on
   the view containers.
   Prefix: clp
   ============================================================================ */

/* Shows the portal view with the given id and hides the others. */
function clp_showPage(pageId) {
    document.querySelectorAll('.clp-portal-page').forEach(function (p) {
        p.classList.remove('clp-active');
    });
    var el = document.getElementById(pageId);
    if (el) el.classList.add('clp-active');
}

/* Shows the search view. */
function clp_showSearch() {
    clp_showPage('clp-page-search');
}

/* Shows the results view. */
function clp_showResults() {
    clp_showPage('clp-page-results');
}

/* Returns to the consumer detail view from the account detail view. */
function clp_backToConsumer() {
    clp_showPage('clp-page-consumer');
}

/* ============================================================================
   FUNCTIONS: LOOKUP RESOLUTION
   ----------------------------------------------------------------------------
   Resolves DM codes to display text against the loaded lookup tables, and
   tests whether a result code is a portal (non-system) event.
   Prefix: clp
   ============================================================================ */

/* Resolves a code to its display value via a named lookup table. */
function clp_lookupValue(table, keyField, keyValue, displayField) {
    if (!clp_lookups || !clp_lookups[table]) return keyValue;
    var row = clp_lookups[table].find(function (r) { return r[keyField] == keyValue; });
    return row ? row[displayField] : keyValue;
}

/* Resolves an action code to its short display text. */
function clp_getAction(code) {
    return clp_lookupValue('actions', 'actn_cd', code, 'actn_cd_shrt_val_txt');
}

/* Resolves a result code to its short display text. */
function clp_getResult(code) {
    return clp_lookupValue('results', 'rslt_cd', code, 'rslt_cd_shrt_val_txt');
}

/* Resolves a bucket id to its name. */
function clp_getBucket(id) {
    return clp_lookupValue('buckets', 'bckt_id', id, 'bckt_nm');
}

/* Resolves a transaction type code to its display text. */
function clp_getTxnType(code) {
    return clp_lookupValue('txn_types', 'bckt_trnsctn_typ_cd', code, 'bckt_trnsctn_val_txt');
}

/* Resolves a user id to its username. */
function clp_getUser(id) {
    return clp_lookupValue('users', 'usr_id', id, 'usr_usrnm');
}

/* Resolves a phone status code to its display text. */
function clp_getPhoneStatus(code) {
    return clp_lookupValue('phone_statuses', 'phn_stts_cd', code, 'phn_stts_val_txt');
}

/* Resolves a phone type code to its display text. */
function clp_getPhoneType(code) {
    return clp_lookupValue('phone_types', 'phn_typ_cd', code, 'phn_typ_val_txt');
}

/* Resolves an address status code to its display text. */
function clp_getAddressStatus(code) {
    return clp_lookupValue('address_statuses', 'addrss_stts_cd', code, 'addrss_stts_val_txt');
}

/* Resolves a payment location code to its display text. */
function clp_getPaymentLocation(code) {
    return clp_lookupValue('payment_locations', 'pymnt_lctn_cd', code, 'pymnt_lctn_val_txt');
}

/* Returns whether a result code is a portal (non-system) event. */
function clp_isPortalEvent(rsltCd) {
    return clp_portalEventCodes.has(rsltCd);
}

/* ============================================================================
   FUNCTIONS: FORMATTING
   ----------------------------------------------------------------------------
   Portal-specific value formatters for currency, dates, datetimes, and phone
   numbers. HTML escaping uses the shared cc_escapeHtml helper.
   Prefix: clp
   ============================================================================ */

/* Formats a numeric value as a US dollar amount. */
function clp_formatCurrency(val) {
    if (val === null || val === undefined) return '$0.00';
    return '$' + Number(val).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

/* Formats a yyyy-MM-dd value as M/D/Y for display. */
function clp_formatDate(val) {
    if (!val) return '';
    var parts = val.split('-');
    if (parts.length === 3) return parts[1] + '/' + parts[2] + '/' + parts[0];
    return val;
}

/* Formats a yyyy-MM-dd HH:mm:ss value as M/D/Y HH:mm:ss for display. */
function clp_formatDateTime(val) {
    if (!val) return '';
    var parts = val.split(' ');
    if (parts.length === 2) return clp_formatDate(parts[0]) + ' ' + parts[1];
    return val;
}

/* Formats a 10-digit phone number as (XXX) XXX-XXXX. */
function clp_formatPhone(val) {
    if (!val) return '';
    var digits = val.replace(/\D/g, '');
    if (digits.length === 10) {
        return '(' + digits.substr(0, 3) + ') ' + digits.substr(3, 3) + '-' + digits.substr(6, 4);
    }
    return val;
}

/* ============================================================================
   FUNCTIONS: STATUS BADGE
   ----------------------------------------------------------------------------
   Renders the consumer/account status badge HTML from a tag, mapping the tag
   short name to its display label and color via clp_TAG_DISPLAY_MAP.
   Prefix: clp
   ============================================================================ */

/* Returns status-badge HTML for a tag, or an empty string when absent. */
function clp_renderStatusBadge(tag) {
    if (!tag) return '';
    var shortNm = tag.short_nm || '';
    var mapped = clp_TAG_DISPLAY_MAP[shortNm] || { display: shortNm.substring(3) || '?', color: 'gray' };
    var display = cc_escapeHtml(mapped.display);
    var color = mapped.color;
    var label = cc_escapeHtml(tag.name || '');
    return '<span class="clp-status-badge clp-badge-' + color + '" title="' + label + '">' + display + '</span>';
}

/* ============================================================================
   FUNCTIONS: SEARCH
   ----------------------------------------------------------------------------
   Runs the consumer search from the form inputs, renders the results table,
   and handles the Enter-key shortcut on the search-term field.
   Prefix: clp
   ============================================================================ */

/* Keydown handler for the search-term field: runs the search on Enter. */
function clp_searchOnEnter(target, event) {
    if (event.key === 'Enter') {
        event.preventDefault();
        clp_doSearch();
    }
}

/* Runs the consumer search from the current form inputs and renders results. */
async function clp_doSearch() {
    var type = document.getElementById('clp-search-type').value;
    var term = document.getElementById('clp-search-term').value.trim();
    var client = document.getElementById('clp-client-filter').value.trim();

    if (!term) {
        cc_showAlert('Please enter a search term.');
        return;
    }

    clp_showPage('clp-page-results');
    document.getElementById('clp-results-loading').classList.remove('clp-hidden');
    document.getElementById('clp-results-table').innerHTML = '';
    document.getElementById('clp-results-summary').textContent = '';

    try {
        var url = '/api/client-portal/search?type=' + encodeURIComponent(type) +
                  '&term=' + encodeURIComponent(term);
        if (client) url += '&client=' + encodeURIComponent(client);

        var json = await cc_engineFetch(url);

        document.getElementById('clp-results-loading').classList.add('clp-hidden');
        if (!json) return;

        if (json.error && json.count === undefined) {
            document.getElementById('clp-results-table').innerHTML =
                '<div class="clp-empty-state"><p>' + cc_escapeHtml(json.error) + '</p></div>';
            return;
        }

        if (json.error && json.count === 0) {
            document.getElementById('clp-results-table').innerHTML =
                '<div class="clp-empty-state"><p>' + cc_escapeHtml(json.error) + '</p></div>';
            return;
        }

        clp_searchResults = json.consumers || [];

        var summary = json.count + ' consumer' + (json.count !== 1 ? 's' : '');
        if (json.capped) summary += ' (results capped at 100)';
        if (json.client_filter) summary += ' - filtered by: ' + cc_escapeHtml(json.client_filter);
        document.getElementById('clp-results-summary').textContent = summary;

        if (clp_searchResults.length === 0) {
            document.getElementById('clp-results-table').innerHTML =
                '<div class="clp-empty-state"><p>No consumers found matching your search.</p></div>';
            return;
        }

        clp_renderResultsTable();
    } catch (err) {
        document.getElementById('clp-results-loading').classList.add('clp-hidden');
        document.getElementById('clp-results-table').innerHTML =
            '<div class="clp-empty-state clp-empty-error"><p>Search failed: ' + cc_escapeHtml(err.message) + '</p></div>';
    }
}

/* Renders the search results into the results table. */
function clp_renderResultsTable() {
    var html = '<table class="clp-table">';
    html += '<thead class="clp-thead"><tr class="clp-row">' +
        '<th class="clp-th">Status</th>' +
        '<th class="clp-th">Consumer #</th>' +
        '<th class="clp-th">Name</th>' +
        '<th class="clp-th">Creditor</th>' +
        '<th class="clp-th"># Accounts</th>' +
        '<th class="clp-th clp-text-right">Total Balance</th>' +
        '<th class="clp-th"></th>' +
        '</tr></thead><tbody>';

    clp_searchResults.forEach(function (c) {
        var credDisplay = cc_escapeHtml(c.first_creditor || '');
        if (c.creditor_count > 1) credDisplay += ' (+' + (c.creditor_count - 1) + ')';

        html += '<tr class="clp-row">' +
            '<td class="clp-td">' + clp_renderStatusBadge(c.status_tag) + '</td>' +
            '<td class="clp-td">' + cc_escapeHtml(c.cnsmr_idntfr_agncy_id) + '</td>' +
            '<td class="clp-td">' + cc_escapeHtml(c.cnsmr_nm_lst_txt) + ', ' + cc_escapeHtml(c.cnsmr_nm_frst_txt) + '</td>' +
            '<td class="clp-td">' + credDisplay + '</td>' +
            '<td class="clp-td">' + c.account_count + '</td>' +
            '<td class="clp-td clp-text-right">' + clp_formatCurrency(c.total_balance) + '</td>' +
            '<td class="clp-td"><button class="clp-btn-view" data-action-click="clp-select-consumer" data-action-clp-id="' + c.cnsmr_id + '">View</button></td>' +
            '</tr>';
    });

    html += '</tbody></table>';
    document.getElementById('clp-results-table').innerHTML = html;
}

/* ============================================================================
   FUNCTIONS: CONSUMER DETAIL
   ----------------------------------------------------------------------------
   Loads and renders the consumer detail view: the header card (with the
   masked/full SSN reveal) and the default Accounts tab.
   Prefix: clp
   ============================================================================ */

/* Opens the consumer detail view for the consumer id carried on the target. */
async function clp_selectConsumer(target) {
    var cnsmrId = target.getAttribute('data-action-clp-id');
    clp_selectedConsumerId = cnsmrId;
    clp_selectedConsumer = null;
    clp_consumerAccounts = null;
    clp_consumerEvents = null;
    clp_showAllConsumerEvents = false;

    clp_showPage('clp-page-consumer');

    document.querySelectorAll('#clp-page-consumer .clp-tab-btn').forEach(function (b) {
        b.classList.toggle('clp-active', b.getAttribute('data-action-clp-tab') === 'clp-consumer-accounts');
    });
    document.querySelectorAll('#clp-page-consumer .clp-tab-panel').forEach(function (p) {
        p.classList.toggle('clp-active', p.id === 'clp-consumer-accounts');
    });

    var toggle = document.getElementById('clp-consumer-events-toggle');
    if (toggle) toggle.classList.remove('clp-active');
    var knob = document.querySelector('#clp-consumer-events-toggle .clp-toggle-knob');
    if (knob) knob.classList.remove('clp-active');

    document.getElementById('clp-consumer-header').innerHTML = '<div class="clp-detail-card-loading">Loading consumer...</div>';
    try {
        var json = await cc_engineFetch('/api/client-portal/consumer/' + cnsmrId);
        if (!json) return;
        if (json.error) throw new Error(json.error);
        clp_selectedConsumer = json.consumer;
        clp_renderConsumerHeader();
    } catch (err) {
        document.getElementById('clp-consumer-header').innerHTML =
            '<div class="clp-detail-card-error">Failed to load consumer: ' + cc_escapeHtml(err.message) + '</div>';
    }

    clp_loadConsumerAccounts();
}

/* Renders the consumer header card from the selected consumer. */
function clp_renderConsumerHeader() {
    var c = clp_selectedConsumer;
    if (!c) return;

    var ssnDisplay = cc_escapeHtml(c.cnsmr_ssn_masked || 'N/A');
    var ssnFull = c.cnsmr_ssn_full;
    var ssnRevealBtn = '';
    if (ssnFull) {
        ssnRevealBtn = ' <button class="clp-btn-reveal" data-action-click="clp-toggle-ssn" data-masked="' +
            cc_escapeHtml(c.cnsmr_ssn_masked) + '" data-full="' + cc_escapeHtml(ssnFull) + '">Show</button>';
    }

    var html = '<div class="clp-detail-card-content">' +
        '<div class="clp-detail-card-title">' +
        clp_renderStatusBadge(c.status_tag) +
        '<h2 class="clp-detail-card-heading">' + cc_escapeHtml(c.cnsmr_nm_lst_txt) + ', ' + cc_escapeHtml(c.cnsmr_nm_frst_txt) + '</h2>' +
        '</div>' +
        '<div class="clp-detail-grid">' +
        '<div class="clp-detail-item"><span class="clp-detail-label">Consumer #:</span> ' + cc_escapeHtml(c.cnsmr_idntfr_agncy_id) + '</div>' +
        '<div class="clp-detail-item"><span class="clp-detail-label">DOB:</span> ' + clp_formatDate(c.cnsmr_brth_dt) + '</div>' +
        '<div class="clp-detail-item"><span class="clp-detail-label">SSN:</span> <span id="clp-ssn-display">' + ssnDisplay + '</span>' + ssnRevealBtn + '</div>' +
        '<div class="clp-detail-item"><span class="clp-detail-label">Email:</span> ' + cc_escapeHtml(c.cnsmr_email_txt || 'N/A') + '</div>' +
        '</div></div>';

    document.getElementById('clp-consumer-header').innerHTML = html;
}

/* Toggles the consumer SSN display between masked and full. */
function clp_toggleSsn(target) {
    var display = document.getElementById('clp-ssn-display');
    if (!display) return;
    var masked = target.getAttribute('data-masked');
    var full = target.getAttribute('data-full');
    if (target.textContent === 'Show') {
        var formatted = full;
        if (full && full.length === 9) {
            formatted = full.substr(0, 3) + '-' + full.substr(3, 2) + '-' + full.substr(5, 4);
        }
        display.textContent = formatted;
        target.textContent = 'Hide';
    } else {
        display.textContent = masked;
        target.textContent = 'Show';
    }
}

/* ============================================================================
   FUNCTIONS: CONSUMER TABS
   ----------------------------------------------------------------------------
   Switches between the five consumer detail tabs and lazy-loads each tab's
   content: accounts, demographics (addresses), phones, events, and outreach.
   Prefix: clp
   ============================================================================ */

/* Switches the active consumer tab and lazy-loads its content. */
function clp_switchConsumerTab(target) {
    var tabId = target.getAttribute('data-action-clp-tab');
    document.querySelectorAll('#clp-page-consumer .clp-tab-btn').forEach(function (b) {
        b.classList.toggle('clp-active', b === target);
    });
    document.querySelectorAll('#clp-page-consumer .clp-tab-panel').forEach(function (p) {
        p.classList.toggle('clp-active', p.id === tabId);
    });

    switch (tabId) {
        case 'clp-consumer-accounts': clp_loadConsumerAccounts(); break;
        case 'clp-consumer-demographics': clp_loadConsumerAddresses(); break;
        case 'clp-consumer-phones': clp_loadConsumerPhones(); break;
        case 'clp-consumer-events': clp_loadConsumerEvents(); break;
        case 'clp-consumer-outreach': clp_loadConsumerDocuments(); break;
    }
}

/* Loads the consumer's accounts (once) and renders them. */
async function clp_loadConsumerAccounts() {
    if (clp_consumerAccounts) { clp_renderConsumerAccounts(); return; }
    var panel = document.getElementById('clp-consumer-accounts');
    panel.innerHTML = '<div class="clp-loading">Loading accounts...</div>';
    try {
        var json = await cc_engineFetch('/api/client-portal/consumer/' + clp_selectedConsumerId + '/accounts');
        if (!json) return;
        if (json.error) throw new Error(json.error);
        clp_consumerAccounts = json;
        clp_renderConsumerAccounts();
    } catch (err) {
        panel.innerHTML = '<div class="clp-empty-state clp-empty-error">' + cc_escapeHtml(err.message) + '</div>';
    }
}

/* Renders the consumer's account list with a totals row. */
function clp_renderConsumerAccounts() {
    var data = clp_consumerAccounts;
    if (!data || !data.accounts) return;
    var panel = document.getElementById('clp-consumer-accounts');

    if (data.accounts.length === 0) {
        panel.innerHTML = '<div class="clp-empty-state">No accounts found.</div>';
        return;
    }

    var html = '<table class="clp-table">';
    html += '<thead class="clp-thead"><tr class="clp-row">' +
        '<th class="clp-th">Status</th>' +
        '<th class="clp-th">Client Acct #</th>' +
        '<th class="clp-th">Creditor</th>' +
        '<th class="clp-th">Patient/Regarding</th>' +
        '<th class="clp-th">Placement Date</th>' +
        '<th class="clp-th">Service Date</th>' +
        '<th class="clp-th clp-text-right">Total Paid</th>' +
        '<th class="clp-th clp-text-right">Current Balance</th>' +
        '<th class="clp-th"></th>' +
        '</tr></thead><tbody>';

    data.accounts.forEach(function (a) {
        html += '<tr class="clp-row">' +
            '<td class="clp-td">' + clp_renderStatusBadge(a.status_tag) + '</td>' +
            '<td class="clp-td">' + cc_escapeHtml(a.cnsmr_accnt_crdtr_rfrnc_id_txt) + '</td>' +
            '<td class="clp-td">' + cc_escapeHtml(a.crdtr_shrt_nm) + '</td>' +
            '<td class="clp-td">' + cc_escapeHtml(a.cnsmr_accnt_dscrptn_txt) + '</td>' +
            '<td class="clp-td">' + clp_formatDate(a.cnsmr_accnt_plcmnt_date) + '</td>' +
            '<td class="clp-td">' + clp_formatDate(a.cnsmr_accnt_crdtr_lst_srvc_dt) + '</td>' +
            '<td class="clp-td clp-text-right">' + clp_formatCurrency(a.total_paid) + '</td>' +
            '<td class="clp-td clp-text-right">' + clp_formatCurrency(a.invoice_balance) + '</td>' +
            '<td class="clp-td"><button class="clp-btn-view" data-action-click="clp-select-account" data-action-clp-id="' + a.cnsmr_accnt_id + '">View</button></td>' +
            '</tr>';
    });

    html += '<tr class="clp-row clp-totals-row">' +
        '<td class="clp-totals-cell clp-text-right" colspan="6"><strong>Totals:</strong></td>' +
        '<td class="clp-totals-cell clp-text-right"><strong>' + clp_formatCurrency(data.total_paid) + '</strong></td>' +
        '<td class="clp-totals-cell clp-text-right"><strong>' + clp_formatCurrency(data.total_balance_owed) + '</strong></td>' +
        '<td class="clp-totals-cell"></td>' +
        '</tr>';

    html += '</tbody></table>';
    panel.innerHTML = html;
}

/* Loads the consumer's addresses (once) and renders them as info cards. */
async function clp_loadConsumerAddresses() {
    var panel = document.getElementById('clp-consumer-demographics');
    if (panel.dataset.loaded === 'true') return;
    panel.innerHTML = '<div class="clp-loading">Loading addresses...</div>';
    try {
        var json = await cc_engineFetch('/api/client-portal/consumer/' + clp_selectedConsumerId + '/addresses');
        if (!json) return;
        if (json.error) throw new Error(json.error);
        panel.dataset.loaded = 'true';

        if (!json.addresses || json.addresses.length === 0) {
            panel.innerHTML = '<div class="clp-empty-state">No addresses on file.</div>';
            return;
        }

        var html = '<div class="clp-card-grid">';
        json.addresses.forEach(function (a) {
            var statusText = clp_getAddressStatus(a.status_cd);
            var isInvalid = (a.status_cd == 2);
            var cardClass = isInvalid ? 'clp-info-card clp-card-warning' : 'clp-info-card';

            var lines = cc_escapeHtml(a.line_1 || '');
            if (a.line_2) lines += '<br>' + cc_escapeHtml(a.line_2);
            lines += '<br>' + cc_escapeHtml(a.city || '') + ', ' + cc_escapeHtml(a.state || '') + ' ' + cc_escapeHtml(a.zip || '');

            var extra = '';
            if (isInvalid && a.mail_return_cd) {
                extra = '<div class="clp-card-detail clp-warning-text">Mail Return: ' + cc_escapeHtml(a.mail_return_cd);
                if (a.mail_return_dt) extra += ' (' + clp_formatDate(a.mail_return_dt) + ')';
                extra += '</div>';
            }

            html += '<div class="' + cardClass + '">' +
                '<div class="clp-card-header"><span class="clp-card-status ' + (isInvalid ? 'clp-status-invalid' : 'clp-status-valid') + '">' + cc_escapeHtml(statusText) + '</span></div>' +
                '<div class="clp-card-body">' + lines + '</div>' +
                extra +
                '</div>';
        });
        html += '</div>';
        panel.innerHTML = html;
    } catch (err) {
        panel.innerHTML = '<div class="clp-empty-state clp-empty-error">' + cc_escapeHtml(err.message) + '</div>';
    }
}

/* Loads the consumer's phones (once) and renders them as info cards. */
async function clp_loadConsumerPhones() {
    var panel = document.getElementById('clp-consumer-phones');
    if (panel.dataset.loaded === 'true') return;
    panel.innerHTML = '<div class="clp-loading">Loading phones...</div>';
    try {
        var json = await cc_engineFetch('/api/client-portal/consumer/' + clp_selectedConsumerId + '/phones');
        if (!json) return;
        if (json.error) throw new Error(json.error);
        panel.dataset.loaded = 'true';

        if (!json.phones || json.phones.length === 0) {
            panel.innerHTML = '<div class="clp-empty-state">No phone numbers on file.</div>';
            return;
        }

        var html = '<div class="clp-card-grid">';
        json.phones.forEach(function (p) {
            var statusText = clp_getPhoneStatus(p.status_cd);
            var typeText = clp_getPhoneType(p.type_cd);
            var isWarning = (p.status_cd == 2 || p.status_cd == 4);

            html += '<div class="clp-info-card' + (isWarning ? ' clp-card-warning' : '') + '">' +
                '<div class="clp-card-header">' +
                '<span class="clp-card-status ' + (isWarning ? 'clp-status-invalid' : 'clp-status-valid') + '">' + cc_escapeHtml(statusText) + '</span>' +
                '<span class="clp-card-type">' + cc_escapeHtml(typeText) + '</span>' +
                '</div>' +
                '<div class="clp-card-body clp-phone-number">' + clp_formatPhone(p.number) + '</div>' +
                '</div>';
        });
        html += '</div>';
        panel.innerHTML = html;
    } catch (err) {
        panel.innerHTML = '<div class="clp-empty-state clp-empty-error">' + cc_escapeHtml(err.message) + '</div>';
    }
}

/* Loads the consumer's events (once) and renders them. */
async function clp_loadConsumerEvents() {
    if (clp_consumerEvents) { clp_renderConsumerEvents(); return; }
    var panel = document.getElementById('clp-consumer-events-list');
    panel.innerHTML = '<div class="clp-loading">Loading events...</div>';
    try {
        var json = await cc_engineFetch('/api/client-portal/consumer/' + clp_selectedConsumerId + '/events');
        if (!json) return;
        if (json.error) throw new Error(json.error);
        clp_consumerEvents = json.events || [];
        clp_renderConsumerEvents();
    } catch (err) {
        panel.innerHTML = '<div class="clp-empty-state clp-empty-error">' + cc_escapeHtml(err.message) + '</div>';
    }
}

/* Renders the consumer event list, filtered by the system-notes toggle. */
function clp_renderConsumerEvents() {
    var panel = document.getElementById('clp-consumer-events-list');
    var events = clp_consumerEvents || [];

    var filtered = clp_showAllConsumerEvents
        ? events
        : events.filter(function (e) { return clp_isPortalEvent(e.rslt_cd); });

    if (filtered.length === 0) {
        panel.innerHTML = '<div class="clp-empty-state">No events found' + (clp_showAllConsumerEvents ? '.' : ' (toggle "Show System Notes" to see all).') + '</div>';
        return;
    }

    var html = '<div class="clp-event-list">';
    filtered.forEach(function (e) {
        html += '<div class="clp-event-card">' +
            '<div class="clp-event-header">' +
            '<span class="clp-event-codes">' + cc_escapeHtml(clp_getAction(e.actn_cd)) + ' - ' + cc_escapeHtml(clp_getResult(e.rslt_cd)) + '</span>' +
            '<span class="clp-event-date">' + clp_formatDateTime(e.event_date) + '</span>' +
            '</div>' +
            '<div class="clp-event-message">' + cc_escapeHtml(e.message) + '</div>' +
            '<div class="clp-event-user">By: ' + cc_escapeHtml(clp_getUser(e.user_id)) + '</div>' +
            '</div>';
    });
    html += '</div>';
    panel.innerHTML = html;
}

/* Toggles the consumer system-notes filter and re-renders the event list. */
function clp_toggleConsumerEvents() {
    clp_showAllConsumerEvents = !clp_showAllConsumerEvents;
    var toggle = document.getElementById('clp-consumer-events-toggle');
    if (toggle) toggle.classList.toggle('clp-active', clp_showAllConsumerEvents);
    var knob = document.querySelector('#clp-consumer-events-toggle .clp-toggle-knob');
    if (knob) knob.classList.toggle('clp-active', clp_showAllConsumerEvents);
    clp_renderConsumerEvents();
}

/* Loads the consumer's outreach documents (once) and renders them. */
async function clp_loadConsumerDocuments() {
    var panel = document.getElementById('clp-consumer-outreach');
    if (panel.dataset.loaded === 'true') return;
    panel.innerHTML = '<div class="clp-loading">Loading documents...</div>';
    try {
        var json = await cc_engineFetch('/api/client-portal/consumer/' + clp_selectedConsumerId + '/documents');
        if (!json) return;
        if (json.error) throw new Error(json.error);
        panel.dataset.loaded = 'true';

        if (!json.documents || json.documents.length === 0) {
            panel.innerHTML = '<div class="clp-empty-state">No outreach documents found.</div>';
            return;
        }

        var html = '<div class="clp-event-list">';
        json.documents.forEach(function (d) {
            html += '<div class="clp-event-card">' +
                '<div class="clp-event-header">' +
                '<span class="clp-event-codes">' + cc_escapeHtml(d.template_short || d.template_name || 'Document') + '</span>' +
                '<span class="clp-event-date">' + clp_formatDate(d.dcmnt_rqst_dt) + '</span>' +
                '</div>' +
                '<div class="clp-event-message">' + cc_escapeHtml(d.template_name || '') + '</div>' +
                '</div>';
        });
        html += '</div>';
        panel.innerHTML = html;
    } catch (err) {
        panel.innerHTML = '<div class="clp-empty-state clp-empty-error">' + cc_escapeHtml(err.message) + '</div>';
    }
}

/* ============================================================================
   FUNCTIONS: ACCOUNT DETAIL
   ----------------------------------------------------------------------------
   Loads and renders the account detail view: the header card, the three
   financial summary boxes, and the default Transactions tab.
   Prefix: clp
   ============================================================================ */

/* Opens the account detail view for the account id carried on the target. */
async function clp_selectAccount(target) {
    var acctId = target.getAttribute('data-action-clp-id');
    clp_selectedAccountId = acctId;
    clp_accountEvents = null;
    clp_showAllAccountEvents = false;

    clp_showPage('clp-page-account');

    document.querySelectorAll('#clp-page-account .clp-tab-btn').forEach(function (b) {
        b.classList.toggle('clp-active', b.getAttribute('data-action-clp-tab') === 'clp-account-transactions');
    });
    document.querySelectorAll('#clp-page-account .clp-tab-panel').forEach(function (p) {
        p.classList.toggle('clp-active', p.id === 'clp-account-transactions');
    });

    var toggle = document.getElementById('clp-account-events-toggle');
    if (toggle) toggle.classList.remove('clp-active');
    var knob = document.querySelector('#clp-account-events-toggle .clp-toggle-knob');
    if (knob) knob.classList.remove('clp-active');

    document.getElementById('clp-account-header').innerHTML = '<div class="clp-detail-card-loading">Loading account...</div>';
    document.getElementById('clp-account-financials').innerHTML = '';

    try {
        var json = await cc_engineFetch('/api/client-portal/account/' + acctId);
        if (!json) return;
        if (json.error) throw new Error(json.error);
        clp_renderAccountHeader(json.account);
        clp_renderAccountFinancials(json.account);
    } catch (err) {
        document.getElementById('clp-account-header').innerHTML =
            '<div class="clp-detail-card-error">Failed to load account: ' + cc_escapeHtml(err.message) + '</div>';
    }

    clp_loadAccountTransactions();
}

/* Renders the account header card from an account object. */
function clp_renderAccountHeader(acct) {
    var html = '<div class="clp-detail-card-content">' +
        '<div class="clp-detail-card-title">' +
        clp_renderStatusBadge(acct.status_tag) +
        '<h2 class="clp-detail-card-heading">Account Details</h2>' +
        '</div>' +
        '<div class="clp-detail-grid">' +
        '<div class="clp-detail-item"><span class="clp-detail-label">Client Account #:</span> ' + cc_escapeHtml(acct.cnsmr_accnt_crdtr_rfrnc_id_txt) + '</div>' +
        '<div class="clp-detail-item"><span class="clp-detail-label">Placement Date:</span> ' + clp_formatDate(acct.cnsmr_accnt_plcmnt_date) + '</div>' +
        '<div class="clp-detail-item"><span class="clp-detail-label">External Ref #:</span> ' + cc_escapeHtml(acct.cnsmr_accnt_crdtr_rfrnc_corltn_id_txt) + '</div>' +
        '<div class="clp-detail-item"><span class="clp-detail-label">Service Date:</span> ' + clp_formatDate(acct.cnsmr_accnt_crdtr_lst_srvc_dt) + '</div>' +
        '<div class="clp-detail-item"><span class="clp-detail-label">Creditor:</span> ' + cc_escapeHtml(acct.crdtr_nm) + ' (' + cc_escapeHtml(acct.crdtr_shrt_nm) + ')</div>' +
        '<div class="clp-detail-item"><span class="clp-detail-label">Patient/Regarding:</span> ' + cc_escapeHtml(acct.cnsmr_accnt_dscrptn_txt) + '</div>' +
        '</div></div>';
    document.getElementById('clp-account-header').innerHTML = html;
}

/* Renders the three financial summary boxes for an account. */
function clp_renderAccountFinancials(acct) {
    var originalBalance = 0;
    if (acct.balances) {
        var orig = acct.balances.find(function (b) { return b.bal_nm_id == 1; });
        if (orig) originalBalance = orig.amount || 0;
    }

    var html = '<div class="clp-financial-box">' +
            '<div class="clp-financial-label">Original Balance</div>' +
            '<div class="clp-financial-amount">' + clp_formatCurrency(originalBalance) + '</div>' +
        '</div>' +
        '<div class="clp-financial-box">' +
            '<div class="clp-financial-label">Total Paid</div>' +
            '<div class="clp-financial-amount clp-financial-paid">' + clp_formatCurrency(acct.total_paid) + '</div>' +
        '</div>' +
        '<div class="clp-financial-box">' +
            '<div class="clp-financial-label">Current Balance</div>' +
            '<div class="clp-financial-amount">' + clp_formatCurrency(acct.invoice_balance) + '</div>' +
        '</div>';

    document.getElementById('clp-account-financials').innerHTML = html;
}

/* ============================================================================
   FUNCTIONS: ACCOUNT TABS
   ----------------------------------------------------------------------------
   Switches between the three account detail tabs and lazy-loads each tab's
   content: transactions, events, and outreach.
   Prefix: clp
   ============================================================================ */

/* Switches the active account tab and lazy-loads its content. */
function clp_switchAccountTab(target) {
    var tabId = target.getAttribute('data-action-clp-tab');
    document.querySelectorAll('#clp-page-account .clp-tab-btn').forEach(function (b) {
        b.classList.toggle('clp-active', b === target);
    });
    document.querySelectorAll('#clp-page-account .clp-tab-panel').forEach(function (p) {
        p.classList.toggle('clp-active', p.id === tabId);
    });

    switch (tabId) {
        case 'clp-account-transactions': clp_loadAccountTransactions(); break;
        case 'clp-account-events': clp_loadAccountEvents(); break;
        case 'clp-account-outreach': clp_loadAccountDocuments(); break;
    }
}

/* Loads the account's transactions (once) and renders them. */
async function clp_loadAccountTransactions() {
    var panel = document.getElementById('clp-account-transactions');
    if (panel.dataset.loaded === clp_selectedAccountId.toString()) return;
    panel.innerHTML = '<div class="clp-loading">Loading transactions...</div>';
    try {
        var json = await cc_engineFetch('/api/client-portal/account/' + clp_selectedAccountId + '/transactions');
        if (!json) return;
        if (json.error) throw new Error(json.error);
        panel.dataset.loaded = clp_selectedAccountId.toString();

        if (!json.transactions || json.transactions.length === 0) {
            panel.innerHTML = '<div class="clp-empty-state">No financial transactions found.</div>';
            return;
        }

        var html = '<table class="clp-table">';
        html += '<thead class="clp-thead"><tr class="clp-row">' +
            '<th class="clp-th">Date</th>' +
            '<th class="clp-th">Bucket</th>' +
            '<th class="clp-th">Type</th>' +
            '<th class="clp-th">Location</th>' +
            '<th class="clp-th clp-text-right">Amount</th>' +
            '</tr></thead><tbody>';

        json.transactions.forEach(function (t) {
            html += '<tr class="clp-row">' +
                '<td class="clp-td">' + clp_formatDate(t.post_date) + '</td>' +
                '<td class="clp-td">' + cc_escapeHtml(clp_getBucket(t.bckt_id)) + '</td>' +
                '<td class="clp-td">' + cc_escapeHtml(clp_getTxnType(t.txn_type_cd)) + '</td>' +
                '<td class="clp-td">' + cc_escapeHtml(clp_getPaymentLocation(t.location_cd)) + '</td>' +
                '<td class="clp-td clp-text-right">' + clp_formatCurrency(t.amount) + '</td>' +
                '</tr>';
        });

        html += '</tbody></table>';
        panel.innerHTML = html;
    } catch (err) {
        panel.innerHTML = '<div class="clp-empty-state clp-empty-error">' + cc_escapeHtml(err.message) + '</div>';
    }
}

/* Loads the account's events (once) and renders them. */
async function clp_loadAccountEvents() {
    if (clp_accountEvents) { clp_renderAccountEvents(); return; }
    var panel = document.getElementById('clp-account-events-list');
    panel.innerHTML = '<div class="clp-loading">Loading events...</div>';
    try {
        var json = await cc_engineFetch('/api/client-portal/account/' + clp_selectedAccountId + '/events');
        if (!json) return;
        if (json.error) throw new Error(json.error);
        clp_accountEvents = json.events || [];
        clp_renderAccountEvents();
    } catch (err) {
        panel.innerHTML = '<div class="clp-empty-state clp-empty-error">' + cc_escapeHtml(err.message) + '</div>';
    }
}

/* Renders the account event list, filtered by the system-notes toggle. */
function clp_renderAccountEvents() {
    var panel = document.getElementById('clp-account-events-list');
    var events = clp_accountEvents || [];

    var filtered = clp_showAllAccountEvents
        ? events
        : events.filter(function (e) { return clp_isPortalEvent(e.rslt_cd); });

    if (filtered.length === 0) {
        panel.innerHTML = '<div class="clp-empty-state">No events found' + (clp_showAllAccountEvents ? '.' : ' (toggle "Show System Notes" to see all).') + '</div>';
        return;
    }

    var html = '<div class="clp-event-list">';
    filtered.forEach(function (e) {
        html += '<div class="clp-event-card">' +
            '<div class="clp-event-header">' +
            '<span class="clp-event-codes">' + cc_escapeHtml(clp_getAction(e.actn_cd)) + ' - ' + cc_escapeHtml(clp_getResult(e.rslt_cd)) + '</span>' +
            '<span class="clp-event-date">' + clp_formatDateTime(e.event_date) + '</span>' +
            '</div>' +
            '<div class="clp-event-message">' + cc_escapeHtml(e.message) + '</div>' +
            '<div class="clp-event-user">By: ' + cc_escapeHtml(clp_getUser(e.user_id)) + '</div>' +
            '</div>';
    });
    html += '</div>';
    panel.innerHTML = html;
}

/* Toggles the account system-notes filter and re-renders the event list. */
function clp_toggleAccountEvents() {
    clp_showAllAccountEvents = !clp_showAllAccountEvents;
    var toggle = document.getElementById('clp-account-events-toggle');
    if (toggle) toggle.classList.toggle('clp-active', clp_showAllAccountEvents);
    var knob = document.querySelector('#clp-account-events-toggle .clp-toggle-knob');
    if (knob) knob.classList.toggle('clp-active', clp_showAllAccountEvents);
    clp_renderAccountEvents();
}

/* Loads the account's outreach documents (once) and renders them. */
async function clp_loadAccountDocuments() {
    var panel = document.getElementById('clp-account-outreach');
    if (panel.dataset.loaded === clp_selectedAccountId.toString()) return;
    panel.innerHTML = '<div class="clp-loading">Loading documents...</div>';
    try {
        var json = await cc_engineFetch('/api/client-portal/account/' + clp_selectedAccountId + '/documents');
        if (!json) return;
        if (json.error) throw new Error(json.error);
        panel.dataset.loaded = clp_selectedAccountId.toString();

        if (!json.documents || json.documents.length === 0) {
            panel.innerHTML = '<div class="clp-empty-state">No outreach documents found.</div>';
            return;
        }

        var html = '<div class="clp-event-list">';
        json.documents.forEach(function (d) {
            html += '<div class="clp-event-card">' +
                '<div class="clp-event-header">' +
                '<span class="clp-event-codes">' + cc_escapeHtml(d.template_short || d.template_name || 'Document') + '</span>' +
                '<span class="clp-event-date">' + clp_formatDate(d.dcmnt_rqst_dt) + '</span>' +
                '</div>' +
                '<div class="clp-event-message">' + cc_escapeHtml(d.template_name || '') + '</div>' +
                '</div>';
        });
        html += '</div>';
        panel.innerHTML = html;
    } catch (err) {
        panel.innerHTML = '<div class="clp-empty-state clp-empty-error">' + cc_escapeHtml(err.message) + '</div>';
    }
}

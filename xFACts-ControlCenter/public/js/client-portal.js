// ============================================================================
// xFACts Control Center - Client Portal
// Location: E:\xFACts-ControlCenter\public\js\client-portal.js
//
// Client-side logic for consumer/account lookup portal.
// Handles search, results display, consumer detail (5 tabs),
// account detail (3 tabs), lookup resolution, and formatting.
//
// Version: Tracked in dbo.System_Metadata (component: Tools.Operations)
// ============================================================================

const Portal = (function () {
    'use strict';

    // ========================================================================
    // STATE
    // ========================================================================
    const state = {
        lookups: null,
        lookupsLoaded: false,
        portalEventCodes: new Set(),
        searchResults: [],
        selectedConsumer: null,
        selectedConsumerId: null,
        selectedAccountId: null,
        consumerAccounts: null,
        showAllConsumerEvents: false,
        showAllAccountEvents: false,
        consumerEvents: null,
        accountEvents: null,
        clientFilterDebounce: null
    };

    // ========================================================================
    // INITIALIZATION
    // ========================================================================
    function init() {
        loadLookups();
        
        // Enter key triggers search
        const termInput = document.getElementById('search-term');
        if (termInput) {
            termInput.addEventListener('keydown', function (e) {
                if (e.key === 'Enter') { e.preventDefault(); doSearch(); }
            });
        }

        // Client filter debounced lookup
        const clientInput = document.getElementById('client-filter');
        if (clientInput) {
            clientInput.addEventListener('input', function () {
                clearTimeout(state.clientFilterDebounce);
                const val = this.value.trim();
                const countEl = document.getElementById('client-filter-count');
                if (!val) {
                    countEl.classList.add('hidden');
                    return;
                }
                state.clientFilterDebounce = setTimeout(function () {
                    resolveClientFilter(val);
                }, 500);
            });
        }
    }

    async function loadLookups() {
        try {
            const resp = await fetch('/api/client-portal/lookups');
            const json = await resp.json();
            if (json.error) throw new Error(json.error);
            state.lookups = json.data;

            // Build portal event code set for toggle filtering
            if (state.lookups.portal_event_codes) {
                state.lookups.portal_event_codes.forEach(function (r) {
                    state.portalEventCodes.add(r.rslt_cd);
                });
            }

            state.lookupsLoaded = true;
            const statusEl = document.getElementById('lookup-status');
            if (statusEl) statusEl.textContent = 'Ready';
        } catch (err) {
            const statusEl = document.getElementById('lookup-status');
            if (statusEl) {
                statusEl.textContent = 'Lookup load failed';
                statusEl.classList.add('error');
            }
            console.error('Failed to load lookups:', err);
        }
    }

    async function resolveClientFilter(filter) {
        const countEl = document.getElementById('client-filter-count');
        try {
            const resp = await fetch('/api/client-portal/creditors?filter=' + encodeURIComponent(filter));
            const json = await resp.json();
            if (json.error) {
                countEl.textContent = 'Not found';
                countEl.classList.remove('hidden');
                countEl.classList.add('filter-error');
                countEl.classList.remove('filter-ok');
                return;
            }
            countEl.textContent = json.count + ' creditor' + (json.count !== 1 ? 's' : '');
            countEl.classList.remove('hidden', 'filter-error');
            countEl.classList.add('filter-ok');
        } catch (err) {
            countEl.textContent = 'Error';
            countEl.classList.remove('hidden', 'filter-ok');
            countEl.classList.add('filter-error');
        }
    }

    // ========================================================================
    // NAVIGATION
    // ========================================================================
    function showPage(pageId) {
        document.querySelectorAll('.portal-page').forEach(function (p) {
            p.classList.remove('active');
        });
        var el = document.getElementById(pageId);
        if (el) el.classList.add('active');
    }

    function showSearch() {
        showPage('page-search');
    }

    function showResults() {
        showPage('page-results');
    }

    function backToConsumer() {
        showPage('page-consumer');
    }

    // ========================================================================
    // LOOKUP HELPERS
    // ========================================================================
    function lookupValue(table, keyField, keyValue, displayField) {
        if (!state.lookups || !state.lookups[table]) return keyValue;
        var row = state.lookups[table].find(function (r) { return r[keyField] == keyValue; });
        return row ? row[displayField] : keyValue;
    }

    function getAction(code) {
        return lookupValue('actions', 'actn_cd', code, 'actn_cd_shrt_val_txt');
    }

    function getResult(code) {
        return lookupValue('results', 'rslt_cd', code, 'rslt_cd_shrt_val_txt');
    }

    function getBucket(id) {
        return lookupValue('buckets', 'bckt_id', id, 'bckt_nm');
    }

    function getTxnType(code) {
        return lookupValue('txn_types', 'bckt_trnsctn_typ_cd', code, 'bckt_trnsctn_val_txt');
    }

    function getBalanceName(id) {
        return lookupValue('balance_names', 'bal_nm_id', id, 'bal_nm');
    }

    function getUser(id) {
        return lookupValue('users', 'usr_id', id, 'usr_usrnm');
    }

    function getPhoneStatus(code) {
        return lookupValue('phone_statuses', 'phn_stts_cd', code, 'phn_stts_val_txt');
    }

    function getPhoneType(code) {
        return lookupValue('phone_types', 'phn_typ_cd', code, 'phn_typ_val_txt');
    }

    function getAddressStatus(code) {
        return lookupValue('address_statuses', 'addrss_stts_cd', code, 'addrss_stts_val_txt');
    }

    function getPaymentLocation(code) {
        return lookupValue('payment_locations', 'pymnt_lctn_cd', code, 'pymnt_lctn_val_txt');
    }

    function isPortalEvent(rsltCd) {
        return state.portalEventCodes.has(rsltCd);
    }

    // ========================================================================
    // FORMATTING HELPERS
    // ========================================================================
    function formatCurrency(val) {
        if (val === null || val === undefined) return '$0.00';
        return '$' + Number(val).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
    }

    function formatDate(val) {
        if (!val) return '';
        // Input is yyyy-MM-dd from API
        var parts = val.split('-');
        if (parts.length === 3) return parts[1] + '/' + parts[2] + '/' + parts[0];
        return val;
    }

    function formatDateTime(val) {
        if (!val) return '';
        // Input is yyyy-MM-dd HH:mm:ss
        var parts = val.split(' ');
        if (parts.length === 2) return formatDate(parts[0]) + ' ' + parts[1];
        return val;
    }

    function formatPhone(val) {
        if (!val) return '';
        var digits = val.replace(/\D/g, '');
        if (digits.length === 10) {
            return '(' + digits.substr(0, 3) + ') ' + digits.substr(3, 3) + '-' + digits.substr(6, 4);
        }
        return val;
    }

    function esc(val) {
        if (val === null || val === undefined) return '';
        var str = String(val);
        var div = document.createElement('div');
        div.textContent = str;
        return div.innerHTML;
    }

    // ========================================================================
    // STATUS BADGE — Tag display and color mapping
    // The tag table provides tag_shrt_nm and tag_nm from the database.
    // Display text (badge label) and color (CSS class) are mapped here
    // since these are presentation concerns not stored in crs5_oltp.
    // ========================================================================
    const TAG_DISPLAY_MAP = {
        // Account-level tags (tag_typ_id = 113)
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
        // Consumer-level tags (tag_typ_id = 115)
        'TC_CSACT': { display: 'ACT', color: 'green' },
        'TC_CSATY': { display: 'ATY', color: 'red' },
        'TC_CSHLD': { display: 'ACT', color: 'green' },
        'TC_CSPLN': { display: 'ACT', color: 'green' },
        'TC_CSBKP': { display: 'ACT', color: 'green' },
        'TC_CSBNK': { display: 'BNK', color: 'orange' },
        'TC_CSDCS': { display: 'ACT', color: 'green' },
        'TC_CSCEA': { display: 'ACT', color: 'green' }
    };

    function renderStatusBadge(tag) {
        if (!tag) return '';
        var shortNm = tag.short_nm || '';
        var mapped = TAG_DISPLAY_MAP[shortNm] || { display: shortNm.substring(3) || '?', color: 'gray' };
        var display = esc(mapped.display);
        var color = mapped.color;
        var label = esc(tag.name || '');

        return '<span class="status-badge badge-' + color + '" title="' + label + '">' + display + '</span>';
    }

    // ========================================================================
    // SEARCH
    // ========================================================================
    async function doSearch() {
        var type = document.getElementById('search-type').value;
        var term = document.getElementById('search-term').value.trim();
        var client = document.getElementById('client-filter').value.trim();

        if (!term) {
            alert('Please enter a search term.');
            return;
        }

        showPage('page-results');
        document.getElementById('results-loading').classList.remove('hidden');
        document.getElementById('results-table').innerHTML = '';
        document.getElementById('results-summary').textContent = '';

        try {
            var url = '/api/client-portal/search?type=' + encodeURIComponent(type) +
                      '&term=' + encodeURIComponent(term);
            if (client) url += '&client=' + encodeURIComponent(client);

            var resp = await fetch(url);
            var json = await resp.json();

            document.getElementById('results-loading').classList.add('hidden');

            if (json.error && json.count === undefined) {
                document.getElementById('results-table').innerHTML =
                    '<div class="empty-state"><p>' + esc(json.error) + '</p></div>';
                return;
            }

            // SSN search message (not an error, but informational)
            if (json.error && json.count === 0) {
                document.getElementById('results-table').innerHTML =
                    '<div class="empty-state"><p>' + esc(json.error) + '</p></div>';
                return;
            }

            state.searchResults = json.consumers || [];

            var summary = json.count + ' consumer' + (json.count !== 1 ? 's' : '');
            if (json.capped) summary += ' (results capped at 100)';
            if (json.client_filter) summary += ' — filtered by: ' + esc(json.client_filter);
            document.getElementById('results-summary').textContent = summary;

            if (state.searchResults.length === 0) {
                document.getElementById('results-table').innerHTML =
                    '<div class="empty-state"><p>No consumers found matching your search.</p></div>';
                return;
            }

            renderResultsTable();
        } catch (err) {
            document.getElementById('results-loading').classList.add('hidden');
            document.getElementById('results-table').innerHTML =
                '<div class="empty-state error"><p>Search failed: ' + esc(err.message) + '</p></div>';
        }
    }

    function renderResultsTable() {
        var html = '<table class="portal-table">';
        html += '<thead><tr>' +
            '<th>Status</th>' +
            '<th>Consumer #</th>' +
            '<th>Name</th>' +
            '<th>Creditor</th>' +
            '<th># Accounts</th>' +
            '<th class="text-right">Total Balance</th>' +
            '<th></th>' +
            '</tr></thead><tbody>';

        state.searchResults.forEach(function (c) {
            var credDisplay = esc(c.first_creditor || '');
            if (c.creditor_count > 1) credDisplay += ' (+' + (c.creditor_count - 1) + ')';

            html += '<tr>' +
                '<td>' + renderStatusBadge(c.status_tag) + '</td>' +
                '<td>' + esc(c.cnsmr_idntfr_agncy_id) + '</td>' +
                '<td>' + esc(c.cnsmr_nm_lst_txt) + ', ' + esc(c.cnsmr_nm_frst_txt) + '</td>' +
                '<td>' + credDisplay + '</td>' +
                '<td>' + c.account_count + '</td>' +
                '<td class="text-right">' + formatCurrency(c.total_balance) + '</td>' +
                '<td><button class="view-btn" onclick="Portal.selectConsumer(' + c.cnsmr_id + ')">View</button></td>' +
                '</tr>';
        });

        html += '</tbody></table>';
        document.getElementById('results-table').innerHTML = html;
    }

    // ========================================================================
    // CONSUMER DETAIL
    // ========================================================================
    async function selectConsumer(cnsmrId) {
        state.selectedConsumerId = cnsmrId;
        state.selectedConsumer = null;
        state.consumerAccounts = null;
        state.consumerEvents = null;
        state.showAllConsumerEvents = false;

        showPage('page-consumer');

        // Reset tabs to Accounts
        document.querySelectorAll('#page-consumer .tab-btn').forEach(function (b) {
            b.classList.toggle('active', b.dataset.tab === 'consumer-accounts');
        });
        document.querySelectorAll('#page-consumer .tab-panel').forEach(function (p) {
            p.classList.toggle('active', p.id === 'consumer-accounts');
        });

        // Reset events toggle
        var toggle = document.getElementById('consumer-events-toggle');
        if (toggle) toggle.classList.remove('active');

        // Load consumer header
        document.getElementById('consumer-header').innerHTML = '<div class="detail-card-loading">Loading consumer...</div>';
        try {
            var resp = await fetch('/api/client-portal/consumer/' + cnsmrId);
            var json = await resp.json();
            if (json.error) throw new Error(json.error);
            state.selectedConsumer = json.consumer;
            renderConsumerHeader();
        } catch (err) {
            document.getElementById('consumer-header').innerHTML =
                '<div class="detail-card-error">Failed to load consumer: ' + esc(err.message) + '</div>';
        }

        // Load accounts tab immediately (default tab)
        loadConsumerAccounts();
    }

    function renderConsumerHeader() {
        var c = state.selectedConsumer;
        if (!c) return;

        var ssnDisplay = esc(c.cnsmr_ssn_masked || 'N/A');
        var ssnFull = c.cnsmr_ssn_full;
        var ssnRevealBtn = '';
        if (ssnFull) {
            ssnRevealBtn = ' <button class="reveal-btn" onclick="Portal.toggleSSN(this)" data-masked="' +
                esc(c.cnsmr_ssn_masked) + '" data-full="' + esc(ssnFull) + '">Show</button>';
        }

        var html = '<div class="detail-card-content">' +
            '<div class="detail-card-title">' +
            renderStatusBadge(c.status_tag) +
            '<h2>' + esc(c.cnsmr_nm_lst_txt) + ', ' + esc(c.cnsmr_nm_frst_txt) + '</h2>' +
            '</div>' +
            '<div class="detail-grid">' +
            '<div class="detail-item"><span class="detail-label">Consumer #:</span> ' + esc(c.cnsmr_idntfr_agncy_id) + '</div>' +
            '<div class="detail-item"><span class="detail-label">DOB:</span> ' + formatDate(c.cnsmr_brth_dt) + '</div>' +
            '<div class="detail-item"><span class="detail-label">SSN:</span> <span id="ssn-display">' + ssnDisplay + '</span>' + ssnRevealBtn + '</div>' +
            '<div class="detail-item"><span class="detail-label">Email:</span> ' + esc(c.cnsmr_email_txt || 'N/A') + '</div>' +
            '</div></div>';

        document.getElementById('consumer-header').innerHTML = html;
    }

    function toggleSSN(btn) {
        var display = document.getElementById('ssn-display');
        if (!display) return;
        var masked = btn.getAttribute('data-masked');
        var full = btn.getAttribute('data-full');
        if (btn.textContent === 'Show') {
            // Format as XXX-XX-XXXX
            var formatted = full;
            if (full && full.length === 9) {
                formatted = full.substr(0, 3) + '-' + full.substr(3, 2) + '-' + full.substr(5, 4);
            }
            display.textContent = formatted;
            btn.textContent = 'Hide';
        } else {
            display.textContent = masked;
            btn.textContent = 'Show';
        }
    }

    // ---- Consumer Tabs ----
    function switchConsumerTab(btn) {
        var tabId = btn.dataset.tab;
        document.querySelectorAll('#page-consumer .tab-btn').forEach(function (b) {
            b.classList.toggle('active', b === btn);
        });
        document.querySelectorAll('#page-consumer .tab-panel').forEach(function (p) {
            p.classList.toggle('active', p.id === tabId);
        });

        // Lazy-load tab content
        switch (tabId) {
            case 'consumer-accounts': loadConsumerAccounts(); break;
            case 'consumer-demographics': loadConsumerAddresses(); break;
            case 'consumer-phones': loadConsumerPhones(); break;
            case 'consumer-events': loadConsumerEvents(); break;
            case 'consumer-outreach': loadConsumerDocuments(); break;
        }
    }

    // ---- Accounts Tab ----
    async function loadConsumerAccounts() {
        if (state.consumerAccounts) { renderConsumerAccounts(); return; }
        var panel = document.getElementById('consumer-accounts');
        panel.innerHTML = '<div class="loading">Loading accounts...</div>';
        try {
            var resp = await fetch('/api/client-portal/consumer/' + state.selectedConsumerId + '/accounts');
            var json = await resp.json();
            if (json.error) throw new Error(json.error);
            state.consumerAccounts = json;
            renderConsumerAccounts();
        } catch (err) {
            panel.innerHTML = '<div class="empty-state error">' + esc(err.message) + '</div>';
        }
    }

    function renderConsumerAccounts() {
        var data = state.consumerAccounts;
        if (!data || !data.accounts) return;
        var panel = document.getElementById('consumer-accounts');

        if (data.accounts.length === 0) {
            panel.innerHTML = '<div class="empty-state">No accounts found.</div>';
            return;
        }

        var html = '<table class="portal-table">';
        html += '<thead><tr>' +
            '<th>Status</th>' +
            '<th>Client Acct #</th>' +
            '<th>Creditor</th>' +
            '<th>Patient/Regarding</th>' +
            '<th>Placement Date</th>' +
            '<th>Service Date</th>' +
            '<th class="text-right">Total Paid</th>' +
            '<th class="text-right">Current Balance</th>' +
            '<th></th>' +
            '</tr></thead><tbody>';

        data.accounts.forEach(function (a) {
            html += '<tr>' +
                '<td>' + renderStatusBadge(a.status_tag) + '</td>' +
                '<td>' + esc(a.cnsmr_accnt_crdtr_rfrnc_id_txt) + '</td>' +
                '<td>' + esc(a.crdtr_shrt_nm) + '</td>' +
                '<td>' + esc(a.cnsmr_accnt_dscrptn_txt) + '</td>' +
                '<td>' + formatDate(a.cnsmr_accnt_plcmnt_date) + '</td>' +
                '<td>' + formatDate(a.cnsmr_accnt_crdtr_lst_srvc_dt) + '</td>' +
                '<td class="text-right">' + formatCurrency(a.total_paid) + '</td>' +
                '<td class="text-right">' + formatCurrency(a.invoice_balance) + '</td>' +
                '<td><button class="view-btn" onclick="Portal.selectAccount(' + a.cnsmr_accnt_id + ')">View</button></td>' +
                '</tr>';
        });

        // Totals row
        html += '<tr class="totals-row">' +
            '<td colspan="6" class="text-right"><strong>Totals:</strong></td>' +
            '<td class="text-right"><strong>' + formatCurrency(data.total_paid) + '</strong></td>' +
            '<td class="text-right"><strong>' + formatCurrency(data.total_balance_owed) + '</strong></td>' +
            '<td></td>' +
            '</tr>';

        html += '</tbody></table>';
        panel.innerHTML = html;
    }

    // ---- Demographics Tab (Addresses) ----
    async function loadConsumerAddresses() {
        var panel = document.getElementById('consumer-demographics');
        if (panel.dataset.loaded === 'true') return;
        panel.innerHTML = '<div class="loading">Loading addresses...</div>';
        try {
            var resp = await fetch('/api/client-portal/consumer/' + state.selectedConsumerId + '/addresses');
            var json = await resp.json();
            if (json.error) throw new Error(json.error);
            panel.dataset.loaded = 'true';

            if (!json.addresses || json.addresses.length === 0) {
                panel.innerHTML = '<div class="empty-state">No addresses on file.</div>';
                return;
            }

            var html = '<div class="card-grid">';
            json.addresses.forEach(function (a) {
                var statusText = getAddressStatus(a.status_cd);
                var isInvalid = (a.status_cd == 2);
                var cardClass = isInvalid ? 'info-card card-warning' : 'info-card';

                var lines = esc(a.line_1 || '');
                if (a.line_2) lines += '<br>' + esc(a.line_2);
                lines += '<br>' + esc(a.city || '') + ', ' + esc(a.state || '') + ' ' + esc(a.zip || '');

                var extra = '';
                if (isInvalid && a.mail_return_cd) {
                    extra = '<div class="card-detail warning-text">Mail Return: ' + esc(a.mail_return_cd);
                    if (a.mail_return_dt) extra += ' (' + formatDate(a.mail_return_dt) + ')';
                    extra += '</div>';
                }

                html += '<div class="' + cardClass + '">' +
                    '<div class="card-header"><span class="card-status ' + (isInvalid ? 'status-invalid' : 'status-valid') + '">' + esc(statusText) + '</span></div>' +
                    '<div class="card-body">' + lines + '</div>' +
                    extra +
                    '</div>';
            });
            html += '</div>';
            panel.innerHTML = html;
        } catch (err) {
            panel.innerHTML = '<div class="empty-state error">' + esc(err.message) + '</div>';
        }
    }

    // ---- Phones Tab ----
    async function loadConsumerPhones() {
        var panel = document.getElementById('consumer-phones');
        if (panel.dataset.loaded === 'true') return;
        panel.innerHTML = '<div class="loading">Loading phones...</div>';
        try {
            var resp = await fetch('/api/client-portal/consumer/' + state.selectedConsumerId + '/phones');
            var json = await resp.json();
            if (json.error) throw new Error(json.error);
            panel.dataset.loaded = 'true';

            if (!json.phones || json.phones.length === 0) {
                panel.innerHTML = '<div class="empty-state">No phone numbers on file.</div>';
                return;
            }

            var html = '<div class="card-grid">';
            json.phones.forEach(function (p) {
                var statusText = getPhoneStatus(p.status_cd);
                var typeText = getPhoneType(p.type_cd);
                var isWarning = (p.status_cd == 2 || p.status_cd == 4); // INVALID or DONOTCALL

                html += '<div class="info-card' + (isWarning ? ' card-warning' : '') + '">' +
                    '<div class="card-header">' +
                    '<span class="card-status ' + (isWarning ? 'status-invalid' : 'status-valid') + '">' + esc(statusText) + '</span>' +
                    '<span class="card-type">' + esc(typeText) + '</span>' +
                    '</div>' +
                    '<div class="card-body phone-number">' + formatPhone(p.number) + '</div>' +
                    '</div>';
            });
            html += '</div>';
            panel.innerHTML = html;
        } catch (err) {
            panel.innerHTML = '<div class="empty-state error">' + esc(err.message) + '</div>';
        }
    }

    // ---- Events Tab ----
    async function loadConsumerEvents() {
        if (state.consumerEvents) { renderConsumerEvents(); return; }
        var panel = document.getElementById('consumer-events-list');
        panel.innerHTML = '<div class="loading">Loading events...</div>';
        try {
            var resp = await fetch('/api/client-portal/consumer/' + state.selectedConsumerId + '/events');
            var json = await resp.json();
            if (json.error) throw new Error(json.error);
            state.consumerEvents = json.events || [];
            renderConsumerEvents();
        } catch (err) {
            panel.innerHTML = '<div class="empty-state error">' + esc(err.message) + '</div>';
        }
    }

    function renderConsumerEvents() {
        var panel = document.getElementById('consumer-events-list');
        var events = state.consumerEvents || [];
        
        var filtered = state.showAllConsumerEvents
            ? events
            : events.filter(function (e) { return isPortalEvent(e.rslt_cd); });

        if (filtered.length === 0) {
            panel.innerHTML = '<div class="empty-state">No events found' + (state.showAllConsumerEvents ? '.' : ' (toggle "Show System Notes" to see all).') + '</div>';
            return;
        }

        var html = '<div class="event-list">';
        filtered.forEach(function (e) {
            html += '<div class="event-card">' +
                '<div class="event-header">' +
                '<span class="event-codes">' + esc(getAction(e.actn_cd)) + ' — ' + esc(getResult(e.rslt_cd)) + '</span>' +
                '<span class="event-date">' + formatDateTime(e.event_date) + '</span>' +
                '</div>' +
                '<div class="event-message">' + esc(e.message) + '</div>' +
                '<div class="event-user">By: ' + esc(getUser(e.user_id)) + '</div>' +
                '</div>';
        });
        html += '</div>';
        panel.innerHTML = html;
    }

    function toggleConsumerEvents() {
        state.showAllConsumerEvents = !state.showAllConsumerEvents;
        var toggle = document.getElementById('consumer-events-toggle');
        if (toggle) toggle.classList.toggle('active', state.showAllConsumerEvents);
        renderConsumerEvents();
    }

    // ---- Outreach Tab (Documents) ----
    async function loadConsumerDocuments() {
        var panel = document.getElementById('consumer-outreach');
        if (panel.dataset.loaded === 'true') return;
        panel.innerHTML = '<div class="loading">Loading documents...</div>';
        try {
            var resp = await fetch('/api/client-portal/consumer/' + state.selectedConsumerId + '/documents');
            var json = await resp.json();
            if (json.error) throw new Error(json.error);
            panel.dataset.loaded = 'true';

            if (!json.documents || json.documents.length === 0) {
                panel.innerHTML = '<div class="empty-state">No outreach documents found.</div>';
                return;
            }

            var html = '<div class="event-list">';
            json.documents.forEach(function (d) {
                html += '<div class="event-card">' +
                    '<div class="event-header">' +
                    '<span class="event-codes">' + esc(d.template_short || d.template_name || 'Document') + '</span>' +
                    '<span class="event-date">' + formatDate(d.dcmnt_rqst_dt) + '</span>' +
                    '</div>' +
                    '<div class="event-message">' + esc(d.template_name || '') + '</div>' +
                    '</div>';
            });
            html += '</div>';
            panel.innerHTML = html;
        } catch (err) {
            panel.innerHTML = '<div class="empty-state error">' + esc(err.message) + '</div>';
        }
    }

    // ========================================================================
    // ACCOUNT DETAIL
    // ========================================================================
    async function selectAccount(acctId) {
        state.selectedAccountId = acctId;
        state.accountEvents = null;
        state.showAllAccountEvents = false;

        showPage('page-account');

        // Reset tabs to Transactions
        document.querySelectorAll('#page-account .tab-btn').forEach(function (b) {
            b.classList.toggle('active', b.dataset.tab === 'account-transactions');
        });
        document.querySelectorAll('#page-account .tab-panel').forEach(function (p) {
            p.classList.toggle('active', p.id === 'account-transactions');
        });

        // Reset events toggle
        var toggle = document.getElementById('account-events-toggle');
        if (toggle) toggle.classList.remove('active');

        // Load account header
        document.getElementById('account-header').innerHTML = '<div class="detail-card-loading">Loading account...</div>';
        document.getElementById('account-financials').innerHTML = '';

        try {
            var resp = await fetch('/api/client-portal/account/' + acctId);
            var json = await resp.json();
            if (json.error) throw new Error(json.error);
            renderAccountHeader(json.account);
            renderAccountFinancials(json.account);
        } catch (err) {
            document.getElementById('account-header').innerHTML =
                '<div class="detail-card-error">Failed to load account: ' + esc(err.message) + '</div>';
        }

        // Load transactions tab immediately
        loadAccountTransactions();
    }

    function renderAccountHeader(acct) {
        var html = '<div class="detail-card-content">' +
            '<div class="detail-card-title">' +
            renderStatusBadge(acct.status_tag) +
            '<h2>Account Details</h2>' +
            '</div>' +
            '<div class="detail-grid">' +
            '<div class="detail-item"><span class="detail-label">Client Account #:</span> ' + esc(acct.cnsmr_accnt_crdtr_rfrnc_id_txt) + '</div>' +
            '<div class="detail-item"><span class="detail-label">Placement Date:</span> ' + formatDate(acct.cnsmr_accnt_plcmnt_date) + '</div>' +
            '<div class="detail-item"><span class="detail-label">External Ref #:</span> ' + esc(acct.cnsmr_accnt_crdtr_rfrnc_corltn_id_txt) + '</div>' +
            '<div class="detail-item"><span class="detail-label">Service Date:</span> ' + formatDate(acct.cnsmr_accnt_crdtr_lst_srvc_dt) + '</div>' +
            '<div class="detail-item"><span class="detail-label">Creditor:</span> ' + esc(acct.crdtr_nm) + ' (' + esc(acct.crdtr_shrt_nm) + ')</div>' +
            '<div class="detail-item"><span class="detail-label">Patient/Regarding:</span> ' + esc(acct.cnsmr_accnt_dscrptn_txt) + '</div>' +
            '</div></div>';
        document.getElementById('account-header').innerHTML = html;
    }

    function renderAccountFinancials(acct) {
        // Find original balance from balances array (bal_nm_id = 1)
        var originalBalance = 0;
        if (acct.balances) {
            var orig = acct.balances.find(function (b) { return b.bal_nm_id == 1; });
            if (orig) originalBalance = orig.amount || 0;
        }

        var html = '<div class="financial-box">' +
                '<div class="financial-label">Original Balance</div>' +
                '<div class="financial-amount">' + formatCurrency(originalBalance) + '</div>' +
            '</div>' +
            '<div class="financial-box">' +
                '<div class="financial-label">Total Paid</div>' +
                '<div class="financial-amount financial-paid">' + formatCurrency(acct.total_paid) + '</div>' +
            '</div>' +
            '<div class="financial-box">' +
                '<div class="financial-label">Current Balance</div>' +
                '<div class="financial-amount">' + formatCurrency(acct.invoice_balance) + '</div>' +
            '</div>';

        document.getElementById('account-financials').innerHTML = html;
    }

    // ---- Account Tabs ----
    function switchAccountTab(btn) {
        var tabId = btn.dataset.tab;
        document.querySelectorAll('#page-account .tab-btn').forEach(function (b) {
            b.classList.toggle('active', b === btn);
        });
        document.querySelectorAll('#page-account .tab-panel').forEach(function (p) {
            p.classList.toggle('active', p.id === tabId);
        });

        switch (tabId) {
            case 'account-transactions': loadAccountTransactions(); break;
            case 'account-events': loadAccountEvents(); break;
            case 'account-outreach': loadAccountDocuments(); break;
        }
    }

    // ---- Transactions Tab ----
    async function loadAccountTransactions() {
        var panel = document.getElementById('account-transactions');
        if (panel.dataset.loaded === state.selectedAccountId.toString()) return;
        panel.innerHTML = '<div class="loading">Loading transactions...</div>';
        try {
            var resp = await fetch('/api/client-portal/account/' + state.selectedAccountId + '/transactions');
            var json = await resp.json();
            if (json.error) throw new Error(json.error);
            panel.dataset.loaded = state.selectedAccountId.toString();

            if (!json.transactions || json.transactions.length === 0) {
                panel.innerHTML = '<div class="empty-state">No financial transactions found.</div>';
                return;
            }

            var html = '<table class="portal-table">';
            html += '<thead><tr>' +
                '<th>Date</th>' +
                '<th>Bucket</th>' +
                '<th>Type</th>' +
                '<th>Location</th>' +
                '<th class="text-right">Amount</th>' +
                '</tr></thead><tbody>';

            json.transactions.forEach(function (t) {
                html += '<tr>' +
                    '<td>' + formatDate(t.post_date) + '</td>' +
                    '<td>' + esc(getBucket(t.bckt_id)) + '</td>' +
                    '<td>' + esc(getTxnType(t.txn_type_cd)) + '</td>' +
                    '<td>' + esc(getPaymentLocation(t.location_cd)) + '</td>' +
                    '<td class="text-right">' + formatCurrency(t.amount) + '</td>' +
                    '</tr>';
            });

            html += '</tbody></table>';
            panel.innerHTML = html;
        } catch (err) {
            panel.innerHTML = '<div class="empty-state error">' + esc(err.message) + '</div>';
        }
    }

    // ---- Account Events Tab ----
    async function loadAccountEvents() {
        if (state.accountEvents) { renderAccountEvents(); return; }
        var panel = document.getElementById('account-events-list');
        panel.innerHTML = '<div class="loading">Loading events...</div>';
        try {
            var resp = await fetch('/api/client-portal/account/' + state.selectedAccountId + '/events');
            var json = await resp.json();
            if (json.error) throw new Error(json.error);
            state.accountEvents = json.events || [];
            renderAccountEvents();
        } catch (err) {
            panel.innerHTML = '<div class="empty-state error">' + esc(err.message) + '</div>';
        }
    }

    function renderAccountEvents() {
        var panel = document.getElementById('account-events-list');
        var events = state.accountEvents || [];

        var filtered = state.showAllAccountEvents
            ? events
            : events.filter(function (e) { return isPortalEvent(e.rslt_cd); });

        if (filtered.length === 0) {
            panel.innerHTML = '<div class="empty-state">No events found' + (state.showAllAccountEvents ? '.' : ' (toggle "Show System Notes" to see all).') + '</div>';
            return;
        }

        var html = '<div class="event-list">';
        filtered.forEach(function (e) {
            html += '<div class="event-card">' +
                '<div class="event-header">' +
                '<span class="event-codes">' + esc(getAction(e.actn_cd)) + ' — ' + esc(getResult(e.rslt_cd)) + '</span>' +
                '<span class="event-date">' + formatDateTime(e.event_date) + '</span>' +
                '</div>' +
                '<div class="event-message">' + esc(e.message) + '</div>' +
                '<div class="event-user">By: ' + esc(getUser(e.user_id)) + '</div>' +
                '</div>';
        });
        html += '</div>';
        panel.innerHTML = html;
    }

    function toggleAccountEvents() {
        state.showAllAccountEvents = !state.showAllAccountEvents;
        var toggle = document.getElementById('account-events-toggle');
        if (toggle) toggle.classList.toggle('active', state.showAllAccountEvents);
        renderAccountEvents();
    }

    // ---- Account Outreach Tab ----
    async function loadAccountDocuments() {
        var panel = document.getElementById('account-outreach');
        if (panel.dataset.loaded === state.selectedAccountId.toString()) return;
        panel.innerHTML = '<div class="loading">Loading documents...</div>';
        try {
            var resp = await fetch('/api/client-portal/account/' + state.selectedAccountId + '/documents');
            var json = await resp.json();
            if (json.error) throw new Error(json.error);
            panel.dataset.loaded = state.selectedAccountId.toString();

            if (!json.documents || json.documents.length === 0) {
                panel.innerHTML = '<div class="empty-state">No outreach documents found.</div>';
                return;
            }

            var html = '<div class="event-list">';
            json.documents.forEach(function (d) {
                html += '<div class="event-card">' +
                    '<div class="event-header">' +
                    '<span class="event-codes">' + esc(d.template_short || d.template_name || 'Document') + '</span>' +
                    '<span class="event-date">' + formatDate(d.dcmnt_rqst_dt) + '</span>' +
                    '</div>' +
                    '<div class="event-message">' + esc(d.template_name || '') + '</div>' +
                    '</div>';
            });
            html += '</div>';
            panel.innerHTML = html;
        } catch (err) {
            panel.innerHTML = '<div class="empty-state error">' + esc(err.message) + '</div>';
        }
    }

    // ========================================================================
    // PUBLIC API
    // ========================================================================
    return {
        init: init,
        doSearch: doSearch,
        showSearch: showSearch,
        showResults: showResults,
        backToConsumer: backToConsumer,
        selectConsumer: selectConsumer,
        selectAccount: selectAccount,
        switchConsumerTab: switchConsumerTab,
        switchAccountTab: switchAccountTab,
        toggleConsumerEvents: toggleConsumerEvents,
        toggleAccountEvents: toggleAccountEvents,
        toggleSSN: toggleSSN
    };

})();

// Initialize on load
document.addEventListener('DOMContentLoaded', Portal.init);

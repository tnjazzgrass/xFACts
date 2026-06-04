/* ============================================================================
   xFACts Control Center - Batch Monitoring JavaScript (batch-monitoring.js)
   Location: E:\xFACts-ControlCenter\public\js\batch-monitoring.js
   Version: Tracked in dbo.System_Metadata (component: BatchOps)

   Page module for the Batch Monitoring dashboard. Loaded by the cc-shared.js
   bootloader, which reads data-cc-prefix from the body and invokes bat_init.
   Renders the daily summary cards, the live active-batch table, collector
   process status, and the batch history tree with its day-detail slideout.
   Cross-page utilities (escaping, timestamp and duration formatting, safe
   number coercion, the fetch wrapper, month/day name lookups, the engine
   card system, and the page refresh hook) are provided by cc-shared.js.

   FILE ORGANIZATION
   -----------------
   CONSTANTS: ENGINE PROCESSES
   CONSTANTS: STATUS DISPLAY MAPS
   CONSTANTS: DISPATCH TABLES
   STATE: REFRESH AND PAGE STATE
   STATE: SECTION FILTER STATE
   STATE: SLIDEOUT STATE
   FUNCTIONS: INITIALIZATION
   FUNCTIONS: REFRESH ARCHITECTURE
   FUNCTIONS: API CALLS
   FUNCTIONS: STATUS RESOLVERS
   FUNCTIONS: RENDER PROCESS STATUS
   FUNCTIONS: RENDER DAILY SUMMARY
   FUNCTIONS: RENDER ACTIVE BATCHES
   FUNCTIONS: RENDER BATCH HISTORY
   FUNCTIONS: RENDER SLIDEOUT
   FUNCTIONS: SLIDEOUT FILTER ACTIONS
   FUNCTIONS: TREE TOGGLES
   FUNCTIONS: SLIDEOUT OPEN AND CLOSE
   FUNCTIONS: FILTER ACTIONS
   FUNCTIONS: UTILITIES
   FUNCTIONS: PAGE LIFECYCLE HOOKS
   ============================================================================ */

/* ============================================================================
   CONSTANTS: ENGINE PROCESSES
   ----------------------------------------------------------------------------
   Maps each orchestrator process feeding this page's engine cards to its
   card slug. Read by cc_connectEngineEvents to wire WebSocket events to the
   nb / pmt / bdl / summary indicator cards.
   Prefix: bat
   ============================================================================ */

/* Orchestrator process-to-slug map for the four Batch Monitoring engine cards. */
var bat_ENGINE_PROCESSES = {
    'Collect-NBBatchStatus':  { slug: 'nb' },
    'Collect-PMTBatchStatus': { slug: 'pmt' },
    'Collect-BDLBatchStatus': { slug: 'bdl' },
    'Send-OpenBatchSummary':  { slug: 'summary' }
};

/* ============================================================================
   CONSTANTS: STATUS DISPLAY MAPS
   ----------------------------------------------------------------------------
   Lookup maps translating raw Debt Manager status reference values into the
   short readable labels shown in the active-batch table and slideout.
   Prefix: bat
   ============================================================================ */

/* Maps NB batch status reference values to readable labels. */
const bat_nbStatusMap = {
    'EMPTY': 'Empty', 'UPLOADING': 'Uploading', 'UPLOADFAILED': 'Upload Failed',
    'UPLOADED': 'Uploaded', 'DELETED': 'Deleted', 'RELEASENEEDED': 'Release Needed',
    'RELEASING': 'Releasing', 'RELEASED': 'Released', 'RELEASEFAILED': 'Release Failed',
    'ACTIVE': 'Active', 'PARTIALRELEASED': 'Partial Released',
    'UPLOAD_WRAP_UP': 'Upload Wrap Up', 'FAILED': 'Failed',
    'GENERATING': 'Generating', 'GENERATED': 'Generated'
};

/* Maps NB merge status reference values to readable labels. */
const bat_nbMergeStatusMap = {
    'NONE': 'None', 'POST_RELEASE_MERGING': 'Merging',
    'POST_RELEASE_MERGE_COMPLETE': 'Merge Complete',
    'POST_RELEASE_LINKING': 'Linking', 'POST_RELEASE_LINK_COMPLETE': 'Link Complete',
    'POST_RELEASE_PRTL_MRGD_WTH_ERS': 'Partial w/ Errors',
    'POST_RELEASE_MERGING_WITH_ERRORS': 'Merging w/ Errors',
    'POST_RELEASE_MERGE_CMPLT_WTH_ERS': 'Complete w/ Errors',
    'POST_RELEASE_PARTIAL_LINKED': 'Partial Linked',
    'POST_RELEASE_PARTIAL_MERGED': 'Partial Merged'
};

/* Maps PMT batch status reference values to readable labels. */
const bat_pmtStatusMap = {
    'ACTIVE': 'Active', 'RELEASED': 'Released', 'INPROCESS': 'In Process',
    'POSTED': 'Posted', 'PARTIAL': 'Partial', 'FAILED': 'Failed',
    'ARCHIVED': 'Archived', 'NEWIMPORT': 'New Import',
    'WAITINGFORIMPORT': 'Waiting for Import', 'IMPORTING': 'Importing',
    'IMPORTFAILED': 'Import Failed', 'NEWSCHEDULE': 'New Schedule',
    'CONVERTINGPAYMENTS': 'Converting', 'SCHEDULEFAILED': 'Schedule Failed',
    'WAITINGFORCONVERSION': 'Waiting for Conversion',
    'DELETEREQUESTED': 'Delete Requested', 'DELETING': 'Deleting',
    'WAITINGFORVIRTUAL': 'Waiting for Virtual',
    'PROCESSINGVIRTUAL': 'Processing Virtual', 'VIRTUALFAILED': 'Virtual Failed',
    'WAITINGTOAUTHORIZE': 'Waiting to Authorize', 'AUTHORIZING': 'Authorizing',
    'IMPORTWRAPUP': 'Import Wrap Up', 'POSTWRAPUP': 'Post Wrap Up',
    'PENDINGREVERSAL': 'Pending Reversal', 'PROCESSINGREVERSAL': 'Processing Reversal',
    'REVERSALFAILED': 'Reversal Failed', 'REVERSALWRAPUP': 'Reversal Wrap Up',
    'PROCESSED': 'Processed', 'ACTIVEWITHSUSPENSE': 'Active w/ Suspense',
    'PROCESSEDWITHSUSPENSE': 'Processed w/ Suspense'
};

/* ============================================================================
   CONSTANTS: DISPATCH TABLES
   ----------------------------------------------------------------------------
   Per-event dispatch tables routing data-action-<event> values declared in
   the page markup and in rendered HTML to their handler functions. Wired to
   a delegated body listener in bat_init.
   Prefix: bat
   ============================================================================ */

/* Routes data-action-click values to their handlers. */
const bat_clickActions = {
    'bat-set-active-filter':   bat_setActiveFilter,
    'bat-set-history-filter':  bat_setHistoryFilter,
    'bat-toggle-year':         bat_toggleYear,
    'bat-toggle-month':        bat_toggleMonth,
    'bat-open-day-detail':     bat_openDayDetail,
    'bat-toggle-batch-row':    bat_toggleBatchRow,
    'bat-set-slideout-tab':    bat_setSlideoutTab,
    'bat-set-slideout-status': bat_setSlideoutStatusFilter,
    'bat-set-slideout-pmt':    bat_setSlideoutPmtFilter,
    'bat-close-slideout':      bat_closeSlideout
};

/* ============================================================================
   STATE: REFRESH AND PAGE STATE
   ----------------------------------------------------------------------------
   Live polling cadence, the live-polling timer handle, and the page-load
   date used to force a full reload across a midnight rollover.
   Prefix: bat
   ============================================================================ */

/* Live polling interval in seconds; overridden by GlobalConfig on load. */
var bat_pageRefreshInterval = 30;

/* setInterval handle for the live Active Batches polling timer. */
var bat_livePollingTimer = null;

/* setInterval handle for the midnight-rollover reload check. */
var bat_autoRefreshTimer = null;

/* The date string at page load, compared to detect a midnight rollover. */
var bat_pageLoadDate = new Date().toDateString();

/* ============================================================================
   STATE: SECTION FILTER STATE
   ----------------------------------------------------------------------------
   Current filter selections and the last-rendered data for the Active
   Batches and Batch History sections.
   Prefix: bat
   ============================================================================ */

/* Current Active Batches type filter (ALL, NB, PMT, BDL). */
var bat_currentActiveFilter = 'ALL';

/* Last active-batch payload, retained so filter changes re-render without refetch. */
var bat_lastActiveBatchData = null;

/* Current Batch History type filter (ALL, NB, PMT, BDL). */
var bat_currentHistoryFilter = 'ALL';

/* Last history payload retained for re-rendering. */
var bat_currentHistoryData = null;

/* Map of expanded year keys in the history tree. */
var bat_expandedYears = {};

/* Map of expanded month keys in the history tree. */
var bat_expandedMonths = {};

/* ============================================================================
   STATE: SLIDEOUT STATE
   ----------------------------------------------------------------------------
   The batch-detail slideout's current tab and filter selections and the
   batch set it is currently displaying.
   Prefix: bat
   ============================================================================ */

/* Current slideout batch-type tab (ALL, NB, PMT, BDL). */
var bat_currentSlideoutTab = 'ALL';

/* Current slideout PMT sub-type filter. */
var bat_currentSlideoutPmtFilter = 'ALL';

/* Current slideout status filter (ALL, SUCCESS, FAILED, ACTIVE). */
var bat_currentSlideoutStatusFilter = 'ALL';

/* The batches currently loaded into the slideout. */
var bat_currentSlideoutBatches = [];

/* ============================================================================
   FUNCTIONS: INITIALIZATION
   ----------------------------------------------------------------------------
   The page boot function invoked by the cc-shared.js bootloader. Registers
   the delegated click listener, connects engine events, starts the live and
   midnight-rollover timers, and loads all sections.
   Prefix: bat
   ============================================================================ */

/* Page boot entry point. Wires the delegated click dispatcher, engine events, timers, and initial data load. */
async function bat_init() {
    await bat_loadRefreshInterval();

    document.body.addEventListener('click', function(event) {
        var target = event.target.closest('[data-action-click]');
        if (!target) {
            return;
        }
        var action = target.getAttribute('data-action-click');
        if (!action || action.indexOf('bat-') !== 0) {
            return;
        }
        var handler = bat_clickActions[action];
        if (handler) {
            handler(target, event);
        }
    });

    bat_refreshAll();
    cc_connectEngineEvents();
    bat_startLivePolling();
    bat_startAutoRefresh();
}

/* ============================================================================
   FUNCTIONS: REFRESH ARCHITECTURE
   ----------------------------------------------------------------------------
   The live section (Active Batches) refreshes on a GlobalConfig-driven timer;
   the event-driven sections (Today's Activity, Process Status, Batch History)
   refresh when an orchestrator process completes. A separate timer forces a
   full reload across a midnight rollover.
   Prefix: bat
   ============================================================================ */

/* Loads the page's live polling interval from GlobalConfig; falls back to the default. */
async function bat_loadRefreshInterval() {
    try {
        var data = await cc_engineFetch('/api/config/refresh-interval?page=batch');
        if (data && data.interval) {
            bat_pageRefreshInterval = data.interval;
        }
    } catch (e) {
        // Config endpoint unavailable; keep the default interval.
    }
}

/* Starts the live Active Batches polling timer; cc_engineFetch self-gates when hidden, idle, or expired. */
function bat_startLivePolling() {
    if (bat_livePollingTimer) {
        clearInterval(bat_livePollingTimer);
    }
    bat_livePollingTimer = setInterval(bat_refreshLiveSections, bat_pageRefreshInterval * 1000);
}

/* Stops the live polling timer. */
function bat_stopLivePolling() {
    if (bat_livePollingTimer) {
        clearInterval(bat_livePollingTimer);
        bat_livePollingTimer = null;
    }
}

/* Starts the timer that reloads the page when the calendar date rolls over. */
function bat_startAutoRefresh() {
    bat_autoRefreshTimer = setInterval(function() {
        var today = new Date().toDateString();
        if (today !== bat_pageLoadDate) {
            window.location.reload();
        }
    }, 60000);
}

/* Refreshes the live sections (Active Batches) and the timestamp. */
function bat_refreshLiveSections() {
    bat_loadActiveBatches();
    bat_updateTimestamp();
}

/* Refreshes the event-driven sections after an orchestrator process completes. */
function bat_refreshEventSections() {
    bat_loadProcessStatus();
    bat_loadDailySummary();
    bat_loadBatchHistory();
    bat_updateTimestamp();
}

/* Refreshes every section (manual refresh and initial load). */
function bat_refreshAll() {
    bat_loadProcessStatus();
    bat_loadDailySummary();
    bat_loadActiveBatches();
    bat_loadBatchHistory();
    bat_updateTimestamp();
}

/* Updates the last-update timestamp in the refresh info row. */
function bat_updateTimestamp() {
    var el = document.getElementById('cc-last-update');
    if (el) {
        el.textContent = new Date().toLocaleTimeString();
    }
}

/* ============================================================================
   FUNCTIONS: API CALLS
   ----------------------------------------------------------------------------
   Section data loaders. Each fetches its endpoint through cc_engineFetch and
   hands the payload to its renderer.
   Prefix: bat
   ============================================================================ */

/* Loads collector process health and renders the Process Status cards. */
function bat_loadProcessStatus() {
    cc_engineFetch('/api/batch-monitoring/process-status')
        .then(function(data) {
            if (!data) {
                return;
            }
            if (data.error) {
                console.error('Process status:', data.error);
                return;
            }
            bat_renderProcessStatus(data.processes || []);
        })
        .catch(function(err) { console.error('Failed to load process status:', err.message); });
}

/* Loads today's batch counts and renders the Daily Summary cards. */
function bat_loadDailySummary() {
    cc_engineFetch('/api/batch-monitoring/daily-summary')
        .then(function(data) {
            if (!data) {
                return;
            }
            if (data.error) {
                console.error('Daily summary:', data.error);
                return;
            }
            bat_renderDailySummary(data);
            bat_updateTimestamp();
        })
        .catch(function(err) { console.error('Failed to load daily summary:', err.message); });
}

/* Loads live in-flight batches and renders the Active Batches table. */
function bat_loadActiveBatches() {
    cc_engineFetch('/api/batch-monitoring/active-batches')
        .then(function(data) {
            if (!data) {
                return;
            }
            if (data.error) {
                console.error('Active batches:', data.error);
                return;
            }
            bat_lastActiveBatchData = data;
            bat_renderActiveBatches(data);
            bat_updateTimestamp();
        })
        .catch(function(err) { console.error('Failed to load active batches:', err.message); });
}

/* Loads the year/month history rollup and renders the Batch History tree. */
function bat_loadBatchHistory() {
    cc_engineFetch('/api/batch-monitoring/history?type=' + bat_currentHistoryFilter)
        .then(function(data) {
            if (!data) {
                return;
            }
            if (data.error) {
                console.error('Batch history:', data.error);
                return;
            }
            bat_currentHistoryData = data.data || [];
            bat_renderBatchHistory(bat_currentHistoryData);
        })
        .catch(function(err) { console.error('Failed to load batch history:', err.message); });
}

/* Loads the day-level detail for an expanded month into its container. */
function bat_loadMonthDetail(year, month) {
    var key = year + '-' + month;
    var container = document.getElementById('bat-month-detail-' + key);
    if (!container) {
        return;
    }

    container.innerHTML = '<div class="bat-loading">Loading...</div>';

    cc_engineFetch('/api/batch-monitoring/history-month?year=' + year + '&month=' + month + '&type=' + bat_currentHistoryFilter)
        .then(function(data) {
            if (!data) {
                return;
            }
            if (data.error) {
                container.innerHTML = '<div class="bat-no-activity">Error: ' + data.error + '</div>';
                return;
            }
            bat_renderMonthDetail(container, data.data || [], year, month);
        })
        .catch(function(err) {
            container.innerHTML = '<div class="bat-no-activity">Failed to load: ' + err.message + '</div>';
        });
}

/* Loads a single day's batches into the slideout and opens it. */
function bat_loadDayDetail(date) {
    document.getElementById('bat-slideout-title').textContent = 'Batches: ' + bat_formatDisplayDate(date);
    document.getElementById('bat-slideout-body').innerHTML = '<div class="bat-loading">Loading...</div>';
    bat_openSlideout();

    cc_engineFetch('/api/batch-monitoring/history-day?date=' + date + '&type=ALL')
        .then(function(data) {
            if (!data) {
                return;
            }
            if (data.error) {
                document.getElementById('bat-slideout-body').innerHTML = '<div class="bat-no-activity">Error: ' + data.error + '</div>';
                return;
            }
            bat_renderDayDetail(data.data || []);
        })
        .catch(function(err) {
            document.getElementById('bat-slideout-body').innerHTML = '<div class="bat-no-activity">Failed to load: ' + err.message + '</div>';
        });
}

/* ============================================================================
   FUNCTIONS: STATUS RESOLVERS
   ----------------------------------------------------------------------------
   Translate raw status codes into readable labels and into the badge state
   class that colors a status pill.
   Prefix: bat
   ============================================================================ */

/* Returns a readable label for a raw status value via the supplied map. */
function bat_friendlyStatus(raw, map) {
    if (!raw) {
        return 'Unknown';
    }
    var key = raw.toUpperCase().trim();
    return map[key] || raw;
}

/* Returns the badge state class for an NB batch from its batch and merge codes. */
function bat_nbStatusBadgeClass(batchCode, mergeCode) {
    if (batchCode === 3 || batchCode === 9 || batchCode === 13) {
        return 'bat-failed';
    }
    if (batchCode === 2 || batchCode === 7 || batchCode === 12 || batchCode === 14 || batchCode === 15) {
        return 'bat-active';
    }
    if (batchCode === 4 || batchCode === 6 || batchCode === 11) {
        return 'bat-waiting';
    }
    if (batchCode === 8 || batchCode === 10) {
        return 'bat-processing';
    }
    return 'bat-info';
}

/* Returns the badge state class for a PMT batch from its status code. */
function bat_pmtStatusBadgeClass(batchCode) {
    if (batchCode === 6 || batchCode === 11 || batchCode === 14 || batchCode === 20 || batchCode === 27) {
        return 'bat-failed';
    }
    if (batchCode === 5 || batchCode === 30) {
        return 'bat-failed';
    }
    if (batchCode === 3 || batchCode === 10 || batchCode === 13 || batchCode === 19 || batchCode === 22 || batchCode === 26) {
        return 'bat-active';
    }
    if (batchCode === 2 || batchCode === 8 || batchCode === 9 || batchCode === 12 || batchCode === 15 || batchCode === 18 || batchCode === 21 || batchCode === 25) {
        return 'bat-waiting';
    }
    return 'bat-info';
}

/* Returns the badge state class for a BDL file from its File_Registry status code. */
function bat_bdlStatusBadgeClass(fileRegistryCode) {
    if (fileRegistryCode === 6 || fileRegistryCode === 7) {
        return 'bat-failed';
    }
    if (fileRegistryCode === 8) {
        return 'bat-warning';
    }
    if (fileRegistryCode === 5) {
        return 'bat-processing';
    }
    if (fileRegistryCode === 4 || fileRegistryCode === 10 || fileRegistryCode === 11) {
        return 'bat-active';
    }
    return 'bat-info';
}

/* ============================================================================
   FUNCTIONS: RENDER PROCESS STATUS
   ----------------------------------------------------------------------------
   Renders the collector health cards from the process-status payload.
   Prefix: bat
   ============================================================================ */

/* Renders the Process Status cards into their container. */
function bat_renderProcessStatus(processes) {
    var container = document.getElementById('bat-process-status');

    if (!processes || processes.length === 0) {
        container.innerHTML = '<div class="bat-no-activity">No processes registered</div>';
        return;
    }

    var html = '';
    processes.forEach(function(p) {
        var secSince = cc_safeInt(p.seconds_since_run);
        var health = p.health_status || 'healthy';

        var cardClass = '';
        if (health === 'running')       { cardClass = ' bat-running'; }
        else if (health === 'critical') { cardClass = ' bat-critical'; }
        else if (health === 'warning')  { cardClass = ' bat-warning'; }

        var badgeLabel = 'OK';
        var badgeClass = 'bat-success';
        if (health === 'running')       { badgeLabel = 'Running'; badgeClass = 'bat-active'; }
        else if (health === 'critical') { badgeLabel = (p.last_status === 'FAILED') ? 'Failed' : 'Stale'; badgeClass = 'bat-failed'; }
        else if (health === 'warning')  { badgeLabel = 'Delayed'; badgeClass = 'bat-warning'; }

        html += '<div class="bat-process-card' + cardClass + '">';
        html += '<div class="bat-process-status-badge ' + badgeClass + '">' + badgeLabel + '</div>';
        html += '<div class="bat-process-info">';
        html += '<div class="bat-process-name">' + cc_escapeHtml(p.collector_name) + '</div>';
        html += '</div>';
        html += '<div class="bat-process-timing">';
        if (p.completed_dttm) {
            html += '<div class="bat-timing-value">' + cc_formatTimeSince(secSince) + ' ago</div>';
            html += '<div>' + (cc_safeInt(p.last_duration_ms) > 0 ? (cc_safeInt(p.last_duration_ms) / 1000).toFixed(1) + 's' : '') + '</div>';
        } else {
            html += '<div>Never run</div>';
        }
        html += '</div>';
        html += '</div>';
    });

    container.innerHTML = html;
}

/* ============================================================================
   FUNCTIONS: RENDER DAILY SUMMARY
   ----------------------------------------------------------------------------
   Renders the three Today's Activity cards (NB, PMT, BDL) from the daily
   summary payload.
   Prefix: bat
   ============================================================================ */

/* Renders the Daily Summary cards into their container. */
function bat_renderDailySummary(data) {
    var container = document.getElementById('bat-daily-summary');
    var nb = data.nb || {};
    var pmt = data.pmt || {};
    var bdl = data.bdl || {};

    var nbTotal  = cc_safeInt(nb.total);
    var pmtTotal = cc_safeInt(pmt.total);
    var bdlTotal = cc_safeInt(bdl.total);

    var html = '';

    html += '<div class="bat-summary-card bat-nb-card">';
    html += '<div class="bat-card-label">New Business</div>';
    html += '<div class="bat-card-value">' + nbTotal + '</div>';
    html += '<div class="bat-card-detail">';
    if (nbTotal > 0) {
        html += '<span class="bat-success">' + cc_safeInt(nb.completed) + ' complete</span>';
        if (cc_safeInt(nb.failed) > 0)         { html += '<span class="bat-failed">' + cc_safeInt(nb.failed) + ' failed</span>'; }
        if (cc_safeInt(nb.in_flight) > 0)      { html += '<span class="bat-active">' + cc_safeInt(nb.in_flight) + ' active</span>'; }
        if (cc_safeInt(nb.total_accounts) > 0) { html += '<span>' + cc_safeInt(nb.total_accounts).toLocaleString() + ' accounts</span>'; }
    } else {
        html += '<span>No batches today</span>';
    }
    html += '</div></div>';

    html += '<div class="bat-summary-card bat-pmt-card">';
    html += '<div class="bat-card-label">Payments</div>';
    html += '<div class="bat-card-value">' + pmtTotal + '</div>';
    html += '<div class="bat-card-detail">';
    if (pmtTotal > 0) {
        html += '<span class="bat-success">' + cc_safeInt(pmt.completed) + ' complete</span>';
        if (cc_safeInt(pmt.failed) > 0)         { html += '<span class="bat-failed">' + cc_safeInt(pmt.failed) + ' failed</span>'; }
        if (cc_safeInt(pmt.in_flight) > 0)      { html += '<span class="bat-active">' + cc_safeInt(pmt.in_flight) + ' active</span>'; }
        if (cc_safeInt(pmt.total_payments) > 0) { html += '<span>' + cc_safeInt(pmt.total_payments).toLocaleString() + ' payments</span>'; }
    } else {
        html += '<span>No batches today</span>';
    }
    var reapplyCount = cc_safeInt(pmt.reapply_count);
    var otherCount = cc_safeInt(pmt.other_count);
    if (reapplyCount > 0 || otherCount > 0) {
        var footnotes = [];
        if (reapplyCount > 0) { footnotes.push(reapplyCount + ' reapply'); }
        if (otherCount > 0)   { footnotes.push(otherCount + ' other'); }
        html += '<span class="bat-card-footnote">' + footnotes.join(' &middot; ') + '</span>';
    }
    html += '</div></div>';

    html += '<div class="bat-summary-card bat-bdl-card">';
    html += '<div class="bat-card-label">BDL Import</div>';
    html += '<div class="bat-card-value">' + bdlTotal + '</div>';
    html += '<div class="bat-card-detail">';
    if (bdlTotal > 0) {
        html += '<span class="bat-success">' + cc_safeInt(bdl.completed) + ' complete</span>';
        if (cc_safeInt(bdl.failed) > 0)        { html += '<span class="bat-failed">' + cc_safeInt(bdl.failed) + ' failed</span>'; }
        if (cc_safeInt(bdl.in_flight) > 0)     { html += '<span class="bat-active">' + cc_safeInt(bdl.in_flight) + ' active</span>'; }
        if (cc_safeInt(bdl.total_records) > 0) { html += '<span>' + cc_safeInt(bdl.total_records).toLocaleString() + ' records</span>'; }
    } else {
        html += '<span>No files today</span>';
    }
    html += '</div></div>';

    container.innerHTML = html;
}

/* ============================================================================
   FUNCTIONS: RENDER ACTIVE BATCHES
   ----------------------------------------------------------------------------
   Renders the filtered live active-batch table across NB, PMT, and BDL types,
   including the per-row activity indicator (status label or progress bar).
   Prefix: bat
   ============================================================================ */

/* Renders the Active Batches table from the active-batch payload, applying the current type filter. */
function bat_renderActiveBatches(data) {
    var container = document.getElementById('bat-active-batches');
    if (!data) {
        container.innerHTML = '<div class="bat-no-activity">Loading...</div>';
        return;
    }

    var nbList  = data.nb  || [];
    var pmtList = data.pmt || [];
    var bdlList = data.bdl || [];

    var showNB  = (bat_currentActiveFilter === 'ALL' || bat_currentActiveFilter === 'NB');
    var showPMT = (bat_currentActiveFilter === 'ALL' || bat_currentActiveFilter === 'PMT');
    var showBDL = (bat_currentActiveFilter === 'ALL' || bat_currentActiveFilter === 'BDL');
    var filteredNB  = showNB  ? nbList  : [];
    var filteredPMT = showPMT ? pmtList : [];
    var filteredBDL = showBDL ? bdlList : [];

    if (filteredNB.length === 0 && filteredPMT.length === 0 && filteredBDL.length === 0) {
        var msg = bat_currentActiveFilter === 'ALL' ? 'No batches currently in flight' : 'No ' + bat_currentActiveFilter + ' batches currently in flight';
        container.innerHTML = '<div class="bat-no-activity">' + msg + '</div>';
        return;
    }

    var html = '<table class="bat-active-batch-table">';
    html += '<thead><tr>';
    html += '<th class="bat-active-th">Type</th><th class="bat-active-th">Batch ID</th><th class="bat-active-th">Name</th><th class="bat-active-th">Status</th><th class="bat-active-th">Progress</th><th class="bat-active-th">Count</th><th class="bat-active-th">Time</th>';
    html += '</tr></thead><tbody>';

    filteredNB.forEach(function(b) {
        var statusDisplay = bat_friendlyStatus(b.batch_status, bat_nbStatusMap);
        if (b.merge_status) {
            statusDisplay = bat_friendlyStatus(b.merge_status, bat_nbMergeStatusMap);
        }
        var ageDisplay = cc_formatAge(cc_safeInt(b.age_minutes));
        var mergeCode = cc_safeInt(b.merge_status_code);
        var batchCode = cc_safeInt(b.batch_status_code);
        var consumerCount = cc_safeInt(b.consumer_count);
        var countDisplay = consumerCount > 0 ? consumerCount.toLocaleString() : '-';

        var activityHtml = '';
        var isInFlight = (batchCode === 2 || batchCode === 7 || batchCode === 12 || batchCode === 14 || batchCode === 15);

        if (isInFlight) {
            activityHtml = '';
        } else if (batchCode === 3 || batchCode === 13) {
            activityHtml = '<span class="bat-activity-label bat-failed">Failed</span>';
        } else if (batchCode === 9) {
            activityHtml = '<span class="bat-activity-label bat-failed">Release Failed</span>';
        } else if (mergeCode === 2 || mergeCode === 7) {
            var mergeProcessed = cc_safeInt(b.merge_processed_count);
            if (consumerCount > 0 && mergeProcessed > 0) {
                var nbPct = Math.min(100, Math.round((mergeProcessed / consumerCount) * 100));
                activityHtml = bat_progressBar(nbPct, mergeProcessed.toLocaleString() + '/' + consumerCount.toLocaleString() + ' (' + nbPct + '%)');
            } else {
                activityHtml = '<span class="bat-activity-label bat-processing">Merging</span>';
            }
        } else if (batchCode === 8 && mergeCode <= 1) {
            activityHtml = '<span class="bat-activity-label bat-waiting">In Queue</span>';
        } else if (batchCode === 4 || batchCode === 6) {
            activityHtml = '<span class="bat-activity-label bat-waiting">Awaiting Release</span>';
        } else {
            activityHtml = '<span class="bat-activity-label bat-info">' + cc_escapeHtml(statusDisplay) + '</span>';
        }

        html += '<tr class="bat-active-row">';
        html += '<td class="bat-active-td"><span class="bat-type-tag bat-type-nb">NB</span></td>';
        html += '<td class="bat-active-td">' + b.batch_id + '</td>';
        html += '<td class="bat-active-td bat-name-cell">' + cc_escapeHtml(b.batch_name) + '</td>';
        html += '<td class="bat-active-td bat-status-cell"><span class="bat-status-badge ' + bat_nbStatusBadgeClass(batchCode, mergeCode) + '">' + cc_escapeHtml(statusDisplay) + '</span></td>';
        html += '<td class="bat-active-td bat-activity-cell">' + activityHtml + '</td>';
        html += '<td class="bat-active-td bat-count-cell">' + countDisplay + '</td>';
        html += '<td class="bat-active-td bat-age-cell">' + ageDisplay + '</td>';
        html += '</tr>';
    });

    filteredPMT.forEach(function(b) {
        var statusDisplay = bat_friendlyStatus(b.batch_status, bat_pmtStatusMap);
        var ageDisplay = cc_formatAge(cc_safeInt(b.age_minutes));
        var pmtType = b.pmt_batch_type || '';
        var batchCode = cc_safeInt(b.batch_status_code);
        var activeCount = cc_safeInt(b.active_count);
        var countDisplay = activeCount > 0 ? activeCount.toLocaleString() : '-';

        var activityHtml = '';
        var isPmtInFlight = (batchCode === 10 || batchCode === 13 || batchCode === 19 || batchCode === 22 || batchCode === 26);

        if (isPmtInFlight) {
            activityHtml = '';
        } else if (batchCode === 6 || batchCode === 11 || batchCode === 27) {
            activityHtml = '<span class="bat-activity-label bat-failed">Failed</span>';
        } else if (batchCode === 5) {
            activityHtml = '<span class="bat-activity-label bat-failed">Partial</span>';
        } else if (batchCode === 30) {
            activityHtml = '<span class="bat-activity-label bat-failed">Suspense</span>';
        } else if (batchCode === 3) {
            var journalPosted = cc_safeInt(b.journal_posted_count);
            if (activeCount > 0 && journalPosted > 0) {
                var pmtPct = Math.min(100, Math.round((journalPosted / activeCount) * 100));
                activityHtml = bat_progressBar(pmtPct, journalPosted.toLocaleString() + '/' + activeCount.toLocaleString() + ' (' + pmtPct + '%)');
            } else if (activeCount > 0) {
                activityHtml = '<span class="bat-activity-label bat-waiting">Posting</span>';
            } else {
                activityHtml = '<span class="bat-activity-label bat-waiting">Awaiting Posting</span>';
            }
        } else if (batchCode === 2) {
            activityHtml = '<span class="bat-activity-label bat-waiting">Released</span>';
        } else if (batchCode === 23) {
            activityHtml = '<span class="bat-activity-label bat-info">Import Wrap Up</span>';
        } else if (batchCode === 24) {
            activityHtml = '<span class="bat-activity-label bat-info">Post Wrap Up</span>';
        } else if (batchCode === 25) {
            activityHtml = '<span class="bat-activity-label bat-waiting">Reversal Pending</span>';
        } else if (batchCode === 28) {
            activityHtml = '<span class="bat-activity-label bat-info">Reversal Wrap Up</span>';
        } else if (batchCode === 16 || batchCode === 17) {
            activityHtml = '<span class="bat-activity-label bat-info">Deleting</span>';
        } else {
            activityHtml = '<span class="bat-activity-label bat-info">' + cc_escapeHtml(pmtType || statusDisplay) + '</span>';
        }

        html += '<tr class="bat-active-row">';
        html += '<td class="bat-active-td"><span class="bat-type-tag bat-type-pmt">PMT</span></td>';
        html += '<td class="bat-active-td">' + b.batch_id + '</td>';
        html += '<td class="bat-active-td bat-name-cell">' + cc_escapeHtml(b.batch_name || b.external_name || 'Batch ' + b.batch_id) + '</td>';
        html += '<td class="bat-active-td bat-status-cell"><span class="bat-status-badge ' + bat_pmtStatusBadgeClass(batchCode) + '">' + cc_escapeHtml(statusDisplay) + '</span></td>';
        html += '<td class="bat-active-td bat-activity-cell">' + activityHtml + '</td>';
        html += '<td class="bat-active-td bat-count-cell">' + countDisplay + '</td>';
        html += '<td class="bat-active-td bat-age-cell">' + ageDisplay + '</td>';
        html += '</tr>';
    });

    filteredBDL.forEach(function(b) {
        var statusDisplay = b.file_registry_status || 'Unknown';
        var ageDisplay = cc_formatAge(cc_safeInt(b.age_minutes));
        var statusCode = cc_safeInt(b.bdl_log_status_code);
        var fileRegCode = cc_safeInt(b.file_registry_status_code);
        var totalRecords = cc_safeInt(b.total_record_count);
        var countDisplay = totalRecords > 0 ? totalRecords.toLocaleString() : '-';

        var activityHtml = '';

        if (statusCode === 8) {
            activityHtml = '<span class="bat-activity-label bat-failed">Stage Failed</span>';
        } else if (statusCode === 11) {
            activityHtml = '<span class="bat-activity-label bat-failed">Import Failed</span>';
        } else if (statusCode === 2) {
            var partCount = cc_safeInt(b.partition_count);
            var partCompleted = cc_safeInt(b.partitions_completed);
            if (partCount > 0 && partCompleted > 0) {
                var bdlPct = Math.min(100, Math.round((partCompleted / partCount) * 100));
                activityHtml = bat_progressBar(bdlPct, partCompleted + '/' + partCount + ' partitions (' + bdlPct + '%)');
            } else {
                activityHtml = '<span class="bat-activity-label bat-processing">Processing</span>';
            }
        } else if (statusCode === 10) {
            var partCount2 = cc_safeInt(b.partition_count);
            var partCompleted2 = cc_safeInt(b.partitions_completed);
            if (partCount2 > 0 && partCompleted2 > 0) {
                var bdlPct2 = Math.min(100, Math.round((partCompleted2 / partCount2) * 100));
                activityHtml = bat_progressBar(bdlPct2, partCompleted2 + '/' + partCount2 + ' partitions (' + bdlPct2 + '%)');
            } else {
                activityHtml = '<span class="bat-activity-label bat-waiting">Awaiting Import</span>';
            }
        } else {
            activityHtml = '<span class="bat-activity-label bat-info">' + cc_escapeHtml(statusDisplay) + '</span>';
        }

        var nameDisplay = b.batch_name || 'File ' + b.batch_id;
        var entityType = b.entity_type;

        html += '<tr class="bat-active-row">';
        html += '<td class="bat-active-td"><span class="bat-type-tag bat-type-bdl">BDL</span></td>';
        html += '<td class="bat-active-td">' + b.batch_id + '</td>';
        html += '<td class="bat-active-td bat-name-cell">' + cc_escapeHtml(nameDisplay);
        if (entityType) {
            html += ' <span class="bat-entity-label">' + cc_escapeHtml(entityType) + '</span>';
        }
        html += '</td>';
        html += '<td class="bat-active-td bat-status-cell"><span class="bat-status-badge ' + bat_bdlStatusBadgeClass(fileRegCode) + '">' + cc_escapeHtml(statusDisplay) + '</span></td>';
        html += '<td class="bat-active-td bat-activity-cell">' + activityHtml + '</td>';
        html += '<td class="bat-active-td bat-count-cell">' + countDisplay + '</td>';
        html += '<td class="bat-active-td bat-age-cell">' + ageDisplay + '</td>';
        html += '</tr>';
    });

    html += '</tbody></table>';
    container.innerHTML = html;
}

/* Builds the inline progress-bar markup for a percentage and overlay text. */
function bat_progressBar(pct, text) {
    var html = '<div class="bat-progress-bar-container">';
    html += '<div class="bat-progress-bar" style="width:' + pct + '%"></div>';
    html += '<span class="bat-progress-text">' + text + '</span>';
    html += '</div>';
    return html;
}

/* ============================================================================
   FUNCTIONS: RENDER BATCH HISTORY
   ----------------------------------------------------------------------------
   Renders the year/month history tree and, on month expansion, the day-level
   summary table. Aggregates across batch types and computes weighted average
   durations.
   Prefix: bat
   ============================================================================ */

/* Renders the Batch History year/month tree from the history payload. */
function bat_renderBatchHistory(data) {
    var container = document.getElementById('bat-batch-history');

    if (!data || data.length === 0) {
        container.innerHTML = '<div class="bat-no-activity">No batch history found</div>';
        return;
    }

    var yearMap = {};
    data.forEach(function(row) {
        var y = row.year;
        var m = row.month;
        if (!yearMap[y]) {
            yearMap[y] = { total: 0, completed: 0, failed: 0, in_flight: 0, months: {} };
        }
        if (!yearMap[y].months[m]) {
            yearMap[y].months[m] = { total: 0, completed: 0, failed: 0, in_flight: 0, avg_total_minutes: null, avg_weight: 0 };
        }

        var total     = cc_safeInt(row.total_batches);
        var completed = cc_safeInt(row.completed);
        var failed    = cc_safeInt(row.failed);
        var inFlight  = cc_safeInt(row.in_flight);

        yearMap[y].total     += total;
        yearMap[y].completed += completed;
        yearMap[y].failed    += failed;
        yearMap[y].in_flight += inFlight;
        yearMap[y].months[m].total     += total;
        yearMap[y].months[m].completed += completed;
        yearMap[y].months[m].failed    += failed;
        yearMap[y].months[m].in_flight += inFlight;

        if (row.avg_total_minutes != null) {
            var completedCount = completed + failed;
            var prevWeight = yearMap[y].months[m].avg_weight;
            var prevAvg    = yearMap[y].months[m].avg_total_minutes || 0;
            var newWeight  = prevWeight + completedCount;
            if (newWeight > 0) {
                yearMap[y].months[m].avg_total_minutes = Math.round(((prevAvg * prevWeight) + (cc_safeInt(row.avg_total_minutes) * completedCount)) / newWeight);
                yearMap[y].months[m].avg_weight = newWeight;
            }
        }
    });

    var sortedYears = Object.keys(yearMap).sort(function(a, b) { return b - a; });

    var html = '';
    sortedYears.forEach(function(year) {
        var yd = yearMap[year];
        var isExpanded = bat_expandedYears[year] || false;

        html += '<div class="bat-year-group">';
        html += '<div class="bat-year-header" data-action-click="bat-toggle-year" data-bat-year="' + year + '">';
        html += '<span class="bat-expand-icon ' + (isExpanded ? 'bat-expanded' : '') + '" id="bat-year-icon-' + year + '">&#9654;</span>';
        html += '<span class="bat-year-label">' + year + '</span>';
        if (yd.in_flight > 0) {
            html += '<span class="bat-year-active">' + yd.in_flight + ' active batches</span>';
        }
        html += '<div class="bat-year-stats">';
        html += '<span class="bat-year-stat">' + yd.total + ' batches</span>';
        html += '<span class="bat-year-stat bat-success">' + yd.completed + ' success</span>';
        html += '<span class="bat-year-stat bat-failed">' + (yd.failed > 0 ? yd.failed + ' failed' : '-') + '</span>';
        html += '</div>';
        html += '</div>';

        html += '<div class="bat-year-content ' + (isExpanded ? 'bat-expanded' : '') + '" id="bat-year-content-' + year + '">';

        var sortedMonths = Object.keys(yd.months).sort(function(a, b) { return b - a; });
        html += '<table class="bat-month-summary-table">';
        html += '<thead><tr><th class="bat-month-th bat-expand-cell"></th><th class="bat-month-th">Month</th><th class="bat-month-th">Batches</th><th class="bat-month-th">Completed</th><th class="bat-month-th">Failed</th><th class="bat-month-th">Active</th><th class="bat-month-th">Avg Duration</th></tr></thead>';
        html += '<tbody>';

        sortedMonths.forEach(function(month) {
            var md = yd.months[month];
            var monthKey = year + '-' + month;
            var isMonthExpanded = bat_expandedMonths[monthKey];

            html += '<tr class="bat-month-row" data-action-click="bat-toggle-month" data-bat-year="' + year + '" data-bat-month="' + month + '">';
            html += '<td class="bat-month-td bat-expand-cell"><span class="bat-expand-icon ' + (isMonthExpanded ? 'bat-expanded' : '') + '" id="bat-month-icon-' + monthKey + '">&#9654;</span></td>';
            html += '<td class="bat-month-td bat-month-cell">' + cc_MONTH_NAMES[parseInt(month, 10)] + '</td>';
            html += '<td class="bat-month-td">' + md.total + '</td>';
            html += '<td class="bat-month-td bat-success-cell">' + md.completed + '</td>';
            html += '<td class="bat-month-td bat-fail-cell">' + (md.failed > 0 ? md.failed : '-') + '</td>';
            html += '<td class="bat-month-td bat-active-cell">' + (md.in_flight > 0 ? md.in_flight : '-') + '</td>';
            html += '<td class="bat-month-td bat-duration-cell">' + (md.avg_total_minutes != null ? bat_formatDurationMinutes(md.avg_total_minutes) : '-') + '</td>';
            html += '</tr>';

            html += '<tr id="bat-month-row-' + monthKey + '" style="display:' + (isMonthExpanded ? 'table-row' : 'none') + '">';
            html += '<td class="bat-month-details-cell" colspan="7"><div class="bat-month-details-content" id="bat-month-detail-' + monthKey + '">';
            if (isMonthExpanded) {
                html += '<div class="bat-loading">Loading...</div>';
            }
            html += '</div></td></tr>';
        });

        html += '</tbody></table>';
        html += '</div></div>';
    });

    container.innerHTML = html;
}

/* Renders the day-level summary table inside an expanded month container. */
function bat_renderMonthDetail(container, data, year, month) {
    if (!data || data.length === 0) {
        container.innerHTML = '<div class="bat-no-activity">No data for this month</div>';
        return;
    }

    var dayMap = {};
    data.forEach(function(row) {
        var d = bat_parseDateOnly(row.batch_date);
        if (!dayMap[d]) {
            dayMap[d] = { total: 0, completed: 0, failed: 0, in_flight: 0, records: 0, avg_total_min: null, avg_weight: 0 };
        }

        var completed = cc_safeInt(row.completed);
        var failed    = cc_safeInt(row.failed);

        dayMap[d].total     += cc_safeInt(row.total_batches);
        dayMap[d].completed += completed;
        dayMap[d].failed    += failed;
        dayMap[d].in_flight += cc_safeInt(row.in_flight);
        dayMap[d].records   += cc_safeInt(row.total_records);

        if (row.avg_total_min != null) {
            var completedCount = completed + failed;
            var prevWeight = dayMap[d].avg_weight;
            var prevAvg    = dayMap[d].avg_total_min || 0;
            var newWeight  = prevWeight + completedCount;
            if (newWeight > 0) {
                dayMap[d].avg_total_min = Math.round(((prevAvg * prevWeight) + (cc_safeInt(row.avg_total_min) * completedCount)) / newWeight);
                dayMap[d].avg_weight = newWeight;
            }
        }
    });

    var sortedDays = Object.keys(dayMap).sort(function(a, b) { return b > a ? 1 : -1; });

    var html = '<table class="bat-day-table">';
    html += '<thead><tr><th class="bat-day-th">Date</th><th class="bat-day-th">Day</th><th class="bat-day-th">Batches</th><th class="bat-day-th">Completed</th><th class="bat-day-th">Failed</th><th class="bat-day-th">Active</th><th class="bat-day-th">Records</th><th class="bat-day-th">Avg Total</th></tr></thead>';
    html += '<tbody>';

    sortedDays.forEach(function(date) {
        var dd = dayMap[date];
        var parts = date.split('-');
        var dateObj = new Date(parseInt(parts[0], 10), parseInt(parts[1], 10) - 1, parseInt(parts[2], 10));
        var dayName = cc_DAY_NAMES[dateObj.getDay() + 1];
        var dateDisplay = (dateObj.getMonth() + 1) + '/' + dateObj.getDate();

        html += '<tr class="bat-day-row" data-action-click="bat-open-day-detail" data-bat-date="' + date + '">';
        html += '<td class="bat-day-td">' + dateDisplay + '</td>';
        html += '<td class="bat-day-td">' + dayName + '</td>';
        html += '<td class="bat-day-td">' + dd.total + '</td>';
        html += '<td class="bat-day-td bat-success-cell">' + dd.completed + '</td>';
        html += '<td class="bat-day-td bat-fail-cell">' + (dd.failed > 0 ? dd.failed : '-') + '</td>';
        html += '<td class="bat-day-td bat-active-cell">' + (dd.in_flight > 0 ? dd.in_flight : '-') + '</td>';
        html += '<td class="bat-day-td">' + (dd.records > 0 ? dd.records.toLocaleString() : '-') + '</td>';
        html += '<td class="bat-day-td bat-duration-cell">' + (dd.avg_total_min != null ? bat_formatDurationMinutes(dd.avg_total_min) : '-') + '</td>';
        html += '</tr>';
    });

    html += '</tbody></table>';
    container.innerHTML = html;
}

/* ============================================================================
   FUNCTIONS: RENDER SLIDEOUT
   ----------------------------------------------------------------------------
   Renders the batch-detail slideout body: the tab bar, filter bars, count
   summary, and the expandable per-batch rows with inline metrics and the
   phase-duration timeline.
   Prefix: bat
   ============================================================================ */

/* Receives a day's batches, seeds the slideout filters, and renders its content. */
function bat_renderDayDetail(batches) {
    var body = document.getElementById('bat-slideout-body');

    if (!batches || batches.length === 0) {
        body.innerHTML = '<div class="bat-no-activity">No batches found for this day</div>';
        return;
    }

    bat_currentSlideoutBatches = batches;
    bat_currentSlideoutTab = bat_currentHistoryFilter;
    bat_currentSlideoutPmtFilter = 'ALL';
    bat_currentSlideoutStatusFilter = 'ALL';

    bat_renderSlideoutContent();
}

/* Returns the outcome class (success, failed, active) for a batch. */
function bat_getBatchOutcome(b) {
    var isNB  = (b.batch_type === 'NB');
    var isBDL = (b.batch_type === 'BDL');
    if (!b.is_complete) {
        return 'active';
    }
    var cs = (b.completed_status || '').toUpperCase();
    if (isNB) {
        var nbSuccess = ['POST_RELEASE_MERGE_COMPLETE', 'POST_RELEASE_PRTL_MRGD_WTH_ERS',
                         'POST_RELEASE_MERGE_CMPLT_WTH_ERS', 'POST_RELEASE_PARTIAL_MERGED',
                         'POST_RELEASE_LINK_COMPLETE'];
        return (nbSuccess.indexOf(cs) >= 0) ? 'success' : 'failed';
    } else if (isBDL) {
        return (cs === 'PROCESSED' || cs === 'PARTIALLY_PROCESSED') ? 'success' : 'failed';
    } else {
        return (cs === 'POSTED') ? 'success' : 'failed';
    }
}

/* Renders the slideout body content from the current batches and filters. */
function bat_renderSlideoutContent() {
    var body = document.getElementById('bat-slideout-body');
    var batches = bat_currentSlideoutBatches;
    var hasPmt = batches.some(function(b) { return b.batch_type === 'PMT'; });

    var html = '';

    html += '<div class="bat-slideout-tab-bar">';
    var tabs = ['ALL', 'NB', 'PMT', 'BDL'];
    tabs.forEach(function(t) {
        var activeClass = (bat_currentSlideoutTab === t) ? ' bat-active' : '';
        var label = t === 'ALL' ? 'All' : t;
        var count = (t === 'ALL') ? batches.length : batches.filter(function(b) { return b.batch_type === t; }).length;
        var countActiveClass = (bat_currentSlideoutTab === t) ? ' bat-active' : '';
        var countLabel = count > 0 ? ' <span class="bat-tab-count' + countActiveClass + '">' + count + '</span>' : '';
        html += '<button class="bat-slideout-tab' + activeClass + '" data-action-click="bat-set-slideout-tab" data-bat-tab="' + t + '">' + label + countLabel + '</button>';
    });
    html += '</div>';

    html += '<div class="bat-slideout-filter-bar">';

    var statusFilters = ['ALL', 'SUCCESS', 'FAILED', 'ACTIVE'];
    statusFilters.forEach(function(f) {
        var activeClass = (bat_currentSlideoutStatusFilter === f) ? ' bat-active' : '';
        var label = f.charAt(0) + f.slice(1).toLowerCase();
        html += '<button class="bat-slideout-status-btn' + activeClass + '" data-action-click="bat-set-slideout-status" data-bat-status="' + f + '">' + label + '</button>';
    });

    if (hasPmt && (bat_currentSlideoutTab === 'PMT' || bat_currentSlideoutTab === 'ALL')) {
        html += '<span class="bat-filter-separator"></span>';
        var pmtFilters = ['ALL', 'IMPORT', 'MANUAL', 'REVERSAL', 'REAPPLY', 'OTHER'];
        pmtFilters.forEach(function(f) {
            var activeClass = (bat_currentSlideoutPmtFilter === f) ? ' bat-active' : '';
            html += '<button class="bat-slideout-filter-btn' + activeClass + '" data-action-click="bat-set-slideout-pmt" data-bat-pmt="' + f + '">' + f.charAt(0) + f.slice(1).toLowerCase() + '</button>';
        });
    }

    html += '</div>';

    var filtered = batches;
    if (bat_currentSlideoutTab !== 'ALL') {
        filtered = filtered.filter(function(b) { return b.batch_type === bat_currentSlideoutTab; });
    }

    if (bat_currentSlideoutPmtFilter !== 'ALL' && (bat_currentSlideoutTab === 'PMT' || bat_currentSlideoutTab === 'ALL')) {
        filtered = filtered.filter(function(b) {
            if (b.batch_type === 'NB' || b.batch_type === 'BDL') {
                return true;
            }
            if (bat_currentSlideoutPmtFilter === 'OTHER') {
                var knownTypes = ['IMPORT', 'MANUAL', 'REVERSAL', 'REAPPLY'];
                return knownTypes.indexOf((b.pmt_batch_type || '').toUpperCase()) === -1;
            }
            return (b.pmt_batch_type || '').toUpperCase() === bat_currentSlideoutPmtFilter;
        });
    }

    if (bat_currentSlideoutStatusFilter !== 'ALL') {
        var target = bat_currentSlideoutStatusFilter.toLowerCase();
        filtered = filtered.filter(function(b) {
            return bat_getBatchOutcome(b) === target;
        });
    }

    var successCount = 0;
    var failedCount = 0;
    var activeCount = 0;
    filtered.forEach(function(b) {
        var outcome = bat_getBatchOutcome(b);
        if (outcome === 'success')      { successCount++; }
        else if (outcome === 'failed')  { failedCount++; }
        else                            { activeCount++; }
    });

    html += '<div class="bat-slideout-batch-count">';
    html += filtered.length + ' batches';
    if (successCount > 0) { html += ' &middot; <span class="bat-count-success">' + successCount + ' success</span>'; }
    if (failedCount > 0)  { html += ' &middot; <span class="bat-count-failed">' + failedCount + ' failed</span>'; }
    if (activeCount > 0)  { html += ' &middot; <span class="bat-count-active">' + activeCount + ' in progress</span>'; }
    html += '</div>';

    if (filtered.length === 0) {
        html += '<div class="bat-no-activity">No matching batches</div>';
        body.innerHTML = html;
        return;
    }

    filtered.forEach(function(b, idx) {
        var isNB  = (b.batch_type === 'NB');
        var isBDL = (b.batch_type === 'BDL');
        var typeClass = isNB ? 'bat-type-nb' : (isBDL ? 'bat-type-bdl' : 'bat-type-pmt');
        var outcome = bat_getBatchOutcome(b);
        var batchName = '';
        if (isNB) {
            batchName = b.upload_filename || b.batch_name || '';
        } else if (isBDL) {
            batchName = b.batch_name || 'File ' + b.batch_id;
        } else {
            batchName = b.batch_name || b.external_name || 'Batch ' + b.batch_id;
        }

        var statusText = '';
        var statusClass = '';
        if (!b.is_complete) {
            statusText = b.batch_status || 'In Progress';
            statusClass = 'bat-active';
        } else {
            statusText = b.completed_status || b.batch_status || '';
            if (outcome === 'success')      { statusClass = 'bat-success'; }
            else if (outcome === 'failed')  { statusClass = 'bat-failed'; }
            else                            { statusClass = 'bat-neutral'; }
        }

        var startTime = cc_formatTimeOfDay(b.batch_created_dttm);
        var endTime = b.completed_dttm ? cc_formatTimeOfDay(b.completed_dttm) : '-';
        var totalMin = cc_safeInt(b.total_min);
        var durationText = totalMin > 0 ? bat_formatDurationMinutes(totalMin) : '-';

        html += '<div class="bat-batch-row" id="bat-batch-row-' + idx + '">';

        html += '<div class="bat-batch-row-header" data-action-click="bat-toggle-batch-row" data-bat-row="' + idx + '">';
        html += '<span class="bat-batch-row-icon" id="bat-batch-row-icon-' + idx + '">&#9654;</span>';
        html += '<span class="bat-type-tag ' + typeClass + '">' + b.batch_type + '</span>';
        html += '<span class="bat-batch-row-id">#' + b.batch_id + '</span>';
        html += '<span class="bat-batch-row-name">' + cc_escapeHtml(batchName) + '</span>';
        html += '<span class="bat-batch-row-time">' + startTime + ' &#8594; ' + endTime + '</span>';
        html += '<span class="bat-batch-row-status ' + statusClass + '">' + cc_escapeHtml(statusText) + '</span>';
        html += '</div>';

        html += '<div class="bat-batch-row-detail" id="bat-batch-row-detail-' + idx + '">';

        html += '<div class="bat-detail-metrics">';
        if (isNB) {
            html += bat_metricSpan('Accounts', b.account_count ? cc_safeInt(b.account_count).toLocaleString() : '-');
            html += bat_metricSpan('Consumers', b.consumer_count ? cc_safeInt(b.consumer_count).toLocaleString() : '-');
            html += bat_metricSpan('Balance', b.total_balance_amt ? '$' + cc_safeFloat(b.total_balance_amt).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 }) : '-');
            html += bat_metricSpan('Posted', b.posted_account_count ? cc_safeInt(b.posted_account_count).toLocaleString() : '-');
            html += bat_metricSpan('Duration', durationText);
        } else if (isBDL) {
            html += bat_metricSpan('Entity', b.entity_type || '-');
            html += bat_metricSpan('Records', b.total_record_count ? cc_safeInt(b.total_record_count).toLocaleString() : '-');
            html += bat_metricSpan('Staged', b.staging_success_count ? cc_safeInt(b.staging_success_count).toLocaleString() : '-');
            if (cc_safeInt(b.staging_failed_count) > 0) {
                html += bat_metricSpan('Stage Errors', cc_safeInt(b.staging_failed_count).toLocaleString());
            }
            html += bat_metricSpan('Imported', b.import_success_count ? cc_safeInt(b.import_success_count).toLocaleString() : '-');
            if (cc_safeInt(b.import_failed_count) > 0) {
                html += bat_metricSpan('Import Errors', cc_safeInt(b.import_failed_count).toLocaleString());
            }
            html += bat_metricSpan('Partitions', b.partition_count ? (cc_safeInt(b.partitions_completed) + '/' + cc_safeInt(b.partition_count)) : '-');
            html += bat_metricSpan('Duration', durationText);
            if (b.error_message) {
                html += bat_metricSpan('Error', cc_escapeHtml(b.error_message));
            }
        } else {
            html += bat_metricSpan('Type', b.pmt_batch_type || '-');
            html += bat_metricSpan('Payments', b.active_count ? cc_safeInt(b.active_count).toLocaleString() : '-');
            html += bat_metricSpan('Posted', b.journal_posted_count ? cc_safeInt(b.journal_posted_count).toLocaleString() : '-');
            if (cc_safeInt(b.journal_failed_count) > 0) {
                html += bat_metricSpan('Failed', cc_safeInt(b.journal_failed_count).toLocaleString());
            }
            html += bat_metricSpan('Duration', durationText);
        }
        html += '</div>';

        if (totalMin > 0) {
            html += '<div class="bat-phase-timeline">';
            html += '<div class="bat-phase-timeline-header">Phase Durations</div>';

            if (isNB) {
                html += bat_phaseRow('Upload to Release', cc_safeInt(b.upload_to_release_min), totalMin, 'bat-phase-upload');
                html += bat_phaseRow('Queue Wait', cc_safeInt(b.release_to_merge_min), totalMin, 'bat-phase-release');
                html += bat_phaseRow('Merge', cc_safeInt(b.merge_duration_min), totalMin, 'bat-phase-merge');
            } else if (isBDL) {
                html += bat_phaseRow('Created to Staged', cc_safeInt(b.created_to_staged_min), totalMin, 'bat-phase-upload');
                html += bat_phaseRow('Staged to Imported', cc_safeInt(b.staged_to_imported_min), totalMin, 'bat-phase-process');
            } else {
                html += bat_phaseRow('Created to Release', cc_safeInt(b.created_to_release_min), totalMin, 'bat-phase-upload');
                html += bat_phaseRow('Release to Processed', cc_safeInt(b.release_to_processed_min), totalMin, 'bat-phase-process');
            }
            html += bat_phaseRow('Total', totalMin, totalMin, 'bat-phase-merge');
            html += '</div>';
        }

        html += '</div>';
        html += '</div>';
    });

    body.innerHTML = html;
}

/* Builds one label/value metric span for the detail panel. */
function bat_metricSpan(label, value) {
    return '<span class="bat-detail-metric"><span class="bat-metric-label">' + label + ':</span><span class="bat-metric-value">' + value + '</span></span>';
}

/* Builds one phase row with a proportional duration bar. */
function bat_phaseRow(name, minutes, maxMinutes, colorClass) {
    var mins = cc_safeInt(minutes);
    var pct = (maxMinutes > 0 && mins > 0) ? Math.max(1, Math.round((mins / maxMinutes) * 100)) : 0;
    var html = '<div class="bat-phase-row">';
    html += '<span class="bat-phase-name">' + name + '</span>';
    html += '<div class="bat-phase-bar"><div class="bat-phase-bar-fill ' + colorClass + '" style="width:' + pct + '%"></div></div>';
    html += '<span class="bat-phase-duration">' + bat_formatDurationMinutes(mins) + '</span>';
    html += '</div>';
    return html;
}

/* ============================================================================
   FUNCTIONS: SLIDEOUT FILTER ACTIONS
   ----------------------------------------------------------------------------
   Handlers updating the slideout's tab and filter selections and re-rendering
   its content.
   Prefix: bat
   ============================================================================ */

/* Switches the slideout batch-type tab. */
function bat_setSlideoutTab(target) {
    bat_currentSlideoutTab = target.getAttribute('data-bat-tab');
    bat_currentSlideoutPmtFilter = 'ALL';
    bat_renderSlideoutContent();
}

/* Sets the slideout status filter. */
function bat_setSlideoutStatusFilter(target) {
    bat_currentSlideoutStatusFilter = target.getAttribute('data-bat-status');
    bat_renderSlideoutContent();
}

/* Sets the slideout PMT sub-type filter. */
function bat_setSlideoutPmtFilter(target) {
    bat_currentSlideoutPmtFilter = target.getAttribute('data-bat-pmt');
    bat_renderSlideoutContent();
}

/* ============================================================================
   FUNCTIONS: TREE TOGGLES
   ----------------------------------------------------------------------------
   Expand/collapse handlers for the history tree's year and month rows and the
   slideout's per-batch detail rows.
   Prefix: bat
   ============================================================================ */

/* Toggles a year group's expanded state. */
function bat_toggleYear(target) {
    var year = target.getAttribute('data-bat-year');
    var isExpanded = !bat_expandedYears[year];
    bat_expandedYears[year] = isExpanded;

    var icon = document.getElementById('bat-year-icon-' + year);
    var content = document.getElementById('bat-year-content-' + year);
    if (icon) {
        icon.classList.toggle('bat-expanded', isExpanded);
    }
    if (content) {
        content.classList.toggle('bat-expanded', isExpanded);
    }
}

/* Toggles a month row's day-detail expansion, loading day data on first open. */
function bat_toggleMonth(target) {
    var year = target.getAttribute('data-bat-year');
    var month = target.getAttribute('data-bat-month');
    var monthKey = year + '-' + month;
    var isExpanded = !bat_expandedMonths[monthKey];
    bat_expandedMonths[monthKey] = isExpanded;

    var icon = document.getElementById('bat-month-icon-' + monthKey);
    var row = document.getElementById('bat-month-row-' + monthKey);
    if (icon) {
        icon.classList.toggle('bat-expanded', isExpanded);
    }
    if (row) {
        row.style.display = isExpanded ? 'table-row' : 'none';
    }

    if (isExpanded) {
        bat_loadMonthDetail(year, month);
    }
}

/* Toggles a slideout batch row's detail panel open or closed. */
function bat_toggleBatchRow(target) {
    var idx = target.getAttribute('data-bat-row');
    var row = document.getElementById('bat-batch-row-' + idx);
    var icon = document.getElementById('bat-batch-row-icon-' + idx);
    var detail = document.getElementById('bat-batch-row-detail-' + idx);
    var willExpand = !(row && row.classList.contains('bat-expanded'));

    if (row) {
        row.classList.toggle('bat-expanded', willExpand);
    }
    if (icon) {
        icon.classList.toggle('bat-expanded', willExpand);
    }
    if (detail) {
        detail.classList.toggle('bat-expanded', willExpand);
    }
}

/* ============================================================================
   FUNCTIONS: SLIDEOUT OPEN AND CLOSE
   ----------------------------------------------------------------------------
   Open and close handlers for the batch-detail slideout, following the shared
   static slide-overlay pattern.
   Prefix: bat
   ============================================================================ */

/* Opens the batch-detail slideout. */
function bat_openSlideout() {
    var overlay = document.getElementById('bat-slideout-detail');
    var dialog = overlay.querySelector('.cc-dialog');
    overlay.classList.add('cc-open');
    requestAnimationFrame(function() {
        dialog.classList.add('cc-open');
    });
}

/* Closes the batch-detail slideout; ignores clicks bubbling from the dialog interior. */
function bat_closeSlideout(target, event) {
    if (event && target.id === 'bat-slideout-detail' && event.target !== target) {
        return;
    }
    var overlay = document.getElementById('bat-slideout-detail');
    var dialog = overlay.querySelector('.cc-dialog');
    dialog.addEventListener('transitionend', function handler() {
        dialog.removeEventListener('transitionend', handler);
        overlay.classList.remove('cc-open');
    });
    dialog.classList.remove('cc-open');
}

/* ============================================================================
   FUNCTIONS: FILTER ACTIONS
   ----------------------------------------------------------------------------
   Handlers for the Active Batches and Batch History section type filters.
   Prefix: bat
   ============================================================================ */

/* Sets the Active Batches type filter and re-renders from retained data. */
function bat_setActiveFilter(target) {
    bat_currentActiveFilter = target.getAttribute('data-bat-filter');

    var buttons = document.querySelectorAll('.bat-active-filter-btn');
    buttons.forEach(function(btn) {
        btn.classList.toggle('bat-active', btn.getAttribute('data-bat-filter') === bat_currentActiveFilter);
    });

    if (bat_lastActiveBatchData) {
        bat_renderActiveBatches(bat_lastActiveBatchData);
    }
}

/* Sets the Batch History type filter and reloads the tree. */
function bat_setHistoryFilter(target) {
    bat_currentHistoryFilter = target.getAttribute('data-bat-filter');

    var buttons = document.querySelectorAll('.bat-filter-btn');
    buttons.forEach(function(btn) {
        btn.classList.toggle('bat-active', btn.getAttribute('data-bat-filter') === bat_currentHistoryFilter);
    });

    bat_expandedYears = {};
    bat_expandedMonths = {};
    bat_loadBatchHistory();
}

/* Opens the day-detail slideout for a clicked day row. */
function bat_openDayDetail(target) {
    var date = target.getAttribute('data-bat-date');
    bat_loadDayDetail(date);
}

/* ============================================================================
   FUNCTIONS: UTILITIES
   ----------------------------------------------------------------------------
   Page-local formatting helpers with no shared equivalent: minute-duration
   formatting and the two date display/parse helpers used by the history tree
   and slideout.
   Prefix: bat
   ============================================================================ */

/* Formats a minute count as a compact duration string (m, h m, or d h). */
function bat_formatDurationMinutes(minutes) {
    var m = cc_safeInt(minutes);
    if (m <= 0) {
        return '0m';
    }
    if (m < 60) {
        return m + 'm';
    }
    var h = Math.floor(m / 60);
    var rem = m % 60;
    if (h < 24) {
        return h + 'h ' + rem + 'm';
    }
    var d = Math.floor(h / 24);
    h = h % 24;
    return d + 'd ' + h + 'h';
}

/* Formats a date-only string as a readable display date. */
function bat_formatDisplayDate(date) {
    var d = bat_parseDateOnly(date);
    var parts = d.split('-');
    var dateObj = new Date(parseInt(parts[0], 10), parseInt(parts[1], 10) - 1, parseInt(parts[2], 10));
    return cc_MONTH_NAMES[dateObj.getMonth() + 1] + ' ' + dateObj.getDate() + ', ' + dateObj.getFullYear();
}

/* Normalizes a timestamp or date value to a YYYY-MM-DD date-only string. */
function bat_parseDateOnly(value) {
    if (!value) {
        return '';
    }
    var s = String(value);
    var match = s.match(/\/Date\((\d+)\)\//);
    if (match) {
        var d = new Date(parseInt(match[1], 10));
        return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0');
    }
    if (s.indexOf('T') !== -1) {
        return s.split('T')[0];
    }
    if (s.indexOf(' ') !== -1) {
        return s.split(' ')[0];
    }
    return s;
}

/* ============================================================================
   FUNCTIONS: PAGE LIFECYCLE HOOKS
   ----------------------------------------------------------------------------
   Named callbacks the cc-shared.js chrome invokes on page refresh, tab
   resume, session expiry, and engine process completion.
   Prefix: bat
   ============================================================================ */

/* Manual page-refresh hook: refreshes every section. */
function bat_onPageRefresh() {
    bat_refreshAll();
}

/* Tab-resume hook: refreshes every section. */
function bat_onPageResumed() {
    bat_refreshAll();
}

/* Session-expiry hook: stops the live polling timer. */
function bat_onSessionExpired() {
    bat_stopLivePolling();
}

/* Engine-completion hook: refreshes the event-driven sections. */
function bat_onEngineProcessCompleted() {
    bat_refreshEventSections();
}

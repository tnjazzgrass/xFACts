/* ============================================================================
   xFACts Control Center - B2B Pipeline Page Module (b2b-pipeline.js)
   Location: E:\xFACts-ControlCenter\public\js\b2b-pipeline.js
   Version: Tracked in dbo.System_Metadata (component: B2B)

   Page module for the B2B Pipeline dashboard. Loads and renders the daily
   pulse cards, the real-time live pipeline activity table read directly
   from the Integration source, and the year/month/day history summary tree
   backed by B2B.INT_PipelineTracking - with a filtered runs modal for search
   and day drill-down, and a run-detail slideout that tells each run's full
   classification story, plus a formatted Sterling status-report view for
   failed runs.

   FILE ORGANIZATION
   -----------------
   CONSTANTS: ENGINE PROCESSES
   CONSTANTS: CLASSIFICATION DISPLAY
   CONSTANTS: HISTORY PAGING
   CONSTANTS: DISPATCH TABLES
   STATE: REFRESH AND PAGE STATE
   STATE: HISTORY TREE STATE
   STATE: RUNS MODAL STATE
   STATE: RUN DATA CACHES
   FUNCTIONS: INITIALIZATION
   FUNCTIONS: REFRESH ARCHITECTURE
   FUNCTIONS: API CALLS
   FUNCTIONS: RENDER SUMMARY
   FUNCTIONS: RENDER LIVE ACTIVITY
   FUNCTIONS: RENDER HISTORY TREE
   FUNCTIONS: TREE TOGGLES
   FUNCTIONS: RUNS MODAL AND DAY SLIDEOUT
   FUNCTIONS: RENDER RUN DETAIL
   FUNCTIONS: SLIDEOUT OPEN AND CLOSE
   FUNCTIONS: FAULT REPORT MODAL
   FUNCTIONS: UTILITIES
   FUNCTIONS: PAGE LIFECYCLE HOOKS
   ============================================================================ */

/* ============================================================================
   CONSTANTS: ENGINE PROCESSES
   ----------------------------------------------------------------------------
   Maps the orchestrator process feeding this page's engine card to its card
   slug. Read by cc_connectEngineEvents to wire WebSocket events to the B2B
   collector indicator card.
   Prefix: b2b
   ============================================================================ */

/* Orchestrator process-to-slug map for the B2B Pipeline engine card. */
var b2b_ENGINE_PROCESSES = {
    'Collect-B2BPipeline': { slug: 'b2b' }
};

/* ============================================================================
   CONSTANTS: CLASSIFICATION DISPLAY
   ----------------------------------------------------------------------------
   Display metadata for the status vocabularies: the twelve detailed status
   classifications (label, badge state, and plain-English meaning shown in the
   run-detail slideout) and the five coarse Sterling-level statuses (label and
   badge state). The vocabularies mirror the CHECK constraints on
   B2B.INT_PipelineTracking.status_classification and sterling_status.
   Prefix: b2b
   ============================================================================ */

/* Maps each status classification to its label, badge state, and meaning. */
const b2b_classificationMeta = {
    'IN_FLIGHT': {
        label: 'In Flight', state: 'b2b-flight',
        meaning: 'The run is presumed executing. Its source row is at status 0 and has not aged past the cross-check threshold.'
    },
    'AWAITING_DM': {
        label: 'Awaiting DM', state: 'b2b-flight',
        meaning: 'The B2B side is done and the run is waiting for the Integration reconciliation job to confirm the DM outcome.'
    },
    'COMPLETE': {
        label: 'Complete', state: 'b2b-ok',
        meaning: 'Fully complete. For NB/PAY/BDL handoffs this includes DM-side confirmation written by the reconciliation job.'
    },
    'NO_FILES': {
        label: 'No Files', state: 'b2b-neutral',
        meaning: 'The run genuinely acquired no files to process. A normal outcome for polling runs that found nothing waiting.'
    },
    'NO_HANDOFF': {
        label: 'No Handoff', state: 'b2b-warn',
        meaning: 'Files were acquired (nonzero-size pickups exist) but the run never handed a batch to DM.'
    },
    'DUPLICATE': {
        label: 'Duplicate', state: 'b2b-warn',
        meaning: 'A duplicate file was detected and processing was suppressed.'
    },
    'CASCADE_SKIP': {
        label: 'Cascade Skip', state: 'b2b-neutral',
        meaning: 'This run was skipped because its predecessor in a SEQUENTIAL chain failed.'
    },
    'STERLING_FAULT': {
        label: 'Sterling Fault', state: 'b2b-crit',
        meaning: 'The workflow faulted on the Sterling side with no DM rejection possible - either before any handoff, or on a process type with no DM arm.'
    },
    'DM_REJECTED': {
        label: 'DM Rejected', state: 'b2b-crit',
        meaning: 'DM rejected the batch after handoff. The DM batch reached a failed or deleted terminal code.'
    },
    'FAULT_POST_HANDOFF': {
        label: 'Fault Post-Handoff', state: 'b2b-crit',
        meaning: 'The data landed in DM but the pipeline faulted afterward - cleanup and notification steps may not have run.'
    },
    'DIED_UNHANDLED': {
        label: 'Died Unhandled', state: 'b2b-crit',
        meaning: 'The run terminated in Sterling without reaching a fault handler. Its status row will never self-update; the Sterling cross-check classified it.'
    },
    'UNCLASSIFIED': {
        label: 'Unclassified', state: 'b2b-neutral',
        meaning: 'The collector could not resolve a classification from the available evidence. Persistent unclassified runs indicate a collector or source problem.'
    }
};

/* Maps each Sterling-level status to its label and badge state. */
const b2b_sterlingStatusMeta = {
    'SUCCESS':     { label: 'Success',     state: 'b2b-ok' },
    'FAILED':      { label: 'Failed',      state: 'b2b-crit' },
    'NO_ACTION':   { label: 'No Action',   state: 'b2b-neutral' },
    'IN_PROGRESS': { label: 'In Progress', state: 'b2b-flight' },
    'UNDEFINED':   { label: 'Undefined',   state: 'b2b-neutral' }
};

/* Maps each process_type to its badge label. Labels start as the raw value;
   shorten any of them here without touching layout or color. The full raw
   value is always shown as the badge tooltip. A run with a NULL process_type
   is a parent/dispatcher run and badges as DISPATCHER. Any value not listed
   here falls back to its raw string on a neutral badge. */
const b2b_processTypeMeta = {
    'NEW_BUSINESS':      { label: 'NB' },
    'PAYMENT':           { label: 'PMT' },
    'BDL':               { label: 'BDL' },
    'STANDARD_BDL':      { label: 'STANDARD_BDL' },
    'SFTP_PULL':         { label: 'SFTP_PULL' },
    'SFTP_PUSH':         { label: 'SFTP_PUSH' },
    'SFTP_PUSH_ED25519': { label: 'SFTP_PUSH_ED25519' },
    'SPECIAL_PROCESS':   { label: 'SPECIAL_PROCESS' },
    'CORE_PROCESS':      { label: 'CORE_PROCESS' },
    'RETURN':            { label: 'RETURN' },
    'REMIT':             { label: 'REMIT' },
    'RECON':             { label: 'RECON' },
    'NCOA':              { label: 'NCOA' },
    'ITS':               { label: 'ITS' },
    'ENCOUNTER':         { label: 'ENCOUNTER' },
    'ACKNOWLEDGMENT':    { label: 'ACKNOWLEDGMENT' },
    'FULL_INVENTORY':    { label: 'FULL_INVENTORY' },
    'FILE_DELETION':     { label: 'FILE_DELETION' },
    'FILE_EMAIL':        { label: 'FILE_EMAIL' },
    'SIMPLE_EMAIL':      { label: 'SIMPLE_EMAIL' },
    'EMAIL_SCRUB':       { label: 'EMAIL_SCRUB' },
    'NOTES_EMAIL':       { label: 'NOTES_EMAIL' },
    'NOTES':             { label: 'NOTES' },
    'NOTE':              { label: 'NOTE' }
};

/* ============================================================================
   CONSTANTS: HISTORY PAGING
   ----------------------------------------------------------------------------
   Fixed paging size for the runs modal.
   Prefix: b2b
   ============================================================================ */

/* Number of runs fetched per modal page. */
const b2b_HISTORY_PAGE_SIZE = 30;

/* ============================================================================
   CONSTANTS: DISPATCH TABLES
   ----------------------------------------------------------------------------
   Per-event action dispatch tables routing data-action-* attribute values to
   their handler functions.
   Prefix: b2b
   ============================================================================ */

/* Click action dispatch table. */
const b2b_clickActions = {
    'b2b-toggle-year':      b2b_toggleYear,
    'b2b-toggle-month':     b2b_toggleMonth,
    'b2b-open-day-runs':    b2b_openDayRuns,
    'b2b-run-search':       b2b_runSearch,
    'b2b-reset-filters':    b2b_resetFilters,
    'b2b-runs-page':        b2b_runsPage,
    'b2b-close-runs-slideout': b2b_closeRunsModal,
    'b2b-day-page':         b2b_dayPage,
    'b2b-close-day-slideout': b2b_closeDaySlideout,
    'b2b-open-run-detail':  b2b_openRunDetail,
    'b2b-open-tile':        b2b_openTile,
    'b2b-close-slideout':   b2b_closeSlideout,
    'b2b-open-fault-report':  b2b_openFaultReport,
    'b2b-close-fault-report': b2b_closeFaultReport,
    'b2b-fault-entries-mode': b2b_setFaultEntriesMode,
    'b2b-fault-view-mode':    b2b_setFaultViewMode,
    'b2b-fault-rawblock-toggle': b2b_toggleFaultRawBlock
};

/* Keydown action dispatch table. */
const b2b_keydownActions = {
    'b2b-search-on-enter': b2b_searchOnEnter
};

/* ============================================================================
   STATE: REFRESH AND PAGE STATE
   ----------------------------------------------------------------------------
   Live polling interval, timers, and the midnight-rollover marker.
   Prefix: b2b
   ============================================================================ */

/* Live section polling interval in seconds; overridden from GlobalConfig. */
var b2b_pageRefreshInterval = 30;

/* Live section polling timer handle. */
var b2b_livePollingTimer = null;

/* Midnight-rollover check timer handle. */
var b2b_autoRefreshTimer = null;

/* Calendar date at page load, for midnight-rollover detection. */
var b2b_pageLoadDate = new Date().toDateString();

/* ============================================================================
   STATE: HISTORY TREE STATE
   ----------------------------------------------------------------------------
   The per-day summary data behind the history tree and the current year and
   month expansion states.
   Prefix: b2b
   ============================================================================ */

/* Per-day history summary rows from the summary endpoint. */
var b2b_summaryData = null;

/* Expanded year keys in the history tree. */
var b2b_expandedYears = {};

/* Expanded year-month keys in the history tree. */
var b2b_expandedMonths = {};

/* ============================================================================
   STATE: RUNS MODAL STATE
   ----------------------------------------------------------------------------
   The filter set, page position, and total row count driving the runs
   modal, plus the date and paging state driving the day-runs slideout.
   Prefix: b2b
   ============================================================================ */

/* Filter set the runs modal is currently displaying. */
var b2b_modalFilters = {};

/* Current zero-based runs-modal page index. */
var b2b_modalPageIndex = 0;

/* Total row count matching the current modal filters. */
var b2b_modalTotal = 0;

/* Date the day-runs slideout is currently displaying. */
var b2b_dayDate = '';

/* Current zero-based day-slideout page index. */
var b2b_dayPageIndex = 0;

/* Total row count for the day the slideout is displaying. */
var b2b_dayTotal = 0;

/* ============================================================================
   STATE: RUN DATA CACHES
   ----------------------------------------------------------------------------
   The most recent row sets returned by the live and modal endpoints, kept
   for slideout fallbacks without refetching, plus the fault-report
   slideout's loaded report and its view-toggle state.
   Prefix: b2b
   ============================================================================ */

/* Most recent live-activity row set. */
var b2b_lastLiveData = null;

/* Most recent runs-modal row set. */
var b2b_lastModalData = null;

/* Most recently loaded fault report row; re-renders read it without refetching. */
var b2b_faultReport = null;

/* Fault-report entries filter: true shows all entries, false errors only. */
var b2b_faultShowAll = false;

/* Fault-report view mode: true shows the raw report text, false the formatted view. */
var b2b_faultShowRaw = false;

/* ============================================================================
   FUNCTIONS: INITIALIZATION
   ----------------------------------------------------------------------------
   The page boot function invoked by the cc-shared.js bootloader. Registers
   the delegated event listeners, connects engine events, starts the live and
   midnight-rollover timers, and loads all sections.
   Prefix: b2b
   ============================================================================ */

/* Page boot entry point. Wires the delegated dispatchers, engine events, timers, and initial load. */
async function b2b_init() {
    await b2b_loadRefreshInterval();

    document.body.addEventListener('click', function(event) {
        var target = event.target.closest('[data-action-click]');
        if (!target) {
            return;
        }
        var action = target.getAttribute('data-action-click');
        if (!action || action.indexOf('b2b-') !== 0) {
            return;
        }
        var handler = b2b_clickActions[action];
        if (handler) {
            handler(target, event);
        }
    });

    document.body.addEventListener('keydown', function(event) {
        var target = event.target.closest('[data-action-keydown]');
        if (!target) {
            return;
        }
        var action = target.getAttribute('data-action-keydown');
        if (!action || action.indexOf('b2b-') !== 0) {
            return;
        }
        var handler = b2b_keydownActions[action];
        if (handler) {
            handler(target, event);
        }
    });

    b2b_populateFilterOptions();
    b2b_refreshAll();
    cc_connectEngineEvents();
    b2b_startLivePolling();
    b2b_startAutoRefresh();
}

/* ============================================================================
   FUNCTIONS: REFRESH ARCHITECTURE
   ----------------------------------------------------------------------------
   The live sections (pulse cards, live activity) refresh on a
   GlobalConfig-driven timer; the event-driven history summary tree refreshes
   when the collector process completes. A separate timer forces a full
   reload across a midnight rollover.
   Prefix: b2b
   ============================================================================ */

/* Loads the page's live polling interval from GlobalConfig; falls back to the default. */
async function b2b_loadRefreshInterval() {
    try {
        var data = await cc_engineFetch('/api/config/refresh-interval?page=b2b');
        if (data && data.interval) {
            b2b_pageRefreshInterval = data.interval;
        }
    } catch (e) {
        // Config endpoint unavailable; keep the default interval.
    }
}

/* Starts the live section polling timer. */
function b2b_startLivePolling() {
    if (b2b_livePollingTimer) {
        clearInterval(b2b_livePollingTimer);
    }
    b2b_livePollingTimer = setInterval(b2b_refreshLiveSections, b2b_pageRefreshInterval * 1000);
}

/* Stops the live polling timer. */
function b2b_stopLivePolling() {
    if (b2b_livePollingTimer) {
        clearInterval(b2b_livePollingTimer);
        b2b_livePollingTimer = null;
    }
}

/* Starts the timer that reloads the page when the calendar date rolls over. */
function b2b_startAutoRefresh() {
    b2b_autoRefreshTimer = setInterval(function() {
        var today = new Date().toDateString();
        if (today !== b2b_pageLoadDate) {
            window.location.reload();
        }
    }, 60000);
}

/* Refreshes the live sections (pulse cards, live activity) and the timestamp. */
function b2b_refreshLiveSections() {
    b2b_loadSummary();
    b2b_loadLiveActivity();
    b2b_updateTimestamp();
}

/* Refreshes the event-driven sections after the collector completes. */
function b2b_refreshEventSections() {
    b2b_loadHistorySummary();
    b2b_updateTimestamp();
}

/* Refreshes every section (manual refresh and initial load). */
function b2b_refreshAll() {
    b2b_loadSummary();
    b2b_loadLiveActivity();
    b2b_loadHistorySummary();
    b2b_updateTimestamp();
}

/* Updates the last-update timestamp in the refresh info row. */
function b2b_updateTimestamp() {
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
   Prefix: b2b
   ============================================================================ */

/* Loads today's pulse counts and renders the summary cards. */
function b2b_loadSummary() {
    cc_engineFetch('/api/b2b-pipeline/summary')
        .then(function(data) {
            if (!data) {
                return;
            }
            b2b_renderSummary(data.summary);
        })
        .catch(function(e) {
            b2b_renderSectionError('b2b-summary-cards', e);
        });
}

/* Loads the current in-motion runs directly from the Integration source and renders the live table. */
function b2b_loadLiveActivity() {
    cc_engineFetch('/api/b2b-pipeline/live')
        .then(function(data) {
            if (!data) {
                return;
            }
            b2b_lastLiveData = data.runs;
            b2b_renderLiveActivity(data.runs);
        })
        .catch(function(e) {
            b2b_renderSectionError('b2b-live-activity', e);
        });
}

/* Loads the per-day history summary and renders the tree. */
function b2b_loadHistorySummary() {
    cc_engineFetch('/api/b2b-pipeline/history-summary')
        .then(function(data) {
            if (!data) {
                return;
            }
            b2b_summaryData = data.days;
            b2b_renderHistoryTree();
        })
        .catch(function(e) {
            b2b_renderSectionError('b2b-history-tree', e);
        });
}

/* Loads a page of filtered runs into the modal. */
function b2b_loadModalRuns() {
    var params = [];
    params.push('page=' + b2b_modalPageIndex);
    params.push('pageSize=' + b2b_HISTORY_PAGE_SIZE);
    if (b2b_modalFilters.client) {
        params.push('client=' + encodeURIComponent(b2b_modalFilters.client));
    }
    if (b2b_modalFilters.sterlingStatus && b2b_modalFilters.sterlingStatus !== 'ALL') {
        params.push('sterlingStatus=' + encodeURIComponent(b2b_modalFilters.sterlingStatus));
    }
    if (b2b_modalFilters.type && b2b_modalFilters.type !== 'ALL') {
        params.push('type=' + encodeURIComponent(b2b_modalFilters.type));
    }
    if (b2b_modalFilters.from) {
        params.push('from=' + encodeURIComponent(b2b_modalFilters.from));
    }
    if (b2b_modalFilters.to) {
        params.push('to=' + encodeURIComponent(b2b_modalFilters.to));
    }
    if (b2b_modalFilters.incomplete) {
        params.push('incomplete=1');
    }

    cc_engineFetch('/api/b2b-pipeline/history?' + params.join('&'))
        .then(function(data) {
            if (!data) {
                return;
            }
            b2b_lastModalData = data.runs;
            b2b_modalTotal = cc_safeInt(data.total);
            b2b_renderModalRuns(data.runs);
        })
        .catch(function(e) {
            b2b_renderSectionError('b2b-runs-content', e);
        });
}

/* Loads one run's full detail and renders the slideout body. */
function b2b_loadRunDetail(runId) {
    cc_engineFetch('/api/b2b-pipeline/run?runId=' + encodeURIComponent(runId))
        .then(function(data) {
            if (data && data.run) {
                b2b_renderRunDetail(data.run);
            }
            else {
                b2b_renderRunNotCollected(runId);
            }
        })
        .catch(function(e) {
            b2b_renderSectionError('b2b-slideout-body', e);
        });
}

/* ============================================================================
   FUNCTIONS: RENDER SUMMARY
   ----------------------------------------------------------------------------
   Renders the six daily pulse cards from the summary endpoint payload.
   Prefix: b2b
   ============================================================================ */

/* Renders the pulse summary cards. */
function b2b_renderSummary(summary) {
    var container = document.getElementById('b2b-summary-cards');
    if (!container || !summary) {
        return;
    }

    var liveCounts = b2b_countLiveTiles(b2b_lastLiveData);

    var cards = [
        { label: 'Runs Today',   value: cc_safeInt(summary.runs_today),    state: '' },
        { label: 'In Flight',    value: liveCounts.inFlight,               state: 'b2b-flight',  liveKey: 'in-flight' },
        { label: 'Awaiting DM',  value: liveCounts.awaitingDm,             state: 'b2b-flight',  liveKey: 'awaiting-dm' },
        { label: 'Success',      value: cc_safeInt(summary.completed),     state: 'b2b-ok',      tile: 'completed' },
        { label: 'No Action',    value: cc_safeInt(summary.no_files),      state: 'b2b-neutral', tile: 'no-files' },
        { label: 'Failed',       value: cc_safeInt(summary.failures),      state: 'b2b-crit',    tile: 'failures' }
    ];

    var html = '';
    cards.forEach(function(card) {
        var classList = 'b2b-summary-card';
        if (card.state) {
            classList += ' ' + card.state;
        }
        var actionAttrs = '';
        if (card.tile) {
            classList += ' b2b-card-clickable';
            actionAttrs = ' data-action-click="b2b-open-tile" data-b2b-tile="' + card.tile + '"';
        }
        var valueAttrs = card.liveKey ? ' data-b2b-live-key="' + card.liveKey + '"' : '';
        html += '<div class="' + classList + '"' + actionAttrs + '>' +
                '<div class="b2b-card-label">' + cc_escapeHtml(card.label) + '</div>' +
                '<div class="b2b-card-value"' + valueAttrs + '>' + card.value + '</div>' +
                '</div>';
    });

    container.innerHTML = html;
}

/* Opens the runs slideout pre-filtered to a clicked pulse tile's population,
   matching that tile's count window exactly. */
function b2b_openTile(target) {
    var tile = target.getAttribute('data-b2b-tile');
    var today = b2b_todayDateString();

    if (tile === 'completed') {
        b2b_modalFilters = {
            sterlingStatus: 'SUCCESS',
            from: today, to: today,
            caption: 'Success - today'
        };
    } else if (tile === 'failures') {
        b2b_modalFilters = {
            sterlingStatus: 'FAILED',
            from: today, to: today,
            caption: 'Failed - today'
        };
    } else if (tile === 'no-files') {
        b2b_modalFilters = {
            sterlingStatus: 'NO_ACTION',
            from: today, to: today,
            caption: 'No Action - today'
        };
    } else {
        return;
    }

    b2b_openRunsModal();
}

/* ============================================================================
   FUNCTIONS: RENDER LIVE ACTIVITY
   ----------------------------------------------------------------------------
   Renders the current in-motion runs as clickable rows with client, type,
   dispatcher, classification badge, and age.
   Prefix: b2b
   ============================================================================ */

/* Renders the live activity table from the in-motion row set. */
function b2b_renderLiveActivity(runs) {
    b2b_updateLiveTileCounts(runs);

    var container = document.getElementById('b2b-live-activity');
    if (!container) {
        return;
    }

    if (!runs || runs.length === 0) {
        container.innerHTML = '<div class="b2b-empty">No pipeline runs currently in motion</div>';
        return;
    }

    var html = '<div class="b2b-table-head b2b-cols-live">' +
               '<div>Type</div><div>Run ID</div><div>Client</div><div>Status</div><div class="b2b-head-num">Age</div>' +
               '</div>';

    runs.forEach(function(run) {
        html += b2b_buildRunRowHtml(run, 'b2b-cols-live', false, false);
    });

    container.innerHTML = html;
}

/* Counts the in-flight and awaiting-DM runs in a live payload. */
function b2b_countLiveTiles(runs) {
    var counts = { inFlight: 0, awaitingDm: 0 };
    if (runs) {
        runs.forEach(function(run) {
            if (run.status_classification === 'IN_FLIGHT') {
                counts.inFlight++;
            }
            else if (run.status_classification === 'AWAITING_DM') {
                counts.awaitingDm++;
            }
        });
    }
    return counts;
}

/* Sets the In Flight and Awaiting DM tile counts from the live payload, so the
   cards always match the runs shown in the live activity window below them. */
function b2b_updateLiveTileCounts(runs) {
    var counts = b2b_countLiveTiles(runs);

    var container = document.getElementById('b2b-summary-cards');
    if (!container) {
        return;
    }
    var inFlightCell = container.querySelector('[data-b2b-live-key="in-flight"]');
    if (inFlightCell) {
        inFlightCell.textContent = counts.inFlight.toLocaleString();
    }
    var awaitingCell = container.querySelector('[data-b2b-live-key="awaiting-dm"]');
    if (awaitingCell) {
        awaitingCell.textContent = counts.awaitingDm.toLocaleString();
    }
}

/* ============================================================================
   FUNCTIONS: RENDER HISTORY TREE
   ----------------------------------------------------------------------------
   Builds the year / month / day accordion from the per-day summary rows and
   the current expansion state. Day rows open the runs modal for their date.
   Prefix: b2b
   ============================================================================ */

/* Renders the history summary tree from the cached per-day rows. */
function b2b_renderHistoryTree() {
    var container = document.getElementById('b2b-history-tree');
    if (!container) {
        return;
    }

    if (!b2b_summaryData || b2b_summaryData.length === 0) {
        container.innerHTML = '<div class="b2b-empty">No run history available</div>';
        return;
    }

    /* Group the day rows into a year -> month -> days structure with rollups. */
    var years = {};
    b2b_summaryData.forEach(function(day) {
        var dateStr = b2b_parseDateOnly(day.run_date);
        var parts = dateStr.split('-');
        if (parts.length !== 3) {
            return;
        }
        var y = parts[0];
        var m = parts[1];

        if (!years[y]) {
            years[y] = { months: {}, total: 0, success: 0, failed: 0, noAction: 0, inProgress: 0, undefinedCount: 0 };
        }
        if (!years[y].months[m]) {
            years[y].months[m] = { days: [], total: 0, success: 0, failed: 0, noAction: 0, inProgress: 0, undefinedCount: 0, durationWeight: 0 };
        }

        day.date_str = dateStr;
        years[y].months[m].days.push(day);
        years[y].months[m].total += cc_safeInt(day.total);
        years[y].months[m].success += cc_safeInt(day.success);
        years[y].months[m].failed += cc_safeInt(day.failed);
        years[y].months[m].noAction += cc_safeInt(day.no_action);
        years[y].months[m].inProgress += cc_safeInt(day.in_progress);
        years[y].months[m].undefinedCount += cc_safeInt(day.undefined_count);
        years[y].months[m].durationWeight += cc_safeInt(day.avg_duration_min) * cc_safeInt(day.total);
        years[y].total += cc_safeInt(day.total);
        years[y].success += cc_safeInt(day.success);
        years[y].failed += cc_safeInt(day.failed);
        years[y].noAction += cc_safeInt(day.no_action);
        years[y].inProgress += cc_safeInt(day.in_progress);
        years[y].undefinedCount += cc_safeInt(day.undefined_count);
    });

    var html = '';
    var yearKeys = Object.keys(years).sort().reverse();
    yearKeys.forEach(function(y) {
        var yr = years[y];
        var yearOpen = b2b_expandedYears[y] === true;

        html += '<div class="b2b-history-year">';
        html += '<div class="b2b-year-header" data-action-click="b2b-toggle-year" data-b2b-year="' + y + '">' +
                '<span class="b2b-tree-chevron' + (yearOpen ? ' b2b-expanded' : '') + '">&#9654;</span>' +
                '<span class="b2b-year-label">' + y + '</span>' +
                '<div class="b2b-year-stats">' +
                (yr.inProgress > 0 ? '<span class="b2b-year-stat b2b-year-stat-progress">' + yr.inProgress.toLocaleString() + ' in progress</span>' : '') +
                '<span class="b2b-year-stat">' + yr.total.toLocaleString() + ' runs</span>' +
                '<span class="b2b-year-stat b2b-year-stat-ok">' + yr.success.toLocaleString() + ' success</span>' +
                '<span class="b2b-year-stat b2b-year-stat-crit">' + yr.failed.toLocaleString() + ' failed</span>' +
                '<span class="b2b-year-stat">' + yr.noAction.toLocaleString() + ' no action</span>' +
                '<span class="b2b-year-stat">' + yr.undefinedCount.toLocaleString() + ' undefined</span>' +
                '</div>' +
                '</div>';

        if (yearOpen) {
            html += '<div class="b2b-year-content">';
            html += '<table class="b2b-month-summary-table">';
            html += '<thead><tr>' +
                    '<th class="b2b-month-th"></th>' +
                    '<th class="b2b-month-th">Month</th>' +
                    '<th class="b2b-month-th b2b-th-num">Runs</th>' +
                    '<th class="b2b-month-th b2b-th-num">Success</th>' +
                    '<th class="b2b-month-th b2b-th-num">Failed</th>' +
                    '<th class="b2b-month-th b2b-th-num">No Action</th>' +
                    '<th class="b2b-month-th b2b-th-num">In Progress</th>' +
                    '<th class="b2b-month-th b2b-th-num">Undefined</th>' +
                    '<th class="b2b-month-th b2b-th-num">Avg Duration</th>' +
                    '</tr></thead>';

            var monthKeys = Object.keys(yr.months).sort().reverse();
            monthKeys.forEach(function(m) {
                var mo = yr.months[m];
                var mKey = y + '-' + m;
                var monthOpen = b2b_expandedMonths[mKey] === true;

                html += '<tbody>';
                html += '<tr class="b2b-month-row" data-action-click="b2b-toggle-month" data-b2b-month="' + mKey + '">' +
                        '<td class="b2b-month-td b2b-expand-cell"><span class="b2b-tree-chevron' + (monthOpen ? ' b2b-expanded' : '') + '">&#9654;</span></td>' +
                        '<td class="b2b-month-td b2b-month-cell">' + cc_escapeHtml(cc_MONTH_NAMES[parseInt(m, 10)]) + '</td>' +
                        b2b_buildTreeCellsHtml(mo, 'b2b-month-td') +
                        '</tr>';

                if (monthOpen) {
                    html += '<tr class="b2b-month-details"><td class="b2b-month-td b2b-month-details-cell" colspan="9">';
                    html += '<table class="b2b-history-table">';
                    html += '<thead><tr>' +
                            '<th class="b2b-history-th">Date</th>' +
                            '<th class="b2b-history-th">Day</th>' +
                            '<th class="b2b-history-th b2b-th-num">Runs</th>' +
                            '<th class="b2b-history-th b2b-th-num">Success</th>' +
                            '<th class="b2b-history-th b2b-th-num">Failed</th>' +
                            '<th class="b2b-history-th b2b-th-num">No Action</th>' +
                            '<th class="b2b-history-th b2b-th-num">In Progress</th>' +
                            '<th class="b2b-history-th b2b-th-num">Undefined</th>' +
                            '<th class="b2b-history-th b2b-th-num">Avg Duration</th>' +
                            '</tr></thead><tbody>';

                    mo.days.forEach(function(day) {
                        var labels = b2b_treeDayLabelParts(day.date_str);
                        html += '<tr class="b2b-day-row" data-action-click="b2b-open-day-runs" data-b2b-date="' + day.date_str + '">' +
                                '<td class="b2b-history-td b2b-day-date-cell">' + cc_escapeHtml(labels.date) + '</td>' +
                                '<td class="b2b-history-td b2b-day-dow-cell">' + cc_escapeHtml(labels.dow) + '</td>' +
                                b2b_buildTreeCellsHtml({
                                    total: cc_safeInt(day.total),
                                    success: cc_safeInt(day.success),
                                    failed: cc_safeInt(day.failed),
                                    noAction: cc_safeInt(day.no_action),
                                    inProgress: cc_safeInt(day.in_progress),
                                    undefinedCount: cc_safeInt(day.undefined_count),
                                    durationWeight: cc_safeInt(day.avg_duration_min) * cc_safeInt(day.total)
                                }, 'b2b-history-td') +
                                '</tr>';
                    });

                    html += '</tbody></table>';
                    html += '</td></tr>';
                }

                html += '</tbody>';
            });

            html += '</table>';
            html += '</div>';
        }

        html += '</div>';
    });

    container.innerHTML = html;
}

/* Builds the numeric cells (runs, success, failed, no action, in progress,
   undefined, avg duration) for a month or day table row. Zero counts render as
   a dash. */
function b2b_buildTreeCellsHtml(node, tdClass) {
    var avg = node.total > 0 ? Math.round(node.durationWeight / node.total) : 0;
    return '<td class="' + tdClass + ' b2b-th-num b2b-cell-runs">' + node.total.toLocaleString() + '</td>' +
           '<td class="' + tdClass + ' b2b-th-num b2b-cell-ok">' + b2b_treeCount(node.success) + '</td>' +
           '<td class="' + tdClass + ' b2b-th-num b2b-cell-crit">' + b2b_treeCount(node.failed) + '</td>' +
           '<td class="' + tdClass + ' b2b-th-num b2b-cell-num">' + b2b_treeCount(node.noAction) + '</td>' +
           '<td class="' + tdClass + ' b2b-th-num b2b-cell-progress">' + b2b_treeCount(node.inProgress) + '</td>' +
           '<td class="' + tdClass + ' b2b-th-num b2b-cell-num">' + b2b_treeCount(node.undefinedCount) + '</td>' +
           '<td class="' + tdClass + ' b2b-th-num b2b-cell-num">' + (avg > 0 ? b2b_formatDurationMinutes(avg) : '-') + '</td>';
}

/* Formats a tree count, rendering zero as a dash to reduce visual clutter. */
function b2b_treeCount(value) {
    return value > 0 ? value.toLocaleString() : '-';
}

/* ============================================================================
   FUNCTIONS: TREE TOGGLES
   ----------------------------------------------------------------------------
   Single-open expansion handlers: opening a year collapses the others and
   clears their month expansions; opening a month collapses the other months
   within its year.
   Prefix: b2b
   ============================================================================ */

/* Toggles a year row's expansion and re-renders the tree. Opening a year
   closes all other years and clears every month expansion. */
function b2b_toggleYear(target) {
    var y = target.getAttribute('data-b2b-year');
    var opening = b2b_expandedYears[y] !== true;
    b2b_expandedYears = {};
    b2b_expandedMonths = {};
    if (opening) {
        b2b_expandedYears[y] = true;
    }
    b2b_renderHistoryTree();
}

/* Toggles a month row's expansion and re-renders the tree. Opening a month
   closes the other months within its year. */
function b2b_toggleMonth(target) {
    var mKey = target.getAttribute('data-b2b-month');
    var opening = b2b_expandedMonths[mKey] !== true;
    b2b_expandedMonths = {};
    if (opening) {
        b2b_expandedMonths[mKey] = true;
    }
    b2b_renderHistoryTree();
}

/* ============================================================================
   FUNCTIONS: RUNS MODAL AND DAY SLIDEOUT
   ----------------------------------------------------------------------------
   The filtered runs modal opened by the search controls, and the day-runs
   slideout opened by a day row - each rendering paged run rows with the
   pager pinned beneath, following the static modal and slide-overlay
   open/close patterns.
   Prefix: b2b
   ============================================================================ */

/* Search button handler: opens the runs modal with the filter-bar values. */
function b2b_runSearch() {
    var search = document.getElementById('b2b-search-input');
    var status = document.getElementById('b2b-filter-status');
    var type = document.getElementById('b2b-filter-type');
    var from = document.getElementById('b2b-filter-from');
    var to = document.getElementById('b2b-filter-to');

    b2b_modalFilters = {
        client: search ? search.value.trim() : '',
        sterlingStatus: status ? status.value : 'ALL',
        type: type ? type.value : 'ALL',
        from: from ? from.value : '',
        to: to ? to.value : ''
    };

    b2b_openRunsModal();
}

/* Search box Enter-key handler: opens the runs modal with the filter-bar values. */
function b2b_searchOnEnter(target, event) {
    if (event && event.key === 'Enter') {
        b2b_runSearch();
    }
}

/* Clears every filter control in the filter bar. */
function b2b_resetFilters() {
    var search = document.getElementById('b2b-search-input');
    var status = document.getElementById('b2b-filter-status');
    var type = document.getElementById('b2b-filter-type');
    var from = document.getElementById('b2b-filter-from');
    var to = document.getElementById('b2b-filter-to');

    if (search) { search.value = ''; }
    if (status) { status.value = 'ALL'; }
    if (type) { type.value = 'ALL'; }
    if (from) { from.value = ''; }
    if (to) { to.value = ''; }
}

/* Day row handler: opens the day-runs slideout for the clicked date. */
function b2b_openDayRuns(target) {
    var date = target.getAttribute('data-b2b-date');
    if (!date) {
        return;
    }

    b2b_dayDate = date;
    b2b_dayPageIndex = 0;

    var title = document.getElementById('b2b-slideout-day-title');
    if (title) {
        title.textContent = 'Runs - ' + b2b_formatDisplayDate(date);
    }

    var content = document.getElementById('b2b-day-content');
    if (content) {
        content.innerHTML = '<div class="b2b-loading">Loading...</div>';
    }

    var overlay = document.getElementById('b2b-slideout-day');
    var dialog = overlay.querySelector('.cc-dialog');
    overlay.classList.add('cc-open');
    requestAnimationFrame(function() {
        dialog.classList.add('cc-open');
    });

    b2b_loadDayRuns();
}

/* Closes the day-runs slideout on backdrop click or the close button. */
function b2b_closeDaySlideout(target, event) {
    if (event && target.id === 'b2b-slideout-day' && event.target !== target) {
        return;
    }
    var overlay = document.getElementById('b2b-slideout-day');
    var dialog = overlay.querySelector('.cc-dialog');
    dialog.addEventListener('transitionend', function handler() {
        dialog.removeEventListener('transitionend', handler);
        overlay.classList.remove('cc-open');
    });
    dialog.classList.remove('cc-open');
}

/* Loads a page of the day-slideout's runs from the history endpoint. */
function b2b_loadDayRuns() {
    var params = [];
    params.push('page=' + b2b_dayPageIndex);
    params.push('pageSize=' + b2b_HISTORY_PAGE_SIZE);
    params.push('from=' + encodeURIComponent(b2b_dayDate));
    params.push('to=' + encodeURIComponent(b2b_dayDate));

    cc_engineFetch('/api/b2b-pipeline/history?' + params.join('&'))
        .then(function(data) {
            if (!data) {
                return;
            }
            b2b_dayTotal = cc_safeInt(data.total);
            b2b_renderDayRuns(data.runs);
        })
        .catch(function(e) {
            b2b_renderSectionError('b2b-day-content', e);
        });
}

/* Renders the day-slideout results page and updates its pager. */
function b2b_renderDayRuns(runs) {
    var content = document.getElementById('b2b-day-content');
    if (!content) {
        return;
    }

    if (!runs || runs.length === 0) {
        content.innerHTML = '<div class="b2b-empty">No runs on this day</div>';
    }
    else {
        var html = '<div class="b2b-table-head b2b-cols-history">' +
                   '<div>Type</div><div>Run ID</div><div>Run Start</div><div>Client</div><div>Dispatcher</div><div>Status</div><div class="b2b-head-num">Duration</div>' +
                   '</div>';

        runs.forEach(function(run) {
            html += b2b_buildRunRowHtml(run, 'b2b-cols-history', true, true);
        });

        content.innerHTML = html;
    }

    var info = document.getElementById('b2b-day-count');
    var prev = document.getElementById('b2b-day-prev');
    var next = document.getElementById('b2b-day-next');
    var pageCount = Math.max(1, Math.ceil(b2b_dayTotal / b2b_HISTORY_PAGE_SIZE));
    var pageNum = b2b_dayPageIndex + 1;

    if (info) {
        info.textContent = b2b_dayTotal.toLocaleString() + ' runs | page ' +
            pageNum.toLocaleString() + ' of ' + pageCount.toLocaleString();
    }
    if (prev) {
        prev.disabled = (b2b_dayPageIndex <= 0);
    }
    if (next) {
        next.disabled = (pageNum >= pageCount);
    }
}

/* Day-slideout pager handler: moves one page in the direction carried by the button. */
function b2b_dayPage(target) {
    var dir = target.getAttribute('data-b2b-dir');
    var pageCount = Math.max(1, Math.ceil(b2b_dayTotal / b2b_HISTORY_PAGE_SIZE));

    if (dir === 'prev' && b2b_dayPageIndex > 0) {
        b2b_dayPageIndex--;
        b2b_loadDayRuns();
    }
    if (dir === 'next' && (b2b_dayPageIndex + 1) < pageCount) {
        b2b_dayPageIndex++;
        b2b_loadDayRuns();
    }
}

/* Opens the runs slideout, sets its caption, and loads the first page. */
function b2b_openRunsModal() {
    b2b_modalPageIndex = 0;

    var caption = document.getElementById('b2b-runs-caption');
    if (caption) {
        caption.textContent = b2b_describeModalFilters();
    }

    var content = document.getElementById('b2b-runs-content');
    if (content) {
        content.innerHTML = '<div class="b2b-loading">Loading...</div>';
    }

    var overlay = document.getElementById('b2b-slideout-runs');
    var dialog = overlay.querySelector('.cc-dialog');
    overlay.classList.add('cc-open');
    requestAnimationFrame(function() {
        dialog.classList.add('cc-open');
    });

    b2b_loadModalRuns();
}

/* Closes the runs slideout on backdrop click or the close button. */
function b2b_closeRunsModal(target, event) {
    if (event && target.id === 'b2b-slideout-runs' && event.target !== target) {
        return;
    }
    var overlay = document.getElementById('b2b-slideout-runs');
    var dialog = overlay.querySelector('.cc-dialog');
    dialog.addEventListener('transitionend', function handler() {
        dialog.removeEventListener('transitionend', handler);
        overlay.classList.remove('cc-open');
    });
    dialog.classList.remove('cc-open');
}

/* Builds the caption text describing the modal's active filters. */
function b2b_describeModalFilters() {
    if (b2b_modalFilters.caption) {
        return b2b_modalFilters.caption;
    }
    var parts = [];
    if (b2b_modalFilters.client) {
        parts.push('client contains "' + b2b_modalFilters.client + '"');
    }
    if (b2b_modalFilters.sterlingStatus && b2b_modalFilters.sterlingStatus !== 'ALL') {
        var meta = b2b_sterlingStatusMeta[b2b_modalFilters.sterlingStatus];
        parts.push('status ' + (meta ? meta.label : b2b_modalFilters.sterlingStatus));
    }
    if (b2b_modalFilters.type && b2b_modalFilters.type !== 'ALL') {
        parts.push('type ' + b2b_modalFilters.type);
    }
    if (b2b_modalFilters.from && b2b_modalFilters.to && b2b_modalFilters.from === b2b_modalFilters.to) {
        parts.push(b2b_formatDisplayDate(b2b_modalFilters.from));
    }
    else {
        if (b2b_modalFilters.from) {
            parts.push('from ' + b2b_formatDisplayDate(b2b_modalFilters.from));
        }
        if (b2b_modalFilters.to) {
            parts.push('to ' + b2b_formatDisplayDate(b2b_modalFilters.to));
        }
    }
    return parts.length > 0 ? parts.join(' | ') : 'All runs';
}

/* Renders the modal results page and updates the pager. */
function b2b_renderModalRuns(runs) {
    var content = document.getElementById('b2b-runs-content');
    if (!content) {
        return;
    }

    if (!runs || runs.length === 0) {
        content.innerHTML = '<div class="b2b-empty">No runs match the current filters</div>';
    }
    else {
        var html = '<div class="b2b-table-head b2b-cols-history">' +
                   '<div>Type</div><div>Run ID</div><div>Run Start</div><div>Client</div><div>Dispatcher</div><div>Status</div><div class="b2b-head-num">Duration</div>' +
                   '</div>';

        runs.forEach(function(run) {
            html += b2b_buildRunRowHtml(run, 'b2b-cols-history', true, true);
        });

        content.innerHTML = html;
    }

    b2b_updateModalPager();
}

/* Updates the modal pager caption and button disabled states. */
function b2b_updateModalPager() {
    var info = document.getElementById('b2b-runs-count');
    var prev = document.getElementById('b2b-runs-prev');
    var next = document.getElementById('b2b-runs-next');

    var pageCount = Math.max(1, Math.ceil(b2b_modalTotal / b2b_HISTORY_PAGE_SIZE));
    var pageNum = b2b_modalPageIndex + 1;

    if (info) {
        info.textContent = b2b_modalTotal.toLocaleString() + ' runs | page ' +
            pageNum.toLocaleString() + ' of ' + pageCount.toLocaleString();
    }
    if (prev) {
        prev.disabled = (b2b_modalPageIndex <= 0);
    }
    if (next) {
        next.disabled = (pageNum >= pageCount);
    }
}

/* Modal pager handler: moves one page in the direction carried by the button. */
function b2b_runsPage(target) {
    var dir = target.getAttribute('data-b2b-dir');
    var pageCount = Math.max(1, Math.ceil(b2b_modalTotal / b2b_HISTORY_PAGE_SIZE));

    if (dir === 'prev' && b2b_modalPageIndex > 0) {
        b2b_modalPageIndex--;
        b2b_loadModalRuns();
    }
    if (dir === 'next' && (b2b_modalPageIndex + 1) < pageCount) {
        b2b_modalPageIndex++;
        b2b_loadModalRuns();
    }
}

/* Builds the process-type badge for a run. NULL process_type is a
   parent/dispatcher run. The full raw value is the tooltip. */
function b2b_buildTypeBadgeHtml(processType) {
    if (!processType) {
        return '<span class="b2b-type-badge b2b-type-dispatcher" title="Parent / dispatcher run">DISPATCHER</span>';
    }
    var meta = b2b_processTypeMeta[processType];
    var label = meta ? meta.label : processType;
    var cls = 'b2b-type-' + processType.toLowerCase();
    return '<span class="b2b-type-badge ' + cls + '" title="' + cc_escapeHtml(processType) + '">' +
           cc_escapeHtml(label) + '</span>';
}

/* Builds one run row for the live table or modal results. History rows are
   clickable and carry a Run Start and Dispatcher column; live rows are static
   and omit both. Both lead with the process-type badge and the run id. */
function b2b_buildRunRowHtml(run, colsClass, withTiming, useSterlingStatus) {
    var meta;
    if (useSterlingStatus) {
        meta = b2b_sterlingStatusMeta[run.sterling_status];
    }
    else {
        meta = b2b_classificationMeta[run.status_classification];
    }
    var rawStatus = useSterlingStatus ? run.sterling_status : run.status_classification;
    var label = meta ? meta.label : rawStatus;
    var state = meta ? meta.state : 'b2b-neutral';
    var clientName = run.client_name ? run.client_name : ('client ' + run.client_id);
    var dispatcher = run.dispatcher_name ? run.dispatcher_name : '-';

    var cells = '<div>' + b2b_buildTypeBadgeHtml(run.process_type) + '</div>' +
                '<div class="b2b-cell-muted">' + cc_safeInt(run.run_id) + '</div>';
    if (withTiming) {
        cells += '<div class="b2b-cell-muted">' + cc_escapeHtml(b2b_formatDttm(run.source_insert_dttm)) + '</div>';
    }
    cells += '<div class="b2b-cell-primary">' + cc_escapeHtml(clientName) + '</div>';
    if (withTiming) {
        cells += '<div class="b2b-cell-muted">' + cc_escapeHtml(dispatcher) + '</div>';
    }
    cells += '<div><span class="b2b-badge ' + state + '">' + cc_escapeHtml(label) + '</span></div>';
    if (withTiming) {
        cells += '<div class="b2b-cell-num">' + cc_escapeHtml(b2b_formatDurationMinutes(run.duration_minutes)) + '</div>';
    }
    else {
        cells += '<div class="b2b-cell-num">' + cc_escapeHtml(b2b_formatDurationMinutes(run.age_minutes)) + '</div>';
    }

    // History rows (withTiming) open the run-detail slideout from the tracked
    // table. Live rows are not clickable: an in-flight run may not be collected
    // into the table yet, so its detail would render empty.
    if (withTiming) {
        return '<button class="b2b-run-row ' + colsClass + '" data-action-click="b2b-open-run-detail" ' +
               'data-b2b-run-id="' + cc_safeInt(run.run_id) + '">' + cells + '</button>';
    }
    return '<div class="b2b-run-row b2b-run-row-static ' + colsClass + '">' + cells + '</div>';
}

/* ============================================================================
   FUNCTIONS: RENDER RUN DETAIL
   ----------------------------------------------------------------------------
   Renders one run's full story into the slideout body: the Sterling status
   headline badge and the detailed classification badge and meaning, then
   fixed two-column label/value sections for identity, timing, and outcome
   evidence.
   Prefix: b2b
   ============================================================================ */

/* Renders the run-detail slideout body from a full tracking row. */
function b2b_renderRunDetail(run) {
    var body = document.getElementById('b2b-slideout-body');
    var title = document.getElementById('b2b-slideout-title');
    if (!body) {
        return;
    }

    var meta = b2b_classificationMeta[run.status_classification];
    var label = meta ? meta.label : run.status_classification;
    var state = meta ? meta.state : 'b2b-neutral';
    var meaning = meta ? meta.meaning : '';
    var clientName = run.client_name ? run.client_name : ('client ' + run.client_id);

    var statusMeta = b2b_sterlingStatusMeta[run.sterling_status];
    var statusLabel = statusMeta ? statusMeta.label : run.sterling_status;
    var statusState = statusMeta ? statusMeta.state : 'b2b-neutral';

    if (title) {
        title.textContent = clientName + ' - Run ' + run.run_id;
    }

    var html = '<div class="b2b-detail-section">' +
               '<div class="b2b-detail-title">Sterling Status</div>' +
               '<div class="b2b-detail-badge-line"><span class="b2b-badge ' + statusState + '">' +
               cc_escapeHtml(statusLabel) + '</span></div>' +
               '</div>';

    html += '<div class="b2b-detail-section">' +
               '<div class="b2b-detail-title">Classification</div>' +
               '<div class="b2b-detail-badge-line"><span class="b2b-badge ' + state + '">' +
               cc_escapeHtml(label) + '</span></div>' +
               '<div class="b2b-detail-meaning">' + cc_escapeHtml(meaning) + '</div>' +
               '</div>';

    html += '<div class="b2b-detail-section">' +
            '<div class="b2b-detail-title">Identity</div>' +
            b2b_buildDetailRowHtml('Run ID', run.run_id) +
            b2b_buildDetailRowHtml('Parent ID', run.parent_id) +
            b2b_buildDetailRowHtml('Client', clientName + ' (' + run.client_id + ')') +
            b2b_buildDetailRowHtml('Seq ID', run.seq_id) +
            b2b_buildDetailRowHtml('Process Type', run.process_type) +
            b2b_buildDetailRowHtml('Comm Method', run.comm_method) +
            b2b_buildDetailRowHtml('Dispatcher', run.dispatcher_name) +
            '</div>';

    html += '<div class="b2b-detail-section">' +
            '<div class="b2b-detail-title">Timing</div>' +
            b2b_buildDetailRowHtml('Run Start', b2b_formatDttm(run.source_insert_dttm)) +
            b2b_buildDetailRowHtml('Source Finish', b2b_formatDttm(run.source_finish_dttm)) +
            b2b_buildDetailRowHtml('Completed', b2b_formatDttm(run.completed_dttm)) +
            b2b_buildDetailRowHtml('Duration', b2b_formatDurationMinutes(run.duration_minutes)) +
            '</div>';

    html += '<div class="b2b-detail-section">' +
            '<div class="b2b-detail-title">Outcome Detail</div>' +
            b2b_buildDetailRowHtml('Raw Source Status', run.batch_status) +
            b2b_buildDetailRowHtml('DM Batch ID', run.batch_id) +
            b2b_buildDetailRowHtml('DM Status Code', run.dm_batch_status_code) +
            b2b_buildDetailRowHtml('Sterling Check', run.sterling_check_result) +
            b2b_buildDetailRowHtml('Alerts Fired', run.alert_count) +
            b2b_buildDetailRowHtml('First Collected', b2b_formatDttm(run.collected_dttm)) +
            b2b_buildDetailRowHtml('Last Polled', b2b_formatDttm(run.last_polled_dttm)) +
            '</div>';

    if (run.has_fault_report) {
        html += b2b_buildFaultBlockHtml(run);
    }

    body.innerHTML = html;
}

/* Renders the slideout body for a live run the collector has not mirrored yet. */
function b2b_renderRunNotCollected(runId) {
    var body = document.getElementById('b2b-slideout-body');
    var title = document.getElementById('b2b-slideout-title');
    if (!body) {
        return;
    }

    var cached = null;
    if (b2b_lastLiveData) {
        b2b_lastLiveData.forEach(function(run) {
            if (String(run.run_id) === String(runId)) {
                cached = run;
            }
        });
    }

    var clientName = cached && cached.client_name ? cached.client_name : ('Run ' + runId);
    if (title) {
        title.textContent = clientName + ' - Run ' + runId;
    }

    var html = '<div class="b2b-detail-section">' +
               '<div class="b2b-detail-title">Awaiting First Collection</div>' +
               '<div class="b2b-detail-meaning">This run just started and the collector has not mirrored it yet. Full detail appears after the next collection cycle.</div>' +
               '</div>';

    if (cached) {
        html += '<div class="b2b-detail-section">' +
                '<div class="b2b-detail-title">Live Snapshot</div>' +
                b2b_buildDetailRowHtml('Run ID', cached.run_id) +
                b2b_buildDetailRowHtml('Client', clientName) +
                b2b_buildDetailRowHtml('Process Type', cached.process_type) +
                b2b_buildDetailRowHtml('Comm Method', cached.comm_method) +
                b2b_buildDetailRowHtml('Run Start', b2b_formatDttm(cached.source_insert_dttm)) +
                b2b_buildDetailRowHtml('Age', b2b_formatDurationMinutes(cached.age_minutes)) +
                '</div>';
    }

    body.innerHTML = html;
}

/* Builds one fixed two-column label/value row for the slideout. */
function b2b_buildDetailRowHtml(label, value) {
    var display = (value === null || value === undefined || value === '') ? '-' : String(value);
    return '<div class="b2b-detail-row">' +
           '<span class="b2b-detail-label">' + cc_escapeHtml(label) + '</span>' +
           '<span class="b2b-detail-value">' + cc_escapeHtml(display) + '</span>' +
           '</div>';
}

/* Builds the fault-report section for a run that carries a captured Sterling
   status report: the summary callout (type, code, summary, capture time) and
   the button opening the full report. Only called when a report exists. */
function b2b_buildFaultBlockHtml(run) {
    return '<div class="b2b-detail-section">' +
           '<div class="b2b-detail-title">Fault Report</div>' +
           '<div class="b2b-fault-callout">' +
           '<div class="b2b-fault-header">' +
           '<span class="b2b-fault-type">' +
           cc_escapeHtml(run.fault_report_type ? run.fault_report_type : '-') + '</span>' +
           '<span class="b2b-fault-code">' +
           cc_escapeHtml(run.fault_report_code ? run.fault_report_code : '-') + '</span>' +
           '</div>' +
           '<div class="b2b-fault-summary">' +
           cc_escapeHtml(run.fault_report_summary ? run.fault_report_summary : '-') + '</div>' +
           '<div class="b2b-fault-captured">Captured ' +
           cc_escapeHtml(b2b_formatDttm(run.fault_report_captured_dttm)) + '</div>' +
           '<button class="b2b-fault-view-btn" data-action-click="b2b-open-fault-report" ' +
           'data-b2b-run-id="' + cc_safeInt(run.run_id) + '">View Full Report</button>' +
           '</div>' +
           '</div>';
}

/* ============================================================================
   FUNCTIONS: SLIDEOUT OPEN AND CLOSE
   ----------------------------------------------------------------------------
   The run-detail slideout open and close handlers, following the shared
   static slide-overlay pattern. Opening from the runs modal closes the
   modal first.
   Prefix: b2b
   ============================================================================ */

/* Opens the run-detail slideout for the clicked row's run. */
function b2b_openRunDetail(target) {
    var runId = target.getAttribute('data-b2b-run-id');
    if (!runId) {
        return;
    }

    /* If the click came from the runs slideout or day slideout, close it first. */
    var runsOverlay = document.getElementById('b2b-slideout-runs');
    if (runsOverlay && runsOverlay.classList.contains('cc-open')) {
        var runsDialog = runsOverlay.querySelector('.cc-dialog');
        runsDialog.classList.remove('cc-open');
        runsOverlay.classList.remove('cc-open');
    }
    var dayOverlay = document.getElementById('b2b-slideout-day');
    if (dayOverlay && dayOverlay.classList.contains('cc-open')) {
        var dayDialog = dayOverlay.querySelector('.cc-dialog');
        dayDialog.classList.remove('cc-open');
        dayOverlay.classList.remove('cc-open');
    }

    var body = document.getElementById('b2b-slideout-body');
    if (body) {
        body.innerHTML = '<div class="b2b-loading">Loading...</div>';
    }

    var overlay = document.getElementById('b2b-slideout-run');
    var dialog = overlay.querySelector('.cc-dialog');
    overlay.classList.add('cc-open');
    requestAnimationFrame(function() {
        dialog.classList.add('cc-open');
    });

    b2b_loadRunDetail(runId);
}

/* Closes the run-detail slideout on backdrop click or the close button. */
function b2b_closeSlideout(target, event) {
    if (event && target.id === 'b2b-slideout-run' && event.target !== target) {
        return;
    }
    var overlay = document.getElementById('b2b-slideout-run');
    var dialog = overlay.querySelector('.cc-dialog');
    dialog.addEventListener('transitionend', function handler() {
        dialog.removeEventListener('transitionend', handler);
        overlay.classList.remove('cc-open');
    });
    dialog.classList.remove('cc-open');
}

/* ============================================================================
   FUNCTIONS: FAULT REPORT MODAL
   ----------------------------------------------------------------------------
   The full Sterling status-report slideout opened from a failed run's fault
   block. Opens the overlay, loads the captured report for the run, and
   renders a formatted view built from the parsed report JSON: report
   metadata rows, count chips, and severity-badged entry cards carrying the
   full per-entry Info detail, with an errors-only filter, collapsible raw
   block data, a raw-report view switch, and a pretty-printed JSON fallback
   for unrecognized shapes. TRANSLATION_ESCALATED reports (recovered from
   the run's last successful Translation step) render identically with an
   Escalated By metadata row carrying the failing step's one-line message;
   warning-only reports default to the all-entries view.
   Prefix: b2b
   ============================================================================ */

/* Opens the full status-report slideout and loads the run's captured report. */
function b2b_openFaultReport(target) {
    var runId = target.getAttribute('data-b2b-run-id');

    var title = document.getElementById('b2b-fault-report-title');
    if (title) {
        title.textContent = 'Status Report - Run ' + runId;
    }

    b2b_faultReport = null;
    b2b_faultShowAll = false;
    b2b_faultShowRaw = false;

    var body = document.getElementById('b2b-fault-report-body');
    if (body) {
        body.innerHTML = '<div class="b2b-loading">Loading...</div>';
    }

    var overlay = document.getElementById('b2b-slideout-fault');
    var dialog = overlay.querySelector('.cc-dialog');
    overlay.classList.add('cc-open');
    requestAnimationFrame(function() {
        dialog.classList.add('cc-open');
    });

    b2b_loadFaultReport(runId);
}

/* Loads one run's captured fault report and renders the slideout body. */
function b2b_loadFaultReport(runId) {
    cc_engineFetch('/api/b2b-pipeline/fault-report?runId=' + encodeURIComponent(runId))
        .then(function(data) {
            b2b_renderFaultReport(data ? data.report : null);
        })
        .catch(function(e) {
            b2b_renderSectionError('b2b-fault-report-body', e);
        });
}

/* Stores the loaded report and renders the slideout body. Warning-only
   translation reports (typical for escalated recoveries) would greet the
   user with an empty errors-only list, so those default to the all-entries
   view; the toolbar filter remains available either way. */
function b2b_renderFaultReport(report) {
    b2b_faultReport = report;

    if (report && report.report_json && b2b_isTranslationReportType(report.fault_report_type)) {
        try {
            var payload = JSON.parse(report.report_json);
            var entries = payload && payload.entries ? payload.entries : [];
            var errorCount = (typeof payload.errorCount === 'number')
                ? payload.errorCount
                : entries.filter(function(e) { return e.severity === 'ERROR'; }).length;
            if (errorCount === 0 && entries.length) {
                b2b_faultShowAll = true;
            }
        }
        catch (e) {
            // Unparseable JSON falls through to the raw/fallback rendering.
        }
    }

    b2b_renderFaultReportBody();
}

/* Renders the slideout body from the stored report and toggle state: the
   toolbar, then the formatted view for the recognized report shapes, the
   raw report text when the raw view is selected, or the pretty-printed JSON
   fallback for unrecognized shapes. */
function b2b_renderFaultReportBody() {
    var body = document.getElementById('b2b-fault-report-body');
    if (!body) {
        return;
    }

    var report = b2b_faultReport;
    if (!report) {
        body.innerHTML = '<div class="b2b-empty">No status report captured for this run</div>';
        return;
    }

    var payload = null;
    if (report.report_json) {
        try {
            payload = JSON.parse(report.report_json);
        }
        catch (e) {
            payload = null;
        }
    }

    if (!payload && !report.raw_report_text) {
        body.innerHTML = '<div class="b2b-empty">The captured report has no content</div>';
        return;
    }

    var html = '<div class="b2b-fault-report-layout">';
    html += b2b_buildFaultToolbarHtml(payload, report);

    if (b2b_faultShowRaw && report.raw_report_text) {
        html += '<pre class="b2b-fault-report-pre">' + cc_escapeHtml(report.raw_report_text) + '</pre>';
    }
    else if (payload && b2b_isTranslationReportType(report.fault_report_type) && payload.entries) {
        html += b2b_buildFaultTranslationHtml(payload, report);
    }
    else if (payload && report.fault_report_type === 'SERVICE') {
        html += b2b_buildFaultServiceHtml(payload);
    }
    else if (payload && report.fault_report_type === 'MESSAGE') {
        html += '<pre class="b2b-fault-report-pre">' + cc_escapeHtml(payload.message ? payload.message : '') + '</pre>';
    }
    else if (report.report_json) {
        var content;
        try {
            content = JSON.stringify(JSON.parse(report.report_json), null, 2);
        }
        catch (e) {
            content = report.report_json;
        }
        html += '<pre class="b2b-fault-report-pre">' + cc_escapeHtml(content) + '</pre>';
    }
    else {
        html += '<pre class="b2b-fault-report-pre">' + cc_escapeHtml(report.raw_report_text) + '</pre>';
    }

    html += '</div>';
    body.innerHTML = html;
}

/* Builds the toolbar: the errors-only/all-entries filter (formatted
   TRANSLATION view only) and the formatted/raw view switch (when raw text
   exists). */
function b2b_buildFaultToolbarHtml(payload, report) {
    var groups = '';

    if (!b2b_faultShowRaw && payload && b2b_isTranslationReportType(report.fault_report_type) && payload.entries) {
        var entries = payload.entries;
        var entryCount = payload.entryCount ? payload.entryCount : entries.length;
        var errorCount = (typeof payload.errorCount === 'number')
            ? payload.errorCount
            : entries.filter(function(e) { return e.severity === 'ERROR'; }).length;
        groups += '<div class="b2b-fault-ctl-group">' +
                  '<button class="b2b-fault-ctl-btn' + (b2b_faultShowAll ? '' : ' b2b-active') + '" ' +
                  'data-action-click="b2b-fault-entries-mode" data-b2b-show-all="0">Errors (' + cc_safeInt(errorCount) + ')</button>' +
                  '<button class="b2b-fault-ctl-btn' + (b2b_faultShowAll ? ' b2b-active' : '') + '" ' +
                  'data-action-click="b2b-fault-entries-mode" data-b2b-show-all="1">All Entries (' + cc_safeInt(entryCount) + ')</button>' +
                  '</div>';
    }
    else {
        groups += '<div class="b2b-fault-ctl-group"></div>';
    }

    if (report.raw_report_text) {
        groups += '<div class="b2b-fault-ctl-group">' +
                  '<button class="b2b-fault-ctl-btn' + (b2b_faultShowRaw ? '' : ' b2b-active') + '" ' +
                  'data-action-click="b2b-fault-view-mode" data-b2b-raw="0">Formatted</button>' +
                  '<button class="b2b-fault-ctl-btn' + (b2b_faultShowRaw ? ' b2b-active' : '') + '" ' +
                  'data-action-click="b2b-fault-view-mode" data-b2b-raw="1">Raw Report</button>' +
                  '</div>';
    }

    return '<div class="b2b-fault-toolbar">' + groups + '</div>';
}

/* Builds the formatted TRANSLATION view: report metadata rows (led by the
   Escalated By row for recovered reports), the count chips, and the entry
   cards under the current errors-only filter. */
function b2b_buildFaultTranslationHtml(payload, report) {
    var entries = payload.entries ? payload.entries : [];
    var entryCount = payload.entryCount ? payload.entryCount : entries.length;
    var errorCount = (typeof payload.errorCount === 'number')
        ? payload.errorCount
        : entries.filter(function(e) { return e.severity === 'ERROR'; }).length;
    var warningCount = (typeof payload.warningCount === 'number')
        ? payload.warningCount
        : entries.filter(function(e) { return e.severity === 'WARNING'; }).length;

    var html = '<div class="b2b-fault-meta">';
    html += b2b_buildFaultDetailRowHtml('Escalated By', report ? report.escalation_message : null);
    html += b2b_buildFaultDetailRowHtml('Map', payload.mapName);
    html += b2b_buildFaultDetailRowHtml('Map Version', payload.mapVersion);
    html += b2b_buildFaultDetailRowHtml('Translation Object', payload.translationObjectName);
    html += b2b_buildFaultDetailRowHtml('Started', payload.startTime);
    html += b2b_buildFaultDetailRowHtml('Ended', payload.endTime);
    html += b2b_buildFaultDetailRowHtml('Execution (ms)', payload.executionMs);
    html += '</div>';

    html += '<div class="b2b-fault-chips">' +
            '<span class="b2b-badge b2b-crit">' + cc_safeInt(errorCount) + ' Errors</span>' +
            '<span class="b2b-badge b2b-warn">' + cc_safeInt(warningCount) + ' Warnings</span>' +
            '<span class="b2b-badge">' + cc_safeInt(entryCount) + ' Entries</span>' +
            '</div>';

    var shown = b2b_faultShowAll
        ? entries
        : entries.filter(function(e) { return e.severity === 'ERROR'; });

    if (!shown.length) {
        html += '<div class="b2b-empty">No error entries in the report</div>';
        return html;
    }

    shown.forEach(function(entry) {
        html += b2b_buildFaultEntryHtml(entry);
    });
    return html;
}

/* Builds one severity-badged entry card with its populated detail rows and
   the collapsible raw block data. */
function b2b_buildFaultEntryHtml(entry) {
    var title;
    if (entry.code && entry.codeLabel) {
        title = entry.code + ' - ' + entry.codeLabel;
    }
    else if (entry.codeLabel) {
        title = entry.codeLabel;
    }
    else if (entry.code) {
        title = 'Code ' + entry.code;
    }
    else {
        title = 'Entry';
    }

    var html = '<div class="b2b-fault-entry">' +
               '<div class="b2b-fault-entry-head">' +
               '<span class="b2b-badge ' + b2b_faultSeverityState(entry.severity) + '">' +
               cc_escapeHtml(entry.severity ? entry.severity : 'INFO') + '</span>' +
               '<span class="b2b-fault-entry-title">' + cc_escapeHtml(title) + '</span>' +
               (entry.section ? '<span class="b2b-fault-entry-section">' + cc_escapeHtml(entry.section) + '</span>' : '') +
               (entry.entryIndex ? '<span class="b2b-fault-entry-idx">#' + cc_safeInt(entry.entryIndex) + '</span>' : '') +
               '</div>';

    var fieldValue = null;
    if (entry.fieldName) {
        fieldValue = entry.fieldName + (entry.fieldNumber ? ' (#' + entry.fieldNumber + ')' : '');
    }
    html += b2b_buildFaultDetailRowHtml('Field', fieldValue);
    html += b2b_buildFaultDetailRowHtml('Field Data', entry.fieldData);
    html += b2b_buildFaultDetailRowHtml('Block', entry.blockName);
    html += b2b_buildFaultDetailRowHtml('Signature Tag', entry.blockSignatureIdTag);
    html += b2b_buildFaultDetailRowHtml('Location', entry.locationIndex);
    html += b2b_buildFaultDetailRowHtml('Iteration', entry.mapIterationCount);
    html += b2b_buildFaultDetailRowHtml('Block Count', entry.blockCount);
    html += b2b_buildFaultDetailRowHtml('Exception', entry.exception);

    if (entry.additionalInfo && entry.additionalInfo.length) {
        entry.additionalInfo.forEach(function(info) {
            if (info && info.label) {
                html += b2b_buildFaultDetailRowHtml(info.label, info.value);
            }
        });
    }

    if (entry.rawBlockData) {
        html += '<div class="b2b-fault-rawblock">' +
                '<button class="b2b-fault-rawblock-btn" data-action-click="b2b-fault-rawblock-toggle">Show raw block data</button>' +
                '<pre class="b2b-fault-rawblock-pre b2b-collapsed">' + cc_escapeHtml(entry.rawBlockData) + '</pre>' +
                '</div>';
    }

    html += '</div>';
    return html;
}

/* Builds the formatted SERVICE view: service identity rows and one card per
   captured ERROR line. Falls back to the legacy firstError field for
   reports parsed before the errors array existed. */
function b2b_buildFaultServiceHtml(payload) {
    var html = '<div class="b2b-fault-meta">';
    html += b2b_buildFaultDetailRowHtml('Service', payload.serviceName);
    html += b2b_buildFaultDetailRowHtml('Errors Reported', payload.errorTotal);
    html += '</div>';

    var errors = payload.errors ? payload.errors : (payload.firstError ? [payload.firstError] : []);
    if (!errors.length) {
        html += '<div class="b2b-empty">No error lines in the report</div>';
        return html;
    }

    errors.forEach(function(msg) {
        html += '<div class="b2b-fault-entry">' +
                '<div class="b2b-fault-entry-head">' +
                '<span class="b2b-badge b2b-crit">ERROR</span>' +
                '<span class="b2b-detail-value">' + cc_escapeHtml(msg) + '</span>' +
                '</div>' +
                '</div>';
    });
    return html;
}

/* Builds one label/value detail row, reusing the run-detail row construct;
   returns an empty string when the value is missing. */
function b2b_buildFaultDetailRowHtml(label, value) {
    if (value === null || value === undefined || value === '') {
        return '';
    }
    return '<div class="b2b-detail-row">' +
           '<span class="b2b-detail-label">' + cc_escapeHtml(label) + '</span>' +
           '<span class="b2b-detail-value">' + cc_escapeHtml(String(value)) + '</span>' +
           '</div>';
}

/* True when a fault report type renders as a formatted translation report:
   a direct TRANSLATION capture or a TRANSLATION_ESCALATED recovery. */
function b2b_isTranslationReportType(type) {
    return type === 'TRANSLATION' || type === 'TRANSLATION_ESCALATED';
}

/* Maps a report-entry severity to its badge state token. */
function b2b_faultSeverityState(severity) {
    if (severity === 'ERROR') {
        return 'b2b-crit';
    }
    if (severity === 'WARNING') {
        return 'b2b-warn';
    }
    return 'b2b-neutral';
}

/* Sets the entries filter from the clicked segment and re-renders. */
function b2b_setFaultEntriesMode(target) {
    b2b_faultShowAll = target.getAttribute('data-b2b-show-all') === '1';
    b2b_renderFaultReportBody();
}

/* Sets the view mode from the clicked segment and re-renders. */
function b2b_setFaultViewMode(target) {
    b2b_faultShowRaw = target.getAttribute('data-b2b-raw') === '1';
    b2b_renderFaultReportBody();
}

/* Expands or collapses one entry's raw block data. */
function b2b_toggleFaultRawBlock(target) {
    var pre = target.nextElementSibling;
    if (!pre) {
        return;
    }
    var collapsed = pre.classList.toggle('b2b-collapsed');
    target.textContent = collapsed ? 'Show raw block data' : 'Hide raw block data';
}

/* Closes the full status-report slideout on backdrop click or the close button. */
function b2b_closeFaultReport(target, event) {
    if (event && target.id === 'b2b-slideout-fault' && event.target !== target) {
        return;
    }
    var overlay = document.getElementById('b2b-slideout-fault');
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
   Page-local formatting helpers: datetime display, date-only parsing,
   display dates, duration formatting, filter-option population, and the
   section-error renderer.
   Prefix: b2b
   ============================================================================ */

/* Populates the status filter dropdown at boot and kicks off the async
   process-type fetch for the type filter. */
function b2b_populateFilterOptions() {
    var statusSelect = document.getElementById('b2b-filter-status');
    if (statusSelect) {
        var statusHtml = '<option value="ALL">All Statuses</option>';
        Object.keys(b2b_sterlingStatusMeta).forEach(function(key) {
            statusHtml += '<option value="' + key + '">' + cc_escapeHtml(b2b_sterlingStatusMeta[key].label) + '</option>';
        });
        statusSelect.innerHTML = statusHtml;
    }

    b2b_loadProcessTypeOptions();
}

/* Fetches the distinct process types present in the data and populates the
   type filter, labeled via the process-type map and sorted by label. */
function b2b_loadProcessTypeOptions() {
    var typeSelect = document.getElementById('b2b-filter-type');
    if (!typeSelect) {
        return;
    }

    cc_engineFetch('/api/b2b-pipeline/process-types')
        .then(function(data) {
            if (!data || !data.types) {
                return;
            }
            var options = data.types.map(function(pt) {
                var meta = b2b_processTypeMeta[pt];
                return { value: pt, label: meta ? meta.label : pt };
            });
            options.sort(function(a, b) {
                return a.label.localeCompare(b.label);
            });

            var typeHtml = '<option value="ALL">All Types</option>';
            options.forEach(function(opt) {
                typeHtml += '<option value="' + cc_escapeHtml(opt.value) + '">' + cc_escapeHtml(opt.label) + '</option>';
            });
            typeSelect.innerHTML = typeHtml;
        })
        .catch(function() {
            typeSelect.innerHTML = '<option value="ALL">All Types</option>';
        });
}

/* Formats a timestamp value as a compact local date-time string. */
function b2b_formatDttm(value) {
    if (!value) {
        return '-';
    }
    var s = String(value);
    var match = s.match(/\/Date\((\d+)\)\//);
    var d = match ? new Date(parseInt(match[1], 10)) : new Date(s);
    if (isNaN(d.getTime())) {
        return s;
    }
    return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' +
           String(d.getDate()).padStart(2, '0') + ' ' +
           String(d.getHours()).padStart(2, '0') + ':' + String(d.getMinutes()).padStart(2, '0');
}

/* Returns today's local date as a YYYY-MM-DD string. */
function b2b_todayDateString() {
    var d = new Date();
    return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0');
}

/* Normalizes a timestamp or date value to a YYYY-MM-DD date-only string. */
function b2b_parseDateOnly(value) {
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

/* Formats a date-only string as a readable display date. */
function b2b_formatDisplayDate(date) {
    var parts = b2b_parseDateOnly(date).split('-');
    if (parts.length !== 3) {
        return String(date);
    }
    var dateObj = new Date(parseInt(parts[0], 10), parseInt(parts[1], 10) - 1, parseInt(parts[2], 10));
    return cc_MONTH_NAMES[dateObj.getMonth() + 1] + ' ' + dateObj.getDate() + ', ' + dateObj.getFullYear();
}

/* Returns a tree day row's label split into a compact M/D date and its
   weekday name, for rendering into separate Date and Day table cells. */
function b2b_treeDayLabelParts(date) {
    var parts = b2b_parseDateOnly(date).split('-');
    if (parts.length !== 3) {
        return { date: String(date), dow: '' };
    }
    var dateObj = new Date(parseInt(parts[0], 10), parseInt(parts[1], 10) - 1, parseInt(parts[2], 10));
    return {
        date: (dateObj.getMonth() + 1) + '/' + dateObj.getDate(),
        dow: cc_DAY_NAMES[dateObj.getDay() + 1]
    };
}

/* Formats a minute count as a compact duration string (m, h m, or d h). */
function b2b_formatDurationMinutes(minutes) {
    if (minutes === null || minutes === undefined || minutes === '') {
        return '-';
    }
    var m = cc_safeInt(minutes);
    if (m <= 0) {
        return '<1m';
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

/* Renders a load-failure message into a section container. */
function b2b_renderSectionError(containerId, err) {
    var container = document.getElementById(containerId);
    if (container) {
        container.innerHTML = '<div class="b2b-empty">Failed to load: ' +
            cc_escapeHtml(err && err.message ? err.message : 'request error') + '</div>';
    }
}

/* ============================================================================
   FUNCTIONS: PAGE LIFECYCLE HOOKS
   ----------------------------------------------------------------------------
   Named callbacks the cc-shared.js chrome invokes on page refresh, tab
   resume, session expiry, and collector completion.
   Prefix: b2b
   ============================================================================ */

/* Manual page-refresh hook: refreshes every section. */
function b2b_onPageRefresh() {
    b2b_refreshAll();
}

/* Tab-resume hook: refreshes every section. */
function b2b_onPageResumed() {
    b2b_refreshAll();
}

/* Session-expiry hook: stops the live polling timer. */
function b2b_onSessionExpired() {
    b2b_stopLivePolling();
}

/* Collector-completion hook: refreshes the event-driven sections and the pulse. */
function b2b_onEngineProcessCompleted() {
    b2b_loadSummary();
    b2b_refreshEventSections();
}

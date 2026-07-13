/* ============================================================================
   xFACts Control Center - B2B Pipeline Page Module (b2b-pipeline.js)
   Location: E:\xFACts-ControlCenter\public\js\b2b-pipeline.js
   Version: Tracked in dbo.System_Metadata (component: B2B)

   Page module for the B2B Pipeline dashboard. Loads and renders the daily
   pulse cards, the real-time live pipeline activity table read directly
   from the Integration source, the recent workflow-change list fed by the
   version census, and the year/month/day history summary tree backed by
   B2B.INT_PipelineTracking - with a filtered runs modal for search and
   day drill-down, and a run-detail slideout that tells each run's full
   classification story.

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
   FUNCTIONS: RENDER WORKFLOW CHANGES
   FUNCTIONS: RENDER HISTORY TREE
   FUNCTIONS: TREE TOGGLES
   FUNCTIONS: RUNS MODAL AND DAY SLIDEOUT
   FUNCTIONS: RENDER RUN DETAIL
   FUNCTIONS: SLIDEOUT OPEN AND CLOSE
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
   Display metadata for the twelve status classifications: readable label,
   badge state class, and the plain-English meaning shown in the run-detail
   slideout. The vocabulary mirrors the CHECK constraint on
   B2B.INT_PipelineTracking.status_classification.
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

/* Process-type filter options shown in the history filter dropdown. */
const b2b_processTypeOptions = [
    'NEW_BUSINESS', 'PAYMENT', 'BDL', 'SPECIAL_PROCESS', 'RETURN',
    'SIMPLE_EMAIL', 'ENCOUNTER', 'FILE_DELETION', 'RECON'
];

/* ============================================================================
   CONSTANTS: HISTORY PAGING
   ----------------------------------------------------------------------------
   Fixed paging size for the runs modal.
   Prefix: b2b
   ============================================================================ */

/* Number of runs fetched per modal page. */
const b2b_HISTORY_PAGE_SIZE = 50;

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
    'b2b-close-runs-modal': b2b_closeRunsModal,
    'b2b-day-page':         b2b_dayPage,
    'b2b-close-day-slideout': b2b_closeDaySlideout,
    'b2b-open-run-detail':  b2b_openRunDetail,
    'b2b-close-slideout':   b2b_closeSlideout
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
   for slideout fallbacks without refetching.
   Prefix: b2b
   ============================================================================ */

/* Most recent live-activity row set. */
var b2b_lastLiveData = null;

/* Most recent runs-modal row set. */
var b2b_lastModalData = null;

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
   GlobalConfig-driven timer; the event-driven sections (workflow changes,
   history summary tree) refresh when the collector process completes. A
   separate timer forces a full reload across a midnight rollover.
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
    b2b_loadWorkflowChanges();
    b2b_loadHistorySummary();
    b2b_updateTimestamp();
}

/* Refreshes every section (manual refresh and initial load). */
function b2b_refreshAll() {
    b2b_loadSummary();
    b2b_loadLiveActivity();
    b2b_loadWorkflowChanges();
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

/* Loads the census change list and catalog totals and renders the section. */
function b2b_loadWorkflowChanges() {
    cc_engineFetch('/api/b2b-pipeline/census')
        .then(function(data) {
            if (!data) {
                return;
            }
            b2b_renderWorkflowChanges(data.changes, data.totals);
        })
        .catch(function(e) {
            b2b_renderSectionError('b2b-workflow-changes', e);
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
    if (b2b_modalFilters.classification && b2b_modalFilters.classification !== 'ALL') {
        params.push('classification=' + encodeURIComponent(b2b_modalFilters.classification));
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

    var cards = [
        { label: 'Runs Today',   value: cc_safeInt(summary.runs_today),    state: '' },
        { label: 'Completed',    value: cc_safeInt(summary.completed),     state: 'b2b-ok' },
        { label: 'Failures',     value: cc_safeInt(summary.failures),      state: 'b2b-crit' },
        { label: 'No Files',     value: cc_safeInt(summary.no_files),      state: 'b2b-neutral' },
        { label: 'In Flight',    value: cc_safeInt(summary.in_flight),     state: 'b2b-flight' },
        { label: 'Awaiting DM',  value: cc_safeInt(summary.awaiting_dm),   state: 'b2b-flight' }
    ];

    var html = '';
    cards.forEach(function(card) {
        var classList = 'b2b-summary-card';
        if (card.state) {
            classList += ' ' + card.state;
        }
        html += '<div class="' + classList + '">' +
                '<div class="b2b-card-label">' + cc_escapeHtml(card.label) + '</div>' +
                '<div class="b2b-card-value">' + card.value + '</div>' +
                '</div>';
    });

    container.innerHTML = html;
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
    var container = document.getElementById('b2b-live-activity');
    if (!container) {
        return;
    }

    if (!runs || runs.length === 0) {
        container.innerHTML = '<div class="b2b-empty">No pipeline runs currently in motion</div>';
        return;
    }

    var html = '<div class="b2b-table-head b2b-cols-live">' +
               '<div>Client</div><div>Type</div><div>Dispatcher</div><div>Status</div><div class="b2b-head-num">Age</div>' +
               '</div>';

    runs.forEach(function(run) {
        html += b2b_buildRunRowHtml(run, 'b2b-cols-live', false);
    });

    container.innerHTML = html;
}

/* ============================================================================
   FUNCTIONS: RENDER WORKFLOW CHANGES
   ----------------------------------------------------------------------------
   Renders the recent census change rows and the catalog totals caption.
   Prefix: b2b
   ============================================================================ */

/* Renders the workflow-change list and totals. */
function b2b_renderWorkflowChanges(changes, totals) {
    var container = document.getElementById('b2b-workflow-changes');
    if (!container) {
        return;
    }

    var html = '';
    if (!changes || changes.length === 0) {
        html += '<div class="b2b-empty">No workflow definition changes captured</div>';
    }
    else {
        changes.forEach(function(chg) {
            var editor = chg.edited_by ? chg.edited_by : '(unknown)';
            html += '<div class="b2b-census-row">' +
                    '<span class="b2b-census-name">' + cc_escapeHtml(chg.workflow_name) + '</span>' +
                    '<span class="b2b-census-versions">v' + cc_safeInt(chg.previous_version) +
                    ' &rarr; v' + cc_safeInt(chg.current_version) + '</span>' +
                    '<span class="b2b-census-meta">' + cc_escapeHtml(editor) + ' &middot; ' +
                    cc_escapeHtml(b2b_formatDttm(chg.last_version_change_dttm)) + '</span>' +
                    '</div>';
        });
    }

    if (totals) {
        html += '<div class="b2b-census-totals">' + cc_safeInt(totals.definition_count) +
                ' definitions catalogued &middot; ' + cc_safeInt(totals.changed_30d) +
                ' changed in 30 days</div>';
    }

    container.innerHTML = html;
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
            years[y] = { months: {}, total: 0, completed: 0, failures: 0 };
        }
        if (!years[y].months[m]) {
            years[y].months[m] = { days: [], total: 0, completed: 0, failures: 0, noFiles: 0, durationWeight: 0 };
        }

        day.date_str = dateStr;
        years[y].months[m].days.push(day);
        years[y].months[m].total += cc_safeInt(day.total);
        years[y].months[m].completed += cc_safeInt(day.completed);
        years[y].months[m].failures += cc_safeInt(day.failures);
        years[y].months[m].noFiles += cc_safeInt(day.no_files);
        years[y].months[m].durationWeight += cc_safeInt(day.avg_duration_min) * cc_safeInt(day.total);
        years[y].total += cc_safeInt(day.total);
        years[y].completed += cc_safeInt(day.completed);
        years[y].failures += cc_safeInt(day.failures);
    });

    var html = '';
    var yearKeys = Object.keys(years).sort().reverse();
    yearKeys.forEach(function(y) {
        var yr = years[y];
        var yearOpen = b2b_expandedYears[y] === true;
        html += '<button class="b2b-tree-year-row" data-action-click="b2b-toggle-year" data-b2b-year="' + y + '">' +
                '<span class="b2b-tree-chevron">' + (yearOpen ? '&#9662;' : '&#9656;') + '</span>' +
                '<span class="b2b-tree-year-label">' + y + '</span>' +
                '<span class="b2b-tree-counts">' +
                '<span class="b2b-count-muted">' + yr.total.toLocaleString() + ' runs</span>' +
                '<span class="b2b-count-ok">' + yr.completed.toLocaleString() + ' ok</span>' +
                '<span class="b2b-count-crit">' + yr.failures.toLocaleString() + ' failed</span>' +
                '</span>' +
                '</button>';

        if (!yearOpen) {
            return;
        }

        html += '<div class="b2b-tree-head">' +
                '<div>Month</div>' +
                '<div class="b2b-head-num">Runs</div>' +
                '<div class="b2b-head-num">Completed</div>' +
                '<div class="b2b-head-num">Failed</div>' +
                '<div class="b2b-head-num">No Files</div>' +
                '<div class="b2b-head-num">Avg Duration</div>' +
                '</div>';

        var monthKeys = Object.keys(yr.months).sort().reverse();
        monthKeys.forEach(function(m) {
            var mo = yr.months[m];
            var mKey = y + '-' + m;
            var monthOpen = b2b_expandedMonths[mKey] === true;
            html += '<button class="b2b-tree-month-row" data-action-click="b2b-toggle-month" data-b2b-month="' + mKey + '">' +
                    '<div class="b2b-tree-label-cell">' +
                    '<span class="b2b-tree-chevron">' + (monthOpen ? '&#9662;' : '&#9656;') + '</span>' +
                    '<span>' + cc_escapeHtml(cc_MONTH_NAMES[parseInt(m, 10)]) + '</span>' +
                    '</div>' +
                    b2b_buildTreeCellsHtml(mo) +
                    '</button>';

            if (!monthOpen) {
                return;
            }

            mo.days.forEach(function(day) {
                html += '<button class="b2b-tree-day-row" data-action-click="b2b-open-day-runs" data-b2b-date="' + day.date_str + '">' +
                        '<div class="b2b-tree-day-cell">' + cc_escapeHtml(b2b_formatDisplayDate(day.date_str)) + '</div>' +
                        b2b_buildTreeCellsHtml({
                            total: cc_safeInt(day.total),
                            completed: cc_safeInt(day.completed),
                            failures: cc_safeInt(day.failures),
                            noFiles: cc_safeInt(day.no_files),
                            durationWeight: cc_safeInt(day.avg_duration_min) * cc_safeInt(day.total)
                        }) +
                        '</button>';
            });
        });
    });

    container.innerHTML = html;
}

/* Builds the numeric table cells (runs, completed, failed, no files, avg duration) for a tree row. */
function b2b_buildTreeCellsHtml(node) {
    var avg = node.total > 0 ? Math.round(node.durationWeight / node.total) : 0;
    return '<div class="b2b-tree-cell-num">' + node.total.toLocaleString() + '</div>' +
           '<div class="b2b-tree-cell-ok">' + node.completed.toLocaleString() + '</div>' +
           '<div class="b2b-tree-cell-crit">' + node.failures.toLocaleString() + '</div>' +
           '<div class="b2b-tree-cell-num">' + node.noFiles.toLocaleString() + '</div>' +
           '<div class="b2b-tree-cell-num">' + (avg > 0 ? b2b_formatDurationMinutes(avg) : '-') + '</div>';
}

/* ============================================================================
   FUNCTIONS: TREE TOGGLES
   ----------------------------------------------------------------------------
   Expansion handlers for the year and month rows, plus the default-expansion
   seeding for the current year and month.
   Prefix: b2b
   ============================================================================ */

/* Toggles a year row's expansion and re-renders the tree. */
function b2b_toggleYear(target) {
    var y = target.getAttribute('data-b2b-year');
    b2b_expandedYears[y] = b2b_expandedYears[y] !== true;
    b2b_renderHistoryTree();
}

/* Toggles a month row's expansion and re-renders the tree. */
function b2b_toggleMonth(target) {
    var mKey = target.getAttribute('data-b2b-month');
    b2b_expandedMonths[mKey] = b2b_expandedMonths[mKey] !== true;
    b2b_renderHistoryTree();
}

/* Seeds the default expansion: the current year and current month open. */
function b2b_seedTreeExpansion() {
    var now = new Date();
    var y = String(now.getFullYear());
    var m = String(now.getMonth() + 1).padStart(2, '0');
    b2b_expandedYears[y] = true;
    b2b_expandedMonths[y + '-' + m] = true;
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
    var cls = document.getElementById('b2b-filter-classification');
    var type = document.getElementById('b2b-filter-type');
    var from = document.getElementById('b2b-filter-from');
    var to = document.getElementById('b2b-filter-to');

    b2b_modalFilters = {
        client: search ? search.value.trim() : '',
        classification: cls ? cls.value : 'ALL',
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
    var cls = document.getElementById('b2b-filter-classification');
    var type = document.getElementById('b2b-filter-type');
    var from = document.getElementById('b2b-filter-from');
    var to = document.getElementById('b2b-filter-to');

    if (search) { search.value = ''; }
    if (cls) { cls.value = 'ALL'; }
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
                   '<div>Run Start</div><div>Client</div><div>Type</div><div>Dispatcher</div><div>Status</div><div class="b2b-head-num">Duration</div>' +
                   '</div>';

        runs.forEach(function(run) {
            html += b2b_buildRunRowHtml(run, 'b2b-cols-history', true);
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

/* Opens the runs modal, sets its caption, and loads the first page. */
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

    document.getElementById('b2b-modal-runs').classList.remove('cc-hidden');
    b2b_loadModalRuns();
}

/* Closes the runs modal on backdrop click or the close button. */
function b2b_closeRunsModal(target, event) {
    if (event && target.id === 'b2b-modal-runs' && event.target !== target) {
        return;
    }
    document.getElementById('b2b-modal-runs').classList.add('cc-hidden');
}

/* Builds the caption text describing the modal's active filters. */
function b2b_describeModalFilters() {
    var parts = [];
    if (b2b_modalFilters.client) {
        parts.push('client contains "' + b2b_modalFilters.client + '"');
    }
    if (b2b_modalFilters.classification && b2b_modalFilters.classification !== 'ALL') {
        var meta = b2b_classificationMeta[b2b_modalFilters.classification];
        parts.push('status ' + (meta ? meta.label : b2b_modalFilters.classification));
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
                   '<div>Run Start</div><div>Client</div><div>Type</div><div>Dispatcher</div><div>Status</div><div class="b2b-head-num">Duration</div>' +
                   '</div>';

        runs.forEach(function(run) {
            html += b2b_buildRunRowHtml(run, 'b2b-cols-history', true);
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

/* Builds one clickable run row's HTML for the live table or modal results. */
function b2b_buildRunRowHtml(run, colsClass, withTiming) {
    var meta = b2b_classificationMeta[run.status_classification];
    var label = meta ? meta.label : run.status_classification;
    var state = meta ? meta.state : 'b2b-neutral';
    var clientName = run.client_name ? run.client_name : ('client ' + run.client_id);
    var processType = run.process_type ? run.process_type : '-';
    var dispatcher = run.dispatcher_name ? run.dispatcher_name : '-';

    var cells = '';
    if (withTiming) {
        cells += '<div class="b2b-cell-muted">' + cc_escapeHtml(b2b_formatDttm(run.source_insert_dttm)) + '</div>';
    }
    cells += '<div class="b2b-cell-primary">' + cc_escapeHtml(clientName) + '</div>' +
             '<div class="b2b-cell-muted">' + cc_escapeHtml(processType) + '</div>' +
             '<div class="b2b-cell-muted">' + cc_escapeHtml(dispatcher) + '</div>' +
             '<div><span class="b2b-badge ' + state + '">' + cc_escapeHtml(label) + '</span></div>';
    if (withTiming) {
        cells += '<div class="b2b-cell-num">' + cc_escapeHtml(b2b_formatDurationMinutes(run.duration_minutes)) + '</div>';
    }
    else {
        cells += '<div class="b2b-cell-num">' + cc_escapeHtml(b2b_formatDurationMinutes(run.age_minutes)) + '</div>';
    }

    return '<button class="b2b-run-row ' + colsClass + '" data-action-click="b2b-open-run-detail" ' +
           'data-b2b-run-id="' + cc_safeInt(run.run_id) + '">' + cells + '</button>';
}

/* ============================================================================
   FUNCTIONS: RENDER RUN DETAIL
   ----------------------------------------------------------------------------
   Renders one run's full story into the slideout body: the classification
   badge and meaning, then fixed two-column label/value sections for
   identity, timing, and outcome evidence.
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

    if (title) {
        title.textContent = clientName + ' - Run ' + run.run_id;
    }

    var html = '<div class="b2b-detail-section">' +
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

    /* If the click came from the runs modal or day slideout, close it first. */
    var modal = document.getElementById('b2b-modal-runs');
    if (modal && !modal.classList.contains('cc-hidden')) {
        modal.classList.add('cc-hidden');
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
   FUNCTIONS: UTILITIES
   ----------------------------------------------------------------------------
   Page-local formatting helpers: datetime display, date-only parsing,
   display dates, duration formatting, filter-option population, and the
   section-error renderer.
   Prefix: b2b
   ============================================================================ */

/* Populates the classification and process-type filter dropdowns at boot. */
function b2b_populateFilterOptions() {
    var clsSelect = document.getElementById('b2b-filter-classification');
    if (clsSelect) {
        var clsHtml = '<option value="ALL">All Statuses</option>';
        Object.keys(b2b_classificationMeta).forEach(function(key) {
            clsHtml += '<option value="' + key + '">' + cc_escapeHtml(b2b_classificationMeta[key].label) + '</option>';
        });
        clsSelect.innerHTML = clsHtml;
    }

    var typeSelect = document.getElementById('b2b-filter-type');
    if (typeSelect) {
        var typeHtml = '<option value="ALL">All Types</option>';
        b2b_processTypeOptions.forEach(function(pt) {
            typeHtml += '<option value="' + pt + '">' + cc_escapeHtml(pt) + '</option>';
        });
        typeSelect.innerHTML = typeHtml;
    }

    b2b_seedTreeExpansion();
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

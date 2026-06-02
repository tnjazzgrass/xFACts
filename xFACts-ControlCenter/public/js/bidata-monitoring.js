/* ============================================================================
   xFACts Control Center - BIDATA Monitoring JavaScript (bidata-monitoring.js)
   Location: E:\xFACts-ControlCenter\public\js\bidata-monitoring.js
   Version: Tracked in dbo.System_Metadata (component: BIDATA)

   Page-specific JS for the BIDATA Daily Build monitoring dashboard. Universal
   chrome (WebSocket engine events, connection banner, page refresh button,
   idle detection, session expiry, shared overlays, formatting utilities) is
   provided by cc-shared.js and invoked through the bootloader contract. This
   file contains the data loading and rendering logic for the live activity
   cards, the build-execution step list, the duration-trend bar chart with its
   custom date-range modal, the year/month/day build-history drill-down, and
   the build-detail slideout. The bootloader calls bid_init after this module
   loads.

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
   FUNCTIONS: BUILD EXECUTION
   FUNCTIONS: DURATION TREND
   FUNCTIONS: DATE RANGE MODAL
   FUNCTIONS: BUILD HISTORY
   FUNCTIONS: BUILD DETAIL SLIDEOUT
   FUNCTIONS: UTILITIES
   FUNCTIONS: PAGE LIFECYCLE HOOKS
   ============================================================================ */

/* ============================================================================
   CONSTANTS: ENGINE PROCESSES
   ----------------------------------------------------------------------------
   The bid_ENGINE_PROCESSES contract: a map from orchestrator process names to
   engine card slugs that cc-shared.js reads at startup to wire up the engine
   indicator subsystem. The BIDATA page has one process driving its
   event-driven sections: Monitor-BIDATABuild captures nightly build progress
   and raises completion events that refresh the page.
   Prefix: bid
   ============================================================================ */

/* Maps orchestrator process names to engine card slugs. cc-shared.js reads
   this at startup via window['bid_ENGINE_PROCESSES']; the single entry binds
   Monitor-BIDATABuild to the bidata card. Card refreshes happen automatically
   through the bid_onEngineProcessCompleted hook. Declared with var per the JS
   spec engine-processes rule. */
var bid_ENGINE_PROCESSES = {
    'Monitor-BIDATABuild': { slug: 'bidata' }
};

/* ============================================================================
   CONSTANTS: PAGE CONFIGURATION
   ----------------------------------------------------------------------------
   Module-level immutable configuration for this page: the month-name lookup
   used by the history tree, the default trend range in days, and the default
   live-polling interval. The refresh interval default is overwritten at load
   time from GlobalConfig.
   Prefix: bid
   ============================================================================ */

/* Month names lookup, 1-indexed so a SQL month number maps directly without
   subtraction. Index 0 is intentional empty padding. Read as
   bid_MONTH_NAMES[1] === 'January'. */
const bid_MONTH_NAMES = ['', 'January', 'February', 'March', 'April', 'May', 'June',
                         'July', 'August', 'September', 'October', 'November', 'December'];

/* Default Duration Trend range in days, matching the 30d button that carries
   the active class in the page markup. */
const bid_DEFAULT_TREND_DAYS = 30;

/* Default live-polling interval in seconds. Overwritten at page load by
   bid_loadRefreshInterval from GlobalConfig. The page is event-driven, so
   live polling is plumbing kept ready rather than the primary refresh path. */
const bid_PAGE_REFRESH_INTERVAL_DEFAULT = 30;

/* ============================================================================
   CONSTANTS: ACTION DISPATCH TABLES
   ----------------------------------------------------------------------------
   Per-event dispatch tables mapping this page's data-action-<event> values to
   handler functions. The bootloader's shared listeners handle cc- actions;
   the page-local listener registered in bid_init routes bid- actions through
   these tables. Keys match the data-action-click values declared in the page
   markup and in the HTML emitted by the render functions below.
   Prefix: bid
   ============================================================================ */

/* Page-local click-action dispatch table. Maps bid- data-action-click values
   to handler functions defined in this file. */
const bid_clickActions = {
    'bid-set-trend-range':    bid_handleSetTrendRange,
    'bid-open-date-modal':    bid_handleOpenDateModal,
    'bid-close-date-modal':   bid_handleCloseDateModal,
    'bid-apply-date-range':   bid_handleApplyDateRange,
    'bid-open-build-by-date': bid_handleOpenBuildByDate,
    'bid-toggle-year':        bid_handleToggleYear,
    'bid-toggle-month':       bid_handleToggleMonth,
    'bid-close-slideout':     bid_closeSlideout
};

/* ============================================================================
   STATE: PAGE STATE
   ----------------------------------------------------------------------------
   Module-scope mutable state for the BIDATA UI: the live-poll and
   auto-refresh timer handles, the page-load date for midnight rollover
   detection, the effective refresh interval, the active trend range, the
   custom date range when one is set, and the cached trend and history
   responses backing re-renders and bar highlighting.
   Prefix: bid
   ============================================================================ */

/* Effective live-polling interval in seconds. Starts at the default and is
   overwritten by bid_loadRefreshInterval if GlobalConfig has a value. */
var bid_pageRefreshInterval = bid_PAGE_REFRESH_INTERVAL_DEFAULT;

/* setInterval handle for the live-polling timer, or null when not running. */
var bid_livePollingTimer = null;

/* setInterval handle for the midnight-rollover check, or null when not
   running. */
var bid_autoRefreshTimer = null;

/* Date string captured at page load. Compared against the current date inside
   the auto-refresh timer to trigger a full reload at midnight. */
var bid_pageLoadDate = new Date().toDateString();

/* Active Duration Trend range in days. Holds the numeric range for the preset
   buttons; the custom-range path uses bid_customDateRange instead. */
var bid_currentTrendDays = bid_DEFAULT_TREND_DAYS;

/* Active custom date range as { from, to }, or null when a preset range is
   active. Set by bid_handleApplyDateRange. */
var bid_customDateRange = null;

/* Cached most-recent Duration Trend response. Retained so bar highlighting can
   re-render against the same data set without a refetch. */
var bid_currentTrendData = null;

/* Cached most-recent Build History response. Retained for the same reason as
   the trend data. */
var bid_currentHistoryData = null;

/* ============================================================================
   FUNCTIONS: INITIALIZATION
   ----------------------------------------------------------------------------
   The page boot function invoked by the cc-shared.js bootloader after this
   module loads. Registers the page-local delegated click listener, performs
   the first data load for all four sections, reads the refresh interval from
   GlobalConfig, starts the refresh timers, and registers the engine-events
   chrome with cc-shared.js.
   Prefix: bid
   ============================================================================ */

/* Page boot entry point. The bootloader resolves window['bid_init'] and calls
   it once after the module loads. Registers one delegated click listener for
   page-local actions, loads each section, starts the refresh timers, and hands
   the engine subsystem to cc-shared.js. */
function bid_init() {
    document.body.addEventListener('click', bid_handleClick);

    bid_refreshAll();

    bid_loadRefreshInterval();
    bid_startAutoRefresh();
    bid_startLivePolling();
    cc_connectEngineEvents();
}

/* ============================================================================
   FUNCTIONS: ACTION DISPATCH
   ----------------------------------------------------------------------------
   The page-local delegated click dispatcher. Registered on document.body in
   bid_init, it resolves the action value on the clicked element and routes it
   through the bid_clickActions table to the matching handler.
   Prefix: bid
   ============================================================================ */

/* Delegated click dispatcher for page-local actions. Resolves the nearest
   element carrying data-action-click, looks the value up in bid_clickActions,
   and invokes the handler with the matched element and the event. cc- actions
   are handled by the bootloader's own shared listener and ignored here. */
function bid_handleClick(event) {
    var target = event.target.closest('[data-action-click]');
    if (!target) {
        return;
    }
    var action = target.getAttribute('data-action-click');
    var handler = bid_clickActions[action];
    if (handler) {
        handler(target, event);
    }
}

/* ============================================================================
   FUNCTIONS: LIVE POLLING
   ----------------------------------------------------------------------------
   The page's refresh loop. The auto-refresh timer reloads the entire page at
   midnight so the "today" framing stays correct. Live polling is plumbing kept
   ready for future direct-query needs; the page is currently event-driven, so
   the live timer only refreshes the timestamp. The refresh-all and
   refresh-event paths are split because the data sections are refreshed when
   the orchestrator process completes, while the Duration Trend is
   action-driven (refreshed on date-range selection).
   Prefix: bid
   ============================================================================ */

/* Loads the page-specific refresh interval from GlobalConfig via the shared
   refresh-interval API. Falls back to the default constant if the API is
   unavailable. */
async function bid_loadRefreshInterval() {
    try {
        var data = await cc_engineFetch('/api/config/refresh-interval?page=bidata');
        if (data) {
            bid_pageRefreshInterval = data.interval || bid_PAGE_REFRESH_INTERVAL_DEFAULT;
        }
    } catch (e) {
        /* API unavailable - default already in effect. */
    }
}

/* Starts the midnight-rollover check. Lightweight 60-second timer that reloads
   the page when the date changes so the "today" sections reframe to the new
   day. */
function bid_startAutoRefresh() {
    bid_autoRefreshTimer = setInterval(function() {
        var today = new Date().toDateString();
        if (today !== bid_pageLoadDate) {
            window.location.reload();
        }
    }, 60000);
}

/* Starts the live-polling timer. The fetch path goes through cc_engineFetch,
   which returns null when the tab is hidden, the session is expired, or
   polling is idle-paused, so the refresh becomes a safe no-op in those
   states. Currently only the timestamp is refreshed since all data sections
   are event-driven. */
function bid_startLivePolling() {
    if (bid_livePollingTimer) {
        clearInterval(bid_livePollingTimer);
    }
    bid_livePollingTimer = setInterval(bid_refreshLiveSections, bid_pageRefreshInterval * 1000);
}

/* Stops live polling. Called by the bid_onSessionExpired hook when cc-shared.js
   detects the session has expired so we do not keep firing timers. */
function bid_stopLivePolling() {
    if (bid_livePollingTimer) {
        clearInterval(bid_livePollingTimer);
        bid_livePollingTimer = null;
    }
}

/* Refreshes the live-polling sections. The page is event-driven, so this only
   updates the page timestamp; it is the seam where direct-query sections would
   be added if live polling is enabled in future. */
function bid_refreshLiveSections() {
    bid_updateTimestamp();
}

/* Refreshes the event-driven sections (Live Activity, Build Execution, Build
   History). Called by the bid_onEngineProcessCompleted hook when the
   Monitor-BIDATABuild process finishes. The Duration Trend is excluded because
   it is action-driven. */
function bid_refreshEventSections() {
    bid_loadLiveActivity();
    bid_loadCurrentBuildExecution();
    bid_loadBuildHistory();
    bid_updateTimestamp();
}

/* Refreshes everything on the page, including the Duration Trend. Called by
   bid_init on first load and by the bid_onPageRefresh / bid_onPageResumed
   hooks. */
function bid_refreshAll() {
    bid_loadLiveActivity();
    bid_loadCurrentBuildExecution();
    bid_loadDurationTrend(bid_currentTrendDays);
    bid_loadBuildHistory();
    bid_updateTimestamp();
}

/* ============================================================================
   FUNCTIONS: LIVE ACTIVITY
   ----------------------------------------------------------------------------
   The top-left section: today's build status as a row of status cards. The
   card set varies by build state (running, completed, failed) and a leading
   waiting card when no build exists yet. An attempts card appears when more
   than one build ran today.
   Prefix: bid
   ============================================================================ */

/* Loads today's build status and re-renders the live activity cards. */
function bid_loadLiveActivity() {
    cc_engineFetch('/api/bidata/todays-build')
        .then(function(data) {
            if (!data) return;
            if (data.error) { console.error('Live activity:', data.error); return; }
            bid_renderLiveActivity(data);
            bid_updateTimestamp();
        })
        .catch(function(err) { console.error('Failed to load live activity:', err.message); });
}

/* Renders today's build status cards. With no build today a single waiting
   card is shown; otherwise the card set reflects the build's state (running,
   completed, or failed) plus an attempts card when multiple builds ran. */
function bid_renderLiveActivity(data) {
    var container = document.getElementById('bid-live-activity');

    if (!data.builds || data.builds.length === 0) {
        var emptyHtml = '<div class="bid-activity-grid">';
        emptyHtml += '<div class="bid-activity-card bid-status-waiting">';
        emptyHtml += '<div class="bid-activity-card-header"><span class="bid-activity-name">Status</span><span class="bid-build-status-badge bid-waiting">Waiting</span></div>';
        emptyHtml += '<div class="bid-activity-card-body"><div class="bid-activity-value">No Build</div><div class="bid-activity-detail">No build activity today</div></div>';
        emptyHtml += '</div>';
        emptyHtml += '</div>';
        container.innerHTML = emptyHtml;
        return;
    }

    var build = data.builds[0];
    var html = '<div class="bid-activity-grid">';

    if (build.status === 'IN_PROGRESS') {
        var elapsed = bid_calculateElapsed(build.start_dttm);
        html += '<div class="bid-activity-card bid-status-running">';
        html += '<div class="bid-activity-card-header"><span class="bid-activity-name">Status</span><span class="bid-build-status-badge bid-running"><span class="cc-spinning-gear">&#9881;</span> Running</span></div>';
        html += '<div class="bid-activity-card-body"><div class="bid-activity-value bid-status-running">In Progress</div><div class="bid-activity-detail">Build running</div></div>';
        html += '</div>';
        html += '<div class="bid-activity-card bid-status-running">';
        html += '<div class="bid-activity-card-header"><span class="bid-activity-name">Started</span><span class="bid-activity-icon bid-status-running">&#128340;</span></div>';
        html += '<div class="bid-activity-card-body"><div class="bid-activity-value bid-status-running">' + cc_formatTimeOfDay(build.start_dttm) + '</div><div class="bid-activity-detail">' + bid_formatDate(build.build_date) + '</div></div>';
        html += '</div>';
        html += '<div class="bid-activity-card bid-status-running">';
        html += '<div class="bid-activity-card-header"><span class="bid-activity-name">Elapsed</span><span class="bid-activity-icon bid-status-running">&#9201;</span></div>';
        html += '<div class="bid-activity-card-body"><div class="bid-activity-value bid-status-running">' + bid_formatDuration(elapsed) + '</div><div class="bid-activity-detail">Running time</div></div>';
        html += '</div>';
        html += '<div class="bid-activity-card bid-status-running">';
        html += '<div class="bid-activity-card-header"><span class="bid-activity-name">Progress</span><span class="bid-activity-icon bid-status-running">&#128202;</span></div>';
        html += '<div class="bid-activity-card-body"><div class="bid-activity-value bid-status-running">' + build.steps_completed + ' / ' + (data.total_expected_steps || '-') + '</div><div class="bid-activity-detail">Steps completed</div></div>';
        html += '</div>';
        if (data.avg_duration_seconds && elapsed > 0) {
            var remaining = data.avg_duration_seconds - elapsed;
            if (remaining > 0) {
                var eta = new Date(new Date().getTime() + (remaining * 1000));
                html += '<div class="bid-activity-card bid-status-running">';
                html += '<div class="bid-activity-card-header"><span class="bid-activity-name">ETA</span><span class="bid-activity-icon bid-status-running">&#127919;</span></div>';
                html += '<div class="bid-activity-card-body"><div class="bid-activity-value bid-status-running">~' + cc_formatTimeOfDay(eta) + '</div><div class="bid-activity-detail">Estimated completion</div></div>';
                html += '</div>';
            }
        }
    } else if (build.status === 'COMPLETED') {
        html += '<div class="bid-activity-card bid-status-completed">';
        html += '<div class="bid-activity-card-header"><span class="bid-activity-name">Status</span><span class="bid-build-status-badge bid-completed">Completed</span></div>';
        html += '<div class="bid-activity-card-body"><div class="bid-activity-value bid-status-completed">Success</div><div class="bid-activity-detail">Build successful</div></div>';
        html += '</div>';
        html += '<div class="bid-activity-card bid-status-completed">';
        html += '<div class="bid-activity-card-header"><span class="bid-activity-name">Date</span><span class="bid-activity-icon bid-status-completed">&#128197;</span></div>';
        html += '<div class="bid-activity-card-body"><div class="bid-activity-value bid-status-completed">' + bid_formatDate(build.build_date) + '</div><div class="bid-activity-detail">Build date</div></div>';
        html += '</div>';
        html += '<div class="bid-activity-card bid-status-completed">';
        html += '<div class="bid-activity-card-header"><span class="bid-activity-name">Started</span><span class="bid-activity-icon bid-status-completed">&#128340;</span></div>';
        html += '<div class="bid-activity-card-body"><div class="bid-activity-value bid-status-completed">' + cc_formatTimeOfDay(build.start_dttm) + '</div><div class="bid-activity-detail">Start time</div></div>';
        html += '</div>';
        html += '<div class="bid-activity-card bid-status-completed">';
        html += '<div class="bid-activity-card-header"><span class="bid-activity-name">Completed</span><span class="bid-activity-icon bid-status-completed">&#127937;</span></div>';
        html += '<div class="bid-activity-card-body"><div class="bid-activity-value bid-status-completed">' + cc_formatTimeOfDay(build.end_dttm) + '</div><div class="bid-activity-detail">End time</div></div>';
        html += '</div>';
        html += '<div class="bid-activity-card bid-status-completed">';
        html += '<div class="bid-activity-card-header"><span class="bid-activity-name">Duration</span><span class="bid-activity-icon bid-status-completed">&#9201;</span></div>';
        html += '<div class="bid-activity-card-body"><div class="bid-activity-value bid-status-completed">' + build.total_duration_formatted + '</div><div class="bid-activity-detail">Total time</div></div>';
        html += '</div>';
    } else if (build.status === 'FAILED') {
        html += '<div class="bid-activity-card bid-status-failed">';
        html += '<div class="bid-activity-card-header"><span class="bid-activity-name">Status</span><span class="bid-build-status-badge bid-failed">Failed</span></div>';
        html += '<div class="bid-activity-card-body"><div class="bid-activity-value bid-status-failed">Error</div><div class="bid-activity-detail">Build error</div></div>';
        html += '</div>';
        html += '<div class="bid-activity-card bid-status-failed">';
        html += '<div class="bid-activity-card-header"><span class="bid-activity-name">Date</span><span class="bid-activity-icon bid-status-failed">&#128197;</span></div>';
        html += '<div class="bid-activity-card-body"><div class="bid-activity-value bid-status-failed">' + bid_formatDate(build.build_date) + '</div><div class="bid-activity-detail">Build date</div></div>';
        html += '</div>';
        html += '<div class="bid-activity-card bid-status-failed">';
        html += '<div class="bid-activity-card-header"><span class="bid-activity-name">Started</span><span class="bid-activity-icon bid-status-failed">&#128340;</span></div>';
        html += '<div class="bid-activity-card-body"><div class="bid-activity-value bid-status-failed">' + cc_formatTimeOfDay(build.start_dttm) + '</div><div class="bid-activity-detail">Start time</div></div>';
        html += '</div>';
        html += '<div class="bid-activity-card bid-status-failed">';
        html += '<div class="bid-activity-card-header"><span class="bid-activity-name">Failed At</span><span class="bid-activity-icon bid-status-failed">&#128165;</span></div>';
        html += '<div class="bid-activity-card-body"><div class="bid-activity-value bid-status-failed">' + cc_formatTimeOfDay(build.end_dttm) + '</div><div class="bid-activity-detail">Failure time</div></div>';
        html += '</div>';
        if (build.failed_step_name) {
            html += '<div class="bid-activity-card bid-status-failed">';
            html += '<div class="bid-activity-card-header"><span class="bid-activity-name">Failed Step</span><span class="bid-activity-icon bid-status-failed">&#9888;</span></div>';
            html += '<div class="bid-activity-card-body"><div class="bid-activity-value bid-status-failed">' + cc_escapeHtml(build.failed_step_name) + '</div><div class="bid-activity-detail">Error location</div></div>';
            html += '</div>';
        }
    }

    if (data.builds.length > 1) {
        var attemptsStatusClass = build.status === 'COMPLETED' ? 'bid-status-completed' : (build.status === 'FAILED' ? 'bid-status-failed' : 'bid-status-running');
        html += '<div class="bid-activity-card ' + attemptsStatusClass + '">';
        html += '<div class="bid-activity-card-header"><span class="bid-activity-name">Attempts</span><span class="bid-activity-icon ' + attemptsStatusClass + '">&#128260;</span></div>';
        html += '<div class="bid-activity-card-body"><div class="bid-activity-value ' + attemptsStatusClass + '">' + data.builds.length + '</div><div class="bid-activity-detail">Today</div></div>';
        html += '</div>';
    }

    html += '</div>';
    container.innerHTML = html;
}

/* ============================================================================
   FUNCTIONS: BUILD EXECUTION
   ----------------------------------------------------------------------------
   The bottom-left section: step-by-step execution detail for today's build.
   Each step row shows a status badge, name, start/end times, duration, and a
   14-day variance pill. A trailing running-step row is appended when a build
   is still in progress.
   Prefix: bid
   ============================================================================ */

/* Loads step-progress data and re-renders the build-execution list. */
function bid_loadCurrentBuildExecution() {
    cc_engineFetch('/api/bidata/step-progress')
        .then(function(data) {
            if (!data) return;
            if (data.error) { console.error('Step progress:', data.error); return; }
            bid_renderCurrentBuildExecution(data);
        })
        .catch(function(err) { console.error('Failed to load step progress:', err.message); });
}

/* Renders the step list for today's build. Shows a centered placeholder when
   no steps exist; otherwise a header row plus one row per completed step, and
   a trailing running-step row when a build is still in progress. */
function bid_renderCurrentBuildExecution(data) {
    var container = document.getElementById('bid-current-build-execution');

    if (!data.steps || data.steps.length === 0) {
        container.innerHTML = '<div class="bid-no-active-build"><div class="bid-no-active-icon">&#128164;</div><div class="bid-no-active-text">No Build Today</div><div class="bid-no-active-subtext">Step execution details will appear here when a build starts</div></div>';
        return;
    }

    var displaySteps = data.steps;

    var html = '<div class="bid-execution-list">';
    html += '<div class="bid-step-row bid-step-header">';
    html += '<span class="bid-step-status-badge"></span>';
    html += '<span class="bid-step-name">Step Name</span>';
    html += '<span class="bid-step-time">Start Time</span>';
    html += '<span class="bid-step-time">End Time</span>';
    html += '<span class="bid-step-duration-col">Duration</span>';
    html += '<span class="bid-step-variance-col">14 Day Var</span>';
    html += '</div>';

    displaySteps.forEach(function(step) {
        var avgDuration = data.avg_durations ? data.avg_durations[String(step.step_id)] : null;
        var statusClass = step.run_status === 1 ? 'bid-step-success' : 'bid-step-failed';
        var badgeClass = step.run_status === 1 ? 'bid-success' : 'bid-failed';
        var badgeLabel = step.run_status === 1 ? 'COMPLETED' : 'FAILED';

        var startTime = bid_formatRunTime(step.run_time);
        var endTime = bid_calculateStepEndTime(step.run_time, step.duration_seconds);

        var comparison = '';
        if (avgDuration && step.duration_seconds !== null && step.duration_seconds !== undefined) {
            var diff = step.duration_seconds - avgDuration;
            var pctDiff = Math.round((diff / avgDuration) * 100);
            var compClass = diff > 0 ? 'bid-slower' : (diff < 0 ? 'bid-faster' : 'bid-neutral');
            var compSign = diff > 0 ? '+' : '';
            comparison = '<span class="bid-step-comparison ' + compClass + '">' + compSign + pctDiff + '%</span>';
        }

        html += '<div class="bid-step-row ' + statusClass + '">';
        html += '<span class="bid-step-status-badge ' + badgeClass + '">' + badgeLabel + '</span>';
        html += '<span class="bid-step-name">' + cc_escapeHtml(step.step_name) + '</span>';
        html += '<span class="bid-step-time">' + startTime + '</span>';
        html += '<span class="bid-step-time">' + endTime + '</span>';
        html += '<span class="bid-step-duration-col">' + step.duration_formatted + '</span>';
        html += '<span class="bid-step-variance-col">' + comparison + '</span>';
        html += '</div>';
    });

    if (data.next_step_number && data.current_step_elapsed_seconds !== null) {
        var runningStartTime = '--:--:--';
        if (displaySteps.length > 0) {
            var lastStep = displaySteps[displaySteps.length - 1];
            runningStartTime = bid_calculateStepEndTime(lastStep.run_time, lastStep.duration_seconds);
        }

        var runningLabel = data.next_step_name
            ? (cc_escapeHtml(data.next_step_name) + ' executing...')
            : ('Step ' + data.next_step_number + ' executing...');

        html += '<div class="bid-step-row bid-step-running">';
        html += '<span class="bid-step-status-badge bid-running"><span class="cc-spinning-gear">&#9881;</span></span>';
        html += '<span class="bid-step-name">' + runningLabel + '</span>';
        html += '<span class="bid-step-time">' + runningStartTime + '</span>';
        html += '<span class="bid-step-time">--:--:--</span>';
        html += '<span class="bid-step-duration-col bid-step-duration-running">' + bid_formatDuration(data.current_step_elapsed_seconds) + '</span>';
        html += '<span class="bid-step-variance-col"></span>';
        html += '</div>';
    }

    html += '</div>';
    container.innerHTML = html;
}

/* ============================================================================
   FUNCTIONS: DURATION TREND
   ----------------------------------------------------------------------------
   The top-right section: a bar chart of build durations over the selected
   range. Each day renders as a single success/failed bar or a stacked
   multi-segment bar for multiple attempts. Date labels appear for ranges of
   30 days or fewer. Each bar carries a date argument so a click opens that
   day's builds in the slideout. A stats row summarizes avg/min/max/day-count.
   Prefix: bid
   ============================================================================ */

/* Loads the Duration Trend for a preset day count or, when fromDate and toDate
   are supplied, a custom range. Caches the response for re-renders and hands
   it to the renderer. */
function bid_loadDurationTrend(days, fromDate, toDate) {
    var url = '/api/bidata/duration-trend?days=' + days;
    if (fromDate && toDate) {
        url = '/api/bidata/duration-trend?from=' + fromDate + '&to=' + toDate;
    }
    cc_engineFetch(url)
        .then(function(data) {
            if (!data) return;
            if (data.error) { console.error('Duration trend:', data.error); return; }
            bid_currentTrendData = data;
            bid_renderDurationTrend(data);
        })
        .catch(function(err) { console.error('Failed to load duration trend:', err.message); });
}

/* Renders the Duration Trend chart. Bars are scaled to the maximum duration in
   the set; multi-attempt days render as stacked segment bars. Date labels are
   shown only for ranges of 30 days or fewer. Each bar carries a bid-open-build-by-date
   action and a date argument for the slideout drill-down. */
function bid_renderDurationTrend(data) {
    var container = document.getElementById('bid-duration-trend');

    if (!data.data_points || data.data_points.length === 0) {
        container.innerHTML = '<div class="bid-no-data">No trend data available</div>';
        return;
    }

    var points = data.data_points;
    var showDateLabels = points.length <= 30;

    var durations = points.map(function(d) {
        return d.total_execution_seconds > 0 ? d.total_execution_seconds : d.duration_seconds;
    }).filter(function(d) { return d > 0; });

    if (durations.length === 0) {
        container.innerHTML = '<div class="bid-no-data">No duration data available</div>';
        return;
    }

    var maxDuration = Math.max.apply(null, durations);

    var html = '<div class="bid-trend-chart-area">';

    points.forEach(function(point) {
        var duration = point.total_execution_seconds > 0 ? point.total_execution_seconds : point.duration_seconds;
        var heightPct = maxDuration > 0 ? Math.max(3, (duration / maxDuration) * 100) : 50;
        var tooltip = point.date + (point.attempt_count > 1 ? ' (' + point.attempt_count + ' attempts)' : '') + '\nDuration: ' + bid_formatDuration(duration);

        html += '<div class="bid-trend-bar-wrapper">';
        html += '<div class="bid-trend-bar-container">';

        if (point.segments && point.segments.length > 1) {
            html += '<div class="bid-trend-bar-stacked" data-action-click="bid-open-build-by-date" data-action-bid-date="' + point.date + '" title="' + cc_escapeHtml(tooltip) + '" style="height:' + heightPct + '%;">';
            var totalSec = point.total_wall_clock_seconds > 0 ? point.total_wall_clock_seconds : duration;
            point.segments.forEach(function(seg) {
                var segPct = totalSec > 0 ? (seg.seconds / totalSec) * 100 : 0;
                html += '<div class="bid-trend-bar-segment bid-bar-' + seg.type + '" style="height:' + segPct + '%;"></div>';
            });
            html += '</div>';
        } else {
            var barClass = point.final_status === 'FAILED' ? 'bid-bar-failed' : 'bid-bar-success';
            html += '<div class="bid-trend-bar ' + barClass + '" data-action-click="bid-open-build-by-date" data-action-bid-date="' + point.date + '" title="' + cc_escapeHtml(tooltip) + '" style="height:' + heightPct + '%;"></div>';
        }

        html += '</div></div>';
    });

    html += '</div>';

    if (showDateLabels) {
        html += '<div class="bid-trend-date-labels">';
        points.forEach(function(point) {
            var dateLabel = point.date_short || point.date.substring(5);
            html += '<div class="bid-trend-date-label">' + dateLabel.replace('-', '/') + '</div>';
        });
        html += '</div>';
    }

    html += '<div class="bid-trend-stats">';
    if (data.stats.avg_formatted) html += '<div class="bid-stat"><span class="bid-stat-label">Avg</span> <span class="bid-stat-value">' + data.stats.avg_formatted + '</span></div>';
    if (data.stats.min_seconds)   html += '<div class="bid-stat"><span class="bid-stat-label">Min</span> <span class="bid-stat-value">' + bid_formatDuration(data.stats.min_seconds) + '</span></div>';
    if (data.stats.max_seconds)   html += '<div class="bid-stat"><span class="bid-stat-label">Max</span> <span class="bid-stat-value">' + bid_formatDuration(data.stats.max_seconds) + '</span></div>';
    html += '<div class="bid-stat"><span class="bid-stat-label">Days</span> <span class="bid-stat-value">' + data.stats.count + '</span></div>';
    html += '</div>';

    container.innerHTML = html;
}

/* Sets the active preset trend range and reloads the chart. Dispatched from
   the bid-set-trend-range click action on the 30/60/90 buttons; reads the day
   count from the button's argument attribute and moves the active class to the
   clicked button. */
function bid_handleSetTrendRange(target, event) {
    var days = target.getAttribute('data-action-bid-days');
    var buttons = document.querySelectorAll('.bid-trend-btn');
    buttons.forEach(function(b) { b.classList.remove('bid-active'); });
    target.classList.add('bid-active');
    bid_customDateRange = null;
    bid_currentTrendDays = parseInt(days, 10);
    bid_loadDurationTrend(days);
}

/* Highlights the trend bar for a given date and scrolls it into view. The
   highlight class goes on the bar element itself (single or stacked); any
   previously-highlighted bar is cleared first. */
function bid_highlightTrendBar(dateStr) {
    var prev = document.querySelectorAll('.bid-highlighted');
    prev.forEach(function(el) { el.classList.remove('bid-highlighted'); });
    var bar = document.querySelector('[data-action-bid-date="' + dateStr + '"]');
    if (bar) {
        bar.classList.add('bid-highlighted');
        bar.scrollIntoView({ behavior: 'smooth', block: 'nearest', inline: 'center' });
    }
}

/* ============================================================================
   FUNCTIONS: DATE RANGE MODAL
   ----------------------------------------------------------------------------
   The custom date-range modal for the Duration Trend. Opening it seeds the two
   date inputs with a default 30-day window; applying it validates the range
   and reloads the trend with a custom from/to query. Uses the shared static
   modal pattern (cc-hidden toggle).
   Prefix: bid
   ============================================================================ */

/* Opens the custom date-range modal. Dispatched from the bid-open-date-modal
   click action on the Custom button; seeds the From input with a date 30 days
   back and the To input with today, then reveals the modal. */
function bid_handleOpenDateModal(target, event) {
    var today = new Date();
    var monthAgo = new Date(today.getTime() - (30 * 24 * 60 * 60 * 1000));
    document.getElementById('bid-date-from').value = bid_formatDateForInput(monthAgo);
    document.getElementById('bid-date-to').value = bid_formatDateForInput(today);
    document.getElementById('bid-modal-daterange').classList.remove('cc-hidden');
}

/* Closes the custom date-range modal. Wired from the close button, the Cancel
   button, and the overlay backdrop via the bid-close-date-modal click action.
   The dispatcher passes the matched action element as target. When target is the
   overlay itself, the click is only a dismiss if it landed directly on the
   backdrop (event.target === target); a click that bubbled up from the dialog
   interior is ignored. When target is an explicit close control (the X or
   Cancel button), the modal always closes. */
function bid_handleCloseDateModal(target, event) {
    if (event && target.id === 'bid-modal-daterange' && event.target !== target) {
        return;
    }
    document.getElementById('bid-modal-daterange').classList.add('cc-hidden');
}

/* Applies the custom date range. Dispatched from the bid-apply-date-range click
   action on the Apply button; validates that both dates are present and ordered,
   moves the active class to the Custom button, reloads the trend with the
   custom range, and closes the modal. */
function bid_handleApplyDateRange(target, event) {
    var fromDate = document.getElementById('bid-date-from').value;
    var toDate = document.getElementById('bid-date-to').value;
    if (!fromDate || !toDate) {
        cc_showAlert('Please select both dates', { title: 'Date Range' });
        return;
    }
    if (fromDate > toDate) {
        cc_showAlert('From date must be before To date', { title: 'Date Range' });
        return;
    }
    var buttons = document.querySelectorAll('.bid-trend-btn');
    buttons.forEach(function(b) { b.classList.remove('bid-active'); });
    var customBtn = document.querySelector('[data-action-bid-days="custom"]');
    if (customBtn) { customBtn.classList.add('bid-active'); }
    bid_customDateRange = { from: fromDate, to: toDate };
    bid_loadDurationTrend('custom', fromDate, toDate);
    document.getElementById('bid-modal-daterange').classList.add('cc-hidden');
}

/* ============================================================================
   FUNCTIONS: BUILD HISTORY
   ----------------------------------------------------------------------------
   The bottom-right section: a year/month/day drill-down of past builds. Years
   are collapsible; each year holds a month-summary table whose rows expand to
   per-day build tables. Day rows carry a date argument so a click opens that
   day's builds in the slideout.
   Prefix: bid
   ============================================================================ */

/* Loads the build-history data and re-renders the tree. */
function bid_loadBuildHistory() {
    cc_engineFetch('/api/bidata/build-history')
        .then(function(data) {
            if (!data) return;
            if (data.error) { console.error('Build history:', data.error); return; }
            bid_currentHistoryData = data;
            bid_renderBuildHistory(data);
        })
        .catch(function(err) { console.error('Failed to load build history:', err.message); });
}

/* Renders the year/month/day history tree. Each year aggregates its month
   summaries into a header line; each month row expands to a per-day table.
   Day rows carry the bid-open-build-by-date action and a date argument. */
function bid_renderBuildHistory(data) {
    var container = document.getElementById('bid-build-history');
    var countEl = document.getElementById('bid-history-count');

    if (!data.grouped || Object.keys(data.grouped).length === 0) {
        container.innerHTML = '<div class="bid-no-data">No build history available</div>';
        return;
    }

    countEl.textContent = data.total_count + ' builds';
    var html = '<div class="bid-history-tree">';
    var years = Object.keys(data.grouped).sort(function(a, b) { return parseInt(b, 10) - parseInt(a, 10); });

    years.forEach(function(year) {
        var yearData = data.grouped[year];

        var yearSuccess = 0;
        var yearFailed = 0;
        var months = Object.keys(yearData).sort(function(a, b) { return parseInt(b, 10) - parseInt(a, 10); });
        months.forEach(function(month) {
            var monthKey = year + '-' + month;
            var summary = data.month_summaries ? data.month_summaries[monthKey] : null;
            if (summary) {
                yearSuccess += summary.success_count || 0;
                yearFailed += summary.failed_count || 0;
            }
        });
        var yearBuilds = yearSuccess + yearFailed;

        html += '<div class="bid-history-year">';
        html += '<div class="bid-year-header" data-action-click="bid-toggle-year">';
        html += '<span class="bid-expand-icon">&#9654;</span>';
        html += '<span class="bid-year-label">' + year + '</span>';
        html += '<div class="bid-year-stats">';
        html += '<span class="bid-year-stat">' + yearBuilds + ' builds</span>';
        html += '<span class="bid-year-stat bid-success">' + yearSuccess + ' success</span>';
        html += '<span class="bid-year-stat bid-failed">' + (yearFailed > 0 ? yearFailed + ' failed' : '-') + '</span>';
        html += '</div>';
        html += '</div>';
        html += '<div class="bid-year-content" style="display:none;">';

        html += '<table class="bid-month-summary-table">';
        html += '<thead><tr><th class="bid-month-summary-table-th"></th><th class="bid-month-summary-table-th">Month</th><th class="bid-month-summary-table-th">Successful</th><th class="bid-month-summary-table-th">Failed</th><th class="bid-month-summary-table-th">Avg Duration</th></tr></thead>';

        months.forEach(function(month) {
            var monthData = yearData[month];
            var monthName = bid_MONTH_NAMES[parseInt(month, 10)];
            var monthKey = year + '-' + month;
            var summary = data.month_summaries ? data.month_summaries[monthKey] : null;

            html += '<tbody>';
            html += '<tr class="bid-month-row" data-action-click="bid-toggle-month">';
            html += '<td class="bid-month-summary-table-td bid-expand-cell"><span class="bid-expand-icon">&#9654;</span></td>';
            html += '<td class="bid-month-summary-table-td bid-month-cell">' + monthName + '</td>';
            if (summary) {
                html += '<td class="bid-month-summary-table-td bid-success-cell">' + summary.success_count + '</td>';
                html += '<td class="bid-month-summary-table-td bid-fail-cell">' + (summary.failed_count > 0 ? summary.failed_count : '-') + '</td>';
                html += '<td class="bid-month-summary-table-td bid-avg-cell">' + (summary.avg_duration_formatted || '-') + '</td>';
            } else {
                html += '<td class="bid-month-summary-table-td">-</td><td class="bid-month-summary-table-td">-</td><td class="bid-month-summary-table-td">-</td>';
            }
            html += '</tr>';

            html += '<tr class="bid-month-details" style="display:none;"><td class="bid-month-summary-table-td" colspan="5">';
            html += '<table class="bid-history-table"><thead><tr>';
            html += '<th class="bid-history-table-th">Status</th><th class="bid-history-table-th">Day</th><th class="bid-history-table-th">Date</th><th class="bid-history-table-th">Job</th><th class="bid-history-table-th">Instance</th><th class="bid-history-table-th">Start</th><th class="bid-history-table-th">End</th><th class="bid-history-table-th">Duration</th>';
            html += '</tr></thead><tbody>';

            monthData.forEach(function(build, idx) {
                var statusClass = build.status === 'COMPLETED' ? 'bid-success' : 'bid-failed';
                var altClass = idx % 2 === 0 ? 'bid-history-table-row' : 'bid-history-table-row bid-row-odd';
                var dateParts = build.build_date.split('-');
                var monthDay = dateParts[1] + '/' + dateParts[2];

                html += '<tr class="' + altClass + '" data-action-click="bid-open-build-by-date" data-action-bid-date="' + build.build_date + '">';
                html += '<td class="bid-history-table-td"><span class="bid-history-status-badge ' + statusClass + '">' + (statusClass === 'bid-success' ? 'SUCCESS' : 'FAILED') + '</span></td>';
                html += '<td class="bid-history-table-td">' + build.day_name + '</td>';
                html += '<td class="bid-history-table-td">' + monthDay + '</td>';
                html += '<td class="bid-history-table-td">' + (build.job_name || 'BIDATA Daily Build') + '</td>';
                html += '<td class="bid-history-table-td">' + (build.instance_id || '-') + '</td>';
                html += '<td class="bid-history-table-td">' + (build.start_dttm || '-') + '</td>';
                html += '<td class="bid-history-table-td">' + (build.end_dttm || '-') + '</td>';
                html += '<td class="bid-history-table-td bid-duration-cell ' + statusClass + '">' + (build.total_duration_formatted || '-') + '</td>';
                html += '</tr>';
            });

            html += '</tbody></table>';
            html += '</td></tr>';
            html += '</tbody>';
        });

        html += '</table>';
        html += '</div></div>';
    });

    html += '</div>';
    container.innerHTML = html;
}

/* Toggles a year row open or closed in the history tree. Dispatched from the
   bid-toggle-year click action on the year header. Opening a year collapses
   any other open year and resets all month rows within the opened year. */
function bid_handleToggleYear(target, event) {
    var yearDiv = target.parentElement;
    var content = target.nextElementSibling;
    var icon = target.querySelector('.bid-expand-icon');
    var isOpening = content.style.display === 'none';

    if (isOpening) {
        var allYears = document.querySelectorAll('.bid-history-year');
        allYears.forEach(function(otherYear) {
            if (otherYear !== yearDiv) {
                otherYear.querySelector('.bid-year-content').style.display = 'none';
                otherYear.querySelector('.bid-year-header .bid-expand-icon').textContent = '\u25B6';
                var otherDetails = otherYear.querySelectorAll('.bid-month-details');
                otherDetails.forEach(function(md) { md.style.display = 'none'; });
                var otherIcons = otherYear.querySelectorAll('.bid-month-row .bid-expand-icon');
                otherIcons.forEach(function(mi) { mi.textContent = '\u25B6'; });
            }
        });
        var ownDetails = content.querySelectorAll('.bid-month-details');
        ownDetails.forEach(function(md) { md.style.display = 'none'; });
        var ownIcons = content.querySelectorAll('.bid-month-row .bid-expand-icon');
        ownIcons.forEach(function(mi) { mi.textContent = '\u25B6'; });
    }

    content.style.display = isOpening ? 'block' : 'none';
    icon.textContent = isOpening ? '\u25BC' : '\u25B6';
}

/* Toggles a month row's per-day detail table open or closed. Dispatched from
   the bid-toggle-month click action on the month row. */
function bid_handleToggleMonth(target, event) {
    var tbody = target.closest('tbody');
    var detailsRow = tbody.querySelector('.bid-month-details');
    var icon = target.querySelector('.bid-expand-icon');
    var isOpen = detailsRow.style.display !== 'none';

    detailsRow.style.display = isOpen ? 'none' : 'table-row';
    icon.textContent = isOpen ? '\u25B6' : '\u25BC';
}

/* ============================================================================
   FUNCTIONS: BUILD DETAIL SLIDEOUT
   ----------------------------------------------------------------------------
   The build-detail slideout. Opening a trend bar or history day row loads all
   builds for that date and renders each build's summary grid and per-step
   table into the slideout, with multi-attempt separators. Open and close
   follow the shared static slide-overlay pattern (cc-open on the overlay and
   the inner cc-dialog, with a transitionend-driven close).
   Prefix: bid
   ============================================================================ */

/* Opens the slideout for all builds on a given date. Dispatched from the
   bid-open-build-by-date click action on a trend bar or history day row; reads
   the date from the element's argument attribute, loads the builds, and
   highlights the matching trend bar. */
function bid_handleOpenBuildByDate(target, event) {
    var dateStr = target.getAttribute('data-action-bid-date');
    bid_loadBuildsForDate(dateStr);
}

/* Loads all builds for a date and renders them into the slideout, then
   highlights the corresponding trend bar. */
function bid_loadBuildsForDate(dateStr) {
    cc_engineFetch('/api/bidata/builds-for-date?date=' + dateStr)
        .then(function(data) {
            if (!data) return;
            if (data.error) { console.error('Build details:', data.error); return; }
            bid_renderBuildsForDate(data, dateStr);
            bid_highlightTrendBar(dateStr);
        })
        .catch(function(err) { console.error('Failed to load build details:', err.message); });
}

/* Renders one or more builds for a date into the slideout body. Each build
   gets a summary grid and a per-step table; multiple attempts are separated
   and labeled. Opens the slideout once the content is built. */
function bid_renderBuildsForDate(data, dateStr) {
    document.getElementById('bid-detail-slideout-title').textContent = 'Builds: ' + dateStr;

    var html = '';

    data.builds.forEach(function(buildData, idx) {
        var build = buildData.build;
        var steps = buildData.steps;

        if (idx > 0) {
            html += '<div class="bid-build-separator"></div>';
        }

        if (data.builds.length > 1) {
            var attemptSuffix = build.status === 'COMPLETED' ? ' (Final)'
                              : build.status === 'IN_PROGRESS' ? ' (Running)'
                              : ' (Failed)';
            html += '<div class="bid-build-attempt-header">Attempt #' + (data.builds.length - idx) + attemptSuffix + '</div>';
        }

        html += '<div class="bid-detail-section"><div class="bid-detail-section-title">Summary</div><div class="bid-detail-grid">';
        html += '<div class="bid-detail-item"><span class="bid-detail-label">Status</span><span class="bid-detail-value ' + bid_getStatusClass(build.status) + '">' + build.status + '</span></div>';
        html += '<div class="bid-detail-item"><span class="bid-detail-label">Start</span><span class="bid-detail-value">' + (build.start_dttm || 'N/A') + '</span></div>';
        html += '<div class="bid-detail-item"><span class="bid-detail-label">End</span><span class="bid-detail-value">' + (build.end_dttm || 'N/A') + '</span></div>';
        html += '<div class="bid-detail-item"><span class="bid-detail-label">Duration</span><span class="bid-detail-value">' + (build.total_duration_formatted || 'N/A') + '</span></div>';
        html += '<div class="bid-detail-item"><span class="bid-detail-label">Steps</span><span class="bid-detail-value">' + build.step_count + '</span></div>';
        if (build.failed_step_name) {
            html += '<div class="bid-detail-item bid-full-width"><span class="bid-detail-label">Failed Step</span><span class="bid-detail-value bid-error">' + cc_escapeHtml(build.failed_step_name) + '</span></div>';
        }
        html += '</div></div>';

        html += '<div class="bid-detail-section"><div class="bid-detail-section-title">Step Details</div><table class="bid-step-table"><thead><tr><th class="bid-step-table-th">#</th><th class="bid-step-table-th">Name</th><th class="bid-step-table-th">Status</th><th class="bid-step-table-th">Duration</th></tr></thead><tbody>';
        steps.forEach(function(step) {
            var badgeClass = step.run_status === 1 ? 'bid-success' : 'bid-failed';
            var badgeLabel = step.run_status === 1 ? 'COMPLETED' : 'FAILED';
            html += '<tr><td class="bid-step-table-td">' + step.step_id + '</td><td class="bid-step-table-td">' + cc_escapeHtml(step.step_name) + '</td><td class="bid-step-table-td bid-status-cell"><span class="bid-step-status-badge ' + badgeClass + '">' + badgeLabel + '</span></td><td class="bid-step-table-td">' + step.duration_formatted + '</td></tr>';
        });
        html += '</tbody></table></div>';
    });

    document.getElementById('bid-detail-slideout-body').innerHTML = html;
    bid_openSlideout();
}

/* Opens the build-detail slideout. Adds cc-open to the overlay, then adds
   cc-open to the inner cc-dialog inside a requestAnimationFrame callback so the
   slide-in transition runs. */
function bid_openSlideout() {
    var overlay = document.getElementById('bid-slideout-detail');
    var dialog = overlay.querySelector('.cc-dialog');
    overlay.classList.add('cc-open');
    requestAnimationFrame(function() {
        dialog.classList.add('cc-open');
    });
}

/* Closes the build-detail slideout. Attaches a one-shot transitionend listener
   to the inner cc-dialog that removes cc-open from the overlay once the
   slide-out transition finishes, then removes cc-open from the dialog to start
   it, and clears any highlighted trend bar. Wired from the close button and the
   overlay backdrop via the bid-close-slideout click action. The dispatcher
   passes the matched action element as target. When target is the overlay
   itself, the click is only a dismiss if it landed directly on the backdrop
   (event.target === target); a click that bubbled up from the dialog interior
   is ignored. When target is an explicit close control (the X button), the
   slideout always closes. */
function bid_closeSlideout(target, event) {
    if (event && target.id === 'bid-slideout-detail' && event.target !== target) {
        return;
    }
    var overlay = document.getElementById('bid-slideout-detail');
    var dialog = overlay.querySelector('.cc-dialog');
    dialog.addEventListener('transitionend', function handler() {
        dialog.removeEventListener('transitionend', handler);
        overlay.classList.remove('cc-open');
    });
    dialog.classList.remove('cc-open');
    var highlighted = document.querySelectorAll('.bid-highlighted');
    highlighted.forEach(function(el) { el.classList.remove('bid-highlighted'); });
}

/* ============================================================================
   FUNCTIONS: UTILITIES
   ----------------------------------------------------------------------------
   Page-local helpers: status-class mapping, date and duration formatting, the
   step run-time and end-time calculations, the date-input formatter, the
   elapsed-time calculation, and the timestamp display update. The standard
   cc_escapeHtml and cc_formatTimeOfDay come from cc-shared.js.
   Prefix: bid
   ============================================================================ */

/* Maps a build status string to its bid- status class for detail-value
   coloring. Returns an empty string for unrecognized statuses. */
function bid_getStatusClass(status) {
    switch (status) {
        case 'COMPLETED':   return 'bid-status-completed';
        case 'FAILED':      return 'bid-status-failed';
        default:            return '';
    }
}

/* Formats an ISO date string (YYYY-MM-DD) as a US long display date. Returns
   'N/A' for an empty input. */
function bid_formatDate(dateStr) {
    if (!dateStr) return 'N/A';
    var dt = new Date(dateStr + 'T00:00:00');
    return dt.toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' });
}

/* Formats a duration in seconds as H:MM:SS. Returns '-' for null or undefined. */
function bid_formatDuration(seconds) {
    if (seconds === null || seconds === undefined) return '-';
    var h = Math.floor(seconds / 3600);
    var m = Math.floor((seconds % 3600) / 60);
    var s = Math.floor(seconds % 60);
    return h + ':' + String(m).padStart(2, '0') + ':' + String(s).padStart(2, '0');
}

/* Formats a SQL run_time integer (HHMMSS) as an HH:MM:SS string. Returns
   '--:--:--' when the value is missing. */
function bid_formatRunTime(runTime) {
    if (!runTime && runTime !== 0) return '--:--:--';
    var str = String(runTime).padStart(6, '0');
    return str.substring(0, 2) + ':' + str.substring(2, 4) + ':' + str.substring(4, 6);
}

/* Calculates a step's end time from its run_time start (HHMMSS) plus a
   duration in seconds, returning an HH:MM:SS string. Returns '--:--:--' when
   either input is missing. */
function bid_calculateStepEndTime(runTime, durationSeconds) {
    if (!runTime && runTime !== 0) return '--:--:--';
    if (!durationSeconds && durationSeconds !== 0) return '--:--:--';
    var str = String(runTime).padStart(6, '0');
    var hours = parseInt(str.substring(0, 2), 10);
    var mins = parseInt(str.substring(2, 4), 10);
    var secs = parseInt(str.substring(4, 6), 10);
    var totalSecs = hours * 3600 + mins * 60 + secs + durationSeconds;
    var endHours = Math.floor(totalSecs / 3600) % 24;
    var endMins = Math.floor((totalSecs % 3600) / 60);
    var endSecs = totalSecs % 60;
    return String(endHours).padStart(2, '0') + ':' + String(endMins).padStart(2, '0') + ':' + String(endSecs).padStart(2, '0');
}

/* Formats a Date object as a YYYY-MM-DD string suitable for a date input
   value. */
function bid_formatDateForInput(date) {
    return date.getFullYear() + '-' + String(date.getMonth() + 1).padStart(2, '0') + '-' + String(date.getDate()).padStart(2, '0');
}

/* Calculates elapsed seconds from a start timestamp string to now. Returns 0
   for an empty input. */
function bid_calculateElapsed(startTimeStr) {
    if (!startTimeStr) return 0;
    return Math.floor((new Date() - new Date(startTimeStr)) / 1000);
}

/* Updates the live "last updated" timestamp in the page header to the current
   local time. */
function bid_updateTimestamp() {
    var el = document.getElementById('cc-last-update');
    if (el) {
        el.textContent = new Date().toLocaleTimeString();
    }
}

/* ============================================================================
   FUNCTIONS: PAGE LIFECYCLE HOOKS
   ----------------------------------------------------------------------------
   Hooks invoked by cc-shared.js. The shared module resolves each via
   window['bid_<hook>'] and calls it at the appropriate moment in the page
   lifecycle.
   Prefix: bid
   ============================================================================ */

/* Called by cc-shared.js when the user clicks the page refresh button.
   cc-shared.js drives the spin animation; this hook does the actual data
   reload. */
function bid_onPageRefresh() {
    bid_refreshAll();
}

/* Called by cc-shared.js when the page becomes visible again after being
   hidden. Reloads all sections so the user sees current data. */
function bid_onPageResumed() {
    bid_refreshAll();
}

/* Called by cc-shared.js when the session is detected as expired. Stops the
   live-polling timer so we do not keep firing timers after the session ends. */
function bid_onSessionExpired() {
    bid_stopLivePolling();
}

/* Called by cc-shared.js when the Monitor-BIDATABuild process completes.
   Refreshes the event-driven sections (Live Activity, Build Execution, Build
   History) since fresh build data is now available. */
function bid_onEngineProcessCompleted(processName, event) {
    bid_refreshEventSections();
}

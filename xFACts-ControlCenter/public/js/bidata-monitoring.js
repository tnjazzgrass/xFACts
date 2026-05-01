/* ============================================================================
   xFACts Control Center - BIDATA Monitoring JavaScript
   Location: E:\xFACts-ControlCenter\public\js\bidata-monitoring.js
   Version: Tracked in dbo.System_Metadata (component: BIDATA)

   Page-specific JavaScript for the BIDATA Daily Build monitoring dashboard.
   Cross-page utilities (escapeHtml, formatTimeOfDay, MONTH_NAMES, showAlert,
   showConfirm, engineFetch, pageRefresh, etc.) are provided by engine-events.js.

   CHANGELOG
   ---------
   2026-04-30  Phase 4 (Standardization): full alignment to shared module.
                 - Deleted local escapeHtml; uses shared escapeHtml.
                 - Deleted local formatTime; uses shared formatTimeOfDay.
                 - Deleted local monthNames; uses shared MONTH_NAMES.
                 - Deleted local pageRefresh; defined onPageRefresh hook
                   that the shared module's pageRefresh wrapper calls.
                 - Deleted local showError/clearError; replaced call sites
                   with console.error() per Phase 4 alignment pattern.
                 - Deleted duplicate formatSecondsToHHMMSS (was identical
                   to formatDuration); call sites updated to formatDuration.
                 - Replaced native alert() calls in applyCustomDateRange()
                   with shared showAlert().
                 - Slideout open/close: updated DOM IDs to match new shared
                   .slide-panel-* markup (#build-slideout-overlay).
                 - Date modal open/close: switched from .classList.add/remove('open')
                   to .classList.remove/add('hidden') for shared .xf-modal-overlay.
   ============================================================================ */

// ============================================================================
// CONFIGURATION
// ============================================================================

// Engine events — process map for shared WebSocket module (engine-events.js)
var ENGINE_PROCESSES = {
    'Monitor-BIDATABuild': { slug: 'bidata' }
};

// Live polling (Refresh Architecture — plumbing ready, not currently active)
var PAGE_REFRESH_INTERVAL = 30;   // Default; overridden by GlobalConfig on load

// Page hooks for engine-events.js shared module
function onPageRefresh()    { refreshAll(); }
function onPageResumed()    { refreshAll(); }
function onSessionExpired() { stopLivePolling(); }

var livePollingTimer = null;
var pageLoadDate = new Date().toDateString();

// Page state
var currentTrendDays = 30;          // Default to 30 days
var customDateRange = null;
var excludedStepIds = [1, 2, 17, 18, 19, 20];
var currentTrendData = null;
var currentHistoryData = null;


// ============================================================================
// INITIALIZATION
// ============================================================================

document.addEventListener('DOMContentLoaded', async function() {
    await loadRefreshInterval();
    refreshAll();
    connectEngineEvents();
    initEngineCardClicks();
    startAutoRefresh();

    // Trend range button group
    document.querySelectorAll('.trend-btn').forEach(function(btn) {
        btn.addEventListener('click', function() {
            var days = this.getAttribute('data-days');
            if (days === 'custom') {
                openDateRangeModal();
            } else {
                document.querySelectorAll('.trend-btn').forEach(function(b) { b.classList.remove('active'); });
                this.classList.add('active');
                customDateRange = null;
                currentTrendDays = parseInt(days);
                loadDurationTrend(days);
            }
        });
    });

    // Date range modal action buttons
    document.getElementById('modal-cancel').addEventListener('click', closeDateRangeModal);
    document.getElementById('modal-apply').addEventListener('click', applyCustomDateRange);
});


// ============================================================================
// REFRESH ARCHITECTURE
// ----------------------------------------------------------------------------
// All sections currently event-driven (data populated by Monitor-BIDATABuild).
// Duration Trend is action-driven (refreshes on date range button click).
// Live polling plumbing is ready for future use when direct polling is needed.
// See: Refresh Architecture doc, Section 6.6
// ============================================================================

async function loadRefreshInterval() {
    try {
        var data = await engineFetch('/api/config/refresh-interval?page=bidata');
        if (data) {
            PAGE_REFRESH_INTERVAL = data.interval || 30;
        }
    } catch (e) {
        // API unavailable -- use default
    }
}

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

function startAutoRefresh() {
    setInterval(function() {
        var today = new Date().toDateString();
        if (today !== pageLoadDate) {
            window.location.reload();
        }
    }, 60000);
}

// ── Live sections: placeholder for future direct polling ──
function refreshLiveSections() {
    // Currently unused -- all sections are event-driven.
    // When live polling is enabled, move sections here that need
    // direct queries independent of the orchestrator cycle.
    updateTimestamp();
}

// ── Event-driven sections: refresh on orchestrator PROCESS_COMPLETED ──
function refreshEventSections() {
    loadLiveActivity();
    loadCurrentBuildExecution();
    loadBuildHistory();
    updateTimestamp();
}

// ── Manual refresh: everything (excluding Duration Trend -- action-driven) ──
function refreshAll() {
    loadLiveActivity();
    loadCurrentBuildExecution();
    loadDurationTrend(currentTrendDays);
    loadBuildHistory();
    updateTimestamp();
}

function updateTimestamp() {
    document.getElementById('last-update').textContent = new Date().toLocaleTimeString();
}

// Called by engine-events.js when a relevant PROCESS_COMPLETED event arrives
function onEngineProcessCompleted(processName, event) {
    refreshEventSections();
}


// ============================================================================
// API CALLS
// ============================================================================

function loadLiveActivity() {
    engineFetch('/api/bidata/todays-build')
        .then(function(data) {
            if (!data) return;
            if (data.error) { console.error('Live activity:', data.error); return; }
            renderLiveActivity(data);
            updateTimestamp();
        })
        .catch(function(err) { console.error('Failed to load live activity:', err.message); });
}

function loadCurrentBuildExecution() {
    engineFetch('/api/bidata/step-progress')
        .then(function(data) {
            if (!data) return;
            if (data.error) { console.error('Step progress:', data.error); return; }
            renderCurrentBuildExecution(data);
        })
        .catch(function(err) { console.error('Failed to load step progress:', err.message); });
}

function loadDurationTrend(days, fromDate, toDate) {
    var url = '/api/bidata/duration-trend?days=' + days;
    if (fromDate && toDate) url = '/api/bidata/duration-trend?from=' + fromDate + '&to=' + toDate;
    engineFetch(url)
        .then(function(data) {
            if (!data) return;
            if (data.error) { console.error('Duration trend:', data.error); return; }
            currentTrendData = data;
            renderDurationTrend(data);
        })
        .catch(function(err) { console.error('Failed to load duration trend:', err.message); });
}

function loadBuildHistory() {
    engineFetch('/api/bidata/build-history')
        .then(function(data) {
            if (!data) return;
            if (data.error) { console.error('Build history:', data.error); return; }
            currentHistoryData = data;
            renderBuildHistory(data);
        })
        .catch(function(err) { console.error('Failed to load build history:', err.message); });
}

function loadBuildDetails(buildId, dateStr) {
    engineFetch('/api/bidata/build-details?build_id=' + buildId)
        .then(function(data) {
            if (!data) return;
            if (data.error) { console.error('Build details:', data.error); return; }
            renderBuildDetails(data, dateStr);
            if (dateStr) highlightTrendBar(dateStr);
        })
        .catch(function(err) { console.error('Failed to load build details:', err.message); });
}

// Load all builds for a date (for slideout with multiple executions)
function loadBuildsForDate(dateStr) {
    engineFetch('/api/bidata/builds-for-date?date=' + dateStr)
        .then(function(data) {
            if (!data) return;
            if (data.error) { console.error('Build details:', data.error); return; }
            renderBuildsForDate(data, dateStr);
            highlightTrendBar(dateStr);
        })
        .catch(function(err) { console.error('Failed to load build details:', err.message); });
}


// ============================================================================
// RENDER: LIVE ACTIVITY
// ----------------------------------------------------------------------------
// Status card uses badge pill; other cards have title left, emoji right.
// All cards share the same border color based on status.
// ============================================================================

function renderLiveActivity(data) {
    var container = document.getElementById('live-activity');

    if (!data.builds || data.builds.length === 0) {
        var html = '<div class="activity-grid">';
        html += '<div class="activity-card status-waiting">';
        html += '<div class="activity-card-header"><span class="activity-name">Status</span><span class="build-status-badge waiting">Waiting</span></div>';
        html += '<div class="activity-card-body"><div class="activity-value">No Build</div><div class="activity-detail">No build activity today</div></div>';
        html += '</div>';
        html += '</div>';
        container.innerHTML = html;
        return;
    }

    var build = data.builds[0];
    var html = '<div class="activity-grid">';

    if (build.status === 'IN_PROGRESS') {
        var elapsed = calculateElapsed(build.start_dttm);
        // Status card -- badge pill with spinning gear
        html += '<div class="activity-card status-running">';
        html += '<div class="activity-card-header"><span class="activity-name">Status</span><span class="build-status-badge running"><span class="spinning-gear">&#9881;</span> Running</span></div>';
        html += '<div class="activity-card-body"><div class="activity-value">In Progress</div><div class="activity-detail">Build running</div></div>';
        html += '</div>';
        // Started card
        html += '<div class="activity-card status-running">';
        html += '<div class="activity-card-header"><span class="activity-name">Started</span><span class="activity-icon">&#128340;</span></div>';
        html += '<div class="activity-card-body"><div class="activity-value">' + formatTimeOfDay(build.start_dttm) + '</div><div class="activity-detail">' + formatDate(build.build_date) + '</div></div>';
        html += '</div>';
        // Elapsed card
        html += '<div class="activity-card status-running">';
        html += '<div class="activity-card-header"><span class="activity-name">Elapsed</span><span class="activity-icon">&#9201;</span></div>';
        html += '<div class="activity-card-body"><div class="activity-value">' + formatDuration(elapsed) + '</div><div class="activity-detail">Running time</div></div>';
        html += '</div>';
        // Progress card
        html += '<div class="activity-card status-running">';
        html += '<div class="activity-card-header"><span class="activity-name">Progress</span><span class="activity-icon">&#128202;</span></div>';
        html += '<div class="activity-card-body"><div class="activity-value">' + build.steps_completed + ' / ' + data.total_expected_steps + '</div><div class="activity-detail">Steps completed</div></div>';
        html += '</div>';
        // ETA card (if calculable)
        if (data.avg_duration_seconds && elapsed > 0) {
            var remaining = data.avg_duration_seconds - elapsed;
            if (remaining > 0) {
                var eta = new Date(new Date().getTime() + (remaining * 1000));
                html += '<div class="activity-card status-running">';
                html += '<div class="activity-card-header"><span class="activity-name">ETA</span><span class="activity-icon">&#127919;</span></div>';
                html += '<div class="activity-card-body"><div class="activity-value">~' + formatTimeOfDay(eta) + '</div><div class="activity-detail">Estimated completion</div></div>';
                html += '</div>';
            }
        }
    } else if (build.status === 'COMPLETED') {
        // Status card -- completed badge pill
        html += '<div class="activity-card status-completed">';
        html += '<div class="activity-card-header"><span class="activity-name">Status</span><span class="build-status-badge completed">Completed</span></div>';
        html += '<div class="activity-card-body"><div class="activity-value">Success</div><div class="activity-detail">Build successful</div></div>';
        html += '</div>';
        // Date card
        html += '<div class="activity-card status-completed">';
        html += '<div class="activity-card-header"><span class="activity-name">Date</span><span class="activity-icon">&#128197;</span></div>';
        html += '<div class="activity-card-body"><div class="activity-value">' + formatDate(build.build_date) + '</div><div class="activity-detail">Build date</div></div>';
        html += '</div>';
        // Started card
        html += '<div class="activity-card status-completed">';
        html += '<div class="activity-card-header"><span class="activity-name">Started</span><span class="activity-icon">&#128340;</span></div>';
        html += '<div class="activity-card-body"><div class="activity-value">' + formatTimeOfDay(build.start_dttm) + '</div><div class="activity-detail">Start time</div></div>';
        html += '</div>';
        // Completed card
        html += '<div class="activity-card status-completed">';
        html += '<div class="activity-card-header"><span class="activity-name">Completed</span><span class="activity-icon">&#127937;</span></div>';
        html += '<div class="activity-card-body"><div class="activity-value">' + formatTimeOfDay(build.end_dttm) + '</div><div class="activity-detail">End time</div></div>';
        html += '</div>';
        // Duration card
        html += '<div class="activity-card status-completed">';
        html += '<div class="activity-card-header"><span class="activity-name">Duration</span><span class="activity-icon">&#9201;</span></div>';
        html += '<div class="activity-card-body"><div class="activity-value">' + build.total_duration_formatted + '</div><div class="activity-detail">Total time</div></div>';
        html += '</div>';
    } else if (build.status === 'FAILED') {
        // Status card -- failed badge pill
        html += '<div class="activity-card status-failed">';
        html += '<div class="activity-card-header"><span class="activity-name">Status</span><span class="build-status-badge failed">Failed</span></div>';
        html += '<div class="activity-card-body"><div class="activity-value">Error</div><div class="activity-detail">Build error</div></div>';
        html += '</div>';
        // Date card
        html += '<div class="activity-card status-failed">';
        html += '<div class="activity-card-header"><span class="activity-name">Date</span><span class="activity-icon">&#128197;</span></div>';
        html += '<div class="activity-card-body"><div class="activity-value">' + formatDate(build.build_date) + '</div><div class="activity-detail">Build date</div></div>';
        html += '</div>';
        // Started card
        html += '<div class="activity-card status-failed">';
        html += '<div class="activity-card-header"><span class="activity-name">Started</span><span class="activity-icon">&#128340;</span></div>';
        html += '<div class="activity-card-body"><div class="activity-value">' + formatTimeOfDay(build.start_dttm) + '</div><div class="activity-detail">Start time</div></div>';
        html += '</div>';
        // Failed At card
        html += '<div class="activity-card status-failed">';
        html += '<div class="activity-card-header"><span class="activity-name">Failed At</span><span class="activity-icon">&#128165;</span></div>';
        html += '<div class="activity-card-body"><div class="activity-value">' + formatTimeOfDay(build.end_dttm) + '</div><div class="activity-detail">Failure time</div></div>';
        html += '</div>';
        // Failed Step card
        if (build.failed_step_name) {
            html += '<div class="activity-card status-failed">';
            html += '<div class="activity-card-header"><span class="activity-name">Failed Step</span><span class="activity-icon">&#9888;</span></div>';
            html += '<div class="activity-card-body"><div class="activity-value" style="font-size:12px;">' + escapeHtml(build.failed_step_name) + '</div><div class="activity-detail">Error location</div></div>';
            html += '</div>';
        }
    }

    // Attempts card if multiple
    if (data.builds.length > 1) {
        var statusClass = build.status === 'COMPLETED' ? 'status-completed' : (build.status === 'FAILED' ? 'status-failed' : 'status-running');
        html += '<div class="activity-card ' + statusClass + '">';
        html += '<div class="activity-card-header"><span class="activity-name">Attempts</span><span class="activity-icon">&#128260;</span></div>';
        html += '<div class="activity-card-body"><div class="activity-value">' + data.builds.length + '</div><div class="activity-detail">Today</div></div>';
        html += '</div>';
    }

    html += '</div>';
    container.innerHTML = html;
}


// ============================================================================
// RENDER: BUILD EXECUTION
// ============================================================================

function renderCurrentBuildExecution(data) {
    var container = document.getElementById('current-build-execution');

    if (!data.steps || data.steps.length === 0) {
        container.innerHTML = '<div class="no-active-build"><div class="no-active-icon">&#128164;</div><div class="no-active-text">No Build Today</div><div class="no-active-subtext">Step execution details will appear here when a build starts</div></div>';
        return;
    }

    // Helper to format run_time (HHMMSS int) to HH:MM:SS string
    function formatRunTime(runTime) {
        if (!runTime && runTime !== 0) return '--:--:--';
        var str = String(runTime).padStart(6, '0');
        return str.substring(0, 2) + ':' + str.substring(2, 4) + ':' + str.substring(4, 6);
    }

    // Helper to calculate end time from start + duration
    function calculateEndTime(runTime, durationSeconds) {
        if (!runTime && runTime !== 0) return '--:--:--';
        if (!durationSeconds && durationSeconds !== 0) return '--:--:--';
        var str = String(runTime).padStart(6, '0');
        var hours = parseInt(str.substring(0, 2));
        var mins = parseInt(str.substring(2, 4));
        var secs = parseInt(str.substring(4, 6));
        var totalSecs = hours * 3600 + mins * 60 + secs + durationSeconds;
        var endHours = Math.floor(totalSecs / 3600) % 24;
        var endMins = Math.floor((totalSecs % 3600) / 60);
        var endSecs = totalSecs % 60;
        return String(endHours).padStart(2, '0') + ':' + String(endMins).padStart(2, '0') + ':' + String(endSecs).padStart(2, '0');
    }

    var displaySteps = data.steps.filter(function(s) { return excludedStepIds.indexOf(s.step_id) === -1; });

    // Header row
    var html = '<div class="execution-list">';
    html += '<div class="step-row step-header">';
    html += '<span class="step-status-badge"></span>';
    html += '<span class="step-name">Step Name</span>';
    html += '<span class="step-time">Start Time</span>';
    html += '<span class="step-time">End Time</span>';
    html += '<span class="step-duration-col">Duration</span>';
    html += '<span class="step-variance-col">14 Day Var</span>';
    html += '</div>';

    displaySteps.forEach(function(step) {
        var avgDuration = data.avg_durations ? data.avg_durations[String(step.step_id)] : null;
        var statusClass = step.run_status === 1 ? 'step-success' : 'step-failed';
        var badgeClass = step.run_status === 1 ? 'success' : 'failed';
        var badgeLabel = step.run_status === 1 ? 'COMPLETED' : 'FAILED';

        var startTime = formatRunTime(step.run_time);
        var endTime = calculateEndTime(step.run_time, step.duration_seconds);

        var comparison = '';
        if (avgDuration && step.duration_seconds !== null && step.duration_seconds !== undefined) {
            var diff = step.duration_seconds - avgDuration;
            var pctDiff = Math.round((diff / avgDuration) * 100);
            var compClass = diff > 0 ? 'slower' : (diff < 0 ? 'faster' : 'neutral');
            var compSign = diff > 0 ? '+' : '';
            comparison = '<span class="step-comparison ' + compClass + '">' + compSign + pctDiff + '%</span>';
        }

        html += '<div class="step-row ' + statusClass + '">';
        html += '<span class="step-status-badge ' + badgeClass + '">' + badgeLabel + '</span>';
        html += '<span class="step-name">' + escapeHtml(step.step_name) + '</span>';
        html += '<span class="step-time">' + startTime + '</span>';
        html += '<span class="step-time">' + endTime + '</span>';
        html += '<span class="step-duration-col">' + step.duration_formatted + '</span>';
        html += '<span class="step-variance-col">' + comparison + '</span>';
        html += '</div>';
    });

    if (data.next_step_number && data.current_step_elapsed_seconds !== null) {
        // Calculate start time for running step (end time of last completed step)
        var runningStartTime = '--:--:--';
        if (displaySteps.length > 0) {
            var lastStep = displaySteps[displaySteps.length - 1];
            runningStartTime = calculateEndTime(lastStep.run_time, lastStep.duration_seconds);
        }

        html += '<div class="step-row step-running">';
        html += '<span class="step-status-badge running"><span class="spinning-gear">&#9881;</span></span>';
        html += '<span class="step-name">Step ' + data.next_step_number + ' executing...</span>';
        html += '<span class="step-time">' + runningStartTime + '</span>';
        html += '<span class="step-time">--:--:--</span>';
        html += '<span class="step-duration-col step-duration-running">' + formatDuration(data.current_step_elapsed_seconds) + '</span>';
        html += '<span class="step-variance-col"></span>';
        html += '</div>';
    }

    html += '</div>';
    container.innerHTML = html;
}


// ============================================================================
// RENDER: DURATION TREND
// ----------------------------------------------------------------------------
// Full-width chart with conditional date labels (only when <=30 days).
// ============================================================================

function renderDurationTrend(data) {
    var container = document.getElementById('duration-trend');

    if (!data.data_points || data.data_points.length === 0) {
        container.innerHTML = '<div class="no-data">No trend data available</div>';
        return;
    }

    var points = data.data_points;
    var showDateLabels = points.length <= 30;  // Only show dates for 30 or fewer days

    // Find max duration for scaling
    var durations = points.map(function(d) {
        return d.total_execution_seconds > 0 ? d.total_execution_seconds : d.duration_seconds;
    }).filter(function(d) { return d > 0; });

    if (durations.length === 0) {
        container.innerHTML = '<div class="no-data">No duration data available</div>';
        return;
    }

    var maxDuration = Math.max.apply(null, durations);

    // Chart area -- bars fill full width
    var html = '<div class="trend-chart-area">';

    points.forEach(function(point) {
        var duration = point.total_execution_seconds > 0 ? point.total_execution_seconds : point.duration_seconds;
        var heightPct = maxDuration > 0 ? Math.max(3, (duration / maxDuration) * 100) : 50;
        var tooltip = point.date + (point.attempt_count > 1 ? ' (' + point.attempt_count + ' attempts)' : '') + '\nDuration: ' + formatDuration(duration);

        html += '<div class="trend-bar-wrapper">';
        html += '<div class="trend-bar-container" data-date="' + point.date + '" title="' + escapeHtml(tooltip) + '" onclick="openBuildByDate(\'' + point.date + '\')">';

        if (point.segments && point.segments.length > 1) {
            html += '<div class="trend-bar-stacked" style="height:' + heightPct + '%;">';
            var totalSec = point.total_wall_clock_seconds > 0 ? point.total_wall_clock_seconds : duration;
            point.segments.forEach(function(seg) {
                var segPct = totalSec > 0 ? (seg.seconds / totalSec) * 100 : 0;
                html += '<div class="trend-bar-segment bar-' + seg.type + '" style="height:' + segPct + '%;"></div>';
            });
            html += '</div>';
        } else {
            var barClass = point.final_status === 'FAILED' ? 'bar-failed' : 'bar-success';
            html += '<div class="trend-bar ' + barClass + '" style="height:' + heightPct + '%;"></div>';
        }

        html += '</div></div>';
    });

    html += '</div>';

    // Date labels (only if <= 30 days)
    if (showDateLabels) {
        html += '<div class="trend-date-labels">';
        points.forEach(function(point) {
            var dateLabel = point.date_short || point.date.substring(5);  // MM-DD format
            html += '<div class="trend-date-label">' + dateLabel.replace('-', '/') + '</div>';
        });
        html += '</div>';
    }

    // Stats below chart
    html += '<div class="trend-stats">';
    if (data.stats.avg_formatted) html += '<div class="stat"><span class="stat-label">Avg</span> <span class="stat-value">' + data.stats.avg_formatted + '</span></div>';
    if (data.stats.min_seconds)   html += '<div class="stat"><span class="stat-label">Min</span> <span class="stat-value">' + formatDuration(data.stats.min_seconds) + '</span></div>';
    if (data.stats.max_seconds)   html += '<div class="stat"><span class="stat-label">Max</span> <span class="stat-value">' + formatDuration(data.stats.max_seconds) + '</span></div>';
    html += '<div class="stat"><span class="stat-label">Days</span> <span class="stat-value">' + data.stats.count + '</span></div>';
    html += '</div>';

    container.innerHTML = html;
}


// ============================================================================
// RENDER: BUILD HISTORY
// ----------------------------------------------------------------------------
// Hierarchical year/month/day expansion with summary tables.
// ============================================================================

function renderBuildHistory(data) {
    var container = document.getElementById('build-history');
    var countEl = document.getElementById('history-count');

    if (!data.grouped || Object.keys(data.grouped).length === 0) {
        container.innerHTML = '<div class="no-data">No build history available</div>';
        return;
    }

    countEl.textContent = data.total_count + ' builds';
    var html = '<div class="history-tree">';
    var years = Object.keys(data.grouped).sort(function(a, b) { return parseInt(b) - parseInt(a); });

    years.forEach(function(year) {
        var yearData = data.grouped[year];

        // Aggregate year totals from month summaries
        var yearBuilds = 0, yearSuccess = 0, yearFailed = 0;
        var months = Object.keys(yearData).sort(function(a, b) { return parseInt(b) - parseInt(a); });
        months.forEach(function(month) {
            var monthKey = year + '-' + month;
            var summary = data.month_summaries ? data.month_summaries[monthKey] : null;
            if (summary) {
                yearSuccess += summary.success_count || 0;
                yearFailed += summary.failed_count || 0;
            }
        });
        yearBuilds = yearSuccess + yearFailed;

        html += '<div class="history-year" data-year="' + year + '">';
        html += '<div class="year-header" onclick="toggleYear(this)">';
        html += '<span class="expand-icon">&#9654;</span>';
        html += '<span class="year-label">' + year + '</span>';
        html += '<div class="year-stats">';
        html += '<span class="year-stat">' + yearBuilds + ' builds</span>';
        html += '<span class="year-stat success">' + yearSuccess + ' success</span>';
        html += '<span class="year-stat failed">' + (yearFailed > 0 ? yearFailed + ' failed' : '-') + '</span>';
        html += '</div>';
        html += '</div>';
        html += '<div class="year-content" style="display:none;">';

        // Month summary table with headers -- each month has its own expandable section
        html += '<table class="month-summary-table">';
        html += '<thead><tr><th></th><th>Month</th><th>Successful</th><th>Failed</th><th>Avg Duration</th></tr></thead>';

        months.forEach(function(month) {
            var monthData = yearData[month];
            var monthName = MONTH_NAMES[parseInt(month)];
            var monthKey = year + '-' + month;
            var summary = data.month_summaries ? data.month_summaries[monthKey] : null;

            // Month summary row
            html += '<tbody class="month-group" data-month="' + month + '">';
            html += '<tr class="month-row" onclick="toggleMonthGroup(this)">';
            html += '<td class="expand-cell"><span class="expand-icon">&#9654;</span></td>';
            html += '<td class="month-cell">' + monthName + '</td>';
            if (summary) {
                html += '<td class="success-cell">' + summary.success_count + '</td>';
                html += '<td class="fail-cell">' + (summary.failed_count > 0 ? summary.failed_count : '-') + '</td>';
                html += '<td class="avg-cell">' + (summary.avg_duration_formatted || '-') + '</td>';
            } else {
                html += '<td>-</td><td>-</td><td>-</td>';
            }
            html += '</tr>';

            // Daily builds rows (hidden by default) -- nested in same tbody
            html += '<tr class="month-details" style="display:none;"><td colspan="5">';
            html += '<table class="history-table"><thead><tr>';
            html += '<th>Status</th><th>Day</th><th>Date</th><th>Job</th><th>Instance</th><th>Start</th><th>End</th><th>Duration</th>';
            html += '</tr></thead><tbody>';

            monthData.forEach(function(build, idx) {
                var statusClass = build.status === 'COMPLETED' ? 'success' : 'failed';
                var altClass = idx % 2 === 0 ? '' : 'row-odd';
                var dateParts = build.build_date.split('-');
                var monthDay = dateParts[1] + '/' + dateParts[2];

                html += '<tr class="' + altClass + '" onclick="openBuildByDate(\'' + build.build_date + '\')">';
                html += '<td><span class="history-status-badge ' + statusClass + '">' + (statusClass === 'success' ? 'SUCCESS' : 'FAILED') + '</span></td>';
                html += '<td>' + build.day_name + '</td>';
                html += '<td>' + monthDay + '</td>';
                html += '<td>' + (build.job_name || 'BIDATA Daily Build') + '</td>';
                html += '<td>' + (build.instance_id || '-') + '</td>';
                html += '<td>' + (build.start_dttm || '-') + '</td>';
                html += '<td>' + (build.end_dttm || '-') + '</td>';
                html += '<td class="duration-cell ' + statusClass + '">' + (build.total_duration_formatted || '-') + '</td>';
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


// ============================================================================
// RENDER: BUILD DETAILS SLIDEOUT
// ============================================================================

function renderBuildDetails(data, dateStr) {
    var build = data.build;
    var steps = data.steps;
    document.getElementById('slideout-title').textContent = 'Build: ' + build.build_date;

    var html = '<div class="detail-section"><h3>Summary</h3><div class="detail-grid">';
    html += '<div class="detail-item"><span class="label">Status</span><span class="value ' + getStatusClass(build.status) + '">' + build.status + '</span></div>';
    html += '<div class="detail-item"><span class="label">Start</span><span class="value">' + (build.start_dttm || 'N/A') + '</span></div>';
    html += '<div class="detail-item"><span class="label">End</span><span class="value">' + (build.end_dttm || 'N/A') + '</span></div>';
    html += '<div class="detail-item"><span class="label">Duration</span><span class="value">' + (build.total_duration_formatted || 'N/A') + '</span></div>';
    html += '<div class="detail-item"><span class="label">Steps</span><span class="value">' + build.step_count + '</span></div>';
    if (build.failed_step_name) html += '<div class="detail-item full-width"><span class="label">Failed Step</span><span class="value error">' + escapeHtml(build.failed_step_name) + '</span></div>';
    html += '</div></div>';

    html += '<div class="detail-section"><h3>Step Details</h3><table class="step-table"><thead><tr><th>#</th><th>Name</th><th>Status</th><th>Duration</th></tr></thead><tbody>';
    steps.forEach(function(step) {
        var badgeClass = step.run_status === 1 ? 'success' : 'failed';
        var badgeLabel = step.run_status === 1 ? 'COMPLETED' : 'FAILED';
        html += '<tr><td>' + step.step_id + '</td><td>' + escapeHtml(step.step_name) + '</td><td class="status-cell"><span class="step-status-badge ' + badgeClass + '">' + badgeLabel + '</span></td><td>' + step.duration_formatted + '</td></tr>';
    });
    html += '</tbody></table></div>';

    document.getElementById('slideout-body').innerHTML = html;
    openSlideout();
}

function renderBuildsForDate(data, dateStr) {
    document.getElementById('slideout-title').textContent = 'Builds: ' + dateStr;

    var html = '';

    data.builds.forEach(function(buildData, idx) {
        var build = buildData.build;
        var steps = buildData.steps;

        if (idx > 0) {
            html += '<div class="build-separator"></div>';
        }

        if (data.builds.length > 1) {
            html += '<div class="build-attempt-header">Attempt #' + (data.builds.length - idx) + (build.status === 'COMPLETED' ? ' (Final)' : ' (Failed)') + '</div>';
        }

        html += '<div class="detail-section"><h3>Summary</h3><div class="detail-grid">';
        html += '<div class="detail-item"><span class="label">Status</span><span class="value ' + getStatusClass(build.status) + '">' + build.status + '</span></div>';
        html += '<div class="detail-item"><span class="label">Start</span><span class="value">' + (build.start_dttm || 'N/A') + '</span></div>';
        html += '<div class="detail-item"><span class="label">End</span><span class="value">' + (build.end_dttm || 'N/A') + '</span></div>';
        html += '<div class="detail-item"><span class="label">Duration</span><span class="value">' + (build.total_duration_formatted || 'N/A') + '</span></div>';
        html += '<div class="detail-item"><span class="label">Steps</span><span class="value">' + build.step_count + '</span></div>';
        if (build.failed_step_name) html += '<div class="detail-item full-width"><span class="label">Failed Step</span><span class="value error">' + escapeHtml(build.failed_step_name) + '</span></div>';
        html += '</div></div>';

        html += '<div class="detail-section"><h3>Step Details</h3><table class="step-table"><thead><tr><th>#</th><th>Name</th><th>Status</th><th>Duration</th></tr></thead><tbody>';
        steps.forEach(function(step) {
            var badgeClass = step.run_status === 1 ? 'success' : 'failed';
            var badgeLabel = step.run_status === 1 ? 'COMPLETED' : 'FAILED';
            html += '<tr><td>' + step.step_id + '</td><td>' + escapeHtml(step.step_name) + '</td><td class="status-cell"><span class="step-status-badge ' + badgeClass + '">' + badgeLabel + '</span></td><td>' + step.duration_formatted + '</td></tr>';
        });
        html += '</tbody></table></div>';
    });

    document.getElementById('slideout-body').innerHTML = html;
    openSlideout();
}


// ============================================================================
// DATE RANGE MODAL
// ----------------------------------------------------------------------------
// Uses shared .xf-modal-overlay.hidden static-toggle pattern.
// ============================================================================

function openDateRangeModal() {
    var today = new Date();
    var monthAgo = new Date(today.getTime() - (30 * 24 * 60 * 60 * 1000));
    document.getElementById('date-from').value = formatDateForInput(monthAgo);
    document.getElementById('date-to').value = formatDateForInput(today);
    document.getElementById('date-modal-overlay').classList.remove('hidden');
}

function closeDateRangeModal() {
    document.getElementById('date-modal-overlay').classList.add('hidden');
}

function applyCustomDateRange() {
    var fromDate = document.getElementById('date-from').value;
    var toDate = document.getElementById('date-to').value;
    if (!fromDate || !toDate) {
        showAlert('Please select both dates', { title: 'Date Range', icon: '&#9888;', iconColor: '#dcdcaa' });
        return;
    }
    if (fromDate > toDate) {
        showAlert('From date must be before To date', { title: 'Date Range', icon: '&#9888;', iconColor: '#dcdcaa' });
        return;
    }
    document.querySelectorAll('.trend-btn').forEach(function(b) { b.classList.remove('active'); });
    document.querySelector('.trend-btn[data-days="custom"]').classList.add('active');
    customDateRange = { from: fromDate, to: toDate };
    loadDurationTrend('custom', fromDate, toDate);
    closeDateRangeModal();
}

function formatDateForInput(date) {
    return date.getFullYear() + '-' + String(date.getMonth() + 1).padStart(2, '0') + '-' + String(date.getDate()).padStart(2, '0');
}


// ============================================================================
// CHART INTERACTION
// ============================================================================

function openBuildByDate(dateStr) {
    loadBuildsForDate(dateStr);
}

function highlightTrendBar(dateStr) {
    document.querySelectorAll('.trend-bar-container.highlighted').forEach(function(el) { el.classList.remove('highlighted'); });
    var bar = document.querySelector('.trend-bar-container[data-date="' + dateStr + '"]');
    if (bar) {
        bar.classList.add('highlighted');
        bar.scrollIntoView({ behavior: 'smooth', block: 'nearest', inline: 'center' });
    }
}


// ============================================================================
// TREE TOGGLE (Year and Month)
// ============================================================================

function toggleYear(header) {
    var yearDiv = header.parentElement;
    var content = header.nextElementSibling;
    var icon = header.querySelector('.expand-icon');
    var isOpening = content.style.display === 'none';

    if (isOpening) {
        document.querySelectorAll('.history-year').forEach(function(otherYear) {
            if (otherYear !== yearDiv) {
                otherYear.querySelector('.year-content').style.display = 'none';
                otherYear.querySelector('.year-header .expand-icon').textContent = '\u25B6';
                otherYear.querySelectorAll('.month-details').forEach(function(md) { md.style.display = 'none'; });
                otherYear.querySelectorAll('.month-row .expand-icon').forEach(function(mi) { mi.textContent = '\u25B6'; });
            }
        });
        content.querySelectorAll('.month-details').forEach(function(md) { md.style.display = 'none'; });
        content.querySelectorAll('.month-row .expand-icon').forEach(function(mi) { mi.textContent = '\u25B6'; });
    }

    content.style.display = isOpening ? 'block' : 'none';
    icon.textContent = isOpening ? '\u25BC' : '\u25B6';
}

function toggleMonthGroup(row) {
    var tbody = row.closest('tbody.month-group');
    var detailsRow = tbody.querySelector('.month-details');
    var icon = row.querySelector('.expand-icon');
    var isOpen = detailsRow.style.display !== 'none';

    detailsRow.style.display = isOpen ? 'none' : 'table-row';
    icon.textContent = isOpen ? '\u25B6' : '\u25BC';
}


// ============================================================================
// SLIDEOUT
// ----------------------------------------------------------------------------
// Uses shared .slide-panel-* infrastructure. The shared system uses .open
// class on both the panel and the overlay for the visible state.
// ============================================================================

function openSlideout() {
    document.getElementById('build-slideout').classList.add('open');
    document.getElementById('build-slideout-overlay').classList.add('open');
}

function closeSlideout() {
    document.getElementById('build-slideout').classList.remove('open');
    document.getElementById('build-slideout-overlay').classList.remove('open');
    document.querySelectorAll('.trend-bar-container.highlighted').forEach(function(el) { el.classList.remove('highlighted'); });
}


// ============================================================================
// PAGE-SPECIFIC UTILITIES
// ----------------------------------------------------------------------------
// Cross-page utilities (escapeHtml, formatTimeOfDay, MONTH_NAMES) are
// provided by engine-events.js. The functions below are BIDATA-specific.
// ============================================================================

function getStatusClass(status) {
    switch (status) {
        case 'COMPLETED':   return 'status-completed';
        case 'FAILED':      return 'status-failed';
        case 'IN_PROGRESS': return 'status-in-progress';
        default:            return '';
    }
}

function formatDate(dateStr) {
    if (!dateStr) return 'N/A';
    var dt = new Date(dateStr + 'T00:00:00');
    return dt.toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' });
}

function formatDuration(seconds) {
    if (seconds === null || seconds === undefined) return '-';
    var h = Math.floor(seconds / 3600);
    var m = Math.floor((seconds % 3600) / 60);
    var s = Math.floor(seconds % 60);
    return h + ':' + String(m).padStart(2, '0') + ':' + String(s).padStart(2, '0');
}

function calculateElapsed(startTimeStr) {
    if (!startTimeStr) return 0;
    return Math.floor((new Date() - new Date(startTimeStr)) / 1000);
}

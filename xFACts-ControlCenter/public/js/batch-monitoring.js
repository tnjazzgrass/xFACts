/* ============================================================================
   xFACts Control Center - Batch Monitoring JavaScript
   Location: E:\xFACts-ControlCenter\public\js\batch-monitoring.js
   Version: Tracked in dbo.System_Metadata (component: BatchOps)
   ============================================================================ */

// ============================================================================
// CONFIGURATION
// ============================================================================

// Engine events — process map for shared WebSocket module (engine-events.js)
var ENGINE_PROCESSES = {
    'Collect-NBBatchStatus':  { slug: 'nb'},
    'Collect-PMTBatchStatus': { slug: 'pmt'},
    'Collect-BDLBatchStatus': { slug: 'bdl'},
    'Send-OpenBatchSummary':  { slug: 'summary'}
};

// Live polling (Refresh Architecture)
var PAGE_REFRESH_INTERVAL = 30;   // Default; overridden by GlobalConfig on load

// Page hooks for engine-events.js shared module
function onPageResumed() { pageRefresh(); }
function onSessionExpired() { stopPolling(); }
var livePollingTimer = null;
var pageLoadDate = new Date().toDateString();

var currentActiveFilter = 'ALL';
var monthNames = ['', 'January', 'February', 'March', 'April', 'May', 'June',
                  'July', 'August', 'September', 'October', 'November', 'December'];
var dayNames = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

// Friendly status display maps (DM reference table values → readable text)
var nbStatusMap = {
    'EMPTY': 'Empty', 'UPLOADING': 'Uploading', 'UPLOADFAILED': 'Upload Failed',
    'UPLOADED': 'Uploaded', 'DELETED': 'Deleted', 'RELEASENEEDED': 'Release Needed',
    'RELEASING': 'Releasing', 'RELEASED': 'Released', 'RELEASEFAILED': 'Release Failed',
    'ACTIVE': 'Active', 'PARTIALRELEASED': 'Partial Released',
    'UPLOAD_WRAP_UP': 'Upload Wrap Up', 'FAILED': 'Failed',
    'GENERATING': 'Generating', 'GENERATED': 'Generated'
};
var nbMergeStatusMap = {
    'NONE': 'None', 'POST_RELEASE_MERGING': 'Merging',
    'POST_RELEASE_MERGE_COMPLETE': 'Merge Complete',
    'POST_RELEASE_LINKING': 'Linking', 'POST_RELEASE_LINK_COMPLETE': 'Link Complete',
    'POST_RELEASE_PRTL_MRGD_WTH_ERS': 'Partial w/ Errors',
    'POST_RELEASE_MERGING_WITH_ERRORS': 'Merging w/ Errors',
    'POST_RELEASE_MERGE_CMPLT_WTH_ERS': 'Complete w/ Errors',
    'POST_RELEASE_PARTIAL_LINKED': 'Partial Linked',
    'POST_RELEASE_PARTIAL_MERGED': 'Partial Merged'
};
var pmtStatusMap = {
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

function friendlyStatus(raw, map) {
    if (!raw) return 'Unknown';
    var key = raw.toUpperCase().trim();
    return map[key] || raw;
}

function nbStatusBadgeClass(batchCode, mergeCode) {
    // Failures
    if (batchCode === 3 || batchCode === 9 || batchCode === 13) return 'failed';
    // In-flight (blue)
    if (batchCode === 2 || batchCode === 7 || batchCode === 12) return 'active';
    // Generating (blue)
    if (batchCode === 14 || batchCode === 15) return 'active';
    // Waiting/staged (yellow)
    if (batchCode === 4 || batchCode === 6 || batchCode === 11) return 'waiting';
    // Released - completed status phase (green)
    if (batchCode === 8 || batchCode === 10) return 'processing';
    return 'info';
}

function pmtStatusBadgeClass(batchCode) {
    // Failures
    if (batchCode === 6 || batchCode === 11 || batchCode === 14 || batchCode === 20 || batchCode === 27) return 'failed';
    // Warnings (partial, suspense)
    if (batchCode === 5 || batchCode === 30) return 'failed';
    // In-flight (blue)
    if (batchCode === 3 || batchCode === 10 || batchCode === 13 || batchCode === 19 || batchCode === 22 || batchCode === 26) return 'active';
    // Waiting (yellow)
    if (batchCode === 2 || batchCode === 8 || batchCode === 9 || batchCode === 12 || batchCode === 15 || batchCode === 18 || batchCode === 21 || batchCode === 25) return 'waiting';
    // Wrap-up and delete
    if (batchCode === 16 || batchCode === 17 || batchCode === 23 || batchCode === 24 || batchCode === 28) return 'info';
    return 'info';
}

var bdlStatusMap = {
    'PROCESSING': 'Processing', 'STAGED': 'Staged', 'IMPORTED': 'Imported',
    'STAGEFAILED': 'Stage Failed', 'IMPORT_FAILED': 'Import Failed',
    'DELETING': 'Deleting', 'DELETED': 'Deleted'
};

function bdlStatusBadgeClass(statusCode) {
    // BDL status codes: PROCESSING (2), STAGED (10), STAGEFAILED (8), IMPORT_FAILED (11), IMPORTED (12)
    if (statusCode === 8 || statusCode === 11) return 'failed';
    if (statusCode === 2) return 'active';
    if (statusCode === 10) return 'waiting';
    if (statusCode === 12) return 'processing';
    return 'info';
}

// State
var currentHistoryFilter = 'ALL';
var currentHistoryData = null;
var expandedYears = {};
var expandedMonths = {};

// ============================================================================
// Initialization
// ============================================================================
// ============================================================================
// Initialization
// ============================================================================
document.addEventListener('DOMContentLoaded', async function() {
    await loadRefreshInterval();
    refreshAll();
    connectEngineEvents();
    initEngineCardClicks();
    startLivePolling();
    startAutoRefresh();
    
    // History filter buttons
    document.querySelectorAll('.filter-btn').forEach(function(btn) {
        btn.addEventListener('click', function() {
            document.querySelectorAll('.filter-btn').forEach(function(b) { b.classList.remove('active'); });
            this.classList.add('active');
            currentHistoryFilter = this.getAttribute('data-filter');
            // Reset all expanded state when switching filters
            expandedYears = {};
            expandedMonths = {};
            loadBatchHistory();
        });
    });
    
    // Active batches filter buttons
    document.querySelectorAll('.active-filter-btn').forEach(function(btn) {
        btn.addEventListener('click', function() {
            document.querySelectorAll('.active-filter-btn').forEach(function(b) { b.classList.remove('active'); });
            this.classList.add('active');
            currentActiveFilter = this.getAttribute('data-filter');
            renderActiveBatches(lastActiveBatchData);
        });
    });
});

// ============================================================================
// REFRESH ARCHITECTURE
// ============================================================================
// Live sections: Active Batches (direct DM production query)
// Event-driven sections: Today's Activity, Process Status, Batch History
// See: Refresh Architecture doc, Section 6.5
// ============================================================================

async function loadRefreshInterval() {
    try {
        var data = await engineFetch('/api/config/refresh-interval?page=batch');
        if (data) {
            // engineFetch handles auth and returns parsed JSON
            PAGE_REFRESH_INTERVAL = data.interval || 30;
        }
    } catch (e) {
        // API unavailable — use default
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

// ── Live sections: refresh on GlobalConfig timer ──
function refreshLiveSections() {
    loadActiveBatches();
    updateTimestamp();
}

// ── Event-driven sections: refresh on orchestrator PROCESS_COMPLETED ──
function refreshEventSections() {
    loadProcessStatus();
    loadDailySummary();
    loadBatchHistory();
    updateTimestamp();
}

// ── Manual refresh: everything ──
function refreshAll() {
    loadProcessStatus();
    loadDailySummary();
    loadActiveBatches();
    loadBatchHistory();
    updateTimestamp();
}

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

function updateTimestamp() {
    document.getElementById('last-update').textContent = new Date().toLocaleTimeString();
}

// Called by engine-events.js when a relevant PROCESS_COMPLETED event arrives
function onEngineProcessCompleted(processName, event) {
    refreshEventSections();
}

// ============================================================================
// LEGACY ENGINE STATUS — REMOVED
// ============================================================================
// Engine indicator cards (NB, PMT, Summary) are now driven by the shared
// engine-events.js WebSocket module. The following functions were removed:
//   - loadEngineStatus()       — polled /api/batch-monitoring/engine-status every 5s
//   - startEngineTicker()      — 1-second countdown ticker
//   - tickEngineIndicator()    — per-card state/countdown renderer
//   - fmtEngineCountdown()     — countdown time formatter
// See: RealTime_Engine_Events_Architecture.md
// ============================================================================

// ============================================================================
// API Calls
// ============================================================================
function loadProcessStatus() {
    engineFetch('/api/batch-monitoring/process-status')
        .then(function(data) {
            if (!data) return;
            if (data.error) { showError('Process status: ' + data.error); return; }
            clearError();
            renderProcessStatus(data.processes || []);
        })
        .catch(function(err) { showError('Failed to load process status: ' + err.message); });
}

function loadDailySummary() {
    engineFetch('/api/batch-monitoring/daily-summary')
        .then(function(data) {
            if (!data) return;
            if (data.error) { showError('Daily summary: ' + data.error); return; }
            clearError();
            renderDailySummary(data);
            updateTimestamp();
        })
        .catch(function(err) { showError('Failed to load daily summary: ' + err.message); });
}

var lastActiveBatchData = null;

function loadActiveBatches() {
    engineFetch('/api/batch-monitoring/active-batches')
        .then(function(data) {
            if (!data) return;
            if (data.error) { showError('Active batches: ' + data.error); return; }
            clearError();
            lastActiveBatchData = data;
            renderActiveBatches(data);
            updateTimestamp();
        })
        .catch(function(err) { showError('Failed to load active batches: ' + err.message); });
}

function loadBatchHistory() {
    engineFetch('/api/batch-monitoring/history?type=' + currentHistoryFilter)
        .then(function(data) {
            if (!data) return;
            if (data.error) { showError('Batch history: ' + data.error); return; }
            clearError();
            currentHistoryData = data.data || [];
            renderBatchHistory(currentHistoryData);
        })
        .catch(function(err) { showError('Failed to load batch history: ' + err.message); });
}

function loadMonthDetail(year, month) {
    var key = year + '-' + month;
    var container = document.getElementById('month-detail-' + key);
    if (!container) return;
    
    container.innerHTML = '<div class="loading">Loading...</div>';
    
    engineFetch('/api/batch-monitoring/history-month?year=' + year + '&month=' + month + '&type=' + currentHistoryFilter)
        .then(function(data) {
            if (!data) return;
            if (data.error) { container.innerHTML = '<div class="no-activity">Error: ' + data.error + '</div>'; return; }
            renderMonthDetail(container, data.data || [], year, month);
        })
        .catch(function(err) {
            container.innerHTML = '<div class="no-activity">Failed to load: ' + err.message + '</div>';
        });
}

function loadDayDetail(date) {
    document.getElementById('slideout-title').textContent = 'Batches: ' + formatDisplayDate(date);
    document.getElementById('slideout-body').innerHTML = '<div class="loading">Loading...</div>';
    openSlideout();
    
    // Always fetch ALL types — tab filtering is handled client-side in the slideout
    engineFetch('/api/batch-monitoring/history-day?date=' + date + '&type=ALL')
        .then(function(data) {
            if (!data) return;
            if (data.error) {
                document.getElementById('slideout-body').innerHTML = '<div class="no-activity">Error: ' + data.error + '</div>';
                return;
            }
            renderDayDetail(data.data || []);
        })
        .catch(function(err) {
            document.getElementById('slideout-body').innerHTML = '<div class="no-activity">Failed to load: ' + err.message + '</div>';
        });
}

// ============================================================================
// Render: Process Status
// ============================================================================
function renderProcessStatus(processes) {
    var container = document.getElementById('process-status');
    
    if (!processes || processes.length === 0) {
        container.innerHTML = '<div class="no-activity">No processes registered</div>';
        return;
    }
    
    var html = '';
    processes.forEach(function(p) {
        var secSince = safeInt(p.seconds_since_run);
        var health = p.health_status || 'healthy';
        
        // Card frame color only on non-healthy
        var cardClass = (health !== 'healthy') ? ' ' + health : '';
        
        // Badge reflects health status
        var badgeLabel = 'OK';
        var badgeClass = 'success';
        if (health === 'running') { badgeLabel = 'Running'; badgeClass = 'active'; }
        else if (health === 'critical') { badgeLabel = p.last_status === 'FAILED' ? 'Failed' : 'Stale'; badgeClass = 'failed'; }
        else if (health === 'warning') { badgeLabel = 'Delayed'; badgeClass = 'warning'; }
        
        html += '<div class="process-card' + cardClass + '">';
        html += '<div class="process-status-badge ' + badgeClass + '">' + badgeLabel + '</div>';
        html += '<div class="process-info">';
        html += '<div class="process-name">' + escapeHtml(p.collector_name) + '</div>';
        html += '</div>';
        html += '<div class="process-timing">';
        if (p.completed_dttm) {
            html += '<div class="timing-value">' + formatTimeSince(secSince) + ' ago</div>';
            html += '<div>' + (safeInt(p.last_duration_ms) > 0 ? (safeInt(p.last_duration_ms) / 1000).toFixed(1) + 's' : '') + '</div>';
        } else {
            html += '<div>Never run</div>';
        }
        html += '</div>';
        html += '</div>';
    });
    
    container.innerHTML = html;
}

// ============================================================================
// Render: Daily Summary
// ============================================================================
function renderDailySummary(data) {
    var container = document.getElementById('daily-summary');
    var nb = data.nb || {};
    var pmt = data.pmt || {};
    var bdl = data.bdl || {};
    
    var nbTotal = safeInt(nb.total);
    var pmtTotal = safeInt(pmt.total);
    var bdlTotal = safeInt(bdl.total);
    
    var html = '';
    
    // NB Card
    html += '<div class="summary-card nb-card">';
    html += '<div class="card-label">New Business</div>';
    html += '<div class="card-value">' + nbTotal + '</div>';
    html += '<div class="card-detail">';
    if (nbTotal > 0) {
        html += '<span class="success">' + safeInt(nb.completed) + ' complete</span>';
        if (safeInt(nb.failed) > 0) html += '<span class="failed">' + safeInt(nb.failed) + ' failed</span>';
        if (safeInt(nb.in_flight) > 0) html += '<span class="active">' + safeInt(nb.in_flight) + ' active</span>';
        if (safeInt(nb.total_accounts) > 0) html += '<span>' + safeInt(nb.total_accounts).toLocaleString() + ' accounts</span>';
    } else {
        html += '<span>No batches today</span>';
    }
    html += '</div></div>';
    
    // PMT Card
    html += '<div class="summary-card pmt-card">';
    html += '<div class="card-label">Payments</div>';
    html += '<div class="card-value">' + pmtTotal + '</div>';
    html += '<div class="card-detail">';
    if (pmtTotal > 0) {
        html += '<span class="success">' + safeInt(pmt.completed) + ' complete</span>';
        if (safeInt(pmt.failed) > 0) html += '<span class="failed">' + safeInt(pmt.failed) + ' failed</span>';
        if (safeInt(pmt.in_flight) > 0) html += '<span class="active">' + safeInt(pmt.in_flight) + ' active</span>';
        if (safeInt(pmt.total_payments) > 0) html += '<span>' + safeInt(pmt.total_payments).toLocaleString() + ' payments</span>';
    } else {
        html += '<span>No batches today</span>';
    }
    // Muted footnote for excluded companion batch types
    var reapplyCount = safeInt(pmt.reapply_count);
    var otherCount = safeInt(pmt.other_count);
    if (reapplyCount > 0 || otherCount > 0) {
        var footnotes = [];
        if (reapplyCount > 0) footnotes.push(reapplyCount + ' reapply');
        if (otherCount > 0) footnotes.push(otherCount + ' other');
        html += '<span class="card-footnote">' + footnotes.join(' &middot; ') + '</span>';
    }
    html += '</div></div>';
    
    // BDL Card
    html += '<div class="summary-card bdl-card">';
    html += '<div class="card-label">BDL Import</div>';
    html += '<div class="card-value">' + bdlTotal + '</div>';
    html += '<div class="card-detail">';
    if (bdlTotal > 0) {
        html += '<span class="success">' + safeInt(bdl.completed) + ' complete</span>';
        if (safeInt(bdl.failed) > 0) html += '<span class="failed">' + safeInt(bdl.failed) + ' failed</span>';
        if (safeInt(bdl.in_flight) > 0) html += '<span class="active">' + safeInt(bdl.in_flight) + ' active</span>';
        if (safeInt(bdl.total_records) > 0) html += '<span>' + safeInt(bdl.total_records).toLocaleString() + ' records</span>';
    } else {
        html += '<span>No files today</span>';
    }
    html += '</div></div>';
    
    container.innerHTML = html;
}

// ============================================================================
// Render: Active Batches (Filtered View)
// ============================================================================
function renderActiveBatches(data) {
    var container = document.getElementById('active-batches');
    if (!data) { container.innerHTML = '<div class="no-activity">Loading...</div>'; return; }
    
    var nbList = data.nb || [];
    var pmtList = data.pmt || [];
    var bdlList = data.bdl || [];
    
    // Apply client-side filter
    var showNB = (currentActiveFilter === 'ALL' || currentActiveFilter === 'NB');
    var showPMT = (currentActiveFilter === 'ALL' || currentActiveFilter === 'PMT');
    var showBDL = (currentActiveFilter === 'ALL' || currentActiveFilter === 'BDL');
    var filteredNB = showNB ? nbList : [];
    var filteredPMT = showPMT ? pmtList : [];
    var filteredBDL = showBDL ? bdlList : [];
    
    if (filteredNB.length === 0 && filteredPMT.length === 0 && filteredBDL.length === 0) {
        var msg = currentActiveFilter === 'ALL' ? 'No batches currently in flight' : 'No ' + currentActiveFilter + ' batches currently in flight';
        container.innerHTML = '<div class="no-activity">' + msg + '</div>';
        return;
    }
    
    var html = '<table class="active-batch-table">';
    html += '<thead><tr>';
    html += '<th>Type</th><th>Batch ID</th><th>Name</th><th>Status</th><th>Progress</th><th style="text-align:right">Count</th><th style="text-align:right">Time</th>';
    html += '</tr></thead><tbody>';
    
    // NB batches
    filteredNB.forEach(function(b) {
        var statusDisplay = friendlyStatus(b.merge_status || b.batch_status, nbStatusMap);
        if (b.merge_status) statusDisplay = friendlyStatus(b.merge_status, nbMergeStatusMap);
        var ageDisplay = formatAge(safeInt(b.age_minutes));
        var mergeCode = safeInt(b.merge_status_code);
        var batchCode = safeInt(b.batch_status_code);
        var consumerCount = safeInt(b.consumer_count);
        var countDisplay = consumerCount > 0 ? consumerCount.toLocaleString() : '-';
        
        // Activity indicator based on pipeline position
        // Blue (in-flight) statuses: progress column is empty — status badge tells the story
        var activityHtml = '';
        var isInFlight = (batchCode === 2 || batchCode === 7 || batchCode === 12 || batchCode === 14 || batchCode === 15);
        
        if (isInFlight) {
            activityHtml = '';
        } else if (batchCode === 3 || batchCode === 13) {
            // UPLOADFAILED or FAILED
            activityHtml = '<span class="activity-label failed">Failed</span>';
        } else if (batchCode === 9) {
            // RELEASEFAILED
            activityHtml = '<span class="activity-label failed">Release Failed</span>';
        } else if (mergeCode === 2 || mergeCode === 7) {
            // Merging — show progress meter if consumer counts available
            var mergeProcessed = safeInt(b.merge_processed_count);
            
            if (consumerCount > 0 && mergeProcessed > 0) {
                var pct = Math.min(100, Math.round((mergeProcessed / consumerCount) * 100));
                activityHtml = '<div class="progress-bar-container">';
                activityHtml += '<div class="progress-bar" style="width:' + pct + '%"></div>';
                activityHtml += '<span class="progress-text">' + mergeProcessed.toLocaleString() + '/' + consumerCount.toLocaleString() + ' (' + pct + '%)</span>';
                activityHtml += '</div>';
            } else {
                activityHtml = '<span class="activity-label processing">Merging</span>';
            }
        } else if (batchCode === 8 && mergeCode <= 1) {
            activityHtml = '<span class="activity-label waiting">In Queue</span>';
        } else if (batchCode === 4 || batchCode === 6) {
            activityHtml = '<span class="activity-label waiting">Awaiting Release</span>';
        } else {
            activityHtml = '<span class="activity-label info">' + escapeHtml(statusDisplay) + '</span>';
        }
        
        html += '<tr>';
        html += '<td><span class="batch-type-tag nb">NB</span></td>';
        html += '<td>' + b.batch_id + '</td>';
        html += '<td class="batch-name-cell">' + escapeHtml(b.batch_name) + '</td>';
        html += '<td class="status-cell"><span class="status-badge ' + nbStatusBadgeClass(batchCode, mergeCode) + '">' + escapeHtml(statusDisplay) + '</span></td>';
        html += '<td class="activity-cell">' + activityHtml + '</td>';
        html += '<td class="count-cell">' + countDisplay + '</td>';
        html += '<td class="age-cell">' + ageDisplay + '</td>';
        html += '</tr>';
    });
    
    // PMT batches - all non-terminal statuses except ACTIVE
    filteredPMT.forEach(function(b) {
        var statusDisplay = friendlyStatus(b.batch_status, pmtStatusMap);
        var ageDisplay = formatAge(safeInt(b.age_minutes));
        var pmtType = b.pmt_batch_type || '';
        var batchCode = safeInt(b.batch_status_code);
        var activeCount = safeInt(b.active_count);
        var countDisplay = activeCount > 0 ? activeCount.toLocaleString() : '-';
        
        var activityHtml = '';
        
        // Blue (in-flight) statuses except INPROCESS: progress column is empty
        var isPmtInFlight = (batchCode === 10 || batchCode === 13 || batchCode === 19 || batchCode === 22 || batchCode === 26);
        
        if (isPmtInFlight) {
            activityHtml = '';
        } else if (batchCode === 6 || batchCode === 11 || batchCode === 27) {
            // FAILED, IMPORTFAILED, REVERSALFAILED
            activityHtml = '<span class="activity-label failed">Failed</span>';
        } else if (batchCode === 5) {
            // PARTIAL
            activityHtml = '<span class="activity-label failed">Partial</span>';
        } else if (batchCode === 30) {
            // ACTIVEWITHSUSPENSE
            activityHtml = '<span class="activity-label failed">Suspense</span>';
        } else if (batchCode === 3) {
            // INPROCESS - show journal progress
            var journalPosted = safeInt(b.journal_posted_count);
            
            if (activeCount > 0 && journalPosted > 0) {
                var pct = Math.min(100, Math.round((journalPosted / activeCount) * 100));
                activityHtml = '<div class="progress-bar-container">';
                activityHtml += '<div class="progress-bar" style="width:' + pct + '%"></div>';
                activityHtml += '<span class="progress-text">' + journalPosted.toLocaleString() + '/' + activeCount.toLocaleString() + ' (' + pct + '%)</span>';
                activityHtml += '</div>';
            } else if (activeCount > 0) {
                activityHtml = '<span class="activity-label waiting">Posting</span>';
            } else {
                activityHtml = '<span class="activity-label waiting">Awaiting Posting</span>';
            }
        } else if (batchCode === 2) {
            // RELEASED
            activityHtml = '<span class="activity-label waiting">Released</span>';
        } else if (batchCode === 23) {
            // IMPORTWRAPUP
            activityHtml = '<span class="activity-label info">Import Wrap Up</span>';
        } else if (batchCode === 24) {
            // POSTWRAPUP
            activityHtml = '<span class="activity-label info">Post Wrap Up</span>';
        } else if (batchCode === 25) {
            // PENDINGREVERSAL
            activityHtml = '<span class="activity-label waiting">Reversal Pending</span>';
        } else if (batchCode === 28) {
            // REVERSALWRAPUP
            activityHtml = '<span class="activity-label info">Reversal Wrap Up</span>';
        } else if (batchCode === 16 || batchCode === 17) {
            // DELETEREQUESTED, DELETING
            activityHtml = '<span class="activity-label info">Deleting</span>';
        } else if (batchCode === 8 || batchCode === 9 || batchCode === 15 || batchCode === 18) {
            // NEWIMPORT, WAITINGFORIMPORT, WAITINGFORCONVERSION, WAITINGFORVIRTUAL
            activityHtml = '<span class="activity-label waiting">' + escapeHtml(pmtType || statusDisplay) + '</span>';
        } else {
            activityHtml = '<span class="activity-label info">' + escapeHtml(pmtType || statusDisplay) + '</span>';
        }
        
        html += '<tr>';
        html += '<td><span class="batch-type-tag pmt">PMT</span></td>';
        html += '<td>' + b.batch_id + '</td>';
        html += '<td class="batch-name-cell">' + escapeHtml(b.batch_name || b.external_name || 'Batch ' + b.batch_id) + '</td>';
        html += '<td class="status-cell"><span class="status-badge ' + pmtStatusBadgeClass(batchCode) + '">' + escapeHtml(statusDisplay) + '</span></td>';
        html += '<td class="activity-cell">' + activityHtml + '</td>';
        html += '<td class="count-cell">' + countDisplay + '</td>';
        html += '<td class="age-cell">' + ageDisplay + '</td>';
        html += '</tr>';
    });
    
    // BDL files
    filteredBDL.forEach(function(b) {
        var statusDisplay = friendlyStatus(b.batch_status, bdlStatusMap);
        var ageDisplay = formatAge(safeInt(b.age_minutes));
        var statusCode = safeInt(b.file_status_code);
        var totalRecords = safeInt(b.total_record_count);
        var countDisplay = totalRecords > 0 ? totalRecords.toLocaleString() : '-';
        
        var activityHtml = '';
        
        if (statusCode === 8) {
            // STAGEFAILED
            activityHtml = '<span class="activity-label failed">Stage Failed</span>';
        } else if (statusCode === 11) {
            // IMPORT_FAILED
            activityHtml = '<span class="activity-label failed">Import Failed</span>';
        } else if (statusCode === 2) {
            // PROCESSING — show partition progress if available
            var partCount = safeInt(b.partition_count);
            var partCompleted = safeInt(b.partitions_completed);
            if (partCount > 0 && partCompleted > 0) {
                var pct = Math.min(100, Math.round((partCompleted / partCount) * 100));
                activityHtml = '<div class="progress-bar-container">';
                activityHtml += '<div class="progress-bar" style="width:' + pct + '%"></div>';
                activityHtml += '<span class="progress-text">' + partCompleted + '/' + partCount + ' partitions (' + pct + '%)</span>';
                activityHtml += '</div>';
            } else {
                activityHtml = '<span class="activity-label processing">Processing</span>';
            }
        } else if (statusCode === 10) {
            // STAGED — waiting for import
            activityHtml = '<span class="activity-label waiting">Awaiting Import</span>';
        } else {
            activityHtml = '<span class="activity-label info">' + escapeHtml(statusDisplay) + '</span>';
        }
        
        var nameDisplay = b.batch_name || 'File ' + b.batch_id;
        var entityType = b.entity_type;
        
        html += '<tr>';
        html += '<td><span class="batch-type-tag bdl">BDL</span></td>';
        html += '<td>' + b.batch_id + '</td>';
        html += '<td class="batch-name-cell">' + escapeHtml(nameDisplay);
        if (entityType) html += ' <span class="bdl-entity-label">' + escapeHtml(entityType) + '</span>';
        html += '</td>';
        html += '<td class="status-cell"><span class="status-badge ' + bdlStatusBadgeClass(statusCode) + '">' + escapeHtml(statusDisplay) + '</span></td>';
        html += '<td class="activity-cell">' + activityHtml + '</td>';
        html += '<td class="count-cell">' + countDisplay + '</td>';
        html += '<td class="age-cell">' + ageDisplay + '</td>';
        html += '</tr>';
    });
    
    html += '</tbody></table>';
    container.innerHTML = html;
}

// ============================================================================
// Render: Batch History (Year/Month Tree)
// ============================================================================
function renderBatchHistory(data) {
    var container = document.getElementById('batch-history');
    
    if (!data || data.length === 0) {
        container.innerHTML = '<div class="no-activity">No batch history found</div>';
        return;
    }
    
    // Group by year, then month - aggregate across batch types
    var yearMap = {};
    data.forEach(function(row) {
        var y = row.year;
        var m = row.month;
        if (!yearMap[y]) yearMap[y] = { total: 0, completed: 0, failed: 0, in_flight: 0, months: {} };
        if (!yearMap[y].months[m]) yearMap[y].months[m] = { total: 0, completed: 0, failed: 0, in_flight: 0, avg_total_minutes: null, avg_weight: 0, types: [] };
        
        var total = safeInt(row.total_batches);
        var completed = safeInt(row.completed);
        var failed = safeInt(row.failed);
        var inFlight = safeInt(row.in_flight);
        
        yearMap[y].total += total;
        yearMap[y].completed += completed;
        yearMap[y].failed += failed;
        yearMap[y].in_flight += inFlight;
        yearMap[y].months[m].total += total;
        yearMap[y].months[m].completed += completed;
        yearMap[y].months[m].failed += failed;
        yearMap[y].months[m].in_flight += inFlight;
        yearMap[y].months[m].types.push(row);
        
        // Weighted average total minutes (weight by batch count for accurate cross-type averaging)
        if (row.avg_total_minutes != null) {
            var completedCount = completed + failed; // batches that have a duration
            var prevWeight = yearMap[y].months[m].avg_weight;
            var prevAvg = yearMap[y].months[m].avg_total_minutes || 0;
            var newWeight = prevWeight + completedCount;
            if (newWeight > 0) {
                yearMap[y].months[m].avg_total_minutes = Math.round(((prevAvg * prevWeight) + (safeInt(row.avg_total_minutes) * completedCount)) / newWeight);
                yearMap[y].months[m].avg_weight = newWeight;
            }
        }
    });
    
    // Sort years descending
    var sortedYears = Object.keys(yearMap).sort(function(a, b) { return b - a; });
    
    var html = '';
    sortedYears.forEach(function(year, idx) {
        var yd = yearMap[year];
        var isExpanded = expandedYears[year] || false;
        
        html += '<div class="year-group">';
        html += '<div class="year-header" onclick="toggleYear(\'' + year + '\')">';
        html += '<span class="expand-icon ' + (isExpanded ? 'expanded' : '') + '" id="year-icon-' + year + '">&#9654;</span>';
        html += '<span class="year-label">' + year + '</span>';
        if (yd.in_flight > 0) html += '<span class="year-active">' + yd.in_flight + ' active batches</span>';
        html += '<div class="year-stats">';
        html += '<span class="year-stat">' + yd.total + ' batches</span>';
        html += '<span class="year-stat success">' + yd.completed + ' success</span>';
        html += '<span class="year-stat failed">' + (yd.failed > 0 ? yd.failed + ' failed' : '-') + '</span>';
        html += '</div>';
        html += '</div>';
        
        html += '<div class="year-content ' + (isExpanded ? 'expanded' : '') + '" id="year-content-' + year + '">';
        
        // Month table
        var sortedMonths = Object.keys(yd.months).sort(function(a, b) { return b - a; });
        html += '<table class="month-summary-table">';
        html += '<thead><tr><th class="expand-cell"></th><th>Month</th><th>Batches</th><th>Completed</th><th>Failed</th><th>Active</th><th>Avg Duration</th></tr></thead>';
        html += '<tbody>';
        
        sortedMonths.forEach(function(month) {
            var md = yd.months[month];
            var monthKey = year + '-' + month;
            var isMonthExpanded = expandedMonths[monthKey];
            
            html += '<tr class="month-row" onclick="toggleMonth(\'' + year + '\', \'' + month + '\')">';
            html += '<td class="expand-cell"><span class="expand-icon ' + (isMonthExpanded ? 'expanded' : '') + '" id="month-icon-' + monthKey + '">&#9654;</span></td>';
            html += '<td class="month-cell">' + monthNames[parseInt(month)] + '</td>';
            html += '<td>' + md.total + '</td>';
            html += '<td class="success-cell">' + md.completed + '</td>';
            html += '<td class="fail-cell">' + (md.failed > 0 ? md.failed : '-') + '</td>';
            html += '<td class="active-cell">' + (md.in_flight > 0 ? md.in_flight : '-') + '</td>';
            html += '<td class="duration-cell">' + (md.avg_total_minutes != null ? formatDurationMinutes(md.avg_total_minutes) : '-') + '</td>';
            html += '</tr>';
            
            // Month detail container (lazy loaded)
            html += '<tr class="month-details" id="month-row-' + monthKey + '" style="display:' + (isMonthExpanded ? 'table-row' : 'none') + '">';
            html += '<td colspan="7"><div class="month-details-content" id="month-detail-' + monthKey + '">';
            if (isMonthExpanded) html += '<div class="loading">Loading...</div>';
            html += '</div></td></tr>';
        });
        
        html += '</tbody></table>';
        html += '</div></div>';
    });
    
    container.innerHTML = html;
}

// ============================================================================
// Render: Month Day Detail
// ============================================================================
function renderMonthDetail(container, data, year, month) {
    if (!data || data.length === 0) {
        container.innerHTML = '<div class="no-activity">No data for this month</div>';
        return;
    }
    
    // Group by date, aggregate across batch types
    var dayMap = {};
    data.forEach(function(row) {
        var d = parseDateOnly(row.batch_date);
        if (!dayMap[d]) dayMap[d] = { total: 0, completed: 0, failed: 0, in_flight: 0, records: 0, types: [], avg_total_min: null, avg_weight: 0 };
        
        var completed = safeInt(row.completed);
        var failed = safeInt(row.failed);
        
        dayMap[d].total += safeInt(row.total_batches);
        dayMap[d].completed += completed;
        dayMap[d].failed += failed;
        dayMap[d].in_flight += safeInt(row.in_flight);
        dayMap[d].records += safeInt(row.total_records);
        dayMap[d].types.push(row);
        
        // Weighted average
        if (row.avg_total_min != null) {
            var completedCount = completed + failed;
            var prevWeight = dayMap[d].avg_weight;
            var prevAvg = dayMap[d].avg_total_min || 0;
            var newWeight = prevWeight + completedCount;
            if (newWeight > 0) {
                dayMap[d].avg_total_min = Math.round(((prevAvg * prevWeight) + (safeInt(row.avg_total_min) * completedCount)) / newWeight);
                dayMap[d].avg_weight = newWeight;
            }
        }
    });
    
    var sortedDays = Object.keys(dayMap).sort(function(a, b) { return b > a ? 1 : -1; });
    
    var html = '<table class="day-table">';
    html += '<thead><tr><th>Date</th><th>Day</th><th>Batches</th><th>Completed</th><th>Failed</th><th>Active</th><th>Records</th><th>Avg Total</th></tr></thead>';
    html += '<tbody>';
    
    sortedDays.forEach(function(date) {
        var dd = dayMap[date];
        var parts = date.split('-');
        var dateObj = new Date(parseInt(parts[0]), parseInt(parts[1]) - 1, parseInt(parts[2]));
        var dayName = dayNames[dateObj.getDay()];
        var dateDisplay = (dateObj.getMonth() + 1) + '/' + dateObj.getDate();
        
        html += '<tr class="clickable" onclick="loadDayDetail(\'' + date + '\')">';
        html += '<td>' + dateDisplay + '</td>';
        html += '<td>' + dayName + '</td>';
        html += '<td>' + dd.total + '</td>';
        html += '<td class="success-cell">' + dd.completed + '</td>';
        html += '<td class="fail-cell">' + (dd.failed > 0 ? dd.failed : '-') + '</td>';
        html += '<td class="active-cell">' + (dd.in_flight > 0 ? dd.in_flight : '-') + '</td>';
        html += '<td>' + (dd.records > 0 ? dd.records.toLocaleString() : '-') + '</td>';
        html += '<td class="duration-cell">' + (dd.avg_total_min != null ? formatDurationMinutes(dd.avg_total_min) : '-') + '</td>';
        html += '</tr>';
    });
    
    html += '</tbody></table>';
    container.innerHTML = html;
}


// ============================================================================
// Slideout State and Filters
// ============================================================================
var currentSlideoutTab = 'ALL';       // Tab: ALL, NB, PMT
var currentSlideoutPmtFilter = 'ALL'; // PMT sub-type: ALL, IMPORT, MANUAL, REVERSAL, OTHER
var currentSlideoutStatusFilter = 'ALL';
var currentSlideoutBatches = [];

function renderDayDetail(batches) {
    var body = document.getElementById('slideout-body');
    
    if (!batches || batches.length === 0) {
        body.innerHTML = '<div class="no-activity">No batches found for this day</div>';
        return;
    }
    
    currentSlideoutBatches = batches;
    // Initialize tab from the history master filter
    currentSlideoutTab = currentHistoryFilter;
    currentSlideoutPmtFilter = 'ALL';
    currentSlideoutStatusFilter = 'ALL';
    
    renderSlideoutContent();
}

function getBatchOutcome(b) {
    var isNB = (b.batch_type === 'NB');
    var isBDL = (b.batch_type === 'BDL');
    if (!b.is_complete) return 'active';
    var cs = (b.completed_status || '').toUpperCase();
    if (isNB) {
        var nbSuccess = ['POST_RELEASE_MERGE_COMPLETE', 'POST_RELEASE_PRTL_MRGD_WTH_ERS',
                         'POST_RELEASE_MERGE_CMPLT_WTH_ERS', 'POST_RELEASE_PARTIAL_MERGED',
                         'POST_RELEASE_LINK_COMPLETE'];
        return (nbSuccess.indexOf(cs) >= 0) ? 'success' : 'failed';
    } else if (isBDL) {
        return (cs === 'IMPORTED') ? 'success' : 'failed';
    } else {
        return (cs === 'POSTED') ? 'success' : 'failed';
    }
}

function formatTime(val) {
    if (!val) return '-';
    var s = String(val);
    // Handle .NET /Date()/ format
    var match = s.match(/\/Date\((\d+)\)\//);
    var d = match ? new Date(parseInt(match[1])) : new Date(s);
    if (isNaN(d.getTime())) return '-';
    var h = d.getHours();
    var m = String(d.getMinutes()).padStart(2, '0');
    var ampm = h >= 12 ? 'PM' : 'AM';
    h = h % 12 || 12;
    return h + ':' + m + ' ' + ampm;
}

function renderSlideoutContent() {
    var body = document.getElementById('slideout-body');
    var batches = currentSlideoutBatches;
    var hasNB = batches.some(function(b) { return b.batch_type === 'NB'; });
    var hasPmt = batches.some(function(b) { return b.batch_type === 'PMT'; });
    var hasBDL = batches.some(function(b) { return b.batch_type === 'BDL'; });
    
    var html = '';
    
    // ── Tab bar: ALL / NB / PMT / BDL ──
    html += '<div class="slideout-tab-bar">';
    var tabs = ['ALL', 'NB', 'PMT', 'BDL'];
    tabs.forEach(function(t) {
        var activeClass = (currentSlideoutTab === t) ? ' active' : '';
        var label = t === 'ALL' ? 'All' : t;
        // Show batch count on each tab
        var count = 0;
        if (t === 'ALL') count = batches.length;
        else count = batches.filter(function(b) { return b.batch_type === t; }).length;
        var countLabel = count > 0 ? ' <span class="tab-count">' + count + '</span>' : '';
        html += '<button class="slideout-tab' + activeClass + '" onclick="setSlideoutTab(\'' + t + '\')">' + label + countLabel + '</button>';
    });
    html += '</div>';
    
    // ── Filter bar: status + PMT sub-type (when applicable) ──
    html += '<div class="slideout-filter-bar">';
    
    // Status filter buttons
    var statusFilters = ['ALL', 'SUCCESS', 'FAILED', 'ACTIVE'];
    statusFilters.forEach(function(f) {
        var activeClass = (currentSlideoutStatusFilter === f) ? ' active' : '';
        var label = f.charAt(0) + f.slice(1).toLowerCase();
        html += '<button class="slideout-status-btn' + activeClass + '" onclick="setSlideoutStatusFilter(\'' + f + '\')">' + label + '</button>';
    });
    
    // PMT sub-type filter (only when PMT or ALL tab is active AND PMT batches exist)
    if (hasPmt && (currentSlideoutTab === 'PMT' || currentSlideoutTab === 'ALL')) {
        html += '<span class="filter-separator"></span>';
        var pmtFilters = ['ALL', 'IMPORT', 'MANUAL', 'REVERSAL', 'REAPPLY', 'OTHER'];
        pmtFilters.forEach(function(f) {
            var activeClass = (currentSlideoutPmtFilter === f) ? ' active' : '';
            html += '<button class="slideout-filter-btn' + activeClass + '" onclick="setSlideoutPmtFilter(\'' + f + '\')">' + f.charAt(0) + f.slice(1).toLowerCase() + '</button>';
        });
    }
    
    html += '</div>';
    
    // ── Apply tab filter (batch type) ──
    var filtered = batches;
    if (currentSlideoutTab !== 'ALL') {
        filtered = filtered.filter(function(b) { return b.batch_type === currentSlideoutTab; });
    }
    
    // ── Apply PMT sub-type filter ──
    if (currentSlideoutPmtFilter !== 'ALL' && (currentSlideoutTab === 'PMT' || currentSlideoutTab === 'ALL')) {
        filtered = filtered.filter(function(b) {
            if (b.batch_type === 'NB' || b.batch_type === 'BDL') return true; // NB and BDL pass through sub-type filter
            if (currentSlideoutPmtFilter === 'OTHER') {
                var knownTypes = ['IMPORT', 'MANUAL', 'REVERSAL', 'REAPPLY'];
                return knownTypes.indexOf((b.pmt_batch_type || '').toUpperCase()) === -1;
            }
            return (b.pmt_batch_type || '').toUpperCase() === currentSlideoutPmtFilter;
        });
    }
    
    // ── Apply status filter ──
    if (currentSlideoutStatusFilter !== 'ALL') {
        var target = currentSlideoutStatusFilter.toLowerCase();
        filtered = filtered.filter(function(b) {
            return getBatchOutcome(b) === target;
        });
    }
    
    // Summary counts
    var successCount = 0, failedCount = 0, activeCount = 0;
    filtered.forEach(function(b) {
        var outcome = getBatchOutcome(b);
        if (outcome === 'success') successCount++;
        else if (outcome === 'failed') failedCount++;
        else activeCount++;
    });
    
    html += '<div class="slideout-batch-count">';
    html += filtered.length + ' batches';
    if (successCount > 0) html += ' &middot; <span class="count-success">' + successCount + ' success</span>';
    if (failedCount > 0) html += ' &middot; <span class="count-failed">' + failedCount + ' failed</span>';
    if (activeCount > 0) html += ' &middot; <span class="count-active">' + activeCount + ' in progress</span>';
    html += '</div>';
    
    if (filtered.length === 0) {
        html += '<div class="no-activity">No matching batches</div>';
        body.innerHTML = html;
        return;
    }
    
    // Render compact batch rows
    filtered.forEach(function(b, idx) {
        var isNB = (b.batch_type === 'NB');
        var isBDL = (b.batch_type === 'BDL');
        var typeClass = isNB ? 'nb' : (isBDL ? 'bdl' : 'pmt');
        var outcome = getBatchOutcome(b);
        var batchName = '';
        if (isNB) {
            batchName = b.upload_filename || b.batch_name || '';
        } else if (isBDL) {
            batchName = b.batch_name || 'File ' + b.batch_id;
        } else {
            batchName = b.batch_name || b.external_name || 'Batch ' + b.batch_id;
        }
        
        // Status display text and class
        var statusText = '';
        var statusClass = '';
        if (!b.is_complete) {
            statusText = b.batch_status || 'In Progress';
            statusClass = 'active';
        } else {
            statusText = b.completed_status || b.batch_status || '';
            if (outcome === 'success') statusClass = 'success';
            else if (outcome === 'failed') statusClass = 'failed';
            else statusClass = 'neutral';
        }
        
        // Times
        var startTime = formatTime(b.batch_created_dttm);
        var endTime = b.completed_dttm ? formatTime(b.completed_dttm) : '-';
        var totalMin = safeInt(b.total_min);
        var durationText = totalMin > 0 ? formatDurationMinutes(totalMin) : '-';
        
        html += '<div class="batch-row" id="batch-row-' + idx + '">';
        
        // Compact header row
        html += '<div class="batch-row-header" onclick="toggleBatchRow(' + idx + ')">';
        html += '<span class="expand-icon">&#9654;</span>';
        html += '<span class="batch-type-tag ' + typeClass + '">' + b.batch_type + '</span>';
        html += '<span class="batch-row-id">#' + b.batch_id + '</span>';
        html += '<span class="batch-row-name">' + escapeHtml(batchName) + '</span>';
        html += '<span class="batch-row-time">' + startTime + '</span>';
        html += '<span style="color:#555; margin:0 2px;">&#8594;</span>';
        html += '<span class="batch-row-time">' + endTime + '</span>';
        html += '<span class="batch-row-status ' + statusClass + '">' + escapeHtml(statusText) + '</span>';
        html += '</div>';
        
        // Expandable detail section
        html += '<div class="batch-row-detail">';
        
        // Inline metrics
        html += '<div class="detail-metrics">';
        if (isNB) {
            html += metricSpan('Accounts', b.account_count ? safeInt(b.account_count).toLocaleString() : '-');
            html += metricSpan('Consumers', b.consumer_count ? safeInt(b.consumer_count).toLocaleString() : '-');
            html += metricSpan('Balance', b.total_balance_amt ? '$' + safeFloat(b.total_balance_amt).toLocaleString(undefined, {minimumFractionDigits:2, maximumFractionDigits:2}) : '-');
            html += metricSpan('Posted', b.posted_account_count ? safeInt(b.posted_account_count).toLocaleString() : '-');
            html += metricSpan('Duration', durationText);
        } else if (isBDL) {
            html += metricSpan('Entity', b.entity_type || '-');
            html += metricSpan('Records', b.total_record_count ? safeInt(b.total_record_count).toLocaleString() : '-');
            html += metricSpan('Staged', b.staging_success_count ? safeInt(b.staging_success_count).toLocaleString() : '-');
            if (safeInt(b.staging_failed_count) > 0) html += metricSpan('Stage Errors', safeInt(b.staging_failed_count).toLocaleString());
            html += metricSpan('Imported', b.import_success_count ? safeInt(b.import_success_count).toLocaleString() : '-');
            if (safeInt(b.import_failed_count) > 0) html += metricSpan('Import Errors', safeInt(b.import_failed_count).toLocaleString());
            html += metricSpan('Partitions', b.partition_count ? (safeInt(b.partitions_completed) + '/' + safeInt(b.partition_count)) : '-');
            html += metricSpan('Duration', durationText);
            if (b.error_message) html += metricSpan('Error', b.error_message);
        } else {
            html += metricSpan('Type', b.pmt_batch_type || '-');
            html += metricSpan('Payments', b.active_count ? safeInt(b.active_count).toLocaleString() : '-');
            html += metricSpan('Posted', b.journal_posted_count ? safeInt(b.journal_posted_count).toLocaleString() : '-');
            if (safeInt(b.journal_failed_count) > 0) html += metricSpan('Failed', safeInt(b.journal_failed_count).toLocaleString());
            html += metricSpan('Duration', durationText);
        }
        html += '</div>';
        
        // Phase timeline (only if completed with duration data)
        if (totalMin > 0) {
            html += '<div class="phase-timeline">';
            html += '<div class="phase-timeline-header">Phase Durations</div>';
            
            if (isNB) {
                var uploadRelease = safeInt(b.upload_to_release_min);
                var releaseMerge = safeInt(b.release_to_merge_min);
                var mergeDur = safeInt(b.merge_duration_min);
                
                html += phaseRow('Upload &#8594; Release', uploadRelease, totalMin, 'upload');
                html += phaseRow('Queue Wait', releaseMerge, totalMin, 'release');
                html += phaseRow('Merge', mergeDur, totalMin, 'merge');
            } else if (isBDL) {
                var createdToStaged = safeInt(b.created_to_staged_min);
                var stagedToImported = safeInt(b.staged_to_imported_min);
                
                html += phaseRow('Processing &#8594; Staged', createdToStaged, totalMin, 'upload');
                html += phaseRow('Staged &#8594; Imported', stagedToImported, totalMin, 'process');
            } else {
                var createRelease = safeInt(b.created_to_release_min);
                var releaseProcess = safeInt(b.release_to_processed_min);
                
                html += phaseRow('Created &#8594; Released', createRelease, totalMin, 'upload');
                html += phaseRow('Released &#8594; Processed', releaseProcess, totalMin, 'process');
            }
            
            html += phaseRow('Total', totalMin, totalMin, 'merge');
            html += '</div>';
        }
        
        html += '</div>'; // batch-row-detail
        html += '</div>'; // batch-row
    });
    
    body.innerHTML = html;
}

function metricSpan(label, value) {
    return '<span class="detail-metric"><span class="metric-label">' + label + ':</span><span class="metric-value">' + value + '</span></span>';
}

function toggleBatchRow(idx) {
    var row = document.getElementById('batch-row-' + idx);
    if (row) row.classList.toggle('expanded');
}

function setSlideoutTab(tab) {
    currentSlideoutTab = tab;
    currentSlideoutPmtFilter = 'ALL'; // Reset sub-type when switching tabs
    currentSlideoutStatusFilter = 'ALL'; // Reset status when switching tabs
    
    // Propagate tab selection back up to history master filter
    if (tab !== currentHistoryFilter) {
        currentHistoryFilter = tab;
        // Update history filter button highlights
        document.querySelectorAll('.filter-btn').forEach(function(b) {
            b.classList.remove('active');
            if (b.getAttribute('data-filter') === tab) b.classList.add('active');
        });
        // Reload history tree with new filter (preserves expanded state)
        loadBatchHistory();
    }
    
    renderSlideoutContent();
}

function setSlideoutPmtFilter(filter) {
    currentSlideoutPmtFilter = filter;
    renderSlideoutContent();
}

function setSlideoutStatusFilter(filter) {
    currentSlideoutStatusFilter = filter;
    renderSlideoutContent();
}


// ============================================================================
// Tree Toggle Functions
// ============================================================================
function toggleYear(year) {
    var content = document.getElementById('year-content-' + year);
    var icon = document.getElementById('year-icon-' + year);
    
    if (content.classList.contains('expanded')) {
        // Collapse this year and reset its months
        content.classList.remove('expanded');
        icon.classList.remove('expanded');
        expandedYears[year] = false;
        resetMonthsForYear(year);
    } else {
        // Collapse all other years first and reset their months
        Object.keys(expandedYears).forEach(function(otherYear) {
            if (expandedYears[otherYear] && otherYear !== year) {
                var otherContent = document.getElementById('year-content-' + otherYear);
                var otherIcon = document.getElementById('year-icon-' + otherYear);
                if (otherContent) otherContent.classList.remove('expanded');
                if (otherIcon) otherIcon.classList.remove('expanded');
                expandedYears[otherYear] = false;
                resetMonthsForYear(otherYear);
            }
        });
        
        // Expand this year
        content.classList.add('expanded');
        icon.classList.add('expanded');
        expandedYears[year] = true;
    }
}

function resetMonthsForYear(year) {
    // Reset all expanded months for a given year
    Object.keys(expandedMonths).forEach(function(key) {
        if (key.indexOf(year + '-') === 0 && expandedMonths[key]) {
            var row = document.getElementById('month-row-' + key);
            var icon = document.getElementById('month-icon-' + key);
            if (row) row.style.display = 'none';
            if (icon) icon.classList.remove('expanded');
            expandedMonths[key] = false;
        }
    });
}

function toggleMonth(year, month) {
    var key = year + '-' + month;
    var row = document.getElementById('month-row-' + key);
    var icon = document.getElementById('month-icon-' + key);
    
    if (expandedMonths[key]) {
        row.style.display = 'none';
        icon.classList.remove('expanded');
        expandedMonths[key] = false;
    } else {
        row.style.display = 'table-row';
        icon.classList.add('expanded');
        expandedMonths[key] = true;
        loadMonthDetail(year, month);
    }
}

// ============================================================================
// Slideout
// ============================================================================
function openSlideout() {
    document.getElementById('batch-slideout').classList.add('open');
    document.getElementById('slideout-overlay').classList.add('open');
}

function closeSlideout() {
    document.getElementById('batch-slideout').classList.remove('open');
    document.getElementById('slideout-overlay').classList.remove('open');
}

// ============================================================================
// Helper Functions
// ============================================================================

// Parse a date value from SQL Server (could be "2026-02-14", "2026-02-14T00:00:00", 
// or "/Date(xxxxx)/") and return YYYY-MM-DD string
function parseDateOnly(val) {
    if (!val) return '';
    var s = String(val);
    // Already YYYY-MM-DD
    if (/^\d{4}-\d{2}-\d{2}$/.test(s)) return s;
    // ISO datetime â€” take date portion
    if (s.indexOf('T') > 0) return s.substring(0, 10);
    // .NET /Date()/ format
    var match = s.match(/\/Date\((\d+)\)\//);
    if (match) {
        var d = new Date(parseInt(match[1]));
        return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0');
    }
    // Fallback â€” try to parse and extract
    var d = new Date(s);
    if (!isNaN(d.getTime())) {
        return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0');
    }
    return s;
}

function detailItem(label, value) {
    return '<div class="detail-item"><div class="detail-label">' + label + '</div><div class="detail-value">' + value + '</div></div>';
}

function phaseRow(name, minutes, maxMinutes, colorClass) {
    var pct = maxMinutes > 0 ? Math.min(100, Math.round((minutes / maxMinutes) * 100)) : 0;
    if (minutes > 0 && pct === 0) pct = 1; // minimum visible
    
    var html = '<div class="phase-row">';
    html += '<span class="phase-name">' + name + '</span>';
    html += '<div class="phase-bar"><div class="phase-bar-fill ' + colorClass + '" style="width:' + pct + '%"></div></div>';
    html += '<span class="phase-duration">' + formatDurationMinutes(minutes) + '</span>';
    html += '</div>';
    return html;
}

function formatAge(minutes) {
    if (minutes < 60) return minutes + 'm';
    var h = Math.floor(minutes / 60);
    var m = minutes % 60;
    if (h < 24) return h + 'h ' + m + 'm';
    var d = Math.floor(h / 24);
    h = h % 24;
    return d + 'd ' + h + 'h';
}

function formatTimeSince(seconds) {
    if (seconds < 60) return seconds + 's';
    var m = Math.floor(seconds / 60);
    if (m < 60) return m + 'm';
    var h = Math.floor(m / 60);
    m = m % 60;
    if (h < 24) return h + 'h ' + m + 'm';
    var d = Math.floor(h / 24);
    h = h % 24;
    return d + 'd ' + h + 'h';
}

function formatDurationMinutes(minutes) {
    if (minutes == null || minutes === 0) return '-';
    if (minutes < 60) return minutes + 'm';
    var h = Math.floor(minutes / 60);
    var m = minutes % 60;
    if (h < 24) return h + 'h ' + m + 'm';
    var d = Math.floor(h / 24);
    h = h % 24;
    return d + 'd ' + h + 'h';
}

function formatDisplayDate(dateStr) {
    var parts = dateStr.split('-');
    if (parts.length === 3) {
        var m = parseInt(parts[1]);
        var d = parseInt(parts[2]);
        var y = parts[0];
        return monthNames[m] + ' ' + d + ', ' + y;
    }
    return dateStr;
}

function updateTimestamp() {
    var el = document.getElementById('last-update');
    if (el) {
        var now = new Date();
        el.textContent = now.toLocaleTimeString();
    }
}

function showError(msg) {
    var el = document.getElementById('connection-error');
    el.textContent = msg;
    el.classList.add('visible');
}

function clearError() {
    var el = document.getElementById('connection-error');
    el.classList.remove('visible');
}

function escapeHtml(str) {
    if (!str) return '';
    return String(str).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

function safeInt(val) {
    if (val == null || val === '' || val === 'DBNull') return 0;
    var n = parseInt(val, 10);
    return isNaN(n) ? 0 : n;
}

function safeFloat(val) {
    if (val == null || val === '' || val === 'DBNull') return 0;
    var n = parseFloat(val);
    return isNaN(n) ? 0 : n;
}

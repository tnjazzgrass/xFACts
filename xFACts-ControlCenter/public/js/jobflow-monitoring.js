/* ============================================================================
   xFACts Control Center - JobFlow Monitoring JavaScript
   Location: E:\xFACts-ControlCenter\public\js\jobflow-monitoring.js
   Version: Tracked in dbo.System_Metadata (component: JobFlow)
   ============================================================================ */

// ============================================================================
// CONFIGURATION
// ============================================================================

// Engine events — process map for shared WebSocket module (engine-events.js)
var ENGINE_PROCESSES = {
    'Monitor-JobFlow': { slug: 'jobflow'}
};

// Live polling (Refresh Architecture)
var PAGE_REFRESH_INTERVAL = 30;   // Default; overridden by GlobalConfig on load

// Page hooks for engine-events.js shared module
function onPageResumed() { pageRefresh(); }
function onSessionExpired() { stopPolling(); }
var livePollingTimer = null;
var pageLoadDate = new Date().toDateString();

var monthNames = ['', 'January', 'February', 'March', 'April', 'May', 'June', 
                  'July', 'August', 'September', 'October', 'November', 'December'];
var dayNames = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

// State
var currentHistoryData = null;
var currentPendingData = null;
var currentAdhocData = null;
var currentStallEpisodes = [];
var slideoutJobFilter = 'ALL';  // ALL or FAILED — filters job tables in slideouts

// App Tasks State
var appTasksOriginalState = {};  // Original state from server: { flowCode: { server: isEnabled } }
var appTasksPendingChanges = {}; // Pending changes: { flowCode: { from: server|null, to: server|null } }
var appTasksServerList = [];
var appTasksData = null;

// ============================================================================
// Slideout Job Filter
// ============================================================================

function toggleFailedFilter() {
    slideoutJobFilter = (slideoutJobFilter === 'FAILED') ? 'ALL' : 'FAILED';
    var body = document.getElementById('slideout-body');
    if (body._lastRender) body._lastRender();
}

function filterJobs(jobs) {
    if (slideoutJobFilter === 'FAILED') {
        return jobs.filter(function(j) { return j.is_failed; });
    }
    return jobs;
}

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
    
    document.getElementById('btn-pending-queue').addEventListener('click', function() {
        openPendingQueueSlideout();
    });
    
    document.getElementById('btn-app-tasks').addEventListener('click', openTasksModal);
    
    document.getElementById('tasks-modal-overlay').addEventListener('click', function(e) {
        if (e.target === this) closeTasksModal();
    });
});

// ============================================================================
// REFRESH ARCHITECTURE
// ============================================================================
// Live sections: Live Activity (direct DM query)
// Event-driven sections: Daily Summary, Process Status, Execution History
// See: Refresh Architecture doc, Section 6.4
// ============================================================================

async function loadRefreshInterval() {
    try {
        var data = await engineFetch('/api/config/refresh-interval?page=jobflow');
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
    loadLiveActivity();
    updateTimestamp();
}

// ── Event-driven sections: refresh on orchestrator PROCESS_COMPLETED ──
function refreshEventSections() {
    loadProcessStatus();
    loadDailySummary();
    loadExecutionHistory();
    updateTimestamp();
}

// ── Manual refresh: everything ──
function refreshAll() {
    loadLiveActivity();
    loadProcessStatus();
    loadDailySummary();
    loadExecutionHistory();
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
// Engine indicator card (JobFlow) is now driven by the shared engine-events.js
// WebSocket module. The following functions were removed:
//   - loadEngineStatus()       — polled /api/jobflow/engine-status every 5s
//   - renderEngineCard()       — triggered countdown render
//   - startEngineTicker()      — 1-second countdown ticker
//   - tickEngineCountdown()    — card state/countdown renderer
//   - fmtEngineCountdown()     — countdown time formatter
// See: RealTime_Engine_Events_Architecture.md
// ============================================================================

// ============================================================================
// API Calls
// ============================================================================
function loadLiveActivity() {
    engineFetch('/api/jobflow/live-activity')
        .then(function(data) {
            if (!data) return;
            if (data.error) { showError('Live activity: ' + data.error); return; }
            clearError();
            renderExecutingJobs(data.executing || []);
            currentPendingData = data.pending || [];
            updatePendingBadge(currentPendingData.length);
            updateTimestamp();
        })
        .catch(function(err) { showError('Failed to load live activity: ' + err.message); });
}

function loadProcessStatus() {
    engineFetch('/api/jobflow/status')
        .then(function(data) {
            if (!data) return;
            if (data.error) { showError('Process status: ' + data.error); return; }
            clearError();
            renderProcessStatus(data.processes || [], data.stall_count, data.stall_threshold);
        })
        .catch(function(err) { showError('Failed to load process status: ' + err.message); });
}

function loadDailySummary() {
    engineFetch('/api/jobflow/todays-summary')
        .then(function(data) {
            if (!data) return;
            if (data.error) { showError("Daily summary: " + data.error); return; }
            clearError();
            renderDailySummary(data);
        })
        .catch(function(err) { showError("Failed to load daily summary: " + err.message); });
}

function loadExecutionHistory() {
    engineFetch('/api/jobflow/history')
        .then(function(data) {
            if (!data) return;
            if (data.error) { showError('Execution history: ' + data.error); return; }
            clearError();
            currentHistoryData = data;
            renderExecutionHistory(data);
        })
        .catch(function(err) { showError('Failed to load execution history: ' + err.message); });
}

function loadFlowDayDetails(jobSqncId, flowCode) {
    slideoutJobFilter = 'ALL';
    document.getElementById('slideout-title').textContent = flowCode + ' - Today';
    document.getElementById('slideout-body').innerHTML = '<div class="loading">Loading...</div>';
    openSlideout();
    
    engineFetch('/api/jobflow/flow-day-details?job_sqnc_id=' + jobSqncId)
        .then(function(data) {
            if (!data) return;
            if (data.error) {
                document.getElementById('slideout-body').innerHTML = '<div class="no-activity">Error: ' + data.error + '</div>';
                return;
            }
            var body = document.getElementById('slideout-body');
            body._lastRender = function() { renderFlowDayDetails(data); };
            renderFlowDayDetails(data);
        })
        .catch(function(err) {
            document.getElementById('slideout-body').innerHTML = '<div class="no-activity">Failed to load: ' + err.message + '</div>';
        });
}

function renderFlowDayDetails(data) {
    var body = document.getElementById('slideout-body');
    
    if (!data.executions || data.executions.length === 0) {
        body.innerHTML = '<div class="no-activity">No executions found</div>';
        return;
    }
    
    // Count total failed across all executions
    var totalFailedJobs = 0;
    data.executions.forEach(function(exec) {
        if (exec.jobs) totalFailedJobs += exec.jobs.filter(function(j) { return j.is_failed; }).length;
    });
    
    var failedCardClass = totalFailedJobs > 0 ? ' clickable' + (slideoutJobFilter === 'FAILED' ? ' filter-active' : '') : '';
    var failedCardClick = totalFailedJobs > 0 ? ' onclick="toggleFailedFilter()"' : '';
    
    var html = '<div class="slideout-summary">';
    html += '<div class="slideout-stat"><div class="slideout-stat-label">Executions</div><div class="slideout-stat-value">' + data.execution_count + '</div></div>';
    html += '<div class="slideout-stat"><div class="slideout-stat-label">Total Jobs</div><div class="slideout-stat-value">' + data.total_jobs + '</div></div>';
    html += '<div class="slideout-stat' + failedCardClass + '"' + failedCardClick + '><div class="slideout-stat-label">Failed</div><div class="slideout-stat-value ' + (totalFailedJobs > 0 ? 'failed' : '') + '">' + totalFailedJobs + '</div></div>';
    html += '<div class="slideout-stat"><div class="slideout-stat-label">Records</div><div class="slideout-stat-value">' + (data.total_records ? data.total_records.toLocaleString() : '-') + '</div></div>';
    html += '</div>';
    
    data.executions.forEach(function(exec, idx) {
        // When filtering, skip execution groups with no failed jobs
        var execFailedCount = exec.jobs ? exec.jobs.filter(function(j) { return j.is_failed; }).length : 0;
        if (slideoutJobFilter === 'FAILED' && execFailedCount === 0) return;
        
        var statusClass = (exec.execution_state === 'COMPLETE' || exec.execution_state === 'VALIDATED') ? 'complete' : (exec.execution_state === 'FAILED' ? 'failed' : 'detected');
        var hasFailures = exec.failed_jobs > 0;
        
        var durationDisplay = '-';
        if (exec.duration_seconds != null) {
            var h = Math.floor(exec.duration_seconds / 3600);
            var m = Math.floor((exec.duration_seconds % 3600) / 60);
            var s = exec.duration_seconds % 60;
            durationDisplay = String(h).padStart(2, '0') + ':' + String(m).padStart(2, '0') + ':' + String(s).padStart(2, '0');
        }
        
        var statusLabel = statusClass === 'complete' ? 'Complete' : (statusClass === 'failed' ? 'Failed' : 'In Progress');
        
        html += '<div class="execution-group">';
        html += '<div class="execution-header">';
        html += '<span class="execution-time">' + durationDisplay + '</span>';
        html += '<span class="execution-stats">' + (exec.expected_jobs || exec.completed_jobs || 0) + ' jobs';
        if (hasFailures) html += ', <span class="failed">' + exec.failed_jobs + ' failed</span>';
        html += '</span>';
        html += '<span class="execution-duration"><span class="execution-start-label">Start </span>' + (exec.start_time || '-') + '</span>';
        html += '<span class="flow-status-badge ' + statusClass + '">' + statusLabel + '</span>';
        html += '</div>';
        
        if (exec.jobs && exec.jobs.length > 0) {
            var displayJobs = filterJobs(exec.jobs);
            if (displayJobs.length > 0) {
                html += '<table class="jobs-table execution-jobs-table"><thead><tr><th></th><th>#</th><th>Job</th><th>Start</th><th>End</th><th>Total</th><th>Success</th><th>Failed</th><th>Duration</th><th>Rate</th><th>Log ID</th></tr></thead><tbody>';
                displayJobs.forEach(function(job) {
                    var jobTitle = job.job_full_name ? escapeHtml(job.job_full_name) : '';
                    html += '<tr><td><span class="job-status-badge ' + (job.is_failed ? 'failed' : 'success') + '">' + (job.is_failed ? 'FAILED' : 'SUCCESS') + '</span></td>';
                    html += '<td class="exec-order">' + (job.execution_order != null ? job.execution_order : '-') + '</td>';
                    html += '<td title="' + jobTitle + '">' + escapeHtml(job.job_name) + '</td>';
                    html += '<td>' + (job.start_time || '-') + '</td>';
                    html += '<td>' + (job.end_time || '-') + '</td>';
                    html += '<td>' + (job.total_records !== null ? job.total_records.toLocaleString() : '-') + '</td>';
                    html += '<td class="success">' + (job.succeeded_count !== null ? job.succeeded_count.toLocaleString() : '-') + '</td>';
                    html += '<td class="failed">' + (job.failed_count || 0) + '</td>';
                    html += '<td>' + (job.duration || '-') + '</td>';
                    html += '<td>' + (job.records_per_second ? job.records_per_second.toFixed(1) + '/s' : '-') + '</td>';
                    html += '<td class="log-id">' + (job.job_log_id || '-') + '</td></tr>';
                    if (job.error_message) html += '<tr class="error-row"><td colspan="11"><span class="error-message">' + escapeHtml(job.error_message) + '</span></td></tr>';
                });
                html += '</tbody></table>';
            }
        }
        html += '</div>';
    });
    
    body.innerHTML = html;
}

function loadDayDetails(date) {
    slideoutJobFilter = 'ALL';
    document.getElementById('slideout-title').textContent = 'Executions: ' + formatDisplayDate(date);
    document.getElementById('slideout-body').innerHTML = '<div class="loading">Loading...</div>';
    openSlideout();
    
    engineFetch('/api/jobflow/history-detail?date=' + date)
        .then(function(data) {
            if (!data) return;
            if (data.error) {
                document.getElementById('slideout-body').innerHTML = '<div class="no-activity">Error: ' + data.error + '</div>';
                return;
            }
            var body = document.getElementById('slideout-body');
            body._lastRender = function() { renderDayDetails(data); };
            renderDayDetails(data);
        })
        .catch(function(err) {
            document.getElementById('slideout-body').innerHTML = '<div class="no-activity">Failed to load: ' + err.message + '</div>';
        });
}

function loadAppTasks() {
    document.getElementById('tasks-grid').innerHTML = '<div class="loading">Loading tasks from application servers...</div>';
    hideApplyChangesButton();
    
    engineFetch('/api/jobflow/app-tasks')
        .then(function(data) {
            if (!data) return;
            if (data.error) {
                document.getElementById('tasks-grid').innerHTML = '<div class="task-error">Error: ' + data.error + '</div>';
                return;
            }
            
            // Store original state
            appTasksData = data;
            appTasksServerList = data.servers || ['DM-PROD-APP', 'DM-PROD-APP2', 'DM-PROD-APP3'];
            appTasksOriginalState = {};
            appTasksPendingChanges = {};
            
            data.tasks.forEach(function(task) {
                appTasksOriginalState[task.flow_code] = {};
                appTasksServerList.forEach(function(server) {
                    var state = task.states[server];
                    appTasksOriginalState[task.flow_code][server] = (state === 'Ready');
                });
            });
            
            renderAppTasks(data);
        })
        .catch(function(err) {
            document.getElementById('tasks-grid').innerHTML = '<div class="task-error">Failed to load tasks: ' + err.message + '</div>';
        });
}

function stageTaskChange(flowCode, clickedServer) {
    var original = appTasksOriginalState[flowCode];
    var pending = appTasksPendingChanges[flowCode];
    
    // Find current enabled server (considering pending changes)
    var currentEnabled = null;
    appTasksServerList.forEach(function(server) {
        if (original[server]) currentEnabled = server;
    });
    
    // If there's a pending change, use the pending 'to' as current
    if (pending) {
        currentEnabled = pending.to;
    }
    
    // Determine what happens when this cell is clicked
    if (pending) {
        // There's already a pending change for this flow
        if (clickedServer === pending.to) {
            // Clicking the pending target - undo the change
            delete appTasksPendingChanges[flowCode];
        } else if (clickedServer === pending.from) {
            // Clicking the original source - undo the change
            delete appTasksPendingChanges[flowCode];
        } else {
            // Clicking a different server - change the target
            appTasksPendingChanges[flowCode] = { from: pending.from, to: clickedServer };
        }
    } else {
        // No pending change yet
        if (original[clickedServer]) {
            // Clicking currently enabled - disable it (move to null)
            appTasksPendingChanges[flowCode] = { from: clickedServer, to: null };
        } else {
            // Clicking currently disabled - enable it (move from current enabled)
            appTasksPendingChanges[flowCode] = { from: currentEnabled, to: clickedServer };
        }
    }
    
    // Re-render the grid to show pending state
    renderAppTasksGrid();
    updatePendingChangesUI();
}

function renderAppTasks(data) {
    renderAppTasksGrid();
    updatePendingChangesUI();
}

function renderAppTasksGrid() {
    var container = document.getElementById('tasks-grid');
    if (!appTasksData || !appTasksData.tasks || appTasksData.tasks.length === 0) {
        container.innerHTML = '<div class="task-error">No scheduled tasks found</div>';
        return;
    }
    
    var html = '<div class="tasks-header flow-col">Flow</div>';
    appTasksServerList.forEach(function(server) {
        html += '<div class="tasks-header">' + server.replace('DM-PROD-', '') + '</div>';
    });
    
    appTasksData.tasks.forEach(function(task) {
        var flowCode = task.flow_code;
        var pending = appTasksPendingChanges[flowCode];
        var hasEnabled = task.has_enabled;
        var rowClass = 'task-row-flow';
        
        // Warning state: active flow with no enabled server and no pending enable
        if (!hasEnabled && (!pending || pending.to === null)) {
            rowClass += ' warning-row';
        }
        
        // Build flow name tooltip
        var flowTitle = task.flow_name ? escapeHtml(task.flow_name) : '';
        
        html += '<div class="' + rowClass + '" title="' + flowTitle + '">' + escapeHtml(flowCode) + '</div>';
        
        appTasksServerList.forEach(function(server) {
            var originalEnabled = appTasksOriginalState[flowCode][server];
            var cellClass = 'task-cell';
            var statusClass = 'task-status';
            var icon = '○';
            
            if (pending) {
                // There's a pending change for this flow
                if (server === pending.from && pending.from !== null) {
                    // This is being disabled
                    cellClass += ' pending-disable';
                    statusClass += ' pending-disable';
                    icon = '●';
                } else if (server === pending.to && pending.to !== null) {
                    // This is being enabled
                    cellClass += ' pending-enable';
                    statusClass += ' pending-enable';
                    icon = '●';
                } else if (originalEnabled) {
                    // Originally enabled, not involved in change
                    cellClass += ' enabled';
                    statusClass += ' enabled';
                    icon = '●';
                } else {
                    cellClass += ' disabled';
                    statusClass += ' disabled';
                }
            } else {
                // No pending change
                if (originalEnabled) {
                    cellClass += ' enabled';
                    statusClass += ' enabled';
                    icon = '●';
                } else {
                    cellClass += ' disabled';
                    statusClass += ' disabled';
                }
            }
            
            html += '<div class="' + cellClass + '" onclick="stageTaskChange(\'' + flowCode + '\', \'' + server + '\')">';
            html += '<span class="' + statusClass + '">' + icon + '</span></div>';
        });
    });
    
    container.innerHTML = html;
}

function updatePendingChangesUI() {
    var changeCount = Object.keys(appTasksPendingChanges).length;
    var indicator = document.getElementById('pending-changes-indicator');
    var applyBtn = document.getElementById('btn-apply-changes');
    
    if (changeCount > 0) {
        indicator.textContent = 'Pending Changes: ' + changeCount;
        indicator.classList.remove('hidden');
        applyBtn.classList.remove('hidden');
    } else {
        indicator.classList.add('hidden');
        applyBtn.classList.add('hidden');
    }
}

function hideApplyChangesButton() {
    document.getElementById('pending-changes-indicator').classList.add('hidden');
    document.getElementById('btn-apply-changes').classList.add('hidden');
}

function showApplyConfirmation() {
    var changes = [];
    for (var flowCode in appTasksPendingChanges) {
        var change = appTasksPendingChanges[flowCode];
        var fromName = change.from ? change.from.replace('DM-PROD-', '') : 'None';
        var toName = change.to ? change.to.replace('DM-PROD-', '') : 'None';
        changes.push({ flowCode: flowCode, from: fromName, to: toName });
    }
    
    var html = '<div class="confirm-changes-list">';
    changes.forEach(function(c) {
        html += '<div class="confirm-change-item">Move <strong>' + escapeHtml(c.flowCode) + '</strong> from <span class="from-server">' + c.from + '</span> to <span class="to-server">' + c.to + '</span></div>';
    });
    html += '</div>';
    
    document.getElementById('confirm-changes-body').innerHTML = html;
    document.getElementById('confirm-modal-overlay').classList.remove('hidden');
}

function closeConfirmModal() {
    document.getElementById('confirm-modal-overlay').classList.add('hidden');
}

function cancelAllChanges() {
    appTasksPendingChanges = {};
    renderAppTasksGrid();
    updatePendingChangesUI();
    closeConfirmModal();
}

function applyAllChanges() {
    var changes = [];
    
    for (var flowCode in appTasksPendingChanges) {
        var change = appTasksPendingChanges[flowCode];
        
        // Disable the 'from' server if it exists
        if (change.from) {
            changes.push({ server: change.from, flow_code: flowCode, enable: false });
        }
        
        // Enable the 'to' server if it exists
        if (change.to) {
            changes.push({ server: change.to, flow_code: flowCode, enable: true });
        }
    }
    
    if (changes.length === 0) {
        closeConfirmModal();
        return;
    }
    
    // Show loading state
    document.getElementById('confirm-changes-body').innerHTML = '<div class="loading">Applying changes...</div>';
    document.getElementById('btn-confirm-apply').disabled = true;
    document.getElementById('btn-confirm-cancel').disabled = true;
    
    engineFetch('/api/jobflow/app-tasks/batch', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ changes: changes })
    })
        .then(function(data) {
            if (!data) return;
            closeConfirmModal();
            document.getElementById('btn-confirm-apply').disabled = false;
            document.getElementById('btn-confirm-cancel').disabled = false;
            
            if (data.error) {
                alert('Failed to apply changes: ' + data.error);
                loadAppTasks();
                return;
            }
            
            if (!data.success) {
                var failedMsg = 'Some changes failed:\n';
                data.results.forEach(function(r) {
                    if (!r.success) {
                        failedMsg += '- ' + r.flow_code + ' on ' + r.server.replace('DM-PROD-', '') + ': ' + r.error + '\n';
                    }
                });
                if (data.rollback_attempted) {
                    failedMsg += '\nRollback was attempted for successful changes.';
                }
                alert(failedMsg);
            }
            
            // Refresh to show current state
            loadAppTasks();
        })
        .catch(function(err) {
            closeConfirmModal();
            document.getElementById('btn-confirm-apply').disabled = false;
            document.getElementById('btn-confirm-cancel').disabled = false;
            alert('Failed to apply changes: ' + err.message);
            loadAppTasks();
        });
}

// ============================================================================
// Rendering Functions
// ============================================================================
function renderExecutingJobs(jobs) {
    var container = document.getElementById('executing-jobs');
    
    if (!jobs || jobs.length === 0) {
        container.innerHTML = '<div class="no-activity">No jobs currently executing</div>';
        return;
    }
    
    var html = '<table class="executing-table"><thead><tr>';
    html += '<th>Job</th><th>Flow</th><th>Progress</th><th>Success</th><th>Failed</th><th>ETA</th><th>Rate</th><th>Log ID</th>';
    html += '</tr></thead><tbody>';
    
    jobs.forEach(function(job) {
        var progress = 0;
        var progressText = '-';
        if (job.total_records && job.total_records > 0) {
            progress = Math.round((job.completed_records / job.total_records) * 100);
            progressText = job.completed_records.toLocaleString() + ' / ' + job.total_records.toLocaleString();
        } else if (job.completed_records > 0) {
            progressText = job.completed_records.toLocaleString() + ' processed';
        }
        
        var jobTitle = job.job_full_name ? escapeHtml(job.job_full_name) : '';
        
        html += '<tr>';
        html += '<td><span class="job-name" title="' + jobTitle + '">' + escapeHtml(job.job_name) + '</span></td>';
        html += '<td>';
        if (job.flow_code) {
            html += '<span class="flow-badge">' + escapeHtml(job.flow_code) + '</span>';
        } else {
            html += '<span style="color: #666;">ad-hoc</span>';
        }
        html += '</td><td>';
        if (job.total_records && job.total_records > 0) {
            html += '<div class="progress-bar-container">';
            html += '<div class="progress-bar" style="width: ' + progress + '%"></div>';
            html += '<span class="progress-text">' + progressText + '</span></div>';
        } else {
            html += '<span style="color: #888;">' + progressText + '</span>';
        }
        html += '</td>';
        html += '<td class="success">' + (job.success_count || 0).toLocaleString() + '</td>';
        html += '<td class="failed">' + (job.failure_count || 0).toLocaleString() + '</td>';
        html += '<td><span class="eta-value">' + (job.time_remaining || '-') + '</span></td>';
        html += '<td><span class="rate-value">' + (job.records_per_second ? job.records_per_second + '/s' : '-') + '</span></td>';
        html += '<td class="log-id">' + (job.job_log_id || '-') + '</td>';
        html += '</tr>';
    });
    
    html += '</tbody></table>';
    container.innerHTML = html;
}

function renderPendingJobs(jobs) {
    var body = document.getElementById('slideout-body');
    
    if (!jobs || jobs.length === 0) {
        body.innerHTML = '<div class="no-activity">No jobs currently pending</div>';
        return;
    }
    
    var html = '<div class="pending-summary"><span class="pending-total">' + jobs.length + ' jobs in queue</span></div>';
    html += '<table class="pending-table"><thead><tr><th>Job</th><th>Flow</th><th>Queued</th></tr></thead><tbody>';
    
    jobs.forEach(function(job) {
        html += '<tr><td><span class="job-name">' + escapeHtml(job.job_name) + '</span></td><td>';
        if (job.flow_code) {
            html += '<span class="flow-badge">' + escapeHtml(job.flow_code) + '</span>';
        } else {
            html += '<span style="color: #666;">ad-hoc</span>';
        }
        html += '</td><td><span style="color: #888;">' + (job.queued_time || '-') + '</span></td></tr>';
    });
    
    html += '</tbody></table>';
    body.innerHTML = html;
}

function updatePendingBadge(count) {
    var badge = document.getElementById('pending-count-badge');
    if (count > 0) {
        badge.textContent = count;
        badge.classList.remove('hidden');
    } else {
        badge.classList.add('hidden');
    }
}

function renderProcessStatus(processes, stallCount, stallThreshold) {
    var container = document.getElementById('process-status');
    
    if (!processes || processes.length === 0) {
        container.innerHTML = '<div class="no-activity">No process status available</div>';
        return;
    }
    
    // Icons for each process step (HTML entities for encoding safety)
    var processIcons = {
        'Flow Config Sync': '&#x21BB;',
        'Flow Detection': '&#x25C9;',
        'Completed Jobs Capture': '&#x2913;',
        'Flow Progress': '&#x25B6;',
        'Flow State Transitions': '&#x21C4;',
        'Stall Detection': '&#x23F8;',
        'Flow Validation': '&#x2714;',
        'Missing Flows': '&#x26A0;'
    };
    
    var threshold = stallThreshold || 6;
    
    var html = '';
    processes.forEach(function(proc) {
        var name = proc.short_name || proc.process_name;
        var icon = processIcons[name] || '&#x2022;';
        var count = proc.last_result_count;
        var countDisplay = (count !== null && count !== undefined) ? count : '-';
        var timeDisplay = proc.time_ago || '-';
        
        // Determine card color class - neutral when healthy
        var cardClass = proc.status_class || 'healthy';
        
        // Special color logic for STALLS card based on current counter
        if (name === 'Stall Detection') {
            if (stallCount === null || stallCount === undefined || stallCount === 0) {
                cardClass = 'healthy';
            } else if (stallCount < threshold) {
                cardClass = 'warning';
            } else {
                cardClass = 'error';
            }
        }
        
        // Special color logic for SYNC card (drift count)
        if (name === 'Flow Config Sync' && count !== null && count !== undefined && count > 0) {
            cardClass = 'warning';
        }
        
        // Only apply border color class for non-healthy states
        var cardColorClass = (cardClass !== 'healthy') ? ' ' + cardClass : '';
        
        // ConfigSync card is always clickable - opens config viewer/editor
        var clickAttr = '';
        if (name === 'Flow Config Sync') {
            clickAttr = ' onclick="openConfigSyncModal()" style="cursor:pointer"';
        }
        
        // Count color matches border color
        var countColorClass = ' count-healthy';
        if (cardClass === 'warning') countColorClass = ' count-warning';
        if (cardClass === 'error') countColorClass = ' count-error';
        
        html += '<div class="status-card' + cardColorClass + '"' + clickAttr + '>';
        html += '<div class="status-card-header"><span class="status-card-name">' + escapeHtml(name) + '</span><span class="status-card-icon">' + icon + '</span></div>';
        html += '<div class="status-card-count' + countColorClass + '">' + countDisplay + '</div>';
        html += '<div class="status-card-time">' + timeDisplay + '</div>';
        html += '</div>';
    });
    
    container.innerHTML = html;
}

function renderDailySummary(data) {
    var container = document.getElementById('daily-summary');
    var flowCount = (data.flows || []).length;
    var adhocCount = (data.adhoc_jobs || []).length;
    var completedFlows = (data.flows || []).filter(function(f) { return f.execution_state === 'COMPLETE' || f.execution_state === 'VALIDATED'; }).length;
    var failedFlows = (data.flows || []).filter(function(f) { return f.execution_state === 'FAILED'; }).length;
    var inProgressFlows = flowCount - completedFlows - failedFlows;
    
    // Store ad-hoc data for slideout
    currentAdhocData = data.adhoc_jobs || [];
    
    // Store stall episodes for slideout
    currentStallEpisodes = data.stall_episodes || [];
    
    // Count total executions across all flows
    var totalExecutions = (data.flows || []).reduce(function(sum, f) { return sum + (f.execution_count || 1); }, 0);
    
    // Stall episode count
    var stallEventCount = currentStallEpisodes.length;
    
    // Cards: TOTAL JOBS | FLOWS | STALL EVENTS
    var html = '<div class="summary-cards">';
    
    // TOTAL JOBS card
    html += '<div class="summary-card"><div class="summary-card-label">TOTAL JOBS</div><div class="summary-card-value">' + (data.total_jobs || 0).toLocaleString() + '</div>';
    html += '<div class="summary-card-detail"><span class="muted">All executions</span></div></div>';
    
    // FLOWS card
    html += '<div class="summary-card"><div class="summary-card-label">FLOWS</div><div class="summary-card-value">' + flowCount + '</div><div class="summary-card-detail">';
    if (completedFlows > 0) html += '<span class="success">' + completedFlows + ' done</span>';
    if (inProgressFlows > 0) html += '<span class="in-progress">' + inProgressFlows + ' active</span>';
    if (failedFlows > 0) html += '<span class="failed">' + failedFlows + ' failed</span>';
    if (flowCount === 0) html += '<span class="muted">None today</span>';
    if (totalExecutions > flowCount) html += '<span class="muted">(' + totalExecutions + ' runs)</span>';
    html += '</div></div>';
    
    // STALL EVENTS card (clickable when events exist)
    var stallCardClass = stallEventCount > 0 ? ' stall-active clickable' : ' clickable';
    var stallClick = ' onclick="openStallEpisodesSlideout()"';
    html += '<div class="summary-card' + stallCardClass + '"' + stallClick + '><div class="summary-card-label">STALL EVENTS</div>';
    html += '<div class="summary-card-value' + (stallEventCount > 0 ? ' stall-value' : '') + '">' + stallEventCount + '</div>';
    html += '<div class="summary-card-detail">';
    if (stallEventCount === 0) {
        html += '<span class="success">No stalls today</span>';
    } else {
        var unresolvedCount = currentStallEpisodes.filter(function(e) { return !e.resolved; }).length;
        if (unresolvedCount > 0) {
            html += '<span class="failed">' + unresolvedCount + ' ongoing</span>';
        } else {
            html += '<span class="muted">All resolved</span>';
        }
    }
    html += '</div><span class="card-click-arrow">&#x25B6;</span></div>';
    
    html += '</div>';
    
    // Flow list section
    if (flowCount > 0) {
        html += '<div class="summary-section"><div class="summary-section-title">Flows</div><div class="summary-items">';
        data.flows.forEach(function(flow) {
            var statusClass = (flow.execution_state === 'COMPLETE' || flow.execution_state === 'VALIDATED') ? 'complete' : (flow.execution_state === 'FAILED' ? 'failed' : 'detected');
            var execCount = flow.execution_count || 1;
            var clickHandler = ' onclick="loadFlowDayDetails(' + flow.job_sqnc_id + ', \'' + escapeHtml(flow.flow_code) + '\')"';
            var flowNameDisplay = flow.flow_name ? escapeHtml(flow.flow_name) : '';
            var execLabel = execCount > 1 ? ' (' + execCount + ' runs)' : '';
            html += '<div class="flow-item clickable"' + clickHandler + '>';
            var flowStatusLabel = statusClass === 'complete' ? 'Complete' : (statusClass === 'failed' ? 'Failed' : 'In Progress');
            html += '<div class="flow-item-left"><span class="flow-code">' + escapeHtml(flow.flow_code) + '</span><span class="flow-name flow-name-' + statusClass + '">' + flowNameDisplay + '</span></div>';
            html += '<div class="flow-item-right">';
            html += '<span class="flow-jobs">' + (flow.expected_jobs || flow.completed_jobs || 0) + ' jobs' + execLabel + '</span>';
            html += '<span class="flow-succeeded">' + (flow.completed_jobs || 0) + ' succeeded</span>';
            html += '<span class="flow-failed">' + ((flow.failed_jobs || 0) > 0 ? flow.failed_jobs + ' failed' : '') + '</span>';
            html += '<span class="flow-duration">' + (flow.duration || '-') + '</span>';
            html += '<span class="flow-status-badge ' + statusClass + '">' + flowStatusLabel + '</span>';
            html += '<span class="flow-arrow">&#x25B6;</span>';
            html += '</div></div>';
        });
        html += '</div></div>';
    }
    
    // Ad hoc section (compact clickable title for slideout access)
    if (adhocCount > 0) {
        html += '<div class="summary-section"><div class="summary-section-title clickable" onclick="openAdhocSlideout()">Ad Hoc Jobs (' + adhocCount + ') <span class="section-arrow">&#x25B6;</span></div></div>';
    }
    
    container.innerHTML = html;
}

function openStallEpisodesSlideout() {
    document.getElementById('slideout-title').textContent = 'Stall Events Today';
    var body = document.getElementById('slideout-body');
    
    if (!currentStallEpisodes || currentStallEpisodes.length === 0) {
        body.innerHTML = '<div class="no-activity">No stall events today</div><div class="stall-history-link"><button class="stall-history-btn" onclick="loadStallHistory()">View All History</button></div>';
        openSlideout();
        return;
    }
    
    var html = '<div class="stall-episodes">';
    
    currentStallEpisodes.forEach(function(ep, idx) {
        var statusClass = ep.resolved ? 'resolved' : 'ongoing';
        var statusIcon = ep.resolved ? '&#x2714;' : '&#x25CF;';
        var resLabel = ep.resolved ? 'Resolved' : 'Ongoing';
        var endDisplay = ep.resolved && ep.end_time ? ep.end_time : 'ongoing';
        
        var durationDisplay = '-';
        if (ep.start_time && ep.end_time && ep.resolved) {
            var sp = ep.start_time.split(':');
            var ep2 = ep.end_time.split(':');
            var diffMin = (parseInt(ep2[0]) * 60 + parseInt(ep2[1])) - (parseInt(sp[0]) * 60 + parseInt(sp[1]));
            if (diffMin < 0) diffMin += 1440;
            if (diffMin >= 60) {
                durationDisplay = Math.floor(diffMin / 60) + 'h ' + (diffMin % 60) + 'm';
            } else {
                durationDisplay = diffMin + 'm';
            }
        } else if (!ep.resolved) {
            durationDisplay = 'ongoing';
        }
        
        var alertBadge = ep.alert_sent ? '<span class="stall-ep-alert-badge">Alert</span>' : '';
		var overnightBadge = ep.crosses_midnight ? '<span class="stall-ep-overnight-badge">Overnight</span>' : '';
        
        html += '<div class="stall-episode-row ' + statusClass + '">';
        html += '<span class="stall-ep-icon ' + statusClass + '">' + statusIcon + '</span>';
        html += '<span class="stall-ep-num">Episode ' + (idx + 1) + '</span>';
		html += '<span class="stall-ep-field"><span class="stall-ep-label">Start</span> ' + ep.start_time + '</span>';
        html += '<span class="stall-ep-field"><span class="stall-ep-label">End</span> ' + endDisplay + '</span>';
        html += '<span class="stall-ep-field"><span class="stall-ep-label">Duration</span> ' + durationDisplay + '</span>';
        html += '<span class="stall-ep-field"><span class="stall-ep-label">Polls</span> ' + ep.polls + '</span>';
		html += overnightBadge;
		html += alertBadge;
		html += '<span class="stall-ep-resolution ' + statusClass + '">' + resLabel + '</span>';
        html += '</div>';
    });
    
    html += '</div>';
    html += '<div class="stall-history-link"><button class="stall-history-btn" onclick="loadStallHistory()">View All History</button></div>';
    body.innerHTML = html;
    openSlideout();
}

function loadStallHistory() {
    document.getElementById('slideout-title').textContent = 'Stall Event History';
    var body = document.getElementById('slideout-body');
    body.innerHTML = '<div class="loading-indicator">Loading history...</div>';
    
    engineFetch('/api/jobflow/stall-history?days=90')
        .then(function(data) {
            if (!data) return;
            if (!data.dates || data.dates.length === 0) {
                body.innerHTML = '<div class="no-activity">No stall events in the last 90 days</div>';
                return;
            }
            
            var html = '<div class="stall-history-summary">';
            html += '<span class="stall-history-range">' + data.dates_with_events + ' day' + (data.dates_with_events === 1 ? '' : 's') + ' with events (last 90 days)</span>';
            html += '</div>';
            html += '<div class="stall-history-dates">';
            
            data.dates.forEach(function(dateGroup) {
                var alertBadge = dateGroup.alert_count > 0 ? '<span class="stall-date-alert">' + dateGroup.alert_count + ' alert' + (dateGroup.alert_count === 1 ? '' : 's') + '</span>' : '';
                var stallTimeStr = '';
                if (dateGroup.total_stall_minutes != null && dateGroup.total_stall_minutes > 0) {
                    if (dateGroup.total_stall_minutes >= 60) {
                        stallTimeStr = Math.floor(dateGroup.total_stall_minutes / 60) + 'h ' + (dateGroup.total_stall_minutes % 60) + 'm';
                    } else {
                        stallTimeStr = dateGroup.total_stall_minutes + 'm';
                    }
                    stallTimeStr = '<span class="stall-date-total-time">Total: ' + stallTimeStr + '</span>';
                }
                html += '<div class="stall-date-group">';
                html += '<div class="stall-date-header"><span class="stall-date-val">' + dateGroup.date + '</span><span class="stall-date-dow">' + dateGroup.day_of_week + '</span><span class="stall-date-episodes-count">' + dateGroup.episode_count + ' episode' + (dateGroup.episode_count === 1 ? '' : 's') + '</span>' + stallTimeStr + alertBadge + '</div>';
                html += '<div class="stall-date-episodes">';
                
                dateGroup.episodes.forEach(function(ep, idx) {
                    var statusClass = ep.resolved ? 'resolved' : 'ongoing';
                    var statusIcon = ep.resolved ? '&#x2714;' : '&#x25CF;';
                    var resLabel = ep.resolved ? 'Resolved' : 'Ongoing';
                    var endDisplay = ep.resolved && ep.end_time ? ep.end_time : 'ongoing';
                    
                    // Calculate duration from HH:mm strings
                    var durationDisplay = '-';
                    if (ep.start_time && ep.end_time && ep.resolved) {
                        var sp = ep.start_time.split(':');
                        var ep2 = ep.end_time.split(':');
                        var diffMin = (parseInt(ep2[0]) * 60 + parseInt(ep2[1])) - (parseInt(sp[0]) * 60 + parseInt(sp[1]));
                        if (diffMin < 0) diffMin += 1440;
                        if (diffMin >= 60) {
                            durationDisplay = Math.floor(diffMin / 60) + 'h ' + (diffMin % 60) + 'm';
                        } else {
                            durationDisplay = diffMin + 'm';
                        }
                    } else if (!ep.resolved) {
                        durationDisplay = 'ongoing';
                    }
                    
                    var alertBadge = ep.alert_sent ? '<span class="stall-ep-alert-badge">Alert</span>' : '';
					var overnightBadge = ep.crosses_midnight ? '<span class="stall-ep-overnight-badge">Overnight</span>' : '';
                    
                    html += '<div class="stall-episode-row ' + statusClass + '">';
                    html += '<span class="stall-ep-icon ' + statusClass + '">' + statusIcon + '</span>';
                    html += '<span class="stall-ep-num">Episode ' + (idx + 1) + '</span>';
					html += '<span class="stall-ep-field"><span class="stall-ep-label">Start</span> ' + ep.start_time + '</span>';
                    html += '<span class="stall-ep-field"><span class="stall-ep-label">End</span> ' + endDisplay + '</span>';
                    html += '<span class="stall-ep-field"><span class="stall-ep-label">Duration</span> ' + durationDisplay + '</span>';
                    html += '<span class="stall-ep-field"><span class="stall-ep-label">Polls</span> ' + ep.polls + '</span>';
					html += overnightBadge;
					html += alertBadge;
                    html += '<span class="stall-ep-resolution ' + statusClass + '">' + resLabel + '</span>';
                    html += '</div>';
                });
                
                html += '</div></div>';
            });
            
            html += '</div>';
            body.innerHTML = html;
        })
        .catch(function(err) {
            body.innerHTML = '<div class="no-activity">Error loading stall history</div>';
        });
}

// ============================================================================
// Execution History - BIDATA Style
// ============================================================================
function renderExecutionHistory(data) {
    var container = document.getElementById('execution-history');
    var countEl = document.getElementById('history-count');
    
    if (!data || !data.years || data.years.length === 0) {
        container.innerHTML = '<div class="no-activity">No execution history available</div>';
        countEl.textContent = '';
        return;
    }
    
    countEl.textContent = (data.total_job_count || 0).toLocaleString() + ' jobs';
    
    var html = '<div class="history-tree">';
    
    data.years.forEach(function(yearData) {
        // Aggregate year totals from month data
        var yearFlows = 0, yearJobs = 0, yearSuccess = 0, yearFailed = 0;
        yearData.months.forEach(function(md) {
            yearFlows += md.distinct_flows || 0;
            yearJobs += md.total_jobs || 0;
            yearSuccess += md.successful_jobs || 0;
            yearFailed += md.failed_jobs || 0;
        });
        
        html += '<div class="history-year" data-year="' + yearData.year + '">';
        html += '<div class="year-header" onclick="toggleYear(this)">';
        html += '<span class="expand-icon">▶</span>';
        html += '<span class="year-label">' + yearData.year + '</span>';
        html += '<div class="year-stats">';
        html += '<span class="year-stat">' + yearJobs.toLocaleString() + ' jobs</span>';
        html += '<span class="year-stat success">' + yearSuccess.toLocaleString() + ' succeeded</span>';
        html += '<span class="year-stat failed">' + (yearFailed > 0 ? yearFailed.toLocaleString() + ' failed' : '-') + '</span>';
        html += '</div>';
        html += '</div>';
        html += '<div class="year-content" style="display:none;">';
        html += '<table class="month-summary-table"><thead><tr><th></th><th>Month</th><th>Flows</th><th>Jobs</th><th>Succeeded</th><th>Failed</th></tr></thead>';
        
        yearData.months.forEach(function(monthData) {
            html += '<tbody class="month-group" data-month="' + monthData.month + '">';
            html += '<tr class="month-row" onclick="toggleMonthGroup(this)">';
            html += '<td class="expand-cell"><span class="expand-icon">▶</span></td>';
            html += '<td class="month-cell">' + monthNames[monthData.month] + '</td>';
            html += '<td>' + (monthData.distinct_flows || 0) + '</td>';
            html += '<td>' + (monthData.total_jobs || 0).toLocaleString() + '</td>';
            html += '<td class="success-cell">' + (monthData.successful_jobs || 0).toLocaleString() + '</td>';
            html += '<td class="fail-cell">' + (monthData.failed_jobs > 0 ? monthData.failed_jobs.toLocaleString() : '-') + '</td>';
            html += '</tr>';
            html += '<tr class="month-details" style="display:none;"><td colspan="6">';
            html += '<div class="month-details-content" data-year="' + yearData.year + '" data-month="' + monthData.month + '"><div class="loading">Loading...</div></div>';
            html += '</td></tr></tbody>';
        });
        
        html += '</table></div></div>';
    });
    
    html += '</div>';
    container.innerHTML = html;
}

function renderMonthDays(container, days) {
    var html = '<table class="history-table"><thead><tr><th></th><th>Day</th><th>Date</th><th>Flows</th><th>Jobs</th><th>Succeeded</th><th>Failed</th></tr></thead><tbody>';
    
    days.forEach(function(dayData, idx) {
        var statusClass = 'success';
        if (dayData.failed_jobs > 0 && dayData.failed_jobs < dayData.total_jobs) statusClass = 'warning';
        else if (dayData.failed_jobs > 0 && dayData.failed_jobs === dayData.total_jobs) statusClass = 'error';
        
        var dateParts = dayData.date.split('-');
        html += '<tr class="' + (idx % 2 === 0 ? '' : 'row-odd') + '" onclick="loadDayDetails(\'' + dayData.date + '\')">';
        html += '<td><span class="status-indicator ' + statusClass + '"></span></td>';
        html += '<td>' + dayData.day_of_week + '</td>';
        html += '<td>' + dateParts[1] + '/' + dateParts[2] + '</td>';
        html += '<td>' + (dayData.flow_count || 0) + '</td>';
        html += '<td>' + (dayData.total_jobs || 0) + '</td>';
        html += '<td class="success-cell">' + (dayData.successful_jobs || 0) + '</td>';
        html += '<td class="fail-cell">' + (dayData.failed_jobs > 0 ? dayData.failed_jobs : '-') + '</td>';
        html += '</tr>';
    });
    
    html += '</tbody></table>';
    container.innerHTML = html;
}

function renderDayDetails(data) {
    var body = document.getElementById('slideout-body');
    var hasFlows = data.flows && data.flows.length > 0;
    var hasAdhoc = data.adhoc_jobs && data.adhoc_jobs.length > 0;
    
    if (!hasFlows && !hasAdhoc) {
        body.innerHTML = '<div class="no-activity">No executions found for this date</div>';
        return;
    }
    
    var html = '<div class="slideout-summary">';
    html += '<div class="slideout-stat"><div class="slideout-stat-label">Flows</div><div class="slideout-stat-value">' + (data.flows ? data.flows.length : 0) + '</div></div>';
    html += '<div class="slideout-stat"><div class="slideout-stat-label">Ad Hoc</div><div class="slideout-stat-value">' + (data.adhoc_jobs ? data.adhoc_jobs.length : 0) + '</div></div>';
    html += '<div class="slideout-stat"><div class="slideout-stat-label">Total Jobs</div><div class="slideout-stat-value">' + (data.total_jobs || 0) + '</div></div>';
    
    // Count total failed across all flows and adhoc
    var totalFailedJobs = 0;
    if (hasFlows) {
        data.flows.forEach(function(flow) {
            if (flow.jobs) totalFailedJobs += flow.jobs.filter(function(j) { return j.is_failed; }).length;
        });
    }
    if (hasAdhoc) {
        totalFailedJobs += data.adhoc_jobs.filter(function(j) { return j.is_failed; }).length;
    }
    
    var failedCardClass = totalFailedJobs > 0 ? ' clickable' + (slideoutJobFilter === 'FAILED' ? ' filter-active' : '') : '';
    var failedCardClick = totalFailedJobs > 0 ? ' onclick="toggleFailedFilter()"' : '';
    html += '<div class="slideout-stat' + failedCardClass + '"' + failedCardClick + '><div class="slideout-stat-label">Failed</div><div class="slideout-stat-value ' + (totalFailedJobs > 0 ? 'failed' : '') + '">' + totalFailedJobs + '</div></div>';
    html += '</div>';
    
    if (hasFlows) {
        html += '<div class="slideout-section-title">Flows (' + data.flows.length + ')</div>';
        data.flows.forEach(function(flow) {
            // When filtering, skip flow groups with no failed jobs
            var flowFailedCount = flow.jobs ? flow.jobs.filter(function(j) { return j.is_failed; }).length : 0;
            if (slideoutJobFilter === 'FAILED' && flowFailedCount === 0) return;
            
            var hasFailures = flow.failed_jobs > 0;
            var valIcon = '';
            if (flow.validation_status) {
                var valClass = 'val-success';
                var valLabel = 'Validated';
                var valTitle = flow.validation_status;
                if (flow.validation_status === 'CRITICAL_FAILURE' || flow.validation_status === 'SYSTEM_FAILURE') {
                    valClass = 'val-error'; valLabel = flow.validation_status === 'CRITICAL_FAILURE' ? 'Critical' : 'System Failure';
                } else if (flow.validation_status === 'PARTIAL_FAILURE' || flow.validation_status === 'BUSINESS_REJECTION') {
                    valClass = 'val-warning'; valLabel = flow.validation_status === 'PARTIAL_FAILURE' ? 'Partial' : 'Rejected';
                } else if (flow.validation_status === 'MISSING_JOBS') {
                    valClass = 'val-error'; valLabel = 'Missing Jobs';
                } else if (flow.validation_status === 'FLOW_NOT_RUN') {
                    valClass = 'val-dimmed'; valLabel = 'Not Run';
                }
                valIcon = '<span class="validation-badge ' + valClass + '" title="Validation: ' + valTitle + '">' + valLabel + '</span>';
            } else {
                valIcon = '<span class="validation-badge val-none" title="Not validated">Unvalidated</span>';
            }
            var flowGroupStatusLabel = hasFailures ? 'Warning' : 'Complete';
            var flowGroupStatusClass = hasFailures ? 'warning' : 'complete';
            html += '<div class="flow-group"><div class="flow-group-header">';
            var flowLabel = escapeHtml(flow.flow_code);
            if (flow.exec_hour_label) flowLabel += ' &mdash; ' + escapeHtml(flow.exec_hour_label);
            html += '<span class="flow-code">' + flowLabel + '</span>';
            html += '<span class="flow-status-badge ' + flowGroupStatusClass + '">' + flowGroupStatusLabel + '</span>' + valIcon;
            html += '<span class="flow-group-stats">' + flow.total_jobs + ' jobs' + (hasFailures ? ', <span class="failed">' + flow.failed_jobs + ' failed</span>' : '') + '</span>';
            if (flow.duration) html += '<span class="flow-group-time">' + flow.duration + '</span>';
            html += '</div>';
            if (flow.jobs && flow.jobs.length > 0) {
                var displayJobs = filterJobs(flow.jobs);
                if (displayJobs.length > 0) {
                    html += '<table class="jobs-table flow-jobs-table"><thead><tr><th></th><th>#</th><th>Job</th><th>Start</th><th>End</th><th>Total</th><th>Success</th><th>Failed</th><th>Duration</th><th>Rate</th><th>Log ID</th></tr></thead><tbody>';
                    displayJobs.forEach(function(job) {
                        var jobTitle = job.job_full_name ? escapeHtml(job.job_full_name) : '';
                        html += '<tr><td><span class="job-status-badge ' + (job.is_failed ? 'failed' : 'success') + '">' + (job.is_failed ? 'FAILED' : 'SUCCESS') + '</span></td>';
                        html += '<td class="exec-order">' + (job.execution_order != null ? job.execution_order : '-') + '</td>';
                        html += '<td title="' + jobTitle + '">' + escapeHtml(job.job_name) + '</td>';
                        html += '<td>' + (job.start_time || '-') + '</td>';
                        html += '<td>' + (job.end_time || '-') + '</td>';
                        html += '<td>' + (job.total_records !== null ? job.total_records.toLocaleString() : '-') + '</td>';
                        html += '<td class="success">' + (job.succeeded_count !== null ? job.succeeded_count.toLocaleString() : '-') + '</td>';
                        html += '<td class="failed">' + (job.failed_count || 0) + '</td>';
                        html += '<td>' + (job.duration || '-') + '</td>';
                        html += '<td>' + (job.records_per_second ? job.records_per_second.toFixed(1) + '/s' : '-') + '</td>';
                        html += '<td class="log-id">' + (job.job_log_id || '-') + '</td></tr>';
                        if (job.error_message) html += '<tr class="error-row"><td colspan="11"><span class="error-message">' + escapeHtml(job.error_message) + '</span></td></tr>';
                    });
                    html += '</tbody></table>';
                }
            }
            html += '</div>';
        });
    }
    
    if (hasAdhoc) {
        var adhocDisplay = filterJobs(data.adhoc_jobs);
        if (adhocDisplay.length > 0) {
            html += '<div class="slideout-section-title">Ad Hoc Jobs (' + data.adhoc_jobs.length + ')</div>';
            html += '<table class="jobs-table"><thead><tr><th></th><th>#</th><th>Job</th><th>Start</th><th>End</th><th>Total</th><th>Success</th><th>Failed</th><th>Duration</th><th>Rate</th><th>User</th><th>Log ID</th></tr></thead><tbody>';
            adhocDisplay.forEach(function(job) {
            var jobTitle = job.job_full_name ? escapeHtml(job.job_full_name) : '';
            html += '<tr><td><span class="job-status-badge ' + (job.is_failed ? 'failed' : 'success') + '">' + (job.is_failed ? 'FAILED' : 'SUCCESS') + '</span></td>';
            html += '<td class="exec-order">-</td>';
            html += '<td title="' + jobTitle + '">' + escapeHtml(job.job_name) + '</td>';
            html += '<td>' + (job.start_time || '-') + '</td>';
            html += '<td>' + (job.end_time || '-') + '</td>';
            html += '<td>' + (job.total_records !== null ? job.total_records.toLocaleString() : '-') + '</td>';
            html += '<td class="success">' + (job.succeeded_count !== null ? job.succeeded_count.toLocaleString() : '-') + '</td>';
            html += '<td class="failed">' + (job.failed_count || 0) + '</td>';
            html += '<td>' + (job.duration || '-') + '</td>';
            html += '<td>' + (job.records_per_second ? job.records_per_second.toFixed(1) + '/s' : '-') + '</td>';
            html += '<td>' + (job.executed_by ? escapeHtml(job.executed_by) : '-') + '</td>';
            html += '<td class="log-id">' + (job.job_log_id || '-') + '</td></tr>';
            if (job.error_message) html += '<tr class="error-row"><td colspan="12"><span class="error-message">' + escapeHtml(job.error_message) + '</span></td></tr>';
        });
        html += '</tbody></table>';
        }
    }
    body.innerHTML = html;
}

// ============================================================================
// Tree Toggle Functions - BIDATA Style
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
                otherYear.querySelector('.year-header .expand-icon').textContent = '▶';
                otherYear.querySelectorAll('.month-details').forEach(function(md) { md.style.display = 'none'; });
                otherYear.querySelectorAll('.month-row .expand-icon').forEach(function(mi) { mi.textContent = '▶'; });
            }
        });
        content.querySelectorAll('.month-details').forEach(function(md) { md.style.display = 'none'; });
        content.querySelectorAll('.month-row .expand-icon').forEach(function(mi) { mi.textContent = '▶'; });
    }
    content.style.display = isOpening ? 'block' : 'none';
    icon.textContent = isOpening ? '▼' : '▶';
}

function toggleMonthGroup(row) {
    var tbody = row.closest('tbody.month-group');
    var detailsRow = tbody.querySelector('.month-details');
    var icon = row.querySelector('.expand-icon');
    var isOpen = detailsRow.style.display !== 'none';
    
    if (!isOpen) {
        var yearContent = tbody.closest('.year-content');
        yearContent.querySelectorAll('.month-details').forEach(function(md) { md.style.display = 'none'; });
        yearContent.querySelectorAll('.month-row .expand-icon').forEach(function(mi) { mi.textContent = '▶'; });
    }
    detailsRow.style.display = isOpen ? 'none' : 'table-row';
    icon.textContent = isOpen ? '▶' : '▼';
    
    if (!isOpen) {
        var contentDiv = detailsRow.querySelector('.month-details-content');
        if (contentDiv && contentDiv.querySelector('.loading')) {
            loadMonthDays(contentDiv.getAttribute('data-year'), contentDiv.getAttribute('data-month'), contentDiv);
        }
    }
}

function loadMonthDays(year, month, container) {
    engineFetch('/api/jobflow/history-month?year=' + year + '&month=' + month)
        .then(function(data) {
            if (!data) return;
            if (data.error) { container.innerHTML = '<div class="no-activity">Error loading data</div>'; return; }
            renderMonthDays(container, data.days || []);
        })
        .catch(function(err) { container.innerHTML = '<div class="no-activity">Failed to load: ' + err.message + '</div>'; });
}

// ============================================================================
// Slideout & Modal Functions
// ============================================================================
function openSlideout() { document.getElementById('flow-slideout').classList.add('open'); }
function closeSlideout() { document.getElementById('flow-slideout').classList.remove('open'); }
function openPendingQueueSlideout() {
    document.getElementById('slideout-title').textContent = 'Pending Queue';
    renderPendingJobs(currentPendingData);
    openSlideout();
}

function openAdhocSlideout() {
    document.getElementById('slideout-title').textContent = 'Ad Hoc Jobs - Today';
    renderAdhocDetails(currentAdhocData);
    openSlideout();
}

function renderAdhocDetails(jobs) {
    var body = document.getElementById('slideout-body');
    
    if (!jobs || jobs.length === 0) {
        body.innerHTML = '<div class="no-activity">No ad hoc jobs today</div>';
        return;
    }
    
    var completedCount = jobs.filter(function(j) { return !j.is_failed; }).length;
    var failedCount = jobs.filter(function(j) { return j.is_failed; }).length;
    
    var html = '<div class="slideout-summary">';
    html += '<div class="slideout-stat"><div class="slideout-stat-label">Total</div><div class="slideout-stat-value">' + jobs.length + '</div></div>';
    html += '<div class="slideout-stat"><div class="slideout-stat-label">Succeeded</div><div class="slideout-stat-value success">' + completedCount + '</div></div>';
    html += '<div class="slideout-stat"><div class="slideout-stat-label">Failed</div><div class="slideout-stat-value failed">' + failedCount + '</div></div>';
    html += '</div>';
    
    html += '<div class="slideout-section-title">Jobs (' + jobs.length + ')</div>';
    html += '<table class="jobs-table"><thead><tr><th></th><th>#</th><th>Job</th><th>Start</th><th>End</th><th>Total</th><th>Success</th><th>Failed</th><th>Duration</th><th>Rate</th><th>User</th><th>Log ID</th></tr></thead><tbody>';
    
    jobs.forEach(function(job) {
        var statusLabel = job.is_failed ? 'FAILED' : 'SUCCESS';
        var statusClass = job.is_failed ? 'failed' : 'success';
        var jobTitle = job.job_full_name ? escapeHtml(job.job_full_name) : '';
        
        html += '<tr>';
        html += '<td><span class="job-status-badge ' + statusClass + '">' + statusLabel + '</span></td>';
        html += '<td class="exec-order">-</td>';
        html += '<td title="' + jobTitle + '">' + escapeHtml(job.job_name) + '</td>';
        html += '<td>' + (job.start_time || '-') + '</td>';
        html += '<td>' + (job.end_time || '-') + '</td>';
        html += '<td>' + (job.total_records !== null ? job.total_records.toLocaleString() : '-') + '</td>';
        html += '<td class="success">' + (job.succeeded_count !== null ? job.succeeded_count.toLocaleString() : '-') + '</td>';
        html += '<td class="failed">' + (job.failed_count || 0) + '</td>';
        html += '<td>' + (job.duration || '-') + '</td>';
        html += '<td>' + (job.records_per_second ? job.records_per_second.toFixed(1) + '/s' : '-') + '</td>';
        html += '<td>' + (job.executed_by ? escapeHtml(job.executed_by) : '-') + '</td>';
        html += '<td class="log-id">' + (job.job_log_id || '-') + '</td>';
        html += '</tr>';
        
        if (job.error_message) {
            html += '<tr class="error-row"><td colspan="12"><span class="error-message">' + escapeHtml(job.error_message) + '</span></td></tr>';
        }
    });
    
    html += '</tbody></table>';
    body.innerHTML = html;
}
function openTasksModal() { 
    document.getElementById('tasks-modal-overlay').classList.remove('hidden'); 
    loadAppTasks(); 
}
function closeTasksModal() { 
    appTasksPendingChanges = {};
    document.getElementById('tasks-modal-overlay').classList.add('hidden'); 
}

// ============================================================================
// Utility Functions
// ============================================================================
function updateTimestamp() { document.getElementById('last-update').textContent = new Date().toLocaleTimeString('en-US', { hour12: false }); }
function showError(message) { var el = document.getElementById('connection-error'); el.textContent = message; el.style.display = 'block'; }
function clearError() { document.getElementById('connection-error').style.display = 'none'; }
function escapeHtml(text) { if (!text) return ''; var div = document.createElement('div'); div.textContent = text; return div.innerHTML; }
function formatShortDate(dateStr) { if (!dateStr) return '-'; var d = new Date(dateStr); return (d.getMonth() + 1) + '/' + d.getDate(); }
function formatDisplayDate(dateStr) {
    if (!dateStr) return '-';
    // Parse YYYY-MM-DD manually to avoid timezone issues
    var parts = dateStr.split('-');
    if (parts.length !== 3) return dateStr;
    var year = parseInt(parts[0], 10);
    var month = parseInt(parts[1], 10);
    var day = parseInt(parts[2], 10);
    return monthNames[month] + ' ' + day + ', ' + year;
}

// ============================================================================
// ConfigSync Modal
// Flow configuration viewer and drift resolution tool
// ============================================================================
var configSyncData = null;        // Cached API response
var configSyncSelectedFlow = null; // Currently selected flow object
var configSyncTaskSchedule = null; // Task Scheduler data for selected flow

function openConfigSyncModal() {
    document.getElementById('configsync-modal-overlay').classList.remove('hidden');
    document.getElementById('configsync-body').innerHTML = '<div class="loading">Loading flow configurations...</div>';
    document.getElementById('configsync-footer-actions').innerHTML = '';
    loadConfigSyncData();
}

function closeConfigSyncModal() {
    document.getElementById('configsync-modal-overlay').classList.add('hidden');
    configSyncData = null;
    configSyncSelectedFlow = null;
    configSyncTaskSchedule = null;
}

function loadConfigSyncData() {
    engineFetch('/api/jobflow/configsync')
        .then(function(data) {
            if (!data) return;
            if (data.error) {
                document.getElementById('configsync-body').innerHTML = '<div class="cs-error">Error: ' + escapeHtml(data.error) + '</div>';
                return;
            }
            configSyncData = data;
            renderConfigSyncSelector(data);
        })
        .catch(function(err) {
            document.getElementById('configsync-body').innerHTML = '<div class="cs-error">Failed to load: ' + escapeHtml(err.message) + '</div>';
        });
}

function renderConfigSyncSelector(data) {
    var select = document.getElementById('configsync-flow-select');
    if (!select) return;
    
    var html = '<option value="">-- Select a flow --</option>';
    
    // Misaligned flows first with warning indicator
    var hasMisaligned = false;
    data.flows.forEach(function(flow) {
        if (flow.misalignment_type) {
            if (!hasMisaligned) {
                html += '<optgroup label="&#9888; Needs Attention">';
                hasMisaligned = true;
            }
            var label = '\u26A0 ' + escapeHtml(flow.flow_code);
            if (flow.misalignment_type === 'NEW') label += ' \u2014 New Flow';
            else if (flow.misalignment_type === 'DEACTIVATED') label += ' \u2014 Deactivated in DM';
            else if (flow.misalignment_type === 'REACTIVATED') label += ' \u2014 Reactivated in DM';
            html += '<option value="' + flow.config_id + '">' + label + '</option>';
        }
    });
    if (hasMisaligned) html += '</optgroup>';
    
    // Aligned flows grouped by status
    var activeFlows = data.flows.filter(function(f) { return !f.misalignment_type && f.dm_is_active !== false; });
    var inactiveFlows = data.flows.filter(function(f) { return !f.misalignment_type && f.dm_is_active === false; });
    
    if (activeFlows.length > 0) {
        html += '<optgroup label="Active Flows">';
        activeFlows.forEach(function(flow) {
            html += '<option value="' + flow.config_id + '">' + escapeHtml(flow.flow_code) + ' \u2014 ' + escapeHtml(flow.expected_schedule) + '</option>';
        });
        html += '</optgroup>';
    }
    
    if (inactiveFlows.length > 0) {
        html += '<optgroup label="Inactive Flows">';
        inactiveFlows.forEach(function(flow) {
            html += '<option value="' + flow.config_id + '">' + escapeHtml(flow.flow_code) + ' \u2014 inactive</option>';
        });
        html += '</optgroup>';
    }
    
    select.innerHTML = html;
    
    // Show summary in body
    var body = document.getElementById('configsync-body');
    if (data.misaligned_count > 0) {
        body.innerHTML = '<div class="cs-summary-banner cs-warning">' +
            '<span class="cs-banner-icon">&#9888;</span> ' +
            data.misaligned_count + ' flow' + (data.misaligned_count > 1 ? 's' : '') + ' need' + (data.misaligned_count === 1 ? 's' : '') + ' attention. Select a flow above to review.' +
            '</div>';
    } else {
        body.innerHTML = '<div class="cs-summary-banner cs-healthy">' +
            '<span class="cs-banner-icon">&#10004;</span> All flows are aligned between DM and xFACts. Select any flow to view its configuration.' +
            '</div>';
    }
    document.getElementById('configsync-footer-actions').innerHTML = '';
}

function onConfigSyncFlowSelected() {
    var select = document.getElementById('configsync-flow-select');
    var configId = parseInt(select.value, 10);
    configSyncTaskSchedule = null;
    
    if (!configId || !configSyncData) {
        renderConfigSyncSelector(configSyncData);
        return;
    }
    
    var flow = null;
    for (var i = 0; i < configSyncData.flows.length; i++) {
        if (configSyncData.flows[i].config_id === configId) {
            flow = configSyncData.flows[i];
            break;
        }
    }
    
    if (!flow) return;
    configSyncSelectedFlow = flow;
    
    if (flow.misalignment_type) {
        renderConfigSyncEditable(flow);
    } else {
        renderConfigSyncReadOnly(flow);
    }
}

// ============================================================================
// Read-Only View (aligned flows)
// ============================================================================
function renderConfigSyncReadOnly(flow) {
    var body = document.getElementById('configsync-body');
    var html = '';
    
    // Flow identity header
    html += '<div class="cs-flow-header">';
    html += '<span class="cs-flow-code">' + escapeHtml(flow.flow_code) + '</span>';
    if (flow.flow_name) html += '<span class="cs-flow-name">' + escapeHtml(flow.flow_name) + '</span>';
    html += '</div>';
    
    // Status badges
    html += '<div class="cs-badges">';
    html += '<span class="cs-badge ' + (flow.dm_is_active ? 'cs-badge-active' : 'cs-badge-inactive') + '">' + (flow.dm_is_active ? 'Active in DM' : 'Inactive in DM') + '</span>';
    html += '<span class="cs-badge ' + (flow.is_monitored ? 'cs-badge-active' : 'cs-badge-inactive') + '">' + (flow.is_monitored ? 'Monitored' : 'Not Monitored') + '</span>';
    html += '<span class="cs-badge cs-badge-neutral">' + escapeHtml(flow.expected_schedule) + '</span>';
    html += '</div>';
    
    // Config section
    html += '<div class="cs-section-header">Monitoring Configuration</div>';
    html += '<div class="cs-detail-grid">';
    html += csDetailRow('Schedule', flow.expected_schedule);
    html += csDetailRow('Monitored', flow.is_monitored ? 'Yes' : 'No');
    html += csDetailRow('Alert on Missing', flow.alert_on_missing ? 'Yes' : 'No');
    html += csDetailRow('Alert on Failure', flow.alert_on_critical_failure ? 'Yes' : 'No');
    html += csDetailRow('Effective From', flow.effective_start_date || '-');
    html += csDetailRow('Effective Until', flow.effective_end_date || 'No expiration');
    if (flow.notes) html += csDetailRow('Notes', flow.notes);
    html += '</div>';
    
    // Schedule section
    if (flow.schedule) {
        html += '<div class="cs-section-header">Schedule Details</div>';
        html += '<div class="cs-detail-grid">';
        html += csDetailRow('Type', flow.schedule.schedule_type);
        html += csDetailRow('Start Time', flow.schedule.expected_start_time || '-');
        html += csDetailRow('Tolerance', flow.schedule.start_time_tolerance_minutes + ' min');
        if (flow.schedule.schedule_frequency) html += csDetailRow('Frequency', 'Every ' + flow.schedule.schedule_frequency + ' hours');
        if (flow.schedule.schedule_day_of_week) html += csDetailRow('Day of Week', csDayName(flow.schedule.schedule_day_of_week));
        if (flow.schedule.schedule_day_of_month) html += csDetailRow('Day of Month', csOrdinal(flow.schedule.schedule_day_of_month));
        if (flow.schedule.schedule_week_of_month) html += csDetailRow('Week of Month', csOrdinal(flow.schedule.schedule_week_of_month));
        html += csDetailRow('Schedule Active', flow.schedule.is_active ? 'Yes' : 'No');
        html += '</div>';
    }
    
    // Audit
    html += '<div class="cs-section-header">Audit</div>';
    html += '<div class="cs-detail-grid">';
    html += csDetailRow('Last DM Sync', flow.dm_last_sync_dttm || 'Never');
    html += csDetailRow('Last Modified', flow.modified_dttm || '-');
    html += csDetailRow('Modified By', flow.modified_by || '-');
    html += '</div>';
    
    body.innerHTML = html;
    document.getElementById('configsync-footer-actions').innerHTML = '';
}

// ============================================================================
// Editable View (misaligned flows)
// ============================================================================
function renderConfigSyncEditable(flow) {
    var body = document.getElementById('configsync-body');
    var html = '';
    
    // Flow identity header
    html += '<div class="cs-flow-header">';
    html += '<span class="cs-flow-code">' + escapeHtml(flow.flow_code) + '</span>';
    if (flow.flow_name) html += '<span class="cs-flow-name">' + escapeHtml(flow.flow_name) + '</span>';
    html += '</div>';
    
    // Issue banner
    if (flow.misalignment_type === 'NEW') {
        html += '<div class="cs-banner cs-banner-new">' +
            '<strong>New Flow Detected</strong><br>' +
            'This flow exists in Debt Manager but hasn\'t been configured in xFACts yet. ' +
            'Choose how this flow should be monitored.' +
            '</div>';
        html += renderNewFlowForm(flow);
    }
    else if (flow.misalignment_type === 'DEACTIVATED') {
        html += '<div class="cs-banner cs-banner-deactivated">' +
            '<strong>Flow Deactivated in DM</strong><br>' +
            'This flow was deactivated in Debt Manager but is still being monitored by xFACts. ' +
            'Recommended action: disable monitoring and end-date the configuration.' +
            '</div>';
        html += renderDeactivateForm(flow);
    }
    else if (flow.misalignment_type === 'REACTIVATED') {
        var prevSchedule = flow.schedule ? flow.schedule.schedule_type : 'unknown';
        var prevTime = flow.schedule ? flow.schedule.expected_start_time : '';
        html += '<div class="cs-banner cs-banner-reactivated">' +
            '<strong>Flow Reactivated in DM</strong><br>' +
            'This flow was reactivated in Debt Manager. Previously scheduled as ' + escapeHtml(prevSchedule) +
            (prevTime ? ' at ' + escapeHtml(prevTime) : '') + '. ' +
            'Review the schedule and re-enable monitoring.' +
            '</div>';
        html += renderReactivateForm(flow);
    }
    
    body.innerHTML = html;
    
    // For NEW flows, auto-query Task Scheduler
    if (flow.misalignment_type === 'NEW') {
        queryTaskSchedule(flow.flow_code);
    } else {
        updateConfigSyncFooter();
    }
}

// ============================================================================
// NEW Flow Form
// ============================================================================
function renderNewFlowForm(flow) {
    var html = '<div id="cs-new-flow-area">';
    html += '<div class="cs-task-loading" id="cs-task-status">' +
        '<span class="cs-spinner"></span> Checking Task Scheduler for ' + escapeHtml(flow.flow_code) + '...' +
        '</div>';
    html += '</div>';
    return html;
}

function queryTaskSchedule(flowCode) {
    engineFetch('/api/jobflow/configsync/task-schedule?flow_code=' + encodeURIComponent(flowCode))
        .then(function(data) {
            if (!data) return;
            if (data.error) {
                document.getElementById('cs-task-status').innerHTML = '<span class="cs-error-text">Error querying Task Scheduler: ' + escapeHtml(data.error) + '</span>';
                return;
            }
            configSyncTaskSchedule = data;
            
            if (data.task_found && data.parsed_schedule && data.parsed_schedule.schedule_type) {
                renderScheduledFlowForm(data.parsed_schedule);
            } else {
                renderNoTaskForm();
            }
        })
        .catch(function(err) {
            document.getElementById('cs-task-status').innerHTML = '<span class="cs-error-text">Failed to query Task Scheduler: ' + escapeHtml(err.message) + '</span>';
        });
}

function renderScheduledFlowForm(parsed) {
    var area = document.getElementById('cs-new-flow-area');
    var html = '<div class="cs-task-found">' +
        '<span class="cs-banner-icon">&#10004;</span> Task Scheduler entry found. Schedule auto-populated below.' +
        '</div>';
    
    html += '<div class="cs-section-header">Schedule Configuration</div>';
    html += '<div class="cs-form-grid">';
    
    // Schedule type
    html += '<div class="cs-form-group">';
    html += '<label>Schedule Type</label>';
    html += '<select id="cs-schedule-type" class="cs-form-control" onchange="onCsScheduleTypeChanged()">';
    var types = ['DAILY', 'WEEKLY', 'MONTHLY', 'EVERY_N_HOURS'];
    types.forEach(function(t) {
        html += '<option value="' + t + '"' + (parsed.schedule_type === t ? ' selected' : '') + '>' + t + '</option>';
    });
    html += '</select></div>';
    
    // Start time
    html += '<div class="cs-form-group">';
    html += '<label>Start Time</label>';
    html += '<input type="time" id="cs-start-time" class="cs-form-control" value="' + (parsed.expected_start_time || '22:00') + '">';
    html += '</div>';
    
    // Tolerance
    html += '<div class="cs-form-group">';
    html += '<label>Tolerance (min)</label>';
    html += '<input type="number" id="cs-tolerance" class="cs-form-control" value="30" min="0" max="240">';
    html += '</div>';
    
    // Frequency (for EVERY_N_HOURS)
    html += '<div class="cs-form-group' + (parsed.schedule_type !== 'EVERY_N_HOURS' ? ' cs-hidden' : '') + '" id="cs-frequency-group">';
    html += '<label>Every N Hours</label>';
    html += '<input type="number" id="cs-frequency" class="cs-form-control" value="' + (parsed.schedule_frequency || 4) + '" min="1" max="24">';
    html += '</div>';
    
    // Day of week (for WEEKLY or MONTHLY DOW)
    var showDow = parsed.schedule_type === 'WEEKLY' || (parsed.schedule_type === 'MONTHLY' && parsed.schedule_week_of_month);
    html += '<div class="cs-form-group' + (!showDow ? ' cs-hidden' : '') + '" id="cs-dow-group">';
    html += '<label>Day of Week</label>';
    html += '<select id="cs-day-of-week" class="cs-form-control">';
    var days = [['1','Sunday'],['2','Monday'],['3','Tuesday'],['4','Wednesday'],['5','Thursday'],['6','Friday'],['7','Saturday']];
    days.forEach(function(d) {
        html += '<option value="' + d[0] + '"' + (parsed.schedule_day_of_week == d[0] ? ' selected' : '') + '>' + d[1] + '</option>';
    });
    html += '</select></div>';
    
    // Day of month (for MONTHLY by date)
    var showDom = parsed.schedule_type === 'MONTHLY' && parsed.schedule_day_of_month && !parsed.schedule_week_of_month;
    html += '<div class="cs-form-group' + (!showDom ? ' cs-hidden' : '') + '" id="cs-dom-group">';
    html += '<label>Day of Month</label>';
    html += '<input type="number" id="cs-day-of-month" class="cs-form-control" value="' + (parsed.schedule_day_of_month || 1) + '" min="1" max="31">';
    html += '</div>';
    
    // Week of month (for MONTHLY DOW)
    var showWom = parsed.schedule_type === 'MONTHLY' && parsed.schedule_week_of_month;
    html += '<div class="cs-form-group' + (!showWom ? ' cs-hidden' : '') + '" id="cs-wom-group">';
    html += '<label>Week of Month</label>';
    html += '<select id="cs-week-of-month" class="cs-form-control">';
    var weeks = [['1','1st'],['2','2nd'],['3','3rd'],['4','4th'],['5','5th (last)']];
    weeks.forEach(function(w) {
        html += '<option value="' + w[0] + '"' + (parsed.schedule_week_of_month == w[0] ? ' selected' : '') + '>' + w[1] + '</option>';
    });
    html += '</select></div>';
    
    html += '</div>';  // end form-grid
    
    // Alert settings
    html += '<div class="cs-section-header">Alert Settings</div>';
    html += '<div class="cs-checkbox-row">';
    html += '<label class="cs-checkbox"><input type="checkbox" id="cs-alert-missing" checked> Alert on Missing</label>';
    html += '<label class="cs-checkbox"><input type="checkbox" id="cs-alert-failure" checked> Alert on Failure</label>';
    html += '<label class="cs-checkbox"><input type="checkbox" id="cs-monitored" checked> Monitored</label>';
    html += '</div>';
    
    area.innerHTML = html;
    updateConfigSyncFooter();
}

function renderNoTaskForm() {
    var area = document.getElementById('cs-new-flow-area');
    var html = '<div class="cs-task-not-found">' +
        '<span class="cs-banner-icon">&#8505;</span> No Task Scheduler entry found for this flow. How is it executed?' +
        '</div>';
    
    html += '<div class="cs-chooser">';
    html += '<div class="cs-chooser-option" onclick="selectFlowType(\'VARIABLE\')">';
    html += '<div class="cs-chooser-title">Triggered by External Process</div>';
    html += '<div class="cs-chooser-desc">Initiated by an external system or API call (e.g., SendRight). Monitor for failures only.</div>';
    html += '</div>';
    
    html += '<div class="cs-chooser-option" onclick="selectFlowType(\'ON-DEMAND\')">';
    html += '<div class="cs-chooser-title">Executed Manually in DM</div>';
    html += '<div class="cs-chooser-desc">Run by a human through the DM user interface. No monitoring needed.</div>';
    html += '</div>';
    
    html += '<div class="cs-chooser-option" onclick="selectFlowType(\'SCHEDULED\')">';
    html += '<div class="cs-chooser-title">Runs on a Regular Schedule</div>';
    html += '<div class="cs-chooser-desc">Should have a Task Scheduler entry but doesn\'t yet. Create the scheduled task first, then configure here.</div>';
    html += '</div>';
    html += '</div>';
    
    area.innerHTML = html;
    document.getElementById('configsync-footer-actions').innerHTML = '';
}

function selectFlowType(type) {
    // Highlight selected option
    document.querySelectorAll('.cs-chooser-option').forEach(function(el) { el.classList.remove('cs-selected'); });
    event.currentTarget.classList.add('cs-selected');
    
    if (type === 'VARIABLE') {
        // Show confirmation summary
        var existing = document.getElementById('cs-type-details');
        if (existing) existing.remove();
        
        var details = document.createElement('div');
        details.id = 'cs-type-details';
        details.className = 'cs-type-summary';
        details.innerHTML = '<div class="cs-section-header">Configuration Preview</div>' +
            '<div class="cs-detail-grid">' +
            csDetailRow('Schedule', 'VARIABLE') +
            csDetailRow('Monitored', 'Yes') +
            csDetailRow('Alert on Missing', 'No') +
            csDetailRow('Alert on Failure', 'Yes') +
            '</div>';
        document.getElementById('cs-new-flow-area').appendChild(details);
        
        configSyncSelectedFlow._action = 'configure_new';
        configSyncSelectedFlow._flowType = 'VARIABLE';
        updateConfigSyncFooter();
    }
    else if (type === 'ON-DEMAND') {
        var existing = document.getElementById('cs-type-details');
        if (existing) existing.remove();
        
        var details = document.createElement('div');
        details.id = 'cs-type-details';
        details.className = 'cs-type-summary';
        details.innerHTML = '<div class="cs-section-header">Configuration Preview</div>' +
            '<div class="cs-detail-grid">' +
            csDetailRow('Schedule', 'ON-DEMAND') +
            csDetailRow('Monitored', 'No') +
            csDetailRow('Alert on Missing', 'No') +
            csDetailRow('Alert on Failure', 'No') +
            '</div>';
        document.getElementById('cs-new-flow-area').appendChild(details);
        
        configSyncSelectedFlow._action = 'configure_new';
        configSyncSelectedFlow._flowType = 'ON-DEMAND';
        updateConfigSyncFooter();
    }
    else if (type === 'SCHEDULED') {
        var existing = document.getElementById('cs-type-details');
        if (existing) existing.remove();
        
        var details = document.createElement('div');
        details.id = 'cs-type-details';
        details.className = 'cs-type-summary cs-info-box';
        details.innerHTML = '<span class="cs-banner-icon">&#8505;</span> ' +
            'Create the scheduled task on the app server first, then re-open this dialog. ' +
            'The task should follow the naming convention: <strong>DM Night Job - ' + escapeHtml(configSyncSelectedFlow.flow_code) + '</strong>';
        document.getElementById('cs-new-flow-area').appendChild(details);
        
        configSyncSelectedFlow._action = null;
        configSyncSelectedFlow._flowType = null;
        document.getElementById('configsync-footer-actions').innerHTML = '';
    }
}

function onCsScheduleTypeChanged() {
    var type = document.getElementById('cs-schedule-type').value;
    
    document.getElementById('cs-frequency-group').classList.toggle('cs-hidden', type !== 'EVERY_N_HOURS');
    document.getElementById('cs-dow-group').classList.toggle('cs-hidden', type !== 'WEEKLY' && type !== 'MONTHLY');
    document.getElementById('cs-dom-group').classList.toggle('cs-hidden', type !== 'MONTHLY');
    document.getElementById('cs-wom-group').classList.toggle('cs-hidden', type !== 'MONTHLY');
    
    // If switching to MONTHLY, show DOW + WOM or DOM based on what's populated
    if (type === 'MONTHLY') {
        document.getElementById('cs-dow-group').classList.remove('cs-hidden');
        document.getElementById('cs-wom-group').classList.remove('cs-hidden');
        document.getElementById('cs-dom-group').classList.remove('cs-hidden');
    }
}

// ============================================================================
// DEACTIVATED Flow Form
// ============================================================================
function renderDeactivateForm(flow) {
    var html = '<div class="cs-section-header">Changes to Apply</div>';
    html += '<div class="cs-detail-grid">';
    html += csDetailRow('Set Monitored', 'No');
    html += csDetailRow('Set End Date', 'Today (' + new Date().toISOString().split('T')[0] + ')');
    if (flow.schedule) {
        html += csDetailRow('Schedule', 'Will be deactivated');
    }
    html += '</div>';
    
    configSyncSelectedFlow._action = 'deactivate';
    return html;
}

// ============================================================================
// REACTIVATED Flow Form
// ============================================================================
function renderReactivateForm(flow) {
    var html = '<div class="cs-section-header">Previous Configuration</div>';
    html += '<div class="cs-detail-grid">';
    if (flow.schedule) {
        html += csDetailRow('Schedule Type', flow.schedule.schedule_type);
        html += csDetailRow('Start Time', flow.schedule.expected_start_time || '-');
        html += csDetailRow('Tolerance', flow.schedule.start_time_tolerance_minutes + ' min');
        if (flow.schedule.schedule_day_of_week) html += csDetailRow('Day of Week', csDayName(flow.schedule.schedule_day_of_week));
        if (flow.schedule.schedule_day_of_month) html += csDetailRow('Day of Month', csOrdinal(flow.schedule.schedule_day_of_month));
        if (flow.schedule.schedule_week_of_month) html += csDetailRow('Week of Month', csOrdinal(flow.schedule.schedule_week_of_month));
    }
    html += '</div>';
    
    html += '<div class="cs-section-header">Re-enable Settings</div>';
    html += '<div class="cs-checkbox-row">';
    html += '<label class="cs-checkbox"><input type="checkbox" id="cs-react-monitored" checked> Enable Monitoring</label>';
    html += '</div>';
    
    configSyncSelectedFlow._action = 'reactivate';
    return html;
}

// ============================================================================
// Footer / Save Actions
// ============================================================================
function updateConfigSyncFooter() {
    var footer = document.getElementById('configsync-footer-actions');
    if (!configSyncSelectedFlow) {
        footer.innerHTML = '';
        return;
    }
    
    var flow = configSyncSelectedFlow;
    if (!flow.misalignment_type || !flow._action) {
        footer.innerHTML = '';
        return;
    }
    
    var label = 'Apply Changes';
    if (flow._action === 'deactivate') label = 'Deactivate Flow';
    else if (flow._action === 'reactivate') label = 'Reactivate Flow';
    else if (flow._action === 'configure_new') label = 'Save Configuration';
    
    footer.innerHTML = '<button class="cs-btn cs-btn-primary" onclick="saveConfigSync()">' + label + '</button>';
}

// ============================================================================
// ConfigSync Confirmation Dialog
// Add this function and update the existing saveConfigSync function
// ============================================================================

// NEW FUNCTION - Add this after updateConfigSyncFooter()
function showConfigSyncConfirmation() {
    var flow = configSyncSelectedFlow;
    if (!flow || !flow._action) return;
    
    var html = '<div class="cs-confirm-header">' + escapeHtml(flow.flow_code) + '</div>';
    html += '<div class="cs-confirm-subheader">The following changes will be applied:</div>';
    html += '<div class="cs-confirm-changes">';
    
    if (flow._action === 'configure_new') {
        if (flow._flowType === 'VARIABLE') {
            html += csConfirmRow('Schedule Type', 'VARIABLE');
            html += csConfirmRow('Monitored', 'Yes');
            html += csConfirmRow('Alert on Missing', 'No');
            html += csConfirmRow('Alert on Failure', 'Yes');
        }
        else if (flow._flowType === 'ON-DEMAND') {
            html += csConfirmRow('Schedule Type', 'ON-DEMAND');
            html += csConfirmRow('Monitored', 'No');
            html += csConfirmRow('Alert on Missing', 'No');
            html += csConfirmRow('Alert on Failure', 'No');
        }
        else {
            // Scheduled - read from form
            var schedType = document.getElementById('cs-schedule-type').value;
            var startTime = document.getElementById('cs-start-time').value;
            var tolerance = document.getElementById('cs-tolerance').value;
            var monitored = document.getElementById('cs-monitored').checked;
            var alertMissing = document.getElementById('cs-alert-missing').checked;
            var alertFailure = document.getElementById('cs-alert-failure').checked;
            
            html += csConfirmRow('Schedule Type', schedType);
            html += csConfirmRow('Start Time', startTime);
            html += csConfirmRow('Tolerance', tolerance + ' minutes');
            
            if (schedType === 'EVERY_N_HOURS') {
                html += csConfirmRow('Frequency', 'Every ' + document.getElementById('cs-frequency').value + ' hours');
            }
            if (schedType === 'WEEKLY') {
                var dow = document.getElementById('cs-day-of-week');
                html += csConfirmRow('Day of Week', dow.options[dow.selectedIndex].text);
            }
            if (schedType === 'MONTHLY') {
                var dom = document.getElementById('cs-day-of-month').value;
                var wom = document.getElementById('cs-week-of-month');
                var dow = document.getElementById('cs-day-of-week');
                if (wom.value && dow.value) {
                    html += csConfirmRow('Schedule', wom.options[wom.selectedIndex].text + ' ' + dow.options[dow.selectedIndex].text);
                } else if (dom) {
                    html += csConfirmRow('Day of Month', csOrdinal(parseInt(dom, 10)));
                }
            }
            
            html += csConfirmRow('Monitored', monitored ? 'Yes' : 'No');
            html += csConfirmRow('Alert on Missing', alertMissing ? 'Yes' : 'No');
            html += csConfirmRow('Alert on Failure', alertFailure ? 'Yes' : 'No');
            html += '<div class="cs-confirm-note">A new Schedule row will be created.</div>';
        }
    }
    else if (flow._action === 'deactivate') {
        html += csConfirmRow('Monitored', 'No (was Yes)');
        html += csConfirmRow('Effective End Date', new Date().toISOString().split('T')[0]);
        if (flow.schedule) {
            html += csConfirmRow('Schedule', 'Will be deactivated');
        }
    }
    else if (flow._action === 'reactivate') {
        var monitored = document.getElementById('cs-react-monitored').checked;
        html += csConfirmRow('Monitored', monitored ? 'Yes' : 'No');
        html += csConfirmRow('Effective End Date', 'Cleared');
        if (flow.schedule) {
            html += csConfirmRow('Schedule', 'Will be reactivated');
        }
    }
    
    html += '</div>';
    
    document.getElementById('cs-confirm-body').innerHTML = html;
    document.getElementById('cs-confirm-overlay').classList.remove('hidden');
}

function closeConfigSyncConfirmation() {
    document.getElementById('cs-confirm-overlay').classList.add('hidden');
}

function confirmAndSaveConfigSync() {
    closeConfigSyncConfirmation();
    executeConfigSyncSave();
}

function csConfirmRow(label, value) {
    return '<div class="cs-confirm-row">' +
        '<span class="cs-confirm-label">' + escapeHtml(label) + ':</span> ' +
        '<span class="cs-confirm-value">' + escapeHtml(value) + '</span>' +
        '</div>';
}


// ============================================================================
// REPLACE the existing saveConfigSync function with this one
// (The old one that fires directly becomes executeConfigSyncSave)
// ============================================================================

function saveConfigSync() {
    // Show confirmation dialog instead of saving directly
    showConfigSyncConfirmation();
}

function executeConfigSyncSave() {
    var flow = configSyncSelectedFlow;
    if (!flow || !flow._action) return;
    
    var payload = {
        action: flow._action === 'configure_new' ? 'configure_new' : flow._action,
        config_id: flow.config_id,
        job_sqnc_id: flow.job_sqnc_id,
        flow_code: flow.flow_code
    };
    
    if (flow._action === 'configure_new') {
        if (flow._flowType === 'VARIABLE') {
            payload.expected_schedule = 'VARIABLE';
            payload.is_monitored = true;
            payload.alert_on_missing = false;
            payload.alert_on_critical_failure = true;
        }
        else if (flow._flowType === 'ON-DEMAND') {
            payload.expected_schedule = 'ON-DEMAND';
            payload.is_monitored = false;
            payload.alert_on_missing = false;
            payload.alert_on_critical_failure = false;
        }
        else {
            // Scheduled - read from form fields
            var schedType = document.getElementById('cs-schedule-type').value;
            payload.expected_schedule = schedType;
            payload.is_monitored = document.getElementById('cs-monitored').checked;
            payload.alert_on_missing = document.getElementById('cs-alert-missing').checked;
            payload.alert_on_critical_failure = document.getElementById('cs-alert-failure').checked;
            
            payload.schedule = {
                schedule_type: schedType,
                expected_start_time: document.getElementById('cs-start-time').value + ':00',
                start_time_tolerance_minutes: parseInt(document.getElementById('cs-tolerance').value, 10) || 30
            };
            
            if (schedType === 'EVERY_N_HOURS') {
                payload.schedule.schedule_frequency = parseInt(document.getElementById('cs-frequency').value, 10) || 4;
            }
            if (schedType === 'WEEKLY' || schedType === 'MONTHLY') {
                var dow = document.getElementById('cs-day-of-week').value;
                if (dow) payload.schedule.schedule_day_of_week = parseInt(dow, 10);
            }
            if (schedType === 'MONTHLY') {
                var dom = document.getElementById('cs-day-of-month').value;
                var wom = document.getElementById('cs-week-of-month').value;
                if (dom) payload.schedule.schedule_day_of_month = parseInt(dom, 10);
                if (wom) payload.schedule.schedule_week_of_month = parseInt(wom, 10);
            }
        }
    }
    else if (flow._action === 'reactivate') {
        payload.is_monitored = document.getElementById('cs-react-monitored').checked;
    }
    
    // Disable button during save
    var btn = document.querySelector('#configsync-footer-actions .cs-btn-primary');
    if (btn) { btn.disabled = true; btn.textContent = 'Saving...'; }
    
    engineFetch('/api/jobflow/configsync/save', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload)
    })
    .then(function(data) {
        if (!data) return;
        if (data.error) {
            alert('Save failed: ' + data.error);
            if (btn) { btn.disabled = false; btn.textContent = 'Retry'; }
            return;
        }
        
        // Show success and reload
        var body = document.getElementById('configsync-body');
        body.innerHTML = '<div class="cs-summary-banner cs-healthy">' +
            '<span class="cs-banner-icon">&#10004;</span> ' +
            escapeHtml(flow.flow_code) + ' updated successfully.' +
            '</div>';
        document.getElementById('configsync-footer-actions').innerHTML = '';
        
        // Refresh data after brief pause
        setTimeout(function() {
            loadConfigSyncData();
            // Also refresh the process status cards
            loadProcessStatus();
        }, 1500);
    })
    .catch(function(err) {
        alert('Save failed: ' + err.message);
        if (btn) { btn.disabled = false; btn.textContent = 'Retry'; }
    });
}

// ============================================================================
// ConfigSync Helper Functions
// ============================================================================
function csDetailRow(label, value) {
    return '<div class="cs-detail-label">' + escapeHtml(label) + '</div>' +
           '<div class="cs-detail-value">' + escapeHtml(value || '-') + '</div>';
}

function csDayName(num) {
    var names = { 1: 'Sunday', 2: 'Monday', 3: 'Tuesday', 4: 'Wednesday', 5: 'Thursday', 6: 'Friday', 7: 'Saturday' };
    return names[num] || num;
}

function csOrdinal(num) {
    var suffix = 'th';
    if (num === 1 || num === 21 || num === 31) suffix = 'st';
    else if (num === 2 || num === 22) suffix = 'nd';
    else if (num === 3 || num === 23) suffix = 'rd';
    return num + suffix;
}
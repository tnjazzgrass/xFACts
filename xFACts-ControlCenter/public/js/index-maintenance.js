// ============================================================================
// xFACts Control Center - Index Maintenance JavaScript
// Location: E:\xFACts-ControlCenter\static\js\index-maintenance.js
// Version: Tracked in dbo.System_Metadata (component: ServerOps.Index)
// ============================================================================

// ============================================================================
// CONFIGURATION
// ============================================================================

// Engine events — process map for shared WebSocket module (engine-events.js)
// NOTE: These processes are not yet registered in the Orchestrator. Engine
// cards will remain in disabled state until processes are registered and
// sending events. See backlog for orchestration design session.
var ENGINE_PROCESSES = {
    'Sync-IndexRegistry':       { slug: 'sync'},
    'Scan-IndexFragmentation':  { slug: 'scan'},
    'Execute-IndexMaintenance': { slug: 'execute'},
    'Update-IndexStatistics':   { slug: 'stats'}
};

// Live polling (Refresh Architecture)
var PAGE_REFRESH_INTERVAL = 5;    // Default; overridden by GlobalConfig on load

// Page hooks for engine-events.js shared module
function onPageResumed() { pageRefresh(); }
function onSessionExpired() { stopPolling(); }
var livePollingTimer = null;
var pageLoadDate = new Date().toDateString();

// ----------------------------------------------------------------------------
// State
// ----------------------------------------------------------------------------
let consecutiveErrors = 0;
let currentScheduleDatabaseId = null;
let currentScheduleDatabaseName = null;

// Drag selection state for schedule
let isDragging = false;
let dragStartCell = null;
let dragSelectedCells = [];
let dragTargetValue = null;
let dragScheduleType = null;

// ----------------------------------------------------------------------------
// Utility Functions
// ----------------------------------------------------------------------------
function formatDuration(seconds) {
    if (seconds === null || seconds === undefined) return '-';
    if (seconds < 60) return `${Math.round(seconds)}s`;
    if (seconds < 3600) {
        const mins = Math.floor(seconds / 60);
        const secs = Math.round(seconds % 60);
        return `${mins}m ${secs}s`;
    }
    const hours = Math.floor(seconds / 3600);
    const mins = Math.floor((seconds % 3600) / 60);
    return `${hours}h ${mins}m`;
}

function formatDurationMs(ms) {
    if (ms === null || ms === undefined) return '-';
    if (ms < 1000) return `${ms}ms`;
    return formatDuration(ms / 1000);
}

function formatNumber(num) {
    if (num === null || num === undefined) return '-';
    return num.toLocaleString();
}

function formatTimeAgo(seconds) {
    if (seconds === null || seconds === undefined) return '-';
    if (seconds < 60) return 'just now';
    if (seconds < 3600) return `${Math.floor(seconds / 60)}m ago`;
    if (seconds < 86400) return `${Math.floor(seconds / 3600)}h ${Math.floor((seconds % 3600) / 60)}m ago`;
    return `${Math.floor(seconds / 86400)}d ago`;
}

function formatDateTime(dateStr) {
    if (!dateStr) return '-';
    const date = new Date(dateStr);
    return date.toLocaleString();
}

function formatDateShort(dateStr) {
    if (!dateStr) return '-';
    const date = new Date(dateStr);
    const now = new Date();
    const diffMs = now - date;
    const diffDays = Math.floor(diffMs / (1000 * 60 * 60 * 24));
    
    if (diffDays === 0) {
        return date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    } else if (diffDays === 1) {
        return 'Yesterday';
    } else if (diffDays < 7) {
        return `${diffDays}d ago`;
    } else {
        return date.toLocaleDateString();
    }
}

function showError(message) {
    const errorDiv = document.getElementById('connection-error');
    errorDiv.textContent = message;
    errorDiv.classList.add('visible');
}

function clearError() {
    const errorDiv = document.getElementById('connection-error');
    errorDiv.classList.remove('visible');
}

function updateLastUpdate() {
    document.getElementById('last-update').textContent = new Date().toLocaleTimeString();
}

// ----------------------------------------------------------------------------
// Slideout Panel Functions
// ----------------------------------------------------------------------------
function openPanel(panelId) {
    document.getElementById(panelId + '-overlay').classList.add('open');
    document.getElementById(panelId + '-panel').classList.add('open');
}

function closePanel(panelId) {
    document.getElementById(panelId + '-overlay').classList.remove('open');
    document.getElementById(panelId + '-panel').classList.remove('open');
}

function closeQueuePanel() { closePanel('queue'); }
function closeSyncPanel() { closePanel('sync'); }
function closeScanPanel() { closePanel('scan'); }
function closeExecutePanel() { closePanel('execute'); }
function closeStatsPanel() { closePanel('stats'); }
function closeSchedulePanel() { 
    closePanel('schedule'); 
    currentScheduleDatabaseId = null;
    currentScheduleDatabaseName = null;
}

// ----------------------------------------------------------------------------
// Live Activity Widget
// ----------------------------------------------------------------------------
async function loadLiveActivity() {
    try {
        const data = await engineFetch('/api/index/live-activity');
        if (!data) return;
        
        const container = document.getElementById('live-activity');
        
        if (data.IsRunning && data.RunningProcesses.length > 0) {
            let html = '<div class="activity-stack">';
            
            for (const proc of data.RunningProcesses) {
                html += `
                    <div class="activity-widget running">
                        <div class="activity-header">
                            <div class="activity-title">${proc.ProcessName}</div>
                            <span class="activity-badge running"><span class="spinning-gear">&#9881;</span> Running</span>
                        </div>
                        <div class="activity-stats">
                            <div class="activity-stat">
                                <span class="label">Elapsed:</span>
                                <span class="value">${formatDuration(proc.ElapsedSeconds)}</span>
                            </div>
                            <div class="activity-stat">
                                <span class="label">Completed:</span>
                                <span class="value">${formatNumber(proc.CompletedCount)} indexes</span>
                            </div>
                        </div>
                    </div>
                `;
            }
            
            html += '</div>';
            container.innerHTML = html;
        } else if (data.LastActivity) {
            const la = data.LastActivity;
            const badgeClass = la.LastStatus === 'SUCCESS' ? 'success' : 
                              la.LastStatus === 'FAILED' ? 'failed' : 
                              la.LastStatus === 'PARTIAL' ? 'partial' : 'unknown';
            const widgetClass = la.LastStatus === 'FAILED' ? 'idle-failed' :
                               la.LastStatus === 'PARTIAL' ? 'idle-partial' : '';
            
            container.innerHTML = `
                <div class="activity-widget ${widgetClass}">
                    <div class="activity-header">
                        <div class="activity-title">Last Activity</div>
                        <span class="activity-badge ${badgeClass}">${la.LastStatus}</span>
                    </div>
                    <div class="activity-stats">
                        <div class="activity-stat">
                            <span class="value">${la.ProcessName}</span>
                            <span class="label">completed ${formatTimeAgo(la.SecondsAgo)}</span>
                        </div>
                        <div class="activity-stat">
                            <span class="label">Duration:</span>
                            <span class="value">${formatDuration(la.DurationSeconds)}</span>
                        </div>
                    </div>
                </div>
            `;
        } else {
            container.innerHTML = '<div class="no-active">No activity recorded</div>';
        }
        
        clearError();
        consecutiveErrors = 0;
    } catch (error) {
        console.error('Error loading live activity:', error);
        consecutiveErrors++;
        if (consecutiveErrors >= 3) {
            showError('Connection lost. Retrying...');
        }
    }
}

// ----------------------------------------------------------------------------
// Process Status Cards
// ----------------------------------------------------------------------------
async function loadProcessStatus() {
    try {
        const processes = await engineFetch('/api/index/process-status');
        if (!processes) return;
        
        const container = document.getElementById('process-status');
        
        if (!processes || processes.length === 0) {
            container.innerHTML = '<div class="loading">No process data available</div>';
            return;
        }
        
        const processDescriptions = {
            'SYNC': 'Registry Sync',
            'SCAN': 'Frag Scan',
            'EXECUTE': 'Rebuild',
            'STATS': 'Stats Update'
        };
        
        const processMetricLabels = {
            'SYNC': { processed: 'Updated', added: 'New', skipped: 'Dropped' },
            'SCAN': { processed: 'Scanned', added: 'Queued', skipped: 'Removed' },
            'EXECUTE': { processed: 'Rebuilt', added: 'Succeeded', skipped: 'Deferred' },
            'STATS': { processed: 'Evaluated', added: 'Updated', skipped: 'Skipped' }
        };
        
        const badgeLabels = {
            'SYNC': 'Sync',
            'SCAN': 'Scan',
            'EXECUTE': 'Execute',
            'STATS': 'Stats'
        };
        
        let html = '';
        
        for (const proc of processes) {
            const statusClass = proc.LastStatus ? proc.LastStatus.toLowerCase().replace('_', '-') : '';
            const labels = processMetricLabels[proc.ProcessName] || { processed: 'Processed', added: 'Added', skipped: 'Skipped' };
            const clickHandler = getProcessClickHandler(proc.ProcessName);
            
            // Admin launch badge (only rendered for admin users)
            const badge = window.isAdmin
                ? `<div class="admin-launch-badge" onclick="event.stopPropagation(); confirmLaunch('${proc.ProcessName}')" title="Launch ${badgeLabels[proc.ProcessName] || proc.ProcessName}">${badgeLabels[proc.ProcessName] || proc.ProcessName}</div>`
                : '';
            
            html += `
                <div class="process-card clickable ${statusClass}" onclick="${clickHandler}">
                    <div class="process-header">
                        <span class="process-name">${processDescriptions[proc.ProcessName] || proc.ProcessName}</span>
                        <span class="process-status ${statusClass}">${proc.LastStatus || 'N/A'}</span>
                    </div>
                    <div class="process-metrics">
                        <div class="process-metric">
                            <span class="label">Last Run</span>
                            <span class="value">${formatDateShort(proc.CompletedDttm)}</span>
                        </div>
                        <div class="process-metric">
                            <span class="label">${labels.processed}</span>
                            <span class="value">${formatNumber(proc.ItemsProcessed)}</span>
                        </div>
                        <div class="process-metric">
                            <span class="label">Duration</span>
                            <span class="value">${formatDuration(proc.DurationSeconds)}</span>
                        </div>
                    </div>
                    ${badge}
                </div>
            `;
        }
        
        container.innerHTML = html;
        updateLastUpdate();
    } catch (error) {
        console.error('Error loading process status:', error);
    }
}

function getProcessClickHandler(processName) {
    switch (processName) {
        case 'SYNC': return 'openSyncDetails()';
        case 'SCAN': return 'openScanDetails()';
        case 'EXECUTE': return 'openExecuteDetails()';
        case 'STATS': return 'openStatsDetails()';
        default: return '';
    }
}

// ----------------------------------------------------------------------------
// Admin: Manual Process Launch
// ----------------------------------------------------------------------------
const launchLabels = { 'SYNC': 'Registry Sync', 'SCAN': 'Frag Scan', 'EXECUTE': 'Rebuild', 'STATS': 'Stats Update' };

function confirmLaunch(processName) {
    const label = launchLabels[processName] || processName;
    document.getElementById('launch-modal-body').innerHTML =
        `<div style="font-size:14px; margin-bottom:8px;">Launch <strong>${label}</strong>?</div>` +
        `<div style="font-size:11px; color:#888;">This will execute with the -Execute flag.</div>`;
    document.getElementById('launch-modal-footer').innerHTML =
        `<button class="btn btn-secondary btn-sm" onclick="closeLaunchModal()">Cancel</button>` +
        `<button class="btn btn-primary btn-sm" onclick="executeLaunch('${processName}')">Launch</button>`;
    document.getElementById('launch-modal').classList.remove('hidden');
}

function closeLaunchModal() {
    document.getElementById('launch-modal').classList.add('hidden');
}

async function executeLaunch(processName) {
    const footer = document.getElementById('launch-modal-footer');
    footer.innerHTML = '<button class="btn btn-secondary btn-sm" disabled>Launching...</button>';
    try {
        const result = await engineFetch('/api/index/launch-process', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ Process: processName })
        });
        if (!result) return;
        if (result.Error) {
            document.getElementById('launch-modal-body').innerHTML =
                `<div style="color:#f14c4c;">${result.Error}</div>`;
        } else {
            document.getElementById('launch-modal-body').innerHTML =
                `<div style="color:#4ec9b0;">&#10003; ${result.Message}</div>`;
        }
        footer.innerHTML = '<button class="btn btn-secondary btn-sm" onclick="closeLaunchModal()">Close</button>';
    } catch (err) {
        document.getElementById('launch-modal-body').innerHTML =
            `<div style="color:#f14c4c;">Failed: ${err.message}</div>`;
        footer.innerHTML = '<button class="btn btn-secondary btn-sm" onclick="closeLaunchModal()">Close</button>';
    }
}

// ----------------------------------------------------------------------------
// Process Detail Slideouts
// ----------------------------------------------------------------------------
async function openSyncDetails() {
    openPanel('sync');
    const body = document.getElementById('sync-panel-body');
    body.innerHTML = '<div class="loading">Loading...</div>';
    
    try {
        const data = await engineFetch('/api/index/sync-details');
        if (!data) return;
        
        let html = '';
        
        // Summary section
        html += `
            <div class="slideout-section">
                <div class="slideout-section-title">Run Summary</div>
                <div class="slideout-summary">
                    <div class="slideout-stat">
                        <div class="slideout-stat-value">${formatNumber(data.Summary.TotalUpdated)}</div>
                        <div class="slideout-stat-label">Updated</div>
                    </div>
                    <div class="slideout-stat">
                        <div class="slideout-stat-value">${formatNumber(data.Summary.TotalAdded)}</div>
                        <div class="slideout-stat-label">New</div>
                    </div>
                    <div class="slideout-stat">
                        <div class="slideout-stat-value">${formatNumber(data.Summary.TotalDropped)}</div>
                        <div class="slideout-stat-label">Dropped</div>
                    </div>
                </div>
                <div style="font-size: 12px; color: #888; margin-bottom: 10px;">
                    Run: ${formatDateTime(data.Summary.StartedDttm)} | Duration: ${formatDuration(data.Summary.DurationSeconds)}
                </div>
            </div>
        `;
        
        // By database section
        if (data.ByDatabase && data.ByDatabase.length > 0) {
            html += `
                <div class="slideout-section">
                    <div class="slideout-section-title">By Database</div>
                    <table class="slideout-table">
                        <thead>
                            <tr>
                                <th>Server</th>
                                <th>Database</th>
                                <th>Updated</th>
                                <th>New</th>
                                <th>Dropped</th>
                            </tr>
                        </thead>
                        <tbody>
            `;
            for (const db of data.ByDatabase) {
                html += `
                    <tr>
                        <td>${db.ServerName}</td>
                        <td>${db.DatabaseName}</td>
                        <td>${formatNumber(db.ItemsProcessed)}</td>
                        <td>${formatNumber(db.ItemsAdded)}</td>
                        <td>${formatNumber(db.ItemsSkipped)}</td>
                    </tr>
                `;
            }
            html += '</tbody></table></div>';
        }
        
        // Added indexes section
        if (data.AddedIndexes && data.AddedIndexes.length > 0) {
            html += `
                <div class="slideout-section">
                    <div class="slideout-section-title">Newly Discovered Indexes</div>
                    <table class="slideout-table">
                        <thead>
                            <tr>
                                <th>Database</th>
                                <th>Table</th>
                                <th>Index</th>
                            </tr>
                        </thead>
                        <tbody>
            `;
            for (const idx of data.AddedIndexes) {
                html += `
                    <tr>
                        <td>${idx.DatabaseName}</td>
                        <td>${idx.TableName}</td>
                        <td>${idx.IndexName}</td>
                    </tr>
                `;
            }
            html += '</tbody></table></div>';
        }
        
        // Dropped indexes section
        if (data.DroppedIndexes && data.DroppedIndexes.length > 0) {
            html += `
                <div class="slideout-section">
                    <div class="slideout-section-title">Dropped Indexes Detected</div>
                    <table class="slideout-table">
                        <thead>
                            <tr>
                                <th>Database</th>
                                <th>Table</th>
                                <th>Index</th>
                            </tr>
                        </thead>
                        <tbody>
            `;
            for (const idx of data.DroppedIndexes) {
                html += `
                    <tr>
                        <td>${idx.DatabaseName}</td>
                        <td>${idx.TableName}</td>
                        <td>${idx.IndexName}</td>
                    </tr>
                `;
            }
            html += '</tbody></table></div>';
        }
        
        if (!data.ByDatabase?.length && !data.AddedIndexes?.length && !data.DroppedIndexes?.length) {
            html += '<div class="slideout-empty">No detailed data available for last run</div>';
        }
        
        body.innerHTML = html;
    } catch (error) {
        body.innerHTML = `<div class="slideout-empty">Error loading sync details: ${error.message}</div>`;
    }
}

async function openScanDetails() {
    openPanel('scan');
    const body = document.getElementById('scan-panel-body');
    body.innerHTML = '<div class="loading">Loading...</div>';
    
    try {
        const data = await engineFetch('/api/index/scan-details');
        if (!data) return;
        
        let html = '';
        
        // Summary section
        html += `
            <div class="slideout-section">
                <div class="slideout-section-title">Run Summary</div>
                <div class="slideout-summary">
                    <div class="slideout-stat">
                        <div class="slideout-stat-value">${formatNumber(data.Summary.TotalScanned)}</div>
                        <div class="slideout-stat-label">Scanned</div>
                    </div>
                    <div class="slideout-stat">
                        <div class="slideout-stat-value">${formatNumber(data.Summary.TotalQueued)}</div>
                        <div class="slideout-stat-label">Queued</div>
                    </div>
                    <div class="slideout-stat">
                        <div class="slideout-stat-value">${formatNumber(data.Summary.TotalRemoved)}</div>
                        <div class="slideout-stat-label">Removed</div>
                    </div>
                </div>
                <div style="font-size: 12px; color: #888; margin-bottom: 10px;">
                    Run: ${formatDateTime(data.Summary.StartedDttm)} | Duration: ${formatDuration(data.Summary.DurationSeconds)}
                </div>
            </div>
        `;
        
        // Scanned indexes - sorted by fragmentation descending
        if (data.ScannedIndexes && data.ScannedIndexes.length > 0) {
            html += `
                <div class="slideout-section">
                    <div class="slideout-section-title">Fragmentation Found (${data.ScannedIndexes.length} indexes)</div>
                    <table class="slideout-table">
                        <thead>
                            <tr>
                                <th>Server</th>
                                <th>Database</th>
                                <th>Index</th>
                                <th>Frag%</th>
                                <th>Pages</th>
                                <th style="text-align:center;">Queued</th>
                            </tr>
                        </thead>
                        <tbody>
            `;
            for (const idx of data.ScannedIndexes) {
                const fragPct = parseFloat(idx.FragmentationPct) || 0;
                const queuedIndicator = idx.WasQueued ? '<span style="color:#4ec9b0;">&#10004;</span>' : '';
                html += `
                    <tr>
                        <td>${idx.ServerName}</td>
                        <td>${idx.DatabaseName}</td>
                        <td title="${idx.SchemaName}.${idx.TableName}">${idx.IndexName}</td>
                        <td>${fragPct.toFixed(1)}%</td>
                        <td>${formatNumber(idx.PageCount)}</td>
                        <td style="text-align:center;">${queuedIndicator}</td>
                    </tr>
                `;
            }
            html += '</tbody></table></div>';
        } else {
            html += '<div class="slideout-empty">No indexes were scanned in the last run</div>';
        }
        
        body.innerHTML = html;
    } catch (error) {
        body.innerHTML = `<div class="slideout-empty">Error loading scan details: ${error.message}</div>`;
    }
}

async function openExecuteDetails() {
    openPanel('execute');
    const body = document.getElementById('execute-panel-body');
    body.innerHTML = '<div class="loading">Loading...</div>';
    
    try {
        const data = await engineFetch('/api/index/execute-details');
        if (!data) return;
        
        let html = '';
        
        // Summary section
        html += `
            <div class="slideout-section">
                <div class="slideout-section-title">Run Summary</div>
                <div class="slideout-summary">
                    <div class="slideout-stat">
                        <div class="slideout-stat-value">${formatNumber(data.Summary.TotalRebuilt)}</div>
                        <div class="slideout-stat-label">Rebuilt</div>
                    </div>
                    <div class="slideout-stat">
                        <div class="slideout-stat-value">${formatNumber(data.Summary.TotalFailed)}</div>
                        <div class="slideout-stat-label">Failed</div>
                    </div>
                    <div class="slideout-stat">
                        <div class="slideout-stat-value">${formatNumber(data.Summary.TotalDeferred)}</div>
                        <div class="slideout-stat-label">Deferred</div>
                    </div>
                </div>
                <div style="font-size: 12px; color: #888; margin-bottom: 10px;">
                    Run: ${formatDateTime(data.Summary.StartedDttm)} | Duration: ${formatDuration(data.Summary.DurationSeconds)}
                </div>
            </div>
        `;
        
        // Rebuilt indexes
        if (data.RebuiltIndexes && data.RebuiltIndexes.length > 0) {
            html += `
                <div class="slideout-section">
                    <div class="slideout-section-title">Rebuilt Indexes</div>
                    <table class="slideout-table">
                        <thead>
                            <tr>
                                <th>Server</th>
                                <th>Database</th>
                                <th>Index</th>
                                <th>Before</th>
                                <th>After</th>
                                <th>Duration</th>
                            </tr>
                        </thead>
                        <tbody>
            `;
            for (const idx of data.RebuiltIndexes) {
                html += `
                    <tr>
                        <td>${idx.ServerName}</td>
                        <td>${idx.DatabaseName}</td>
                        <td title="${idx.SchemaName}.${idx.TableName}">${idx.IndexName}</td>
                        <td>${idx.FragmentationBefore.toFixed(1)}%</td>
                        <td>${idx.FragmentationAfter !== null ? idx.FragmentationAfter.toFixed(1) + '%' : '-'}</td>
                        <td>${formatDuration(idx.DurationSeconds)}</td>
                    </tr>
                `;
            }
            html += '</tbody></table></div>';
        } else {
            html += '<div class="slideout-empty">No indexes were rebuilt in the last run</div>';
        }
        
        body.innerHTML = html;
    } catch (error) {
        body.innerHTML = `<div class="slideout-empty">Error loading execute details: ${error.message}</div>`;
    }
}

async function openStatsDetails() {
    openPanel('stats');
    const body = document.getElementById('stats-panel-body');
    body.innerHTML = '<div class="loading">Loading...</div>';
    
    try {
        const data = await engineFetch('/api/index/stats-details');
        if (!data) return;
        
        let html = '';
        
        // Summary section
        html += `
            <div class="slideout-section">
                <div class="slideout-section-title">Run Summary</div>
                <div class="slideout-summary">
                    <div class="slideout-stat">
                        <div class="slideout-stat-value">${formatNumber(data.Summary?.TotalEvaluated || 0)}</div>
                        <div class="slideout-stat-label">Evaluated</div>
                    </div>
                    <div class="slideout-stat">
                        <div class="slideout-stat-value">${formatNumber(data.TotalModifications)}</div>
                        <div class="slideout-stat-label">Modifications</div>
                    </div>
                    <div class="slideout-stat">
                        <div class="slideout-stat-value">${formatNumber(data.TotalStaleness)}</div>
                        <div class="slideout-stat-label">Staleness</div>
                    </div>
                </div>
                <div style="font-size: 12px; color: #888; margin-bottom: 10px;">
                    Run: ${formatDateTime(data.Summary?.StartedDttm)} | Duration: ${formatDuration(data.Summary?.DurationSeconds || 0)}
                </div>
            </div>
        `;
        
        // By database section
        if (data.ByDatabase && data.ByDatabase.length > 0) {
            html += `
                <div class="slideout-section">
                    <div class="slideout-section-title">By Database</div>
                    <table class="slideout-table">
                        <thead>
                            <tr>
                                <th>Server</th>
                                <th>Database</th>
                                <th>Modifications</th>
                                <th>Staleness</th>
                                <th>Duration</th>
                            </tr>
                        </thead>
                        <tbody>
            `;
            for (const db of data.ByDatabase) {
                html += `
                    <tr>
                        <td>${db.ServerName}</td>
                        <td>${db.DatabaseName}</td>
                        <td>${formatNumber(db.ModificationCount)}</td>
                        <td>${db.StalenessCount > 0 ? formatNumber(db.StalenessCount) : '-'}</td>
                        <td>${formatDurationMs(db.DurationMs)}</td>
                    </tr>
                `;
            }
            html += '</tbody></table></div>';
        }
        
        // Failures section (only if any exist)
        if (data.Failures && data.Failures.length > 0) {
            html += `
                <div class="slideout-section">
                    <div class="slideout-section-title" style="color: #f48771;">Failures (${data.Failures.length})</div>
                    <table class="slideout-table">
                        <thead>
                            <tr>
                                <th>Database</th>
                                <th>Stat Name</th>
                                <th>Error</th>
                            </tr>
                        </thead>
                        <tbody>
            `;
            for (const fail of data.Failures) {
                html += `
                    <tr>
                        <td>${fail.DatabaseName}</td>
                        <td>${fail.StatName || '-'}</td>
                        <td style="color: #f48771; font-size: 11px;">${fail.ErrorMessage || '-'}</td>
                    </tr>
                `;
            }
            html += '</tbody></table></div>';
        }
        
        if (!data.ByDatabase?.length) {
            html += '<div class="slideout-empty">No detailed data available for last run</div>';
        }
        
        body.innerHTML = html;
    } catch (error) {
        body.innerHTML = `<div class="slideout-empty">Error loading stats details: ${error.message}</div>`;
    }
}

// ----------------------------------------------------------------------------
// Active Execution (Real-time Rebuild Progress)
// ----------------------------------------------------------------------------
async function loadActiveExecution() {
    try {
        const data = await engineFetch('/api/index/active-execution');
        if (!data) return;
        
        const container = document.getElementById('active-execution');
        
        if (!data.IsExecuting || !data.ActiveRebuilds || data.ActiveRebuilds.length === 0) {
            container.innerHTML = '<div class="no-active">No index rebuilds currently in progress</div>';
            return;
        }
        
        let html = '';
        
        for (const rebuild of data.ActiveRebuilds) {
            html += `
                <div class="rebuild-card">
                    <div class="rebuild-header">
                        <div>
                            <div class="rebuild-index">${rebuild.IndexName}</div>
                            <div class="rebuild-location">${rebuild.ServerName} / ${rebuild.DatabaseName}</div>
                        </div>
                        <div class="rebuild-percent">${rebuild.PercentComplete.toFixed(1)}%</div>
                    </div>
                    <div class="rebuild-progress-bar">
                        <div class="rebuild-progress-fill" style="width: ${rebuild.PercentComplete}%"></div>
                    </div>
                    <div class="rebuild-stats">
                        <div class="rebuild-stat">
                            <span class="label">Step:</span>
                            <span class="value">${rebuild.CurrentStep}</span>
                        </div>
                        <div class="rebuild-stat">
                            <span class="label">Rows:</span>
                            <span class="value">${formatNumber(rebuild.RowsProcessed)} / ${formatNumber(rebuild.TotalRows)}</span>
                        </div>
                        <div class="rebuild-stat">
                            <span class="label">Elapsed:</span>
                            <span class="value">${formatDuration(rebuild.ElapsedSeconds)}</span>
                        </div>
                        <div class="rebuild-stat">
                            <span class="label">ETA:</span>
                            <span class="value">${formatDuration(rebuild.EstimatedSecondsLeft)}</span>
                        </div>
                    </div>
                </div>
            `;
        }
        
        container.innerHTML = html;
    } catch (error) {
        console.error('Error loading active execution:', error);
    }
}

// ----------------------------------------------------------------------------
// Queue Summary (Clickable to open details) - Compact format
// ----------------------------------------------------------------------------
async function loadQueueSummary() {
    try {
        const summary = await engineFetch('/api/index/queue-summary');
        if (!summary) return;
        
        const container = document.getElementById('queue-summary');
        
        if (!summary || summary.length === 0) {
            container.innerHTML = '<div class="queue-empty">Queue is empty</div>';
            container.onclick = openQueueDetails;
            container.classList.add('clickable');
            return;
        }
        
        // Build lookup by status
        const byStatus = {};
        let total = null;
        for (const item of summary) {
            if (item.Status === 'TOTAL') {
                total = item;
            } else {
                byStatus[item.Status] = item;
            }
        }
        
        // If total exists but has 0 items, show empty state
        if (total && total.ItemCount === 0) {
            container.innerHTML = '<div class="queue-empty">Queue is empty</div>';
            container.onclick = openQueueDetails;
            container.classList.add('clickable');
            return;
        }
        
        const pending = byStatus['PENDING'] || { ItemCount: 0 };
        const scheduled = byStatus['SCHEDULED'] || { ItemCount: 0 };
        const deferred = byStatus['DEFERRED'] || { ItemCount: 0 };
        
        // Make whole container clickable
        container.onclick = openQueueDetails;
        container.classList.add('clickable');
        
        let html = '<div class="queue-summary-grid">';
        
        html += `
            <div class="queue-stat-card pending">
                <div class="queue-stat-value">${pending.ItemCount}</div>
                <div class="queue-stat-label">Pending</div>
            </div>
            <div class="queue-stat-card scheduled">
                <div class="queue-stat-value">${scheduled.ItemCount}</div>
                <div class="queue-stat-label">Scheduled</div>
            </div>
            <div class="queue-stat-card deferred">
                <div class="queue-stat-value">${deferred.ItemCount}</div>
                <div class="queue-stat-label">Deferred</div>
            </div>
        `;
        
        html += '</div>';
        
        // Text totals line
        if (total) {
            html += `
                <div class="queue-totals-line">
                    TOTAL ITEMS: ${total.ItemCount}  ·  TOTAL PAGES: ${formatNumber(total.TotalPages)}  ·  EST. RUNTIME: ${formatDuration(total.TotalSecondsOnline)}
                </div>
            `;
        }
        
        container.innerHTML = html;
    } catch (error) {
        console.error('Error loading queue summary:', error);
        document.getElementById('queue-summary').innerHTML = '<div class="queue-empty">Error loading queue</div>';
    }
}

// ----------------------------------------------------------------------------
// Queue Details Slideout
// ----------------------------------------------------------------------------
async function openQueueDetails() {
    openPanel('queue');
    const body = document.getElementById('queue-panel-body');
    body.innerHTML = '<div class="loading">Loading...</div>';
    
    try {
        const items = await engineFetch('/api/index/queue-details');
        if (!items) return;
        
        if (!items || items.length === 0) {
            body.innerHTML = '<div class="slideout-empty">Queue is empty</div>';
            return;
        }
        
        let html = `
            <table class="slideout-table">
                <thead>
                    <tr>
                        <th>Database</th>
                        <th>Index</th>
                        <th>Frag%</th>
                        <th>Pages</th>
                        <th>Est.</th>
                        <th>Status</th>
                        <th>Pri</th>
                    </tr>
                </thead>
                <tbody>
        `;
        
        for (const item of items) {
            const statusClass = item.Status.toLowerCase().replace('_', '-');
            html += `
                <tr>
                    <td title="${item.ServerName}">${item.DatabaseName}</td>
                    <td title="${item.SchemaName}.${item.TableName}.${item.IndexName}">${item.IndexName}</td>
                    <td>${item.FragmentationPct.toFixed(1)}%</td>
                    <td>${formatNumber(item.PageCount)}</td>
                    <td>${formatDuration(item.EstimatedSecondsOnline)}</td>
                    <td><span class="status-badge ${statusClass}">${item.Status}</span></td>
                    <td>${item.PriorityScore}</td>
                </tr>
            `;
        }
        
        html += '</tbody></table>';
        body.innerHTML = html;
    } catch (error) {
        body.innerHTML = `<div class="slideout-empty">Error loading queue details: ${error.message}</div>`;
    }
}

// ----------------------------------------------------------------------------
// Database Overview (grouped by maintenance type)
// ----------------------------------------------------------------------------
async function loadDatabaseHealth() {
    try {
        const data = await engineFetch('/api/index/database-health');
        if (!data) return;
        
        const container = document.getElementById('database-health');
        
        if (!data.Databases || data.Databases.length === 0) {
            container.innerHTML = '<div class="health-empty">No databases registered</div>';
            return;
        }
        
        // Separate into Index Maintenance and Statistics Only groups
        const indexMaintenanceDbs = data.Databases.filter(db => db.IndexMaintenanceEnabled);
        const statsOnlyDbs = data.Databases.filter(db => !db.IndexMaintenanceEnabled && db.StatsMaintenanceEnabled);
        
        let html = '';
        
        // Index Maintenance Group
        if (indexMaintenanceDbs.length > 0) {
            html += `
                <div class="database-group">
                    <div class="database-group-header">Index Maintenance</div>
                    <table class="health-table">
                        <thead>
                            <tr>
                                <th>Server</th>
                                <th></th>
                                <th>Database</th>
                                <th>Total</th>
                                <th>Frag</th>
                                <th>Queue</th>
                                <th>Last Scan</th>
                            </tr>
                        </thead>
                        <tbody>
            `;
            
            for (const db of indexMaintenanceDbs) {
                let healthClass = 'good';
                if (db.InQueue > 0) healthClass = 'warning';
                if (db.InQueue > 10) healthClass = 'critical';
                
                html += `
                    <tr>
                        <td>
                            <span class="health-indicator ${healthClass}"></span>
                            ${db.ServerName}
                        </td>
                        <td class="schedule-icon-cell">
                            <span class="schedule-icon" onclick="openSchedule(${db.DatabaseId}, '${db.ServerName}', '${db.DatabaseName}')" title="View/Edit Schedule">📅</span>
                        </td>
                        <td>${db.DatabaseName}</td>
                        <td>${formatNumber(db.TotalIndexes)}</td>
                        <td>${db.FragmentedCount}</td>
                        <td>${db.InQueue}</td>
                        <td>${formatDateShort(db.LastScanDate)}</td>
                    </tr>
                `;
            }
            
            html += '</tbody></table></div>';
        }
        
        // Statistics Only Group
        if (statsOnlyDbs.length > 0) {
            html += `
                <div class="database-group">
                    <div class="database-group-header">Statistics Only</div>
                    <table class="health-table">
                        <thead>
                            <tr>
                                <th>Server</th>
                                <th>Database</th>
                                <th>Total</th>
                                <th>Last Scan</th>
                            </tr>
                        </thead>
                        <tbody>
            `;
            
            for (const db of statsOnlyDbs) {
                html += `
                    <tr>
                        <td>${db.ServerName}</td>
                        <td>${db.DatabaseName}</td>
                        <td>${formatNumber(db.TotalIndexes)}</td>
                        <td>${formatDateShort(db.LastScanDate)}</td>
                    </tr>
                `;
            }
            
            html += '</tbody></table></div>';
        }
        
        container.innerHTML = html;
    } catch (error) {
        console.error('Error loading database health:', error);
    }
}

// ----------------------------------------------------------------------------
// Schedule Modal
// ----------------------------------------------------------------------------

async function openSchedule(databaseId, serverName, databaseName) {
    currentScheduleDatabaseId = databaseId;
    currentScheduleDatabaseName = databaseName;
    
    document.getElementById('schedule-panel-title').textContent = 
        `Maintenance Schedule: ${serverName} / ${databaseName}`;
    
    openPanel('schedule');
    const body = document.getElementById('schedule-panel-body');
    body.innerHTML = '<div class="loading">Loading schedule...</div>';
    
    try {
        const data = await engineFetch(`/api/index/schedule/${databaseId}`);
        if (!data) return;
        
        renderScheduleGrid(data.Schedule, data.HolidaySchedule);
    } catch (error) {
        body.innerHTML = `<div class="slideout-empty">Error loading schedule: ${error.message}</div>`;
    }
}

function renderScheduleGrid(schedule, holidaySchedule) {
    const body = document.getElementById('schedule-panel-body');
    
    function formatHour(h) {
        if (h === 0) return '12a';
        if (h < 12) return h + 'a';
        if (h === 12) return '12p';
        return (h - 12) + 'p';
    }
    
    let html = `
        <div class="schedule-container">
            <div class="schedule-legend">
                <div class="schedule-legend-item">
                    <div class="schedule-legend-box allowed"></div>
                    <span>Maintenance Allowed</span>
                </div>
                <div class="schedule-legend-item">
                    <div class="schedule-legend-box blocked"></div>
                    <span>Blocked</span>
                </div>
                <div class="schedule-legend-item schedule-drag-hint">
                    <span>💡 Click or drag to select multiple cells</span>
                </div>
            </div>
            
            <div class="schedule-section-header">Standard Schedule</div>
            <div class="schedule-grid" data-schedule-type="standard" onmouseup="handleScheduleMouseUp()" onmouseleave="handleScheduleMouseLeave()">
    `;
    
    // Hour labels row
    html += '<div class="schedule-hour-labels"><div class="schedule-day-label"></div>';
    for (let h = 0; h < 24; h++) {
        html += `<div class="schedule-hour-label">${formatHour(h)}</div>`;
    }
    html += '</div>';
    
    // Day rows
    for (const day of DAY_ORDER) {
        const daySchedule = schedule.find(s => s.DayOfWeek === day) || {};
        
        html += `<div class="schedule-row">`;
        html += `<div class="schedule-day-label">${DAY_NAMES[day]}</div>`;
        html += `<div class="schedule-hours">`;
        
        for (let hour = 0; hour < 24; hour++) {
            const hourKey = `Hr${hour.toString().padStart(2, '0')}`;
            const isAllowed = daySchedule[hourKey] === true;
            const cellClass = isAllowed ? 'allowed' : 'blocked';
            
            html += `
                <div class="schedule-cell ${cellClass}" 
                     data-day="${day}" 
                     data-hour="${hour}"
                     data-schedule-type="standard"
                     onmousedown="handleScheduleMouseDown(event, this, ${day}, ${hour}, 'standard')"
                     onmouseover="handleScheduleMouseOver(this, ${day}, ${hour}, 'standard')"
                     title="${DAY_NAMES[day]} ${formatHour(hour)} - ${isAllowed ? 'Allowed' : 'Blocked'}">
                </div>
            `;
        }
        
        html += '</div></div>';
    }
    
    html += '</div>';
    
    // Holiday Schedule Section
    if (holidaySchedule) {
        html += `
            <div class="schedule-section-header">Holiday Schedule</div>
            <div class="schedule-grid" data-schedule-type="holiday" onmouseup="handleScheduleMouseUp()" onmouseleave="handleScheduleMouseLeave()">
        `;
        
        html += '<div class="schedule-hour-labels"><div class="schedule-day-label"></div>';
        for (let h = 0; h < 24; h++) {
            html += `<div class="schedule-hour-label">${formatHour(h)}</div>`;
        }
        html += '</div>';
        
        html += `<div class="schedule-row">`;
        html += `<div class="schedule-day-label">Holiday</div>`;
        html += `<div class="schedule-hours">`;
        
        for (let hour = 0; hour < 24; hour++) {
            const hourKey = `Hr${hour.toString().padStart(2, '0')}`;
            const isAllowed = holidaySchedule[hourKey] === true;
            const cellClass = isAllowed ? 'allowed' : 'blocked';
            
            html += `
                <div class="schedule-cell ${cellClass}" 
                     data-hour="${hour}"
                     data-schedule-type="holiday"
                     onmousedown="handleScheduleMouseDown(event, this, null, ${hour}, 'holiday')"
                     onmouseover="handleScheduleMouseOver(this, null, ${hour}, 'holiday')"
                     title="Holiday ${formatHour(hour)} - ${isAllowed ? 'Allowed' : 'Blocked'}">
                </div>
            `;
        }
        
        html += '</div></div>';
        html += '</div>';
    } else {
        html += '<div class="schedule-no-holiday">No holiday schedule configured for this database.</div>';
    }
    
    html += '</div>';
    body.innerHTML = html;
}

// Drag selection handlers
function handleScheduleMouseDown(event, cell, day, hour, scheduleType) {
    event.preventDefault();
    if (!currentScheduleDatabaseId) return;
    
    isDragging = true;
    dragStartCell = cell;
    dragSelectedCells = [{ cell, day, hour }];
    dragScheduleType = scheduleType;
    
    const wasAllowed = cell.classList.contains('allowed');
    dragTargetValue = !wasAllowed;
    
    cell.classList.add('drag-selected');
}

function handleScheduleMouseOver(cell, day, hour, scheduleType) {
    if (!isDragging) return;
    if (scheduleType !== dragScheduleType) return;
    
    const alreadySelected = dragSelectedCells.some(c => c.day === day && c.hour === hour);
    if (!alreadySelected) {
        dragSelectedCells.push({ cell, day, hour });
        cell.classList.add('drag-selected');
    }
}

function handleScheduleMouseUp() {
    if (!isDragging) return;
    applyDragSelection();
}

function handleScheduleMouseLeave() {
    if (!isDragging) return;
    applyDragSelection();
}

async function applyDragSelection() {
    if (!isDragging || dragSelectedCells.length === 0) {
        resetDragState();
        return;
    }
    
    const cellsToUpdate = [...dragSelectedCells];
    const targetValue = dragTargetValue;
    const scheduleType = dragScheduleType;
    
    resetDragState();
    
    cellsToUpdate.forEach(({ cell }) => {
        cell.classList.add('saving');
        cell.classList.remove('drag-selected');
    });
    
    function formatHour(h) {
        if (h === 0) return '12a';
        if (h < 12) return h + 'a';
        if (h === 12) return '12p';
        return (h - 12) + 'p';
    }
    
    try {
        let apiUrl, requestBody;
        
        if (scheduleType === 'holiday') {
            apiUrl = '/api/index/schedule/holiday/update-batch';
            requestBody = {
                DatabaseId: currentScheduleDatabaseId,
                Updates: cellsToUpdate.map(({ hour }) => ({
                    Hour: hour,
                    Allowed: targetValue
                }))
            };
        } else {
            apiUrl = '/api/index/schedule/update-batch';
            requestBody = {
                DatabaseId: currentScheduleDatabaseId,
                Updates: cellsToUpdate.map(({ day, hour }) => ({
                    DayOfWeek: day,
                    Hour: hour,
                    Allowed: targetValue
                }))
            };
        }
        
        await engineFetch(apiUrl, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(requestBody)
        });
        
        cellsToUpdate.forEach(({ cell, day, hour }) => {
            cell.classList.remove('saving');
            cell.classList.toggle('allowed', targetValue);
            cell.classList.toggle('blocked', !targetValue);
            
            const dayLabel = scheduleType === 'holiday' ? 'Holiday' : DAY_NAMES[day];
            cell.title = `${dayLabel} ${formatHour(hour)} - ${targetValue ? 'Allowed' : 'Blocked'}`;
        });
        
    } catch (error) {
        console.error('Error updating schedule:', error);
        
        cellsToUpdate.forEach(({ cell, day, hour }) => {
            cell.classList.remove('saving');
            cell.classList.toggle('allowed', !targetValue);
            cell.classList.toggle('blocked', targetValue);
            
            const dayLabel = scheduleType === 'holiday' ? 'Holiday' : DAY_NAMES[day];
            cell.title = `${dayLabel} ${formatHour(hour)} - ${!targetValue ? 'Allowed' : 'Blocked'}`;
        });
        
        alert('Failed to update schedule. Please try again.');
    }
}

function resetDragState() {
    isDragging = false;
    dragStartCell = null;
    dragTargetValue = null;
    dragScheduleType = null;
    
    dragSelectedCells.forEach(({ cell }) => {
        cell.classList.remove('drag-selected');
    });
    dragSelectedCells = [];
}

// ----------------------------------------------------------------------------
// Initialization
// ----------------------------------------------------------------------------
// ============================================================================
// REFRESH ARCHITECTURE
// ============================================================================
// Live sections: Live Activity, Active Execution (direct DMV/status queries)
// Event-driven sections: Process Status, Index Queue, Database Overview
// NOTE: Engine events won't fire until processes are registered in Orchestrator.
// Until then, event-driven sections refresh via live polling as fallback.
// See: Refresh Architecture doc, Section 6.7
// ============================================================================

async function loadRefreshInterval() {
    try {
        const data = await engineFetch('/api/config/refresh-interval?page=indexmaintenance');
        if (data) {
            // engineFetch handles auth and returns parsed JSON
            PAGE_REFRESH_INTERVAL = data.interval || 5;
        }
    } catch (e) {
        // API unavailable — use default
    }
}

function startLivePolling() {
    if (livePollingTimer) clearInterval(livePollingTimer);
    livePollingTimer = setInterval(() => {
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
    setInterval(() => {
        const today = new Date().toDateString();
        if (today !== pageLoadDate) {
            window.location.reload();
        }
    }, 60000);
}

// ── Live sections: refresh on GlobalConfig timer ──
function refreshLiveSections() {
    loadLiveActivity();
    loadActiveExecution();
    updateTimestamp();
}

// ── Event-driven sections: refresh on orchestrator PROCESS_COMPLETED ──
// NOTE: Also called on live polling timer as fallback until orchestration is live
function refreshEventSections() {
    loadProcessStatus();
    loadQueueSummary();
    loadDatabaseHealth();
    updateTimestamp();
}

// ── Manual refresh: everything ──
function refreshAll() {
    loadLiveActivity();
    loadProcessStatus();
    loadActiveExecution();
    loadQueueSummary();
    loadDatabaseHealth();
    updateTimestamp();
}

function pageRefresh() {
    const btn = document.querySelector('.page-refresh-btn');
    if (btn) {
        btn.classList.add('spinning');
        btn.addEventListener('animationend', () => {
            btn.classList.remove('spinning');
        }, { once: true });
    }
    refreshAll();
}

function updateTimestamp() {
    const el = document.getElementById('last-update');
    if (el) el.textContent = new Date().toLocaleTimeString();
}

// Called by engine-events.js when a relevant PROCESS_COMPLETED event arrives
function onEngineProcessCompleted(processName, event) {
    refreshEventSections();
}

document.addEventListener('DOMContentLoaded', async () => {
    await loadRefreshInterval();
    refreshAll();
    connectEngineEvents();
    initEngineCardClicks();
    startLivePolling();
    startAutoRefresh();

    // Fallback: refresh event-driven sections on a slower timer
    // until orchestration is live and engine events handle it
    setInterval(refreshEventSections, 30000);
});

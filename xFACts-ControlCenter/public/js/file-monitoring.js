// ============================================================================
// xFACts Control Center - File Monitoring JavaScript
// Location: E:\xFACts-ControlCenter\public\js\file-monitoring.js
// Version: Tracked in dbo.System_Metadata (component: FileOps)
// ============================================================================

// ============================================================================
// STATE
// ============================================================================

var servers = [];
var configs = [];
var webhooks = [];
var subscriptions = [];
var refreshTimer = null;
var expandedYears = {};
var expandedMonths = {};
var pageLoadDate = new Date().toDateString();
var monthNames = ['', 'January', 'February', 'March', 'April', 'May', 'June',
                  'July', 'August', 'September', 'October', 'November', 'December'];
var dayNames = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
var dayKeys = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
var dayLabels = ['Su', 'Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa'];

// Engine events — process map for shared WebSocket module (engine-events.js)
var ENGINE_PROCESSES = {
    'Scan-SFTPFiles': { slug: 'sftp'}
};

// Live polling (Refresh Architecture)
var PAGE_REFRESH_INTERVAL = 30;   // Default; overridden by GlobalConfig on load

// Page hooks for engine-events.js shared module
function onPageResumed() { pageRefresh(); }
function onSessionExpired() { stopLivePolling(); }
var livePollingTimer = null;

// ============================================================================
// INITIALIZATION
// ============================================================================

document.addEventListener('DOMContentLoaded', async function() {
    await loadRefreshInterval();
    await loadServers();
    await loadWebhooks();
    await loadSubscriptions();
    await loadAllData();
    loadDetectionHistory();
    loadScheduledCount();
    startAutoRefresh();
    connectEngineEvents();
    initEngineCardClicks();
    startLivePolling();
});

async function loadAllData() {
    await Promise.all([
        loadDailyQueue(),
        loadConfigs()
    ]);
    updateLastRefresh();
}

function startAutoRefresh() {
    // Lightweight timer — only checks for overnight date change (page reload)
    // All data refresh is event-driven via onEngineProcessCompleted
    refreshTimer = setInterval(function() {
        var today = new Date().toDateString();
        if (today !== pageLoadDate) {
            window.location.reload();
        }
    }, 60000);
}

// Called by engine-events.js when a relevant PROCESS_COMPLETED event arrives
function onEngineProcessCompleted(processName, event) {
    loadAllData();
    loadScheduledCount();
}

// ============================================================================
// MANUAL REFRESH
// ============================================================================

function refreshAll() {
    loadAllData();
    loadDetectionHistory();
    loadScheduledCount();
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

// ============================================================================
// LIVE POLLING (Refresh Architecture)
// ============================================================================
// Framework for live polling sections that refresh on a GlobalConfig-driven
// timer. File Monitoring is currently all event-driven (no live sections),
// so loadLiveData() is a stub. When live sections are added to this page,
// add their refresh calls inside loadLiveData().
//
// See: Refresh Architecture doc, Section 2.2 (Live Polling Mode)
// ============================================================================

/**
 * Loads the page-specific refresh interval from GlobalConfig via shared API.
 * Called once on page init. Falls back to default if API unavailable.
 */
async function loadRefreshInterval() {
    try {
        var data = await engineFetch('/api/config/refresh-interval?page=fileops');
        if (data) {
            // engineFetch handles auth and returns parsed JSON
            PAGE_REFRESH_INTERVAL = data.interval || 30;
        }
    } catch (e) {
        // API unavailable — use default. Not worth logging; page works fine.
    }
}

/**
 * Starts the live polling timer using the GlobalConfig interval.
 * Timer calls refreshLiveSections() which reloads all live sections on the page.
 */
function startLivePolling() {
    if (livePollingTimer) clearInterval(livePollingTimer);
    livePollingTimer = setInterval(function() {
        refreshLiveSections();
    }, PAGE_REFRESH_INTERVAL * 1000);
}

/**
 * Stops live polling. Used by smart polling (activity-aware) when the page
 * detects no orchestrator activity and live data would be unchanged.
 */
function stopLivePolling() {
    if (enginePageHidden || engineSessionExpired) return;
    if (livePollingTimer) {
        clearInterval(livePollingTimer);
        livePollingTimer = null;
    }
}

/**
 * Reloads all live polling sections and updates the page timestamp.
 * Called by the live polling timer and by manual refresh button clicks
 * on any live badge.
 */
function refreshLiveSections() {
    loadLiveData();
    updateLastRefresh();
}

/**
 * Loads data for all live polling sections on this page.
 *
 * FILE MONITORING: Currently no live sections — all data is event-driven
 * (refreshed on Scan-SFTPFiles PROCESS_COMPLETED events).
 *
 * When live sections are added, put their load calls here:
 *   async function loadLiveData() {
 *       await Promise.all([
 *           loadSomeLiveSection(),
 *           loadAnotherLiveSection()
 *       ]);
 *   }
 */
function loadLiveData() {
    // No live sections on this page yet.
    // Add live section refresh calls here when implemented.
}

// ============================================================================
// ENGINE HEALTH — handled by shared engine-events.js module
// ============================================================================

function updateLastRefresh() {
    var now = new Date();
    document.getElementById('last-update').textContent = now.toLocaleTimeString('en-US', {
        hour: '2-digit', minute: '2-digit', second: '2-digit'
    });
}

// ============================================================================
// DAILY QUEUE
// ============================================================================

async function loadDailyQueue() {
    try {
        var data = await engineFetch('/api/fileops/status');
        if (!data) return;
        hideConnectionError();
        renderDailyQueue(data);
        renderStatusSummary(data);
    } catch (error) {
        showConnectionError('Failed to load monitor status');
    }
}

function renderDailyQueue(data) {
    var escalated = [], detected = [], monitoring = [];
    var now = new Date();
    var today = now.getFullYear() + '-' + String(now.getMonth() + 1).padStart(2, '0') + '-' + String(now.getDate()).padStart(2, '0');

    if (data && data.length > 0) {
        data.forEach(function(m) {
            if (!m.LastScannedDttm || m.LastScannedDttm.split(' ')[0] < today) return;

            if (m.LastStatus === 'Escalated') escalated.push(m);
            else if (m.LastStatus === 'Detected' || m.LastStatus === 'LateDetected') detected.push(m);
            else if (m.LastStatus === 'Monitoring') monitoring.push(m);
        });
    }

    // Sort detected by detection time descending (most recent first)
    detected.sort(function(a, b) {
        var ta = a.FileDetectedDttm || '';
        var tb = b.FileDetectedDttm || '';
        return tb.localeCompare(ta);
    });

    // Sort escalated by escalation time descending
    escalated.sort(function(a, b) {
        var ta = a.EscalatedDttm || a.EscalationTime || '';
        var tb = b.EscalatedDttm || b.EscalationTime || '';
        return tb.localeCompare(ta);
    });

    var html = '';

    // Escalated section (top priority)
    if (escalated.length > 0) {
        html += renderQueueRows(escalated);
    } else {
        html += '<tr><td colspan="4" class="queue-section-empty">No current escalations</td></tr>';
    }

    // Divider
    html += '<tr class="queue-divider-row"><td colspan="4"></td></tr>';

    // Monitoring section (actively scanning)
    if (monitoring.length > 0) {
        html += renderQueueRows(monitoring);
    } else {
        html += '<tr><td colspan="4" class="queue-section-empty">No current monitoring</td></tr>';
    }

    // Divider
    html += '<tr class="queue-divider-row"><td colspan="4"></td></tr>';

    // Detected section (reverse time order)
    if (detected.length > 0) {
        html += renderQueueRows(detected);
    } else {
        html += '<tr><td colspan="4" class="queue-section-empty">No detections yet today</td></tr>';
    }

    document.getElementById('queue-body').innerHTML = html;
}

function renderQueueRows(monitors) {
    var html = '';
    monitors.forEach(function(m) {
        var cls = m.LastStatus.toLowerCase();
        var txt = m.LastStatus === 'LateDetected' ? 'LATE' : m.LastStatus.toUpperCase();
        var time = getTimeDisplay(m);
        var file = m.FileDetectedName ? '<span class="monitor-file">' + esc(m.FileDetectedName) + '</span>' : '<span style="color:#555;">—</span>';
        html += '<tr class="clickable" onclick="openConsoleToMonitor(' + m.ConfigId + ')">';
        html += '<td><span class="status-badge ' + cls + '">' + txt + '</span></td>';
        html += '<td><span class="monitor-name">' + esc(m.ConfigName) + '</span></td>';
        html += '<td><span class="monitor-time">' + time + '</span></td>';
        html += '<td>' + file + '</td></tr>';
    });
    return html;
}

function getTimeDisplay(m) {
    // Always return a time - use the most relevant per status
    if (m.LastStatus === 'Detected' || m.LastStatus === 'LateDetected') {
        if (m.FileDetectedDttm) return formatTime(m.FileDetectedDttm);
    }
    if (m.LastStatus === 'Escalated') {
        if (m.EscalatedDttm) return formatTime(m.EscalatedDttm);
        if (m.EscalationTime) return fmtTimeOnly(m.EscalationTime);
    }
    if (m.LastStatus === 'Monitoring') {
        if (m.LastScannedDttm) return formatTime(m.LastScannedDttm);
        if (m.CheckStartTime) return fmtTimeOnly(m.CheckStartTime);
    }
    // Fallback: last scanned or start time
    if (m.LastScannedDttm) return formatTime(m.LastScannedDttm);
    if (m.CheckStartTime) return fmtTimeOnly(m.CheckStartTime);
    return '—';
}

// ============================================================================
// STATUS SUMMARY
// ============================================================================

function renderStatusSummary(data) {
    var esc = 0, mon = 0, det = 0;
    var now = new Date();
    var today = now.getFullYear() + '-' + String(now.getMonth() + 1).padStart(2, '0') + '-' + String(now.getDate()).padStart(2, '0');
    if (data && data.length > 0) {
        data.forEach(function(m) {
            if (!m.LastScannedDttm || m.LastScannedDttm.split(' ')[0] < today) return;
            if (m.LastStatus === 'Escalated') esc++;
            else if (m.LastStatus === 'Monitoring') mon++;
            else if (m.LastStatus === 'Detected' || m.LastStatus === 'LateDetected') det++;
        });
    }

    var elEsc = document.getElementById('val-escalated');
    var elMon = document.getElementById('val-monitoring');
    var elDet = document.getElementById('val-detected');

    elEsc.textContent = esc;
    elEsc.className = 'card-value ' + (esc > 0 ? 'escalated' : 'zero');

    elMon.textContent = mon;
    elMon.className = 'card-value ' + (mon > 0 ? 'monitoring' : 'zero');

    elDet.textContent = det;
    elDet.className = 'card-value ' + (det > 0 ? 'detected' : 'zero');

    // Card frame coloring per standard: color means "look at me"
    var cardEsc = document.getElementById('card-escalated');
    cardEsc.className = 'summary-card' + (esc > 0 ? ' card-critical' : '');
}

// ============================================================================
// CONFIGS & SERVERS
// ============================================================================

async function loadConfigs() {
    try {
        var result = await engineFetch('/api/fileops/configs');
        if (!result) return;
        configs = result;
        document.getElementById('monitor-count').textContent = configs.length;
        document.getElementById('server-count').textContent = servers.length;
    } catch (error) { console.error('Error loading configs:', error); }
}

async function loadServers() {
    try {
        var result = await engineFetch('/api/fileops/servers');
        if (!result) return;
        servers = result;
    } catch (error) { console.error('Error loading servers:', error); }
}

async function loadWebhooks() {
    try {
        var result = await engineFetch('/api/fileops/webhooks');
        if (!result) return;
        webhooks = result;
    } catch (error) { console.error('Error loading webhooks:', error); }
}

async function loadSubscriptions() {
    try {
        var result = await engineFetch('/api/fileops/subscriptions');
        if (!result) return;
        subscriptions = result;
    } catch (error) { console.error('Error loading subscriptions:', error); }
}

function getSubscriptionsForMonitor(configName) {
    if (!configName || !subscriptions.length) return [];
    return subscriptions.filter(function(s) {
        return s.TriggerType === configName;
    });
}

// ============================================================================
// SLIDE-UP MANAGEMENT CONSOLE
// ============================================================================

function openConsole(tab) {
    document.getElementById('console-overlay').classList.add('visible');
    document.getElementById('console-panel').classList.add('visible');
    currentFace = tab || 'monitors';
    applyConsoleFace();
}

function openConsoleToMonitor(configId) {
    openConsole('monitors');
    // Scroll to the specific row after render
    setTimeout(function() {
        var el = document.querySelector('.monitor-row[data-id="' + configId + '"]');
        if (el) el.scrollIntoView({ behavior: 'smooth', block: 'center' });
    }, 100);
}

function closeConsole() {
    // Check for unsaved changes
    if (Object.keys(dirtyRows).length > 0) {
        if (!confirm('You have unsaved changes. Close anyway?')) return;
    }
    document.getElementById('console-overlay').classList.remove('visible');
    document.getElementById('console-panel').classList.remove('visible');
    dirtyRows = {};
}

function flipConsole() {
    currentFace = currentFace === 'monitors' ? 'servers' : 'monitors';
    applyConsoleFace();
}

function applyConsoleFace() {
    var flipCard = document.getElementById('console-flip-card');
    var title = document.getElementById('console-face-title');
    var addBtn = document.getElementById('console-add-btn');

    if (currentFace === 'servers') {
        flipCard.classList.add('flipped');
        title.textContent = 'Servers';
        addBtn.style.display = 'none';
        renderServerList();
    } else {
        flipCard.classList.remove('flipped');
        title.textContent = 'Monitors';
        addBtn.style.display = '';
        renderMonitorList();
    }
}

// ============================================================================
// MONITOR LIST (inline-edit rows)
// ============================================================================

var dirtyRows = {};
var currentFace = 'monitors';

function renderMonitorList() {
    var container = document.getElementById('monitor-list');
    if (configs.length === 0) {
        container.innerHTML = '<div class="no-activity">No monitors configured yet</div>';
        return;
    }

    var active = configs.filter(function(c) { return c.IsEnabled; });
    var inactive = configs.filter(function(c) { return !c.IsEnabled; });

    // Column header
    var html = '<div class="monitor-col-header">';
    html += '<div class="col-grid">';
    html += '<span class="monitor-col-label">Status</span>';
    html += '<span class="monitor-col-label">Monitor</span>';
    html += '<span class="monitor-col-label">Server</span>';
    html += '<span class="monitor-col-label">Path</span>';
    html += '<span class="monitor-col-label">Pattern</span>';
    html += '<span class="monitor-col-label">Days</span>';
    html += '<span class="monitor-col-label">Start</span>';
    html += '<span class="monitor-col-label">End</span>';
    html += '<span class="monitor-col-label">Escalate</span>';
    html += '</div>';
    html += '<div class="col-subs"><span class="monitor-col-label">Alerts</span></div>';
    html += '</div>';

    active.forEach(function(c) { html += renderMonitorRow(c); });
    inactive.forEach(function(c) { html += renderMonitorRow(c); });

    container.innerHTML = html;
}

function renderMonitorRow(c) {
    var id = c.ConfigId;
    var isDirty = !!dirtyRows[id];
    var dirtyCls = isDirty ? ' dirty' : '';
    var disabledCls = getVal(id, 'IsEnabled', c.IsEnabled) ? '' : ' disabled';

    // Get current values (dirty overrides or original)
    var name = getVal(id, 'ConfigName', c.ConfigName);
    var serverId = getVal(id, 'ServerId', c.ServerId);
    var path = getVal(id, 'SftpPath', c.SftpPath);
    var pattern = getVal(id, 'FilePattern', c.FilePattern);
    var startTime = getVal(id, 'CheckStartTime', fmtTimeInput(c.CheckStartTime));
    var endTime = getVal(id, 'CheckEndTime', fmtTimeInput(c.CheckEndTime));
    var escTime = getVal(id, 'EscalationTime', fmtTimeInput(c.EscalationTime));
    var notifyDet = getVal(id, 'NotifyOnDetection', c.NotifyOnDetection);
    var notifyEsc = getVal(id, 'NotifyOnEscalation', c.NotifyOnEscalation);
    var jira = getVal(id, 'CreateJiraOnEscalation', c.CreateJiraOnEscalation);
    var priority = getVal(id, 'DefaultPriority', c.DefaultPriority);
    var enabled = getVal(id, 'IsEnabled', c.IsEnabled);

    // Server dropdown
    var serverOpts = servers.map(function(sv) {
        var sel = sv.ServerId === serverId ? ' selected' : '';
        return '<option value="' + sv.ServerId + '"' + sel + '>' + esc(sv.ServerName) + '</option>';
    }).join('');

    // Day badges
    var dayBadges = '';
    for (var i = 0; i < 7; i++) {
        var key = 'Check' + dayKeys[i];
        var isOn = getVal(id, key, c[key]);
        dayBadges += '<span class="day-badge ' + (isOn ? 'on' : 'off') + '" onclick="event.stopPropagation();toggleField(' + id + ',\'' + key + '\',' + !isOn + ')">' + dayLabels[i] + '</span>';
    }

    // Mini-badges
    var detBadge = '<span class="mini-badge det ' + (notifyDet ? 'on' : 'off') + '" onclick="event.stopPropagation();toggleField(' + id + ',\'NotifyOnDetection\',' + !notifyDet + ')">DET</span>';
    var escBadge = '<span class="mini-badge esc ' + (notifyEsc ? 'on' : 'off') + '" onclick="event.stopPropagation();toggleField(' + id + ',\'NotifyOnEscalation\',' + !notifyEsc + ')">ESC</span>';
    var jiraBadge = '<span class="mini-badge jira ' + (jira ? 'on' : 'off') + '" onclick="event.stopPropagation();toggleField(' + id + ',\'CreateJiraOnEscalation\',' + !jira + ')">JIRA</span>';

    // Priority 2x2 grid (Jira color scheme)
    var priValues = [
        { key: 'Highest', label: 'Highest', cls: 'pri-highest' },
        { key: 'High', label: 'High', cls: 'pri-high' },
        { key: 'Medium', label: 'Medium', cls: 'pri-medium' },
        { key: 'Low', label: 'Low', cls: 'pri-low' }
    ];
    var priGrid = '<div class="priority-grid">';
    priValues.forEach(function(p) {
        var sel = (priority === p.key) ? ' selected' : '';
        var dis = jira ? '' : ' disabled';
        priGrid += '<button class="priority-btn ' + p.cls + sel + dis + '" onclick="event.stopPropagation();' + (jira ? 'setPriority(' + id + ',\'' + p.key + '\')' : '') + '" title="' + p.key + '">' + p.label + '</button>';
    });
    priGrid += '</div>';

    // Status badge (clickable toggle)
    var statusBadge = enabled
        ? '<span class="status-badge active status-toggle" onclick="event.stopPropagation();toggleField(' + id + ',\'IsEnabled\',false)">ACTIVE</span>'
        : '<span class="status-badge inactive status-toggle" onclick="event.stopPropagation();toggleField(' + id + ',\'IsEnabled\',true)">OFF</span>';

    var html = '<div class="monitor-row' + dirtyCls + disabledCls + '" data-id="' + id + '">';
    html += '<div class="monitor-row-fields">';

    // Fixed grid zone (config fields)
    html += '<div class="row-grid">';
    html += statusBadge;
    html += '<input class="inline-input name-input" value="' + escAttr(name) + '" onchange="setField(' + id + ',\'ConfigName\',this.value)">';
    html += '<select class="inline-input" onchange="setField(' + id + ',\'ServerId\',parseInt(this.value))">' + serverOpts + '</select>';
    html += '<input class="inline-input" value="' + escAttr(path) + '" onchange="setField(' + id + ',\'SftpPath\',this.value)" placeholder="/path/">';
    html += '<input class="inline-input" value="' + escAttr(pattern) + '" onchange="setField(' + id + ',\'FilePattern\',this.value)" placeholder="*.txt">';
    html += '<div class="monitor-row-days">' + dayBadges + '</div>';
    html += '<input type="time" class="inline-input" value="' + startTime + '" onchange="setField(' + id + ',\'CheckStartTime\',this.value)">';
    html += '<input type="time" class="inline-input" value="' + endTime + '" onchange="setField(' + id + ',\'CheckEndTime\',this.value)">';
    html += '<input type="time" class="inline-input" value="' + escTime + '" onchange="setField(' + id + ',\'EscalationTime\',this.value)">';
    html += '</div>';

    // Jira section
    html += '<div class="row-jira-section">';
    html += jiraBadge;
    html += priGrid;
    html += '</div>';

    // Subscription zone
    html += '<div class="row-subs">';
    var monitorSubs = getSubscriptionsForMonitor(c.ConfigName);
    if (monitorSubs.length > 0) {
        // Existing subscriptions - show channel badges with DET/ESC
        monitorSubs.forEach(function(sub) {
            var activeCls = sub.IsActive ? '' : ' inactive';
            html += '<div class="sub-group">';
            html += '<span class="sub-channel-badge' + activeCls + '" title="' + esc(sub.WebhookName) + '">' + esc(sub.ChannelName) + '</span>';
            html += '<div class="sub-det-esc">';
            html += detBadge;
            html += escBadge;
            html += '</div>';
            html += '</div>';
        });
    } else if (webhooks.length > 0) {
        // No subscriptions - show webhook selector
        var selWebhookId = getVal(id, 'WebhookConfigId', '');
        var webhookOpts = '<option value="">No Teams Routing</option>';
        webhooks.forEach(function(wh) {
            var sel = (selWebhookId && selWebhookId == wh.ConfigId) ? ' selected' : '';
            webhookOpts += '<option value="' + wh.ConfigId + '"' + sel + '>' + esc(wh.WebhookName) + '</option>';
        });
        webhookOpts += '<option value="new">+ New Webhook...</option>';
        html += '<div class="sub-group">';
        html += '<select class="inline-input sub-webhook-select" onchange="if(this.value===\'new\'){this.value=\'\';openWebhookModal(' + id + ');}else{setField(' + id + ',\'WebhookConfigId\',this.value?parseInt(this.value):null)}">' + webhookOpts + '</select>';
        // Show preview badge + disabled DET/ESC when a webhook is selected
        if (selWebhookId) {
            var selWebhook = webhooks.find(function(w) { return w.ConfigId == selWebhookId; });
            var previewName = selWebhook ? selWebhook.WebhookName : 'Selected';
            html += '<div class="sub-group preview">';
            html += '<span class="sub-channel-badge preview" title="Will be created on save">' + esc(previewName) + '</span>';
            html += '<div class="sub-det-esc">';
            html += detBadge;
            html += escBadge;
            html += '</div>';
            html += '</div>';
        }
        html += '</div>';
    }
    html += '</div>';

    html += '</div>';

    // Save/Cancel bar
    html += '<div class="monitor-save-bar">';
    html += '<button class="btn btn-secondary" onclick="cancelRowEdit(' + id + ')">Cancel</button>';
    html += '<button class="btn btn-primary" onclick="saveRow(' + id + ')">Save</button>';
    html += '</div>';

    html += '</div>';
    return html;
}

// ============================================================================
// INLINE EDIT - DIRTY TRACKING
// ============================================================================

function getVal(id, field, original) {
    if (dirtyRows[id] && dirtyRows[id].hasOwnProperty(field)) return dirtyRows[id][field];
    return original;
}

function setField(id, field, value) {
    if (!dirtyRows[id]) dirtyRows[id] = {};
    dirtyRows[id][field] = value;
    renderMonitorList();
}

function toggleField(id, field, value) {
    setField(id, field, value);
}

function setPriority(id, value) {
    setField(id, 'DefaultPriority', value);
}

var webhookModalForRowId = null;

function openWebhookModal(rowId) {
    webhookModalForRowId = rowId;
    document.getElementById('wh-new-name').value = '';
    document.getElementById('wh-new-url').value = '';
    document.getElementById('wh-new-desc').value = '';
    document.getElementById('wh-modal-overlay').classList.add('visible');
    setTimeout(function() { document.getElementById('wh-new-name').focus(); }, 50);
}

function closeWebhookModal() {
    document.getElementById('wh-modal-overlay').classList.remove('visible');
    webhookModalForRowId = null;
}

// ============================================================================
// SCHEDULED MONITORS MODAL
// ============================================================================

var schedCountdownInterval = null;

function openScheduledModal() {
    document.getElementById('sched-modal-overlay').classList.add('visible');
    loadScheduledMonitors();
}

function closeScheduledModal() {
    document.getElementById('sched-modal-overlay').classList.remove('visible');
    if (schedCountdownInterval) {
        clearInterval(schedCountdownInterval);
        schedCountdownInterval = null;
    }
}

async function loadScheduledMonitors() {
    var body = document.getElementById('sched-modal-body');
    body.innerHTML = '<div class="loading">Loading...</div>';

    try {
        var data = await engineFetch('/api/fileops/scheduled');
        if (!data) return;
        updateScheduledBadge(data.length);
        renderScheduledMonitors(data);
    } catch (error) {
        body.innerHTML = '<div class="no-activity">Failed to load scheduled monitors</div>';
    }
}

function updateScheduledBadge(count) {
    var badge = document.getElementById('sched-count-badge');
    if (!badge) return;
    if (count > 0) {
        badge.textContent = count;
        badge.classList.remove('hidden');
    } else {
        badge.classList.add('hidden');
    }
}

async function loadScheduledCount() {
    try {
        var data = await engineFetch('/api/fileops/scheduled');
        if (!data) return;
        updateScheduledBadge(data.length);
    } catch (e) { /* silent */ }
}

function renderScheduledMonitors(data) {
    var body = document.getElementById('sched-modal-body');

    if (!data || data.length === 0) {
        body.innerHTML = '<div class="no-activity" style="padding:20px;">No monitors waiting to start today</div>';
        return;
    }

    var html = '<table class="sched-table">';
    html += '<thead><tr><th>Monitor</th><th>Start</th><th>Escalate</th><th>Starts In</th></tr></thead>';
    html += '<tbody>';
    data.forEach(function(m) {
        html += '<tr>';
        html += '<td class="sched-name">' + esc(m.ConfigName) + '</td>';
        html += '<td class="sched-time">' + fmtTimeOnly(m.CheckStartTime) + '</td>';
        html += '<td class="sched-time">' + fmtTimeOnly(m.EscalationTime) + '</td>';
        html += '<td class="sched-countdown" data-start="' + m.CheckStartTime + '"></td>';
        html += '</tr>';
    });
    html += '</tbody></table>';

    body.innerHTML = html;
    updateScheduledCountdowns();
    if (schedCountdownInterval) clearInterval(schedCountdownInterval);
    schedCountdownInterval = setInterval(updateScheduledCountdowns, 1000);
}

function updateScheduledCountdowns() {
    var cells = document.querySelectorAll('.sched-countdown');
    var now = new Date();
    cells.forEach(function(cell) {
        var startStr = cell.getAttribute('data-start');
        if (!startStr) return;
        var parts = startStr.split(':');
        var target = new Date();
        target.setHours(parseInt(parts[0]), parseInt(parts[1]), parseInt(parts[2] || 0), 0);
        var diffMs = target - now;
        if (diffMs <= 0) {
            cell.innerHTML = '<span style="color:#4ec9b0;">Starting...</span>';
        } else {
            var h = Math.floor(diffMs / 3600000);
            var m = Math.floor((diffMs % 3600000) / 60000);
            var s = Math.floor((diffMs % 60000) / 1000);
            var str = '';
            if (h > 0) str += h + 'h ';
            str += m + 'm ' + s + 's';
            cell.textContent = str;
        }
    });
}

async function saveNewWebhook() {
    var name = document.getElementById('wh-new-name').value.trim();
    var url = document.getElementById('wh-new-url').value.trim();
    var desc = document.getElementById('wh-new-desc').value.trim();

    if (!name) { alert('Webhook name is required'); return; }
    if (!url) { alert('Webhook URL is required'); return; }
    if (!url.startsWith('https://')) { alert('Webhook URL must start with https://'); return; }

     try {
        var response = await engineFetch('/api/fileops/webhook/save', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                WebhookName: name,
                WebhookUrl: url,
                AlertCategory: 'ALL',
                Description: desc || null
            })
        });
        if (!response) return;
        if (response.Error) {
            throw new Error(response.Error || 'Failed to create webhook');
        }
        var newConfigId = response.ConfigId;

        // Refresh webhooks list
        await loadWebhooks();

        // Set the new webhook on the row that triggered the modal
        if (webhookModalForRowId !== null) {
            setField(webhookModalForRowId, 'WebhookConfigId', newConfigId);
        }

        closeWebhookModal();
    } catch (error) {
        alert('Failed to create webhook: ' + error.message);
    }
}

function cancelRowEdit(id) {
    delete dirtyRows[id];
    // If canceling a new monitor, remove it from the array
    if (id === -1) {
        configs = configs.filter(function(x) { return x.ConfigId !== -1; });
    }
    renderMonitorList();
}

// ============================================================================
// ADD NEW MONITOR
// ============================================================================

function addNewMonitor() {
    // Insert a temporary config at the top
    var newId = -1;
    var existing = configs.find(function(c) { return c.ConfigId === -1; });
    if (existing) return; // already adding

    var newConfig = {
        ConfigId: newId,
        ServerId: servers.length > 0 ? servers[0].ServerId : null,
        ConfigName: '',
        SftpPath: '',
        FilePattern: '',
        CheckStartTime: '08:00:00',
        EscalationTime: '13:00:00',
        CheckEndTime: '15:00:00',
        IsEnabled: true,
        NotifyOnDetection: false,
        NotifyOnEscalation: false,
        CreateJiraOnEscalation: false,
        DefaultPriority: 'High',
        CheckSunday: false,
        CheckMonday: true,
        CheckTuesday: true,
        CheckWednesday: true,
        CheckThursday: true,
        CheckFriday: true,
        CheckSaturday: false
    };

    configs.unshift(newConfig);
    dirtyRows[newId] = {}; // Mark as dirty immediately so save bar shows
    renderMonitorList();

    // Focus the name input
    setTimeout(function() {
        var firstInput = document.querySelector('.monitor-row[data-id="-1"] .name-input');
        if (firstInput) firstInput.focus();
    }, 50);
}

async function saveRow(id) {
    var c = configs.find(function(x) { return x.ConfigId === id; });
    if (!c) return;

    var d = dirtyRows[id] || {};
    var name = d.hasOwnProperty('ConfigName') ? d.ConfigName : c.ConfigName;
    var path = d.hasOwnProperty('SftpPath') ? d.SftpPath : c.SftpPath;
    var pattern = d.hasOwnProperty('FilePattern') ? d.FilePattern : c.FilePattern;

    if (!name || !name.trim()) { alert('Monitor name is required'); return; }
    if (!path || !path.trim()) { alert('SFTP path is required'); return; }
    if (!pattern || !pattern.trim()) { alert('File pattern is required'); return; }

    path = path.trim();
    if (!path.endsWith('/')) path += '/';

    var startTime = d.hasOwnProperty('CheckStartTime') ? d.CheckStartTime : fmtTimeInput(c.CheckStartTime);
    var endTime = d.hasOwnProperty('CheckEndTime') ? d.CheckEndTime : fmtTimeInput(c.CheckEndTime);
    var escTime = d.hasOwnProperty('EscalationTime') ? d.EscalationTime : fmtTimeInput(c.EscalationTime);

    var payload = {
        ConfigId: id === -1 ? null : id,
        ServerId: d.hasOwnProperty('ServerId') ? d.ServerId : c.ServerId,
        ConfigName: name.trim(),
        SftpPath: path,
        FilePattern: pattern.trim(),
        CheckStartTime: startTime + ':00',
        EscalationTime: escTime + ':00',
        CheckEndTime: endTime + ':00',
        IsEnabled: d.hasOwnProperty('IsEnabled') ? d.IsEnabled : c.IsEnabled,
        NotifyOnDetection: d.hasOwnProperty('NotifyOnDetection') ? d.NotifyOnDetection : c.NotifyOnDetection,
        NotifyOnEscalation: d.hasOwnProperty('NotifyOnEscalation') ? d.NotifyOnEscalation : c.NotifyOnEscalation,
        CreateJiraOnEscalation: d.hasOwnProperty('CreateJiraOnEscalation') ? d.CreateJiraOnEscalation : c.CreateJiraOnEscalation,
        DefaultPriority: d.hasOwnProperty('DefaultPriority') ? d.DefaultPriority : c.DefaultPriority,
        WebhookConfigId: d.hasOwnProperty('WebhookConfigId') ? d.WebhookConfigId : null
    };
    for (var i = 0; i < 7; i++) {
        var key = 'Check' + dayKeys[i];
        payload[key] = d.hasOwnProperty(key) ? d[key] : c[key];
    }

    try {
        var response = await engineFetch('/api/fileops/config/save', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload)
        });
        if (!response) return;
        if (response.Error) {
            throw new Error(response.Error || 'Failed to save');
        }
        delete dirtyRows[id];
        // Remove temp config if it was a new one
        if (id === -1) {
            configs = configs.filter(function(x) { return x.ConfigId !== -1; });
        }
        await loadSubscriptions();
        await loadConfigs();
        renderMonitorList();
        await loadDailyQueue();
    } catch (error) {
        alert('Failed to save: ' + error.message);
    }
}

// ============================================================================
// SERVER LIST
// ============================================================================

function renderServerList() {
    var container = document.getElementById('server-list');
    if (servers.length === 0) {
        container.innerHTML = '<div class="no-activity">No SFTP servers configured</div>';
        return;
    }

    var html = '';
    servers.forEach(function(s) {
        html += '<div class="server-row">';
        html += '<span class="server-row-name">' + esc(s.ServerName) + '</span>';
        html += '<span class="server-row-host">' + esc(s.SftpHost) + '</span>';
        html += '<span class="server-row-port">Port ' + (s.SftpPort || 22) + '</span>';
        html += '<span class="server-row-status"><span class="status-badge active">ACTIVE</span></span>';
        html += '</div>';
    });

    container.innerHTML = html;
}

// ============================================================================
// DETECTION HISTORY TREE
// ============================================================================

async function loadDetectionHistory() {
    var container = document.getElementById('detection-history');
    try {
        var data = await engineFetch('/api/fileops/history?limit=500');
        if (!data) return;
        renderDetectionHistory(container, data);
    } catch (error) {
        container.innerHTML = '<div class="no-activity">Failed to load history</div>';
    }
}

function renderDetectionHistory(container, data) {
    if (!data || data.length === 0) {
        container.innerHTML = '<div class="no-activity">No detection history available</div>';
        return;
    }

    var yearMap = {};
    data.forEach(function(e) {
        var d = new Date(e.EventDttm);
        var y = d.getFullYear(), m = d.getMonth() + 1;
        var dayKey = d.toISOString().split('T')[0];
        if (!yearMap[y]) yearMap[y] = { detected: 0, escalated: 0, monitors: {}, months: {} };
        if (!yearMap[y].months[m]) yearMap[y].months[m] = { detected: 0, escalated: 0, monitors: {}, days: {} };
        if (!yearMap[y].months[m].days[dayKey]) yearMap[y].months[m].days[dayKey] = { detected: 0, escalated: 0, monitors: {} };
        yearMap[y].monitors[e.ConfigName] = true;
        yearMap[y].months[m].monitors[e.ConfigName] = true;
        yearMap[y].months[m].days[dayKey].monitors[e.ConfigName] = true;
        if (e.EventType === 'Escalated') { yearMap[y].escalated++; yearMap[y].months[m].escalated++; yearMap[y].months[m].days[dayKey].escalated++; }
        else { yearMap[y].detected++; yearMap[y].months[m].detected++; yearMap[y].months[m].days[dayKey].detected++; }
    });

    var sortedYears = Object.keys(yearMap).sort(function(a, b) { return b - a; });
    var html = '';

    sortedYears.forEach(function(year) {
        var yd = yearMap[year];
        var yMonCount = Object.keys(yd.monitors).length;
        var isExp = expandedYears[year] || false;
        html += '<div class="year-group"><div class="year-header" onclick="toggleYear(\'' + year + '\')">';
        html += '<span class="expand-icon ' + (isExp ? 'expanded' : '') + '" id="year-icon-' + year + '">&#9654;</span>';
        html += '<span class="year-label">' + year + '</span>';
        html += '<div class="year-stats">';
        html += '<span class="year-stat">' + yMonCount + ' monitor' + (yMonCount !== 1 ? 's' : '') + '</span>';
        html += '<span class="year-stat detected">' + yd.detected + ' detected</span>';
        html += '<span class="year-stat escalated">' + (yd.escalated > 0 ? yd.escalated + ' escalated' : '-') + '</span>';
        html += '</div></div>';
        html += '<div class="year-content ' + (isExp ? 'expanded' : '') + '" id="year-content-' + year + '">';

        var sortedMonths = Object.keys(yd.months).sort(function(a, b) { return b - a; });
        html += '<table class="month-summary-table"><thead><tr><th class="expand-cell"></th><th>Month</th><th>Monitors</th><th>Detected</th><th>Escalated</th></tr></thead><tbody>';

        sortedMonths.forEach(function(month) {
            var md = yd.months[month];
            var mMonCount = Object.keys(md.monitors).length;
            var mk = year + '-' + month;
            var isMExp = expandedMonths[mk];
            html += '<tr class="month-row" onclick="toggleMonth(\'' + year + '\', \'' + month + '\')">';
            html += '<td class="expand-cell"><span class="expand-icon ' + (isMExp ? 'expanded' : '') + '" id="month-icon-' + mk + '">&#9654;</span></td>';
            html += '<td class="month-cell">' + monthNames[parseInt(month)] + '</td>';
            html += '<td class="monitors-cell">' + mMonCount + '</td>';
            html += '<td class="detected-cell">' + md.detected + '</td>';
            html += '<td class="escalated-cell">' + (md.escalated > 0 ? md.escalated : '-') + '</td></tr>';

            html += '<tr class="month-details" id="month-row-' + mk + '" style="display:' + (isMExp ? 'table-row' : 'none') + '">';
            html += '<td colspan="5"><div class="month-details-content" id="month-detail-' + mk + '">';
            if (isMExp) html += renderDayTable(md.days);
            html += '</div></td></tr>';
        });

        html += '</tbody></table></div></div>';
    });

    container.innerHTML = html;
}

function renderDayTable(days) {
    var sorted = Object.keys(days).sort().reverse();
    var html = '<table class="day-table"><thead><tr><th>Date</th><th>Day</th><th>Monitors</th><th>Detected</th><th>Escalated</th></tr></thead><tbody>';
    sorted.forEach(function(dk) {
        var dd = days[dk], parts = dk.split('-');
        var dMonCount = Object.keys(dd.monitors).length;
        var dateObj = new Date(parseInt(parts[0]), parseInt(parts[1]) - 1, parseInt(parts[2]));
        html += '<tr class="clickable" onclick="openDayDetail(\'' + dk + '\')">';
        html += '<td>' + (dateObj.getMonth() + 1) + '/' + dateObj.getDate() + '</td>';
        html += '<td>' + dayNames[dateObj.getDay()] + '</td>';
        html += '<td class="monitors-cell">' + dMonCount + '</td>';
        html += '<td class="detected-cell">' + dd.detected + '</td>';
        html += '<td class="escalated-cell">' + (dd.escalated > 0 ? dd.escalated : '-') + '</td></tr>';
    });
    html += '</tbody></table>';
    return html;
}

function toggleYear(year) {
    expandedYears[year] = !expandedYears[year];
    var c = document.getElementById('year-content-' + year);
    var i = document.getElementById('year-icon-' + year);
    if (expandedYears[year]) { c.classList.add('expanded'); i.classList.add('expanded'); }
    else { c.classList.remove('expanded'); i.classList.remove('expanded'); }
}

function toggleMonth(year, month) {
    var key = year + '-' + month;
    expandedMonths[key] = !expandedMonths[key];
    var row = document.getElementById('month-row-' + key);
    var icon = document.getElementById('month-icon-' + key);
    if (expandedMonths[key]) { row.style.display = 'table-row'; icon.classList.add('expanded'); loadDetectionHistory(); }
    else { row.style.display = 'none'; icon.classList.remove('expanded'); }
}

// ============================================================================
// DAY DETAIL SLIDEOUT
// ============================================================================

async function openDayDetail(dateKey) {
    document.getElementById('day-overlay').classList.add('visible');
    document.getElementById('day-slideout').classList.add('visible');
    var parts = dateKey.split('-');
    var dateObj = new Date(parseInt(parts[0]), parseInt(parts[1]) - 1, parseInt(parts[2]));
    document.getElementById('day-slideout-title').textContent = dateObj.toLocaleDateString('en-US', { weekday: 'long', month: 'long', day: 'numeric', year: 'numeric' });
    var container = document.getElementById('day-body');
    container.innerHTML = '<div class="loading">Loading...</div>';
    try {
        var data = await engineFetch('/api/fileops/history?limit=200');
        if (!data) return;
        var filtered = data.filter(function(e) { return new Date(e.EventDttm).toISOString().split('T')[0] === dateKey; });
        renderDayDetail(container, filtered);
    } catch (error) { container.innerHTML = '<div class="no-activity">Failed to load details</div>'; }
}

function renderDayDetail(container, events) {
    if (!events || events.length === 0) { container.innerHTML = '<div class="no-activity">No events for this date</div>'; return; }
    var html = '<table class="slideout-table"><thead><tr><th>Status</th><th>Monitor</th><th>Time</th><th>File</th><th>Alerts</th></tr></thead><tbody>';
    events.forEach(function(e) {
        var cls = e.EventType.toLowerCase();
        var badge = e.EventType === 'LateDetected' ? 'LATE' : e.EventType.toUpperCase();
        var alertHtml = '';
        if (e.TeamsAlertQueued) alertHtml += '<span class="alert-badge teams">Teams</span>';
        if (e.JiraTicketQueued) alertHtml += '<span class="alert-badge jira">Jira</span>';
        if (!alertHtml) alertHtml = '<span style="color:#444;">—</span>';
        html += '<tr><td><span class="status-badge ' + cls + '">' + badge + '</span></td>';
        html += '<td>' + esc(e.ConfigName) + '</td>';
        html += '<td style="font-size:11px;color:#dcdcaa;">' + formatTime(e.EventDttm) + '</td>';
        html += '<td style="font-size:11px;">' + (e.FileDetectedName ? esc(e.FileDetectedName) : '—') + '</td>';
        html += '<td>' + alertHtml + '</td></tr>';
    });
    html += '</tbody></table>';
    container.innerHTML = html;
}

function closeDayPanel() {
    document.getElementById('day-overlay').classList.remove('visible');
    document.getElementById('day-slideout').classList.remove('visible');
}

// ============================================================================
// UTILITIES
// ============================================================================

function esc(text) {
    if (!text) return '';
    var div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
}

function escAttr(text) {
    if (!text) return '';
    return text.replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/'/g, '&#39;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function formatTime(dateStr) {
    if (!dateStr) return '';
    return new Date(dateStr).toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit' });
}

function fmtTimeOnly(timeStr) {
    if (!timeStr) return '';
    var p = timeStr.split(':');
    if (p.length >= 2) {
        var h = parseInt(p[0]), m = p[1];
        return (h > 12 ? h - 12 : (h === 0 ? 12 : h)) + ':' + m + ' ' + (h >= 12 ? 'PM' : 'AM');
    }
    return timeStr;
}

function fmtTimeInput(timeStr) {
    if (!timeStr) return '';
    var p = timeStr.split(':');
    if (p.length >= 2) return p[0].padStart(2, '0') + ':' + p[1].padStart(2, '0');
    return timeStr;
}

function showConnectionError(msg) {
    var el = document.getElementById('connection-error');
    el.textContent = msg;
    el.classList.add('visible');
}

function hideConnectionError() {
    document.getElementById('connection-error').classList.remove('visible');
}

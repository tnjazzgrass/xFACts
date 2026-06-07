/* ============================================================================
   xFACts Control Center - File Monitoring (file-monitoring.js)
   Location: E:\xFACts-ControlCenter\public\js\file-monitoring.js
   Version: Tracked in dbo.System_Metadata (component: FileOps)

   Page module for the File Monitoring dashboard. Loaded by the cc-shared.js
   bootloader, which reads the body's data-cc-prefix and calls flm_init. Owns
   the daily monitor queue, status summary, configuration cards, detection
   history tree, the slide-up management console with inline-edit monitor
   rows, the server list, the scheduled-monitors modal, the day detail
   slideout, and the new-webhook modal.

   FILE ORGANIZATION
   -----------------
   CONSTANTS: ENGINE PROCESSES
   CONSTANTS: ACTION DISPATCH
   CONSTANTS: LOOKUPS
   STATE: PAGE STATE
   FUNCTIONS: INITIALIZATION
   FUNCTIONS: ACTION DISPATCH
   FUNCTIONS: DATA LOADING
   FUNCTIONS: DAILY QUEUE
   FUNCTIONS: STATUS SUMMARY
   FUNCTIONS: CONFIGURATION CARDS
   FUNCTIONS: MANAGEMENT CONSOLE
   FUNCTIONS: MONITOR LIST
   FUNCTIONS: INLINE EDIT
   FUNCTIONS: ADD MONITOR
   FUNCTIONS: SAVE MONITOR
   FUNCTIONS: WEBHOOK MODAL
   FUNCTIONS: SERVER LIST
   FUNCTIONS: SCHEDULED MODAL
   FUNCTIONS: DETECTION HISTORY
   FUNCTIONS: DAY DETAIL
   FUNCTIONS: UTILITIES
   FUNCTIONS: PAGE LIFECYCLE HOOKS
   ============================================================================ */

/* ============================================================================
   CONSTANTS: ENGINE PROCESSES
   ----------------------------------------------------------------------------
   Engine process map consumed by the shared engine-card system to bind this
   page's SFTP scan process to its status card.
   Prefix: flm
   ============================================================================ */

/*
 * Engine process map consumed by cc_connectEngineEvents to populate the SFTP
 * engine card. Declared with var so the bootloader can read it off window.
 */
var flm_ENGINE_PROCESSES = {
    'Scan-SFTPFiles': { slug: 'sftp' }
};

/* ============================================================================
   CONSTANTS: ACTION DISPATCH
   ----------------------------------------------------------------------------
   Dispatch tables mapping each data-action-click and data-action-change
   value to its handler function. The delegated body listeners in flm_init
   route events through these tables.
   Prefix: flm
   ============================================================================ */

/*
 * Click action dispatch table. Maps each data-action-click value to its
 * handler; the delegated body listener in flm_init routes to these.
 */
const flm_clickActions = {
    'flm-open-scheduled': flm_openScheduledModal,
    'flm-open-console': flm_openConsoleFromCard,
    'flm-open-console-monitor': flm_openConsoleToMonitor,
    'flm-flip-console': flm_flipConsole,
    'flm-add-monitor': flm_addNewMonitor,
    'flm-close-console': flm_closeConsole,
    'flm-close-day': flm_closeDayPanel,
    'flm-close-scheduled': flm_closeScheduledModal,
    'flm-close-webhook': flm_closeWebhookModal,
    'flm-save-webhook': flm_saveNewWebhook,
    'flm-toggle-year': flm_toggleYear,
    'flm-toggle-month': flm_toggleMonth,
    'flm-open-day': flm_openDayDetail,
    'flm-toggle-field': flm_toggleFieldAction,
    'flm-set-priority': flm_setPriorityAction,
    'flm-save-row': flm_saveRowAction,
    'flm-cancel-row': flm_cancelRowAction
};

/*
 * Change action dispatch table. Maps each data-action-change value to its
 * handler; the delegated body listener in flm_init routes to these.
 */
const flm_changeActions = {
    'flm-set-field': flm_setFieldAction,
    'flm-select-webhook': flm_selectWebhookAction
};

/* ============================================================================
   CONSTANTS: LOOKUPS
   ----------------------------------------------------------------------------
   Static lookup arrays for monitor-row rendering: day labels and SQL
   day-column suffixes for the day toggle badges, and the Jira priority
   button definitions.
   Prefix: flm
   ============================================================================ */

/* Two-letter day labels for the monitor-row day toggle badges, Sun-first. */
const flm_DAY_LABELS = ['Su', 'Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa'];

/*
 * SQL day-column suffixes for the monitor-row day toggle badges, Sun-first.
 * Combined as 'Check' + suffix to address MonitorConfig day columns.
 */
const flm_DAY_KEYS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];

/* Jira priority buttons rendered in each monitor row, in display order. */
const flm_PRIORITIES = [
    { key: 'Highest', label: 'Highest', cls: 'flm-pri-highest' },
    { key: 'High', label: 'High', cls: 'flm-pri-high' },
    { key: 'Medium', label: 'Medium', cls: 'flm-pri-medium' },
    { key: 'Low', label: 'Low', cls: 'flm-pri-low' }
];

/* ============================================================================
   STATE: PAGE STATE
   ----------------------------------------------------------------------------
   Module-level mutable state: cached server, monitor, webhook, and
   subscription collections; detection-history expand maps; per-row unsaved
   edits; the active console face; and modal handles.
   Prefix: flm
   ============================================================================ */

/* Cached SFTP server configurations from /api/fileops/servers. */
var flm_servers = [];

/* Cached monitor configurations from /api/fileops/configs. */
var flm_configs = [];

/* Cached Teams webhook configurations from /api/fileops/webhooks. */
var flm_webhooks = [];

/* Cached Teams webhook subscriptions from /api/fileops/subscriptions. */
var flm_subscriptions = [];

/* Expanded-state map for detection-history year groups, keyed by year. */
var flm_expandedYears = {};

/* Expanded-state map for detection-history month rows, keyed by year-month. */
var flm_expandedMonths = {};

/* Per-row unsaved-edit map, keyed by config id; each value is a field-delta object. */
var flm_dirtyRows = {};

/* The currently displayed console face, either 'monitors' or 'servers'. */
var flm_currentFace = 'monitors';

/* The config id whose row triggered the new-webhook modal, or null. */
var flm_webhookModalForRowId = null;

/* The interval handle for the scheduled-modal countdown ticker, or null. */
var flm_schedCountdownInterval = null;

/* ============================================================================
   FUNCTIONS: INITIALIZATION
   ----------------------------------------------------------------------------
   Page entry point invoked by the cc-shared.js bootloader.
   Prefix: flm
   ============================================================================ */

/*
 * Page entry point invoked by the cc-shared.js bootloader. Registers the
 * delegated click and change listeners, connects the engine card system,
 * and loads all dashboard data.
 */
async function flm_init() {
    document.body.addEventListener('click', flm_dispatchClick);
    document.body.addEventListener('change', flm_dispatchChange);
    cc_connectEngineEvents();
    await flm_loadServers();
    await flm_loadWebhooks();
    await flm_loadSubscriptions();
    await flm_loadAllData();
    flm_loadDetectionHistory();
    flm_loadScheduledCount();
}

/* ============================================================================
   FUNCTIONS: ACTION DISPATCH
   ----------------------------------------------------------------------------
   Delegated event dispatchers that resolve the nearest element carrying an
   action attribute and route it to the matching handler in the dispatch
   tables.
   Prefix: flm
   ============================================================================ */

/*
 * Delegated click dispatcher. Resolves the nearest element carrying a
 * data-action-click attribute and routes it to the matching handler.
 */
function flm_dispatchClick(event) {
    var el = event.target.closest('[data-action-click]');
    if (!el) return;
    var action = el.getAttribute('data-action-click');
    var handler = flm_clickActions[action];
    if (handler) handler(el, event);
}

/*
 * Delegated change dispatcher. Resolves the nearest element carrying a
 * data-action-change attribute and routes it to the matching handler.
 */
function flm_dispatchChange(event) {
    var el = event.target.closest('[data-action-change]');
    if (!el) return;
    var action = el.getAttribute('data-action-change');
    var handler = flm_changeActions[action];
    if (handler) handler(el, event);
}

/* ============================================================================
   FUNCTIONS: DATA LOADING
   ----------------------------------------------------------------------------
   Functions that fetch dashboard data from the page API endpoints into the
   module caches and refresh the header timestamp.
   Prefix: flm
   ============================================================================ */

/*
 * Loads the daily queue and configuration data in parallel, then updates
 * the page timestamp.
 */
async function flm_loadAllData() {
    await Promise.all([
        flm_loadDailyQueue(),
        flm_loadConfigs()
    ]);
    flm_updateLastRefresh();
}

/* Loads SFTP server configurations into the module cache. */
async function flm_loadServers() {
    try {
        var result = await cc_engineFetch('/api/fileops/servers');
        if (!result) return;
        flm_servers = result;
    } catch (error) {
        console.error('Error loading servers:', error);
    }
}

/* Loads Teams webhook configurations into the module cache. */
async function flm_loadWebhooks() {
    try {
        var result = await cc_engineFetch('/api/fileops/webhooks');
        if (!result) return;
        flm_webhooks = result;
    } catch (error) {
        console.error('Error loading webhooks:', error);
    }
}

/* Loads Teams webhook subscriptions into the module cache. */
async function flm_loadSubscriptions() {
    try {
        var result = await cc_engineFetch('/api/fileops/subscriptions');
        if (!result) return;
        flm_subscriptions = result;
    } catch (error) {
        console.error('Error loading subscriptions:', error);
    }
}

/* Loads monitor configurations and updates the configuration card counts. */
async function flm_loadConfigs() {
    try {
        var result = await cc_engineFetch('/api/fileops/configs');
        if (!result) return;
        flm_configs = result;
        document.getElementById('flm-monitor-count').textContent = flm_configs.length;
        document.getElementById('flm-server-count').textContent = flm_servers.length;
    } catch (error) {
        console.error('Error loading configs:', error);
    }
}

/* Returns the subscriptions whose trigger type matches a monitor name. */
function flm_getSubscriptionsForMonitor(configName) {
    if (!configName || !flm_subscriptions.length) return [];
    return flm_subscriptions.filter(function(s) {
        return s.TriggerType === configName;
    });
}

/* Updates the last-refresh timestamp shown in the header refresh info. */
function flm_updateLastRefresh() {
    var el = document.getElementById('cc-last-update');
    if (!el) return;
    var now = new Date();
    el.textContent = now.toLocaleTimeString('en-US', {
        hour: '2-digit', minute: '2-digit', second: '2-digit'
    });
}

/* ============================================================================
   FUNCTIONS: DAILY QUEUE
   ----------------------------------------------------------------------------
   Functions that load and render the daily monitor queue, grouped into
   escalated, monitoring, and detected sections.
   Prefix: flm
   ============================================================================ */

/* Loads the monitor status feed and renders the daily queue and summary. */
async function flm_loadDailyQueue() {
    try {
        var data = await cc_engineFetch('/api/fileops/status');
        if (!data) return;
        flm_renderDailyQueue(data);
        flm_renderStatusSummary(data);
    } catch (error) {
        console.error('Error loading daily queue:', error);
    }
}

/*
 * Renders today's monitor activity into the queue table, grouped into the
 * escalated, monitoring, and detected sections.
 */
function flm_renderDailyQueue(data) {
    var escalated = [];
    var detected = [];
    var monitoring = [];
    var today = flm_todayKey();

    if (data && data.length > 0) {
        data.forEach(function(m) {
            if (!m.LastScannedDttm || m.LastScannedDttm.split(' ')[0] < today) return;
            if (m.LastStatus === 'Escalated') escalated.push(m);
            else if (m.LastStatus === 'Detected' || m.LastStatus === 'LateDetected') detected.push(m);
            else if (m.LastStatus === 'Monitoring') monitoring.push(m);
        });
    }

    detected.sort(function(a, b) {
        var ta = a.FileDetectedDttm || '';
        var tb = b.FileDetectedDttm || '';
        return tb.localeCompare(ta);
    });

    escalated.sort(function(a, b) {
        var ta = a.EscalatedDttm || a.EscalationTime || '';
        var tb = b.EscalatedDttm || b.EscalationTime || '';
        return tb.localeCompare(ta);
    });

    var html = '';
    if (escalated.length > 0) {
        html += flm_renderQueueRows(escalated);
    } else {
        html += '<tr><td colspan="4" class="flm-queue-section-empty">No current escalations</td></tr>';
    }
    html += '<tr><td colspan="4" class="flm-queue-divider"></td></tr>';
    if (monitoring.length > 0) {
        html += flm_renderQueueRows(monitoring);
    } else {
        html += '<tr><td colspan="4" class="flm-queue-section-empty">No current monitoring</td></tr>';
    }
    html += '<tr><td colspan="4" class="flm-queue-divider"></td></tr>';
    if (detected.length > 0) {
        html += flm_renderQueueRows(detected);
    } else {
        html += '<tr><td colspan="4" class="flm-queue-section-empty">No detections yet today</td></tr>';
    }

    document.getElementById('flm-queue-body').innerHTML = html;
}

/* Builds the table rows for a set of monitors in the daily queue. */
function flm_renderQueueRows(monitors) {
    var html = '';
    monitors.forEach(function(m) {
        var badgeCls = flm_statusBadgeClass(m.LastStatus);
        var txt = m.LastStatus === 'LateDetected' ? 'LATE' : m.LastStatus.toUpperCase();
        var time = flm_getTimeDisplay(m);
        var file = m.FileDetectedName
            ? '<span class="flm-monitor-file">' + cc_escapeHtml(m.FileDetectedName) + '</span>'
            : '<span class="flm-empty-cell">\u2014</span>';
        html += '<tr class="flm-queue-row" data-action-click="flm-open-console-monitor" data-action-flm-id="' + m.ConfigId + '">';
        html += '<td class="flm-monitor-table-td"><span class="flm-status-badge ' + badgeCls + '">' + txt + '</span></td>';
        html += '<td class="flm-monitor-table-td"><span class="flm-monitor-name">' + cc_escapeHtml(m.ConfigName) + '</span></td>';
        html += '<td class="flm-monitor-table-td"><span class="flm-monitor-time">' + time + '</span></td>';
        html += '<td class="flm-monitor-table-td">' + file + '</td></tr>';
    });
    return html;
}

/* Chooses the most relevant time to display for a monitor by status. */
function flm_getTimeDisplay(m) {
    if (m.LastStatus === 'Detected' || m.LastStatus === 'LateDetected') {
        if (m.FileDetectedDttm) return cc_formatTimeOfDay(m.FileDetectedDttm);
    }
    if (m.LastStatus === 'Escalated') {
        if (m.EscalatedDttm) return cc_formatTimeOfDay(m.EscalatedDttm);
        if (m.EscalationTime) return flm_fmtTimeOnly(m.EscalationTime);
    }
    if (m.LastStatus === 'Monitoring') {
        if (m.LastScannedDttm) return cc_formatTimeOfDay(m.LastScannedDttm);
        if (m.CheckStartTime) return flm_fmtTimeOnly(m.CheckStartTime);
    }
    if (m.LastScannedDttm) return cc_formatTimeOfDay(m.LastScannedDttm);
    if (m.CheckStartTime) return flm_fmtTimeOnly(m.CheckStartTime);
    return '\u2014';
}

/* ============================================================================
   FUNCTIONS: STATUS SUMMARY
   ----------------------------------------------------------------------------
   Functions that compute the day's escalated, monitoring, and detected
   counts and update the three summary cards.
   Prefix: flm
   ============================================================================ */

/*
 * Computes today's escalated, monitoring, and detected counts and updates
 * the three summary cards.
 */
function flm_renderStatusSummary(data) {
    var escCount = 0;
    var monCount = 0;
    var detCount = 0;
    var today = flm_todayKey();

    if (data && data.length > 0) {
        data.forEach(function(m) {
            if (!m.LastScannedDttm || m.LastScannedDttm.split(' ')[0] < today) return;
            if (m.LastStatus === 'Escalated') escCount++;
            else if (m.LastStatus === 'Monitoring') monCount++;
            else if (m.LastStatus === 'Detected' || m.LastStatus === 'LateDetected') detCount++;
        });
    }

    var elEsc = document.getElementById('flm-val-escalated');
    var elMon = document.getElementById('flm-val-monitoring');
    var elDet = document.getElementById('flm-val-detected');

    elEsc.textContent = escCount;
    elEsc.className = 'flm-card-value ' + (escCount > 0 ? 'flm-card-value-escalated' : 'flm-zero');

    elMon.textContent = monCount;
    elMon.className = 'flm-card-value ' + (monCount > 0 ? 'flm-card-value-monitoring' : 'flm-zero');

    elDet.textContent = detCount;
    elDet.className = 'flm-card-value ' + (detCount > 0 ? 'flm-card-value-detected' : 'flm-zero');

    var cardEsc = document.getElementById('flm-card-escalated');
    cardEsc.className = 'flm-summary-card' + (escCount > 0 ? ' flm-card-critical' : '');
}

/* ============================================================================
   FUNCTIONS: CONFIGURATION CARDS
   ----------------------------------------------------------------------------
   Handlers for the configuration card clicks that open the management
   console to the requested face.
   Prefix: flm
   ============================================================================ */

/*
 * Opens the management console from a configuration card click, using the
 * card's data-action-flm-face argument to pick the face.
 */
function flm_openConsoleFromCard(target) {
    var face = target.getAttribute('data-action-flm-face') || 'monitors';
    flm_openConsole(face);
}

/* ============================================================================
   FUNCTIONS: MANAGEMENT CONSOLE
   ----------------------------------------------------------------------------
   Functions that open, close, flip, and apply the face state of the
   slide-up management console.
   Prefix: flm
   ============================================================================ */

/* Opens the slide-up management console to the requested face. */
function flm_openConsole(face) {
    var overlay = document.getElementById('flm-slideup-console');
    var dialog = overlay.querySelector('.cc-dialog-slideup');
    overlay.classList.add('cc-open');
    requestAnimationFrame(function() {
        dialog.classList.add('cc-open');
    });
    flm_currentFace = face || 'monitors';
    flm_applyConsoleFace();
}

/* Opens the console to the monitors face and scrolls to a specific row. */
function flm_openConsoleToMonitor(target) {
    var configId = target.getAttribute('data-action-flm-id');
    flm_openConsole('monitors');
    setTimeout(function() {
        var el = document.querySelector('.flm-monitor-row[data-id="' + configId + '"]');
        if (el) el.scrollIntoView({ behavior: 'smooth', block: 'center' });
    }, 100);
}

/* Closes the management console, prompting first if there are unsaved edits. */
function flm_closeConsole() {
    if (Object.keys(flm_dirtyRows).length > 0) {
        cc_showConfirm('You have unsaved changes. Close anyway?').then(function(ok) {
            if (!ok) return;
            flm_dirtyRows = {};
            flm_hideConsole();
        });
        return;
    }
    flm_hideConsole();
}

/* Removes the open-state classes that reveal the console. */
function flm_hideConsole() {
    var overlay = document.getElementById('flm-slideup-console');
    var dialog = overlay.querySelector('.cc-dialog-slideup');
    dialog.classList.remove('cc-open');
    dialog.addEventListener('transitionend', function handler() {
        dialog.removeEventListener('transitionend', handler);
        overlay.classList.remove('cc-open');
    }, { once: true });
}

/* Flips the console between the monitors and servers faces. */
function flm_flipConsole() {
    flm_currentFace = flm_currentFace === 'monitors' ? 'servers' : 'monitors';
    flm_applyConsoleFace();
}

/* Applies the current face to the flip card, title, add button, and list. */
function flm_applyConsoleFace() {
    var flipCard = document.getElementById('flm-console-flip-card');
    var title = document.getElementById('flm-console-face-title');
    var addBtn = document.getElementById('flm-console-add-btn');

    if (flm_currentFace === 'servers') {
        flipCard.classList.add('flm-console-flipped');
        title.textContent = 'Servers';
        addBtn.classList.add('cc-hidden');
        flm_renderServerList();
    } else {
        flipCard.classList.remove('flm-console-flipped');
        title.textContent = 'Monitors';
        addBtn.classList.remove('cc-hidden');
        flm_renderMonitorList();
    }
}

/* ============================================================================
   FUNCTIONS: MONITOR LIST
   ----------------------------------------------------------------------------
   Functions that render the inline-edit monitor list and individual monitor
   rows on the console front face.
   Prefix: flm
   ============================================================================ */

/* Renders the inline-edit monitor list on the console's front face. */
function flm_renderMonitorList() {
    var container = document.getElementById('flm-monitor-list');
    if (flm_configs.length === 0) {
        container.innerHTML = '<div class="flm-no-activity">No monitors configured yet</div>';
        return;
    }

    var active = flm_configs.filter(function(c) { return c.IsEnabled; });
    var inactive = flm_configs.filter(function(c) { return !c.IsEnabled; });

    var html = '<div class="flm-monitor-col-header">';
    html += '<div class="flm-col-grid">';
    html += '<span class="flm-monitor-col-label">Status</span>';
    html += '<span class="flm-monitor-col-label">Monitor</span>';
    html += '<span class="flm-monitor-col-label">Server</span>';
    html += '<span class="flm-monitor-col-label">Path</span>';
    html += '<span class="flm-monitor-col-label">Pattern</span>';
    html += '<span class="flm-monitor-col-label">Days</span>';
    html += '<span class="flm-monitor-col-label">Start</span>';
    html += '<span class="flm-monitor-col-label">End</span>';
    html += '<span class="flm-monitor-col-label">Escalate</span>';
    html += '</div>';
    html += '<div class="flm-col-subs"><span class="flm-monitor-col-label">Alerts</span></div>';
    html += '</div>';

    active.forEach(function(c) { html += flm_renderMonitorRow(c); });
    inactive.forEach(function(c) { html += flm_renderMonitorRow(c); });

    container.innerHTML = html;
}

/* Builds the markup for a single inline-editable monitor row. */
function flm_renderMonitorRow(c) {
    var id = c.ConfigId;
    var isDirty = !!flm_dirtyRows[id];
    var rowCls = 'flm-monitor-row' + (isDirty ? ' flm-dirty' : '');
    var enabled = flm_getVal(id, 'IsEnabled', c.IsEnabled);
    if (!enabled) rowCls += ' flm-row-disabled';

    var name = flm_getVal(id, 'ConfigName', c.ConfigName);
    var serverId = flm_getVal(id, 'ServerId', c.ServerId);
    var path = flm_getVal(id, 'SftpPath', c.SftpPath);
    var pattern = flm_getVal(id, 'FilePattern', c.FilePattern);
    var startTime = flm_getVal(id, 'CheckStartTime', flm_fmtTimeInput(c.CheckStartTime));
    var endTime = flm_getVal(id, 'CheckEndTime', flm_fmtTimeInput(c.CheckEndTime));
    var escTime = flm_getVal(id, 'EscalationTime', flm_fmtTimeInput(c.EscalationTime));
    var notifyDet = flm_getVal(id, 'NotifyOnDetection', c.NotifyOnDetection);
    var notifyEsc = flm_getVal(id, 'NotifyOnEscalation', c.NotifyOnEscalation);
    var jira = flm_getVal(id, 'CreateJiraOnEscalation', c.CreateJiraOnEscalation);
    var priority = flm_getVal(id, 'DefaultPriority', c.DefaultPriority);

    var serverOpts = flm_servers.map(function(sv) {
        var sel = sv.ServerId === serverId ? ' selected' : '';
        return '<option value="' + sv.ServerId + '"' + sel + '>' + cc_escapeHtml(sv.ServerName) + '</option>';
    }).join('');

    var dayBadges = '';
    for (var i = 0; i < 7; i++) {
        var key = 'Check' + flm_DAY_KEYS[i];
        var isOn = flm_getVal(id, key, c[key]);
        dayBadges += '<span class="flm-day-badge ' + (isOn ? 'flm-day-on' : 'flm-day-off') + '" data-action-click="flm-toggle-field" data-action-flm-id="' + id + '" data-action-flm-field="' + key + '" data-action-flm-value="' + (!isOn) + '">' + flm_DAY_LABELS[i] + '</span>';
    }

    var detBadge = flm_miniBadge(id, 'NotifyOnDetection', notifyDet, 'flm-mini-det-on', 'DET');
    var escBadge = flm_miniBadge(id, 'NotifyOnEscalation', notifyEsc, 'flm-mini-esc-on', 'ESC');
    var jiraBadge = flm_miniBadge(id, 'CreateJiraOnEscalation', jira, 'flm-mini-jira-on', 'JIRA');

    var priGrid = '<div class="flm-priority-grid">';
    flm_PRIORITIES.forEach(function(p) {
        var sel = (priority === p.key) ? ' ' + p.cls : '';
        var cls = 'flm-priority-btn' + sel + (jira ? '' : ' flm-priority-disabled');
        var attrs = jira
            ? ' data-action-click="flm-set-priority" data-action-flm-id="' + id + '" data-action-flm-value="' + p.key + '"'
            : '';
        priGrid += '<button class="' + cls + '"' + attrs + ' title="' + p.key + '">' + p.label + '</button>';
    });
    priGrid += '</div>';

    var statusBadge = enabled
        ? '<span class="flm-status-badge flm-badge-active flm-status-toggle" data-action-click="flm-toggle-field" data-action-flm-id="' + id + '" data-action-flm-field="IsEnabled" data-action-flm-value="false">ACTIVE</span>'
        : '<span class="flm-status-badge flm-badge-inactive flm-status-toggle" data-action-click="flm-toggle-field" data-action-flm-id="' + id + '" data-action-flm-field="IsEnabled" data-action-flm-value="true">OFF</span>';

    var html = '<div class="' + rowCls + '" data-id="' + id + '">';
    html += '<div class="flm-monitor-row-fields">';

    html += '<div class="flm-row-grid">';
    html += statusBadge;
    html += '<input class="flm-inline-input flm-name-input" value="' + flm_escAttr(name) + '" data-action-change="flm-set-field" data-action-flm-id="' + id + '" data-action-flm-field="ConfigName">';
    html += '<select class="flm-inline-input" data-action-change="flm-set-field" data-action-flm-id="' + id + '" data-action-flm-field="ServerId" data-action-flm-numeric="1">' + serverOpts + '</select>';
    html += '<input class="flm-inline-input" value="' + flm_escAttr(path) + '" data-action-change="flm-set-field" data-action-flm-id="' + id + '" data-action-flm-field="SftpPath" placeholder="/path/">';
    html += '<input class="flm-inline-input" value="' + flm_escAttr(pattern) + '" data-action-change="flm-set-field" data-action-flm-id="' + id + '" data-action-flm-field="FilePattern" placeholder="*.txt">';
    html += '<div class="flm-monitor-row-days">' + dayBadges + '</div>';
    html += '<input type="time" class="flm-inline-input" value="' + startTime + '" data-action-change="flm-set-field" data-action-flm-id="' + id + '" data-action-flm-field="CheckStartTime">';
    html += '<input type="time" class="flm-inline-input" value="' + endTime + '" data-action-change="flm-set-field" data-action-flm-id="' + id + '" data-action-flm-field="CheckEndTime">';
    html += '<input type="time" class="flm-inline-input" value="' + escTime + '" data-action-change="flm-set-field" data-action-flm-id="' + id + '" data-action-flm-field="EscalationTime">';
    html += '</div>';

    html += '<div class="flm-row-jira-section">';
    html += jiraBadge;
    html += priGrid;
    html += '</div>';

    html += '<div class="flm-row-subs">';
    html += flm_renderSubscriptionZone(c, id, detBadge, escBadge);
    html += '</div>';

    html += '</div>';

    html += '<div class="flm-monitor-save-bar' + (isDirty ? ' flm-save-bar-visible' : '') + '">';
    html += '<button class="flm-btn-action" data-action-click="flm-cancel-row" data-action-flm-id="' + id + '">Cancel</button>';
    html += '<button class="flm-btn-action" data-action-click="flm-save-row" data-action-flm-id="' + id + '">Save</button>';
    html += '</div>';

    html += '</div>';
    return html;
}

/* Builds a single notification mini-badge for a monitor row. */
function flm_miniBadge(id, field, isOn, onClass, label) {
    var cls = 'flm-mini-badge ' + (isOn ? onClass : 'flm-mini-off');
    return '<span class="' + cls + '" data-action-click="flm-toggle-field" data-action-flm-id="' + id + '" data-action-flm-field="' + field + '" data-action-flm-value="' + (!isOn) + '">' + label + '</span>';
}

/*
 * Builds the subscription zone for a monitor row: existing channel badges or
 * a webhook selector with an optional preview badge.
 */
function flm_renderSubscriptionZone(c, id, detBadge, escBadge) {
    var html = '';
    var monitorSubs = flm_getSubscriptionsForMonitor(c.ConfigName);
    if (monitorSubs.length > 0) {
        monitorSubs.forEach(function(sub) {
            var activeCls = sub.IsActive ? '' : ' flm-sub-inactive';
            html += '<div class="flm-sub-group">';
            html += '<span class="flm-sub-channel-badge' + activeCls + '" title="' + flm_escAttr(sub.WebhookName) + '">' + cc_escapeHtml(sub.ChannelName) + '</span>';
            html += '<div class="flm-sub-det-esc">' + detBadge + escBadge + '</div>';
            html += '</div>';
        });
        return html;
    }

    if (flm_webhooks.length > 0) {
        var selWebhookId = flm_getVal(id, 'WebhookConfigId', '');
        var webhookOpts = '<option value="">No Teams Routing</option>';
        flm_webhooks.forEach(function(wh) {
            var sel = (selWebhookId && selWebhookId == wh.ConfigId) ? ' selected' : '';
            webhookOpts += '<option value="' + wh.ConfigId + '"' + sel + '>' + cc_escapeHtml(wh.WebhookName) + '</option>';
        });
        webhookOpts += '<option value="new">+ New Webhook...</option>';
        html += '<div class="flm-sub-group">';
        html += '<select class="flm-inline-input flm-sub-webhook-select" data-action-change="flm-select-webhook" data-action-flm-id="' + id + '">' + webhookOpts + '</select>';
        if (selWebhookId) {
            var selWebhook = flm_webhooks.find(function(w) { return w.ConfigId == selWebhookId; });
            var previewName = selWebhook ? selWebhook.WebhookName : 'Selected';
            html += '<div class="flm-sub-group flm-sub-preview">';
            html += '<span class="flm-sub-channel-badge flm-sub-preview" title="Will be created on save">' + cc_escapeHtml(previewName) + '</span>';
            html += '<div class="flm-sub-det-esc">' + detBadge + escBadge + '</div>';
            html += '</div>';
        }
        html += '</div>';
    }
    return html;
}

/* ============================================================================
   FUNCTIONS: INLINE EDIT
   ----------------------------------------------------------------------------
   Functions that read and record per-row unsaved edits and handle the
   inline field, toggle, priority, webhook, cancel, and save controls.
   Prefix: flm
   ============================================================================ */

/* Returns the current value for a row field, preferring an unsaved edit. */
function flm_getVal(id, field, original) {
    if (flm_dirtyRows[id] && flm_dirtyRows[id].hasOwnProperty(field)) return flm_dirtyRows[id][field];
    return original;
}

/* Records an unsaved edit for a row field and re-renders the monitor list. */
function flm_setField(id, field, value) {
    if (!flm_dirtyRows[id]) flm_dirtyRows[id] = {};
    flm_dirtyRows[id][field] = value;
    flm_renderMonitorList();
}

/* Change handler for inline text, select, and time inputs in a monitor row. */
function flm_setFieldAction(target) {
    var id = parseInt(target.getAttribute('data-action-flm-id'), 10);
    var field = target.getAttribute('data-action-flm-field');
    var value = target.value;
    if (target.getAttribute('data-action-flm-numeric') === '1') {
        value = parseInt(value, 10);
    }
    flm_setField(id, field, value);
}

/* Click handler for the day, notification, and status toggle badges. */
function flm_toggleFieldAction(target) {
    var id = parseInt(target.getAttribute('data-action-flm-id'), 10);
    var field = target.getAttribute('data-action-flm-field');
    var value = target.getAttribute('data-action-flm-value') === 'true';
    flm_setField(id, field, value);
}

/* Click handler for the Jira priority buttons. */
function flm_setPriorityAction(target) {
    var id = parseInt(target.getAttribute('data-action-flm-id'), 10);
    var value = target.getAttribute('data-action-flm-value');
    flm_setField(id, 'DefaultPriority', value);
}

/*
 * Change handler for the webhook selector; opens the new-webhook modal when
 * the sentinel option is chosen, otherwise records the selected webhook id.
 */
function flm_selectWebhookAction(target) {
    var id = parseInt(target.getAttribute('data-action-flm-id'), 10);
    if (target.value === 'new') {
        target.value = '';
        flm_openWebhookModal(id);
        return;
    }
    flm_setField(id, 'WebhookConfigId', target.value ? parseInt(target.value, 10) : null);
}

/* Click handler for the row Cancel button. */
function flm_cancelRowAction(target) {
    var id = parseInt(target.getAttribute('data-action-flm-id'), 10);
    flm_cancelRowEdit(id);
}

/* Click handler for the row Save button. */
function flm_saveRowAction(target) {
    var id = parseInt(target.getAttribute('data-action-flm-id'), 10);
    flm_saveRow(id);
}

/* Discards unsaved edits for a row, removing a never-saved new monitor. */
function flm_cancelRowEdit(id) {
    delete flm_dirtyRows[id];
    if (id === -1) {
        flm_configs = flm_configs.filter(function(x) { return x.ConfigId !== -1; });
    }
    flm_renderMonitorList();
}

/* ============================================================================
   FUNCTIONS: ADD MONITOR
   ----------------------------------------------------------------------------
   Function that inserts a blank monitor row at the top of the list for
   creating a new monitor.
   Prefix: flm
   ============================================================================ */

/* Inserts a blank monitor row at the top of the list for a new monitor. */
function flm_addNewMonitor() {
    var existing = flm_configs.find(function(c) { return c.ConfigId === -1; });
    if (existing) return;

    var newConfig = {
        ConfigId: -1,
        ServerId: flm_servers.length > 0 ? flm_servers[0].ServerId : null,
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

    flm_configs.unshift(newConfig);
    flm_dirtyRows[-1] = {};
    flm_renderMonitorList();

    setTimeout(function() {
        var firstInput = document.querySelector('.flm-monitor-row[data-id="-1"] .flm-name-input');
        if (firstInput) firstInput.focus();
    }, 50);
}

/* ============================================================================
   FUNCTIONS: SAVE MONITOR
   ----------------------------------------------------------------------------
   Function that validates and persists a monitor row, then refreshes the
   dependent sections.
   Prefix: flm
   ============================================================================ */

/* Validates and persists a monitor row, then refreshes dependent sections. */
async function flm_saveRow(id) {
    var c = flm_configs.find(function(x) { return x.ConfigId === id; });
    if (!c) return;

    var d = flm_dirtyRows[id] || {};
    var name = d.hasOwnProperty('ConfigName') ? d.ConfigName : c.ConfigName;
    var path = d.hasOwnProperty('SftpPath') ? d.SftpPath : c.SftpPath;
    var pattern = d.hasOwnProperty('FilePattern') ? d.FilePattern : c.FilePattern;

    if (!name || !name.trim()) { cc_showAlert('Monitor name is required'); return; }
    if (!path || !path.trim()) { cc_showAlert('SFTP path is required'); return; }
    if (!pattern || !pattern.trim()) { cc_showAlert('File pattern is required'); return; }

    path = path.trim();
    if (!path.endsWith('/')) path += '/';

    var startTime = d.hasOwnProperty('CheckStartTime') ? d.CheckStartTime : flm_fmtTimeInput(c.CheckStartTime);
    var endTime = d.hasOwnProperty('CheckEndTime') ? d.CheckEndTime : flm_fmtTimeInput(c.CheckEndTime);
    var escTime = d.hasOwnProperty('EscalationTime') ? d.EscalationTime : flm_fmtTimeInput(c.EscalationTime);

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
        var key = 'Check' + flm_DAY_KEYS[i];
        payload[key] = d.hasOwnProperty(key) ? d[key] : c[key];
    }

    try {
        var response = await cc_engineFetch('/api/fileops/config/save', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload)
        });
        if (!response) return;
        if (response.Error) {
            throw new Error(response.Error || 'Failed to save');
        }
        delete flm_dirtyRows[id];
        if (id === -1) {
            flm_configs = flm_configs.filter(function(x) { return x.ConfigId !== -1; });
        }
        await flm_loadSubscriptions();
        await flm_loadConfigs();
        flm_renderMonitorList();
        await flm_loadDailyQueue();
    } catch (error) {
        cc_showAlert('Failed to save: ' + error.message);
    }
}

/* ============================================================================
   FUNCTIONS: WEBHOOK MODAL
   ----------------------------------------------------------------------------
   Functions that open and close the new-webhook modal and create a new
   Teams webhook for the requesting row.
   Prefix: flm
   ============================================================================ */

/* Opens the new-webhook modal for the row that requested it. */
function flm_openWebhookModal(rowId) {
    flm_webhookModalForRowId = rowId;
    document.getElementById('flm-wh-new-name').value = '';
    document.getElementById('flm-wh-new-url').value = '';
    document.getElementById('flm-wh-new-desc').value = '';
    document.getElementById('flm-modal-webhook').classList.remove('cc-hidden');
    setTimeout(function() { document.getElementById('flm-wh-new-name').focus(); }, 50);
}

/*
 * Closes the new-webhook modal. A backdrop click dismisses while clicks
 * bubbling from the dialog interior are ignored.
 */
function flm_closeWebhookModal(target, event) {
    if (event && target.id === 'flm-modal-webhook' && event.target !== target) {
        return;
    }
    document.getElementById('flm-modal-webhook').classList.add('cc-hidden');
    flm_webhookModalForRowId = null;
}

/* Validates and creates a new Teams webhook, then assigns it to the row. */
async function flm_saveNewWebhook() {
    var name = document.getElementById('flm-wh-new-name').value.trim();
    var url = document.getElementById('flm-wh-new-url').value.trim();
    var desc = document.getElementById('flm-wh-new-desc').value.trim();

    if (!name) { cc_showAlert('Webhook name is required'); return; }
    if (!url) { cc_showAlert('Webhook URL is required'); return; }
    if (!url.startsWith('https://')) { cc_showAlert('Webhook URL must start with https://'); return; }

    try {
        var response = await cc_engineFetch('/api/fileops/webhook/save', {
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
        await flm_loadWebhooks();
        if (flm_webhookModalForRowId !== null) {
            flm_setField(flm_webhookModalForRowId, 'WebhookConfigId', newConfigId);
        }
        flm_closeWebhookModal();
    } catch (error) {
        cc_showAlert('Failed to create webhook: ' + error.message);
    }
}

/* ============================================================================
   FUNCTIONS: SERVER LIST
   ----------------------------------------------------------------------------
   Function that renders the SFTP server rows on the console back face.
   Prefix: flm
   ============================================================================ */

/* Renders the SFTP server rows on the console's back face. */
function flm_renderServerList() {
    var container = document.getElementById('flm-server-list');
    if (flm_servers.length === 0) {
        container.innerHTML = '<div class="flm-no-activity">No SFTP servers configured</div>';
        return;
    }

    var html = '';
    flm_servers.forEach(function(s) {
        html += '<div class="flm-server-row">';
        html += '<span class="flm-server-row-name">' + cc_escapeHtml(s.ServerName) + '</span>';
        html += '<span class="flm-server-row-host">' + cc_escapeHtml(s.SftpHost) + '</span>';
        html += '<span class="flm-server-row-port">Port ' + (s.SftpPort || 22) + '</span>';
        html += '<span class="flm-server-row-status"><span class="flm-status-badge flm-badge-active">ACTIVE</span></span>';
        html += '</div>';
    });

    container.innerHTML = html;
}

/* ============================================================================
   FUNCTIONS: SCHEDULED MODAL
   ----------------------------------------------------------------------------
   Functions that open and close the scheduled-monitors modal, load and
   render its content, drive the countdown ticker, and maintain the header
   count badge.
   Prefix: flm
   ============================================================================ */

/* Opens the scheduled-monitors modal and loads its content. */
function flm_openScheduledModal() {
    document.getElementById('flm-modal-scheduled').classList.remove('cc-hidden');
    flm_loadScheduledMonitors();
}

/*
 * Closes the scheduled-monitors modal and stops its countdown ticker.
 * A backdrop click dismisses while clicks bubbling from the dialog interior
 * are ignored.
 */
function flm_closeScheduledModal(target, event) {
    if (event && target.id === 'flm-modal-scheduled' && event.target !== target) {
        return;
    }
    document.getElementById('flm-modal-scheduled').classList.add('cc-hidden');
    if (flm_schedCountdownInterval) {
        clearInterval(flm_schedCountdownInterval);
        flm_schedCountdownInterval = null;
    }
}

/* Loads the scheduled-but-not-started monitors and renders them. */
async function flm_loadScheduledMonitors() {
    var body = document.getElementById('flm-sched-modal-body');
    body.innerHTML = '<div class="flm-loading">Loading...</div>';
    try {
        var data = await cc_engineFetch('/api/fileops/scheduled');
        if (!data) return;
        flm_updateScheduledBadge(data.length);
        flm_renderScheduledMonitors(data);
    } catch (error) {
        body.innerHTML = '<div class="flm-no-activity">Failed to load scheduled monitors</div>';
    }
}

/* Loads just the scheduled count to update the header badge. */
async function flm_loadScheduledCount() {
    try {
        var data = await cc_engineFetch('/api/fileops/scheduled');
        if (!data) return;
        flm_updateScheduledBadge(data.length);
    } catch (e) {
        console.error('Error loading scheduled count:', e);
    }
}

/* Shows or hides the scheduled-count badge in the daily queue header. */
function flm_updateScheduledBadge(count) {
    var badge = document.getElementById('flm-sched-count-badge');
    if (!badge) return;
    if (count > 0) {
        badge.textContent = count;
        badge.classList.remove('cc-hidden');
    } else {
        badge.classList.add('cc-hidden');
    }
}

/* Renders the scheduled-monitors table and starts the countdown ticker. */
function flm_renderScheduledMonitors(data) {
    var body = document.getElementById('flm-sched-modal-body');
    if (!data || data.length === 0) {
        body.innerHTML = '<div class="flm-no-activity">No monitors waiting to start today</div>';
        return;
    }

    var html = '<table class="flm-sched-table">';
    html += '<thead><tr><th class="flm-sched-table-th">Monitor</th><th class="flm-sched-table-th">Start</th><th class="flm-sched-table-th">Escalate</th><th class="flm-sched-table-th">Starts In</th></tr></thead>';
    html += '<tbody>';
    data.forEach(function(m) {
        html += '<tr>';
        html += '<td class="flm-sched-table-td flm-sched-name">' + cc_escapeHtml(m.ConfigName) + '</td>';
        html += '<td class="flm-sched-table-td flm-sched-time">' + flm_fmtTimeOnly(m.CheckStartTime) + '</td>';
        html += '<td class="flm-sched-table-td flm-sched-time">' + flm_fmtTimeOnly(m.EscalationTime) + '</td>';
        html += '<td class="flm-sched-table-td flm-sched-countdown" data-start="' + m.CheckStartTime + '"></td>';
        html += '</tr>';
    });
    html += '</tbody></table>';

    body.innerHTML = html;
    flm_updateScheduledCountdowns();
    if (flm_schedCountdownInterval) clearInterval(flm_schedCountdownInterval);
    flm_schedCountdownInterval = setInterval(flm_updateScheduledCountdowns, 1000);
}

/* Recomputes the live countdown text in each scheduled-monitor row. */
function flm_updateScheduledCountdowns() {
    var cells = document.querySelectorAll('.flm-sched-countdown');
    var now = new Date();
    cells.forEach(function(cell) {
        var startStr = cell.getAttribute('data-start');
        if (!startStr) return;
        var parts = startStr.split(':');
        var target = new Date();
        target.setHours(parseInt(parts[0], 10), parseInt(parts[1], 10), parseInt(parts[2] || 0, 10), 0);
        var diffMs = target - now;
        if (diffMs <= 0) {
            cell.textContent = 'Starting...';
            cell.classList.add('flm-sched-starting');
        } else {
            var h = Math.floor(diffMs / 3600000);
            var m = Math.floor((diffMs % 3600000) / 60000);
            var s = Math.floor((diffMs % 60000) / 1000);
            var str = '';
            if (h > 0) str += h + 'h ';
            str += m + 'm ' + s + 's';
            cell.textContent = str;
            cell.classList.remove('flm-sched-starting');
        }
    });
}

/* ============================================================================
   FUNCTIONS: DETECTION HISTORY
   ----------------------------------------------------------------------------
   Functions that load detection events and render and toggle the year,
   month, and day breakdown tree.
   Prefix: flm
   ============================================================================ */

/* Loads the detection history feed and renders the year/month/day tree. */
async function flm_loadDetectionHistory() {
    var container = document.getElementById('flm-detection-history');
    try {
        var data = await cc_engineFetch('/api/fileops/history?limit=500');
        if (!data) return;
        flm_renderDetectionHistory(container, data);
    } catch (error) {
        container.innerHTML = '<div class="flm-no-activity">Failed to load history</div>';
    }
}

/* Aggregates detection events into a year/month/day tree and renders it. */
function flm_renderDetectionHistory(container, data) {
    if (!data || data.length === 0) {
        container.innerHTML = '<div class="flm-no-activity">No detection history available</div>';
        return;
    }

    var yearMap = {};
    data.forEach(function(e) {
        var d = new Date(e.EventDttm);
        var y = d.getFullYear();
        var m = d.getMonth() + 1;
        var dayKey = d.toISOString().split('T')[0];
        if (!yearMap[y]) yearMap[y] = { detected: 0, escalated: 0, monitors: {}, months: {} };
        if (!yearMap[y].months[m]) yearMap[y].months[m] = { detected: 0, escalated: 0, monitors: {}, days: {} };
        if (!yearMap[y].months[m].days[dayKey]) yearMap[y].months[m].days[dayKey] = { detected: 0, escalated: 0, monitors: {} };
        yearMap[y].monitors[e.ConfigName] = true;
        yearMap[y].months[m].monitors[e.ConfigName] = true;
        yearMap[y].months[m].days[dayKey].monitors[e.ConfigName] = true;
        if (e.EventType === 'Escalated') {
            yearMap[y].escalated++;
            yearMap[y].months[m].escalated++;
            yearMap[y].months[m].days[dayKey].escalated++;
        } else {
            yearMap[y].detected++;
            yearMap[y].months[m].detected++;
            yearMap[y].months[m].days[dayKey].detected++;
        }
    });

    var sortedYears = Object.keys(yearMap).sort(function(a, b) { return b - a; });
    var html = '';
    sortedYears.forEach(function(year) {
        var yd = yearMap[year];
        var yMonCount = Object.keys(yd.monitors).length;
        var isExp = flm_expandedYears[year] || false;
        html += '<div class="flm-year-group"><div class="flm-year-header" data-action-click="flm-toggle-year" data-action-flm-year="' + year + '">';
        html += '<span class="flm-expand-icon ' + (isExp ? 'flm-expanded' : '') + '" id="flm-year-icon-' + year + '">&#9654;</span>';
        html += '<span class="flm-year-label">' + year + '</span>';
        html += '<div class="flm-year-stats">';
        html += '<span class="flm-year-stat">' + yMonCount + ' monitor' + (yMonCount !== 1 ? 's' : '') + '</span>';
        html += '<span class="flm-year-stat flm-stat-detected">' + yd.detected + ' detected</span>';
        html += '<span class="flm-year-stat flm-stat-escalated">' + (yd.escalated > 0 ? yd.escalated + ' escalated' : '-') + '</span>';
        html += '</div></div>';
        html += '<div class="flm-year-content ' + (isExp ? 'flm-year-content-expanded' : '') + '" id="flm-year-content-' + year + '">';

        var sortedMonths = Object.keys(yd.months).sort(function(a, b) { return b - a; });
        html += '<table class="flm-month-table"><thead><tr><th class="flm-month-table-th flm-expand-cell"></th><th class="flm-month-table-th">Month</th><th class="flm-month-table-th">Monitors</th><th class="flm-month-table-th">Detected</th><th class="flm-month-table-th">Escalated</th></tr></thead><tbody>';
        sortedMonths.forEach(function(month) {
            var md = yd.months[month];
            var mMonCount = Object.keys(md.monitors).length;
            var mk = year + '-' + month;
            var isMExp = flm_expandedMonths[mk];
            html += '<tr class="flm-month-row" data-action-click="flm-toggle-month" data-action-flm-year="' + year + '" data-action-flm-month="' + month + '">';
            html += '<td class="flm-month-table-td flm-expand-cell"><span class="flm-expand-icon ' + (isMExp ? 'flm-expanded' : '') + '" id="flm-month-icon-' + mk + '">&#9654;</span></td>';
            html += '<td class="flm-month-table-td flm-month-cell">' + cc_MONTH_NAMES[parseInt(month, 10)] + '</td>';
            html += '<td class="flm-month-table-td flm-monitors-cell">' + mMonCount + '</td>';
            html += '<td class="flm-month-table-td flm-detected-cell">' + md.detected + '</td>';
            html += '<td class="flm-month-table-td flm-escalated-cell">' + (md.escalated > 0 ? md.escalated : '-') + '</td></tr>';
            html += '<tr class="flm-month-details" id="flm-month-row-' + mk + '" style="display:' + (isMExp ? 'table-row' : 'none') + '">';
            html += '<td class="flm-month-table-td" colspan="5"><div class="flm-month-details-content" id="flm-month-detail-' + mk + '">';
            if (isMExp) html += flm_renderDayTable(md.days);
            html += '</div></td></tr>';
        });
        html += '</tbody></table></div></div>';
    });

    container.innerHTML = html;
}

/* Builds the per-day breakdown table for an expanded month. */
function flm_renderDayTable(days) {
    var sorted = Object.keys(days).sort().reverse();
    var html = '<table class="flm-day-table"><thead><tr><th class="flm-day-table-th">Date</th><th class="flm-day-table-th">Day</th><th class="flm-day-table-th">Monitors</th><th class="flm-day-table-th">Detected</th><th class="flm-day-table-th">Escalated</th></tr></thead><tbody>';
    sorted.forEach(function(dk) {
        var dd = days[dk];
        var parts = dk.split('-');
        var dMonCount = Object.keys(dd.monitors).length;
        var dateObj = new Date(parseInt(parts[0], 10), parseInt(parts[1], 10) - 1, parseInt(parts[2], 10));
        html += '<tr class="flm-day-row" data-action-click="flm-open-day" data-action-flm-date="' + dk + '">';
        html += '<td class="flm-day-table-td">' + (dateObj.getMonth() + 1) + '/' + dateObj.getDate() + '</td>';
        html += '<td class="flm-day-table-td">' + cc_DAY_NAMES[dateObj.getDay() + 1] + '</td>';
        html += '<td class="flm-day-table-td flm-monitors-cell">' + dMonCount + '</td>';
        html += '<td class="flm-day-table-td flm-detected-cell">' + dd.detected + '</td>';
        html += '<td class="flm-day-table-td flm-escalated-cell">' + (dd.escalated > 0 ? dd.escalated : '-') + '</td></tr>';
    });
    html += '</tbody></table>';
    return html;
}

/* Click handler toggling a detection-history year group open or closed. */
function flm_toggleYear(target) {
    var year = target.getAttribute('data-action-flm-year');
    flm_expandedYears[year] = !flm_expandedYears[year];
    var content = document.getElementById('flm-year-content-' + year);
    var icon = document.getElementById('flm-year-icon-' + year);
    if (flm_expandedYears[year]) {
        content.classList.add('flm-year-content-expanded');
        icon.classList.add('flm-expanded');
    } else {
        content.classList.remove('flm-year-content-expanded');
        icon.classList.remove('flm-expanded');
    }
}

/* Click handler toggling a detection-history month row open or closed. */
function flm_toggleMonth(target) {
    var year = target.getAttribute('data-action-flm-year');
    var month = target.getAttribute('data-action-flm-month');
    var key = year + '-' + month;
    flm_expandedMonths[key] = !flm_expandedMonths[key];
    var row = document.getElementById('flm-month-row-' + key);
    var icon = document.getElementById('flm-month-icon-' + key);
    if (flm_expandedMonths[key]) {
        row.style.display = 'table-row';
        icon.classList.add('flm-expanded');
        flm_loadDetectionHistory();
    } else {
        row.style.display = 'none';
        icon.classList.remove('flm-expanded');
    }
}

/* ============================================================================
   FUNCTIONS: DAY DETAIL
   ----------------------------------------------------------------------------
   Functions that open, render, and close the day detail slideout for a
   selected detection date.
   Prefix: flm
   ============================================================================ */

/* Opens the day detail slideout and loads the events for the chosen date. */
async function flm_openDayDetail(target) {
    var dateKey = target.getAttribute('data-action-flm-date');
    var overlay = document.getElementById('flm-slideout-day');
    var dialog = overlay.querySelector('.cc-dialog');
    overlay.classList.add('cc-open');
    requestAnimationFrame(function() {
        dialog.classList.add('cc-open');
    });
    var parts = dateKey.split('-');
    var dateObj = new Date(parseInt(parts[0], 10), parseInt(parts[1], 10) - 1, parseInt(parts[2], 10));
    document.getElementById('flm-day-title').textContent = dateObj.toLocaleDateString('en-US', { weekday: 'long', month: 'long', day: 'numeric', year: 'numeric' });
    var container = document.getElementById('flm-day-body');
    container.innerHTML = '<div class="flm-loading">Loading...</div>';
    try {
        var data = await cc_engineFetch('/api/fileops/history?limit=200');
        if (!data) return;
        var filtered = data.filter(function(e) {
            return new Date(e.EventDttm).toISOString().split('T')[0] === dateKey;
        });
        flm_renderDayDetail(container, filtered);
    } catch (error) {
        container.innerHTML = '<div class="flm-no-activity">Failed to load details</div>';
    }
}

/* Renders the day detail event table into the slideout body. */
function flm_renderDayDetail(container, events) {
    if (!events || events.length === 0) {
        container.innerHTML = '<div class="cc-slide-empty">No events for this date</div>';
        return;
    }
    var html = '<table class="cc-slide-table"><thead><tr><th class="cc-slide-table-th">Status</th><th class="cc-slide-table-th">Monitor</th><th class="cc-slide-table-th">Time</th><th class="cc-slide-table-th">File</th><th class="cc-slide-table-th">Alerts</th></tr></thead><tbody>';
    events.forEach(function(e) {
        var badgeCls = flm_statusBadgeClass(e.EventType);
        var badge = e.EventType === 'LateDetected' ? 'LATE' : e.EventType.toUpperCase();
        var alertHtml = '';
        if (e.TeamsAlertQueued) alertHtml += '<span class="flm-alert-badge flm-alert-teams">Teams</span>';
        if (e.JiraTicketQueued) alertHtml += '<span class="flm-alert-badge flm-alert-jira">Jira</span>';
        if (!alertHtml) alertHtml = '<span class="flm-empty-cell">\u2014</span>';
        html += '<tr class="cc-slide-table-row"><td class="cc-slide-table-td"><span class="flm-status-badge ' + badgeCls + '">' + badge + '</span></td>';
        html += '<td class="cc-slide-table-td">' + cc_escapeHtml(e.ConfigName) + '</td>';
        html += '<td class="cc-slide-table-td flm-monitor-time">' + cc_formatTimeOfDay(e.EventDttm) + '</td>';
        html += '<td class="cc-slide-table-td flm-monitor-file">' + (e.FileDetectedName ? cc_escapeHtml(e.FileDetectedName) : '\u2014') + '</td>';
        html += '<td class="cc-slide-table-td">' + alertHtml + '</td></tr>';
    });
    html += '</tbody></table>';
    container.innerHTML = html;
}

/*
 * Closes the day detail slideout. A one-shot transitionend on the inner
 * dialog removes cc-open from the overlay; a backdrop click dismisses while
 * interior clicks are ignored.
 */
function flm_closeDayPanel(target, event) {
    if (event && target.id === 'flm-slideout-day' && event.target !== target) {
        return;
    }
    var overlay = document.getElementById('flm-slideout-day');
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
   Small shared helpers for date keys, status-badge classes, attribute
   escaping, and SQL TIME formatting used across the page module.
   Prefix: flm
   ============================================================================ */

/* Returns the local YYYY-MM-DD key for today, used for same-day filtering. */
function flm_todayKey() {
    var now = new Date();
    return now.getFullYear() + '-' + String(now.getMonth() + 1).padStart(2, '0') + '-' + String(now.getDate()).padStart(2, '0');
}

/* Maps a monitor or event status to its status-badge class. */
function flm_statusBadgeClass(status) {
    if (status === 'Escalated') return 'flm-badge-escalated';
    if (status === 'Monitoring') return 'flm-badge-monitoring';
    if (status === 'Detected') return 'flm-badge-detected';
    if (status === 'LateDetected') return 'flm-badge-latedetected';
    return 'flm-badge-monitoring';
}

/* Attribute-safe escaping for values placed inside HTML attribute values. */
function flm_escAttr(text) {
    if (!text) return '';
    return text.replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/'/g, '&#39;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

/* Formats a SQL TIME-of-day string ("HH:MM:SS") as a 12-hour clock time. */
function flm_fmtTimeOnly(timeStr) {
    if (!timeStr) return '';
    var p = timeStr.split(':');
    if (p.length >= 2) {
        var h = parseInt(p[0], 10);
        var m = p[1];
        return (h > 12 ? h - 12 : (h === 0 ? 12 : h)) + ':' + m + ' ' + (h >= 12 ? 'PM' : 'AM');
    }
    return timeStr;
}

/* Normalizes a SQL TIME string to the "HH:MM" form an input[type=time] needs. */
function flm_fmtTimeInput(timeStr) {
    if (!timeStr) return '';
    var p = timeStr.split(':');
    if (p.length >= 2) return p[0].padStart(2, '0') + ':' + p[1].padStart(2, '0');
    return timeStr;
}

/* ============================================================================
   FUNCTIONS: PAGE LIFECYCLE HOOKS
   ----------------------------------------------------------------------------
   Lifecycle hook functions invoked by the cc-shared.js bootloader on page
   refresh, tab resume, and engine-process completion.
   Prefix: flm
   ============================================================================ */

/* Invoked by the shared page-refresh control; reloads all dashboard data. */
function flm_onPageRefresh() {
    flm_loadAllData();
    flm_loadDetectionHistory();
    flm_loadScheduledCount();
}

/* Invoked when the tab regains focus after being hidden; reloads data. */
function flm_onPageResumed() {
    flm_loadAllData();
    flm_loadScheduledCount();
}

/* Invoked when a Scan-SFTPFiles process completes; reloads activity data. */
function flm_onEngineProcessCompleted(processName, event) {
    flm_loadAllData();
    flm_loadScheduledCount();
}

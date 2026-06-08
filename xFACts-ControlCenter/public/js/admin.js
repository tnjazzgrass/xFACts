/* ============================================================================
   xFACts Control Center - Administration Page Module (admin.js)
   Location: E:\xFACts-ControlCenter\public\js\admin.js
   Version: Tracked in dbo.System_Metadata (component: ControlCenter.Admin)

   Page module for the Administration page. Drives the live process timeline
   (canvas visualization fed by raw orchestrator WebSocket events), the engine
   drain/service controls, and the management slide-up panels and detail dock:
   system metadata versioning, global configuration, process scheduling, the
   documentation pipeline, and alert-failure resends. Loaded by the cc-shared.js
   bootloader, which invokes adm_init after injection. Page chrome, the engine
   event transport, the shared fetch wrapper, formatters, and the modal helpers
   are consumed from cc-shared.js.

   FILE ORGANIZATION
   -----------------
   CONSTANTS: DISPATCH TABLES
   CONSTANTS: ENGINE PROCESSES
   CONSTANTS: TIMELINE CONFIGURATION
   STATE: PAGE STATE
   FUNCTIONS: INITIALIZATION
   FUNCTIONS: EVENT DISPATCH
   FUNCTIONS: TIMELINE DATA
   FUNCTIONS: TIMELINE RENDERING
   FUNCTIONS: ENGINE CONTROLS
   FUNCTIONS: SYSTEM METADATA
   FUNCTIONS: METADATA DETAIL DOCK
   FUNCTIONS: GLOBAL CONFIGURATION
   FUNCTIONS: PROCESS SCHEDULER
   FUNCTIONS: DOCUMENTATION PIPELINE
   FUNCTIONS: ALERT FAILURES
   FUNCTIONS: INPUT MODAL
   FUNCTIONS: LOG MODAL
   FUNCTIONS: FORMATTING
   FUNCTIONS: PAGE LIFECYCLE HOOKS
   ============================================================================ */

/* ============================================================================
   CONSTANTS: DISPATCH TABLES
   ----------------------------------------------------------------------------
   Maps page action values to their handler functions. The bootloader registers
   one delegated listener per recognized event; adm_init registers the page-side
   listeners that route adm- prefixed action values through these tables. Each
   handler receives (target, event): target is the element carrying the
   data-action-<event> attribute, event is the DOM event. Runtime arguments are
   read from the target's data-action-adm-* attributes.
   Prefix: adm
   ============================================================================ */

/* Click-action dispatch table. */
const adm_clickActions = {
    'adm-open-engine':         adm_openEngineControls,
    'adm-close-engine':        adm_closeEngineControls,
    'adm-toggle-drain':        adm_toggleDrain,
    'adm-service-control':     adm_serviceControl,
    'adm-open-metadata':       adm_openMetadata,
    'adm-close-metadata':      adm_closeMetadata,
    'adm-meta-toggle-root':    adm_metaToggleRoot,
    'adm-meta-toggle-mod':     adm_metaToggleMod,
    'adm-meta-toggle-comp':    adm_metaToggleComp,
    'adm-meta-insert':         adm_metaInsert,
    'adm-meta-load-history':   adm_metaLoadHistory,
    'adm-meta-load-objects':   adm_metaLoadObjects,
    'adm-close-detail':        adm_closeDetail,
    'adm-open-globalconfig':   adm_openGlobalConfig,
    'adm-close-globalconfig':  adm_closeGlobalConfig,
    'adm-gc-toggle-mod':       adm_gcToggleMod,
    'adm-gc-toggle-row':       adm_gcToggleRow,
    'adm-gc-toggle-bit':       adm_gcToggleBit,
    'adm-gc-toggle-alert-mode': adm_gcToggleAlertMode,
    'adm-gc-start-edit':       adm_gcStartEdit,
    'adm-gc-save-edit':        adm_gcSaveEdit,
    'adm-gc-cancel-edit':      adm_gcCancelEdit,
    'adm-gc-start-add':        adm_gcStartAdd,
    'adm-gc-cancel-add':       adm_gcCancelAdd,
    'adm-gc-submit-add':       adm_gcSubmitAdd,
    'adm-gc-toggle-active':    adm_gcToggleActive,
    'adm-gc-toggle-inactive':  adm_gcToggleInactive,
    'adm-open-schedule':       adm_openSchedules,
    'adm-close-schedule':      adm_closeSchedules,
    'adm-sched-toggle-mod':    adm_schedToggleMod,
    'adm-sched-toggle-row':    adm_schedToggleRow,
    'adm-sched-start-edit':    adm_schedStartEdit,
    'adm-sched-save-field':    adm_schedSaveField,
    'adm-sched-cancel-edit':   adm_schedCancelEdit,
    'adm-sched-toggle-mode':   adm_schedToggleMode,
    'adm-sched-toggle-concurrent': adm_schedToggleConcurrent,
    'adm-sched-start-add':     adm_schedStartAdd,
    'adm-sched-cancel-add':    adm_schedCancelAdd,
    'adm-sched-submit-add':    adm_schedSubmitAdd,
    'adm-sched-add-toggle-mode': adm_schedAddToggleMode,
    'adm-open-docpipeline':    adm_openDocPipeline,
    'adm-close-docpipeline':   adm_closeDocPipeline,
    'adm-doc-run':             adm_runDocPipeline,
    'adm-doc-toggle-pill':     adm_docTogglePill,
    'adm-open-alertfailures':  adm_openAlertFailures,
    'adm-close-alertfailures': adm_closeAlertFailures,
    'adm-resend-alert':        adm_resendAlert,
    'adm-open-platmon':        adm_openPlatformMonitoring,
    'adm-set-filter':          adm_setFilter,
    'adm-set-window':          adm_setWindow,
    'adm-toggle-process':      adm_toggleProcess,
    'adm-close-input':         adm_cancelInput,
    'adm-confirm-input':       adm_confirmInput,
    'adm-close-log':           adm_closeLog,
    'adm-switch-log-tab':      adm_switchLogTab
};

/* Change-action dispatch table. */
const adm_changeActions = {
    'adm-sched-script-selected': adm_schedScriptSelected,
    'adm-doc-step-change':       adm_docUpdateCards
};

/* Keydown-action dispatch table. */
const adm_keydownActions = {
    'adm-input-keydown':     adm_inputKeydown,
    'adm-gc-edit-keydown':   adm_gcEditKeydown,
    'adm-gc-add-keydown':    adm_gcAddKeydown,
    'adm-sched-edit-keydown': adm_schedEditKeydown
};

/* Input-action dispatch table. */
const adm_inputActions = {
    'adm-meta-desc-input': adm_metaDescInput
};

/* ============================================================================
   CONSTANTS: ENGINE PROCESSES
   ----------------------------------------------------------------------------
   The engine-process map consumed by the shared WebSocket transport. The page
   drives its timeline from the raw-event hook (adm_onEngineEventRaw) rather
   than per-process cards, so the map is intentionally empty; it must still be
   defined and truthy so cc_connectEngineEvents opens the socket.
   Prefix: adm
   ============================================================================ */

/* Empty-but-defined engine-process map; keeps the shared WebSocket open. */
var adm_ENGINE_PROCESSES = {};

/* ============================================================================
   CONSTANTS: TIMELINE CONFIGURATION
   ----------------------------------------------------------------------------
   Static lookup tables for the process timeline: the numeric tuning constants,
   the module color palette, the status-color overrides, the dependency-group
   labels, and the documentation step-to-card/options mappings.
   Prefix: adm
   ============================================================================ */

/* Safety-net refresh interval in milliseconds. */
const adm_SAFETY_NET_MS = 60000;
/* Countdown tick interval in milliseconds. */
const adm_TICK_MS = 1000;
/* Pixel height of a dependency-group lane on the canvas. */
const adm_GROUP_H = 22;
/* Pixel height of a process row on the canvas. */
const adm_ROW_H = 30;
/* Minimum drawn width in pixels for a timeline bar. */
const adm_MIN_BAR_W = 3;

/* Canvas color palette per module (bar fill, light gradient stop, glow). */
const adm_MODULE_COLORS = {
    ServerOps:    { bar: '#2563eb', light: '#60a5fa', glow: 'rgba(37,99,235,0.3)' },
    JobFlow:      { bar: '#7c3aed', light: '#a78bfa', glow: 'rgba(124,58,237,0.3)' },
    BatchOps:     { bar: '#d97706', light: '#fbbf24', glow: 'rgba(217,119,6,0.3)' },
    FileOps:      { bar: '#059669', light: '#34d399', glow: 'rgba(5,150,105,0.3)' },
    DeptOps:      { bar: '#db2777', light: '#f472b6', glow: 'rgba(219,39,119,0.3)' },
    Orchestrator: { bar: '#4ec9b0', light: '#4ec9b0', glow: 'rgba(78,201,176,0.3)' },
    Teams:        { bar: '#0ea5e9', light: '#38bdf8', glow: 'rgba(14,165,233,0.3)' },
    Jira:         { bar: '#f97316', light: '#fb923c', glow: 'rgba(249,115,22,0.3)' }
};

/* Fallback canvas color for modules with no palette entry. */
const adm_DEFAULT_COLOR = { bar: '#888', light: '#aaa', glow: 'rgba(136,136,136,0.3)' };

/* Status-specific bar/light overrides (SUCCESS uses the module color). */
const adm_STATUS_COLORS = {
    SUCCESS:  null,
    RUNNING:  { bar: '#569cd6', light: '#7dc4ff' },
    LAUNCHED: { bar: '#569cd6', light: '#7dc4ff' },
    FAILED:   { bar: '#ef4444', light: '#f87171' },
    TIMEOUT:  { bar: '#f87171', light: '#fca5a5' },
    POLLING:  { bar: '#dcdcaa', light: '#e8e8c0' }
};

/* Dependency-group number to sidebar label. */
const adm_GROUP_LABELS = {
    10: 'Collectors',
    20: 'Processors',
    30: 'Scanners & Dept',
    99: 'Queue Processors'
};

/* Documentation step toggle -> card + sub-options element mapping. */
const adm_DOC_STEP_OPTION_MAP = [
    { step: 'adm-doc-step-publish',     card: 'adm-doc-card-publish',     options: 'adm-doc-step-publish-options' },
    { step: 'adm-doc-step-consolidate', card: 'adm-doc-card-consolidate', options: 'adm-doc-step-consolidate-options' }
];

/* All documentation step toggles, for card dimming. */
const adm_DOC_ALL_STEPS = [
    { step: 'adm-doc-step-ddl',         card: 'adm-doc-card-ddl' },
    { step: 'adm-doc-step-publish',     card: 'adm-doc-card-publish' },
    { step: 'adm-doc-step-github',      card: 'adm-doc-card-github' },
    { step: 'adm-doc-step-consolidate', card: 'adm-doc-card-consolidate' }
];

/* ============================================================================
   STATE: PAGE STATE
   ----------------------------------------------------------------------------
   Mutable page state. Timeline data and view settings, engine/service status,
   per-subsystem tree expansion and edit state, and the transient modal/log
   buffers. One declaration per statement.
   Prefix: adm
   ============================================================================ */

/* Timeline: latest process roster from the status endpoint. */
var adm_processData = [];

/* Timeline: rolling window of task events for the canvas. */
var adm_timelineData = [];

/* Timeline: per-process countdown cache (pid -> { countdown, lastCalc }). */
var adm_processCountdowns = {};

/* Timeline: stable lane ordering (process names in render order). */
var adm_processOrder = [];

/* Timeline: computed canvas row geometry for hit-testing. */
var adm_canvasRows = [];

/* Timeline: task under the cursor, or null. */
var adm_hoveredTask = null;

/* Timeline: task selected by click, or null. */
var adm_selectedTask = null;

/* Timeline: active lane filter (all | running | failed). */
var adm_activeFilter = 'all';

/* Timeline: visible time window in minutes. */
var adm_windowMinutes = 30;

/* Timeline: timestamp of the last data refresh. */
var adm_lastRefresh = null;

/* Engine: whether the orchestrator is in drain mode. */
var adm_isDraining = false;

/* Engine: latest Windows-service status string. */
var adm_serviceStatus = 'Unknown';

/* Timeline: count of currently-running processes. */
var adm_totalRunning = 0;

/* Log modal: buffered output and error text for the two tabs. */
var adm_logData = { output: null, error: null };

/* Metadata: full component list from the tree endpoint. */
var adm_metaComponents = [];

/* Metadata: module-name -> description map. */
var adm_metaModules = {};

/* Metadata: platform totals block, or null before load. */
var adm_metaTotals = null;

/* Metadata: expanded module name (or '__root__'), or null. */
var adm_metaExpandedMod = null;

/* Metadata: expanded component name, or null. */
var adm_metaExpandedComp = null;

/* Metadata: object-catalog cache keyed by component name. */
var adm_metaObjectCache = {};

/* GlobalConfig: full settings list from the tree endpoint. */
var adm_gcAllSettings = [];

/* GlobalConfig: expanded module name, or null. */
var adm_gcExpandedMod = null;

/* GlobalConfig: expanded setting id, or null. */
var adm_gcExpandedId = null;

/* GlobalConfig: setting id currently being inline-edited, or null. */
var adm_gcEditingId = null;

/* GlobalConfig: module name an add-form is open under, or null. */
var adm_gcAddingTo = null;

/* GlobalConfig: per-module show-inactive flags (module -> bool). */
var adm_gcShowInactive = {};

/* Scheduler: full process list from the schedule endpoint. */
var adm_schedAllProcesses = [];

/* Scheduler: expanded module name, or null. */
var adm_schedExpandedMod = null;

/* Scheduler: expanded process id, or null. */
var adm_schedExpandedId = null;

/* Scheduler: { pid, field } currently being inline-edited, or null. */
var adm_schedEditingField = null;

/* Scheduler: module name an add-form is open under, or null. */
var adm_schedAddingTo = null;

/* Scheduler: available script filenames for the add-form dropdown. */
var adm_schedAvailableScripts = [];

/* Scheduler: execution mode chosen in the open add-form. */
var adm_schedAddMode = 'WAIT';

/* Documentation: whether a pipeline run is in flight. */
var adm_docRunning = false;

/* Documentation: status-poll interval handle, or null. */
var adm_docPollTimer = null;

/* Documentation: steps selected for the active run. */
var adm_docSelectedSteps = [];

/* Alert failures: latest failure list. */
var adm_afData = [];

/* Alert failures: whether the panel is open. */
var adm_afOpen = false;

/* Input modal: pending confirm callback, or null. */
var adm_inputModalCallback = null;

/* Timeline: midnight-rollover interval handle, or null. */
var adm_midnightTimer = null;

/* Timeline: safety-net refresh interval handle, or null. */
var adm_safetyTimer = null;

/* Timeline: 1-second tick interval handle, or null. */
var adm_tickTimer = null;

/* ============================================================================
   FUNCTIONS: INITIALIZATION
   ----------------------------------------------------------------------------
   The bootloader invokes adm_init after injecting this module. It registers the
   page-side delegated listeners (one per non-empty dispatch table), seeds the
   initial data load, starts the timeline timers, wires the canvas interaction
   and resize handlers, opens the shared engine WebSocket, and primes the
   documentation step toggles.
   Prefix: adm
   ============================================================================ */

/* Page entry point. Called once by the cc-shared.js bootloader. */
function adm_init() {
    document.body.addEventListener('click', adm_handleClick);
    document.body.addEventListener('change', adm_handleChange);
    document.body.addEventListener('input', adm_handleInput);
    document.body.addEventListener('keydown', adm_handleKeydown);

    adm_loadDrainStatus();
    adm_loadProcessStatus();
    adm_loadTimelineData();
    adm_loadAlertFailureCount();

    adm_safetyTimer = setInterval(adm_safetyRefresh, adm_SAFETY_NET_MS);
    adm_tickTimer = setInterval(adm_tickAll, adm_TICK_MS);

    var loadDate = new Date().toDateString();
    adm_midnightTimer = setInterval(function() {
        if (new Date().toDateString() !== loadDate) {
            window.location.reload();
        }
    }, 60000);

    window.addEventListener('resize', adm_layoutAndPaint);

    var cv = document.getElementById('adm-timeline-canvas');
    if (cv) {
        cv.addEventListener('mousemove', adm_onCanvasMouseMove);
        cv.addEventListener('mouseleave', adm_onCanvasMouseLeave);
        cv.addEventListener('click', adm_onCanvasClick);
    }

    var sb = document.getElementById('adm-timeline-sidebar');
    if (sb) {
        sb.addEventListener('scroll', adm_onSidebarScroll);
    }

    cc_connectEngineEvents();
    adm_initDocStepToggles();
}

/* ============================================================================
   FUNCTIONS: EVENT DISPATCH
   ----------------------------------------------------------------------------
   The page-side delegated dispatchers registered by adm_init. Each inspects
   the event target for a data-action-<event> attribute, ignores chrome cc-
   actions (handled by the shared listener), and routes adm- prefixed actions
   through the matching dispatch table.
   Prefix: adm
   ============================================================================ */

/* Page-side click dispatcher. Routes adm- prefixed data-action-click values
   through adm_clickActions. Chrome cc- actions are handled by the shared
   listener and ignored here. */
function adm_handleClick(event) {
    var target = event.target.closest('[data-action-click]');
    if (!target) {
        return;
    }
    var action = target.getAttribute('data-action-click');
    if (action.indexOf('adm-') !== 0) {
        return;
    }
    var handler = adm_clickActions[action];
    if (handler) {
        handler(target, event);
    }
}

/* Page-side change dispatcher. Routes adm- prefixed data-action-change values
   through adm_changeActions. */
function adm_handleChange(event) {
    var target = event.target.closest('[data-action-change]');
    if (!target) {
        return;
    }
    var action = target.getAttribute('data-action-change');
    if (action.indexOf('adm-') !== 0) {
        return;
    }
    var handler = adm_changeActions[action];
    if (handler) {
        handler(target, event);
    }
}

/* Page-side input dispatcher. Routes adm- prefixed data-action-input values
   through adm_inputActions. */
function adm_handleInput(event) {
    var target = event.target.closest('[data-action-input]');
    if (!target) {
        return;
    }
    var action = target.getAttribute('data-action-input');
    if (action.indexOf('adm-') !== 0) {
        return;
    }
    var handler = adm_inputActions[action];
    if (handler) {
        handler(target, event);
    }
}

/* Page-side keydown dispatcher. Routes adm- prefixed data-action-keydown values
   through adm_keydownActions. */
function adm_handleKeydown(event) {
    var target = event.target.closest('[data-action-keydown]');
    if (!target) {
        return;
    }
    var action = target.getAttribute('data-action-keydown');
    if (action.indexOf('adm-') !== 0) {
        return;
    }
    var handler = adm_keydownActions[action];
    if (handler) {
        handler(target, event);
    }
}

/* ============================================================================
   FUNCTIONS: TIMELINE DATA
   ----------------------------------------------------------------------------
   Loads and maintains the timeline data model: the process roster and drain
   status from REST, the task-event window, and the live mutations applied from
   raw WebSocket events. Builds the lane ordering, the module legend, and the
   sidebar rows; owns the filter and time-window controls.
   Prefix: adm
   ============================================================================ */

/* Safety-net refresh tick: reloads process, drain, and alert data unless paused. */
function adm_safetyRefresh() {
    if (cc_enginePageHidden || cc_engineSessionExpired) {
        return;
    }
    adm_loadProcessStatus();
    adm_loadDrainStatus();
    adm_loadAlertFailureCount();
}

/* Applies a raw orchestrator event to the live timeline and sidebar state. */
function adm_handleEngineEvent(event) {
    if (!adm_processData.length) {
        return;
    }

    var procName = event.processName;
    var proc = null;
    var i;
    for (i = 0; i < adm_processData.length; i++) {
        if (adm_processData[i].process_name === procName) {
            proc = adm_processData[i];
            break;
        }
    }
    if (!proc) {
        return;
    }

    if (event.eventType === 'PROCESS_STARTED') {
        proc.running_count = (proc.running_count || 0) + 1;
        proc.last_execution_status = 'RUNNING';
        delete adm_processCountdowns[proc.process_id];

        adm_timelineData.push({
            task_id: event.taskId || ('ws-' + Date.now()),
            process_id: event.processId,
            process_name: procName,
            module_name: event.moduleName,
            dependency_group: proc.dependency_group,
            execution_mode: proc.execution_mode,
            task_status: 'RUNNING',
            start_dttm: event.timestamp,
            end_dttm: null,
            duration_ms: null,
            output_summary: null,
            error_output: null
        });

        adm_renderSidebar();
    } else if (event.eventType === 'PROCESS_COMPLETED') {
        proc.running_count = Math.max((proc.running_count || 1) - 1, 0);
        proc.last_execution_status = event.status || 'SUCCESS';
        proc.last_duration_ms = event.durationMs;
        proc.last_execution_dttm = event.timestamp;

        var st = (event.status || 'SUCCESS').toUpperCase();
        if (st === 'SUCCESS') {
            proc.daily_success = (proc.daily_success || 0) + 1;
        } else if (st === 'FAILED' || st === 'TIMEOUT') {
            proc.daily_failed = (proc.daily_failed || 0) + 1;
        }

        var cd = cc_calcCountdownFromEvent(event, Date.now());
        if (cd !== null) {
            adm_processCountdowns[proc.process_id] = { countdown: cd, lastCalc: Date.now() };
        } else {
            delete adm_processCountdowns[proc.process_id];
        }

        var closed = false;
        var j;
        for (j = adm_timelineData.length - 1; j >= 0; j--) {
            var t = adm_timelineData[j];
            if (t.process_name === procName && !t.end_dttm) {
                t.end_dttm = event.timestamp;
                t.duration_ms = event.durationMs;
                t.task_status = event.status || 'SUCCESS';
                t.output_summary = event.outputSummary || null;
                if (event.taskId) {
                    t.task_id = event.taskId;
                }
                closed = true;
                break;
            }
        }

        if (!closed && event.timestamp && event.durationMs) {
            var startMs = new Date(event.timestamp).getTime() - event.durationMs;
            adm_timelineData.push({
                task_id: event.taskId || ('ws-' + Date.now()),
                process_id: event.processId,
                process_name: procName,
                module_name: event.moduleName,
                dependency_group: proc.dependency_group,
                execution_mode: proc.execution_mode,
                task_status: event.status || 'SUCCESS',
                start_dttm: new Date(startMs).toISOString(),
                end_dttm: event.timestamp,
                duration_ms: event.durationMs,
                output_summary: event.outputSummary || null,
                error_output: null
            });
        }

        adm_renderSidebar();
    }
}

/* Loads the process roster and seeds countdowns. */
function adm_loadProcessStatus() {
    cc_engineFetch('/api/admin/process-status').then(function(data) {
        if (!data) {
            return;
        }
        if (data.Error) {
            cc_showAlert(data.Error, { title: 'Error' });
            return;
        }
        adm_processData = Array.isArray(data) ? data : [];
        adm_lastRefresh = Date.now();
        adm_processData.forEach(function(p) {
            var secs = p.seconds_until_next;
            if (secs !== null && secs !== undefined) {
                adm_processCountdowns[p.process_id] = { countdown: secs, lastCalc: Date.now() };
            }
        });
        adm_buildProcessOrder();
        adm_buildLegend();
        adm_renderSidebar();
        adm_layoutAndPaint();
        adm_updateTs();
    }).catch(function(e) {
        cc_showAlert('API unreachable: ' + e.message, { title: 'Error' });
    });
}

/* Loads the rolling task-event window for the canvas. */
function adm_loadTimelineData() {
    cc_engineFetch('/api/admin/timeline-data?window_minutes=' + adm_windowMinutes).then(function(data) {
        if (!data) {
            return;
        }
        if (data.Error) {
            return;
        }
        adm_timelineData = Array.isArray(data) ? data : [];
        adm_layoutAndPaint();
    }).catch(function() {});
}

/* Builds the module legend from the current roster. */
function adm_buildLegend() {
    var el = document.getElementById('adm-timeline-legend');
    if (!el) {
        return;
    }
    if (!adm_processData.length) {
        el.innerHTML = '';
        return;
    }
    var seen = {};
    var mods = [];
    adm_processData.forEach(function(p) {
        var m = p.module_name;
        if (m && !seen[m]) {
            seen[m] = 1;
            mods.push(m);
        }
    });
    mods.sort();
    var html = '';
    mods.forEach(function(m) {
        var c = adm_getModColor(m);
        html += '<span class="adm-legend-item"><span class="adm-legend-dot" data-adm-color="' + c.bar + '"></span>' + cc_escapeHtml(m) + '</span>';
    });
    el.innerHTML = html;
    adm_applyLegendColors();
}

/* Applies legend dot colors from their data-adm-color attribute (avoids inline style). */
function adm_applyLegendColors() {
    var dots = document.querySelectorAll('#adm-timeline-legend .adm-legend-dot');
    var i;
    for (i = 0; i < dots.length; i++) {
        dots[i].style.background = dots[i].getAttribute('data-adm-color');
    }
}

/* Builds the stable lane ordering grouped by dependency group. */
function adm_buildProcessOrder() {
    var groups = {};
    adm_processData.forEach(function(p) {
        var g = p.dependency_group;
        if (!groups[g]) {
            groups[g] = [];
        }
        groups[g].push(p);
    });
    var gkeys = Object.keys(groups).sort(function(a, b) { return (+a) - (+b); });
    adm_processOrder = [];
    gkeys.forEach(function(g) {
        groups[g].sort(function(a, b) { return a.process_name.localeCompare(b.process_name); });
        groups[g].forEach(function(p) { adm_processOrder.push(p); });
    });
}

/* Renders the process-lane sidebar. */
function adm_renderSidebar() {
    var sb = document.getElementById('adm-timeline-sidebar');
    if (!sb) {
        return;
    }
    if (!adm_processData.length) {
        sb.innerHTML = '<div class="adm-loading">Loading...</div>';
        return;
    }
    var html = '';
    var lastGroup = null;
    adm_processOrder.forEach(function(p) {
        var st = adm_resolveStatus(p);
        var visible = adm_matchesFilter(p, st);
        if (p.dependency_group !== lastGroup) {
            lastGroup = p.dependency_group;
            html += '<div class="adm-group-header">' + cc_escapeHtml(adm_GROUP_LABELS[lastGroup] || ('Group ' + lastGroup)) + '</div>';
        }
        if (!visible) {
            return;
        }
        var isE = p.run_mode !== 0;
        var pwrCls = isE ? 'adm-on' : 'adm-off';
        var dotCls = 'adm-' + st.toLowerCase();
        var rowCls = 'adm-process-row';
        if (!isE) {
            rowCls += ' adm-disabled';
        }
        if (st === 'RUNNING' || st === 'LAUNCHED') {
            rowCls += ' adm-running';
        }
        var cd = adm_getCd(p);
        var cdH = '';
        if (cd !== null && p.run_mode === 1) {
            if (cd < -15) {
                cdH = '<span class="adm-countdown adm-overdue" data-pid="' + p.process_id + '">' + adm_fmtCd(cd) + '</span>';
            } else if (cd > 0) {
                cdH = '<span class="adm-countdown" data-pid="' + p.process_id + '">' + adm_fmtCd(cd) + '</span>';
            } else {
                cdH = '<span class="adm-countdown" data-pid="' + p.process_id + '"></span>';
            }
        } else if (p.run_mode === 2) {
            cdH = '<span class="adm-countdown adm-queue">queue</span>';
        } else if (p.run_mode === 0) {
            cdH = '<span class="adm-countdown adm-off">off</span>';
        }
        var ds = p.daily_success || 0;
        var df = p.daily_failed || 0;
        var ctsH = '<span class="adm-counts"><span class="' + (ds > 0 ? 'adm-count-ok' : 'adm-count-zero') + '">' + ds + '</span><span class="' + (df > 0 ? 'adm-count-fail' : 'adm-count-zero') + '">' + df + '</span></span>';
        html += '<div class="' + rowCls + '" data-pid="' + p.process_id + '">' +
            '<button class="adm-pwr ' + pwrCls + '" data-action-click="adm-toggle-process" data-action-adm-pid="' + p.process_id + '" data-action-adm-enabled="' + (isE ? 'true' : 'false') + '" data-action-adm-name="' + cc_escapeHtml(p.process_name) + '" title="' + (isE ? 'Disable' : 'Enable') + ' ' + cc_escapeHtml(p.process_name) + '">\u23FB</button>' +
            '<span class="adm-proc-badge ' + dotCls + '" title="' + cc_escapeHtml(p.process_name) + '">' + cc_escapeHtml(p.process_name) + '</span>' +
            ctsH + cdH + '</div>';
    });
    sb.innerHTML = html;
}

/* Resolves a process's display status. */
function adm_resolveStatus(p) {
    if (p.run_mode === 0) {
        return 'DISABLED';
    }
    if (p.running_count > 0) {
        return 'RUNNING';
    }
    var s = (p.last_execution_status || 'SUCCESS').toUpperCase();
    if (['SUCCESS', 'FAILED', 'TIMEOUT', 'LAUNCHED', 'POLLING'].indexOf(s) === -1) {
        s = 'SUCCESS';
    }
    return s;
}

/* Tests whether a process matches the active filter. */
function adm_matchesFilter(p, st) {
    if (adm_activeFilter === 'all') {
        return true;
    }
    if (adm_activeFilter === 'running') {
        return st === 'RUNNING' || st === 'LAUNCHED';
    }
    if (adm_activeFilter === 'failed') {
        return st === 'FAILED' || st === 'TIMEOUT' || (p.daily_failed && p.daily_failed > 0);
    }
    return true;
}

/* Sets the active lane filter from a filter pill. */
function adm_setFilter(target) {
    var f = target.getAttribute('data-action-adm-filter');
    adm_activeFilter = f;
    var pills = document.querySelectorAll('.adm-filter-pill');
    var i;
    for (i = 0; i < pills.length; i++) {
        pills[i].classList.toggle('adm-active', pills[i].getAttribute('data-action-adm-filter') === f);
    }
    adm_renderSidebar();
    adm_layoutAndPaint();
}

/* Sets the visible time window from a window button. */
function adm_setWindow(target) {
    var m = parseInt(target.getAttribute('data-action-adm-window'), 10);
    adm_windowMinutes = m;
    var btns = document.querySelectorAll('.adm-window-btn');
    var i;
    for (i = 0; i < btns.length; i++) {
        btns[i].classList.toggle('adm-active', parseInt(btns[i].getAttribute('data-action-adm-window'), 10) === m);
    }
    adm_loadTimelineData();
}

/* ============================================================================
   FUNCTIONS: TIMELINE RENDERING
   ----------------------------------------------------------------------------
   Canvas layout and painting for the process timeline: row geometry, gridlines,
   the NOW marker, task bars with status coloring, hit-testing, the hover
   tooltip, and the per-second tick that advances countdowns and repaints. Color
   literals here are canvas 2D drawing values, not CSS declarations.
   Prefix: adm
   ============================================================================ */

/* Rebuilds canvas row geometry then repaints. */
function adm_layoutAndPaint() {
    adm_buildCanvasRows();
    adm_paintCanvas();
}

/* Computes the canvas row layout from the filtered process order. */
function adm_buildCanvasRows() {
    adm_canvasRows = [];
    if (!adm_processData.length) {
        return;
    }
    var y = 0;
    var lastGroup = null;
    adm_processOrder.forEach(function(p) {
        var st = adm_resolveStatus(p);
        if (!adm_matchesFilter(p, st)) {
            return;
        }
        if (p.dependency_group !== lastGroup) {
            lastGroup = p.dependency_group;
            adm_canvasRows.push({ type: 'group', label: adm_GROUP_LABELS[lastGroup] || ('Group ' + lastGroup), y: y, h: adm_GROUP_H, group: lastGroup });
            y += adm_GROUP_H;
        }
        adm_canvasRows.push({ type: 'process', label: p.process_name, processName: p.process_name, module: p.module_name, group: p.dependency_group, processId: p.process_id, y: y, h: adm_ROW_H });
        y += adm_ROW_H;
    });
}

/* Paints the timeline canvas. */
function adm_paintCanvas() {
    var wrap = document.getElementById('adm-timeline-canvas-wrap');
    var canvas = document.getElementById('adm-timeline-canvas');
    if (!wrap || !canvas) {
        return;
    }
    var dpr = window.devicePixelRatio || 1;
    var w = wrap.clientWidth;
    var totalH = adm_canvasRows.length > 0 ? adm_canvasRows[adm_canvasRows.length - 1].y + adm_canvasRows[adm_canvasRows.length - 1].h : 300;
    var h = Math.max(totalH, wrap.clientHeight);
    canvas.width = w * dpr;
    canvas.height = h * dpr;
    canvas.style.width = w + 'px';
    canvas.style.height = h + 'px';
    var ctx = canvas.getContext('2d');
    ctx.scale(dpr, dpr);
    ctx.clearRect(0, 0, w, h);
    var sb = document.getElementById('adm-timeline-sidebar');
    var scrollTop = sb ? sb.scrollTop : 0;
    ctx.save();
    ctx.translate(0, -scrollTop);
    var now = Date.now();
    var tStart = now - adm_windowMinutes * 60 * 1000;
    var tEnd = now + 2 * 60 * 1000;
    function tx(t) {
        return ((t - tStart) / (tEnd - tStart)) * w;
    }
    adm_canvasRows.forEach(function(row, i) {
        if (row.type === 'group') {
            ctx.fillStyle = '#1a1a1e';
            ctx.fillRect(0, row.y, w, row.h);
        } else {
            ctx.fillStyle = i % 2 === 0 ? '#252526' : '#282830';
            ctx.fillRect(0, row.y, w, row.h);
        }
    });
    var gi;
    if (adm_windowMinutes <= 15) {
        gi = 60000;
    } else if (adm_windowMinutes <= 30) {
        gi = 300000;
    } else {
        gi = 600000;
    }
    var fg = Math.ceil(tStart / gi) * gi;
    ctx.strokeStyle = 'rgba(255,255,255,0.04)';
    ctx.lineWidth = 1;
    ctx.font = '10px "Segoe UI",sans-serif';
    ctx.fillStyle = '#444';
    ctx.textBaseline = 'top';
    var gt;
    for (gt = fg; gt <= tEnd; gt += gi) {
        var gx = tx(gt);
        ctx.beginPath();
        ctx.moveTo(gx, 0);
        ctx.lineTo(gx, h);
        ctx.stroke();
        var gd = new Date(gt);
        ctx.fillText(gd.getHours() + ':' + (gd.getMinutes() < 10 ? '0' : '') + gd.getMinutes(), gx + 3, 3);
    }
    var nx = tx(now);
    ctx.strokeStyle = 'rgba(78,201,176,0.5)';
    ctx.lineWidth = 1.5;
    ctx.setLineDash([6, 4]);
    ctx.beginPath();
    ctx.moveTo(nx, 0);
    ctx.lineTo(nx, h);
    ctx.stroke();
    ctx.setLineDash([]);
    ctx.fillStyle = '#4ec9b0';
    ctx.font = '600 9px "Segoe UI",sans-serif';
    ctx.textBaseline = 'bottom';
    ctx.fillText('NOW', nx + 3, adm_canvasRows.length > 0 ? adm_canvasRows[0].y + adm_canvasRows[0].h - 2 : 18);
    var prm = {};
    adm_canvasRows.forEach(function(r) {
        if (r.type === 'process') {
            prm[r.processName] = r;
        }
    });
    adm_timelineData.forEach(function(task) {
        var row = prm[task.process_name];
        if (!row) {
            return;
        }
        var sd = adm_parseDate(task.start_dttm);
        if (!sd) {
            return;
        }
        var sT = sd.getTime();
        var eT;
        if (task.end_dttm) {
            var ed = adm_parseDate(task.end_dttm);
            eT = ed ? ed.getTime() : sT + (task.duration_ms || 1000);
        } else {
            eT = now;
        }
        var x1 = tx(sT);
        var x2 = tx(eT);
        var bW = Math.max(x2 - x1, adm_MIN_BAR_W);
        if (x1 + bW < 0 || x1 > w) {
            return;
        }
        var bY = row.y + 4;
        var bH = row.h - 8;
        var st = (task.task_status || 'SUCCESS').toUpperCase();
        var sc = adm_STATUS_COLORS[st];
        var mc = adm_getModColor(task.module_name);
        var fc = sc ? sc.bar : mc.bar;
        var lc = sc ? sc.light : mc.light;
        var isH = adm_hoveredTask && adm_hoveredTask.task_id === task.task_id;
        var isS = adm_selectedTask && adm_selectedTask.task_id === task.task_id;
        if (isH || isS) {
            ctx.shadowColor = sc ? sc.bar : mc.glow;
            ctx.shadowBlur = 8;
        }
        var gr = ctx.createLinearGradient(x1, bY, x1, bY + bH);
        gr.addColorStop(0, lc);
        gr.addColorStop(1, fc);
        ctx.fillStyle = gr;
        var rr = Math.min(3, bH / 2);
        adm_rrect(ctx, x1, bY, bW, bH, rr);
        ctx.fill();
        ctx.shadowColor = 'transparent';
        ctx.shadowBlur = 0;
        if (bW > 50) {
            ctx.fillStyle = 'rgba(0,0,0,0.6)';
            ctx.font = '600 8px "Segoe UI",sans-serif';
            ctx.textBaseline = 'middle';
            ctx.fillText(adm_fmtDur(task.duration_ms), x1 + 4, bY + bH / 2);
        }
        if (isS) {
            ctx.strokeStyle = '#fff';
            ctx.lineWidth = 1.5;
            adm_rrect(ctx, x1, bY, bW, bH, rr);
            ctx.stroke();
        }
    });
    ctx.restore();
}

/* Traces a rounded rectangle path on the canvas context. */
function adm_rrect(ctx, x, y, w, h, r) {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.lineTo(x + w - r, y);
    ctx.arcTo(x + w, y, x + w, y + r, r);
    ctx.lineTo(x + w, y + h - r);
    ctx.arcTo(x + w, y + h, x + w - r, y + h, r);
    ctx.lineTo(x + r, y + h);
    ctx.arcTo(x, y + h, x, y + h - r, r);
    ctx.lineTo(x, y + r);
    ctx.arcTo(x, y, x + r, y, r);
}

/* Returns the task bar at canvas-relative coordinates, or null. */
function adm_getTaskAtPoint(cx, cy) {
    if (!adm_timelineData.length || !adm_canvasRows.length) {
        return null;
    }
    var wrap = document.getElementById('adm-timeline-canvas-wrap');
    var w = wrap.clientWidth;
    var sb = document.getElementById('adm-timeline-sidebar');
    var st = sb ? sb.scrollTop : 0;
    var aY = cy + st;
    var now = Date.now();
    var tS = now - adm_windowMinutes * 60 * 1000;
    var tE = now + 2 * 60 * 1000;
    function tx(t) {
        return ((t - tS) / (tE - tS)) * w;
    }
    var prm = {};
    adm_canvasRows.forEach(function(r) {
        if (r.type === 'process') {
            prm[r.processName] = r;
        }
    });
    var i;
    for (i = adm_timelineData.length - 1; i >= 0; i--) {
        var task = adm_timelineData[i];
        var row = prm[task.process_name];
        if (!row) {
            continue;
        }
        var sd = adm_parseDate(task.start_dttm);
        if (!sd) {
            continue;
        }
        var sT = sd.getTime();
        var eT;
        if (task.end_dttm) {
            var ed = adm_parseDate(task.end_dttm);
            eT = ed ? ed.getTime() : sT + (task.duration_ms || 1000);
        } else {
            eT = now;
        }
        var x1 = tx(sT);
        var x2 = tx(eT);
        var bW = Math.max(x2 - x1, adm_MIN_BAR_W);
        var bY = row.y + 4;
        var bH = row.h - 8;
        if (cx >= x1 && cx <= x1 + bW && aY >= bY && aY <= bY + bH) {
            return task;
        }
    }
    return null;
}

/* Canvas mousemove: updates hover state and tooltip. */
function adm_onCanvasMouseMove(e) {
    var r = e.target.getBoundingClientRect();
    var x = e.clientX - r.left;
    var y = e.clientY - r.top;
    var t = adm_getTaskAtPoint(x, y);
    var ch = (adm_hoveredTask ? adm_hoveredTask.task_id : null) !== (t ? t.task_id : null);
    adm_hoveredTask = t;
    if (ch) {
        adm_paintCanvas();
        if (t) {
            adm_showTooltip(t, e.clientX, e.clientY);
        } else {
            adm_hideTooltip();
        }
    } else if (t) {
        adm_positionTooltip(e.clientX, e.clientY);
    }
    e.target.style.cursor = t ? 'pointer' : 'default';
}

/* Canvas mouseleave: clears hover state. */
function adm_onCanvasMouseLeave() {
    if (adm_hoveredTask) {
        adm_hoveredTask = null;
        adm_paintCanvas();
        adm_hideTooltip();
    }
}

/* Sidebar scroll: repaints the canvas so lanes stay aligned with the rows. */
function adm_onSidebarScroll() {
    adm_paintCanvas();
}

/* Canvas click: selects a task and opens its log. */
function adm_onCanvasClick(e) {
    var r = e.target.getBoundingClientRect();
    var t = adm_getTaskAtPoint(e.clientX - r.left, e.clientY - r.top);
    if (t) {
        adm_selectedTask = t;
        adm_paintCanvas();
        adm_openLogFromTask(t);
    } else if (adm_selectedTask) {
        adm_selectedTask = null;
        adm_paintCanvas();
    }
}

/* Renders and shows the hover tooltip for a task. */
function adm_showTooltip(task, cx, cy) {
    var el = document.getElementById('adm-tooltip');
    var st = (task.task_status || 'SUCCESS').toUpperCase();
    el.innerHTML = '<div class="adm-tooltip-name">' + cc_escapeHtml(task.process_name) + '</div>' +
        '<div class="adm-tooltip-row"><span class="adm-tooltip-label">Status</span><span class="adm-tooltip-status adm-' + st.toLowerCase() + '">' + st + '</span></div>' +
        '<div class="adm-tooltip-row"><span class="adm-tooltip-label">Started</span><span class="adm-tooltip-value">' + adm_fmtTs(task.start_dttm) + '</span></div>' +
        '<div class="adm-tooltip-row"><span class="adm-tooltip-label">Duration</span><span class="adm-tooltip-value">' + adm_fmtDur(task.duration_ms) + '</span></div>' +
        '<div class="adm-tooltip-row"><span class="adm-tooltip-label">Mode</span><span class="adm-tooltip-value">' + cc_escapeHtml(task.execution_mode || '-') + '</span></div>' +
        '<div class="adm-tooltip-row"><span class="adm-tooltip-label">Task ID</span><span class="adm-tooltip-value">#' + task.task_id + '</span></div>';
    el.classList.add('adm-visible');
    adm_positionTooltip(cx, cy);
}

/* Positions the tooltip near the cursor, flipping to stay on-screen. */
function adm_positionTooltip(cx, cy) {
    var el = document.getElementById('adm-tooltip');
    var tw = el.offsetWidth || 280;
    var th = el.offsetHeight || 120;
    var px = cx + 12;
    var py = cy - th - 8;
    if (px + tw > window.innerWidth - 10) {
        px = cx - tw - 12;
    }
    if (py < 10) {
        py = cy + 16;
    }
    el.style.left = px + 'px';
    el.style.top = py + 'px';
}

/* Hides the hover tooltip. */
function adm_hideTooltip() {
    document.getElementById('adm-tooltip').classList.remove('adm-visible');
}

/* Returns the live countdown seconds for a process, or null. */
function adm_getCd(p) {
    if (p.run_mode === 0 || p.run_mode === 2) {
        return null;
    }
    var entry = adm_processCountdowns[p.process_id];
    if (!entry) {
        return null;
    }
    var elapsed = Math.floor((Date.now() - entry.lastCalc) / 1000);
    return entry.countdown - elapsed;
}

/* Advances the sidebar countdown spans in place. */
function adm_tickCountdowns() {
    if (!adm_processData.length) {
        return;
    }
    var spans = document.querySelectorAll('.adm-countdown[data-pid]');
    var i;
    for (i = 0; i < spans.length; i++) {
        var sp = spans[i];
        var pid = parseInt(sp.getAttribute('data-pid'), 10);
        var entry = adm_processCountdowns[pid];
        if (!entry) {
            continue;
        }
        var cur = entry.countdown - Math.floor((Date.now() - entry.lastCalc) / 1000);
        if (cur < -15) {
            sp.textContent = adm_fmtCd(cur);
            sp.classList.add('adm-overdue');
        } else if (cur > 0) {
            sp.textContent = adm_fmtCd(cur);
            sp.classList.remove('adm-overdue');
        } else {
            sp.textContent = '';
            sp.classList.remove('adm-overdue');
        }
    }
}

/* Per-second tick: advances countdowns and repaints the canvas. */
function adm_tickAll() {
    if (cc_enginePageHidden || cc_engineSessionExpired) {
        return;
    }
    adm_tickCountdowns();
    adm_paintCanvas();
}

/* ============================================================================
   FUNCTIONS: ENGINE CONTROLS
   ----------------------------------------------------------------------------
   The Engine Controls slide-up: opens/closes the panel, loads and renders the
   orchestrator drain state and Windows-service status (breaker switch, status
   light, service badge, control buttons, next-step guidance), and performs the
   drain-toggle and service-control actions with confirmation.
   Prefix: adm
   ============================================================================ */

/* Opens the Engine Controls slide-up and refreshes its state. */
function adm_openEngineControls() {
    var overlay = document.getElementById('adm-slideup-engine');
    var dialog = overlay.querySelector('.cc-dialog');
    overlay.classList.add('cc-open');
    requestAnimationFrame(function() {
        dialog.classList.add('cc-open');
    });
    adm_loadDrainStatus();
}

/* Closes the Engine Controls slide-up (backdrop-guarded). */
function adm_closeEngineControls(target, event) {
    if (event && target.id === 'adm-slideup-engine' && event.target !== target) {
        return;
    }
    var overlay = document.getElementById('adm-slideup-engine');
    var dialog = overlay.querySelector('.cc-dialog');
    dialog.addEventListener('transitionend', function handler() {
        dialog.removeEventListener('transitionend', handler);
        overlay.classList.remove('cc-open');
    });
    dialog.classList.remove('cc-open');
}

/* Loads the orchestrator drain status and service state. */
function adm_loadDrainStatus() {
    cc_engineFetch('/api/admin/drain-status').then(function(d) {
        if (!d) {
            return;
        }
        if (!d.Error) {
            adm_isDraining = d.drain_mode === 1;
            adm_serviceStatus = d.service_status || 'Unknown';
            adm_totalRunning = d.total_running || 0;
            adm_renderDrain();
            adm_renderEnginePip();
        }
    }).catch(function() {});
}

/* Updates the engine and service status pips on the card. */
function adm_renderEnginePip() {
    var ep = document.getElementById('adm-engine-pip');
    var sp = document.getElementById('adm-service-pip');
    if (ep) {
        ep.classList.remove('adm-draining');
        if (adm_isDraining) {
            ep.classList.add('adm-draining');
        }
    }
    if (sp) {
        sp.classList.remove('adm-stopped', 'adm-pending');
        if (adm_serviceStatus === 'Stopped') {
            sp.classList.add('adm-stopped');
        } else if (adm_serviceStatus === 'StopPending' || adm_serviceStatus === 'StartPending') {
            sp.classList.add('adm-pending');
        }
    }
}

/* Renders the breaker switch, status light, and drain caption. */
function adm_renderDrain() {
    var h = document.getElementById('adm-switch-handle');
    var l = document.getElementById('adm-status-light');
    var s = document.getElementById('adm-drain-status');
    if (!h) {
        return;
    }
    if (!adm_isDraining) {
        h.className = 'adm-switch-handle adm-on';
        l.className = 'adm-status-light adm-online';
        s.className = 'adm-drain-status adm-online';
        s.textContent = 'ONLINE';
    } else if (adm_serviceStatus === 'StopPending') {
        h.className = 'adm-switch-handle adm-off';
        l.className = 'adm-status-light adm-caution';
        s.className = 'adm-drain-status adm-caution';
        s.textContent = 'STOPPING';
    } else if (adm_serviceStatus === 'StartPending') {
        h.className = 'adm-switch-handle adm-off';
        l.className = 'adm-status-light adm-caution';
        s.className = 'adm-drain-status adm-caution';
        s.textContent = 'RESTARTING';
    } else if (adm_totalRunning > 0 && adm_serviceStatus === 'Running') {
        h.className = 'adm-switch-handle adm-off';
        l.className = 'adm-status-light adm-caution';
        s.className = 'adm-drain-status adm-caution';
        s.textContent = 'DRAINING';
    } else {
        h.className = 'adm-switch-handle adm-off';
        l.className = 'adm-status-light adm-offline';
        s.className = 'adm-drain-status adm-offline';
        s.textContent = 'OFFLINE';
    }
    var plate = document.getElementById('adm-breaker-plate');
    if (plate) {
        plate.classList.toggle('adm-drain-warning', adm_isDraining && adm_totalRunning === 0 && adm_serviceStatus === 'Running');
    }
    adm_renderServiceBadge();
    adm_renderServiceButtons();
    adm_renderGuidance();
}

/* Renders the Windows-service status badge. */
function adm_renderServiceBadge() {
    var b = document.getElementById('adm-svc-badge');
    if (!b) {
        return;
    }
    b.classList.remove('adm-running', 'adm-stopped', 'adm-pending', 'adm-unknown');
    switch (adm_serviceStatus) {
        case 'Running':
            b.textContent = 'SERVICE RUNNING';
            b.classList.add('adm-running');
            break;
        case 'Stopped':
            b.textContent = 'SERVICE STOPPED';
            b.classList.add('adm-stopped');
            break;
        case 'StartPending':
        case 'StopPending':
            b.textContent = 'SERVICE ' + adm_serviceStatus.toUpperCase();
            b.classList.add('adm-pending');
            break;
        default:
            b.textContent = 'SERVICE ' + adm_serviceStatus.toUpperCase();
            b.classList.add('adm-unknown');
            break;
    }
}

/* Enables/disables the service control buttons by current state. */
function adm_renderServiceButtons() {
    var bs = document.getElementById('adm-svc-btn-stop');
    var bt = document.getElementById('adm-svc-btn-start');
    var br = document.getElementById('adm-svc-btn-restart');
    if (!bs) {
        return;
    }
    bs.disabled = true;
    bt.disabled = true;
    br.disabled = true;
    if (adm_serviceStatus === 'Stopped') {
        bt.disabled = false;
        return;
    }
    if (!adm_isDraining) {
        return;
    }
    if (adm_totalRunning === 0 && adm_serviceStatus === 'Running') {
        bs.disabled = false;
        br.disabled = false;
    }
}

/* Renders the next-step guidance message. */
function adm_renderGuidance() {
    var g = document.getElementById('adm-svc-guidance');
    if (!g) {
        return;
    }
    var msg = '';
    if (adm_serviceStatus === 'StartPending' || adm_serviceStatus === 'StopPending') {
        msg = '<span class="adm-guidance-muted">Service state is changing. Please wait...</span>';
    } else if (!adm_isDraining && adm_serviceStatus === 'Running') {
        msg = '<span class="adm-guidance-muted">Normal operations.</span> To perform maintenance, engage drain mode first.';
    } else if (adm_isDraining && adm_serviceStatus === 'Running' && adm_totalRunning > 0) {
        msg = 'Waiting for <span class="adm-guidance-step">' + adm_totalRunning + ' running process' + (adm_totalRunning > 1 ? 'es' : '') + ' to complete</span> before the service can be stopped.';
    } else if (adm_isDraining && adm_serviceStatus === 'Running' && adm_totalRunning === 0) {
        msg = 'All processes drained. <span class="adm-guidance-step">Stop</span> or <span class="adm-guidance-step">Restart</span> the service when ready.';
    } else if (adm_isDraining && adm_serviceStatus === 'Stopped') {
        msg = 'Service is stopped. <span class="adm-guidance-step">Disengage drain mode</span> above, then click <span class="adm-guidance-step">Start</span> for a clean startup.';
    } else if (!adm_isDraining && adm_serviceStatus === 'Stopped') {
        msg = 'Ready. Click <span class="adm-guidance-step">Start</span> to resume normal operations.';
    } else {
        msg = '';
    }
    g.innerHTML = msg;
}

/* Confirms then toggles drain mode. */
function adm_toggleDrain() {
    if (!adm_isDraining) {
        cc_showConfirm('Stop launching new processes. Running processes complete normally.', {
            title: 'Engage Drain Mode',
            confirmLabel: 'Engage',
            confirmClass: 'cc-dialog-btn-danger'
        }).then(function(ok) {
            if (ok) {
                adm_postDrain(1);
            }
        });
    } else {
        cc_showConfirm('Re-enable normal orchestrator operations.', {
            title: 'Resume Operations',
            confirmLabel: 'Resume',
            confirmClass: 'cc-dialog-btn-primary'
        }).then(function(ok) {
            if (ok) {
                adm_postDrain(0);
            }
        });
    }
}

/* Posts a drain-mode change and refreshes. */
function adm_postDrain(v) {
    cc_engineFetch('/api/admin/drain-mode', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ drain_mode: v })
    }).then(function(d) {
        if (!d) {
            return;
        }
        if (d.Error) {
            cc_showAlert(d.Error, { title: 'Error' });
            return;
        }
        adm_sparks();
        adm_loadDrainStatus();
        adm_loadProcessStatus();
    }).catch(function(e) {
        cc_showAlert(e.message, { title: 'Error' });
    });
}

/* Confirms then performs a service control action. */
function adm_serviceControl(target) {
    var a = target.getAttribute('data-action-adm-svc');
    var labels = { stop: 'Stop Service', start: 'Start Service', restart: 'Restart Service' };
    var messages = {
        stop: 'Stop the xFACtsOrchestrator Windows service.' + (adm_isDraining ? ' Drain mode will remain engaged.' : ' The engine is currently online.'),
        start: 'Start the xFACtsOrchestrator Windows service.' + (adm_isDraining ? ' Note: drain mode is still engaged. The engine will not launch processes until drain mode is disengaged.' : ' The engine will resume normal operations.'),
        restart: 'Stop and restart the xFACtsOrchestrator Windows service.' + (adm_isDraining ? ' Drain mode will remain engaged.' : ' The engine is currently online.')
    };
    var danger = { stop: true, start: adm_isDraining, restart: true };
    cc_showConfirm(messages[a], {
        title: labels[a],
        confirmLabel: labels[a],
        confirmClass: danger[a] ? 'cc-dialog-btn-danger' : 'cc-dialog-btn-primary'
    }).then(function(ok) {
        if (ok) {
            adm_doServiceControl(a);
        }
    });
}

/* Performs a service control action and refreshes. */
function adm_doServiceControl(a) {
    ['stop', 'start', 'restart'].forEach(function(x) {
        var b = document.getElementById('adm-svc-btn-' + x);
        if (b) {
            b.disabled = true;
        }
    });
    cc_engineFetch('/api/admin/service-control', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: a })
    }).then(function(d) {
        if (!d) {
            return;
        }
        if (d.Error) {
            cc_showAlert(d.Error, { title: 'Error' });
            adm_loadDrainStatus();
            return;
        }
        adm_serviceStatus = d.service_status || 'Unknown';
        adm_renderDrain();
        adm_renderEnginePip();
        adm_loadDrainStatus();
    }).catch(function(e) {
        cc_showAlert(e.message, { title: 'Error' });
        adm_loadDrainStatus();
    });
}

/* Emits the spark-burst animation over the breaker. */
function adm_sparks() {
    var c = document.getElementById('adm-spark-container');
    if (!c) {
        return;
    }
    var pl = c.closest('.adm-breaker-housing').querySelector('.adm-breaker-plate');
    var cx = pl.offsetWidth / 2;
    var cy = pl.offsetHeight / 2;
    var i;
    for (i = 0; i < 14; i++) {
        var s = document.createElement('div');
        s.classList.add('adm-spark');
        var a = (Math.PI * 2 * i) / 14 + (Math.random() - 0.5) * 0.6;
        var d = 20 + Math.random() * 25;
        s.style.cssText = 'left:' + cx + 'px;top:' + cy + 'px;width:' + (1 + Math.random() * 2) + 'px;height:' + (1 + Math.random() * 2) + 'px;background:' + (Math.random() > 0.5 ? '#fbbf24' : '#fff') + ';--tx:' + (Math.cos(a) * d) + 'px;--ty:' + (Math.sin(a) * d) + 'px;animation:adm-spark-fly ' + (0.3 + Math.random() * 0.3) + 's ease-out forwards;';
        c.appendChild(s);
        (function(el) {
            setTimeout(function() { el.remove(); }, 600);
        })(s);
    }
}

/* Confirms then toggles a process's enabled state (sidebar power button). */
function adm_toggleProcess(target, event) {
    event.stopPropagation();
    var pid = parseInt(target.getAttribute('data-action-adm-pid'), 10);
    var en = target.getAttribute('data-action-adm-enabled') === 'true';
    var name = target.getAttribute('data-action-adm-name');
    if (en) {
        cc_showConfirm('Disable ' + name + '? It will not be launched on the next cycle.', {
            title: 'Disable Process',
            confirmLabel: 'Disable',
            confirmClass: 'cc-dialog-btn-danger'
        }).then(function(ok) {
            if (ok) {
                adm_doToggleProcess(pid, 'disable');
            }
        });
    } else {
        cc_showConfirm('Enable ' + name + '? It will resume on the next scheduled cycle.', {
            title: 'Enable Process',
            confirmLabel: 'Enable',
            confirmClass: 'cc-dialog-btn-primary'
        }).then(function(ok) {
            if (ok) {
                adm_doToggleProcess(pid, 'enable');
            }
        });
    }
}

/* Posts a process enable/disable and refreshes. */
function adm_doToggleProcess(pid, action) {
    cc_engineFetch('/api/admin/toggle-process', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ process_id: pid, action: action })
    }).then(function(d) {
        if (!d) {
            return;
        }
        if (d.Error) {
            cc_showAlert(d.Error, { title: 'Error' });
            return;
        }
        adm_loadProcessStatus();
    }).catch(function(e) {
        cc_showAlert(e.message, { title: 'Error' });
    });
}

/* Navigates to the Platform Monitoring page. */
function adm_openPlatformMonitoring() {
    window.location.href = '/platform-monitoring';
}

/* ============================================================================
   FUNCTIONS: SYSTEM METADATA
   ----------------------------------------------------------------------------
   The System Metadata slide-up: the component-versioning tree (root, module,
   component rows), the version-bump editor, version insertion, and the shared
   module-description loader used here and by the globalconfig and scheduler
   panels. The detail dock that this panel pairs with is in the next section.
   Prefix: adm
   ============================================================================ */

/* Module-name -> description cache, loaded once and shared by panels. */
var adm_adminModules = {};

/* Loads admin module descriptions once; resolves immediately if cached. */
function adm_loadAdminModules() {
    if (Object.keys(adm_adminModules).length > 0) {
        return Promise.resolve();
    }
    return cc_engineFetch('/api/admin/modules').then(function(data) {
        if (!data || data.Error) {
            return;
        }
        (Array.isArray(data) ? data : []).forEach(function(m) {
            adm_adminModules[m.module_name] = m.description || '';
        });
    }).catch(function() {});
}

/* Opens the System Metadata slide-up and loads the tree. */
function adm_openMetadata() {
    adm_metaReset();
    var overlay = document.getElementById('adm-slideup-metadata');
    var dialog = overlay.querySelector('.cc-dialog');
    overlay.classList.add('cc-open');
    requestAnimationFrame(function() {
        dialog.classList.add('cc-open');
    });
    adm_metaLoadTree();
}

/* Closes the System Metadata slide-up and its detail dock (backdrop-guarded). */
function adm_closeMetadata(target, event) {
    if (event && target.id === 'adm-slideup-metadata' && event.target !== target) {
        return;
    }
    adm_closeDetail();
    var overlay = document.getElementById('adm-slideup-metadata');
    var dialog = overlay.querySelector('.cc-dialog');
    dialog.addEventListener('transitionend', function handler() {
        dialog.removeEventListener('transitionend', handler);
        overlay.classList.remove('cc-open');
    });
    dialog.classList.remove('cc-open');
}

/* Resets metadata state and clears the panel. */
function adm_metaReset() {
    adm_metaComponents = [];
    adm_metaModules = {};
    adm_metaTotals = null;
    adm_metaExpandedMod = null;
    adm_metaExpandedComp = null;
    adm_metaObjectCache = {};
    document.getElementById('adm-meta-tree-list').innerHTML = '';
    document.getElementById('adm-meta-results-count').textContent = '';
    var st = document.getElementById('adm-meta-status');
    st.textContent = '';
    st.className = 'adm-meta-status';
}

/* Loads the metadata tree from the API. */
function adm_metaLoadTree() {
    document.getElementById('adm-meta-tree-list').innerHTML = '<div class="adm-loading">Loading metadata...</div>';
    cc_engineFetch('/api/admin/metadata/tree').then(function(data) {
        if (!data) {
            return;
        }
        if (data.Error) {
            adm_metaShowStatus(data.Error, true);
            return;
        }
        adm_metaComponents = Array.isArray(data.components) ? data.components : [];
        adm_metaTotals = data.totals || null;
        adm_metaModules = {};
        (Array.isArray(data.modules) ? data.modules : []).forEach(function(m) {
            adm_metaModules[m.module_name] = m.description || '';
        });
        var objCount = adm_metaTotals ? adm_metaTotals.object_count : 0;
        document.getElementById('adm-meta-results-count').textContent = objCount + ' object' + (objCount !== 1 ? 's' : '') + ' across ' + adm_metaComponents.length + ' component' + (adm_metaComponents.length !== 1 ? 's' : '');
        adm_renderMetaTree();
    }).catch(function(e) {
        adm_metaShowStatus(e.message, true);
    });
}

/* Renders the metadata tree (root + module rows). */
function adm_renderMetaTree() {
    var c = document.getElementById('adm-meta-tree-list');
    if (adm_metaComponents.length === 0) {
        c.innerHTML = '<div class="cc-slide-empty">No components found</div>';
        return;
    }
    var modules = {};
    var modOrder = [];
    adm_metaComponents.forEach(function(comp) {
        var mod = comp.module_name;
        if (!modules[mod]) {
            modules[mod] = [];
            modOrder.push(mod);
        }
        modules[mod].push(comp);
    });
    var html = '';
    html += adm_renderMetaRootRow();
    modOrder.forEach(function(mod) {
        var comps = modules[mod];
        var isExp = adm_metaExpandedMod === mod;
        var modObjCount = 0;
        comps.forEach(function(comp) { modObjCount += (comp.object_count || 0); });
        html += '<div class="adm-meta-parent-row">';
        html += '<div class="adm-meta-parent-header' + (isExp ? ' adm-expanded' : '') + '" data-action-click="adm-meta-toggle-mod" data-action-adm-mod="' + cc_escapeHtml(mod) + '">';
        html += '<span class="adm-meta-parent-chevron">' + (isExp ? '\u25BC' : '\u25B6') + '</span>';
        html += '<span class="adm-meta-parent-name">' + cc_escapeHtml(mod) + '</span>';
        var modDesc = adm_metaModules[mod] || '';
        if (modDesc) {
            html += '<span class="adm-meta-parent-desc">' + cc_escapeHtml(modDesc) + '</span>';
        }
        html += '<span class="adm-meta-parent-count">' + comps.length + ' component' + (comps.length !== 1 ? 's' : '') + ' \u00B7 ' + modObjCount + ' object' + (modObjCount !== 1 ? 's' : '') + '</span>';
        html += '</div></div>';
        if (isExp) {
            comps.forEach(function(comp) { html += adm_renderMetaCompRow(comp); });
        }
    });
    c.innerHTML = html;
}

/* Renders the synthetic root ("xFACts") tree row. */
function adm_renderMetaRootRow() {
    var isExp = adm_metaExpandedMod === '__root__';
    var compCount = adm_metaTotals ? adm_metaTotals.component_count : adm_metaComponents.length;
    var objCount = adm_metaTotals ? adm_metaTotals.object_count : 0;
    var lastActivity = adm_metaTotals ? adm_metaTotals.last_activity : null;
    return '<div class="adm-meta-root-row">' +
        '<div class="adm-meta-root-header' + (isExp ? ' adm-expanded' : '') + '" data-action-click="adm-meta-toggle-root">' +
        '<span class="adm-meta-root-chevron">' + (isExp ? '\u25BC' : '\u25B6') + '</span>' +
        '<span class="adm-meta-root-icon">&#128450;</span>' +
        '<span class="adm-meta-root-name">xFACts</span>' +
        '<span class="adm-meta-parent-count">' + compCount + ' component' + (compCount !== 1 ? 's' : '') + ' \u00B7 ' + objCount + ' object' + (objCount !== 1 ? 's' : '') + '</span>' +
        '</div>' +
        '<div class="adm-meta-root-body' + (isExp ? ' adm-expanded' : '') + '">' + (isExp ? adm_renderMetaRootDetail(lastActivity) : '') + '</div>' +
        '</div>';
}

/* Renders the root detail body. */
function adm_renderMetaRootDetail(lastActivity) {
    var html = '<div class="adm-meta-root-info">';
    if (lastActivity) {
        html += '<div class="adm-meta-root-stat">Last activity: ' + adm_fmtDateShort(lastActivity) + '</div>';
    }
    html += '</div>';
    return html;
}

/* Renders a single component child card. */
function adm_renderMetaCompRow(comp) {
    var isExp = adm_metaExpandedComp === comp.component_name;
    var shortName = comp.component_name;
    var html = '<div class="adm-meta-child-card' + (isExp ? ' adm-expanded' : '') + '" data-comp="' + cc_escapeHtml(comp.component_name) + '"' + (isExp ? '' : ' data-action-click="adm-meta-toggle-comp" data-action-adm-comp="' + cc_escapeHtml(comp.component_name) + '"') + '>';
    html += '<div class="adm-meta-child-header"' + (isExp ? ' data-action-click="adm-meta-toggle-comp" data-action-adm-comp="' + cc_escapeHtml(comp.component_name) + '"' : '') + '>';
    html += '<span class="adm-meta-child-name" title="' + cc_escapeHtml(comp.component_name) + '">' + cc_escapeHtml(shortName) + '</span>';
    html += '<span class="adm-meta-child-dots"></span>';
    html += '<span class="adm-meta-child-objcount" title="' + comp.object_count + ' registered objects">' + comp.object_count + ' obj</span>';
    html += '<span class="adm-meta-child-ver">' + cc_escapeHtml(comp.version || '-') + '</span>';
    html += '</div>';
    if (comp.component_description) {
        html += '<div class="adm-meta-child-desc' + (isExp ? ' adm-expanded' : '') + '">' + cc_escapeHtml(comp.component_description) + '</div>';
    }
    html += '<div class="adm-meta-child-body' + (isExp ? ' adm-expanded' : '') + '">';
    if (isExp) {
        html += adm_renderMetaCompExpanded(comp);
    }
    html += '</div></div>';
    return html;
}

/* Renders the expanded component body (version-bump editor + actions). */
function adm_renderMetaCompExpanded(comp) {
    var cn = comp.component_name;
    var p = (comp.version || '0.0.0').split('.');
    var b = [parseInt(p[0], 10) || 0, parseInt(p[1], 10) || 0, parseInt(p[2], 10) || 0];
    var v2 = b[2] + 1;
    var v1 = b[1];
    var v0 = b[0];
    if (v2 > 9) {
        v2 = 0;
        v1++;
    }
    if (v1 > 9) {
        v1 = 0;
        v0++;
    }
    var ce = cc_escapeHtml(cn);
    var html = '<div class="adm-meta-bump-section">';
    html += '<div class="adm-meta-bump-row">';
    html += '<span class="adm-meta-bump-label">Version</span>';
    html += '<span class="adm-ver-bump adm-ver-next">' + v0 + '</span>';
    html += '<span class="adm-ver-dot">.</span>';
    html += '<span class="adm-ver-bump adm-ver-next">' + v1 + '</span>';
    html += '<span class="adm-ver-dot">.</span>';
    html += '<span class="adm-ver-bump adm-ver-next">' + v2 + '</span>';
    html += '<span class="adm-meta-bump-spacer"></span>';
    html += '<button class="adm-meta-cancel-btn" data-action-click="adm-meta-toggle-comp" data-action-adm-comp="' + ce + '">Cancel</button>';
    html += '<button class="adm-meta-insert-btn adm-disabled" id="adm-ins-' + ce + '" data-action-click="adm-meta-insert" data-action-adm-comp="' + ce + '" disabled>Insert</button>';
    html += '</div>';
    html += '<div class="adm-meta-bump-hint">Next version. Current: ' + cc_escapeHtml(comp.version || '-') + '</div>';
    html += '<div class="adm-meta-desc-row">';
    html += '<textarea class="adm-meta-desc-area" id="adm-desc-' + ce + '" placeholder="Description of changes\u2026" maxlength="1000" rows="3" data-action-input="adm-meta-desc-input" data-action-adm-comp="' + ce + '"></textarea>';
    html += '</div>';
    html += '<div class="adm-meta-bump-status" id="adm-bst-' + ce + '"></div>';
    html += '</div>';
    html += '<div class="adm-meta-actions-row">';
    html += '<button class="adm-meta-history-toggle" data-action-click="adm-meta-load-history" data-action-adm-comp="' + ce + '">Version history</button>';
    html += '<button class="adm-meta-history-toggle" data-action-click="adm-meta-load-objects" data-action-adm-comp="' + ce + '">Object catalog (' + comp.object_count + ')</button>';
    html += '</div>';
    return html;
}

/* Toggles the root row expansion. */
function adm_metaToggleRoot() {
    adm_metaExpandedComp = null;
    adm_metaExpandedMod = adm_metaExpandedMod === '__root__' ? null : '__root__';
    adm_renderMetaTree();
}

/* Toggles a module row expansion. */
function adm_metaToggleMod(target) {
    var mod = target.getAttribute('data-action-adm-mod');
    adm_metaExpandedComp = null;
    adm_metaExpandedMod = adm_metaExpandedMod === mod ? null : mod;
    adm_renderMetaTree();
    if (adm_metaExpandedMod && adm_metaExpandedMod !== '__root__') {
        var el = document.querySelector('.adm-meta-parent-header.adm-expanded');
        if (el) {
            el.scrollIntoView({ behavior: 'smooth', block: 'start' });
        }
    }
}

/* Toggles a component card expansion. */
function adm_metaToggleComp(target) {
    var cn = target.getAttribute('data-action-adm-comp');
    adm_metaExpandedComp = adm_metaExpandedComp === cn ? null : cn;
    adm_renderMetaTree();
    if (adm_metaExpandedComp) {
        var el = document.querySelector('.adm-meta-child-card[data-comp="' + cn + '"]');
        if (el) {
            el.scrollIntoView({ behavior: 'smooth', block: 'center' });
        }
    }
}

/* Enables/disables the Insert button as the description changes. */
function adm_metaDescInput(target) {
    var cn = target.getAttribute('data-action-adm-comp');
    var desc = (document.getElementById('adm-desc-' + cn).value || '').trim();
    var btn = document.getElementById('adm-ins-' + cn);
    if (btn) {
        if (desc.length > 0) {
            btn.disabled = false;
            btn.classList.remove('adm-disabled');
        } else {
            btn.disabled = true;
            btn.classList.add('adm-disabled');
        }
    }
}

/* Confirms then inserts a new component version. */
function adm_metaInsert(target) {
    var cn = target.getAttribute('data-action-adm-comp');
    var comp = adm_metaFindComp(cn);
    if (!comp) {
        return;
    }
    var desc = (document.getElementById('adm-desc-' + cn).value || '').trim();
    if (!desc) {
        adm_metaBumpStatus(cn, 'Description required', true);
        return;
    }
    var p = (comp.version || '0.0.0').split('.');
    var b = [parseInt(p[0], 10) || 0, parseInt(p[1], 10) || 0, parseInt(p[2], 10) || 0];
    var v2 = b[2] + 1;
    var v1 = b[1];
    var v0 = b[0];
    if (v2 > 9) {
        v2 = 0;
        v1++;
    }
    if (v1 > 9) {
        v1 = 0;
        v0++;
    }
    var ver = v0 + '.' + v1 + '.' + v2;
    cc_showConfirm('Insert ' + cn + ' v' + ver + '?', {
        title: 'Insert Version',
        confirmLabel: 'Insert',
        confirmClass: 'cc-dialog-btn-primary'
    }).then(function(ok) {
        if (ok) {
            adm_doMetaInsert(cn, ver, desc);
        }
    });
}

/* Posts a new component version and reloads the tree. */
function adm_doMetaInsert(cn, ver, desc) {
    var btn = document.getElementById('adm-ins-' + cn);
    if (btn) {
        btn.disabled = true;
    }
    cc_engineFetch('/api/admin/metadata/insert', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ component_name: cn, version: ver, description: desc })
    }).then(function(d) {
        if (!d) {
            return;
        }
        if (d.Error) {
            adm_metaBumpStatus(cn, d.Error, true);
            if (btn) {
                btn.disabled = false;
            }
            return;
        }
        adm_metaBumpStatus(cn, 'Inserted ' + cn + ' v' + ver, false);
        setTimeout(function() { adm_metaLoadTree(); }, 800);
    }).catch(function(e) {
        adm_metaBumpStatus(cn, e.message, true);
        if (btn) {
            btn.disabled = false;
        }
    });
}

/* Sets the per-component bump status line. */
function adm_metaBumpStatus(cn, msg, isErr) {
    var el = document.getElementById('adm-bst-' + cn);
    if (el) {
        el.textContent = msg;
        el.className = 'adm-meta-bump-status ' + (isErr ? 'adm-error' : 'adm-success');
    }
}

/* Finds a component record by name. */
function adm_metaFindComp(cn) {
    var i;
    for (i = 0; i < adm_metaComponents.length; i++) {
        if (adm_metaComponents[i].component_name === cn) {
            return adm_metaComponents[i];
        }
    }
    return null;
}

/* Sets the metadata panel status line. */
function adm_metaShowStatus(msg, isErr) {
    var el = document.getElementById('adm-meta-status');
    if (el) {
        el.textContent = msg;
        el.className = 'adm-meta-status ' + (isErr ? 'adm-error' : 'adm-success');
    }
}

/* ============================================================================
   FUNCTIONS: METADATA DETAIL DOCK
   ----------------------------------------------------------------------------
   The detail dock paired with the System Metadata panel. Shows either a
   component's version history or its object catalog, toggling closed when the
   same view is requested again. The current view is tracked on the dock element
   via _mode and _comp; the dock reveals by adding cc-open and dismisses by
   removing it (back-button only, per the dock handler contract).
   Prefix: adm
   ============================================================================ */

/* Type-badge class/label lookup for catalog object types. */
var adm_detailTypeBadge = {
    'Table':       { cls: 'adm-cat-table',      label: 'TABLE' },
    'Procedure':   { cls: 'adm-cat-proc',       label: 'PROC' },
    'Trigger':     { cls: 'adm-cat-trigger',    label: 'TRIGGER' },
    'DDL Trigger': { cls: 'adm-cat-ddltrigger', label: 'DDL' },
    'View':        { cls: 'adm-cat-view',       label: 'VIEW' },
    'Function':    { cls: 'adm-cat-function',   label: 'FUNC' },
    'Script':      { cls: 'adm-cat-script',     label: 'SCRIPT' },
    'XE Session':  { cls: 'adm-cat-xe',         label: 'XE' },
    'Route':       { cls: 'adm-cat-route',      label: 'ROUTE' },
    'API':         { cls: 'adm-cat-api',        label: 'API' },
    'JavaScript':  { cls: 'adm-cat-js',         label: 'JS' },
    'CSS':         { cls: 'adm-cat-css',        label: 'CSS' },
    'HTML':        { cls: 'adm-cat-html',       label: 'HTML' },
    'Module':      { cls: 'adm-cat-module',     label: 'MODULE' }
};

/* Loads and shows a component's version history in the dock (toggles closed). */
function adm_metaLoadHistory(target) {
    var cn = target.getAttribute('data-action-adm-comp');
    var dock = document.getElementById('adm-dock-detail');
    if (dock.classList.contains('cc-open') && dock._mode === 'history' && dock._comp === cn) {
        adm_closeDetail();
        return;
    }
    var shortName = cn;
    if (shortName.indexOf('.') > -1) {
        var parts = shortName.split('.');
        shortName = parts[parts.length - 1];
    }
    document.getElementById('adm-detail-title').textContent = shortName + ' \u2014 Version History';
    document.getElementById('adm-detail-count').textContent = '';
    document.getElementById('adm-detail-body').innerHTML = '<div class="adm-loading">Loading\u2026</div>';
    dock._comp = cn;
    dock._mode = 'history';
    dock.classList.add('cc-open');

    cc_engineFetch('/api/admin/metadata/history?component=' + encodeURIComponent(cn)).then(function(data) {
        if (!data) {
            return;
        }
        var dock2 = document.getElementById('adm-dock-detail');
        if (dock2._comp !== cn || dock2._mode !== 'history') {
            return;
        }
        if (data.Error) {
            document.getElementById('adm-detail-body').innerHTML = '<div class="adm-detail-error-msg">' + cc_escapeHtml(data.Error) + '</div>';
            return;
        }
        var arr = Array.isArray(data) ? data : [];
        document.getElementById('adm-detail-count').textContent = arr.length + ' version' + (arr.length !== 1 ? 's' : '');
        if (arr.length === 0) {
            document.getElementById('adm-detail-body').innerHTML = '<div class="adm-detail-empty">No history found</div>';
            return;
        }
        var html = '';
        arr.forEach(function(h) {
            html += '<div class="adm-detail-row">';
            html += '<span class="adm-detail-row-type adm-cat-table">' + cc_escapeHtml(h.version) + '</span>';
            html += '<span class="adm-detail-row-name adm-detail-row-name-plain">' + cc_escapeHtml(h.description || '-') + '</span>';
            html += '<span class="adm-detail-row-path">' + adm_fmtDateShort(h.deployed_date) + '</span>';
            html += '</div>';
        });
        document.getElementById('adm-detail-body').innerHTML = html;
    }).catch(function(e) {
        document.getElementById('adm-detail-body').innerHTML = '<div class="adm-detail-error-msg">' + cc_escapeHtml(e.message) + '</div>';
    });
}

/* Loads and shows a component's object catalog in the dock (toggles closed). */
function adm_metaLoadObjects(target) {
    var cn = target.getAttribute('data-action-adm-comp');
    var dock = document.getElementById('adm-dock-detail');
    if (dock.classList.contains('cc-open') && dock._mode === 'catalog' && dock._comp === cn) {
        adm_closeDetail();
        return;
    }
    var shortName = cn;
    if (shortName.indexOf('.') > -1) {
        var parts = shortName.split('.');
        shortName = parts[parts.length - 1];
    }
    document.getElementById('adm-detail-title').textContent = shortName + ' \u2014 Object Catalog';
    document.getElementById('adm-detail-count').textContent = '';
    document.getElementById('adm-detail-body').innerHTML = '<div class="adm-loading">Loading\u2026</div>';
    dock._comp = cn;
    dock._mode = 'catalog';
    dock.classList.add('cc-open');
    if (adm_metaObjectCache[cn]) {
        adm_renderCatalog(cn, adm_metaObjectCache[cn]);
        return;
    }
    cc_engineFetch('/api/admin/metadata/objects?component=' + encodeURIComponent(cn)).then(function(data) {
        if (!data) {
            return;
        }
        var dock2 = document.getElementById('adm-dock-detail');
        if (dock2._comp !== cn || dock2._mode !== 'catalog') {
            return;
        }
        if (data.Error) {
            document.getElementById('adm-detail-body').innerHTML = '<div class="adm-detail-error-msg">' + cc_escapeHtml(data.Error) + '</div>';
            return;
        }
        var arr = Array.isArray(data) ? data : [];
        adm_metaObjectCache[cn] = arr;
        adm_renderCatalog(cn, arr);
    }).catch(function(e) {
        document.getElementById('adm-detail-body').innerHTML = '<div class="adm-detail-error-msg">' + cc_escapeHtml(e.message) + '</div>';
    });
}

/* Renders the object catalog grouped by category into the dock body. */
function adm_renderCatalog(cn, objects) {
    var dock = document.getElementById('adm-dock-detail');
    if (dock._comp !== cn || dock._mode !== 'catalog') {
        return;
    }
    document.getElementById('adm-detail-count').textContent = objects.length + ' object' + (objects.length !== 1 ? 's' : '');
    if (objects.length === 0) {
        document.getElementById('adm-detail-body').innerHTML = '<div class="adm-detail-empty">No objects registered</div>';
        return;
    }
    var groups = {};
    var groupOrder = [];
    objects.forEach(function(o) {
        var cat = o.object_category || 'Other';
        if (!groups[cat]) {
            groups[cat] = [];
            groupOrder.push(cat);
        }
        groups[cat].push(o);
    });
    var html = '';
    groupOrder.forEach(function(cat) {
        html += '<div class="adm-detail-group-label">' + cc_escapeHtml(cat) + ' (' + groups[cat].length + ')</div>';
        groups[cat].forEach(function(o) {
            var badge = adm_detailTypeBadge[o.object_type] || { cls: '', label: o.object_type };
            html += '<div class="adm-detail-row">';
            html += '<span class="adm-detail-row-type ' + badge.cls + '">' + badge.label + '</span>';
            html += '<span class="adm-detail-row-name">' + cc_escapeHtml(o.object_name) + '</span>';
            if (o.object_path) {
                html += '<span class="adm-detail-row-path">' + cc_escapeHtml(o.object_path) + '</span>';
            }
            html += '</div>';
        });
    });
    document.getElementById('adm-detail-body').innerHTML = html;
}

/* Closes the detail dock and clears its view tracking. */
function adm_closeDetail() {
    var dock = document.getElementById('adm-dock-detail');
    dock.classList.remove('cc-open');
    dock._comp = null;
    dock._mode = null;
}

/* ============================================================================
   FUNCTIONS: GLOBAL CONFIGURATION
   ----------------------------------------------------------------------------
   The Global Configuration slide-up: the module/setting tree with active and
   inactive groupings, the inline value editor, the ALERT_MODE channel badges
   and BIT toggle widgets, per-setting detail and change history, the add-setting
   form, and the activate/deactivate actions. Toggle and badge state classes are
   applied to the element that changes per the state-on-element model.
   Prefix: adm
   ============================================================================ */

/* Opens the Global Configuration slide-up and loads settings. */
function adm_openGlobalConfig() {
    adm_gcReset();
    var overlay = document.getElementById('adm-slideup-globalconfig');
    var dialog = overlay.querySelector('.cc-dialog');
    overlay.classList.add('cc-open');
    requestAnimationFrame(function() {
        dialog.classList.add('cc-open');
    });
    adm_loadAdminModules().then(function() {
        adm_gcGo();
    });
}

/* Closes the Global Configuration slide-up (backdrop-guarded). */
function adm_closeGlobalConfig(target, event) {
    if (event && target.id === 'adm-slideup-globalconfig' && event.target !== target) {
        return;
    }
    var overlay = document.getElementById('adm-slideup-globalconfig');
    var dialog = overlay.querySelector('.cc-dialog');
    dialog.addEventListener('transitionend', function handler() {
        dialog.removeEventListener('transitionend', handler);
        overlay.classList.remove('cc-open');
    });
    dialog.classList.remove('cc-open');
}

/* Resets globalconfig state and clears the panel. */
function adm_gcReset() {
    adm_gcAllSettings = [];
    adm_gcExpandedMod = null;
    adm_gcExpandedId = null;
    adm_gcEditingId = null;
    adm_gcAddingTo = null;
    adm_gcShowInactive = {};
    var st = document.getElementById('adm-gc-status');
    st.textContent = '';
    st.className = 'adm-meta-status';
    document.getElementById('adm-gc-tree-list').innerHTML = '';
    document.getElementById('adm-gc-results-count').textContent = '';
}

/* Loads the globalconfig settings list. */
function adm_gcGo() {
    document.getElementById('adm-gc-tree-list').innerHTML = '<div class="adm-loading">Loading settings...</div>';
    cc_engineFetch('/api/admin/globalconfig/settings').then(function(data) {
        if (!data) {
            return;
        }
        if (data.Error) {
            adm_gcShowStatus(data.Error, true);
            return;
        }
        adm_gcAllSettings = Array.isArray(data) ? data : [];
        adm_renderGcTree();
    }).catch(function(e) {
        adm_gcShowStatus(e.message, true);
    });
}

/* Tests whether a setting record is inactive. */
function adm_gcIsInactive(s) {
    return s.is_active === false || s.is_active === 0 || s.is_active === '0' || s.is_active === null;
}

/* Renders the globalconfig module/setting tree. */
function adm_renderGcTree() {
    var c = document.getElementById('adm-gc-tree-list');
    if (adm_gcAllSettings.length === 0) {
        c.innerHTML = '<div class="cc-slide-empty">No UI-editable settings found</div>';
        return;
    }
    var modules = {};
    var inactiveModules = {};
    adm_gcAllSettings.forEach(function(s) {
        var mod = s.module_name || 'Other';
        if (adm_gcIsInactive(s)) {
            if (!inactiveModules[mod]) {
                inactiveModules[mod] = [];
            }
            inactiveModules[mod].push(s);
        } else {
            if (!modules[mod]) {
                modules[mod] = [];
            }
            modules[mod].push(s);
        }
    });
    var activeCount = 0;
    var inactiveCount = 0;
    adm_gcAllSettings.forEach(function(s) {
        if (adm_gcIsInactive(s)) {
            inactiveCount++;
        } else {
            activeCount++;
        }
    });
    document.getElementById('adm-gc-results-count').textContent = activeCount + ' setting' + (activeCount !== 1 ? 's' : '') + (inactiveCount > 0 ? ' (' + inactiveCount + ' inactive)' : '');
    var html = '';
    var allMods = {};
    Object.keys(modules).forEach(function(m) { allMods[m] = true; });
    Object.keys(inactiveModules).forEach(function(m) { allMods[m] = true; });
    var modNames = Object.keys(allMods).sort();
    modNames.forEach(function(mod) {
        var active = modules[mod] || [];
        var inactive = inactiveModules[mod] || [];
        var totalLabel = active.length + (inactive.length > 0 ? ' + ' + inactive.length + ' inactive' : '');
        var isExp = adm_gcExpandedMod === mod;
        var modDesc = adm_adminModules[mod] || '';
        var me = cc_escapeHtml(mod);
        html += '<div class="adm-gc-mod-row">';
        html += '<div class="adm-gc-mod-header' + (isExp ? ' adm-expanded' : '') + '" data-action-click="adm-gc-toggle-mod" data-action-adm-mod="' + me + '">';
        html += '<span class="adm-meta-parent-chevron">' + (isExp ? '\u25BC' : '\u25B6') + '</span>';
        html += '<span class="adm-gc-mod-name">' + me + '</span>';
        if (modDesc) {
            html += '<span class="adm-meta-parent-desc">' + cc_escapeHtml(modDesc) + '</span>';
        }
        html += '<span class="adm-meta-parent-count">' + totalLabel + '</span>';
        html += '<button class="adm-meta-add-btn" data-action-click="adm-gc-start-add" data-action-adm-mod="' + me + '" title="Add new setting">+</button>';
        html += '</div></div>';
        if (isExp) {
            if (adm_gcAddingTo === mod) {
                html += adm_renderGcAddForm(mod);
            }
            var cats = {};
            var catOrd = [];
            active.forEach(function(s) {
                var cat = s.category || '';
                if (!cats[cat]) {
                    cats[cat] = [];
                    catOrd.push(cat);
                }
                cats[cat].push(s);
            });
            catOrd.forEach(function(cat) {
                if (catOrd.length > 1 || cat) {
                    html += '<div class="adm-gc-category-label">' + cc_escapeHtml(cat || 'General') + '</div>';
                }
                cats[cat].forEach(function(s) { html += adm_renderGcChildCard(s, false); });
            });
            if (inactive.length > 0) {
                var showInact = adm_gcShowInactive[mod];
                html += '<div class="adm-gc-inactive-toggle" data-action-click="adm-gc-toggle-inactive" data-action-adm-mod="' + me + '">' + (showInact ? '\u25BC' : '\u25B6') + ' ' + inactive.length + ' inactive setting' + (inactive.length !== 1 ? 's' : '') + '</div>';
                if (showInact) {
                    inactive.forEach(function(s) { html += adm_renderGcChildCard(s, true); });
                }
            }
        }
    });
    c.innerHTML = html;
}

/* Renders a single setting child card. */
function adm_renderGcChildCard(s, isInactive) {
    var isExp = adm_gcExpandedId === s.config_id;
    var toggleState = isInactive ? 'adm-off' : 'adm-on';
    var toggleHtml = '<span class="adm-gc-active-toggle" data-action-click="adm-gc-toggle-active" data-action-adm-cid="' + s.config_id + '" data-action-adm-state="' + (isInactive ? '1' : '0') + '" title="' + (isInactive ? 'Reactivate' : 'Deactivate') + '"><span class="adm-gc-toggle"><span class="adm-gc-toggle-track ' + toggleState + '"><span class="adm-gc-toggle-knob ' + toggleState + '"></span></span></span></span>';
    if (isInactive) {
        return '<div class="adm-gc-child-card adm-inactive" data-cid="' + s.config_id + '"><div class="adm-gc-child-header" data-action-click="adm-gc-toggle-row" data-action-adm-cid="' + s.config_id + '"><span class="adm-gc-child-desc">' + cc_escapeHtml(s.description || s.setting_name) + '</span><span class="adm-gc-child-name adm-inactive">' + cc_escapeHtml(s.setting_name) + '</span><span class="adm-gc-child-value"><span class="adm-gc-val-inactive">' + cc_escapeHtml(s.setting_value) + '</span></span>' + toggleHtml + '</div><div class="adm-gc-child-body' + (isExp ? ' adm-expanded' : '') + '">' + (isExp ? adm_renderGcDetail(s) : '') + '</div></div>';
    }
    return '<div class="adm-gc-child-card' + (isExp ? ' adm-expanded' : '') + '" data-cid="' + s.config_id + '"><div class="adm-gc-child-header" data-action-click="adm-gc-toggle-row" data-action-adm-cid="' + s.config_id + '"><span class="adm-gc-child-desc">' + cc_escapeHtml(s.description || s.setting_name) + '</span><span class="adm-gc-child-name">' + cc_escapeHtml(s.setting_name) + '</span><span class="adm-gc-child-value">' + adm_renderGcValue(s) + '</span>' + toggleHtml + '</div><div class="adm-gc-child-body' + (isExp ? ' adm-expanded' : '') + '">' + (isExp ? adm_renderGcDetail(s) : '') + '</div></div>';
}

/* Renders the value widget for a setting (ALERT_MODE, BIT, inline editor, or text). */
function adm_renderGcValue(s) {
    if (s.data_type === 'ALERT_MODE') {
        var v = parseInt(s.setting_value, 10) || 0;
        var teamsOn = (v & 1) === 1;
        var jiraOn = (v & 2) === 2;
        return '<span class="adm-gc-alert-badges">' +
            '<span class="adm-gc-alert-badge ' + (teamsOn ? 'adm-teams-on' : 'adm-teams-off') + '" data-action-click="adm-gc-toggle-alert-mode" data-action-adm-cid="' + s.config_id + '" data-action-adm-channel="teams" title="Teams alerts">Teams</span>' +
            '<span class="adm-gc-alert-badge ' + (jiraOn ? 'adm-jira-on' : 'adm-jira-off') + '" data-action-click="adm-gc-toggle-alert-mode" data-action-adm-cid="' + s.config_id + '" data-action-adm-channel="jira" title="Jira tickets">Jira</span>' +
            '</span>';
    }
    if (s.data_type === 'BIT') {
        var isOn = s.setting_value === '1';
        var bitState = isOn ? 'adm-on' : 'adm-off';
        return '<span class="adm-gc-val-bit" data-action-click="adm-gc-toggle-bit" data-action-adm-cid="' + s.config_id + '" title="Click to toggle"><span class="adm-gc-toggle"><span class="adm-gc-toggle-track ' + bitState + '"><span class="adm-gc-toggle-knob ' + bitState + '"></span></span><span class="adm-gc-toggle-label ' + bitState + '">' + (isOn ? 'ON' : 'OFF') + '</span></span></span>';
    }
    if (adm_gcEditingId === s.config_id) {
        return '<span class="adm-gc-edit-wrap"><input type="text" class="adm-gc-edit-input" id="adm-gc-edit-' + s.config_id + '" value="' + cc_escapeHtml(s.setting_value) + '" data-action-keydown="adm-gc-edit-keydown" data-action-adm-cid="' + s.config_id + '"><button class="adm-gc-edit-save" data-action-click="adm-gc-save-edit" data-action-adm-cid="' + s.config_id + '" title="Save">&#10003;</button><button class="adm-gc-edit-cancel" data-action-click="adm-gc-cancel-edit" title="Cancel">&#10007;</button></span>';
    }
    return '<span class="adm-gc-val-text" data-action-click="adm-gc-start-edit" data-action-adm-cid="' + s.config_id + '" title="Click to edit">' + cc_escapeHtml(s.setting_value) + '</span>';
}

/* Renders the expanded setting detail and history container. */
function adm_renderGcDetail(s) {
    var html = '<div class="adm-gc-detail-grid"><div class="adm-gc-detail-desc">' + cc_escapeHtml(s.description || 'No description') + '</div>';
    if (s.notes) {
        html += '<div class="adm-gc-detail-notes">' + cc_escapeHtml(s.notes) + '</div>';
    }
    if (s.category) {
        html += '<div class="adm-gc-detail-item"><span class="adm-gc-detail-label">Category: </span><span class="adm-gc-detail-value">' + cc_escapeHtml(s.category) + '</span></div>';
    }
    if (!adm_gcIsInactive(s)) {
        html += '<div class="adm-gc-detail-deactivate"><span class="adm-gc-deactivate-link" data-action-click="adm-gc-toggle-active" data-action-adm-cid="' + s.config_id + '" data-action-adm-state="0">Deactivate this setting</span></div>';
    }
    html += '</div><div class="adm-gc-history" id="adm-gc-history-' + s.config_id + '"></div>';
    return html;
}

/* Loads change history for a setting into its detail container. */
function adm_gcLoadHistory(cid) {
    var ct = document.getElementById('adm-gc-history-' + cid);
    if (!ct) {
        return;
    }
    ct.innerHTML = '<div class="adm-gc-history-loading">Loading history...</div>';
    cc_engineFetch('/api/admin/globalconfig/history?config_id=' + cid).then(function(data) {
        if (!data) {
            return;
        }
        if (data.Error) {
            ct.innerHTML = '';
            return;
        }
        var arr = Array.isArray(data) ? data : [];
        if (arr.length === 0) {
            ct.innerHTML = '<div class="adm-gc-history-empty">No change history</div>';
            return;
        }
        var html = '<div class="adm-gc-history-header">Change History (' + arr.length + ')</div><div class="adm-gc-history-list">';
        arr.forEach(function(h) {
            html += '<div class="adm-gc-history-entry"><span class="adm-gc-history-ts">' + adm_fmtTs(h.changed_dttm) + '</span><span class="adm-gc-history-user">' + cc_escapeHtml(h.changed_by) + '</span><span class="adm-gc-history-change"><span class="adm-gc-history-old">' + cc_escapeHtml(h.old_value || '(null)') + '</span> &rarr; <span class="adm-gc-history-new">' + cc_escapeHtml(h.new_value) + '</span></span></div>';
        });
        html += '</div>';
        ct.innerHTML = html;
    }).catch(function() {
        ct.innerHTML = '';
    });
}

/* Toggles a globalconfig module row. */
function adm_gcToggleMod(target) {
    var mod = target.getAttribute('data-action-adm-mod');
    adm_gcExpandedId = null;
    adm_gcEditingId = null;
    adm_gcAddingTo = null;
    adm_gcExpandedMod = adm_gcExpandedMod === mod ? null : mod;
    adm_renderGcTree();
}

/* Toggles a setting row and loads its history when expanded. */
function adm_gcToggleRow(target) {
    var cid = parseInt(target.getAttribute('data-action-adm-cid'), 10);
    adm_gcEditingId = null;
    adm_gcAddingTo = null;
    adm_gcExpandedId = adm_gcExpandedId === cid ? null : cid;
    adm_renderGcTree();
    if (adm_gcExpandedId) {
        adm_gcLoadHistory(cid);
        var el = document.querySelector('.adm-gc-child-card[data-cid="' + cid + '"]');
        if (el) {
            el.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
        }
    }
}

/* Opens or closes the add-setting form under a module. */
function adm_gcStartAdd(target) {
    var mod = target.getAttribute('data-action-adm-mod');
    adm_gcExpandedId = null;
    adm_gcEditingId = null;
    if (adm_gcAddingTo === mod) {
        adm_gcAddingTo = null;
    } else {
        adm_gcAddingTo = mod;
        adm_gcExpandedMod = mod;
    }
    adm_renderGcTree();
}

/* Cancels the add-setting form. */
function adm_gcCancelAdd() {
    adm_gcAddingTo = null;
    adm_gcExpandedMod = null;
    adm_renderGcTree();
}

/* Renders the add-setting form. */
function adm_renderGcAddForm(mod) {
    var me = cc_escapeHtml(mod);
    return '<div class="adm-meta-add-form adm-meta-add-child"><div class="adm-meta-add-title">New Setting: ' + me + '<button class="adm-gc-add-close" data-action-click="adm-gc-cancel-add" title="Cancel">&times;</button></div><div class="adm-gc-add-hint">Names must be lowercase with underscores (e.g. my_setting_name)</div><div class="adm-meta-add-row"><input type="text" class="adm-meta-add-input" id="adm-gc-new-name" placeholder="setting_name" maxlength="100" data-action-keydown="adm-gc-add-keydown" data-action-adm-mod="' + me + '"><select class="adm-meta-select adm-gc-add-type" id="adm-gc-new-type"><option value="INT">INT</option><option value="BIT">BIT</option><option value="DECIMAL">DECIMAL</option><option value="VARCHAR">VARCHAR</option></select></div><div class="adm-meta-add-row"><input type="text" class="adm-meta-add-input adm-gc-add-narrow" id="adm-gc-new-value" placeholder="Default value" maxlength="500"><input type="text" class="adm-meta-add-input adm-gc-add-narrow" id="adm-gc-new-category" placeholder="Category (optional)" maxlength="50"></div><div class="adm-meta-add-row"><input type="text" class="adm-meta-desc-input adm-gc-add-grow" id="adm-gc-new-desc" placeholder="Description (required)" maxlength="500"><button class="adm-meta-insert-btn" data-action-click="adm-gc-submit-add" data-action-adm-mod="' + me + '">Insert</button></div><div class="adm-meta-bump-status" id="adm-gc-new-status"></div></div>';
}

/* Validates and submits a new setting. */
function adm_gcSubmitAdd(target) {
    var mod = target.getAttribute('data-action-adm-mod');
    var name = (document.getElementById('adm-gc-new-name').value || '').trim();
    var dt = document.getElementById('adm-gc-new-type').value;
    var val = (document.getElementById('adm-gc-new-value').value || '').trim();
    var cat = (document.getElementById('adm-gc-new-category').value || '').trim();
    var desc = (document.getElementById('adm-gc-new-desc').value || '').trim();
    var st = document.getElementById('adm-gc-new-status');
    if (!name) {
        st.textContent = 'Setting name required';
        st.className = 'adm-meta-bump-status adm-error';
        return;
    }
    if (!/^[a-z][a-z0-9_]*$/.test(name)) {
        st.textContent = 'Name must be lowercase letters, numbers, and underscores only';
        st.className = 'adm-meta-bump-status adm-error';
        return;
    }
    if (val === '') {
        st.textContent = 'Default value required';
        st.className = 'adm-meta-bump-status adm-error';
        return;
    }
    if (!desc) {
        st.textContent = 'Description required';
        st.className = 'adm-meta-bump-status adm-error';
        return;
    }
    cc_showConfirm('Create ' + mod + '.' + name + ' (' + dt + ')?', {
        title: 'Insert Setting',
        confirmLabel: 'Insert',
        confirmClass: 'cc-dialog-btn-primary'
    }).then(function(ok) {
        if (!ok) {
            return;
        }
        cc_engineFetch('/api/admin/globalconfig/insert', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ module_name: mod, setting_name: name, setting_value: val, data_type: dt, category: cat || null, description: desc })
        }).then(function(d) {
            if (!d) {
                return;
            }
            if (d.Error) {
                st.textContent = d.Error;
                st.className = 'adm-meta-bump-status adm-error';
                return;
            }
            st.textContent = 'Created ' + name;
            st.className = 'adm-meta-bump-status adm-success';
            adm_gcAddingTo = null;
            setTimeout(function() { adm_gcGo(); }, 600);
        }).catch(function(e) {
            st.textContent = e.message;
            st.className = 'adm-meta-bump-status adm-error';
        });
    });
}

/* Confirms then toggles a BIT setting. */
function adm_gcToggleBit(target) {
    var cid = parseInt(target.getAttribute('data-action-adm-cid'), 10);
    var s = adm_gcFindSetting(cid);
    if (!s) {
        return;
    }
    var nv = s.setting_value === '1' ? '0' : '1';
    var lbl = s.module_name + '.' + s.setting_name;
    var act = nv === '1' ? 'Enable' : 'Disable';
    cc_showConfirm(act + ' ' + lbl + '?', {
        title: act + ' Setting',
        confirmLabel: act,
        confirmClass: nv === '1' ? 'cc-dialog-btn-primary' : 'cc-dialog-btn-danger'
    }).then(function(ok) {
        if (ok) {
            adm_gcDoUpdate(cid, nv);
        }
    });
}

/* Confirms then updates an ALERT_MODE channel bitmask. */
function adm_gcToggleAlertMode(target) {
    var cid = parseInt(target.getAttribute('data-action-adm-cid'), 10);
    var channel = target.getAttribute('data-action-adm-channel');
    var s = adm_gcFindSetting(cid);
    if (!s) {
        return;
    }
    var v = parseInt(s.setting_value, 10) || 0;
    if (channel === 'teams') {
        v = v ^ 1;
    } else if (channel === 'jira') {
        v = v ^ 2;
    }
    var nv = String(v);
    var labels = [];
    if (v & 1) {
        labels.push('Teams');
    }
    if (v & 2) {
        labels.push('Jira');
    }
    var desc = labels.length > 0 ? labels.join(' + ') : 'None';
    cc_showConfirm('Set ' + s.setting_name + ' to ' + desc + '?', {
        title: 'Update Alert Routing',
        confirmLabel: 'Update',
        confirmClass: 'cc-dialog-btn-primary'
    }).then(function(ok) {
        if (ok) {
            adm_gcDoUpdate(cid, nv);
        }
    });
}

/* Begins inline editing of a setting value. */
function adm_gcStartEdit(target) {
    var cid = parseInt(target.getAttribute('data-action-adm-cid'), 10);
    adm_gcEditingId = cid;
    adm_renderGcTree();
    var inp = document.getElementById('adm-gc-edit-' + cid);
    if (inp) {
        inp.focus();
        inp.select();
    }
}

/* Cancels inline editing. */
function adm_gcCancelEdit() {
    adm_gcEditingId = null;
    adm_renderGcTree();
}

/* Confirms then saves an inline edit. */
function adm_gcSaveEdit(target) {
    var cid = parseInt(target.getAttribute('data-action-adm-cid'), 10);
    var inp = document.getElementById('adm-gc-edit-' + cid);
    if (!inp) {
        return;
    }
    var nv = inp.value.trim();
    var s = adm_gcFindSetting(cid);
    if (!s) {
        return;
    }
    if (nv === s.setting_value) {
        adm_gcCancelEdit();
        return;
    }
    if (!nv) {
        return;
    }
    cc_showConfirm('Change ' + s.module_name + '.' + s.setting_name + ' from \'' + s.setting_value + '\' to \'' + nv + '\'?', {
        title: 'Update Setting',
        confirmLabel: 'Update',
        confirmClass: 'cc-dialog-btn-primary'
    }).then(function(ok) {
        if (ok) {
            adm_gcDoUpdate(cid, nv);
        }
    });
}

/* Posts a setting value update and refreshes the row. */
function adm_gcDoUpdate(cid, nv) {
    cc_engineFetch('/api/admin/globalconfig/update', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ config_id: cid, setting_value: nv })
    }).then(function(d) {
        if (!d) {
            return;
        }
        if (d.Error) {
            adm_gcShowStatus(d.Error, true);
            return;
        }
        var s = adm_gcFindSetting(cid);
        if (s) {
            s.setting_value = nv;
        }
        adm_gcEditingId = null;
        adm_renderGcTree();
        adm_gcShowStatus(d.message, false);
    }).catch(function(e) {
        adm_gcShowStatus(e.message, true);
    });
}

/* Confirms then activates/deactivates a setting. */
function adm_gcToggleActive(target) {
    var cid = parseInt(target.getAttribute('data-action-adm-cid'), 10);
    var newState = parseInt(target.getAttribute('data-action-adm-state'), 10);
    var s = adm_gcFindSetting(cid);
    if (!s) {
        return;
    }
    var lbl = s.module_name + '.' + s.setting_name;
    var act = newState === 1 ? 'Reactivate' : 'Deactivate';
    cc_showConfirm(act + ' ' + lbl + '?', {
        title: act + ' Setting',
        confirmLabel: act,
        confirmClass: newState === 1 ? 'cc-dialog-btn-primary' : 'cc-dialog-btn-danger'
    }).then(function(ok) {
        if (!ok) {
            return;
        }
        cc_engineFetch('/api/admin/globalconfig/update', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ config_id: cid, field_name: 'is_active', new_value: String(newState) })
        }).then(function(d) {
            if (!d) {
                return;
            }
            if (d.Error) {
                adm_gcShowStatus(d.Error, true);
                return;
            }
            adm_gcShowStatus(d.message, false);
            adm_gcGo();
        }).catch(function(e) {
            adm_gcShowStatus(e.message, true);
        });
    });
}

/* Toggles the show-inactive expander for a module. */
function adm_gcToggleInactive(target) {
    var mod = target.getAttribute('data-action-adm-mod');
    adm_gcShowInactive[mod] = !adm_gcShowInactive[mod];
    adm_renderGcTree();
}

/* Finds a setting record by config id. */
function adm_gcFindSetting(cid) {
    var i;
    for (i = 0; i < adm_gcAllSettings.length; i++) {
        if (adm_gcAllSettings[i].config_id === cid) {
            return adm_gcAllSettings[i];
        }
    }
    return null;
}

/* Sets the globalconfig panel status line. */
function adm_gcShowStatus(msg, isErr) {
    var el = document.getElementById('adm-gc-status');
    if (el) {
        el.textContent = msg;
        el.className = 'adm-meta-status ' + (isErr ? 'adm-error' : 'adm-success');
    }
    if (!isErr) {
        setTimeout(function() {
            if (el) {
                el.textContent = '';
                el.className = 'adm-meta-status';
            }
        }, 3000);
    }
}

/* Keydown handler for the inline value editor (Enter saves, Escape cancels). */
function adm_gcEditKeydown(target, event) {
    if (event.key === 'Enter') {
        adm_gcSaveEdit(target);
    } else if (event.key === 'Escape') {
        adm_gcCancelEdit();
    }
}

/* Keydown handler for the add-setting name field (Enter submits). */
function adm_gcAddKeydown(target, event) {
    if (event.key === 'Enter') {
        adm_gcSubmitAdd(target);
    }
}

/* ============================================================================
   FUNCTIONS: PROCESS SCHEDULER
   ----------------------------------------------------------------------------
   The Process Scheduler slide-up: the module/process tree, per-process
   configuration detail with inline-editable fields and mode/concurrency
   toggles, and the add-process form with its script picker and execution-mode
   toggle. Field updates and additions go through confirmation.
   Prefix: adm
   ============================================================================ */

/* Opens the Process Scheduler slide-up and loads processes. */
function adm_openSchedules() {
    adm_schedReset();
    var overlay = document.getElementById('adm-slideup-schedule');
    var dialog = overlay.querySelector('.cc-dialog');
    overlay.classList.add('cc-open');
    requestAnimationFrame(function() {
        dialog.classList.add('cc-open');
    });
    adm_loadAdminModules().then(function() {
        adm_schedLoad();
    });
}

/* Closes the Process Scheduler slide-up (backdrop-guarded). */
function adm_closeSchedules(target, event) {
    if (event && target.id === 'adm-slideup-schedule' && event.target !== target) {
        return;
    }
    var overlay = document.getElementById('adm-slideup-schedule');
    var dialog = overlay.querySelector('.cc-dialog');
    dialog.addEventListener('transitionend', function handler() {
        dialog.removeEventListener('transitionend', handler);
        overlay.classList.remove('cc-open');
    });
    dialog.classList.remove('cc-open');
}

/* Resets scheduler state and clears the panel. */
function adm_schedReset() {
    adm_schedAllProcesses = [];
    adm_schedExpandedMod = null;
    adm_schedExpandedId = null;
    adm_schedEditingField = null;
    adm_schedAddingTo = null;
    adm_schedAvailableScripts = [];
    var st = document.getElementById('adm-sched-status');
    st.textContent = '';
    st.className = 'adm-meta-status';
    document.getElementById('adm-sched-tree-list').innerHTML = '';
    document.getElementById('adm-sched-results-count').textContent = '';
}

/* Loads the scheduler process list. */
function adm_schedLoad() {
    document.getElementById('adm-sched-tree-list').innerHTML = '<div class="adm-loading">Loading processes...</div>';
    cc_engineFetch('/api/admin/schedule/processes').then(function(data) {
        if (!data) {
            return;
        }
        if (data.Error) {
            adm_schedShowStatus(data.Error, true);
            return;
        }
        adm_schedAllProcesses = Array.isArray(data) ? data : [];
        document.getElementById('adm-sched-results-count').textContent = adm_schedAllProcesses.length + ' process' + (adm_schedAllProcesses.length !== 1 ? 'es' : '');
        adm_renderSchedTree();
    }).catch(function(e) {
        adm_schedShowStatus(e.message, true);
    });
}

/* Renders the scheduler module/process tree. */
function adm_renderSchedTree() {
    var c = document.getElementById('adm-sched-tree-list');
    if (adm_schedAllProcesses.length === 0) {
        c.innerHTML = '<div class="cc-slide-empty">No processes found</div>';
        return;
    }
    var modules = {};
    adm_schedAllProcesses.forEach(function(p) {
        var mod = p.module_name || 'Other';
        if (!modules[mod]) {
            modules[mod] = [];
        }
        modules[mod].push(p);
    });
    var html = '';
    var modNames = Object.keys(modules).sort();
    modNames.forEach(function(mod) {
        var procs = modules[mod];
        var isExp = adm_schedExpandedMod === mod;
        var modDesc = adm_adminModules[mod] || '';
        var me = cc_escapeHtml(mod);
        html += '<div class="adm-sched-mod-row">';
        html += '<div class="adm-sched-mod-header' + (isExp ? ' adm-expanded' : '') + '" data-action-click="adm-sched-toggle-mod" data-action-adm-mod="' + me + '">';
        html += '<span class="adm-meta-parent-chevron">' + (isExp ? '\u25BC' : '\u25B6') + '</span>';
        html += '<span class="adm-sched-mod-name">' + me + '</span>';
        if (modDesc) {
            html += '<span class="adm-meta-parent-desc">' + cc_escapeHtml(modDesc) + '</span>';
        }
        html += '<span class="adm-meta-parent-count">' + procs.length + '</span>';
        html += '<button class="adm-meta-add-btn" data-action-click="adm-sched-start-add" data-action-adm-mod="' + me + '" title="Add new process">+</button>';
        html += '</div></div>';
        if (isExp) {
            if (adm_schedAddingTo === mod) {
                html += adm_renderSchedAddForm(mod);
            }
            procs.forEach(function(p) { html += adm_renderSchedCard(p); });
        }
    });
    c.innerHTML = html;
}

/* Renders a single process card. */
function adm_renderSchedCard(p) {
    var isExp = adm_schedExpandedId === p.process_id;
    var modeLabel = p.execution_mode === 'FIRE_AND_FORGET' ? 'F&F' : 'WAIT';
    var modeBadge = '<span class="adm-sched-mode-badge ' + (p.execution_mode === 'WAIT' ? 'adm-wait' : 'adm-ff') + '">' + modeLabel + '</span>';
    var statusCls = p.run_mode === 0 ? 'adm-disabled' : 'adm-enabled';
    var statusLabel = p.run_mode === 0 ? 'OFF' : (p.run_mode === 2 ? 'QUEUE' : 'ON');
    var statusBadge = '<span class="adm-sched-status-badge ' + statusCls + '">' + statusLabel + '</span>';
    var html = '<div class="adm-sched-child-card' + (isExp ? ' adm-expanded' : '') + '" data-pid="' + p.process_id + '">';
    html += '<div class="adm-sched-child-header" data-action-click="adm-sched-toggle-row" data-action-adm-pid="' + p.process_id + '">';
    html += statusBadge;
    html += '<span class="adm-sched-child-name">' + cc_escapeHtml(p.process_name) + '</span>';
    html += '<span class="adm-meta-child-dots"></span>';
    html += modeBadge;
    html += '<span class="adm-sched-child-group">G' + p.dependency_group + '</span>';
    html += '</div>';
    html += '<div class="adm-sched-child-body' + (isExp ? ' adm-expanded' : '') + '">' + (isExp ? adm_renderSchedDetail(p) : '') + '</div>';
    html += '</div>';
    return html;
}

/* Normalizes a scheduled-time value to HH:mm:ss, or null. */
function adm_formatSchedTime(val) {
    if (!val) {
        return null;
    }
    if (typeof val === 'string' && val.indexOf('/Date(') === 0) {
        var ms = parseInt(val.replace(/\/Date\((-?\d+)\)\//, '$1'), 10);
        if (!isNaN(ms)) {
            var td = new Date(ms);
            return (td.getHours() < 10 ? '0' : '') + td.getHours() + ':' + (td.getMinutes() < 10 ? '0' : '') + td.getMinutes() + ':' + (td.getSeconds() < 10 ? '0' : '') + td.getSeconds();
        }
    }
    if (typeof val === 'string') {
        return val;
    }
    if (typeof val === 'object' && val !== null) {
        var h = val.Hours || val.hours || 0;
        var m = val.Minutes || val.minutes || 0;
        var s = val.Seconds || val.seconds || 0;
        if (typeof h === 'number') {
            return (h < 10 ? '0' : '') + h + ':' + (m < 10 ? '0' : '') + m + ':' + (s < 10 ? '0' : '') + s;
        }
        if (val.TotalMilliseconds !== undefined) {
            var tot = Math.floor(val.TotalMilliseconds / 1000);
            h = Math.floor(tot / 3600);
            m = Math.floor((tot % 3600) / 60);
            s = tot % 60;
            return (h < 10 ? '0' : '') + h + ':' + (m < 10 ? '0' : '') + m + ':' + (s < 10 ? '0' : '') + s;
        }
    }
    return String(val);
}

/* Renders the expanded process detail (info card + settings grid). */
function adm_renderSchedDetail(p) {
    var html = '<div class="adm-sched-detail">';
    html += '<div class="adm-sched-info-card">';
    html += '<div class="adm-sched-desc">' + cc_escapeHtml(p.description || 'No description') + '</div>';
    html += '<div class="adm-sched-script"><span class="adm-sched-script-label">Script</span><span class="adm-sched-script-path">' + cc_escapeHtml(p.script_path || '-') + '</span></div>';
    html += '</div>';
    html += '<div class="adm-sched-settings-card">';
    html += '<div class="adm-sched-settings-title">Configuration</div>';
    html += '<div class="adm-sched-settings-grid">';
    var isFF = p.execution_mode === 'FIRE_AND_FORGET';
    var ffState = isFF ? 'adm-on' : 'adm-off';
    html += '<div class="adm-sched-setting-item adm-wide">';
    html += '<span class="adm-sched-setting-label">Execution Mode</span>';
    html += '<span class="adm-sched-setting-control">';
    html += '<span class="adm-sched-toggle-wrap" data-action-click="adm-sched-toggle-mode" data-action-adm-pid="' + p.process_id + '" title="WAIT: Engine waits for process to finish before continuing.&#10;FIRE_AND_FORGET: Engine launches and moves on.">';
    html += '<span class="adm-gc-toggle-track ' + ffState + '"><span class="adm-gc-toggle-knob ' + ffState + '"></span></span>';
    html += '<span class="adm-gc-toggle-label ' + ffState + '">' + (isFF ? 'Fire & Forget' : 'Wait for Exit') + '</span></span></span></div>';
    html += adm_schedEditableField(p, 'dependency_group', 'Dep. Group', p.dependency_group);
    html += adm_schedEditableField(p, 'interval_seconds', 'Interval (sec)', p.interval_seconds);
    var schedTime = adm_formatSchedTime(p.scheduled_time);
    html += adm_schedEditableField(p, 'scheduled_time', 'Sched. Time', schedTime || '(none)');
    html += adm_schedEditableField(p, 'timeout_seconds', 'Timeout (sec)', p.timeout_seconds !== null && p.timeout_seconds !== undefined ? p.timeout_seconds : '(none)');
    var isCon = p.allow_concurrent === true || p.allow_concurrent === 1;
    var conState = isCon ? 'adm-on' : 'adm-off';
    html += '<div class="adm-sched-setting-item adm-wide">';
    html += '<span class="adm-sched-setting-label">Allow Concurrent</span>';
    html += '<span class="adm-sched-setting-control">';
    html += '<span class="adm-sched-toggle-wrap" data-action-click="adm-sched-toggle-concurrent" data-action-adm-pid="' + p.process_id + '">';
    html += '<span class="adm-gc-toggle-track ' + conState + '"><span class="adm-gc-toggle-knob ' + conState + '"></span></span>';
    html += '<span class="adm-gc-toggle-label ' + conState + '">' + (isCon ? 'Yes' : 'No') + '</span></span></span></div>';
    html += '</div>';
    html += '</div>';
    html += '<div class="adm-sched-card-status" id="adm-sched-card-status-' + p.process_id + '"></div>';
    html += '</div>';
    return html;
}

/* Renders an inline-editable setting field. */
function adm_schedEditableField(p, field, label, displayVal) {
    var isEditing = adm_schedEditingField && adm_schedEditingField.pid === p.process_id && adm_schedEditingField.field === field;
    var html = '<div class="adm-sched-setting-item">';
    html += '<span class="adm-sched-setting-label">' + label + '</span>';
    if (isEditing) {
        html += '<span class="adm-sched-setting-control"><span class="adm-gc-edit-wrap">';
        html += '<input type="text" class="adm-gc-edit-input adm-sched-edit-input" id="adm-sched-edit-input" value="' + cc_escapeHtml(displayVal === '(none)' ? '' : displayVal) + '" data-action-keydown="adm-sched-edit-keydown" data-action-adm-pid="' + p.process_id + '" data-action-adm-field="' + field + '">';
        html += '<button class="adm-gc-edit-save" data-action-click="adm-sched-save-field" data-action-adm-pid="' + p.process_id + '" data-action-adm-field="' + field + '" title="Save">&#10003;</button>';
        html += '<button class="adm-gc-edit-cancel" data-action-click="adm-sched-cancel-edit" title="Cancel">&#10007;</button>';
        html += '</span></span>';
    } else {
        html += '<span class="adm-sched-setting-control"><span class="adm-sched-setting-value" data-action-click="adm-sched-start-edit" data-action-adm-pid="' + p.process_id + '" data-action-adm-field="' + field + '">' + cc_escapeHtml(String(displayVal)) + '</span></span>';
    }
    html += '</div>';
    return html;
}

/* Toggles a scheduler module row. */
function adm_schedToggleMod(target) {
    var mod = target.getAttribute('data-action-adm-mod');
    adm_schedExpandedId = null;
    adm_schedEditingField = null;
    adm_schedAddingTo = null;
    adm_schedExpandedMod = adm_schedExpandedMod === mod ? null : mod;
    adm_renderSchedTree();
}

/* Toggles a process card row. */
function adm_schedToggleRow(target) {
    var pid = parseInt(target.getAttribute('data-action-adm-pid'), 10);
    adm_schedEditingField = null;
    adm_schedAddingTo = null;
    adm_schedExpandedId = adm_schedExpandedId === pid ? null : pid;
    adm_renderSchedTree();
    if (adm_schedExpandedId) {
        var el = document.querySelector('.adm-sched-child-card[data-pid="' + pid + '"]');
        if (el) {
            el.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
        }
    }
}

/* Begins inline editing of a process field. */
function adm_schedStartEdit(target) {
    var pid = parseInt(target.getAttribute('data-action-adm-pid'), 10);
    var field = target.getAttribute('data-action-adm-field');
    adm_schedEditingField = { pid: pid, field: field };
    adm_renderSchedTree();
    var inp = document.getElementById('adm-sched-edit-input');
    if (inp) {
        inp.focus();
        inp.select();
    }
}

/* Cancels inline field editing. */
function adm_schedCancelEdit() {
    adm_schedEditingField = null;
    adm_renderSchedTree();
}

/* Confirms then saves an inline field edit. */
function adm_schedSaveField(target) {
    var pid = parseInt(target.getAttribute('data-action-adm-pid'), 10);
    var field = target.getAttribute('data-action-adm-field');
    var inp = document.getElementById('adm-sched-edit-input');
    if (!inp) {
        return;
    }
    var newVal = inp.value.trim();
    var p = adm_schedFindProcess(pid);
    if (!p) {
        return;
    }
    var currentVal = String(p[field] !== null && p[field] !== undefined ? p[field] : '');
    if (field === 'scheduled_time') {
        currentVal = adm_formatSchedTime(p[field]) || '';
    }
    if (newVal === currentVal) {
        adm_schedCancelEdit();
        return;
    }
    var displayField = field.replace(/_/g, ' ');
    cc_showConfirm('Change ' + p.process_name + '.' + displayField + ' from \'' + currentVal + '\' to \'' + newVal + '\'?', {
        title: 'Update ' + displayField,
        confirmLabel: 'Update',
        confirmClass: 'cc-dialog-btn-primary'
    }).then(function(ok) {
        if (ok) {
            adm_schedDoUpdate(pid, field, currentVal, newVal);
        }
    });
}

/* Confirms then toggles a process's execution mode. */
function adm_schedToggleMode(target) {
    var pid = parseInt(target.getAttribute('data-action-adm-pid'), 10);
    var p = adm_schedFindProcess(pid);
    if (!p) {
        return;
    }
    var oldMode = p.execution_mode;
    var newMode = oldMode === 'FIRE_AND_FORGET' ? 'WAIT' : 'FIRE_AND_FORGET';
    var newLabel = newMode === 'FIRE_AND_FORGET' ? 'Fire & Forget' : 'Wait for Exit';
    cc_showConfirm('Change ' + p.process_name + ' to ' + newLabel + '?\n\nWAIT: The orchestrator waits for the process to finish before continuing.\nFIRE & FORGET: The orchestrator launches the process and moves on immediately.\n\nTakes effect on the next execution cycle.', {
        title: 'Change Execution Mode',
        confirmLabel: 'Change',
        confirmClass: 'cc-dialog-btn-danger'
    }).then(function(ok) {
        if (ok) {
            adm_schedDoUpdate(pid, 'execution_mode', oldMode, newMode);
        }
    });
}

/* Confirms then toggles a process's concurrency setting. */
function adm_schedToggleConcurrent(target) {
    var pid = parseInt(target.getAttribute('data-action-adm-pid'), 10);
    var p = adm_schedFindProcess(pid);
    if (!p) {
        return;
    }
    var oldVal = (p.allow_concurrent === true || p.allow_concurrent === 1) ? '1' : '0';
    var newVal = oldVal === '1' ? '0' : '1';
    var label = newVal === '1' ? 'Enable' : 'Disable';
    cc_showConfirm(label + ' concurrent execution for ' + p.process_name + '?', {
        title: label + ' Concurrent Execution',
        confirmLabel: label,
        confirmClass: newVal === '1' ? 'cc-dialog-btn-primary' : 'cc-dialog-btn-danger'
    }).then(function(ok) {
        if (ok) {
            adm_schedDoUpdate(pid, 'allow_concurrent', oldVal, newVal);
        }
    });
}

/* Posts a scheduler field update and refreshes the card. */
function adm_schedDoUpdate(pid, field, oldVal, newVal) {
    cc_engineFetch('/api/admin/schedule/update', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ process_id: pid, field_name: field, old_value: oldVal, new_value: newVal })
    }).then(function(d) {
        if (!d) {
            return;
        }
        if (d.Error) {
            adm_schedShowCardStatus(pid, d.Error, true);
            return;
        }
        var p = adm_schedFindProcess(pid);
        if (p) {
            if (field === 'allow_concurrent') {
                p[field] = newVal === '1' ? 1 : 0;
            } else if (field === 'dependency_group' || field === 'interval_seconds' || field === 'timeout_seconds') {
                p[field] = parseInt(newVal, 10);
            } else {
                p[field] = newVal === '' || newVal === 'null' ? null : newVal;
            }
        }
        adm_schedEditingField = null;
        adm_renderSchedTree();
        adm_schedShowCardStatus(pid, d.message, false);
        adm_loadProcessStatus();
    }).catch(function(e) {
        adm_schedShowCardStatus(pid, e.message, true);
    });
}

/* Opens or closes the add-process form under a module. */
function adm_schedStartAdd(target) {
    var mod = target.getAttribute('data-action-adm-mod');
    adm_schedExpandedId = null;
    adm_schedEditingField = null;
    if (adm_schedAddingTo === mod) {
        adm_schedAddingTo = null;
    } else {
        adm_schedAddingTo = mod;
        adm_schedExpandedMod = mod;
        adm_schedAddMode = 'FIRE_AND_FORGET';
        adm_schedLoadAvailableScripts();
    }
    adm_renderSchedTree();
}

/* Cancels the add-process form. */
function adm_schedCancelAdd() {
    adm_schedAddingTo = null;
    adm_renderSchedTree();
}

/* Loads available script filenames for the add-process dropdown. */
function adm_schedLoadAvailableScripts() {
    cc_engineFetch('/api/admin/schedule/browse-scripts').then(function(data) {
        if (!data) {
            return;
        }
        if (data.Error) {
            adm_schedShowStatus(data.Error, true);
            return;
        }
        adm_schedAvailableScripts = Array.isArray(data) ? data : [];
        adm_renderSchedTree();
    }).catch(function(e) {
        adm_schedShowStatus(e.message, true);
    });
}

/* Renders the add-process form. */
function adm_renderSchedAddForm(mod) {
    var me = cc_escapeHtml(mod);
    var ffState = adm_schedAddMode === 'FIRE_AND_FORGET' ? 'adm-on' : 'adm-off';
    var html = '<div class="adm-meta-add-form adm-meta-add-child">';
    html += '<div class="adm-meta-add-title">New Process: ' + me + '<button class="adm-gc-add-close" data-action-click="adm-sched-cancel-add" title="Cancel">&times;</button></div>';
    html += '<div class="adm-meta-add-row"><label class="adm-sched-add-label">Script</label>';
    html += '<select class="adm-meta-select" id="adm-sched-new-script" data-action-change="adm-sched-script-selected">';
    html += '<option value="">Select a script...</option>';
    adm_schedAvailableScripts.forEach(function(f) {
        html += '<option value="' + cc_escapeHtml(f) + '">' + cc_escapeHtml(f) + '</option>';
    });
    if (adm_schedAvailableScripts.length === 0) {
        html += '<option value="" disabled>Loading scripts...</option>';
    }
    html += '</select></div>';
    html += '<div class="adm-meta-add-row"><label class="adm-sched-add-label">Process Name</label>';
    html += '<input type="text" class="adm-meta-add-input" id="adm-sched-new-name" placeholder="(auto-populated from script)" readonly></div>';
    html += '<div class="adm-meta-add-row"><label class="adm-sched-add-label">Description</label>';
    html += '<input type="text" class="adm-meta-desc-input adm-gc-add-grow" id="adm-sched-new-desc" placeholder="Description (required)" maxlength="500"></div>';
    html += '<div class="adm-meta-add-row"><label class="adm-sched-add-label">Execution Mode</label>';
    html += '<span class="adm-sched-toggle-wrap" data-action-click="adm-sched-add-toggle-mode">';
    html += '<span class="adm-gc-toggle-track ' + ffState + '" id="adm-sched-new-mode-track"><span class="adm-gc-toggle-knob ' + ffState + '" id="adm-sched-new-mode-knob"></span></span>';
    html += '<span class="adm-gc-toggle-label ' + ffState + '" id="adm-sched-new-mode-label">' + (adm_schedAddMode === 'FIRE_AND_FORGET' ? 'Fire & Forget' : 'Wait for Exit') + '</span></span></div>';
    html += '<div class="adm-sched-add-grid">';
    html += '<div class="adm-sched-add-cell"><label class="adm-sched-add-cell-label">Dependency Group</label><input type="number" class="adm-sched-add-cell-input" id="adm-sched-new-group" placeholder="Group #" min="1"></div>';
    html += '<div class="adm-sched-add-cell"><label class="adm-sched-add-cell-label">Interval (seconds)</label><input type="number" class="adm-sched-add-cell-input" id="adm-sched-new-interval" placeholder="Seconds" min="0" value="300"></div>';
    html += '<div class="adm-sched-add-cell"><label class="adm-sched-add-cell-label">Timeout (seconds)</label><input type="number" class="adm-sched-add-cell-input" id="adm-sched-new-timeout" placeholder="Seconds" min="1"></div>';
    html += '<div class="adm-sched-add-cell"><label class="adm-sched-add-cell-label">Scheduled Time</label><input type="text" class="adm-sched-add-cell-input" id="adm-sched-new-schedtime" placeholder="HH:mm:ss (optional)"></div>';
    html += '</div>';
    html += '<div class="adm-meta-add-row adm-sched-add-actions"><button class="adm-meta-insert-btn" data-action-click="adm-sched-submit-add" data-action-adm-mod="' + me + '">Add Process</button></div>';
    html += '<div class="adm-meta-bump-status" id="adm-sched-new-status"></div>';
    html += '</div>';
    return html;
}

/* Toggles the execution-mode switch in the add-process form. */
function adm_schedAddToggleMode() {
    var track = document.getElementById('adm-sched-new-mode-track');
    var knob = document.getElementById('adm-sched-new-mode-knob');
    var label = document.getElementById('adm-sched-new-mode-label');
    if (!track) {
        return;
    }
    if (adm_schedAddMode === 'FIRE_AND_FORGET') {
        adm_schedAddMode = 'WAIT';
        track.className = 'adm-gc-toggle-track adm-off';
        knob.className = 'adm-gc-toggle-knob adm-off';
        label.className = 'adm-gc-toggle-label adm-off';
        label.textContent = 'Wait for Exit';
    } else {
        adm_schedAddMode = 'FIRE_AND_FORGET';
        track.className = 'adm-gc-toggle-track adm-on';
        knob.className = 'adm-gc-toggle-knob adm-on';
        label.className = 'adm-gc-toggle-label adm-on';
        label.textContent = 'Fire & Forget';
    }
}

/* Auto-populates the process name and description from the chosen script. */
function adm_schedScriptSelected() {
    var sel = document.getElementById('adm-sched-new-script');
    var nameEl = document.getElementById('adm-sched-new-name');
    var descEl = document.getElementById('adm-sched-new-desc');
    if (!sel || !nameEl) {
        return;
    }
    var file = sel.value;
    if (!file) {
        nameEl.value = '';
        return;
    }
    var procName = file.replace(/\.ps1$/i, '');
    nameEl.value = procName;
    if (!descEl.value) {
        var desc = procName.replace(/-/g, ' ').replace(/([a-z])([A-Z])/g, '$1 $2').replace(/^./, function(c) { return c.toUpperCase(); });
        descEl.value = desc;
    }
}

/* Validates and submits a new process. */
function adm_schedSubmitAdd(target) {
    var mod = target.getAttribute('data-action-adm-mod');
    var script = (document.getElementById('adm-sched-new-script').value || '').trim();
    var name = (document.getElementById('adm-sched-new-name').value || '').trim();
    var desc = (document.getElementById('adm-sched-new-desc').value || '').trim();
    var mode = document.getElementById('adm-sched-new-mode-label').textContent === 'Fire & Forget' ? 'FIRE_AND_FORGET' : 'WAIT';
    var group = (document.getElementById('adm-sched-new-group').value || '').trim();
    var interval = (document.getElementById('adm-sched-new-interval').value || '').trim();
    var timeout = (document.getElementById('adm-sched-new-timeout').value || '').trim();
    var schedTime = (document.getElementById('adm-sched-new-schedtime').value || '').trim();
    var st = document.getElementById('adm-sched-new-status');
    if (!script) {
        st.textContent = 'Select a script';
        st.className = 'adm-meta-bump-status adm-error';
        return;
    }
    if (!desc) {
        st.textContent = 'Description is required';
        st.className = 'adm-meta-bump-status adm-error';
        return;
    }
    if (!group) {
        st.textContent = 'Dependency group is required';
        st.className = 'adm-meta-bump-status adm-error';
        return;
    }
    if (!timeout) {
        st.textContent = 'Timeout is required';
        st.className = 'adm-meta-bump-status adm-error';
        return;
    }
    cc_showConfirm('Register ' + name + ' in ' + mod + '?\n\nThe process will be created DISABLED (run_mode = 0). Enable it manually when ready.', {
        title: 'Add Process',
        confirmLabel: 'Add',
        confirmClass: 'cc-dialog-btn-primary'
    }).then(function(ok) {
        if (!ok) {
            return;
        }
        cc_engineFetch('/api/admin/schedule/add', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ module_name: mod, script_path: script, process_name: name, description: desc, execution_mode: mode, dependency_group: parseInt(group, 10), interval_seconds: interval ? parseInt(interval, 10) : 300, scheduled_time: schedTime || null, timeout_seconds: parseInt(timeout, 10) })
        }).then(function(d) {
            if (!d) {
                return;
            }
            if (d.Error) {
                st.textContent = d.Error;
                st.className = 'adm-meta-bump-status adm-error';
                return;
            }
            st.textContent = 'Added ' + name + ' (disabled)';
            st.className = 'adm-meta-bump-status adm-success';
            adm_schedAddingTo = null;
            setTimeout(function() {
                adm_schedLoad();
                adm_loadProcessStatus();
            }, 600);
        }).catch(function(e) {
            st.textContent = e.message;
            st.className = 'adm-meta-bump-status adm-error';
        });
    });
}

/* Finds a process record by id. */
function adm_schedFindProcess(pid) {
    var i;
    for (i = 0; i < adm_schedAllProcesses.length; i++) {
        if (adm_schedAllProcesses[i].process_id === pid) {
            return adm_schedAllProcesses[i];
        }
    }
    return null;
}

/* Sets the scheduler panel status line. */
function adm_schedShowStatus(msg, isErr) {
    var el = document.getElementById('adm-sched-status');
    if (el) {
        el.textContent = msg;
        el.className = 'adm-meta-status ' + (isErr ? 'adm-error' : 'adm-success');
    }
    if (!isErr) {
        setTimeout(function() {
            if (el) {
                el.textContent = '';
                el.className = 'adm-meta-status';
            }
        }, 3000);
    }
}

/* Sets a per-card status line in the scheduler. */
function adm_schedShowCardStatus(pid, msg, isErr) {
    var el = document.getElementById('adm-sched-card-status-' + pid);
    if (el) {
        el.textContent = msg;
        el.className = 'adm-sched-card-status ' + (isErr ? 'adm-error' : 'adm-success');
    }
    if (!isErr) {
        setTimeout(function() {
            if (el) {
                el.textContent = '';
                el.className = 'adm-sched-card-status';
            }
        }, 3000);
    }
}

/* Keydown handler for inline scheduler field edits (Enter saves, Escape cancels). */
function adm_schedEditKeydown(target, event) {
    if (event.key === 'Enter') {
        adm_schedSaveField(target);
    } else if (event.key === 'Escape') {
        adm_schedCancelEdit();
    }
}

/* ============================================================================
   FUNCTIONS: DOCUMENTATION PIPELINE
   ----------------------------------------------------------------------------
   The Documentation slide-up: step toggles with card dimming and sub-option
   reveal, the run action that launches the pipeline and polls for status, and
   the collapsible per-step results. The step toggles are native checkboxes
   bound through the delegated change dispatcher.
   Prefix: adm
   ============================================================================ */

/* Converts a doc-pipeline step key (the underscored API contract value) to its
   hyphenated DOM id suffix, so element ids stay lowercase-hyphen while the
   payload keeps the underscore form the API expects. */
function adm_docStepIdSuffix(stepKey) {
    return stepKey.replace(/_/g, '-');
}

/* Opens the Documentation slide-up and resets its result state. */
function adm_openDocPipeline() {
    var res = document.getElementById('adm-doc-results');
    if (res) {
        res.innerHTML = '';
    }
    var st = document.getElementById('adm-doc-run-status');
    if (st) {
        st.textContent = '';
        st.className = 'adm-doc-run-status';
    }
    var btn = document.getElementById('adm-doc-run-btn');
    if (btn) {
        btn.disabled = false;
        btn.textContent = 'Run Selected';
        btn.setAttribute('data-action-click', 'adm-doc-run');
    }
    ['generate_ddl', 'publish_confluence', 'publish_github', 'consolidate_upload'].forEach(function(k) {
        var el = document.getElementById('adm-doc-status-' + adm_docStepIdSuffix(k));
        if (el) {
            el.textContent = '';
            el.className = 'adm-doc-card-status';
        }
    });
    var overlay = document.getElementById('adm-slideup-docpipeline');
    var dialog = overlay.querySelector('.cc-dialog');
    overlay.classList.add('cc-open');
    requestAnimationFrame(function() {
        dialog.classList.add('cc-open');
    });
    adm_docUpdateCards();
}

/* Closes the Documentation slide-up (backdrop-guarded; blocked while running). */
function adm_closeDocPipeline(target, event) {
    if (adm_docRunning) {
        return;
    }
    if (event && target.id === 'adm-slideup-docpipeline' && event.target !== target) {
        return;
    }
    if (adm_docPollTimer) {
        clearInterval(adm_docPollTimer);
        adm_docPollTimer = null;
    }
    var overlay = document.getElementById('adm-slideup-docpipeline');
    var dialog = overlay.querySelector('.cc-dialog');
    dialog.addEventListener('transitionend', function handler() {
        dialog.removeEventListener('transitionend', handler);
        overlay.classList.remove('cc-open');
    });
    dialog.classList.remove('cc-open');
}

/* Updates step-card dimming and sub-option visibility from the toggles. */
function adm_docUpdateCards() {
    adm_DOC_ALL_STEPS.forEach(function(s) {
        var cb = document.getElementById(s.step);
        var card = document.getElementById(s.card);
        if (cb && card) {
            if (cb.checked) {
                card.classList.remove('adm-off');
            } else {
                card.classList.add('adm-off');
            }
        }
    });
    adm_DOC_STEP_OPTION_MAP.forEach(function(pair) {
        var cb = document.getElementById(pair.step);
        var opts = document.getElementById(pair.options);
        if (cb && opts) {
            opts.classList.toggle('adm-hidden', !cb.checked);
        }
    });
}

/* Toggles a sub-option pill's active state. */
function adm_docTogglePill(target) {
    target.classList.toggle('adm-active');
}

/* Wires the step toggles by adding the change action; no per-element listeners. */
function adm_initDocStepToggles() {
    adm_DOC_ALL_STEPS.forEach(function(s) {
        var cb = document.getElementById(s.step);
        if (cb) {
            cb.setAttribute('data-action-change', 'adm-doc-step-change');
        }
    });
    adm_docUpdateCards();
}

/* Launches the documentation pipeline run. */
function adm_runDocPipeline() {
    if (adm_docRunning) {
        return;
    }
    var steps = [];
    if (document.getElementById('adm-doc-step-ddl').checked) {
        steps.push('generate_ddl');
    }
    if (document.getElementById('adm-doc-step-publish').checked) {
        steps.push('publish_confluence');
    }
    if (document.getElementById('adm-doc-step-github').checked) {
        steps.push('publish_github');
    }
    if (document.getElementById('adm-doc-step-consolidate').checked) {
        steps.push('consolidate_upload');
    }
    var st = document.getElementById('adm-doc-run-status');
    if (steps.length === 0) {
        st.textContent = 'Select at least one step';
        st.className = 'adm-doc-run-status adm-error';
        return;
    }
    var payload = {
        steps: steps,
        publish_to_confluence: document.getElementById('adm-doc-opt-confluence').classList.contains('adm-active'),
        export_markdown: document.getElementById('adm-doc-opt-markdown').classList.contains('adm-active'),
        include_sql_objects: document.getElementById('adm-doc-opt-sql').classList.contains('adm-active'),
        include_json: document.getElementById('adm-doc-opt-json').classList.contains('adm-active')
    };
    adm_docRunning = true;
    adm_docSelectedSteps = steps.slice();
    var btn = document.getElementById('adm-doc-run-btn');
    btn.disabled = true;
    btn.textContent = 'Running...';
    st.textContent = 'Launching pipeline...';
    st.className = 'adm-doc-run-status adm-running';
    steps.forEach(function(k) {
        var el = document.getElementById('adm-doc-status-' + adm_docStepIdSuffix(k));
        if (el) {
            el.textContent = '\u23F3';
            el.className = 'adm-doc-card-status adm-pending';
        }
    });
    document.getElementById('adm-doc-results').innerHTML = '';
    cc_engineFetch('/api/admin/doc-pipeline', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload)
    }).then(function(data) {
        if (!data) {
            return;
        }
        if (data.Error) {
            adm_docRunning = false;
            btn.disabled = false;
            btn.textContent = 'Run Selected';
            st.textContent = data.Error;
            st.className = 'adm-doc-run-status adm-error';
            return;
        }
        st.textContent = 'Pipeline running...';
        st.className = 'adm-doc-run-status adm-running';
        adm_docPollTimer = setInterval(adm_pollDocStatus, 2000);
        setTimeout(adm_pollDocStatus, 500);
    }).catch(function(err) {
        adm_docRunning = false;
        btn.disabled = false;
        btn.textContent = 'Run Selected';
        st.textContent = 'Launch failed: ' + err.message;
        st.className = 'adm-doc-run-status adm-error';
    });
}

/* Polls pipeline status and renders results on completion. */
function adm_pollDocStatus() {
    cc_engineFetch('/api/admin/doc-pipeline/status').then(function(data) {
        if (!data) {
            return;
        }
        if (data.pending) {
            return;
        }
        var results = data.results || [];
        var st = document.getElementById('adm-doc-run-status');
        results.forEach(function(r) {
            var el = document.getElementById('adm-doc-status-' + adm_docStepIdSuffix(r.step));
            if (!el) {
                return;
            }
            if (r.status === 'running') {
                el.textContent = '\u23F3';
                el.className = 'adm-doc-card-status adm-pending';
            } else if (r.status === 'success') {
                el.textContent = '\u2713';
                el.className = 'adm-doc-card-status adm-success';
            } else if (r.status === 'warning') {
                el.textContent = '\u26A0';
                el.className = 'adm-doc-card-status adm-warning';
            } else if (r.status === 'failed') {
                el.textContent = '\u2717';
                el.className = 'adm-doc-card-status adm-failed';
            }
        });
        var doneCount = 0;
        results.forEach(function(r) {
            if (r.status !== 'running') {
                doneCount++;
            }
        });
        if (!data.complete) {
            st.textContent = 'Running... (' + doneCount + '/' + adm_docSelectedSteps.length + ' complete)';
        }
        if (data.complete) {
            clearInterval(adm_docPollTimer);
            adm_docPollTimer = null;
            adm_docRunning = false;
            var btn = document.getElementById('adm-doc-run-btn');
            btn.disabled = false;
            btn.textContent = 'OK';
            btn.setAttribute('data-action-click', 'adm-close-docpipeline');
            var hasWarnings = results.some(function(r) { return r.status === 'warning'; });
            if (data.success && !hasWarnings) {
                st.textContent = 'All steps completed successfully';
                st.className = 'adm-doc-run-status adm-success';
            } else if (data.success && hasWarnings) {
                st.textContent = 'Completed with warnings';
                st.className = 'adm-doc-run-status adm-warning';
            } else {
                st.textContent = 'Pipeline completed with errors';
                st.className = 'adm-doc-run-status adm-error';
            }
            var res = document.getElementById('adm-doc-results');
            var html = '<div class="adm-doc-results-divider">Results</div>';
            results.forEach(function(r) {
                var ok = (r.status === 'success' || r.status === 'warning');
                var cls = r.status === 'warning' ? 'adm-warn' : (ok ? 'adm-ok' : 'adm-fail');
                var icon = r.status === 'warning' ? '\u26A0' : (ok ? '\u2713' : '\u2717');
                var openAttr = ok && r.status !== 'warning' ? '' : ' open';
                var outputText = '';
                if (r.output) {
                    if (typeof r.output === 'string') {
                        outputText = r.output.trim();
                    } else if (r.output.value && typeof r.output.value === 'string') {
                        outputText = r.output.value.trim();
                    }
                }
                var errorText = '';
                if (r.error) {
                    if (typeof r.error === 'string') {
                        errorText = r.error.trim();
                    } else if (r.error.value && typeof r.error.value === 'string') {
                        errorText = r.error.value.trim();
                    }
                }
                html += '<details class="adm-doc-detail ' + cls + '"' + openAttr + '>';
                html += '<summary>';
                html += '<span class="adm-doc-detail-arrow">\u25B6</span>';
                html += '<span class="adm-doc-detail-icon ' + cls + '">' + icon + '</span>';
                html += '<span class="adm-doc-detail-label">' + cc_escapeHtml(r.label) + '</span>';
                if (r.exit_code !== null && r.exit_code !== undefined) {
                    html += '<span class="adm-doc-detail-exit">exit ' + r.exit_code + '</span>';
                }
                html += '</summary>';
                if (outputText) {
                    html += '<pre class="adm-doc-detail-output">' + cc_escapeHtml(outputText) + '</pre>';
                }
                if (errorText) {
                    html += '<pre class="adm-doc-detail-error">' + cc_escapeHtml(errorText) + '</pre>';
                }
                html += '</details>';
            });
            res.innerHTML = html;
        }
    }).catch(function() {});
}

/* ============================================================================
   FUNCTIONS: ALERT FAILURES
   ----------------------------------------------------------------------------
   The Alert Failures slide-up and the card-badge count: loads the failure count
   for the badge, opens the panel and lists unresolved failures, and resends a
   failed alert with confirmation.
   Prefix: adm
   ============================================================================ */

/* Loads the unresolved failure count for the card badge. */
function adm_loadAlertFailureCount() {
    cc_engineFetch('/api/admin/alert-failure-count').then(function(data) {
        if (!data) {
            return;
        }
        if (data.Error) {
            return;
        }
        var badge = document.getElementById('adm-af-badge');
        var countEl = document.getElementById('adm-af-badge-count');
        if (!badge || !countEl) {
            return;
        }
        var count = data.count || 0;
        if (count > 0) {
            badge.className = 'adm-af-badge';
            countEl.textContent = count;
            countEl.classList.remove('adm-hidden');
        } else {
            badge.className = 'adm-af-badge adm-clean';
            countEl.textContent = '';
            countEl.classList.add('adm-hidden');
        }
    }).catch(function() {});
}

/* Opens the Alert Failures slide-up and loads the list. */
function adm_openAlertFailures() {
    adm_afOpen = true;
    document.getElementById('adm-af-body').innerHTML = '<div class="adm-loading">Loading...</div>';
    document.getElementById('adm-af-results-count').textContent = '';
    var overlay = document.getElementById('adm-slideup-alertfailures');
    var dialog = overlay.querySelector('.cc-dialog');
    overlay.classList.add('cc-open');
    requestAnimationFrame(function() {
        dialog.classList.add('cc-open');
    });
    adm_loadAlertFailures();
}

/* Closes the Alert Failures slide-up (backdrop-guarded). */
function adm_closeAlertFailures(target, event) {
    if (event && target.id === 'adm-slideup-alertfailures' && event.target !== target) {
        return;
    }
    adm_afOpen = false;
    var overlay = document.getElementById('adm-slideup-alertfailures');
    var dialog = overlay.querySelector('.cc-dialog');
    dialog.addEventListener('transitionend', function handler() {
        dialog.removeEventListener('transitionend', handler);
        overlay.classList.remove('cc-open');
    });
    dialog.classList.remove('cc-open');
}

/* Loads the list of unresolved alert failures. */
function adm_loadAlertFailures() {
    cc_engineFetch('/api/admin/alert-failures').then(function(data) {
        if (!data) {
            return;
        }
        if (data.Error) {
            document.getElementById('adm-af-body').innerHTML = '<div class="adm-af-load-error">' + cc_escapeHtml(data.Error) + '</div>';
            return;
        }
        adm_afData = Array.isArray(data) ? data : [];
        adm_renderAlertFailures();
    }).catch(function(e) {
        document.getElementById('adm-af-body').innerHTML = '<div class="adm-af-load-error">Failed to load: ' + cc_escapeHtml(e.message) + '</div>';
    });
}

/* Renders the alert-failure cards. */
function adm_renderAlertFailures() {
    var body = document.getElementById('adm-af-body');
    var countEl = document.getElementById('adm-af-results-count');
    if (adm_afData.length === 0) {
        countEl.textContent = '';
        body.innerHTML = '<div class="adm-af-empty"><div class="adm-af-empty-icon">&#10003;</div>No unresolved alert failures</div>';
        return;
    }
    countEl.textContent = adm_afData.length + ' failure' + (adm_afData.length !== 1 ? 's' : '');
    var html = '';
    adm_afData.forEach(function(a) {
        var catCls = (a.alert_category || '').toLowerCase();
        if (catCls !== 'critical' && catCls !== 'warning' && catCls !== 'info') {
            catCls = 'info';
        }
        html += '<div class="adm-af-card" id="adm-af-card-' + a.queue_id + '">';
        html += '<div class="adm-af-card-header">';
        html += '<span class="adm-af-module-badge">' + cc_escapeHtml(a.source_module) + '</span>';
        html += '<span class="adm-af-category-badge adm-' + catCls + '">' + cc_escapeHtml(a.alert_category) + '</span>';
        html += '<span class="adm-af-card-title" title="' + cc_escapeHtml(a.title) + '">' + cc_escapeHtml(a.title) + '</span>';
        html += '</div>';
        if (a.error_message && !(a.error_message instanceof Object)) {
            html += '<div class="adm-af-card-error">' + cc_escapeHtml(a.error_message) + '</div>';
        }
        html += '<div class="adm-af-card-footer">';
        html += '<div class="adm-af-card-meta">';
        html += '<span>Retries: ' + (a.retry_count || 0) + '</span>';
        html += '<span>' + adm_fmtTs(a.created_dttm) + '</span>';
        html += '</div>';
        html += '<button class="adm-af-resend-btn" id="adm-af-resend-' + a.queue_id + '" data-action-click="adm-resend-alert" data-action-adm-qid="' + a.queue_id + '">Resend</button>';
        html += '</div>';
        html += '</div>';
    });
    body.innerHTML = html;
}

/* Confirms then resends a failed alert. */
function adm_resendAlert(target) {
    var queueId = parseInt(target.getAttribute('data-action-adm-qid'), 10);
    var alertItem = null;
    var i;
    for (i = 0; i < adm_afData.length; i++) {
        if (adm_afData[i].queue_id === queueId) {
            alertItem = adm_afData[i];
            break;
        }
    }
    var alertTitle = alertItem ? alertItem.title : 'this alert';
    cc_showConfirm('Resend "' + alertTitle + '"? A new copy will be queued for delivery.', {
        title: 'Resend Alert',
        confirmLabel: 'Resend',
        confirmClass: 'cc-dialog-btn-primary'
    }).then(function(ok) {
        if (!ok) {
            return;
        }
        var btn = document.getElementById('adm-af-resend-' + queueId);
        if (btn) {
            btn.textContent = 'Pending\u2026';
            btn.className = 'adm-af-resend-btn adm-pending';
        }
        cc_engineFetch('/api/admin/alert-resend', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ queue_id: queueId })
        }).then(function(data) {
            if (!data) {
                return;
            }
            if (data.Error) {
                if (btn) {
                    btn.textContent = 'Resend';
                    btn.className = 'adm-af-resend-btn';
                }
                cc_showAlert(data.Error, { title: 'Resend Failed' });
                return;
            }
            adm_loadAlertFailureCount();
            if (adm_afOpen) {
                setTimeout(adm_loadAlertFailures, 600);
            }
        }).catch(function(e) {
            if (btn) {
                btn.textContent = 'Resend';
                btn.className = 'adm-af-resend-btn';
            }
            cc_showAlert(e.message, { title: 'Resend Failed' });
        });
    });
}

/* ============================================================================
   FUNCTIONS: INPUT MODAL
   ----------------------------------------------------------------------------
   The themed name-entry modal that replaces the native browser prompt. Opens
   with a title, hint, and default value; resolves the pending callback with the
   trimmed value on confirm.
   Prefix: adm
   ============================================================================ */

/* Opens the input modal with a title, hint, default value, and callback. */
function adm_showInputModal(title, hint, dv, cb) {
    adm_inputModalCallback = cb;
    document.getElementById('adm-input-modal-title').textContent = title;
    document.getElementById('adm-input-modal-hint').textContent = hint;
    var f = document.getElementById('adm-input-modal-field');
    f.value = dv || '';
    document.getElementById('adm-modal-input').classList.remove('cc-hidden');
    setTimeout(function() { f.focus(); }, 100);
}

/* Closes/cancels the input modal (backdrop-guarded). */
function adm_cancelInput(target, event) {
    if (event && target && target.id === 'adm-modal-input' && event.target !== target) {
        return;
    }
    document.getElementById('adm-modal-input').classList.add('cc-hidden');
    adm_inputModalCallback = null;
}

/* Confirms the input modal, invoking the callback with the trimmed value. */
function adm_confirmInput() {
    var v = document.getElementById('adm-input-modal-field').value;
    var cb = adm_inputModalCallback;
    adm_cancelInput();
    if (cb && v && v.trim()) {
        cb(v.trim());
    }
}

/* Keydown handler for the input field (Enter confirms). */
function adm_inputKeydown(target, event) {
    if (event.key === 'Enter') {
        adm_confirmInput();
    }
}

/* ============================================================================
   FUNCTIONS: LOG MODAL
   ----------------------------------------------------------------------------
   The task-log modal opened from a timeline bar click. Shows buffered output
   and error text across two tabs.
   Prefix: adm
   ============================================================================ */

/* Opens the log modal for a clicked task. */
function adm_openLogFromTask(task) {
    adm_logData.output = task.output_summary || null;
    adm_logData.error = task.error_output || null;
    document.getElementById('adm-log-modal-title').textContent = 'Task #' + task.task_id + '  \u2502  ' + adm_fmtTs(task.start_dttm) + '  \u2502  ' + (task.task_status || '?');
    var ot = document.getElementById('adm-log-tab-output');
    var et = document.getElementById('adm-log-tab-error');
    ot.className = 'adm-log-tab adm-active' + (adm_logData.output ? ' adm-has-content' : '');
    et.className = 'adm-log-tab' + (adm_logData.error ? ' adm-has-error' : '');
    adm_showLogContent('output');
    document.getElementById('adm-modal-log').classList.remove('cc-hidden');
}

/* Closes the log modal (backdrop-guarded). */
function adm_closeLog(target, event) {
    if (event && target && target.id === 'adm-modal-log' && event.target !== target) {
        return;
    }
    document.getElementById('adm-modal-log').classList.add('cc-hidden');
}

/* Switches the active log tab. */
function adm_switchLogTab(target) {
    var tab = target.getAttribute('data-action-adm-tab');
    document.getElementById('adm-log-tab-output').classList.toggle('adm-active', tab === 'output');
    document.getElementById('adm-log-tab-error').classList.toggle('adm-active', tab === 'error');
    adm_showLogContent(tab);
}

/* Renders the content for the active log tab. */
function adm_showLogContent(tab) {
    var el = document.getElementById('adm-log-content');
    var txt = tab === 'error' ? adm_logData.error : adm_logData.output;
    if (txt && txt.trim()) {
        el.textContent = txt;
        el.className = 'adm-log-content' + (tab === 'error' ? ' adm-error-text' : '');
    } else {
        el.textContent = tab === 'error' ? 'No error output' : 'No output captured';
        el.className = 'adm-log-content adm-empty';
    }
}

/* ============================================================================
   FUNCTIONS: FORMATTING
   ----------------------------------------------------------------------------
   Admin-specific date, time, and duration formatters used by the timeline,
   tooltip, history, and log views. These produce Admin's particular output
   shapes and have no shared-formatter equivalent.
   Prefix: adm
   ============================================================================ */

/* Parses a date value (ISO, .NET /Date(ms)/, or space-separated), or null. */
function adm_parseDate(v) {
    if (!v) {
        return null;
    }
    if (typeof v === 'string' && v.indexOf('/Date(') === 0) {
        var ms = parseInt(v.replace(/\/Date\((-?\d+)\)\//, '$1'), 10);
        return isNaN(ms) ? null : new Date(ms);
    }
    var d = new Date(v);
    if (isNaN(d.getTime())) {
        d = new Date(String(v).replace(' ', 'T'));
    }
    return isNaN(d.getTime()) ? null : d;
}

/* Formats a timestamp as "M/D h:mm:ssa". */
function adm_fmtTs(v) {
    var d = adm_parseDate(v);
    if (!d) {
        return '-';
    }
    return (d.getMonth() + 1) + '/' + d.getDate() + ' ' + adm_fmtT12(d);
}

/* Formats a Date as 12-hour "h:mm:ssa". */
function adm_fmtT12(d) {
    var h = d.getHours();
    var ap = h >= 12 ? 'p' : 'a';
    h = h % 12 || 12;
    var m = d.getMinutes();
    var s = d.getSeconds();
    return h + ':' + (m < 10 ? '0' : '') + m + ':' + (s < 10 ? '0' : '') + s + ap;
}

/* Formats a millisecond duration as a compact human string. */
function adm_fmtDur(ms) {
    if (ms === null || ms === undefined) {
        return '-';
    }
    if (ms < 1000) {
        return ms + 'ms';
    }
    if (ms < 60000) {
        return (ms / 1000).toFixed(1) + 's';
    }
    return Math.floor(ms / 60000) + 'm ' + Math.floor((ms % 60000) / 1000) + 's';
}

/* Formats a date as short "M/D/YY". */
function adm_fmtDateShort(v) {
    if (!v) {
        return '-';
    }
    var d = adm_parseDate(v);
    if (!d) {
        return '-';
    }
    return (d.getMonth() + 1) + '/' + d.getDate() + '/' + String(d.getFullYear()).slice(2);
}

/* Formats a signed countdown in seconds; overdue values are prefixed with +. */
function adm_fmtCd(s) {
    if (s === null) {
        return '';
    }
    var neg = s < 0;
    var a = Math.abs(Math.floor(s));
    var m = Math.floor(a / 60);
    var sec = a % 60;
    var d;
    if (m > 60) {
        var h = Math.floor(m / 60);
        d = h + 'h ' + (m % 60) + 'm';
    } else if (m > 0) {
        d = m + ':' + (sec < 10 ? '0' : '') + sec;
    } else {
        d = sec + 's';
    }
    return neg ? '+' + d : d;
}

/* Updates the chrome last-update timestamp. */
function adm_updateTs() {
    var el = document.getElementById('cc-last-update');
    if (!el) {
        return;
    }
    el.textContent = adm_fmtT12(new Date()).toUpperCase();
}

/* Returns the canvas color palette entry for a module. */
function adm_getModColor(m) {
    return adm_MODULE_COLORS[m] || adm_DEFAULT_COLOR;
}

/* ============================================================================
   FUNCTIONS: PAGE LIFECYCLE HOOKS
   ----------------------------------------------------------------------------
   Hooks resolved and invoked by cc-shared.js. The raw-event hook drives the
   timeline from every orchestrator event; the refresh and resume hooks reload
   page data; the session-expiry hook is a no-op because the page has no
   standalone polling beyond the shared transport.
   Prefix: adm
   ============================================================================ */

/* Raw engine-event hook: drives the timeline and sidebar from every event. */
function adm_onEngineEventRaw(event) {
    adm_handleEngineEvent(event);
}

/* Process-completed hook: unused (the raw hook handles all events). */
function adm_onEngineProcessCompleted(processName, event) {
    return;
}

/* Manual refresh hook: reloads all page data. */
function adm_onPageRefresh() {
    adm_loadDrainStatus();
    adm_loadProcessStatus();
    adm_loadTimelineData();
    adm_loadAlertFailureCount();
}

/* Tab-resume hook: reloads all page data. */
function adm_onPageResumed() {
    adm_onPageRefresh();
}

/* Session-expiry hook: no standalone polling to stop. */
function adm_onSessionExpired() {
    return;
}

/* ============================================================================
   xFACts Control Center - Applications & Integration Page (applications-integration.js)
   Location: E:\xFACts-ControlCenter\public\js\applications-integration.js
   Version: Tracked in dbo.System_Metadata (component: DeptOps.ApplicationsIntegration)

   Page module for the Applications & Integration departmental dashboard.
   Drives the two-tier BDL Catalog management dock (a bottom slide-up format
   list paired with a side detail panel) in both Global Configuration and
   Department Access modes, the page-local toggle and inline-edit controls,
   and the DM job trigger modals (Refresh Drools across all tools servers,
   plus single-server Release Notices and Balance Sync with cooldown checks)
   rendered as dynamic cc-dialog modals. All page-local actions route through
   per-event dispatch tables registered in aai_init.

   FILE ORGANIZATION
   -----------------
   CONSTANTS: ENVIRONMENTS
   CONSTANTS: SINGLE-SERVER JOBS
   CONSTANTS: DISPATCH TABLES
   STATE: CATALOG MODE
   STATE: CATALOG GLOBAL MODE
   STATE: CATALOG DEPARTMENT MODE
   STATE: DM JOB
   FUNCTIONS: INITIALIZATION
   FUNCTIONS: ACTION DISPATCH
   FUNCTIONS: CATALOG DOCK
   FUNCTIONS: CATALOG GLOBAL MODE
   FUNCTIONS: CATALOG DEPARTMENT MODE
   FUNCTIONS: CATALOG ELEMENT RENDERING
   FUNCTIONS: CATALOG INLINE EDIT
   FUNCTIONS: CATALOG STATUS
   FUNCTIONS: DM JOB MODAL SHELL
   FUNCTIONS: DM JOB ENVIRONMENT SELECTION
   FUNCTIONS: REFRESH DROOLS
   FUNCTIONS: SINGLE-SERVER JOB
   FUNCTIONS: DM JOB ENTRY POINTS
   FUNCTIONS: UTILITIES
   ============================================================================ */

/* ============================================================================
   CONSTANTS: ENVIRONMENTS
   ----------------------------------------------------------------------------
   The ordered set of target environments offered in every DM job trigger
   modal's environment-selection step.
   Prefix: aai
   ============================================================================ */

/* The target environments offered when launching a DM job. */
const aai_environments = ['TEST', 'STAGE', 'PROD'];

/* ============================================================================
   CONSTANTS: SINGLE-SERVER JOBS
   ----------------------------------------------------------------------------
   Configuration objects for the single-server DM jobs (Release Notices and
   Balance Sync). Each describes the job's modal id, display title, API
   endpoint, and the cooldown key used to look up its last execution.
   Prefix: aai
   ============================================================================ */

/* Configuration for the Release Notices single-server job. */
const aai_releaseNoticesJob = {
    modalId: 'aai-job-release-modal',
    title: 'Release Notices',
    apiEndpoint: '/api/apps-int/release-notices',
    cooldownKey: 'release_notices'
};

/* Configuration for the Balance Sync single-server job. */
const aai_balanceSyncJob = {
    modalId: 'aai-job-balance-modal',
    title: 'Balance Sync',
    apiEndpoint: '/api/apps-int/balance-sync',
    cooldownKey: 'balance_sync'
};

/* ============================================================================
   CONSTANTS: DISPATCH TABLES
   ----------------------------------------------------------------------------
   Per-event dispatch tables mapping this page's data-action-<event> values
   to handler functions. Registered as delegated listeners on document.body
   inside aai_init.
   Prefix: aai
   ============================================================================ */

/* Maps data-action-click values to their click handlers. */
const aai_clickActions = {
    'aai-open-catalog':          aai_openCatalog,
    'aai-close-catalog':         aai_closeCatalog,
    'aai-close-catalog-detail':  aai_closeCatalogDetail,
    'aai-set-mode':              aai_setModeFromAction,
    'aai-select-format':         aai_selectFormatFromAction,
    'aai-toggle-format':         aai_toggleFormatFromAction,
    'aai-select-dept-format':    aai_selectDeptFormatFromAction,
    'aai-toggle-dept-access':    aai_toggleDeptAccessFromAction,
    'aai-toggle-field':          aai_toggleFieldFromAction,
    'aai-toggle-dept-field':     aai_toggleDeptFieldFromAction,
    'aai-start-edit':            aai_startEditFromAction,
    'aai-save-field':            aai_saveFieldFromAction,
    'aai-cancel-edit':           aai_cancelEditFromAction,
    'aai-open-refresh-drools':   aai_openRefreshDrools,
    'aai-open-release-notices':  aai_openReleaseNotices,
    'aai-open-balance-sync':     aai_openBalanceSync,
    'aai-job-select-env':        aai_jobSelectEnvFromAction,
    'aai-job-confirm':           aai_jobConfirmFromAction,
    'aai-job-close-modal':       aai_jobCloseModalFromAction
};

/* Maps data-action-change values to their change handlers. */
const aai_changeActions = {
    'aai-select-department': aai_selectDepartmentFromAction
};

/* Maps data-action-keydown values to their keydown handlers. */
const aai_keydownActions = {
    'aai-edit-keydown': aai_editKeydownFromAction
};

/* ============================================================================
   STATE: CATALOG MODE
   ----------------------------------------------------------------------------
   The catalog's current mode and the in-flight inline edit, shared across
   both Global Configuration and Department Access views.
   Prefix: aai
   ============================================================================ */

/* The active catalog mode: 'global' or 'department'. */
var aai_mode = 'global';

/* The field currently being inline-edited (global mode), or null. */
var aai_editingField = null;

/* ============================================================================
   STATE: CATALOG GLOBAL MODE
   ----------------------------------------------------------------------------
   Loaded data and selection state for the Global Configuration view: the
   format list, the selected format's elements, and the current selection.
   Prefix: aai
   ============================================================================ */

/* The loaded BDL format rows for the global view. */
var aai_formats = [];

/* The element rows for the currently selected format. */
var aai_elements = [];

/* The format_id of the currently selected format, or null. */
var aai_selectedFormatId = null;

/* The display name of the currently selected format, or null. */
var aai_selectedFormatName = null;

/* ============================================================================
   STATE: CATALOG DEPARTMENT MODE
   ----------------------------------------------------------------------------
   Loaded data and selection state for the Department Access view: the
   department list, the selected department, its entity-access rows, the
   selected entity's field rows, and the related selection identifiers.
   Prefix: aai
   ============================================================================ */

/* The loaded department rows for the department selector. */
var aai_departments = [];

/* The department_key of the currently selected department, or null. */
var aai_selectedDepartment = null;

/* The display name of the currently selected department, or null. */
var aai_selectedDepartmentName = null;

/* The entity-access rows for the selected department. */
var aai_deptFormats = [];

/* The field-access rows for the selected entity. */
var aai_deptFields = [];

/* The format_id of the selected entity in department mode, or null. */
var aai_deptSelectedFormatId = null;

/* The entity_type of the selected entity in department mode, or null. */
var aai_deptSelectedEntityType = null;

/* The config_id of the selected entity's access config, or null. */
var aai_deptSelectedConfigId = null;

/* ============================================================================
   STATE: DM JOB
   ----------------------------------------------------------------------------
   The in-flight DM job context, carried across a job modal's environment
   selection, confirmation, and execution steps.
   Prefix: aai
   ============================================================================ */

/* The active DM job's runtime context for the open modal, or null. Holds the
   modal id, selected environment, server list, and (for single-server jobs)
   the job config and primary server. */
var aai_activeJob = null;

/* ============================================================================
   FUNCTIONS: INITIALIZATION
   ----------------------------------------------------------------------------
   The page boot function invoked by the cc-shared bootloader. Registers one
   delegated listener per event type whose dispatch table is non-empty.
   Prefix: aai
   ============================================================================ */

/* Boots the page: registers delegated listeners for the page's click,
   change, and keydown actions on document.body. */
function aai_init() {
    document.body.addEventListener('click', aai_handleClickAction);
    document.body.addEventListener('change', aai_handleChangeAction);
    document.body.addEventListener('keydown', aai_handleKeydownAction);
}

/* ============================================================================
   FUNCTIONS: ACTION DISPATCH
   ----------------------------------------------------------------------------
   Per-event delegated dispatchers. Each finds the nearest element carrying
   the relevant data-action attribute, ignores shared cc- actions (handled by
   cc-shared), and routes page-local actions to the matching handler.
   Prefix: aai
   ============================================================================ */

/* Routes a click to its handler via the aai_clickActions table. */
function aai_handleClickAction(event) {
    var target = event.target.closest('[data-action-click]');
    if (!target) return;
    var action = target.getAttribute('data-action-click');
    if (!action || action.indexOf('aai-') !== 0) return;
    var handler = aai_clickActions[action];
    if (handler) handler(target, event);
}

/* Routes a change to its handler via the aai_changeActions table. */
function aai_handleChangeAction(event) {
    var target = event.target.closest('[data-action-change]');
    if (!target) return;
    var action = target.getAttribute('data-action-change');
    if (!action || action.indexOf('aai-') !== 0) return;
    var handler = aai_changeActions[action];
    if (handler) handler(target, event);
}

/* Routes a keydown to its handler via the aai_keydownActions table. */
function aai_handleKeydownAction(event) {
    var target = event.target.closest('[data-action-keydown]');
    if (!target) return;
    var action = target.getAttribute('data-action-keydown');
    if (!action || action.indexOf('aai-') !== 0) return;
    var handler = aai_keydownActions[action];
    if (handler) handler(target, event);
}

/* ============================================================================
   FUNCTIONS: CATALOG DOCK
   ----------------------------------------------------------------------------
   Open and close handlers for the BDL Catalog dock and its side detail panel.
   The dock is a page-local slide-up construct toggled via the aai-visible
   state class.
   Prefix: aai
   ============================================================================ */

/* Opens the catalog dock in Global Configuration mode and loads formats. */
function aai_openCatalog() {
    aai_mode = 'global';
    aai_resetGlobalState();
    aai_resetDeptState();
    aai_hideDetail();

    document.getElementById('aai-catalog-backdrop').classList.add('aai-visible');
    document.getElementById('aai-catalog-panel').classList.add('aai-visible');
    document.getElementById('aai-catalog-body').innerHTML = '<div class="aai-catalog-loading">Loading BDL formats...</div>';
    document.getElementById('aai-catalog-count').textContent = '';
    document.getElementById('aai-catalog-title').textContent = 'BDL Content Management';

    aai_renderModeSelector();
    aai_loadFormats();
}

/* Closes the catalog dock and its detail panel. */
function aai_closeCatalog() {
    aai_hideDetail();
    document.getElementById('aai-catalog-backdrop').classList.remove('aai-visible');
    document.getElementById('aai-catalog-panel').classList.remove('aai-visible');
}

/* Closes only the side detail panel and clears the related selection. */
function aai_closeCatalogDetail() {
    aai_hideDetail();
    if (aai_mode === 'global') {
        aai_renderFormats();
    } else {
        aai_renderDeptFormats();
    }
}

/* Hides the detail panel and resets the per-mode detail selection state. */
function aai_hideDetail() {
    document.getElementById('aai-catalog-detail').classList.remove('aai-visible');
    if (aai_mode === 'global') {
        aai_selectedFormatId = null;
        aai_selectedFormatName = null;
        aai_editingField = null;
    } else {
        aai_deptSelectedFormatId = null;
        aai_deptSelectedEntityType = null;
        aai_deptSelectedConfigId = null;
    }
}

/* Clears all Global Configuration state. */
function aai_resetGlobalState() {
    aai_formats = [];
    aai_elements = [];
    aai_selectedFormatId = null;
    aai_selectedFormatName = null;
    aai_editingField = null;
}

/* Clears all Department Access state. */
function aai_resetDeptState() {
    aai_departments = [];
    aai_selectedDepartment = null;
    aai_selectedDepartmentName = null;
    aai_deptFormats = [];
    aai_deptFields = [];
    aai_deptSelectedFormatId = null;
    aai_deptSelectedEntityType = null;
    aai_deptSelectedConfigId = null;
}

/* Renders the mode tab bar and, in department mode, the department dropdown. */
function aai_renderModeSelector() {
    var container = document.getElementById('aai-catalog-mode-selector');
    if (!container) return;

    var globalCls = aai_mode === 'global' ? ' aai-active' : '';
    var deptCls = aai_mode === 'department' ? ' aai-active' : '';

    var html = '<div class="aai-catalog-mode-tabs">' +
        '<button class="aai-catalog-mode-tab' + globalCls + '" data-action-click="aai-set-mode" data-aai-mode="global">Global Configuration</button>' +
        '<button class="aai-catalog-mode-tab' + deptCls + '" data-action-click="aai-set-mode" data-aai-mode="department">Department Access</button>' +
        '</div>';

    if (aai_mode === 'department') {
        html += '<div class="aai-catalog-dept-selector">';
        html += '<select id="aai-catalog-dept-dropdown" class="aai-catalog-dept-dropdown" data-action-change="aai-select-department">';
        html += '<option value="">Select department...</option>';
        aai_departments.forEach(function (d) {
            var sel = d.department_key === aai_selectedDepartment ? ' selected' : '';
            html += '<option value="' + cc_escapeHtml(d.department_key) + '"' + sel + '>' + cc_escapeHtml(d.department_name) + '</option>';
        });
        html += '</select>';
        html += '</div>';
    }

    container.innerHTML = html;
}

/* Switches catalog mode from a mode tab click and loads that mode's data. */
function aai_setModeFromAction(target) {
    var newMode = target.getAttribute('data-aai-mode');
    if (newMode === aai_mode) return;
    aai_mode = newMode;
    aai_hideDetail();

    if (aai_mode === 'department') {
        document.getElementById('aai-catalog-body').innerHTML = '<div class="aai-catalog-loading">Loading departments...</div>';
        document.getElementById('aai-catalog-count').textContent = '';
        document.getElementById('aai-catalog-title').textContent = 'BDL Department Access';
        aai_loadDepartments();
    } else {
        document.getElementById('aai-catalog-title').textContent = 'BDL Content Management';
        document.getElementById('aai-catalog-body').innerHTML = '<div class="aai-catalog-loading">Loading BDL formats...</div>';
        document.getElementById('aai-catalog-count').textContent = '';
        aai_renderModeSelector();
        aai_loadFormats();
    }
}

/* ============================================================================
   FUNCTIONS: CATALOG GLOBAL MODE
   ----------------------------------------------------------------------------
   Global Configuration view: loads and renders the BDL format list, handles
   format selection and active-state toggles, and loads a selected format's
   element rows into the detail panel.
   Prefix: aai
   ============================================================================ */

/* Loads the BDL format list for the global view. */
function aai_loadFormats() {
    fetch('/api/apps-int/bdl-formats')
        .then(function (r) { return r.json(); })
        .then(function (data) {
            if (data.Error) {
                document.getElementById('aai-catalog-body').innerHTML = '<div class="aai-catalog-error">' + cc_escapeHtml(data.Error) + '</div>';
                return;
            }
            aai_formats = Array.isArray(data) ? data : [];
            aai_renderFormats();
        })
        .catch(function (e) {
            document.getElementById('aai-catalog-body').innerHTML = '<div class="aai-catalog-error">Failed to load: ' + cc_escapeHtml(e.message) + '</div>';
        });
}

/* Renders the format list, split into active and inactive entity groups. */
function aai_renderFormats() {
    var body = document.getElementById('aai-catalog-body');
    if (aai_formats.length === 0) {
        body.innerHTML = '<div class="aai-catalog-empty">No BDL formats found</div>';
        document.getElementById('aai-catalog-count').textContent = '';
        return;
    }

    var activeCount = 0, inactiveCount = 0;
    aai_formats.forEach(function (f) { if (f.is_active) activeCount++; else inactiveCount++; });
    document.getElementById('aai-catalog-count').textContent = activeCount + ' active' + (inactiveCount > 0 ? ', ' + inactiveCount + ' inactive' : '');

    var html = '';
    var active = aai_formats.filter(function (f) { return f.is_active; });
    var inactive = aai_formats.filter(function (f) { return !f.is_active; });

    if (active.length > 0) {
        html += '<div class="aai-catalog-section-label">Active Entity Types</div>';
        active.forEach(function (f) { html += aai_renderFormatRow(f); });
    }
    if (inactive.length > 0) {
        html += '<div class="aai-catalog-section-label aai-inactive">Inactive Entity Types</div>';
        inactive.forEach(function (f) { html += aai_renderFormatRow(f); });
    }

    body.innerHTML = html;
}

/* Builds the HTML for a single format row in the global view. */
function aai_renderFormatRow(f) {
    var isOn = f.is_active;
    var rowCls = 'aai-catalog-format-row' + (isOn ? '' : ' aai-inactive');
    var selectedCls = (aai_selectedFormatId === f.format_id) ? ' aai-selected' : '';
    var displayName = f.entity_type || f.type_name || '(unknown)';
    var isWrapper = !f.entity_type;
    var wrapperBadge = isWrapper ? ' <span class="aai-catalog-badge-wrapper" title="Container/UDP format -- no entity_type assigned">WRAPPER</span>' : '';
    var actionBadge = '';
    if (f.action_type && f.action_type !== 'FILE_MAPPED') {
        var badgeCls = f.action_type === 'FIXED_VALUE' ? 'aai-catalog-badge-fixed' : 'aai-catalog-badge-hybrid';
        actionBadge = ' <span class="' + badgeCls + '" title="Action type: ' + f.action_type + '">' + f.action_type.replace('_', ' ') + '</span>';
    }

    return '<div class="' + rowCls + selectedCls + '" data-aai-fid="' + f.format_id + '">' +
        '<div class="aai-catalog-format-main" data-action-click="aai-select-format" data-aai-format-id="' + f.format_id + '" data-aai-format-name="' + cc_escapeHtml(displayName) + '">' +
            '<span class="aai-catalog-format-name">' + cc_escapeHtml(displayName) + wrapperBadge + actionBadge + '</span>' +
            '<span class="aai-catalog-format-dots"></span>' +
            '<span class="aai-catalog-format-stats">' +
                '<span class="aai-catalog-stat" title="Visible fields">' + f.visible_count + ' vis</span>' +
                '<span class="aai-catalog-stat" title="Required fields">' + f.required_count + ' req</span>' +
                '<span class="aai-catalog-stat" title="Total elements">' + f.actual_element_count + ' total</span>' +
            '</span>' +
        '</div>' +
        '<span class="aai-catalog-format-toggle" data-action-click="aai-toggle-format" data-aai-format-id="' + f.format_id + '" data-aai-new-state="' + (isOn ? '0' : '1') + '" data-aai-format-name="' + cc_escapeHtml(displayName) + '">' +
            aai_renderToggleMarkup(isOn) +
        '</span>' +
    '</div>';
}

/* Selects a format from a row click, toggling the detail panel open or shut. */
function aai_selectFormatFromAction(target) {
    var formatId = parseInt(target.getAttribute('data-aai-format-id'), 10);
    var entityType = target.getAttribute('data-aai-format-name');

    if (aai_selectedFormatId === formatId) {
        aai_hideDetail();
        aai_renderFormats();
        return;
    }
    aai_selectedFormatId = formatId;
    aai_selectedFormatName = entityType;
    aai_editingField = null;
    aai_renderFormats();

    document.getElementById('aai-catalog-detail-title').textContent = entityType + ' -- Elements';
    document.getElementById('aai-catalog-detail-count').textContent = '';
    document.getElementById('aai-catalog-detail-body').innerHTML = '<div class="aai-catalog-loading">Loading elements...</div>';
    document.getElementById('aai-catalog-detail').classList.add('aai-visible');

    aai_loadElements(formatId);
}

/* Confirms and applies an entity active-state toggle from a toggle click. */
function aai_toggleFormatFromAction(target) {
    var formatId = parseInt(target.getAttribute('data-aai-format-id'), 10);
    var newState = parseInt(target.getAttribute('data-aai-new-state'), 10);
    var entityType = target.getAttribute('data-aai-format-name');

    var action = newState === 1 ? 'Activate' : 'Deactivate';
    var msg = action + ' ' + entityType + '? This will ' + (newState === 1 ? 'make it available' : 'hide it from') + ' BDL Import operations.';

    cc_showConfirm(msg, {
        title: action + ' Entity Type',
        confirmLabel: action,
        confirmClass: newState === 1 ? 'cc-dialog-btn-primary' : 'cc-dialog-btn-danger'
    }).then(function (confirmed) {
        if (!confirmed) return;
        fetch('/api/apps-int/bdl-format/toggle', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ format_id: formatId, is_active: newState })
        })
        .then(function (r) { return r.json(); })
        .then(function (data) {
            if (data.Error) {
                cc_showAlert(data.Error, { title: 'Error' });
                return;
            }
            for (var i = 0; i < aai_formats.length; i++) {
                if (aai_formats[i].format_id === formatId) {
                    aai_formats[i].is_active = newState === 1;
                    break;
                }
            }
            aai_renderFormats();
            aai_showStatus('aai-catalog-status', data.message, false);
        })
        .catch(function (e) {
            cc_showAlert(e.message, { title: 'Error' });
        });
    });
}

/* Loads the element rows for a selected format. */
function aai_loadElements(formatId) {
    fetch('/api/apps-int/bdl-elements?format_id=' + formatId)
        .then(function (r) { return r.json(); })
        .then(function (data) {
            if (data.Error) {
                document.getElementById('aai-catalog-detail-body').innerHTML = '<div class="aai-catalog-error">' + cc_escapeHtml(data.Error) + '</div>';
                return;
            }
            aai_elements = Array.isArray(data) ? data : [];
            aai_renderElements();
        })
        .catch(function (e) {
            document.getElementById('aai-catalog-detail-body').innerHTML = '<div class="aai-catalog-error">' + cc_escapeHtml(e.message) + '</div>';
        });
}

/* ============================================================================
   FUNCTIONS: CATALOG DEPARTMENT MODE
   ----------------------------------------------------------------------------
   Department Access view: loads departments and per-department entity access,
   handles department selection, entity-access grant/revoke toggles, entity
   selection into the detail panel, and field-access loading and toggles.
   Prefix: aai
   ============================================================================ */

/* Loads the department list for the department selector. */
function aai_loadDepartments() {
    fetch('/api/apps-int/departments')
        .then(function (r) { return r.json(); })
        .then(function (data) {
            if (data.Error) {
                document.getElementById('aai-catalog-body').innerHTML = '<div class="aai-catalog-error">' + cc_escapeHtml(data.Error) + '</div>';
                return;
            }
            aai_departments = Array.isArray(data) ? data : [];
            aai_renderModeSelector();
            if (aai_selectedDepartment) {
                aai_loadDepartmentAccess(aai_selectedDepartment);
            } else {
                document.getElementById('aai-catalog-body').innerHTML = '<div class="aai-catalog-empty">Select a department to manage BDL access</div>';
                document.getElementById('aai-catalog-count').textContent = '';
            }
        })
        .catch(function (e) {
            document.getElementById('aai-catalog-body').innerHTML = '<div class="aai-catalog-error">Failed to load departments: ' + cc_escapeHtml(e.message) + '</div>';
        });
}

/* Handles a department dropdown change: loads that department's access. */
function aai_selectDepartmentFromAction(target) {
    var deptKey = target.value;
    aai_hideDetail();
    if (!deptKey) {
        aai_selectedDepartment = null;
        aai_selectedDepartmentName = null;
        aai_deptFormats = [];
        document.getElementById('aai-catalog-body').innerHTML = '<div class="aai-catalog-empty">Select a department to manage BDL access</div>';
        document.getElementById('aai-catalog-count').textContent = '';
        return;
    }
    aai_selectedDepartment = deptKey;
    for (var i = 0; i < aai_departments.length; i++) {
        if (aai_departments[i].department_key === deptKey) {
            aai_selectedDepartmentName = aai_departments[i].department_name;
            break;
        }
    }
    document.getElementById('aai-catalog-body').innerHTML = '<div class="aai-catalog-loading">Loading access configuration...</div>';
    aai_loadDepartmentAccess(deptKey);
}

/* Loads the entity-access rows for a department. */
function aai_loadDepartmentAccess(deptKey) {
    fetch('/api/apps-int/bdl-access?department=' + encodeURIComponent(deptKey))
        .then(function (r) { return r.json(); })
        .then(function (data) {
            if (data.Error) {
                document.getElementById('aai-catalog-body').innerHTML = '<div class="aai-catalog-error">' + cc_escapeHtml(data.Error) + '</div>';
                return;
            }
            aai_deptFormats = Array.isArray(data) ? data : [];
            aai_renderDeptFormats();
        })
        .catch(function (e) {
            document.getElementById('aai-catalog-body').innerHTML = '<div class="aai-catalog-error">Failed to load access: ' + cc_escapeHtml(e.message) + '</div>';
        });
}

/* Renders the per-department entity-access list. */
function aai_renderDeptFormats() {
    var body = document.getElementById('aai-catalog-body');
    if (aai_deptFormats.length === 0) {
        body.innerHTML = '<div class="aai-catalog-empty">No active BDL entity types found</div>';
        document.getElementById('aai-catalog-count').textContent = '';
        return;
    }

    var grantedCount = 0;
    aai_deptFormats.forEach(function (f) { if (f.has_access) grantedCount++; });
    document.getElementById('aai-catalog-count').textContent = grantedCount + ' of ' + aai_deptFormats.length + ' granted';

    var html = '';
    aai_deptFormats.forEach(function (f) {
        var isOn = f.has_access;
        var rowCls = 'aai-catalog-format-row' + (isOn ? '' : ' aai-dept-ungranted');
        var selectedCls = (aai_deptSelectedFormatId === f.format_id) ? ' aai-selected' : '';
        var displayName = f.entity_type || f.type_name || '(unknown)';

        var actionBadge = '';
        if (f.action_type && f.action_type !== 'FILE_MAPPED') {
            var badgeCls = f.action_type === 'FIXED_VALUE' ? 'aai-catalog-badge-fixed' : 'aai-catalog-badge-hybrid';
            actionBadge = ' <span class="' + badgeCls + '">' + f.action_type.replace('_', ' ') + '</span>';
        }

        var fieldStats = '';
        if (isOn && f.config_id) {
            fieldStats = '<span class="aai-catalog-stat aai-dept-field-stat">' +
                (f.granted_field_count || 0) + ' of ' + (f.visible_field_count || 0) + ' fields' +
                '</span>';
        }

        html += '<div class="' + rowCls + selectedCls + '" data-aai-fid="' + f.format_id + '">' +
            '<div class="aai-catalog-format-main" data-action-click="aai-select-dept-format" data-aai-format-id="' + f.format_id + '" data-aai-entity-name="' + cc_escapeHtml(displayName) + '" data-aai-config-id="' + (f.config_id || '') + '">' +
                '<span class="aai-catalog-format-name">' + cc_escapeHtml(displayName) + actionBadge + '</span>' +
                '<span class="aai-catalog-format-dots"></span>' +
                fieldStats +
            '</div>' +
            '<span class="aai-catalog-format-toggle" data-action-click="aai-toggle-dept-access" data-aai-entity-type="' + cc_escapeHtml(f.entity_type) + '" data-aai-new-state="' + (isOn ? '0' : '1') + '" data-aai-entity-name="' + cc_escapeHtml(displayName) + '">' +
                aai_renderToggleMarkup(isOn) +
            '</span>' +
        '</div>';
    });

    body.innerHTML = html;
}

/* Confirms and applies a department entity-access grant or revoke. */
function aai_toggleDeptAccessFromAction(target) {
    if (!aai_selectedDepartment) return;
    var entityType = target.getAttribute('data-aai-entity-type');
    var newState = parseInt(target.getAttribute('data-aai-new-state'), 10);
    var entityName = target.getAttribute('data-aai-entity-name');

    var action = newState === 1 ? 'Grant' : 'Revoke';
    var msg = action + ' access to ' + entityName + ' for ' + aai_selectedDepartmentName + '?';

    cc_showConfirm(msg, {
        title: action + ' Entity Access',
        confirmLabel: action,
        confirmClass: newState === 1 ? 'cc-dialog-btn-primary' : 'cc-dialog-btn-danger'
    }).then(function (confirmed) {
        if (!confirmed) return;
        fetch('/api/apps-int/bdl-access/toggle', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ entity_type: entityType, department: aai_selectedDepartment, is_active: newState })
        })
        .then(function (r) { return r.json(); })
        .then(function (data) {
            if (data.Error) {
                cc_showAlert(data.Error, { title: 'Error' });
                return;
            }
            if (newState === 0) {
                for (var i = 0; i < aai_deptFormats.length; i++) {
                    if (aai_deptFormats[i].entity_type === entityType && aai_deptFormats[i].config_id === aai_deptSelectedConfigId) {
                        aai_hideDetail();
                        break;
                    }
                }
            }
            aai_loadDepartmentAccess(aai_selectedDepartment);
            aai_showStatus('aai-catalog-status', data.message, false);
        })
        .catch(function (e) {
            cc_showAlert(e.message, { title: 'Error' });
        });
    });
}

/* Selects a department entity into the detail panel for field management. */
function aai_selectDeptFormatFromAction(target) {
    var formatId = parseInt(target.getAttribute('data-aai-format-id'), 10);
    var entityType = target.getAttribute('data-aai-entity-name');
    var configIdRaw = target.getAttribute('data-aai-config-id');
    var configId = configIdRaw ? parseInt(configIdRaw, 10) : null;

    if (aai_deptSelectedFormatId === formatId) {
        aai_hideDetail();
        aai_renderDeptFormats();
        return;
    }

    if (!configId) {
        cc_showAlert('Grant entity access to this department before managing field permissions.', { title: 'Grant Access First' });
        return;
    }

    var fmt = null;
    for (var i = 0; i < aai_deptFormats.length; i++) {
        if (aai_deptFormats[i].format_id === formatId) { fmt = aai_deptFormats[i]; break; }
    }
    if (fmt && !fmt.has_access) {
        cc_showAlert('Grant entity access to this department before managing field permissions.', { title: 'Grant Access First' });
        return;
    }

    aai_deptSelectedFormatId = formatId;
    aai_deptSelectedEntityType = entityType;
    aai_deptSelectedConfigId = configId;
    aai_renderDeptFormats();

    document.getElementById('aai-catalog-detail-title').textContent = entityType + ' -- Field Access (' + aai_selectedDepartmentName + ')';
    document.getElementById('aai-catalog-detail-count').textContent = '';
    document.getElementById('aai-catalog-detail-body').innerHTML = '<div class="aai-catalog-loading">Loading fields...</div>';
    document.getElementById('aai-catalog-detail').classList.add('aai-visible');

    aai_loadDeptFieldAccess(configId);
}

/* Loads the field-access rows for a department entity config. */
function aai_loadDeptFieldAccess(configId) {
    fetch('/api/apps-int/bdl-field-access?config_id=' + configId)
        .then(function (r) { return r.json(); })
        .then(function (data) {
            if (data.Error) {
                document.getElementById('aai-catalog-detail-body').innerHTML = '<div class="aai-catalog-error">' + cc_escapeHtml(data.Error) + '</div>';
                return;
            }
            aai_deptFields = Array.isArray(data) ? data : [];
            aai_renderDeptFields();
        })
        .catch(function (e) {
            document.getElementById('aai-catalog-detail-body').innerHTML = '<div class="aai-catalog-error">' + cc_escapeHtml(e.message) + '</div>';
        });
}

/* Renders the field-access table for a department entity. */
function aai_renderDeptFields() {
    var body = document.getElementById('aai-catalog-detail-body');
    if (aai_deptFields.length === 0) {
        document.getElementById('aai-catalog-detail-count').textContent = '';
        body.innerHTML = '<div class="aai-catalog-empty">No visible fields found</div>';
        return;
    }

    var grantedCount = 0;
    aai_deptFields.forEach(function (f) { if (f.is_granted) grantedCount++; });
    document.getElementById('aai-catalog-detail-count').textContent = grantedCount + ' of ' + aai_deptFields.length + ' granted';

    var html = '<table class="aai-catalog-element-table"><thead><tr>' +
        '<th class="aai-catalog-element-th aai-th-name">Element Name</th>' +
        '<th class="aai-catalog-element-th aai-th-display">Display Name</th>' +
        '<th class="aai-catalog-element-th aai-th-toggle">Granted</th>' +
        '<th class="aai-catalog-element-th aai-th-desc">Description</th>' +
        '</tr></thead><tbody>';

    aai_deptFields.forEach(function (el) {
        var rowCls = el.is_granted ? 'aai-catalog-element-row' : 'aai-catalog-element-row aai-dimmed';
        html += '<tr class="' + rowCls + '">';
        html += '<td class="aai-catalog-element-td aai-catalog-cell-name">' + cc_escapeHtml(el.element_name);
        if (el.is_primary_id) html += ' <span class="aai-catalog-badge-pk" title="Primary identifier">PK</span>';
        if (el.lookup_table) html += ' <span class="aai-catalog-badge-lookup" title="Lookup: ' + cc_escapeHtml(el.lookup_table) + '">LK</span>';
        if (el.is_import_required) html += ' <span class="aai-catalog-badge-req" title="Import required">REQ</span>';
        html += '</td>';
        html += '<td class="aai-catalog-element-td aai-catalog-cell-display">' + (el.display_name ? cc_escapeHtml(el.display_name) : '<span class="aai-catalog-empty-val">(empty)</span>') + '</td>';
        html += '<td class="aai-catalog-element-td aai-catalog-cell-toggle">' +
            '<span class="aai-toggle-wrap" data-action-click="aai-toggle-dept-field" data-aai-element-name="' + cc_escapeHtml(el.element_name) + '" data-aai-new-state="' + (el.is_granted ? '0' : '1') + '">' +
                aai_renderToggleMarkup(el.is_granted) +
            '</span></td>';
        html += '<td class="aai-catalog-element-td aai-catalog-cell-desc">' + (el.field_description ? cc_escapeHtml(el.field_description) : '<span class="aai-catalog-empty-val">(empty)</span>') + '</td>';
        html += '</tr>';
    });

    html += '</tbody></table>';
    body.innerHTML = html;
}

/* Applies a department field-access grant or revoke from a toggle click. */
function aai_toggleDeptFieldFromAction(target) {
    if (!aai_deptSelectedConfigId) return;
    var elementName = target.getAttribute('data-aai-element-name');
    var newState = parseInt(target.getAttribute('data-aai-new-state'), 10);

    fetch('/api/apps-int/bdl-field-access/toggle', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ config_id: aai_deptSelectedConfigId, element_name: elementName, is_active: newState })
    })
    .then(function (r) { return r.json(); })
    .then(function (data) {
        if (data.Error) {
            cc_showAlert(data.Error, { title: 'Error' });
            return;
        }
        for (var i = 0; i < aai_deptFields.length; i++) {
            if (aai_deptFields[i].element_name === elementName) {
                aai_deptFields[i].is_granted = newState === 1;
                break;
            }
        }
        aai_renderDeptFields();
        aai_updateDeptFormatFieldCount();
        aai_showStatus('aai-catalog-detail-status', data.message, false);
    })
    .catch(function (e) {
        cc_showAlert(e.message, { title: 'Error' });
    });
}

/* Recomputes and re-renders the granted-field count for the selected entity. */
function aai_updateDeptFormatFieldCount() {
    if (!aai_deptSelectedConfigId) return;
    var grantedCount = 0;
    aai_deptFields.forEach(function (f) { if (f.is_granted) grantedCount++; });
    for (var i = 0; i < aai_deptFormats.length; i++) {
        if (aai_deptFormats[i].config_id === aai_deptSelectedConfigId) {
            aai_deptFormats[i].granted_field_count = grantedCount;
            break;
        }
    }
    aai_renderDeptFormats();
}

/* ============================================================================
   FUNCTIONS: CATALOG ELEMENT RENDERING
   ----------------------------------------------------------------------------
   Global-view element table rendering and the shared toggle-switch markup
   helper. The toggle helper emits the aai-on/aai-off state class on both the
   track and the knob so the knob's position is driven by its own state class.
   Prefix: aai
   ============================================================================ */

/* Renders the element table for the selected format in the global view. */
function aai_renderElements() {
    var body = document.getElementById('aai-catalog-detail-body');
    if (aai_elements.length === 0) {
        document.getElementById('aai-catalog-detail-count').textContent = '';
        body.innerHTML = '<div class="aai-catalog-empty">No elements found</div>';
        return;
    }

    var visCount = 0, reqCount = 0;
    aai_elements.forEach(function (el) {
        if (el.is_visible) visCount++;
        if (el.is_import_required) reqCount++;
    });
    document.getElementById('aai-catalog-detail-count').textContent = aai_elements.length + ' elements \u00B7 ' + visCount + ' visible \u00B7 ' + reqCount + ' required';

    var html = '<table class="aai-catalog-element-table"><thead><tr>' +
        '<th class="aai-catalog-element-th aai-th-name">Element Name</th>' +
        '<th class="aai-catalog-element-th aai-th-display">Display Name</th>' +
        '<th class="aai-catalog-element-th aai-th-toggle">Visible</th>' +
        '<th class="aai-catalog-element-th aai-th-toggle">Required</th>' +
        '<th class="aai-catalog-element-th aai-th-desc">Description</th>' +
        '<th class="aai-catalog-element-th aai-th-guidance">Import Guidance</th>' +
        '</tr></thead><tbody>';

    aai_elements.forEach(function (el) {
        var rowCls = el.is_visible ? 'aai-catalog-element-row' : 'aai-catalog-element-row aai-dimmed';
        html += '<tr class="' + rowCls + '" data-aai-eid="' + el.element_id + '">';
        html += '<td class="aai-catalog-element-td aai-catalog-cell-name">' + cc_escapeHtml(el.element_name);
        if (el.is_primary_id) html += ' <span class="aai-catalog-badge-pk" title="Primary identifier">PK</span>';
        if (el.lookup_table) html += ' <span class="aai-catalog-badge-lookup" title="Lookup: ' + cc_escapeHtml(el.lookup_table) + '">LK</span>';
        html += '</td>';
        html += '<td class="aai-catalog-element-td aai-catalog-cell-display">' + aai_renderEditableText(el, 'display_name', el.display_name) + '</td>';
        html += '<td class="aai-catalog-element-td aai-catalog-cell-toggle">' + aai_renderFieldToggle(el, 'is_visible', el.is_visible) + '</td>';
        html += '<td class="aai-catalog-element-td aai-catalog-cell-toggle">' + aai_renderFieldToggle(el, 'is_import_required', el.is_import_required) + '</td>';
        html += '<td class="aai-catalog-element-td aai-catalog-cell-desc">' + aai_renderEditableText(el, 'field_description', el.field_description) + '</td>';
        html += '<td class="aai-catalog-element-td aai-catalog-cell-guidance">' + aai_renderEditableText(el, 'import_guidance', el.import_guidance) + '</td>';
        html += '</tr>';
    });

    html += '</tbody></table>';
    body.innerHTML = html;
}

/* Builds the toggle-switch markup with state on both track and knob. */
function aai_renderToggleMarkup(isOn) {
    var stateCls = isOn ? 'aai-on' : 'aai-off';
    return '<span class="aai-toggle-track ' + stateCls + '"><span class="aai-toggle-knob ' + stateCls + '"></span></span>';
}

/* Builds a clickable field-toggle cell for an element in the global view. */
function aai_renderFieldToggle(el, fieldName, isOn) {
    return '<span class="aai-toggle-wrap" data-action-click="aai-toggle-field" data-aai-element-id="' + el.element_id + '" data-aai-field-name="' + fieldName + '" data-aai-new-state="' + (isOn ? '0' : '1') + '">' +
        aai_renderToggleMarkup(isOn) +
        '</span>';
}

/* ============================================================================
   FUNCTIONS: CATALOG INLINE EDIT
   ----------------------------------------------------------------------------
   The click-to-edit text controls in the global element table: rendering the
   editable display or active input, starting and cancelling an edit, saving
   on Enter or the save button, applying toggle and text updates, and the
   keydown handler that drives Enter/Escape behavior in the edit input.
   Prefix: aai
   ============================================================================ */

/* Renders either the editable text display or the active edit input. */
function aai_renderEditableText(el, fieldName, value) {
    var isEditing = aai_editingField && aai_editingField.elementId === el.element_id && aai_editingField.fieldName === fieldName;
    if (isEditing) {
        var inputVal = value ? cc_escapeHtml(value) : '';
        return '<span class="aai-edit-wrap">' +
            '<input type="text" class="aai-edit-input" id="aai-edit-' + el.element_id + '-' + fieldName + '" value="' + inputVal + '" ' +
            'data-action-keydown="aai-edit-keydown" data-aai-element-id="' + el.element_id + '" data-aai-field-name="' + fieldName + '">' +
            '<button class="aai-edit-save" data-action-click="aai-save-field" data-aai-element-id="' + el.element_id + '" data-aai-field-name="' + fieldName + '" title="Save">&#10003;</button>' +
            '<button class="aai-edit-cancel" data-action-click="aai-cancel-edit" title="Cancel">&#10007;</button>' +
            '</span>';
    }
    var displayVal = value ? cc_escapeHtml(value) : '<span class="aai-catalog-empty-val">(empty)</span>';
    return '<span class="aai-catalog-editable" data-action-click="aai-start-edit" data-aai-element-id="' + el.element_id + '" data-aai-field-name="' + fieldName + '" title="Click to edit">' + displayVal + '</span>';
}

/* Starts an inline edit and focuses the input. */
function aai_startEditFromAction(target) {
    var elementId = parseInt(target.getAttribute('data-aai-element-id'), 10);
    var fieldName = target.getAttribute('data-aai-field-name');
    aai_editingField = { elementId: elementId, fieldName: fieldName };
    aai_renderElements();
    var inp = document.getElementById('aai-edit-' + elementId + '-' + fieldName);
    if (inp) { inp.focus(); inp.select(); }
}

/* Cancels the active inline edit and re-renders. */
function aai_cancelEditFromAction() {
    aai_editingField = null;
    aai_renderElements();
}

/* Saves the active inline edit from the save button. */
function aai_saveFieldFromAction(target) {
    var elementId = parseInt(target.getAttribute('data-aai-element-id'), 10);
    var fieldName = target.getAttribute('data-aai-field-name');
    aai_saveField(elementId, fieldName);
}

/* Drives Enter (save) and Escape (cancel) behavior in the edit input. */
function aai_editKeydownFromAction(target, event) {
    if (event.key === 'Enter') {
        var elementId = parseInt(target.getAttribute('data-aai-element-id'), 10);
        var fieldName = target.getAttribute('data-aai-field-name');
        aai_saveField(elementId, fieldName);
    } else if (event.key === 'Escape') {
        aai_cancelEditFromAction();
    }
}

/* Reads the edit input, skips a no-op change, and applies the update. */
function aai_saveField(elementId, fieldName) {
    var inp = document.getElementById('aai-edit-' + elementId + '-' + fieldName);
    if (!inp) return;
    var newValue = inp.value.trim();
    var el = aai_findElement(elementId);
    if (!el) return;
    var currentValue = el[fieldName] || '';
    if (newValue === currentValue) { aai_cancelEditFromAction(); return; }
    aai_doUpdate(elementId, fieldName, newValue);
}

/* Applies an element field toggle from a toggle click. */
function aai_toggleFieldFromAction(target) {
    var elementId = parseInt(target.getAttribute('data-aai-element-id'), 10);
    var fieldName = target.getAttribute('data-aai-field-name');
    var newState = parseInt(target.getAttribute('data-aai-new-state'), 10);
    aai_doUpdate(elementId, fieldName, String(newState));
}

/* Posts an element field update and refreshes the affected rows. */
function aai_doUpdate(elementId, fieldName, newValue) {
    fetch('/api/apps-int/bdl-elements/update', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ element_id: elementId, field_name: fieldName, new_value: newValue })
    })
    .then(function (r) { return r.json(); })
    .then(function (data) {
        if (data.Error) {
            cc_showAlert(data.Error, { title: 'Error' });
            return;
        }
        var el = aai_findElement(elementId);
        if (el) {
            if (fieldName === 'is_visible' || fieldName === 'is_import_required') {
                el[fieldName] = parseInt(newValue, 10) === 1;
            } else {
                el[fieldName] = newValue || null;
            }
        }
        aai_editingField = null;
        aai_renderElements();
        aai_updateFormatCounts();
        aai_showStatus('aai-catalog-detail-status', data.message, false);
    })
    .catch(function (e) {
        cc_showAlert(e.message, { title: 'Error' });
    });
}

/* Recomputes and re-renders the visible/required counts for the format. */
function aai_updateFormatCounts() {
    if (!aai_selectedFormatId) return;
    var visCount = 0, reqCount = 0;
    aai_elements.forEach(function (el) {
        if (el.is_visible) visCount++;
        if (el.is_import_required) reqCount++;
    });
    for (var i = 0; i < aai_formats.length; i++) {
        if (aai_formats[i].format_id === aai_selectedFormatId) {
            aai_formats[i].visible_count = visCount;
            aai_formats[i].required_count = reqCount;
            break;
        }
    }
    aai_renderFormats();
}

/* Finds a loaded element row by its element_id. */
function aai_findElement(elementId) {
    for (var i = 0; i < aai_elements.length; i++) {
        if (aai_elements[i].element_id === elementId) return aai_elements[i];
    }
    return null;
}

/* ============================================================================
   FUNCTIONS: CATALOG STATUS
   ----------------------------------------------------------------------------
   The inline status line used by catalog edits, shown beneath the panel or
   detail header and auto-cleared after a short delay on success.
   Prefix: aai
   ============================================================================ */

/* Shows a success or error status message and auto-clears it on success. */
function aai_showStatus(elId, msg, isErr) {
    var el = document.getElementById(elId);
    if (!el) return;
    el.textContent = msg;
    var baseCls = elId === 'aai-catalog-detail-status' ? 'aai-catalog-detail-status' : 'aai-catalog-status';
    el.className = baseCls + ' ' + (isErr ? 'aai-error' : 'aai-success');
    if (!isErr) {
        setTimeout(function () {
            if (el) { el.textContent = ''; el.className = baseCls; }
        }, 3000);
    }
}

/* ============================================================================
   FUNCTIONS: DM JOB MODAL SHELL
   ----------------------------------------------------------------------------
   Open, reset, and close helpers for the statically-declared DM job modals.
   Each modal's overlay, dialog, and header are declared in the page route
   shell; these helpers toggle the cc-hidden state and repopulate the body and
   actions per step. The close handler dismisses on a backdrop click and on the
   close controls.
   Prefix: aai
   ============================================================================ */

/* Opens a statically-declared job modal and clears its body and actions. */
function aai_jobOpenModal(modalId) {
    var body = document.getElementById(modalId + '-body');
    var actions = document.getElementById(modalId + '-actions');
    if (body) body.innerHTML = '';
    if (actions) actions.innerHTML = '';
    document.getElementById(modalId).classList.remove('cc-hidden');
}

/* Hides a job modal and clears the active-job context. */
function aai_jobHideModal(modalId) {
    document.getElementById(modalId).classList.add('cc-hidden');
    aai_activeJob = null;
}

/* Closes a job modal from a backdrop or close-control click, ignoring clicks
   that bubble from the dialog interior. */
function aai_jobCloseModalFromAction(target, event) {
    var modalId = target.getAttribute('data-aai-modal-id');
    if (event && target.id === modalId && event.target !== target) {
        return;
    }
    aai_jobHideModal(modalId);
}

/* ============================================================================
   FUNCTIONS: DM JOB ENVIRONMENT SELECTION
   ----------------------------------------------------------------------------
   The first step of every DM job modal: the environment-selection buttons and
   the routing of a chosen environment into the job's next step.
   Prefix: aai
   ============================================================================ */

/* Renders the environment-selection buttons into a job modal. */
function aai_jobRenderEnvSelection(modalId) {
    var body = document.getElementById(modalId + '-body');
    var actions = document.getElementById(modalId + '-actions');

    var html = '<p class="aai-job-prompt">Select target environment:</p>';
    html += '<div class="aai-job-env-buttons">';
    aai_environments.forEach(function (env) {
        var cls = 'aai-job-env-btn aai-job-env-' + env.toLowerCase();
        html += '<button class="' + cls + '" data-action-click="aai-job-select-env" data-aai-modal-id="' + modalId + '" data-aai-env="' + env + '">' + env + '</button>';
    });
    html += '</div>';

    body.innerHTML = html;
    actions.innerHTML = '<button class="cc-dialog-btn-cancel" data-action-click="aai-job-close-modal" data-aai-modal-id="' + modalId + '">Cancel</button>';
}

/* Routes a chosen environment to the active job's confirmation step. */
function aai_jobSelectEnvFromAction(target) {
    var env = target.getAttribute('data-aai-env');
    if (!aai_activeJob) return;
    aai_activeJob.env = env;
    if (aai_activeJob.kind === 'drools') {
        aai_droolsLoadServersAndConfirm(env);
    } else {
        aai_singleServerLoadConfirm(env);
    }
}

/* Routes a confirm-button click to the active job's execution step. */
function aai_jobConfirmFromAction(target) {
    if (!aai_activeJob) return;
    var btn = document.getElementById(aai_activeJob.modalId + '-confirm');
    if (btn) { btn.disabled = true; btn.textContent = 'Executing...'; }
    var actions = document.getElementById(aai_activeJob.modalId + '-actions');
    if (actions) actions.innerHTML = '';
    if (aai_activeJob.kind === 'drools') {
        aai_droolsExecute(aai_activeJob.servers, aai_activeJob.env);
    } else {
        aai_singleServerRun(aai_activeJob.config, aai_activeJob.env, aai_activeJob.primaryServer);
    }
}

/* ============================================================================
   FUNCTIONS: REFRESH DROOLS
   ----------------------------------------------------------------------------
   The multi-server Refresh Drools flow: open the modal, load the environment's
   tools servers and present a confirmation, then execute the refresh on each
   server in sequence and render a roll-up summary.
   Prefix: aai
   ============================================================================ */

/* Opens the Refresh Drools modal at the environment-selection step. */
function aai_openRefreshDrools() {
    var modalId = 'aai-job-drools-modal';
    aai_jobOpenModal(modalId);
    aai_activeJob = { kind: 'drools', modalId: modalId, env: null, servers: [] };
    aai_jobRenderEnvSelection(modalId);
}

/* Loads the tools servers for the environment and renders the confirm step. */
function aai_droolsLoadServersAndConfirm(env) {
    var modalId = aai_activeJob.modalId;
    var body = document.getElementById(modalId + '-body');
    var actions = document.getElementById(modalId + '-actions');

    body.innerHTML = '<div class="aai-job-loading">Loading servers...</div>';
    actions.innerHTML = '';

    fetch('/api/apps-int/dm-servers?environment=' + encodeURIComponent(env))
        .then(function (r) { return r.json(); })
        .then(function (data) {
            if (data.Error) {
                aai_jobShowError(modalId, data.Error);
                return;
            }
            var servers = data.servers || [];
            if (servers.length === 0) {
                aai_jobShowNotice(modalId, 'No tools-enabled servers found for ' + cc_escapeHtml(env) + '.');
                return;
            }

            aai_activeJob.servers = servers;

            var html = '<p class="aai-job-confirm-text">Refresh business rules on all <strong class="aai-job-env-highlight aai-job-env-' + env.toLowerCase() + '">' + env + '</strong> app servers?</p>';
            html += '<div class="aai-job-server-list">';
            servers.forEach(function (s) {
                html += '<div class="aai-job-server-row"><span class="aai-job-server-name">' + cc_escapeHtml(s.server_name) + '</span><span class="aai-job-server-status aai-job-status-pending">Pending</span></div>';
            });
            html += '</div>';
            body.innerHTML = html;

            actions.innerHTML =
                '<button class="cc-dialog-btn-cancel" data-action-click="aai-job-close-modal" data-aai-modal-id="' + modalId + '">Cancel</button>' +
                '<button class="cc-dialog-btn-primary" id="' + modalId + '-confirm" data-action-click="aai-job-confirm">Refresh (' + servers.length + ' server' + (servers.length > 1 ? 's' : '') + ')</button>';
        })
        .catch(function (err) {
            aai_jobShowError(modalId, 'Failed to load servers: ' + err.message);
        });
}

/* Executes the Drools refresh, kicking off the per-server sequence. */
function aai_droolsExecute(servers, env) {
    var modalId = aai_activeJob.modalId;
    var body = document.getElementById(modalId + '-body');

    var html = '<p class="aai-job-running-text">Refreshing Drools on <strong>' + cc_escapeHtml(env) + '</strong>...</p>';
    html += '<div class="aai-job-server-list">';
    servers.forEach(function (s, idx) {
        html += '<div class="aai-job-server-row" id="aai-drools-srv-' + idx + '">' +
            '<span class="aai-job-server-name">' + cc_escapeHtml(s.server_name) + '</span>' +
            '<span class="aai-job-server-status aai-job-status-pending" id="aai-drools-status-' + idx + '">Pending</span>' +
        '</div>';
    });
    html += '</div>';
    html += '<div id="aai-drools-summary" class="aai-job-summary-slot"></div>';

    body.innerHTML = html;
    document.getElementById(modalId + '-actions').innerHTML = '';

    aai_droolsNextServer(servers, env, 0, []);
}

/* Refreshes Drools on a single server, then recurses to the next. */
function aai_droolsNextServer(servers, env, idx, results) {
    if (idx >= servers.length) {
        aai_droolsRenderSummary(results, env);
        return;
    }

    var server = servers[idx];
    var statusEl = document.getElementById('aai-drools-status-' + idx);
    if (statusEl) { statusEl.textContent = 'Executing...'; statusEl.className = 'aai-job-server-status aai-job-status-running'; }

    fetch('/api/apps-int/refresh-drools', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ environment: env, server_name: server.server_name, api_base_url: server.api_base_url })
    })
    .then(function (r) { return r.json().then(function (d) { d._httpStatus = r.status; return d; }); })
    .then(function (data) {
        var success = data._httpStatus < 400 && data.success;
        var dmInfo = data.dm_response ? aai_formatDmResponse(data.dm_response) : '';
        results.push({ server_name: server.server_name, success: success, message: success ? data.message : (data.error || data.Error || 'Unknown error'), dm_response: dmInfo });

        if (statusEl) {
            if (success) {
                statusEl.innerHTML = '&#10003; Success' + (dmInfo ? ' <span class="aai-job-dm-response">' + cc_escapeHtml(dmInfo) + '</span>' : '');
                statusEl.className = 'aai-job-server-status aai-job-status-success';
            } else {
                statusEl.innerHTML = '&#10006; Failed';
                statusEl.className = 'aai-job-server-status aai-job-status-failed';
            }
        }

        aai_droolsNextServer(servers, env, idx + 1, results);
    })
    .catch(function (err) {
        results.push({ server_name: server.server_name, success: false, message: err.message, dm_response: '' });
        if (statusEl) { statusEl.innerHTML = '&#10006; Error'; statusEl.className = 'aai-job-server-status aai-job-status-failed'; }
        aai_droolsNextServer(servers, env, idx + 1, results);
    });
}

/* Renders the Drools roll-up summary and a Close button. */
function aai_droolsRenderSummary(results, env) {
    var modalId = aai_activeJob ? aai_activeJob.modalId : 'aai-job-drools-modal';
    var summaryEl = document.getElementById('aai-drools-summary');
    var actions = document.getElementById(modalId + '-actions');

    var successCount = results.filter(function (r) { return r.success; }).length;
    var failCount = results.length - successCount;

    var html = '';
    if (failCount === 0) {
        html = '<div class="aai-job-summary-success">&#10003; Drools refreshed on all ' + results.length + ' server' + (results.length > 1 ? 's' : '') + ' (' + cc_escapeHtml(env) + ')</div>';
    } else if (successCount === 0) {
        html = '<div class="aai-job-summary-failed">&#10006; Refresh failed on all ' + results.length + ' server' + (results.length > 1 ? 's' : '') + '</div>';
    } else {
        html = '<div class="aai-job-summary-partial">&#9888; ' + successCount + ' succeeded, ' + failCount + ' failed</div>';
    }

    results.forEach(function (r) {
        if (!r.success) {
            html += '<div class="aai-job-error-detail"><strong>' + cc_escapeHtml(r.server_name) + ':</strong> ' + cc_escapeHtml(r.message) + '</div>';
        }
    });

    if (summaryEl) summaryEl.innerHTML = html;
    if (actions) actions.innerHTML = '<button class="cc-dialog-btn-primary" data-action-click="aai-job-close-modal" data-aai-modal-id="' + modalId + '">Close</button>';
}

/* ============================================================================
   FUNCTIONS: SINGLE-SERVER JOB
   ----------------------------------------------------------------------------
   The single-server job flow (Release Notices, Balance Sync): open the modal,
   check the cooldown and resolve the primary server, present a confirmation
   with any cooldown notice, then execute on the primary server and render the
   result.
   Prefix: aai
   ============================================================================ */

/* Opens a single-server job modal at the environment-selection step. */
function aai_openSingleServerJob(config) {
    aai_jobOpenModal(config.modalId);
    aai_activeJob = { kind: 'single', modalId: config.modalId, config: config, env: null, primaryServer: null };
    aai_jobRenderEnvSelection(config.modalId);
}

/* Loads the cooldown and server list, then renders the confirm step. */
function aai_singleServerLoadConfirm(env) {
    var config = aai_activeJob.config;
    var modalId = config.modalId;
    var body = document.getElementById(modalId + '-body');
    var actions = document.getElementById(modalId + '-actions');

    body.innerHTML = '<div class="aai-job-loading">Checking availability...</div>';
    actions.innerHTML = '';

    Promise.all([
        fetch('/api/apps-int/cooldown-check?job_name=' + encodeURIComponent(config.cooldownKey) + '&environment=' + encodeURIComponent(env)).then(function (r) { return r.json(); }),
        fetch('/api/apps-int/dm-servers?environment=' + encodeURIComponent(env)).then(function (r) { return r.json(); })
    ])
    .then(function (results) {
        var cooldown = results[0];
        var serverData = results[1];

        if (serverData.Error) {
            aai_jobShowError(modalId, serverData.Error);
            return;
        }
        var servers = serverData.servers || [];
        if (servers.length === 0) {
            aai_jobShowNotice(modalId, 'No tools-enabled servers found for ' + cc_escapeHtml(env) + '.');
            return;
        }

        var primaryServer = servers[0];
        aai_activeJob.primaryServer = primaryServer;

        var html = '<p class="aai-job-confirm-text">Execute <strong>' + cc_escapeHtml(config.title) + '</strong> on <strong class="aai-job-env-highlight aai-job-env-' + env.toLowerCase() + '">' + env + '</strong>?</p>';
        html += '<div class="aai-job-server-list">';
        html += '<div class="aai-job-server-row"><span class="aai-job-server-name">' + cc_escapeHtml(primaryServer.server_name) + '</span><span class="aai-job-server-status aai-job-status-primary">Primary</span></div>';
        html += '</div>';

        if (cooldown.cooldown_active) {
            var mins = Math.ceil(cooldown.seconds_remaining / 60);
            var lastUser = cooldown.last_executed_by || 'unknown';
            if (lastUser.indexOf('\\') !== -1) lastUser = lastUser.split('\\')[1];
            html += '<div class="aai-job-cooldown-active">';
            html += '<span class="aai-job-cooldown-icon">&#9202;</span> ';
            html += 'Last executed ' + aai_formatTimeAgo(cooldown.last_executed_at) + ' by <strong>' + cc_escapeHtml(lastUser) + '</strong>';
            html += '<br>Available in <strong>' + mins + ' minute' + (mins !== 1 ? 's' : '') + '</strong>';
            html += '</div>';
        } else if (cooldown.last_executed_at) {
            var lastUser2 = cooldown.last_executed_by || 'unknown';
            if (lastUser2.indexOf('\\') !== -1) lastUser2 = lastUser2.split('\\')[1];
            html += '<div class="aai-job-cooldown-clear">';
            html += 'Last executed ' + aai_formatTimeAgo(cooldown.last_executed_at) + ' by ' + cc_escapeHtml(lastUser2);
            html += '</div>';
        }

        body.innerHTML = html;

        if (cooldown.cooldown_active) {
            actions.innerHTML = '<button class="cc-dialog-btn-cancel" data-action-click="aai-job-close-modal" data-aai-modal-id="' + modalId + '">Close</button>' +
                '<button class="cc-dialog-btn-primary" disabled title="Cooldown active">Cooldown Active</button>';
        } else {
            actions.innerHTML = '<button class="cc-dialog-btn-cancel" data-action-click="aai-job-close-modal" data-aai-modal-id="' + modalId + '">Cancel</button>' +
                '<button class="cc-dialog-btn-primary" id="' + modalId + '-confirm" data-action-click="aai-job-confirm">Execute</button>';
        }
    })
    .catch(function (err) {
        aai_jobShowError(modalId, 'Failed: ' + err.message);
    });
}

/* Executes the single-server job and renders success or failure. */
function aai_singleServerRun(config, env, server) {
    var modalId = config.modalId;
    var body = document.getElementById(modalId + '-body');

    var html = '<p class="aai-job-running-text">Executing <strong>' + cc_escapeHtml(config.title) + '</strong> on <strong>' + cc_escapeHtml(env) + '</strong>...</p>';
    html += '<div class="aai-job-server-list">';
    html += '<div class="aai-job-server-row"><span class="aai-job-server-name">' + cc_escapeHtml(server.server_name) + '</span><span class="aai-job-server-status aai-job-status-running" id="aai-single-job-status">Executing...</span></div>';
    html += '</div>';
    html += '<div id="aai-single-job-summary" class="aai-job-summary-slot"></div>';

    body.innerHTML = html;

    fetch(config.apiEndpoint, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ environment: env })
    })
    .then(function (r) { return r.json().then(function (d) { d._httpStatus = r.status; return d; }); })
    .then(function (data) {
        var statusEl = document.getElementById('aai-single-job-status');
        var summaryEl = document.getElementById('aai-single-job-summary');
        var actions = document.getElementById(modalId + '-actions');
        var success = data._httpStatus < 400 && data.success;

        if (success) {
            var dmInfo = data.dm_response ? aai_formatDmResponse(data.dm_response) : '';
            if (statusEl) {
                statusEl.innerHTML = '&#10003; Success' + (dmInfo ? ' <span class="aai-job-dm-response">' + cc_escapeHtml(dmInfo) + '</span>' : '');
                statusEl.className = 'aai-job-server-status aai-job-status-success';
            }
            if (summaryEl) summaryEl.innerHTML = '<div class="aai-job-summary-success">&#10003; ' + cc_escapeHtml(config.title) + ' completed on ' + cc_escapeHtml(server.server_name) + ' (' + cc_escapeHtml(env) + ')</div>';
        } else {
            var errMsg = data.error || data.Error || 'Unknown error';
            if (statusEl) { statusEl.innerHTML = '&#10006; Failed'; statusEl.className = 'aai-job-server-status aai-job-status-failed'; }
            if (summaryEl) summaryEl.innerHTML = '<div class="aai-job-summary-failed">&#10006; ' + cc_escapeHtml(config.title) + ' failed</div><div class="aai-job-error-detail">' + cc_escapeHtml(errMsg) + '</div>';
        }

        if (actions) actions.innerHTML = '<button class="cc-dialog-btn-primary" data-action-click="aai-job-close-modal" data-aai-modal-id="' + modalId + '">Close</button>';
    })
    .catch(function (err) {
        var statusEl = document.getElementById('aai-single-job-status');
        var summaryEl = document.getElementById('aai-single-job-summary');
        var actions = document.getElementById(modalId + '-actions');
        if (statusEl) { statusEl.innerHTML = '&#10006; Error'; statusEl.className = 'aai-job-server-status aai-job-status-failed'; }
        if (summaryEl) summaryEl.innerHTML = '<div class="aai-job-summary-failed">&#10006; Request failed</div><div class="aai-job-error-detail">' + cc_escapeHtml(err.message) + '</div>';
        if (actions) actions.innerHTML = '<button class="cc-dialog-btn-primary" data-action-click="aai-job-close-modal" data-aai-modal-id="' + modalId + '">Close</button>';
    });
}

/* ============================================================================
   FUNCTIONS: DM JOB ENTRY POINTS
   ----------------------------------------------------------------------------
   The tool-card click handlers that open each DM job modal.
   Prefix: aai
   ============================================================================ */

/* Opens the Release Notices job modal. */
function aai_openReleaseNotices() {
    aai_openSingleServerJob(aai_releaseNoticesJob);
}

/* Opens the Balance Sync job modal. */
function aai_openBalanceSync() {
    aai_openSingleServerJob(aai_balanceSyncJob);
}

/* ============================================================================
   FUNCTIONS: UTILITIES
   ----------------------------------------------------------------------------
   Page-local helpers: relative time formatting for the cooldown display, the
   DM API response formatter, and the shared job-modal error and notice
   renderers.
   Prefix: aai
   ============================================================================ */

/* Formats a timestamp as a relative "time ago" string for cooldown display. */
function aai_formatTimeAgo(dateStr) {
    if (!dateStr) return 'unknown';
    var then = new Date(dateStr);
    var now = new Date();
    var diffMin = Math.floor((now - then) / 60000);
    if (diffMin < 1) return 'just now';
    if (diffMin < 60) return diffMin + ' min ago';
    var diffHrs = Math.floor(diffMin / 60);
    if (diffHrs < 24) return diffHrs + ' hr' + (diffHrs > 1 ? 's' : '') + ' ago';
    var diffDays = Math.floor(diffHrs / 24);
    return diffDays + ' day' + (diffDays > 1 ? 's' : '') + ' ago';
}

/* Formats a DM API JSON response into a short display string. */
function aai_formatDmResponse(dmResponse) {
    if (!dmResponse) return '';
    try {
        var parsed = JSON.parse(dmResponse);
        if (parsed.status && parsed.data) return 'DM: ' + parsed.data;
        return 'DM: ' + dmResponse;
    } catch (e) {
        return 'DM: ' + dmResponse;
    }
}

/* Renders an error message and a Close button into a job modal. */
function aai_jobShowError(modalId, message) {
    var body = document.getElementById(modalId + '-body');
    var actions = document.getElementById(modalId + '-actions');
    if (body) body.innerHTML = '<div class="aai-job-modal-error">' + cc_escapeHtml(message) + '</div>';
    if (actions) actions.innerHTML = '<button class="cc-dialog-btn-cancel" data-action-click="aai-job-close-modal" data-aai-modal-id="' + modalId + '">Close</button>';
}

/* Renders a neutral notice and a Close button into a job modal. */
function aai_jobShowNotice(modalId, message) {
    var body = document.getElementById(modalId + '-body');
    var actions = document.getElementById(modalId + '-actions');
    if (body) body.innerHTML = '<div class="aai-job-modal-notice">' + message + '</div>';
    if (actions) actions.innerHTML = '<button class="cc-dialog-btn-cancel" data-action-click="aai-job-close-modal" data-aai-modal-id="' + modalId + '">Close</button>';
}

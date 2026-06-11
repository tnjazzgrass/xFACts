/* ============================================================================
   xFACts Control Center - BDL Import (bdl-import.js)
   Location: E:\xFACts-ControlCenter\public\js\bdl-import.js
   Version: Tracked in dbo.System_Metadata (component: Tools.BDLImport)

   Client-side logic for the guided BDL Import wizard: a five-step flow
   (environment, file upload, entity selection, map and validate, execute)
   that parses a file in the browser, stages it server-side, validates and
   maps columns to BDL fields, previews the generated XML, executes the
   import into Debt Manager, and tracks import history with live polling.
   Boots via the cc-shared.js bootloader and routes all interaction through
   delegated data-action dispatch tables.

   FILE ORGANIZATION
   -----------------
   CONSTANTS: ACTION DISPATCH TABLES
   CONSTANTS: WIZARD CONFIGURATION
   CONSTANTS: COMPOSED MESSAGE BUILDER
   STATE: WIZARD FLOW
   STATE: FILE AND ENTITIES
   STATE: EXECUTION AND TEMPLATES
   STATE: PROMOTE TO PRODUCTION
   STATE: IMPORT HISTORY
   FUNCTIONS: INITIALIZATION
   FUNCTIONS: STAGING CLEANUP
   FUNCTIONS: STEP NAVIGATION
   FUNCTIONS: STEP 1 ENVIRONMENT
   FUNCTIONS: STEP 2 FILE UPLOAD
   FUNCTIONS: STEP 3 ENTITY SELECTION
   FUNCTIONS: PER-ENTITY STATE
   FUNCTIONS: STEP 4 MAPPING
   FUNCTIONS: STEP 4 ASSIGNMENT CARDS
   FUNCTIONS: STEP 4 FIELD ASSIGNMENTS
   FUNCTIONS: STEP 4 COMPOSED MESSAGE BUILDER
   FUNCTIONS: STEP 4 VALIDATION
   FUNCTIONS: STEP 5 EXECUTE
   FUNCTIONS: ALIGNMENT
   FUNCTIONS: PROMOTE TO PRODUCTION
   FUNCTIONS: TEMPLATES
   FUNCTIONS: IMPORT HISTORY
   FUNCTIONS: HELPERS
   FUNCTIONS: PAGE LIFECYCLE HOOKS
   ============================================================================ */

/* ============================================================================
   CONSTANTS: ACTION DISPATCH TABLES
   ----------------------------------------------------------------------------
   Per-event dispatch tables mapping data-action-<event> values declared in
   route markup and rendered HTML to their handler functions. The bdl_init
   function registers one delegated body listener per non-empty table.
   Prefix: bdl
   ============================================================================ */

/* Maps data-action-click values to their click handler functions. */
const bdl_clickActions = {
    'bdl-cleanup-run':              bdl_runCleanup,
    'bdl-step-goto':                bdl_goToStepAction,
    'bdl-step-back':                bdl_prevStep,
    'bdl-step-next':                bdl_nextStep,
    'bdl-env-select':               bdl_selectEnvironment,
    'bdl-prod-advisory-back':       bdl_closeProdAdvisory,
    'bdl-prod-advisory-continue':   bdl_prodAdvisoryContinue,
    'bdl-file-remove':              bdl_removeFile,
    'bdl-entity-toggle':            bdl_toggleEntity,
    'bdl-entity-field-info':        bdl_showFieldInfo,
    'bdl-field-info-close':         bdl_closeDynamicOverlay,
    'bdl-source-click':             bdl_sourceClick,
    'bdl-target-click':             bdl_targetClick,
    'bdl-unmap-pair':               bdl_unmapPair,
    'bdl-nullify-field':            bdl_nullifyField,
    'bdl-unnullify-field':          bdl_unnullifyField,
    'bdl-validate-entity':          bdl_validateCurrentEntity,
    'bdl-revalidate-entity':        bdl_revalidateCurrentEntity,
    'bdl-advance-entity':           bdl_advanceToNextEntity,
    'bdl-add-assignment':           bdl_addAssignment,
    'bdl-remove-assignment':        bdl_removeAssignment,
    'bdl-assignment-mode':          bdl_toggleAssignmentMode,
    'bdl-show-all-triggers':        bdl_showAllTriggerValues,
    'bdl-select-assignment-value':  bdl_selectAssignmentValue,
    'bdl-field-mode':               bdl_toggleFieldMode,
    'bdl-switch-field-mode':        bdl_switchFieldMode,
    'bdl-select-field-value':       bdl_selectFieldAssignmentValue,
    'bdl-select-field-cond-value':  bdl_selectFieldCondValue,
    'bdl-show-all-field-triggers':  bdl_showAllFieldTriggerValues,
    'bdl-cm-add-segment':           bdl_cmAddSegment,
    'bdl-cm-remove-segment':        bdl_cmRemoveSegment,
    'bdl-cm-segment-type':          bdl_cmSetSegmentType,
    'bdl-cond-skip':                bdl_condSkipToggle,
    'bdl-fa-cond-skip':             bdl_fieldCondSkipToggle,
    'bdl-apply-replacement':        bdl_applyReplacement,
    'bdl-fill-empty':               bdl_fillEmpty,
    'bdl-skip-rows':                bdl_skipRows,
    'bdl-toggle-validation-card':   bdl_toggleValidationCard,
    'bdl-toggle-info-card':         bdl_toggleInfoCard,
    'bdl-execute-tab':              bdl_switchExecuteTab,
    'bdl-preview-xml':              bdl_previewEntityXml,
    'bdl-copy-xml':                 bdl_copyEntityXml,
    'bdl-toggle-section':           bdl_toggleExecuteSection,
    'bdl-execute-all':              bdl_executeAll,
    'bdl-show-alignment':           bdl_showAlignmentModal,
    'bdl-alignment-close':          bdl_closeAlignment,
    'bdl-alignment-apply':          bdl_applyAlignment,
    'bdl-reset-alignment':          bdl_resetAlignment,
    'bdl-promote-card':             bdl_promoteCardClicked,
    'bdl-promote-advisory-back':    bdl_closePromoteAdvisory,
    'bdl-promote-advisory-go':      bdl_promoteAdvisoryContinue,
    'bdl-preview-template':         bdl_previewTemplate,
    'bdl-apply-template':           bdl_applyTemplate,
    'bdl-delete-template':          bdl_deleteTemplate,
    'bdl-template-preview-close':   bdl_closeTemplatePreview,
    'bdl-show-save-template':       bdl_showSaveTemplate,
    'bdl-save-template':            bdl_saveTemplate,
    'bdl-save-template-close':      bdl_closeSaveTemplate,
    'bdl-refresh-history':          bdl_refreshHistory,
    'bdl-history-env-filter':       bdl_setHistoryEnvFilter,
    'bdl-history-user-scope':       bdl_setHistoryUserScope,
    'bdl-toggle-history-year':      bdl_toggleHistoryYear,
    'bdl-toggle-history-month':     bdl_toggleHistoryMonth,
    'bdl-toggle-history-day':       bdl_toggleHistoryDay,
    'bdl-retry-import':             bdl_retryImportTrigger
};

/* Maps data-action-change values to their change handler functions. */
const bdl_changeActions = {
    'bdl-file-selected':              bdl_fileSelected,
    'bdl-identifier-changed':         bdl_identifierChanged,
    'bdl-fixed-identifier-changed':   bdl_fixedValueIdentifierChanged,
    'bdl-set-trigger-column':         bdl_setTriggerColumn,
    'bdl-set-assignment-file-column': bdl_setAssignmentFileColumn,
    'bdl-set-field-trigger-column':   bdl_setFieldTriggerColumn,
    'bdl-assignment-field-changed':   bdl_assignmentFieldChanged,
    'bdl-shared-field-changed':       bdl_sharedFieldChanged,
    'bdl-conditional-value-changed':  bdl_conditionalValueChanged,
    'bdl-field-assignment-changed':   bdl_fieldAssignmentValueChanged,
    'bdl-field-cond-value-changed':   bdl_fieldCondValueChanged,
    'bdl-ticket-changed':             bdl_ticketChanged,
    'bdl-cm-segment-field-changed':   bdl_cmSegmentFieldChanged,
    'bdl-cm-fallback-changed':        bdl_cmFallbackChanged
};

/* Maps data-action-input values to their input handler functions. */
const bdl_inputActions = {
    'bdl-assignment-field-search':  bdl_assignmentFieldSearch,
    'bdl-conditional-value-search': bdl_conditionalValueSearch,
    'bdl-field-assignment-search':  bdl_fieldAssignmentSearch,
    'bdl-field-cond-value-search':  bdl_fieldCondValueSearch,
    'bdl-cm-segment-text-input':    bdl_cmSegmentTextInput,
    'bdl-cm-fallback-input':        bdl_cmFallbackInput,
    'bdl-cm-segment-sep-input':     bdl_cmSegmentSepInput
};

/* ============================================================================
   CONSTANTS: WIZARD CONFIGURATION
   ----------------------------------------------------------------------------
   Immutable wizard configuration: total step count, the preview row cap, and
   the list of environments temporarily blocked from selection and filtering.
   Prefix: bdl
   ============================================================================ */

/* The total number of wizard steps. */
const bdl_TOTAL_STEPS = 5;

/* The maximum number of file rows rendered in the upload preview table. */
const bdl_MAX_PREVIEW_ROWS = 10;

/* Environments rendered grayed-out and non-selectable on Step 1 and in the
   history filter; used for temporary blocks during DM upgrades or
   maintenance windows. Remove an entry to re-enable that environment. */
const bdl_disabledEnvironments = ['STAGE'];

/* ============================================================================
   CONSTANTS: COMPOSED MESSAGE BUILDER
   ----------------------------------------------------------------------------
   Configuration for the AR Log message builder, a per-row message composer
   that replaces the normal mapping input for one field on one entity. The
   builder appears only when the selected entity and the target element both
   match the constants below; everywhere else the page is unchanged. Widening
   the builder to additional fields later is a matter of turning the element
   constant into a set and testing membership.
   Prefix: bdl
   ============================================================================ */

/* The entity type whose message field uses the composed-message builder. */
const bdl_COMPOSED_MESSAGE_ENTITY = 'CONSUMER_ACCOUNT_AR_LOG';

/* The element name the composed-message builder owns and fills per row. */
const bdl_COMPOSED_MESSAGE_ELEMENT = 'cnsmr_accnt_ar_mssg_txt';

/* The fallback text pre-filled in the builder, written to a row whose composed
   result is empty. Change this string to change the default fallback. */
const bdl_COMPOSED_MESSAGE_DEFAULT_FALLBACK = 'No message content provided.';

/* ============================================================================
   STATE: WIZARD FLOW
   ----------------------------------------------------------------------------
   Mutable state tracking the wizard's current position and per-step
   completion across the five-step flow.
   Prefix: bdl
   ============================================================================ */

/* The currently displayed wizard step (1-5). */
var bdl_currentStep = 1;

/* Per-step completion flags, indexed 0-4 for steps 1-5. */
var bdl_stepComplete = [false, false, false, false, false];

/* The selected environment object (config_id, environment, server). */
var bdl_selectedEnvironment = null;

/* The config_id of a PROD selection pending advisory confirmation. */
var bdl_pendingProdConfigId = null;

/* ============================================================================
   STATE: FILE AND ENTITIES
   ----------------------------------------------------------------------------
   Mutable state for the uploaded file, its parsed preview data, the available
   and selected entity types, and the per-entity processing states.
   Prefix: bdl
   ============================================================================ */

/* The raw uploaded File object pending parse and staging. */
var bdl_uploadedFile = null;

/* Parsed file preview data: headers, sample rows, and total row count. */
var bdl_parsedFileData = null;

/* All entity types available to the user, loaded from the API. */
var bdl_allEntities = [];

/* The environment list loaded from the API, used to resolve a card's config. */
var bdl_envData = [];

/* The entity types the user has selected for import. */
var bdl_selectedEntities = [];

/* Per-entity processing state objects, one per selected entity. */
var bdl_entityStates = [];

/* The index into bdl_entityStates of the entity currently being mapped. */
var bdl_currentEntityIndex = 0;

/* Whether a re-validation pass is currently in flight. */
var bdl_revalidating = false;

/* Debounce timer handle for lookup-search typeahead requests. */
var bdl_searchDebounceTimer = null;

/* ============================================================================
   STATE: EXECUTION AND TEMPLATES
   ----------------------------------------------------------------------------
   Mutable state for the execute phase (in-progress flag and per-entity result
   tracking) and the saved mapping templates for the current entity.
   Prefix: bdl
   ============================================================================ */

/* Whether an execute pass is currently running. */
var bdl_executeInProgress = false;

/* Per-entity execution result records accumulated during a run. */
var bdl_executeResultTracker = [];

/* Saved mapping templates for the current entity type. */
var bdl_entityTemplates = [];

/* The template_id of the currently applied template, or null. */
var bdl_activeTemplateId = null;

/* Whether the current user may delete templates (server-computed). */
var bdl_templateCanDelete = false;

/* ============================================================================
   STATE: PROMOTE TO PRODUCTION
   ----------------------------------------------------------------------------
   Mutable state for the promote-to-production flow shown after a successful
   TEST/STAGE import: the source data, countdown timer, and ready flag.
   Prefix: bdl
   ============================================================================ */

/* The promote source data (entity results and source environment). */
var bdl_promoteData = null;

/* The setInterval handle for the promote cooldown countdown. */
var bdl_promoteCountdownTimer = null;

/* Seconds remaining on the promote cooldown countdown. */
var bdl_promoteSecondsRemaining = 0;

/* Whether the promote card has become ready (cooldown elapsed). */
var bdl_promoteReady = false;

/* The PROD config_id pending promote-advisory confirmation. */
var bdl_pendingPromoteConfigId = null;

/* ============================================================================
   STATE: IMPORT HISTORY
   ----------------------------------------------------------------------------
   Mutable state for the live-polling import-history panel: the loaded data,
   active filters, polling timers, accordion expansion sets, and the per-month
   detail cache.
   Prefix: bdl
   ============================================================================ */

/* The loaded import-history payload (active rows plus the year tree). */
var bdl_historyData = null;

/* The active environment filter ('ALL', 'TEST', 'STAGE', 'PROD'). */
var bdl_historyEnvFilter = 'ALL';

/* The active user scope ('me' or 'all'). */
var bdl_historyUserScope = 'me';

/* The setInterval handle for live history polling. */
var bdl_historyPollTimer = null;

/* The history polling interval in seconds. */
var bdl_historyPollInterval = 20;

/* Expansion-state set for history year nodes, keyed by year. */
var bdl_historyExpandedYears = {};

/* Expansion-state set for history month nodes, keyed by year-month. */
var bdl_historyExpandedMonths = {};

/* Expansion-state set for history day nodes, keyed by date. */
var bdl_historyExpandedDays = {};

/* Per-month loaded detail cache, keyed by year-month. */
var bdl_historyMonthCache = {};

/* The current user's username, used by the Mine/All Users scope filter. */
var bdl_historyCurrentUser = null;

/* The set of environments present in the loaded history (for chip rendering). */
var bdl_historyAvailableEnvs = [];

/* Timestamp (ms) of the last history load, for the last-updated display. */
var bdl_historyLastLoadMs = 0;

/* The date string captured at page load, used for midnight-rollover detection. */
var bdl_pageLoadDate = new Date().toDateString();

/* The setInterval handle for the midnight-rollover check. */
var bdl_midnightCheckTimer = null;

/* ============================================================================
   FUNCTIONS: INITIALIZATION
   ----------------------------------------------------------------------------
   The page boot function invoked by the cc-shared.js bootloader. Registers
   the delegated action listeners, binds the drag-and-drop handlers on their
   stable parents, and kicks off the initial environment, cleanup, and
   history loads.
   Prefix: bdl
   ============================================================================ */

/* Boots the BDL Import page: wires delegated dispatchers and drag handlers,
   then loads environments, checks for stale staging tables, and starts the
   import-history panel. */
function bdl_init() {
    document.body.addEventListener('click', function(event) {
        bdl_dispatch(bdl_clickActions, 'click', event);
    });
    document.body.addEventListener('change', function(event) {
        bdl_dispatch(bdl_changeActions, 'change', event);
    });
    document.body.addEventListener('input', function(event) {
        bdl_dispatch(bdl_inputActions, 'input', event);
    });
    bdl_bindDragAndDrop();
    cc_connectEngineEvents();
    bdl_loadEnvironments();
    bdl_checkStagingCleanup();
    bdl_initHistoryPanel();
}

/* ============================================================================
   FUNCTIONS: STAGING CLEANUP
   ----------------------------------------------------------------------------
   The dispatcher used by the delegated listeners, plus the drag-and-drop
   binding and the stale-staging-table detection and cleanup flow shown in
   the connection-banner slot at the top of the page.
   Prefix: bdl
   ============================================================================ */

/* Routes a fired event to its handler by reading the element's
   data-action-<event> value and looking it up in the supplied table. */
function bdl_dispatch(table, eventName, event) {
    var attr = 'data-action-' + eventName;
    var el = event.target.closest('[' + attr + ']');
    if (!el) {
        return;
    }
    var action = el.getAttribute(attr);
    var handler = table[action];
    if (handler) {
        handler(el, event);
    }
}

/* Binds the drag-and-drop handlers for the upload zone and the mapping
   panels on their stable parents. Drag events are outside the recognized
   data-action event set, so they are delegated directly here at boot. */
function bdl_bindDragAndDrop() {
    var zone = document.getElementById('bdl-upload-zone');
    if (zone) {
        zone.addEventListener('dragover', bdl_dragOver);
        zone.addEventListener('dragleave', bdl_dragLeave);
        zone.addEventListener('drop', bdl_fileDrop);
    }
    var area = document.getElementById('bdl-map-validate-area');
    if (area) {
        area.addEventListener('dragstart', bdl_chipDragStart);
        area.addEventListener('dragover', bdl_chipDragOver);
        area.addEventListener('drop', bdl_chipDrop);
    }
}

/* Reads the file input's selected file when the browse control changes. */
function bdl_fileSelected(target) {
    if (target.files.length > 0) {
        bdl_handleFile(target.files[0]);
    }
}

/* Checks for expired staging tables and shows a cleanup banner if any exist. */
function bdl_checkStagingCleanup() {
    fetch('/api/bdl-import/staging-cleanup').then(function(r) {
        return r.json();
    }).then(function(data) {
        var tables = data.expired_tables || [];
        if (tables.length > 0) {
            var banner = document.getElementById('bdl-connection-error');
            banner.classList.remove('bdl-hidden');
            banner.className = 'bdl-cleanup-banner';
            banner.innerHTML = '<span class="bdl-cleanup-text">' + tables.length +
                ' expired staging table(s) found (older than 48 hours)</span>' +
                '<button class="bdl-cleanup-btn" data-action-click="bdl-cleanup-run">Clean Up</button>';
        }
    }).catch(function() {});
}

/* Runs staging cleanup, dropping expired tables and reporting the result. */
function bdl_runCleanup() {
    var banner = document.getElementById('bdl-connection-error');
    banner.innerHTML = '<span class="bdl-cleanup-text">Cleaning up...</span>';
    fetch('/api/bdl-import/staging-cleanup', { method: 'POST' }).then(function(r) {
        return r.json();
    }).then(function(data) {
        banner.innerHTML = '<span class="bdl-cleanup-text">' + (data.dropped || []).length +
            ' table(s) removed</span>';
        setTimeout(function() {
            banner.classList.add('bdl-hidden');
            banner.className = 'bdl-connection-error bdl-hidden';
        }, 3000);
    }).catch(function(err) {
        banner.innerHTML = '<span class="bdl-cleanup-text bdl-inline-error">Cleanup failed: ' +
            err.message + '</span>';
    });
}

/* ============================================================================
   FUNCTIONS: STEP NAVIGATION
   ----------------------------------------------------------------------------
   Movement between the five wizard steps: the stepper indicators, the
   Back/Next buttons, the contextual guide panel, the environment badge, and
   the reset cascade that clears downstream state when an earlier step
   changes.
   Prefix: bdl
   ============================================================================ */

/* Handles a stepper indicator click, jumping to the chosen step if allowed. */
function bdl_goToStepAction(target) {
    var step = parseInt(target.getAttribute('data-action-bdl-step'), 10);
    bdl_goToStep(step);
}

/* Jumps to a step if it is the current step, a completed step, or reachable. */
function bdl_goToStep(step) {
    if (step > bdl_currentStep ||
        (step < bdl_currentStep && !bdl_stepComplete[step - 1] && step !== bdl_currentStep)) {
        return;
    }
    bdl_showStep(step);
}

/* Advances to the next step, running the per-step transition work. */
function bdl_nextStep() {
    if (bdl_currentStep < bdl_TOTAL_STEPS && bdl_stepComplete[bdl_currentStep - 1]) {
        if (bdl_currentStep === 3) {
            bdl_initEntityStates();
            bdl_currentEntityIndex = 0;
            bdl_loadCurrentEntityFields(function() {
                bdl_showStep(4);
                bdl_renderMapValidatePanel();
            });
            return;
        }
        if (bdl_currentStep === 4) {
            var state = bdl_curState();
            if (state && state.nullifyFields && state.nullifyFields.length > 0 && state.stagingContext) {
                bdl_persistNullifyFields(state, function() {
                    bdl_showStep(5);
                    bdl_renderExecuteReview();
                });
            } else {
                bdl_showStep(5);
                bdl_renderExecuteReview();
            }
            return;
        }
        bdl_showStep(bdl_currentStep + 1);
    }
}

/* Moves to the previous step or the previous entity within Step 4. */
function bdl_prevStep() {
    if (bdl_currentStep === 4 && bdl_currentEntityIndex > 0) {
        bdl_currentEntityIndex--;
        bdl_loadCurrentEntityFields(function() {
            bdl_renderMapValidatePanel();
        });
        return;
    }
    if (bdl_currentStep > 1) {
        bdl_showStep(bdl_currentStep - 1);
    }
}

/* Switches the visible step panel and refreshes the stepper, guide, and nav. */
function bdl_showStep(step) {
    var i;
    for (i = 1; i <= bdl_TOTAL_STEPS; i++) {
        var p = document.getElementById('bdl-panel-' + i);
        var ind = document.getElementById('bdl-step-ind-' + i);
        if (p) {
            p.classList.remove('bdl-active');
        }
        if (ind) {
            ind.classList.remove('bdl-active');
        }
    }
    var tp = document.getElementById('bdl-panel-' + step);
    var ti = document.getElementById('bdl-step-ind-' + step);
    if (tp) {
        tp.classList.add('bdl-active');
    }
    if (ti) {
        ti.classList.add('bdl-active');
    }
    bdl_currentStep = step;
    bdl_updateGuidePanel();
    bdl_updateStepperUI();
    bdl_updateNavButtons();
    if (step === 3 && bdl_allEntities.length === 0) {
        bdl_loadEntities();
    }
}

/* Refreshes the stepper indicators, number badges, and connectors to reflect
   current and completed steps. */
function bdl_updateStepperUI() {
    var i;
    for (i = 1; i <= bdl_TOTAL_STEPS; i++) {
        var ind = document.getElementById('bdl-step-ind-' + i);
        var num = document.getElementById('bdl-step-num-' + i);
        var conn = document.getElementById('bdl-conn-' + i);
        if (!ind) {
            continue;
        }
        ind.classList.remove('bdl-completed', 'bdl-active');
        if (num) {
            num.classList.remove('bdl-completed', 'bdl-active');
        }
        if (bdl_stepComplete[i - 1] && i !== bdl_currentStep) {
            ind.classList.add('bdl-completed');
            if (num) {
                num.classList.add('bdl-completed');
                num.innerHTML = '&#10003;';
            }
        } else if (i === bdl_currentStep) {
            ind.classList.add('bdl-active');
            if (num) {
                num.classList.add('bdl-active');
                num.textContent = i;
            }
        } else {
            if (num) {
                num.textContent = i;
            }
        }
        var label = document.getElementById('bdl-step-label-' + i);
        if (label) {
            label.classList.remove('bdl-completed', 'bdl-active');
            if (bdl_stepComplete[i - 1] && i !== bdl_currentStep) {
                label.classList.add('bdl-completed');
            } else if (i === bdl_currentStep) {
                label.classList.add('bdl-active');
            }
        }
        if (conn) {
            if (bdl_stepComplete[i - 1]) {
                conn.classList.add('bdl-completed');
            } else {
                conn.classList.remove('bdl-completed');
            }
        }
    }
}

/* Shows the guide block for the current step and hides the others. */
function bdl_updateGuidePanel() {
    var g;
    for (g = 1; g <= bdl_TOTAL_STEPS; g++) {
        var gt = document.getElementById('bdl-guide-text-' + g);
        if (gt) {
            if (g === bdl_currentStep) {
                gt.classList.remove('bdl-hidden');
            } else {
                gt.classList.add('bdl-hidden');
            }
        }
    }
    bdl_updateTemplateSectionState();
}

/* Enables/disables and shows/hides the Back and Next buttons for the step. */
function bdl_updateNavButtons() {
    var back = document.getElementById('bdl-btn-back');
    var next = document.getElementById('bdl-btn-next');
    if (bdl_currentStep === 1) {
        back.disabled = true;
    } else if (bdl_currentStep === 4 && bdl_currentEntityIndex > 0) {
        back.disabled = false;
    } else {
        back.disabled = (bdl_currentStep === 1);
    }
    bdl_setEnabledClass(back, !back.disabled);
    if (bdl_currentStep === 5 && bdl_stepComplete[4]) {
        back.classList.add('bdl-hidden');
    } else {
        back.classList.remove('bdl-hidden');
    }
    if (bdl_currentStep === 5) {
        next.classList.add('bdl-hidden');
    } else {
        next.classList.remove('bdl-hidden');
        next.disabled = !bdl_stepComplete[bdl_currentStep - 1];
        next.innerHTML = 'Next &#8594;';
        bdl_setEnabledClass(next, !next.disabled);
    }
}

/* Toggles the bdl-enabled state class in step with a button's enabled flag. */
function bdl_setEnabledClass(button, isEnabled) {
    if (!button) {
        return;
    }
    if (isEnabled) {
        button.classList.add('bdl-enabled');
    } else {
        button.classList.remove('bdl-enabled');
    }
}

/* Updates the environment badge in the stepper to match the selection. */
function bdl_updateEnvBadge() {
    var badge = document.getElementById('bdl-env-badge');
    if (!badge) {
        return;
    }
    if (!bdl_selectedEnvironment) {
        badge.className = 'bdl-env-badge bdl-hidden';
        badge.textContent = '';
        return;
    }
    badge.textContent = bdl_selectedEnvironment.environment;
    badge.className = 'bdl-env-badge bdl-env-badge-' +
        bdl_selectedEnvironment.environment.toLowerCase();
}

/* Clears completion and downstream state from the given step onward. */
function bdl_resetFromStep(step) {
    var i;
    for (i = step; i <= bdl_TOTAL_STEPS; i++) {
        bdl_stepComplete[i - 1] = false;
    }
    if (step <= 4) {
        bdl_entityStates = [];
        bdl_currentEntityIndex = 0;
    }
    if (step <= 5) {
        bdl_clearPromoteState();
    }
}

/* ============================================================================
   FUNCTIONS: STEP 1 ENVIRONMENT
   ----------------------------------------------------------------------------
   Loads and renders the environment cards, handles selection (with the
   production advisory dynamic modal), and applies the per-environment
   selected-state classes.
   Prefix: bdl
   ============================================================================ */

/* Loads the available environments from the API and renders the cards. */
function bdl_loadEnvironments() {
    fetch('/api/bdl-import/environments').then(function(r) {
        if (!r.ok) {
            throw new Error('HTTP ' + r.status);
        }
        return r.json();
    }).then(function(data) {
        bdl_renderEnvironments(data.environments || []);
    }).catch(function(err) {
        document.getElementById('bdl-env-cards').innerHTML =
            '<div class="bdl-placeholder-message bdl-inline-error">Failed to load: ' +
            err.message + '</div>';
    });
}

/* Renders the environment selection cards, graying out disabled ones. */
function bdl_renderEnvironments(envs) {
    var c = document.getElementById('bdl-env-cards');
    if (!envs.length) {
        c.innerHTML = '<div class="bdl-placeholder-message">No environments configured.</div>';
        return;
    }
    var h = '';
    envs.forEach(function(env) {
        var isDisabled = bdl_disabledEnvironments.indexOf(env.environment) !== -1;
        var envLower = env.environment.toLowerCase();
        var classes = ['bdl-env-card', 'bdl-env-card-' + envLower];
        if (isDisabled) {
            classes.push('bdl-env-card-disabled');
        }
        var actionAttrs = isDisabled ? '' :
            ' data-action-click="bdl-env-select" data-action-bdl-config-id="' + env.config_id + '"';
        h += '<div class="' + classes.join(' ') + '" data-bdl-env="' + env.environment + '"' +
            actionAttrs + '>';
        h += '<div class="bdl-env-name bdl-env-name-' + envLower + '">' + env.environment + '</div>';
        if (isDisabled) {
            h += '<div class="bdl-env-disabled-note">Temporarily unavailable</div>';
        }
        h += '</div>';
    });
    c.innerHTML = h;
    bdl_envData = envs;
}

/* Handles an environment card click, routing PROD through the advisory modal. */
function bdl_selectEnvironment(target) {
    var configId = parseInt(target.getAttribute('data-action-bdl-config-id'), 10);
    var envData = (bdl_envData || []).find(function(e) {
        return e.config_id === configId;
    });
    if (!envData) {
        return;
    }
    if (envData.environment === 'PROD') {
        bdl_showProdAdvisoryModal(envData);
        return;
    }
    bdl_applyEnvironmentSelection(envData);
}

/* Applies the chosen environment, updating selection state and the badge. */
function bdl_applyEnvironmentSelection(envData) {
    var envLower = envData.environment.toLowerCase();
    document.querySelectorAll('.bdl-env-card').forEach(function(card) {
        card.classList.remove('bdl-selected', 'bdl-env-card-test-selected',
            'bdl-env-card-stage-selected', 'bdl-env-card-prod-selected');
        var name = card.querySelector('.bdl-env-name');
        if (name) {
            name.classList.remove('bdl-selected', 'bdl-env-name-test-selected',
                'bdl-env-name-stage-selected', 'bdl-env-name-prod-selected');
        }
    });
    var chosen = document.querySelector('.bdl-env-card[data-bdl-env="' + envData.environment + '"]');
    if (chosen) {
        chosen.classList.add('bdl-selected', 'bdl-env-card-' + envLower + '-selected');
        var nm = chosen.querySelector('.bdl-env-name');
        if (nm) {
            nm.classList.add('bdl-selected', 'bdl-env-name-' + envLower + '-selected');
        }
    }
    bdl_selectedEnvironment = envData;
    bdl_stepComplete[0] = true;
    bdl_updateNavButtons();
    bdl_updateStepperUI();
    bdl_updateEnvBadge();
    bdl_resetFromStep(2);
}

/* Opens the static production-advisory modal before a direct PROD target. */
function bdl_showProdAdvisoryModal(envData) {
    bdl_pendingProdConfigId = envData.config_id;
    document.getElementById('bdl-modal-prod-advisory').classList.remove('cc-hidden');
}

/* Closes the production-advisory modal (backdrop or explicit control). */
function bdl_closeProdAdvisory(target, event) {
    if (event && target.id === 'bdl-modal-prod-advisory' && event.target !== target) {
        return;
    }
    document.getElementById('bdl-modal-prod-advisory').classList.add('cc-hidden');
}

/* Continues to PROD after the advisory, applying the pending selection. */
function bdl_prodAdvisoryContinue() {
    document.getElementById('bdl-modal-prod-advisory').classList.add('cc-hidden');
    var envData = (bdl_envData || []).find(function(e) {
        return e.config_id === bdl_pendingProdConfigId;
    });
    bdl_pendingProdConfigId = null;
    if (envData) {
        bdl_applyEnvironmentSelection(envData);
    }
}

/* Removes a dynamically-created overlay that contains the clicked control. */
function bdl_closeDynamicOverlay(target) {
    var overlay = target.closest('.cc-modal-overlay');
    if (overlay) {
        overlay.remove();
    }
}

/* ============================================================================
   FUNCTIONS: STEP 2 FILE UPLOAD
   ----------------------------------------------------------------------------
   Drag-and-drop and browse handling, in-browser CSV and Excel parsing, the
   file-info display, the preview table, and file removal.
   Prefix: bdl
   ============================================================================ */

/* Highlights the upload zone while a file is dragged over it. */
function bdl_dragOver(event) {
    event.preventDefault();
    event.stopPropagation();
    document.getElementById('bdl-upload-zone').classList.add('bdl-drag-over');
}

/* Clears the upload-zone highlight when the drag leaves. */
function bdl_dragLeave(event) {
    event.preventDefault();
    event.stopPropagation();
    document.getElementById('bdl-upload-zone').classList.remove('bdl-drag-over');
}

/* Handles a file dropped onto the upload zone. */
function bdl_fileDrop(event) {
    event.preventDefault();
    event.stopPropagation();
    document.getElementById('bdl-upload-zone').classList.remove('bdl-drag-over');
    if (event.dataTransfer.files.length > 0) {
        bdl_handleFile(event.dataTransfer.files[0]);
    }
}

/* Validates a file's extension and routes it to the CSV or Excel parser. */
function bdl_handleFile(file) {
    var ext = '.' + file.name.split('.').pop().toLowerCase();
    if (['.csv', '.txt', '.xlsx', '.xls'].indexOf(ext) === -1) {
        cc_showAlert('Supported formats: CSV, TXT, XLSX, XLS',
            { title: 'Invalid File Type' });
        return;
    }
    bdl_uploadedFile = file;
    if (ext === '.csv' || ext === '.txt') {
        bdl_parseCSVPreview(file);
    } else {
        bdl_parseExcelPreview(file);
    }
}

/* Parses the first rows of a CSV/TXT file into the preview data. */
function bdl_parseCSVPreview(file) {
    var reader = new FileReader();
    reader.addEventListener('load', function(e) {
        var lines = e.target.result.split(/\r?\n/).filter(function(l) {
            return l.trim();
        });
        if (lines.length < 2) {
            cc_showAlert('The file contains no data rows.',
                { title: 'Empty File' });
            return;
        }
        var headers = bdl_parseCSVLine(lines[0]);
        var rows = [];
        var i;
        for (i = 1; i <= Math.min(lines.length - 1, bdl_MAX_PREVIEW_ROWS); i++) {
            rows.push(bdl_parseCSVLine(lines[i]));
        }
        bdl_parsedFileData = { headers: headers, rows: rows, rowCount: lines.length - 1 };
        bdl_showFileInfo(file, bdl_parsedFileData);
        bdl_renderFilePreview(bdl_parsedFileData);
        document.getElementById('bdl-upload-prompt').classList.add('bdl-hidden');
        bdl_stepComplete[1] = true;
        bdl_updateNavButtons();
        bdl_updateStepperUI();
        bdl_resetFromStep(3);
    });
    reader.readAsText(file);
}

/* Splits one CSV line into fields, honoring quoted values and escapes. */
function bdl_parseCSVLine(line) {
    var result = [];
    var current = '';
    var inQ = false;
    var i;
    for (i = 0; i < line.length; i++) {
        var ch = line[i];
        if (inQ) {
            if (ch === '"' && i + 1 < line.length && line[i + 1] === '"') {
                current += '"';
                i++;
            } else if (ch === '"') {
                inQ = false;
            } else {
                current += ch;
            }
        } else {
            if (ch === '"') {
                inQ = true;
            } else if (ch === ',') {
                result.push(current.trim());
                current = '';
            } else {
                current += ch;
            }
        }
    }
    result.push(current.trim());
    return result;
}

/* Formats an Excel cell value, rendering dates as ISO strings. */
function bdl_excelCellValue(cell) {
    if (!cell) {
        return '';
    }
    if (cell.t === 'd' && cell.v instanceof Date) {
        var dt = cell.v;
        var mm = String(dt.getUTCMonth() + 1).padStart(2, '0');
        var dd = String(dt.getUTCDate()).padStart(2, '0');
        return dt.getUTCFullYear() + '-' + mm + '-' + dd;
    }
    return cell.w !== undefined ? cell.w : String(cell.v);
}

/* Parses the first sheet of an Excel file into the preview data. */
function bdl_parseExcelPreview(file) {
    var reader = new FileReader();
    reader.addEventListener('load', function(e) {
        try {
            var data = new Uint8Array(e.target.result);
            var wb = XLSX.read(data, { type: 'array', cellDates: true });
            var sh = wb.Sheets[wb.SheetNames[0]];
            if (!sh['!ref']) {
                cc_showAlert('The file contains no data.',
                    { title: 'Empty File' });
                return;
            }
            var range = XLSX.utils.decode_range(sh['!ref']);
            var totalRows = range.e.r;
            if (totalRows < 1) {
                cc_showAlert('The file has headers but no data rows.',
                    { title: 'No Data Rows' });
                return;
            }
            var headers = [];
            var col;
            for (col = range.s.c; col <= range.e.c; col++) {
                var cell = sh[XLSX.utils.encode_cell({ r: 0, c: col })];
                headers.push(cell ? String(cell.v) : 'Column ' + (col + 1));
            }
            var rows = [];
            var row;
            for (row = 1; row <= Math.min(totalRows, bdl_MAX_PREVIEW_ROWS); row++) {
                var rd = [];
                var c2;
                for (c2 = range.s.c; c2 <= range.e.c; c2++) {
                    var dc = sh[XLSX.utils.encode_cell({ r: row, c: c2 })];
                    rd.push(bdl_excelCellValue(dc));
                }
                rows.push(rd);
            }
            bdl_parsedFileData = { headers: headers, rows: rows, rowCount: totalRows };
            bdl_showFileInfo(file, bdl_parsedFileData);
            bdl_renderFilePreview(bdl_parsedFileData);
            document.getElementById('bdl-upload-prompt').classList.add('bdl-hidden');
            bdl_stepComplete[1] = true;
            bdl_updateNavButtons();
            bdl_updateStepperUI();
            bdl_resetFromStep(3);
        } catch (err) {
            cc_showAlert(err.message,
                { title: 'Excel Parse Error' });
        }
    });
    reader.readAsArrayBuffer(file);
}

/* Renders the file info row (name, size, dimensions, remove control). */
function bdl_showFileInfo(file, data) {
    document.getElementById('bdl-file-preview').classList.remove('bdl-hidden');
    var info = document.getElementById('bdl-file-info');
    var sz = (file.size / 1024).toFixed(1) + ' KB';
    if (file.size > 1048576) {
        sz = (file.size / 1048576).toFixed(1) + ' MB';
    }
    info.innerHTML = '<span class="bdl-file-name">' + cc_escapeHtml(file.name) + '</span>' +
        '<span class="bdl-file-detail">' + sz +
        (data ? ' &middot; ' + data.rowCount.toLocaleString() + ' rows &middot; ' +
            data.headers.length + ' columns' : '') + '</span>' +
        '<span class="bdl-file-remove" data-action-click="bdl-file-remove" title="Remove file">&#10005;</span>';
    if (data && data.rowCount > 250000) {
        info.innerHTML += '<div class="bdl-large-file-warning">&#9888; Large file: ' +
            data.rowCount.toLocaleString() + ' rows.</div>';
    }
}

/* Renders the parsed-file preview table. */
function bdl_renderFilePreview(data) {
    var table = document.getElementById('bdl-preview-table');
    var h = '<thead><tr><th class="bdl-preview-table-th bdl-row-num">#</th>';
    data.headers.forEach(function(hd) {
        h += '<th class="bdl-preview-table-th">' + cc_escapeHtml(hd) + '</th>';
    });
    h += '</tr></thead><tbody>';
    data.rows.forEach(function(row, idx) {
        h += '<tr class="bdl-preview-table-row"><td class="bdl-preview-table-td bdl-row-num">' +
            (idx + 1) + '</td>';
        row.forEach(function(cell) {
            h += '<td class="bdl-preview-table-td" title="' + cc_escapeHtml(cell) + '">' +
                cc_escapeHtml(cell) + '</td>';
        });
        h += '</tr>';
    });
    if (data.rowCount > data.rows.length) {
        h += '<tr class="bdl-preview-table-row"><td class="bdl-preview-table-td bdl-preview-more" colspan="' +
            (data.headers.length + 1) + '">... ' +
            (data.rowCount - data.rows.length).toLocaleString() + ' more rows</td></tr>';
    }
    h += '</tbody>';
    table.innerHTML = h;
}

/* Removes the uploaded file and resets the upload step. */
function bdl_removeFile() {
    bdl_uploadedFile = null;
    bdl_parsedFileData = null;
    document.getElementById('bdl-file-preview').classList.add('bdl-hidden');
    document.getElementById('bdl-file-preview').innerHTML =
        '<div class="bdl-file-info" id="bdl-file-info"></div>' +
        '<div class="bdl-preview-table-wrap"><table class="bdl-preview-table" id="bdl-preview-table"></table></div>';
    document.getElementById('bdl-file-input').value = '';
    document.getElementById('bdl-upload-prompt').classList.remove('bdl-hidden');
    bdl_stepComplete[1] = false;
    bdl_resetFromStep(3);
    bdl_updateNavButtons();
    bdl_updateStepperUI();
}

/* ============================================================================
   FUNCTIONS: STEP 3 ENTITY SELECTION
   ----------------------------------------------------------------------------
   Loads and renders the multi-select entity cards grouped by section, handles
   selection toggling and the selection banner, and shows the on-demand
   field-info dynamic modal.
   Prefix: bdl
   ============================================================================ */

/* Loads the available entity types from the API and renders them. */
function bdl_loadEntities() {
    var grid = document.getElementById('bdl-entity-grid');
    grid.innerHTML = '<div class="bdl-loading">Loading entity types...</div>';
    fetch('/api/bdl-import/entities').then(function(r) {
        if (!r.ok) {
            throw new Error('HTTP ' + r.status);
        }
        return r.json();
    }).then(function(data) {
        bdl_allEntities = data.entities || [];
        bdl_renderEntities(bdl_allEntities);
    }).catch(function(err) {
        grid.innerHTML = '<div class="bdl-placeholder-message bdl-inline-error">Failed to load: ' +
            err.message + '</div>';
    });
}

/* Renders the entity cards grouped into Consumer/Account/Other sections. */
function bdl_renderEntities(entities) {
    var grid = document.getElementById('bdl-entity-grid');
    if (!entities.length) {
        grid.innerHTML = '<div class="bdl-placeholder-message">No entity types available.</div>';
        return;
    }
    var sectionOrder = ['CONSUMER', 'ACCOUNT', 'OTHER'];
    var sectionLabels = { CONSUMER: 'Consumer', ACCOUNT: 'Account', OTHER: 'Other' };
    var groups = {};
    entities.forEach(function(ent) {
        var key = ent.entity_key || 'OTHER';
        if (!groups[key]) {
            groups[key] = [];
        }
        groups[key].push(ent);
    });
    var h = '';
    sectionOrder.forEach(function(key) {
        if (!groups[key] || groups[key].length === 0) {
            return;
        }
        h += '<div class="bdl-entity-section"><div class="bdl-entity-section-header">' +
            '<span class="bdl-entity-section-label">' + cc_escapeHtml(sectionLabels[key] || key) +
            '</span><span class="bdl-entity-section-line"></span>' +
            '<span class="bdl-entity-section-count">' + groups[key].length + '</span></div>' +
            '<div class="bdl-entity-cards">';
        groups[key].forEach(function(ent) {
            var dn = bdl_formatEntityName(ent.entity_type);
            var folder = ent.folder || 'root';
            var isSelected = bdl_selectedEntities.some(function(se) {
                return se.entity_type === ent.entity_type;
            });
            var cardClasses = ['bdl-entity-card'];
            if (isSelected) {
                cardClasses.push('bdl-selected');
            }
            h += '<div class="' + cardClasses.join(' ') + '" data-action-click="bdl-entity-toggle" ' +
                'data-action-bdl-entity-type="' + cc_escapeHtml(ent.entity_type) + '">';
            h += '<button class="bdl-entity-info-btn" data-action-click="bdl-entity-field-info" ' +
                'data-action-bdl-entity-type="' + cc_escapeHtml(ent.entity_type) + '" ' +
                'data-action-bdl-entity-name="' + cc_escapeHtml(dn) + '" ' +
                'title="View available fields">i</button>';
            var nameClasses = ['bdl-entity-name'];
            if (isSelected) {
                nameClasses.push('bdl-selected');
            }
            h += '<div class="' + nameClasses.join(' ') + '">' + dn + '</div>' +
                '<div class="bdl-entity-meta"><span class="bdl-entity-folder">' + folder +
                '</span><span class="bdl-entity-fields">' + ent.element_count + ' fields</span></div></div>';
        });
        h += '</div></div>';
    });
    grid.innerHTML = h;
    bdl_updateEntitySelectionBanner();
}

/* Shows the on-demand field-info dynamic modal for an entity type. */
function bdl_showFieldInfo(target) {
    var entityType = target.getAttribute('data-action-bdl-entity-type');
    var entityName = target.getAttribute('data-action-bdl-entity-name');
    var existing = document.getElementById('bdl-field-info-modal');
    if (existing) {
        existing.remove();
    }
    var overlay = document.createElement('div');
    overlay.id = 'bdl-field-info-modal';
    overlay.className = 'cc-modal-overlay';
    overlay.innerHTML =
        '<div class="cc-dialog cc-dialog-modal cc-medium">' +
        '<div class="cc-dialog-header"><span class="cc-dialog-title">Available Fields</span></div>' +
        '<div class="cc-dialog-body"><div class="bdl-field-info-loading">Loading fields for ' +
        cc_escapeHtml(entityName) + '...</div></div>' +
        '<div class="cc-dialog-actions">' +
        '<button class="cc-dialog-btn-cancel" data-action-click="bdl-field-info-close">Close</button>' +
        '</div></div>';
    document.body.appendChild(overlay);
    fetch('/api/bdl-import/entity-fields?entity_type=' + encodeURIComponent(entityType)).then(function(r) {
        return r.json();
    }).then(function(data) {
        var fields = data.fields || [];
        var body = overlay.querySelector('.cc-dialog-body');
        if (!fields.length) {
            body.innerHTML = '<div class="bdl-field-info-empty">No fields available for this entity type.</div>';
            return;
        }
        var entityInfo = bdl_allEntities.find(function(e) {
            return e.entity_type === entityType;
        });
        var entityCanNullify = entityInfo && entityInfo.has_nullify_fields;
        var html = '<div class="bdl-field-info-list">';
        fields.forEach(function(f) {
            var displayName = (f.display_name && f.display_name !== '') ? f.display_name : f.element_name;
            var canNullify = entityCanNullify && !f.is_not_nullifiable && !f.is_primary_id && !f.is_import_required;
            html += '<div class="bdl-field-info-item">';
            if (canNullify) {
                html += '<span class="bdl-field-info-nullify-icon" title="This field can be nullified during import">&#8709;</span>';
            }
            html += '<div class="bdl-field-info-name">' + cc_escapeHtml(displayName) + '</div>';
            if (f.field_description && f.field_description.length > 0) {
                html += '<div class="bdl-field-info-desc">' + cc_escapeHtml(f.field_description) + '</div>';
            }
            if (f.import_guidance && f.import_guidance.length > 0) {
                html += '<div class="bdl-field-info-guidance">' + cc_escapeHtml(f.import_guidance) + '</div>';
            }
            html += '</div>';
        });
        html += '</div>';
        body.innerHTML = html;
    }).catch(function(err) {
        overlay.querySelector('.cc-dialog-body').innerHTML =
            '<div class="bdl-field-info-empty bdl-inline-error">Failed to load fields: ' +
            cc_escapeHtml(err.message) + '</div>';
    });
}

/* Toggles an entity's membership in the selected set and updates Step 3. */
function bdl_toggleEntity(target) {
    var entityType = target.getAttribute('data-action-bdl-entity-type');
    var idx = -1;
    var i;
    for (i = 0; i < bdl_selectedEntities.length; i++) {
        if (bdl_selectedEntities[i].entity_type === entityType) {
            idx = i;
            break;
        }
    }
    if (idx !== -1) {
        bdl_selectedEntities.splice(idx, 1);
    } else {
        var ent = bdl_allEntities.find(function(e) {
            return e.entity_type === entityType;
        });
        if (ent) {
            bdl_selectedEntities.push(ent);
        }
    }
    bdl_renderEntities(bdl_allEntities);
    bdl_stepComplete[2] = bdl_selectedEntities.length > 0;
    bdl_updateNavButtons();
    bdl_updateStepperUI();
    bdl_resetFromStep(4);
}

/* Updates the entity selection banner's count display. */
function bdl_updateEntitySelectionBanner() {
    var countEl = document.getElementById('bdl-entity-select-count');
    if (!countEl) {
        return;
    }
    if (bdl_selectedEntities.length === 0) {
        countEl.textContent = '';
        countEl.className = 'bdl-entity-banner-count';
    } else {
        countEl.textContent = bdl_selectedEntities.length + ' selected';
        countEl.className = 'bdl-entity-banner-count bdl-entity-banner-count-active';
    }
}

/* Formats an entity_type identifier into a Title Case display name. */
function bdl_formatEntityName(et) {
    return et.split('_').map(function(w) {
        return w.charAt(0).toUpperCase() + w.slice(1).toLowerCase();
    }).join(' ');
}

/* ============================================================================
   FUNCTIONS: PER-ENTITY STATE
   ----------------------------------------------------------------------------
   Initialization and access helpers for the per-entity processing state
   array, plus loading the current entity's field definitions.
   Prefix: bdl
   ============================================================================ */

/* Returns the state object for the entity currently being mapped. */
function bdl_curState() {
    return bdl_entityStates[bdl_currentEntityIndex] || null;
}

/* Returns the entity object for the entity currently being mapped. */
function bdl_curEntity() {
    var s = bdl_curState();
    return s ? s.entity : null;
}

/* Builds the per-entity state array from the selected entities. */
function bdl_initEntityStates() {
    bdl_entityStates = bdl_selectedEntities.map(function(ent) {
        return {
            entity: ent,
            fields: null,
            wrapper: null,
            columnMapping: {},
            assignments: [],
            fieldAssignments: {},
            stagingContext: null,
            stagedMapping: null,
            stagedAssignments: null,
            stagedFieldAssignments: null,
            validationResult: null,
            validated: false,
            xmlPreviewLoaded: false,
            nullifyFields: [],
            composedMessage: null
        };
    });
}

/* Loads the current entity's field definitions, then runs the callback. */
function bdl_loadCurrentEntityFields(callback) {
    var state = bdl_curState();
    if (!state) {
        if (callback) {
            callback();
        }
        return;
    }
    if (state.fields) {
        if (callback) {
            callback();
        }
        return;
    }
    fetch('/api/bdl-import/entity-fields?entity_type=' + encodeURIComponent(state.entity.entity_type))
        .then(function(r) {
            return r.json();
        }).then(function(data) {
            state.fields = data.fields || [];
            state.wrapper = data.wrapper || [];
            bdl_loadTemplates(state.entity.entity_type);
            if (callback) {
                callback();
            }
        }).catch(function(err) {
            console.error('Failed to load entity fields:', err);
            if (callback) {
                callback();
            }
        });
}

/* Returns a field's display name, falling back to its element name. */
function bdl_getFieldDisplayName(f) {
    return (f.display_name && f.display_name !== '') ? f.display_name : f.element_name;
}

/* Returns a field's display name by element name, from the current state. */
function bdl_getFieldDisplayNameByElement(elementName) {
    var state = bdl_curState();
    if (!state || !state.fields) {
        return elementName;
    }
    var f = state.fields.find(function(fld) {
        return fld.element_name === elementName;
    });
    return f ? bdl_getFieldDisplayName(f) : elementName;
}

/* Reports whether a field carries a non-empty display name. */
function bdl_hasDisplayName(f) {
    return f.display_name && f.display_name !== '';
}

/* Resolves the required identifier element name from an entity's entity_key.
   CONSUMER keys on the consumer agency id, ACCOUNT on the account agency id.
   Any other value returns null: there is no safe default, because mapping an
   account-level entity onto the consumer identifier could target the wrong
   records. */
function bdl_identifierElementForKey(entityKey) {
    if (entityKey === 'CONSUMER') {
        return 'cnsmr_idntfr_agncy_id';
    }
    if (entityKey === 'ACCOUNT') {
        return 'cnsmr_accnt_idntfr_agncy_id';
    }
    return null;
}

/* Handles an entity whose entity_key is not recognized: shows a blocking
   modal directing the user to the Applications Team and returns them to the
   entity-selection step. Nothing is rendered or made submittable, so a
   misconfigured entity cannot import against the wrong identifier. */
function bdl_handleUnrecognizedEntityKey() {
    cc_showAlert('Unrecognized entity_key, please contact the Applications Team to resolve this issue.',
        { title: 'Entity Not Configured' });
    bdl_showStep(3);
}

/* ============================================================================
   FUNCTIONS: STEP 4 MAPPING
   ----------------------------------------------------------------------------
   The per-entity mapping workspace: the render dispatcher, the standard
   drag-and-drop column mapping (source/target panels, chips, mapped pairs),
   the required identifier selector, nullify handling, and the
   mapping-completeness check that gates the Validate button.
   Prefix: bdl
   ============================================================================ */

/* Renders the current entity's Step 4 panel in its mapping, validation, or
   validated state. */
function bdl_renderMapValidatePanel() {
    var area = document.getElementById('bdl-map-validate-area');
    var state = bdl_curState();
    if (!state || !state.fields || !bdl_parsedFileData) {
        area.innerHTML = '<div class="bdl-placeholder-message">Complete previous steps.</div>';
        return;
    }
    if (state.validated) {
        bdl_renderMapValidateValidated(area, state);
    } else if (state.stagingContext && state.validationResult) {
        bdl_renderMapValidateValidation(area, state);
    } else {
        bdl_renderMapValidateMapping(area, state);
    }
    bdl_updateStep4Completion();
    bdl_updateNavButtons();
}

/* Renders the standard drag-and-drop mapping UI for a non-fixed entity. */
function bdl_renderMapValidateMapping(area, state) {
    if (state.entity.action_type === 'FIXED_VALUE') {
        bdl_renderFixedValueMapping(area, state);
        return;
    }
    var entityFields = state.fields;
    var columnMapping = state.columnMapping;
    var visibleFields = entityFields.filter(function(f) {
        return f.is_visible !== 0 && f.is_visible !== false;
    });
    var idElemName = bdl_identifierElementForKey(state.entity.entity_key);
    if (!idElemName) {
        bdl_handleUnrecognizedEntityKey();
        return;
    }
    var isAcct = state.entity.entity_key === 'ACCOUNT';
    var idField = visibleFields.find(function(f) {
        return f.element_name === idElemName;
    });
    var mappableFields = visibleFields.filter(function(f) {
        if (f.element_name === idElemName) {
            return false;
        }
        if (bdl_isComposedMessageActive(state) && f.element_name === bdl_COMPOSED_MESSAGE_ELEMENT) {
            return false;
        }
        return true;
    });
    var prevIdIdx = '';
    var k;
    for (k in columnMapping) {
        if (columnMapping[k] === idElemName) {
            var hIdx = bdl_parsedFileData.headers.indexOf(k);
            if (hIdx !== -1) {
                prevIdIdx = String(hIdx);
            }
            break;
        }
    }
    var html = bdl_renderEntityProgressBanner('mapping');
    var idSelected = (prevIdIdx !== '');
    if (idField) {
        var idStateClass = idSelected ? 'bdl-identifier-confirmed' : 'bdl-identifier-pending';
        html += '<div class="bdl-mapping-identifier ' + idStateClass + '">' +
            '<div class="bdl-identifier-label"><span class="bdl-identifier-icon">&#128273;</span>' +
            '<strong class="bdl-identifier-label-strong">' + (isAcct ? 'Account' : 'Consumer') +
            ' Identifier</strong><span class="bdl-identifier-note">Which column contains the DM ' +
            (isAcct ? 'Account' : 'Consumer') + ' Number?</span></div>' +
            '<div class="bdl-identifier-select"><select id="bdl-identifier-column" ' +
            'data-action-change="bdl-identifier-changed" class="bdl-identifier-dropdown">' +
            '<option value="">&mdash; Select identifier column &mdash;</option>';
        bdl_parsedFileData.headers.forEach(function(header, idx) {
            var sample = (bdl_parsedFileData.rows[0] && bdl_parsedFileData.rows[0][idx]) ?
                bdl_parsedFileData.rows[0][idx] : '';
            var sel = (String(idx) === prevIdIdx) ? ' selected' : '';
            html += '<option value="' + idx + '"' + sel + '>' +
                cc_escapeHtml(header + (sample ? '  (' + sample.substring(0, 20) + ')' : '')) + '</option>';
        });
        html += '</select><span class="bdl-identifier-target">&#8594; <code class="bdl-identifier-target-code">' +
            idField.element_name + '</code></span></div></div>';
    }
    var disabledClass = (idField && !idSelected) ? ' bdl-mapping-disabled' : '';
    html += '<div class="bdl-mapping-panels-wrap' + disabledClass + '" id="bdl-mapping-panels-wrap">';
    if (idField && !idSelected) {
        html += '<div class="bdl-mapping-disabled-msg">Select the identifier column above to begin mapping</div>';
    }
    html += '<div class="bdl-mapping-panels"><div class="bdl-mapping-panel">' +
        '<div class="bdl-panel-header bdl-panel-header-source">Source Columns</div>' +
        '<div class="bdl-panel-list" id="bdl-source-list"></div></div>' +
        '<div class="bdl-mapping-panel"><div class="bdl-panel-header bdl-panel-header-target">BDL Fields</div>' +
        '<div class="bdl-panel-list" id="bdl-target-list"></div></div></div>';
    html += '<div class="bdl-mapped-section"><div class="bdl-panel-header bdl-panel-header-mapped">Mapped</div>' +
        '<div class="bdl-mapped-list" id="bdl-mapped-list"></div></div>';
    html += '<div id="bdl-field-assignments-area"></div>';
    html += '<div id="bdl-composed-message-area"></div>';
    html += '<div id="bdl-mapping-warnings" class="bdl-mapping-warnings"></div></div>';
    html += '<div class="bdl-map-validate-actions"><button class="bdl-execute-btn" id="bdl-btn-validate-entity" ' +
        'data-action-click="bdl-validate-entity" disabled>Validate ' +
        cc_escapeHtml(bdl_formatEntityName(state.entity.entity_type)) + '</button></div>';
    area.innerHTML = html;
    area._mappableFields = mappableFields;
    area._identifierField = idField;
    area._identifierElementName = idElemName;
    area._selectedSource = null;
    bdl_refreshMappingPanels();
}

/* Re-renders the source, target, and mapped lists from current state. */
function bdl_refreshMappingPanels() {
    var area = document.getElementById('bdl-map-validate-area');
    var state = bdl_curState();
    if (!state) {
        return;
    }
    var mf = area._mappableFields;
    var columnMapping = state.columnMapping;
    var nullified = state.nullifyFields || [];
    var canEntityNullify = !!state.entity.has_nullify_fields;
    var fieldAssigned = state.fieldAssignments || {};
    var idColIdx = null;
    var idSel = document.getElementById('bdl-identifier-column');
    if (idSel && idSel.value !== '') {
        idColIdx = parseInt(idSel.value, 10);
    }
    var mSrc = Object.keys(columnMapping);
    var mTgt = Object.values(columnMapping);
    var srcList = document.getElementById('bdl-source-list');
    var srcH = '';
    bdl_parsedFileData.headers.forEach(function(header, idx) {
        if (idx === idColIdx || mSrc.indexOf(header) !== -1) {
            return;
        }
        var sample = (bdl_parsedFileData.rows[0] && bdl_parsedFileData.rows[0][idx]) ?
            bdl_parsedFileData.rows[0][idx] : '';
        if (sample.length > 30) {
            sample = sample.substring(0, 27) + '...';
        }
        var chipClasses = ['bdl-mapping-chip', 'bdl-source-chip'];
        if (area._selectedSource === header) {
            chipClasses.push('bdl-selected');
        }
        srcH += '<div class="' + chipClasses.join(' ') + '" draggable="true" ' +
            'data-bdl-source="' + cc_escapeHtml(header) + '" data-bdl-idx="' + idx + '" ' +
            'data-action-click="bdl-source-click" data-action-bdl-source="' + cc_escapeHtml(header) + '">';
        srcH += '<div class="bdl-chip-name bdl-chip-name-source">' + cc_escapeHtml(header) + '</div>';
        if (sample) {
            srcH += '<div class="bdl-chip-sample">' + cc_escapeHtml(sample) + '</div>';
        }
        srcH += '</div>';
    });
    srcList.innerHTML = srcH || '<div class="bdl-panel-empty">All columns mapped</div>';
    var tgtList = document.getElementById('bdl-target-list');
    var tgtH = '';
    mf.forEach(function(f) {
        if (mTgt.indexOf(f.element_name) !== -1) {
            return;
        }
        if (nullified.indexOf(f.element_name) !== -1) {
            return;
        }
        if (fieldAssigned[f.element_name]) {
            return;
        }
        var chipClasses = ['bdl-mapping-chip', 'bdl-target-chip'];
        if (f.is_import_required) {
            chipClasses.push('bdl-chip-required');
        }
        var canNullify = canEntityNullify && !f.is_not_nullifiable && !f.is_import_required && !f.is_conditional_eligible;
        var isConditionalEligible = !!f.is_conditional_eligible;
        tgtH += '<div class="' + chipClasses.join(' ') + '" data-bdl-element="' + f.element_name + '" ' +
            'data-action-click="bdl-target-click" data-action-bdl-element="' + f.element_name + '">';
        if (bdl_hasDisplayName(f)) {
            tgtH += '<div class="bdl-chip-name bdl-chip-name-target">' + cc_escapeHtml(f.display_name) +
                '</div><div class="bdl-chip-element">' + f.element_name + '</div>';
        } else {
            tgtH += '<div class="bdl-chip-name bdl-chip-name-target bdl-chip-name-technical">' +
                f.element_name + '</div>';
        }
        if (f.field_description) {
            tgtH += '<div class="bdl-chip-desc">' + cc_escapeHtml(f.field_description.substring(0, 80)) + '</div>';
        }
        if (f.import_guidance) {
            tgtH += '<div class="bdl-chip-guidance">' + cc_escapeHtml(f.import_guidance) + '</div>';
        }
        var meta = bdl_buildFieldMeta(f);
        if (meta) {
            tgtH += '<div class="bdl-chip-meta">' + meta + '</div>';
        }
        if (isConditionalEligible) {
            tgtH += '<div class="bdl-field-mode-toggle">';
            tgtH += '<span class="bdl-field-mode-btn bdl-field-mode-active-file" title="Map from file column (drag & drop)">File</span>';
            tgtH += '<span class="bdl-field-mode-btn" data-action-click="bdl-field-mode" ' +
                'data-action-bdl-element="' + f.element_name + '" data-action-bdl-mode="blanket" ' +
                'title="Set one value for all rows">Blanket</span>';
            tgtH += '<span class="bdl-field-mode-btn" data-action-click="bdl-field-mode" ' +
                'data-action-bdl-element="' + f.element_name + '" data-action-bdl-mode="conditional" ' +
                'title="Vary by trigger column">Cond</span>';
            tgtH += '</div>';
        } else if (canNullify) {
            tgtH += '<span class="bdl-chip-nullify-btn" data-action-click="bdl-nullify-field" ' +
                'data-action-bdl-element="' + f.element_name + '" title="Nullify this field in DM">&#8709;</span>';
        }
        tgtH += '</div>';
    });
    tgtList.innerHTML = tgtH || '<div class="bdl-panel-empty">All fields mapped</div>';
    var mapList = document.getElementById('bdl-mapped-list');
    var mapH = '';
    var mKeys = Object.keys(columnMapping);
    if (!mKeys.length && !nullified.length) {
        mapH = '<div class="bdl-panel-empty">Click a source column, then click a BDL field to pair them. Or drag and drop.</div>';
    } else {
        mKeys.forEach(function(sc) {
            var te = columnMapping[sc];
            var displayName = bdl_getFieldDisplayNameByElement(te);
            mapH += '<div class="bdl-mapped-pair"><span class="bdl-pair-source">' + cc_escapeHtml(sc) +
                '</span><span class="bdl-pair-arrow">&#8594;</span>';
            if (displayName !== te) {
                mapH += '<span class="bdl-pair-target"><span class="bdl-pair-display">' +
                    cc_escapeHtml(displayName) + '</span> <span class="bdl-pair-element">' + te + '</span></span>';
            } else {
                mapH += '<span class="bdl-pair-target">' + te + '</span>';
            }
            mapH += '<span class="bdl-pair-remove" data-action-click="bdl-unmap-pair" ' +
                'data-action-bdl-source="' + cc_escapeHtml(sc) + '" title="Remove mapping">&#10005;</span></div>';
        });
        nullified.forEach(function(nf) {
            var displayName = bdl_getFieldDisplayNameByElement(nf);
            mapH += '<div class="bdl-mapped-pair bdl-mapped-pair-nullify">' +
                '<span class="bdl-pair-nullify-label">&#8709; Nullify</span>' +
                '<span class="bdl-pair-arrow">&#8594;</span>';
            if (displayName !== nf) {
                mapH += '<span class="bdl-pair-target"><span class="bdl-pair-display">' +
                    cc_escapeHtml(displayName) + '</span> <span class="bdl-pair-element">' + nf + '</span></span>';
            } else {
                mapH += '<span class="bdl-pair-target">' + nf + '</span>';
            }
            mapH += '<span class="bdl-pair-remove" data-action-click="bdl-unnullify-field" ' +
                'data-action-bdl-element="' + nf + '" title="Remove nullification">&#10005;</span></div>';
        });
    }
    mapList.innerHTML = mapH;
    bdl_renderFieldAssignmentsSection(state);
    bdl_renderComposedMessageSection(state);
    bdl_checkMappingComplete();
}

/* Builds the meta line (type, length, lookup, required) for a target chip. */
function bdl_buildFieldMeta(f) {
    var p = [];
    if (f.data_type) {
        p.push(f.data_type);
    }
    if (f.max_length) {
        p.push('max ' + f.max_length);
    }
    if (f.lookup_table) {
        p.push('&#128270; ' + f.lookup_table);
    }
    if (f.is_import_required) {
        p.push('required');
    }
    return p.join(' \u00b7 ');
}

/* Reports whether a field is a boolean type. */
function bdl_isBooleanField(f) {
    return f && (f.data_type || '').toLowerCase() === 'boolean';
}

/* Builds a Y/N select for a boolean field. */
function bdl_buildBooleanSelect(fieldId, existingVal, actionAttrs) {
    var nSel = '';
    var ySel = '';
    if (existingVal === 'Y' || existingVal === 'y' || existingVal === 'yes' ||
        existingVal === 'true' || existingVal === '1') {
        ySel = ' selected';
    } else {
        nSel = ' selected';
    }
    return '<select id="' + fieldId + '" class="bdl-fixed-value-text bdl-boolean-select" ' + actionAttrs +
        '><option value="N"' + nSel + '>N</option><option value="Y"' + ySel + '>Y</option></select>';
}

/* Reports whether the mapping panels are currently disabled. */
function bdl_isMappingDisabled() {
    var wrap = document.getElementById('bdl-mapping-panels-wrap');
    return wrap && wrap.classList.contains('bdl-mapping-disabled');
}

/* Handles a source-column chip click, toggling it as the pairing source. */
function bdl_sourceClick(target) {
    if (bdl_isMappingDisabled()) {
        return;
    }
    var h = target.getAttribute('data-action-bdl-source');
    var a = document.getElementById('bdl-map-validate-area');
    a._selectedSource = (a._selectedSource === h) ? null : h;
    bdl_refreshMappingPanels();
}

/* Handles a target-field chip click, pairing it with the selected source. */
function bdl_targetClick(target) {
    if (bdl_isMappingDisabled()) {
        return;
    }
    var el = target.getAttribute('data-action-bdl-element');
    var a = document.getElementById('bdl-map-validate-area');
    if (!a._selectedSource) {
        return;
    }
    bdl_curState().columnMapping[a._selectedSource] = el;
    a._selectedSource = null;
    bdl_refreshMappingPanels();
}

/* Begins a chip drag, recording the source column in the drag payload. */
function bdl_chipDragStart(event) {
    if (bdl_isMappingDisabled()) {
        event.preventDefault();
        return;
    }
    var s = event.target.closest('.bdl-source-chip');
    if (!s) {
        return;
    }
    event.dataTransfer.setData('text/plain', s.dataset.bdlSource);
    event.dataTransfer.effectAllowed = 'link';
    s.classList.add('bdl-dragging');
}

/* Highlights a target chip as a drop target during a chip drag-over. */
function bdl_chipDragOver(event) {
    if (bdl_isMappingDisabled()) {
        return;
    }
    event.preventDefault();
    event.dataTransfer.dropEffect = 'link';
    var t = event.target.closest('.bdl-target-chip');
    if (t) {
        t.classList.add('bdl-drag-hover');
    }
}

/* Completes a chip drop, pairing the dragged source with the target field. */
function bdl_chipDrop(event) {
    if (bdl_isMappingDisabled()) {
        return;
    }
    event.preventDefault();
    var sh = event.dataTransfer.getData('text/plain');
    var t = event.target.closest('.bdl-target-chip');
    if (!t || !sh) {
        return;
    }
    bdl_curState().columnMapping[sh] = t.dataset.bdlElement;
    document.getElementById('bdl-map-validate-area')._selectedSource = null;
    bdl_refreshMappingPanels();
}

/* Removes a mapped source-to-target pair. */
function bdl_unmapPair(target) {
    var sc = target.getAttribute('data-action-bdl-source');
    delete bdl_curState().columnMapping[sc];
    bdl_refreshMappingPanels();
}

/* Handles the identifier-column select change, (re)mapping the ID column. */
function bdl_identifierChanged() {
    var a = document.getElementById('bdl-map-validate-area');
    var idSel = document.getElementById('bdl-identifier-column');
    var idElem = a._identifierElementName;
    var cm = bdl_curState().columnMapping;
    var k;
    for (k in cm) {
        if (cm[k] === idElem) {
            delete cm[k];
        }
    }
    if (idSel.value !== '') {
        cm[bdl_parsedFileData.headers[parseInt(idSel.value, 10)]] = idElem;
    }
    var idSection = document.querySelector('.bdl-mapping-identifier');
    var wrap = document.getElementById('bdl-mapping-panels-wrap');
    if (idSel.value !== '') {
        if (idSection) {
            idSection.classList.remove('bdl-identifier-pending');
            idSection.classList.add('bdl-identifier-confirmed');
        }
        if (wrap) {
            wrap.classList.remove('bdl-mapping-disabled');
            var msg = wrap.querySelector('.bdl-mapping-disabled-msg');
            if (msg) {
                msg.remove();
            }
        }
    } else {
        if (idSection) {
            idSection.classList.remove('bdl-identifier-confirmed');
            idSection.classList.add('bdl-identifier-pending');
        }
        if (wrap) {
            wrap.classList.add('bdl-mapping-disabled');
        }
    }
    bdl_refreshMappingPanels();
}

/* Marks a field for nullification and refreshes the panels. */
function bdl_nullifyField(target) {
    var elementName = target.getAttribute('data-action-bdl-element');
    var state = bdl_curState();
    if (!state.nullifyFields) {
        state.nullifyFields = [];
    }
    if (state.nullifyFields.indexOf(elementName) === -1) {
        state.nullifyFields.push(elementName);
    }
    bdl_refreshMappingPanels();
}

/* Removes a field's nullification and refreshes the panels. */
function bdl_unnullifyField(target) {
    var elementName = target.getAttribute('data-action-bdl-element');
    var state = bdl_curState();
    var idx = state.nullifyFields ? state.nullifyFields.indexOf(elementName) : -1;
    if (idx !== -1) {
        state.nullifyFields.splice(idx, 1);
    }
    bdl_refreshMappingPanels();
}

/* Updates the warnings/success display and enables the Validate button when
   the mapping (and any field assignments) are sufficiently complete. */
function bdl_checkMappingComplete() {
    var state = bdl_curState();
    if (!state) {
        return;
    }
    var area = document.getElementById('bdl-map-validate-area');
    var mc = Object.keys(state.columnMapping).length;
    var mf = area ? area._mappableFields || [] : [];
    var idF = area ? area._identifierField : null;
    var allReq = mf.filter(function(f) {
        return f.is_import_required;
    });
    if (idF) {
        allReq.push(idF);
    }
    var mapped = Object.values(state.columnMapping);
    var unmReq = allReq.filter(function(f) {
        if (mapped.indexOf(f.element_name) !== -1) {
            return false;
        }
        if (state.fieldAssignments && state.fieldAssignments[f.element_name]) {
            return false;
        }
        return true;
    });
    var wd = document.getElementById('bdl-mapping-warnings');
    if (wd) {
        if (unmReq.length > 0) {
            wd.innerHTML = '<div class="bdl-warning-box"><strong>&#9888; Unmapped required fields:</strong> ' +
                unmReq.map(function(f) {
                    return '<code class="bdl-warning-box-code">' + bdl_getFieldDisplayName(f) + '</code>';
                }).join(', ') +
                '<br><span class="bdl-warning-box-note">These will be added to the staging table. ' +
                'You must provide values during validation.</span></div>';
        } else if (mc > 0 || (state.fieldAssignments && Object.keys(state.fieldAssignments).length > 0)) {
            wd.innerHTML = '<div class="bdl-success-box">&#10003; All required fields mapped</div>';
        } else {
            wd.innerHTML = '';
        }
    }
    var fieldAssignmentsReady = true;
    if (state.fieldAssignments) {
        Object.keys(state.fieldAssignments).forEach(function(elemName) {
            if (!bdl_fieldAssignmentComplete(state, elemName, state.fieldAssignments[elemName])) {
                fieldAssignmentsReady = false;
            }
        });
    }
    var valBtn = document.getElementById('bdl-btn-validate-entity');
    var composedActive = bdl_isComposedMessageActive(state);
    var composedReady = bdl_composedMessageReady(state);
    var hasContent = mc > 0 ||
        (state.nullifyFields && state.nullifyFields.length > 0) ||
        (state.fieldAssignments && Object.keys(state.fieldAssignments).length > 0) ||
        (composedActive && composedReady);
    if (valBtn) {
        valBtn.disabled = !hasContent || !fieldAssignmentsReady || !composedReady;
        bdl_setEnabledClass(valBtn, !valBtn.disabled);
    }
    bdl_refreshCompleteStates(state);
}

/* Updates the live complete-state styling without a full re-render: the green
   header on each field-assignment card and the message builder, and the
   value-set accent on filled blanket inputs. Called on every mapping change so
   the cues track edits without disrupting input focus. */
function bdl_refreshCompleteStates(state) {
    if (!state) {
        return;
    }
    if (state.fieldAssignments) {
        Object.keys(state.fieldAssignments).forEach(function(elemName) {
            var fa = state.fieldAssignments[elemName];
            var fieldId = 'bdl-fa-blanket-' + elemName.replace(/[^a-zA-Z0-9]/g, '');
            var input = document.getElementById(fieldId);
            if (input && input.classList.contains('bdl-fixed-value-text')) {
                var faField = state.fields ? state.fields.find(function(f) {
                    return f.element_name === elemName;
                }) : null;
                var isSet;
                if (faField && faField.lookup_table) {
                    isSet = !!fa.valueResolved;
                } else {
                    isSet = !!(input.value && input.value.trim() !== '');
                }
                if (isSet) {
                    input.classList.add('bdl-value-set');
                } else {
                    input.classList.remove('bdl-value-set');
                }
            }
        });
    }
    if (state.fieldAssignments) {
        Object.keys(state.fieldAssignments).forEach(function(elemName) {
            var header = document.querySelector('.bdl-field-assignment-header[data-bdl-fa-element="' + elemName + '"]');
            if (header) {
                if (bdl_fieldAssignmentComplete(state, elemName, state.fieldAssignments[elemName])) {
                    header.classList.add('bdl-assignment-complete');
                } else {
                    header.classList.remove('bdl-assignment-complete');
                }
            }
        });
    }
    var cmHeader = document.querySelector('.bdl-composed-header');
    if (cmHeader && bdl_isComposedMessageActive(state)) {
        if (bdl_composedMessageReady(state)) {
            cmHeader.classList.add('bdl-assignment-complete');
        } else {
            cmHeader.classList.remove('bdl-assignment-complete');
        }
    }
}

/* Marks Step 4 complete when every selected entity has been validated. */
function bdl_updateStep4Completion() {
    var allDone = bdl_entityStates.length > 0 && bdl_entityStates.every(function(s) {
        return s.validated;
    });
    bdl_stepComplete[3] = allDone;
    bdl_updateStepperUI();
}

/* Compares two column-mapping objects for equality. */
function bdl_mappingsAreEqual(a, b) {
    if (!a || !b) {
        return false;
    }
    var aKeys = Object.keys(a).sort();
    var bKeys = Object.keys(b).sort();
    if (aKeys.length !== bKeys.length) {
        return false;
    }
    var i;
    for (i = 0; i < aKeys.length; i++) {
        if (aKeys[i] !== bKeys[i] || a[aKeys[i]] !== b[bKeys[i]]) {
            return false;
        }
    }
    return true;
}

/* Persists the entity's nullify fields to the staging table, then continues. */
function bdl_persistNullifyFields(state, callback) {
    if (!state || !state.stagingContext || !state.nullifyFields || state.nullifyFields.length === 0) {
        if (callback) {
            callback();
        }
        return;
    }
    fetch('/api/bdl-import/set-nullify-fields', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
            staging_table: state.stagingContext.staging_table,
            nullify_fields: state.nullifyFields
        })
    }).then(function(r) {
        if (!r.ok) {
            return r.json().then(function(d) {
                throw new Error(d.error || 'HTTP ' + r.status);
            });
        }
        return r.json();
    }).then(function() {
        if (callback) {
            callback();
        }
    }).catch(function(err) {
        console.error('Failed to persist nullify fields:', err);
        if (callback) {
            callback();
        }
    });
}

/* ============================================================================
   FUNCTIONS: STEP 4 ASSIGNMENT CARDS
   ----------------------------------------------------------------------------
   The FIXED_VALUE entity workflow: the fixed-value identifier selector and
   assignment cards with blanket, conditional, and from-file modes, the
   trigger-column unique-value grid, lookup typeahead suggestions, and the
   assignment-completeness check.
   Prefix: bdl
   ============================================================================ */

/* Renders the fixed-value mapping UI (identifier plus assignment cards). */
function bdl_renderFixedValueMapping(area, state) {
    var entityFields = state.fields;
    var visibleFields = entityFields.filter(function(f) {
        return f.is_visible !== 0 && f.is_visible !== false;
    });
    var idElemName = bdl_identifierElementForKey(state.entity.entity_key);
    if (!idElemName) {
        bdl_handleUnrecognizedEntityKey();
        return;
    }
    var isAcct = state.entity.entity_key === 'ACCOUNT';
    var idField = visibleFields.find(function(f) {
        return f.element_name === idElemName;
    });
    var valueFields = visibleFields.filter(function(f) {
        return f.element_name !== idElemName;
    });
    var conditionalFields = valueFields.filter(function(f) {
        return f.is_conditional_eligible;
    });
    var hasConditionalOption = conditionalFields.length > 0;
    if (!state.assignments || state.assignments.length === 0) {
        state.assignments = [{ mode: 'blanket', fixedValues: {}, triggerColumn: null,
            conditionalField: null, valueMap: {}, sharedFields: {}, triggerUniqueValues: null }];
    }
    var prevIdIdx = '';
    var k;
    for (k in state.columnMapping) {
        if (state.columnMapping[k] === idElemName) {
            var hIdx = bdl_parsedFileData.headers.indexOf(k);
            if (hIdx !== -1) {
                prevIdIdx = String(hIdx);
            }
            break;
        }
    }
    var html = bdl_renderEntityProgressBanner('mapping');
    var idSelected = (prevIdIdx !== '');
    if (idField) {
        var idStateClass = idSelected ? 'bdl-identifier-confirmed' : 'bdl-identifier-pending';
        html += '<div class="bdl-mapping-identifier ' + idStateClass + '">' +
            '<div class="bdl-identifier-label"><span class="bdl-identifier-icon">&#128273;</span>' +
            '<strong class="bdl-identifier-label-strong">' + (isAcct ? 'Account' : 'Consumer') +
            ' Identifier</strong><span class="bdl-identifier-note">Which column contains the DM ' +
            (isAcct ? 'Account' : 'Consumer') + ' Number?</span></div>' +
            '<div class="bdl-identifier-select"><select id="bdl-identifier-column" ' +
            'data-action-change="bdl-fixed-identifier-changed" class="bdl-identifier-dropdown">' +
            '<option value="">&mdash; Select identifier column &mdash;</option>';
        bdl_parsedFileData.headers.forEach(function(header, idx) {
            var sample = (bdl_parsedFileData.rows[0] && bdl_parsedFileData.rows[0][idx]) ?
                bdl_parsedFileData.rows[0][idx] : '';
            var sel = (String(idx) === prevIdIdx) ? ' selected' : '';
            html += '<option value="' + idx + '"' + sel + '>' +
                cc_escapeHtml(header + (sample ? '  (' + sample.substring(0, 20) + ')' : '')) + '</option>';
        });
        html += '</select><span class="bdl-identifier-target">&#8594; <code class="bdl-identifier-target-code">' +
            idField.element_name + '</code></span></div></div>';
    }
    var disabledClass = (idField && !idSelected) ? ' bdl-mapping-disabled' : '';
    html += '<div class="bdl-assignment-area' + disabledClass + '" id="bdl-assignment-area">';
    if (idField && !idSelected) {
        html += '<div class="bdl-mapping-disabled-msg">Select the identifier column above to enter values</div>';
    }
    html += '<div class="bdl-assignment-list" id="bdl-assignment-list">';
    state.assignments.forEach(function(assignment, aIdx) {
        html += bdl_renderAssignmentCard(assignment, aIdx, state, valueFields, conditionalFields, hasConditionalOption);
    });
    html += '</div>';
    var entityWord = bdl_formatEntityName(state.entity.entity_type).split(' ').pop();
    html += '<button class="bdl-add-assignment-btn" data-action-click="bdl-add-assignment">+ Add Another ' +
        cc_escapeHtml(entityWord) + ' Assignment</button>';
    html += '</div>';
    html += '<div class="bdl-map-validate-actions"><button class="bdl-execute-btn" id="bdl-btn-validate-entity" ' +
        'data-action-click="bdl-validate-entity">Validate ' +
        cc_escapeHtml(bdl_formatEntityName(state.entity.entity_type)) + '</button></div>';
    area.innerHTML = html;
    area._identifierField = idField;
    area._identifierElementName = idElemName;
    area._valueFields = valueFields;
    area._conditionalFields = conditionalFields;
    bdl_checkAssignmentsComplete(state);
}

/* Builds the markup for one assignment card in its current mode. */
function bdl_renderAssignmentCard(assignment, aIdx, state, valueFields, conditionalFields, hasConditionalOption) {
    var modeBadgeClass = assignment.mode === 'conditional' ? 'bdl-assignment-badge-conditional' :
        (assignment.mode === 'from_file' ? 'bdl-assignment-badge-file' : 'bdl-assignment-badge-blanket');
    var modeBadgeLabel = assignment.mode === 'conditional' ? 'Conditional' :
        (assignment.mode === 'from_file' ? 'From File' : 'Blanket');
    var html = '<div class="bdl-assignment-card" id="bdl-assignment-card-' + aIdx + '">';
    html += '<div class="bdl-assignment-header"><div class="bdl-assignment-title">' +
        '<span class="bdl-assignment-num">' + (aIdx + 1) + '</span> Assignment ' +
        '<span class="bdl-assignment-mode-badge ' + modeBadgeClass + '">' + modeBadgeLabel + '</span></div>';
    if (state.assignments.length > 1) {
        html += '<span class="bdl-assignment-remove" data-action-click="bdl-remove-assignment" ' +
            'data-action-bdl-aidx="' + aIdx + '" title="Remove assignment">&#10005;</span>';
    }
    html += '</div>';
    if (hasConditionalOption) {
        var fileCls = assignment.mode === 'from_file' ? ' bdl-assignment-toggle-active-file' : '';
        var blanketCls = assignment.mode === 'blanket' ? ' bdl-assignment-toggle-active-blanket' : '';
        var condCls = assignment.mode === 'conditional' ? ' bdl-assignment-toggle-active-cond' : '';
        html += '<div class="bdl-assignment-mode-toggle">' +
            '<div class="bdl-assignment-toggle-btn bdl-toggle-first' + fileCls + '" ' +
            'data-action-click="bdl-assignment-mode" data-action-bdl-aidx="' + aIdx + '" ' +
            'data-action-bdl-mode="from_file">File</div>' +
            '<div class="bdl-assignment-toggle-btn' + blanketCls + '" ' +
            'data-action-click="bdl-assignment-mode" data-action-bdl-aidx="' + aIdx + '" ' +
            'data-action-bdl-mode="blanket">Blanket</div>' +
            '<div class="bdl-assignment-toggle-btn bdl-toggle-last' + condCls + '" ' +
            'data-action-click="bdl-assignment-mode" data-action-bdl-aidx="' + aIdx + '" ' +
            'data-action-bdl-mode="conditional">Conditional</div></div>';
    }
    html += '<div class="bdl-assignment-body">';
    if (assignment.mode === 'from_file') {
        html += bdl_renderFromFileAssignmentFields(assignment, aIdx, state, valueFields, conditionalFields);
    } else if (assignment.mode === 'blanket') {
        html += bdl_renderBlanketFields(assignment, aIdx, valueFields);
    } else {
        html += bdl_renderConditionalFields(assignment, aIdx, state, valueFields, conditionalFields);
    }
    html += '</div></div>';
    return html;
}

/* Builds the blanket-mode fixed-value input rows for an assignment. */
function bdl_renderBlanketFields(assignment, aIdx, valueFields) {
    var html = '';
    valueFields.forEach(function(f) {
        var fieldId = 'bdl-afv-' + aIdx + '-' + f.element_name.replace(/[^a-zA-Z0-9]/g, '');
        var existingVal = assignment.fixedValues[f.element_name] || '';
        var displayName = bdl_hasDisplayName(f) ? f.display_name : f.element_name;
        var reqLabel = f.is_import_required ? ' <span class="bdl-chip-required-label">required</span>' : '';
        html += '<div class="bdl-fixed-value-row"><div class="bdl-fixed-value-label">' +
            cc_escapeHtml(displayName) + reqLabel;
        if (bdl_hasDisplayName(f)) {
            html += '<div class="bdl-fixed-value-element">' + f.element_name + '</div>';
        }
        if (f.field_description) {
            html += '<div class="bdl-fixed-value-desc">' + cc_escapeHtml(f.field_description.substring(0, 120)) + '</div>';
        }
        if (f.import_guidance) {
            html += '<div class="bdl-fixed-value-guidance">' + cc_escapeHtml(f.import_guidance) + '</div>';
        }
        html += '</div><div class="bdl-fixed-value-input">';
        var actionAttrs = 'data-action-change="bdl-assignment-field-changed" data-action-bdl-aidx="' + aIdx +
            '" data-action-bdl-element="' + f.element_name + '"';
        if (bdl_isBooleanField(f)) {
            if (!existingVal) {
                existingVal = 'N';
                assignment.fixedValues[f.element_name] = 'N';
            }
            html += bdl_buildBooleanSelect(fieldId, existingVal, actionAttrs);
        } else if (f.lookup_table) {
            html += '<input type="text" id="' + fieldId + '" class="bdl-fixed-value-text" ' +
                'placeholder="Type to search..." value="' + cc_escapeHtml(existingVal) + '" ' +
                'data-action-input="bdl-assignment-field-search" data-action-bdl-aidx="' + aIdx + '" ' +
                'data-action-bdl-element="' + f.element_name + '" autocomplete="off">' +
                '<div class="bdl-fixed-value-suggestions" id="bdl-sug-' + fieldId + '"></div>';
        } else {
            html += '<input type="text" id="' + fieldId + '" class="bdl-fixed-value-text" ' +
                'placeholder="Enter value" value="' + cc_escapeHtml(existingVal) + '" ' +
                'data-action-input="bdl-assignment-field-search" data-action-bdl-aidx="' + aIdx + '" ' +
                'data-action-bdl-element="' + f.element_name + '">';
        }
        var meta = bdl_buildFieldMeta(f);
        if (meta) {
            html += '<div class="bdl-fixed-value-meta">' + meta + '</div>';
        }
        html += '</div></div>';
    });
    return html;
}

/* Builds the right-hand cell of a conditional trigger row: the row count when
   addressed, a skipped indicator when explicitly skipped, or a prompt when not
   yet addressed, plus the Skip toggle. The toggle uses the supplied click
   action and carries the trigger value plus any extra owner attributes (aidx or
   element). */
function bdl_renderTriggerRowEnd(uv, isAddressed, isSkipped, skipAction, ownerAttrs) {
    var html = '<span class="bdl-trigger-row-action">';
    var triggerAttr = 'data-action-bdl-trigger="' + cc_escapeHtml(uv.value) + '"';
    if (isSkipped) {
        html += '<span class="bdl-trigger-row-skipped-label">skipped</span>';
    } else if (isAddressed) {
        html += '<span class="bdl-trigger-row-count">' + uv.count.toLocaleString() + '</span>';
    } else {
        html += '<span class="bdl-trigger-row-unset">needs action</span>';
    }
    var btnLabel = isSkipped ? 'Unskip' : 'Skip';
    var btnActiveCls = isSkipped ? ' bdl-trigger-skip-btn-active' : '';
    html += '<button type="button" class="bdl-trigger-skip-btn' + btnActiveCls + '" ' +
        'data-action-click="' + skipAction + '" ' + ownerAttrs + ' ' + triggerAttr + '>' + btnLabel + '</button>';
    html += '</span>';
    return html;
}

/* Builds the conditional-mode trigger grid and shared fields for an assignment. */
function bdl_renderConditionalFields(assignment, aIdx, state, valueFields, conditionalFields) {
    var html = '';
    var condField = conditionalFields[0];
    html += '<div class="bdl-trigger-section"><div class="bdl-trigger-label">' +
        '<span class="bdl-trigger-label-icon">&#9881;</span> Trigger column</div>';
    html += '<select class="bdl-identifier-dropdown bdl-trigger-dropdown" id="bdl-trigger-col-' + aIdx + '" ' +
        'data-action-change="bdl-set-trigger-column" data-action-bdl-aidx="' + aIdx + '">' +
        '<option value="">&mdash; Select trigger column &mdash;</option>';
    bdl_parsedFileData.headers.forEach(function(header, idx) {
        var sample = (bdl_parsedFileData.rows[0] && bdl_parsedFileData.rows[0][idx]) ?
            bdl_parsedFileData.rows[0][idx] : '';
        var sel = (assignment.triggerColumn === header) ? ' selected' : '';
        html += '<option value="' + cc_escapeHtml(header) + '"' + sel + '>' +
            cc_escapeHtml(header + (sample ? '  (' + sample.substring(0, 20) + ')' : '')) + '</option>';
    });
    html += '</select>';
    if (assignment.triggerColumn && condField) {
        html += '<div class="bdl-trigger-note">&#9432; Unique values from "' +
            cc_escapeHtml(assignment.triggerColumn) + '" mapped to <code class="bdl-trigger-note-code">' +
            condField.element_name + '</code></div>';
    }
    html += '</div>';
    if (assignment.triggerColumn && assignment.triggerUniqueValues) {
        var uniqueVals = assignment.triggerUniqueValues;
        var showAll = assignment._showAllTriggerValues || false;
        var maxVisible = 15;
        var displayVals = showAll ? uniqueVals : uniqueVals.slice(0, maxVisible);
        var hasMore = uniqueVals.length > maxVisible && !showAll;
        html += '<div class="bdl-trigger-grid"><div class="bdl-trigger-grid-header">' +
            '<span>Trigger value</span><span>' + (condField ? condField.element_name : 'Value') +
            '</span><span class="bdl-trigger-grid-header-rows">Rows</span></div>';
        displayVals.forEach(function(uv) {
            var fieldId = 'bdl-cond-' + aIdx + '-' + uv.value.replace(/[^a-zA-Z0-9]/g, '_');
            var existingVal = assignment.valueMap[uv.value] || '';
            var isSkipped = !!(assignment.skipMap && assignment.skipMap[uv.value]);
            var addressed = bdl_condRowAddressed(assignment, condField, uv.value);
            var setCls = addressed ? ' bdl-trigger-grid-input-set' : '';
            var rowCls = isSkipped ? 'bdl-trigger-grid-row bdl-trigger-row-skipped' : 'bdl-trigger-grid-row';
            html += '<div class="' + rowCls + '"><span class="bdl-trigger-val">' +
                '<code class="bdl-trigger-val-code">' + cc_escapeHtml(uv.value) + '</code></span>' +
                '<span class="bdl-trigger-input-cell">';
            var actionAttrs = 'data-action-change="bdl-conditional-value-changed" data-action-bdl-aidx="' + aIdx +
                '" data-action-bdl-trigger="' + cc_escapeHtml(uv.value) + '"';
            var disabledAttr = isSkipped ? ' disabled' : '';
            if (condField && bdl_isBooleanField(condField)) {
                html += bdl_buildBooleanSelect(fieldId, existingVal, actionAttrs + disabledAttr);
            } else if (condField && condField.lookup_table) {
                html += '<input type="text" id="' + fieldId + '" class="bdl-trigger-grid-input' + setCls + '" ' +
                    'placeholder="Type to search..." value="' + cc_escapeHtml(existingVal) + '"' + disabledAttr + ' ' +
                    'data-action-input="bdl-conditional-value-search" data-action-bdl-aidx="' + aIdx + '" ' +
                    'data-action-bdl-trigger="' + cc_escapeHtml(uv.value) + '" autocomplete="off">' +
                    '<div class="bdl-fixed-value-suggestions" id="bdl-sug-' + fieldId + '"></div>';
            } else {
                html += '<input type="text" id="' + fieldId + '" class="bdl-trigger-grid-input' + setCls + '" ' +
                    'placeholder="Enter value or skip" value="' + cc_escapeHtml(existingVal) + '"' + disabledAttr + ' ' +
                    'data-action-input="bdl-conditional-value-changed" data-action-bdl-aidx="' + aIdx + '" ' +
                    'data-action-bdl-trigger="' + cc_escapeHtml(uv.value) + '">';
            }
            html += '</span>';
            html += bdl_renderTriggerRowEnd(uv, addressed, isSkipped,
                'bdl-cond-skip', 'data-action-bdl-aidx="' + aIdx + '"');
            html += '</div>';
        });
        if (hasMore) {
            html += '<div class="bdl-trigger-grid-show-all" data-action-click="bdl-show-all-triggers" ' +
                'data-action-bdl-aidx="' + aIdx + '">+ ' + (uniqueVals.length - maxVisible) +
                ' more values &mdash; show all</div>';
        }
        html += '</div>';
    } else if (assignment.triggerColumn && !assignment.triggerUniqueValues) {
        html += '<div class="bdl-loading">Scanning file for unique values...</div>';
    }
    var sharedFields = valueFields.filter(function(f) {
        return !f.is_conditional_eligible;
    });
    if (sharedFields.length > 0 && assignment.triggerColumn) {
        html += '<div class="bdl-shared-fields-section"><div class="bdl-shared-fields-label">' +
            'Shared fields (apply to all rows in this assignment)</div>';
        sharedFields.forEach(function(f) {
            var fieldId = 'bdl-asf-' + aIdx + '-' + f.element_name.replace(/[^a-zA-Z0-9]/g, '');
            var existingVal = assignment.sharedFields[f.element_name] || '';
            var displayName = bdl_hasDisplayName(f) ? f.display_name : f.element_name;
            html += '<div class="bdl-fixed-value-row"><div class="bdl-fixed-value-label">' +
                cc_escapeHtml(displayName);
            if (bdl_hasDisplayName(f)) {
                html += '<div class="bdl-fixed-value-element">' + f.element_name + '</div>';
            }
            html += '</div><div class="bdl-fixed-value-input">';
            var actionAttrs = 'data-action-change="bdl-shared-field-changed" data-action-bdl-aidx="' + aIdx +
                '" data-action-bdl-element="' + f.element_name + '"';
            if (bdl_isBooleanField(f)) {
                if (!existingVal) {
                    existingVal = 'N';
                    assignment.sharedFields[f.element_name] = 'N';
                }
                html += bdl_buildBooleanSelect(fieldId, existingVal, actionAttrs);
            } else {
                html += '<input type="text" id="' + fieldId + '" class="bdl-fixed-value-text" ' +
                    'placeholder="Enter value" value="' + cc_escapeHtml(existingVal) + '" ' +
                    'data-action-input="bdl-shared-field-changed" data-action-bdl-aidx="' + aIdx + '" ' +
                    'data-action-bdl-element="' + f.element_name + '">';
            }
            html += '</div></div>';
        });
        html += '</div>';
    }
    return html;
}

/* Builds the from-file-mode source column selector and shared fields. */
function bdl_renderFromFileAssignmentFields(assignment, aIdx, state, valueFields, conditionalFields) {
    var html = '';
    var condField = conditionalFields[0];
    if (!condField) {
        return html;
    }
    var displayName = bdl_hasDisplayName(condField) ? condField.display_name : condField.element_name;
    html += '<div class="bdl-trigger-section"><div class="bdl-trigger-label">' +
        '<span class="bdl-trigger-label-icon">&#128196;</span> Source column for ' +
        cc_escapeHtml(displayName) + '</div>';
    html += '<select class="bdl-identifier-dropdown bdl-trigger-dropdown" id="bdl-filecol-' + aIdx + '" ' +
        'data-action-change="bdl-set-assignment-file-column" data-action-bdl-aidx="' + aIdx + '">' +
        '<option value="">&mdash; Select file column &mdash;</option>';
    bdl_parsedFileData.headers.forEach(function(header, idx) {
        var sample = (bdl_parsedFileData.rows[0] && bdl_parsedFileData.rows[0][idx]) ?
            bdl_parsedFileData.rows[0][idx] : '';
        var sel = (assignment.fileColumn === header) ? ' selected' : '';
        html += '<option value="' + cc_escapeHtml(header) + '"' + sel + '>' +
            cc_escapeHtml(header + (sample ? '  (' + sample.substring(0, 20) + ')' : '')) + '</option>';
    });
    html += '</select>';
    if (assignment.fileColumn) {
        html += '<div class="bdl-trigger-note">&#9432; Values from "' + cc_escapeHtml(assignment.fileColumn) +
            '" will be used for <code class="bdl-trigger-note-code-file">' + condField.element_name + '</code></div>';
    }
    html += '</div>';
    var sharedFields = valueFields.filter(function(f) {
        return !f.is_conditional_eligible;
    });
    if (sharedFields.length > 0 && assignment.fileColumn) {
        html += '<div class="bdl-shared-fields-section"><div class="bdl-shared-fields-label">' +
            'Shared fields (apply to all rows in this assignment)</div>';
        sharedFields.forEach(function(f) {
            var fieldId = 'bdl-asf-' + aIdx + '-' + f.element_name.replace(/[^a-zA-Z0-9]/g, '');
            var existingVal = assignment.sharedFields[f.element_name] || '';
            var dn = bdl_hasDisplayName(f) ? f.display_name : f.element_name;
            html += '<div class="bdl-fixed-value-row"><div class="bdl-fixed-value-label">' + cc_escapeHtml(dn);
            if (bdl_hasDisplayName(f)) {
                html += '<div class="bdl-fixed-value-element">' + f.element_name + '</div>';
            }
            html += '</div><div class="bdl-fixed-value-input">';
            var actionAttrs = 'data-action-change="bdl-shared-field-changed" data-action-bdl-aidx="' + aIdx +
                '" data-action-bdl-element="' + f.element_name + '"';
            if (bdl_isBooleanField(f)) {
                if (!existingVal) {
                    existingVal = 'N';
                    assignment.sharedFields[f.element_name] = 'N';
                }
                html += bdl_buildBooleanSelect(fieldId, existingVal, actionAttrs);
            } else {
                html += '<input type="text" id="' + fieldId + '" class="bdl-fixed-value-text" ' +
                    'placeholder="Enter value" value="' + cc_escapeHtml(existingVal) + '" ' +
                    'data-action-input="bdl-shared-field-changed" data-action-bdl-aidx="' + aIdx + '" ' +
                    'data-action-bdl-element="' + f.element_name + '">';
            }
            html += '</div></div>';
        });
        html += '</div>';
    }
    return html;
}

/* Adds a new blanket assignment card to the current entity. */
function bdl_addAssignment() {
    var state = bdl_curState();
    if (!state) {
        return;
    }
    state.assignments.push({ mode: 'blanket', fixedValues: {}, triggerColumn: null,
        conditionalField: null, valueMap: {}, sharedFields: {}, triggerUniqueValues: null });
    bdl_renderFixedValueMapping(document.getElementById('bdl-map-validate-area'), state);
}

/* Removes an assignment card from the current entity. */
function bdl_removeAssignment(target) {
    var aIdx = parseInt(target.getAttribute('data-action-bdl-aidx'), 10);
    var state = bdl_curState();
    if (!state || state.assignments.length <= 1) {
        return;
    }
    state.assignments.splice(aIdx, 1);
    bdl_renderFixedValueMapping(document.getElementById('bdl-map-validate-area'), state);
}

/* Switches an assignment card between blanket, conditional, and from-file. */
function bdl_toggleAssignmentMode(target) {
    var aIdx = parseInt(target.getAttribute('data-action-bdl-aidx'), 10);
    var mode = target.getAttribute('data-action-bdl-mode');
    var state = bdl_curState();
    if (!state || !state.assignments[aIdx]) {
        return;
    }
    if (state.assignments[aIdx].mode === mode) {
        return;
    }
    var area = document.getElementById('bdl-map-validate-area');
    state.assignments[aIdx].mode = mode;
    if (mode === 'blanket') {
        state.assignments[aIdx].triggerColumn = null;
        state.assignments[aIdx].conditionalField = null;
        state.assignments[aIdx].valueMap = {};
        state.assignments[aIdx].sharedFields = {};
        state.assignments[aIdx].triggerUniqueValues = null;
        state.assignments[aIdx]._showAllTriggerValues = false;
        state.assignments[aIdx].fileColumn = null;
    } else if (mode === 'from_file') {
        state.assignments[aIdx].fixedValues = {};
        state.assignments[aIdx].triggerColumn = null;
        state.assignments[aIdx].valueMap = {};
        state.assignments[aIdx].triggerUniqueValues = null;
        state.assignments[aIdx]._showAllTriggerValues = false;
        state.assignments[aIdx].fileColumn = null;
        state.assignments[aIdx].sharedFields = {};
        if (area._conditionalFields && area._conditionalFields.length > 0) {
            state.assignments[aIdx].conditionalField = area._conditionalFields[0].element_name;
        }
    } else {
        state.assignments[aIdx].fixedValues = {};
        state.assignments[aIdx].fileColumn = null;
        if (area._conditionalFields && area._conditionalFields.length > 0) {
            state.assignments[aIdx].conditionalField = area._conditionalFields[0].element_name;
        }
    }
    bdl_renderFixedValueMapping(area, state);
}

/* Sets the from-file source column for an assignment and re-renders. */
function bdl_setAssignmentFileColumn(target) {
    var aIdx = parseInt(target.getAttribute('data-action-bdl-aidx'), 10);
    var state = bdl_curState();
    if (!state || !state.assignments[aIdx]) {
        return;
    }
    var sel = document.getElementById('bdl-filecol-' + aIdx);
    var headerName = sel ? sel.value : '';
    state.assignments[aIdx].fileColumn = headerName || null;
    bdl_renderFixedValueMapping(document.getElementById('bdl-map-validate-area'), state);
}

/* Expands the trigger-value grid to show all unique values. */
function bdl_showAllTriggerValues(target) {
    var aIdx = parseInt(target.getAttribute('data-action-bdl-aidx'), 10);
    var state = bdl_curState();
    if (!state || !state.assignments[aIdx]) {
        return;
    }
    state.assignments[aIdx]._showAllTriggerValues = true;
    bdl_renderFixedValueMapping(document.getElementById('bdl-map-validate-area'), state);
}

/* Sets the conditional trigger column and scans the file for unique values. */
function bdl_setTriggerColumn(target) {
    var aIdx = parseInt(target.getAttribute('data-action-bdl-aidx'), 10);
    var state = bdl_curState();
    if (!state || !state.assignments[aIdx]) {
        return;
    }
    var sel = document.getElementById('bdl-trigger-col-' + aIdx);
    var headerName = sel ? sel.value : '';
    if (!headerName) {
        state.assignments[aIdx].triggerColumn = null;
        state.assignments[aIdx].triggerUniqueValues = null;
        state.assignments[aIdx].valueMap = {};
        state.assignments[aIdx]._showAllTriggerValues = false;
        bdl_renderFixedValueMapping(document.getElementById('bdl-map-validate-area'), state);
        return;
    }
    state.assignments[aIdx].triggerColumn = headerName;
    state.assignments[aIdx].triggerUniqueValues = null;
    state.assignments[aIdx].valueMap = {};
    state.assignments[aIdx]._showAllTriggerValues = false;
    bdl_renderFixedValueMapping(document.getElementById('bdl-map-validate-area'), state);
    var headerIndex = bdl_parsedFileData.headers.indexOf(headerName);
    if (headerIndex < 0) {
        return;
    }
    bdl_readFileColumnValues(headerIndex, function(uniqueValues) {
        var currentState = bdl_curState();
        if (!currentState || !currentState.assignments[aIdx] ||
            currentState.assignments[aIdx].triggerColumn !== headerName) {
            return;
        }
        currentState.assignments[aIdx].triggerUniqueValues = uniqueValues;
        bdl_renderFixedValueMapping(document.getElementById('bdl-map-validate-area'), currentState);
    });
}

/* Reads a file column's distinct values and counts, then runs the callback. */
function bdl_readFileColumnValues(colIndex, callback) {
    var ext = '.' + bdl_uploadedFile.name.split('.').pop().toLowerCase();
    var reader = new FileReader();
    reader.addEventListener('load', function(e) {
        var allRows;
        try {
            if (ext === '.csv' || ext === '.txt') {
                allRows = bdl_parseCSVAllRows(e.target.result);
            } else {
                allRows = bdl_parseExcelAllRows(e.target.result);
            }
        } catch (err) {
            callback([]);
            return;
        }
        var counts = {};
        var r;
        for (r = 0; r < allRows.length; r++) {
            var val = (colIndex < allRows[r].length) ? allRows[r][colIndex].trim() : '';
            if (val === '') {
                continue;
            }
            if (!counts[val]) {
                counts[val] = 0;
            }
            counts[val]++;
        }
        var result = Object.keys(counts).sort().map(function(v) {
            return { value: v, count: counts[v] };
        });
        callback(result);
    });
    if (ext === '.csv' || ext === '.txt') {
        reader.readAsText(bdl_uploadedFile);
    } else {
        reader.readAsArrayBuffer(bdl_uploadedFile);
    }
}

/* Records a blanket fixed-value change and re-checks assignment completeness. */
function bdl_assignmentFieldChanged(target) {
    var aIdx = parseInt(target.getAttribute('data-action-bdl-aidx'), 10);
    var elementName = target.getAttribute('data-action-bdl-element');
    var state = bdl_curState();
    if (!state || !state.assignments[aIdx]) {
        return;
    }
    var val = target.value.trim();
    if (val) {
        state.assignments[aIdx].fixedValues[elementName] = val;
    } else {
        delete state.assignments[aIdx].fixedValues[elementName];
    }
    bdl_checkAssignmentsComplete(state);
}

/* Records a blanket value edit and runs a debounced lookup search. */
function bdl_assignmentFieldSearch(target) {
    var aIdx = parseInt(target.getAttribute('data-action-bdl-aidx'), 10);
    var elementName = target.getAttribute('data-action-bdl-element');
    var state = bdl_curState();
    if (!state || !state.assignments[aIdx]) {
        return;
    }
    var val = target.value.trim();
    if (val) {
        state.assignments[aIdx].fixedValues[elementName] = val;
    } else {
        delete state.assignments[aIdx].fixedValues[elementName];
    }
    var fieldId = 'bdl-afv-' + aIdx + '-' + elementName.replace(/[^a-zA-Z0-9]/g, '');
    var sugEl = document.getElementById('bdl-sug-' + fieldId);
    if (!sugEl) {
        return;
    }
    if (val.length < 2) {
        sugEl.innerHTML = '';
        bdl_checkAssignmentsComplete(state);
        return;
    }
    var field = state.fields.find(function(f) {
        return f.element_name === elementName;
    });
    if (!field || !field.lookup_table) {
        bdl_checkAssignmentsComplete(state);
        return;
    }
    if (!state._lookupCache) {
        state._lookupCache = {};
    }
    var cacheKey = elementName + '::' + val.toLowerCase();
    if (state._lookupCache[cacheKey]) {
        bdl_renderAssignmentSuggestions(sugEl, state._lookupCache[cacheKey], aIdx, 'blanket', elementName);
        bdl_checkAssignmentsComplete(state);
        return;
    }
    if (bdl_searchDebounceTimer) {
        clearTimeout(bdl_searchDebounceTimer);
    }
    sugEl.innerHTML = '<div class="bdl-suggestion-hint">Searching...</div>';
    bdl_searchDebounceTimer = setTimeout(function() {
        fetch('/api/bdl-import/lookup-search?lookup_table=' + encodeURIComponent(field.lookup_table) +
            '&element_name=' + encodeURIComponent(elementName) + '&search=' + encodeURIComponent(val) +
            '&config_id=' + encodeURIComponent(bdl_selectedEnvironment.config_id) +
            '&entity_type=' + encodeURIComponent(bdl_curState().entity.entity_type))
            .then(function(r) {
                return r.json();
            }).then(function(data) {
                if (data.error) {
                    sugEl.innerHTML = '<div class="bdl-suggestion-hint bdl-inline-error">' +
                        cc_escapeHtml(data.error) + '</div>';
                    return;
                }
                var values = data.values || [];
                state._lookupCache[cacheKey] = values;
                bdl_renderAssignmentSuggestions(sugEl, values, aIdx, 'blanket', elementName);
            }).catch(function() {
                sugEl.innerHTML = '<div class="bdl-suggestion-hint bdl-inline-error">Lookup failed</div>';
            });
    }, 300);
    bdl_checkAssignmentsComplete(state);
}

/* Applies a selected suggestion to a blanket or conditional assignment value. */
function bdl_selectAssignmentValue(target) {
    var aIdx = parseInt(target.getAttribute('data-action-bdl-aidx'), 10);
    var scope = target.getAttribute('data-action-bdl-scope');
    var key = target.getAttribute('data-action-bdl-key');
    var value = target.getAttribute('data-action-bdl-value');
    var state = bdl_curState();
    if (!state || !state.assignments[aIdx]) {
        return;
    }
    if (scope === 'conditional') {
        var cfieldId = 'bdl-cond-' + aIdx + '-' + key.replace(/[^a-zA-Z0-9]/g, '_');
        var cinput = document.getElementById(cfieldId);
        if (cinput) {
            cinput.value = value;
        }
        state.assignments[aIdx].valueMap[key] = value;
        if (!state.assignments[aIdx].resolvedMap) {
            state.assignments[aIdx].resolvedMap = {};
        }
        state.assignments[aIdx].resolvedMap[key] = true;
        var csug = document.getElementById('bdl-sug-' + cfieldId);
        if (csug) {
            csug.innerHTML = '';
        }
        bdl_setCondInputSetClass(cinput, true);
        bdl_updateTriggerRowDisplay(aIdx, key, true);
    } else {
        var bfieldId = 'bdl-afv-' + aIdx + '-' + key.replace(/[^a-zA-Z0-9]/g, '');
        var binput = document.getElementById(bfieldId);
        if (binput) {
            binput.value = value;
        }
        state.assignments[aIdx].fixedValues[key] = value;
        var bsug = document.getElementById('bdl-sug-' + bfieldId);
        if (bsug) {
            bsug.innerHTML = '';
        }
    }
    bdl_checkAssignmentsComplete(state);
}

/* Records a shared (non-varying) field change for a conditional assignment. */
function bdl_sharedFieldChanged(target) {
    var aIdx = parseInt(target.getAttribute('data-action-bdl-aidx'), 10);
    var elementName = target.getAttribute('data-action-bdl-element');
    var state = bdl_curState();
    if (!state || !state.assignments[aIdx]) {
        return;
    }
    var val = target.value.trim();
    if (val) {
        state.assignments[aIdx].sharedFields[elementName] = val;
    } else {
        delete state.assignments[aIdx].sharedFields[elementName];
    }
    bdl_checkAssignmentsComplete(state);
}

/* Records a per-trigger-value change and updates that row's count display. */
function bdl_conditionalValueChanged(target) {
    var aIdx = parseInt(target.getAttribute('data-action-bdl-aidx'), 10);
    var triggerVal = target.getAttribute('data-action-bdl-trigger');
    var state = bdl_curState();
    if (!state || !state.assignments[aIdx]) {
        return;
    }
    var assignment = state.assignments[aIdx];
    var val = target.value.trim();
    if (val) {
        assignment.valueMap[triggerVal] = val;
    } else {
        delete assignment.valueMap[triggerVal];
    }
    if (assignment.resolvedMap) {
        delete assignment.resolvedMap[triggerVal];
    }
    var condField = bdl_assignmentConditionalField(assignment, state);
    bdl_updateTriggerRowDisplay(aIdx, triggerVal, bdl_condRowAddressed(assignment, condField, triggerVal));
    bdl_checkAssignmentsComplete(state);
}

/* Toggles the explicit skip state for one trigger value in an assignment-card
   conditional grid. Skipping clears any mapped value (mutual exclusivity) and
   locks the row; unskipping restores an enterable empty input. */
function bdl_condSkipToggle(target) {
    var aIdx = parseInt(target.getAttribute('data-action-bdl-aidx'), 10);
    var triggerVal = target.getAttribute('data-action-bdl-trigger');
    var state = bdl_curState();
    if (!state || !state.assignments[aIdx]) {
        return;
    }
    var assignment = state.assignments[aIdx];
    if (!assignment.skipMap) {
        assignment.skipMap = {};
    }
    if (assignment.skipMap[triggerVal]) {
        delete assignment.skipMap[triggerVal];
    } else {
        assignment.skipMap[triggerVal] = true;
        delete assignment.valueMap[triggerVal];
        if (assignment.resolvedMap) {
            delete assignment.resolvedMap[triggerVal];
        }
    }
    bdl_renderFixedValueMapping(document.getElementById('bdl-map-validate-area'), state);
}

/* Records a per-trigger-value edit and runs a debounced lookup search. */
function bdl_conditionalValueSearch(target) {
    var aIdx = parseInt(target.getAttribute('data-action-bdl-aidx'), 10);
    var triggerVal = target.getAttribute('data-action-bdl-trigger');
    var state = bdl_curState();
    if (!state || !state.assignments[aIdx]) {
        return;
    }
    var assignment = state.assignments[aIdx];
    var val = target.value.trim();
    if (val) {
        assignment.valueMap[triggerVal] = val;
    } else {
        delete assignment.valueMap[triggerVal];
    }
    if (assignment.resolvedMap) {
        delete assignment.resolvedMap[triggerVal];
    }
    var searchCondField = bdl_assignmentConditionalField(assignment, state);
    bdl_updateTriggerRowDisplay(aIdx, triggerVal, bdl_condRowAddressed(assignment, searchCondField, triggerVal));
    var condField = state.assignments[aIdx].conditionalField;
    var fieldId = 'bdl-cond-' + aIdx + '-' + triggerVal.replace(/[^a-zA-Z0-9]/g, '_');
    var sugEl = document.getElementById('bdl-sug-' + fieldId);
    if (!sugEl) {
        return;
    }
    if (val.length < 2) {
        sugEl.innerHTML = '';
        bdl_checkAssignmentsComplete(state);
        return;
    }
    var field = state.fields.find(function(f) {
        return f.element_name === condField;
    });
    if (!field || !field.lookup_table) {
        bdl_checkAssignmentsComplete(state);
        return;
    }
    if (!state._lookupCache) {
        state._lookupCache = {};
    }
    var cacheKey = condField + '::' + val.toLowerCase();
    if (state._lookupCache[cacheKey]) {
        bdl_renderAssignmentSuggestions(sugEl, state._lookupCache[cacheKey], aIdx, 'conditional', triggerVal);
        bdl_checkAssignmentsComplete(state);
        return;
    }
    if (bdl_searchDebounceTimer) {
        clearTimeout(bdl_searchDebounceTimer);
    }
    sugEl.innerHTML = '<div class="bdl-suggestion-hint">Searching...</div>';
    bdl_searchDebounceTimer = setTimeout(function() {
        fetch('/api/bdl-import/lookup-search?lookup_table=' + encodeURIComponent(field.lookup_table) +
            '&element_name=' + encodeURIComponent(condField) + '&search=' + encodeURIComponent(val) +
            '&config_id=' + encodeURIComponent(bdl_selectedEnvironment.config_id) +
            '&entity_type=' + encodeURIComponent(bdl_curState().entity.entity_type))
            .then(function(r) {
                return r.json();
            }).then(function(data) {
                if (data.error) {
                    sugEl.innerHTML = '<div class="bdl-suggestion-hint bdl-inline-error">' +
                        cc_escapeHtml(data.error) + '</div>';
                    return;
                }
                var values = data.values || [];
                state._lookupCache[cacheKey] = values;
                bdl_renderAssignmentSuggestions(sugEl, values, aIdx, 'conditional', triggerVal);
            }).catch(function() {
                sugEl.innerHTML = '<div class="bdl-suggestion-hint bdl-inline-error">Lookup failed</div>';
            });
    }, 300);
    bdl_checkAssignmentsComplete(state);
}

/* Updates a trigger row's count/skip display after a value change. */
function bdl_updateTriggerRowDisplay(aIdx, triggerVal, isAddressed) {
    var state = bdl_curState();
    if (!state || !state.assignments[aIdx]) {
        return;
    }
    var fieldId = 'bdl-cond-' + aIdx + '-' + triggerVal.replace(/[^a-zA-Z0-9]/g, '_');
    var inputEl = document.getElementById(fieldId);
    if (!inputEl) {
        return;
    }
    bdl_setCondInputSetClass(inputEl, isAddressed);
    var row = inputEl.closest('.bdl-trigger-grid-row');
    if (!row) {
        return;
    }
    var countSpan = row.querySelector('.bdl-trigger-row-count, .bdl-trigger-row-unset');
    if (!countSpan) {
        return;
    }
    var uv = state.assignments[aIdx].triggerUniqueValues ?
        state.assignments[aIdx].triggerUniqueValues.find(function(u) {
            return u.value === triggerVal;
        }) : null;
    if (isAddressed) {
        countSpan.className = 'bdl-trigger-row-count';
        countSpan.textContent = uv ? uv.count.toLocaleString() : '';
    } else {
        countSpan.className = 'bdl-trigger-row-unset';
        countSpan.textContent = 'needs action';
    }
}

/* Renders lookup suggestion items for a blanket or conditional input. */
function bdl_renderAssignmentSuggestions(sugEl, values, aIdx, scope, key) {
    if (values.length === 0) {
        sugEl.innerHTML = '<div class="bdl-suggestion-none">No matches</div>';
        return;
    }
    var html = '';
    values.forEach(function(item) {
        var val = item.value || item;
        html += '<div class="bdl-suggestion-item" data-action-click="bdl-select-assignment-value" ' +
            'data-action-bdl-aidx="' + aIdx + '" data-action-bdl-scope="' + scope + '" ' +
            'data-action-bdl-key="' + cc_escapeHtml(String(key)) + '" ' +
            'data-action-bdl-value="' + cc_escapeHtml(String(val)) + '">' +
            '<span class="bdl-suggestion-value">' + cc_escapeHtml(String(val)) + '</span>';
        if (item.description) {
            html += '<span class="bdl-suggestion-desc">' + cc_escapeHtml(item.description) + '</span>';
        }
        html += '</div>';
    });
    sugEl.innerHTML = html;
}

/* Handles the fixed-value identifier select change, (re)mapping the ID column. */
function bdl_fixedValueIdentifierChanged() {
    var area = document.getElementById('bdl-map-validate-area');
    var idSel = document.getElementById('bdl-identifier-column');
    var idElem = area._identifierElementName;
    var state = bdl_curState();
    if (!state) {
        return;
    }
    var cm = state.columnMapping;
    var k;
    for (k in cm) {
        if (cm[k] === idElem) {
            delete cm[k];
        }
    }
    if (idSel.value !== '') {
        cm[bdl_parsedFileData.headers[parseInt(idSel.value, 10)]] = idElem;
    }
    var idSection = document.querySelector('.bdl-mapping-identifier');
    var assignArea = document.getElementById('bdl-assignment-area');
    if (idSel.value !== '') {
        if (idSection) {
            idSection.classList.remove('bdl-identifier-pending');
            idSection.classList.add('bdl-identifier-confirmed');
        }
        if (assignArea) {
            assignArea.classList.remove('bdl-mapping-disabled');
            var msg = assignArea.querySelector('.bdl-mapping-disabled-msg');
            if (msg) {
                msg.remove();
            }
        }
    } else {
        if (idSection) {
            idSection.classList.remove('bdl-identifier-confirmed');
            idSection.classList.add('bdl-identifier-pending');
        }
        if (assignArea) {
            assignArea.classList.add('bdl-mapping-disabled');
        }
    }
    bdl_checkAssignmentsComplete(state);
}

/* Enables the Validate button when all assignments are sufficiently complete. */
function bdl_checkAssignmentsComplete(state) {
    if (!state) {
        return;
    }
    var area = document.getElementById('bdl-map-validate-area');
    var idElem = area ? area._identifierElementName : '';
    var hasIdentifier = false;
    var k;
    for (k in state.columnMapping) {
        if (state.columnMapping[k] === idElem) {
            hasIdentifier = true;
            break;
        }
    }
    var valBtn = document.getElementById('bdl-btn-validate-entity');
    if (!hasIdentifier || !state.assignments || state.assignments.length === 0) {
        if (valBtn) {
            valBtn.disabled = true;
            bdl_setEnabledClass(valBtn, false);
        }
        return;
    }
    var allComplete = true;
    var valueFields = area ? area._valueFields || [] : [];
    state.assignments.forEach(function(a) {
        if (a.mode === 'blanket') {
            valueFields.forEach(function(f) {
                if (f.is_import_required && !a.fixedValues[f.element_name]) {
                    allComplete = false;
                }
            });
        } else if (a.mode === 'from_file') {
            if (!a.fileColumn) {
                allComplete = false;
                return;
            }
        } else if (a.mode === 'conditional') {
            if (!a.triggerColumn || !a.triggerUniqueValues) {
                allComplete = false;
                return;
            }
            var condFields = area ? area._conditionalFields || [] : [];
            var aCondField = condFields.length > 0 ? condFields[0] : null;
            var skipMap = a.skipMap || {};
            var allAddressed = a.triggerUniqueValues.every(function(uv) {
                return bdl_condRowAddressed(a, aCondField, uv.value) || skipMap[uv.value];
            });
            if (!allAddressed) {
                allComplete = false;
            }
        }
    });
    if (valBtn) {
        valBtn.disabled = !allComplete;
        bdl_setEnabledClass(valBtn, allComplete);
    }
}

/* ============================================================================
   FUNCTIONS: STEP 4 FIELD ASSIGNMENTS
   ----------------------------------------------------------------------------
   The per-field mode override for conditional-eligible fields in FILE_MAPPED
   entities: pulling a field out of the drag-drop target panel into a blanket
   or conditional field-assignment card, with its own trigger grid, typeahead,
   and value handlers.
   Prefix: bdl
   ============================================================================ */

/* Switches a conditional-eligible field between file, blanket, and
   conditional assignment modes. */
function bdl_toggleFieldMode(target) {
    var elementName = target.getAttribute('data-action-bdl-element');
    var mode = target.getAttribute('data-action-bdl-mode');
    var state = bdl_curState();
    if (!state) {
        return;
    }
    if (!state.fieldAssignments) {
        state.fieldAssignments = {};
    }
    if (mode === 'from_file') {
        delete state.fieldAssignments[elementName];
    } else {
        state.fieldAssignments[elementName] = {
            mode: mode,
            value: '',
            triggerColumn: null,
            conditionalField: elementName,
            valueMap: {},
            triggerUniqueValues: null,
            _showAllTriggerValues: false
        };
    }
    bdl_refreshMappingPanels();
}

/* Renders the field-assignments section beneath the mapping panels. */
function bdl_renderFieldAssignmentsSection(state) {
    var container = document.getElementById('bdl-field-assignments-area');
    if (!container) {
        return;
    }
    if (!state.fieldAssignments || Object.keys(state.fieldAssignments).length === 0) {
        container.innerHTML = '';
        return;
    }
    var html = '<div class="bdl-field-assignments-section">';
    html += '<div class="bdl-panel-header bdl-field-assignments-header">Field Assignments</div>';
    html += '<div class="bdl-field-assignments-list">';
    Object.keys(state.fieldAssignments).forEach(function(elemName) {
        var fa = state.fieldAssignments[elemName];
        html += bdl_renderFieldAssignmentCard(elemName, fa, state);
    });
    html += '</div></div>';
    container.innerHTML = html;
}

/* Resolves the conditional field object for an assignment-card from the stored
   conditionalField element name, or the area's conditional field list. */
function bdl_assignmentConditionalField(assignment, state) {
    var area = document.getElementById('bdl-map-validate-area');
    if (assignment.conditionalField && state.fields) {
        var byName = state.fields.find(function(f) {
            return f.element_name === assignment.conditionalField;
        });
        if (byName) {
            return byName;
        }
    }
    if (area && area._conditionalFields && area._conditionalFields.length > 0) {
        return area._conditionalFields[0];
    }
    return null;
}

/* Returns true when a conditional trigger-value row is addressed: for a
   lookup-backed field this requires a confirmed match selection; for a plain
   field any non-empty value counts. Skip is handled separately. */
function bdl_condRowAddressed(fa, field, triggerVal) {
    if (field && field.lookup_table) {
        return !!(fa.resolvedMap && fa.resolvedMap[triggerVal]);
    }
    var v = fa.valueMap ? fa.valueMap[triggerVal] : null;
    return !!(v && v.trim() !== '');
}

/* Toggles the value-set accent class on a conditional grid input. */
function bdl_setCondInputSetClass(inputEl, isSet) {
    if (!inputEl) {
        return;
    }
    if (isSet) {
        inputEl.classList.add('bdl-trigger-grid-input-set');
    } else {
        inputEl.classList.remove('bdl-trigger-grid-input-set');
    }
}

/* Returns true when a field assignment has everything it needs: a blanket
   assignment has a value for a required field, and a conditional assignment has
   a trigger column, scanned values, and at least one mapped value. Used both to
   gate Validate and to drive the card's complete-state header. */
function bdl_fieldAssignmentComplete(state, elementName, fa) {
    if (!fa) {
        return false;
    }
    if (fa.mode === 'blanket') {
        var field = state.fields ? state.fields.find(function(f) {
            return f.element_name === elementName;
        }) : null;
        if (field && field.lookup_table) {
            return !!fa.valueResolved;
        }
        if (field && field.is_import_required && !fa.value) {
            return false;
        }
        return true;
    }
    if (fa.mode === 'conditional') {
        if (!fa.triggerColumn || !fa.triggerUniqueValues) {
            return false;
        }
        var condField = state.fields ? state.fields.find(function(f) {
            return f.element_name === elementName;
        }) : null;
        var skipMap = fa.skipMap || {};
        return fa.triggerUniqueValues.every(function(uv) {
            return bdl_condRowAddressed(fa, condField, uv.value) || skipMap[uv.value];
        });
    }
    return true;
}

/* Builds one field-assignment card with its mode toggle and body. */
function bdl_renderFieldAssignmentCard(elementName, fa, state) {
    var field = state.fields ? state.fields.find(function(f) {
        return f.element_name === elementName;
    }) : null;
    var displayName = field ? bdl_getFieldDisplayName(field) : elementName;
    var modeBadgeClass = fa.mode === 'conditional' ? 'bdl-assignment-badge-conditional' : 'bdl-assignment-badge-blanket';
    var modeBadgeLabel = fa.mode === 'conditional' ? 'Conditional' : 'Blanket';
    var completeCls = bdl_fieldAssignmentComplete(state, elementName, fa) ? ' bdl-assignment-complete' : '';
    var html = '<div class="bdl-assignment-card bdl-field-assignment-card">';
    html += '<div class="bdl-assignment-header bdl-field-assignment-header' + completeCls +
        '" data-bdl-fa-element="' + elementName + '"><div class="bdl-assignment-title">';
    html += '<span class="bdl-field-assignment-name">' + cc_escapeHtml(displayName) + '</span>';
    if (bdl_hasDisplayName(field)) {
        html += ' <code class="bdl-field-assignment-elem">' + elementName + '</code>';
    }
    html += ' <span class="bdl-assignment-mode-badge ' + modeBadgeClass + '">' + modeBadgeLabel + '</span>';
    html += '</div>';
    html += '<span class="bdl-assignment-remove bdl-field-assignment-remove" data-action-click="bdl-field-mode" ' +
        'data-action-bdl-element="' + elementName + '" data-action-bdl-mode="from_file" ' +
        'title="Return to file mapping">&#8592; File</span>';
    html += '</div>';
    var blanketCls = fa.mode === 'blanket' ? ' bdl-assignment-toggle-active-blanket' : '';
    var condCls = fa.mode === 'conditional' ? ' bdl-assignment-toggle-active-cond' : '';
    html += '<div class="bdl-assignment-mode-toggle">';
    html += '<div class="bdl-assignment-toggle-btn bdl-toggle-first' + blanketCls + '" ' +
        'data-action-click="bdl-switch-field-mode" data-action-bdl-element="' + elementName + '" ' +
        'data-action-bdl-mode="blanket">Blanket</div>';
    html += '<div class="bdl-assignment-toggle-btn bdl-toggle-last' + condCls + '" ' +
        'data-action-click="bdl-switch-field-mode" data-action-bdl-element="' + elementName + '" ' +
        'data-action-bdl-mode="conditional">Conditional</div>';
    html += '</div>';
    html += '<div class="bdl-assignment-body">';
    if (fa.mode === 'blanket') {
        html += bdl_renderFieldBlanketInput(elementName, fa, field);
    } else {
        html += bdl_renderFieldConditionalInput(elementName, fa, field, state);
    }
    html += '</div></div>';
    return html;
}

/* Returns the value-set class suffix when a blanket value is non-empty, so a
   filled value reads in the accent color like a conditional mapped value. */
function bdl_valueSetClass(val) {
    return (val && String(val).trim() !== '') ? ' bdl-value-set' : '';
}

/* Builds the blanket-value input for a field assignment. */
function bdl_renderFieldBlanketInput(elementName, fa, field) {
    var fieldId = 'bdl-fa-blanket-' + elementName.replace(/[^a-zA-Z0-9]/g, '');
    var existingVal = fa.value || '';
    var html = '<div class="bdl-fixed-value-row"><div class="bdl-fixed-value-label">Value for all rows';
    if (field && field.import_guidance) {
        html += '<div class="bdl-fixed-value-guidance">' + cc_escapeHtml(field.import_guidance) + '</div>';
    }
    html += '</div><div class="bdl-fixed-value-input">';
    var actionAttrs = 'data-action-change="bdl-field-assignment-changed" data-action-bdl-element="' + elementName + '"';
    if (field && bdl_isBooleanField(field)) {
        if (!existingVal) {
            existingVal = 'N';
            fa.value = 'N';
        }
        html += bdl_buildBooleanSelect(fieldId, existingVal, actionAttrs);
    } else if (field && field.lookup_table) {
        var lookupSetCls = fa.valueResolved ? ' bdl-value-set' : '';
        html += '<input type="text" id="' + fieldId + '" class="bdl-fixed-value-text' + lookupSetCls + '" ' +
            'placeholder="Type to search..." value="' + cc_escapeHtml(existingVal) + '" ' +
            'data-action-input="bdl-field-assignment-search" data-action-bdl-element="' + elementName + '" ' +
            'autocomplete="off"><div class="bdl-fixed-value-suggestions" id="bdl-sug-' + fieldId + '"></div>';
    } else {
        html += '<input type="text" id="' + fieldId + '" class="bdl-fixed-value-text' + bdl_valueSetClass(existingVal) + '" ' +
            'placeholder="Enter value" value="' + cc_escapeHtml(existingVal) + '" ' +
            'data-action-input="bdl-field-assignment-changed" data-action-bdl-element="' + elementName + '">';
    }
    if (field) {
        var meta = bdl_buildFieldMeta(field);
        if (meta) {
            html += '<div class="bdl-fixed-value-meta">' + meta + '</div>';
        }
    }
    html += '</div></div>';
    return html;
}

/* Builds the conditional trigger grid for a field assignment. */
function bdl_renderFieldConditionalInput(elementName, fa, field, state) {
    var html = '';
    html += '<div class="bdl-trigger-section"><div class="bdl-trigger-label">' +
        '<span class="bdl-trigger-label-icon">&#9881;</span> Trigger column</div>';
    html += '<select class="bdl-identifier-dropdown bdl-trigger-dropdown" id="bdl-fa-trigger-' +
        elementName.replace(/[^a-zA-Z0-9]/g, '') + '" data-action-change="bdl-set-field-trigger-column" ' +
        'data-action-bdl-element="' + elementName + '"><option value="">&mdash; Select trigger column &mdash;</option>';
    bdl_parsedFileData.headers.forEach(function(header, idx) {
        var sample = (bdl_parsedFileData.rows[0] && bdl_parsedFileData.rows[0][idx]) ?
            bdl_parsedFileData.rows[0][idx] : '';
        var sel = (fa.triggerColumn === header) ? ' selected' : '';
        html += '<option value="' + cc_escapeHtml(header) + '"' + sel + '>' +
            cc_escapeHtml(header + (sample ? '  (' + sample.substring(0, 20) + ')' : '')) + '</option>';
    });
    html += '</select>';
    if (fa.triggerColumn && field) {
        var dn = field ? bdl_getFieldDisplayName(field) : elementName;
        html += '<div class="bdl-trigger-note">&#9432; Unique values from "' + cc_escapeHtml(fa.triggerColumn) +
            '" mapped to <code class="bdl-trigger-note-code">' + cc_escapeHtml(dn) + '</code></div>';
    }
    html += '</div>';
    if (fa.triggerColumn && fa.triggerUniqueValues) {
        var uniqueVals = fa.triggerUniqueValues;
        var showAll = fa._showAllTriggerValues || false;
        var maxVisible = 15;
        var displayVals = showAll ? uniqueVals : uniqueVals.slice(0, maxVisible);
        var hasMore = uniqueVals.length > maxVisible && !showAll;
        html += '<div class="bdl-trigger-grid"><div class="bdl-trigger-grid-header"><span>Trigger value</span><span>' +
            (field ? bdl_getFieldDisplayName(field) : elementName) +
            '</span><span class="bdl-trigger-grid-header-rows">Rows</span></div>';
        displayVals.forEach(function(uv) {
            var fieldId = 'bdl-fa-cond-' + elementName.replace(/[^a-zA-Z0-9]/g, '') + '-' +
                uv.value.replace(/[^a-zA-Z0-9]/g, '_');
            var existingVal = fa.valueMap[uv.value] || '';
            var isSkipped = !!(fa.skipMap && fa.skipMap[uv.value]);
            var addressed = bdl_condRowAddressed(fa, field, uv.value);
            var setCls = addressed ? ' bdl-trigger-grid-input-set' : '';
            var rowCls = isSkipped ? 'bdl-trigger-grid-row bdl-trigger-row-skipped' : 'bdl-trigger-grid-row';
            html += '<div class="' + rowCls + '"><span class="bdl-trigger-val">' +
                '<code class="bdl-trigger-val-code">' + cc_escapeHtml(uv.value) + '</code></span>' +
                '<span class="bdl-trigger-input-cell">';
            var actionAttrs = 'data-action-change="bdl-field-cond-value-changed" data-action-bdl-element="' +
                elementName + '" data-action-bdl-trigger="' + cc_escapeHtml(uv.value) + '"';
            var disabledAttr = isSkipped ? ' disabled' : '';
            if (field && bdl_isBooleanField(field)) {
                html += bdl_buildBooleanSelect(fieldId, existingVal, actionAttrs + disabledAttr);
            } else if (field && field.lookup_table) {
                html += '<input type="text" id="' + fieldId + '" class="bdl-trigger-grid-input' + setCls + '" ' +
                    'placeholder="Type to search..." value="' + cc_escapeHtml(existingVal) + '"' + disabledAttr + ' ' +
                    'data-action-input="bdl-field-cond-value-search" data-action-bdl-element="' + elementName + '" ' +
                    'data-action-bdl-trigger="' + cc_escapeHtml(uv.value) + '" autocomplete="off">' +
                    '<div class="bdl-fixed-value-suggestions" id="bdl-sug-' + fieldId + '"></div>';
            } else {
                html += '<input type="text" id="' + fieldId + '" class="bdl-trigger-grid-input' + setCls + '" ' +
                    'placeholder="Enter value or skip" value="' + cc_escapeHtml(existingVal) + '"' + disabledAttr + ' ' +
                    'data-action-input="bdl-field-cond-value-changed" data-action-bdl-element="' + elementName + '" ' +
                    'data-action-bdl-trigger="' + cc_escapeHtml(uv.value) + '">';
            }
            html += '</span>';
            html += bdl_renderTriggerRowEnd(uv, addressed, isSkipped,
                'bdl-fa-cond-skip', 'data-action-bdl-element="' + elementName + '"');
            html += '</div>';
        });
        if (hasMore) {
            html += '<div class="bdl-trigger-grid-show-all" data-action-click="bdl-show-all-field-triggers" ' +
                'data-action-bdl-element="' + elementName + '">+ ' + (uniqueVals.length - maxVisible) +
                ' more values &mdash; show all</div>';
        }
        html += '</div>';
    } else if (fa.triggerColumn && !fa.triggerUniqueValues) {
        html += '<div class="bdl-loading">Scanning file for unique values...</div>';
    }
    return html;
}

/* Switches a field assignment between blanket and conditional mode. */
function bdl_switchFieldMode(target) {
    var elementName = target.getAttribute('data-action-bdl-element');
    var mode = target.getAttribute('data-action-bdl-mode');
    var state = bdl_curState();
    if (!state || !state.fieldAssignments || !state.fieldAssignments[elementName]) {
        return;
    }
    if (state.fieldAssignments[elementName].mode === mode) {
        return;
    }
    state.fieldAssignments[elementName].mode = mode;
    state.fieldAssignments[elementName].value = '';
    state.fieldAssignments[elementName].valueResolved = false;
    state.fieldAssignments[elementName].triggerColumn = null;
    state.fieldAssignments[elementName].valueMap = {};
    state.fieldAssignments[elementName].triggerUniqueValues = null;
    state.fieldAssignments[elementName]._showAllTriggerValues = false;
    bdl_refreshMappingPanels();
}

/* Records a blanket field-assignment value change. */
function bdl_fieldAssignmentValueChanged(target) {
    var elementName = target.getAttribute('data-action-bdl-element');
    var state = bdl_curState();
    if (!state || !state.fieldAssignments || !state.fieldAssignments[elementName]) {
        return;
    }
    state.fieldAssignments[elementName].value = target.value.trim();
    bdl_checkMappingComplete();
}

/* Records a blanket field-assignment edit and runs a debounced lookup search. */
function bdl_fieldAssignmentSearch(target) {
    var elementName = target.getAttribute('data-action-bdl-element');
    var state = bdl_curState();
    if (!state || !state.fieldAssignments || !state.fieldAssignments[elementName]) {
        return;
    }
    state.fieldAssignments[elementName].value = target.value.trim();
    state.fieldAssignments[elementName].valueResolved = false;
    var val = target.value.trim();
    var fieldId = 'bdl-fa-blanket-' + elementName.replace(/[^a-zA-Z0-9]/g, '');
    var sugEl = document.getElementById('bdl-sug-' + fieldId);
    if (!sugEl) {
        return;
    }
    if (val.length < 2) {
        sugEl.innerHTML = '';
        bdl_checkMappingComplete();
        return;
    }
    var field = state.fields.find(function(f) {
        return f.element_name === elementName;
    });
    if (!field || !field.lookup_table) {
        bdl_checkMappingComplete();
        return;
    }
    if (!state._lookupCache) {
        state._lookupCache = {};
    }
    var cacheKey = elementName + '::' + val.toLowerCase();
    if (state._lookupCache[cacheKey]) {
        bdl_renderFieldSuggestions(sugEl, state._lookupCache[cacheKey], elementName);
        bdl_checkMappingComplete();
        return;
    }
    if (bdl_searchDebounceTimer) {
        clearTimeout(bdl_searchDebounceTimer);
    }
    sugEl.innerHTML = '<div class="bdl-suggestion-hint">Searching...</div>';
    bdl_searchDebounceTimer = setTimeout(function() {
        fetch('/api/bdl-import/lookup-search?lookup_table=' + encodeURIComponent(field.lookup_table) +
            '&element_name=' + encodeURIComponent(elementName) + '&search=' + encodeURIComponent(val) +
            '&config_id=' + encodeURIComponent(bdl_selectedEnvironment.config_id) +
            '&entity_type=' + encodeURIComponent(bdl_curState().entity.entity_type))
            .then(function(r) {
                return r.json();
            }).then(function(data) {
                if (data.error) {
                    sugEl.innerHTML = '<div class="bdl-suggestion-hint bdl-inline-error">' +
                        cc_escapeHtml(data.error) + '</div>';
                    return;
                }
                var values = data.values || [];
                state._lookupCache[cacheKey] = values;
                bdl_renderFieldSuggestions(sugEl, values, elementName);
            }).catch(function() {
                sugEl.innerHTML = '<div class="bdl-suggestion-hint bdl-inline-error">Lookup failed</div>';
            });
    }, 300);
    bdl_checkMappingComplete();
}

/* Applies a selected suggestion to a blanket field assignment. */
function bdl_selectFieldAssignmentValue(target) {
    var elementName = target.getAttribute('data-action-bdl-element');
    var value = target.getAttribute('data-action-bdl-value');
    var state = bdl_curState();
    if (!state || !state.fieldAssignments || !state.fieldAssignments[elementName]) {
        return;
    }
    var fieldId = 'bdl-fa-blanket-' + elementName.replace(/[^a-zA-Z0-9]/g, '');
    var input = document.getElementById(fieldId);
    if (input) {
        input.value = value;
    }
    state.fieldAssignments[elementName].value = value;
    state.fieldAssignments[elementName].valueResolved = true;
    var sugEl = document.getElementById('bdl-sug-' + fieldId);
    if (sugEl) {
        sugEl.innerHTML = '';
    }
    bdl_checkMappingComplete();
}

/* Sets a field assignment's trigger column and scans for unique values. */
function bdl_setFieldTriggerColumn(target) {
    var elementName = target.getAttribute('data-action-bdl-element');
    var state = bdl_curState();
    if (!state || !state.fieldAssignments || !state.fieldAssignments[elementName]) {
        return;
    }
    var selId = 'bdl-fa-trigger-' + elementName.replace(/[^a-zA-Z0-9]/g, '');
    var sel = document.getElementById(selId);
    var headerName = sel ? sel.value : '';
    var fa = state.fieldAssignments[elementName];
    if (!headerName) {
        fa.triggerColumn = null;
        fa.triggerUniqueValues = null;
        fa.valueMap = {};
        fa._showAllTriggerValues = false;
        bdl_refreshMappingPanels();
        return;
    }
    fa.triggerColumn = headerName;
    fa.triggerUniqueValues = null;
    fa.valueMap = {};
    fa._showAllTriggerValues = false;
    bdl_refreshMappingPanels();
    var headerIndex = bdl_parsedFileData.headers.indexOf(headerName);
    if (headerIndex < 0) {
        return;
    }
    bdl_readFileColumnValues(headerIndex, function(uniqueValues) {
        var currentState = bdl_curState();
        if (!currentState || !currentState.fieldAssignments || !currentState.fieldAssignments[elementName]) {
            return;
        }
        if (currentState.fieldAssignments[elementName].triggerColumn !== headerName) {
            return;
        }
        currentState.fieldAssignments[elementName].triggerUniqueValues = uniqueValues;
        bdl_refreshMappingPanels();
    });
}

/* Records a per-trigger field-assignment change and updates the row display. */
function bdl_fieldCondValueChanged(target) {
    var elementName = target.getAttribute('data-action-bdl-element');
    var triggerVal = target.getAttribute('data-action-bdl-trigger');
    var state = bdl_curState();
    if (!state || !state.fieldAssignments || !state.fieldAssignments[elementName]) {
        return;
    }
    var fa = state.fieldAssignments[elementName];
    var val = target.value.trim();
    if (val) {
        fa.valueMap[triggerVal] = val;
    } else {
        delete fa.valueMap[triggerVal];
    }
    if (fa.resolvedMap) {
        delete fa.resolvedMap[triggerVal];
    }
    var field = state.fields ? state.fields.find(function(f) {
        return f.element_name === elementName;
    }) : null;
    var addressed = bdl_condRowAddressed(fa, field, triggerVal);
    var fieldId = 'bdl-fa-cond-' + elementName.replace(/[^a-zA-Z0-9]/g, '') + '-' +
        triggerVal.replace(/[^a-zA-Z0-9]/g, '_');
    var inputEl = document.getElementById(fieldId);
    if (inputEl) {
        bdl_setCondInputSetClass(inputEl, addressed);
        var row = inputEl.closest('.bdl-trigger-grid-row');
        if (row) {
            var countSpan = row.querySelector('.bdl-trigger-row-count, .bdl-trigger-row-unset');
            if (countSpan) {
                var uv = fa.triggerUniqueValues ? fa.triggerUniqueValues.find(function(u) {
                    return u.value === triggerVal;
                }) : null;
                if (addressed) {
                    countSpan.className = 'bdl-trigger-row-count';
                    countSpan.textContent = uv ? uv.count.toLocaleString() : '';
                } else {
                    countSpan.className = 'bdl-trigger-row-unset';
                    countSpan.textContent = 'needs action';
                }
            }
        }
    }
    bdl_checkMappingComplete();
}

/* Toggles the explicit skip state for one trigger value in a field-assignment
   conditional grid. Skipping clears any mapped value (mutual exclusivity) and
   locks the row; unskipping restores an enterable empty input. */
function bdl_fieldCondSkipToggle(target) {
    var elementName = target.getAttribute('data-action-bdl-element');
    var triggerVal = target.getAttribute('data-action-bdl-trigger');
    var state = bdl_curState();
    if (!state || !state.fieldAssignments || !state.fieldAssignments[elementName]) {
        return;
    }
    var fa = state.fieldAssignments[elementName];
    if (!fa.skipMap) {
        fa.skipMap = {};
    }
    if (fa.skipMap[triggerVal]) {
        delete fa.skipMap[triggerVal];
    } else {
        fa.skipMap[triggerVal] = true;
        delete fa.valueMap[triggerVal];
        if (fa.resolvedMap) {
            delete fa.resolvedMap[triggerVal];
        }
    }
    bdl_refreshMappingPanels();
}

/* Records a per-trigger field-assignment edit and runs a debounced lookup. */
function bdl_fieldCondValueSearch(target) {
    var elementName = target.getAttribute('data-action-bdl-element');
    var triggerVal = target.getAttribute('data-action-bdl-trigger');
    var state = bdl_curState();
    if (!state || !state.fieldAssignments || !state.fieldAssignments[elementName]) {
        return;
    }
    var fa = state.fieldAssignments[elementName];
    var val = target.value.trim();
    if (val) {
        fa.valueMap[triggerVal] = val;
    } else {
        delete fa.valueMap[triggerVal];
    }
    if (fa.resolvedMap) {
        delete fa.resolvedMap[triggerVal];
    }
    var searchField = state.fields ? state.fields.find(function(f) {
        return f.element_name === elementName;
    }) : null;
    var fieldId = 'bdl-fa-cond-' + elementName.replace(/[^a-zA-Z0-9]/g, '') + '-' +
        triggerVal.replace(/[^a-zA-Z0-9]/g, '_');
    var rowInput = document.getElementById(fieldId);
    if (rowInput) {
        var addressedNow = bdl_condRowAddressed(fa, searchField, triggerVal);
        bdl_setCondInputSetClass(rowInput, addressedNow);
        var rowEl = rowInput.closest('.bdl-trigger-grid-row');
        if (rowEl) {
            var statusSpan = rowEl.querySelector('.bdl-trigger-row-count, .bdl-trigger-row-unset');
            if (statusSpan) {
                var rowUv = fa.triggerUniqueValues ? fa.triggerUniqueValues.find(function(u) {
                    return u.value === triggerVal;
                }) : null;
                if (addressedNow) {
                    statusSpan.className = 'bdl-trigger-row-count';
                    statusSpan.textContent = rowUv ? rowUv.count.toLocaleString() : '';
                } else {
                    statusSpan.className = 'bdl-trigger-row-unset';
                    statusSpan.textContent = 'needs action';
                }
            }
        }
    }
    var sugEl = document.getElementById('bdl-sug-' + fieldId);
    if (!sugEl) {
        return;
    }
    if (val.length < 2) {
        sugEl.innerHTML = '';
        bdl_checkMappingComplete();
        return;
    }
    var field = state.fields.find(function(f) {
        return f.element_name === elementName;
    });
    if (!field || !field.lookup_table) {
        bdl_checkMappingComplete();
        return;
    }
    if (!state._lookupCache) {
        state._lookupCache = {};
    }
    var cacheKey = elementName + '::' + val.toLowerCase();
    if (state._lookupCache[cacheKey]) {
        bdl_renderFieldSuggestions(sugEl, state._lookupCache[cacheKey], elementName, triggerVal);
        bdl_checkMappingComplete();
        return;
    }
    if (bdl_searchDebounceTimer) {
        clearTimeout(bdl_searchDebounceTimer);
    }
    sugEl.innerHTML = '<div class="bdl-suggestion-hint">Searching...</div>';
    bdl_searchDebounceTimer = setTimeout(function() {
        fetch('/api/bdl-import/lookup-search?lookup_table=' + encodeURIComponent(field.lookup_table) +
            '&element_name=' + encodeURIComponent(elementName) + '&search=' + encodeURIComponent(val) +
            '&config_id=' + encodeURIComponent(bdl_selectedEnvironment.config_id) +
            '&entity_type=' + encodeURIComponent(bdl_curState().entity.entity_type))
            .then(function(r) {
                return r.json();
            }).then(function(data) {
                if (data.error) {
                    sugEl.innerHTML = '<div class="bdl-suggestion-hint bdl-inline-error">' +
                        cc_escapeHtml(data.error) + '</div>';
                    return;
                }
                var values = data.values || [];
                state._lookupCache[cacheKey] = values;
                bdl_renderFieldSuggestions(sugEl, values, elementName, triggerVal);
            }).catch(function() {
                sugEl.innerHTML = '<div class="bdl-suggestion-hint bdl-inline-error">Lookup failed</div>';
            });
    }, 300);
    bdl_checkMappingComplete();
}

/* Applies a selected suggestion to a per-trigger field-assignment value. */
function bdl_selectFieldCondValue(target) {
    var elementName = target.getAttribute('data-action-bdl-element');
    var triggerVal = target.getAttribute('data-action-bdl-trigger');
    var value = target.getAttribute('data-action-bdl-value');
    var state = bdl_curState();
    if (!state || !state.fieldAssignments || !state.fieldAssignments[elementName]) {
        return;
    }
    var fieldId = 'bdl-fa-cond-' + elementName.replace(/[^a-zA-Z0-9]/g, '') + '-' +
        triggerVal.replace(/[^a-zA-Z0-9]/g, '_');
    var input = document.getElementById(fieldId);
    if (input) {
        input.value = value;
    }
    state.fieldAssignments[elementName].valueMap[triggerVal] = value;
    if (!state.fieldAssignments[elementName].resolvedMap) {
        state.fieldAssignments[elementName].resolvedMap = {};
    }
    state.fieldAssignments[elementName].resolvedMap[triggerVal] = true;
    var sugEl = document.getElementById('bdl-sug-' + fieldId);
    if (sugEl) {
        sugEl.innerHTML = '';
    }
    var inputEl = document.getElementById(fieldId);
    if (inputEl) {
        bdl_setCondInputSetClass(inputEl, true);
        var row = inputEl.closest('.bdl-trigger-grid-row');
        if (row) {
            var countSpan = row.querySelector('.bdl-trigger-row-count, .bdl-trigger-row-unset');
            if (countSpan) {
                var fa = state.fieldAssignments[elementName];
                var uv = fa.triggerUniqueValues ? fa.triggerUniqueValues.find(function(u) {
                    return u.value === triggerVal;
                }) : null;
                countSpan.className = 'bdl-trigger-row-count';
                countSpan.textContent = uv ? uv.count.toLocaleString() : '';
            }
        }
    }
    bdl_checkMappingComplete();
}

/* Expands a field assignment's trigger grid to show all unique values. */
function bdl_showAllFieldTriggerValues(target) {
    var elementName = target.getAttribute('data-action-bdl-element');
    var state = bdl_curState();
    if (!state || !state.fieldAssignments || !state.fieldAssignments[elementName]) {
        return;
    }
    state.fieldAssignments[elementName]._showAllTriggerValues = true;
    bdl_refreshMappingPanels();
}

/* Renders lookup suggestions for a blanket or conditional field assignment. */
function bdl_renderFieldSuggestions(sugEl, values, elementName, triggerVal) {
    if (values.length === 0) {
        sugEl.innerHTML = '<div class="bdl-suggestion-none">No matches</div>';
        return;
    }
    var html = '';
    values.forEach(function(item) {
        var val = item.value || item;
        if (triggerVal !== undefined) {
            html += '<div class="bdl-suggestion-item" data-action-click="bdl-select-field-cond-value" ' +
                'data-action-bdl-element="' + cc_escapeHtml(String(elementName)) + '" ' +
                'data-action-bdl-trigger="' + cc_escapeHtml(String(triggerVal)) + '" ' +
                'data-action-bdl-value="' + cc_escapeHtml(String(val)) + '">';
        } else {
            html += '<div class="bdl-suggestion-item" data-action-click="bdl-select-field-value" ' +
                'data-action-bdl-element="' + cc_escapeHtml(String(elementName)) + '" ' +
                'data-action-bdl-value="' + cc_escapeHtml(String(val)) + '">';
        }
        html += '<span class="bdl-suggestion-value">' + cc_escapeHtml(String(val)) + '</span>';
        if (item.description) {
            html += '<span class="bdl-suggestion-desc">' + cc_escapeHtml(item.description) + '</span>';
        }
        html += '</div>';
    });
    sugEl.innerHTML = html;
}

/* ============================================================================
   FUNCTIONS: STEP 4 COMPOSED MESSAGE BUILDER
   ----------------------------------------------------------------------------
   The AR Log message builder: a per-row message composer that owns one field
   on one entity (gated by bdl_COMPOSED_MESSAGE_ENTITY and
   bdl_COMPOSED_MESSAGE_ELEMENT). The message is built from an ordered list of
   segments, each either literal text or a file-column reference, woven
   together left to right. A fallback value covers rows whose composed result
   is empty. The composed template travels to the server as composed_message
   and is written into the message column during staging.
   Prefix: bdl
   ============================================================================ */

/* Returns true when the builder owns the current entity's message field. */
function bdl_isComposedMessageActive(state) {
    if (!state || !state.entity) {
        return false;
    }
    if (state.entity.entity_type !== bdl_COMPOSED_MESSAGE_ENTITY) {
        return false;
    }
    if (!state.fields) {
        return false;
    }
    return state.fields.some(function(f) {
        return f.element_name === bdl_COMPOSED_MESSAGE_ELEMENT &&
            f.is_visible !== 0 && f.is_visible !== false;
    });
}

/* Ensures the current entity has a composed-message template, seeding one
   empty text segment and the default fallback on first use. */
function bdl_ensureComposedMessage(state) {
    if (!state.composedMessage) {
        state.composedMessage = {
            segments: [{ type: 'text', value: '', header: null, sep: '' }],
            fallback: bdl_COMPOSED_MESSAGE_DEFAULT_FALLBACK
        };
    }
    return state.composedMessage;
}

/* Returns true when a segment contributes content (text with characters, or a
   field with a chosen column). */
function bdl_composedSegmentUsable(seg) {
    if (!seg) {
        return false;
    }
    if (seg.type === 'text') {
        return !!(seg.value && seg.value.length > 0);
    }
    if (seg.type === 'field') {
        return !!seg.header;
    }
    return false;
}

/* Returns true when the template has at least one usable segment. */
function bdl_composedMessageReady(state) {
    if (!bdl_isComposedMessageActive(state)) {
        return true;
    }
    if (!state.composedMessage || !state.composedMessage.segments) {
        return false;
    }
    return state.composedMessage.segments.some(bdl_composedSegmentUsable);
}

/* Serializes the composed message for the stage request, keeping only usable
   segments and the fallback. Field segments carry their header; text segments
   carry their literal value; each carries its trailing separator. */
function bdl_serializeComposedMessage(cm) {
    var segments = cm.segments.filter(bdl_composedSegmentUsable).map(function(seg) {
        if (seg.type === 'field') {
            return { type: 'field', header: seg.header, sep: seg.sep || '' };
        }
        return { type: 'text', value: seg.value, sep: seg.sep || '' };
    });
    return { segments: segments, fallback: cm.fallback || '' };
}

/* Composes the preview string for a segment list using the first file row as
   sample data, appending each usable segment's trailing separator (except the
   last) and substituting the fallback when the result is empty. Mirrors the
   server-side composition so the preview matches what each row will receive. */
function bdl_composedMessagePreview(cm) {
    var sampleRow = (bdl_parsedFileData && bdl_parsedFileData.rows && bdl_parsedFileData.rows[0]) ?
        bdl_parsedFileData.rows[0] : null;
    var usable = cm.segments.filter(bdl_composedSegmentUsable);
    var composed = '';
    usable.forEach(function(seg, i) {
        var piece;
        if (seg.type === 'text') {
            piece = seg.value || '';
        } else {
            var idx = bdl_parsedFileData ? bdl_parsedFileData.headers.indexOf(seg.header) : -1;
            piece = (idx !== -1 && sampleRow && idx < sampleRow.length && sampleRow[idx]) ? sampleRow[idx] : '';
        }
        composed += piece;
        if (i < usable.length - 1) {
            composed += (seg.sep || '');
        }
    });
    if (composed.trim() === '') {
        return cm.fallback || '';
    }
    return composed;
}

/* Renders the composed-message builder section into its container, or clears
   the container when the builder is not active for this entity. */
function bdl_renderComposedMessageSection(state) {
    var container = document.getElementById('bdl-composed-message-area');
    if (!container) {
        return;
    }
    if (!bdl_isComposedMessageActive(state)) {
        container.innerHTML = '';
        return;
    }
    var cm = bdl_ensureComposedMessage(state);
    var msgField = state.fields.find(function(f) {
        return f.element_name === bdl_COMPOSED_MESSAGE_ELEMENT;
    });
    var displayName = msgField ? bdl_getFieldDisplayName(msgField) : bdl_COMPOSED_MESSAGE_ELEMENT;
    var headerCompleteCls = bdl_composedMessageReady(state) ? ' bdl-assignment-complete' : '';
    var html = '<div class="bdl-composed-message-section">';
    html += '<div class="bdl-panel-header bdl-composed-header' + headerCompleteCls + '">' + cc_escapeHtml(displayName) +
        ' <span class="bdl-composed-required">required</span></div>';
    html += '<div class="bdl-composed-intro">Build the message written to each row. Add text and ' +
        'file-column segments in any order; they join left to right.</div>';
    html += '<div class="bdl-composed-segments" id="bdl-composed-segments">';
    cm.segments.forEach(function(seg, sIdx) {
        html += bdl_renderComposedSegment(seg, sIdx, cm.segments.length);
    });
    html += '</div>';
    html += '<button class="bdl-composed-add-btn" data-action-click="bdl-cm-add-segment">+ Add Segment</button>';
    html += '<div class="bdl-composed-fallback-row"><div class="bdl-composed-fallback-label">' +
        'If a row\'s message is empty, use this text instead</div>';
    html += '<input type="text" class="bdl-composed-fallback-input" id="bdl-composed-fallback" ' +
        'value="' + cc_escapeHtml(cm.fallback || '') + '" ' +
        'data-action-input="bdl-cm-fallback-input" data-action-change="bdl-cm-fallback-changed" ' +
        'placeholder="(leave empty to allow blank messages)"></div>';
    html += '<div class="bdl-composed-preview-row"><span class="bdl-composed-preview-label">Preview (first row):</span>' +
        '<code class="bdl-composed-preview-value" id="bdl-composed-preview">' +
        cc_escapeHtml(bdl_composedMessagePreview(cm)) + '</code></div>';
    html += '</div>';
    container.innerHTML = html;
}

/* Builds the markup for one composed-message segment with its type toggle and
   the input appropriate to its type. */
function bdl_renderComposedSegment(seg, sIdx, segCount) {
    var textActive = seg.type === 'text' ? ' bdl-cm-type-active' : '';
    var fieldActive = seg.type === 'field' ? ' bdl-cm-type-active' : '';
    var html = '<div class="bdl-composed-segment" id="bdl-cm-seg-' + sIdx + '">';
    html += '<div class="bdl-composed-segment-num">' + (sIdx + 1) + '</div>';
    html += '<div class="bdl-composed-type-toggle">';
    html += '<div class="bdl-composed-type-btn bdl-toggle-first' + textActive + '" ' +
        'data-action-click="bdl-cm-segment-type" data-action-bdl-sidx="' + sIdx + '" ' +
        'data-action-bdl-cmtype="text">Text</div>';
    html += '<div class="bdl-composed-type-btn bdl-toggle-last' + fieldActive + '" ' +
        'data-action-click="bdl-cm-segment-type" data-action-bdl-sidx="' + sIdx + '" ' +
        'data-action-bdl-cmtype="field">Field</div>';
    html += '</div>';
    html += '<div class="bdl-composed-segment-input">';
    if (seg.type === 'text') {
        html += '<input type="text" class="bdl-composed-text-input" id="bdl-cm-text-' + sIdx + '" ' +
            'value="' + cc_escapeHtml(seg.value || '') + '" placeholder="Enter text" ' +
            'data-action-input="bdl-cm-segment-text-input" data-action-bdl-sidx="' + sIdx + '">';
    } else {
        html += '<select class="bdl-identifier-dropdown bdl-composed-field-select" id="bdl-cm-field-' + sIdx + '" ' +
            'data-action-change="bdl-cm-segment-field-changed" data-action-bdl-sidx="' + sIdx + '">' +
            '<option value="">&mdash; Select file column &mdash;</option>';
        if (bdl_parsedFileData && bdl_parsedFileData.headers) {
            bdl_parsedFileData.headers.forEach(function(header, idx) {
                var sample = (bdl_parsedFileData.rows[0] && bdl_parsedFileData.rows[0][idx]) ?
                    bdl_parsedFileData.rows[0][idx] : '';
                var sel = (seg.header === header) ? ' selected' : '';
                html += '<option value="' + cc_escapeHtml(header) + '"' + sel + '>' +
                    cc_escapeHtml(header + (sample ? '  (' + sample.substring(0, 20) + ')' : '')) + '</option>';
            });
        }
        html += '</select>';
    }
    html += '</div>';
    html += '<div class="bdl-composed-segment-sep">';
    html += '<input type="text" class="bdl-composed-sep-input" id="bdl-cm-sep-' + sIdx + '" ' +
        'value="' + cc_escapeHtml(seg.sep || '') + '" placeholder="sep" title="Separator after this segment" ' +
        'data-action-input="bdl-cm-segment-sep-input" data-action-bdl-sidx="' + sIdx + '">';
    html += '</div>';
    if (segCount > 1) {
        html += '<span class="bdl-composed-segment-remove" data-action-click="bdl-cm-remove-segment" ' +
            'data-action-bdl-sidx="' + sIdx + '" title="Remove segment">&#10005;</span>';
    }
    html += '</div>';
    return html;
}

/* Refreshes the live preview line without re-rendering the whole builder. */
function bdl_cmUpdatePreview(state) {
    var previewEl = document.getElementById('bdl-composed-preview');
    if (!previewEl || !state.composedMessage) {
        return;
    }
    previewEl.textContent = bdl_composedMessagePreview(state.composedMessage);
}

/* Adds a new empty text segment to the composed message. */
function bdl_cmAddSegment() {
    var state = bdl_curState();
    if (!state) {
        return;
    }
    var cm = bdl_ensureComposedMessage(state);
    cm.segments.push({ type: 'text', value: '', header: null, sep: '' });
    bdl_renderComposedMessageSection(state);
    bdl_checkMappingComplete();
}

/* Removes a segment from the composed message, keeping at least one. */
function bdl_cmRemoveSegment(target) {
    var sIdx = parseInt(target.getAttribute('data-action-bdl-sidx'), 10);
    var state = bdl_curState();
    if (!state || !state.composedMessage || state.composedMessage.segments.length <= 1) {
        return;
    }
    state.composedMessage.segments.splice(sIdx, 1);
    bdl_renderComposedMessageSection(state);
    bdl_checkMappingComplete();
}

/* Switches a segment between text and field type, clearing its prior value. */
function bdl_cmSetSegmentType(target) {
    var sIdx = parseInt(target.getAttribute('data-action-bdl-sidx'), 10);
    var newType = target.getAttribute('data-action-bdl-cmtype');
    var state = bdl_curState();
    if (!state || !state.composedMessage || !state.composedMessage.segments[sIdx]) {
        return;
    }
    var seg = state.composedMessage.segments[sIdx];
    if (seg.type === newType) {
        return;
    }
    seg.type = newType;
    seg.value = '';
    seg.header = null;
    bdl_renderComposedMessageSection(state);
    bdl_checkMappingComplete();
}

/* Records a text segment's value as the user types and updates the preview. */
function bdl_cmSegmentTextInput(target) {
    var sIdx = parseInt(target.getAttribute('data-action-bdl-sidx'), 10);
    var state = bdl_curState();
    if (!state || !state.composedMessage || !state.composedMessage.segments[sIdx]) {
        return;
    }
    state.composedMessage.segments[sIdx].value = target.value;
    bdl_cmUpdatePreview(state);
    bdl_checkMappingComplete();
}

/* Records a field segment's chosen column and refreshes the builder. */
function bdl_cmSegmentFieldChanged(target) {
    var sIdx = parseInt(target.getAttribute('data-action-bdl-sidx'), 10);
    var state = bdl_curState();
    if (!state || !state.composedMessage || !state.composedMessage.segments[sIdx]) {
        return;
    }
    state.composedMessage.segments[sIdx].header = target.value || null;
    bdl_renderComposedMessageSection(state);
    bdl_checkMappingComplete();
}

/* Records the fallback text as the user types and updates the preview. */
function bdl_cmFallbackInput(target) {
    var state = bdl_curState();
    if (!state || !state.composedMessage) {
        return;
    }
    state.composedMessage.fallback = target.value;
    bdl_cmUpdatePreview(state);
}

/* Commits the fallback text on change (covers paste and blur). */
function bdl_cmFallbackChanged(target) {
    var state = bdl_curState();
    if (!state || !state.composedMessage) {
        return;
    }
    state.composedMessage.fallback = target.value;
    bdl_cmUpdatePreview(state);
}

/* Records a segment's trailing separator as the user types and updates the
   preview. */
function bdl_cmSegmentSepInput(target) {
    var sIdx = parseInt(target.getAttribute('data-action-bdl-sidx'), 10);
    var state = bdl_curState();
    if (!state || !state.composedMessage || !state.composedMessage.segments[sIdx]) {
        return;
    }
    state.composedMessage.segments[sIdx].sep = target.value;
    bdl_cmUpdatePreview(state);
}

/* ============================================================================
   FUNCTIONS: STEP 4 VALIDATION
   ----------------------------------------------------------------------------
   Staging the full file server-side, running server validation, the
   client-side row scan that produces warnings, the validation results UI
   (actionable cards and informational warnings), the lookup-value
   replace/fill/skip remediation flow, and the per-entity progress banner.
   Prefix: bdl
   ============================================================================ */

/* Renders the validation-results state for the current entity. */
function bdl_renderMapValidateValidation(area, state) {
    var html = bdl_renderEntityProgressBanner('validating');
    html += bdl_buildValidationResultsHtml(state.validationResult.warnings, state.validationResult.serverData);
    area.innerHTML = html;
}

/* Renders the validated (complete) state for the current entity. */
function bdl_renderMapValidateValidated(area, state) {
    var html = bdl_renderEntityProgressBanner('complete');
    var detailParts = [];
    if (state.stagingContext) {
        detailParts.push(state.stagingContext.row_count.toLocaleString() + ' rows staged');
    }
    var mappedCount = Object.keys(state.columnMapping).length;
    var faCount = state.fieldAssignments ? Object.keys(state.fieldAssignments).length : 0;
    detailParts.push((mappedCount + faCount) + ' field' + ((mappedCount + faCount) !== 1 ? 's' : '') + ' mapped');
    if (state.nullifyFields && state.nullifyFields.length > 0) {
        detailParts.push(state.nullifyFields.length + ' field' +
            (state.nullifyFields.length !== 1 ? 's' : '') + ' will be nullified');
    }
    html += '<div class="bdl-validation-summary bdl-validation-pass">' +
        '<span class="bdl-validation-icon bdl-validation-icon-pass">&#10003;</span>' +
        '<div><strong class="bdl-validation-summary-strong bdl-validation-strong-pass">' +
        cc_escapeHtml(bdl_formatEntityName(state.entity.entity_type)) +
        ' &mdash; Mapping and validation complete</strong>' +
        '<div class="bdl-validation-detail">' + detailParts.join(' &middot; ') + '</div></div></div>';
    var mappingKeys = Object.keys(state.columnMapping);
    if (mappingKeys.length > 0 || faCount > 0) {
        html += '<div class="bdl-execute-mapped-summary"><span class="bdl-mapped-summary-icon">&#128279;</span> ' +
            '<strong class="bdl-execute-mapped-summary-strong">Mapped Fields:</strong> ';
        var fieldCodes = mappingKeys.map(function(sc) {
            var te = state.columnMapping[sc];
            var fld = state.fields ? state.fields.find(function(f) {
                return f.element_name === te;
            }) : null;
            return '<code class="bdl-execute-mapped-summary-code">' +
                cc_escapeHtml(fld ? bdl_getFieldDisplayName(fld) : te) + '</code>';
        });
        if (state.fieldAssignments) {
            Object.keys(state.fieldAssignments).forEach(function(elemName) {
                var fa = state.fieldAssignments[elemName];
                var fld = state.fields ? state.fields.find(function(f) {
                    return f.element_name === elemName;
                }) : null;
                var label = fld ? bdl_getFieldDisplayName(fld) : elemName;
                var modeTag = fa.mode === 'conditional' ?
                    ' <span class="bdl-field-mode-tag-cond">(cond)</span>' :
                    ' <span class="bdl-field-mode-tag-fixed">(fixed)</span>';
                fieldCodes.push('<code class="bdl-execute-mapped-summary-code">' +
                    cc_escapeHtml(label) + '</code>' + modeTag);
            });
        }
        html += fieldCodes.join(', ');
        html += '</div>';
    }
    if (state.nullifyFields && state.nullifyFields.length > 0) {
        html += '<div class="bdl-nullify-summary"><span class="bdl-nullify-summary-icon">&#8709;</span> ' +
            '<strong class="bdl-nullify-summary-strong">Nullify:</strong> ';
        html += state.nullifyFields.map(function(nf) {
            return '<code class="bdl-nullify-summary-code">' +
                cc_escapeHtml(bdl_getFieldDisplayNameByElement(nf)) + '</code>';
        }).join(', ');
        html += '</div>';
    }
    html += '<div class="bdl-map-validate-actions">';
    html += '<button class="bdl-nav-btn bdl-enabled" data-action-click="bdl-revalidate-entity">Re-validate</button>';
    if (bdl_currentEntityIndex < bdl_entityStates.length - 1) {
        html += '<button class="bdl-execute-btn bdl-enabled" data-action-click="bdl-advance-entity">Continue to ' +
            cc_escapeHtml(bdl_formatEntityName(bdl_entityStates[bdl_currentEntityIndex + 1].entity.entity_type)) +
            ' &#8594;</button>';
    }
    html += '</div>';
    area.innerHTML = html;
}

/* Builds the multi-entity progress banner shown above the Step 4 workspace. */
function bdl_renderEntityProgressBanner(phase) {
    var total = bdl_entityStates.length;
    if (total <= 1 && phase !== 'complete') {
        return '';
    }
    var current = bdl_currentEntityIndex + 1;
    var entityName = bdl_formatEntityName(bdl_curEntity().entity_type);
    var html = '<div class="bdl-mapping-progress-banner"><div class="bdl-progress-banner-top">';
    var i;
    for (i = 0; i < total; i++) {
        var dotClass = 'bdl-progress-dot';
        if (i < bdl_currentEntityIndex || (i === bdl_currentEntityIndex && phase === 'complete')) {
            dotClass += ' bdl-progress-dot-done';
        } else if (i === bdl_currentEntityIndex) {
            dotClass += ' bdl-progress-dot-active';
        }
        html += '<span class="' + dotClass + '" title="' +
            cc_escapeHtml(bdl_formatEntityName(bdl_entityStates[i].entity.entity_type)) + '">' + (i + 1) + '</span>';
        if (i < total - 1) {
            html += '<span class="bdl-progress-dot-line' +
                (i < bdl_currentEntityIndex ? ' bdl-progress-dot-line-done' : '') + '"></span>';
        }
    }
    html += '</div>';
    if (phase === 'mapping') {
        html += '<div class="bdl-progress-banner-label">Mapping ' + current + ' of ' + total +
            ': <strong>' + cc_escapeHtml(entityName) + '</strong></div>';
    } else if (phase === 'validating') {
        html += '<div class="bdl-progress-banner-label">Validating ' + current + ' of ' + total +
            ': <strong>' + cc_escapeHtml(entityName) + '</strong></div>';
    } else if (phase === 'complete') {
        html += '<div class="bdl-progress-banner-label">Complete ' + current + ' of ' + total +
            ': <strong>' + cc_escapeHtml(entityName) + '</strong> &#10003;</div>';
    }
    html += '</div>';
    return html;
}

/* Validates the current entity, re-staging first if the mapping changed. */
function bdl_validateCurrentEntity() {
    var state = bdl_curState();
    if (!state || (Object.keys(state.columnMapping).length === 0 &&
        (!state.fieldAssignments || Object.keys(state.fieldAssignments).length === 0) &&
        !bdl_composedMessageReady(state))) {
        return;
    }
    var mappingUnchanged = state.stagingContext && state.stagedMapping &&
        bdl_mappingsAreEqual(state.columnMapping, state.stagedMapping);
    if (mappingUnchanged && state.assignments && state.assignments.length > 0) {
        var currentAssignmentsJson = JSON.stringify(state.assignments.map(function(a) {
            return { mode: a.mode, fixedValues: a.fixedValues, triggerColumn: a.triggerColumn,
                conditionalField: a.conditionalField, valueMap: a.valueMap,
                sharedFields: a.sharedFields, fileColumn: a.fileColumn };
        }));
        mappingUnchanged = state.stagedAssignments === currentAssignmentsJson;
    }
    if (mappingUnchanged && state.fieldAssignments) {
        var currentFAJson = JSON.stringify(state.fieldAssignments);
        mappingUnchanged = state.stagedFieldAssignments === currentFAJson;
    }
    if (mappingUnchanged && bdl_isComposedMessageActive(state) && state.composedMessage) {
        var currentCMJson = JSON.stringify(bdl_serializeComposedMessage(state.composedMessage));
        mappingUnchanged = state.stagedComposedMessage === currentCMJson;
    }
    if (mappingUnchanged) {
        bdl_runEntityValidation(state);
    } else if (state.stagingContext) {
        var oldTable = state.stagingContext.staging_table;
        state.stagingContext = null;
        state.stagedMapping = null;
        state.stagedAssignments = null;
        state.stagedFieldAssignments = null;
        state.stagedComposedMessage = null;
        bdl_stageEntityData(state, function() {
            bdl_runEntityValidation(state);
        }, oldTable);
    } else {
        bdl_stageEntityData(state, function() {
            bdl_runEntityValidation(state);
        });
    }
}

/* Reads the full file and stages it server-side for the given entity. */
function bdl_stageEntityData(state, onComplete, dropExistingTable) {
    var area = document.getElementById('bdl-map-validate-area');
    area.innerHTML = bdl_renderEntityProgressBanner('validating') + '<div class="bdl-loading">' +
        (dropExistingTable ? 'Mapping changed &mdash; re-staging data...' : 'Reading full file and staging...') +
        '</div>';
    var ext = '.' + bdl_uploadedFile.name.split('.').pop().toLowerCase();
    var reader = new FileReader();
    reader.addEventListener('load', function(e) {
        var allRows;
        try {
            if (ext === '.csv' || ext === '.txt') {
                allRows = bdl_parseCSVAllRows(e.target.result);
            } else {
                allRows = bdl_parseExcelAllRows(e.target.result);
            }
        } catch (err) {
            area.innerHTML = bdl_renderEntityProgressBanner('validating') +
                '<div class="bdl-placeholder-message bdl-inline-error">Failed to read file: ' + err.message + '</div>';
            return;
        }
        area.innerHTML = bdl_renderEntityProgressBanner('validating') + '<div class="bdl-loading">Staging ' +
            allRows.length.toLocaleString() + ' rows for ' + bdl_formatEntityName(state.entity.entity_type) + '...</div>';
        var fileMapping = {};
        Object.keys(state.columnMapping).forEach(function(k) {
            if (k.indexOf('__fixed__') !== 0) {
                fileMapping[k] = state.columnMapping[k];
            }
        });
        var stageBody = { entity_type: state.entity.entity_type, config_id: bdl_selectedEnvironment.config_id,
            mapping: fileMapping, headers: bdl_parsedFileData.headers, rows: allRows };
        if (state.assignments && state.assignments.length > 0) {
            stageBody.assignments = state.assignments.map(function(a) {
                return { mode: a.mode, fixed_values: a.fixedValues || {}, trigger_column: a.triggerColumn,
                    conditional_field: a.conditionalField, value_map: a.valueMap || {},
                    shared_fields: a.sharedFields || {}, file_column: a.fileColumn || null };
            });
        } else {
            var fixedValues = {};
            Object.keys(state.columnMapping).forEach(function(k) {
                if (k.indexOf('__fixed__') === 0) {
                    fixedValues[k.replace('__fixed__', '')] = state.columnMapping[k];
                }
            });
            if (Object.keys(fixedValues).length > 0) {
                stageBody.fixed_values = fixedValues;
            }
        }
        if (state.fieldAssignments && Object.keys(state.fieldAssignments).length > 0) {
            var faPayload = {};
            Object.keys(state.fieldAssignments).forEach(function(elemName) {
                var fa = state.fieldAssignments[elemName];
                faPayload[elemName] = { mode: fa.mode, value: fa.value || '',
                    trigger_column: fa.triggerColumn, value_map: fa.valueMap || {} };
            });
            stageBody.field_assignments = faPayload;
        }
        if (bdl_isComposedMessageActive(state) && state.composedMessage) {
            stageBody.composed_message = bdl_serializeComposedMessage(state.composedMessage);
        }
        if (dropExistingTable) {
            stageBody.drop_existing = dropExistingTable;
        }
        fetch('/api/bdl-import/stage', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(stageBody)
        }).then(function(r) {
            if (!r.ok) {
                return r.json().then(function(d) {
                    throw new Error(d.error || 'HTTP ' + r.status);
                });
            }
            return r.json();
        }).then(function(data) {
            state.stagingContext = { staging_table: data.staging_table, row_count: data.row_count,
                environment: data.environment, required_extra_fields: data.required_extra_fields || [] };
            state.stagedMapping = JSON.parse(JSON.stringify(state.columnMapping));
            if (state.assignments && state.assignments.length > 0) {
                state.stagedAssignments = JSON.stringify(state.assignments.map(function(a) {
                    return { mode: a.mode, fixedValues: a.fixedValues, triggerColumn: a.triggerColumn,
                        conditionalField: a.conditionalField, valueMap: a.valueMap,
                        sharedFields: a.sharedFields, fileColumn: a.fileColumn };
                }));
            }
            if (state.fieldAssignments && Object.keys(state.fieldAssignments).length > 0) {
                state.stagedFieldAssignments = JSON.stringify(state.fieldAssignments);
            }
            if (bdl_isComposedMessageActive(state) && state.composedMessage) {
                state.stagedComposedMessage = JSON.stringify(bdl_serializeComposedMessage(state.composedMessage));
            }
            if (onComplete) {
                onComplete();
            }
        }).catch(function(err) {
            area.innerHTML = bdl_renderEntityProgressBanner('validating') +
                '<div class="bdl-placeholder-message bdl-inline-error">Staging failed: ' + err.message + '</div>';
        });
    });
    if (ext === '.csv' || ext === '.txt') {
        reader.readAsText(bdl_uploadedFile);
    } else {
        reader.readAsArrayBuffer(bdl_uploadedFile);
    }
}

/* Runs server validation against the staged data and renders the result. */
function bdl_runEntityValidation(state) {
    var area = document.getElementById('bdl-map-validate-area');
    area.innerHTML = bdl_renderEntityProgressBanner('validating') + '<div class="bdl-loading">Validating ' +
        bdl_formatEntityName(state.entity.entity_type) + ' against ' + state.stagingContext.environment + '...</div>';
    bdl_revalidating = true;
    fetch('/api/bdl-import/validate', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ staging_table: state.stagingContext.staging_table,
            entity_type: state.entity.entity_type, config_id: bdl_selectedEnvironment.config_id })
    }).then(function(r) {
        if (!r.ok) {
            return r.json().then(function(d) {
                throw new Error(d.error || 'HTTP ' + r.status);
            });
        }
        return r.json();
    }).then(function(serverData) {
        bdl_revalidating = false;
        serverData.staging_table = state.stagingContext.staging_table;
        var warnings = bdl_validateStagedRows(serverData, state);
        state.validationResult = { warnings: warnings, serverData: serverData };
        if (serverData.row_count !== undefined) {
            state.stagingContext.row_count = serverData.row_count;
        }
        if (serverData.skipped_count !== undefined) {
            state.stagingContext.skipped_count = serverData.skipped_count;
        }
        var hasActionable = warnings.some(function(w) {
            return w.type === 'required_empty' || w.type === 'lookup_invalid';
        });
        state.validated = !hasActionable;
        if (state.validated && bdl_entityStates.length > 1 &&
            bdl_currentEntityIndex < bdl_entityStates.length - 1) {
            bdl_showEntityTransition(state.entity.entity_type,
                bdl_entityStates[bdl_currentEntityIndex + 1].entity.entity_type);
        } else {
            bdl_renderMapValidatePanel();
        }
    }).catch(function(err) {
        bdl_revalidating = false;
        area.innerHTML = bdl_renderEntityProgressBanner('validating') +
            '<div class="bdl-placeholder-message bdl-inline-error">Validation failed: ' + err.message + '</div>';
    });
}

/* Shows a brief dynamic transition modal between completed entities. */
function bdl_showEntityTransition(completedType, nextType) {
    var existing = document.getElementById('bdl-entity-transition-modal');
    if (existing) {
        existing.remove();
    }
    var modal = document.createElement('div');
    modal.id = 'bdl-entity-transition-modal';
    modal.className = 'cc-modal-overlay';
    modal.innerHTML = '<div class="cc-dialog cc-dialog-modal">' +
        '<div class="cc-dialog-header"><span class="bdl-dialog-icon bdl-transition-icon">&#10003;</span>' +
        '<span class="cc-dialog-title">' + cc_escapeHtml(bdl_formatEntityName(completedType)) +
        ' Complete</span></div><div class="cc-dialog-body">' +
        '<p class="cc-dialog-paragraph">Mapping and validation passed.</p>' +
        '<p class="cc-dialog-paragraph cc-last">Moving to <strong class="cc-dialog-strong">' +
        cc_escapeHtml(bdl_formatEntityName(nextType)) + '</strong>...</p></div></div>';
    document.body.appendChild(modal);
    setTimeout(function() {
        modal.remove();
        bdl_renderMapValidatePanel();
    }, 1500);
}

/* Persists nullify fields if needed, then advances to the next entity. */
function bdl_advanceToNextEntity() {
    if (bdl_currentEntityIndex >= bdl_entityStates.length - 1) {
        return;
    }
    var state = bdl_curState();
    if (state && state.nullifyFields && state.nullifyFields.length > 0 && state.stagingContext) {
        bdl_persistNullifyFields(state, function() {
            bdl_currentEntityIndex++;
            bdl_loadCurrentEntityFields(function() {
                bdl_loadTemplates(bdl_curEntity().entity_type);
                bdl_renderMapValidatePanel();
            });
        });
    } else {
        bdl_currentEntityIndex++;
        bdl_loadCurrentEntityFields(function() {
            bdl_loadTemplates(bdl_curEntity().entity_type);
            bdl_renderMapValidatePanel();
        });
    }
}

/* Resets the current entity to its mapping state for re-validation. */
function bdl_revalidateCurrentEntity() {
    var state = bdl_curState();
    if (!state) {
        return;
    }
    state.validated = false;
    state.validationResult = null;
    bdl_renderMapValidateMapping(document.getElementById('bdl-map-validate-area'), state);
}

/* Parses all data rows of a CSV/TXT file. */
function bdl_parseCSVAllRows(text) {
    var lines = text.split(/\r?\n/).filter(function(l) {
        return l.trim();
    });
    var rows = [];
    var i;
    for (i = 1; i < lines.length; i++) {
        rows.push(bdl_parseCSVLine(lines[i]));
    }
    return rows;
}

/* Parses all data rows of the first sheet of an Excel file. */
function bdl_parseExcelAllRows(buffer) {
    var d = new Uint8Array(buffer);
    var wb = XLSX.read(d, { type: 'array', cellDates: true });
    var sh = wb.Sheets[wb.SheetNames[0]];
    var range = XLSX.utils.decode_range(sh['!ref']);
    var rows = [];
    var r;
    for (r = 1; r <= range.e.r; r++) {
        var rd = [];
        var c;
        for (c = range.s.c; c <= range.e.c; c++) {
            var cell = sh[XLSX.utils.encode_cell({ r: r, c: c })];
            rd.push(bdl_excelCellValue(cell));
        }
        rows.push(rd);
    }
    return rows;
}

/* Scans staged rows client-side and produces the validation warning list. */
function bdl_validateStagedRows(serverData, state) {
    var warnings = [];
    var columns = serverData.columns || [];
    var rows = serverData.rows || [];
    var lookups = serverData.lookups || {};
    var lookupErrors = serverData.lookup_errors || {};
    var entityFields = state.fields;
    var columnMapping = state.columnMapping;
    var fieldMap = {};
    entityFields.forEach(function(f) {
        fieldMap[f.element_name] = f;
    });
    var colIndex = {};
    columns.forEach(function(col, idx) {
        colIndex[col] = idx;
    });
    Object.keys(lookupErrors).forEach(function(en) {
        warnings.push({ type: 'lookup_error', field: en, message: lookupErrors[en], rowCount: 0, samples: [] });
    });
    var MAX_SAMPLES = 5;
    columns.forEach(function(colName) {
        var field = fieldMap[colName];
        if (!field) {
            return;
        }
        var ci = colIndex[colName];
        var emptyCount = 0;
        var lenErrs = { items: [], total: 0 };
        var typeErrs = { items: [], total: 0 };
        var lookupMiss = { total: 0, uv: {} };
        var isReq = field.is_import_required;
        var maxLen = field.max_length;
        var dt = (field.data_type || '').toLowerCase();
        var lookupSet = lookups[colName] ? lookups[colName].values : null;
        var lookupMap = null;
        if (lookupSet) {
            lookupMap = {};
            lookupSet.forEach(function(v) {
                lookupMap[String(v).toUpperCase()] = true;
            });
        }
        var sourceCol = null;
        Object.keys(columnMapping).forEach(function(sc) {
            if (columnMapping[sc] === colName) {
                sourceCol = sc;
            }
        });
        var i;
        for (i = 0; i < rows.length; i++) {
            var val = rows[i][ci];
            if (val === undefined || val === null) {
                val = '';
            }
            var tr = val.trim();
            if (isReq && tr === '') {
                emptyCount++;
                continue;
            }
            if (tr === '') {
                continue;
            }
            if (maxLen && tr.length > maxLen) {
                lenErrs.total++;
                if (lenErrs.items.length < MAX_SAMPLES) {
                    lenErrs.items.push({ row: i + 1, value: tr.substring(0, 50), length: tr.length });
                }
            }
            if (dt === 'int' || dt === 'long' || dt === 'short') {
                if (!/^-?\d+$/.test(tr)) {
                    typeErrs.total++;
                    if (typeErrs.items.length < MAX_SAMPLES) {
                        typeErrs.items.push({ row: i + 1, value: tr.substring(0, 30) });
                    }
                }
            } else if (dt === 'decimal') {
                if (!/^-?\d+(\.\d+)?$/.test(tr)) {
                    typeErrs.total++;
                    if (typeErrs.items.length < MAX_SAMPLES) {
                        typeErrs.items.push({ row: i + 1, value: tr.substring(0, 30) });
                    }
                }
            } else if (dt === 'boolean') {
                if (['true', 'false', '1', '0', 'yes', 'no', 'y', 'n'].indexOf(tr.toLowerCase()) === -1) {
                    typeErrs.total++;
                    if (typeErrs.items.length < MAX_SAMPLES) {
                        typeErrs.items.push({ row: i + 1, value: tr.substring(0, 30) });
                    }
                }
            }
            if (lookupMap && tr !== '') {
                if (!lookupMap[tr.toUpperCase()]) {
                    var uKey = tr.toUpperCase();
                    if (!lookupMiss.uv[uKey]) {
                        lookupMiss.uv[uKey] = { display: tr, count: 0 };
                    }
                    lookupMiss.uv[uKey].count++;
                    lookupMiss.total++;
                }
            }
        }
        if (emptyCount > 0) {
            warnings.push({ type: 'required_empty', field: colName, sourceColumn: sourceCol,
                message: emptyCount.toLocaleString() + ' row(s) have empty values for required field',
                rowCount: emptyCount, hasLookup: !!lookupSet, lookupValues: lookupSet, samples: [] });
        }
        if (lenErrs.total > 0) {
            warnings.push({ type: 'max_length', field: colName, sourceColumn: sourceCol,
                message: lenErrs.total.toLocaleString() + ' row(s) exceed max length of ' + maxLen,
                rowCount: lenErrs.total, samples: lenErrs.items });
        }
        if (typeErrs.total > 0) {
            warnings.push({ type: 'data_type', field: colName, sourceColumn: sourceCol,
                message: typeErrs.total.toLocaleString() + ' row(s) have invalid ' + dt + ' values',
                rowCount: typeErrs.total, samples: typeErrs.items });
        }
        if (lookupMiss.total > 0) {
            var tRef = lookups[colName] ? lookups[colName].table : '';
            warnings.push({ type: 'lookup_invalid', field: colName, sourceColumn: sourceCol,
                message: lookupMiss.total.toLocaleString() + ' row(s) have values not found in ' + tRef,
                rowCount: lookupMiss.total, uniqueValues: lookupMiss.uv, samples: [] });
        }
    });
    return warnings;
}

/* Builds the validation results UI (actionable cards plus info warnings). */
function bdl_buildValidationResultsHtml(warnings, serverData) {
    var html = '';
    var rc = serverData.row_count || 0;
    var skipped = serverData.skipped_count || 0;
    var actionableWarnings = warnings.filter(function(w) {
        return w.type === 'required_empty' || w.type === 'lookup_invalid';
    });
    var infoWarnings = warnings.filter(function(w) {
        return w.type !== 'required_empty' && w.type !== 'lookup_invalid';
    });
    var rowSummary = rc.toLocaleString() + ' rows validated' +
        (skipped > 0 ? ', ' + skipped.toLocaleString() + ' skipped' : '');
    if (!warnings.length) {
        html += '<div class="bdl-validation-summary bdl-validation-pass">' +
            '<span class="bdl-validation-icon bdl-validation-icon-pass">&#10003;</span>' +
            '<div><strong class="bdl-validation-summary-strong bdl-validation-strong-pass">Validation passed</strong>' +
            '<div class="bdl-validation-detail">' + rowSummary + '. No issues found.</div></div></div>';
    } else if (actionableWarnings.length > 0) {
        html += '<div class="bdl-validation-summary bdl-validation-block">' +
            '<span class="bdl-validation-icon bdl-validation-icon-block">&#9888;</span>' +
            '<div><strong class="bdl-validation-summary-strong bdl-validation-strong-block">' +
            actionableWarnings.length + ' issue' + (actionableWarnings.length > 1 ? 's' : '') + ' found</strong>' +
            '<div class="bdl-validation-detail">' + rowSummary + '. Resolve issues below.</div></div></div>';
    } else {
        html += '<div class="bdl-validation-summary bdl-validation-warn">' +
            '<span class="bdl-validation-icon bdl-validation-icon-warn">&#9888;</span>' +
            '<div><strong class="bdl-validation-summary-strong bdl-validation-strong-warn">' +
            infoWarnings.length + ' warning' + (infoWarnings.length > 1 ? 's' : '') + '</strong>' +
            '<div class="bdl-validation-detail">' + rowSummary + '. You may proceed.</div></div></div>';
    }
    if (actionableWarnings.length > 0) {
        html += '<div class="bdl-validation-cards" id="bdl-validation-cards">';
        var typeLabels = { required_empty: 'Required Value Missing', lookup_invalid: 'Invalid Lookup Value' };
        actionableWarnings.forEach(function(w, idx) {
            var cardId = 'bdl-vcard-' + idx;
            var fieldDisplay = bdl_getFieldDisplayNameByElement(w.field);
            html += '<div class="bdl-val-card" id="' + cardId + '">' +
                '<div class="bdl-val-card-header" data-action-click="bdl-toggle-validation-card" ' +
                'data-action-bdl-card="' + cardId + '"><div class="bdl-val-card-header-left">' +
                '<span class="bdl-val-card-field">';
            if (fieldDisplay !== w.field) {
                html += cc_escapeHtml(fieldDisplay) + ' <code class="bdl-val-target bdl-val-card-field-code">' +
                    w.field + '</code>';
            } else {
                html += '<code class="bdl-val-target">' + w.field + '</code>';
            }
            html += '</span><span class="bdl-val-badge">' + typeLabels[w.type] + '</span></div>' +
                '<div class="bdl-val-card-header-right"><span class="bdl-val-card-count">' +
                w.rowCount.toLocaleString() + ' rows</span>' +
                '<span class="bdl-val-card-chevron" id="bdl-chevron-' + cardId + '">&#9654;</span></div></div>';
            html += '<div class="bdl-val-card-body bdl-hidden" id="bdl-body-' + cardId + '">';
            var guidanceState = bdl_curState();
            var guidanceField = guidanceState && guidanceState.fields ? guidanceState.fields.find(function(gf) {
                return gf.element_name === w.field;
            }) : null;
            if (guidanceField && guidanceField.import_guidance) {
                html += '<div class="bdl-val-guidance-tip">' + cc_escapeHtml(guidanceField.import_guidance) + '</div>';
            }
            if (w.type === 'required_empty') {
                html += bdl_renderRequiredEmptyActions(w);
            } else if (w.type === 'lookup_invalid') {
                html += bdl_renderLookupInvalidActions(w, cardId, serverData);
            }
            html += '</div></div>';
        });
        html += '</div>';
    }
    if (infoWarnings.length > 0) {
        html += '<div class="bdl-validation-info-section"><div class="bdl-validation-info-header">Warnings (' +
            infoWarnings.length + ')</div>';
        infoWarnings.forEach(function(w, idx) {
            var infoId = 'bdl-vinfo-' + idx;
            var fieldDisplay = bdl_getFieldDisplayNameByElement(w.field);
            var typeLabel = { max_length: 'Max Length', data_type: 'Data Type',
                lookup_error: 'Lookup Discovery' }[w.type] || w.type;
            html += '<div class="bdl-val-info-card" id="' + infoId + '">' +
                '<div class="bdl-val-info-header" data-action-click="bdl-toggle-info-card" ' +
                'data-action-bdl-info="' + infoId + '"><span class="bdl-val-card-field">';
            if (fieldDisplay !== w.field) {
                html += cc_escapeHtml(fieldDisplay) + ' <code class="bdl-val-target bdl-val-card-field-code">' +
                    w.field + '</code>';
            } else {
                html += '<code class="bdl-val-target">' + w.field + '</code>';
            }
            html += '</span><span class="bdl-val-badge bdl-val-badge-info">' + typeLabel + '</span>' +
                '<span class="bdl-val-card-count">' + w.rowCount.toLocaleString() + ' rows</span>' +
                '<span class="bdl-val-info-chevron" id="bdl-chevron-' + infoId + '">&#9654;</span></div>';
            html += '<div class="bdl-val-info-body bdl-hidden" id="bdl-body-' + infoId + '">' +
                '<div class="bdl-val-card-message">' + cc_escapeHtml(w.message) + '</div>';
            if (w.samples && w.samples.length > 0) {
                html += '<div class="bdl-validation-samples">';
                w.samples.forEach(function(s) {
                    html += '<span class="bdl-val-sample">Row ' + s.row + ': <code class="bdl-val-sample-code">' +
                        cc_escapeHtml(String(s.value)) + '</code>';
                    if (s.length) {
                        html += ' (' + s.length + ' chars)';
                    }
                    html += '</span>';
                });
                html += '</div>';
            }
            html += '</div></div>';
        });
        html += '</div>';
    }
    return html;
}

/* Builds the fill/skip remediation row for a required-empty warning. */
function bdl_renderRequiredEmptyActions(w) {
    var rid = 'bdl-fill-' + w.field.replace(/[^a-zA-Z0-9]/g, '');
    var state = bdl_curState();
    var html = '<div class="bdl-lookup-replace-table"><div class="bdl-lookup-replace-header">' +
        '<span class="bdl-lrh-count">Rows</span><span class="bdl-lrh-value">Current</span>' +
        '<span class="bdl-lrh-action">Action</span></div>';
    html += '<div class="bdl-lookup-replace-row" id="bdl-row-' + rid + '">' +
        '<span class="bdl-lrr-count">' + w.rowCount.toLocaleString() + '</span>' +
        '<span class="bdl-lrr-value"><code class="bdl-lrr-value-code">(empty)</code></span>' +
        '<span class="bdl-lrr-action">';
    if (w.hasLookup && w.lookupValues) {
        html += '<select id="' + rid + '" class="bdl-replace-select"><option value="">&mdash; Select value &mdash;</option>';
        w.lookupValues.forEach(function(v) {
            html += '<option value="' + cc_escapeHtml(v) + '">' + cc_escapeHtml(v) + '</option>';
        });
        html += '</select>';
    } else {
        html += '<input type="text" id="' + rid + '" class="bdl-replace-input" placeholder="Enter value...">';
    }
    html += ' <button class="bdl-replace-btn bdl-enabled" data-action-click="bdl-fill-empty" ' +
        'data-action-bdl-field="' + cc_escapeHtml(w.field) + '" data-action-bdl-input="' + rid + '">Fill</button>';
    var fieldObj = state.fields.find(function(ff) {
        return ff.element_name === w.field;
    });
    if (!fieldObj || !fieldObj.is_not_nullifiable) {
        html += ' <button class="bdl-skip-btn bdl-enabled" data-action-click="bdl-skip-rows" ' +
            'data-action-bdl-field="' + cc_escapeHtml(w.field) + '" data-action-bdl-value="" ' +
            'data-action-bdl-row="bdl-row-' + rid + '">Skip Rows</button>';
    }
    html += '</span></div></div>';
    return html;
}

/* Builds the replace/skip remediation rows for a lookup-invalid warning. */
function bdl_renderLookupInvalidActions(w, cardId, serverData) {
    var vv = serverData.lookups && serverData.lookups[w.field] ? serverData.lookups[w.field].values : [];
    var uniqueKeys = Object.keys(w.uniqueValues);
    var html = '<div class="bdl-lookup-replace-table" data-bdl-card="' + cardId + '" data-bdl-total-values="' +
        uniqueKeys.length + '" data-bdl-resolved="0">';
    html += '<div class="bdl-lookup-replace-header"><span class="bdl-lrh-count">Count</span>' +
        '<span class="bdl-lrh-value">File Value</span><span class="bdl-lrh-action">Action</span></div>';
    uniqueKeys.forEach(function(key) {
        var info = w.uniqueValues[key];
        var rid2 = 'bdl-replace-' + w.field.replace(/[^a-zA-Z0-9]/g, '') + '-' + key.replace(/[^a-zA-Z0-9]/g, '');
        html += '<div class="bdl-lookup-replace-row" id="bdl-row-' + rid2 + '" data-bdl-resolved="false">' +
            '<span class="bdl-lrr-count">' + info.count.toLocaleString() + '</span>' +
            '<span class="bdl-lrr-value"><code class="bdl-lrr-value-code">' + cc_escapeHtml(info.display) +
            '</code></span><span class="bdl-lrr-action">';
        html += '<select id="' + rid2 + '" class="bdl-replace-select"><option value="">&mdash; Replace with &mdash;</option>';
        vv.forEach(function(v) {
            html += '<option value="' + cc_escapeHtml(v) + '">' + cc_escapeHtml(v) + '</option>';
        });
        html += '</select> <button class="bdl-replace-btn bdl-enabled" data-action-click="bdl-apply-replacement" ' +
            'data-action-bdl-field="' + cc_escapeHtml(w.field) + '" data-action-bdl-old="' +
            cc_escapeHtml(info.display) + '" data-action-bdl-select="' + rid2 + '">Replace</button> ' +
            '<button class="bdl-skip-btn bdl-enabled" data-action-click="bdl-skip-rows" ' +
            'data-action-bdl-field="' + cc_escapeHtml(w.field) + '" data-action-bdl-value="' +
            cc_escapeHtml(info.display) + '" data-action-bdl-row="bdl-row-' + rid2 + '">Skip</button>';
        html += '</span></div>';
    });
    html += '</div>';
    return html;
}

/* Toggles a single actionable validation card open, closing the others. */
function bdl_toggleValidationCard(target) {
    if (bdl_revalidating) {
        return;
    }
    var cardId = target.getAttribute('data-action-bdl-card');
    var cards = document.querySelectorAll('.bdl-val-card');
    cards.forEach(function(card) {
        var body = document.getElementById('bdl-body-' + card.id);
        var chevron = document.getElementById('bdl-chevron-' + card.id);
        if (card.id === cardId) {
            if (body.classList.contains('bdl-hidden')) {
                body.classList.remove('bdl-hidden');
                if (chevron) {
                    chevron.innerHTML = '&#9660;';
                }
                card.classList.add('bdl-val-card-expanded');
            } else {
                body.classList.add('bdl-hidden');
                if (chevron) {
                    chevron.innerHTML = '&#9654;';
                }
                card.classList.remove('bdl-val-card-expanded');
            }
        } else {
            if (body) {
                body.classList.add('bdl-hidden');
            }
            if (chevron) {
                chevron.innerHTML = '&#9654;';
            }
            card.classList.remove('bdl-val-card-expanded');
        }
    });
}

/* Toggles a single informational warning card open or closed. */
function bdl_toggleInfoCard(target) {
    var infoId = target.getAttribute('data-action-bdl-info');
    var body = document.getElementById('bdl-body-' + infoId);
    var chevron = document.getElementById('bdl-chevron-' + infoId);
    if (!body) {
        return;
    }
    if (body.classList.contains('bdl-hidden')) {
        body.classList.remove('bdl-hidden');
        if (chevron) {
            chevron.innerHTML = '&#9660;';
        }
    } else {
        body.classList.add('bdl-hidden');
        if (chevron) {
            chevron.innerHTML = '&#9654;';
        }
    }
}

/* Re-validates automatically once every value in a lookup card is resolved. */
function bdl_checkLookupCardComplete(rowElement) {
    var table = rowElement.closest('.bdl-lookup-replace-table');
    if (!table) {
        return;
    }
    var totalValues = parseInt(table.dataset.bdlTotalValues, 10) || 0;
    var resolvedRows = table.querySelectorAll('.bdl-lookup-replace-row[data-bdl-resolved="true"]');
    table.dataset.bdlResolved = String(resolvedRows.length);
    if (resolvedRows.length >= totalValues) {
        bdl_triggerCascadingRevalidate();
    }
}

/* Shows a re-validating indicator and re-runs validation after remediation. */
function bdl_triggerCascadingRevalidate() {
    if (bdl_revalidating) {
        return;
    }
    bdl_revalidating = true;
    var area = document.getElementById('bdl-map-validate-area');
    area.innerHTML = bdl_renderEntityProgressBanner('validating') +
        '<div class="bdl-loading">Applying changes and re-validating...</div>';
    setTimeout(function() {
        bdl_runEntityValidation(bdl_curState());
    }, 200);
}

/* Replaces an invalid lookup value with a chosen valid value. */
function bdl_applyReplacement(target) {
    if (bdl_revalidating) {
        return;
    }
    var field = target.getAttribute('data-action-bdl-field');
    var oldValue = target.getAttribute('data-action-bdl-old');
    var selectId = target.getAttribute('data-action-bdl-select');
    var state = bdl_curState();
    if (!state) {
        return;
    }
    var sel = document.getElementById(selectId);
    if (!sel || !sel.value) {
        cc_showAlert('Please select a replacement value.',
            { title: 'Selection Required' });
        return;
    }
    var newVal = sel.value;
    var btn = sel.parentElement.querySelector('.bdl-replace-btn');
    if (btn) {
        btn.disabled = true;
    }
    var skipBtn = sel.parentElement.querySelector('.bdl-skip-btn');
    if (skipBtn) {
        skipBtn.disabled = true;
    }
    fetch('/api/bdl-import/replace-values', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ staging_table: state.stagingContext.staging_table,
            field: field, old_value: oldValue, new_value: newVal })
    }).then(function(r) {
        if (!r.ok) {
            return r.json().then(function(d) {
                throw new Error(d.error || 'HTTP ' + r.status);
            });
        }
        return r.json();
    }).then(function(data) {
        var row = document.getElementById(selectId).closest('.bdl-lookup-replace-row');
        if (row) {
            row.innerHTML = '<span class="bdl-lrr-count">' + data.rows_updated + '</span>' +
                '<span class="bdl-lrr-value"><code class="bdl-lrr-value-code">' + cc_escapeHtml(oldValue) +
                '</code> &#8594; <code class="bdl-lrr-value-code">' + cc_escapeHtml(newVal) + '</code></span>' +
                '<span class="bdl-lrr-action bdl-replace-done">&#10003; Replaced</span>';
            row.dataset.bdlResolved = 'true';
            bdl_checkLookupCardComplete(row);
        }
    }).catch(function(err) {
        cc_showAlert(err.message,
            { title: 'Replacement Failed' });
        if (btn) {
            btn.disabled = false;
        }
        if (skipBtn) {
            skipBtn.disabled = false;
        }
    });
}

/* Fills empty required values with a chosen value, then re-validates. */
function bdl_fillEmpty(target) {
    if (bdl_revalidating) {
        return;
    }
    var field = target.getAttribute('data-action-bdl-field');
    var inputId = target.getAttribute('data-action-bdl-input');
    var state = bdl_curState();
    if (!state) {
        return;
    }
    var input = document.getElementById(inputId);
    var newVal = input ? input.value : '';
    if (!newVal) {
        cc_showAlert('Please enter or select a value.',
            { title: 'Value Required' });
        return;
    }
    var btn = input.parentElement.querySelector('.bdl-replace-btn');
    if (btn) {
        btn.disabled = true;
    }
    var skipBtn = input.parentElement.querySelector('.bdl-skip-btn');
    if (skipBtn) {
        skipBtn.disabled = true;
    }
    fetch('/api/bdl-import/replace-values', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ staging_table: state.stagingContext.staging_table,
            field: field, old_value: '', new_value: newVal })
    }).then(function(r) {
        if (!r.ok) {
            return r.json().then(function(d) {
                throw new Error(d.error || 'HTTP ' + r.status);
            });
        }
        return r.json();
    }).then(function(data) {
        var row = document.getElementById(inputId).closest('.bdl-lookup-replace-row');
        if (row) {
            row.innerHTML = '<span class="bdl-lrr-count">' + data.rows_updated + '</span>' +
                '<span class="bdl-lrr-value"><code class="bdl-lrr-value-code">(empty)</code> &#8594; ' +
                '<code class="bdl-lrr-value-code">' + cc_escapeHtml(newVal) + '</code></span>' +
                '<span class="bdl-lrr-action bdl-replace-done">&#10003; Filled</span>';
        }
        bdl_triggerCascadingRevalidate();
    }).catch(function(err) {
        cc_showAlert(err.message, { title: 'Fill Failed' });
        if (btn) {
            btn.disabled = false;
        }
        if (skipBtn) {
            skipBtn.disabled = false;
        }
    });
}

/* Skips the rows carrying an invalid or empty value, then re-validates. */
function bdl_skipRows(target) {
    if (bdl_revalidating) {
        return;
    }
    var field = target.getAttribute('data-action-bdl-field');
    var value = target.getAttribute('data-action-bdl-value');
    var rowElementId = target.getAttribute('data-action-bdl-row');
    var state = bdl_curState();
    if (!state) {
        return;
    }
    var rowEl = document.getElementById(rowElementId);
    if (rowEl) {
        rowEl.querySelectorAll('button').forEach(function(b) {
            b.disabled = true;
        });
    }
    fetch('/api/bdl-import/skip-rows', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ staging_table: state.stagingContext.staging_table, field: field, value: value })
    }).then(function(r) {
        if (!r.ok) {
            return r.json().then(function(d) {
                throw new Error(d.error || 'HTTP ' + r.status);
            });
        }
        return r.json();
    }).then(function(data) {
        var row = document.getElementById(rowElementId);
        if (row) {
            row.innerHTML = '<span class="bdl-lrr-count">' + data.rows_skipped + '</span>' +
                '<span class="bdl-lrr-value"><code class="bdl-lrr-value-code">' +
                cc_escapeHtml(value || '(empty)') + '</code></span>' +
                '<span class="bdl-lrr-action bdl-skip-done">&#10005; Skipped (' + data.rows_skipped + ' rows)</span>';
            if (row.dataset.bdlResolved !== undefined) {
                row.dataset.bdlResolved = 'true';
                bdl_checkLookupCardComplete(row);
            } else {
                bdl_triggerCascadingRevalidate();
            }
        }
    }).catch(function(err) {
        cc_showAlert(err.message, { title: 'Skip Failed' });
        if (rowEl) {
            rowEl.querySelectorAll('button').forEach(function(b) {
                b.disabled = false;
            });
        }
    });
}

/* ============================================================================
   FUNCTIONS: STEP 5 EXECUTE
   ----------------------------------------------------------------------------
   The execute review: the per-entity tabbed summary, the optional Jira ticket
   and AR-message fields, the row-count mismatch banner, the collapsible XML
   preview with syntax highlighting and copy, and the sequential executor that
   submits each entity's BDL and the consolidated AR log.
   Prefix: bdl
   ============================================================================ */

/* Renders the execute review with one tab per selected entity. */
function bdl_renderExecuteReview() {
    var area = document.getElementById('bdl-execute-area');
    var envName = bdl_selectedEnvironment ? bdl_selectedEnvironment.environment : '?';
    bdl_clearPromoteState();
    var html = '';
    html += '<div class="bdl-execute-ticket"><div class="bdl-execute-section-header bdl-execute-section-header-static">' +
        'Jira Ticket Link <span class="bdl-ticket-optional">(optional &mdash; applies to all imports)</span></div>' +
        '<div class="bdl-ticket-fields"><div class="bdl-ticket-field-row">' +
        '<label class="bdl-ticket-label" for="bdl-jira-ticket">Ticket</label>' +
        '<input type="text" id="bdl-jira-ticket" class="bdl-ticket-input" placeholder="SD-1234" ' +
        'data-action-input="bdl-ticket-changed"></div>' +
        '<div class="bdl-ticket-field-row bdl-hidden" id="bdl-ar-message-row">' +
        '<label class="bdl-ticket-label" for="bdl-ar-message">AR Message</label>' +
        '<input type="text" id="bdl-ar-message" class="bdl-ticket-input bdl-ticket-message-input" ' +
        'placeholder="Message for DM AR log"></div></div></div>';
    if (bdl_entityStates.length > 1) {
        var hasFixedOrHybrid = bdl_entityStates.some(function(s) {
            return s.entity.action_type === 'FIXED_VALUE' || s.entity.action_type === 'HYBRID';
        });
        var counts = bdl_entityStates.map(function(s) {
            return s.stagingContext ? s.stagingContext.row_count : 0;
        });
        var allSame = counts.every(function(c) {
            return c === counts[0];
        });
        if (!allSame && hasFixedOrHybrid) {
            html += '<div class="bdl-execute-mismatch-banner"><div class="bdl-mismatch-header">' +
                '<span class="bdl-mismatch-icon">&#9888;</span> Row counts differ across entities</div>' +
                '<div class="bdl-mismatch-detail">';
            bdl_entityStates.forEach(function(s) {
                html += '<div class="bdl-mismatch-entity"><span class="bdl-mismatch-name">' +
                    cc_escapeHtml(bdl_formatEntityName(s.entity.entity_type)) + '</span>' +
                    '<span class="bdl-mismatch-counts">' +
                    (s.stagingContext ? s.stagingContext.row_count : 0).toLocaleString() + ' active' +
                    (s.stagingContext && s.stagingContext.skipped_count > 0 ?
                        ', ' + s.stagingContext.skipped_count.toLocaleString() + ' skipped' : '') + '</span></div>';
            });
            html += '</div><div class="bdl-mismatch-actions"><button class="bdl-nav-btn bdl-enabled" ' +
                'data-action-click="bdl-show-alignment">Align Row Counts</button></div></div>';
        }
    }
    html += '<div class="bdl-execute-tabs" id="bdl-execute-tabs">';
    bdl_entityStates.forEach(function(state, idx) {
        html += '<div class="bdl-execute-tab' + (idx === 0 ? ' bdl-execute-tab-active' : '') +
            '" id="bdl-exec-tab-' + idx + '" data-action-click="bdl-execute-tab" data-action-bdl-idx="' + idx + '">' +
            cc_escapeHtml(bdl_formatEntityName(state.entity.entity_type)) + '</div>';
    });
    html += '</div>';
    bdl_entityStates.forEach(function(state, idx) {
        var visClass = idx === 0 ? '' : ' bdl-hidden';
        var entityName = bdl_formatEntityName(state.entity.entity_type);
        var rowCount = state.stagingContext ? state.stagingContext.row_count : 0;
        var skipped = state.stagingContext && state.stagingContext.skipped_count ?
            state.stagingContext.skipped_count : 0;
        var nullifyCount = state.nullifyFields ? state.nullifyFields.length : 0;
        var faCount = state.fieldAssignments ? Object.keys(state.fieldAssignments).length : 0;
        html += '<div class="bdl-execute-tab-content' + visClass + '" id="bdl-exec-content-' + idx + '">';
        html += '<div class="bdl-execute-summary"><div class="bdl-execute-summary-header">' +
            cc_escapeHtml(entityName) + '</div><div class="bdl-execute-summary-grid">';
        html += '<div class="bdl-summary-item"><span class="bdl-summary-label">Environment</span>' +
            '<span class="bdl-summary-value bdl-summary-env-' + envName.toLowerCase() + '">' + envName + '</span></div>';
        html += '<div class="bdl-summary-item"><span class="bdl-summary-label">Entity Type</span>' +
            '<span class="bdl-summary-value"><code class="bdl-summary-code">' +
            cc_escapeHtml(state.entity.entity_type) + '</code></span></div>';
        html += '<div class="bdl-summary-item bdl-summary-item-lastrow"><span class="bdl-summary-label">Rows</span>' +
            '<span class="bdl-summary-value">' + rowCount.toLocaleString() +
            (skipped > 0 ? ' <span class="bdl-summary-skipped">(' + skipped + ' skipped)</span>' : '') +
            '</span></div>';
        html += '<div class="bdl-summary-item bdl-summary-item-lastrow"><span class="bdl-summary-label">Staging Table</span>' +
            '<span class="bdl-summary-value"><code class="bdl-summary-code">' +
            cc_escapeHtml(state.stagingContext.staging_table) + '</code></span></div>';
        html += '</div></div>';
        var mappingKeys = Object.keys(state.columnMapping);
        if (mappingKeys.length > 0 || faCount > 0) {
            html += '<div class="bdl-execute-mapped-summary"><span class="bdl-mapped-summary-icon">&#128279;</span> ' +
                '<strong class="bdl-execute-mapped-summary-strong">Mapped Fields:</strong> ';
            var fieldCodes = mappingKeys.map(function(sc) {
                var te = state.columnMapping[sc];
                var nfField = state.fields ? state.fields.find(function(f) {
                    return f.element_name === te;
                }) : null;
                return '<code class="bdl-execute-mapped-summary-code">' +
                    cc_escapeHtml(nfField ? bdl_getFieldDisplayName(nfField) : te) + '</code>';
            });
            if (state.fieldAssignments) {
                Object.keys(state.fieldAssignments).forEach(function(elemName) {
                    var fa = state.fieldAssignments[elemName];
                    var fld = state.fields ? state.fields.find(function(f) {
                        return f.element_name === elemName;
                    }) : null;
                    var label = fld ? bdl_getFieldDisplayName(fld) : elemName;
                    var modeTag = fa.mode === 'conditional' ?
                        ' <span class="bdl-field-mode-tag-cond">(cond)</span>' :
                        ' <span class="bdl-field-mode-tag-fixed">(fixed)</span>';
                    fieldCodes.push('<code class="bdl-execute-mapped-summary-code">' +
                        cc_escapeHtml(label) + '</code>' + modeTag);
                });
            }
            html += fieldCodes.join(', ') + '</div>';
        }
        if (nullifyCount > 0) {
            html += '<div class="bdl-execute-nullify-summary"><span class="bdl-nullify-summary-icon">&#8709;</span> ' +
                '<strong class="bdl-execute-nullify-summary-strong">Nullify:</strong> ';
            html += state.nullifyFields.map(function(nf) {
                var nfField = state.fields ? state.fields.find(function(f) {
                    return f.element_name === nf;
                }) : null;
                return '<code class="bdl-execute-nullify-summary-code">' +
                    cc_escapeHtml(nfField ? bdl_getFieldDisplayName(nfField) : nf) + '</code>';
            }).join(', ');
            html += '</div>';
        }
        html += '<div class="bdl-execute-preview" id="bdl-exec-preview-' + idx + '">' +
            '<div class="bdl-execute-section-header bdl-execute-section-header-static bdl-xml-preview-header">' +
            '<button class="bdl-xml-preview-btn" data-action-click="bdl-preview-xml" data-action-bdl-idx="' + idx +
            '">&#128196; Preview XML <span class="bdl-section-toggle bdl-section-toggle-preview" ' +
            'id="bdl-xml-toggle-' + idx + '">&#9654;</span></button></div>' +
            '<div class="bdl-execute-section-body bdl-collapsed" id="bdl-xml-body-' + idx + '">' +
            '<div id="bdl-xml-content-' + idx + '"></div></div></div></div>';
    });
    html += '<div class="bdl-execute-results-all bdl-hidden" id="bdl-execute-results-all">' +
        '<div class="bdl-execute-results-header">Execution Results</div>' +
        '<div class="bdl-execute-results-list" id="bdl-execute-results-list"></div></div>';
    html += '<div class="bdl-execute-actions" id="bdl-execute-actions">';
    if (envName === 'PROD') {
        html += '<div class="bdl-execute-prod-warning">&#9888; You are about to import into ' +
            '<strong class="bdl-execute-prod-warning-strong">PRODUCTION</strong>. This action cannot be undone.</div>';
    }
    html += '<button class="bdl-execute-btn bdl-enabled" id="bdl-btn-execute-import" data-action-click="bdl-execute-all">' +
        'Submit All (' + bdl_entityStates.length + ' BDL' + (bdl_entityStates.length > 1 ? 's' : '') +
        ')</button></div>';
    html += '<div class="bdl-execute-progress bdl-hidden" id="bdl-execute-progress"></div>';
    area.innerHTML = html;
}

/* Switches the active execute tab and its content pane. */
function bdl_switchExecuteTab(target) {
    var idx = parseInt(target.getAttribute('data-action-bdl-idx'), 10);
    bdl_entityStates.forEach(function(_, i) {
        var tab = document.getElementById('bdl-exec-tab-' + i);
        var content = document.getElementById('bdl-exec-content-' + i);
        if (i === idx) {
            tab.classList.add('bdl-execute-tab-active');
            content.classList.remove('bdl-hidden');
        } else {
            tab.classList.remove('bdl-execute-tab-active');
            content.classList.add('bdl-hidden');
        }
    });
}

/* Switches the active execute tab by index (used during sequential execute). */
function bdl_switchExecuteTabByIndex(idx) {
    bdl_entityStates.forEach(function(_, i) {
        var tab = document.getElementById('bdl-exec-tab-' + i);
        var content = document.getElementById('bdl-exec-content-' + i);
        if (i === idx) {
            tab.classList.add('bdl-execute-tab-active');
            content.classList.remove('bdl-hidden');
        } else {
            tab.classList.remove('bdl-execute-tab-active');
            content.classList.add('bdl-hidden');
        }
    });
}

/* Builds and toggles the per-entity XML preview, fetching it once. */
function bdl_previewEntityXml(target) {
    var idx = parseInt(target.getAttribute('data-action-bdl-idx'), 10);
    var body = document.getElementById('bdl-xml-body-' + idx);
    var toggle = document.getElementById('bdl-xml-toggle-' + idx);
    var state = bdl_entityStates[idx];
    if (!body || !state || !state.stagingContext) {
        return;
    }
    if (state.xmlPreviewLoaded) {
        if (body.classList.contains('bdl-collapsed')) {
            body.classList.remove('bdl-collapsed');
            if (toggle) {
                toggle.innerHTML = '&#9660;';
            }
        } else {
            body.classList.add('bdl-collapsed');
            if (toggle) {
                toggle.innerHTML = '&#9654;';
            }
        }
        return;
    }
    body.classList.remove('bdl-collapsed');
    if (toggle) {
        toggle.innerHTML = '&#9660;';
    }
    var contentEl = document.getElementById('bdl-xml-content-' + idx);
    if (!contentEl) {
        return;
    }
    contentEl.innerHTML = '<div class="bdl-xml-preview-loading">Building XML preview...</div>';
    fetch('/api/bdl-import/build-preview', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ staging_table: state.stagingContext.staging_table,
            entity_type: state.entity.entity_type, config_id: bdl_selectedEnvironment.config_id })
    }).then(function(r) {
        if (!r.ok) {
            return r.json().then(function(d) {
                throw new Error(d.error || 'HTTP ' + r.status);
            });
        }
        return r.json();
    }).then(function(data) {
        var html = '<div class="bdl-xml-preview-header"><span class="bdl-xml-filename">' +
            cc_escapeHtml(data.xml_filename) + '</span><span class="bdl-xml-meta">' +
            data.row_count.toLocaleString() + ' rows';
        if (data.skipped_count > 0) {
            html += ', ' + data.skipped_count.toLocaleString() + ' skipped';
        }
        html += ' &middot; ' + (data.full_size_bytes / 1024).toFixed(1) + ' KB';
        if (data.truncated) {
            html += ' (preview truncated)';
        }
        html += '</span><button class="bdl-xml-copy-btn" data-action-click="bdl-copy-xml" ' +
            'data-action-bdl-idx="' + idx + '" title="Copy XML to clipboard">Copy</button></div>';
        html += '<pre class="bdl-xml-preview-code" id="bdl-xml-code-' + idx + '">' +
            bdl_highlightXml(data.xml) + '</pre>';
        contentEl.innerHTML = html;
        contentEl._rawXml = data.xml;
        state.xmlPreviewLoaded = true;
    }).catch(function(err) {
        contentEl.innerHTML = '<div class="bdl-xml-preview-loading bdl-inline-error">Preview failed: ' +
            cc_escapeHtml(err.message) + '</div>';
    });
}

/* Applies syntax-highlight spans to escaped XML for the preview block. */
function bdl_highlightXml(xml) {
    return cc_escapeHtml(xml)
        .replace(/^(&lt;\?xml.*?\?&gt;)/gm, '<span class="bdl-xml-decl">$1</span>')
        .replace(/(&lt;!--.*?--&gt;)/g, '<span class="bdl-xml-comment">$1</span>')
        .replace(/(&lt;\/?)([\w:_-]+)/g, '<span class="bdl-xml-bracket">$1</span><span class="bdl-xml-tag">$2</span>')
        .replace(/(\/?&gt;)/g, '<span class="bdl-xml-bracket">$1</span>')
        .replace(/\s([\w:_-]+)(=)(&quot;[^&]*?&quot;)/g,
            ' <span class="bdl-xml-attr-name">$1</span>$2<span class="bdl-xml-attr-val">$3</span>');
}

/* Copies the raw XML for an entity to the clipboard. */
function bdl_copyEntityXml(target) {
    var idx = parseInt(target.getAttribute('data-action-bdl-idx'), 10);
    var contentEl = document.getElementById('bdl-xml-content-' + idx);
    if (!contentEl || !contentEl._rawXml) {
        return;
    }
    var ta = document.createElement('textarea');
    ta.value = contentEl._rawXml;
    ta.className = 'bdl-offscreen-textarea';
    document.body.appendChild(ta);
    ta.focus();
    ta.select();
    try {
        document.execCommand('copy');
        var btn = contentEl.querySelector('.bdl-xml-copy-btn');
        if (btn) {
            btn.textContent = 'Copied!';
            btn.classList.add('bdl-xml-copy-btn-done');
            setTimeout(function() {
                btn.textContent = 'Copy';
                btn.classList.remove('bdl-xml-copy-btn-done');
            }, 2000);
        }
    } catch (e) {
        cc_showAlert('Failed to copy to clipboard.',
            { title: 'Copy Failed' });
    }
    document.body.removeChild(ta);
}

/* Shows/hides the AR message field as the Jira ticket value changes. */
function bdl_ticketChanged() {
    var ticketInput = document.getElementById('bdl-jira-ticket');
    var messageRow = document.getElementById('bdl-ar-message-row');
    var messageInput = document.getElementById('bdl-ar-message');
    var ticket = ticketInput ? ticketInput.value.trim() : '';
    if (ticket) {
        messageRow.classList.remove('bdl-hidden');
        if (!messageInput.dataset.bdlUserEdited) {
            messageInput.value = ticket + ': ' + bdl_entityStates.map(function(s) {
                return s.entity.entity_type;
            }).join(', ') + ' update via BDL Import';
        }
    } else {
        messageRow.classList.add('bdl-hidden');
        messageInput.value = '';
        messageInput.dataset.bdlUserEdited = '';
    }
}

/* Confirms the import, then begins sequential execution of all entities. */
function bdl_executeAll() {
    if (bdl_executeInProgress) {
        return;
    }
    var envName = bdl_selectedEnvironment.environment;
    var jiraTicket = (document.getElementById('bdl-jira-ticket') || {}).value || '';
    jiraTicket = jiraTicket.trim();
    var count = bdl_entityStates.length;
    var bodyHtml = '<p class="cc-dialog-paragraph">Submit ' + count + ' BDL import' + (count > 1 ? 's' : '') +
        ' to <strong class="bdl-summary-env-' + envName.toLowerCase() + '">' + envName + '</strong>?</p>';
    bdl_entityStates.forEach(function(s) {
        bodyHtml += '<p class="cc-dialog-paragraph bdl-confirm-entity-line">' +
            cc_escapeHtml(bdl_formatEntityName(s.entity.entity_type)) + ': ' +
            s.stagingContext.row_count.toLocaleString() + ' rows</p>';
    });
    if (envName === 'PROD') {
        bodyHtml += '<p class="cc-dialog-paragraph bdl-confirm-prod-warning">This is a PRODUCTION import and cannot be undone.</p>';
    }
    cc_showConfirm(bodyHtml, {
        title: 'Submit BDL Import' + (count > 1 ? 's' : ''),
        confirmLabel: 'Submit ' + (count > 1 ? 'All' : 'Import'),
        cancelLabel: 'Cancel',
        confirmClass: envName === 'PROD' ? 'cc-dialog-btn-danger' : 'cc-dialog-btn-primary',
        html: true
    }).then(function(confirmed) {
        if (!confirmed) {
            return;
        }
        bdl_executeInProgress = true;
        bdl_executeResultTracker = [];
        var execBtn = document.getElementById('bdl-btn-execute-import');
        if (execBtn) {
            execBtn.disabled = true;
            execBtn.textContent = 'Submitting...';
        }
        bdl_executeSequential(0, jiraTicket);
    });
}

/* Executes one entity, then recurses to the next, then the AR log. */
function bdl_executeSequential(idx, jiraTicket) {
    if (idx >= bdl_entityStates.length) {
        var hasSuccess = bdl_executeResultTracker.some(function(r) {
            return r.success;
        });
        if (jiraTicket && hasSuccess) {
            bdl_submitConsolidatedArLog(jiraTicket, function() {
                bdl_finishExecution();
            });
        } else {
            bdl_finishExecution();
        }
        return;
    }
    var state = bdl_entityStates[idx];
    var tabEl = document.getElementById('bdl-exec-tab-' + idx);
    var resultsPane = document.getElementById('bdl-execute-results-all');
    var resultsList = document.getElementById('bdl-execute-results-list');
    bdl_switchExecuteTabByIndex(idx);
    if (tabEl) {
        tabEl.innerHTML = cc_escapeHtml(bdl_formatEntityName(state.entity.entity_type)) +
            ' <span class="bdl-exec-tab-spinner">&#8943;</span>';
    }
    if (resultsPane) {
        resultsPane.classList.remove('bdl-hidden');
    }
    var entityName = bdl_formatEntityName(state.entity.entity_type);
    fetch('/api/bdl-import/execute', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ staging_table: state.stagingContext.staging_table,
            entity_type: state.entity.entity_type, config_id: bdl_selectedEnvironment.config_id,
            source_filename: bdl_uploadedFile ? bdl_uploadedFile.name : 'unknown',
            column_mapping: JSON.stringify(state.columnMapping) })
    }).then(function(r) {
        return r.json().then(function(d) {
            d._httpStatus = r.status;
            return d;
        });
    }).then(function(data) {
        var rh = '';
        if (data._httpStatus >= 400 || data.error) {
            rh += '<div class="bdl-execute-result-fail"><span class="bdl-result-icon-fail">&#10006;</span>' +
                '<div><strong class="bdl-result-strong-fail">' + cc_escapeHtml(entityName) +
                ' &mdash; Failed</strong><div class="bdl-result-detail">' + cc_escapeHtml(data.error) + '</div>' +
                (data.log_id ? '<div class="bdl-result-meta">Log ID: ' + data.log_id + '</div>' : '') + '</div></div>';
            if (tabEl) {
                tabEl.innerHTML = cc_escapeHtml(entityName) + ' <span class="bdl-exec-tab-fail">&#10006;</span>';
            }
            bdl_executeResultTracker.push({ entity_type: state.entity.entity_type,
                staging_table: state.stagingContext.staging_table, log_id: data.log_id || null, success: false });
        } else {
            rh += '<div class="bdl-execute-result-success"><span class="bdl-result-icon-success">&#10003;</span>' +
                '<div><strong class="bdl-result-strong-success">' + cc_escapeHtml(entityName) +
                ' &mdash; Submitted</strong><div class="bdl-result-meta">File: <code class="bdl-result-meta-code">' +
                cc_escapeHtml(data.xml_filename) + '</code> &middot; Registry ID: ' + data.file_registry_id +
                ' &middot; ' + data.row_count.toLocaleString() + ' rows</div></div></div>';
            if (tabEl) {
                tabEl.innerHTML = cc_escapeHtml(entityName) + ' <span class="bdl-exec-tab-success">&#10003;</span>';
            }
            bdl_executeResultTracker.push({ entity_type: state.entity.entity_type,
                staging_table: state.stagingContext.staging_table, log_id: data.log_id, success: true });
            if (!bdl_promoteData && data.promote_cooldown_seconds && data.prod_config_id) {
                bdl_promoteData = { cooldownSeconds: data.promote_cooldown_seconds,
                    prodConfigId: data.prod_config_id, sourceEnvironment: bdl_selectedEnvironment.environment };
            }
        }
        if (resultsList) {
            resultsList.innerHTML += rh;
        }
        bdl_executeSequential(idx + 1, jiraTicket);
    }).catch(function(err) {
        if (resultsList) {
            resultsList.innerHTML += '<div class="bdl-execute-result-fail">' +
                '<span class="bdl-result-icon-fail">&#10006;</span>' +
                '<div><strong class="bdl-result-strong-fail">' + cc_escapeHtml(entityName) +
                ' &mdash; Request Failed</strong><div class="bdl-result-detail">' +
                cc_escapeHtml(err.message) + '</div></div></div>';
        }
        if (tabEl) {
            tabEl.innerHTML = cc_escapeHtml(entityName) + ' <span class="bdl-exec-tab-fail">&#10006;</span>';
        }
        bdl_executeResultTracker.push({ entity_type: state.entity.entity_type,
            staging_table: state.stagingContext.staging_table, log_id: null, success: false });
        bdl_executeSequential(idx + 1, jiraTicket);
    });
}

/* Submits the consolidated AR log linking all successful imports to a ticket. */
function bdl_submitConsolidatedArLog(jiraTicket, callback) {
    var resultsList = document.getElementById('bdl-execute-results-list');
    var successResults = bdl_executeResultTracker.filter(function(r) {
        return r.success;
    });
    if (successResults.length === 0) {
        callback();
        return;
    }
    var arLogPresent = successResults.some(function(r) {
        return r.entity_type === 'CONSUMER_ACCOUNT_AR_LOG';
    });
    if (arLogPresent) {
        callback();
        return;
    }
    var entityTypes = successResults.map(function(r) {
        return r.entity_type;
    }).join(',');
    var parentLogIds = successResults.map(function(r) {
        return r.log_id;
    }).filter(function(id) {
        return id;
    }).join(',');
    var arMessage = (document.getElementById('bdl-ar-message') || {}).value || '';
    if (!arMessage.trim()) {
        arMessage = jiraTicket + ': ' + entityTypes + ' update via BDL Import';
    }
    fetch('/api/bdl-import/execute-ar-log', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ staging_table: successResults[0].staging_table, entity_types: entityTypes,
            jira_ticket: jiraTicket, ar_message: arMessage.trim(), config_id: bdl_selectedEnvironment.config_id,
            source_filename: bdl_uploadedFile ? bdl_uploadedFile.name : 'unknown', parent_log_ids: parentLogIds })
    }).then(function(r) {
        return r.json().then(function(d) {
            d._httpStatus = r.status;
            return d;
        });
    }).then(function(data) {
        var rh = data._httpStatus >= 400 || data.error ?
            '<div class="bdl-execute-result-warn bdl-execute-result-ar">' +
            '<span class="bdl-result-icon-warn">&#9888;</span><div>' +
            '<strong class="bdl-result-strong-warn">AR Log &mdash; Failed</strong>' +
            '<div class="bdl-result-detail">' + cc_escapeHtml(data.error) + '</div></div></div>' :
            '<div class="bdl-execute-result-success bdl-execute-result-ar">' +
            '<span class="bdl-result-icon-success">&#10003;</span><div>' +
            '<strong class="bdl-result-strong-success">AR Log &mdash; Submitted</strong>' +
            '<div class="bdl-result-meta">' + data.row_count.toLocaleString() + ' records linked to ' +
            cc_escapeHtml(jiraTicket) + ' (' + cc_escapeHtml(entityTypes) + ')</div></div></div>';
        if (resultsList) {
            resultsList.innerHTML += rh;
        }
        callback();
    }).catch(function(err) {
        if (resultsList) {
            resultsList.innerHTML += '<div class="bdl-execute-result-warn bdl-execute-result-ar">' +
                '<span class="bdl-result-icon-warn">&#9888;</span><div>' +
                '<strong class="bdl-result-strong-warn">AR Log &mdash; Request Failed</strong>' +
                '<div class="bdl-result-detail">' + cc_escapeHtml(err.message) + '</div></div></div>';
        }
        callback();
    });
}

/* Finalizes the execute step and shows the promote card when applicable. */
function bdl_finishExecution() {
    bdl_executeInProgress = false;
    var actions = document.getElementById('bdl-execute-actions');
    if (actions) {
        actions.classList.add('bdl-hidden');
    }
    bdl_stepComplete[4] = true;
    bdl_updateStepperUI();
    bdl_updateNavButtons();
    if (bdl_promoteData && bdl_promoteData.cooldownSeconds && bdl_promoteData.prodConfigId) {
        bdl_renderPromoteCard(bdl_promoteData.sourceEnvironment);
    }
}

/* Toggles a collapsible execute section open or closed. */
function bdl_toggleExecuteSection(target) {
    var bodyId = target.getAttribute('data-action-bdl-body');
    var body = document.getElementById(bodyId);
    if (!body) {
        return;
    }
    body.classList.toggle('bdl-collapsed');
}

/* ============================================================================
   FUNCTIONS: ALIGNMENT
   ----------------------------------------------------------------------------
   The row-count alignment flow for multi-entity imports: a dynamic modal that
   trims each fixed-value entity's row set to match a chosen mapped entity by
   identifier, plus the per-entity undo.
   Prefix: bdl
   ============================================================================ */

/* Returns the identifier column for the first entity (consumer or account). */
function bdl_getIdentifierColumn() {
    var firstEntity = bdl_entityStates[0];
    if (!firstEntity) {
        return 'cnsmr_idntfr_agncy_id';
    }
    return firstEntity.entity.entity_key === 'ACCOUNT' ?
        'cnsmr_accnt_idntfr_agncy_id' : 'cnsmr_idntfr_agncy_id';
}

/* Builds and shows the row-count alignment dynamic modal. */
function bdl_showAlignmentModal() {
    var mappedEntities = bdl_entityStates.filter(function(s) {
        return s.entity.action_type === 'FILE_MAPPED';
    });
    var alignableEntities = bdl_entityStates.filter(function(s) {
        return s.entity.action_type === 'FIXED_VALUE' || s.entity.action_type === 'HYBRID';
    });
    if (alignableEntities.length === 0 || mappedEntities.length === 0) {
        return;
    }
    var bodyHtml = '<p class="cc-dialog-paragraph bdl-alignment-intro">Choose which mapped entity ' +
        'each fixed-value entity should align its row set to.</p>';
    alignableEntities.forEach(function(s) {
        var entityIdx = bdl_entityStates.indexOf(s);
        bodyHtml += '<div class="bdl-alignment-row" id="bdl-align-row-' + entityIdx + '">' +
            '<div class="bdl-alignment-entity-info"><span class="bdl-alignment-entity-name">' +
            cc_escapeHtml(bdl_formatEntityName(s.entity.entity_type)) + '</span>' +
            '<span class="bdl-alignment-entity-counts">' +
            (s.stagingContext ? s.stagingContext.row_count : 0).toLocaleString() + ' active' +
            (s.stagingContext && s.stagingContext.skipped_count > 0 ?
                ', ' + s.stagingContext.skipped_count.toLocaleString() + ' skipped' : '') + '</span></div>' +
            '<div class="bdl-alignment-select-row"><label class="bdl-alignment-label">Align to:</label>' +
            '<select class="bdl-alignment-dropdown" id="bdl-align-select-' + entityIdx + '">' +
            '<option value="">Keep all rows</option>';
        mappedEntities.forEach(function(m) {
            bodyHtml += '<option value="' + bdl_entityStates.indexOf(m) + '">' +
                cc_escapeHtml(bdl_formatEntityName(m.entity.entity_type)) + ' (' +
                (m.stagingContext ? m.stagingContext.row_count : 0).toLocaleString() + ' rows)</option>';
        });
        bodyHtml += '</select><button class="bdl-skip-btn bdl-enabled bdl-alignment-undo-btn bdl-hidden" ' +
            'id="bdl-align-undo-' + entityIdx + '" data-action-click="bdl-reset-alignment" ' +
            'data-action-bdl-idx="' + entityIdx + '">Undo</button></div></div>';
    });
    document.getElementById('bdl-alignment-body').innerHTML = bodyHtml;
    var applyBtn = document.querySelector('#bdl-modal-alignment .cc-dialog-btn-primary');
    if (applyBtn) {
        applyBtn.disabled = false;
        applyBtn.textContent = 'Apply';
    }
    document.getElementById('bdl-modal-alignment').classList.remove('cc-hidden');
}

/* Closes the alignment modal (backdrop or explicit control). */
function bdl_closeAlignment(target, event) {
    if (event && target.id === 'bdl-modal-alignment' && event.target !== target) {
        return;
    }
    document.getElementById('bdl-modal-alignment').classList.add('cc-hidden');
}

/* Applies the chosen alignments, trimming each target to its source set. */
function bdl_applyAlignment() {
    var alignableEntities = bdl_entityStates.filter(function(s) {
        return s.entity.action_type === 'FIXED_VALUE' || s.entity.action_type === 'HYBRID';
    });
    var idCol = bdl_getIdentifierColumn();
    var pending = [];
    alignableEntities.forEach(function(s) {
        var entityIdx = bdl_entityStates.indexOf(s);
        var sel = document.getElementById('bdl-align-select-' + entityIdx);
        if (!sel || sel.value === '') {
            return;
        }
        var sourceIdx = parseInt(sel.value, 10);
        var sourceState = bdl_entityStates[sourceIdx];
        if (!sourceState || !sourceState.stagingContext || !s.stagingContext) {
            return;
        }
        pending.push({ targetIdx: entityIdx, sourceIdx: sourceIdx,
            targetTable: s.stagingContext.staging_table, sourceTable: sourceState.stagingContext.staging_table });
    });
    if (pending.length === 0) {
        document.getElementById('bdl-modal-alignment').classList.add('cc-hidden');
        return;
    }
    var applyBtn = document.querySelector('#bdl-modal-alignment .cc-dialog-btn-primary');
    if (applyBtn) {
        applyBtn.disabled = true;
        applyBtn.textContent = 'Aligning...';
    }
    var completed = 0;
    pending.forEach(function(item) {
        fetch('/api/bdl-import/align-rows', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ source_table: item.sourceTable, target_table: item.targetTable,
                identifier_column: idCol })
        }).then(function(r) {
            if (!r.ok) {
                return r.json().then(function(d) {
                    throw new Error(d.error || 'HTTP ' + r.status);
                });
            }
            return r.json();
        }).then(function(data) {
            bdl_entityStates[item.targetIdx].stagingContext.row_count = data.active_count;
            bdl_entityStates[item.targetIdx].stagingContext.skipped_count = data.skipped_count;
            completed++;
            if (completed >= pending.length) {
                document.getElementById('bdl-modal-alignment').classList.add('cc-hidden');
                bdl_renderExecuteReview();
            }
        }).catch(function(err) {
            completed++;
            cc_showAlert('Alignment failed: ' + err.message,
                { title: 'Alignment Error' });
            if (completed >= pending.length) {
                document.getElementById('bdl-modal-alignment').classList.add('cc-hidden');
                bdl_renderExecuteReview();
            }
        });
    });
}

/* Resets one entity's alignment, restoring its full row set. */
function bdl_resetAlignment(target) {
    var entityIdx = parseInt(target.getAttribute('data-action-bdl-idx'), 10);
    var state = bdl_entityStates[entityIdx];
    if (!state || !state.stagingContext) {
        return;
    }
    var undoBtn = document.getElementById('bdl-align-undo-' + entityIdx);
    if (undoBtn) {
        undoBtn.disabled = true;
        undoBtn.textContent = 'Resetting...';
    }
    fetch('/api/bdl-import/reset-alignment', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ staging_table: state.stagingContext.staging_table })
    }).then(function(r) {
        if (!r.ok) {
            return r.json().then(function(d) {
                throw new Error(d.error || 'HTTP ' + r.status);
            });
        }
        return r.json();
    }).then(function(data) {
        state.stagingContext.row_count = data.active_count;
        state.stagingContext.skipped_count = 0;
        var row = document.getElementById('bdl-align-row-' + entityIdx);
        if (row) {
            var countsEl = row.querySelector('.bdl-alignment-entity-counts');
            if (countsEl) {
                countsEl.textContent = data.active_count.toLocaleString() + ' active';
            }
        }
        var sel = document.getElementById('bdl-align-select-' + entityIdx);
        if (sel) {
            sel.value = '';
        }
        if (undoBtn) {
            undoBtn.classList.add('bdl-hidden');
            undoBtn.disabled = false;
            undoBtn.textContent = 'Undo';
        }
    }).catch(function(err) {
        cc_showAlert('Reset failed: ' + err.message,
            { title: 'Reset Error' });
        if (undoBtn) {
            undoBtn.disabled = false;
            undoBtn.textContent = 'Undo';
        }
    });
}

/* ============================================================================
   FUNCTIONS: PROMOTE TO PRODUCTION
   ----------------------------------------------------------------------------
   The post-import promote card shown after a successful TEST/STAGE import: a
   cooldown countdown that unlocks the card, the early-click hint flash, and
   the production advisory dynamic modal that re-targets the wizard at PROD.
   Prefix: bdl
   ============================================================================ */

/* Renders the promote-to-production card beneath the results pane. */
function bdl_renderPromoteCard(sourceEnv) {
    var resultsPane = document.getElementById('bdl-execute-results-all');
    if (!resultsPane) {
        return;
    }
    var existing = document.getElementById('bdl-promote-area');
    if (existing) {
        existing.remove();
    }
    var promoteDiv = document.createElement('div');
    promoteDiv.id = 'bdl-promote-area';
    promoteDiv.className = 'bdl-promote-area';
    bdl_promoteSecondsRemaining = bdl_promoteData.cooldownSeconds;
    bdl_promoteReady = false;
    promoteDiv.innerHTML = '<div class="bdl-promote-card" id="bdl-promote-card" ' +
        'data-action-click="bdl-promote-card">' +
        '<div class="bdl-promote-card-header">' +
        '<span class="bdl-promote-card-icon">&#128274;</span>' +
        '<span class="bdl-promote-card-title">Promote to Production</span>' +
        '<span class="bdl-promote-card-status" id="bdl-promote-status">Locked</span>' +
        '</div>' +
        '<div class="bdl-promote-card-timer" id="bdl-promote-timer">' +
        '<span class="bdl-promote-card-timer-prefix">Available in</span>' +
        bdl_formatCountdown(bdl_promoteSecondsRemaining) +
        '</div>' +
        '<div class="bdl-promote-card-hint" id="bdl-promote-hint">This button unlocks when the cooldown timer ' +
        'expires. Use this time to verify your ' + cc_escapeHtml(sourceEnv) +
        ' import results in Debt Manager.</div>' +
        '</div>';
    resultsPane.parentNode.insertBefore(promoteDiv, resultsPane.nextSibling);
    bdl_startPromoteCountdown();
}

/* Formats a second count as a m:ss or Ns countdown string. */
function bdl_formatCountdown(seconds) {
    var m = Math.floor(seconds / 60);
    var s = seconds % 60;
    return (m > 0 ? m + ':' : '') + (m > 0 && s < 10 ? '0' : '') + s + (m === 0 ? 's' : '');
}

/* Runs the promote cooldown countdown and unlocks the card at zero. */
function bdl_startPromoteCountdown() {
    if (bdl_promoteCountdownTimer) {
        clearInterval(bdl_promoteCountdownTimer);
    }
    bdl_promoteCountdownTimer = setInterval(function() {
        bdl_promoteSecondsRemaining--;
        var timerEl = document.getElementById('bdl-promote-timer');
        var hintEl = document.getElementById('bdl-promote-hint');
        var statusEl = document.getElementById('bdl-promote-status');
        var iconEl = document.querySelector('#bdl-promote-card .bdl-promote-card-icon');
        var card = document.getElementById('bdl-promote-card');
        if (bdl_promoteSecondsRemaining <= 0) {
            clearInterval(bdl_promoteCountdownTimer);
            bdl_promoteCountdownTimer = null;
            bdl_promoteReady = true;
            if (timerEl) {
                timerEl.textContent = 'Click to promote this import to Production';
                timerEl.classList.add('bdl-promote-ready');
            }
            if (hintEl) {
                hintEl.textContent = 'Your test import results have had time for review. ' +
                    'Click the card above to begin the Production promotion.';
            }
            if (statusEl) {
                statusEl.textContent = 'Ready';
                statusEl.classList.add('bdl-promote-ready');
            }
            if (iconEl) {
                iconEl.innerHTML = '&#10003;';
                iconEl.classList.add('bdl-promote-ready');
            }
            if (card) {
                card.classList.add('bdl-promote-ready');
                var titleEl = card.querySelector('.bdl-promote-card-title');
                if (titleEl) {
                    titleEl.classList.add('bdl-promote-ready');
                }
                var prefixEl = card.querySelector('.bdl-promote-card-timer-prefix');
                if (prefixEl) {
                    prefixEl.classList.add('bdl-promote-ready');
                }
            }
        } else {
            if (timerEl) {
                timerEl.innerHTML = '<span class="bdl-promote-card-timer-prefix">Available in</span>' +
                    bdl_formatCountdown(bdl_promoteSecondsRemaining);
            }
        }
    }, 1000);
}

/* Handles a promote-card click: flashes the hint if locked, else promotes. */
function bdl_promoteCardClicked() {
    if (!bdl_promoteReady) {
        var hintEl = document.getElementById('bdl-promote-hint');
        if (hintEl) {
            hintEl.classList.add('bdl-promote-hint-flash');
            setTimeout(function() {
                hintEl.classList.remove('bdl-promote-hint-flash');
            }, 1500);
        }
        return;
    }
    bdl_promoteToProduction();
}

/* Loads the production environment config, then shows the promote advisory. */
function bdl_promoteToProduction() {
    if (!bdl_promoteData || !bdl_promoteData.prodConfigId) {
        return;
    }
    fetch('/api/bdl-import/environments').then(function(r) {
        return r.json();
    }).then(function(data) {
        var prodEnv = (data.environments || []).find(function(e) {
            return e.config_id === bdl_promoteData.prodConfigId;
        });
        if (!prodEnv) {
            cc_showAlert('Production environment configuration not found.',
                { title: 'Promote Error' });
            return;
        }
        bdl_showPromoteProdAdvisory(prodEnv);
    }).catch(function(err) {
        cc_showAlert('Failed to load environments: ' + err.message,
            { title: 'Promote Error' });
    });
}

/* Builds and shows the production-promote advisory dynamic modal. */
function bdl_showPromoteProdAdvisory(prodEnv) {
    bdl_pendingPromoteConfigId = prodEnv.config_id;
    var entityList = '';
    bdl_entityStates.forEach(function(s) {
        entityList += '<div class="bdl-promote-entity-line">' +
            cc_escapeHtml(bdl_formatEntityName(s.entity.entity_type)) + ': ' +
            s.stagingContext.row_count.toLocaleString() + ' rows</div>';
    });
    document.getElementById('bdl-promote-advisory-body').innerHTML =
        '<p class="cc-dialog-paragraph">You are about to promote your <strong class="cc-dialog-strong">' +
        cc_escapeHtml(bdl_promoteData.sourceEnvironment) +
        '</strong> import to <strong class="cc-dialog-strong">Production</strong>.</p>' +
        '<p class="cc-dialog-paragraph">The same staging data will be submitted to the production environment:</p>' +
        entityList +
        '<p class="cc-dialog-paragraph cc-last bdl-promote-prod-warning">This is a PRODUCTION import and cannot be undone.</p>';
    document.getElementById('bdl-modal-promote-advisory').classList.remove('cc-hidden');
}

/* Closes the promote-advisory modal (backdrop or explicit control). */
function bdl_closePromoteAdvisory(target, event) {
    if (event && target.id === 'bdl-modal-promote-advisory' && event.target !== target) {
        return;
    }
    document.getElementById('bdl-modal-promote-advisory').classList.add('cc-hidden');
}

/* Re-targets the wizard at production and re-renders the execute review. */
function bdl_promoteAdvisoryContinue() {
    document.getElementById('bdl-modal-promote-advisory').classList.add('cc-hidden');
    var prodConfigId = bdl_pendingPromoteConfigId;
    bdl_pendingPromoteConfigId = null;
    fetch('/api/bdl-import/environments').then(function(r) {
        return r.json();
    }).then(function(data) {
        var prodEnv = (data.environments || []).find(function(e) {
            return e.config_id === prodConfigId;
        });
        if (!prodEnv) {
            return;
        }
        bdl_selectedEnvironment = prodEnv;
        bdl_stepComplete[4] = false;
        bdl_executeInProgress = false;
        bdl_clearPromoteState();
        bdl_entityStates.forEach(function(s) {
            s.xmlPreviewLoaded = false;
        });
        bdl_updateEnvBadge();
        bdl_renderExecuteReview();
    });
}

/* Clears any active promote countdown and promote state. */
function bdl_clearPromoteState() {
    if (bdl_promoteCountdownTimer) {
        clearInterval(bdl_promoteCountdownTimer);
        bdl_promoteCountdownTimer = null;
    }
    bdl_promoteData = null;
    bdl_promoteReady = false;
    bdl_promoteSecondsRemaining = 0;
    var existing = document.getElementById('bdl-promote-area');
    if (existing) {
        existing.remove();
    }
}

/* ============================================================================
   FUNCTIONS: TEMPLATES
   ----------------------------------------------------------------------------
   The saved mapping templates panel: loading and rendering the template list
   for the current entity, the file-match count, the preview slideout (static
   slide overlay), applying a template to the current mapping, and the save
   and delete flows (delete gated server-side via the can_delete flag).
   Prefix: bdl
   ============================================================================ */

/* Loads the saved templates for an entity type and renders the list. */
function bdl_loadTemplates(entityType) {
    bdl_entityTemplates = [];
    var list = document.getElementById('bdl-template-list');
    if (!list) {
        return;
    }
    list.innerHTML = '<div class="bdl-template-empty">Loading templates...</div>';
    fetch('/api/bdl-import/templates?entity_type=' + encodeURIComponent(entityType)).then(function(r) {
        return r.json();
    }).then(function(data) {
        bdl_entityTemplates = data.templates || [];
        bdl_templateCanDelete = !!data.can_delete;
        bdl_renderTemplateList();
    }).catch(function() {
        list.innerHTML = '<div class="bdl-template-empty">Failed to load templates.</div>';
    });
}

/* Renders the saved-template cards with per-template file-match counts. */
function bdl_renderTemplateList() {
    var list = document.getElementById('bdl-template-list');
    if (!list) {
        return;
    }
    if (!bdl_entityTemplates.length) {
        list.innerHTML = '<div class="bdl-template-empty">No saved templates for this entity type.</div>';
        return;
    }
    var html = '';
    bdl_entityTemplates.forEach(function(t) {
        var mapping = {};
        try {
            mapping = JSON.parse(t.column_mapping);
        } catch (e) {
            mapping = {};
        }
        var fieldCount = Object.keys(mapping).length;
        var matchInfo = '';
        if (bdl_currentStep === 4 && bdl_parsedFileData) {
            var mc = bdl_countTemplateMatches(mapping);
            matchInfo = '<span class="bdl-template-match">' + mc + ' of ' + fieldCount + ' fields match</span>';
        }
        var creator = t.created_by || '';
        if (creator.indexOf('\\') !== -1) {
            creator = creator.split('\\')[1];
        }
        var activeCls = (bdl_activeTemplateId === t.template_id) ? ' bdl-template-card-active' : '';
        html += '<div class="bdl-template-card' + activeCls + '" data-action-click="bdl-preview-template" ' +
            'data-action-bdl-template-id="' + t.template_id + '"><div class="bdl-template-card-name">' +
            cc_escapeHtml(t.template_name) + '</div>';
        if (t.description) {
            html += '<div class="bdl-template-card-desc">' + cc_escapeHtml(t.description) + '</div>';
        }
        html += '<div class="bdl-template-card-meta">' + fieldCount + ' fields &middot; ' +
            cc_escapeHtml(creator) + (matchInfo ? ' &middot; ' + matchInfo : '') + '</div></div>';
    });
    list.innerHTML = html;
}

/* Counts how many of a template's source columns exist in the loaded file. */
function bdl_countTemplateMatches(mapping) {
    if (!bdl_parsedFileData) {
        return 0;
    }
    var count = 0;
    var fh = bdl_parsedFileData.headers.map(function(h) {
        return h.toUpperCase();
    });
    Object.keys(mapping).forEach(function(sc) {
        if (fh.indexOf(sc.toUpperCase()) !== -1) {
            count++;
        }
    });
    return count;
}

/* Shows or hides the save-template control based on step and mapping state. */
function bdl_updateTemplateSectionState() {
    var saveArea = document.getElementById('bdl-template-save-area');
    var state = bdl_curState();
    if (saveArea) {
        if (bdl_currentStep === 4 && state && Object.keys(state.columnMapping).length > 0) {
            saveArea.classList.remove('bdl-hidden');
        } else {
            saveArea.classList.add('bdl-hidden');
        }
    }
    if (bdl_entityTemplates.length > 0) {
        bdl_renderTemplateList();
    }
}

/* Fills and opens the template preview slideout (static slide overlay). */
function bdl_previewTemplate(target) {
    var templateId = parseInt(target.getAttribute('data-action-bdl-template-id'), 10);
    var template = bdl_entityTemplates.find(function(t) {
        return t.template_id === templateId;
    });
    if (!template) {
        return;
    }
    var mapping = {};
    try {
        mapping = JSON.parse(template.column_mapping);
    } catch (e) {
        mapping = {};
    }
    var mappingKeys = Object.keys(mapping);
    document.getElementById('bdl-template-preview-title').textContent = template.template_name;
    var html = '';
    var creator = template.created_by || '';
    if (creator.indexOf('\\') !== -1) {
        creator = creator.split('\\')[1];
    }
    html += '<div class="bdl-slideout-meta">';
    if (template.description) {
        html += '<div class="bdl-slideout-desc">' + cc_escapeHtml(template.description) + '</div>';
    }
    html += '<div class="bdl-slideout-creator">Created by <strong>' + cc_escapeHtml(creator) + '</strong></div></div>';
    if (bdl_parsedFileData && bdl_currentStep === 4) {
        var mc = bdl_countTemplateMatches(mapping);
        var matchClass = (mc === mappingKeys.length) ? 'bdl-slideout-match-full' :
            (mc > 0 ? 'bdl-slideout-match-partial' : 'bdl-slideout-match-none');
        html += '<div class="bdl-slideout-match-summary ' + matchClass + '">' + mc + ' of ' +
            mappingKeys.length + ' mapped columns found in your file</div>';
    }
    html += '<div class="bdl-slideout-mappings-header">Column Mappings (' + mappingKeys.length +
        ')</div><div class="bdl-slideout-mappings">';
    var fileHeaders = bdl_parsedFileData ? bdl_parsedFileData.headers.map(function(h) {
        return h.toUpperCase();
    }) : [];
    mappingKeys.forEach(function(sourceCol) {
        var elementName = mapping[sourceCol];
        var displayName = bdl_getFieldDisplayNameByElement(elementName);
        var matched = fileHeaders.indexOf(sourceCol.toUpperCase()) !== -1;
        html += '<div class="bdl-slideout-pair' +
            (bdl_parsedFileData ? (matched ? ' bdl-slideout-pair-match' : ' bdl-slideout-pair-miss') : '') +
            '"><span class="bdl-slideout-pair-source">' + cc_escapeHtml(sourceCol) + '</span>' +
            '<span class="bdl-slideout-pair-arrow">&#8594;</span>';
        if (displayName !== elementName) {
            html += '<span class="bdl-slideout-pair-target">' + cc_escapeHtml(displayName) +
                ' <code class="bdl-slideout-pair-target-code">' + elementName + '</code></span>';
        } else {
            html += '<span class="bdl-slideout-pair-target"><code class="bdl-slideout-pair-target-code">' +
                elementName + '</code></span>';
        }
        if (bdl_parsedFileData) {
            html += '<span class="bdl-slideout-pair-status ' +
                (matched ? 'bdl-slideout-pair-status-match' : 'bdl-slideout-pair-status-miss') + '">' +
                (matched ? '&#10003;' : '&#10005;') + '</span>';
        }
        html += '</div>';
    });
    html += '</div>';
    if (bdl_currentStep === 4 && bdl_parsedFileData) {
        html += '<div class="bdl-slideout-actions"><button class="bdl-slideout-apply-btn" ' +
            'data-action-click="bdl-apply-template" data-action-bdl-template-id="' + templateId +
            '">Apply Template</button></div>';
    }
    if (bdl_templateCanDelete) {
        html += '<div class="bdl-slideout-danger"><button class="bdl-slideout-delete-btn" ' +
            'data-action-click="bdl-delete-template" data-action-bdl-template-id="' + templateId +
            '">Delete Template</button></div>';
    }
    document.getElementById('bdl-template-preview-body').innerHTML = html;
    var overlay = document.getElementById('bdl-slideout-template-preview');
    var dialog = overlay.querySelector('.cc-dialog');
    overlay.classList.add('cc-open');
    requestAnimationFrame(function() {
        dialog.classList.add('cc-open');
    });
}

/* Closes the template preview slideout (static slide overlay). */
function bdl_closeTemplatePreview(target, event) {
    var overlay = document.getElementById('bdl-slideout-template-preview');
    if (event && target.id === 'bdl-slideout-template-preview' && event.target !== target) {
        return;
    }
    var dialog = overlay.querySelector('.cc-dialog');
    dialog.addEventListener('transitionend', function handler() {
        dialog.removeEventListener('transitionend', handler);
        overlay.classList.remove('cc-open');
    });
    dialog.classList.remove('cc-open');
}

/* Applies a template's mapping to the current entity and re-renders. */
function bdl_applyTemplate(target) {
    var templateId = parseInt(target.getAttribute('data-action-bdl-template-id'), 10);
    var template = bdl_entityTemplates.find(function(t) {
        return t.template_id === templateId;
    });
    var state = bdl_curState();
    if (!template || !bdl_parsedFileData || !state) {
        return;
    }
    var templateMapping = {};
    try {
        templateMapping = JSON.parse(template.column_mapping);
    } catch (e) {
        return;
    }
    var fileHeaderMap = {};
    bdl_parsedFileData.headers.forEach(function(h) {
        fileHeaderMap[h.toUpperCase()] = h;
    });
    state.columnMapping = {};
    Object.keys(templateMapping).forEach(function(sourceCol) {
        var actualHeader = fileHeaderMap[sourceCol.toUpperCase()];
        if (actualHeader) {
            state.columnMapping[actualHeader] = templateMapping[sourceCol];
        }
    });
    bdl_activeTemplateId = templateId;
    bdl_closeTemplatePreviewImmediate();
    bdl_renderMapValidateMapping(document.getElementById('bdl-map-validate-area'), state);
    bdl_renderTemplateList();
}

/* Closes the preview slideout without the transition (used after apply). */
function bdl_closeTemplatePreviewImmediate() {
    var overlay = document.getElementById('bdl-slideout-template-preview');
    if (!overlay) {
        return;
    }
    var dialog = overlay.querySelector('.cc-dialog');
    if (dialog) {
        dialog.classList.remove('cc-open');
    }
    overlay.classList.remove('cc-open');
}

/* Opens the save-template modal (static modal) and fills the mapping preview. */
function bdl_showSaveTemplate() {
    var state = bdl_curState();
    if (!state || Object.keys(state.columnMapping).length === 0) {
        return;
    }
    var nameInput = document.getElementById('bdl-save-template-name');
    var descInput = document.getElementById('bdl-save-template-desc');
    var status = document.getElementById('bdl-save-template-status');
    nameInput.value = '';
    descInput.value = '';
    status.classList.add('bdl-hidden');
    var preview = document.getElementById('bdl-save-template-preview');
    var mKeys = Object.keys(state.columnMapping);
    var html = '<div class="bdl-template-modal-preview-header">' + mKeys.length + ' mapping(s):</div>';
    mKeys.forEach(function(sc) {
        var te = state.columnMapping[sc];
        var dn = bdl_getFieldDisplayNameByElement(te);
        html += '<div class="bdl-template-modal-preview-row"><span class="bdl-slideout-pair-source">' +
            cc_escapeHtml(sc) + '</span><span class="bdl-slideout-pair-arrow">&#8594;</span>' +
            '<span class="bdl-slideout-pair-target">' +
            (dn !== te ? cc_escapeHtml(dn) + ' <span class="bdl-slideout-pair-element">' + te + '</span>' : te) +
            '</span></div>';
    });
    preview.innerHTML = html;
    document.getElementById('bdl-modal-save-template').classList.remove('cc-hidden');
    nameInput.focus();
}

/* Closes the save-template modal (static modal). */
function bdl_closeSaveTemplate(target, event) {
    if (event && target.id === 'bdl-modal-save-template' && event.target !== target) {
        return;
    }
    document.getElementById('bdl-modal-save-template').classList.add('cc-hidden');
}

/* Saves the current mapping as a named template. */
function bdl_saveTemplate() {
    var state = bdl_curState();
    if (!state) {
        return;
    }
    var nameInput = document.getElementById('bdl-save-template-name');
    var descInput = document.getElementById('bdl-save-template-desc');
    var status = document.getElementById('bdl-save-template-status');
    var name = nameInput.value.trim();
    if (!name) {
        nameInput.focus();
        nameInput.classList.add('bdl-template-modal-input-error');
        return;
    }
    nameInput.classList.remove('bdl-template-modal-input-error');
    fetch('/api/bdl-import/templates', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ entity_type: state.entity.entity_type, template_name: name,
            description: descInput.value.trim() || null, column_mapping: JSON.stringify(state.columnMapping) })
    }).then(function(r) {
        return r.json().then(function(d) {
            d._httpStatus = r.status;
            return d;
        });
    }).then(function(data) {
        if (data._httpStatus >= 400 || data.error) {
            status.textContent = data.error || 'Failed.';
            status.className = 'bdl-template-modal-status bdl-template-modal-error';
            status.classList.remove('bdl-hidden');
        } else {
            status.textContent = 'Saved!';
            status.className = 'bdl-template-modal-status bdl-template-modal-success';
            status.classList.remove('bdl-hidden');
            bdl_activeTemplateId = data.template_id;
            setTimeout(function() {
                document.getElementById('bdl-modal-save-template').classList.add('cc-hidden');
                bdl_loadTemplates(state.entity.entity_type);
            }, 1000);
        }
    }).catch(function(err) {
        status.textContent = 'Error: ' + err.message;
        status.className = 'bdl-template-modal-status bdl-template-modal-error';
        status.classList.remove('bdl-hidden');
    });
}

/* Deletes a template after confirmation (delete capability is server-gated). */
function bdl_deleteTemplate(target) {
    var templateId = parseInt(target.getAttribute('data-action-bdl-template-id'), 10);
    var template = bdl_entityTemplates.find(function(t) {
        return t.template_id === templateId;
    });
    if (!template) {
        return;
    }
    cc_showConfirm('Delete template "' + cc_escapeHtml(template.template_name) + '"?', {
        title: 'Delete Template', confirmLabel: 'Delete', cancelLabel: 'Keep',
        confirmClass: 'cc-dialog-btn-danger'
    }).then(function(confirmed) {
        if (!confirmed) {
            return;
        }
        var state = bdl_curState();
        fetch('/api/bdl-import/templates/' + templateId, { method: 'DELETE' }).then(function(r) {
            return r.json();
        }).then(function(data) {
            if (data.success) {
                if (bdl_activeTemplateId === templateId) {
                    bdl_activeTemplateId = null;
                }
                bdl_closeTemplatePreviewImmediate();
                if (state) {
                    bdl_loadTemplates(state.entity.entity_type);
                }
            } else {
                cc_showAlert(data.error || 'Failed.',
                    { title: 'Delete Failed' });
            }
        }).catch(function(err) {
            cc_showAlert(err.message, { title: 'Error' });
        });
    });
}

/* ============================================================================
   FUNCTIONS: IMPORT HISTORY
   ----------------------------------------------------------------------------
   The import history panel: the active-imports list, the year/month/day
   drill-down tree with lazy month loading, the environment and user-scope
   filters, retry of failed-but-ready imports, the live-polling lifecycle
   driven by active rows, and the midnight rollover check.
   Prefix: bdl
   ============================================================================ */

/* Initializes the history panel: restores scope, loads config, first load. */
function bdl_initHistoryPanel() {
    try {
        var savedScope = localStorage.getItem('bdl_history_user_scope');
        if (savedScope === 'me' || savedScope === 'all') {
            bdl_historyUserScope = savedScope;
        }
        var savedScopeBtns = document.querySelectorAll('#bdl-history-user-toggle .bdl-history-toggle-btn');
        savedScopeBtns.forEach(function(btn) {
            if (btn.dataset.scope === bdl_historyUserScope) {
                btn.classList.add('bdl-history-toggle-active');
            } else {
                btn.classList.remove('bdl-history-toggle-active');
            }
        });
    } catch (e) {
        /* localStorage unavailable; use the in-memory default. */
    }
    fetch('/api/config/refresh-interval?page=bdl-import').then(function(r) {
        return r.ok ? r.json() : null;
    }).then(function(data) {
        if (data && data.interval && !data.default) {
            bdl_historyPollInterval = data.interval;
        }
    }).catch(function() {
        /* Use the default poll interval. */
    });
    bdl_loadHistory();
    if (bdl_midnightCheckTimer) {
        clearInterval(bdl_midnightCheckTimer);
    }
    bdl_midnightCheckTimer = setInterval(bdl_checkMidnightRollover, 60000);
}

/* Loads history data (active rows + year tree) and renders the panel. */
function bdl_loadHistory(silent) {
    var envParam = (bdl_historyEnvFilter === 'ALL') ? '' : '&env=' + encodeURIComponent(bdl_historyEnvFilter);
    var url = '/api/bdl-import/history?user_scope=' + bdl_historyUserScope + envParam;
    var btn = document.getElementById('bdl-history-refresh-btn');
    if (btn && !silent) {
        btn.classList.add('bdl-spinning');
    }
    return Promise.resolve(cc_engineFetch(url)).then(function(data) {
        if (!data) {
            return;
        }
        bdl_historyData = data;
        bdl_historyCurrentUser = data.current_user || null;
        bdl_historyAvailableEnvs = data.environments || [];
        if (data.poll_interval_seconds) {
            bdl_historyPollInterval = data.poll_interval_seconds;
        }
        bdl_historyLastLoadMs = Date.now();
        bdl_renderHistoryEnvChips();
        bdl_renderHistoryActive();
        bdl_renderHistoryTree();
        bdl_updateHistoryLastUpdated();
        bdl_updateHistoryPollingLifecycle();
    }).catch(function(err) {
        var active = document.getElementById('bdl-history-active-section');
        if (active) {
            active.innerHTML = '<div class="bdl-history-empty bdl-inline-error">Failed to load: ' +
                cc_escapeHtml(err.message) + '</div>';
        }
        var tree = document.getElementById('bdl-history-tree');
        if (tree) {
            tree.innerHTML = '';
        }
    }).then(function() {
        if (btn) {
            setTimeout(function() {
                btn.classList.remove('bdl-spinning');
            }, 600);
        }
    });
}

/* Forces a non-silent history reload (used by hooks and manual refresh). */
function bdl_refreshHistory() {
    bdl_loadHistory(false);
}

/* Renders the environment filter chips. */
function bdl_renderHistoryEnvChips() {
    var container = document.getElementById('bdl-history-env-chips');
    if (!container) {
        return;
    }
    var html = '<button type="button" class="bdl-history-chip' +
        (bdl_historyEnvFilter === 'ALL' ? ' bdl-history-chip-active' : '') +
        '" data-action-click="bdl-history-env-filter" data-action-bdl-env="ALL">All</button>';
    bdl_historyAvailableEnvs.forEach(function(env) {
        var isDisabled = bdl_disabledEnvironments.indexOf(env) !== -1;
        var activeCls = (bdl_historyEnvFilter === env) ? ' bdl-history-chip-active' : '';
        var disabledCls = isDisabled ? ' bdl-history-chip-disabled' : '';
        var actionAttrs = isDisabled ? '' :
            ' data-action-click="bdl-history-env-filter" data-action-bdl-env="' + cc_escapeHtml(env) + '"';
        html += '<button type="button" class="bdl-history-chip' + activeCls + disabledCls +
            '" data-bdl-env="' + cc_escapeHtml(env) + '"' + actionAttrs + '>' + cc_escapeHtml(env) + '</button>';
    });
    container.innerHTML = html;
}

/* Renders the active-imports section. */
function bdl_renderHistoryActive() {
    var container = document.getElementById('bdl-history-active-section');
    if (!container || !bdl_historyData) {
        return;
    }
    var rows = bdl_historyData.active_rows || [];
    var liveIndicator = document.getElementById('bdl-history-live-indicator');
    if (rows.length === 0) {
        container.innerHTML = '<div class="bdl-history-empty">No active imports</div>';
        if (liveIndicator) {
            liveIndicator.classList.add('bdl-hidden');
        }
        return;
    }
    if (liveIndicator) {
        liveIndicator.classList.remove('bdl-hidden');
    }
    var html = '<div class="bdl-history-active-header"><span class="bdl-history-active-label">Active</span>' +
        '<span class="bdl-history-active-count">' + rows.length + '</span></div>';
    html += '<div class="bdl-history-active-list">';
    rows.forEach(function(r) {
        html += bdl_renderActiveRow(r);
    });
    html += '</div>';
    container.innerHTML = html;
}

/* Builds one active-import row. */
function bdl_renderActiveRow(r) {
    var envLower = (r.environment || '').toLowerCase();
    var fnShort = bdl_shortenFilename(r.source_filename || r.xml_filename || '');
    var entityName = r.entity_type ? bdl_formatEntityName(r.entity_type) : '';
    var ageText = bdl_formatAge(r.started_dttm || r.created_dttm);
    var status = (r.status || '').toUpperCase();
    var statusBadge = '<span class="bdl-history-status-badge bdl-history-status-' + status.toLowerCase() + '">' +
        cc_escapeHtml(status) + '</span>';
    var rowCount = r.total_record_count || r.staging_success_count || 0;
    var tooltip = bdl_buildRowTooltip(r);
    var html = '<div class="bdl-history-active-row" title="' + cc_escapeHtml(tooltip) + '">';
    html += '<span class="bdl-history-active-env bdl-env-' + envLower + '">' +
        cc_escapeHtml(r.environment || '') + '</span>';
    if (entityName) {
        html += '<span class="bdl-history-active-entity">' + cc_escapeHtml(entityName) + '</span>';
    }
    html += '<span class="bdl-history-active-filename">' + cc_escapeHtml(fnShort) + '</span>';
    html += statusBadge;
    html += '<span class="bdl-history-active-meta"><span class="bdl-history-active-count">' +
        rowCount.toLocaleString() + '</span><span class="bdl-history-active-age">' +
        cc_escapeHtml(ageText) + '</span></span>';
    html += '</div>';
    return html;
}

/* Renders the completed-imports year tree. */
function bdl_renderHistoryTree() {
    var container = document.getElementById('bdl-history-tree');
    if (!container || !bdl_historyData) {
        return;
    }
    var years = bdl_historyData.years || [];
    if (years.length === 0) {
        container.innerHTML = '<div class="bdl-history-empty">No completed imports</div>';
        return;
    }
    var html = '';
    years.forEach(function(yearObj) {
        var year = yearObj.year;
        var expanded = !!bdl_historyExpandedYears[year];
        var iconCls = 'bdl-history-year-icon' + (expanded ? ' bdl-expanded' : '');
        var contentCls = 'bdl-history-year-content' + (expanded ? ' bdl-expanded' : '');
        html += '<div class="bdl-history-year" data-bdl-year="' + year + '">';
        html += '<div class="bdl-history-year-header" data-action-click="bdl-toggle-history-year" ' +
            'data-action-bdl-year="' + year + '">';
        html += '<span class="' + iconCls + '">&#9654;</span>';
        html += '<span class="bdl-history-year-label">' + year + '</span>';
        html += '<span class="bdl-history-year-spacer"></span>';
        html += '<span class="bdl-history-year-stat">' + yearObj.total.toLocaleString() + '</span>';
        html += '<span class="bdl-history-year-stat bdl-history-stat-success">' +
            (yearObj.success > 0 ? yearObj.success.toLocaleString() : '') + '</span>';
        html += '<span class="bdl-history-year-stat bdl-history-stat-failed">' +
            (yearObj.fail > 0 ? yearObj.fail.toLocaleString() : '') + '</span>';
        html += '</div>';
        html += '<div class="' + contentCls + '" id="bdl-year-content-' + year + '">';
        html += bdl_renderYearMonths(yearObj);
        html += '</div></div>';
    });
    container.innerHTML = html;
}

/* Builds the month table for one year. */
function bdl_renderYearMonths(yearObj) {
    var months = yearObj.months || [];
    if (months.length === 0) {
        return '';
    }
    var html = '<table class="bdl-history-month-table"><tbody>';
    months.forEach(function(m) {
        var expanded = !!bdl_historyExpandedMonths[yearObj.year + '-' + m.month];
        var iconCls = 'bdl-history-month-icon' + (expanded ? ' bdl-expanded' : '');
        var monthName = bdl_monthAbbrev(m.month);
        html += '<tr class="bdl-history-month-row" data-action-click="bdl-toggle-history-month" ' +
            'data-action-bdl-year="' + yearObj.year + '" data-action-bdl-month="' + m.month + '">';
        html += '<td class="bdl-history-month-expand-cell"><span class="' + iconCls + '">&#9654;</span></td>';
        html += '<td class="bdl-history-month-name">' + monthName + '</td>';
        html += '<td class="bdl-history-month-total">' + m.total.toLocaleString() + '</td>';
        html += '<td class="bdl-history-month-success">' + (m.success > 0 ? m.success.toLocaleString() : '') + '</td>';
        html += '<td class="bdl-history-month-fail">' + (m.fail > 0 ? m.fail.toLocaleString() : '') + '</td>';
        html += '</tr>';
        html += '<tr class="bdl-history-month-details' + (expanded ? '' : ' bdl-hidden') +
            '" id="bdl-month-details-' + yearObj.year + '-' + m.month + '">';
        html += '<td colspan="5"><div class="bdl-history-month-details-content" id="bdl-month-content-' +
            yearObj.year + '-' + m.month + '">';
        if (expanded) {
            html += '<div class="bdl-history-month-loading">Loading...</div>';
        }
        html += '</div></td></tr>';
    });
    html += '</tbody></table>';
    return html;
}

/* Toggles a year open (accordion: closes sibling years), then re-renders. */
function bdl_toggleHistoryYear(target) {
    var year = parseInt(target.getAttribute('data-action-bdl-year'), 10);
    bdl_historyExpandedYears[year] = !bdl_historyExpandedYears[year];
    if (bdl_historyExpandedYears[year]) {
        Object.keys(bdl_historyExpandedYears).forEach(function(y) {
            if (parseInt(y, 10) !== year) {
                bdl_historyExpandedYears[y] = false;
            }
        });
    }
    bdl_renderHistoryTree();
}

/* Toggles a month open (accordion within its year) and lazy-loads its days. */
function bdl_toggleHistoryMonth(target) {
    var year = parseInt(target.getAttribute('data-action-bdl-year'), 10);
    var month = parseInt(target.getAttribute('data-action-bdl-month'), 10);
    var key = year + '-' + month;
    bdl_historyExpandedMonths[key] = !bdl_historyExpandedMonths[key];
    if (bdl_historyExpandedMonths[key]) {
        Object.keys(bdl_historyExpandedMonths).forEach(function(k) {
            if (k !== key && k.indexOf(year + '-') === 0) {
                bdl_historyExpandedMonths[k] = false;
            }
        });
    }
    bdl_renderHistoryTree();
    if (bdl_historyExpandedMonths[key]) {
        bdl_loadHistoryMonth(year, month);
    }
}

/* Loads (or serves from cache) the day breakdown for a month. */
function bdl_loadHistoryMonth(year, month) {
    var cacheKey = year + '-' + month + '-' + bdl_historyEnvFilter + '-' + bdl_historyUserScope;
    var contentEl = document.getElementById('bdl-month-content-' + year + '-' + month);
    if (!contentEl) {
        return;
    }
    if (bdl_historyMonthCache[cacheKey]) {
        bdl_renderMonthDays(contentEl, bdl_historyMonthCache[cacheKey].days, year, month,
            bdl_historyMonthCache[cacheKey].truncated);
        return;
    }
    contentEl.innerHTML = '<div class="bdl-history-month-loading">Loading...</div>';
    var envParam = (bdl_historyEnvFilter === 'ALL') ? '' : '&env=' + encodeURIComponent(bdl_historyEnvFilter);
    var url = '/api/bdl-import/history-month?year=' + year + '&month=' + month + '&user_scope=' +
        bdl_historyUserScope + envParam;
    Promise.resolve(cc_engineFetch(url)).then(function(data) {
        if (!data) {
            contentEl.innerHTML = '<div class="bdl-history-month-loading">Paused</div>';
            return;
        }
        bdl_historyMonthCache[cacheKey] = { days: data.days || [], truncated: data.truncated || false };
        bdl_renderMonthDays(contentEl, data.days || [], year, month, data.truncated);
    }).catch(function(err) {
        contentEl.innerHTML = '<div class="bdl-history-month-loading bdl-inline-error">Failed: ' +
            cc_escapeHtml(err.message) + '</div>';
    });
}

/* Renders the per-day rows (with their import rows) for a month. */
function bdl_renderMonthDays(container, days, year, month, truncated) {
    if (!days || days.length === 0) {
        container.innerHTML = '<div class="bdl-history-month-empty">No imports</div>';
        return;
    }
    var html = '';
    days.forEach(function(d) {
        var dateKey = d.date;
        var expanded = !!bdl_historyExpandedDays[dateKey];
        var iconCls = 'bdl-history-day-icon' + (expanded ? ' bdl-expanded' : '');
        html += '<div class="bdl-history-day-row">';
        html += '<div class="bdl-history-day-header" data-action-click="bdl-toggle-history-day" ' +
            'data-action-bdl-date="' + cc_escapeHtml(dateKey) + '">';
        html += '<span class="' + iconCls + '">&#9654;</span>';
        html += '<span class="bdl-history-day-label">' + d.day_of_month + '</span>';
        html += '<span class="bdl-history-day-dow">' + cc_escapeHtml(d.day_of_week || '') + '</span>';
        html += '<span class="bdl-history-day-spacer"></span>';
        html += '<span class="bdl-history-day-stat">' + d.total + '</span>';
        html += '<span class="bdl-history-day-stat bdl-history-stat-success">' + (d.success > 0 ? d.success : '') + '</span>';
        html += '<span class="bdl-history-day-stat bdl-history-stat-failed">' + (d.fail > 0 ? d.fail : '') + '</span>';
        html += '</div>';
        html += '<div class="bdl-history-day-imports' + (expanded ? ' bdl-expanded' : '') +
            '" id="bdl-day-imports-' + dateKey + '">';
        html += '<div class="bdl-history-import-header">';
        html += '<span>Env</span>';
        html += '<span>Entity</span>';
        html += '<span>File</span>';
        html += '<span>Status</span>';
        html += '<span class="bdl-history-ih-total">Total</span>';
        html += '<span class="bdl-history-ih-succ">Succ</span>';
        html += '<span class="bdl-history-ih-fail">Fail</span>';
        html += '<span>User</span>';
        html += '</div>';
        (d.imports || []).forEach(function(imp) {
            html += bdl_renderImportRow(imp);
        });
        html += '</div></div>';
    });
    if (truncated) {
        html += '<div class="bdl-history-month-truncated">Showing first 500 imports for this month ' +
            '&mdash; refine filters to see more</div>';
    }
    container.innerHTML = html;
}

/* Builds one completed-import row, including the retry badge when eligible. */
function bdl_renderImportRow(imp) {
    var envLower = (imp.environment || '').toLowerCase();
    var fnShort = bdl_shortenFilename(imp.source_filename || imp.xml_filename || '');
    var entityName = imp.entity_type ? bdl_formatEntityName(imp.entity_type) : '';
    var status = (imp.file_registry_status || imp.status || '').toUpperCase();
    var total = imp.total_record_count || imp.staging_success_count || 0;
    var succ = imp.import_success_count || 0;
    var fail = imp.import_failed_count || 0;
    var user = imp.executed_by || '';
    if (user.indexOf('\\') !== -1) {
        user = user.split('\\')[1];
    }
    var tooltip = bdl_buildRowTooltip(imp);
    var userCell = (user && bdl_historyUserScope === 'all') ? cc_escapeHtml(user) : '';
    var html = '<div class="bdl-history-import-row" title="' + cc_escapeHtml(tooltip) + '">';
    html += '<span class="bdl-history-import-env bdl-env-' + envLower + '">' +
        cc_escapeHtml(imp.environment || '') + '</span>';
    html += '<span class="bdl-history-import-entity">' + cc_escapeHtml(entityName) + '</span>';
    html += '<span class="bdl-history-import-filename">' + cc_escapeHtml(fnShort) + '</span>';
    html += '<span class="bdl-history-import-status"><span class="bdl-history-status-badge bdl-history-status-' +
        status.toLowerCase() + '">' + cc_escapeHtml(status) + '</span>';
    if (imp.status === 'FAILED' && imp.file_registry_id && imp.log_id && imp.file_registry_status === 'READY') {
        html += '<span class="bdl-history-retry-badge" data-action-click="bdl-retry-import" ' +
            'data-action-bdl-log-id="' + imp.log_id + '">RETRY</span>';
    }
    html += '</span>';
    html += '<span class="bdl-history-import-count">' + total.toLocaleString() + '</span>';
    html += '<span class="bdl-history-import-count-success">' + (succ > 0 ? succ.toLocaleString() : '') + '</span>';
    html += '<span class="bdl-history-import-count-fail">' + (fail > 0 ? fail.toLocaleString() : '') + '</span>';
    html += '<span class="bdl-history-import-user">' + userCell + '</span>';
    html += '</div>';
    return html;
}

/* Retries a failed-but-ready import, refreshing history on success. */
function bdl_retryImportTrigger(target) {
    var logId = parseInt(target.getAttribute('data-action-bdl-log-id'), 10);
    var badgeEl = target;
    if (badgeEl) {
        badgeEl.textContent = '...';
        badgeEl.classList.add('bdl-history-retry-pending');
    }
    fetch('/api/bdl-import/retry-trigger', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ log_id: logId })
    }).then(function(r) {
        return r.json().then(function(d) {
            d._httpStatus = r.status;
            return d;
        });
    }).then(function(data) {
        if (data._httpStatus >= 400 || data.error) {
            cc_showAlert(data.error || 'Retry failed', { title: 'Retry Failed' });
            if (badgeEl) {
                badgeEl.textContent = 'Retry';
                badgeEl.classList.remove('bdl-history-retry-pending');
            }
        } else {
            if (badgeEl) {
                badgeEl.textContent = 'Submitted';
                badgeEl.classList.remove('bdl-history-retry-pending');
                badgeEl.classList.add('bdl-history-retry-success');
            }
            bdl_historyMonthCache = {};
            setTimeout(function() {
                bdl_loadHistory();
            }, 1500);
        }
    }).catch(function(err) {
        cc_showAlert(err.message, { title: 'Retry Error' });
        if (badgeEl) {
            badgeEl.textContent = 'Retry';
            badgeEl.classList.remove('bdl-history-retry-pending');
        }
    });
}

/* Toggles a day's imports list open or closed. */
function bdl_toggleHistoryDay(target) {
    var dateKey = target.getAttribute('data-action-bdl-date');
    bdl_historyExpandedDays[dateKey] = !bdl_historyExpandedDays[dateKey];
    var el = document.getElementById('bdl-day-imports-' + dateKey);
    if (el) {
        el.classList.toggle('bdl-expanded');
    }
    var dayRow = el ? el.parentElement : null;
    if (dayRow) {
        var icon = dayRow.querySelector('.bdl-history-day-icon');
        if (icon) {
            icon.classList.toggle('bdl-expanded');
        }
    }
}

/* Sets the environment filter and reloads history. */
function bdl_setHistoryEnvFilter(target) {
    var env = target.getAttribute('data-action-bdl-env');
    if (bdl_historyEnvFilter === env) {
        return;
    }
    bdl_historyEnvFilter = env;
    bdl_historyExpandedMonths = {};
    bdl_historyExpandedDays = {};
    bdl_historyMonthCache = {};
    bdl_loadHistory();
}

/* Sets the user scope (me/all), persists it, and reloads history. */
function bdl_setHistoryUserScope(target) {
    var scope = target.getAttribute('data-action-bdl-scope');
    if (bdl_historyUserScope === scope) {
        return;
    }
    bdl_historyUserScope = scope;
    try {
        localStorage.setItem('bdl_history_user_scope', scope);
    } catch (e) {
        /* localStorage unavailable; scope stays in memory only. */
    }
    var btns = document.querySelectorAll('#bdl-history-user-toggle .bdl-history-toggle-btn');
    btns.forEach(function(b) {
        if (b.dataset.scope === scope) {
            b.classList.add('bdl-history-toggle-active');
        } else {
            b.classList.remove('bdl-history-toggle-active');
        }
    });
    bdl_historyExpandedMonths = {};
    bdl_historyExpandedDays = {};
    bdl_historyMonthCache = {};
    bdl_loadHistory();
}

/* Updates the "as of" timestamp shown on the history panel. */
function bdl_updateHistoryLastUpdated() {
    var el = document.getElementById('bdl-history-last-updated');
    if (!el) {
        return;
    }
    el.textContent = 'as of ' + bdl_formatClockTime(new Date());
}

/* Starts or stops live polling based on whether any imports are active. */
function bdl_updateHistoryPollingLifecycle() {
    var hasActive = bdl_historyData && bdl_historyData.active_rows && bdl_historyData.active_rows.length > 0;
    if (hasActive) {
        bdl_startHistoryPolling();
    } else {
        bdl_stopHistoryPolling();
    }
}

/* Starts the live-polling interval for active imports. */
function bdl_startHistoryPolling() {
    if (bdl_historyPollTimer) {
        return;
    }
    bdl_historyPollTimer = setInterval(function() {
        if (cc_enginePageHidden) {
            return;
        }
        if (cc_engineSessionExpired) {
            bdl_stopHistoryPolling();
            return;
        }
        bdl_loadHistory(true);
    }, bdl_historyPollInterval * 1000);
}

/* Stops the live-polling interval. */
function bdl_stopHistoryPolling() {
    if (bdl_historyPollTimer) {
        clearInterval(bdl_historyPollTimer);
        bdl_historyPollTimer = null;
    }
}

/* Reloads history and clears day caches when the date rolls past midnight. */
function bdl_checkMidnightRollover() {
    var today = new Date().toDateString();
    if (today !== bdl_pageLoadDate) {
        bdl_pageLoadDate = today;
        bdl_historyMonthCache = {};
        bdl_historyExpandedDays = {};
        bdl_loadHistory(true);
    }
}

/* ============================================================================
   FUNCTIONS: HELPERS
   ----------------------------------------------------------------------------
   Page-local formatting utilities for the history panel and active rows.
   HTML escaping uses the shared cc_escapeHtml; these cover only the
   page-specific filename, age, time, month, and tooltip formatting that
   has no shared equivalent.
   Prefix: bdl
   ============================================================================ */

/* Shortens a long filename with an ellipsis, preserving the extension. */
function bdl_shortenFilename(fn) {
    if (!fn) {
        return '';
    }
    if (fn.length <= 34) {
        return fn;
    }
    var dot = fn.lastIndexOf('.');
    var ext = dot > 0 ? fn.substring(dot) : '';
    var base = dot > 0 ? fn.substring(0, dot) : fn;
    return base.substring(0, 28) + '\u2026' + ext;
}

/* Formats a timestamp as a relative age (e.g. "5m ago"). */
function bdl_formatAge(dttm) {
    if (!dttm) {
        return '';
    }
    var then = new Date(dttm);
    if (isNaN(then.getTime())) {
        return '';
    }
    var secs = Math.floor((Date.now() - then.getTime()) / 1000);
    if (secs < 60) {
        return secs + 's ago';
    }
    if (secs < 3600) {
        return Math.floor(secs / 60) + 'm ago';
    }
    if (secs < 86400) {
        return Math.floor(secs / 3600) + 'h ago';
    }
    return Math.floor(secs / 86400) + 'd ago';
}

/* Formats a timestamp as a 12-hour clock time (e.g. "1:23pm"). */
function bdl_formatImportTime(dttm) {
    if (!dttm) {
        return '';
    }
    var d = new Date(dttm);
    if (isNaN(d.getTime())) {
        return '';
    }
    var h = d.getHours();
    var m = d.getMinutes();
    var ampm = h >= 12 ? 'pm' : 'am';
    h = h % 12;
    if (h === 0) {
        h = 12;
    }
    return h + ':' + (m < 10 ? '0' : '') + m + ampm;
}

/* Formats a Date object as a 12-hour clock time (e.g. "1:23pm"). */
function bdl_formatClockTime(d) {
    var h = d.getHours();
    var m = d.getMinutes();
    var ampm = h >= 12 ? 'pm' : 'am';
    h = h % 12;
    if (h === 0) {
        h = 12;
    }
    return h + ':' + (m < 10 ? '0' : '') + m + ampm;
}

/* Returns the three-letter abbreviation for a 1-based month number. */
function bdl_monthAbbrev(month) {
    var names = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return names[month - 1] || String(month);
}

/* Builds the hover tooltip text for an active or completed import row. */
function bdl_buildRowTooltip(r) {
    var parts = [];
    if (r.entity_type) {
        parts.push('Entity: ' + r.entity_type);
    }
    if (r.environment) {
        parts.push('Env: ' + r.environment);
    }
    if (r.status) {
        parts.push('Status: ' + r.status);
    }
    if (r.file_registry_status) {
        parts.push('DM: ' + r.file_registry_status);
    }
    if (r.executed_by) {
        parts.push('User: ' + r.executed_by);
    }
    if (r.started_dttm) {
        parts.push('Started: ' + new Date(r.started_dttm).toLocaleString());
    }
    if (r.completed_dttm) {
        parts.push('Completed: ' + new Date(r.completed_dttm).toLocaleString());
    }
    if (r.error_message) {
        parts.push('Error: ' + r.error_message);
    }
    return parts.join(' | ');
}

/* ============================================================================
   FUNCTIONS: PAGE LIFECYCLE HOOKS
   ----------------------------------------------------------------------------
   The hooks invoked by cc-shared.js on tab-resume and session-expiry. On
   resume, the history panel is refreshed; on expiry, its live polling is
   stopped.
   Prefix: bdl
   ============================================================================ */

/* Called by cc-shared when the tab regains visibility: refresh history. */
function bdl_onPageResumed() {
    bdl_refreshHistory();
}

/* Called by cc-shared when the session expires: stop history polling. */
function bdl_onSessionExpired() {
    bdl_stopHistoryPolling();
}

/* ============================================================================
   bdl-import.js — BDL Import Wizard (5-Step)
   Location: E:\xFACts-ControlCenter\public\js\bdl-import.js
   Steps: Environment → Upload File → Select Entities → Map & Validate → Execute
   Version: Tracked in dbo.System_Metadata (component: ControlCenter.BDLImport)

   CHANGELOG
   ---------
   2026-04-16  Import History panel in right column
               Active rows pinned top, pulsing LIVE indicator when polling
               Y/M/D accordion (JobFlow pattern) for completed imports
               Env chip filter + Mine/All Users toggle (localStorage persisted)
               On-demand reconciliation via /api/bdl-import/history
               Polling lifecycle driven by active-row presence + engine-events.js
               Midnight rollover reload   
   2026-04-15  Per-field mode selector for conditional-eligible fields on FILE_MAPPED entities
               3-way toggle (File / Blanket / Cond) on target chips
               Field Assignments section below mapping panels
               Assignment card model for blanket/conditional field overrides
   2026-04-15  Assignment card model for FIXED_VALUE entities (multi-assignment)
               Blanket/Conditional mode toggle per assignment card
               Conditional mode: trigger column scan, unique value grid, per-value typeahead
               Add Another / Remove assignment card management
               Staging expansion sends assignments array to API
   2026-04-11  Added blanket nullify fields support in mapping step
               Nullify badge on target chips for eligible fields
               Nullified fields shown in Mapped section with distinct styling
   2026-04-09  Restored XML preview per entity tab on Execute step
               Entity selection grouped by entity_key (CONSUMER/ACCOUNT/OTHER)
               Field info modal on entity cards (on-demand field list via ℹ icon)
   2026-04-08  Consolidated to 5-step wizard
               Steps 2/3 swapped: Upload File precedes Entity Type selection
               Entity Type selection converted to multi-select with toggle cards
               Map & Validate combined into single step with per-entity loop
               Execute step uses tabbed per-entity summary with single Submit All
               Per-entity state management (entityStates array)
   2026-04-06  Replaced all native alert/confirm dialogs with shared styled modals
               XML preview auto-loads on section expand
               Added Promote to Production flow with cooldown timer
   ============================================================================ */

var BDL = (function () {
    'use strict';

    var currentStep = 1, totalSteps = 5;
    var stepComplete = [false, false, false, false, false];
    var selectedEnvironment = null;

    var selectedEntities = [];
    var entityStates = [];
    var currentEntityIndex = 0;

    function curState() { return entityStates[currentEntityIndex] || null; }
    function curEntity() { var s = curState(); return s ? s.entity : null; }

    var uploadedFile = null, parsedFileData = null;
    var allEntities = [], MAX_PREVIEW_ROWS = 10;
    var executeInProgress = false;
    var executeResultTracker = [];
    var revalidating = false;
    var entityTemplates = [];
    var activeTemplateId = null;

    var promoteData = null;
    var promoteCountdownTimer = null;
    var promoteSecondsRemaining = 0;
    var promoteReady = false;

    // Environments listed here are rendered grayed-out and cannot be selected
    // on Step 1 or filtered in the Import History panel. Used for temporary
    // blocks during DM upgrades, maintenance windows, etc. Remove an entry
    // from this list to re-enable that environment.
    var DISABLED_ENVIRONMENTS = ['STAGE'];
	
    // ── Import History Panel State ───────────────────────────────────────
    var historyData = null;
    var historyEnvFilter = 'ALL';
    var historyUserScope = 'me';
    var historyPollTimer = null;
    var historyPollInterval = 20;
    var historyExpandedYears = {};
    var historyExpandedMonths = {};
    var historyExpandedDays = {};
    var historyMonthCache = {};
    var historyCurrentUser = null;
    var historyAvailableEnvs = [];
    var historyLastLoadMs = 0;
    var pageLoadDate = new Date().toDateString();
    var midnightCheckTimer = null;	

    function init() { loadEnvironments(); checkStagingCleanup(); initHistoryPanel(); }

    function checkStagingCleanup() {
        fetch('/api/bdl-import/staging-cleanup').then(function (r) { return r.json(); }).then(function (data) {
            var tables = data.expired_tables || [];
            if (tables.length > 0) {
                var banner = document.getElementById('connection-error');
                banner.style.display = 'block'; banner.className = 'cleanup-banner';
                banner.innerHTML = '<span class="cleanup-text">' + tables.length + ' expired staging table(s) found (older than 48 hours)</span><button class="cleanup-btn" onclick="BDL.runCleanup()">Clean Up</button>';
            }
        }).catch(function () {});
    }
    function runCleanup() {
        var banner = document.getElementById('connection-error');
        banner.innerHTML = '<span class="cleanup-text">Cleaning up...</span>';
        fetch('/api/bdl-import/staging-cleanup', { method: 'POST' }).then(function (r) { return r.json(); }).then(function (data) {
            banner.innerHTML = '<span class="cleanup-text">' + (data.dropped || []).length + ' table(s) removed</span>';
            setTimeout(function () { banner.style.display = 'none'; banner.className = 'connection-error'; }, 3000);
        }).catch(function (err) { banner.innerHTML = '<span class="cleanup-text" style="color:#f48771;">Cleanup failed: ' + err.message + '</span>'; });
    }

    // ── Step Navigation ──────────────────────────────────────────────────
    function goToStep(step) { if (step > currentStep || (step < currentStep && !stepComplete[step - 1] && step !== currentStep)) return; showStep(step); }

    function nextStep() {
        if (currentStep < totalSteps && stepComplete[currentStep - 1]) {
            if (currentStep === 3) {
                initEntityStates();
                currentEntityIndex = 0;
                loadCurrentEntityFields(function () { showStep(4); renderMapValidatePanel(); });
                return;
            }
            if (currentStep === 4) {
                var state = curState();
                if (state && state.nullifyFields && state.nullifyFields.length > 0 && state.stagingContext) {
                    persistNullifyFields(state, function () { showStep(5); renderExecuteReview(); });
                } else {
                    showStep(5); renderExecuteReview();
                }
                return;
            }
            showStep(currentStep + 1);
        }
    }

    function prevStep() {
        if (currentStep === 4 && currentEntityIndex > 0) { currentEntityIndex--; loadCurrentEntityFields(function () { renderMapValidatePanel(); }); return; }
        if (currentStep > 1) showStep(currentStep - 1);
    }

    function showStep(step) {
        for (var i = 1; i <= totalSteps; i++) { var p = document.getElementById('panel-' + i), ind = document.getElementById('step-ind-' + i); if (p) p.classList.remove('active'); if (ind) ind.classList.remove('active'); }
        var tp = document.getElementById('panel-' + step), ti = document.getElementById('step-ind-' + step);
        if (tp) tp.classList.add('active'); if (ti) ti.classList.add('active');
        currentStep = step; updateGuidePanel(); updateStepperUI(); updateNavButtons();
        if (step === 3 && allEntities.length === 0) loadEntities();
    }

    function updateStepperUI() {
        for (var i = 1; i <= totalSteps; i++) {
            var ind = document.getElementById('step-ind-' + i), num = document.getElementById('step-num-' + i), conn = document.getElementById('conn-' + i);
            if (!ind) continue; ind.classList.remove('completed', 'active');
            if (stepComplete[i - 1] && i !== currentStep) { ind.classList.add('completed'); if (num) num.innerHTML = '&#10003;'; }
            else if (i === currentStep) { ind.classList.add('active'); if (num) num.textContent = i; }
            else { if (num) num.textContent = i; }
            if (conn) { if (stepComplete[i - 1]) conn.classList.add('completed'); else conn.classList.remove('completed'); }
        }
    }

    function updateGuidePanel() {
        for (var g = 1; g <= totalSteps; g++) { var gt = document.getElementById('guide-text-' + g); if (gt) { if (g === currentStep) gt.classList.remove('hidden'); else gt.classList.add('hidden'); } }
        updateTemplateSectionState();
    }

    function updateNavButtons() {
        var back = document.getElementById('btn-back'), next = document.getElementById('btn-next');
        if (currentStep === 1) { back.disabled = true; }
        else if (currentStep === 4 && currentEntityIndex > 0) { back.disabled = false; }
        else { back.disabled = (currentStep === 1); }
        if (currentStep === 5 && stepComplete[4]) { back.style.display = 'none'; } else { back.style.display = ''; }
        if (currentStep === 5) { next.style.display = 'none'; }
        else {
            next.style.display = '';
            next.disabled = !stepComplete[currentStep - 1];
            next.innerHTML = 'Next &#8594;';
            next.classList.remove('btn-execute');
            if (stepComplete[currentStep - 1]) next.classList.add('btn-next');
            else next.classList.remove('btn-next');
        }
    }

    function updateEnvBadge() {
        var badge = document.getElementById('env-badge'); if (!badge) return;
        if (!selectedEnvironment) { badge.className = 'env-badge hidden'; badge.textContent = ''; return; }
        badge.textContent = selectedEnvironment.environment;
        badge.className = 'env-badge env-badge-' + selectedEnvironment.environment.toLowerCase();
    }

    // ── Step 1: Environment ──────────────────────────────────────────────
    function loadEnvironments() {
        fetch('/api/bdl-import/environments').then(function (r) { if (!r.ok) throw new Error('HTTP ' + r.status); return r.json(); })
            .then(function (data) { renderEnvironments(data.environments || []); })
            .catch(function (err) { document.getElementById('env-cards').innerHTML = '<div class="placeholder-message" style="color:#f48771;">Failed to load: ' + err.message + '</div>'; });
    }
	function renderEnvironments(envs) {
        var c = document.getElementById('env-cards');
        if (!envs.length) { c.innerHTML = '<div class="placeholder-message">No environments configured.</div>'; return; }
        var h = '';
        envs.forEach(function (env) {
            var isDisabled = DISABLED_ENVIRONMENTS.indexOf(env.environment) !== -1;
            var cls = 'env-card' + (isDisabled ? ' env-card-disabled' : '');
            var clickAttr = isDisabled ? '' : ' onclick="BDL.selectEnvironment(this,' + env.config_id + ')"';
            h += '<div class="' + cls + '" data-env="' + env.environment + '"' + clickAttr + '>';
            h += '<div class="env-name">' + env.environment + '</div>';
            if (isDisabled) h += '<div class="env-disabled-note">Temporarily unavailable</div>';
            h += '</div>';
        });
        c.innerHTML = h; c._envData = envs;
    }
    function selectEnvironment(card, configId) {
        var envData = (document.getElementById('env-cards')._envData || []).find(function (e) { return e.config_id === configId; });
        if (!envData) return;
        if (envData.environment === 'PROD') { showProdAdvisoryModal(card, envData); return; }
        applyEnvironmentSelection(card, envData);
    }
    function applyEnvironmentSelection(card, envData) {
        document.querySelectorAll('.env-card').forEach(function (c) { c.classList.remove('selected'); }); card.classList.add('selected');
        selectedEnvironment = envData; stepComplete[0] = true; updateNavButtons(); updateStepperUI(); updateEnvBadge(); resetFromStep(2);
    }
    function showProdAdvisoryModal(card, envData) {
        var existing = document.getElementById('prod-advisory-modal'); if (existing) existing.remove();
        var modal = document.createElement('div'); modal.id = 'prod-advisory-modal'; modal.className = 'xf-modal-overlay';
        modal.innerHTML = '<div class="xf-modal"><div class="xf-modal-header"><span class="xf-modal-icon" style="color:#dcdcaa">&#9888;</span><span>Production Environment</span></div><div class="xf-modal-body"><p>You are about to target <strong>Production</strong> directly.</p><p>If you haven\'t validated this data in a test environment first, consider running a test import on TEST or STAGE before loading to Production.</p></div><div class="xf-modal-actions"><button class="xf-modal-btn-cancel" id="prod-advisory-back">Go Back</button><button class="xf-modal-btn-primary" id="prod-advisory-continue">Continue to Production</button></div></div>';
        document.body.appendChild(modal);
        document.getElementById('prod-advisory-back').onclick = function () { modal.remove(); };
        document.getElementById('prod-advisory-continue').onclick = function () { modal.remove(); applyEnvironmentSelection(card, envData); };
    }

    // ── Step 2: Upload File ──────────────────────────────────────────────
    function dragOver(e) { e.preventDefault(); e.stopPropagation(); document.getElementById('upload-zone').classList.add('drag-over'); }
    function dragLeave(e) { e.preventDefault(); e.stopPropagation(); document.getElementById('upload-zone').classList.remove('drag-over'); }
    function fileDrop(e) { e.preventDefault(); e.stopPropagation(); document.getElementById('upload-zone').classList.remove('drag-over'); if (e.dataTransfer.files.length > 0) handleFile(e.dataTransfer.files[0]); }
    function fileSelected(input) { if (input.files.length > 0) handleFile(input.files[0]); }
    function handleFile(file) {
        var ext = '.' + file.name.split('.').pop().toLowerCase();
        if (['.csv', '.txt', '.xlsx', '.xls'].indexOf(ext) === -1) { showAlert('Supported formats: CSV, TXT, XLSX, XLS', { title: 'Invalid File Type', icon: '&#10005;', iconColor: '#f48771' }); return; }
        uploadedFile = file;
        if (ext === '.csv' || ext === '.txt') parseCSVPreview(file); else parseExcelPreview(file);
    }
    function parseCSVPreview(file) {
        var reader = new FileReader(); reader.onload = function (e) {
            var lines = e.target.result.split(/\r?\n/).filter(function (l) { return l.trim(); });
            if (lines.length < 2) { showAlert('The file contains no data rows.', { title: 'Empty File', icon: '&#9888;', iconColor: '#dcdcaa' }); return; }
            var headers = parseCSVLine(lines[0]), rows = [];
            for (var i = 1; i <= Math.min(lines.length - 1, MAX_PREVIEW_ROWS); i++) rows.push(parseCSVLine(lines[i]));
            parsedFileData = { headers: headers, rows: rows, rowCount: lines.length - 1 };
            showFileInfo(file, parsedFileData); renderFilePreview(parsedFileData);
            document.getElementById('upload-prompt').style.display = 'none';
            stepComplete[1] = true; updateNavButtons(); updateStepperUI(); resetFromStep(3);
        }; reader.readAsText(file);
    }
    function parseCSVLine(line) {
        var result = [], current = '', inQ = false;
        for (var i = 0; i < line.length; i++) { var ch = line[i]; if (inQ) { if (ch === '"' && i + 1 < line.length && line[i + 1] === '"') { current += '"'; i++; } else if (ch === '"') inQ = false; else current += ch; } else { if (ch === '"') inQ = true; else if (ch === ',') { result.push(current.trim()); current = ''; } else current += ch; } }
        result.push(current.trim()); return result;
    }
    function excelCellValue(cell) {
        if (!cell) return '';
        if (cell.t === 'd' && cell.v instanceof Date) {
            var dt = cell.v;
            var mm = String(dt.getUTCMonth() + 1).padStart(2, '0');
            var dd = String(dt.getUTCDate()).padStart(2, '0');
            return dt.getUTCFullYear() + '-' + mm + '-' + dd;
        }
        return cell.w !== undefined ? cell.w : String(cell.v);
    }
    function parseExcelPreview(file) {
        var reader = new FileReader(); reader.onload = function (e) {
            try {
                var data = new Uint8Array(e.target.result), wb = XLSX.read(data, { type: 'array', cellDates: true }), sh = wb.Sheets[wb.SheetNames[0]];
                if (!sh['!ref']) { showAlert('The file contains no data.', { title: 'Empty File', icon: '&#9888;', iconColor: '#dcdcaa' }); return; }
                var range = XLSX.utils.decode_range(sh['!ref']), totalRows = range.e.r;
                if (totalRows < 1) { showAlert('The file has headers but no data rows.', { title: 'No Data Rows', icon: '&#9888;', iconColor: '#dcdcaa' }); return; }
                var headers = [];
                for (var col = range.s.c; col <= range.e.c; col++) { var cell = sh[XLSX.utils.encode_cell({ r: 0, c: col })]; headers.push(cell ? String(cell.v) : 'Column ' + (col + 1)); }
                var rows = [];
                for (var row = 1; row <= Math.min(totalRows, MAX_PREVIEW_ROWS); row++) { var rd = []; for (var c = range.s.c; c <= range.e.c; c++) { var dc = sh[XLSX.utils.encode_cell({ r: row, c: c })]; rd.push(excelCellValue(dc)); } rows.push(rd); }
                parsedFileData = { headers: headers, rows: rows, rowCount: totalRows };
                showFileInfo(file, parsedFileData); renderFilePreview(parsedFileData);
                document.getElementById('upload-prompt').style.display = 'none';
                stepComplete[1] = true; updateNavButtons(); updateStepperUI(); resetFromStep(3);
            } catch (err) { showAlert(err.message, { title: 'Excel Parse Error', icon: '&#10005;', iconColor: '#f48771' }); }
        }; reader.readAsArrayBuffer(file);
    }
    function showFileInfo(file, data) {
        document.getElementById('file-preview').classList.remove('hidden');
        var info = document.getElementById('file-info'), sz = (file.size / 1024).toFixed(1) + ' KB';
        if (file.size > 1048576) sz = (file.size / 1048576).toFixed(1) + ' MB';
        info.innerHTML = '<span class="file-name">' + escapeHtml(file.name) + '</span><span class="file-detail">' + sz + (data ? ' &middot; ' + data.rowCount.toLocaleString() + ' rows &middot; ' + data.headers.length + ' columns' : '') + '</span><span class="file-remove" onclick="BDL.removeFile()" title="Remove file">&#10005;</span>';
        if (data && data.rowCount > 250000) info.innerHTML += '<div style="color:#dcdcaa;font-size:12px;margin-top:6px;">&#9888; Large file: ' + data.rowCount.toLocaleString() + ' rows.</div>';
    }
    function renderFilePreview(data) {
        var table = document.getElementById('preview-table'), h = '<thead><tr><th class="row-num">#</th>';
        data.headers.forEach(function (hd) { h += '<th>' + escapeHtml(hd) + '</th>'; }); h += '</tr></thead><tbody>';
        data.rows.forEach(function (row, idx) { h += '<tr><td class="row-num">' + (idx + 1) + '</td>'; row.forEach(function (cell) { h += '<td title="' + escapeHtml(cell) + '">' + escapeHtml(cell) + '</td>'; }); h += '</tr>'; });
        if (data.rowCount > data.rows.length) h += '<tr><td colspan="' + (data.headers.length + 1) + '" style="text-align:center;color:#888;font-style:italic;">... ' + (data.rowCount - data.rows.length).toLocaleString() + ' more rows</td></tr>';
        h += '</tbody>'; table.innerHTML = h;
    }
    function removeFile() {
        uploadedFile = null; parsedFileData = null;
        document.getElementById('file-preview').classList.add('hidden');
        document.getElementById('file-preview').innerHTML = '<div class="file-info" id="file-info"></div><div class="preview-table-wrap"><table class="preview-table" id="preview-table"></table></div>';
        document.getElementById('file-input').value = '';
        document.getElementById('upload-prompt').style.display = '';
        stepComplete[1] = false; resetFromStep(3); updateNavButtons(); updateStepperUI();
    }

    // ── Step 3: Entity Type Selection (Multi-Select, Grouped) ────────────
    function loadEntities() {
        var grid = document.getElementById('entity-grid'); grid.innerHTML = '<div class="loading">Loading entity types...</div>';
        fetch('/api/bdl-import/entities').then(function (r) { if (!r.ok) throw new Error('HTTP ' + r.status); return r.json(); })
            .then(function (data) { allEntities = data.entities || []; renderEntities(allEntities); })
            .catch(function (err) { grid.innerHTML = '<div class="placeholder-message" style="color:#f48771;">Failed to load: ' + err.message + '</div>'; });
    }

    function renderEntities(entities) {
        var grid = document.getElementById('entity-grid');
        if (!entities.length) { grid.innerHTML = '<div class="placeholder-message">No entity types available.</div>'; return; }
        var sectionOrder = ['CONSUMER', 'ACCOUNT', 'OTHER'], sectionLabels = { CONSUMER: 'Consumer', ACCOUNT: 'Account', OTHER: 'Other' };
        var groups = {}; entities.forEach(function (ent) { var key = ent.entity_key || 'OTHER'; if (!groups[key]) groups[key] = []; groups[key].push(ent); });
        var h = '';
        sectionOrder.forEach(function (key) {
            if (!groups[key] || groups[key].length === 0) return;
            h += '<div class="entity-section"><div class="entity-section-header"><span class="entity-section-label">' + escapeHtml(sectionLabels[key] || key) + '</span><span class="entity-section-line"></span><span class="entity-section-count">' + groups[key].length + '</span></div><div class="entity-cards">';
            groups[key].forEach(function (ent) {
                var dn = formatEntityName(ent.entity_type), folder = ent.folder || 'root';
                var isSelected = selectedEntities.some(function (se) { return se.entity_type === ent.entity_type; });
                var safeType = ent.entity_type.replace(/'/g, "\\'");
                h += '<div class="entity-card' + (isSelected ? ' selected' : '') + '" onclick="BDL.toggleEntity(\'' + safeType + '\')">';
                h += '<button class="entity-info-btn" onclick="event.stopPropagation(); BDL.showFieldInfo(\'' + safeType + '\', \'' + escapeHtml(dn).replace(/'/g, "\\'") + '\')" title="View available fields">i</button>';
                h += '<div class="entity-name">' + dn + '</div><div class="entity-meta"><span class="entity-folder">' + folder + '</span><span class="entity-fields">' + ent.element_count + ' fields</span></div></div>';
            });
            h += '</div></div>';
        });
        grid.innerHTML = h; updateEntitySelectionBanner();
    }

    function showFieldInfo(entityType, entityName) {
        var existing = document.getElementById('field-info-modal'); if (existing) existing.remove();
        var modal = document.createElement('div'); modal.id = 'field-info-modal'; modal.className = 'xf-modal-overlay';
        modal.innerHTML = '<div class="xf-modal" style="max-width:480px;"><div class="xf-modal-header"><span class="xf-modal-icon" style="color:#9cdcfe">&#9432;</span><span>Available Fields</span></div><div class="xf-modal-body"><div class="field-info-loading">Loading fields for ' + escapeHtml(entityName) + '...</div></div><div class="xf-modal-actions"><button class="xf-modal-btn-cancel" id="field-info-close">Close</button></div></div>';
        document.body.appendChild(modal);
        document.getElementById('field-info-close').onclick = function () { modal.remove(); };
        modal.onclick = function (e) { if (e.target === modal) modal.remove(); };
        fetch('/api/bdl-import/entity-fields?entity_type=' + encodeURIComponent(entityType)).then(function (r) { return r.json(); }).then(function (data) {
            var fields = data.fields || [], body = modal.querySelector('.xf-modal-body');
            if (!fields.length) { body.innerHTML = '<div class="field-info-empty">No fields available for this entity type.</div>'; return; }
            var entityInfo = allEntities.find(function (e) { return e.entity_type === entityType; });
            var entityCanNullify = entityInfo && entityInfo.has_nullify_fields;
            var html = '<div class="field-info-list">'; fields.forEach(function (f) {
                var displayName = (f.display_name && f.display_name !== '') ? f.display_name : f.element_name;
                var canNullify = entityCanNullify && !f.is_not_nullifiable && !f.is_primary_id && !f.is_import_required;
                html += '<div class="field-info-item">';
                if (canNullify) html += '<span class="field-info-nullify-icon" title="This field can be nullified during import">&#8709;</span>';
                html += '<div class="field-info-name">' + escapeHtml(displayName) + '</div>';
                if (f.field_description && f.field_description.length > 0) html += '<div class="field-info-desc">' + escapeHtml(f.field_description) + '</div>';
                if (f.import_guidance && f.import_guidance.length > 0) html += '<div class="field-info-guidance">' + escapeHtml(f.import_guidance) + '</div>';
                html += '</div>';
            }); html += '</div>'; body.innerHTML = html;
        }).catch(function (err) { modal.querySelector('.xf-modal-body').innerHTML = '<div class="field-info-empty" style="color:#f48771;">Failed to load fields: ' + escapeHtml(err.message) + '</div>'; });
    }

    function toggleEntity(entityType) {
        var idx = -1; for (var i = 0; i < selectedEntities.length; i++) { if (selectedEntities[i].entity_type === entityType) { idx = i; break; } }
        if (idx !== -1) selectedEntities.splice(idx, 1);
        else { var ent = allEntities.find(function (e) { return e.entity_type === entityType; }); if (ent) selectedEntities.push(ent); }
        renderEntities(allEntities); stepComplete[2] = selectedEntities.length > 0; updateNavButtons(); updateStepperUI(); resetFromStep(4);
    }
    function updateEntitySelectionBanner() {
        var countEl = document.getElementById('entity-select-count'); if (!countEl) return;
        if (selectedEntities.length === 0) { countEl.textContent = ''; countEl.className = 'entity-banner-count'; }
        else { countEl.textContent = selectedEntities.length + ' selected'; countEl.className = 'entity-banner-count entity-banner-count-active'; }
    }
    function formatEntityName(et) { return et.split('_').map(function (w) { return w.charAt(0).toUpperCase() + w.slice(1).toLowerCase(); }).join(' '); }

    // ── Per-Entity State Management ──────────────────────────────────────
    function initEntityStates() {
        entityStates = selectedEntities.map(function (ent) {
            return { entity: ent, fields: null, wrapper: null, columnMapping: {}, assignments: [], fieldAssignments: {}, stagingContext: null, stagedMapping: null, stagedAssignments: null, stagedFieldAssignments: null, validationResult: null, validated: false, xmlPreviewLoaded: false, nullifyFields: [] };
        });
    }

    function loadCurrentEntityFields(callback) {
        var state = curState(); if (!state) { if (callback) callback(); return; }
        if (state.fields) { if (callback) callback(); return; }
        fetch('/api/bdl-import/entity-fields?entity_type=' + encodeURIComponent(state.entity.entity_type))
            .then(function (r) { return r.json(); })
            .then(function (data) { state.fields = data.fields || []; state.wrapper = data.wrapper || []; loadTemplates(state.entity.entity_type); if (callback) callback(); })
            .catch(function (err) { console.error('Failed to load entity fields:', err); if (callback) callback(); });
    }

    function getFieldDisplayName(f) { return (f.display_name && f.display_name !== '') ? f.display_name : f.element_name; }
    function getFieldDisplayNameByElement(elementName) {
        var state = curState(); if (!state || !state.fields) return elementName;
        var f = state.fields.find(function (fld) { return fld.element_name === elementName; });
        return f ? getFieldDisplayName(f) : elementName;
    }
    function hasDisplayName(f) { return f.display_name && f.display_name !== ''; }

    // ── Step 4: Map & Validate (per-entity loop) ─────────────────────────

    function renderMapValidatePanel() {
        var area = document.getElementById('map-validate-area');
        var state = curState();
        if (!state || !state.fields || !parsedFileData) { area.innerHTML = '<div class="placeholder-message">Complete previous steps.</div>'; return; }
        if (state.validated) { renderMapValidateValidated(area, state); }
        else if (state.stagingContext && state.validationResult) { renderMapValidateValidation(area, state); }
        else { renderMapValidateMapping(area, state); }
        updateStep4Completion(); updateNavButtons();
    }

    function renderMapValidateMapping(area, state) {
        if (state.entity.action_type === 'FIXED_VALUE') { renderFixedValueMapping(area, state); return; }
        var entityFields = state.fields, columnMapping = state.columnMapping;
        var visibleFields = entityFields.filter(function (f) { return f.is_visible !== 0 && f.is_visible !== false; });
        var isAcct = state.entity.folder && state.entity.folder.indexOf('account') !== -1;
        var idElemName = isAcct ? 'cnsmr_accnt_idntfr_agncy_id' : 'cnsmr_idntfr_agncy_id';
        var idField = visibleFields.find(function (f) { return f.element_name === idElemName; });
        var mappableFields = visibleFields.filter(function (f) { return f.element_name !== idElemName; });
        var prevIdIdx = '';
        for (var k in columnMapping) { if (columnMapping[k] === idElemName) { var hIdx = parsedFileData.headers.indexOf(k); if (hIdx !== -1) prevIdIdx = String(hIdx); break; } }
        var html = renderEntityProgressBanner('mapping');
        var idSelected = (prevIdIdx !== '');
        if (idField) {
            var idStateClass = idSelected ? 'identifier-confirmed' : 'identifier-pending';
            html += '<div class="mapping-identifier ' + idStateClass + '"><div class="identifier-label"><span class="identifier-icon">&#128273;</span><strong>' + (isAcct ? 'Account' : 'Consumer') + ' Identifier</strong><span class="identifier-note">Which column contains the DM ' + (isAcct ? 'Account' : 'Consumer') + ' Number?</span></div><div class="identifier-select"><select id="identifier-column" onchange="BDL.identifierChanged()" class="identifier-dropdown"><option value="">— Select identifier column —</option>';
            parsedFileData.headers.forEach(function (header, idx) { var sample = (parsedFileData.rows[0] && parsedFileData.rows[0][idx]) ? parsedFileData.rows[0][idx] : ''; var sel = (String(idx) === prevIdIdx) ? ' selected' : ''; html += '<option value="' + idx + '"' + sel + '>' + escapeHtml(header + (sample ? '  (' + sample.substring(0, 20) + ')' : '')) + '</option>'; });
            html += '</select><span class="identifier-target">&#8594; <code>' + idField.element_name + '</code></span></div></div>';
        }
        var disabledClass = (idField && !idSelected) ? ' mapping-disabled' : '';
        html += '<div class="mapping-panels-wrap' + disabledClass + '" id="mapping-panels-wrap">';
        if (idField && !idSelected) html += '<div class="mapping-disabled-msg">Select the identifier column above to begin mapping</div>';
        html += '<div class="mapping-panels"><div class="mapping-panel panel-source"><div class="panel-header">Source Columns</div><div class="panel-list" id="source-list"></div></div><div class="mapping-panel panel-target"><div class="panel-header">BDL Fields</div><div class="panel-list" id="target-list"></div></div></div>';
        html += '<div class="mapped-section"><div class="panel-header">Mapped</div><div class="mapped-list" id="mapped-list"></div></div>';
        html += '<div id="field-assignments-area"></div>';
        html += '<div id="mapping-warnings" class="mapping-warnings"></div></div>';
        html += '<div class="map-validate-actions"><button class="execute-btn" id="btn-validate-entity" onclick="BDL.validateCurrentEntity()" disabled>Validate ' + escapeHtml(formatEntityName(state.entity.entity_type)) + '</button></div>';
        area.innerHTML = html;
        area._mappableFields = mappableFields; area._identifierField = idField; area._identifierElementName = idElemName; area._selectedSource = null;
        refreshMappingPanels();
    }

    // ── Fixed-Value Mapping with Assignment Cards ──────────────────────
    function renderFixedValueMapping(area, state) {
        var entityFields = state.fields;
        var visibleFields = entityFields.filter(function (f) { return f.is_visible !== 0 && f.is_visible !== false; });
        var isAcct = state.entity.folder && state.entity.folder.indexOf('account') !== -1;
        var idElemName = isAcct ? 'cnsmr_accnt_idntfr_agncy_id' : 'cnsmr_idntfr_agncy_id';
        var idField = visibleFields.find(function (f) { return f.element_name === idElemName; });
        var valueFields = visibleFields.filter(function (f) { return f.element_name !== idElemName; });
        var conditionalFields = valueFields.filter(function (f) { return f.is_conditional_eligible; });
        var hasConditionalOption = conditionalFields.length > 0;
        if (!state.assignments || state.assignments.length === 0) {
            state.assignments = [{ mode: 'blanket', fixedValues: {}, triggerColumn: null, conditionalField: null, valueMap: {}, sharedFields: {}, triggerUniqueValues: null }];
        }
        var prevIdIdx = '';
        for (var k in state.columnMapping) { if (state.columnMapping[k] === idElemName) { var hIdx = parsedFileData.headers.indexOf(k); if (hIdx !== -1) prevIdIdx = String(hIdx); break; } }
        var html = renderEntityProgressBanner('mapping');
        // html += '<div class="fixed-value-banner"><span class="fixed-value-icon">&#9998;</span> <strong>' + escapeHtml(formatEntityName(state.entity.entity_type)) + '</strong> uses fixed values — define one or more assignments below.</div>';
        var idSelected = (prevIdIdx !== '');
        if (idField) {
            var idStateClass = idSelected ? 'identifier-confirmed' : 'identifier-pending';
            html += '<div class="mapping-identifier ' + idStateClass + '"><div class="identifier-label"><span class="identifier-icon">&#128273;</span><strong>' + (isAcct ? 'Account' : 'Consumer') + ' Identifier</strong><span class="identifier-note">Which column contains the DM ' + (isAcct ? 'Account' : 'Consumer') + ' Number?</span></div><div class="identifier-select"><select id="identifier-column" onchange="BDL.fixedValueIdentifierChanged()" class="identifier-dropdown"><option value="">— Select identifier column —</option>';
            parsedFileData.headers.forEach(function (header, idx) { var sample = (parsedFileData.rows[0] && parsedFileData.rows[0][idx]) ? parsedFileData.rows[0][idx] : ''; var sel = (String(idx) === prevIdIdx) ? ' selected' : ''; html += '<option value="' + idx + '"' + sel + '>' + escapeHtml(header + (sample ? '  (' + sample.substring(0, 20) + ')' : '')) + '</option>'; });
            html += '</select><span class="identifier-target">&#8594; <code>' + idField.element_name + '</code></span></div></div>';
        }
        var disabledClass = (idField && !idSelected) ? ' mapping-disabled' : '';
        html += '<div class="assignment-area' + disabledClass + '" id="assignment-area">';
        if (idField && !idSelected) html += '<div class="mapping-disabled-msg">Select the identifier column above to enter values</div>';
        html += '<div class="assignment-list" id="assignment-list">';
        state.assignments.forEach(function (assignment, aIdx) {
            html += renderAssignmentCard(assignment, aIdx, state, valueFields, conditionalFields, hasConditionalOption);
        });
        html += '</div>';
        var entityWord = formatEntityName(state.entity.entity_type).split(' ').pop();
        html += '<button class="add-assignment-btn" onclick="BDL.addAssignment()">+ Add Another ' + escapeHtml(entityWord) + ' Assignment</button>';
        html += '</div>';
        html += '<div class="map-validate-actions"><button class="execute-btn" id="btn-validate-entity" onclick="BDL.validateCurrentEntity()">Validate ' + escapeHtml(formatEntityName(state.entity.entity_type)) + '</button></div>';
        area.innerHTML = html;
        area._identifierField = idField;
        area._identifierElementName = idElemName;
        area._valueFields = valueFields;
        area._conditionalFields = conditionalFields;
        checkAssignmentsComplete(state);
    }

    function renderAssignmentCard(assignment, aIdx, state, valueFields, conditionalFields, hasConditionalOption) {
        var modeBadgeClass = assignment.mode === 'conditional' ? 'assignment-badge-conditional' : (assignment.mode === 'from_file' ? 'assignment-badge-file' : 'assignment-badge-blanket');
        var modeBadgeLabel = assignment.mode === 'conditional' ? 'Conditional' : (assignment.mode === 'from_file' ? 'From File' : 'Blanket');
        var html = '<div class="assignment-card" id="assignment-card-' + aIdx + '">';
        html += '<div class="assignment-header"><div class="assignment-title"><span class="assignment-num">' + (aIdx + 1) + '</span> Assignment <span class="assignment-mode-badge ' + modeBadgeClass + '">' + modeBadgeLabel + '</span></div>';
        if (state.assignments.length > 1) html += '<span class="assignment-remove" onclick="BDL.removeAssignment(' + aIdx + ')" title="Remove assignment">&#10005;</span>';
        html += '</div>';
        if (hasConditionalOption) {
            var fileCls = assignment.mode === 'from_file' ? ' assignment-toggle-active-file' : '';
            var blanketCls = assignment.mode === 'blanket' ? ' assignment-toggle-active-blanket' : '';
            var condCls = assignment.mode === 'conditional' ? ' assignment-toggle-active-cond' : '';
            html += '<div class="assignment-mode-toggle"><div class="assignment-toggle-btn' + fileCls + '" onclick="BDL.toggleAssignmentMode(' + aIdx + ',\'from_file\')">File</div><div class="assignment-toggle-btn' + blanketCls + '" onclick="BDL.toggleAssignmentMode(' + aIdx + ',\'blanket\')">Blanket</div><div class="assignment-toggle-btn' + condCls + '" onclick="BDL.toggleAssignmentMode(' + aIdx + ',\'conditional\')">Conditional</div></div>';
        }
        html += '<div class="assignment-body">';
        if (assignment.mode === 'from_file') { html += renderFromFileAssignmentFields(assignment, aIdx, state, valueFields, conditionalFields); }
        else if (assignment.mode === 'blanket') { html += renderBlanketFields(assignment, aIdx, valueFields); }
        else { html += renderConditionalFields(assignment, aIdx, state, valueFields, conditionalFields); }
        html += '</div></div>';
        return html;
    }

    function renderBlanketFields(assignment, aIdx, valueFields) {
        var html = '';
        valueFields.forEach(function (f) {
            var fieldId = 'afv-' + aIdx + '-' + f.element_name.replace(/[^a-zA-Z0-9]/g, '');
            var existingVal = assignment.fixedValues[f.element_name] || '';
            var displayName = hasDisplayName(f) ? f.display_name : f.element_name;
            var reqLabel = f.is_import_required ? ' <span class="chip-required-label">required</span>' : '';
            html += '<div class="fixed-value-row"><div class="fixed-value-label">' + escapeHtml(displayName) + reqLabel;
            if (hasDisplayName(f)) html += '<div class="fixed-value-element">' + f.element_name + '</div>';
            if (f.field_description) html += '<div class="fixed-value-desc">' + escapeHtml(f.field_description.substring(0, 120)) + '</div>';
            if (f.import_guidance) html += '<div class="fixed-value-guidance">' + escapeHtml(f.import_guidance) + '</div>';
            html += '</div><div class="fixed-value-input">';
            if (f.lookup_table) {
                html += '<input type="text" id="' + fieldId + '" class="fixed-value-text" placeholder="Type to search..." value="' + escapeHtml(existingVal) + '" oninput="BDL.assignmentFieldSearch(' + aIdx + ',\'' + f.element_name + '\',this)" autocomplete="off"><div class="fixed-value-suggestions" id="sug-' + fieldId + '"></div>';
            } else {
                html += '<input type="text" id="' + fieldId + '" class="fixed-value-text" placeholder="Enter value" value="' + escapeHtml(existingVal) + '" oninput="BDL.assignmentFieldChanged(' + aIdx + ',\'' + f.element_name + '\',this)">';
            }
            var meta = buildFieldMeta(f); if (meta) html += '<div class="fixed-value-meta">' + meta + '</div>';
            html += '</div></div>';
        });
        return html;
    }

    function renderConditionalFields(assignment, aIdx, state, valueFields, conditionalFields) {
        var html = '';
        var condField = conditionalFields[0];
        html += '<div class="trigger-section"><div class="trigger-label"><span style="font-size:13px">&#9881;</span> Trigger column</div>';
        html += '<select class="identifier-dropdown trigger-dropdown" id="trigger-col-' + aIdx + '" onchange="BDL.setTriggerColumn(' + aIdx + ')" style="max-width:320px"><option value="">— Select trigger column —</option>';
        parsedFileData.headers.forEach(function (header, idx) {
            var sample = (parsedFileData.rows[0] && parsedFileData.rows[0][idx]) ? parsedFileData.rows[0][idx] : '';
            var sel = (assignment.triggerColumn === header) ? ' selected' : '';
            html += '<option value="' + escapeHtml(header) + '"' + sel + '>' + escapeHtml(header + (sample ? '  (' + sample.substring(0, 20) + ')' : '')) + '</option>';
        });
        html += '</select>';
        if (assignment.triggerColumn && condField) {
            html += '<div class="trigger-note">&#9432; Unique values from "' + escapeHtml(assignment.triggerColumn) + '" mapped to <code style="color:#c586c0">' + condField.element_name + '</code></div>';
        }
        html += '</div>';
        if (assignment.triggerColumn && assignment.triggerUniqueValues) {
            var uniqueVals = assignment.triggerUniqueValues;
            var showAll = assignment._showAllTriggerValues || false;
            var maxVisible = 15;
            var displayVals = showAll ? uniqueVals : uniqueVals.slice(0, maxVisible);
            var hasMore = uniqueVals.length > maxVisible && !showAll;
            html += '<div class="trigger-grid"><div class="trigger-grid-header"><span>Trigger value</span><span>' + (condField ? condField.element_name : 'Value') + '</span><span style="text-align:right">Rows</span></div>';
            displayVals.forEach(function (uv) {
                var fieldId = 'cond-' + aIdx + '-' + uv.value.replace(/[^a-zA-Z0-9]/g, '_');
                var existingVal = assignment.valueMap[uv.value] || '';
                var safeTV = escapeHtml(uv.value).replace(/'/g, "\\'");
                html += '<div class="trigger-grid-row"><span class="trigger-val"><code>' + escapeHtml(uv.value) + '</code></span><span class="trigger-input-cell">';
                if (condField && condField.lookup_table) {
                    html += '<input type="text" id="' + fieldId + '" class="trigger-grid-input" placeholder="Type to search..." value="' + escapeHtml(existingVal) + '" oninput="BDL.conditionalValueSearch(' + aIdx + ',\'' + safeTV + '\',this)" autocomplete="off"><div class="fixed-value-suggestions" id="sug-' + fieldId + '"></div>';
                } else {
                    html += '<input type="text" id="' + fieldId + '" class="trigger-grid-input" placeholder="(skip)" value="' + escapeHtml(existingVal) + '" oninput="BDL.conditionalValueChanged(' + aIdx + ',\'' + safeTV + '\',this)">';
                }
                html += '</span>';
                if (existingVal) html += '<span class="trigger-row-count">' + uv.count.toLocaleString() + '</span>';
                else html += '<span class="trigger-row-skip">skip</span>';
                html += '</div>';
            });
            if (hasMore) html += '<div class="trigger-grid-show-all" onclick="BDL.showAllTriggerValues(' + aIdx + ')">+ ' + (uniqueVals.length - maxVisible) + ' more values — show all</div>';
            html += '</div>';
        } else if (assignment.triggerColumn && !assignment.triggerUniqueValues) {
            html += '<div class="loading">Scanning file for unique values...</div>';
        }
        var sharedFields = valueFields.filter(function (f) { return !f.is_conditional_eligible; });
        if (sharedFields.length > 0 && assignment.triggerColumn) {
            html += '<div class="shared-fields-section"><div class="shared-fields-label">Shared fields (apply to all rows in this assignment)</div>';
            sharedFields.forEach(function (f) {
                var fieldId = 'asf-' + aIdx + '-' + f.element_name.replace(/[^a-zA-Z0-9]/g, '');
                var existingVal = assignment.sharedFields[f.element_name] || '';
                var displayName = hasDisplayName(f) ? f.display_name : f.element_name;
                html += '<div class="fixed-value-row"><div class="fixed-value-label">' + escapeHtml(displayName);
                if (hasDisplayName(f)) html += '<div class="fixed-value-element">' + f.element_name + '</div>';
                html += '</div><div class="fixed-value-input"><input type="text" id="' + fieldId + '" class="fixed-value-text" placeholder="Enter value" value="' + escapeHtml(existingVal) + '" oninput="BDL.sharedFieldChanged(' + aIdx + ',\'' + f.element_name + '\',this)"></div></div>';
            });
            html += '</div>';
        }
        return html;
    }

    function renderFromFileAssignmentFields(assignment, aIdx, state, valueFields, conditionalFields) {
        var html = '';
        var condField = conditionalFields[0];
        if (!condField) return html;
        var displayName = hasDisplayName(condField) ? condField.display_name : condField.element_name;
        html += '<div class="trigger-section"><div class="trigger-label"><span style="font-size:13px">&#128196;</span> Source column for ' + escapeHtml(displayName) + '</div>';
        html += '<select class="identifier-dropdown trigger-dropdown" id="filecol-' + aIdx + '" onchange="BDL.setAssignmentFileColumn(' + aIdx + ')" style="max-width:320px"><option value="">— Select file column —</option>';
        parsedFileData.headers.forEach(function (header, idx) {
            var sample = (parsedFileData.rows[0] && parsedFileData.rows[0][idx]) ? parsedFileData.rows[0][idx] : '';
            var sel = (assignment.fileColumn === header) ? ' selected' : '';
            html += '<option value="' + escapeHtml(header) + '"' + sel + '>' + escapeHtml(header + (sample ? '  (' + sample.substring(0, 20) + ')' : '')) + '</option>';
        });
        html += '</select>';
        if (assignment.fileColumn) {
            html += '<div class="trigger-note">&#9432; Values from "' + escapeHtml(assignment.fileColumn) + '" will be used for <code style="color:#569cd6">' + condField.element_name + '</code></div>';
        }
        html += '</div>';
        // Shared fields (non-conditional fields) with text inputs
        var sharedFields = valueFields.filter(function (f) { return !f.is_conditional_eligible; });
        if (sharedFields.length > 0 && assignment.fileColumn) {
            html += '<div class="shared-fields-section"><div class="shared-fields-label">Shared fields (apply to all rows in this assignment)</div>';
            sharedFields.forEach(function (f) {
                var fieldId = 'asf-' + aIdx + '-' + f.element_name.replace(/[^a-zA-Z0-9]/g, '');
                var existingVal = assignment.sharedFields[f.element_name] || '';
                var dn = hasDisplayName(f) ? f.display_name : f.element_name;
                html += '<div class="fixed-value-row"><div class="fixed-value-label">' + escapeHtml(dn);
                if (hasDisplayName(f)) html += '<div class="fixed-value-element">' + f.element_name + '</div>';
                html += '</div><div class="fixed-value-input"><input type="text" id="' + fieldId + '" class="fixed-value-text" placeholder="Enter value" value="' + escapeHtml(existingVal) + '" oninput="BDL.sharedFieldChanged(' + aIdx + ',\'' + f.element_name + '\',this)"></div></div>';
            });
            html += '</div>';
        }
        return html;
    }

    // ── FIXED_VALUE Assignment Card Actions ───────────────────────────────
    function addAssignment() {
        var state = curState(); if (!state) return;
        state.assignments.push({ mode: 'blanket', fixedValues: {}, triggerColumn: null, conditionalField: null, valueMap: {}, sharedFields: {}, triggerUniqueValues: null });
        renderFixedValueMapping(document.getElementById('map-validate-area'), state);
    }
    function removeAssignment(aIdx) {
        var state = curState(); if (!state || state.assignments.length <= 1) return;
        state.assignments.splice(aIdx, 1);
        renderFixedValueMapping(document.getElementById('map-validate-area'), state);
    }
    function toggleAssignmentMode(aIdx, mode) {
        var state = curState(); if (!state || !state.assignments[aIdx]) return;
        if (state.assignments[aIdx].mode === mode) return;
        var area = document.getElementById('map-validate-area');
        state.assignments[aIdx].mode = mode;
        if (mode === 'blanket') {
            state.assignments[aIdx].triggerColumn = null; state.assignments[aIdx].conditionalField = null;
            state.assignments[aIdx].valueMap = {}; state.assignments[aIdx].sharedFields = {};
            state.assignments[aIdx].triggerUniqueValues = null; state.assignments[aIdx]._showAllTriggerValues = false;
            state.assignments[aIdx].fileColumn = null;
        } else if (mode === 'from_file') {
            state.assignments[aIdx].fixedValues = {};
            state.assignments[aIdx].triggerColumn = null;
            state.assignments[aIdx].valueMap = {};
            state.assignments[aIdx].triggerUniqueValues = null; state.assignments[aIdx]._showAllTriggerValues = false;
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
        renderFixedValueMapping(area, state);
    }
    function setAssignmentFileColumn(aIdx) {
        var state = curState(); if (!state || !state.assignments[aIdx]) return;
        var sel = document.getElementById('filecol-' + aIdx);
        var headerName = sel ? sel.value : '';
        state.assignments[aIdx].fileColumn = headerName || null;
        renderFixedValueMapping(document.getElementById('map-validate-area'), state);
    }
    function showAllTriggerValues(aIdx) {
        var state = curState(); if (!state || !state.assignments[aIdx]) return;
        state.assignments[aIdx]._showAllTriggerValues = true;
        renderFixedValueMapping(document.getElementById('map-validate-area'), state);
    }
    function setTriggerColumn(aIdx) {
        var state = curState(); if (!state || !state.assignments[aIdx]) return;
        var sel = document.getElementById('trigger-col-' + aIdx);
        var headerName = sel ? sel.value : '';
        if (!headerName) {
            state.assignments[aIdx].triggerColumn = null; state.assignments[aIdx].triggerUniqueValues = null;
            state.assignments[aIdx].valueMap = {}; state.assignments[aIdx]._showAllTriggerValues = false;
            renderFixedValueMapping(document.getElementById('map-validate-area'), state); return;
        }
        state.assignments[aIdx].triggerColumn = headerName; state.assignments[aIdx].triggerUniqueValues = null;
        state.assignments[aIdx].valueMap = {}; state.assignments[aIdx]._showAllTriggerValues = false;
        renderFixedValueMapping(document.getElementById('map-validate-area'), state);
        var headerIndex = parsedFileData.headers.indexOf(headerName);
        if (headerIndex < 0) return;
        readFileColumnValues(headerIndex, function (uniqueValues) {
            var currentState = curState();
            if (!currentState || !currentState.assignments[aIdx] || currentState.assignments[aIdx].triggerColumn !== headerName) return;
            currentState.assignments[aIdx].triggerUniqueValues = uniqueValues;
            renderFixedValueMapping(document.getElementById('map-validate-area'), currentState);
        });
    }

    function readFileColumnValues(colIndex, callback) {
        var ext = '.' + uploadedFile.name.split('.').pop().toLowerCase();
        var reader = new FileReader();
        reader.onload = function (e) {
            var allRows;
            try { if (ext === '.csv' || ext === '.txt') allRows = parseCSVAllRows(e.target.result); else allRows = parseExcelAllRows(e.target.result); }
            catch (err) { callback([]); return; }
            var counts = {};
            for (var r = 0; r < allRows.length; r++) {
                var val = (colIndex < allRows[r].length) ? allRows[r][colIndex].trim() : '';
                if (val === '') continue;
                if (!counts[val]) counts[val] = 0;
                counts[val]++;
            }
            var result = Object.keys(counts).sort().map(function (v) { return { value: v, count: counts[v] }; });
            callback(result);
        };
        if (ext === '.csv' || ext === '.txt') reader.readAsText(uploadedFile); else reader.readAsArrayBuffer(uploadedFile);
    }

    // ── FIXED_VALUE Assignment Value Change/Search/Select ────────────────
    function assignmentFieldChanged(aIdx, elementName, input) {
        var state = curState(); if (!state || !state.assignments[aIdx]) return;
        var val = input.value.trim();
        if (val) state.assignments[aIdx].fixedValues[elementName] = val;
        else delete state.assignments[aIdx].fixedValues[elementName];
        checkAssignmentsComplete(state);
    }

    var searchDebounceTimer = null;

    function assignmentFieldSearch(aIdx, elementName, input) {
        var state = curState(); if (!state || !state.assignments[aIdx]) return;
        var val = input.value.trim();
        if (val) state.assignments[aIdx].fixedValues[elementName] = val;
        else delete state.assignments[aIdx].fixedValues[elementName];
        var fieldId = 'afv-' + aIdx + '-' + elementName.replace(/[^a-zA-Z0-9]/g, '');
        var sugEl = document.getElementById('sug-' + fieldId); if (!sugEl) return;
        if (val.length < 2) { sugEl.innerHTML = ''; checkAssignmentsComplete(state); return; }
        var field = state.fields.find(function (f) { return f.element_name === elementName; });
        if (!field || !field.lookup_table) { checkAssignmentsComplete(state); return; }
        if (!state._lookupCache) state._lookupCache = {};
        var cacheKey = elementName + '::' + val.toLowerCase();
        if (state._lookupCache[cacheKey]) { renderAssignmentSuggestions(document.getElementById('sug-' + fieldId), state._lookupCache[cacheKey], aIdx, 'blanket', elementName); checkAssignmentsComplete(state); return; }
        if (searchDebounceTimer) clearTimeout(searchDebounceTimer);
        sugEl.innerHTML = '<div class="suggestion-hint">Searching...</div>';
        searchDebounceTimer = setTimeout(function () {
            fetch('/api/bdl-import/lookup-search?lookup_table=' + encodeURIComponent(field.lookup_table) + '&element_name=' + encodeURIComponent(elementName) + '&search=' + encodeURIComponent(val) +'&config_id=' + encodeURIComponent(selectedEnvironment.config_id) + '&entity_type=' + encodeURIComponent(curState().entity.entity_type))
                .then(function (r) { return r.json(); }).then(function (data) { if (data.error) { sugEl.innerHTML = '<div class="suggestion-hint" style="color:#f48771;">' + escapeHtml(data.error) + '</div>'; return; } var values = data.values || []; state._lookupCache[cacheKey] = values; renderAssignmentSuggestions(sugEl, values, aIdx, 'blanket', elementName); })
                .catch(function () { sugEl.innerHTML = '<div class="suggestion-hint" style="color:#f48771;">Lookup failed</div>'; });
        }, 300);
        checkAssignmentsComplete(state);
    }
    function selectAssignmentValue(aIdx, elementName, value) {
        var state = curState(); if (!state || !state.assignments[aIdx]) return;
        var fieldId = 'afv-' + aIdx + '-' + elementName.replace(/[^a-zA-Z0-9]/g, '');
        var input = document.getElementById(fieldId); if (input) input.value = value;
        state.assignments[aIdx].fixedValues[elementName] = value;
        var sugEl = document.getElementById('sug-' + fieldId); if (sugEl) sugEl.innerHTML = '';
        checkAssignmentsComplete(state);
    }
    function sharedFieldChanged(aIdx, elementName, input) {
        var state = curState(); if (!state || !state.assignments[aIdx]) return;
        var val = input.value.trim();
        if (val) state.assignments[aIdx].sharedFields[elementName] = val;
        else delete state.assignments[aIdx].sharedFields[elementName];
        checkAssignmentsComplete(state);
    }
    function conditionalValueChanged(aIdx, triggerVal, input) {
        var state = curState(); if (!state || !state.assignments[aIdx]) return;
        var val = input.value.trim();
        if (val) state.assignments[aIdx].valueMap[triggerVal] = val;
        else delete state.assignments[aIdx].valueMap[triggerVal];
        updateTriggerRowDisplay(aIdx, triggerVal, val);
        checkAssignmentsComplete(state);
    }
    function conditionalValueSearch(aIdx, triggerVal, input) {
        var state = curState(); if (!state || !state.assignments[aIdx]) return;
        var val = input.value.trim();
        if (val) state.assignments[aIdx].valueMap[triggerVal] = val;
        else delete state.assignments[aIdx].valueMap[triggerVal];
        var condField = state.assignments[aIdx].conditionalField;
        var fieldId = 'cond-' + aIdx + '-' + triggerVal.replace(/[^a-zA-Z0-9]/g, '_');
        var sugEl = document.getElementById('sug-' + fieldId); if (!sugEl) return;
        if (val.length < 2) { sugEl.innerHTML = ''; checkAssignmentsComplete(state); return; }
        var field = state.fields.find(function (f) { return f.element_name === condField; });
        if (!field || !field.lookup_table) { checkAssignmentsComplete(state); return; }
        if (!state._lookupCache) state._lookupCache = {};
        var cacheKey = condField + '::' + val.toLowerCase();
        if (state._lookupCache[cacheKey]) { renderAssignmentSuggestions(document.getElementById('sug-' + fieldId), state._lookupCache[cacheKey], aIdx, 'conditional', triggerVal); checkAssignmentsComplete(state); return; }
        if (searchDebounceTimer) clearTimeout(searchDebounceTimer);
        sugEl.innerHTML = '<div class="suggestion-hint">Searching...</div>';
        searchDebounceTimer = setTimeout(function () {
            fetch('/api/bdl-import/lookup-search?lookup_table=' + encodeURIComponent(field.lookup_table) + '&element_name=' + encodeURIComponent(condField) + '&search=' + encodeURIComponent(val) + '&config_id=' + encodeURIComponent(selectedEnvironment.config_id) + '&entity_type=' + encodeURIComponent(curState().entity.entity_type))
                .then(function (r) { return r.json(); }).then(function (data) { if (data.error) { sugEl.innerHTML = '<div class="suggestion-hint" style="color:#f48771;">' + escapeHtml(data.error) + '</div>'; return; } var values = data.values || []; state._lookupCache[cacheKey] = values; renderAssignmentSuggestions(sugEl, values, aIdx, 'conditional', triggerVal); })
                .catch(function () { sugEl.innerHTML = '<div class="suggestion-hint" style="color:#f48771;">Lookup failed</div>'; });
        }, 300);
        checkAssignmentsComplete(state);
    }
    function selectConditionalValue(aIdx, triggerVal, value) {
        var state = curState(); if (!state || !state.assignments[aIdx]) return;
        var fieldId = 'cond-' + aIdx + '-' + triggerVal.replace(/[^a-zA-Z0-9]/g, '_');
        var input = document.getElementById(fieldId); if (input) input.value = value;
        state.assignments[aIdx].valueMap[triggerVal] = value;
        var sugEl = document.getElementById('sug-' + fieldId); if (sugEl) sugEl.innerHTML = '';
        updateTriggerRowDisplay(aIdx, triggerVal, value);
        checkAssignmentsComplete(state);
    }
    function updateTriggerRowDisplay(aIdx, triggerVal, value) {
        var state = curState(); if (!state || !state.assignments[aIdx]) return;
        var fieldId = 'cond-' + aIdx + '-' + triggerVal.replace(/[^a-zA-Z0-9]/g, '_');
        var inputEl = document.getElementById(fieldId); if (!inputEl) return;
        var row = inputEl.closest('.trigger-grid-row'); if (!row) return;
        var countSpan = row.querySelector('.trigger-row-count, .trigger-row-skip');
        if (!countSpan) return;
        var uv = state.assignments[aIdx].triggerUniqueValues ? state.assignments[aIdx].triggerUniqueValues.find(function (u) { return u.value === triggerVal; }) : null;
        if (value) { countSpan.className = 'trigger-row-count'; countSpan.textContent = uv ? uv.count.toLocaleString() : ''; }
        else { countSpan.className = 'trigger-row-skip'; countSpan.textContent = 'skip'; }
    }
    function renderAssignmentSuggestions(sugEl, values, aIdx, scope, key) {
        if (values.length === 0) { sugEl.innerHTML = '<div class="suggestion-none">No matches</div>'; return; }
        var selectFn = (scope === 'blanket') ? 'BDL.selectAssignmentValue' : 'BDL.selectConditionalValue';
        var html = '';
        values.forEach(function (item) {
            var val = item.value || item;
            var safeVal = escapeHtml(String(val)).replace(/'/g, "\\'");
            var safeKey = escapeHtml(String(key)).replace(/'/g, "\\'");
            html += '<div class="suggestion-item" onclick="' + selectFn + '(' + aIdx + ',\'' + safeKey + '\',\'' + safeVal + '\')"><span class="suggestion-value">' + escapeHtml(String(val)) + '</span>';
            if (item.description) html += '<span class="suggestion-desc">' + escapeHtml(item.description) + '</span>';
            html += '</div>';
        });
        sugEl.innerHTML = html;
    }
    function fixedValueIdentifierChanged() {
        var area = document.getElementById('map-validate-area'), idSel = document.getElementById('identifier-column'), idElem = area._identifierElementName;
        var state = curState(); if (!state) return;
        var cm = state.columnMapping; for (var k in cm) { if (cm[k] === idElem) delete cm[k]; }
        if (idSel.value !== '') cm[parsedFileData.headers[parseInt(idSel.value)]] = idElem;
        var idSection = document.querySelector('.mapping-identifier'), assignArea = document.getElementById('assignment-area');
        if (idSel.value !== '') { if (idSection) { idSection.classList.remove('identifier-pending'); idSection.classList.add('identifier-confirmed'); } if (assignArea) { assignArea.classList.remove('mapping-disabled'); var msg = assignArea.querySelector('.mapping-disabled-msg'); if (msg) msg.remove(); } }
        else { if (idSection) { idSection.classList.remove('identifier-confirmed'); idSection.classList.add('identifier-pending'); } if (assignArea) assignArea.classList.add('mapping-disabled'); }
        checkAssignmentsComplete(state);
    }
    function checkAssignmentsComplete(state) {
        if (!state) return;
        var area = document.getElementById('map-validate-area');
        var idElem = area ? area._identifierElementName : '';
        var hasIdentifier = false;
        for (var k in state.columnMapping) { if (state.columnMapping[k] === idElem) { hasIdentifier = true; break; } }
        if (!hasIdentifier || !state.assignments || state.assignments.length === 0) {
            var valBtn = document.getElementById('btn-validate-entity'); if (valBtn) valBtn.disabled = true; return;
        }
        var allComplete = true;
        var valueFields = area ? area._valueFields || [] : [];
        state.assignments.forEach(function (a) {
            if (a.mode === 'blanket') {
                valueFields.forEach(function (f) { if (f.is_import_required && !a.fixedValues[f.element_name]) allComplete = false; });
            } else if (a.mode === 'from_file') {
                if (!a.fileColumn) { allComplete = false; return; }
            } else if (a.mode === 'conditional') {
                if (!a.triggerColumn || !a.triggerUniqueValues) { allComplete = false; return; }
                var hasMappedValue = Object.keys(a.valueMap).some(function (k) { return a.valueMap[k] && a.valueMap[k].trim() !== ''; });
                if (!hasMappedValue) allComplete = false;
            }
        });
        var valBtn = document.getElementById('btn-validate-entity'); if (valBtn) valBtn.disabled = !allComplete;
    }

    // ══════════════════════════════════════════════════════════════════════
    // Per-Field Mode Selector (FILE_MAPPED entities)
    // Conditional-eligible fields get a 3-way toggle: File / Blanket / Cond
    // Selecting Blanket or Conditional pulls the field from the target panel
    // and creates a field assignment card in the Field Assignments section.
    // ══════════════════════════════════════════════════════════════════════

    function toggleFieldMode(elementName, mode) {
        var state = curState(); if (!state) return;
        if (!state.fieldAssignments) state.fieldAssignments = {};
        if (mode === 'from_file') {
            delete state.fieldAssignments[elementName];
        } else {
            var field = state.fields ? state.fields.find(function (f) { return f.element_name === elementName; }) : null;
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
        refreshMappingPanels();
    }

    function renderFieldAssignmentsSection(state) {
        var container = document.getElementById('field-assignments-area');
        if (!container) return;
        if (!state.fieldAssignments || Object.keys(state.fieldAssignments).length === 0) {
            container.innerHTML = '';
            return;
        }
        var html = '<div class="field-assignments-section">';
        html += '<div class="panel-header" style="color:#dcdcaa;">Field Assignments</div>';
        html += '<div class="field-assignments-list">';
        Object.keys(state.fieldAssignments).forEach(function (elemName) {
            var fa = state.fieldAssignments[elemName];
            html += renderFieldAssignmentCard(elemName, fa, state);
        });
        html += '</div></div>';
        container.innerHTML = html;
    }

    function renderFieldAssignmentCard(elementName, fa, state) {
        var field = state.fields ? state.fields.find(function (f) { return f.element_name === elementName; }) : null;
        var displayName = field ? getFieldDisplayName(field) : elementName;
        var modeBadgeClass = fa.mode === 'conditional' ? 'assignment-badge-conditional' : 'assignment-badge-blanket';
        var modeBadgeLabel = fa.mode === 'conditional' ? 'Conditional' : 'Blanket';
        var safeElem = elementName.replace(/'/g, "\\'");

        var html = '<div class="assignment-card field-assignment-card">';
        html += '<div class="assignment-header"><div class="assignment-title">';
        html += '<span class="field-assignment-name">' + escapeHtml(displayName) + '</span>';
        if (hasDisplayName(field)) html += ' <code class="field-assignment-elem">' + elementName + '</code>';
        html += ' <span class="assignment-mode-badge ' + modeBadgeClass + '">' + modeBadgeLabel + '</span>';
        html += '</div>';
        html += '<span class="assignment-remove" onclick="BDL.toggleFieldMode(\'' + safeElem + '\',\'from_file\')" title="Return to file mapping">&#8592; File</span>';
        html += '</div>';

        // Mode toggle
        var blanketCls = fa.mode === 'blanket' ? ' assignment-toggle-active-blanket' : '';
        var condCls = fa.mode === 'conditional' ? ' assignment-toggle-active-cond' : '';
        html += '<div class="assignment-mode-toggle">';
        html += '<div class="assignment-toggle-btn' + blanketCls + '" onclick="BDL.switchFieldMode(\'' + safeElem + '\',\'blanket\')">Blanket</div>';
        html += '<div class="assignment-toggle-btn' + condCls + '" onclick="BDL.switchFieldMode(\'' + safeElem + '\',\'conditional\')">Conditional</div>';
        html += '</div>';

        html += '<div class="assignment-body">';
        if (fa.mode === 'blanket') {
            html += renderFieldBlanketInput(elementName, fa, field);
        } else {
            html += renderFieldConditionalInput(elementName, fa, field, state);
        }
        html += '</div></div>';
        return html;
    }

    function renderFieldBlanketInput(elementName, fa, field) {
        var fieldId = 'fa-blanket-' + elementName.replace(/[^a-zA-Z0-9]/g, '');
        var existingVal = fa.value || '';
        var html = '<div class="fixed-value-row"><div class="fixed-value-label">Value for all rows';
        if (field && field.import_guidance) html += '<div class="fixed-value-guidance">' + escapeHtml(field.import_guidance) + '</div>';
        html += '</div><div class="fixed-value-input">';
        if (field && field.lookup_table) {
            html += '<input type="text" id="' + fieldId + '" class="fixed-value-text" placeholder="Type to search..." value="' + escapeHtml(existingVal) + '" oninput="BDL.fieldAssignmentSearch(\'' + elementName + '\',this)" autocomplete="off"><div class="fixed-value-suggestions" id="sug-' + fieldId + '"></div>';
        } else {
            html += '<input type="text" id="' + fieldId + '" class="fixed-value-text" placeholder="Enter value" value="' + escapeHtml(existingVal) + '" oninput="BDL.fieldAssignmentValueChanged(\'' + elementName + '\',this)">';
        }
        if (field) { var meta = buildFieldMeta(field); if (meta) html += '<div class="fixed-value-meta">' + meta + '</div>'; }
        html += '</div></div>';
        return html;
    }

    function renderFieldConditionalInput(elementName, fa, field, state) {
        var html = '';
        var safeElem = elementName.replace(/'/g, "\\'");
        html += '<div class="trigger-section"><div class="trigger-label"><span style="font-size:13px">&#9881;</span> Trigger column</div>';
        html += '<select class="identifier-dropdown trigger-dropdown" id="fa-trigger-' + elementName.replace(/[^a-zA-Z0-9]/g, '') + '" onchange="BDL.setFieldTriggerColumn(\'' + safeElem + '\')" style="max-width:320px"><option value="">— Select trigger column —</option>';
        parsedFileData.headers.forEach(function (header, idx) {
            var sample = (parsedFileData.rows[0] && parsedFileData.rows[0][idx]) ? parsedFileData.rows[0][idx] : '';
            var sel = (fa.triggerColumn === header) ? ' selected' : '';
            html += '<option value="' + escapeHtml(header) + '"' + sel + '>' + escapeHtml(header + (sample ? '  (' + sample.substring(0, 20) + ')' : '')) + '</option>';
        });
        html += '</select>';
        if (fa.triggerColumn && field) {
            var dn = field ? getFieldDisplayName(field) : elementName;
            html += '<div class="trigger-note">&#9432; Unique values from "' + escapeHtml(fa.triggerColumn) + '" mapped to <code style="color:#c586c0">' + escapeHtml(dn) + '</code></div>';
        }
        html += '</div>';
        if (fa.triggerColumn && fa.triggerUniqueValues) {
            var uniqueVals = fa.triggerUniqueValues;
            var showAll = fa._showAllTriggerValues || false;
            var maxVisible = 15;
            var displayVals = showAll ? uniqueVals : uniqueVals.slice(0, maxVisible);
            var hasMore = uniqueVals.length > maxVisible && !showAll;
            html += '<div class="trigger-grid"><div class="trigger-grid-header"><span>Trigger value</span><span>' + (field ? getFieldDisplayName(field) : elementName) + '</span><span style="text-align:right">Rows</span></div>';
            displayVals.forEach(function (uv) {
                var fieldId = 'fa-cond-' + elementName.replace(/[^a-zA-Z0-9]/g, '') + '-' + uv.value.replace(/[^a-zA-Z0-9]/g, '_');
                var existingVal = fa.valueMap[uv.value] || '';
                var safeTV = escapeHtml(uv.value).replace(/'/g, "\\'");
                html += '<div class="trigger-grid-row"><span class="trigger-val"><code>' + escapeHtml(uv.value) + '</code></span><span class="trigger-input-cell">';
                if (field && field.lookup_table) {
                    html += '<input type="text" id="' + fieldId + '" class="trigger-grid-input" placeholder="Type to search..." value="' + escapeHtml(existingVal) + '" oninput="BDL.fieldCondValueSearch(\'' + safeElem + '\',\'' + safeTV + '\',this)" autocomplete="off"><div class="fixed-value-suggestions" id="sug-' + fieldId + '"></div>';
                } else {
                    html += '<input type="text" id="' + fieldId + '" class="trigger-grid-input" placeholder="(skip)" value="' + escapeHtml(existingVal) + '" oninput="BDL.fieldCondValueChanged(\'' + safeElem + '\',\'' + safeTV + '\',this)">';
                }
                html += '</span>';
                if (existingVal) html += '<span class="trigger-row-count">' + uv.count.toLocaleString() + '</span>';
                else html += '<span class="trigger-row-skip">skip</span>';
                html += '</div>';
            });
            if (hasMore) html += '<div class="trigger-grid-show-all" onclick="BDL.showAllFieldTriggerValues(\'' + safeElem + '\')">+ ' + (uniqueVals.length - maxVisible) + ' more values — show all</div>';
            html += '</div>';
        } else if (fa.triggerColumn && !fa.triggerUniqueValues) {
            html += '<div class="loading">Scanning file for unique values...</div>';
        }
        return html;
    }

    // ── Per-Field Assignment Value Handlers ───────────────────────────────

    function switchFieldMode(elementName, mode) {
        var state = curState(); if (!state || !state.fieldAssignments || !state.fieldAssignments[elementName]) return;
        if (state.fieldAssignments[elementName].mode === mode) return;
        state.fieldAssignments[elementName].mode = mode;
        state.fieldAssignments[elementName].value = '';
        state.fieldAssignments[elementName].triggerColumn = null;
        state.fieldAssignments[elementName].valueMap = {};
        state.fieldAssignments[elementName].triggerUniqueValues = null;
        state.fieldAssignments[elementName]._showAllTriggerValues = false;
        refreshMappingPanels();
    }

    function fieldAssignmentValueChanged(elementName, input) {
        var state = curState(); if (!state || !state.fieldAssignments || !state.fieldAssignments[elementName]) return;
        state.fieldAssignments[elementName].value = input.value.trim();
        checkMappingComplete();
    }

    function fieldAssignmentSearch(elementName, input) {
        var state = curState(); if (!state || !state.fieldAssignments || !state.fieldAssignments[elementName]) return;
        state.fieldAssignments[elementName].value = input.value.trim();
        var val = input.value.trim();
        var fieldId = 'fa-blanket-' + elementName.replace(/[^a-zA-Z0-9]/g, '');
        var sugEl = document.getElementById('sug-' + fieldId); if (!sugEl) return;
        if (val.length < 2) { sugEl.innerHTML = ''; checkMappingComplete(); return; }
        var field = state.fields.find(function (f) { return f.element_name === elementName; });
        if (!field || !field.lookup_table) { checkMappingComplete(); return; }
        if (!state._lookupCache) state._lookupCache = {};
        var cacheKey = elementName + '::' + val.toLowerCase();
        if (state._lookupCache[cacheKey]) { renderFieldSuggestions(sugEl, state._lookupCache[cacheKey], elementName); checkMappingComplete(); return; }
        if (searchDebounceTimer) clearTimeout(searchDebounceTimer);
        sugEl.innerHTML = '<div class="suggestion-hint">Searching...</div>';
        searchDebounceTimer = setTimeout(function () {
            fetch('/api/bdl-import/lookup-search?lookup_table=' + encodeURIComponent(field.lookup_table) + '&element_name=' + encodeURIComponent(elementName) + '&search=' + encodeURIComponent(val) + '&config_id=' + encodeURIComponent(selectedEnvironment.config_id) + '&entity_type=' + encodeURIComponent(curState().entity.entity_type))
                .then(function (r) { return r.json(); }).then(function (data) {
                    if (data.error) { sugEl.innerHTML = '<div class="suggestion-hint" style="color:#f48771;">' + escapeHtml(data.error) + '</div>'; return; }
                    var values = data.values || []; state._lookupCache[cacheKey] = values;
                    renderFieldSuggestions(sugEl, values, elementName);
                }).catch(function () { sugEl.innerHTML = '<div class="suggestion-hint" style="color:#f48771;">Lookup failed</div>'; });
        }, 300);
        checkMappingComplete();
    }

    function selectFieldAssignmentValue(elementName, value) {
        var state = curState(); if (!state || !state.fieldAssignments || !state.fieldAssignments[elementName]) return;
        var fieldId = 'fa-blanket-' + elementName.replace(/[^a-zA-Z0-9]/g, '');
        var input = document.getElementById(fieldId); if (input) input.value = value;
        state.fieldAssignments[elementName].value = value;
        var sugEl = document.getElementById('sug-' + fieldId); if (sugEl) sugEl.innerHTML = '';
        checkMappingComplete();
    }

    function setFieldTriggerColumn(elementName) {
        var state = curState(); if (!state || !state.fieldAssignments || !state.fieldAssignments[elementName]) return;
        var selId = 'fa-trigger-' + elementName.replace(/[^a-zA-Z0-9]/g, '');
        var sel = document.getElementById(selId);
        var headerName = sel ? sel.value : '';
        var fa = state.fieldAssignments[elementName];
        if (!headerName) {
            fa.triggerColumn = null; fa.triggerUniqueValues = null; fa.valueMap = {};
            fa._showAllTriggerValues = false;
            refreshMappingPanels(); return;
        }
        fa.triggerColumn = headerName; fa.triggerUniqueValues = null; fa.valueMap = {};
        fa._showAllTriggerValues = false;
        refreshMappingPanels();
        var headerIndex = parsedFileData.headers.indexOf(headerName);
        if (headerIndex < 0) return;
        readFileColumnValues(headerIndex, function (uniqueValues) {
            var currentState = curState();
            if (!currentState || !currentState.fieldAssignments || !currentState.fieldAssignments[elementName]) return;
            if (currentState.fieldAssignments[elementName].triggerColumn !== headerName) return;
            currentState.fieldAssignments[elementName].triggerUniqueValues = uniqueValues;
            refreshMappingPanels();
        });
    }

    function fieldCondValueChanged(elementName, triggerVal, input) {
        var state = curState(); if (!state || !state.fieldAssignments || !state.fieldAssignments[elementName]) return;
        var val = input.value.trim();
        if (val) state.fieldAssignments[elementName].valueMap[triggerVal] = val;
        else delete state.fieldAssignments[elementName].valueMap[triggerVal];
        var fieldId = 'fa-cond-' + elementName.replace(/[^a-zA-Z0-9]/g, '') + '-' + triggerVal.replace(/[^a-zA-Z0-9]/g, '_');
        var inputEl = document.getElementById(fieldId); if (inputEl) {
            var row = inputEl.closest('.trigger-grid-row'); if (row) {
                var countSpan = row.querySelector('.trigger-row-count, .trigger-row-skip');
                if (countSpan) {
                    var fa = state.fieldAssignments[elementName];
                    var uv = fa.triggerUniqueValues ? fa.triggerUniqueValues.find(function (u) { return u.value === triggerVal; }) : null;
                    if (val) { countSpan.className = 'trigger-row-count'; countSpan.textContent = uv ? uv.count.toLocaleString() : ''; }
                    else { countSpan.className = 'trigger-row-skip'; countSpan.textContent = 'skip'; }
                }
            }
        }
        checkMappingComplete();
    }

    function fieldCondValueSearch(elementName, triggerVal, input) {
        var state = curState(); if (!state || !state.fieldAssignments || !state.fieldAssignments[elementName]) return;
        var val = input.value.trim();
        if (val) state.fieldAssignments[elementName].valueMap[triggerVal] = val;
        else delete state.fieldAssignments[elementName].valueMap[triggerVal];
        var fieldId = 'fa-cond-' + elementName.replace(/[^a-zA-Z0-9]/g, '') + '-' + triggerVal.replace(/[^a-zA-Z0-9]/g, '_');
        var sugEl = document.getElementById('sug-' + fieldId); if (!sugEl) return;
        if (val.length < 2) { sugEl.innerHTML = ''; checkMappingComplete(); return; }
        var field = state.fields.find(function (f) { return f.element_name === elementName; });
        if (!field || !field.lookup_table) { checkMappingComplete(); return; }
        if (!state._lookupCache) state._lookupCache = {};
        var cacheKey = elementName + '::' + val.toLowerCase();
        if (state._lookupCache[cacheKey]) { renderFieldSuggestions(sugEl, state._lookupCache[cacheKey], elementName, triggerVal); checkMappingComplete(); return; }
        if (searchDebounceTimer) clearTimeout(searchDebounceTimer);
        sugEl.innerHTML = '<div class="suggestion-hint">Searching...</div>';
        searchDebounceTimer = setTimeout(function () {
            fetch('/api/bdl-import/lookup-search?lookup_table=' + encodeURIComponent(field.lookup_table) + '&element_name=' + encodeURIComponent(elementName) + '&search=' + encodeURIComponent(val) + '&config_id=' + encodeURIComponent(selectedEnvironment.config_id) + '&entity_type=' + encodeURIComponent(curState().entity.entity_type))
                .then(function (r) { return r.json(); }).then(function (data) {
                    if (data.error) { sugEl.innerHTML = '<div class="suggestion-hint" style="color:#f48771;">' + escapeHtml(data.error) + '</div>'; return; }
                    var values = data.values || []; state._lookupCache[cacheKey] = values;
                    renderFieldSuggestions(sugEl, values, elementName, triggerVal);
                }).catch(function () { sugEl.innerHTML = '<div class="suggestion-hint" style="color:#f48771;">Lookup failed</div>'; });
        }, 300);
        checkMappingComplete();
    }

    function selectFieldCondValue(elementName, triggerVal, value) {
        var state = curState(); if (!state || !state.fieldAssignments || !state.fieldAssignments[elementName]) return;
        var fieldId = 'fa-cond-' + elementName.replace(/[^a-zA-Z0-9]/g, '') + '-' + triggerVal.replace(/[^a-zA-Z0-9]/g, '_');
        var input = document.getElementById(fieldId); if (input) input.value = value;
        state.fieldAssignments[elementName].valueMap[triggerVal] = value;
        var sugEl = document.getElementById('sug-' + fieldId); if (sugEl) sugEl.innerHTML = '';
        var inputEl = document.getElementById(fieldId); if (inputEl) {
            var row = inputEl.closest('.trigger-grid-row'); if (row) {
                var countSpan = row.querySelector('.trigger-row-count, .trigger-row-skip');
                if (countSpan) {
                    var fa = state.fieldAssignments[elementName];
                    var uv = fa.triggerUniqueValues ? fa.triggerUniqueValues.find(function (u) { return u.value === triggerVal; }) : null;
                    countSpan.className = 'trigger-row-count'; countSpan.textContent = uv ? uv.count.toLocaleString() : '';
                }
            }
        }
        checkMappingComplete();
    }

    function showAllFieldTriggerValues(elementName) {
        var state = curState(); if (!state || !state.fieldAssignments || !state.fieldAssignments[elementName]) return;
        state.fieldAssignments[elementName]._showAllTriggerValues = true;
        refreshMappingPanels();
    }

    function renderFieldSuggestions(sugEl, values, elementName, triggerVal) {
        if (values.length === 0) { sugEl.innerHTML = '<div class="suggestion-none">No matches</div>'; return; }
        var safeElem = escapeHtml(String(elementName)).replace(/'/g, "\\'");
        var html = '';
        values.forEach(function (item) {
            var val = item.value || item;
            var safeVal = escapeHtml(String(val)).replace(/'/g, "\\'");
            if (triggerVal !== undefined) {
                var safeTV = escapeHtml(String(triggerVal)).replace(/'/g, "\\'");
                html += '<div class="suggestion-item" onclick="BDL.selectFieldCondValue(\'' + safeElem + '\',\'' + safeTV + '\',\'' + safeVal + '\')">';
            } else {
                html += '<div class="suggestion-item" onclick="BDL.selectFieldAssignmentValue(\'' + safeElem + '\',\'' + safeVal + '\')">';
            }
            html += '<span class="suggestion-value">' + escapeHtml(String(val)) + '</span>';
            if (item.description) html += '<span class="suggestion-desc">' + escapeHtml(item.description) + '</span>';
            html += '</div>';
        });
        sugEl.innerHTML = html;
    }

    function renderMapValidateValidation(area, state) {
        var html = renderEntityProgressBanner('validating');
        html += buildValidationResultsHtml(state.validationResult.warnings, state.validationResult.serverData);
        area.innerHTML = html;
    }

    function renderMapValidateValidated(area, state) {
        var html = renderEntityProgressBanner('complete');
        var detailParts = [];
        if (state.stagingContext) detailParts.push(state.stagingContext.row_count.toLocaleString() + ' rows staged');
        var mappedCount = Object.keys(state.columnMapping).length;
        var faCount = state.fieldAssignments ? Object.keys(state.fieldAssignments).length : 0;
        detailParts.push((mappedCount + faCount) + ' field' + ((mappedCount + faCount) !== 1 ? 's' : '') + ' mapped');
        if (state.nullifyFields && state.nullifyFields.length > 0) {
            detailParts.push(state.nullifyFields.length + ' field' + (state.nullifyFields.length !== 1 ? 's' : '') + ' will be nullified');
        }
        html += '<div class="validation-summary validation-pass"><span class="validation-icon">&#10003;</span><div><strong>' + escapeHtml(formatEntityName(state.entity.entity_type)) + ' — Mapping and validation complete</strong><div class="validation-detail">' + detailParts.join(' &middot; ') + '</div></div></div>';
        var mappingKeys = Object.keys(state.columnMapping);
        if (mappingKeys.length > 0 || faCount > 0) {
            html += '<div class="execute-mapped-summary"><span class="mapped-summary-icon">&#128279;</span> <strong>Mapped Fields:</strong> ';
            var fieldCodes = mappingKeys.map(function (sc) {
                var te = state.columnMapping[sc];
                var fld = state.fields ? state.fields.find(function (f) { return f.element_name === te; }) : null;
                return '<code>' + escapeHtml(fld ? getFieldDisplayName(fld) : te) + '</code>';
            });
            if (state.fieldAssignments) {
                Object.keys(state.fieldAssignments).forEach(function (elemName) {
                    var fa = state.fieldAssignments[elemName];
                    var fld = state.fields ? state.fields.find(function (f) { return f.element_name === elemName; }) : null;
                    var label = fld ? getFieldDisplayName(fld) : elemName;
                    var modeTag = fa.mode === 'conditional' ? ' <span style="color:#dcdcaa;font-size:10px;">(cond)</span>' : ' <span style="color:#4ec9b0;font-size:10px;">(fixed)</span>';
                    fieldCodes.push('<code>' + escapeHtml(label) + '</code>' + modeTag);
                });
            }
            html += fieldCodes.join(', ');
            html += '</div>';
        }
        if (state.nullifyFields && state.nullifyFields.length > 0) {
            html += '<div class="nullify-summary"><span class="nullify-summary-icon">&#8709;</span> <strong>Nullify:</strong> ';
            html += state.nullifyFields.map(function (nf) { return '<code>' + escapeHtml(getFieldDisplayNameByElement(nf)) + '</code>'; }).join(', ');
            html += '</div>';
        }
        html += '<div class="map-validate-actions">';
        html += '<button class="nav-btn" onclick="BDL.revalidateCurrentEntity()">Re-validate</button>';
        if (currentEntityIndex < entityStates.length - 1) html += '<button class="execute-btn" onclick="BDL.advanceToNextEntity()">Continue to ' + escapeHtml(formatEntityName(entityStates[currentEntityIndex + 1].entity.entity_type)) + ' &#8594;</button>';
        html += '</div>';
        area.innerHTML = html;
    }

    function renderEntityProgressBanner(phase) {
        var total = entityStates.length; if (total <= 1 && phase !== 'complete') return '';
        var current = currentEntityIndex + 1, entityName = formatEntityName(curEntity().entity_type);
        var html = '<div class="mapping-progress-banner"><div class="progress-banner-top">';
        for (var i = 0; i < total; i++) {
            var dotClass = 'progress-dot';
            if (i < currentEntityIndex || (i === currentEntityIndex && phase === 'complete')) dotClass += ' progress-dot-done';
            else if (i === currentEntityIndex) dotClass += ' progress-dot-active';
            html += '<span class="' + dotClass + '" title="' + escapeHtml(formatEntityName(entityStates[i].entity.entity_type)) + '">' + (i + 1) + '</span>';
            if (i < total - 1) html += '<span class="progress-dot-line' + (i < currentEntityIndex ? ' progress-dot-line-done' : '') + '"></span>';
        }
        html += '</div>';
        if (phase === 'mapping') html += '<div class="progress-banner-label">Mapping ' + current + ' of ' + total + ': <strong>' + escapeHtml(entityName) + '</strong></div>';
        else if (phase === 'validating') html += '<div class="progress-banner-label">Validating ' + current + ' of ' + total + ': <strong>' + escapeHtml(entityName) + '</strong></div>';
        else if (phase === 'complete') html += '<div class="progress-banner-label">Complete ' + current + ' of ' + total + ': <strong>' + escapeHtml(entityName) + '</strong> &#10003;</div>';
        html += '</div>';
        return html;
    }

    function validateCurrentEntity() {
        var state = curState();
        if (!state || (Object.keys(state.columnMapping).length === 0 && (!state.fieldAssignments || Object.keys(state.fieldAssignments).length === 0))) return;
        var mappingUnchanged = state.stagingContext && state.stagedMapping && mappingsAreEqual(state.columnMapping, state.stagedMapping);
        if (mappingUnchanged && state.assignments && state.assignments.length > 0) {
            var currentAssignmentsJson = JSON.stringify(state.assignments.map(function (a) { return { mode: a.mode, fixedValues: a.fixedValues, triggerColumn: a.triggerColumn, conditionalField: a.conditionalField, valueMap: a.valueMap, sharedFields: a.sharedFields, fileColumn: a.fileColumn }; }));
            mappingUnchanged = state.stagedAssignments === currentAssignmentsJson;
        }
        if (mappingUnchanged && state.fieldAssignments) {
            var currentFAJson = JSON.stringify(state.fieldAssignments);
            mappingUnchanged = state.stagedFieldAssignments === currentFAJson;
        }
        if (mappingUnchanged) { runEntityValidation(state); }
        else if (state.stagingContext) { var oldTable = state.stagingContext.staging_table; state.stagingContext = null; state.stagedMapping = null; state.stagedAssignments = null; state.stagedFieldAssignments = null; stageEntityData(state, function () { runEntityValidation(state); }, oldTable); }
        else { stageEntityData(state, function () { runEntityValidation(state); }); }
    }

    function stageEntityData(state, onComplete, dropExistingTable) {
        var area = document.getElementById('map-validate-area');
        area.innerHTML = renderEntityProgressBanner('validating') + '<div class="loading">' + (dropExistingTable ? 'Mapping changed — re-staging data...' : 'Reading full file and staging...') + '</div>';
        var ext = '.' + uploadedFile.name.split('.').pop().toLowerCase();
        var reader = new FileReader();
        reader.onload = function (e) {
            var allRows;
            try { if (ext === '.csv' || ext === '.txt') allRows = parseCSVAllRows(e.target.result); else allRows = parseExcelAllRows(e.target.result); }
            catch (err) { area.innerHTML = renderEntityProgressBanner('validating') + '<div class="placeholder-message" style="color:#f48771;">Failed to read file: ' + err.message + '</div>'; return; }
            area.innerHTML = renderEntityProgressBanner('validating') + '<div class="loading">Staging ' + allRows.length.toLocaleString() + ' rows for ' + formatEntityName(state.entity.entity_type) + '...</div>';
            var fileMapping = {};
            Object.keys(state.columnMapping).forEach(function (k) { if (k.indexOf('__fixed__') !== 0) fileMapping[k] = state.columnMapping[k]; });
            var stageBody = { entity_type: state.entity.entity_type, config_id: selectedEnvironment.config_id, mapping: fileMapping, headers: parsedFileData.headers, rows: allRows };
            if (state.assignments && state.assignments.length > 0) {
                stageBody.assignments = state.assignments.map(function (a) {
                    return { mode: a.mode, fixed_values: a.fixedValues || {}, trigger_column: a.triggerColumn, conditional_field: a.conditionalField, value_map: a.valueMap || {}, shared_fields: a.sharedFields || {}, file_column: a.fileColumn || null };
                });
            } else {
                var fixedValues = {};
                Object.keys(state.columnMapping).forEach(function (k) { if (k.indexOf('__fixed__') === 0) fixedValues[k.replace('__fixed__', '')] = state.columnMapping[k]; });
                if (Object.keys(fixedValues).length > 0) stageBody.fixed_values = fixedValues;
            }
            if (state.fieldAssignments && Object.keys(state.fieldAssignments).length > 0) {
                var faPayload = {};
                Object.keys(state.fieldAssignments).forEach(function (elemName) {
                    var fa = state.fieldAssignments[elemName];
                    faPayload[elemName] = { mode: fa.mode, value: fa.value || '', trigger_column: fa.triggerColumn, value_map: fa.valueMap || {} };
                });
                stageBody.field_assignments = faPayload;
            }
            if (dropExistingTable) stageBody.drop_existing = dropExistingTable;
            fetch('/api/bdl-import/stage', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(stageBody) })
            .then(function (r) { if (!r.ok) return r.json().then(function (d) { throw new Error(d.error || 'HTTP ' + r.status); }); return r.json(); })
            .then(function (data) {
                state.stagingContext = { staging_table: data.staging_table, row_count: data.row_count, environment: data.environment, required_extra_fields: data.required_extra_fields || [] };
                state.stagedMapping = JSON.parse(JSON.stringify(state.columnMapping));
                if (state.assignments && state.assignments.length > 0) {
                    state.stagedAssignments = JSON.stringify(state.assignments.map(function (a) { return { mode: a.mode, fixedValues: a.fixedValues, triggerColumn: a.triggerColumn, conditionalField: a.conditionalField, valueMap: a.valueMap, sharedFields: a.sharedFields, fileColumn: a.fileColumn }; }));
                }
                if (state.fieldAssignments && Object.keys(state.fieldAssignments).length > 0) {
                    state.stagedFieldAssignments = JSON.stringify(state.fieldAssignments);
                }
                if (onComplete) onComplete();
            })
            .catch(function (err) { area.innerHTML = renderEntityProgressBanner('validating') + '<div class="placeholder-message" style="color:#f48771;">Staging failed: ' + err.message + '</div>'; });
        };
        if (ext === '.csv' || ext === '.txt') reader.readAsText(uploadedFile); else reader.readAsArrayBuffer(uploadedFile);
    }

    function runEntityValidation(state) {
        var area = document.getElementById('map-validate-area');
        area.innerHTML = renderEntityProgressBanner('validating') + '<div class="loading">Validating ' + formatEntityName(state.entity.entity_type) + ' against ' + state.stagingContext.environment + '...</div>';
        revalidating = true;
        fetch('/api/bdl-import/validate', { method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ staging_table: state.stagingContext.staging_table, entity_type: state.entity.entity_type, config_id: selectedEnvironment.config_id }) })
        .then(function (r) { if (!r.ok) return r.json().then(function (d) { throw new Error(d.error || 'HTTP ' + r.status); }); return r.json(); })
        .then(function (serverData) {
            revalidating = false;
            serverData.staging_table = state.stagingContext.staging_table;
            var warnings = validateStagedRows(serverData, state);
            state.validationResult = { warnings: warnings, serverData: serverData };
            if (serverData.row_count !== undefined) state.stagingContext.row_count = serverData.row_count;
            if (serverData.skipped_count !== undefined) state.stagingContext.skipped_count = serverData.skipped_count;
            var hasActionable = warnings.some(function (w) { return w.type === 'required_empty' || w.type === 'lookup_invalid'; });
            state.validated = !hasActionable;
            if (state.validated && entityStates.length > 1 && currentEntityIndex < entityStates.length - 1) { showEntityTransition(state.entity.entity_type, entityStates[currentEntityIndex + 1].entity.entity_type); }
            else { renderMapValidatePanel(); }
        })
        .catch(function (err) { revalidating = false; area.innerHTML = renderEntityProgressBanner('validating') + '<div class="placeholder-message" style="color:#f48771;">Validation failed: ' + err.message + '</div>'; });
    }

    function showEntityTransition(completedType, nextType) {
        var existing = document.getElementById('entity-transition-modal'); if (existing) existing.remove();
        var modal = document.createElement('div'); modal.id = 'entity-transition-modal'; modal.className = 'xf-modal-overlay';
        modal.innerHTML = '<div class="xf-modal"><div class="xf-modal-header"><span class="xf-modal-icon" style="color:#4ec9b0">&#10003;</span><span>' + escapeHtml(formatEntityName(completedType)) + ' Complete</span></div><div class="xf-modal-body"><p>Mapping and validation passed.</p><p>Moving to <strong>' + escapeHtml(formatEntityName(nextType)) + '</strong>...</p></div></div>';
        document.body.appendChild(modal);
        setTimeout(function () { modal.remove(); renderMapValidatePanel(); }, 1500);
    }

    function advanceToNextEntity() {
        if (currentEntityIndex >= entityStates.length - 1) return;
        var state = curState();
        if (state && state.nullifyFields && state.nullifyFields.length > 0 && state.stagingContext) {
            persistNullifyFields(state, function () {
                currentEntityIndex++;
                loadCurrentEntityFields(function () { loadTemplates(curEntity().entity_type); renderMapValidatePanel(); });
            });
        } else {
            currentEntityIndex++;
            loadCurrentEntityFields(function () { loadTemplates(curEntity().entity_type); renderMapValidatePanel(); });
        }
    }

    function revalidateCurrentEntity() {
        var state = curState(); if (!state) return;
        state.validated = false; state.validationResult = null;
        renderMapValidateMapping(document.getElementById('map-validate-area'), state);
    }

    function updateStep4Completion() { var allDone = entityStates.length > 0 && entityStates.every(function (s) { return s.validated; }); stepComplete[3] = allDone; updateStepperUI(); }

    function mappingsAreEqual(a, b) { if (!a || !b) return false; var aKeys = Object.keys(a).sort(), bKeys = Object.keys(b).sort(); if (aKeys.length !== bKeys.length) return false; for (var i = 0; i < aKeys.length; i++) { if (aKeys[i] !== bKeys[i] || a[aKeys[i]] !== b[bKeys[i]]) return false; } return true; }

    // ── Nullify Fields (in mapping step) ─────────────────────────────────
    function nullifyField(elementName) {
        var state = curState(); if (!state) return;
        if (!state.nullifyFields) state.nullifyFields = [];
        if (state.nullifyFields.indexOf(elementName) === -1) { state.nullifyFields.push(elementName); }
        refreshMappingPanels();
    }
    function unnullifyField(elementName) {
        var state = curState(); if (!state || !state.nullifyFields) return;
        var idx = state.nullifyFields.indexOf(elementName);
        if (idx !== -1) state.nullifyFields.splice(idx, 1);
        refreshMappingPanels();
    }
    function persistNullifyFields(state, callback) {
        if (!state || !state.stagingContext || !state.nullifyFields || state.nullifyFields.length === 0) { if (callback) callback(); return; }
        fetch('/api/bdl-import/set-nullify-fields', { method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ staging_table: state.stagingContext.staging_table, nullify_fields: state.nullifyFields }) })
        .then(function (r) { if (!r.ok) return r.json().then(function (d) { throw new Error(d.error || 'HTTP ' + r.status); }); return r.json(); })
        .then(function () { if (callback) callback(); })
        .catch(function (err) { console.error('Failed to persist nullify fields:', err); if (callback) callback(); });
    }

    // ── Mapping Panel Internals ──────────────────────────────────────────
    function refreshMappingPanels() {
        var area = document.getElementById('map-validate-area');
        var state = curState(); if (!state) return;
        var mf = area._mappableFields, columnMapping = state.columnMapping;
        var nullified = state.nullifyFields || [];
        var canEntityNullify = !!state.entity.has_nullify_fields;
        var fieldAssigned = state.fieldAssignments || {};
        var idColIdx = null;
        var idSel = document.getElementById('identifier-column'); if (idSel && idSel.value !== '') idColIdx = parseInt(idSel.value);
        var mSrc = Object.keys(columnMapping), mTgt = Object.values(columnMapping);

        // Source columns
        var srcList = document.getElementById('source-list'), srcH = '';
        parsedFileData.headers.forEach(function (header, idx) {
            if (idx === idColIdx || mSrc.indexOf(header) !== -1) return;
            var sample = (parsedFileData.rows[0] && parsedFileData.rows[0][idx]) ? parsedFileData.rows[0][idx] : ''; if (sample.length > 30) sample = sample.substring(0, 27) + '...';
            var selCls = (area._selectedSource === header) ? ' selected' : '';
            srcH += '<div class="mapping-chip source-chip' + selCls + '" draggable="true" data-source="' + escapeHtml(header) + '" data-idx="' + idx + '" ondragstart="BDL.chipDragStart(event)" onclick="BDL.sourceClick(\'' + escapeHtml(header).replace(/'/g, "\\'") + '\')">';
            srcH += '<div class="chip-name">' + escapeHtml(header) + '</div>'; if (sample) srcH += '<div class="chip-sample">' + escapeHtml(sample) + '</div>'; srcH += '</div>';
        }); srcList.innerHTML = srcH || '<div class="panel-empty">All columns mapped</div>';

        // Target BDL fields (exclude mapped, nullified, and field-assigned)
        var tgtList = document.getElementById('target-list'), tgtH = '';
        mf.forEach(function (f) {
            if (mTgt.indexOf(f.element_name) !== -1) return;
            if (nullified.indexOf(f.element_name) !== -1) return;
            if (fieldAssigned[f.element_name]) return;
            var rc = f.is_import_required ? ' chip-required' : '';
            var canNullify = canEntityNullify && !f.is_not_nullifiable && !f.is_import_required && !f.is_conditional_eligible;
            var isConditionalEligible = !!f.is_conditional_eligible;
            tgtH += '<div class="mapping-chip target-chip' + rc + '" data-element="' + f.element_name + '" ondragover="BDL.chipDragOver(event)" ondrop="BDL.chipDrop(event)" onclick="BDL.targetClick(\'' + f.element_name + '\')">';
            if (hasDisplayName(f)) { tgtH += '<div class="chip-name">' + escapeHtml(f.display_name) + '</div><div class="chip-element">' + f.element_name + '</div>'; }
            else { tgtH += '<div class="chip-name chip-name-technical">' + f.element_name + '</div>'; }
            if (f.field_description) tgtH += '<div class="chip-desc">' + escapeHtml(f.field_description.substring(0, 80)) + '</div>';
            if (f.import_guidance) tgtH += '<div class="chip-guidance">' + escapeHtml(f.import_guidance) + '</div>';
            var meta = buildFieldMeta(f); if (meta) tgtH += '<div class="chip-meta">' + meta + '</div>';
            if (isConditionalEligible) {
                var safeElem = f.element_name.replace(/'/g, "\\'");
                tgtH += '<div class="field-mode-toggle">';
                tgtH += '<span class="field-mode-btn field-mode-active-file" title="Map from file column (drag & drop)">File</span>';
                tgtH += '<span class="field-mode-btn" onclick="event.stopPropagation(); BDL.toggleFieldMode(\'' + safeElem + '\',\'blanket\')" title="Set one value for all rows">Blanket</span>';
                tgtH += '<span class="field-mode-btn" onclick="event.stopPropagation(); BDL.toggleFieldMode(\'' + safeElem + '\',\'conditional\')" title="Vary by trigger column">Cond</span>';
                tgtH += '</div>';
            } else if (canNullify) {
                tgtH += '<span class="chip-nullify-btn" onclick="event.stopPropagation(); BDL.nullifyField(\'' + f.element_name + '\')" title="Nullify this field in DM">&#8709;</span>';
            }
            tgtH += '</div>';
        }); tgtList.innerHTML = tgtH || '<div class="panel-empty">All fields mapped</div>';

        // Mapped section — file mappings + nullified fields
        var mapList = document.getElementById('mapped-list'), mapH = '', mKeys = Object.keys(columnMapping);
        if (!mKeys.length && !nullified.length) {
            mapH = '<div class="panel-empty">Click a source column, then click a BDL field to pair them. Or drag and drop.</div>';
        } else {
            mKeys.forEach(function (sc) {
                var te = columnMapping[sc], displayName = getFieldDisplayNameByElement(te);
                mapH += '<div class="mapped-pair"><span class="pair-source">' + escapeHtml(sc) + '</span><span class="pair-arrow">&#8594;</span>';
                if (displayName !== te) mapH += '<span class="pair-target"><span class="pair-display">' + escapeHtml(displayName) + '</span> <span class="pair-element">' + te + '</span></span>';
                else mapH += '<span class="pair-target">' + te + '</span>';
                mapH += '<span class="pair-remove" onclick="BDL.unmapPair(\'' + escapeHtml(sc).replace(/'/g, "\\'") + '\')" title="Remove mapping">&#10005;</span></div>';
            });
            nullified.forEach(function (nf) {
                var displayName = getFieldDisplayNameByElement(nf);
                mapH += '<div class="mapped-pair mapped-pair-nullify"><span class="pair-nullify-label">&#8709; Nullify</span><span class="pair-arrow">&#8594;</span>';
                if (displayName !== nf) mapH += '<span class="pair-target"><span class="pair-display">' + escapeHtml(displayName) + '</span> <span class="pair-element">' + nf + '</span></span>';
                else mapH += '<span class="pair-target">' + nf + '</span>';
                mapH += '<span class="pair-remove" onclick="BDL.unnullifyField(\'' + nf + '\')" title="Remove nullification">&#10005;</span></div>';
            });
        }
        mapList.innerHTML = mapH;

        // Field Assignments section (per-field mode overrides)
        renderFieldAssignmentsSection(state);

        checkMappingComplete();
    }

    function buildFieldMeta(f) { var p = []; if (f.data_type) p.push(f.data_type); if (f.max_length) p.push('max ' + f.max_length); if (f.lookup_table) p.push('&#128270; ' + f.lookup_table); if (f.is_import_required) p.push('required'); return p.join(' \u00b7 '); }
    function isMappingDisabled() { var wrap = document.getElementById('mapping-panels-wrap'); return wrap && wrap.classList.contains('mapping-disabled'); }
    function sourceClick(h) { if (isMappingDisabled()) return; var a = document.getElementById('map-validate-area'); a._selectedSource = (a._selectedSource === h) ? null : h; refreshMappingPanels(); }
    function targetClick(el) { if (isMappingDisabled()) return; var a = document.getElementById('map-validate-area'); if (!a._selectedSource) return; curState().columnMapping[a._selectedSource] = el; a._selectedSource = null; refreshMappingPanels(); }
    function chipDragStart(e) { if (isMappingDisabled()) { e.preventDefault(); return; } var s = e.target.closest('.source-chip'); if (!s) return; e.dataTransfer.setData('text/plain', s.dataset.source); e.dataTransfer.effectAllowed = 'link'; s.classList.add('dragging'); }
    function chipDragOver(e) { if (isMappingDisabled()) return; e.preventDefault(); e.dataTransfer.dropEffect = 'link'; var t = e.target.closest('.target-chip'); if (t) t.classList.add('drag-hover'); }
    function chipDrop(e) { if (isMappingDisabled()) return; e.preventDefault(); var sh = e.dataTransfer.getData('text/plain'), t = e.target.closest('.target-chip'); if (!t || !sh) return; curState().columnMapping[sh] = t.dataset.element; document.getElementById('map-validate-area')._selectedSource = null; refreshMappingPanels(); }
    function unmapPair(sc) { delete curState().columnMapping[sc]; refreshMappingPanels(); }

    function identifierChanged() {
        var a = document.getElementById('map-validate-area'), idSel = document.getElementById('identifier-column'), idElem = a._identifierElementName;
        var cm = curState().columnMapping; for (var k in cm) { if (cm[k] === idElem) delete cm[k]; }
        if (idSel.value !== '') cm[parsedFileData.headers[parseInt(idSel.value)]] = idElem;
        var idSection = document.querySelector('.mapping-identifier'), wrap = document.getElementById('mapping-panels-wrap');
        if (idSel.value !== '') { if (idSection) { idSection.classList.remove('identifier-pending'); idSection.classList.add('identifier-confirmed'); } if (wrap) { wrap.classList.remove('mapping-disabled'); var msg = wrap.querySelector('.mapping-disabled-msg'); if (msg) msg.remove(); } }
        else { if (idSection) { idSection.classList.remove('identifier-confirmed'); idSection.classList.add('identifier-pending'); } if (wrap) wrap.classList.add('mapping-disabled'); }
        refreshMappingPanels();
    }

    function checkMappingComplete() {
        var state = curState(); if (!state) return;
        var area = document.getElementById('map-validate-area');
        var mc = Object.keys(state.columnMapping).length;
        var mf = area ? area._mappableFields || [] : [], idF = area ? area._identifierField : null;
        var allReq = mf.filter(function (f) { return f.is_import_required; }); if (idF) allReq.push(idF);
        var mapped = Object.values(state.columnMapping), unmReq = allReq.filter(function (f) {
            if (mapped.indexOf(f.element_name) !== -1) return false;
            if (state.fieldAssignments && state.fieldAssignments[f.element_name]) return false;
            return true;
        });
        var wd = document.getElementById('mapping-warnings');
        if (wd) {
            if (unmReq.length > 0) wd.innerHTML = '<div class="warning-box"><strong>&#9888; Unmapped required fields:</strong> ' + unmReq.map(function (f) { return '<code>' + getFieldDisplayName(f) + '</code>'; }).join(', ') + '<br><span style="font-size:11px;color:#888;">These will be added to the staging table. You must provide values during validation.</span></div>';
            else if (mc > 0 || (state.fieldAssignments && Object.keys(state.fieldAssignments).length > 0)) wd.innerHTML = '<div class="success-box">&#10003; All required fields mapped</div>';
            else wd.innerHTML = '';
        }
        // Check field assignments are ready
        var fieldAssignmentsReady = true;
        if (state.fieldAssignments) {
            Object.keys(state.fieldAssignments).forEach(function (elemName) {
                var fa = state.fieldAssignments[elemName];
                if (fa.mode === 'blanket') {
                    var field = state.fields ? state.fields.find(function (f) { return f.element_name === elemName; }) : null;
                    if (field && field.is_import_required && !fa.value) fieldAssignmentsReady = false;
                } else if (fa.mode === 'conditional') {
                    if (!fa.triggerColumn || !fa.triggerUniqueValues) { fieldAssignmentsReady = false; return; }
                    var hasMappedValue = Object.keys(fa.valueMap).some(function (k) { return fa.valueMap[k] && fa.valueMap[k].trim() !== ''; });
                    if (!hasMappedValue) fieldAssignmentsReady = false;
                }
            });
        }
        var valBtn = document.getElementById('btn-validate-entity');
        var hasContent = mc > 0 || (state.nullifyFields && state.nullifyFields.length > 0) || (state.fieldAssignments && Object.keys(state.fieldAssignments).length > 0);
        if (valBtn) valBtn.disabled = !hasContent || !fieldAssignmentsReady;
    }

    // ── Validation Logic ─────────────────────────────────────────────────
    function parseCSVAllRows(text) { var lines = text.split(/\r?\n/).filter(function (l) { return l.trim(); }), rows = []; for (var i = 1; i < lines.length; i++) rows.push(parseCSVLine(lines[i])); return rows; }
    function parseExcelAllRows(buffer) { var d = new Uint8Array(buffer), wb = XLSX.read(d, { type: 'array', cellDates: true }), sh = wb.Sheets[wb.SheetNames[0]], range = XLSX.utils.decode_range(sh['!ref']), rows = []; for (var r = 1; r <= range.e.r; r++) { var rd = []; for (var c = range.s.c; c <= range.e.c; c++) { var cell = sh[XLSX.utils.encode_cell({ r: r, c: c })]; rd.push(excelCellValue(cell)); } rows.push(rd); } return rows; }

    function validateStagedRows(serverData, state) {
        var warnings = [], columns = serverData.columns || [], rows = serverData.rows || [];
        var lookups = serverData.lookups || {}, lookupErrors = serverData.lookup_errors || {};
        var entityFields = state.fields, columnMapping = state.columnMapping;
        var fieldMap = {}; entityFields.forEach(function (f) { fieldMap[f.element_name] = f; });
        var colIndex = {}; columns.forEach(function (col, idx) { colIndex[col] = idx; });
        Object.keys(lookupErrors).forEach(function (en) { warnings.push({ type: 'lookup_error', field: en, message: lookupErrors[en], rowCount: 0, samples: [] }); });
        var MAX_SAMPLES = 5;
        columns.forEach(function (colName) {
            var field = fieldMap[colName]; if (!field) return;
            var ci = colIndex[colName];
            var emptyCount = 0, lenErrs = { items: [], total: 0 }, typeErrs = { items: [], total: 0 }, lookupMiss = { total: 0, uv: {} };
            var isReq = field.is_import_required, maxLen = field.max_length, dt = (field.data_type || '').toLowerCase();
            var lookupSet = lookups[colName] ? lookups[colName].values : null, lookupMap = null;
            if (lookupSet) { lookupMap = {}; lookupSet.forEach(function (v) { lookupMap[String(v).toUpperCase()] = true; }); }
            var sourceCol = null; Object.keys(columnMapping).forEach(function (sc) { if (columnMapping[sc] === colName) sourceCol = sc; });
            for (var i = 0; i < rows.length; i++) {
                var val = rows[i][ci]; if (val === undefined || val === null) val = ''; var tr = val.trim();
                if (isReq && tr === '') { emptyCount++; continue; }
                if (tr === '') continue;
                if (maxLen && tr.length > maxLen) { lenErrs.total++; if (lenErrs.items.length < MAX_SAMPLES) lenErrs.items.push({ row: i + 1, value: tr.substring(0, 50), length: tr.length }); }
                if (dt === 'int' || dt === 'long' || dt === 'short') { if (!/^-?\d+$/.test(tr)) { typeErrs.total++; if (typeErrs.items.length < MAX_SAMPLES) typeErrs.items.push({ row: i + 1, value: tr.substring(0, 30) }); } }
                else if (dt === 'decimal') { if (!/^-?\d+(\.\d+)?$/.test(tr)) { typeErrs.total++; if (typeErrs.items.length < MAX_SAMPLES) typeErrs.items.push({ row: i + 1, value: tr.substring(0, 30) }); } }
                else if (dt === 'boolean') { if (['true', 'false', '1', '0', 'yes', 'no'].indexOf(tr.toLowerCase()) === -1) { typeErrs.total++; if (typeErrs.items.length < MAX_SAMPLES) typeErrs.items.push({ row: i + 1, value: tr.substring(0, 30) }); } }
                if (lookupMap && tr !== '') { if (!lookupMap[tr.toUpperCase()]) { var uKey = tr.toUpperCase(); if (!lookupMiss.uv[uKey]) lookupMiss.uv[uKey] = { display: tr, count: 0 }; lookupMiss.uv[uKey].count++; lookupMiss.total++; } }
            }
            if (emptyCount > 0) warnings.push({ type: 'required_empty', field: colName, sourceColumn: sourceCol, message: emptyCount.toLocaleString() + ' row(s) have empty values for required field', rowCount: emptyCount, hasLookup: !!lookupSet, lookupValues: lookupSet, samples: [] });
            if (lenErrs.total > 0) warnings.push({ type: 'max_length', field: colName, sourceColumn: sourceCol, message: lenErrs.total.toLocaleString() + ' row(s) exceed max length of ' + maxLen, rowCount: lenErrs.total, samples: lenErrs.items });
            if (typeErrs.total > 0) warnings.push({ type: 'data_type', field: colName, sourceColumn: sourceCol, message: typeErrs.total.toLocaleString() + ' row(s) have invalid ' + dt + ' values', rowCount: typeErrs.total, samples: typeErrs.items });
            if (lookupMiss.total > 0) { var tRef = lookups[colName] ? lookups[colName].table : ''; warnings.push({ type: 'lookup_invalid', field: colName, sourceColumn: sourceCol, message: lookupMiss.total.toLocaleString() + ' row(s) have values not found in ' + tRef, rowCount: lookupMiss.total, uniqueValues: lookupMiss.uv, samples: [] }); }
        });
        return warnings;
    }

    function buildValidationResultsHtml(warnings, serverData) {
        var html = '', rc = serverData.row_count || 0, skipped = serverData.skipped_count || 0;
        var actionableWarnings = warnings.filter(function (w) { return w.type === 'required_empty' || w.type === 'lookup_invalid'; });
        var infoWarnings = warnings.filter(function (w) { return w.type !== 'required_empty' && w.type !== 'lookup_invalid'; });
        var rowSummary = rc.toLocaleString() + ' rows validated' + (skipped > 0 ? ', ' + skipped.toLocaleString() + ' skipped' : '');
        if (!warnings.length) html += '<div class="validation-summary validation-pass"><span class="validation-icon">&#10003;</span><div><strong>Validation passed</strong><div class="validation-detail">' + rowSummary + '. No issues found.</div></div></div>';
        else if (actionableWarnings.length > 0) html += '<div class="validation-summary validation-block"><span class="validation-icon">&#9888;</span><div><strong>' + actionableWarnings.length + ' issue' + (actionableWarnings.length > 1 ? 's' : '') + ' found</strong><div class="validation-detail">' + rowSummary + '. Resolve issues below.</div></div></div>';
        else html += '<div class="validation-summary validation-warn"><span class="validation-icon">&#9888;</span><div><strong>' + infoWarnings.length + ' warning' + (infoWarnings.length > 1 ? 's' : '') + '</strong><div class="validation-detail">' + rowSummary + '. You may proceed.</div></div></div>';
        if (actionableWarnings.length > 0) { html += '<div class="validation-cards" id="validation-cards">'; var typeLabels = { required_empty: 'Required Value Missing', lookup_invalid: 'Invalid Lookup Value' }; actionableWarnings.forEach(function (w, idx) { var cardId = 'vcard-' + idx, fieldDisplay = getFieldDisplayNameByElement(w.field); html += '<div class="val-card" id="' + cardId + '"><div class="val-card-header" onclick="BDL.toggleValidationCard(\'' + cardId + '\')"><div class="val-card-header-left"><span class="val-card-field">'; if (fieldDisplay !== w.field) html += escapeHtml(fieldDisplay) + ' <code class="val-target">' + w.field + '</code>'; else html += '<code class="val-target">' + w.field + '</code>'; html += '</span><span class="val-badge">' + typeLabels[w.type] + '</span></div><div class="val-card-header-right"><span class="val-card-count">' + w.rowCount.toLocaleString() + ' rows</span><span class="val-card-chevron" id="chevron-' + cardId + '">&#9654;</span></div></div>'; html += '<div class="val-card-body" id="body-' + cardId + '" style="display:none;">'; var guidanceState = curState(), guidanceField = guidanceState && guidanceState.fields ? guidanceState.fields.find(function(gf) { return gf.element_name === w.field; }) : null; if (guidanceField && guidanceField.import_guidance) html += '<div class="val-guidance-tip">' + escapeHtml(guidanceField.import_guidance) + '</div>'; if (w.type === 'required_empty') html += renderRequiredEmptyActions(w); else if (w.type === 'lookup_invalid') html += renderLookupInvalidActions(w, cardId, serverData); html += '</div></div>'; }); html += '</div>'; }
        if (infoWarnings.length > 0) { html += '<div class="validation-info-section"><div class="validation-info-header">Warnings (' + infoWarnings.length + ')</div>'; infoWarnings.forEach(function (w, idx) { var infoId = 'vinfo-' + idx, fieldDisplay = getFieldDisplayNameByElement(w.field); var typeLabel = { max_length: 'Max Length', data_type: 'Data Type', lookup_error: 'Lookup Discovery' }[w.type] || w.type; html += '<div class="val-info-card" id="' + infoId + '"><div class="val-info-header" onclick="BDL.toggleInfoCard(\'' + infoId + '\')"><span class="val-card-field">'; if (fieldDisplay !== w.field) html += escapeHtml(fieldDisplay) + ' <code class="val-target">' + w.field + '</code>'; else html += '<code class="val-target">' + w.field + '</code>'; html += '</span><span class="val-badge val-badge-info">' + typeLabel + '</span><span class="val-card-count">' + w.rowCount.toLocaleString() + ' rows</span><span class="val-info-chevron" id="chevron-' + infoId + '">&#9654;</span></div>'; html += '<div class="val-info-body" id="body-' + infoId + '" style="display:none;"><div class="val-card-message">' + escapeHtml(w.message) + '</div>'; if (w.samples && w.samples.length > 0) { html += '<div class="validation-samples">'; w.samples.forEach(function (s) { html += '<span class="val-sample">Row ' + s.row + ': <code>' + escapeHtml(String(s.value)) + '</code>'; if (s.length) html += ' (' + s.length + ' chars)'; html += '</span>'; }); html += '</div>'; } html += '</div></div>'; }); html += '</div>'; }
        return html;
    }

    function renderRequiredEmptyActions(w) { var sf = w.field.replace(/'/g, "\\'"); var rid = 'fill-' + w.field.replace(/[^a-zA-Z0-9]/g, ''); var state = curState(); var html = '<div class="lookup-replace-table"><div class="lookup-replace-header"><span class="lrh-count">Rows</span><span class="lrh-value">Current</span><span class="lrh-action">Action</span></div>'; html += '<div class="lookup-replace-row" id="row-' + rid + '"><span class="lrr-count">' + w.rowCount.toLocaleString() + '</span><span class="lrr-value"><code>(empty)</code></span><span class="lrr-action">'; if (w.hasLookup && w.lookupValues) { html += '<select id="' + rid + '" class="replace-select"><option value="">— Select value —</option>'; w.lookupValues.forEach(function (v) { html += '<option value="' + escapeHtml(v) + '">' + escapeHtml(v) + '</option>'; }); html += '</select>'; } else { html += '<input type="text" id="' + rid + '" class="replace-input" placeholder="Enter value...">'; } html += ' <button class="replace-btn" onclick="BDL.fillEmpty(\'' + sf + '\',\'' + rid + '\')">Fill</button>'; var fieldObj = state.fields.find(function(ff) { return ff.element_name === w.field; }); if (!fieldObj || !fieldObj.is_not_nullifiable) html += ' <button class="skip-btn" onclick="BDL.skipRows(\'' + sf + '\',\'\',\'row-' + rid + '\')">Skip Rows</button>'; html += '</span></div></div>'; return html; }

    function renderLookupInvalidActions(w, cardId, serverData) { var vv = serverData.lookups && serverData.lookups[w.field] ? serverData.lookups[w.field].values : []; var uniqueKeys = Object.keys(w.uniqueValues); var html = '<div class="lookup-replace-table" data-card="' + cardId + '" data-total-values="' + uniqueKeys.length + '" data-resolved="0">'; html += '<div class="lookup-replace-header"><span class="lrh-count">Count</span><span class="lrh-value">File Value</span><span class="lrh-action">Action</span></div>'; uniqueKeys.forEach(function (key) { var info = w.uniqueValues[key], sf2 = w.field.replace(/'/g, "\\'"), sd = info.display.replace(/'/g, "\\'"); var rid2 = 'replace-' + w.field.replace(/[^a-zA-Z0-9]/g, '') + '-' + key.replace(/[^a-zA-Z0-9]/g, ''); html += '<div class="lookup-replace-row" id="row-' + rid2 + '" data-resolved="false"><span class="lrr-count">' + info.count.toLocaleString() + '</span><span class="lrr-value"><code>' + escapeHtml(info.display) + '</code></span><span class="lrr-action">'; html += '<select id="' + rid2 + '" class="replace-select"><option value="">— Replace with —</option>'; vv.forEach(function (v) { html += '<option value="' + escapeHtml(v) + '">' + escapeHtml(v) + '</option>'; }); html += '</select> <button class="replace-btn" onclick="BDL.applyReplacement(\'' + sf2 + '\',\'' + sd + '\',\'' + rid2 + '\')">Replace</button> <button class="skip-btn" onclick="BDL.skipRows(\'' + sf2 + '\',\'' + sd + '\',\'row-' + rid2 + '\')">Skip</button>'; html += '</span></div>'; }); html += '</div>'; return html; }

    function toggleValidationCard(cardId) { if (revalidating) return; var cards = document.querySelectorAll('.val-card'); cards.forEach(function (card) { var body = document.getElementById('body-' + card.id), chevron = document.getElementById('chevron-' + card.id); if (card.id === cardId) { if (body.style.display === 'none') { body.style.display = 'block'; if (chevron) chevron.innerHTML = '&#9660;'; card.classList.add('val-card-expanded'); } else { body.style.display = 'none'; if (chevron) chevron.innerHTML = '&#9654;'; card.classList.remove('val-card-expanded'); } } else { if (body) body.style.display = 'none'; if (chevron) chevron.innerHTML = '&#9654;'; card.classList.remove('val-card-expanded'); } }); }
    function toggleInfoCard(infoId) { var body = document.getElementById('body-' + infoId), chevron = document.getElementById('chevron-' + infoId); if (!body) return; if (body.style.display === 'none') { body.style.display = 'block'; if (chevron) chevron.innerHTML = '&#9660;'; } else { body.style.display = 'none'; if (chevron) chevron.innerHTML = '&#9654;'; } }
    function checkLookupCardComplete(rowElement) { var table = rowElement.closest('.lookup-replace-table'); if (!table) return; var totalValues = parseInt(table.dataset.totalValues) || 0; var resolvedRows = table.querySelectorAll('.lookup-replace-row[data-resolved="true"]'); table.dataset.resolved = String(resolvedRows.length); if (resolvedRows.length >= totalValues) triggerCascadingRevalidate(); }
    function triggerCascadingRevalidate() { if (revalidating) return; revalidating = true; var area = document.getElementById('map-validate-area'); area.innerHTML = renderEntityProgressBanner('validating') + '<div class="loading">Applying changes and re-validating...</div>'; setTimeout(function () { runEntityValidation(curState()); }, 200); }

    function applyReplacement(field, oldValue, selectId) { if (revalidating) return; var state = curState(); if (!state) return; var sel = document.getElementById(selectId); if (!sel || !sel.value) { showAlert('Please select a replacement value.', { title: 'Selection Required', icon: '&#9432;', iconColor: '#569cd6' }); return; } var newVal = sel.value, btn = sel.parentElement.querySelector('.replace-btn'); if (btn) btn.disabled = true; var skipBtn = sel.parentElement.querySelector('.skip-btn'); if (skipBtn) skipBtn.disabled = true; fetch('/api/bdl-import/replace-values', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ staging_table: state.stagingContext.staging_table, field: field, old_value: oldValue, new_value: newVal }) }).then(function (r) { if (!r.ok) return r.json().then(function (d) { throw new Error(d.error || 'HTTP ' + r.status); }); return r.json(); }).then(function (data) { var row = document.getElementById(selectId).closest('.lookup-replace-row'); if (row) { row.innerHTML = '<span class="lrr-count">' + data.rows_updated + '</span><span class="lrr-value"><code>' + escapeHtml(oldValue) + '</code> &#8594; <code>' + escapeHtml(newVal) + '</code></span><span class="lrr-action replace-done">&#10003; Replaced</span>'; row.dataset.resolved = 'true'; checkLookupCardComplete(row); } }).catch(function (err) { showAlert(err.message, { title: 'Replacement Failed', icon: '&#10005;', iconColor: '#f48771' }); if (btn) btn.disabled = false; if (skipBtn) skipBtn.disabled = false; }); }

    function fillEmpty(field, inputId) { if (revalidating) return; var state = curState(); if (!state) return; var input = document.getElementById(inputId), newVal = input ? input.value : ''; if (!newVal) { showAlert('Please enter or select a value.', { title: 'Value Required', icon: '&#9432;', iconColor: '#569cd6' }); return; } var btn = input.parentElement.querySelector('.replace-btn'); if (btn) btn.disabled = true; var skipBtn = input.parentElement.querySelector('.skip-btn'); if (skipBtn) skipBtn.disabled = true; fetch('/api/bdl-import/replace-values', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ staging_table: state.stagingContext.staging_table, field: field, old_value: '', new_value: newVal }) }).then(function (r) { if (!r.ok) return r.json().then(function (d) { throw new Error(d.error || 'HTTP ' + r.status); }); return r.json(); }).then(function (data) { var row = document.getElementById(inputId).closest('.lookup-replace-row'); if (row) row.innerHTML = '<span class="lrr-count">' + data.rows_updated + '</span><span class="lrr-value"><code>(empty)</code> &#8594; <code>' + escapeHtml(newVal) + '</code></span><span class="lrr-action replace-done">&#10003; Filled</span>'; triggerCascadingRevalidate(); }).catch(function (err) { showAlert(err.message, { title: 'Fill Failed', icon: '&#10005;', iconColor: '#f48771' }); if (btn) btn.disabled = false; if (skipBtn) skipBtn.disabled = false; }); }

    function skipRows(field, value, rowElementId) { if (revalidating) return; var state = curState(); if (!state) return; var rowEl = document.getElementById(rowElementId); if (rowEl) rowEl.querySelectorAll('button').forEach(function (b) { b.disabled = true; }); fetch('/api/bdl-import/skip-rows', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ staging_table: state.stagingContext.staging_table, field: field, value: value }) }).then(function (r) { if (!r.ok) return r.json().then(function (d) { throw new Error(d.error || 'HTTP ' + r.status); }); return r.json(); }).then(function (data) { var row = document.getElementById(rowElementId); if (row) { row.innerHTML = '<span class="lrr-count">' + data.rows_skipped + '</span><span class="lrr-value"><code>' + escapeHtml(value || '(empty)') + '</code></span><span class="lrr-action skip-done">&#10005; Skipped (' + data.rows_skipped + ' rows)</span>'; if (row.dataset.resolved !== undefined) { row.dataset.resolved = 'true'; checkLookupCardComplete(row); } else triggerCascadingRevalidate(); } }).catch(function (err) { showAlert(err.message, { title: 'Skip Failed', icon: '&#10005;', iconColor: '#f48771' }); if (rowEl) rowEl.querySelectorAll('button').forEach(function (b) { b.disabled = false; }); }); }

    // ── Step 5: Execute (Tabbed) ─────────────────────────────────────────
    function renderExecuteReview() {
        var area = document.getElementById('execute-area');
        var envName = selectedEnvironment ? selectedEnvironment.environment : '?';
        clearPromoteState();
        var html = '';
        html += '<div class="execute-ticket"><div class="execute-section-header">Jira Ticket Link <span class="ticket-optional">(optional — applies to all imports)</span></div><div class="ticket-fields"><div class="ticket-field-row"><label class="ticket-label" for="jira-ticket">Ticket</label><input type="text" id="jira-ticket" class="ticket-input" placeholder="SD-1234" oninput="BDL.ticketChanged()"></div><div class="ticket-field-row" id="ar-message-row" style="display:none;"><label class="ticket-label" for="ar-message">AR Message</label><input type="text" id="ar-message" class="ticket-input ticket-message-input" placeholder="Message for DM AR log"></div></div></div>';
        if (entityStates.length > 1) {
            var hasFixedOrHybrid = entityStates.some(function (s) { return s.entity.action_type === 'FIXED_VALUE' || s.entity.action_type === 'HYBRID'; });
            var counts = entityStates.map(function (s) { return s.stagingContext ? s.stagingContext.row_count : 0; });
            var allSame = counts.every(function (c) { return c === counts[0]; });
            if (!allSame && hasFixedOrHybrid) {
                html += '<div class="execute-mismatch-banner"><div class="mismatch-header"><span class="mismatch-icon">&#9888;</span> Row counts differ across entities</div><div class="mismatch-detail">';
                entityStates.forEach(function (s) { html += '<div class="mismatch-entity"><span class="mismatch-name">' + escapeHtml(formatEntityName(s.entity.entity_type)) + '</span><span class="mismatch-counts">' + (s.stagingContext ? s.stagingContext.row_count : 0).toLocaleString() + ' active' + (s.stagingContext && s.stagingContext.skipped_count > 0 ? ', ' + s.stagingContext.skipped_count.toLocaleString() + ' skipped' : '') + '</span></div>'; });
                html += '</div><div class="mismatch-actions"><button class="nav-btn" onclick="BDL.showAlignmentModal()">Align Row Counts</button></div></div>';
            }
        }
        html += '<div class="execute-tabs" id="execute-tabs">'; entityStates.forEach(function (state, idx) { html += '<div class="execute-tab' + (idx === 0 ? ' execute-tab-active' : '') + '" id="exec-tab-' + idx + '" onclick="BDL.switchExecuteTab(' + idx + ')">' + escapeHtml(formatEntityName(state.entity.entity_type)) + '</div>'; }); html += '</div>';
        entityStates.forEach(function (state, idx) {
            var visClass = idx === 0 ? '' : ' hidden';
            var entityName = formatEntityName(state.entity.entity_type);
            var rowCount = state.stagingContext ? state.stagingContext.row_count : 0;
            var skipped = state.stagingContext && state.stagingContext.skipped_count ? state.stagingContext.skipped_count : 0;
            var nullifyCount = state.nullifyFields ? state.nullifyFields.length : 0;
            var faCount = state.fieldAssignments ? Object.keys(state.fieldAssignments).length : 0;
            html += '<div class="execute-tab-content' + visClass + '" id="exec-content-' + idx + '">';
            html += '<div class="execute-summary"><div class="execute-summary-header">' + escapeHtml(entityName) + '</div><div class="execute-summary-grid">';
            html += '<div class="summary-item"><span class="summary-label">Environment</span><span class="summary-value summary-env-' + envName.toLowerCase() + '">' + envName + '</span></div>';
            html += '<div class="summary-item"><span class="summary-label">Entity Type</span><span class="summary-value"><code class="summary-code">' + escapeHtml(state.entity.entity_type) + '</code></span></div>';
            html += '<div class="summary-item"><span class="summary-label">Rows</span><span class="summary-value">' + rowCount.toLocaleString() + (skipped > 0 ? ' <span style="color:#888;font-size:11px;">(' + skipped + ' skipped)</span>' : '') + '</span></div>';
            html += '<div class="summary-item"><span class="summary-label">Staging Table</span><span class="summary-value"><code class="summary-code">' + escapeHtml(state.stagingContext.staging_table) + '</code></span></div>';
            html += '</div></div>';
            var mappingKeys = Object.keys(state.columnMapping);
            if (mappingKeys.length > 0 || faCount > 0) {
                html += '<div class="execute-mapped-summary"><span class="mapped-summary-icon">&#128279;</span> <strong>Mapped Fields:</strong> ';
                var fieldCodes = mappingKeys.map(function (sc) {
                    var te = state.columnMapping[sc];
                    var nfField = state.fields ? state.fields.find(function (f) { return f.element_name === te; }) : null;
                    return '<code>' + escapeHtml(nfField ? getFieldDisplayName(nfField) : te) + '</code>';
                });
                if (state.fieldAssignments) {
                    Object.keys(state.fieldAssignments).forEach(function (elemName) {
                        var fa = state.fieldAssignments[elemName];
                        var fld = state.fields ? state.fields.find(function (f) { return f.element_name === elemName; }) : null;
                        var label = fld ? getFieldDisplayName(fld) : elemName;
                        var modeTag = fa.mode === 'conditional' ? ' <span style="color:#dcdcaa;font-size:10px;">(cond)</span>' : ' <span style="color:#4ec9b0;font-size:10px;">(fixed)</span>';
                        fieldCodes.push('<code>' + escapeHtml(label) + '</code>' + modeTag);
                    });
                }
                html += fieldCodes.join(', ') + '</div>';
            }
            if (nullifyCount > 0) {
                html += '<div class="execute-nullify-summary"><span class="nullify-summary-icon">&#8709;</span> <strong>Nullify:</strong> ';
                html += state.nullifyFields.map(function (nf) { var nfField = state.fields ? state.fields.find(function (f) { return f.element_name === nf; }) : null; return '<code>' + escapeHtml(nfField ? getFieldDisplayName(nfField) : nf) + '</code>'; }).join(', ');
                html += '</div>';
            }
            html += '<div class="execute-preview" id="exec-preview-' + idx + '"><div class="execute-section-header xml-preview-header"><button class="xml-preview-btn" onclick="BDL.previewEntityXml(' + idx + ')">&#128196; Preview XML <span class="section-toggle" id="xml-toggle-' + idx + '">&#9654;</span></button></div><div class="execute-section-body collapsed" id="xml-body-' + idx + '"><div id="xml-content-' + idx + '"></div></div></div></div>';
        });
        html += '<div class="execute-results-all hidden" id="execute-results-all"><div class="execute-results-header">Execution Results</div><div id="execute-results-list"></div></div>';
        html += '<div class="execute-actions" id="execute-actions">'; if (envName === 'PROD') html += '<div class="execute-prod-warning">&#9888; You are about to import into <strong>PRODUCTION</strong>. This action cannot be undone.</div>'; html += '<button class="execute-btn" id="btn-execute-import" onclick="BDL.executeAll()">Submit All (' + entityStates.length + ' BDL' + (entityStates.length > 1 ? 's' : '') + ')</button></div>';
        html += '<div class="execute-progress hidden" id="execute-progress"></div>';
        area.innerHTML = html;
    }

    function switchExecuteTab(idx) { entityStates.forEach(function (_, i) { var tab = document.getElementById('exec-tab-' + i); var content = document.getElementById('exec-content-' + i); if (i === idx) { tab.classList.add('execute-tab-active'); content.classList.remove('hidden'); } else { tab.classList.remove('execute-tab-active'); content.classList.add('hidden'); } }); }

    function previewEntityXml(idx) {
        var body = document.getElementById('xml-body-' + idx), toggle = document.getElementById('xml-toggle-' + idx), state = entityStates[idx];
        if (!body || !state || !state.stagingContext) return;
        if (state.xmlPreviewLoaded) { if (body.classList.contains('collapsed')) { body.classList.remove('collapsed'); if (toggle) toggle.innerHTML = '&#9660;'; } else { body.classList.add('collapsed'); if (toggle) toggle.innerHTML = '&#9654;'; } return; }
        body.classList.remove('collapsed'); if (toggle) toggle.innerHTML = '&#9660;';
        var contentEl = document.getElementById('xml-content-' + idx); if (!contentEl) return;
        contentEl.innerHTML = '<div class="xml-preview-loading">Building XML preview...</div>';
        fetch('/api/bdl-import/build-preview', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ staging_table: state.stagingContext.staging_table, entity_type: state.entity.entity_type, config_id: selectedEnvironment.config_id }) })
        .then(function (r) { if (!r.ok) return r.json().then(function (d) { throw new Error(d.error || 'HTTP ' + r.status); }); return r.json(); })
        .then(function (data) {
            var html = '<div class="xml-preview-header"><span class="xml-filename">' + escapeHtml(data.xml_filename) + '</span><span class="xml-meta">' + data.row_count.toLocaleString() + ' rows';
            if (data.skipped_count > 0) html += ', ' + data.skipped_count.toLocaleString() + ' skipped';
            html += ' &middot; ' + (data.full_size_bytes / 1024).toFixed(1) + ' KB'; if (data.truncated) html += ' (preview truncated)';
            html += '</span><button class="xml-copy-btn" onclick="BDL.copyEntityXml(' + idx + ')" title="Copy XML to clipboard">Copy</button></div>';
            html += '<pre class="xml-preview-code" id="xml-code-' + idx + '">' + highlightXml(data.xml) + '</pre>';
            contentEl.innerHTML = html; contentEl._rawXml = data.xml; state.xmlPreviewLoaded = true;
        }).catch(function (err) { contentEl.innerHTML = '<div class="xml-preview-loading" style="color:#f48771;">Preview failed: ' + escapeHtml(err.message) + '</div>'; });
    }

    function highlightXml(xml) { return escapeHtml(xml).replace(/^(&lt;\?xml.*?\?&gt;)/gm, '<span class="xml-decl">$1</span>').replace(/(&lt;!--.*?--&gt;)/g, '<span class="xml-comment">$1</span>').replace(/(&lt;\/?)([\w:_-]+)/g, '<span class="xml-bracket">$1</span><span class="xml-tag">$2</span>').replace(/(\/?&gt;)/g, '<span class="xml-bracket">$1</span>').replace(/\s([\w:_-]+)(=)(&quot;[^&]*?&quot;)/g, ' <span class="xml-attr-name">$1</span>$2<span class="xml-attr-val">$3</span>'); }

    function copyEntityXml(idx) {
        var contentEl = document.getElementById('xml-content-' + idx); if (!contentEl || !contentEl._rawXml) return;
        var ta = document.createElement('textarea'); ta.value = contentEl._rawXml; ta.style.position = 'fixed'; ta.style.left = '-9999px'; ta.style.top = '-9999px'; document.body.appendChild(ta); ta.focus(); ta.select();
        try { document.execCommand('copy'); var btn = contentEl.querySelector('.xml-copy-btn'); if (btn) { btn.textContent = 'Copied!'; btn.style.color = '#4ec9b0'; btn.style.borderColor = '#4ec9b0'; setTimeout(function () { btn.textContent = 'Copy'; btn.style.color = ''; btn.style.borderColor = ''; }, 2000); } }
        catch (e) { showAlert('Failed to copy to clipboard.', { title: 'Copy Failed', icon: '&#9432;', iconColor: '#569cd6' }); }
        document.body.removeChild(ta);
    }

    // ── Row Count Alignment ──────────────────────────────────────────────
    function getIdentifierColumn() { var firstEntity = entityStates[0]; if (!firstEntity) return 'cnsmr_idntfr_agncy_id'; return firstEntity.entity.entity_key === 'ACCOUNT' ? 'cnsmr_accnt_idntfr_agncy_id' : 'cnsmr_idntfr_agncy_id'; }
    function showAlignmentModal() {
        var existing = document.getElementById('alignment-modal'); if (existing) existing.remove();
        var mappedEntities = entityStates.filter(function (s) { return s.entity.action_type === 'FILE_MAPPED'; });
        var alignableEntities = entityStates.filter(function (s) { return s.entity.action_type === 'FIXED_VALUE' || s.entity.action_type === 'HYBRID'; });
        if (alignableEntities.length === 0 || mappedEntities.length === 0) return;
        var modal = document.createElement('div'); modal.id = 'alignment-modal'; modal.className = 'xf-modal-overlay';
        var bodyHtml = '';
        alignableEntities.forEach(function (s) {
            var entityIdx = entityStates.indexOf(s);
            bodyHtml += '<div class="alignment-row" id="align-row-' + entityIdx + '"><div class="alignment-entity-info"><span class="alignment-entity-name">' + escapeHtml(formatEntityName(s.entity.entity_type)) + '</span><span class="alignment-entity-counts">' + (s.stagingContext ? s.stagingContext.row_count : 0).toLocaleString() + ' active' + (s.stagingContext && s.stagingContext.skipped_count > 0 ? ', ' + s.stagingContext.skipped_count.toLocaleString() + ' skipped' : '') + '</span></div><div class="alignment-select-row"><label class="alignment-label">Align to:</label><select class="alignment-dropdown" id="align-select-' + entityIdx + '"><option value="">Keep all rows</option>';
            mappedEntities.forEach(function (m) { bodyHtml += '<option value="' + entityStates.indexOf(m) + '">' + escapeHtml(formatEntityName(m.entity.entity_type)) + ' (' + (m.stagingContext ? m.stagingContext.row_count : 0).toLocaleString() + ' rows)</option>'; });
            bodyHtml += '</select><button class="skip-btn alignment-undo-btn" id="align-undo-' + entityIdx + '" onclick="BDL.resetAlignment(' + entityIdx + ')" style="display:none;">Undo</button></div></div>';
        });
        modal.innerHTML = '<div class="xf-modal" style="max-width:520px;"><div class="xf-modal-header"><span class="xf-modal-icon" style="color:#dcdcaa">&#9888;</span><span>Align Row Counts</span></div><div class="xf-modal-body"><p style="color:#999;font-size:13px;margin:0 0 14px;">Choose which mapped entity each fixed-value entity should align its row set to.</p>' + bodyHtml + '</div><div class="xf-modal-actions"><button class="xf-modal-btn-cancel" onclick="BDL.closeAlignmentModal()">Cancel</button><button class="xf-modal-btn-primary" onclick="BDL.applyAlignment()">Apply</button></div></div>';
        document.body.appendChild(modal);
    }
    function closeAlignmentModal() { var modal = document.getElementById('alignment-modal'); if (modal) modal.remove(); }
    function applyAlignment() {
        var alignableEntities = entityStates.filter(function (s) { return s.entity.action_type === 'FIXED_VALUE' || s.entity.action_type === 'HYBRID'; });
        var idCol = getIdentifierColumn(), pending = [];
        alignableEntities.forEach(function (s) { var entityIdx = entityStates.indexOf(s); var sel = document.getElementById('align-select-' + entityIdx); if (!sel || sel.value === '') return; var sourceIdx = parseInt(sel.value); var sourceState = entityStates[sourceIdx]; if (!sourceState || !sourceState.stagingContext || !s.stagingContext) return; pending.push({ targetIdx: entityIdx, sourceIdx: sourceIdx, targetTable: s.stagingContext.staging_table, sourceTable: sourceState.stagingContext.staging_table }); });
        if (pending.length === 0) { closeAlignmentModal(); return; }
        var applyBtn = document.querySelector('#alignment-modal .xf-modal-btn-primary'); if (applyBtn) { applyBtn.disabled = true; applyBtn.textContent = 'Aligning...'; }
        var completed = 0;
        pending.forEach(function (item) {
            fetch('/api/bdl-import/align-rows', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ source_table: item.sourceTable, target_table: item.targetTable, identifier_column: idCol }) })
            .then(function (r) { if (!r.ok) return r.json().then(function (d) { throw new Error(d.error || 'HTTP ' + r.status); }); return r.json(); })
            .then(function (data) { entityStates[item.targetIdx].stagingContext.row_count = data.active_count; entityStates[item.targetIdx].stagingContext.skipped_count = data.skipped_count; completed++; if (completed >= pending.length) { closeAlignmentModal(); renderExecuteReview(); } })
            .catch(function (err) { completed++; showAlert('Alignment failed: ' + err.message, { title: 'Alignment Error', icon: '&#10005;', iconColor: '#f48771' }); if (completed >= pending.length) { closeAlignmentModal(); renderExecuteReview(); } });
        });
    }
    function resetAlignment(entityIdx) {
        var state = entityStates[entityIdx]; if (!state || !state.stagingContext) return;
        var undoBtn = document.getElementById('align-undo-' + entityIdx); if (undoBtn) { undoBtn.disabled = true; undoBtn.textContent = 'Resetting...'; }
        fetch('/api/bdl-import/reset-alignment', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ staging_table: state.stagingContext.staging_table }) })
        .then(function (r) { if (!r.ok) return r.json().then(function (d) { throw new Error(d.error || 'HTTP ' + r.status); }); return r.json(); })
        .then(function (data) { state.stagingContext.row_count = data.active_count; state.stagingContext.skipped_count = 0; var row = document.getElementById('align-row-' + entityIdx); if (row) { var countsEl = row.querySelector('.alignment-entity-counts'); if (countsEl) countsEl.textContent = data.active_count.toLocaleString() + ' active'; } var sel = document.getElementById('align-select-' + entityIdx); if (sel) sel.value = ''; if (undoBtn) { undoBtn.style.display = 'none'; undoBtn.disabled = false; undoBtn.textContent = 'Undo'; } })
        .catch(function (err) { showAlert('Reset failed: ' + err.message, { title: 'Reset Error', icon: '&#10005;', iconColor: '#f48771' }); if (undoBtn) { undoBtn.disabled = false; undoBtn.textContent = 'Undo'; } });
    }

    // ── Promote to Production ────────────────────────────────────────────
    function renderPromoteCard(sourceEnv) {
        var resultsPane = document.getElementById('execute-results-all'); if (!resultsPane) return;
        var existing = document.getElementById('promote-area'); if (existing) existing.remove();
        var promoteDiv = document.createElement('div'); promoteDiv.id = 'promote-area'; promoteDiv.className = 'promote-area';
        promoteSecondsRemaining = promoteData.cooldownSeconds; promoteReady = false;
        promoteDiv.innerHTML = '<div class="promote-card" id="promote-card" onclick="BDL.promoteCardClicked()"><div class="promote-card-header"><span class="promote-card-icon">&#9650;</span><span class="promote-card-title">Promote to Production</span></div><div class="promote-card-timer" id="promote-timer">' + formatCountdown(promoteSecondsRemaining) + '</div><div class="promote-card-hint" id="promote-hint">Review your ' + escapeHtml(sourceEnv) + ' results before promoting</div></div>';
        resultsPane.parentNode.insertBefore(promoteDiv, resultsPane.nextSibling); startPromoteCountdown();
    }
    function formatCountdown(seconds) { var m = Math.floor(seconds / 60), s = seconds % 60; return (m > 0 ? m + ':' : '') + (m > 0 && s < 10 ? '0' : '') + s + (m === 0 ? 's' : ''); }
    function startPromoteCountdown() { if (promoteCountdownTimer) clearInterval(promoteCountdownTimer); promoteCountdownTimer = setInterval(function () { promoteSecondsRemaining--; var timerEl = document.getElementById('promote-timer'), hintEl = document.getElementById('promote-hint'), card = document.getElementById('promote-card'); if (promoteSecondsRemaining <= 0) { clearInterval(promoteCountdownTimer); promoteCountdownTimer = null; promoteReady = true; if (timerEl) timerEl.textContent = 'Ready'; if (hintEl) hintEl.textContent = 'Click to promote to Production'; if (card) card.classList.add('promote-ready'); } else { if (timerEl) timerEl.textContent = formatCountdown(promoteSecondsRemaining); } }, 1000); }
    function promoteCardClicked() { if (!promoteReady) { var hintEl = document.getElementById('promote-hint'); if (hintEl) { hintEl.textContent = 'Please verify your results in the lower environment first'; hintEl.classList.add('promote-hint-flash'); setTimeout(function () { hintEl.classList.remove('promote-hint-flash'); }, 1500); } return; } promoteToProduction(); }
    function promoteToProduction() { if (!promoteData || !promoteData.prodConfigId) return; fetch('/api/bdl-import/environments').then(function (r) { return r.json(); }).then(function (data) { var prodEnv = (data.environments || []).find(function (e) { return e.config_id === promoteData.prodConfigId; }); if (!prodEnv) { showAlert('Production environment configuration not found.', { title: 'Promote Error', icon: '&#10005;', iconColor: '#f48771' }); return; } showPromoteProdAdvisory(prodEnv); }).catch(function (err) { showAlert('Failed to load environments: ' + err.message, { title: 'Promote Error', icon: '&#10005;', iconColor: '#f48771' }); }); }
    function showPromoteProdAdvisory(prodEnv) {
        var existing = document.getElementById('prod-advisory-modal'); if (existing) existing.remove();
        var modal = document.createElement('div'); modal.id = 'prod-advisory-modal'; modal.className = 'xf-modal-overlay';
        var entityList = ''; entityStates.forEach(function (s) { entityList += '<div style="font-size:12px;color:#999;margin:2px 0;">' + escapeHtml(formatEntityName(s.entity.entity_type)) + ': ' + s.stagingContext.row_count.toLocaleString() + ' rows</div>'; });
        modal.innerHTML = '<div class="xf-modal"><div class="xf-modal-header"><span class="xf-modal-icon" style="color:#dcdcaa">&#9888;</span><span>Promote to Production</span></div><div class="xf-modal-body"><p>You are about to promote your <strong>' + escapeHtml(promoteData.sourceEnvironment) + '</strong> import to <strong>Production</strong>.</p><p>The same staging data will be submitted to the production environment:</p>' + entityList + '<p style="color:#f48771;font-weight:600;margin-top:12px;">This is a PRODUCTION import and cannot be undone.</p></div><div class="xf-modal-actions"><button class="xf-modal-btn-cancel" id="promote-advisory-back">Cancel</button><button class="xf-modal-btn-primary xf-modal-btn-danger" id="promote-advisory-continue">Promote to Production</button></div></div>';
        document.body.appendChild(modal);
        document.getElementById('promote-advisory-back').onclick = function () { modal.remove(); };
        document.getElementById('promote-advisory-continue').onclick = function () { modal.remove(); selectedEnvironment = prodEnv; stepComplete[4] = false; executeInProgress = false; clearPromoteState(); entityStates.forEach(function (s) { s.xmlPreviewLoaded = false; }); updateEnvBadge(); renderExecuteReview(); };
    }

    function ticketChanged() { var ticketInput = document.getElementById('jira-ticket'); var messageRow = document.getElementById('ar-message-row'); var messageInput = document.getElementById('ar-message'); var ticket = ticketInput ? ticketInput.value.trim() : ''; if (ticket) { messageRow.style.display = ''; if (!messageInput.dataset.userEdited) { messageInput.value = ticket + ': ' + entityStates.map(function (s) { return s.entity.entity_type; }).join(', ') + ' update via BDL Import'; } } else { messageRow.style.display = 'none'; messageInput.value = ''; messageInput.dataset.userEdited = ''; } }

    function executeAll() {
        if (executeInProgress) return;
        var envName = selectedEnvironment.environment, jiraTicket = (document.getElementById('jira-ticket') || {}).value || ''; jiraTicket = jiraTicket.trim(); var count = entityStates.length;
        var bodyHtml = '<p>Submit ' + count + ' BDL import' + (count > 1 ? 's' : '') + ' to <strong class="summary-env-' + envName.toLowerCase() + '">' + envName + '</strong>?</p>'; entityStates.forEach(function (s) { bodyHtml += '<p style="font-size:12px;color:#999;">' + escapeHtml(formatEntityName(s.entity.entity_type)) + ': ' + s.stagingContext.row_count.toLocaleString() + ' rows</p>'; }); if (envName === 'PROD') bodyHtml += '<p style="color:#f48771;font-weight:600;">This is a PRODUCTION import and cannot be undone.</p>';
        showConfirm(bodyHtml, { title: 'Submit BDL Import' + (count > 1 ? 's' : ''), icon: envName === 'PROD' ? '&#9888;' : '&#9654;', iconColor: envName === 'PROD' ? '#f48771' : '#4ec9b0', confirmLabel: 'Submit ' + (count > 1 ? 'All' : 'Import'), cancelLabel: 'Cancel', confirmClass: envName === 'PROD' ? 'xf-modal-btn-danger' : 'xf-modal-btn-primary', html: true }).then(function (confirmed) { if (!confirmed) return; executeInProgress = true; executeResultTracker = []; var execBtn = document.getElementById('btn-execute-import'); if (execBtn) { execBtn.disabled = true; execBtn.textContent = 'Submitting...'; } executeSequential(0, jiraTicket); });
    }

    function executeSequential(idx, jiraTicket) {
        if (idx >= entityStates.length) { var hasSuccess = executeResultTracker.some(function (r) { return r.success; }); if (jiraTicket && hasSuccess) { submitConsolidatedArLog(jiraTicket, function () { finishExecution(); }); } else { finishExecution(); } return; }
        var state = entityStates[idx], tabEl = document.getElementById('exec-tab-' + idx), resultsPane = document.getElementById('execute-results-all'), resultsList = document.getElementById('execute-results-list');
        switchExecuteTab(idx);
        if (tabEl) tabEl.innerHTML = escapeHtml(formatEntityName(state.entity.entity_type)) + ' <span style="color:#dcdcaa;">&#8943;</span>';
        if (resultsPane) resultsPane.classList.remove('hidden');
        var entityName = formatEntityName(state.entity.entity_type);
        fetch('/api/bdl-import/execute', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ staging_table: state.stagingContext.staging_table, entity_type: state.entity.entity_type, config_id: selectedEnvironment.config_id, source_filename: uploadedFile ? uploadedFile.name : 'unknown', column_mapping: JSON.stringify(state.columnMapping) }) })
        .then(function (r) { return r.json().then(function (d) { d._httpStatus = r.status; return d; }); })
        .then(function (data) {
            var rh = '';
            if (data._httpStatus >= 400 || data.error) {
                rh += '<div class="execute-result-fail"><span class="result-icon">&#10006;</span><div><strong>' + escapeHtml(entityName) + ' — Failed</strong><div class="result-detail">' + escapeHtml(data.error) + '</div>' + (data.log_id ? '<div class="result-meta">Log ID: ' + data.log_id + '</div>' : '') + '</div></div>';
                if (tabEl) tabEl.innerHTML = escapeHtml(entityName) + ' <span style="color:#ef4444;">&#10006;</span>';
                executeResultTracker.push({ entity_type: state.entity.entity_type, staging_table: state.stagingContext.staging_table, log_id: data.log_id || null, success: false });
            } else {
                rh += '<div class="execute-result-success"><span class="result-icon">&#10003;</span><div><strong>' + escapeHtml(entityName) + ' — Submitted</strong><div class="result-meta">File: <code>' + escapeHtml(data.xml_filename) + '</code> &middot; Registry ID: ' + data.file_registry_id + ' &middot; ' + data.row_count.toLocaleString() + ' rows</div></div></div>';
                if (tabEl) tabEl.innerHTML = escapeHtml(entityName) + ' <span style="color:#4ec9b0;">&#10003;</span>';
                executeResultTracker.push({ entity_type: state.entity.entity_type, staging_table: state.stagingContext.staging_table, log_id: data.log_id, success: true });
                if (!promoteData && data.promote_cooldown_seconds && data.prod_config_id) { promoteData = { cooldownSeconds: data.promote_cooldown_seconds, prodConfigId: data.prod_config_id, sourceEnvironment: selectedEnvironment.environment }; }
            }
            if (resultsList) resultsList.innerHTML += rh;
            executeSequential(idx + 1, jiraTicket);
        })
        .catch(function (err) {
            if (resultsList) resultsList.innerHTML += '<div class="execute-result-fail"><span class="result-icon">&#10006;</span><div><strong>' + escapeHtml(entityName) + ' — Request Failed</strong><div class="result-detail">' + escapeHtml(err.message) + '</div></div></div>';
            if (tabEl) tabEl.innerHTML = escapeHtml(entityName) + ' <span style="color:#ef4444;">&#10006;</span>';
            executeResultTracker.push({ entity_type: state.entity.entity_type, staging_table: state.stagingContext.staging_table, log_id: null, success: false });
            executeSequential(idx + 1, jiraTicket);
        });
    }

    function submitConsolidatedArLog(jiraTicket, callback) {
        var resultsList = document.getElementById('execute-results-list');
        var successResults = executeResultTracker.filter(function (r) { return r.success; }); if (successResults.length === 0) { callback(); return; }
        var entityTypes = successResults.map(function (r) { return r.entity_type; }).join(',');
        var parentLogIds = successResults.map(function (r) { return r.log_id; }).filter(function (id) { return id; }).join(',');
        var arMessage = (document.getElementById('ar-message') || {}).value || '';
        if (!arMessage.trim()) arMessage = jiraTicket + ': ' + entityTypes + ' update via BDL Import';
        fetch('/api/bdl-import/execute-ar-log', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ staging_table: successResults[0].staging_table, entity_types: entityTypes, jira_ticket: jiraTicket, ar_message: arMessage.trim(), config_id: selectedEnvironment.config_id, source_filename: uploadedFile ? uploadedFile.name : 'unknown', parent_log_ids: parentLogIds }) })
        .then(function (r) { return r.json().then(function (d) { d._httpStatus = r.status; return d; }); })
        .then(function (data) { var rh = data._httpStatus >= 400 || data.error ? '<div class="execute-result-warn execute-result-ar"><span class="result-icon">&#9888;</span><div><strong>AR Log — Failed</strong><div class="result-detail">' + escapeHtml(data.error) + '</div></div></div>' : '<div class="execute-result-success execute-result-ar"><span class="result-icon">&#10003;</span><div><strong>AR Log — Submitted</strong><div class="result-meta">' + data.row_count.toLocaleString() + ' records linked to ' + escapeHtml(jiraTicket) + ' (' + escapeHtml(entityTypes) + ')</div></div></div>'; if (resultsList) resultsList.innerHTML += rh; callback(); })
        .catch(function (err) { if (resultsList) resultsList.innerHTML += '<div class="execute-result-warn execute-result-ar"><span class="result-icon">&#9888;</span><div><strong>AR Log — Request Failed</strong><div class="result-detail">' + escapeHtml(err.message) + '</div></div></div>'; callback(); });
    }

    function finishExecution() { executeInProgress = false; var actions = document.getElementById('execute-actions'); if (actions) actions.classList.add('hidden'); stepComplete[4] = true; updateStepperUI(); updateNavButtons(); if (promoteData && promoteData.cooldownSeconds && promoteData.prodConfigId) renderPromoteCard(promoteData.sourceEnvironment); }

    // ── Templates ─────────────────────────────────────────────────────────
    function loadTemplates(entityType) { entityTemplates = []; var list = document.getElementById('template-list'); if (!list) return; list.innerHTML = '<div class="template-empty">Loading templates...</div>'; fetch('/api/bdl-import/templates?entity_type=' + encodeURIComponent(entityType)).then(function (r) { return r.json(); }).then(function (data) { entityTemplates = data.templates || []; renderTemplateList(); }).catch(function () { list.innerHTML = '<div class="template-empty">Failed to load templates.</div>'; }); }
    function renderTemplateList() { var list = document.getElementById('template-list'); if (!list) return; if (!entityTemplates.length) { list.innerHTML = '<div class="template-empty">No saved templates for this entity type.</div>'; return; } var html = ''; entityTemplates.forEach(function (t) { var mapping = {}; try { mapping = JSON.parse(t.column_mapping); } catch (e) {} var fieldCount = Object.keys(mapping).length; var matchInfo = ''; if (currentStep === 4 && parsedFileData) { var mc = countTemplateMatches(mapping); matchInfo = '<span class="template-match">' + mc + ' of ' + fieldCount + ' fields match</span>'; } var creator = t.created_by || ''; if (creator.indexOf('\\') !== -1) creator = creator.split('\\')[1]; var activeCls = (activeTemplateId === t.template_id) ? ' template-card-active' : ''; html += '<div class="template-card' + activeCls + '" onclick="BDL.previewTemplate(' + t.template_id + ')"><div class="template-card-name">' + escapeHtml(t.template_name) + '</div>'; if (t.description) html += '<div class="template-card-desc">' + escapeHtml(t.description) + '</div>'; html += '<div class="template-card-meta">' + fieldCount + ' fields &middot; ' + escapeHtml(creator) + (matchInfo ? ' &middot; ' + matchInfo : '') + '</div></div>'; }); list.innerHTML = html; }
    function countTemplateMatches(mapping) { if (!parsedFileData) return 0; var count = 0, fh = parsedFileData.headers.map(function (h) { return h.toUpperCase(); }); Object.keys(mapping).forEach(function (sc) { if (fh.indexOf(sc.toUpperCase()) !== -1) count++; }); return count; }
    function updateTemplateSectionState() { var saveArea = document.getElementById('template-save-area'); var state = curState(); if (saveArea) { if (currentStep === 4 && state && Object.keys(state.columnMapping).length > 0) saveArea.classList.remove('hidden'); else saveArea.classList.add('hidden'); } if (entityTemplates.length > 0) renderTemplateList(); }
    function previewTemplate(templateId) { var template = entityTemplates.find(function (t) { return t.template_id === templateId; }); if (!template) return; var mapping = {}; try { mapping = JSON.parse(template.column_mapping); } catch (e) {} var mappingKeys = Object.keys(mapping); var slideout = document.getElementById('template-slideout'), overlay = document.getElementById('template-slideout-overlay'); document.getElementById('template-slideout-title').textContent = template.template_name; var html = '', creator = template.created_by || ''; if (creator.indexOf('\\') !== -1) creator = creator.split('\\')[1]; html += '<div class="slideout-meta">'; if (template.description) html += '<div class="slideout-desc">' + escapeHtml(template.description) + '</div>'; html += '<div class="slideout-creator">Created by <strong>' + escapeHtml(creator) + '</strong></div></div>'; if (parsedFileData && currentStep === 4) { var mc = countTemplateMatches(mapping); var matchClass = (mc === mappingKeys.length) ? 'slideout-match-full' : (mc > 0 ? 'slideout-match-partial' : 'slideout-match-none'); html += '<div class="slideout-match-summary ' + matchClass + '">' + mc + ' of ' + mappingKeys.length + ' mapped columns found in your file</div>'; } html += '<div class="slideout-mappings-header">Column Mappings (' + mappingKeys.length + ')</div><div class="slideout-mappings">'; var fileHeaders = parsedFileData ? parsedFileData.headers.map(function (h) { return h.toUpperCase(); }) : []; mappingKeys.forEach(function (sourceCol) { var elementName = mapping[sourceCol], displayName = getFieldDisplayNameByElement(elementName); var matched = fileHeaders.indexOf(sourceCol.toUpperCase()) !== -1; html += '<div class="slideout-pair' + (parsedFileData ? (matched ? ' slideout-pair-match' : ' slideout-pair-miss') : '') + '"><span class="slideout-pair-source">' + escapeHtml(sourceCol) + '</span><span class="slideout-pair-arrow">&#8594;</span>'; if (displayName !== elementName) html += '<span class="slideout-pair-target">' + escapeHtml(displayName) + ' <code>' + elementName + '</code></span>'; else html += '<span class="slideout-pair-target"><code>' + elementName + '</code></span>'; if (parsedFileData) html += '<span class="slideout-pair-status">' + (matched ? '&#10003;' : '&#10005;') + '</span>'; html += '</div>'; }); html += '</div>'; if (currentStep === 4 && parsedFileData) html += '<div class="slideout-actions"><button class="replace-btn" onclick="BDL.applyTemplate(' + templateId + ')">Apply Template</button></div>'; if (window.isAdmin) html += '<div class="slideout-danger"><button class="slideout-delete-btn" onclick="BDL.deleteTemplate(' + templateId + ')">Delete Template</button></div>'; document.getElementById('template-slideout-body').innerHTML = html; slideout.classList.add('open'); overlay.classList.add('open'); }
    function closeTemplatePreview() { document.getElementById('template-slideout').classList.remove('open'); document.getElementById('template-slideout-overlay').classList.remove('open'); }
    function applyTemplate(templateId) { var template = entityTemplates.find(function (t) { return t.template_id === templateId; }); var state = curState(); if (!template || !parsedFileData || !state) return; var templateMapping = {}; try { templateMapping = JSON.parse(template.column_mapping); } catch (e) { return; } var fileHeaderMap = {}; parsedFileData.headers.forEach(function (h) { fileHeaderMap[h.toUpperCase()] = h; }); state.columnMapping = {}; Object.keys(templateMapping).forEach(function (sourceCol) { var actualHeader = fileHeaderMap[sourceCol.toUpperCase()]; if (actualHeader) state.columnMapping[actualHeader] = templateMapping[sourceCol]; }); activeTemplateId = templateId; closeTemplatePreview(); renderMapValidateMapping(document.getElementById('map-validate-area'), state); renderTemplateList(); }
    function showSaveTemplate() { var state = curState(); if (!state || Object.keys(state.columnMapping).length === 0) return; var modal = document.getElementById('template-modal-overlay'); var nameInput = document.getElementById('save-template-name'), descInput = document.getElementById('save-template-desc'), status = document.getElementById('save-template-status'); nameInput.value = ''; descInput.value = ''; status.classList.add('hidden'); var preview = document.getElementById('save-template-preview'), mKeys = Object.keys(state.columnMapping); var html = '<div class="template-modal-preview-header">' + mKeys.length + ' mapping(s):</div>'; mKeys.forEach(function (sc) { var te = state.columnMapping[sc], dn = getFieldDisplayNameByElement(te); html += '<div class="template-modal-preview-row"><span class="pair-source">' + escapeHtml(sc) + '</span><span class="pair-arrow">&#8594;</span><span class="pair-target">' + (dn !== te ? escapeHtml(dn) + ' <span class="pair-element">' + te + '</span>' : te) + '</span></div>'; }); preview.innerHTML = html; modal.classList.remove('hidden'); nameInput.focus(); }
    function closeSaveTemplate() { document.getElementById('template-modal-overlay').classList.add('hidden'); }
    function saveTemplate() { var state = curState(); if (!state) return; var nameInput = document.getElementById('save-template-name'), descInput = document.getElementById('save-template-desc'), status = document.getElementById('save-template-status'); var name = nameInput.value.trim(); if (!name) { nameInput.focus(); nameInput.style.borderColor = '#f48771'; return; } nameInput.style.borderColor = ''; fetch('/api/bdl-import/templates', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ entity_type: state.entity.entity_type, template_name: name, description: descInput.value.trim() || null, column_mapping: JSON.stringify(state.columnMapping) }) }).then(function (r) { return r.json().then(function (d) { d._httpStatus = r.status; return d; }); }).then(function (data) { if (data._httpStatus >= 400 || data.error) { status.textContent = data.error || 'Failed.'; status.className = 'template-modal-status template-modal-error'; status.classList.remove('hidden'); } else { status.textContent = 'Saved!'; status.className = 'template-modal-status template-modal-success'; status.classList.remove('hidden'); activeTemplateId = data.template_id; setTimeout(function () { closeSaveTemplate(); loadTemplates(state.entity.entity_type); }, 1000); } }).catch(function (err) { status.textContent = 'Error: ' + err.message; status.className = 'template-modal-status template-modal-error'; status.classList.remove('hidden'); }); }
    function deleteTemplate(templateId) { var template = entityTemplates.find(function (t) { return t.template_id === templateId; }); if (!template) return; showConfirm('Delete template "' + template.template_name + '"?', { title: 'Delete Template', icon: '&#128465;', iconColor: '#f48771', confirmLabel: 'Delete', cancelLabel: 'Keep', confirmClass: 'xf-modal-btn-danger' }).then(function (confirmed) { if (!confirmed) return; var state = curState(); fetch('/api/bdl-import/templates/' + templateId, { method: 'DELETE' }).then(function (r) { return r.json(); }).then(function (data) { if (data.success) { if (activeTemplateId === templateId) activeTemplateId = null; closeTemplatePreview(); if (state) loadTemplates(state.entity.entity_type); } else showAlert(data.error || 'Failed.', { title: 'Delete Failed', icon: '&#10005;', iconColor: '#f48771' }); }).catch(function (err) { showAlert(err.message, { title: 'Error', icon: '&#10005;', iconColor: '#f48771' }); }); }); }

// ── Import History Panel ─────────────────────────────────────────────
    function initHistoryPanel() {
        try {
            var savedScope = localStorage.getItem('bdl_history_user_scope');
            if (savedScope === 'me' || savedScope === 'all') historyUserScope = savedScope;
            var savedScopeBtns = document.querySelectorAll('#history-user-toggle .history-toggle-btn');
            savedScopeBtns.forEach(function (btn) {
                if (btn.dataset.scope === historyUserScope) btn.classList.add('history-toggle-active');
                else btn.classList.remove('history-toggle-active');
            });
        } catch (e) { /* ignore */ }
        fetch('/api/config/refresh-interval?page=bdl-import')
            .then(function (r) { return r.ok ? r.json() : null; })
            .then(function (data) { if (data && data.interval && !data.default) historyPollInterval = data.interval; })
            .catch(function () { /* use default */ });
        loadHistory();
        if (midnightCheckTimer) clearInterval(midnightCheckTimer);
        midnightCheckTimer = setInterval(checkMidnightRollover, 60000);
    }

    function loadHistory(silent) {
        var envParam = (historyEnvFilter === 'ALL') ? '' : '&env=' + encodeURIComponent(historyEnvFilter);
        var url = '/api/bdl-import/history?user_scope=' + historyUserScope + envParam;
        var btn = document.getElementById('history-refresh-btn');
        if (btn && !silent) btn.classList.add('spinning');
        var doFetch = (typeof engineFetch === 'function') ? engineFetch(url) : fetch(url).then(function (r) { return r.json(); });
        return Promise.resolve(doFetch)
            .then(function (data) {
                if (!data) return;
                historyData = data;
                historyCurrentUser = data.current_user || null;
                historyAvailableEnvs = data.environments || [];
                if (data.poll_interval_seconds) historyPollInterval = data.poll_interval_seconds;
                historyLastLoadMs = Date.now();
                renderHistoryEnvChips();
                renderHistoryActive();
                renderHistoryTree();
                updateHistoryLastUpdated();
                updateHistoryPollingLifecycle();
            })
            .catch(function (err) {
                var active = document.getElementById('history-active-section');
                if (active) active.innerHTML = '<div class="history-empty" style="color:#f48771;">Failed to load: ' + escapeHtml(err.message) + '</div>';
                var tree = document.getElementById('history-tree'); if (tree) tree.innerHTML = '';
            })
            .then(function () {
                if (btn) setTimeout(function () { btn.classList.remove('spinning'); }, 600);
            });
    }

    function refreshHistory() { loadHistory(false); }

    function renderHistoryEnvChips() {
        var container = document.getElementById('history-env-chips');
        if (!container) return;
        var html = '<span class="history-chip history-chip-env' + (historyEnvFilter === 'ALL' ? ' history-chip-active' : '') + '" data-env="ALL" onclick="BDL.setHistoryEnvFilter(\'ALL\')">All</span>';
        historyAvailableEnvs.forEach(function (env) {
            var isDisabled = DISABLED_ENVIRONMENTS.indexOf(env) !== -1;
            var activeCls   = (historyEnvFilter === env) ? ' history-chip-active' : '';
            var disabledCls = isDisabled ? ' history-chip-disabled' : '';
            var clickAttr   = isDisabled ? '' : ' onclick="BDL.setHistoryEnvFilter(\'' + escapeHtml(env).replace(/'/g, "\\'") + '\')"';
            html += '<span class="history-chip history-chip-env' + activeCls + disabledCls + '" data-env="' + escapeHtml(env) + '"' + clickAttr + '>' + escapeHtml(env) + '</span>';
        });
        container.innerHTML = html;
    }

    function renderHistoryActive() {
        var container = document.getElementById('history-active-section');
        if (!container || !historyData) return;
        var rows = historyData.active_rows || [];
        var liveIndicator = document.getElementById('history-live-indicator');
        if (rows.length === 0) {
            container.innerHTML = '<div class="history-empty">No active imports</div>';
            if (liveIndicator) liveIndicator.classList.add('hidden');
            return;
        }
        if (liveIndicator) liveIndicator.classList.remove('hidden');
        var html = '<div class="history-active-header"><span class="history-active-label">Active</span><span class="history-active-count">' + rows.length + '</span></div>';
        html += '<div class="history-active-list">';
        rows.forEach(function (r) { html += renderActiveRow(r); });
        html += '</div>';
        container.innerHTML = html;
    }

    function renderActiveRow(r) {
        var envLower = (r.environment || '').toLowerCase();
        var fnShort = shortenFilename(r.source_filename || r.xml_filename || '');
        var entityName = r.entity_type ? formatEntityName(r.entity_type) : '';
        var ageText = formatAge(r.started_dttm || r.created_dttm);
        var status = (r.status || '').toUpperCase();
        var statusBadge = '<span class="history-status-badge history-status-' + escapeHtml(status) + '">' + escapeHtml(status) + '</span>';
        var rowCount = r.total_record_count || r.staging_success_count || 0;
        var tooltip = buildRowTooltip(r);
        var html = '<div class="history-active-row" title="' + escapeHtml(tooltip) + '">';
        html += '<span class="history-active-env env-' + envLower + '">' + escapeHtml(r.environment || '') + '</span>';
        if (entityName) html += '<span class="history-active-entity">' + escapeHtml(entityName) + '</span>';
        html += '<span class="history-active-filename">' + escapeHtml(fnShort) + '</span>';
        html += statusBadge;
        html += '<span class="history-active-meta"><span class="history-active-count">' + rowCount.toLocaleString() + '</span><span class="history-active-age">' + escapeHtml(ageText) + '</span></span>';
        html += '</div>';
        return html;
    }

    function renderHistoryTree() {
        var container = document.getElementById('history-tree');
        if (!container || !historyData) return;
        var years = historyData.years || [];
        if (years.length === 0) { container.innerHTML = '<div class="history-empty">No completed imports</div>'; return; }
        var html = '';
        years.forEach(function (yearObj) {
            var year = yearObj.year;
            var expanded = !!historyExpandedYears[year];
            var iconCls = 'history-year-icon' + (expanded ? ' expanded' : '');
            var contentCls = 'history-year-content' + (expanded ? ' expanded' : '');
            html += '<div class="history-year" data-year="' + year + '">';
            html += '<div class="history-year-header" onclick="BDL.toggleHistoryYear(' + year + ')">';
            html += '<span class="' + iconCls + '">&#9654;</span>';
            html += '<span class="history-year-label">' + year + '</span>';
            html += '<span class="history-year-spacer"></span>';
            html += '<span class="history-year-stat">' + yearObj.total.toLocaleString() + '</span>';
            html += '<span class="history-year-stat success">' + (yearObj.success > 0 ? yearObj.success.toLocaleString() : '') + '</span>';
            html += '<span class="history-year-stat failed">'  + (yearObj.fail    > 0 ? yearObj.fail.toLocaleString()    : '') + '</span>';
            html += '</div>';
            html += '<div class="' + contentCls + '" id="year-content-' + year + '">';
            html += renderYearMonths(yearObj);
            html += '</div></div>';
        });
        container.innerHTML = html;
    }

    function renderYearMonths(yearObj) {
        var months = yearObj.months || [];
        if (months.length === 0) return '';
        var html = '<table class="history-month-table"><tbody>';
        months.forEach(function (m) {
            var expanded = !!historyExpandedMonths[yearObj.year + '-' + m.month];
            var iconCls = 'history-month-icon' + (expanded ? ' expanded' : '');
            var monthName = monthAbbrev(m.month);
            html += '<tr class="history-month-row" onclick="BDL.toggleHistoryMonth(' + yearObj.year + ',' + m.month + ')">';
            html += '<td class="history-month-expand-cell"><span class="' + iconCls + '">&#9654;</span></td>';
            html += '<td class="history-month-name">' + monthName + '</td>';
            html += '<td class="history-month-total">' + m.total.toLocaleString() + '</td>';
            html += '<td class="history-month-success">' + (m.success > 0 ? m.success.toLocaleString() : '') + '</td>';
            html += '<td class="history-month-fail">'    + (m.fail    > 0 ? m.fail.toLocaleString()    : '') + '</td>';
            html += '</tr>';
            html += '<tr class="history-month-details" id="month-details-' + yearObj.year + '-' + m.month + '" style="display:' + (expanded ? 'table-row' : 'none') + ';">';
            html += '<td colspan="5"><div class="history-month-details-content" id="month-content-' + yearObj.year + '-' + m.month + '">';
            if (expanded) html += '<div class="history-month-loading">Loading...</div>';
            html += '</div></td></tr>';
        });
        html += '</tbody></table>';
        return html;
    }

    function toggleHistoryYear(year) {
        historyExpandedYears[year] = !historyExpandedYears[year];
        if (historyExpandedYears[year]) {
            Object.keys(historyExpandedYears).forEach(function (y) { if (parseInt(y) !== year) historyExpandedYears[y] = false; });
        }
        renderHistoryTree();
    }

    function toggleHistoryMonth(year, month) {
        var key = year + '-' + month;
        historyExpandedMonths[key] = !historyExpandedMonths[key];
        if (historyExpandedMonths[key]) {
            Object.keys(historyExpandedMonths).forEach(function (k) {
                if (k !== key && k.indexOf(year + '-') === 0) historyExpandedMonths[k] = false;
            });
        }
        renderHistoryTree();
        if (historyExpandedMonths[key]) loadHistoryMonth(year, month);
    }

    function loadHistoryMonth(year, month) {
        var cacheKey = year + '-' + month + '-' + historyEnvFilter + '-' + historyUserScope;
        var contentEl = document.getElementById('month-content-' + year + '-' + month);
        if (!contentEl) return;
        if (historyMonthCache[cacheKey]) { renderMonthDays(contentEl, historyMonthCache[cacheKey].days, year, month, historyMonthCache[cacheKey].truncated); return; }
        contentEl.innerHTML = '<div class="history-month-loading">Loading...</div>';
        var envParam = (historyEnvFilter === 'ALL') ? '' : '&env=' + encodeURIComponent(historyEnvFilter);
        var url = '/api/bdl-import/history-month?year=' + year + '&month=' + month + '&user_scope=' + historyUserScope + envParam;
        var doFetch = (typeof engineFetch === 'function') ? engineFetch(url) : fetch(url).then(function (r) { return r.json(); });
        Promise.resolve(doFetch)
            .then(function (data) {
                if (!data) { contentEl.innerHTML = '<div class="history-month-loading">Paused</div>'; return; }
                historyMonthCache[cacheKey] = { days: data.days || [], truncated: data.truncated || false };
                renderMonthDays(contentEl, data.days || [], year, month, data.truncated);
            })
            .catch(function (err) {
                contentEl.innerHTML = '<div class="history-month-loading" style="color:#f48771;">Failed: ' + escapeHtml(err.message) + '</div>';
            });
    }

    function renderMonthDays(container, days, year, month, truncated) {
        if (!days || days.length === 0) { container.innerHTML = '<div class="history-month-empty">No imports</div>'; return; }
        var html = '';
        days.forEach(function (d) {
            var dateKey = d.date;
            var expanded = !!historyExpandedDays[dateKey];
            var iconCls = 'history-day-icon' + (expanded ? ' expanded' : '');
            html += '<div class="history-day-row">';
            html += '<div class="history-day-header" onclick="BDL.toggleHistoryDay(\'' + escapeHtml(dateKey).replace(/'/g, "\\'") + '\')">';
            html += '<span class="' + iconCls + '">&#9654;</span>';
            html += '<span class="history-day-label">' + d.day_of_month + '</span>';
            html += '<span class="history-day-dow">' + escapeHtml(d.day_of_week || '') + '</span>';
            html += '<span class="history-day-spacer"></span>';
            html += '<span class="history-day-stat">' + d.total + '</span>';
            html += '<span class="history-day-stat success">' + (d.success > 0 ? d.success : '') + '</span>';
            html += '<span class="history-day-stat failed">'  + (d.fail    > 0 ? d.fail    : '') + '</span>';
            html += '</div>';
            html += '<div class="history-day-imports' + (expanded ? ' expanded' : '') + '" id="day-imports-' + dateKey + '">';
            html += '<div class="history-import-header">';
            html += '<span>Env</span>';
            html += '<span>Entity</span>';
            html += '<span>File</span>';
            html += '<span>Status</span>';
            html += '<span class="history-ih-total">Total</span>';
            html += '<span class="history-ih-succ">Succ</span>';
            html += '<span class="history-ih-fail">Fail</span>';
            html += '<span>User</span>';
            html += '</div>';
            (d.imports || []).forEach(function (imp) { html += renderImportRow(imp); });
            html += '</div></div>';
        });
        if (truncated) html += '<div class="history-month-truncated">Showing first 500 imports for this month &mdash; refine filters to see more</div>';
        container.innerHTML = html;
    }

    function renderImportRow(imp) {
        var envLower = (imp.environment || '').toLowerCase();
        var fnShort = shortenFilename(imp.source_filename || imp.xml_filename || '');
        var entityName = imp.entity_type ? formatEntityName(imp.entity_type) : '';
        var status = (imp.file_registry_status || imp.status || '').toUpperCase();
        var total = imp.total_record_count || imp.staging_success_count || 0;
        var succ  = imp.import_success_count || 0;
        var fail  = imp.import_failed_count  || 0;
        var user = imp.executed_by || '';
        if (user.indexOf('\\') !== -1) user = user.split('\\')[1];
        var tooltip = buildRowTooltip(imp);
        // Column order matches the CSS grid template for .history-import-row:
        //   env | entity | filename | status | total | succ | fail | user
        // Every column is always emitted (possibly empty) so the grid tracks align.
        var userCell = (user && historyUserScope === 'all') ? escapeHtml(user) : '';
        var html = '<div class="history-import-row" title="' + escapeHtml(tooltip) + '">';
        html += '<span class="history-import-env env-' + envLower + '">' + escapeHtml(imp.environment || '') + '</span>';
        html += '<span class="history-import-entity">' + escapeHtml(entityName) + '</span>';
        html += '<span class="history-import-filename">' + escapeHtml(fnShort) + '</span>';
        html += '<span class="history-import-status"><span class="history-status-badge history-status-' + escapeHtml(status) + '">' + escapeHtml(status) + '</span></span>';
        html += '<span class="history-import-count">' + total.toLocaleString() + '</span>';
        html += '<span class="history-import-count-success">' + (succ > 0 ? succ.toLocaleString() : '') + '</span>';
        html += '<span class="history-import-count-fail">'    + (fail > 0 ? fail.toLocaleString() : '') + '</span>';
        html += '<span class="history-import-user">' + userCell + '</span>';
        html += '</div>';
        return html;
    }

    function toggleHistoryDay(dateKey) {
        historyExpandedDays[dateKey] = !historyExpandedDays[dateKey];
        var el = document.getElementById('day-imports-' + dateKey);
        if (el) el.classList.toggle('expanded');
        var dayRow = el ? el.parentElement : null;
        if (dayRow) {
            var icon = dayRow.querySelector('.history-day-icon');
            if (icon) icon.classList.toggle('expanded');
        }
    }

    function setHistoryEnvFilter(env) {
        if (historyEnvFilter === env) return;
        historyEnvFilter = env;
        historyExpandedMonths = {};
        historyExpandedDays = {};
        historyMonthCache = {};
        loadHistory();
    }

    function setHistoryUserScope(scope) {
        if (historyUserScope === scope) return;
        historyUserScope = scope;
        try { localStorage.setItem('bdl_history_user_scope', scope); } catch (e) { /* ignore */ }
        var btns = document.querySelectorAll('#history-user-toggle .history-toggle-btn');
        btns.forEach(function (b) {
            if (b.dataset.scope === scope) b.classList.add('history-toggle-active');
            else b.classList.remove('history-toggle-active');
        });
        historyExpandedMonths = {};
        historyExpandedDays = {};
        historyMonthCache = {};
        loadHistory();
    }

    function updateHistoryLastUpdated() {
        var el = document.getElementById('history-last-updated');
        if (!el) return;
        el.textContent = 'as of ' + formatClockTime(new Date());
    }

    function updateHistoryPollingLifecycle() {
        var hasActive = historyData && historyData.active_rows && historyData.active_rows.length > 0;
        if (hasActive) startHistoryPolling();
        else stopHistoryPolling();
    }

    function startHistoryPolling() {
        if (historyPollTimer) return;
        historyPollTimer = setInterval(function () {
            if (typeof enginePageHidden !== 'undefined' && enginePageHidden) return;
            if (typeof engineSessionExpired !== 'undefined' && engineSessionExpired) { stopHistoryPolling(); return; }
            loadHistory(true);
        }, historyPollInterval * 1000);
    }

    function stopHistoryPolling() {
        if (historyPollTimer) { clearInterval(historyPollTimer); historyPollTimer = null; }
    }

    function checkMidnightRollover() {
        var today = new Date().toDateString();
        if (today !== pageLoadDate) {
            pageLoadDate = today;
            historyMonthCache = {};
            historyExpandedDays = {};
            loadHistory(true);
        }
    }

    // ── History Formatting Helpers ────────────────────────────────────────
    function shortenFilename(fn) {
        if (!fn) return '';
        if (fn.length <= 34) return fn;
        var dot = fn.lastIndexOf('.');
        var ext = dot > 0 ? fn.substring(dot) : '';
        var base = dot > 0 ? fn.substring(0, dot) : fn;
        return base.substring(0, 28) + '\u2026' + ext;
    }
    function formatAge(dttm) {
        if (!dttm) return '';
        var then = new Date(dttm);
        if (isNaN(then.getTime())) return '';
        var secs = Math.floor((Date.now() - then.getTime()) / 1000);
        if (secs < 60) return secs + 's ago';
        if (secs < 3600) return Math.floor(secs / 60) + 'm ago';
        if (secs < 86400) return Math.floor(secs / 3600) + 'h ago';
        return Math.floor(secs / 86400) + 'd ago';
    }
    function formatImportTime(dttm) {
        if (!dttm) return '';
        var d = new Date(dttm);
        if (isNaN(d.getTime())) return '';
        var h = d.getHours(), m = d.getMinutes();
        var ampm = h >= 12 ? 'pm' : 'am';
        h = h % 12; if (h === 0) h = 12;
        return h + ':' + (m < 10 ? '0' : '') + m + ampm;
    }
    function formatClockTime(d) {
        var h = d.getHours(), m = d.getMinutes();
        var ampm = h >= 12 ? 'pm' : 'am';
        h = h % 12; if (h === 0) h = 12;
        return h + ':' + (m < 10 ? '0' : '') + m + ampm;
    }
    function monthAbbrev(month) {
        var names = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
        return names[month - 1] || String(month);
    }
    function buildRowTooltip(r) {
        var parts = [];
        if (r.entity_type) parts.push('Entity: ' + r.entity_type);
        if (r.environment) parts.push('Env: ' + r.environment);
        if (r.status) parts.push('Status: ' + r.status);
        if (r.file_registry_status) parts.push('DM: ' + r.file_registry_status);
        if (r.executed_by) parts.push('User: ' + r.executed_by);
        if (r.started_dttm) parts.push('Started: ' + new Date(r.started_dttm).toLocaleString());
        if (r.completed_dttm) parts.push('Completed: ' + new Date(r.completed_dttm).toLocaleString());
        if (r.error_message) parts.push('Error: ' + r.error_message);
        return parts.join(' | ');
    }

    // ── Reset ─────────────────────────────────────────────────────────────
    function resetFromStep(step) {
        for (var i = step - 1; i < totalSteps; i++) stepComplete[i] = false;
        if (step <= 2) { uploadedFile = null; parsedFileData = null; }
        if (step <= 3) { selectedEntities = []; entityStates = []; currentEntityIndex = 0; entityTemplates = []; activeTemplateId = null; }
        if (step <= 4) { entityStates = []; currentEntityIndex = 0; activeTemplateId = null; }
        executeInProgress = false; executeResultTracker = []; clearPromoteState(); updateStepperUI(); updateNavButtons();
    }
    function clearPromoteState() { if (promoteCountdownTimer) { clearInterval(promoteCountdownTimer); promoteCountdownTimer = null; } promoteData = null; promoteSecondsRemaining = 0; promoteReady = false; }
    function escapeHtml(str) { if (!str) return ''; var d = document.createElement('div'); d.textContent = str; return d.innerHTML; }

    return {
        init: init, goToStep: goToStep, nextStep: nextStep, prevStep: prevStep,
        selectEnvironment: selectEnvironment,
        toggleEntity: toggleEntity, showFieldInfo: showFieldInfo,
        dragOver: dragOver, dragLeave: dragLeave, fileDrop: fileDrop, fileSelected: fileSelected, removeFile: removeFile,
        sourceClick: sourceClick, targetClick: targetClick, chipDragStart: chipDragStart, chipDragOver: chipDragOver, chipDrop: chipDrop,
        unmapPair: unmapPair, identifierChanged: identifierChanged,
        validateCurrentEntity: validateCurrentEntity, advanceToNextEntity: advanceToNextEntity, revalidateCurrentEntity: revalidateCurrentEntity,
        fixedValueIdentifierChanged: fixedValueIdentifierChanged,
        addAssignment: addAssignment, removeAssignment: removeAssignment,
        toggleAssignmentMode: toggleAssignmentMode, showAllTriggerValues: showAllTriggerValues,
        setTriggerColumn: setTriggerColumn, setAssignmentFileColumn: setAssignmentFileColumn,
        assignmentFieldChanged: assignmentFieldChanged, assignmentFieldSearch: assignmentFieldSearch, selectAssignmentValue: selectAssignmentValue,
        sharedFieldChanged: sharedFieldChanged,
        conditionalValueChanged: conditionalValueChanged, conditionalValueSearch: conditionalValueSearch, selectConditionalValue: selectConditionalValue,
        toggleFieldMode: toggleFieldMode, switchFieldMode: switchFieldMode,
        fieldAssignmentValueChanged: fieldAssignmentValueChanged, fieldAssignmentSearch: fieldAssignmentSearch, selectFieldAssignmentValue: selectFieldAssignmentValue,
        setFieldTriggerColumn: setFieldTriggerColumn,
        fieldCondValueChanged: fieldCondValueChanged, fieldCondValueSearch: fieldCondValueSearch, selectFieldCondValue: selectFieldCondValue,
        showAllFieldTriggerValues: showAllFieldTriggerValues,
        nullifyField: nullifyField, unnullifyField: unnullifyField,
        applyReplacement: applyReplacement, fillEmpty: fillEmpty, skipRows: skipRows,
        runCleanup: runCleanup,
        toggleValidationCard: toggleValidationCard, toggleInfoCard: toggleInfoCard,
        switchExecuteTab: switchExecuteTab, executeAll: executeAll,
        ticketChanged: ticketChanged,
        previewEntityXml: previewEntityXml, copyEntityXml: copyEntityXml,
        showAlignmentModal: showAlignmentModal, closeAlignmentModal: closeAlignmentModal, applyAlignment: applyAlignment, resetAlignment: resetAlignment,
        promoteCardClicked: promoteCardClicked,
        previewTemplate: previewTemplate, closeTemplatePreview: closeTemplatePreview,
        applyTemplate: applyTemplate, showSaveTemplate: showSaveTemplate,
        closeSaveTemplate: closeSaveTemplate, saveTemplate: saveTemplate, deleteTemplate: deleteTemplate,
        refreshHistory: refreshHistory,
        setHistoryEnvFilter: setHistoryEnvFilter,
        setHistoryUserScope: setHistoryUserScope,
        toggleHistoryYear: toggleHistoryYear,
        toggleHistoryMonth: toggleHistoryMonth,
        toggleHistoryDay: toggleHistoryDay,
        stopHistoryPolling: stopHistoryPolling
    };
})();

window.onPageResumed = function () { if (window.BDL) BDL.refreshHistory(); };
window.onSessionExpired = function () { if (window.BDL) BDL.stopHistoryPolling(); };

document.addEventListener('DOMContentLoaded', BDL.init);

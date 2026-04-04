/* ============================================================================
   bdl-import.js — BDL Import Wizard
   Location: E:\xFACts-ControlCenter\public\js\bdl-import.js
   Steps: Environment → Entity Type → Upload → Map Columns → Validate → Execute
   Version: Tracked in dbo.System_Metadata (component: ControlCenter.BDLImport)
   ============================================================================ */

var BDL = (function () {
    'use strict';

    var currentStep = 1, totalSteps = 6;
    var stepComplete = [false, false, false, false, false, false];
    var selectedEnvironment = null, selectedEntity = null, entityFields = null, entityWrapper = null;
    var uploadedFile = null, parsedFileData = null, columnMapping = null;
    var validationResult = null, stagingContext = null;
    var stagedMapping = null; // tracks the mapping used when staging was created
    var allEntities = [], MAX_PREVIEW_ROWS = 10;
    var executeInProgress = false;
    var revalidating = false; // prevents interaction during re-validate cycle
    var entityTemplates = []; // cached templates for the selected entity type
    var activeTemplateId = null; // template currently applied to the mapping

    function init() { loadEnvironments(); checkStagingCleanup(); }

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

    function goToStep(step) { if (step > currentStep || (step < currentStep && !stepComplete[step - 1] && step !== currentStep)) return; showStep(step); }
    function nextStep() {
        if (currentStep < totalSteps && stepComplete[currentStep - 1]) {
            if (currentStep === 4) { handleStepFourNext(); return; }
            if (currentStep === 5) { showStep(6); renderExecuteReview(); return; }
            showStep(currentStep + 1);
        }
    }
    function prevStep() { if (currentStep > 1) showStep(currentStep - 1); }

    // ── Step 4 → 5 transition: reuse staging or re-stage ────────────────
    function handleStepFourNext() {
        if (stagingContext && stagedMapping && mappingsAreEqual(columnMapping, stagedMapping)) {
            // Mapping unchanged — reuse existing staging table, just re-validate
            showStep(5);
            runValidation();
        } else if (stagingContext) {
            // Mapping changed — pass old table name so stage endpoint can drop it
            var oldTable = stagingContext.staging_table;
            stagingContext = null;
            stagedMapping = null;
            stageData(function () { runValidation(); }, oldTable);
        } else {
            // No staging yet — first time through
            stageData(function () { runValidation(); });
        }
    }

    function mappingsAreEqual(a, b) {
        if (!a || !b) return false;
        var aKeys = Object.keys(a).sort();
        var bKeys = Object.keys(b).sort();
        if (aKeys.length !== bKeys.length) return false;
        for (var i = 0; i < aKeys.length; i++) {
            if (aKeys[i] !== bKeys[i] || a[aKeys[i]] !== b[bKeys[i]]) return false;
        }
        return true;
    }

    function showStep(step) {
        for (var i = 1; i <= totalSteps; i++) { var p = document.getElementById('panel-' + i), ind = document.getElementById('step-ind-' + i); if (p) p.classList.remove('active'); if (ind) ind.classList.remove('active'); }
        var tp = document.getElementById('panel-' + step), ti = document.getElementById('step-ind-' + step);
        if (tp) tp.classList.add('active'); if (ti) ti.classList.add('active');
        currentStep = step; updateGuidePanel(); updateStepperUI(); updateNavButtons();
        if (step === 2 && allEntities.length === 0) loadEntities();
        if (step === 4 && parsedFileData && entityFields) renderMapping();
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
        for (var g = 1; g <= totalSteps; g++) {
            var gt = document.getElementById('guide-text-' + g);
            if (gt) {
                if (g === currentStep) { gt.classList.remove('hidden'); }
                else { gt.classList.add('hidden'); }
            }
        }
        updateTemplateSectionState();
    }
    function updateNavButtons() {
        var back = document.getElementById('btn-back'), next = document.getElementById('btn-next');
        back.disabled = (currentStep === 1);

        if (currentStep === 6) {
            next.style.display = 'none';
        } else {
            next.style.display = '';
            next.disabled = !stepComplete[currentStep - 1];
            next.innerHTML = 'Next &#8594;';
            next.classList.remove('btn-execute');
            // Next button: muted when disabled, colored when ready to proceed
            if (stepComplete[currentStep - 1]) {
                next.classList.add('btn-next');
            } else {
                next.classList.remove('btn-next');
            }
        }
    }

    // ── Step 1 ───────────────────────────────────────────────────────────
    function loadEnvironments() {
        fetch('/api/bdl-import/environments').then(function (r) { if (!r.ok) throw new Error('HTTP ' + r.status); return r.json(); })
            .then(function (data) { renderEnvironments(data.environments || []); })
            .catch(function (err) { document.getElementById('env-cards').innerHTML = '<div class="placeholder-message" style="color:#f48771;">Failed to load: ' + err.message + '</div>'; });
    }
    function renderEnvironments(envs) {
        var c = document.getElementById('env-cards');
        if (!envs.length) { c.innerHTML = '<div class="placeholder-message">No environments configured.</div>'; return; }
        var h = ''; envs.forEach(function (env) { var locked = (env.environment === 'STAGE'|| env.environment === 'PROD' ); h += '<div class="env-card' + (locked ? ' env-locked' : '') + '" data-env="' + env.environment + '"' + (locked ? '' : ' onclick="BDL.selectEnvironment(this,' + env.config_id + ')"') + '><div class="env-name">' + env.environment + '</div><div class="env-server">' + env.server_name + '</div>' + (locked ? '<div class="env-locked-label">Coming Soon</div>' : '') + '</div>'; });
        c.innerHTML = h; c._envData = envs;
    }
    function selectEnvironment(card, configId) {
        document.querySelectorAll('.env-card').forEach(function (c) { c.classList.remove('selected'); }); card.classList.add('selected');
        selectedEnvironment = (document.getElementById('env-cards')._envData || []).find(function (e) { return e.config_id === configId; });
        stepComplete[0] = true; updateNavButtons(); updateStepperUI(); resetFromStep(2);
    }

    // ── Step 2 ───────────────────────────────────────────────────────────
    function loadEntities() {
        var grid = document.getElementById('entity-grid'); grid.innerHTML = '<div class="loading">Loading entity types...</div>';
        fetch('/api/bdl-import/entities').then(function (r) { if (!r.ok) throw new Error('HTTP ' + r.status); return r.json(); })
            .then(function (data) { allEntities = data.entities || []; renderEntities(allEntities); })
            .catch(function (err) { grid.innerHTML = '<div class="placeholder-message" style="color:#f48771;">Failed to load: ' + err.message + '</div>'; });
    }
    function renderEntities(entities) {
        var grid = document.getElementById('entity-grid');
        if (!entities.length) { grid.innerHTML = '<div class="placeholder-message">No entity types available.</div>'; return; }
        var h = ''; entities.forEach(function (ent) {
            var dn = formatEntityName(ent.entity_type), folder = ent.folder || 'root', sel = (selectedEntity && selectedEntity.entity_type === ent.entity_type) ? ' selected' : '';
            h += '<div class="entity-card' + sel + '" onclick="BDL.selectEntity(\'' + ent.entity_type + '\')"><div class="entity-name">' + dn + '</div><div class="entity-meta"><span class="entity-folder">' + folder + '</span><span class="entity-fields">' + ent.element_count + ' fields</span></div></div>';
        }); grid.innerHTML = h;
    }
    function selectEntity(entityType) {
        selectedEntity = allEntities.find(function (e) { return e.entity_type === entityType; });
        renderEntities(allEntities.filter(function (e) { var s = document.getElementById('entity-search').value.toLowerCase(); if (!s) return true; return e.entity_type.toLowerCase().indexOf(s) !== -1 || (e.folder || '').toLowerCase().indexOf(s) !== -1; }));
        loadEntityFields(entityType); stepComplete[1] = true; updateNavButtons(); updateStepperUI(); resetFromStep(3);
    }
    function loadEntityFields(entityType) {
        fetch('/api/bdl-import/entity-fields?entity_type=' + encodeURIComponent(entityType)).then(function (r) { return r.json(); })
            .then(function (data) { entityFields = data.fields || []; entityWrapper = data.wrapper || []; }).catch(function (err) { console.error('Failed to load entity fields:', err); });
        loadTemplates(entityType);
    }
    function filterEntities(value) {
        var filtered = allEntities.filter(function (e) { if (!value) return true; var s = value.toLowerCase(); return e.entity_type.toLowerCase().indexOf(s) !== -1 || (e.folder || '').toLowerCase().indexOf(s) !== -1 || formatEntityName(e.entity_type).toLowerCase().indexOf(s) !== -1; });
        renderEntities(filtered);
    }
    function formatEntityName(et) { return et.split('_').map(function (w) { return w.charAt(0).toUpperCase() + w.slice(1).toLowerCase(); }).join(' '); }

    // ── Helpers for display names ────────────────────────────────────────
    function getFieldDisplayName(f) {
        return (f.display_name && f.display_name !== '') ? f.display_name : f.element_name;
    }
    function getFieldDisplayNameByElement(elementName) {
        if (!entityFields) return elementName;
        var f = entityFields.find(function (fld) { return fld.element_name === elementName; });
        return f ? getFieldDisplayName(f) : elementName;
    }
    function hasDisplayName(f) {
        return f.display_name && f.display_name !== '';
    }

    // ── Step 3 ───────────────────────────────────────────────────────────
    function dragOver(e) { e.preventDefault(); e.stopPropagation(); document.getElementById('upload-zone').classList.add('drag-over'); }
    function dragLeave(e) { e.preventDefault(); e.stopPropagation(); document.getElementById('upload-zone').classList.remove('drag-over'); }
    function fileDrop(e) { e.preventDefault(); e.stopPropagation(); document.getElementById('upload-zone').classList.remove('drag-over'); if (e.dataTransfer.files.length > 0) handleFile(e.dataTransfer.files[0]); }
    function fileSelected(input) { if (input.files.length > 0) handleFile(input.files[0]); }
    function handleFile(file) {
        var ext = '.' + file.name.split('.').pop().toLowerCase();
        if (['.csv', '.txt', '.xlsx', '.xls'].indexOf(ext) === -1) { alert('Invalid file type.'); return; }
        uploadedFile = file;
        if (ext === '.csv' || ext === '.txt') parseCSVPreview(file); else parseExcelPreview(file);
    }
    function parseCSVPreview(file) {
        var reader = new FileReader(); reader.onload = function (e) {
            var lines = e.target.result.split(/\r?\n/).filter(function (l) { return l.trim(); });
            if (lines.length < 2) { alert('File appears empty.'); return; }
            var headers = parseCSVLine(lines[0]), rows = [];
            for (var i = 1; i <= Math.min(lines.length - 1, MAX_PREVIEW_ROWS); i++) rows.push(parseCSVLine(lines[i]));
            parsedFileData = { headers: headers, rows: rows, rowCount: lines.length - 1 };
            showFileInfo(file, parsedFileData); renderFilePreview(parsedFileData);
            document.getElementById('upload-prompt').style.display = 'none';
            stepComplete[2] = true; updateNavButtons(); updateStepperUI();
        }; reader.readAsText(file);
    }
    function parseCSVLine(line) {
        var result = [], current = '', inQ = false;
        for (var i = 0; i < line.length; i++) { var ch = line[i]; if (inQ) { if (ch === '"' && i + 1 < line.length && line[i + 1] === '"') { current += '"'; i++; } else if (ch === '"') inQ = false; else current += ch; } else { if (ch === '"') inQ = true; else if (ch === ',') { result.push(current.trim()); current = ''; } else current += ch; } }
        result.push(current.trim()); return result;
    }
    function parseExcelPreview(file) {
        var reader = new FileReader(); reader.onload = function (e) {
            try {
                var data = new Uint8Array(e.target.result), wb = XLSX.read(data, { type: 'array' }), sh = wb.Sheets[wb.SheetNames[0]];
                if (!sh['!ref']) { alert('File appears empty.'); return; }
                var range = XLSX.utils.decode_range(sh['!ref']), totalRows = range.e.r;
                if (totalRows < 1) { alert('File has no data rows.'); return; }
                var headers = [];
                for (var col = range.s.c; col <= range.e.c; col++) { var cell = sh[XLSX.utils.encode_cell({ r: 0, c: col })]; headers.push(cell ? String(cell.v) : 'Column ' + (col + 1)); }
                var rows = [];
                for (var row = 1; row <= Math.min(totalRows, MAX_PREVIEW_ROWS); row++) { var rd = []; for (var c = range.s.c; c <= range.e.c; c++) { var dc = sh[XLSX.utils.encode_cell({ r: row, c: c })]; rd.push(dc ? String(dc.v) : ''); } rows.push(rd); }
                parsedFileData = { headers: headers, rows: rows, rowCount: totalRows };
                showFileInfo(file, parsedFileData); renderFilePreview(parsedFileData);
                document.getElementById('upload-prompt').style.display = 'none';
                stepComplete[2] = true; updateNavButtons(); updateStepperUI();
            } catch (err) { alert('Failed to parse Excel file: ' + err.message); }
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
        stepComplete[2] = false; resetFromStep(4); updateNavButtons(); updateStepperUI();
    }

    // ── Step 4 ───────────────────────────────────────────────────────────
    function renderMapping() {
        var area = document.getElementById('mapping-area');
        if (!parsedFileData || !entityFields) { area.innerHTML = '<div class="placeholder-message">Complete previous steps.</div>'; return; }
        var visibleFields = entityFields.filter(function (f) { return f.is_visible !== 0 && f.is_visible !== false; });
        var isAcct = selectedEntity && selectedEntity.folder && selectedEntity.folder.indexOf('account') !== -1;
        var idElemName = isAcct ? 'cnsmr_accnt_idntfr_agncy_id' : 'cnsmr_idntfr_agncy_id';
        var idField = visibleFields.find(function (f) { return f.element_name === idElemName; });
        var mappableFields = visibleFields.filter(function (f) { return f.element_name !== idElemName; });

        // Preserve existing mapping on back navigation — only initialize if null
        if (!columnMapping) { columnMapping = {}; }

        // Check if identifier was previously mapped
        var prevIdIdx = '';
        if (columnMapping) {
            for (var k in columnMapping) {
                if (columnMapping[k] === idElemName) {
                    var hIdx = parsedFileData.headers.indexOf(k);
                    if (hIdx !== -1) prevIdIdx = String(hIdx);
                    break;
                }
            }
        }

        var html = '';
        var idSelected = (prevIdIdx !== '');
        if (idField) {
            var idStateClass = idSelected ? 'identifier-confirmed' : 'identifier-pending';
            html += '<div class="mapping-identifier ' + idStateClass + '"><div class="identifier-label"><span class="identifier-icon">&#128273;</span><strong>Consumer Identifier</strong><span class="identifier-note">Which column contains the DM Agency ID?</span></div><div class="identifier-select"><select id="identifier-column" onchange="BDL.identifierChanged()" class="identifier-dropdown"><option value="">— Select identifier column —</option>';
            parsedFileData.headers.forEach(function (header, idx) { var sample = (parsedFileData.rows[0] && parsedFileData.rows[0][idx]) ? parsedFileData.rows[0][idx] : ''; var sel = (String(idx) === prevIdIdx) ? ' selected' : ''; html += '<option value="' + idx + '"' + sel + '>' + escapeHtml(header + (sample ? '  (' + sample.substring(0, 20) + ')' : '')) + '</option>'; });
            html += '</select><span class="identifier-target">&#8594; <code>' + idField.element_name + '</code></span></div></div>';
        }
        var disabledClass = (idField && !idSelected) ? ' mapping-disabled' : '';
        html += '<div class="mapping-panels-wrap' + disabledClass + '" id="mapping-panels-wrap">';
        if (idField && !idSelected) {
            html += '<div class="mapping-disabled-msg">Select the identifier column above to begin mapping</div>';
        }
        html += '<div class="mapping-panels">';
        html += '<div class="mapping-panel panel-source"><div class="panel-header">Source Columns</div><div class="panel-list" id="source-list"></div></div>';
        html += '<div class="mapping-panel panel-target"><div class="panel-header">BDL Fields</div><div class="panel-list" id="target-list"></div></div>';
        html += '</div>';
        html += '<div class="mapped-section"><div class="panel-header">Mapped</div><div class="mapped-list" id="mapped-list"></div></div>';
        html += '<div id="mapping-warnings" class="mapping-warnings"></div>';
        html += '</div>';
        area.innerHTML = html; area._mappableFields = mappableFields; area._identifierField = idField; area._identifierElementName = idElemName; area._selectedSource = null;
        refreshMappingPanels();
    }
    function refreshMappingPanels() {
        var area = document.getElementById('mapping-area'), mf = area._mappableFields, idColIdx = null;
        var idSel = document.getElementById('identifier-column'); if (idSel && idSel.value !== '') idColIdx = parseInt(idSel.value);
        var mSrc = Object.keys(columnMapping), mTgt = Object.values(columnMapping);
        var srcList = document.getElementById('source-list'), srcH = '';
        parsedFileData.headers.forEach(function (header, idx) {
            if (idx === idColIdx || mSrc.indexOf(header) !== -1) return;
            var sample = (parsedFileData.rows[0] && parsedFileData.rows[0][idx]) ? parsedFileData.rows[0][idx] : ''; if (sample.length > 30) sample = sample.substring(0, 27) + '...';
            var selCls = (area._selectedSource === header) ? ' selected' : '';
            srcH += '<div class="mapping-chip source-chip' + selCls + '" draggable="true" data-source="' + escapeHtml(header) + '" data-idx="' + idx + '" ondragstart="BDL.chipDragStart(event)" onclick="BDL.sourceClick(\'' + escapeHtml(header).replace(/'/g, "\\'") + '\')">';
            srcH += '<div class="chip-name">' + escapeHtml(header) + '</div>'; if (sample) srcH += '<div class="chip-sample">' + escapeHtml(sample) + '</div>'; srcH += '</div>';
        }); srcList.innerHTML = srcH || '<div class="panel-empty">All columns mapped</div>';

        var tgtList = document.getElementById('target-list'), tgtH = '';
        mf.forEach(function (f) {
            if (mTgt.indexOf(f.element_name) !== -1) return;
            var rc = f.is_import_required ? ' chip-required' : '';
            tgtH += '<div class="mapping-chip target-chip' + rc + '" data-element="' + f.element_name + '" ondragover="BDL.chipDragOver(event)" ondrop="BDL.chipDrop(event)" onclick="BDL.targetClick(\'' + f.element_name + '\')">';
            if (hasDisplayName(f)) {
                tgtH += '<div class="chip-name">' + escapeHtml(f.display_name) + '</div>';
                tgtH += '<div class="chip-element">' + f.element_name + '</div>';
            } else {
                tgtH += '<div class="chip-name chip-name-technical">' + f.element_name + '</div>';
            }
            if (f.field_description) tgtH += '<div class="chip-desc">' + escapeHtml(f.field_description.substring(0, 80)) + '</div>';
            var meta = buildFieldMeta(f); if (meta) tgtH += '<div class="chip-meta">' + meta + '</div>'; tgtH += '</div>';
        }); tgtList.innerHTML = tgtH || '<div class="panel-empty">All fields mapped</div>';

        var mapList = document.getElementById('mapped-list'), mapH = '', mKeys = Object.keys(columnMapping);
        if (!mKeys.length) { mapH = '<div class="panel-empty">Click a source column, then click a BDL field to pair them. Or drag and drop between panels.</div>'; }
        else {
            mKeys.forEach(function (sc) {
                var te = columnMapping[sc];
                var displayName = getFieldDisplayNameByElement(te);
                mapH += '<div class="mapped-pair"><span class="pair-source">' + escapeHtml(sc) + '</span><span class="pair-arrow">&#8594;</span>';
                if (displayName !== te) {
                    mapH += '<span class="pair-target"><span class="pair-display">' + escapeHtml(displayName) + '</span> <span class="pair-element">' + te + '</span></span>';
                } else {
                    mapH += '<span class="pair-target">' + te + '</span>';
                }
                mapH += '<span class="pair-remove" onclick="BDL.unmapPair(\'' + escapeHtml(sc).replace(/'/g, "\\'") + '\')" title="Remove mapping">&#10005;</span></div>';
            });
        }
        mapList.innerHTML = mapH; checkMappingComplete();
    }
    function buildFieldMeta(f) { var p = []; if (f.data_type) p.push(f.data_type); if (f.max_length) p.push('max ' + f.max_length); if (f.lookup_table) p.push('&#128270; ' + f.lookup_table); if (f.is_import_required) p.push('required'); return p.join(' \u00b7 '); }
    function isMappingDisabled() { var wrap = document.getElementById('mapping-panels-wrap'); return wrap && wrap.classList.contains('mapping-disabled'); }
    function sourceClick(h) { if (isMappingDisabled()) return; var a = document.getElementById('mapping-area'); a._selectedSource = (a._selectedSource === h) ? null : h; refreshMappingPanels(); }
    function targetClick(el) { if (isMappingDisabled()) return; var a = document.getElementById('mapping-area'); if (!a._selectedSource) return; columnMapping[a._selectedSource] = el; a._selectedSource = null; refreshMappingPanels(); }
    function chipDragStart(e) { if (isMappingDisabled()) { e.preventDefault(); return; } var s = e.target.closest('.source-chip'); if (!s) return; e.dataTransfer.setData('text/plain', s.dataset.source); e.dataTransfer.effectAllowed = 'link'; s.classList.add('dragging'); }
    function chipDragOver(e) { if (isMappingDisabled()) return; e.preventDefault(); e.dataTransfer.dropEffect = 'link'; var t = e.target.closest('.target-chip'); if (t) t.classList.add('drag-hover'); }
    function chipDrop(e) { if (isMappingDisabled()) return; e.preventDefault(); var sh = e.dataTransfer.getData('text/plain'), t = e.target.closest('.target-chip'); if (!t || !sh) return; columnMapping[sh] = t.dataset.element; document.getElementById('mapping-area')._selectedSource = null; refreshMappingPanels(); }
    function unmapPair(sc) { delete columnMapping[sc]; refreshMappingPanels(); }
    function identifierChanged() {
        var a = document.getElementById('mapping-area'), idSel = document.getElementById('identifier-column'), idElem = a._identifierElementName;
        for (var k in columnMapping) { if (columnMapping[k] === idElem) delete columnMapping[k]; }
        if (idSel.value !== '') { columnMapping[parsedFileData.headers[parseInt(idSel.value)]] = idElem; }

        // Update identifier visual state
        var idSection = document.querySelector('.mapping-identifier');
        var wrap = document.getElementById('mapping-panels-wrap');
        if (idSel.value !== '') {
            if (idSection) { idSection.classList.remove('identifier-pending'); idSection.classList.add('identifier-confirmed'); }
            if (wrap) { wrap.classList.remove('mapping-disabled'); var msg = wrap.querySelector('.mapping-disabled-msg'); if (msg) msg.remove(); }
        } else {
            if (idSection) { idSection.classList.remove('identifier-confirmed'); idSection.classList.add('identifier-pending'); }
            if (wrap) { wrap.classList.add('mapping-disabled'); }
        }

        refreshMappingPanels();
    }
    function checkMappingComplete() {
        var mc = Object.keys(columnMapping).length, area = document.getElementById('mapping-area');
        var mf = area ? area._mappableFields || [] : [], idF = area ? area._identifierField : null;
        var allReq = mf.filter(function (f) { return f.is_import_required; }); if (idF) allReq.push(idF);
        var mapped = Object.values(columnMapping), unmReq = allReq.filter(function (f) { return mapped.indexOf(f.element_name) === -1; });
        var wd = document.getElementById('mapping-warnings');
        if (wd) {
            if (unmReq.length > 0) { wd.innerHTML = '<div class="warning-box"><strong>&#9888; Unmapped required fields:</strong> ' + unmReq.map(function (f) { return '<code>' + getFieldDisplayName(f) + '</code>'; }).join(', ') + '<br><span style="font-size:11px;color:#888;">These will be added to the staging table. You must provide values during validation.</span></div>'; }
            else if (mc > 0) { wd.innerHTML = '<div class="success-box">&#10003; All required fields mapped</div>'; }
            else { wd.innerHTML = ''; }
        }
        stepComplete[3] = mc > 0; updateNavButtons(); updateStepperUI();
    }

    // ── Step 5 ───────────────────────────────────────────────────────────

    function stageData(onComplete, dropExistingTable) {
        showStep(5);
        var area = document.getElementById('validation-area');
        area.innerHTML = '<div class="loading">' + (dropExistingTable ? 'Mapping changed — re-staging data...' : 'Reading full file...') + '</div>';
        var ext = '.' + uploadedFile.name.split('.').pop().toLowerCase();
        var reader = new FileReader();
        reader.onload = function (e) {
            var allRows;
            try { if (ext === '.csv' || ext === '.txt') allRows = parseCSVAllRows(e.target.result); else allRows = parseExcelAllRows(e.target.result); }
            catch (err) { area.innerHTML = '<div class="placeholder-message" style="color:#f48771;">Failed to read file: ' + err.message + '</div>'; return; }
            area.innerHTML = '<div class="loading">Staging ' + allRows.length.toLocaleString() + ' rows to server...</div>';
            var stageBody = { entity_type: selectedEntity.entity_type, config_id: selectedEnvironment.config_id, mapping: columnMapping, headers: parsedFileData.headers, rows: allRows };
            if (dropExistingTable) { stageBody.drop_existing = dropExistingTable; }
            fetch('/api/bdl-import/stage', { method: 'POST', headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(stageBody) })
            .then(function (r) { if (!r.ok) return r.json().then(function (d) { throw new Error(d.error || 'HTTP ' + r.status); }); return r.json(); })
            .then(function (data) {
                stagingContext = { staging_table: data.staging_table, row_count: data.row_count, environment: data.environment, required_extra_fields: data.required_extra_fields || [] };
                // Snapshot the mapping used for staging
                stagedMapping = JSON.parse(JSON.stringify(columnMapping));
                if (onComplete) onComplete();
            })
            .catch(function (err) { area.innerHTML = '<div class="placeholder-message" style="color:#f48771;">Staging failed: ' + err.message + '</div>'; });
        };
        if (ext === '.csv' || ext === '.txt') reader.readAsText(uploadedFile); else reader.readAsArrayBuffer(uploadedFile);
    }

    function runValidation() {
        var area = document.getElementById('validation-area');
        area.innerHTML = '<div class="loading">Validating against ' + stagingContext.environment + '...</div>';
        revalidating = true;
        fetch('/api/bdl-import/validate', { method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ staging_table: stagingContext.staging_table, entity_type: selectedEntity.entity_type, config_id: selectedEnvironment.config_id }) })
        .then(function (r) { if (!r.ok) return r.json().then(function (d) { throw new Error(d.error || 'HTTP ' + r.status); }); return r.json(); })
        .then(function (serverData) {
            revalidating = false;
            serverData.staging_table = stagingContext.staging_table;
            var warnings = validateStagedRows(serverData);
            validationResult = { warnings: warnings, serverData: serverData };
            renderValidationResults(warnings, serverData);
            var hasRequiredEmpty = warnings.some(function (w) { return w.type === 'required_empty'; });
            stepComplete[4] = !hasRequiredEmpty;
            updateNavButtons(); updateStepperUI();
        })
        .catch(function (err) {
            revalidating = false;
            area.innerHTML = '<div class="placeholder-message" style="color:#f48771;">Validation failed: ' + err.message + '</div>';
        });
    }

    function parseCSVAllRows(text) { var lines = text.split(/\r?\n/).filter(function (l) { return l.trim(); }), rows = []; for (var i = 1; i < lines.length; i++) rows.push(parseCSVLine(lines[i])); return rows; }
    function parseExcelAllRows(buffer) {
        var d = new Uint8Array(buffer), wb = XLSX.read(d, { type: 'array' }), sh = wb.Sheets[wb.SheetNames[0]], range = XLSX.utils.decode_range(sh['!ref']), rows = [];
        for (var r = 1; r <= range.e.r; r++) { var rd = []; for (var c = range.s.c; c <= range.e.c; c++) { var cell = sh[XLSX.utils.encode_cell({ r: r, c: c })]; rd.push(cell ? String(cell.v) : ''); } rows.push(rd); }
        return rows;
    }

    function validateStagedRows(serverData) {
        var warnings = [], columns = serverData.columns || [], rows = serverData.rows || [];
        var lookups = serverData.lookups || {}, lookupErrors = serverData.lookup_errors || {};
        var fieldMap = {}; entityFields.forEach(function (f) { fieldMap[f.element_name] = f; });
        var colIndex = {}; columns.forEach(function (col, idx) { colIndex[col] = idx; });

        Object.keys(lookupErrors).forEach(function (en) {
            warnings.push({ type: 'lookup_error', field: en, message: lookupErrors[en], rowCount: 0, samples: [] });
        });

        var MAX_SAMPLES = 5;
        columns.forEach(function (colName) {
            var field = fieldMap[colName]; if (!field) return;
            var ci = colIndex[colName];
            var emptyCount = 0, lenErrs = { items: [], total: 0 }, typeErrs = { items: [], total: 0 }, lookupMiss = { total: 0, uv: {} };
            var isReq = field.is_import_required;
            var maxLen = field.max_length, dt = (field.data_type || '').toLowerCase();
            var lookupSet = lookups[colName] ? lookups[colName].values : null, lookupMap = null;
            if (lookupSet) { lookupMap = {}; lookupSet.forEach(function (v) { lookupMap[String(v).toUpperCase()] = true; }); }
            var sourceCol = null;
            Object.keys(columnMapping).forEach(function (sc) { if (columnMapping[sc] === colName) sourceCol = sc; });

            for (var i = 0; i < rows.length; i++) {
                var val = rows[i][ci]; if (val === undefined || val === null) val = '';
                var tr = val.trim();
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

    // ── Validation Results: Accordion Card Rendering ─────────────────────

    function renderValidationResults(warnings, serverData) {
        var area = document.getElementById('validation-area'), html = '';
        var rc = serverData.row_count || 0, skipped = serverData.skipped_count || 0;
        var actionableWarnings = warnings.filter(function (w) { return w.type === 'required_empty' || w.type === 'lookup_invalid'; });
        var infoWarnings = warnings.filter(function (w) { return w.type !== 'required_empty' && w.type !== 'lookup_invalid'; });
        var rowSummary = rc.toLocaleString() + ' rows validated' + (skipped > 0 ? ', ' + skipped.toLocaleString() + ' skipped' : '');

        // Summary banner
        if (!warnings.length) {
            html += '<div class="validation-summary validation-pass"><span class="validation-icon">&#10003;</span><div><strong>Validation passed</strong><div class="validation-detail">' + rowSummary + '. No issues found.</div></div></div>';
        } else if (actionableWarnings.length > 0) {
            html += '<div class="validation-summary validation-block"><span class="validation-icon">&#9888;</span><div><strong>' + actionableWarnings.length + ' issue' + (actionableWarnings.length > 1 ? 's' : '') + ' found during validation</strong><div class="validation-detail">' + rowSummary + '. Click each issue below to review and resolve before proceeding.</div></div></div>';
        } else {
            html += '<div class="validation-summary validation-warn"><span class="validation-icon">&#9888;</span><div><strong>' + infoWarnings.length + ' warning' + (infoWarnings.length > 1 ? 's' : '') + '</strong><div class="validation-detail">' + rowSummary + '. Review warnings below — you may proceed.</div></div></div>';
        }

        // Actionable issue cards (accordion)
        if (actionableWarnings.length > 0) {
            html += '<div class="validation-cards" id="validation-cards">';
            var typeLabels = { required_empty: 'Required Value Missing', lookup_invalid: 'Invalid Lookup Value' };

            actionableWarnings.forEach(function (w, idx) {
                var cardId = 'vcard-' + idx;
                var fieldDisplay = getFieldDisplayNameByElement(w.field);

                html += '<div class="val-card" id="' + cardId + '">';

                // Card header (always visible, clickable)
                html += '<div class="val-card-header" onclick="BDL.toggleValidationCard(\'' + cardId + '\')">';
                html += '<div class="val-card-header-left">';
                html += '<span class="val-card-field">';
                if (fieldDisplay !== w.field) {
                    html += escapeHtml(fieldDisplay) + ' <code class="val-target">' + w.field + '</code>';
                } else {
                    html += '<code class="val-target">' + w.field + '</code>';
                }
                html += '</span>';
                html += '<span class="val-badge">' + typeLabels[w.type] + '</span>';
                html += '</div>';
                html += '<div class="val-card-header-right">';
                html += '<span class="val-card-count">' + w.rowCount.toLocaleString() + ' rows</span>';
                html += '<span class="val-card-chevron" id="chevron-' + cardId + '">&#9654;</span>';
                html += '</div>';
                html += '</div>';

                // Card body (hidden by default)
                html += '<div class="val-card-body" id="body-' + cardId + '" style="display:none;">';

                // Action controls — jump straight to them
                if (w.type === 'required_empty') {
                    html += renderRequiredEmptyActions(w, cardId);
                } else if (w.type === 'lookup_invalid') {
                    html += renderLookupInvalidActions(w, cardId, serverData);
                }

                html += '</div>'; // end card body
                html += '</div>'; // end card
            });
            html += '</div>'; // end validation-cards
        }

        // Informational warnings (max length, data type, lookup errors — not actionable)
        if (infoWarnings.length > 0) {
            html += '<div class="validation-info-section">';
            html += '<div class="validation-info-header">Warnings (' + infoWarnings.length + ')</div>';
            infoWarnings.forEach(function (w, idx) {
                var infoId = 'vinfo-' + idx;
                var fieldDisplay = getFieldDisplayNameByElement(w.field);
                var typeLabel = { max_length: 'Max Length', data_type: 'Data Type', lookup_error: 'Lookup Discovery' }[w.type] || w.type;

                html += '<div class="val-info-card" id="' + infoId + '">';
                html += '<div class="val-info-header" onclick="BDL.toggleInfoCard(\'' + infoId + '\')">';
                html += '<span class="val-card-field">';
                if (fieldDisplay !== w.field) {
                    html += escapeHtml(fieldDisplay) + ' <code class="val-target">' + w.field + '</code>';
                } else {
                    html += '<code class="val-target">' + w.field + '</code>';
                }
                html += '</span>';
                html += '<span class="val-badge val-badge-info">' + typeLabel + '</span>';
                html += '<span class="val-card-count">' + w.rowCount.toLocaleString() + ' rows</span>';
                html += '<span class="val-info-chevron" id="chevron-' + infoId + '">&#9654;</span>';
                html += '</div>';
                html += '<div class="val-info-body" id="body-' + infoId + '" style="display:none;">';
                html += '<div class="val-card-message">' + escapeHtml(w.message) + '</div>';
                if (w.samples && w.samples.length > 0) {
                    html += '<div class="validation-samples">';
                    w.samples.forEach(function (s) { html += '<span class="val-sample">Row ' + s.row + ': <code>' + escapeHtml(String(s.value)) + '</code>'; if (s.length) html += ' (' + s.length + ' chars)'; html += '</span>'; });
                    html += '</div>';
                }
                html += '</div></div>';
            });
            html += '</div>';
        }

        // Context and actions
        html += '<div class="validation-context">Staged to <strong>' + escapeHtml(serverData.staging_table) + '</strong> &middot; Validated against <strong>' + escapeHtml(serverData.environment) + '</strong> (' + escapeHtml(serverData.db_instance) + ')';
        var lc = Object.keys(serverData.lookups || {}).length; if (lc > 0) html += ' &middot; ' + lc + ' lookup table(s) queried';
        html += '</div><div class="validation-actions"><button class="nav-btn" onclick="BDL.revalidate()">Re-validate</button></div>';
        area.innerHTML = html;
    }

    function renderRequiredEmptyActions(w, cardId) {
        var sf = w.field.replace(/'/g, "\\'");
        var rid = 'fill-' + w.field.replace(/[^a-zA-Z0-9]/g, '');
        var html = '<div class="lookup-replace-table"><div class="lookup-replace-header"><span class="lrh-count">Rows</span><span class="lrh-value">Current</span><span class="lrh-action">Action</span></div>';
        html += '<div class="lookup-replace-row" id="row-' + rid + '"><span class="lrr-count">' + w.rowCount.toLocaleString() + '</span><span class="lrr-value"><code>(empty)</code></span><span class="lrr-action">';
        if (w.hasLookup && w.lookupValues) {
            html += '<select id="' + rid + '" class="replace-select"><option value="">— Select value —</option>';
            w.lookupValues.forEach(function (v) { html += '<option value="' + escapeHtml(v) + '">' + escapeHtml(v) + '</option>'; });
            html += '</select>';
        } else {
            html += '<input type="text" id="' + rid + '" class="replace-input" placeholder="Enter value...">';
        }
        html += ' <button class="replace-btn" onclick="BDL.fillEmpty(\'' + sf + '\',\'' + rid + '\')">Fill</button>';
        var fieldObj = entityFields.find(function(ff) { return ff.element_name === w.field; });
        if (!fieldObj || !fieldObj.is_not_nullifiable) {
            html += ' <button class="skip-btn" onclick="BDL.skipRows(\'' + sf + '\',\'\',\'row-' + rid + '\')">Skip Rows</button>';
        }
        html += '</span></div></div>';
        return html;
    }

    function renderLookupInvalidActions(w, cardId, serverData) {
        var vv = serverData.lookups && serverData.lookups[w.field] ? serverData.lookups[w.field].values : [];
        var uniqueKeys = Object.keys(w.uniqueValues);
        var html = '<div class="lookup-replace-table" data-card="' + cardId + '" data-total-values="' + uniqueKeys.length + '" data-resolved="0">';
        html += '<div class="lookup-replace-header"><span class="lrh-count">Count</span><span class="lrh-value">File Value</span><span class="lrh-action">Action</span></div>';
        uniqueKeys.forEach(function (key) {
            var info = w.uniqueValues[key], sf2 = w.field.replace(/'/g, "\\'"), sd = info.display.replace(/'/g, "\\'");
            var rid2 = 'replace-' + w.field.replace(/[^a-zA-Z0-9]/g, '') + '-' + key.replace(/[^a-zA-Z0-9]/g, '');
            html += '<div class="lookup-replace-row" id="row-' + rid2 + '" data-resolved="false"><span class="lrr-count">' + info.count.toLocaleString() + '</span><span class="lrr-value"><code>' + escapeHtml(info.display) + '</code></span><span class="lrr-action">';
            html += '<select id="' + rid2 + '" class="replace-select"><option value="">— Replace with —</option>';
            vv.forEach(function (v) { html += '<option value="' + escapeHtml(v) + '">' + escapeHtml(v) + '</option>'; });
            html += '</select> <button class="replace-btn" onclick="BDL.applyReplacement(\'' + sf2 + '\',\'' + sd + '\',\'' + rid2 + '\')">Replace</button> <button class="skip-btn" onclick="BDL.skipRows(\'' + sf2 + '\',\'' + sd + '\',\'row-' + rid2 + '\')">Skip</button>';
            html += '</span></div>';
        });
        html += '</div>';
        return html;
    }

    // ── Accordion card toggling ──────────────────────────────────────────
    function toggleValidationCard(cardId) {
        if (revalidating) return;
        var cards = document.querySelectorAll('.val-card');
        cards.forEach(function (card) {
            var body = document.getElementById('body-' + card.id);
            var chevron = document.getElementById('chevron-' + card.id);
            if (card.id === cardId) {
                // Toggle this card
                if (body.style.display === 'none') {
                    body.style.display = 'block';
                    if (chevron) chevron.innerHTML = '&#9660;';
                    card.classList.add('val-card-expanded');
                } else {
                    body.style.display = 'none';
                    if (chevron) chevron.innerHTML = '&#9654;';
                    card.classList.remove('val-card-expanded');
                }
            } else {
                // Collapse other cards
                if (body) body.style.display = 'none';
                if (chevron) chevron.innerHTML = '&#9654;';
                card.classList.remove('val-card-expanded');
            }
        });
    }

    function toggleInfoCard(infoId) {
        var body = document.getElementById('body-' + infoId);
        var chevron = document.getElementById('chevron-' + infoId);
        if (!body) return;
        if (body.style.display === 'none') {
            body.style.display = 'block';
            if (chevron) chevron.innerHTML = '&#9660;';
        } else {
            body.style.display = 'none';
            if (chevron) chevron.innerHTML = '&#9654;';
        }
    }

    // ── Check if all values in a lookup card are resolved ────────────────
    function checkLookupCardComplete(rowElement) {
        var table = rowElement.closest('.lookup-replace-table');
        if (!table) return;
        var totalValues = parseInt(table.dataset.totalValues) || 0;
        var resolvedRows = table.querySelectorAll('.lookup-replace-row[data-resolved="true"]');
        var resolvedCount = resolvedRows.length;
        table.dataset.resolved = String(resolvedCount);

        if (resolvedCount >= totalValues) {
            // All values for this element resolved — trigger cascading re-validate
            triggerCascadingRevalidate();
        }
    }

    // ── Cascading re-validate ────────────────────────────────────────────
    function triggerCascadingRevalidate() {
        if (revalidating) return;
        revalidating = true;

        var area = document.getElementById('validation-area');
        area.innerHTML = '<div class="loading">Applying changes and re-validating...</div>';

        // Small delay to let the UI update before the fetch
        setTimeout(function () { runValidation(); }, 200);
    }

    // ── Action handlers with cascading support ───────────────────────────

    function applyReplacement(field, oldValue, selectId) {
        if (revalidating) return;
        var sel = document.getElementById(selectId); if (!sel || !sel.value) { alert('Please select a replacement value.'); return; }
        var newVal = sel.value, btn = sel.parentElement.querySelector('.replace-btn'); if (btn) btn.disabled = true;
        var skipBtn = sel.parentElement.querySelector('.skip-btn'); if (skipBtn) skipBtn.disabled = true;

        fetch('/api/bdl-import/replace-values', { method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ staging_table: stagingContext.staging_table, field: field, old_value: oldValue, new_value: newVal }) })
        .then(function (r) { if (!r.ok) return r.json().then(function (d) { throw new Error(d.error || 'HTTP ' + r.status); }); return r.json(); })
        .then(function (data) {
            var row = document.getElementById(selectId).closest('.lookup-replace-row');
            if (row) {
                row.innerHTML = '<span class="lrr-count">' + data.rows_updated + '</span><span class="lrr-value"><code>' + escapeHtml(oldValue) + '</code> &#8594; <code>' + escapeHtml(newVal) + '</code></span><span class="lrr-action replace-done">&#10003; Replaced</span>';
                row.dataset.resolved = 'true';
                checkLookupCardComplete(row);
            }
        }).catch(function (err) { alert('Replacement failed: ' + err.message); if (btn) btn.disabled = false; if (skipBtn) skipBtn.disabled = false; });
    }

    function fillEmpty(field, inputId) {
        if (revalidating) return;
        var input = document.getElementById(inputId);
        var newVal = input ? input.value : '';
        if (!newVal) { alert('Please enter or select a value.'); return; }
        var btn = input.parentElement.querySelector('.replace-btn'); if (btn) btn.disabled = true;
        var skipBtn = input.parentElement.querySelector('.skip-btn'); if (skipBtn) skipBtn.disabled = true;

        fetch('/api/bdl-import/replace-values', { method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ staging_table: stagingContext.staging_table, field: field, old_value: '', new_value: newVal }) })
        .then(function (r) { if (!r.ok) return r.json().then(function (d) { throw new Error(d.error || 'HTTP ' + r.status); }); return r.json(); })
        .then(function (data) {
            var row = document.getElementById(inputId).closest('.lookup-replace-row');
            if (row) {
                row.innerHTML = '<span class="lrr-count">' + data.rows_updated + '</span><span class="lrr-value"><code>(empty)</code> &#8594; <code>' + escapeHtml(newVal) + '</code></span><span class="lrr-action replace-done">&#10003; Filled</span>';
            }
            // Required empty is always a single action — trigger re-validate immediately
            triggerCascadingRevalidate();
        }).catch(function (err) { alert('Fill failed: ' + err.message); if (btn) btn.disabled = false; if (skipBtn) skipBtn.disabled = false; });
    }

    function skipRows(field, value, rowElementId) {
        if (revalidating) return;
        var rowEl = document.getElementById(rowElementId);
        // Disable buttons in this row while the request is in flight
        if (rowEl) {
            var btns = rowEl.querySelectorAll('button');
            btns.forEach(function (b) { b.disabled = true; });
        }

        fetch('/api/bdl-import/skip-rows', { method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ staging_table: stagingContext.staging_table, field: field, value: value }) })
        .then(function (r) { if (!r.ok) return r.json().then(function (d) { throw new Error(d.error || 'HTTP ' + r.status); }); return r.json(); })
        .then(function (data) {
            var row = document.getElementById(rowElementId);
            if (row) {
                row.innerHTML = '<span class="lrr-count">' + data.rows_skipped + '</span><span class="lrr-value"><code>' + escapeHtml(value || '(empty)') + '</code></span><span class="lrr-action skip-done">&#10005; Skipped (' + data.rows_skipped + ' rows)</span>';

                // Check if this is a lookup card (has data-resolved attribute) or a required empty
                if (row.dataset.resolved !== undefined) {
                    // Lookup card — mark resolved, check if all values done
                    row.dataset.resolved = 'true';
                    checkLookupCardComplete(row);
                } else {
                    // Required empty — single action, trigger re-validate immediately
                    triggerCascadingRevalidate();
                }
            }
        }).catch(function (err) {
            alert('Skip failed: ' + err.message);
            if (rowEl) {
                var btns = rowEl.querySelectorAll('button');
                btns.forEach(function (b) { b.disabled = false; });
            }
        });
    }

    function revalidate() { validationResult = null; runValidation(); }

    // ── Step 6: Review & Execute ─────────────────────────────────────────

    function renderExecuteReview() {
        var area = document.getElementById('execute-area');
        var envName = selectedEnvironment ? selectedEnvironment.environment : '?';
        var entityName = formatEntityName(selectedEntity ? selectedEntity.entity_type : '?');
        var fileName = uploadedFile ? uploadedFile.name : '?';
        var mappedCount = columnMapping ? Object.keys(columnMapping).length : 0;
        var rowCount = stagingContext ? stagingContext.row_count : 0;

        var html = '';

        html += '<div class="execute-summary">';
        html += '<div class="execute-summary-header">Import Summary</div>';
        html += '<div class="execute-summary-grid">';
        html += '<div class="summary-item"><span class="summary-label">Environment</span><span class="summary-value summary-env-' + envName.toLowerCase() + '">' + envName + '</span></div>';
        html += '<div class="summary-item"><span class="summary-label">Entity Type</span><span class="summary-value">' + entityName + ' <code class="summary-code">' + escapeHtml(selectedEntity.entity_type) + '</code></span></div>';
        html += '<div class="summary-item"><span class="summary-label">Source File</span><span class="summary-value">' + escapeHtml(fileName) + '</span></div>';
        html += '<div class="summary-item"><span class="summary-label">Rows to Import</span><span class="summary-value">' + rowCount.toLocaleString() + '</span></div>';
        html += '<div class="summary-item"><span class="summary-label">Mapped Fields</span><span class="summary-value">' + mappedCount + '</span></div>';
        html += '<div class="summary-item"><span class="summary-label">Staging Table</span><span class="summary-value"><code class="summary-code">' + escapeHtml(stagingContext.staging_table) + '</code></span></div>';
        html += '</div></div>';

        html += '<div class="execute-mapping">';
        html += '<div class="execute-section-header" onclick="BDL.toggleSection(\'mapping-ref\')">Column Mapping <span class="section-toggle" id="toggle-mapping-ref">&#9660;</span></div>';
        html += '<div class="execute-section-body" id="mapping-ref">';
        var mKeys = Object.keys(columnMapping);
        mKeys.forEach(function (sc) {
            var te = columnMapping[sc];
            var displayName = getFieldDisplayNameByElement(te);
            html += '<div class="execute-map-row"><span class="exec-map-source">' + escapeHtml(sc) + '</span><span class="exec-map-arrow">&#8594;</span>';
            if (displayName !== te) {
                html += '<span class="exec-map-target">' + escapeHtml(displayName) + ' <code>' + te + '</code></span>';
            } else {
                html += '<span class="exec-map-target"><code>' + te + '</code></span>';
            }
            html += '</div>';
        });
        html += '</div></div>';

        html += '<div class="execute-preview">';
        html += '<div class="execute-section-header" onclick="BDL.toggleSection(\'xml-preview\')">XML Preview <span class="section-toggle" id="toggle-xml-preview">&#9654;</span></div>';
        html += '<div class="execute-section-body collapsed" id="xml-preview">';
        html += '<div class="xml-preview-loading" id="xml-preview-content">Click to load XML preview...</div>';
        html += '<div class="xml-preview-actions"><button class="nav-btn" onclick="BDL.loadXmlPreview()">Load Preview</button></div>';
        html += '</div></div>';

        html += '<div class="execute-actions" id="execute-actions">';
        if (envName === 'PROD') {
            html += '<div class="execute-prod-warning">&#9888; You are about to import into <strong>PRODUCTION</strong>. This action cannot be undone.</div>';
        }
        html += '<button class="execute-btn" id="btn-execute-import" onclick="BDL.executeImport()">Submit BDL Import</button>';
        html += '</div>';

        html += '<div class="execute-progress hidden" id="execute-progress"></div>';
        html += '<div class="execute-result hidden" id="execute-result"></div>';

        area.innerHTML = html;
    }

    function toggleSection(sectionId) {
        var body = document.getElementById(sectionId);
        var toggle = document.getElementById('toggle-' + sectionId);
        if (!body) return;
        if (body.classList.contains('collapsed')) {
            body.classList.remove('collapsed');
            if (toggle) toggle.innerHTML = '&#9660;';
        } else {
            body.classList.add('collapsed');
            if (toggle) toggle.innerHTML = '&#9654;';
        }
    }

    function loadXmlPreview() {
        var content = document.getElementById('xml-preview-content');
        content.innerHTML = '<div class="loading">Building XML preview...</div>';

        fetch('/api/bdl-import/build-preview', { method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ staging_table: stagingContext.staging_table, entity_type: selectedEntity.entity_type, config_id: selectedEnvironment.config_id }) })
        .then(function (r) { if (!r.ok) return r.json().then(function (d) { throw new Error(d.error || 'HTTP ' + r.status); }); return r.json(); })
        .then(function (data) {
            var sizeKB = (data.full_size_bytes / 1024).toFixed(1);
            var header = '<div class="xml-preview-header">';
            header += '<span class="xml-filename">' + escapeHtml(data.xml_filename) + '</span>';
            header += '<span class="xml-meta">' + data.row_count.toLocaleString() + ' rows &middot; ' + sizeKB + ' KB';
            if (data.truncated) header += ' &middot; <em>preview truncated</em>';
            header += '</span></div>';
            content.innerHTML = header + '<pre class="xml-preview-code">' + highlightXml(data.xml) + '</pre>';
        })
        .catch(function (err) {
            content.innerHTML = '<div class="placeholder-message" style="color:#f48771;">Failed to build preview: ' + err.message + '</div>';
        });
    }

    function highlightXml(xml) {
        var s = xml
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;');

        s = s.replace(/(&lt;\?xml\b)(.*?)(\?&gt;)/g,
            '<span class="xml-decl">$1$2$3</span>');

        s = s.replace(/(&lt;!--)([\s\S]*?)(--&gt;)/g,
            '<span class="xml-comment">$1$2$3</span>');

        s = s.replace(/(&lt;\/)([\w_:-]+)(&gt;)/g,
            '<span class="xml-bracket">$1</span><span class="xml-tag">$2</span><span class="xml-bracket">$3</span>');

        s = s.replace(/(&lt;)([\w_:-]+)(\/&gt;)/g,
            '<span class="xml-bracket">$1</span><span class="xml-tag">$2</span><span class="xml-bracket">$3</span>');

        s = s.replace(/(&lt;)([\w_:-]+)((?:\s+[\w_:-]+=&quot;[^&]*?&quot;)*\s*\/?)(&gt;)/g,
            function (match, lt, tagName, attrs, gt) {
                var coloredAttrs = attrs.replace(/([\w_:-]+)(=)(&quot;)(.*?)(&quot;)/g,
                    '<span class="xml-attr-name">$1</span><span class="xml-bracket">$2</span><span class="xml-attr-val">$3$4$5</span>');
                return '<span class="xml-bracket">' + lt + '</span><span class="xml-tag">' + tagName + '</span>' + coloredAttrs + '<span class="xml-bracket">' + gt + '</span>';
            });

        s = s.replace(/(<\/span>)([^<]+)(<span class="xml-bracket">&lt;)/g,
            function (match, closeSpan, text, openSpan) {
                if (text.trim() === '') return match;
                return closeSpan + '<span class="xml-value">' + text + '</span>' + openSpan;
            });

        return s;
    }

    function executeImport() {
        if (executeInProgress) return;

        var envName = selectedEnvironment.environment;
        var msg = 'Submit BDL import to ' + envName + '?\n\n';
        msg += 'Entity: ' + selectedEntity.entity_type + '\n';
        msg += 'Rows: ' + stagingContext.row_count.toLocaleString() + '\n\n';
        if (envName === 'PROD') msg += 'WARNING: This is a PRODUCTION import and cannot be undone.\n\n';
        msg += 'Continue?';
        if (!confirm(msg)) return;

        executeInProgress = true;

        var execBtn = document.getElementById('btn-execute-import');
        if (execBtn) { execBtn.disabled = true; execBtn.textContent = 'Submitting...'; }

        var progress = document.getElementById('execute-progress');
        progress.classList.remove('hidden');
        progress.innerHTML = renderProgressSteps('building');

        var mappingJson = JSON.stringify(columnMapping);

        fetch('/api/bdl-import/execute', { method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                staging_table: stagingContext.staging_table,
                entity_type: selectedEntity.entity_type,
                config_id: selectedEnvironment.config_id,
                source_filename: uploadedFile ? uploadedFile.name : 'unknown',
                column_mapping: mappingJson
            })
        })
        .then(function (r) { return r.json().then(function (d) { d._httpStatus = r.status; return d; }); })
        .then(function (data) {
            executeInProgress = false;

            if (data._httpStatus >= 400 || data.error) {
                progress.innerHTML = renderProgressSteps('failed');
                var result = document.getElementById('execute-result');
                result.classList.remove('hidden');
                result.innerHTML = '<div class="execute-result-fail">'
                    + '<span class="result-icon">&#10006;</span>'
                    + '<div><strong>Import Failed</strong>'
                    + '<div class="result-detail">' + escapeHtml(data.error) + '</div>'
                    + (data.log_id ? '<div class="result-meta">Log ID: ' + data.log_id + '</div>' : '')
                    + '</div></div>';

                if (execBtn) { execBtn.disabled = false; execBtn.textContent = 'Retry Submit'; }
            } else {
                progress.innerHTML = renderProgressSteps('submitted');
                var result = document.getElementById('execute-result');
                result.classList.remove('hidden');
                result.innerHTML = '<div class="execute-result-success">'
                    + '<span class="result-icon">&#10003;</span>'
                    + '<div><strong>BDL Import Submitted</strong>'
                    + '<div class="result-detail">' + escapeHtml(data.message) + '</div>'
                    + '<div class="result-meta">'
                    + 'File: <code>' + escapeHtml(data.xml_filename) + '</code> &middot; '
                    + 'Registry ID: <strong>' + data.file_registry_id + '</strong> &middot; '
                    + 'Log ID: ' + data.log_id + ' &middot; '
                    + data.row_count.toLocaleString() + ' rows'
                    + '</div></div></div>';

                var actions = document.getElementById('execute-actions');
                if (actions) actions.classList.add('hidden');

                stepComplete[5] = true;
                updateStepperUI();
            }
        })
        .catch(function (err) {
            executeInProgress = false;
            progress.innerHTML = renderProgressSteps('failed');
            var result = document.getElementById('execute-result');
            result.classList.remove('hidden');
            result.innerHTML = '<div class="execute-result-fail">'
                + '<span class="result-icon">&#10006;</span>'
                + '<div><strong>Request Failed</strong>'
                + '<div class="result-detail">' + escapeHtml(err.message) + '</div>'
                + '</div></div>';

            if (execBtn) { execBtn.disabled = false; execBtn.textContent = 'Retry Submit'; }
        });
    }

    function renderProgressSteps(currentPhase) {
        var phases = [
            { key: 'building',   label: 'Building XML' },
            { key: 'writing',    label: 'Writing File' },
            { key: 'registered', label: 'Registering with DM' },
            { key: 'submitted',  label: 'Triggering Import' }
        ];

        var phaseOrder = { building: 0, writing: 1, registered: 2, submitted: 3, failed: -1 };
        var currentIdx = phaseOrder[currentPhase] !== undefined ? phaseOrder[currentPhase] : -1;
        var isFailed = (currentPhase === 'failed');

        var html = '<div class="progress-steps">';
        phases.forEach(function (p, idx) {
            var cls = 'progress-step';
            if (isFailed) {
                cls += (idx <= Math.max(currentIdx, 0)) ? ' progress-failed' : '';
            } else if (idx < currentIdx) {
                cls += ' progress-complete';
            } else if (idx === currentIdx) {
                cls += ' progress-active';
            }
            var icon = '';
            if (isFailed && idx === Math.max(currentIdx, 0)) icon = '&#10006;';
            else if (idx < currentIdx || (currentPhase === 'submitted' && idx === currentIdx)) icon = '&#10003;';
            else if (idx === currentIdx && !isFailed) icon = '&#9679;';
            else icon = '&#9675;';

            html += '<div class="' + cls + '"><span class="progress-icon">' + icon + '</span><span class="progress-label">' + p.label + '</span></div>';
            if (idx < phases.length - 1) html += '<div class="progress-connector' + (idx < currentIdx ? ' progress-connector-done' : '') + '"></div>';
        });
        html += '</div>';
        return html;
    }

    // ── Templates ─────────────────────────────────────────────────────────

    function loadTemplates(entityType) {
        entityTemplates = [];
        var list = document.getElementById('template-list');
        if (!list) return;
        list.innerHTML = '<div class="template-empty">Loading templates...</div>';

        fetch('/api/bdl-import/templates?entity_type=' + encodeURIComponent(entityType))
            .then(function (r) { return r.json(); })
            .then(function (data) {
                entityTemplates = data.templates || [];
                renderTemplateList();
            })
            .catch(function () {
                list.innerHTML = '<div class="template-empty">Failed to load templates.</div>';
            });
    }

    function renderTemplateList() {
        var list = document.getElementById('template-list');
        if (!list) return;

        if (!entityTemplates.length) {
            list.innerHTML = '<div class="template-empty">No saved templates for this entity type.</div>';
            return;
        }

        var isStep4 = (currentStep === 4);
        var html = '';
        entityTemplates.forEach(function (t) {
            var mapping = {};
            try { mapping = JSON.parse(t.column_mapping); } catch (e) {}
            var fieldCount = Object.keys(mapping).length;
            var matchInfo = '';
            if (isStep4 && parsedFileData) {
                var matchCount = countTemplateMatches(mapping);
                matchInfo = '<span class="template-match">' + matchCount + ' of ' + fieldCount + ' fields match your file</span>';
            }
            var creator = t.created_by || '';
            if (creator.indexOf('\\') !== -1) creator = creator.split('\\')[1];
            var activeCls = (activeTemplateId === t.template_id) ? ' template-card-active' : '';

            html += '<div class="template-card' + activeCls + '" onclick="BDL.previewTemplate(' + t.template_id + ')">';
            html += '<div class="template-card-name">' + escapeHtml(t.template_name) + '</div>';
            if (t.description) html += '<div class="template-card-desc">' + escapeHtml(t.description) + '</div>';
            html += '<div class="template-card-meta">' + fieldCount + ' fields &middot; ' + escapeHtml(creator) + (matchInfo ? ' &middot; ' + matchInfo : '') + '</div>';
            html += '</div>';
        });
        list.innerHTML = html;
    }

    function countTemplateMatches(mapping) {
        if (!parsedFileData) return 0;
        var count = 0;
        var fileHeaders = parsedFileData.headers.map(function (h) { return h.toUpperCase(); });
        Object.keys(mapping).forEach(function (sourceCol) {
            if (fileHeaders.indexOf(sourceCol.toUpperCase()) !== -1) count++;
        });
        return count;
    }

    function updateTemplateSectionState() {
        var saveArea = document.getElementById('template-save-area');
        if (saveArea) {
            if (currentStep === 4 && columnMapping && Object.keys(columnMapping).length > 0) {
                saveArea.classList.remove('hidden');
            } else {
                saveArea.classList.add('hidden');
            }
        }
        // Re-render list to update match counts when step changes
        if (entityTemplates.length > 0) renderTemplateList();
    }

    function previewTemplate(templateId) {
        var template = entityTemplates.find(function (t) { return t.template_id === templateId; });
        if (!template) return;

        var mapping = {};
        try { mapping = JSON.parse(template.column_mapping); } catch (e) {}
        var mappingKeys = Object.keys(mapping);

        var slideout = document.getElementById('template-slideout');
        var overlay = document.getElementById('template-slideout-overlay');
        var title = document.getElementById('template-slideout-title');
        var body = document.getElementById('template-slideout-body');

        title.textContent = template.template_name;

        var html = '';

        // Meta info
        var creator = template.created_by || '';
        if (creator.indexOf('\\') !== -1) creator = creator.split('\\')[1];
        html += '<div class="slideout-meta">';
        if (template.description) html += '<div class="slideout-desc">' + escapeHtml(template.description) + '</div>';
        html += '<div class="slideout-creator">Created by <strong>' + escapeHtml(creator) + '</strong></div>';
        html += '</div>';

        // Match summary (only on Step 4 with a file loaded)
        if (parsedFileData && currentStep === 4) {
            var matchCount = countTemplateMatches(mapping);
            var matchClass = (matchCount === mappingKeys.length) ? 'slideout-match-full' : (matchCount > 0 ? 'slideout-match-partial' : 'slideout-match-none');
            html += '<div class="slideout-match-summary ' + matchClass + '">' + matchCount + ' of ' + mappingKeys.length + ' mapped columns found in your file</div>';
        }

        // Mapping pairs
        html += '<div class="slideout-mappings-header">Column Mappings (' + mappingKeys.length + ')</div>';
        html += '<div class="slideout-mappings">';
        var fileHeaders = parsedFileData ? parsedFileData.headers.map(function (h) { return h.toUpperCase(); }) : [];
        mappingKeys.forEach(function (sourceCol) {
            var elementName = mapping[sourceCol];
            var displayName = getFieldDisplayNameByElement(elementName);
            var matched = fileHeaders.indexOf(sourceCol.toUpperCase()) !== -1;
            var matchCls = parsedFileData ? (matched ? ' slideout-pair-match' : ' slideout-pair-miss') : '';

            html += '<div class="slideout-pair' + matchCls + '">';
            html += '<span class="slideout-pair-source">' + escapeHtml(sourceCol) + '</span>';
            html += '<span class="slideout-pair-arrow">&#8594;</span>';
            if (displayName !== elementName) {
                html += '<span class="slideout-pair-target">' + escapeHtml(displayName) + ' <code>' + elementName + '</code></span>';
            } else {
                html += '<span class="slideout-pair-target"><code>' + elementName + '</code></span>';
            }
            if (parsedFileData) {
                html += '<span class="slideout-pair-status">' + (matched ? '&#10003;' : '&#10005;') + '</span>';
            }
            html += '</div>';
        });
        html += '</div>';

        // Action buttons
        if (currentStep === 4 && parsedFileData) {
            html += '<div class="slideout-actions">';
            html += '<button class="replace-btn" onclick="BDL.applyTemplate(' + templateId + ')">Apply Template</button>';
            html += '</div>';
        }

        // Delete button (creator or admin)
        var currentUser = 'FAC\\' + (window.userTier || '');
        var isCreator = (template.created_by === currentUser);
        if (isCreator || window.isAdmin) {
            html += '<div class="slideout-danger"><button class="slideout-delete-btn" onclick="BDL.deleteTemplate(' + templateId + ')">Delete Template</button></div>';
        }

        body.innerHTML = html;
        slideout.classList.add('open');
        overlay.classList.add('open');
    }

    function closeTemplatePreview() {
        var slideout = document.getElementById('template-slideout');
        var overlay = document.getElementById('template-slideout-overlay');
        slideout.classList.remove('open');
        overlay.classList.remove('open');
    }

    function applyTemplate(templateId) {
        var template = entityTemplates.find(function (t) { return t.template_id === templateId; });
        if (!template || !parsedFileData) return;

        var templateMapping = {};
        try { templateMapping = JSON.parse(template.column_mapping); } catch (e) { return; }

        // Match template source columns to current file headers (case-insensitive)
        var fileHeaderMap = {};
        parsedFileData.headers.forEach(function (h) { fileHeaderMap[h.toUpperCase()] = h; });

        columnMapping = {};
        Object.keys(templateMapping).forEach(function (sourceCol) {
            var actualHeader = fileHeaderMap[sourceCol.toUpperCase()];
            if (actualHeader) {
                columnMapping[actualHeader] = templateMapping[sourceCol];
            }
        });

        activeTemplateId = templateId;
        closeTemplatePreview();
        renderMapping();
        renderTemplateList();
    }

    function showSaveTemplate() {
        if (!columnMapping || Object.keys(columnMapping).length === 0) return;
        var modal = document.getElementById('template-modal-overlay');
        var nameInput = document.getElementById('save-template-name');
        var descInput = document.getElementById('save-template-desc');
        var status = document.getElementById('save-template-status');
        nameInput.value = '';
        descInput.value = '';
        status.classList.add('hidden');
        status.textContent = '';

        // Show preview of what will be saved
        var preview = document.getElementById('save-template-preview');
        var mKeys = Object.keys(columnMapping);
        var html = '<div class="template-modal-preview-header">' + mKeys.length + ' field mapping(s) will be saved:</div>';
        mKeys.forEach(function (sc) {
            var te = columnMapping[sc];
            var displayName = getFieldDisplayNameByElement(te);
            html += '<div class="template-modal-preview-row">';
            html += '<span class="pair-source">' + escapeHtml(sc) + '</span>';
            html += '<span class="pair-arrow">&#8594;</span>';
            if (displayName !== te) {
                html += '<span class="pair-target"><span class="pair-display">' + escapeHtml(displayName) + '</span> <span class="pair-element">' + te + '</span></span>';
            } else {
                html += '<span class="pair-target">' + te + '</span>';
            }
            html += '</div>';
        });
        preview.innerHTML = html;

        modal.classList.remove('hidden');
        nameInput.focus();
    }

    function closeSaveTemplate() {
        document.getElementById('template-modal-overlay').classList.add('hidden');
    }

    function saveTemplate() {
        var nameInput = document.getElementById('save-template-name');
        var descInput = document.getElementById('save-template-desc');
        var status = document.getElementById('save-template-status');
        var name = nameInput.value.trim();

        if (!name) { nameInput.focus(); nameInput.style.borderColor = '#f48771'; return; }
        nameInput.style.borderColor = '';

        var mappingJson = JSON.stringify(columnMapping);

        fetch('/api/bdl-import/templates', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                entity_type: selectedEntity.entity_type,
                template_name: name,
                description: descInput.value.trim() || null,
                column_mapping: mappingJson
            })
        })
        .then(function (r) { return r.json().then(function (d) { d._httpStatus = r.status; return d; }); })
        .then(function (data) {
            if (data._httpStatus >= 400 || data.error) {
                status.textContent = data.error || 'Failed to save template.';
                status.className = 'template-modal-status template-modal-error';
                status.classList.remove('hidden');
            } else {
                status.textContent = 'Template saved!';
                status.className = 'template-modal-status template-modal-success';
                status.classList.remove('hidden');
                activeTemplateId = data.template_id;
                setTimeout(function () {
                    closeSaveTemplate();
                    loadTemplates(selectedEntity.entity_type);
                }, 1000);
            }
        })
        .catch(function (err) {
            status.textContent = 'Error: ' + err.message;
            status.className = 'template-modal-status template-modal-error';
            status.classList.remove('hidden');
        });
    }

    function deleteTemplate(templateId) {
        var template = entityTemplates.find(function (t) { return t.template_id === templateId; });
        if (!template) return;
        if (!confirm('Delete template "' + template.template_name + '"?\n\nThis cannot be undone.')) return;

        fetch('/api/bdl-import/templates/' + templateId, { method: 'DELETE' })
            .then(function (r) { return r.json(); })
            .then(function (data) {
                if (data.success) {
                    if (activeTemplateId === templateId) activeTemplateId = null;
                    closeTemplatePreview();
                    loadTemplates(selectedEntity.entity_type);
                } else {
                    alert(data.error || 'Failed to delete template.');
                }
            })
            .catch(function (err) { alert('Error: ' + err.message); });
    }

    function resetFromStep(step) {
        for (var i = step - 1; i < totalSteps; i++) stepComplete[i] = false;
        if (step <= 3) { uploadedFile = null; parsedFileData = null; columnMapping = null; stagingContext = null; stagedMapping = null; }
        if (step <= 2) { entityTemplates = []; activeTemplateId = null; }
        if (step <= 5 && step > 3) { validationResult = null; }
        if (step <= 4 && step > 3) { validationResult = null; activeTemplateId = null; }
        executeInProgress = false;
        updateStepperUI(); updateNavButtons();
    }

    function escapeHtml(str) { if (!str) return ''; var d = document.createElement('div'); d.textContent = str; return d.innerHTML; }

    return {
        init: init, goToStep: goToStep, nextStep: nextStep, prevStep: prevStep,
        selectEnvironment: selectEnvironment,
        selectEntity: selectEntity, filterEntities: filterEntities,
        dragOver: dragOver, dragLeave: dragLeave, fileDrop: fileDrop, fileSelected: fileSelected, removeFile: removeFile,
        sourceClick: sourceClick, targetClick: targetClick, chipDragStart: chipDragStart, chipDragOver: chipDragOver, chipDrop: chipDrop,
        unmapPair: unmapPair, identifierChanged: identifierChanged,
        revalidate: revalidate, applyReplacement: applyReplacement, fillEmpty: fillEmpty, skipRows: skipRows,
        runCleanup: runCleanup,
        toggleValidationCard: toggleValidationCard, toggleInfoCard: toggleInfoCard,
        toggleSection: toggleSection, loadXmlPreview: loadXmlPreview, executeImport: executeImport,
        previewTemplate: previewTemplate, closeTemplatePreview: closeTemplatePreview,
        applyTemplate: applyTemplate, showSaveTemplate: showSaveTemplate,
        closeSaveTemplate: closeSaveTemplate, saveTemplate: saveTemplate, deleteTemplate: deleteTemplate
    };
})();
document.addEventListener('DOMContentLoaded', BDL.init);

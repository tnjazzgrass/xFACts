// ============================================================================
// xFACts Control Center - Applications & Integration Page JavaScript
// Location: E:\xFACts-ControlCenter\public\js\applications-integration.js
// Version: Tracked in dbo.System_Metadata (component: DeptOps.ApplicationsIntegration)
// ============================================================================

// ============================================================================
// BDL CATALOG MANAGEMENT
// Two-tier panel: Slide-up (format list) + Slideout (element detail)
// Supports two modes:
//   Global Configuration — edit catalog fields, toggle entity active state
//   Department Access — grant/revoke entity and field access per department
// ============================================================================

const BdlCatalog = (function () {

    // --- Shared State ---
    let mode = 'global';  // 'global' or 'department'
    let editingField = null;  // { elementId, fieldName } — global mode only

    // --- Global Mode State ---
    let formats = [];
    let elements = [];
    let selectedFormatId = null;
    let selectedFormatName = null;

    // --- Department Mode State ---
    let departments = [];
    let selectedDepartment = null;     // department_key
    let selectedDepartmentName = null; // department_name for display
    let deptFormats = [];              // format list with access status
    let deptFields = [];               // field list with granted status
    let deptSelectedFormatId = null;
    let deptSelectedEntityType = null;
    let deptSelectedConfigId = null;

    // =========================================================================
    // PANEL CONTROLS
    // =========================================================================

    function open() {
        mode = 'global';
        resetGlobalState();
        resetDeptState();
        closeDetail();

        document.getElementById('bdlcat-backdrop').classList.add('visible');
        document.getElementById('bdlcat-panel').classList.add('visible');
        document.getElementById('bdlcat-body').innerHTML = '<div class="bdlcat-loading">Loading BDL formats...</div>';
        document.getElementById('bdlcat-count').textContent = '';

        renderModeSelector();
        loadFormats();
    }

    function close() {
        closeDetail();
        document.getElementById('bdlcat-backdrop').classList.remove('visible');
        document.getElementById('bdlcat-panel').classList.remove('visible');
    }

    function closeDetail() {
        document.getElementById('bdlcat-detail').classList.remove('visible');
        if (mode === 'global') {
            selectedFormatId = null;
            selectedFormatName = null;
            editingField = null;
        } else {
            deptSelectedFormatId = null;
            deptSelectedEntityType = null;
            deptSelectedConfigId = null;
        }
    }

    function resetGlobalState() {
        formats = [];
        elements = [];
        selectedFormatId = null;
        selectedFormatName = null;
        editingField = null;
    }

    function resetDeptState() {
        departments = [];
        selectedDepartment = null;
        selectedDepartmentName = null;
        deptFormats = [];
        deptFields = [];
        deptSelectedFormatId = null;
        deptSelectedEntityType = null;
        deptSelectedConfigId = null;
    }

    // =========================================================================
    // MODE SELECTOR
    // =========================================================================

    function renderModeSelector() {
        var container = document.getElementById('bdlcat-mode-selector');
        if (!container) return;

        var globalCls = mode === 'global' ? ' active' : '';
        var deptCls = mode === 'department' ? ' active' : '';

        var html = '<div class="bdlcat-mode-tabs">' +
            '<button class="bdlcat-mode-tab' + globalCls + '" onclick="BdlCatalog.setMode(\'global\')">Global Configuration</button>' +
            '<button class="bdlcat-mode-tab' + deptCls + '" onclick="BdlCatalog.setMode(\'department\')">Department Access</button>' +
            '</div>';

        if (mode === 'department') {
            html += '<div class="bdlcat-dept-selector">';
            html += '<select id="bdlcat-dept-dropdown" class="bdlcat-dept-dropdown" onchange="BdlCatalog.selectDepartment(this.value)">';
            html += '<option value="">Select department...</option>';
            departments.forEach(function (d) {
                var sel = d.department_key === selectedDepartment ? ' selected' : '';
                html += '<option value="' + esc(d.department_key) + '"' + sel + '>' + esc(d.department_name) + '</option>';
            });
            html += '</select>';
            html += '</div>';
        }

        container.innerHTML = html;
    }

    function setMode(newMode) {
        if (newMode === mode) return;
        mode = newMode;
        closeDetail();

        if (mode === 'department') {
            document.getElementById('bdlcat-body').innerHTML = '<div class="bdlcat-loading">Loading departments...</div>';
            document.getElementById('bdlcat-count').textContent = '';
            document.getElementById('bdlcat-title').textContent = 'BDL Department Access';
            loadDepartments();
        } else {
            document.getElementById('bdlcat-title').textContent = 'BDL Content Management';
            document.getElementById('bdlcat-body').innerHTML = '<div class="bdlcat-loading">Loading BDL formats...</div>';
            document.getElementById('bdlcat-count').textContent = '';
            renderModeSelector();
            loadFormats();
        }
    }

    // =========================================================================
    // DEPARTMENT MODE — DEPARTMENT LIST
    // =========================================================================

    function loadDepartments() {
        fetch('/api/apps-int/departments')
            .then(function (r) { return r.json(); })
            .then(function (data) {
                if (data.Error) {
                    document.getElementById('bdlcat-body').innerHTML = '<div class="bdlcat-error">' + esc(data.Error) + '</div>';
                    return;
                }
                departments = Array.isArray(data) ? data : [];
                renderModeSelector();
                if (selectedDepartment) {
                    loadDepartmentAccess(selectedDepartment);
                } else {
                    document.getElementById('bdlcat-body').innerHTML = '<div class="bdlcat-empty">Select a department to manage BDL access</div>';
                    document.getElementById('bdlcat-count').textContent = '';
                }
            })
            .catch(function (e) {
                document.getElementById('bdlcat-body').innerHTML = '<div class="bdlcat-error">Failed to load departments: ' + esc(e.message) + '</div>';
            });
    }

    function selectDepartment(deptKey) {
        closeDetail();
        if (!deptKey) {
            selectedDepartment = null;
            selectedDepartmentName = null;
            deptFormats = [];
            document.getElementById('bdlcat-body').innerHTML = '<div class="bdlcat-empty">Select a department to manage BDL access</div>';
            document.getElementById('bdlcat-count').textContent = '';
            return;
        }
        selectedDepartment = deptKey;
        for (var i = 0; i < departments.length; i++) {
            if (departments[i].department_key === deptKey) {
                selectedDepartmentName = departments[i].department_name;
                break;
            }
        }
        document.getElementById('bdlcat-body').innerHTML = '<div class="bdlcat-loading">Loading access configuration...</div>';
        loadDepartmentAccess(deptKey);
    }

    // =========================================================================
    // DEPARTMENT MODE — TIER 1: ENTITY ACCESS LIST
    // =========================================================================

    function loadDepartmentAccess(deptKey) {
        fetch('/api/apps-int/bdl-access?department=' + encodeURIComponent(deptKey))
            .then(function (r) { return r.json(); })
            .then(function (data) {
                if (data.Error) {
                    document.getElementById('bdlcat-body').innerHTML = '<div class="bdlcat-error">' + esc(data.Error) + '</div>';
                    return;
                }
                deptFormats = Array.isArray(data) ? data : [];
                renderDeptFormats();
            })
            .catch(function (e) {
                document.getElementById('bdlcat-body').innerHTML = '<div class="bdlcat-error">Failed to load access: ' + esc(e.message) + '</div>';
            });
    }

    function renderDeptFormats() {
        var body = document.getElementById('bdlcat-body');
        if (deptFormats.length === 0) {
            body.innerHTML = '<div class="bdlcat-empty">No active BDL entity types found</div>';
            document.getElementById('bdlcat-count').textContent = '';
            return;
        }

        var grantedCount = 0;
        deptFormats.forEach(function (f) { if (f.has_access) grantedCount++; });
        document.getElementById('bdlcat-count').textContent = grantedCount + ' of ' + deptFormats.length + ' granted';

        var html = '';
        deptFormats.forEach(function (f) {
            var isOn = f.has_access;
            var toggleCls = isOn ? 'on' : 'off';
            var rowCls = 'bdlcat-format-row' + (isOn ? '' : ' dept-ungranted');
            var selectedCls = (deptSelectedFormatId === f.format_id) ? ' selected' : '';
            var displayName = f.entity_type || f.type_name || '(unknown)';

            var actionBadge = '';
            if (f.action_type && f.action_type !== 'FILE_MAPPED') {
                var badgeCls = f.action_type === 'FIXED_VALUE' ? 'bdlcat-badge-fixed' : 'bdlcat-badge-hybrid';
                actionBadge = ' <span class="' + badgeCls + '">' + f.action_type.replace('_', ' ') + '</span>';
            }

            var fieldStats = '';
            if (isOn && f.config_id) {
                fieldStats = '<span class="bdlcat-stat dept-field-stat">' +
                    (f.granted_field_count || 0) + ' of ' + (f.visible_field_count || 0) + ' fields' +
                    '</span>';
            }

            html += '<div class="' + rowCls + selectedCls + '" data-fid="' + f.format_id + '">' +
                '<div class="bdlcat-format-main" onclick="BdlCatalog.selectDeptFormat(' + f.format_id + ',\'' + esc(displayName) + '\',' + (f.config_id || 'null') + ')">' +
                    '<span class="bdlcat-format-name">' + esc(displayName) + actionBadge + '</span>' +
                    '<span class="bdlcat-format-dots"></span>' +
                    fieldStats +
                '</div>' +
                '<span class="bdlcat-format-toggle" onclick="event.stopPropagation();BdlCatalog.toggleDeptAccess(\'' + esc(f.entity_type) + '\',' + (isOn ? '0' : '1') + ',\'' + esc(displayName) + '\')">' +
                    '<span class="gc-toggle"><span class="gc-toggle-track ' + toggleCls + '"><span class="gc-toggle-knob"></span></span></span>' +
                '</span>' +
            '</div>';
        });

        body.innerHTML = html;
    }

    function toggleDeptAccess(entityType, newState, entityName) {
        if (!selectedDepartment) return;

        var action = newState === 1 ? 'Grant' : 'Revoke';
        var msg = action + ' access to ' + entityName + ' for ' + selectedDepartmentName + '?';

        showConfirm(action + ' Entity Access', msg, action, newState === 1 ? 'safe' : 'danger')
            .then(function (confirmed) {
                if (!confirmed) return;

                fetch('/api/apps-int/bdl-access/toggle', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({
                        entity_type: entityType,
                        department: selectedDepartment,
                        is_active: newState
                    })
                })
                .then(function (r) { return r.json(); })
                .then(function (data) {
                    if (data.Error) {
                        showAlert('Error', data.Error, { iconColor: '#ef4444' });
                        return;
                    }
                    // If we just revoked access and the detail panel is showing fields
                    // for this entity, close it
                    if (newState === 0) {
                        for (var i = 0; i < deptFormats.length; i++) {
                            if (deptFormats[i].entity_type === entityType && deptFormats[i].config_id === deptSelectedConfigId) {
                                closeDetail();
                                break;
                            }
                        }
                    }
                    // Reload the entity list to reflect updated state and new config_id
                    loadDepartmentAccess(selectedDepartment);
                    showStatus('bdlcat-status', data.message, false);
                })
                .catch(function (e) {
                    showAlert('Error', e.message, { iconColor: '#ef4444' });
                });
            });
    }

    function selectDeptFormat(formatId, entityType, configId) {
        if (deptSelectedFormatId === formatId) {
            closeDetail();
            renderDeptFormats();
            return;
        }

        if (!configId) {
            showAlert('Grant Access First', 'Grant entity access to this department before managing field permissions.', { iconColor: '#dcdcaa' });
            return;
        }

        // Check if the entity is actually granted (has_access)
        var fmt = null;
        for (var i = 0; i < deptFormats.length; i++) {
            if (deptFormats[i].format_id === formatId) { fmt = deptFormats[i]; break; }
        }
        if (fmt && !fmt.has_access) {
            showAlert('Grant Access First', 'Grant entity access to this department before managing field permissions.', { iconColor: '#dcdcaa' });
            return;
        }

        deptSelectedFormatId = formatId;
        deptSelectedEntityType = entityType;
        deptSelectedConfigId = configId;
        renderDeptFormats();

        document.getElementById('bdlcat-detail-title').textContent = entityType + ' — Field Access (' + selectedDepartmentName + ')';
        document.getElementById('bdlcat-detail-count').textContent = '';
        document.getElementById('bdlcat-detail-body').innerHTML = '<div class="bdlcat-loading">Loading fields...</div>';
        document.getElementById('bdlcat-detail').classList.add('visible');

        loadDeptFieldAccess(configId);
    }

    // =========================================================================
    // DEPARTMENT MODE — TIER 2: FIELD ACCESS LIST
    // =========================================================================

    function loadDeptFieldAccess(configId) {
        fetch('/api/apps-int/bdl-field-access?config_id=' + configId)
            .then(function (r) { return r.json(); })
            .then(function (data) {
                if (data.Error) {
                    document.getElementById('bdlcat-detail-body').innerHTML = '<div class="bdlcat-error">' + esc(data.Error) + '</div>';
                    return;
                }
                deptFields = Array.isArray(data) ? data : [];
                renderDeptFields();
            })
            .catch(function (e) {
                document.getElementById('bdlcat-detail-body').innerHTML = '<div class="bdlcat-error">' + esc(e.message) + '</div>';
            });
    }

    function renderDeptFields() {
        var body = document.getElementById('bdlcat-detail-body');
        if (deptFields.length === 0) {
            document.getElementById('bdlcat-detail-count').textContent = '';
            body.innerHTML = '<div class="bdlcat-empty">No visible fields found</div>';
            return;
        }

        var grantedCount = 0;
        deptFields.forEach(function (f) { if (f.is_granted) grantedCount++; });
        document.getElementById('bdlcat-detail-count').textContent = grantedCount + ' of ' + deptFields.length + ' granted';

        var html = '<table class="bdlcat-element-table"><thead><tr>' +
            '<th class="bdlcat-th-name">Element Name</th>' +
            '<th class="bdlcat-th-display">Display Name</th>' +
            '<th class="bdlcat-th-toggle">Granted</th>' +
            '<th class="bdlcat-th-desc">Description</th>' +
            '</tr></thead><tbody>';

        deptFields.forEach(function (el) {
            var rowCls = el.is_granted ? '' : ' dimmed';
            html += '<tr class="bdlcat-element-row' + rowCls + '">';

            // Element name (read-only)
            html += '<td class="bdlcat-cell-name">' + esc(el.element_name);
            if (el.is_primary_id) html += ' <span class="bdlcat-badge-pk" title="Primary identifier">PK</span>';
            if (el.lookup_table) html += ' <span class="bdlcat-badge-lookup" title="Lookup: ' + esc(el.lookup_table) + '">LK</span>';
            if (el.is_import_required) html += ' <span class="bdlcat-badge-req" title="Import required">REQ</span>';
            html += '</td>';

            // Display name (read-only in department mode)
            html += '<td class="bdlcat-cell-display">' + (el.display_name ? esc(el.display_name) : '<span class="bdlcat-empty-val">(empty)</span>') + '</td>';

            // Granted toggle
            var toggleCls = el.is_granted ? 'on' : 'off';
            html += '<td class="bdlcat-cell-toggle">' +
                '<span class="bdlcat-toggle-wrap" onclick="BdlCatalog.toggleDeptField(\'' + esc(el.element_name) + '\',' + (el.is_granted ? '0' : '1') + ')">' +
                    '<span class="gc-toggle-track ' + toggleCls + '"><span class="gc-toggle-knob"></span></span>' +
                '</span></td>';

            // Description (read-only in department mode)
            html += '<td class="bdlcat-cell-desc">' + (el.field_description ? esc(el.field_description) : '<span class="bdlcat-empty-val">(empty)</span>') + '</td>';

            html += '</tr>';
        });

        html += '</tbody></table>';
        body.innerHTML = html;
    }

    function toggleDeptField(elementName, newState) {
        if (!deptSelectedConfigId) return;

        fetch('/api/apps-int/bdl-field-access/toggle', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                config_id: deptSelectedConfigId,
                element_name: elementName,
                is_active: newState
            })
        })
        .then(function (r) { return r.json(); })
        .then(function (data) {
            if (data.Error) {
                showAlert('Error', data.Error, { iconColor: '#ef4444' });
                return;
            }
            // Update local state
            for (var i = 0; i < deptFields.length; i++) {
                if (deptFields[i].element_name === elementName) {
                    deptFields[i].is_granted = newState === 1;
                    break;
                }
            }
            renderDeptFields();
            // Update field count in tier 1
            updateDeptFormatFieldCount();
            showStatus('bdlcat-detail-status', data.message, false);
        })
        .catch(function (e) {
            showAlert('Error', e.message, { iconColor: '#ef4444' });
        });
    }

    function updateDeptFormatFieldCount() {
        if (!deptSelectedConfigId) return;
        var grantedCount = 0;
        deptFields.forEach(function (f) { if (f.is_granted) grantedCount++; });
        for (var i = 0; i < deptFormats.length; i++) {
            if (deptFormats[i].config_id === deptSelectedConfigId) {
                deptFormats[i].granted_field_count = grantedCount;
                break;
            }
        }
        renderDeptFormats();
    }

    // =========================================================================
    // GLOBAL MODE — TIER 1: FORMAT LIST
    // =========================================================================

    function loadFormats() {
        fetch('/api/apps-int/bdl-formats')
            .then(function (r) { return r.json(); })
            .then(function (data) {
                if (data.Error) {
                    document.getElementById('bdlcat-body').innerHTML = '<div class="bdlcat-error">' + esc(data.Error) + '</div>';
                    return;
                }
                formats = Array.isArray(data) ? data : [];
                renderFormats();
            })
            .catch(function (e) {
                document.getElementById('bdlcat-body').innerHTML = '<div class="bdlcat-error">Failed to load: ' + esc(e.message) + '</div>';
            });
    }

    function renderFormats() {
        var body = document.getElementById('bdlcat-body');
        if (formats.length === 0) {
            body.innerHTML = '<div class="bdlcat-empty">No BDL formats found</div>';
            document.getElementById('bdlcat-count').textContent = '';
            return;
        }

        var activeCount = 0, inactiveCount = 0;
        formats.forEach(function (f) { if (f.is_active) activeCount++; else inactiveCount++; });
        document.getElementById('bdlcat-count').textContent = activeCount + ' active' + (inactiveCount > 0 ? ', ' + inactiveCount + ' inactive' : '');

        var html = '';
        var active = formats.filter(function (f) { return f.is_active; });
        var inactive = formats.filter(function (f) { return !f.is_active; });

        if (active.length > 0) {
            html += '<div class="bdlcat-section-label">Active Entity Types</div>';
            active.forEach(function (f) { html += renderFormatRow(f); });
        }
        if (inactive.length > 0) {
            html += '<div class="bdlcat-section-label inactive">Inactive Entity Types</div>';
            inactive.forEach(function (f) { html += renderFormatRow(f); });
        }

        body.innerHTML = html;
    }

    function renderFormatRow(f) {
        var isOn = f.is_active;
        var toggleCls = isOn ? 'on' : 'off';
        var rowCls = 'bdlcat-format-row' + (isOn ? '' : ' inactive');
        var selectedCls = (selectedFormatId === f.format_id) ? ' selected' : '';
        var displayName = f.entity_type || f.type_name || '(unknown)';
        var isWrapper = !f.entity_type;
        var wrapperBadge = isWrapper ? ' <span class="bdlcat-badge-wrapper" title="Container/UDP format — no entity_type assigned">WRAPPER</span>' : '';
        var actionBadge = '';
        if (f.action_type && f.action_type !== 'FILE_MAPPED') {
            var badgeCls = f.action_type === 'FIXED_VALUE' ? 'bdlcat-badge-fixed' : 'bdlcat-badge-hybrid';
            actionBadge = ' <span class="' + badgeCls + '" title="Action type: ' + f.action_type + '">' + f.action_type.replace('_', ' ') + '</span>';
        }

        return '<div class="' + rowCls + selectedCls + '" data-fid="' + f.format_id + '">' +
            '<div class="bdlcat-format-main" onclick="BdlCatalog.selectFormat(' + f.format_id + ',\'' + esc(displayName) + '\')">' +
                '<span class="bdlcat-format-name">' + esc(displayName) + wrapperBadge + actionBadge + '</span>' +
                '<span class="bdlcat-format-dots"></span>' +
                '<span class="bdlcat-format-stats">' +
                    '<span class="bdlcat-stat" title="Visible fields">' + f.visible_count + ' vis</span>' +
                    '<span class="bdlcat-stat" title="Required fields">' + f.required_count + ' req</span>' +
                    '<span class="bdlcat-stat" title="Total elements">' + f.actual_element_count + ' total</span>' +
                '</span>' +
            '</div>' +
            '<span class="bdlcat-format-toggle" onclick="event.stopPropagation();BdlCatalog.toggleFormat(' + f.format_id + ',' + (isOn ? '0' : '1') + ',\'' + esc(displayName) + '\')">' +
                '<span class="gc-toggle"><span class="gc-toggle-track ' + toggleCls + '"><span class="gc-toggle-knob"></span></span></span>' +
            '</span>' +
        '</div>';
    }

    function selectFormat(formatId, entityType) {
        if (selectedFormatId === formatId) {
            closeDetail();
            renderFormats();
            return;
        }
        selectedFormatId = formatId;
        selectedFormatName = entityType;
        editingField = null;
        renderFormats();

        document.getElementById('bdlcat-detail-title').textContent = entityType + ' — Elements';
        document.getElementById('bdlcat-detail-count').textContent = '';
        document.getElementById('bdlcat-detail-body').innerHTML = '<div class="bdlcat-loading">Loading elements...</div>';
        document.getElementById('bdlcat-detail').classList.add('visible');

        loadElements(formatId);
    }

    function toggleFormat(formatId, newState, entityType) {
        var action = newState === 1 ? 'Activate' : 'Deactivate';
        var msg = action + ' ' + entityType + '? This will ' + (newState === 1 ? 'make it available' : 'hide it from') + ' BDL Import operations.';

        showConfirm(action + ' Entity Type', msg, action, newState === 1 ? 'safe' : 'danger')
            .then(function (confirmed) {
                if (!confirmed) return;
                fetch('/api/apps-int/bdl-format/toggle', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ format_id: formatId, is_active: newState })
                })
                .then(function (r) { return r.json(); })
                .then(function (data) {
                    if (data.Error) {
                        showAlert('Error', data.Error, { iconColor: '#ef4444' });
                        return;
                    }
                    for (var i = 0; i < formats.length; i++) {
                        if (formats[i].format_id === formatId) {
                            formats[i].is_active = newState === 1;
                            break;
                        }
                    }
                    renderFormats();
                    showStatus('bdlcat-status', data.message, false);
                })
                .catch(function (e) {
                    showAlert('Error', e.message, { iconColor: '#ef4444' });
                });
            });
    }

    // =========================================================================
    // GLOBAL MODE — TIER 2: ELEMENT DETAIL
    // =========================================================================

    function loadElements(formatId) {
        fetch('/api/apps-int/bdl-elements?format_id=' + formatId)
            .then(function (r) { return r.json(); })
            .then(function (data) {
                if (data.Error) {
                    document.getElementById('bdlcat-detail-body').innerHTML = '<div class="bdlcat-error">' + esc(data.Error) + '</div>';
                    return;
                }
                elements = Array.isArray(data) ? data : [];
                renderElements();
            })
            .catch(function (e) {
                document.getElementById('bdlcat-detail-body').innerHTML = '<div class="bdlcat-error">' + esc(e.message) + '</div>';
            });
    }

    function renderElements() {
        var body = document.getElementById('bdlcat-detail-body');
        if (elements.length === 0) {
            document.getElementById('bdlcat-detail-count').textContent = '';
            body.innerHTML = '<div class="bdlcat-empty">No elements found</div>';
            return;
        }

        var visCount = 0, reqCount = 0;
        elements.forEach(function (e) {
            if (e.is_visible) visCount++;
            if (e.is_import_required) reqCount++;
        });
        document.getElementById('bdlcat-detail-count').textContent = elements.length + ' elements \u00B7 ' + visCount + ' visible \u00B7 ' + reqCount + ' required';

        var html = '<table class="bdlcat-element-table"><thead><tr>' +
            '<th class="bdlcat-th-name">Element Name</th>' +
            '<th class="bdlcat-th-display">Display Name</th>' +
            '<th class="bdlcat-th-toggle">Visible</th>' +
            '<th class="bdlcat-th-toggle">Required</th>' +
            '<th class="bdlcat-th-desc">Description</th>' +
            '<th class="bdlcat-th-guidance">Import Guidance</th>' +
            '</tr></thead><tbody>';

        elements.forEach(function (el) {
            var rowCls = el.is_visible ? '' : ' dimmed';
            html += '<tr class="bdlcat-element-row' + rowCls + '" data-eid="' + el.element_id + '">';

            html += '<td class="bdlcat-cell-name">' + esc(el.element_name);
            if (el.is_primary_id) html += ' <span class="bdlcat-badge-pk" title="Primary identifier">PK</span>';
            if (el.lookup_table) html += ' <span class="bdlcat-badge-lookup" title="Lookup: ' + esc(el.lookup_table) + '">LK</span>';
            html += '</td>';

            html += '<td class="bdlcat-cell-display">' + renderEditableText(el, 'display_name', el.display_name) + '</td>';
            html += '<td class="bdlcat-cell-toggle">' + renderToggle(el, 'is_visible', el.is_visible) + '</td>';
            html += '<td class="bdlcat-cell-toggle">' + renderToggle(el, 'is_import_required', el.is_import_required) + '</td>';
            html += '<td class="bdlcat-cell-desc">' + renderEditableText(el, 'field_description', el.field_description) + '</td>';
            html += '<td class="bdlcat-cell-guidance">' + renderEditableText(el, 'import_guidance', el.import_guidance) + '</td>';

            html += '</tr>';
        });

        html += '</tbody></table>';
        body.innerHTML = html;
    }

    function renderEditableText(el, fieldName, value) {
        var isEditing = editingField && editingField.elementId === el.element_id && editingField.fieldName === fieldName;
        if (isEditing) {
            var inputVal = value ? esc(value) : '';
            return '<span class="gc-edit-wrap">' +
                '<input type="text" class="gc-edit-input bdlcat-edit-input" id="bdlcat-edit-' + el.element_id + '-' + fieldName + '" value="' + inputVal + '" ' +
                'onkeydown="if(event.key===\'Enter\')BdlCatalog.saveField(' + el.element_id + ',\'' + fieldName + '\');if(event.key===\'Escape\')BdlCatalog.cancelEdit()">' +
                '<button class="gc-edit-save" onclick="BdlCatalog.saveField(' + el.element_id + ',\'' + fieldName + '\')" title="Save">&#10003;</button>' +
                '<button class="gc-edit-cancel" onclick="BdlCatalog.cancelEdit()" title="Cancel">&#10007;</button>' +
                '</span>';
        }
        var displayVal = value ? esc(value) : '<span class="bdlcat-empty-val">(empty)</span>';
        return '<span class="bdlcat-editable" onclick="BdlCatalog.startEdit(' + el.element_id + ',\'' + fieldName + '\')" title="Click to edit">' + displayVal + '</span>';
    }

    function renderToggle(el, fieldName, isOn) {
        var toggleCls = isOn ? 'on' : 'off';
        return '<span class="bdlcat-toggle-wrap" onclick="BdlCatalog.toggleField(' + el.element_id + ',\'' + fieldName + '\',' + (isOn ? '0' : '1') + ')">' +
            '<span class="gc-toggle-track ' + toggleCls + '"><span class="gc-toggle-knob"></span></span>' +
            '</span>';
    }

    // =========================================================================
    // GLOBAL MODE — INLINE EDITING
    // =========================================================================

    function startEdit(elementId, fieldName) {
        editingField = { elementId: elementId, fieldName: fieldName };
        renderElements();
        var inp = document.getElementById('bdlcat-edit-' + elementId + '-' + fieldName);
        if (inp) { inp.focus(); inp.select(); }
    }

    function cancelEdit() {
        editingField = null;
        renderElements();
    }

    function saveField(elementId, fieldName) {
        var inp = document.getElementById('bdlcat-edit-' + elementId + '-' + fieldName);
        if (!inp) return;

        var newValue = inp.value.trim();
        var el = findElement(elementId);
        if (!el) return;

        var currentValue = el[fieldName] || '';
        if (newValue === currentValue) {
            cancelEdit();
            return;
        }

        doUpdate(elementId, fieldName, newValue);
    }

    function toggleField(elementId, fieldName, newValue) {
        doUpdate(elementId, fieldName, String(newValue));
    }

    function doUpdate(elementId, fieldName, newValue) {
        fetch('/api/apps-int/bdl-elements/update', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ element_id: elementId, field_name: fieldName, new_value: newValue })
        })
        .then(function (r) { return r.json(); })
        .then(function (data) {
            if (data.Error) {
                showAlert('Error', data.Error, { iconColor: '#ef4444' });
                return;
            }
            var el = findElement(elementId);
            if (el) {
                if (fieldName === 'is_visible' || fieldName === 'is_import_required') {
                    el[fieldName] = parseInt(newValue) === 1;
                } else {
                    el[fieldName] = newValue || null;
                }
            }
            editingField = null;
            renderElements();
            updateFormatCounts();
            showStatus('bdlcat-detail-status', data.message, false);
        })
        .catch(function (e) {
            showAlert('Error', e.message, { iconColor: '#ef4444' });
        });
    }

    function updateFormatCounts() {
        if (!selectedFormatId) return;
        var visCount = 0, reqCount = 0;
        elements.forEach(function (e) {
            if (e.is_visible) visCount++;
            if (e.is_import_required) reqCount++;
        });
        for (var i = 0; i < formats.length; i++) {
            if (formats[i].format_id === selectedFormatId) {
                formats[i].visible_count = visCount;
                formats[i].required_count = reqCount;
                break;
            }
        }
        renderFormats();
    }

    // =========================================================================
    // HELPERS
    // =========================================================================

    function findElement(elementId) {
        for (var i = 0; i < elements.length; i++) {
            if (elements[i].element_id === elementId) return elements[i];
        }
        return null;
    }

    function showStatus(elId, msg, isErr) {
        var el = document.getElementById(elId);
        if (!el) return;
        el.textContent = msg;
        el.className = 'bdlcat-status ' + (isErr ? 'error' : 'success');
        if (!isErr) {
            setTimeout(function () {
                if (el) { el.textContent = ''; el.className = 'bdlcat-status'; }
            }, 3000);
        }
    }

    function esc(s) {
        if (!s) return '';
        return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
    }

    // =========================================================================
    // PUBLIC API
    // =========================================================================

    return {
        open: open,
        close: close,
        closeDetail: closeDetail,
        setMode: setMode,
        selectDepartment: selectDepartment,
        selectFormat: selectFormat,
        toggleFormat: toggleFormat,
        selectDeptFormat: selectDeptFormat,
        toggleDeptAccess: toggleDeptAccess,
        toggleDeptField: toggleDeptField,
        startEdit: startEdit,
        cancelEdit: cancelEdit,
        saveField: saveField,
        toggleField: toggleField
    };
})();

// ============================================================================
// xFACts Control Center - Applications & Integration Page JavaScript
// Location: E:\xFACts-ControlCenter\public\js\applications-integration.js
// Version: Tracked in dbo.System_Metadata (component: DeptOps.ApplicationsIntegration)
//
// CHANGELOG
// ---------
// 2026-04-13  Added DmJobs module for Refresh Drools with per-server progress
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
    let selectedDepartment = null;
    let selectedDepartmentName = null;
    let deptFormats = [];
    let deptFields = [];
    let deptSelectedFormatId = null;
    let deptSelectedEntityType = null;
    let deptSelectedConfigId = null;

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
                    if (newState === 0) {
                        for (var i = 0; i < deptFormats.length; i++) {
                            if (deptFormats[i].entity_type === entityType && deptFormats[i].config_id === deptSelectedConfigId) {
                                closeDetail();
                                break;
                            }
                        }
                    }
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
            html += '<td class="bdlcat-cell-name">' + esc(el.element_name);
            if (el.is_primary_id) html += ' <span class="bdlcat-badge-pk" title="Primary identifier">PK</span>';
            if (el.lookup_table) html += ' <span class="bdlcat-badge-lookup" title="Lookup: ' + esc(el.lookup_table) + '">LK</span>';
            if (el.is_import_required) html += ' <span class="bdlcat-badge-req" title="Import required">REQ</span>';
            html += '</td>';
            html += '<td class="bdlcat-cell-display">' + (el.display_name ? esc(el.display_name) : '<span class="bdlcat-empty-val">(empty)</span>') + '</td>';
            var toggleCls = el.is_granted ? 'on' : 'off';
            html += '<td class="bdlcat-cell-toggle">' +
                '<span class="bdlcat-toggle-wrap" onclick="BdlCatalog.toggleDeptField(\'' + esc(el.element_name) + '\',' + (el.is_granted ? '0' : '1') + ')">' +
                    '<span class="gc-toggle-track ' + toggleCls + '"><span class="gc-toggle-knob"></span></span>' +
                '</span></td>';
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
            for (var i = 0; i < deptFields.length; i++) {
                if (deptFields[i].element_name === elementName) {
                    deptFields[i].is_granted = newState === 1;
                    break;
                }
            }
            renderDeptFields();
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
        if (newValue === currentValue) { cancelEdit(); return; }
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

// ============================================================================
// DM JOB TRIGGERS
// Environment-scoped DM scheduled job execution with per-server progress.
// Supports multi-server (Refresh Drools) and single-server with cooldown
// (Release Notices, Balance Sync). Uses xf-modal-* shared modal classes
// from engine-events.css.
// ============================================================================

const DmJobs = (function () {
    'use strict';

    var environments = ['TEST', 'STAGE', 'PROD'];

    function esc(s) {
        if (!s) return '';
        return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
    }

    function formatDmResponse(dmResponse) {
        if (!dmResponse) return '';
        try {
            var parsed = JSON.parse(dmResponse);
            if (parsed.status && parsed.data) return 'DM: ' + parsed.data;
            return 'DM: ' + dmResponse;
        } catch (e) {
            return 'DM: ' + dmResponse;
        }
    }

    // ── Shared Modal Shell ───────────────────────────────────────────────

    function createModal(id, title, icon, iconColor) {
        removeModal(id);
        var overlay = document.createElement('div');
        overlay.id = id;
        overlay.className = 'xf-modal-overlay';
        overlay.innerHTML =
            '<div class="xf-modal" style="max-width:440px;">' +
                '<div class="xf-modal-header">' +
                    '<span class="xf-modal-icon" style="color:' + iconColor + '">' + icon + '</span>' +
                    '<span>' + esc(title) + '</span>' +
                '</div>' +
                '<div class="xf-modal-body" id="' + id + '-body"></div>' +
                '<div class="xf-modal-actions" id="' + id + '-actions"></div>' +
            '</div>';
        document.body.appendChild(overlay);
        return overlay;
    }

    function removeModal(id) {
        var existing = document.getElementById(id);
        if (existing) existing.remove();
    }

    // ── Environment Selection Step ───────────────────────────────────────

    function renderEnvSelection(modalId) {
        var body = document.getElementById(modalId + '-body');
        var actions = document.getElementById(modalId + '-actions');

        var html = '<p style="color:#999;font-size:13px;margin:0 0 14px;">Select target environment:</p>';
        html += '<div class="dmjob-env-buttons">';
        environments.forEach(function (env) {
            var cls = 'dmjob-env-btn dmjob-env-' + env.toLowerCase();
            html += '<button class="' + cls + '" onclick="DmJobs._envSelected(\'' + modalId + '\',\'' + env + '\')">' + env + '</button>';
        });
        html += '</div>';

        body.innerHTML = html;
        actions.innerHTML = '<button class="xf-modal-btn-cancel" onclick="DmJobs._closeModal(\'' + modalId + '\')">Cancel</button>';
    }

    function _envSelected(modalId, env) {
        var modal = document.getElementById(modalId);
        if (modal && modal._envCallback) {
            modal._envCallback(env);
        }
    }

    // ── Confirm Execution (shared) ───────────────────────────────────────

    function _confirmExec(modalId) {
        var modal = document.getElementById(modalId);
        if (!modal || !modal._onConfirm) return;
        var btn = document.getElementById(modalId + '-confirm');
        if (btn) { btn.disabled = true; btn.textContent = 'Executing...'; }
        var actions = document.getElementById(modalId + '-actions');
        if (actions) actions.innerHTML = '';
        modal._onConfirm();
    }

    function _closeModal(modalId) {
        removeModal(modalId);
    }

    // =====================================================================
    // REFRESH DROOLS — Multi-server, no cooldown
    // =====================================================================

    function openRefreshDrools() {
        var modal = createModal('dm-drools-modal', 'Refresh Drools', '&#128260;', '#4ec9b0');
        modal._envCallback = function (env) {
            loadServersAndConfirm('dm-drools-modal', env, 'Refresh business rules on all <strong class="dmjob-env-highlight dmjob-env-' + env.toLowerCase() + '">' + env + '</strong> app servers?', function (servers) {
                executeRefreshDrools(servers, env);
            });
        };
        renderEnvSelection('dm-drools-modal');
    }

    function loadServersAndConfirm(modalId, env, confirmMsg, onConfirm) {
        var body = document.getElementById(modalId + '-body');
        var actions = document.getElementById(modalId + '-actions');

        body.innerHTML = '<div style="text-align:center;color:#888;padding:12px;">Loading servers...</div>';
        actions.innerHTML = '';

        fetch('/api/apps-int/dm-servers?environment=' + encodeURIComponent(env))
            .then(function (r) { return r.json(); })
            .then(function (data) {
                if (data.Error) {
                    body.innerHTML = '<div style="color:#f48771;padding:8px;">' + esc(data.Error) + '</div>';
                    actions.innerHTML = '<button class="xf-modal-btn-cancel" onclick="DmJobs._closeModal(\'' + modalId + '\')">Close</button>';
                    return;
                }

                var servers = data.servers || [];
                if (servers.length === 0) {
                    body.innerHTML = '<div style="color:#dcdcaa;padding:8px;">No tools-enabled servers found for ' + esc(env) + '.</div>';
                    actions.innerHTML = '<button class="xf-modal-btn-cancel" onclick="DmJobs._closeModal(\'' + modalId + '\')">Close</button>';
                    return;
                }

                var html = '<p style="margin:0 0 12px;">' + confirmMsg + '</p>';
                html += '<div class="dmjob-server-list">';
                servers.forEach(function (s) {
                    html += '<div class="dmjob-server-row"><span class="dmjob-server-name">' + esc(s.server_name) + '</span><span class="dmjob-server-status dmjob-status-pending">Pending</span></div>';
                });
                html += '</div>';

                body.innerHTML = html;

                var modal = document.getElementById(modalId);
                if (modal) {
                    modal._onConfirm = function () { onConfirm(servers); };
                }

                actions.innerHTML =
                    '<button class="xf-modal-btn-cancel" onclick="DmJobs._closeModal(\'' + modalId + '\')">Cancel</button>' +
                    '<button class="xf-modal-btn-primary" id="' + modalId + '-confirm" onclick="DmJobs._confirmExec(\'' + modalId + '\')">Refresh (' + servers.length + ' server' + (servers.length > 1 ? 's' : '') + ')</button>';
            })
            .catch(function (err) {
                body.innerHTML = '<div style="color:#f48771;padding:8px;">Failed to load servers: ' + esc(err.message) + '</div>';
                actions.innerHTML = '<button class="xf-modal-btn-cancel" onclick="DmJobs._closeModal(\'' + modalId + '\')">Close</button>';
            });
    }

    function executeRefreshDrools(servers, env) {
        var body = document.getElementById('dm-drools-modal-body');

        var html = '<p style="margin:0 0 10px;color:#999;font-size:13px;">Refreshing Drools on <strong>' + esc(env) + '</strong>...</p>';
        html += '<div class="dmjob-server-list">';
        servers.forEach(function (s, idx) {
            html += '<div class="dmjob-server-row" id="drools-srv-' + idx + '">' +
                '<span class="dmjob-server-name">' + esc(s.server_name) + '</span>' +
                '<span class="dmjob-server-status dmjob-status-pending" id="drools-status-' + idx + '">Pending</span>' +
            '</div>';
        });
        html += '</div>';
        html += '<div id="drools-summary" style="margin-top:12px;"></div>';

        body.innerHTML = html;
        document.getElementById('dm-drools-modal-actions').innerHTML = '';

        droolsNextServer(servers, env, 0, []);
    }

    function droolsNextServer(servers, env, idx, results) {
        if (idx >= servers.length) {
            renderDroolsSummary(results, env);
            return;
        }

        var server = servers[idx];
        var statusEl = document.getElementById('drools-status-' + idx);
        if (statusEl) { statusEl.textContent = 'Executing...'; statusEl.className = 'dmjob-server-status dmjob-status-running'; }

        fetch('/api/apps-int/refresh-drools', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ environment: env, server_name: server.server_name, api_base_url: server.api_base_url })
        })
        .then(function (r) { return r.json().then(function (d) { d._httpStatus = r.status; return d; }); })
        .then(function (data) {
            var success = data._httpStatus < 400 && data.success;
            var dmInfo = data.dm_response ? formatDmResponse(data.dm_response) : '';
            results.push({ server_name: server.server_name, success: success, message: success ? data.message : (data.error || data.Error || 'Unknown error'), dm_response: dmInfo });

            if (statusEl) {
                if (success) {
                    statusEl.innerHTML = '&#10003; Success' + (dmInfo ? ' <span class="dmjob-dm-response">' + esc(dmInfo) + '</span>' : '');
                    statusEl.className = 'dmjob-server-status dmjob-status-success';
                } else {
                    statusEl.innerHTML = '&#10006; Failed';
                    statusEl.className = 'dmjob-server-status dmjob-status-failed';
                }
            }

            droolsNextServer(servers, env, idx + 1, results);
        })
        .catch(function (err) {
            results.push({ server_name: server.server_name, success: false, message: err.message, dm_response: '' });
            if (statusEl) { statusEl.innerHTML = '&#10006; Error'; statusEl.className = 'dmjob-server-status dmjob-status-failed'; }
            droolsNextServer(servers, env, idx + 1, results);
        });
    }

    function renderDroolsSummary(results, env) {
        var summaryEl = document.getElementById('drools-summary');
        var actions = document.getElementById('dm-drools-modal-actions');

        var successCount = results.filter(function (r) { return r.success; }).length;
        var failCount = results.length - successCount;

        var html = '';
        if (failCount === 0) {
            html = '<div class="dmjob-summary-success">&#10003; Drools refreshed on all ' + results.length + ' server' + (results.length > 1 ? 's' : '') + ' (' + esc(env) + ')</div>';
        } else if (successCount === 0) {
            html = '<div class="dmjob-summary-failed">&#10006; Refresh failed on all ' + results.length + ' server' + (results.length > 1 ? 's' : '') + '</div>';
        } else {
            html = '<div class="dmjob-summary-partial">&#9888; ' + successCount + ' succeeded, ' + failCount + ' failed</div>';
        }

        results.forEach(function (r) {
            if (!r.success) {
                html += '<div class="dmjob-error-detail"><strong>' + esc(r.server_name) + ':</strong> ' + esc(r.message) + '</div>';
            }
        });

        if (summaryEl) summaryEl.innerHTML = html;
        if (actions) actions.innerHTML = '<button class="xf-modal-btn-primary" onclick="DmJobs._closeModal(\'dm-drools-modal\')">Close</button>';
    }

    // =====================================================================
    // SINGLE-SERVER JOB — Generic flow with cooldown support
    // Used by Release Notices, Balance Sync, and future single-server jobs
    // =====================================================================

    function executeSingleServerJob(config) {
        var modal = createModal(config.modalId, config.title, config.icon, config.iconColor);
        modal._envCallback = function (env) {
            loadSingleServerConfirm(config, env);
        };
        renderEnvSelection(config.modalId);
    }

    function loadSingleServerConfirm(config, env) {
        var body = document.getElementById(config.modalId + '-body');
        var actions = document.getElementById(config.modalId + '-actions');

        body.innerHTML = '<div style="text-align:center;color:#888;padding:12px;">Checking availability...</div>';
        actions.innerHTML = '';

        Promise.all([
            fetch('/api/apps-int/cooldown-check?job_name=' + encodeURIComponent(config.cooldownKey) + '&environment=' + encodeURIComponent(env)).then(function (r) { return r.json(); }),
            fetch('/api/apps-int/dm-servers?environment=' + encodeURIComponent(env)).then(function (r) { return r.json(); })
        ])
        .then(function (results) {
            var cooldown = results[0];
            var serverData = results[1];

            if (serverData.Error) {
                body.innerHTML = '<div style="color:#f48771;padding:8px;">' + esc(serverData.Error) + '</div>';
                actions.innerHTML = '<button class="xf-modal-btn-cancel" onclick="DmJobs._closeModal(\'' + config.modalId + '\')">Close</button>';
                return;
            }

            var servers = serverData.servers || [];
            if (servers.length === 0) {
                body.innerHTML = '<div style="color:#dcdcaa;padding:8px;">No tools-enabled servers found for ' + esc(env) + '.</div>';
                actions.innerHTML = '<button class="xf-modal-btn-cancel" onclick="DmJobs._closeModal(\'' + config.modalId + '\')">Close</button>';
                return;
            }

            var primaryServer = servers[0];

            var html = '<p style="margin:0 0 12px;">Execute <strong>' + esc(config.title) + '</strong> on <strong class="dmjob-env-highlight dmjob-env-' + env.toLowerCase() + '">' + env + '</strong>?</p>';
            html += '<div class="dmjob-server-list">';
            html += '<div class="dmjob-server-row"><span class="dmjob-server-name">' + esc(primaryServer.server_name) + '</span><span class="dmjob-server-status" style="color:#569cd6;">Primary</span></div>';
            html += '</div>';

            if (cooldown.cooldown_active) {
                var mins = Math.ceil(cooldown.seconds_remaining / 60);
                var lastUser = cooldown.last_executed_by || 'unknown';
                if (lastUser.indexOf('\\') !== -1) lastUser = lastUser.split('\\')[1];
                html += '<div class="dmjob-cooldown-active">';
                html += '<span class="dmjob-cooldown-icon">&#9202;</span> ';
                html += 'Last executed ' + formatTimeAgo(cooldown.last_executed_at) + ' by <strong>' + esc(lastUser) + '</strong>';
                html += '<br>Available in <strong>' + mins + ' minute' + (mins !== 1 ? 's' : '') + '</strong>';
                html += '</div>';
            } else if (cooldown.last_executed_at) {
                var lastUser2 = cooldown.last_executed_by || 'unknown';
                if (lastUser2.indexOf('\\') !== -1) lastUser2 = lastUser2.split('\\')[1];
                html += '<div class="dmjob-cooldown-clear">';
                html += 'Last executed ' + formatTimeAgo(cooldown.last_executed_at) + ' by ' + esc(lastUser2);
                html += '</div>';
            }

            body.innerHTML = html;

            var modal = document.getElementById(config.modalId);
            if (modal) {
                modal._onConfirm = function () { runSingleServerJob(config, env, primaryServer); };
            }

            if (cooldown.cooldown_active) {
                actions.innerHTML = '<button class="xf-modal-btn-cancel" onclick="DmJobs._closeModal(\'' + config.modalId + '\')">Close</button>' +
                    '<button class="xf-modal-btn-primary" disabled title="Cooldown active">Cooldown Active</button>';
            } else {
                actions.innerHTML = '<button class="xf-modal-btn-cancel" onclick="DmJobs._closeModal(\'' + config.modalId + '\')">Cancel</button>' +
                    '<button class="xf-modal-btn-primary" id="' + config.modalId + '-confirm" onclick="DmJobs._confirmExec(\'' + config.modalId + '\')">Execute</button>';
            }
        })
        .catch(function (err) {
            body.innerHTML = '<div style="color:#f48771;padding:8px;">Failed: ' + esc(err.message) + '</div>';
            actions.innerHTML = '<button class="xf-modal-btn-cancel" onclick="DmJobs._closeModal(\'' + config.modalId + '\')">Close</button>';
        });
    }

    function runSingleServerJob(config, env, server) {
        var body = document.getElementById(config.modalId + '-body');

        var html = '<p style="margin:0 0 10px;color:#999;font-size:13px;">Executing <strong>' + esc(config.title) + '</strong> on <strong>' + esc(env) + '</strong>...</p>';
        html += '<div class="dmjob-server-list">';
        html += '<div class="dmjob-server-row"><span class="dmjob-server-name">' + esc(server.server_name) + '</span><span class="dmjob-server-status dmjob-status-running" id="single-job-status">Executing...</span></div>';
        html += '</div>';
        html += '<div id="single-job-summary" style="margin-top:12px;"></div>';

        body.innerHTML = html;

        fetch(config.apiEndpoint, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ environment: env })
        })
        .then(function (r) { return r.json().then(function (d) { d._httpStatus = r.status; return d; }); })
        .then(function (data) {
            var statusEl = document.getElementById('single-job-status');
            var summaryEl = document.getElementById('single-job-summary');
            var actions = document.getElementById(config.modalId + '-actions');
            var success = data._httpStatus < 400 && data.success;

            if (success) {
                var dmInfo = data.dm_response ? formatDmResponse(data.dm_response) : '';
                if (statusEl) {
                    statusEl.innerHTML = '&#10003; Success' + (dmInfo ? ' <span class="dmjob-dm-response">' + esc(dmInfo) + '</span>' : '');
                    statusEl.className = 'dmjob-server-status dmjob-status-success';
                }
                if (summaryEl) summaryEl.innerHTML = '<div class="dmjob-summary-success">&#10003; ' + esc(config.title) + ' completed on ' + esc(server.server_name) + ' (' + esc(env) + ')</div>';
            } else {
                var errMsg = data.error || data.Error || 'Unknown error';
                if (statusEl) { statusEl.innerHTML = '&#10006; Failed'; statusEl.className = 'dmjob-server-status dmjob-status-failed'; }
                if (summaryEl) summaryEl.innerHTML = '<div class="dmjob-summary-failed">&#10006; ' + esc(config.title) + ' failed</div><div class="dmjob-error-detail">' + esc(errMsg) + '</div>';
            }

            if (actions) actions.innerHTML = '<button class="xf-modal-btn-primary" onclick="DmJobs._closeModal(\'' + config.modalId + '\')">Close</button>';
        })
        .catch(function (err) {
            var statusEl = document.getElementById('single-job-status');
            var summaryEl = document.getElementById('single-job-summary');
            var actions = document.getElementById(config.modalId + '-actions');
            if (statusEl) { statusEl.innerHTML = '&#10006; Error'; statusEl.className = 'dmjob-server-status dmjob-status-failed'; }
            if (summaryEl) summaryEl.innerHTML = '<div class="dmjob-summary-failed">&#10006; Request failed</div><div class="dmjob-error-detail">' + esc(err.message) + '</div>';
            if (actions) actions.innerHTML = '<button class="xf-modal-btn-primary" onclick="DmJobs._closeModal(\'' + config.modalId + '\')">Close</button>';
        });
    }

    function formatTimeAgo(dateStr) {
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

    // =====================================================================
    // ENTRY POINTS
    // =====================================================================

    function openReleaseNotices() {
        executeSingleServerJob({
            modalId: 'dm-release-modal',
            title: 'Release Notices',
            icon: '&#128196;',
            iconColor: '#569cd6',
            apiEndpoint: '/api/apps-int/release-notices',
            jobName: 'Release Notices',
            cooldownKey: 'release_notices'
        });
    }

    function openBalanceSync() {
        executeSingleServerJob({
            modalId: 'dm-balance-modal',
            title: 'Balance Sync',
            icon: '&#128176;',
            iconColor: '#dcdcaa',
            apiEndpoint: '/api/apps-int/balance-sync',
            jobName: 'Balance Sync',
            cooldownKey: 'balance_sync'
        });
    }

    return {
        refreshDrools: openRefreshDrools,
        releaseNotices: openReleaseNotices,
        balanceSync: openBalanceSync,
        _envSelected: _envSelected,
        _confirmExec: _confirmExec,
        _closeModal: _closeModal
    };
})();

// ============================================================================
// xFACts Control Center - Applications & Integration Page JavaScript
// Location: E:\xFACts-ControlCenter\public\js\applications-integration.js
// Version: Tracked in dbo.System_Metadata (component: DeptOps.ApplicationsIntegration)
// ============================================================================

// ============================================================================
// BDL CATALOG MANAGEMENT
// Two-tier panel: Slide-up (format list) + Slideout (element detail)
// ============================================================================

const BdlCatalog = (function () {

    let formats = [];
    let elements = [];
    let selectedFormatId = null;
    let selectedFormatName = null;
    let editingField = null;  // { elementId, fieldName }

    // --- Panel Controls ---

    function open() {
        formats = [];
        elements = [];
        selectedFormatId = null;
        selectedFormatName = null;
        editingField = null;
        closeDetail();
        document.getElementById('bdlcat-backdrop').classList.add('visible');
        document.getElementById('bdlcat-panel').classList.add('visible');
        document.getElementById('bdlcat-body').innerHTML = '<div class="bdlcat-loading">Loading BDL formats...</div>';
        document.getElementById('bdlcat-count').textContent = '';
        loadFormats();
    }

    function close() {
        closeDetail();
        document.getElementById('bdlcat-backdrop').classList.remove('visible');
        document.getElementById('bdlcat-panel').classList.remove('visible');
    }

    function closeDetail() {
        document.getElementById('bdlcat-detail').classList.remove('visible');
        selectedFormatId = null;
        selectedFormatName = null;
        editingField = null;
    }

    // --- Format List (Tier 1) ---

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

        // Active formats first
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
            // Toggle off — close detail
            closeDetail();
            renderFormats();
            return;
        }
        selectedFormatId = formatId;
        selectedFormatName = entityType;
        editingField = null;
        renderFormats();

        // Open detail panel and load elements
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
                    // Update local state
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

    // --- Element Detail (Tier 2) ---

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
            '</tr></thead><tbody>';

        elements.forEach(function (el) {
            var rowCls = el.is_visible ? '' : ' dimmed';
            html += '<tr class="bdlcat-element-row' + rowCls + '" data-eid="' + el.element_id + '">';

            // Element name (read-only)
            html += '<td class="bdlcat-cell-name">' + esc(el.element_name);
            if (el.is_primary_id) html += ' <span class="bdlcat-badge-pk" title="Primary identifier">PK</span>';
            if (el.lookup_table) html += ' <span class="bdlcat-badge-lookup" title="Lookup: ' + esc(el.lookup_table) + '">LK</span>';
            html += '</td>';

            // Display name (editable)
            html += '<td class="bdlcat-cell-display">' + renderEditableText(el, 'display_name', el.display_name) + '</td>';

            // is_visible toggle
            html += '<td class="bdlcat-cell-toggle">' + renderToggle(el, 'is_visible', el.is_visible) + '</td>';

            // is_import_required toggle
            html += '<td class="bdlcat-cell-toggle">' + renderToggle(el, 'is_import_required', el.is_import_required) + '</td>';

            // field_description (editable)
            html += '<td class="bdlcat-cell-desc">' + renderEditableText(el, 'field_description', el.field_description) + '</td>';

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

    // --- Inline Editing ---

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
            // Update local state
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
            // Also refresh format counts in tier 1
            updateFormatCounts();
            showStatus('bdlcat-detail-status', data.message, false);
        })
        .catch(function (e) {
            showAlert('Error', e.message, { iconColor: '#ef4444' });
        });
    }

    function updateFormatCounts() {
        // Recalculate counts from local elements data and update the format row
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

    // --- Helpers ---

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
        selectFormat: selectFormat,
        toggleFormat: toggleFormat,
        startEdit: startEdit,
        cancelEdit: cancelEdit,
        saveField: saveField,
        toggleField: toggleField
    };
})();

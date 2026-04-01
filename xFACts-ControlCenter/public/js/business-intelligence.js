/* ============================================================================
   business-intelligence.js — Business Intelligence Departmental Page
   Location: E:\xFACts-ControlCenter\public\js\business-intelligence.js
   
   Loads Notice Recon execution data, renders status cards and step detail.
   
   Version: Tracked in dbo.System_Metadata (component: DeptOps.BusinessIntelligence)
   ============================================================================ */

var BI = (function () {
    'use strict';

    // ── State ────────────────────────────────────────────────────────────
    var selectedExecutionId = null;
    var refreshTimer = null;
    var REFRESH_INTERVAL = 60000; // 60 seconds default

    // ── Initialize ───────────────────────────────────────────────────────
    function init() {
        loadRefreshInterval();
        loadNoticeRecon();
    }

    function loadRefreshInterval() {
        fetch('/api/config/refresh-interval?page=business_intelligence')
            .then(function (r) { return r.json(); })
            .then(function (data) {
                if (data.interval) {
                    REFRESH_INTERVAL = data.interval * 1000;
                }
                startAutoRefresh();
            })
            .catch(function () { startAutoRefresh(); });
    }

    function startAutoRefresh() {
        if (refreshTimer) clearInterval(refreshTimer);
        refreshTimer = setInterval(function () {
            loadNoticeRecon();
        }, REFRESH_INTERVAL);
    }

    // ── Page Refresh ─────────────────────────────────────────────────────
    function pageRefresh() {
        loadNoticeRecon();
    }

    // ── Notice Recon ─────────────────────────────────────────────────────
    function loadNoticeRecon() {
        fetch('/api/business-intelligence/notice-recon')
            .then(function (r) {
                if (!r.ok) throw new Error('HTTP ' + r.status);
                return r.json();
            })
            .then(function (data) {
                hideConnectionError();
                renderNoticeReconCards(data.executions || []);
                updateTimestamp();

                // If we had a selected execution, reload its steps
                if (selectedExecutionId) {
                    loadStepDetail(selectedExecutionId);
                }
            })
            .catch(function (err) {
                showConnectionError('Failed to load Notice Recon data: ' + err.message);
            });
    }

    function renderNoticeReconCards(executions) {
        var container = document.getElementById('nr-cards');
        var loading = document.getElementById('nr-loading');
        var empty = document.getElementById('nr-empty');

        loading.classList.add('hidden');

        if (executions.length === 0) {
            container.classList.add('hidden');
            empty.classList.remove('hidden');
            return;
        }

        empty.classList.add('hidden');
        container.classList.remove('hidden');

        // Expected processes — show placeholder if not yet run today
        var expected = ['SndRight', 'Revspring', 'Validation'];
        var byName = {};
        executions.forEach(function (ex) { byName[ex.process_name] = ex; });

        var html = '';
        expected.forEach(function (name) {
            var ex = byName[name];
            if (ex) {
                html += buildExecCard(ex);
            } else {
                html += buildPendingCard(name);
            }
        });

        // Any unexpected processes (future-proofing)
        executions.forEach(function (ex) {
            if (expected.indexOf(ex.process_name) === -1) {
                html += buildExecCard(ex);
            }
        });

        container.innerHTML = html;

        // Reapply selection
        if (selectedExecutionId) {
            var sel = container.querySelector('[data-exec-id="' + selectedExecutionId + '"]');
            if (sel) sel.classList.add('selected');
        }
    }

    function buildExecCard(ex) {
        var statusClass = getStatusClass(ex.status);
        var badgeClass = statusClass;
        var selected = (ex.execution_id === selectedExecutionId) ? ' selected' : '';
        var timeStr = ex.start_time ? formatTime(ex.start_time) : '';
        var durationStr = ex.duration_seconds !== null ? formatDuration(ex.duration_seconds) : '-';

        return '<div class="nr-card status-' + statusClass + selected + '" '
            + 'data-exec-id="' + ex.execution_id + '" '
            + 'onclick="BI.selectExecution(' + ex.execution_id + ')">'
            + '<div class="nr-card-header">'
            + '<span class="nr-process-name">' + escHtml(ex.process_name) + '</span>'
            + '<span class="nr-status-badge ' + badgeClass + '">' + escHtml(ex.status) + '</span>'
            + '</div>'
            + '<div class="nr-card-metrics">'
            + '<div class="nr-metric"><span class="nr-metric-label">Duration</span><span class="nr-metric-value">' + durationStr + '</span></div>'
            + '<div class="nr-metric"><span class="nr-metric-label">Total Records</span><span class="nr-metric-value">' + formatNumber(ex.total_records) + '</span></div>'
            + '<div class="nr-metric"><span class="nr-metric-label">DM Updates</span><span class="nr-metric-value">' + formatNumber(ex.records_updated_dm) + '</span></div>'
            + '<div class="nr-metric"><span class="nr-metric-label">Documents</span><span class="nr-metric-value">' + formatNumber(ex.records_document) + '</span></div>'
            + '</div>'
            + '<div class="nr-card-time">' + timeStr + '</div>'
            + '</div>';
    }

    function buildPendingCard(name) {
        return '<div class="nr-card status-pending">'
            + '<div class="nr-card-header">'
            + '<span class="nr-process-name">' + escHtml(name) + '</span>'
            + '<span class="nr-status-badge" style="color:#666;">Pending</span>'
            + '</div>'
            + '<div class="nr-card-metrics">'
            + '<div class="nr-metric"><span class="nr-metric-label">Status</span><span class="nr-metric-value" style="color:#666;">Not yet run today</span></div>'
            + '</div>'
            + '</div>';
    }

    // ── Step Detail ──────────────────────────────────────────────────────
    function selectExecution(execId) {
        // Toggle selection
        if (selectedExecutionId === execId) {
            selectedExecutionId = null;
            clearSelection();
            clearStepDetail();
            return;
        }

        selectedExecutionId = execId;
        highlightSelected(execId);
        loadStepDetail(execId);
    }

    function loadStepDetail(execId) {
        var subtitle = document.getElementById('nr-detail-subtitle');
        subtitle.textContent = 'Loading steps...';

        fetch('/api/business-intelligence/notice-recon-steps?execution_id=' + execId)
            .then(function (r) {
                if (!r.ok) throw new Error('HTTP ' + r.status);
                return r.json();
            })
            .then(function (data) {
                renderStepDetail(data.steps || []);
            })
            .catch(function (err) {
                subtitle.textContent = 'Failed to load steps: ' + err.message;
            });
    }

    function renderStepDetail(steps) {
        var container = document.getElementById('nr-steps');
        var subtitle = document.getElementById('nr-detail-subtitle');

        if (steps.length === 0) {
            container.innerHTML = '';
            subtitle.textContent = 'No steps found for this execution';
            return;
        }

        subtitle.textContent = steps.length + ' steps';

        var html = '<table class="nr-step-table">'
            + '<thead><tr>'
            + '<th>#</th><th>Step</th><th>Status</th><th>Duration</th><th>Rows</th><th>Message</th>'
            + '</tr></thead><tbody>';

        steps.forEach(function (step) {
            var statusClass = getStatusClass(step.status);
            var durationStr = step.duration_seconds > 0 ? step.duration_seconds + 's' : '<1s';
            var rowsStr = step.rows_affected !== null ? formatNumber(step.rows_affected) : '-';
            var msgStr = step.message || '';
            if (step.error_message) {
                msgStr = '<span style="color:#ef5350;">' + escHtml(step.error_message) + '</span>';
            } else {
                msgStr = escHtml(msgStr);
            }

            html += '<tr>'
                + '<td>' + step.step_number + '</td>'
                + '<td>' + escHtml(step.step_name) + '</td>'
                + '<td><span class="step-status ' + statusClass + '">' + escHtml(step.status) + '</span></td>'
                + '<td>' + durationStr + '</td>'
                + '<td>' + rowsStr + '</td>'
                + '<td class="step-message">' + msgStr + '</td>'
                + '</tr>';
        });

        html += '</tbody></table>';
        container.innerHTML = html;
    }

    function clearStepDetail() {
        document.getElementById('nr-steps').innerHTML = '';
        document.getElementById('nr-detail-subtitle').textContent = 'Click a process card above to view steps';
    }

    // ── Card Selection ───────────────────────────────────────────────────
    function highlightSelected(execId) {
        var cards = document.querySelectorAll('.nr-card');
        cards.forEach(function (c) { c.classList.remove('selected'); });
        var sel = document.querySelector('[data-exec-id="' + execId + '"]');
        if (sel) sel.classList.add('selected');
    }

    function clearSelection() {
        var cards = document.querySelectorAll('.nr-card');
        cards.forEach(function (c) { c.classList.remove('selected'); });
    }

    // ── Helpers ──────────────────────────────────────────────────────────
    function getStatusClass(status) {
        if (!status) return 'pending';
        switch (status.toLowerCase()) {
            case 'success': return 'success';
            case 'warning': return 'warning';
            case 'error': case 'failed': return 'error';
            case 'running': return 'running';
            default: return 'pending';
        }
    }

    function formatTime(isoStr) {
        if (!isoStr) return '';
        var d = new Date(isoStr);
        var h = d.getHours();
        var m = d.getMinutes();
        var ampm = h >= 12 ? 'PM' : 'AM';
        h = h % 12 || 12;
        return h + ':' + (m < 10 ? '0' : '') + m + ' ' + ampm;
    }

    function formatDuration(seconds) {
        if (seconds < 60) return seconds + 's';
        var m = Math.floor(seconds / 60);
        var s = seconds % 60;
        return m + 'm ' + s + 's';
    }

    function formatNumber(n) {
        if (n === null || n === undefined) return '-';
        return n.toLocaleString();
    }

    function escHtml(str) {
        if (!str) return '';
        var div = document.createElement('div');
        div.appendChild(document.createTextNode(str));
        return div.innerHTML;
    }

    function updateTimestamp() {
        var el = document.getElementById('last-update');
        if (el) {
            var now = new Date();
            var h = now.getHours();
            var m = now.getMinutes();
            var s = now.getSeconds();
            var ampm = h >= 12 ? 'PM' : 'AM';
            h = h % 12 || 12;
            el.textContent = h + ':' + (m < 10 ? '0' : '') + m + ':' + (s < 10 ? '0' : '') + s + ' ' + ampm;
        }
    }

    function showConnectionError(msg) {
        var el = document.getElementById('connection-error');
        el.textContent = msg;
        el.style.display = 'block';
    }

    function hideConnectionError() {
        var el = document.getElementById('connection-error');
        el.style.display = 'none';
    }

    // ── Init on load ─────────────────────────────────────────────────────
    init();

    // ── Public API ───────────────────────────────────────────────────────
    return {
        pageRefresh: pageRefresh,
        selectExecution: selectExecution
    };

})();

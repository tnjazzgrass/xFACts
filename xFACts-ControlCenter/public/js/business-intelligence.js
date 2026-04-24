/* ============================================================================
   business-intelligence.js — Business Intelligence Departmental Page
   Location: E:\xFACts-ControlCenter\public\js\business-intelligence.js
   
   Renders the Notice Recon tile with per-process status badges and opens
   a detail slideout when a badge is clicked. To enable a planned process,
   flip its `active` flag to true in NR_PROCESSES.
   
   Version: Tracked in dbo.System_Metadata (component: DeptOps.BusinessIntelligence)
   ============================================================================ */

var BI = (function () {
    'use strict';

    // ── Process Configuration ────────────────────────────────────────────
    // Listed in display order left-to-right. Flip `active` to true when
    // a planned process goes live; no other code changes required.
    var NR_PROCESSES = [
        { name: 'SndRight',   active: true },
        { name: 'Revspring',  active: true },
        { name: 'Validation', active: true },
        { name: 'FAND',       active: false }
    ];

    // ── State ────────────────────────────────────────────────────────────
    var refreshTimer = null;
    var REFRESH_INTERVAL = 60000; // 60 seconds default
    var executionsByName = {};    // Today's executions keyed by process_name
    var executionsById = {};      // Same data keyed by execution_id (slideout lookup)

    // ── Initialize ───────────────────────────────────────────────────────
    function init() {
        renderBadgeSkeleton();
        loadRefreshInterval();
        loadNoticeRecon();

        // Close slideout on Escape
        document.addEventListener('keydown', function (e) {
            if (e.key === 'Escape') closeDetail();
        });
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
                updateBadges(data.executions || []);
                updateTimestamp();
            })
            .catch(function (err) {
                showConnectionError('Failed to load Notice Recon data: ' + err.message);
            });
    }

    // Render the initial badge row with all processes in 'pending' state.
    // Applied once on init so the tile has its final layout immediately,
    // before the first API response arrives.
    function renderBadgeSkeleton() {
        var container = document.getElementById('nr-badges');
        if (!container) return;

        var html = '';
        NR_PROCESSES.forEach(function (p) {
            var extraClass = p.active ? '' : ' future';
            html += '<div class="nr-badge pending' + extraClass + '" '
                  + 'data-process="' + escAttr(p.name) + '" '
                  + 'onclick="BI.openDetail(\'' + escAttr(p.name) + '\')">'
                  + escHtml(p.name)
                  + '</div>';
        });
        container.innerHTML = html;
    }

    // Update badge colors and internal state caches from the executions list.
    function updateBadges(executions) {
        // Rebuild lookup caches
        executionsByName = {};
        executionsById = {};
        executions.forEach(function (ex) {
            executionsByName[ex.process_name] = ex;
            executionsById[ex.execution_id] = ex;
        });

        // Update badge state classes in place (no re-render = no flicker)
        var container = document.getElementById('nr-badges');
        if (!container) return;

        NR_PROCESSES.forEach(function (p) {
            var badge = container.querySelector('[data-process="' + cssEscape(p.name) + '"]');
            if (!badge) return;

            var ex = executionsByName[p.name];
            var statusClass = ex ? getStatusClass(ex.status) : 'pending';

            // Reset classes and apply the current status
            badge.className = 'nr-badge ' + statusClass + (p.active ? '' : ' future');
        });
    }

    // ── Detail Slideout ──────────────────────────────────────────────────
    // Accepts either an execution_id (number) or a process_name (string).
    // Badge clicks pass the process name; this resolves to the execution.
    function openDetail(processNameOrId) {
        var ex = null;
        var processName = null;
        var procConfig = null;

        if (typeof processNameOrId === 'string') {
            processName = processNameOrId;
            ex = executionsByName[processName] || null;
            procConfig = NR_PROCESSES.filter(function (p) { return p.name === processName; })[0] || null;
        } else {
            ex = executionsById[processNameOrId] || null;
            if (ex) processName = ex.process_name;
        }

        var title = document.getElementById('nr-detail-title');
        var content = document.getElementById('nr-detail-content');
        var overlay = document.getElementById('nr-detail-overlay');
        var panel = document.getElementById('nr-detail-panel');

        title.textContent = (processName || 'Notice Recon') + ' — Execution Detail';

        if (ex) {
            content.innerHTML = renderSummary(ex)
                + '<div class="slideout-section">'
                + '<div class="slideout-section-title">Steps</div>'
                + '<div id="nr-detail-steps" class="loading">Loading steps...</div>'
                + '</div>';

            fetch('/api/business-intelligence/notice-recon-steps?execution_id=' + ex.execution_id)
                .then(function (r) {
                    if (!r.ok) throw new Error('HTTP ' + r.status);
                    return r.json();
                })
                .then(function (data) {
                    renderSteps(data.steps || []);
                })
                .catch(function (err) {
                    var stepsEl = document.getElementById('nr-detail-steps');
                    if (stepsEl) stepsEl.innerHTML = '<div class="slideout-empty">Failed to load steps: ' + escHtml(err.message) + '</div>';
                });
        } else {
            // No execution for this process today
            var message = (procConfig && !procConfig.active)
                ? 'This process has not yet been deployed.'
                : 'This process has not yet run today.';
            content.innerHTML = '<div class="slideout-empty">' + escHtml(message) + '</div>';
        }

        overlay.classList.add('open');
        panel.classList.add('open');
    }

    function closeDetail() {
        var overlay = document.getElementById('nr-detail-overlay');
        var panel = document.getElementById('nr-detail-panel');
        if (overlay) overlay.classList.remove('open');
        if (panel) panel.classList.remove('open');
    }

    function renderSummary(ex) {
        var statusClass = getStatusClass(ex.status);
        var durationStr = ex.duration_seconds !== null ? formatDuration(ex.duration_seconds) : '-';
        var timeStr = ex.start_time ? formatTime(ex.start_time) : '-';

        return '<div class="slideout-summary">'
            + '<div class="slideout-stat">'
            + '<div class="slideout-stat-value"><span class="nr-status-pill ' + statusClass + '">' + escHtml(ex.status) + '</span></div>'
            + '<div class="slideout-stat-label">Status</div>'
            + '</div>'
            + '<div class="slideout-stat">'
            + '<div class="slideout-stat-value">' + durationStr + '</div>'
            + '<div class="slideout-stat-label">Duration</div>'
            + '</div>'
            + '<div class="slideout-stat">'
            + '<div class="slideout-stat-value">' + formatNumber(ex.total_records) + '</div>'
            + '<div class="slideout-stat-label">Total Records</div>'
            + '</div>'
            + '<div class="slideout-stat">'
            + '<div class="slideout-stat-value">' + formatNumber(ex.records_updated_dm) + '</div>'
            + '<div class="slideout-stat-label">DM Updates</div>'
            + '</div>'
            + '<div class="slideout-stat">'
            + '<div class="slideout-stat-value">' + timeStr + '</div>'
            + '<div class="slideout-stat-label">Start Time</div>'
            + '</div>'
            + '</div>';
    }

    function renderSteps(steps) {
        var container = document.getElementById('nr-detail-steps');
        if (!container) return;

        if (steps.length === 0) {
            container.innerHTML = '<div class="slideout-empty">No steps found for this execution</div>';
            return;
        }

        container.classList.remove('loading');

        var html = '<table class="slideout-table">'
            + '<thead><tr>'
            + '<th>#</th><th>Step</th><th>Status</th><th>Duration</th><th class="align-right">Rows</th><th>Message</th>'
            + '</tr></thead><tbody>';

        steps.forEach(function (step) {
            var statusClass = getStatusClass(step.status);
            var durationStr = step.duration_seconds > 0 ? step.duration_seconds + 's' : '<1s';
            var rowsStr = step.rows_affected !== null ? formatNumber(step.rows_affected) : '-';
            var msgStr;
            if (step.error_message) {
                msgStr = '<span style="color:#ef5350;">' + escHtml(step.error_message) + '</span>';
            } else {
                msgStr = escHtml(step.message || '');
            }

            html += '<tr>'
                + '<td>' + step.step_number + '</td>'
                + '<td>' + escHtml(step.step_name) + '</td>'
                + '<td><span class="nr-status-pill ' + statusClass + '">' + escHtml(step.status) + '</span></td>'
                + '<td>' + durationStr + '</td>'
                + '<td class="align-right">' + rowsStr + '</td>'
                + '<td>' + msgStr + '</td>'
                + '</tr>';
        });

        html += '</tbody></table>';
        container.innerHTML = html;
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

    // For use in HTML attribute values (inside double quotes).
    function escAttr(str) {
        if (!str) return '';
        return String(str).replace(/&/g, '&amp;').replace(/"/g, '&quot;');
    }

    // Escape a value for safe use inside a querySelector attribute selector.
    function cssEscape(str) {
        if (window.CSS && typeof window.CSS.escape === 'function') {
            return window.CSS.escape(str);
        }
        // Minimal fallback for older browsers
        return String(str).replace(/([^a-zA-Z0-9_-])/g, '\\$1');
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
        openDetail: openDetail,
        closeDetail: closeDetail
    };

})();

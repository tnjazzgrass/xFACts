/* ============================================================================
   xFACts Control Center - Platform Monitoring JavaScript
   Location: E:\xFACts-ControlCenter\public\js\platform-monitoring.js
   Version: Tracked in dbo.System_Metadata (component: ControlCenter.Platform)
   ============================================================================ */

// ============================================================================
// REFRESH ARCHITECTURE (Shared plumbing)
// ============================================================================

// ENGINE_PROCESSES: maps orchestrator process names to card slugs.
// Empty -- no engine cards on this page. Plumbing ready for future use.
var ENGINE_PROCESSES = {};

// Midnight rollover check
var pageLoadDate = new Date().toDateString();
setInterval(function() {
    if (new Date().toDateString() !== pageLoadDate) window.location.reload();
}, 60000);

// Engine-events hooks (called by engine-events.js)
function onEngineProcessCompleted(processName, event) {
    // No event-driven sections on this page
}

// ============================================================================
// PLATFORM MONITORING
// ============================================================================

var PM = (function() {

    var currentServer = 'all';
    var currentRange = '1h';

// Page hooks for engine-events.js shared module
function onPageResumed() { pageRefresh(); }
function onSessionExpired() { }

    var customFrom = null;
    var customTo = null;
    var trendChart = null;
    var gaugeChart = null;
    var miniGaugeCharts = {};
    var processData = [];
    var sortCol = 'total_cpu_ms';
    var sortDir = 'desc';
    var serverImpactData = null;
    var summaryCardData = null;
    var allServersCache = null;

    function init() {
        refreshAll();
        connectEngineEvents();
        initEngineCardClicks();
    }

    function pageRefresh() {
        var btn = document.querySelector('.page-refresh-btn');
        if (btn) {
            btn.classList.add('spinning');
            btn.addEventListener('animationend', function() {
                btn.classList.remove('spinning');
            }, { once: true });
        }
        refreshAll();
    }

    function refreshAll() {
        loadImpactSummary();
        loadSummaryCards();
        loadTrend();
        loadProcessBreakdown();
        loadApiPerformance();
        setText('last-update', new Date().toLocaleTimeString());
    }

    function buildParams() {
        var p = 'server=' + encodeURIComponent(currentServer);
        if (customFrom && customTo) p += '&range=custom&from=' + customFrom + '&to=' + customTo;
        else p += '&range=' + currentRange;
        return p;
    }

    function showError(msg) { var el = document.getElementById('connection-error'); el.textContent = msg; el.classList.add('visible'); }
    function clearError() { document.getElementById('connection-error').classList.remove('visible'); }

    // ========================================================================
    // SERVER SELECTION — via mini gauges and ALL pill
    // ========================================================================
    function selectServer(name) {
        // Clicking the already-selected server toggles back to ALL
        if (name !== 'all' && currentServer === name) {
            name = 'all';
        }
        currentServer = name;

        // Update ALL pill
        var allPill = document.getElementById('srv-all');
        if (allPill) allPill.classList.toggle('active', name === 'all');

        // Update mini gauge highlights
        document.querySelectorAll('.pm-mini-gauge').forEach(function(g) {
            g.classList.toggle('selected', g.getAttribute('data-server') === name);
        });

        // Update hero label
        var serverEl = document.getElementById('gauge-server');
        if (serverEl) serverEl.textContent = name === 'all' ? 'ALL SERVERS' : name;

        refreshAll();
    }

    // ========================================================================
    // TIME
    // ========================================================================
    function setRange(range) {
        currentRange = range; customFrom = null; customTo = null;
        document.querySelectorAll('.pm-time-btn').forEach(function(b) {
            b.classList.toggle('active', b.getAttribute('data-range') === range);
        });
        refreshAll();
    }
    function openDateModal() {
        var today = new Date(); var wa = new Date(today.getTime() - 7*86400000);
        document.getElementById('date-from').value = fmtDate(wa);
        document.getElementById('date-to').value = fmtDate(today);
        document.getElementById('date-modal-overlay').classList.add('open');
    }
    function closeDateModal() { document.getElementById('date-modal-overlay').classList.remove('open'); }
    function applyCustomRange() {
        var f = document.getElementById('date-from').value, t = document.getElementById('date-to').value;
        if (!f || !t) { alert('Please select both dates'); return; }
        if (f > t) { alert('From must be before To'); return; }
        customFrom = f; customTo = t;
        document.querySelectorAll('.pm-time-btn').forEach(function(b) { b.classList.remove('active'); });
        document.querySelector('.pm-time-btn[data-range="custom"]').classList.add('active');
        closeDateModal(); refreshAll();
    }
    function fmtDate(d) { return d.getFullYear() + '-' + String(d.getMonth()+1).padStart(2,'0') + '-' + String(d.getDate()).padStart(2,'0'); }

    // ========================================================================
    // NARRATIVE SUMMARY STRIP
    // ========================================================================
    function updateNarrative() {
        if (!serverImpactData) return;
        var agg = serverImpactData.aggregate;
        var textEl = document.getElementById('narrative-text');
        var accentEl = document.querySelector('.pm-narrative-accent');
        if (!textEl || !accentEl) return;

        var pct = agg.cpu_pct;
        var queries = agg.total_queries || 0;
        var cpuMs = agg.total_cpu_ms || 0;

        // Time range label
        var rangeLabel;
        if (customFrom && customTo) {
            rangeLabel = customFrom + ' to ' + customTo;
        } else {
            rangeLabel = { '1h': 'the last hour', '12h': 'the last 12 hours', '24h': 'the last 24 hours', '7d': 'the last 7 days' }[currentRange] || 'the selected period';
        }

        // Server label
        var serverLabel = currentServer === 'all' ? 'across all servers' : 'on ' + currentServer;

        // Color class
        var colorCls = 'green';
        if (pct !== null && pct !== undefined) {
            if (pct >= 5) colorCls = 'red';
            else if (pct >= 2) colorCls = 'yellow';
        }
        accentEl.className = 'pm-narrative-accent ' + colorCls;

        // Null/no data case
        if (pct === null || pct === undefined) {
            textEl.innerHTML = 'Insufficient data for ' + rangeLabel + ' ' + serverLabel + '. Extended Events data may not be available for this period.';
            return;
        }

        // Build narrative
        var parts = [];

        // Main statement
        parts.push('Over <strong>' + rangeLabel + '</strong>, xFACts executed <span class="nar-highlight">' + fmtCompact(queries) + ' queries</span> consuming <span class="nar-' + colorCls + '">' + pct.toFixed(2) + '%</span> of total server CPU capacity ' + serverLabel + ' (' + fmtMs(cpuMs) + ' CPU time).');

        // Heaviest process
        if (processData && processData.length > 0) {
            var top = processData[0];
            var topName = top.process_name || '';
            // Strip "xFACts " prefix for readability
            if (topName.indexOf('xFACts ') === 0) topName = topName.substring(7);
            parts.push('Heaviest process: <span class="nar-highlight">' + esc(topName) + '</span> (' + fmtMs(top.total_cpu_ms) + ' CPU).');
        }

        // Alert conditions
        if (summaryCardData) {
            var alerts = [];
            var blockedBy = summaryCardData.blocked_by_others || 0;
            var causedBy = summaryCardData.caused_by_xfacts || 0;
            if (blockedBy > 0) alerts.push('xFACts was blocked ' + blockedBy + ' time' + (blockedBy !== 1 ? 's' : '') + ' by other processes');
            if (causedBy > 0) alerts.push('xFACts caused ' + causedBy + ' blocking event' + (causedBy !== 1 ? 's' : ''));
            if (summaryCardData.lrq_crossovers > 0) alerts.push(summaryCardData.lrq_crossovers + ' long-running quer' + (summaryCardData.lrq_crossovers !== 1 ? 'ies' : 'y'));
            if (summaryCardData.open_transactions > 0) alerts.push(summaryCardData.open_transactions + ' open transaction' + (summaryCardData.open_transactions !== 1 ? 's' : ''));

            if (alerts.length > 0) {
                parts.push('<span class="nar-red">Attention:</span> ' + alerts.join(', ') + ' detected.');
            } else {
                parts.push('No blocking events, long-running queries, or open transactions detected.');
            }
        }

        textEl.innerHTML = parts.join(' ');
    }

    // ========================================================================
    // INFO MODAL — plain-English explanations for every metric
    // ========================================================================
    var INFO = {
        'cpu-impact': {
            title: 'CPU Impact',
            body: '<p>This is the headline number for the entire page. It answers: <strong>"What percentage of the server\'s total processing capacity did xFACts use?"</strong></p>' +
                '<p><strong>How it\'s calculated:</strong> xFACts CPU time \u00F7 Total CPU capacity. Total capacity = number of CPU cores \u00D7 time period \u00D7 1,000 (converting to milliseconds). This is the same model used by Windows Task Manager \u2014 a process using 5% means 5% of the machine\'s total horsepower, regardless of what else is running.</p>' +
                '<p>For example, a 16-core server over 1 hour has 57,600,000ms of total CPU capacity (16 \u00D7 3,600 \u00D7 1,000). If xFACts consumed 60,000ms of CPU time during that hour, the result is 0.10%.</p>' +
                '<div class="info-thresholds">' +
                    '<span><span class="info-green">\u25CF Under 2%</span> \u2014 Minimal impact. xFACts is virtually invisible.</span>' +
                    '<span><span class="info-yellow">\u25CF 2% \u2013 5%</span> \u2014 Moderate. Worth monitoring but unlikely to affect users.</span>' +
                    '<span><span class="info-red">\u25CF Over 5%</span> \u2014 Elevated. Investigate which processes are consuming resources.</span>' +
                '</div>' +
                '<p>If someone asks <em>"is your system causing slowdowns?"</em>, this number is the answer.</p>'
        },
        'perf-section': {
            title: 'Platform Performance',
            body: '<p>This section measures the database activity generated by xFACts processes \u2014 the monitoring scripts, data collectors, and automation jobs that run on schedule.</p>' +
                '<p>These metrics are derived from Extended Events (XE) and Dynamic Management Views (DMVs) on each monitored server. They reflect only xFACts activity, not total server activity.</p>' +
                '<p>The three metrics on the bottom row (<span class="info-label">Blocking Events</span>, <span class="info-label">LRQ Crossovers</span>, <span class="info-label">Open Transactions</span>) are alert indicators \u2014 they show <span class="info-green">green 0</span> when healthy and <span class="info-red">red</span> when attention is needed.</p>'
        },
        'active-sessions': {
            title: 'Active Sessions',
            body: '<p>How many xFACts processes have active connections to the database right now. This is a <strong>real-time snapshot</strong>, not a time-range total.</p>' +
                '<p>Think of it like "how many xFACts workers are currently clocked in." A handful is normal \u2014 these are the monitoring and collection scripts that run on schedule.</p>'
        },
        'total-queries': {
            title: 'Total Queries',
            body: '<p>The total number of SQL queries xFACts executed during the selected time range. This includes everything \u2014 data collection, alert checks, API responses, health checks.</p>' +
                '<p>A high number by itself is not concerning. What matters is how much CPU those queries consumed, which is what the CPU Impact gauge shows. Thousands of lightweight queries can have less impact than a single heavy one.</p>'
        },
        'avg-duration': {
            title: 'Average Duration (ms)',
            body: '<p>The average time each xFACts query took to complete, in milliseconds. Lower is better.</p>' +
                '<p>A value under 10ms means xFACts queries are executing almost instantly. If this climbs significantly, it could indicate the server is under pressure from other workloads (not necessarily from xFACts itself).</p>'
        },
        'blocking-events': {
            title: 'Blocking Events',
            body: '<p>This card shows two separate counts of blocking events involving xFACts during the selected time range:</p>' +
                '<p><span class="info-label">Blocked by others</span> \u2014 How many times an xFACts process had to wait because another process (like a Debt Manager query or user report) was holding a lock. This means xFACts was the <em>victim</em> \u2014 it was slowed down, but it didn\'t cause problems for anyone else.</p>' +
                '<p><span class="info-label">Caused by xFACts</span> \u2014 How many times an xFACts process held a lock that blocked a <em>non-xFACts</em> process. This is the more important number \u2014 it means xFACts was causing another application or user to wait.</p>' +
                '<p><span class="info-green">Zero for both is the goal.</span> Occasional blocking is normal in busy databases, but a sustained pattern in "caused by xFACts" would need investigation.</p>'
        },
        'lrq-crossovers': {
            title: 'LRQ Crossovers',
            body: '<p>"Long-Running Query" crossovers \u2014 the number of xFACts queries that exceeded the configured duration threshold (tracked by Extended Events).</p>' +
                '<p>Think of this as a speed trap: queries that ran longer than expected. <span class="info-green">Zero means all xFACts queries finished quickly.</span> A nonzero value doesn\'t necessarily mean a problem \u2014 it could be a one-time slow query during a busy period \u2014 but a pattern would warrant attention.</p>'
        },
        'open-transactions': {
            title: 'Open Transactions',
            body: '<p>The number of xFACts database connections that currently have an uncommitted transaction. This is a <strong>real-time snapshot</strong>.</p>' +
                '<p><span class="info-green">Zero is normal.</span> An open transaction holds locks that can block other queries, so a persistent nonzero value here would be a concern worth investigating.</p>'
        },
        'api-section': {
            title: 'Control Center API',
            body: '<p>This section measures the performance of the Control Center web interface itself \u2014 the dashboards, pages, and API endpoints you\'re using right now.</p>' +
                '<p>These metrics come from the API Request Log and reflect how quickly the web server responds when someone opens a dashboard page. They are <strong>separate from database monitoring activity</strong> \u2014 this is about the UI, not the background processes.</p>'
        },
        'api-requests': {
            title: 'API Requests',
            body: '<p>Total number of HTTP requests the Control Center handled during the selected time range. Every time a dashboard page loads or auto-refreshes, it makes several API calls to fetch data.</p>' +
                '<p>This is a measure of how much the Control Center UI is being used, not a performance concern.</p>'
        },
        'api-rpm': {
            title: 'API Requests Per Minute',
            body: '<p>Average requests per minute to the Control Center. Gives a sense of how active the UI is.</p>' +
                '<p>Higher numbers usually just mean more people have dashboards open, since each open page auto-refreshes on a timer (typically every 5\u201360 seconds depending on the page).</p>'
        },
        'api-avg': {
            title: 'API Average Response (ms)',
            body: '<p>The average time the Control Center took to respond to an API request, in milliseconds.</p>' +
                '<p>This measures the <strong>web server\'s responsiveness</strong>, not database performance. Under 50ms means pages load and refresh instantly. If this climbs, it could indicate the Pode web server is under load or a specific query behind an API endpoint is slow.</p>'
        },
        'api-p95': {
            title: 'API P95 Response (ms)',
            body: '<p>The <strong>95th percentile</strong> response time \u2014 meaning 95% of all API requests completed faster than this value.</p>' +
                '<p>This is more useful than the average because it reveals the "worst typical experience." If the average is 7ms but the P95 is 200ms, it means most requests are fast but 1 in 20 is noticeably slower.</p>' +
                '<p>A low P95 means consistently fast performance with no outlier spikes.</p>'
        },
        'api-users': {
            title: 'API Users',
            body: '<p>The number of distinct users who accessed the Control Center during the selected time range.</p>' +
                '<p>Helps gauge adoption \u2014 are people actually using the dashboards?</p>'
        },
        'api-errors': {
            title: 'API Errors',
            body: '<p>API requests that returned an error (HTTP status 400 or higher). <span class="info-green">Zero is the goal.</span></p>' +
                '<p>Errors could indicate a bug in an API endpoint, a database connectivity issue, or a permissions problem. Any nonzero value here is worth investigating.</p>'
        },
        'process-breakdown': {
            title: 'Process Breakdown',
            body: '<p>A ranked list of every xFACts process that ran queries during the selected time range.</p>' +
                '<p>The <span class="info-label">% xFACts</span> column shows each process\'s share of total xFACts CPU \u2014 useful for comparing which processes are the heaviest <strong>relative to each other</strong>.</p>' +
                '<p>The <span class="info-label">% Server</span> column puts it in real-world context \u2014 what percentage of the server\'s total CPU did this individual process consume. When every row shows values like 0.07%, 0.02%, 0.01%, that\'s a clear indicator that xFACts processes are not contributing to performance issues.</p>' +
                '<p>Hover over any row to see a plain-English summary combining both perspectives.</p>' +
                '<p>Other columns: <strong>Qry</strong> = query count, <strong>CPU</strong> = total CPU time, <strong>Avg</strong> = average query duration, <strong>Reads</strong> = logical reads (data touched in memory).</p>'
        },
        'cpu-trend': {
            title: 'CPU Impact Over Time',
            body: '<p>A timeline showing how xFACts CPU usage and query volume changed over the selected period.</p>' +
                '<p>The <span class="info-green">green line</span> is CPU percentage (left axis) \u2014 calculated as xFACts CPU time divided by total server CPU capacity for each time bucket. Hover over any point to see the actual values used in the calculation. The <span style="color:#569cd6">blue bars</span> are query count (right axis) \u2014 these typically spike when scheduled collection processes run.</p>' +
                '<p>The two together tell a story: if query volume spikes but CPU stays flat, the queries are lightweight. If both spike together, a heavier process was running during that window.</p>'
        },
        'api-endpoints': {
            title: 'Top API Endpoints',
            body: '<p>The most-called Control Center API endpoints, ranked by total processing time. This shows which dashboard features are generating the most server-side work.</p>' +
                '<p>Useful for identifying if a specific endpoint is slow (high Avg ms) or just heavily used (high Calls but low Avg ms).</p>'
        }
    };

    function showInfo(key) {
        var info = INFO[key];
        if (!info) return;
        document.getElementById('info-modal-title').textContent = info.title;
        document.getElementById('info-modal-body').innerHTML = info.body;
        document.getElementById('info-modal-overlay').classList.add('open');
    }

    function closeInfo(event) {
        // If called from overlay click, only close if clicking the overlay itself
        if (event && event.target !== document.getElementById('info-modal-overlay')) return;
        document.getElementById('info-modal-overlay').classList.remove('open');
    }

    // ========================================================================
    // HERO GAUGE (full donut)
    // ========================================================================
    function loadImpactSummary() {
        // Always fetch all-servers data for mini gauges
        var allParams = buildParams().replace(/server=[^&]*/, 'server=all');
        var filteredParams = buildParams();

        // Fetch all-servers for mini gauges (always)
        var allFetch = engineFetch('/api/platform-monitoring/impact-summary?' + allParams);

        // Fetch filtered data for hero gauge + narrative
        var filteredFetch = (currentServer === 'all')
            ? allFetch  // Reuse same request when viewing all
            : engineFetch('/api/platform-monitoring/impact-summary?' + filteredParams);

        Promise.all([allFetch, filteredFetch])
            .then(function(results) {
                var allData = results[0];
                var filteredData = results[1];

                if (allData.Error) { showError(allData.Error); return; }
                clearError();

                allServersCache = allData;
                serverImpactData = filteredData;

                renderHeroGauge(filteredData);
                renderMiniGauges(allData);
                updateNarrative();
            }).catch(function(e) { showError('Load failed: ' + e.message); });
    }

    function renderHeroGauge(data) {
        var agg = data.aggregate;
        var pct = agg.cpu_pct;
        var pctEl = document.getElementById('gauge-pct');
        var detailEl = document.getElementById('gauge-detail');

        if (pct === null || pct === undefined) {
            pctEl.textContent = 'N/A'; pctEl.className = 'pm-hero-pct na';
            detailEl.textContent = 'Insufficient data';
            drawHeroDonut(0, '#555'); return;
        }
        pctEl.textContent = pct.toFixed(2) + '%';
        var color;
        if (pct < 2) { color = '#4ec9b0'; pctEl.className = 'pm-hero-pct green'; }
        else if (pct < 5) { color = '#dcdcaa'; pctEl.className = 'pm-hero-pct yellow'; }
        else { color = '#f48771'; pctEl.className = 'pm-hero-pct red'; }
        // Derive core count from capacity: capacity_cpu_ms / (rangeMinutes * 60 * 1000)
        var cores = '';
        if (agg.capacity_cpu_ms) {
            // For standard ranges, compute cores from capacity
            var rangeMs = { '1h': 3600000, '12h': 43200000, '24h': 86400000, '7d': 604800000 };
            var rMs = (customFrom && customTo) ? null : rangeMs[currentRange];
            if (rMs && agg.capacity_cpu_ms > 0) cores = ' \u2022 ' + Math.round(agg.capacity_cpu_ms / rMs) + ' cores';
        }
        detailEl.textContent = 'xFACts: ' + fmtMs(agg.total_cpu_ms) + ' CPU' + cores;
        drawHeroDonut(pct, color);
    }

    function drawHeroDonut(pct, color) {
        var canvas = document.getElementById('gauge-chart');
        var ctx = canvas.getContext('2d');
        var display = pct > 0 && pct < 10 ? Math.max(pct * 8, 3) : pct;
        display = Math.min(display, 100);
        if (gaugeChart) gaugeChart.destroy();
        gaugeChart = new Chart(ctx, {
            type: 'doughnut',
            data: { datasets: [{ data: [display, 100 - display], backgroundColor: [color, '#2d2d2d'], borderWidth: 0, circumference: 270, rotation: 225 }] },
            options: { responsive: false, cutout: '72%', plugins: { legend: { display: false }, tooltip: { enabled: false } }, animation: { animateRotate: true, duration: 600 } }
        });
    }

    // ========================================================================
    // MINI GAUGES — clickable server selectors in card frames
    // ========================================================================
    function renderMiniGauges(data) {
        var container = document.getElementById('mini-gauges');
        var servers = data.servers || [];
        if (servers.length === 0) { container.innerHTML = ''; return; }

        // Destroy existing
        Object.keys(miniGaugeCharts).forEach(function(k) { if (miniGaugeCharts[k]) miniGaugeCharts[k].destroy(); });
        miniGaugeCharts = {};

        var html = '';
        servers.forEach(function(s) {
            var id = 'mg-' + s.server_name.replace(/[^a-zA-Z0-9]/g, '_');
            var sel = (currentServer === s.server_name) ? ' selected' : '';
            html += '<div class="pm-mini-gauge' + sel + '" data-server="' + s.server_name + '" onclick="PM.selectServer(\'' + s.server_name + '\')">' +
                '<div class="pm-mini-gauge-wrap"><canvas id="' + id + '" width="60" height="60"></canvas></div>' +
                '<div class="pm-mini-gauge-pct" id="' + id + '-pct">-</div>' +
                '<div class="pm-mini-gauge-name">' + s.server_name + '</div></div>';
        });
        container.innerHTML = html;

        setTimeout(function() {
            servers.forEach(function(s) {
                var id = 'mg-' + s.server_name.replace(/[^a-zA-Z0-9]/g, '_');
                var pct = s.cpu_pct;
                var pctEl = document.getElementById(id + '-pct');
                var canvas = document.getElementById(id);
                if (!canvas) return;

                var color = '#555';
                if (pct === null || pct === undefined) {
                    if (pctEl) { pctEl.textContent = 'N/A'; pctEl.className = 'pm-mini-gauge-pct na'; }
                } else {
                    if (pctEl) {
                        pctEl.textContent = pct.toFixed(1) + '%';
                        if (pct < 2) { color = '#4ec9b0'; pctEl.className = 'pm-mini-gauge-pct green'; }
                        else if (pct < 5) { color = '#dcdcaa'; pctEl.className = 'pm-mini-gauge-pct yellow'; }
                        else { color = '#f48771'; pctEl.className = 'pm-mini-gauge-pct red'; }
                    }
                }

                // Semi-circle: 180 degree arc
                var display = pct || 0;
                if (display > 0 && display < 10) display = Math.max(display * 8, 4);
                display = Math.min(display, 100);

                var existing = Chart.getChart(canvas);
                if (existing) existing.destroy();

                miniGaugeCharts[id] = new Chart(canvas.getContext('2d'), {
                    type: 'doughnut',
                    data: { datasets: [{ data: [display, 100 - display], backgroundColor: [color, '#333'], borderWidth: 0, circumference: 180, rotation: 270 }] },
                    options: { responsive: false, cutout: '65%', plugins: { legend: { display: false }, tooltip: { enabled: false } }, animation: { duration: 400 } }
                });
            });
        }, 50);
    }

    // ========================================================================
    // SUMMARY CARDS
    // ========================================================================
    function loadSummaryCards() {
        engineFetch('/api/platform-monitoring/summary-cards?' + buildParams())
            .then(function(data) {
                if (!data) return;
                if (data.Error) return;
                summaryCardData = data;
                setText('card-sessions', fmtNum(data.active_sessions));
                setText('card-queries', fmtCompact(data.total_queries));
                setText('card-avg-dur', data.avg_duration_ms > 0 ? data.avg_duration_ms.toFixed(0) : '0');
                setAlertVal('card-blocked-by', data.blocked_by_others);
                setAlertVal('card-caused-by', data.caused_by_xfacts);
                setAlertVal('card-lrq', data.lrq_crossovers);
                setAlertVal('card-open-tx', data.open_transactions);
                updateNarrative();
            }).catch(function() {});
    }
    function setAlertVal(id, val) {
        var el = document.getElementById(id);
        var v = (val === null || val === undefined) ? 0 : val;
        el.textContent = fmtNum(v);
        el.className = 'pm-card-val' + (v > 0 ? ' red' : ' green');
    }

    // ========================================================================
    // TREND CHART — auto-scaling both axes
    // ========================================================================
    function loadTrend() {
        engineFetch('/api/platform-monitoring/trend?' + buildParams())
            .then(function(data) {
                if (!data) return;
                if (data.Error) return;
                renderTrendChart(data);
            }).catch(function() {});
    }

    function renderTrendChart(data) {
        var canvas = document.getElementById('trend-chart');
        var points = data.points || [];

        var labels = points.map(function(p) {
            var b = p.bucket;
            if (b.indexOf('/') >= 0) return b;
            var parts = b.split(' ');
            return parts.length > 1 ? parts[1] : b;
        });
        var pctData = points.map(function(p) { return p.cpu_pct; });
        var queryData = points.map(function(p) { return p.query_count; });

        var maxPct = 0;
        pctData.forEach(function(v) { if (v !== null && v !== undefined && v > maxPct) maxPct = v; });
        var yMax;
        if (maxPct === 0) yMax = 1;
        else if (maxPct < 0.5) yMax = Math.ceil(maxPct * 20) / 20 + 0.05;
        else if (maxPct < 2) yMax = Math.ceil(maxPct * 10) / 10 + 0.1;
        else if (maxPct < 10) yMax = Math.ceil(maxPct) + 1;
        else yMax = Math.ceil(maxPct * 1.3);

        var maxQ = 0;
        queryData.forEach(function(v) { if (v !== null && v !== undefined && v > maxQ) maxQ = v; });
        var y1Max = maxQ > 0 ? Math.ceil(maxQ * 1.3) : 100;

        if (trendChart) trendChart.destroy();
        trendChart = new Chart(canvas, {
            type: 'bar',
            data: {
                labels: labels,
                datasets: [
                    {
                        label: 'CPU %', type: 'line', data: pctData,
                        borderColor: '#4ec9b0', backgroundColor: 'rgba(78,201,176,0.12)',
                        borderWidth: 2, pointRadius: 2, pointHoverRadius: 5,
                        pointBackgroundColor: '#4ec9b0',
                        fill: true, yAxisID: 'y', tension: 0.3, spanGaps: true,
                        order: 0
                    },
                    {
                        label: 'Queries', data: queryData,
                        backgroundColor: 'rgba(86,156,214,0.3)',
                        borderColor: 'rgba(86,156,214,0.5)',
                        borderWidth: 1, yAxisID: 'y1',
                        order: 1
                    }
                ]
            },
            options: {
                responsive: true, maintainAspectRatio: false,
                interaction: { mode: 'index', intersect: false },
                plugins: {
                    legend: { labels: { color: '#888', font: { size: 11 }, boxWidth: 14, padding: 12 } },
                    tooltip: { titleFont: { size: 11 }, bodyFont: { size: 11 },
                        footerFont: { size: 10, weight: 'normal' },
                        footerColor: '#999',
                        callbacks: {
                        label: function(item) {
                            if (item.datasetIndex === 0) return 'CPU: ' + (item.raw !== null ? item.raw.toFixed(3) + '%' : 'N/A');
                            return 'Queries: ' + fmtNum(item.raw);
                        },
                        afterBody: function(items) {
                            var idx = items[0].dataIndex;
                            var pt = points[idx];
                            if (!pt || pt.cpu_pct === null || pt.cpu_pct === undefined) return [];
                            var lines = [];
                            lines.push('');
                            lines.push(fmtNum(pt.xfacts_cpu_ms) + 'ms \u00F7 ' + fmtNum(pt.capacity_cpu_ms) + 'ms capacity');
                            return lines;
                        },
                        footer: function() {
                            return 'Capacity = CPU cores \u00D7 bucket duration \u00D7 1000';
                        }
                    }}
                },
                scales: {
                    x: { ticks: { color: '#888', font: { size: 10 }, maxRotation: 0, autoSkip: true, maxTicksLimit: 12 }, grid: { color: '#2d2d2d' } },
                    y: { type: 'linear', position: 'left', min: 0, suggestedMax: yMax,
                        title: { display: true, text: 'CPU %', color: '#4ec9b0', font: { size: 10 } },
                        ticks: { color: '#4ec9b0', font: { size: 10 } }, grid: { color: '#2d2d2d' } },
                    y1: { type: 'linear', position: 'right', min: 0, suggestedMax: y1Max,
                        title: { display: true, text: 'Queries', color: '#569cd6', font: { size: 10 } },
                        ticks: { color: '#569cd6', font: { size: 10 } }, grid: { display: false } }
                }
            }
        });
    }

    // ========================================================================
    // PROCESS BREAKDOWN
    // ========================================================================
    function loadProcessBreakdown() {
        engineFetch('/api/platform-monitoring/process-breakdown?' + buildParams())
            .then(function(data) {
                if (!data) return;
                if (data.Error) return;
                processData = data; renderProcessTable();
                updateNarrative();
            }).catch(function() {});
    }

    function renderProcessTable() {
        var wrap = document.getElementById('process-table-wrap');
        if (!processData || processData.length === 0) { wrap.innerHTML = '<div class="pm-loading">No data</div>'; return; }

        var d = processData.slice();
        d.sort(function(a, b) {
            var va = a[sortCol] || 0, vb = b[sortCol] || 0;
            if (typeof va === 'string') return sortDir === 'asc' ? va.localeCompare(vb) : vb.localeCompare(va);
            return sortDir === 'desc' ? vb - va : va - vb;
        });

        // Calculate totals for percentage columns
        var totalXfactsCpu = 0;
        d.forEach(function(r) { totalXfactsCpu += (r.total_cpu_ms || 0); });
        var serverCpuMs = (serverImpactData && serverImpactData.aggregate) ? serverImpactData.aggregate.capacity_cpu_ms : null;

        var cols = [
            { key: 'process_name', label: 'Process', cls: '' },
            { key: 'query_count', label: 'Qry', cls: 'num' },
            { key: 'total_cpu_ms', label: 'CPU', cls: 'num' },
            { key: 'avg_duration_ms', label: 'Avg', cls: 'num' },
            { key: 'total_logical_reads', label: 'Reads', cls: 'num' },
            { key: '_pct_xfacts', label: '% xFACts', cls: 'num' },
            { key: '_pct_server', label: '% Server', cls: 'num' }
        ];

        var html = '<table class="pm-table"><thead><tr>';
        cols.forEach(function(c) {
            var arrow = '';
            var sortKey = c.key;
            // Map virtual columns to their sort basis
            if (sortKey === '_pct_xfacts' || sortKey === '_pct_server') sortKey = 'total_cpu_ms';
            if (sortKey === sortCol) arrow = '<span class="sort-arrow">' + (sortDir === 'asc' ? '\u25B2' : '\u25BC') + '</span>';
            var onclick = ' onclick="PM.sortProcess(\'' + sortKey + '\')"';
            html += '<th class="' + c.cls + '"' + onclick + '>' + c.label + arrow + '</th>';
        });
        html += '</tr></thead><tbody>';

        d.forEach(function(row) {
            var pctXfacts = totalXfactsCpu > 0 ? ((row.total_cpu_ms || 0) / totalXfactsCpu * 100) : 0;
            var pctServer = (serverCpuMs && serverCpuMs > 0) ? ((row.total_cpu_ms || 0) / serverCpuMs * 100) : null;

            var procName = row.process_name || '';
            var shortName = procName.indexOf('xFACts ') === 0 ? procName.substring(7) : procName;
            var tooltip = shortName + ' used ' + pctXfacts.toFixed(1) + '% of all xFACts CPU';
            if (pctServer !== null) tooltip += ', but only ' + pctServer.toFixed(3) + '% of total server CPU capacity';

            var displayName = row.process_name || '';
            if (displayName.indexOf('xFACts ') === 0) displayName = displayName.substring(7);

            html += '<tr data-tooltip="' + esc(tooltip) + '"><td class="process-name" title="' + esc(row.process_name) + '">' + esc(displayName) + '</td>' +
                '<td class="num">' + fmtCompact(row.query_count) + '</td>' +
                '<td class="num">' + fmtMs(row.total_cpu_ms) + '</td>' +
                '<td class="num">' + fmtDur(row.avg_duration_ms) + '</td>' +
                '<td class="num">' + fmtCompact(row.total_logical_reads) + '</td>' +
                '<td class="num">' + pctXfacts.toFixed(1) + '%</td>' +
                '<td class="num pct-server">' + (pctServer !== null ? pctServer.toFixed(3) + '%' : '-') + '</td></tr>';
        });
        html += '</tbody></table>';
        wrap.innerHTML = html;
    }

    function sortProcess(col) {
        if (sortCol === col) sortDir = sortDir === 'desc' ? 'asc' : 'desc';
        else { sortCol = col; sortDir = col === 'process_name' ? 'asc' : 'desc'; }
        renderProcessTable();
    }

    // ========================================================================
    // API PERFORMANCE
    // ========================================================================
    function loadApiPerformance() {
        engineFetch('/api/platform-monitoring/api-performance?' + buildParams())
            .then(function(data) {
                if (!data) return;
                if (data.Error) return;
                renderApiTable(data);
                setText('card-api-reqs', fmtCompact(data.total_requests));
                setText('card-api-rpm', data.requests_per_min !== null ? data.requests_per_min : '-');
                setText('card-api-avg', data.avg_duration_ms > 0 ? Math.round(data.avg_duration_ms) : '0');
                setText('card-api-p95', data.p95_ms > 0 ? Math.round(data.p95_ms) : '0');
                setText('card-api-users', data.unique_users || '0');
                var errEl = document.getElementById('card-api-errors');
                var errCount = data.error_count || 0;
                errEl.textContent = fmtNum(errCount);
                errEl.className = 'pm-card-val' + (errCount > 0 ? ' red' : ' green');
            }).catch(function() {});
    }

    function renderApiTable(data) {
        var wrap = document.getElementById('api-table-wrap');
        var eps = data.top_endpoints || [];
        if (eps.length === 0) { wrap.innerHTML = '<div class="pm-loading">No API data</div>'; return; }

        var html = '<table class="pm-api-table"><thead><tr><th>Endpoint</th><th class="num">Calls</th><th class="num">Avg ms</th><th class="num">Max ms</th></tr></thead><tbody>';
        eps.forEach(function(ep) {
            html += '<tr><td class="endpoint" title="' + esc(ep.endpoint) + '">' + esc(ep.endpoint) + '</td>' +
                '<td class="num">' + fmtCompact(ep.call_count) + '</td>' +
                '<td class="num">' + fmtNum(ep.avg_ms) + '</td>' +
                '<td class="num">' + fmtNum(ep.max_ms) + '</td></tr>';
        });
        html += '</tbody></table>';
        wrap.innerHTML = html;
    }

    // ========================================================================
    // SLIDEOUT PANEL — card click-through detail views
    // ========================================================================
    function openSlideout(type) {
        var overlay = document.getElementById('slideout-overlay');
        var panel = document.getElementById('slideout-panel');
        var title = document.getElementById('slideout-title');
        var summary = document.getElementById('slideout-summary');
        var body = document.getElementById('slideout-body');

        body.innerHTML = '<div class="pm-so-empty">Loading...</div>';
        summary.innerHTML = '';

        var titles = {
            'blocking': 'Blocking Event Detail',
            'lrq': 'Long-Running Query Detail',
            'api-errors': 'API Error Detail',
            'api-users': 'API User Breakdown'
        };
        title.textContent = titles[type] || 'Detail';

        overlay.classList.add('visible');
        panel.classList.add('visible');

        if (type === 'blocking') loadBlockingDetail(summary, body);
        else if (type === 'lrq') loadLRQDetail(summary, body);
        else if (type === 'api-errors') loadAPIErrorDetail(summary, body);
        else if (type === 'api-users') loadAPIUserDetail(summary, body);
    }

    function closeSlideout() {
        document.getElementById('slideout-overlay').classList.remove('visible');
        document.getElementById('slideout-panel').classList.remove('visible');
    }

    function loadBlockingDetail(summary, body) {
        engineFetch('/api/platform-monitoring/blocking-detail?' + buildParams())
            .then(function(data) {
                if (!data) return;
                if (!data || data.length === 0) {
                    summary.innerHTML = 'No blocking events involving xFACts during this period.';
                    body.innerHTML = '<div class="pm-so-empty">Nothing to show \u2014 this is good!</div>';
                    return;
                }
                summary.innerHTML = '<strong>' + data.length + '</strong> blocking event' + (data.length !== 1 ? 's' : '') + ' found. Click a row to see query details.';
                var html = '<table class="pm-so-table"><thead><tr><th>Time</th><th>Server</th><th>Direction</th><th class="num">Wait</th><th>Wait Type</th><th>Blocked App</th><th>Blocker App</th></tr></thead><tbody>';
                data.forEach(function(e, idx) {
                    var dirCls = e.direction === 'Caused by xFACts' ? 'dir-caused' : (e.direction === 'Blocked by Others' ? 'dir-blocked' : 'dir-both');
                    var waitSec = e.blocked_wait_time_ms ? (e.blocked_wait_time_ms / 1000).toFixed(1) + 's' : '-';
                    var hasSql = (e.blocked_query || e.blocker_query);
                    html += '<tr' + (hasSql ? ' class="pm-so-expandable" onclick="PM.toggleSqlRow(\'blk-sql-' + idx + '\')"' : '') + '>' +
                        '<td class="dim">' + fmtTimestamp(e.event_timestamp) + '</td>' +
                        '<td>' + esc(e.server_name) + '</td>' +
                        '<td class="' + dirCls + '">' + esc(e.direction) + '</td>' +
                        '<td class="num">' + waitSec + '</td>' +
                        '<td class="dim">' + esc(e.blocked_wait_type || '-') + '</td>' +
                        '<td class="mono">' + esc(truncApp(e.blocked_client_app)) + '</td>' +
                        '<td class="mono">' + esc(truncApp(e.blocked_by_client_app)) + '</td>' +
                        '</tr>';
                    if (hasSql) {
                        var sqlContent = '';
                        if (e.blocked_query) sqlContent += '<div class="pm-so-sql-label">Blocked Query:</div><div class="pm-so-sql-box">' + esc(e.blocked_query) + '</div>';
                        if (e.blocker_query) sqlContent += '<div class="pm-so-sql-label">Blocker Query:</div><div class="pm-so-sql-box">' + esc(e.blocker_query) + '</div>';
                        html += '<tr class="pm-so-sql-row" id="blk-sql-' + idx + '"><td colspan="7">' + sqlContent + '</td></tr>';
                    }
                });
                html += '</tbody></table>';
                body.innerHTML = html;
            }).catch(function(e) { body.innerHTML = '<div class="pm-so-empty">Error: ' + esc(e.message) + '</div>'; });
    }

    function loadLRQDetail(summary, body) {
        engineFetch('/api/platform-monitoring/lrq-detail?' + buildParams())
            .then(function(data) {
                if (!data) return;
                if (!data || data.length === 0) {
                    summary.innerHTML = 'No long-running xFACts queries during this period.';
                    body.innerHTML = '<div class="pm-so-empty">All queries completed within threshold \u2014 this is good!</div>';
                    return;
                }
                summary.innerHTML = '<strong>' + data.length + '</strong> long-running quer' + (data.length !== 1 ? 'ies' : 'y') + ' found. Click a row to see the full query text.';
                var html = '<table class="pm-so-table"><thead><tr><th>Time</th><th>Server</th><th>Process</th><th>Database</th><th class="num">Duration</th><th class="num">CPU</th><th class="num">Reads</th></tr></thead><tbody>';
                data.forEach(function(e, idx) {
                    var proc = e.client_app_name || '';
                    if (proc.indexOf('xFACts ') === 0) proc = proc.substring(7);
                    html += '<tr class="pm-so-expandable" onclick="PM.toggleSqlRow(\'lrq-sql-' + idx + '\')">' +
                        '<td class="dim">' + fmtTimestamp(e.event_timestamp) + '</td>' +
                        '<td>' + esc(e.server_name) + '</td>' +
                        '<td>' + esc(proc) + '</td>' +
                        '<td class="dim">' + esc(e.database_name || '-') + '</td>' +
                        '<td class="num">' + fmtMs(e.duration_ms) + '</td>' +
                        '<td class="num">' + fmtMs(e.cpu_time_ms) + '</td>' +
                        '<td class="num">' + fmtCompact(e.logical_reads) + '</td>' +
                        '</tr>' +
                        '<tr class="pm-so-sql-row" id="lrq-sql-' + idx + '"><td colspan="7"><div class="pm-so-sql-box">' + esc(e.sql_preview || 'No query text available') + '</div></td></tr>';
                });
                html += '</tbody></table>';
                body.innerHTML = html;
            }).catch(function(e) { body.innerHTML = '<div class="pm-so-empty">Error: ' + esc(e.message) + '</div>'; });
    }

    function loadAPIErrorDetail(summary, body) {
        engineFetch('/api/platform-monitoring/api-errors?' + buildParams())
            .then(function(data) {
                if (!data) return;
                if (data.Error) { body.innerHTML = '<div class="pm-so-empty">Error: ' + esc(data.Error) + '</div>'; return; }
                var errors = data.errors || [];
                var timeouts = data.timeouts || [];
                var totalTimeouts = data.total_timeouts || 0;

                var parts = [];
                if (errors.length > 0) parts.push('<strong>' + errors.length + '</strong> error' + (errors.length !== 1 ? 's' : ''));
                if (totalTimeouts > 0) parts.push('<strong>' + fmtCompact(totalTimeouts) + '</strong> client timeout' + (totalTimeouts !== 1 ? 's' : '') + ' (408)');
                if (parts.length === 0) parts.push('No errors or timeouts');
                summary.innerHTML = parts.join(', ') + ' during this period.';

                var html = '';

                // Real errors section
                if (errors.length > 0) {
                    html += '<table class="pm-so-table"><thead><tr><th>Time</th><th>Endpoint</th><th>Method</th><th class="num">Status</th><th>User</th><th class="num">Duration</th></tr></thead><tbody>';
                    errors.forEach(function(e) {
                        html += '<tr>' +
                            '<td class="dim">' + fmtTimestamp(e.request_dttm) + '</td>' +
                            '<td class="mono">' + esc(e.endpoint) + '</td>' +
                            '<td class="dim">' + esc(e.http_method) + '</td>' +
                            '<td class="num" style="color:#f48771">' + (e.status_code || '-') + '</td>' +
                            '<td>' + esc(e.user_name || 'Anonymous') + '</td>' +
                            '<td class="num">' + (e.duration_ms !== null ? e.duration_ms + 'ms' : '-') + '</td>' +
                            '</tr>';
                    });
                    html += '</tbody></table>';
                } else {
                    html += '<div class="pm-so-empty">No application errors \u2014 clean slate!</div>';
                }

                // Client timeouts section (collapsible)
                if (totalTimeouts > 0) {
                    html += '<div class="pm-so-timeout-section">' +
                        '<div class="pm-so-timeout-header pm-so-expandable" onclick="PM.toggleSqlRow(\'timeout-detail\')">' +
                        '<span class="pm-so-timeout-chevron" id="timeout-chevron">\u25B6</span> ' +
                        'Client Timeouts (408) \u2014 <strong>' + fmtCompact(totalTimeouts) + '</strong> total across <strong>' + timeouts.length + '</strong> endpoint' + (timeouts.length !== 1 ? 's' : '') +
                        '<span class="pm-so-timeout-note">Typically caused by backgrounded browser tabs or expired sessions</span>' +
                        '</div>' +
                        '<div class="pm-so-timeout-body" id="timeout-detail">';
                    html += '<table class="pm-so-table"><thead><tr><th>Endpoint</th><th class="num">Timeouts</th><th>Last Seen</th></tr></thead><tbody>';
                    timeouts.forEach(function(t) {
                        html += '<tr>' +
                            '<td class="mono">' + esc(t.endpoint) + '</td>' +
                            '<td class="num">' + fmtCompact(t.timeout_count) + '</td>' +
                            '<td class="dim">' + fmtTimestamp(t.last_timeout) + '</td>' +
                            '</tr>';
                    });
                    html += '</tbody></table></div></div>';
                }

                body.innerHTML = html;
            }).catch(function(e) { body.innerHTML = '<div class="pm-so-empty">Error: ' + esc(e.message) + '</div>'; });
    }

    function loadAPIUserDetail(summary, body) {
        engineFetch('/api/platform-monitoring/api-users?' + buildParams())
            .then(function(data) {
                if (!data) return;
                if (data.Error) { body.innerHTML = '<div class="pm-so-empty">Error: ' + esc(data.Error) + '</div>'; return; }
                var users = data.users || [];
                var unauthCount = data.unauthenticated_requests || 0;
                var totalAuth = data.total_authenticated || 0;

                summary.innerHTML = '<strong>' + users.length + '</strong> active user' + (users.length !== 1 ? 's' : '') +
                    ' \u2014 <strong>' + fmtCompact(totalAuth) + '</strong> authenticated requests, ' +
                    '<strong>' + fmtCompact(unauthCount) + '</strong> unauthenticated (login page, expired sessions)';

                if (users.length === 0) {
                    body.innerHTML = '<div class="pm-so-empty">No authenticated user activity during this period.</div>';
                    return;
                }
                var html = '<table class="pm-so-table"><thead><tr><th>User</th><th class="num">Requests</th><th class="num">Pages</th><th>Last Active</th></tr></thead><tbody>';
                users.forEach(function(u) {
                    html += '<tr>' +
                        '<td>' + esc(u.user_name) + '</td>' +
                        '<td class="num">' + fmtCompact(u.request_count) + '</td>' +
                        '<td class="num">' + (u.pages_used || '-') + '</td>' +
                        '<td class="dim">' + fmtTimestamp(u.last_active) + '</td>' +
                        '</tr>';
                });
                html += '</tbody></table>';
                body.innerHTML = html;
            }).catch(function(e) { body.innerHTML = '<div class="pm-so-empty">Error: ' + esc(e.message) + '</div>'; });
    }

    // Slideout helpers
    function truncApp(name) { if (!name) return '-'; if (name.indexOf('xFACts ') === 0) return name.substring(7); return name.length > 30 ? name.substring(0, 27) + '...' : name; }
    function truncSql(sql) { if (!sql) return '-'; return sql.length > 60 ? sql.substring(0, 57) + '...' : sql; }
    function toggleSqlRow(id) {
        var row = document.getElementById(id);
        if (row) {
            row.classList.toggle('visible');
            // Rotate chevron if this is the timeout section
            if (id === 'timeout-detail') {
                var chev = document.getElementById('timeout-chevron');
                if (chev) chev.textContent = row.classList.contains('visible') ? '\u25BC' : '\u25B6';
            }
        }
    }
    function fmtTimestamp(ts) {
        if (!ts) return '-';
        // Handle .NET JSON date format: /Date(1234567890)/
        var dotnetMatch = String(ts).match(/\/Date\((\d+)\)\//);
        if (dotnetMatch) {
            var d = new Date(parseInt(dotnetMatch[1]));
            return (d.getMonth()+1) + '/' + d.getDate() + ' ' + d.toLocaleTimeString();
        }
        var d = new Date(ts);
        if (isNaN(d.getTime())) return String(ts).substring(0, 19);
        return (d.getMonth()+1) + '/' + d.getDate() + ' ' + d.toLocaleTimeString();
    }

    // ========================================================================
    // FORMATTING
    // ========================================================================
    function fmtNum(n) { if (n === null || n === undefined) return '-'; return Number(n).toLocaleString(); }
    function fmtCompact(n) {
        if (n === null || n === undefined) return '-';
        if (n >= 1000000) return (n/1000000).toFixed(1) + 'M';
        if (n >= 1000) return (n/1000).toFixed(1) + 'K';
        return Number(n).toLocaleString();
    }
    function fmtMs(ms) {
        if (ms === null || ms === undefined) return '-';
        if (ms < 1000) return ms + 'ms';
        if (ms < 60000) return (ms/1000).toFixed(1) + 's';
        if (ms < 3600000) return (ms/60000).toFixed(1) + 'm';
        return (ms/3600000).toFixed(1) + 'h';
    }
    function fmtDur(ms) {
        if (ms === null || ms === undefined) return '-';
        if (ms < 1) return '<1ms'; return Number(ms).toFixed(0) + 'ms';
    }
    function setText(id, val) { var el = document.getElementById(id); if (el) el.textContent = val; }
    function esc(s) { if (!s) return ''; return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;'); }

    document.addEventListener('DOMContentLoaded', init);
    return { selectServer: selectServer, setRange: setRange, openDateModal: openDateModal, closeDateModal: closeDateModal, applyCustomRange: applyCustomRange, sortProcess: sortProcess, showInfo: showInfo, closeInfo: closeInfo, openSlideout: openSlideout, closeSlideout: closeSlideout, toggleSqlRow: toggleSqlRow, pageRefresh: pageRefresh };
})();

# ============================================================================
# xFACts Control Center - Replication Monitoring Page
# Location: E:\xFACts-ControlCenter\scripts\routes\ReplicationMonitoring.ps1
#
# Renders the Replication Monitoring dashboard page.
# CSS: /css/replication-monitoring.css
# JS:  /js/replication-monitoring.js
# APIs: ReplicationMonitoring-API.ps1
#
# Version: Tracked in dbo.System_Metadata (component: ServerOps.Replication)
#
# CHANGELOG
# ---------
# 2026-04-29  Phase 3d of dynamic nav: replaced hardcoded nav block with
#             Get-NavBarHtml helper. Page H1 link, title, subtitle, and
#             browser tab title now render from RBAC_NavRegistry via
#             Get-PageHeaderHtml and Get-PageBrowserTitle.
# ============================================================================

Add-PodeRoute -Method Get -Path '/replication-monitoring' -Authentication 'ADLogin' -ScriptBlock {

    # --- RBAC Access Check ---
    $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/replication-monitoring'
    if (-not $access.HasAccess) {
        Write-PodeHtmlResponse -Value (Get-AccessDeniedHtml -DisplayName $access.DisplayName -PageRoute '/replication-monitoring') -StatusCode 403
        return
    }

    # --- User context (used by helper for nav rendering) ---
    $ctx = Get-UserContext -WebEvent $WebEvent

    # --- Render dynamic nav bar and page header from RBAC_NavRegistry ---
    $navHtml      = Get-NavBarHtml      -UserContext $ctx -CurrentPageRoute '/replication-monitoring'
    $headerHtml   = Get-PageHeaderHtml   -PageRoute '/replication-monitoring'
    $browserTitle = Get-PageBrowserTitle -PageRoute '/replication-monitoring'

    $html = @"

<!DOCTYPE html>
<html>
<head>
    <title>$browserTitle</title>
    <link rel="stylesheet" href="/css/replication-monitoring.css">
    <link rel="stylesheet" href="/css/engine-events.css">
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/chartjs-adapter-date-fns"></script>
</head>
<body>
$navHtml

    <div class="header-bar">
        <div>
            $headerHtml
        </div>
        <div class="header-right">
            <div class="refresh-info">
                <span class="live-indicator"></span>
                <span>Live</span> | Updated: <span id="last-update" class="last-updated">-</span>
                <button class="page-refresh-btn" onclick="pageRefresh()" title="Refresh all data">&#8635;</button>
            </div>
            <div class="engine-row">
                <div class="engine-card" id="card-engine-replication">
                    <span class="engine-label">Replication</span>
                    <div class="engine-bar disabled" id="engine-bar-replication"></div>
                    <span class="engine-countdown" id="engine-cd-replication">&nbsp;</span>
                </div>
            </div>
        </div>
    </div>

    <div id="connection-error" class="connection-error"></div>

    <!-- Agent Status Cards -->
    <div class="section">
        <div class="section-header">
            <h2 class="section-title">Agent Status</h2>
            <span class="refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
        </div>
        <div id="agent-cards" class="agent-cards-grid">
            <div class="loading">Loading...</div>
        </div>
    </div>

    <!-- Delivery Rate (full width, first chart) -->
    <div class="section">
        <div class="section-header">
            <h2 class="section-title">Delivery Rate</h2>
            <div class="section-header-right">
                <div class="time-buttons">
                    <button class="time-btn active" data-chart="throughput" data-minutes="60">1h</button>
                    <button class="time-btn" data-chart="throughput" data-minutes="240">4h</button>
                    <button class="time-btn" data-chart="throughput" data-minutes="720">12h</button>
                    <button class="time-btn" data-chart="throughput" data-minutes="1440">24h</button>
                    <button class="time-btn" data-chart="throughput" data-minutes="10080">7d</button>
                </div>
                <span class="refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
            </div>
        </div>
        <div class="chart-container chart-wide">
            <canvas id="throughput-chart"></canvas>
        </div>
    </div>

    <!-- Two Column: Charts (left) + Event Log (right) -->
    <div class="lower-grid">

        <!-- Left: Stacked Charts -->
        <div class="lower-left">
            <!-- Queue Depth Chart -->
            <div class="section">
                <div class="section-header">
                    <h2 class="section-title">Queue Depth</h2>
                    <div class="section-header-right">
                        <div class="time-buttons">
                            <button class="time-btn active" data-chart="queue" data-minutes="60">1h</button>
                            <button class="time-btn" data-chart="queue" data-minutes="240">4h</button>
                            <button class="time-btn" data-chart="queue" data-minutes="720">12h</button>
                            <button class="time-btn" data-chart="queue" data-minutes="1440">24h</button>
                            <button class="time-btn" data-chart="queue" data-minutes="10080">7d</button>
                        </div>
                        <span class="refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                    </div>
                </div>
                <div class="chart-container chart-half">
                    <canvas id="queue-chart"></canvas>
                </div>
            </div>

            <!-- Latency Chart -->
            <div class="section">
                <div class="section-header">
                    <h2 class="section-title">End-to-End Latency</h2>
                    <div class="section-header-right">
                        <div class="time-buttons">
                            <button class="time-btn active" data-chart="latency" data-minutes="60">1h</button>
                            <button class="time-btn" data-chart="latency" data-minutes="240">4h</button>
                            <button class="time-btn" data-chart="latency" data-minutes="720">12h</button>
                            <button class="time-btn" data-chart="latency" data-minutes="1440">24h</button>
                            <button class="time-btn" data-chart="latency" data-minutes="10080">7d</button>
                        </div>
                        <span class="refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                    </div>
                </div>
                <div class="chart-container chart-half">
                    <canvas id="latency-chart"></canvas>
                </div>
            </div>
        </div>

        <!-- Right: Event Log -->
        <div class="lower-right">
            <div class="section section-event-log">
                <div class="section-header">
                    <h2 class="section-title">Event Log</h2>
                    <div class="section-header-right">
                        <button id="btn-correlated" class="btn-correlation" onclick="toggleCorrelationMode()" title="Show all BIDATA-correlated events">&#x1F517; Correlated</button>
                        <input type="date" id="event-date-picker" class="event-date-picker" onchange="onEventDateChange()">
                        <span class="refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                    </div>
                </div>
                <div id="event-agent-filter" class="event-agent-filter"></div>
                <div id="event-log" class="event-log-container">
                    <div class="loading">Loading...</div>
                </div>
            </div>
        </div>

    </div>

    <script src="/js/replication-monitoring.js"></script>
    <script src="/js/engine-events.js"></script>
</body>
</html>

"@
    Write-PodeHtmlResponse -Value $html
}
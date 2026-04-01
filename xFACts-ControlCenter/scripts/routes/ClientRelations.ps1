# ============================================================================
# xFACts Control Center - Client Relations Dashboard
# Location: E:\xFACts-ControlCenter\scripts\routes\ClientRelations.ps1
# 
# Departmental page for Client Relations team.
# Components:
#   - Summary Cards: Total consumers, total accounts, rejection reason breakdown (Live)
#   - Reg F Queue:   Expandable consumer/account tree with sorting and filtering (Live)
#
# CSS: /css/client-relations.css, /css/engine-events.css
# JS:  /js/client-relations.js, /js/engine-events.js
# APIs: ClientRelations-API.ps1
#
# Version: Tracked in dbo.System_Metadata (component: DeptOps.ClientRelations)
# ============================================================================

Add-PodeRoute -Method Get -Path '/departmental/client-relations' -Authentication 'ADLogin' -ScriptBlock {
    
    # --- RBAC Access Check ---
    $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/departmental/client-relations'
    if (-not $access.HasAccess) {
        Write-PodeHtmlResponse -Value (Get-AccessDeniedHtml -DisplayName $access.DisplayName -PageRoute '/departmental/client-relations') -StatusCode 403
        return
    }
    
    # --- Admin gear icon (visible only to admin role holders) ---
    $ctx = Get-UserContext -WebEvent $WebEvent
    $adminGear = if ($ctx.IsAdmin) {
        '<span class="nav-spacer"></span><a href="/admin" class="nav-link nav-admin" title="Administration">&#9881;</a>'
    } else { '' }
    
    # Build nav bar - dept-only users get a simplified nav
    $navHtml = if ($access.IsDeptOnly) {
        @'
    <nav class="nav-bar">
        <a href="/" class="nav-link">Home</a>
        <a href="/departmental/client-relations" class="nav-link active">Client Relations</a>
    </nav>
'@
    } else {
        @'
    <nav class="nav-bar">
        <a href="/" class="nav-link">Home</a>
        <a href="/server-health" class="nav-link">Server Health</a>
        <a href="/jobflow-monitoring" class="nav-link">Job/Flow Monitoring</a>
        <a href="/batch-monitoring" class="nav-link">Batch Monitoring</a>
        <a href="/backup" class="nav-link">Backup Monitoring</a>
        <a href="/index-maintenance" class="nav-link">Index Maintenance</a>
        <a href="/bidata-monitoring" class="nav-link">BIDATA Monitoring</a>
        <a href="/file-monitoring" class="nav-link">File Monitoring</a>
        <span class="nav-separator">|</span>
        <a href="/departmental/business-services" class="nav-link">Business Services</a>
        <a href="/departmental/business-intelligence" class="nav-link">Business Intelligence</a>
        <a href="/departmental/client-relations" class="nav-link active">Client Relations</a>
    </nav>
'@
    }
    
    $navHtml = $navHtml.Replace('</nav>', "$adminGear</nav>")
    
    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>Client Relations - xFACts Control Center</title>
    <link rel="stylesheet" href="/css/client-relations.css">
    <link rel="stylesheet" href="/css/engine-events.css">
</head>
<body>
    $navHtml
    
    <div class="header-bar">
        <div>
            <h1>Client Relations</h1>
            <p class="page-subtitle">Departmental Operations</p>
        </div>
        <div class="header-right">
            <div class="refresh-info">
                <span id="cache-indicator" class="cache-indicator" title="Serving cached data">&#9679;</span>
                <span id="cache-label">Cached</span> | Updated: <span id="last-update" class="last-updated">-</span>
                <button class="page-refresh-btn" onclick="pageRefresh()" title="Refresh all data (bypasses cache)">&#8635;</button>
            </div>
            <div class="engine-row" id="engine-row">
                <!-- Engine cards will be added here when collectors are implemented -->
            </div>
        </div>
    </div>
    
    <div id="connection-error" class="connection-error"></div>
    
    <!-- ================================================================ -->
    <!-- SUMMARY CARDS                                                    -->
    <!-- ================================================================ -->
    <div class="section" id="summary-section">
        <div class="section-header">
            <h2>Reg F Compliance Queue</h2>
            <span class="refresh-badge-live" title="Refreshes on live polling timer"><span class="badge-dot"></span></span>
        </div>
        <div class="section-body">
            <div id="summary-loading" class="loading">Loading summary...</div>
            <div id="summary-cards" class="summary-cards hidden"></div>
        </div>
    </div>
    
    <!-- ================================================================ -->
    <!-- QUEUE TABLE (Consumer/Account Tree)                              -->
    <!-- ================================================================ -->
    <div class="section" id="queue-section">
        <div class="section-header">
            <h2>Queue Detail</h2>
            <div class="section-controls">
                <input type="text" id="queue-search" class="search-input" placeholder="Search consumers...">
                <div id="reason-filters" class="reason-filters"></div>
                <span class="refresh-badge-live" title="Refreshes on live polling timer"><span class="badge-dot"></span></span>
            </div>
        </div>
        <div class="section-body section-body-table">
            <div id="queue-loading" class="loading">Loading queue...</div>
            <div id="queue-table" class="queue-scroll-container hidden"></div>
        </div>
    </div>
    
    <script src="/js/client-relations.js"></script>
    <script src="/js/engine-events.js"></script>
</body>
</html>
"@
    Write-PodeHtmlResponse -Value $html
}
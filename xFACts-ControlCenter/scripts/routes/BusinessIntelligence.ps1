# ============================================================================
# xFACts Control Center - Business Intelligence Departmental Page
# Location: E:\xFACts-ControlCenter\scripts\routes\BusinessIntelligence.ps1
# 
# Departmental dashboard for the Business Intelligence team.
# Components:
#   - Notice Recon: Daily reconciliation process status and step detail
#   - BDL Import: Placeholder card linking to future Tools BDL Import page
#   - LiveVox / SndRight: Placeholder cards for Phase 2 monitors
#
# CSS: /css/business-intelligence.css, /css/engine-events.css
# JS:  /js/business-intelligence.js, /js/engine-events.js
# APIs: BusinessIntelligence-API.ps1
#
# Version: Tracked in dbo.System_Metadata (component: DeptOps.BusinessIntelligence)
# ============================================================================

Add-PodeRoute -Method Get -Path '/departmental/business-intelligence' -Authentication 'ADLogin' -ScriptBlock {
    
    # --- RBAC Access Check ---
    $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/departmental/business-intelligence'
    if (-not $access.HasAccess) {
        Write-PodeHtmlResponse -Value (Get-AccessDeniedHtml -DisplayName $access.DisplayName -PageRoute '/departmental/business-intelligence') -StatusCode 403
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
        <a href="/departmental/business-intelligence" class="nav-link active">Business Intelligence</a>
    </nav>
'@
    } else {
        @'
    <nav class="nav-bar">
        <a href="/" class="nav-link">Home</a>
        <a href="/server-health" class="nav-link">Server Health</a>
        <a href="/jobflow-monitoring" class="nav-link">Job/Flow Monitoring</a>
        <a href="/backup" class="nav-link">Backup Monitoring</a>
        <a href="/index-maintenance" class="nav-link">Index Maintenance</a>
        <a href="/bidata-monitoring" class="nav-link">BIDATA Monitoring</a>
        <a href="/file-monitoring" class="nav-link">File Monitoring</a>
        <span class="nav-separator">|</span>
        <a href="/departmental/business-services" class="nav-link">Business Services</a>
        <a href="/departmental/business-intelligence" class="nav-link active">Business Intelligence</a>
    </nav>
'@
    }
    
    $navHtml = $navHtml.Replace('</nav>', "$adminGear</nav>")
    
    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>Business Intelligence - xFACts Control Center</title>
    <link rel="stylesheet" href="/css/business-intelligence.css">
</head>
<body>
    $navHtml
    
    <div class="header-bar">
        <div>
            <h1>Business Intelligence</h1>
            <p class="page-subtitle">Departmental Operations</p>
        </div>
        <div class="header-right">
            <div class="refresh-info">
                Updated: <span id="last-update" class="last-updated">-</span>
                <button class="page-refresh-btn" onclick="BI.pageRefresh()" title="Refresh all data">&#8635;</button>
            </div>
        </div>
    </div>
    
    <div id="connection-error" class="connection-error"></div>
    
    <!-- ================================================================ -->
    <!-- NOTICE RECON STATUS CARDS                                        -->
    <!-- ================================================================ -->
    <div class="section" id="notice-recon-section">
        <div class="section-header">
            <h2>Notice Reconciliation</h2>
            <span class="section-subtitle">Daily vendor file processing status</span>
        </div>
        <div class="section-body">
            <div id="nr-loading" class="loading">Loading Notice Recon status...</div>
            <div id="nr-cards" class="nr-cards hidden"></div>
            <div id="nr-empty" class="empty-state hidden">No executions found for today</div>
        </div>
    </div>
    
    <!-- ================================================================ -->
    <!-- NOTICE RECON STEP DETAIL (expandable)                            -->
    <!-- ================================================================ -->
    <div class="section" id="nr-detail-section">
        <div class="section-header">
            <h2>Execution Detail</h2>
            <span id="nr-detail-subtitle" class="section-subtitle">Click a process card above to view steps</span>
        </div>
        <div class="section-body">
            <div id="nr-steps" class="nr-steps"></div>
        </div>
    </div>
    
    <!-- ================================================================ -->
    <!-- TOOLS & FUTURE MONITORS                                          -->
    <!-- ================================================================ -->
    <div class="section" id="tools-section">
        <div class="section-header">
            <h2>Tools & Processes</h2>
        </div>
        <div class="section-body">
            <div class="tool-cards">
                <div class="tool-card" id="bdl-import-card" onclick="window.location.href='/bdl-import'">
                    <div class="tool-icon">&#128230;</div>
                    <div class="tool-label">BDL Import</div>
                    <div class="tool-status">Open</div>
                </div>
                <div class="tool-card placeholder">
                    <div class="tool-icon">&#128222;</div>
                    <div class="tool-label">LiveVox</div>
                    <div class="tool-status">Phase 2</div>
                </div>
                <div class="tool-card placeholder">
                    <div class="tool-icon">&#128172;</div>
                    <div class="tool-label">SndRight Texting</div>
                    <div class="tool-status">Phase 2</div>
                </div>
            </div>
        </div>
    </div>
    
    <script src="/js/business-intelligence.js"></script>
</body>
</html>
"@
    Write-PodeHtmlResponse -Value $html
}
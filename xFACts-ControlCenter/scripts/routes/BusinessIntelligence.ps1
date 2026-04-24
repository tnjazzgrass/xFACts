# ============================================================================
# xFACts Control Center - Business Intelligence Departmental Page
# Location: E:\xFACts-ControlCenter\scripts\routes\BusinessIntelligence.ps1
# 
# Departmental dashboard for the Business Intelligence team.
# Components:
#   - Tools & Processes tile row:
#       * Notice Recon: Horizontal status badges for daily reconciliation
#         processes (SndRight, Revspring, Validation, FAND). Each badge
#         is independently clickable to open a detail slideout.
#       * BDL Import: Links to Tools BDL Import page.
#       * LiveVox / SndRight Texting: Placeholder tiles for Phase 2 monitors.
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
    <link rel="stylesheet" href="/css/engine-events.css">
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
    <!-- TOOLS & PROCESSES                                                -->
    <!-- ================================================================ -->
    <div class="section" id="tools-section">
        <div class="section-header">
            <h2>Tools & Processes</h2>
        </div>
        <div class="section-body">
            <div class="tool-cards">
                <!-- Notice Recon: status-badge tile (badges rendered/updated by JS) -->
                <div class="tool-card notice-recon-tile">
                    <div class="nr-badges" id="nr-badges"></div>
                    <div class="tool-label">Notice Recon</div>
                    <div class="tool-status">Daily Reconciliation</div>
                </div>
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
    
    <!-- ================================================================ -->
    <!-- EXECUTION DETAIL SLIDEOUT                                        -->
    <!-- ================================================================ -->
    <div id="nr-detail-overlay" class="slide-panel-overlay" onclick="BI.closeDetail()"></div>
    <div id="nr-detail-panel" class="slide-panel wide">
        <div class="slide-panel-header">
            <h3 id="nr-detail-title">Execution Detail</h3>
            <button class="modal-close" onclick="BI.closeDetail()" title="Close">&times;</button>
        </div>
        <div class="slide-panel-body">
            <div id="nr-detail-content"></div>
        </div>
    </div>
    
    <script src="/js/business-intelligence.js"></script>
</body>
</html>
"@
    Write-PodeHtmlResponse -Value $html
}
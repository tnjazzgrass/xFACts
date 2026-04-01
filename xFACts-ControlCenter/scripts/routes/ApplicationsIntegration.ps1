# ============================================================================
# xFACts Control Center - Applications & Integration Departmental Page
# Location: E:\xFACts-ControlCenter\scripts\routes\ApplicationsIntegration.ps1
# 
# Departmental dashboard for the Applications & Integration team.
# Components:
#   - BDL Import: Card linking to the BDL Import workflow page
#   - Future: Additional toolkit functions migrated from Access DB
#
# CSS: /css/applications-integration.css
# JS:  (none currently — static page with card links)
#
# Version: Tracked in dbo.System_Metadata (component: DeptOps.ApplicationsIntegration)
# ============================================================================

Add-PodeRoute -Method Get -Path '/departmental/applications-integration' -Authentication 'ADLogin' -ScriptBlock {
    
    # --- RBAC Access Check ---
    $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/departmental/applications-integration'
    if (-not $access.HasAccess) {
        Write-PodeHtmlResponse -Value (Get-AccessDeniedHtml -DisplayName $access.DisplayName -PageRoute '/departmental/applications-integration') -StatusCode 403
        return
    }
    
    # --- Admin gear icon (visible only to admin role holders) ---
    $ctx = Get-UserContext -WebEvent $WebEvent
    $adminGear = if ($ctx.IsAdmin) {
        '<span class="nav-spacer"></span><a href="/admin" class="nav-link nav-admin" title="Administration">&#9881;</a>'
    } else { '' }
    
    # IT users always get the full nav
    $navHtml = @'
    <nav class="nav-bar">
        <a href="/" class="nav-link">Home</a>
        <a href="/server-health" class="nav-link">Server Health</a>
        <a href="/jobflow-monitoring" class="nav-link">Job/Flow Monitoring</a>
        <a href="/batch-monitoring" class="nav-link">Batch Monitoring</a>
        <a href="/backup" class="nav-link">Backup Monitoring</a>
        <a href="/index-maintenance" class="nav-link">Index Maintenance</a>
        <a href="/dbcc-operations" class="nav-link">DBCC Operations</a>
        <a href="/bidata-monitoring" class="nav-link">BIDATA Monitoring</a>
        <a href="/file-monitoring" class="nav-link">File Monitoring</a>
        <a href="/replication-monitoring" class="nav-link">Replication Monitoring</a>
        <a href="/jboss-monitoring" class="nav-link">JBoss Monitoring</a>
        <a href="/dm-operations" class="nav-link">DM Operations</a>
        <span class="nav-separator">|</span>
        <a href="/departmental/applications-integration" class="nav-link active">Apps/Int</a>
        <a href="/departmental/business-services" class="nav-link">Business Services</a>
        <a href="/departmental/business-intelligence" class="nav-link">Business Intelligence</a>
        <a href="/departmental/client-relations" class="nav-link">Client Relations</a>
    </nav>
'@
    
    $navHtml = $navHtml.Replace('</nav>', "$adminGear</nav>")
    
    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>Applications & Integration - xFACts Control Center</title>
    <link rel="stylesheet" href="/css/applications-integration.css">
</head>
<body>
    $navHtml
    
    <div class="header-bar">
        <div>
            <h1>Applications &amp; Integration</h1>
            <p class="page-subtitle">Departmental Operations &amp; Tools</p>
        </div>
    </div>
    
    <div id="connection-error" class="connection-error"></div>
    
    <!-- ================================================================ -->
    <!-- DM TOOLS                                                         -->
    <!-- ================================================================ -->
    <div class="section" id="tools-section">
        <div class="section-header">
            <h2>Debt Manager Tools</h2>
            <span class="section-subtitle">File imports, API operations, and scheduled job management</span>
        </div>
        <div class="section-body">
            <div class="tool-cards">
                <div class="tool-card" onclick="window.location.href='/bdl-import'">
                    <div class="tool-icon">&#128230;</div>
                    <div class="tool-label">BDL Import</div>
                    <div class="tool-status">Bulk Data Load</div>
                </div>
                <div class="tool-card placeholder">
                    <div class="tool-icon">&#128176;</div>
                    <div class="tool-label">Payment Import</div>
                    <div class="tool-status">Phase 3</div>
                </div>
                <div class="tool-card placeholder">
                    <div class="tool-icon">&#9881;</div>
                    <div class="tool-label">Job Triggers</div>
                    <div class="tool-status">Phase 2</div>
                </div>
                <div class="tool-card placeholder">
                    <div class="tool-icon">&#128100;</div>
                    <div class="tool-label">Consumer Ops</div>
                    <div class="tool-status">Phase 4</div>
                </div>
                <div class="tool-card placeholder">
                    <div class="tool-icon">&#128196;</div>
                    <div class="tool-label">CDL Import</div>
                    <div class="tool-status">Future</div>
                </div>
                <div class="tool-card placeholder">
                    <div class="tool-icon">&#128268;</div>
                    <div class="tool-label">API Caller</div>
                    <div class="tool-status">Future</div>
                </div>
            </div>
        </div>
    </div>
    
</body>
</html>
"@
    Write-PodeHtmlResponse -Value $html
}
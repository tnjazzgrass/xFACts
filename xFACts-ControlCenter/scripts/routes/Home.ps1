# ============================================================================
# xFACts Control Center - Home/Dashboard Routes
# Location: E:\xFACts-ControlCenter\scripts\routes\Home.ps1
# 
# Defines the home page (dashboard) and navigation.
# Loaded by Start-ControlCenter.ps1 at startup.
# Version: Tracked in dbo.System_Metadata (component: ControlCenter.Home)
# ============================================================================
# ============================================================================

Add-PodeRoute -Method Get -Path '/' -Authentication 'ADLogin' -ScriptBlock {
    $username = $WebEvent.Auth.User.Username
    $displayName = if ($WebEvent.Auth.User.Name) { $WebEvent.Auth.User.Name } else { $username }
    
    # --- RBAC: Check if dept-only user (redirect to their department page) ---
    $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/'
    
    # --- Admin gear icon (visible only to admin role holders) ---
    $ctx = Get-UserContext -WebEvent $WebEvent
    $adminGear = if ($ctx.IsAdmin) {
        '<a href="/admin" class="admin-gear" title="Administration">&#9881;</a>'
    } else { '' }
    
    if (-not $access.HasAccess -and $access.IsDeptOnly -and $access.DepartmentScopes.Count -gt 0) {
        # Dept-only user with no Home access -- redirect to their department page
        $deptKey = $access.DepartmentScopes[0]
        $deptPages = Invoke-XFActsQuery -Query "SELECT page_route FROM dbo.RBAC_DepartmentRegistry WHERE department_key = @key AND is_active = 1" -Parameters @{ key = $deptKey }
        if ($deptPages -and $deptPages.Count -gt 0) {
            Move-PodeResponseUrl -Url $deptPages[0].page_route
            return
        }
    }
    
    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>xFACts Control Center</title>
    <style>
        body { 
            font-family: 'Segoe UI', Arial, sans-serif; 
            margin: 0; 
            padding: 40px; 
            background: #1e1e1e; 
            color: #d4d4d4; 
        }
        h1 { color: #569cd6; margin-bottom: 10px; }
        h1 a { color: inherit; text-decoration: none; transition: color 0.2s ease; }
        h1 a:hover { color: #9cdcfe; }
        .subtitle { color: #888; margin-bottom: 40px; }
        .section-header {
            color: #888;
            font-size: 13px;
            text-transform: uppercase;
            letter-spacing: 1px;
            margin-bottom: 15px;
            padding-bottom: 8px;
            border-bottom: 1px solid #333;
        }
        .section-spacer { margin-top: 35px; }
        .nav-grid {
            display: grid;
            grid-template-columns: repeat(auto-fill, 280px);
            gap: 20px;
        }
        .nav-card {
            background: #2d2d2d;
            border: 1px solid #404040;
            border-radius: 8px;
            padding: 20px;
            text-decoration: none;
            color: inherit;
            transition: all 0.2s;
            min-height: 100px;
        }
        .nav-card:hover {
            border-color: #569cd6;
            background: #333;
        }
        .nav-card h3 { color: #4ec9b0; margin: 0 0 10px 0; }
        .nav-card p { margin: 0; color: #888; font-size: 14px; }
        .nav-card.dept-card:hover {
            border-color: #dcdcaa;
        }
        .nav-card.dept-card h3 { color: #dcdcaa; }
        .user-bar {
            position: fixed;
            top: 0;
            left: 0;
            right: 0;
            background: #252526;
            border-bottom: 1px solid #404040;
            padding: 10px 20px;
            display: flex;
            justify-content: space-between;
            align-items: center;
            font-size: 13px;
        }
        .user-info { color: #888; }
        .user-name { color: #4ec9b0; font-weight: 500; }
        .logout-link { color: #888; text-decoration: none; }
        .logout-link:hover { color: #d4d4d4; }
        .user-bar-right { display: flex; align-items: center; gap: 16px; }
        .admin-gear { 
            color: #569cd6; text-decoration: none; font-size: 20px; 
            opacity: 0.45; transition: opacity 0.2s; line-height: 1;
        }
        .admin-gear:hover { opacity: 1; }
        .main-content { margin-top: 50px; }
        .status-bar {
            position: fixed;
            bottom: 0;
            left: 0;
            right: 0;
            background: #252526;
            border-top: 1px solid #404040;
            padding: 8px 20px;
            font-size: 12px;
            color: #888;
        }
    </style>
</head>
<body>
    <div class="user-bar">
        <div class="user-info">Signed in as <span class="user-name">$displayName</span></div>
        <div class="user-bar-right">
            $adminGear
            <a href="/logout" class="logout-link">Sign Out</a>
        </div>
    </div>
    
    <div class="main-content">
        <h1><a href="/docs/pages/index.html" target="_blank">xFACts Control Center</a></h1>
        <p class="subtitle">Enterprise IT Operations Platform</p>
        
        <div class="section-header">Monitoring</div>
        <div class="nav-grid">
            <a href="/server-health" class="nav-card">
                <h3>Server Health</h3>
                <p>Real-time SQL Server performance and health monitoring</p>
            </a>
            <a href="/jobflow-monitoring" class="nav-card">
                <h3>Job/Flow Monitoring</h3>
                <p>Real-time Debt Manager queue activity, flow tracking, and execution history</p>
            </a>
            <a href="/batch-monitoring" class="nav-card">
                <h3>Batch Monitoring</h3>
                <p>Real-time Debt Manager batch activity, pipeline tracking, and execution history</p>
            </a>
            <a href="/backup" class="nav-card">
                <h3>Backup Monitoring</h3>
                <p>Real-time pipeline status, active operations, storage utilization, and pending retention</p>
            </a>
            <a href="/index-maintenance" class="nav-card">
                <h3>Index Maintenance</h3>
                <p>Real-time process status, queue management, execution progress, and database health</p>
            </a>
            </a>
            <a href="/dbcc-operations" class="nav-card">
                <h3>DBCC Operations</h3>
                <p>Real-time integrity checking progress, execution history and scheduling</p>
            </a>
            <a href="/bidata-monitoring" class="nav-card">
                <h3>BIDATA Monitoring</h3>
                <p>Real-time daily build status, step progress, duration trends, and historical tracking</p>
            </a>
            <a href="/file-monitoring" class="nav-card">
                <h3>File Monitoring</h3>
                <p>Real-time SFTP file arrival tracking, detection alerts, and escalation management</p>
            </a>
            <a href="/replication-monitoring" class="nav-card">
                <h3>Replication Monitoring</h3>
                <p>Real-time agent health, queue depth, and end-to-end latency across all publications</p>
            </a>
            <a href="/jboss-monitoring" class="nav-card">
                <h3>JBoss Monitoring</h3>
                <p>Real-time Monitoring of the JBoss Management Console for the Application Servers</p>
            </a>
            <a href="/dm-operations" class="nav-card">
                <h3>DM Operations</h3>
                <p>Real-time Monitoring of the Debt Manager Archiving Process</p>
            </a>
        </div>
        
        <div class="section-spacer"></div>
        <div class="section-header">Departmental Pages</div>
        <div class="nav-grid">
            <a href="/departmental/applications-integration" class="nav-card dept-card">
                <h3>Applications & Integration</h3>
                <p>Departmental Operations & Administrative Tools</p>
            </a>
            <a href="/departmental/business-services" class="nav-card dept-card">
                <h3>Business Services</h3>
                <p>Departmental Operations</p>
            </a>
            <a href="/departmental/business-intelligence" class="nav-card dept-card">
                <h3>Business Intelligence</h3>
                <p>Departmental Operations</p>
            </a>
            <a href="/departmental/client-relations" class="nav-card dept-card">
                <h3>Client Relations</h3>
                <p>Departmental Operations</p>
            </a>
        </div>

        <div class="section-spacer"></div>
        <div class="section-header">Tools</div>
        <div class="nav-grid">
            <a href="/client-portal" class="nav-card">
                <h3>Client Portal</h3>
                <p>Consumer and account lookup</p>
            </a>
        </div>
    </div>
    
    <div class="status-bar">
        xFACts Control Center | Port 8085 | Connected to AVG-PROD-LSNR
    </div>
</body>
</html>
"@
    Write-PodeHtmlResponse -Value $html
}
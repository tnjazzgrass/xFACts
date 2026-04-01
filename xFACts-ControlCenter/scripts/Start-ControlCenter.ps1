# ============================================================================
# xFACts Control Center
# Version: Tracked in dbo.System_Metadata (component: ControlCenter.Shared)
# Location: E:\xFACts-ControlCenter\scripts\Start-ControlCenter.ps1
# 
# Main entry point for the xFACts Control Center web interface.
# Loads helper module, configures AD authentication with RBAC audit logging,
# initializes API caching, and starts the Pode server.
#
# Usage:
#   Interactive: .\Start-ControlCenter.ps1
#   As Service:  Managed via NSSM (xFACtsControlCenter service)
#
# Prerequisites:
#   - RSAT-AD-PowerShell feature must be installed
#   - Install-WindowsFeature -Name "RSAT-AD-PowerShell"
#
# File Structure:
#   E:\xFACts-ControlCenter\
#   +-- scripts\
#   |   +-- Start-ControlCenter.ps1        # This file - main entry point
#   |   +-- modules\
#   |   |   +-- xFACts-Helpers.psm1        # Shared helper module (DB, RBAC, cache, CRS5)
#   |   +-- routes\
#   |       +-- Home.ps1                   # / route (navigation hub)
#   |       +-- {Feature}.ps1              # Page routes (one per feature)
#   |       +-- {Feature}-API.ps1          # API endpoints (one per feature)
#   +-- public\
#   |   +-- css\                           # Page-specific stylesheets
#   |   +-- js\                            # Page-specific JavaScript
#   |   +-- images\                        # Image assets
#   +-- logs\                              # Pode request/error logs (auto-generated)
#
# Authentication:
#   - Windows AD authentication via form login (fac.local)
#   - RBAC via xFACts-Helpers.psm1 (roles resolved from AD groups)
#   - User info available in routes via $WebEvent.Auth.User
# ============================================================================

Import-Module Pode

# ============================================================================
# CONFIGURATION
# ============================================================================
$script:BaseRoot = Split-Path $PSScriptRoot -Parent

$script:Config = @{
    Port        = 8085
    Address     = '*'
    ScriptRoot  = $PSScriptRoot
    PublicRoot  = Join-Path $script:BaseRoot 'public'
    LogPath     = Join-Path $script:BaseRoot 'logs'
    ADDomain    = 'fac.local'
}

# ============================================================================
# START PODE SERVER
# ============================================================================
Start-PodeServer {
    
    # ------------------------------------------
    # Server Configuration
    # ------------------------------------------
    Add-PodeEndpoint -Address $script:Config.Address -Port $script:Config.Port -Protocol Http
    Add-PodeEndpoint -Address $script:Config.Address -Port $script:Config.Port -Protocol Ws
    
    # ------------------------------------------
    # Static File Serving
    # ------------------------------------------
    Add-PodeStaticRoute -Path '/css' -Source (Join-Path $script:Config.PublicRoot 'css')
    Add-PodeStaticRoute -Path '/js' -Source (Join-Path $script:Config.PublicRoot 'js')
    Add-PodeStaticRoute -Path '/images' -Source (Join-Path $script:Config.PublicRoot 'images')
    Add-PodeStaticRoute -Path '/docs' -Source (Join-Path $script:Config.PublicRoot 'docs')
    
    # ------------------------------------------
    # Pode File Logging
    # ------------------------------------------
    New-PodeLoggingMethod -File -Name 'requests' -Path $script:Config.LogPath | Enable-PodeRequestLogging
    New-PodeLoggingMethod -File -Name 'errors' -Path $script:Config.LogPath | Enable-PodeErrorLogging
    
    # ------------------------------------------
    # Session Middleware (required for auth)
    # ------------------------------------------
    Enable-PodeSessionMiddleware -Duration 3600 -Extend  # 1 hour session, extends on activity

    # ------------------------------------------
    # Load Helper Module (available to all runspaces)
    # Must load BEFORE auth setup and middleware so
    # Invoke-XFActsQuery and Write-RBACAuditLog are
    # available in scriptblocks.
    # ------------------------------------------
    $modulePath = Join-Path $script:Config.ScriptRoot "modules\xFACts-Helpers.psm1"
    if (Test-Path $modulePath) {
        Import-Module -Name $modulePath -Force -DisableNameChecking
        Write-Host "  Loaded module: xFACts-Helpers.psm1" -ForegroundColor DarkGray
    } else {
        Write-Host "  FATAL: xFACts-Helpers.psm1 not found at $modulePath" -ForegroundColor Red
        throw "Required module xFACts-Helpers.psm1 not found. Cannot start."
    }

    # ------------------------------------------
    # Windows AD Authentication
    # ScriptBlock runs after successful AD validation
    # to log the LOGIN_SUCCESS event with full context.
    # ------------------------------------------
    New-PodeAuthScheme -Form | Add-PodeAuthWindowsAd -Name 'ADLogin' `
        -Fqdn $script:Config.ADDomain -DirectGroups `
        -FailureUrl '/login' -SuccessUrl '/' `
        -ScriptBlock {
            param($user)
            
            try {
                $username = $user.Username
                if ($username -and $username.Contains('\')) {
                    $username = $username.Split('\')[1]
                }
                
                $groupsStr = if ($user.Groups) { ($user.Groups -join ', ') } else { $null }
                if ($groupsStr -and $groupsStr.Length -gt 2000) {
                    $groupsStr = $groupsStr.Substring(0, 1997) + '...'
                }
                
                $clientIp = $WebEvent.Request.RemoteEndPoint.Address.ToString()
                
                Invoke-XFActsQuery -Query @"
                    INSERT INTO dbo.RBAC_AuditLog 
                        (event_type, username, ad_groups, result, detail, client_ip)
                    VALUES 
                        (@eventType, @username, @adGroups, @result, @detail, @clientIp)
"@ -Parameters @{
                    eventType = 'LOGIN_SUCCESS'
                    username  = $(if ($username) { $username } else { [DBNull]::Value })
                    adGroups  = $(if ($groupsStr) { $groupsStr } else { [DBNull]::Value })
                    result    = 'ALLOWED'
                    detail    = "AD authentication successful for $($user.Name)"
                    clientIp  = $(if ($clientIp) { $clientIp } else { [DBNull]::Value })
                }
            }
            catch {
                # Login logging must never prevent access
            }
            
            # Pass the user through - required for Pode to complete authentication
            return @{ User = $user }
        }
    
    # ------------------------------------------
    # API Request Logging Middleware
    # Captures request start time for duration calculation.
    # ------------------------------------------
    Add-PodeMiddleware -Name 'APIRequestLogging' -ScriptBlock {
        $WebEvent.Metadata['RequestStart'] = Get-Date
        return $true
    }
    
    # ------------------------------------------
    # Request Logging Endware
    # Logs all non-static requests to dbo.API_RequestLog.
    # Also detects failed login attempts for RBAC audit.
    # ------------------------------------------
    Add-PodeEndware -ScriptBlock {
        try {
            $endpoint = $WebEvent.Path
            $method = $WebEvent.Method

            # Skip logging for static assets - no analytical value
            if ($endpoint -match '^\/(css|js|images)\/|^\/favicon\.ico$') {
                return
            }

            $startTime = $WebEvent.Metadata['RequestStart']
            $endTime = Get-Date
            $durationMs = if ($startTime) { [int]($endTime - $startTime).TotalMilliseconds } else { $null }
            $userName = $WebEvent.Auth.User.Name
            $clientIp = $WebEvent.Request.RemoteEndPoint.Address.ToString()
            $userAgent = $WebEvent.Request.Headers['User-Agent']
            $statusCode = $WebEvent.Response.StatusCode
            
            $responseBytes = $null
            if ($WebEvent.Response.ContentLength64 -gt 0) {
                $responseBytes = $WebEvent.Response.ContentLength64
            }
            
            if ($userAgent -and $userAgent.Length -gt 500) {
                $userAgent = $userAgent.Substring(0, 500)
            }
            
            # Log to API_RequestLog via helper module (AG-safe connection)
            Invoke-XFActsQuery -Query @"
                INSERT INTO dbo.API_RequestLog 
                    (endpoint, http_method, user_name, client_ip, user_agent, 
                     request_dttm, duration_ms, status_code, response_bytes, source_application)
                VALUES 
                    (@endpoint, @method, @userName, @clientIp, @userAgent, 
                     @requestDttm, @durationMs, @statusCode, @responseBytes, @sourceApp)
"@ -Parameters @{
                endpoint    = $endpoint
                method      = $method
                userName    = $(if ($userName) { $userName } else { [DBNull]::Value })
                clientIp    = $(if ($clientIp) { $clientIp } else { [DBNull]::Value })
                userAgent   = $(if ($userAgent) { $userAgent } else { [DBNull]::Value })
                requestDttm = $endTime
                durationMs  = $(if ($null -ne $durationMs) { $durationMs } else { [DBNull]::Value })
                statusCode  = $(if ($statusCode) { $statusCode } else { [DBNull]::Value })
                responseBytes = $(if ($null -ne $responseBytes) { $responseBytes } else { [DBNull]::Value })
                sourceApp   = 'ControlCenter'
            }
            
            # Detect failed login attempts: POST to /auth/login with no authenticated user
            if ($endpoint -eq '/auth/login' -and $method -eq 'POST' -and -not $WebEvent.Auth.User) {
                $attemptedUser = $WebEvent.Data.username
                
                Invoke-XFActsQuery -Query @"
                    INSERT INTO dbo.RBAC_AuditLog 
                        (event_type, username, result, detail, client_ip)
                    VALUES 
                        (@eventType, @username, @result, @detail, @clientIp)
"@ -Parameters @{
                    eventType = 'LOGIN_FAILURE'
                    username  = $(if ($attemptedUser) { $attemptedUser } else { [DBNull]::Value })
                    result    = 'DENIED'
                    detail    = "AD authentication failed for user '$attemptedUser'"
                    clientIp  = $(if ($clientIp) { $clientIp } else { [DBNull]::Value })
                }
            }
        }
        catch {
            # Logging must never break requests
        }
    }
    
    # ------------------------------------------
    # Login Page Route
    # ------------------------------------------
    Add-PodeRoute -Method Get -Path '/login' -ScriptBlock {
        # Check if already logged in
        if ($WebEvent.Auth.User) {
            Move-PodeResponseUrl -Url '/'
            return
        }
        
        $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>Login - xFACts Control Center</title>
    <style>
        * { box-sizing: border-box; }
        body { 
            font-family: 'Segoe UI', Arial, sans-serif; 
            margin: 0; 
            padding: 0;
            background: #1e1e1e; 
            color: #d4d4d4;
            display: flex;
            justify-content: center;
            align-items: center;
            min-height: 100vh;
        }
        .login-container {
            background: #252526;
            border: 1px solid #404040;
            border-radius: 8px;
            padding: 40px;
            width: 100%;
            max-width: 400px;
        }
        .login-header {
            text-align: center;
            margin-bottom: 30px;
        }
        .login-header h1 {
            color: #569cd6;
            font-size: 24px;
            margin: 0 0 5px 0;
        }
        .login-header p {
            color: #888;
            font-size: 14px;
            margin: 0;
        }
        .form-group {
            margin-bottom: 20px;
        }
        .form-group label {
            display: block;
            color: #888;
            font-size: 12px;
            text-transform: uppercase;
            letter-spacing: 1px;
            margin-bottom: 8px;
        }
        .form-group input {
            width: 100%;
            padding: 12px;
            background: #3c3c3c;
            border: 1px solid #555;
            border-radius: 4px;
            color: #d4d4d4;
            font-size: 14px;
        }
        .form-group input:focus {
            outline: none;
            border-color: #569cd6;
        }
        .login-btn {
            width: 100%;
            padding: 12px;
            background: #4ec9b0;
            border: none;
            border-radius: 4px;
            color: #1e1e1e;
            font-size: 14px;
            font-weight: 600;
            cursor: pointer;
            transition: background 0.2s;
        }
        .login-btn:hover {
            background: #3db89f;
        }
        .domain-hint {
            text-align: center;
            margin-top: 15px;
            font-size: 12px;
            color: #666;
        }
    </style>
</head>
<body>
    <div class="login-container">
        <div class="login-header">
            <h1>xFACts Control Center</h1>
            <p>Sign in with your network credentials</p>
        </div>
        <form method="POST" action="/auth/login">
            <div class="form-group">
                <label for="username">Username</label>
                <input type="text" id="username" name="username" placeholder="Enter your username" required autofocus>
            </div>
            <div class="form-group">
                <label for="password">Password</label>
                <input type="password" id="password" name="password" placeholder="Enter your password" required>
            </div>
            <button type="submit" class="login-btn">Sign In</button>
        </form>
        <div class="domain-hint">Domain: FAC</div>
    </div>
</body>
</html>
"@
        Write-PodeHtmlResponse -Value $html
    }
    
    # Login POST handler - uses the auth scheme's FailureUrl/SuccessUrl
    Add-PodeRoute -Method Post -Path '/auth/login' -Authentication 'ADLogin' -Login
    
    # Logout route
    Add-PodeRoute -Method Post -Path '/logout' -Authentication 'ADLogin' -Logout -ScriptBlock {
        Move-PodeResponseUrl -Url '/login'
    }
    
    # Logout via GET (for convenience)
    Add-PodeRoute -Method Get -Path '/logout' -ScriptBlock {
        Remove-PodeSession
        Move-PodeResponseUrl -Url '/login'
    }
    
    Write-Host "xFACts Control Center starting on port $($script:Config.Port)..." -ForegroundColor Cyan
    Write-Host "  Authentication: Windows AD ($($script:Config.ADDomain))" -ForegroundColor DarkGray

    # ------------------------------------------
    # API Cache Initialization
    # ------------------------------------------
    # Shared cache for API endpoint results. Uses Pode shared state
    # with a named lockable for thread-safe cross-runspace access.
    # TTL settings are loaded from GlobalConfig and refreshed periodically.
    New-PodeLockable -Name 'ApiCache'
    Set-PodeState -Name 'ApiCache' -Value @{}
    Set-PodeState -Name 'ApiCacheConfig' -Value @{}
    
    # Load initial cache TTL configuration from GlobalConfig
    Initialize-ApiCacheConfig
    Write-Host "  API cache initialized" -ForegroundColor DarkGray
    
    # Refresh cache TTL configuration from GlobalConfig every 5 minutes
    Add-PodeTimer -Name 'RefreshApiCacheConfig' -Interval 300 -ScriptBlock {
        Initialize-ApiCacheConfig
    }

    # ------------------------------------------
    # Engine Events (Real-Time WebSocket Push)
    # ------------------------------------------
    # Shared state holds latest engine event per process. Populated by
    # the internal POST route when the Orchestrator engine pushes events.
    # Used by the bootstrap GET route to hydrate pages on initial load.
    New-PodeLockable -Name 'EngineState'
    Set-PodeState -Name 'EngineState' -Value @{}

    Write-Host "  Engine events initialized (WebSocket on port $($script:Config.Port))" -ForegroundColor DarkGray

    # ------------------------------------------
    # Engine Event Routes (Internal + Bootstrap)
    # ------------------------------------------

    # POST /api/internal/engine-event
    # Receives process execution events from the Orchestrator engine.
    # Localhost-only -- no authentication required.
    # Stores latest event in shared state and broadcasts via WebSocket.
    Add-PodeRoute -Method Post -Path '/api/internal/engine-event' -ScriptBlock {
        # Localhost-only security check
        $remoteIp = $WebEvent.Request.RemoteEndPoint.Address.ToString()
        if ($remoteIp -notin @('127.0.0.1', '::1')) {
            Set-PodeResponseStatus -Code 403
            Write-PodeJsonResponse -Value @{ error = 'Forbidden: localhost only' }
            return
        }

        try {
            # $WebEvent.Data is a PSObject (not hashtable) -- use dot-notation
            $event = $WebEvent.Data

            # Store latest event per process in shared state
            Lock-PodeObject -Name 'EngineState' -ScriptBlock {
                $state = Get-PodeState -Name 'EngineState'
                $state[$event.processName] = $event
            }

            # Broadcast to all connected WebSocket clients
            $json = $event | ConvertTo-Json -Compress
            Send-PodeSignal -Value $json -Path '/engine-events'

            Write-PodeJsonResponse -Value @{ received = $true }
        }
        catch {
            Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
        }
    }

# GET /api/engine/state
    # Returns latest engine event per process for initial page load.
    # First checks in-memory state (populated by WebSocket push events).
    # Falls back to ProcessRegistry + TaskLog for processes that haven't
    # pushed an event since the last CC restart (e.g., once-daily processes
    # that already ran today). This ensures engine indicators populate
    # immediately rather than staying dark until the next execution.
    Add-PodeRoute -Method Get -Path '/api/engine/state' -Authentication 'ADLogin' -ScriptBlock {
        try {
            $state = @{}
            Lock-PodeObject -Name 'EngineState' -ScriptBlock {
                $raw = Get-PodeState -Name 'EngineState'
                foreach ($key in $raw.Keys) {
                    $state[$key] = $raw[$key]
                }
            }

            # Fall back to database for processes not yet in memory
            $dbState = Invoke-XFActsQuery -Query @"
                SELECT
                    p.process_name,
                    p.module_name,
                    p.interval_seconds,
                    CONVERT(VARCHAR(8), p.scheduled_time, 108) AS scheduled_time,
                    p.run_mode,
                    p.running_count,
                    t.task_id,
                    t.task_status,
                    t.start_dttm,
                    t.end_dttm,
                    t.duration_ms,
                    t.exit_code,
                    t.output_summary
                FROM Orchestrator.ProcessRegistry p
                OUTER APPLY (
                    SELECT TOP 1 tl.task_id, tl.task_status, tl.start_dttm,
                           tl.end_dttm, tl.duration_ms, tl.exit_code, tl.output_summary
                    FROM Orchestrator.TaskLog tl
                    WHERE tl.process_id = p.process_id
                    ORDER BY tl.start_dttm DESC
                ) t
                WHERE p.run_mode > 0
"@

            if ($dbState) {
                foreach ($row in @($dbState)) {
                    $procName = $row.process_name
                    # Skip if we already have in-memory state for this process
                    if ($state.ContainsKey($procName)) { continue }

                    # Skip if no task history at all
                    if ($row.task_id -is [DBNull] -or -not $row.task_id) { continue }

                    # Determine event type based on current state
                    $isRunning = ($row.running_count -gt 0) -or
                                 ($row.task_status -in @('LAUNCHED', 'RUNNING'))
                    $eventType = if ($isRunning) { 'PROCESS_STARTED' } else { 'PROCESS_COMPLETED' }

                    $timestamp = if ($isRunning -and $row.start_dttm -and $row.start_dttm -isnot [DBNull]) {
                        $row.start_dttm.ToString("yyyy-MM-ddTHH:mm:ss.fff")
                    } elseif ($row.end_dttm -and $row.end_dttm -isnot [DBNull]) {
                        $row.end_dttm.ToString("yyyy-MM-ddTHH:mm:ss.fff")
                    } else {
                        $row.start_dttm.ToString("yyyy-MM-ddTHH:mm:ss.fff")
                    }

                    $state[$procName] = [PSCustomObject]@{
                        eventType       = $eventType
                        processName     = $procName
                        moduleName      = $row.module_name
                        taskId          = [long]$row.task_id
                        timestamp       = $timestamp
                        status          = if ($row.task_status -isnot [DBNull]) { $row.task_status } else { '' }
                        durationMs      = if ($row.duration_ms -isnot [DBNull]) { [int]$row.duration_ms } else { 0 }
                        exitCode        = if ($row.exit_code -isnot [DBNull]) { [int]$row.exit_code } else { 0 }
                        outputSummary   = if ($row.output_summary -isnot [DBNull]) { $row.output_summary } else { '' }
                        intervalSeconds = if ($row.interval_seconds -isnot [DBNull]) { [int]$row.interval_seconds } else { 0 }
                        scheduledTime   = if ($row.scheduled_time -isnot [DBNull]) { $row.scheduled_time } else { '' }
                        runMode         = if ($row.run_mode -isnot [DBNull]) { [int]$row.run_mode } else { 1 }
                    }
                }
            }

            Write-PodeJsonResponse -Value $state
        }
        catch {
            Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
        }
    }

    # ------------------------------------------
    # Shared Configuration Routes
    # ------------------------------------------

    # GET /api/config/refresh-interval?page={pagename}
    # Returns the live polling interval for the requested page.
    # Looks up GlobalConfig: ControlCenter | refresh_{page}_seconds
    # Used by all pages on init to set their PAGE_REFRESH_INTERVAL.
    Add-PodeRoute -Method Get -Path '/api/config/refresh-interval' -Authentication 'ADLogin' -ScriptBlock {
        try {
            $page = $WebEvent.Query['page']
            if (-not $page) {
                Write-PodeJsonResponse -Value @{ error = 'Missing page parameter' } -StatusCode 400
                return
            }

            $settingName = "refresh_${page}_seconds"
            $result = Invoke-XFActsQuery -Query @"
                SELECT setting_value 
                FROM dbo.GlobalConfig 
                WHERE module_name = 'ControlCenter' 
                  AND setting_name = @settingName 
                  AND is_active = 1
"@ -Parameters @{ settingName = $settingName }

            if ($result) {
                $interval = [int]$result.setting_value
                Write-PodeJsonResponse -Value @{ interval = $interval }
            }
            else {
                # No config found -- return default so pages always get a value
                Write-PodeJsonResponse -Value @{ interval = 30; default = $true }
            }
        }
        catch {
            Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
        }
    }

    # ------------------------------------------
    # Load Route Modules
    # ------------------------------------------
    $routesPath = Join-Path $script:Config.ScriptRoot "routes"
    if (Test-Path $routesPath) {
        Get-ChildItem -Path $routesPath -Filter "*.ps1" | ForEach-Object {
            Write-Host "  Loading route: $($_.Name)" -ForegroundColor DarkGray
            . $_.FullName
        }
    }
 
    Write-Host "Startup complete." -ForegroundColor Green
}
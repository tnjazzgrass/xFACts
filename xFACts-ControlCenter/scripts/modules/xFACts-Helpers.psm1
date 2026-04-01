# ============================================================================
# xFACts Control Center - Helper Functions Module
# Version: Tracked in dbo.System_Metadata (component: ServerOps.ServerHealth)
# Location: E:\xFACts-ControlCenter\scripts\modules\xFACts-Helpers.psm1
# 
# PowerShell module providing database connectivity and RBAC functions.
# Loaded via Import-PodeModule in Start-ControlCenter.ps1, which makes
# all exported functions available across all Pode runspaces (routes,
# middleware, etc.) automatically.
#
# Functions:
#   Database:
#     Invoke-XFActsQuery  - Execute SQL query, return results as hashtables
#     Invoke-XFActsProc   - Execute stored procedure, capture PRINT messages
#
#   RBAC:
#     Get-UserAccess          - Page-level access check (use in page routes)
#     Test-ActionPermission   - Action-level permission check (use in API routes)
#     Get-UserContext         - User identity/role context for UI rendering
#     Get-AccessDeniedHtml    - Styled 403 page matching Control Center theme
#     Get-ActionDeniedResponse - Standardized 403 JSON for API endpoints
# ============================================================================

$script:ConnectionString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Application Name=xFACts Control Center;"

function Invoke-XFActsQuery {
    <#
    .SYNOPSIS
        Executes a SQL query and returns results as an array of hashtables.
    .PARAMETER Query
        The SQL query to execute.
    .PARAMETER Parameters
        Optional hashtable of parameters for parameterized queries.
    .EXAMPLE
        $results = Invoke-XFActsQuery -Query "SELECT * FROM dbo.ServerRegistry"
    .EXAMPLE
        $results = Invoke-XFActsQuery -Query "SELECT * FROM dbo.ServerRegistry WHERE server_id = @id" -Parameters @{ id = 1 }
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Query,
        
        [hashtable]$Parameters = @{}
    )
    
    $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Application Name=xFACts Control Center;"
    $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
    try {
        $conn.Open()
        
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $Query
        $cmd.CommandTimeout = 30
        
        # Add parameters if provided
        foreach ($key in $Parameters.Keys) {
            $cmd.Parameters.AddWithValue("@$key", $Parameters[$key]) | Out-Null
        }
        
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        
        $results = @()
        if ($dataset.Tables.Count -gt 0) {
            foreach ($row in $dataset.Tables[0].Rows) {
                $obj = @{}
                foreach ($col in $dataset.Tables[0].Columns) {
                    $obj[$col.ColumnName] = $row[$col.ColumnName]
                }
                $results += $obj
            }
        }
        return ,$results
    }
    finally {
        if ($conn.State -eq 'Open') { $conn.Close() }
    }
}

function Invoke-XFActsProc {
    <#
    .SYNOPSIS
        Executes a stored procedure and captures PRINT/RAISERROR messages.
    .PARAMETER ProcName
        The fully qualified stored procedure name (e.g., "ServerOps.sp_DiagnoseServerHealth").
    .PARAMETER Parameters
        Optional hashtable of parameters to pass to the procedure.
    .RETURNS
        An ArrayList of messages captured from PRINT/RAISERROR statements.
    .EXAMPLE
        $messages = Invoke-XFActsProc -ProcName "ServerOps.sp_DiagnoseServerHealth" -Parameters @{ server_name = "AVG-PROD-LSNR"; lookback_minutes = 60 }
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ProcName,
        
        [hashtable]$Parameters = @{}
    )
    
    $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Application Name=xFACts Control Center;"
    $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
    
    # Capture PRINT/RAISERROR messages
    $messages = [System.Collections.ArrayList]::new()
    $handler = [System.Data.SqlClient.SqlInfoMessageEventHandler]{
        param($sender, $event)
        $messages.Add($event.Message) | Out-Null
    }
    $conn.add_InfoMessage($handler)
    $conn.FireInfoMessageEventOnUserErrors = $true
    
    try {
        $conn.Open()
        
        $cmd = $conn.CreateCommand()
        $cmd.CommandType = [System.Data.CommandType]::StoredProcedure
        $cmd.CommandText = $ProcName
        $cmd.CommandTimeout = 120  # 2 minutes for diagnostic procs
        
        foreach ($key in $Parameters.Keys) {
            $cmd.Parameters.AddWithValue("@$key", $Parameters[$key]) | Out-Null
        }
        
        $cmd.ExecuteNonQuery() | Out-Null
        
        return $messages
    }
    finally {
        if ($conn.State -eq 'Open') { $conn.Close() }
    }
}

function Invoke-XFActsNonQuery {
    <#
    .SYNOPSIS
        Executes a non-query SQL statement (INSERT, UPDATE, DELETE, CREATE, ALTER, DROP) against the xFACts database.
    .PARAMETER Query
        The SQL statement to execute.
    .PARAMETER Parameters
        Optional hashtable of parameters for parameterized queries.
    .PARAMETER TimeoutSeconds
        Command timeout in seconds (default: 30).
    .RETURNS
        The number of rows affected (for DML statements). DDL statements return -1.
    .EXAMPLE
        $rows = Invoke-XFActsNonQuery -Query "UPDATE dbo.GlobalConfig SET setting_value = @val WHERE config_id = @id" -Parameters @{ val = '10'; id = 5 }
    .EXAMPLE
        Invoke-XFActsNonQuery -Query "CREATE TABLE Staging.[MyTable] ([id] INT, [name] VARCHAR(50))"
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Query,
        
        [hashtable]$Parameters = @{},

        [int]$TimeoutSeconds = 30
    )
    
    $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Application Name=xFACts Control Center;"
    $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
    try {
        $conn.Open()
        
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $Query
        $cmd.CommandTimeout = $TimeoutSeconds
        
        foreach ($key in $Parameters.Keys) {
            $cmd.Parameters.AddWithValue("@$key", $Parameters[$key]) | Out-Null
        }
        
        $rowsAffected = $cmd.ExecuteNonQuery()
        return $rowsAffected
    }
    finally {
        if ($conn.State -eq 'Open') { $conn.Close() }
    }
}

# ============================================================================
# RBAC (Role-Based Access Control) Functions
# ============================================================================
# Provides permission evaluation for the Control Center.
# AD groups -> Roles -> Page permissions -> Action grants
#
# Usage in routes:
#   # Page-level access check
#   $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/server-health'
#   if (-not $access.HasAccess) {
#       Write-PodeHtmlResponse -Value (Get-AccessDeniedHtml -DisplayName $access.DisplayName) -StatusCode 403
#       return
#   }
#
#   # Action-level permission check
#   if (-not (Test-ActionPermission -WebEvent $WebEvent -PageRoute '/server-health' -ActionName 'kill-zombie')) {
#       Write-PodeJsonResponse -Value (Get-ActionDeniedResponse -ActionName 'kill-zombie') -StatusCode 403
#       return
#   }
#
#   # UI rendering context
#   $ctx = Get-UserContext -WebEvent $WebEvent
#   if ($ctx.IsAdmin) { # show admin controls }
# ============================================================================

# ----------------------------------------------------------------------------
# RBAC Cache
# All RBAC tables loaded into memory, refreshed every 5 minutes.
# Avoids querying the database on every request.
# ----------------------------------------------------------------------------
$script:RBACCache = @{
    Roles            = $null
    RoleMappings     = $null
    PagePermissions  = $null
    ActionGrants     = $null
    ActionRegistry   = $null
    DepartmentPages  = $null
    EnforcementMode  = 'disabled'
    AuditVerbosity   = 'denials_only'
    LastRefresh      = [datetime]::MinValue
    CacheDurationSec = 300  # 5 minutes
}

function Initialize-RBACCache {
    <#
    .SYNOPSIS
        Loads RBAC configuration from the database into memory cache.
        Called on first request and refreshed every CacheDurationSec seconds.
    #>
    
    try {
        # Load roles
        $script:RBACCache.Roles = Invoke-XFActsQuery -Query @"
            SELECT role_id, role_name, role_tier, display_order
            FROM dbo.RBAC_Role
            WHERE is_active = 1
"@

        # Load role mappings
        $script:RBACCache.RoleMappings = Invoke-XFActsQuery -Query @"
            SELECT rm.mapping_id, rm.ad_group_name, rm.role_id, rm.department_scope,
                   r.role_name, r.role_tier
            FROM dbo.RBAC_RoleMapping rm
            INNER JOIN dbo.RBAC_Role r ON r.role_id = rm.role_id
            WHERE rm.is_active = 1 AND r.is_active = 1
"@

        # Load page permissions
        $script:RBACCache.PagePermissions = Invoke-XFActsQuery -Query @"
            SELECT pp.permission_id, pp.role_id, pp.page_route, pp.permission_tier,
                   r.role_name
            FROM dbo.RBAC_PermissionMapping pp
            INNER JOIN dbo.RBAC_Role r ON r.role_id = pp.role_id
            WHERE pp.is_active = 1 AND r.is_active = 1
"@

        # Load action grants
        $script:RBACCache.ActionGrants = Invoke-XFActsQuery -Query @"
            SELECT ag.grant_id, ag.grant_type, ag.grant_scope, ag.role_id, ag.username,
                   ar.page_route, ar.action_name, ar.api_endpoint, ar.required_tier,
                   r.role_name
            FROM dbo.RBAC_ActionGrant ag
            INNER JOIN dbo.RBAC_ActionRegistry ar ON ar.action_id = ag.action_id
            LEFT JOIN dbo.RBAC_Role r ON r.role_id = ag.role_id
            WHERE ag.is_active = 1 AND ar.is_active = 1
"@

        # Load department pages
        $script:RBACCache.DepartmentPages = Invoke-XFActsQuery -Query @"
            SELECT department_id, department_key, department_name, page_route
            FROM dbo.RBAC_DepartmentRegistry
            WHERE is_active = 1
"@

        # Load action registry (for middleware endpoint lookup)
        $script:RBACCache.ActionRegistry = Invoke-XFActsQuery -Query @"
            SELECT action_id, action_name, api_endpoint, http_method,
                   page_route, required_tier
            FROM dbo.RBAC_ActionRegistry
            WHERE is_active = 1
"@

        # Load enforcement mode from GlobalConfig
        $configResults = Invoke-XFActsQuery -Query @"
            SELECT setting_name, setting_value
            FROM dbo.GlobalConfig
            WHERE module_name = 'ControlCenter'
              AND category = 'RBAC'
              AND is_active = 1
"@

        foreach ($config in $configResults) {
            switch ($config.setting_name) {
                'rbac_enforcement_mode' { $script:RBACCache.EnforcementMode = $config.setting_value }
                'rbac_audit_verbosity'  { $script:RBACCache.AuditVerbosity = $config.setting_value }
            }
        }

        $script:RBACCache.LastRefresh = Get-Date
    }
    catch {
        # If cache load fails, use stale cache or defaults
        # RBAC issues should not take down the Control Center
    }
}

function Confirm-RBACCache {
    <#
    .SYNOPSIS
        Ensures the RBAC cache is loaded and fresh.
        Call at the start of any RBAC function.
    #>
    $elapsed = (Get-Date) - $script:RBACCache.LastRefresh
    if ($null -eq $script:RBACCache.Roles -or $elapsed.TotalSeconds -gt $script:RBACCache.CacheDurationSec) {
        Initialize-RBACCache
    }
}

# ----------------------------------------------------------------------------
# Tier Comparison Helpers
# ----------------------------------------------------------------------------

function Get-TierLevel {
    <#
    .SYNOPSIS
        Converts a tier name to a numeric level for comparison.
        Higher number = more access.
    #>
    param([string]$Tier)
    
    switch ($Tier) {
        'admin'   { return 3 }
        'operate' { return 2 }
        'view'    { return 1 }
        default   { return 0 }
    }
}

function Test-TierSufficient {
    <#
    .SYNOPSIS
        Tests whether a user's tier meets or exceeds the required tier.
    #>
    param(
        [string]$UserTier,
        [string]$RequiredTier
    )
    
    return (Get-TierLevel -Tier $UserTier) -ge (Get-TierLevel -Tier $RequiredTier)
}

# ----------------------------------------------------------------------------
# Core RBAC Functions
# ----------------------------------------------------------------------------

function Resolve-UserRoles {
    <#
    .SYNOPSIS
        Resolves a user's AD groups into RBAC roles.
    .PARAMETER UserGroups
        Array of AD group names from $WebEvent.Auth.User.Groups
    .RETURNS
        Array of hashtables with role details and department scope
    #>
    param(
        [array]$UserGroups
    )
    
    Confirm-RBACCache
    
    if (-not $UserGroups -or -not $script:RBACCache.RoleMappings) {
        return @()
    }
    
    $resolvedRoles = @()
    foreach ($mapping in $script:RBACCache.RoleMappings) {
        if ($UserGroups -contains $mapping.ad_group_name) {
            $resolvedRoles += @{
                role_id          = $mapping.role_id
                role_name        = $mapping.role_name
                role_tier        = $mapping.role_tier
                department_scope = $mapping.department_scope
                ad_group_name    = $mapping.ad_group_name
            }
        }
    }
    
    return $resolvedRoles
}

function Get-UserPageTier {
    <#
    .SYNOPSIS
        Determines the highest permission tier a user has for a specific page.
    .PARAMETER UserRoles
        Array of resolved roles from Resolve-UserRoles
    .PARAMETER PageRoute
        The page route to check (e.g., '/server-health')
    .RETURNS
        String tier name ('admin', 'operate', 'view') or $null if no access
    #>
    param(
        [array]$UserRoles,
        [string]$PageRoute
    )
    
    Confirm-RBACCache
    
    if (-not $UserRoles -or -not $script:RBACCache.PagePermissions) {
        return $null
    }
    
    $highestTier = $null
    $highestLevel = 0
    
    # Get all role IDs for this user
    $userRoleIds = $UserRoles | ForEach-Object { $_.role_id }
    
    foreach ($perm in $script:RBACCache.PagePermissions) {
        # Must be a role the user has
        if ($userRoleIds -notcontains $perm.role_id) { continue }
        
        # Must match the page route (exact match or wildcard)
        if ($perm.page_route -ne '*' -and $perm.page_route -ne $PageRoute) { continue }
        
        # For departmental roles, verify department scope matches the page
        # UNLESS there is an explicit permission row for this role on this exact page
        $role = $UserRoles | Where-Object { $_.role_id -eq $perm.role_id } | Select-Object -First 1
        if ($role.department_scope -and $perm.page_route -eq '*') {
            # Department-scoped role with wildcard permission -- only applies within that department
            $deptPage = $script:RBACCache.DepartmentPages | Where-Object { $_.department_key -eq $role.department_scope }
            if ($deptPage -and $PageRoute -ne $deptPage.page_route) { continue }
        }
        
        $level = Get-TierLevel -Tier $perm.permission_tier
        if ($level -gt $highestLevel) {
            $highestLevel = $level
            $highestTier = $perm.permission_tier
        }
    }
    
    return $highestTier
}

function Test-ActionPermission {
    <#
    .SYNOPSIS
        Tests whether a user can perform a specific action on a page.
        Evaluation order: User DENY > Role DENY > User ALLOW > Role ALLOW > Tier fallback
    .PARAMETER WebEvent
        The Pode WebEvent object containing auth context
    .PARAMETER PageRoute
        The page route (e.g., '/server-health')
    .PARAMETER ActionName
        The action to check (e.g., 'kill-zombie')
    .PARAMETER RequiredTier
        Minimum tier normally required for this action (default: 'operate')
    .RETURNS
        $true if the action is permitted, $false otherwise
    #>
    param(
        [Parameter(Mandatory)]$WebEvent,
        [Parameter(Mandatory)][string]$PageRoute,
        [Parameter(Mandatory)][string]$ActionName,
        [string]$RequiredTier = 'operate'
    )
    
    Confirm-RBACCache
    
    $mode = $script:RBACCache.EnforcementMode
    if ($mode -eq 'disabled') { return $true }
    
    $userGroups = $WebEvent.Auth.User.Groups
    $username = $WebEvent.Auth.User.Username
    # Strip domain prefix if present (FAC\username -> username)
    if ($username -and $username.Contains('\')) {
        $username = $username.Split('\')[1]
    }
    
    $userRoles = Resolve-UserRoles -UserGroups $userGroups
    $userRoleIds = $userRoles | ForEach-Object { $_.role_id }
    
    # Step 1: Check for user-level DENY
    $userDeny = $script:RBACCache.ActionGrants | Where-Object {
        $_.grant_type -eq 'DENY' -and
        $_.grant_scope -eq 'USER' -and
        $_.username -eq $username -and
        $_.page_route -eq $PageRoute -and
        $_.action_name -eq $ActionName
    }
    if ($userDeny) {
        Write-RBACAuditLog -EventType 'ACTION_DENIED' -Username $username -UserGroups $userGroups `
            -UserRoles $userRoles -PageRoute $PageRoute -ActionName $ActionName `
            -RequiredTier $RequiredTier -UserTier 'DENY_OVERRIDE' `
            -Result $(if ($mode -eq 'enforce') { 'DENIED' } else { 'WOULD_DENY' }) `
            -Detail "User-level DENY grant (grant_id: $($userDeny[0].grant_id))" `
            -ClientIp $WebEvent.Request.RemoteEndPoint.Address.ToString()
        return ($mode -ne 'enforce')
    }
    
    # Step 2: Check for role-level DENY
    $roleDeny = $script:RBACCache.ActionGrants | Where-Object {
        $_.grant_type -eq 'DENY' -and
        $_.grant_scope -eq 'ROLE' -and
        $userRoleIds -contains $_.role_id -and
        $_.page_route -eq $PageRoute -and
        $_.action_name -eq $ActionName
    }
    if ($roleDeny) {
        Write-RBACAuditLog -EventType 'ACTION_DENIED' -Username $username -UserGroups $userGroups `
            -UserRoles $userRoles -PageRoute $PageRoute -ActionName $ActionName `
            -RequiredTier $RequiredTier -UserTier 'DENY_OVERRIDE' `
            -Result $(if ($mode -eq 'enforce') { 'DENIED' } else { 'WOULD_DENY' }) `
            -Detail "Role-level DENY grant for $($roleDeny[0].role_name) (grant_id: $($roleDeny[0].grant_id))" `
            -ClientIp $WebEvent.Request.RemoteEndPoint.Address.ToString()
        return ($mode -ne 'enforce')
    }
    
    # Step 3: Check for user-level ALLOW
    $userAllow = $script:RBACCache.ActionGrants | Where-Object {
        $_.grant_type -eq 'ALLOW' -and
        $_.grant_scope -eq 'USER' -and
        $_.username -eq $username -and
        $_.page_route -eq $PageRoute -and
        $_.action_name -eq $ActionName
    }
    if ($userAllow) { return $true }
    
    # Step 4: Check for role-level ALLOW
    $roleAllow = $script:RBACCache.ActionGrants | Where-Object {
        $_.grant_type -eq 'ALLOW' -and
        $_.grant_scope -eq 'ROLE' -and
        $userRoleIds -contains $_.role_id -and
        $_.page_route -eq $PageRoute -and
        $_.action_name -eq $ActionName
    }
    if ($roleAllow) { return $true }
    
    # Step 5: Fall back to tier-based check
    $userTier = Get-UserPageTier -UserRoles $userRoles -PageRoute $PageRoute
    $permitted = Test-TierSufficient -UserTier $userTier -RequiredTier $RequiredTier
    
    if (-not $permitted) {
        Write-RBACAuditLog -EventType 'ACTION_DENIED' -Username $username -UserGroups $userGroups `
            -UserRoles $userRoles -PageRoute $PageRoute -ActionName $ActionName `
            -RequiredTier $RequiredTier -UserTier $userTier `
            -Result $(if ($mode -eq 'enforce') { 'DENIED' } else { 'WOULD_DENY' }) `
            -Detail "Tier insufficient: user has '$userTier', action requires '$RequiredTier'" `
            -ClientIp $WebEvent.Request.RemoteEndPoint.Address.ToString()
        return ($mode -ne 'enforce')
    }
    
    # Log successful action permission (respects verbosity setting)
    Write-RBACAuditLog -EventType 'ACTION_ALLOWED' -Username $username -UserGroups $userGroups `
        -UserRoles $userRoles -PageRoute $PageRoute -ActionName $ActionName `
        -RequiredTier $RequiredTier -UserTier $userTier `
        -Result 'ALLOWED' `
        -Detail "Action permitted with tier '$userTier'" `
        -ClientIp $WebEvent.Request.RemoteEndPoint.Address.ToString()
    
    return $true
}

function Test-ActionEndpoint {
    <#
    .SYNOPSIS
        Checks whether the current API action is permitted for the authenticated user.
        Reads the endpoint path and HTTP method from $WebEvent, looks it up in the
        ActionRegistry cache, and runs the full RBAC permission check if registered.
        
        Call at the top of any POST/PUT/DELETE route scriptblock:
            if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
        
        Unregistered endpoints are allowed through (returns $true).
        If denied in enforce mode, sends 403 JSON response before returning $false.
    .PARAMETER WebEvent
        The Pode WebEvent object containing auth context, path, and method
    .RETURNS
        $true  - Action permitted (or endpoint not registered)
        $false - Action denied (403 response already sent)
    #>
    param(
        [Parameter(Mandatory)]$WebEvent
    )
    
    Confirm-RBACCache
    
    $endpoint = $WebEvent.Path
    $method = $WebEvent.Method.ToUpper()
    
    # Look up this endpoint in the ActionRegistry cache
    $action = $script:RBACCache.ActionRegistry | Where-Object {
        $_.api_endpoint -eq $endpoint -and $_.http_method -eq $method
    }
    
    # Not registered = not protected, allow through
    if (-not $action) { return $true }
    
    # Found a registered action -- run the full permission check
    $permitted = Test-ActionPermission -WebEvent $WebEvent `
        -PageRoute $action.page_route `
        -ActionName $action.action_name `
        -RequiredTier $action.required_tier
    
    if (-not $permitted) {
        Write-PodeJsonResponse -Value @{
            error  = 'Action not permitted'
            action = $action.action_name
        } -StatusCode 403
        return $false
    }
    
    return $true
}

function Get-UserAccess {
    <#
    .SYNOPSIS
        Evaluates a user's access to a specific page. Returns an object with
        access decision, tier, roles, and department context.
    .PARAMETER WebEvent
        The Pode WebEvent object containing auth context
    .PARAMETER PageRoute
        The page route to check (e.g., '/server-health', '/departmental/business-services')
    .RETURNS
        Hashtable with: HasAccess, Tier, Roles, DepartmentScope, Username, DisplayName, IsDeptOnly
    .EXAMPLE
        $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/server-health'
        if (-not $access.HasAccess) {
            Write-PodeHtmlResponse -Value (Get-AccessDeniedHtml -DisplayName $access.DisplayName) -StatusCode 403
            return
        }
        # Use $access.Tier to conditionally render UI elements
    #>
    param(
        [Parameter(Mandatory)]$WebEvent,
        [Parameter(Mandatory)][string]$PageRoute
    )
    
    Confirm-RBACCache
    
    $mode = $script:RBACCache.EnforcementMode
    $userGroups = $WebEvent.Auth.User.Groups
    $username = $WebEvent.Auth.User.Username
    $displayName = if ($WebEvent.Auth.User.Name) { $WebEvent.Auth.User.Name } else { $username }
    
    # Strip domain prefix if present
    $cleanUsername = $username
    if ($cleanUsername -and $cleanUsername.Contains('\')) {
        $cleanUsername = $cleanUsername.Split('\')[1]
    }
    
    $userRoles = Resolve-UserRoles -UserGroups $userGroups
    
    # Determine if user is department-only (has dept roles but no platform roles)
    $hasPlatformRole = ($userRoles | Where-Object { -not $_.department_scope }) -as [bool]
    $deptScopes = @($userRoles | Where-Object { $_.department_scope } | ForEach-Object { $_.department_scope } | Select-Object -Unique)
    $isDeptOnly = (-not $hasPlatformRole) -and ($deptScopes.Count -gt 0)
    
    $result = @{
        HasAccess        = $false
        Tier             = $null
        Roles            = $userRoles
        RoleNames        = @($userRoles | ForEach-Object { $_.role_name } | Select-Object -Unique)
        DepartmentScopes = $deptScopes
        Username         = $cleanUsername
        DisplayName      = $displayName
        IsDeptOnly       = $isDeptOnly
        EnforcementMode  = $mode
    }
    
    # If disabled, grant full access
    if ($mode -eq 'disabled') {
        $result.HasAccess = $true
        $result.Tier = 'admin'  # Effectively unrestricted
        return $result
    }
    
    # Resolve tier for this page
    $tier = Get-UserPageTier -UserRoles $userRoles -PageRoute $PageRoute
    $result.Tier = $tier
    
    if ($tier) {
        $result.HasAccess = $true
        
        # Log successful page access (respects verbosity setting)
        Write-RBACAuditLog -EventType 'ACCESS_ALLOWED' -Username $cleanUsername -UserGroups $userGroups `
            -UserRoles $userRoles -PageRoute $PageRoute -RequiredTier 'view' -UserTier $tier `
            -Result 'ALLOWED' `
            -Detail "Page access granted with tier '$tier'" `
            -ClientIp $WebEvent.Request.RemoteEndPoint.Address.ToString()
    }
    else {
        # No access -- log it
        $logResult = if ($mode -eq 'enforce') { 'DENIED' } else { 'WOULD_DENY' }
        Write-RBACAuditLog -EventType $(if ($mode -eq 'enforce') { 'ACCESS_DENIED' } else { 'ACCESS_AUDIT' }) `
            -Username $cleanUsername -UserGroups $userGroups -UserRoles $userRoles `
            -PageRoute $PageRoute -RequiredTier 'view' -UserTier $null `
            -Result $logResult `
            -Detail "No page permission found for any of user's roles" `
            -ClientIp $WebEvent.Request.RemoteEndPoint.Address.ToString()
        
        # In audit mode, still allow access
        if ($mode -eq 'audit') {
            $result.HasAccess = $true
            $result.Tier = 'admin'  # Audit mode = unrestricted
        }
    }
    
    return $result
}

function Get-UserContext {
    <#
    .SYNOPSIS
        Lightweight function to get user identity and role context for UI rendering.
        Does NOT perform access checks -- use Get-UserAccess for that.
        Useful for building nav menus, showing/hiding elements, displaying user info.
    .PARAMETER WebEvent
        The Pode WebEvent object containing auth context
    .RETURNS
        Hashtable with: Username, DisplayName, Roles, RoleNames, DepartmentScopes,
        IsDeptOnly, IsAdmin, HasPlatformAccess, AccessiblePages, UserDepartments
    #>
    param(
        [Parameter(Mandatory)]$WebEvent
    )
    
    Confirm-RBACCache
    
    $userGroups = $WebEvent.Auth.User.Groups
    $username = $WebEvent.Auth.User.Username
    $displayName = if ($WebEvent.Auth.User.Name) { $WebEvent.Auth.User.Name } else { $username }
    
    # Strip domain prefix
    $cleanUsername = $username
    if ($cleanUsername -and $cleanUsername.Contains('\')) {
        $cleanUsername = $cleanUsername.Split('\')[1]
    }
    
    $userRoles = Resolve-UserRoles -UserGroups $userGroups
    $roleNames = @($userRoles | ForEach-Object { $_.role_name } | Select-Object -Unique)
    $hasPlatformRole = ($userRoles | Where-Object { -not $_.department_scope }) -as [bool]
    $deptScopes = @($userRoles | Where-Object { $_.department_scope } | ForEach-Object { $_.department_scope } | Select-Object -Unique)
    $isDeptOnly = (-not $hasPlatformRole) -and ($deptScopes.Count -gt 0)
    $isAdmin = $roleNames -contains 'Admin'
    
    # Build list of accessible pages (for nav rendering)
    $accessiblePages = @()
    if ($script:RBACCache.EnforcementMode -eq 'disabled') {
        # Everything accessible when disabled
        $accessiblePages = @('/', '/server-health', '/jobflow-monitoring', '/backup', 
                            '/index-maintenance', '/bidata-monitoring', '/file-monitoring')
        foreach ($dept in $script:RBACCache.DepartmentPages) {
            $accessiblePages += $dept.page_route
        }
    }
    else {
        # Check each known page
        $allPages = @('/', '/server-health', '/jobflow-monitoring', '/backup',
                      '/index-maintenance', '/bidata-monitoring', '/file-monitoring')
        foreach ($dept in $script:RBACCache.DepartmentPages) {
            $allPages += $dept.page_route
        }
        
        foreach ($page in $allPages) {
            $tier = Get-UserPageTier -UserRoles $userRoles -PageRoute $page
            if ($tier) { $accessiblePages += $page }
        }
    }
    
    # Build department info for departmental nav items
    $userDepartments = @()
    foreach ($scope in $deptScopes) {
        $deptPage = $script:RBACCache.DepartmentPages | Where-Object { $_.department_key -eq $scope }
        if ($deptPage) {
            $userDepartments += @{
                department_key  = $deptPage.department_key
                department_name = $deptPage.department_name
                page_route      = $deptPage.page_route
            }
        }
    }
    
    return @{
        Username          = $cleanUsername
        DisplayName       = $displayName
        Roles             = $userRoles
        RoleNames         = $roleNames
        DepartmentScopes  = $deptScopes
        UserDepartments   = $userDepartments
        IsDeptOnly        = $isDeptOnly
        IsAdmin           = $isAdmin
        HasPlatformAccess = $hasPlatformRole
        AccessiblePages   = $accessiblePages
        EnforcementMode   = $script:RBACCache.EnforcementMode
    }
}

# ----------------------------------------------------------------------------
# Audit Logging
# ----------------------------------------------------------------------------

function Write-RBACAuditLog {
    <#
    .SYNOPSIS
        Writes an event to the RBAC_AuditLog table.
        Respects the audit verbosity setting -- denials are always logged,
        ALLOWED events only logged when verbosity is 'all'.
    #>
    param(
        [Parameter(Mandatory)][string]$EventType,
        [string]$Username,
        [array]$UserGroups,
        [array]$UserRoles,
        [string]$PageRoute,
        [string]$ActionName,
        [string]$RequiredTier,
        [string]$UserTier,
        [Parameter(Mandatory)][string]$Result,
        [string]$Detail,
        [string]$ClientIp
    )
    
    # Skip ALLOWED events unless verbosity is 'all'
    if ($Result -eq 'ALLOWED' -and $script:RBACCache.AuditVerbosity -ne 'all') {
        return
    }
    
    try {
        $groupsStr = if ($UserGroups) { ($UserGroups -join ', ') } else { $null }
        $rolesStr = if ($UserRoles) { ($UserRoles | ForEach-Object { $_.role_name } | Select-Object -Unique) -join ', ' } else { $null }
        
        # Truncate if needed
        if ($groupsStr -and $groupsStr.Length -gt 2000) {
            $groupsStr = $groupsStr.Substring(0, 1997) + '...'
        }
        if ($rolesStr -and $rolesStr.Length -gt 500) {
            $rolesStr = $rolesStr.Substring(0, 497) + '...'
        }
        
        $query = @"
INSERT INTO dbo.RBAC_AuditLog 
    (event_type, username, ad_groups, resolved_roles, page_route, action_name,
     required_tier, user_tier, result, detail, client_ip)
VALUES 
    (@eventType, @username, @adGroups, @resolvedRoles, @pageRoute, @actionName,
     @requiredTier, @userTier, @result, @detail, @clientIp)
"@
        
        $params = @{
            eventType     = $EventType
            username      = $(if ($Username) { $Username } else { [DBNull]::Value })
            adGroups      = $(if ($groupsStr) { $groupsStr } else { [DBNull]::Value })
            resolvedRoles = $(if ($rolesStr) { $rolesStr } else { [DBNull]::Value })
            pageRoute     = $(if ($PageRoute) { $PageRoute } else { [DBNull]::Value })
            actionName    = $(if ($ActionName) { $ActionName } else { [DBNull]::Value })
            requiredTier  = $(if ($RequiredTier) { $RequiredTier } else { [DBNull]::Value })
            userTier      = $(if ($UserTier) { $UserTier } else { [DBNull]::Value })
            result        = $Result
            detail        = $(if ($Detail) { $Detail } else { [DBNull]::Value })
            clientIp      = $(if ($ClientIp) { $ClientIp } else { [DBNull]::Value })
        }
        
        Invoke-XFActsQuery -Query $query -Parameters $params
    }
    catch {
        # Audit logging should never break the application
    }
}

# ----------------------------------------------------------------------------
# Response Helpers
# ----------------------------------------------------------------------------

function Get-AccessDeniedHtml {
    <#
    .SYNOPSIS
        Returns a styled 403 Access Denied HTML page matching the Control Center theme.
    .PARAMETER DisplayName
        The user's display name to show on the page
    .PARAMETER PageRoute
        The page they were trying to access
    #>
    param(
        [string]$DisplayName = 'Unknown User',
        [string]$PageRoute = ''
    )
    
    return @"
<!DOCTYPE html>
<html>
<head>
    <title>Access Denied - xFACts Control Center</title>
    <style>
        body { 
            font-family: 'Segoe UI', Arial, sans-serif; 
            margin: 0; padding: 40px; 
            background: #1e1e1e; color: #d4d4d4;
            display: flex; justify-content: center; align-items: center; min-height: 90vh;
        }
        .denied-container {
            background: #252526; border: 1px solid #404040; border-radius: 8px;
            padding: 40px; max-width: 500px; text-align: center;
        }
        .denied-icon { font-size: 48px; margin-bottom: 20px; }
        h1 { color: #f14c4c; font-size: 24px; margin: 0 0 10px 0; }
        p { color: #888; margin: 10px 0; }
        .home-link {
            display: inline-block; margin-top: 20px; padding: 10px 24px;
            background: #4ec9b0; color: #1e1e1e; text-decoration: none;
            border-radius: 4px; font-weight: 600;
        }
        .home-link:hover { background: #3db89f; }
    </style>
</head>
<body>
    <div class="denied-container">
        <div class="denied-icon">&#128274;</div>
        <h1>Access Denied</h1>
        <p>Sorry $DisplayName, you don't have permission to access this page.</p>
        <p style="font-size: 12px; color: #666;">If you believe this is an error, contact the Applications Team.</p>
        <a href="/" class="home-link">Go Home</a>
    </div>
</body>
</html>
"@
}

function Get-ActionDeniedResponse {
    <#
    .SYNOPSIS
        Returns a standardized JSON response for denied API actions.
    .PARAMETER ActionName
        The action that was denied
    #>
    param(
        [string]$ActionName = 'this action'
    )
    
    return [PSCustomObject]@{
        Error   = "Access Denied"
        Message = "You do not have permission to perform $ActionName."
    }
}

# ============================================================================
# API Cache Functions
# Shared caching layer for Control Center API endpoints.
# Uses Pode shared state for cross-runspace access with named lockable
# for thread safety. Cache TTLs are driven by GlobalConfig with periodic
# refresh to avoid per-request database lookups.
#
# GlobalConfig category convention:
#   'ApiCache'                  = Global default TTL
#   'ApiCache.ClientRelations'  = Client Relations page endpoints
#   'ApiCache.BusinessServices' = Business Services page endpoints (future)
#   etc.
#
# Initialization:
#   Start-ControlCenter.ps1 must call:
#     New-PodeLockable -Name 'ApiCache'
#     Set-PodeState -Name 'ApiCache' -Value @{}
#     Set-PodeState -Name 'ApiCacheConfig' -Value @{}
#   Then call Initialize-ApiCacheConfig to load TTL settings.
#
# Usage in API routes:
#   $data = Get-CachedResult -CacheKey 'regf_queue' -ScriptBlock {
#       Invoke-CRS5ReadQuery -Query "SELECT ..."
#   }
#
#   # Force refresh (manual refresh button):
#   $data = Get-CachedResult -CacheKey 'regf_queue' -ForceRefresh -ScriptBlock {
#       Invoke-CRS5ReadQuery -Query "SELECT ..."
#   }
# ============================================================================

function Initialize-ApiCacheConfig {
    <#
    .SYNOPSIS
        Loads cache TTL settings from GlobalConfig into Pode shared state.
        Called on startup and periodically by a Pode timer.
    .DESCRIPTION
        Reads all cache_ttl_* settings from GlobalConfig for the ControlCenter
        module (across all ApiCache.* categories) and stores them in the 
        ApiCacheConfig shared state. This avoids querying GlobalConfig on 
        every API request.
    #>
    
    try {
        $settings = Invoke-XFActsQuery -Query @"
            SELECT setting_name, setting_value
            FROM dbo.GlobalConfig
            WHERE module_name = 'ControlCenter'
              AND category LIKE 'ApiCache%'
              AND is_active = 1
"@
        
        $configMap = @{}
        foreach ($row in $settings) {
            $configMap[$row.setting_name] = $row.setting_value
        }
        
        Lock-PodeObject -Name 'ApiCache' -ScriptBlock {
            Set-PodeState -Name 'ApiCacheConfig' -Value $configMap
        }
    }
    catch {
        # If GlobalConfig is unreachable, leave existing config in place.
        # The Get-CachedResult function will fall back to hardcoded defaults.
    }
}

function Get-CachedResult {
    <#
    .SYNOPSIS
        Returns cached API results or executes the query if cache is expired/missing.
    .DESCRIPTION
        Thread-safe caching using Pode shared state. TTL is resolved in this order:
        1. Endpoint-specific GlobalConfig setting (cache_ttl_<CacheKey>_seconds)
        2. Default GlobalConfig setting (cache_ttl_default_seconds)  
        3. Hardcoded fallback (600 seconds)
        
        The query scriptblock executes OUTSIDE the lock to avoid blocking
        other threads during long-running queries.
    .PARAMETER CacheKey
        Unique identifier for this cached dataset (e.g., 'regf_queue').
        Used as both the state key and the GlobalConfig setting name component.
    .PARAMETER ScriptBlock
        The code to execute on cache miss. Should return the data to cache.
    .PARAMETER ForceRefresh
        Bypass cache and execute the query. Updates the cache with fresh data.
        Used by manual refresh buttons.
    .RETURNS
        The cached or freshly-queried data.
    .EXAMPLE
        $data = Get-CachedResult -CacheKey 'regf_queue' -ScriptBlock {
            Invoke-CRS5ReadQuery -Query "SELECT ..."
        }
    #>
    param(
        [Parameter(Mandatory)]
        [string]$CacheKey,
        
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,
        
        [switch]$ForceRefresh
    )
    
    # --- Resolve TTL from cached config ---
    $ttlSeconds = 600  # Hardcoded emergency fallback
    
    Lock-PodeObject -Name 'ApiCache' -ScriptBlock {
        $config = Get-PodeState -Name 'ApiCacheConfig'
        if ($null -ne $config) {
            # Check for endpoint-specific TTL first
            $specificKey = "cache_ttl_${CacheKey}_seconds"
            if ($config.ContainsKey($specificKey)) {
                $ttlSeconds = [int]$config[$specificKey]
            }
            elseif ($config.ContainsKey('cache_ttl_default_seconds')) {
                $ttlSeconds = [int]$config['cache_ttl_default_seconds']
            }
        }
    }
    
    # --- Check cache (unless force refresh) ---
    if (-not $ForceRefresh) {
        $cached = $null
        Lock-PodeObject -Name 'ApiCache' -ScriptBlock {
            $cache = Get-PodeState -Name 'ApiCache'
            if ($cache.ContainsKey($CacheKey)) {
                $entry = $cache[$CacheKey]
                $age = ((Get-Date) - $entry.Timestamp).TotalSeconds
                if ($age -lt $ttlSeconds) {
                    $cached = $entry.Data
                }
            }
        }
        
        if ($null -ne $cached) {
            return $cached
        }
    }
    
    # --- Cache miss or force refresh: execute query OUTSIDE the lock ---
    $result = & $ScriptBlock
    
    # --- Store result in cache ---
    Lock-PodeObject -Name 'ApiCache' -ScriptBlock {
        $cache = Get-PodeState -Name 'ApiCache'
        $cache[$CacheKey] = @{
            Data      = $result
            Timestamp = Get-Date
        }
    }
    
    return $result
}


# ============================================================================
# CRS5 (Debt Manager) Database Functions
# AG-aware read/write split for crs5_oltp operations.
# Read queries use the configured SourceReplica (default: SECONDARY).
# Write queries detect and use the current AG primary.
# When a TargetInstance is specified and does not match the AG listener,
# connections route directly to the named instance (non-AG standalone).
# ============================================================================

function Get-CRS5Connection {
    <#
    .SYNOPSIS
        Returns connection strings for read and write operations against crs5_oltp.
        Reads AG configuration from GlobalConfig and detects current replica roles.
    .PARAMETER TargetInstance
        Optional. When specified, compared against the AGListenerName from GlobalConfig.
        If it matches (or is not provided), uses AG-aware read/write split.
        If it does not match, routes both read and write directly to the named instance.
    .RETURNS
        Hashtable with 'Read' and 'Write' connection strings
    #>
    param(
        [string]$TargetInstance
    )
    
    # Get AG configuration from GlobalConfig
    $agConfig = Invoke-XFActsQuery -Query @"
        SELECT setting_name, setting_value
        FROM dbo.GlobalConfig
        WHERE module_name IN ('Core', 'Shared', 'dbo', 'Shared (dbo)')
          AND setting_name IN ('AGName', 'SourceReplica', 'AGListenerName')
          AND is_active = 1
"@
    
    $agName = 'DMPRODAG'
    $sourceReplica = 'SECONDARY'
    $agListenerName = 'AVG-PROD-LSNR'
    
    foreach ($row in $agConfig) {
        switch ($row.setting_name) {
            'AGName'         { $agName = $row.setting_value }
            'SourceReplica'  { $sourceReplica = $row.setting_value }
            'AGListenerName' { $agListenerName = $row.setting_value }
        }
    }
    
    # If TargetInstance is specified and does not match the AG listener,
    # route directly to the standalone instance (non-AG path)
    if (-not [string]::IsNullOrEmpty($TargetInstance) -and $TargetInstance -ne $agListenerName) {
        return @{
            Read  = "Server=$TargetInstance;Database=crs5_oltp;Integrated Security=True;Application Name=xFACts Control Center;"
            Write = "Server=$TargetInstance;Database=crs5_oltp;Integrated Security=True;Application Name=xFACts Control Center;"
        }
    }
    
    # AG-aware path: query for current replica roles via the listener
    $replicaQuery = @"
        SELECT 
            ar.replica_server_name,
            ars.role_desc
        FROM sys.dm_hadr_availability_replica_states ars
        INNER JOIN sys.availability_replicas ar 
            ON ars.replica_id = ar.replica_id
        INNER JOIN sys.availability_groups ag
            ON ar.group_id = ag.group_id
        WHERE ag.name = '$agName'
"@
    
    $replicaResults = Invoke-XFActsQuery -Query $replicaQuery
    
    $roles = @{ PRIMARY = $null; SECONDARY = $null }
    foreach ($row in $replicaResults) {
        if ($row.role_desc -eq 'PRIMARY')   { $roles.PRIMARY = $row.replica_server_name }
        elseif ($row.role_desc -eq 'SECONDARY') { $roles.SECONDARY = $row.replica_server_name }
    }
    
    # Determine read server based on config
    $readServer = if ($sourceReplica -eq 'SECONDARY' -and $roles.SECONDARY) {
        $roles.SECONDARY
    } else {
        $roles.PRIMARY
    }
    
    $writeServer = $roles.PRIMARY
    
    # Fallback to listener if detection fails
    if (-not $readServer)  { $readServer = $agListenerName }
    if (-not $writeServer) { $writeServer = $agListenerName }
    
    return @{
        Read  = "Server=$readServer;Database=crs5_oltp;Integrated Security=True;Application Name=xFACts Control Center;ApplicationIntent=ReadOnly;"
        Write = "Server=$writeServer;Database=crs5_oltp;Integrated Security=True;Application Name=xFACts Control Center;"
    }
}

function Invoke-CRS5ReadQuery {
    <#
    .SYNOPSIS
        Executes a read-only query against crs5_oltp using the configured secondary replica.
    .PARAMETER Query
        The SQL query to execute
    .PARAMETER Parameters
        Optional hashtable of parameters
    .PARAMETER TimeoutSeconds
        Command timeout in seconds (default: 60)
    .PARAMETER TargetInstance
        Optional. Passed to Get-CRS5Connection for AG vs direct routing.
    .RETURNS
        Array of hashtables
    #>
    param(
        [Parameter(Mandatory)][string]$Query,
        [hashtable]$Parameters = @{},
        [int]$TimeoutSeconds = 60,
        [string]$TargetInstance
    )
    
    $connStrings = Get-CRS5Connection -TargetInstance $TargetInstance
    $conn = New-Object System.Data.SqlClient.SqlConnection($connStrings.Read)
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $Query
        $cmd.CommandTimeout = $TimeoutSeconds
        
        foreach ($key in $Parameters.Keys) {
            $cmd.Parameters.AddWithValue("@$key", $Parameters[$key]) | Out-Null
        }
        
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        
        $results = @()
        if ($dataset.Tables.Count -gt 0) {
            foreach ($row in $dataset.Tables[0].Rows) {
                $obj = @{}
                foreach ($col in $dataset.Tables[0].Columns) {
                    $obj[$col.ColumnName] = $row[$col.ColumnName]
                }
                $results += $obj
            }
        }
        return ,$results
    }
    finally {
        if ($conn.State -eq 'Open') { $conn.Close() }
    }
}


function Invoke-CRS5WriteQuery {
    <#
    .SYNOPSIS
        Executes a write query against crs5_oltp using the current AG primary.
    .PARAMETER Query
        The SQL query to execute
    .PARAMETER Parameters
        Optional hashtable of parameters
    .PARAMETER TargetInstance
        Optional. Passed to Get-CRS5Connection for AG vs direct routing.
    .RETURNS
        Number of rows affected
    #>
    param(
        [Parameter(Mandatory)][string]$Query,
        [hashtable]$Parameters = @{},
        [string]$TargetInstance
    )
    
    $connStrings = Get-CRS5Connection -TargetInstance $TargetInstance
    $conn = New-Object System.Data.SqlClient.SqlConnection($connStrings.Write)
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $Query
        $cmd.CommandTimeout = 30
        
        foreach ($key in $Parameters.Keys) {
            $cmd.Parameters.AddWithValue("@$key", $Parameters[$key]) | Out-Null
        }
        
        return $cmd.ExecuteNonQuery()
    }
    finally {
        if ($conn.State -eq 'Open') { $conn.Close() }
    }
}

# ============================================================================
# DmOps Remaining Counts Cache
# Periodic query against crs5_oltp for archive/shell remaining counts.
# Cached in memory with configurable TTL to avoid frequent OLTP queries.
# ============================================================================

$script:DmOpsRemainingCache = @{
    ArchiveRemaining   = $null
    ShellRemaining     = $null
    ExclusionCount     = $null
    BaselineDttm       = $null
    TargetInstance     = $null
    CacheMaxAgeMinutes = 60
}

function Get-RemainingCounts {
    <#
    .SYNOPSIS
        Returns cached remaining counts for DmOps archive and shell purge processes.
        Queries crs5_oltp via the secondary replica on first call and when cache expires.
        Exclusion count is always fresh from the xFACts database.
    .RETURNS
        Hashtable with ArchiveRemaining, ShellRemaining, ExclusionCount, BaselineDttm, TargetInstance
    #>
    $cache = $script:DmOpsRemainingCache
    $now = Get-Date
    
    # Check if cache is still valid
    if ($cache.BaselineDttm -and ($now - $cache.BaselineDttm).TotalMinutes -lt $cache.CacheMaxAgeMinutes) {
        return $cache
    }
    
    # Get target instance from DmOps GlobalConfig
    $targetConfig = Invoke-XFActsQuery -Query @"
        SELECT setting_value FROM dbo.GlobalConfig
        WHERE module_name = 'DmOps' AND category = 'Archive'
          AND setting_name = 'target_instance' AND is_active = 1
"@
    $targetInstance = if ($targetConfig -and $targetConfig.Count -gt 0) { $targetConfig[0].setting_value } else { 'AVG-PROD-LSNR' }
    
    try {
        # Archive remaining: TA_ARCH tagged accounts
        $archiveResult = Invoke-CRS5ReadQuery -TargetInstance $targetInstance -Query @"
            SELECT COUNT(cat.cnsmr_accnt_id) AS remaining_count
            FROM crs5_oltp.dbo.cnsmr_accnt_tag cat
            INNER JOIN crs5_oltp.dbo.tag t ON t.tag_id = cat.tag_id
                AND cat.cnsmr_accnt_sft_delete_flg = 'N'
                AND t.tag_shrt_nm = 'TA_ARCH'
"@ -TimeoutSeconds 30
        
        # Shell remaining: WFAPURGE workgroup consumers
        $shellResult = Invoke-CRS5ReadQuery -TargetInstance $targetInstance -Query @"
            SELECT COUNT(c.cnsmr_id) AS remaining_count
            FROM crs5_oltp.dbo.cnsmr c
            INNER JOIN crs5_oltp.dbo.wrkgrp w ON w.wrkgrp_id = c.wrkgrp_id
                AND w.wrkgrp_shrt_nm = 'WFAPURGE'
"@ -TimeoutSeconds 30
        
        # Exclusion count from xFACts (always fresh, cheap)
        $exclusionResult = Invoke-XFActsQuery -Query @"
            SELECT COUNT(DISTINCT cnsmr_id) AS exclusion_count
            FROM DmOps.ShellPurge_ExclusionLog
"@
        
        # Update cache
        $cache.ArchiveRemaining = if ($archiveResult -and $archiveResult.Count -gt 0) { [long]$archiveResult[0].remaining_count } else { $null }
        $cache.ShellRemaining = if ($shellResult -and $shellResult.Count -gt 0) { [long]$shellResult[0].remaining_count } else { $null }
        $cache.ExclusionCount = if ($exclusionResult -and $exclusionResult.Count -gt 0) { [long]$exclusionResult[0].exclusion_count } else { 0 }
        $cache.BaselineDttm = $now
        $cache.TargetInstance = $targetInstance
    }
    catch {
        Write-Host "WARNING: Failed to refresh remaining counts from crs5_oltp ($targetInstance): $($_.Exception.Message)"
    }
    
    return $cache
}

# ============================================================================
# Credential Retrieval (from dbo.Credentials via two-tier decryption)
# ============================================================================

function Get-ServiceCredentials {
    <#
    .SYNOPSIS
        Retrieves decrypted credentials for an external service from dbo.Credentials.
    .DESCRIPTION
        Implements the two-tier decryption model: master passphrase (from GlobalConfig)
        decrypts the service-level passphrase, which decrypts all credential values.
        Mirrors the pattern used by collector scripts (Process-JiraTicketQueue.ps1, etc.).
        
        No caching — master passphrase is retrieved fresh each call. Designed for
        infrequent, user-initiated actions (not polling cycles).
    .PARAMETER ServiceName
        The service identifier in dbo.Credentials (e.g., 'SharePoint', 'Jira').
    .PARAMETER Environment
        Environment filter. Defaults to 'PROD'.
    .RETURNS
        Hashtable of decrypted ConfigKey = value pairs (excluding 'Passphrase').
        Example: @{ TenantId = '...'; ClientId = '...'; ClientSecret = '...' }
    .EXAMPLE
        $creds = Get-ServiceCredentials -ServiceName 'SharePoint'
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ServiceName,

        [string]$Environment = 'PROD'
    )

    # Step 1: Retrieve master passphrase from GlobalConfig
    $masterResult = Invoke-XFActsQuery -Query @"
        SELECT setting_value
        FROM dbo.GlobalConfig
        WHERE module_name = 'Shared'
          AND category = 'Credentials'
          AND setting_name = 'master_passphrase'
          AND is_active = 1
"@

    if (-not $masterResult -or -not $masterResult[0].setting_value) {
        throw "Master passphrase not found in GlobalConfig (Shared.Credentials.master_passphrase)"
    }

    $masterPass = $masterResult[0].setting_value

    # Step 2: Decrypt service-level passphrase, then decrypt all config keys
    # Note: Passphrases are concatenated into the query (not parameterized) because
    # DECRYPTBYPASSPHRASE requires literal string values. This mirrors the proven
    # pattern in Process-JiraTicketQueue.ps1 and other collector scripts.
    $decryptQuery = @"
        DECLARE @MasterPassphrase VARCHAR(100) = '$($masterPass -replace "'", "''")';
        DECLARE @ServicePassphrase VARCHAR(100);

        SELECT @ServicePassphrase = CAST(DECRYPTBYPASSPHRASE(@MasterPassphrase, ConfigValue) AS VARCHAR(100))
        FROM dbo.Credentials
        WHERE Environment = @env
          AND ServiceName = @svc
          AND ConfigKey = 'Passphrase';

        IF @ServicePassphrase IS NULL
            THROW 50001, 'Service passphrase not found or decryption failed', 1;

        SELECT
            ConfigKey,
            CAST(DECRYPTBYPASSPHRASE(@ServicePassphrase, ConfigValue) AS VARCHAR(500)) AS ConfigValue
        FROM dbo.Credentials
        WHERE Environment = @env
          AND ServiceName = @svc
          AND ConfigKey <> 'Passphrase';
"@

    $results = Invoke-XFActsQuery -Query $decryptQuery -Parameters @{
        env = $Environment
        svc = $ServiceName
    }

    if (-not $results -or $results.Count -eq 0) {
        throw "No credentials found for service '$ServiceName' in environment '$Environment'"
    }

    # Build hashtable of key/value pairs
    $credentials = @{}
    foreach ($row in $results) {
        if ([string]::IsNullOrEmpty($row.ConfigValue)) {
            throw "Decryption failed for $ServiceName.$($row.ConfigKey) - check passphrase chain"
        }
        $credentials[$row.ConfigKey] = $row.ConfigValue
    }

    return $credentials
}

# ============================================================================
# AG Read Query — Generalized secondary replica read for any AG database
# ============================================================================
 
function Invoke-AGReadQuery {
    <#
    .SYNOPSIS
        Executes a read-only query against any AG database using the configured
        secondary replica. Reuses the same AG topology detection as CRS5 functions
        but targets the specified database.
    .PARAMETER Database
        The database name to query (e.g., 'Notice_Recon', 'crs5_oltp')
    .PARAMETER Query
        The SQL query to execute
    .PARAMETER Parameters
        Optional hashtable of parameters
    .PARAMETER TimeoutSeconds
        Command timeout in seconds (default: 60)
    .RETURNS
        Array of hashtables
    .EXAMPLE
        $results = Invoke-AGReadQuery -Database 'Notice_Recon' -Query "SELECT * FROM dbo.Process_Execution_Log WHERE ..."
    #>
    param(
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][string]$Query,
        [hashtable]$Parameters = @{},
        [int]$TimeoutSeconds = 60
    )
    
    # Detect AG replica roles using existing GlobalConfig settings
    $agConfig = Invoke-XFActsQuery -Query @"
        SELECT setting_name, setting_value
        FROM dbo.GlobalConfig
        WHERE module_name IN ('Core', 'Shared', 'dbo', 'Shared (dbo)')
          AND setting_name IN ('AGName', 'SourceReplica')
          AND is_active = 1
"@
    
    $agName = 'DMPRODAG'
    $sourceReplica = 'SECONDARY'
    
    foreach ($row in $agConfig) {
        switch ($row.setting_name) {
            'AGName'        { $agName = $row.setting_value }
            'SourceReplica' { $sourceReplica = $row.setting_value }
        }
    }
    
    # Query AG for current replica roles
    $replicaResults = Invoke-XFActsQuery -Query @"
        SELECT ar.replica_server_name, ars.role_desc
        FROM sys.dm_hadr_availability_replica_states ars
        INNER JOIN sys.availability_replicas ar ON ars.replica_id = ar.replica_id
        INNER JOIN sys.availability_groups ag ON ar.group_id = ag.group_id
        WHERE ag.name = '$agName'
"@
    
    $readServer = $null
    foreach ($row in $replicaResults) {
        if ($sourceReplica -eq 'SECONDARY' -and $row.role_desc -eq 'SECONDARY') {
            $readServer = $row.replica_server_name
        }
        elseif ($sourceReplica -eq 'PRIMARY' -and $row.role_desc -eq 'PRIMARY') {
            $readServer = $row.replica_server_name
        }
    }
    
    # Fallback to listener
    if (-not $readServer) { $readServer = 'AVG-PROD-LSNR' }
    
    $connString = "Server=$readServer;Database=$Database;Integrated Security=True;Application Name=xFACts Control Center;ApplicationIntent=ReadOnly;"
    $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $Query
        $cmd.CommandTimeout = $TimeoutSeconds
        
        foreach ($key in $Parameters.Keys) {
            $cmd.Parameters.AddWithValue("@$key", $Parameters[$key]) | Out-Null
        }
        
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        
        $results = @()
        if ($dataset.Tables.Count -gt 0) {
            foreach ($row in $dataset.Tables[0].Rows) {
                $obj = @{}
                foreach ($col in $dataset.Tables[0].Columns) {
                    $obj[$col.ColumnName] = $row[$col.ColumnName]
                }
                $results += $obj
            }
        }
        return ,$results
    }
    finally {
        if ($conn.State -eq 'Open') { $conn.Close() }
    }
}

# ============================================================================
# Module Exports
# ============================================================================
Export-ModuleMember -Function @(
    # Database
    'Invoke-XFActsQuery',
    'Invoke-XFActsProc',
    'Invoke-XFActsNonQuery',
    # RBAC - Core
    'Get-UserAccess',
    'Test-ActionPermission',
    'Test-ActionEndpoint',
    'Get-UserContext',
    # RBAC - Internal (needed by routes that build CRS5 connections)
    'Resolve-UserRoles',
    'Get-UserPageTier',
    'Initialize-RBACCache',
    'Confirm-RBACCache',
    'Get-TierLevel',
    'Test-TierSufficient',
    'Write-RBACAuditLog',
    # RBAC - Response Helpers
    'Get-AccessDeniedHtml',
    'Get-ActionDeniedResponse',
#    # API Cache
    'Initialize-ApiCacheConfig',
    'Get-CachedResult',
    # Credentials
    'Get-ServiceCredentials',
    # CRS5 (Debt Manager) Database
    'Get-CRS5Connection',
    'Invoke-CRS5ReadQuery',
    'Invoke-CRS5WriteQuery',
#     # AG Generalized Read
     'Invoke-AGReadQuery',
    # DmOps Cache
    'Get-RemainingCounts'
)
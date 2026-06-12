<#
.SYNOPSIS
    Shared Control Center helper module providing database access, RBAC evaluation,
    server-side navigation rendering, and supporting utility functions.

.DESCRIPTION
    Drop-in successor to xFACts-Helpers.psm1 consumed by every Control Center page
    that has been refactored to the CC File Format Standardization conventions
    (cc- chrome class prefix, cc_ JavaScript identifier prefix, data-cc-page /
    data-cc-prefix body attributes). Loaded by Start-ControlCenter.ps1 via
    Import-PodeModule so every exported function is available across all Pode
    runspaces. Provides the xFACts database access surface (Invoke-XFActsQuery,
    Invoke-XFActsProc, Invoke-XFActsNonQuery), the full RBAC evaluation chain
    (cache, role resolution, page-tier resolution, action and endpoint permission
    checks, user context), server-side navigation and page-header rendering, the
    API result cache, encrypted credentials retrieval, CRS5 (Debt Manager) and
    AG-secondary read helpers, the DmOps remaining-counts cache, BDL XML
    construction and reconciliation, and DBNull-safe value conversion helpers.

.COMPONENT
    ControlCenter.Shared

.NOTES
    File Name : xFACts-CCShared.psm1
    Location  : E:\xFACts-ControlCenter\scripts\modules\xFACts-CCShared.psm1

    FILE ORGANIZATION
    -----------------
    CONSTANTS: CONNECTION STRINGS
    VARIABLES: RBAC CACHE
    VARIABLES: DMOPS CACHE
    FUNCTIONS: DATABASE
    FUNCTIONS: RBAC CACHE
    FUNCTIONS: RBAC HELPERS
    FUNCTIONS: RBAC CORE
    FUNCTIONS: DYNAMIC NAVIGATION
    FUNCTIONS: RBAC AUDIT LOG
    FUNCTIONS: ACCESS DENIED RESPONSES
    FUNCTIONS: API CACHE
    FUNCTIONS: CRS5 DATABASE
    FUNCTIONS: PROFANITY REDACTION
    FUNCTIONS: DMOPS CACHE
    FUNCTIONS: SERVICE CREDENTIALS
    FUNCTIONS: AG READ QUERY
    FUNCTIONS: DATA CONVERSION HELPERS
    FUNCTIONS: BDL PROCESS
    FUNCTIONS: TOOLS SERVER TARGETING
    EXPORTS: MODULE EXPORTS
#>

<# ============================================================================
   CONSTANTS: CONNECTION STRINGS
   ----------------------------------------------------------------------------
   Immutable connection strings shared across the module. The xFACts AG
   listener connection string is used by every Invoke-XFActs* helper.
   Prefix: (none)
   ============================================================================ #>

# xFACts AG listener connection string. Integrated Security with
# ApplicationName tagging so sys.dm_exec_sessions attributes the work back
# to the Control Center for DMV reporting.
$script:ConnectionString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Application Name=xFACts Control Center;"

<# ============================================================================
   VARIABLES: RBAC CACHE
   ----------------------------------------------------------------------------
   Module-scope mutable cache of the RBAC_* configuration tables. Populated
   by Initialize-RBACCache and refreshed on a fixed cadence governed by
   CacheDurationSec.
   Prefix: (none)
   ============================================================================ #>

# In-memory RBAC cache. Populated by Initialize-RBACCache and consulted by
# every access check via Confirm-RBACCache (lazy TTL refresh).
$script:RBACCache = @{
    Roles            = $null
    RoleMappings     = $null
    PagePermissions  = $null
    ActionGrants     = $null
    ActionRegistry   = $null
    DepartmentPages  = $null
    NavSections      = $null
    NavRegistry      = $null
    EnforcementMode  = 'disabled'
    AuditVerbosity   = 'denials_only'
    LastRefresh      = [datetime]::MinValue
    # Cache duration in seconds (5 minutes).
    CacheDurationSec = 300
}

<# ============================================================================
   VARIABLES: DMOPS CACHE
   ----------------------------------------------------------------------------
   Module-scope mutable cache backing Get-RemainingCounts. Holds the latest
   aggregate counts from the DmOps archive pipeline with a short TTL because
   the underlying numbers change with every archive run.
   Prefix: (none)
   ============================================================================ #>

# In-memory DmOps remaining-counts cache. Populated by Get-RemainingCounts on
# first read or after TTL expiry.
$script:DmOpsRemainingCache = @{
    ArchiveConsumersRemaining   = $null   # ALL: WFAARCH1 + WFAARCH3
    ArchiveAccountsRemaining    = $null   # ALL: WFAARCH1 + WFAARCH3
    ArchiveConsumersRemaining1P = $null   # WFAARCH1
    ArchiveAccountsRemaining1P  = $null   # WFAARCH1
    ArchiveConsumersRemaining3P = $null   # WFAARCH3
    ArchiveAccountsRemaining3P  = $null   # WFAARCH3
    ShellRemaining              = $null
    BaselineDttm                = $null
    ArchiveTargetInstance       = $null
    ShellPurgeTargetInstance    = $null
    CacheMaxAgeMinutes          = 60
}

<# ============================================================================
   FUNCTIONS: DATABASE
   ----------------------------------------------------------------------------
   Primary read, stored-procedure, and non-query execution paths against the
   xFACts AG listener. Used by every Control Center route that touches the
   platform database.
   Prefix: (none)
   ============================================================================ #>

function Invoke-XFActsQuery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Query,

        [hashtable]$Parameters = @{}
    )

    <#
    .SYNOPSIS
        Executes a SQL query against the xFACts AG listener and returns results as hashtables.

    .DESCRIPTION
        Opens a SQL connection to the AVG-PROD-LSNR xFACts database using
        Integrated Security, executes the supplied query, and returns each result
        row as a hashtable keyed by column name. Closes the connection in a
        finally block. Used as the primary read path for every CC route that
        queries the xFACts database.

    .PARAMETER Query
        The SQL query text to execute. Multi-line queries may use here-strings.

    .PARAMETER Parameters
        Optional hashtable of parameter name/value pairs. Keys map to @parameter placeholders in the query; strings are typed as VarChar to avoid implicit NVARCHAR conversion that defeats indexes.
    #>

    $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Application Name=xFACts Control Center;"
    $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
    try {
        $conn.Open()

        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $Query
        $cmd.CommandTimeout = 30

        # Add parameters if provided
        foreach ($key in $Parameters.Keys) {
            $p = $cmd.Parameters.AddWithValue("@$key", $Parameters[$key])
            if ($Parameters[$key] -is [string]) { $p.SqlDbType = [System.Data.SqlDbType]::VarChar }
        }

        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null

        $results = [System.Collections.ArrayList]::new()
        if ($dataset.Tables.Count -gt 0) {
            foreach ($row in $dataset.Tables[0].Rows) {
                $obj = @{}
                foreach ($col in $dataset.Tables[0].Columns) {
                    $obj[$col.ColumnName] = $row[$col.ColumnName]
                }
                $results.Add($obj) | Out-Null
            }
        }
        return ,$results
    }
    finally {
        if ($conn.State -eq 'Open') { $conn.Close() }
    }
}

function Invoke-XFActsProc {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ProcName,

        [hashtable]$Parameters = @{}
    )

    <#
    .SYNOPSIS
        Executes a stored procedure against the xFACts AG listener and captures PRINT messages.

    .DESCRIPTION
        Opens a SQL connection to the AVG-PROD-LSNR xFACts database, attaches an
        InfoMessage handler so PRINT output is captured, executes the named
        stored procedure with any supplied parameters, and returns a hashtable
        containing the result rows plus the captured PRINT messages. Command
        timeout is fixed at 120 seconds for diagnostic procs.

    .PARAMETER ProcName
        Fully-qualified procedure name (e.g., dbo.sp_DiagnoseServerHealth).

    .PARAMETER Parameters
        Optional hashtable of parameter name/value pairs. Keys map to procedure parameters by name; strings are typed as VarChar.
    #>

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
        # 2 minutes for diagnostic procs
        $cmd.CommandTimeout = 120

        foreach ($key in $Parameters.Keys) {
            $p = $cmd.Parameters.AddWithValue("@$key", $Parameters[$key])
            if ($Parameters[$key] -is [string]) { $p.SqlDbType = [System.Data.SqlDbType]::VarChar }
        }

        $cmd.ExecuteNonQuery() | Out-Null

        return $messages
    }
    finally {
        if ($conn.State -eq 'Open') { $conn.Close() }
    }
}

function Invoke-XFActsNonQuery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Query,

        [hashtable]$Parameters = @{},

        [int]$TimeoutSeconds = 30
    )

    <#
    .SYNOPSIS
        Executes a non-query SQL statement against the xFACts AG listener and returns affected row count.

    .DESCRIPTION
        Opens a SQL connection to the AVG-PROD-LSNR xFACts database, executes
        an INSERT/UPDATE/DELETE statement (or any other non-result-set
        statement), and returns the number of rows affected. Closes the
        connection in a finally block.

    .PARAMETER Query
        The SQL statement to execute.

    .PARAMETER Parameters
        Optional hashtable of parameter name/value pairs. Keys map to @parameter placeholders; strings are typed as VarChar.

    .PARAMETER TimeoutSeconds
        Command timeout in seconds. Defaults to 30.
    #>

    $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Application Name=xFACts Control Center;"
    $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
    try {
        $conn.Open()

        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $Query
        $cmd.CommandTimeout = $TimeoutSeconds

        foreach ($key in $Parameters.Keys) {
            $p = $cmd.Parameters.AddWithValue("@$key", $Parameters[$key])
            if ($Parameters[$key] -is [string]) { $p.SqlDbType = [System.Data.SqlDbType]::VarChar }
        }

        $rowsAffected = $cmd.ExecuteNonQuery()
        return $rowsAffected
    }
    finally {
        if ($conn.State -eq 'Open') { $conn.Close() }
    }
}

<# ============================================================================
   FUNCTIONS: RBAC CACHE
   ----------------------------------------------------------------------------
   In-memory cache of the RBAC_* configuration tables. The cache is loaded
   on first access and refreshed on a fixed cadence governed by the
   CacheDurationSec setting in $script:RBACCache.
   Prefix: (none)
   ============================================================================ #>

function Initialize-RBACCache {
    [CmdletBinding()]
    param()

    <#
    .SYNOPSIS
        Loads all RBAC configuration tables from the database into the in-memory cache.

    .DESCRIPTION
        Issues a single batched query against the RBAC_* tables and populates
        the $script:RBACCache hashtable with Roles, RoleMappings, PagePermissions,
        ActionGrants, ActionRegistry, DepartmentPages, NavSections, NavRegistry,
        plus the EnforcementMode and AuditVerbosity GlobalConfig values. Stamps
        LastRefresh with the current time. Called automatically by
        Confirm-RBACCache when the cache is empty or stale.
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

        # Load nav sections (for dynamic nav rendering)
        $script:RBACCache.NavSections = Invoke-XFActsQuery -Query @"
            SELECT section_id, section_key, section_label, section_sort_order, accent_class
            FROM dbo.RBAC_NavSection
            WHERE is_active = 1
            ORDER BY section_sort_order
"@

        # Load nav registry (for dynamic nav rendering)
        $script:RBACCache.NavRegistry = Invoke-XFActsQuery -Query @"
            SELECT nav_id, page_route, nav_label, display_title, description,
                   section_key, sort_order, doc_page_id, show_in_nav, show_on_home
            FROM dbo.RBAC_NavRegistry
            WHERE is_active = 1
            ORDER BY section_key, sort_order
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
    [CmdletBinding()]
    param()

    <#
    .SYNOPSIS
        Ensures the RBAC cache is current, refreshing it if empty or expired.

    .DESCRIPTION
        Checks the elapsed time since the last cache refresh against the
        CacheDurationSec setting. When the cache is empty or has aged beyond
        its TTL, calls Initialize-RBACCache to repopulate it. Cheap enough to
        call on every RBAC check.
    #>

    $elapsed = (Get-Date) - $script:RBACCache.LastRefresh
    if ($null -eq $script:RBACCache.Roles -or $elapsed.TotalSeconds -gt $script:RBACCache.CacheDurationSec) {
        Initialize-RBACCache
    }
}

<# ============================================================================
   FUNCTIONS: RBAC HELPERS
   ----------------------------------------------------------------------------
   Small helpers consumed by the RBAC core: DBNull normalization for
   boolean-context safety, and the numeric tier-comparison primitives.
   Prefix: (none)
   ============================================================================ #>

function ConvertFrom-DBNull {
    [CmdletBinding()]
    param($Value)

    <#
    .SYNOPSIS
        Returns $null when the supplied value is a DBNull, otherwise returns the value unchanged.

    .DESCRIPTION
        SQL NULL values returned from Invoke-XFActsQuery surface as
        [System.DBNull]::Value, which PowerShell treats as truthy in boolean
        contexts. This helper normalizes DBNull to $null so conditional checks
        like "if ($_.department_scope)" evaluate correctly.

    .PARAMETER Value
        The raw value from a SQL result row, which may be [DBNull] or any other type.
    #>

    if ($Value -is [System.DBNull]) { return $null }
    return $Value
}

function Get-TierLevel {
    [CmdletBinding()]
    param([string]$Tier)

    <#
    .SYNOPSIS
        Converts an access tier name to a numeric level for comparison.

    .DESCRIPTION
        Maps the tier strings used in RBAC_PermissionMapping and
        RBAC_ActionRegistry to numeric levels suitable for >= comparisons.
        Higher numbers mean more privilege. Unknown tier strings return 0.

    .PARAMETER Tier
        The tier name: read, operate, manage, admin, or any other string (treated as 0).
    #>

    switch ($Tier) {
        'admin'   { return 3 }
        'operate' { return 2 }
        'view'    { return 1 }
        default   { return 0 }
    }
}

function Test-TierSufficient {
    [CmdletBinding()]
    param(
        [string]$UserTier,
        [string]$RequiredTier
    )

    <#
    .SYNOPSIS
        Tests whether a user tier meets or exceeds a required tier.

    .DESCRIPTION
        Resolves both tier names to numeric levels via Get-TierLevel and
        returns $true when the user tier is numerically greater than or
        equal to the required tier.

    .PARAMETER UserTier
        The tier the user holds.

    .PARAMETER RequiredTier
        The tier required to perform the operation.
    #>

    return (Get-TierLevel -Tier $UserTier) -ge (Get-TierLevel -Tier $RequiredTier)
}

<# ============================================================================
   FUNCTIONS: RBAC CORE
   ----------------------------------------------------------------------------
   The page-level and action-level access evaluation surface every CC
   route consumes. Get-UserAccess gates page rendering; Test-ActionEndpoint
   is the universal API hook; Get-UserContext powers UI personalization.
   Prefix: (none)
   ============================================================================ #>

function Resolve-UserRoles {
    [CmdletBinding()]
    param(
        [array]$UserGroups
    )

    <#
    .SYNOPSIS
        Resolves a user's AD group memberships to the RBAC roles those groups map to.

    .DESCRIPTION
        Iterates the supplied AD group list and looks each up in the
        RBAC_RoleMapping cache. Returns the distinct set of role names the
        user holds via group membership. Unknown groups are silently
        skipped.

    .PARAMETER UserGroups
        Array of AD group SAM account names from the user's authentication context.
    #>

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
    [CmdletBinding()]
    param(
        [array]$UserRoles,
        [string]$PageRoute
    )

    <#
    .SYNOPSIS
        Resolves the highest access tier a user holds for a specific page route.

    .DESCRIPTION
        Walks the user's RBAC roles, looks up each role's permissions against
        the supplied page route in RBAC_PermissionMapping, and returns the
        highest-privilege tier any role grants. Returns $null when no role
        grants access to the page.

    .PARAMETER UserRoles
        Array of role names the user holds (from Resolve-UserRoles).

    .PARAMETER PageRoute
        The page route path being accessed (e.g., /server-health).
    #>

    Confirm-RBACCache

    if (-not $UserRoles -or -not $script:RBACCache.PagePermissions) {
        return $null
    }

    # Look up the target page's section once. Used to determine whether the
    # department-scope filter applies. Unregistered pages default to
    # 'departmental' (fail-closed) -- a dept-scoped role will be filtered out
    # unless the page route matches its dept page.
    $targetSection = 'departmental'
    if ($script:RBACCache.NavRegistry) {
        $navEntry = $script:RBACCache.NavRegistry | Where-Object { $_.page_route -eq $PageRoute } | Select-Object -First 1
        if ($navEntry) {
            $targetSection = $navEntry.section_key
        }
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

        # For department-scoped roles accessing a page in the 'departmental' section,
        # the page must match the user's department scope. Pages in other sections
        # (platform, tools, admin) are not subject to dept-scope filtering -- those
        # permissions apply to anyone holding the role regardless of scope.
        $role = $UserRoles | Where-Object { $_.role_id -eq $perm.role_id } | Select-Object -First 1
        $deptScope = ConvertFrom-DBNull $role.department_scope
        if ($deptScope -and $targetSection -eq 'departmental') {
            $deptPage = $script:RBACCache.DepartmentPages | Where-Object { $_.department_key -eq $deptScope }
            if (-not $deptPage -or $PageRoute -ne $deptPage.page_route) { continue }
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
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$WebEvent,
        [Parameter(Mandatory)][string]$PageRoute,
        [Parameter(Mandatory)][string]$ActionName,
        [string]$RequiredTier = 'operate'
    )

    <#
    .SYNOPSIS
        Tests whether a user has permission to perform a specific action on a page.

    .DESCRIPTION
        Performs the action-level permission check used by API routes. Resolves
        the user's context, looks up the action in RBAC_ActionRegistry to get
        the action's required tier, then compares the user's page tier against
        that required tier. Honors the platform's enforcement mode setting --
        in audit mode access is granted but the denial would have been logged.

    .PARAMETER WebEvent
        The Pode $WebEvent for the current request, carrying the authenticated user identity.

    .PARAMETER PageRoute
        The page route the action belongs to.

    .PARAMETER ActionName
        The action name as registered in RBAC_ActionRegistry.

    .PARAMETER RequiredTier
        Optional override of the registry-declared required tier. Defaults to operate.
    #>

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
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$WebEvent
    )

    <#
    .SYNOPSIS
        Tests whether an API endpoint call is permitted, fail-open for unregistered actions.

    .DESCRIPTION
        Universal RBAC hook called by every API route. Resolves the page route
        and action name from the request, looks the action up in
        RBAC_ActionRegistry, and applies the platform's standard tier-comparison
        logic. Endpoints not yet registered in RBAC_ActionRegistry return
        $true (fail-open) so new endpoints work immediately and registration
        can be added after deployment.

    .PARAMETER WebEvent
        The Pode $WebEvent for the current request.
    #>

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
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$WebEvent,
        [Parameter(Mandatory)][string]$PageRoute
    )

    <#
    .SYNOPSIS
        Performs the page-level access check used by every page route as the first statement.

    .DESCRIPTION
        Resolves the user's identity, AD groups, and RBAC roles, looks up the
        page tier the roles grant for the supplied route, and returns a
        hashtable describing whether access is granted, the resolved tier, and
        the user's display name. Honors the enforcement mode -- when disabled
        every user gets admin access; when audit mode is active access is
        granted but denials are still logged. Page routes call this as the
        first statement of the scriptblock and return Get-AccessDeniedHtml
        when HasAccess is false.

    .PARAMETER WebEvent
        The Pode $WebEvent for the current request.

    .PARAMETER PageRoute
        The page route being requested.
    #>

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
        # Effectively unrestricted
        $result.Tier = 'admin'
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
            # Audit mode = unrestricted
            $result.Tier = 'admin'
        }
    }

    return $result
}

function Get-UserContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$WebEvent
    )

    <#
    .SYNOPSIS
        Resolves the current user's identity, roles, and admin status into a UI rendering context.

    .DESCRIPTION
        Lightweight context-builder used by page templates and nav rendering.
        Returns a hashtable containing the username, display name, AD group
        list, resolved RBAC roles, IsAdmin flag, and department scope. Used to
        drive nav visibility, admin gating, and personalized page content.

    .PARAMETER WebEvent
        The Pode $WebEvent for the current request.
    #>

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
    # Normalize DBNull -> $null so boolean checks and Where-Object filters
    # behave correctly when department_scope is NULL in the database.
    $hasPlatformRole = ($userRoles | Where-Object { -not (ConvertFrom-DBNull $_.department_scope) }) -as [bool]
    $deptScopes = @($userRoles |
        Where-Object { ConvertFrom-DBNull $_.department_scope } |
        ForEach-Object { ConvertFrom-DBNull $_.department_scope } |
        Select-Object -Unique)
    $isDeptOnly = (-not $hasPlatformRole) -and ($deptScopes.Count -gt 0)
    $isAdmin = $roleNames -contains 'Admin'

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
        EnforcementMode   = $script:RBACCache.EnforcementMode
    }
}

<# ============================================================================
   FUNCTIONS: DYNAMIC NAVIGATION
   ----------------------------------------------------------------------------
   Server-side rendering of the navigation bar, Home page tile layout, and
   per-page header / browser-title / script-tag blocks. Driven by the
   cached RBAC_NavRegistry and RBAC_NavSection content.
   Prefix: (none)
   ============================================================================ #>

function Get-NavBarHtml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$UserContext,
        [Parameter(Mandatory)][string]$CurrentPageRoute
    )

    <#
    .SYNOPSIS
        Renders the horizontal navigation bar HTML for a given user and current page.

    .DESCRIPTION
        Filters the RBAC_NavRegistry rows visible to the user, groups them by
        section per RBAC_NavSection, applies the cc-active modifier to the link
        matching the current page route, and appends the admin gear icon for
        users with the Admin role. Emits cc- prefixed chrome classes per the
        CC_CSS_Spec (cc-nav-bar, cc-nav-link, cc-nav-section-<key>,
        cc-nav-separator, cc-nav-spacer, cc-nav-admin). RBAC_NavSection.accent_class
        database values (e.g., nav-section-platform) are transformed at
        emission time by prepending cc- so the database content stays unchanged
        during the migration.

    .PARAMETER UserContext
        Hashtable from Get-UserContext containing user identity and roles.

    .PARAMETER CurrentPageRoute
        The route of the page currently being rendered. Used to apply the cc-active modifier to the matching nav link.
    #>

    Confirm-RBACCache

    if (-not $script:RBACCache.NavRegistry -or -not $script:RBACCache.NavSections) {
        # Cache not loaded - return minimal nav as fallback
        return '<nav class="cc-nav-bar"><a href="/" class="cc-nav-link">Home</a></nav>'
    }

    $userRoles = $UserContext.Roles
    $isAdmin = $UserContext.IsAdmin

    # Build the HTML in a StringBuilder for efficient concatenation
    $sb = New-Object System.Text.StringBuilder 2048
    [void]$sb.AppendLine('    <nav class="cc-nav-bar">')

    # Home link is always first, regardless of section. The class string is
    # built via the array-join pattern: collect tokens into an array, then
    # join with a single space. This keeps the class attribute on the emitted
    # <a> tag fully resolved (no string-interpolation directly into the
    # class attribute) per the CC spec.
    $homeTokens = @('cc-nav-link')
    if ($CurrentPageRoute -eq '/') { $homeTokens += 'cc-active' }
    $homeClasses = $homeTokens -join ' '
    [void]$sb.AppendLine("        <a href=`"/`" class=`"$homeClasses`">Home</a>")

    # Iterate sections in order, filtering pages by user permissions
    $sectionsRendered = 0
    foreach ($section in $script:RBACCache.NavSections) {
        # Skip the admin section -- it's not rendered in the nav, only via gear icon
        if ($section.section_key -eq 'admin') { continue }

        # Get pages in this section that should appear in nav
        $sectionPages = $script:RBACCache.NavRegistry | Where-Object {
            $_.section_key -eq $section.section_key -and $_.show_in_nav -eq 1
        } | Sort-Object sort_order

        if (-not $sectionPages) { continue }

        # Filter pages by user's permissions
        $accessiblePages = @()
        foreach ($page in $sectionPages) {
            $tier = Get-UserPageTier -UserRoles $userRoles -PageRoute $page.page_route
            if ($tier) {
                $accessiblePages += $page
            }
        }

        if ($accessiblePages.Count -eq 0) { continue }

        # Add section separator before non-first sections
        if ($sectionsRendered -gt 0) {
            [void]$sb.AppendLine('        <span class="cc-nav-separator">|</span>')
        }

        # Render each accessible page. Class string is built via the
        # array-join pattern, same shape as the home link above.
        # RBAC_NavSection.accent_class stores values like 'nav-section-platform';
        # we prepend 'cc-' at emission time to produce 'cc-nav-section-platform'
        # for the new CC chrome class convention. Database content stays
        # unchanged.
        foreach ($page in $accessiblePages) {
            $pageTokens = @('cc-nav-link')
            if ($section.accent_class) {
                $pageTokens += "cc-$($section.accent_class)"
            }
            if ($page.page_route -eq $CurrentPageRoute) {
                $pageTokens += 'cc-active'
            }
            $pageClasses = $pageTokens -join ' '
            $label = [System.Web.HttpUtility]::HtmlEncode($page.nav_label)
            [void]$sb.AppendLine("        <a href=`"$($page.page_route)`" class=`"$pageClasses`">$label</a>")
        }

        $sectionsRendered++
    }

    # Append admin gear for admin users (always last; gets 'cc-active' class
    # when the user is currently viewing /admin). Same array-join pattern.
    if ($isAdmin) {
        $adminTokens = @('cc-nav-link', 'cc-nav-admin')
        if ($CurrentPageRoute -eq '/admin') { $adminTokens += 'cc-active' }
        $adminClasses = $adminTokens -join ' '
        [void]$sb.AppendLine('        <span class="cc-nav-spacer"></span>')
        [void]$sb.AppendLine("        <a href=`"/admin`" class=`"$adminClasses`" title=`"Administration`">&#9881;</a>")
    }

    [void]$sb.AppendLine('    </nav>')

    return $sb.ToString()
}

function Get-ChromeBannersHtml {
    [CmdletBinding()]
    param()

    <#
    .SYNOPSIS
        Renders the shared connection and page-error banner placeholders for a CC page.

    .DESCRIPTION
        Emits the two universal chrome banner placeholders every Control Center
        page includes: the connection-state banner operated by
        cc_updateConnectionBanner / cc_showReloadingBanner and the page-boot
        error banner operated by cc_renderPageError, both in cc-shared.js. Both
        are emitted as empty <div> elements carrying their fixed cc- chrome id
        and class; cc-shared.js locates each by id and populates it at runtime.
        Returned as a single block so a page includes both with one $bannerHtml
        substitution, parallel to how Get-NavBarHtml and Get-PageHeaderHtml
        supply the nav bar and page header. Takes no parameters: the
        placeholders are identical on every page.
    #>

    $sb = New-Object System.Text.StringBuilder 256
    [void]$sb.AppendLine('    <div id="cc-connection-banner" class="cc-connection-banner"></div>')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('    <div id="cc-page-error-banner" class="cc-page-error-banner"></div>')

    return $sb.ToString()
}

function Get-HomePageSections {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$UserContext
    )

    <#
    .SYNOPSIS
        Returns structured section-and-page data for rendering the Home page tile layout.

    .DESCRIPTION
        Filters RBAC_NavRegistry to the pages visible to the user, groups them
        by their RBAC_NavSection (including accent class and section title),
        and returns an ordered list of section hashtables each containing the
        pages that belong to it. Home-page-specific filtering (pages flagged
        as not-on-home) is applied here. Consumed by the Home page route to
        render the tile grid.

    .PARAMETER UserContext
        Hashtable from Get-UserContext containing user identity and roles.
    #>

    Confirm-RBACCache

    $result = @()

    if (-not $script:RBACCache.NavRegistry -or -not $script:RBACCache.NavSections) {
        return $result
    }

    $userRoles = $UserContext.Roles

    foreach ($section in $script:RBACCache.NavSections) {
        # Skip the admin section -- not rendered as Home tiles
        if ($section.section_key -eq 'admin') { continue }

        # Get pages in this section that should appear on Home
        $sectionPages = $script:RBACCache.NavRegistry | Where-Object {
            $_.section_key -eq $section.section_key -and $_.show_on_home -eq 1
        } | Sort-Object sort_order

        if (-not $sectionPages) { continue }

        # Filter pages by user's permissions
        $accessiblePages = @()
        foreach ($page in $sectionPages) {
            $tier = Get-UserPageTier -UserRoles $userRoles -PageRoute $page.page_route
            if ($tier) {
                $accessiblePages += @{
                    Route        = $page.page_route
                    NavLabel     = $page.nav_label
                    DisplayTitle = $page.display_title
                    Description  = $page.description
                    DocPageId    = $page.doc_page_id
                    SortOrder    = $page.sort_order
                    Tier         = $tier
                }
            }
        }

        # Skip empty sections
        if ($accessiblePages.Count -eq 0) { continue }

        $result += @{
            SectionKey   = $section.section_key
            SectionLabel = $section.section_label
            AccentClass  = $section.accent_class
            SortOrder    = $section.section_sort_order
            Pages        = $accessiblePages
        }
    }

    return $result
}

function Get-NavRegistryEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PageRoute
    )

    <#
    .SYNOPSIS
        Returns the cached RBAC_NavRegistry row for a single page route.

    .DESCRIPTION
        Single-row lookup against the RBAC_NavRegistry cache, used by page
        header rendering and browser-tab title resolution. Returns $null when
        no row exists for the supplied route.

    .PARAMETER PageRoute
        The page route path to look up.
    #>

    Confirm-RBACCache

    if ($script:RBACCache.NavRegistry) {
        $row = $script:RBACCache.NavRegistry | Where-Object { $_.page_route -eq $PageRoute } | Select-Object -First 1
        if ($row) { return $row }
    }

    # Placeholder when the route is missing from the registry. Visible in the UI
    # so a registration gap is obvious, but does not throw or break rendering.
    return @{
        nav_id        = 0
        page_route    = $PageRoute
        nav_label     = '(Unregistered Page)'
        display_title = '(Unregistered Page)'
        description   = "No RBAC_NavRegistry row found for route '$PageRoute'."
        section_key   = $null
        sort_order    = 0
        doc_page_id   = $null
        show_in_nav   = 0
        show_on_home  = 0
    }
}

function Get-PageHeaderHtml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PageRoute
    )

    <#
    .SYNOPSIS
        Renders the H1 plus subtitle block for a page from its RBAC_NavRegistry row.

    .DESCRIPTION
        Looks up the page in RBAC_NavRegistry and emits the standard
        cc-page-h1 / cc-page-h1-link / cc-page-subtitle block consumed by
        every CC page header. Includes the section-<key> compound modifier on
        the H1 to tint the page colour to its section accent. Falls back to a
        plain header when the page is not registered.

    .PARAMETER PageRoute
        The page route being rendered.
    #>

    $entry = Get-NavRegistryEntry -PageRoute $PageRoute

    $title = [System.Web.HttpUtility]::HtmlEncode([string]$entry.display_title)
    $description = [System.Web.HttpUtility]::HtmlEncode([string]$entry.description)

    if ($entry.doc_page_id -and -not [string]::IsNullOrWhiteSpace([string]$entry.doc_page_id)) {
        $docSlug = [System.Web.HttpUtility]::HtmlEncode([string]$entry.doc_page_id)
        $h1Inner = "<a href=`"/docs/pages/$docSlug.html`" target=`"_blank`" class=`"cc-page-h1-link`">$title</a>"
    }
    else {
        $h1Inner = $title
    }

    # Build the H1 class string via the array-join pattern: collect class
    # tokens into an array, then join with a single space. The cc-section-{key}
    # modifier (when present) is what cc-shared.css's color-routing rules
    # match; without it the H1 falls back to bare .cc-page-h1.
    # cc-section-<key> carries the cc- prefix per CC_CSS_Spec.md Section 7.1
    # (every class token in a compound must carry its section's declared prefix).
    $sectionKey = ConvertFrom-DBNull $entry.section_key
    $h1Tokens = @('cc-page-h1')
    if ($sectionKey) {
        $h1Tokens += "cc-section-$sectionKey"
    }
    $h1Classes = $h1Tokens -join ' '

    return "<h1 class=`"$h1Classes`">$h1Inner</h1>`n<p class=`"cc-page-subtitle`">$description</p>"
}

function Get-PageBrowserTitle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PageRoute,
        [string]$Suffix = 'xFACts Control Center'
    )

    <#
    .SYNOPSIS
        Returns the browser tab title for a page, with an optional suffix.

    .DESCRIPTION
        Looks up the page in RBAC_NavRegistry and returns its page title,
        concatenated with the supplied suffix. Used to populate the <title>
        element of every CC page so the browser tab shows the page name plus
        the platform name.

    .PARAMETER PageRoute
        The page route being rendered.

    .PARAMETER Suffix
        String appended after the page title, separated by a hyphen. Defaults to "xFACts Control Center".
    #>

    $entry = Get-NavRegistryEntry -PageRoute $PageRoute
    return "$([string]$entry.display_title) - $Suffix"
}

function Get-PageScriptTagHtml {
    [CmdletBinding()]
    param()

    <#
    .SYNOPSIS
        Returns the standard cc-shared.js script tag for embedding in CC page footers.

    .DESCRIPTION
        Returns the literal <script src="/js/cc-shared.js"></script> tag every
        CC page footer includes. Centralizes the include path so a future
        rename or relocation of cc-shared.js is a single-file change.
    #>

    return '<script src="/js/cc-shared.js"></script>'
}

<# ============================================================================
   FUNCTIONS: RBAC AUDIT LOG
   ----------------------------------------------------------------------------
   Insert path for audit rows describing every access or action evaluation.
   Verbosity is governed by the rbac_audit_verbosity GlobalConfig setting.
   Prefix: (none)
   ============================================================================ #>

function Write-RBACAuditLog {
    [CmdletBinding()]
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

    <#
    .SYNOPSIS
        Inserts an audit row into RBAC_AuditLog describing an access or action evaluation.

    .DESCRIPTION
        Writes a single audit row capturing the event type, user identity,
        resolved roles, page and action context, required vs. resolved tier,
        outcome (granted / denied / audit), and optional detail and client IP.
        Verbosity is governed by the rbac_audit_verbosity GlobalConfig
        setting; the caller decides whether to invoke this helper based on
        that setting.

    .PARAMETER EventType
        The event type literal (PAGE_ACCESS, ACTION_PERMISSION, ENDPOINT, etc.).

    .PARAMETER Username
        The acting user's SAM account name.

    .PARAMETER UserGroups
        Array of AD groups the user held at evaluation time.

    .PARAMETER UserRoles
        Array of RBAC roles the user resolved to.

    .PARAMETER PageRoute
        The page route the event concerns.

    .PARAMETER ActionName
        The action name when the event is action- or endpoint-related.

    .PARAMETER RequiredTier
        The tier the page or action required.

    .PARAMETER UserTier
        The tier the user resolved to for the page.

    .PARAMETER Result
        The outcome literal (GRANTED, DENIED, AUDIT, etc.).

    .PARAMETER Detail
        Free-text detail describing the decision path.

    .PARAMETER ClientIp
        The client IP address from the request.
    #>

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

<# ============================================================================
   FUNCTIONS: ACCESS DENIED RESPONSES
   ----------------------------------------------------------------------------
   Standard response builders for the 403 outcomes: the page-level HTML
   denial returned by routes whose Get-UserAccess check fails, and the
   JSON payload returned by API routes whose action checks fail.
   Prefix: (none)
   ============================================================================ #>

function Get-AccessDeniedHtml {
    [CmdletBinding()]
    param(
        [string]$DisplayName = 'Unknown User',
        [string]$PageRoute = ''
    )
    <#
    .SYNOPSIS
        Returns a styled 403 Access Denied HTML page matching the Control Center theme.
    .DESCRIPTION
        Returns the complete HTML body for a page-level access denial,
        styled to match the Control Center dark theme. Embedded by page
        routes immediately after a Get-UserAccess check returns HasAccess =
        $false, paired with a 403 status code. The inline <style> block is
        permitted under CC_HTML_Spec section 1.4 because authentication
        or authorization failure may coincide with conditions that prevent
        loading of /css/cc-shared.css.
    .PARAMETER DisplayName
        The user's display name shown on the denial page.
    .PARAMETER PageRoute
        The page the user attempted to access. Currently informational; not rendered.
    #>
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
        .denied-subtext { font-size: 12px; color: #666; }
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
        <p class="denied-subtext">If you believe this is an error, contact the Applications Team.</p>
        <a href="/" class="home-link">Go Home</a>
    </div>
</body>
</html>
"@
}

function Get-ActionDeniedResponse {
    [CmdletBinding()]
    param(
        [string]$ActionName = 'this action'
    )

    <#
    .SYNOPSIS
        Returns a standardized 403 JSON payload for API action denials.

    .DESCRIPTION
        Returns the hashtable that API routes pass to Write-PodeJsonResponse
        with status code 403 when an action check fails. Provides a
        consistent error shape across every Control Center API endpoint.

    .PARAMETER ActionName
        The action name that was denied, surfaced in the error payload for the client.
    #>

    return [PSCustomObject]@{
        Error   = "Access Denied"
        Message = "You do not have permission to perform $ActionName."
    }
}

<# ============================================================================
   FUNCTIONS: API CACHE
   ----------------------------------------------------------------------------
   TTL-based cache around expensive API workloads. Configuration TTLs are
   loaded from GlobalConfig at startup; per-key cached values live in the
   ApiCache Pode state bag.
   Prefix: (none)
   ============================================================================ #>

function Initialize-ApiCacheConfig {
    [CmdletBinding()]
    param()

    <#
    .SYNOPSIS
        Loads API cache TTL settings from GlobalConfig into the ApiCacheConfig Pode state bag.

    .DESCRIPTION
        Reads the api_cache_* GlobalConfig settings and writes them into the
        ApiCacheConfig shared Pode state. Called by Start-ControlCenter at
        application startup and after the operator triggers a manual config
        reload. Without this, Get-CachedResult falls back to a hardcoded
        emergency TTL.
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
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CacheKey,

        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,

        [switch]$ForceRefresh
    )

    <#
    .SYNOPSIS
        Returns a cached query result, executing and caching the supplied scriptblock on miss.

    .DESCRIPTION
        Lock-guarded cache lookup against the ApiCache Pode state bag. On
        hit, returns the stored value if it has not aged beyond its TTL. On
        miss or forced refresh, releases the lock, executes the supplied
        scriptblock, reacquires the lock and stores the result. Used by API
        routes that produce expensive aggregates which only need to refresh
        on a known cadence.

    .PARAMETER CacheKey
        Unique string identifying the cached value. Caller decides the key shape.

    .PARAMETER ScriptBlock
        The work to perform on cache miss. Must return the value to cache.

    .PARAMETER ForceRefresh
        Switch that bypasses the freshness check and re-executes the scriptblock.
    #>

    # Resolve TTL from cached config
    # Hardcoded emergency fallback
    $ttlSeconds = 600

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

    # Check cache (unless force refresh)
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

    # Cache miss or force refresh: execute query OUTSIDE the lock
    $result = & $ScriptBlock

    # Store result in cache
    Lock-PodeObject -Name 'ApiCache' -ScriptBlock {
        $cache = Get-PodeState -Name 'ApiCache'
        $cache[$CacheKey] = @{
            Data      = $result
            Timestamp = Get-Date
        }
    }

    return $result
}

<# ============================================================================
   FUNCTIONS: CRS5 DATABASE
   ----------------------------------------------------------------------------
   Connections and query execution against the CRS5 (Debt Manager)
   databases. The target instance resolves from explicit override,
   GlobalConfig dm_target_instance, or the environment default.
   Prefix: (none)
   ============================================================================ #>

function Get-CRS5Connection {
    [CmdletBinding()]
    param(
        [string]$TargetInstance
    )

    <#
    .SYNOPSIS
        Builds and returns a SqlConnection to the resolved CRS5 target instance.

    .DESCRIPTION
        Resolves the target CRS5 (Debt Manager) instance -- explicit override,
        GlobalConfig dm_target_instance, or the environment default -- builds
        a SqlConnection using Integrated Security with the xFACts Control
        Center ApplicationName, opens it, and returns the open connection.
        Caller is responsible for closing and disposing.

    .PARAMETER TargetInstance
        Optional explicit instance name. When supplied this overrides GlobalConfig and the environment default.
    #>

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
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Query,
        [hashtable]$Parameters = @{},
        [int]$TimeoutSeconds = 60,
        [string]$TargetInstance
    )

    <#
    .SYNOPSIS
        Executes a read-only query against a CRS5 (Debt Manager) instance.

    .DESCRIPTION
        Opens a connection to the resolved CRS5 target instance via
        Get-CRS5Connection, executes the supplied SELECT query (or other
        result-set-returning statement), and returns each row as a hashtable.
        Closes the connection in a finally block.

    .PARAMETER Query
        The SQL query text to execute.

    .PARAMETER Parameters
        Optional hashtable of parameter name/value pairs.

    .PARAMETER TimeoutSeconds
        Command timeout in seconds. Defaults to 60.

    .PARAMETER TargetInstance
        Optional explicit CRS5 instance override.
    #>

    $connStrings = Get-CRS5Connection -TargetInstance $TargetInstance
    $conn = New-Object System.Data.SqlClient.SqlConnection($connStrings.Read)
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $Query
        $cmd.CommandTimeout = $TimeoutSeconds

        foreach ($key in $Parameters.Keys) {
            $p = $cmd.Parameters.AddWithValue("@$key", $Parameters[$key])
            if ($Parameters[$key] -is [string]) { $p.SqlDbType = [System.Data.SqlDbType]::VarChar }
        }

        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null

        $results = [System.Collections.ArrayList]::new()
        if ($dataset.Tables.Count -gt 0) {
            foreach ($row in $dataset.Tables[0].Rows) {
                $obj = @{}
                foreach ($col in $dataset.Tables[0].Columns) {
                    $obj[$col.ColumnName] = $row[$col.ColumnName]
                }
                $results.Add($obj) | Out-Null
            }
        }
        return ,$results
    }
    finally {
        if ($conn.State -eq 'Open') { $conn.Close() }
    }
}

function Invoke-CRS5WriteQuery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Query,
        [hashtable]$Parameters = @{},
        [string]$TargetInstance
    )

    <#
    .SYNOPSIS
        Executes a write statement against a CRS5 (Debt Manager) instance and returns affected rows.

    .DESCRIPTION
        Opens a connection to the resolved CRS5 target instance via
        Get-CRS5Connection, executes the supplied INSERT/UPDATE/DELETE
        statement, and returns the row count from ExecuteNonQuery. Closes the
        connection in a finally block.

    .PARAMETER Query
        The SQL statement to execute.

    .PARAMETER Parameters
        Optional hashtable of parameter name/value pairs.

    .PARAMETER TargetInstance
        Optional explicit CRS5 instance override.
    #>

    $connStrings = Get-CRS5Connection -TargetInstance $TargetInstance
    $conn = New-Object System.Data.SqlClient.SqlConnection($connStrings.Write)
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $Query
        $cmd.CommandTimeout = 30

        foreach ($key in $Parameters.Keys) {
            $p = $cmd.Parameters.AddWithValue("@$key", $Parameters[$key])
            if ($Parameters[$key] -is [string]) { $p.SqlDbType = [System.Data.SqlDbType]::VarChar }
        }

        return $cmd.ExecuteNonQuery()
    }
    finally {
        if ($conn.State -eq 'Open') { $conn.Close() }
    }
}

<# ============================================================================
   FUNCTIONS: PROFANITY REDACTION
   ----------------------------------------------------------------------------
   Shared logic for the profanity redaction tool surfaced on the Business
   Services and Applications & Integration pages. Get-RedactionEvent finds
   candidate cnsmr_accnt_ar_log events to redact; Invoke-ProfanityRedaction
   performs the paired write (redact the message, insert a review event) as a
   single CRS5 transaction. Both consume the CRS5 read/write helpers above.
   Prefix: (none)
   ============================================================================ #>

function Get-RedactionEvent {
    [CmdletBinding(DefaultParameterSetName = 'ById')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'ById')]
        [long]$LogId,

        [Parameter(Mandatory, ParameterSetName = 'ByConsumer')]
        [string]$AgencyId,

        [Parameter(Mandatory, ParameterSetName = 'ByConsumer')]
        [string]$EventDate
    )

    <#
    .SYNOPSIS
        Finds cnsmr_accnt_ar_log events that are candidates for profanity redaction.

    .DESCRIPTION
        Searches the CRS5 cnsmr_accnt_ar_log table for events to redact, in one
        of two modes. ById returns the single event with the supplied
        cnsmr_accnt_ar_log_id. ByConsumer joins to the cnsmr table on cnsmr_id,
        filters by the consumer's agency identifier (cnsmr_idntfr_agncy_id) and
        the event date (the date portion of upsrt_dttm), and returns every event
        for that consumer on that day. Results are ordered so the events carrying
        the non-standard-reply action/result codes (actn_cd 352, rslt_cd 617)
        sort first, since those are the likely redaction targets, with everything
        else following. Read-only; uses Invoke-CRS5ReadQuery.

    .PARAMETER LogId
        The cnsmr_accnt_ar_log_id of the specific event to retrieve (ById mode).

    .PARAMETER AgencyId
        The consumer's cnsmr_idntfr_agncy_id to search by (ByConsumer mode).

    .PARAMETER EventDate
        The event date (yyyy-MM-dd) to search by (ByConsumer mode).
    #>

    if ($PSCmdlet.ParameterSetName -eq 'ById') {
        return Invoke-CRS5ReadQuery -Query @"
            SELECT
                ar.cnsmr_accnt_ar_log_id,
                ar.cnsmr_id,
                ar.actn_cd,
                ar.rslt_cd,
                ar.cnsmr_accnt_ar_mssg_txt,
                ar.upsrt_dttm
            FROM crs5_oltp.dbo.cnsmr_accnt_ar_log ar
            WHERE ar.cnsmr_accnt_ar_log_id = @log_id
"@ -Parameters @{ log_id = $LogId }
    }

    return Invoke-CRS5ReadQuery -Query @"
        SELECT
            ar.cnsmr_accnt_ar_log_id,
            ar.cnsmr_id,
            ar.actn_cd,
            ar.rslt_cd,
            ar.cnsmr_accnt_ar_mssg_txt,
            ar.upsrt_dttm
        FROM crs5_oltp.dbo.cnsmr_accnt_ar_log ar
        INNER JOIN crs5_oltp.dbo.cnsmr c
            ON c.cnsmr_id = ar.cnsmr_id
        WHERE c.cnsmr_idntfr_agncy_id = @agency_id
          AND CAST(ar.upsrt_dttm AS DATE) = @event_date
        ORDER BY
            CASE WHEN ar.actn_cd = 352 AND ar.rslt_cd = 617 THEN 0 ELSE 1 END,
            ar.upsrt_dttm DESC
"@ -Parameters @{ agency_id = $AgencyId; event_date = $EventDate }
}

function Invoke-ProfanityRedaction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][long]$LogId,
        [Parameter(Mandatory)][string]$Username,
        [Parameter(Mandatory)][string]$RedactionBody,
        [Parameter(Mandatory)][string]$ReviewMessage
    )

    <#
    .SYNOPSIS
        Redacts a cnsmr_accnt_ar_log event's message and inserts a paired review event.

    .DESCRIPTION
        Performs the profanity redaction as a single CRS5 transaction. Resolves
        the acting user's DM usr_id from the CRS5 usr table by usr_usrnm; if the
        user is not provisioned in DM the batch raises USER_NOT_PROVISIONED and
        nothing is written. Reads the target event's cnsmr_id and current message;
        if the event is missing the batch raises EVENT_NOT_FOUND. Preserves the
        original received-timestamp tail (everything from the last '@' in the
        original message) by appending it to the supplied redaction body; when the
        original carries no '@' tail the redaction body stands alone. Inside one
        transaction it (1) updates the target event's message text, stamps
        upsrt_soft_comp_id 114, and increments upsrt_trnsctn_nmbr, and (2) inserts
        a review event on the same cnsmr_id carrying actn_cd 228, rslt_cd 236, the
        supplied review message, the resolved usr_id as both creator and upsert
        user, the current datetime, upsrt_soft_comp_id 114, and upsrt_trnsctn_nmbr
        0. The original event's upsrt_usr_id and upsrt_dttm are deliberately not
        touched, so the redaction does not overwrite the original actor or time.
        Both writes commit together or roll back together (SET XACT_ABORT ON).
        Returns the affected row count from Invoke-CRS5WriteQuery.

    .PARAMETER LogId
        The cnsmr_accnt_ar_log_id of the event to redact.

    .PARAMETER Username
        The acting user's bare username, matched against crs5_oltp.dbo.usr.usr_usrnm.

    .PARAMETER RedactionBody
        The replacement message body for the redacted event. The preserved
        timestamp tail, when present, is appended to this server-side.

    .PARAMETER ReviewMessage
        The full message text for the inserted review event, including the
        redacted event's id (composed by the caller).
    #>

    $batch = @"
SET XACT_ABORT ON;
SET NOCOUNT ON;

DECLARE @usr_id BIGINT;
SELECT @usr_id = usr_id FROM crs5_oltp.dbo.usr WHERE usr_usrnm = @username;
IF @usr_id IS NULL
BEGIN
    RAISERROR('USER_NOT_PROVISIONED', 16, 1);
    RETURN;
END

DECLARE @cnsmr_id BIGINT;
DECLARE @orig_msg VARCHAR(8000);
SELECT @cnsmr_id = cnsmr_id, @orig_msg = cnsmr_accnt_ar_mssg_txt
FROM crs5_oltp.dbo.cnsmr_accnt_ar_log
WHERE cnsmr_accnt_ar_log_id = @log_id;
IF @cnsmr_id IS NULL
BEGIN
    RAISERROR('EVENT_NOT_FOUND', 16, 1);
    RETURN;
END

DECLARE @tail VARCHAR(8000) = '';
IF CHARINDEX('@', REVERSE(@orig_msg)) > 0
    SET @tail = ' ' + SUBSTRING(@orig_msg,
        LEN(@orig_msg) - CHARINDEX('@', REVERSE(@orig_msg)) + 1, 8000);

DECLARE @new_msg VARCHAR(8000) = @redaction_body + @tail;

BEGIN TRAN;

UPDATE crs5_oltp.dbo.cnsmr_accnt_ar_log
SET cnsmr_accnt_ar_mssg_txt = @new_msg,
    upsrt_soft_comp_id      = 114,
    upsrt_trnsctn_nmbr      = upsrt_trnsctn_nmbr + 1
WHERE cnsmr_accnt_ar_log_id = @log_id;

INSERT INTO crs5_oltp.dbo.cnsmr_accnt_ar_log
    (actn_cd, cnsmr_id, rslt_cd, cnsmr_accnt_ar_mssg_txt,
     cnsmr_accnt_ar_log_crt_usr_id, upsrt_dttm,
     upsrt_soft_comp_id, upsrt_trnsctn_nmbr, upsrt_usr_id)
VALUES
    (228, @cnsmr_id, 236, @review_msg,
     @usr_id, GETDATE(), 114, 0, @usr_id);

COMMIT TRAN;
"@

    return Invoke-CRS5WriteQuery -Query $batch -Parameters @{
        log_id         = $LogId
        username       = $Username
        redaction_body = $RedactionBody
        review_msg     = $ReviewMessage
    }
}

<# ============================================================================
   FUNCTIONS: DMOPS CACHE
   ----------------------------------------------------------------------------
   Cached aggregate counts for the DmOps archive pipeline dashboard,
   refreshed from the database when the in-memory cache ages out.
   Prefix: (none)
   ============================================================================ #>

function Get-RemainingCounts {
    [CmdletBinding()]
    param()

    <#
    .SYNOPSIS
        Returns cached aggregate counts of remaining work items in the DmOps archive pipeline.

    .DESCRIPTION
        Reads the cached counts from $script:DmOpsRemainingCache, refreshing
        the cache from the database when stale. Returns a hashtable with the
        counts the DmOps dashboard renders. Cache TTL is short because the
        underlying numbers change with every archive run.
    #>

    $cache = $script:DmOpsRemainingCache
    $now = Get-Date

    # Check if cache is still valid
    if ($cache.BaselineDttm -and ($now - $cache.BaselineDttm).TotalMinutes -lt $cache.CacheMaxAgeMinutes) {
        return $cache
    }

    # Get Archive and ShellPurge target instances independently from GlobalConfig
    $targetConfig = Invoke-XFActsQuery -Query @"
        SELECT category, setting_value FROM dbo.GlobalConfig
        WHERE module_name = 'DmOps'
          AND category IN ('Archive', 'ShellPurge')
          AND setting_name = 'target_instance'
          AND is_active = 1
"@
    $archiveTargetInstance    = 'AVG-PROD-LSNR'
    $shellPurgeTargetInstance = 'AVG-PROD-LSNR'
    if ($targetConfig) {
        foreach ($row in $targetConfig) {
            if ($row.category -eq 'Archive')    { $archiveTargetInstance    = [string]$row.setting_value }
            if ($row.category -eq 'ShellPurge') { $shellPurgeTargetInstance = [string]$row.setting_value }
        }
    }

    try {
        # Archive remaining: TC_ARCH-tagged consumers in the two archive
        # workgroups, split by line of business (WFAARCH1 = 1P, WFAARCH3 = 3P),
        # plus the accounts on those consumers. Under the workgroup model a
        # TC_ARCH consumer is only archivable once moved into one of these
        # workgroups, so the per-workgroup counts are the real remaining work;
        # ALL is their sum. Single query keeps this one OLTP round-trip.
        $archiveResult = Invoke-CRS5ReadQuery -TargetInstance $archiveTargetInstance -Query @"
            SELECT
                (SELECT COUNT(*)
                 FROM crs5_oltp.dbo.cnsmr_Tag ct
                 INNER JOIN crs5_oltp.dbo.tag t ON t.tag_id = ct.tag_id
                 INNER JOIN crs5_oltp.dbo.cnsmr c ON c.cnsmr_id = ct.cnsmr_id
                 INNER JOIN crs5_oltp.dbo.wrkgrp w ON w.wrkgrp_id = c.wrkgrp_id
                 WHERE ct.cnsmr_tag_sft_delete_flg = 'N'
                   AND t.tag_shrt_nm = 'TC_ARCH'
                   AND w.wrkgrp_shrt_nm = 'WFAARCH1') AS consumers_1p,
                (SELECT COUNT(*)
                 FROM crs5_oltp.dbo.cnsmr_Tag ct
                 INNER JOIN crs5_oltp.dbo.tag t ON t.tag_id = ct.tag_id
                 INNER JOIN crs5_oltp.dbo.cnsmr c ON c.cnsmr_id = ct.cnsmr_id
                 INNER JOIN crs5_oltp.dbo.wrkgrp w ON w.wrkgrp_id = c.wrkgrp_id
                 WHERE ct.cnsmr_tag_sft_delete_flg = 'N'
                   AND t.tag_shrt_nm = 'TC_ARCH'
                   AND w.wrkgrp_shrt_nm = 'WFAARCH3') AS consumers_3p,
                (SELECT COUNT(*)
                 FROM crs5_oltp.dbo.cnsmr_accnt ca
                 WHERE ca.cnsmr_id IN (
                     SELECT ct.cnsmr_id
                     FROM crs5_oltp.dbo.cnsmr_Tag ct
                     INNER JOIN crs5_oltp.dbo.tag t ON t.tag_id = ct.tag_id
                     INNER JOIN crs5_oltp.dbo.cnsmr c ON c.cnsmr_id = ct.cnsmr_id
                     INNER JOIN crs5_oltp.dbo.wrkgrp w ON w.wrkgrp_id = c.wrkgrp_id
                     WHERE ct.cnsmr_tag_sft_delete_flg = 'N'
                       AND t.tag_shrt_nm = 'TC_ARCH'
                       AND w.wrkgrp_shrt_nm = 'WFAARCH1'
                 )) AS accounts_1p,
                (SELECT COUNT(*)
                 FROM crs5_oltp.dbo.cnsmr_accnt ca
                 WHERE ca.cnsmr_id IN (
                     SELECT ct.cnsmr_id
                     FROM crs5_oltp.dbo.cnsmr_Tag ct
                     INNER JOIN crs5_oltp.dbo.tag t ON t.tag_id = ct.tag_id
                     INNER JOIN crs5_oltp.dbo.cnsmr c ON c.cnsmr_id = ct.cnsmr_id
                     INNER JOIN crs5_oltp.dbo.wrkgrp w ON w.wrkgrp_id = c.wrkgrp_id
                     WHERE ct.cnsmr_tag_sft_delete_flg = 'N'
                       AND t.tag_shrt_nm = 'TC_ARCH'
                       AND w.wrkgrp_shrt_nm = 'WFAARCH3'
                 )) AS accounts_3p
"@ -TimeoutSeconds 60

        # Shell remaining: WFAPURGE workgroup consumers (naturally-occurring shells).
        # Routes against ShellPurge's configured target_instance.
        $shellResult = Invoke-CRS5ReadQuery -TargetInstance $shellPurgeTargetInstance -Query @"
            SELECT COUNT(c.cnsmr_id) AS remaining_count
            FROM crs5_oltp.dbo.cnsmr c
            INNER JOIN crs5_oltp.dbo.wrkgrp w ON w.wrkgrp_id = c.wrkgrp_id
                AND w.wrkgrp_shrt_nm = 'WFAPURGE'
"@ -TimeoutSeconds 30

        # Update cache: per-workgroup figures and the ALL combined sums.
        if ($archiveResult -and $archiveResult.Count -gt 0) {
            $c1p = [long]$archiveResult[0].consumers_1p
            $c3p = [long]$archiveResult[0].consumers_3p
            $a1p = [long]$archiveResult[0].accounts_1p
            $a3p = [long]$archiveResult[0].accounts_3p

            $cache.ArchiveConsumersRemaining1P = $c1p
            $cache.ArchiveConsumersRemaining3P = $c3p
            $cache.ArchiveAccountsRemaining1P  = $a1p
            $cache.ArchiveAccountsRemaining3P  = $a3p
            $cache.ArchiveConsumersRemaining   = $c1p + $c3p
            $cache.ArchiveAccountsRemaining    = $a1p + $a3p
        }
        else {
            $cache.ArchiveConsumersRemaining1P = $null
            $cache.ArchiveConsumersRemaining3P = $null
            $cache.ArchiveAccountsRemaining1P  = $null
            $cache.ArchiveAccountsRemaining3P  = $null
            $cache.ArchiveConsumersRemaining   = $null
            $cache.ArchiveAccountsRemaining    = $null
        }
        $cache.ShellRemaining = if ($shellResult -and $shellResult.Count -gt 0) { [long]$shellResult[0].remaining_count } else { $null }
        $cache.BaselineDttm = $now
        $cache.ArchiveTargetInstance    = $archiveTargetInstance
        $cache.ShellPurgeTargetInstance = $shellPurgeTargetInstance
    }
    catch {
        Write-Warning "Failed to refresh remaining counts from crs5_oltp (Archive: $archiveTargetInstance, ShellPurge: $shellPurgeTargetInstance): $($_.Exception.Message)"
    }

    return $cache
}

<# ============================================================================
   FUNCTIONS: SERVICE CREDENTIALS
   ----------------------------------------------------------------------------
   Decryption path for the encrypted Credentials table. Master passphrase
   is retrieved fresh on every call by design; no caching.
   Prefix: (none)
   ============================================================================ #>

function Get-ServiceCredentials {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ServiceName,

        [string]$Environment = 'PROD'
    )

    <#
    .SYNOPSIS
        Returns decrypted credentials for a registered service in a target environment.

    .DESCRIPTION
        Looks up the requested service and environment in the encrypted
        Credentials table, retrieves the AES-encrypted username and password,
        fetches the master passphrase fresh on each call (no caching by
        design), and returns a hashtable containing the decrypted username
        and password. Used by DM API integrations and Sterling B2B operations.

    .PARAMETER ServiceName
        The service name as registered in Credentials.service_name.

    .PARAMETER Environment
        The target environment (PROD, TEST, etc.). Defaults to PROD.
    #>

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

<# ============================================================================
   FUNCTIONS: AG READ QUERY
   ----------------------------------------------------------------------------
   Generalized read-only query helper that routes to the AG secondary
   replica via ApplicationIntent ReadOnly, for cross-database reporting
   reads.
   Prefix: (none)
   ============================================================================ #>

function Invoke-AGReadQuery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][string]$Query,
        [hashtable]$Parameters = @{},
        [int]$TimeoutSeconds = 60
    )

    <#
    .SYNOPSIS
        Generalized read-only query against any AG-hosted database via the listener.

    .DESCRIPTION
        Builds a connection to the AVG-PROD-LSNR listener with ApplicationIntent
        set to ReadOnly so the request is routed to the secondary replica.
        Executes the supplied query against the named database and returns each
        row as a hashtable. Used by reporting routes and ad-hoc read-only
        cross-database queries.

    .PARAMETER Database
        The target database name on the AG listener.

    .PARAMETER Query
        The SQL query text to execute.

    .PARAMETER Parameters
        Optional hashtable of parameter name/value pairs.

    .PARAMETER TimeoutSeconds
        Command timeout in seconds. Defaults to 60.
    #>

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
            $p = $cmd.Parameters.AddWithValue("@$key", $Parameters[$key])
            if ($Parameters[$key] -is [string]) { $p.SqlDbType = [System.Data.SqlDbType]::VarChar }
        }

        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null

        $results = [System.Collections.ArrayList]::new()
        if ($dataset.Tables.Count -gt 0) {
            foreach ($row in $dataset.Tables[0].Rows) {
                $obj = @{}
                foreach ($col in $dataset.Tables[0].Columns) {
                    $obj[$col.ColumnName] = $row[$col.ColumnName]
                }
                $results.Add($obj) | Out-Null
            }
        }
        return ,$results
    }
    finally {
        if ($conn.State -eq 'Open') { $conn.Close() }
    }
}

<# ============================================================================
   FUNCTIONS: DATA CONVERSION HELPERS
   ----------------------------------------------------------------------------
   DBNull-safe value normalizers used to prepare SQL result rows for clean
   JSON serialization from API endpoints.
   Prefix: (none)
   ============================================================================ #>

function ConvertTo-SafeValue {
    [CmdletBinding()]
    param($Value)

    <#
    .SYNOPSIS
        Returns $null when the value is DBNull, otherwise returns the value unchanged.

    .DESCRIPTION
        Used to normalize SQL result-set values for clean JSON serialization,
        where DBNull would otherwise serialize as an empty object instead of
        JSON null.

    .PARAMETER Value
        The raw value to normalize. May be [DBNull] or any other type.
    #>

    if ($Value -is [DBNull]) { return $null }
    return $Value
}

function ConvertTo-SafeDate {
    [CmdletBinding()]
    param($Value, [string]$Format = "yyyy-MM-dd")

    <#
    .SYNOPSIS
        Converts a date value to a formatted string, returning $null for DBNull or empty values.

    .DESCRIPTION
        Date-typed companion to ConvertTo-SafeValue. Casts the input to
        DateTime when possible and applies the supplied format string,
        returning $null on DBNull, null, or cast failure.

    .PARAMETER Value
        The raw value to format. May be [DBNull], $null, or any date-castable value.

    .PARAMETER Format
        The .NET date format string. Defaults to yyyy-MM-dd.
    #>

    if ($Value -is [DBNull] -or $null -eq $Value) { return $null }
    try { return ([DateTime]$Value).ToString($Format) } catch { return $null }
}

function ConvertTo-SafeDateTime {
    [CmdletBinding()]
    param($Value)

    <#
    .SYNOPSIS
        Converts a datetime value to yyyy-MM-dd HH:mm:ss format, returning $null for DBNull or empty values.

    .DESCRIPTION
        DateTime-typed companion to ConvertTo-SafeValue. Casts the input to
        DateTime when possible and applies the platform's standard timestamp
        format, returning $null on DBNull, null, or cast failure.

    .PARAMETER Value
        The raw value to format. May be [DBNull], $null, or any datetime-castable value.
    #>

    if ($Value -is [DBNull] -or $null -eq $Value) { return $null }
    try { return ([DateTime]$Value).ToString("yyyy-MM-dd HH:mm:ss") } catch { return $null }
}

function ConvertTo-SafeDecimal {
    [CmdletBinding()]
    param($Value)

    <#
    .SYNOPSIS
        Converts a numeric value to decimal, returning $null for DBNull or empty values.

    .DESCRIPTION
        Decimal-typed companion to ConvertTo-SafeValue. Casts the input to
        decimal when possible, returning $null on DBNull, null, or cast
        failure.

    .PARAMETER Value
        The raw value to cast. May be [DBNull], $null, or any decimal-castable value.
    #>

    if ($Value -is [DBNull] -or $null -eq $Value) { return $null }
    try { return [decimal]$Value } catch { return $null }
}

<# ============================================================================
   FUNCTIONS: BDL PROCESS
   ----------------------------------------------------------------------------
   BDL XML construction from staging tables (main operational-transaction
   payload plus the optional CONSUMER_ACCOUNT_AR_LOG payload), and
   post-submission reconciliation of BDL_ImportLog rows against the
   destination DM File_Registry.
   Prefix: (none)
   ============================================================================ #>

function ConvertTo-BDLXml {
    [CmdletBinding()]
    param(
        [string]$StagingTable,
        [string]$EntityType,
        [int]$ConfigId,
        $WebEvent
    )

    <#
    .SYNOPSIS
        Builds the BDL operational-transaction XML from a staging table and catalog metadata.

    .DESCRIPTION
        Reads non-skipped rows from the named staging table, looks up the
        wrapper element name, entity element name, nullify-eligible columns,
        and boolean columns from the BDL catalog, then emits the complete
        BDL XML payload (mirroring the reference VBA structure) ready for
        submission to Debt Manager. Returns a hashtable carrying the XML
        string, filename, row count, skipped count, environment, and any
        error condition.

    .PARAMETER StagingTable
        The Staging-schema table name containing rows to load.

    .PARAMETER EntityType
        The BDL entity type the staging rows describe.

    .PARAMETER ConfigId
        Tools.EnvironmentConfig config_id selecting the target environment.

    .PARAMETER WebEvent
        The Pode $WebEvent, used to capture the requesting user identity in the XML header.
    #>

    # Validate staging table exists
    $tableCheck = Invoke-XFActsQuery -Query @"
        SELECT 1 FROM sys.tables t
        INNER JOIN sys.schemas s ON s.schema_id = t.schema_id
        WHERE s.name = 'Staging' AND t.name = @tableName
"@ -Parameters @{ tableName = $StagingTable }

    if (-not $tableCheck -or $tableCheck.Count -eq 0) {
        return @{ Error = "Staging table not found: $StagingTable"; StatusCode = 404 }
    }

    # Get environment config
    $envConfig = Invoke-XFActsQuery -Query @"
        SELECT environment FROM Tools.EnvironmentConfig
        WHERE config_id = @configId AND is_active = 1
"@ -Parameters @{ configId = $ConfigId }

    if (-not $envConfig -or $envConfig.Count -eq 0) {
        return @{ Error = 'Environment configuration not found'; StatusCode = 404 }
    }
    $environment = $envConfig[0].environment

    # Get entity format info
    $formatInfo = Invoke-XFActsQuery -Query @"
        SELECT f.format_id, f.entity_type, f.type_name, f.batch_abbreviation, f.has_nullify_fields, f.operational_transaction_type
        FROM Tools.Catalog_BDLFormatRegistry f
        WHERE f.entity_type = @entityType
          AND f.is_active = 1
"@ -Parameters @{ entityType = $EntityType }

    if (-not $formatInfo -or $formatInfo.Count -eq 0) {
        return @{ Error = "Entity type not found: $EntityType"; StatusCode = 404 }
    }
    $typeName = $formatInfo[0].type_name
    $batchAbbrev = if ($formatInfo[0].batch_abbreviation -and $formatInfo[0].batch_abbreviation -isnot [System.DBNull]) { $formatInfo[0].batch_abbreviation } else { $EntityType.Substring(0, [Math]::Min($EntityType.Length, 14)) }
    $hasNullifyFields = $formatInfo[0].has_nullify_fields -eq 1

    # Get non-nullifiable fields (for record-level nullify)
    $nonNullifiableSet = @{}
    if ($hasNullifyFields) {
        $nonNullifiable = Invoke-XFActsQuery -Query @"
            SELECT element_name FROM Tools.Catalog_BDLElementRegistry
            WHERE format_id = @formatId AND is_not_nullifiable = 1
"@ -Parameters @{ formatId = $formatInfo[0].format_id }
        if ($nonNullifiable) { $nonNullifiable | ForEach-Object { $nonNullifiableSet[$_.element_name] = $true } }
    }

    # Get boolean fields (for true/false normalization)
    $booleanFields = @{}
    $boolFieldRows = Invoke-XFActsQuery -Query @"
        SELECT element_name FROM Tools.Catalog_BDLElementRegistry
        WHERE format_id = @formatId AND data_type = 'boolean'
"@ -Parameters @{ formatId = $formatInfo[0].format_id }
    if ($boolFieldRows) { $boolFieldRows | ForEach-Object { $booleanFields[$_.element_name] = $true } }

    # Get wrapper info from catalog
    $wrapperInfo = Invoke-XFActsQuery -Query @"
        SELECT w.type_name AS wrapper_type, we.element_name AS entity_element
        FROM Tools.Catalog_BDLFormatRegistry w
        INNER JOIN Tools.Catalog_BDLElementRegistry we
            ON we.format_id = w.format_id
        WHERE we.data_type = @typeName
          AND w.entity_type IS NULL
"@ -Parameters @{ typeName = $typeName }

    # Determine wrapper element name and entity element name
    # default
    $wrapperElement = 'consumer_operational_transaction_data'
    $entityElement = $typeName -replace '_data_type$', ''

    if ($wrapperInfo -and $wrapperInfo.Count -gt 0) {
        $wrapperElement = $wrapperInfo[0].wrapper_type -replace '_type$', ''
        $entityElement = $wrapperInfo[0].entity_element
    }

    # Determine the operational_transaction_type for the header. Read the
    # explicit value from the catalog rather than inferring it from folder
    # text. A missing value is a hard error: emitting a guessed transaction
    # type can register an import that then fails (or, worse, succeeds against
    # the wrong data), so the build refuses to proceed until the entity is
    # configured in Tools.Catalog_BDLFormatRegistry.
    $operationalTransactionType = $formatInfo[0].operational_transaction_type
    if ($operationalTransactionType -is [System.DBNull] -or
        $null -eq $operationalTransactionType -or
        ([string]$operationalTransactionType).Trim() -eq '') {
        return @{ Error = "operational_transaction_type is not configured for entity type '$EntityType'. Set it in Tools.Catalog_BDLFormatRegistry before importing."; StatusCode = 500 }
    }
    $operationalTransactionType = [string]$operationalTransactionType

    # Read staging data (non-skipped rows)
    $safeTable = "Staging.[" + $StagingTable.Replace(']', ']]') + "]"
    $stagingRows = Invoke-XFActsQuery -Query "SELECT * FROM $safeTable WHERE _skip = 0 ORDER BY _row_number"

    $rowCount = if ($stagingRows) { $stagingRows.Count } else { 0 }
    if ($rowCount -eq 0) {
        return @{ Error = 'No rows to export (all rows may be skipped)'; StatusCode = 400 }
    }

    # Get skipped count
    $skipResult = Invoke-XFActsQuery -Query "SELECT COUNT(*) AS cnt FROM $safeTable WHERE _skip = 1"
    $skippedCount = if ($skipResult -and $skipResult.Count -gt 0) { $skipResult[0].cnt } else { 0 }

    # Identify mapped columns (exclude system columns and unmapped columns)
    $mappedColumns = @($stagingRows[0].Keys | Where-Object {
        $_ -ne '_row_number' -and $_ -ne '_skip' -and $_ -ne '_nullify_fields' -and
        $_ -ne '_trigger_value' -and $_ -ne '_assignment_index' -and $_ -notlike '*_unmapped'
    })

    # Build filename
    $username = $WebEvent.Auth.User.Username
    if ($username -and $username.Contains('\')) { $username = $username.Split('\')[1] }
    $timestamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
    $xmlFilename = "xFACts_${EntityType}_${username}_${timestamp}.txt"

    # Build the XML
    $sb = New-Object System.Text.StringBuilder 8192

    # XML declaration
    [void]$sb.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')

    # Root element
    [void]$sb.AppendLine('<dm_data xmlns="http://www.fico.com/xml/debtmanager/data/v1_0">')

    # Header
    [void]$sb.AppendLine('  <header>')
    [void]$sb.AppendLine("    <import_as_user_name>${username}</import_as_user_name>")
    [void]$sb.AppendLine('    <sender_id_txt>Organization</sender_id_txt>')
    [void]$sb.AppendLine('    <target_id_txt>FAC Debt Manager</target_id_txt>')
    $batchTimestamp = (Get-Date).ToString('yyyyMMddHHmmss')
    [void]$sb.AppendLine("    <batch_id_txt>XF_${batchAbbrev}_${batchTimestamp}</batch_id_txt>")
    [void]$sb.AppendLine('    <communication_reference_id_txt>Organization</communication_reference_id_txt>')
    [void]$sb.AppendLine("    <operational_transaction_type>${operationalTransactionType}</operational_transaction_type>")
    [void]$sb.AppendLine("    <total_count>${rowCount}</total_count>")
    $creationDate = (Get-Date).ToString('yyyy-MM-dd') + 'T' + (Get-Date).ToString('HH:mm') + ':00'
    [void]$sb.AppendLine("    <creation_data>${creationDate}</creation_data>")
    [void]$sb.AppendLine('    <custom_properties>')
    [void]$sb.AppendLine('      <custom_property/>')
    [void]$sb.AppendLine('    </custom_properties>')
    [void]$sb.AppendLine('  </header>')

    # Operational transaction data
    [void]$sb.AppendLine('  <operational_transaction_data>')
    [void]$sb.AppendLine("    <${wrapperElement}>")

    # Entity rows
    $seq = 1
    foreach ($row in $stagingRows) {
        [void]$sb.AppendLine("      <${entityElement} seq_no=`"${seq}`" type=`"${EntityType}`">")

        # Collect record-level nullify fields (empty mapped columns)
        $allNullifyFields = @()

        # Blanket nullify fields (from UI badge via _nullify_fields column)
        if ($row.ContainsKey('_nullify_fields')) {
            $nfVal = $row['_nullify_fields']
            if ($nfVal -and $nfVal -isnot [System.DBNull] -and ([string]$nfVal).Trim() -ne '') {
                $allNullifyFields = @(([string]$nfVal) -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
            }
        }

        # Record-level nullify: empty values in mapped columns -> nullify
        if ($hasNullifyFields) {
            foreach ($col in $mappedColumns) {
                if ($nonNullifiableSet.ContainsKey($col)) { continue }
                if ($allNullifyFields -contains $col) { continue }
                $val = $row[$col]
                if ($val -is [System.DBNull] -or $null -eq $val -or ([string]$val).Trim() -eq '') {
                    $allNullifyFields += $col
                }
            }
        }

        # Emit nullify block if any fields need nullification
        if ($allNullifyFields.Count -gt 0) {
            [void]$sb.AppendLine("        <nullify_fields>")
            foreach ($nf in $allNullifyFields) {
                [void]$sb.AppendLine("          <nullify_field>${nf}</nullify_field>")
            }
            [void]$sb.AppendLine("        </nullify_fields>")
        }

        # Data elements
        foreach ($col in $mappedColumns) {
            $val = $row[$col]
            if ($val -is [System.DBNull] -or $null -eq $val) { continue }
            $valStr = [string]$val
            if ($valStr.Trim() -eq '') { continue }

            # XML-escape the value
            $valStr = $valStr.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;').Replace("'", '&apos;')

            # Boolean normalization: DM only accepts 'true' or 'false' in XML
            if ($booleanFields.ContainsKey($col)) {
                $valStr = if ($valStr -in @('Y','y','yes','Yes','YES','1','true','True','TRUE')) { 'true' } else { 'false' }
            }

            [void]$sb.AppendLine("        <${col}>${valStr}</${col}>")
        }

        [void]$sb.AppendLine("      </${entityElement}>")
        $seq++
    }

    # Close wrapper and root
    [void]$sb.AppendLine("    </${wrapperElement}>")
    [void]$sb.AppendLine('  </operational_transaction_data>')
    [void]$sb.AppendLine('</dm_data>')

    return @{
        Xml          = $sb.ToString()
        Filename     = $xmlFilename
        RowCount     = $rowCount
        SkippedCount = $skippedCount
        Environment  = $environment
        Error        = $null
    }
}

function ConvertTo-ARLogXml {
    [CmdletBinding()]
    param(
        [string]$StagingTable,
        [string]$EntityType,
        [string]$JiraTicket,
        [string]$ArMessage,
        [string]$IdentifierElement,
        $WebEvent
    )

    <#
    .SYNOPSIS
        Builds a CONSUMER_ACCOUNT_AR_LOG BDL XML payload from a staging table.

    .DESCRIPTION
        Reads identifier values from the named staging table and emits a
        CONSUMER_ACCOUNT_AR_LOG BDL XML payload that creates one AR log entry
        per non-skipped row, with the supplied AR message and Jira ticket
        reference. Mirrors the CC/CC action-and-result-code AR Event pattern
        used by the existing VBA tooling. Called optionally from the BDL
        execute endpoint when a Jira ticket is supplied alongside the main
        import payload.

    .PARAMETER StagingTable
        The Staging-schema table name containing the rows.

    .PARAMETER EntityType
        The originating BDL entity type, included in the AR message text.

    .PARAMETER JiraTicket
        The Jira ticket reference used as the batch ID and embedded in the AR message.

    .PARAMETER ArMessage
        Optional AR message override. When empty a default message is generated from the Jira ticket and entity type.

    .PARAMETER IdentifierElement
        The identifier column / element name written into each AR log entry.

    .PARAMETER WebEvent
        The Pode $WebEvent, used to stamp the requesting user identity on the XML.
    #>

    # Validate staging table exists
    $tableCheck = Invoke-XFActsQuery -Query @"
        SELECT 1 FROM sys.tables t
        INNER JOIN sys.schemas s ON s.schema_id = t.schema_id
        WHERE s.name = 'Staging' AND t.name = @tableName
"@ -Parameters @{ tableName = $StagingTable }

    if (-not $tableCheck -or $tableCheck.Count -eq 0) {
        return @{ Error = "Staging table not found: $StagingTable"; StatusCode = 404 }
    }

    # -- Read staging data (non-skipped rows, identifier column only) -
    $safeTable = "Staging.[" + $StagingTable.Replace(']', ']]') + "]"
    $safeIdCol = "[" + $IdentifierElement.Replace(']', ']]') + "]"

    $stagingRows = Invoke-XFActsQuery -Query "SELECT $safeIdCol FROM $safeTable WHERE _skip = 0 ORDER BY _row_number"

    $rowCount = if ($stagingRows) { $stagingRows.Count } else { 0 }
    if ($rowCount -eq 0) {
        return @{ Error = 'No rows for AR log (all rows may be skipped)'; StatusCode = 400 }
    }

    # Build filename
    $username = $WebEvent.Auth.User.Username
    if ($username -and $username.Contains('\')) { $username = $username.Split('\')[1] }
    $timestamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
    $xmlFilename = "xFACts_${EntityType}_AR_${username}_${timestamp}.txt"

    # Default message if not provided
    if (-not $ArMessage) {
        $ArMessage = "${JiraTicket}: ${EntityType} update via BDL Import"
    }

    # Build the XML
    $sb = New-Object System.Text.StringBuilder 4096

    [void]$sb.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
    [void]$sb.AppendLine('<dm_data xmlns="http://www.fico.com/xml/debtmanager/data/v1_0">')
    [void]$sb.AppendLine('  <header>')
    [void]$sb.AppendLine("    <import_as_user_name>${username}</import_as_user_name>")
    [void]$sb.AppendLine('    <sender_id_txt>Organization</sender_id_txt>')
    [void]$sb.AppendLine('    <target_id_txt>FAC Debt Manager</target_id_txt>')
    [void]$sb.AppendLine("    <batch_id_txt>${JiraTicket}</batch_id_txt>")
    [void]$sb.AppendLine('    <operational_transaction_type>CONSUMER_ACCOUNT_AR_LOG</operational_transaction_type>')
    [void]$sb.AppendLine("    <total_count>${rowCount}</total_count>")
    $creationDate = (Get-Date).ToString('yyyy-MM-dd') + 'T' + (Get-Date).ToString('HH:mm') + ':00'
    [void]$sb.AppendLine("    <creation_data>${creationDate}</creation_data>")
    [void]$sb.AppendLine('  </header>')
    [void]$sb.AppendLine('  <operational_transaction_data>')
    [void]$sb.AppendLine('    <cnsmr_accnt_ar_log_operational_transaction_data>')

    # XML-escape the message once
    $escapedMessage = $ArMessage.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;').Replace("'", '&apos;')

    $seq = 1
    foreach ($row in $stagingRows) {
        $idVal = $row[$IdentifierElement]
        if ($idVal -is [System.DBNull] -or $null -eq $idVal) { continue }
        $idStr = [string]$idVal
        if ($idStr.Trim() -eq '') { continue }
        $idStr = $idStr.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')

        [void]$sb.AppendLine("      <cnsmr_accnt_ar_log seq_no=`"${seq}`" type=`"CONSUMER_ACCOUNT_AR_LOG`">")
        [void]$sb.AppendLine("        <${IdentifierElement}>${idStr}</${IdentifierElement}>")
        [void]$sb.AppendLine('        <actn_cd_shrt_val_txt>CC</actn_cd_shrt_val_txt>')
        [void]$sb.AppendLine('        <rslt_cd_shrt_val_txt>CC</rslt_cd_shrt_val_txt>')
        [void]$sb.AppendLine("        <cnsmr_accnt_ar_mssg_txt>${escapedMessage}</cnsmr_accnt_ar_mssg_txt>")
        [void]$sb.AppendLine("        <cnsmr_accnt_ar_log_crt_usr_nm>${username}</cnsmr_accnt_ar_log_crt_usr_nm>")
        [void]$sb.AppendLine('      </cnsmr_accnt_ar_log>')
        $seq++
    }

    [void]$sb.AppendLine('    </cnsmr_accnt_ar_log_operational_transaction_data>')
    [void]$sb.AppendLine('  </operational_transaction_data>')
    [void]$sb.AppendLine('</dm_data>')

    return @{
        Xml      = $sb.ToString()
        Filename = $xmlFilename
        RowCount = $rowCount
        Error    = $null
    }
}

function Invoke-BDLImportLogReconcile {
    [CmdletBinding()]
    param(
        [int[]]$LogIds = $null,
        [int]$MaxRows = 100
    )

    <#
    .SYNOPSIS
        Reconciles non-terminal Tools.BDL_ImportLog rows against DM File_Registry to capture terminal status.

    .DESCRIPTION
        Groups non-terminal BDL_ImportLog rows (is_complete = 0) by
        environment, resolves the target DM database for each environment
        from Tools.EnvironmentConfig, and issues one batched query per
        environment against File_Registry. When DM reports a terminal status
        the helper writes back the terminal status, record counts, and sets
        is_complete = 1. Rows still in non-terminal DM states or not found
        in DM get only their last_polled_dttm refreshed. Cross-environment
        work uses direct Integrated Security connections rather than the
        xFACts AG helpers, which are hardcoded to AVG-PROD-LSNR. Called
        on-demand from /api/bdl-import/history.

    .PARAMETER LogIds
        Optional array of specific log_id values to reconcile. When omitted, reconciles every row where is_complete = 0 AND file_registry_id IS NOT NULL.

    .PARAMETER MaxRows
        Safety cap on rows reconciled per invocation. Defaults to 100.
    #>

    $result = @{
        success      = $true
        reconciled   = 0
        not_found    = 0
        still_active = 0
        errors       = @()
        environments = @{}
    }

    # Build eligible rows query
    $filter = "WHERE is_complete = 0 AND file_registry_id IS NOT NULL"
    if ($LogIds -and $LogIds.Count -gt 0) {
        # Safe inline -- values are integers from caller, cast to [int] defensively
        $idList = ($LogIds | ForEach-Object { [int]$_ }) -join ','
        $filter += " AND log_id IN ($idList)"
    }

    $eligibleQuery = "SELECT TOP $MaxRows log_id, environment, file_registry_id FROM Tools.BDL_ImportLog $filter ORDER BY log_id DESC"
    $eligibleRows = Invoke-XFActsQuery -Query $eligibleQuery

    if (-not $eligibleRows -or $eligibleRows.Count -eq 0) {
        return $result
    }

    # Group by environment
    $byEnv = @{}
    foreach ($row in $eligibleRows) {
        $env = $row.environment
        if (-not $byEnv.ContainsKey($env)) { $byEnv[$env] = @() }
        $byEnv[$env] += $row
    }

    # Process each environment
    foreach ($env in $byEnv.Keys) {
        $envRows = $byEnv[$env]
        $envMetrics = @{
            queried      = $envRows.Count
            reconciled   = 0
            not_found    = 0
            still_active = 0
        }

        try {
            # Resolve db_instance for this environment
            $envConfig = Invoke-XFActsQuery -Query @"
                SELECT db_instance FROM Tools.EnvironmentConfig
                WHERE environment = @env AND is_active = 1
"@ -Parameters @{ env = $env }

            if (-not $envConfig -or $envConfig.Count -eq 0 -or [string]::IsNullOrEmpty($envConfig[0].db_instance)) {
                $result.errors += "[$env] No db_instance configured in Tools.EnvironmentConfig"
                $result.environments[$env] = $envMetrics
                continue
            }
            $dbInstance = $envConfig[0].db_instance

            # Build comma-separated file_registry_id list (safe -- all integers from our own table)
            $fileRegIds = ($envRows | ForEach-Object { [int]$_.file_registry_id }) -join ','

            # DM query: File_Registry + file_rgstry_dtl + custom details in one shot
            $dmQuery = @"
;WITH CustomDetails AS (
    SELECT
        d.file_registry_id,
        MAX(CASE WHEN cd.file_rgstry_cstm_dtl_nm = 'Dm_staging_success_count'  THEN cd.file_rgstry_cstm_dtl_val_txt END) AS staging_success,
        MAX(CASE WHEN cd.file_rgstry_cstm_dtl_nm = 'Dm_staging_failed_count'   THEN cd.file_rgstry_cstm_dtl_val_txt END) AS staging_failed,
        MAX(CASE WHEN cd.file_rgstry_cstm_dtl_nm = 'Dm_import_processed_count' THEN cd.file_rgstry_cstm_dtl_val_txt END) AS import_processed,
        MAX(CASE WHEN cd.file_rgstry_cstm_dtl_nm = 'Dm_import_success_count'   THEN cd.file_rgstry_cstm_dtl_val_txt END) AS import_success,
        MAX(CASE WHEN cd.file_rgstry_cstm_dtl_nm = 'Dm_import_failed_count'    THEN cd.file_rgstry_cstm_dtl_val_txt END) AS import_failed
    FROM dbo.file_rgstry_cstm_dtl cd
    INNER JOIN dbo.file_rgstry_dtl d ON cd.file_rgstry_dtl_id = d.file_rgstry_dtl_id
    WHERE d.file_registry_id IN ($fileRegIds)
    GROUP BY d.file_registry_id
)
SELECT
    fr.File_registry_id                   AS file_registry_id,
    fr.file_stts_cd                       AS file_registry_status_code,
    fr.upsrt_dttm                         AS file_registry_upsrt_dttm,
    fr.file_err_msg_txt                   AS file_err_msg_txt,
    frd.file_rgstry_dtl_rec_ttl_cnt       AS total_record_count,
    cd.staging_success,
    cd.staging_failed,
    cd.import_processed,
    cd.import_success,
    cd.import_failed
FROM dbo.File_Registry fr
LEFT JOIN dbo.file_rgstry_dtl frd ON fr.File_registry_id = frd.file_registry_id
LEFT JOIN CustomDetails cd        ON fr.File_registry_id = cd.file_registry_id
WHERE fr.File_registry_id IN ($fileRegIds)
"@

            # Execute DM query using cross-environment direct connection
            $connString = "Server=$dbInstance;Database=crs5_oltp;Integrated Security=True;Application Name=xFACts BDL-Reconcile;"
            $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
            $dmResults = @{}

            try {
                $conn.Open()
                $cmd = $conn.CreateCommand()
                $cmd.CommandText = $dmQuery
                $cmd.CommandTimeout = 30

                $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
                $dataset = New-Object System.Data.DataSet
                $adapter.Fill($dataset) | Out-Null

                if ($dataset.Tables.Count -gt 0) {
                    foreach ($dmRow in $dataset.Tables[0].Rows) {
                        $dmResults[[int]$dmRow['file_registry_id']] = $dmRow
                    }
                }
            }
            finally {
                if ($conn.State -eq 'Open') { $conn.Close() }
            }

            # Write back per row
            foreach ($envRow in $envRows) {
                $fileRegId = [int]$envRow.file_registry_id
                $logId = [int]$envRow.log_id

                # Not found in DM -- just update last_polled_dttm
                if (-not $dmResults.ContainsKey($fileRegId)) {
                    Invoke-XFActsNonQuery -Query "UPDATE Tools.BDL_ImportLog SET last_polled_dttm = GETDATE() WHERE log_id = @logId" -Parameters @{ logId = $logId } | Out-Null
                    $envMetrics.not_found++
                    $result.not_found++
                    continue
                }

                $dm = $dmResults[$fileRegId]
                $sttsCode = [int]$dm['file_registry_status_code']

                # Non-terminal DM state (1-4, 9-11) -- just update last_polled_dttm
                if ($sttsCode -notin @(5, 6, 7, 8)) {
                    Invoke-XFActsNonQuery -Query "UPDATE Tools.BDL_ImportLog SET last_polled_dttm = GETDATE() WHERE log_id = @logId" -Parameters @{ logId = $logId } | Out-Null
                    $envMetrics.still_active++
                    $result.still_active++
                    continue
                }

                # Terminal state -- map and write back full state
                $fileRegStatus = switch ($sttsCode) {
                    5 { 'PROCESSED' }
                    6 { 'FAILED' }
                    7 { 'CANCELED' }
                    8 { 'PARTIALLY_PROCESSED' }
                }
                $newStatus = if ($sttsCode -in @(5, 8)) { 'COMPLETED' } else { 'FAILED' }

                # Safe extraction for nullable integer columns
                $intOrNull = {
                    param($val)
                    if ($val -is [DBNull] -or $null -eq $val) { return [DBNull]::Value }
                    try { return [int]$val } catch { return [DBNull]::Value }
                }

                $completedDttm = if ($dm['file_registry_upsrt_dttm'] -is [DBNull]) { [DBNull]::Value } else { $dm['file_registry_upsrt_dttm'] }
                $errMsg = if ($newStatus -eq 'FAILED' -and $dm['file_err_msg_txt'] -isnot [DBNull]) { [string]$dm['file_err_msg_txt'] } else { [DBNull]::Value }

                Invoke-XFActsNonQuery -Query @"
UPDATE Tools.BDL_ImportLog
SET status                      = @status,
    file_registry_status_code   = @fileRegStatusCode,
    file_registry_status        = @fileRegStatus,
    total_record_count          = @totalRec,
    staging_success_count       = @stgSuccess,
    staging_failed_count        = @stgFailed,
    import_processed_count      = @impProcessed,
    import_success_count        = @impSuccess,
    import_failed_count         = @impFailed,
    is_complete                 = 1,
    completed_dttm              = @completedDttm,
    error_message               = COALESCE(error_message, @errMsg),
    last_polled_dttm            = GETDATE()
WHERE log_id = @logId
"@ -Parameters @{
                    logId             = $logId
                    status            = $newStatus
                    fileRegStatusCode = $sttsCode
                    fileRegStatus     = $fileRegStatus
                    totalRec          = & $intOrNull $dm['total_record_count']
                    stgSuccess        = & $intOrNull $dm['staging_success']
                    stgFailed         = & $intOrNull $dm['staging_failed']
                    impProcessed      = & $intOrNull $dm['import_processed']
                    impSuccess        = & $intOrNull $dm['import_success']
                    impFailed         = & $intOrNull $dm['import_failed']
                    completedDttm     = $completedDttm
                    errMsg            = $errMsg
                } | Out-Null

                $envMetrics.reconciled++
                $result.reconciled++
            }
        }
        catch {
            $result.errors += "[$env] $($_.Exception.Message)"
            $result.success = $false
        }

        $result.environments[$env] = $envMetrics
    }

    return $result
}

<# ============================================================================
   FUNCTIONS: TOOLS SERVER TARGETING
   ----------------------------------------------------------------------------
   Resolves the set of DM Tools-enabled servers for a target environment.
   Drives both single-server operations (primary only) and all-server
   operations (Drools refresh and similar).
   Prefix: (none)
   ============================================================================ #>

function Get-ToolsServers {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Environment,

        [switch]$PrimaryOnly
    )

    <#
    .SYNOPSIS
        Returns the set of DM Tools-enabled servers for a target environment.

    .DESCRIPTION
        Queries dbo.ServerRegistry for servers that have the tools_enabled
        flag set in the requested environment and that carry an api_base_url.
        When PrimaryOnly is set, returns only the is_api_primary server for
        single-server operations (such as job triggers). Without the switch
        returns every API-eligible server, ordered by name, for all-server
        operations (such as Drools rule refreshes).

    .PARAMETER Environment
        The target environment (PROD, TEST, etc.) to filter the server list by.

    .PARAMETER PrimaryOnly
        Switch that restricts the result to the single is_api_primary server.
    #>

    if ($PrimaryOnly) {
        $servers = Invoke-XFActsQuery -Query @"
            SELECT server_name, api_base_url, environment
            FROM dbo.ServerRegistry
            WHERE environment = @env
              AND is_api_primary = 1
              AND tools_enabled = 1
"@ -Parameters @{ env = $Environment }
    }
    else {
        $servers = Invoke-XFActsQuery -Query @"
            SELECT server_name, api_base_url, environment
            FROM dbo.ServerRegistry
            WHERE environment = @env
              AND api_base_url IS NOT NULL
              AND tools_enabled = 1
            ORDER BY server_name
"@ -Parameters @{ env = $Environment }
    }

    if (-not $servers -or $servers.Count -eq 0) {
        return @()
    }

    return @($servers)
}

<# ============================================================================
   EXPORTS: MODULE EXPORTS
   ----------------------------------------------------------------------------
   Enumerated list of every public function exported by this module. The list
   is alphabetical to make additions and audits straightforward.
   Prefix: (none)
   ============================================================================ #>

Export-ModuleMember -Function @(
    'Confirm-RBACCache',
    'ConvertFrom-DBNull',
    'ConvertTo-ARLogXml',
    'ConvertTo-BDLXml',
    'ConvertTo-SafeDate',
    'ConvertTo-SafeDateTime',
    'ConvertTo-SafeDecimal',
    'ConvertTo-SafeValue',
    'Get-AccessDeniedHtml',
    'Get-ActionDeniedResponse',
    'Get-CRS5Connection',
    'Get-CachedResult',
    'Get-ChromeBannersHtml',
    'Get-HomePageSections',
    'Get-NavBarHtml',
    'Get-NavRegistryEntry',
    'Get-PageBrowserTitle',
    'Get-PageHeaderHtml',
    'Get-PageScriptTagHtml',
    'Get-RedactionEvent',
    'Get-RemainingCounts',
    'Get-ServiceCredentials',
    'Get-TierLevel',
    'Get-ToolsServers',
    'Get-UserAccess',
    'Get-UserContext',
    'Get-UserPageTier',
    'Initialize-ApiCacheConfig',
    'Initialize-RBACCache',
    'Invoke-AGReadQuery',
    'Invoke-BDLImportLogReconcile',
    'Invoke-CRS5ReadQuery',
    'Invoke-CRS5WriteQuery',
    'Invoke-ProfanityRedaction',
    'Invoke-XFActsNonQuery',
    'Invoke-XFActsProc',
    'Invoke-XFActsQuery',
    'Resolve-UserRoles',
    'Test-ActionEndpoint',
    'Test-ActionPermission',
    'Test-TierSufficient',
    'Write-RBACAuditLog'
)
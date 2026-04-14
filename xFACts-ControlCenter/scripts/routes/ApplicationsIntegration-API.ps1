# ============================================================================
# xFACts Control Center - Applications & Integration API
# Location: E:\xFACts-ControlCenter\scripts\routes\ApplicationsIntegration-API.ps1
# 
# API endpoints for the Applications & Integration departmental page.
# Components:
#   - BDL Catalog Management: Admin-only CRUD for Catalog_BDLFormatRegistry
#     and Catalog_BDLElementRegistry
#   - BDL Department Access: Admin-only department-scoped entity and field
#     access management via Tools.AccessConfig and Tools.AccessFieldConfig
#   - DM Job Triggers: Environment-scoped DM scheduled job execution
#     via ServerRegistry API targeting and ActionAuditLog audit trail
#
# Route: /departmental/applications-integration
# CSS:   /css/applications-integration.css
# JS:    /js/applications-integration.js
#
# Version: Tracked in dbo.System_Metadata (component: DeptOps.ApplicationsIntegration)
#
# CHANGELOG
# ---------
# 2026-04-13  Added cooldown-check, release-notices, balance-sync endpoints
#             Added dm_response to refresh-drools success response
#             Wired ActionAuditLog into BDL catalog management endpoints
#             Added dm-servers and refresh-drools endpoints for DM job triggers
# ============================================================================

# ============================================================================
# GET /api/apps-int/bdl-formats
# Returns all BDL format registry entries with element counts.
# Admin-only.
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/apps-int/bdl-formats' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/departmental/applications-integration'
        if (-not $access.HasAccess) {
            Write-PodeJsonResponse -Value @{ Error = "Access denied" } -StatusCode 403
            return
        }
        $ctx = Get-UserContext -WebEvent $WebEvent
        if (-not $ctx.IsAdmin) {
            Write-PodeJsonResponse -Value @{ Error = "Admin access required" } -StatusCode 403
            return
        }

        $results = Invoke-XFActsQuery -Query @"
            SELECT f.format_id, f.entity_type, f.type_name, f.folder, f.element_count,
                   f.has_nullify_fields, f.is_active, f.action_type,
                   (SELECT COUNT(*) FROM Tools.Catalog_BDLElementRegistry e WHERE e.format_id = f.format_id) AS actual_element_count,
                   (SELECT COUNT(*) FROM Tools.Catalog_BDLElementRegistry e WHERE e.format_id = f.format_id AND e.is_visible = 1) AS visible_count,
                   (SELECT COUNT(*) FROM Tools.Catalog_BDLElementRegistry e WHERE e.format_id = f.format_id AND e.is_import_required = 1) AS required_count
            FROM Tools.Catalog_BDLFormatRegistry f
            ORDER BY f.is_active DESC, f.entity_type
"@

        Write-PodeJsonResponse -Value @($results)
    }
    catch {
        Write-PodeJsonResponse -Value @{ Error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# GET /api/apps-int/bdl-elements?format_id=X
# Returns all elements for a given format, ordered by sort_order.
# Admin-only.
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/apps-int/bdl-elements' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/departmental/applications-integration'
        if (-not $access.HasAccess) {
            Write-PodeJsonResponse -Value @{ Error = "Access denied" } -StatusCode 403
            return
        }
        $ctx = Get-UserContext -WebEvent $WebEvent
        if (-not $ctx.IsAdmin) {
            Write-PodeJsonResponse -Value @{ Error = "Admin access required" } -StatusCode 403
            return
        }

        $formatId = $WebEvent.Query['format_id']
        if (-not $formatId) {
            Write-PodeJsonResponse -Value @{ Error = "format_id required" } -StatusCode 400
            return
        }

        $results = Invoke-XFActsQuery -Query @"
            SELECT e.element_id, e.format_id, e.element_name, e.display_name,
                   e.data_type, e.max_length, e.is_required, e.sort_order,
                   e.table_column, e.lookup_table,
                   e.is_not_nullifiable, e.is_primary_id, e.is_visible,
                   e.is_import_required, e.field_description, e.import_guidance
            FROM Tools.Catalog_BDLElementRegistry e
            WHERE e.format_id = @formatId
            ORDER BY e.sort_order, e.element_name
"@ -Parameters @{ formatId = $formatId }

        Write-PodeJsonResponse -Value @($results)
    }
    catch {
        Write-PodeJsonResponse -Value @{ Error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# POST /api/apps-int/bdl-elements/update
# Updates a single field on a single element row.
# Body: { element_id, field_name, new_value }
# Allowed fields: display_name, is_visible, is_import_required, field_description
# Admin-only.
# ============================================================================
Add-PodeRoute -Method Post -Path '/api/apps-int/bdl-elements/update' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/departmental/applications-integration'
        if (-not $access.HasAccess) {
            Write-PodeJsonResponse -Value @{ Error = "Access denied" } -StatusCode 403
            return
        }
        $ctx = Get-UserContext -WebEvent $WebEvent
        if (-not $ctx.IsAdmin) {
            Write-PodeJsonResponse -Value @{ Error = "Admin access required" } -StatusCode 403
            return
        }

        $body = $WebEvent.Data
        $elementId = $body.element_id
        $fieldName = $body.field_name
        $newValue  = $body.new_value

        if (-not $elementId -or -not $fieldName) {
            Write-PodeJsonResponse -Value @{ Error = "element_id and field_name required" } -StatusCode 400
            return
        }

        $allowedFields = @('display_name', 'is_visible', 'is_import_required', 'field_description', 'import_guidance')
        if ($fieldName -notin $allowedFields) {
            Write-PodeJsonResponse -Value @{ Error = "Field '$fieldName' is not editable" } -StatusCode 400
            return
        }

        $bitFields = @('is_visible', 'is_import_required')

        if ($fieldName -in $bitFields) {
            Invoke-XFActsNonQuery -Query @"
                UPDATE Tools.Catalog_BDLElementRegistry 
                SET [$fieldName] = @newValue 
                WHERE element_id = @elementId
"@ -Parameters @{ elementId = $elementId; newValue = [int]$newValue }
        }
        else {
            $paramValue = if ([string]::IsNullOrWhiteSpace($newValue)) { [DBNull]::Value } else { $newValue }
            Invoke-XFActsNonQuery -Query @"
                UPDATE Tools.Catalog_BDLElementRegistry 
                SET [$fieldName] = @newValue 
                WHERE element_id = @elementId
"@ -Parameters @{ elementId = $elementId; newValue = $paramValue }
        }

        $user = "FAC\$($WebEvent.Auth.User.Username)"

        # ── ActionAuditLog ──────────────────────────────────────────
        try {
            Invoke-XFActsNonQuery -Query @"
                INSERT INTO dbo.ActionAuditLog 
                    (page_route, action_type, action_summary, result, executed_by)
                VALUES 
                    ('/apps-int', 'CONFIG_CHANGE', @summary, 'SUCCESS', @executedBy)
"@ -Parameters @{
                summary    = "Updated $fieldName on element $elementId to: $newValue"
                executedBy = $user
            }
        } catch { }

        Write-PodeJsonResponse -Value @{ 
            message    = "Updated $fieldName on element $elementId"
            element_id = $elementId
            field_name = $fieldName
            new_value  = $newValue
        }
    }
    catch {
        Write-PodeJsonResponse -Value @{ Error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# POST /api/apps-int/bdl-format/toggle
# Toggles is_active on a format registry entry.
# Body: { format_id, is_active }
# Admin-only. Requires confirmation on client side.
# ============================================================================
Add-PodeRoute -Method Post -Path '/api/apps-int/bdl-format/toggle' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/departmental/applications-integration'
        if (-not $access.HasAccess) {
            Write-PodeJsonResponse -Value @{ Error = "Access denied" } -StatusCode 403
            return
        }
        $ctx = Get-UserContext -WebEvent $WebEvent
        if (-not $ctx.IsAdmin) {
            Write-PodeJsonResponse -Value @{ Error = "Admin access required" } -StatusCode 403
            return
        }

        $body = $WebEvent.Data
        $formatId = $body.format_id
        $isActive = $body.is_active

        if ($null -eq $formatId) {
            Write-PodeJsonResponse -Value @{ Error = "format_id required" } -StatusCode 400
            return
        }

        Invoke-XFActsNonQuery -Query @"
            UPDATE Tools.Catalog_BDLFormatRegistry 
            SET is_active = @isActive 
            WHERE format_id = @formatId
"@ -Parameters @{ formatId = $formatId; isActive = [int]$isActive }

        $action = if ([int]$isActive -eq 1) { "activated" } else { "deactivated" }

        $user = "FAC\$($WebEvent.Auth.User.Username)"

        # ── ActionAuditLog ──────────────────────────────────────────
        try {
            Invoke-XFActsNonQuery -Query @"
                INSERT INTO dbo.ActionAuditLog 
                    (page_route, action_type, action_summary, result, executed_by)
                VALUES 
                    ('/apps-int', 'CONFIG_CHANGE', @summary, 'SUCCESS', @executedBy)
"@ -Parameters @{
                summary    = "Entity format $formatId $action"
                executedBy = $user
            }
        } catch { }

        Write-PodeJsonResponse -Value @{ 
            message   = "Format $formatId $action"
            format_id = $formatId
            is_active = [bool]([int]$isActive)
        }
    }
    catch {
        Write-PodeJsonResponse -Value @{ Error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# POST /api/apps-int/bdl-format/update
# Updates a single field on a format registry entry.
# Body: { format_id, field_name, new_value }
# Allowed fields: action_type
# Admin-only.
# ============================================================================
Add-PodeRoute -Method Post -Path '/api/apps-int/bdl-format/update' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/departmental/applications-integration'
        if (-not $access.HasAccess) {
            Write-PodeJsonResponse -Value @{ Error = "Access denied" } -StatusCode 403
            return
        }
        $ctx = Get-UserContext -WebEvent $WebEvent
        if (-not $ctx.IsAdmin) {
            Write-PodeJsonResponse -Value @{ Error = "Admin access required" } -StatusCode 403
            return
        }

        $body = $WebEvent.Data
        $formatId = $body.format_id
        $fieldName = $body.field_name
        $newValue  = $body.new_value

        if (-not $formatId -or -not $fieldName) {
            Write-PodeJsonResponse -Value @{ Error = "format_id and field_name required" } -StatusCode 400
            return
        }

        $allowedFields = @('action_type')
        if ($fieldName -notin $allowedFields) {
            Write-PodeJsonResponse -Value @{ Error = "Field '$fieldName' is not editable" } -StatusCode 400
            return
        }

        Invoke-XFActsNonQuery -Query @"
            UPDATE Tools.Catalog_BDLFormatRegistry 
            SET [$fieldName] = @newValue 
            WHERE format_id = @formatId
"@ -Parameters @{ formatId = $formatId; newValue = $newValue }

        $user = "FAC\$($WebEvent.Auth.User.Username)"

        # ── ActionAuditLog ──────────────────────────────────────────
        try {
            Invoke-XFActsNonQuery -Query @"
                INSERT INTO dbo.ActionAuditLog 
                    (page_route, action_type, action_summary, result, executed_by)
                VALUES 
                    ('/apps-int', 'CONFIG_CHANGE', @summary, 'SUCCESS', @executedBy)
"@ -Parameters @{
                summary    = "Updated $fieldName to $newValue on format $formatId"
                executedBy = $user
            }
        } catch { }

        Write-PodeJsonResponse -Value @{ 
            message    = "Updated $fieldName on format $formatId"
            format_id  = $formatId
            field_name = $fieldName
            new_value  = $newValue
        }
    }
    catch {
        Write-PodeJsonResponse -Value @{ Error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# DEPARTMENT ACCESS MANAGEMENT ENDPOINTS
# ============================================================================

# ============================================================================
# GET /api/apps-int/departments
# Returns active departments from RBAC_DepartmentRegistry for the
# department access mode dropdown.
# Admin-only.
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/apps-int/departments' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/departmental/applications-integration'
        if (-not $access.HasAccess) {
            Write-PodeJsonResponse -Value @{ Error = "Access denied" } -StatusCode 403
            return
        }
        $ctx = Get-UserContext -WebEvent $WebEvent
        if (-not $ctx.IsAdmin) {
            Write-PodeJsonResponse -Value @{ Error = "Admin access required" } -StatusCode 403
            return
        }

        $results = Invoke-XFActsQuery -Query @"
            SELECT department_id, department_key, department_name
            FROM dbo.RBAC_DepartmentRegistry
            WHERE is_active = 1
              AND department_key != 'applications-integration'
            ORDER BY department_name
"@

        Write-PodeJsonResponse -Value @($results)
    }
    catch {
        Write-PodeJsonResponse -Value @{ Error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# GET /api/apps-int/bdl-access?department=X
# Returns globally active BDL format list with per-department access status.
# Admin-only.
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/apps-int/bdl-access' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/departmental/applications-integration'
        if (-not $access.HasAccess) {
            Write-PodeJsonResponse -Value @{ Error = "Access denied" } -StatusCode 403
            return
        }
        $ctx = Get-UserContext -WebEvent $WebEvent
        if (-not $ctx.IsAdmin) {
            Write-PodeJsonResponse -Value @{ Error = "Admin access required" } -StatusCode 403
            return
        }

        $department = $WebEvent.Query['department']
        if (-not $department) {
            Write-PodeJsonResponse -Value @{ Error = "department parameter required" } -StatusCode 400
            return
        }

        $results = Invoke-XFActsQuery -Query @"
            SELECT f.format_id, f.entity_type, f.type_name, f.action_type,
                   ac.config_id,
                   CASE WHEN ac.config_id IS NOT NULL AND ac.is_active = 1 THEN 1 ELSE 0 END AS has_access,
                   (SELECT COUNT(*) 
                    FROM Tools.Catalog_BDLElementRegistry e 
                    WHERE e.format_id = f.format_id AND e.is_visible = 1
                   ) AS visible_field_count,
                   (SELECT COUNT(*) 
                    FROM Tools.AccessFieldConfig afc
                    INNER JOIN Tools.Catalog_BDLElementRegistry e2
                        ON e2.element_name = afc.element_name AND e2.format_id = f.format_id
                    WHERE afc.config_id = ac.config_id AND afc.is_active = 1 AND e2.is_visible = 1
                   ) AS granted_field_count
            FROM Tools.Catalog_BDLFormatRegistry f
            LEFT JOIN Tools.AccessConfig ac 
                ON ac.tool_type = 'BDL' 
                AND ac.item_key = f.entity_type 
                AND ac.department_scope = @department
            WHERE f.is_active = 1
            ORDER BY f.entity_type
"@ -Parameters @{ department = $department }

        Write-PodeJsonResponse -Value @($results)
    }
    catch {
        Write-PodeJsonResponse -Value @{ Error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# GET /api/apps-int/bdl-field-access?config_id=X
# Returns globally visible fields with per-field access status.
# Admin-only.
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/apps-int/bdl-field-access' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/departmental/applications-integration'
        if (-not $access.HasAccess) {
            Write-PodeJsonResponse -Value @{ Error = "Access denied" } -StatusCode 403
            return
        }
        $ctx = Get-UserContext -WebEvent $WebEvent
        if (-not $ctx.IsAdmin) {
            Write-PodeJsonResponse -Value @{ Error = "Admin access required" } -StatusCode 403
            return
        }

        $configId = $WebEvent.Query['config_id']
        if (-not $configId) {
            Write-PodeJsonResponse -Value @{ Error = "config_id parameter required" } -StatusCode 400
            return
        }

        $results = Invoke-XFActsQuery -Query @"
            SELECT e.element_id, e.element_name, e.display_name, e.field_description,
                   e.is_primary_id, e.lookup_table, e.is_import_required,
                   afc.field_config_id,
                   CASE WHEN afc.field_config_id IS NOT NULL AND afc.is_active = 1 THEN 1 ELSE 0 END AS is_granted
            FROM Tools.Catalog_BDLElementRegistry e
            INNER JOIN Tools.AccessConfig ac ON ac.config_id = @configId
            INNER JOIN Tools.Catalog_BDLFormatRegistry f 
                ON f.entity_type = ac.item_key AND f.format_id = e.format_id
            LEFT JOIN Tools.AccessFieldConfig afc 
                ON afc.config_id = @configId AND afc.element_name = e.element_name
            WHERE e.is_visible = 1
            ORDER BY e.sort_order, e.element_name
"@ -Parameters @{ configId = $configId }

        Write-PodeJsonResponse -Value @($results)
    }
    catch {
        Write-PodeJsonResponse -Value @{ Error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# POST /api/apps-int/bdl-access/toggle
# Grants or revokes department-level entity access via UPSERT on AccessConfig.
# Body: { entity_type, department, is_active }
# Admin-only.
# ============================================================================
Add-PodeRoute -Method Post -Path '/api/apps-int/bdl-access/toggle' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/departmental/applications-integration'
        if (-not $access.HasAccess) {
            Write-PodeJsonResponse -Value @{ Error = "Access denied" } -StatusCode 403
            return
        }
        $ctx = Get-UserContext -WebEvent $WebEvent
        if (-not $ctx.IsAdmin) {
            Write-PodeJsonResponse -Value @{ Error = "Admin access required" } -StatusCode 403
            return
        }

        $body = $WebEvent.Data
        $entityType = $body.entity_type
        $department = $body.department
        $isActive   = $body.is_active

        if (-not $entityType -or -not $department -or $null -eq $isActive) {
            Write-PodeJsonResponse -Value @{ Error = "entity_type, department, and is_active required" } -StatusCode 400
            return
        }

        $user = "FAC\$($WebEvent.Auth.User.Username)"

        $result = Invoke-XFActsQuery -Query @"
            MERGE Tools.AccessConfig AS tgt
            USING (SELECT @toolType AS tool_type, @itemKey AS item_key, @deptScope AS department_scope) AS src
                ON tgt.tool_type = src.tool_type 
                AND tgt.item_key = src.item_key 
                AND tgt.department_scope = src.department_scope
            WHEN MATCHED THEN
                UPDATE SET is_active = @isActive, modified_dttm = GETDATE(), modified_by = @modifiedBy
            WHEN NOT MATCHED THEN
                INSERT (tool_type, item_key, department_scope, is_active, created_by)
                VALUES (@toolType, @itemKey, @deptScope, @isActive, @modifiedBy)
            OUTPUT inserted.config_id, inserted.is_active;
"@ -Parameters @{
            toolType   = 'BDL'
            itemKey    = $entityType
            deptScope  = $department
            isActive   = [int]$isActive
            modifiedBy = $user
        }

        $configId = if ($result) { $result.config_id } else { $null }
        $action = if ([int]$isActive -eq 1) { "granted" } else { "revoked" }

        # ── ActionAuditLog ──────────────────────────────────────────
        try {
            Invoke-XFActsNonQuery -Query @"
                INSERT INTO dbo.ActionAuditLog 
                    (page_route, action_type, action_summary, result, executed_by)
                VALUES 
                    ('/apps-int', 'ACCESS_CHANGE', @summary, 'SUCCESS', @executedBy)
"@ -Parameters @{
                summary    = "BDL entity access for $entityType $action for $department"
                executedBy = $user
            }
        } catch { }

        Write-PodeJsonResponse -Value @{
            message     = "BDL access for $entityType $action for $department"
            config_id   = $configId
            entity_type = $entityType
            department  = $department
            is_active   = [bool]([int]$isActive)
        }
    }
    catch {
        Write-PodeJsonResponse -Value @{ Error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# POST /api/apps-int/bdl-field-access/toggle
# Grants or revokes field-level access via UPSERT on AccessFieldConfig.
# Body: { config_id, element_name, is_active }
# Admin-only.
# ============================================================================
Add-PodeRoute -Method Post -Path '/api/apps-int/bdl-field-access/toggle' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/departmental/applications-integration'
        if (-not $access.HasAccess) {
            Write-PodeJsonResponse -Value @{ Error = "Access denied" } -StatusCode 403
            return
        }
        $ctx = Get-UserContext -WebEvent $WebEvent
        if (-not $ctx.IsAdmin) {
            Write-PodeJsonResponse -Value @{ Error = "Admin access required" } -StatusCode 403
            return
        }

        $body = $WebEvent.Data
        $configId    = $body.config_id
        $elementName = $body.element_name
        $isActive    = $body.is_active

        if (-not $configId -or -not $elementName -or $null -eq $isActive) {
            Write-PodeJsonResponse -Value @{ Error = "config_id, element_name, and is_active required" } -StatusCode 400
            return
        }

        $user = "FAC\$($WebEvent.Auth.User.Username)"

        $result = Invoke-XFActsQuery -Query @"
            MERGE Tools.AccessFieldConfig AS tgt
            USING (SELECT @configId AS config_id, @elementName AS element_name) AS src
                ON tgt.config_id = src.config_id AND tgt.element_name = src.element_name
            WHEN MATCHED THEN
                UPDATE SET is_active = @isActive, modified_dttm = GETDATE(), modified_by = @modifiedBy
            WHEN NOT MATCHED THEN
                INSERT (config_id, element_name, is_active, created_by)
                VALUES (@configId, @elementName, @isActive, @modifiedBy)
            OUTPUT inserted.field_config_id, inserted.is_active;
"@ -Parameters @{
            configId    = [int]$configId
            elementName = $elementName
            isActive    = [int]$isActive
            modifiedBy  = $user
        }

        $fieldConfigId = if ($result) { $result.field_config_id } else { $null }
        $action = if ([int]$isActive -eq 1) { "granted" } else { "revoked" }

        # ── ActionAuditLog ──────────────────────────────────────────
        try {
            Invoke-XFActsNonQuery -Query @"
                INSERT INTO dbo.ActionAuditLog 
                    (page_route, action_type, action_summary, result, executed_by)
                VALUES 
                    ('/apps-int', 'ACCESS_CHANGE', @summary, 'SUCCESS', @executedBy)
"@ -Parameters @{
                summary    = "Field access for $elementName $action (config_id: $configId)"
                executedBy = $user
            }
        } catch { }

        Write-PodeJsonResponse -Value @{
            message         = "Field access for $elementName $action"
            field_config_id = $fieldConfigId
            config_id       = $configId
            element_name    = $elementName
            is_active       = [bool]([int]$isActive)
        }
    }
    catch {
        Write-PodeJsonResponse -Value @{ Error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# DM JOB TRIGGER ENDPOINTS
# ============================================================================

# ============================================================================
# GET /api/apps-int/dm-servers?environment=X
# Returns tools-enabled DM app servers for a given environment.
# Shared endpoint used by all DM job trigger UIs.
# Uses Get-ToolsServers from xFACts-Helpers.psm1.
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/apps-int/dm-servers' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/departmental/applications-integration'
        if (-not $access.HasAccess) {
            Write-PodeJsonResponse -Value @{ Error = "Access denied" } -StatusCode 403
            return
        }

        $environment = $WebEvent.Query['environment']
        if (-not $environment) {
            Write-PodeJsonResponse -Value @{ Error = "environment parameter required" } -StatusCode 400
            return
        }

        $servers = Get-ToolsServers -Environment $environment

        Write-PodeJsonResponse -Value @{ servers = @($servers); environment = $environment }
    }
    catch {
        Write-PodeJsonResponse -Value @{ Error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# POST /api/apps-int/refresh-drools
# Triggers REFRESH_DROOLS on a single DM app server.
# Called sequentially by the client for each server in the environment.
# Body: { environment, server_name, api_base_url }
# Logs each execution to ActionAuditLog.
# ============================================================================
Add-PodeRoute -Method Post -Path '/api/apps-int/refresh-drools' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/departmental/applications-integration'
        if (-not $access.HasAccess) {
            Write-PodeJsonResponse -Value @{ Error = "Access denied" } -StatusCode 403
            return
        }

        $body = $WebEvent.Data
        $environment = $body.environment
        $serverName  = $body.server_name
        $apiBaseUrl  = $body.api_base_url

        if (-not $environment -or -not $serverName -or -not $apiBaseUrl) {
            Write-PodeJsonResponse -Value @{ Error = "environment, server_name, and api_base_url are required" } -StatusCode 400
            return
        }

        $user = "FAC\$($WebEvent.Auth.User.Username)"

        # ── Get DM API credentials ──────────────────────────────────
        $creds = Get-ServiceCredentials -ServiceName 'DM_REST_API'
        $apiHeaders = @{
            'Authorization' = $creds.AuthHeader
            'Content-Type'  = 'application/vnd.fico.dm.v1+json'
        }

        # ── Call REFRESH_DROOLS ─────────────────────────────────────
        try {
            $response = Invoke-RestMethod -Uri "$apiBaseUrl/scheduledjobs/REFRESH_DROOLS" `
                -Method POST -Headers $apiHeaders -Body '' -ErrorAction Stop

            # ── ActionAuditLog — success ────────────────────────────
            try {
                Invoke-XFActsNonQuery -Query @"
                    INSERT INTO dbo.ActionAuditLog 
                        (page_route, action_type, action_summary, environment, result, executed_by)
                    VALUES 
                        ('/apps-int', 'JOB_TRIGGER', @summary, @environment, 'SUCCESS', @executedBy)
"@ -Parameters @{
                    summary     = "Refresh Drools on $serverName"
                    environment = $environment
                    executedBy  = $user
                }
            } catch { }

            $dmResponseText = if ($response) { 
                try { $response | ConvertTo-Json -Depth 3 -Compress } catch { [string]$response }
            } else { $null }

            Write-PodeJsonResponse -Value @{
                success      = $true
                server_name  = $serverName
                environment  = $environment
                message      = "REFRESH_DROOLS triggered successfully on $serverName"
                dm_response  = $dmResponseText
            }
        }
        catch {
            $errorMsg = $_.Exception.Message

            # ── ActionAuditLog — failure ────────────────────────────
            try {
                Invoke-XFActsNonQuery -Query @"
                    INSERT INTO dbo.ActionAuditLog 
                        (page_route, action_type, action_summary, environment, result, error_detail, executed_by)
                    VALUES 
                        ('/apps-int', 'JOB_TRIGGER', @summary, @environment, 'FAILED', @errorDetail, @executedBy)
"@ -Parameters @{
                    summary     = "Refresh Drools on $serverName"
                    environment = $environment
                    errorDetail = $errorMsg
                    executedBy  = $user
                }
            } catch { }

            Write-PodeJsonResponse -Value @{
                success     = $false
                server_name = $serverName
                environment = $environment
                error       = "REFRESH_DROOLS failed on ${serverName}: $errorMsg"
            } -StatusCode 500
        }
    }
    catch {
        Write-PodeJsonResponse -Value @{ Error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# GET /api/apps-int/cooldown-check?job_name=X&environment=Y
# Checks ActionAuditLog for the most recent successful execution of a job
# in the given environment. Returns last execution time, who ran it, and
# whether the cooldown is still active. Cooldown duration from GlobalConfig.
# Reusable for any throttled DM job trigger.
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/apps-int/cooldown-check' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/departmental/applications-integration'
        if (-not $access.HasAccess) {
            Write-PodeJsonResponse -Value @{ Error = "Access denied" } -StatusCode 403
            return
        }

        $jobName = $WebEvent.Query['job_name']
        $environment = $WebEvent.Query['environment']

        if (-not $jobName -or -not $environment) {
            Write-PodeJsonResponse -Value @{ Error = "job_name and environment are required" } -StatusCode 400
            return
        }

        # Get cooldown setting from GlobalConfig
        $cooldownConfig = Invoke-XFActsQuery -Query @"
            SELECT setting_value
            FROM dbo.GlobalConfig
            WHERE module_name = 'DeptOps'
              AND category = 'ApplicationsIntegration'
              AND setting_name = @settingName
              AND is_active = 1
"@ -Parameters @{ settingName = "cooldown_${jobName}_seconds" }

        $cooldownSeconds = 0
        if ($cooldownConfig -and $cooldownConfig.Count -gt 0) {
            $cooldownSeconds = [int]$cooldownConfig[0].setting_value
        }

        # Find last successful execution
        $lastExec = Invoke-XFActsQuery -Query @"
            SELECT TOP 1 action_summary, environment, executed_by, executed_dttm
            FROM dbo.ActionAuditLog
            WHERE action_type = 'JOB_TRIGGER'
              AND action_summary LIKE @jobPattern
              AND environment = @env
              AND result = 'SUCCESS'
            ORDER BY executed_dttm DESC
"@ -Parameters @{ jobPattern = "%${jobName}%"; env = $environment }

        $isActive = $false
        $secondsRemaining = 0
        $lastExecutedBy = $null
        $lastExecutedDttm = $null

        if ($lastExec -and $lastExec.Count -gt 0) {
            $lastDttm = [DateTime]$lastExec[0].executed_dttm
            $elapsed = ((Get-Date) - $lastDttm).TotalSeconds
            $lastExecutedBy = $lastExec[0].executed_by
            $lastExecutedDttm = $lastDttm.ToString('yyyy-MM-dd HH:mm:ss')

            if ($elapsed -lt $cooldownSeconds) {
                $isActive = $true
                $secondsRemaining = [Math]::Ceiling($cooldownSeconds - $elapsed)
            }
        }

        Write-PodeJsonResponse -Value @{
            job_name          = $jobName
            environment       = $environment
            cooldown_seconds  = $cooldownSeconds
            cooldown_active   = $isActive
            seconds_remaining = $secondsRemaining
            last_executed_by  = $lastExecutedBy
            last_executed_at  = $lastExecutedDttm
        }
    }
    catch {
        Write-PodeJsonResponse -Value @{ Error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# POST /api/apps-int/release-notices
# Triggers RELEASE_DOC_REQUESTS on the primary DM app server for a given
# environment. Single-server operation with cooldown enforcement.
# Body: { environment }
# ============================================================================
Add-PodeRoute -Method Post -Path '/api/apps-int/release-notices' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/departmental/applications-integration'
        if (-not $access.HasAccess) {
            Write-PodeJsonResponse -Value @{ Error = "Access denied" } -StatusCode 403
            return
        }

        $body = $WebEvent.Data
        $environment = $body.environment

        if (-not $environment) {
            Write-PodeJsonResponse -Value @{ Error = "environment is required" } -StatusCode 400
            return
        }

        $user = "FAC\$($WebEvent.Auth.User.Username)"

        # ── Server-side cooldown enforcement ────────────────────────
        $cooldownConfig = Invoke-XFActsQuery -Query @"
            SELECT setting_value FROM dbo.GlobalConfig
            WHERE module_name = 'DeptOps' AND category = 'ApplicationsIntegration'
              AND setting_name = 'cooldown_release_notices_seconds' AND is_active = 1
"@
        $cooldownSeconds = if ($cooldownConfig -and $cooldownConfig.Count -gt 0) { [int]$cooldownConfig[0].setting_value } else { 300 }

        $lastExec = Invoke-XFActsQuery -Query @"
            SELECT TOP 1 executed_dttm, executed_by FROM dbo.ActionAuditLog
            WHERE action_type = 'JOB_TRIGGER' AND action_summary LIKE '%Release Notices%'
              AND environment = @env AND result = 'SUCCESS'
            ORDER BY executed_dttm DESC
"@ -Parameters @{ env = $environment }

        if ($lastExec -and $lastExec.Count -gt 0) {
            $elapsed = ((Get-Date) - [DateTime]$lastExec[0].executed_dttm).TotalSeconds
            if ($elapsed -lt $cooldownSeconds) {
                $remaining = [Math]::Ceiling($cooldownSeconds - $elapsed)
                Write-PodeJsonResponse -Value @{
                    Error             = "Cooldown active — try again in $remaining seconds"
                    cooldown_active   = $true
                    seconds_remaining = $remaining
                    last_executed_by  = $lastExec[0].executed_by
                } -StatusCode 429
                return
            }
        }

        # ── Get primary server ──────────────────────────────────────
        $servers = Get-ToolsServers -Environment $environment -PrimaryOnly
        if ($servers.Count -eq 0) {
            Write-PodeJsonResponse -Value @{ Error = "No primary API server configured for $environment" } -StatusCode 500
            return
        }

        $serverName = $servers[0].server_name
        $apiBaseUrl = $servers[0].api_base_url

        # ── Get DM API credentials ──────────────────────────────────
        $creds = Get-ServiceCredentials -ServiceName 'DM_REST_API'
        $apiHeaders = @{
            'Authorization' = $creds.AuthHeader
            'Content-Type'  = 'application/vnd.fico.dm.v1+json'
        }

        # ── Call RELEASE_DOC_REQUESTS ───────────────────────────────
        try {
            $response = Invoke-RestMethod -Uri "$apiBaseUrl/scheduledjobs/RELEASE_DOC_REQUESTS" `
                -Method POST -Headers $apiHeaders -Body '' -ErrorAction Stop

            $dmResponseText = if ($response) {
                try { $response | ConvertTo-Json -Depth 3 -Compress } catch { [string]$response }
            } else { $null }

            # ── ActionAuditLog — success ────────────────────────────
            try {
                Invoke-XFActsNonQuery -Query @"
                    INSERT INTO dbo.ActionAuditLog 
                        (page_route, action_type, action_summary, environment, result, executed_by)
                    VALUES 
                        ('/apps-int', 'JOB_TRIGGER', @summary, @environment, 'SUCCESS', @executedBy)
"@ -Parameters @{
                    summary     = "Release Notices on $serverName"
                    environment = $environment
                    executedBy  = $user
                }
            } catch { }

            Write-PodeJsonResponse -Value @{
                success      = $true
                server_name  = $serverName
                environment  = $environment
                message      = "RELEASE_DOC_REQUESTS triggered successfully on $serverName"
                dm_response  = $dmResponseText
            }
        }
        catch {
            $errorMsg = $_.Exception.Message

            # ── ActionAuditLog — failure ────────────────────────────
            try {
                Invoke-XFActsNonQuery -Query @"
                    INSERT INTO dbo.ActionAuditLog 
                        (page_route, action_type, action_summary, environment, result, error_detail, executed_by)
                    VALUES 
                        ('/apps-int', 'JOB_TRIGGER', @summary, @environment, 'FAILED', @errorDetail, @executedBy)
"@ -Parameters @{
                    summary     = "Release Notices on $serverName"
                    environment = $environment
                    errorDetail = $errorMsg
                    executedBy  = $user
                }
            } catch { }

            Write-PodeJsonResponse -Value @{
                success     = $false
                server_name = $serverName
                environment = $environment
                error       = "RELEASE_DOC_REQUESTS failed on ${serverName}: $errorMsg"
            } -StatusCode 500
        }
    }
    catch {
        Write-PodeJsonResponse -Value @{ Error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# POST /api/apps-int/balance-sync
# Triggers UPDATE_BALANCES on the primary DM app server for a given
# environment. Single-server operation with cooldown enforcement.
# Body: { environment }
# ============================================================================
Add-PodeRoute -Method Post -Path '/api/apps-int/balance-sync' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/departmental/applications-integration'
        if (-not $access.HasAccess) {
            Write-PodeJsonResponse -Value @{ Error = "Access denied" } -StatusCode 403
            return
        }

        $body = $WebEvent.Data
        $environment = $body.environment

        if (-not $environment) {
            Write-PodeJsonResponse -Value @{ Error = "environment is required" } -StatusCode 400
            return
        }

        $user = "FAC\$($WebEvent.Auth.User.Username)"

        # ── Server-side cooldown enforcement ────────────────────────
        $cooldownConfig = Invoke-XFActsQuery -Query @"
            SELECT setting_value FROM dbo.GlobalConfig
            WHERE module_name = 'DeptOps' AND category = 'ApplicationsIntegration'
              AND setting_name = 'cooldown_balance_sync_seconds' AND is_active = 1
"@
        $cooldownSeconds = if ($cooldownConfig -and $cooldownConfig.Count -gt 0) { [int]$cooldownConfig[0].setting_value } else { 3600 }

        $lastExec = Invoke-XFActsQuery -Query @"
            SELECT TOP 1 executed_dttm, executed_by FROM dbo.ActionAuditLog
            WHERE action_type = 'JOB_TRIGGER' AND action_summary LIKE '%Balance Sync%'
              AND environment = @env AND result = 'SUCCESS'
            ORDER BY executed_dttm DESC
"@ -Parameters @{ env = $environment }

        if ($lastExec -and $lastExec.Count -gt 0) {
            $elapsed = ((Get-Date) - [DateTime]$lastExec[0].executed_dttm).TotalSeconds
            if ($elapsed -lt $cooldownSeconds) {
                $remaining = [Math]::Ceiling($cooldownSeconds - $elapsed)
                Write-PodeJsonResponse -Value @{
                    Error             = "Cooldown active — try again in $remaining seconds"
                    cooldown_active   = $true
                    seconds_remaining = $remaining
                    last_executed_by  = $lastExec[0].executed_by
                } -StatusCode 429
                return
            }
        }

        # ── Get primary server ──────────────────────────────────────
        $servers = Get-ToolsServers -Environment $environment -PrimaryOnly
        if ($servers.Count -eq 0) {
            Write-PodeJsonResponse -Value @{ Error = "No primary API server configured for $environment" } -StatusCode 500
            return
        }

        $serverName = $servers[0].server_name
        $apiBaseUrl = $servers[0].api_base_url

        # ── Get DM API credentials ──────────────────────────────────
        $creds = Get-ServiceCredentials -ServiceName 'DM_REST_API'
        $apiHeaders = @{
            'Authorization' = $creds.AuthHeader
            'Content-Type'  = 'application/vnd.fico.dm.v1+json'
        }

        # ── Call UPDATE_BALANCES ────────────────────────────────────
        try {
            $response = Invoke-RestMethod -Uri "$apiBaseUrl/scheduledjobs/UPDATE_BALANCES" `
                -Method POST -Headers $apiHeaders -Body '' -ErrorAction Stop

            $dmResponseText = if ($response) {
                try { $response | ConvertTo-Json -Depth 3 -Compress } catch { [string]$response }
            } else { $null }

            # ── ActionAuditLog — success ────────────────────────────
            try {
                Invoke-XFActsNonQuery -Query @"
                    INSERT INTO dbo.ActionAuditLog 
                        (page_route, action_type, action_summary, environment, result, executed_by)
                    VALUES 
                        ('/apps-int', 'JOB_TRIGGER', @summary, @environment, 'SUCCESS', @executedBy)
"@ -Parameters @{
                    summary     = "Balance Sync on $serverName"
                    environment = $environment
                    executedBy  = $user
                }
            } catch { }

            Write-PodeJsonResponse -Value @{
                success      = $true
                server_name  = $serverName
                environment  = $environment
                message      = "UPDATE_BALANCES triggered successfully on $serverName"
                dm_response  = $dmResponseText
            }
        }
        catch {
            $errorMsg = $_.Exception.Message

            # ── ActionAuditLog — failure ────────────────────────────
            try {
                Invoke-XFActsNonQuery -Query @"
                    INSERT INTO dbo.ActionAuditLog 
                        (page_route, action_type, action_summary, environment, result, error_detail, executed_by)
                    VALUES 
                        ('/apps-int', 'JOB_TRIGGER', @summary, @environment, 'FAILED', @errorDetail, @executedBy)
"@ -Parameters @{
                    summary     = "Balance Sync on $serverName"
                    environment = $environment
                    errorDetail = $errorMsg
                    executedBy  = $user
                }
            } catch { }

            Write-PodeJsonResponse -Value @{
                success     = $false
                server_name = $serverName
                environment = $environment
                error       = "UPDATE_BALANCES failed on ${serverName}: $errorMsg"
            } -StatusCode 500
        }
    }
    catch {
        Write-PodeJsonResponse -Value @{ Error = $_.Exception.Message } -StatusCode 500
    }
}
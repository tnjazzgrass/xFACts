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
#
# Route: /departmental/applications-integration
# CSS:   /css/applications-integration.css
# JS:    /js/applications-integration.js
#
# Version: Tracked in dbo.System_Metadata (component: DeptOps.ApplicationsIntegration)
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

        # Whitelist of editable fields
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
# Each row includes has_access (bool) and config_id (if granted).
# Also includes granted field count per entity for the stats display.
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
# Returns globally visible fields for the entity tied to a given AccessConfig
# row, with per-field access status (granted/not granted).
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
# UPSERT: if row exists, updates is_active + modified_*; if not, inserts.
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

        # UPSERT via MERGE
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
# UPSERT: if row exists, updates is_active + modified_*; if not, inserts.
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

        # UPSERT via MERGE
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
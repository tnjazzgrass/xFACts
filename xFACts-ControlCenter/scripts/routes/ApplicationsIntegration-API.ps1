# ============================================================================
# xFACts Control Center - Applications & Integration API
# Location: E:\xFACts-ControlCenter\scripts\routes\ApplicationsIntegration-API.ps1
# 
# API endpoints for the Applications & Integration departmental page.
# Components:
#   - BDL Catalog Management: Admin-only CRUD for Catalog_BDLFormatRegistry
#     and Catalog_BDLElementRegistry
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
                   e.is_import_required, e.field_description
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
        $allowedFields = @('display_name', 'is_visible', 'is_import_required', 'field_description')
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
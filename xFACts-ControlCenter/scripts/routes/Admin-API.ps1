# ============================================================================
# xFACts Control Center - Administration API Endpoints
# Location: E:\xFACts-ControlCenter\scripts\routes\Admin-API.ps1
# Version: See Admin.ps1 for current version
# ============================================================================

# ============================================================================
# API: Process Status with daily aggregates
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/admin/process-status' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $results = Invoke-XFActsQuery -Query @"
            SELECT
                p.process_id,
                p.module_name,
                p.process_name,
                p.run_mode,
                p.dependency_group,
                p.interval_seconds,
                p.scheduled_time,
                p.running_count,
                p.last_execution_dttm,
                p.last_execution_status,
                p.last_duration_ms,
                p.last_successful_date,
                p.execution_mode,
                p.timeout_seconds,
                ISNULL(agg.daily_success, 0) AS daily_success,
                ISNULL(agg.daily_launched, 0) AS daily_launched,
                ISNULL(agg.daily_failed, 0) AS daily_failed,
                CASE
                    WHEN p.run_mode = 0 THEN NULL
                    WHEN p.run_mode = 2 THEN NULL
                    WHEN p.run_mode = 1 AND p.scheduled_time IS NOT NULL THEN
                        CASE
                            WHEN p.last_successful_date = CAST(GETDATE() AS DATE) THEN
                                DATEDIFF(SECOND, GETDATE(),
                                    DATEADD(DAY, 1, CAST(CAST(GETDATE() AS DATE) AS DATETIME)
                                        + CAST(p.scheduled_time AS DATETIME)))
                            ELSE
                                DATEDIFF(SECOND, GETDATE(),
                                    CAST(CAST(GETDATE() AS DATE) AS DATETIME)
                                        + CAST(p.scheduled_time AS DATETIME))
                        END
                    WHEN p.run_mode = 1 AND p.last_execution_dttm IS NOT NULL THEN
                        p.interval_seconds - DATEDIFF(SECOND, p.last_execution_dttm, GETDATE())
                    WHEN p.run_mode = 1 AND p.last_execution_dttm IS NULL THEN -1
                    ELSE NULL
                END AS seconds_until_next
            FROM Orchestrator.ProcessRegistry p
            OUTER APPLY (
                SELECT
                    SUM(CASE WHEN t.task_status = 'SUCCESS' THEN 1 ELSE 0 END) AS daily_success,
                    SUM(CASE WHEN t.task_status IN ('LAUNCHED', 'RUNNING') THEN 1 ELSE 0 END) AS daily_launched,
                    SUM(CASE WHEN t.task_status IN ('FAILED', 'TIMEOUT') THEN 1 ELSE 0 END) AS daily_failed
                FROM Orchestrator.TaskLog t
                WHERE t.process_id = p.process_id
                  AND t.start_dttm >= CAST(GETDATE() AS DATE)
            ) agg
            ORDER BY p.dependency_group, p.process_name
"@
        Write-PodeJsonResponse -Value $results
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ============================================================================
# API: Process History with pagination and status filtering
# Parameters:
#   process_id (required) - ProcessRegistry ID
#   offset (optional, default 0) - pagination offset
#   status_filter (optional) - 'failed','running','success', or omit for all
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/admin/process-history' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $processId = $WebEvent.Query['process_id']
        if (-not $processId) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "process_id required" }) -StatusCode 400
            return
        }

        $offsetRaw = $WebEvent.Query['offset']
        $offset = if ($offsetRaw) { [int]$offsetRaw } else { 0 }
        $limit = 20

        $statusFilter = $WebEvent.Query['status_filter']

        # Build status WHERE clause based on filter
        $statusClause = ""
        switch ($statusFilter) {
            'failed'  { $statusClause = "AND t.task_status IN ('FAILED', 'TIMEOUT')" }
            'running' { $statusClause = "AND t.task_status IN ('RUNNING', 'LAUNCHED')" }
            'success' { $statusClause = "AND t.task_status = 'SUCCESS'" }
            default   { $statusClause = "" }
        }

        $query = @"
            SELECT
                t.task_id, t.task_status, t.start_dttm, t.end_dttm,
                t.duration_ms, t.exit_code,
                t.output_summary, t.error_output
            FROM Orchestrator.TaskLog t
            WHERE t.process_id = @processId
              $statusClause
            ORDER BY t.start_dttm DESC
            OFFSET @offset ROWS FETCH NEXT @limit ROWS ONLY
"@

        $results = Invoke-XFActsQuery -Query $query -Parameters @{
            processId = [int]$processId
            offset = $offset
            limit = $limit
        }

        Write-PodeJsonResponse -Value $results
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ============================================================================
# xFACts Control Center - Administration Timeline API
# Location: E:\xFACts-ControlCenter\scripts\routes\Admin-API.ps1
# Note: Add this endpoint to the EXISTING Admin-API.ps1 file
# ============================================================================

# ============================================================================
# API: Timeline Data — Recent task executions for canvas timeline
# Returns the last N minutes of TaskLog entries with process metadata
# Parameters:
#   window_minutes (optional, default 30) - how many minutes of history
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/admin/timeline-data' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $windowRaw = $WebEvent.Query['window_minutes']
        $windowMinutes = if ($windowRaw) { [int]$windowRaw } else { 30 }

        # Clamp to reasonable range
        if ($windowMinutes -lt 5)  { $windowMinutes = 5 }
        if ($windowMinutes -gt 120) { $windowMinutes = 120 }

        $results = Invoke-XFActsQuery -Query @"
            SELECT
                t.task_id,
                t.process_id,
                p.process_name,
                p.module_name,
                p.dependency_group,
                t.execution_mode,
                t.task_status,
                t.start_dttm,
                t.end_dttm,
                t.duration_ms,
                t.output_summary,
                t.error_output
            FROM Orchestrator.TaskLog t
            INNER JOIN Orchestrator.ProcessRegistry p
                ON t.process_id = p.process_id
            WHERE t.start_dttm >= DATEADD(MINUTE, -@window, GETDATE())
            ORDER BY t.start_dttm DESC
"@ -Parameters @{ window = $windowMinutes }

        Write-PodeJsonResponse -Value $results
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ============================================================================
# API: Toggle Process Run Mode (enable/disable)
# ============================================================================
Add-PodeRoute -Method Post -Path '/api/admin/toggle-process' -Authentication 'ADLogin' -ScriptBlock {
    try {
        if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }

        $processId = $WebEvent.Data.process_id
        $action = $WebEvent.Data.action   # enable or disable
        $user = "FAC\$($WebEvent.Auth.User.Username)"

        if ($action -notin @('enable','disable')) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Invalid action: $action. Must be enable or disable." }) -StatusCode 400
            return
        }

        if ($action -eq 'disable') {
            Invoke-XFActsQuery -Query @"
                UPDATE Orchestrator.ProcessRegistry
                SET run_mode = 0, modified_dttm = GETDATE(), modified_by = @user
                WHERE process_id = @pid
"@ -Parameters @{ pid = [int]$processId; user = $user }
        }
        else {
            # Enable: run_mode = 2 for group 99 (queue processors), 1 for everything else
            Invoke-XFActsQuery -Query @"
                UPDATE Orchestrator.ProcessRegistry
                SET run_mode = CASE WHEN dependency_group = 99 THEN 2 ELSE 1 END,
                    modified_dttm = GETDATE(), modified_by = @user
                WHERE process_id = @pid
"@ -Parameters @{ pid = [int]$processId; user = $user }
        }

        # Return updated state
        $updated = Invoke-XFActsQuery -Query @"
            SELECT process_id, process_name, run_mode, dependency_group
            FROM Orchestrator.ProcessRegistry WHERE process_id = @pid
"@ -Parameters @{ pid = [int]$processId }

        $newMode = if ($updated) { $updated[0].run_mode } else { -1 }

        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            success = $true
            process_id = [int]$processId
            action = $action
            run_mode = $newMode
            performed_by = $user
            message = "Process $action performed by $user"
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}



# ============================================================================
# API: Drain Status (includes Windows service state)
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/admin/drain-status' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $result = Invoke-XFActsQuery -Query @"
            SELECT CAST(setting_value AS INT) AS drain_mode
            FROM dbo.GlobalConfig
            WHERE module_name IN ('Orchestrator', 'dbo', 'Shared')
              AND setting_name = 'orchestrator_drain_mode' AND is_active = 1
"@
        $dm = if ($result -and $result.Count -gt 0) { $result[0].drain_mode } else { 0 }

        $run = Invoke-XFActsQuery -Query @"
            SELECT SUM(running_count) AS total_running,
                   COUNT(CASE WHEN running_count > 0 THEN 1 END) AS procs_running
            FROM Orchestrator.ProcessRegistry WHERE run_mode > 0
"@

        # Check Windows service status
        $svcStatus = 'Unknown'
        try {
            $svc = Get-Service -Name 'xFACtsOrchestrator' -ErrorAction Stop
            $svcStatus = $svc.Status.ToString()   # Running, Stopped, StartPending, StopPending
        } catch {
            $svcStatus = 'NotFound'
        }

        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            drain_mode = $dm
            total_running = if ($run) { $run[0].total_running } else { 0 }
            processes_running = if ($run) { $run[0].procs_running } else { 0 }
            service_status = $svcStatus
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ============================================================================
# API: Toggle Drain
# ============================================================================
Add-PodeRoute -Method Post -Path '/api/admin/drain-mode' -Authentication 'ADLogin' -ScriptBlock {
    try {
        if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }

        $user = "FAC\$($WebEvent.Auth.User.Username)"
        $val = $WebEvent.Data.drain_mode
        if ($val -ne 0 -and $val -ne 1) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Must be 0 or 1" }) -StatusCode 400; return
        }

        # Look up the config_id and current value for change logging
        $drainSetting = Invoke-XFActsQuery -Query @"
            SELECT config_id, module_name, setting_name, setting_value
            FROM dbo.GlobalConfig
            WHERE module_name IN ('Orchestrator','dbo','Shared')
              AND setting_name = 'orchestrator_drain_mode' AND is_active = 1
"@
        $drainRow = if ($drainSetting) { $drainSetting[0] } else { $null }
        $oldDrainVal = if ($drainRow) { $drainRow.setting_value } else { $null }

        Invoke-XFActsQuery -Query @"
            UPDATE dbo.GlobalConfig SET setting_value = @v
            WHERE module_name IN ('Orchestrator','dbo','Shared')
              AND setting_name = 'orchestrator_drain_mode' AND is_active = 1
"@ -Parameters @{ v = [string]$val }

        # Log the change to ActionAuditLog
        if ($drainRow) {
            Invoke-XFActsQuery -Query @"
                INSERT INTO dbo.ActionAuditLog
                    (source_module, entity_type, entity_id, entity_name, field_name, old_value, new_value, changed_by)
                VALUES
                    (@mod, 'GlobalConfig', @cid, @name, 'setting_value', @oldVal, @newVal, @user)
"@ -Parameters @{
                mod    = $drainRow.module_name
                cid    = [int]$drainRow.config_id
                name   = $drainRow.setting_name
                oldVal = if ($oldDrainVal) { $oldDrainVal } else { [DBNull]::Value }
                newVal = [string]$val
                user   = $user
            }
        }

        $act = if ($val -eq 1) { 'ENGAGED' } else { 'DISENGAGED' }
        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            success = $true; drain_mode = $val; action = $act
            performed_by = $user; message = "Drain mode $act by $user"
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ============================================================================
# API: Service Control (Stop / Start / Restart)
# ============================================================================
Add-PodeRoute -Method Post -Path '/api/admin/service-control' -Authentication 'ADLogin' -ScriptBlock {
    try {
        if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }

        $user = "FAC\$($WebEvent.Auth.User.Username)"
        $action = $WebEvent.Data.action   # stop, start, restart

        if ($action -notin @('stop','start','restart')) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Invalid action: $action. Must be stop, start, or restart." }) -StatusCode 400
            return
        }

        $serviceName = 'xFACtsOrchestrator'

        # Safety checks
        $svc = Get-Service -Name $serviceName -ErrorAction Stop

        switch ($action) {
            'stop' {
                if ($svc.Status -ne 'Running') {
                    Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Service is not running (status: $($svc.Status))" }) -StatusCode 409
                    return
                }
                Stop-Service -Name $serviceName -Force
                $svc.WaitForStatus('Stopped', (New-TimeSpan -Seconds 30))
            }
            'start' {
                if ($svc.Status -ne 'Stopped') {
                    Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Service is not stopped (status: $($svc.Status))" }) -StatusCode 409
                    return
                }
                Start-Service -Name $serviceName
                $svc.WaitForStatus('Running', (New-TimeSpan -Seconds 30))
            }
            'restart' {
                if ($svc.Status -ne 'Running') {
                    Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Service is not running (status: $($svc.Status))" }) -StatusCode 409
                    return
                }
                Stop-Service -Name $serviceName -Force
                $svc.WaitForStatus('Stopped', (New-TimeSpan -Seconds 30))
                Start-Service -Name $serviceName
                $svc = Get-Service -Name $serviceName -ErrorAction Stop
                $svc.WaitForStatus('Running', (New-TimeSpan -Seconds 30))
            }
        }

        $svc = Get-Service -Name $serviceName -ErrorAction Stop

        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            success = $true
            action = $action
            service_status = $svc.Status.ToString()
            performed_by = $user
            message = "Service $action performed by $user"
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ============================================================================
# ============================================================================
# SYSTEM METADATA APIs (Rearchitected — Component-Level Versioning)
# ============================================================================
# Data model: Component_Registry → Object_Registry → System_Metadata
# Tree: module → component (from Component_Registry)
# Versions: append-only changelog (System_Metadata), latest = current
# ============================================================================

# ----------------------------------------------------------------------------
# GET /api/admin/metadata/tree
# Returns component tree with current versions for the admin slideout.
# Joins Component_Registry with latest System_Metadata per component.
# Also returns total object count from Object_Registry.
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Get -Path '/api/admin/metadata/tree' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $results = Invoke-XFActsQuery -Query @"
            SELECT
                cr.component_id,
                cr.module_name,
                cr.component_name,
                cr.description AS component_description,
                sm.version,
                sm.description AS version_description,
                sm.deployed_date,
                sm.deployed_by,
                (SELECT COUNT(*) FROM dbo.Object_Registry oreg
                 WHERE oreg.component_name = cr.component_name
                   AND oreg.is_active = 1) AS object_count
            FROM dbo.Component_Registry cr
            LEFT JOIN (
                SELECT component_name, version, description, deployed_date, deployed_by,
                       ROW_NUMBER() OVER (PARTITION BY component_name ORDER BY metadata_id DESC) AS rn
                FROM dbo.System_Metadata
            ) sm ON sm.component_name = cr.component_name AND sm.rn = 1
            WHERE cr.is_active = 1
            ORDER BY cr.module_name, cr.component_name
"@
        # Module descriptions for tree header rows
        $modules = Invoke-XFActsQuery -Query @"
            SELECT module_name, description
            FROM dbo.Module_Registry
            WHERE is_active = 1
            ORDER BY module_name
"@
        # Platform-wide totals for the root row
        $totals = Invoke-XFActsQuery -Query @"
            SELECT
                (SELECT COUNT(*) FROM dbo.Component_Registry WHERE is_active = 1) AS component_count,
                (SELECT COUNT(*) FROM dbo.Object_Registry WHERE is_active = 1) AS object_count,
                (SELECT TOP 1 deployed_date FROM dbo.System_Metadata ORDER BY metadata_id DESC) AS last_activity
"@

        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            components = $results
            modules = $modules
            totals = if ($totals -and $totals.Count -gt 0) { $totals[0] } else { $null }
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ----------------------------------------------------------------------------
# GET /api/admin/metadata/history?component=X
# Returns full version history for a specific component (newest first).
# Append-only table — no status column, just the ordered changelog.
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Get -Path '/api/admin/metadata/history' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $component = $WebEvent.Query['component']

        if (-not $component) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "component is required" }) -StatusCode 400
            return
        }

        $results = Invoke-XFActsQuery -Query @"
            SELECT metadata_id, version, description, deployed_date, deployed_by
            FROM dbo.System_Metadata
            WHERE component_name = @comp
            ORDER BY metadata_id DESC
"@ -Parameters @{ comp = $component }

        Write-PodeJsonResponse -Value $results
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ----------------------------------------------------------------------------
# GET /api/admin/metadata/objects?component=X
# Returns Object_Registry entries for a specific component.
# Used by the object catalog expansion in the admin tree.
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Get -Path '/api/admin/metadata/objects' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $component = $WebEvent.Query['component']

        if (-not $component) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "component is required" }) -StatusCode 400
            return
        }

        $results = Invoke-XFActsQuery -Query @"
            SELECT registry_id, object_name, object_category, object_type, object_path, description
            FROM dbo.Object_Registry
            WHERE component_name = @comp
              AND is_active = 1
            ORDER BY object_category, object_type, object_name
"@ -Parameters @{ comp = $component }

        Write-PodeJsonResponse -Value $results
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ----------------------------------------------------------------------------
# POST /api/admin/metadata/insert
# Insert a new version record into System_Metadata.
# Component must already exist in Component_Registry.
# No trigger needed — table is append-only.
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Post -Path '/api/admin/metadata/insert' -Authentication 'ADLogin' -ScriptBlock {
    try {
        if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }

        $component = $WebEvent.Data.component_name
        $version = $WebEvent.Data.version
        $description = $WebEvent.Data.description

        # Validate required fields
        if (-not $component -or -not $version) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "component_name and version are required" }) -StatusCode 400
            return
        }

        # Validate version format (X.Y.Z)
        if ($version -notmatch '^\d+\.\d+\.\d+$') {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Version must be format X.Y.Z (e.g., 3.0.1)" }) -StatusCode 400
            return
        }

        # Verify component exists in Component_Registry
        $comp = Invoke-XFActsQuery -Query @"
            SELECT component_id, module_name FROM dbo.Component_Registry
            WHERE component_name = @comp AND is_active = 1
"@ -Parameters @{ comp = $component }

        if (-not $comp -or $comp.Count -eq 0) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Component '$component' not found in Component_Registry" }) -StatusCode 404
            return
        }

        $moduleName = $comp[0].module_name

        # Check for duplicate version
        $existing = Invoke-XFActsQuery -Query @"
            SELECT metadata_id FROM dbo.System_Metadata
            WHERE component_name = @comp AND version = @ver
"@ -Parameters @{ comp = $component; ver = $version }

        if ($existing) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Version $version already exists for $component" }) -StatusCode 409
            return
        }

        # Insert version record
        $user = "FAC\$($WebEvent.Auth.User.Username)"
        Invoke-XFActsQuery -Query @"
            INSERT INTO dbo.System_Metadata
                (module_name, component_name, version, description, deployed_by)
            VALUES
                (@mod, @comp, @ver, @desc, @user)
"@ -Parameters @{
            mod = $moduleName; comp = $component
            ver = $version; desc = $description; user = $user
        }

        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            success = $true
            module_name = $moduleName
            component_name = $component
            version = $version
            message = "Version $version inserted for $component"
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ----------------------------------------------------------------------------
# POST /api/admin/metadata/add-component
# Register a new component in Component_Registry and create its baseline
# version in System_Metadata.
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Post -Path '/api/admin/metadata/add-component' -Authentication 'ADLogin' -ScriptBlock {
    try {
        if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }

        $moduleName = $WebEvent.Data.module_name
        $componentName = $WebEvent.Data.component_name
        $description = $WebEvent.Data.description
        $version = $WebEvent.Data.version
        if (-not $version) { $version = '1.0.0' }

        # Validate required fields
        if (-not $moduleName -or -not $componentName -or -not $description) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "module_name, component_name, and description are required" }) -StatusCode 400
            return
        }

        # Check for duplicate component
        $existing = Invoke-XFActsQuery -Query @"
            SELECT component_id FROM dbo.Component_Registry
            WHERE component_name = @comp
"@ -Parameters @{ comp = $componentName }

        if ($existing) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Component '$componentName' already exists" }) -StatusCode 409
            return
        }

        $user = "FAC\$($WebEvent.Auth.User.Username)"

        # Insert into Component_Registry
        Invoke-XFActsQuery -Query @"
            INSERT INTO dbo.Component_Registry
                (module_name, component_name, description, created_by)
            VALUES
                (@mod, @comp, @desc, @user)
"@ -Parameters @{ mod = $moduleName; comp = $componentName; desc = $description; user = $user }

        # Insert baseline version into System_Metadata
        Invoke-XFActsQuery -Query @"
            INSERT INTO dbo.System_Metadata
                (module_name, component_name, version, description, deployed_by)
            VALUES
                (@mod, @comp, @ver, @verDesc, @user)
"@ -Parameters @{
            mod = $moduleName; comp = $componentName; ver = $version
            verDesc = "Initial component baseline"; user = $user
        }

        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            success = $true
            module_name = $moduleName
            component_name = $componentName
            version = $version
            message = "Component '$componentName' registered with v$version"
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ============================================================================
# SHARED: Module Registry (used by System Metadata, GlobalConfig, Scheduler)
# ============================================================================

# ----------------------------------------------------------------------------
# GET /api/admin/modules
# Returns Module_Registry descriptions. Cached client-side, shared across panels.
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Get -Path '/api/admin/modules' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $results = Invoke-XFActsQuery -Query @"
            SELECT module_name, description
            FROM dbo.Module_Registry
            WHERE is_active = 1
            ORDER BY module_name
"@
        Write-PodeJsonResponse -Value $results
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ============================================================================
# GLOBALCONFIG APIs
# ============================================================================

# ----------------------------------------------------------------------------
# GET /api/admin/globalconfig/modules
# Returns distinct module names that have UI-editable settings
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Get -Path '/api/admin/globalconfig/modules' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $results = Invoke-XFActsQuery -Query @"
            SELECT DISTINCT module_name
            FROM dbo.GlobalConfig
            WHERE is_ui_editable = 1
            ORDER BY module_name
"@
        Write-PodeJsonResponse -Value $results
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ----------------------------------------------------------------------------
# GET /api/admin/globalconfig/settings?module=X
# Returns UI-editable settings with optional module filter
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Get -Path '/api/admin/globalconfig/settings' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $where = @("is_ui_editable = 1")
        $params = @{}

        if ($module) {
            $where += "module_name = @mod"
            $params['mod'] = $module
        }

        $whereClause = $where -join ' AND '

        $results = Invoke-XFActsQuery -Query @"
            SELECT config_id, module_name, setting_name, setting_value,
                   data_type, category, description, notes, is_active
            FROM dbo.GlobalConfig
            WHERE $whereClause
            ORDER BY module_name, is_active DESC, category, setting_name
"@ -Parameters $params

        Write-PodeJsonResponse -Value $results
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ----------------------------------------------------------------------------
# POST /api/admin/globalconfig/update
# Update a single GlobalConfig setting value
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Post -Path '/api/admin/globalconfig/update' -Authentication 'ADLogin' -ScriptBlock {
    try {
        if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }

        $configId = $WebEvent.Data.config_id
        $fieldName = $WebEvent.Data.field_name   # 'setting_value' or 'is_active'
        $newValue = $WebEvent.Data.new_value
        $user = "FAC\$($WebEvent.Auth.User.Username)"

        # Default to setting_value for backward compatibility with existing BIT toggle / value edit calls
        if (-not $fieldName) {
            $fieldName = 'setting_value'
            $newValue = $WebEvent.Data.setting_value
        }

        if (-not $configId) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "config_id is required" }) -StatusCode 400
            return
        }
        if ($null -eq $newValue) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "value is required" }) -StatusCode 400
            return
        }
        if ($fieldName -notin @('setting_value', 'is_active')) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Invalid field_name: must be 'setting_value' or 'is_active'" }) -StatusCode 400
            return
        }

        # Verify the setting exists and is UI-editable
        $existing = Invoke-XFActsQuery -Query @"
            SELECT config_id, module_name, setting_name, setting_value,
                   data_type, is_ui_editable, is_active
            FROM dbo.GlobalConfig
            WHERE config_id = @cid
"@ -Parameters @{ cid = [int]$configId }

        if (-not $existing) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Setting not found" }) -StatusCode 404
            return
        }

        $setting = $existing[0]

        if (-not $setting.is_ui_editable) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Setting '$($setting.setting_name)' is not UI-editable" }) -StatusCode 403
            return
        }

        $val = [string]$newValue

        if ($fieldName -eq 'setting_value') {
            # Validate value based on data_type
            switch ($setting.data_type) {
                'BIT' {
                    if ($val -notin @('0','1')) {
                        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "BIT value must be 0 or 1" }) -StatusCode 400
                        return
                    }
                }
                'INT' {
                    if ($val -notmatch '^\-?\d+$') {
                        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "INT value must be a whole number" }) -StatusCode 400
                        return
                    }
                }
                'DECIMAL' {
                    if ($val -notmatch '^\-?\d+(\.\d+)?$') {
                        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "DECIMAL value must be a number" }) -StatusCode 400
                        return
                    }
                }
            }

            $oldValue = $setting.setting_value

            Invoke-XFActsQuery -Query @"
                UPDATE dbo.GlobalConfig
                SET setting_value = @val
                WHERE config_id = @cid
"@ -Parameters @{ val = $val; cid = [int]$configId }
        }
        elseif ($fieldName -eq 'is_active') {
            if ($val -notin @('0','1')) {
                Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "is_active must be 0 or 1" }) -StatusCode 400
                return
            }

            $oldValue = [string]$setting.is_active

            Invoke-XFActsQuery -Query @"
                UPDATE dbo.GlobalConfig
                SET is_active = @val
                WHERE config_id = @cid
"@ -Parameters @{ val = [int]$val; cid = [int]$configId }
        }

        # Log the change to ActionAuditLog
        Invoke-XFActsQuery -Query @"
            INSERT INTO dbo.ActionAuditLog
                (source_module, entity_type, entity_id, entity_name, field_name, old_value, new_value, changed_by)
            VALUES
                (@mod, 'GlobalConfig', @cid, @name, @field, @oldVal, @newVal, @user)
"@ -Parameters @{
            mod    = $setting.module_name
            cid    = [int]$configId
            name   = $setting.setting_name
            field  = $fieldName
            oldVal = if ($oldValue) { $oldValue } else { [DBNull]::Value }
            newVal = $val
            user   = $user
        }

        $action = if ($fieldName -eq 'is_active') {
            if ($val -eq '1') { 'reactivated' } else { 'deactivated' }
        } else { 'updated' }

        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            success = $true
            config_id = [int]$configId
            setting_name = $setting.setting_name
            field_name = $fieldName
            old_value = $oldValue
            new_value = $val
            performed_by = $user
            message = "$($setting.module_name).$($setting.setting_name) $action"
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ----------------------------------------------------------------------------
# GET /api/admin/globalconfig/history?config_id=X
# Returns change history for a specific GlobalConfig setting
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Get -Path '/api/admin/globalconfig/history' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $configId = $WebEvent.Query['config_id']
        if (-not $configId) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "config_id is required" }) -StatusCode 400
            return
        }

        # Look up setting_name for the config_id to query ActionAuditLog
        $settingInfo = Invoke-XFActsQuery -Query @"
            SELECT setting_name FROM dbo.GlobalConfig WHERE config_id = @cid
"@ -Parameters @{ cid = [int]$configId }

        $settingName = if ($settingInfo) { $settingInfo[0].setting_name } else { '' }

        $results = Invoke-XFActsQuery -Query @"
            SELECT audit_id AS change_id, entity_id AS config_id,
                   source_module AS module_name, entity_name AS setting_name,
                   old_value, new_value, changed_by, changed_dttm
            FROM dbo.ActionAuditLog
            WHERE entity_type = 'GlobalConfig'
              AND entity_name = @sname
            ORDER BY changed_dttm DESC
"@ -Parameters @{ sname = $settingName }

        Write-PodeJsonResponse -Value $results
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ----------------------------------------------------------------------------
# POST /api/admin/globalconfig/insert
# Insert a new GlobalConfig setting
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Post -Path '/api/admin/globalconfig/insert' -Authentication 'ADLogin' -ScriptBlock {
    try {
        if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }

        $module = $WebEvent.Data.module_name
        $name = $WebEvent.Data.setting_name
        $value = $WebEvent.Data.setting_value
        $dataType = $WebEvent.Data.data_type
        $category = $WebEvent.Data.category
        $description = $WebEvent.Data.description
        $user = "FAC\$($WebEvent.Auth.User.Username)"

        # Validate required fields
        if (-not $module -or -not $name -or -not $dataType -or -not $description) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "module_name, setting_name, data_type, and description are required" }) -StatusCode 400
            return
        }
        if ($null -eq $value) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "setting_value is required" }) -StatusCode 400
            return
        }

        # Validate setting_name format: lowercase, underscores, no spaces
        if ($name -notmatch '^[a-z][a-z0-9_]*$') {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Setting name must be lowercase letters, numbers, and underscores only" }) -StatusCode 400
            return
        }

        # Validate data_type
        if ($dataType -notin @('BIT','INT','DECIMAL','VARCHAR')) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "data_type must be BIT, INT, DECIMAL, or VARCHAR" }) -StatusCode 400
            return
        }

        # Check for duplicate
        $existing = Invoke-XFActsQuery -Query @"
            SELECT config_id FROM dbo.GlobalConfig
            WHERE module_name = @mod AND setting_name = @name
"@ -Parameters @{ mod = $module; name = $name }

        if ($existing) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Setting '$name' already exists in module '$module'" }) -StatusCode 409
            return
        }

        Invoke-XFActsQuery -Query @"
            INSERT INTO dbo.GlobalConfig
                (module_name, setting_name, setting_value, data_type, category,
                 description, is_active, is_ui_editable, created_by)
            VALUES
                (@mod, @name, @val, @dtype, @cat, @desc, 1, 1, @user)
"@ -Parameters @{
            mod = $module; name = $name; val = [string]$value
            dtype = $dataType; desc = $description; user = $user
            cat = if ($category) { $category } else { [DBNull]::Value }
        }

        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            success = $true
            module_name = $module
            setting_name = $name
            message = "Created $module.$name"
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}
# ============================================================================
# SCHEDULE EDITOR APIs
# ============================================================================

# ----------------------------------------------------------------------------
# GET /api/admin/schedule/processes
# All ProcessRegistry entries for the Schedule Editor panel
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Get -Path '/api/admin/schedule/processes' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $results = Invoke-XFActsQuery -Query @"
            SELECT
                p.process_id,
                p.module_name,
                p.process_name,
                p.description,
                p.script_path,
                p.execution_mode,
                p.dependency_group,
                p.interval_seconds,
                p.scheduled_time,
                p.timeout_seconds,
                p.allow_concurrent,
                p.run_mode
            FROM Orchestrator.ProcessRegistry p
            ORDER BY p.module_name, p.process_name
"@
        Write-PodeJsonResponse -Value $results
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ----------------------------------------------------------------------------
# GET /api/admin/schedule/browse-scripts
# List .ps1 files not already registered in ProcessRegistry
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Get -Path '/api/admin/schedule/browse-scripts' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $scriptDir = 'E:\xFACts-PowerShell'

        if (-not (Test-Path $scriptDir)) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Script directory not found: $scriptDir" }) -StatusCode 500
            return
        }

        # Get all .ps1 files in the directory (top level only)
        $allFiles = Get-ChildItem -Path $scriptDir -Filter '*.ps1' -File |
            Select-Object -ExpandProperty Name |
            Sort-Object

        # Scripts that should never be registered as processes
        $excludedScripts = @(
            'Start-xFACtsOrchestrator.ps1',
            'xFACts-IndexFunctions.ps1',
            'xFACts-OrchestratorFunctions.ps1'
        )

        # Get already-registered script_path values
        $registered = Invoke-XFActsQuery -Query @"
            SELECT script_path FROM Orchestrator.ProcessRegistry WHERE script_path IS NOT NULL
"@
        $registeredNames = @()
        if ($registered) {
            $registeredNames = $registered | ForEach-Object { $_.script_path }
        }

        # Filter out already-registered and excluded scripts
        $available = $allFiles | Where-Object {
            $_ -notin $registeredNames -and $_ -notin $excludedScripts
        }

        Write-PodeJsonResponse -Value @($available)
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ----------------------------------------------------------------------------
# POST /api/admin/schedule/update
# Update a single editable field on an existing process (RBAC protected)
# Expects: { process_id, field_name, old_value, new_value }
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Post -Path '/api/admin/schedule/update' -Authentication 'ADLogin' -ScriptBlock {
    try {
        if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }

        $user = "FAC\$($WebEvent.Auth.User.Username)"
        $processId = $WebEvent.Data.process_id
        $fieldName = $WebEvent.Data.field_name
        $oldValue = $WebEvent.Data.old_value
        $newValue = $WebEvent.Data.new_value

        if (-not $processId -or -not $fieldName) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "process_id and field_name are required" }) -StatusCode 400
            return
        }

        # Whitelist of editable fields
        $editableFields = @('execution_mode', 'dependency_group', 'interval_seconds', 'scheduled_time', 'timeout_seconds', 'allow_concurrent')
        if ($fieldName -notin $editableFields) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Field '$fieldName' is not editable" }) -StatusCode 400
            return
        }

        # Verify process exists and get name for audit
        $proc = Invoke-XFActsQuery -Query @"
            SELECT process_id, process_name, module_name FROM Orchestrator.ProcessRegistry WHERE process_id = @pid
"@ -Parameters @{ pid = [int]$processId }

        if (-not $proc) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Process not found" }) -StatusCode 404
            return
        }

        $processName = $proc[0].process_name
        $moduleName = $proc[0].module_name

        # Validate and cast value based on field
        $sqlValue = $null
        switch ($fieldName) {
            'execution_mode' {
                if ($newValue -notin @('WAIT', 'FIRE_AND_FORGET')) {
                    Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "execution_mode must be WAIT or FIRE_AND_FORGET" }) -StatusCode 400
                    return
                }
                $sqlValue = $newValue
            }
            'dependency_group' {
                if ($newValue -notmatch '^\d+$') {
                    Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "dependency_group must be a positive integer" }) -StatusCode 400
                    return
                }
                $sqlValue = [int]$newValue
            }
            'interval_seconds' {
                if ($newValue -notmatch '^\d+$' -or [int]$newValue -lt 0) {
                    Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "interval_seconds must be a non-negative integer" }) -StatusCode 400
                    return
                }
                $sqlValue = [int]$newValue
            }
            'scheduled_time' {
                # Allow NULL/empty to clear, or a valid time string
                if ([string]::IsNullOrWhiteSpace($newValue) -or $newValue -eq 'null') {
                    $sqlValue = [DBNull]::Value
                }
                else {
                    try { [TimeSpan]::Parse($newValue) | Out-Null; $sqlValue = $newValue }
                    catch {
                        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "scheduled_time must be a valid time (HH:mm:ss)" }) -StatusCode 400
                        return
                    }
                }
            }
            'timeout_seconds' {
                if ([string]::IsNullOrWhiteSpace($newValue) -or $newValue -eq 'null') {
                    $sqlValue = [DBNull]::Value
                }
                elseif ($newValue -notmatch '^\d+$') {
                    Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "timeout_seconds must be a positive integer or empty" }) -StatusCode 400
                    return
                }
                else { $sqlValue = [int]$newValue }
            }
            'allow_concurrent' {
                if ($newValue -notin @('0', '1', 0, 1, $true, $false)) {
                    Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "allow_concurrent must be 0 or 1" }) -StatusCode 400
                    return
                }
                $sqlValue = if ($newValue -eq $true -or $newValue -eq '1' -or $newValue -eq 1) { 1 } else { 0 }
            }
        }

        # Dynamic UPDATE — safe because field_name is whitelisted above
        Invoke-XFActsQuery -Query @"
            UPDATE Orchestrator.ProcessRegistry
            SET $fieldName = @val, modified_dttm = GETDATE(), modified_by = @user
            WHERE process_id = @pid
"@ -Parameters @{
            val  = $sqlValue
            user = $user
            pid  = [int]$processId
        }

        # Audit log
        Invoke-XFActsQuery -Query @"
            INSERT INTO dbo.ActionAuditLog
                (source_module, entity_type, entity_id, entity_name, field_name, old_value, new_value, changed_by)
            VALUES
                (@mod, 'ProcessSchedule', @pid, @pname, @field, @oldVal, @newVal, @user)
"@ -Parameters @{
            mod    = $moduleName
            pid    = [int]$processId
            pname  = $processName
            field  = $fieldName
            oldVal = if ($oldValue -ne $null -and $oldValue -ne '') { [string]$oldValue } else { [DBNull]::Value }
            newVal = if ($sqlValue -is [DBNull]) { [DBNull]::Value } else { [string]$sqlValue }
            user   = $user
        }

        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            success = $true
            process_id = [int]$processId
            process_name = $processName
            field_name = $fieldName
            new_value = if ($sqlValue -is [DBNull]) { $null } else { $sqlValue }
            performed_by = $user
            message = "$processName.$fieldName updated by $user"
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ----------------------------------------------------------------------------
# POST /api/admin/schedule/add
# Register a new process in ProcessRegistry (RBAC protected)
# New processes are always created DISABLED (run_mode = 0)
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Post -Path '/api/admin/schedule/add' -Authentication 'ADLogin' -ScriptBlock {
    try {
        if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }

        $user = "FAC\$($WebEvent.Auth.User.Username)"
        $moduleName = $WebEvent.Data.module_name
        $scriptPath = $WebEvent.Data.script_path
        $processName = $WebEvent.Data.process_name
        $description = $WebEvent.Data.description
        $executionMode = $WebEvent.Data.execution_mode
        $dependencyGroup = $WebEvent.Data.dependency_group
        $intervalSeconds = $WebEvent.Data.interval_seconds
        $scheduledTime = $WebEvent.Data.scheduled_time
        $timeoutSeconds = $WebEvent.Data.timeout_seconds

        # Validate required fields
        if (-not $moduleName -or -not $scriptPath -or -not $processName -or -not $description) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "module_name, script_path, process_name, and description are required" }) -StatusCode 400
            return
        }
        if (-not $dependencyGroup -or -not $timeoutSeconds) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "dependency_group and timeout_seconds are required" }) -StatusCode 400
            return
        }

        # Validate execution_mode
        if (-not $executionMode) { $executionMode = 'FIRE_AND_FORGET' }
        if ($executionMode -notin @('WAIT', 'FIRE_AND_FORGET')) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "execution_mode must be WAIT or FIRE_AND_FORGET" }) -StatusCode 400
            return
        }

        # Check for duplicate script_path
        $existing = Invoke-XFActsQuery -Query @"
            SELECT process_id FROM Orchestrator.ProcessRegistry WHERE script_path = @sp
"@ -Parameters @{ sp = $scriptPath }

        if ($existing) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Script '$scriptPath' is already registered" }) -StatusCode 409
            return
        }

        # Check for duplicate module_name + process_name
        $existingName = Invoke-XFActsQuery -Query @"
            SELECT process_id FROM Orchestrator.ProcessRegistry WHERE module_name = @mod AND process_name = @pn
"@ -Parameters @{ mod = $moduleName; pn = $processName }

        if ($existingName) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Process '$processName' already exists in module '$moduleName'" }) -StatusCode 409
            return
        }

        # Handle scheduled_time (nullable)
        $schedTimeVal = if ([string]::IsNullOrWhiteSpace($scheduledTime) -or $scheduledTime -eq 'null') {
            [DBNull]::Value
        } else { $scheduledTime }

        # Handle interval_seconds (default 300 if not provided)
        $intervalVal = if ($intervalSeconds) { [int]$intervalSeconds } else { 300 }

        Invoke-XFActsQuery -Query @"
            INSERT INTO Orchestrator.ProcessRegistry
                (module_name, process_name, description, script_path, execution_mode,
                 dependency_group, interval_seconds, scheduled_time, timeout_seconds,
                 run_mode, allow_concurrent, created_by)
            VALUES
                (@mod, @pn, @desc, @sp, @em,
                 @dg, @iv, @st, @ts,
                 0, 0, @user)
"@ -Parameters @{
            mod  = $moduleName
            pn   = $processName
            desc = $description
            sp   = $scriptPath
            em   = $executionMode
            dg   = [int]$dependencyGroup
            iv   = $intervalVal
            st   = $schedTimeVal
            ts   = [int]$timeoutSeconds
            user = $user
        }

        # Get the new process_id
        $newProc = Invoke-XFActsQuery -Query @"
            SELECT process_id FROM Orchestrator.ProcessRegistry WHERE module_name = @mod AND process_name = @pn
"@ -Parameters @{ mod = $moduleName; pn = $processName }

        $newId = if ($newProc) { $newProc[0].process_id } else { $null }

        # Audit log
        Invoke-XFActsQuery -Query @"
            INSERT INTO dbo.ActionAuditLog
                (source_module, entity_type, entity_id, entity_name, field_name, old_value, new_value, changed_by)
            VALUES
                (@mod, 'ProcessSchedule', @pid, @pname, 'NEW_PROCESS', NULL, @desc, @user)
"@ -Parameters @{
            mod   = $moduleName
            pid   = if ($newId) { [int]$newId } else { [DBNull]::Value }
            pname = $processName
            desc  = "script=$scriptPath, mode=$executionMode, group=$dependencyGroup, interval=$intervalVal, timeout=$timeoutSeconds"
            user  = $user
        }

        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            success = $true
            process_id = $newId
            process_name = $processName
            module_name = $moduleName
            performed_by = $user
            message = "Process '$processName' added to $moduleName (disabled, run_mode=0)"
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ============================================================================
# API: Documentation Pipeline — Launch (fire-and-forget)
# Launches Invoke-DocPipeline.ps1 which runs selected steps in sequence and
# writes real-time status to a JSON file. Poll /api/admin/doc-pipeline/status
# for progress.
# ============================================================================
Add-PodeRoute -Method Post -Path '/api/admin/doc-pipeline' -Authentication 'ADLogin' -ScriptBlock {
    try {
        if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }

        $user = "FAC\$($WebEvent.Auth.User.Username)"
        $body = $WebEvent.Data

        # Validate at least one step selected
        $steps = @($body.steps)
        if ($steps.Count -eq 0) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "No steps selected" }) -StatusCode 400
            return
        }

        $stepsJoined = $steps -join ','

        # Build switch arguments for options
        $optionArgs = @()
        if ([bool]$body.publish_to_confluence) { $optionArgs += '-PublishToConfluence' }
        if ([bool]$body.export_markdown)       { $optionArgs += '-ExportMarkdown' }
        if ([bool]$body.include_sql_objects)    { $optionArgs += '-IncludeSQLObjects' }
        if ([bool]$body.include_json)           { $optionArgs += '-IncludeJSON' }
        $optionString = $optionArgs -join ' '

        $scriptsRoot = 'E:\xFACts-PowerShell'
        $wrapperScript = Join-Path $scriptsRoot 'Invoke-DocPipeline.ps1'

        if (-not (Test-Path $wrapperScript)) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Wrapper script not found: Invoke-DocPipeline.ps1" }) -StatusCode 500
            return
        }

        # Clear any previous status file
        $statusFile = Join-Path $scriptsRoot 'Logs\doc-pipeline-status.json'
        if (Test-Path $statusFile) {
            Remove-Item $statusFile -Force -ErrorAction SilentlyContinue
        }

        # Launch fire-and-forget
        $arguments = "-ExecutionPolicy Bypass -File `"$wrapperScript`" -StepsJson `"$stepsJoined`" $optionString"
        Start-Process -FilePath "powershell.exe" `
            -ArgumentList $arguments `
            -WorkingDirectory $scriptsRoot `
            -WindowStyle Hidden `
            -PassThru | Out-Null

        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            success      = $true
            performed_by = $user
            message      = "Documentation pipeline launched ($($steps.Count) steps)"
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ============================================================================
# API: Documentation Pipeline — Status (polling endpoint)
# Returns the current contents of the pipeline status JSON file.
# Lightweight read-only — safe to poll every 2 seconds.
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/admin/doc-pipeline/status' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $statusFile = 'E:\xFACts-PowerShell\Logs\doc-pipeline-status.json'

        if (-not (Test-Path $statusFile)) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{
                complete = $false
                pending  = $true
                message  = 'Waiting for pipeline to start...'
            })
            return
        }

        $json = Get-Content $statusFile -Raw -Encoding UTF8 -ErrorAction Stop
        $status = $json | ConvertFrom-Json

        Write-PodeJsonResponse -Value $status
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}
# ============================================================================
# ALERT FAILURES APIs
# Added: 2026-03-05
# ============================================================================

# ----------------------------------------------------------------------------
# GET /api/admin/alert-failure-count
# Returns the count of unresolved failed alerts (for card badge pip).
# Lightweight — safe to poll on the 5-second refresh cycle.
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Get -Path '/api/admin/alert-failure-count' -Authentication 'ADLogin' -ScriptBlock {
    try {
        # Get lookback days from GlobalConfig (default 3)
        $lookbackResult = Invoke-XFActsQuery -Query @"
            SELECT CAST(setting_value AS INT) AS lookback_days
            FROM dbo.GlobalConfig
            WHERE module_name = 'Teams'
              AND setting_name = 'alert_failure_lookback_days'
              AND is_active = 1
"@
        $lookbackDays = if ($lookbackResult -and $lookbackResult.Count -gt 0) { $lookbackResult[0].lookback_days } else { 3 }

        $result = Invoke-XFActsQuery -Query @"
            SELECT COUNT(*) AS cnt
            FROM Teams.AlertQueue f
            WHERE f.status = 'Failed'
              AND f.created_dttm >= DATEADD(DAY, -@lookback, GETDATE())
              AND NOT EXISTS (
                SELECT 1 FROM Teams.AlertQueue r
                WHERE r.original_queue_id = f.queue_id
                  AND r.status IN ('Success', 'Sent', 'Pending')
              )
"@ -Parameters @{ lookback = $lookbackDays }

        $count = if ($result -and $result.Count -gt 0) { $result[0].cnt } else { 0 }
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ count = $count })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ----------------------------------------------------------------------------
# GET /api/admin/alert-failures
# Returns unresolved failed alerts within the lookback window.
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Get -Path '/api/admin/alert-failures' -Authentication 'ADLogin' -ScriptBlock {
    try {
        # Get lookback days from GlobalConfig (default 3)
        $lookbackResult = Invoke-XFActsQuery -Query @"
            SELECT CAST(setting_value AS INT) AS lookback_days
            FROM dbo.GlobalConfig
            WHERE module_name = 'Teams'
              AND setting_name = 'alert_failure_lookback_days'
              AND is_active = 1
"@
        $lookbackDays = if ($lookbackResult -and $lookbackResult.Count -gt 0) { $lookbackResult[0].lookback_days } else { 3 }

        $results = Invoke-XFActsQuery -Query @"
            SELECT f.queue_id, f.source_module, f.alert_category, f.title,
                   f.message, f.error_message, f.retry_count, f.created_dttm
            FROM Teams.AlertQueue f
            WHERE f.status = 'Failed'
              AND f.created_dttm >= DATEADD(DAY, -@lookback, GETDATE())
              AND NOT EXISTS (
                SELECT 1 FROM Teams.AlertQueue r
                WHERE r.original_queue_id = f.queue_id
                  AND r.status IN ('Success', 'Sent', 'Pending')
              )
            ORDER BY f.created_dttm DESC
"@ -Parameters @{ lookback = $lookbackDays }

        Write-PodeJsonResponse -Value $results
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ----------------------------------------------------------------------------
# POST /api/admin/alert-resend
# Creates a new Pending copy of a failed alert for redelivery.
# RBAC: Operate tier via Test-ActionEndpoint.
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Post -Path '/api/admin/alert-resend' -Authentication 'ADLogin' -ScriptBlock {
    try {
        if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }

        $user = "FAC\$($WebEvent.Auth.User.Username)"
        $queueId = $WebEvent.Data.queue_id

        if (-not $queueId) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "queue_id required" }) -StatusCode 400
            return
        }

        # Verify the original alert exists and is Failed
        $original = Invoke-XFActsQuery -Query @"
            SELECT queue_id, source_module, alert_category, title, message,
                   color, card_json, trigger_type, trigger_value, status
            FROM Teams.AlertQueue
            WHERE queue_id = @qid
"@ -Parameters @{ qid = [int]$queueId }

        if (-not $original -or $original.Count -eq 0) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Alert not found: queue_id $queueId" }) -StatusCode 404
            return
        }

        $orig = $original[0]
        if ($orig.status -ne 'Failed') {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Alert is not in Failed status (current: $($orig.status))" }) -StatusCode 409
            return
        }

        # Check if there's already a Pending resend for this alert
        $pendingResend = Invoke-XFActsQuery -Query @"
            SELECT queue_id FROM Teams.AlertQueue
            WHERE original_queue_id = @qid AND status = 'Pending'
"@ -Parameters @{ qid = [int]$queueId }

        if ($pendingResend -and $pendingResend.Count -gt 0) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "A resend is already pending for this alert" }) -StatusCode 409
            return
        }

        # Insert the resend copy — handle nullable fields
        $cardJson = if ($orig.card_json -and $orig.card_json -isnot [DBNull]) { $orig.card_json } else { [DBNull]::Value }
        $trigType = if ($orig.trigger_type -and $orig.trigger_type -isnot [DBNull]) { $orig.trigger_type } else { [DBNull]::Value }
        $trigVal  = if ($orig.trigger_value -and $orig.trigger_value -isnot [DBNull]) { $orig.trigger_value } else { [DBNull]::Value }

        Invoke-XFActsQuery -Query @"
            INSERT INTO Teams.AlertQueue
                (source_module, alert_category, title, message, color,
                 card_json, trigger_type, trigger_value,
                 status, retry_count, original_queue_id, created_dttm)
            VALUES
                (@src, @cat, @title, @msg, @color,
                 @cardJson, @trigType, @trigVal,
                 'Pending', 0, @origId, GETDATE())
"@ -Parameters @{
            src      = $orig.source_module
            cat      = $orig.alert_category
            title    = $orig.title
            msg      = $orig.message
            color    = if ($orig.color -and $orig.color -isnot [DBNull]) { $orig.color } else { [DBNull]::Value }
            cardJson = $cardJson
            trigType = $trigType
            trigVal  = $trigVal
            origId   = [int]$queueId
        }

        # Get the new queue_id
        $newRow = Invoke-XFActsQuery -Query @"
            SELECT TOP 1 queue_id FROM Teams.AlertQueue
            WHERE original_queue_id = @qid
            ORDER BY created_dttm DESC
"@ -Parameters @{ qid = [int]$queueId }

        $newQueueId = if ($newRow -and $newRow.Count -gt 0) { $newRow[0].queue_id } else { $null }

        # Audit log
        Invoke-XFActsQuery -Query @"
            INSERT INTO dbo.ActionAuditLog
                (source_module, entity_type, entity_id, entity_name, field_name, old_value, new_value, changed_by)
            VALUES
                ('Teams', 'AlertResend', @origId, @title, 'resend', 'Failed', 'Pending (resend)', @user)
"@ -Parameters @{
            origId = [int]$queueId
            title  = $orig.title
            user   = $user
        }

        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            success      = $true
            new_queue_id = $newQueueId
            original_id  = [int]$queueId
            performed_by = $user
            message      = "Alert queued for resend"
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}
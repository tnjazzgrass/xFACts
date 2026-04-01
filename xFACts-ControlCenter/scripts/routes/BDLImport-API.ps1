# ============================================================================
# xFACts Control Center - BDL Import API
# Location: E:\xFACts-ControlCenter\scripts\routes\BDLImport-API.ps1
# 
# API endpoints for the BDL Import workflow.
# Version: Tracked in dbo.System_Metadata (component: ControlCenter.BDLImport)
# ============================================================================

# ----------------------------------------------------------------------------
# GET /api/bdl-import/environments
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Get -Path '/api/bdl-import/environments' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $results = Invoke-XFActsQuery -Query @"
            SELECT sc.config_id, sc.server_name, sc.environment, 
                   sc.api_base_url, sc.dmfs_base_path
            FROM Tools.ServerConfig sc
            INNER JOIN dbo.ServerRegistry sr ON sr.server_id = sc.server_id
            WHERE sc.is_active = 1
              AND sr.tools_enabled = 1
              --AND sr.is_active = 1
            ORDER BY 
                CASE sc.environment 
                    WHEN 'TEST' THEN 1 
                    WHEN 'STAGE' THEN 2 
                    WHEN 'PROD' THEN 3 
                    ELSE 4 
                END
"@
        Write-PodeJsonResponse -Value @{ environments = @($results) }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ----------------------------------------------------------------------------
# GET /api/bdl-import/entities
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Get -Path '/api/bdl-import/entities' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/bdl-import'
        
        if ($access.Tier -eq 'admin') {
            $results = Invoke-XFActsQuery -Query @"
                SELECT f.entity_type, f.type_name, f.folder, f.element_count,
                       f.has_parent_ref, f.has_nullify_fields
                FROM Tools.Catalog_BDLFormatRegistry f
                WHERE f.is_active = 1
                  AND f.entity_type IS NOT NULL
                ORDER BY f.folder, f.entity_type
"@
        }
        else {
            $deptScope = ''
            if ($access.DepartmentScopes -and $access.DepartmentScopes.Count -gt 0) {
                foreach ($scope in $access.DepartmentScopes) {
                    if ($scope -and $scope -isnot [System.DBNull]) { 
                        $deptScope = $scope
                        break 
                    }
                }
            }
            
            $results = Invoke-XFActsQuery -Query @"
                SELECT f.entity_type, f.type_name, f.folder, f.element_count,
                       f.has_parent_ref, f.has_nullify_fields
                FROM Tools.Catalog_BDLFormatRegistry f
                INNER JOIN Tools.AccessConfig ac 
                    ON ac.item_key = f.entity_type
                    AND ac.tool_type = 'BDL'
                    AND ac.department_scope = @deptScope
                    AND ac.is_active = 1
                WHERE f.is_active = 1
                  AND f.entity_type IS NOT NULL
                ORDER BY f.folder, f.entity_type
"@ -Parameters @{ deptScope = $deptScope }
        }
        
        Write-PodeJsonResponse -Value @{ entities = @($results) }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ----------------------------------------------------------------------------
# GET /api/bdl-import/entity-fields?entity_type=PHONE
# Returns BDL element fields for a specific entity type.
# Admin tier: all visible fields.
# Department tier: only fields whitelisted in AccessFieldConfig.
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Get -Path '/api/bdl-import/entity-fields' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $entityType = $WebEvent.Query['entity_type']
        if (-not $entityType) {
            Write-PodeJsonResponse -Value @{ error = 'entity_type parameter required' } -StatusCode 400
            return
        }

        $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/bdl-import'
        
        if ($access.Tier -eq 'admin') {
            # Admin: all visible fields
            $fields = Invoke-XFActsQuery -Query @"
                SELECT e.element_name, e.display_name, e.data_type, e.max_length,
                       e.table_column, e.lookup_table, e.is_not_nullifiable, 
                       e.is_primary_id, e.is_visible, e.is_import_required,
                       e.field_description, e.sort_order
                FROM Tools.Catalog_BDLElementRegistry e
                INNER JOIN Tools.Catalog_BDLFormatRegistry f
                    ON e.format_id = f.format_id
                WHERE f.entity_type = @entityType
                  AND e.is_visible = 1
                ORDER BY e.sort_order
"@ -Parameters @{ entityType = $entityType }
        }
        else {
            # Department: only fields whitelisted in AccessFieldConfig
            $deptScope = ''
            if ($access.DepartmentScopes -and $access.DepartmentScopes.Count -gt 0) {
                foreach ($scope in $access.DepartmentScopes) {
                    if ($scope -and $scope -isnot [System.DBNull]) { 
                        $deptScope = $scope
                        break 
                    }
                }
            }

            $fields = Invoke-XFActsQuery -Query @"
                SELECT e.element_name, e.display_name, e.data_type, e.max_length,
                       e.table_column, e.lookup_table, e.is_not_nullifiable, 
                       e.is_primary_id, e.is_visible, e.is_import_required,
                       e.field_description, e.sort_order
                FROM Tools.Catalog_BDLElementRegistry e
                INNER JOIN Tools.Catalog_BDLFormatRegistry f
                    ON e.format_id = f.format_id
                INNER JOIN Tools.AccessConfig ac
                    ON ac.item_key = f.entity_type
                    AND ac.tool_type = 'BDL'
                    AND ac.department_scope = @deptScope
                    AND ac.is_active = 1
                INNER JOIN Tools.AccessFieldConfig afc
                    ON afc.config_id = ac.config_id
                    AND afc.element_name = e.element_name
                    AND afc.is_active = 1
                WHERE f.entity_type = @entityType
                  AND e.is_visible = 1
                ORDER BY e.sort_order
"@ -Parameters @{ entityType = $entityType; deptScope = $deptScope }
        }
        
        $wrapper = Invoke-XFActsQuery -Query @"
            SELECT w.type_name AS wrapper, we.element_name AS entity_ref, we.data_type
            FROM Tools.Catalog_BDLFormatRegistry w
            INNER JOIN Tools.Catalog_BDLElementRegistry we
                ON we.format_id = w.format_id
            INNER JOIN Tools.Catalog_BDLFormatRegistry f
                ON we.data_type = f.type_name
            WHERE f.entity_type = @entityType
"@ -Parameters @{ entityType = $entityType }
        
        Write-PodeJsonResponse -Value @{ 
            fields = @($fields)
            wrapper = @($wrapper)
            entity_type = $entityType
        }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ----------------------------------------------------------------------------
# POST /api/bdl-import/stage
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Post -Path '/api/bdl-import/stage' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $body = $WebEvent.Data
        $entityType = $body.entity_type
        $configId = $body.config_id
        $mapping = $body.mapping
        $headers = $body.headers
        $rows = $body.rows

        if (-not $entityType -or -not $configId -or -not $mapping -or -not $headers -or -not $rows) {
            Write-PodeJsonResponse -Value @{ error = 'Missing required fields: entity_type, config_id, mapping, headers, rows' } -StatusCode 400
            return
        }

        $serverConfig = Invoke-XFActsQuery -Query @"
            SELECT db_instance, environment
            FROM Tools.ServerConfig
            WHERE config_id = @configId AND is_active = 1
"@ -Parameters @{ configId = $configId }

        if (-not $serverConfig -or $serverConfig.Count -eq 0) {
            Write-PodeJsonResponse -Value @{ error = 'Environment configuration not found' } -StatusCode 404
            return
        }

        $environment = $serverConfig[0].environment

        $username = $WebEvent.Auth.User.Username
        if ($username -and $username.Contains('\')) { $username = $username.Split('\')[1] }

        $fieldMeta = Invoke-XFActsQuery -Query @"
            SELECT e.element_name, e.data_type, e.max_length, e.lookup_table, e.is_import_required
            FROM Tools.Catalog_BDLElementRegistry e
            INNER JOIN Tools.Catalog_BDLFormatRegistry f ON e.format_id = f.format_id
            WHERE f.entity_type = @entityType
              AND e.is_visible = 1
"@ -Parameters @{ entityType = $entityType }

        $fieldMetaMap = @{}
        foreach ($f in $fieldMeta) { $fieldMetaMap[$f.element_name] = $f }

        $timestamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
        $tableName = "BDL_${entityType}_${username}_${timestamp}"
        $fullTableName = "Staging.[$tableName]"

        $mappingHash = @{}
        foreach ($key in $mapping.PSObject.Properties) { $mappingHash[$key.Name] = $key.Value }

        $mappedElementNames = @{}
        foreach ($val in $mappingHash.Values) { $mappedElementNames[$val] = $true }

        # ── Build CREATE TABLE DDL ──────────────────────────────────────
        $colDefs = @()
        $colDefs += '    [_row_number] INT IDENTITY(1,1)'
        $colDefs += '    [_skip] BIT NOT NULL DEFAULT 0'

        $mappedColumns = @()
        $unmappedColumns = @()
        $requiredExtraColumns = @()

        for ($i = 0; $i -lt $headers.Count; $i++) {
            $header = $headers[$i]
            if ($mappingHash.ContainsKey($header)) {
                $elementName = $mappingHash[$header]
                $meta = $fieldMetaMap[$elementName]
                
                $sqlType = 'VARCHAR(MAX)'
                if ($meta) {
                    $bdlType = if ($meta.data_type -and $meta.data_type -isnot [System.DBNull]) { $meta.data_type.ToLower() } else { '' }
                    $maxLen = $meta.max_length
                    
                    switch ($bdlType) {
                        'string'   { $sqlType = if ($maxLen) { "VARCHAR($maxLen)" } else { 'VARCHAR(MAX)' } }
                        'int'      { $sqlType = 'VARCHAR(20)' }
                        'long'     { $sqlType = 'VARCHAR(20)' }
                        'short'    { $sqlType = 'VARCHAR(10)' }
                        'decimal'  { $sqlType = 'VARCHAR(30)' }
                        'boolean'  { $sqlType = 'VARCHAR(10)' }
                        'dateTime' { $sqlType = 'VARCHAR(50)' }
                        default    { $sqlType = if ($maxLen) { "VARCHAR($maxLen)" } else { 'VARCHAR(MAX)' } }
                    }
                }
                
                $colDefs += "    [$elementName] $sqlType NULL"
                $mappedColumns += @{ headerIndex = $i; elementName = $elementName }
            }
            else {
                $safeName = ($header -replace '[^\w]', '_')
                if ($safeName.Length -gt 100) { $safeName = $safeName.Substring(0, 100) }
                $colDefs += "    [${safeName}_unmapped] VARCHAR(MAX) NULL"
                $unmappedColumns += @{ headerIndex = $i; columnName = "${safeName}_unmapped" }
            }
        }

        foreach ($f in $fieldMeta) {
            if ($f.is_import_required -and -not $mappedElementNames.ContainsKey($f.element_name)) {
                $bdlType = if ($f.data_type -and $f.data_type -isnot [System.DBNull]) { $f.data_type.ToLower() } else { '' }
                $maxLen = $f.max_length
                $sqlType = 'VARCHAR(MAX)'
                
                switch ($bdlType) {
                    'string'   { $sqlType = if ($maxLen) { "VARCHAR($maxLen)" } else { 'VARCHAR(MAX)' } }
                    'int'      { $sqlType = 'VARCHAR(20)' }
                    'long'     { $sqlType = 'VARCHAR(20)' }
                    'short'    { $sqlType = 'VARCHAR(10)' }
                    'decimal'  { $sqlType = 'VARCHAR(30)' }
                    'boolean'  { $sqlType = 'VARCHAR(10)' }
                    'dateTime' { $sqlType = 'VARCHAR(50)' }
                    default    { $sqlType = if ($maxLen) { "VARCHAR($maxLen)" } else { 'VARCHAR(MAX)' } }
                }

                $colDefs += "    [$($f.element_name)] $sqlType NULL"
                $requiredExtraColumns += @{ elementName = $f.element_name; sqlType = $sqlType }
            }
        }

        $createDdl = "CREATE TABLE $fullTableName (`n" + ($colDefs -join ",`n") + "`n);"
        Invoke-XFActsNonQuery -Query $createDdl

        # ── Bulk INSERT rows ────────────────────────────────────────────
        $allInsertColumns = @()
        foreach ($mc in $mappedColumns) { $allInsertColumns += "[$($mc.elementName)]" }
        foreach ($uc in $unmappedColumns) { $allInsertColumns += "[$($uc.columnName)]" }
        $columnList = $allInsertColumns -join ', '

        $allColumnIndices = @()
        foreach ($mc in $mappedColumns) { $allColumnIndices += $mc.headerIndex }
        foreach ($uc in $unmappedColumns) { $allColumnIndices += $uc.headerIndex }

        $batchSize = 500
        $totalRows = $rows.Count
        
        for ($batchStart = 0; $batchStart -lt $totalRows; $batchStart += $batchSize) {
            $batchEnd = [Math]::Min($batchStart + $batchSize, $totalRows)
            $valuesClauses = @()

            for ($r = $batchStart; $r -lt $batchEnd; $r++) {
                $row = $rows[$r]
                $vals = @()
                foreach ($colIdx in $allColumnIndices) {
                    $val = if ($colIdx -lt $row.Count) { $row[$colIdx] } else { '' }
                    $val = $val -replace "'", "''"
                    $vals += "'$val'"
                }
                $valuesClauses += "(" + ($vals -join ', ') + ")"
            }

            $insertSql = "INSERT INTO $fullTableName ($columnList) VALUES`n" + ($valuesClauses -join ",`n")
            Invoke-XFActsNonQuery -Query $insertSql
        }

        $reqExtraNames = @($requiredExtraColumns | ForEach-Object { $_.elementName })

        Write-PodeJsonResponse -Value @{
            staging_table         = $tableName
            row_count             = $totalRows
            environment           = $environment
            required_extra_fields = @($reqExtraNames)
        }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ----------------------------------------------------------------------------
# POST /api/bdl-import/validate
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Post -Path '/api/bdl-import/validate' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $body = $WebEvent.Data
        $stagingTable = $body.staging_table
        $entityType = $body.entity_type
        $configId = $body.config_id

        if (-not $stagingTable -or -not $entityType -or -not $configId) {
            Write-PodeJsonResponse -Value @{ error = 'staging_table, entity_type, and config_id are required' } -StatusCode 400
            return
        }

        $tableCheck = Invoke-XFActsQuery -Query @"
            SELECT 1 FROM sys.tables t
            INNER JOIN sys.schemas s ON s.schema_id = t.schema_id
            WHERE s.name = 'Staging' AND t.name = @tableName
"@ -Parameters @{ tableName = $stagingTable }

        if (-not $tableCheck -or $tableCheck.Count -eq 0) {
            Write-PodeJsonResponse -Value @{ error = "Staging table not found: $stagingTable" } -StatusCode 404
            return
        }

        $serverConfig = Invoke-XFActsQuery -Query @"
            SELECT db_instance, environment
            FROM Tools.ServerConfig
            WHERE config_id = @configId AND is_active = 1
"@ -Parameters @{ configId = $configId }

        if (-not $serverConfig -or $serverConfig.Count -eq 0) {
            Write-PodeJsonResponse -Value @{ error = 'Environment configuration not found' } -StatusCode 404
            return
        }

        $dbInstance = $serverConfig[0].db_instance
        $environment = $serverConfig[0].environment

        $safeTable = "Staging.[" + $stagingTable.Replace(']', ']]') + "]"
        $stagingRows = Invoke-XFActsQuery -Query "SELECT * FROM $safeTable WHERE _skip = 0 ORDER BY _row_number"

        $mappedColumnNames = @()
        if ($stagingRows -and $stagingRows.Count -gt 0) {
            $mappedColumnNames = @($stagingRows[0].Keys | Where-Object { 
                $_ -ne '_row_number' -and $_ -ne '_skip' -and $_ -notlike '*_unmapped' 
            })
        }

        $fieldMeta = Invoke-XFActsQuery -Query @"
            SELECT e.element_name, e.data_type, e.max_length, e.lookup_table
            FROM Tools.Catalog_BDLElementRegistry e
            INNER JOIN Tools.Catalog_BDLFormatRegistry f ON e.format_id = f.format_id
            WHERE f.entity_type = @entityType
              AND e.is_visible = 1
"@ -Parameters @{ entityType = $entityType }

        $lookupFields = $fieldMeta | Where-Object { $_.lookup_table -and $_.lookup_table -isnot [System.DBNull] }
        $lookups = @{}
        $lookupErrors = @{}
        $discoveredTables = @{}

        foreach ($field in $lookupFields) {
            if ($mappedColumnNames -notcontains $field.element_name) { continue }
            $tblName = $field.lookup_table
            $elementName = $field.element_name

            try {
                if (-not $discoveredTables.ContainsKey($tblName)) {
                    $columns = Invoke-CRS5ReadQuery -TargetInstance $dbInstance -Query @"
                        SELECT COLUMN_NAME
                        FROM INFORMATION_SCHEMA.COLUMNS
                        WHERE TABLE_SCHEMA = 'dbo' AND TABLE_NAME = @tableName
                        ORDER BY ORDINAL_POSITION
"@ -Parameters @{ tableName = $tblName }

                    $colNames = @($columns | ForEach-Object { $_.COLUMN_NAME })
                    $valColumn = $colNames | Where-Object { $_ -like '*_val_txt' } | Select-Object -First 1
                    $actvColumn = $colNames | Where-Object { $_ -like '*_actv_flg' } | Select-Object -First 1

                    $discoveredTables[$tblName] = @{
                        ValColumn  = $valColumn
                        ActvColumn = $actvColumn
                        AllColumns = $colNames
                    }
                }

                $tableInfo = $discoveredTables[$tblName]

                if (-not $tableInfo.ValColumn) {
                    $lookupErrors[$elementName] = "Could not find _val_txt column in $tblName (columns: $($tableInfo.AllColumns -join ', '))"
                    continue
                }

                $valCol = $tableInfo.ValColumn
                $actvCol = $tableInfo.ActvColumn

                if ($actvCol) {
                    $values = Invoke-CRS5ReadQuery -TargetInstance $dbInstance -Query @"
                        SELECT DISTINCT [$valCol] AS val FROM dbo.[$tblName] WHERE [$actvCol] = 'Y' ORDER BY [$valCol]
"@
                }
                else {
                    $values = Invoke-CRS5ReadQuery -TargetInstance $dbInstance -Query @"
                        SELECT DISTINCT [$valCol] AS val FROM dbo.[$tblName] ORDER BY [$valCol]
"@
                }

                $lookups[$elementName] = @{
                    values      = @($values | ForEach-Object { $_.val })
                    table       = $tblName
                    val_column  = $valCol
                    actv_column = if ($actvCol) { $actvCol } else { $null }
                }
            }
            catch {
                $lookupErrors[$elementName] = "Failed to query $tblName on ${dbInstance}: $($_.Exception.Message)"
            }
        }

        $rowArrays = @()
        foreach ($sRow in $stagingRows) {
            $rowVals = @()
            foreach ($col in $mappedColumnNames) {
                $v = $sRow[$col]
                if ($v -is [System.DBNull]) { $rowVals += '' }
                else { $rowVals += [string]$v }
            }
            $rowArrays += ,@($rowVals)
        }

        $skipCount = Invoke-XFActsQuery -Query "SELECT COUNT(*) AS cnt FROM $safeTable WHERE _skip = 1"
        $skippedCount = if ($skipCount -and $skipCount.Count -gt 0) { $skipCount[0].cnt } else { 0 }

        Write-PodeJsonResponse -Value @{
            columns       = @($mappedColumnNames)
            rows          = @($rowArrays)
            row_count     = $rowArrays.Count
            skipped_count = $skippedCount
            lookups       = $lookups
            lookup_errors = $lookupErrors
            environment   = $environment
            db_instance   = $dbInstance
        }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ----------------------------------------------------------------------------
# POST /api/bdl-import/replace-values
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Post -Path '/api/bdl-import/replace-values' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $body = $WebEvent.Data
        $stagingTable = $body.staging_table
        $field = $body.field
        $oldValue = $body.old_value
        $newValue = $body.new_value

        if (-not $stagingTable -or -not $field -or -not $newValue) {
            Write-PodeJsonResponse -Value @{ error = 'Missing required fields: staging_table, field, new_value' } -StatusCode 400
            return
        }

        $tableCheck = Invoke-XFActsQuery -Query @"
            SELECT 1 FROM sys.tables t INNER JOIN sys.schemas s ON s.schema_id = t.schema_id
            WHERE s.name = 'Staging' AND t.name = @tableName
"@ -Parameters @{ tableName = $stagingTable }

        if (-not $tableCheck -or $tableCheck.Count -eq 0) {
            Write-PodeJsonResponse -Value @{ error = "Staging table not found: $stagingTable" } -StatusCode 404
            return
        }

        $colCheck = Invoke-XFActsQuery -Query @"
            SELECT 1 FROM sys.columns c
            INNER JOIN sys.tables t ON t.object_id = c.object_id
            INNER JOIN sys.schemas s ON s.schema_id = t.schema_id
            WHERE s.name = 'Staging' AND t.name = @tableName AND c.name = @colName
"@ -Parameters @{ tableName = $stagingTable; colName = $field }

        if (-not $colCheck -or $colCheck.Count -eq 0) {
            Write-PodeJsonResponse -Value @{ error = "Column not found: $field" } -StatusCode 404
            return
        }

        $safeTable = "Staging.[" + $stagingTable.Replace(']', ']]') + "]"
        $safeField = "[" + $field.Replace(']', ']]') + "]"

        if (-not $oldValue -or $oldValue -eq '') {
            $rowsUpdated = Invoke-XFActsNonQuery -Query @"
                UPDATE $safeTable SET $safeField = @newValue
                WHERE ($safeField IS NULL OR LTRIM(RTRIM($safeField)) = '') AND _skip = 0
"@ -Parameters @{ newValue = $newValue }
        }
        else {
            $rowsUpdated = Invoke-XFActsNonQuery -Query @"
                UPDATE $safeTable SET $safeField = @newValue
                WHERE UPPER($safeField) = UPPER(@oldValue) AND _skip = 0
"@ -Parameters @{ newValue = $newValue; oldValue = $oldValue }
        }

        Write-PodeJsonResponse -Value @{ rows_updated = $rowsUpdated; field = $field; old_value = $oldValue; new_value = $newValue }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ----------------------------------------------------------------------------
# POST /api/bdl-import/skip-rows
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Post -Path '/api/bdl-import/skip-rows' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $body = $WebEvent.Data
        $stagingTable = $body.staging_table
        $field = $body.field
        $value = $body.value

        if (-not $stagingTable -or -not $field) {
            Write-PodeJsonResponse -Value @{ error = 'Missing required fields: staging_table, field' } -StatusCode 400
            return
        }

        $tableCheck = Invoke-XFActsQuery -Query @"
            SELECT 1 FROM sys.tables t INNER JOIN sys.schemas s ON s.schema_id = t.schema_id
            WHERE s.name = 'Staging' AND t.name = @tableName
"@ -Parameters @{ tableName = $stagingTable }

        if (-not $tableCheck -or $tableCheck.Count -eq 0) {
            Write-PodeJsonResponse -Value @{ error = "Staging table not found: $stagingTable" } -StatusCode 404
            return
        }

        $safeTable = "Staging.[" + $stagingTable.Replace(']', ']]') + "]"
        $safeField = "[" + $field.Replace(']', ']]') + "]"

        if (-not $value -or $value -eq '') {
            $rowsSkipped = Invoke-XFActsNonQuery -Query @"
                UPDATE $safeTable SET _skip = 1
                WHERE ($safeField IS NULL OR LTRIM(RTRIM($safeField)) = '')
"@
        }
        else {
            $rowsSkipped = Invoke-XFActsNonQuery -Query @"
                UPDATE $safeTable SET _skip = 1
                WHERE UPPER($safeField) = UPPER(@matchValue)
"@ -Parameters @{ matchValue = $value }
        }

        Write-PodeJsonResponse -Value @{ rows_skipped = $rowsSkipped; field = $field; value = $value }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ----------------------------------------------------------------------------
# GET /api/bdl-import/staging-cleanup
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Get -Path '/api/bdl-import/staging-cleanup' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $results = Invoke-XFActsQuery -Query @"
            SELECT t.name, t.create_date, DATEDIFF(HOUR, t.create_date, GETDATE()) AS age_hours
            FROM sys.tables t INNER JOIN sys.schemas s ON s.schema_id = t.schema_id
            WHERE s.name = 'Staging' AND DATEDIFF(HOUR, t.create_date, GETDATE()) > 48
            ORDER BY t.create_date
"@
        Write-PodeJsonResponse -Value @{ expired_tables = @($results) }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ----------------------------------------------------------------------------
# POST /api/bdl-import/staging-cleanup
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Post -Path '/api/bdl-import/staging-cleanup' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $expired = Invoke-XFActsQuery -Query @"
            SELECT t.name FROM sys.tables t INNER JOIN sys.schemas s ON s.schema_id = t.schema_id
            WHERE s.name = 'Staging' AND DATEDIFF(HOUR, t.create_date, GETDATE()) > 48
"@
        $dropped = @()
        foreach ($tbl in $expired) {
            $safeName = "Staging.[" + $tbl.name.Replace(']', ']]') + "]"
            Invoke-XFActsNonQuery -Query "DROP TABLE $safeName;"
            $dropped += $tbl.name
        }
        Write-PodeJsonResponse -Value @{ dropped = @($dropped) }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ----------------------------------------------------------------------------
# GET /api/bdl-import/history
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Get -Path '/api/bdl-import/history' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $results = Invoke-XFActsQuery -Query @"
            SELECT TOP 50 log_id, environment, entity_type, source_filename,
                   row_count, validation_errors, status, error_message,
                   executed_by, started_dttm, completed_dttm
            FROM Tools.BDL_ImportLog
            ORDER BY log_id DESC
"@
        Write-PodeJsonResponse -Value @{ history = @($results) }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}
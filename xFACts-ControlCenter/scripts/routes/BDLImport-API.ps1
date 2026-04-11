# ============================================================================
# xFACts Control Center - BDL Import API
# Location: E:\xFACts-ControlCenter\scripts\routes\BDLImport-API.ps1
# 
# API endpoints for the BDL Import workflow.
# Version: Tracked in dbo.System_Metadata (component: ControlCenter.BDLImport)
#
# CHANGELOG
# ---------
# 2026-04-04  Added AR log (Jira ticket link) support to execute endpoint
# 2026-04-04  Added drop_existing support to stage endpoint for re-staging
# 2026-04-04  Added template CRUD endpoints (list, save, update, delete)
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
                       f.has_parent_ref, f.has_nullify_fields, f.action_type, f.entity_key
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
                       f.has_parent_ref, f.has_nullify_fields, f.action_type, f.entity_key
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
                       e.field_description, e.import_guidance, e.sort_order
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
                       e.field_description, e.import_guidance, e.sort_order
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
# Creates a staging table and inserts all rows from the uploaded file.
# Optional: drop_existing parameter drops a prior staging table before creating.
# Optional: fixed_values parameter applies uniform values to all rows (for
#           FIXED_VALUE entity types like tags).
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Post -Path '/api/bdl-import/stage' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $body = $WebEvent.Data
        $entityType = $body.entity_type
        $configId = $body.config_id
        $mapping = $body.mapping
        $headers = $body.headers
        $rows = $body.rows
        $fixedValues = $body.fixed_values
 
        if (-not $entityType -or -not $configId -or -not $headers -or -not $rows) {
            Write-PodeJsonResponse -Value @{ error = 'Missing required fields: entity_type, config_id, headers, rows' } -StatusCode 400
            return
        }
 
        # mapping may be empty for pure FIXED_VALUE entities (only identifier mapped)
        if (-not $mapping) { $mapping = [PSCustomObject]@{} }
 
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
 
        # ── Drop existing staging table if re-staging ───────────────────
        $dropExisting = $body.drop_existing
        if ($dropExisting) {
            $dropCheck = Invoke-XFActsQuery -Query @"
                SELECT 1 FROM sys.tables t
                INNER JOIN sys.schemas s ON s.schema_id = t.schema_id
                WHERE s.name = 'Staging' AND t.name = @tableName
"@ -Parameters @{ tableName = $dropExisting }
            if ($dropCheck -and $dropCheck.Count -gt 0) {
                $safeDrop = "Staging.[" + $dropExisting.Replace(']', ']]') + "]"
                Invoke-XFActsNonQuery -Query "DROP TABLE $safeDrop;"
            }
        }
 
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
 
        # ── Apply fixed values (for FIXED_VALUE entity types) ──────────
        if ($fixedValues) {
            foreach ($prop in $fixedValues.PSObject.Properties) {
                $fvElementName = $prop.Name
                $fvValue = $prop.Value
 
                # Check if column exists in staging table
                $colExists = Invoke-XFActsQuery -Query @"
                    SELECT 1 FROM sys.columns c
                    INNER JOIN sys.tables t ON t.object_id = c.object_id
                    INNER JOIN sys.schemas s ON s.schema_id = t.schema_id
                    WHERE s.name = 'Staging' AND t.name = @tableName AND c.name = @colName
"@ -Parameters @{ tableName = $tableName; colName = $fvElementName }
 
                if (-not $colExists -or $colExists.Count -eq 0) {
                    # Column doesn't exist — add it with appropriate type
                    $fvMeta = $fieldMetaMap[$fvElementName]
                    $fvSqlType = 'VARCHAR(MAX)'
                    if ($fvMeta) {
                        $fvBdlType = if ($fvMeta.data_type -and $fvMeta.data_type -isnot [System.DBNull]) { $fvMeta.data_type.ToLower() } else { '' }
                        $fvMaxLen = $fvMeta.max_length
                        switch ($fvBdlType) {
                            'string'   { $fvSqlType = if ($fvMaxLen) { "VARCHAR($fvMaxLen)" } else { 'VARCHAR(MAX)' } }
                            'int'      { $fvSqlType = 'VARCHAR(20)' }
                            'long'     { $fvSqlType = 'VARCHAR(20)' }
                            'short'    { $fvSqlType = 'VARCHAR(10)' }
                            'decimal'  { $fvSqlType = 'VARCHAR(30)' }
                            'boolean'  { $fvSqlType = 'VARCHAR(10)' }
                            'dateTime' { $fvSqlType = 'VARCHAR(50)' }
                            default    { $fvSqlType = if ($fvMaxLen) { "VARCHAR($fvMaxLen)" } else { 'VARCHAR(MAX)' } }
                        }
                    }
                    $safeCol = "[$fvElementName]"
                    Invoke-XFActsNonQuery -Query "ALTER TABLE $fullTableName ADD $safeCol $fvSqlType NULL"
                }
 
                # Update all non-skipped rows with the fixed value
                $safeCol = "[$fvElementName]"
                Invoke-XFActsNonQuery -Query @"
                    UPDATE $fullTableName SET $safeCol = @fixedVal WHERE _skip = 0
"@ -Parameters @{ fixedVal = $fvValue }
            }
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
# GET /api/bdl-import/lookup-search
# Typeahead search against DM lookup tables for FIXED_VALUE entity fields.
# Discovers active flag and description columns dynamically via
# INFORMATION_SCHEMA. Returns top 10 matching values with descriptions
# when a _nm column is available.
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Get -Path '/api/bdl-import/lookup-search' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $lookupTable = $WebEvent.Query['lookup_table']
        $elementName = $WebEvent.Query['element_name']
        $search = $WebEvent.Query['search']
        $configId = $WebEvent.Query['config_id']

        if (-not $lookupTable -or -not $elementName -or -not $search -or -not $configId) {
            Write-PodeJsonResponse -Value @{ error = 'lookup_table, element_name, search, and config_id are required' } -StatusCode 400
            return
        }

        if ($search.Length -lt 2) {
            Write-PodeJsonResponse -Value @{ values = @() }
            return
        }

        $serverConfig = Invoke-XFActsQuery -Query @"
            SELECT db_instance
            FROM Tools.ServerConfig
            WHERE config_id = @configId AND is_active = 1
"@ -Parameters @{ configId = $configId }

        if (-not $serverConfig -or $serverConfig.Count -eq 0) {
            Write-PodeJsonResponse -Value @{ error = 'Environment configuration not found' } -StatusCode 404
            return
        }

        $dbInstance = $serverConfig[0].db_instance

        # Discover columns dynamically
        $columns = Invoke-CRS5ReadQuery -TargetInstance $dbInstance -Query @"
            SELECT COLUMN_NAME
            FROM INFORMATION_SCHEMA.COLUMNS
            WHERE TABLE_SCHEMA = 'dbo' AND TABLE_NAME = @tableName
            ORDER BY ORDINAL_POSITION
"@ -Parameters @{ tableName = $lookupTable }

        $colNames = @($columns | ForEach-Object { $_.COLUMN_NAME })

        # Verify the element_name column exists in the lookup table
        if ($colNames -notcontains $elementName) {
            Write-PodeJsonResponse -Value @{ error = "Column '$elementName' not found in table '$lookupTable'" } -StatusCode 404
            return
        }

        $actvColumn = $colNames | Where-Object { $_ -like '*_actv_flg' } | Select-Object -First 1
        $descColumn = $colNames | Where-Object { $_ -like '*_nm' -and $_ -ne $elementName } | Select-Object -First 1

        # Build and execute the search query
        $safeElement = "[$elementName]"
        $safeTable = "dbo.[$lookupTable]"
        $selectColumns = "$safeElement AS val"
        if ($descColumn) { $selectColumns += ", [$descColumn] AS description" }

        $whereClause = "$safeElement LIKE @searchPattern"
        if ($actvColumn) { $whereClause += " AND [$actvColumn] = 'Y'" }

        $values = Invoke-CRS5ReadQuery -TargetInstance $dbInstance -Query @"
            SELECT DISTINCT TOP 10 $selectColumns
            FROM $safeTable
            WHERE $whereClause
            ORDER BY $safeElement
"@ -Parameters @{ searchPattern = "%$search%" }

        $results = @($values | ForEach-Object {
            $item = @{ value = $_.val }
            if ($descColumn -and $_.description -and $_.description -isnot [System.DBNull]) {
                $item.description = $_.description
            }
            $item
        })

        Write-PodeJsonResponse -Value @{ values = @($results) }
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
                   executed_by, started_dttm, completed_dttm, parent_log_id
            FROM Tools.BDL_ImportLog
            ORDER BY log_id DESC
"@
        Write-PodeJsonResponse -Value @{ history = @($results) }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ----------------------------------------------------------------------------
# POST /api/bdl-import/build-preview
# Builds the BDL XML from staging data and returns it for preview.
# Does NOT write the file or call DM APIs.
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Post -Path '/api/bdl-import/build-preview' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $body = $WebEvent.Data
        $stagingTable = $body.staging_table
        $entityType = $body.entity_type
        $configId = $body.config_id

        if (-not $stagingTable -or -not $entityType -or -not $configId) {
            Write-PodeJsonResponse -Value @{ error = 'staging_table, entity_type, and config_id are required' } -StatusCode 400
            return
        }

        $xmlResult = Build-BDLXml -StagingTable $stagingTable -EntityType $entityType -ConfigId $configId -WebEvent $WebEvent
        if ($xmlResult.Error) {
            Write-PodeJsonResponse -Value @{ error = $xmlResult.Error } -StatusCode $xmlResult.StatusCode
            return
        }

        # Return a truncated preview if the XML is very large
        $xmlPreview = $xmlResult.Xml
        $truncated = $false
        if ($xmlPreview.Length -gt 100000) {
            $xmlPreview = $xmlPreview.Substring(0, 100000) + "`n<!-- ... truncated for preview (full file: $([math]::Round($xmlResult.Xml.Length / 1024, 1)) KB) -->"
            $truncated = $true
        }

        Write-PodeJsonResponse -Value @{
            xml             = $xmlPreview
            xml_filename    = $xmlResult.Filename
            row_count       = $xmlResult.RowCount
            skipped_count   = $xmlResult.SkippedCount
            environment     = $xmlResult.Environment
            truncated       = $truncated
            full_size_bytes = $xmlResult.Xml.Length
        }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ----------------------------------------------------------------------------
# POST /api/bdl-import/execute
# Full execute: build XML -> write to dmfs -> register -> trigger import.
# Handles a single entity type per call. Called sequentially by the client
# for multi-entity imports. AR log is handled separately via execute-ar-log.
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Post -Path '/api/bdl-import/execute' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $body = $WebEvent.Data
        $stagingTable = $body.staging_table
        $entityType = $body.entity_type
        $configId = $body.config_id
        $sourceFilename = $body.source_filename
        $columnMapping = $body.column_mapping

        if (-not $stagingTable -or -not $entityType -or -not $configId) {
            Write-PodeJsonResponse -Value @{ error = 'staging_table, entity_type, and config_id are required' } -StatusCode 400
            return
        }

        $user = "FAC\$($WebEvent.Auth.User.Username)"
        $username = $WebEvent.Auth.User.Username
        if ($username -and $username.Contains('\')) { $username = $username.Split('\')[1] }

        # ── Step 1: Build the XML ───────────────────────────────────────
        $xmlResult = Build-BDLXml -StagingTable $stagingTable -EntityType $entityType -ConfigId $configId -WebEvent $WebEvent
        if ($xmlResult.Error) {
            Write-PodeJsonResponse -Value @{ error = $xmlResult.Error } -StatusCode $xmlResult.StatusCode
            return
        }

        # ── Step 2: Create ImportLog row (BUILDING status) ──────────────
        $logInsert = Invoke-XFActsQuery -Query @"
            INSERT INTO Tools.BDL_ImportLog 
                (server_config_id, environment, entity_type, source_filename,
                 xml_filename, staging_table, row_count, column_mapping, status, executed_by)
            OUTPUT INSERTED.log_id
            VALUES 
                (@configId, @environment, @entityType, @sourceFilename,
                 @xmlFilename, @stagingTable, @rowCount, @columnMapping, 'BUILDING', @executedBy)
"@ -Parameters @{
            configId       = $configId
            environment    = $xmlResult.Environment
            entityType     = $entityType
            sourceFilename = if ($sourceFilename) { $sourceFilename } else { 'unknown' }
            xmlFilename    = $xmlResult.Filename
            rowCount       = $xmlResult.RowCount
            columnMapping  = if ($columnMapping) { $columnMapping } else { [DBNull]::Value }
            stagingTable   = $stagingTable
            executedBy     = $user
        }

        $logId = $logInsert[0].log_id

        # ── Step 3: Get server config for file path and API URL ─────────
        $serverConfig = Invoke-XFActsQuery -Query @"
            SELECT api_base_url, dmfs_base_path, dmfs_bdl_folder, environment
            FROM Tools.ServerConfig
            WHERE config_id = @configId AND is_active = 1
"@ -Parameters @{ configId = $configId }

        $apiBaseUrl = $serverConfig[0].api_base_url
        $dmfsPath = $serverConfig[0].dmfs_base_path + '\' + $serverConfig[0].dmfs_bdl_folder + '\'

        # ── Step 4: Write XML file to dmfs ──────────────────────────────
        try {
            $fullFilePath = $dmfsPath + $xmlResult.Filename
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($fullFilePath, $xmlResult.Xml, $utf8NoBom)
        }
        catch {
            Invoke-XFActsNonQuery -Query @"
                UPDATE Tools.BDL_ImportLog 
                SET status = 'FAILED', error_message = @errorMsg, completed_dttm = GETDATE()
                WHERE log_id = @logId
"@ -Parameters @{ logId = $logId; errorMsg = "File write failed: $($_.Exception.Message)" }

            Write-PodeJsonResponse -Value @{ error = "Failed to write file to dmfs: $($_.Exception.Message)"; log_id = $logId } -StatusCode 500
            return
        }

        # ── Step 5: Get DM API credentials ──────────────────────────────
        try {
            $creds = Get-ServiceCredentials -ServiceName 'DM_REST_API'
        }
        catch {
            Invoke-XFActsNonQuery -Query @"
                UPDATE Tools.BDL_ImportLog 
                SET status = 'FAILED', error_message = @errorMsg, completed_dttm = GETDATE()
                WHERE log_id = @logId
"@ -Parameters @{ logId = $logId; errorMsg = "Credential retrieval failed: $($_.Exception.Message)" }

            Write-PodeJsonResponse -Value @{ error = "Failed to retrieve DM API credentials: $($_.Exception.Message)"; log_id = $logId } -StatusCode 500
            return
        }

        $authHeader = $creds.AuthHeader
        $apiHeaders = @{
            'Authorization' = $authHeader
            'Content-Type'  = 'application/vnd.fico.dm.v1+json'
        }

        # ── Step 6: Register file with DM (POST /fileregistry) ──────────
        try {
            $regBody = @{
                fileName = $xmlResult.Filename
                fileType = 'BDL_IMPORT'
            } | ConvertTo-Json

            $regResponse = Invoke-RestMethod -Uri "$apiBaseUrl/fileregistry" `
                -Method POST -Headers $apiHeaders -Body $regBody -ErrorAction Stop

            $fileRegistryId = $null
            if ($regResponse.data -and $regResponse.data.fileRegistryId) {
                $fileRegistryId = $regResponse.data.fileRegistryId
            }
            elseif ($regResponse.fileRegistryId) {
                $fileRegistryId = $regResponse.fileRegistryId
            }
            elseif ($regResponse.id) {
                $fileRegistryId = $regResponse.id
            }
            if (-not $fileRegistryId) {
                $regResponseText = $regResponse | ConvertTo-Json -Depth 5
                throw "Could not extract file_registry_id from response: $regResponseText"
            }

            Invoke-XFActsNonQuery -Query @"
                UPDATE Tools.BDL_ImportLog 
                SET status = 'REGISTERED', file_registry_id = @regId
                WHERE log_id = @logId
"@ -Parameters @{ logId = $logId; regId = $fileRegistryId }
        }
        catch {
            Invoke-XFActsNonQuery -Query @"
                UPDATE Tools.BDL_ImportLog 
                SET status = 'FAILED', error_message = @errorMsg, completed_dttm = GETDATE()
                WHERE log_id = @logId
"@ -Parameters @{ logId = $logId; errorMsg = "File registration failed: $($_.Exception.Message)" }

            Write-PodeJsonResponse -Value @{ error = "DM file registration failed: $($_.Exception.Message)"; log_id = $logId } -StatusCode 500
            return
        }

        # ── Step 7: Trigger BDL import (POST /fileregistry/{id}/bdlimport)
        try {
            $importResponse = Invoke-RestMethod -Uri "$apiBaseUrl/fileregistry/$fileRegistryId/bdlimport" `
                -Method POST -Headers $apiHeaders -Body '' -ErrorAction Stop

            Invoke-XFActsNonQuery -Query @"
                UPDATE Tools.BDL_ImportLog 
                SET status = 'SUBMITTED', completed_dttm = GETDATE()
                WHERE log_id = @logId
"@ -Parameters @{ logId = $logId }
        }
        catch {
            Invoke-XFActsNonQuery -Query @"
                UPDATE Tools.BDL_ImportLog 
                SET status = 'FAILED', error_message = @errorMsg, completed_dttm = GETDATE()
                WHERE log_id = @logId
"@ -Parameters @{ logId = $logId; errorMsg = "BDL import trigger failed: $($_.Exception.Message)" }

            Write-PodeJsonResponse -Value @{ error = "BDL import trigger failed: $($_.Exception.Message)"; log_id = $logId; file_registry_id = $fileRegistryId } -StatusCode 500
            return
        }

        # ── Primary BDL Success ─────────────────────────────────────────
        $primaryLogId = $logId
        $primaryResult = @{
            success          = $true
            log_id           = $logId
            file_registry_id = $fileRegistryId
            xml_filename     = $xmlResult.Filename
            row_count        = $xmlResult.RowCount
            environment      = $xmlResult.Environment
            status           = 'SUBMITTED'
            message          = "BDL file $($xmlResult.Filename) has been submitted to Debt Manager."
        }
		
# ── Promote metadata for non-PROD environments ─────────────────
        if ($xmlResult.Environment -ne 'PROD') {
            $cooldownConfig = Invoke-XFActsQuery -Query @"
                SELECT setting_value
                FROM dbo.GlobalConfig
                WHERE module_name = 'Tools'
                  AND category = 'Operations'
                  AND setting_name = 'bdl_promote_cooldown_seconds'
                  AND is_active = 1
"@
            $prodConfig = Invoke-XFActsQuery -Query @"
                SELECT sc.config_id
                FROM Tools.ServerConfig sc
                INNER JOIN dbo.ServerRegistry sr ON sr.server_id = sc.server_id
                WHERE sc.environment = 'PROD'
                  AND sc.is_active = 1
                  AND sr.tools_enabled = 1
"@

            if ($cooldownConfig -and $cooldownConfig.Count -gt 0) {
                $primaryResult.promote_cooldown_seconds = [int]$cooldownConfig[0].setting_value
            }
            if ($prodConfig -and $prodConfig.Count -gt 0) {
                $primaryResult.prod_config_id = $prodConfig[0].config_id
            }
        }

        # ── Final response ──────────────────────────────────────────────
        Write-PodeJsonResponse -Value $primaryResult
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ----------------------------------------------------------------------------
# POST /api/bdl-import/execute-ar-log
# Builds and submits a single consolidated CONSUMER_ACCOUNT_AR_LOG BDL
# covering all entity types in a batch execution. Called by the client
# after all primary entity imports complete successfully.
# Body: { staging_table, entity_types, jira_ticket, ar_message (optional),
#          config_id, source_filename, parent_log_ids }
# entity_types: comma-separated list (e.g., "PHONE,CONSUMER_TAG")
# parent_log_ids: comma-separated log_id values from primary imports
# AR log failure returns error but does not affect primary imports.
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Post -Path '/api/bdl-import/execute-ar-log' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $body = $WebEvent.Data
        $stagingTable   = $body.staging_table
        $entityTypes    = $body.entity_types
        $jiraTicket     = $body.jira_ticket
        $arMessage      = $body.ar_message
        $configId       = $body.config_id
        $sourceFilename = $body.source_filename
        $parentLogIds   = $body.parent_log_ids

        if (-not $stagingTable -or -not $jiraTicket -or -not $configId -or -not $entityTypes) {
            Write-PodeJsonResponse -Value @{ error = 'staging_table, entity_types, jira_ticket, and config_id are required' } -StatusCode 400
            return
        }

        $jiraTicket = $jiraTicket.Trim()
        $user = "FAC\$($WebEvent.Auth.User.Username)"

        # ── Default AR message if not provided ──────────────────────────
        if (-not $arMessage -or $arMessage.Trim() -eq '') {
            $arMessage = "${jiraTicket}: ${entityTypes} update via BDL Import"
        }

        # ── Determine identifier element from first entity type ─────────
        $firstEntity = ($entityTypes -split ',')[0].Trim()
        $folderInfo = Invoke-XFActsQuery -Query @"
            SELECT folder FROM Tools.Catalog_BDLFormatRegistry
            WHERE entity_type = @entityType AND is_active = 1
"@ -Parameters @{ entityType = $firstEntity }

        $isAcctLevel = $false
        if ($folderInfo -and $folderInfo.Count -gt 0 -and $folderInfo[0].folder) {
            $isAcctLevel = $folderInfo[0].folder -like '*account*'
        }
        $identifierElement = if ($isAcctLevel) { 'cnsmr_accnt_idntfr_agncy_id' } else { 'cnsmr_idntfr_agncy_id' }

        # ── Get server config ───────────────────────────────────────────
        $serverConfig = Invoke-XFActsQuery -Query @"
            SELECT api_base_url, dmfs_base_path, dmfs_bdl_folder, environment
            FROM Tools.ServerConfig
            WHERE config_id = @configId AND is_active = 1
"@ -Parameters @{ configId = $configId }

        if (-not $serverConfig -or $serverConfig.Count -eq 0) {
            Write-PodeJsonResponse -Value @{ error = 'Environment configuration not found' } -StatusCode 404
            return
        }

        $apiBaseUrl = $serverConfig[0].api_base_url
        $dmfsPath = $serverConfig[0].dmfs_base_path + '\' + $serverConfig[0].dmfs_bdl_folder + '\'
        $environment = $serverConfig[0].environment

        # ── Build AR log XML ────────────────────────────────────────────
        $arXmlResult = Build-ARLogXml -StagingTable $stagingTable -EntityType $firstEntity `
            -JiraTicket $jiraTicket -ArMessage $arMessage `
            -IdentifierElement $identifierElement -WebEvent $WebEvent

        if ($arXmlResult.Error) {
            Write-PodeJsonResponse -Value @{ error = $arXmlResult.Error } -StatusCode ($arXmlResult.StatusCode -as [int])
            return
        }

        # ── Write AR log XML to dmfs ────────────────────────────────────
        $arFilePath = $dmfsPath + $arXmlResult.Filename
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($arFilePath, $arXmlResult.Xml, $utf8NoBom)

        # ── Create ImportLog row (BUILDING) ─────────────────────────────
        $arLogInsert = Invoke-XFActsQuery -Query @"
            INSERT INTO Tools.BDL_ImportLog 
                (server_config_id, environment, entity_type, source_filename,
                 xml_filename, staging_table, row_count, status, executed_by, parent_log_ids)
            OUTPUT INSERTED.log_id
            VALUES 
                (@configId, @environment, 'CONSUMER_ACCOUNT_AR_LOG', @sourceFilename,
                 @xmlFilename, @stagingTable, @rowCount, 'BUILDING', @executedBy, @parentLogIds)
"@ -Parameters @{
            configId       = $configId
            environment    = $environment
            sourceFilename = if ($sourceFilename) { $sourceFilename } else { 'unknown' }
            xmlFilename    = $arXmlResult.Filename
            rowCount       = $arXmlResult.RowCount
            stagingTable   = $stagingTable
            executedBy     = $user
            parentLogIds   = if ($parentLogIds) { $parentLogIds } else { [DBNull]::Value }
        }

        $arLogId = $arLogInsert[0].log_id

        # ── Get DM API credentials ──────────────────────────────────────
        $creds = Get-ServiceCredentials -ServiceName 'DM_REST_API'
        $apiHeaders = @{
            'Authorization' = $creds.AuthHeader
            'Content-Type'  = 'application/vnd.fico.dm.v1+json'
        }

        # ── Register AR log file with DM ────────────────────────────────
        $arRegBody = @{ fileName = $arXmlResult.Filename; fileType = 'BDL_IMPORT' } | ConvertTo-Json
        $arRegResponse = Invoke-RestMethod -Uri "$apiBaseUrl/fileregistry" `
            -Method POST -Headers $apiHeaders -Body $arRegBody -ErrorAction Stop

        $arFileRegistryId = $null
        if ($arRegResponse.data -and $arRegResponse.data.fileRegistryId) { $arFileRegistryId = $arRegResponse.data.fileRegistryId }
        elseif ($arRegResponse.fileRegistryId) { $arFileRegistryId = $arRegResponse.fileRegistryId }
        elseif ($arRegResponse.id) { $arFileRegistryId = $arRegResponse.id }

        if (-not $arFileRegistryId) { throw "Could not extract file_registry_id from AR log registration response" }

        Invoke-XFActsNonQuery -Query @"
            UPDATE Tools.BDL_ImportLog 
            SET status = 'REGISTERED', file_registry_id = @regId
            WHERE log_id = @logId
"@ -Parameters @{ logId = $arLogId; regId = $arFileRegistryId }

        # ── Trigger AR log import ───────────────────────────────────────
        Invoke-RestMethod -Uri "$apiBaseUrl/fileregistry/$arFileRegistryId/bdlimport" `
            -Method POST -Headers $apiHeaders -Body '' -ErrorAction Stop

        Invoke-XFActsNonQuery -Query @"
            UPDATE Tools.BDL_ImportLog 
            SET status = 'SUBMITTED', completed_dttm = GETDATE()
            WHERE log_id = @logId
"@ -Parameters @{ logId = $arLogId }

        Write-PodeJsonResponse -Value @{
            success          = $true
            log_id           = $arLogId
            file_registry_id = $arFileRegistryId
            xml_filename     = $arXmlResult.Filename
            row_count        = $arXmlResult.RowCount
            entity_types     = $entityTypes
            message          = "AR log submitted for ${entityTypes}"
        }
    }
    catch {
        # If we have a log_id, mark it failed
        if ($arLogId) {
            try {
                Invoke-XFActsNonQuery -Query @"
                    UPDATE Tools.BDL_ImportLog 
                    SET status = 'FAILED', error_message = @errorMsg, completed_dttm = GETDATE()
                    WHERE log_id = @logId
"@ -Parameters @{ logId = $arLogId; errorMsg = "AR log failed: $($_.Exception.Message)" }
            } catch { }
        }
        Write-PodeJsonResponse -Value @{ error = "AR log failed: $($_.Exception.Message)" } -StatusCode 500
    }
}

# ----------------------------------------------------------------------------
# POST /api/bdl-import/align-rows
# Aligns a target staging table's skip set to match a source staging table.
# Finds identifier values that are skipped in the source but active in the
# target, and marks them as skipped in the target.
# Body: { source_table, target_table, identifier_column }
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Post -Path '/api/bdl-import/align-rows' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $body = $WebEvent.Data
        $sourceTable = $body.source_table
        $targetTable = $body.target_table
        $identifierColumn = $body.identifier_column

        if (-not $sourceTable -or -not $targetTable -or -not $identifierColumn) {
            Write-PodeJsonResponse -Value @{ error = 'source_table, target_table, and identifier_column are required' } -StatusCode 400
            return
        }

        # Verify both staging tables exist
        foreach ($tblName in @($sourceTable, $targetTable)) {
            $tableCheck = Invoke-XFActsQuery -Query @"
                SELECT 1 FROM sys.tables t
                INNER JOIN sys.schemas s ON s.schema_id = t.schema_id
                WHERE s.name = 'Staging' AND t.name = @tableName
"@ -Parameters @{ tableName = $tblName }

            if (-not $tableCheck -or $tableCheck.Count -eq 0) {
                Write-PodeJsonResponse -Value @{ error = "Staging table not found: $tblName" } -StatusCode 404
                return
            }
        }

        # Verify identifier column exists in both tables
        foreach ($tblName in @($sourceTable, $targetTable)) {
            $colCheck = Invoke-XFActsQuery -Query @"
                SELECT 1 FROM sys.columns c
                INNER JOIN sys.tables t ON t.object_id = c.object_id
                INNER JOIN sys.schemas s ON s.schema_id = t.schema_id
                WHERE s.name = 'Staging' AND t.name = @tableName AND c.name = @colName
"@ -Parameters @{ tableName = $tblName; colName = $identifierColumn }

            if (-not $colCheck -or $colCheck.Count -eq 0) {
                Write-PodeJsonResponse -Value @{ error = "Identifier column '$identifierColumn' not found in staging table '$tblName'" } -StatusCode 404
                return
            }
        }

        $safeSource = "Staging.[" + $sourceTable.Replace(']', ']]') + "]"
        $safeTarget = "Staging.[" + $targetTable.Replace(']', ']]') + "]"
        $safeIdCol = "[" + $identifierColumn.Replace(']', ']]') + "]"

        # Skip rows in the target where the identifier is skipped in the source
        $rowsAligned = Invoke-XFActsNonQuery -Query @"
            UPDATE t
            SET t._skip = 1
            FROM $safeTarget t
            INNER JOIN $safeSource s ON s.$safeIdCol = t.$safeIdCol
            WHERE s._skip = 1
              AND t._skip = 0
"@

        # Get updated counts for the target table
        $countResult = Invoke-XFActsQuery -Query @"
            SELECT 
                COUNT(CASE WHEN _skip = 0 THEN 1 END) AS active_count,
                COUNT(CASE WHEN _skip = 1 THEN 1 END) AS skipped_count
            FROM $safeTarget
"@

        $activeCount = if ($countResult -and $countResult.Count -gt 0) { $countResult[0].active_count } else { 0 }
        $skippedCount = if ($countResult -and $countResult.Count -gt 0) { $countResult[0].skipped_count } else { 0 }

        Write-PodeJsonResponse -Value @{
            rows_aligned  = $rowsAligned
            target_table  = $targetTable
            source_table  = $sourceTable
            active_count  = $activeCount
            skipped_count = $skippedCount
        }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ----------------------------------------------------------------------------
# POST /api/bdl-import/reset-alignment
# Resets all skipped rows in a staging table back to active.
# Used to undo alignment on FIXED_VALUE entity staging tables.
# Body: { staging_table }
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Post -Path '/api/bdl-import/reset-alignment' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $body = $WebEvent.Data
        $stagingTable = $body.staging_table

        if (-not $stagingTable) {
            Write-PodeJsonResponse -Value @{ error = 'staging_table is required' } -StatusCode 400
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

        $safeTable = "Staging.[" + $stagingTable.Replace(']', ']]') + "]"

        $rowsReset = Invoke-XFActsNonQuery -Query @"
            UPDATE $safeTable SET _skip = 0 WHERE _skip = 1
"@

        # Get updated count
        $countResult = Invoke-XFActsQuery -Query @"
            SELECT COUNT(*) AS active_count FROM $safeTable WHERE _skip = 0
"@

        $activeCount = if ($countResult -and $countResult.Count -gt 0) { $countResult[0].active_count } else { 0 }

        Write-PodeJsonResponse -Value @{
            rows_reset   = $rowsReset
            active_count = $activeCount
            staging_table = $stagingTable
        }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ----------------------------------------------------------------------------
# GET /api/bdl-import/templates?entity_type=PHONE
# Returns active templates for a given entity type. Visible to all users.
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Get -Path '/api/bdl-import/templates' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $entityType = $WebEvent.Query['entity_type']
        if (-not $entityType) {
            Write-PodeJsonResponse -Value @{ error = 'entity_type parameter required' } -StatusCode 400
            return
        }

        $results = Invoke-XFActsQuery -Query @"
            SELECT template_id, entity_type, template_name, description,
                   column_mapping, created_by, created_dttm,
                   modified_by, modified_dttm
            FROM Tools.BDL_ImportTemplate
            WHERE entity_type = @entityType
              AND is_active = 1
            ORDER BY template_name
"@ -Parameters @{ entityType = $entityType }

        Write-PodeJsonResponse -Value @{ templates = @($results) }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ----------------------------------------------------------------------------
# POST /api/bdl-import/templates
# Save a new template. Any authenticated user can create.
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Post -Path '/api/bdl-import/templates' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $body = $WebEvent.Data
        $entityType = $body.entity_type
        $templateName = $body.template_name
        $description = $body.description
        $columnMapping = $body.column_mapping

        if (-not $entityType -or -not $templateName -or -not $columnMapping) {
            Write-PodeJsonResponse -Value @{ error = 'entity_type, template_name, and column_mapping are required' } -StatusCode 400
            return
        }

        $user = "FAC\$($WebEvent.Auth.User.Username)"

        # Check for duplicate name within entity type
        $existing = Invoke-XFActsQuery -Query @"
            SELECT template_id FROM Tools.BDL_ImportTemplate
            WHERE entity_type = @entityType AND template_name = @templateName AND is_active = 1
"@ -Parameters @{ entityType = $entityType; templateName = $templateName }

        if ($existing -and $existing.Count -gt 0) {
            Write-PodeJsonResponse -Value @{ error = "A template named '$templateName' already exists for this entity type." } -StatusCode 409
            return
        }

        $result = Invoke-XFActsQuery -Query @"
            INSERT INTO Tools.BDL_ImportTemplate
                (entity_type, template_name, description, column_mapping, created_by)
            OUTPUT INSERTED.template_id
            VALUES
                (@entityType, @templateName, @description, @columnMapping, @createdBy)
"@ -Parameters @{
            entityType    = $entityType
            templateName  = $templateName
            description   = if ($description) { $description } else { [DBNull]::Value }
            columnMapping = $columnMapping
            createdBy     = $user
        }

        $templateId = $result[0].template_id

        Write-PodeJsonResponse -Value @{
            success     = $true
            template_id = $templateId
            message     = "Template '$templateName' saved."
        }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ----------------------------------------------------------------------------
# PUT /api/bdl-import/templates/:id
# Update a template. Creator or admin only.
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Put -Path '/api/bdl-import/templates/:id' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $templateId = $WebEvent.Parameters['id']
        $body = $WebEvent.Data
        $user = "FAC\$($WebEvent.Auth.User.Username)"

        $existing = Invoke-XFActsQuery -Query @"
            SELECT template_id, created_by, entity_type
            FROM Tools.BDL_ImportTemplate
            WHERE template_id = @templateId AND is_active = 1
"@ -Parameters @{ templateId = $templateId }

        if (-not $existing -or $existing.Count -eq 0) {
            Write-PodeJsonResponse -Value @{ error = 'Template not found' } -StatusCode 404
            return
        }

        # Check ownership: creator or admin
        $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/bdl-import'
        $isOwner = ($existing[0].created_by -eq $user)
        if (-not $isOwner -and $access.Tier -ne 'admin') {
            Write-PodeJsonResponse -Value @{ error = 'Only the template creator or an admin can modify this template.' } -StatusCode 403
            return
        }

        # Build dynamic SET clause based on provided fields
        $setClauses = @("modified_by = @modifiedBy", "modified_dttm = GETDATE()")
        $params = @{ templateId = $templateId; modifiedBy = $user }

        if ($body.template_name) {
            # Check for duplicate name (excluding self)
            $dupCheck = Invoke-XFActsQuery -Query @"
                SELECT template_id FROM Tools.BDL_ImportTemplate
                WHERE entity_type = @entityType AND template_name = @templateName
                  AND template_id != @templateId AND is_active = 1
"@ -Parameters @{ entityType = $existing[0].entity_type; templateName = $body.template_name; templateId = $templateId }

            if ($dupCheck -and $dupCheck.Count -gt 0) {
                Write-PodeJsonResponse -Value @{ error = "A template named '$($body.template_name)' already exists for this entity type." } -StatusCode 409
                return
            }
            $setClauses += "template_name = @templateName"
            $params['templateName'] = $body.template_name
        }
        if ($null -ne $body.description) {
            $setClauses += "description = @description"
            $params['description'] = if ($body.description -eq '') { [DBNull]::Value } else { $body.description }
        }
        if ($body.column_mapping) {
            $setClauses += "column_mapping = @columnMapping"
            $params['columnMapping'] = $body.column_mapping
        }

        $updateSql = "UPDATE Tools.BDL_ImportTemplate SET " + ($setClauses -join ", ") + " WHERE template_id = @templateId"
        Invoke-XFActsNonQuery -Query $updateSql -Parameters $params

        Write-PodeJsonResponse -Value @{ success = $true; message = 'Template updated.' }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ----------------------------------------------------------------------------
# DELETE /api/bdl-import/templates/:id
# Soft-delete (deactivate) a template. Creator or admin only.
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Delete -Path '/api/bdl-import/templates/:id' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $templateId = $WebEvent.Parameters['id']
        $user = "FAC\$($WebEvent.Auth.User.Username)"

        $existing = Invoke-XFActsQuery -Query @"
            SELECT template_id, created_by
            FROM Tools.BDL_ImportTemplate
            WHERE template_id = @templateId AND is_active = 1
"@ -Parameters @{ templateId = $templateId }

        if (-not $existing -or $existing.Count -eq 0) {
            Write-PodeJsonResponse -Value @{ error = 'Template not found' } -StatusCode 404
            return
        }

        # Check ownership: creator or admin
        $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/bdl-import'
        $isOwner = ($existing[0].created_by -eq $user)
        if (-not $isOwner -and $access.Tier -ne 'admin') {
            Write-PodeJsonResponse -Value @{ error = 'Only the template creator or an admin can delete this template.' } -StatusCode 403
            return
        }

        Invoke-XFActsNonQuery -Query @"
            UPDATE Tools.BDL_ImportTemplate
            SET is_active = 0, modified_by = @modifiedBy, modified_dttm = GETDATE()
            WHERE template_id = @templateId
"@ -Parameters @{ templateId = $templateId; modifiedBy = $user }

        Write-PodeJsonResponse -Value @{ success = $true; message = 'Template deleted.' }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}
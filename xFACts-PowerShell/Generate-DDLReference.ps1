<#
.SYNOPSIS
    xFACts - DDL Reference Generator

.DESCRIPTION
    Generates comprehensive JSON reference documents containing all database
    object metadata across the xFACts platform. Writes individual JSON files
    per schema to the documentation directory. These JSON files are consumed
    by the documentation reference pages to dynamically render field tables,
    indexes, constraints, and descriptions without manual HTML maintenance.

    The inline SQL discovers schemas dynamically, extracts complete catalog
    metadata, enriches it with Object_Metadata content (descriptions, design
    notes, queries, status values, relationship notes), and returns multiple
    result sets (one per schema plus a metadata set). This script reads each
    result set using SqlDataReader and writes individual files.

.NOTES
    File Name      : Generate-DDLReference.ps1
    Location       : E:\xFACts-PowerShell
    Author         : Frost Arnett Applications Team
    Version        : Tracked in dbo.System_Metadata (component: Engine.SharedInfrastructure)

.PARAMETER ServerInstance
    SQL Server instance name for xFACts database (default: AVG-PROD-LSNR)

.PARAMETER Database
    Database name (default: xFACts)

.PARAMETER OutputDirectory
    Directory to write JSON files (default: E:\xFACts-ControlCenter\public\docs\data\ddl)

.PARAMETER Execute
    Required to actually write files. Without this flag, runs in preview mode
    showing what would be generated without writing anything.

================================================================================
CHANGELOG
================================================================================
2026-03-12  doc-registry.json: Removed doc_is_hub column reference. isHub now
            derived from doc_sort_order = 0 convention.
2026-03-11  Consolidated dbo.sp_GenerateDDLReference SQL inline into this script.
            Single file to maintain instead of proc + script. Proc can be dropped.
            Added sortOrder field to all enrichment subqueries (designNotes,
            statusValues, queries, relationshipNotes) across all object types.
            Added doc-registry.json export from Component_Registry doc_* columns.
            Groups by doc_page_id with nested sections for multi-component pages.
2026-02-26  Initial implementation
            Single SQL call with multiple result sets via SqlDataReader
            Individual JSON file output per schema
            Metadata file with generation timestamp
            Preview mode by default
================================================================================
#>

[CmdletBinding()]
param(
    [string]$ServerInstance = "AVG-PROD-LSNR",
    [string]$Database = "xFACts",
    [string]$OutputDirectory = "E:\xFACts-ControlCenter\public\docs\data\ddl",
    [switch]$Execute
)

$LogFile = "$PSScriptRoot\Logs\Generate-DDLReference_$(Get-Date -Format 'yyyyMMdd').log"

# ========================================
# FUNCTIONS
# ========================================

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"

    $color = switch ($Level) {
        "ERROR"   { "Red" }
        "WARN"    { "Yellow" }
        "SUCCESS" { "Green" }
        "DEBUG"   { "DarkGray" }
        default   { "White" }
    }
    Write-Host $logMessage -ForegroundColor $color

    $logDir = Split-Path $LogFile -Parent
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    Add-Content -Path $LogFile -Value $logMessage -ErrorAction SilentlyContinue
}

# ========================================
# MAIN
# ========================================

Write-Log "=========================================="
Write-Log "xFACts DDL Reference Generator"
Write-Log "=========================================="
Write-Log "Server: $ServerInstance"
Write-Log "Database: $Database"
Write-Log "Output: $OutputDirectory"
Write-Log "Mode: $(if ($Execute) { 'EXECUTE' } else { 'PREVIEW' })"
Write-Log "------------------------------------------"

# Validate output directory
if ($Execute) {
    if (-not (Test-Path $OutputDirectory)) {
        try {
            New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
            Write-Log "Created output directory: $OutputDirectory"
        }
        catch {
            Write-Log "Failed to create output directory: $($_.Exception.Message)" "ERROR"
            exit 1
        }
    }
}

# ========================================
# DDL Reference SQL (inline - formerly dbo.sp_GenerateDDLReference)
# ========================================

$sqlQuery = @"
    SET NOCOUNT ON;

    -- =========================================================================
    -- Discover active schemas containing user objects
    -- =========================================================================

    CREATE TABLE #ActiveSchemas (
        schema_id   INT,
        schema_name SYSNAME
    );

    -- Schemas with database objects
    INSERT INTO #ActiveSchemas (schema_id, schema_name)
    SELECT DISTINCT s.schema_id, s.name
    FROM sys.schemas s
    INNER JOIN sys.objects o ON s.schema_id = o.schema_id
    WHERE o.type IN ('U', 'P', 'TR', 'FN', 'IF', 'TF', 'V')
      AND o.is_ms_shipped = 0
      AND s.name NOT IN ('sys', 'INFORMATION_SCHEMA', 'guest', 'Legacy')
      AND o.name NOT LIKE 'sp_MS%'
      AND o.name NOT LIKE 'fn_MS%'
      AND o.name NOT LIKE 'sp_diagram%'
      AND o.name NOT LIKE 'sysdiagram%';

    -- Also include schemas that have Script entries in Object_Metadata
    -- (handles the edge case of a schema with only scripts and no DB objects)
    INSERT INTO #ActiveSchemas (schema_id, schema_name)
    SELECT DISTINCT 0, om.schema_name
    FROM dbo.Object_Metadata om
    WHERE om.object_type IN ('Script', 'XE Session', 'DDL Trigger')
      AND om.property_type = 'description'
      AND om.is_active = 1
      AND om.schema_name NOT IN (SELECT schema_name FROM #ActiveSchemas);

    -- =========================================================================
    -- Iterate each schema - emit one result set per schema
    -- =========================================================================

    DECLARE @schemaName SYSNAME;
    DECLARE @schemaId INT;
    DECLARE @schemaJson NVARCHAR(MAX);

    DECLARE schema_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT schema_id, schema_name FROM #ActiveSchemas ORDER BY schema_name;

    OPEN schema_cursor;
    FETCH NEXT FROM schema_cursor INTO @schemaId, @schemaName;

    WHILE @@FETCH_STATUS = 0
    BEGIN

        -- -----------------------------------------------------------------
        -- TABLES
        -- -----------------------------------------------------------------
        DECLARE @tablesJson NVARCHAR(MAX) = '';

        SELECT @tablesJson = (
            SELECT
                t.name AS [name],
                -- Object description from Object_Metadata
                (
                    SELECT TOP 1 om.content
                    FROM dbo.Object_Metadata om
                    WHERE om.schema_name = @schemaName
                      AND om.object_name = t.name
                      AND om.property_type = 'description'
                      AND om.column_name IS NULL
                      AND om.is_active = 1
                ) AS [description],
                -- Module
                (
                    SELECT TOP 1 om.content
                    FROM dbo.Object_Metadata om
                    WHERE om.schema_name = @schemaName
                      AND om.object_name = t.name
                      AND om.property_type = 'module'
                      AND om.is_active = 1
                ) AS [module],
                -- Category
                (
                    SELECT TOP 1 om.content
                    FROM dbo.Object_Metadata om
                    WHERE om.schema_name = @schemaName
                      AND om.object_name = t.name
                      AND om.property_type = 'category'
                      AND om.is_active = 1
                ) AS [category],
                -- Data Flow
                (
                    SELECT TOP 1 om.content
                    FROM dbo.Object_Metadata om
                    WHERE om.schema_name = @schemaName
                      AND om.object_name = t.name
                      AND om.property_type = 'data_flow'
                      AND om.is_active = 1
                ) AS [dataFlow],
                -- Columns (structural from sys.columns, descriptions from Object_Metadata)
                (
                    SELECT
                        c.column_id         AS [ordinal],
                        c.name              AS [name],
                        TYPE_NAME(c.user_type_id) AS [dataType],
                        CASE
                            WHEN TYPE_NAME(c.user_type_id) IN ('varchar', 'nvarchar', 'char', 'nchar', 'varbinary', 'binary')
                                THEN CASE WHEN c.max_length = -1 THEN 'MAX'
                                     WHEN TYPE_NAME(c.user_type_id) IN ('nvarchar', 'nchar')
                                         THEN CAST(c.max_length / 2 AS VARCHAR(10))
                                     ELSE CAST(c.max_length AS VARCHAR(10))
                                END
                            WHEN TYPE_NAME(c.user_type_id) IN ('decimal', 'numeric')
                                THEN CAST(c.precision AS VARCHAR(10)) + ',' + CAST(c.scale AS VARCHAR(10))
                            ELSE NULL
                        END                 AS [length],
                        c.is_nullable       AS [nullable],
                        c.is_identity       AS [identity],
                        dc.definition       AS [default],
                        (
                            SELECT TOP 1 om.content
                            FROM dbo.Object_Metadata om
                            WHERE om.schema_name = @schemaName
                              AND om.object_name = t.name
                              AND om.column_name = c.name
                              AND om.property_type = 'description'
                              AND om.is_active = 1
                        ) AS [description]
                    FROM sys.columns c
                    LEFT JOIN sys.default_constraints dc
                        ON c.default_object_id = dc.object_id
                    WHERE c.object_id = t.object_id
                    ORDER BY c.column_id
                    FOR JSON PATH
                ) AS [columns],
                -- Indexes
                (
                    SELECT
                        i.name              AS [name],
                        i.type_desc         AS [type],
                        i.is_unique         AS [isUnique],
                        i.is_primary_key    AS [isPrimaryKey],
                        i.is_unique_constraint AS [isUniqueConstraint],
                        (
                            SELECT STRING_AGG(c2.name, ', ')
                                WITHIN GROUP (ORDER BY ic.key_ordinal)
                            FROM sys.index_columns ic
                            JOIN sys.columns c2
                                ON ic.object_id = c2.object_id
                               AND ic.column_id = c2.column_id
                            WHERE ic.object_id = i.object_id
                              AND ic.index_id = i.index_id
                              AND ic.is_included_column = 0
                        ) AS [keyColumns],
                        (
                            SELECT STRING_AGG(c3.name, ', ')
                                WITHIN GROUP (ORDER BY ic2.index_column_id)
                            FROM sys.index_columns ic2
                            JOIN sys.columns c3
                                ON ic2.object_id = c3.object_id
                               AND ic2.column_id = c3.column_id
                            WHERE ic2.object_id = i.object_id
                              AND ic2.index_id = i.index_id
                              AND ic2.is_included_column = 1
                        ) AS [includedColumns]
                    FROM sys.indexes i
                    WHERE i.object_id = t.object_id
                      AND i.type > 0
                    ORDER BY i.is_primary_key DESC, i.name
                    FOR JSON PATH
                ) AS [indexes],
                -- Check constraints
                (
                    SELECT
                        cc.name             AS [name],
                        cc.definition       AS [definition]
                    FROM sys.check_constraints cc
                    WHERE cc.parent_object_id = t.object_id
                    ORDER BY cc.name
                    FOR JSON PATH
                ) AS [checkConstraints],
                -- Foreign keys
                (
                    SELECT
                        fk.name             AS [name],
                        COL_NAME(fkc.parent_object_id, fkc.parent_column_id) AS [column],
                        SCHEMA_NAME(rt.schema_id) + '.' + rt.name AS [referencedTable],
                        COL_NAME(fkc.referenced_object_id, fkc.referenced_column_id) AS [referencedColumn]
                    FROM sys.foreign_keys fk
                    JOIN sys.foreign_key_columns fkc
                        ON fk.object_id = fkc.constraint_object_id
                    JOIN sys.tables rt
                        ON fk.referenced_object_id = rt.object_id
                    WHERE fk.parent_object_id = t.object_id
                    ORDER BY fk.name
                    FOR JSON PATH
                ) AS [foreignKeys],
                -- Design Notes (enrichment)
                (
                    SELECT
                        om.title            AS [topic],
                        om.description      AS [summary],
                        om.content          AS [note],
                        om.sort_order       AS [sortOrder]
                    FROM dbo.Object_Metadata om
                    WHERE om.schema_name = @schemaName
                      AND om.object_name = t.name
                      AND om.property_type = 'design_note'
                      AND om.is_active = 1
                    ORDER BY om.sort_order
                    FOR JSON PATH
                ) AS [designNotes],
                -- Status Values (enrichment)
                (
                    SELECT
                        om.column_name      AS [column],
                        om.title            AS [value],
                        om.content          AS [meaning],
                        om.sort_order       AS [sortOrder]
                    FROM dbo.Object_Metadata om
                    WHERE om.schema_name = @schemaName
                      AND om.object_name = t.name
                      AND om.property_type = 'status_value'
                      AND om.is_active = 1
                    ORDER BY om.sort_order
                    FOR JSON PATH
                ) AS [statusValues],
                -- Common Queries (enrichment)
                (
                    SELECT
                        om.title            AS [name],
                        om.description      AS [description],
                        om.content          AS [sql],
                        om.sort_order       AS [sortOrder]
                    FROM dbo.Object_Metadata om
                    WHERE om.schema_name = @schemaName
                      AND om.object_name = t.name
                      AND om.property_type = 'query'
                      AND om.is_active = 1
                    ORDER BY om.sort_order
                    FOR JSON PATH
                ) AS [queries],
                -- Relationship Notes (enrichment)
                (
                    SELECT
                        om.title            AS [relatedObject],
                        om.content          AS [note],
                        om.sort_order       AS [sortOrder]
                    FROM dbo.Object_Metadata om
                    WHERE om.schema_name = @schemaName
                      AND om.object_name = t.name
                      AND om.property_type = 'relationship_note'
                      AND om.is_active = 1
                    ORDER BY om.sort_order
                    FOR JSON PATH
                ) AS [relationshipNotes]
            FROM sys.tables t
            WHERE SCHEMA_NAME(t.schema_id) = @schemaName
              AND t.name NOT LIKE 'sysdiagram%'
            ORDER BY t.name
            FOR JSON PATH
        );

        -- -----------------------------------------------------------------
        -- PROCEDURES
        -- -----------------------------------------------------------------
        DECLARE @procsJson NVARCHAR(MAX) = '';

        SELECT @procsJson = (
            SELECT
                p.name AS [name],
                (
                    SELECT TOP 1 om.content
                    FROM dbo.Object_Metadata om
                    WHERE om.schema_name = @schemaName
                      AND om.object_name = p.name
                      AND om.property_type = 'description'
                      AND om.column_name IS NULL
                      AND om.is_active = 1
                ) AS [description],
                -- Module
                (
                    SELECT TOP 1 om.content
                    FROM dbo.Object_Metadata om
                    WHERE om.schema_name = @schemaName
                      AND om.object_name = p.name
                      AND om.property_type = 'module'
                      AND om.is_active = 1
                ) AS [module],
                -- Category
                (
                    SELECT TOP 1 om.content
                    FROM dbo.Object_Metadata om
                    WHERE om.schema_name = @schemaName
                      AND om.object_name = p.name
                      AND om.property_type = 'category'
                      AND om.is_active = 1
                ) AS [category],
                -- Data Flow (enrichment)
                (
                    SELECT TOP 1 om.content
                    FROM dbo.Object_Metadata om
                    WHERE om.schema_name = @schemaName
                      AND om.object_name = p.name
                      AND om.property_type = 'data_flow'
                      AND om.is_active = 1
                ) AS [dataFlow],
                -- Parameters (structural from sys.parameters)
                (
                    SELECT
                        pm.parameter_id     AS [ordinal],
                        pm.name             AS [name],
                        TYPE_NAME(pm.user_type_id) AS [dataType],
                        CASE
                            WHEN TYPE_NAME(pm.user_type_id) IN ('varchar', 'nvarchar', 'char', 'nchar')
                                THEN CASE WHEN pm.max_length = -1 THEN 'MAX'
                                     WHEN TYPE_NAME(pm.user_type_id) IN ('nvarchar', 'nchar')
                                         THEN CAST(pm.max_length / 2 AS VARCHAR(10))
                                     ELSE CAST(pm.max_length AS VARCHAR(10))
                                END
                            WHEN TYPE_NAME(pm.user_type_id) IN ('decimal', 'numeric')
                                THEN CAST(pm.precision AS VARCHAR(10)) + ',' + CAST(pm.scale AS VARCHAR(10))
                            ELSE NULL
                        END                 AS [length],
                        pm.is_output        AS [isOutput],
                        pm.has_default_value AS [isOptional]
                    FROM sys.parameters pm
                    WHERE pm.object_id = p.object_id
                      AND pm.parameter_id > 0
                    ORDER BY pm.parameter_id
                    FOR JSON PATH
                ) AS [parameters],
                -- Design Notes (enrichment)
                (
                    SELECT
                        om.title            AS [topic],
                        om.description      AS [summary],
                        om.content          AS [note],
                        om.sort_order       AS [sortOrder]
                    FROM dbo.Object_Metadata om
                    WHERE om.schema_name = @schemaName
                      AND om.object_name = p.name
                      AND om.property_type = 'design_note'
                      AND om.is_active = 1
                    ORDER BY om.sort_order
                    FOR JSON PATH
                ) AS [designNotes],
                -- Relationship Notes (enrichment)
                (
                    SELECT
                        om.title            AS [relatedObject],
                        om.content          AS [note],
                        om.sort_order       AS [sortOrder]
                    FROM dbo.Object_Metadata om
                    WHERE om.schema_name = @schemaName
                      AND om.object_name = p.name
                      AND om.property_type = 'relationship_note'
                      AND om.is_active = 1
                    ORDER BY om.sort_order
                    FOR JSON PATH
                ) AS [relationshipNotes]
            FROM sys.procedures p
            WHERE SCHEMA_NAME(p.schema_id) = @schemaName
              AND p.name NOT LIKE 'sp_MS%'
              AND p.name NOT LIKE 'sp_diagram%'
            ORDER BY p.name
            FOR JSON PATH
        );

        -- -----------------------------------------------------------------
        -- TRIGGERS
        -- -----------------------------------------------------------------
        DECLARE @triggersJson NVARCHAR(MAX) = '';

        SELECT @triggersJson = (
            SELECT
                tr.name AS [name],
                OBJECT_NAME(tr.parent_id) AS [parentTable],
                (
                    SELECT TOP 1 om.content
                    FROM dbo.Object_Metadata om
                    WHERE om.schema_name = @schemaName
                      AND om.object_name = tr.name
                      AND om.property_type = 'description'
                      AND om.column_name IS NULL
                      AND om.is_active = 1
                ) AS [description],
                -- Module
                (
                    SELECT TOP 1 om.content
                    FROM dbo.Object_Metadata om
                    WHERE om.schema_name = @schemaName
                      AND om.object_name = tr.name
                      AND om.property_type = 'module'
                      AND om.is_active = 1
                ) AS [module],
                -- Category
                (
                    SELECT TOP 1 om.content
                    FROM dbo.Object_Metadata om
                    WHERE om.schema_name = @schemaName
                      AND om.object_name = tr.name
                      AND om.property_type = 'category'
                      AND om.is_active = 1
                ) AS [category],
                CASE WHEN OBJECTPROPERTY(tr.object_id, 'ExecIsInsertTrigger') = 1 THEN 1 ELSE 0 END AS [firesOnInsert],
                CASE WHEN OBJECTPROPERTY(tr.object_id, 'ExecIsUpdateTrigger') = 1 THEN 1 ELSE 0 END AS [firesOnUpdate],
                CASE WHEN OBJECTPROPERTY(tr.object_id, 'ExecIsDeleteTrigger') = 1 THEN 1 ELSE 0 END AS [firesOnDelete],
                CASE WHEN tr.is_disabled = 0 THEN 1 ELSE 0 END AS [isEnabled],
                -- Design Notes (enrichment)
                (
                    SELECT
                        om.title            AS [topic],
                        om.description      AS [summary],
                        om.content          AS [note],
                        om.sort_order       AS [sortOrder]
                    FROM dbo.Object_Metadata om
                    WHERE om.schema_name = @schemaName
                      AND om.object_name = tr.name
                      AND om.property_type = 'design_note'
                      AND om.is_active = 1
                    ORDER BY om.sort_order
                    FOR JSON PATH
                ) AS [designNotes],
                -- Relationship Notes (enrichment)
                (
                    SELECT
                        om.title            AS [relatedObject],
                        om.content          AS [note],
                        om.sort_order       AS [sortOrder]
                    FROM dbo.Object_Metadata om
                    WHERE om.schema_name = @schemaName
                      AND om.object_name = tr.name
                      AND om.property_type = 'relationship_note'
                      AND om.is_active = 1
                    ORDER BY om.sort_order
                    FOR JSON PATH
                ) AS [relationshipNotes]
            FROM sys.triggers tr
            JOIN sys.tables t ON tr.parent_id = t.object_id
            WHERE SCHEMA_NAME(t.schema_id) = @schemaName
            ORDER BY tr.name
            FOR JSON PATH
        );

        -- -----------------------------------------------------------------
        -- FUNCTIONS
        -- -----------------------------------------------------------------
        DECLARE @functionsJson NVARCHAR(MAX) = '';

        SELECT @functionsJson = (
            SELECT
                o.name AS [name],
                CASE o.type
                    WHEN 'FN' THEN 'Scalar'
                    WHEN 'IF' THEN 'Inline Table-Valued'
                    WHEN 'TF' THEN 'Multi-Statement Table-Valued'
                END AS [functionType],
                (
                    SELECT TOP 1 om.content
                    FROM dbo.Object_Metadata om
                    WHERE om.schema_name = @schemaName
                      AND om.object_name = o.name
                      AND om.property_type = 'description'
                      AND om.column_name IS NULL
                      AND om.is_active = 1
                ) AS [description],
                -- Module
                (
                    SELECT TOP 1 om.content
                    FROM dbo.Object_Metadata om
                    WHERE om.schema_name = @schemaName
                      AND om.object_name = o.name
                      AND om.property_type = 'module'
                      AND om.is_active = 1
                ) AS [module],
                -- Category
                (
                    SELECT TOP 1 om.content
                    FROM dbo.Object_Metadata om
                    WHERE om.schema_name = @schemaName
                      AND om.object_name = o.name
                      AND om.property_type = 'category'
                      AND om.is_active = 1
                ) AS [category],
                (
                    SELECT
                        pm.parameter_id     AS [ordinal],
                        pm.name             AS [name],
                        TYPE_NAME(pm.user_type_id) AS [dataType],
                        CASE
                            WHEN TYPE_NAME(pm.user_type_id) IN ('varchar', 'nvarchar', 'char', 'nchar')
                                THEN CASE WHEN pm.max_length = -1 THEN 'MAX'
                                     WHEN TYPE_NAME(pm.user_type_id) IN ('nvarchar', 'nchar')
                                         THEN CAST(pm.max_length / 2 AS VARCHAR(10))
                                     ELSE CAST(pm.max_length AS VARCHAR(10))
                                END
                            ELSE NULL
                        END                 AS [length],
                        pm.is_output        AS [isOutput],
                        pm.has_default_value AS [isOptional]
                    FROM sys.parameters pm
                    WHERE pm.object_id = o.object_id
                      AND pm.parameter_id > 0
                    ORDER BY pm.parameter_id
                    FOR JSON PATH
                ) AS [parameters]
            FROM sys.objects o
            WHERE SCHEMA_NAME(o.schema_id) = @schemaName
              AND o.type IN ('FN', 'IF', 'TF')
              AND o.is_ms_shipped = 0
              AND o.name NOT LIKE 'fn_MS%'
            ORDER BY o.name
            FOR JSON PATH
        );

        -- -----------------------------------------------------------------
        -- VIEWS
        -- -----------------------------------------------------------------
        DECLARE @viewsJson NVARCHAR(MAX) = '';

        SELECT @viewsJson = (
            SELECT
                v.name AS [name],
                -- Description
                (
                    SELECT TOP 1 om.content
                    FROM dbo.Object_Metadata om
                    WHERE om.schema_name = @schemaName
                      AND om.object_name = v.name
                      AND om.property_type = 'description'
                      AND om.column_name IS NULL
                      AND om.is_active = 1
                ) AS [description],
                -- Module
                (
                    SELECT TOP 1 om.content
                    FROM dbo.Object_Metadata om
                    WHERE om.schema_name = @schemaName
                      AND om.object_name = v.name
                      AND om.property_type = 'module'
                      AND om.is_active = 1
                ) AS [module],
                -- Category
                (
                    SELECT TOP 1 om.content
                    FROM dbo.Object_Metadata om
                    WHERE om.schema_name = @schemaName
                      AND om.object_name = v.name
                      AND om.property_type = 'category'
                      AND om.is_active = 1
                ) AS [category],
                (
                    SELECT
                        c.column_id         AS [ordinal],
                        c.name              AS [name],
                        TYPE_NAME(c.user_type_id) AS [dataType],
                        CASE
                            WHEN TYPE_NAME(c.user_type_id) IN ('varchar', 'nvarchar', 'char', 'nchar')
                                THEN CASE WHEN c.max_length = -1 THEN 'MAX'
                                     WHEN TYPE_NAME(c.user_type_id) IN ('nvarchar', 'nchar')
                                         THEN CAST(c.max_length / 2 AS VARCHAR(10))
                                     ELSE CAST(c.max_length AS VARCHAR(10))
                                END
                            ELSE NULL
                        END                 AS [length],
                        c.is_nullable       AS [nullable]
                    FROM sys.columns c
                    WHERE c.object_id = v.object_id
                    ORDER BY c.column_id
                    FOR JSON PATH
                ) AS [columns]
            FROM sys.views v
            WHERE SCHEMA_NAME(v.schema_id) = @schemaName
            ORDER BY v.name
            FOR JSON PATH
        );

        -- -----------------------------------------------------------------
        -- SCRIPTS (from Object_Metadata only - no sys.objects equivalent)
        -- -----------------------------------------------------------------
        DECLARE @scriptsJson NVARCHAR(MAX) = '';

        SELECT @scriptsJson = (
            SELECT
                s.object_name AS [name],
                -- Description
                (
                    SELECT TOP 1 om.content
                    FROM dbo.Object_Metadata om
                    WHERE om.schema_name = @schemaName
                      AND om.object_name = s.object_name
                      AND om.property_type = 'description'
                      AND om.column_name IS NULL
                      AND om.is_active = 1
                ) AS [description],
                -- Module
                (
                    SELECT TOP 1 om.content
                    FROM dbo.Object_Metadata om
                    WHERE om.schema_name = @schemaName
                      AND om.object_name = s.object_name
                      AND om.property_type = 'module'
                      AND om.is_active = 1
                ) AS [module],
                -- Category
                (
                    SELECT TOP 1 om.content
                    FROM dbo.Object_Metadata om
                    WHERE om.schema_name = @schemaName
                      AND om.object_name = s.object_name
                      AND om.property_type = 'category'
                      AND om.is_active = 1
                ) AS [category],
                -- Data Flow
                (
                    SELECT TOP 1 om.content
                    FROM dbo.Object_Metadata om
                    WHERE om.schema_name = @schemaName
                      AND om.object_name = s.object_name
                      AND om.property_type = 'data_flow'
                      AND om.is_active = 1
                ) AS [dataFlow],
                -- Design Notes
                (
                    SELECT
                        om.title            AS [topic],
                        om.description      AS [summary],
                        om.content          AS [note],
                        om.sort_order       AS [sortOrder]
                    FROM dbo.Object_Metadata om
                    WHERE om.schema_name = @schemaName
                      AND om.object_name = s.object_name
                      AND om.property_type = 'design_note'
                      AND om.is_active = 1
                    ORDER BY om.sort_order
                    FOR JSON PATH
                ) AS [designNotes],
                -- Relationship Notes
                (
                    SELECT
                        om.title            AS [relatedObject],
                        om.content          AS [note],
                        om.sort_order       AS [sortOrder]
                    FROM dbo.Object_Metadata om
                    WHERE om.schema_name = @schemaName
                      AND om.object_name = s.object_name
                      AND om.property_type = 'relationship_note'
                      AND om.is_active = 1
                    ORDER BY om.sort_order
                    FOR JSON PATH
                ) AS [relationshipNotes]
            FROM (
                -- Get distinct script names in this schema
                SELECT DISTINCT object_name
                FROM dbo.Object_Metadata
                WHERE schema_name = @schemaName
                  AND object_type = 'Script'
                  AND is_active = 1
            ) s
            ORDER BY s.object_name
            FOR JSON PATH
        );

        -- -----------------------------------------------------------------
        -- XE SESSIONS (from Object_Metadata only - no sys.objects equivalent)
        -- -----------------------------------------------------------------
        DECLARE @xeSessionsJson NVARCHAR(MAX) = '';

        SELECT @xeSessionsJson = (
            SELECT
                x.object_name AS [name],
                -- Description
                (
                    SELECT TOP 1 om.content
                    FROM dbo.Object_Metadata om
                    WHERE om.schema_name = @schemaName
                      AND om.object_name = x.object_name
                      AND om.property_type = 'description'
                      AND om.column_name IS NULL
                      AND om.is_active = 1
                ) AS [description],
                -- Module
                (
                    SELECT TOP 1 om.content
                    FROM dbo.Object_Metadata om
                    WHERE om.schema_name = @schemaName
                      AND om.object_name = x.object_name
                      AND om.property_type = 'module'
                      AND om.is_active = 1
                ) AS [module],
                -- Category
                (
                    SELECT TOP 1 om.content
                    FROM dbo.Object_Metadata om
                    WHERE om.schema_name = @schemaName
                      AND om.object_name = x.object_name
                      AND om.property_type = 'category'
                      AND om.is_active = 1
                ) AS [category],
                -- Data Flow
                (
                    SELECT TOP 1 om.content
                    FROM dbo.Object_Metadata om
                    WHERE om.schema_name = @schemaName
                      AND om.object_name = x.object_name
                      AND om.property_type = 'data_flow'
                      AND om.is_active = 1
                ) AS [dataFlow],
                -- Design Notes
                (
                    SELECT
                        om.title            AS [topic],
                        om.description      AS [summary],
                        om.content          AS [note],
                        om.sort_order       AS [sortOrder]
                    FROM dbo.Object_Metadata om
                    WHERE om.schema_name = @schemaName
                      AND om.object_name = x.object_name
                      AND om.property_type = 'design_note'
                      AND om.is_active = 1
                    ORDER BY om.sort_order
                    FOR JSON PATH
                ) AS [designNotes],
                -- Common Queries
                (
                    SELECT
                        om.title            AS [name],
                        om.description      AS [description],
                        om.content          AS [sql],
                        om.sort_order       AS [sortOrder]
                    FROM dbo.Object_Metadata om
                    WHERE om.schema_name = @schemaName
                      AND om.object_name = x.object_name
                      AND om.property_type = 'query'
                      AND om.is_active = 1
                    ORDER BY om.sort_order
                    FOR JSON PATH
                ) AS [queries],
                -- Relationship Notes
                (
                    SELECT
                        om.title            AS [relatedObject],
                        om.content          AS [note],
                        om.sort_order       AS [sortOrder]
                    FROM dbo.Object_Metadata om
                    WHERE om.schema_name = @schemaName
                      AND om.object_name = x.object_name
                      AND om.property_type = 'relationship_note'
                      AND om.is_active = 1
                    ORDER BY om.sort_order
                    FOR JSON PATH
                ) AS [relationshipNotes]
            FROM (
                -- Get distinct XE Session names in this schema
                SELECT DISTINCT object_name
                FROM dbo.Object_Metadata
                WHERE schema_name = @schemaName
                  AND object_type = 'XE Session'
                  AND is_active = 1
            ) x
            ORDER BY x.object_name
            FOR JSON PATH
        );

       -- -----------------------------------------------------------------
        -- DDL TRIGGERS (from Object_Metadata only — database-level triggers
        -- not captured by the sys.triggers / sys.tables join above)
        -- -----------------------------------------------------------------
        DECLARE @ddlTriggersJson NVARCHAR(MAX) = '';

        SELECT @ddlTriggersJson = (
            SELECT
                d.object_name AS [name],
                -- Description
                (
                    SELECT TOP 1 om.content
                    FROM dbo.Object_Metadata om
                    WHERE om.schema_name = @schemaName
                      AND om.object_name = d.object_name
                      AND om.property_type = 'description'
                      AND om.column_name IS NULL
                      AND om.is_active = 1
                ) AS [description],
                -- Module
                (
                    SELECT TOP 1 om.content
                    FROM dbo.Object_Metadata om
                    WHERE om.schema_name = @schemaName
                      AND om.object_name = d.object_name
                      AND om.property_type = 'module'
                      AND om.is_active = 1
                ) AS [module],
                -- Category
                (
                    SELECT TOP 1 om.content
                    FROM dbo.Object_Metadata om
                    WHERE om.schema_name = @schemaName
                      AND om.object_name = d.object_name
                      AND om.property_type = 'category'
                      AND om.is_active = 1
                ) AS [category],
                -- Data Flow
                (
                    SELECT TOP 1 om.content
                    FROM dbo.Object_Metadata om
                    WHERE om.schema_name = @schemaName
                      AND om.object_name = d.object_name
                      AND om.property_type = 'data_flow'
                      AND om.is_active = 1
                ) AS [dataFlow],
                -- Design Notes
                (
                    SELECT
                        om.title            AS [topic],
                        om.description      AS [summary],
                        om.content          AS [note],
                        om.sort_order       AS [sortOrder]
                    FROM dbo.Object_Metadata om
                    WHERE om.schema_name = @schemaName
                      AND om.object_name = d.object_name
                      AND om.property_type = 'design_note'
                      AND om.is_active = 1
                    ORDER BY om.sort_order
                    FOR JSON PATH
                ) AS [designNotes],
                -- Relationship Notes
                (
                    SELECT
                        om.title            AS [relatedObject],
                        om.content          AS [note],
                        om.sort_order       AS [sortOrder]
                    FROM dbo.Object_Metadata om
                    WHERE om.schema_name = @schemaName
                      AND om.object_name = d.object_name
                      AND om.property_type = 'relationship_note'
                      AND om.is_active = 1
                    ORDER BY om.sort_order
                    FOR JSON PATH
                ) AS [relationshipNotes]
            FROM (
                SELECT DISTINCT object_name
                FROM dbo.Object_Metadata
                WHERE schema_name = @schemaName
                  AND object_type = 'DDL Trigger'
                  AND is_active = 1
            ) d
            ORDER BY d.object_name
            FOR JSON PATH
        );

        -- -----------------------------------------------------------------
        -- Assemble and emit this schema's result set
        -- -----------------------------------------------------------------
        SET @schemaJson = '{';
        SET @schemaJson = @schemaJson + '"tables":' + ISNULL(@tablesJson, '[]') + ',';
        SET @schemaJson = @schemaJson + '"procedures":' + ISNULL(@procsJson, '[]') + ',';
        SET @schemaJson = @schemaJson + '"triggers":' + ISNULL(@triggersJson, '[]') + ',';
        SET @schemaJson = @schemaJson + '"functions":' + ISNULL(@functionsJson, '[]') + ',';
        SET @schemaJson = @schemaJson + '"views":' + ISNULL(@viewsJson, '[]') + ',';
        SET @schemaJson = @schemaJson + '"scripts":' + ISNULL(@scriptsJson, '[]') + ',';
        SET @schemaJson = @schemaJson + '"xeSessions":' + ISNULL(@xeSessionsJson, '[]') + ',';
        SET @schemaJson = @schemaJson + '"ddlTriggers":' + ISNULL(@ddlTriggersJson, '[]');
        SET @schemaJson = @schemaJson + '}';

        -- Emit one result set for this schema
        SELECT @schemaName AS SchemaName, @schemaJson AS SchemaJson;

        FETCH NEXT FROM schema_cursor INTO @schemaId, @schemaName;
    END;

    CLOSE schema_cursor;
    DEALLOCATE schema_cursor;

    -- =========================================================================
    -- Final result set: metadata
    -- =========================================================================
    SELECT
        '_metadata' AS SchemaName,
        '{' +
            '"generated":"' + CONVERT(VARCHAR(30), GETDATE(), 127) + '",' +
            '"database":"' + DB_NAME() + '",' +
            '"server":"' + @@SERVERNAME + '"' +
        '}' AS SchemaJson;

    DROP TABLE #ActiveSchemas;
"@

# ========================================
# Execute SQL and read multiple result sets
# ========================================

$schemasWritten = @()
$connectionString = "Server=$ServerInstance;Database=$Database;Integrated Security=True;TrustServerCertificate=True;Application Name=xFACts Generate-DDLReference"

try {
    $connection = New-Object System.Data.SqlClient.SqlConnection($connectionString)
    $connection.Open()
    Write-Log "Connected to $ServerInstance/$Database"

    $command = $connection.CreateCommand()
    $command.CommandText = $sqlQuery
    $command.CommandTimeout = 120

    $reader = $command.ExecuteReader()

    $hasResults = $true
    while ($hasResults) {
        if ($reader.Read()) {
            $schemaName = $reader["SchemaName"]
            $schemaJson = $reader["SchemaJson"]

            if ($schemaName -eq '_metadata') {
                # Write metadata file
                Write-Log "Metadata: $schemaJson" "DEBUG"

                if ($Execute) {
                    $metadataPath = Join-Path $OutputDirectory "_metadata.json"
                    $schemaJson | Out-File -FilePath $metadataPath -Encoding UTF8 -Force
                    Write-Log "Wrote: _metadata.json" "SUCCESS"
                }
                else {
                    Write-Log "[PREVIEW] Would write: _metadata.json"
                }
            }
            else {
                # Format JSON for readability
                try {
                    $parsed = $schemaJson | ConvertFrom-Json
                    $formatted = $parsed | ConvertTo-Json -Depth 20 -Compress:$false
                }
                catch {
                    # If parsing fails, write raw JSON
                    Write-Log "JSON formatting failed for $schemaName, writing raw" "WARN"
                    $formatted = $schemaJson
                }

                # Count objects for logging
                $tableCount = 0
                $procCount = 0
                $triggerCount = 0
                $functionCount = 0
                $viewCount = 0

                if ($parsed.tables) { $tableCount = @($parsed.tables).Count }
                if ($parsed.procedures) { $procCount = @($parsed.procedures).Count }
                if ($parsed.triggers) { $triggerCount = @($parsed.triggers).Count }
                if ($parsed.functions) { $functionCount = @($parsed.functions).Count }
                if ($parsed.views) { $viewCount = @($parsed.views).Count }

                $objectSummary = @()
                if ($tableCount -gt 0) { $objectSummary += "$tableCount tables" }
                if ($procCount -gt 0) { $objectSummary += "$procCount procedures" }
                if ($triggerCount -gt 0) { $objectSummary += "$triggerCount triggers" }
                if ($functionCount -gt 0) { $objectSummary += "$functionCount functions" }
                if ($viewCount -gt 0) { $objectSummary += "$viewCount views" }
                $summary = $objectSummary -join ", "

                if ($Execute) {
                    $filePath = Join-Path $OutputDirectory "$schemaName.json"
                    $formatted | Out-File -FilePath $filePath -Encoding UTF8 -Force
                    Write-Log "Wrote: $schemaName.json ($summary)" "SUCCESS"
                }
                else {
                    Write-Log "[PREVIEW] Would write: $schemaName.json ($summary)"
                }

                $schemasWritten += $schemaName
            }
        }

        $hasResults = $reader.NextResult()
    }

    $reader.Close()
    $connection.Close()
}
catch {
    Write-Log "Database error: $($_.Exception.Message)" "ERROR"
    if ($connection -and $connection.State -eq 'Open') { $connection.Close() }
    exit 1
}

# ========================================
# Doc Registry Export (doc-registry.json)
# Queries Component_Registry for documentation page metadata.
# Groups by doc_page_id, nests component sections for multi-component pages.
# ========================================

$docRegistryPath = Join-Path $OutputDirectory "doc-registry.json"

Write-Log "------------------------------------------"
Write-Log "Generating doc-registry.json..."

try {
    $docConnection = New-Object System.Data.SqlClient.SqlConnection($connectionString)
    $docConnection.Open()

    $docQuery = @"
        SELECT
            cr.component_name,
            cr.description,
            cr.doc_page_id,
            cr.doc_title,
            cr.doc_json_schema,
            cr.doc_json_categories,
            cr.doc_cc_slug,
            cr.doc_sort_order,
            cr.doc_section_order
        FROM dbo.Component_Registry cr
        WHERE cr.doc_page_id IS NOT NULL
          AND cr.is_active = 1
        ORDER BY
            ISNULL(cr.doc_sort_order, 999),
            cr.doc_section_order
"@

    $docCmd = $docConnection.CreateCommand()
    $docCmd.CommandText = $docQuery
    $docCmd.CommandTimeout = 30

    $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($docCmd)
    $dataTable = New-Object System.Data.DataTable
    $adapter.Fill($dataTable) | Out-Null
    $docConnection.Close()

    # Group rows by doc_page_id
    $pages = [ordered]@{}
    foreach ($row in $dataTable.Rows) {
        $pageId = $row.doc_page_id
        if (-not $pages.Contains($pageId)) {
            $pages[$pageId] = @{
                rows = @()
            }
        }
        $pages[$pageId].rows += $row
    }

    # Build JSON structure
    $registry = @()
    foreach ($pageId in $pages.Keys) {
        $rows = $pages[$pageId].rows

        # Primary row is the one with doc_sort_order populated
        $primary = $null
        foreach ($r in $rows) {
            if ($r.doc_sort_order -isnot [DBNull]) {
                $primary = $r
                break
            }
        }

        # Fallback: first row if no primary found
        if (-not $primary) { $primary = $rows[0] }

        $page = [ordered]@{
            pageId    = [string]$primary.doc_page_id
            title     = if ($primary.doc_title -is [DBNull]) { $null } else { [string]$primary.doc_title }
            sortOrder = if ($primary.doc_sort_order -is [DBNull]) { $null } else { [int]$primary.doc_sort_order }
            isHub     = ($primary.doc_sort_order -isnot [DBNull]) -and ([int]$primary.doc_sort_order -eq 0)
        }

        # Build sections array
        $sections = @()
        foreach ($r in $rows) {
            $section = [ordered]@{
                component      = [string]$r.component_name
                description    = if ($r.description -is [DBNull]) { $null } else { [string]$r.description }
                jsonSchema     = if ($r.doc_json_schema -is [DBNull]) { $null } else { [string]$r.doc_json_schema }
                jsonCategories = if ($r.doc_json_categories -is [DBNull]) { $null } else { [string]$r.doc_json_categories }
                sectionOrder   = if ($r.doc_section_order -is [DBNull]) { $null } else { [int]$r.doc_section_order }
                ccSlug         = if ($r.doc_cc_slug -is [DBNull]) { $null } else { [string]$r.doc_cc_slug }
                ccTitle        = if ($r.doc_cc_slug -isnot [DBNull] -and $r.doc_title -isnot [DBNull]) { [string]$r.doc_title } else { $null }
            }
            $sections += $section
        }
        $page.sections = $sections

        $registry += $page
    }

    $registryJson = $registry | ConvertTo-Json -Depth 5 -Compress:$false

    if ($Execute) {
        $registryJson | Out-File -FilePath $docRegistryPath -Encoding UTF8 -Force
        Write-Log "Wrote: doc-registry.json ($($registry.Count) pages)" "SUCCESS"
    }
    else {
        Write-Log "[PREVIEW] Would write: doc-registry.json ($($registry.Count) pages)"
    }
}
catch {
    Write-Log "Doc registry export failed: $($_.Exception.Message)" "ERROR"
    # Non-fatal — DDL generation already succeeded
}

# ========================================
# Summary
# ========================================

Write-Log "------------------------------------------"
Write-Log "Schemas processed: $($schemasWritten.Count)"
foreach ($s in $schemasWritten | Sort-Object) {
    Write-Log "  - $s"
}

if (-not $Execute) {
    Write-Log ""
    Write-Log "PREVIEW MODE - no files were written" "WARN"
    Write-Log "Run with -Execute to write files" "WARN"
}
else {
    Write-Log "DDL reference generation complete" "SUCCESS"
}
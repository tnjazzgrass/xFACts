/*
================================================================================
 Object:      Tools.sp_SyncColumnOrdinals
 Type:        Stored Procedure
 Version:     Tracked in dbo.System_Metadata (component: Tools.Utilities)
 Purpose:     Aligns Object_Metadata column description sort_order values with
              actual sys.columns column_id ordinals. Deactivates Object_Metadata
              rows for columns that no longer exist in the table (dropped columns).
              Supports single table, single schema, or full database scope.
================================================================================

 CHANGELOG:
 ----------
 2026-03-22  Refactored: optional @SchemaName/@ObjectName for multi-scope support.
             Added summary result set for schema/database modes.
             Detail result set returned only in single-table preview mode.
 2026-03-08  Initial implementation

================================================================================
*/

CREATE PROCEDURE [Tools].[sp_SyncColumnOrdinals]
    @SchemaName     VARCHAR(128) = NULL,
    @ObjectName     VARCHAR(128) = NULL,
    @PreviewOnly    BIT = 1
AS
BEGIN
    SET NOCOUNT ON;

    -- =====================================================================
    -- Determine execution scope
    -- =====================================================================
    -- Both provided   → single table
    -- Schema only     → all tables in that schema
    -- Both NULL       → full database
    -- Object only     → invalid

    IF @ObjectName IS NOT NULL AND @SchemaName IS NULL
    BEGIN
        RAISERROR('@SchemaName is required when @ObjectName is specified.', 16, 1);
        RETURN;
    END

    DECLARE @SingleTableMode BIT = CASE 
        WHEN @SchemaName IS NOT NULL AND @ObjectName IS NOT NULL THEN 1 
        ELSE 0 
    END;

    -- =====================================================================
    -- Single table mode: validate the specific table exists
    -- =====================================================================

    IF @SingleTableMode = 1
    BEGIN
        IF OBJECT_ID(QUOTENAME(@SchemaName) + '.' + QUOTENAME(@ObjectName)) IS NULL
        BEGIN
            RAISERROR('Table [%s].[%s] does not exist.', 16, 1, @SchemaName, @ObjectName);
            RETURN;
        END

        IF NOT EXISTS (
            SELECT 1 FROM dbo.Object_Metadata
            WHERE schema_name = @SchemaName
              AND object_name = @ObjectName
              AND property_type = 'description'
              AND column_name IS NOT NULL
              AND is_active = 1
        )
        BEGIN
            RAISERROR('No active column descriptions found in Object_Metadata for [%s].[%s].', 16, 1, @SchemaName, @ObjectName);
            RETURN;
        END
    END

    -- =====================================================================
    -- Build the target table list
    -- =====================================================================

    CREATE TABLE #TargetTables (
        schema_name     VARCHAR(128),
        object_name     VARCHAR(128),
        object_id       INT
    );

    IF @SingleTableMode = 1
    BEGIN
        INSERT INTO #TargetTables (schema_name, object_name, object_id)
        VALUES (@SchemaName, @ObjectName, OBJECT_ID(QUOTENAME(@SchemaName) + '.' + QUOTENAME(@ObjectName)));
    END
    ELSE
    BEGIN
        -- Find all tables that have active column descriptions in Object_Metadata
        INSERT INTO #TargetTables (schema_name, object_name, object_id)
        SELECT DISTINCT om.schema_name, om.object_name, t.object_id
        FROM dbo.Object_Metadata om
        INNER JOIN sys.tables t 
            ON t.name = om.object_name
        INNER JOIN sys.schemas s 
            ON s.schema_id = t.schema_id 
            AND s.name = om.schema_name
        WHERE om.property_type = 'description'
          AND om.column_name IS NOT NULL
          AND om.is_active = 1
          AND (@SchemaName IS NULL OR om.schema_name = @SchemaName);
    END

    IF NOT EXISTS (SELECT 1 FROM #TargetTables)
    BEGIN
        PRINT 'No tables found with active column descriptions in Object_Metadata.';
        DROP TABLE #TargetTables;
        RETURN;
    END

    -- =====================================================================
    -- Build comparison across all target tables
    -- =====================================================================

    -- All active column descriptions for target tables
    CREATE TABLE #MetaColumns (
        schema_name     VARCHAR(128),
        object_name     VARCHAR(128),
        metadata_id     INT,
        column_name     VARCHAR(128),
        current_order   INT
    );

    INSERT INTO #MetaColumns (schema_name, object_name, metadata_id, column_name, current_order)
    SELECT om.schema_name, om.object_name, om.metadata_id, om.column_name, om.sort_order
    FROM dbo.Object_Metadata om
    INNER JOIN #TargetTables tt
        ON tt.schema_name = om.schema_name
        AND tt.object_name = om.object_name
    WHERE om.property_type = 'description'
      AND om.column_name IS NOT NULL
      AND om.is_active = 1;

    -- Actual columns for all target tables
    CREATE TABLE #SysColumns (
        schema_name     VARCHAR(128),
        object_name     VARCHAR(128),
        column_id       INT,
        column_name     VARCHAR(128)
    );

    INSERT INTO #SysColumns (schema_name, object_name, column_id, column_name)
    SELECT tt.schema_name, tt.object_name, c.column_id, c.name
    FROM sys.columns c
    INNER JOIN #TargetTables tt ON tt.object_id = c.object_id;

    -- =====================================================================
    -- Identify changes needed
    -- =====================================================================

    -- Orphaned: in Object_Metadata but not in sys.columns
    CREATE TABLE #Changes (
        schema_name         VARCHAR(128),
        object_name         VARCHAR(128),
        metadata_id         INT,
        column_name         VARCHAR(128),
        current_sort_order  INT,
        action              VARCHAR(10),
        new_sort_order      INT
    );

    INSERT INTO #Changes (schema_name, object_name, metadata_id, column_name, current_sort_order, action, new_sort_order)
    SELECT mc.schema_name, mc.object_name, mc.metadata_id, mc.column_name, mc.current_order, 'DEACTIVATE', 0
    FROM #MetaColumns mc
    LEFT JOIN #SysColumns sc 
        ON sc.schema_name = mc.schema_name 
        AND sc.object_name = mc.object_name 
        AND sc.column_name = mc.column_name
    WHERE sc.column_name IS NULL;

    -- Misaligned: exists in both but sort_order doesn't match column_id
    INSERT INTO #Changes (schema_name, object_name, metadata_id, column_name, current_sort_order, action, new_sort_order)
    SELECT mc.schema_name, mc.object_name, mc.metadata_id, mc.column_name, mc.current_order, 'UPDATE', sc.column_id
    FROM #MetaColumns mc
    INNER JOIN #SysColumns sc 
        ON sc.schema_name = mc.schema_name 
        AND sc.object_name = mc.object_name 
        AND sc.column_name = mc.column_name
    WHERE mc.current_order <> sc.column_id;

    -- Missing: in sys.columns but no active description row
    CREATE TABLE #Missing (
        schema_name     VARCHAR(128),
        object_name     VARCHAR(128),
        column_id       INT,
        column_name     VARCHAR(128)
    );

    INSERT INTO #Missing (schema_name, object_name, column_id, column_name)
    SELECT sc.schema_name, sc.object_name, sc.column_id, sc.column_name
    FROM #SysColumns sc
    LEFT JOIN #MetaColumns mc 
        ON mc.schema_name = sc.schema_name 
        AND mc.object_name = sc.object_name 
        AND mc.column_name = sc.column_name
    WHERE mc.column_name IS NULL;

    -- =====================================================================
    -- Output: Single table preview → detail result sets
    -- =====================================================================

    IF @SingleTableMode = 1 AND @PreviewOnly = 1
    BEGIN
        -- Detail: all columns with their status
        SELECT 
            c.column_name,
            CASE 
                WHEN ch.action = 'DEACTIVATE' THEN 'DEACTIVATE'
                WHEN ch.action = 'UPDATE' THEN 'UPDATE'
                WHEN mc.metadata_id IS NOT NULL THEN 'ALIGNED'
                ELSE NULL
            END AS action,
            mc.current_order AS current_sort_order,
            CASE 
                WHEN ch.action = 'DEACTIVATE' THEN 0
                WHEN ch.action = 'UPDATE' THEN ch.new_sort_order
                WHEN mc.metadata_id IS NOT NULL THEN mc.current_order
                ELSE NULL
            END AS new_sort_order
        FROM #SysColumns c
        LEFT JOIN #MetaColumns mc 
            ON mc.schema_name = c.schema_name 
            AND mc.object_name = c.object_name 
            AND mc.column_name = c.column_name
        LEFT JOIN #Changes ch 
            ON ch.schema_name = c.schema_name 
            AND ch.object_name = c.object_name 
            AND ch.column_name = c.column_name
        WHERE c.schema_name = @SchemaName AND c.object_name = @ObjectName

        UNION ALL

        -- Orphans (not in sys.columns, only in metadata)
        SELECT 
            ch.column_name,
            'DEACTIVATE' AS action,
            ch.current_sort_order,
            0 AS new_sort_order
        FROM #Changes ch
        WHERE ch.schema_name = @SchemaName 
          AND ch.object_name = @ObjectName 
          AND ch.action = 'DEACTIVATE'

        ORDER BY 
            CASE WHEN action = 'DEACTIVATE' THEN 1 ELSE 0 END,
            new_sort_order;

        -- Missing descriptions (informational)
        IF EXISTS (SELECT 1 FROM #Missing WHERE schema_name = @SchemaName AND object_name = @ObjectName)
        BEGIN
            SELECT column_id, column_name
            FROM #Missing
            WHERE schema_name = @SchemaName AND object_name = @ObjectName
            ORDER BY column_id;
        END
    END

    -- =====================================================================
    -- Output: Summary result set (all modes)
    -- =====================================================================

    SELECT 
        tt.schema_name,
        tt.object_name,
        (SELECT COUNT(*) FROM #SysColumns sc 
         WHERE sc.schema_name = tt.schema_name AND sc.object_name = tt.object_name) AS table_columns,
        (SELECT COUNT(*) FROM #MetaColumns mc 
         WHERE mc.schema_name = tt.schema_name AND mc.object_name = tt.object_name) AS described_columns,
        (SELECT COUNT(*) FROM #MetaColumns mc 
         INNER JOIN #SysColumns sc ON sc.schema_name = mc.schema_name AND sc.object_name = mc.object_name AND sc.column_name = mc.column_name
         WHERE mc.schema_name = tt.schema_name AND mc.object_name = tt.object_name 
           AND mc.current_order = sc.column_id) AS aligned,
        ISNULL((SELECT COUNT(*) FROM #Changes ch 
         WHERE ch.schema_name = tt.schema_name AND ch.object_name = tt.object_name AND ch.action = 'UPDATE'), 0) AS sort_order_updates,
        ISNULL((SELECT COUNT(*) FROM #Changes ch 
         WHERE ch.schema_name = tt.schema_name AND ch.object_name = tt.object_name AND ch.action = 'DEACTIVATE'), 0) AS orphans_deactivated,
        ISNULL((SELECT COUNT(*) FROM #Missing m 
         WHERE m.schema_name = tt.schema_name AND m.object_name = tt.object_name), 0) AS missing_descriptions
    FROM #TargetTables tt
    ORDER BY tt.schema_name, tt.object_name;

    -- =====================================================================
    -- Apply changes (if not preview mode)
    -- =====================================================================

    IF @PreviewOnly = 0 AND EXISTS (SELECT 1 FROM #Changes)
    BEGIN
        -- Deactivate orphaned rows
        UPDATE om
        SET om.is_active = 0,
            om.sort_order = 0,
            om.modified_dttm = GETDATE(),
            om.modified_by = SUSER_SNAME()
        FROM dbo.Object_Metadata om
        INNER JOIN #Changes c ON c.metadata_id = om.metadata_id
        WHERE c.action = 'DEACTIVATE';

        -- Update misaligned sort_order values
        UPDATE om
        SET om.sort_order = c.new_sort_order,
            om.modified_dttm = GETDATE(),
            om.modified_by = SUSER_SNAME()
        FROM dbo.Object_Metadata om
        INNER JOIN #Changes c ON c.metadata_id = om.metadata_id
        WHERE c.action = 'UPDATE';
    END

    -- =====================================================================
    -- Cleanup
    -- =====================================================================

    DROP TABLE #TargetTables;
    DROP TABLE #MetaColumns;
    DROP TABLE #SysColumns;
    DROP TABLE #Changes;
    DROP TABLE #Missing;
END
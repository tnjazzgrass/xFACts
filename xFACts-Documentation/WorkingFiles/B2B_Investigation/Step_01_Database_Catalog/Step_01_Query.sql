-- ============================================================================
-- B2B INVESTIGATION — Step 1: b2bi Database Catalog
-- Purpose: Inventory every table in b2bi with row counts and basic structure
--          Treat as first-time discovery; no assumptions about contents
-- ============================================================================

USE b2bi;
GO

-- ----------------------------------------------------------------------------
-- 1.1 Sterling version (if discoverable from the database)
-- ----------------------------------------------------------------------------
-- Try a few common possibilities; Sterling typically exposes version somewhere
SELECT name
FROM sys.tables
WHERE name LIKE '%VERSION%' OR name LIKE '%SI_VER%'
ORDER BY name;
-- If any return, we'll query them individually in a follow-up

SELECT * FROM SI_VERSION

-- ----------------------------------------------------------------------------
-- 1.2 Full table catalog: every user table, row count, approx data size
-- ----------------------------------------------------------------------------
SELECT 
    t.name AS table_name,
    SUM(p.rows) AS row_count,
    SUM(a.total_pages) * 8 / 1024 AS total_mb,
    SUM(a.used_pages) * 8 / 1024 AS used_mb
FROM sys.tables t
INNER JOIN sys.indexes i ON t.object_id = i.object_id
INNER JOIN sys.partitions p ON i.object_id = p.object_id AND i.index_id = p.index_id
INNER JOIN sys.allocation_units a ON p.partition_id = a.container_id
WHERE t.is_ms_shipped = 0
  AND i.index_id IN (0, 1)  -- heap or clustered index only, to avoid double-counting
GROUP BY t.name
ORDER BY SUM(p.rows) DESC;

-- ----------------------------------------------------------------------------
-- 1.3 Column count and key-presence summary per table
--     (gives us structural character at a glance)
-- ----------------------------------------------------------------------------
SELECT
    t.name AS table_name,
    COUNT(c.column_id) AS column_count,
    SUM(CASE WHEN c.is_identity = 1 THEN 1 ELSE 0 END) AS identity_cols,
    SUM(CASE WHEN c.is_nullable = 0 THEN 1 ELSE 0 END) AS not_null_cols,
    CASE WHEN EXISTS (
        SELECT 1 FROM sys.key_constraints k 
        WHERE k.parent_object_id = t.object_id AND k.type = 'PK'
    ) THEN 'Y' ELSE 'N' END AS has_pk,
    CASE WHEN EXISTS (
        SELECT 1 FROM sys.foreign_keys f
        WHERE f.parent_object_id = t.object_id
    ) THEN 'Y' ELSE 'N' END AS has_fk_out,
    CASE WHEN EXISTS (
        SELECT 1 FROM sys.foreign_keys f
        WHERE f.referenced_object_id = t.object_id
    ) THEN 'Y' ELSE 'N' END AS has_fk_in
FROM sys.tables t
INNER JOIN sys.columns c ON t.object_id = c.object_id
WHERE t.is_ms_shipped = 0
GROUP BY t.name, t.object_id
ORDER BY t.name;

-- ----------------------------------------------------------------------------
-- 1.4 Foreign-key relationships
-- ----------------------------------------------------------------------------
SELECT 
    fk.name AS fk_name,
    tp.name AS parent_table,
    cp.name AS parent_column,
    tr.name AS referenced_table,
    cr.name AS referenced_column
FROM sys.foreign_keys fk
INNER JOIN sys.tables tp ON fk.parent_object_id = tp.object_id
INNER JOIN sys.tables tr ON fk.referenced_object_id = tr.object_id
INNER JOIN sys.foreign_key_columns fkc ON fk.object_id = fkc.constraint_object_id
INNER JOIN sys.columns cp ON fkc.parent_object_id = cp.object_id 
                          AND fkc.parent_column_id = cp.column_id
INNER JOIN sys.columns cr ON fkc.referenced_object_id = cr.object_id
                          AND fkc.referenced_column_id = cr.column_id
ORDER BY tp.name, fk.name;

-- ----------------------------------------------------------------------------
-- 1.5 View catalog (Sterling sometimes uses views for abstraction)
-- ----------------------------------------------------------------------------
SELECT 
    name AS view_name,
    create_date,
    modify_date
FROM sys.views
WHERE is_ms_shipped = 0
ORDER BY name;

-- ----------------------------------------------------------------------------
-- 1.6 Stored procedure catalog (useful for understanding Sterling's own ops)
-- ----------------------------------------------------------------------------
SELECT 
    name AS proc_name,
    create_date,
    modify_date
FROM sys.procedures
WHERE is_ms_shipped = 0
ORDER BY name;
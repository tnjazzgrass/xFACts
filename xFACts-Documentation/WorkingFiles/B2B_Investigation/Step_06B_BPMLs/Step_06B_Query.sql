/*
================================================================================
Step 6B — BPML Storage Schema Discovery
================================================================================
Purpose : Locate the b2bi table(s) that store BPML XML content for workflow
          definitions. WFD does not have a WFD_XML column (verified Step 6A).
          Legacy ArchitectureOverview references "WFD_XML / DATA_TABLE" as the
          source — we need to confirm the actual structure before drafting the
          bulk extraction script.

Target  : b2bi database (FA-INT-DBP), read-only
Runtime : < 5 seconds; all metadata + catalog queries
================================================================================

Run all six queries. Paste back the results. We'll draft the bulk extraction
script from what's observed.
*/

-- ---------------------------------------------------------------------------
-- Q1 : Look for tables with 'WFD' or 'BPML' or 'XML' in the name.
-- ---------------------------------------------------------------------------
PRINT '--- Q1: Tables with WFD/BPML/XML in name ---';
SELECT
    TABLE_SCHEMA,
    TABLE_NAME
FROM b2bi.INFORMATION_SCHEMA.TABLES
WHERE TABLE_TYPE = 'BASE TABLE'
  AND (TABLE_NAME LIKE '%WFD%'
    OR TABLE_NAME LIKE '%BPML%'
    OR TABLE_NAME LIKE '%_XML%')
ORDER BY TABLE_NAME;


-- ---------------------------------------------------------------------------
-- Q2 : Full column list of all WFD-related tables. Reveals what each stores.
-- ---------------------------------------------------------------------------
PRINT '--- Q2: Columns in WFD-related tables ---';
SELECT
    c.TABLE_NAME,
    c.ORDINAL_POSITION,
    c.COLUMN_NAME,
    c.DATA_TYPE,
    c.CHARACTER_MAXIMUM_LENGTH,
    c.IS_NULLABLE
FROM b2bi.INFORMATION_SCHEMA.COLUMNS c
WHERE c.TABLE_NAME LIKE '%WFD%'
   OR c.TABLE_NAME LIKE '%BPML%'
ORDER BY c.TABLE_NAME, c.ORDINAL_POSITION;


-- ---------------------------------------------------------------------------
-- Q3 : DATA_TABLE structure (referenced by SCHEDULE.TIMINGXML; may also store
--      BPML payloads).
-- ---------------------------------------------------------------------------
PRINT '--- Q3: DATA_TABLE columns ---';
SELECT
    ORDINAL_POSITION,
    COLUMN_NAME,
    DATA_TYPE,
    CHARACTER_MAXIMUM_LENGTH,
    IS_NULLABLE
FROM b2bi.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'DATA_TABLE'
ORDER BY ORDINAL_POSITION;


-- ---------------------------------------------------------------------------
-- Q4 : Row count and a sample preview of each candidate table.
--      For each candidate table found in Q1/Q2, we want to see:
--        - row count
--        - any columns that could be an FK back to WFD (WFD_ID, WFD_VERSION)
--        - any blob/CLOB/varbinary columns (likely BPML payload)
--      This query must be adjusted after Q1/Q2 reveal the actual table names.
--      Below are the common candidates; results will tell us which are real.
-- ---------------------------------------------------------------------------
PRINT '--- Q4: Row counts of likely candidate tables ---';
-- Safe way: try each candidate; ignore error if the table doesn't exist.
-- Use TRY/CATCH in a loop so a missing table doesn't halt the batch.

DECLARE @tables TABLE (tbl sysname);
INSERT INTO @tables(tbl) VALUES
    ('WFD_XML'),
    ('WFD_STATE'),
    ('WFD_STATE_XML'),
    ('BUSINESS_PROCESS_DEF'),
    ('DATA_TABLE'),
    ('WFD');

DECLARE @tbl sysname, @sql nvarchar(500), @cnt bigint;
DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT tbl FROM @tables;
OPEN cur;
FETCH NEXT FROM cur INTO @tbl;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @sql = N'SELECT @cnt = COUNT_BIG(*) FROM b2bi.dbo.' + QUOTENAME(@tbl);
        EXEC sp_executesql @sql, N'@cnt bigint OUTPUT', @cnt = @cnt OUTPUT;
        PRINT @tbl + ': ' + CAST(@cnt AS varchar(20)) + ' rows';
    END TRY
    BEGIN CATCH
        PRINT @tbl + ': DOES NOT EXIST';
    END CATCH
    FETCH NEXT FROM cur INTO @tbl;
END
CLOSE cur;
DEALLOCATE cur;


-- ---------------------------------------------------------------------------
-- Q5 : Pull one MAIN sample row from every candidate BPML-storage table.
--      For WFD we use MAIN's WFD_ID 798 at whatever its latest version is.
--      This tells us which table(s) have a row for MAIN and what shape.
-- ---------------------------------------------------------------------------
PRINT '--- Q5: MAIN (WFD_ID 798) sample from candidate tables ---';

-- Try WFD_XML if it exists
BEGIN TRY
    SELECT TOP 5 *
    FROM b2bi.dbo.WFD_XML
    WHERE WFD_ID = 798
    ORDER BY
        CASE WHEN COL_LENGTH('b2bi.dbo.WFD_XML', 'WFD_VERSION') IS NOT NULL
             THEN 1 ELSE 0 END DESC;  -- no-op ORDER if no such column
END TRY
BEGIN CATCH
    PRINT 'WFD_XML: query failed - ' + ERROR_MESSAGE();
END CATCH


-- ---------------------------------------------------------------------------
-- Q6 : For each candidate table that has binary/text blob columns, show
--      a size histogram so we know what to expect in 6B extraction.
--      Query must be adapted after Q1/Q2 reveal actual table + column names.
--      This skeleton lists what we'd want; actual execution deferred until
--      we know the table name.
-- ---------------------------------------------------------------------------
PRINT '--- Q6: Skeleton for blob size distribution (adapt after Q1/Q2 reveal the table) ---';
PRINT 'Template:';
PRINT '  SELECT';
PRINT '    COUNT(*) AS row_count,';
PRINT '    MIN(DATALENGTH(<blob_col>)) AS min_bytes,';
PRINT '    AVG(DATALENGTH(<blob_col>) * 1.0) AS avg_bytes,';
PRINT '    MAX(DATALENGTH(<blob_col>)) AS max_bytes,';
PRINT '    SUM(DATALENGTH(<blob_col>) * 1.0) / 1024.0 / 1024.0 AS total_mb';
PRINT '  FROM b2bi.dbo.<bpml_table>;';


/*
================================================================================
Step 6B — BPML Content Verification
================================================================================
Purpose : Verify three things about BPML storage before drafting the extraction
          script:
            1. How WFD_XML.XML (handle) maps to DATA_TABLE.DATA_ID rows
               (1:1 or paginated)
            2. Size distribution of BPML payloads
            3. Whether blobs are compressed (gzip magic bytes) or plain XML

Target  : b2bi database, read-only
Runtime : < 5 seconds
================================================================================
*/

-- ---------------------------------------------------------------------------
-- Q1 : MAIN's current latest version (WFD_ID 798, presumably version 48)
--      — show handle and verify it resolves in DATA_TABLE.
-- ---------------------------------------------------------------------------
PRINT '--- Q1: MAIN v48 handle + DATA_TABLE resolution ---';
SELECT
    wx.WFD_ID,
    wx.WFD_VERSION,
    wx.XML       AS handle,
    dt.DATA_ID,
    dt.PAGE_INDEX,
    dt.DATA_TYPE,
    DATALENGTH(dt.DATA_OBJECT) AS blob_bytes,
    dt.ARCHIVE_FLAG,
    dt.ARCHIVE_DATE,
    dt.WF_ID,
    dt.REFERENCE_TABLE
FROM b2bi.dbo.WFD_XML wx
LEFT JOIN b2bi.dbo.DATA_TABLE dt
       ON dt.DATA_ID = wx.XML
WHERE wx.WFD_ID = 798
ORDER BY wx.WFD_VERSION DESC, dt.PAGE_INDEX ASC;


-- ---------------------------------------------------------------------------
-- Q2 : Pagination check — do any BPML handles resolve to multiple
--      DATA_TABLE rows (PAGE_INDEX > 0)? If yes, large BPMLs paginate and
--      extraction must concatenate all pages.
-- ---------------------------------------------------------------------------
PRINT '--- Q2: Pagination check across all BPML handles ---';
WITH page_counts AS (
    SELECT
        wx.WFD_ID,
        wx.WFD_VERSION,
        wx.XML AS handle,
        COUNT(*) AS page_rows,
        MAX(dt.PAGE_INDEX) AS max_page_index,
        SUM(DATALENGTH(dt.DATA_OBJECT)) AS total_blob_bytes
    FROM b2bi.dbo.WFD_XML wx
    INNER JOIN b2bi.dbo.DATA_TABLE dt
            ON dt.DATA_ID = wx.XML
    GROUP BY wx.WFD_ID, wx.WFD_VERSION, wx.XML
)
SELECT
    page_rows,
    COUNT(*) AS n_handles
FROM page_counts
GROUP BY page_rows
ORDER BY page_rows;


-- ---------------------------------------------------------------------------
-- Q3 : Size distribution across ALL BPML payloads.
--      Note: if any BPMLs paginate (Q2 shows page_rows > 1), the SUM is what
--      matters — a single BPML may be spread across multiple rows.
-- ---------------------------------------------------------------------------
PRINT '--- Q3: BPML blob size distribution ---';
WITH bpml_sizes AS (
    SELECT
        wx.WFD_ID,
        wx.WFD_VERSION,
        SUM(DATALENGTH(dt.DATA_OBJECT)) AS total_bytes
    FROM b2bi.dbo.WFD_XML wx
    LEFT JOIN b2bi.dbo.DATA_TABLE dt ON dt.DATA_ID = wx.XML
    GROUP BY wx.WFD_ID, wx.WFD_VERSION
)
SELECT
    COUNT(*) AS total_wfd_versions,
    SUM(CASE WHEN total_bytes IS NULL THEN 1 ELSE 0 END) AS wfd_versions_without_blob,
    MIN(total_bytes) AS min_bytes,
    AVG(total_bytes * 1.0) AS avg_bytes,
    MAX(total_bytes) AS max_bytes,
    SUM(total_bytes * 1.0) / 1024.0 / 1024.0 AS total_mb
FROM bpml_sizes;


-- ---------------------------------------------------------------------------
-- Q4 : Compression check — read first 4 bytes of MAIN v48's blob.
--      gzip magic = 0x1F 0x8B.  Plain XML = starts with '<' (0x3C) or
--      UTF-8 BOM (0xEF 0xBB 0xBF) followed by '<'.
--      This tells us whether PowerShell needs GZipStream or can just cast.
-- ---------------------------------------------------------------------------
PRINT '--- Q4: First 16 bytes of MAIN latest-version blob (detect gzip vs plain) ---';
DECLARE @mainHandle nvarchar(255);
SELECT TOP 1 @mainHandle = wx.XML
FROM b2bi.dbo.WFD_XML wx
WHERE wx.WFD_ID = 798
ORDER BY wx.WFD_VERSION DESC;

PRINT 'MAIN latest handle: ' + ISNULL(@mainHandle, 'NULL');

SELECT TOP 1
    PAGE_INDEX,
    DATALENGTH(DATA_OBJECT) AS blob_bytes,
    CONVERT(varbinary(16), SUBSTRING(DATA_OBJECT, 1, 16)) AS first_16_bytes,
    CASE
        WHEN SUBSTRING(DATA_OBJECT, 1, 2) = 0x1F8B THEN 'GZIP'
        WHEN SUBSTRING(DATA_OBJECT, 1, 1) = 0x3C   THEN 'PLAIN_XML (starts with <)'
        WHEN SUBSTRING(DATA_OBJECT, 1, 3) = 0xEFBBBF THEN 'UTF8_BOM + XML'
        ELSE 'UNKNOWN / OTHER'
    END AS format_detected
FROM b2bi.dbo.DATA_TABLE
WHERE DATA_ID = @mainHandle
ORDER BY PAGE_INDEX ASC;


-- ---------------------------------------------------------------------------
-- Q5 : Sanity check — do the same for a handful of other BPMLs to make sure
--      the format is consistent across the workflow population.
--      Sample: VITAL (800), ARCHIVE (795), EMAIL (794), GET_LIST (797),
--              GET_DOCS (796), and a random FA_FROM + FA_TO.
-- ---------------------------------------------------------------------------
PRINT '--- Q5: Format check across several workflows ---';
WITH targets AS (
    SELECT 800 AS wfd_id UNION ALL  -- VITAL
    SELECT 795 UNION ALL             -- ARCHIVE
    SELECT 794 UNION ALL             -- EMAIL
    SELECT 797 UNION ALL             -- GET_LIST
    SELECT 796                        -- GET_DOCS
),
latest AS (
    SELECT wx.WFD_ID, MAX(wx.WFD_VERSION) AS ver
    FROM b2bi.dbo.WFD_XML wx
    INNER JOIN targets t ON t.wfd_id = wx.WFD_ID
    GROUP BY wx.WFD_ID
)
SELECT
    w.NAME,
    wx.WFD_ID,
    wx.WFD_VERSION,
    DATALENGTH(dt.DATA_OBJECT) AS blob_bytes,
    dt.PAGE_INDEX,
    CONVERT(varbinary(8), SUBSTRING(dt.DATA_OBJECT, 1, 8)) AS first_8_bytes,
    CASE
        WHEN SUBSTRING(dt.DATA_OBJECT, 1, 2) = 0x1F8B THEN 'GZIP'
        WHEN SUBSTRING(dt.DATA_OBJECT, 1, 1) = 0x3C   THEN 'PLAIN_XML'
        WHEN SUBSTRING(dt.DATA_OBJECT, 1, 3) = 0xEFBBBF THEN 'UTF8_BOM + XML'
        ELSE 'UNKNOWN'
    END AS format_detected
FROM b2bi.dbo.WFD_XML wx
INNER JOIN latest l ON l.WFD_ID = wx.WFD_ID AND l.ver = wx.WFD_VERSION
INNER JOIN b2bi.dbo.WFD w ON w.WFD_ID = wx.WFD_ID AND w.WFD_VERSION = wx.WFD_VERSION
LEFT JOIN b2bi.dbo.DATA_TABLE dt ON dt.DATA_ID = wx.XML
ORDER BY w.NAME, dt.PAGE_INDEX;
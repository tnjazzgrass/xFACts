

/*
================================================================================
 ServerOps.sp_Index_AddDatabaseSchedule
================================================================================
 Database:    xFACts
 Schema:      ServerOps
 Object:      sp_Index_AddDatabaseSchedule
 Type:        Stored Procedure
 Author:      Applications Team
 Version:     3.0.0
 Purpose:     Initialize the 7 default schedule rows for a database in 
              Index_DatabaseSchedule. Provides flexible parameters for 
              customizing maintenance windows.
================================================================================

 CHANGELOG:
 ----------
 Version  Date        Description
 -------  ----------  -----------------------------------------------------------
 3.0.0    2026-01-22  xFACts Refactoring - Phase 3/8
                      Renamed from sp_Maintenance_AddDatabaseSchedule
                      Table references updated:
                        ServerOps.DatabaseRegistry -> dbo.DatabaseRegistry
                        ServerOps.Maintenance_Database_Schedule -> ServerOps.DatabaseSchedule
 2.0.0    2026-01-13  Renamed from sp_Index_InitializeSchedule; fixed preview
                      display by casting BIT columns to INT for readability
 1.1.0    2026-01-01  Changed bit flag convention: 1 = allowed, 0 = not allowed
                      (consistent with other xFACts flags)
                      Added validation for weekend parameter pairs
                      Added validation for Sunday parameter pairs
                      Added validation for hour ranges on weekend/Sunday
                      Added validation that BlockStart < BlockEnd
                      Updated comments and output messages
 1.0.0    2025-12-31  Initial creation

================================================================================
*/

CREATE     PROCEDURE [ServerOps].[sp_Index_AddDatabaseSchedule]
    @DatabaseID             INT,
    @WeekdayBlockStart      TINYINT = 6,        -- Default: 6am
    @WeekdayBlockEnd        TINYINT = 19,       -- Default: 7pm (blocks through hr18)
    @WeekendBlockStart      TINYINT = NULL,     -- Default: no blocking
    @WeekendBlockEnd        TINYINT = NULL,     -- Default: no blocking
    @SundayBlockStart       TINYINT = NULL,     -- Default: use weekend setting
    @SundayBlockEnd         TINYINT = NULL,     -- Default: use weekend setting
    @PreviewOnly            BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    
    -- ========================================================================
    -- Section 1: Validation
    -- ========================================================================
    
    -- Verify database exists
    IF NOT EXISTS (SELECT 1 FROM dbo.DatabaseRegistry WHERE database_id = @DatabaseID)
    BEGIN
        RAISERROR('Database ID %d not found in DatabaseRegistry', 16, 1, @DatabaseID);
        RETURN;
    END
    
    -- Check if schedules already exist
    IF EXISTS (SELECT 1 FROM ServerOps.Index_DatabaseSchedule WHERE database_id = @DatabaseID)
    BEGIN
        DECLARE @ExistingCount INT;
        SELECT @ExistingCount = COUNT(*) 
        FROM ServerOps.Index_DatabaseSchedule 
        WHERE database_id = @DatabaseID;
        
        RAISERROR('Database ID %d already has %d schedule rows. Delete existing rows before re-initializing.', 16, 1, @DatabaseID, @ExistingCount);
        RETURN;
    END
    
    -- Validate weekday hour ranges
    IF @WeekdayBlockStart IS NOT NULL AND (@WeekdayBlockStart < 0 OR @WeekdayBlockStart > 23)
    BEGIN
        RAISERROR('Invalid @WeekdayBlockStart: %d. Must be between 0 and 23.', 16, 1, @WeekdayBlockStart);
        RETURN;
    END
    
    IF @WeekdayBlockEnd IS NOT NULL AND (@WeekdayBlockEnd < 0 OR @WeekdayBlockEnd > 23)
    BEGIN
        RAISERROR('Invalid @WeekdayBlockEnd: %d. Must be between 0 and 23.', 16, 1, @WeekdayBlockEnd);
        RETURN;
    END
    
    -- Validate weekend hour ranges
    IF @WeekendBlockStart IS NOT NULL AND (@WeekendBlockStart < 0 OR @WeekendBlockStart > 23)
    BEGIN
        RAISERROR('Invalid @WeekendBlockStart: %d. Must be between 0 and 23.', 16, 1, @WeekendBlockStart);
        RETURN;
    END
    
    IF @WeekendBlockEnd IS NOT NULL AND (@WeekendBlockEnd < 0 OR @WeekendBlockEnd > 23)
    BEGIN
        RAISERROR('Invalid @WeekendBlockEnd: %d. Must be between 0 and 23.', 16, 1, @WeekendBlockEnd);
        RETURN;
    END
    
    -- Validate Sunday hour ranges
    IF @SundayBlockStart IS NOT NULL AND (@SundayBlockStart < 0 OR @SundayBlockStart > 23)
    BEGIN
        RAISERROR('Invalid @SundayBlockStart: %d. Must be between 0 and 23.', 16, 1, @SundayBlockStart);
        RETURN;
    END
    
    IF @SundayBlockEnd IS NOT NULL AND (@SundayBlockEnd < 0 OR @SundayBlockEnd > 23)
    BEGIN
        RAISERROR('Invalid @SundayBlockEnd: %d. Must be between 0 and 23.', 16, 1, @SundayBlockEnd);
        RETURN;
    END
    
    -- If one weekday parameter is specified, both must be
    IF (@WeekdayBlockStart IS NULL AND @WeekdayBlockEnd IS NOT NULL)
        OR (@WeekdayBlockStart IS NOT NULL AND @WeekdayBlockEnd IS NULL)
    BEGIN
        RAISERROR('Both @WeekdayBlockStart and @WeekdayBlockEnd must be specified together, or both NULL for no blocking.', 16, 1);
        RETURN;
    END
    
    -- If one weekend parameter is specified, both must be
    IF (@WeekendBlockStart IS NULL AND @WeekendBlockEnd IS NOT NULL)
        OR (@WeekendBlockStart IS NOT NULL AND @WeekendBlockEnd IS NULL)
    BEGIN
        RAISERROR('Both @WeekendBlockStart and @WeekendBlockEnd must be specified together, or both NULL for no blocking.', 16, 1);
        RETURN;
    END
    
    -- If one Sunday parameter is specified, both must be
    IF (@SundayBlockStart IS NULL AND @SundayBlockEnd IS NOT NULL)
        OR (@SundayBlockStart IS NOT NULL AND @SundayBlockEnd IS NULL)
    BEGIN
        RAISERROR('Both @SundayBlockStart and @SundayBlockEnd must be specified together, or both NULL to use weekend setting.', 16, 1);
        RETURN;
    END
    
    -- Validate BlockStart < BlockEnd
    -- Overnight windows (start > end) are not supported; use alternative approach
    IF @WeekdayBlockStart IS NOT NULL AND @WeekdayBlockEnd IS NOT NULL 
        AND @WeekdayBlockStart >= @WeekdayBlockEnd
    BEGIN
        RAISERROR('Invalid weekday block range: @WeekdayBlockStart (%d) must be less than @WeekdayBlockEnd (%d). Overnight windows not supported.', 16, 1, @WeekdayBlockStart, @WeekdayBlockEnd);
        RETURN;
    END
    
    IF @WeekendBlockStart IS NOT NULL AND @WeekendBlockEnd IS NOT NULL 
        AND @WeekendBlockStart >= @WeekendBlockEnd
    BEGIN
        RAISERROR('Invalid weekend block range: @WeekendBlockStart (%d) must be less than @WeekendBlockEnd (%d). Overnight windows not supported.', 16, 1, @WeekendBlockStart, @WeekendBlockEnd);
        RETURN;
    END
    
    IF @SundayBlockStart IS NOT NULL AND @SundayBlockEnd IS NOT NULL 
        AND @SundayBlockStart >= @SundayBlockEnd
    BEGIN
        RAISERROR('Invalid Sunday block range: @SundayBlockStart (%d) must be less than @SundayBlockEnd (%d). Overnight windows not supported.', 16, 1, @SundayBlockStart, @SundayBlockEnd);
        RETURN;
    END
    
    -- Sunday defaults to weekend settings if not explicitly overridden
    IF @SundayBlockStart IS NULL
        SET @SundayBlockStart = @WeekendBlockStart;
    IF @SundayBlockEnd IS NULL
        SET @SundayBlockEnd = @WeekendBlockEnd;
    
    -- ========================================================================
    -- Section 2: Build Schedule Rows
    -- ========================================================================
    -- Bit flag convention: 1 = allowed, 0 = not allowed
    -- Hours INSIDE the block range get 0 (not allowed)
    -- Hours OUTSIDE the block range get 1 (allowed)
    
    DECLARE @DatabaseName VARCHAR(128);
    SELECT @DatabaseName = database_name 
    FROM dbo.DatabaseRegistry 
    WHERE database_id = @DatabaseID;
    
    -- Create temp table to hold the 7 rows
    CREATE TABLE #ScheduleRows (
        database_id INT,
        day_of_week TINYINT,
        hr00 BIT, hr01 BIT, hr02 BIT, hr03 BIT, hr04 BIT, hr05 BIT,
        hr06 BIT, hr07 BIT, hr08 BIT, hr09 BIT, hr10 BIT, hr11 BIT,
        hr12 BIT, hr13 BIT, hr14 BIT, hr15 BIT, hr16 BIT, hr17 BIT,
        hr18 BIT, hr19 BIT, hr20 BIT, hr21 BIT, hr22 BIT, hr23 BIT
    );
    
    -- Generate all 7 days
    DECLARE @DayOfWeek TINYINT = 1;  -- Start with Sunday (1)
    
    WHILE @DayOfWeek <= 7
    BEGIN
        -- Determine blocking pattern for this day
        DECLARE @BlockStart TINYINT = NULL;
        DECLARE @BlockEnd TINYINT = NULL;
        
        IF @DayOfWeek = 1  -- Sunday
        BEGIN
            SET @BlockStart = @SundayBlockStart;
            SET @BlockEnd = @SundayBlockEnd;
        END
        ELSE IF @DayOfWeek = 7  -- Saturday
        BEGIN
            SET @BlockStart = @WeekendBlockStart;
            SET @BlockEnd = @WeekendBlockEnd;
        END
        ELSE  -- Monday-Friday (2-6)
        BEGIN
            SET @BlockStart = @WeekdayBlockStart;
            SET @BlockEnd = @WeekdayBlockEnd;
        END
        
        -- Build 24-hour row for this day
        -- INVERTED logic - 1 = allowed (outside block), 0 = not allowed (inside block)
        INSERT INTO #ScheduleRows (
            database_id, day_of_week,
            hr00, hr01, hr02, hr03, hr04, hr05, hr06, hr07, hr08, hr09, hr10, hr11,
            hr12, hr13, hr14, hr15, hr16, hr17, hr18, hr19, hr20, hr21, hr22, hr23
        )
        VALUES (
            @DatabaseID,
            @DayOfWeek,
            -- Each hour: 0 if in block range (not allowed), 1 if outside (allowed)
            -- If @BlockStart IS NULL, no blocking - all hours allowed (1)
            CASE WHEN @BlockStart IS NOT NULL AND 0 >= @BlockStart AND 0 < @BlockEnd THEN 0 ELSE 1 END,
            CASE WHEN @BlockStart IS NOT NULL AND 1 >= @BlockStart AND 1 < @BlockEnd THEN 0 ELSE 1 END,
            CASE WHEN @BlockStart IS NOT NULL AND 2 >= @BlockStart AND 2 < @BlockEnd THEN 0 ELSE 1 END,
            CASE WHEN @BlockStart IS NOT NULL AND 3 >= @BlockStart AND 3 < @BlockEnd THEN 0 ELSE 1 END,
            CASE WHEN @BlockStart IS NOT NULL AND 4 >= @BlockStart AND 4 < @BlockEnd THEN 0 ELSE 1 END,
            CASE WHEN @BlockStart IS NOT NULL AND 5 >= @BlockStart AND 5 < @BlockEnd THEN 0 ELSE 1 END,
            CASE WHEN @BlockStart IS NOT NULL AND 6 >= @BlockStart AND 6 < @BlockEnd THEN 0 ELSE 1 END,
            CASE WHEN @BlockStart IS NOT NULL AND 7 >= @BlockStart AND 7 < @BlockEnd THEN 0 ELSE 1 END,
            CASE WHEN @BlockStart IS NOT NULL AND 8 >= @BlockStart AND 8 < @BlockEnd THEN 0 ELSE 1 END,
            CASE WHEN @BlockStart IS NOT NULL AND 9 >= @BlockStart AND 9 < @BlockEnd THEN 0 ELSE 1 END,
            CASE WHEN @BlockStart IS NOT NULL AND 10 >= @BlockStart AND 10 < @BlockEnd THEN 0 ELSE 1 END,
            CASE WHEN @BlockStart IS NOT NULL AND 11 >= @BlockStart AND 11 < @BlockEnd THEN 0 ELSE 1 END,
            CASE WHEN @BlockStart IS NOT NULL AND 12 >= @BlockStart AND 12 < @BlockEnd THEN 0 ELSE 1 END,
            CASE WHEN @BlockStart IS NOT NULL AND 13 >= @BlockStart AND 13 < @BlockEnd THEN 0 ELSE 1 END,
            CASE WHEN @BlockStart IS NOT NULL AND 14 >= @BlockStart AND 14 < @BlockEnd THEN 0 ELSE 1 END,
            CASE WHEN @BlockStart IS NOT NULL AND 15 >= @BlockStart AND 15 < @BlockEnd THEN 0 ELSE 1 END,
            CASE WHEN @BlockStart IS NOT NULL AND 16 >= @BlockStart AND 16 < @BlockEnd THEN 0 ELSE 1 END,
            CASE WHEN @BlockStart IS NOT NULL AND 17 >= @BlockStart AND 17 < @BlockEnd THEN 0 ELSE 1 END,
            CASE WHEN @BlockStart IS NOT NULL AND 18 >= @BlockStart AND 18 < @BlockEnd THEN 0 ELSE 1 END,
            CASE WHEN @BlockStart IS NOT NULL AND 19 >= @BlockStart AND 19 < @BlockEnd THEN 0 ELSE 1 END,
            CASE WHEN @BlockStart IS NOT NULL AND 20 >= @BlockStart AND 20 < @BlockEnd THEN 0 ELSE 1 END,
            CASE WHEN @BlockStart IS NOT NULL AND 21 >= @BlockStart AND 21 < @BlockEnd THEN 0 ELSE 1 END,
            CASE WHEN @BlockStart IS NOT NULL AND 22 >= @BlockStart AND 22 < @BlockEnd THEN 0 ELSE 1 END,
            CASE WHEN @BlockStart IS NOT NULL AND 23 >= @BlockStart AND 23 < @BlockEnd THEN 0 ELSE 1 END
        );
        
        SET @DayOfWeek = @DayOfWeek + 1;
    END
    
    -- ========================================================================
    -- Section 3: Preview or Execute
    -- ========================================================================
    
    IF @PreviewOnly = 1
    BEGIN
        PRINT '========================================';
        PRINT 'PREVIEW MODE - No changes will be made';
        PRINT '========================================';
        PRINT '';
        PRINT 'Database: ' + @DatabaseName + ' (ID: ' + CAST(@DatabaseID AS VARCHAR(10)) + ')';
        PRINT '';
        PRINT 'Bit Flag Convention: 1 = ALLOWED, 0 = NOT ALLOWED';
        PRINT '';
        PRINT 'Schedule Pattern (hours when maintenance is BLOCKED):';
        PRINT '  Weekdays (Mon-Fri): ' + 
              CASE 
                  WHEN @WeekdayBlockStart IS NULL THEN 'No blocking (maintenance allowed 24hrs)'
                  ELSE 'Blocked ' + CAST(@WeekdayBlockStart AS VARCHAR(2)) + ':00 - ' + CAST(@WeekdayBlockEnd AS VARCHAR(2)) + ':00'
              END;
        PRINT '  Saturday: ' + 
              CASE 
                  WHEN @WeekendBlockStart IS NULL THEN 'No blocking (maintenance allowed 24hrs)'
                  ELSE 'Blocked ' + CAST(@WeekendBlockStart AS VARCHAR(2)) + ':00 - ' + CAST(@WeekendBlockEnd AS VARCHAR(2)) + ':00'
              END;
        PRINT '  Sunday: ' + 
              CASE 
                  WHEN @SundayBlockStart IS NULL THEN 'No blocking (maintenance allowed 24hrs)'
                  ELSE 'Blocked ' + CAST(@SundayBlockStart AS VARCHAR(2)) + ':00 - ' + CAST(@SundayBlockEnd AS VARCHAR(2)) + ':00'
              END;
        PRINT '';
        PRINT '7 rows ready to insert (1 = allowed, 0 = not allowed):';
        PRINT '';
        
        -- Show the rows in a readable format
        SELECT 
            day_of_week,
            CASE day_of_week
                WHEN 1 THEN 'Sunday'
                WHEN 2 THEN 'Monday'
                WHEN 3 THEN 'Tuesday'
                WHEN 4 THEN 'Wednesday'
                WHEN 5 THEN 'Thursday'
                WHEN 6 THEN 'Friday'
                WHEN 7 THEN 'Saturday'
            END AS day_name,
            hr00, hr01, hr02, hr03, hr04, hr05, hr06, hr07, hr08, hr09, hr10, hr11,
            hr12, hr13, hr14, hr15, hr16, hr17, hr18, hr19, hr20, hr21, hr22, hr23,
            -- Show count of allowed hours for quick validation
            (CAST(hr00 AS INT)+CAST(hr01 AS INT)+CAST(hr02 AS INT)+CAST(hr03 AS INT)+
             CAST(hr04 AS INT)+CAST(hr05 AS INT)+CAST(hr06 AS INT)+CAST(hr07 AS INT)+
             CAST(hr08 AS INT)+CAST(hr09 AS INT)+CAST(hr10 AS INT)+CAST(hr11 AS INT)+
             CAST(hr12 AS INT)+CAST(hr13 AS INT)+CAST(hr14 AS INT)+CAST(hr15 AS INT)+
             CAST(hr16 AS INT)+CAST(hr17 AS INT)+CAST(hr18 AS INT)+CAST(hr19 AS INT)+
             CAST(hr20 AS INT)+CAST(hr21 AS INT)+CAST(hr22 AS INT)+CAST(hr23 AS INT)) AS allowed_hours
        FROM #ScheduleRows
        ORDER BY day_of_week;
        
        PRINT '';
        PRINT 'To execute, run with @PreviewOnly = 0';
    END
    ELSE
    BEGIN
        -- Execute the insert
        INSERT INTO ServerOps.Index_DatabaseSchedule (
            database_id, day_of_week,
            hr00, hr01, hr02, hr03, hr04, hr05, hr06, hr07, hr08, hr09, hr10, hr11,
            hr12, hr13, hr14, hr15, hr16, hr17, hr18, hr19, hr20, hr21, hr22, hr23,
            created_dttm, created_by
        )
        SELECT 
            database_id, day_of_week,
            hr00, hr01, hr02, hr03, hr04, hr05, hr06, hr07, hr08, hr09, hr10, hr11,
            hr12, hr13, hr14, hr15, hr16, hr17, hr18, hr19, hr20, hr21, hr22, hr23,
            GETDATE(),
            SUSER_SNAME()
        FROM #ScheduleRows;
        
        PRINT '========================================';
        PRINT 'SUCCESS - Schedule initialized';
        PRINT '========================================';
        PRINT '';
        PRINT 'Database: ' + @DatabaseName + ' (ID: ' + CAST(@DatabaseID AS VARCHAR(10)) + ')';
        PRINT '7 rows inserted into Index_DatabaseSchedule';
        PRINT '';
        PRINT 'Bit Flag Convention: 1 = ALLOWED, 0 = NOT ALLOWED';
        PRINT '';
        PRINT 'Schedule Pattern (hours when maintenance is BLOCKED):';
        PRINT '  Weekdays (Mon-Fri): ' + 
              CASE 
                  WHEN @WeekdayBlockStart IS NULL THEN 'No blocking (maintenance allowed 24hrs)'
                  ELSE 'Blocked ' + CAST(@WeekdayBlockStart AS VARCHAR(2)) + ':00 - ' + CAST(@WeekdayBlockEnd AS VARCHAR(2)) + ':00'
              END;
        PRINT '  Saturday: ' + 
              CASE 
                  WHEN @WeekendBlockStart IS NULL THEN 'No blocking (maintenance allowed 24hrs)'
                  ELSE 'Blocked ' + CAST(@WeekendBlockStart AS VARCHAR(2)) + ':00 - ' + CAST(@WeekendBlockEnd AS VARCHAR(2)) + ':00'
              END;
        PRINT '  Sunday: ' + 
              CASE 
                  WHEN @SundayBlockStart IS NULL THEN 'No blocking (maintenance allowed 24hrs)'
                  ELSE 'Blocked ' + CAST(@SundayBlockStart AS VARCHAR(2)) + ':00 - ' + CAST(@SundayBlockEnd AS VARCHAR(2)) + ':00'
              END;
    END
    
    DROP TABLE #ScheduleRows;
    
END;

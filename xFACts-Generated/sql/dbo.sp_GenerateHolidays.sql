
/*
================================================================================
 dbo.sp_GenerateHolidays
================================================================================
 Database:    xFACts
 Schema:      dbo
 Object:      sp_GenerateHolidays
 Type:        Stored Procedure
 Author:      Applications Team
 Version:     2.0.0
 Purpose:     Generates US federal holidays for a given year and inserts them
              into dbo.Holiday. Handles weekend observation rules
              (Saturday->Friday, Sunday->Monday) automatically.
================================================================================

 CHANGELOG:
 ----------
 Version  Date        Description
 -------  ----------  -----------------------------------------------------------
 2.0.0    2026-01-22  xFACts Refactoring - Phase 3/8
                      Moved to dbo schema (Core infrastructure)
                      Renamed from sp_Maintenance_GenerateHolidays
                      Table references updated:
                        ServerOps.Maintenance_Holiday -> dbo.Holiday
 1.0.0    2026-01-14  Initial implementation
                      US federal holidays with observed date calculation
                      Preview mode for validation before insert

================================================================================
*/

CREATE   PROCEDURE dbo.sp_GenerateHolidays
    @Year INT,
    @PreviewOnly BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    
    CREATE TABLE #Holidays (
        holiday_date   DATE,
        holiday_name   VARCHAR(50),
        observed_date  DATE,
        observed_name  VARCHAR(50)
    );
    
    -- ========================================================================
    -- Fixed Date Holidays
    -- ========================================================================
    
    INSERT INTO #Holidays (holiday_date, holiday_name)
    VALUES 
        (DATEFROMPARTS(@Year, 1, 1),   'New Year''s Day'),
        (DATEFROMPARTS(@Year, 7, 4),   'Independence Day'),
        (DATEFROMPARTS(@Year, 11, 11), 'Veterans Day'),
        (DATEFROMPARTS(@Year, 12, 25), 'Christmas Day');
    
    -- ========================================================================
    -- Rule-Based Holidays (Nth weekday of month)
    -- ========================================================================
    
    ---- MLK Day: 3rd Monday of January
    --INSERT INTO #Holidays (holiday_date, holiday_name)
    --SELECT DATEADD(DAY, ((9 - DATEPART(WEEKDAY, DATEFROMPARTS(@Year, 1, 1))) % 7) + 14, 
    --       DATEFROMPARTS(@Year, 1, 1)), 'Martin Luther King Jr. Day';
    
    ---- Presidents Day: 3rd Monday of February
    --INSERT INTO #Holidays (holiday_date, holiday_name)
    --SELECT DATEADD(DAY, ((9 - DATEPART(WEEKDAY, DATEFROMPARTS(@Year, 2, 1))) % 7) + 14, 
    --       DATEFROMPARTS(@Year, 2, 1)), 'Presidents Day';
    
    -- Memorial Day: Last Monday of May
    INSERT INTO #Holidays (holiday_date, holiday_name)
    SELECT DATEADD(DAY, -((DATEPART(WEEKDAY, DATEFROMPARTS(@Year, 5, 31)) + 5) % 7), 
           DATEFROMPARTS(@Year, 5, 31)), 'Memorial Day';
    
    -- Labor Day: 1st Monday of September
    INSERT INTO #Holidays (holiday_date, holiday_name)
    SELECT DATEADD(DAY, ((9 - DATEPART(WEEKDAY, DATEFROMPARTS(@Year, 9, 1))) % 7), 
           DATEFROMPARTS(@Year, 9, 1)), 'Labor Day';
    
    ---- Columbus Day: 2nd Monday of October
    --INSERT INTO #Holidays (holiday_date, holiday_name)
    --SELECT DATEADD(DAY, ((9 - DATEPART(WEEKDAY, DATEFROMPARTS(@Year, 10, 1))) % 7) + 7, 
    --       DATEFROMPARTS(@Year, 10, 1)), 'Columbus Day';
    
    -- Thanksgiving: 4th Thursday of November
    INSERT INTO #Holidays (holiday_date, holiday_name)
    SELECT DATEADD(DAY, ((12 - DATEPART(WEEKDAY, DATEFROMPARTS(@Year, 11, 1))) % 7) + 21, 
           DATEFROMPARTS(@Year, 11, 1)), 'Thanksgiving';
    
    -- Day After Thanksgiving: Friday after Thanksgiving
    INSERT INTO #Holidays (holiday_date, holiday_name)
    SELECT DATEADD(DAY, ((12 - DATEPART(WEEKDAY, DATEFROMPARTS(@Year, 11, 1))) % 7) + 22, 
           DATEFROMPARTS(@Year, 11, 1)), 'Day After Thanksgiving';
    
    -- ========================================================================
    -- Calculate Observed Dates (Sat->Fri, Sun->Mon)
    -- ========================================================================
    
    UPDATE #Holidays
    SET observed_date = CASE DATEPART(WEEKDAY, holiday_date)
            WHEN 1 THEN DATEADD(DAY, 1, holiday_date)   -- Sunday -> Monday
            WHEN 7 THEN DATEADD(DAY, -1, holiday_date)  -- Saturday -> Friday
            ELSE holiday_date
        END,
        observed_name = CASE 
            WHEN DATEPART(WEEKDAY, holiday_date) IN (1, 7) 
            THEN holiday_name + ' (Observed)'
            ELSE holiday_name
        END;
    
    -- ========================================================================
    -- Output
    -- ========================================================================
    
    IF @PreviewOnly = 1
    BEGIN
        SELECT 
            holiday_name AS original_name,
            holiday_date,
            DATENAME(WEEKDAY, holiday_date) AS actual_day,
            observed_name,
            observed_date,
            DATENAME(WEEKDAY, observed_date) AS observed_day
        FROM #Holidays
        ORDER BY holiday_date;
        
        PRINT '';
        PRINT 'Preview mode - no rows inserted. Run with @PreviewOnly = 0 to insert.';
    END
    ELSE
    BEGIN
        INSERT INTO dbo.Holiday (holiday_date, holiday_name)
        SELECT observed_date, observed_name
        FROM #Holidays h
        WHERE NOT EXISTS (
            SELECT 1 FROM dbo.Holiday mh
            WHERE mh.holiday_date = h.observed_date
        )
        ORDER BY observed_date;
        
        PRINT 'Inserted ' + CAST(@@ROWCOUNT AS VARCHAR) + ' holiday(s) for ' + CAST(@Year AS VARCHAR);
    END
    
    DROP TABLE #Holidays;
END

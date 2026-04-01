
/*
================================================================================
 dbo.sp_AddHoliday
================================================================================
 Database:    xFACts
 Schema:      dbo
 Object:      sp_AddHoliday
 Type:        Stored Procedure
 Author:      Applications Team
 Version:     2.0.0
 Purpose:     Adds a single holiday to dbo.Holiday with optional
              weekend observation adjustment. Use for company-specific holidays
              or one-off closures not covered by sp_GenerateHolidays.
================================================================================

 CHANGELOG:
 ----------
 Version  Date        Description
 -------  ----------  -----------------------------------------------------------
 2.0.0    2026-01-22  xFACts Refactoring - Phase 3/8
                      Moved to dbo schema (Core infrastructure)
                      Renamed from sp_Maintenance_AddHoliday
                      Table references updated:
                        ServerOps.Maintenance_Holiday -> dbo.Holiday
 1.0.0    2026-01-14  Initial implementation
                      Optional weekend observation (Sat->Fri, Sun->Mon)
                      Preview mode with duplicate detection

================================================================================
*/

CREATE   PROCEDURE dbo.sp_AddHoliday
    @HolidayDate DATE,
    @HolidayName VARCHAR(50),
    @ObserveWeekends BIT = 1,  -- Shift Sat->Fri, Sun->Mon
    @PreviewOnly BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    
    DECLARE @FinalDate DATE = @HolidayDate;
    DECLARE @FinalName VARCHAR(50) = @HolidayName;
    
    -- Apply weekend observation if requested
    IF @ObserveWeekends = 1
    BEGIN
        IF DATEPART(WEEKDAY, @HolidayDate) = 1  -- Sunday
        BEGIN
            SET @FinalDate = DATEADD(DAY, 1, @HolidayDate);
            SET @FinalName = @HolidayName + ' (Observed)';
        END
        ELSE IF DATEPART(WEEKDAY, @HolidayDate) = 7  -- Saturday
        BEGIN
            SET @FinalDate = DATEADD(DAY, -1, @HolidayDate);
            SET @FinalName = @HolidayName + ' (Observed)';
        END
    END
    
    IF @PreviewOnly = 1
    BEGIN
        SELECT 
            @HolidayName AS original_name,
            @HolidayDate AS original_date,
            DATENAME(WEEKDAY, @HolidayDate) AS original_day,
            @FinalName AS final_name,
            @FinalDate AS final_date,
            DATENAME(WEEKDAY, @FinalDate) AS final_day,
            CASE WHEN EXISTS (SELECT 1 FROM dbo.Holiday WHERE holiday_date = @FinalDate)
                 THEN 'Already exists - would skip'
                 ELSE 'Would insert'
            END AS action;
        
        PRINT '';
        PRINT 'Preview mode - no rows inserted. Run with @PreviewOnly = 0 to insert.';
    END
    ELSE
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM dbo.Holiday WHERE holiday_date = @FinalDate)
        BEGIN
            INSERT INTO dbo.Holiday (holiday_date, holiday_name)
            VALUES (@FinalDate, @FinalName);
            
            PRINT 'Inserted: ' + @FinalName + ' on ' + CONVERT(VARCHAR, @FinalDate, 101);
        END
        ELSE
        BEGIN
            PRINT 'Skipped: ' + CONVERT(VARCHAR, @FinalDate, 101) + ' already exists';
        END
    END
END



/*
================================================================================
 ServerOps.sp_Index_AddDatabaseHolidaySchedule
================================================================================
 Database:    xFACts
 Schema:      ServerOps
 Object:      sp_Index_AddDatabaseHolidaySchedule
 Type:        Stored Procedure
 Author:      Applications Team
 Version:     2.0.0
 Purpose:     Adds a holiday schedule row for a database into Index_HolidaySchedule
================================================================================

 CHANGELOG:
 ----------
 Version  Date        Description
 -------  ----------  -----------------------------------------------------------
 2.0.0    2026-01-22  xFACts Refactoring - Phase 3/8
                      Renamed from sp_Maintenance_AddDatabaseHolidaySchedule
                      Table references updated:
                        ServerOps.ServerRegistry -> dbo.ServerRegistry
                        ServerOps.DatabaseRegistry -> dbo.DatabaseRegistry
                        ServerOps.Maintenance_Holiday_Schedule -> ServerOps.Index_HolidaySchedule
 1.0.0    2026-01-14  Initial implementation
                      Resolves database and server names to IDs
                      Inserts with standard default: 9am-11pm allowed
                      Prevents duplicate entries

================================================================================
*/

CREATE     PROCEDURE [ServerOps].[sp_Index_AddDatabaseHolidaySchedule]
    @DatabaseName NVARCHAR(128),
    @ServerName NVARCHAR(128),
    @PreviewOnly BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    
    DECLARE @DatabaseId INT;
    DECLARE @ServerId INT;
    
    -- -------------------------------------------------------------------------
    -- Resolve server_id
    -- -------------------------------------------------------------------------
    SELECT @ServerId = server_id
    FROM dbo.ServerRegistry
    WHERE server_name = @ServerName
      AND is_active = 1;
    
    IF @ServerId IS NULL
    BEGIN
        RAISERROR('Server not found or inactive: %s', 16, 1, @ServerName);
        RETURN;
    END
    
    -- -------------------------------------------------------------------------
    -- Resolve database_id
    -- -------------------------------------------------------------------------
    SELECT @DatabaseId = database_id
    FROM dbo.DatabaseRegistry
    WHERE database_name = @DatabaseName
      AND server_id = @ServerId
      AND is_active = 1;
    
    IF @DatabaseId IS NULL
    BEGIN
        RAISERROR('Database not found or inactive: %s on server %s', 16, 1, @DatabaseName, @ServerName);
        RETURN;
    END
    
    -- -------------------------------------------------------------------------
    -- Check for existing entry
    -- -------------------------------------------------------------------------
    IF EXISTS (SELECT 1 FROM ServerOps.Index_HolidaySchedule WHERE database_id = @DatabaseId)
    BEGIN
        IF @PreviewOnly = 1
        BEGIN
            SELECT 
                'ALREADY EXISTS' AS action,
                @DatabaseName AS database_name,
                @ServerName AS server_name,
                @DatabaseId AS database_id;
        END
        ELSE
        BEGIN
            PRINT 'Holiday schedule already exists for ' + @DatabaseName + ' on ' + @ServerName;
        END
        RETURN;
    END
    
    -- -------------------------------------------------------------------------
    -- Preview or Insert
    -- -------------------------------------------------------------------------
    IF @PreviewOnly = 1
    BEGIN
        SELECT 
            'WOULD INSERT' AS action,
            @DatabaseName AS database_name,
            @ServerName AS server_name,
            @DatabaseId AS database_id,
            '9am-11pm allowed, 11pm-9am blocked' AS schedule_description,
            14 AS allowed_hours,
            10 AS blocked_hours;
    END
    ELSE
    BEGIN
        INSERT INTO ServerOps.Index_HolidaySchedule (
            database_id,
            hr00, hr01, hr02, hr03, hr04, hr05, hr06, hr07, hr08,
            hr09, hr10, hr11, hr12, hr13, hr14, hr15, hr16, hr17,
            hr18, hr19, hr20, hr21, hr22,
            hr23
        )
        VALUES (
            @DatabaseId,
            0, 0, 0, 0, 0, 0, 0, 0, 0,  -- hr00-hr08: Blocked
            1, 1, 1, 1, 1, 1, 1, 1, 1,  -- hr09-hr17: Allowed
            1, 1, 1, 1, 1,              -- hr18-hr22: Allowed
            0                           -- hr23: Blocked
        );
        
        PRINT 'Inserted holiday schedule for ' + @DatabaseName + ' on ' + @ServerName;
    END
END


/*
================================================================================
 dbo.sp_LogProtectionViolation
================================================================================
 Database:    xFACts
 Schema:      dbo
 Object:      sp_LogProtectionViolation
 Type:        Stored Procedure
 Author:      Applications Team
 Version:     1.0.0
 Purpose:     Autonomous transaction logging for the DDL protection trigger.
              Uses loopback linked server to persist violations before ROLLBACK.
              Loopback linked server must be created on both AG nodes.
================================================================================

 CHANGELOG:
 ----------
 Version  Date        Description
 -------  ----------  -----------------------------------------------------------
 1.0.0    2025-12-26  Initial implementation
                      Autonomous transaction logging for protection trigger

================================================================================
*/

CREATE       PROCEDURE [dbo].[sp_LogProtectionViolation]
    @violation_dttm DATETIME,
    @username NVARCHAR(100),
    @object_name NVARCHAR(400),
    @event_type NVARCHAR(200),
    @sql_text NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    
    INSERT INTO dbo.Protection_ViolationLog (
        violation_dttm,
        username,
        object_name,
        event_type,
        sql_text
    )
    VALUES (
        @violation_dttm,
        @username,
        @object_name,
        @event_type,
        @sql_text
    );
END


/*
================================================================================
 Teams.sp_QueueAlert
================================================================================
 Database:    xFACts
 Schema:      Teams
 Object:      sp_QueueAlert
 Type:        Stored Procedure
 Author:      Applications Team
 Version:     1.0.0
 Purpose:     Queues an alert for Teams webhook delivery. Inserts into AlertQueue
              for async processing by Process-TeamsAlertQueue.ps1. Supports
              deduplication via TriggerType/TriggerValue.
================================================================================

 CHANGELOG:
 ----------
 Version  Date        Description
 -------  ----------  -----------------------------------------------------------
 1.0.0    2025-12-16  Initial implementation
                      Queue alert for Teams webhook delivery

================================================================================
*/

CREATE       PROCEDURE [Teams].[sp_QueueAlert]
    @SourceModule VARCHAR(50),
    @AlertCategory VARCHAR(50),
    @Title VARCHAR(255),
    @Message NVARCHAR(MAX),
    @Color VARCHAR(20) = NULL,
    @TriggerType VARCHAR(50) = NULL,
    @TriggerValue VARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    
    -- Default colors based on category
    IF @Color IS NULL
    BEGIN
        SET @Color = CASE @AlertCategory
            WHEN 'CRITICAL' THEN 'attention'
            WHEN 'WARNING' THEN 'warning'
            WHEN 'INFO' THEN 'good'
            ELSE 'default'
        END;
    END;
    
    INSERT INTO Teams.AlertQueue (
        source_module,
        alert_category,
        title,
        message,
        color,
        status,
        trigger_type,
        trigger_value,
        created_dttm
    )
    VALUES (
        @SourceModule,
        @AlertCategory,
        @Title,
        @Message,
        @Color,
        'Pending',
        @TriggerType,
        @TriggerValue,
        GETDATE()
    );
    
    RETURN 0;
END;

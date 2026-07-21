/*
================================================================================
 Object:        FileOps.sp_AddNewMonitorConfig
 Type:          Stored Procedure
 Purpose:       Adds a new file monitor configuration with validation
 
 Parameters:
   @ServerID                 INT           - FK to ServerConfig (default: 1 for Joker)
   @ConfigName               VARCHAR(100)  - Friendly name for the monitor
   @SftpPath                 VARCHAR(500)  - Directory path on SFTP server
   @FilePattern              VARCHAR(255)  - Wildcard pattern to match files
   @CheckStartTime           TIME          - When to begin checking
   @CheckEndTime             TIME          - When to stop checking
   @EscalationTime           TIME          - When to escalate if not found
   @CheckWeekdays            BIT           - Check Monday-Friday (default: 1)
   @CheckWeekends            BIT           - Check Saturday-Sunday (default: 0)
   @CheckHolidays            BIT           - Check holidays (default: 0, not implemented)
   @NotifyOnDetection        BIT           - Teams alert on detection (default: 0)
   @NotifyOnEscalation       BIT           - Teams alert on escalation (default: 1)
   @CreateJiraOnEscalation   BIT           - Jira ticket on escalation (default: 1)
   @DefaultPriority          VARCHAR(20)   - Jira priority (default: 'High')
   @IsEnabled                BIT           - Active immediately (default: 1)
   @PreviewOnly              BIT           - Preview without inserting (default: 1)
 
 Returns:       New config_id on success (when @PreviewOnly = 0)
 
================================================================================

 CHANGELOG:
 ----------
 Version  Date        Description
 -------  ----------  -----------------------------------------------------------
 1.0.0    2025-01-21  Initial implementation

================================================================================
*/

CREATE   PROCEDURE FileOps.sp_AddNewMonitorConfig
    @ServerID                 INT           = 1,
    @ConfigName               VARCHAR(100),
    @SftpPath                 VARCHAR(500),
    @FilePattern              VARCHAR(255),
    @CheckStartTime           TIME,
    @CheckEndTime             TIME,
    @EscalationTime           TIME,
    @CheckWeekdays            BIT           = 1,
    @CheckWeekends            BIT           = 0,
    @CheckHolidays            BIT           = 0,
    @NotifyOnDetection        BIT           = 0,
    @NotifyOnEscalation       BIT           = 1,
    @CreateJiraOnEscalation   BIT           = 1,
    @DefaultPriority          VARCHAR(20)   = 'High',
    @IsEnabled                BIT           = 1,
    @PreviewOnly              BIT           = 1
AS
BEGIN
    SET NOCOUNT ON;
    
    DECLARE @ErrorMessage VARCHAR(500);
    DECLARE @NewConfigID INT;
    DECLARE @ValidationErrors TABLE (ErrorMessage VARCHAR(500));
    
    -- ========================================
    -- VALIDATION
    -- ========================================
    
    -- Check server exists and is enabled
    IF NOT EXISTS (SELECT 1 FROM FileOps.ServerConfig WHERE server_id = @ServerID)
    BEGIN
        INSERT INTO @ValidationErrors (ErrorMessage)
        VALUES ('Server ID ' + CAST(@ServerID AS VARCHAR(10)) + ' does not exist in FileOps.ServerConfig');
    END
    ELSE IF NOT EXISTS (SELECT 1 FROM FileOps.ServerConfig WHERE server_id = @ServerID AND is_enabled = 1)
    BEGIN
        INSERT INTO @ValidationErrors (ErrorMessage)
        VALUES ('Server ID ' + CAST(@ServerID AS VARCHAR(10)) + ' exists but is disabled');
    END
    
    -- Check escalation time is between start and end
    IF @EscalationTime < @CheckStartTime
    BEGIN
        INSERT INTO @ValidationErrors (ErrorMessage)
        VALUES ('Escalation time (' + CAST(@EscalationTime AS VARCHAR(8)) + ') cannot be before check start time (' + CAST(@CheckStartTime AS VARCHAR(8)) + ')');
    END
    
    IF @EscalationTime > @CheckEndTime
    BEGIN
        INSERT INTO @ValidationErrors (ErrorMessage)
        VALUES ('Escalation time (' + CAST(@EscalationTime AS VARCHAR(8)) + ') cannot be after check end time (' + CAST(@CheckEndTime AS VARCHAR(8)) + ')');
    END
    
    -- Check end time is after start time
    IF @CheckEndTime <= @CheckStartTime
    BEGIN
        INSERT INTO @ValidationErrors (ErrorMessage)
        VALUES ('Check end time (' + CAST(@CheckEndTime AS VARCHAR(8)) + ') must be after check start time (' + CAST(@CheckStartTime AS VARCHAR(8)) + ')');
    END
    
    -- Validate priority value
    IF @DefaultPriority NOT IN ('Highest', 'High', 'Medium', 'Low')
    BEGIN
        INSERT INTO @ValidationErrors (ErrorMessage)
        VALUES ('Invalid priority "' + @DefaultPriority + '". Must be: Highest, High, Medium, or Low');
    END
    
    -- Check at least one day type is selected
    IF @CheckWeekdays = 0 AND @CheckWeekends = 0
    BEGIN
        INSERT INTO @ValidationErrors (ErrorMessage)
        VALUES ('At least one of CheckWeekdays or CheckWeekends must be enabled');
    END
    
    -- Check for duplicate file pattern (same server, same path, same pattern)
    IF EXISTS (
        SELECT 1 
        FROM FileOps.MonitorConfig 
        WHERE server_id = @ServerID 
          AND sftp_path = @SftpPath 
          AND file_pattern = @FilePattern
    )
    BEGIN
        INSERT INTO @ValidationErrors (ErrorMessage)
        VALUES ('Duplicate configuration: A monitor already exists for this server, path, and file pattern');
    END
    
    -- Check for duplicate config name
    IF EXISTS (SELECT 1 FROM FileOps.MonitorConfig WHERE config_name = @ConfigName)
    BEGIN
        INSERT INTO @ValidationErrors (ErrorMessage)
        VALUES ('Duplicate config name: "' + @ConfigName + '" already exists');
    END
    
    -- Check SFTP path format (should start and end with /)
    IF LEFT(@SftpPath, 1) != '/'
    BEGIN
        INSERT INTO @ValidationErrors (ErrorMessage)
        VALUES ('SFTP path should start with / (got: "' + @SftpPath + '")');
    END
    
    IF RIGHT(@SftpPath, 1) != '/'
    BEGIN
        INSERT INTO @ValidationErrors (ErrorMessage)
        VALUES ('SFTP path should end with / (got: "' + @SftpPath + '")');
    END
    
    -- ========================================
    -- REPORT VALIDATION ERRORS
    -- ========================================
    
    IF EXISTS (SELECT 1 FROM @ValidationErrors)
    BEGIN
        PRINT '========================================';
        PRINT 'VALIDATION FAILED';
        PRINT '========================================';
        
        SELECT ErrorMessage AS [Validation Errors] FROM @ValidationErrors;
        
        RETURN -1;
    END
    
    -- ========================================
    -- PREVIEW MODE
    -- ========================================
    
    IF @PreviewOnly = 1
    BEGIN
        PRINT '========================================';
        PRINT 'PREVIEW MODE - No changes will be made';
        PRINT '========================================';
        PRINT '';
        PRINT 'The following configuration will be created:';
        PRINT '';
        
        SELECT 
            @ConfigName AS config_name,
            sc.server_name,
            @SftpPath AS sftp_path,
            @FilePattern AS file_pattern,
            @CheckStartTime AS check_start_time,
            @EscalationTime AS escalation_time,
            @CheckEndTime AS check_end_time,
            CASE WHEN @CheckWeekdays = 1 THEN 'Yes' ELSE 'No' END AS check_weekdays,
            CASE WHEN @CheckWeekends = 1 THEN 'Yes' ELSE 'No' END AS check_weekends,
            CASE WHEN @NotifyOnDetection = 1 THEN 'Yes' ELSE 'No' END AS notify_on_detection,
            CASE WHEN @NotifyOnEscalation = 1 THEN 'Yes' ELSE 'No' END AS notify_on_escalation,
            CASE WHEN @CreateJiraOnEscalation = 1 THEN 'Yes' ELSE 'No' END AS create_jira_on_escalation,
            @DefaultPriority AS default_priority,
            CASE WHEN @IsEnabled = 1 THEN 'Yes' ELSE 'No' END AS is_enabled
        FROM FileOps.ServerConfig sc
        WHERE sc.server_id = @ServerID;
        
        PRINT '';
        PRINT 'Schedule Summary:';
        PRINT '  Window: ' + CAST(@CheckStartTime AS VARCHAR(8)) + ' - ' + CAST(@CheckEndTime AS VARCHAR(8));
        PRINT '  Escalation: ' + CAST(@EscalationTime AS VARCHAR(8));
        PRINT '  Days: ' + 
            CASE 
                WHEN @CheckWeekdays = 1 AND @CheckWeekends = 1 THEN 'Daily'
                WHEN @CheckWeekdays = 1 THEN 'Monday-Friday'
                WHEN @CheckWeekends = 1 THEN 'Saturday-Sunday'
            END;
        PRINT '';
        PRINT '----------------------------------------';
        PRINT 'To execute, run again with @PreviewOnly = 0';
        PRINT '----------------------------------------';
        
        RETURN 0;
    END
    
    -- ========================================
    -- INSERT CONFIGURATION
    -- ========================================
    
    BEGIN TRY
        INSERT INTO FileOps.MonitorConfig (
            server_id,
            config_name,
            sftp_path,
            file_pattern,
            check_start_time,
            check_end_time,
            escalation_time,
            check_weekdays,
            check_weekends,
            check_holidays,
            notify_on_detection,
            notify_on_escalation,
            create_jira_on_escalation,
            default_priority,
            is_enabled
        )
        VALUES (
            @ServerID,
            @ConfigName,
            @SftpPath,
            @FilePattern,
            @CheckStartTime,
            @CheckEndTime,
            @EscalationTime,
            @CheckWeekdays,
            @CheckWeekends,
            @CheckHolidays,
            @NotifyOnDetection,
            @NotifyOnEscalation,
            @CreateJiraOnEscalation,
            @DefaultPriority,
            @IsEnabled
        );
        
        SET @NewConfigID = SCOPE_IDENTITY();
        
        PRINT '========================================';
        PRINT 'SUCCESS';
        PRINT '========================================';
        PRINT '';
        PRINT 'Monitor configuration created successfully!';
        PRINT '';
        PRINT '  Config ID: ' + CAST(@NewConfigID AS VARCHAR(10));
        PRINT '  Config Name: ' + @ConfigName;
        PRINT '  Status: ' + CASE WHEN @IsEnabled = 1 THEN 'Active - will begin scanning at next window' ELSE 'Disabled - enable when ready' END;
        PRINT '';
        
        -- Return the new config for confirmation
        SELECT 
            mc.config_id,
            mc.config_name,
            sc.server_name,
            mc.sftp_path,
            mc.file_pattern,
            mc.check_start_time,
            mc.escalation_time,
            mc.check_end_time,
            mc.is_enabled
        FROM FileOps.MonitorConfig mc
        INNER JOIN FileOps.ServerConfig sc ON mc.server_id = sc.server_id
        WHERE mc.config_id = @NewConfigID;
        
        RETURN @NewConfigID;
        
    END TRY
    BEGIN CATCH
        SET @ErrorMessage = ERROR_MESSAGE();
        
        PRINT '========================================';
        PRINT 'ERROR';
        PRINT '========================================';
        PRINT 'Failed to create monitor configuration:';
        PRINT @ErrorMessage;
        
        RETURN -1;
    END CATCH
    
END


/*
================================================================================
 Jira.sp_QueueTicket
================================================================================
 Database:    xFACts
 Schema:      Jira
 Object:      sp_QueueTicket
 Type:        Stored Procedure
 Author:      Applications Team
 Version:     1.0.0
 Purpose:     Queues a Jira ticket request for async processing by PowerShell.
              Inserts into TicketQueue for processing by Process-JiraTicketQueue.ps1.
              Supports custom fields, cascading fields, and deduplication.
================================================================================

 CHANGELOG:
 ----------
 Version  Date        Description
 -------  ----------  -----------------------------------------------------------
 1.1.0    2025-12-26  Expanded @Summary parameter from NVARCHAR(500) to NVARCHAR(1000)
 1.0.0    2025-12-14  Initial implementation
                      Queues a Jira ticket request for async processing

================================================================================
*/

    CREATE       PROCEDURE [Jira].[sp_QueueTicket]
        @SourceModule VARCHAR(50),
        @ProjectKey VARCHAR(20),
        @Summary NVARCHAR(1000),
        @Description NVARCHAR(MAX),
        @IssueType VARCHAR(50) = 'Task',
        @Priority VARCHAR(20) = 'High',
        @Assignee VARCHAR(100) = NULL,
        @EmailRecipients VARCHAR(4000) = NULL,
        @CascadingField_ID VARCHAR(50) = NULL,
        @CascadingField_ParentValue VARCHAR(500) = NULL,
        @CascadingField_ChildValue VARCHAR(500) = NULL,
        @CustomField_ID VARCHAR(50) = NULL,
        @CustomField_Value VARCHAR(500) = NULL,
        @CustomField2_ID VARCHAR(50) = NULL,
        @CustomField2_Value VARCHAR(500) = NULL,
        @CustomField3_ID VARCHAR(50) = NULL,
        @CustomField3_Value VARCHAR(500) = NULL,
        @DueDate DATE = NULL,
        @TriggerType VARCHAR(50) = NULL,
        @TriggerValue VARCHAR(200) = NULL
    AS
    BEGIN
        SET NOCOUNT ON;
        
        DECLARE @QueueID INT;
        
        BEGIN TRY
            INSERT INTO Jira.TicketQueue (
                SourceModule,
                ProjectKey,
                Summary,
                TicketDescription,
                IssueType,
                TicketPriority,
                Assignee,
                CascadingField_ID,
                CascadingField_ParentValue,
                CascadingField_ChildValue,
                CustomField_ID,
                CustomField_Value,
                CustomField2_ID,
                CustomField2_Value,
                CustomField3_ID,
                CustomField3_Value,
                DueDate,
                TriggerType,
                TriggerValue,
                EmailRecipients,
                TicketStatus
            )
            VALUES (
                @SourceModule,
                @ProjectKey,
                @Summary,
                @Description,
                @IssueType,
                @Priority,
                @Assignee,
                @CascadingField_ID,
                @CascadingField_ParentValue,
                @CascadingField_ChildValue,
                @CustomField_ID,
                @CustomField_Value,
                @CustomField2_ID,
                @CustomField2_Value,
                @CustomField3_ID,
                @CustomField3_Value,
                @DueDate,
                @TriggerType,
                @TriggerValue,
                @EmailRecipients,
                'Pending'
            );
            
            SET @QueueID = SCOPE_IDENTITY();
            
            PRINT 'Jira ticket request queued for processing (QueueID: ' + CAST(@QueueID AS VARCHAR) + ')';
            PRINT 'Summary: ' + @Summary;
            PRINT 'PowerShell processor will create ticket within 5 minutes';
            
            RETURN 0;
            
        END TRY
        BEGIN CATCH
            DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
            PRINT 'ERROR: Failed to queue Jira ticket request - ' + @ErrorMessage;
            
            BEGIN TRY
                INSERT INTO Jira.RequestLog (
                    SourceModule,
                    ServiceName,
                    RequestType,
                    ProjectKey,
                    Summary,
                    TicketKey,
                    StatusCode,
                    ResponseMessage,
                    CreatedDate,
                    CreatedBy,
                    Trigger_Type,
                    Trigger_Value,
                    Jira_Assignee
                )
                VALUES (
                    @SourceModule,
                    'Jira',
                    'QueueInsertFailed',
                    @ProjectKey,
                    @Summary,
                    NULL,
                    -99,
                    'Failed to insert to queue: ' + @ErrorMessage,
                    GETDATE(),
                    'Jira.sp_QueueTicket',
                    @TriggerType,
                    @TriggerValue,
                    NULL
                );
            END TRY
            BEGIN CATCH
                PRINT 'Warning: Could not log queue failure';
            END CATCH
            
            RETURN -1;
        END CATCH
    END;
    


-- Jira TicketQueue trigger
CREATE   TRIGGER TR_Jira_TicketQueue_QueueDepth
ON Jira.TicketQueue
AFTER INSERT
AS
BEGIN
    SET NOCOUNT ON;
    
    -- Increment running_count for the Jira queue processor
    -- This signals the orchestrator that there's work to do
    UPDATE Orchestrator.ProcessRegistry
    SET running_count = running_count + (SELECT COUNT(*) FROM inserted)
    WHERE process_name = 'Process-JiraTicketQueue'
      AND run_mode = 2;  -- Only if configured as queue-driven
END;

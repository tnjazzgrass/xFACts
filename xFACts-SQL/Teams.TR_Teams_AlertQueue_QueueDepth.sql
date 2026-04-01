CREATE   TRIGGER TR_Teams_AlertQueue_QueueDepth
ON Teams.AlertQueue
AFTER INSERT
AS
BEGIN
    SET NOCOUNT ON;
    
    -- Increment running_count for the Teams queue processor
    -- This signals the orchestrator that there's work to do
    UPDATE Orchestrator.ProcessRegistry
    SET running_count = running_count + (SELECT COUNT(*) FROM inserted)
    WHERE process_name = 'Process-TeamsAlertQueue'
      AND run_mode = 2;  -- Only if configured as queue-driven
END;

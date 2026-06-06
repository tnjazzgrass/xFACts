
CREATE TRIGGER [FileOps].[DisableETL] ON [FileOps].[MonitorLog] 
  AFTER UPDATE
AS 
BEGIN
  SET NOCOUNT ON;

--If escalation alert is detected fire the trigger to disable the ETLs 

DECLARE @config_id INT
DECLARE @event_type INT
SET @config_id = (SELECT config_id FROM INSERTED)
SET @event_type = (SELECT event_type FROM INSERTED)

IF @event_type IN ('Escalated') 
AND 
@config_id IN 
(77,78,79,80)  -- OneGI

BEGIN
UPDATE Integration.etl.tbl_B2B_CLIENTS_FILES
Set ACTIVE_FLAG = 0
WHERE ACTIVE_FLAG = 1
AND CLIENT_ID = 10678
AND SEQ_ID IN (1,2,3,4,5,6)

END

END


CREATE   TRIGGER [FileOps].[TR_FileOps_MonitorLog_DisableETL_OneGI] ON [FileOps].[MonitorLog]
  AFTER INSERT
AS
BEGIN
  SET NOCOUNT ON;

  -- If any inserted row is an escalation for one of the 4 OneGI configs,
  -- disable the IBM/B2B automation for the 6 target process rows.
  IF EXISTS (
      SELECT 1
      FROM INSERTED
      WHERE event_type = 'Escalated'
        AND config_id IN (77, 78, 79, 80)   -- OneGI
  )
  BEGIN
      UPDATE Integration.etl.tbl_B2B_CLIENTS_FILES
      SET ACTIVE_FLAG = 0
      WHERE ACTIVE_FLAG = 1
        AND CLIENT_ID = 10678
        AND SEQ_ID IN (1, 2, 3, 4, 5, 6);
  END
END

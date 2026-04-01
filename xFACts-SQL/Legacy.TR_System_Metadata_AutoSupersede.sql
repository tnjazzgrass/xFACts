
/*
================================================================================
 dbo.TR_System_Metadata_AutoSupersede
================================================================================
 Database:    xFACts
 Schema:      dbo
 Object:      TR_System_Metadata_AutoSupersede
 Type:        DML Trigger
 Author:      Applications Team
 Version:     1.0.0
 Purpose:     Automatically marks previous versions of the same object as
              SUPERSEDED when a new version is inserted into System_Metadata.
              Enables point-in-time version queries without manual housekeeping.
================================================================================

 CHANGELOG:
 ----------
 Version  Date        Description
 -------  ----------  -----------------------------------------------------------
 1.0.0    2025-12-27  Initial implementation
                      Auto-supersedes previous ACTIVE versions on INSERT

================================================================================
*/

CREATE   TRIGGER [dbo].[TR_System_Metadata_AutoSupersede]
ON [dbo].[System_Metadata]
AFTER INSERT
AS
BEGIN
    SET NOCOUNT ON;
    
    -- Mark previous versions of the same object as SUPERSEDED
    UPDATE sm
    SET status = 'SUPERSEDED',
        superseded_reason = 'VERSION',
        status_changed_date = i.deployed_date,
        status_changed_by = i.deployed_by
    FROM dbo.System_Metadata sm
    INNER JOIN inserted i 
        ON sm.module_name = i.module_name
        AND sm.component_name = i.component_name
        AND sm.component_type = i.component_type
    WHERE sm.metadata_id != i.metadata_id
      AND sm.status = 'ACTIVE';
END;

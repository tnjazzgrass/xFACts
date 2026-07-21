

/*
================================================================================
 ServerOps.sp_Activity_CorrelateIncidents
================================================================================
 Database:    xFACts
 Schema:      ServerOps
 Object:      sp_Activity_CorrelateIncidents
 Type:        Stored Procedure
 Author:      Applications Team
 Version:     2.0.0
 Purpose:     Analyzes collected DMV metrics for all monitored servers, detects
              threshold crossings (PLE, HADR, memory grants), correlates with
              concurrent activity, and logs heartbeats and incidents.
================================================================================

 CHANGELOG:
 ----------
 Version  Date        Description
 -------  ----------  -----------------------------------------------------------
 2.0.0    2026-01-23  Refactoring standardization:
                      - ServerOps.Activity_Config -> dbo.GlobalConfig
                      - ServerOps.ServerRegistry -> dbo.ServerRegistry
                      - monitor_activity -> serverops_activity_enabled
                      - Activity_Incident_Log -> Activity_IncidentLog
                      - Activity_Incident_Type -> Activity_IncidentType
 1.0.0    2026-01-16  Initial implementation
                      Loops through all monitor_activity=1 servers
                      Checks PLE, HADR, and memory grant thresholds
                      Correlates incidents with LRQs on self or AG partner
                      Writes to Activity_Heartbeat and Activity_IncidentLog

================================================================================
*/

CREATE       PROCEDURE [ServerOps].[sp_Activity_CorrelateIncidents]
    @preview_only BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    
    -- ========================================================================
    -- THRESHOLD VARIABLES (loaded once, used for all servers)
    -- ========================================================================
    
    DECLARE @hadr_warning_ms BIGINT;
    DECLARE @hadr_critical_ms BIGINT;
    DECLARE @ple_warning INT;
    DECLARE @ple_critical INT;
    DECLARE @zombie_warning INT;
    DECLARE @memory_grants_threshold INT;
    
    -- Load thresholds from config
    SELECT @hadr_warning_ms = CAST(setting_value AS BIGINT) 
    FROM dbo.GlobalConfig WHERE module_name = 'ServerOps' AND category = 'Activity_DMV' AND setting_name = 'incident_hadr_spike_warning_ms';
    
    SELECT @hadr_critical_ms = CAST(setting_value AS BIGINT) 
    FROM dbo.GlobalConfig WHERE module_name = 'ServerOps' AND category = 'Activity_DMV' AND setting_name = 'incident_hadr_spike_critical_ms';
    
    SELECT @ple_warning = CAST(setting_value AS INT) 
    FROM dbo.GlobalConfig WHERE module_name = 'ServerOps' AND category = 'Activity_DMV' AND setting_name = 'incident_ple_warning_threshold';
    
    SELECT @ple_critical = CAST(setting_value AS INT) 
    FROM dbo.GlobalConfig WHERE module_name = 'ServerOps' AND category = 'Activity_DMV' AND setting_name = 'incident_ple_critical_threshold';
    
    SELECT @zombie_warning = CAST(setting_value AS INT) 
    FROM dbo.GlobalConfig WHERE module_name = 'ServerOps' AND category = 'Activity_DMV' AND setting_name = 'incident_zombie_warning_threshold';
    
    SELECT @memory_grants_threshold = CAST(setting_value AS INT) 
    FROM dbo.GlobalConfig WHERE module_name = 'ServerOps' AND category = 'Activity_DMV' AND setting_name = 'incident_memory_grants_threshold';
    
    -- Defaults if config missing
    SET @hadr_warning_ms = ISNULL(@hadr_warning_ms, 500000);
    SET @hadr_critical_ms = ISNULL(@hadr_critical_ms, 5000000);
    SET @ple_warning = ISNULL(@ple_warning, 300);
    SET @ple_critical = ISNULL(@ple_critical, 100);
    SET @zombie_warning = ISNULL(@zombie_warning, 500);
    SET @memory_grants_threshold = ISNULL(@memory_grants_threshold, 5);
    
    -- ========================================================================
    -- SERVER LOOP VARIABLES
    -- ========================================================================
    
    DECLARE @server_name VARCHAR(128);
    DECLARE @server_count INT = 0;
    
    -- Per-server metrics
    DECLARE @current_ple INT;
    DECLARE @current_zombies INT;
    DECLARE @current_grants_pending INT;
    DECLARE @current_cache_hit DECIMAL(5,2);
    DECLARE @hadr_delta_ms BIGINT;
    DECLARE @snapshot_dttm DATETIME2(0);
    DECLARE @prev_snapshot_dttm DATETIME2(0);
    DECLARE @secondary_server VARCHAR(128);
    
    -- Status tracking
    DECLARE @overall_status VARCHAR(20);
    DECLARE @incidents_logged TINYINT;
    DECLARE @heartbeat_id BIGINT;
    
    -- Correlation variables
    DECLARE @correlation_window_min INT;
    DECLARE @window_start DATETIME2(0);
    DECLARE @window_end DATETIME2(0);
    DECLARE @correlated_source VARCHAR(100);
    DECLARE @correlated_query VARCHAR(MAX);
    DECLARE @correlated_user VARCHAR(128);
    DECLARE @correlated_database VARCHAR(128);
    DECLARE @correlated_duration_sec INT;
    DECLARE @correlated_count INT;
    DECLARE @summary VARCHAR(1000);
    
    -- ========================================================================
    -- PREVIEW HEADER
    -- ========================================================================
    
    IF @preview_only = 1
    BEGIN
        PRINT '=== INCIDENT CORRELATION PREVIEW (ALL MONITORED SERVERS) ===';
        PRINT 'Thresholds:';
        PRINT '  PLE Warning: ' + CAST(@ple_warning AS VARCHAR(10)) + ', Critical: ' + CAST(@ple_critical AS VARCHAR(10));
        PRINT '  HADR Warning: ' + CAST(@hadr_warning_ms/1000 AS VARCHAR(10)) + 's, Critical: ' + CAST(@hadr_critical_ms/1000 AS VARCHAR(10)) + 's';
        PRINT '  Zombie Warning: ' + CAST(@zombie_warning AS VARCHAR(10));
        PRINT '  Memory Grants: ' + CAST(@memory_grants_threshold AS VARCHAR(10));
        PRINT '';
    END
    
    -- ========================================================================
    -- LOOP THROUGH MONITORED SERVERS
    -- ========================================================================
    
    DECLARE server_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT server_name 
        FROM dbo.ServerRegistry 
        WHERE serverops_activity_enabled = 1 
          AND is_active = 1
        ORDER BY server_name;
    
    OPEN server_cursor;
    FETCH NEXT FROM server_cursor INTO @server_name;
    
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @server_count = @server_count + 1;
        
        -- Reset per-server variables
        SET @overall_status = 'HEALTHY';
        SET @incidents_logged = 0;
        SET @current_ple = NULL;
        SET @current_zombies = NULL;
        SET @current_grants_pending = NULL;
        SET @current_cache_hit = NULL;
        SET @hadr_delta_ms = NULL;
        SET @snapshot_dttm = NULL;
        SET @secondary_server = NULL;
        
        -- Reset correlation variables
        SET @correlated_source = NULL;
        SET @correlated_query = NULL;
        SET @correlated_user = NULL;
        SET @correlated_database = NULL;
        SET @correlated_duration_sec = NULL;
        SET @correlated_count = NULL;
        
        -- ====================================================================
        -- GET LATEST SNAPSHOT DATA FOR THIS SERVER
        -- ====================================================================
        
        -- Get latest memory snapshot
        SELECT TOP 1
            @snapshot_dttm = snapshot_dttm,
            @current_ple = ple_seconds,
            @current_cache_hit = buffer_cache_hit_ratio,
            @current_grants_pending = memory_grants_pending
        FROM ServerOps.Activity_DMV_Memory
        WHERE server_name = @server_name
        ORDER BY snapshot_dttm DESC;
        
        -- Skip if no recent data for this server
        IF @snapshot_dttm IS NULL
        BEGIN
            IF @preview_only = 1
                PRINT '--- ' + @server_name + ': No recent data, skipping ---';
            
            FETCH NEXT FROM server_cursor INTO @server_name;
            CONTINUE;
        END
        
        -- Check if we already processed this snapshot (avoid duplicates on re-runs)
        IF @preview_only = 0 AND EXISTS (
            SELECT 1 FROM ServerOps.Activity_Heartbeat 
            WHERE server_name = @server_name 
              AND snapshot_dttm = @snapshot_dttm
        )
        BEGIN
            FETCH NEXT FROM server_cursor INTO @server_name;
            CONTINUE;
        END
        
        -- Get latest zombie count
        SELECT TOP 1 @current_zombies = zombie_count
        FROM ServerOps.Activity_DMV_ConnectionHealth
        WHERE server_name = @server_name
        ORDER BY snapshot_dttm DESC;
        
        -- Calculate HADR delta (current - previous snapshot)
        SELECT TOP 1 @prev_snapshot_dttm = snapshot_dttm
        FROM ServerOps.Activity_DMV_WaitStats
        WHERE server_name = @server_name
          AND wait_type = 'HADR_SYNC_COMMIT'
          AND snapshot_dttm < @snapshot_dttm
        ORDER BY snapshot_dttm DESC;
        
        IF @prev_snapshot_dttm IS NOT NULL
        BEGIN
            SELECT @hadr_delta_ms = curr.wait_time_ms - prev.wait_time_ms
            FROM (SELECT wait_time_ms FROM ServerOps.Activity_DMV_WaitStats 
                  WHERE server_name = @server_name AND wait_type = 'HADR_SYNC_COMMIT' 
                  AND snapshot_dttm = @snapshot_dttm) curr,
                 (SELECT wait_time_ms FROM ServerOps.Activity_DMV_WaitStats 
                  WHERE server_name = @server_name AND wait_type = 'HADR_SYNC_COMMIT' 
                  AND snapshot_dttm = @prev_snapshot_dttm) prev;
            
            -- Handle counter reset (negative delta)
            IF @hadr_delta_ms < 0 SET @hadr_delta_ms = 0;
        END
        
        -- Determine secondary server (AG partner)
        SET @secondary_server = NULL;

        SELECT @secondary_server = sr2.server_name
        FROM dbo.ServerRegistry sr1
        INNER JOIN dbo.ServerRegistry sr2 
            ON sr1.ag_cluster_name = sr2.ag_cluster_name
            AND sr1.server_name <> sr2.server_name
            AND sr2.server_type = 'SQL_SERVER'  -- Exclude the listener
            AND sr2.is_active = 1
        WHERE sr1.server_name = @server_name
          AND sr1.ag_cluster_name IS NOT NULL;
        
        -- ====================================================================
        -- PREVIEW OUTPUT FOR THIS SERVER
        -- ====================================================================
        
        IF @preview_only = 1
        BEGIN
            PRINT '--- ' + @server_name + ' (snapshot: ' + CONVERT(VARCHAR(20), @snapshot_dttm, 120) + ') ---';
            PRINT '  PLE: ' + CAST(ISNULL(@current_ple, 0) AS VARCHAR(10)) + 
                  CASE WHEN @current_ple < @ple_critical THEN ' <<<< CRITICAL'
                       WHEN @current_ple < @ple_warning THEN ' <<<< WARNING'
                       ELSE ' (OK)' END;
            PRINT '  HADR Delta: ' + CAST(ISNULL(@hadr_delta_ms, 0)/1000 AS VARCHAR(20)) + 's' +
                  CASE WHEN ISNULL(@hadr_delta_ms,0) >= @hadr_critical_ms THEN ' <<<< CRITICAL'
                       WHEN ISNULL(@hadr_delta_ms,0) >= @hadr_warning_ms THEN ' <<<< WARNING'
                       ELSE ' (OK)' END;
            PRINT '  Zombies: ' + CAST(ISNULL(@current_zombies, 0) AS VARCHAR(10)) +
                  CASE WHEN ISNULL(@current_zombies,0) >= @zombie_warning THEN ' <<<< WARNING (not logged yet)' ELSE ' (OK)' END;
            PRINT '  Grants Pending: ' + CAST(ISNULL(@current_grants_pending, 0) AS VARCHAR(10)) +
                  CASE WHEN ISNULL(@current_grants_pending,0) >= @memory_grants_threshold THEN ' <<<< WARNING' ELSE ' (OK)' END;
        END
        
        -- ====================================================================
        -- CHECK THRESHOLDS AND LOG INCIDENTS
        -- ====================================================================
        
        -- ----- PLE CRISIS CHECK -----
        IF @current_ple < @ple_critical
        BEGIN
            SET @overall_status = 'CRITICAL';
            
            SELECT @correlation_window_min = correlation_window_min 
            FROM ServerOps.Activity_IncidentType WHERE incident_type_code = 'PLE_CRISIS';
            SET @correlation_window_min = ISNULL(@correlation_window_min, 15);
            
            SET @window_start = DATEADD(MINUTE, -@correlation_window_min, @snapshot_dttm);
            SET @window_end = @snapshot_dttm;
            
            -- Look for heavy queries on this server
            SELECT TOP 1
                @correlated_source = CASE 
                    WHEN username LIKE '%sqlmon%' THEN 'Redgate Monitoring'
                    WHEN sql_text LIKE '%fn_xe_file_target_read_file%' THEN 'xFACts XE Collection'
                    ELSE 'User Query (' + ISNULL(database_name, 'unknown') + ')'
                END,
                @correlated_query = LEFT(sql_text, 500),
                @correlated_user = username,
                @correlated_database = database_name,
                @correlated_duration_sec = duration_ms / 1000
            FROM ServerOps.Activity_XE_LRQ
            WHERE server_name = @server_name
              AND event_timestamp >= @window_start
              AND event_timestamp <= @window_end
            ORDER BY duration_ms DESC;
            
            SELECT @correlated_count = COUNT(*)
            FROM ServerOps.Activity_XE_LRQ
            WHERE server_name = @server_name
              AND event_timestamp >= @window_start
              AND event_timestamp <= @window_end;
            
            SET @summary = 'PLE dropped to ' + CAST(@current_ple AS VARCHAR(10)) + ' seconds (CRISIS level). ' +
                           CAST(ISNULL(@correlated_count, 0) AS VARCHAR(10)) + ' long-running queries in window.';
            
            IF @preview_only = 0
            BEGIN
                INSERT INTO ServerOps.Activity_IncidentLog (
                    incident_type_code, detected_dttm, severity, primary_server,
                    primary_metric_name, primary_metric_value, secondary_server,
                    correlation_window_start, correlation_window_end,
                    correlated_source, correlated_query, correlated_user, 
                    correlated_database, correlated_duration_sec, correlated_count, summary
                ) VALUES (
                    'PLE_CRISIS', @snapshot_dttm, 'CRITICAL', @server_name,
                    'ple_seconds', CAST(@current_ple AS VARCHAR(50)), NULL,
                    @window_start, @window_end,
                    @correlated_source, @correlated_query, @correlated_user,
                    @correlated_database, @correlated_duration_sec, @correlated_count, @summary
                );
                SET @incidents_logged = @incidents_logged + 1;
            END
            ELSE
                PRINT '  >> Would log PLE_CRISIS incident';
        END
        -- ----- PLE WARNING CHECK -----
        ELSE IF @current_ple < @ple_warning
        BEGIN
            IF @overall_status = 'HEALTHY' SET @overall_status = 'WARNING';
            
            SET @summary = 'PLE dropped to ' + CAST(@current_ple AS VARCHAR(10)) + ' seconds (below warning threshold).';
            
            IF @preview_only = 0
            BEGIN
                INSERT INTO ServerOps.Activity_IncidentLog (
                    incident_type_code, detected_dttm, severity, primary_server,
                    primary_metric_name, primary_metric_value, summary
                ) VALUES (
                    'PLE_WARNING', @snapshot_dttm, 'WARNING', @server_name,
                    'ple_seconds', CAST(@current_ple AS VARCHAR(50)), @summary
                );
                SET @incidents_logged = @incidents_logged + 1;
            END
            ELSE
                PRINT '  >> Would log PLE_WARNING incident';
        END
        
        -- ----- HADR SPIKE CRITICAL CHECK -----
        IF ISNULL(@hadr_delta_ms, 0) >= @hadr_critical_ms
        BEGIN
            SET @overall_status = 'CRITICAL';
            
            SELECT @correlation_window_min = correlation_window_min 
            FROM ServerOps.Activity_IncidentType WHERE incident_type_code = 'HADR_SPIKE_CRITICAL';
            SET @correlation_window_min = ISNULL(@correlation_window_min, 5);
            
            SET @window_start = DATEADD(MINUTE, -@correlation_window_min, @snapshot_dttm);
            SET @window_end = @snapshot_dttm;
            
            -- Reset correlation variables before secondary lookup
            SET @correlated_source = NULL;
            SET @correlated_query = NULL;
            SET @correlated_user = NULL;
            SET @correlated_database = NULL;
            SET @correlated_duration_sec = NULL;
            
            -- Look for heavy queries on SECONDARY
            IF @secondary_server IS NOT NULL
            BEGIN
                SELECT TOP 1
                    @correlated_source = CASE 
                        WHEN username LIKE '%sqlmon%' THEN 'Redgate Monitoring'
                        WHEN sql_text LIKE '%fn_xe_file_target_read_file%' THEN 'xFACts XE Collection'
                        WHEN sql_text LIKE '%upsrt_dttm%' THEN 'Azure Data Sync'
                        WHEN database_name = 'BIDATA' THEN 'BIDATA Builds'
                        WHEN database_name = 'PROCESSES' THEN 'PROCESSES Jobs'
                        ELSE 'Other (' + ISNULL(database_name, 'unknown') + ')'
                    END,
                    @correlated_query = LEFT(sql_text, 500),
                    @correlated_user = username,
                    @correlated_database = database_name,
                    @correlated_duration_sec = duration_ms / 1000
                FROM ServerOps.Activity_XE_LRQ
                WHERE server_name = @secondary_server
                  AND event_timestamp >= @window_start
                  AND event_timestamp <= @window_end
                ORDER BY duration_ms DESC;
                
                SELECT @correlated_count = COUNT(*)
                FROM ServerOps.Activity_XE_LRQ
                WHERE server_name = @secondary_server
                  AND event_timestamp >= @window_start
                  AND event_timestamp <= @window_end;
            END
            
            SET @summary = 'HADR_SYNC_COMMIT delta reached ' + CAST(@hadr_delta_ms / 1000 AS VARCHAR(20)) + 
                           ' seconds (CRITICAL). ' + CAST(ISNULL(@correlated_count, 0) AS VARCHAR(10)) + 
                           ' LRQs on ' + ISNULL(@secondary_server, 'secondary') + '. Primary source: ' + ISNULL(@correlated_source, 'Unknown');
            
            IF @preview_only = 0
            BEGIN
                INSERT INTO ServerOps.Activity_IncidentLog (
                    incident_type_code, detected_dttm, severity, primary_server,
                    primary_metric_name, primary_metric_value, secondary_server,
                    correlation_window_start, correlation_window_end,
                    correlated_source, correlated_query, correlated_user, 
                    correlated_database, correlated_duration_sec, correlated_count, summary
                ) VALUES (
                    'HADR_SPIKE_CRITICAL', @snapshot_dttm, 'CRITICAL', @server_name,
                    'hadr_sync_commit_delta_ms', CAST(@hadr_delta_ms AS VARCHAR(50)), @secondary_server,
                    @window_start, @window_end,
                    @correlated_source, @correlated_query, @correlated_user,
                    @correlated_database, @correlated_duration_sec, @correlated_count, @summary
                );
                SET @incidents_logged = @incidents_logged + 1;
            END
            ELSE
                PRINT '  >> Would log HADR_SPIKE_CRITICAL incident (correlated: ' + ISNULL(@correlated_source, 'none') + ')';
        END
        -- ----- HADR SPIKE WARNING CHECK -----
        ELSE IF ISNULL(@hadr_delta_ms, 0) >= @hadr_warning_ms
        BEGIN
            IF @overall_status = 'HEALTHY' SET @overall_status = 'WARNING';
            
            SELECT @correlation_window_min = correlation_window_min 
            FROM ServerOps.Activity_IncidentType WHERE incident_type_code = 'HADR_SPIKE';
            SET @correlation_window_min = ISNULL(@correlation_window_min, 5);
            
            SET @window_start = DATEADD(MINUTE, -@correlation_window_min, @snapshot_dttm);
            SET @window_end = @snapshot_dttm;
            
            -- Reset correlation variables
            SET @correlated_source = NULL;
            SET @correlated_query = NULL;
            SET @correlated_user = NULL;
            SET @correlated_database = NULL;
            SET @correlated_duration_sec = NULL;
            
            -- Look for heavy queries on SECONDARY
            IF @secondary_server IS NOT NULL
            BEGIN
                SELECT TOP 1
                @correlated_source = CASE 
                    WHEN username LIKE '%sqlmon%' THEN 'Redgate Monitoring'
                    WHEN username LIKE '%reports%' THEN 'Reporting Server Queries'
                    WHEN sql_text LIKE '%fn_xe_file_target_read_file%' THEN 'xFACts XE Collection'
                    WHEN sql_text LIKE '%upsrt_dttm%' THEN 'Azure Data Sync'
                    WHEN database_name = 'BIDATA' THEN 'BIDATA Builds'
                    WHEN database_name = 'PROCESSES' THEN 'PROCESSES Jobs'
                    ELSE 'Other (' + ISNULL(database_name, 'unknown') + ')'
                    END,
                    @correlated_query = LEFT(sql_text, 500),
                    @correlated_user = username,
                    @correlated_database = database_name,
                    @correlated_duration_sec = duration_ms / 1000
                FROM ServerOps.Activity_XE_LRQ
                WHERE server_name = @secondary_server
                  AND event_timestamp >= @window_start
                  AND event_timestamp <= @window_end
                ORDER BY duration_ms DESC;
                
                SELECT @correlated_count = COUNT(*)
                FROM ServerOps.Activity_XE_LRQ
                WHERE server_name = @secondary_server
                  AND event_timestamp >= @window_start
                  AND event_timestamp <= @window_end;
            END
            
            SET @summary = 'HADR_SYNC_COMMIT delta reached ' + CAST(@hadr_delta_ms / 1000 AS VARCHAR(20)) + 
                           ' seconds. ' + CAST(ISNULL(@correlated_count, 0) AS VARCHAR(10)) + 
                           ' LRQs on ' + ISNULL(@secondary_server, 'secondary') + '. Primary source: ' + ISNULL(@correlated_source, 'Unknown');
            
            IF @preview_only = 0
            BEGIN
                INSERT INTO ServerOps.Activity_IncidentLog (
                    incident_type_code, detected_dttm, severity, primary_server,
                    primary_metric_name, primary_metric_value, secondary_server,
                    correlation_window_start, correlation_window_end,
                    correlated_source, correlated_query, correlated_user, 
                    correlated_database, correlated_duration_sec, correlated_count, summary
                ) VALUES (
                    'HADR_SPIKE', @snapshot_dttm, 'WARNING', @server_name,
                    'hadr_sync_commit_delta_ms', CAST(@hadr_delta_ms AS VARCHAR(50)), @secondary_server,
                    @window_start, @window_end,
                    @correlated_source, @correlated_query, @correlated_user,
                    @correlated_database, @correlated_duration_sec, @correlated_count, @summary
                );
                SET @incidents_logged = @incidents_logged + 1;
            END
            ELSE
                PRINT '  >> Would log HADR_SPIKE incident (correlated: ' + ISNULL(@correlated_source, 'none') + ')';
        END
        
        -- ----- MEMORY GRANTS PENDING CHECK -----
        IF ISNULL(@current_grants_pending, 0) >= @memory_grants_threshold
        BEGIN
            IF @overall_status = 'HEALTHY' SET @overall_status = 'WARNING';
            
            SET @summary = CAST(@current_grants_pending AS VARCHAR(10)) + ' queries waiting for memory grants.';
            
            IF @preview_only = 0
            BEGIN
                INSERT INTO ServerOps.Activity_IncidentLog (
                    incident_type_code, detected_dttm, severity, primary_server,
                    primary_metric_name, primary_metric_value, summary
                ) VALUES (
                    'MEMORY_GRANTS_PENDING', @snapshot_dttm, 'WARNING', @server_name,
                    'memory_grants_pending', CAST(@current_grants_pending AS VARCHAR(50)), @summary
                );
                SET @incidents_logged = @incidents_logged + 1;
            END
            ELSE
                PRINT '  >> Would log MEMORY_GRANTS_PENDING incident';
        END
        
        -- ====================================================================
        -- WRITE HEARTBEAT RECORD FOR THIS SERVER
        -- ====================================================================
        
        IF @preview_only = 0
        BEGIN
            INSERT INTO ServerOps.Activity_Heartbeat (
                server_name, snapshot_dttm, overall_status,
                ple_seconds, hadr_sync_delta_ms, zombie_count, buffer_cache_hit_pct,
                incidents_logged
            ) VALUES (
                @server_name, @snapshot_dttm, @overall_status,
                @current_ple, @hadr_delta_ms, @current_zombies, @current_cache_hit,
                @incidents_logged
            );
            
            SET @heartbeat_id = SCOPE_IDENTITY();
            
            -- Update incidents with heartbeat_id
            UPDATE ServerOps.Activity_IncidentLog
            SET heartbeat_id = @heartbeat_id
            WHERE heartbeat_id IS NULL
              AND primary_server = @server_name
              AND detected_dttm = @snapshot_dttm;
        END
        ELSE
        BEGIN
            PRINT '  Status: ' + @overall_status + ', Incidents: ' + CAST(@incidents_logged AS VARCHAR(10));
            PRINT '';
        END
        
        FETCH NEXT FROM server_cursor INTO @server_name;
    END
    
    CLOSE server_cursor;
    DEALLOCATE server_cursor;
    
    -- ========================================================================
    -- FINAL SUMMARY
    -- ========================================================================
    
    IF @preview_only = 1
    BEGIN
        PRINT '=== END PREVIEW ===';
        PRINT 'Servers processed: ' + CAST(@server_count AS VARCHAR(10));
        PRINT 'Run with @preview_only = 0 to write data.';
    END
    
END

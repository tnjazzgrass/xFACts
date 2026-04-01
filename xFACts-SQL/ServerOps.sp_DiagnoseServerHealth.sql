
/*
================================================================================
 ServerOps.sp_DiagnoseServerHealth
================================================================================
 Database:    xFACts
 Schema:      ServerOps
 Object:      sp_DiagnoseServerHealth
 Type:        Stored Procedure
 Author:      Applications Team
 Version:     2.0.0
 Purpose:     Interactive diagnostic tool for analyzing server health using
              collected DMV metrics. Provides guided analysis with educational
              explanations of memory pressure, connection health, and wait
              statistics to help identify root causes of performance issues.
================================================================================

 CHANGELOG:
 ----------
 Version  Date        Description
 -------  ----------  -----------------------------------------------------------
 2.0.0    2026-01-23  Refactoring: Activity_DMV_Wait_Stats -> Activity_DMV_WaitStats;
                      Activity_DMV_Connection_Health -> Activity_DMV_ConnectionHealth
 1.0.0    2026-01-16  Initial implementation
                      Memory analysis with PLE trending and buffer cache health
                      Connection health with zombie detection and JDBC breakdown
                      Wait statistics and category analysis with category grouping
                      Educational output explaining metrics and thresholds
                      HADR health analysis with cross-server LRQ correlation
                      Monitoring overhead detection (Redgate, xFACts, Azure sync)
                      xFACts self-check section
                      @detail_level TINYINT (0=Technical, 1=Standard, 2=Educational)
                      @output_format parameter for future MARKDOWN/TABLE support
                      Dynamic AG partner detection from DMVs
================================================================================
*/

CREATE     PROCEDURE [ServerOps].[sp_DiagnoseServerHealth]
    @server_name VARCHAR(128) = 'DM-PROD-DB',
    @lookback_minutes INT = 60,
    @detail_level TINYINT = 1,  -- 0=Technical, 1=Standard, 2=Educational
    @include_recommendations BIT = 1,
    @output_format VARCHAR(20) = 'PRINT'  -- PRINT, MARKDOWN, TABLE (future)
AS
BEGIN
    SET NOCOUNT ON;
    
    -- ========================================================================
    -- VARIABLE DECLARATIONS
    -- ========================================================================
    
    -- AG Health
    DECLARE @ag_name VARCHAR(128);
    DECLARE @expected_primary VARCHAR(128) = 'DM-PROD-DB';
    DECLARE @actual_role VARCHAR(50);
    DECLARE @ag_health VARCHAR(50);
    DECLARE @ag_is_healthy BIT = 0;
    DECLARE @secondary_server VARCHAR(128);
    
    -- Memory metrics
    DECLARE @current_ple INT;
    DECLARE @min_ple INT;
    DECLARE @avg_ple DECIMAL(10,2);
    DECLARE @max_ple INT;
    DECLARE @ple_trend VARCHAR(20);
    DECLARE @first_half_avg FLOAT;
    DECLARE @second_half_avg FLOAT;
    DECLARE @current_cache_hit DECIMAL(5,2);
    DECLARE @min_cache_hit DECIMAL(5,2);
    DECLARE @current_grants_pending INT;
    DECLARE @max_grants_pending INT;
    DECLARE @memory_status VARCHAR(20);
    DECLARE @ple_crash_count INT;
    
    -- Connection metrics
    DECLARE @current_connections INT;
    DECLARE @current_zombies INT;
    DECLARE @max_zombies INT;
    DECLARE @oldest_zombie_min INT;
    DECLARE @jdbc_zombies INT;
    DECLARE @zombie_status VARCHAR(20);
    DECLARE @zombie_delta INT;
    
    -- Wait metrics
    DECLARE @pageiolatch_seconds DECIMAL(10,2);
    DECLARE @lck_seconds DECIMAL(10,2);
    DECLARE @cxpacket_seconds DECIMAL(10,2);
    DECLARE @cxconsumer_seconds DECIMAL(10,2);
    DECLARE @hadr_sync_seconds DECIMAL(10,2);
    DECLARE @top_wait_type VARCHAR(60);
    DECLARE @top_wait_seconds DECIMAL(10,2);
    DECLARE @wait_status VARCHAR(20);
    DECLARE @total_problem_waits DECIMAL(18,2);
    
    -- HADR metrics
    DECLARE @hadr_status VARCHAR(20);
    DECLARE @max_hadr_sync DECIMAL(10,2);
    DECLARE @avg_hadr_sync DECIMAL(10,2);
    DECLARE @hadr_spike_count INT;
    
    -- Monitoring overhead
    DECLARE @redgate_lrq_count INT;
    DECLARE @redgate_total_seconds DECIMAL(10,2);
    DECLARE @xfacts_wait_seconds DECIMAL(10,2);
    DECLARE @azure_sync_count INT;
    DECLARE @azure_sync_seconds DECIMAL(10,2);
    
    -- Workload metrics
    DECLARE @current_blocked INT;
    DECLARE @max_blocked INT;
    DECLARE @current_active_requests INT;
    
    -- Overall assessment
    DECLARE @overall_status VARCHAR(20);
    DECLARE @issue_count INT = 0;
    
    -- Snapshot tracking
    DECLARE @snapshot_count INT;
    DECLARE @latest_snapshot DATETIME;
    DECLARE @oldest_snapshot DATETIME;
    
    -- Time window
    DECLARE @window_start DATETIME = DATEADD(MINUTE, -@lookback_minutes, GETDATE());
    DECLARE @window_end DATETIME = GETDATE();
    
    -- ========================================================================
    -- HEADER
    -- ========================================================================
    
    PRINT '================================================================================';
    PRINT '  SERVER HEALTH DIAGNOSTIC REPORT';
    PRINT '================================================================================';
    PRINT '';
    PRINT '  Server:          ' + @server_name;
    PRINT '  Analysis Window: Last ' + CAST(@lookback_minutes AS VARCHAR(10)) + ' minutes';
    PRINT '  Report Time:     ' + CONVERT(VARCHAR(20), GETDATE(), 120);
    PRINT '  Detail Level:    ' + CASE @detail_level 
                                    WHEN 0 THEN 'Technical (metrics only)'
                                    WHEN 1 THEN 'Standard (with explanations)'
                                    WHEN 2 THEN 'Educational (plain English)'
                                    ELSE 'Unknown' END;
    PRINT '';
    PRINT '================================================================================';
    
    -- ========================================================================
    -- SECTION 0: DATA AVAILABILITY CHECK
    -- ========================================================================
    
    PRINT '';
    PRINT '--------------------------------------------------------------------------------';
    PRINT '  SECTION 0: DATA AVAILABILITY CHECK';
    PRINT '--------------------------------------------------------------------------------';
    
    SELECT @snapshot_count = COUNT(*),
           @latest_snapshot = MAX(snapshot_dttm),
           @oldest_snapshot = MIN(snapshot_dttm)
    FROM ServerOps.Activity_DMV_Memory
    WHERE server_name = @server_name
      AND snapshot_dttm >= @window_start;
    
    IF @snapshot_count = 0
    BEGIN
        PRINT '';
        PRINT '  !! WARNING: No DMV data found for ' + @server_name + ' in the last ' 
              + CAST(@lookback_minutes AS VARCHAR(10)) + ' minutes.';
        PRINT '';
        PRINT '  Possible causes:';
        PRINT '    - Server is not enrolled for activity monitoring';
        PRINT '    - Collect-DMVMetrics.ps1 is not running';
        PRINT '    - Server name mismatch';
        PRINT '';
        PRINT '  Available servers with recent data:';
        
        SELECT DISTINCT server_name, MAX(snapshot_dttm) AS latest_data
        FROM ServerOps.Activity_DMV_Memory
        WHERE snapshot_dttm >= DATEADD(HOUR, -1, GETDATE())
        GROUP BY server_name;
        
        RETURN;
    END
    
    PRINT '';
    PRINT '  Data available: ' + CAST(@snapshot_count AS VARCHAR(10)) + ' snapshots found';
    PRINT '  Time range:     ' + CONVERT(VARCHAR(20), @oldest_snapshot, 120) + ' to ' + CONVERT(VARCHAR(20), @latest_snapshot, 120);
    PRINT '  Collection appears to be working normally.';
    
    -- ========================================================================
    -- SECTION 1: AVAILABILITY GROUP HEALTH
    -- ========================================================================
    
    PRINT '';
    PRINT '--------------------------------------------------------------------------------';
    PRINT '  SECTION 1: AVAILABILITY GROUP HEALTH';
    PRINT '--------------------------------------------------------------------------------';
    
    IF @detail_level >= 1
    BEGIN
        PRINT '';
        IF @detail_level = 2
        BEGIN
            PRINT '  WHAT THIS MEANS:';
            PRINT '  Your database has a backup copy on another server that stays in sync.';
            PRINT '  If the main server fails, the backup can take over. This check makes';
            PRINT '  sure everything is working correctly between the two servers.';
        END
        ELSE
        BEGIN
            PRINT '  WHAT THIS CHECKS:';
            PRINT '  AG health, sync status, and expected primary role.';
        END
        PRINT '';
    END
    
    -- Get AG info and secondary server
    BEGIN TRY
        SELECT TOP 1
            @ag_name = ag.name,
            @actual_role = ars.role_desc,
            @ag_health = ags.synchronization_health_desc
        FROM sys.dm_hadr_availability_replica_states ars
        INNER JOIN sys.availability_groups ag ON ars.group_id = ag.group_id
        INNER JOIN sys.dm_hadr_availability_group_states ags ON ag.group_id = ags.group_id
        WHERE ars.is_local = 1;
        
        -- Find secondary server
        SELECT TOP 1 @secondary_server = ar.replica_server_name
        FROM sys.dm_hadr_availability_replica_states ars
        INNER JOIN sys.availability_replicas ar ON ars.replica_id = ar.replica_id
        WHERE ars.role_desc = 'SECONDARY';
        
        IF @actual_role = 'PRIMARY' AND @ag_health = 'HEALTHY'
        BEGIN
            SET @ag_is_healthy = 1;
            PRINT '  RESULT: AG is HEALTHY';
            PRINT '    AG Name:    ' + ISNULL(@ag_name, 'Unknown');
            PRINT '    Role:       ' + @actual_role + ' (expected)';
            PRINT '    Sync State: ' + @ag_health;
            PRINT '    Secondary:  ' + ISNULL(@secondary_server, 'Unknown');
        END
        ELSE
        BEGIN
            PRINT '  RESULT: AG requires attention';
            PRINT '    AG Name:    ' + ISNULL(@ag_name, 'Unknown');
            PRINT '    Role:       ' + ISNULL(@actual_role, 'Unknown');
            PRINT '    Sync State: ' + ISNULL(@ag_health, 'Unknown');
            IF @actual_role <> 'PRIMARY'
                PRINT '    <<<< WARNING: This server is not the PRIMARY!';
        END
    END TRY
    BEGIN CATCH
        PRINT '  RESULT: Unable to query AG status';
        PRINT '    Error: ' + ERROR_MESSAGE();
        SET @secondary_server = 'DM-PROD-REP';  -- Fallback
    END CATCH
    
    -- Default secondary if not found
    IF @secondary_server IS NULL
        SET @secondary_server = 'DM-PROD-REP';
    
    -- ========================================================================
    -- SECTION 2: MEMORY HEALTH ANALYSIS
    -- ========================================================================
    
    PRINT '';
    PRINT '--------------------------------------------------------------------------------';
    PRINT '  SECTION 2: MEMORY HEALTH ANALYSIS';
    PRINT '--------------------------------------------------------------------------------';
    
    IF @detail_level >= 1
    BEGIN
        PRINT '';
        IF @detail_level = 2
        BEGIN
            PRINT '  WHAT THIS MEANS:';
            PRINT '  SQL Server keeps frequently-used data in memory (RAM) so it can access';
            PRINT '  it quickly. When memory fills up, it has to read from the hard drive';
            PRINT '  instead, which is MUCH slower. This section checks if memory is healthy.';
            PRINT '';
            PRINT '  Think of it like a desk vs. a filing cabinet:';
            PRINT '    - Data in memory = files on your desk (instant access)';
            PRINT '    - Data on disk = files in a cabinet across the room (takes time)';
            PRINT '';
            PRINT '  PAGE LIFE EXPECTANCY (PLE):';
            PRINT '    How long data stays on your "desk" before being put away.';
            PRINT '    > 1000 seconds = Plenty of desk space, everything runs fast';
            PRINT '    < 300 seconds  = Desk is overcrowded, constantly shuffling papers';
            PRINT '    < 100 seconds  = Chaos - nothing stays on the desk long enough to use';
        END
        ELSE
        BEGIN
            PRINT '  WHAT THIS CHECKS:';
            PRINT '  PLE (buffer pool page retention), buffer cache hit ratio, memory grants.';
            PRINT '  Thresholds: PLE > 600 OK, 300-600 WARNING, < 300 CRITICAL, < 100 CRISIS';
        END
        PRINT '';
    END
    
    -- Get current memory metrics
    SELECT TOP 1
        @current_ple = ple_seconds,
        @current_cache_hit = buffer_cache_hit_ratio,
        @current_grants_pending = memory_grants_pending
    FROM ServerOps.Activity_DMV_Memory
    WHERE server_name = @server_name
    ORDER BY snapshot_dttm DESC;
    
    -- Get memory metrics for the window
    SELECT 
        @min_ple = MIN(ple_seconds),
        @avg_ple = AVG(CAST(ple_seconds AS DECIMAL(10,2))),
        @max_ple = MAX(ple_seconds),
        @min_cache_hit = MIN(buffer_cache_hit_ratio),
        @max_grants_pending = MAX(memory_grants_pending),
        @ple_crash_count = SUM(CASE WHEN ple_seconds < 300 THEN 1 ELSE 0 END)
    FROM ServerOps.Activity_DMV_Memory
    WHERE server_name = @server_name
      AND snapshot_dttm >= @window_start;
    
    -- Determine PLE trend
    SELECT 
        @first_half_avg = AVG(CASE 
            WHEN snapshot_dttm < DATEADD(MINUTE, -@lookback_minutes/2, GETDATE()) 
            THEN CAST(ple_seconds AS FLOAT) END),
        @second_half_avg = AVG(CASE 
            WHEN snapshot_dttm >= DATEADD(MINUTE, -@lookback_minutes/2, GETDATE()) 
            THEN CAST(ple_seconds AS FLOAT) END)
    FROM ServerOps.Activity_DMV_Memory
    WHERE server_name = @server_name
      AND snapshot_dttm >= @window_start;
    
    SET @ple_trend = CASE 
        WHEN @first_half_avg IS NULL OR @second_half_avg IS NULL THEN 'UNKNOWN'
        WHEN @first_half_avg = 0 THEN 'UNKNOWN'
        WHEN @second_half_avg > @first_half_avg * 1.2 THEN 'IMPROVING'
        WHEN @second_half_avg < @first_half_avg * 0.8 THEN 'DECLINING'
        ELSE 'STABLE'
    END;
    
    -- Determine memory status
    SET @memory_status = CASE
        WHEN @current_ple < 100 OR @min_cache_hit < 80 THEN 'CRITICAL'
        WHEN @current_ple < 300 OR @ple_crash_count > 3 OR @min_cache_hit < 90 THEN 'WARNING'
        WHEN @current_ple < 600 OR @ple_crash_count > 0 THEN 'ELEVATED'
        ELSE 'HEALTHY'
    END;
    
    IF @memory_status IN ('CRITICAL', 'WARNING') SET @issue_count = @issue_count + 1;
    
    -- Display memory results
    PRINT '  CURRENT STATE:';
    PRINT '    PLE:                  ' + CAST(ISNULL(@current_ple, 0) AS VARCHAR(10)) + ' seconds ' +
          CASE 
              WHEN @current_ple < 100 THEN '  <<<< CRISIS - Severe memory pressure!'
              WHEN @current_ple < 300 THEN '  <<<< CRITICAL - Memory pressure detected'
              WHEN @current_ple < 600 THEN '  <<<< WARNING - Below optimal'
              ELSE '  (OK)'
          END;
    PRINT '    Buffer Cache Hit:     ' + CAST(ISNULL(@current_cache_hit, 0) AS VARCHAR(10)) + '%' +
          CASE 
              WHEN @current_cache_hit < 90 THEN '  <<<< LOW - Excessive disk reads'
              WHEN @current_cache_hit < 95 THEN '  <<<< Below optimal'
              ELSE '  (OK)'
          END;
    PRINT '    Memory Grants Pending: ' + CAST(ISNULL(@current_grants_pending, 0) AS VARCHAR(10)) +
          CASE WHEN ISNULL(@current_grants_pending, 0) > 0 THEN '  <<<< Queries waiting for memory!' ELSE '  (OK)' END;
    
    PRINT '';
    PRINT '  ANALYSIS WINDOW (' + CAST(@lookback_minutes AS VARCHAR(10)) + ' minutes):';
    PRINT '    PLE Range:            ' + CAST(ISNULL(@min_ple, 0) AS VARCHAR(10)) + ' to ' + CAST(ISNULL(@max_ple, 0) AS VARCHAR(10)) + ' seconds';
    PRINT '    PLE Average:          ' + CAST(ISNULL(@avg_ple, 0) AS VARCHAR(10)) + ' seconds';
    PRINT '    PLE Trend:            ' + @ple_trend +
          CASE 
              WHEN @ple_trend = 'DECLINING' THEN '  <<<< Getting worse'
              WHEN @ple_trend = 'IMPROVING' THEN '  (recovering)'
              ELSE ''
          END;
    PRINT '    Critical Events:      ' + CAST(ISNULL(@ple_crash_count, 0) AS VARCHAR(10)) + ' snapshots with PLE < 300' +
          CASE WHEN ISNULL(@ple_crash_count, 0) > 0 THEN '  <<<< Memory pressure occurred' ELSE '' END;
    
    PRINT '';
    PRINT '  ASSESSMENT: ' + @memory_status;
    
    IF @detail_level = 2 AND @memory_status IN ('CRITICAL', 'WARNING')
    BEGIN
        PRINT '';
        PRINT '  WHAT THIS MEANS FOR YOU:';
        PRINT '  The server is running low on memory. This causes queries to run slower';
        PRINT '  because data has to be fetched from the hard drive instead of RAM.';
        PRINT '  Users will experience delays, especially during busy periods.';
    END
    
    -- Memory timeline
    PRINT '';
    PRINT '  MEMORY TIMELINE (most recent snapshots):';
    
    SELECT TOP 12
        snapshot_dttm AS [Snapshot Time],
        ple_seconds AS [PLE (sec)],
        CASE 
            WHEN ple_seconds < 100 THEN 'CRISIS'
            WHEN ple_seconds < 300 THEN 'CRITICAL'
            WHEN ple_seconds < 600 THEN 'WARNING'
            ELSE 'OK'
        END AS [Status],
        buffer_cache_hit_ratio AS [Cache Hit %],
        memory_grants_pending AS [Grants Pending]
    FROM ServerOps.Activity_DMV_Memory
    WHERE server_name = @server_name
      AND snapshot_dttm >= @window_start
    ORDER BY snapshot_dttm DESC;
    
    -- ========================================================================
    -- SECTION 3: WAIT CATEGORY ANALYSIS
    -- ========================================================================
    
    PRINT '';
    PRINT '--------------------------------------------------------------------------------';
    PRINT '  SECTION 3: WAIT CATEGORY ANALYSIS';
    PRINT '--------------------------------------------------------------------------------';
    
    IF @detail_level >= 1
    BEGIN
        PRINT '';
        IF @detail_level = 2
        BEGIN
            PRINT '  WHAT THIS MEANS:';
            PRINT '  When SQL Server runs a query, it often has to wait for things:';
            PRINT '    - Waiting for data from the hard drive (disk waits)';
            PRINT '    - Waiting for another query to release a lock (lock waits)';
            PRINT '    - Waiting for parallel workers to coordinate (parallelism waits)';
            PRINT '    - Waiting for the backup server to confirm changes (sync waits)';
            PRINT '';
            PRINT '  This section shows WHERE the server is spending its time waiting,';
            PRINT '  which tells us WHY things are slow.';
        END
        ELSE
        BEGIN
            PRINT '  WHAT THIS CHECKS:';
            PRINT '  Aggregated wait statistics grouped by category to identify bottlenecks.';
        END
        PRINT '';
    END
    
    -- Calculate wait category totals
    ;WITH WaitDeltas AS (
        SELECT 
            wait_type,
            wait_time_ms - LAG(wait_time_ms) OVER (PARTITION BY wait_type ORDER BY snapshot_dttm) AS delta_ms
        FROM ServerOps.Activity_DMV_WaitStats
        WHERE server_name = @server_name
          AND snapshot_dttm >= DATEADD(MINUTE, -5, @window_start)  -- Extra buffer for delta calc
          AND snapshot_dttm <= @window_end
    )
    SELECT 
        @pageiolatch_seconds = SUM(CASE WHEN wait_type LIKE 'PAGEIOLATCH%' THEN delta_ms ELSE 0 END) / 1000.0,
        @lck_seconds = SUM(CASE WHEN wait_type LIKE 'LCK_M_%' THEN delta_ms ELSE 0 END) / 1000.0,
        @cxpacket_seconds = SUM(CASE WHEN wait_type = 'CXPACKET' THEN delta_ms ELSE 0 END) / 1000.0,
        @cxconsumer_seconds = SUM(CASE WHEN wait_type = 'CXCONSUMER' THEN delta_ms ELSE 0 END) / 1000.0,
        @hadr_sync_seconds = SUM(CASE WHEN wait_type = 'HADR_SYNC_COMMIT' THEN delta_ms ELSE 0 END) / 1000.0
    FROM WaitDeltas
    WHERE delta_ms > 0;
    
    SET @total_problem_waits = ISNULL(@pageiolatch_seconds, 0) + ISNULL(@cxpacket_seconds, 0) + 
                               ISNULL(@cxconsumer_seconds, 0) + ISNULL(@lck_seconds, 0);
    
    -- Determine wait status
    SET @wait_status = CASE
        WHEN ISNULL(@pageiolatch_seconds, 0) > 10000 OR ISNULL(@hadr_sync_seconds, 0) > 5000 THEN 'CRITICAL'
        WHEN ISNULL(@pageiolatch_seconds, 0) > 1000 OR ISNULL(@hadr_sync_seconds, 0) > 1000 THEN 'WARNING'
        WHEN ISNULL(@pageiolatch_seconds, 0) > 300 THEN 'ELEVATED'
        ELSE 'HEALTHY'
    END;
    
    IF @wait_status IN ('CRITICAL', 'WARNING') SET @issue_count = @issue_count + 1;
    
    PRINT '  WAIT CATEGORIES (total seconds during analysis window):';
    PRINT '';
    
    -- Disk I/O Waits
    PRINT '    DISK I/O WAITS:        ' + CAST(ISNULL(@pageiolatch_seconds, 0) AS VARCHAR(20)) + ' seconds' +
          CASE 
              WHEN @pageiolatch_seconds > 10000 THEN '  <<<< SEVERE'
              WHEN @pageiolatch_seconds > 1000 THEN '  <<<< HIGH'
              ELSE ''
          END;
    IF @detail_level = 2 AND ISNULL(@pageiolatch_seconds, 0) > 1000
        PRINT '      ^ Queries waiting to read data from disk. Usually means memory pressure.';
    
    -- Parallelism Waits
    DECLARE @parallel_total DECIMAL(10,2) = ISNULL(@cxpacket_seconds, 0) + ISNULL(@cxconsumer_seconds, 0);
    PRINT '    PARALLELISM WAITS:     ' + CAST(@parallel_total AS VARCHAR(20)) + ' seconds' +
          CASE 
              WHEN @parallel_total > 50000 THEN '  <<<< SEVERE'
              WHEN @parallel_total > 10000 THEN '  <<<< HIGH'
              ELSE ''
          END;
    IF @detail_level = 2 AND @parallel_total > 10000
        PRINT '      ^ Large queries running with multiple workers. Batch jobs likely running.';
    
    -- Lock Waits
    PRINT '    LOCK WAITS:            ' + CAST(ISNULL(@lck_seconds, 0) AS VARCHAR(20)) + ' seconds' +
          CASE 
              WHEN @lck_seconds > 1000 THEN '  <<<< HIGH'
              WHEN @lck_seconds > 300 THEN '  <<<< ELEVATED'
              ELSE ''
          END;
    IF @detail_level = 2 AND ISNULL(@lck_seconds, 0) > 300
        PRINT '      ^ Queries waiting for other queries to release locks. Blocking occurring.';
    
    -- HADR Sync Waits
    PRINT '    AG SYNC WAITS:         ' + CAST(ISNULL(@hadr_sync_seconds, 0) AS VARCHAR(20)) + ' seconds' +
          CASE 
              WHEN @hadr_sync_seconds > 5000 THEN '  <<<< SEVERE'
              WHEN @hadr_sync_seconds > 1000 THEN '  <<<< HIGH'
              ELSE ''
          END;
    IF @detail_level = 2 AND ISNULL(@hadr_sync_seconds, 0) > 1000
        PRINT '      ^ Waiting for backup server to confirm. Heavy activity on secondary?';
    
    PRINT '';
    PRINT '  ASSESSMENT: ' + @wait_status;
    
    IF @total_problem_waits > 0
    BEGIN
        PRINT '';
        PRINT '  LIKELY ROOT CAUSE:';
        IF @pageiolatch_seconds > @parallel_total AND @pageiolatch_seconds > @hadr_sync_seconds
            PRINT '    Memory pressure forcing disk reads (PAGEIOLATCH dominant)';
        ELSE IF @parallel_total > @pageiolatch_seconds AND @parallel_total > @hadr_sync_seconds
            PRINT '    Heavy batch processing with parallel queries (CXPACKET/CXCONSUMER dominant)';
        ELSE IF @hadr_sync_seconds > @pageiolatch_seconds AND @hadr_sync_seconds > @parallel_total
            PRINT '    Secondary server slow to acknowledge (HADR_SYNC_COMMIT dominant)';
    END
    
    -- ========================================================================
    -- SECTION 4: HADR HEALTH & SECONDARY CORRELATION
    -- ========================================================================
    
    PRINT '';
    PRINT '--------------------------------------------------------------------------------';
    PRINT '  SECTION 4: HADR HEALTH & SECONDARY CORRELATION';
    PRINT '--------------------------------------------------------------------------------';
    
    IF @detail_level >= 1
    BEGIN
        PRINT '';
        IF @detail_level = 2
        BEGIN
            PRINT '  WHAT THIS MEANS:';
            PRINT '  When you save changes to the database, they must be confirmed by the';
            PRINT '  backup server (' + @secondary_server + ') before the save is complete.';
            PRINT '  If the backup server is busy (running reports, syncing data), it takes';
            PRINT '  longer to confirm, which slows down EVERYTHING on the main server.';
            PRINT '';
            PRINT '  This section checks if the backup server is causing delays.';
        END
        ELSE
        BEGIN
            PRINT '  WHAT THIS CHECKS:';
            PRINT '  HADR_SYNC_COMMIT wait correlation with LRQ activity on secondary replica.';
        END
        PRINT '';
    END
    
    -- Get HADR sync metrics
    ;WITH HADRDeltas AS (
        SELECT 
            snapshot_dttm,
            wait_time_ms - LAG(wait_time_ms) OVER (ORDER BY snapshot_dttm) AS delta_ms
        FROM ServerOps.Activity_DMV_WaitStats
        WHERE server_name = @server_name
          AND wait_type = 'HADR_SYNC_COMMIT'
          AND snapshot_dttm >= @window_start
    )
    SELECT 
        @max_hadr_sync = MAX(delta_ms) / 1000.0,
        @avg_hadr_sync = AVG(delta_ms) / 1000.0,
        @hadr_spike_count = SUM(CASE WHEN delta_ms > 5000000 THEN 1 ELSE 0 END)  -- > 5000 seconds
    FROM HADRDeltas
    WHERE delta_ms > 0;
    
    SET @hadr_status = CASE
        WHEN ISNULL(@max_hadr_sync, 0) > 10000 THEN 'CRITICAL'
        WHEN ISNULL(@max_hadr_sync, 0) > 1000 THEN 'WARNING'
        WHEN ISNULL(@max_hadr_sync, 0) > 300 THEN 'ELEVATED'
        ELSE 'HEALTHY'
    END;
    
    IF @hadr_status IN ('CRITICAL', 'WARNING') SET @issue_count = @issue_count + 1;
    
    PRINT '  HADR SYNC COMMIT METRICS:';
    PRINT '    Max Wait (single snapshot):  ' + CAST(ISNULL(@max_hadr_sync, 0) AS VARCHAR(20)) + ' seconds' +
          CASE WHEN @max_hadr_sync > 5000 THEN '  <<<< SEVERE SPIKE' ELSE '' END;
    PRINT '    Avg Wait (per snapshot):     ' + CAST(ISNULL(@avg_hadr_sync, 0) AS VARCHAR(20)) + ' seconds';
    PRINT '    Spike Count (> 5000 sec):    ' + CAST(ISNULL(@hadr_spike_count, 0) AS VARCHAR(10));
    PRINT '';
    PRINT '  ASSESSMENT: ' + @hadr_status;
    
    -- Check for LRQs on secondary during this window
    IF EXISTS (SELECT 1 FROM ServerOps.Activity_XE_LRQ WHERE server_name = @secondary_server AND event_timestamp >= @window_start)
    BEGIN
        PRINT '';
        PRINT '  LONG-RUNNING QUERIES ON SECONDARY (' + @secondary_server + '):';
        PRINT '';
        
        SELECT 
            event_timestamp AS [Time],
            duration_ms / 1000 AS [Duration (sec)],
            database_name AS [Database],
            username AS [User],
            LEFT(sql_text, 200) AS [Query (truncated)]
        FROM ServerOps.Activity_XE_LRQ
        WHERE server_name = @secondary_server
          AND event_timestamp >= @window_start
          AND duration_ms > 30000  -- > 30 seconds
        ORDER BY event_timestamp DESC;
        
        -- Summarize by source
        PRINT '';
        PRINT '  SECONDARY LRQ SUMMARY BY SOURCE:';
        
        SELECT 
            CASE 
                WHEN username LIKE '%sqlmon%' THEN 'Redgate Monitoring'
                WHEN sql_text LIKE '%fn_xe_file_target_read_file%' THEN 'xFACts XE Collection'
                WHEN sql_text LIKE '%upsrt_dttm%' THEN 'Azure Data Sync'
                WHEN database_name = 'BIDATA' THEN 'BIDATA Builds'
                WHEN database_name = 'PROCESSES' THEN 'PROCESSES Jobs'
                ELSE 'Other (' + ISNULL(database_name, 'unknown') + ')'
            END AS [Source],
            COUNT(*) AS [Query Count],
            SUM(duration_ms) / 1000 AS [Total Seconds],
            AVG(duration_ms) / 1000 AS [Avg Seconds]
        FROM ServerOps.Activity_XE_LRQ
        WHERE server_name = @secondary_server
          AND event_timestamp >= @window_start
        GROUP BY 
            CASE 
                WHEN username LIKE '%sqlmon%' THEN 'Redgate Monitoring'
                WHEN sql_text LIKE '%fn_xe_file_target_read_file%' THEN 'xFACts XE Collection'
                WHEN sql_text LIKE '%upsrt_dttm%' THEN 'Azure Data Sync'
                WHEN database_name = 'BIDATA' THEN 'BIDATA Builds'
                WHEN database_name = 'PROCESSES' THEN 'PROCESSES Jobs'
                ELSE 'Other (' + ISNULL(database_name, 'unknown') + ')'
            END
        ORDER BY [Total Seconds] DESC;
    END
    ELSE
    BEGIN
        PRINT '';
        PRINT '  No long-running queries found on ' + @secondary_server + ' during this window.';
    END
    
    -- ========================================================================
    -- SECTION 5: MONITORING OVERHEAD ANALYSIS
    -- ========================================================================
    
    PRINT '';
    PRINT '--------------------------------------------------------------------------------';
    PRINT '  SECTION 5: MONITORING OVERHEAD ANALYSIS';
    PRINT '--------------------------------------------------------------------------------';
    
    IF @detail_level >= 1
    BEGIN
        PRINT '';
        IF @detail_level = 2
        BEGIN
            PRINT '  WHAT THIS MEANS:';
            PRINT '  Monitoring tools (like Redgate and xFACts) run queries to check server';
            PRINT '  health. These queries themselves consume resources. This section measures';
            PRINT '  how much overhead each monitoring tool adds so we know if monitoring';
            PRINT '  itself is contributing to the problem.';
        END
        ELSE
        BEGIN
            PRINT '  WHAT THIS CHECKS:';
            PRINT '  Resource consumption by monitoring tools (Redgate, xFACts, Azure sync).';
        END
        PRINT '';
    END
    
    -- Redgate on secondary
    SELECT 
        @redgate_lrq_count = COUNT(*),
        @redgate_total_seconds = ISNULL(SUM(duration_ms), 0) / 1000.0
    FROM ServerOps.Activity_XE_LRQ
    WHERE server_name = @secondary_server
      AND event_timestamp >= @window_start
      AND (username LIKE '%sqlmon%' OR sql_text LIKE '%RedGate%');
    
    -- xFACts overhead (from wait stats)
    SELECT @xfacts_wait_seconds = ISNULL(SUM(
        CASE WHEN w2.wait_time_ms > w1.wait_time_ms 
             THEN w2.wait_time_ms - w1.wait_time_ms 
             ELSE 0 END), 0) / 1000.0
    FROM ServerOps.Activity_DMV_WaitStats w1
    JOIN ServerOps.Activity_DMV_WaitStats w2 
        ON w1.server_name = w2.server_name 
        AND w1.wait_type = w2.wait_type
        AND w2.snapshot_dttm = (
            SELECT MIN(snapshot_dttm) 
            FROM ServerOps.Activity_DMV_WaitStats 
            WHERE server_name = w1.server_name 
              AND wait_type = w1.wait_type 
              AND snapshot_dttm > w1.snapshot_dttm
        )
    WHERE w1.server_name = @server_name
      AND w1.wait_type = 'XE_FILE_TARGET_TVF'
      AND w1.snapshot_dttm >= @window_start;
    
    -- Azure sync on secondary
    SELECT 
        @azure_sync_count = COUNT(*),
        @azure_sync_seconds = ISNULL(SUM(duration_ms), 0) / 1000.0
    FROM ServerOps.Activity_XE_LRQ
    WHERE server_name = @secondary_server
      AND event_timestamp >= @window_start
      AND sql_text LIKE '%upsrt_dttm%';
    
    PRINT '  MONITORING TOOL OVERHEAD:';
    PRINT '';
    PRINT '    REDGATE SQL MONITOR (on ' + @secondary_server + '):';
    PRINT '      Long queries captured:  ' + CAST(ISNULL(@redgate_lrq_count, 0) AS VARCHAR(10));
    PRINT '      Total execution time:   ' + CAST(ISNULL(@redgate_total_seconds, 0) AS VARCHAR(20)) + ' seconds';
    IF @redgate_total_seconds > 1000
        PRINT '      <<<< Significant overhead from Redgate monitoring';
    
    PRINT '';
    PRINT '    xFACts ACTIVITY MONITORING:';
    PRINT '      XE file read waits:     ' + CAST(ISNULL(@xfacts_wait_seconds, 0) AS VARCHAR(20)) + ' seconds';
    IF @total_problem_waits > 0
        PRINT '      % of problem waits:     ' + CAST(CAST(ISNULL(@xfacts_wait_seconds, 0) / @total_problem_waits * 100 AS DECIMAL(5,2)) AS VARCHAR(10)) + '%';
    PRINT '      Status:                 ' + CASE WHEN @xfacts_wait_seconds < 100 THEN 'Minimal impact' ELSE 'Review collection frequency' END;
    
    PRINT '';
    PRINT '    AZURE DATA SYNC (on ' + @secondary_server + '):';
    PRINT '      Sync queries captured:  ' + CAST(ISNULL(@azure_sync_count, 0) AS VARCHAR(10));
    PRINT '      Total execution time:   ' + CAST(ISNULL(@azure_sync_seconds, 0) AS VARCHAR(20)) + ' seconds';
    IF @azure_sync_seconds > 500
        PRINT '      <<<< Consider optimizing incremental sync queries';
    
    PRINT '';
    PRINT '  xFACts SELF-CHECK:';
    IF @xfacts_wait_seconds < 100 AND @total_problem_waits > 10000
    BEGIN
        PRINT '    xFACts contribution:  < 1% of total problem waits';
        PRINT '    Verdict:              xFACts is OBSERVING, not CAUSING issues';
    END
    ELSE IF @xfacts_wait_seconds > @total_problem_waits * 0.05
    BEGIN
        PRINT '    xFACts contribution:  > 5% of total problem waits';
        PRINT '    Verdict:              Review xFACts collection frequency';
    END
    ELSE
    BEGIN
        PRINT '    Verdict:              xFACts overhead is within acceptable range';
    END
    
    -- ========================================================================
    -- SECTION 6: CONNECTION & ZOMBIE ANALYSIS
    -- ========================================================================
    
    PRINT '';
    PRINT '--------------------------------------------------------------------------------';
    PRINT '  SECTION 6: CONNECTION & ZOMBIE ANALYSIS';
    PRINT '--------------------------------------------------------------------------------';
    
    IF @detail_level >= 1
    BEGIN
        PRINT '';
        IF @detail_level = 2
        BEGIN
            PRINT '  WHAT THIS MEANS:';
            PRINT '  Applications connect to the database to run queries. Sometimes they';
            PRINT '  forget to disconnect when finished. These abandoned connections are';
            PRINT '  called "zombies" - they sit there doing nothing but taking up space.';
            PRINT '';
            PRINT '  Too many zombies = fewer connections available for real users.';
        END
        ELSE
        BEGIN
            PRINT '  WHAT THIS CHECKS:';
            PRINT '  Total connections, zombie (abandoned) connections, oldest zombie age.';
        END
        PRINT '';
    END
    
    -- Get current connection metrics
    SELECT TOP 1
        @current_connections = total_sessions,
        @current_zombies = zombie_count,
        @oldest_zombie_min = oldest_zombie_idle_min,
        @jdbc_zombies = jdbc_zombie
    FROM ServerOps.Activity_DMV_ConnectionHealth
    WHERE server_name = @server_name
    ORDER BY snapshot_dttm DESC;
    
    -- Get max zombies in window
    SELECT @max_zombies = MAX(zombie_count)
    FROM ServerOps.Activity_DMV_ConnectionHealth
    WHERE server_name = @server_name
      AND snapshot_dttm >= @window_start;
    
    SET @zombie_status = CASE
        WHEN ISNULL(@current_zombies, 0) > 100 THEN 'CRITICAL'
        WHEN ISNULL(@current_zombies, 0) > 50 OR ISNULL(@oldest_zombie_min, 0) > 1440 THEN 'WARNING'
        WHEN ISNULL(@current_zombies, 0) > 20 THEN 'ELEVATED'
        ELSE 'HEALTHY'
    END;
    
    IF @zombie_status IN ('CRITICAL', 'WARNING') SET @issue_count = @issue_count + 1;
    
    PRINT '  CURRENT STATE:';
    PRINT '    Total Connections:     ' + CAST(ISNULL(@current_connections, 0) AS VARCHAR(10));
    PRINT '    Zombie Connections:    ' + CAST(ISNULL(@current_zombies, 0) AS VARCHAR(10)) +
          CASE WHEN @current_zombies > 50 THEN '  <<<< HIGH' ELSE '' END;
    PRINT '    JDBC Zombies:          ' + CAST(ISNULL(@jdbc_zombies, 0) AS VARCHAR(10)) +
          CASE WHEN @jdbc_zombies > 20 THEN '  <<<< Java apps leaking connections' ELSE '' END;
    PRINT '    Oldest Zombie:         ' + CAST(ISNULL(@oldest_zombie_min, 0) AS VARCHAR(10)) + ' minutes' +
          CASE WHEN @oldest_zombie_min > 1440 THEN '  <<<< Over 24 hours old!' ELSE '' END;
    PRINT '    Max Zombies (window):  ' + CAST(ISNULL(@max_zombies, 0) AS VARCHAR(10));
    PRINT '';
    PRINT '  ASSESSMENT: ' + @zombie_status;
    
    -- ========================================================================
    -- SECTION 7: MANUAL INVESTIGATION QUERIES
    -- ========================================================================
    
    PRINT '';
    PRINT '--------------------------------------------------------------------------------';
    PRINT '  SECTION 7: MANUAL INVESTIGATION QUERIES';
    PRINT '--------------------------------------------------------------------------------';
    PRINT '';
    PRINT '  Copy/paste these queries to dig deeper on DM-PROD-DB:';
    PRINT '';
    PRINT '  --- ZOMBIE SOURCE IDENTIFICATION ---';
    PRINT '  SELECT program_name, host_name, COUNT(*) AS zombie_count,';
    PRINT '         MAX(DATEDIFF(MINUTE, last_request_end_time, GETDATE())) AS max_idle_min';
    PRINT '  FROM sys.dm_exec_sessions';
    PRINT '  WHERE session_id > 50 AND status = ''sleeping''';
    PRINT '    AND open_transaction_count = 0';
    PRINT '    AND DATEDIFF(MINUTE, last_request_end_time, GETDATE()) > 60';
    PRINT '  GROUP BY program_name, host_name ORDER BY zombie_count DESC;';
    PRINT '';
    PRINT '  --- CURRENT BLOCKING CHAIN ---';
    PRINT '  SELECT blocking_session_id, session_id, wait_type, wait_time/1000 AS wait_sec,';
    PRINT '         DB_NAME(database_id) AS db_name';
    PRINT '  FROM sys.dm_exec_requests WHERE blocking_session_id > 0;';
    PRINT '';
    PRINT '  --- TOP MEMORY CONSUMERS ---';
    PRINT '  SELECT TOP 10 session_id, login_name, program_name,';
    PRINT '         memory_usage * 8 AS memory_kb, status';
    PRINT '  FROM sys.dm_exec_sessions WHERE session_id > 50';
    PRINT '  ORDER BY memory_usage DESC;';
    
    -- ========================================================================
    -- SECTION 8: SUMMARY & RECOMMENDATIONS
    -- ========================================================================
    
    IF @include_recommendations = 1
    BEGIN
        PRINT '';
        PRINT '================================================================================';
        PRINT '  SUMMARY & RECOMMENDATIONS';
        PRINT '================================================================================';
        
        -- Determine overall status
        SET @overall_status = CASE
            WHEN @memory_status = 'CRITICAL' OR @wait_status = 'CRITICAL' OR @hadr_status = 'CRITICAL' THEN 'CRITICAL'
            WHEN @memory_status = 'WARNING' OR @wait_status = 'WARNING' OR @hadr_status = 'WARNING' OR @zombie_status = 'WARNING' THEN 'WARNING'
            WHEN @memory_status = 'ELEVATED' OR @wait_status = 'ELEVATED' OR @zombie_status = 'ELEVATED' THEN 'ELEVATED'
            ELSE 'HEALTHY'
        END;
        
        PRINT '';
        PRINT '  OVERALL SERVER HEALTH: ' + @overall_status;
        PRINT '  Issues Detected: ' + CAST(@issue_count AS VARCHAR(10));
        PRINT '';
        PRINT '  COMPONENT STATUS:';
        PRINT '    Memory Health:     ' + @memory_status;
        PRINT '    Wait Analysis:     ' + @wait_status;
        PRINT '    HADR Health:       ' + @hadr_status;
        PRINT '    Connection Health: ' + @zombie_status;
        PRINT '    AG Status:         ' + CASE WHEN @ag_is_healthy = 1 THEN 'HEALTHY' ELSE 'CHECK REQUIRED' END;
        
        IF @overall_status IN ('CRITICAL', 'WARNING')
        BEGIN
            PRINT '';
            PRINT '  ----------------------------------------------------------------------------';
            PRINT '  LIKELY ROOT CAUSES:';
            PRINT '  ----------------------------------------------------------------------------';
            
            IF @memory_status IN ('CRITICAL', 'WARNING') AND @pageiolatch_seconds > 1000
            BEGIN
                PRINT '';
                PRINT '  1. MEMORY PRESSURE ON PRIMARY';
                PRINT '     - PLE crashed ' + CAST(@ple_crash_count AS VARCHAR(10)) + ' times below 300 seconds';
                PRINT '     - PAGEIOLATCH waits: ' + CAST(@pageiolatch_seconds AS VARCHAR(20)) + ' seconds';
                PRINT '     - Root cause: Insufficient RAM for workload';
                PRINT '     - Solution: RAM upgrade (scheduled)';
            END
            
            IF @hadr_status IN ('CRITICAL', 'WARNING')
            BEGIN
                PRINT '';
                PRINT '  2. SECONDARY SERVER CONTENTION';
                PRINT '     - HADR_SYNC_COMMIT peak: ' + CAST(@max_hadr_sync AS VARCHAR(20)) + ' seconds';
                PRINT '     - Transactions waiting for ' + @secondary_server + ' to acknowledge';
                IF @redgate_total_seconds > 500
                    PRINT '     - Contributing factor: Redgate monitoring (' + CAST(@redgate_total_seconds AS VARCHAR(20)) + ' sec)';
                PRINT '     - Solution: Review secondary workload, consider async replica for reporting';
            END
            
            IF @parallel_total > 50000
            BEGIN
                PRINT '';
                PRINT '  3. HEAVY BATCH PROCESSING';
                PRINT '     - Parallelism waits: ' + CAST(@parallel_total AS VARCHAR(20)) + ' seconds';
                PRINT '     - Large parallel queries consuming resources';
                PRINT '     - This is normal during batch windows but impacts other queries';
            END
            
            PRINT '';
            PRINT '  ----------------------------------------------------------------------------';
            PRINT '  RECOMMENDED ACTIONS:';
            PRINT '  ----------------------------------------------------------------------------';
            
            IF @memory_status IN ('CRITICAL', 'WARNING')
            BEGIN
                PRINT '';
                PRINT '  [MEMORY]';
                PRINT '    - RAM upgrade is the primary solution';
                PRINT '    - Monitor PLE trend - if IMPROVING, batch jobs are completing';
                PRINT '    - Check Section 5 for currently running processes';
            END
            
            IF @hadr_status IN ('CRITICAL', 'WARNING')
            BEGIN
                PRINT '';
                PRINT '  [HADR]';
                PRINT '    - Review workload on ' + @secondary_server;
                PRINT '    - Consider scheduling BIDATA builds outside peak hours';
                PRINT '    - Evaluate Redgate monitoring frequency';
                PRINT '    - Long-term: Async replica for reporting workload';
            END
            
            IF @zombie_status IN ('CRITICAL', 'WARNING')
            BEGIN
                PRINT '';
                PRINT '  [ZOMBIES]';
                PRINT '    - Run zombie source query to identify culprit application';
                PRINT '    - Coordinate with app team on connection pool settings';
            END
        END
        ELSE
        BEGIN
            PRINT '';
            PRINT '  No critical issues detected. Server health is acceptable.';
        END
        
        PRINT '';
        PRINT '  ----------------------------------------------------------------------------';
        PRINT '  WHAT TO TELL USERS:';
        PRINT '  ----------------------------------------------------------------------------';
        
        IF @overall_status = 'CRITICAL'
        BEGIN
            PRINT '';
            PRINT '  "The database server is experiencing high load due to batch processing';
            PRINT '   and memory constraints. This is causing slower response times. We have';
            PRINT '   a RAM upgrade scheduled that will significantly improve performance.';
            PRINT '   In the meantime, expect some delays during peak processing periods."';
        END
        ELSE IF @overall_status = 'WARNING'
        BEGIN
            PRINT '';
            PRINT '  "The database server is under moderate load. You may notice some';
            PRINT '   slowness during busy periods. We are monitoring the situation and';
            PRINT '   have infrastructure improvements scheduled."';
        END
        ELSE
        BEGIN
            PRINT '';
            PRINT '  "Database server health looks good. If you are experiencing slowness,';
            PRINT '   please provide specific details (time, operation, error messages)';
            PRINT '   so we can investigate further."';
        END
    END
    
    PRINT '';
    PRINT '================================================================================';
    PRINT '  END OF DIAGNOSTIC REPORT';
    PRINT '  Generated: ' + CONVERT(VARCHAR(20), GETDATE(), 120);
    PRINT '================================================================================';
    
END

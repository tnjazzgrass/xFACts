# ============================================================================
# xFACts Control Center - DM Operations API
# Location: E:\xFACts-ControlCenter\scripts\routes\DmOperations-API.ps1
# 
# API endpoints for DM Operations monitoring data.
# Version: Tracked in dbo.System_Metadata (component: ControlCenter.DmOperations)
# ============================================================================

# Note: Get-RemainingCounts and $DmOpsRemainingCache are defined in xFACts-Helpers.psm1

# ----------------------------------------------------------------------------
# GET /api/dmops/lifetime-totals
# Returns cumulative totals, abort flags, and remaining counts with subtractive math
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Get -Path '/api/dmops/lifetime-totals' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Connect Timeout=5;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        
        $query = @"
            -- Archive lifetime totals
            SELECT 
                ISNULL(SUM(CASE WHEN status = 'Success' THEN consumer_count ELSE 0 END), 0) AS archive_consumers,
                ISNULL(SUM(CASE WHEN status = 'Success' THEN account_count ELSE 0 END), 0) AS archive_accounts,
                ISNULL(SUM(CASE WHEN status = 'Success' THEN total_rows_deleted ELSE 0 END), 0) AS archive_rows,
                COUNT(*) AS archive_batches,
                SUM(CASE WHEN status = 'Failed' THEN 1 ELSE 0 END) AS archive_failed_batches,
                MIN(batch_start_dttm) AS archive_first_batch,
                MAX(batch_start_dttm) AS archive_last_batch
            FROM DmOps.Archive_BatchLog
            WHERE status IN ('Success', 'Failed');

            -- ShellPurge lifetime totals
            SELECT 
                ISNULL(SUM(CASE WHEN status = 'Success' THEN consumer_count ELSE 0 END), 0) AS purge_consumers,
                ISNULL(SUM(CASE WHEN status = 'Success' THEN total_rows_deleted ELSE 0 END), 0) AS purge_rows,
                COUNT(*) AS purge_batches,
                SUM(CASE WHEN status = 'Failed' THEN 1 ELSE 0 END) AS purge_failed_batches,
                MIN(batch_start_dttm) AS purge_first_batch,
                MAX(batch_start_dttm) AS purge_last_batch
            FROM DmOps.ShellPurge_BatchLog
            WHERE status IN ('Success', 'Failed');

            -- Current abort flags
            SELECT setting_name, setting_value 
            FROM dbo.GlobalConfig
            WHERE module_name = 'DmOps' 
              AND setting_name IN ('archive_abort', 'shell_purge_abort')
              AND is_active = 1;
"@
        
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $query
        $cmd.CommandTimeout = 10
        
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        
        $conn.Close()
        
        # Archive totals
        $archRow = $dataset.Tables[0].Rows[0]
        $archive = [PSCustomObject]@{
            Consumers = if ($archRow['archive_consumers'] -is [DBNull]) { 0 } else { [long]$archRow['archive_consumers'] }
            Accounts = if ($archRow['archive_accounts'] -is [DBNull]) { 0 } else { [long]$archRow['archive_accounts'] }
            RowsDeleted = if ($archRow['archive_rows'] -is [DBNull]) { 0 } else { [long]$archRow['archive_rows'] }
            Batches = if ($archRow['archive_batches'] -is [DBNull]) { 0 } else { [int]$archRow['archive_batches'] }
            FailedBatches = if ($archRow['archive_failed_batches'] -is [DBNull]) { 0 } else { [int]$archRow['archive_failed_batches'] }
            FirstBatch = if ($archRow['archive_first_batch'] -is [DBNull]) { $null } else { $archRow['archive_first_batch'].ToString("yyyy-MM-dd HH:mm:ss") }
            LastBatch = if ($archRow['archive_last_batch'] -is [DBNull]) { $null } else { $archRow['archive_last_batch'].ToString("yyyy-MM-dd HH:mm:ss") }
        }
        
        # ShellPurge totals
        $purgeRow = $dataset.Tables[1].Rows[0]
        $shellPurge = [PSCustomObject]@{
            Consumers = if ($purgeRow['purge_consumers'] -is [DBNull]) { 0 } else { [long]$purgeRow['purge_consumers'] }
            RowsDeleted = if ($purgeRow['purge_rows'] -is [DBNull]) { 0 } else { [long]$purgeRow['purge_rows'] }
            Batches = if ($purgeRow['purge_batches'] -is [DBNull]) { 0 } else { [int]$purgeRow['purge_batches'] }
            FailedBatches = if ($purgeRow['purge_failed_batches'] -is [DBNull]) { 0 } else { [int]$purgeRow['purge_failed_batches'] }
            FirstBatch = if ($purgeRow['purge_first_batch'] -is [DBNull]) { $null } else { $purgeRow['purge_first_batch'].ToString("yyyy-MM-dd HH:mm:ss") }
            LastBatch = if ($purgeRow['purge_last_batch'] -is [DBNull]) { $null } else { $purgeRow['purge_last_batch'].ToString("yyyy-MM-dd HH:mm:ss") }
        }
        
        # Abort flags
        $archiveAbort = $false
        $shellPurgeAbort = $false
        foreach ($row in $dataset.Tables[2].Rows) {
            $name = [string]$row['setting_name']
            $val = [string]$row['setting_value']
            if ($name -eq 'archive_abort' -and $val -eq '1') { $archiveAbort = $true }
            if ($name -eq 'shell_purge_abort' -and $val -eq '1') { $shellPurgeAbort = $true }
        }
        
        # Remaining counts (cached, subtractive) — non-blocking
        # If crs5_oltp is unreachable, remaining returns nulls but everything else still works
        $remaining = [PSCustomObject]@{
            ArchiveBaseline = $null
            ShellBaseline = $null
            ExclusionCount = $null
            BaselineDttm = $null
            TargetInstance = $null
            ArchiveSinceBaseline = 0
            ShellSinceBaseline = 0
            Error = $null
        }
        
        try {
            $cache = Get-RemainingCounts
            $remaining.ArchiveBaseline = $cache.ArchiveRemaining
            $remaining.ShellBaseline = $cache.ShellRemaining
            $remaining.ExclusionCount = $cache.ExclusionCount
            $remaining.BaselineDttm = if ($cache.BaselineDttm) { $cache.BaselineDttm.ToString("yyyy-MM-dd HH:mm:ss") } else { $null }
            $remaining.TargetInstance = $cache.TargetInstance
            
            # Subtractive counts: accounts/consumers processed since baseline
            if ($cache.BaselineDttm) {
                $subtractiveConn = New-Object System.Data.SqlClient.SqlConnection($connString)
                $subtractiveConn.Open()
                
                $subtractiveQuery = @"
                    SELECT 
                        ISNULL(SUM(account_count), 0) AS archive_since_baseline
                    FROM DmOps.Archive_BatchLog
                    WHERE status = 'Success'
                      AND batch_start_dttm > @BaselineDttm;
                      
                    SELECT
                        ISNULL(SUM(consumer_count), 0) AS purge_since_baseline
                    FROM DmOps.ShellPurge_BatchLog
                    WHERE status = 'Success'
                      AND batch_start_dttm > @BaselineDttm;
"@
                $subtractiveCmd = $subtractiveConn.CreateCommand()
                $subtractiveCmd.CommandText = $subtractiveQuery
                $subtractiveCmd.CommandTimeout = 10
                $subtractiveCmd.Parameters.AddWithValue("@BaselineDttm", $cache.BaselineDttm) | Out-Null
                
                $subtractiveAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($subtractiveCmd)
                $subtractiveDs = New-Object System.Data.DataSet
                $subtractiveAdapter.Fill($subtractiveDs) | Out-Null
                $subtractiveConn.Close()
                
                $remaining.ArchiveSinceBaseline = [long]$subtractiveDs.Tables[0].Rows[0]['archive_since_baseline']
                $remaining.ShellSinceBaseline = [long]$subtractiveDs.Tables[1].Rows[0]['purge_since_baseline']
            }
        }
        catch {
            $remaining.Error = $_.Exception.Message
            Write-Host "WARNING: Remaining counts failed: $($_.Exception.Message)"
        }
        
        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            Archive = $archive
            ShellPurge = $shellPurge
            ArchiveAborted = $archiveAbort
            ShellPurgeAborted = $shellPurgeAbort
            Remaining = $remaining
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ----------------------------------------------------------------------------
# GET /api/dmops/today
# Returns today's running totals for both processes
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Get -Path '/api/dmops/today' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Connect Timeout=5;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        
        $query = @"
            -- Archive today
            SELECT
                COUNT(*) AS batches,
                ISNULL(SUM(CASE WHEN status = 'Success' THEN consumer_count ELSE 0 END), 0) AS consumers,
                ISNULL(SUM(CASE WHEN status = 'Success' THEN account_count ELSE 0 END), 0) AS accounts,
                ISNULL(SUM(CASE WHEN status = 'Success' THEN total_rows_deleted ELSE 0 END), 0) AS rows_deleted,
                ISNULL(SUM(CASE WHEN status = 'Success' THEN duration_ms ELSE 0 END), 0) / 1000 AS total_seconds,
                SUM(CASE WHEN status = 'Failed' THEN 1 ELSE 0 END) AS failed_batches,
                SUM(CASE WHEN schedule_mode = 'Full' THEN 1 ELSE 0 END) AS full_batches,
                SUM(CASE WHEN schedule_mode = 'Reduced' THEN 1 ELSE 0 END) AS reduced_batches
            FROM DmOps.Archive_BatchLog
            WHERE status IN ('Success', 'Failed')
              AND CAST(batch_start_dttm AS DATE) = CAST(GETDATE() AS DATE);

            -- ShellPurge today
            SELECT
                COUNT(*) AS batches,
                ISNULL(SUM(CASE WHEN status = 'Success' THEN consumer_count ELSE 0 END), 0) AS consumers,
                ISNULL(SUM(CASE WHEN status = 'Success' THEN total_rows_deleted ELSE 0 END), 0) AS rows_deleted,
                ISNULL(SUM(CASE WHEN status = 'Success' THEN duration_ms ELSE 0 END), 0) / 1000 AS total_seconds,
                SUM(CASE WHEN status = 'Failed' THEN 1 ELSE 0 END) AS failed_batches,
                SUM(CASE WHEN schedule_mode = 'Full' THEN 1 ELSE 0 END) AS full_batches,
                SUM(CASE WHEN schedule_mode = 'Reduced' THEN 1 ELSE 0 END) AS reduced_batches
            FROM DmOps.ShellPurge_BatchLog
            WHERE status IN ('Success', 'Failed')
              AND CAST(batch_start_dttm AS DATE) = CAST(GETDATE() AS DATE);
"@
        
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $query
        $cmd.CommandTimeout = 10
        
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        
        $conn.Close()
        
        $archRow = $dataset.Tables[0].Rows[0]
        $purgeRow = $dataset.Tables[1].Rows[0]
        
        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            Archive = [PSCustomObject]@{
                Batches = if ($archRow['batches'] -is [DBNull]) { 0 } else { [int]$archRow['batches'] }
                Consumers = if ($archRow['consumers'] -is [DBNull]) { 0 } else { [long]$archRow['consumers'] }
                Accounts = if ($archRow['accounts'] -is [DBNull]) { 0 } else { [long]$archRow['accounts'] }
                RowsDeleted = if ($archRow['rows_deleted'] -is [DBNull]) { 0 } else { [long]$archRow['rows_deleted'] }
                TotalSeconds = if ($archRow['total_seconds'] -is [DBNull]) { 0 } else { [long]$archRow['total_seconds'] }
                FailedBatches = if ($archRow['failed_batches'] -is [DBNull]) { 0 } else { [int]$archRow['failed_batches'] }
                FullBatches = if ($archRow['full_batches'] -is [DBNull]) { 0 } else { [int]$archRow['full_batches'] }
                ReducedBatches = if ($archRow['reduced_batches'] -is [DBNull]) { 0 } else { [int]$archRow['reduced_batches'] }
            }
            ShellPurge = [PSCustomObject]@{
                Batches = if ($purgeRow['batches'] -is [DBNull]) { 0 } else { [int]$purgeRow['batches'] }
                Consumers = if ($purgeRow['consumers'] -is [DBNull]) { 0 } else { [long]$purgeRow['consumers'] }
                RowsDeleted = if ($purgeRow['rows_deleted'] -is [DBNull]) { 0 } else { [long]$purgeRow['rows_deleted'] }
                TotalSeconds = if ($purgeRow['total_seconds'] -is [DBNull]) { 0 } else { [long]$purgeRow['total_seconds'] }
                FailedBatches = if ($purgeRow['failed_batches'] -is [DBNull]) { 0 } else { [int]$purgeRow['failed_batches'] }
                FullBatches = if ($purgeRow['full_batches'] -is [DBNull]) { 0 } else { [int]$purgeRow['full_batches'] }
                ReducedBatches = if ($purgeRow['reduced_batches'] -is [DBNull]) { 0 } else { [int]$purgeRow['reduced_batches'] }
            }
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ----------------------------------------------------------------------------
# GET /api/dmops/execution-history
# Returns daily aggregated totals grouped by year/month/day for accordion display
# Both Archive and ShellPurge in a single response
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Get -Path '/api/dmops/execution-history' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Connect Timeout=5;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        
        $query = @"
            -- Archive daily summary
            SELECT
                YEAR(batch_start_dttm) AS run_year,
                MONTH(batch_start_dttm) AS run_month,
                CAST(batch_start_dttm AS DATE) AS run_date,
                DATENAME(dw, batch_start_dttm) AS day_of_week,
                COUNT(*) AS batches,
                SUM(CASE WHEN status = 'Success' THEN consumer_count ELSE 0 END) AS total_consumers,
                SUM(CASE WHEN status = 'Success' THEN account_count ELSE 0 END) AS total_accounts,
                SUM(CASE WHEN status = 'Success' THEN total_rows_deleted ELSE 0 END) AS total_rows,
                SUM(CASE WHEN status = 'Failed' THEN 1 ELSE 0 END) AS failed_batches,
                SUM(CASE WHEN status = 'Success' THEN duration_ms ELSE 0 END) / 1000 AS total_seconds,
                SUM(CASE WHEN schedule_mode = 'Full' THEN 1 ELSE 0 END) AS full_batches,
                SUM(CASE WHEN schedule_mode = 'Reduced' THEN 1 ELSE 0 END) AS reduced_batches
            FROM DmOps.Archive_BatchLog
            WHERE status IN ('Success', 'Failed')
            GROUP BY YEAR(batch_start_dttm), MONTH(batch_start_dttm),
                     CAST(batch_start_dttm AS DATE), DATENAME(dw, batch_start_dttm)
            ORDER BY run_date DESC;

            -- ShellPurge daily summary
            SELECT
                YEAR(batch_start_dttm) AS run_year,
                MONTH(batch_start_dttm) AS run_month,
                CAST(batch_start_dttm AS DATE) AS run_date,
                DATENAME(dw, batch_start_dttm) AS day_of_week,
                COUNT(*) AS batches,
                SUM(CASE WHEN status = 'Success' THEN consumer_count ELSE 0 END) AS total_consumers,
                SUM(CASE WHEN status = 'Success' THEN total_rows_deleted ELSE 0 END) AS total_rows,
                SUM(CASE WHEN status = 'Failed' THEN 1 ELSE 0 END) AS failed_batches,
                SUM(CASE WHEN status = 'Success' THEN duration_ms ELSE 0 END) / 1000 AS total_seconds,
                SUM(CASE WHEN schedule_mode = 'Full' THEN 1 ELSE 0 END) AS full_batches,
                SUM(CASE WHEN schedule_mode = 'Reduced' THEN 1 ELSE 0 END) AS reduced_batches
            FROM DmOps.ShellPurge_BatchLog
            WHERE status IN ('Success', 'Failed')
            GROUP BY YEAR(batch_start_dttm), MONTH(batch_start_dttm),
                     CAST(batch_start_dttm AS DATE), DATENAME(dw, batch_start_dttm)
            ORDER BY run_date DESC;
"@
        
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $query
        $cmd.CommandTimeout = 15
        
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        
        $conn.Close()
        
        # Archive history
        $archiveDays = @()
        foreach ($row in $dataset.Tables[0].Rows) {
            $archiveDays += [PSCustomObject]@{
                run_year = [int]$row['run_year']
                run_month = [int]$row['run_month']
                run_date = $row['run_date'].ToString("yyyy-MM-dd")
                day_of_week = [string]$row['day_of_week']
                batches = [int]$row['batches']
                consumers = [long]$row['total_consumers']
                accounts = [long]$row['total_accounts']
                rows_deleted = [long]$row['total_rows']
                failed_batches = [int]$row['failed_batches']
                total_seconds = if ($row['total_seconds'] -is [DBNull]) { 0 } else { [long]$row['total_seconds'] }
                full_batches = [int]$row['full_batches']
                reduced_batches = [int]$row['reduced_batches']
            }
        }
        
        # ShellPurge history
        $shellPurgeDays = @()
        foreach ($row in $dataset.Tables[1].Rows) {
            $shellPurgeDays += [PSCustomObject]@{
                run_year = [int]$row['run_year']
                run_month = [int]$row['run_month']
                run_date = $row['run_date'].ToString("yyyy-MM-dd")
                day_of_week = [string]$row['day_of_week']
                batches = [int]$row['batches']
                consumers = [long]$row['total_consumers']
                rows_deleted = [long]$row['total_rows']
                failed_batches = [int]$row['failed_batches']
                total_seconds = if ($row['total_seconds'] -is [DBNull]) { 0 } else { [long]$row['total_seconds'] }
                full_batches = [int]$row['full_batches']
                reduced_batches = [int]$row['reduced_batches']
            }
        }
        
        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            Archive = $archiveDays
            ShellPurge = $shellPurgeDays
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ----------------------------------------------------------------------------
# GET /api/dmops/archive/schedule
# Returns the 7x24 archive schedule grid (tinyint: 0=blocked, 1=full, 2=reduced)
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Get -Path '/api/dmops/archive/schedule' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Connect Timeout=5;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        
        $query = @"
            SELECT 
                day_of_week,
                hr00, hr01, hr02, hr03, hr04, hr05, hr06, hr07,
                hr08, hr09, hr10, hr11, hr12, hr13, hr14, hr15,
                hr16, hr17, hr18, hr19, hr20, hr21, hr22, hr23
            FROM DmOps.Archive_Schedule
            ORDER BY day_of_week
"@
        
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $query
        $cmd.CommandTimeout = 10
        
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        
        $conn.Close()
        
        $schedule = @()
        foreach ($row in $dataset.Tables[0].Rows) {
            $daySchedule = [PSCustomObject]@{
                DayOfWeek = [int]$row['day_of_week']
            }
            for ($h = 0; $h -lt 24; $h++) {
                $col = "hr" + $h.ToString("00")
                $daySchedule | Add-Member -NotePropertyName "Hr$($h.ToString('00'))" -NotePropertyValue ([int]$row[$col])
            }
            $schedule += $daySchedule
        }
        
        Write-PodeJsonResponse -Value $schedule
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ----------------------------------------------------------------------------
# GET /api/dmops/shellpurge/schedule
# Returns the 7x24 shell purge schedule grid (tinyint: 0=blocked, 1=full, 2=reduced)
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Get -Path '/api/dmops/shellpurge/schedule' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Connect Timeout=5;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        
        $query = @"
            SELECT 
                day_of_week,
                hr00, hr01, hr02, hr03, hr04, hr05, hr06, hr07,
                hr08, hr09, hr10, hr11, hr12, hr13, hr14, hr15,
                hr16, hr17, hr18, hr19, hr20, hr21, hr22, hr23
            FROM DmOps.ShellPurge_Schedule
            ORDER BY day_of_week
"@
        
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $query
        $cmd.CommandTimeout = 10
        
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        
        $conn.Close()
        
        $schedule = @()
        foreach ($row in $dataset.Tables[0].Rows) {
            $daySchedule = [PSCustomObject]@{
                DayOfWeek = [int]$row['day_of_week']
            }
            for ($h = 0; $h -lt 24; $h++) {
                $col = "hr" + $h.ToString("00")
                $daySchedule | Add-Member -NotePropertyName "Hr$($h.ToString('00'))" -NotePropertyValue ([int]$row[$col])
            }
            $schedule += $daySchedule
        }
        
        Write-PodeJsonResponse -Value $schedule
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ----------------------------------------------------------------------------
# POST /api/dmops/schedule/update-batch
# Updates multiple hour cells in either Archive or ShellPurge schedule
# Body: { Process: 'archive'|'shellpurge', Updates: [{ DayOfWeek, Hour, Value }, ...] }
# Value: 0=blocked, 1=full, 2=reduced
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Post -Path '/api/dmops/schedule/update-batch' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        $body = $WebEvent.Data
        $process = $body.Process
        $updates = $body.Updates
        
        if ($process -ne 'archive' -and $process -ne 'shellpurge') {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Invalid process: $process" }) -StatusCode 400
            return
        }
        
        if (-not $updates -or $updates.Count -eq 0) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "No updates provided" }) -StatusCode 400
            return
        }
        
        $tableName = if ($process -eq 'archive') { 'DmOps.Archive_Schedule' } else { 'DmOps.ShellPurge_Schedule' }
        
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Connect Timeout=5;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        
        # Get current user for audit
        $currentUser = $WebEvent.Auth.User.Name
        if ([string]::IsNullOrEmpty($currentUser)) {
            $currentUser = "Unknown"
        }
        
        $transaction = $conn.BeginTransaction()
        
        try {
            $totalRowsAffected = 0
            
            foreach ($update in $updates) {
                $dayOfWeek = [int]$update.DayOfWeek
                $hour = [int]$update.Hour
                $value = [int]$update.Value
                
                if ($dayOfWeek -lt 1 -or $dayOfWeek -gt 7) {
                    throw "Invalid day of week: $dayOfWeek"
                }
                if ($hour -lt 0 -or $hour -gt 23) {
                    throw "Invalid hour: $hour"
                }
                if ($value -lt 0 -or $value -gt 2) {
                    throw "Invalid value: $value (must be 0, 1, or 2)"
                }
                
                $hourColumn = "hr" + $hour.ToString("00")
                
                $query = @"
                    UPDATE $tableName
                    SET $hourColumn = @Value,
                        modified_dttm = GETDATE(),
                        modified_by = @ModifiedBy
                    WHERE day_of_week = @DayOfWeek
"@
                
                $cmd = $conn.CreateCommand()
                $cmd.Transaction = $transaction
                $cmd.CommandText = $query
                $cmd.CommandTimeout = 10
                $cmd.Parameters.AddWithValue("@Value", $value) | Out-Null
                $cmd.Parameters.AddWithValue("@DayOfWeek", $dayOfWeek) | Out-Null
                $cmd.Parameters.AddWithValue("@ModifiedBy", $currentUser) | Out-Null
                
                $rowsAffected = $cmd.ExecuteNonQuery()
                $totalRowsAffected += $rowsAffected
            }
            
            $transaction.Commit()
            
            $conn.Close()
            
            Write-PodeJsonResponse -Value ([PSCustomObject]@{
                Success = $true
                Process = $process
                UpdateCount = $updates.Count
                RowsAffected = $totalRowsAffected
                ModifiedBy = $currentUser
            })
        }
        catch {
            $transaction.Rollback()
            throw
        }
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ----------------------------------------------------------------------------
# POST /api/dmops/abort
# Toggles the abort flag for archive or shell purge
# Body: { Process: 'archive'|'shellpurge', Abort: true|false }
# Updates GlobalConfig setting_value, logs change to ActionAuditLog
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Post -Path '/api/dmops/abort' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        $body = $WebEvent.Data
        $process = $body.Process
        $abort = [bool]$body.Abort
        
        $settingName = switch ($process) {
            'archive'    { 'archive_abort' }
            'shellpurge' { 'shell_purge_abort' }
            default {
                Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Invalid process: $process" }) -StatusCode 400
                return
            }
        }
        
        $category = switch ($process) {
            'archive'    { 'Archive' }
            'shellpurge' { 'ShellPurge' }
        }
        
        $abortValue = if ($abort) { '1' } else { '0' }
        $user = "FAC\$($WebEvent.Auth.User.Username)"
        
        # Look up current config_id and value for change logging
        $currentSetting = Invoke-XFActsQuery -Query @"
            SELECT config_id, setting_value
            FROM dbo.GlobalConfig
            WHERE module_name = 'DmOps' 
              AND category = @Category
              AND setting_name = @SettingName
              AND is_active = 1
"@ -Parameters @{ Category = $category; SettingName = $settingName }
        
        if (-not $currentSetting -or $currentSetting.Count -eq 0) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "GlobalConfig setting not found: DmOps/$category/$settingName" }) -StatusCode 404
            return
        }
        
        $configId = [int]$currentSetting[0].config_id
        $oldValue = [string]$currentSetting[0].setting_value
        
        # Update the setting value
        Invoke-XFActsQuery -Query @"
            UPDATE dbo.GlobalConfig
            SET setting_value = @AbortValue
            WHERE config_id = @ConfigId
"@ -Parameters @{ AbortValue = $abortValue; ConfigId = $configId }
        
        # Log the change to ActionAuditLog
        Invoke-XFActsQuery -Query @"
            INSERT INTO dbo.ActionAuditLog
                (source_module, entity_type, entity_id, entity_name, field_name, old_value, new_value, changed_by)
            VALUES
                (@Module, 'GlobalConfig', @ConfigId, @SettingName, 'setting_value', @OldVal, @NewVal, @User)
"@ -Parameters @{
            Module = 'DmOps'
            ConfigId = $configId
            SettingName = $settingName
            OldVal = $oldValue
            NewVal = $abortValue
            User = $user
        }
        
        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            Success = $true
            Process = $process
            Abort = $abort
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}
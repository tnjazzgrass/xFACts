# ============================================================================
# xFACts Control Center - Backup Monitoring API Endpoints
# Location: E:\xFACts-ControlCenter\scripts\routes\Backup-API.ps1
# Version: Tracked in dbo.System_Metadata (component: ServerOps.Backup)
#
# API endpoints for the Backup Monitoring page.
# Provides data for active operations, pipeline status, storage, and queues.
# ============================================================================

# ============================================================================
# API: Active Operations
# Returns backups in progress (DMV) and files currently being copied/uploaded
# Includes estimated progress based on dynamic speed calculations
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/backup/active-operations' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $results = @{
            backups_in_progress = @()
            network_copies_in_progress = @()
            aws_uploads_in_progress = @()
            timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
        
        # ------------------------------------------
        # Query each physical server for active backups
        # ------------------------------------------
        $xfactsConn = New-Object System.Data.SqlClient.SqlConnection("Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Application Name=xFACts Control Center;Connect Timeout=5;")
        $xfactsConn.Open()
        
        # Get list of physical servers (exclude AG listener)
        $serverCmd = $xfactsConn.CreateCommand()
        $serverCmd.CommandText = "SELECT server_name FROM dbo.ServerRegistry WHERE is_active = 1 AND server_type = 'SQL_SERVER' ORDER BY server_name"
        $serverCmd.CommandTimeout = 10
        $serverAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($serverCmd)
        $serverDataset = New-Object System.Data.DataSet
        $serverAdapter.Fill($serverDataset) | Out-Null
        
        $servers = @()
        foreach ($row in $serverDataset.Tables[0].Rows) {
            $servers += $row['server_name']
        }
        
        # DMV query for active backup operations
        $backupDmvQuery = @"
SELECT 
    r.session_id,
    r.command,
    CONVERT(NUMERIC(6,2), r.percent_complete) AS percent_complete,
    CONVERT(VARCHAR(20), DATEADD(ms, r.estimated_completion_time, GETDATE()), 120) AS eta_completion,
    CONVERT(NUMERIC(10,2), r.total_elapsed_time/1000.0/60.0) AS elapsed_minutes,
    CONVERT(NUMERIC(10,2), r.estimated_completion_time/1000.0/60.0) AS eta_minutes,
    SUBSTRING(st.text, (r.statement_start_offset/2) + 1,
        CASE WHEN r.statement_end_offset = -1 THEN LEN(st.text)
             ELSE (r.statement_end_offset - r.statement_start_offset)/2 + 1
        END) AS sql_text
FROM sys.dm_exec_requests r
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) st
WHERE r.command IN ('BACKUP DATABASE', 'BACKUP LOG', 'RESTORE DATABASE', 'RESTORE HEADERONLY')
"@
        
        foreach ($serverName in $servers) {
            try {
                $serverConn = New-Object System.Data.SqlClient.SqlConnection("Server=$serverName;Database=master;Integrated Security=True;Application Name=xFACts Control Center;Connect Timeout=5;")
                $serverConn.Open()
                $dmvCmd = $serverConn.CreateCommand()
                $dmvCmd.CommandText = $backupDmvQuery
                $dmvCmd.CommandTimeout = 10
                $dmvAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($dmvCmd)
                $dmvDataset = New-Object System.Data.DataSet
                $dmvAdapter.Fill($dmvDataset) | Out-Null
                $serverConn.Close()
                
                foreach ($row in $dmvDataset.Tables[0].Rows) {
                    # Parse database name from SQL text if possible
                    $sqlText = if ($row['sql_text'] -is [DBNull]) { "" } else { $row['sql_text'].ToString() }
                    $databaseName = ""
                    if ($sqlText -match "DATABASE\s+\[?(\w+)\]?") {
                        $databaseName = $Matches[1]
                    }
                    
                    $results.backups_in_progress += [PSCustomObject]@{
                        server_name = $serverName
                        database_name = $databaseName
                        command = if ($row['command'] -is [DBNull]) { "" } else { $row['command'] }
                        percent_complete = if ($row['percent_complete'] -is [DBNull]) { 0 } else { [decimal]$row['percent_complete'] }
                        eta_completion = if ($row['eta_completion'] -is [DBNull]) { "" } else { $row['eta_completion'] }
                        elapsed_minutes = if ($row['elapsed_minutes'] -is [DBNull]) { 0 } else { [decimal]$row['elapsed_minutes'] }
                        eta_minutes = if ($row['eta_minutes'] -is [DBNull]) { 0 } else { [decimal]$row['eta_minutes'] }
                    }
                }
            }
            catch {
                # Server unreachable - skip silently for active operations
            }
        }
        
        # ------------------------------------------
        # Calculate average speeds by backup type from last 30 days
        # ------------------------------------------
        $speedQuery = @"
SELECT 
    backup_type,
    AVG(CAST(COALESCE(compressed_size_bytes, file_size_bytes) AS FLOAT) / 
        NULLIF(DATEDIFF(SECOND, aws_upload_started_dttm, aws_upload_completed_dttm), 0)) AS aws_avg_bytes_per_sec,
    AVG(CAST(COALESCE(compressed_size_bytes, file_size_bytes) AS FLOAT) / 
        NULLIF(DATEDIFF(SECOND, network_copy_started_dttm, network_copy_completed_dttm), 0)) AS network_avg_bytes_per_sec
FROM ServerOps.Backup_FileTracking
WHERE (aws_upload_status = 'COMPLETED' OR network_copy_status = 'COMPLETED')
  AND backup_finish_dttm >= DATEADD(DAY, -30, GETDATE())
  AND (
      (aws_upload_started_dttm IS NOT NULL AND aws_upload_completed_dttm IS NOT NULL 
       AND DATEDIFF(SECOND, aws_upload_started_dttm, aws_upload_completed_dttm) > 0)
      OR
      (network_copy_started_dttm IS NOT NULL AND network_copy_completed_dttm IS NOT NULL 
       AND DATEDIFF(SECOND, network_copy_started_dttm, network_copy_completed_dttm) > 0)
  )
GROUP BY backup_type
"@
        
        $speedCmd = $xfactsConn.CreateCommand()
        $speedCmd.CommandText = $speedQuery
        $speedCmd.CommandTimeout = 15
        $speedAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($speedCmd)
        $speedDataset = New-Object System.Data.DataSet
        $speedAdapter.Fill($speedDataset) | Out-Null
        
        # Build lookup tables for speeds
        $awsSpeeds = @{}
        $networkSpeeds = @{}
        foreach ($row in $speedDataset.Tables[0].Rows) {
            $backupType = $row['backup_type']
            if ($row['aws_avg_bytes_per_sec'] -isnot [DBNull]) {
                $awsSpeeds[$backupType] = [double]$row['aws_avg_bytes_per_sec']
            }
            if ($row['network_avg_bytes_per_sec'] -isnot [DBNull]) {
                $networkSpeeds[$backupType] = [double]$row['network_avg_bytes_per_sec']
            }
        }
        
        # Default speeds if no data for a type (conservative estimates)
        $defaultAwsSpeed = 50000000   # 50 MB/sec
        $defaultNetworkSpeed = 100000000  # 100 MB/sec
        
        # ------------------------------------------
        # Query FileTracking for IN_PROGRESS operations
        # ------------------------------------------
        $inProgressQuery = @"
SELECT 
    tracking_id,
    server_name,
    database_name,
    backup_type,
    file_name,
    COALESCE(compressed_size_bytes, file_size_bytes) AS file_size_bytes,
    network_copy_status,
    network_copy_started_dttm,
    aws_upload_status,
    aws_upload_started_dttm
FROM ServerOps.Backup_FileTracking
WHERE network_copy_status = 'IN_PROGRESS'
   OR aws_upload_status = 'IN_PROGRESS'
ORDER BY COALESCE(network_copy_started_dttm, aws_upload_started_dttm)
"@
        
        $trackingCmd = $xfactsConn.CreateCommand()
        $trackingCmd.CommandText = $inProgressQuery
        $trackingCmd.CommandTimeout = 10
        $trackingAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($trackingCmd)
        $trackingDataset = New-Object System.Data.DataSet
        $trackingAdapter.Fill($trackingDataset) | Out-Null
        
        $now = Get-Date
        
        foreach ($row in $trackingDataset.Tables[0].Rows) {
            $backupType = $row['backup_type']
            $fileSize = if ($row['file_size_bytes'] -is [DBNull]) { 0 } else { [long]$row['file_size_bytes'] }
            
            if ($row['network_copy_status'] -eq 'IN_PROGRESS') {
                $startedDttm = if ($row['network_copy_started_dttm'] -is [DBNull]) { $null } else { [DateTime]$row['network_copy_started_dttm'] }
                $speed = if ($networkSpeeds.ContainsKey($backupType)) { $networkSpeeds[$backupType] } else { $defaultNetworkSpeed }
                
                $elapsedMinutes = 0
                $percentComplete = 0
                $etaMinutes = 0
                
                if ($null -ne $startedDttm -and $fileSize -gt 0 -and $speed -gt 0) {
                    $elapsedSeconds = ($now - $startedDttm).TotalSeconds
                    $elapsedMinutes = [math]::Round($elapsedSeconds / 60, 1)
                    $estimatedBytesTransferred = $elapsedSeconds * $speed
                    $percentComplete = [math]::Min([math]::Round(($estimatedBytesTransferred / $fileSize) * 100, 1), 99.9)
                    $remainingBytes = [math]::Max($fileSize - $estimatedBytesTransferred, 0)
                    $etaMinutes = [math]::Round(($remainingBytes / $speed) / 60, 1)
                }
                
                $results.network_copies_in_progress += [PSCustomObject]@{
                    tracking_id = [long]$row['tracking_id']
                    server_name = $row['server_name']
                    database_name = $row['database_name']
                    backup_type = $backupType
                    file_name = $row['file_name']
                    file_size_bytes = $fileSize
                    started_dttm = if ($null -ne $startedDttm) { $startedDttm.ToString("yyyy-MM-dd HH:mm:ss") } else { $null }
                    percent_complete = $percentComplete
                    elapsed_minutes = $elapsedMinutes
                    eta_minutes = $etaMinutes
                }
            }
            
            if ($row['aws_upload_status'] -eq 'IN_PROGRESS') {
                $startedDttm = if ($row['aws_upload_started_dttm'] -is [DBNull]) { $null } else { [DateTime]$row['aws_upload_started_dttm'] }
                $speed = if ($awsSpeeds.ContainsKey($backupType)) { $awsSpeeds[$backupType] } else { $defaultAwsSpeed }
                
                $elapsedMinutes = 0
                $percentComplete = 0
                $etaMinutes = 0
                
                if ($null -ne $startedDttm -and $fileSize -gt 0 -and $speed -gt 0) {
                    $elapsedSeconds = ($now - $startedDttm).TotalSeconds
                    $elapsedMinutes = [math]::Round($elapsedSeconds / 60, 1)
                    $estimatedBytesTransferred = $elapsedSeconds * $speed
                    $percentComplete = [math]::Min([math]::Round(($estimatedBytesTransferred / $fileSize) * 100, 1), 99.9)
                    $remainingBytes = [math]::Max($fileSize - $estimatedBytesTransferred, 0)
                    $etaMinutes = [math]::Round(($remainingBytes / $speed) / 60, 1)
                }
                
                $results.aws_uploads_in_progress += [PSCustomObject]@{
                    tracking_id = [long]$row['tracking_id']
                    server_name = $row['server_name']
                    database_name = $row['database_name']
                    backup_type = $backupType
                    file_name = $row['file_name']
                    file_size_bytes = $fileSize
                    started_dttm = if ($null -ne $startedDttm) { $startedDttm.ToString("yyyy-MM-dd HH:mm:ss") } else { $null }
                    percent_complete = $percentComplete
                    elapsed_minutes = $elapsedMinutes
                    eta_minutes = $etaMinutes
                }
            }
        }
        
        $xfactsConn.Close()
        Write-PodeJsonResponse -Value $results
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ error = $_.Exception.Message }) -StatusCode 500
    }
}

# ============================================================================
# API: Pipeline Status
# Returns timing/status from Orchestrator.TaskLog and file metrics from
# Backup_ExecutionLog for the 4 backup pipeline processes.
# Replaces the former Backup_Status table dependency.
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/backup/pipeline-status' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Application Name=xFACts Control Center;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        
        # Map ProcessRegistry process_name -> pipeline card label
        $processMap = @{
            'Collect-BackupStatus'       = 'COLLECTION'
            'Process-BackupNetworkCopy'  = 'NETWORK_COPY'
            'Process-BackupAWSUpload'    = 'AWS_UPLOAD'
            'Process-BackupRetention'    = 'RETENTION'
        }
        
        # Get the most recent completed task per backup process from TaskLog
        $taskLogCmd = $conn.CreateCommand()
        $taskLogCmd.CommandText = @"
;WITH LatestTasks AS (
    SELECT 
        t.process_name,
        t.start_dttm,
        t.end_dttm,
        t.duration_ms,
        t.task_status,
        t.error_output,
        ROW_NUMBER() OVER (
            PARTITION BY t.process_id 
            ORDER BY t.start_dttm DESC
        ) AS rn
    FROM Orchestrator.TaskLog t
    JOIN Orchestrator.ProcessRegistry pr ON t.process_id = pr.process_id
    WHERE pr.process_name IN ('Collect-BackupStatus', 'Process-BackupNetworkCopy', 'Process-BackupAWSUpload', 'Process-BackupRetention')
      AND t.task_status IN ('SUCCESS', 'FAILED')
)
SELECT process_name, start_dttm, end_dttm, duration_ms, task_status, error_output
FROM LatestTasks
WHERE rn = 1
"@
        $taskLogCmd.CommandTimeout = 10
        $taskLogAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($taskLogCmd)
        $taskLogDataset = New-Object System.Data.DataSet
        $taskLogAdapter.Fill($taskLogDataset) | Out-Null
        
        # Build a lookup of TaskLog results keyed by pipeline label
        $taskData = @{}
        foreach ($row in $taskLogDataset.Tables[0].Rows) {
            $regName = $row['process_name']
            $label = $processMap[$regName]
            if ($label) {
                $taskData[$label] = @{
                    started_dttm  = if ($row['start_dttm'] -is [DBNull]) { $null } else { [DateTime]$row['start_dttm'] }
                    completed_dttm = if ($row['end_dttm'] -is [DBNull]) { $null } else { [DateTime]$row['end_dttm'] }
                    duration_ms   = if ($row['duration_ms'] -is [DBNull]) { $null } else { [int]$row['duration_ms'] }
                    task_status   = if ($row['task_status'] -is [DBNull]) { $null } else { $row['task_status'] }
                    error_output  = if ($row['error_output'] -is [DBNull]) { $null } else { $row['error_output'] }
                }
            }
        }
        
        # Get file count and bytes from ExecutionLog for each process's last run window
        $execLogCmd = $conn.CreateCommand()
        $execLogCmd.CommandText = @"
;WITH LatestTasks AS (
    SELECT 
        pr.process_name AS reg_name,
        t.start_dttm,
        t.end_dttm,
        CASE pr.process_name
            WHEN 'Collect-BackupStatus' THEN 'COLLECTION'
            WHEN 'Process-BackupNetworkCopy' THEN 'NETWORK_COPY'
            WHEN 'Process-BackupAWSUpload' THEN 'AWS_UPLOAD'
            WHEN 'Process-BackupRetention' THEN 'RETENTION'
        END AS component,
        ROW_NUMBER() OVER (
            PARTITION BY t.process_id 
            ORDER BY t.start_dttm DESC
        ) AS rn
    FROM Orchestrator.TaskLog t
    JOIN Orchestrator.ProcessRegistry pr ON t.process_id = pr.process_id
    WHERE pr.process_name IN ('Collect-BackupStatus', 'Process-BackupNetworkCopy', 'Process-BackupAWSUpload', 'Process-BackupRetention')
      AND t.task_status IN ('SUCCESS', 'FAILED')
)
SELECT 
    lt.component,
    COUNT(el.log_id) AS files_processed,
    ISNULL(SUM(el.bytes_processed), 0) AS bytes_processed
FROM LatestTasks lt
LEFT JOIN ServerOps.Backup_ExecutionLog el 
    ON el.component = lt.component
    AND el.started_dttm >= lt.start_dttm
    AND el.started_dttm <= ISNULL(lt.end_dttm, GETDATE())
    AND el.status = 'SUCCESS'
WHERE lt.rn = 1
GROUP BY lt.component
"@
        $execLogCmd.CommandTimeout = 15
        $execLogAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($execLogCmd)
        $execLogDataset = New-Object System.Data.DataSet
        $execLogAdapter.Fill($execLogDataset) | Out-Null
        
        # Build lookup for exec metrics
        $execMetrics = @{}
        foreach ($row in $execLogDataset.Tables[0].Rows) {
            $component = $row['component']
            $execMetrics[$component] = @{
                files_processed = if ($row['files_processed'] -is [DBNull]) { 0 } else { [int]$row['files_processed'] }
                bytes_processed = if ($row['bytes_processed'] -is [DBNull]) { 0 } else { [long]$row['bytes_processed'] }
            }
        }
        
        # Get retention scheduled time from ProcessRegistry
        $configCmd = $conn.CreateCommand()
        $configCmd.CommandText = "SELECT scheduled_time FROM Orchestrator.ProcessRegistry WHERE process_name = 'Process-BackupRetention'"
        $configCmd.CommandTimeout = 5
        $retentionScheduledTime = $configCmd.ExecuteScalar()
        if ($null -eq $retentionScheduledTime -or $retentionScheduledTime -is [DBNull]) { 
            $retentionTimeStr = $null 
        } else { 
            $retentionTimeStr = ([TimeSpan]$retentionScheduledTime).ToString('hh\:mm\:ss')
        }
        
        $conn.Close()
        
        # Build the response in the same shape the JS expects
        $processOrder = @('COLLECTION', 'NETWORK_COPY', 'AWS_UPLOAD', 'RETENTION')
        $results = @()
        
        foreach ($label in $processOrder) {
            $task = $taskData[$label]
            $metrics = $execMetrics[$label]
            
            $startedDttm = if ($task) { $task.started_dttm } else { $null }
            $completedDttm = if ($task) { $task.completed_dttm } else { $null }
            
            $results += [PSCustomObject]@{
                process_name = $label
                started_dttm = if ($null -ne $startedDttm) { $startedDttm.ToString("yyyy-MM-dd HH:mm:ss") } else { $null }
                completed_dttm = if ($null -ne $completedDttm) { $completedDttm.ToString("yyyy-MM-dd HH:mm:ss") } else { $null }
                last_status = if ($task) { $task.task_status } else { $null }
                last_duration_ms = if ($task) { $task.duration_ms } else { $null }
                last_files_processed = if ($metrics) { $metrics.files_processed } else { 0 }
                last_bytes_processed = if ($metrics) { $metrics.bytes_processed } else { 0 }
                last_error_message = if ($task) { $task.error_output } else { $null }
                minutes_since_completion = if ($null -ne $completedDttm) { [int](New-TimeSpan -Start $completedDttm -End (Get-Date)).TotalMinutes } else { $null }
            }
        }
        
        Write-PodeJsonResponse -Value @{
            processes = $results
            retention_scheduled_time = $retentionTimeStr
            timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ error = $_.Exception.Message }) -StatusCode 500
    }
}

# ============================================================================
# API: Storage Status
# Returns backup drive free space and pending retention calculation
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/backup/storage-status' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Application Name=xFACts Control Center;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        
        # ------------------------------------------
        # Get backup drives from FileTracking (distinct first char of local_path)
        # ------------------------------------------
        $backupDrivesQuery = @"
;WITH BackupDrives AS (
    SELECT DISTINCT 
        ft.server_id,
        sr.server_name,
        UPPER(LEFT(ft.local_path, 1)) AS drive_letter
    FROM ServerOps.Backup_FileTracking ft
    JOIN dbo.ServerRegistry sr ON ft.server_id = sr.server_id
    WHERE ft.local_path IS NOT NULL
      AND ft.local_deleted_dttm IS NULL
      AND sr.is_active = 1
)
SELECT 
    bd.server_name,
    bd.drive_letter,
    ds.total_size_mb,
    ds.free_space_mb,
    ds.percent_free,
    ds.snapshot_dttm
FROM BackupDrives bd
JOIN ServerOps.Disk_Snapshot ds ON bd.server_id = ds.server_id AND bd.drive_letter = ds.drive_letter
WHERE ds.snapshot_id = (
    SELECT MAX(ds2.snapshot_id)
    FROM ServerOps.Disk_Snapshot ds2
    WHERE ds2.server_id = bd.server_id AND ds2.drive_letter = bd.drive_letter
)
ORDER BY bd.server_name, bd.drive_letter
"@
        
        $drivesCmd = $conn.CreateCommand()
        $drivesCmd.CommandText = $backupDrivesQuery
        $drivesCmd.CommandTimeout = 15
        $drivesAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($drivesCmd)
        $drivesDataset = New-Object System.Data.DataSet
        $drivesAdapter.Fill($drivesDataset) | Out-Null
        
        $localDrives = @()
        foreach ($row in $drivesDataset.Tables[0].Rows) {
            $localDrives += [PSCustomObject]@{
                server_name = $row['server_name']
                drive_letter = $row['drive_letter']
                total_size_mb = if ($row['total_size_mb'] -is [DBNull]) { 0 } else { [long]$row['total_size_mb'] }
                free_space_mb = if ($row['free_space_mb'] -is [DBNull]) { 0 } else { [long]$row['free_space_mb'] }
                percent_free = if ($row['percent_free'] -is [DBNull]) { 0 } else { [decimal]$row['percent_free'] }
                snapshot_dttm = if ($row['snapshot_dttm'] -is [DBNull]) { $null } else { ([DateTime]$row['snapshot_dttm']).ToString("yyyy-MM-dd HH:mm:ss") }
            }
        }
        
        # ------------------------------------------
        # Get network backup root and check free space
        # ------------------------------------------
        $networkCmd = $conn.CreateCommand()
        $networkCmd.CommandText = "SELECT setting_value FROM dbo.GlobalConfig WHERE module_name = 'ServerOps' AND category = 'Backup' AND setting_name = 'network_backup_root' AND is_active = 1"
        $networkCmd.CommandTimeout = 5
        $networkRoot = $networkCmd.ExecuteScalar()
        
        $networkStorage = $null
        if ($networkRoot) {
            try {
                # Query the network share for free space
                # The network path is typically like \\server\share or \\server\X$ (admin share)
                if ($networkRoot -match '^\\\\([^\\]+)\\([^\\]+)') {
                    $networkServer = $Matches[1]
                    $networkShare = $Matches[2]
                    
                    # Check if this is an admin share (ends with $)
                    # Admin shares like G$ map directly to drive letter G:
                    if ($networkShare -match '^([A-Za-z])\$$') {
                        $driveLetter = $Matches[1].ToUpper()
                        $deviceId = "$driveLetter`:"
                        
                        # Query the drive directly via CIM
                        $session = New-CimSession -ComputerName $networkServer -ErrorAction Stop
                        $disk = Get-CimInstance -CimSession $session -ClassName Win32_LogicalDisk -Filter "DeviceID='$deviceId'" -ErrorAction SilentlyContinue
                        Remove-CimSession $session
                        
                        if ($disk -and $disk.Size -gt 0) {
                            $networkStorage = [PSCustomObject]@{
                                path = $networkRoot
                                total_size_mb = [math]::Round($disk.Size / 1MB, 0)
                                free_space_mb = [math]::Round($disk.FreeSpace / 1MB, 0)
                                percent_free = [math]::Round(($disk.FreeSpace / $disk.Size) * 100, 2)
                            }
                        }
                        else {
                            $networkStorage = [PSCustomObject]@{
                                path = $networkRoot
                                error = "Unable to query drive $deviceId on $networkServer"
                            }
                        }
                    }
                    else {
                        # Regular share - try to find what drive hosts it
                        $session = New-CimSession -ComputerName $networkServer -ErrorAction Stop
                        $shares = Get-CimInstance -CimSession $session -ClassName Win32_Share -Filter "Name='$networkShare'" -ErrorAction SilentlyContinue
                        
                        if ($shares -and $shares.Path) {
                            $shareDriveLetter = $shares.Path.Substring(0, 2)
                            $disk = Get-CimInstance -CimSession $session -ClassName Win32_LogicalDisk -Filter "DeviceID='$shareDriveLetter'" -ErrorAction SilentlyContinue
                            
                            if ($disk -and $disk.Size -gt 0) {
                                $networkStorage = [PSCustomObject]@{
                                    path = $networkRoot
                                    total_size_mb = [math]::Round($disk.Size / 1MB, 0)
                                    free_space_mb = [math]::Round($disk.FreeSpace / 1MB, 0)
                                    percent_free = [math]::Round(($disk.FreeSpace / $disk.Size) * 100, 2)
                                }
                            }
                        }
                        
                        Remove-CimSession $session
                        
                        if ($null -eq $networkStorage) {
                            $networkStorage = [PSCustomObject]@{
                                path = $networkRoot
                                error = "Unable to resolve share '$networkShare' on $networkServer"
                            }
                        }
                    }
                }
                else {
                    $networkStorage = [PSCustomObject]@{
                        path = $networkRoot
                        error = "Invalid network path format"
                    }
                }
            }
            catch {
                # Network storage check failed - continue without it
                $networkStorage = [PSCustomObject]@{
                    path = $networkRoot
                    error = "Unable to query network storage: $($_.Exception.Message)"
                }
            }
        }
        
        # ------------------------------------------
        # Calculate pending retention (local and network)
        # Uses same logic as Process-BackupRetention.ps1
        # ------------------------------------------
        $pendingRetentionQuery = @"
;WITH LocalFullRanked AS (
    SELECT 
        server_name,
        database_name,
        backup_finish_dttm,
        ROW_NUMBER() OVER (
            PARTITION BY server_name, database_name 
            ORDER BY backup_finish_dttm DESC
        ) AS rn
    FROM ServerOps.Backup_FileTracking
    WHERE backup_type = 'FULL'
      AND local_deleted_dttm IS NULL
      AND local_path IS NOT NULL
),
LocalCutoffs AS (
    SELECT 
        dc.server_name,
        dc.database_name,
        dc.full_retention_chain_local_count,
        lfr.backup_finish_dttm AS cutoff_dttm
    FROM ServerOps.Backup_DatabaseConfig dc
    JOIN dbo.ServerRegistry sr ON dc.server_name = sr.server_name
    LEFT JOIN LocalFullRanked lfr 
        ON dc.server_name = lfr.server_name 
        AND dc.database_name = lfr.database_name
        AND lfr.rn = dc.full_retention_chain_local_count
    WHERE dc.full_retention_chain_local_count > 0
      AND sr.is_active = 1
      AND sr.serverops_backup_enabled = 1
),
NetworkFullRanked AS (
    SELECT 
        server_name,
        database_name,
        backup_finish_dttm,
        ROW_NUMBER() OVER (
            PARTITION BY server_name, database_name 
            ORDER BY backup_finish_dttm DESC
        ) AS rn
    FROM ServerOps.Backup_FileTracking
    WHERE backup_type = 'FULL'
      AND network_deleted_dttm IS NULL
      AND network_path IS NOT NULL
),
NetworkCutoffs AS (
    SELECT 
        dc.server_name,
        dc.database_name,
        dc.full_retention_chain_network_count,
        nfr.backup_finish_dttm AS cutoff_dttm
    FROM ServerOps.Backup_DatabaseConfig dc
    JOIN dbo.ServerRegistry sr ON dc.server_name = sr.server_name
    LEFT JOIN NetworkFullRanked nfr 
        ON dc.server_name = nfr.server_name 
        AND dc.database_name = nfr.database_name
        AND nfr.rn = dc.full_retention_chain_network_count
    WHERE dc.full_retention_chain_network_count > 0
      AND sr.is_active = 1
      AND sr.serverops_backup_enabled = 1
)
SELECT 
    'LOCAL' AS retention_type,
    COUNT(*) AS file_count,
    ISNULL(SUM(COALESCE(ft.compressed_size_bytes, ft.file_size_bytes)), 0) AS total_bytes
FROM ServerOps.Backup_FileTracking ft
JOIN LocalCutoffs lc ON ft.server_name = lc.server_name AND ft.database_name = lc.database_name
WHERE ft.network_copy_status IN ('COMPLETED', 'HISTORICAL')
  AND ft.local_deleted_dttm IS NULL
  AND ft.local_path IS NOT NULL
  AND lc.cutoff_dttm IS NOT NULL
  AND ft.backup_finish_dttm < lc.cutoff_dttm

UNION ALL

SELECT 
    'NETWORK' AS retention_type,
    COUNT(*) AS file_count,
    ISNULL(SUM(COALESCE(ft.compressed_size_bytes, ft.file_size_bytes)), 0) AS total_bytes
FROM ServerOps.Backup_FileTracking ft
JOIN NetworkCutoffs nc ON ft.server_name = nc.server_name AND ft.database_name = nc.database_name
WHERE ft.network_deleted_dttm IS NULL
  AND ft.network_path IS NOT NULL
  AND nc.cutoff_dttm IS NOT NULL
  AND ft.backup_finish_dttm < nc.cutoff_dttm
"@
        
        $retentionCmd = $conn.CreateCommand()
        $retentionCmd.CommandText = $pendingRetentionQuery
        $retentionCmd.CommandTimeout = 30
        $retentionAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($retentionCmd)
        $retentionDataset = New-Object System.Data.DataSet
        $retentionAdapter.Fill($retentionDataset) | Out-Null
        
        $pendingRetention = @{
            local = @{ file_count = 0; total_bytes = 0 }
            network = @{ file_count = 0; total_bytes = 0 }
        }
        
        foreach ($row in $retentionDataset.Tables[0].Rows) {
            $type = $row['retention_type'].ToLower()
            $pendingRetention[$type] = @{
                file_count = if ($row['file_count'] -is [DBNull]) { 0 } else { [int]$row['file_count'] }
                total_bytes = if ($row['total_bytes'] -is [DBNull]) { 0 } else { [long]$row['total_bytes'] }
            }
        }
        
        $conn.Close()
        
        Write-PodeJsonResponse -Value @{
            local_drives = $localDrives
            network_storage = $networkStorage
            pending_retention = $pendingRetention
            timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ error = $_.Exception.Message }) -StatusCode 500
    }
}

# ============================================================================
# API: Queue Status
# Returns counts of files in PENDING status for network copy and AWS upload
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/backup/queue-status' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Application Name=xFACts Control Center;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = @"
SELECT 
    'NETWORK_COPY' AS queue_type,
    COUNT(*) AS file_count,
    ISNULL(SUM(COALESCE(ft.compressed_size_bytes, ft.file_size_bytes)), 0) AS total_bytes,
    MIN(ft.backup_finish_dttm) AS oldest_file_dttm
FROM ServerOps.Backup_FileTracking ft
JOIN dbo.ServerRegistry sr ON ft.server_id = sr.server_id
JOIN dbo.DatabaseRegistry dr ON ft.server_id = dr.server_id AND ft.database_name = dr.database_name
JOIN ServerOps.Backup_DatabaseConfig dc ON dr.database_id = dc.database_id
WHERE ft.network_copy_status = 'PENDING'
  AND sr.is_active = 1
  AND sr.serverops_backup_enabled = 1
  AND dc.backup_network_copy_enabled = 1

UNION ALL

SELECT 
    'AWS_UPLOAD' AS queue_type,
    COUNT(*) AS file_count,
    ISNULL(SUM(COALESCE(ft.compressed_size_bytes, ft.file_size_bytes)), 0) AS total_bytes,
    MIN(ft.backup_finish_dttm) AS oldest_file_dttm
FROM ServerOps.Backup_FileTracking ft
JOIN dbo.ServerRegistry sr ON ft.server_id = sr.server_id
JOIN dbo.DatabaseRegistry dr ON ft.server_id = dr.server_id AND ft.database_name = dr.database_name
JOIN ServerOps.Backup_DatabaseConfig dc ON dr.database_id = dc.database_id
WHERE ft.aws_upload_status = 'PENDING'
  AND sr.is_active = 1
  AND sr.serverops_backup_enabled = 1
  AND dc.backup_aws_upload_enabled = 1
"@
        $cmd.CommandTimeout = 15
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        $conn.Close()
        
        $results = @{
            network_copy = @{ file_count = 0; total_bytes = 0; oldest_file_dttm = $null }
            aws_upload = @{ file_count = 0; total_bytes = 0; oldest_file_dttm = $null }
        }
        
        foreach ($row in $dataset.Tables[0].Rows) {
            $queueType = $row['queue_type'].ToLower() -replace '_', '_'
            $key = if ($queueType -eq 'network_copy') { 'network_copy' } else { 'aws_upload' }
            
            $results[$key] = @{
                file_count = if ($row['file_count'] -is [DBNull]) { 0 } else { [int]$row['file_count'] }
                total_bytes = if ($row['total_bytes'] -is [DBNull]) { 0 } else { [long]$row['total_bytes'] }
                oldest_file_dttm = if ($row['oldest_file_dttm'] -is [DBNull]) { $null } else { ([DateTime]$row['oldest_file_dttm']).ToString("yyyy-MM-dd HH:mm:ss") }
            }
        }
        
        $results.timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        
        Write-PodeJsonResponse -Value $results
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ error = $_.Exception.Message }) -StatusCode 500
    }
}

# ============================================================================
# API: Pipeline Detail
# Returns file-level detail from ExecutionLog for the most recent run
# of a specified backup pipeline process.
# Uses Orchestrator.TaskLog for the run time window (fixes timing gap).
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/backup/pipeline-detail' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $process = $WebEvent.Query['process']
        if ($process -notin @('COLLECTION', 'NETWORK_COPY', 'AWS_UPLOAD', 'RETENTION')) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ error = "Invalid process parameter." }) -StatusCode 400
            return
        }
        
        # Map pipeline label back to ProcessRegistry process_name
        $regNameMap = @{
            'COLLECTION'   = 'Collect-BackupStatus'
            'NETWORK_COPY' = 'Process-BackupNetworkCopy'
            'AWS_UPLOAD'   = 'Process-BackupAWSUpload'
            'RETENTION'    = 'Process-BackupRetention'
        }
        $regName = $regNameMap[$process]
        
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Application Name=xFACts Control Center;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        
        # Get the last completed run window from TaskLog
        $taskCmd = $conn.CreateCommand()
        $taskCmd.CommandText = @"
SELECT TOP 1 
    t.start_dttm, 
    t.end_dttm, 
    t.duration_ms, 
    t.task_status, 
    t.error_output
FROM Orchestrator.TaskLog t
JOIN Orchestrator.ProcessRegistry pr ON t.process_id = pr.process_id
WHERE pr.process_name = '$regName'
  AND t.task_status IN ('SUCCESS', 'FAILED')
ORDER BY t.start_dttm DESC
"@
        $taskCmd.CommandTimeout = 10
        $taskAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($taskCmd)
        $taskDataset = New-Object System.Data.DataSet
        $taskAdapter.Fill($taskDataset) | Out-Null
        
        $summary = $null
        $startDttm = $null
        $endDttm = $null
        if ($taskDataset.Tables[0].Rows.Count -gt 0) {
            $row = $taskDataset.Tables[0].Rows[0]
            $startDttm = if ($row['start_dttm'] -is [DBNull]) { $null } else { [DateTime]$row['start_dttm'] }
            $endDttm = if ($row['end_dttm'] -is [DBNull]) { $null } else { [DateTime]$row['end_dttm'] }
            
            # Get aggregate file metrics from ExecutionLog for this run window
            $metricsCmd = $conn.CreateCommand()
            $metricsStartStr = $startDttm.ToString("yyyy-MM-dd HH:mm:ss.fff")
            $metricsEndStr = if ($null -ne $endDttm) { $endDttm.ToString("yyyy-MM-dd HH:mm:ss.fff") } else { (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff") }
            $metricsCmd.CommandText = @"
SELECT 
    COUNT(*) AS files_processed,
    ISNULL(SUM(bytes_processed), 0) AS bytes_processed
FROM ServerOps.Backup_ExecutionLog
WHERE component = '$process'
  AND started_dttm >= '$metricsStartStr'
  AND started_dttm <= '$metricsEndStr'
  AND status = 'SUCCESS'
"@
            $metricsCmd.CommandTimeout = 10
            $metricsResult = $metricsCmd.ExecuteReader()
            $filesProcessed = 0
            $bytesProcessed = [long]0
            if ($metricsResult.Read()) {
                $filesProcessed = if ($metricsResult.IsDBNull(0)) { 0 } else { $metricsResult.GetInt32(0) }
                $bytesProcessed = if ($metricsResult.IsDBNull(1)) { [long]0 } else { $metricsResult.GetInt64(1) }
            }
            $metricsResult.Close()
            
            $summary = [PSCustomObject]@{
                started_dttm = if ($null -ne $startDttm) { $startDttm.ToString("yyyy-MM-dd HH:mm:ss") } else { $null }
                completed_dttm = if ($null -ne $endDttm) { $endDttm.ToString("yyyy-MM-dd HH:mm:ss") } else { $null }
                last_status = if ($row['task_status'] -is [DBNull]) { $null } else { $row['task_status'] }
                last_files_processed = $filesProcessed
                last_bytes_processed = $bytesProcessed
                last_duration_ms = if ($row['duration_ms'] -is [DBNull]) { 0 } else { [int]$row['duration_ms'] }
                last_error_message = if ($row['error_output'] -is [DBNull]) { $null } else { $row['error_output'] }
            }
        }
        
        # Get file-level detail from ExecutionLog for the last run
        $files = @()
        if ($null -ne $startDttm) {
            $startStr = $startDttm.ToString("yyyy-MM-dd HH:mm:ss.fff")
            $endStr = if ($null -ne $endDttm) { $endDttm.ToString("yyyy-MM-dd HH:mm:ss.fff") } else { (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff") }
            
            $detailCmd = $conn.CreateCommand()
            $detailCmd.CommandText = @"
SELECT server_name, database_name, file_name, tracking_id, status,
       bytes_processed, duration_ms, error_message, started_dttm, completed_dttm
FROM ServerOps.Backup_ExecutionLog
WHERE component = '$process'
  AND started_dttm >= '$startStr'
  AND started_dttm <= '$endStr'
ORDER BY started_dttm
"@
            $detailCmd.CommandTimeout = 15
            $detailAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($detailCmd)
            $detailDataset = New-Object System.Data.DataSet
            $detailAdapter.Fill($detailDataset) | Out-Null
            
            foreach ($row in $detailDataset.Tables[0].Rows) {
                $files += [PSCustomObject]@{
                    server_name = if ($row['server_name'] -is [DBNull]) { $null } else { $row['server_name'] }
                    database_name = if ($row['database_name'] -is [DBNull]) { $null } else { $row['database_name'] }
                    file_name = if ($row['file_name'] -is [DBNull]) { $null } else { $row['file_name'] }
                    tracking_id = if ($row['tracking_id'] -is [DBNull]) { $null } else { [long]$row['tracking_id'] }
                    status = if ($row['status'] -is [DBNull]) { $null } else { $row['status'] }
                    bytes_processed = if ($row['bytes_processed'] -is [DBNull]) { 0 } else { [long]$row['bytes_processed'] }
                    duration_ms = if ($row['duration_ms'] -is [DBNull]) { 0 } else { [int]$row['duration_ms'] }
                    error_message = if ($row['error_message'] -is [DBNull]) { $null } else { $row['error_message'] }
                }
            }
        }
        
        $conn.Close()
        
        Write-PodeJsonResponse -Value @{
            process = $process
            summary = $summary
            files = $files
            timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ error = $_.Exception.Message }) -StatusCode 500
    }
}

# ============================================================================
# API: Queue Detail
# Returns file-level detail for pending queue items (network copy or AWS upload)
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/backup/queue-detail' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $type = $WebEvent.Query['type']
        if ($type -notin @('network', 'aws')) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ error = "Invalid type parameter. Use 'network' or 'aws'." }) -StatusCode 400
            return
        }
        
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Application Name=xFACts Control Center;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        
        $statusColumn = if ($type -eq 'network') { 'network_copy_status' } else { 'aws_upload_status' }
        $enabledColumn = if ($type -eq 'network') { 'backup_network_copy_enabled' } else { 'backup_aws_upload_enabled' }
        
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = @"
SELECT ft.server_name, ft.database_name, ft.backup_type, ft.file_name,
       ft.backup_finish_dttm,
       COALESCE(ft.compressed_size_bytes, ft.file_size_bytes) AS file_size_bytes
FROM ServerOps.Backup_FileTracking ft
JOIN dbo.DatabaseRegistry dr ON ft.server_id = dr.server_id AND ft.database_name = dr.database_name
JOIN dbo.ServerRegistry sr ON dr.server_id = sr.server_id
JOIN ServerOps.Backup_DatabaseConfig dc ON dr.database_id = dc.database_id
WHERE ft.$statusColumn = 'PENDING'
  AND sr.is_active = 1
  AND sr.serverops_backup_enabled = 1
  AND dr.is_active = 1
  AND dc.$enabledColumn = 1
ORDER BY ft.backup_finish_dttm
"@
        $cmd.CommandTimeout = 15
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        $conn.Close()
        
        $files = @()
        foreach ($row in $dataset.Tables[0].Rows) {
            $files += [PSCustomObject]@{
                server_name = $row['server_name']
                database_name = $row['database_name']
                backup_type = $row['backup_type']
                file_name = $row['file_name']
                backup_finish_dttm = ([DateTime]$row['backup_finish_dttm']).ToString("yyyy-MM-dd HH:mm:ss")
                file_size_bytes = if ($row['file_size_bytes'] -is [DBNull]) { 0 } else { [long]$row['file_size_bytes'] }
            }
        }
        
        Write-PodeJsonResponse -Value @{
            type = $type
            files = $files
            total_count = $files.Count
            total_bytes = ($files | Measure-Object -Property file_size_bytes -Sum).Sum
            timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ error = $_.Exception.Message }) -StatusCode 500
    }
}

# ============================================================================
# API: Retention Candidates Detail
# Returns file-level detail for retention candidates (local or network)
# Used by retention slideout panels for pre-run review
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/backup/retention-candidates' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $type = $WebEvent.Query['type']
        if ($type -notin @('local', 'network')) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ error = "Invalid type parameter. Use 'local' or 'network'." }) -StatusCode 400
            return
        }
        
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Application Name=xFACts Control Center;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        
        if ($type -eq 'local') {
            $query = @"
;WITH LocalFullRanked AS (
    SELECT 
        server_name,
        database_name,
        backup_finish_dttm,
        ROW_NUMBER() OVER (
            PARTITION BY server_name, database_name 
            ORDER BY backup_finish_dttm DESC
        ) AS rn
    FROM ServerOps.Backup_FileTracking
    WHERE backup_type = 'FULL'
      AND local_deleted_dttm IS NULL
      AND local_path IS NOT NULL
),
LocalCutoffs AS (
    SELECT 
        dc.server_name,
        dc.database_name,
        dc.full_retention_chain_local_count AS chain_count,
        lfr.backup_finish_dttm AS cutoff_dttm
    FROM ServerOps.Backup_DatabaseConfig dc
    JOIN dbo.ServerRegistry sr ON dc.server_name = sr.server_name
    LEFT JOIN LocalFullRanked lfr 
        ON dc.server_name = lfr.server_name 
        AND dc.database_name = lfr.database_name
        AND lfr.rn = dc.full_retention_chain_local_count
    WHERE dc.full_retention_chain_local_count > 0
      AND sr.is_active = 1
      AND sr.serverops_backup_enabled = 1
)
SELECT 
    ft.server_name,
    ft.database_name,
    ft.backup_type,
    ft.file_name,
    ft.backup_finish_dttm,
    COALESCE(ft.compressed_size_bytes, ft.file_size_bytes) AS file_size_bytes,
    lc.cutoff_dttm,
    lc.chain_count
FROM ServerOps.Backup_FileTracking ft
JOIN LocalCutoffs lc ON ft.server_name = lc.server_name AND ft.database_name = lc.database_name
WHERE ft.network_copy_status IN ('COMPLETED', 'HISTORICAL')
  AND ft.local_deleted_dttm IS NULL
  AND ft.local_path IS NOT NULL
  AND lc.cutoff_dttm IS NOT NULL
  AND ft.backup_finish_dttm < lc.cutoff_dttm
ORDER BY ft.server_name, ft.database_name, ft.backup_finish_dttm DESC
"@
        }
        else {
            $query = @"
;WITH NetworkFullRanked AS (
    SELECT 
        server_name,
        database_name,
        backup_finish_dttm,
        ROW_NUMBER() OVER (
            PARTITION BY server_name, database_name 
            ORDER BY backup_finish_dttm DESC
        ) AS rn
    FROM ServerOps.Backup_FileTracking
    WHERE backup_type = 'FULL'
      AND network_deleted_dttm IS NULL
      AND network_path IS NOT NULL
),
NetworkCutoffs AS (
    SELECT 
        dc.server_name,
        dc.database_name,
        dc.full_retention_chain_network_count AS chain_count,
        nfr.backup_finish_dttm AS cutoff_dttm
    FROM ServerOps.Backup_DatabaseConfig dc
    JOIN dbo.ServerRegistry sr ON dc.server_name = sr.server_name
    LEFT JOIN NetworkFullRanked nfr 
        ON dc.server_name = nfr.server_name 
        AND dc.database_name = nfr.database_name
        AND nfr.rn = dc.full_retention_chain_network_count
    WHERE dc.full_retention_chain_network_count > 0
      AND sr.is_active = 1
      AND sr.serverops_backup_enabled = 1
)
SELECT 
    ft.server_name,
    ft.database_name,
    ft.backup_type,
    ft.file_name,
    ft.backup_finish_dttm,
    COALESCE(ft.compressed_size_bytes, ft.file_size_bytes) AS file_size_bytes,
    nc.cutoff_dttm,
    nc.chain_count
FROM ServerOps.Backup_FileTracking ft
JOIN NetworkCutoffs nc ON ft.server_name = nc.server_name AND ft.database_name = nc.database_name
WHERE ft.network_deleted_dttm IS NULL
  AND ft.network_path IS NOT NULL
  AND nc.cutoff_dttm IS NOT NULL
  AND ft.backup_finish_dttm < nc.cutoff_dttm
ORDER BY ft.server_name, ft.database_name, ft.backup_finish_dttm DESC
"@
        }
        
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $query
        $cmd.CommandTimeout = 30
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        $conn.Close()
        
        $files = @()
        foreach ($row in $dataset.Tables[0].Rows) {
            $files += [PSCustomObject]@{
                server_name      = $row['server_name']
                database_name    = $row['database_name']
                backup_type      = $row['backup_type']
                file_name        = $row['file_name']
                backup_finish_dttm = ([DateTime]$row['backup_finish_dttm']).ToString("yyyy-MM-dd HH:mm:ss")
                file_size_bytes  = if ($row['file_size_bytes'] -is [DBNull]) { 0 } else { [long]$row['file_size_bytes'] }
                cutoff_dttm      = ([DateTime]$row['cutoff_dttm']).ToString("yyyy-MM-dd HH:mm:ss")
                chain_count      = [int]$row['chain_count']
            }
        }
        
        Write-PodeJsonResponse -Value @{
            type = $type
            files = $files
            total_count = $files.Count
            total_bytes = ($files | Measure-Object -Property file_size_bytes -Sum).Sum
            timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ error = $_.Exception.Message }) -StatusCode 500
    }
}

# NOTE: The legacy /api/backup/engine-status endpoint was removed during the
# Refresh Architecture migration. Engine indicators are now driven by the shared
# WebSocket-based engine-events system (engine-events.js) via /api/engine/state.
# See: RealTime_Engine_Events_Architecture.md
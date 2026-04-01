# ============================================================================
# xFACts Control Center - File Monitoring API
# Location: E:\xFACts-ControlCenter\scripts\routes\FileMonitoring-API.ps1
# 
# API endpoints for File Monitoring data and configuration management.
# Version: Tracked in dbo.System_Metadata (component: FileOps)
# ============================================================================

# ----------------------------------------------------------------------------
# GET /api/fileops/servers
# Returns list of configured SFTP servers for dropdown
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Get -Path '/api/fileops/servers' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Connect Timeout=5;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        
        $query = @"
            SELECT 
                server_id AS ServerId,
                server_name AS ServerName,
                sftp_host AS SftpHost,
                sftp_port AS SftpPort,
                is_enabled AS IsEnabled
            FROM FileOps.ServerConfig
            WHERE is_enabled = 1
            ORDER BY server_name
"@
        
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $query
        $cmd.CommandTimeout = 10
        
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        
        $result = @()
        foreach ($row in $dataset.Tables[0].Rows) {
            $result += [PSCustomObject]@{
                ServerId = [int]$row['ServerId']
                ServerName = $row['ServerName']
                SftpHost = $row['SftpHost']
                SftpPort = [int]$row['SftpPort']
                IsEnabled = [bool]$row['IsEnabled']
            }
        }
        
        $conn.Close()
        Write-PodeJsonResponse -Value $result
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ----------------------------------------------------------------------------
# GET /api/fileops/status
# Returns current monitor status for all active monitors
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Get -Path '/api/fileops/status' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Connect Timeout=5;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        
        $query = @"
            SELECT 
                ms.status_id AS StatusId,
                ms.config_id AS ConfigId,
                ms.config_name AS ConfigName,
                ms.sftp_path AS SftpPath,
                ms.last_status AS LastStatus,
                ms.last_scanned_dttm AS LastScannedDttm,
                ms.file_detected_name AS FileDetectedName,
                ms.file_detected_dttm AS FileDetectedDttm,
                ms.escalated_dttm AS EscalatedDttm,
                mc.check_start_time AS CheckStartTime,
                mc.escalation_time AS EscalationTime,
                mc.check_end_time AS CheckEndTime
            FROM FileOps.MonitorStatus ms
            INNER JOIN FileOps.MonitorConfig mc ON ms.config_id = mc.config_id
            WHERE mc.is_enabled = 1
            ORDER BY 
                CASE ms.last_status 
                    WHEN 'Escalated' THEN 1 
                    WHEN 'Monitoring' THEN 2 
                    WHEN 'Detected' THEN 3 
                    ELSE 4 
                END,
                ms.config_name
"@
        
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $query
        $cmd.CommandTimeout = 10
        
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        
        $result = @()
        foreach ($row in $dataset.Tables[0].Rows) {
            $result += [PSCustomObject]@{
                StatusId = [int]$row['StatusId']
                ConfigId = [int]$row['ConfigId']
                ConfigName = $row['ConfigName']
                SftpPath = $row['SftpPath']
                LastStatus = $row['LastStatus']
                LastScannedDttm = if ($row['LastScannedDttm'] -is [DBNull]) { $null } else { $row['LastScannedDttm'].ToString("yyyy-MM-dd HH:mm:ss") }
                FileDetectedName = if ($row['FileDetectedName'] -is [DBNull]) { $null } else { $row['FileDetectedName'] }
                FileDetectedDttm = if ($row['FileDetectedDttm'] -is [DBNull]) { $null } else { $row['FileDetectedDttm'].ToString("yyyy-MM-dd HH:mm:ss") }
                EscalatedDttm = if ($row['EscalatedDttm'] -is [DBNull]) { $null } else { $row['EscalatedDttm'].ToString("yyyy-MM-dd HH:mm:ss") }
                CheckStartTime = $row['CheckStartTime'].ToString()
                EscalationTime = $row['EscalationTime'].ToString()
                CheckEndTime = $row['CheckEndTime'].ToString()
            }
        }
        
        $conn.Close()
        Write-PodeJsonResponse -Value $result
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ----------------------------------------------------------------------------
# GET /api/fileops/scheduled
# Returns active monitors scheduled for today that are NOT yet in their
# check window (start time is in the future). Used by the "Scheduled" modal.
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Get -Path '/api/fileops/scheduled' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Connect Timeout=5;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        
        $query = @"
            DECLARE @CurrentTime TIME = CAST(GETDATE() AS TIME);
            DECLARE @DayOfWeek INT = DATEPART(WEEKDAY, GETDATE());

            SELECT 
                mc.config_id AS ConfigId,
                mc.config_name AS ConfigName,
                mc.sftp_path AS SftpPath,
                mc.file_pattern AS FilePattern,
                mc.check_start_time AS CheckStartTime,
                mc.check_end_time AS CheckEndTime,
                mc.escalation_time AS EscalationTime,
                sc.server_name AS ServerName
            FROM FileOps.MonitorConfig mc
            INNER JOIN FileOps.ServerConfig sc ON mc.server_id = sc.server_id
            WHERE mc.is_enabled = 1
              AND sc.is_enabled = 1
              AND @CurrentTime < mc.check_start_time
              AND (
                (@DayOfWeek = 1 AND mc.check_sunday = 1) OR
                (@DayOfWeek = 2 AND mc.check_monday = 1) OR
                (@DayOfWeek = 3 AND mc.check_tuesday = 1) OR
                (@DayOfWeek = 4 AND mc.check_wednesday = 1) OR
                (@DayOfWeek = 5 AND mc.check_thursday = 1) OR
                (@DayOfWeek = 6 AND mc.check_friday = 1) OR
                (@DayOfWeek = 7 AND mc.check_saturday = 1)
              )
            ORDER BY mc.check_start_time ASC
"@
        
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $query
        $cmd.CommandTimeout = 10
        
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        
        $result = @()
        foreach ($row in $dataset.Tables[0].Rows) {
            $result += [PSCustomObject]@{
                ConfigId       = [int]$row['ConfigId']
                ConfigName     = $row['ConfigName']
                SftpPath       = $row['SftpPath']
                FilePattern    = $row['FilePattern']
                CheckStartTime = $row['CheckStartTime'].ToString()
                CheckEndTime   = $row['CheckEndTime'].ToString()
                EscalationTime = $row['EscalationTime'].ToString()
                ServerName     = $row['ServerName']
            }
        }
        
        $conn.Close()
        Write-PodeJsonResponse -Value $result
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ----------------------------------------------------------------------------
# GET /api/fileops/configs
# Returns all monitor configurations
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Get -Path '/api/fileops/configs' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Connect Timeout=5;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        
        $query = @"
            SELECT 
                mc.config_id AS ConfigId,
                mc.server_id AS ServerId,
                sc.server_name AS ServerName,
                mc.config_name AS ConfigName,
                mc.sftp_path AS SftpPath,
                mc.file_pattern AS FilePattern,
                mc.check_start_time AS CheckStartTime,
                mc.check_end_time AS CheckEndTime,
                mc.escalation_time AS EscalationTime,
                mc.check_sunday AS CheckSunday,
                mc.check_monday AS CheckMonday,
                mc.check_tuesday AS CheckTuesday,
                mc.check_wednesday AS CheckWednesday,
                mc.check_thursday AS CheckThursday,
                mc.check_friday AS CheckFriday,
                mc.check_saturday AS CheckSaturday,
                mc.check_holidays AS CheckHolidays,
                mc.notify_on_detection AS NotifyOnDetection,
                mc.notify_on_escalation AS NotifyOnEscalation,
                mc.create_jira_on_escalation AS CreateJiraOnEscalation,
                mc.default_priority AS DefaultPriority,
                mc.is_enabled AS IsEnabled,
                mc.created_dttm AS CreatedDttm,
                mc.modified_dttm AS ModifiedDttm
            FROM FileOps.MonitorConfig mc
            INNER JOIN FileOps.ServerConfig sc ON mc.server_id = sc.server_id
            ORDER BY mc.is_enabled DESC, mc.config_name
"@
        
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $query
        $cmd.CommandTimeout = 10
        
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        
        $result = @()
        foreach ($row in $dataset.Tables[0].Rows) {
            $result += [PSCustomObject]@{
                ConfigId = [int]$row['ConfigId']
                ServerId = [int]$row['ServerId']
                ServerName = $row['ServerName']
                ConfigName = $row['ConfigName']
                SftpPath = $row['SftpPath']
                FilePattern = $row['FilePattern']
                CheckStartTime = $row['CheckStartTime'].ToString()
                CheckEndTime = $row['CheckEndTime'].ToString()
                EscalationTime = $row['EscalationTime'].ToString()
                CheckSunday = [bool]$row['CheckSunday']
                CheckMonday = [bool]$row['CheckMonday']
                CheckTuesday = [bool]$row['CheckTuesday']
                CheckWednesday = [bool]$row['CheckWednesday']
                CheckThursday = [bool]$row['CheckThursday']
                CheckFriday = [bool]$row['CheckFriday']
                CheckSaturday = [bool]$row['CheckSaturday']
                CheckHolidays = [bool]$row['CheckHolidays']
                NotifyOnDetection = [bool]$row['NotifyOnDetection']
                NotifyOnEscalation = [bool]$row['NotifyOnEscalation']
                CreateJiraOnEscalation = [bool]$row['CreateJiraOnEscalation']
                DefaultPriority = $row['DefaultPriority']
                IsEnabled = [bool]$row['IsEnabled']
                CreatedDttm = $row['CreatedDttm'].ToString("yyyy-MM-dd HH:mm:ss")
                ModifiedDttm = if ($row['ModifiedDttm'] -is [DBNull]) { $null } else { $row['ModifiedDttm'].ToString("yyyy-MM-dd HH:mm:ss") }
            }
        }
        
        $conn.Close()
        Write-PodeJsonResponse -Value $result
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ----------------------------------------------------------------------------
# GET /api/fileops/config/:id
# Returns a single configuration by ID
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Get -Path '/api/fileops/config/:id' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $configId = [int]$WebEvent.Parameters['id']
        
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Connect Timeout=5;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        
        $query = @"
            SELECT 
                mc.config_id AS ConfigId,
                mc.server_id AS ServerId,
                sc.server_name AS ServerName,
                mc.config_name AS ConfigName,
                mc.sftp_path AS SftpPath,
                mc.file_pattern AS FilePattern,
                mc.check_start_time AS CheckStartTime,
                mc.check_end_time AS CheckEndTime,
                mc.escalation_time AS EscalationTime,
                mc.check_sunday AS CheckSunday,
                mc.check_monday AS CheckMonday,
                mc.check_tuesday AS CheckTuesday,
                mc.check_wednesday AS CheckWednesday,
                mc.check_thursday AS CheckThursday,
                mc.check_friday AS CheckFriday,
                mc.check_saturday AS CheckSaturday,
                mc.check_holidays AS CheckHolidays,
                mc.notify_on_detection AS NotifyOnDetection,
                mc.notify_on_escalation AS NotifyOnEscalation,
                mc.create_jira_on_escalation AS CreateJiraOnEscalation,
                mc.default_priority AS DefaultPriority,
                mc.is_enabled AS IsEnabled
            FROM FileOps.MonitorConfig mc
            INNER JOIN FileOps.ServerConfig sc ON mc.server_id = sc.server_id
            WHERE mc.config_id = @ConfigId
"@
        
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $query
        $cmd.CommandTimeout = 10
        $cmd.Parameters.AddWithValue("@ConfigId", $configId) | Out-Null
        
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        
        if ($dataset.Tables[0].Rows.Count -eq 0) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Configuration not found" }) -StatusCode 404
            return
        }
        
        $row = $dataset.Tables[0].Rows[0]
        $result = [PSCustomObject]@{
            ConfigId = [int]$row['ConfigId']
            ServerId = [int]$row['ServerId']
            ServerName = $row['ServerName']
            ConfigName = $row['ConfigName']
            SftpPath = $row['SftpPath']
            FilePattern = $row['FilePattern']
            CheckStartTime = $row['CheckStartTime'].ToString()
            CheckEndTime = $row['CheckEndTime'].ToString()
            EscalationTime = $row['EscalationTime'].ToString()
            CheckSunday = [bool]$row['CheckSunday']
            CheckMonday = [bool]$row['CheckMonday']
            CheckTuesday = [bool]$row['CheckTuesday']
            CheckWednesday = [bool]$row['CheckWednesday']
            CheckThursday = [bool]$row['CheckThursday']
            CheckFriday = [bool]$row['CheckFriday']
            CheckSaturday = [bool]$row['CheckSaturday']
            CheckHolidays = [bool]$row['CheckHolidays']
            NotifyOnDetection = [bool]$row['NotifyOnDetection']
            NotifyOnEscalation = [bool]$row['NotifyOnEscalation']
            CreateJiraOnEscalation = [bool]$row['CreateJiraOnEscalation']
            DefaultPriority = $row['DefaultPriority']
            IsEnabled = [bool]$row['IsEnabled']
        }
        
        $conn.Close()
        Write-PodeJsonResponse -Value $result
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ----------------------------------------------------------------------------
# GET /api/fileops/history
# Returns monitor log history (detection and escalation events)
# Query params: limit (default 50)
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Get -Path '/api/fileops/history' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $limit = $WebEvent.Query['limit']
        if (-not $limit) { $limit = 50 }
        $limit = [Math]::Min([int]$limit, 500)
        
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Connect Timeout=5;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        
        $query = @"
            SELECT TOP (@Limit)
                log_id AS LogId,
                config_id AS ConfigId,
                config_name AS ConfigName,
                sftp_path AS SftpPath,
                log_date AS LogDate,
                event_type AS EventType,
                file_detected_name AS FileDetectedName,
                event_dttm AS EventDttm,
                teams_alert_queued AS TeamsAlertQueued,
                jira_ticket_queued AS JiraTicketQueued,
                created_dttm AS CreatedDttm
            FROM FileOps.MonitorLog
            ORDER BY event_dttm DESC
"@
        
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $query
        $cmd.CommandTimeout = 10
        $cmd.Parameters.AddWithValue("@Limit", $limit) | Out-Null
        
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        
        $result = @()
        foreach ($row in $dataset.Tables[0].Rows) {
            $result += [PSCustomObject]@{
                LogId = [int]$row['LogId']
                ConfigId = [int]$row['ConfigId']
                ConfigName = $row['ConfigName']
                SftpPath = $row['SftpPath']
                LogDate = $row['LogDate'].ToString("yyyy-MM-dd")
                EventType = $row['EventType']
                FileDetectedName = if ($row['FileDetectedName'] -is [DBNull]) { $null } else { $row['FileDetectedName'] }
                EventDttm = $row['EventDttm'].ToString("yyyy-MM-dd HH:mm:ss")
                TeamsAlertQueued = [bool]$row['TeamsAlertQueued']
                JiraTicketQueued = [bool]$row['JiraTicketQueued']
                CreatedDttm = $row['CreatedDttm'].ToString("yyyy-MM-dd HH:mm:ss")
            }
        }
        
        $conn.Close()
        Write-PodeJsonResponse -Value $result
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ----------------------------------------------------------------------------
# POST /api/fileops/config/save
# Creates or updates a monitor configuration and manages alert subscription
#
# Subscription logic:
# - If webhook selected + any notification checkbox checked:
#   -> Upsert subscription with trigger_type = config_name, alert_category = NULL
# - If both notification checkboxes unchecked:
#   -> Deactivate existing subscription (if any)
# - If config_name changed on update:
#   -> Update trigger_type on existing subscription to match new name
# - If reactivating an inactive subscription:
#   -> Set is_active = 1
#
# Body includes: WebhookConfigId (nullable), DeactivateSubscription (bool),
#   ReactivateSubscription (bool) - these flags are set by the JS after
#   user confirmation dialogs
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Post -Path '/api/fileops/config/save' -Authentication 'ADLogin' -ScriptBlock {
        if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
        try {
        $body = $WebEvent.Data
        
        # Get current user for audit
        $currentUser = $WebEvent.Auth.User.Name
        if ([string]::IsNullOrEmpty($currentUser)) {
            $currentUser = $WebEvent.Auth.User.Username
        }
        if ([string]::IsNullOrEmpty($currentUser)) {
            $currentUser = "Unknown"
        }
        
        # Validate required fields
        if ([string]::IsNullOrWhiteSpace($body.ConfigName)) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Monitor name is required" }) -StatusCode 400
            return
        }
        if ([string]::IsNullOrWhiteSpace($body.SftpPath)) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "SFTP path is required" }) -StatusCode 400
            return
        }
        if ([string]::IsNullOrWhiteSpace($body.FilePattern)) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "File pattern is required" }) -StatusCode 400
            return
        }
        
        # Validate at least one day is selected
        $anyDay = $body.CheckSunday -or $body.CheckMonday -or $body.CheckTuesday -or 
                  $body.CheckWednesday -or $body.CheckThursday -or $body.CheckFriday -or $body.CheckSaturday
        if (-not $anyDay) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "At least one day must be selected" }) -StatusCode 400
            return
        }
   
           # Validate unique config name
        $dupCheckConn = New-Object System.Data.SqlClient.SqlConnection("Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Connect Timeout=5;")
        $dupCheckConn.Open()
        $dupQuery = "SELECT config_id FROM FileOps.MonitorConfig WHERE config_name = @Name"
        $dupCmd = $dupCheckConn.CreateCommand()
        $dupCmd.CommandText = $dupQuery
        $dupCmd.CommandTimeout = 10
        $dupCmd.Parameters.AddWithValue("@Name", $body.ConfigName) | Out-Null
        $dupResult = $dupCmd.ExecuteScalar()
        $dupCheckConn.Close()
        
        if ($null -ne $dupResult) {
            $existingId = [int]$dupResult
            $isUpdate = $null -ne $body.ConfigId -and $body.ConfigId -gt 0
            if (-not $isUpdate -or $existingId -ne [int]$body.ConfigId) {
                Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "A monitor named '$($body.ConfigName)' already exists (config_id: $existingId)" }) -StatusCode 400
                return
            }
        }
        
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Connect Timeout=5;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        
        $isUpdate = $null -ne $body.ConfigId -and $body.ConfigId -gt 0
        
        # ----------------------------------------------------------------
        # Step 1: Get the old config_name if this is an update (for trigger_type rename)
        # ----------------------------------------------------------------
        $oldConfigName = $null
        if ($isUpdate) {
            $nameQuery = "SELECT config_name FROM FileOps.MonitorConfig WHERE config_id = @ConfigId"
            $nameCmd = $conn.CreateCommand()
            $nameCmd.CommandText = $nameQuery
            $nameCmd.CommandTimeout = 10
            $nameCmd.Parameters.AddWithValue("@ConfigId", [int]$body.ConfigId) | Out-Null
            $oldConfigName = $nameCmd.ExecuteScalar()
        }
        
        # ----------------------------------------------------------------
        # Step 2: Save the MonitorConfig (INSERT or UPDATE)
        # ----------------------------------------------------------------
        if ($isUpdate) {
            $query = @"
                UPDATE FileOps.MonitorConfig
                SET server_id = @ServerId,
                    config_name = @ConfigName,
                    sftp_path = @SftpPath,
                    file_pattern = @FilePattern,
                    check_start_time = @CheckStartTime,
                    check_end_time = @CheckEndTime,
                    escalation_time = @EscalationTime,
                    check_sunday = @CheckSunday,
                    check_monday = @CheckMonday,
                    check_tuesday = @CheckTuesday,
                    check_wednesday = @CheckWednesday,
                    check_thursday = @CheckThursday,
                    check_friday = @CheckFriday,
                    check_saturday = @CheckSaturday,
                    notify_on_detection = @NotifyOnDetection,
                    notify_on_escalation = @NotifyOnEscalation,
                    create_jira_on_escalation = @CreateJiraOnEscalation,
                    default_priority = @DefaultPriority,
                    is_enabled = @IsEnabled,
                    modified_dttm = GETDATE()
                WHERE config_id = @ConfigId;
                
                SELECT @ConfigId AS ConfigId;
"@
        }
        else {
            $query = @"
                INSERT INTO FileOps.MonitorConfig (
                    server_id, config_name, sftp_path, file_pattern,
                    check_start_time, check_end_time, escalation_time,
                    check_sunday, check_monday, check_tuesday, check_wednesday,
                    check_thursday, check_friday, check_saturday,
                    notify_on_detection, notify_on_escalation, create_jira_on_escalation,
                    default_priority, is_enabled
                )
                VALUES (
                    @ServerId, @ConfigName, @SftpPath, @FilePattern,
                    @CheckStartTime, @CheckEndTime, @EscalationTime,
                    @CheckSunday, @CheckMonday, @CheckTuesday, @CheckWednesday,
                    @CheckThursday, @CheckFriday, @CheckSaturday,
                    @NotifyOnDetection, @NotifyOnEscalation, @CreateJiraOnEscalation,
                    @DefaultPriority, @IsEnabled
                );
                
                SELECT SCOPE_IDENTITY() AS ConfigId;
"@
        }
        
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $query
        $cmd.CommandTimeout = 10
        
        if ($isUpdate) {
            $cmd.Parameters.AddWithValue("@ConfigId", [int]$body.ConfigId) | Out-Null
        }
        $cmd.Parameters.AddWithValue("@ServerId", [int]$body.ServerId) | Out-Null
        $cmd.Parameters.AddWithValue("@ConfigName", $body.ConfigName) | Out-Null
        $cmd.Parameters.AddWithValue("@SftpPath", $body.SftpPath) | Out-Null
        $cmd.Parameters.AddWithValue("@FilePattern", $body.FilePattern) | Out-Null
        $cmd.Parameters.AddWithValue("@CheckStartTime", $body.CheckStartTime) | Out-Null
        $cmd.Parameters.AddWithValue("@CheckEndTime", $body.CheckEndTime) | Out-Null
        $cmd.Parameters.AddWithValue("@EscalationTime", $body.EscalationTime) | Out-Null
        $cmd.Parameters.AddWithValue("@CheckSunday", [bool]$body.CheckSunday) | Out-Null
        $cmd.Parameters.AddWithValue("@CheckMonday", [bool]$body.CheckMonday) | Out-Null
        $cmd.Parameters.AddWithValue("@CheckTuesday", [bool]$body.CheckTuesday) | Out-Null
        $cmd.Parameters.AddWithValue("@CheckWednesday", [bool]$body.CheckWednesday) | Out-Null
        $cmd.Parameters.AddWithValue("@CheckThursday", [bool]$body.CheckThursday) | Out-Null
        $cmd.Parameters.AddWithValue("@CheckFriday", [bool]$body.CheckFriday) | Out-Null
        $cmd.Parameters.AddWithValue("@CheckSaturday", [bool]$body.CheckSaturday) | Out-Null
        $cmd.Parameters.AddWithValue("@NotifyOnDetection", [bool]$body.NotifyOnDetection) | Out-Null
        $cmd.Parameters.AddWithValue("@NotifyOnEscalation", [bool]$body.NotifyOnEscalation) | Out-Null
        $cmd.Parameters.AddWithValue("@CreateJiraOnEscalation", [bool]$body.CreateJiraOnEscalation) | Out-Null
        $cmd.Parameters.AddWithValue("@DefaultPriority", $body.DefaultPriority) | Out-Null
        $cmd.Parameters.AddWithValue("@IsEnabled", [bool]$body.IsEnabled) | Out-Null
        
        $resultId = $cmd.ExecuteScalar()
        $savedConfigId = [int]$resultId
        
        # ----------------------------------------------------------------
        # Step 3: Handle subscription management
        # ----------------------------------------------------------------
        $subscriptionAction = "None"
        $newConfigName = $body.ConfigName
        $webhookConfigId = $body.WebhookConfigId
        $hasAnyNotification = [bool]$body.NotifyOnDetection -or [bool]$body.NotifyOnEscalation
        $deactivateRequested = [bool]$body.DeactivateSubscription
        $reactivateRequested = [bool]$body.ReactivateSubscription
        
        # Determine the trigger_type to search for (old name for updates, new name for inserts)
        $searchTriggerType = if ($isUpdate -and $oldConfigName) { $oldConfigName } else { $newConfigName }
        
        # Look for existing subscription
        $subQuery = @"
            SELECT subscription_id, config_id, is_active, trigger_type
            FROM Teams.WebhookSubscription
            WHERE source_module = 'FileOps'
              AND trigger_type = @TriggerType
"@
        $subCmd = $conn.CreateCommand()
        $subCmd.CommandText = $subQuery
        $subCmd.CommandTimeout = 10
        $subCmd.Parameters.AddWithValue("@TriggerType", $searchTriggerType) | Out-Null
        
        $subAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($subCmd)
        $subDataset = New-Object System.Data.DataSet
        $subAdapter.Fill($subDataset) | Out-Null
        
        $existingSub = $null
        if ($subDataset.Tables[0].Rows.Count -gt 0) {
            $subRow = $subDataset.Tables[0].Rows[0]
            $existingSub = @{
                SubscriptionId = [int]$subRow['subscription_id']
                ConfigId = [int]$subRow['config_id']
                IsActive = [bool]$subRow['is_active']
                TriggerType = $subRow['trigger_type']
            }
        }
        
        if ($webhookConfigId -and $webhookConfigId -gt 0 -and $hasAnyNotification) {
            # Webhook selected + at least one notification checkbox checked
            
            if ($existingSub) {
                # Existing subscription found - update it
                $updateFields = @(
                    "config_id = @NewWebhookConfigId"
                    "trigger_type = @NewTriggerType"
                    "modified_dttm = GETDATE()"
                )
                
                if ($reactivateRequested -and -not $existingSub.IsActive) {
                    $updateFields += "is_active = 1"
                    $subscriptionAction = "Reactivated"
                } elseif ($existingSub.ConfigId -ne [int]$webhookConfigId) {
                    $subscriptionAction = "Updated"
                } elseif ($existingSub.TriggerType -ne $newConfigName) {
                    $subscriptionAction = "Renamed"
                } else {
                    $subscriptionAction = "Unchanged"
                }
                
                $updateQuery = @"
                    UPDATE Teams.WebhookSubscription
                    SET $($updateFields -join ', ')
                    WHERE subscription_id = @SubId
"@
                $updateCmd = $conn.CreateCommand()
                $updateCmd.CommandText = $updateQuery
                $updateCmd.CommandTimeout = 10
                $updateCmd.Parameters.AddWithValue("@SubId", $existingSub.SubscriptionId) | Out-Null
                $updateCmd.Parameters.AddWithValue("@NewWebhookConfigId", [int]$webhookConfigId) | Out-Null
                $updateCmd.Parameters.AddWithValue("@NewTriggerType", $newConfigName) | Out-Null
                $updateCmd.ExecuteNonQuery() | Out-Null
                
            } else {
                # No existing subscription - create one
                $insertQuery = @"
                    INSERT INTO Teams.WebhookSubscription (
                        config_id, channel_name, source_module,
                        alert_category, trigger_type, is_active, description
                    )
                    SELECT 
                        @WebhookConfigId,
                        w.webhook_name,
                        'FileOps',
                        NULL,
                        @TriggerType,
                        1,
                        'Auto-created by File Monitoring configuration'
                    FROM Teams.WebhookConfig w
                    WHERE w.config_id = @WebhookConfigId;
"@
                $insertCmd = $conn.CreateCommand()
                $insertCmd.CommandText = $insertQuery
                $insertCmd.CommandTimeout = 10
                $insertCmd.Parameters.AddWithValue("@WebhookConfigId", [int]$webhookConfigId) | Out-Null
                $insertCmd.Parameters.AddWithValue("@TriggerType", $newConfigName) | Out-Null
                $insertCmd.ExecuteNonQuery() | Out-Null
                
                $subscriptionAction = "Created"
            }
            
        } elseif ($deactivateRequested -and $existingSub -and $existingSub.IsActive) {
            # Both checkboxes unchecked and user confirmed deactivation
            $deactQuery = @"
                UPDATE Teams.WebhookSubscription
                SET is_active = 0,
                    modified_dttm = GETDATE()
                WHERE subscription_id = @SubId
"@
            $deactCmd = $conn.CreateCommand()
            $deactCmd.CommandText = $deactQuery
            $deactCmd.CommandTimeout = 10
            $deactCmd.Parameters.AddWithValue("@SubId", $existingSub.SubscriptionId) | Out-Null
            $deactCmd.ExecuteNonQuery() | Out-Null
            
            $subscriptionAction = "Deactivated"
            
        } elseif ($isUpdate -and $existingSub -and $oldConfigName -ne $newConfigName) {
            # Config name changed but no webhook/notification changes - still update trigger_type
            $renameQuery = @"
                UPDATE Teams.WebhookSubscription
                SET trigger_type = @NewTriggerType,
                    modified_dttm = GETDATE()
                WHERE subscription_id = @SubId
"@
            $renameCmd = $conn.CreateCommand()
            $renameCmd.CommandText = $renameQuery
            $renameCmd.CommandTimeout = 10
            $renameCmd.Parameters.AddWithValue("@SubId", $existingSub.SubscriptionId) | Out-Null
            $renameCmd.Parameters.AddWithValue("@NewTriggerType", $newConfigName) | Out-Null
            $renameCmd.ExecuteNonQuery() | Out-Null
            
            $subscriptionAction = "Renamed"
        }
        
        $conn.Close()
        
        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            Success = $true
            ConfigId = $savedConfigId
            Action = if ($isUpdate) { "Updated" } else { "Created" }
            SubscriptionAction = $subscriptionAction
            ModifiedBy = $currentUser
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ----------------------------------------------------------------------------
# POST /api/fileops/config/toggle
# Enables or disables a monitor configuration
# Body: { ConfigId, IsEnabled }
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Post -Path '/api/fileops/config/toggle' -Authentication 'ADLogin' -ScriptBlock {
        if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
        try {
        $body = $WebEvent.Data
        $configId = [int]$body.ConfigId
        $isEnabled = [bool]$body.IsEnabled
        
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Connect Timeout=5;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        
        $query = @"
            UPDATE FileOps.MonitorConfig
            SET is_enabled = @IsEnabled,
                modified_dttm = GETDATE()
            WHERE config_id = @ConfigId
"@
        
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $query
        $cmd.CommandTimeout = 10
        $cmd.Parameters.AddWithValue("@ConfigId", $configId) | Out-Null
        $cmd.Parameters.AddWithValue("@IsEnabled", $isEnabled) | Out-Null
        
        $rowsAffected = $cmd.ExecuteNonQuery()
        
        $conn.Close()
        
        if ($rowsAffected -eq 0) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Configuration not found" }) -StatusCode 404
            return
        }
        
        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            Success = $true
            ConfigId = $configId
            IsEnabled = $isEnabled
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ============================================================================
# WEBHOOK AND SUBSCRIPTION ENDPOINTS
# ============================================================================

# ----------------------------------------------------------------------------
# GET /api/fileops/webhooks
# Returns list of all webhook configurations
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Get -Path '/api/fileops/webhooks' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Connect Timeout=5;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        
        $query = @"
            SELECT 
                config_id AS ConfigId,
                webhook_name AS WebhookName,
                webhook_url AS WebhookUrl,
                alert_category AS AlertCategory,
                description AS Description,
                is_active AS IsActive
            FROM Teams.WebhookConfig
            WHERE is_active = 1
            ORDER BY webhook_name
"@
        
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $query
        $cmd.CommandTimeout = 10
        
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        
        $result = @()
        foreach ($row in $dataset.Tables[0].Rows) {
            $result += [PSCustomObject]@{
                ConfigId = [int]$row['ConfigId']
                WebhookName = $row['WebhookName']
                WebhookUrl = $row['WebhookUrl']
                AlertCategory = $row['AlertCategory']
                Description = if ($row['Description'] -is [DBNull]) { $null } else { $row['Description'] }
                IsActive = [bool]$row['IsActive']
            }
        }
        
        $conn.Close()
        Write-PodeJsonResponse -Value $result
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ----------------------------------------------------------------------------
# GET /api/fileops/subscriptions
# Returns FileOps webhook subscriptions (read-only display)
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Get -Path '/api/fileops/subscriptions' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Connect Timeout=5;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        
        $query = @"
            SELECT 
                s.subscription_id AS SubscriptionId,
                s.config_id AS ConfigId,
                w.webhook_name AS WebhookName,
                s.channel_name AS ChannelName,
                s.source_module AS SourceModule,
                s.alert_category AS AlertCategory,
                s.trigger_type AS TriggerType,
                s.is_active AS IsActive,
                s.description AS Description
            FROM Teams.WebhookSubscription s
            INNER JOIN Teams.WebhookConfig w ON s.config_id = w.config_id
            WHERE s.source_module = 'FileOps'
            ORDER BY s.is_active DESC, s.channel_name
"@
        
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $query
        $cmd.CommandTimeout = 10
        
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        
        $result = @()
        foreach ($row in $dataset.Tables[0].Rows) {
            $result += [PSCustomObject]@{
                SubscriptionId = [int]$row['SubscriptionId']
                ConfigId = [int]$row['ConfigId']
                WebhookName = $row['WebhookName']
                ChannelName = $row['ChannelName']
                SourceModule = $row['SourceModule']
                AlertCategory = if ($row['AlertCategory'] -is [DBNull]) { $null } else { $row['AlertCategory'] }
                TriggerType = if ($row['TriggerType'] -is [DBNull]) { $null } else { $row['TriggerType'] }
                IsActive = [bool]$row['IsActive']
                Description = if ($row['Description'] -is [DBNull]) { $null } else { $row['Description'] }
            }
        }
        
        $conn.Close()
        Write-PodeJsonResponse -Value $result
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ----------------------------------------------------------------------------
# GET /api/fileops/config/subscription
# Returns subscription info for a given config_name (trigger_type lookup)
# Query param: configName
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Get -Path '/api/fileops/config/subscription' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $configName = $WebEvent.Query['configName']
        
        if ([string]::IsNullOrWhiteSpace($configName)) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Found = $false })
            return
        }
        
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Connect Timeout=5;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        
        $query = @"
            SELECT 
                s.subscription_id AS SubscriptionId,
                s.config_id AS WebhookConfigId,
                w.webhook_name AS WebhookName,
                s.channel_name AS ChannelName,
                s.alert_category AS AlertCategory,
                s.trigger_type AS TriggerType,
                s.is_active AS IsActive
            FROM Teams.WebhookSubscription s
            INNER JOIN Teams.WebhookConfig w ON s.config_id = w.config_id
            WHERE s.source_module = 'FileOps'
              AND s.trigger_type = @ConfigName
"@
        
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $query
        $cmd.CommandTimeout = 10
        $cmd.Parameters.AddWithValue("@ConfigName", $configName) | Out-Null
        
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        
        if ($dataset.Tables[0].Rows.Count -eq 0) {
            $conn.Close()
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Found = $false })
            return
        }
        
        $row = $dataset.Tables[0].Rows[0]
        $result = [PSCustomObject]@{
            Found = $true
            SubscriptionId = [int]$row['SubscriptionId']
            WebhookConfigId = [int]$row['WebhookConfigId']
            WebhookName = $row['WebhookName']
            ChannelName = $row['ChannelName']
            AlertCategory = if ($row['AlertCategory'] -is [DBNull]) { $null } else { $row['AlertCategory'] }
            TriggerType = $row['TriggerType']
            IsActive = [bool]$row['IsActive']
        }
        
        $conn.Close()
        Write-PodeJsonResponse -Value $result
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ----------------------------------------------------------------------------
# POST /api/fileops/webhook/save
# Creates a new webhook configuration (used by inline creation in config modal)
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Post -Path '/api/fileops/webhook/save' -Authentication 'ADLogin' -ScriptBlock {
        if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
        try {
        $body = $WebEvent.Data
        
        if ([string]::IsNullOrWhiteSpace($body.WebhookName)) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Webhook name is required" }) -StatusCode 400
            return
        }
        if ([string]::IsNullOrWhiteSpace($body.WebhookUrl)) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Webhook URL is required" }) -StatusCode 400
            return
        }
        
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Connect Timeout=5;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        
        $query = @"
            INSERT INTO Teams.WebhookConfig (
                webhook_name, webhook_url, alert_category, description, is_active
            )
            VALUES (
                @WebhookName, @WebhookUrl, @AlertCategory, @Description, 1
            );
            
            SELECT SCOPE_IDENTITY() AS ConfigId;
"@
        
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $query
        $cmd.CommandTimeout = 10
        $cmd.Parameters.AddWithValue("@WebhookName", $body.WebhookName) | Out-Null
        $cmd.Parameters.AddWithValue("@WebhookUrl", $body.WebhookUrl) | Out-Null
        $cmd.Parameters.AddWithValue("@AlertCategory", $(if ($body.AlertCategory) { $body.AlertCategory } else { 'ALL' })) | Out-Null
        $descParam = if ([string]::IsNullOrWhiteSpace($body.Description)) { [DBNull]::Value } else { $body.Description }
        $cmd.Parameters.AddWithValue("@Description", $descParam) | Out-Null
        
        $resultId = $cmd.ExecuteScalar()
        
        $conn.Close()
        
        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            Success = $true
            ConfigId = [int]$resultId
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ----------------------------------------------------------------------------
# GET /api/fileops/engine-status
# Returns orchestrator process health for the FileOps scanner
# Driven entirely by ProcessRegistry - no module-specific status table needed
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Get -Path '/api/fileops/engine-status' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Connect Timeout=5;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        
        $query = @"
            SELECT
                p.process_id AS ProcessId,
                p.run_mode AS RunMode,
                p.interval_seconds AS IntervalSeconds,
                p.running_count AS RunningCount,
                p.last_execution_dttm AS LastExecutionDttm,
                p.last_execution_status AS LastExecutionStatus,
                p.last_duration_ms AS LastDurationMs,
                CASE
                    WHEN p.run_mode = 0 THEN NULL
                    WHEN p.run_mode = 2 THEN NULL
                    WHEN p.run_mode = 1 AND p.last_execution_dttm IS NOT NULL THEN
                        p.interval_seconds - DATEDIFF(SECOND, p.last_execution_dttm, GETDATE())
                    WHEN p.run_mode = 1 AND p.last_execution_dttm IS NULL THEN -1
                    ELSE NULL
                END AS SecondsUntilNext
            FROM Orchestrator.ProcessRegistry p
            WHERE p.module_name = 'FileOps'
              AND p.process_name = 'Scan-SFTPFiles'
"@
        
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $query
        $cmd.CommandTimeout = 10
        
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        
        if ($dataset.Tables[0].Rows.Count -eq 0) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Process not found in registry" }) -StatusCode 404
            return
        }
        
        $row = $dataset.Tables[0].Rows[0]
        $result = [PSCustomObject]@{
            ProcessId = [int]$row['ProcessId']
            RunMode = [int]$row['RunMode']
            IntervalSeconds = [int]$row['IntervalSeconds']
            RunningCount = [int]$row['RunningCount']
            LastExecutionDttm = if ($row['LastExecutionDttm'] -is [DBNull]) { $null } else { $row['LastExecutionDttm'].ToString("yyyy-MM-dd HH:mm:ss") }
            LastExecutionStatus = if ($row['LastExecutionStatus'] -is [DBNull]) { $null } else { $row['LastExecutionStatus'] }
            LastDurationMs = if ($row['LastDurationMs'] -is [DBNull]) { $null } else { [int]$row['LastDurationMs'] }
            SecondsUntilNext = if ($row['SecondsUntilNext'] -is [DBNull]) { $null } else { [int]$row['SecondsUntilNext'] }
        }
        
        $conn.Close()
        Write-PodeJsonResponse -Value $result
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}
<#
.SYNOPSIS
    Control Center API endpoints for File Monitoring.

.DESCRIPTION
    Registers the File Monitoring API endpoints backing the dashboard: SFTP
    server and monitor configuration reads, current monitor status, the daily
    scheduled-but-not-started list, detection history, configuration create
    and update with Teams subscription management, monitor enable and disable,
    and webhook configuration and subscription reads.

.COMPONENT
    FileOps

.NOTES
    File Name : FileMonitoring-API.ps1
    Location  : E:\xFACts-ControlCenter\scripts\routes\FileMonitoring-API.ps1

    FILE ORGANIZATION
    -----------------
    ROUTE: API ENDPOINTS
#>

<# ============================================================================
   ROUTE: API ENDPOINTS
   ----------------------------------------------------------------------------
   Registers all File Monitoring API endpoints. Each endpoint calls
   Test-ActionEndpoint as its first statement, accesses data through the
   shared Invoke-XFActsQuery / Invoke-XFActsNonQuery wrappers, and ends with
   Write-PodeJsonResponse.
   Prefix: (none)
   ============================================================================ #>

Add-PodeRoute -Method Get -Path '/api/fileops/servers' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        $rows = Invoke-XFActsQuery -Query @"
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

        $result = @()
        foreach ($row in $rows) {
            $result += [PSCustomObject]@{
                ServerId   = [int]$row['ServerId']
                ServerName = $row['ServerName']
                SftpHost   = $row['SftpHost']
                SftpPort   = [int]$row['SftpPort']
                IsEnabled  = [bool]$row['IsEnabled']
            }
        }

        Write-PodeJsonResponse -Value $result
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

Add-PodeRoute -Method Get -Path '/api/fileops/status' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        $rows = Invoke-XFActsQuery -Query @"
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

        $result = @()
        foreach ($row in $rows) {
            $result += [PSCustomObject]@{
                StatusId         = [int]$row['StatusId']
                ConfigId         = [int]$row['ConfigId']
                ConfigName       = $row['ConfigName']
                SftpPath         = $row['SftpPath']
                LastStatus       = $row['LastStatus']
                LastScannedDttm  = if ($row['LastScannedDttm'] -is [DBNull]) { $null } else { $row['LastScannedDttm'].ToString("yyyy-MM-dd HH:mm:ss") }
                FileDetectedName = if ($row['FileDetectedName'] -is [DBNull]) { $null } else { $row['FileDetectedName'] }
                FileDetectedDttm = if ($row['FileDetectedDttm'] -is [DBNull]) { $null } else { $row['FileDetectedDttm'].ToString("yyyy-MM-dd HH:mm:ss") }
                EscalatedDttm    = if ($row['EscalatedDttm'] -is [DBNull]) { $null } else { $row['EscalatedDttm'].ToString("yyyy-MM-dd HH:mm:ss") }
                CheckStartTime   = $row['CheckStartTime'].ToString()
                EscalationTime   = $row['EscalationTime'].ToString()
                CheckEndTime     = $row['CheckEndTime'].ToString()
            }
        }

        Write-PodeJsonResponse -Value $result
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

Add-PodeRoute -Method Get -Path '/api/fileops/scheduled' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        $currentTime = (Get-Date).ToString('HH:mm:ss')
        $dayOfWeek = [int](Get-Date).DayOfWeek + 1

        $rows = Invoke-XFActsQuery -Query @"
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
"@ -Parameters @{ CurrentTime = $currentTime; DayOfWeek = $dayOfWeek }

        $result = @()
        foreach ($row in $rows) {
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

        Write-PodeJsonResponse -Value $result
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

Add-PodeRoute -Method Get -Path '/api/fileops/configs' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        $rows = Invoke-XFActsQuery -Query @"
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

        $result = @()
        foreach ($row in $rows) {
            $result += [PSCustomObject]@{
                ConfigId               = [int]$row['ConfigId']
                ServerId               = [int]$row['ServerId']
                ServerName             = $row['ServerName']
                ConfigName             = $row['ConfigName']
                SftpPath               = $row['SftpPath']
                FilePattern            = $row['FilePattern']
                CheckStartTime         = $row['CheckStartTime'].ToString()
                CheckEndTime           = $row['CheckEndTime'].ToString()
                EscalationTime         = $row['EscalationTime'].ToString()
                CheckSunday            = [bool]$row['CheckSunday']
                CheckMonday            = [bool]$row['CheckMonday']
                CheckTuesday           = [bool]$row['CheckTuesday']
                CheckWednesday         = [bool]$row['CheckWednesday']
                CheckThursday          = [bool]$row['CheckThursday']
                CheckFriday            = [bool]$row['CheckFriday']
                CheckSaturday          = [bool]$row['CheckSaturday']
                CheckHolidays          = [bool]$row['CheckHolidays']
                NotifyOnDetection      = [bool]$row['NotifyOnDetection']
                NotifyOnEscalation     = [bool]$row['NotifyOnEscalation']
                CreateJiraOnEscalation = [bool]$row['CreateJiraOnEscalation']
                DefaultPriority        = $row['DefaultPriority']
                IsEnabled              = [bool]$row['IsEnabled']
                CreatedDttm            = $row['CreatedDttm'].ToString("yyyy-MM-dd HH:mm:ss")
                ModifiedDttm           = if ($row['ModifiedDttm'] -is [DBNull]) { $null } else { $row['ModifiedDttm'].ToString("yyyy-MM-dd HH:mm:ss") }
            }
        }

        Write-PodeJsonResponse -Value $result
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

Add-PodeRoute -Method Get -Path '/api/fileops/config/:id' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        $configId = [int]$WebEvent.Parameters['id']

        $rows = Invoke-XFActsQuery -Query @"
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
"@ -Parameters @{ ConfigId = $configId }

        if (-not $rows -or $rows.Count -eq 0) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Configuration not found" }) -StatusCode 404
            return
        }

        $row = $rows[0]
        $result = [PSCustomObject]@{
            ConfigId               = [int]$row['ConfigId']
            ServerId               = [int]$row['ServerId']
            ServerName             = $row['ServerName']
            ConfigName             = $row['ConfigName']
            SftpPath               = $row['SftpPath']
            FilePattern            = $row['FilePattern']
            CheckStartTime         = $row['CheckStartTime'].ToString()
            CheckEndTime           = $row['CheckEndTime'].ToString()
            EscalationTime         = $row['EscalationTime'].ToString()
            CheckSunday            = [bool]$row['CheckSunday']
            CheckMonday            = [bool]$row['CheckMonday']
            CheckTuesday           = [bool]$row['CheckTuesday']
            CheckWednesday         = [bool]$row['CheckWednesday']
            CheckThursday          = [bool]$row['CheckThursday']
            CheckFriday            = [bool]$row['CheckFriday']
            CheckSaturday          = [bool]$row['CheckSaturday']
            CheckHolidays          = [bool]$row['CheckHolidays']
            NotifyOnDetection      = [bool]$row['NotifyOnDetection']
            NotifyOnEscalation     = [bool]$row['NotifyOnEscalation']
            CreateJiraOnEscalation = [bool]$row['CreateJiraOnEscalation']
            DefaultPriority        = $row['DefaultPriority']
            IsEnabled              = [bool]$row['IsEnabled']
        }

        Write-PodeJsonResponse -Value $result
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

Add-PodeRoute -Method Get -Path '/api/fileops/history' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        $limit = $WebEvent.Query['limit']
        if (-not $limit) { $limit = 50 }
        $limit = [Math]::Min([int]$limit, 500)

        $rows = Invoke-XFActsQuery -Query @"
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
"@ -Parameters @{ Limit = $limit }

        $result = @()
        foreach ($row in $rows) {
            $result += [PSCustomObject]@{
                LogId            = [int]$row['LogId']
                ConfigId         = [int]$row['ConfigId']
                ConfigName       = $row['ConfigName']
                SftpPath         = $row['SftpPath']
                LogDate          = $row['LogDate'].ToString("yyyy-MM-dd")
                EventType        = $row['EventType']
                FileDetectedName = if ($row['FileDetectedName'] -is [DBNull]) { $null } else { $row['FileDetectedName'] }
                EventDttm        = $row['EventDttm'].ToString("yyyy-MM-dd HH:mm:ss")
                TeamsAlertQueued = [bool]$row['TeamsAlertQueued']
                JiraTicketQueued = [bool]$row['JiraTicketQueued']
                CreatedDttm      = $row['CreatedDttm'].ToString("yyyy-MM-dd HH:mm:ss")
            }
        }

        Write-PodeJsonResponse -Value $result
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

Add-PodeRoute -Method Post -Path '/api/fileops/config/save' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        $body = $WebEvent.Data

        $currentUser = $WebEvent.Auth.User.Username
        if ([string]::IsNullOrEmpty($currentUser)) {
            $currentUser = "Unknown"
        }

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

        $anyDay = $body.CheckSunday -or $body.CheckMonday -or $body.CheckTuesday -or
                  $body.CheckWednesday -or $body.CheckThursday -or $body.CheckFriday -or $body.CheckSaturday
        if (-not $anyDay) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "At least one day must be selected" }) -StatusCode 400
            return
        }

        $isUpdate = $null -ne $body.ConfigId -and $body.ConfigId -gt 0

        $dupRows = Invoke-XFActsQuery -Query @"
            SELECT config_id AS ConfigId
            FROM FileOps.MonitorConfig
            WHERE config_name = @Name
"@ -Parameters @{ Name = $body.ConfigName }

        if ($dupRows -and $dupRows.Count -gt 0) {
            $existingId = [int]$dupRows[0]['ConfigId']
            if (-not $isUpdate -or $existingId -ne [int]$body.ConfigId) {
                Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "A monitor named '$($body.ConfigName)' already exists (config_id: $existingId)" }) -StatusCode 400
                return
            }
        }

        $oldConfigName = $null
        if ($isUpdate) {
            $nameRows = Invoke-XFActsQuery -Query @"
                SELECT config_name AS ConfigName
                FROM FileOps.MonitorConfig
                WHERE config_id = @ConfigId
"@ -Parameters @{ ConfigId = [int]$body.ConfigId }
            if ($nameRows -and $nameRows.Count -gt 0) {
                $oldConfigName = $nameRows[0]['ConfigName']
            }
        }

        $saveParams = @{
            ServerId               = [int]$body.ServerId
            ConfigName             = $body.ConfigName
            SftpPath               = $body.SftpPath
            FilePattern            = $body.FilePattern
            CheckStartTime         = $body.CheckStartTime
            CheckEndTime           = $body.CheckEndTime
            EscalationTime         = $body.EscalationTime
            CheckSunday            = [bool]$body.CheckSunday
            CheckMonday            = [bool]$body.CheckMonday
            CheckTuesday           = [bool]$body.CheckTuesday
            CheckWednesday         = [bool]$body.CheckWednesday
            CheckThursday          = [bool]$body.CheckThursday
            CheckFriday            = [bool]$body.CheckFriday
            CheckSaturday          = [bool]$body.CheckSaturday
            NotifyOnDetection      = [bool]$body.NotifyOnDetection
            NotifyOnEscalation     = [bool]$body.NotifyOnEscalation
            CreateJiraOnEscalation = [bool]$body.CreateJiraOnEscalation
            DefaultPriority        = $body.DefaultPriority
            IsEnabled              = [bool]$body.IsEnabled
        }

        if ($isUpdate) {
            $saveParams['ConfigId'] = [int]$body.ConfigId
            $saveRows = Invoke-XFActsQuery -Query @"
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
"@ -Parameters $saveParams
        }
        else {
            $saveRows = Invoke-XFActsQuery -Query @"
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
"@ -Parameters $saveParams
        }

        $savedConfigId = [int]$saveRows[0]['ConfigId']

        $subscriptionAction = "None"
        $newConfigName = $body.ConfigName
        $webhookConfigId = $body.WebhookConfigId
        $hasAnyNotification = [bool]$body.NotifyOnDetection -or [bool]$body.NotifyOnEscalation
        $deactivateRequested = [bool]$body.DeactivateSubscription
        $reactivateRequested = [bool]$body.ReactivateSubscription

        $searchTriggerType = if ($isUpdate -and $oldConfigName) { $oldConfigName } else { $newConfigName }

        $subRows = Invoke-XFActsQuery -Query @"
            SELECT subscription_id AS SubscriptionId, config_id AS ConfigId,
                   is_active AS IsActive, trigger_type AS TriggerType
            FROM Teams.WebhookSubscription
            WHERE source_module = 'FileOps'
              AND trigger_type = @TriggerType
"@ -Parameters @{ TriggerType = $searchTriggerType }

        $existingSub = $null
        if ($subRows -and $subRows.Count -gt 0) {
            $subRow = $subRows[0]
            $existingSub = @{
                SubscriptionId = [int]$subRow['SubscriptionId']
                ConfigId       = [int]$subRow['ConfigId']
                IsActive       = [bool]$subRow['IsActive']
                TriggerType    = $subRow['TriggerType']
            }
        }

        if ($webhookConfigId -and $webhookConfigId -gt 0 -and $hasAnyNotification) {
            if ($existingSub) {
                $setReactivate = ''
                if ($reactivateRequested -and -not $existingSub.IsActive) {
                    $setReactivate = ', is_active = 1'
                    $subscriptionAction = "Reactivated"
                } elseif ($existingSub.ConfigId -ne [int]$webhookConfigId) {
                    $subscriptionAction = "Updated"
                } elseif ($existingSub.TriggerType -ne $newConfigName) {
                    $subscriptionAction = "Renamed"
                } else {
                    $subscriptionAction = "Unchanged"
                }

                Invoke-XFActsNonQuery -Query @"
                    UPDATE Teams.WebhookSubscription
                    SET config_id = @NewWebhookConfigId,
                        trigger_type = @NewTriggerType,
                        modified_dttm = GETDATE()$setReactivate
                    WHERE subscription_id = @SubId
"@ -Parameters @{
                    SubId              = $existingSub.SubscriptionId
                    NewWebhookConfigId = [int]$webhookConfigId
                    NewTriggerType     = $newConfigName
                } | Out-Null
            }
            else {
                Invoke-XFActsNonQuery -Query @"
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
"@ -Parameters @{
                    WebhookConfigId = [int]$webhookConfigId
                    TriggerType     = $newConfigName
                } | Out-Null

                $subscriptionAction = "Created"
            }
        }
        elseif ($deactivateRequested -and $existingSub -and $existingSub.IsActive) {
            Invoke-XFActsNonQuery -Query @"
                UPDATE Teams.WebhookSubscription
                SET is_active = 0,
                    modified_dttm = GETDATE()
                WHERE subscription_id = @SubId
"@ -Parameters @{ SubId = $existingSub.SubscriptionId } | Out-Null

            $subscriptionAction = "Deactivated"
        }
        elseif ($isUpdate -and $existingSub -and $oldConfigName -ne $newConfigName) {
            Invoke-XFActsNonQuery -Query @"
                UPDATE Teams.WebhookSubscription
                SET trigger_type = @NewTriggerType,
                    modified_dttm = GETDATE()
                WHERE subscription_id = @SubId
"@ -Parameters @{
                SubId          = $existingSub.SubscriptionId
                NewTriggerType = $newConfigName
            } | Out-Null

            $subscriptionAction = "Renamed"
        }

        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            Success            = $true
            ConfigId           = $savedConfigId
            Action             = if ($isUpdate) { "Updated" } else { "Created" }
            SubscriptionAction = $subscriptionAction
            ModifiedBy         = $currentUser
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

Add-PodeRoute -Method Post -Path '/api/fileops/config/toggle' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        $body = $WebEvent.Data
        $configId = [int]$body.ConfigId
        $isEnabled = [bool]$body.IsEnabled

        $rowsAffected = Invoke-XFActsNonQuery -Query @"
            UPDATE FileOps.MonitorConfig
            SET is_enabled = @IsEnabled,
                modified_dttm = GETDATE()
            WHERE config_id = @ConfigId
"@ -Parameters @{
            IsEnabled = $isEnabled
            ConfigId  = $configId
        }

        if ($rowsAffected -eq 0) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Configuration not found" }) -StatusCode 404
            return
        }

        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            Success   = $true
            ConfigId  = $configId
            IsEnabled = $isEnabled
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

Add-PodeRoute -Method Get -Path '/api/fileops/webhooks' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        $rows = Invoke-XFActsQuery -Query @"
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

        $result = @()
        foreach ($row in $rows) {
            $result += [PSCustomObject]@{
                ConfigId      = [int]$row['ConfigId']
                WebhookName   = $row['WebhookName']
                WebhookUrl    = $row['WebhookUrl']
                AlertCategory = $row['AlertCategory']
                Description   = if ($row['Description'] -is [DBNull]) { $null } else { $row['Description'] }
                IsActive      = [bool]$row['IsActive']
            }
        }

        Write-PodeJsonResponse -Value $result
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

Add-PodeRoute -Method Get -Path '/api/fileops/subscriptions' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        $rows = Invoke-XFActsQuery -Query @"
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

        $result = @()
        foreach ($row in $rows) {
            $result += [PSCustomObject]@{
                SubscriptionId = [int]$row['SubscriptionId']
                ConfigId       = [int]$row['ConfigId']
                WebhookName    = $row['WebhookName']
                ChannelName    = $row['ChannelName']
                SourceModule   = $row['SourceModule']
                AlertCategory  = if ($row['AlertCategory'] -is [DBNull]) { $null } else { $row['AlertCategory'] }
                TriggerType    = if ($row['TriggerType'] -is [DBNull]) { $null } else { $row['TriggerType'] }
                IsActive       = [bool]$row['IsActive']
                Description    = if ($row['Description'] -is [DBNull]) { $null } else { $row['Description'] }
            }
        }

        Write-PodeJsonResponse -Value $result
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

Add-PodeRoute -Method Get -Path '/api/fileops/config/subscription' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        $configName = $WebEvent.Query['configName']

        if ([string]::IsNullOrWhiteSpace($configName)) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Found = $false })
            return
        }

        $rows = Invoke-XFActsQuery -Query @"
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
"@ -Parameters @{ ConfigName = $configName }

        if (-not $rows -or $rows.Count -eq 0) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Found = $false })
            return
        }

        $row = $rows[0]
        $result = [PSCustomObject]@{
            Found           = $true
            SubscriptionId  = [int]$row['SubscriptionId']
            WebhookConfigId = [int]$row['WebhookConfigId']
            WebhookName     = $row['WebhookName']
            ChannelName     = $row['ChannelName']
            AlertCategory   = if ($row['AlertCategory'] -is [DBNull]) { $null } else { $row['AlertCategory'] }
            TriggerType     = $row['TriggerType']
            IsActive        = [bool]$row['IsActive']
        }

        Write-PodeJsonResponse -Value $result
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

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

        $alertCategory = if ($body.AlertCategory) { $body.AlertCategory } else { 'ALL' }
        $description = if ([string]::IsNullOrWhiteSpace($body.Description)) { [DBNull]::Value } else { $body.Description }

        $rows = Invoke-XFActsQuery -Query @"
            INSERT INTO Teams.WebhookConfig (
                webhook_name, webhook_url, alert_category, description, is_active
            )
            VALUES (
                @WebhookName, @WebhookUrl, @AlertCategory, @Description, 1
            );

            SELECT SCOPE_IDENTITY() AS ConfigId;
"@ -Parameters @{
            WebhookName   = $body.WebhookName
            WebhookUrl    = $body.WebhookUrl
            AlertCategory = $alertCategory
            Description   = $description
        }

        $newConfigId = [int]$rows[0]['ConfigId']

        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            Success  = $true
            ConfigId = $newConfigId
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}
# ============================================================================
# xFACts Control Center - Server Health API Endpoints
# Location: E:\xFACts-ControlCenter\scripts\routes\ServerHealth-API.ps1
# Version: Tracked in dbo.System_Metadata (component: ServerOps.ServerHealth)
# ============================================================================

# API: Server List
Add-PodeRoute -Method Get -Path '/api/servers'  -Authentication 'ADLogin' -ScriptBlock {
    try {
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Application Name=xFACts Control Center;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = @"
SELECT sr.server_id, sr.server_name, sr.ag_cluster_name
FROM dbo.ServerRegistry sr 
WHERE sr.is_active = 1 
  AND sr.server_type = 'SQL_SERVER'  -- Exclude AG listeners
  AND EXISTS (
      SELECT 1 FROM ServerOps.Activity_DMV_Memory m 
      WHERE m.server_id = sr.server_id 
      AND m.snapshot_dttm >= DATEADD(HOUR, -1, GETDATE())
  )
ORDER BY sr.server_id
"@
        $cmd.CommandTimeout = 30
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        $conn.Close()
        $results = @()
        foreach ($row in $dataset.Tables[0].Rows) { 
            $results += [PSCustomObject]@{ 
                server_id = $row['server_id']
                server_name = $row['server_name']
                ag_cluster_name = if ($row['ag_cluster_name'] -is [DBNull]) { $null } else { $row['ag_cluster_name'] }
            } 
        }
        Write-PodeJsonResponse -Value $results
    } catch { Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500 }
}

# API: GlobalConfig Thresholds
Add-PodeRoute -Method Get -Path '/api/config/thresholds'  -Authentication 'ADLogin' -ScriptBlock {
    try {
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Application Name=xFACts Control Center;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = "SELECT setting_name, setting_value FROM dbo.GlobalConfig WHERE module_name = 'ServerOps' AND category = 'Activity_DMV' AND setting_name LIKE 'threshold_%' AND is_active = 1"
        $cmd.CommandTimeout = 10
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        $conn.Close()
        $result = [PSCustomObject]@{}
        foreach ($row in $dataset.Tables[0].Rows) {
            $name = $row['setting_name']; $value = $row['setting_value']
            if ($value -match '^\d+$') { $value = [int]$value }
            $result | Add-Member -NotePropertyName $name -NotePropertyValue $value
        }
        Write-PodeJsonResponse -Value $result
    } catch { Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500 }
}

# API: Memory Metrics
Add-PodeRoute -Method Get -Path '/api/server-health/memory'  -Authentication 'ADLogin' -ScriptBlock {
    try {
        $serverName = $WebEvent.Query['server']; if (-not $serverName) { $serverName = 'AVG-PROD-LSNR' }
        $connString = "Server=$serverName;Database=master;Integrated Security=True;Application Name=xFACts Control Center;Connect Timeout=5;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = @"
SELECT 
    (SELECT cntr_value FROM sys.dm_os_performance_counters WHERE counter_name = 'Page life expectancy' AND object_name LIKE '%Buffer Manager%') AS ple,
    (SELECT CAST(a.cntr_value AS FLOAT) / NULLIF(b.cntr_value, 0) * 100 FROM sys.dm_os_performance_counters a CROSS JOIN sys.dm_os_performance_counters b WHERE a.counter_name = 'Buffer cache hit ratio' AND a.object_name LIKE '%Buffer Manager%' AND b.counter_name = 'Buffer cache hit ratio base' AND b.object_name LIKE '%Buffer Manager%') AS buffer_cache_hit_ratio,
    (SELECT cntr_value FROM sys.dm_os_performance_counters WHERE counter_name = 'Memory Grants Pending' AND object_name LIKE '%Memory Manager%') AS memory_grants_pending,
    (SELECT cntr_value FROM sys.dm_os_performance_counters WHERE counter_name = 'Lazy writes/sec' AND object_name LIKE '%Buffer Manager%') AS lazy_writes_cumulative
"@
        $cmd.CommandTimeout = 10
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        $conn.Close()
        if ($dataset.Tables.Count -gt 0 -and $dataset.Tables[0].Rows.Count -gt 0) {
            $row = $dataset.Tables[0].Rows[0]
            $currentCumulative = if ($row['lazy_writes_cumulative'] -is [DBNull]) { $null } else { [long]$row['lazy_writes_cumulative'] }
            $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

            # Calculate lazy writes/sec from delta with previous reading
            $lazyWritesSec = $null
            $cacheKey = "lazy_writes_prev_$serverName"
            Lock-PodeObject -Name 'ApiCache' -ScriptBlock {
                $cache = Get-PodeState -Name 'ApiCache'
                $prev = $cache[$cacheKey]
                if ($prev -and $null -ne $currentCumulative) {
                    $elapsedSec = ($now - $prev.Timestamp) / 1000.0
                    if ($elapsedSec -gt 0) {
                        $delta = $currentCumulative - $prev.Value
                        if ($delta -ge 0) {
                            $lazyWritesSec = [int][math]::Round($delta / $elapsedSec)
                        }
                    }
                }
                # Store current reading for next call
                if ($null -ne $currentCumulative) {
                    $cache[$cacheKey] = @{ Value = $currentCumulative; Timestamp = $now }
                }
            }

            $result = [PSCustomObject]@{
                ple = if ($row['ple'] -is [DBNull]) { $null } else { [int]$row['ple'] }
                buffer_cache_hit_ratio = if ($row['buffer_cache_hit_ratio'] -is [DBNull]) { $null } else { [math]::Round([decimal]$row['buffer_cache_hit_ratio'], 2) }
                memory_grants_pending = if ($row['memory_grants_pending'] -is [DBNull]) { $null } else { [int]$row['memory_grants_pending'] }
                lazy_writes_sec = $lazyWritesSec
            }
            Write-PodeJsonResponse -Value $result
        } else { Write-PodeJsonResponse -Value ([PSCustomObject]@{ ple = $null; buffer_cache_hit_ratio = $null; memory_grants_pending = $null; lazy_writes_sec = $null }) }
    } catch { Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500 }
}

# API: Connection Metrics
Add-PodeRoute -Method Get -Path '/api/server-health/connections'  -Authentication 'ADLogin' -ScriptBlock {
    try {
        $serverName = $WebEvent.Query['server']; if (-not $serverName) { $serverName = 'AVG-PROD-LSNR' }
        # Get thresholds from GlobalConfig
        $xfactsConn = New-Object System.Data.SqlClient.SqlConnection("Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Application Name=xFACts Control Center;")
        $xfactsConn.Open()
        $configCmd = $xfactsConn.CreateCommand()
        $configCmd.CommandText = "SELECT setting_name, CAST(setting_value AS INT) AS setting_value FROM dbo.GlobalConfig WHERE module_name = 'ServerOps' AND category = 'Activity_DMV' AND setting_name IN ('threshold_zombie_idle_minutes', 'threshold_open_trans_idle_minutes') AND is_active = 1"
        $configAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($configCmd)
        $configDataset = New-Object System.Data.DataSet
        $configAdapter.Fill($configDataset) | Out-Null
        $xfactsConn.Close()
        
        $zombieThreshold = 60  # default
        $openTransIdleThreshold = 5  # default
        foreach ($row in $configDataset.Tables[0].Rows) {
            if ($row['setting_name'] -eq 'threshold_zombie_idle_minutes') { $zombieThreshold = $row['setting_value'] }
            if ($row['setting_name'] -eq 'threshold_open_trans_idle_minutes') { $openTransIdleThreshold = $row['setting_value'] }
        }
        
        $connString = "Server=$serverName;Database=master;Integrated Security=True;Application Name=xFACts Control Center;Connect Timeout=5;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = @"
DECLARE @zombie_threshold_minutes INT = $zombieThreshold;
DECLARE @open_trans_idle_minutes INT = $openTransIdleThreshold;

;WITH SessionData AS (
    SELECT session_id, status, program_name, open_transaction_count, last_request_end_time,
        DATEDIFF(MINUTE, last_request_end_time, GETDATE()) AS idle_minutes,
        CASE WHEN program_name LIKE '%JDBC%' THEN 1 ELSE 0 END AS is_jdbc,
        CASE WHEN status = 'sleeping' AND open_transaction_count = 0 AND program_name LIKE '%JDBC%' AND DATEDIFF(MINUTE, last_request_end_time, GETDATE()) > @zombie_threshold_minutes THEN 1 ELSE 0 END AS is_zombie,
        CASE WHEN status = 'sleeping' AND open_transaction_count > 0 AND DATEDIFF(MINUTE, last_request_end_time, GETDATE()) > @open_trans_idle_minutes THEN 1 ELSE 0 END AS has_idle_open_trans
    FROM sys.dm_exec_sessions WHERE session_id > 50 AND is_user_process = 1
),
OpenTransInfo AS (SELECT TOP 1 session_id AS oldest_spid, idle_minutes AS oldest_idle FROM SessionData WHERE has_idle_open_trans = 1 ORDER BY idle_minutes DESC)
SELECT COUNT(*) AS total_connections, SUM(is_jdbc) AS jdbc_connections, SUM(is_zombie) AS zombie_count,
    ISNULL(MAX(CASE WHEN is_zombie = 1 THEN idle_minutes ELSE NULL END), 0) AS oldest_zombie_minutes,
    SUM(has_idle_open_trans) AS open_trans_count,
    (SELECT oldest_spid FROM OpenTransInfo) AS oldest_open_trans_spid,
    (SELECT oldest_idle FROM OpenTransInfo) AS oldest_open_trans_idle_min
FROM SessionData
"@
        $cmd.CommandTimeout = 10
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        $conn.Close()
        if ($dataset.Tables.Count -gt 0 -and $dataset.Tables[0].Rows.Count -gt 0) {
            $row = $dataset.Tables[0].Rows[0]
            $result = [PSCustomObject]@{
                total_connections = if ($row['total_connections'] -is [DBNull]) { 0 } else { [int]$row['total_connections'] }
                jdbc_connections = if ($row['jdbc_connections'] -is [DBNull]) { 0 } else { [int]$row['jdbc_connections'] }
                zombie_count = if ($row['zombie_count'] -is [DBNull]) { 0 } else { [int]$row['zombie_count'] }
                oldest_zombie_minutes = if ($row['oldest_zombie_minutes'] -is [DBNull]) { 0 } else { [int]$row['oldest_zombie_minutes'] }
                open_trans_count = if ($row['open_trans_count'] -is [DBNull]) { 0 } else { [int]$row['open_trans_count'] }
                oldest_open_trans_spid = if ($row['oldest_open_trans_spid'] -is [DBNull]) { $null } else { [int]$row['oldest_open_trans_spid'] }
                oldest_open_trans_idle_min = if ($row['oldest_open_trans_idle_min'] -is [DBNull]) { 0 } else { [int]$row['oldest_open_trans_idle_min'] }
            }
            Write-PodeJsonResponse -Value $result
        } else { Write-PodeJsonResponse -Value ([PSCustomObject]@{ total_connections = $null; jdbc_connections = $null; zombie_count = $null; oldest_zombie_minutes = $null; open_trans_count = $null; oldest_open_trans_spid = $null; oldest_open_trans_idle_min = $null }) }
    } catch { Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500 }
}

# API: Kill Zombie Connections (POST)
Add-PodeRoute -Method Post -Path '/api/server-health/kill-zombies'  -Authentication 'ADLogin' -ScriptBlock {
        if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
        try {
        $serverName = $WebEvent.Query['server']; if (-not $serverName) { $serverName = 'AVG-PROD-LSNR' }
        $username = $WebEvent.Auth.User.Username
        $displayName = if ($WebEvent.Auth.User.Name) { $WebEvent.Auth.User.Name } else { $username }
        
        # Get threshold from GlobalConfig
        $xfactsConn = New-Object System.Data.SqlClient.SqlConnection("Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Application Name=xFACts Control Center;")
        $xfactsConn.Open()
        $configCmd = $xfactsConn.CreateCommand()
        $configCmd.CommandText = "SELECT CAST(setting_value AS INT) FROM dbo.GlobalConfig WHERE module_name = 'ServerOps' AND category = 'Activity_DMV' AND setting_name = 'threshold_zombie_idle_minutes' AND is_active = 1"
        $zombieThreshold = $configCmd.ExecuteScalar()
        if ($null -eq $zombieThreshold) { $zombieThreshold = 60 }
        
        # Also get webhook URL for Teams alert
        $webhookCmd = $xfactsConn.CreateCommand()
        $webhookCmd.CommandText = "SELECT webhook_url FROM Teams.WebhookConfig WHERE webhook_name = 'xFACts_Alerts' AND is_active = 1"
        $webhookUrl = $webhookCmd.ExecuteScalar()
        
        $connString = "Server=$serverName;Database=master;Integrated Security=True;Application Name=xFACts Control Center;Connect Timeout=5;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = "SELECT session_id FROM sys.dm_exec_sessions WHERE program_name = 'Microsoft JDBC Driver for SQL Server' AND status = 'sleeping' AND open_transaction_count = 0 AND DATEDIFF(MINUTE, last_request_end_time, GETDATE()) > $zombieThreshold"
        $cmd.CommandTimeout = 10
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        
        $killedCount = 0; $errors = @()
        foreach ($row in $dataset.Tables[0].Rows) {
            $spid = $row['session_id']
            try {
                $killCmd = $conn.CreateCommand()
                $killCmd.CommandText = "KILL $spid"
                $killCmd.CommandTimeout = 5
                $killCmd.ExecuteNonQuery() | Out-Null
                $killedCount++
            } catch { $errors += "SPID $spid : $($_.Exception.Message)" }
        }
        $conn.Close()
        
        # Send Teams alert if we killed any zombies and have a webhook URL
        if ($killedCount -gt 0 -and $webhookUrl) {
            # Force TLS 1.2
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            
            # Use Unicode escape sequences for emojis to avoid encoding issues
            $zombieEmoji = [char]::ConvertFromUtf32(0x1F9DF)  # Zombie
            $gunEmoji = [char]::ConvertFromUtf32(0x1F52B)     # Gun
            $skullEmoji = [char]::ConvertFromUtf32(0x1F480)   # Skull
            
            $title = "$zombieEmoji Zombie Eradication Complete $gunEmoji"
            $message = "**$displayName** has double-tapped JDBC zombies on **$serverName**`n`n$skullEmoji **Kill Count: $killedCount**"
            
            $card = @{
                type = "message"
                attachments = @(
                    @{
                        contentType = "application/vnd.microsoft.card.adaptive"
                        content = @{
                            '$schema' = "http://adaptivecards.io/schemas/adaptive-card.json"
                            type = "AdaptiveCard"
                            version = "1.4"
                            body = @(
                                @{
                                    type = "Container"
                                    style = "good"
                                    items = @(
                                        @{
                                            type = "TextBlock"
                                            text = $title
                                            weight = "bolder"
                                            size = "medium"
                                            wrap = $true
                                        }
                                    )
                                    bleed = $true
                                }
                                @{
                                    type = "TextBlock"
                                    text = $message
                                    wrap = $true
                                    markdown = $true
                                }
                                @{
                                    type = "FactSet"
                                    facts = @(
                                        @{ title = "Source"; value = "ControlCenter" }
                                        @{ title = "Category"; value = "INFO" }
                                        @{ title = "Time"; value = (Get-Date -Format "yyyy-MM-dd HH:mm:ss") }
                                    )
                                }
                            )
                        }
                    }
                )
            }
            
            $json = $card | ConvertTo-Json -Depth 20
            $teamsResult = $null
            $maxRetries = 3
            $retryDelay = 2
            $retryCount = 0
            for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
                try {
                    $teamsResponse = Invoke-RestMethod -Uri $webhookUrl -Method Post -Body $json -ContentType 'application/json; charset=utf-8' -UseBasicParsing
                    $teamsResult = @{ Success = $true; StatusCode = 200 }
                    break
                } catch {
                    $retryCount = $attempt
                    $teamsResult = @{ Success = $false; StatusCode = 0; Error = $_.Exception.Message }
                    if ($attempt -lt $maxRetries) { Start-Sleep -Seconds ($retryDelay * $attempt) }
                }
            }
            
            # Insert audit record to AlertQueue
            $alertStatus = if ($teamsResult.Success) { 'Sent' } else { 'Failed' }
            $safeTitle = $title -replace "'", "''"
            $safeMessage = $message -replace "'", "''"
            
            $auditCmd = $xfactsConn.CreateCommand()
            $auditSql = "INSERT INTO Teams.AlertQueue (source_module, alert_category, title, message, color, status, retry_count, trigger_type, trigger_value, created_dttm, processed_dttm, error_message) "
            $auditSql += "VALUES ('ControlCenter', 'INFO', '$safeTitle', '$safeMessage', 'good', '$alertStatus', $retryCount, 'ZombieKill', '$serverName', GETDATE(), GETDATE(), "
            if ($teamsResult.Success) {
                $auditSql += "NULL)"
            } else {
                $safeError = $teamsResult.Error -replace "'", "''"
                $auditSql += "'$safeError')"
            }
            $auditCmd.CommandText = $auditSql
            $auditCmd.ExecuteNonQuery() | Out-Null
        }
        
        $xfactsConn.Close()
        
        $result = [PSCustomObject]@{ killed_count = $killedCount; threshold_minutes = $zombieThreshold; server = $serverName }
        if ($errors.Count -gt 0) { $result | Add-Member -NotePropertyName 'errors' -NotePropertyValue $errors }
        Write-PodeJsonResponse -Value $result
    } catch { Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500 }
}

# API: Open Transactions Detail
Add-PodeRoute -Method Get -Path '/api/server-health/open-transactions'  -Authentication 'ADLogin' -ScriptBlock {
    try {
        $serverName = $WebEvent.Query['server']; if (-not $serverName) { $serverName = 'AVG-PROD-LSNR' }
        
        # Get idle threshold from GlobalConfig
        $xfactsConn = New-Object System.Data.SqlClient.SqlConnection("Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Application Name=xFACts Control Center;")
        $xfactsConn.Open()
        $configCmd = $xfactsConn.CreateCommand()
        $configCmd.CommandText = "SELECT CAST(setting_value AS INT) FROM dbo.GlobalConfig WHERE module_name = 'ServerOps' AND category = 'Activity_DMV' AND setting_name = 'threshold_open_trans_idle_minutes' AND is_active = 1"
        $idleThreshold = $configCmd.ExecuteScalar()
        $xfactsConn.Close()
        if ($null -eq $idleThreshold) { $idleThreshold = 5 }
        
        $connString = "Server=$serverName;Database=master;Integrated Security=True;Application Name=xFACts Control Center;Connect Timeout=5;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = "SELECT s.session_id, s.login_name, s.program_name, s.host_name, ISNULL(DB_NAME(s.database_id), 'N/A') AS database_name, DATEDIFF(MINUTE, s.last_request_end_time, GETDATE()) AS idle_minutes, s.open_transaction_count FROM sys.dm_exec_sessions s WHERE s.session_id > 50 AND s.is_user_process = 1 AND s.open_transaction_count > 0 AND s.status = 'sleeping' AND DATEDIFF(MINUTE, s.last_request_end_time, GETDATE()) > $idleThreshold ORDER BY DATEDIFF(MINUTE, s.last_request_end_time, GETDATE()) DESC"
        $cmd.CommandTimeout = 10
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        $conn.Close()
        $results = @()
        foreach ($row in $dataset.Tables[0].Rows) {
            $results += [PSCustomObject]@{
                session_id = [int]$row['session_id']
                login_name = if ($row['login_name'] -is [DBNull]) { $null } else { $row['login_name'] }
                program_name = if ($row['program_name'] -is [DBNull]) { $null } else { $row['program_name'] }
                host_name = if ($row['host_name'] -is [DBNull]) { $null } else { $row['host_name'] }
                database_name = if ($row['database_name'] -is [DBNull]) { $null } else { $row['database_name'] }
                idle_minutes = if ($row['idle_minutes'] -is [DBNull]) { 0 } else { [int]$row['idle_minutes'] }
                open_transaction_count = if ($row['open_transaction_count'] -is [DBNull]) { 0 } else { [int]$row['open_transaction_count'] }
            }
        }
        Write-PodeJsonResponse -Value $results
    } catch { Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500 }
}

# API: Activity Metrics
Add-PodeRoute -Method Get -Path '/api/server-health/activity'  -Authentication 'ADLogin' -ScriptBlock {
    try {
        $serverName = $WebEvent.Query['server']; if (-not $serverName) { $serverName = 'AVG-PROD-LSNR' }
        $connString = "Server=$serverName;Database=master;Integrated Security=True;Application Name=xFACts Control Center;Connect Timeout=5;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = @"
;WITH BlockingInfo AS (SELECT r.blocking_session_id, r.session_id, r.wait_time / 1000.0 AS wait_seconds FROM sys.dm_exec_requests r WHERE r.blocking_session_id > 0),
LeadBlocker AS (SELECT TOP 1 b.blocking_session_id AS lead_blocker_spid FROM BlockingInfo b WHERE NOT EXISTS (SELECT 1 FROM BlockingInfo b2 WHERE b2.session_id = b.blocking_session_id) ORDER BY b.wait_seconds DESC),
ActiveCounts AS (
    SELECT 
        SUM(CASE WHEN status = 'running' THEN 1 ELSE 0 END) AS running_count,
        SUM(CASE WHEN status = 'runnable' THEN 1 ELSE 0 END) AS runnable_count,
        SUM(CASE WHEN status = 'suspended' THEN 1 ELSE 0 END) AS suspended_count
    FROM sys.dm_exec_requests WHERE session_id > 50 AND status IN ('running', 'runnable', 'suspended')
)
SELECT (SELECT COUNT(*) FROM BlockingInfo) AS blocked_sessions, 
    (SELECT lead_blocker_spid FROM LeadBlocker) AS lead_blocker_spid,
    ISNULL((SELECT MAX(wait_seconds) FROM BlockingInfo), 0) AS longest_wait_seconds,
    ac.running_count,
    ac.runnable_count,
    ac.suspended_count,
    (ac.running_count + ac.runnable_count + ac.suspended_count) AS active_requests
FROM ActiveCounts ac
"@
        $cmd.CommandTimeout = 10
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        $conn.Close()
        if ($dataset.Tables.Count -gt 0 -and $dataset.Tables[0].Rows.Count -gt 0) {
            $row = $dataset.Tables[0].Rows[0]
            $result = [PSCustomObject]@{
                blocked_sessions = if ($row['blocked_sessions'] -is [DBNull]) { 0 } else { [int]$row['blocked_sessions'] }
                lead_blocker_spid = if ($row['lead_blocker_spid'] -is [DBNull]) { $null } else { [int]$row['lead_blocker_spid'] }
                longest_wait_seconds = if ($row['longest_wait_seconds'] -is [DBNull]) { 0 } else { [math]::Round([decimal]$row['longest_wait_seconds'], 1) }
                active_requests = if ($row['active_requests'] -is [DBNull]) { 0 } else { [int]$row['active_requests'] }
                running_count = if ($row['running_count'] -is [DBNull]) { 0 } else { [int]$row['running_count'] }
                runnable_count = if ($row['runnable_count'] -is [DBNull]) { 0 } else { [int]$row['runnable_count'] }
                suspended_count = if ($row['suspended_count'] -is [DBNull]) { 0 } else { [int]$row['suspended_count'] }
            }
            Write-PodeJsonResponse -Value $result
        } else { Write-PodeJsonResponse -Value ([PSCustomObject]@{ blocked_sessions = 0; lead_blocker_spid = $null; longest_wait_seconds = 0; active_requests = 0; running_count = 0; runnable_count = 0; suspended_count = 0 }) }
    } catch { Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500 }
}

# API: Server Info
Add-PodeRoute -Method Get -Path '/api/server-health/info'  -Authentication 'ADLogin' -ScriptBlock {
    try {
        $serverName = $WebEvent.Query['server']; if (-not $serverName) { $serverName = 'AVG-PROD-LSNR' }
        $connString = "Server=$serverName;Database=master;Integrated Security=True;Application Name=xFACts Control Center;Connect Timeout=5;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = @"
DECLARE @ag_role VARCHAR(20);
BEGIN TRY SELECT TOP 1 @ag_role = ars.role_desc FROM sys.dm_hadr_availability_replica_states ars WHERE ars.is_local = 1; END TRY BEGIN CATCH SET @ag_role = NULL; END CATCH
SELECT CAST(SERVERPROPERTY('ProductVersion') AS VARCHAR(50)) AS version_full,
    CASE WHEN CAST(SERVERPROPERTY('ProductMajorVersion') AS INT) = 16 THEN 'SQL Server 2022' WHEN CAST(SERVERPROPERTY('ProductMajorVersion') AS INT) = 15 THEN 'SQL Server 2019' WHEN CAST(SERVERPROPERTY('ProductMajorVersion') AS INT) = 14 THEN 'SQL Server 2017' ELSE 'SQL Server' END AS version_short,
    CASE SERVERPROPERTY('EngineEdition') WHEN 3 THEN 'Enterprise' WHEN 2 THEN 'Standard' WHEN 4 THEN 'Express' ELSE 'Other' END AS edition,
    (SELECT physical_memory_kb / 1024 / 1024 FROM sys.dm_os_sys_info) AS total_memory_gb,
    (SELECT cpu_count FROM sys.dm_os_sys_info) AS cpu_count,
    (SELECT sqlserver_start_time FROM sys.dm_os_sys_info) AS start_time, @ag_role AS ag_role
"@
        $cmd.CommandTimeout = 10
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        $conn.Close()
        if ($dataset.Tables.Count -gt 0 -and $dataset.Tables[0].Rows.Count -gt 0) {
            $row = $dataset.Tables[0].Rows[0]
            $startTime = [datetime]$row['start_time']
            $uptime = (Get-Date) - $startTime
            $uptimeStr = ""; if ($uptime.Days -gt 0) { $uptimeStr += "$($uptime.Days)d " }; $uptimeStr += "$($uptime.Hours)h $($uptime.Minutes)m"
            $result = [PSCustomObject]@{
                version_full = $row['version_full'].ToString(); version_short = $row['version_short'].ToString(); edition = $row['edition'].ToString()
                total_memory_gb = [int]$row['total_memory_gb']; cpu_count = [int]$row['cpu_count']; uptime = $uptimeStr
                ag_role = if ($row['ag_role'] -is [DBNull]) { $null } else { $row['ag_role'].ToString() }
            }
            Write-PodeJsonResponse -Value $result
        } else { Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "No data" }) -StatusCode 500 }
    } catch { Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500 }
}

# API: Trend Data (with hourly aggregation for 7d/30d views)
Add-PodeRoute -Method Get -Path '/api/server-health/trend'  -Authentication 'ADLogin' -ScriptBlock {
    try {
        $metric = $WebEvent.Query['metric']; $serverName = $WebEvent.Query['server']; $hours = $WebEvent.Query['hours']
        if (-not $metric) { $metric = 'ple' }; if (-not $serverName) { $serverName = 'AVG-PROD-LSNR' }; if (-not $hours) { $hours = 24 }
        $hours = [int]$hours
        
        # Use hourly aggregation for longer time ranges (> 24 hours)
        $useAggregation = $hours -gt 24
        
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Application Name=xFACts Control Center;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        $cmd = $conn.CreateCommand()
        
        # Build query based on metric and aggregation needs
        switch ($metric) {
            'ple' {
                if ($useAggregation) {
                    $cmd.CommandText = "SELECT DATEADD(HOUR, DATEDIFF(HOUR, 0, snapshot_dttm), 0) AS timestamp, AVG(CAST(ple_seconds AS FLOAT)) AS value FROM ServerOps.Activity_DMV_Memory WHERE server_name = @server AND snapshot_dttm >= DATEADD(HOUR, -@hours, GETDATE()) GROUP BY DATEADD(HOUR, DATEDIFF(HOUR, 0, snapshot_dttm), 0) ORDER BY timestamp"
                } else {
                    $cmd.CommandText = "SELECT snapshot_dttm AS timestamp, ple_seconds AS value FROM ServerOps.Activity_DMV_Memory WHERE server_name = @server AND snapshot_dttm >= DATEADD(HOUR, -@hours, GETDATE()) ORDER BY snapshot_dttm"
                }
            }
            'buffer_cache' {
                if ($useAggregation) {
                    $cmd.CommandText = "SELECT DATEADD(HOUR, DATEDIFF(HOUR, 0, snapshot_dttm), 0) AS timestamp, AVG(buffer_cache_hit_ratio) AS value FROM ServerOps.Activity_DMV_Memory WHERE server_name = @server AND snapshot_dttm >= DATEADD(HOUR, -@hours, GETDATE()) GROUP BY DATEADD(HOUR, DATEDIFF(HOUR, 0, snapshot_dttm), 0) ORDER BY timestamp"
                } else {
                    $cmd.CommandText = "SELECT snapshot_dttm AS timestamp, buffer_cache_hit_ratio AS value FROM ServerOps.Activity_DMV_Memory WHERE server_name = @server AND snapshot_dttm >= DATEADD(HOUR, -@hours, GETDATE()) ORDER BY snapshot_dttm"
                }
            }
            'memory_grants' {
                if ($useAggregation) {
                    $cmd.CommandText = "SELECT DATEADD(HOUR, DATEDIFF(HOUR, 0, snapshot_dttm), 0) AS timestamp, AVG(CAST(memory_grants_pending AS FLOAT)) AS value FROM ServerOps.Activity_DMV_Memory WHERE server_name = @server AND snapshot_dttm >= DATEADD(HOUR, -@hours, GETDATE()) GROUP BY DATEADD(HOUR, DATEDIFF(HOUR, 0, snapshot_dttm), 0) ORDER BY timestamp"
                } else {
                    $cmd.CommandText = "SELECT snapshot_dttm AS timestamp, memory_grants_pending AS value FROM ServerOps.Activity_DMV_Memory WHERE server_name = @server AND snapshot_dttm >= DATEADD(HOUR, -@hours, GETDATE()) ORDER BY snapshot_dttm"
                }
            }
            'zombie_count' {
                if ($useAggregation) {
                    $cmd.CommandText = "SELECT DATEADD(HOUR, DATEDIFF(HOUR, 0, snapshot_dttm), 0) AS timestamp, AVG(CAST(zombie_count AS FLOAT)) AS value FROM ServerOps.Activity_DMV_ConnectionHealth WHERE server_name = @server AND snapshot_dttm >= DATEADD(HOUR, -@hours, GETDATE()) GROUP BY DATEADD(HOUR, DATEDIFF(HOUR, 0, snapshot_dttm), 0) ORDER BY timestamp"
                } else {
                    $cmd.CommandText = "SELECT snapshot_dttm AS timestamp, zombie_count AS value FROM ServerOps.Activity_DMV_ConnectionHealth WHERE server_name = @server AND snapshot_dttm >= DATEADD(HOUR, -@hours, GETDATE()) ORDER BY snapshot_dttm"
                }
            }
            'connections' {
                if ($useAggregation) {
                    $cmd.CommandText = "SELECT DATEADD(HOUR, DATEDIFF(HOUR, 0, snapshot_dttm), 0) AS timestamp, AVG(CAST(user_connections AS FLOAT)) AS value FROM ServerOps.Activity_DMV_Workload WHERE server_name = @server AND snapshot_dttm >= DATEADD(HOUR, -@hours, GETDATE()) GROUP BY DATEADD(HOUR, DATEDIFF(HOUR, 0, snapshot_dttm), 0) ORDER BY timestamp"
                } else {
                    $cmd.CommandText = "SELECT snapshot_dttm AS timestamp, user_connections AS value FROM ServerOps.Activity_DMV_Workload WHERE server_name = @server AND snapshot_dttm >= DATEADD(HOUR, -@hours, GETDATE()) ORDER BY snapshot_dttm"
                }
            }
            'jdbc_connections' {
                if ($useAggregation) {
                    $cmd.CommandText = "SELECT DATEADD(HOUR, DATEDIFF(HOUR, 0, snapshot_dttm), 0) AS timestamp, AVG(CAST(jdbc_total AS FLOAT)) AS value FROM ServerOps.Activity_DMV_ConnectionHealth WHERE server_name = @server AND snapshot_dttm >= DATEADD(HOUR, -@hours, GETDATE()) GROUP BY DATEADD(HOUR, DATEDIFF(HOUR, 0, snapshot_dttm), 0) ORDER BY timestamp"
                } else {
                    $cmd.CommandText = "SELECT snapshot_dttm AS timestamp, jdbc_total AS value FROM ServerOps.Activity_DMV_ConnectionHealth WHERE server_name = @server AND snapshot_dttm >= DATEADD(HOUR, -@hours, GETDATE()) ORDER BY snapshot_dttm"
                }
            }
            'blocked_sessions' {
                if ($useAggregation) {
                    $cmd.CommandText = "SELECT DATEADD(HOUR, DATEDIFF(HOUR, 0, snapshot_dttm), 0) AS timestamp, MAX(blocked_session_count) AS value FROM ServerOps.Activity_DMV_Workload WHERE server_name = @server AND snapshot_dttm >= DATEADD(HOUR, -@hours, GETDATE()) GROUP BY DATEADD(HOUR, DATEDIFF(HOUR, 0, snapshot_dttm), 0) ORDER BY timestamp"
                } else {
                    $cmd.CommandText = "SELECT snapshot_dttm AS timestamp, blocked_session_count AS value FROM ServerOps.Activity_DMV_Workload WHERE server_name = @server AND snapshot_dttm >= DATEADD(HOUR, -@hours, GETDATE()) ORDER BY snapshot_dttm"
                }
            }
            default {
                if ($useAggregation) {
                    $cmd.CommandText = "SELECT DATEADD(HOUR, DATEDIFF(HOUR, 0, snapshot_dttm), 0) AS timestamp, AVG(CAST(ple_seconds AS FLOAT)) AS value FROM ServerOps.Activity_DMV_Memory WHERE server_name = @server AND snapshot_dttm >= DATEADD(HOUR, -@hours, GETDATE()) GROUP BY DATEADD(HOUR, DATEDIFF(HOUR, 0, snapshot_dttm), 0) ORDER BY timestamp"
                } else {
                    $cmd.CommandText = "SELECT snapshot_dttm AS timestamp, ple_seconds AS value FROM ServerOps.Activity_DMV_Memory WHERE server_name = @server AND snapshot_dttm >= DATEADD(HOUR, -@hours, GETDATE()) ORDER BY snapshot_dttm"
                }
            }
        }
        $cmd.Parameters.AddWithValue("@server", $serverName) | Out-Null
        $cmd.Parameters.AddWithValue("@hours", $hours) | Out-Null
        $cmd.CommandTimeout = 30
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        $conn.Close()
        $results = @()
        foreach ($row in $dataset.Tables[0].Rows) {
            $val = if ($row['value'] -is [DBNull]) { $null } else { 
                if ($useAggregation) { [math]::Round([double]$row['value'], 2) } else { $row['value'] }
            }
            $results += [PSCustomObject]@{ timestamp = $row['timestamp'].ToString("yyyy-MM-ddTHH:mm:ss"); value = $val }
        }
        Write-PodeJsonResponse -Value $results
    } catch { Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500 }
}

# API: Active Requests Detail
Add-PodeRoute -Method Get -Path '/api/server-health/active-requests'  -Authentication 'ADLogin' -ScriptBlock {
    try {
        $serverName = $WebEvent.Query['server']; if (-not $serverName) { $serverName = 'AVG-PROD-LSNR' }
        $connString = "Server=$serverName;Database=master;Integrated Security=True;Application Name=xFACts Control Center;Connect Timeout=5;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = @"
SELECT 
    r.session_id,
    s.login_name,
    s.host_name,
    s.program_name,
    DB_NAME(r.database_id) AS database_name,
    r.status,
    r.command,
    DATEDIFF(SECOND, r.start_time, GETDATE()) AS duration_seconds,
    r.wait_type,
    r.wait_time / 1000.0 AS wait_seconds,
    r.wait_resource,
    r.blocking_session_id,
    r.cpu_time,
    r.reads,
    r.writes,
    r.logical_reads,
    (SELECT TEXT FROM sys.dm_exec_sql_text(r.sql_handle)) AS query_text
FROM sys.dm_exec_requests r
INNER JOIN sys.dm_exec_sessions s ON r.session_id = s.session_id
WHERE r.session_id > 50
  AND s.is_user_process = 1
  AND r.status IN ('running', 'runnable', 'suspended')
ORDER BY r.start_time ASC
"@
        $cmd.CommandTimeout = 10
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        $conn.Close()
        
        $results = @()
        foreach ($row in $dataset.Tables[0].Rows) {
            $results += [PSCustomObject]@{
                session_id = [int]$row['session_id']
                login_name = if ($row['login_name'] -is [DBNull]) { $null } else { $row['login_name'] }
                host_name = if ($row['host_name'] -is [DBNull]) { $null } else { $row['host_name'] }
                program_name = if ($row['program_name'] -is [DBNull]) { $null } else { $row['program_name'] }
                database_name = if ($row['database_name'] -is [DBNull]) { $null } else { $row['database_name'] }
                status = if ($row['status'] -is [DBNull]) { $null } else { $row['status'] }
                command = if ($row['command'] -is [DBNull]) { $null } else { $row['command'] }
                duration_seconds = if ($row['duration_seconds'] -is [DBNull]) { 0 } else { [int]$row['duration_seconds'] }
                wait_type = if ($row['wait_type'] -is [DBNull]) { $null } else { $row['wait_type'] }
                wait_seconds = if ($row['wait_seconds'] -is [DBNull]) { $null } else { [math]::Round([decimal]$row['wait_seconds'], 1) }
                blocking_session_id = if ($row['blocking_session_id'] -is [DBNull] -or [int]$row['blocking_session_id'] -eq 0) { $null } else { [int]$row['blocking_session_id'] }
                cpu_time = if ($row['cpu_time'] -is [DBNull]) { 0 } else { [int]$row['cpu_time'] }
                reads = if ($row['reads'] -is [DBNull]) { 0 } else { [long]$row['reads'] }
                writes = if ($row['writes'] -is [DBNull]) { 0 } else { [long]$row['writes'] }
                logical_reads = if ($row['logical_reads'] -is [DBNull]) { 0 } else { [long]$row['logical_reads'] }
                query_text = if ($row['query_text'] -is [DBNull]) { $null } else { $row['query_text'] }
            }
        }
        Write-PodeJsonResponse -Value $results
    } catch { Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500 }
}

# API: Blocking Details
Add-PodeRoute -Method Get -Path '/api/server-health/blocking-details'  -Authentication 'ADLogin' -ScriptBlock {
    try {
        $serverName = $WebEvent.Query['server']; if (-not $serverName) { $serverName = 'AVG-PROD-LSNR' }
        $connString = "Server=$serverName;Database=master;Integrated Security=True;Application Name=xFACts Control Center;Connect Timeout=5;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = @"
;WITH BlockingChain AS (
    SELECT 
        r.session_id AS blocked_spid,
        r.blocking_session_id AS blocker_spid,
        r.wait_time / 1000.0 AS wait_seconds,
        r.wait_type,
        r.wait_resource,
        DB_NAME(r.database_id) AS database_name,
        s.login_name,
        s.host_name,
        s.program_name,
        s.status,
        (SELECT TEXT FROM sys.dm_exec_sql_text(r.sql_handle)) AS blocked_query
    FROM sys.dm_exec_requests r
    INNER JOIN sys.dm_exec_sessions s ON r.session_id = s.session_id
    WHERE r.blocking_session_id > 0
),
LeadBlockers AS (
    SELECT DISTINCT bc.blocker_spid
    FROM BlockingChain bc
    WHERE NOT EXISTS (
        SELECT 1 FROM BlockingChain bc2 
        WHERE bc2.blocked_spid = bc.blocker_spid
    )
),
BlockerDetails AS (
    SELECT 
        s.session_id AS blocker_spid,
        s.login_name,
        s.host_name,
        s.program_name,
        s.status,
        DB_NAME(s.database_id) AS database_name,
        s.last_request_start_time,
        s.last_request_end_time,
        DATEDIFF(SECOND, s.last_request_start_time, GETDATE()) AS duration_seconds,
        COALESCE(
            (SELECT TEXT FROM sys.dm_exec_sql_text(r.sql_handle)),
            (SELECT TOP 1 TEXT FROM sys.dm_exec_connections c CROSS APPLY sys.dm_exec_sql_text(c.most_recent_sql_handle) WHERE c.session_id = s.session_id)
        ) AS blocker_query
    FROM sys.dm_exec_sessions s
    LEFT JOIN sys.dm_exec_requests r ON s.session_id = r.session_id
    WHERE s.session_id IN (SELECT blocker_spid FROM LeadBlockers)
)
SELECT 
    'blocker' AS row_type,
    bd.blocker_spid AS spid,
    NULL AS blocker_spid,
    bd.login_name,
    bd.host_name,
    bd.program_name,
    bd.database_name,
    bd.status,
    NULL AS wait_seconds,
    NULL AS wait_type,
    bd.duration_seconds,
    bd.blocker_query AS query_text
FROM BlockerDetails bd
UNION ALL
SELECT 
    'blocked' AS row_type,
    bc.blocked_spid AS spid,
    bc.blocker_spid,
    bc.login_name,
    bc.host_name,
    bc.program_name,
    bc.database_name,
    bc.status,
    bc.wait_seconds,
    bc.wait_type,
    NULL AS duration_seconds,
    bc.blocked_query AS query_text
FROM BlockingChain bc
ORDER BY row_type DESC, spid
"@
        $cmd.CommandTimeout = 15
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        $conn.Close()
        
        $blockers = @()
        $blocked = @()
        foreach ($row in $dataset.Tables[0].Rows) {
            $item = [PSCustomObject]@{
                spid = [int]$row['spid']
                blocker_spid = if ($row['blocker_spid'] -is [DBNull]) { $null } else { [int]$row['blocker_spid'] }
                login_name = if ($row['login_name'] -is [DBNull]) { $null } else { $row['login_name'] }
                host_name = if ($row['host_name'] -is [DBNull]) { $null } else { $row['host_name'] }
                program_name = if ($row['program_name'] -is [DBNull]) { $null } else { $row['program_name'] }
                database_name = if ($row['database_name'] -is [DBNull]) { $null } else { $row['database_name'] }
                status = if ($row['status'] -is [DBNull]) { $null } else { $row['status'] }
                wait_seconds = if ($row['wait_seconds'] -is [DBNull]) { $null } else { [math]::Round([decimal]$row['wait_seconds'], 1) }
                wait_type = if ($row['wait_type'] -is [DBNull]) { $null } else { $row['wait_type'] }
                duration_seconds = if ($row['duration_seconds'] -is [DBNull]) { $null } else { [int]$row['duration_seconds'] }
                query_text = if ($row['query_text'] -is [DBNull]) { $null } else { $row['query_text'] }
            }
            if ($row['row_type'] -eq 'blocker') { $blockers += $item } else { $blocked += $item }
        }
        
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ blockers = $blockers; blocked = $blocked })
    } catch { Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500 }
}

# API: Disk Space
Add-PodeRoute -Method Get -Path '/api/server-health/disks'  -Authentication 'ADLogin' -ScriptBlock {
    try {
        $serverName = $WebEvent.Query['server']; if (-not $serverName) { $serverName = 'AVG-PROD-LSNR' }
        $results = @(); $localHostNames = @($env:COMPUTERNAME, 'localhost', '127.0.0.1')
        try {
            if ($localHostNames -contains $serverName) { $disks = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3" -OperationTimeoutSec 10 -ErrorAction Stop }
            else {
                $sessionOption = New-CimSessionOption -Protocol Wsman
                $session = New-CimSession -ComputerName $serverName -SessionOption $sessionOption -OperationTimeoutSec 10 -ErrorAction Stop
                $disks = Get-CimInstance -CimSession $session -ClassName Win32_LogicalDisk -Filter "DriveType=3" -OperationTimeoutSec 10 -ErrorAction Stop
                Remove-CimSession $session -ErrorAction SilentlyContinue
            }
            foreach ($disk in $disks) {
                $totalGB = [math]::Round($disk.Size / 1GB, 1); $freeGB = [math]::Round($disk.FreeSpace / 1GB, 1)
                $usedPct = if ($disk.Size -gt 0) { [math]::Round((($disk.Size - $disk.FreeSpace) / $disk.Size) * 100, 1) } else { 0 }
                $freeDisplay = if ($freeGB -ge 1000) { "{0:N1} TB" -f ($freeGB / 1024) } elseif ($freeGB -ge 1) { "{0:N0} GB" -f $freeGB } else { "{0:N0} MB" -f [math]::Round($disk.FreeSpace / 1MB, 0) }
                $results += [PSCustomObject]@{ drive = $disk.DeviceID; total_gb = $totalGB; free_gb = $freeGB; used_pct = $usedPct; free_display = $freeDisplay }
            }
            $results = $results | Sort-Object drive
        } catch { Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "CIM failed: $($_.Exception.Message)" }) -StatusCode 500; return }
        Write-PodeJsonResponse -Value $results
    } catch { Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500 }
}

# API: AG Status (AG-cluster-aware - shows all replicas in the same AG)
Add-PodeRoute -Method Get -Path '/api/server-health/ag-status'  -Authentication 'ADLogin' -ScriptBlock {
    try {
        $serverName = $WebEvent.Query['server']; if (-not $serverName) { $serverName = 'AVG-PROD-LSNR' }
        
        # First, check if this server is in an AG by looking at ServerRegistry
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Application Name=xFACts Control Center;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = @"
SELECT ag_cluster_name 
FROM dbo.ServerRegistry 
WHERE server_name = @serverParam AND ag_cluster_name IS NOT NULL
"@
        $cmd.Parameters.AddWithValue("@serverParam", $serverName) | Out-Null
        $cmd.CommandTimeout = 10
        $agCluster = $cmd.ExecuteScalar()
        
        if ($null -eq $agCluster -or $agCluster -is [DBNull]) {
            $conn.Close()
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ is_ag_member = $false; replicas = @() })
            return
        }
        
        # Get all servers in this AG cluster (excluding listener)
        $cmd2 = $conn.CreateCommand()
        $cmd2.CommandText = @"
SELECT server_id, server_name 
FROM dbo.ServerRegistry 
WHERE ag_cluster_name = @agCluster 
  AND server_type = 'SQL_SERVER'
ORDER BY server_id
"@
        $cmd2.Parameters.AddWithValue("@agCluster", $agCluster) | Out-Null
        $cmd2.CommandTimeout = 10
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd2)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        $conn.Close()
        
        $agServers = @()
        foreach ($row in $dataset.Tables[0].Rows) {
            $agServers += [PSCustomObject]@{ server_id = $row['server_id']; server_name = $row['server_name'] }
        }
        
        if ($agServers.Count -eq 0) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ is_ag_member = $false; replicas = @() })
            return
        }
        
        # Query the first AG server (usually server_id 1) for live AG status
        $primaryServer = $agServers[0].server_name
        $agConnString = "Server=$primaryServer;Database=master;Integrated Security=True;Application Name=xFACts Control Center;Connect Timeout=5;"
        $agConn = New-Object System.Data.SqlClient.SqlConnection($agConnString)
        $agConn.Open()
        $agCmd = $agConn.CreateCommand()
        $agCmd.CommandText = @"
IF EXISTS (SELECT 1 FROM sys.dm_hadr_availability_replica_states)
BEGIN
    SELECT 
        ag.name AS ag_name,
        ar.replica_server_name AS server_name,
        ars.role_desc AS role,
        ars.synchronization_health_desc AS sync_health,
        ars.operational_state_desc AS operational_state,
        ars.connected_state_desc AS connected_state,
        CASE 
            WHEN ars.synchronization_health_desc = 'HEALTHY' THEN 'healthy'
            WHEN ars.synchronization_health_desc = 'PARTIALLY_HEALTHY' THEN 'warning'
            ELSE 'critical'
        END AS health_status
    FROM sys.availability_groups ag
    INNER JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id
    INNER JOIN sys.dm_hadr_availability_replica_states ars ON ar.replica_id = ars.replica_id
    ORDER BY CASE WHEN ars.role_desc = 'PRIMARY' THEN 0 ELSE 1 END, ar.replica_server_name
END
ELSE
BEGIN
    SELECT NULL AS ag_name, NULL AS server_name WHERE 1=0
END
"@
        $agCmd.CommandTimeout = 10
        $agAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($agCmd)
        $agDataset = New-Object System.Data.DataSet
        $agAdapter.Fill($agDataset) | Out-Null
        $agConn.Close()
        
        $replicas = @()
        $agName = $null
        $agSyncHealth = 'HEALTHY'
        foreach ($row in $agDataset.Tables[0].Rows) {
            if ($null -eq $agName) { $agName = $row['ag_name'] }
            # AG-level health is worst of all replicas
            if ($row['sync_health'] -eq 'NOT_HEALTHY') { $agSyncHealth = 'NOT_HEALTHY' }
            elseif ($row['sync_health'] -eq 'PARTIALLY_HEALTHY' -and $agSyncHealth -ne 'NOT_HEALTHY') { $agSyncHealth = 'PARTIALLY_HEALTHY' }
            
            $replicas += [PSCustomObject]@{
                server_name = $row['server_name']
                role = $row['role']
                sync_health = $row['sync_health']
                operational_state = $row['operational_state']
                connected_state = $row['connected_state']
                health_status = $row['health_status']
            }
        }
        
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ 
            is_ag_member = $true
            ag_cluster = $agCluster
            ag_name = $agName
            ag_sync_health = $agSyncHealth
            replicas = $replicas 
        })
    } catch { Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500 }
}

# API: AG Replica Detail (detailed metrics for a specific replica)
Add-PodeRoute -Method Get -Path '/api/server-health/ag-replica-detail'  -Authentication 'ADLogin' -ScriptBlock {
    try {
        $serverName = $WebEvent.Query['server']; if (-not $serverName) { $serverName = 'AVG-PROD-LSNR' }
        
        # Connect to the specified server for live metrics
        $connString = "Server=$serverName;Database=master;Integrated Security=True;Application Name=xFACts Control Center;Connect Timeout=5;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = @"
-- Get replica-level info
SELECT 
    ag.name AS ag_name,
    ar.replica_server_name,
    ars.role_desc,
    ars.operational_state_desc,
    ars.connected_state_desc,
    ars.recovery_health_desc,
    ars.synchronization_health_desc
FROM sys.availability_groups ag
INNER JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id
INNER JOIN sys.dm_hadr_availability_replica_states ars ON ar.replica_id = ars.replica_id
WHERE ar.replica_server_name = @@SERVERNAME;

-- Get database-level details
SELECT 
    db.name AS database_name,
    drs.synchronization_state_desc,
    drs.synchronization_health_desc,
    drs.is_suspended,
    drs.suspend_reason_desc,
    drs.log_send_queue_size,
    drs.log_send_rate,
    drs.redo_queue_size,
    drs.redo_rate,
    drs.last_sent_time,
    drs.last_received_time,
    drs.last_hardened_time,
    drs.last_redone_time,
    drs.last_commit_time,
    CASE 
        WHEN drs.redo_rate > 0 THEN drs.redo_queue_size / drs.redo_rate 
        ELSE NULL 
    END AS estimated_catchup_seconds
FROM sys.dm_hadr_database_replica_states drs
INNER JOIN sys.databases db ON drs.database_id = db.database_id
WHERE drs.is_local = 1
ORDER BY db.name;

-- Get PLE
SELECT cntr_value AS ple
FROM sys.dm_os_performance_counters
WHERE object_name LIKE '%Buffer Manager%'
  AND counter_name = 'Page life expectancy';
"@
        $cmd.CommandTimeout = 10
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        $conn.Close()
        
        # Parse replica info
        $replicaInfo = $null
        if ($dataset.Tables[0].Rows.Count -gt 0) {
            $row = $dataset.Tables[0].Rows[0]
            $replicaInfo = [PSCustomObject]@{
                ag_name = $row['ag_name']
                server_name = $row['replica_server_name']
                role = $row['role_desc']
                operational_state = $row['operational_state_desc']
                connected_state = $row['connected_state_desc']
                recovery_health = $row['recovery_health_desc']
                sync_health = $row['synchronization_health_desc']
            }
        }
        
        # Parse database details
        $databases = @()
        foreach ($row in $dataset.Tables[1].Rows) {
            $databases += [PSCustomObject]@{
                database_name = $row['database_name']
                sync_state = $row['synchronization_state_desc']
                sync_health = $row['synchronization_health_desc']
                is_suspended = [bool]$row['is_suspended']
                suspend_reason = if ($row['suspend_reason_desc'] -is [DBNull]) { $null } else { $row['suspend_reason_desc'] }
                log_send_queue_kb = if ($row['log_send_queue_size'] -is [DBNull]) { $null } else { [long]$row['log_send_queue_size'] }
                log_send_rate_kbps = if ($row['log_send_rate'] -is [DBNull]) { $null } else { [long]$row['log_send_rate'] }
                redo_queue_kb = if ($row['redo_queue_size'] -is [DBNull]) { $null } else { [long]$row['redo_queue_size'] }
                redo_rate_kbps = if ($row['redo_rate'] -is [DBNull]) { $null } else { [long]$row['redo_rate'] }
                last_sent_time = if ($row['last_sent_time'] -is [DBNull]) { $null } else { $row['last_sent_time'].ToString("yyyy-MM-dd HH:mm:ss") }
                last_received_time = if ($row['last_received_time'] -is [DBNull]) { $null } else { $row['last_received_time'].ToString("yyyy-MM-dd HH:mm:ss") }
                last_hardened_time = if ($row['last_hardened_time'] -is [DBNull]) { $null } else { $row['last_hardened_time'].ToString("yyyy-MM-dd HH:mm:ss") }
                last_redone_time = if ($row['last_redone_time'] -is [DBNull]) { $null } else { $row['last_redone_time'].ToString("yyyy-MM-dd HH:mm:ss") }
                last_commit_time = if ($row['last_commit_time'] -is [DBNull]) { $null } else { $row['last_commit_time'].ToString("yyyy-MM-dd HH:mm:ss") }
                estimated_catchup_seconds = if ($row['estimated_catchup_seconds'] -is [DBNull]) { $null } else { [int]$row['estimated_catchup_seconds'] }
            }
        }
        
        # Parse PLE
        $ple = $null
        if ($dataset.Tables[2].Rows.Count -gt 0) {
            $ple = [long]$dataset.Tables[2].Rows[0]['ple']
        }
        
        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            replica = $replicaInfo
            databases = $databases
            ple = $ple
        })
    } catch { Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500 }
}

# API: XE Activity (all XE-derived counts)
Add-PodeRoute -Method Get -Path '/api/server-health/xe-activity'  -Authentication 'ADLogin' -ScriptBlock {
    try {
        $serverName = $WebEvent.Query['server']; if (-not $serverName) { $serverName = 'AVG-PROD-LSNR' }
        $minutes = $WebEvent.Query['minutes']; if (-not $minutes) { $minutes = 15 }
        
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Application Name=xFACts Control Center;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = @"
DECLARE @cutoff DATETIME = DATEADD(MINUTE, -@minutesParam, GETDATE());

SELECT
    (SELECT COUNT(*) FROM ServerOps.Activity_XE_LRQ WHERE server_name = @serverParam AND event_timestamp >= @cutoff) AS lrq_count,
    (SELECT COUNT(*) FROM ServerOps.Activity_XE_BlockedProcess WHERE server_name = @serverParam AND event_timestamp >= @cutoff) AS blocking_count,
    (SELECT COUNT(*) FROM ServerOps.Activity_XE_Deadlock WHERE server_name = @serverParam AND event_timestamp >= @cutoff) AS deadlock_count,
    (SELECT COUNT(*) FROM ServerOps.Activity_XE_LinkedServerIn WHERE server_name = @serverParam AND last_event_timestamp >= @cutoff) AS ls_inbound_count,
    (SELECT COUNT(*) FROM ServerOps.Activity_XE_LinkedServerOut WHERE server_name = @serverParam AND last_event_timestamp >= @cutoff) AS ls_outbound_count,
    (SELECT COUNT(*) FROM ServerOps.Activity_XE_AGHealth WHERE server_name = @serverParam AND event_timestamp >= @cutoff) AS ag_events_count,
    (SELECT COUNT(*) FROM ServerOps.Activity_XE_SystemHealth WHERE server_name = @serverParam AND event_timestamp >= @cutoff) AS system_health_count
"@
        $cmd.Parameters.AddWithValue("@serverParam", $serverName) | Out-Null
        $cmd.Parameters.AddWithValue("@minutesParam", [int]$minutes) | Out-Null
        $cmd.CommandTimeout = 30
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        $conn.Close()
        
        if ($dataset.Tables.Count -gt 0 -and $dataset.Tables[0].Rows.Count -gt 0) {
            $row = $dataset.Tables[0].Rows[0]
            $result = [PSCustomObject]@{
                lrq_count = [int]$row['lrq_count']
                blocking_count = [int]$row['blocking_count']
                deadlock_count = [int]$row['deadlock_count']
                ls_inbound_count = [int]$row['ls_inbound_count']
                ls_outbound_count = [int]$row['ls_outbound_count']
                ag_events_count = [int]$row['ag_events_count']
                system_health_count = [int]$row['system_health_count']
            }
            Write-PodeJsonResponse -Value $result
        } else {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ 
                lrq_count = 0; blocking_count = 0; deadlock_count = 0
                ls_inbound_count = 0; ls_outbound_count = 0
                ag_events_count = 0; system_health_count = 0
            })
        }
    } catch { Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500 }
}

# API: Long Running Queries Detail (grouped by session)
Add-PodeRoute -Method Get -Path '/api/server-health/lrq-detail'  -Authentication 'ADLogin' -ScriptBlock {
    try {
        $serverName = $WebEvent.Query['server']; if (-not $serverName) { $serverName = 'AVG-PROD-LSNR' }
        $minutes = $WebEvent.Query['minutes']; if (-not $minutes) { $minutes = 15 }
        
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Application Name=xFACts Control Center;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = @"
DECLARE @cutoff DATETIME = DATEADD(MINUTE, -@minutesParam, GETDATE());

;WITH Aggregated AS (
    SELECT
        session_id,
        database_name,
        username,
        client_hostname,
        client_app_name,
        COUNT(*) AS execution_count,
        AVG(duration_ms) AS avg_duration_ms,
        MAX(duration_ms) AS max_duration_ms,
        SUM(duration_ms) AS total_duration_ms,
        AVG(cpu_time_ms) AS avg_cpu_ms,
        SUM(cpu_time_ms) AS total_cpu_ms,
        SUM(logical_reads) AS total_reads,
        SUM(writes) AS total_writes,
        MIN(event_timestamp) AS first_occurrence,
        MAX(event_timestamp) AS last_occurrence
    FROM ServerOps.Activity_XE_LRQ
    WHERE server_name = @serverParam 
      AND event_timestamp >= @cutoff
    GROUP BY session_id, database_name, username, client_hostname, client_app_name
),
MostRecent AS (
    SELECT 
        session_id,
        database_name,
        username,
        client_hostname,
        client_app_name,
        sql_text,
        ROW_NUMBER() OVER (
            PARTITION BY session_id, database_name, username, client_hostname, client_app_name 
            ORDER BY event_timestamp DESC
        ) AS rn
    FROM ServerOps.Activity_XE_LRQ
    WHERE server_name = @serverParam 
      AND event_timestamp >= @cutoff
)
SELECT 
    a.*,
    m.sql_text AS recent_sql_text
FROM Aggregated a
LEFT JOIN MostRecent m ON a.session_id = m.session_id 
    AND ISNULL(a.database_name,'') = ISNULL(m.database_name,'')
    AND ISNULL(a.username,'') = ISNULL(m.username,'')
    AND ISNULL(a.client_hostname,'') = ISNULL(m.client_hostname,'')
    AND ISNULL(a.client_app_name,'') = ISNULL(m.client_app_name,'')
    AND m.rn = 1
ORDER BY a.execution_count DESC, a.avg_duration_ms DESC
"@
        $cmd.Parameters.AddWithValue("@serverParam", $serverName) | Out-Null
        $cmd.Parameters.AddWithValue("@minutesParam", [int]$minutes) | Out-Null
        $cmd.CommandTimeout = 30
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        $conn.Close()
        
        $results = @()
        foreach ($row in $dataset.Tables[0].Rows) {
            $results += [PSCustomObject]@{
                session_id = if ($row['session_id'] -is [DBNull]) { $null } else { [int]$row['session_id'] }
                database_name = if ($row['database_name'] -is [DBNull]) { $null } else { $row['database_name'] }
                username = if ($row['username'] -is [DBNull]) { $null } else { $row['username'] }
                client_hostname = if ($row['client_hostname'] -is [DBNull]) { $null } else { $row['client_hostname'] }
                client_app_name = if ($row['client_app_name'] -is [DBNull]) { $null } else { $row['client_app_name'] }
                execution_count = [int]$row['execution_count']
                avg_duration_ms = [long]$row['avg_duration_ms']
                max_duration_ms = [long]$row['max_duration_ms']
                total_duration_ms = [long]$row['total_duration_ms']
                avg_cpu_ms = if ($row['avg_cpu_ms'] -is [DBNull]) { $null } else { [long]$row['avg_cpu_ms'] }
                total_cpu_ms = if ($row['total_cpu_ms'] -is [DBNull]) { $null } else { [long]$row['total_cpu_ms'] }
                total_reads = if ($row['total_reads'] -is [DBNull]) { $null } else { [long]$row['total_reads'] }
                total_writes = if ($row['total_writes'] -is [DBNull]) { $null } else { [long]$row['total_writes'] }
                first_occurrence = $row['first_occurrence'].ToString("yyyy-MM-dd HH:mm:ss")
                last_occurrence = $row['last_occurrence'].ToString("yyyy-MM-dd HH:mm:ss")
                recent_sql_text = if ($row['recent_sql_text'] -is [DBNull]) { $null } else { $row['recent_sql_text'] }
            }
        }
        Write-PodeJsonResponse -Value $results
    } catch { Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500 }
}

# API: Blocking Events Detail (grouped by blocker SPID)
Add-PodeRoute -Method Get -Path '/api/server-health/blocking-detail'  -Authentication 'ADLogin' -ScriptBlock {
    try {
        $serverName = $WebEvent.Query['server']; if (-not $serverName) { $serverName = 'AVG-PROD-LSNR' }
        $minutes = $WebEvent.Query['minutes']; if (-not $minutes) { $minutes = 15 }
        
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Application Name=xFACts Control Center;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = @"
DECLARE @cutoff DATETIME = DATEADD(MINUTE, -@minutesParam, GETDATE());

;WITH Aggregated AS (
    SELECT
        blocked_by_spid,
        blocked_by_login,
        blocked_by_database,
        blocked_by_client_app,
        blocked_by_host_name,
        blocked_by_status,
        COUNT(*) AS blocking_count,
        COUNT(DISTINCT blocked_spid) AS victims_count,
        AVG(blocked_wait_time_ms) AS avg_wait_ms,
        MAX(blocked_wait_time_ms) AS max_wait_ms,
        SUM(blocked_wait_time_ms) AS total_wait_ms,
        MIN(event_timestamp) AS first_occurrence,
        MAX(event_timestamp) AS last_occurrence
    FROM ServerOps.Activity_XE_BlockedProcess
    WHERE server_name = @serverParam 
      AND event_timestamp >= @cutoff
    GROUP BY blocked_by_spid, blocked_by_login, blocked_by_database, blocked_by_client_app, blocked_by_host_name, blocked_by_status
),
MostRecent AS (
    SELECT 
        blocked_by_spid,
        blocked_by_login,
        blocked_by_database,
        blocked_by_client_app,
        blocked_by_host_name,
        blocked_by_status,
        blocked_by_query_text,
        ROW_NUMBER() OVER (
            PARTITION BY blocked_by_spid, blocked_by_login, blocked_by_database, blocked_by_client_app, blocked_by_host_name, blocked_by_status
            ORDER BY event_timestamp DESC
        ) AS rn
    FROM ServerOps.Activity_XE_BlockedProcess
    WHERE server_name = @serverParam 
      AND event_timestamp >= @cutoff
)
SELECT 
    a.*,
    m.blocked_by_query_text AS blocker_query_text
FROM Aggregated a
LEFT JOIN MostRecent m ON ISNULL(a.blocked_by_spid,0) = ISNULL(m.blocked_by_spid,0)
    AND ISNULL(a.blocked_by_login,'') = ISNULL(m.blocked_by_login,'')
    AND ISNULL(a.blocked_by_database,'') = ISNULL(m.blocked_by_database,'')
    AND ISNULL(a.blocked_by_client_app,'') = ISNULL(m.blocked_by_client_app,'')
    AND ISNULL(a.blocked_by_host_name,'') = ISNULL(m.blocked_by_host_name,'')
    AND ISNULL(a.blocked_by_status,'') = ISNULL(m.blocked_by_status,'')
    AND m.rn = 1
ORDER BY a.blocking_count DESC, a.max_wait_ms DESC
"@
        $cmd.Parameters.AddWithValue("@serverParam", $serverName) | Out-Null
        $cmd.Parameters.AddWithValue("@minutesParam", [int]$minutes) | Out-Null
        $cmd.CommandTimeout = 30
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        $conn.Close()
        
        $results = @()
        foreach ($row in $dataset.Tables[0].Rows) {
            $results += [PSCustomObject]@{
                blocked_by_spid = if ($row['blocked_by_spid'] -is [DBNull]) { $null } else { [int]$row['blocked_by_spid'] }
                blocked_by_login = if ($row['blocked_by_login'] -is [DBNull]) { $null } else { $row['blocked_by_login'] }
                blocked_by_database = if ($row['blocked_by_database'] -is [DBNull]) { $null } else { $row['blocked_by_database'] }
                blocked_by_client_app = if ($row['blocked_by_client_app'] -is [DBNull]) { $null } else { $row['blocked_by_client_app'] }
                blocked_by_host_name = if ($row['blocked_by_host_name'] -is [DBNull]) { $null } else { $row['blocked_by_host_name'] }
                blocked_by_status = if ($row['blocked_by_status'] -is [DBNull]) { $null } else { $row['blocked_by_status'] }
                blocking_count = [int]$row['blocking_count']
                victims_count = [int]$row['victims_count']
                avg_wait_ms = [long]$row['avg_wait_ms']
                max_wait_ms = [long]$row['max_wait_ms']
                total_wait_ms = [long]$row['total_wait_ms']
                first_occurrence = $row['first_occurrence'].ToString("yyyy-MM-dd HH:mm:ss")
                last_occurrence = $row['last_occurrence'].ToString("yyyy-MM-dd HH:mm:ss")
                blocker_query_text = if ($row['blocker_query_text'] -is [DBNull]) { $null } else { $row['blocker_query_text'] }
            }
        }
        Write-PodeJsonResponse -Value $results
    } catch { Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500 }
}

# API: Blocking Victims Detail (individual victim events for a specific blocker)
Add-PodeRoute -Method Get -Path '/api/server-health/blocking-victims'  -Authentication 'ADLogin' -ScriptBlock {
    try {
        $serverName = $WebEvent.Query['server']; if (-not $serverName) { $serverName = 'AVG-PROD-LSNR' }
        $minutes = $WebEvent.Query['minutes']; if (-not $minutes) { $minutes = 15 }
        $blockerSpid = $WebEvent.Query['blocker_spid']
        
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Application Name=xFACts Control Center;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = @"
DECLARE @cutoff DATETIME = DATEADD(MINUTE, -@minutesParam, GETDATE());

SELECT
    event_id,
    event_timestamp,
    blocked_spid,
    blocked_database,
    blocked_login,
    blocked_client_app,
    blocked_host_name,
    blocked_wait_time_ms,
    blocked_wait_type,
    blocked_wait_resource,
    blocked_query_text
FROM ServerOps.Activity_XE_BlockedProcess
WHERE server_name = @serverParam 
  AND event_timestamp >= @cutoff
  AND (@blockerSpidParam IS NULL OR blocked_by_spid = @blockerSpidParam)
ORDER BY event_timestamp DESC
"@
        $cmd.Parameters.AddWithValue("@serverParam", $serverName) | Out-Null
        $cmd.Parameters.AddWithValue("@minutesParam", [int]$minutes) | Out-Null
        if ($blockerSpid) {
            $cmd.Parameters.AddWithValue("@blockerSpidParam", [int]$blockerSpid) | Out-Null
        } else {
            $cmd.Parameters.AddWithValue("@blockerSpidParam", [DBNull]::Value) | Out-Null
        }
        $cmd.CommandTimeout = 30
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        $conn.Close()
        
        $results = @()
        foreach ($row in $dataset.Tables[0].Rows) {
            $results += [PSCustomObject]@{
                event_id = [long]$row['event_id']
                event_timestamp = $row['event_timestamp'].ToString("yyyy-MM-dd HH:mm:ss")
                blocked_spid = if ($row['blocked_spid'] -is [DBNull]) { $null } else { [int]$row['blocked_spid'] }
                blocked_database = if ($row['blocked_database'] -is [DBNull]) { $null } else { $row['blocked_database'] }
                blocked_login = if ($row['blocked_login'] -is [DBNull]) { $null } else { $row['blocked_login'] }
                blocked_client_app = if ($row['blocked_client_app'] -is [DBNull]) { $null } else { $row['blocked_client_app'] }
                blocked_host_name = if ($row['blocked_host_name'] -is [DBNull]) { $null } else { $row['blocked_host_name'] }
                blocked_wait_time_ms = if ($row['blocked_wait_time_ms'] -is [DBNull]) { $null } else { [long]$row['blocked_wait_time_ms'] }
                blocked_wait_type = if ($row['blocked_wait_type'] -is [DBNull]) { $null } else { $row['blocked_wait_type'] }
                blocked_wait_resource = if ($row['blocked_wait_resource'] -is [DBNull]) { $null } else { $row['blocked_wait_resource'] }
                blocked_query_text = if ($row['blocked_query_text'] -is [DBNull]) { $null } else { $row['blocked_query_text'] }
            }
        }
        Write-PodeJsonResponse -Value $results
    } catch { Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500 }
}

# API: Deadlock Events Detail
Add-PodeRoute -Method Get -Path '/api/server-health/deadlock-detail'  -Authentication 'ADLogin' -ScriptBlock {
    try {
        $serverName = $WebEvent.Query['server']; if (-not $serverName) { $serverName = 'AVG-PROD-LSNR' }
        $minutes = $WebEvent.Query['minutes']; if (-not $minutes) { $minutes = 15 }
        
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Application Name=xFACts Control Center;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = @"
DECLARE @cutoff DATETIME = DATEADD(MINUTE, -@minutesParam, GETDATE());

SELECT
    event_id,
    event_timestamp,
    process_count,
    victim_count,
    deadlock_category,
    victim_spid,
    victim_database,
    victim_login,
    victim_client_app,
    victim_host_name,
    victim_query_text,
    survivor_spid,
    survivor_database,
    survivor_login,
    survivor_client_app,
    survivor_host_name,
    survivor_query_text
FROM ServerOps.Activity_XE_Deadlock
WHERE server_name = @serverParam 
  AND event_timestamp >= @cutoff
ORDER BY event_timestamp DESC
"@
        $cmd.Parameters.AddWithValue("@serverParam", $serverName) | Out-Null
        $cmd.Parameters.AddWithValue("@minutesParam", [int]$minutes) | Out-Null
        $cmd.CommandTimeout = 30
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        $conn.Close()
        
        $results = @()
        foreach ($row in $dataset.Tables[0].Rows) {
            $results += [PSCustomObject]@{
                event_id = [long]$row['event_id']
                event_timestamp = $row['event_timestamp'].ToString("yyyy-MM-dd HH:mm:ss")
                process_count = if ($row['process_count'] -is [DBNull]) { $null } else { [int]$row['process_count'] }
                victim_count = if ($row['victim_count'] -is [DBNull]) { $null } else { [int]$row['victim_count'] }
                deadlock_category = if ($row['deadlock_category'] -is [DBNull]) { $null } else { $row['deadlock_category'] }
                victim_spid = if ($row['victim_spid'] -is [DBNull]) { $null } else { [int]$row['victim_spid'] }
                victim_database = if ($row['victim_database'] -is [DBNull]) { $null } else { $row['victim_database'] }
                victim_login = if ($row['victim_login'] -is [DBNull]) { $null } else { $row['victim_login'] }
                victim_client_app = if ($row['victim_client_app'] -is [DBNull]) { $null } else { $row['victim_client_app'] }
                victim_host_name = if ($row['victim_host_name'] -is [DBNull]) { $null } else { $row['victim_host_name'] }
                victim_query_text = if ($row['victim_query_text'] -is [DBNull]) { $null } else { $row['victim_query_text'] }
                survivor_spid = if ($row['survivor_spid'] -is [DBNull]) { $null } else { [int]$row['survivor_spid'] }
                survivor_database = if ($row['survivor_database'] -is [DBNull]) { $null } else { $row['survivor_database'] }
                survivor_login = if ($row['survivor_login'] -is [DBNull]) { $null } else { $row['survivor_login'] }
                survivor_client_app = if ($row['survivor_client_app'] -is [DBNull]) { $null } else { $row['survivor_client_app'] }
                survivor_host_name = if ($row['survivor_host_name'] -is [DBNull]) { $null } else { $row['survivor_host_name'] }
                survivor_query_text = if ($row['survivor_query_text'] -is [DBNull]) { $null } else { $row['survivor_query_text'] }
            }
        }
        Write-PodeJsonResponse -Value $results
    } catch { Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500 }
}

# API: Linked Server Inbound Detail
Add-PodeRoute -Method Get -Path '/api/server-health/ls-inbound-detail'  -Authentication 'ADLogin' -ScriptBlock {
    try {
        $serverName = $WebEvent.Query['server']; if (-not $serverName) { $serverName = 'AVG-PROD-LSNR' }
        $minutes = $WebEvent.Query['minutes']; if (-not $minutes) { $minutes = 15 }
        
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Application Name=xFACts Control Center;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = @"
DECLARE @cutoff DATETIME = DATEADD(MINUTE, -@minutesParam, GETDATE());

SELECT
    event_id,
    first_event_timestamp,
    last_event_timestamp,
    client_hostname,
    database_name,
    username,
    session_id,
    client_app_name,
    execution_count,
    total_duration_ms,
    max_duration_ms,
    total_cpu_time_ms,
    total_logical_reads,
    total_writes,
    sql_text
FROM ServerOps.Activity_XE_LinkedServerIn
WHERE server_name = @serverParam 
  AND last_event_timestamp >= @cutoff
ORDER BY last_event_timestamp DESC
"@
        $cmd.Parameters.AddWithValue("@serverParam", $serverName) | Out-Null
        $cmd.Parameters.AddWithValue("@minutesParam", [int]$minutes) | Out-Null
        $cmd.CommandTimeout = 30
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        $conn.Close()
        
        $results = @()
        foreach ($row in $dataset.Tables[0].Rows) {
            $results += [PSCustomObject]@{
                event_id = [long]$row['event_id']
                first_event_timestamp = $row['first_event_timestamp'].ToString("yyyy-MM-dd HH:mm:ss")
                last_event_timestamp = $row['last_event_timestamp'].ToString("yyyy-MM-dd HH:mm:ss")
                client_hostname = if ($row['client_hostname'] -is [DBNull]) { $null } else { $row['client_hostname'] }
                database_name = if ($row['database_name'] -is [DBNull]) { $null } else { $row['database_name'] }
                username = if ($row['username'] -is [DBNull]) { $null } else { $row['username'] }
                session_id = if ($row['session_id'] -is [DBNull]) { $null } else { [int]$row['session_id'] }
                client_app_name = if ($row['client_app_name'] -is [DBNull]) { $null } else { $row['client_app_name'] }
                execution_count = if ($row['execution_count'] -is [DBNull]) { 1 } else { [int]$row['execution_count'] }
                total_duration_ms = if ($row['total_duration_ms'] -is [DBNull]) { $null } else { [long]$row['total_duration_ms'] }
                max_duration_ms = if ($row['max_duration_ms'] -is [DBNull]) { $null } else { [long]$row['max_duration_ms'] }
                total_cpu_time_ms = if ($row['total_cpu_time_ms'] -is [DBNull]) { $null } else { [long]$row['total_cpu_time_ms'] }
                total_logical_reads = if ($row['total_logical_reads'] -is [DBNull]) { $null } else { [long]$row['total_logical_reads'] }
                total_writes = if ($row['total_writes'] -is [DBNull]) { $null } else { [long]$row['total_writes'] }
                sql_text = if ($row['sql_text'] -is [DBNull]) { $null } else { $row['sql_text'] }
            }
        }
        Write-PodeJsonResponse -Value $results
    } catch { Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500 }
}

# API: Linked Server Outbound Detail
Add-PodeRoute -Method Get -Path '/api/server-health/ls-outbound-detail'  -Authentication 'ADLogin' -ScriptBlock {
    try {
        $serverName = $WebEvent.Query['server']; if (-not $serverName) { $serverName = 'AVG-PROD-LSNR' }
        $minutes = $WebEvent.Query['minutes']; if (-not $minutes) { $minutes = 15 }
        
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Application Name=xFACts Control Center;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = @"
DECLARE @cutoff DATETIME = DATEADD(MINUTE, -@minutesParam, GETDATE());

SELECT
    event_id,
    first_event_timestamp,
    last_event_timestamp,
    client_hostname,
    database_name,
    username,
    session_id,
    client_app_name,
    execution_count,
    total_duration_ms,
    max_duration_ms,
    total_cpu_time_ms,
    total_logical_reads,
    total_writes,
    sql_text
FROM ServerOps.Activity_XE_LinkedServerOut
WHERE server_name = @serverParam 
  AND last_event_timestamp >= @cutoff
ORDER BY last_event_timestamp DESC
"@
        $cmd.Parameters.AddWithValue("@serverParam", $serverName) | Out-Null
        $cmd.Parameters.AddWithValue("@minutesParam", [int]$minutes) | Out-Null
        $cmd.CommandTimeout = 30
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        $conn.Close()
        
        $results = @()
        foreach ($row in $dataset.Tables[0].Rows) {
            $results += [PSCustomObject]@{
                event_id = [long]$row['event_id']
                first_event_timestamp = $row['first_event_timestamp'].ToString("yyyy-MM-dd HH:mm:ss")
                last_event_timestamp = $row['last_event_timestamp'].ToString("yyyy-MM-dd HH:mm:ss")
                client_hostname = if ($row['client_hostname'] -is [DBNull]) { $null } else { $row['client_hostname'] }
                database_name = if ($row['database_name'] -is [DBNull]) { $null } else { $row['database_name'] }
                username = if ($row['username'] -is [DBNull]) { $null } else { $row['username'] }
                session_id = if ($row['session_id'] -is [DBNull]) { $null } else { [int]$row['session_id'] }
                client_app_name = if ($row['client_app_name'] -is [DBNull]) { $null } else { $row['client_app_name'] }
                execution_count = if ($row['execution_count'] -is [DBNull]) { 1 } else { [int]$row['execution_count'] }
                total_duration_ms = if ($row['total_duration_ms'] -is [DBNull]) { $null } else { [long]$row['total_duration_ms'] }
                max_duration_ms = if ($row['max_duration_ms'] -is [DBNull]) { $null } else { [long]$row['max_duration_ms'] }
                total_cpu_time_ms = if ($row['total_cpu_time_ms'] -is [DBNull]) { $null } else { [long]$row['total_cpu_time_ms'] }
                total_logical_reads = if ($row['total_logical_reads'] -is [DBNull]) { $null } else { [long]$row['total_logical_reads'] }
                total_writes = if ($row['total_writes'] -is [DBNull]) { $null } else { [long]$row['total_writes'] }
                sql_text = if ($row['sql_text'] -is [DBNull]) { $null } else { $row['sql_text'] }
            }
        }
        Write-PodeJsonResponse -Value $results
    } catch { Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500 }
}

# API: AG Health Events Detail
Add-PodeRoute -Method Get -Path '/api/server-health/ag-events-detail'  -Authentication 'ADLogin' -ScriptBlock {
    try {
        $serverName = $WebEvent.Query['server']; if (-not $serverName) { $serverName = 'AVG-PROD-LSNR' }
        $minutes = $WebEvent.Query['minutes']; if (-not $minutes) { $minutes = 15 }
        
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Application Name=xFACts Control Center;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = @"
DECLARE @cutoff DATETIME = DATEADD(MINUTE, -@minutesParam, GETDATE());

SELECT
    event_id,
    event_timestamp,
    event_type,
    availability_group_name,
    availability_replica_name,
    database_name,
    previous_state,
    current_state,
    error_number,
    error_message
FROM ServerOps.Activity_XE_AGHealth
WHERE server_name = @serverParam 
  AND event_timestamp >= @cutoff
ORDER BY event_timestamp DESC
"@
        $cmd.Parameters.AddWithValue("@serverParam", $serverName) | Out-Null
        $cmd.Parameters.AddWithValue("@minutesParam", [int]$minutes) | Out-Null
        $cmd.CommandTimeout = 30
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        $conn.Close()
        
        $results = @()
        foreach ($row in $dataset.Tables[0].Rows) {
            $results += [PSCustomObject]@{
                event_id = [long]$row['event_id']
                event_timestamp = $row['event_timestamp'].ToString("yyyy-MM-dd HH:mm:ss")
                event_type = $row['event_type']
                ag_name = if ($row['availability_group_name'] -is [DBNull]) { $null } else { $row['availability_group_name'] }
                replica_name = if ($row['availability_replica_name'] -is [DBNull]) { $null } else { $row['availability_replica_name'] }
                database_name = if ($row['database_name'] -is [DBNull]) { $null } else { $row['database_name'] }
                previous_state = if ($row['previous_state'] -is [DBNull]) { $null } else { $row['previous_state'] }
                current_state = if ($row['current_state'] -is [DBNull]) { $null } else { $row['current_state'] }
                error_number = if ($row['error_number'] -is [DBNull]) { $null } else { [int]$row['error_number'] }
                error_message = if ($row['error_message'] -is [DBNull]) { $null } else { $row['error_message'] }
            }
        }
        Write-PodeJsonResponse -Value $results
    } catch { Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500 }
}

# API: System Health Events Detail
Add-PodeRoute -Method Get -Path '/api/server-health/system-health-detail'  -Authentication 'ADLogin' -ScriptBlock {
    try {
        $serverName = $WebEvent.Query['server']; if (-not $serverName) { $serverName = 'AVG-PROD-LSNR' }
        $minutes = $WebEvent.Query['minutes']; if (-not $minutes) { $minutes = 15 }
        
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Application Name=xFACts Control Center;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = @"
DECLARE @cutoff DATETIME = DATEADD(MINUTE, -@minutesParam, GETDATE());

SELECT
    event_id,
    event_timestamp,
    event_type,
    session_id,
    error_code,
    calling_api_name,
    client_hostname,
    client_app_name,
    os_error,
    wait_type,
    duration_ms,
    component_type,
    component_state
FROM ServerOps.Activity_XE_SystemHealth
WHERE server_name = @serverParam 
  AND event_timestamp >= @cutoff
ORDER BY event_timestamp DESC
"@
        $cmd.Parameters.AddWithValue("@serverParam", $serverName) | Out-Null
        $cmd.Parameters.AddWithValue("@minutesParam", [int]$minutes) | Out-Null
        $cmd.CommandTimeout = 30
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        $conn.Close()
        
        $results = @()
        foreach ($row in $dataset.Tables[0].Rows) {
            $results += [PSCustomObject]@{
                event_id = [long]$row['event_id']
                event_timestamp = $row['event_timestamp'].ToString("yyyy-MM-dd HH:mm:ss")
                event_type = $row['event_type']
                session_id = if ($row['session_id'] -is [DBNull]) { $null } else { [int]$row['session_id'] }
                error_code = if ($row['error_code'] -is [DBNull]) { $null } else { [int]$row['error_code'] }
                calling_api_name = if ($row['calling_api_name'] -is [DBNull]) { $null } else { $row['calling_api_name'] }
                client_hostname = if ($row['client_hostname'] -is [DBNull]) { $null } else { $row['client_hostname'] }
                client_app_name = if ($row['client_app_name'] -is [DBNull]) { $null } else { $row['client_app_name'] }
                os_error = if ($row['os_error'] -is [DBNull]) { $null } else { [int]$row['os_error'] }
                wait_type = if ($row['wait_type'] -is [DBNull]) { $null } else { $row['wait_type'] }
                duration_ms = if ($row['duration_ms'] -is [DBNull]) { $null } else { [long]$row['duration_ms'] }
                component_type = if ($row['component_type'] -is [DBNull]) { $null } else { $row['component_type'] }
                component_state = if ($row['component_state'] -is [DBNull]) { $null } else { $row['component_state'] }
            }
        }
        Write-PodeJsonResponse -Value $results
    } catch { Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500 }
}

# API: CPU Gauges (live CPU % for all monitored servers - used by mini gauge server selector)
Add-PodeRoute -Method Get -Path '/api/server-health/cpu-gauges'  -Authentication 'ADLogin' -ScriptBlock {
    try {
        # Get active SQL Server list from ServerRegistry
        $xfactsConn = New-Object System.Data.SqlClient.SqlConnection("Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Application Name=xFACts Control Center;")
        $xfactsConn.Open()
        $cmd = $xfactsConn.CreateCommand()
        $cmd.CommandText = @"
SELECT sr.server_id, sr.server_name
FROM dbo.ServerRegistry sr 
WHERE sr.is_active = 1 
  AND sr.server_type = 'SQL_SERVER'
  AND EXISTS (
      SELECT 1 FROM ServerOps.Activity_DMV_Memory m 
      WHERE m.server_id = sr.server_id 
      AND m.snapshot_dttm >= DATEADD(HOUR, -1, GETDATE())
  )
ORDER BY sr.server_id
"@
        $cmd.CommandTimeout = 10
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        $xfactsConn.Close()

        $results = @()
        foreach ($row in $dataset.Tables[0].Rows) {
            $srvName = $row['server_name']
            $cpuPct = $null

            try {
                $srvConn = New-Object System.Data.SqlClient.SqlConnection("Server=$srvName;Database=master;Integrated Security=True;Application Name=xFACts Control Center;Connect Timeout=5;")
                $srvConn.Open()
                $srvCmd = $srvConn.CreateCommand()
                $srvCmd.CommandText = @"
SELECT TOP 1
    record.value('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]','int') AS system_idle,
    record.value('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]','int') AS sql_cpu
FROM (
    SELECT CAST(record AS xml) AS record
    FROM sys.dm_os_ring_buffers
    WHERE ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR'
      AND record LIKE N'%<SystemHealth>%'
) AS x
ORDER BY record.value('(./Record/@id)[1]','int') DESC
"@
                $srvCmd.CommandTimeout = 5
                $srvAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($srvCmd)
                $srvDataset = New-Object System.Data.DataSet
                $srvAdapter.Fill($srvDataset) | Out-Null
                $srvConn.Close()

                if ($srvDataset.Tables[0].Rows.Count -gt 0) {
                    $cpuRow = $srvDataset.Tables[0].Rows[0]
                    $cpuPct = if ($cpuRow['sql_cpu'] -is [DBNull]) { $null } else { [int]$cpuRow['sql_cpu'] }
                }
            }
            catch {
                # Server unreachable - leave cpuPct null
                $cpuPct = $null
            }

            $results += [PSCustomObject]@{
                server_name = $srvName
                cpu_pct = $cpuPct
            }
        }

        Write-PodeJsonResponse -Value $results
    } catch { Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500 }
}

# ============================================================================
# API: Engine Status
# Returns orchestrator process health for Server Health collection processes
# ============================================================================
# ============================================================================
# ENGINE STATUS -- REMOVED
# ============================================================================
# The /api/server-health/engine-status endpoint (~70 lines) was removed.
# Engine indicator cards (DMV, XE, Disk) are now driven by the shared
# engine-events.js WebSocket module via real-time PROCESS_STARTED/COMPLETED
# events from the orchestrator engine.
# See: RealTime_Engine_Events_Architecture.md
# ============================================================================
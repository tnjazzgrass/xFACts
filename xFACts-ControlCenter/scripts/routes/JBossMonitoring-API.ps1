# ============================================================================
# xFACts Control Center - JBoss Monitoring API Endpoints
# Location: E:\xFACts-ControlCenter\scripts\routes\JBossMonitoring-API.ps1
#
# API endpoints for the JBoss Monitoring page.
#
# Version: Tracked in dbo.System_Metadata (component: JBoss)
#
# CHANGELOG
# ---------
# 2026-03-18  Renamed from DmMonitoring-API.ps1. Schema DmOps → JBoss.
#             Tables: App_Snapshot → Snapshot, App_QueueSnapshot → QueueSnapshot.
#             Routes: /api/dm-monitoring/* → /api/jboss-monitoring/*.
#             GlobalConfig module: DmOps → JBoss.
# 2026-03-09  Delta seeding: status endpoint returns two most recent snapshots
#             per server (prev_ fields for delta-relevant counters). Queue-status
#             endpoint returns two most recent cycles per server (prev_messages_added
#             per queue). Enables immediate delta display on page load.
# 2026-03-08  Phase 2: Expanded status endpoint with all Management API
#             columns. Added queue-status and queue-detail endpoints.
#             Removed http_response_bytes (column dropped).
# 2026-03-08  Added GET /api/jboss-monitoring/active-server and
#             POST /api/jboss-monitoring/switch-server (migrated from Admin-API)
# 2026-03-07  Initial implementation — GET /api/jboss-monitoring/status
# ============================================================================

# ============================================================================
# API: Current Server Status (with previous snapshot for delta seeding)
# Returns the latest Snapshot per server with all metrics, plus the
# previous snapshot's delta-relevant fields so the JS can compute deltas
# immediately on page load without waiting for a second collection cycle.
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/jboss-monitoring/status' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $query = @"
;WITH RankedSnaps AS (
    SELECT
        a.*,
        ROW_NUMBER() OVER (PARTITION BY a.server_id ORDER BY a.collected_dttm DESC) AS rn
    FROM JBoss.Snapshot a
    JOIN dbo.ServerRegistry s ON a.server_id = s.server_id
    WHERE s.is_active = 1
      AND s.jboss_enabled = 1
      AND s.server_type = 'APP_SERVER'
)
SELECT
    s.server_id,
    s.server_name,
    s.server_role,
    s.is_domain_controller,
    cur.collected_dttm,
    cur.http_status_code,
    cur.http_response_ms,
    cur.http_error_message,
    cur.service_name,
    cur.service_state,
    cur.service_start_mode,
    cur.jboss_process_id,
    cur.jboss_working_set_mb,
    cur.jboss_thread_count,
    cur.jboss_handle_count,
    cur.server_uptime_hours,
    cur.api_server_state,
    cur.jvm_heap_used_mb,
    cur.jvm_heap_max_mb,
    cur.jvm_nonheap_used_mb,
    cur.jvm_thread_count,
    cur.jvm_thread_peak,
    cur.undertow_request_count,
    cur.undertow_error_count,
    cur.undertow_bytes_sent,
    cur.undertow_processing_ms,
    cur.undertow_max_proc_ms,
    cur.io_worker_queue_size,
    cur.tx_committed,
    cur.tx_inflight,
    cur.tx_timed_out,
    cur.tx_rollbacks,
    cur.tx_aborted,
    cur.tx_heuristics,
    cur.ds_active_count,
    cur.ds_in_use_count,
    cur.ds_idle_count,
    cur.ds_wait_count,
    cur.ds_max_used_count,
    cur.ds_timed_out,
    cur.ds_avg_get_time_ms,
    cur.ds_max_wait_time_ms,
    -- Previous snapshot: only delta-relevant fields
    prev.collected_dttm         AS prev_collected_dttm,
    prev.server_uptime_hours    AS prev_server_uptime_hours,
    prev.tx_committed           AS prev_tx_committed,
    prev.tx_timed_out           AS prev_tx_timed_out,
    prev.tx_rollbacks           AS prev_tx_rollbacks,
    prev.tx_aborted             AS prev_tx_aborted,
    prev.tx_heuristics          AS prev_tx_heuristics,
    prev.undertow_request_count AS prev_undertow_request_count,
    prev.undertow_error_count   AS prev_undertow_error_count,
    prev.undertow_bytes_sent    AS prev_undertow_bytes_sent,
    prev.undertow_processing_ms AS prev_undertow_processing_ms,
    prev.ds_timed_out           AS prev_ds_timed_out
FROM dbo.ServerRegistry s
LEFT JOIN RankedSnaps cur  ON cur.server_id = s.server_id AND cur.rn = 1
LEFT JOIN RankedSnaps prev ON prev.server_id = s.server_id AND prev.rn = 2
WHERE s.is_active = 1
  AND s.jboss_enabled = 1
  AND s.server_type = 'APP_SERVER'
ORDER BY s.server_name
"@
        $results = Invoke-XFActsQuery -Query $query

        # Helper to clean DBNull
        function cv($val) { if ($val -is [DBNull]) { return $null } return $val }
        function ci($val) { if ($val -is [DBNull]) { return $null } return [int]$val }
        function cl($val) { if ($val -is [DBNull]) { return $null } return [long]$val }
        function cd($val) { if ($val -is [DBNull]) { return $null } return [double]::Parse($val.ToString()) }

        $servers = @()
        foreach ($row in @($results)) {
            $obj = [PSCustomObject]@{
                server_id            = ci $row.server_id
                server_name          = cv $row.server_name
                server_role          = cv $row.server_role
                is_domain_controller = [bool]$row.is_domain_controller
                collected_dttm       = if ($row.collected_dttm -is [DBNull]) { $null } else { $row.collected_dttm.ToString("yyyy-MM-dd HH:mm:ss") }
                # HTTP
                http_status_code     = ci $row.http_status_code
                http_response_ms     = ci $row.http_response_ms
                http_error_message   = cv $row.http_error_message
                # CIM Service
                service_name         = cv $row.service_name
                service_state        = cv $row.service_state
                service_start_mode   = cv $row.service_start_mode
                # CIM Process
                jboss_process_id     = ci $row.jboss_process_id
                jboss_working_set_mb = ci $row.jboss_working_set_mb
                jboss_thread_count   = ci $row.jboss_thread_count
                jboss_handle_count   = ci $row.jboss_handle_count
                server_uptime_hours  = if ($row.server_uptime_hours -is [DBNull]) { $null } else { [double]0 + $row.server_uptime_hours }
                # Management API — Server State
                api_server_state     = cv $row.api_server_state
                # Management API — JVM
                jvm_heap_used_mb     = ci $row.jvm_heap_used_mb
                jvm_heap_max_mb      = ci $row.jvm_heap_max_mb
                jvm_nonheap_used_mb  = ci $row.jvm_nonheap_used_mb
                jvm_thread_count     = ci $row.jvm_thread_count
                jvm_thread_peak      = ci $row.jvm_thread_peak
                # Management API — Undertow
                undertow_request_count = cl $row.undertow_request_count
                undertow_error_count   = cl $row.undertow_error_count
                undertow_bytes_sent    = cl $row.undertow_bytes_sent
                undertow_processing_ms = cl $row.undertow_processing_ms
                undertow_max_proc_ms   = cl $row.undertow_max_proc_ms
                # Management API — IO Worker
                io_worker_queue_size = ci $row.io_worker_queue_size
                # Management API — Transactions
                tx_committed         = cl $row.tx_committed
                tx_inflight          = ci $row.tx_inflight
                tx_timed_out         = cl $row.tx_timed_out
                tx_rollbacks         = cl $row.tx_rollbacks
                tx_aborted           = cl $row.tx_aborted
                tx_heuristics        = cl $row.tx_heuristics
                # Management API — Datasource Pool
                ds_active_count      = ci $row.ds_active_count
                ds_in_use_count      = ci $row.ds_in_use_count
                ds_idle_count        = ci $row.ds_idle_count
                ds_wait_count        = ci $row.ds_wait_count
                ds_max_used_count    = ci $row.ds_max_used_count
                ds_timed_out         = cl $row.ds_timed_out
                ds_avg_get_time_ms   = ci $row.ds_avg_get_time_ms
                ds_max_wait_time_ms  = ci $row.ds_max_wait_time_ms
            }

            # Previous snapshot for delta seeding (only included if a previous exists)
            if (-not ($row.prev_collected_dttm -is [DBNull])) {
                $obj | Add-Member -NotePropertyName 'prev_collected_dttm'         -NotePropertyValue ($row.prev_collected_dttm.ToString("yyyy-MM-dd HH:mm:ss"))
                $obj | Add-Member -NotePropertyName 'prev_server_uptime_hours'    -NotePropertyValue $(if ($row.prev_server_uptime_hours -is [DBNull]) { $null } else { [double]0 + $row.prev_server_uptime_hours })
                $obj | Add-Member -NotePropertyName 'prev_tx_committed'           -NotePropertyValue (cl $row.prev_tx_committed)
                $obj | Add-Member -NotePropertyName 'prev_tx_timed_out'           -NotePropertyValue (cl $row.prev_tx_timed_out)
                $obj | Add-Member -NotePropertyName 'prev_tx_rollbacks'           -NotePropertyValue (cl $row.prev_tx_rollbacks)
                $obj | Add-Member -NotePropertyName 'prev_tx_aborted'             -NotePropertyValue (cl $row.prev_tx_aborted)
                $obj | Add-Member -NotePropertyName 'prev_tx_heuristics'          -NotePropertyValue (cl $row.prev_tx_heuristics)
                $obj | Add-Member -NotePropertyName 'prev_undertow_request_count' -NotePropertyValue (cl $row.prev_undertow_request_count)
                $obj | Add-Member -NotePropertyName 'prev_undertow_error_count'   -NotePropertyValue (cl $row.prev_undertow_error_count)
                $obj | Add-Member -NotePropertyName 'prev_undertow_bytes_sent'    -NotePropertyValue (cl $row.prev_undertow_bytes_sent)
                $obj | Add-Member -NotePropertyName 'prev_undertow_processing_ms' -NotePropertyValue (cl $row.prev_undertow_processing_ms)
                $obj | Add-Member -NotePropertyName 'prev_ds_timed_out'           -NotePropertyValue (cl $row.prev_ds_timed_out)
            }

            $servers += $obj
        }

        Write-PodeJsonResponse -Value @{
            servers   = $servers
            timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# API: Queue Status Summary (with previous cycle for delta seeding)
# Returns latest queue snapshot per server plus the previous cycle's
# messages_added values so the JS can compute queue deltas on page load.
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/jboss-monitoring/queue-status' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $query = @"
;WITH RankedCycles AS (
    SELECT
        server_id,
        collected_dttm,
        DENSE_RANK() OVER (PARTITION BY server_id ORDER BY collected_dttm DESC) AS cycle_rank
    FROM JBoss.QueueSnapshot
    GROUP BY server_id, collected_dttm
)
SELECT
    q.server_id,
    q.server_name,
    q.queue_name,
    q.message_count,
    q.delivering_count,
    q.consumer_count,
    q.messages_added,
    q.collected_dttm,
    prev.messages_added  AS prev_messages_added,
    prev.collected_dttm  AS prev_collected_dttm
FROM JBoss.QueueSnapshot q
JOIN RankedCycles rc ON q.server_id = rc.server_id
    AND q.collected_dttm = rc.collected_dttm
    AND rc.cycle_rank = 1
LEFT JOIN JBoss.QueueSnapshot prev ON prev.server_id = q.server_id
    AND prev.queue_name = q.queue_name
    AND prev.collected_dttm = (
        SELECT collected_dttm
        FROM RankedCycles rc2
        WHERE rc2.server_id = q.server_id AND rc2.cycle_rank = 2
    )
ORDER BY q.server_id, q.queue_name
"@
        $results = Invoke-XFActsQuery -Query $query

        $serverQueues = @{}
        foreach ($row in @($results)) {
            $sid = [int]$row.server_id
            if (-not $serverQueues.ContainsKey($sid)) {
                $serverQueues[$sid] = @{
                    server_id   = $sid
                    server_name = $row.server_name
                    collected_dttm = $row.collected_dttm.ToString("yyyy-MM-dd HH:mm:ss")
                    prev_collected_dttm = if ($row.prev_collected_dttm -is [DBNull]) { $null } else { $row.prev_collected_dttm.ToString("yyyy-MM-dd HH:mm:ss") }
                    queues      = @()
                    total_pending = 0
                    queues_backing_up = 0
                }
            }
            $pending = [int]$row.message_count
            $queueObj = [PSCustomObject]@{
                queue_name       = $row.queue_name
                message_count    = $pending
                delivering_count = [int]$row.delivering_count
                consumer_count   = [int]$row.consumer_count
                messages_added   = [long]$row.messages_added
            }
            # Include previous messages_added for delta seeding
            if (-not ($row.prev_messages_added -is [DBNull])) {
                $queueObj | Add-Member -NotePropertyName 'prev_messages_added' -NotePropertyValue ([long]$row.prev_messages_added)
            }

            $serverQueues[$sid].queues += $queueObj
            $serverQueues[$sid].total_pending += $pending
            if ($pending -gt 0) { $serverQueues[$sid].queues_backing_up++ }
        }

        # Convert to array sorted by server_id
        $output = @()
        foreach ($key in ($serverQueues.Keys | Sort-Object)) {
            $s = $serverQueues[$key]
            $output += [PSCustomObject]@{
                server_id          = $s.server_id
                server_name        = $s.server_name
                collected_dttm     = $s.collected_dttm
                prev_collected_dttm = $s.prev_collected_dttm
                total_pending      = $s.total_pending
                queues_backing_up  = $s.queues_backing_up
                queues             = $s.queues
            }
        }

        Write-PodeJsonResponse -Value @{
            servers   = $output
            timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# API: Active Server
# Returns the currently active DM app server (SharePoint link target)
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/jboss-monitoring/active-server' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $result = Invoke-XFActsQuery -Query @"
            SELECT config_id, setting_value
            FROM dbo.GlobalConfig
            WHERE module_name = 'JBoss'
              AND setting_name = 'dm_sharepoint_active_server'
              AND is_active = 1
"@

        if (-not $result -or $result.Count -eq 0) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "DM app server setting not found in GlobalConfig" }) -StatusCode 404
            return
        }

        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            active_server = $result[0].setting_value
            config_id     = $result[0].config_id
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ============================================================================
# API: Switch Server
# Changes the active DM app server — updates firewall, SharePoint, GlobalConfig
# ============================================================================
Add-PodeRoute -Method Post -Path '/api/jboss-monitoring/switch-server' -Authentication 'ADLogin' -ScriptBlock {
    try {
        # Admin check
        $ctx = Get-UserContext -WebEvent $WebEvent
        if (-not $ctx.IsAdmin) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Access denied — admin role required" }) -StatusCode 403
            return
        }
        $user = $ctx.DisplayName

        $body = $WebEvent.Data
        $targetServer = $body.target_server
        $validServers = @('DM-PROD-APP', 'DM-PROD-APP2', 'DM-PROD-APP3')

        if (-not $targetServer) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "target_server is required" }) -StatusCode 400
            return
        }
        if ($targetServer -notin $validServers) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Invalid server. Must be one of: $($validServers -join ', ')" }) -StatusCode 400
            return
        }

        # Get current server from GlobalConfig
        $configResult = Invoke-XFActsQuery -Query @"
            SELECT config_id, setting_value
            FROM dbo.GlobalConfig
            WHERE module_name = 'JBoss'
              AND setting_name = 'dm_sharepoint_active_server'
              AND is_active = 1
"@
        if (-not $configResult -or $configResult.Count -eq 0) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "DM app server setting not found" }) -StatusCode 500
            return
        }

        $configId  = $configResult[0].config_id
        $oldServer = $configResult[0].setting_value

        if ($targetServer -eq $oldServer) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Already set to $targetServer" }) -StatusCode 400
            return
        }

        # ==============================================================
        # Helper: Invoke Palo Alto API with certificate bypass
        # ==============================================================
        function Invoke-PaloAltoAPI {
            param([string]$Uri, [string]$FwApiKey)

            # PowerShell 5.1 cert bypass
            if (-not ([System.Management.Automation.PSTypeName]'TrustAllCertsPolicy').Type) {
                Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) { return true; }
}
"@
            }
            $prevPolicy = [System.Net.ServicePointManager]::CertificatePolicy
            [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy

            try {
                $response = Invoke-WebRequest -Uri $Uri -Method Get -Headers @{ 'X-PAN-KEY' = $FwApiKey } -UseBasicParsing
                [xml]$xml = $response.Content
                if ($xml.response.status -ne 'success') {
                    throw "Firewall API error: $($xml.response.msg)"
                }
                return $xml
            }
            finally {
                [System.Net.ServicePointManager]::CertificatePolicy = $prevPolicy
            }
        }

        # ==============================================================
        # Helper: Set firewall rule enabled/disabled
        # ==============================================================
        function Set-FirewallRule {
            param([string]$Enabled, [string]$FwApiKey)

            $fwHost   = '10.1.10.40'
            $vsys     = 'vsys1'
            $ruleName = 'Enable-Access-Prod-APP'
            $baseUrl  = "https://$fwHost"

            $xpath   = "/config/devices/entry[@name='localhost.localdomain']/vsys/entry[@name='$vsys']/rulebase/security/rules/entry[@name='$ruleName']"
            $element = "<disabled>$Enabled</disabled>"
            $uri     = "$baseUrl/api/?type=config&action=set&key=$([uri]::EscapeDataString($FwApiKey))&xpath=$([uri]::EscapeDataString($xpath))&element=$([uri]::EscapeDataString($element))"

            # Apply the rule change
            Invoke-PaloAltoAPI -Uri $uri -FwApiKey $FwApiKey | Out-Null

            # Commit and wait for completion
            $commitUri = "$baseUrl/api/?type=commit&key=$([uri]::EscapeDataString($FwApiKey))&cmd=<commit></commit>"
            $commitResult = Invoke-PaloAltoAPI -Uri $commitUri -FwApiKey $FwApiKey
            $jobId = $commitResult.response.result.job

            if ($jobId) {
                $maxWait = 300
                $elapsed = 0
                do {
                    Start-Sleep -Seconds 5
                    $elapsed += 5
                    $statusUri = "$baseUrl/api/?type=op&key=$([uri]::EscapeDataString($FwApiKey))&cmd=<show><jobs><id>$jobId</id></jobs></show>"
                    $status = Invoke-PaloAltoAPI -Uri $statusUri -FwApiKey $FwApiKey
                    $jobStatus = $status.response.result.job.status
                    $jobResult = $status.response.result.job.result
                } while ($jobStatus -ne 'FIN' -and $elapsed -lt $maxWait)

                if ($jobStatus -ne 'FIN') {
                    throw "Firewall commit timed out after ${maxWait}s - job $jobId still in status: $jobStatus"
                }
                if ($jobResult -ne 'OK') {
                    throw "Firewall commit job $jobId finished with result: $jobResult"
                }
            }
        }

        # ==============================================================
        # Helper: Get SharePoint OAuth2 access token
        # ==============================================================
        function Get-SharePointAccessToken {
            param([hashtable]$Creds)

            $tokenUrl = "https://accounts.accesscontrol.windows.net/$($Creds.TenantId)/tokens/OAuth/2"
            $body = @{
                grant_type    = 'client_credentials'
                client_id     = "$($Creds.ClientId)@$($Creds.TenantId)"
                client_secret = $Creds.ClientSecret
                resource      = "00000003-0000-0ff1-ce00-000000000000/frostarn.sharepoint.com@$($Creds.TenantId)"
            }

            $tokenResponse = Invoke-RestMethod -Method Post -Uri $tokenUrl -ContentType 'application/x-www-form-urlencoded' -Body $body
            if (-not $tokenResponse.access_token) {
                throw "Failed to obtain SharePoint access token"
            }
            return $tokenResponse.access_token
        }

        # ==============================================================
        # Helper: Update SharePoint navigation node URL
        # ==============================================================
        function Update-SharePointNavNode {
            param([string]$AccessToken, [string]$NewUrl)

            $siteUrl = 'https://frostarn.sharepoint.com'
            $headers = @{
                'Authorization' = "Bearer $AccessToken"
                'Accept'        = 'application/json;odata=verbose'
            }

            # GET all top navigation nodes
            $navResponse = Invoke-RestMethod -Method Get -Uri "$siteUrl/_api/web/navigation/TopNavigationBar" -Headers $headers
            $nodes = $navResponse.d.results

            if (-not $nodes -or $nodes.Count -eq 0) {
                throw "No top navigation nodes found on SharePoint site"
            }

            # Find the "Debt Manager" node
            $dmNode = $nodes | Where-Object { $_.Title -eq 'Debt Manager' }
            if (-not $dmNode) {
                $titles = ($nodes | ForEach-Object { $_.Title }) -join ', '
                throw "Navigation node 'Debt Manager' not found. Available nodes: $titles"
            }

            $nodeId = $dmNode.Id

            # Get request digest for write operations
            $digestResponse = Invoke-RestMethod -Method Post -Uri "$siteUrl/_api/contextinfo" -Headers $headers -ContentType 'application/json;odata=verbose'
            $formDigest = $digestResponse.d.GetContextWebInformation.FormDigestValue

            # Update the node URL using MERGE
            $updateHeaders = @{
                'Authorization'   = "Bearer $AccessToken"
                'Accept'          = 'application/json;odata=verbose'
                'Content-Type'    = 'application/json;odata=verbose'
                'X-RequestDigest' = $formDigest
                'X-HTTP-Method'   = 'MERGE'
                'IF-MATCH'        = '*'
            }

            $updateBody = @{
                '__metadata' = @{ 'type' = 'SP.NavigationNode' }
                'Url'        = $NewUrl
            } | ConvertTo-Json

            Invoke-RestMethod -Method Post -Uri "$siteUrl/_api/web/navigation/GetNodeById($nodeId)" -Headers $updateHeaders -Body $updateBody

            return $nodeId
        }

        # ==============================================================
        # EXECUTION: Firewall + SharePoint + GlobalConfig + Audit
        # ==============================================================

        # PowerShell 5.1 defaults to TLS 1.0 — force TLS 1.2 for all external API calls
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

        $newUrl = "http://$($targetServer.ToLower()).fac.local/CRSServicesWeb/#"

        if ($targetServer -ne 'DM-PROD-APP2') {
            # Switching AWAY from APP2: Enable firewall first, then update SharePoint
            $fwCreds = Get-ServiceCredentials -ServiceName 'PaloAlto'
            Set-FirewallRule -Enabled 'no' -FwApiKey $fwCreds.ApiKey    # disabled=no means ENABLE the rule

            $spCreds = Get-ServiceCredentials -ServiceName 'SharePoint'
            $token = Get-SharePointAccessToken -Creds $spCreds
            Update-SharePointNavNode -AccessToken $token -NewUrl $newUrl
        }
        else {
            # Switching BACK to APP2: Update SharePoint first, then disable firewall
            $spCreds = Get-ServiceCredentials -ServiceName 'SharePoint'
            $token = Get-SharePointAccessToken -Creds $spCreds
            Update-SharePointNavNode -AccessToken $token -NewUrl $newUrl

            $fwCreds = Get-ServiceCredentials -ServiceName 'PaloAlto'
            Set-FirewallRule -Enabled 'yes' -FwApiKey $fwCreds.ApiKey   # disabled=yes means DISABLE the rule
        }

        # Update GlobalConfig
        Invoke-XFActsQuery -Query @"
            UPDATE dbo.GlobalConfig
            SET setting_value = @val
            WHERE config_id = @cid
"@ -Parameters @{ val = $targetServer; cid = [int]$configId }

        # Audit log
        Invoke-XFActsQuery -Query @"
            INSERT INTO dbo.ActionAuditLog
                (page_route, action_type, action_summary, executed_by)
            VALUES
                ('/jboss-monitoring', 'CONFIG_CHANGE', @summary, @user)
"@ -Parameters @{
            summary = "Changed dm_sharepoint_active_server from $oldServer to $targetServer"
            user    = $user
        }

        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            success       = $true
            active_server = $targetServer
            old_server    = $oldServer
            performed_by  = $user
            message       = "DM App Server switched from $oldServer to $targetServer"
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}
<#
.SYNOPSIS
    xFACts - JBoss Application Server Metrics Collection

.DESCRIPTION
    xFACts - JBoss
    Script: Collect-JBossMetrics.ps1
    Version: Tracked in dbo.System_Metadata (component: JBoss)

    Collects health metrics from all JBoss-enabled application servers in
    ServerRegistry and writes results to three tables:

    1. JBoss.Snapshot — One row per server per cycle. Five data sources:
       a. HTTP Responsiveness — Invoke-WebRequest to the DM splash page.
          Primary freeze detection mechanism.
       b. CIM Service State — Win32_Service for DebtManager-Host.
       c. CIM JBoss Process Metrics — Win32_Process for the main java.exe
          (largest by WorkingSetSize): memory, threads, handles.
       d. Server Uptime — Win32_OperatingSystem.LastBootUpTime.
       e. JBoss Management API — Composite REST operations via the domain
          controller for JVM memory/threads, Undertow HTTP stats,
          transactions, IO worker pool, and datasource pool metrics.

    2. JBoss.QueueSnapshot — One row per active JMS queue per server.
       ~18 queues × 3 servers = ~54 rows per cycle.

    3. JBoss.ConfigHistory — Write-on-change only. Tracks JBoss config
       values (pool sizes, thread counts, timeouts). Typically 0 rows per
       cycle after initial baseline capture.

    Each data source is an independent try/catch — partial failures produce
    partial snapshots with NULL for the failed source.

    CHANGELOG
    ---------
    2026-03-18  DS pool alert evaluation (Step 5g)
                Two consecutive ds_in_use_count above per-server threshold
                fires CRITICAL Teams alert via Send-TeamsAlert. Episode
                tracking via ds_alert_fired column on Snapshot. Recovery
                requires two consecutive snapshots with HTTP 200, ds below
                threshold, and positive undertow processing delta.
                jboss_ds_alert_threshold read from ServerRegistry per server.
    2026-03-18  Renamed from Collect-DmHealthMetrics.ps1.
                Schema DmOps → JBoss. Tables: App_Snapshot → Snapshot,
                App_QueueSnapshot → QueueSnapshot, App_ConfigHistory → ConfigHistory.
                ServerRegistry column: dmops_enabled → jboss_enabled.
                GlobalConfig module: DmOps → JBoss.
    2026-03-08  Phase 2 rewrite: Added JBoss Management API collection
                (health composite, queue composite, config change detection).
                Migrated to Initialize-XFActsScript shared infrastructure.
                Added Get-ServiceCredentials for JBoss Management API auth.
                Removed http_response_bytes (column dropped).
    2026-03-07  Initial implementation (HTTP, CIM, uptime only)

.PARAMETER ServerInstance
    SQL Server instance name for xFACts database (default: AVG-PROD-LSNR)

.PARAMETER Database
    Database name (default: xFACts)

.PARAMETER Execute
    Perform writes. Without this flag, runs in preview/dry-run mode.

.PARAMETER Force
    Bypass any checks and run immediately

.PARAMETER TaskId
    Orchestrator TaskLog ID passed by the v2 engine at launch. Used for task
    completion callback. Default 0 (no callback when run manually).

.PARAMETER ProcessId
    Orchestrator ProcessRegistry ID passed by the v2 engine at launch. Used for
    task completion callback. Default 0 (no callback when run manually).

================================================================================
DEPLOYMENT REMINDERS
================================================================================
1. Deployed to E:\xFACts-PowerShell on FA-SQLDBB.
2. The service account (FAC\sqlmon) must have WinRM/CIM access to all three
   JBoss application servers.
3. xFACts-OrchestratorFunctions.ps1 must be in the same directory.
4. JBoss Management API credentials must be stored in dbo.Credentials
   (ServiceName: JBossManagement, ConfigKeys: JBossUser, JBossPassword).
5. Firewall rule: FA-SQLDBB -> dm-prod-app port 9990 must be open.
================================================================================
#>

[CmdletBinding()]
param(
    [string]$ServerInstance = "AVG-PROD-LSNR",
    [string]$Database = "xFACts",
    [switch]$Execute,
    [switch]$Force,
    [long]$TaskId = 0,
    [int]$ProcessId = 0
)

# ============================================================================
# STANDARD INITIALIZATION
# ============================================================================

. "$PSScriptRoot\xFACts-OrchestratorFunctions.ps1"

Initialize-XFActsScript -ScriptName 'Collect-JBossMetrics' `
    -ServerInstance $ServerInstance -Database $Database -Execute:$Execute

$scriptStart = Get-Date

# ============================================================================
# ACTIVE QUEUE LIST
# ============================================================================
# Queues with observed throughput (messages-added > 0) on any server.
# Based on discovery session March 7, 2026. Static list — dynamic discovery
# is a future enhancement.

$ActiveQueues = @(
    'requestQueue'
    'jobBatchQueue'
    'fixedFeeEventQueue'
    'documentOutputRequestQueue'
    'consumerAccountCBRPurgeQueue'
    'consumerCacheRequestQueue'
    'bdlImportPostProcessorQueue'
    'bdlImportStagedDataQueue'
    'scheduleAndSettlementUpdateQueue'
    'paymentsImportPartitionQueue'
    'paymentsPostingPartitionQueue'
    'nbUploadQueue'
    'nbReleaseQueue'
    'nbPostReleaseQueue'
    'brokenPaymentSchedulePartitionQueue'
    'accountInterestAndBalanceUpdateQueue'
    'scheduledRequestQueue'
    'fpRequestQueue'
)

# ============================================================================
# CONFIG SETTINGS TO TRACK
# ============================================================================
# Each entry defines a JBoss config value to monitor for changes.
# address_suffix is appended to the server instance address path.
# profile_level entries read from the profile (shared config) rather than
# the server instance (runtime values).

$ConfigSettings = @(
    @{ Name = 'worker_max_threads';    AddressSuffix = '"subsystem":"io"},{"worker":"default"';     Property = 'task-max-threads' }
    @{ Name = 'io_thread_count';       AddressSuffix = '"subsystem":"io"},{"worker":"default"';     Property = 'io-threads' }
    @{ Name = 'datasource_min_pool';   ProfileLevel = $true; AddressSuffix = '"subsystem":"datasources"},{"data-source":"dataSource"'; Property = 'min-pool-size' }
    @{ Name = 'datasource_max_pool';   ProfileLevel = $true; AddressSuffix = '"subsystem":"datasources"},{"data-source":"dataSource"'; Property = 'max-pool-size' }
    @{ Name = 'jvm_heap_max_mb';       AddressSuffix = '"core-service":"platform-mbean"},{"type":"memory"'; Property = 'heap-memory-usage'; SubProperty = 'max'; ConvertBytesToMB = $true }
    @{ Name = 'transaction_timeout';   AddressSuffix = '"subsystem":"transactions"';                Property = 'default-timeout' }
    @{ Name = 'messaging_min_pool';    ProfileLevel = $true; AddressSuffix = '"subsystem":"messaging-activemq"},{"server":"default"},{"pooled-connection-factory":"hornetq-ra"'; Property = 'min-pool-size' }
    @{ Name = 'messaging_max_pool';    ProfileLevel = $true; AddressSuffix = '"subsystem":"messaging-activemq"},{"server":"default"},{"pooled-connection-factory":"hornetq-ra"'; Property = 'max-pool-size' }
    @{ Name = 'messaging_thread_pool'; ProfileLevel = $true; AddressSuffix = '"subsystem":"messaging-activemq"},{"server":"default"},{"pooled-connection-factory":"hornetq-ra"'; Property = 'thread-pool-max-size' }
)

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

function Get-ConfigValue {
    param([string]$SettingName, [string]$Category = 'App')
    $result = Get-SqlData -Query @"
SELECT setting_value
FROM dbo.GlobalConfig
WHERE module_name = 'JBoss'
  AND category = '$Category'
  AND setting_name = '$SettingName'
  AND is_active = 1
"@
    if ($null -ne $result) { return $result.setting_value }
    return $null
}

function Invoke-JBossAPI {
    <#
    .SYNOPSIS
        Sends a POST request to the JBoss Management API.
    .DESCRIPTION
        Handles JSON POST to the Management API endpoint with credential
        authentication and configurable timeout. Returns the parsed response
        object on success, $null on failure.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Body,
        [Parameter(Mandatory)]
        [string]$ApiUrl,
        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Credential,
        [int]$TimeoutSec = 30
    )

    try {
        $response = Invoke-RestMethod -Uri $ApiUrl -Method Post -Body $Body `
            -Headers @{ 'Content-Type' = 'application/json' } `
            -Credential $Credential -TimeoutSec $TimeoutSec -ErrorAction Stop

        if ($response.outcome -eq 'success') {
            return $response
        }
        else {
            $failDesc = if ($response.'failure-description') { $response.'failure-description' } else { 'Unknown failure' }
            Write-Log "    JBoss API call failed: $failDesc" "WARN"
            return $null
        }
    }
    catch {
        Write-Log "    JBoss API call error: $($_.Exception.Message)" "ERROR"
        return $null
    }
}

# ============================================================================
# MAIN SCRIPT
# ============================================================================

Write-Log "========================================"
Write-Log "xFACts JBoss Metrics Collection"
Write-Log "========================================"

if ($Force) {
    Write-Log "Force flag set - manual execution."
}

# ----------------------------------------
# Step 1: Load configuration
# ----------------------------------------
Write-Log "Loading configuration..."

$httpBasePath = Get-ConfigValue -SettingName 'http_base_path'
if ($null -eq $httpBasePath) {
    $httpBasePath = "/CRSServicesWeb/"
    Write-Log "  http_base_path not found, using default: $httpBasePath" "WARN"
}

$httpTimeoutSec = Get-ConfigValue -SettingName 'http_timeout_seconds'
if ($null -eq $httpTimeoutSec) { $httpTimeoutSec = 10; Write-Log "  http_timeout_seconds not found, using default: $httpTimeoutSec" "WARN" }
$httpTimeoutSec = [int]$httpTimeoutSec

$apiTimeoutSec = Get-ConfigValue -SettingName 'api_timeout_seconds'
if ($null -eq $apiTimeoutSec) { $apiTimeoutSec = 30; Write-Log "  api_timeout_seconds not found, using default: $apiTimeoutSec" "WARN" }
$apiTimeoutSec = [int]$apiTimeoutSec

# Management API URL — try GlobalConfig first, fall back to dynamic lookup
$managementApiUrl = Get-ConfigValue -SettingName 'management_api_url' -Category 'Admin'
if ($null -eq $managementApiUrl) {
    Write-Log "  management_api_url not in GlobalConfig, building from ServerRegistry..." "WARN"
    $dcServer = Get-SqlData -Query @"
SELECT server_name
FROM dbo.ServerRegistry
WHERE is_active = 1
  AND jboss_enabled = 1
  AND is_domain_controller = 1
  AND server_type = 'APP_SERVER'
"@
    if ($null -ne $dcServer) {
        $managementApiUrl = "http://$($dcServer.server_name):9990/management"
        Write-Log "  Built API URL from domain controller: $managementApiUrl"
    }
    else {
        Write-Log "  No domain controller found in ServerRegistry — Management API collection will be skipped" "WARN"
    }
}

Write-Log "  HTTP base path: $httpBasePath"
Write-Log "  HTTP timeout: ${httpTimeoutSec}s"
Write-Log "  API timeout: ${apiTimeoutSec}s"
Write-Log "  Management API URL: $(if ($managementApiUrl) { $managementApiUrl } else { 'NOT CONFIGURED' })"

# ----------------------------------------
# Step 2: Load JBoss credentials
# ----------------------------------------
$jbossCred = $null
if ($null -ne $managementApiUrl) {
    Write-Log "Retrieving JBoss Management credentials..."
    $jbossCreds = Get-ServiceCredentials -ServiceName 'JBossManagement'
    if ($null -ne $jbossCreds -and $jbossCreds.JBossUser -and $jbossCreds.JBossPassword) {
        $secPassword = ConvertTo-SecureString $jbossCreds.JBossPassword -AsPlainText -Force
        $jbossCred = New-Object System.Management.Automation.PSCredential($jbossCreds.JBossUser, $secPassword)
        Write-Log "  JBoss credentials loaded."
    }
    else {
        Write-Log "  Failed to load JBoss credentials — Management API collection will be skipped" "WARN"
        $managementApiUrl = $null
    }
}

# ----------------------------------------
# Step 3: Get list of servers to monitor
# ----------------------------------------
Write-Log "Retrieving server list..."

$servers = Get-SqlData -Query @"
SELECT
    server_id,
    server_name,
    server_role,
    jboss_ds_alert_threshold
FROM dbo.ServerRegistry
WHERE is_active = 1
  AND jboss_enabled = 1
  AND server_type = 'APP_SERVER'
ORDER BY server_id
"@

if ($null -eq $servers -or @($servers).Count -eq 0) {
    Write-Log "No active servers configured for JBoss monitoring. Exiting." "WARN"
    exit 0
}

$serverCount = @($servers).Count
Write-Log "Found $serverCount server(s) to monitor."

# ----------------------------------------
# Step 4: Initialize config change cache
# ----------------------------------------
# Load the most recent config value per server per setting for change detection.
# On first run (empty table), everything will be treated as a new baseline.

$configCache = @{}
if ($null -ne $managementApiUrl) {
    Write-Log "Loading config change detection cache..."
    $existingConfig = Get-SqlData -Query @"
SELECT server_id, setting_name, setting_value
FROM (
    SELECT server_id, setting_name, setting_value,
           ROW_NUMBER() OVER (PARTITION BY server_id, setting_name ORDER BY collected_dttm DESC) AS rn
    FROM JBoss.ConfigHistory
) ranked
WHERE rn = 1
"@
    if ($null -ne $existingConfig) {
        foreach ($row in @($existingConfig)) {
            $cacheKey = "$($row.server_id)|$($row.setting_name)"
            $configCache[$cacheKey] = $row.setting_value
        }
        Write-Log "  Loaded $($configCache.Count) cached config values."
    }
    else {
        Write-Log "  No existing config history — first run will establish baseline."
    }
}

# ----------------------------------------
# Step 5: Collect from each server
# ----------------------------------------
$collectionTime = Get-Date
$successServers = 0
$failedServers = @()
$totalQueueRows = 0
$totalConfigRows = 0
$totalAlertsFired = 0

foreach ($server in @($servers)) {
    $serverName = $server.server_name
    $serverId = $server.server_id
    $serverRole = if ($server.server_role -isnot [DBNull]) { $server.server_role } else { '' }
    $dsAlertThreshold = if ($server.jboss_ds_alert_threshold -isnot [DBNull]) { [int]$server.jboss_ds_alert_threshold } else { 0 }

    Write-Log "Collecting from: $serverName ($serverRole)"

    # Initialize all snapshot values as NULL
    $snap = @{
        http_status_code     = "NULL"; http_response_ms     = "NULL"
        http_error_message   = "NULL"
        service_name         = "NULL"; service_state        = "NULL"; service_start_mode = "NULL"
        jboss_process_id     = "NULL"; jboss_working_set_mb = "NULL"
        jboss_thread_count   = "NULL"; jboss_handle_count   = "NULL"
        server_uptime_hours  = "NULL"
        api_server_state     = "NULL"
        jvm_heap_used_mb     = "NULL"; jvm_heap_max_mb      = "NULL"; jvm_nonheap_used_mb = "NULL"
        jvm_thread_count     = "NULL"; jvm_thread_peak      = "NULL"
        undertow_request_count = "NULL"; undertow_error_count = "NULL"
        undertow_bytes_sent  = "NULL"; undertow_processing_ms = "NULL"; undertow_max_proc_ms = "NULL"
        io_worker_queue_size = "NULL"
        tx_committed         = "NULL"; tx_inflight          = "NULL"; tx_timed_out = "NULL"
        tx_rollbacks         = "NULL"; tx_aborted           = "NULL"; tx_heuristics = "NULL"
        ds_active_count      = "NULL"; ds_in_use_count      = "NULL"; ds_idle_count = "NULL"
        ds_wait_count        = "NULL"; ds_max_used_count    = "NULL"; ds_timed_out  = "NULL"
        ds_avg_get_time_ms   = "NULL"; ds_max_wait_time_ms  = "NULL"
    }

    $serverSuccess = $true

    # ----------------------------------------
    # Step 5a: HTTP Responsiveness
    # ----------------------------------------
    Write-Log "  HTTP responsiveness..."
    $healthUrl = "http://${serverName}.fac.local${httpBasePath}"

    try {
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $response = Invoke-WebRequest -Uri $healthUrl -TimeoutSec $httpTimeoutSec `
            -UseBasicParsing -ErrorAction Stop
        $stopwatch.Stop()

        $snap.http_status_code = $response.StatusCode
        $snap.http_response_ms = $stopwatch.ElapsedMilliseconds

        Write-Log "    Status: $($snap.http_status_code), $($snap.http_response_ms)ms"
    }
    catch {
        $stopwatch.Stop()
        $snap.http_response_ms = $stopwatch.ElapsedMilliseconds

        if ($_.Exception.Response) {
            $snap.http_status_code = [int]$_.Exception.Response.StatusCode
        }

        $errorMsg = $_.Exception.Message -replace "'", "''"
        if ($errorMsg.Length -gt 500) { $errorMsg = $errorMsg.Substring(0, 497) + "..." }
        $snap.http_error_message = "'$errorMsg'"

        Write-Log "    FAILED: $($_.Exception.Message)" "ERROR"
        $serverSuccess = $false
    }

    # ----------------------------------------
    # Step 5b: CIM Collection (service, process, uptime)
    # ----------------------------------------
    Write-Log "  CIM collection..."

    try {
        $session = New-CimSession -ComputerName $serverName -ErrorAction Stop

        # Service state
        $svcName = "DebtManager-Host"
        $svc = Get-CimInstance -CimSession $session -ClassName Win32_Service `
            -Filter "Name='$svcName'" -ErrorAction Stop

        if ($null -ne $svc) {
            $snap.service_name = "'$svcName'"
            $snap.service_state = "'$($svc.State)'"
            $snap.service_start_mode = "'$($svc.StartMode)'"
            Write-Log "    $svcName : $($svc.State) ($($svc.StartMode))"
        }
        else {
            Write-Log "    Service '$svcName' not found" "WARN"
        }

        # JBoss process metrics — largest java.exe by WorkingSetSize
        $javaProcesses = Get-CimInstance -CimSession $session -ClassName Win32_Process `
            -Filter "Name='java.exe'" -ErrorAction Stop

        if ($null -ne $javaProcesses -and @($javaProcesses).Count -gt 0) {
            $mainProcess = @($javaProcesses) | Sort-Object WorkingSetSize -Descending | Select-Object -First 1

            $snap.jboss_process_id = $mainProcess.ProcessId
            $snap.jboss_working_set_mb = [math]::Round($mainProcess.WorkingSetSize / 1MB, 0)
            $snap.jboss_thread_count = $mainProcess.ThreadCount
            $snap.jboss_handle_count = $mainProcess.HandleCount

            Write-Log "    PID: $($snap.jboss_process_id), Memory: $($snap.jboss_working_set_mb) MB, Threads: $($snap.jboss_thread_count), Handles: $($snap.jboss_handle_count)"
        }
        else {
            Write-Log "    No java.exe processes found" "WARN"
            $serverSuccess = $false
        }

        # Server uptime
        $os = Get-CimInstance -CimSession $session -ClassName Win32_OperatingSystem -ErrorAction Stop
        if ($null -ne $os -and $null -ne $os.LastBootUpTime) {
            $uptimeSpan = (Get-Date) - $os.LastBootUpTime
            $snap.server_uptime_hours = [math]::Round($uptimeSpan.TotalHours, 1)
            Write-Log "    Uptime: $($snap.server_uptime_hours) hours"
        }

        Remove-CimSession $session
    }
    catch {
        Write-Log "  CIM collection failed: $($_.Exception.Message)" "ERROR"
        $serverSuccess = $false
        if ($null -ne $session) {
            try { Remove-CimSession $session -ErrorAction SilentlyContinue } catch {}
        }
    }

    # ----------------------------------------
    # Step 5c: Management API — Health Composite
    # ----------------------------------------
    if ($null -ne $managementApiUrl) {
        Write-Log "  Management API health composite..."

        # JBoss domain controller uses lowercase hostnames in address paths
        $jbossHost = $serverName.ToLower()
        $inst = "${jbossHost}-inst1"

        # Hand-built JSON — PowerShell 5.1 ConvertTo-Json does not reliably
        # serialize the nested array-of-objects address format JBoss requires.
        $healthBody = @"
{
    "operation": "composite",
    "address": [],
    "steps": [
        {
            "operation": "read-attribute",
            "address": [{"host":"$jbossHost"},{"server":"$inst"}],
            "name": "server-state"
        },
        {
            "operation": "read-resource",
            "address": [{"host":"$jbossHost"},{"server":"$inst"},{"core-service":"platform-mbean"},{"type":"memory"}],
            "include-runtime": true
        },
        {
            "operation": "read-resource",
            "address": [{"host":"$jbossHost"},{"server":"$inst"},{"core-service":"platform-mbean"},{"type":"threading"}],
            "include-runtime": true
        },
        {
            "operation": "read-resource",
            "address": [{"host":"$jbossHost"},{"server":"$inst"},{"subsystem":"datasources"},{"data-source":"dataSource"},{"statistics":"pool"}],
            "include-runtime": true
        },
        {
            "operation": "read-resource",
            "address": [{"host":"$jbossHost"},{"server":"$inst"},{"subsystem":"undertow"},{"server":"default-server"},{"http-listener":"http"}],
            "include-runtime": true
        },
        {
            "operation": "read-resource",
            "address": [{"host":"$jbossHost"},{"server":"$inst"},{"subsystem":"transactions"}],
            "include-runtime": true
        },
        {
            "operation": "read-resource",
            "address": [{"host":"$jbossHost"},{"server":"$inst"},{"subsystem":"io"},{"worker":"default"}],
            "include-runtime": true
        }
    ]
}
"@

        $healthResult = Invoke-JBossAPI -Body $healthBody -ApiUrl $managementApiUrl `
            -Credential $jbossCred -TimeoutSec $apiTimeoutSec

        if ($null -ne $healthResult) {
            $steps = $healthResult.result

            # Step 1: Server state
            $s1 = $steps.'step-1'
            if ($s1 -and $s1.outcome -eq 'success') {
                $snap.api_server_state = "'$($s1.result)'"
            }

            # Step 2: JVM Memory
            $s2 = $steps.'step-2'
            if ($s2 -and $s2.outcome -eq 'success') {
                $heap = $s2.result.'heap-memory-usage'
                $nonheap = $s2.result.'non-heap-memory-usage'
                if ($null -ne $heap) {
                    $snap.jvm_heap_used_mb = [math]::Round($heap.used / 1MB, 0)
                    $snap.jvm_heap_max_mb = [math]::Round($heap.max / 1MB, 0)
                }
                if ($null -ne $nonheap) {
                    $snap.jvm_nonheap_used_mb = [math]::Round($nonheap.used / 1MB, 0)
                }
            }

            # Step 3: JVM Threads
            $s3 = $steps.'step-3'
            if ($s3 -and $s3.outcome -eq 'success') {
                $snap.jvm_thread_count = $s3.result.'thread-count'
                $snap.jvm_thread_peak = $s3.result.'peak-thread-count'
            }

            # Step 4: Datasource Pool
            $s4 = $steps.'step-4'
            if ($s4 -and $s4.outcome -eq 'success') {
                $snap.ds_active_count    = $s4.result.ActiveCount
                $snap.ds_in_use_count    = $s4.result.InUseCount
                $snap.ds_idle_count      = $s4.result.IdleCount
                $snap.ds_wait_count      = $s4.result.WaitCount
                $snap.ds_max_used_count  = $s4.result.MaxUsedCount
                $snap.ds_timed_out       = $s4.result.TimedOut
                $snap.ds_avg_get_time_ms = $s4.result.AverageGetTime
                $snap.ds_max_wait_time_ms = $s4.result.MaxWaitTime
            }

            # Step 5: Undertow HTTP
            $s5 = $steps.'step-5'
            if ($s5 -and $s5.outcome -eq 'success') {
                $snap.undertow_request_count = $s5.result.'request-count'
                $snap.undertow_error_count   = $s5.result.'error-count'
                $snap.undertow_bytes_sent    = $s5.result.'bytes-sent'
                $snap.undertow_processing_ms = $s5.result.'processing-time'
                $snap.undertow_max_proc_ms   = $s5.result.'max-processing-time'
            }

            # Step 6: Transactions
            $s6 = $steps.'step-6'
            if ($s6 -and $s6.outcome -eq 'success') {
                $snap.tx_committed  = $s6.result.'number-of-committed-transactions'
                $snap.tx_inflight   = $s6.result.'number-of-inflight-transactions'
                $snap.tx_timed_out  = $s6.result.'number-of-timed-out-transactions'
                $snap.tx_rollbacks  = $s6.result.'number-of-application-rollbacks'
                $snap.tx_aborted    = $s6.result.'number-of-aborted-transactions'
                $snap.tx_heuristics = $s6.result.'number-of-heuristics'
            }

            # Step 7: IO Worker
            $s7 = $steps.'step-7'
            if ($s7 -and $s7.outcome -eq 'success') {
                $snap.io_worker_queue_size = $s7.result.'queue-size'
            }

            Write-Log "    Health composite collected successfully."
        }
        else {
            Write-Log "    Health composite failed — API columns will be NULL" "WARN"
        }
    }

    # ----------------------------------------
    # Step 5d: Insert Snapshot
    # ----------------------------------------
    $insertQuery = @"
INSERT INTO JBoss.Snapshot
    (server_id, server_name, collected_dttm,
     http_status_code, http_response_ms, http_error_message,
     service_name, service_state, service_start_mode,
     jboss_process_id, jboss_working_set_mb, jboss_thread_count, jboss_handle_count,
     server_uptime_hours,
     api_server_state,
     jvm_heap_used_mb, jvm_heap_max_mb, jvm_nonheap_used_mb,
     jvm_thread_count, jvm_thread_peak,
     undertow_request_count, undertow_error_count, undertow_bytes_sent,
     undertow_processing_ms, undertow_max_proc_ms,
     io_worker_queue_size,
     tx_committed, tx_inflight, tx_timed_out, tx_rollbacks, tx_aborted, tx_heuristics,
     ds_active_count, ds_in_use_count, ds_idle_count, ds_wait_count,
     ds_max_used_count, ds_timed_out, ds_avg_get_time_ms, ds_max_wait_time_ms)
VALUES
    ($serverId, '$serverName', '$($collectionTime.ToString("yyyy-MM-dd HH:mm:ss"))',
     $($snap.http_status_code), $($snap.http_response_ms), $($snap.http_error_message),
     $($snap.service_name), $($snap.service_state), $($snap.service_start_mode),
     $($snap.jboss_process_id), $($snap.jboss_working_set_mb), $($snap.jboss_thread_count), $($snap.jboss_handle_count),
     $($snap.server_uptime_hours),
     $($snap.api_server_state),
     $($snap.jvm_heap_used_mb), $($snap.jvm_heap_max_mb), $($snap.jvm_nonheap_used_mb),
     $($snap.jvm_thread_count), $($snap.jvm_thread_peak),
     $($snap.undertow_request_count), $($snap.undertow_error_count), $($snap.undertow_bytes_sent),
     $($snap.undertow_processing_ms), $($snap.undertow_max_proc_ms),
     $($snap.io_worker_queue_size),
     $($snap.tx_committed), $($snap.tx_inflight), $($snap.tx_timed_out), $($snap.tx_rollbacks), $($snap.tx_aborted), $($snap.tx_heuristics),
     $($snap.ds_active_count), $($snap.ds_in_use_count), $($snap.ds_idle_count), $($snap.ds_wait_count),
     $($snap.ds_max_used_count), $($snap.ds_timed_out), $($snap.ds_avg_get_time_ms), $($snap.ds_max_wait_time_ms))
"@

    if ($Execute) {
        $result = Invoke-SqlNonQuery -Query $insertQuery
        if ($result) {
            Write-Log "  Snapshot inserted." "SUCCESS"
        }
        else {
            Write-Log "  Failed to insert Snapshot." "ERROR"
            $serverSuccess = $false
        }
    }
    else {
        Write-Log "  [Preview] Would insert Snapshot for $serverName"
    }

    # ----------------------------------------
    # Step 5e: Management API — Queue Composite
    # ----------------------------------------
    if ($null -ne $managementApiUrl -and $null -ne $healthResult) {
        Write-Log "  Management API queue composite..."

        # Build composite steps for all active queues
        $queueSteps = @()
        foreach ($qName in $ActiveQueues) {
            $queueSteps += @"
        {
            "operation": "read-resource",
            "address": [{"host":"$jbossHost"},{"server":"$inst"},{"subsystem":"messaging-activemq"},{"server":"default"},{"jms-queue":"$qName"}],
            "include-runtime": true
        }
"@
        }
        $queueStepsJson = $queueSteps -join ",`n"

        $queueBody = @"
{
    "operation": "composite",
    "address": [],
    "steps": [
$queueStepsJson
    ]
}
"@

        $queueResult = Invoke-JBossAPI -Body $queueBody -ApiUrl $managementApiUrl `
            -Credential $jbossCred -TimeoutSec $apiTimeoutSec

        if ($null -ne $queueResult) {
            $queueInsertCount = 0

            for ($i = 0; $i -lt $ActiveQueues.Count; $i++) {
                $stepKey = "step-$($i + 1)"
                $step = $queueResult.result.$stepKey

                if ($null -ne $step -and $step.outcome -eq 'success') {
                    $qName = $ActiveQueues[$i]
                    $msgCount = $step.result.'message-count'
                    $delCount = $step.result.'delivering-count'
                    $conCount = $step.result.'consumer-count'
                    $msgAdded = $step.result.'messages-added'

                    $qInsert = @"
INSERT INTO JBoss.QueueSnapshot
    (server_id, server_name, queue_name, message_count, delivering_count, consumer_count, messages_added, collected_dttm)
VALUES
    ($serverId, '$serverName', '$qName', $msgCount, $delCount, $conCount, $msgAdded, '$($collectionTime.ToString("yyyy-MM-dd HH:mm:ss"))')
"@
                    if ($Execute) {
                        if (Invoke-SqlNonQuery -Query $qInsert) {
                            $queueInsertCount++
                        }
                    }
                    else {
                        $queueInsertCount++
                    }
                }
            }

            $totalQueueRows += $queueInsertCount
            Write-Log "  Queue snapshots: $queueInsertCount rows$(if (-not $Execute) { ' [Preview]' })" "SUCCESS"
        }
        else {
            Write-Log "  Queue composite failed — no queue data for $serverName" "WARN"
        }
    }

    # ----------------------------------------
    # Step 5f: Management API — Config Composite
    # ----------------------------------------
    # One composite call per server with all 9 config settings as steps.
    # Steps mix profile-level and server-instance-level address paths —
    # JBoss composites support mixed addresses in the same request.

    if ($null -ne $managementApiUrl -and $null -ne $healthResult) {
        Write-Log "  Config change detection..."

        $configChanges = 0

        # Build composite steps for all config settings
        $configSteps = @()
        foreach ($setting in $ConfigSettings) {
            if ($setting.ProfileLevel) {
                $addr = "[{`"profile`":`"full-ha`"},{$($setting.AddressSuffix)}]"
            }
            else {
                $addr = "[{`"host`":`"$jbossHost`"},{`"server`":`"$inst`"},{$($setting.AddressSuffix)}]"
            }
            $configSteps += "        {`"operation`":`"read-attribute`",`"address`":$addr,`"name`":`"$($setting.Property)`"}"
        }
        $configStepsJson = $configSteps -join ",`n"

        $configBody = @"
{
    "operation": "composite",
    "address": [],
    "steps": [
$configStepsJson
    ]
}
"@

        $configResult = Invoke-JBossAPI -Body $configBody -ApiUrl $managementApiUrl `
            -Credential $jbossCred -TimeoutSec $apiTimeoutSec

        if ($null -ne $configResult) {
            for ($i = 0; $i -lt $ConfigSettings.Count; $i++) {
                $setting = $ConfigSettings[$i]
                $settingName = $setting.Name
                $stepKey = "step-$($i + 1)"
                $step = $configResult.result.$stepKey

                if ($null -ne $step -and $step.outcome -eq 'success') {
                    $currentValue = $step.result

                    # Handle nested property (e.g., heap-memory-usage.max)
                    if ($setting.SubProperty) {
                        $currentValue = $currentValue.$($setting.SubProperty)
                    }

                    # Convert bytes to MB if specified
                    if ($setting.ConvertBytesToMB -and $null -ne $currentValue) {
                        $currentValue = [math]::Round([long]$currentValue / 1MB, 0)
                    }

                    $currentValueStr = [string]$currentValue

                    # Compare against cached value
                    $cacheKey = "$serverId|$settingName"
                    $previousValue = $configCache[$cacheKey]

                    if ($null -eq $previousValue -or $previousValue -ne $currentValueStr) {
                        # Change detected (or first capture)
                        $prevSql = if ($null -eq $previousValue) { "NULL" } else { "'$($previousValue -replace "'", "''")'" }

                        $configInsert = @"
INSERT INTO JBoss.ConfigHistory
    (server_id, server_name, setting_name, setting_value, previous_value, collected_dttm)
VALUES
    ($serverId, '$serverName', '$settingName', '$($currentValueStr -replace "'", "''")', $prevSql, '$($collectionTime.ToString("yyyy-MM-dd HH:mm:ss"))')
"@
                        if ($Execute) {
                            if (Invoke-SqlNonQuery -Query $configInsert) {
                                $configChanges++
                                $configCache[$cacheKey] = $currentValueStr
                            }
                        }
                        else {
                            $configChanges++
                            $configCache[$cacheKey] = $currentValueStr
                        }

                        $changeType = if ($null -eq $previousValue) { "baseline" } else { "changed from $previousValue" }
                        Write-Log "    $settingName = $currentValueStr ($changeType)"
                    }
                }
                else {
                    Write-Log "    Config step failed for $settingName" "WARN"
                }
            }
        }
        else {
            Write-Log "  Config composite failed — no config data for $serverName" "WARN"
        }

        $totalConfigRows += $configChanges
        if ($configChanges -gt 0) {
            Write-Log "  Config changes detected: $configChanges$(if (-not $Execute) { ' [Preview]' })"
        }
        else {
            Write-Log "  No config changes detected."
        }
    }

    # ----------------------------------------
    # Step 5g: Alert Evaluation — DS Pool Elevation
    # ----------------------------------------
    # Fires a CRITICAL Teams alert when two consecutive snapshots show
    # ds_in_use_count at or above the per-server threshold. Episode tracking
    # via ds_alert_fired column prevents duplicate alerts during an ongoing
    # event. Recovery requires two consecutive snapshots where all three
    # conditions are met: HTTP 200, ds_in_use below threshold, and positive
    # undertow_processing_ms delta (NULL delta does not count as positive).

    if ($dsAlertThreshold -gt 0 -and $Execute) {
        # Get the three most recent snapshots for this server to evaluate:
        # Row 1 = current (just inserted), Row 2 = previous, Row 3 = the one before that
        $recentSnaps = Get-SqlData -Query @"
SELECT TOP 3
    snapshot_id,
    ds_in_use_count,
    ds_alert_fired,
    http_status_code,
    undertow_processing_ms
FROM JBoss.Snapshot
WHERE server_id = $serverId
  AND ds_in_use_count IS NOT NULL
ORDER BY collected_dttm DESC
"@

        if ($null -ne $recentSnaps -and @($recentSnaps).Count -ge 2) {
            $current  = @($recentSnaps)[0]
            $previous = @($recentSnaps)[1]
            $beforePrev = if (@($recentSnaps).Count -ge 3) { @($recentSnaps)[2] } else { $null }

            $currentDS  = [int]$current.ds_in_use_count
            $previousDS = [int]$previous.ds_in_use_count
            $currentSnapshotId = $current.snapshot_id

            # ── Check if we're in an open alert episode ──
            $inEpisode = [bool]$previous.ds_alert_fired

            if ($currentDS -ge $dsAlertThreshold -and $previousDS -ge $dsAlertThreshold) {
                # Two consecutive above threshold

                if (-not $inEpisode) {
                    # ── NEW EPISODE — fire alert ──
                    Write-Log "  ALERT: DS pool elevation detected on $serverName ($currentDS / $dsAlertThreshold)" "WARN"

                    # Calculate undertow delta percentage for the alert message
                    $undertowPctText = 'N/A'
                    if ($null -ne $current.undertow_processing_ms -and $current.undertow_processing_ms -isnot [DBNull] -and
                        $null -ne $previous.undertow_processing_ms -and $previous.undertow_processing_ms -isnot [DBNull] -and
                        $null -ne $beforePrev -and
                        $null -ne $beforePrev.undertow_processing_ms -and $beforePrev.undertow_processing_ms -isnot [DBNull]) {

                        $currentDelta = [long]$current.undertow_processing_ms - [long]$previous.undertow_processing_ms
                        $priorDelta   = [long]$previous.undertow_processing_ms - [long]$beforePrev.undertow_processing_ms

                        if ($priorDelta -gt 0) {
                            $pctChange = [math]::Round((($currentDelta - $priorDelta) / $priorDelta) * 100, 0)
                            $undertowPctText = "${pctChange}%"
                        }
                    }

                    # HTTP status for alert message
                    $httpText = if ($null -ne $current.http_status_code -and $current.http_status_code -isnot [DBNull]) {
                        "Responding ($($snap.http_response_ms)ms)"
                    } else {
                        "Not Responding"
                    }

                    $detectionTime = $collectionTime.ToString("yyyy-MM-dd HH:mm:ss")

                    $alertTitle = "{{FIRE}} APPLICATION SERVER FAILURE EVENT"
                    $alertMessage = @"
A potential server failure event has been detected on **$serverName**
Confirm application availability immediately

**$detectionTime**
DS Pool: Above threshold ($currentDS / $dsAlertThreshold)
HTTP: $httpText
Undertow: Falling ($undertowPctText)
"@

                    $alertResult = Send-TeamsAlert `
                        -SourceModule 'JBoss' `
                        -AlertCategory 'CRITICAL' `
                        -Title $alertTitle `
                        -Message $alertMessage `
                        -Color 'attention' `
                        -TriggerType 'JBoss_DSPoolElevation' `
                        -TriggerValue "${serverName}_${detectionTime}"

                    if ($alertResult) {
                        $totalAlertsFired++
                    }
                }
                else {
                    Write-Log "  DS pool elevated on $serverName ($currentDS) — episode already open, skipping alert" "DEBUG"
                }

                # Mark current snapshot as part of the episode
                Invoke-SqlNonQuery -Query @"
UPDATE JBoss.Snapshot
SET ds_alert_fired = 1
WHERE snapshot_id = $currentSnapshotId
"@ | Out-Null

            }
            elseif ($inEpisode) {
                # ── Episode is open — check for recovery or mark ongoing ──

                # Recovery condition: HTTP 200, ds below threshold, undertow delta positive
                # Must be true for BOTH current and previous snapshots (two consecutive)

                # Current snapshot recovery check
                $curHttpOk = ($null -ne $current.http_status_code -and $current.http_status_code -isnot [DBNull] -and [int]$current.http_status_code -eq 200)
                $curDsOk   = ($currentDS -lt $dsAlertThreshold)
                $curUndertowOk = $false
                if ($null -ne $current.undertow_processing_ms -and $current.undertow_processing_ms -isnot [DBNull] -and
                    $null -ne $previous.undertow_processing_ms -and $previous.undertow_processing_ms -isnot [DBNull]) {
                    $curUndertowDelta = [long]$current.undertow_processing_ms - [long]$previous.undertow_processing_ms
                    $curUndertowOk = ($curUndertowDelta -gt 0)
                }

                # Previous snapshot recovery check
                $prevHttpOk = ($null -ne $previous.http_status_code -and $previous.http_status_code -isnot [DBNull] -and [int]$previous.http_status_code -eq 200)
                $prevDsOk   = ($previousDS -lt $dsAlertThreshold)
                $prevUndertowOk = $false
                if ($null -ne $beforePrev -and
                    $null -ne $previous.undertow_processing_ms -and $previous.undertow_processing_ms -isnot [DBNull] -and
                    $null -ne $beforePrev.undertow_processing_ms -and $beforePrev.undertow_processing_ms -isnot [DBNull]) {
                    $prevUndertowDelta = [long]$previous.undertow_processing_ms - [long]$beforePrev.undertow_processing_ms
                    $prevUndertowOk = ($prevUndertowDelta -gt 0)
                }

                if ($curHttpOk -and $curDsOk -and $curUndertowOk -and $prevHttpOk -and $prevDsOk -and $prevUndertowOk) {
                    # Two consecutive recovery snapshots — episode over
                    Write-Log "  DS pool alert episode CLOSED on $serverName — recovery confirmed" "SUCCESS"
                    # Current snapshot stays at ds_alert_fired = 0 (default)
                }
                else {
                    # Still in episode — mark current snapshot
                    Invoke-SqlNonQuery -Query @"
UPDATE JBoss.Snapshot
SET ds_alert_fired = 1
WHERE snapshot_id = $currentSnapshotId
"@ | Out-Null
                    Write-Log "  DS pool alert episode ongoing on $serverName (ds_in_use: $currentDS)" "DEBUG"
                }
            }
        }
    }
    elseif ($dsAlertThreshold -gt 0 -and -not $Execute) {
        Write-Log "  [Preview] DS pool alert evaluation skipped (preview mode)"
    }

    # Track success/failure
    if ($serverSuccess) {
        $successServers++
    }
    else {
        $failedServers += $serverName
    }
}

# ----------------------------------------
# Summary
# ----------------------------------------
Write-Log "========================================"
Write-Log "Collection Complete$(if (-not $Execute) { ' [PREVIEW]' })"
Write-Log "  Servers attempted: $serverCount"
Write-Log "  Servers successful: $successServers"
Write-Log "  Servers failed: $($failedServers.Count)"
Write-Log "  Queue snapshot rows: $totalQueueRows"
Write-Log "  Config change rows: $totalConfigRows"
Write-Log "  Alerts fired: $totalAlertsFired"
Write-Log "========================================"

if ($failedServers.Count -gt 0) {
    Write-Log "Failed servers: $($failedServers -join ', ')" "WARN"
}

# ----------------------------------------
# Orchestrator Callback
# ----------------------------------------
if ($TaskId -gt 0) {
    $totalMs = [int]((New-TimeSpan -Start $scriptStart -End (Get-Date)).TotalMilliseconds)
    $outputMsg = "Servers: $successServers/$serverCount, Queues: $totalQueueRows rows, Config: $totalConfigRows changes, Alerts: $totalAlertsFired"
    if ($failedServers.Count -gt 0) {
        $outputMsg += " (failed: $($failedServers -join ', '))"
    }
    Complete-OrchestratorTask -TaskId $TaskId -ProcessId $ProcessId `
        -Status $(if ($failedServers.Count -eq 0) { "SUCCESS" } else { "PARTIAL" }) `
        -DurationMs $totalMs `
        -Output $outputMsg
}

exit 0
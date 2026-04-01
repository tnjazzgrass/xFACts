<#
.SYNOPSIS
    xFACts - Server Health Collection

.DESCRIPTION
    xFACts - ServerOps.Disk
    Script: Collect-ServerHealth.ps1
    Version: Tracked in dbo.System_Metadata (component: ServerOps.Disk)

    Collects disk space metrics from all registered servers via CIM/WinRM
    and inserts into xFACts.ServerOps.Disk_Snapshot for threshold monitoring.

    For SQL Server instances, also captures service start time from
    sys.dm_os_sys_info to enable intelligent DMV freshness weighting.

    After collection, evaluates disk thresholds and creates Jira tickets
    for IT Operations when drives fall below configured thresholds. Includes
    auto-creation of threshold config for new drives, deduplication via
    Disk_AlertHistory, and auto-resolution when drives recover.

    CHANGELOG
    ---------
    2026-03-10  Migrated to Initialize-XFActsScript shared infrastructure
                Removed inline Write-Log, Get-SqlData, Invoke-SqlNonQuery
                Updated header to component-level versioning format
    2026-02-06  Consolidated sp_Disk_Monitor functionality
                Added threshold evaluation, auto-create Disk_ThresholdConfig
                Added Jira ticket creation for threshold breaches
                Added auto-resolution with hysteresis buffer
                Added Disk_Status poll metrics update with daily counter reset
    2026-02-03  Orchestrator v2 integration
                Added -Execute, -TaskId, -ProcessId parameters
                Added orchestrator callback for fire-and-forget tracking
                Relocated to E:\xFACts-PowerShell
    2026-01-23  Registry migrated to dbo.ServerRegistry
                serverops_disk_enabled flag, Disk_Status rename
    2025-12-28  Added SQL Server service start time capture
                Added named instance support via instance_name column
    2025-12-27  Updated table references to Disk_ prefix
                Removed is_enabled check (ProcessRegistry handles this)
    2025-12-23  Initial implementation
                Centralized disk space collection via CIM

.PARAMETER ServerInstance
    SQL Server instance name for xFACts database (default: AVG-PROD-LSNR)

.PARAMETER Database
    Database name (default: xFACts)

.PARAMETER FrequencyMinutes
    Minimum minutes between collections (default: 60)

.PARAMETER Force
    Bypass frequency check and run immediately

.PARAMETER Execute
    Perform writes. Without this flag, runs in preview/dry-run mode.

.PARAMETER TaskId
    Orchestrator TaskLog ID passed by the v2 engine at launch. Used for task
    completion callback. Default 0 (no callback when run manually).

.PARAMETER ProcessId
    Orchestrator ProcessRegistry ID passed by the v2 engine at launch. Used for
    task completion callback. Default 0 (no callback when run manually).

================================================================================
DEPLOYMENT REMINDERS
================================================================================
1. This is deployed in an Availability Group - ensure this script is placed
   on both servers in the appropriate folder.
2. The SQL Agent service account must have admin rights on all monitored servers.
3. The SQL Agent service account must have SQL access to all monitored SQL instances.
4. xFACts-OrchestratorFunctions.ps1 must be in the same directory.
================================================================================
#>

[CmdletBinding()]
param(
    [string]$ServerInstance = "AVG-PROD-LSNR",
    [string]$Database = "xFACts",
    [int]$FrequencyMinutes = 60,
    [switch]$Force,
    [switch]$Execute,
    [long]$TaskId = 0,
    [int]$ProcessId = 0
)

# ============================================================================
# STANDARD INITIALIZATION
# ============================================================================

. "$PSScriptRoot\xFACts-OrchestratorFunctions.ps1"

Initialize-XFActsScript -ScriptName 'Collect-ServerHealth' `
    -ServerInstance $ServerInstance -Database $Database -Execute:$Execute

# ============================================================================
# FUNCTIONS
# ============================================================================

function Get-SqlInstanceName {
    <#
    .SYNOPSIS
        Builds the SQL Server instance connection string from server name and optional instance name
    #>
    param(
        [string]$ServerName,
        [string]$InstanceName
    )

    if ([string]::IsNullOrWhiteSpace($InstanceName)) {
        return $ServerName
    }
    else {
        return "$ServerName\$InstanceName"
    }
}

function Get-SqlServiceStartTime {
    <#
    .SYNOPSIS
        Retrieves the SQL Server service start time from a remote instance
    .RETURNS
        DateTime if successful, $null if failed
    #>
    param(
        [string]$SqlInstanceName
    )

    try {
        $result = Invoke-Sqlcmd -ServerInstance $SqlInstanceName -Query "SELECT sqlserver_start_time FROM sys.dm_os_sys_info" -ConnectionTimeout 10 -SuppressProviderContextWarning -ApplicationName $script:XFActsAppName -ErrorAction Stop -TrustServerCertificate

        if ($null -ne $result -and $result.sqlserver_start_time -isnot [DBNull]) {
            return [DateTime]$result.sqlserver_start_time
        }
        return $null
    }
    catch {
        Write-Log "    Failed to get service start time from ${SqlInstanceName}: $($_.Exception.Message)" "WARN"
        return $null
    }
}

# ============================================================================
# MAIN SCRIPT
# ============================================================================

Write-Log "========================================"
Write-Log "xFACts Server Health Collection"
Write-Log "========================================"

# ----------------------------------------
# Step 1: Frequency managed by Orchestrator v2
# ----------------------------------------
if ($Force) {
    Write-Log "Force flag set - manual execution."
}

# ----------------------------------------
# Step 2: Get list of servers to monitor
# ----------------------------------------
Write-Log "Retrieving server list..."

$servers = Get-SqlData -Query @"
SELECT
    server_id,
    server_name,
    instance_name,
    server_type,
    environment,
    server_role
FROM dbo.ServerRegistry
WHERE is_active = 1 AND serverops_disk_enabled = 1
ORDER BY server_id
"@

if ($null -eq $servers -or @($servers).Count -eq 0) {
    Write-Log "No active servers configured for disk monitoring. Exiting." "WARN"
    exit 0
}

$serverCount = @($servers).Count
Write-Log "Found $serverCount server(s) to monitor."

# ----------------------------------------
# Step 3: Collect disk space from each server
# ----------------------------------------
$collectionTime = Get-Date
$totalDrives = 0
$successServers = 0
$failedServers = @()
$sqlServersUpdated = 0

# In-memory collection results for threshold evaluation (Step 7)
$collectedDrives = @()

foreach ($server in $servers) {
    $serverName = $server.server_name
    $serverId = $server.server_id
    $instanceName = if ($server.instance_name -isnot [DBNull]) { $server.instance_name } else { $null }
    $serverType = $server.server_type

    Write-Log "Collecting from: $serverName (ID: $serverId, Type: $serverType)"

    # ----------------------------------------
    # Step 3a: Disk space collection (all servers)
    # ----------------------------------------
    try {
        # Create CIM session (local or remote)
        $localHostNames = @($env:COMPUTERNAME, "localhost", ".")

        if ($localHostNames -contains $serverName) {
            $disks = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction Stop
        }
        else {
            $session = New-CimSession -ComputerName $serverName -ErrorAction Stop
            $disks = Get-CimInstance -CimSession $session -ClassName Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction Stop
            Remove-CimSession $session
        }

        $driveCount = @($disks).Count
        Write-Log "  Found $driveCount drive(s)"

        foreach ($disk in $disks) {
            $driveLetter = $disk.DeviceID.TrimEnd(':')
            $volumeLabel = if ($disk.VolumeName) { $disk.VolumeName } else { "" }
            $totalMB = [math]::Round($disk.Size / 1MB, 0)
            $freeMB = [math]::Round($disk.FreeSpace / 1MB, 0)
            $pctFree = if ($disk.Size -gt 0) { [math]::Round(($disk.FreeSpace / $disk.Size) * 100, 2) } else { 0 }

            # Escape single quotes in volume label
            $volumeLabelSafe = $volumeLabel -replace "'", "''"

            $insertQuery = @"
INSERT INTO ServerOps.Disk_Snapshot (server_id, drive_letter, volume_label, total_size_mb, free_space_mb, percent_free, snapshot_dttm)
VALUES ($serverId, '$driveLetter', '$volumeLabelSafe', $totalMB, $freeMB, $pctFree, '$($collectionTime.ToString("yyyy-MM-dd HH:mm:ss"))')
"@

            if ($Execute) {
                $result = Invoke-SqlNonQuery -Query $insertQuery

                if ($result) {
                    Write-Log "    $($driveLetter): $pctFree% free ($freeMB MB / $totalMB MB)"
                    $totalDrives++
                }
                else {
                    Write-Log "    $($driveLetter): Failed to insert" "ERROR"
                }
            }
            else {
                Write-Log "    [Preview] $($driveLetter): $pctFree% free ($freeMB MB / $totalMB MB)"
                $totalDrives++
            }

            # Store in-memory for threshold evaluation
            $collectedDrives += [PSCustomObject]@{
                server_id    = $serverId
                server_name  = $serverName
                drive_letter = $driveLetter
                volume_label = $volumeLabel
                total_size_mb = $totalMB
                free_space_mb = $freeMB
                percent_free = $pctFree
            }
        }

        $successServers++
    }
    catch {
        Write-Log "  FAILED (disk collection): $($_.Exception.Message)" "ERROR"
        $failedServers += $serverName
    }

    # ----------------------------------------
    # Step 3b: SQL Server service start time (SQL Servers only)
    # ----------------------------------------
    if ($serverType -eq "SQL_SERVER") {
        $sqlInstanceName = Get-SqlInstanceName -ServerName $serverName -InstanceName $instanceName
        Write-Log "  Checking SQL service start time ($sqlInstanceName)..."

        $serviceStartTime = Get-SqlServiceStartTime -SqlInstanceName $sqlInstanceName

        if ($null -ne $serviceStartTime) {
            $uptimeDays = [math]::Round((Get-Date).Subtract($serviceStartTime).TotalDays, 1)
            Write-Log "    Service started: $($serviceStartTime.ToString('yyyy-MM-dd HH:mm:ss')) (uptime: $uptimeDays days)"

            $updateQuery = @"
UPDATE dbo.ServerRegistry
SET last_service_start_dttm = '$($serviceStartTime.ToString("yyyy-MM-dd HH:mm:ss"))',
    last_service_start_captured_dttm = '$($collectionTime.ToString("yyyy-MM-dd HH:mm:ss"))',
    modified_dttm = GETDATE(),
    modified_by = 'Collect-ServerHealth.ps1'
WHERE server_id = $serverId
"@

            if ($Execute) {
                $updateResult = Invoke-SqlNonQuery -Query $updateQuery
                if ($updateResult) {
                    $sqlServersUpdated++
                }
            }
            else {
                Write-Log "    [Preview] Would update service start time: $($serviceStartTime.ToString('yyyy-MM-dd HH:mm:ss'))"
                $sqlServersUpdated++
            }
        }
        else {
            Write-Log "    Could not retrieve service start time" "WARN"
        }
    }
}

# ----------------------------------------
# Step 4: Update Disk_Status (collection timestamp)
# ----------------------------------------
if ($Execute) {
    Write-Log "Updating Disk_Status (collection)..."

    $updateQuery = @"
UPDATE ServerOps.Disk_Status
SET last_collection_dttm = '$($collectionTime.ToString("yyyy-MM-dd HH:mm:ss"))',
    modified_dttm = GETDATE()
WHERE status_id = 1
"@

    Invoke-SqlNonQuery -Query $updateQuery | Out-Null
}
else {
    Write-Log "  [Preview] Would update Disk_Status.last_collection_dttm"
}

# ----------------------------------------
# Collection Summary
# ----------------------------------------
Write-Log "========================================"
Write-Log "  Collection Complete$(if (-not $Execute) { ' [PREVIEW]' })"
Write-Log "  Servers attempted: $serverCount"
Write-Log "  Servers successful: $successServers"
Write-Log "  Servers failed: $($failedServers.Count)"
Write-Log "  Total drives collected: $totalDrives"
Write-Log "  SQL service times updated: $sqlServersUpdated"
Write-Log "========================================"

if ($failedServers.Count -gt 0) {
    Write-Log "Failed servers: $($failedServers -join ', ')" "WARN"
}

# ============================================================================
# THRESHOLD EVALUATION (Steps 5-10)
# Absorbed from sp_Disk_Monitor - evaluates against in-memory collection data
# Wrapped in try/catch for error isolation: collection data is already committed
# ============================================================================

$pollStart = Get-Date
$alertsDetected = 0
$alertsSent = 0
$belowThresholdCount = 0

try {

    if ($collectedDrives.Count -eq 0) {
        Write-Log "No drives collected - skipping threshold evaluation."
    }
    else {

    Write-Log ""
    Write-Log "========================================"
    Write-Log "Threshold Evaluation"
    Write-Log "========================================"

    # ----------------------------------------
    # Step 5: Load monitoring configuration
    # ----------------------------------------
    Write-Log "Loading monitoring configuration..."

    $configData = Get-SqlData -Query @"
SELECT setting_name, setting_value
FROM dbo.GlobalConfig
WHERE module_name = 'ServerOps'
  AND category = 'Disk'
  AND is_active = 1
"@

    # Parse config values with defaults
    $defaultThresholdPct = 10.00
    $spaceRequestBufferPct = 5.00
    $warningBufferPct = 2.00

    if ($configData) {
        foreach ($cfg in @($configData)) {
            switch ($cfg.setting_name) {
                'default_threshold_pct'    { $defaultThresholdPct = [decimal]$cfg.setting_value }
                'space_request_buffer_pct' { $spaceRequestBufferPct = [decimal]$cfg.setting_value }
                'warning_buffer_pct'       { $warningBufferPct = [decimal]$cfg.setting_value }
            }
        }
    }

    Write-Log "  Default threshold: ${defaultThresholdPct}%"
    Write-Log "  Space request target: ${spaceRequestBufferPct}%"
    Write-Log "  Warning buffer: ${warningBufferPct}%"
    Write-Log "  Resolution threshold: $($defaultThresholdPct + $warningBufferPct)% (threshold + buffer)"

    # ----------------------------------------
    # Step 6: Auto-create thresholds for new drives
    # ----------------------------------------
    Write-Log "Checking for new drives needing threshold configuration..."

    # Get all existing threshold configs
    $existingThresholds = Get-SqlData -Query @"
SELECT server_id, drive_letter, threshold_pct, alert_enabled
FROM ServerOps.Disk_ThresholdConfig
"@

    # Build a lookup hashtable for fast comparison
    $thresholdLookup = @{}
    if ($existingThresholds) {
        foreach ($t in @($existingThresholds)) {
            $key = "$($t.server_id)_$($t.drive_letter)"
            $thresholdLookup[$key] = $t
        }
    }

    # Find drives without threshold config
    $newDrives = $collectedDrives | Where-Object {
        $key = "$($_.server_id)_$($_.drive_letter)"
        -not $thresholdLookup.ContainsKey($key)
    }

    if ($newDrives -and @($newDrives).Count -gt 0) {
        $newDriveCount = @($newDrives).Count
        Write-Log "  Found $newDriveCount new drive(s) needing threshold config"

        foreach ($nd in @($newDrives)) {
            Write-Log "    $($nd.server_name) drive $($nd.drive_letter): creating with default ${defaultThresholdPct}%"

            if ($Execute) {
                $insertResult = Invoke-SqlNonQuery -Query @"
INSERT INTO ServerOps.Disk_ThresholdConfig (server_id, drive_letter, threshold_pct, alert_enabled, created_by, modified_by)
VALUES ($($nd.server_id), '$($nd.drive_letter)', $defaultThresholdPct, 1, 'Collect-ServerHealth.ps1', 'Collect-ServerHealth.ps1')
"@
                if ($insertResult) {
                    # Add to lookup so threshold evaluation can use it immediately
                    $key = "$($nd.server_id)_$($nd.drive_letter)"
                    $thresholdLookup[$key] = [PSCustomObject]@{
                        server_id    = $nd.server_id
                        drive_letter = $nd.drive_letter
                        threshold_pct = $defaultThresholdPct
                        alert_enabled = 1
                    }
                }
            }
            else {
                # Add to lookup for preview evaluation
                $key = "$($nd.server_id)_$($nd.drive_letter)"
                $thresholdLookup[$key] = [PSCustomObject]@{
                    server_id    = $nd.server_id
                    drive_letter = $nd.drive_letter
                    threshold_pct = $defaultThresholdPct
                    alert_enabled = 1
                }
            }
        }
    }
    else {
        Write-Log "  All drives have threshold configuration."
    }

    # ----------------------------------------
    # Step 7: Evaluate thresholds
    # ----------------------------------------
    Write-Log "Evaluating thresholds..."

    # Get active (unresolved) alerts from Disk_AlertHistory
    $activeAlerts = Get-SqlData -Query @"
SELECT alert_id, server_id, alert_key
FROM ServerOps.Disk_AlertHistory
WHERE alert_type = 'DISK_SPACE_LOW'
  AND is_resolved = 0
"@

    # Build active alert lookup
    $activeAlertLookup = @{}
    if ($activeAlerts) {
        foreach ($a in @($activeAlerts)) {
            $key = "$($a.server_id)_$($a.alert_key)"
            $activeAlertLookup[$key] = $a
        }
    }

    # Evaluate each collected drive against its threshold
    $drivesBelow = @()
    $drivesToResolve = @()

    foreach ($drive in $collectedDrives) {
        $key = "$($drive.server_id)_$($drive.drive_letter)"
        $threshold = $thresholdLookup[$key]

        if (-not $threshold) {
            Write-Log "    WARNING: No threshold config for $($drive.server_name) drive $($drive.drive_letter) - skipping" "WARN"
            continue
        }

        if (-not $threshold.alert_enabled) {
            continue  # Alerting disabled for this drive
        }

        $thresholdPct = [decimal]$threshold.threshold_pct
        $resolutionPct = $thresholdPct + $warningBufferPct
        $hasActiveAlert = $activeAlertLookup.ContainsKey($key)

        if ($drive.percent_free -lt $thresholdPct) {
            # Drive is below threshold
            $belowThresholdCount++

            if (-not $hasActiveAlert) {
                # New breach - needs ticket
                $drivesBelow += [PSCustomObject]@{
                    server_id     = $drive.server_id
                    server_name   = $drive.server_name
                    drive_letter  = $drive.drive_letter
                    volume_label  = $drive.volume_label
                    total_size_mb = $drive.total_size_mb
                    free_space_mb = $drive.free_space_mb
                    percent_free  = $drive.percent_free
                    threshold_pct = $thresholdPct
                }
                Write-Log "    BREACH: $($drive.server_name) drive $($drive.drive_letter) at $($drive.percent_free)% (threshold: ${thresholdPct}%)" "WARN"
            }
            else {
                Write-Log "    BELOW: $($drive.server_name) drive $($drive.drive_letter) at $($drive.percent_free)% - active alert exists, no new ticket"
            }
        }
        elseif ($hasActiveAlert -and $drive.percent_free -ge $resolutionPct) {
            # Drive has recovered above threshold + buffer - resolve the alert
            $drivesToResolve += [PSCustomObject]@{
                alert_id     = $activeAlertLookup[$key].alert_id
                server_name  = $drive.server_name
                drive_letter = $drive.drive_letter
                percent_free = $drive.percent_free
                resolution_pct = $resolutionPct
            }
            Write-Log "    RESOLVED: $($drive.server_name) drive $($drive.drive_letter) at $($drive.percent_free)% (above resolution threshold ${resolutionPct}%)" "SUCCESS"
        }
        elseif ($hasActiveAlert) {
            # Drive is above threshold but below resolution threshold - hold the alert
            Write-Log "    HOLDING: $($drive.server_name) drive $($drive.drive_letter) at $($drive.percent_free)% (above ${thresholdPct}% but below resolution ${resolutionPct}%)"
        }
    }

    Write-Log "  Drives below threshold: $belowThresholdCount"
    Write-Log "  New breaches: $(@($drivesBelow).Count)"
    Write-Log "  Alerts to resolve: $(@($drivesToResolve).Count)"

    # ----------------------------------------
    # Step 8: Create Jira tickets for new breaches
    # ----------------------------------------
    if (@($drivesBelow).Count -gt 0) {
        Write-Log "Creating Jira tickets for threshold breaches..."

        foreach ($breach in $drivesBelow) {
            $alertsDetected++

            # Calculate space needed to reach threshold + buffer
            $driveTargetPct = $breach.threshold_pct + $spaceRequestBufferPct
            $targetFreeMB = [math]::Ceiling(($driveTargetPct / 100) * $breach.total_size_mb)
            $spaceNeededMB = $targetFreeMB - $breach.free_space_mb
            $spaceNeededGB = [math]::Ceiling($spaceNeededMB / 1024)

            # Round up to nearest 10 GB
            $spaceRequestGB = [math]::Ceiling($spaceNeededGB / 10) * 10

            # Ensure minimum request of 10 GB
            if ($spaceRequestGB -lt 10) { $spaceRequestGB = 10 }

            $currentFreeGB = [math]::Round($breach.free_space_mb / 1024, 1)
            $totalSizeGB = [math]::Round($breach.total_size_mb / 1024, 1)

            Write-Log "    $($breach.server_name) $($breach.drive_letter): requesting ${spaceRequestGB} GB (current: ${currentFreeGB} GB free of ${totalSizeGB} GB)"

            # Build ticket summary
            $ticketSummary = "Please add $spaceRequestGB GB of space to $($breach.server_name) drive $($breach.drive_letter):"
            $ticketSummarySafe = $ticketSummary -replace "'", "''"

            # Build ticket description
            $ticketDescription = @"
Server: $($breach.server_name)
Drive: $($breach.drive_letter):$(if ($breach.volume_label) { " ($($breach.volume_label))" })
Total Size: $totalSizeGB GB
Current Free Space: $currentFreeGB GB ($($breach.percent_free)%)
Alert Threshold: $($breach.threshold_pct)%
Space Request Target: ${driveTargetPct}% (threshold $($breach.threshold_pct)% + buffer ${spaceRequestBufferPct}%)

Requested: $spaceRequestGB GB to bring drive above ${driveTargetPct}% free space.

Detected: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Source: xFACts Automated Disk Monitoring (Collect-ServerHealth.ps1)
"@
            $ticketDescriptionSafe = $ticketDescription -replace "'", "''"

            # Trigger values for deduplication
            $triggerType = 'ServerOps_DiskSpace'
            $triggerValue = "$($breach.server_name)_$($breach.drive_letter)"

            # Build alert details for Disk_AlertHistory
            $alertDetails = "$($breach.server_name) - Drive $($breach.drive_letter): at $($breach.percent_free)% free (threshold: $($breach.threshold_pct)%) - Jira ticket requested for $spaceRequestGB GB"
            $alertDetailsSafe = $alertDetails -replace "'", "''"

            if ($Execute) {
                # Insert into Disk_AlertHistory
                $alertInsert = Invoke-SqlNonQuery -Query @"
INSERT INTO ServerOps.Disk_AlertHistory (
    server_id, alert_type, alert_key, alert_details,
    threshold_value, actual_value, detected_dttm
)
VALUES (
    $($breach.server_id), 'DISK_SPACE_LOW', '$($breach.drive_letter)', '$alertDetailsSafe',
    $($breach.threshold_pct), $($breach.percent_free), GETDATE()
)
"@

                if ($alertInsert) {
                    # Insert directly into Jira.TicketQueue
                    $jiraInsert = Invoke-SqlNonQuery -Query @"
INSERT INTO Jira.TicketQueue (
    SourceModule, ProjectKey, Summary, TicketDescription,
    IssueType, TicketPriority, EmailRecipients,
    CascadingField_ID, CascadingField_ParentValue, CascadingField_ChildValue,
    CustomField_ID, CustomField_Value,
    CustomField2_ID, CustomField2_Value,
    TriggerType, TriggerValue,
    TicketStatus, RequestedDate
)
VALUES (
    'ServerOps', 'SD', '$ticketSummarySafe', '$ticketDescriptionSafe',
    'Issue', 'High', 'sfitzpatrick@frost-arnett.com',
    'customfield_18401', 'Computer/Software/Network Access', 'Hardware Issue',
    'customfield_10305', 'FAC INFORMATION TECHNOLOGY',
    'customfield_10009', 'sd/1b77b626-3ad4-4bee-8727-abc18b68c5fa',
    '$triggerType', '$triggerValue',
    'Pending', GETDATE()
)
"@

                    if ($jiraInsert) {
                        # Update AlertHistory with alerted timestamp and method
                        Invoke-SqlNonQuery -Query @"
UPDATE ServerOps.Disk_AlertHistory
SET alerted_dttm = GETDATE(),
    alert_method = 'JIRA'
WHERE server_id = $($breach.server_id)
  AND alert_type = 'DISK_SPACE_LOW'
  AND alert_key = '$($breach.drive_letter)'
  AND is_resolved = 0
  AND alerted_dttm IS NULL
"@ | Out-Null
                        $alertsSent++
                        Write-Log "      Jira ticket queued and alert recorded" "SUCCESS"
                    }
                    else {
                        Write-Log "      Alert recorded but Jira ticket insert FAILED" "ERROR"
                    }
                }
                else {
                    Write-Log "      Failed to insert Disk_AlertHistory" "ERROR"
                }
            }
            else {
                Write-Log "    [Preview] Would create alert and queue Jira ticket:"
                Write-Log "      Summary: $ticketSummary"
                Write-Log "      Space request: $spaceRequestGB GB"
                Write-Log "      Trigger: $triggerType / $triggerValue"
            }
        }
    }
    else {
        Write-Log "  No new threshold breaches detected."
    }

    # ----------------------------------------
    # Step 9: Auto-resolve recovered drives
    # ----------------------------------------
    if (@($drivesToResolve).Count -gt 0) {
        Write-Log "Auto-resolving recovered drives..."

        foreach ($resolved in $drivesToResolve) {
            if ($Execute) {
                $resolveResult = Invoke-SqlNonQuery -Query @"
UPDATE ServerOps.Disk_AlertHistory
SET is_resolved = 1,
    resolved_dttm = GETDATE(),
    resolved_by = 'Collect-ServerHealth.ps1'
WHERE alert_id = $($resolved.alert_id)
"@
                if ($resolveResult) {
                    Write-Log "    Resolved alert $($resolved.alert_id) for $($resolved.server_name) drive $($resolved.drive_letter)" "SUCCESS"
                }
                else {
                    Write-Log "    Failed to resolve alert $($resolved.alert_id)" "ERROR"
                }
            }
            else {
                Write-Log "    [Preview] Would resolve alert $($resolved.alert_id) for $($resolved.server_name) drive $($resolved.drive_letter)"
            }
        }
    }
    else {
        Write-Log "  No alerts to resolve."
    }

    # ----------------------------------------
    # Step 10: Update Disk_Status (poll metrics)
    # ----------------------------------------
    $pollEnd = Get-Date
    $pollDurationMs = [int]($pollEnd - $pollStart).TotalMilliseconds

    Write-Log "Updating Disk_Status (poll metrics)..."

    if ($Execute) {
        # Check if date changed (reset daily counters)
        $lastPollDate = Get-SqlData -Query @"
SELECT CAST(last_poll_dttm AS DATE) AS last_poll_date
FROM ServerOps.Disk_Status
WHERE status_id = 1
"@

        $today = (Get-Date).Date
        $isNewDay = $true
        if ($lastPollDate -and $lastPollDate.last_poll_date -isnot [DBNull]) {
            $lastDate = [DateTime]$lastPollDate.last_poll_date
            $isNewDay = ($lastDate -lt $today)
        }

        if ($isNewDay) {
            # New day - reset counters
            Invoke-SqlNonQuery -Query @"
UPDATE ServerOps.Disk_Status
SET alerts_detected_today = $alertsDetected,
    alerts_sent_today = $alertsSent,
    last_poll_dttm = GETDATE(),
    last_poll_duration_ms = $pollDurationMs,
    last_poll_status = 'SUCCESS',
    servers_monitored = $successServers,
    drives_monitored = $totalDrives,
    drives_below_threshold = $belowThresholdCount,
    modified_dttm = GETDATE()
WHERE status_id = 1
"@ | Out-Null
        }
        else {
            # Same day - increment counters
            Invoke-SqlNonQuery -Query @"
UPDATE ServerOps.Disk_Status
SET alerts_detected_today = alerts_detected_today + $alertsDetected,
    alerts_sent_today = alerts_sent_today + $alertsSent,
    last_poll_dttm = GETDATE(),
    last_poll_duration_ms = $pollDurationMs,
    last_poll_status = 'SUCCESS',
    servers_monitored = $successServers,
    drives_monitored = $totalDrives,
    drives_below_threshold = $belowThresholdCount,
    modified_dttm = GETDATE()
WHERE status_id = 1
"@ | Out-Null
        }
    }
    else {
        Write-Log "  [Preview] Would update Disk_Status poll metrics"
        Write-Log "    Poll duration: $pollDurationMs ms"
        Write-Log "    Servers monitored: $successServers"
        Write-Log "    Drives monitored: $totalDrives"
        Write-Log "    Below threshold: $belowThresholdCount"
        Write-Log "    Alerts detected: $alertsDetected"
        Write-Log "    Alerts sent: $alertsSent"
    }

    }  # end if ($collectedDrives.Count -eq 0) else block

}
catch {
    Write-Log "THRESHOLD EVALUATION ERROR: $($_.Exception.Message)" "ERROR"
    Write-Log "  Stack: $($_.ScriptStackTrace)" "ERROR"
    Write-Log "  Collection data was already committed. Threshold evaluation failed independently." "WARN"

    # Still try to update Disk_Status with error
    if ($Execute) {
        Invoke-SqlNonQuery -Query @"
UPDATE ServerOps.Disk_Status
SET last_poll_dttm = GETDATE(),
    last_poll_status = 'FAILED',
    modified_dttm = GETDATE()
WHERE status_id = 1
"@ | Out-Null
    }
}

# ----------------------------------------
# Final Summary
# ----------------------------------------
$scriptEnd = Get-Date
$totalDurationMs = [int]($scriptEnd - $collectionTime).TotalMilliseconds

Write-Log ""
Write-Log "========================================"
Write-Log "  Script Complete$(if (-not $Execute) { ' [PREVIEW - No changes made]' })"
Write-Log "  Total duration: $totalDurationMs ms"
Write-Log "  Collection: $successServers/$serverCount servers, $totalDrives drives"
Write-Log "  SQL service times: $sqlServersUpdated"
Write-Log "  Threshold breaches: $alertsDetected"
Write-Log "  Jira tickets queued: $alertsSent"
Write-Log "  Below threshold: $belowThresholdCount"
Write-Log "========================================"

# ----------------------------------------
# Orchestrator Callback
# ----------------------------------------
if ($TaskId -gt 0) {
    $outputMsg = "Servers: $successServers/$serverCount, Drives: $totalDrives, SQL: $sqlServersUpdated, Breaches: $alertsDetected, Tickets: $alertsSent"
    Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
        -TaskId $TaskId -ProcessId $ProcessId `
        -Status "SUCCESS" -DurationMs $totalDurationMs `
        -Output $outputMsg
}

exit 0
<#
.SYNOPSIS
    xFACts - Disk Health Summary Notification

.DESCRIPTION
    xFACts - ServerOps.Disk
    Script: Send-DiskHealthSummary.ps1
    Version: Tracked in dbo.System_Metadata (component: ServerOps.Disk)

    Generates a disk health summary across all monitored servers and sends
    a formatted Adaptive Card notification to Teams. Replaces sp_Disk_DailyHealth
    with richer card formatting and proper Unicode/emoji rendering.

    Key behaviors:
    - Queries latest Disk_Snapshot per server/drive
    - Joins to Disk_ThresholdConfig for threshold comparison
    - Classifies drives as BELOW / APPROACHING / OK
    - Builds Adaptive Card JSON with color-coded status indicators
    - Inserts directly into Teams.AlertQueue with card_json
    - Updates Disk_Status with health check timestamp
    - Three-tier severity: green (all healthy), yellow (approaching), red (below threshold)
    - Unified server listing with inline drive details for problem drives

    CHANGELOG
    ---------
    2026-03-11  Migrated to Initialize-XFActsScript shared infrastructure
                Removed inline Write-Log, Get-SqlData, Invoke-SqlNonQuery
                Updated header to component-level versioning format
    2026-02-06  Initial implementation
                Replaces sp_Disk_DailyHealth with PowerShell-driven Adaptive Card
                Direct INSERT into Teams.AlertQueue with card_json
                Three-tier severity (green/yellow/red)
                Unified server listing with inline drive details for problem drives
                Standard v2 orchestrator integration (-Execute, -TaskId, -ProcessId)

.PARAMETER ServerInstance
    SQL Server instance name for xFACts database (default: AVG-PROD-LSNR)

.PARAMETER Database
    Database name (default: xFACts)

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
1. Deploy to E:\xFACts-PowerShell on FA-SQLDBB.
2. xFACts-OrchestratorFunctions.ps1 must be in the same directory.
3. Register in Orchestrator.ProcessRegistry with scheduled_time for daily execution.
4. Requires WebhookSubscription entry for ServerOps/INFO (and WARNING) routing.
================================================================================
#>

[CmdletBinding()]
param(
    [string]$ServerInstance = "AVG-PROD-LSNR",
    [string]$Database = "xFACts",
    [switch]$Execute,
    [long]$TaskId = 0,
    [int]$ProcessId = 0
)

# ============================================================================
# STANDARD INITIALIZATION
# ============================================================================

. "$PSScriptRoot\xFACts-OrchestratorFunctions.ps1"

Initialize-XFActsScript -ScriptName 'Send-DiskHealthSummary' `
    -ServerInstance $ServerInstance -Database $Database -Execute:$Execute

# ============================================================================
# FUNCTIONS
# ============================================================================

function Format-FreeSpace {
    <#
    .SYNOPSIS
        Formats free space in human-readable units (GB or TB)
    #>
    param([long]$FreeMB)
    
    if ($FreeMB -ge 1048576) {
        # 1 TB or more
        return "{0:N1} TB" -f ($FreeMB / 1048576.0)
    }
    else {
        return "{0:N0} GB" -f ($FreeMB / 1024.0)
    }
}

function Build-AdaptiveCard {
    <#
    .SYNOPSIS
        Builds an Adaptive Card JSON payload for the disk health summary
    .DESCRIPTION
        Creates a unified server listing with inline drive details:
        - Color-coded header based on overall severity
        - Servers grouped by severity (below first, then approaching, then OK)
        - Within each severity group, sorted by server_id
        - Problem drives shown inline under their server
        - Healthy servers show icon only, no drive detail
        - Color-coded text matching drive status
        - Footer with server/drive counts
    #>
    param(
        [array]$DriveData,
        [string]$CardColor    # good, warning, or attention
    )
    
    $dateDisplay = Get-Date -Format "MMMM dd, yyyy - h:mm tt"
    
    # ----------------------------------------
    # Build unified server listing
    # ----------------------------------------
    $serverGroups = $DriveData | Group-Object -Property server_id
    
    # Assign severity rank per server (worst drive wins), then sort by rank then server_id
    $rankedServers = $serverGroups | ForEach-Object {
        $hasBelowDrives = @($_.Group | Where-Object { $_.status -eq 'BELOW' }).Count -gt 0
        $hasApproachingDrives = @($_.Group | Where-Object { $_.status -eq 'APPROACHING' }).Count -gt 0
        
        $severityRank = if ($hasBelowDrives) { 1 }
                        elseif ($hasApproachingDrives) { 2 }
                        else { 3 }
        
        [PSCustomObject]@{
            ServerGroup = $_
            SeverityRank = $severityRank
            ServerId = [int]$_.Name
        }
    } | Sort-Object SeverityRank, ServerId
    
    $serverListItems = @()
    
    foreach ($ranked in $rankedServers) {
        $serverGroup = $ranked.ServerGroup
        $serverName = $serverGroup.Group[0].server_name
        $belowDrives = @($serverGroup.Group | Where-Object { $_.status -eq 'BELOW' })
        $approachingDrives = @($serverGroup.Group | Where-Object { $_.status -eq 'APPROACHING' })
        
        # Determine server-level status (worst wins)
        if ($belowDrives.Count -gt 0) {
            $serverIcon = "{{FIRE}}"
            $serverColor = "attention"
        }
        elseif ($approachingDrives.Count -gt 0) {
            $serverIcon = "{{WARN}}"
            $serverColor = "warning"
        }
        else {
            $serverIcon = "{{CHECK}}"
            $serverColor = "good"
        }
        
        # Server row: name left, icon right
        $serverListItems += @{
            type = "ColumnSet"
            separator = $true
            columns = @(
                @{
                    type = "Column"
                    width = "stretch"
                    items = @(
                        @{
                            type = "TextBlock"
                            text = $serverName
                            weight = "bolder"
                            color = $serverColor
                            spacing = "none"
                        }
                    )
                }
                @{
                    type = "Column"
                    width = "auto"
                    items = @(
                        @{
                            type = "TextBlock"
                            text = $serverIcon
                            horizontalAlignment = "right"
                            spacing = "none"
                        }
                    )
                }
            )
            spacing = "small"
        }
        
        # Inline drive details for problem drives (below threshold first, then approaching)
        $problemDrives = @()
        $problemDrives += $belowDrives | Sort-Object percent_free
        $problemDrives += $approachingDrives | Sort-Object percent_free
        
        foreach ($drive in $problemDrives) {
            $freeDisplay = Format-FreeSpace -FreeMB $drive.free_space_mb
            
            if ($drive.status -eq 'BELOW') {
                $driveIcon = "{{FIRE}}"
                $driveColor = "attention"
            }
            else {
                $driveIcon = "{{WARN}}"
                $driveColor = "warning"
            }
            
            # Drive row: icon | drive letter | right-justified free space
            $serverListItems += @{
                type = "ColumnSet"
                columns = @(
                    @{
                        type = "Column"
                        width = "24px"
                        items = @(
                            @{
                                type = "TextBlock"
                                text = $driveIcon
                                spacing = "none"
                                size = "small"
                                horizontalAlignment = "center"
                            }
                        )
                    }
                    @{
                        type = "Column"
                        width = "stretch"
                        items = @(
                            @{
                                type = "TextBlock"
                                text = "$($drive.drive_letter):"
                                color = $driveColor
                                spacing = "none"
                                size = "small"
                            }
                        )
                    }
                    @{
                        type = "Column"
                        width = "auto"
                        items = @(
                            @{
                                type = "TextBlock"
                                text = "$($drive.percent_free)% free ($freeDisplay)"
                                color = $driveColor
                                horizontalAlignment = "right"
                                spacing = "none"
                                size = "small"
                            }
                        )
                    }
                )
                spacing = "none"
            }
        }
    }
    
    # ----------------------------------------
    # Build body
    # ----------------------------------------
    $bodyItems = @()
    
    # Header container with severity color
    $bodyItems += @{
        type = "Container"
        style = $CardColor
        bleed = $true
        items = @(
            @{
                type = "TextBlock"
                text = "xFACts Disk Health Summary"
                weight = "bolder"
                size = "medium"
                wrap = $true
            }
            @{
                type = "TextBlock"
                text = $dateDisplay
                size = "small"
                isSubtle = $true
                spacing = "none"
            }
        )
    }
    
    # Server listing in emphasis container for visibility
    $bodyItems += @{
        type = "Container"
        style = "emphasis"
        items = $serverListItems
        spacing = "medium"
    }
    
    # Status summary
    $totalDrives = $DriveData.Count
    $totalServers = @($DriveData | Select-Object -Property server_name -Unique).Count
    $belowCount = @($DriveData | Where-Object { $_.status -eq 'BELOW' }).Count
    $approachingCount = @($DriveData | Where-Object { $_.status -eq 'APPROACHING' }).Count
    
    if ($belowCount -eq 0 -and $approachingCount -eq 0) {
        $bodyItems += @{
            type = "TextBlock"
            text = "**All drives above threshold.**"
            color = "good"
            spacing = "medium"
        }
    }
    
    # Footer
    $bodyItems += @{
        type = "ColumnSet"
        columns = @(
            @{
                type = "Column"
                width = "stretch"
                items = @(
                    @{
                        type = "TextBlock"
                        text = "Source: xFACts ServerOps"
                        size = "small"
                        isSubtle = $true
                        spacing = "none"
                    }
                )
            }
            @{
                type = "Column"
                width = "auto"
                items = @(
                    @{
                        type = "TextBlock"
                        text = "$totalServers servers · $totalDrives drives"
                        size = "small"
                        isSubtle = $true
                        spacing = "none"
                        horizontalAlignment = "right"
                    }
                )
            }
        )
        spacing = "medium"
    }
    
    # ----------------------------------------
    # Assemble full card payload
    # ----------------------------------------
    $card = @{
        type = "message"
        attachments = @(
            @{
                contentType = "application/vnd.microsoft.card.adaptive"
                content = @{
                    '$schema' = "http://adaptivecards.io/schemas/adaptive-card.json"
                    type = "AdaptiveCard"
                    version = "1.4"
                    body = $bodyItems
                }
            }
        )
    }
    
    return ($card | ConvertTo-Json -Depth 20)
}

# ============================================================================
# MAIN SCRIPT
# ============================================================================

Write-Log "========================================"
Write-Log "xFACts Disk Health Summary"
Write-Log "========================================"

$scriptStart = Get-Date

# ----------------------------------------
# Step 1: Load configuration from GlobalConfig
# ----------------------------------------
Write-Log "Loading configuration..."

$configResult = Get-SqlData -Query @"
SELECT setting_name, setting_value
FROM dbo.GlobalConfig
WHERE module_name = 'ServerOps' 
  AND category = 'Disk'
  AND setting_name = 'warning_buffer_pct'
  AND is_active = 1
"@

$warningBufferPct = 2.00
if ($configResult -and $configResult.setting_value) {
    $warningBufferPct = [decimal]$configResult.setting_value
}

Write-Log "  Warning buffer: ${warningBufferPct}%"

# ----------------------------------------
# Step 2: Query latest snapshots with threshold analysis
# ----------------------------------------
Write-Log "Querying disk snapshots and thresholds..."

$driveData = Get-SqlData -Query @"
SELECT 
    s.server_id,
    s.server_name,
    d.drive_letter,
    d.percent_free,
    d.free_space_mb,
    d.total_size_mb,
    t.threshold_pct,
    CASE 
        WHEN d.percent_free < t.threshold_pct THEN 'BELOW'
        WHEN d.percent_free < (t.threshold_pct + $warningBufferPct) THEN 'APPROACHING'
        ELSE 'OK'
    END AS status
FROM ServerOps.Disk_Snapshot d
INNER JOIN dbo.ServerRegistry s ON d.server_id = s.server_id
INNER JOIN ServerOps.Disk_ThresholdConfig t ON d.server_id = t.server_id AND d.drive_letter = t.drive_letter
WHERE s.is_active = 1
  AND s.serverops_disk_enabled = 1
  AND d.snapshot_id IN (
      SELECT MAX(d2.snapshot_id)
      FROM ServerOps.Disk_Snapshot d2
      WHERE d2.server_id = d.server_id
        AND d2.drive_letter = d.drive_letter
  )
ORDER BY s.server_id, d.drive_letter
"@

if ($null -eq $driveData -or @($driveData).Count -eq 0) {
    Write-Log "No drive data found. Exiting." "WARN"
    
    if ($TaskId -gt 0) {
        $totalMs = [int]((New-TimeSpan -Start $scriptStart -End (Get-Date)).TotalMilliseconds)
        Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
            -TaskId $TaskId -ProcessId $ProcessId `
            -Status "SUCCESS" -DurationMs $totalMs `
            -Output "No drive data available"
    }
    exit 0
}

# Ensure array even with single result
$driveData = @($driveData)

$totalServers = @($driveData | Select-Object -Property server_name -Unique).Count
$totalDrives = $driveData.Count
$belowCount = @($driveData | Where-Object { $_.status -eq 'BELOW' }).Count
$approachingCount = @($driveData | Where-Object { $_.status -eq 'APPROACHING' }).Count

Write-Log "  Servers: $totalServers"
Write-Log "  Drives: $totalDrives"
Write-Log "  Below threshold: $belowCount"
Write-Log "  Approaching threshold: $approachingCount"

# ----------------------------------------
# Step 3: Determine severity and card color
# ----------------------------------------
if ($belowCount -gt 0) {
    $cardColor = "attention"
    $alertCategory = "WARNING"
    Write-Log "  Severity: WARNING - drive(s) below threshold" "WARN"
}
elseif ($approachingCount -gt 0) {
    $cardColor = "warning"
    $alertCategory = "WARNING"
    Write-Log "  Severity: WARNING - drive(s) approaching threshold" "WARN"
}
else {
    $cardColor = "good"
    $alertCategory = "INFO"
    Write-Log "  Severity: INFO - all healthy" "SUCCESS"
}

# ----------------------------------------
# Step 4: Build Adaptive Card
# ----------------------------------------
Write-Log "Building Adaptive Card..."

$cardJson = Build-AdaptiveCard -DriveData $driveData -CardColor $cardColor

if (-not $Execute) {
    Write-Log "[Preview] Card JSON:" "DEBUG"
    Write-Log $cardJson "DEBUG"
}

# ----------------------------------------
# Step 5: Insert into Teams.AlertQueue
# ----------------------------------------
if ($Execute) {
    Write-Log "Inserting into Teams.AlertQueue..."
    
    # Escape the JSON for SQL insertion
    $cardJsonSafe = $cardJson -replace "'", "''"
    
    # Build a plain text summary for the message field (audit/logging)
    $plainSummary = "Disk Health Summary: $totalServers servers, $totalDrives drives. "
    if ($belowCount -gt 0) {
        $plainSummary += "$belowCount drive(s) below threshold. "
    }
    if ($approachingCount -gt 0) {
        $plainSummary += "$approachingCount drive(s) approaching threshold. "
    }
    if ($belowCount -eq 0 -and $approachingCount -eq 0) {
        $plainSummary += "All drives healthy."
    }
    $plainSummarySafe = $plainSummary -replace "'", "''"
    
    # Determine color value (same mapping as sp_QueueAlert)
    $colorValue = switch ($alertCategory) {
        "CRITICAL" { "attention" }
        "WARNING"  { "warning" }
        "INFO"     { "good" }
        default    { "default" }
    }
    
    $insertQuery = @"
INSERT INTO Teams.AlertQueue (
    source_module,
    alert_category,
    title,
    message,
    color,
    card_json,
    trigger_type,
    trigger_value,
    status,
    created_dttm
)
VALUES (
    'ServerOps',
    '$alertCategory',
    'Disk Health Summary',
    '$plainSummarySafe',
    '$colorValue',
    '$cardJsonSafe',
    'DiskHealthSummary',
    '$(Get-Date -Format "yyyy-MM-dd")',
    'Pending',
    GETDATE()
)
"@
    
    $result = Invoke-SqlNonQuery -Query $insertQuery
    
    if ($result) {
        Write-Log "  Alert queued successfully" "SUCCESS"
    }
    else {
        Write-Log "  Failed to queue alert" "ERROR"
    }
}
else {
    Write-Log "[Preview] Would insert into Teams.AlertQueue with card_json" "WARN"
}

# ----------------------------------------
# Step 6: Update Disk_Status
# ----------------------------------------
if ($Execute) {
    Write-Log "Updating Disk_Status..."
    
    $updateQuery = @"
UPDATE ServerOps.Disk_Status
SET last_health_check_dttm = GETDATE(),
    last_health_check_status = 'SUCCESS',
    modified_dttm = GETDATE()
WHERE status_id = 1
"@
    
    Invoke-SqlNonQuery -Query $updateQuery | Out-Null
}
else {
    Write-Log "[Preview] Would update Disk_Status.last_health_check_dttm" "WARN"
}

# ----------------------------------------
# Summary
# ----------------------------------------
$scriptEnd = Get-Date
$scriptDuration = $scriptEnd - $scriptStart

Write-Log "========================================"
Write-Log "  Summary$(if (-not $Execute) { ' [PREVIEW - No changes made]' })"
Write-Log "  Servers: $totalServers"
Write-Log "  Drives: $totalDrives"
Write-Log "  Below threshold: $belowCount"
Write-Log "  Approaching: $approachingCount"
Write-Log "  Card color: $cardColor"
Write-Log "  Duration: $([int]$scriptDuration.TotalMilliseconds) ms"
Write-Log "========================================"

# ----------------------------------------
# Orchestrator Callback
# ----------------------------------------
if ($TaskId -gt 0) {
    $totalMs = [int]$scriptDuration.TotalMilliseconds
    $outputMsg = "Servers: $totalServers, Drives: $totalDrives, Below: $belowCount, Approaching: $approachingCount"
    Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
        -TaskId $TaskId -ProcessId $ProcessId `
        -Status "SUCCESS" -DurationMs $totalMs `
        -Output $outputMsg
}

exit 0
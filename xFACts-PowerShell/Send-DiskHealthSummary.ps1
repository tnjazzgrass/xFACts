<#
.SYNOPSIS
    xFACts - Disk Health Summary Notification

.DESCRIPTION
    Generates a disk health summary across all monitored servers and sends a
    formatted Adaptive Card notification to Teams. Replaces sp_Disk_DailyHealth
    with richer card formatting and proper Unicode/emoji rendering.

    Key behaviors:
    - Queries latest Disk_Snapshot per server/drive
    - Joins to Disk_ThresholdConfig for threshold comparison
    - Classifies drives as BELOW / APPROACHING / OK
    - Builds Adaptive Card JSON with color-coded status indicators
    - Inserts via shared Send-TeamsAlert function with card_json payload
    - Updates Disk_Status with health check timestamp
    - Three-tier severity: green (all healthy), yellow (approaching), red (below threshold)
    - Unified server listing with inline drive details for problem drives

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

.COMPONENT
    ServerOps.Disk

.NOTES
    File Name : Send-DiskHealthSummary.ps1
    Location  : E:\xFACts-PowerShell\Send-DiskHealthSummary.ps1

    FILE ORGANIZATION
    -----------------
    CHANGELOG: CHANGE HISTORY
    PARAMETERS: SCRIPT PARAMETERS
    IMPORTS: SCRIPT DEPENDENCIES
    INITIALIZATION: SCRIPT INITIALIZATION
    FUNCTIONS: ADAPTIVE CARD
    EXECUTION: SCRIPT EXECUTION
#>

<# ============================================================================
   CHANGELOG: CHANGE HISTORY
   ----------------------------------------------------------------------------
   Dated change history for this file, most recent first. Authoritative
   version tracking lives in dbo.System_Metadata (component ServerOps.Disk);
   this section records what changed and when.
   Prefix: (none)
   ============================================================================ #>

# 2026-06-19  Conformed to the PowerShell file format spec: header CHANGELOG and
#             deployment block removed, redundant Script/Version description lines
#             dropped, section banners added, functions renamed to approved verbs
#             with the dsk prefix (Format-dsk_FreeSpace, New-dsk_AdaptiveCard),
#             docblocks replaced with single-line purpose comments, divider
#             comments regularized, and the parameter trailing comment relocated.
# 2026-04-28  Standardized Teams alerting via the shared Send-TeamsAlert function.
#             Converted the direct INSERT to Send-TeamsAlert with a -CardJson
#             parameter. trigger_value changed from yyyy-MM-dd to yyyy-MM-dd-HH
#             for future schedule flexibility (orchestrator schedule still
#             controls cadence). Card severity logic and color mapping preserved.
# 2026-03-11  Migrated to Initialize-XFActsScript shared infrastructure.
#             Removed inline Write-Log, Get-SqlData, Invoke-SqlNonQuery.
# 2026-02-06  Initial implementation. Replaces sp_Disk_DailyHealth with a
#             PowerShell-driven Adaptive Card, three-tier severity (green/yellow/
#             red), unified server listing with inline problem-drive details, and
#             standard v2 orchestrator integration (-Execute, -TaskId, -ProcessId).

<# ============================================================================
   PARAMETERS: SCRIPT PARAMETERS
   ----------------------------------------------------------------------------
   Script-level parameters: connection target, the execute switch, and the
   orchestrator callback identifiers.
   Prefix: (none)
   ============================================================================ #>

[CmdletBinding()]
param(
    [string]$ServerInstance = "AVG-PROD-LSNR",
    [string]$Database = "xFACts",
    [switch]$Execute,
    [long]$TaskId = 0,
    [int]$ProcessId = 0
)

<# ============================================================================
   IMPORTS: SCRIPT DEPENDENCIES
   ----------------------------------------------------------------------------
   Dot-sourced shared infrastructure: orchestrator helpers, SQL data access,
   logging, the shared Teams alert sender, and the orchestrator callback.
   Prefix: (none)
   ============================================================================ #>

. "$PSScriptRoot\xFACts-OrchestratorFunctions.ps1"

<# ============================================================================
   INITIALIZATION: SCRIPT INITIALIZATION
   ----------------------------------------------------------------------------
   Establishes shared script context (application identity, connection target,
   log path, Execute mode). This script is preview-capable: without -Execute it
   runs in dry-run mode and every write is gated inline, so there is no hard exit.
   Prefix: (none)
   ============================================================================ #>

Initialize-XFActsScript -ScriptName 'Send-DiskHealthSummary' `
    -ServerInstance $ServerInstance -Database $Database -Execute:$Execute

<# ============================================================================
   FUNCTIONS: ADAPTIVE CARD
   ----------------------------------------------------------------------------
   Builds the Teams Adaptive Card payload for the disk health summary, plus the
   free-space formatting helper it uses for per-drive detail lines.
   Prefix: dsk
   ============================================================================ #>

# Formats a free-space value in human-readable units (GB, or TB at 1 TB and above).
function Format-dsk_FreeSpace {
    param([long]$FreeMB)

    if ($FreeMB -ge 1048576) {
        # 1 TB or more
        return "{0:N1} TB" -f ($FreeMB / 1048576.0)
    }
    else {
        return "{0:N0} GB" -f ($FreeMB / 1024.0)
    }
}

# Builds the Adaptive Card JSON payload for the disk health summary and returns it.
function New-dsk_AdaptiveCard {
    param(
        [array]$DriveData,
        # Card severity color: good, warning, or attention
        [string]$CardColor
    )

    $dateDisplay = Get-Date -Format "MMMM dd, yyyy - h:mm tt"

    # Middle-dot separator for the footer counts (ASCII source, renders as the Unicode glyph)
    $midDot = [char]0x00B7

    # Build unified server listing
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
            $freeDisplay = Format-dsk_FreeSpace -FreeMB $drive.free_space_mb

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

    # Build body
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
                        text = "$totalServers servers $midDot $totalDrives drives"
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

    # Assemble full card payload
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

<# ============================================================================
   EXECUTION: SCRIPT EXECUTION
   ----------------------------------------------------------------------------
   Main flow: load the warning-buffer config, query the latest snapshot per
   drive with threshold classification, determine overall severity and card
   color, build the Adaptive Card, send it via the shared Teams alert function,
   update Disk_Status, and report completion to the orchestrator.
   Prefix: (none)
   ============================================================================ #>

Write-Log "========================================"
Write-Log "xFACts Disk Health Summary"
Write-Log "========================================"

$scriptStart = Get-Date

# -- Step 1: Load configuration from GlobalConfig --

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

# -- Step 2: Query latest snapshots with threshold analysis --

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

# -- Step 3: Determine severity and card color --

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

# -- Step 4: Build Adaptive Card --

Write-Log "Building Adaptive Card..."

$cardJson = New-dsk_AdaptiveCard -DriveData $driveData -CardColor $cardColor

if (-not $Execute) {
    Write-Log "[Preview] Card JSON:" "DEBUG"
    Write-Log $cardJson "DEBUG"
}

# -- Step 5: Send Teams alert via shared function --

if ($Execute) {
    Write-Log "Sending Teams alert..."

    # Build a plain text summary for the message field (audit/logging fallback)
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

    # Row color mirrors alert_category (summary severity), distinct from card content colors.
    # $cardColor (set in Step 3) drives the card container; per-drive colors are inside the card.
    $rowColor = switch ($alertCategory) {
        "CRITICAL" { "attention" }
        "WARNING"  { "warning" }
        "INFO"     { "good" }
        default    { "default" }
    }

    Send-TeamsAlert -SourceModule 'ServerOps' -AlertCategory $alertCategory `
        -Title 'Disk Health Summary' -Message $plainSummary -Color $rowColor `
        -CardJson $cardJson `
        -TriggerType 'DiskHealthSummary' `
        -TriggerValue (Get-Date -Format "yyyy-MM-dd-HH") | Out-Null
}
else {
    Write-Log "[Preview] Would send Teams alert with card_json" "WARN"
}

# -- Step 6: Update Disk_Status --

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

# -- Summary --

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

# -- Orchestrator Callback --

if ($TaskId -gt 0) {
    $totalMs = [int]$scriptDuration.TotalMilliseconds
    $outputMsg = "Servers: $totalServers, Drives: $totalDrives, Below: $belowCount, Approaching: $approachingCount"
    Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
        -TaskId $TaskId -ProcessId $ProcessId `
        -Status "SUCCESS" -DurationMs $totalMs `
        -Output $outputMsg
}

exit 0
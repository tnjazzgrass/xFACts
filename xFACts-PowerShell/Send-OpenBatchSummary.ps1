<#
.SYNOPSIS
    xFACts - Pre-Maintenance Processing Summary

.DESCRIPTION
    Generates a summary of all active Debt Manager processing and sends a formatted
    Adaptive Card notification to Teams before the nightly maintenance window.
    Replaces sp_DM_OpenBatchCheck with expanded scope and richer card formatting.

    Key behaviors: reads from the AG secondary replica via GlobalConfig; queries open
    New Business and Payment batches with status details; renders a sectioned Adaptive
    Card (with expansion points for BDL and Notices); inserts via the shared
    Send-TeamsAlert function with a card_json payload; colors the card by overall
    severity (green=clear, yellow=warning); and dedups by date+hour so only one alert
    fires per hour even if invoked manually.

.PARAMETER ServerInstance
    SQL Server instance name for xFACts database (default: AVG-PROD-LSNR).

.PARAMETER Database
    Database name (default: xFACts).

.PARAMETER SourceDB
    Source database for Debt Manager data (default: crs5_oltp).

.PARAMETER ForceSourceServer
    Override the GlobalConfig replica setting and connect to a specific server for reads.

.PARAMETER Execute
    Perform writes. Without this flag, runs in preview/dry-run mode.

.PARAMETER TaskId
    Orchestrator TaskLog ID passed by the v2 engine at launch. Used for task
    completion callback. Default 0 (no callback when run manually).

.PARAMETER ProcessId
    Orchestrator ProcessRegistry ID passed by the v2 engine at launch. Used for
    task completion callback. Default 0 (no callback when run manually).

.COMPONENT
    BatchOps

.NOTES
    File Name : Send-OpenBatchSummary.ps1
    Location  : E:\xFACts-PowerShell

    FILE ORGANIZATION
    -----------------
    CHANGELOG: CHANGE HISTORY
    PARAMETERS: SCRIPT PARAMETERS
    IMPORTS: SCRIPT DEPENDENCIES
    INITIALIZATION: SCRIPT INITIALIZATION
    VARIABLES: GLOBAL STATE
    FUNCTIONS: SOURCE AND CONFIGURATION
    FUNCTIONS: PROCESSING CHECKS
    FUNCTIONS: ADAPTIVE CARD
    EXECUTION: SCRIPT EXECUTION
#>

<# ============================================================================
   CHANGELOG: CHANGE HISTORY
   ----------------------------------------------------------------------------
   Date-driven change history for this script. Most-recent entry first.
   Prefix: (none)
   ============================================================================ #>

# 2026-04-28  Standardized Teams alerting via Send-TeamsAlert shared function.
#             Converted direct INSERT to Send-TeamsAlert with -CardJson parameter.
#             trigger_value changed from yyyy-MM-dd to yyyy-MM-dd-HH for future schedule
#             flexibility (orchestrator schedule still controls cadence). Card severity
#             logic and color mapping preserved.
# 2026-03-11  Migrated to Initialize-XFActsScript shared infrastructure.
#             Removed inline Write-Log, Get-xFACtsData, Invoke-xFACtsNonQuery.
# 2026-02-13  Payment batch section implemented. Live DM query for in-flight PMT batches,
#             replacing the placeholder with active monitoring.
# 2026-02-06  Initial implementation. Replaces BatchOps.sp_DM_OpenBatchCheck. AG-aware
#             secondary replica reads via GlobalConfig, sectioned Adaptive Card with
#             expansion points, direct INSERT into Teams.AlertQueue with card_json,
#             standard v2 orchestrator integration.

<# ============================================================================
   PARAMETERS: SCRIPT PARAMETERS
   ----------------------------------------------------------------------------
   The [CmdletBinding()] attribute and param() block declaring script-level parameters.
   Prefix: (none)
   ============================================================================ #>

[CmdletBinding()]
param(
    [string]$ServerInstance = "AVG-PROD-LSNR",
    [string]$Database = "xFACts",
    [string]$SourceDB = "crs5_oltp",
    [string]$ForceSourceServer = $null,
    [switch]$Execute,
    [long]$TaskId = 0,
    [int]$ProcessId = 0
)

<# ============================================================================
   IMPORTS: SCRIPT DEPENDENCIES
   ----------------------------------------------------------------------------
   Dot-sources the platform shared orchestrator functions consumed by this script.
   Prefix: (none)
   ============================================================================ #>

. "$PSScriptRoot\xFACts-OrchestratorFunctions.ps1"

<# ============================================================================
   INITIALIZATION: SCRIPT INITIALIZATION
   ----------------------------------------------------------------------------
   One-time setup that must run at file scope before other content executes.
   Prefix: (none)
   ============================================================================ #>

Initialize-XFActsScript -ScriptName 'Send-OpenBatchSummary' `
    -ServerInstance $ServerInstance -Database $Database -Execute:$Execute

<# ============================================================================
   VARIABLES: GLOBAL STATE
   ----------------------------------------------------------------------------
   Mutable script-scope state populated during configuration and execution.
   Prefix: bat
   ============================================================================ #>

# Server the script reads DM source data from (the AG secondary replica per config).
$script:ReadServer = $null

# Server the script writes xFACts updates to (the AG listener).
$script:WriteServer = $null

# GlobalConfig settings with AG name and source replica defaults.
$script:Config = @{
    AGName = "DMPRODAG"
    SourceReplica = "SECONDARY"
}

<# ============================================================================
   FUNCTIONS: SOURCE AND CONFIGURATION
   ----------------------------------------------------------------------------
   Source-data access, AG replica role detection, and configuration loading.
   Prefix: bat
   ============================================================================ #>

# Executes a query against the source database (crs5_oltp) on the configured replica.
function Get-bat_OBS_SourceData {
    param(
        [string]$Query,
        [int]$Timeout = 300
    )
    if (-not $script:ReadServer) {
        Write-Log "ReadServer not configured - cannot query source" "ERROR"
        return $null
    }
    try {
        Invoke-Sqlcmd -ServerInstance $script:ReadServer -Database $SourceDB -Query $Query -QueryTimeout $Timeout -ApplicationName $script:XFActsAppName -ErrorAction Stop -TrustServerCertificate
    }
    catch {
        Write-Log "Source query failed on $($script:ReadServer): $($_.Exception.Message)" "ERROR"
        return $null
    }
}

# Queries the AG to resolve current PRIMARY and SECONDARY replica server names.
function Get-bat_OBS_AGReplicaRoles {
    param()
    $agName = $script:Config.AGName

    if (-not $agName) {
        Write-Log "AGName not configured - cannot query replica states" "ERROR"
        return $null
    }

    $query = @"
        SELECT
            ar.replica_server_name,
            ars.role_desc
        FROM sys.dm_hadr_availability_replica_states ars
        INNER JOIN sys.availability_replicas ar
            ON ars.replica_id = ar.replica_id
        INNER JOIN sys.availability_groups ag
            ON ar.group_id = ag.group_id
        WHERE ag.name = '$agName'
"@

    $results = Get-SqlData -Query $query

    if (-not $results) {
        Write-Log "Failed to query AG replica states" "ERROR"
        return $null
    }

    $roles = @{
        PRIMARY = $null
        SECONDARY = $null
    }

    foreach ($row in $results) {
        if ($row.role_desc -eq 'PRIMARY') {
            $roles.PRIMARY = $row.replica_server_name
        }
        elseif ($row.role_desc -eq 'SECONDARY') {
            $roles.SECONDARY = $row.replica_server_name
        }
    }

    return $roles
}

# Loads GlobalConfig settings and determines server connections.
function Initialize-bat_OBS_Configuration {
    param()

    Write-Log "Loading configuration..." "INFO"

    # Set write server first (needed for GlobalConfig query)
    $script:WriteServer = $ServerInstance

    # Load GlobalConfig settings
    $configQuery = @"
        SELECT module_name, setting_name, setting_value
        FROM dbo.GlobalConfig
        WHERE module_name IN ('Core', 'Shared', 'dbo')
          AND is_active = 1
"@

    $configResults = Get-SqlData -Query $configQuery

    # Override defaults with GlobalConfig values
    if ($configResults) {
        foreach ($row in $configResults) {
            switch ($row.setting_name) {
                "AGName"         { $script:Config.AGName = $row.setting_value }
                "SourceReplica"  { $script:Config.SourceReplica = $row.setting_value }
            }
        }
    }

    Write-Log "  AGName: $($script:Config.AGName)" "INFO"
    Write-Log "  SourceReplica: $($script:Config.SourceReplica)" "INFO"

    # Determine read server
    if ($ForceSourceServer) {
        $script:ReadServer = $ForceSourceServer
        Write-Log "  ReadServer: $($script:ReadServer) (forced via parameter)" "WARN"
        Write-Log "  AG detection skipped due to ForceSourceServer" "WARN"
    }
    else {
        Write-Log "Detecting AG replica roles..." "INFO"
        $agRoles = Get-bat_OBS_AGReplicaRoles

        if (-not $agRoles) {
            Write-Log "AG detection failed - cannot determine read server" "ERROR"
            return $false
        }

        Write-Log "  AG PRIMARY: $($agRoles.PRIMARY)" "INFO"
        Write-Log "  AG SECONDARY: $($agRoles.SECONDARY)" "INFO"

        if ($script:Config.SourceReplica -eq "PRIMARY") {
            $script:ReadServer = $agRoles.PRIMARY
        }
        else {
            $script:ReadServer = $agRoles.SECONDARY
        }

        if (-not $script:ReadServer) {
            Write-Log "Could not determine ReadServer from AG roles" "ERROR"
            return $false
        }

        Write-Log "  ReadServer: $($script:ReadServer) (from GlobalConfig: $($script:Config.SourceReplica))" "SUCCESS"
    }

    Write-Log "  WriteServer: $($script:WriteServer)" "INFO"

    return $true
}

<# ============================================================================
   FUNCTIONS: PROCESSING CHECKS
   ----------------------------------------------------------------------------
   Per-area checks for active Debt Manager processing: New Business, Payments, and
   placeholders for BDL imports and Notice processing.
   Prefix: bat
   ============================================================================ #>

# Checks for New Business batches actively in-flight at maintenance time.
function Get-bat_OBS_OpenNBBatches {
    param()

    Write-Log "Checking New Business batches..." "INFO"

    # Terminal/safe merge statuses - batches at these states are done or not actively processing
    # 1 = NONE, 3 = MERGE_COMPLETE, 6 = PRTL_MRGD_WTH_ERS, 8 = MERGE_CMPLT_WTH_ERS, 10 = PARTIAL_MERGED
    $query = @"
        SELECT
            nbb.new_bsnss_btch_id,
            nbb.new_bsnss_btch_shrt_nm,
            nbb.new_bsnss_btch_stts_cd,
            rsts.new_bsnss_btch_stts_val_txt AS batch_status,
            nbb.cnsmr_mrg_lnk_stts_cd,
            COALESCE(rnbb.cnsmr_mrg_lnk_stts_dscrptn_txt, rsts.new_bsnss_btch_stts_dscrptn_txt) AS display_status,
            nbb.new_bsnss_btch_crt_dt
        FROM dbo.new_bsnss_btch nbb
        LEFT JOIN dbo.ref_cnsmr_mrg_lnk_stts_cd rnbb
            ON nbb.cnsmr_mrg_lnk_stts_cd = rnbb.cnsmr_mrg_lnk_stts_cd
        INNER JOIN dbo.Ref_new_bsnss_btch_stts_cd rsts
            ON nbb.new_bsnss_btch_stts_cd = rsts.new_bsnss_btch_stts_cd
        WHERE CAST(nbb.new_bsnss_btch_crt_dt AS DATE) >= DATEADD(DAY, -7, GETDATE())
          AND nbb.new_bsnss_btch_stts_cd <> 5                                    -- Not DELETED
          AND (nbb.cnsmr_mrg_lnk_stts_cd NOT IN (1, 3, 6, 8, 10)                -- Not terminal/safe merge states
               OR nbb.cnsmr_mrg_lnk_stts_cd IS NULL)                             -- NULL = pre-merge, still in-flight
        ORDER BY nbb.new_bsnss_btch_crt_dt DESC
"@

    $results = Get-bat_OBS_SourceData -Query $query

    $details = @()
    $count = 0

    if ($results) {
        $results = @($results)
        $count = $results.Count

        foreach ($row in $results) {
            $details += [PSCustomObject]@{
                BatchId   = $row.new_bsnss_btch_id
                ShortName = $row.new_bsnss_btch_shrt_nm
                Status    = $row.display_status
                Created   = $row.new_bsnss_btch_crt_dt
            }
        }
    }

    Write-Log "  Found $count open NB batch(es)" $(if ($count -gt 0) { "WARN" } else { "SUCCESS" })

    return [PSCustomObject]@{
        BatchType = "New Business"
        Count     = $count
        Details   = $details
        HasIssues = ($count -gt 0)
    }
}

# Checks for Payment batches actively in-flight at maintenance time.
function Get-bat_OBS_OpenPMTBatches {
    param()

    Write-Log "Checking Payment batches..." "INFO"

    $query = @"
        SELECT
            cpb.cnsmr_pymnt_btch_id,
            cpb.cnsmr_pymnt_btch_nm,
            rpbs.pymnt_btch_stts_val_txt AS batch_status,
            rpt.pymnt_btch_typ_val_txt AS batch_type,
            cpb.cnsmr_pymnt_btch_crt_dttm
        FROM dbo.cnsmr_pymnt_btch cpb
        INNER JOIN dbo.Ref_pymnt_btch_stts_cd rpbs
            ON cpb.cnsmr_pymnt_btch_stts_cd = rpbs.pymnt_btch_stts_cd
        INNER JOIN dbo.Ref_pymnt_btch_typ_cd rpt
            ON cpb.cnsmr_pymnt_btch_typ_cd = rpt.pymnt_btch_typ_cd
        WHERE cpb.cnsmr_pymnt_btch_crt_dttm >= DATEADD(DAY, -7, GETDATE())
          AND cpb.cnsmr_pymnt_btch_stts_cd NOT IN (
              1,   -- ACTIVE (idle)
              4,   -- POSTED (terminal)
              5,   -- PARTIAL (terminal)
              6,   -- FAILED (terminal)
              7,   -- ARCHIVED (terminal)
              11,  -- IMPORTFAILED (terminal)
              14,  -- SCHEDULEFAILED (terminal)
              20,  -- VIRTUALFAILED (terminal)
              27,  -- REVERSALFAILED (terminal)
              29,  -- PROCESSED (terminal)
              30,  -- ACTIVEWITHSUSPENSE (idle)
              31   -- PROCESSEDWITHSUSPENSE (terminal)
          )
        ORDER BY cpb.cnsmr_pymnt_btch_crt_dttm DESC
"@

    $results = Get-bat_OBS_SourceData -Query $query

    $details = @()
    $count = 0

    if ($results) {
        $results = @($results)
        $count = $results.Count

        foreach ($row in $results) {
            $details += [PSCustomObject]@{
                BatchId   = $row.cnsmr_pymnt_btch_id
                ShortName = $row.batch_type
                Status    = $row.batch_status
                Created   = $row.cnsmr_pymnt_btch_crt_dttm
            }
        }
    }

    Write-Log "  Found $count open PMT batch(es)" $(if ($count -gt 0) { "WARN" } else { "SUCCESS" })

    return [PSCustomObject]@{
        BatchType = "Payments"
        Count     = $count
        Details   = $details
        HasIssues = ($count -gt 0)
    }
}

# Placeholder for BDL import checks; returns an empty result until implemented.
function Get-bat_OBS_OpenBDLImports {
    param()

    return [PSCustomObject]@{
        BatchType   = "Bulk Data Loader"
        Count       = 0
        Details     = @()
        HasIssues   = $false
        NotMonitored = $true
    }
}

# Placeholder for Notice processing checks; returns an empty result until implemented.
function Get-bat_OBS_ActiveNoticeProcessing {
    param()

    return [PSCustomObject]@{
        BatchType   = "Notice Processing"
        Count       = 0
        Details     = @()
        HasIssues   = $false
        NotMonitored = $true
    }
}

<# ============================================================================
   FUNCTIONS: ADAPTIVE CARD
   ----------------------------------------------------------------------------
   Construction of the Adaptive Card: per-section elements and the full card JSON
   payload sent to Teams.
   Prefix: bat
   ============================================================================ #>

# Builds the Adaptive Card elements for one processing section.
function New-bat_OBS_SectionElements {
    param(
        [PSCustomObject]$CheckResult
    )

    $elements = @()
    $sectionLabel = $CheckResult.BatchType.ToUpper()

    # -- Determine state color and summary text --

    if ($CheckResult.NotMonitored) {
        # default text, no color override
        $stateColor = $null
        $summaryText = "Not yet monitored"
        $summarySubtle = $true
        $headerSubtle = $false
    }
    elseif ($CheckResult.HasIssues) {
        $stateColor = "warning"
        $summaryText = "$($CheckResult.Count) in progress {{WARN}}"
        $summarySubtle = $false
        $headerSubtle = $false
    }
    else {
        $stateColor = "good"
        $summaryText = "No active processing {{CHECK}}"
        $summarySubtle = $false
        $headerSubtle = $false
    }

    # -- Section header row with separator line --

    $headerRow = @{
        type = "ColumnSet"
        separator = $true
        spacing = "medium"
        columns = @(
            @{
                type = "Column"
                width = "stretch"
                items = @(
                    @{
                        type = "TextBlock"
                        text = $sectionLabel
                        weight = "bolder"
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
                        text = $summaryText
                        spacing = "none"
                        horizontalAlignment = "right"
                    }
                )
            }
        )
    }

    # Apply state color to header text
    if ($stateColor) {
        $headerRow.columns[0].items[0].color = $stateColor
        $headerRow.columns[1].items[0].color = $stateColor
    }

    # Apply subtle to summary if needed (not-monitored)
    if ($summarySubtle) {
        $headerRow.columns[1].items[0].isSubtle = $true
    }

    $elements += $headerRow

    # -- Detail rows for active batches (all text in state color) --

    if ($CheckResult.Count -gt 0 -and $CheckResult.Details) {
        $firstRow = $true
        foreach ($batch in $CheckResult.Details) {
            $createdDisplay = if ($batch.Created) {
                ([datetime]$batch.Created).ToString("M/d/yyyy h:mm tt")
            } else { "N/A" }

            $detailRow = @{
                type = "ColumnSet"
                columns = @(
                    @{
                        type = "Column"
                        width = "auto"
                        items = @(
                            @{
                                type = "TextBlock"
                                text = "$($batch.BatchId) - $($batch.ShortName)"
                                weight = "bolder"
                                color = $stateColor
                                spacing = "none"
                                size = "small"
                            }
                        )
                    }
                    @{
                        type = "Column"
                        width = "stretch"
                        items = @(
                            @{
                                type = "TextBlock"
                                text = "$($batch.Status)"
                                color = $stateColor
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
                                text = $createdDisplay
                                color = $stateColor
                                spacing = "none"
                                size = "small"
                                horizontalAlignment = "right"
                            }
                        )
                    }
                )
                spacing = $(if ($firstRow) { "small" } else { "none" })
            }

            $elements += $detailRow
            $firstRow = $false
        }
    }

    return $elements
}

# Builds the Adaptive Card JSON payload for the pre-maintenance processing summary.
function New-bat_OBS_AdaptiveCard {
    param(
        [array]$CheckResults,
        [string]$CardColor
    )

    $dateDisplay = Get-Date -Format "MMMM dd, yyyy - h:mm tt"

    $bodyItems = @()

    # Header container with severity color
    $bodyItems += @{
        type = "Container"
        style = $CardColor
        bleed = $true
        items = @(
            @{
                type = "TextBlock"
                text = "xFACts Pre-Maintenance Processing Summary"
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

    # Section elements - each check gets separator line, colored header, and detail rows
    foreach ($result in $CheckResults) {
        $sectionElements = New-bat_OBS_SectionElements -CheckResult $result
        foreach ($element in $sectionElements) {
            $bodyItems += $element
        }
    }

    # Overall status message
    $totalActive = ($CheckResults | Where-Object { -not $_.NotMonitored } | Measure-Object -Property Count -Sum).Sum
    $monitoredTypes = @($CheckResults | Where-Object { -not $_.NotMonitored }).Count

    if ($totalActive -eq 0) {
        $bodyItems += @{
            type = "TextBlock"
            text = "**No active processing detected. Safe to proceed with maintenance if needed.**"
            color = "good"
            spacing = "medium"
            wrap = $true
            separator = $true
        }
    }
    else {
        $bodyItems += @{
            type = "TextBlock"
            text = "**Verify status of in-progress items before proceeding with any maintenance.**"
            color = "warning"
            spacing = "medium"
            wrap = $true
            separator = $true
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
                        text = "Source: xFACts BatchOps"
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
                        text = "$monitoredTypes of $($CheckResults.Count) checks active"
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
   Runs the processing checks, determines overall severity, builds and sends the
   Adaptive Card, records run status in BatchOps.Status, and reports completion to
   the orchestrator.
   Prefix: (none)
   ============================================================================ #>

# Capture start time for duration reporting.
$scriptStart = Get-Date

# -- Step 1: Initialize configuration and server connections --

$initResult = Initialize-bat_OBS_Configuration

if (-not $initResult) {
    Write-Log "Configuration initialization failed. Exiting." "ERROR"

    if ($TaskId -gt 0) {
        $totalMs = [int]((New-TimeSpan -Start $scriptStart -End (Get-Date)).TotalMilliseconds)
        Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
            -TaskId $TaskId -ProcessId $ProcessId `
            -Status "FAILED" -DurationMs $totalMs `
            -Output "Configuration initialization failed"
    }
    exit 1
}

# Mark as RUNNING in BatchOps.Status
if ($Execute) {
    try {
        Invoke-SqlNonQuery -Query @"
            UPDATE BatchOps.Status
            SET processing_status = 'RUNNING',
                started_dttm = GETDATE()
            WHERE collector_name = 'Send-OpenBatchSummary'
"@ | Out-Null
    }
    catch {
        Write-Log "  Failed to set RUNNING status: $($_.Exception.Message)" "WARN"
    }
}

# -- Step 2: Run all processing checks --

Write-Log "Running processing checks..." "INFO"

# Accumulates per-area check results for the card and severity logic.
$checkResults = @()

# New Business - active check
$checkResults += Get-bat_OBS_OpenNBBatches

# Payments - placeholder (future)
$checkResults += Get-bat_OBS_OpenPMTBatches

# BDL - placeholder (future)
$checkResults += Get-bat_OBS_OpenBDLImports

# Notice Processing - placeholder (future)
$checkResults += Get-bat_OBS_ActiveNoticeProcessing

# -- Step 3: Determine severity and card color --

$totalActive = ($checkResults | Where-Object { -not $_.NotMonitored } | Measure-Object -Property Count -Sum).Sum

if ($totalActive -gt 0) {
    $cardColor = "warning"
    $alertCategory = "WARNING"
    Write-Log "  Overall: WARNING - $totalActive active process(es) detected" "WARN"
}
else {
    $cardColor = "good"
    $alertCategory = "INFO"
    Write-Log "  Overall: INFO - no active processing" "SUCCESS"
}

# -- Step 4: Build Adaptive Card --

Write-Log "Building Adaptive Card..." "INFO"

$cardJson = New-bat_OBS_AdaptiveCard -CheckResults $checkResults -CardColor $cardColor

if (-not $Execute) {
    Write-Log "[Preview] Card JSON:" "DEBUG"
    Write-Log $cardJson "DEBUG"
}

# -- Step 5: Send Teams alert via shared function --

if ($Execute) {
    Write-Log "Sending Teams alert..." "INFO"

    # Build plain text summary for the message field (audit/logging fallback)
    $plainParts = @()
    foreach ($result in $checkResults) {
        if ($result.NotMonitored) { continue }
        $plainParts += "$($result.BatchType): $($result.Count) active"
    }
    $plainSummary = "Pre-Maintenance Summary: " + ($plainParts -join ", ") + "."

    # Row color mirrors alert_category (summary severity), distinct from card content colors.
    # $cardColor (set in Step 3) drives the card container; per-section colors are inside the card.
    $rowColor = switch ($alertCategory) {
        "CRITICAL" { "attention" }
        "WARNING"  { "warning" }
        "INFO"     { "good" }
        default    { "default" }
    }

    Send-TeamsAlert -SourceModule 'BatchOps' -AlertCategory $alertCategory `
        -Title 'Pre-Maintenance Processing Summary' -Message $plainSummary -Color $rowColor `
        -CardJson $cardJson `
        -TriggerType 'OpenBatchSummary' `
        -TriggerValue (Get-Date -Format "yyyy-MM-dd-HH") | Out-Null
}
else {
    Write-Log "[Preview] Would send Teams alert with card_json" "WARN"
}

# -- Summary --

# Capture end time for duration reporting.
$scriptEnd = Get-Date
# Total elapsed wall-clock time.
$scriptDuration = $scriptEnd - $scriptStart

Write-Log "========================================"
Write-Log "  Summary$(if (-not $Execute) { ' [PREVIEW - No changes made]' })"
foreach ($result in $checkResults) {
    $status = if ($result.NotMonitored) { "Not monitored" } else { "$($result.Count) active" }
    Write-Log "  $($result.BatchType): $status"
}
Write-Log "  Overall severity: $alertCategory"
Write-Log "  Card color: $cardColor"
Write-Log "  Duration: $([int]$scriptDuration.TotalMilliseconds) ms"
Write-Log "========================================"

# -- Update BatchOps.Status --

if ($Execute) {
    try {
        $totalMs = [int]$scriptDuration.TotalMilliseconds
        Invoke-SqlNonQuery -Query @"
            UPDATE BatchOps.Status
            SET processing_status = 'IDLE',
                completed_dttm = GETDATE(),
                last_duration_ms = $totalMs,
                last_status = 'SUCCESS'
            WHERE collector_name = 'Send-OpenBatchSummary'
"@ | Out-Null
    }
    catch {
        Write-Log "  Failed to update Status: $($_.Exception.Message)" "WARN"
    }
}

# -- Orchestrator Callback --

if ($TaskId -gt 0) {
    $totalMs = [int]$scriptDuration.TotalMilliseconds
    $outputMsg = "NB: $($checkResults[0].Count) PMT: $($checkResults[1].Count) active. Severity: $alertCategory"
    Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
        -TaskId $TaskId -ProcessId $ProcessId `
        -Status "SUCCESS" -DurationMs $totalMs `
        -Output $outputMsg
}

exit 0
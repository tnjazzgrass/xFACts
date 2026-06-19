<#
.SYNOPSIS
    Shared scoped helper functions for the xFACts BatchOps collectors.

.DESCRIPTION
    Common functions dot-sourced by the BatchOps batch-status collectors
    (Collect-BDLBatchStatus, Collect-NBBatchStatus, Collect-PMTBatchStatus)
    and the pre-maintenance summary (Send-OpenBatchSummary): read-replica
    source querying, availability-group read-server resolution, stall-
    duration formatting, and BatchOps.Status run-state tracking.

    Load order: dot-source xFACts-OrchestratorFunctions.ps1 BEFORE this
    file. Resolve-bat_ReadServer calls the shared Get-AGReplicaRoles, which
    lives in the orchestrator functions; this file declares no imports of
    its own. Dot-source with
    . "$PSScriptRoot\xFACts-BatchOpsFunctions.ps1" after the orchestrator
    functions are already in scope.

.COMPONENT
    BatchOps

.NOTES
    File Name : xFACts-BatchOpsFunctions.ps1
    Location  : E:\xFACts-PowerShell\xFACts-BatchOpsFunctions.ps1

    FILE ORGANIZATION
    -----------------
    CHANGELOG: CHANGE HISTORY
    FUNCTIONS: SOURCE DATA ACCESS
    FUNCTIONS: REPLICA RESOLUTION
    FUNCTIONS: STALL FORMATTING
    FUNCTIONS: STATUS TRACKING
    FUNCTIONS: ALERT DISPATCH
#>

<# ============================================================================
   CHANGELOG: CHANGE HISTORY
   ----------------------------------------------------------------------------
   Dated change history for this file, most recent first. Authoritative
   version tracking lives in dbo.System_Metadata (component BatchOps); this
   section records what changed and when.
   Prefix: (none)
   ============================================================================ #>

# 2026-06-18  Added Send-bat_BatchAlert (FUNCTIONS: ALERT DISPATCH): the
#             shared Jira-plus-Teams alert dispatcher with mandatory
#             RequestLog dedup, replacing the per-check dispatch blocks
#             duplicated across the BDL, NB, and PMT alert evaluators.
#             Callers retain their own alert_count increment and fired
#             tally, which key per-collector tracking tables.
# 2026-06-18  Initial implementation. Extracted the duplicated scoped helpers
#             from the BatchOps collectors into one shared file: Get-bat_-
#             SourceData (read-replica source querying, folded in the OBS
#             copy and standardized on -SuppressProviderContextWarning),
#             Resolve-bat_ReadServer (AG read-server resolution via the
#             shared Get-AGReplicaRoles, replacing the per-collector copies),
#             Get-bat_StallDurationText (stall-duration text), and
#             Set-bat_BatchStatus (BatchOps.Status RUNNING and IDLE writes).

<# ============================================================================
   FUNCTIONS: SOURCE DATA ACCESS
   ----------------------------------------------------------------------------
   Read-replica source querying against the Debt Manager database. Targets
   the resolved read server and tags the connection with the xFACts
   application name.
   Prefix: bat
   ============================================================================ #>

# Run a read-only query against the resolved read replica; returns rows or $null on failure.
function Get-bat_SourceData {
    param(
        [string]$Query,
        [int]$Timeout = 60
    )

    if (-not $script:ReadServer) {
        Write-Log "ReadServer not configured - cannot query source" "ERROR"
        return $null
    }

    try {
        Invoke-Sqlcmd -ServerInstance $script:ReadServer -Database $SourceDB -Query $Query -QueryTimeout $Timeout -ApplicationName $script:XFActsAppName -ErrorAction Stop -SuppressProviderContextWarning -TrustServerCertificate
    }
    catch {
        Write-Log "Source query failed on $($script:ReadServer): $($_.Exception.Message)" "ERROR"
        return $null
    }
}

<# ============================================================================
   FUNCTIONS: REPLICA RESOLUTION
   ----------------------------------------------------------------------------
   Availability-group read-server resolution. Honors an explicit force-
   server override, otherwise resolves the AG topology via the shared
   Get-AGReplicaRoles and selects the replica named by the source-replica
   setting.
   Prefix: bat
   ============================================================================ #>

# Resolve the read server: the forced server if supplied, else the AG replica named by SourceReplica.
function Resolve-bat_ReadServer {
    param(
        [string]$AGName,
        [string]$SourceReplica,
        [string]$ForceSourceServer
    )

    if ($ForceSourceServer) {
        Write-Log "  ReadServer: $ForceSourceServer (forced via parameter)" "WARN"
        Write-Log "  AG detection skipped due to ForceSourceServer" "WARN"
        return $ForceSourceServer
    }

    Write-Log "Detecting AG replica roles..." "INFO"
    $agRoles = Get-AGReplicaRoles -AGName $AGName

    if (-not $agRoles) {
        Write-Log "AG detection failed - cannot determine read server" "ERROR"
        return $null
    }

    Write-Log "  AG PRIMARY: $($agRoles.PRIMARY)" "INFO"
    Write-Log "  AG SECONDARY: $($agRoles.SECONDARY)" "INFO"

    if ($SourceReplica -eq "PRIMARY") {
        $readServer = $agRoles.PRIMARY
    }
    else {
        $readServer = $agRoles.SECONDARY
    }

    if (-not $readServer) {
        Write-Log "Could not determine ReadServer from AG roles" "ERROR"
        return $null
    }

    Write-Log "  ReadServer: $readServer (from GlobalConfig: $SourceReplica)" "SUCCESS"
    return $readServer
}

<# ============================================================================
   FUNCTIONS: STALL FORMATTING
   ----------------------------------------------------------------------------
   Human-readable stall-duration text derived from a poll count and the
   resolved polling interval.
   Prefix: bat
   ============================================================================ #>

# Format a stall poll count as display text, including elapsed minutes when the interval is known.
function Get-bat_StallDurationText {
    param([int]$PollCount)

    if ($null -ne $script:PollingIntervalMinutes) {
        $totalMinutes = [math]::Round($PollCount * $script:PollingIntervalMinutes)
        return "$PollCount polls (~$totalMinutes min)"
    }
    else {
        return "$PollCount polls"
    }
}

<# ============================================================================
   FUNCTIONS: STATUS TRACKING
   ----------------------------------------------------------------------------
   BatchOps.Status run-state writes. Marks a collector RUNNING at start and
   IDLE at completion with duration and final status. Callers gate invocation
   on their own Execute switch.
   Prefix: bat
   ============================================================================ #>

# Write a collector's BatchOps.Status row for the RUNNING (start) or IDLE (completion) transition.
function Set-bat_BatchStatus {
    param(
        [string]$CollectorName,
        [ValidateSet('RUNNING', 'IDLE')]
        [string]$State,
        [string]$Status = 'SUCCESS',
        [int]$DurationMs = 0
    )

    try {
        if ($State -eq 'RUNNING') {
            $statusQuery = @"
            UPDATE BatchOps.Status
            SET processing_status = 'RUNNING',
                started_dttm = GETDATE()
            WHERE collector_name = '$CollectorName'
"@
        }
        else {
            $statusQuery = @"
            UPDATE BatchOps.Status
            SET processing_status = 'IDLE',
                completed_dttm = GETDATE(),
                last_duration_ms = $DurationMs,
                last_status = '$Status'
            WHERE collector_name = '$CollectorName'
"@
        }

        Invoke-SqlNonQuery -Query $statusQuery | Out-Null
    }
    catch {
        Write-Log "  Failed to update Status: $($_.Exception.Message)" "WARN"
    }
}

<# ============================================================================
   FUNCTIONS: ALERT DISPATCH
   ----------------------------------------------------------------------------
   Jira and Teams alert dispatch for the batch collectors. Queues a Jira
   ticket (with mandatory RequestLog deduplication) and/or posts a Teams
   alert per the routing bitmask, sharing the fixed ticket field set and
   due-date logic. Callers own their alert_count bookkeeping.
   Prefix: bat
   ============================================================================ #>

# Dispatch a Jira ticket (deduped) and/or Teams alert per the routing bitmask (1=Teams, 2=Jira, 3=both).
function Send-bat_BatchAlert {
    param(
        [int]$Routing,
        [string]$TriggerType,
        [string]$TriggerValue,
        [string]$CascadingChild,
        [string]$JiraSummary,
        [string]$JiraDescription,
        [string]$TeamsTitle,
        [string]$TeamsMessage,
        [ValidateSet('CRITICAL', 'WARNING')]
        [string]$TeamsCategory,
        [string]$TeamsColor
    )

    # Fixed Jira ticket field set (hardcoded per xFACts convention)
    $jiraProjectKey = 'SD'
    $jiraIssueType = 'Issue'
    $jiraPriority = 'Highest'
    $jiraCascadingFieldId = 'customfield_18401'
    $jiraCascadingParent = 'File Processing'
    $jiraCustomField1Id = 'customfield_10305'
    $jiraCustomField1Value = 'FAC INFORMATION TECHNOLOGY'
    $jiraCustomField2Id = 'customfield_10009'
    $jiraCustomField2Value = 'sd/1b77b626-3ad4-4bee-8727-abc18b68c5fa'
    $jiraEmailRecipients = 'applications@frost-arnett.com'

    # Due date: today if weekday, next business day if weekend (0=Sun, 6=Sat)
    $dayOfWeek = [int](Get-Date).DayOfWeek
    if ($dayOfWeek -eq 0) { $jiraDueDate = (Get-Date).AddDays(1).ToString("yyyy-MM-dd") }
    elseif ($dayOfWeek -eq 6) { $jiraDueDate = (Get-Date).AddDays(2).ToString("yyyy-MM-dd") }
    else { $jiraDueDate = (Get-Date).ToString("yyyy-MM-dd") }

    # Jira ticket (routing 2 or 3)
    if ($Routing -band 2) {
        $jiraDedup = Get-SqlData -Query @"
            SELECT TOP 1 1 AS ticket_exists
            FROM Jira.RequestLog
            WHERE Trigger_Type = '$TriggerType'
              AND Trigger_Value = '$TriggerValue'
              AND StatusCode = 201
              AND TicketKey IS NOT NULL
              AND TicketKey != 'Email'
"@
        if (-not $jiraDedup) {
            Invoke-SqlNonQuery -Query @"
                EXEC Jira.sp_QueueTicket
                    @SourceModule = @SourceModule,
                    @ProjectKey = @ProjectKey,
                    @Summary = @Summary,
                    @Description = @Description,
                    @IssueType = @IssueType,
                    @Priority = @Priority,
                    @EmailRecipients = @EmailRecipients,
                    @CascadingField_ID = @CascadingField_ID,
                    @CascadingField_ParentValue = @CascadingField_ParentValue,
                    @CascadingField_ChildValue = @CascadingField_ChildValue,
                    @CustomField_ID = @CustomField_ID,
                    @CustomField_Value = @CustomField_Value,
                    @CustomField2_ID = @CustomField2_ID,
                    @CustomField2_Value = @CustomField2_Value,
                    @DueDate = @DueDate,
                    @TriggerType = @TriggerType,
                    @TriggerValue = @TriggerValue
"@ -Parameters @{
                SourceModule = 'BatchOps'
                ProjectKey = $jiraProjectKey
                Summary = $JiraSummary
                Description = $JiraDescription
                IssueType = $jiraIssueType
                Priority = $jiraPriority
                EmailRecipients = $jiraEmailRecipients
                CascadingField_ID = $jiraCascadingFieldId
                CascadingField_ParentValue = $jiraCascadingParent
                CascadingField_ChildValue = $CascadingChild
                CustomField_ID = $jiraCustomField1Id
                CustomField_Value = $jiraCustomField1Value
                CustomField2_ID = $jiraCustomField2Id
                CustomField2_Value = $jiraCustomField2Value
                DueDate = $jiraDueDate
                TriggerType = $TriggerType
                TriggerValue = $TriggerValue
            } | Out-Null
            Write-Log "    Jira ticket queued for $TriggerType/$TriggerValue" "SUCCESS"
        }
        else {
            Write-Log "    Jira dedup: ticket exists for $TriggerType/$TriggerValue" "INFO"
        }
    }

    # Teams alert (routing 1 or 3)
    if ($Routing -band 1) {
        Send-TeamsAlert -SourceModule 'BatchOps' -AlertCategory $TeamsCategory `
            -Title $TeamsTitle -Message $TeamsMessage -Color $TeamsColor `
            -TriggerType $TriggerType -TriggerValue $TriggerValue | Out-Null
    }
}
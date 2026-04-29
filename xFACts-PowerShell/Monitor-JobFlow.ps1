<#
.SYNOPSIS
    xFACts - JobFlow Monitor

.DESCRIPTION
    xFACts - JobFlow
    Script: Monitor-JobFlow.ps1
    Version: Tracked in dbo.System_Metadata (component: JobFlow)

    Monitors Debt Manager job flows, tracking execution progress, detecting 
    stalls, validating completions, and alerting on issues. Replaces the 
    monolithic sp_StateMonitor with a PowerShell-driven approach that supports
    multi-server connectivity for future xFACts isolation.
    
    Includes integrated ConfigSync: synchronizes JobFlow.FlowConfig with Debt 
    Manager flow definitions on every cycle, detecting new, deactivated, and 
    reactivated flows. Replaces the standalone sp_ConfigSync stored procedure.
    
    Key behaviors:
    - Reads from configurable replica (PRIMARY or SECONDARY) for crs5_oltp queries
    - Writes to xFACts via the AG listener for all JobFlow.* table updates
    - AG-aware: automatically detects current PRIMARY/SECONDARY roles
    - Supports preview mode for safe testing

    CHANGELOG
    ---------
    2026-04-28  Standardized Teams alerting via Send-TeamsAlert shared function
                Converted both Teams alert sites from EXEC sp_QueueAlert to
                  Send-TeamsAlert (Stall in Step 5, MissingFlow in Step 6)
                Inline Teams.RequestLog dedup queries removed (handled by
                  shared function)
                Added title icons for visual scanning consistency:
                  Stall:        {{FIRE}} JobFlow System Stall Detected
                  MissingFlow:  {{WARN}} Missing Job Flow: <flowCode>
                Severity, color, and trigger_value schemes unchanged
                Jira queue calls (Stall, MissingFlow, NewFlow, Deactivated,
                  Validation) untouched - Jira standardization is a separate
                  audit
    2026-03-15  Stall detection IDLE path fix
                Moved counterBefore read before IDLE exit checks in Step 5
                RESET events now log correctly when system goes from stalled to idle
                Step 2 dedup optimization: date-filtered query replaces full table scan
                Removed dead exclusionClause code block from Step 2
                Removed debug Write-Log lines from Step 6
    2026-03-14  Validation date filter fix
                Removed execution_date >= today filter from Step 6 query
                Flows completing after midnight were permanently orphaned
                in COMPLETE state, blocking early exit on every cycle
                Added tracking_id > 0 to early exit unresolved flows check
                Backfill row (tracking_id 0) was always counted as unresolved
                Reset Status rows for skipped steps on early exit
                CC cards were showing stale values from last full pipeline run
    2026-03-11  Migrated to Initialize-XFActsScript shared infrastructure
                Removed inline Write-Log, Get-xFACtsData, Invoke-xFACtsWrite
                Renamed $xFACtsServer/$xFACtsDB to $ServerInstance/$Database
                Updated header to component-level versioning format
    2026-03-03  Early exit now checks xFACts for unresolved flows
                Fixes last flow in a run staying in EXECUTING
                Early exit when no active job activity detected
                Skips Steps 1-6 when no flows executing (performance)
                Fixed incorrect TriggerType on Jira queue calls in stall
                and missing flow alert paths
    2026-02-12  Bug fix: missing RESET event in StallDetectionLog
                on IDLE transition after stall counter increment
    2026-02-11  Bug fix: stall alert never firing
                StallDetectionLog INSERT moved after dedup check
    2026-02-04  Orchestrator v2 integration
                TaskId/ProcessId parameters, FIRE_AND_FORGET callback
                Relocated to E:\xFACts-PowerShell on FA-SQLDBB
    2026-02-01  Integrated ConfigSync into monitor cycle
                Detects new/deactivated/reactivated DM flows
                Inserts UNCONFIGURED stub rows, queues Jira tickets for drift
                Promoted SourceReplica from JobFlow to Core GlobalConfig module
    2026-01-31  Bug fix: fast-completing flows not tracked
                Flow detection now includes COMPLETED status (stts_cd 3)
    2026-01-29  Initial implementation
                AG-aware replica detection, embedded SQL logic
                Multi-server connectivity, preview mode support
                Replaces JobFlow.sp_StateMonitor

.PARAMETER ServerInstance
    SQL Server instance hosting xFACts database (default: AVG-PROD-LSNR)

.PARAMETER Database
    xFACts database name (default: xFACts)

.PARAMETER SourceDB
    Source database for Debt Manager data (default: crs5_oltp)

.PARAMETER Execute
    Perform writes. Without this flag, runs in preview/dry-run mode.

.PARAMETER ForceSourceServer
    Override the GlobalConfig replica setting and connect to specific server for reads.
    Useful for testing or when AG detection fails.

.PARAMETER TaskId
    Orchestrator TaskLog ID passed by the v2 engine at launch. Used for task 
    completion callback. Default 0 (no callback when run manually).

.PARAMETER ProcessId
    Orchestrator ProcessRegistry ID passed by the v2 engine at launch. Used for 
    task completion callback. Default 0 (no callback when run manually).

================================================================================
DEPLOYMENT REMINDERS
================================================================================
1. This script should be deployed to both AG servers initially, and will move
   to the dedicated xFACts server when that migration occurs.
2. The service account running this script needs:
   - Read access to crs5_oltp on both DM-PROD-DB and DM-PROD-REP
   - Read/Write access to xFACts database
3. Required GlobalConfig entries:
   - Core.AGName (default: DMPRODAG)
   - Core.SourceReplica (PRIMARY or SECONDARY, default: SECONDARY)
   - JobFlow.StallThreshold (default: 6)
4. Required schema change for ConfigSync integration:
   - FlowConfig CHECK constraint must include 'UNCONFIGURED' in expected_schedule

================================================================================
#>

[CmdletBinding()]
param(
    [string]$ServerInstance = "AVG-PROD-LSNR",
    [string]$Database = "xFACts",
    [string]$SourceDB = "crs5_oltp",
    [switch]$Execute,
    [string]$ForceSourceServer = $null,
    [long]$TaskId = 0,
    [int]$ProcessId = 0
)

# ============================================================================
# STANDARD INITIALIZATION
# ============================================================================

. "$PSScriptRoot\xFACts-OrchestratorFunctions.ps1"

Initialize-XFActsScript -ScriptName 'Monitor-JobFlow' `
    -ServerInstance $ServerInstance -Database $Database -Execute:$Execute

# ============================================================================
# GLOBAL VARIABLES
# ============================================================================

$Script:AGPrimary = $null        # Current AG primary server (physical name)
$Script:AGSecondary = $null      # Current AG secondary server (physical name)
$Script:ReadServer = $null       # Server for crs5_oltp reads (determined by GlobalConfig)
$Script:WriteServer = $null      # Server for xFACts writes (AG listener)
$Script:Config = @{}             # GlobalConfig settings
$Script:ExecutionDate = $null    # Captured at start for consistency across all steps

# ============================================================================
# FUNCTIONS
# ============================================================================

function Get-SourceData {
    <#
    .SYNOPSIS
        Execute a query against the source database (crs5_oltp) on the configured replica
    #>
    param(
        [string]$Query,
        [int]$Timeout = 60
    )
    
    if (-not $Script:ReadServer) {
        Write-Log "ReadServer not configured - cannot query source" "ERROR"
        return $null
    }
    
    try {
        Invoke-Sqlcmd -ServerInstance $Script:ReadServer -Database $SourceDB -Query $Query -QueryTimeout $Timeout -ApplicationName $script:XFActsAppName -ErrorAction Stop -TrustServerCertificate
    }
    catch {
        Write-Log "Source query failed on $($Script:ReadServer): $($_.Exception.Message)" "ERROR"
        return $null
    }
}

# ============================================================================
# CONFIGURATION FUNCTIONS
# ============================================================================

function Get-AGReplicaRoles {
    <#
    .SYNOPSIS
        Queries the Availability Group to determine current PRIMARY and SECONDARY servers
    .RETURNS
        Hashtable with 'PRIMARY' and 'SECONDARY' keys containing server names
    #>
    
    $agName = $Script:Config.AGName
    
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

function Initialize-Configuration {
    <#
    .SYNOPSIS
        Loads GlobalConfig settings and determines server connections
    .RETURNS
        $true if successful, $false otherwise
    #>
    
    Write-Log "Loading configuration..." "INFO"
    
    # Capture execution date for consistency across all steps
    $Script:ExecutionDate = Get-Date -Format "yyyy-MM-dd"
    Write-Log "  ExecutionDate: $($Script:ExecutionDate)" "INFO"
    
    # Load GlobalConfig settings for Core and JobFlow
    $configQuery = @"
        SELECT module_name, setting_name, setting_value
        FROM dbo.GlobalConfig
        WHERE module_name IN ('Core', 'JobFlow', 'Shared', 'dbo')
          AND is_active = 1
"@
    
    $configResults = Get-SqlData -Query $configQuery
    
    # Set defaults
    $Script:Config = @{
        AGName = "DMPRODAG"
        SourceReplica = "SECONDARY"
        StallThreshold = 6
    }
    
    # Override with GlobalConfig values
    if ($configResults) {
        foreach ($row in $configResults) {
            switch ($row.setting_name) {
                "AGName"         { $Script:Config.AGName = $row.setting_value }
                "SourceReplica"  { $Script:Config.SourceReplica = $row.setting_value }
                "StallThreshold" { $Script:Config.StallThreshold = [int]$row.setting_value }
            }
        }
    }
    
    Write-Log "  AGName: $($Script:Config.AGName)" "INFO"
    Write-Log "  SourceReplica: $($Script:Config.SourceReplica)" "INFO"
    Write-Log "  StallThreshold: $($Script:Config.StallThreshold)" "INFO"
    
    # Set write server (always the listener/xFACts server)
    $Script:WriteServer = $ServerInstance
    
    # Determine read server
    if ($ForceSourceServer) {
        # Manual override - skip AG detection
        $Script:ReadServer = $ForceSourceServer
        Write-Log "  ReadServer: $($Script:ReadServer) (forced via parameter)" "WARN"
        Write-Log "  AG detection skipped due to ForceSourceServer" "WARN"
    }
    else {
        # AG detection
        Write-Log "Detecting AG replica roles..." "INFO"
        $agRoles = Get-AGReplicaRoles
        
        if (-not $agRoles) {
            Write-Log "AG detection failed - cannot determine read server" "ERROR"
            return $false
        }
        
        # Store both roles for reference
        $Script:AGPrimary = $agRoles.PRIMARY
        $Script:AGSecondary = $agRoles.SECONDARY
        
        Write-Log "  AG PRIMARY: $($Script:AGPrimary)" "INFO"
        Write-Log "  AG SECONDARY: $($Script:AGSecondary)" "INFO"
        
        # Select read server based on config
        if ($Script:Config.SourceReplica -eq "PRIMARY") {
            $Script:ReadServer = $Script:AGPrimary
        }
        else {
            $Script:ReadServer = $Script:AGSecondary
        }
        
        if (-not $Script:ReadServer) {
            Write-Log "Could not determine ReadServer from AG roles" "ERROR"
            return $false
        }
        
        Write-Log "  ReadServer: $($Script:ReadServer) (from GlobalConfig: $($Script:Config.SourceReplica))" "SUCCESS"
    }
    
    Write-Log "  WriteServer: $($Script:WriteServer)" "INFO"
    
    return $true
}

# ============================================================================
# JOBFLOW MONITORING FUNCTIONS
# ============================================================================

function Step-ConfigSync {
    <#
    .SYNOPSIS
        Synchronizes JobFlow.FlowConfig with Debt Manager flow definitions.
        Detects new, deactivated, and reactivated flows. Inserts stub rows
        for new flows and queues Jira tickets for configuration drift.
    .NOTES
        Replaces JobFlow.sp_ConfigSync. Runs every cycle (lightweight with
        ~20 active flows and ~45 total config rows).
    #>
    param([bool]$PreviewOnly = $true)
    
    Write-Log "Step: Config Sync" "STEP"
    
    # Update status: started
    if (-not $PreviewOnly) {
        Invoke-SqlNonQuery -Query @"
            UPDATE JobFlow.Status 
            SET started_dttm = GETDATE(), 
                last_status = NULL, 
                last_error_message = NULL 
            WHERE process_name = 'ConfigSync'
"@ | Out-Null
    }
    
    try {
    
    $syncResults = @{
        DMFlowCount = 0
        NewFlows = 0
        DeactivatedFlows = 0
        ReactivatedFlows = 0
        TicketsQueued = 0
        StubsInserted = 0
    }
    
    $syncDttm = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    
    # ── DUE DATE CALCULATION (next business day if weekend) ──
    $dayOfWeek = (Get-Date).DayOfWeek
    $dueDate = switch ($dayOfWeek) {
        'Saturday' { (Get-Date).AddDays(2).ToString('yyyy-MM-dd') }
        'Sunday'   { (Get-Date).AddDays(1).ToString('yyyy-MM-dd') }
        default    { (Get-Date).ToString('yyyy-MM-dd') }
    }
    
    # ── STEP 1: Get current active flows from DM ──
    
    $dmFlowsQuery = @"
        SELECT 
            job_sqnc_id,
            RTRIM(job_sqnc_shrt_nm) AS job_sqnc_shrt_nm,
            RTRIM(job_sqnc_nm) AS job_sqnc_nm
        FROM dbo.job_sqnc
        WHERE job_sqnc_actv_flg = 'Y'
"@
    
    $dmFlows = Get-SourceData -Query $dmFlowsQuery
    
    if (-not $dmFlows) {
        Write-Log "  No active flows returned from DM - skipping sync" "WARN"
        return $syncResults
    }
    
    $dmFlows = @($dmFlows)  # Ensure array
    $syncResults.DMFlowCount = $dmFlows.Count
    Write-Log "  Active flows in DM: $($dmFlows.Count)" "INFO"
    
    # ── Load current FlowConfig ──
    
    $configQuery = @"
        SELECT config_id, job_sqnc_id, job_sqnc_shrt_nm, job_sqnc_nm, 
               dm_is_active, expected_schedule
        FROM JobFlow.FlowConfig
        WHERE job_sqnc_id > 0
"@
    
    $configFlows = Get-SqlData -Query $configQuery
    $configFlows = if ($configFlows) { @($configFlows) } else { @() }
    
    # Build lookup by job_sqnc_id for efficient comparison
    $configLookup = @{}
    foreach ($cf in $configFlows) {
        $configLookup[[Int64]$cf.job_sqnc_id] = $cf
    }
    
    $dmLookup = @{}
    foreach ($dm in $dmFlows) {
        $dmLookup[[Int64]$dm.job_sqnc_id] = $dm
    }

    
    # ── STEP 2: Detect NEW flows (in DM, not in FlowConfig) ──
    
    $newFlows = @($dmFlows | Where-Object { -not $configLookup.ContainsKey($_.job_sqnc_id) })
    $syncResults.NewFlows = $newFlows.Count
    
    if ($newFlows.Count -gt 0) {
        Write-Log "  New flows detected: $($newFlows.Count)" "WARN"
        foreach ($flow in $newFlows) {
            Write-Log "    NEW: $($flow.job_sqnc_shrt_nm) (ID: $($flow.job_sqnc_id)) - $($flow.job_sqnc_nm)" "WARN"
        }
    }
    else {
        Write-Log "  No new flows detected" "DEBUG"
    }
    
    # ── STEP 3: Detect DEACTIVATED flows (in FlowConfig as active, not in DM active) ──
    
    $deactivatedFlows = @($configFlows | Where-Object { 
        $_.dm_is_active -eq 1 -and -not $dmLookup.ContainsKey([Int64]$_.job_sqnc_id) 
    })
    $syncResults.DeactivatedFlows = $deactivatedFlows.Count
    
    if ($deactivatedFlows.Count -gt 0) {
        Write-Log "  Deactivated flows detected: $($deactivatedFlows.Count)" "WARN"
        foreach ($flow in $deactivatedFlows) {
            Write-Log "    DEACTIVATED: $($flow.job_sqnc_shrt_nm) (ID: $($flow.job_sqnc_id))" "WARN"
        }
    }
    else {
        Write-Log "  No deactivated flows detected" "DEBUG"
    }
    
    # ── STEP 4: Detect REACTIVATED flows (in FlowConfig as inactive, now in DM active) ──
    
    $reactivatedFlows = @($configFlows | Where-Object { 
        $_.dm_is_active -eq 0 -and $dmLookup.ContainsKey([Int64]$_.job_sqnc_id) 
    })
    $syncResults.ReactivatedFlows = $reactivatedFlows.Count
    
    if ($reactivatedFlows.Count -gt 0) {
        Write-Log "  Reactivated flows detected: $($reactivatedFlows.Count)" "WARN"
        foreach ($flow in $reactivatedFlows) {
            Write-Log "    REACTIVATED: $($flow.job_sqnc_shrt_nm) (ID: $($flow.job_sqnc_id))" "WARN"
        }
    }
    else {
        Write-Log "  No reactivated flows detected" "DEBUG"
    }
    
    # ── STEP 5: Insert stub rows and queue Jira tickets for NEW flows ──
    
    if ($newFlows.Count -gt 0 -and -not $PreviewOnly) {
        foreach ($flow in $newFlows) {
            $flowCode = $flow.job_sqnc_shrt_nm -replace "'", "''"
            $flowName = if ($flow.job_sqnc_nm) { $flow.job_sqnc_nm -replace "'", "''" } else { 'N/A' }
            $flowId = $flow.job_sqnc_id
            
            # Insert stub row into FlowConfig
            $insertQuery = @"
                INSERT INTO JobFlow.FlowConfig (
                    job_sqnc_id, job_sqnc_shrt_nm, job_sqnc_nm,
                    dm_is_active, dm_last_sync_dttm,
                    is_monitored, expected_schedule,
                    alert_on_missing, alert_on_critical_failure,
                    created_by
                ) VALUES (
                    $flowId, '$flowCode', '$flowName',
                    1, '$syncDttm',
                    0, 'UNCONFIGURED',
                    0, 0,
                    'Monitor-JobFlow'
                )
"@
            $insertResult = Invoke-SqlNonQuery -Query $insertQuery
            if ($insertResult) {
                $syncResults.StubsInserted++
                Write-Log "    Stub row inserted for $flowCode" "SUCCESS"
            }
            
            # Check Jira deduplication - success in RequestLog OR recent attempt in TicketQueue
            $jiraExistsQuery = @"
                SELECT 1 FROM Jira.RequestLog
                WHERE Trigger_Type = 'JobFlow_NewFlow'
                  AND Trigger_Value = '$flowCode'
                  AND StatusCode = 201
                  AND TicketKey IS NOT NULL
                  AND TicketKey != 'Email'
                UNION ALL
                SELECT 1 FROM Jira.TicketQueue
                WHERE TriggerType = 'JobFlow_NewFlow'
                  AND TriggerValue = '$flowCode'
                  AND TicketStatus IN ('Pending', 'Failed', 'EmailSent')
"@
            $jiraExists = Get-SqlData -Query $jiraExistsQuery
            
            if (-not $jiraExists) {
                $ticketSummary = "New DM Job Flow Detected: $flowCode"
                $ticketDescription = @"
A new job flow has been detected in Debt Manager that is not configured in xFACts JobFlow monitoring.

Flow Code: $flowCode
Flow Name: $flowName
Flow ID: $flowId
Detection Date: $syncDttm

A stub entry has been created in JobFlow.FlowConfig with expected_schedule = UNCONFIGURED.

ACTION REQUIRED:
1. Open the JobFlow Monitoring page in xFACts Control Center
2. Locate the unconfigured flow entry
3. Set the expected schedule and enable monitoring if appropriate
4. Configure JobFlow.Schedule if the flow runs on a fixed schedule

REFERENCE:
Database: xFACts
Table: JobFlow.FlowConfig
"@
                $jiraQuery = @"
                    EXEC Jira.sp_QueueTicket
                        @SourceModule = 'JobFlow',
                        @ProjectKey = 'SD',
                        @Summary = '$($ticketSummary -replace "'", "''")',
                        @Description = '$($ticketDescription -replace "'", "''")',
                        @IssueType = 'Issue',
                        @Priority = 'High',
                        @EmailRecipients = 'applications@frost-arnett.com',
                        @CascadingField_ID = 'customfield_18401',
                        @CascadingField_ParentValue = 'Debt Manager',
                        @CascadingField_ChildValue = 'DM Configuration Issues',
                        @CustomField_ID = 'customfield_10305',
                        @CustomField_Value = 'FAC INFORMATION TECHNOLOGY',
                        @CustomField2_ID = 'customfield_10009',
                        @CustomField2_Value = 'sd/1b77b626-3ad4-4bee-8727-abc18b68c5fa',
                        @DueDate = '$dueDate',
                        @TriggerType = 'JobFlow_NewFlow',
                        @TriggerValue = '$flowCode'
"@
                Invoke-SqlNonQuery -Query $jiraQuery | Out-Null
                $syncResults.TicketsQueued++
                Write-Log "    Jira ticket queued for $flowCode" "SUCCESS"
            }
            else {
                Write-Log "    Jira ticket already exists for $flowCode - suppressed" "INFO"
            }
        }
    }
    
    # ── STEP 6: Queue Jira tickets for DEACTIVATED flows ──
    
    if ($deactivatedFlows.Count -gt 0 -and -not $PreviewOnly) {
        foreach ($flow in $deactivatedFlows) {
            $flowCode = $flow.job_sqnc_shrt_nm -replace "'", "''"
            $flowName = if ($flow.job_sqnc_nm) { $flow.job_sqnc_nm -replace "'", "''" } else { 'N/A' }
            $flowId = $flow.job_sqnc_id
            
            # Check Jira deduplication - success in RequestLog OR recent attempt in TicketQueue
            $jiraExistsQuery = @"
                SELECT 1 FROM Jira.RequestLog
                WHERE Trigger_Type = 'JobFlow_Deactivated'
                  AND Trigger_Value = '$flowCode'
                  AND StatusCode = 201
                  AND TicketKey IS NOT NULL
                  AND TicketKey != 'Email'
                UNION ALL
                SELECT 1 FROM Jira.TicketQueue
                WHERE TriggerType = 'JobFlow_Deactivated'
                  AND TriggerValue = '$flowCode'
                  AND TicketStatus IN ('Pending', 'Failed', 'EmailSent')
"@
            $jiraExists = Get-SqlData -Query $jiraExistsQuery
            
            if (-not $jiraExists) {
                $ticketSummary = "DM Job Flow Deactivated: $flowCode"
                $ticketDescription = @"
A job flow configured in xFACts has been deactivated in Debt Manager.

Flow Code: $flowCode
Flow Name: $flowName
Flow ID: $flowId
Detection Date: $syncDttm

ACTION REQUIRED:
1. Confirm flow deactivation was intentional
2. Open the JobFlow Monitoring page in xFACts Control Center
3. Update or disable the flow configuration as appropriate

REFERENCE:
Database: xFACts
Table: JobFlow.FlowConfig
"@
                $jiraQuery = @"
                    EXEC Jira.sp_QueueTicket
                        @SourceModule = 'JobFlow',
                        @ProjectKey = 'SD',
                        @Summary = '$($ticketSummary -replace "'", "''")',
                        @Description = '$($ticketDescription -replace "'", "''")',
                        @IssueType = 'Issue',
                        @Priority = 'High',
                        @EmailRecipients = 'applications@frost-arnett.com',
                        @CascadingField_ID = 'customfield_18401',
                        @CascadingField_ParentValue = 'Debt Manager',
                        @CascadingField_ChildValue = 'DM Configuration Issues',
                        @CustomField_ID = 'customfield_10305',
                        @CustomField_Value = 'FAC INFORMATION TECHNOLOGY',
                        @CustomField2_ID = 'customfield_10009',
                        @CustomField2_Value = 'sd/1b77b626-3ad4-4bee-8727-abc18b68c5fa',
                        @DueDate = '$dueDate',
                        @TriggerType = 'JobFlow_Deactivated',
                        @TriggerValue = '$flowCode'
"@
                Invoke-SqlNonQuery -Query $jiraQuery | Out-Null
                $syncResults.TicketsQueued++
                Write-Log "    Jira ticket queued for $flowCode" "SUCCESS"
            }
            else {
                Write-Log "    Jira ticket already exists for $flowCode - suppressed" "INFO"
            }
        }
    }
    
    # ── STEP 7: Update FlowConfig sync status ──
    
    if (-not $PreviewOnly) {
        # Update dm_last_sync_dttm for all flows that have been synced before
        $updateSyncQuery = @"
            UPDATE JobFlow.FlowConfig
            SET dm_last_sync_dttm = '$syncDttm',
                modified_dttm = '$syncDttm',
                modified_by = 'Monitor-JobFlow'
            WHERE dm_is_active IS NOT NULL
"@
        Invoke-SqlNonQuery -Query $updateSyncQuery | Out-Null
        
        # Mark deactivated flows
        if ($deactivatedFlows.Count -gt 0) {
            $deactivatedIds = ($deactivatedFlows | ForEach-Object { $_.config_id }) -join ','
            $deactivateQuery = @"
                UPDATE JobFlow.FlowConfig
                SET dm_is_active = 0,
                    modified_dttm = '$syncDttm',
                    modified_by = 'Monitor-JobFlow'
                WHERE config_id IN ($deactivatedIds)
"@
            Invoke-SqlNonQuery -Query $deactivateQuery | Out-Null
        }
        
        # Mark reactivated flows
        if ($reactivatedFlows.Count -gt 0) {
            $reactivatedIds = ($reactivatedFlows | ForEach-Object { $_.config_id }) -join ','
            $reactivateQuery = @"
                UPDATE JobFlow.FlowConfig
                SET dm_is_active = 1,
                    modified_dttm = '$syncDttm',
                    modified_by = 'Monitor-JobFlow'
                WHERE config_id IN ($reactivatedIds)
"@
            Invoke-SqlNonQuery -Query $reactivateQuery | Out-Null
        }
        
        Write-Log "  Sync status updated" "SUCCESS"
    }
    
    # ── SUMMARY ──
    
    if ($syncResults.NewFlows -eq 0 -and $syncResults.DeactivatedFlows -eq 0 -and $syncResults.ReactivatedFlows -eq 0) {
        Write-Log "  Config sync complete - no drift detected" "SUCCESS"
    }
    else {
        Write-Log "  Config sync complete - drift detected (New: $($syncResults.NewFlows), Deactivated: $($syncResults.DeactivatedFlows), Reactivated: $($syncResults.ReactivatedFlows))" "WARN"
    }
    
# Update status: success
    # Query current unresolved drift (persists until manually resolved)
    $currentDriftQuery = @"
        SELECT COUNT(*) AS drift_count
        FROM JobFlow.FlowConfig fc
        WHERE fc.job_sqnc_id > 0
          AND (fc.expected_schedule = 'UNCONFIGURED'
           OR (fc.dm_is_active = 0 AND fc.is_monitored = 1)
           OR (fc.dm_is_active = 1 AND fc.is_monitored = 0 
               AND EXISTS (SELECT 1 FROM JobFlow.Schedule s WHERE s.job_sqnc_id = fc.job_sqnc_id)))
"@
    $currentDrift = Get-SqlData -Query $currentDriftQuery
    $driftCount = if ($currentDrift -and $currentDrift.drift_count) { [int]$currentDrift.drift_count } else { 0 }
    
    if (-not $PreviewOnly) {
        Invoke-SqlNonQuery -Query @"
            UPDATE JobFlow.Status 
            SET completed_dttm = GETDATE(), 
                last_status = 'SUCCESS', 
                last_result_count = $driftCount 
            WHERE process_name = 'ConfigSync'
"@ | Out-Null
    }
    
    return $syncResults
    }
    catch {
        $errorMessage = $_.Exception.Message -replace "'", "''"
        Write-Log "  Error in ConfigSync: $($_.Exception.Message)" "ERROR"
        
        if (-not $PreviewOnly) {
            Invoke-SqlNonQuery -Query @"
                UPDATE JobFlow.Status 
                SET completed_dttm = GETDATE(), 
                    last_status = 'FAILED', 
                    last_error_message = '$errorMessage'
                WHERE process_name = 'ConfigSync'
"@ | Out-Null
        }
        
        return $syncResults
    }
}

function Step-DetectFlows {

    <#
    .SYNOPSIS
        Detects new job flows that have started in the last 24 hours
        and inserts tracking records for any not already being monitored
    #>
    param([bool]$PreviewOnly = $true)
    
    Write-Log "Step: Detect New Flows" "STEP"
    
    $flowsDetected = 0
    
    # Update status: started
    if (-not $PreviewOnly) {
        Invoke-SqlNonQuery -Query @"
            UPDATE JobFlow.Status 
            SET started_dttm = GETDATE(), 
                last_status = NULL, 
                last_error_message = NULL 
            WHERE process_name = 'DetectFlows'
"@ | Out-Null
    }
    
    try {
        # Query source for flows started in last 24 hours that we're not already tracking
        $newFlowsQuery = @"
            SELECT DISTINCT
                jsl.job_sqnc_log_id,
                jsl.job_sqnc_id,
                js.job_sqnc_shrt_nm,
                js.job_sqnc_nm,
                CAST(jsl.job_sqnc_exctn_dttm AS DATE) AS execution_date,
                jsl.job_sqnc_exctn_dttm AS started_dttm
            FROM dbo.job_sqnc_log jsl
            INNER JOIN dbo.job_sqnc js ON js.job_sqnc_id = jsl.job_sqnc_id
            WHERE jsl.job_sqnc_exctn_dttm >= DATEADD(HOUR, -24, GETDATE())
              AND jsl.job_sqnc_stts_cd IN (1, 3)
              AND js.job_sqnc_actv_flg = 'Y'
"@
        
        $newFlows = Get-SourceData -Query $newFlowsQuery
        
        if (-not $newFlows) {
            Write-Log "  No new flows found in source" "DEBUG"
        }
        else {
            foreach ($flow in @($newFlows)) {
                # Check if we're already tracking this flow
                $existsQuery = @"
                    SELECT 1 FROM JobFlow.FlowExecutionTracking 
                    WHERE job_sqnc_log_id = $($flow.job_sqnc_log_id)
"@
                $exists = Get-SqlData -Query $existsQuery
                
                if (-not $exists) {
                    $flowsDetected++
                    Write-Log "  New flow: $($flow.job_sqnc_shrt_nm) (job_sqnc_log_id: $($flow.job_sqnc_log_id))" "INFO"
                    
                    if (-not $PreviewOnly) {
                        # Get expected job count from source
                        $expectedJobsQuery = @"
                            SELECT COUNT(*) AS job_count
                            FROM dbo.job_sqnc_exctn_log jsel
                            WHERE jsel.job_sqnc_log_id = $($flow.job_sqnc_log_id)
"@
                        $expectedJobs = Get-SourceData -Query $expectedJobsQuery
                        $expectedJobCount = if ($expectedJobs) { $expectedJobs.job_count } else { 0 }
                        
                        # Build expected jobs JSON
                        $jobListQuery = @"
                            SELECT jsel.job_log_id, j.job_shrt_nm,
                                   ROW_NUMBER() OVER (ORDER BY jsel.job_sqnc_exctn_log_id) AS execution_sequence
                            FROM dbo.job_sqnc_exctn_log jsel
                            INNER JOIN dbo.job_log jl ON jl.job_log_id = jsel.job_log_id
                            INNER JOIN dbo.job j ON j.job_id = jl.job_id
                            WHERE jsel.job_sqnc_log_id = $($flow.job_sqnc_log_id)
                            ORDER BY jsel.job_sqnc_exctn_log_id
"@
                        $jobList = Get-SourceData -Query $jobListQuery
                        
                        $expectedJobsJson = 'NULL'
                        if ($jobList) {
                            $jobArray = @($jobList | ForEach-Object {
                                "{`"job_log_id`":$($_.job_log_id),`"job_shrt_nm`":`"$($_.job_shrt_nm)`",`"sequence`":$($_.execution_sequence)}"
                            })
                            $expectedJobsJson = "'[$($jobArray -join ',')]'"
                        }
                        
                        $insertQuery = @"
                            INSERT INTO JobFlow.FlowExecutionTracking (
                                job_sqnc_log_id, job_sqnc_id, job_sqnc_shrt_nm,
                                execution_date, execution_state,
                                expected_job_count, expected_jobs_json
                            )
                            VALUES (
                                $($flow.job_sqnc_log_id), $($flow.job_sqnc_id), 
                                '$($flow.job_sqnc_shrt_nm)',
                                '$($flow.execution_date.ToString("yyyy-MM-dd"))', 'DETECTED',
                                $expectedJobCount, $expectedJobsJson
                            )
"@
                        Invoke-SqlNonQuery -Query $insertQuery | Out-Null
                    }
                }
            }
        }
        
        Write-Log "  Flows detected: $flowsDetected" "INFO"
        
        # Update status: success
        if (-not $PreviewOnly) {
            Invoke-SqlNonQuery -Query @"
                UPDATE JobFlow.Status 
                SET completed_dttm = GETDATE(), 
                    last_status = 'SUCCESS', 
                    last_result_count = $flowsDetected 
                WHERE process_name = 'DetectFlows'
"@ | Out-Null
        }
        
        return @{ FlowsDetected = $flowsDetected }
    }
    catch {
        $errorMessage = $_.Exception.Message -replace "'", "''"
        Write-Log "  Error in DetectFlows: $($_.Exception.Message)" "ERROR"
        
        # Update status: failed
        if (-not $PreviewOnly) {
            Invoke-SqlNonQuery -Query @"
                UPDATE JobFlow.Status 
                SET completed_dttm = GETDATE(), 
                    last_status = 'FAILED', 
                    last_error_message = '$errorMessage'
                WHERE process_name = 'DetectFlows'
"@ | Out-Null
        }
        
        return @{ FlowsDetected = 0; Error = $_.Exception.Message }
    }
}

function Step-CaptureCompletedJobs {
    <#
    .SYNOPSIS
        Captures job execution details for completed jobs
        Mirrors the logic from sp_StateMonitor Step 2
    #>
    param([bool]$PreviewOnly = $true)
    
    Write-Log "Step: Capture Completed Jobs" "STEP"
    
    $jobsCaptured = 0
    
    # Update status: started
    if (-not $PreviewOnly) {
        Invoke-SqlNonQuery -Query @"
            UPDATE JobFlow.Status 
            SET started_dttm = GETDATE(), 
                last_status = NULL, 
                last_error_message = NULL 
            WHERE process_name = 'CaptureJobs'
"@ | Out-Null
    }
    
    try {
        # Get recent job_log_ids already captured (to exclude)
        # Date-filtered: DM query only looks back 24 hours so 2-day buffer is sufficient
        $existingJobsQuery = @"
            SELECT job_log_id FROM JobFlow.JobExecutionLog
            WHERE execution_date >= DATEADD(DAY, -2, GETDATE())
"@
        $existingJobs = Get-SqlData -Query $existingJobsQuery
        $existingJobLogIds = @()
        if ($existingJobs) {
            $existingJobLogIds = @($existingJobs | ForEach-Object { $_.job_log_id })
        }
        
        # Query source for completed jobs - matching sp_StateMonitor exactly
        $completedJobsQuery = @"
            SELECT 
                jsl.job_sqnc_log_id,
                jl.job_log_id,
                j.job_id,
                j.job_shrt_nm,
                j.job_nm,
                js.job_sqnc_id,
                js.job_sqnc_shrt_nm,
                jse.job_exctn_ordr_nmbr AS execution_order_nmbr,
                CASE WHEN u.usr_usrnm = 'apischeduler' THEN 'SCHEDULED' ELSE 'AD_HOC' END AS execution_type,
                u.usr_usrnm AS executed_by,
                CAST(jl.job_exec_dttm AS DATE) AS execution_date,
                jl.job_exec_dttm,
                COALESCE(MIN(jel.upsrt_dttm), jl.job_exec_dttm) AS job_start_dttm,
                COALESCE(MAX(jel.upsrt_dttm), jl.job_exec_dttm) AS job_end_dttm,
                jl.upsrt_dttm AS job_reported_complete_dttm,
                jl.job_entty_ttl_nmbr AS total_records,
                COUNT(CASE WHEN jel.job_entty_log_id IS NOT NULL AND jel.job_entty_log_err_rsn_txt IS NULL THEN 1 END) AS succeeded_count,
                COUNT(CASE WHEN jel.job_entty_log_id IS NOT NULL AND jel.job_entty_log_err_rsn_txt IS NOT NULL THEN 1 END) AS failed_count,
                CASE 
                    WHEN COALESCE(jl.job_entty_ttl_nmbr, 0) = 0 THEN NULL
                    WHEN DATEDIFF(SECOND, MIN(jel.upsrt_dttm), MAX(jel.upsrt_dttm)) = 0 THEN NULL
                    ELSE CAST(COUNT(jel.job_entty_log_id) AS DECIMAL(10,2)) / 
                         DATEDIFF(SECOND, MIN(jel.upsrt_dttm), MAX(jel.upsrt_dttm))
                END AS records_per_second,
                DATEDIFF(SECOND, MIN(jel.upsrt_dttm), MAX(jel.upsrt_dttm)) AS execution_time_seconds,
                CASE 
                    WHEN jl.job_stts_cd = 1 THEN 'EXECUTING'
                    WHEN jl.job_stts_cd = 6 THEN 'PENDING'
                    WHEN jl.job_stts_cd IN (4, 5) AND COUNT(jel.job_entty_log_id) > 0 THEN 'PARTIAL'
                    WHEN jl.job_stts_cd IN (4, 5) THEN 'CANCELLED'
                    WHEN COALESCE(jl.job_entty_ttl_nmbr, 0) > 0 AND COUNT(jel.job_entty_log_id) = jl.job_entty_ttl_nmbr THEN 'COMPLETED'
                    WHEN jl.job_stts_cd = 3 THEN 'COMPLETED'
                    WHEN COUNT(jel.job_entty_log_id) > 0 AND COUNT(jel.job_entty_log_id) < COALESCE(jl.job_entty_ttl_nmbr, 0) THEN 'PARTIAL'
                    WHEN jl.job_stts_cd = 2 THEN 'FAILED'
                    ELSE 'UNKNOWN'
                END AS job_status,
                jl.job_stts_cd,
                jl.job_exctn_msg_txt AS error_message
            FROM dbo.job_log jl
            INNER JOIN dbo.job j ON j.job_id = jl.job_id
            INNER JOIN dbo.usr u ON u.usr_id = jl.job_exec_usr_id
            LEFT JOIN dbo.job_sqnc_exctn jse ON jse.job_sqnc_exctn_id = jl.job_sqnc_exctn_id
            LEFT JOIN dbo.job_sqnc_exctn_log jsel ON jsel.job_log_id = jl.job_log_id
            LEFT JOIN dbo.job_sqnc_log jsl ON jsl.job_sqnc_log_id = jsel.job_sqnc_log_id
            LEFT JOIN dbo.job_sqnc js ON js.job_sqnc_id = jsl.job_sqnc_id
            LEFT JOIN dbo.job_entty_log jel ON jel.job_log_id = jl.job_log_id
                AND jel.upsrt_dttm >= DATEADD(DAY, -2, GETDATE())
            WHERE jl.job_exec_dttm >= DATEADD(DAY, -1, GETDATE())
              AND jl.job_stts_cd IN (2, 3, 4)
            GROUP BY 
                jsl.job_sqnc_log_id,
                jl.job_log_id,
                j.job_id,
                j.job_shrt_nm,
                j.job_nm,
                js.job_sqnc_id,
                js.job_sqnc_shrt_nm,
                jse.job_exctn_ordr_nmbr,
                u.usr_usrnm,
                jl.job_exec_dttm,
                jl.upsrt_dttm,
                jl.job_entty_ttl_nmbr,
                jl.job_stts_cd,
                jl.job_exctn_msg_txt
"@
        
        $completedJobs = Get-SourceData -Query $completedJobsQuery -Timeout 120
        
        if (-not $completedJobs) {
            Write-Log "  No completed jobs found in source" "DEBUG"
        }
        else {
            foreach ($job in @($completedJobs)) {
                # Skip if already captured
                if ($existingJobLogIds -contains $job.job_log_id) {
                    continue
                }
                
                # Get tracking_id from xFACts
                $trackingId = "NULL"
                if ($job.job_sqnc_log_id) {
                    $trackingQuery = @"
                        SELECT tracking_id FROM JobFlow.FlowExecutionTracking 
                        WHERE job_sqnc_log_id = $($job.job_sqnc_log_id)
"@
                    $trackingResult = Get-SqlData -Query $trackingQuery
                    if ($trackingResult) {
                        $trackingId = $trackingResult.tracking_id
                    }
                }
                
                $jobsCaptured++
                Write-Log "    Capturing: $($job.job_shrt_nm) (job_log_id: $($job.job_log_id), status: $($job.job_status))" "DEBUG"
                
                if (-not $PreviewOnly) {
                    # Build NULL-safe values
                    $jobNmSql = if ($job.job_nm -is [DBNull]) { "NULL" } else { "'$($job.job_nm -replace "'", "''")'" }
                    $jobSqncIdSql = if ($job.job_sqnc_id -is [DBNull]) { "NULL" } else { $job.job_sqnc_id }
                    $jobSqncShrtNmSql = if ($job.job_sqnc_shrt_nm -is [DBNull]) { "NULL" } else { "'$($job.job_sqnc_shrt_nm)'" }
                    $execOrderSql = if ($job.execution_order_nmbr -is [DBNull]) { "NULL" } else { $job.execution_order_nmbr }
                    $totalRecordsSql = if ($job.total_records -is [DBNull]) { "NULL" } else { $job.total_records }
                    $rpsSql = if ($job.records_per_second -is [DBNull]) { "NULL" } else { $job.records_per_second }
                    $execTimeSql = if ($job.execution_time_seconds -is [DBNull]) { "NULL" } else { $job.execution_time_seconds }
                    $errorMsgSql = if ($job.error_message -is [DBNull]) { "NULL" } else { "'$($job.error_message -replace "'", "''")'" }
                    
                    $insertQuery = @"
                        INSERT INTO JobFlow.JobExecutionLog (
                            tracking_id,
                            job_log_id,
                            job_id,
                            job_shrt_nm,
                            job_nm,
                            job_sqnc_id,
                            job_sqnc_shrt_nm,
                            execution_order_nmbr,
                            execution_type,
                            executed_by,
                            execution_date,
                            job_exec_dttm,
                            job_start_dttm,
                            job_end_dttm,
                            job_reported_complete_dttm,
                            total_records,
                            succeeded_count,
                            failed_count,
                            records_per_second,
                            execution_time_seconds,
                            job_status,
                            job_stts_cd,
                            error_message,
                            captured_dttm
                        )
                        VALUES (
                            $trackingId,
                            $($job.job_log_id),
                            $($job.job_id),
                            '$($job.job_shrt_nm)',
                            $jobNmSql,
                            $jobSqncIdSql,
                            $jobSqncShrtNmSql,
                            $execOrderSql,
                            '$($job.execution_type)',
                            '$($job.executed_by)',
                            '$($job.execution_date.ToString("yyyy-MM-dd"))',
                            '$($job.job_exec_dttm.ToString("yyyy-MM-dd HH:mm:ss"))',
                            '$($job.job_start_dttm.ToString("yyyy-MM-dd HH:mm:ss"))',
                            '$($job.job_end_dttm.ToString("yyyy-MM-dd HH:mm:ss"))',
                            '$($job.job_reported_complete_dttm.ToString("yyyy-MM-dd HH:mm:ss"))',
                            $totalRecordsSql,
                            $($job.succeeded_count),
                            $($job.failed_count),
                            $rpsSQL,
                            $execTimeSql,
                            '$($job.job_status)',
                            $($job.job_stts_cd),
                            $errorMsgSql,
                            GETDATE()
                        )
"@
#Write-Log "DEBUG INSERT: $insertQuery" "DEBUG"
                    Invoke-SqlNonQuery -Query $insertQuery | Out-Null
                }
            }
        }
        
        Write-Log "  Jobs captured: $jobsCaptured" "INFO"
        
        # Update status: success
        if (-not $PreviewOnly) {
            Invoke-SqlNonQuery -Query @"
                UPDATE JobFlow.Status 
                SET completed_dttm = GETDATE(), 
                    last_status = 'SUCCESS', 
                    last_result_count = $jobsCaptured 
                WHERE process_name = 'CaptureJobs'
"@ | Out-Null
        }
        
        return @{ JobsCaptured = $jobsCaptured }
    }
    catch {
        $errorMessage = $_.Exception.Message -replace "'", "''"
        Write-Log "  Error in CaptureJobs: $($_.Exception.Message)" "ERROR"
        
        # Update status: failed
        if (-not $PreviewOnly) {
            Invoke-SqlNonQuery -Query @"
                UPDATE JobFlow.Status 
                SET completed_dttm = GETDATE(), 
                    last_status = 'FAILED', 
                    last_error_message = '$errorMessage'
                WHERE process_name = 'CaptureJobs'
"@ | Out-Null
        }
        
        return @{ JobsCaptured = 0; Error = $_.Exception.Message }
    }
}

function Step-UpdateFlowProgress {
    <#
    .SYNOPSIS
        Updates job counts and progress metrics for active flows
        Mirrors the logic from sp_StateMonitor Step 3
    #>
    param([bool]$PreviewOnly = $true)
    
    Write-Log "Step: Update Flow Progress" "STEP"
    
    $flowsUpdated = 0
    
    # Update status: started
    if (-not $PreviewOnly) {
        Invoke-SqlNonQuery -Query @"
            UPDATE JobFlow.Status 
            SET started_dttm = GETDATE(), 
                last_status = NULL, 
                last_error_message = NULL 
            WHERE process_name = 'UpdateProgress'
"@ | Out-Null
    }
    
    try {
        # Get active flows from xFACts
        $activeFlowsQuery = @"
            SELECT tracking_id, job_sqnc_log_id, job_sqnc_shrt_nm
            FROM JobFlow.FlowExecutionTracking
            WHERE execution_state IN ('DETECTED', 'EXECUTING')
"@
        
        $activeFlows = Get-SqlData -Query $activeFlowsQuery
        
        if (-not $activeFlows) {
            Write-Log "  No active flows to update" "INFO"
        }
        else {
            foreach ($flow in @($activeFlows)) {
                # Get current job counts from source using sp_StateMonitor logic
                $countsQuery = @"
                    SELECT 
                        SUM(CASE WHEN jl.job_stts_cd = 3 OR 
                            (jl.job_stts_cd = 2 AND jl.job_entty_ttl_nmbr = agg.processed_count) 
                            THEN 1 ELSE 0 END) AS completed_count,
                        SUM(CASE WHEN jl.job_stts_cd = 1 THEN 1 ELSE 0 END) AS executing_count,
                        SUM(CASE WHEN jl.job_stts_cd = 6 THEN 1 ELSE 0 END) AS pending_count,
                        SUM(CASE WHEN jl.job_stts_cd = 2 AND 
                            (jl.job_entty_ttl_nmbr IS NULL OR jl.job_entty_ttl_nmbr != agg.processed_count) 
                            THEN 1 ELSE 0 END) AS failed_count,
                        SUM(CASE WHEN jl.job_stts_cd = 4 THEN 1 ELSE 0 END) AS cancelled_count,
                        SUM(COALESCE(agg.processed_count, 0)) AS agg_records
                    FROM dbo.job_sqnc_exctn_log jsel
                    INNER JOIN dbo.job_log jl ON jl.job_log_id = jsel.job_log_id
                    OUTER APPLY (
                        SELECT COUNT(*) AS processed_count
                        FROM dbo.job_entty_log jel
                        WHERE jel.job_log_id = jl.job_log_id
                          AND jel.upsrt_dttm >= DATEADD(DAY, -2, GETDATE())
                    ) agg
                    WHERE jsel.job_sqnc_log_id = $($flow.job_sqnc_log_id)
"@
                
                $counts = Get-SourceData -Query $countsQuery
                
                if ($counts) {
                    $completed = if ($counts.completed_count) { $counts.completed_count } else { 0 }
                    $executing = if ($counts.executing_count) { $counts.executing_count } else { 0 }
                    $pending = if ($counts.pending_count) { $counts.pending_count } else { 0 }
                    $failed = if ($counts.failed_count) { $counts.failed_count } else { 0 }
                    $cancelled = if ($counts.cancelled_count) { $counts.cancelled_count } else { 0 }
                    $aggRecords = if ($counts.agg_records) { $counts.agg_records } else { 0 }
                    
                    $flowsUpdated++
                    
                    if ($PreviewOnly) {
                        Write-Log "    PREVIEW: $($flow.job_sqnc_shrt_nm) - Exec:$executing Pend:$pending Comp:$completed Fail:$failed Canc:$cancelled" "WARN"
                    }
                    else {
                        $updateQuery = @"
                            UPDATE JobFlow.FlowExecutionTracking
                            SET completed_job_count = $completed,
                                executing_job_count = $executing,
                                pending_job_count = $pending,
                                failed_job_count = $failed,
                                cancelled_job_count = $cancelled,
                                aggregate_completed_records = $aggRecords,
                                last_activity_dttm = GETDATE(),
                                modified_dttm = GETDATE()
                            WHERE tracking_id = $($flow.tracking_id)
"@
                        Invoke-SqlNonQuery -Query $updateQuery | Out-Null
                        Write-Log "    Updated: $($flow.job_sqnc_shrt_nm) - Exec:$executing Pend:$pending Comp:$completed Fail:$failed Canc:$cancelled" "INFO"
                    }
                }
                else {
                    Write-Log "    Warning: No counts returned for $($flow.job_sqnc_shrt_nm)" "WARN"
                }
            }
        }
        
        Write-Log "  Flows updated: $flowsUpdated" "INFO"
        
        # Update status: success
        if (-not $PreviewOnly) {
            Invoke-SqlNonQuery -Query @"
                UPDATE JobFlow.Status 
                SET completed_dttm = GETDATE(), 
                    last_status = 'SUCCESS', 
                    last_result_count = $flowsUpdated 
                WHERE process_name = 'UpdateProgress'
"@ | Out-Null
        }
        
        return @{ FlowsUpdated = $flowsUpdated }
    }
    catch {
        $errorMessage = $_.Exception.Message -replace "'", "''"
        Write-Log "  Error in UpdateProgress: $($_.Exception.Message)" "ERROR"
        
        # Update status: failed
        if (-not $PreviewOnly) {
            Invoke-SqlNonQuery -Query @"
                UPDATE JobFlow.Status 
                SET completed_dttm = GETDATE(), 
                    last_status = 'FAILED', 
                    last_error_message = '$errorMessage'
                WHERE process_name = 'UpdateProgress'
"@ | Out-Null
        }
        
        return @{ FlowsUpdated = 0; Error = $_.Exception.Message }
    }
}

function Step-TransitionFlowStates {
    <#
    .SYNOPSIS
        Handles state transitions: DETECTED -> EXECUTING -> COMPLETE
        Mirrors the logic from sp_StateMonitor Step 5
    #>
    param([bool]$PreviewOnly = $true)
    
    Write-Log "Step: Transition Flow States" "STEP"
    
    $detectedToExecuting = 0
    $executingToComplete = 0
    
    # Update status: started
    if (-not $PreviewOnly) {
        Invoke-SqlNonQuery -Query @"
            UPDATE JobFlow.Status 
            SET started_dttm = GETDATE(), 
                last_status = NULL, 
                last_error_message = NULL 
            WHERE process_name = 'TransitionStates'
"@ | Out-Null
    }
    
    try {
        # DETECTED -> EXECUTING: Jobs have started
        $toExecutingQuery = @"
            SELECT tracking_id, job_sqnc_shrt_nm, executing_job_count, completed_job_count
            FROM JobFlow.FlowExecutionTracking
            WHERE execution_state = 'DETECTED'
              AND (executing_job_count > 0 OR completed_job_count > 0)
"@
        
        $toExecuting = Get-SqlData -Query $toExecutingQuery
        
        if ($toExecuting) {
            foreach ($flow in @($toExecuting)) {
                $detectedToExecuting++
                Write-Log "  DETECTED -> EXECUTING: $($flow.job_sqnc_shrt_nm) (Exec:$($flow.executing_job_count) Comp:$($flow.completed_job_count))" "INFO"
                
                if (-not $PreviewOnly) {
                    $updateQuery = @"
                        UPDATE JobFlow.FlowExecutionTracking
                        SET execution_state = 'EXECUTING',
                            execution_window_start = COALESCE(execution_window_start, GETDATE()),
                            last_activity_dttm = GETDATE(),
                            modified_dttm = GETDATE()
                        WHERE tracking_id = $($flow.tracking_id)
"@
                    Invoke-SqlNonQuery -Query $updateQuery | Out-Null
                }
            }
        }
        
        # EXECUTING -> COMPLETE: All jobs finished
        $toCompleteQuery = @"
            SELECT tracking_id, job_sqnc_shrt_nm, completed_job_count, failed_job_count, cancelled_job_count
            FROM JobFlow.FlowExecutionTracking
            WHERE execution_state = 'EXECUTING'
              AND executing_job_count = 0
              AND pending_job_count = 0
              AND (completed_job_count + failed_job_count + cancelled_job_count) > 0
"@
        
        $toComplete = Get-SqlData -Query $toCompleteQuery
        
        if ($toComplete) {
            foreach ($flow in @($toComplete)) {
                $executingToComplete++
                Write-Log "  EXECUTING -> COMPLETE: $($flow.job_sqnc_shrt_nm) (Comp:$($flow.completed_job_count) Fail:$($flow.failed_job_count) Canc:$($flow.cancelled_job_count))" "INFO"
                
                if (-not $PreviewOnly) {
                    $updateQuery = @"
                        UPDATE JobFlow.FlowExecutionTracking
                        SET execution_state = 'COMPLETE',
                            execution_window_end = GETDATE(),
                            completion_dttm = GETDATE(),
                            last_activity_dttm = GETDATE(),
                            modified_dttm = GETDATE()
                        WHERE tracking_id = $($flow.tracking_id)
"@
                    Invoke-SqlNonQuery -Query $updateQuery | Out-Null
                }
            }
        }
        
        $totalTransitions = $detectedToExecuting + $executingToComplete
        Write-Log "  Transitions: $detectedToExecuting DETECTED->EXECUTING, $executingToComplete EXECUTING->COMPLETE" "INFO"
        
        # Update status: success
        if (-not $PreviewOnly) {
            Invoke-SqlNonQuery -Query @"
                UPDATE JobFlow.Status 
                SET completed_dttm = GETDATE(), 
                    last_status = 'SUCCESS', 
                    last_result_count = $totalTransitions 
                WHERE process_name = 'TransitionStates'
"@ | Out-Null
        }
        
        return @{ 
            DetectedToExecuting = $detectedToExecuting
            ExecutingToComplete = $executingToComplete 
        }
    }
    catch {
        $errorMessage = $_.Exception.Message -replace "'", "''"
        Write-Log "  Error in TransitionStates: $($_.Exception.Message)" "ERROR"
        
        # Update status: failed
        if (-not $PreviewOnly) {
            Invoke-SqlNonQuery -Query @"
                UPDATE JobFlow.Status 
                SET completed_dttm = GETDATE(), 
                    last_status = 'FAILED', 
                    last_error_message = '$errorMessage'
                WHERE process_name = 'TransitionStates'
"@ | Out-Null
        }
        
        return @{ DetectedToExecuting = 0; ExecutingToComplete = 0; Error = $_.Exception.Message }
    }
}

function Step-DetectStalls {
    <#
    .SYNOPSIS
        Detects system-wide stalls by comparing job snapshots between polls
        Simplified from sp_StateMonitor - no intra-poll delay, just cross-poll comparison
    #>
    param([bool]$PreviewOnly = $true)
    
    Write-Log "Step: Detect Stalls" "STEP"
    
    $stallThreshold = $Script:Config.StallThreshold
    $currentDate = Get-Date -Format "yyyy-MM-dd"
    $currentDttm = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    
    # Update status: started
    if (-not $PreviewOnly) {
        Invoke-SqlNonQuery -Query @"
            UPDATE JobFlow.Status 
            SET started_dttm = GETDATE(), 
                last_status = NULL, 
                last_error_message = NULL 
            WHERE process_name = 'DetectStalls'
"@ | Out-Null
    }
    
    try {
        # Get current stall counter from Status table (needed before IDLE checks for RESET logging)
        $statusQuery = @"
            SELECT 
                stall_no_progress_count,
                stall_last_progress_dttm,
                stall_snapshot_xml
            FROM JobFlow.Status
            WHERE process_name = 'DetectStalls'
"@
        
        $status = Get-SqlData -Query $statusQuery
        
        $counterBefore = if ($status -and $status.stall_no_progress_count) { $status.stall_no_progress_count } else { 0 }
        $previousSnapshotXml = if ($status) { $status.stall_snapshot_xml } else { $null }
        
        Write-Log "  Previous counter: $counterBefore / $stallThreshold" "DEBUG"
        
        # Get executing flows from xFACts
        $executingFlowsQuery = @"
            SELECT job_sqnc_log_id
            FROM JobFlow.FlowExecutionTracking
            WHERE execution_state = 'EXECUTING'
"@
        
        $executingFlows = Get-SqlData -Query $executingFlowsQuery
        
        if (-not $executingFlows) {
            # No executing flows - system is IDLE
            Write-Log "  No executing flows - system IDLE" "INFO"
            
            if (-not $PreviewOnly) {
                # If counter was elevated, log RESET so StallDetectionLog reflects resolution
                if ($counterBefore -gt 0) {
                    $taskIdValue = if ($TaskId -gt 0) { "$TaskId" } else { "NULL" }
                    $resetLogQuery = @"
                        INSERT INTO JobFlow.StallDetectionLog (
                            task_id, poll_dttm, counter_before, counter_after,
                            stall_threshold, threshold_reached, event_type,
                            snapshot_comparison_xml
                        )
                        VALUES (
                            $taskIdValue, GETDATE(), $counterBefore, 0,
                            $stallThreshold, 0, 'RESET',
                            '<Snapshot poll_dttm="$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")"><Idle reason="no_executing_flows"/></Snapshot>'
                        )
"@
                    Invoke-SqlNonQuery -Query $resetLogQuery | Out-Null
                    Write-Log "  RESET event logged (IDLE - no executing flows, counter was $counterBefore)" "SUCCESS"
                }
                
                $updateQuery = @"
                    UPDATE JobFlow.Status
                    SET stall_no_progress_count = 0,
                        stall_snapshot_xml = NULL,
                        last_status = 'SUCCESS',
                        last_result_count = 0,
                        completed_dttm = GETDATE()
                    WHERE process_name = 'DetectStalls'
"@
                Invoke-SqlNonQuery -Query $updateQuery | Out-Null
            }
            
            return @{ StallState = 'IDLE'; Counter = 0 }
        }
        
        # Build comma-separated list of job_sqnc_log_ids for source query
        $logIds = @($executingFlows | ForEach-Object { $_.job_sqnc_log_id }) -join ','
        
        # Query source for active jobs (executing or pending) in those flows
        $sourceQuery = @"
            SELECT 
                jl.job_log_id,
                jl.job_stts_cd,
                COALESCE(agg.processed_count, 0) AS processed_count
            FROM dbo.job_sqnc_exctn_log jsel
            INNER JOIN dbo.job_log jl ON jl.job_log_id = jsel.job_log_id
            OUTER APPLY (
                SELECT COUNT(*) AS processed_count
                FROM dbo.job_entty_log jel
                WHERE jel.job_log_id = jl.job_log_id
                  AND jel.upsrt_dttm >= DATEADD(DAY, -2, GETDATE())
            ) agg
            WHERE jsel.job_sqnc_log_id IN ($logIds)
              AND jl.job_stts_cd IN (1, 6)
            ORDER BY jl.job_log_id
"@
        
        $activeJobs = Get-SourceData -Query $sourceQuery
        
        if (-not $activeJobs) {
            # No executing/pending jobs - system is IDLE
            Write-Log "  No executing or pending jobs - system IDLE" "INFO"
            
            if (-not $PreviewOnly) {
                # If counter was elevated, log RESET so StallDetectionLog reflects resolution
                if ($counterBefore -gt 0) {
                    $taskIdValue = if ($TaskId -gt 0) { "$TaskId" } else { "NULL" }
                    $resetLogQuery = @"
                        INSERT INTO JobFlow.StallDetectionLog (
                            task_id, poll_dttm, counter_before, counter_after,
                            stall_threshold, threshold_reached, event_type,
                            snapshot_comparison_xml
                        )
                        VALUES (
                            $taskIdValue, GETDATE(), $counterBefore, 0,
                            $stallThreshold, 0, 'RESET',
                            '<Snapshot poll_dttm="$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")"><Idle reason="no_active_jobs"/></Snapshot>'
                        )
"@
                    Invoke-SqlNonQuery -Query $resetLogQuery | Out-Null
                    Write-Log "  RESET event logged (IDLE - no active jobs, counter was $counterBefore)" "SUCCESS"
                }
                
                $updateQuery = @"
                    UPDATE JobFlow.Status
                    SET stall_no_progress_count = 0,
                        stall_snapshot_xml = NULL,
                        last_status = 'SUCCESS',
                        last_result_count = 0,
                        completed_dttm = GETDATE()
                    WHERE process_name = 'DetectStalls'
"@
                Invoke-SqlNonQuery -Query $updateQuery | Out-Null
            }
            
            return @{ StallState = 'IDLE'; Counter = 0 }
        }
        
        # Build current snapshot XML
        $snapshotJobs = @($activeJobs | ForEach-Object {
            "<Job id=`"$($_.job_log_id)`" status=`"$($_.job_stts_cd)`" count=`"$($_.processed_count)`"/>"
        })
        $currentSnapshotXml = "<Snapshot poll_dttm=`"$currentDttm`">$($snapshotJobs -join '')</Snapshot>"
        
        Write-Log "  Current snapshot: $(@($activeJobs).Count) jobs" "DEBUG"
        
        # Compare snapshots
        $progressDetected = $false
        
        if (-not $previousSnapshotXml) {
            # First run or after IDLE - no comparison possible, assume progress
            $progressDetected = $true
            Write-Log "  No previous snapshot - assuming progress" "DEBUG"
        }
        else {
            # Build current job signature for comparison
            $currentSignature = (@($activeJobs) | ForEach-Object { 
                "$($_.job_log_id):$($_.job_stts_cd):$($_.processed_count)" 
            }) -join '|'
            
            # Parse previous XML to build signature
            $previousQuery = @"
                DECLARE @xml XML = '$($previousSnapshotXml -replace "'", "''")'
                SELECT 
                    j.value('@id', 'INT') AS job_log_id,
                    j.value('@status', 'INT') AS job_stts_cd,
                    j.value('@count', 'INT') AS processed_count
                FROM @xml.nodes('/Snapshot/Job') AS t(j)
                ORDER BY j.value('@id', 'INT')
"@
            
            $previousJobs = Get-SqlData -Query $previousQuery
            
            if ($previousJobs) {
                $previousSignature = (@($previousJobs) | ForEach-Object { 
                    "$($_.job_log_id):$($_.job_stts_cd):$($_.processed_count)" 
                }) -join '|'
                
                if ($currentSignature -ne $previousSignature) {
                    $progressDetected = $true
                    Write-Log "  Snapshot changed - progress detected" "DEBUG"
                }
                else {
                    Write-Log "  Snapshot unchanged - NO progress" "WARN"
                }
            }
            else {
                # Couldn't parse previous - assume progress
                $progressDetected = $true
                Write-Log "  Could not parse previous snapshot - assuming progress" "DEBUG"
            }
        }
        
        # Determine action based on progress
        $counterAfter = 0
        $eventType = $null
        $stallState = 'HEALTHY'
        $queueAlerts = $false
        
        if ($progressDetected) {
            $counterAfter = 0
            $stallState = 'HEALTHY'
            
            if ($counterBefore -gt 0) {
                $eventType = 'RESET'
                Write-Log "  PROGRESS DETECTED - Counter reset ($counterBefore -> 0)" "SUCCESS"
            }
            else {
                Write-Log "  Progress detected - system HEALTHY" "SUCCESS"
            }
        }
        else {
            # No progress
            $counterAfter = $counterBefore + 1
            
            if ($counterAfter -lt $stallThreshold) {
                $eventType = 'INCREMENT'
                $stallState = 'HEALTHY'
                Write-Log "  No progress - counter incremented ($counterBefore -> $counterAfter)" "WARN"
            }
            elseif ($counterAfter -eq $stallThreshold) {
                $eventType = 'ALERT'
                $stallState = 'STALLED'
                $queueAlerts = $true
                Write-Log "  *** STALL THRESHOLD REACHED ($counterAfter) ***" "ERROR"
            }
            else {
                $eventType = 'STALLED'
                $stallState = 'STALLED'
                Write-Log "  Stall continuing ($counterAfter polls)" "ERROR"
            }
        }
        
        if (-not $PreviewOnly) {
            # Update Status table
            $lastProgressUpdate = if ($progressDetected) { "stall_last_progress_dttm = GETDATE()," } else { "" }
            
            $updateStatusQuery = @"
                UPDATE JobFlow.Status
                SET stall_no_progress_count = $counterAfter,
                    $lastProgressUpdate
                    stall_snapshot_xml = '$($currentSnapshotXml -replace "'", "''")',
                    last_status = 'SUCCESS',
                    last_result_count = $counterAfter,
                    completed_dttm = GETDATE()
                WHERE process_name = 'DetectStalls'
"@
            Invoke-SqlNonQuery -Query $updateStatusQuery | Out-Null
            
            # Queue alerts if threshold just reached
            if ($queueAlerts) {
                # Check for active stall (ALERT today without subsequent RESET)
                $activeStallQuery = @"
                    SELECT 1 FROM JobFlow.StallDetectionLog sdl
                    WHERE CAST(sdl.poll_dttm AS DATE) = '$currentDate'
                      AND sdl.event_type = 'ALERT'
                      AND NOT EXISTS (
                          SELECT 1 FROM JobFlow.StallDetectionLog r
                          WHERE r.poll_dttm > sdl.poll_dttm
                            AND r.event_type = 'RESET'
                            AND CAST(r.poll_dttm AS DATE) = '$currentDate'
                      )
"@
                $activeStall = Get-SqlData -Query $activeStallQuery
                
                if (-not $activeStall) {
                    $lastProgressStr = if ($status -and $status.stall_last_progress_dttm) { 
                        $status.stall_last_progress_dttm.ToString('yyyy-MM-dd HH:mm:ss') 
                    } else { 'Unknown' }
                    
                    $durationStr = "$($stallThreshold * 5) minutes ($stallThreshold poll cycles)"
                    
                    # Check and queue Jira ticket
                    $jiraExistsQuery = @"
                        SELECT 1 FROM Jira.RequestLog
                        WHERE Trigger_Type = 'JobFlow_Stall'
                          AND Trigger_Value = '$currentDate'
                          AND StatusCode = 201
                          AND TicketKey IS NOT NULL
                          AND TicketKey != 'Email'
"@
                    $jiraExists = Get-SqlData -Query $jiraExistsQuery
                    
                    if (-not $jiraExists) {
                        $ticketSummary = "JobFlow System Stall Detected - $currentDttm"
                        $ticketDescription = @"
The JobFlow monitoring system has detected a system-wide stall.

STALL DETAILS:
Detection Time: $currentDttm
No Progress Duration: $durationStr
Last Progress: $lastProgressStr

IMPACT:
No jobs are progressing across any active flows. The JBoss JMS queue may be stalled or the Debt Manager application server may be experiencing issues.

ACTION REQUIRED:
1. Check JBoss application server status
2. Check JMS queue for stuck messages
3. Review Debt Manager logs for errors
4. Restart services if necessary

REFERENCE:
Database: xFACts
Table: JobFlow.Status
"@
                        $jiraQuery = @"
                            EXEC Jira.sp_QueueTicket
                                @SourceModule = 'JobFlow',
                                @ProjectKey = 'SD',
                                @Summary = '$($ticketSummary -replace "'", "''")',
                                @Description = '$($ticketDescription -replace "'", "''")',
                                @IssueType = 'Issue',
                                @Priority = 'Highest',
                                @EmailRecipients = 'applications@frost-arnett.com;biteam@frost-arnett.com',
                                @CascadingField_ID = 'customfield_18401',
                                @CascadingField_ParentValue = 'Debt Manager',
                                @CascadingField_ChildValue = 'DM Configuration Issues',
                                @CustomField_ID = 'customfield_10305',
                                @CustomField_Value = 'FAC INFORMATION TECHNOLOGY',
                                @CustomField2_ID = 'customfield_10009',
                                @CustomField2_Value = 'sd/1b77b626-3ad4-4bee-8727-abc18b68c5fa',
                                @DueDate = '$executionDate',
                                @TriggerType = 'JobFlow_Stall',
                                @TriggerValue = '$triggerValue'
"@
                        Invoke-SqlNonQuery -Query $jiraQuery | Out-Null
                        Write-Log "  Jira ticket queued" "SUCCESS"
                    }
                    else {
                        Write-Log "  Jira ticket already exists for today - suppressed" "INFO"
                    }
                    
                    # Queue Teams alert (dedup handled internally by Send-TeamsAlert)
                    $teamsMessage = @"
System stall detected at $currentDttm.
No job progress for $durationStr.
Last progress: $lastProgressStr.

Check JBoss application server and JMS queue. Jira ticket created.
"@
                    Send-TeamsAlert -SourceModule 'JobFlow' -AlertCategory 'CRITICAL' `
                        -Title '{{FIRE}} JobFlow System Stall Detected' `
                        -Message $teamsMessage -Color 'attention' `
                        -TriggerType 'JobFlow_Stall' -TriggerValue $currentDate | Out-Null
                }
                else {
                    Write-Log "  Active stall exists (no RESET since last ALERT) - suppressing duplicates" "INFO"
                }
            }
            
            # Log to StallDetectionLog if event occurred
            # NOTE: This must happen AFTER the Send-TeamsAlert call above.
            # If it ran before, the ALERT row we are about to insert would
            # be found by the "is there an active ALERT since last RESET?"
            # check on the next monitor cycle and suppress the alert from
            # firing again until reset.
            if ($eventType) {
                $thresholdReached = if ($counterAfter -ge $stallThreshold) { 1 } else { 0 }
                
                $taskIdValue = if ($TaskId -gt 0) { "$TaskId" } else { "NULL" }
                $logQuery = @"
                    INSERT INTO JobFlow.StallDetectionLog (
                        task_id, poll_dttm, counter_before, counter_after,
                        stall_threshold, threshold_reached, event_type,
                        snapshot_comparison_xml
                    )
                    VALUES (
                        $taskIdValue, GETDATE(), $counterBefore, $counterAfter,
                        $stallThreshold, $thresholdReached, '$eventType',
                        '$($currentSnapshotXml -replace "'", "''")'
                    )
"@
                Invoke-SqlNonQuery -Query $logQuery | Out-Null
            }
        }
        else {
            Write-Log "  PREVIEW: Would update Status and log event '$eventType'" "WARN"
            if ($queueAlerts) { 
                Write-Log "  PREVIEW: Would queue Jira ticket and Teams alert" "WARN" 
            }
        }
        
        return @{ 
            StallState = $stallState
            Counter = $counterAfter
            EventType = $eventType
        }
    }
    catch {
        $errorMessage = $_.Exception.Message -replace "'", "''"
        Write-Log "  Error in DetectStalls: $($_.Exception.Message)" "ERROR"
        
        # Update status: failed
        if (-not $PreviewOnly) {
            Invoke-SqlNonQuery -Query @"
                UPDATE JobFlow.Status 
                SET completed_dttm = GETDATE(), 
                    last_status = 'FAILED', 
                    last_error_message = '$errorMessage'
                WHERE process_name = 'DetectStalls'
"@ | Out-Null
        }
        
        return @{ StallState = 'ERROR'; Counter = 0; Error = $_.Exception.Message }
    }
}

function Step-ValidateCompletedFlows {
    <#
    .SYNOPSIS
        Validates completed flows - checks that all expected jobs ran and identifies failures
        Integrates with ErrorCategory and JobConfig for alerting decisions
    #>
    param([bool]$PreviewOnly = $true)
    
    Write-Log "Step: Validate Completed Flows" "STEP"
    
    $currentDate = Get-Date -Format "yyyy-MM-dd"
    $flowsValidated = 0
    $issuesFound = 0
    
    # Update status: started
    if (-not $PreviewOnly) {
        Invoke-SqlNonQuery -Query @"
            UPDATE JobFlow.Status 
            SET started_dttm = GETDATE(), 
                last_status = NULL, 
                last_error_message = NULL 
            WHERE process_name = 'ValidateFlows'
"@ | Out-Null
    }
    
    try {
        # Get flows in COMPLETE state that need validation (exclude tracking_id 0 - all flows pre-dating xFACts)
        $completedFlowsQuery = @"
            SELECT 
                tracking_id,
                job_sqnc_log_id,
                job_sqnc_id,
                job_sqnc_shrt_nm,
                execution_date,
                expected_job_count,
                expected_jobs_json
            FROM JobFlow.FlowExecutionTracking
            WHERE execution_state = 'COMPLETE'
              AND tracking_id > 0
"@
        
        $completedFlows = Get-SqlData -Query $completedFlowsQuery
        
        if (-not $completedFlows) {
            Write-Log "  No completed flows to validate" "INFO"
            
            # Update status: success
            if (-not $PreviewOnly) {
                Invoke-SqlNonQuery -Query @"
                    UPDATE JobFlow.Status 
                    SET completed_dttm = GETDATE(), 
                        last_status = 'SUCCESS', 
                        last_result_count = 0 
                    WHERE process_name = 'ValidateFlows'
"@ | Out-Null
            }
            
            return @{ FlowsValidated = 0; IssuesFound = 0 }
        }
        
        foreach ($flow in @($completedFlows)) {
            $flowsValidated++
            $trackingId = $flow.tracking_id
            $jobSqncLogId = $flow.job_sqnc_log_id
            $jobSqncShrtNm = $flow.job_sqnc_shrt_nm
            $executionDate = $flow.execution_date.ToString('yyyy-MM-dd')
            
            Write-Log "  Validating: $jobSqncShrtNm (tracking_id: $trackingId)" "INFO"
            
            # Build trigger value for deduplication
            $triggerValue = "${jobSqncShrtNm}_${executionDate}"
            
            # Get job analysis from JobExecutionLog joined with JobConfig
            $jobAnalysisQuery = @"
                SELECT 
                    jed.execution_detail_id,
                    jed.job_log_id,
                    jed.job_id,
                    jed.job_shrt_nm,
                    jed.job_stts_cd,
                    jed.job_status,
                    jed.total_records,
                    jed.succeeded_count,
                    jed.failed_count,
                    jed.error_message,
                    ISNULL(jc.is_critical, 0) AS is_critical,
                    jc.criticality_reason,
                    CASE 
                        WHEN jed.job_status = 'FAILED' THEN 'SYSTEM_FAILURE'
                        WHEN jed.job_stts_cd = 6 THEN 'NEVER_EXECUTED'
                        WHEN jed.job_stts_cd = 1 THEN 'STUCK_EXECUTING'
                        WHEN jed.job_stts_cd = 5 THEN 'STUCK_CANCELLING'
                        WHEN jed.job_stts_cd = 4 THEN 'CANCELED'
                        WHEN jed.job_stts_cd = 7 THEN 'PARTIAL'
                        WHEN ISNULL(jed.total_records, 0) > 0 
                             AND jed.succeeded_count = 0 
                             AND jed.failed_count > 0 THEN 'TOTAL_FAILURE'
                        ELSE 'OK'
                    END AS validation_result
                FROM JobFlow.JobExecutionLog jed
                LEFT JOIN JobFlow.JobConfig jc ON jed.job_id = jc.job_id
                WHERE jed.tracking_id = $trackingId
"@
            
            $jobAnalysis = Get-SqlData -Query $jobAnalysisQuery
            
            if (-not $jobAnalysis) {
                Write-Log "    No job details found for tracking_id $trackingId" "WARN"
                continue
            }
            
            # Initialize counters
            $expectedJobCount = $flow.expected_job_count
            $actualJobCount = 0
            $pendingJobCount = 0
            $stuckJobCount = 0
            $canceledJobCount = 0
            $totalFailureCount = 0
            $systemFailureCount = 0
            $businessRejectionCount = 0
            $partialCount = 0
            $successCount = 0
            
            # Process each job and apply ErrorCategory logic for TOTAL_FAILURE jobs
            $problemJobs = @()
            
            foreach ($job in @($jobAnalysis)) {
                $actualJobCount++
                $validationResult = $job.validation_result
                
                # For TOTAL_FAILURE jobs, check ErrorCategory to determine if alertable
                if ($validationResult -eq 'TOTAL_FAILURE') {
                    # Get dominant error type from source
                    $errorTypeQuery = @"
                        SELECT TOP 1
                            CASE 
                                WHEN jel.job_entty_log_err_rsn_txt LIKE 'Data is stale%' THEN 'StaleData'
                                WHEN jel.job_entty_log_err_rsn_txt LIKE 'User with Id:%' THEN 'UserInitiated'
                                WHEN jel.job_entty_log_err_rsn_txt LIKE 'Data access or update failed%' THEN 'DataAccessError'
                                WHEN jel.job_entty_log_err_rsn_txt LIKE 'Failed to execute action:%'
                                    THEN LEFT(LTRIM(RTRIM(SUBSTRING(
                                        jel.job_entty_log_err_rsn_txt,
                                        CHARINDEX('action:', jel.job_entty_log_err_rsn_txt) + 8,
                                        CASE 
                                            WHEN CHARINDEX('(', jel.job_entty_log_err_rsn_txt) > CHARINDEX('action:', jel.job_entty_log_err_rsn_txt)
                                            THEN CHARINDEX('(', jel.job_entty_log_err_rsn_txt) - CHARINDEX('action:', jel.job_entty_log_err_rsn_txt) - 9
                                            ELSE 100
                                        END
                                    ))), 100)
                                ELSE 'OTHER'
                            END AS error_type,
                            COUNT(*) AS error_count
                        FROM dbo.job_entty_log jel
                        WHERE jel.job_log_id = $($job.job_log_id)
                          AND jel.job_entty_log_stts_cd = 2
                        GROUP BY 
                            CASE 
                                WHEN jel.job_entty_log_err_rsn_txt LIKE 'Data is stale%' THEN 'StaleData'
                                WHEN jel.job_entty_log_err_rsn_txt LIKE 'User with Id:%' THEN 'UserInitiated'
                                WHEN jel.job_entty_log_err_rsn_txt LIKE 'Data access or update failed%' THEN 'DataAccessError'
                                WHEN jel.job_entty_log_err_rsn_txt LIKE 'Failed to execute action:%'
                                    THEN LEFT(LTRIM(RTRIM(SUBSTRING(
                                        jel.job_entty_log_err_rsn_txt,
                                        CHARINDEX('action:', jel.job_entty_log_err_rsn_txt) + 8,
                                        CASE 
                                            WHEN CHARINDEX('(', jel.job_entty_log_err_rsn_txt) > CHARINDEX('action:', jel.job_entty_log_err_rsn_txt)
                                            THEN CHARINDEX('(', jel.job_entty_log_err_rsn_txt) - CHARINDEX('action:', jel.job_entty_log_err_rsn_txt) - 9
                                            ELSE 100
                                        END
                                    ))), 100)
                                ELSE 'OTHER'
                            END
                        ORDER BY COUNT(*) DESC
"@
                    $errorTypeResult = Get-SourceData -Query $errorTypeQuery
                    $errorType = if ($errorTypeResult) { $errorTypeResult.error_type } else { 'UNKNOWN' }
                    
                    # Look up ErrorCategory
                    $errorCategoryQuery = @"
                        SELECT classification, alert_on_total_failure, min_failure_threshold, description
                        FROM JobFlow.ErrorCategory
                        WHERE error_type = '$errorType'
"@
                    $errorCategory = Get-SqlData -Query $errorCategoryQuery
                    
                    $alertOnFailure = $true  # Default to alert
                    $errorClassification = 'UNCLASSIFIED'
                    $errorDescription = $null
                    
                    if ($errorCategory) {
                        $errorClassification = $errorCategory.classification
                        $errorDescription = $errorCategory.description
                        $minThreshold = if ($errorCategory.min_failure_threshold) { $errorCategory.min_failure_threshold } else { 10 }
                        
                        # Alert only if: job is critical AND error type is alertable AND meets threshold
                        if ($job.is_critical -eq 1 -and 
                            $errorCategory.alert_on_total_failure -eq 1 -and 
                            $job.failed_count -ge $minThreshold) {
                            $alertOnFailure = $true
                        }
                        else {
                            $alertOnFailure = $false
                        }
                    }
                    
                    if ($alertOnFailure) {
                        $totalFailureCount++
                        $problemJobs += @{
                            job_shrt_nm = $job.job_shrt_nm
                            validation_result = 'TOTAL_FAILURE'
                            is_critical = $job.is_critical
                            failed_count = $job.failed_count
                            error_type = $errorType
                            error_description = $errorDescription
                            criticality_reason = $job.criticality_reason
                        }
                    }
                    else {
                        # Reclassify as BUSINESS_REJECTION
                        $validationResult = 'BUSINESS_REJECTION'
                        $businessRejectionCount++
                    }
                }
                elseif ($validationResult -eq 'SYSTEM_FAILURE') {
                    $systemFailureCount++
                    $problemJobs += @{
                        job_shrt_nm = $job.job_shrt_nm
                        validation_result = 'SYSTEM_FAILURE'
                        is_critical = $job.is_critical
                        error_message = $job.error_message
                    }
                }
                elseif ($validationResult -eq 'NEVER_EXECUTED') {
                    $pendingJobCount++
                    $problemJobs += @{
                        job_shrt_nm = $job.job_shrt_nm
                        validation_result = 'NEVER_EXECUTED'
                        is_critical = $job.is_critical
                    }
                }
                elseif ($validationResult -in @('STUCK_EXECUTING', 'STUCK_CANCELLING')) {
                    $stuckJobCount++
                    $problemJobs += @{
                        job_shrt_nm = $job.job_shrt_nm
                        validation_result = $validationResult
                        is_critical = $job.is_critical
                    }
                }
                elseif ($validationResult -eq 'CANCELED') {
                    $canceledJobCount++
                }
                elseif ($validationResult -eq 'PARTIAL') {
                    $partialCount++
                    $problemJobs += @{
                        job_shrt_nm = $job.job_shrt_nm
                        validation_result = 'PARTIAL'
                        is_critical = $job.is_critical
                    }
                }
                else {
                    $successCount++
                }
            }
            
            # Determine overall validation status
            $validationStatus = 'SUCCESS'
            $hasIssues = $false
            
            if ($pendingJobCount -gt 0 -or $stuckJobCount -gt 0) {
                $validationStatus = 'MISSING_JOBS'
                $hasIssues = $true
            }
            elseif ($systemFailureCount -gt 0) {
                $validationStatus = 'SYSTEM_FAILURE'
                $hasIssues = $true
            }
            elseif ($totalFailureCount -gt 0) {
                $validationStatus = 'CRITICAL_FAILURE'
                $hasIssues = $true
            }
            elseif ($partialCount -gt 0) {
                $validationStatus = 'PARTIAL_FAILURE'
                $hasIssues = $true
            }
            elseif ($businessRejectionCount -gt 0) {
                $validationStatus = 'BUSINESS_REJECTION'
            }
            elseif ($canceledJobCount -gt 0 -and $successCount -eq 0) {
                $validationStatus = 'FLOW_NOT_RUN'
            }
            
            Write-Log "    Status: $validationStatus (OK:$successCount Fail:$totalFailureCount SysFail:$systemFailureCount Missing:$pendingJobCount Stuck:$stuckJobCount BizReject:$businessRejectionCount)" "INFO"
            
            if ($hasIssues) {
                $issuesFound++
                Write-Log "    Issues found - ticket will be created" "WARN"
            }
            
            if (-not $PreviewOnly) {
                # Insert ValidationLog record
                $insertLogQuery = @"
                    INSERT INTO JobFlow.ValidationLog (
                        tracking_id,
                        job_sqnc_id,
                        job_sqnc_shrt_nm,
                        execution_date,
                        validation_dttm,
                        validation_status,
                        expected_job_count,
                        actual_job_count,
                        missing_job_count,
                        unexpected_job_count,
                        failed_job_count,
                        critical_jobs_missing,
                        critical_jobs_failed,
                        created_dttm
                    )
                    OUTPUT INSERTED.validation_id
                    VALUES (
                        $trackingId,
                        $($flow.job_sqnc_id),
                        '$jobSqncShrtNm',
                        '$executionDate',
                        GETDATE(),
                        '$validationStatus',
                        $expectedJobCount,
                        $actualJobCount,
                        $($pendingJobCount + $stuckJobCount),
                        0,
                        $($totalFailureCount + $businessRejectionCount + $systemFailureCount),
                        (SELECT COUNT(*) FROM JobFlow.JobExecutionLog jed 
                         LEFT JOIN JobFlow.JobConfig jc ON jed.job_id = jc.job_id
                         WHERE jed.tracking_id = $trackingId 
                           AND jed.job_stts_cd IN (1, 5, 6) 
                           AND ISNULL(jc.is_critical, 0) = 1),
                        $totalFailureCount,
                        GETDATE()
                    )
"@

                $validationIdResult = Get-SqlData -Query $insertLogQuery
                $validationId = if ($validationIdResult) { $validationIdResult.validation_id } else { $null }
                
                # Insert ValidationException records for problem jobs
                if ($validationId -and $problemJobs.Count -gt 0) {
                    foreach ($pj in $problemJobs) {
                        $exceptionType = switch ($pj.validation_result) {
                            'NEVER_EXECUTED' { 'MISSING_JOB' }
                            'STUCK_EXECUTING' { 'STUCK_JOB' }
                            'STUCK_CANCELLING' { 'STUCK_JOB' }
                            'TOTAL_FAILURE' { 'FAILED_JOB' }
                            'SYSTEM_FAILURE' { 'SYSTEM_FAILURE' }
                            'BUSINESS_REJECTION' { 'BUSINESS_REJECTION' }
                            'PARTIAL' { 'UNEXPECTED_JOB' }
                            default { 'UNKNOWN' }
                        }
                        
                        $isCritical = if ($pj.is_critical) { 1 } else { 0 }
                        
                        $insertExceptionQuery = @"
                            INSERT INTO JobFlow.ValidationException (
                                validation_id,
                                job_id,
                                job_shrt_nm,
                                exception_type,
                                is_critical,
                                created_dttm
                            )
                            SELECT 
                                $validationId,
                                job_id,
                                '$($pj.job_shrt_nm)',
                                '$exceptionType',
                                $isCritical,
                                GETDATE()
                            FROM JobFlow.JobExecutionLog
                            WHERE tracking_id = $trackingId AND job_shrt_nm = '$($pj.job_shrt_nm)'
"@
                        Invoke-SqlNonQuery -Query $insertExceptionQuery | Out-Null
                    }
                }
                
                # Queue Jira ticket if issues found
                if ($hasIssues) {
                    # Check deduplication
                    $jiraExistsQuery = @"
                        SELECT 1 FROM Jira.RequestLog
                        WHERE Trigger_Type = 'JobFlow_Validation'
                          AND Trigger_Value = '$triggerValue'
                          AND StatusCode = 201
                          AND TicketKey IS NOT NULL
                          AND TicketKey != 'Email'
"@
                    $jiraExists = Get-SqlData -Query $jiraExistsQuery
                    
                    if (-not $jiraExists) {
                        $ticketSummary = "JobFlow Validation: $jobSqncShrtNm - $validationStatus"
                        
                        # Build problem jobs list
                        $problemJobsList = ($problemJobs | ForEach-Object {
                            $detail = "  - $($_.job_shrt_nm): $($_.validation_result)"
                            if ($_.failed_count) { $detail += " ($($_.failed_count) records)" }
                            if ($_.error_description) { $detail += " - $($_.error_description)" }
                            if ($_.error_message) { $detail += " - $($_.error_message)" }
                            if ($_.criticality_reason) { $detail += " [Critical: $($_.criticality_reason)]" }
                            $detail
                        }) -join "`r`n"
                        
                        $ticketDescription = @"
Job Flow validation detected issues after completion.

Flow: $jobSqncShrtNm
Execution Date: $executionDate
Validation Status: $validationStatus

Summary:
  Expected Jobs: $expectedJobCount
  Jobs Not Executed: $($pendingJobCount + $stuckJobCount)
  Jobs with System Failure: $systemFailureCount
  Jobs with Critical Failure: $totalFailureCount
  Jobs with Business Rejection: $businessRejectionCount (suppressed)

Problem Jobs:
$problemJobsList
"@
                        $jiraQuery = @"
                            EXEC Jira.sp_QueueTicket
                                @SourceModule = 'JobFlow',
                                @ProjectKey = 'SD',
                                @Summary = '$($ticketSummary -replace "'", "''")',
                                @Description = '$($ticketDescription -replace "'", "''")',
                                @IssueType = 'Issue',
                                @Priority = 'Highest',
                                @EmailRecipients = 'applications@frost-arnett.com;biteam@frost-arnett.com',
                                @CascadingField_ID = 'customfield_18401',
                                @CascadingField_ParentValue = 'Debt Manager',
                                @CascadingField_ChildValue = 'DM Configuration Issues',
                                @CustomField_ID = 'customfield_10305',
                                @CustomField_Value = 'FAC INFORMATION TECHNOLOGY',
                                @CustomField2_ID = 'customfield_10009',
                                @CustomField2_Value = 'sd/1b77b626-3ad4-4bee-8727-abc18b68c5fa',
                                @DueDate = '$executionDate',
                                @TriggerType = 'JobFlow_Validation',
                                @TriggerValue = '$triggerValue'
"@
                        Invoke-SqlNonQuery -Query $jiraQuery | Out-Null
                        Write-Log "    Jira ticket queued" "SUCCESS"
                    }
                    else {
                        Write-Log "    Jira ticket already exists for $triggerValue - suppressed" "INFO"
                    }
                }
                
                # Update flow state to VALIDATED
                $updateFlowQuery = @"
                    UPDATE JobFlow.FlowExecutionTracking
                    SET execution_state = 'VALIDATED',
                        is_validated = 1,
                        validation_dttm = GETDATE(),
                        last_activity_dttm = GETDATE(),
                        modified_dttm = GETDATE()
                    WHERE tracking_id = $trackingId
"@
                Invoke-SqlNonQuery -Query $updateFlowQuery | Out-Null
            }
            else {
                Write-Log "    PREVIEW: Would insert ValidationLog, exceptions, and update state to VALIDATED" "WARN"
                if ($hasIssues) {
                    Write-Log "    PREVIEW: Would queue Jira ticket" "WARN"
                }
            }
        }
        
        Write-Log "  Flows validated: $flowsValidated, Issues found: $issuesFound" "INFO"
        
        # Update status: success
        if (-not $PreviewOnly) {
            Invoke-SqlNonQuery -Query @"
                UPDATE JobFlow.Status 
                SET completed_dttm = GETDATE(), 
                    last_status = 'SUCCESS', 
                    last_result_count = $flowsValidated 
                WHERE process_name = 'ValidateFlows'
"@ | Out-Null
        }
        
        return @{ 
            FlowsValidated = $flowsValidated
            IssuesFound = $issuesFound 
        }
    }
    catch {
        $errorMessage = $_.Exception.Message -replace "'", "''"
        Write-Log "  Error in ValidateFlows: $($_.Exception.Message)" "ERROR"
        
        # Update status: failed
        if (-not $PreviewOnly) {
            Invoke-SqlNonQuery -Query @"
                UPDATE JobFlow.Status 
                SET completed_dttm = GETDATE(), 
                    last_status = 'FAILED', 
                    last_error_message = '$errorMessage'
                WHERE process_name = 'ValidateFlows'
"@ | Out-Null
        }
        
        return @{ FlowsValidated = 0; IssuesFound = 0; Error = $_.Exception.Message }
    }
}

function Step-DetectMissingFlows {
    <#
    .SYNOPSIS
        Detects flows that were scheduled to run but haven't started
        Checks against JobFlow.FlowConfig and JobFlow.Schedule
    #>
    param([bool]$PreviewOnly = $true)
    
    Write-Log "Step: Detect Missing Flows" "STEP"
    
    $currentDate = Get-Date -Format "yyyy-MM-dd"
    $currentDttm = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $missingCount = 0
    $alertsQueued = 0
    
    # Update status: started
    if (-not $PreviewOnly) {
        Invoke-SqlNonQuery -Query @"
            UPDATE JobFlow.Status 
            SET started_dttm = GETDATE(), 
                last_status = NULL, 
                last_error_message = NULL 
            WHERE process_name = 'DetectMissing'
"@ | Out-Null
    }
    
    try {
        # Query for missing flows across all schedule types
        $missingFlowsQuery = @"
            DECLARE @current_date DATE = '$currentDate';
            DECLARE @current_dttm DATETIME = '$currentDttm';
            
            SELECT 
                c.config_id,
                s.schedule_id,
                c.job_sqnc_id,
                c.job_sqnc_shrt_nm,
                c.job_sqnc_nm,
                s.schedule_type,
                s.expected_start_time,
                s.start_time_tolerance_minutes,
                DATEADD(MINUTE, s.start_time_tolerance_minutes, 
                    CAST(@current_date AS DATETIME) + CAST(s.expected_start_time AS DATETIME)) AS deadline_dttm,
                DATEDIFF(MINUTE, 
                    DATEADD(MINUTE, s.start_time_tolerance_minutes, 
                        CAST(@current_date AS DATETIME) + CAST(s.expected_start_time AS DATETIME)),
                    @current_dttm) AS minutes_overdue
            FROM JobFlow.FlowConfig c
            INNER JOIN JobFlow.Schedule s ON s.job_sqnc_id = c.job_sqnc_id
            WHERE c.is_monitored = 1
              AND c.dm_is_active = 1
              AND s.alert_on_missing = 1
              AND s.is_active = 1
              AND @current_date BETWEEN s.effective_start_date AND ISNULL(s.effective_end_date, '9999-12-31')
              AND @current_dttm > DATEADD(MINUTE, s.start_time_tolerance_minutes, 
                    CAST(@current_date AS DATETIME) + CAST(s.expected_start_time AS DATETIME))
              AND DATEDIFF(MINUTE, 
                    DATEADD(MINUTE, s.start_time_tolerance_minutes, 
                        CAST(@current_date AS DATETIME) + CAST(s.expected_start_time AS DATETIME)),
                    @current_dttm) >= 15
              AND NOT EXISTS (
                  SELECT 1 FROM JobFlow.FlowExecutionTracking et
                  WHERE et.job_sqnc_id = c.job_sqnc_id
                    AND et.execution_date = @current_date
              )
              AND (
                  (s.schedule_type = 'DAILY')
                  OR (s.schedule_type = 'WEEKDAYS' AND DATEPART(WEEKDAY, @current_date) BETWEEN 2 AND 6)
                  OR (s.schedule_type = 'WEEKLY' AND s.schedule_day_of_week = DATEPART(WEEKDAY, @current_date))
                  OR (s.schedule_type = 'MONTHLY' AND s.schedule_day_of_month = DATEPART(DAY, @current_date))
                  OR (s.schedule_type = 'MONTHLY_WEEK' 
                      AND s.schedule_day_of_week = DATEPART(WEEKDAY, @current_date)
                      AND s.schedule_week_of_month = (DATEPART(DAY, @current_date) - 1) / 7 + 1)
              )
            ORDER BY deadline_dttm
"@
        
        $missingFlows = Get-SqlData -Query $missingFlowsQuery
        
        if (-not $missingFlows) {
            Write-Log "  No missing flows detected" "INFO"
            
            # Update status: success
            if (-not $PreviewOnly) {
                Invoke-SqlNonQuery -Query @"
                    UPDATE JobFlow.Status 
                    SET completed_dttm = GETDATE(), 
                        last_status = 'SUCCESS', 
                        last_result_count = 0 
                    WHERE process_name = 'DetectMissing'
"@ | Out-Null
            }
            
            return @{ MissingFlows = 0; AlertsQueued = 0 }
        }
        
        $missingCount = @($missingFlows).Count
        Write-Log "  Missing flows detected: $missingCount" "WARN"
        
        foreach ($flow in @($missingFlows)) {
            $jobSqncShrtNm = $flow.job_sqnc_shrt_nm
            $jobSqncNm = $flow.job_sqnc_nm
            $scheduleType = $flow.schedule_type
            $expectedTime = $flow.expected_start_time
            $minutesOverdue = $flow.minutes_overdue
            $deadlineDttm = $flow.deadline_dttm
            
            Write-Log "    $jobSqncShrtNm ($scheduleType) - $minutesOverdue minutes overdue" "ERROR"
            
            if (-not $PreviewOnly) {
                $triggerValue = "${jobSqncShrtNm}_${currentDate}"
                
                # Check Jira deduplication
                $jiraExistsQuery = @"
                    SELECT 1 FROM Jira.RequestLog
                    WHERE Trigger_Type = 'JobFlow_MissingFlow'
                      AND Trigger_Value = '$triggerValue'
                      AND StatusCode = 201
                      AND TicketKey IS NOT NULL
                      AND TicketKey != 'Email'
"@
                $jiraExists = Get-SqlData -Query $jiraExistsQuery

                if (-not $jiraExists) {
                    $ticketSummary = "Missing Job Flow: $jobSqncShrtNm - $currentDate"
                    
                    $ticketDescription = @"
A scheduled job flow did not start as expected.

FLOW DETAILS:
Flow Code: $jobSqncShrtNm
Flow Name: $jobSqncNm
Schedule Type: $scheduleType
Expected Start: $expectedTime
Tolerance: $($flow.start_time_tolerance_minutes) minutes
Deadline: $($deadlineDttm.ToString('yyyy-MM-dd HH:mm:ss'))
Minutes Overdue: $minutesOverdue

IMPACT:
This flow was scheduled to run today but has not started. This may indicate a scheduler issue, application server problem, or configuration error.

ACTION REQUIRED:
1. Check Debt Manager scheduler status
2. Verify flow is still configured correctly in DM
3. Check JBoss application server logs
4. Manually trigger the flow if needed

REFERENCE:
Database: xFACts
Table: JobFlow.FlowConfig
"@
                        $jiraQuery = @"
                            EXEC Jira.sp_QueueTicket
                                @SourceModule = 'JobFlow',
                                @ProjectKey = 'SD',
                                @Summary = '$($ticketSummary -replace "'", "''")',
                                @Description = '$($ticketDescription -replace "'", "''")',
                                @IssueType = 'Issue',
                                @Priority = 'Highest',
                                @EmailRecipients = 'applications@frost-arnett.com;biteam@frost-arnett.com',
                                @CascadingField_ID = 'customfield_18401',
                                @CascadingField_ParentValue = 'Debt Manager',
                                @CascadingField_ChildValue = 'DM Configuration Issues',
                                @CustomField_ID = 'customfield_10305',
                                @CustomField_Value = 'FAC INFORMATION TECHNOLOGY',
                                @CustomField2_ID = 'customfield_10009',
                                @CustomField2_Value = 'sd/1b77b626-3ad4-4bee-8727-abc18b68c5fa',
                                @DueDate = '$executionDate',
                                @TriggerType = 'JobFlow_MissingFlow',
                                @TriggerValue = '$triggerValue'
"@
                    Invoke-SqlNonQuery -Query $jiraQuery | Out-Null
                    Write-Log "      Jira ticket queued" "SUCCESS"
                    $alertsQueued++
                }
                else {
                    Write-Log "      Jira ticket already exists - suppressed" "INFO"
                }
                
                # Queue Teams alert (dedup handled internally by Send-TeamsAlert)
                $teamsMessage = @"
Missing flow: $jobSqncShrtNm
Schedule: $scheduleType at $expectedTime
Overdue: $minutesOverdue minutes

Flow was expected to start by $($deadlineDttm.ToString('HH:mm')) but has not been detected. Check Debt Manager scheduler and application server.
"@
                Send-TeamsAlert -SourceModule 'JobFlow' -AlertCategory 'WARNING' `
                    -Title "{{WARN}} Missing Job Flow: $jobSqncShrtNm" `
                    -Message $teamsMessage -Color 'warning' `
                    -TriggerType 'JobFlow_MissingFlow' -TriggerValue $triggerValue | Out-Null
            }
            else {
                Write-Log "      PREVIEW: Would queue Jira ticket and Teams alert" "WARN"
            }
        }
        
        Write-Log "  Missing flows: $missingCount, Alerts queued: $alertsQueued" "INFO"
        
        # Update status: success
        if (-not $PreviewOnly) {
            Invoke-SqlNonQuery -Query @"
                UPDATE JobFlow.Status 
                SET completed_dttm = GETDATE(), 
                    last_status = 'SUCCESS', 
                    last_result_count = $missingCount 
                WHERE process_name = 'DetectMissing'
"@ | Out-Null
        }
        
        return @{ 
            MissingFlows = $missingCount
            AlertsQueued = $alertsQueued 
        }
    }
    catch {
        $errorMessage = $_.Exception.Message -replace "'", "''"
        Write-Log "  Error in DetectMissing: $($_.Exception.Message)" "ERROR"
        
        # Update status: failed
        if (-not $PreviewOnly) {
            Invoke-SqlNonQuery -Query @"
                UPDATE JobFlow.Status 
                SET completed_dttm = GETDATE(), 
                    last_status = 'FAILED', 
                    last_error_message = '$errorMessage'
                WHERE process_name = 'DetectMissing'
"@ | Out-Null
        }
        
        return @{ MissingFlows = 0; AlertsQueued = 0; Error = $_.Exception.Message }
    }
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

$scriptStart = Get-Date

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  xFACts JobFlow Monitor" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# Mode indicator
if ($Execute) {
    Write-Log "Mode: EXECUTE (changes will be applied)" "WARN"
}
else {
    Write-Log "Mode: PREVIEW (no changes will be made)" "INFO"
}

Write-Host ""

# Initialize configuration and server connections
if (-not (Initialize-Configuration)) {
    Write-Log "Configuration initialization failed - exiting" "ERROR"
    exit 1
}

Write-Host ""
Write-Host "----------------------------------------------------------------" -ForegroundColor DarkGray
Write-Host "  Executing Steps" -ForegroundColor DarkGray
Write-Host "----------------------------------------------------------------" -ForegroundColor DarkGray
Write-Host ""

$previewOnly = -not $Execute
$stepResults = @{}
$earlyExit = $false

# Step 0: Config Sync — always runs regardless of job activity
$stepResults.ConfigSync = Step-ConfigSync -PreviewOnly $previewOnly

# ── Early exit check: query DM for active jobs AND xFACts for unresolved flows ──
Write-Log "Checking for active job activity..." "INFO"
$activeJobsQuery = @"
    SELECT COUNT(*) AS active_count
    FROM dbo.job_log
    WHERE job_stts_cd IN (1, 6)
"@
$activeJobs = Get-SourceData -Query $activeJobsQuery
$dmActive = ($activeJobs -and $activeJobs.active_count -gt 0)

# Also check for flows that xFACts hasn't finished processing yet.
# Without this, the last flow in a run stays in EXECUTING/COMPLETE because
# the early exit skips Steps 2-6 that would resolve it.
$unresolvedFlowsQuery = @"
    SELECT COUNT(*) AS unresolved_count
    FROM JobFlow.FlowExecutionTracking
    WHERE execution_state IN ('DETECTED', 'EXECUTING', 'COMPLETE', 'STALLED')
    AND tracking_id > 0
"@
$unresolvedFlows = Get-SqlData -Query $unresolvedFlowsQuery
$xfactsUnresolved = ($unresolvedFlows -and $unresolvedFlows.unresolved_count -gt 0)

if (-not $dmActive -and -not $xfactsUnresolved) {
    Write-Log "No job activity detected and no unresolved flows. Running missing flow check then exiting." "INFO"
    $stepResults.MissingFlows = Step-DetectMissingFlows -PreviewOnly $previewOnly
    $earlyExit = $true

    # Reset Status rows for skipped steps so CC cards don't show stale data
    if (-not $previewOnly) {
        Invoke-SqlNonQuery -Query @"
            UPDATE JobFlow.Status
            SET last_result_count = 0,
                last_status = 'SUCCESS',
                completed_dttm = GETDATE()
            WHERE process_name IN ('DetectFlows', 'CaptureJobs', 'UpdateProgress', 
                                   'TransitionStates', 'ValidateFlows')
"@ | Out-Null

        Invoke-SqlNonQuery -Query @"
            UPDATE JobFlow.Status
            SET stall_no_progress_count = 0,
                stall_snapshot_xml = NULL,
                last_result_count = 0,
                last_status = 'SUCCESS',
                completed_dttm = GETDATE()
            WHERE process_name = 'DetectStalls'
"@ | Out-Null
    }
}
else {
    if ($dmActive) {
        Write-Log "Active job activity detected ($($activeJobs.active_count) job(s)). Running full pipeline." "INFO"
    } else {
        Write-Log "No active jobs in DM but $($unresolvedFlows.unresolved_count) unresolved flow(s) in xFACts. Running full pipeline to resolve." "INFO"
    }

    # Step 1: Detect new flows
    $stepResults.DetectFlows = Step-DetectFlows -PreviewOnly $previewOnly

    # Step 2: Capture completed jobs
    $stepResults.CaptureJobs = Step-CaptureCompletedJobs -PreviewOnly $previewOnly

    # Step 3: Update flow progress
    $stepResults.UpdateProgress = Step-UpdateFlowProgress -PreviewOnly $previewOnly

    # Step 4: Transition flow states
    $stepResults.TransitionStates = Step-TransitionFlowStates -PreviewOnly $previewOnly

    # Step 5: Detect stalls
    $stepResults.DetectStalls = Step-DetectStalls -PreviewOnly $previewOnly

    # Step 6: Validate completed flows
    $stepResults.ValidateFlows = Step-ValidateCompletedFlows -PreviewOnly $previewOnly

    # Step 7: Detect missing flows
    $stepResults.MissingFlows = Step-DetectMissingFlows -PreviewOnly $previewOnly
}

# ============================================================================
# SUMMARY
# ============================================================================

$scriptEnd = Get-Date
$scriptDuration = $scriptEnd - $scriptStart

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Execution Summary" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Read Server:  $($Script:ReadServer)"
Write-Host "  Write Server: $($Script:WriteServer)"
Write-Host ""

if ($earlyExit) {
    Write-Host "  Mode: EARLY EXIT (no active job activity)"
    Write-Host "  Results:"
    Write-Host "    Config Sync:        DM=$($stepResults.ConfigSync.DMFlowCount) | New=$($stepResults.ConfigSync.NewFlows) Deact=$($stepResults.ConfigSync.DeactivatedFlows) React=$($stepResults.ConfigSync.ReactivatedFlows)"
    Write-Host "    Missing Flows:      $($stepResults.MissingFlows.MissingFlows) (Alerts: $($stepResults.MissingFlows.AlertsQueued))"
}
else {
    Write-Host "  Results:"
    Write-Host "    Config Sync:        DM=$($stepResults.ConfigSync.DMFlowCount) | New=$($stepResults.ConfigSync.NewFlows) Deact=$($stepResults.ConfigSync.DeactivatedFlows) React=$($stepResults.ConfigSync.ReactivatedFlows)"
    Write-Host "    Flows Detected:     $($stepResults.DetectFlows.FlowsDetected)"
    Write-Host "    Jobs Captured:      $($stepResults.CaptureJobs.JobsCaptured)"
    Write-Host "    Flows Updated:      $($stepResults.UpdateProgress.FlowsUpdated)"
    Write-Host "    State Transitions:  $($stepResults.TransitionStates.DetectedToExecuting + $stepResults.TransitionStates.ExecutingToComplete)"
    Write-Host "    Stall State:        $($stepResults.DetectStalls.StallState) (Counter: $($stepResults.DetectStalls.Counter))"
    Write-Host "    Flows Validated:    $($stepResults.ValidateFlows.FlowsValidated) (Issues: $($stepResults.ValidateFlows.IssuesFound))"
    Write-Host "    Missing Flows:      $($stepResults.MissingFlows.MissingFlows) (Alerts: $($stepResults.MissingFlows.AlertsQueued))"
}

Write-Host ""
Write-Host "  Duration: $([int]$scriptDuration.TotalMilliseconds) ms"
Write-Host ""

if (-not $Execute) {
    Write-Host "  *** PREVIEW MODE - No changes were made ***" -ForegroundColor Yellow
    Write-Host "  Run with -Execute to perform actual updates" -ForegroundColor Yellow
    Write-Host ""
}

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  JobFlow Monitor Complete" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# Report completion to orchestrator (FIRE_AND_FORGET callback)
if ($TaskId -gt 0) {
    $totalMs = [int]$scriptDuration.TotalMilliseconds
    if ($earlyExit) {
        $outputSummary = "EarlyExit:NoActivity ConfigSync:$($stepResults.ConfigSync.DMFlowCount) Missing:$($stepResults.MissingFlows.MissingFlows)"
    }
    else {
        $outputSummary = "ConfigSync:$($stepResults.ConfigSync.DMFlowCount) Flows:$($stepResults.DetectFlows.FlowsDetected) Jobs:$($stepResults.CaptureJobs.JobsCaptured) Validated:$($stepResults.ValidateFlows.FlowsValidated)"
    }

    Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
        -TaskId $TaskId -ProcessId $ProcessId `
        -Status "SUCCESS" -DurationMs $totalMs `
        -Output $outputSummary
}

exit 0
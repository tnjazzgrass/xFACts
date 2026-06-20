<#
.SYNOPSIS
    xFACts - Business Services Review Request Distribution

.DESCRIPTION
    Automated distribution of unassigned review requests to configured users in
    distribution-enabled groups. Reads the user roster and assignment caps from
    DeptOps tables, determines how many requests each user needs to reach their
    cap, then assigns the oldest unassigned requests in CRS5.

    Reads the user roster and caps from xFACts (DeptOps.BS_ReviewRequest_User) and
    current assigned counts from CRS5 directly (the live source of truth). Writes
    assignments to the CRS5 primary and does not update the xFACts tracking table;
    the collector handles that sync. Detects the AG primary for CRS5 writes, supports
    a preview mode, and attributes writes to the FAC\sqlmon service account usr_id.

.PARAMETER ServerInstance
    SQL Server instance hosting the xFACts database (default: AVG-PROD-LSNR).

.PARAMETER Database
    xFACts database name (default: xFACts).

.PARAMETER SourceDB
    Source database for Debt Manager data (default: crs5_oltp).

.PARAMETER Execute
    Perform writes. Without this flag, runs in preview/dry-run mode.

.PARAMETER ForceSourceServer
    Override AG detection and connect to a specific server for CRS5 operations.

.PARAMETER TaskId
    Orchestrator TaskLog ID for the completion callback. Default 0.

.PARAMETER ProcessId
    Orchestrator ProcessRegistry ID for the completion callback. Default 0.

.COMPONENT
    DeptOps.BusinessServices

.NOTES
    File Name : Distribute-BSReviewRequests.ps1
    Location  : E:\xFACts-PowerShell

    FILE ORGANIZATION
    -----------------
    CHANGELOG: CHANGE HISTORY
    PARAMETERS: SCRIPT PARAMETERS
    IMPORTS: SCRIPT DEPENDENCIES
    INITIALIZATION: SCRIPT INITIALIZATION
    VARIABLES: SERVER AND CONFIG STATE
    FUNCTIONS: CONFIGURATION
    FUNCTIONS: DISTRIBUTION STEPS
    EXECUTION: SCRIPT EXECUTION
#>

<# ============================================================================
   CHANGELOG: CHANGE HISTORY
   ----------------------------------------------------------------------------
   Dated change history, most recent first. Authoritative version tracking lives
   in dbo.System_Metadata (component DeptOps.BusinessServices).
   Prefix: (none)
   ============================================================================ #>

# 2026-06-19  Conformed to the xFACts PowerShell file format spec: section banners,
#             comment-based-help header with .COMPONENT, dedicated CHANGELOG section,
#             bsv-prefixed local functions, and single-line purpose comments. Deleted
#             the local Get-AGReplicaRoles and Get-SourceData copies and switched to the
#             shared orchestrator versions (Get-AGReplicaRoles -AGName, Get-SourceData
#             with explicit -ReadServer/-SourceDB). Renamed Initialize-Configuration to
#             Initialize-bsv_DistributeConfig and Invoke-bsv_SourceWrite to Invoke-bsv_SourceWrite.
#             Removed the Author and Version header fields (Version lives in System_Metadata).
#             Converted Write-Host output to the shared Write-Console family.
# 2026-03-11  Migrated to Initialize-XFActsScript shared infrastructure. Removed inline
#             Write-Log and Get-xFACtsData. Updated Get-SourceData/Invoke-bsv_SourceWrite
#             ApplicationName. Updated the header to component-level versioning.
# 2026-03-10  Round-robin distribution. Replaced sequential fill (first user gets all) with
#             round-robin assignment; users sorted by fewest currently assigned so the most
#             available capacity goes first. Each round gives one request per user before
#             cycling back. Cap enforcement preserved.
# 2026-02-13  Initial implementation. Oldest-first assignment from the unassigned backlog,
#             per-user cap enforcement, master enable/disable via GlobalConfig, AG-aware
#             CRS5 primary detection for writes, preview mode support, and Orchestrator v2
#             integration.

<# ============================================================================
   PARAMETERS: SCRIPT PARAMETERS
   ----------------------------------------------------------------------------
   Connection targets, the source database, the Execute write-guard, an optional
   server override, and the orchestrator TaskId/ProcessId callback identifiers.
   Prefix: (none)
   ============================================================================ #>

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

<# ============================================================================
   IMPORTS: SCRIPT DEPENDENCIES
   ----------------------------------------------------------------------------
   Shared orchestrator and script-infrastructure functions: initialization, logging,
   SQL access, AG replica resolution, source-data access, and the completion callback.
   Prefix: (none)
   ============================================================================ #>

. "$PSScriptRoot\xFACts-OrchestratorFunctions.ps1"

<# ============================================================================
   INITIALIZATION: SCRIPT INITIALIZATION
   ----------------------------------------------------------------------------
   One-time startup: loads the SQL module, sets application identity and log path,
   stores default connection targets, and applies the preview-mode execute guard.
   Prefix: (none)
   ============================================================================ #>

Initialize-XFActsScript -ScriptName 'Distribute-BSReviewRequests' `
    -ServerInstance $ServerInstance -Database $Database -Execute:$Execute

<# ============================================================================
   VARIABLES: SERVER AND CONFIG STATE
   ----------------------------------------------------------------------------
   Script-scope state populated by Initialize-bsv_DistributeConfig and read across the
   distribution step: resolved AG replica names, CRS5 read/write targets, the loaded
   GlobalConfig hashtable, and the resolved service-account usr_id.
   Prefix: bsv
   ============================================================================ #>

# Current AG primary server (physical name).
$script:AGPrimary = $null
# Current AG secondary server (physical name).
$script:AGSecondary = $null
# Server for crs5_oltp reads (AG secondary, or primary as fallback).
$script:CRS5ReadServer = $null
# Server for crs5_oltp writes (AG primary).
$script:CRS5WriteServer = $null
# Loaded GlobalConfig settings (AGName, DistributionEnabled, ServiceAccountUsername).
$script:Config = @{}
# Resolved CRS5 usr_id for the service account, used for write attribution.
$script:ServiceAccountUserId = $null

<# ============================================================================
   FUNCTIONS: CONFIGURATION
   ----------------------------------------------------------------------------
   Loads distribution configuration and the master enable switch, resolves the CRS5
   read and write servers via shared AG detection, and resolves the service-account usr_id.
   Prefix: bsv
   ============================================================================ #>

# Loads distribution config, checks the master switch, resolves CRS5 servers and the service usr_id.
function Initialize-bsv_DistributeConfig {
param()

    Write-Log "Loading configuration..." "INFO"

    $configQuery = @"
        SELECT module_name, setting_name, setting_value
        FROM dbo.GlobalConfig
        WHERE module_name IN ('DeptOps', 'Shared', 'dbo')
          AND is_active = 1
"@

    $configResults = Get-SqlData -Query $configQuery

    $script:Config = @{
        AGName                = "DMPRODAG"
        DistributionEnabled   = $true
        ServiceAccountUsername = "sqlmon"
    }

    if ($configResults) {
        foreach ($row in $configResults) {
            switch ($row.setting_name) {
                "AGName"                  { $script:Config.AGName = $row.setting_value }
                "bs_distribution_enabled" { $script:Config.DistributionEnabled = ($row.setting_value -eq '1') }
            }
        }
    }

    Write-Log "  AGName: $($script:Config.AGName)" "INFO"
    Write-Log "  Distribution Enabled: $($script:Config.DistributionEnabled)" "INFO"

    # Check master switch
    if (-not $script:Config.DistributionEnabled) {
        Write-Log "Distribution is DISABLED via GlobalConfig (bs_distribution_enabled = 0)" "WARN"
        return $false
    }

    # Determine servers
    if ($ForceSourceServer) {
        $script:CRS5ReadServer = $ForceSourceServer
        $script:CRS5WriteServer = $ForceSourceServer
        Write-Log "  CRS5 Server: $ForceSourceServer (forced via parameter)" "WARN"
    }
    else {
        Write-Log "Detecting AG replica roles..." "INFO"
        $agRoles = Get-AGReplicaRoles -AGName $script:Config.AGName

        if (-not $agRoles) {
            Write-Log "AG detection failed" "ERROR"
            return $false
        }

        $script:AGPrimary = $agRoles.PRIMARY
        $script:AGSecondary = $agRoles.SECONDARY

        Write-Log "  AG PRIMARY: $($script:AGPrimary)" "INFO"
        Write-Log "  AG SECONDARY: $($script:AGSecondary)" "INFO"

        # Read from secondary, write to primary
        $script:CRS5ReadServer = if ($script:AGSecondary) { $script:AGSecondary } else { $script:AGPrimary }
        $script:CRS5WriteServer = $script:AGPrimary

        if (-not $script:CRS5WriteServer) {
            Write-Log "Could not determine CRS5 write server (PRIMARY)" "ERROR"
            return $false
        }

        Write-Log "  CRS5 Read:  $($script:CRS5ReadServer)" "INFO"
        Write-Log "  CRS5 Write: $($script:CRS5WriteServer)" "SUCCESS"
    }

    # Resolve service account usr_id from CRS5
    Write-Log "Resolving service account usr_id..." "INFO"
    $svcAcctQuery = "SELECT usr_id FROM dbo.usr WHERE usr_usrnm = '$($script:Config.ServiceAccountUsername)'"
    $svcResult = Get-SourceData -Query $svcAcctQuery -ReadServer $script:CRS5ReadServer -SourceDB $SourceDB

    if (-not $svcResult -or @($svcResult).Count -eq 0) {
        Write-Log "Could not resolve usr_id for service account '$($script:Config.ServiceAccountUsername)'" "ERROR"
        return $false
    }

    $script:ServiceAccountUserId = @($svcResult)[0].usr_id
    Write-Log "  Service Account: $($script:Config.ServiceAccountUsername) (usr_id: $($script:ServiceAccountUserId.ToString()))" "INFO"

    return $true
}

<# ============================================================================
   FUNCTIONS: DISTRIBUTION STEPS
   ----------------------------------------------------------------------------
   The distribution pipeline: a CRS5 write wrapper and the round-robin assignment of
   oldest unassigned requests to users below their cap, per distribution-enabled group.
   Prefix: bsv
   ============================================================================ #>

# Executes a write query against the CRS5 write server, returning success as a boolean.
function Invoke-bsv_SourceWrite {
    param(
        [string]$Query,
        [int]$Timeout = 30
    )
    try {
        Invoke-Sqlcmd -ServerInstance $script:CRS5WriteServer -Database $SourceDB -Query $Query -QueryTimeout $Timeout -ApplicationName $script:XFActsAppName -ErrorAction Stop -SuppressProviderContextWarning -TrustServerCertificate
        return $true
    }
    catch {
        Write-Log "CRS5 write failed on $($script:CRS5WriteServer): $($_.Exception.Message)" "ERROR"
        return $false
    }
}

# Assigns oldest unassigned CRS5 requests round-robin to users below their cap, per group.
function Step-bsv_Distribute {
    param([bool]$PreviewOnly = $true)

    Write-Log "Step 1: Distribute Review Requests" "STEP"

    $totalAssigned = 0

    try {
        # Load distribution roster from xFACts
        $rosterQuery = @"
            SELECT
                u.user_id,
                u.dm_user_id,
                u.username,
                u.display_name,
                u.assignment_cap,
                u.group_id,
                g.dm_group_id,
                g.group_short_name
            FROM DeptOps.BS_ReviewRequest_User u
            INNER JOIN DeptOps.BS_ReviewRequest_Group g ON g.group_id = u.group_id
            WHERE u.is_active = 1
              AND g.distribution_enabled = 1
              AND g.is_active = 1
            ORDER BY g.dm_group_id, u.display_name
"@

        $roster = Get-SqlData -Query $rosterQuery

        if (-not $roster -or @($roster).Count -eq 0) {
            Write-Log "  No active distribution users found" "WARN"
            return @{ Assigned = 0; Error = $null }
        }

        Write-Log "  Loaded $(@($roster).Count) distribution user(s)" "INFO"

        # Group users by DM group ID
        $groupUsers = @{}
        foreach ($u in @($roster)) {
            $dmGid = $u.dm_group_id
            if (-not $groupUsers.ContainsKey($dmGid)) {
                $groupUsers[$dmGid] = @{
                    dm_group_id      = $dmGid
                    group_short_name = $u.group_short_name
                    users            = @()
                }
            }
            $groupUsers[$dmGid].users += $u
        }

        # Process each distribution-enabled group
        foreach ($dmGid in $groupUsers.Keys) {
            $groupInfo = $groupUsers[$dmGid]
            $groupName = $groupInfo.group_short_name

            Write-Log "  [$groupName] Processing distribution..." "INFO"

            # Get current assigned count per user from CRS5 (source of truth)
            $dmUserIds = @($groupInfo.users | ForEach-Object { $_.dm_user_id }) -join ','

            $currentCountsQuery = @"
                SELECT
                    cnsmr_rvw_rqst_assgn_usr_id AS dm_user_id,
                    COUNT(*) AS assigned_count
                FROM dbo.cnsmr_rvw_rqst
                WHERE cnsmr_rvw_rqst_assgnd_usr_grp_id = $dmGid
                  AND cnsmr_rvw_rqst_sft_dlt_flg = 'N'
                  AND cnsmr_rvw_rqst_assgn_usr_id IN ($dmUserIds)
                GROUP BY cnsmr_rvw_rqst_assgn_usr_id
"@

            $currentCounts = Get-SourceData -Query $currentCountsQuery -ReadServer $script:CRS5ReadServer -SourceDB $SourceDB
            $countMap = @{}
            if ($currentCounts) {
                foreach ($c in @($currentCounts)) {
                    $countMap[$c.dm_user_id] = [int]$c.assigned_count
                }
            }

            # Calculate how many each user needs
            $needsList = @()
            foreach ($u in $groupInfo.users) {
                $current = if ($countMap.ContainsKey($u.dm_user_id)) { $countMap[$u.dm_user_id] } else { 0 }
                $needed = [Math]::Max(0, [int]$u.assignment_cap - $current)

                Write-Log "    $($u.display_name): $current / $($u.assignment_cap) (needs $needed)" "DEBUG"

                if ($needed -gt 0) {
                    $needsList += @{
                        dm_user_id    = $u.dm_user_id
                        username      = $u.username
                        display_name  = $u.display_name
                        needed        = $needed
                        current_count = $current
                    }
                }
            }

            if ($needsList.Count -eq 0) {
                Write-Log "  [$groupName] All users at capacity" "INFO"
                continue
            }

            $totalNeeded = 0
            foreach ($n in $needsList) { $totalNeeded += $n.needed }
            Write-Log "  [$groupName] Total slots to fill: $totalNeeded" "INFO"

            # Fetch unassigned requests, oldest first
            $unassignedQuery = @"
                SELECT TOP ($totalNeeded)
                    cnsmr_rvw_rqst_id
                FROM dbo.cnsmr_rvw_rqst
                WHERE cnsmr_rvw_rqst_assgnd_usr_grp_id = $dmGid
                  AND cnsmr_rvw_rqst_sft_dlt_flg = 'N'
                  AND cnsmr_rvw_rqst_assgn_usr_id IS NULL
                ORDER BY cnsmr_rvw_rqst_assgn_dt ASC
"@

            $unassigned = Get-SourceData -Query $unassignedQuery -ReadServer $script:CRS5ReadServer -SourceDB $SourceDB

            if (-not $unassigned -or @($unassigned).Count -eq 0) {
                Write-Log "  [$groupName] No unassigned requests available" "INFO"
                continue
            }

            $available = @($unassigned)
            Write-Log "  [$groupName] Found $($available.Count) unassigned request(s)" "INFO"

            # Round-robin distribution - fewest assigned goes first
            $needsList = @($needsList | Sort-Object { $_.current_count })

            $idx = 0
            $userAssignedCounts = @{}
            foreach ($user in $needsList) { $userAssignedCounts[$user.dm_user_id] = 0 }

            while ($idx -lt $available.Count) {
                $assignedThisRound = $false

                foreach ($user in $needsList) {
                    if ($idx -ge $available.Count) { break }
                    if ($userAssignedCounts[$user.dm_user_id] -ge $user.needed) { continue }

                    $reqId = $available[$idx].cnsmr_rvw_rqst_id
                    $idx++

                    if ($PreviewOnly) {
                        Write-Log "    [Preview] Would assign request $reqId to $($user.display_name)" "DEBUG"
                        $userAssignedCounts[$user.dm_user_id]++
                        $totalAssigned++
                    }
                    else {
                        $assignQuery = @"
                            UPDATE dbo.cnsmr_rvw_rqst
                            SET cnsmr_rvw_rqst_assgn_usr_id = $($user.dm_user_id),
                                cnsmr_rvw_rqst_stts_cd = 1,
                                upsrt_dttm = GETDATE(),
                                upsrt_usr_id = $($script:ServiceAccountUserId),
                                upsrt_trnsctn_nmbr = upsrt_trnsctn_nmbr + 1
                            WHERE cnsmr_rvw_rqst_id = $reqId
                              AND cnsmr_rvw_rqst_assgn_usr_id IS NULL
                              AND cnsmr_rvw_rqst_sft_dlt_flg = 'N'
"@

                        $result = Invoke-bsv_SourceWrite -Query $assignQuery
                        if ($result) {
                            $userAssignedCounts[$user.dm_user_id]++
                            $totalAssigned++
                        }
                        else {
                            Write-Log "    Failed to assign request $reqId (may have been claimed)" "WARN"
                        }
                    }

                    $assignedThisRound = $true
                }

                # Safety: if no user could accept in this round, break to avoid infinite loop
                if (-not $assignedThisRound) { break }
            }

            foreach ($user in $needsList) {
                $count = $userAssignedCounts[$user.dm_user_id]
                if ($count -gt 0) {
                    Write-Log "    $($user.display_name): assigned $count request(s)" "SUCCESS"
                }
            }
        }

        Write-Log "  Total requests assigned: $totalAssigned" "SUCCESS"
        return @{ Assigned = $totalAssigned; Error = $null }
    }
    catch {
        Write-Log "  Error in distribution: $($_.Exception.Message)" "ERROR"
        return @{ Assigned = $totalAssigned; Error = $_.Exception.Message }
    }
}

<# ============================================================================
   EXECUTION: SCRIPT EXECUTION
   ----------------------------------------------------------------------------
   The distribution run: initialize configuration, run the distribution step, print the
   summary, and fire the orchestrator completion callback.
   Prefix: (none)
   ============================================================================ #>

$scriptStart = Get-Date

Write-Console
Write-ConsoleBanner -Label "xFACts BS Review Request Distribution" -Color Cyan

if ($Execute) {
    Write-Log "Mode: EXECUTE (changes will be applied to CRS5)" "WARN"
}
else {
    Write-Log "Mode: PREVIEW (no changes will be made)" "INFO"
}

Write-Console

if (-not (Initialize-bsv_DistributeConfig)) {
    Write-Log "Configuration initialization failed - exiting" "ERROR"

    if ($TaskId -gt 0) {
        $totalMs = [int]((Get-Date) - $scriptStart).TotalMilliseconds
        Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
            -TaskId $TaskId -ProcessId $ProcessId `
            -Status "FAILED" -DurationMs $totalMs `
            -ErrorMessage "Configuration initialization failed"
    }

    exit 1
}

Write-Console

$previewOnly = -not $Execute
$stepResults = @{}

Write-ConsoleBanner -Label "Executing Steps" -Color DarkGray -RuleChar '-'

$stepResults.Distribute = Step-bsv_Distribute -PreviewOnly $previewOnly

# SUMMARY

$scriptEnd = Get-Date
$scriptDuration = $scriptEnd - $scriptStart
$totalMs = [int]$scriptDuration.TotalMilliseconds

$finalStatus = "SUCCESS"
if ($stepResults.Distribute.Error) {
    $finalStatus = "FAILED"
}

Write-Console
Write-ConsoleBanner -Label "Execution Summary" -Color Cyan
Write-Console "  CRS5 Read:   $($script:CRS5ReadServer)"
Write-Console "  CRS5 Write:  $($script:CRS5WriteServer)"
Write-Console
Write-Console "  Results:"
Write-Console "    Requests Assigned: $($stepResults.Distribute.Assigned)"
Write-Console
Write-Console "  Duration: $totalMs ms"
Write-Console

if (-not $Execute) {
    Write-Console "  *** PREVIEW MODE - No changes were made ***" Yellow
    Write-Console "  Run with -Execute to perform actual updates" Yellow
    Write-Console
}

Write-ConsoleBanner -Label "BS Review Request Distribution Complete" -Color Cyan

# Orchestrator callback
if ($TaskId -gt 0) {
    $outputSummary = "Assigned:$($stepResults.Distribute.Assigned)"

    Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
        -TaskId $TaskId -ProcessId $ProcessId `
        -Status $finalStatus -DurationMs $totalMs `
        -Output $outputSummary
}
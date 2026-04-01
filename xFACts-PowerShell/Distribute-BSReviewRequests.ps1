<#
.SYNOPSIS
    xFACts - Business Services Review Request Distribution

.DESCRIPTION
    Automated distribution of unassigned review requests to configured users
    in distribution-enabled groups. Reads the user roster and assignment caps
    from DeptOps tables, determines how many requests each user needs to reach
    their cap, then assigns the oldest unassigned requests in CRS5.

    Key behaviors:
    - Reads user roster and caps from xFACts (DeptOps.BS_ReviewRequest_User)
    - Reads current assigned counts from CRS5 directly (source of truth for live state)
    - Writes assignments to CRS5 primary (updates cnsmr_rvw_rqst)
    - Does NOT update xFACts tracking table (collector handles sync)
    - AG-aware: detects primary for CRS5 writes
    - Supports preview mode for safe testing
    - Uses FAC\sqlmon service account usr_id for upsrt_usr_id attribution

.NOTES
    File Name      : Distribute-BSReviewRequests.ps1
    Location       : E:\xFACts-PowerShell
    Author         : Frost Arnett Applications Team
    Version        : Tracked in dbo.System_Metadata (component: DeptOps.BusinessServices)

.PARAMETER ServerInstance
    SQL Server instance hosting xFACts database (default: AVG-PROD-LSNR)

.PARAMETER Database
    xFACts database name (default: xFACts)

.PARAMETER SourceDB
    Source database for Debt Manager data (default: crs5_oltp)

.PARAMETER Execute
    Perform writes. Without this flag, runs in preview/dry-run mode.

.PARAMETER ForceSourceServer
    Override AG detection and connect to a specific server for CRS5 operations.

.PARAMETER TaskId
    Orchestrator TaskLog ID for completion callback. Default 0.

.PARAMETER ProcessId
    Orchestrator ProcessRegistry ID for completion callback. Default 0.

================================================================================
DEPLOYMENT REMINDERS
================================================================================
1. The service account (FAC\sqlmon) must have:
   - Read/Write access to crs5_oltp on the AG primary
   - Read access to crs5_oltp on the AG secondary
   - Read access to xFACts database
   - A corresponding usr record in crs5_oltp.dbo.usr
2. Required GlobalConfig entries:
   - Shared.AGName (default: DMPRODAG)
   - DeptOps.bs_distribution_enabled (master switch, default: 1)
3. Required DeptOps tables:
   - BS_ReviewRequest_Group (with distribution_enabled flag)
   - BS_ReviewRequest_User (user roster with assignment caps)
================================================================================

================================================================================
CHANGELOG
================================================================================
2026-03-11  Migrated to Initialize-XFActsScript shared infrastructure
            Removed inline Write-Log and Get-xFACtsData
            Renamed $ServerInstance/$Database to $ServerInstance/$Database
            Updated Get-SourceData/Invoke-SourceWrite ApplicationName
            Updated header to component-level versioning format
2026-03-10  Round-robin distribution
            Replaced sequential fill (first user gets all) with round-robin assignment
            Users sorted by fewest currently assigned — most available capacity goes first
            Each round gives one request per user before cycling back
            Cap enforcement preserved
2026-02-13  Initial implementation
            Oldest-first assignment from unassigned backlog
            Per-user cap enforcement
            Master enable/disable via GlobalConfig
            AG-aware CRS5 primary detection for writes
            Preview mode support
            Orchestrator v2 integration
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

Initialize-XFActsScript -ScriptName 'Distribute-BSReviewRequests' `
    -ServerInstance $ServerInstance -Database $Database -Execute:$Execute

# ============================================================================
# GLOBAL VARIABLES
# ============================================================================

$Script:AGPrimary = $null
$Script:AGSecondary = $null
$Script:CRS5ReadServer = $null
$Script:CRS5WriteServer = $null
$Script:Config = @{}
$Script:ServiceAccountUserId = $null

# ============================================================================
# FUNCTIONS
# ============================================================================

function Get-SourceData {
    param(
        [string]$Query,
        [int]$Timeout = 60
    )
    try {
        Invoke-Sqlcmd -ServerInstance $Script:CRS5ReadServer -Database $SourceDB -Query $Query -QueryTimeout $Timeout -ApplicationName $script:XFActsAppName -ErrorAction Stop -SuppressProviderContextWarning -TrustServerCertificate
    }
    catch {
        Write-Log "CRS5 read failed on $($Script:CRS5ReadServer): $($_.Exception.Message)" "ERROR"
        return $null
    }
}

function Invoke-SourceWrite {
    param(
        [string]$Query,
        [int]$Timeout = 30
    )
    try {
        Invoke-Sqlcmd -ServerInstance $Script:CRS5WriteServer -Database $SourceDB -Query $Query -QueryTimeout $Timeout -ApplicationName $script:XFActsAppName -ErrorAction Stop -SuppressProviderContextWarning -TrustServerCertificate
        return $true
    }
    catch {
        Write-Log "CRS5 write failed on $($Script:CRS5WriteServer): $($_.Exception.Message)" "ERROR"
        return $false
    }
}

# ============================================================================
# CONFIGURATION
# ============================================================================

function Get-AGReplicaRoles {
    $agName = $Script:Config.AGName

    if (-not $agName) {
        Write-Log "AGName not configured" "ERROR"
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

    $roles = @{ PRIMARY = $null; SECONDARY = $null }

    foreach ($row in $results) {
        if ($row.role_desc -eq 'PRIMARY')   { $roles.PRIMARY = $row.replica_server_name }
        elseif ($row.role_desc -eq 'SECONDARY') { $roles.SECONDARY = $row.replica_server_name }
    }

    return $roles
}

function Initialize-Configuration {
    Write-Log "Loading configuration..." "INFO"

    $configQuery = @"
        SELECT module_name, setting_name, setting_value
        FROM dbo.GlobalConfig
        WHERE module_name IN ('DeptOps', 'Shared', 'dbo')
          AND is_active = 1
"@

    $configResults = Get-SqlData -Query $configQuery

    $Script:Config = @{
        AGName                = "DMPRODAG"
        DistributionEnabled   = $true
        ServiceAccountUsername = "sqlmon"
    }

    if ($configResults) {
        foreach ($row in $configResults) {
            switch ($row.setting_name) {
                "AGName"                  { $Script:Config.AGName = $row.setting_value }
                "bs_distribution_enabled" { $Script:Config.DistributionEnabled = ($row.setting_value -eq '1') }
            }
        }
    }

    Write-Log "  AGName: $($Script:Config.AGName)" "INFO"
    Write-Log "  Distribution Enabled: $($Script:Config.DistributionEnabled)" "INFO"

    # Check master switch
    if (-not $Script:Config.DistributionEnabled) {
        Write-Log "Distribution is DISABLED via GlobalConfig (bs_distribution_enabled = 0)" "WARN"
        return $false
    }

    # Determine servers
    if ($ForceSourceServer) {
        $Script:CRS5ReadServer = $ForceSourceServer
        $Script:CRS5WriteServer = $ForceSourceServer
        Write-Log "  CRS5 Server: $ForceSourceServer (forced via parameter)" "WARN"
    }
    else {
        Write-Log "Detecting AG replica roles..." "INFO"
        $agRoles = Get-AGReplicaRoles

        if (-not $agRoles) {
            Write-Log "AG detection failed" "ERROR"
            return $false
        }

        $Script:AGPrimary = $agRoles.PRIMARY
        $Script:AGSecondary = $agRoles.SECONDARY

        Write-Log "  AG PRIMARY: $($Script:AGPrimary)" "INFO"
        Write-Log "  AG SECONDARY: $($Script:AGSecondary)" "INFO"

        # Read from secondary, write to primary
        $Script:CRS5ReadServer = if ($Script:AGSecondary) { $Script:AGSecondary } else { $Script:AGPrimary }
        $Script:CRS5WriteServer = $Script:AGPrimary

        if (-not $Script:CRS5WriteServer) {
            Write-Log "Could not determine CRS5 write server (PRIMARY)" "ERROR"
            return $false
        }

        Write-Log "  CRS5 Read:  $($Script:CRS5ReadServer)" "INFO"
        Write-Log "  CRS5 Write: $($Script:CRS5WriteServer)" "SUCCESS"
    }

    # Resolve service account usr_id from CRS5
    Write-Log "Resolving service account usr_id..." "INFO"
    $svcAcctQuery = "SELECT usr_id FROM dbo.usr WHERE usr_usrnm = '$($Script:Config.ServiceAccountUsername)'"
    $svcResult = Get-SourceData -Query $svcAcctQuery

    if (-not $svcResult -or @($svcResult).Count -eq 0) {
        Write-Log "Could not resolve usr_id for service account '$($Script:Config.ServiceAccountUsername)'" "ERROR"
        return $false
    }

    $Script:ServiceAccountUserId = @($svcResult)[0].usr_id
    Write-Log "  Service Account: $($Script:Config.ServiceAccountUsername) (usr_id: $($Script:ServiceAccountUserId.ToString()))" "INFO"

    return $true
}

# ============================================================================
# DISTRIBUTION LOGIC
# ============================================================================

function Step-Distribute {
    <#
    .SYNOPSIS
        For each distribution-enabled group, determines how many requests each
        user needs to reach their cap, then assigns the oldest unassigned requests.
    #>
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

            $currentCounts = Get-SourceData -Query $currentCountsQuery
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

            $unassigned = Get-SourceData -Query $unassignedQuery

            if (-not $unassigned -or @($unassigned).Count -eq 0) {
                Write-Log "  [$groupName] No unassigned requests available" "INFO"
                continue
            }

            $available = @($unassigned)
            Write-Log "  [$groupName] Found $($available.Count) unassigned request(s)" "INFO"

            # Round-robin distribution — fewest assigned goes first
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
                                upsrt_usr_id = $($Script:ServiceAccountUserId),
                                upsrt_trnsctn_nmbr = upsrt_trnsctn_nmbr + 1
                            WHERE cnsmr_rvw_rqst_id = $reqId
                              AND cnsmr_rvw_rqst_assgn_usr_id IS NULL
                              AND cnsmr_rvw_rqst_sft_dlt_flg = 'N'
"@

                        $result = Invoke-SourceWrite -Query $assignQuery
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

# ============================================================================
# MAIN EXECUTION
# ============================================================================

$scriptStart = Get-Date

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  xFACts BS Review Request Distribution" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

if ($Execute) {
    Write-Log "Mode: EXECUTE (changes will be applied to CRS5)" "WARN"
}
else {
    Write-Log "Mode: PREVIEW (no changes will be made)" "INFO"
}

Write-Host ""

if (-not (Initialize-Configuration)) {
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

Write-Host ""

$previewOnly = -not $Execute
$stepResults = @{}

Write-Host "----------------------------------------------------------------" -ForegroundColor DarkGray
Write-Host "  Executing Steps" -ForegroundColor DarkGray
Write-Host "----------------------------------------------------------------" -ForegroundColor DarkGray
Write-Host ""

$stepResults.Distribute = Step-Distribute -PreviewOnly $previewOnly

# ============================================================================
# SUMMARY
# ============================================================================

$scriptEnd = Get-Date
$scriptDuration = $scriptEnd - $scriptStart
$totalMs = [int]$scriptDuration.TotalMilliseconds

$finalStatus = "SUCCESS"
if ($stepResults.Distribute.Error) {
    $finalStatus = "FAILED"
}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Execution Summary" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  CRS5 Read:   $($Script:CRS5ReadServer)"
Write-Host "  CRS5 Write:  $($Script:CRS5WriteServer)"
Write-Host ""
Write-Host "  Results:"
Write-Host "    Requests Assigned: $($stepResults.Distribute.Assigned)"
Write-Host ""
Write-Host "  Duration: $totalMs ms"
Write-Host ""

if (-not $Execute) {
    Write-Host "  *** PREVIEW MODE - No changes were made ***" -ForegroundColor Yellow
    Write-Host "  Run with -Execute to perform actual updates" -ForegroundColor Yellow
    Write-Host ""
}

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  BS Review Request Distribution Complete" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# Orchestrator callback
if ($TaskId -gt 0) {
    $outputSummary = "Assigned:$($stepResults.Distribute.Assigned)"

    Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
        -TaskId $TaskId -ProcessId $ProcessId `
        -Status $finalStatus -DurationMs $totalMs `
        -Output $outputSummary
}

if ($finalStatus -eq "FAILED") { exit 1 } else { exit 0 }
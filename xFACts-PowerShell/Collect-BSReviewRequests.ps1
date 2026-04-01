<#
.SYNOPSIS
    xFACts - Business Services Review Request Collection

.DESCRIPTION
    xFACts - DeptOps.BusinessServices
    Script: Collect-BSReviewRequests.ps1
    Version: Tracked in dbo.System_Metadata (component: DeptOps.BusinessServices)

    Collects and synchronizes Business Services review request data from
    Debt Manager (CRS5) into the DeptOps.BS_ReviewRequest_Tracking table.
    Supports incremental sync using CRS5 transaction numbers to minimize
    source database load.

    Follows the xFACts collect pattern:
    - Reads from configurable AG replica (PRIMARY or SECONDARY) for CRS5 queries
    - Writes to xFACts via the AG listener
    - AG-aware: automatically detects current PRIMARY/SECONDARY roles
    - Supports preview mode for safe testing

    Step 1: Collect new review requests not yet in the tracking table
    Step 2: Update existing records where the CRS5 transaction number has changed

    CRS5 Field Mapping Notes (vendor naming is misleading):
      cnsmr_rvw_rqst_cmplt_usr_id  = Requesting user (submitted the request)
      cnsmr_rvw_rqst_assgn_dt      = Request date (not assignment date)
      cnsmr_rvw_rqst_assgn_usr_id  = Assigned user
      upsrt_usr_id                 = Completing user (only when sft_dlt_flg = Y)
      upsrt_dttm                   = Completion date (only when sft_dlt_flg = Y)

    CHANGELOG
    ---------
    2026-03-11  Migrated to Initialize-XFActsScript shared infrastructure
                Removed inline Write-Log, Get-xFACtsData, Invoke-xFACtsWrite
                Renamed $xFACtsServer/$xFACtsDB to $ServerInstance/$Database
                Updated header to component-level versioning format
    2026-02-13  Initial implementation
                Incremental sync using CRS5 upsrt_trnsctn_nmbr
                AG-aware replica detection for read operations
                Conditional completion field population
                Preview mode support, Orchestrator v2 integration

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
1. The service account running this script needs:
   - Read access to crs5_oltp on both DM-PROD-DB and DM-PROD-REP
   - Read/Write access to xFACts database
2. Required GlobalConfig entries:
   - Shared.AGName (default: DMPRODAG)
   - Shared.SourceReplica (PRIMARY or SECONDARY, default: SECONDARY)
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

Initialize-XFActsScript -ScriptName 'Collect-BSReviewRequests' `
    -ServerInstance $ServerInstance -Database $Database -Execute:$Execute

# ============================================================================
# GLOBAL VARIABLES
# ============================================================================

$Script:AGPrimary = $null
$Script:AGSecondary = $null
$Script:ReadServer = $null
$Script:WriteServer = $null
$Script:Config = @{}
$Script:Groups = $null

# ============================================================================
# FUNCTIONS
# ============================================================================

function Get-SourceData {
    param(
        [string]$Query,
        [int]$Timeout = 60
    )

    if (-not $Script:ReadServer) {
        Write-Log "ReadServer not configured - cannot query source" "ERROR"
        return $null
    }

    try {
        Invoke-Sqlcmd -ServerInstance $Script:ReadServer -Database $SourceDB -Query $Query -QueryTimeout $Timeout -ApplicationName $script:XFActsAppName -ErrorAction Stop -SuppressProviderContextWarning -TrustServerCertificate
    }
    catch {
        Write-Log "Source query failed on $($Script:ReadServer): $($_.Exception.Message)" "ERROR"
        return $null
    }
}

# ============================================================================
# CONFIGURATION
# ============================================================================

function Get-AGReplicaRoles {
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
    Write-Log "Loading configuration..." "INFO"

    # Load GlobalConfig settings
    $configQuery = @"
        SELECT module_name, setting_name, setting_value
        FROM dbo.GlobalConfig
        WHERE module_name IN ('DeptOps', 'Shared', 'dbo')
          AND is_active = 1
"@

    $configResults = Get-SqlData -Query $configQuery

    # Set defaults
    $Script:Config = @{
        AGName              = "DMPRODAG"
        SourceReplica       = "SECONDARY"
    }

    # Override with GlobalConfig values
    if ($configResults) {
        foreach ($row in $configResults) {
            switch ($row.setting_name) {
                "AGName"          { $Script:Config.AGName = $row.setting_value }
                "SourceReplica"   { $Script:Config.SourceReplica = $row.setting_value }
            }
        }
    }

    Write-Log "  AGName: $($Script:Config.AGName)" "INFO"
    Write-Log "  SourceReplica: $($Script:Config.SourceReplica)" "INFO"

    # Set write server (always the listener)
    $Script:WriteServer = $ServerInstance

    # Determine read server
    if ($ForceSourceServer) {
        $Script:ReadServer = $ForceSourceServer
        Write-Log "  ReadServer: $($Script:ReadServer) (forced via parameter)" "WARN"
    }
    else {
        Write-Log "Detecting AG replica roles..." "INFO"
        $agRoles = Get-AGReplicaRoles

        if (-not $agRoles) {
            Write-Log "AG detection failed - cannot determine read server" "ERROR"
            return $false
        }

        $Script:AGPrimary = $agRoles.PRIMARY
        $Script:AGSecondary = $agRoles.SECONDARY

        Write-Log "  AG PRIMARY: $($Script:AGPrimary)" "INFO"
        Write-Log "  AG SECONDARY: $($Script:AGSecondary)" "INFO"

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

    # Load active group IDs from xFACts
    $groupQuery = "SELECT group_id, dm_group_id, group_name, group_short_name FROM DeptOps.BS_ReviewRequest_Group WHERE is_active = 1"
    $Script:Groups = Get-SqlData -Query $groupQuery

    if (-not $Script:Groups) {
        Write-Log "No active groups found in BS_ReviewRequest_Group" "ERROR"
        return $false
    }

    $groupCount = @($Script:Groups).Count
    Write-Log "  Active groups: $groupCount" "INFO"
    foreach ($g in @($Script:Groups)) {
        Write-Log "    [$($g.dm_group_id)] $($g.group_name) ($($g.group_short_name))" "DEBUG"
    }

    return $true
}

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

function ConvertTo-SafeSQL {
    <#
    .SYNOPSIS
        Converts a value to a safe SQL string representation.
        Handles DBNull, escapes single quotes, and wraps strings in quotes.
    #>
    param(
        $Value,
        [string]$Type = "string"
    )

    if ($Value -is [DBNull] -or $null -eq $Value) {
        return "NULL"
    }

    switch ($Type) {
        "string"   { return "'" + ($Value.ToString() -replace "'", "''") + "'" }
        "datetime" { return "'" + $Value.ToString("yyyy-MM-dd HH:mm:ss.fff") + "'" }
        "int"      { return $Value.ToString() }
        default    { return "'" + ($Value.ToString() -replace "'", "''") + "'" }
    }
}

# ============================================================================
# STEP FUNCTIONS
# ============================================================================

function Step-CollectNewRequests {
    <#
    .SYNOPSIS
        Discovers new review requests in CRS5 not yet tracked in xFACts and inserts them.
        Uses MAX(dm_request_id) as the high-water mark — cnsmr_rvw_rqst_id is an
        incrementing BIGINT in CRS5, so any ID above our max is a new record.
    #>
    param([bool]$PreviewOnly = $true)

    Write-Log "Step 1: Collect New Review Requests" "STEP"

    $newCount = 0

    try {
        # Get the high-water mark from xFACts
        $hwmQuery = "SELECT ISNULL(MAX(dm_request_id), 0) AS max_request_id FROM DeptOps.BS_ReviewRequest_Tracking"
        $hwmResult = Get-SqlData -Query $hwmQuery
        $maxRequestId = $hwmResult.max_request_id

        Write-Log "  High-water mark: dm_request_id > $maxRequestId" "INFO"

        # Build the DM group ID list for the WHERE clause
        $dmGroupIds = @($Script:Groups | ForEach-Object { $_.dm_group_id }) -join ','

        # Build a lookup from dm_group_id to xFACts group_id (cast key to [long] for type safety)
        $groupMap = @{}
        foreach ($g in @($Script:Groups)) {
            $groupMap[[long]$g.dm_group_id] = $g.group_id
        }

        # Query CRS5 for requests above our high-water mark
        $sourceQuery = @"
            SELECT
                rr.cnsmr_rvw_rqst_id,
                rr.cnsmr_id,
                rr.cnsmr_rvw_rqst_assgnd_usr_grp_id,
                c.cnsmr_idntfr_agncy_id,
                c.cnsmr_nm_lst_txt,
                c.cnsmr_nm_frst_txt,
                w.wrkgrp_shrt_nm,
                rr.cnsmr_rvw_rqst_cmmnt,
                rr.cnsmr_rvw_rqst_stts_cd,
                rr.cnsmr_Rvw_rqst_sft_dlt_flg,
                rr.cnsmr_rvw_rqst_cmplt_usr_id,
                u_req.usr_usrnm AS requesting_username,
                rr.cnsmr_rvw_rqst_assgn_dt,
                rr.cnsmr_rvw_rqst_assgn_usr_id,
                u_asgn.usr_usrnm AS assigned_username,
                rr.upsrt_usr_id,
                u_cmplt.usr_usrnm AS completed_username,
                rr.upsrt_trnsctn_nmbr,
                rr.upsrt_dttm
            FROM dbo.cnsmr_rvw_rqst rr
            INNER JOIN dbo.cnsmr c
                ON c.cnsmr_id = rr.cnsmr_id
            INNER JOIN dbo.wrkgrp w
                ON w.wrkgrp_id = c.wrkgrp_id
            LEFT JOIN dbo.usr u_req
                ON u_req.usr_id = rr.cnsmr_rvw_rqst_cmplt_usr_id
            LEFT JOIN dbo.usr u_asgn
                ON u_asgn.usr_id = rr.cnsmr_rvw_rqst_assgn_usr_id
            LEFT JOIN dbo.usr u_cmplt
                ON u_cmplt.usr_id = rr.upsrt_usr_id
            WHERE rr.cnsmr_rvw_rqst_assgnd_usr_grp_id IN ($dmGroupIds)
              AND rr.cnsmr_rvw_rqst_id > $maxRequestId
"@

        Write-Log "  Querying CRS5 for new requests in groups: $dmGroupIds" "INFO"
        $sourceData = Get-SourceData -Query $sourceQuery -Timeout 120

        if (-not $sourceData) {
            Write-Log "  No new requests found" "INFO"
            return @{ New = 0; Error = $null }
        }

        $newRequests = @($sourceData)
        Write-Log "  Found $($newRequests.Count) new request(s) to insert" "INFO"

        foreach ($req in $newRequests) {
            $reqId = $req.cnsmr_rvw_rqst_id
            $dmGroupId = [long]$req.cnsmr_rvw_rqst_assgnd_usr_grp_id
            $xfGroupId = $groupMap[$dmGroupId]
            $isSoftDeleted = ($req.cnsmr_Rvw_rqst_sft_dlt_flg -ne [DBNull] -and $req.cnsmr_Rvw_rqst_sft_dlt_flg -eq 'Y')

            # Consumer fields
            $consumerId   = ConvertTo-SafeSQL $req.cnsmr_id "int"
            $consumerNum  = ConvertTo-SafeSQL $req.cnsmr_idntfr_agncy_id "string"
            $lastName     = ConvertTo-SafeSQL $req.cnsmr_nm_lst_txt "string"
            $firstName    = ConvertTo-SafeSQL $req.cnsmr_nm_frst_txt "string"
            $workgroup    = ConvertTo-SafeSQL $req.wrkgrp_shrt_nm "string"
            $comment      = ConvertTo-SafeSQL $req.cnsmr_rvw_rqst_cmmnt "string"
            $statusCode   = ConvertTo-SafeSQL $req.cnsmr_rvw_rqst_stts_cd "int"
            $sftDlt       = if ($req.cnsmr_Rvw_rqst_sft_dlt_flg -is [DBNull]) { "'N'" } else { "'" + $req.cnsmr_Rvw_rqst_sft_dlt_flg + "'" }

            # Requesting user (CRS5: cnsmr_rvw_rqst_cmplt_usr_id)
            $reqUserId    = ConvertTo-SafeSQL $req.cnsmr_rvw_rqst_cmplt_usr_id "int"
            $reqUsername   = ConvertTo-SafeSQL $req.requesting_username "string"
            $reqDate       = ConvertTo-SafeSQL $req.cnsmr_rvw_rqst_assgn_dt "datetime"

            # Assigned user
            $asgnUserId   = ConvertTo-SafeSQL $req.cnsmr_rvw_rqst_assgn_usr_id "int"
            $asgnUsername  = ConvertTo-SafeSQL $req.assigned_username "string"

            # Completion fields - only populated when soft deleted
            if ($isSoftDeleted) {
                $cmpltUserId  = ConvertTo-SafeSQL $req.upsrt_usr_id "int"
                $cmpltUsername = ConvertTo-SafeSQL $req.completed_username "string"
                $cmpltDate     = ConvertTo-SafeSQL $req.upsrt_dttm "datetime"
            }
            else {
                $cmpltUserId  = "NULL"
                $cmpltUsername = "NULL"
                $cmpltDate     = "NULL"
            }

            # Source sync fields
            $tranNum   = ConvertTo-SafeSQL $req.upsrt_trnsctn_nmbr "int"
            $upsrtDttm = ConvertTo-SafeSQL $req.upsrt_dttm "datetime"

            if ($PreviewOnly) {
                Write-Log "  [Preview] Would insert request $reqId (group $dmGroupId, sftDlt=$($req.cnsmr_Rvw_rqst_sft_dlt_flg))" "DEBUG"
                $newCount++
            }
            else {
                $insertQuery = @"
                    INSERT INTO DeptOps.BS_ReviewRequest_Tracking (
                        dm_request_id, dm_consumer_id, group_id,
                        consumer_number, consumer_last_name, consumer_first_name, workgroup,
                        request_comment, status_code, soft_delete_flag,
                        requesting_user_id, requesting_username, request_date,
                        assigned_user_id, assigned_username,
                        completed_user_id, completed_username, completion_date,
                        dm_transaction_number, dm_last_updated
                    )
                    VALUES (
                        $reqId, $consumerId, $xfGroupId,
                        $consumerNum, $lastName, $firstName, $workgroup,
                        $comment, $statusCode, $sftDlt,
                        $reqUserId, $reqUsername, $reqDate,
                        $asgnUserId, $asgnUsername,
                        $cmpltUserId, $cmpltUsername, $cmpltDate,
                        $tranNum, $upsrtDttm
                    )
"@

                $result = Invoke-SqlNonQuery -Query $insertQuery
                if ($result) {
                    $newCount++
                }
                else {
                    Write-Log "  Failed to insert request $reqId" "ERROR"
                }
            }
        }

        Write-Log "  New requests collected: $newCount" "SUCCESS"
        return @{ New = $newCount; Error = $null }
    }
    catch {
        Write-Log "  Error in Collect New Requests: $($_.Exception.Message)" "ERROR"
        return @{ New = $newCount; Error = $_.Exception.Message }
    }
}

function Step-UpdateChangedRequests {
    <#
    .SYNOPSIS
        Updates existing tracking records where the CRS5 transaction number has changed.
        Compares upsrt_trnsctn_nmbr per-row between CRS5 and xFACts to detect changes.
        This field increments every time a record is touched in the UI.

        Fields that can change over the lifecycle:
        - status_code, soft_delete_flag
        - assigned_user_id, assigned_username (distribution assigns)
        - completed_user_id, completed_username, completion_date (on soft delete)
        - workgroup (consumer workgroup can change)
        - dm_transaction_number, dm_last_updated (always updated)
    #>
    param([bool]$PreviewOnly = $true)

    Write-Log "Step 2: Update Changed Review Requests" "STEP"

    $updatedCount = 0

    try {
        # Get all tracked request IDs and their current transaction numbers
        $trackedQuery = "SELECT dm_request_id, dm_transaction_number FROM DeptOps.BS_ReviewRequest_Tracking"
        $trackedResults = Get-SqlData -Query $trackedQuery -Timeout 60

        if (-not $trackedResults) {
            Write-Log "  No tracked records to check for updates" "INFO"
            return @{ Updated = 0; Error = $null }
        }

        # Build a lookup of dm_request_id -> dm_transaction_number
        $trackedTrans = @{}
        foreach ($row in @($trackedResults)) {
            $trackedTrans[$row.dm_request_id] = $row.dm_transaction_number
        }

        Write-Log "  Loaded $($trackedTrans.Count) tracked records for comparison" "INFO"

        # Build the DM group ID list
        $dmGroupIds = @($Script:Groups | ForEach-Object { $_.dm_group_id }) -join ','

        # Get the high-water mark so we only look at existing records (not new ones Step 1 handles)
        $maxRequestId = ($trackedTrans.Keys | Measure-Object -Maximum).Maximum

        # Query CRS5 for all existing tracked records in our groups
        $sourceQuery = @"
            SELECT
                rr.cnsmr_rvw_rqst_id,
                rr.cnsmr_rvw_rqst_stts_cd,
                rr.cnsmr_Rvw_rqst_sft_dlt_flg,
                rr.cnsmr_rvw_rqst_assgn_usr_id,
                u_asgn.usr_usrnm AS assigned_username,
                rr.upsrt_usr_id,
                u_cmplt.usr_usrnm AS completed_username,
                w.wrkgrp_shrt_nm,
                rr.upsrt_trnsctn_nmbr,
                rr.upsrt_dttm
            FROM dbo.cnsmr_rvw_rqst rr
            INNER JOIN dbo.cnsmr c
                ON c.cnsmr_id = rr.cnsmr_id
            INNER JOIN dbo.wrkgrp w
                ON w.wrkgrp_id = c.wrkgrp_id
            LEFT JOIN dbo.usr u_asgn
                ON u_asgn.usr_id = rr.cnsmr_rvw_rqst_assgn_usr_id
            LEFT JOIN dbo.usr u_cmplt
                ON u_cmplt.usr_id = rr.upsrt_usr_id
            WHERE rr.cnsmr_rvw_rqst_assgnd_usr_grp_id IN ($dmGroupIds)
              AND rr.cnsmr_rvw_rqst_id <= $maxRequestId
"@

        Write-Log "  Querying CRS5 for existing records (id <= $maxRequestId) in groups: $dmGroupIds" "INFO"
        $sourceData = Get-SourceData -Query $sourceQuery -Timeout 120

        if (-not $sourceData) {
            Write-Log "  No source data returned for update check" "WARN"
            return @{ Updated = 0; Error = $null }
        }

        # Filter to records where the transaction number has changed
        $changedRows = @($sourceData | Where-Object {
            $trackedTrans.ContainsKey($_.cnsmr_rvw_rqst_id) -and
            $_.upsrt_trnsctn_nmbr -ne $trackedTrans[$_.cnsmr_rvw_rqst_id]
        })

        if ($changedRows.Count -eq 0) {
            Write-Log "  No changed records detected" "INFO"
            return @{ Updated = 0; Error = $null }
        }

        Write-Log "  Found $($changedRows.Count) changed record(s)" "INFO"

        foreach ($row in $changedRows) {
            $reqId = $row.cnsmr_rvw_rqst_id
            $isSoftDeleted = ($row.cnsmr_Rvw_rqst_sft_dlt_flg -ne [DBNull] -and $row.cnsmr_Rvw_rqst_sft_dlt_flg -eq 'Y')
            $sftDlt = if ($row.cnsmr_Rvw_rqst_sft_dlt_flg -is [DBNull]) { "'N'" } else { "'" + $row.cnsmr_Rvw_rqst_sft_dlt_flg + "'" }

            # Status
            $statusCode   = ConvertTo-SafeSQL $row.cnsmr_rvw_rqst_stts_cd "int"

            # Assigned user
            $asgnUserId   = ConvertTo-SafeSQL $row.cnsmr_rvw_rqst_assgn_usr_id "int"
            $asgnUsername  = ConvertTo-SafeSQL $row.assigned_username "string"

            # Workgroup (may have changed)
            $workgroup    = ConvertTo-SafeSQL $row.wrkgrp_shrt_nm "string"

            # Completion fields - only populated when soft deleted
            if ($isSoftDeleted) {
                $cmpltUserId  = ConvertTo-SafeSQL $row.upsrt_usr_id "int"
                $cmpltUsername = ConvertTo-SafeSQL $row.completed_username "string"
                $cmpltDate     = ConvertTo-SafeSQL $row.upsrt_dttm "datetime"
            }
            else {
                $cmpltUserId  = "NULL"
                $cmpltUsername = "NULL"
                $cmpltDate     = "NULL"
            }

            # Sync fields
            $tranNum   = ConvertTo-SafeSQL $row.upsrt_trnsctn_nmbr "int"
            $upsrtDttm = ConvertTo-SafeSQL $row.upsrt_dttm "datetime"

            if ($PreviewOnly) {
                $previewNote = if ($isSoftDeleted) { "COMPLETED" } else { "updated" }
                Write-Log "  [Preview] Would update request $reqId ($previewNote, tran $($row.upsrt_trnsctn_nmbr))" "DEBUG"
                $updatedCount++
            }
            else {
                $updQuery = @"
                    UPDATE DeptOps.BS_ReviewRequest_Tracking
                    SET status_code              = $statusCode,
                        soft_delete_flag          = $sftDlt,
                        assigned_user_id          = $asgnUserId,
                        assigned_username         = $asgnUsername,
                        workgroup                 = $workgroup,
                        completed_user_id         = $cmpltUserId,
                        completed_username        = $cmpltUsername,
                        completion_date           = $cmpltDate,
                        dm_transaction_number     = $tranNum,
                        dm_last_updated           = $upsrtDttm
                    WHERE dm_request_id = $reqId
"@

                $result = Invoke-SqlNonQuery -Query $updQuery
                if ($result) {
                    $updatedCount++
                }
                else {
                    Write-Log "  Failed to update request $reqId" "ERROR"
                }
            }
        }

        Write-Log "  Requests updated: $updatedCount" "SUCCESS"
        return @{ Updated = $updatedCount; Error = $null }
    }
    catch {
        Write-Log "  Error in Update Changed Requests: $($_.Exception.Message)" "ERROR"
        return @{ Updated = $updatedCount; Error = $_.Exception.Message }
    }
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

$scriptStart = Get-Date

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  xFACts BS Review Request Collection v1.0.0" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

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

# Step 1: Collect new requests from CRS5
$stepResults.Collect = Step-CollectNewRequests -PreviewOnly $previewOnly

# Step 2: Update changed requests
$stepResults.Update = Step-UpdateChangedRequests -PreviewOnly $previewOnly

# ============================================================================
# SUMMARY
# ============================================================================

$scriptEnd = Get-Date
$scriptDuration = $scriptEnd - $scriptStart
$totalMs = [int]$scriptDuration.TotalMilliseconds

$finalStatus = "SUCCESS"
if ($stepResults.Collect.Error -or $stepResults.Update.Error) {
    $finalStatus = "FAILED"
}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Execution Summary" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Read Server:  $($Script:ReadServer)"
Write-Host "  Write Server: $($Script:WriteServer)"
Write-Host ""
Write-Host "  Results:"
Write-Host "    New Requests:      $($stepResults.Collect.New)"
Write-Host "    Requests Updated:  $($stepResults.Update.Updated)"
Write-Host ""
Write-Host "  Duration: $totalMs ms"
Write-Host ""

if (-not $Execute) {
    Write-Host "  *** PREVIEW MODE - No changes were made ***" -ForegroundColor Yellow
    Write-Host "  Run with -Execute to perform actual updates" -ForegroundColor Yellow
    Write-Host ""
}

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  BS Review Request Collection Complete" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# Orchestrator callback
if ($TaskId -gt 0) {
    $outputSummary = "New:$($stepResults.Collect.New) Updated:$($stepResults.Update.Updated)"

    Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
        -TaskId $TaskId -ProcessId $ProcessId `
        -Status $finalStatus -DurationMs $totalMs `
        -Output $outputSummary
}

if ($finalStatus -eq "FAILED") { exit 1 } else { exit 0 }
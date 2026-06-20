<#
.SYNOPSIS
    xFACts - Business Services Review Request Collection

.DESCRIPTION
    Collects and synchronizes Business Services review request data from Debt
    Manager (CRS5) into the DeptOps.BS_ReviewRequest_Tracking table. Supports
    incremental sync using CRS5 transaction numbers to minimize source load.
    Reads from a configurable AG replica (PRIMARY or SECONDARY) for CRS5 queries,
    writes to xFACts via the AG listener, detects PRIMARY/SECONDARY roles
    automatically, and supports a preview mode for safe testing.

    Step 1 collects new review requests not yet in the tracking table. Step 2
    updates existing records where the CRS5 transaction number has changed.

    CRS5 field mapping notes (vendor naming is misleading):
      cnsmr_rvw_rqst_cmplt_usr_id  = Requesting user (submitted the request)
      cnsmr_rvw_rqst_assgn_dt      = Request date (not assignment date)
      cnsmr_rvw_rqst_assgn_usr_id  = Assigned user
      upsrt_usr_id                 = Completing user (only when sft_dlt_flg = Y)
      upsrt_dttm                   = Completion date (only when sft_dlt_flg = Y)

.PARAMETER ServerInstance
    SQL Server instance hosting the xFACts database (default: AVG-PROD-LSNR).

.PARAMETER Database
    xFACts database name (default: xFACts).

.PARAMETER SourceDB
    Source database for Debt Manager data (default: crs5_oltp).

.PARAMETER Execute
    Perform writes. Without this flag, runs in preview/dry-run mode.

.PARAMETER ForceSourceServer
    Override the GlobalConfig replica setting and connect to a specific server for
    reads. Useful for testing or when AG detection fails.

.PARAMETER TaskId
    Orchestrator TaskLog ID passed by the engine at launch, used for the task
    completion callback. Default 0 (no callback when run manually).

.PARAMETER ProcessId
    Orchestrator ProcessRegistry ID passed by the engine at launch, used for the
    task completion callback. Default 0 (no callback when run manually).

.COMPONENT
    DeptOps.BusinessServices

.NOTES
    File Name : Collect-BSReviewRequests.ps1
    Location  : E:\xFACts-PowerShell

    FILE ORGANIZATION
    -----------------
    CHANGELOG: CHANGE HISTORY
    PARAMETERS: SCRIPT PARAMETERS
    IMPORTS: SCRIPT DEPENDENCIES
    INITIALIZATION: SCRIPT INITIALIZATION
    VARIABLES: SERVER AND CONFIG STATE
    FUNCTIONS: CONFIGURATION
    FUNCTIONS: COLLECTION STEPS
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
#             Initialize-bsv_CollectConfig and ConvertTo-SafeSQL to ConvertTo-bsv_SafeSQL.
#             Converted Write-Host output to the shared Write-Console family.
# 2026-03-11  Migrated to Initialize-XFActsScript shared infrastructure. Removed inline
#             Write-Log, Get-xFACtsData, Invoke-xFACtsWrite. Renamed $xFACtsServer/$xFACtsDB
#             to $ServerInstance/$Database. Updated the header to component-level versioning.
# 2026-02-13  Initial implementation. Incremental sync using CRS5 upsrt_trnsctn_nmbr,
#             AG-aware replica detection for reads, conditional completion-field population,
#             preview mode support, and Orchestrator v2 integration.

<# ============================================================================
   PARAMETERS: SCRIPT PARAMETERS
   ----------------------------------------------------------------------------
   Connection targets, the source database, the Execute write-guard, an optional
   read-server override, and the orchestrator TaskId/ProcessId callback identifiers.
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

Initialize-XFActsScript -ScriptName 'Collect-BSReviewRequests' `
    -ServerInstance $ServerInstance -Database $Database -Execute:$Execute

<# ============================================================================
   VARIABLES: SERVER AND CONFIG STATE
   ----------------------------------------------------------------------------
   Script-scope state populated by Initialize-bsv_CollectConfig and read across the
   collection steps: resolved AG replica names, read/write targets, the loaded
   GlobalConfig hashtable, and the active review-request groups.
   Prefix: bsv
   ============================================================================ #>

# Current AG primary server (physical name).
$script:AGPrimary = $null
# Current AG secondary server (physical name).
$script:AGSecondary = $null
# Server for crs5_oltp reads (determined by GlobalConfig).
$script:ReadServer = $null
# Server for xFACts writes (AG listener).
$script:WriteServer = $null
# Loaded GlobalConfig settings (AGName, SourceReplica).
$script:Config = @{}
# Active review-request groups loaded from DeptOps.BS_ReviewRequest_Group.
$script:Groups = $null

<# ============================================================================
   FUNCTIONS: CONFIGURATION
   ----------------------------------------------------------------------------
   Loads collection configuration from GlobalConfig, resolves the read and write SQL
   targets via shared AG detection, and loads the active review-request groups.
   Prefix: bsv
   ============================================================================ #>

# Loads BS review collection config, resolves read/write servers, and loads active groups.
function Initialize-bsv_CollectConfig {
param()

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
    $script:Config = @{
        AGName              = "DMPRODAG"
        SourceReplica       = "SECONDARY"
    }

    # Override with GlobalConfig values
    if ($configResults) {
        foreach ($row in $configResults) {
            switch ($row.setting_name) {
                "AGName"          { $script:Config.AGName = $row.setting_value }
                "SourceReplica"   { $script:Config.SourceReplica = $row.setting_value }
            }
        }
    }

    Write-Log "  AGName: $($script:Config.AGName)" "INFO"
    Write-Log "  SourceReplica: $($script:Config.SourceReplica)" "INFO"

    # Set write server (always the listener)
    $script:WriteServer = $ServerInstance

    # Determine read server
    if ($ForceSourceServer) {
        $script:ReadServer = $ForceSourceServer
        Write-Log "  ReadServer: $($script:ReadServer) (forced via parameter)" "WARN"
    }
    else {
        Write-Log "Detecting AG replica roles..." "INFO"
        $agRoles = Get-AGReplicaRoles -AGName $script:Config.AGName

        if (-not $agRoles) {
            Write-Log "AG detection failed - cannot determine read server" "ERROR"
            return $false
        }

        $script:AGPrimary = $agRoles.PRIMARY
        $script:AGSecondary = $agRoles.SECONDARY

        Write-Log "  AG PRIMARY: $($script:AGPrimary)" "INFO"
        Write-Log "  AG SECONDARY: $($script:AGSecondary)" "INFO"

        if ($script:Config.SourceReplica -eq "PRIMARY") {
            $script:ReadServer = $script:AGPrimary
        }
        else {
            $script:ReadServer = $script:AGSecondary
        }

        if (-not $script:ReadServer) {
            Write-Log "Could not determine ReadServer from AG roles" "ERROR"
            return $false
        }

        Write-Log "  ReadServer: $($script:ReadServer) (from GlobalConfig: $($script:Config.SourceReplica))" "SUCCESS"
    }

    Write-Log "  WriteServer: $($script:WriteServer)" "INFO"

    # Load active group IDs from xFACts
    $groupQuery = "SELECT group_id, dm_group_id, group_name, group_short_name FROM DeptOps.BS_ReviewRequest_Group WHERE is_active = 1"
    $script:Groups = Get-SqlData -Query $groupQuery

    if (-not $script:Groups) {
        Write-Log "No active groups found in BS_ReviewRequest_Group" "ERROR"
        return $false
    }

    $groupCount = @($script:Groups).Count
    Write-Log "  Active groups: $groupCount" "INFO"
    foreach ($g in @($script:Groups)) {
        Write-Log "    [$($g.dm_group_id)] $($g.group_name) ($($g.group_short_name))" "DEBUG"
    }

    return $true
}

<# ============================================================================
   FUNCTIONS: COLLECTION STEPS
   ----------------------------------------------------------------------------
   The collection pipeline: a SQL value-safety helper, new-request discovery against
   the CRS5 high-water mark, and per-row change detection via transaction numbers.
   Prefix: bsv
   ============================================================================ #>

# Converts a value to a safe SQL literal, handling DBNull and escaping single quotes.
function ConvertTo-bsv_SafeSQL {
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

# Discovers CRS5 review requests above the xFACts high-water mark and inserts them.
function Step-bsv_CollectNewRequests {
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
        $dmGroupIds = @($script:Groups | ForEach-Object { $_.dm_group_id }) -join ','

        # Build a lookup from dm_group_id to xFACts group_id (cast key to [long] for type safety)
        $groupMap = @{}
        foreach ($g in @($script:Groups)) {
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
        $sourceData = Get-SourceData -Query $sourceQuery -ReadServer $script:ReadServer -SourceDB $SourceDB -Timeout 120

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
            $consumerId   = ConvertTo-bsv_SafeSQL $req.cnsmr_id "int"
            $consumerNum  = ConvertTo-bsv_SafeSQL $req.cnsmr_idntfr_agncy_id "string"
            $lastName     = ConvertTo-bsv_SafeSQL $req.cnsmr_nm_lst_txt "string"
            $firstName    = ConvertTo-bsv_SafeSQL $req.cnsmr_nm_frst_txt "string"
            $workgroup    = ConvertTo-bsv_SafeSQL $req.wrkgrp_shrt_nm "string"
            $comment      = ConvertTo-bsv_SafeSQL $req.cnsmr_rvw_rqst_cmmnt "string"
            $statusCode   = ConvertTo-bsv_SafeSQL $req.cnsmr_rvw_rqst_stts_cd "int"
            $sftDlt       = if ($req.cnsmr_Rvw_rqst_sft_dlt_flg -is [DBNull]) { "'N'" } else { "'" + $req.cnsmr_Rvw_rqst_sft_dlt_flg + "'" }

            # Requesting user (CRS5: cnsmr_rvw_rqst_cmplt_usr_id)
            $reqUserId    = ConvertTo-bsv_SafeSQL $req.cnsmr_rvw_rqst_cmplt_usr_id "int"
            $reqUsername   = ConvertTo-bsv_SafeSQL $req.requesting_username "string"
            $reqDate       = ConvertTo-bsv_SafeSQL $req.cnsmr_rvw_rqst_assgn_dt "datetime"

            # Assigned user
            $asgnUserId   = ConvertTo-bsv_SafeSQL $req.cnsmr_rvw_rqst_assgn_usr_id "int"
            $asgnUsername  = ConvertTo-bsv_SafeSQL $req.assigned_username "string"

            # Completion fields - only populated when soft deleted
            if ($isSoftDeleted) {
                $cmpltUserId  = ConvertTo-bsv_SafeSQL $req.upsrt_usr_id "int"
                $cmpltUsername = ConvertTo-bsv_SafeSQL $req.completed_username "string"
                $cmpltDate     = ConvertTo-bsv_SafeSQL $req.upsrt_dttm "datetime"
            }
            else {
                $cmpltUserId  = "NULL"
                $cmpltUsername = "NULL"
                $cmpltDate     = "NULL"
            }

            # Source sync fields
            $tranNum   = ConvertTo-bsv_SafeSQL $req.upsrt_trnsctn_nmbr "int"
            $upsrtDttm = ConvertTo-bsv_SafeSQL $req.upsrt_dttm "datetime"

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

# Updates tracked records whose CRS5 transaction number has changed since last sync.
function Step-bsv_UpdateChangedRequests {
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
        $dmGroupIds = @($script:Groups | ForEach-Object { $_.dm_group_id }) -join ','

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
        $sourceData = Get-SourceData -Query $sourceQuery -ReadServer $script:ReadServer -SourceDB $SourceDB -Timeout 120

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
            $statusCode   = ConvertTo-bsv_SafeSQL $row.cnsmr_rvw_rqst_stts_cd "int"

            # Assigned user
            $asgnUserId   = ConvertTo-bsv_SafeSQL $row.cnsmr_rvw_rqst_assgn_usr_id "int"
            $asgnUsername  = ConvertTo-bsv_SafeSQL $row.assigned_username "string"

            # Workgroup (may have changed)
            $workgroup    = ConvertTo-bsv_SafeSQL $row.wrkgrp_shrt_nm "string"

            # Completion fields - only populated when soft deleted
            if ($isSoftDeleted) {
                $cmpltUserId  = ConvertTo-bsv_SafeSQL $row.upsrt_usr_id "int"
                $cmpltUsername = ConvertTo-bsv_SafeSQL $row.completed_username "string"
                $cmpltDate     = ConvertTo-bsv_SafeSQL $row.upsrt_dttm "datetime"
            }
            else {
                $cmpltUserId  = "NULL"
                $cmpltUsername = "NULL"
                $cmpltDate     = "NULL"
            }

            # Sync fields
            $tranNum   = ConvertTo-bsv_SafeSQL $row.upsrt_trnsctn_nmbr "int"
            $upsrtDttm = ConvertTo-bsv_SafeSQL $row.upsrt_dttm "datetime"

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

<# ============================================================================
   EXECUTION: SCRIPT EXECUTION
   ----------------------------------------------------------------------------
   The collection run: initialize configuration, collect new requests, update changed
   records, print the summary, and fire the orchestrator completion callback.
   Prefix: (none)
   ============================================================================ #>

$scriptStart = Get-Date

Write-Console
Write-ConsoleBanner -Label "xFACts BS Review Request Collection" -Color Cyan

if ($Execute) {
    Write-Log "Mode: EXECUTE (changes will be applied)" "WARN"
}
else {
    Write-Log "Mode: PREVIEW (no changes will be made)" "INFO"
}

Write-Console

# Initialize configuration and server connections
if (-not (Initialize-bsv_CollectConfig)) {
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

# Step 1: Collect new requests from CRS5
$stepResults.Collect = Step-bsv_CollectNewRequests -PreviewOnly $previewOnly

# Step 2: Update changed requests
$stepResults.Update = Step-bsv_UpdateChangedRequests -PreviewOnly $previewOnly

# SUMMARY

$scriptEnd = Get-Date
$scriptDuration = $scriptEnd - $scriptStart
$totalMs = [int]$scriptDuration.TotalMilliseconds

$finalStatus = "SUCCESS"
if ($stepResults.Collect.Error -or $stepResults.Update.Error) {
    $finalStatus = "FAILED"
}

Write-Console
Write-ConsoleBanner -Label "Execution Summary" -Color Cyan
Write-Console "  Read Server:  $($script:ReadServer)"
Write-Console "  Write Server: $($script:WriteServer)"
Write-Console
Write-Console "  Results:"
Write-Console "    New Requests:      $($stepResults.Collect.New)"
Write-Console "    Requests Updated:  $($stepResults.Update.Updated)"
Write-Console
Write-Console "  Duration: $totalMs ms"
Write-Console

if (-not $Execute) {
    Write-Console "  *** PREVIEW MODE - No changes were made ***" Yellow
    Write-Console "  Run with -Execute to perform actual updates" Yellow
    Write-Console
}

Write-ConsoleBanner -Label "BS Review Request Collection Complete" -Color Cyan

# Orchestrator callback
if ($TaskId -gt 0) {
    $outputSummary = "New:$($stepResults.Collect.New) Updated:$($stepResults.Update.Updated)"

    Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
        -TaskId $TaskId -ProcessId $ProcessId `
        -Status $finalStatus -DurationMs $totalMs `
        -Output $outputSummary
}
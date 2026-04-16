<#
.SYNOPSIS
    xFACts - Client Hierarchy Synchronization

.DESCRIPTION
    xFACts - Engine.SharedInfrastructure
    Script: Sync-ClientHierarchy.ps1
    Version: Tracked in dbo.System_Metadata (component: Engine.SharedInfrastructure)

    Rebuilds dbo.ClientHierarchy from crs5_oltp creditor and creditor group
    tables using a recursive CTE to resolve the full group hierarchy in a
    single pass. Uses MERGE to insert new creditors, update changed metadata,
    and delete creditors that no longer exist in the source.

    The CTE walks the entire group tree regardless of soft-delete status,
    capturing the hierarchy as it exists in DM. Active flags at creditor,
    parent group, and top parent levels enable consumers to identify
    discrepancies (e.g., active creditor under a soft-deleted group).

    Standalone creditors (crdtr_grp_id = 1) and those with unresolvable
    group chains self-reference: their parent and top parent fields point
    to themselves.

    CHANGELOG
    ---------
    2026-04-16  Initial implementation

.PARAMETER ServerInstance
    SQL Server instance hosting xFACts database (default: AVG-PROD-LSNR)

.PARAMETER Database
    xFACts database name (default: xFACts)

.PARAMETER Execute
    Perform writes. Without this flag, runs in preview/dry-run mode.

.PARAMETER TaskId
    Orchestrator TaskLog ID passed by the engine at launch. Used for task
    completion callback. Default 0 (no callback when run manually).

.PARAMETER ProcessId
    Orchestrator ProcessRegistry ID passed by the engine at launch. Used for
    task completion callback. Default 0 (no callback when run manually).

================================================================================
DEPLOYMENT REMINDERS
================================================================================
1. Deploy to E:\xFACts-PowerShell on FA-SQLDBB.
2. xFACts-OrchestratorFunctions.ps1 must be in the same directory.
3. The service account running this script needs:
   - Read access to crs5_oltp on AVG-PROD-LSNR (crdtr, crdtr_grp tables)
   - Read/Write access to xFACts database (dbo.ClientHierarchy)
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

Initialize-XFActsScript -ScriptName 'Sync-ClientHierarchy' `
    -ServerInstance $ServerInstance -Database $Database -Execute:$Execute

# ============================================================================
# MAIN
# ============================================================================

$scriptStart = Get-Date

Write-Log ""
Write-Log "================================================================"
Write-Log "  Client Hierarchy Synchronization"
Write-Log "================================================================"
Write-Log ""

# ----------------------------------------------------------------------------
# Step 1: Build hierarchy via recursive CTE and MERGE into ClientHierarchy
# ----------------------------------------------------------------------------

Write-Log "Building creditor hierarchy from crs5_oltp..."

$mergeQuery = @"
;WITH GroupHierarchy AS (
    -- Anchor: top-level groups (no parent, or parent is Group 1)
    -- Walks ALL groups regardless of soft-delete status to capture the real hierarchy
    SELECT 
        crdtr_grp_id,
        crdtr_grp_shrt_nm,
        crdtr_grp_nm,
        crdtr_grp_sft_dlt_flg,
        crdtr_grp_id            AS top_parent_id,
        crdtr_grp_shrt_nm       AS top_parent_key,
        crdtr_grp_nm            AS top_parent_name,
        crdtr_grp_sft_dlt_flg   AS top_parent_sft_dlt_flg
    FROM crs5_oltp.dbo.crdtr_grp
    WHERE (crdtr_grp_prnt_id IS NULL OR crdtr_grp_prnt_id = 1)
      AND crdtr_grp_id <> 1
    
    UNION ALL
    
    -- Recursive: walk down the group tree
    SELECT 
        cg.crdtr_grp_id,
        cg.crdtr_grp_shrt_nm,
        cg.crdtr_grp_nm,
        cg.crdtr_grp_sft_dlt_flg,
        gh.top_parent_id,
        gh.top_parent_key,
        gh.top_parent_name,
        gh.top_parent_sft_dlt_flg
    FROM crs5_oltp.dbo.crdtr_grp cg
    INNER JOIN GroupHierarchy gh ON cg.crdtr_grp_prnt_id = gh.crdtr_grp_id
),
SourceData AS (
    -- Group 1 = standalone (self-reference). NULL = unresolved group (self-reference as safety net).
    SELECT 
        cr.crdtr_id           AS creditor_id,
        cr.crdtr_shrt_nm      AS creditor_key,
        cr.crdtr_nm           AS creditor_name,

        CASE WHEN cr.crdtr_grp_id = 1 OR gh.crdtr_grp_id IS NULL
             THEN cr.crdtr_id       ELSE gh.crdtr_grp_id       END AS parent_group_id,
        CASE WHEN cr.crdtr_grp_id = 1 OR gh.crdtr_grp_id IS NULL
             THEN cr.crdtr_shrt_nm  ELSE gh.crdtr_grp_shrt_nm  END AS parent_group_key,
        CASE WHEN cr.crdtr_grp_id = 1 OR gh.crdtr_grp_id IS NULL
             THEN cr.crdtr_nm       ELSE gh.crdtr_grp_nm       END AS parent_group_name,
        CASE WHEN cr.crdtr_grp_id = 1 OR gh.crdtr_grp_id IS NULL
             THEN CASE WHEN cr.crdtr_stts_cd = 1 THEN 1 ELSE 0 END
             ELSE CASE WHEN gh.crdtr_grp_sft_dlt_flg = 'N' THEN 1 ELSE 0 END
        END AS parent_group_is_active,

        CASE WHEN cr.crdtr_grp_id = 1 OR gh.crdtr_grp_id IS NULL
             THEN cr.crdtr_id       ELSE gh.top_parent_id      END AS top_parent_id,
        CASE WHEN cr.crdtr_grp_id = 1 OR gh.crdtr_grp_id IS NULL
             THEN cr.crdtr_shrt_nm  ELSE gh.top_parent_key     END AS top_parent_key,
        CASE WHEN cr.crdtr_grp_id = 1 OR gh.crdtr_grp_id IS NULL
             THEN cr.crdtr_nm       ELSE gh.top_parent_name    END AS top_parent_name,
        CASE WHEN cr.crdtr_grp_id = 1 OR gh.crdtr_grp_id IS NULL
             THEN CASE WHEN cr.crdtr_stts_cd = 1 THEN 1 ELSE 0 END
             ELSE CASE WHEN gh.top_parent_sft_dlt_flg = 'N' THEN 1 ELSE 0 END
        END AS top_parent_is_active,

        CASE WHEN cr.crdtr_stts_cd = 1 THEN 1 ELSE 0 END AS is_active

    FROM crs5_oltp.dbo.crdtr cr
    LEFT JOIN GroupHierarchy gh ON cr.crdtr_grp_id = gh.crdtr_grp_id
)
MERGE dbo.ClientHierarchy AS tgt
USING SourceData AS src ON tgt.creditor_id = src.creditor_id
WHEN MATCHED AND (
       tgt.creditor_key            <> src.creditor_key
    OR tgt.creditor_name           <> src.creditor_name
    OR tgt.parent_group_id         <> src.parent_group_id
    OR tgt.parent_group_key        <> src.parent_group_key
    OR tgt.parent_group_name       <> src.parent_group_name
    OR tgt.parent_group_is_active  <> src.parent_group_is_active
    OR tgt.top_parent_id           <> src.top_parent_id
    OR tgt.top_parent_key          <> src.top_parent_key
    OR tgt.top_parent_name         <> src.top_parent_name
    OR tgt.top_parent_is_active    <> src.top_parent_is_active
    OR tgt.is_active               <> src.is_active
) THEN UPDATE SET
    creditor_key            = src.creditor_key,
    creditor_name           = src.creditor_name,
    parent_group_id         = src.parent_group_id,
    parent_group_key        = src.parent_group_key,
    parent_group_name       = src.parent_group_name,
    parent_group_is_active  = src.parent_group_is_active,
    top_parent_id           = src.top_parent_id,
    top_parent_key          = src.top_parent_key,
    top_parent_name         = src.top_parent_name,
    top_parent_is_active    = src.top_parent_is_active,
    is_active               = src.is_active,
    last_refreshed_dttm     = GETDATE()
WHEN NOT MATCHED BY TARGET THEN INSERT (
    creditor_id, creditor_key, creditor_name,
    parent_group_id, parent_group_key, parent_group_name, parent_group_is_active,
    top_parent_id, top_parent_key, top_parent_name, top_parent_is_active,
    is_active, last_refreshed_dttm
) VALUES (
    src.creditor_id, src.creditor_key, src.creditor_name,
    src.parent_group_id, src.parent_group_key, src.parent_group_name, src.parent_group_is_active,
    src.top_parent_id, src.top_parent_key, src.top_parent_name, src.top_parent_is_active,
    src.is_active, GETDATE()
)
WHEN NOT MATCHED BY SOURCE THEN DELETE
OUTPUT `$action;
"@

if ($Execute) {
    try {
        $mergeResults = Invoke-Sqlcmd -ServerInstance $ServerInstance -Database $Database `
            -Query $mergeQuery `
            -ApplicationName "xFACts Sync-ClientHierarchy" `
            -QueryTimeout 300 -ErrorAction Stop -TrustServerCertificate

        # Count MERGE actions
        $inserted = ($mergeResults | Where-Object { $_.'$action' -eq 'INSERT' } | Measure-Object).Count
        $updated  = ($mergeResults | Where-Object { $_.'$action' -eq 'UPDATE' } | Measure-Object).Count
        $deleted  = ($mergeResults | Where-Object { $_.'$action' -eq 'DELETE' } | Measure-Object).Count

        Write-Log "MERGE complete — Inserted: $inserted, Updated: $updated, Deleted: $deleted" "SUCCESS"
    }
    catch {
        Write-Log "MERGE failed: $($_.Exception.Message)" "ERROR"
        
        $scriptDuration = [int]((Get-Date) - $scriptStart).TotalMilliseconds
        if ($TaskId -gt 0) {
            Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
                -TaskId $TaskId -ProcessId $ProcessId `
                -Status "FAILED" -DurationMs $scriptDuration `
                -Output "MERGE failed: $($_.Exception.Message)"
        }
        exit 1
    }
}
else {
    Write-Log "[PREVIEW] MERGE query built but not executed" "WARN"
    $inserted = 0
    $updated = 0
    $deleted = 0
}

# ----------------------------------------------------------------------------
# Step 2: Update last_refreshed_dttm for unchanged rows
# ----------------------------------------------------------------------------

# Rows that matched but had no changes were not touched by MERGE.
# Stamp them so last_refreshed_dttm reflects this sync cycle ran.

if ($Execute) {
    Write-Log "Updating last_refreshed_dttm on unchanged rows..."

    try {
        $touchQuery = @"
UPDATE dbo.ClientHierarchy
SET last_refreshed_dttm = GETDATE()
WHERE last_refreshed_dttm < DATEADD(MINUTE, -5, GETDATE());
"@
        $touchResult = Invoke-Sqlcmd -ServerInstance $ServerInstance -Database $Database `
            -Query $touchQuery `
            -ApplicationName "xFACts Sync-ClientHierarchy" `
            -QueryTimeout 60 -ErrorAction Stop -TrustServerCertificate

        Write-Log "Timestamp refresh complete" "SUCCESS"
    }
    catch {
        Write-Log "Timestamp refresh failed (non-fatal): $($_.Exception.Message)" "WARN"
    }
}

# ----------------------------------------------------------------------------
# Step 3: Summary
# ----------------------------------------------------------------------------

$scriptEnd = Get-Date
$duration = $scriptEnd - $scriptStart
$totalDurationMs = [int]$duration.TotalMilliseconds

# Get final counts
$finalCounts = $null
try {
    $finalCounts = Invoke-Sqlcmd -ServerInstance $ServerInstance -Database $Database `
        -Query "
            SELECT 
                COUNT(*)                                                        AS total_creditors,
                ISNULL(SUM(CASE WHEN is_active = 1 THEN 1 ELSE 0 END), 0)      AS active_creditors,
                COUNT(DISTINCT top_parent_id)                                   AS top_parent_groups,
                ISNULL(SUM(CASE WHEN is_active = 1 AND parent_group_is_active = 0 THEN 1 ELSE 0 END), 0) AS active_in_inactive_group
            FROM dbo.ClientHierarchy;
        " `
        -ApplicationName "xFACts Sync-ClientHierarchy" `
        -QueryTimeout 30 -ErrorAction Stop -TrustServerCertificate
}
catch {
    Write-Log "Could not retrieve final counts: $($_.Exception.Message)" "WARN"
}

Write-Log ""
Write-Log "================================================================"
Write-Log "  SUMMARY$(if (-not $Execute) { ' [PREVIEW - No changes made]' })"
Write-Log "================================================================"
Write-Log ""
Write-Log "  Inserted:       $inserted"
Write-Log "  Updated:        $updated"
Write-Log "  Deleted:        $deleted"
Write-Log ""
if ($finalCounts) {
    Write-Log "  ClientHierarchy Now Contains:"
    Write-Log "    Total Creditors:          $($finalCounts.total_creditors)"
    Write-Log "    Active Creditors:         $($finalCounts.active_creditors)"
    Write-Log "    Top Parent Groups:        $($finalCounts.top_parent_groups)"
    Write-Log "    Active in Inactive Group: $($finalCounts.active_in_inactive_group)"
    Write-Log ""
}
Write-Log "  Duration:       $($duration.ToString('mm\:ss'))"
Write-Log ""
Write-Log "================================================================"
Write-Log "  Synchronization Complete"
Write-Log "================================================================"
Write-Log ""

# ----------------------------------------
# Orchestrator Callback
# ----------------------------------------
if ($TaskId -gt 0) {
    $outputSummary = "Ins:$inserted Upd:$updated Del:$deleted"
    if ($finalCounts) {
        $outputSummary += " Total:$($finalCounts.total_creditors) ActiveInInactiveGrp:$($finalCounts.active_in_inactive_group)"
    }
    Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
        -TaskId $TaskId -ProcessId $ProcessId `
        -Status "SUCCESS" -DurationMs $totalDurationMs `
        -Output $outputSummary
}

exit 0
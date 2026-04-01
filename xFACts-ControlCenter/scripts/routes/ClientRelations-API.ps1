# ============================================================================
# xFACts Control Center - Client Relations API Routes
# Location: E:\xFACts-ControlCenter\scripts\routes\ClientRelations-API.ps1
# 
# API endpoints for the Client Relations dashboard.
# 
# Reg F queue endpoint queries crs5_oltp via the secondary replica
# with server-side caching to minimize production database impact.
#
# Endpoints:
#   GET  /api/client-relations/regf-queue  - Reg F compliance queue (cached)
#
# Version: Tracked in dbo.System_Metadata (component: DeptOps.ClientRelations)
# ============================================================================

# ============================================================================
# REG F COMPLIANCE QUEUE - Cached CRS5 query
# ============================================================================

Add-PodeRoute -Method Get -Path '/api/client-relations/regf-queue' -Authentication 'ADLogin' -ScriptBlock {
    try {
        # Check for manual refresh request
        $forceRefresh = ($WebEvent.Query['refresh'] -eq 'true')
        
        $results = Get-CachedResult -CacheKey 'regf_queue' -ForceRefresh:$forceRefresh -ScriptBlock {
            Invoke-CRS5ReadQuery -Query @"
                ;WITH cte AS
                (
                SELECT
                     CAST(cat.cnsmr_accnt_tag_assgn_dt AS date) AS [RejectDate]
                    ,tt.tag_shrt_nm AS Company
                    ,c.cnsmr_id AS ConsumerID
                    ,c.cnsmr_idntfr_agncy_id AS ConsumerNumber
                    ,c.cnsmr_nm_lst_txt + ', ' + c.cnsmr_nm_frst_txt AS ConsumerName
                    ,ca.new_bsnss_btch_id AS NewBusinessBatch
                    ,ca.cnsmr_accnt_idntfr_agncy_id AS ConsumerAccountNumber
                    ,ca.cnsmr_accnt_crdtr_rfrnc_id_txt AS CreditorReference
                    ,cg.crdtr_grp_shrt_nm AS CreditorGroup
                    ,REPLACE(cg.crdtr_grp_nm, ',', ' ') AS CreditorGroupName
                    ,cr.crdtr_shrt_nm AS Creditor
                    ,REPLACE(cr.crdtr_nm, ',', ' ') AS CreditorName
                    ,crt.tag_shrt_nm AS LetterStrategy
                    ,CAST(ca.cnsmr_accnt_plcmnt_date AS date) AS PlacementDate
                    ,CAST(ca.cnsmr_accnt_rlsd_dt AS date) AS DateReleasedIntoDM
                    ,COALESCE(u.UDEFSERV_BAL_DUE, b.BalAtDOS) AS BalAtDoS
                    ,u.UDEFFEE_AMT AS CalculatedFees
                    ,u.UDEFINT_AMT AS CalculatedInterest
                    ,CAST(cab.cnsmr_accnt_bal_amnt AS money) AS CurrentAccountBalanceInDM
                    ,u.UDEFPAY_AMT AS CalculatedPaymentsMade
                    ,RejectionReason = 
                        CASE 
                            WHEN CAST(u.UDEFSERV_BAL_DUE AS money) = 0
                                THEN 'Zero Dollar Original Charges Received'
                            WHEN u.UDEFSERV_BAL_DUE IS NULL
                                THEN 'No Reg F Data In DM'
                            WHEN CAST(u.UDEFPAY_AMT AS money) < 0
                                THEN 'Unaccounted For Balance Discrepancy'
                            ELSE 'Other Reason'
                        END
                FROM dbo.cnsmr c
                INNER JOIN dbo.wrkgrp w ON w.wrkgrp_id = c.wrkgrp_id
                INNER JOIN dbo.cnsmr_accnt ca ON ca.cnsmr_id = c.cnsmr_id
                INNER JOIN dbo.cnsmr_accnt_bal cab ON cab.cnsmr_accnt_id = ca.cnsmr_accnt_id AND cab.bal_nm_id = 2
                INNER JOIN dbo.crdtr cr ON cr.crdtr_id = ca.crdtr_id
                INNER JOIN (
                    SELECT ct.crdtr_id, t.tag_shrt_nm 
                    FROM dbo.crdtr_tag ct
                    INNER JOIN dbo.tag t ON t.tag_id = ct.tag_id 
                        AND ct.crdtr_tag_sft_delete_flg = 'N' 
                        AND t.tag_typ_id = 170
                ) crt ON crt.crdtr_id = cr.crdtr_id
                INNER JOIN dbo.crdtr_grp cg ON cg.crdtr_grp_id = cr.crdtr_grp_id
                LEFT JOIN dbo.UDEFCREDITORTRANHIST u ON u.cnsmr_accnt_id = ca.cnsmr_accnt_id
                INNER JOIN dbo.cnsmr_accnt_tag cat ON cat.cnsmr_accnt_id = ca.cnsmr_accnt_id 
                    AND cat.cnsmr_accnt_sft_delete_flg = 'N'
                INNER JOIN dbo.tag t ON t.tag_id = cat.tag_id
                INNER JOIN (
                    SELECT ct.cnsmr_id, t.tag_shrt_nm 
                    FROM dbo.cnsmr_tag ct
                    INNER JOIN dbo.tag t ON t.tag_id = ct.tag_id 
                        AND ct.cnsmr_tag_sft_delete_flg = 'N' 
                        AND t.tag_typ_id = 204
                ) tt ON tt.cnsmr_id = c.cnsmr_id
                LEFT JOIN (
                    SELECT DISTINCT cnsmr_accnt_id,
                        LTRIM(RTRIM(LEFT(
                            SUBSTRING(cnsmr_accnt_ar_mssg_txt, 55, 15), 
                            CHARINDEX(',', SUBSTRING(cnsmr_accnt_ar_mssg_txt, 55, 15) + ',') - 1
                        ))) AS BalAtDOS
                    FROM dbo.cnsmr_accnt_ar_log
                    WHERE rslt_cd = 906
                    AND NOT EXISTS (
                        SELECT 1 FROM dbo.UDEFCREDITORTRANHIST uch 
                        WHERE uch.cnsmr_accnt_id = cnsmr_accnt_ar_log.cnsmr_accnt_id
                    )
                ) b ON ca.cnsmr_accnt_id = b.cnsmr_accnt_id
                WHERE w.wrkgrp_shrt_nm = 'WFACRFNC'
                AND t.tag_shrt_nm = 'TA_RFNC'
                )
                SELECT DISTINCT
                     ltr.dcmnt_tmplt_shrt_nm AS Letter
                    ,CASE
                        WHEN ltr.dcmnt_rqst_dt IS NOT NULL
                            THEN CAST(ltr.dcmnt_rqst_dt AS date)
                        ELSE CAST(a.RejectDate AS date)
                     END AS QueueDate
                    ,CASE
                        WHEN ltr.dcmnt_rqst_dt IS NOT NULL
                            THEN 'Letter Requested'
                        ELSE 'Other Reason'
                     END AS QueueReason
                    ,a.ConsumerNumber
                    ,a.ConsumerName
                    ,a.Company
                    ,a.NewBusinessBatch
                    ,a.ConsumerAccountNumber
                    ,a.CreditorReference
                    ,a.CreditorGroup
                    ,a.CreditorGroupName
                    ,a.Creditor
                    ,a.CreditorName
                    ,a.LetterStrategy
                    ,a.PlacementDate
                    ,a.DateReleasedIntoDM
                    ,a.BalAtDoS
                    ,a.CalculatedFees
                    ,a.CalculatedInterest
                    ,a.CurrentAccountBalanceInDM
                    ,a.CalculatedPaymentsMade
                    ,a.RejectionReason
                FROM cte a
                OUTER APPLY (
                    SELECT TOP 1
                        dr.dcmnt_rqst_dt,
                        dt.dcmnt_tmplt_shrt_nm
                    FROM dbo.dcmnt_rqst dr
                    INNER JOIN dbo.dcmnt_tmplt_vrsn dtv ON dtv.dcmnt_tmplt_vrsn_id = dr.dcmnt_tmplt_vrsn_id
                    INNER JOIN dbo.dcmnt_tmplt dt ON dt.dcmnt_tmplt_id = dtv.dcmnt_tmplt_id
                    INNER JOIN dbo.dcmnt_grp dg ON dg.dcmnt_grp_id = dt.dcmnt_grp_id
                    WHERE dg.dcmnt_grp_shrt_nm = 'DGBVAL'
                      AND dr.dcmnt_rqst_send_to_entty_id = a.ConsumerID
                    ORDER BY dr.dcmnt_rqst_id DESC
                ) ltr
                ORDER BY QueueDate ASC
"@
        }
        
        # Build response - return flat rows, JS handles consumer grouping
        $rows = @()
        foreach ($row in $results) {
            $rows += @{
                letter               = if ($row.Letter -is [DBNull]) { $null } else { $row.Letter }
                queue_date           = if ($row.QueueDate -is [DBNull]) { $null } else { ([DateTime]$row.QueueDate).ToString("M/d/yyyy") }
                queue_reason         = if ($row.QueueReason -is [DBNull]) { $null } else { $row.QueueReason }
                consumer_number      = if ($row.ConsumerNumber -is [DBNull]) { $null } else { $row.ConsumerNumber }
                consumer_name        = if ($row.ConsumerName -is [DBNull]) { $null } else { $row.ConsumerName }
                company              = if ($row.Company -is [DBNull]) { $null } else { $row.Company }
                new_business_batch   = if ($row.NewBusinessBatch -is [DBNull]) { $null } else { $row.NewBusinessBatch }
                consumer_account_number = if ($row.ConsumerAccountNumber -is [DBNull]) { $null } else { $row.ConsumerAccountNumber }
                creditor_reference   = if ($row.CreditorReference -is [DBNull]) { $null } else { $row.CreditorReference }
                creditor_group       = if ($row.CreditorGroup -is [DBNull]) { $null } else { $row.CreditorGroup }
                creditor_group_name  = if ($row.CreditorGroupName -is [DBNull]) { $null } else { $row.CreditorGroupName }
                creditor             = if ($row.Creditor -is [DBNull]) { $null } else { $row.Creditor }
                creditor_name        = if ($row.CreditorName -is [DBNull]) { $null } else { $row.CreditorName }
                letter_strategy      = if ($row.LetterStrategy -is [DBNull]) { $null } else { $row.LetterStrategy }
                placement_date       = if ($row.PlacementDate -is [DBNull]) { $null } else { ([DateTime]$row.PlacementDate).ToString("M/d/yyyy") }
                date_released        = if ($row.DateReleasedIntoDM -is [DBNull]) { $null } else { ([DateTime]$row.DateReleasedIntoDM).ToString("M/d/yyyy") }
                bal_at_dos           = if ($row.BalAtDoS -is [DBNull]) { $null } else { $row.BalAtDoS }
                calculated_fees      = if ($row.CalculatedFees -is [DBNull]) { $null } else { $row.CalculatedFees }
                calculated_interest  = if ($row.CalculatedInterest -is [DBNull]) { $null } else { $row.CalculatedInterest }
                current_balance      = if ($row.CurrentAccountBalanceInDM -is [DBNull]) { $null } else { $row.CurrentAccountBalanceInDM }
                calculated_payments  = if ($row.CalculatedPaymentsMade -is [DBNull]) { $null } else { $row.CalculatedPaymentsMade }
                rejection_reason     = if ($row.RejectionReason -is [DBNull]) { $null } else { $row.RejectionReason }
            }
        }
        
        Write-PodeJsonResponse -Value @{
            rows      = $rows
            count     = $rows.Count
            timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}
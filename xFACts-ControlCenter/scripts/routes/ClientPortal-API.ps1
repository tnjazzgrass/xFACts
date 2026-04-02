# ============================================================================
# xFACts Control Center - Client Portal API Routes
# Location: E:\xFACts-ControlCenter\scripts\routes\ClientPortal-API.ps1
# 
# API endpoints for the Client Portal consumer/account lookup tool.
# All queries are read-only against crs5_oltp via the AG secondary replica.
# No xFACts database tables are used — this is a pure passthrough to DM data.
#
# Cross-database references:
#   DBA.dbo.fn_Clients(@filter) - TVF returning crdtr_id, crdtr_shrt_nm
#                                  for any creditor or group short name
#   DBA.dbo.fn_GetSSN(@cnsmr_id) - Scalar function returning decrypted SSN
#
# Dependencies (from xFACts-Helpers.psm1):
#   Invoke-CRS5ReadQuery, Get-CachedResult, Invoke-XFActsQuery,
#   ConvertTo-SafeValue, ConvertTo-SafeDate, ConvertTo-SafeDateTime,
#   ConvertTo-SafeDecimal
#
# Endpoints:
#   GET  /api/client-portal/lookups                 - All lookup tables (cached)
#   GET  /api/client-portal/creditors               - Creditor lookup via fn_Clients
#   GET  /api/client-portal/search                  - Consumer search (with optional creditor filter)
#   GET  /api/client-portal/consumer/:id            - Consumer header (with decrypted SSN)
#   GET  /api/client-portal/consumer/:id/accounts   - Account list with financials
#   GET  /api/client-portal/consumer/:id/addresses  - Consumer addresses
#   GET  /api/client-portal/consumer/:id/phones     - Consumer phones (non-deleted)
#   GET  /api/client-portal/consumer/:id/events     - Consumer-level AR log
#   GET  /api/client-portal/consumer/:id/documents  - Consumer-level outreach
#   GET  /api/client-portal/account/:id             - Account detail with financials
#   GET  /api/client-portal/account/:id/transactions - Account transactions (reportable)
#   GET  /api/client-portal/account/:id/events      - Account-level AR log
#   GET  /api/client-portal/account/:id/documents   - Account-level outreach
#
# Version: Tracked in dbo.System_Metadata (component: Tools.Operations)
# ============================================================================

# ============================================================================
# LOOKUPS - All reference/lookup tables, cached with long TTL
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/client-portal/lookups' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $forceRefresh = ($WebEvent.Query['refresh'] -eq 'true')

        $results = Get-CachedResult -CacheKey 'portal_lookups' -ForceRefresh:$forceRefresh -ScriptBlock {

            # Get timeout from GlobalConfig (inline — cannot use file-level functions in Pode runspaces)
            $timeout = 60
            try {
                $tCfg = Invoke-XFActsQuery -Query "SELECT setting_value FROM dbo.GlobalConfig WHERE module_name = 'Tools' AND category = 'Portal' AND setting_name = 'crs5_portal_query_timeout_seconds' AND is_active = 1"
                if ($tCfg -and $tCfg.Count -gt 0 -and $tCfg[0].setting_value) { $timeout = [int]$tCfg[0].setting_value }
            } catch { }

            $actions = Invoke-CRS5ReadQuery -TimeoutSeconds $timeout -Query "SELECT actn_cd, actn_cd_shrt_val_txt FROM dbo.actn_cd"
            $results_lookup = Invoke-CRS5ReadQuery -TimeoutSeconds $timeout -Query "SELECT rslt_cd, rslt_cd_shrt_val_txt FROM dbo.rslt_cd"
            $addressStatuses = Invoke-CRS5ReadQuery -TimeoutSeconds $timeout -Query "SELECT addrss_stts_cd, addrss_stts_val_txt FROM dbo.ref_addrss_stts_cd"
            $buckets = Invoke-CRS5ReadQuery -TimeoutSeconds $timeout -Query "SELECT bckt_id, bckt_nm FROM dbo.bckt"
            $txnTypes = Invoke-CRS5ReadQuery -TimeoutSeconds $timeout -Query "SELECT bckt_trnsctn_typ_cd, bckt_trnsctn_val_txt FROM dbo.ref_bckt_trnsctn_typ_cd"
            $balanceNames = Invoke-CRS5ReadQuery -TimeoutSeconds $timeout -Query "SELECT bal_nm_id, bal_nm FROM dbo.bal_nm"
            $users = Invoke-CRS5ReadQuery -TimeoutSeconds $timeout -Query "SELECT usr_id, usr_usrnm FROM dbo.usr"
            $phoneStatuses = Invoke-CRS5ReadQuery -TimeoutSeconds $timeout -Query "SELECT phn_stts_cd, phn_stts_val_txt FROM dbo.ref_phn_stts_cd"
            $phoneTypes = Invoke-CRS5ReadQuery -TimeoutSeconds $timeout -Query "SELECT phn_typ_cd, phn_typ_val_txt FROM dbo.ref_phn_typ_cd"
            $paymentLocations = Invoke-CRS5ReadQuery -TimeoutSeconds $timeout -Query "SELECT pymnt_lctn_cd, pymnt_lctn_val_txt FROM dbo.ref_pymnt_lctn_cd"
            $tags = Invoke-CRS5ReadQuery -TimeoutSeconds $timeout -Query "SELECT tag_id, tag_typ_id, tag_shrt_nm, tag_nm FROM dbo.tag WHERE tag_typ_id IN (113, 115)"
            $portalEvents = Invoke-CRS5ReadQuery -TimeoutSeconds $timeout -Query "SELECT rslt_cd FROM dbo.rslt_cd_class_assctn WHERE rslt_cd_class_id = 41"

            return @{
                actions            = $actions
                results            = $results_lookup
                address_statuses   = $addressStatuses
                buckets            = $buckets
                txn_types          = $txnTypes
                balance_names      = $balanceNames
                users              = $users
                phone_statuses     = $phoneStatuses
                phone_types        = $phoneTypes
                payment_locations  = $paymentLocations
                tags               = $tags
                portal_event_codes = $portalEvents
            }
        }

        Write-PodeJsonResponse -Value @{
            data      = $results
            timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# CREDITOR LOOKUP - Resolve client/group short name via fn_Clients
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/client-portal/creditors' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $filter = $WebEvent.Query['filter']

        if (-not $filter) {
            Write-PodeJsonResponse -Value @{ error = "Missing required parameter: filter" } -StatusCode 400
            return
        }

        $timeout = 60
        try {
            $tCfg = Invoke-XFActsQuery -Query "SELECT setting_value FROM dbo.GlobalConfig WHERE module_name = 'Tools' AND category = 'Portal' AND setting_name = 'crs5_portal_query_timeout_seconds' AND is_active = 1"
            if ($tCfg -and $tCfg.Count -gt 0 -and $tCfg[0].setting_value) { $timeout = [int]$tCfg[0].setting_value }
        } catch { }

        $results = Invoke-CRS5ReadQuery -TimeoutSeconds $timeout -Query @"
            SELECT crdtr_id, crdtr_shrt_nm
            FROM DBA.dbo.fn_Clients(@filter)
            ORDER BY crdtr_shrt_nm
"@ -Parameters @{ filter = $filter }

        $creditors = @()
        foreach ($r in $results) {
            $creditors += @{
                crdtr_id      = ConvertTo-SafeValue $r.crdtr_id
                crdtr_shrt_nm = ConvertTo-SafeValue $r.crdtr_shrt_nm
            }
        }

        Write-PodeJsonResponse -Value @{
            creditors = $creditors
            count     = $creditors.Count
            filter    = $filter
        }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# SEARCH - Single-query approach: search + enrichment in one round trip
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/client-portal/search' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $searchType = $WebEvent.Query['type']
        $searchTerm = $WebEvent.Query['term']
        $clientFilter = $WebEvent.Query['client']

        $timeout = 60
        try {
            $tCfg = Invoke-XFActsQuery -Query "SELECT setting_value FROM dbo.GlobalConfig WHERE module_name = 'Tools' AND category = 'Portal' AND setting_name = 'crs5_portal_query_timeout_seconds' AND is_active = 1"
            if ($tCfg -and $tCfg.Count -gt 0 -and $tCfg[0].setting_value) { $timeout = [int]$tCfg[0].setting_value }
        } catch { }

        if (-not $searchType -or -not $searchTerm) {
            Write-PodeJsonResponse -Value @{ error = "Missing required parameters: type and term" } -StatusCode 400
            return
        }

        # Validate search type
        $validTypes = @(
            'cnsmr_accnt_crdtr_rfrnc_id_txt',
            'cnsmr_phn_nmbr_txt',
            'cnsmr_idntfr_hshd_ssn_txt',
            'cnsmr_nm_lst_txt',
            'cnsmr_idntfr_agncy_id',
            'cnsmr_accnt_idntfr_agncy_id'
        )
        if ($searchType -notin $validTypes) {
            Write-PodeJsonResponse -Value @{ error = "Invalid search type" } -StatusCode 400
            return
        }

        # Convert wildcard patterns: * -> %, M* -> M%
        $sqlTerm = $searchTerm.Replace('*', '%')
        $useWildcard = $sqlTerm.Contains('%')

        # Build creditor filter components
        $hasClientFilter = (-not [string]::IsNullOrWhiteSpace($clientFilter))
        $ctePrefix = ""
        $cfJoin = ""
        $cfWhereCA2 = ""
        $cfWhereCA3 = ""
        if ($hasClientFilter) {
            $ctePrefix = ";WITH _crdtr_filter AS (SELECT crdtr_id FROM DBA.dbo.fn_Clients(@clientFilter))"
            $cfJoin = "INNER JOIN _crdtr_filter cf ON cf.crdtr_id = ca.crdtr_id"
            $cfWhereCA2 = "AND ca2.crdtr_id IN (SELECT crdtr_id FROM DBA.dbo.fn_Clients(@clientFilter))"
            $cfWhereCA3 = "AND ca3.crdtr_id IN (SELECT crdtr_id FROM DBA.dbo.fn_Clients(@clientFilter))"
        }

        # Enrichment OUTER APPLYs — appended to every search query
        # These run correlated to each matched consumer, all in a single query
        $enrichmentApplies = @"
            OUTER APPLY (
                SELECT COUNT(*) AS account_count,
                       COUNT(DISTINCT ca2.crdtr_id) AS creditor_count,
                       MIN(cr2.crdtr_shrt_nm) AS first_creditor
                FROM dbo.cnsmr_accnt ca2
                INNER JOIN dbo.crdtr cr2 ON cr2.crdtr_id = ca2.crdtr_id
                WHERE ca2.cnsmr_id = c.cnsmr_id $cfWhereCA2
            ) acct_summary
            OUTER APPLY (
                SELECT ISNULL(SUM(CASE WHEN ca3.cnsmr_accnt_is_rtrnd_flg = 'Y' THEN 0
                     ELSE ISNULL(cab.cnsmr_accnt_bal_amnt, 0) END), 0) AS total_balance
                FROM dbo.cnsmr_accnt ca3
                LEFT JOIN dbo.cnsmr_accnt_bal cab ON cab.cnsmr_accnt_id = ca3.cnsmr_accnt_id AND cab.bal_nm_id = 7
                WHERE ca3.cnsmr_id = c.cnsmr_id $cfWhereCA3
            ) bal_summary
            OUTER APPLY (
                SELECT TOP 1 t.tag_id, t.tag_shrt_nm, t.tag_nm
                FROM dbo.cnsmr_tag ct
                INNER JOIN dbo.tag t ON t.tag_id = ct.tag_id AND t.tag_typ_id = 115
                WHERE ct.cnsmr_id = c.cnsmr_id AND ct.cnsmr_tag_sft_delete_flg = 'N'
            ) cnsmr_tag
"@

        $enrichmentColumns = ", acct_summary.account_count, acct_summary.creditor_count, acct_summary.first_creditor, bal_summary.total_balance, cnsmr_tag.tag_id, cnsmr_tag.tag_shrt_nm, cnsmr_tag.tag_nm"
        $enrichmentGroupBy = ", acct_summary.account_count, acct_summary.creditor_count, acct_summary.first_creditor, bal_summary.total_balance, cnsmr_tag.tag_id, cnsmr_tag.tag_shrt_nm, cnsmr_tag.tag_nm"

        $query = $null
        $leanQuery = $null
        $params = @{}
        if ($hasClientFilter) { $params['clientFilter'] = $clientFilter }

        # Search types that join through large tables use the two-step path:
        # Step 1: lean search (no enrichment) to get distinct cnsmr_ids
        # Step 2: single enrichment query against the narrowed ID set
        #
        # Search types that hit small result sets directly use the single-query path
        # with inline OUTER APPLYs (enrichment runs against few rows, fast).

        switch ($searchType) {
            'cnsmr_accnt_crdtr_rfrnc_id_txt' {
                # TWO-STEP: Client Account Number — varchar column, can match many account rows
                $whereClause = if ($useWildcard) { "ca.cnsmr_accnt_crdtr_rfrnc_id_txt LIKE @term" } else { "ca.cnsmr_accnt_crdtr_rfrnc_id_txt = @term" }
                $leanQuery = @"
                    $ctePrefix
                    SELECT TOP 100
                        c.cnsmr_id, c.cnsmr_idntfr_agncy_id, c.cnsmr_nm_lst_txt, c.cnsmr_nm_frst_txt
                    FROM dbo.cnsmr c
                    INNER JOIN dbo.cnsmr_accnt ca ON ca.cnsmr_id = c.cnsmr_id
                    $(if ($hasClientFilter) { $cfJoin })
                    WHERE $whereClause
                    GROUP BY c.cnsmr_id, c.cnsmr_idntfr_agncy_id, c.cnsmr_nm_lst_txt, c.cnsmr_nm_frst_txt
                    ORDER BY c.cnsmr_nm_lst_txt, c.cnsmr_nm_frst_txt
"@
                $params['term'] = $sqlTerm
            }
            'cnsmr_phn_nmbr_txt' {
                # TWO-STEP: Phone Number — joins through cnsmr_phn
                $phoneTerm = ($sqlTerm -replace '[^0-9%]', '')
                $whereClause = if ($useWildcard) { "cp.cnsmr_phn_nmbr_txt LIKE @term" } else { "cp.cnsmr_phn_nmbr_txt = @term" }
                if ($hasClientFilter) {
                    $leanQuery = @"
                        $ctePrefix
                        SELECT TOP 100
                            c.cnsmr_id, c.cnsmr_idntfr_agncy_id, c.cnsmr_nm_lst_txt, c.cnsmr_nm_frst_txt
                        FROM dbo.cnsmr c
                        INNER JOIN dbo.cnsmr_phn cp ON cp.cnsmr_id = c.cnsmr_id AND cp.cnsmr_phn_sft_dlt_flg = 'N'
                        INNER JOIN dbo.cnsmr_accnt ca ON ca.cnsmr_id = c.cnsmr_id
                        $cfJoin
                        WHERE $whereClause
                        GROUP BY c.cnsmr_id, c.cnsmr_idntfr_agncy_id, c.cnsmr_nm_lst_txt, c.cnsmr_nm_frst_txt
                        ORDER BY c.cnsmr_nm_lst_txt, c.cnsmr_nm_frst_txt
"@
                } else {
                    $leanQuery = @"
                        SELECT TOP 100
                            c.cnsmr_id, c.cnsmr_idntfr_agncy_id, c.cnsmr_nm_lst_txt, c.cnsmr_nm_frst_txt
                        FROM dbo.cnsmr c
                        INNER JOIN dbo.cnsmr_phn cp ON cp.cnsmr_id = c.cnsmr_id AND cp.cnsmr_phn_sft_dlt_flg = 'N'
                        WHERE $whereClause
                        GROUP BY c.cnsmr_id, c.cnsmr_idntfr_agncy_id, c.cnsmr_nm_lst_txt, c.cnsmr_nm_frst_txt
                        ORDER BY c.cnsmr_nm_lst_txt, c.cnsmr_nm_frst_txt
"@
                }
                $params['term'] = $phoneTerm
            }
            'cnsmr_idntfr_hshd_ssn_txt' {
                # SSN search: hash the input with SHA1 + salt, compare against cnsmr_idntfr_hshd_ssn_txt
                # Credentials retrieved from dbo.Credentials (DM_Encryption service)
                $ssnTerm = ($searchTerm -replace '[^0-9]', '')
                if ($ssnTerm.Length -lt 4) {
                    Write-PodeJsonResponse -Value @{ 
                        error = "Please enter at least 4 digits for SSN search."
                        consumers = @(); count = 0
                    } -StatusCode 200
                    return
                }

                try {
                    $dmCreds = Get-ServiceCredentials -ServiceName 'DM_Encryption'
                    $hashSalt = $dmCreds['DMPassphrase']
                } catch {
                    Write-PodeJsonResponse -Value @{ 
                        error = "SSN search is unavailable — encryption credentials could not be retrieved."
                        consumers = @(); count = 0
                    } -StatusCode 200
                    return
                }

                $params['term'] = $ssnTerm
                $params['hashSalt'] = $hashSalt

                $ssnWhereClause = "c.cnsmr_idntfr_hshd_ssn_txt = LOWER(CONVERT(VARCHAR(128), HASHBYTES('SHA1', REVERSE(@term) + @hashSalt), 2))"

                if ($hasClientFilter) {
                    $leanQuery = @"
                        $ctePrefix
                        SELECT TOP 100
                            c.cnsmr_id, c.cnsmr_idntfr_agncy_id, c.cnsmr_nm_lst_txt, c.cnsmr_nm_frst_txt
                        FROM dbo.cnsmr c
                        INNER JOIN dbo.cnsmr_accnt ca ON ca.cnsmr_id = c.cnsmr_id
                        $cfJoin
                        WHERE $ssnWhereClause
                        GROUP BY c.cnsmr_id, c.cnsmr_idntfr_agncy_id, c.cnsmr_nm_lst_txt, c.cnsmr_nm_frst_txt
                        ORDER BY c.cnsmr_nm_lst_txt, c.cnsmr_nm_frst_txt
"@
                } else {
                    $leanQuery = @"
                        SELECT TOP 100
                            c.cnsmr_id, c.cnsmr_idntfr_agncy_id, c.cnsmr_nm_lst_txt, c.cnsmr_nm_frst_txt
                        FROM dbo.cnsmr c
                        WHERE $ssnWhereClause
                        ORDER BY c.cnsmr_nm_lst_txt, c.cnsmr_nm_frst_txt
"@
                }
            }
            'cnsmr_nm_lst_txt' {
                # TWO-STEP: Name search — can return many consumers
                $lastTerm = $sqlTerm
                $firstTerm = $null
                if ($sqlTerm -match '^\s*(.+?)\s*,\s*(.+?)\s*$') {
                    $lastTerm = $Matches[1].Replace('*', '%')
                    $firstTerm = $Matches[2].Replace('*', '%')
                }
                $lastWhere = if ($lastTerm.Contains('%')) { "c.cnsmr_nm_lst_txt LIKE @termLast" } else { "c.cnsmr_nm_lst_txt = @termLast" }
                $firstWhere = ""
                if ($firstTerm) {
                    $firstWhere = "AND c.cnsmr_nm_frst_txt LIKE @termFirst"
                    if (-not $firstTerm.Contains('%')) { $firstWhere = "AND c.cnsmr_nm_frst_txt = @termFirst" }
                    $params['termFirst'] = $firstTerm
                }
                $params['termLast'] = $lastTerm

                if ($hasClientFilter) {
                    $leanQuery = @"
                        $ctePrefix
                        SELECT TOP 100
                            c.cnsmr_id, c.cnsmr_idntfr_agncy_id, c.cnsmr_nm_lst_txt, c.cnsmr_nm_frst_txt
                        FROM dbo.cnsmr c
                        INNER JOIN dbo.cnsmr_accnt ca ON ca.cnsmr_id = c.cnsmr_id
                        $cfJoin
                        WHERE $lastWhere $firstWhere
                        GROUP BY c.cnsmr_id, c.cnsmr_idntfr_agncy_id, c.cnsmr_nm_lst_txt, c.cnsmr_nm_frst_txt
                        ORDER BY c.cnsmr_nm_lst_txt, c.cnsmr_nm_frst_txt
"@
                } else {
                    $leanQuery = @"
                        SELECT TOP 100
                            c.cnsmr_id, c.cnsmr_idntfr_agncy_id, c.cnsmr_nm_lst_txt, c.cnsmr_nm_frst_txt
                        FROM dbo.cnsmr c
                        WHERE $lastWhere $firstWhere
                        ORDER BY c.cnsmr_nm_lst_txt, c.cnsmr_nm_frst_txt
"@
                }
            }
            'cnsmr_idntfr_agncy_id' {
                # SINGLE-QUERY: FA Consumer Number — direct cnsmr lookup, fast
                if ($useWildcard) {
                    $query = @"
                        SELECT TOP 100
                            c.cnsmr_id, c.cnsmr_idntfr_agncy_id, c.cnsmr_nm_lst_txt, c.cnsmr_nm_frst_txt
                            $enrichmentColumns
                        FROM dbo.cnsmr c
                        $enrichmentApplies
                        WHERE CAST(c.cnsmr_idntfr_agncy_id AS VARCHAR(20)) LIKE @term
                        ORDER BY c.cnsmr_nm_lst_txt, c.cnsmr_nm_frst_txt
"@
                    $params['term'] = $sqlTerm
                } else {
                    $query = @"
                        SELECT TOP 100
                            c.cnsmr_id, c.cnsmr_idntfr_agncy_id, c.cnsmr_nm_lst_txt, c.cnsmr_nm_frst_txt
                            $enrichmentColumns
                        FROM dbo.cnsmr c
                        $enrichmentApplies
                        WHERE c.cnsmr_idntfr_agncy_id = @termInt
                        ORDER BY c.cnsmr_nm_lst_txt, c.cnsmr_nm_frst_txt
"@
                    $params['termInt'] = [int]$searchTerm
                }
            }
            'cnsmr_accnt_idntfr_agncy_id' {
                # SINGLE-QUERY: FA Account Number — integer column, small result set
                if ($useWildcard) {
                    $leanQuery = @"
                        $ctePrefix
                        SELECT TOP 100
                            c.cnsmr_id, c.cnsmr_idntfr_agncy_id, c.cnsmr_nm_lst_txt, c.cnsmr_nm_frst_txt
                        FROM dbo.cnsmr c
                        INNER JOIN dbo.cnsmr_accnt ca ON ca.cnsmr_id = c.cnsmr_id
                        $(if ($hasClientFilter) { $cfJoin })
                        WHERE CAST(ca.cnsmr_accnt_idntfr_agncy_id AS VARCHAR(20)) LIKE @term
                        GROUP BY c.cnsmr_id, c.cnsmr_idntfr_agncy_id, c.cnsmr_nm_lst_txt, c.cnsmr_nm_frst_txt
                        ORDER BY c.cnsmr_nm_lst_txt, c.cnsmr_nm_frst_txt
"@
                    $params['term'] = $sqlTerm
                } else {
                    $query = @"
                        $ctePrefix
                        SELECT TOP 100
                            c.cnsmr_id, c.cnsmr_idntfr_agncy_id, c.cnsmr_nm_lst_txt, c.cnsmr_nm_frst_txt
                            $enrichmentColumns
                        FROM dbo.cnsmr c
                        INNER JOIN dbo.cnsmr_accnt ca ON ca.cnsmr_id = c.cnsmr_id
                        $(if ($hasClientFilter) { $cfJoin })
                        $enrichmentApplies
                        WHERE ca.cnsmr_accnt_idntfr_agncy_id = @termInt
                        GROUP BY c.cnsmr_id, c.cnsmr_idntfr_agncy_id, c.cnsmr_nm_lst_txt, c.cnsmr_nm_frst_txt
                            $enrichmentGroupBy
                        ORDER BY c.cnsmr_nm_lst_txt, c.cnsmr_nm_frst_txt
"@
                    $params['termInt'] = [int]$searchTerm
                }
            }
        }

        $consumers = @()

        if ($leanQuery) {
            # ---- TWO-STEP PATH ----
            # Step 1: Lean search — get distinct consumer IDs only
            $searchResults = Invoke-CRS5ReadQuery -Query $leanQuery -Parameters $params -TimeoutSeconds $timeout

            if ($searchResults -and $searchResults.Count -gt 0) {
                # Step 2: Single enrichment query against the narrowed ID set
                $idList = ($searchResults | ForEach-Object { [int]$_.cnsmr_id }) -join ','

                $enrichQuery = @"
                    SELECT c.cnsmr_id, c.cnsmr_idntfr_agncy_id, c.cnsmr_nm_lst_txt, c.cnsmr_nm_frst_txt
                        $enrichmentColumns
                    FROM dbo.cnsmr c
                    $enrichmentApplies
                    WHERE c.cnsmr_id IN ($idList)
                    ORDER BY c.cnsmr_nm_lst_txt, c.cnsmr_nm_frst_txt
"@
                # Enrichment query uses no extra parameters (IDs are inline integers)
                # But if client filter is active, fn_Clients is referenced in OUTER APPLYs
                $enrichParams = @{}
                if ($hasClientFilter) { $enrichParams['clientFilter'] = $clientFilter }

                $enrichedResults = Invoke-CRS5ReadQuery -Query $enrichQuery -Parameters $enrichParams -TimeoutSeconds $timeout

                foreach ($row in $enrichedResults) {
                    $statusTag = $null
                    if ($row.tag_id -and $row.tag_id -isnot [DBNull]) {
                        $statusTag = @{
                            tag_id = ConvertTo-SafeValue $row.tag_id; short_nm = ConvertTo-SafeValue $row.tag_shrt_nm
                            name = ConvertTo-SafeValue $row.tag_nm
                        }
                    }
                    $consumers += @{
                        cnsmr_id = $row.cnsmr_id; cnsmr_idntfr_agncy_id = ConvertTo-SafeValue $row.cnsmr_idntfr_agncy_id
                        cnsmr_nm_lst_txt = ConvertTo-SafeValue $row.cnsmr_nm_lst_txt; cnsmr_nm_frst_txt = ConvertTo-SafeValue $row.cnsmr_nm_frst_txt
                        account_count = if ($row.account_count -isnot [DBNull]) { $row.account_count } else { 0 }
                        total_balance = ConvertTo-SafeDecimal $row.total_balance
                        first_creditor = ConvertTo-SafeValue $row.first_creditor
                        creditor_count = if ($row.creditor_count -isnot [DBNull]) { $row.creditor_count } else { 0 }
                        status_tag = $statusTag
                    }
                }
            }
        }
        elseif ($query) {
            # ---- SINGLE-QUERY PATH ----
            $searchResults = Invoke-CRS5ReadQuery -Query $query -Parameters $params -TimeoutSeconds $timeout

            foreach ($row in $searchResults) {
                $statusTag = $null
                if ($row.tag_id -and $row.tag_id -isnot [DBNull]) {
                    $statusTag = @{
                        tag_id = ConvertTo-SafeValue $row.tag_id; short_nm = ConvertTo-SafeValue $row.tag_shrt_nm
                        name = ConvertTo-SafeValue $row.tag_nm
                    }
                }
                $consumers += @{
                    cnsmr_id = $row.cnsmr_id; cnsmr_idntfr_agncy_id = ConvertTo-SafeValue $row.cnsmr_idntfr_agncy_id
                    cnsmr_nm_lst_txt = ConvertTo-SafeValue $row.cnsmr_nm_lst_txt; cnsmr_nm_frst_txt = ConvertTo-SafeValue $row.cnsmr_nm_frst_txt
                    account_count = if ($row.account_count -isnot [DBNull]) { $row.account_count } else { 0 }
                    total_balance = ConvertTo-SafeDecimal $row.total_balance
                    first_creditor = ConvertTo-SafeValue $row.first_creditor
                    creditor_count = if ($row.creditor_count -isnot [DBNull]) { $row.creditor_count } else { 0 }
                    status_tag = $statusTag
                }
            }
        }

        Write-PodeJsonResponse -Value @{
            consumers = $consumers; count = $consumers.Count
            capped = ($searchResults.Count -ge 100)
            client_filter = $(if ($hasClientFilter) { $clientFilter } else { $null })
            timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# CONSUMER HEADER - Demographics, status tag, and decrypted SSN
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/client-portal/consumer/:id' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $cnsmrId = $WebEvent.Parameters['id']
        $timeout = 60
        try {
            $tCfg = Invoke-XFActsQuery -Query "SELECT setting_value FROM dbo.GlobalConfig WHERE module_name = 'Tools' AND category = 'Portal' AND setting_name = 'crs5_portal_query_timeout_seconds' AND is_active = 1"
            if ($tCfg -and $tCfg.Count -gt 0 -and $tCfg[0].setting_value) { $timeout = [int]$tCfg[0].setting_value }
        } catch { }

        $result = Invoke-CRS5ReadQuery -TimeoutSeconds $timeout -Query @"
            SELECT c.cnsmr_id, c.cnsmr_idntfr_agncy_id, c.cnsmr_nm_lst_txt, c.cnsmr_nm_frst_txt,
                   c.cnsmr_brth_dt, c.cnsmr_email_txt, DBA.dbo.fn_GetSSN(c.cnsmr_id) AS cnsmr_ssn_decrypted
            FROM dbo.cnsmr c WHERE c.cnsmr_id = @cnsmrId
"@ -Parameters @{ cnsmrId = [int]$cnsmrId }

        if (-not $result -or $result.Count -eq 0) {
            Write-PodeJsonResponse -Value @{ error = "Consumer not found" } -StatusCode 404
            return
        }
        $r = $result[0]

        $tagResult = Invoke-CRS5ReadQuery -TimeoutSeconds $timeout -Query @"
            SELECT t.tag_id, t.tag_shrt_nm, t.tag_nm
            FROM dbo.cnsmr_tag ct INNER JOIN dbo.tag t ON t.tag_id = ct.tag_id
            WHERE ct.cnsmr_id = @cnsmrId AND ct.cnsmr_tag_sft_delete_flg = 'N' AND t.tag_typ_id = 115
"@ -Parameters @{ cnsmrId = [int]$cnsmrId }

        $statusTag = $null
        if ($tagResult -and $tagResult.Count -gt 0) {
            $statusTag = @{
                tag_id = ConvertTo-SafeValue $tagResult[0].tag_id; short_nm = ConvertTo-SafeValue $tagResult[0].tag_shrt_nm
                name = ConvertTo-SafeValue $tagResult[0].tag_nm
            }
        }

        $fullSsn = ConvertTo-SafeValue $r.cnsmr_ssn_decrypted
        $maskedSsn = $null
        if ($fullSsn -and $fullSsn.Length -ge 4) {
            $lastFour = $fullSsn.Substring($fullSsn.Length - 4)
            $maskedSsn = "***-**-$lastFour"
        }

        Write-PodeJsonResponse -Value @{
            consumer = @{
                cnsmr_id = ConvertTo-SafeValue $r.cnsmr_id; cnsmr_idntfr_agncy_id = ConvertTo-SafeValue $r.cnsmr_idntfr_agncy_id
                cnsmr_nm_lst_txt = ConvertTo-SafeValue $r.cnsmr_nm_lst_txt; cnsmr_nm_frst_txt = ConvertTo-SafeValue $r.cnsmr_nm_frst_txt
                cnsmr_brth_dt = ConvertTo-SafeDate $r.cnsmr_brth_dt; cnsmr_email_txt = ConvertTo-SafeValue $r.cnsmr_email_txt
                cnsmr_ssn_masked = $maskedSsn; cnsmr_ssn_full = $fullSsn; status_tag = $statusTag
            }
        }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# CONSUMER ACCOUNTS - Account list with pre-computed financials
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/client-portal/consumer/:id/accounts' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $cnsmrId = $WebEvent.Parameters['id']
        $timeout = 60
        try {
            $tCfg = Invoke-XFActsQuery -Query "SELECT setting_value FROM dbo.GlobalConfig WHERE module_name = 'Tools' AND category = 'Portal' AND setting_name = 'crs5_portal_query_timeout_seconds' AND is_active = 1"
            if ($tCfg -and $tCfg.Count -gt 0 -and $tCfg[0].setting_value) { $timeout = [int]$tCfg[0].setting_value }
        } catch { }

        $accounts = Invoke-CRS5ReadQuery -TimeoutSeconds $timeout -Query @"
            SELECT ca.cnsmr_accnt_id, ca.cnsmr_id, ca.crdtr_id, ca.cnsmr_accnt_idntfr_agncy_id,
                ca.cnsmr_accnt_crdtr_rfrnc_id_txt, ca.cnsmr_accnt_crdtr_rfrnc_corltn_id_txt,
                ca.cnsmr_accnt_dscrptn_txt, ca.cnsmr_accnt_plcmnt_date, ca.cnsmr_accnt_crdtr_lst_srvc_dt,
                ca.cnsmr_accnt_is_actv_per_crdtr_flg, ca.cnsmr_accnt_pif_flg, ca.cnsmr_accnt_sif_flg,
                ca.cnsmr_accnt_is_rtrnd_flg, ca.cnsmr_accnt_incld_in_cnsmr_bal_flg,
                cr.crdtr_shrt_nm, cr.crdtr_nm,
                CASE WHEN ca.cnsmr_accnt_is_rtrnd_flg = 'Y' THEN 0
                     ELSE ISNULL(cab.cnsmr_accnt_bal_amnt, 0) END AS invoice_balance,
                acct_tag.tag_id, acct_tag.tag_shrt_nm AS status_short_nm, acct_tag.tag_nm AS status_name
            FROM dbo.cnsmr_accnt ca
            INNER JOIN dbo.crdtr cr ON cr.crdtr_id = ca.crdtr_id
            LEFT JOIN dbo.cnsmr_accnt_bal cab ON cab.cnsmr_accnt_id = ca.cnsmr_accnt_id AND cab.bal_nm_id = 7
            OUTER APPLY (
                SELECT TOP 1 t.tag_id, t.tag_shrt_nm, t.tag_nm
                FROM dbo.cnsmr_accnt_tag cat
                INNER JOIN dbo.tag t ON t.tag_id = cat.tag_id AND t.tag_typ_id = 113
                WHERE cat.cnsmr_accnt_id = ca.cnsmr_accnt_id AND cat.cnsmr_accnt_sft_delete_flg = 'N'
                ORDER BY cat.cnsmr_accnt_tag_assgn_dt DESC
            ) acct_tag
            WHERE ca.cnsmr_id = @cnsmrId
            ORDER BY cr.crdtr_shrt_nm, ca.cnsmr_accnt_plcmnt_date
"@ -Parameters @{ cnsmrId = [int]$cnsmrId }

        $paidResults = Invoke-CRS5ReadQuery -TimeoutSeconds $timeout -Query @"
            SELECT t.cnsmr_accnt_id, ISNULL(SUM(t.cnsmr_accnt_trnsctn_amnt), 0) AS total_paid
            FROM dbo.cnsmr_accnt_trnsctn t
            INNER JOIN dbo.crdtr_bckt cb ON cb.bckt_id = t.bckt_id AND cb.crdtr_id = t.crdtr_id
            INNER JOIN dbo.cnsmr_accnt ca ON ca.cnsmr_accnt_id = t.cnsmr_accnt_id
            WHERE ca.cnsmr_id = @cnsmrId AND t.bckt_trnsctn_typ_cd IN (2, 3, 5, 9) AND cb.crdtr_bckt_rprtbl_flg = 'Y'
            GROUP BY t.cnsmr_accnt_id
"@ -Parameters @{ cnsmrId = [int]$cnsmrId }

        $paidByAccount = @{}
        foreach ($p in $paidResults) { $paidByAccount[$p.cnsmr_accnt_id] = ConvertTo-SafeDecimal $p.total_paid }

        $accountList = @(); $totalBalanceOwed = [decimal]0; $totalPaidAll = [decimal]0
        foreach ($a in $accounts) {
            $acctId = $a.cnsmr_accnt_id
            $invoiceBalance = ConvertTo-SafeDecimal $a.invoice_balance
            $totalPaid = if ($paidByAccount.ContainsKey($acctId)) { $paidByAccount[$acctId] } else { [decimal]0 }
            if ($invoiceBalance) { $totalBalanceOwed += $invoiceBalance }
            if ($totalPaid) { $totalPaidAll += $totalPaid }

            $statusTag = $null
            if ($a.tag_id -and $a.tag_id -isnot [DBNull]) {
                $statusTag = @{
                    tag_id = ConvertTo-SafeValue $a.tag_id; short_nm = ConvertTo-SafeValue $a.status_short_nm
                    name = ConvertTo-SafeValue $a.status_name
                }
            }

            $accountList += @{
                cnsmr_accnt_id = $acctId; cnsmr_id = ConvertTo-SafeValue $a.cnsmr_id; crdtr_id = ConvertTo-SafeValue $a.crdtr_id
                cnsmr_accnt_idntfr_agncy_id = ConvertTo-SafeValue $a.cnsmr_accnt_idntfr_agncy_id
                cnsmr_accnt_crdtr_rfrnc_id_txt = ConvertTo-SafeValue $a.cnsmr_accnt_crdtr_rfrnc_id_txt
                cnsmr_accnt_crdtr_rfrnc_corltn_id_txt = ConvertTo-SafeValue $a.cnsmr_accnt_crdtr_rfrnc_corltn_id_txt
                cnsmr_accnt_dscrptn_txt = ConvertTo-SafeValue $a.cnsmr_accnt_dscrptn_txt
                cnsmr_accnt_plcmnt_date = ConvertTo-SafeDate $a.cnsmr_accnt_plcmnt_date
                cnsmr_accnt_crdtr_lst_srvc_dt = ConvertTo-SafeDate $a.cnsmr_accnt_crdtr_lst_srvc_dt
                cnsmr_accnt_is_rtrnd_flg = ConvertTo-SafeValue $a.cnsmr_accnt_is_rtrnd_flg
                cnsmr_accnt_pif_flg = ConvertTo-SafeValue $a.cnsmr_accnt_pif_flg
                cnsmr_accnt_sif_flg = ConvertTo-SafeValue $a.cnsmr_accnt_sif_flg
                cnsmr_accnt_is_actv_per_crdtr_flg = ConvertTo-SafeValue $a.cnsmr_accnt_is_actv_per_crdtr_flg
                crdtr_shrt_nm = ConvertTo-SafeValue $a.crdtr_shrt_nm; crdtr_nm = ConvertTo-SafeValue $a.crdtr_nm
                invoice_balance = $invoiceBalance; total_paid = $totalPaid; status_tag = $statusTag
            }
        }

        Write-PodeJsonResponse -Value @{
            accounts = $accountList; count = $accountList.Count
            total_balance_owed = $totalBalanceOwed; total_paid = $totalPaidAll
            timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# CONSUMER ADDRESSES
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/client-portal/consumer/:id/addresses' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $cnsmrId = $WebEvent.Parameters['id']
        $timeout = 60
        try {
            $tCfg = Invoke-XFActsQuery -Query "SELECT setting_value FROM dbo.GlobalConfig WHERE module_name = 'Tools' AND category = 'Portal' AND setting_name = 'crs5_portal_query_timeout_seconds' AND is_active = 1"
            if ($tCfg -and $tCfg.Count -gt 0 -and $tCfg[0].setting_value) { $timeout = [int]$tCfg[0].setting_value }
        } catch { }

        $results = Invoke-CRS5ReadQuery -TimeoutSeconds $timeout -Query @"
            SELECT ca.cnsmr_addrss_ln_1_txt, ca.cnsmr_addrss_ln_2_txt, ca.cnsmr_addrss_city_txt,
                   ca.cnsmr_addrss_st_txt, ca.cnsmr_addrss_pstl_cd_txt, ca.cnsmr_addrss_stts_cd,
                   ca.cnsmr_addrss_mail_rtrn_cd, ca.cnsmr_addrss_mail_rtrn_dt
            FROM dbo.cnsmr_addrss ca WHERE ca.cnsmr_id = @cnsmrId
"@ -Parameters @{ cnsmrId = [int]$cnsmrId }

        $addresses = @()
        foreach ($r in $results) {
            $addresses += @{
                line_1 = ConvertTo-SafeValue $r.cnsmr_addrss_ln_1_txt; line_2 = ConvertTo-SafeValue $r.cnsmr_addrss_ln_2_txt
                city = ConvertTo-SafeValue $r.cnsmr_addrss_city_txt; state = ConvertTo-SafeValue $r.cnsmr_addrss_st_txt
                zip = ConvertTo-SafeValue $r.cnsmr_addrss_pstl_cd_txt; status_cd = ConvertTo-SafeValue $r.cnsmr_addrss_stts_cd
                mail_return_cd = ConvertTo-SafeValue $r.cnsmr_addrss_mail_rtrn_cd; mail_return_dt = ConvertTo-SafeDate $r.cnsmr_addrss_mail_rtrn_dt
            }
        }

        Write-PodeJsonResponse -Value @{ addresses = $addresses; count = $addresses.Count }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# CONSUMER PHONES
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/client-portal/consumer/:id/phones' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $cnsmrId = $WebEvent.Parameters['id']
        $timeout = 60
        try {
            $tCfg = Invoke-XFActsQuery -Query "SELECT setting_value FROM dbo.GlobalConfig WHERE module_name = 'Tools' AND category = 'Portal' AND setting_name = 'crs5_portal_query_timeout_seconds' AND is_active = 1"
            if ($tCfg -and $tCfg.Count -gt 0 -and $tCfg[0].setting_value) { $timeout = [int]$tCfg[0].setting_value }
        } catch { }

        $results = Invoke-CRS5ReadQuery -TimeoutSeconds $timeout -Query @"
            SELECT cp.cnsmr_phn_nmbr_txt, cp.cnsmr_phn_stts_cd, cp.cnsmr_phn_typ_cd
            FROM dbo.cnsmr_phn cp WHERE cp.cnsmr_id = @cnsmrId AND cp.cnsmr_phn_sft_dlt_flg = 'N'
"@ -Parameters @{ cnsmrId = [int]$cnsmrId }

        $phones = @()
        foreach ($r in $results) {
            $phones += @{
                number = ConvertTo-SafeValue $r.cnsmr_phn_nmbr_txt; status_cd = ConvertTo-SafeValue $r.cnsmr_phn_stts_cd
                type_cd = ConvertTo-SafeValue $r.cnsmr_phn_typ_cd
            }
        }

        Write-PodeJsonResponse -Value @{ phones = $phones; count = $phones.Count }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# CONSUMER EVENTS
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/client-portal/consumer/:id/events' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $cnsmrId = $WebEvent.Parameters['id']
        $timeout = 60
        try {
            $tCfg = Invoke-XFActsQuery -Query "SELECT setting_value FROM dbo.GlobalConfig WHERE module_name = 'Tools' AND category = 'Portal' AND setting_name = 'crs5_portal_query_timeout_seconds' AND is_active = 1"
            if ($tCfg -and $tCfg.Count -gt 0 -and $tCfg[0].setting_value) { $timeout = [int]$tCfg[0].setting_value }
        } catch { }

        $results = Invoke-CRS5ReadQuery -TimeoutSeconds $timeout -Query @"
            SELECT al.actn_cd, al.rslt_cd, al.cnsmr_accnt_id, al.cnsmr_accnt_ar_mssg_txt,
                   al.cnsmr_accnt_ar_log_crt_usr_id, al.upsrt_dttm
            FROM dbo.cnsmr_accnt_ar_log al WHERE al.cnsmr_id = @cnsmrId ORDER BY al.upsrt_dttm DESC
"@ -Parameters @{ cnsmrId = [int]$cnsmrId }

        $events = @()
        foreach ($r in $results) {
            $events += @{
                actn_cd = ConvertTo-SafeValue $r.actn_cd; rslt_cd = ConvertTo-SafeValue $r.rslt_cd
                cnsmr_accnt_id = ConvertTo-SafeValue $r.cnsmr_accnt_id; message = ConvertTo-SafeValue $r.cnsmr_accnt_ar_mssg_txt
                user_id = ConvertTo-SafeValue $r.cnsmr_accnt_ar_log_crt_usr_id; event_date = ConvertTo-SafeDateTime $r.upsrt_dttm
            }
        }

        Write-PodeJsonResponse -Value @{ events = $events; count = $events.Count }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# CONSUMER DOCUMENTS
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/client-portal/consumer/:id/documents' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $cnsmrId = $WebEvent.Parameters['id']
        $timeout = 60
        try {
            $tCfg = Invoke-XFActsQuery -Query "SELECT setting_value FROM dbo.GlobalConfig WHERE module_name = 'Tools' AND category = 'Portal' AND setting_name = 'crs5_portal_query_timeout_seconds' AND is_active = 1"
            if ($tCfg -and $tCfg.Count -gt 0 -and $tCfg[0].setting_value) { $timeout = [int]$tCfg[0].setting_value }
        } catch { }

        $results = Invoke-CRS5ReadQuery -TimeoutSeconds $timeout -Query @"
            SELECT dr.dcmnt_rqst_id, dr.dcmnt_rqst_dt, dt.dcmnt_tmplt_shrt_nm, dt.dcmnt_tmplt_nm
            FROM dbo.dcmnt_rqst dr
            INNER JOIN dbo.dcmnt_tmplt_vrsn dtv ON dtv.dcmnt_tmplt_vrsn_id = dr.dcmnt_tmplt_vrsn_id
            INNER JOIN dbo.dcmnt_tmplt dt ON dt.dcmnt_tmplt_id = dtv.dcmnt_tmplt_id
            WHERE dr.dcmnt_rqst_sbjct_entty_id = @cnsmrId AND dr.dcmnt_rqst_stts_cd = 5
            ORDER BY dr.dcmnt_rqst_dt DESC
"@ -Parameters @{ cnsmrId = [int]$cnsmrId }

        $documents = @()
        foreach ($r in $results) {
            $documents += @{
                dcmnt_rqst_id = ConvertTo-SafeValue $r.dcmnt_rqst_id; dcmnt_rqst_dt = ConvertTo-SafeDate $r.dcmnt_rqst_dt
                template_short = ConvertTo-SafeValue $r.dcmnt_tmplt_shrt_nm; template_name = ConvertTo-SafeValue $r.dcmnt_tmplt_nm
            }
        }

        Write-PodeJsonResponse -Value @{ documents = $documents; count = $documents.Count }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# ACCOUNT DETAIL
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/client-portal/account/:id' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $acctId = $WebEvent.Parameters['id']
        $timeout = 60
        try {
            $tCfg = Invoke-XFActsQuery -Query "SELECT setting_value FROM dbo.GlobalConfig WHERE module_name = 'Tools' AND category = 'Portal' AND setting_name = 'crs5_portal_query_timeout_seconds' AND is_active = 1"
            if ($tCfg -and $tCfg.Count -gt 0 -and $tCfg[0].setting_value) { $timeout = [int]$tCfg[0].setting_value }
        } catch { }

        $result = Invoke-CRS5ReadQuery -TimeoutSeconds $timeout -Query @"
            SELECT ca.cnsmr_accnt_id, ca.cnsmr_id, ca.crdtr_id, ca.cnsmr_accnt_idntfr_agncy_id,
                ca.cnsmr_accnt_crdtr_rfrnc_id_txt, ca.cnsmr_accnt_crdtr_rfrnc_corltn_id_txt,
                ca.cnsmr_accnt_dscrptn_txt, ca.cnsmr_accnt_plcmnt_date, ca.cnsmr_accnt_crdtr_lst_srvc_dt,
                ca.cnsmr_accnt_is_actv_per_crdtr_flg, ca.cnsmr_accnt_pif_flg, ca.cnsmr_accnt_sif_flg,
                ca.cnsmr_accnt_is_rtrnd_flg, cr.crdtr_shrt_nm, cr.crdtr_nm,
                CASE WHEN ca.cnsmr_accnt_is_rtrnd_flg = 'Y' THEN 0
                     ELSE ISNULL(cab.cnsmr_accnt_bal_amnt, 0) END AS invoice_balance,
                acct_tag.tag_id, acct_tag.tag_shrt_nm AS status_short_nm, acct_tag.tag_nm AS status_name
            FROM dbo.cnsmr_accnt ca
            INNER JOIN dbo.crdtr cr ON cr.crdtr_id = ca.crdtr_id
            LEFT JOIN dbo.cnsmr_accnt_bal cab ON cab.cnsmr_accnt_id = ca.cnsmr_accnt_id AND cab.bal_nm_id = 7
            OUTER APPLY (
                SELECT TOP 1 t.tag_id, t.tag_shrt_nm, t.tag_nm
                FROM dbo.cnsmr_accnt_tag cat
                INNER JOIN dbo.tag t ON t.tag_id = cat.tag_id AND t.tag_typ_id = 113
                WHERE cat.cnsmr_accnt_id = ca.cnsmr_accnt_id AND cat.cnsmr_accnt_sft_delete_flg = 'N'
                ORDER BY cat.cnsmr_accnt_tag_assgn_dt DESC
            ) acct_tag
            WHERE ca.cnsmr_accnt_id = @acctId
"@ -Parameters @{ acctId = [int]$acctId }

        if (-not $result -or $result.Count -eq 0) {
            Write-PodeJsonResponse -Value @{ error = "Account not found" } -StatusCode 404; return
        }
        $a = $result[0]

        $paidResult = Invoke-CRS5ReadQuery -TimeoutSeconds $timeout -Query @"
            SELECT ISNULL(SUM(t.cnsmr_accnt_trnsctn_amnt), 0) AS total_paid
            FROM dbo.cnsmr_accnt_trnsctn t
            INNER JOIN dbo.crdtr_bckt cb ON cb.bckt_id = t.bckt_id AND cb.crdtr_id = t.crdtr_id
            WHERE t.cnsmr_accnt_id = @acctId AND t.bckt_trnsctn_typ_cd IN (2, 3, 5, 9) AND cb.crdtr_bckt_rprtbl_flg = 'Y'
"@ -Parameters @{ acctId = [int]$acctId }
        $totalPaid = if ($paidResult -and $paidResult.Count -gt 0) { ConvertTo-SafeDecimal $paidResult[0].total_paid } else { 0 }

        $balances = Invoke-CRS5ReadQuery -TimeoutSeconds $timeout -Query "SELECT cab.bal_nm_id, cab.cnsmr_accnt_bal_amnt FROM dbo.cnsmr_accnt_bal cab WHERE cab.cnsmr_accnt_id = @acctId" -Parameters @{ acctId = [int]$acctId }
        $balanceList = @()
        foreach ($b in $balances) { $balanceList += @{ bal_nm_id = ConvertTo-SafeValue $b.bal_nm_id; amount = ConvertTo-SafeDecimal $b.cnsmr_accnt_bal_amnt } }

        $statusTag = $null
        if ($a.tag_id -and $a.tag_id -isnot [DBNull]) {
            $statusTag = @{
                tag_id = ConvertTo-SafeValue $a.tag_id; short_nm = ConvertTo-SafeValue $a.status_short_nm
                name = ConvertTo-SafeValue $a.status_name
            }
        }

        Write-PodeJsonResponse -Value @{
            account = @{
                cnsmr_accnt_id = ConvertTo-SafeValue $a.cnsmr_accnt_id; cnsmr_id = ConvertTo-SafeValue $a.cnsmr_id
                crdtr_id = ConvertTo-SafeValue $a.crdtr_id; cnsmr_accnt_idntfr_agncy_id = ConvertTo-SafeValue $a.cnsmr_accnt_idntfr_agncy_id
                cnsmr_accnt_crdtr_rfrnc_id_txt = ConvertTo-SafeValue $a.cnsmr_accnt_crdtr_rfrnc_id_txt
                cnsmr_accnt_crdtr_rfrnc_corltn_id_txt = ConvertTo-SafeValue $a.cnsmr_accnt_crdtr_rfrnc_corltn_id_txt
                cnsmr_accnt_dscrptn_txt = ConvertTo-SafeValue $a.cnsmr_accnt_dscrptn_txt
                cnsmr_accnt_plcmnt_date = ConvertTo-SafeDate $a.cnsmr_accnt_plcmnt_date
                cnsmr_accnt_crdtr_lst_srvc_dt = ConvertTo-SafeDate $a.cnsmr_accnt_crdtr_lst_srvc_dt
                cnsmr_accnt_is_rtrnd_flg = ConvertTo-SafeValue $a.cnsmr_accnt_is_rtrnd_flg
                cnsmr_accnt_pif_flg = ConvertTo-SafeValue $a.cnsmr_accnt_pif_flg
                cnsmr_accnt_sif_flg = ConvertTo-SafeValue $a.cnsmr_accnt_sif_flg
                cnsmr_accnt_is_actv_per_crdtr_flg = ConvertTo-SafeValue $a.cnsmr_accnt_is_actv_per_crdtr_flg
                crdtr_shrt_nm = ConvertTo-SafeValue $a.crdtr_shrt_nm; crdtr_nm = ConvertTo-SafeValue $a.crdtr_nm
                invoice_balance = ConvertTo-SafeDecimal $a.invoice_balance; total_paid = $totalPaid
                balances = $balanceList; status_tag = $statusTag
            }
        }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# ACCOUNT TRANSACTIONS
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/client-portal/account/:id/transactions' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $acctId = $WebEvent.Parameters['id']
        $timeout = 60
        try {
            $tCfg = Invoke-XFActsQuery -Query "SELECT setting_value FROM dbo.GlobalConfig WHERE module_name = 'Tools' AND category = 'Portal' AND setting_name = 'crs5_portal_query_timeout_seconds' AND is_active = 1"
            if ($tCfg -and $tCfg.Count -gt 0 -and $tCfg[0].setting_value) { $timeout = [int]$tCfg[0].setting_value }
        } catch { }

        $results = Invoke-CRS5ReadQuery -TimeoutSeconds $timeout -Query @"
            SELECT t.bckt_id, t.bckt_trnsctn_typ_cd, t.cnsmr_accnt_trnsctn_amnt,
                   t.cnsmr_accnt_trnsctn_pst_dt, t.cnsmr_accnt_trnsctn_lctn_cd
            FROM dbo.cnsmr_accnt_trnsctn t
            INNER JOIN dbo.crdtr_bckt cb ON cb.bckt_id = t.bckt_id AND cb.crdtr_id = t.crdtr_id
            WHERE t.cnsmr_accnt_id = @acctId AND t.bckt_trnsctn_typ_cd IN (2, 3, 5, 9) AND cb.crdtr_bckt_rprtbl_flg = 'Y'
            ORDER BY t.cnsmr_accnt_trnsctn_pst_dt DESC
"@ -Parameters @{ acctId = [int]$acctId }

        $transactions = @()
        foreach ($r in $results) {
            $transactions += @{
                bckt_id = ConvertTo-SafeValue $r.bckt_id; txn_type_cd = ConvertTo-SafeValue $r.bckt_trnsctn_typ_cd
                amount = ConvertTo-SafeDecimal $r.cnsmr_accnt_trnsctn_amnt; post_date = ConvertTo-SafeDate $r.cnsmr_accnt_trnsctn_pst_dt
                location_cd = ConvertTo-SafeValue $r.cnsmr_accnt_trnsctn_lctn_cd
            }
        }

        Write-PodeJsonResponse -Value @{ transactions = $transactions; count = $transactions.Count }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# ACCOUNT EVENTS
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/client-portal/account/:id/events' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $acctId = $WebEvent.Parameters['id']
        $timeout = 60
        try {
            $tCfg = Invoke-XFActsQuery -Query "SELECT setting_value FROM dbo.GlobalConfig WHERE module_name = 'Tools' AND category = 'Portal' AND setting_name = 'crs5_portal_query_timeout_seconds' AND is_active = 1"
            if ($tCfg -and $tCfg.Count -gt 0 -and $tCfg[0].setting_value) { $timeout = [int]$tCfg[0].setting_value }
        } catch { }

        $results = Invoke-CRS5ReadQuery -TimeoutSeconds $timeout -Query @"
            SELECT al.actn_cd, al.rslt_cd, al.cnsmr_accnt_ar_mssg_txt,
                   al.cnsmr_accnt_ar_log_crt_usr_id, al.upsrt_dttm
            FROM dbo.cnsmr_accnt_ar_log al WHERE al.cnsmr_accnt_id = @acctId ORDER BY al.upsrt_dttm DESC
"@ -Parameters @{ acctId = [int]$acctId }

        $events = @()
        foreach ($r in $results) {
            $events += @{
                actn_cd = ConvertTo-SafeValue $r.actn_cd; rslt_cd = ConvertTo-SafeValue $r.rslt_cd
                message = ConvertTo-SafeValue $r.cnsmr_accnt_ar_mssg_txt
                user_id = ConvertTo-SafeValue $r.cnsmr_accnt_ar_log_crt_usr_id; event_date = ConvertTo-SafeDateTime $r.upsrt_dttm
            }
        }

        Write-PodeJsonResponse -Value @{ events = $events; count = $events.Count }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# ACCOUNT DOCUMENTS
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/client-portal/account/:id/documents' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $acctId = $WebEvent.Parameters['id']
        $timeout = 60
        try {
            $tCfg = Invoke-XFActsQuery -Query "SELECT setting_value FROM dbo.GlobalConfig WHERE module_name = 'Tools' AND category = 'Portal' AND setting_name = 'crs5_portal_query_timeout_seconds' AND is_active = 1"
            if ($tCfg -and $tCfg.Count -gt 0 -and $tCfg[0].setting_value) { $timeout = [int]$tCfg[0].setting_value }
        } catch { }

        $results = Invoke-CRS5ReadQuery -TimeoutSeconds $timeout -Query @"
            SELECT dr.dcmnt_rqst_id, dr.dcmnt_rqst_dt, dt.dcmnt_tmplt_shrt_nm, dt.dcmnt_tmplt_nm
            FROM dbo.dcmnt_rqst_sbjct_rcrd drsr
            INNER JOIN dbo.dcmnt_rqst dr ON dr.dcmnt_rqst_id = drsr.dcmnt_rqst_id
            INNER JOIN dbo.dcmnt_tmplt_vrsn dtv ON dtv.dcmnt_tmplt_vrsn_id = dr.dcmnt_tmplt_vrsn_id
            INNER JOIN dbo.dcmnt_tmplt dt ON dt.dcmnt_tmplt_id = dtv.dcmnt_tmplt_id
            WHERE drsr.dcmnt_rqst_sbjct_entty_id = @acctId AND drsr.entty_assctn_cd = 3
              AND drsr.dcmnt_rqst_in_elgblty_rsn_txt IS NULL AND dr.dcmnt_rqst_stts_cd = 5
            ORDER BY dr.dcmnt_rqst_dt DESC
"@ -Parameters @{ acctId = [int]$acctId }

        $documents = @()
        foreach ($r in $results) {
            $documents += @{
                dcmnt_rqst_id = ConvertTo-SafeValue $r.dcmnt_rqst_id; dcmnt_rqst_dt = ConvertTo-SafeDate $r.dcmnt_rqst_dt
                template_short = ConvertTo-SafeValue $r.dcmnt_tmplt_shrt_nm; template_name = ConvertTo-SafeValue $r.dcmnt_tmplt_nm
            }
        }

        Write-PodeJsonResponse -Value @{ documents = $documents; count = $documents.Count }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}
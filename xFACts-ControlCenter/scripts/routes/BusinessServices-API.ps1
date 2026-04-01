# ============================================================================
# xFACts Control Center - Business Services API Routes
# Location: E:\xFACts-ControlCenter\scripts\routes\BusinessServices-API.ps1
# 
# API endpoints for the Business Services manager dashboard.
# 
# Live Activity endpoints query CRS5 directly for real-time data.
# History and distribution endpoints query xFACts tracking tables.
#
# Endpoints:
#   GET  /api/business-services/live-activity      - Real-time group summary cards from CRS5
#   GET  /api/business-services/distribution        - Distribution user cards from xFACts
#   GET  /api/business-services/history             - Year/month rollup from xFACts
#   GET  /api/business-services/history-month       - Day-level detail for a month
#   GET  /api/business-services/history-day         - Group/user breakdown for a day
#   GET  /api/business-services/history-user-day    - Individual requests for a user on a day
#   GET  /api/business-services/request-detail      - Single request detail (comment modal)
#
# Version: Tracked in dbo.System_Metadata (component: DeptOps.BusinessServices)
# ============================================================================

# ============================================================================
# LIVE ACTIVITY - Direct CRS5 queries for real-time dashboard
# ============================================================================

Add-PodeRoute -Method Get -Path '/api/business-services/live-activity' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $results = Invoke-CRS5ReadQuery -Query @"
            SELECT 
                ug.usr_grp_clssfctn_id AS group_id,
                ug.usr_grp_clssfctn_shrt_nm AS group_short_name,
                ug.usr_grp_clssfctn_nm AS group_name,
                SUM(CASE WHEN rr.cnsmr_rvw_rqst_sft_dlt_flg = 'N' THEN 1 ELSE 0 END) AS total_open,
                SUM(CASE WHEN rr.cnsmr_rvw_rqst_sft_dlt_flg = 'N' AND rr.cnsmr_rvw_rqst_assgn_usr_id IS NULL THEN 1 ELSE 0 END) AS unassigned,
                SUM(CASE WHEN rr.cnsmr_rvw_rqst_sft_dlt_flg = 'N' AND rr.cnsmr_rvw_rqst_assgn_usr_id IS NOT NULL THEN 1 ELSE 0 END) AS assigned,
                SUM(CASE 
                    WHEN rr.cnsmr_rvw_rqst_sft_dlt_flg = 'Y' 
                     AND CAST(rr.upsrt_dttm AS DATE) = CAST(GETDATE() AS DATE) 
                    THEN 1 ELSE 0 
                END) AS closed_today,
                SUM(CASE 
                    WHEN CAST(rr.cnsmr_rvw_rqst_assgn_dt AS DATE) = CAST(GETDATE() AS DATE) 
                    THEN 1 ELSE 0 
                END) AS new_today
            FROM dbo.usr_grp_clssfctn ug
            LEFT JOIN dbo.cnsmr_rvw_rqst rr
                ON rr.cnsmr_rvw_rqst_assgnd_usr_grp_id = ug.usr_grp_clssfctn_id
            WHERE ug.usr_grp_clssfctn_id IN (15, 16, 17, 18, 19)
            GROUP BY ug.usr_grp_clssfctn_id, ug.usr_grp_clssfctn_shrt_nm, ug.usr_grp_clssfctn_nm
"@
        
        # Build group list directly (one row per group guaranteed)
        $groupList = @()
        foreach ($row in $results) {
            $groupList += @{
                group_id         = $row.group_id
                group_short_name = $row.group_short_name
                group_name       = $row.group_name
                total_open       = if ($row.total_open -is [DBNull]) { 0 } else { [int]$row.total_open }
                unassigned       = if ($row.unassigned -is [DBNull]) { 0 } else { [int]$row.unassigned }
                assigned         = if ($row.assigned -is [DBNull]) { 0 } else { [int]$row.assigned }
                closed_today     = if ($row.closed_today -is [DBNull]) { 0 } else { [int]$row.closed_today }
                new_today        = if ($row.new_today -is [DBNull]) { 0 } else { [int]$row.new_today }
            }
        }
        
        # Sort by group_id for consistent display order
        $groupList = @($groupList | Sort-Object { $_.group_id })
        
        Write-PodeJsonResponse -Value @{
            groups    = $groupList
            timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# DISTRIBUTION USERS - xFACts tracking data for user cards
# ============================================================================

Add-PodeRoute -Method Get -Path '/api/business-services/distribution' -Authentication 'ADLogin' -ScriptBlock {
    try {
        # Get distribution-enabled groups and their users
        $users = Invoke-XFActsQuery -Query @"
            SELECT 
                u.user_id,
                u.dm_user_id,
                u.username,
                u.display_name,
                u.assignment_cap,
                u.group_id,
                g.group_name,
                g.group_short_name,
                g.dm_group_id
            FROM DeptOps.BS_ReviewRequest_User u
            INNER JOIN DeptOps.BS_ReviewRequest_Group g ON g.group_id = u.group_id
            WHERE u.is_active = 1
              AND g.distribution_enabled = 1
              AND g.is_active = 1
            ORDER BY g.group_id, u.display_name
"@
        
        # For each user, get their current assigned count and completed today from tracking
        $metrics = Invoke-XFActsQuery -Query @"
            SELECT 
                t.assigned_username,
                t.group_id,
                SUM(CASE WHEN t.soft_delete_flag = 'N' AND t.assigned_username IS NOT NULL THEN 1 ELSE 0 END) AS currently_assigned,
                SUM(CASE 
                    WHEN t.soft_delete_flag = 'Y' 
                     AND t.completion_date IS NOT NULL 
                     AND CAST(t.completion_date AS DATE) = CAST(GETDATE() AS DATE)
                    THEN 1 ELSE 0 
                END) AS completed_today
            FROM DeptOps.BS_ReviewRequest_Tracking t
            INNER JOIN DeptOps.BS_ReviewRequest_Group g ON g.group_id = t.group_id
            WHERE g.distribution_enabled = 1
              AND t.assigned_username IS NOT NULL
            GROUP BY t.assigned_username, t.group_id
"@

        # Get new today count per distribution-enabled group
        $newTodayData = Invoke-XFActsQuery -Query @"
            SELECT 
                t.group_id,
                COUNT(*) AS new_today
            FROM DeptOps.BS_ReviewRequest_Tracking t
            INNER JOIN DeptOps.BS_ReviewRequest_Group g ON g.group_id = t.group_id
            WHERE g.distribution_enabled = 1
              AND CAST(t.request_date AS DATE) = CAST(GETDATE() AS DATE)
            GROUP BY t.group_id
"@

        # Build new today lookup
        $newTodayMap = @{}
        foreach ($n in $newTodayData) {
            $newTodayMap[$n.group_id] = if ($n.new_today -is [DBNull]) { 0 } else { [int]$n.new_today }
        }
        
        # Build metrics lookup
        $metricsMap = @{}
        foreach ($m in $metrics) {
            $key = "$($m.assigned_username)|$($m.group_id)"
            $metricsMap[$key] = @{
                currently_assigned = if ($m.currently_assigned -is [DBNull]) { 0 } else { [int]$m.currently_assigned }
                completed_today    = if ($m.completed_today -is [DBNull]) { 0 } else { [int]$m.completed_today }
            }
        }
        
        # Merge user config with metrics
        $groupData = @{}
        foreach ($u in $users) {
            $gid = $u.group_id
            if (-not $groupData.ContainsKey($gid)) {
                $groupData[$gid] = @{
                    group_id         = $gid
                    group_name       = $u.group_name
                    group_short_name = $u.group_short_name
                    new_today        = if ($newTodayMap.ContainsKey($gid)) { $newTodayMap[$gid] } else { 0 }
                    users            = @()
                }
            }
            
            $key = "$($u.username)|$gid"
            $um = if ($metricsMap.ContainsKey($key)) { $metricsMap[$key] } else { @{ currently_assigned = 0; completed_today = 0 } }
            
            $groupData[$gid].users += @{
                user_id            = $u.user_id
                username           = $u.username
                display_name       = $u.display_name
                assignment_cap     = [int]$u.assignment_cap
                currently_assigned = $um.currently_assigned
                completed_today    = $um.completed_today
            }
        }
        
        Write-PodeJsonResponse -Value @{
            groups    = @($groupData.Values | Sort-Object { $_.group_id })
            timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# HISTORY - Year/month rollup from xFACts tracking table
# ============================================================================

Add-PodeRoute -Method Get -Path '/api/business-services/history' -Authentication 'ADLogin' -ScriptBlock {
    try {
         # Optional group filter (0 or empty = all groups)
        $groupFilter = $WebEvent.Query['group']
        $groupClause = ""
        $params = @{}
        
        if ($groupFilter -and $groupFilter -ne '0') {
            $groupClause = "AND t.group_id = @groupId"
            $params['groupId'] = [int]$groupFilter
        }
        
        # Total request count for header
        $totalResult = Invoke-XFActsQuery -Query "SELECT COUNT(*) AS cnt FROM DeptOps.BS_ReviewRequest_Tracking t WHERE 1=1 $groupClause" -Parameters $params
        $totalCount = if ($totalResult -and $totalResult.Count -gt 0) { [long]$totalResult[0].cnt } else { 0 }
        
        # Year/month rollup by request_date (received)
        $receivedData = Invoke-XFActsQuery -Query @"
            SELECT 
                YEAR(t.request_date) AS yr,
                MONTH(t.request_date) AS mo,
                COUNT(*) AS received
            FROM DeptOps.BS_ReviewRequest_Tracking t
            WHERE t.request_date IS NOT NULL
            $groupClause
            GROUP BY YEAR(t.request_date), MONTH(t.request_date)
"@ -Parameters $params

        # Year/month rollup by completion_date (completed)
        $completedData = Invoke-XFActsQuery -Query @"
            SELECT 
                YEAR(t.completion_date) AS yr,
                MONTH(t.completion_date) AS mo,
                COUNT(*) AS completed
            FROM DeptOps.BS_ReviewRequest_Tracking t
            WHERE t.completion_date IS NOT NULL
              AND t.soft_delete_flag = 'Y'
            $groupClause
            GROUP BY YEAR(t.completion_date), MONTH(t.completion_date)
"@ -Parameters $params

        # Build received lookup
        $receivedMap = @{}
        foreach ($row in $receivedData) {
            $key = "$([int]$row.yr)-$([int]$row.mo)"
            $receivedMap[$key] = if ($row.received -is [DBNull]) { 0 } else { [int]$row.received }
        }

        # Build completed lookup
        $completedMap = @{}
        foreach ($row in $completedData) {
            $key = "$([int]$row.yr)-$([int]$row.mo)"
            $completedMap[$key] = if ($row.completed -is [DBNull]) { 0 } else { [int]$row.completed }
        }

        # Merge all year/month keys
        $allKeys = @{}
        foreach ($k in $receivedMap.Keys) { $allKeys[$k] = $true }
        foreach ($k in $completedMap.Keys) { $allKeys[$k] = $true }
        
        # Group by year
        $yearData = @{}
        foreach ($k in $allKeys.Keys) {
            $parts = $k -split '-'
            $year = [int]$parts[0]
            $month = [int]$parts[1]
            $received = if ($receivedMap.ContainsKey($k)) { $receivedMap[$k] } else { 0 }
            $completed = if ($completedMap.ContainsKey($k)) { $completedMap[$k] } else { 0 }

            if (-not $yearData.ContainsKey($year)) {
                $yearData[$year] = @{
                    year      = $year
                    received  = 0
                    completed = 0
                    months    = @()
                }
            }

            $yearData[$year].received += $received
            $yearData[$year].completed += $completed

            $yearData[$year].months += @{
                month     = $month
                received  = $received
                completed = $completed
            }
        }

        # Sort months within each year descending
        foreach ($yd in $yearData.Values) {
            $yd.months = @($yd.months | Sort-Object { -$_.month })
        }
        
        $years = @($yearData.Values | Sort-Object { -$_.year })
        
        # Get group list for filter badges
        $groups = Invoke-XFActsQuery -Query @"
            SELECT group_id, group_name, group_short_name 
            FROM DeptOps.BS_ReviewRequest_Group 
            WHERE is_active = 1 
            ORDER BY group_id
"@
        
        Write-PodeJsonResponse -Value @{
            years       = $years
            total_count = $totalCount
            groups      = $groups
            timestamp   = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# HISTORY MONTH - Day-level detail for a specific month
# ============================================================================

Add-PodeRoute -Method Get -Path '/api/business-services/history-month' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $year = $WebEvent.Query['year']
        $month = $WebEvent.Query['month']
        $groupFilter = $WebEvent.Query['group']
        
        if ([string]::IsNullOrEmpty($year) -or [string]::IsNullOrEmpty($month)) {
            Write-PodeJsonResponse -Value @{ error = "year and month are required" } -StatusCode 400
            return
        }
        
        $groupClause = ""
        $params = @{ year = [int]$year; month = [int]$month }
        
        if ($groupFilter -and $groupFilter -ne '0') {
            $groupClause = "AND t.group_id = @groupId"
            $params['groupId'] = [int]$groupFilter
        }

        # Received per day (by request_date)
        $receivedDays = Invoke-XFActsQuery -Query @"
            SELECT 
                CAST(t.request_date AS DATE) AS the_day,
                DATENAME(WEEKDAY, t.request_date) AS day_of_week,
                COUNT(*) AS received
            FROM DeptOps.BS_ReviewRequest_Tracking t
            WHERE YEAR(t.request_date) = @year
              AND MONTH(t.request_date) = @month
              $groupClause
            GROUP BY CAST(t.request_date AS DATE), DATENAME(WEEKDAY, t.request_date)
"@ -Parameters $params

        # Completed per day (by completion_date)
        $completedDays = Invoke-XFActsQuery -Query @"
            SELECT 
                CAST(t.completion_date AS DATE) AS the_day,
                DATENAME(WEEKDAY, t.completion_date) AS day_of_week,
                COUNT(*) AS completed
            FROM DeptOps.BS_ReviewRequest_Tracking t
            WHERE t.completion_date IS NOT NULL
              AND t.soft_delete_flag = 'Y'
              AND YEAR(t.completion_date) = @year
              AND MONTH(t.completion_date) = @month
              $groupClause
            GROUP BY CAST(t.completion_date AS DATE), DATENAME(WEEKDAY, t.completion_date)
"@ -Parameters $params

        # Build lookups
        $recMap = @{}
        foreach ($r in $receivedDays) {
            $dateStr = ([DateTime]$r.the_day).ToString("yyyy-MM-dd")
            $recMap[$dateStr] = @{ received = [int]$r.received; day_of_week = $r.day_of_week.ToString().Substring(0, 3) }
        }

        $cmpMap = @{}
        foreach ($c in $completedDays) {
            $dateStr = ([DateTime]$c.the_day).ToString("yyyy-MM-dd")
            $cmpMap[$dateStr] = @{ completed = [int]$c.completed; day_of_week = $c.day_of_week.ToString().Substring(0, 3) }
        }

        # Merge all day keys
        $allDays = @{}
        foreach ($k in $recMap.Keys) { $allDays[$k] = $true }
        foreach ($k in $cmpMap.Keys) { $allDays[$k] = $true }

        $dayList = @()
        foreach ($dateStr in $allDays.Keys) {
            $received = if ($recMap.ContainsKey($dateStr)) { $recMap[$dateStr].received } else { 0 }
            $completed = if ($cmpMap.ContainsKey($dateStr)) { $cmpMap[$dateStr].completed } else { 0 }
            $dow = if ($recMap.ContainsKey($dateStr)) { $recMap[$dateStr].day_of_week } elseif ($cmpMap.ContainsKey($dateStr)) { $cmpMap[$dateStr].day_of_week } else { '' }

            $dayList += @{
                date        = $dateStr
                day_of_week = $dow
                received    = $received
                completed   = $completed
            }
        }

        # Sort descending by date
        $dayList = @($dayList | Sort-Object { $_.date } -Descending)
        
        Write-PodeJsonResponse -Value @{
            year      = [int]$year
            month     = [int]$month
            days      = $dayList
            timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# HISTORY DAY - Group and user breakdown for a specific day (slideout)
# Pivoted to completion_date - shows who completed what on this day
# ============================================================================

Add-PodeRoute -Method Get -Path '/api/business-services/history-day' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $date = $WebEvent.Query['date']
        $groupFilter = $WebEvent.Query['group']
        
        if ([string]::IsNullOrEmpty($date)) {
            Write-PodeJsonResponse -Value @{ error = "date is required" } -StatusCode 400
            return
        }
        
        $groupClause = ""
        $params = @{ date = $date }
        
        if ($groupFilter -and $groupFilter -ne '0') {
            $groupClause = "AND t.group_id = @groupId"
            $params['groupId'] = [int]$groupFilter
        }
        
        # Group-level summary: completions on this day + received on this day
        $groupSummary = Invoke-XFActsQuery -Query @"
            SELECT 
                g.group_short_name,
                g.group_id,
                SUM(CASE WHEN CAST(t.completion_date AS DATE) = @date AND t.soft_delete_flag = 'Y' THEN 1 ELSE 0 END) AS completed,
                SUM(CASE WHEN CAST(t.request_date AS DATE) = @date THEN 1 ELSE 0 END) AS received
            FROM DeptOps.BS_ReviewRequest_Group g
            LEFT JOIN DeptOps.BS_ReviewRequest_Tracking t ON t.group_id = g.group_id
                AND (
                    (t.completion_date IS NOT NULL AND CAST(t.completion_date AS DATE) = @date AND t.soft_delete_flag = 'Y')
                    OR CAST(t.request_date AS DATE) = @date
                )
            WHERE g.is_active = 1
            $groupClause
            GROUP BY g.group_short_name, g.group_id
            ORDER BY g.group_id
"@ -Parameters $params
        
        # User-level breakdown: completions on this day
        $userSummary = Invoke-XFActsQuery -Query @"
            SELECT 
                g.group_short_name,
                g.group_id,
                ISNULL(t.completed_username, '(Unknown)') AS username,
                COUNT(*) AS completed
            FROM DeptOps.BS_ReviewRequest_Tracking t
            INNER JOIN DeptOps.BS_ReviewRequest_Group g ON g.group_id = t.group_id
            WHERE t.soft_delete_flag = 'Y'
              AND t.completion_date IS NOT NULL
              AND CAST(t.completion_date AS DATE) = @date
            $groupClause
            GROUP BY g.group_short_name, g.group_id, t.completed_username
            ORDER BY g.group_id, completed_username
"@ -Parameters $params
        
        $groupList = @()
        foreach ($g in $groupSummary) {
            $groupList += @{
                group_short_name = $g.group_short_name
                group_id         = [int]$g.group_id
                completed        = if ($g.completed -is [DBNull]) { 0 } else { [int]$g.completed }
                received         = if ($g.received -is [DBNull]) { 0 } else { [int]$g.received }
            }
        }
        
        $userList = @()
        foreach ($u in $userSummary) {
            $userList += @{
                group_short_name = $u.group_short_name
                group_id         = [int]$u.group_id
                username         = $u.username
                completed        = if ($u.completed -is [DBNull]) { 0 } else { [int]$u.completed }
            }
        }
        
        Write-PodeJsonResponse -Value @{
            date      = $date
            groups    = $groupList
            users     = $userList
            timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# HISTORY USER DAY - Individual requests completed by a user on a day
# ============================================================================

Add-PodeRoute -Method Get -Path '/api/business-services/history-user-day' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $date = $WebEvent.Query['date']
        $username = $WebEvent.Query['username']
        $groupFilter = $WebEvent.Query['group']
        
        if ([string]::IsNullOrEmpty($date) -or [string]::IsNullOrEmpty($username)) {
            Write-PodeJsonResponse -Value @{ error = "date and username are required" } -StatusCode 400
            return
        }
        
        $groupClause = ""
        $params = @{ date = $date }
        
        if ($groupFilter -and $groupFilter -ne '0') {
            $groupClause = "AND t.group_id = @groupId"
            $params['groupId'] = [int]$groupFilter
        }
        
        # User clause based on username
        $userClause = ""
        if ($username -eq '(Unknown)') {
            $userClause = "AND t.completed_username IS NULL"
        } else {
            $userClause = "AND t.completed_username = @username"
            $params['username'] = $username
        }
        
        $requests = Invoke-XFActsQuery -Query @"
            SELECT 
                t.tracking_id,
                t.dm_request_id,
                t.consumer_number,
                t.consumer_last_name,
                t.consumer_first_name,
                t.workgroup,
                g.group_short_name,
                t.requesting_username,
                t.assigned_username,
                t.completed_username,
                t.request_date,
                t.completion_date,
                t.soft_delete_flag,
                t.status_code,
                CASE WHEN t.request_comment IS NOT NULL AND LEN(t.request_comment) > 0 THEN 1 ELSE 0 END AS has_comment
            FROM DeptOps.BS_ReviewRequest_Tracking t
            INNER JOIN DeptOps.BS_ReviewRequest_Group g ON g.group_id = t.group_id
            WHERE t.soft_delete_flag = 'Y'
              AND t.completion_date IS NOT NULL
              AND CAST(t.completion_date AS DATE) = @date
            $userClause
            $groupClause
            ORDER BY t.completion_date ASC
"@ -Parameters $params
        
        $reqList = @()
        foreach ($r in $requests) {
            $reqList += @{
                tracking_id        = [int]$r.tracking_id
                dm_request_id      = [long]$r.dm_request_id
                consumer_number    = if ($r.consumer_number -is [DBNull]) { $null } else { $r.consumer_number }
                consumer_name      = if ($r.consumer_last_name -is [DBNull]) { '' } else { 
                    $last = $r.consumer_last_name
                    $first = if ($r.consumer_first_name -is [DBNull]) { '' } else { $r.consumer_first_name }
                    if ($first) { "$last, $first" } else { $last }
                }
                workgroup          = if ($r.workgroup -is [DBNull]) { $null } else { $r.workgroup }
                group_short_name   = $r.group_short_name
                requesting_user    = if ($r.requesting_username -is [DBNull]) { $null } else { $r.requesting_username }
                assigned_user      = if ($r.assigned_username -is [DBNull]) { $null } else { $r.assigned_username }
                completed_user     = if ($r.completed_username -is [DBNull]) { $null } else { $r.completed_username }
                request_date       = if ($r.request_date -is [DBNull]) { $null } else { ([DateTime]$r.request_date).ToString("M/d/yyyy h:mm tt") }
                completion_date    = if ($r.completion_date -is [DBNull]) { $null } else { ([DateTime]$r.completion_date).ToString("M/d/yyyy h:mm tt") }
                is_completed       = ($r.soft_delete_flag -eq 'Y')
                has_comment        = ([int]$r.has_comment -eq 1)
            }
        }
        
        Write-PodeJsonResponse -Value @{
            date      = $date
            username  = $username
            requests  = $reqList
            count     = $reqList.Count
            timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# REQUEST DETAIL - Single request with full comment (modal)
# ============================================================================

Add-PodeRoute -Method Get -Path '/api/business-services/request-detail' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $trackingId = $WebEvent.Query['id']
        
        if ([string]::IsNullOrEmpty($trackingId)) {
            Write-PodeJsonResponse -Value @{ error = "id is required" } -StatusCode 400
            return
        }
        
        $result = Invoke-XFActsQuery -Query @"
            SELECT 
                t.tracking_id,
                t.dm_request_id,
                t.consumer_number,
                t.consumer_last_name,
                t.consumer_first_name,
                t.workgroup,
                g.group_name,
                t.request_comment,
                t.requesting_username,
                t.assigned_username,
                t.completed_username,
                t.request_date,
                t.completion_date,
                t.soft_delete_flag,
                t.status_code,
                t.collected_dttm
            FROM DeptOps.BS_ReviewRequest_Tracking t
            INNER JOIN DeptOps.BS_ReviewRequest_Group g ON g.group_id = t.group_id
            WHERE t.tracking_id = @id
"@ -Parameters @{ id = [int]$trackingId }
        
        if (-not $result -or $result.Count -eq 0) {
            Write-PodeJsonResponse -Value @{ error = "Request not found" } -StatusCode 404
            return
        }
        
        $r = $result[0]
        
        Write-PodeJsonResponse -Value @{
            tracking_id     = [int]$r.tracking_id
            dm_request_id   = [long]$r.dm_request_id
            consumer_number = if ($r.consumer_number -is [DBNull]) { $null } else { $r.consumer_number }
            consumer_name   = if ($r.consumer_last_name -is [DBNull]) { '' } else {
                $last = $r.consumer_last_name
                $first = if ($r.consumer_first_name -is [DBNull]) { '' } else { $r.consumer_first_name }
                if ($first) { "$last, $first" } else { $last }
            }
            workgroup        = if ($r.workgroup -is [DBNull]) { $null } else { $r.workgroup }
            group_name       = $r.group_name
            comment          = if ($r.request_comment -is [DBNull]) { $null } else { $r.request_comment }
            requesting_user  = if ($r.requesting_username -is [DBNull]) { $null } else { $r.requesting_username }
            assigned_user    = if ($r.assigned_username -is [DBNull]) { $null } else { $r.assigned_username }
            completed_user   = if ($r.completed_username -is [DBNull]) { $null } else { $r.completed_username }
            request_date     = if ($r.request_date -is [DBNull]) { $null } else { ([DateTime]$r.request_date).ToString("M/d/yyyy h:mm tt") }
            completion_date  = if ($r.completion_date -is [DBNull]) { $null } else { ([DateTime]$r.completion_date).ToString("M/d/yyyy h:mm tt") }
            is_completed     = ($r.soft_delete_flag -eq 'Y')
            status_code      = [int]$r.status_code
        }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}
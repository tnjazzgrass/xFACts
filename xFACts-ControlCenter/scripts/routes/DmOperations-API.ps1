<#
.SYNOPSIS
    Provides the DM Operations dashboard's JSON API endpoints.

.DESCRIPTION
    API routes backing the Control Center DM Operations dashboard. Exposes read
    endpoints for per-process lifetime totals, today's running totals, daily
    execution history, per-day batch lists, per-batch detail, and the weekly
    execution-window schedule grids for the unified consumer archive and the
    consumer shell purge, plus the per-process environment badges. Action
    endpoints toggle the per-process abort flag, write schedule grid cells, and
    perform an admin-gated manual process launch. Every endpoint queries the
    xFActs AG listener through the shared data-access helpers, runs the
    action-permission hook, and returns JSON.

.COMPONENT
    DmOps

.NOTES
    File Name : DmOperations-API.ps1
    Location  : E:\xFACts-ControlCenter\scripts\routes\DmOperations-API.ps1

    FILE ORGANIZATION
    -----------------
    ROUTE: API ENDPOINTS
#>

<# ============================================================================
   ROUTE: API ENDPOINTS
   ----------------------------------------------------------------------------
   Registers the GET and POST endpoints under /api/dmops, each gated by ADLogin
   authentication and the Test-ActionEndpoint permission hook and returning a
   JSON response. Read endpoints use Invoke-XFActsQuery against the AG listener;
   schedule and abort writes use Invoke-XFActsNonQuery. Archive and shell purge
   are independent processes; each is represented by its own self-contained
   response object.
   Prefix: (none)
   ============================================================================ #>

# GET /api/dmops/lifetime-totals
# Returns per-process self-contained objects (Archive, ShellPurge). Each object
# carries cumulative totals, its abort flag, its TC_ARCH-gated remaining counts
# (subtractive math returns counts processed since the OLTP baseline was
# sampled), and the admin CanLaunch gate flag.
Add-PodeRoute -Method Get -Path '/api/dmops/lifetime-totals' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        $ctx = Get-UserContext -WebEvent $WebEvent
        $canLaunch = [bool]$ctx.IsAdmin

        # Archive lifetime totals (consumer-driven; account counts retained as secondary metric)
        $archRows = Invoke-XFActsQuery -Query @"
            SELECT
                ISNULL(SUM(CASE WHEN status = 'Success' THEN consumer_count ELSE 0 END), 0) AS archive_consumers,
                ISNULL(SUM(CASE WHEN status = 'Success' THEN account_count  ELSE 0 END), 0) AS archive_accounts,
                ISNULL(SUM(CASE WHEN status = 'Success' THEN total_rows_deleted ELSE 0 END), 0) AS archive_rows,
                ISNULL(SUM(exception_count), 0) AS archive_exceptions,
                COUNT(*) AS archive_batches,
                SUM(CASE WHEN status = 'Failed' THEN 1 ELSE 0 END) AS archive_failed_batches,
                MIN(batch_start_dttm) AS archive_first_batch,
                MAX(batch_start_dttm) AS archive_last_batch
            FROM DmOps.Archive_BatchLog
            WHERE status IN ('Success', 'Failed')
"@
        $archRow = $archRows[0]

        # ShellPurge lifetime totals (naturally-occurring shells only)
        $purgeRows = Invoke-XFActsQuery -Query @"
            SELECT
                ISNULL(SUM(CASE WHEN status = 'Success' THEN consumer_count ELSE 0 END), 0) AS purge_consumers,
                ISNULL(SUM(CASE WHEN status = 'Success' THEN total_rows_deleted ELSE 0 END), 0) AS purge_rows,
                COUNT(*) AS purge_batches,
                SUM(CASE WHEN status = 'Failed' THEN 1 ELSE 0 END) AS purge_failed_batches,
                MIN(batch_start_dttm) AS purge_first_batch,
                MAX(batch_start_dttm) AS purge_last_batch
            FROM DmOps.ShellPurge_BatchLog
            WHERE status IN ('Success', 'Failed')
"@
        $purgeRow = $purgeRows[0]

        # Current abort flags
        $abortRows = Invoke-XFActsQuery -Query @"
            SELECT setting_name, setting_value
            FROM dbo.GlobalConfig
            WHERE module_name = 'DmOps'
              AND setting_name IN ('archive_abort', 'shell_purge_abort')
              AND is_active = 1
"@

        $archiveAbort = $false
        $shellPurgeAbort = $false
        foreach ($row in $abortRows) {
            $name = [string]$row['setting_name']
            $val  = [string]$row['setting_value']
            if ($name -eq 'archive_abort'     -and $val -eq '1') { $archiveAbort = $true }
            if ($name -eq 'shell_purge_abort' -and $val -eq '1') { $shellPurgeAbort = $true }
        }

        # Remaining counts (cached, subtractive) -- non-blocking. If crs5_oltp
        # is unreachable, remaining baselines stay null but everything else
        # still works. BaselineDttm and Error come from the single
        # Get-RemainingCounts cache call and are surfaced inside each process's
        # own Remaining object so each object is self-describing.
        $archiveConsumersBaseline = $null
        $archiveAccountsBaseline  = $null
        $shellBaseline            = $null
        $baselineDttm             = $null
        $archiveConsumersSince    = 0
        $archiveAccountsSince     = 0
        $shellSince               = 0
        $remainingError           = $null

        try {
            $cache = Get-RemainingCounts
            $archiveConsumersBaseline = $cache.ArchiveConsumersRemaining
            $archiveAccountsBaseline  = $cache.ArchiveAccountsRemaining
            $shellBaseline            = $cache.ShellRemaining
            $baselineDttm             = if ($cache.BaselineDttm) { $cache.BaselineDttm.ToString("yyyy-MM-dd HH:mm:ss") } else { $null }

            # Subtractive counts: consumers/accounts processed since baseline
            if ($cache.BaselineDttm) {
                $sinceRows = Invoke-XFActsQuery -Query @"
                    SELECT
                        ISNULL(SUM(consumer_count), 0) AS archive_consumers_since,
                        ISNULL(SUM(account_count),  0) AS archive_accounts_since
                    FROM DmOps.Archive_BatchLog
                    WHERE status = 'Success'
                      AND batch_start_dttm > @BaselineDttm
"@ -Parameters @{ BaselineDttm = $cache.BaselineDttm }
                $archiveConsumersSince = [long]$sinceRows[0]['archive_consumers_since']
                $archiveAccountsSince  = [long]$sinceRows[0]['archive_accounts_since']

                $shellSinceRows = Invoke-XFActsQuery -Query @"
                    SELECT
                        ISNULL(SUM(consumer_count), 0) AS purge_since_baseline
                    FROM DmOps.ShellPurge_BatchLog
                    WHERE status = 'Success'
                      AND batch_start_dttm > @BaselineDttm
"@ -Parameters @{ BaselineDttm = $cache.BaselineDttm }
                $shellSince = [long]$shellSinceRows[0]['purge_since_baseline']
            }
        }
        catch {
            $remainingError = $_.Exception.Message
        }

        $archive = [PSCustomObject]@{
            Consumers     = if ($archRow['archive_consumers']      -is [DBNull]) { 0 } else { [long]$archRow['archive_consumers'] }
            Accounts      = if ($archRow['archive_accounts']       -is [DBNull]) { 0 } else { [long]$archRow['archive_accounts'] }
            RowsDeleted   = if ($archRow['archive_rows']           -is [DBNull]) { 0 } else { [long]$archRow['archive_rows'] }
            Exceptions    = if ($archRow['archive_exceptions']     -is [DBNull]) { 0 } else { [long]$archRow['archive_exceptions'] }
            Batches       = if ($archRow['archive_batches']        -is [DBNull]) { 0 } else { [int]$archRow['archive_batches'] }
            FailedBatches = if ($archRow['archive_failed_batches'] -is [DBNull]) { 0 } else { [int]$archRow['archive_failed_batches'] }
            FirstBatch    = if ($archRow['archive_first_batch']    -is [DBNull]) { $null } else { $archRow['archive_first_batch'].ToString("yyyy-MM-dd HH:mm:ss") }
            LastBatch     = if ($archRow['archive_last_batch']     -is [DBNull]) { $null } else { $archRow['archive_last_batch'].ToString("yyyy-MM-dd HH:mm:ss") }
            Aborted       = $archiveAbort
            CanLaunch     = $canLaunch
            Remaining     = [PSCustomObject]@{
                ConsumersBaseline      = $archiveConsumersBaseline
                AccountsBaseline       = $archiveAccountsBaseline
                BaselineDttm           = $baselineDttm
                ConsumersSinceBaseline = $archiveConsumersSince
                AccountsSinceBaseline  = $archiveAccountsSince
                Error                  = $remainingError
            }
        }

        $shellPurge = [PSCustomObject]@{
            Consumers     = if ($purgeRow['purge_consumers']      -is [DBNull]) { 0 } else { [long]$purgeRow['purge_consumers'] }
            RowsDeleted   = if ($purgeRow['purge_rows']           -is [DBNull]) { 0 } else { [long]$purgeRow['purge_rows'] }
            Batches       = if ($purgeRow['purge_batches']        -is [DBNull]) { 0 } else { [int]$purgeRow['purge_batches'] }
            FailedBatches = if ($purgeRow['purge_failed_batches'] -is [DBNull]) { 0 } else { [int]$purgeRow['purge_failed_batches'] }
            FirstBatch    = if ($purgeRow['purge_first_batch']    -is [DBNull]) { $null } else { $purgeRow['purge_first_batch'].ToString("yyyy-MM-dd HH:mm:ss") }
            LastBatch     = if ($purgeRow['purge_last_batch']     -is [DBNull]) { $null } else { $purgeRow['purge_last_batch'].ToString("yyyy-MM-dd HH:mm:ss") }
            Aborted       = $shellPurgeAbort
            CanLaunch     = $canLaunch
            Remaining     = [PSCustomObject]@{
                Baseline      = $shellBaseline
                BaselineDttm  = $baselineDttm
                SinceBaseline = $shellSince
                Error         = $remainingError
            }
        }

        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            Archive    = $archive
            ShellPurge = $shellPurge
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# GET /api/dmops/today
# Returns today's running totals for both processes (with exception_count
# and bidata_status mix for Archive).
Add-PodeRoute -Method Get -Path '/api/dmops/today' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        # Archive today
        $archRows = Invoke-XFActsQuery -Query @"
            SELECT
                COUNT(*) AS batches,
                ISNULL(SUM(CASE WHEN status = 'Success' THEN consumer_count ELSE 0 END), 0) AS consumers,
                ISNULL(SUM(CASE WHEN status = 'Success' THEN account_count  ELSE 0 END), 0) AS accounts,
                ISNULL(SUM(CASE WHEN status = 'Success' THEN total_rows_deleted ELSE 0 END), 0) AS rows_deleted,
                ISNULL(SUM(exception_count), 0) AS exceptions,
                ISNULL(SUM(CASE WHEN status = 'Success' THEN duration_ms ELSE 0 END), 0) / 1000 AS total_seconds,
                SUM(CASE WHEN status = 'Failed' THEN 1 ELSE 0 END) AS failed_batches,
                SUM(CASE WHEN bidata_status = 'Failed' THEN 1 ELSE 0 END) AS bidata_failed,
                SUM(CASE WHEN schedule_mode = 'Full'    THEN 1 ELSE 0 END) AS full_batches,
                SUM(CASE WHEN schedule_mode = 'Reduced' THEN 1 ELSE 0 END) AS reduced_batches
            FROM DmOps.Archive_BatchLog
            WHERE status IN ('Success', 'Failed')
              AND CAST(batch_start_dttm AS DATE) = CAST(GETDATE() AS DATE)
"@
        $archRow = $archRows[0]

        # ShellPurge today
        $purgeRows = Invoke-XFActsQuery -Query @"
            SELECT
                COUNT(*) AS batches,
                ISNULL(SUM(CASE WHEN status = 'Success' THEN consumer_count ELSE 0 END), 0) AS consumers,
                ISNULL(SUM(CASE WHEN status = 'Success' THEN total_rows_deleted ELSE 0 END), 0) AS rows_deleted,
                ISNULL(SUM(CASE WHEN status = 'Success' THEN duration_ms ELSE 0 END), 0) / 1000 AS total_seconds,
                SUM(CASE WHEN status = 'Failed' THEN 1 ELSE 0 END) AS failed_batches,
                SUM(CASE WHEN schedule_mode = 'Full'    THEN 1 ELSE 0 END) AS full_batches,
                SUM(CASE WHEN schedule_mode = 'Reduced' THEN 1 ELSE 0 END) AS reduced_batches
            FROM DmOps.ShellPurge_BatchLog
            WHERE status IN ('Success', 'Failed')
              AND CAST(batch_start_dttm AS DATE) = CAST(GETDATE() AS DATE)
"@
        $purgeRow = $purgeRows[0]

        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            Archive = [PSCustomObject]@{
                Batches        = if ($archRow['batches']         -is [DBNull]) { 0 } else { [int]$archRow['batches'] }
                Consumers      = if ($archRow['consumers']       -is [DBNull]) { 0 } else { [long]$archRow['consumers'] }
                Accounts       = if ($archRow['accounts']        -is [DBNull]) { 0 } else { [long]$archRow['accounts'] }
                RowsDeleted    = if ($archRow['rows_deleted']    -is [DBNull]) { 0 } else { [long]$archRow['rows_deleted'] }
                Exceptions     = if ($archRow['exceptions']      -is [DBNull]) { 0 } else { [long]$archRow['exceptions'] }
                TotalSeconds   = if ($archRow['total_seconds']   -is [DBNull]) { 0 } else { [long]$archRow['total_seconds'] }
                FailedBatches  = if ($archRow['failed_batches']  -is [DBNull]) { 0 } else { [int]$archRow['failed_batches'] }
                BidataFailed   = if ($archRow['bidata_failed']   -is [DBNull]) { 0 } else { [int]$archRow['bidata_failed'] }
                FullBatches    = if ($archRow['full_batches']    -is [DBNull]) { 0 } else { [int]$archRow['full_batches'] }
                ReducedBatches = if ($archRow['reduced_batches'] -is [DBNull]) { 0 } else { [int]$archRow['reduced_batches'] }
            }
            ShellPurge = [PSCustomObject]@{
                Batches        = if ($purgeRow['batches']         -is [DBNull]) { 0 } else { [int]$purgeRow['batches'] }
                Consumers      = if ($purgeRow['consumers']       -is [DBNull]) { 0 } else { [long]$purgeRow['consumers'] }
                RowsDeleted    = if ($purgeRow['rows_deleted']    -is [DBNull]) { 0 } else { [long]$purgeRow['rows_deleted'] }
                TotalSeconds   = if ($purgeRow['total_seconds']   -is [DBNull]) { 0 } else { [long]$purgeRow['total_seconds'] }
                FailedBatches  = if ($purgeRow['failed_batches']  -is [DBNull]) { 0 } else { [int]$purgeRow['failed_batches'] }
                FullBatches    = if ($purgeRow['full_batches']    -is [DBNull]) { 0 } else { [int]$purgeRow['full_batches'] }
                ReducedBatches = if ($purgeRow['reduced_batches'] -is [DBNull]) { 0 } else { [int]$purgeRow['reduced_batches'] }
            }
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# GET /api/dmops/execution-history
# Returns daily aggregated totals grouped by year/month/day for accordion
# display. Day-level aggregates include exception_count totals and
# bidata_failed counts (Archive) for use in the at-a-glance row.
Add-PodeRoute -Method Get -Path '/api/dmops/execution-history' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        # Archive daily summary
        $archRows = Invoke-XFActsQuery -Query @"
            SELECT
                YEAR(batch_start_dttm) AS run_year,
                MONTH(batch_start_dttm) AS run_month,
                CAST(batch_start_dttm AS DATE) AS run_date,
                DATENAME(dw, batch_start_dttm) AS day_of_week,
                COUNT(*) AS batches,
                SUM(CASE WHEN status = 'Success' THEN consumer_count ELSE 0 END) AS total_consumers,
                SUM(CASE WHEN status = 'Success' THEN account_count  ELSE 0 END) AS total_accounts,
                SUM(CASE WHEN status = 'Success' THEN total_rows_deleted ELSE 0 END) AS total_rows,
                ISNULL(SUM(exception_count), 0) AS total_exceptions,
                SUM(CASE WHEN status = 'Failed' THEN 1 ELSE 0 END) AS failed_batches,
                SUM(CASE WHEN bidata_status = 'Failed' THEN 1 ELSE 0 END) AS bidata_failed,
                SUM(CASE WHEN status = 'Success' THEN duration_ms ELSE 0 END) / 1000 AS total_seconds,
                SUM(CASE WHEN schedule_mode = 'Full'    THEN 1 ELSE 0 END) AS full_batches,
                SUM(CASE WHEN schedule_mode = 'Reduced' THEN 1 ELSE 0 END) AS reduced_batches
            FROM DmOps.Archive_BatchLog
            WHERE status IN ('Success', 'Failed')
            GROUP BY YEAR(batch_start_dttm), MONTH(batch_start_dttm),
                     CAST(batch_start_dttm AS DATE), DATENAME(dw, batch_start_dttm)
            ORDER BY run_date DESC
"@

        # ShellPurge daily summary
        $purgeRows = Invoke-XFActsQuery -Query @"
            SELECT
                YEAR(batch_start_dttm) AS run_year,
                MONTH(batch_start_dttm) AS run_month,
                CAST(batch_start_dttm AS DATE) AS run_date,
                DATENAME(dw, batch_start_dttm) AS day_of_week,
                COUNT(*) AS batches,
                SUM(CASE WHEN status = 'Success' THEN consumer_count ELSE 0 END) AS total_consumers,
                SUM(CASE WHEN status = 'Success' THEN total_rows_deleted ELSE 0 END) AS total_rows,
                SUM(CASE WHEN status = 'Failed' THEN 1 ELSE 0 END) AS failed_batches,
                SUM(CASE WHEN status = 'Success' THEN duration_ms ELSE 0 END) / 1000 AS total_seconds,
                SUM(CASE WHEN schedule_mode = 'Full'    THEN 1 ELSE 0 END) AS full_batches,
                SUM(CASE WHEN schedule_mode = 'Reduced' THEN 1 ELSE 0 END) AS reduced_batches
            FROM DmOps.ShellPurge_BatchLog
            WHERE status IN ('Success', 'Failed')
            GROUP BY YEAR(batch_start_dttm), MONTH(batch_start_dttm),
                     CAST(batch_start_dttm AS DATE), DATENAME(dw, batch_start_dttm)
            ORDER BY run_date DESC
"@

        # Archive history
        $archiveDays = @()
        foreach ($row in $archRows) {
            $archiveDays += [PSCustomObject]@{
                run_year        = [int]$row['run_year']
                run_month       = [int]$row['run_month']
                run_date        = $row['run_date'].ToString("yyyy-MM-dd")
                day_of_week     = [string]$row['day_of_week']
                batches         = [int]$row['batches']
                consumers       = [long]$row['total_consumers']
                accounts        = [long]$row['total_accounts']
                rows_deleted    = [long]$row['total_rows']
                exceptions      = [long]$row['total_exceptions']
                failed_batches  = [int]$row['failed_batches']
                bidata_failed   = [int]$row['bidata_failed']
                total_seconds   = if ($row['total_seconds'] -is [DBNull]) { 0 } else { [long]$row['total_seconds'] }
                full_batches    = [int]$row['full_batches']
                reduced_batches = [int]$row['reduced_batches']
            }
        }

        # ShellPurge history
        $shellPurgeDays = @()
        foreach ($row in $purgeRows) {
            $shellPurgeDays += [PSCustomObject]@{
                run_year        = [int]$row['run_year']
                run_month       = [int]$row['run_month']
                run_date        = $row['run_date'].ToString("yyyy-MM-dd")
                day_of_week     = [string]$row['day_of_week']
                batches         = [int]$row['batches']
                consumers       = [long]$row['total_consumers']
                rows_deleted    = [long]$row['total_rows']
                failed_batches  = [int]$row['failed_batches']
                total_seconds   = if ($row['total_seconds'] -is [DBNull]) { 0 } else { [long]$row['total_seconds'] }
                full_batches    = [int]$row['full_batches']
                reduced_batches = [int]$row['reduced_batches']
            }
        }

        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            Archive    = $archiveDays
            ShellPurge = $shellPurgeDays
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# GET /api/dmops/archive/batches-by-day?date=YYYY-MM-DD
# Returns the individual Archive batches for the given date.
Add-PodeRoute -Method Get -Path '/api/dmops/archive/batches-by-day' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        $date = $WebEvent.Query['date']
        if ([string]::IsNullOrEmpty($date)) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Missing required query parameter: date (YYYY-MM-DD)" }) -StatusCode 400
            return
        }

        $rows = Invoke-XFActsQuery -Query @"
            SELECT
                batch_id, batch_start_dttm, batch_end_dttm,
                schedule_mode, batch_size_used,
                consumer_count, account_count, total_rows_deleted,
                exception_count, tables_processed, tables_skipped, tables_failed,
                duration_ms, status, error_message,
                batch_retry, retry_batch_id, bidata_status, executed_by
            FROM DmOps.Archive_BatchLog
            WHERE CAST(batch_start_dttm AS DATE) = CAST(@date AS DATE)
            ORDER BY batch_id DESC
"@ -Parameters @{ date = $date }

        $batches = @()
        foreach ($r in $rows) {
            $batches += [PSCustomObject]@{
                batch_id           = [long]$r['batch_id']
                batch_start_dttm   = if ($r['batch_start_dttm']   -is [DBNull]) { $null } else { $r['batch_start_dttm'].ToString("yyyy-MM-dd HH:mm:ss") }
                batch_end_dttm     = if ($r['batch_end_dttm']     -is [DBNull]) { $null } else { $r['batch_end_dttm'].ToString("yyyy-MM-dd HH:mm:ss") }
                schedule_mode      = if ($r['schedule_mode']      -is [DBNull]) { $null } else { [string]$r['schedule_mode'] }
                batch_size_used    = if ($r['batch_size_used']    -is [DBNull]) { 0 } else { [int]$r['batch_size_used'] }
                consumer_count     = if ($r['consumer_count']     -is [DBNull]) { 0 } else { [long]$r['consumer_count'] }
                account_count      = if ($r['account_count']      -is [DBNull]) { 0 } else { [long]$r['account_count'] }
                total_rows_deleted = if ($r['total_rows_deleted'] -is [DBNull]) { 0 } else { [long]$r['total_rows_deleted'] }
                exception_count    = if ($r['exception_count']    -is [DBNull]) { 0 } else { [int]$r['exception_count'] }
                tables_processed   = if ($r['tables_processed']   -is [DBNull]) { 0 } else { [int]$r['tables_processed'] }
                tables_skipped     = if ($r['tables_skipped']     -is [DBNull]) { 0 } else { [int]$r['tables_skipped'] }
                tables_failed      = if ($r['tables_failed']      -is [DBNull]) { 0 } else { [int]$r['tables_failed'] }
                duration_ms        = if ($r['duration_ms']        -is [DBNull]) { 0 } else { [long]$r['duration_ms'] }
                status             = if ($r['status']             -is [DBNull]) { $null } else { [string]$r['status'] }
                error_message      = if ($r['error_message']      -is [DBNull]) { $null } else { [string]$r['error_message'] }
                batch_retry        = if ($r['batch_retry']        -is [DBNull]) { 0 } else { [int]$r['batch_retry'] }
                retry_batch_id     = if ($r['retry_batch_id']     -is [DBNull]) { $null } else { [long]$r['retry_batch_id'] }
                bidata_status      = if ($r['bidata_status']      -is [DBNull]) { $null } else { [string]$r['bidata_status'] }
                executed_by        = if ($r['executed_by']        -is [DBNull]) { $null } else { [string]$r['executed_by'] }
            }
        }

        Write-PodeJsonResponse -Value $batches
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# GET /api/dmops/shellpurge/batches-by-day?date=YYYY-MM-DD
# Returns the individual ShellPurge batches for the given date.
Add-PodeRoute -Method Get -Path '/api/dmops/shellpurge/batches-by-day' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        $date = $WebEvent.Query['date']
        if ([string]::IsNullOrEmpty($date)) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Missing required query parameter: date (YYYY-MM-DD)" }) -StatusCode 400
            return
        }

        $rows = Invoke-XFActsQuery -Query @"
            SELECT
                batch_id, batch_start_dttm, batch_end_dttm,
                schedule_mode, batch_size_used,
                consumer_count, total_rows_deleted,
                tables_processed, tables_skipped, tables_failed,
                duration_ms, status, error_message,
                executed_by
            FROM DmOps.ShellPurge_BatchLog
            WHERE CAST(batch_start_dttm AS DATE) = CAST(@date AS DATE)
            ORDER BY batch_id DESC
"@ -Parameters @{ date = $date }

        $batches = @()
        foreach ($r in $rows) {
            $batches += [PSCustomObject]@{
                batch_id           = [long]$r['batch_id']
                batch_start_dttm   = if ($r['batch_start_dttm']   -is [DBNull]) { $null } else { $r['batch_start_dttm'].ToString("yyyy-MM-dd HH:mm:ss") }
                batch_end_dttm     = if ($r['batch_end_dttm']     -is [DBNull]) { $null } else { $r['batch_end_dttm'].ToString("yyyy-MM-dd HH:mm:ss") }
                schedule_mode      = if ($r['schedule_mode']      -is [DBNull]) { $null } else { [string]$r['schedule_mode'] }
                batch_size_used    = if ($r['batch_size_used']    -is [DBNull]) { 0 } else { [int]$r['batch_size_used'] }
                consumer_count     = if ($r['consumer_count']     -is [DBNull]) { 0 } else { [long]$r['consumer_count'] }
                total_rows_deleted = if ($r['total_rows_deleted'] -is [DBNull]) { 0 } else { [long]$r['total_rows_deleted'] }
                tables_processed   = if ($r['tables_processed']   -is [DBNull]) { 0 } else { [int]$r['tables_processed'] }
                tables_skipped     = if ($r['tables_skipped']     -is [DBNull]) { 0 } else { [int]$r['tables_skipped'] }
                tables_failed      = if ($r['tables_failed']      -is [DBNull]) { 0 } else { [int]$r['tables_failed'] }
                duration_ms        = if ($r['duration_ms']        -is [DBNull]) { 0 } else { [long]$r['duration_ms'] }
                status             = if ($r['status']             -is [DBNull]) { $null } else { [string]$r['status'] }
                error_message      = if ($r['error_message']      -is [DBNull]) { $null } else { [string]$r['error_message'] }
                executed_by        = if ($r['executed_by']        -is [DBNull]) { $null } else { [string]$r['executed_by'] }
            }
        }

        Write-PodeJsonResponse -Value $batches
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# GET /api/dmops/archive/batch-detail/:batchId
# Returns Archive_BatchDetail rows for a specific batch (for the slide-out
# step-by-step view), with the batch summary for the slide-out header.
Add-PodeRoute -Method Get -Path '/api/dmops/archive/batch-detail/:batchId' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        $batchId = $WebEvent.Parameters['batchId']
        if ([string]::IsNullOrEmpty($batchId)) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Missing batchId" }) -StatusCode 400
            return
        }

        $summary = Invoke-XFActsQuery -Query @"
            SELECT
                batch_id, batch_start_dttm, batch_end_dttm,
                schedule_mode, batch_size_used,
                consumer_count, account_count, total_rows_deleted,
                exception_count, tables_processed, tables_skipped, tables_failed,
                duration_ms, status, error_message,
                batch_retry, retry_batch_id, bidata_status, executed_by
            FROM DmOps.Archive_BatchLog
            WHERE batch_id = @batchId
"@ -Parameters @{ batchId = [long]$batchId }

        if (-not $summary -or $summary.Count -eq 0) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Batch not found: $batchId" }) -StatusCode 404
            return
        }

        $details = Invoke-XFActsQuery -Query @"
            SELECT
                detail_id, batch_id, delete_order, table_name, pass_description,
                rows_affected, duration_ms, status, error_message, created_dttm
            FROM DmOps.Archive_BatchDetail
            WHERE batch_id = @batchId
            ORDER BY detail_id ASC
"@ -Parameters @{ batchId = [long]$batchId }

        $s = $summary[0]
        $detailRows = @()
        foreach ($d in $details) {
            $detailRows += [PSCustomObject]@{
                detail_id        = [long]$d['detail_id']
                delete_order     = if ($d['delete_order']     -is [DBNull]) { $null } else { [string]$d['delete_order'] }
                table_name       = if ($d['table_name']       -is [DBNull]) { $null } else { [string]$d['table_name'] }
                pass_description = if ($d['pass_description'] -is [DBNull]) { $null } else { [string]$d['pass_description'] }
                rows_affected    = if ($d['rows_affected']    -is [DBNull]) { 0 } else { [long]$d['rows_affected'] }
                duration_ms      = if ($d['duration_ms']      -is [DBNull]) { 0 } else { [long]$d['duration_ms'] }
                status           = if ($d['status']           -is [DBNull]) { $null } else { [string]$d['status'] }
                error_message    = if ($d['error_message']    -is [DBNull]) { $null } else { [string]$d['error_message'] }
                created_dttm     = if ($d['created_dttm']     -is [DBNull]) { $null } else { $d['created_dttm'].ToString("yyyy-MM-dd HH:mm:ss") }
            }
        }

        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            Summary = [PSCustomObject]@{
                batch_id           = [long]$s['batch_id']
                batch_start_dttm   = if ($s['batch_start_dttm']   -is [DBNull]) { $null } else { $s['batch_start_dttm'].ToString("yyyy-MM-dd HH:mm:ss") }
                batch_end_dttm     = if ($s['batch_end_dttm']     -is [DBNull]) { $null } else { $s['batch_end_dttm'].ToString("yyyy-MM-dd HH:mm:ss") }
                schedule_mode      = if ($s['schedule_mode']      -is [DBNull]) { $null } else { [string]$s['schedule_mode'] }
                batch_size_used    = if ($s['batch_size_used']    -is [DBNull]) { 0 } else { [int]$s['batch_size_used'] }
                consumer_count     = if ($s['consumer_count']     -is [DBNull]) { 0 } else { [long]$s['consumer_count'] }
                account_count      = if ($s['account_count']      -is [DBNull]) { 0 } else { [long]$s['account_count'] }
                total_rows_deleted = if ($s['total_rows_deleted'] -is [DBNull]) { 0 } else { [long]$s['total_rows_deleted'] }
                exception_count    = if ($s['exception_count']    -is [DBNull]) { 0 } else { [int]$s['exception_count'] }
                tables_processed   = if ($s['tables_processed']   -is [DBNull]) { 0 } else { [int]$s['tables_processed'] }
                tables_skipped     = if ($s['tables_skipped']     -is [DBNull]) { 0 } else { [int]$s['tables_skipped'] }
                tables_failed      = if ($s['tables_failed']      -is [DBNull]) { 0 } else { [int]$s['tables_failed'] }
                duration_ms        = if ($s['duration_ms']        -is [DBNull]) { 0 } else { [long]$s['duration_ms'] }
                status             = if ($s['status']             -is [DBNull]) { $null } else { [string]$s['status'] }
                error_message      = if ($s['error_message']      -is [DBNull]) { $null } else { [string]$s['error_message'] }
                batch_retry        = if ($s['batch_retry']        -is [DBNull]) { 0 } else { [int]$s['batch_retry'] }
                retry_batch_id     = if ($s['retry_batch_id']     -is [DBNull]) { $null } else { [long]$s['retry_batch_id'] }
                bidata_status      = if ($s['bidata_status']      -is [DBNull]) { $null } else { [string]$s['bidata_status'] }
                executed_by        = if ($s['executed_by']        -is [DBNull]) { $null } else { [string]$s['executed_by'] }
            }
            Details = $detailRows
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# GET /api/dmops/shellpurge/batch-detail/:batchId
# Returns ShellPurge_BatchDetail rows for a specific batch, with the batch
# summary for the slide-out header.
Add-PodeRoute -Method Get -Path '/api/dmops/shellpurge/batch-detail/:batchId' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        $batchId = $WebEvent.Parameters['batchId']
        if ([string]::IsNullOrEmpty($batchId)) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Missing batchId" }) -StatusCode 400
            return
        }

        $summary = Invoke-XFActsQuery -Query @"
            SELECT
                batch_id, batch_start_dttm, batch_end_dttm,
                schedule_mode, batch_size_used,
                consumer_count, total_rows_deleted,
                tables_processed, tables_skipped, tables_failed,
                duration_ms, status, error_message,
                executed_by
            FROM DmOps.ShellPurge_BatchLog
            WHERE batch_id = @batchId
"@ -Parameters @{ batchId = [long]$batchId }

        if (-not $summary -or $summary.Count -eq 0) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Batch not found: $batchId" }) -StatusCode 404
            return
        }

        $details = Invoke-XFActsQuery -Query @"
            SELECT
                detail_id, batch_id, delete_order, table_name, pass_description,
                rows_affected, duration_ms, status, error_message, created_dttm
            FROM DmOps.ShellPurge_BatchDetail
            WHERE batch_id = @batchId
            ORDER BY detail_id ASC
"@ -Parameters @{ batchId = [long]$batchId }

        $s = $summary[0]
        $detailRows = @()
        foreach ($d in $details) {
            $detailRows += [PSCustomObject]@{
                detail_id        = [long]$d['detail_id']
                delete_order     = if ($d['delete_order']     -is [DBNull]) { $null } else { [string]$d['delete_order'] }
                table_name       = if ($d['table_name']       -is [DBNull]) { $null } else { [string]$d['table_name'] }
                pass_description = if ($d['pass_description'] -is [DBNull]) { $null } else { [string]$d['pass_description'] }
                rows_affected    = if ($d['rows_affected']    -is [DBNull]) { 0 } else { [long]$d['rows_affected'] }
                duration_ms      = if ($d['duration_ms']      -is [DBNull]) { 0 } else { [long]$d['duration_ms'] }
                status           = if ($d['status']           -is [DBNull]) { $null } else { [string]$d['status'] }
                error_message    = if ($d['error_message']    -is [DBNull]) { $null } else { [string]$d['error_message'] }
                created_dttm     = if ($d['created_dttm']     -is [DBNull]) { $null } else { $d['created_dttm'].ToString("yyyy-MM-dd HH:mm:ss") }
            }
        }

        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            Summary = [PSCustomObject]@{
                batch_id           = [long]$s['batch_id']
                batch_start_dttm   = if ($s['batch_start_dttm']   -is [DBNull]) { $null } else { $s['batch_start_dttm'].ToString("yyyy-MM-dd HH:mm:ss") }
                batch_end_dttm     = if ($s['batch_end_dttm']     -is [DBNull]) { $null } else { $s['batch_end_dttm'].ToString("yyyy-MM-dd HH:mm:ss") }
                schedule_mode      = if ($s['schedule_mode']      -is [DBNull]) { $null } else { [string]$s['schedule_mode'] }
                batch_size_used    = if ($s['batch_size_used']    -is [DBNull]) { 0 } else { [int]$s['batch_size_used'] }
                consumer_count     = if ($s['consumer_count']     -is [DBNull]) { 0 } else { [long]$s['consumer_count'] }
                total_rows_deleted = if ($s['total_rows_deleted'] -is [DBNull]) { 0 } else { [long]$s['total_rows_deleted'] }
                tables_processed   = if ($s['tables_processed']   -is [DBNull]) { 0 } else { [int]$s['tables_processed'] }
                tables_skipped     = if ($s['tables_skipped']     -is [DBNull]) { 0 } else { [int]$s['tables_skipped'] }
                tables_failed      = if ($s['tables_failed']      -is [DBNull]) { 0 } else { [int]$s['tables_failed'] }
                duration_ms        = if ($s['duration_ms']        -is [DBNull]) { 0 } else { [long]$s['duration_ms'] }
                status             = if ($s['status']             -is [DBNull]) { $null } else { [string]$s['status'] }
                error_message      = if ($s['error_message']      -is [DBNull]) { $null } else { [string]$s['error_message'] }
                executed_by        = if ($s['executed_by']        -is [DBNull]) { $null } else { [string]$s['executed_by'] }
            }
            Details = $detailRows
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# GET /api/dmops/archive/schedule
# Returns the 7x24 archive schedule grid (tinyint: 0=blocked, 1=full, 2=reduced).
Add-PodeRoute -Method Get -Path '/api/dmops/archive/schedule' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        $rows = Invoke-XFActsQuery -Query @"
            SELECT
                day_of_week,
                hr00, hr01, hr02, hr03, hr04, hr05, hr06, hr07,
                hr08, hr09, hr10, hr11, hr12, hr13, hr14, hr15,
                hr16, hr17, hr18, hr19, hr20, hr21, hr22, hr23
            FROM DmOps.Archive_Schedule
            ORDER BY day_of_week
"@

        $schedule = @()
        foreach ($row in $rows) {
            $daySchedule = [PSCustomObject]@{
                DayOfWeek = [int]$row['day_of_week']
            }
            for ($h = 0; $h -lt 24; $h++) {
                $col = "hr" + $h.ToString("00")
                $daySchedule | Add-Member -NotePropertyName "Hr$($h.ToString('00'))" -NotePropertyValue ([int]$row[$col])
            }
            $schedule += $daySchedule
        }

        Write-PodeJsonResponse -Value $schedule
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# GET /api/dmops/shellpurge/schedule
# Returns the 7x24 shell purge schedule grid (tinyint: 0=blocked, 1=full, 2=reduced).
Add-PodeRoute -Method Get -Path '/api/dmops/shellpurge/schedule' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        $rows = Invoke-XFActsQuery -Query @"
            SELECT
                day_of_week,
                hr00, hr01, hr02, hr03, hr04, hr05, hr06, hr07,
                hr08, hr09, hr10, hr11, hr12, hr13, hr14, hr15,
                hr16, hr17, hr18, hr19, hr20, hr21, hr22, hr23
            FROM DmOps.ShellPurge_Schedule
            ORDER BY day_of_week
"@

        $schedule = @()
        foreach ($row in $rows) {
            $daySchedule = [PSCustomObject]@{
                DayOfWeek = [int]$row['day_of_week']
            }
            for ($h = 0; $h -lt 24; $h++) {
                $col = "hr" + $h.ToString("00")
                $daySchedule | Add-Member -NotePropertyName "Hr$($h.ToString('00'))" -NotePropertyValue ([int]$row[$col])
            }
            $schedule += $daySchedule
        }

        Write-PodeJsonResponse -Value $schedule
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# POST /api/dmops/schedule/update-batch
# Updates multiple hour cells in either the Archive or ShellPurge schedule
# atomically in a single transactional batch.
# Body: { Process: 'archive'|'shellpurge', Updates: [{ DayOfWeek, Hour, Value }, ...] }
# Value: 0=blocked, 1=full, 2=reduced
Add-PodeRoute -Method Post -Path '/api/dmops/schedule/update-batch' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        $body = $WebEvent.Data
        $process = $body.Process
        $updates = $body.Updates

        if ($process -ne 'archive' -and $process -ne 'shellpurge') {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Invalid process: $process" }) -StatusCode 400
            return
        }

        if (-not $updates -or $updates.Count -eq 0) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "No updates provided" }) -StatusCode 400
            return
        }

        $tableName = if ($process -eq 'archive') { 'DmOps.Archive_Schedule' } else { 'DmOps.ShellPurge_Schedule' }

        $currentUser = "FAC\$($WebEvent.Auth.User.Username)"

        # Build one transactional batch that applies every cell update in a
        # single round trip. Each update contributes its own parameterized
        # statement; the surrounding transaction preserves all-or-nothing
        # semantics. Hour and day are validated before use; the hour column
        # name and the table name are validated identifiers.
        $statements = [System.Collections.ArrayList]::new()
        $parameters = @{
            ModifiedBy = $currentUser
        }

        $i = 0
        foreach ($update in $updates) {
            $dayOfWeek = [int]$update.DayOfWeek
            $hour      = [int]$update.Hour
            $value     = [int]$update.Value

            if ($dayOfWeek -lt 1 -or $dayOfWeek -gt 7) {
                Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Invalid day of week: $dayOfWeek" }) -StatusCode 400
                return
            }
            if ($hour -lt 0 -or $hour -gt 23) {
                Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Invalid hour: $hour" }) -StatusCode 400
                return
            }
            if ($value -lt 0 -or $value -gt 2) {
                Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Invalid value: $value (must be 0, 1, or 2)" }) -StatusCode 400
                return
            }

            $hourColumn = "hr" + $hour.ToString("00")
            $valueParam = "Value$i"
            $dayParam   = "Day$i"

            [void]$statements.Add(@"
    UPDATE $tableName
    SET $hourColumn = @$valueParam,
        modified_dttm = GETDATE(),
        modified_by = @ModifiedBy
    WHERE day_of_week = @$dayParam;
"@)
            $parameters[$valueParam] = $value
            $parameters[$dayParam]   = $dayOfWeek
            $i++
        }

        $batchBody = $statements -join "`n"
        $query = @"
SET XACT_ABORT ON;
BEGIN TRANSACTION;
$batchBody
COMMIT TRANSACTION;
"@

        $rowsAffected = Invoke-XFActsNonQuery -Query $query -Parameters $parameters

        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            Success      = $true
            Process      = $process
            UpdateCount  = $updates.Count
            RowsAffected = $rowsAffected
            ModifiedBy   = $currentUser
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# GET /api/dmops/target-servers
# Returns the configured target_instance for Archive and ShellPurge along with
# the environment classification from ServerRegistry. Used by the page header
# to display per-process environment badges (TEST / PROD / Unknown). Read-only,
# no caching -- the values change rarely but should reflect the current
# GlobalConfig immediately when admins update them.
Add-PodeRoute -Method Get -Path '/api/dmops/target-servers' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        $rows = Invoke-XFActsQuery -Query @"
            SELECT
                gc.category    AS process_category,
                gc.setting_value AS server_name,
                sr.environment AS environment
            FROM dbo.GlobalConfig gc
            LEFT JOIN dbo.ServerRegistry sr ON sr.server_name = gc.setting_value
            WHERE gc.module_name = 'DmOps'
              AND gc.category IN ('Archive', 'ShellPurge')
              AND gc.setting_name = 'target_instance'
              AND gc.is_active = 1
"@

        $archive = [PSCustomObject]@{ Server = $null; Environment = $null }
        $shell   = [PSCustomObject]@{ Server = $null; Environment = $null }

        if ($rows) {
            foreach ($r in $rows) {
                $cat    = [string]$r['process_category']
                $server = if ($r['server_name'] -is [DBNull]) { $null } else { [string]$r['server_name'] }
                $env    = if ($r['environment'] -is [DBNull]) { $null } else { [string]$r['environment'] }

                if ($cat -eq 'Archive') {
                    $archive.Server      = $server
                    $archive.Environment = $env
                }
                elseif ($cat -eq 'ShellPurge') {
                    $shell.Server      = $server
                    $shell.Environment = $env
                }
            }
        }

        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            Archive    = $archive
            ShellPurge = $shell
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# POST /api/dmops/abort
# Toggles the abort flag for archive or shell purge. Updates the GlobalConfig
# setting_value and logs the change to ActionAuditLog.
# Body: { Process: 'archive'|'shellpurge', Abort: true|false }
Add-PodeRoute -Method Post -Path '/api/dmops/abort' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        $body = $WebEvent.Data
        $process = $body.Process
        $abort = [bool]$body.Abort

        $settingName = switch ($process) {
            'archive'    { 'archive_abort' }
            'shellpurge' { 'shell_purge_abort' }
            default {
                Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Invalid process: $process" }) -StatusCode 400
                return
            }
        }

        $category = switch ($process) {
            'archive'    { 'Archive' }
            'shellpurge' { 'ShellPurge' }
        }

        $abortValue = if ($abort) { '1' } else { '0' }
        $user = "FAC\$($WebEvent.Auth.User.Username)"

        # Look up current config_id and value for change logging
        $currentSetting = Invoke-XFActsQuery -Query @"
            SELECT config_id, setting_value
            FROM dbo.GlobalConfig
            WHERE module_name = 'DmOps'
              AND category = @Category
              AND setting_name = @SettingName
              AND is_active = 1
"@ -Parameters @{ Category = $category; SettingName = $settingName }

        if (-not $currentSetting -or $currentSetting.Count -eq 0) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "GlobalConfig setting not found: DmOps/$category/$settingName" }) -StatusCode 404
            return
        }

        $configId = [int]$currentSetting[0]['config_id']
        $oldValue = [string]$currentSetting[0]['setting_value']

        # Update the setting value
        Invoke-XFActsNonQuery -Query @"
            UPDATE dbo.GlobalConfig
            SET setting_value = @AbortValue
            WHERE config_id = @ConfigId
"@ -Parameters @{ AbortValue = $abortValue; ConfigId = $configId }

        # Log the change to ActionAuditLog
        $action = if ($abort) { "Activated" } else { "Cleared" }
        try {
            Invoke-XFActsNonQuery -Query @"
                INSERT INTO dbo.ActionAuditLog
                    (page_route, action_type, action_summary, result, executed_by)
                VALUES
                    ('/dm-operations', 'CONFIG_CHANGE', @summary, 'SUCCESS', @executedBy)
"@ -Parameters @{
                summary    = "$action $settingName (was: $oldValue, now: $abortValue)"
                executedBy = $user
            }
        } catch { }

        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            Success = $true
            Process = $process
            Abort   = $abort
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# POST /api/dmops/launch-process
# Admin-gated manual launch of the archive or shell purge execution script.
# Body: { Process: 'archive'|'shell' }
Add-PodeRoute -Method Post -Path '/api/dmops/launch-process' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        $body = $WebEvent.Data
        $processName = $body.Process

        $scriptMap = @{
            'archive' = 'Execute-DmConsumerArchive.ps1'
            'shell'   = 'Execute-DmShellPurge.ps1'
        }

        if (-not $scriptMap.ContainsKey($processName)) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Invalid process: $processName" }) -StatusCode 400
            return
        }

        $scriptPath = Join-Path 'E:\xFACts-PowerShell' $scriptMap[$processName]
        if (-not (Test-Path $scriptPath)) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Script not found: $($scriptMap[$processName])" }) -StatusCode 500
            return
        }

        $arguments = "-ExecutionPolicy Bypass -File `"$scriptPath`" -Execute"
        Start-Process -FilePath "powershell.exe" `
            -ArgumentList $arguments `
            -WorkingDirectory 'E:\xFACts-PowerShell' `
            -WindowStyle Hidden `
            -PassThru | Out-Null

        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            Success = $true
            Process = $processName
            Script  = $scriptMap[$processName]
            Message = "$processName launched successfully"
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}
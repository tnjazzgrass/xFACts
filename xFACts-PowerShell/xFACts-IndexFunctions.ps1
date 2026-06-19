<#
.SYNOPSIS
    Shared index-maintenance helper functions for the ServerOps.Index scripts.

.DESCRIPTION
    Scoped shared-function library for the Index Maintenance and Statistics
    Maintenance scripts. Provides abort-flag checking, three-tier schedule
    resolution (exception -> holiday -> database), available-window and
    maximum-weekday-window calculation, extended-window detection, best-fit
    index selection, and availability-group primary resolution. Dot-sourced by
    the standalone Index scripts after xFACts-OrchestratorFunctions.ps1.

.COMPONENT
    ServerOps.Index

.NOTES
    File Name : xFACts-IndexFunctions.ps1
    Location  : E:\xFACts-PowerShell\xFACts-IndexFunctions.ps1

    FILE ORGANIZATION
    -----------------
    CHANGELOG: CHANGE HISTORY
    FUNCTIONS: ABORT CONTROL
    FUNCTIONS: SCHEDULE RESOLUTION
    FUNCTIONS: WINDOW SELECTION
    FUNCTIONS: AVAILABILITY GROUP
#>

<# ============================================================================
   CHANGELOG: CHANGE HISTORY
   ----------------------------------------------------------------------------
   Date-driven change history for this shared library. Most-recent entry first.
   Prefix: (none)
   ============================================================================ #>

# 2026-06-19  Brought the file into PowerShell spec conformance. Rebuilt the
#             header to the comment-based-help form, moved change history into
#             this dedicated CHANGELOG section, added section banners, and
#             converted every function docblock to a single-line purpose
#             comment per the SCOPED-tier rules. Prefixed all functions with
#             idx_ and lifted Get-idx_AGPrimary in from the duplicate copies in
#             Execute-IndexMaintenance.ps1 and Update-IndexStatistics.ps1.
# 2026-03-10  Updated header to component-level versioning format.
#             ApplicationName references updated to $script:XFActsAppName.
# 2026-02-14  Orchestrator v2 standardization. Added
#             -SuppressProviderContextWarning -TrustServerCertificate.
#             Relocated to E:\xFACts-PowerShell.
# 2026-01-21  Table references updated to Index_* naming. GlobalConfig queries
#             now filter by module_name and category.
# 2026-01-14  Updated holiday logic for two-table architecture.
# 2026-01-13  Added Test-AbortRequested function.
# 2025-12-31  Initial implementation: Get-EffectiveSchedule, Get-AvailableMinutes,
#             Get-MaxWeekdayWindow, Test-IsExtendedWindow.

<# ============================================================================
   FUNCTIONS: ABORT CONTROL
   ----------------------------------------------------------------------------
   Graceful-abort flag checking against GlobalConfig for the Index scripts.
   Prefix: idx
   ============================================================================ #>

# Checks if an abort flag is set in GlobalConfig.
function Test-idx_AbortRequested {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ServerInstance,

        [Parameter(Mandatory=$true)]
        [string]$Database,

        [Parameter(Mandatory=$true)]
        [string]$SettingName
    )

    $abortQuery = @"
SELECT setting_value
FROM dbo.GlobalConfig
WHERE module_name = 'ServerOps'
  AND category = 'Index'
  AND setting_name = '$SettingName'
  AND is_active = 1
"@
    try {
        $result = Invoke-Sqlcmd -ServerInstance $ServerInstance -Database $Database -Query $abortQuery -QueryTimeout 10 -ApplicationName $script:XFActsAppName -ErrorAction Stop -SuppressProviderContextWarning -TrustServerCertificate
        if ($result -and $result.setting_value -eq '1') {
            return $true
        }
    }
    catch {
        # If we can't check, assume no abort (don't stop script on query failure)
        return $false
    }
    return $false
}

<# ============================================================================
   FUNCTIONS: SCHEDULE RESOLUTION
   ----------------------------------------------------------------------------
   Effective maintenance-schedule resolution and available-minutes calculation
   across the exception, holiday, and database-default tiers.
   Prefix: idx
   ============================================================================ #>

# Resolves the effective maintenance schedule for a database at a specific hour.
function Get-idx_EffectiveSchedule {
    param(
        [Parameter(Mandatory)]
        [string]$ServerInstance,

        [Parameter(Mandatory)]
        [string]$Database,

        [Parameter(Mandatory)]
        [int]$DatabaseId,

        [Parameter(Mandatory)]
        [int]$ServerId,

        [DateTime]$CheckDate = (Get-Date).Date,

        [int]$CheckHour = (Get-Date).Hour
    )

    $hourColumn = "hr{0:D2}" -f $CheckHour
    $dateString = $CheckDate.ToString("yyyy-MM-dd")

    # Convert PowerShell DayOfWeek to SQL convention
    # PowerShell: Sunday=0, Monday=1, ..., Saturday=6
    # SQL (our tables): Sunday=1, Monday=2, ..., Saturday=7
    $dayOfWeek = ([int]$CheckDate.DayOfWeek) + 1

    # Sunday=1, Saturday=7
    $isWeekend = $dayOfWeek -in @(1, 7)

    # Check 1: DATABASE-scope exception
    $query = @"
SELECT $hourColumn AS is_allowed
FROM ServerOps.Index_ExceptionSchedule
WHERE exception_date = '$dateString'
  AND scope = 'DATABASE'
  AND database_id = $DatabaseId
  AND is_enabled = 1
"@

    try {
        $result = Invoke-Sqlcmd -ServerInstance $ServerInstance -Database $Database -Query $query -QueryTimeout 30 -ApplicationName $script:XFActsAppName -ErrorAction Stop -SuppressProviderContextWarning -TrustServerCertificate
        if ($result) {
            return [PSCustomObject]@{
                IsAllowed = [bool]$result.is_allowed
                Source = 'EXCEPTION_DATABASE'
                DayOfWeek = $dayOfWeek
            }
        }
    }
    catch {
        Write-Warning "Schedule query failed: $($_.Exception.Message)"
    }

    # Check 2: SERVER-scope exception
    $query = @"
SELECT $hourColumn AS is_allowed
FROM ServerOps.Index_ExceptionSchedule
WHERE exception_date = '$dateString'
  AND scope = 'SERVER'
  AND server_id = $ServerId
  AND is_enabled = 1
"@

    try {
        $result = Invoke-Sqlcmd -ServerInstance $ServerInstance -Database $Database -Query $query -QueryTimeout 30 -ApplicationName $script:XFActsAppName -ErrorAction Stop -SuppressProviderContextWarning -TrustServerCertificate
        if ($result) {
            return [PSCustomObject]@{
                IsAllowed = [bool]$result.is_allowed
                Source = 'EXCEPTION_SERVER'
                DayOfWeek = $dayOfWeek
            }
        }
    }
    catch {
        Write-Warning "Schedule query failed: $($_.Exception.Message)"
    }

    # Check 3: GLOBAL exception
    $query = @"
SELECT $hourColumn AS is_allowed
FROM ServerOps.Index_ExceptionSchedule
WHERE exception_date = '$dateString'
  AND scope = 'GLOBAL'
  AND is_enabled = 1
"@

    try {
        $result = Invoke-Sqlcmd -ServerInstance $ServerInstance -Database $Database -Query $query -QueryTimeout 30 -ApplicationName $script:XFActsAppName -ErrorAction Stop -SuppressProviderContextWarning -TrustServerCertificate
        if ($result) {
            return [PSCustomObject]@{
                IsAllowed = [bool]$result.is_allowed
                Source = 'EXCEPTION_GLOBAL'
                DayOfWeek = $dayOfWeek
            }
        }
    }
    catch {
        Write-Warning "Schedule query failed: $($_.Exception.Message)"
    }

    # Check 4: Holiday (weekdays only)
    # Two-table design: dbo.Holiday (calendar) + ServerOps.Index_HolidaySchedule (per-database hours)
    if (-not $isWeekend) {
        # First check if today is a holiday in the calendar table
        $holidayCheckQuery = @"
SELECT holiday_name
FROM dbo.Holiday
WHERE holiday_date = '$dateString'
  AND is_active = 1
"@

        try {
            $holidayResult = Invoke-Sqlcmd -ServerInstance $ServerInstance -Database $Database -Query $holidayCheckQuery -QueryTimeout 30 -ApplicationName $script:XFActsAppName -ErrorAction Stop -SuppressProviderContextWarning -TrustServerCertificate
            if ($holidayResult) {
                # Today is a holiday - get this database's holiday schedule
                $scheduleQuery = @"
SELECT $hourColumn AS is_allowed
FROM ServerOps.Index_HolidaySchedule
WHERE database_id = $DatabaseId
"@
                $scheduleResult = Invoke-Sqlcmd -ServerInstance $ServerInstance -Database $Database -Query $scheduleQuery -QueryTimeout 30 -ApplicationName $script:XFActsAppName -ErrorAction Stop -SuppressProviderContextWarning -TrustServerCertificate
                if ($scheduleResult) {
                    return [PSCustomObject]@{
                        IsAllowed = [bool]$scheduleResult.is_allowed
                        Source = 'HOLIDAY'
                        DayOfWeek = $dayOfWeek
                    }
                }
                # Holiday exists but no holiday schedule for this database - fall through to default schedule
            }
        }
        catch {
            Write-Warning "Schedule query failed: $($_.Exception.Message)"
        }
    }

    # Check 5: Database default schedule
    $query = @"
SELECT $hourColumn AS is_allowed
FROM ServerOps.Index_DatabaseSchedule
WHERE database_id = $DatabaseId
  AND day_of_week = $dayOfWeek
"@

    try {
        $result = Invoke-Sqlcmd -ServerInstance $ServerInstance -Database $Database -Query $query -QueryTimeout 30 -ApplicationName $script:XFActsAppName -ErrorAction Stop -SuppressProviderContextWarning -TrustServerCertificate
        if ($result) {
            return [PSCustomObject]@{
                IsAllowed = [bool]$result.is_allowed
                Source = 'DATABASE_SCHEDULE'
                DayOfWeek = $dayOfWeek
            }
        }
    }
    catch {
        Write-Warning "Schedule query failed: $($_.Exception.Message)"
    }

    # No schedule found
    return [PSCustomObject]@{
        IsAllowed = $false
        Source = 'NO_SCHEDULE'
        DayOfWeek = $dayOfWeek
    }
}

# Calculates minutes available until the next blocked hour.
function Get-idx_AvailableMinutes {
    param(
        [Parameter(Mandatory)]
        [string]$ServerInstance,

        [Parameter(Mandatory)]
        [string]$Database,

        [Parameter(Mandatory)]
        [int]$DatabaseId,

        [Parameter(Mandatory)]
        [int]$ServerId,

        [DateTime]$FromDateTime = (Get-Date),

        [int]$MaxLookAheadHours = 24
    )

    # Check if current hour is allowed
    $currentSchedule = Get-idx_EffectiveSchedule -ServerInstance $ServerInstance -Database $Database `
        -DatabaseId $DatabaseId -ServerId $ServerId `
        -CheckDate $FromDateTime.Date -CheckHour $FromDateTime.Hour

    if (-not $currentSchedule.IsAllowed) {
        return 0
    }

    # Calculate minutes remaining in current hour
    $minutesInCurrentHour = 60 - $FromDateTime.Minute

    # Look ahead hour by hour
    $totalMinutes = $minutesInCurrentHour
    $checkTime = $FromDateTime.Date.AddHours($FromDateTime.Hour + 1)

    for ($i = 1; $i -lt $MaxLookAheadHours; $i++) {
        $schedule = Get-idx_EffectiveSchedule -ServerInstance $ServerInstance -Database $Database `
            -DatabaseId $DatabaseId -ServerId $ServerId `
            -CheckDate $checkTime.Date -CheckHour $checkTime.Hour

        if (-not $schedule.IsAllowed) {
            break
        }

        $totalMinutes += 60
        $checkTime = $checkTime.AddHours(1)
    }

    return $totalMinutes
}

<# ============================================================================
   FUNCTIONS: WINDOW SELECTION
   ----------------------------------------------------------------------------
   Maximum-weekday-window calculation, extended-window detection, and best-fit
   selection of queued indexes that fit the available maintenance window.
   Prefix: idx
   ============================================================================ #>

# Calculates the largest contiguous maintenance window across all weekdays.
function Get-idx_MaxWeekdayWindow {
    param(
        [Parameter(Mandatory)]
        [string]$ServerInstance,

        [Parameter(Mandatory)]
        [string]$Database,

        [Parameter(Mandatory)]
        [int]$DatabaseId
    )

    # Query all weekday schedules for this database
    $query = @"
SELECT
    day_of_week,
    hr00, hr01, hr02, hr03, hr04, hr05, hr06, hr07, hr08, hr09, hr10, hr11,
    hr12, hr13, hr14, hr15, hr16, hr17, hr18, hr19, hr20, hr21, hr22, hr23
FROM ServerOps.Index_DatabaseSchedule
WHERE database_id = $DatabaseId
  AND day_of_week BETWEEN 2 AND 6  -- Monday through Friday
ORDER BY day_of_week
"@

    try {
        $schedules = Invoke-Sqlcmd -ServerInstance $ServerInstance -Database $Database -Query $query -QueryTimeout 30 -ApplicationName $script:XFActsAppName -ErrorAction Stop -SuppressProviderContextWarning -TrustServerCertificate
    }
    catch {
        Write-Warning "Failed to query weekday schedules: $($_.Exception.Message)"
        return 0
    }

    if (-not $schedules) {
        return 0
    }

    $maxWindow = 0

    foreach ($day in $schedules) {
        # Build array of hour values
        $hours = @(
            $day.hr00, $day.hr01, $day.hr02, $day.hr03, $day.hr04, $day.hr05,
            $day.hr06, $day.hr07, $day.hr08, $day.hr09, $day.hr10, $day.hr11,
            $day.hr12, $day.hr13, $day.hr14, $day.hr15, $day.hr16, $day.hr17,
            $day.hr18, $day.hr19, $day.hr20, $day.hr21, $day.hr22, $day.hr23
        )

        # Find longest contiguous run of 1s
        $currentRun = 0
        $longestRun = 0

        foreach ($hour in $hours) {
            if ($hour -eq 1) {
                $currentRun++
                if ($currentRun -gt $longestRun) {
                    $longestRun = $currentRun
                }
            }
            else {
                $currentRun = 0
            }
        }

        # Convert hours to minutes and track max
        $windowMinutes = $longestRun * 60
        if ($windowMinutes -gt $maxWindow) {
            $maxWindow = $windowMinutes
        }
    }

    return $maxWindow
}

# Determines if today qualifies as an extended maintenance window day.
function Test-idx_IsExtendedWindow {
    param(
        [Parameter(Mandatory)]
        [string]$ServerInstance,

        [Parameter(Mandatory)]
        [string]$Database,

        [DateTime]$CheckDate = (Get-Date).Date
    )

    # Convert to SQL convention
    $dayOfWeek = ([int]$CheckDate.DayOfWeek) + 1
    # Sunday=1, Saturday=7
    $isWeekend = $dayOfWeek -in @(1, 7)

    if ($isWeekend) {
        return [PSCustomObject]@{
            IsExtended = $true
            Reason = 'WEEKEND'
            DayOfWeek = $dayOfWeek
        }
    }

    # Check for holiday in the calendar table
    $dateString = $CheckDate.ToString("yyyy-MM-dd")
    $query = @"
SELECT holiday_name
FROM dbo.Holiday
WHERE holiday_date = '$dateString'
  AND is_active = 1
"@

    try {
        $result = Invoke-Sqlcmd -ServerInstance $ServerInstance -Database $Database -Query $query -QueryTimeout 30 -ApplicationName $script:XFActsAppName -ErrorAction Stop -SuppressProviderContextWarning -TrustServerCertificate
        if ($result) {
            return [PSCustomObject]@{
                IsExtended = $true
                Reason = 'HOLIDAY'
                DayOfWeek = $dayOfWeek
                HolidayName = $result.holiday_name
            }
        }
    }
    catch {
        Write-Warning "Holiday check failed: $($_.Exception.Message)"
    }

    return [PSCustomObject]@{
        IsExtended = $false
        Reason = 'WEEKDAY'
        DayOfWeek = $dayOfWeek
    }
}

# Selects indexes from the queue that fit within the available time window.
function Get-idx_IndexesForWindow {
    param(
        [Parameter(Mandatory)]
        [string]$ServerInstance,

        [Parameter(Mandatory)]
        [string]$Database,

        [Parameter(Mandatory)]
        [int]$DatabaseId,

        [Parameter(Mandatory)]
        [int]$AvailableMinutes,

        [Parameter(Mandatory)]
        [int]$MaxWeekdayMinutes,

        [Parameter(Mandatory)]
        [bool]$IsExtendedWindow,

        [Parameter(Mandatory)]
        [bool]$UseOnlineEstimate
    )

    $estimateColumn = if ($UseOnlineEstimate) { 'estimated_seconds_online' } else { 'estimated_seconds_offline' }

    # Get all pending/deferred indexes for this database, ordered by priority
    $query = @"
SELECT
    q.queue_id,
    q.registry_id,
    q.schema_name,
    q.table_name,
    q.index_name,
    q.page_count,
    q.fragmentation_pct,
    q.$estimateColumn AS estimated_seconds,
    q.operation_type,
    q.online_option,
    q.status,
    q.deferral_count,
    q.priority_score,
    dc.index_maintenance_priority
FROM ServerOps.Index_Queue q
JOIN dbo.DatabaseRegistry dr ON q.database_id = dr.database_id
LEFT JOIN ServerOps.Index_DatabaseConfig dc ON q.database_id = dc.database_id
WHERE q.database_id = $DatabaseId
  AND q.status IN ('PENDING', 'DEFERRED', 'SCHEDULED', 'FAILED')
ORDER BY
    q.priority_score DESC,
    dc.index_maintenance_priority ASC,
    q.page_count DESC
"@

    try {
        $allIndexes = Invoke-Sqlcmd -ServerInstance $ServerInstance -Database $Database -Query $query -QueryTimeout 60 -ApplicationName $script:XFActsAppName -ErrorAction Stop -SuppressProviderContextWarning -TrustServerCertificate
    }
    catch {
        Write-Warning "Failed to query index queue: $($_.Exception.Message)"
        return @()
    }

    if (-not $allIndexes) {
        return @()
    }

    $selectedIndexes = @()
    $scheduledIndexes = @()
    # SCHEDULED indexes that didn't fit even in extended window
    $deferredScheduledIndexes = @()
    $availableSeconds = $AvailableMinutes * 60
    $maxWeekdaySeconds = $MaxWeekdayMinutes * 60
    $usedSeconds = 0

    foreach ($index in $allIndexes) {
        $estimatedSeconds = [int]$index.estimated_seconds

        # Handle SCHEDULED status
        if ($index.status -eq 'SCHEDULED') {
            if ($IsExtendedWindow) {
                # Extended window - SCHEDULED indexes are eligible
                # They'll be processed below like any other
            }
            else {
                # Not extended window - skip SCHEDULED indexes
                continue
            }
        }

        # Check if index can EVER fit on a weekday
        if (-not $IsExtendedWindow -and $estimatedSeconds -gt $maxWeekdaySeconds) {
            # This index is too large for any weekday window - mark for SCHEDULED
            $scheduledIndexes += $index
            continue
        }

        # Check if index fits in remaining time (best-fit for both weekday and extended)
        if (($usedSeconds + $estimatedSeconds) -le $availableSeconds) {
            $selectedIndexes += $index
            $usedSeconds += $estimatedSeconds
        }
        else {
            # Doesn't fit - track SCHEDULED indexes that couldn't fit even in extended window
            if ($IsExtendedWindow -and $index.status -eq 'SCHEDULED') {
                $deferredScheduledIndexes += $index
            }
            # Continue checking - a smaller one might fit (best-fit algorithm)
        }
    }

    # Return results
    return [PSCustomObject]@{
        SelectedIndexes = $selectedIndexes
        ScheduledIndexes = $scheduledIndexes
        # SCHEDULED that didn't fit - increment deferral_count
        DeferredScheduledIndexes = $deferredScheduledIndexes
        TotalEstimatedSeconds = $usedSeconds
        AvailableSeconds = $availableSeconds
    }
}

<# ============================================================================
   FUNCTIONS: AVAILABILITY GROUP
   ----------------------------------------------------------------------------
   Availability-group primary-replica resolution for selecting the write target.
   Prefix: idx
   ============================================================================ #>

# Resolves the current PRIMARY replica server for an availability group listener.
function Get-idx_AGPrimary {
    param(
        [string]$ListenerName
    )

    $query = @"
SELECT ar.replica_server_name
FROM sys.dm_hadr_availability_group_states ags
JOIN sys.availability_replicas ar ON ags.group_id = ar.group_id
WHERE ags.primary_replica = ar.replica_server_name
"@

    try {
        $result = Invoke-Sqlcmd -ServerInstance $ListenerName -Database "master" -Query $query -QueryTimeout 10 -ApplicationName $script:XFActsAppName -ErrorAction Stop -SuppressProviderContextWarning -TrustServerCertificate
        if ($result) {
            return $result.replica_server_name
        }
    }
    catch {
        Write-Log "Could not detect AG primary for $ListenerName : $($_.Exception.Message)" "WARN"
    }
    return $null
}
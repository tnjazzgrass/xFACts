<#
.SYNOPSIS
    xFACts - Shared Index Maintenance Functions

.DESCRIPTION
    xFACts - ServerOps.Index
    Script: xFACts-IndexFunctions.ps1
    Version: Tracked in dbo.System_Metadata (component: ServerOps.Index)

    Common functions used by Index Maintenance and Statistics Maintenance scripts:
    - Abort flag checking
    - Schedule evaluation (Exception → Holiday → Database precedence)
    - Available window calculation
    - Large window detection for SCHEDULED index handling
    
    Dot-source this file at the top of maintenance scripts:
    . "$PSScriptRoot\xFACts-IndexFunctions.ps1"

    CHANGELOG
    ---------
    2026-03-10  Updated header to component-level versioning format
                ApplicationName references updated to $script:XFActsAppName
    2026-02-14  Orchestrator v2 standardization
                Added -SuppressProviderContextWarning -TrustServerCertificate
                Relocated to E:\xFACts-PowerShell
    2026-01-21  xFACts Refactoring - Phase 3/8
                Table references updated to Index_* naming
                GlobalConfig queries now filter by module_name and category
    2026-01-14  Updated holiday logic for two-table architecture
    2026-01-13  Added Test-AbortRequested function
    2025-12-31  Initial implementation
                Get-EffectiveSchedule, Get-AvailableMinutes,
                Get-MaxWeekdayWindow, Test-IsExtendedWindow

================================================================================
#>

# ============================================================================
# ABORT FLAG CHECK
# ============================================================================

function Test-AbortRequested {
    <#
    .SYNOPSIS
        Checks if an abort flag is set in GlobalConfig.
    
    .DESCRIPTION
        Queries the specified setting in GlobalConfig and returns
        $true if it's set to '1'. Used for graceful script termination.
    
    .PARAMETER ServerInstance
        SQL Server instance hosting xFACts.
    
    .PARAMETER Database
        xFACts database name.
    
    .PARAMETER SettingName
        Config setting name to check.
        - 'index_scan_abort' for Scan-IndexFragmentation.ps1
        - 'index_execute_abort' for Execute-IndexMaintenance.ps1
    
    .OUTPUTS
        [bool] $true if abort flag is set to '1', $false otherwise.
    
    .EXAMPLE
        if (Test-AbortRequested -ServerInstance "AVG-PROD-LSNR" -Database "xFACts" -SettingName "index_execute_abort") {
            Write-Log "Abort requested - stopping gracefully"
            break
        }
    #>
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

# ============================================================================
# SCHEDULE EVALUATION FUNCTIONS
# ============================================================================

function Get-EffectiveSchedule {
    <#
    .SYNOPSIS
        Resolves the effective maintenance schedule for a database at a specific hour.
    
    .DESCRIPTION
        Evaluates the three-tier schedule hierarchy:
        1. Exception (DATABASE → SERVER → GLOBAL scope)
        2. Holiday (weekdays only) - checks dbo.Holiday for date,
           then ServerOps.Index_HolidaySchedule by database_id for hours
        3. Database default schedule
        
        Returns whether maintenance is allowed for the specified database/date/hour.
    
    .PARAMETER ServerInstance
        SQL Server instance hosting xFACts database.
    
    .PARAMETER Database
        xFACts database name.
    
    .PARAMETER DatabaseId
        The database_id from DatabaseRegistry.
    
    .PARAMETER ServerId
        The server_id from ServerRegistry.
    
    .PARAMETER CheckDate
        The date to check (defaults to today).
    
    .PARAMETER CheckHour
        The hour to check (0-23, defaults to current hour).
    
    .OUTPUTS
        PSCustomObject with:
        - IsAllowed: Boolean indicating if maintenance can run
        - Source: Where the schedule came from (EXCEPTION_DATABASE, EXCEPTION_SERVER, 
                  EXCEPTION_GLOBAL, HOLIDAY, DATABASE_SCHEDULE, NO_SCHEDULE)
        - DayOfWeek: Day of week for the checked date (1-7)
    
    .EXAMPLE
        Get-EffectiveSchedule -ServerInstance "AVG-PROD-LSNR" -Database "xFACts" -DatabaseId 1 -ServerId 1
        # Returns whether maintenance is allowed right now for database 1
    #>
    [CmdletBinding()]
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
    
    $isWeekend = $dayOfWeek -in @(1, 7)  # Sunday=1, Saturday=7
    
    # -------------------------------------------------------------------------
    # Check 1: DATABASE-scope exception
    # -------------------------------------------------------------------------
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
    
    # -------------------------------------------------------------------------
    # Check 2: SERVER-scope exception
    # -------------------------------------------------------------------------
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
    
    # -------------------------------------------------------------------------
    # Check 3: GLOBAL exception
    # -------------------------------------------------------------------------
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
    
    # -------------------------------------------------------------------------
    # Check 4: Holiday (weekdays only)
    # Two-table design: dbo.Holiday (calendar) + ServerOps.Index_HolidaySchedule (per-database hours)
    # -------------------------------------------------------------------------
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
    
    # -------------------------------------------------------------------------
    # Check 5: Database default schedule
    # -------------------------------------------------------------------------
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
    
    # -------------------------------------------------------------------------
    # No schedule found
    # -------------------------------------------------------------------------
    return [PSCustomObject]@{
        IsAllowed = $false
        Source = 'NO_SCHEDULE'
        DayOfWeek = $dayOfWeek
    }
}


function Get-AvailableMinutes {
    <#
    .SYNOPSIS
        Calculates minutes available until the next blocked hour.
    
    .DESCRIPTION
        Starting from the current time, looks ahead hour by hour to find when
        the maintenance window closes. Returns total available minutes.
        
        Does NOT include overrun tolerance - that's a safety buffer only.
    
    .PARAMETER ServerInstance
        SQL Server instance hosting xFACts database.
    
    .PARAMETER Database
        xFACts database name.
    
    .PARAMETER DatabaseId
        The database_id from DatabaseRegistry.
    
    .PARAMETER ServerId
        The server_id from ServerRegistry.
    
    .PARAMETER FromDateTime
        Starting datetime (defaults to now).
    
    .PARAMETER MaxLookAheadHours
        Maximum hours to look ahead (defaults to 24).
    
    .OUTPUTS
        Integer - available minutes until next blocked period.
        Returns 0 if current hour is blocked.
    
    .EXAMPLE
        Get-AvailableMinutes -ServerInstance "AVG-PROD-LSNR" -Database "xFACts" -ServerId 1 -DatabaseId 1
        # Returns minutes available starting now
    #>
    [CmdletBinding()]
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
    $currentSchedule = Get-EffectiveSchedule -ServerInstance $ServerInstance -Database $Database `
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
        $schedule = Get-EffectiveSchedule -ServerInstance $ServerInstance -Database $Database `
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


function Get-MaxWeekdayWindow {
    <#
    .SYNOPSIS
        Calculates the largest contiguous maintenance window across all weekdays.
    
    .DESCRIPTION
        Queries Index_DatabaseSchedule for days 2-6 (Monday-Friday) and
        finds the maximum contiguous block of allowed hours. Used to determine
        if an index can ever fit on a weekday.
    
    .PARAMETER ServerInstance
        SQL Server instance hosting xFACts database.
    
    .PARAMETER Database
        xFACts database name.
    
    .PARAMETER DatabaseId
        The database_id from DatabaseRegistry.
    
    .OUTPUTS
        Integer - maximum contiguous minutes available on any weekday.
        Returns 0 if no schedule exists.
    
    .EXAMPLE
        Get-MaxWeekdayWindow -ServerInstance "AVG-PROD-LSNR" -Database "xFACts" -DatabaseId 1
        # Returns 300 (5 hours) for crs5_oltp
    #>
    [CmdletBinding()]
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


function Test-IsExtendedWindow {
    <#
    .SYNOPSIS
        Determines if today qualifies as an extended maintenance window day.
    
    .DESCRIPTION
        Returns true if today is:
        - A weekend (Saturday or Sunday), OR
        - A holiday with an active entry in dbo.Holiday
        
        Used to determine whether SCHEDULED indexes should be reset to PENDING.
    
    .PARAMETER ServerInstance
        SQL Server instance hosting xFACts database.
    
    .PARAMETER Database
        xFACts database name.
    
    .PARAMETER CheckDate
        The date to check (defaults to today).
    
    .OUTPUTS
        PSCustomObject with:
        - IsExtended: Boolean indicating if this is an extended window day
        - Reason: WEEKEND, HOLIDAY, or WEEKDAY
        - DayOfWeek: Day of week (1-7)
        - HolidayName: Name of holiday (if applicable)
    
    .EXAMPLE
        Test-IsExtendedWindow -ServerInstance "AVG-PROD-LSNR" -Database "xFACts"
        # Returns whether today is a weekend or holiday
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ServerInstance,
        
        [Parameter(Mandatory)]
        [string]$Database,
        
        [DateTime]$CheckDate = (Get-Date).Date
    )
    
    $dayOfWeek = ([int]$CheckDate.DayOfWeek) + 1  # Convert to SQL convention
    $isWeekend = $dayOfWeek -in @(1, 7)  # Sunday=1, Saturday=7
    
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


function Get-IndexesForWindow {
    <#
    .SYNOPSIS
        Selects indexes from the queue that fit within the available time window.
    
    .DESCRIPTION
        Implements the "best fit" algorithm for weekday processing:
        1. Queries queue ordered by priority_score DESC
        2. Iterates through, selecting indexes whose estimated duration fits
        3. Skips indexes that don't fit but continues checking smaller ones
        4. Returns selected indexes in priority order for execution
        
        For extended windows (weekends/holidays), simply returns all eligible
        indexes in priority order.
    
    .PARAMETER ServerInstance
        SQL Server instance hosting xFACts database.
    
    .PARAMETER Database
        xFACts database name.
    
    .PARAMETER DatabaseId
        The database_id from DatabaseRegistry.
    
    .PARAMETER AvailableMinutes
        Minutes available in current window.
    
    .PARAMETER MaxWeekdayMinutes
        Maximum weekday window for this database (for SCHEDULED determination).
    
    .PARAMETER IsExtendedWindow
        Whether today is a weekend/holiday (changes algorithm).
    
    .PARAMETER UseOnlineEstimate
        Whether to use online (true) or offline (false) estimates.
    
    .OUTPUTS
        PSCustomObject with:
        - SelectedIndexes: Array of queue entries to execute this run
        - ScheduledIndexes: Indexes too large for any weekday window (mark SCHEDULED)
        - DeferredScheduledIndexes: SCHEDULED indexes that didn't fit even in extended window (increment deferral_count)
        - TotalEstimatedSeconds: Sum of estimated seconds for selected indexes
        - AvailableSeconds: Window size for reference
    
    .EXAMPLE
        Get-IndexesForWindow -ServerInstance "AVG-PROD-LSNR" -Database "xFACts" `
            -DatabaseId 1 -AvailableMinutes 300 -MaxWeekdayMinutes 300 `
            -IsExtendedWindow $false -UseOnlineEstimate $false
    #>
    [CmdletBinding()]
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
    $deferredScheduledIndexes = @()  # SCHEDULED indexes that didn't fit even in extended window
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
        DeferredScheduledIndexes = $deferredScheduledIndexes  # SCHEDULED that didn't fit - increment deferral_count
        TotalEstimatedSeconds = $usedSeconds
        AvailableSeconds = $availableSeconds
    }
}
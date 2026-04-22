<#
.SYNOPSIS
    xFACts - IBM Sterling B2B Integrator execution monitoring

.DESCRIPTION
    xFACts - B2B
    Script: Collect-B2BExecution.ps1

    Single collector for the B2B module. Synchronizes the schedule registry
    from b2bi.dbo.SCHEDULE, collects FA_CLIENTS_MAIN workflow executions from
    b2bi, enriches them with live-joined data from the Integration DB, and
    evaluates alert conditions.

    This script is being built in phases matching the B2B module's development
    plan:
      Block 1 (current) - Schedule sync into B2B.SI_ScheduleRegistry.
                          Fully implemented.
      Block 2 (future)  - Execution collection into B2B.SI_ExecutionTracking.
                          Currently stubbed.
      Block 3 (future)  - Detail extraction into B2B.SI_ExecutionDetail.
                          Currently stubbed.
      Phase 4 (future)  - Alert evaluation. Currently stubbed.

    Source server: FA-INT-DBP (b2bi database) via Windows auth.
    Target server: AVG-PROD-LSNR (xFACts database) via Windows auth.
    Integration enrichment server: AVG-PROD-LSNR (Integration database),
    live-joined in PowerShell via hashtable merge.

    CHANGELOG
    ---------
    2026-04-22  Initial implementation. Block 1 schedule sync complete;
                Block 2/3 steps stubbed.

.PARAMETER ServerInstance
    SQL Server instance hosting the xFACts database. Default: AVG-PROD-LSNR.

.PARAMETER Database
    xFACts database name. Default: xFACts.

.PARAMETER SourceInstance
    SQL Server instance hosting the b2bi database. Default: FA-INT-DBP.

.PARAMETER SourceDatabase
    b2bi database name. Default: b2bi.

.PARAMETER IntegrationDatabase
    Integration database name (on ServerInstance, via AG listener). Default: Integration.

.PARAMETER Execute
    Perform writes. Without this flag, runs in preview/dry-run mode.

.PARAMETER TaskId
    Orchestrator TaskLog ID passed by the engine at launch. Default 0.

.PARAMETER ProcessId
    Orchestrator ProcessRegistry ID passed by the engine at launch. Default 0.

.EXAMPLE
    .\Collect-B2BExecution.ps1
    Runs in preview mode.

.EXAMPLE
    .\Collect-B2BExecution.ps1 -Execute
    Runs and applies changes to the registry.

================================================================================
DEPLOYMENT REMINDERS
================================================================================
1. Service account must have read access to b2bi on FA-INT-DBP via Windows auth.
2. Service account must have read/write access to xFACts database on AVG-PROD-LSNR.
3. Required GlobalConfig entries (module = 'B2B', category = 'B2B'):
   - b2b_alerting_enabled (default: 0)
   - b2b_collect_lookback_days (default: 7) - applies to Block 2 execution
     collection; ignored in Block 1.
================================================================================
#>

[CmdletBinding()]
param(
    [string]$ServerInstance        = "AVG-PROD-LSNR",
    [string]$Database              = "xFACts",
    [string]$SourceInstance        = "FA-INT-DBP",
    [string]$SourceDatabase        = "b2bi",
    [string]$IntegrationDatabase   = "Integration",
    [switch]$Execute,
    [long]$TaskId                  = 0,
    [int]$ProcessId                = 0
)

$ErrorActionPreference = "Stop"

# ============================================================================
# STANDARD INITIALIZATION
# ============================================================================

. "$PSScriptRoot\xFACts-OrchestratorFunctions.ps1"

Initialize-XFActsScript -ScriptName 'Collect-B2BExecution' `
    -ServerInstance $ServerInstance -Database $Database -Execute:$Execute

# ============================================================================
# SCRIPT STATE
# ============================================================================

$Script:Config = @{}

# ============================================================================
# CONFIGURATION
# ============================================================================

function Initialize-Configuration {
    Write-Log "Loading configuration..." "INFO"

    # Defaults (also act as fallback if GlobalConfig row is missing)
    $Script:Config = @{
        B2B_AlertingEnabled     = $false
        B2B_CollectLookbackDays = 7
    }

    $configQuery = @"
SELECT setting_name, setting_value
FROM dbo.GlobalConfig
WHERE module_name = 'B2B' AND is_active = 1
"@

    $configResults = Get-SqlData -Query $configQuery
    if ($configResults) {
        foreach ($row in @($configResults)) {
            switch ($row.setting_name) {
                'b2b_alerting_enabled'      { $Script:Config.B2B_AlertingEnabled     = [bool][int]$row.setting_value }
                'b2b_collect_lookback_days' { $Script:Config.B2B_CollectLookbackDays = [int]$row.setting_value }
            }
        }
    }

    Write-Log "  B2B_AlertingEnabled:     $($Script:Config.B2B_AlertingEnabled)" "INFO"
    Write-Log "  B2B_CollectLookbackDays: $($Script:Config.B2B_CollectLookbackDays)" "INFO"
    Write-Log "  Source (b2bi):           $SourceInstance / $SourceDatabase" "INFO"
    Write-Log "  Target (xFACts):         $ServerInstance / $Database" "INFO"
    Write-Log "  Integration enrichment:  $ServerInstance / $IntegrationDatabase" "INFO"

    return $true
}

# ============================================================================
# TIMINGXML PARSER
# ============================================================================

function Expand-GzipBytes {
    <#
    .SYNOPSIS
        Decompresses a gzip byte array and returns the resulting UTF-8 string.
    #>
    param([byte[]]$Bytes)

    if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return $null }

    $ms = New-Object System.IO.MemoryStream(,$Bytes)
    try {
        $gz = New-Object System.IO.Compression.GZipStream($ms, [System.IO.Compression.CompressionMode]::Decompress)
        try {
            $sr = New-Object System.IO.StreamReader($gz)
            try {
                return $sr.ReadToEnd()
            }
            finally { $sr.Dispose() }
        }
        finally { $gz.Dispose() }
    }
    finally { $ms.Dispose() }
}

function Format-HHMM {
    <#
    .SYNOPSIS
        Formats a 4-digit HHMM string as HH:MM. Returns input unchanged if not 4 digits.
    #>
    param([string]$Value)
    if ($Value -match '^\d{4}$') {
        return "{0}:{1}" -f $Value.Substring(0,2), $Value.Substring(2,2)
    }
    return $Value
}

function Get-DayMaskFromWeekDays {
    <#
    .SYNOPSIS
        Builds the CHAR(7) day mask string from a set of ofWeek integer values.
        Sterling day numbering: 1=Sun, 2=Mon, 3=Tue, 4=Wed, 5=Thu, 6=Fri, 7=Sat.
        Mask position order: Sun-Mon-Tue-Wed-Thu-Fri-Sat.
        Letters: S/M/T/W/T/F/S if that day is active, '-' otherwise.
    #>
    param([int[]]$WeekDays)

    $letters = @('S','M','T','W','T','F','S')
    $mask    = [char[]]('-','-','-','-','-','-','-')

    foreach ($d in $WeekDays) {
        if ($d -ge 1 -and $d -le 7) {
            $mask[$d - 1] = $letters[$d - 1]
        }
    }
    return -join $mask
}

function Get-WeekDayRangeText {
    <#
    .SYNOPSIS
        Given a day mask, returns a human-readable day string for the schedule
        description. Collapses contiguous runs into ranges.
    #>
    param([string]$Mask)

    if ($Mask -eq 'SMTWTFS') { return 'daily' }
    if ($Mask -eq '-MTWTF-') { return 'Mon-Fri' }
    if ($Mask -eq 'S-----S') { return 'Sat-Sun' }

    $names = @('Sun','Mon','Tue','Wed','Thu','Fri','Sat')
    $active = @()
    for ($i = 0; $i -lt 7; $i++) {
        if ($Mask[$i] -ne '-') { $active += $names[$i] }
    }

    if ($active.Count -eq 0) { return '(no days)' }
    if ($active.Count -eq 1) { return $active[0] }
    if ($active.Count -eq 7) { return 'daily' }
    return ($active -join ', ')
}

function ConvertTo-ParsedSchedule {
    <#
    .SYNOPSIS
        Parses a decompressed TIMINGXML string into the structured field
        hashtable expected by SI_ScheduleRegistry.

    .DESCRIPTION
        Returns a hashtable with all 12 parsed columns, the pattern type
        classification, and the generated schedule_description. On parse
        failure, returns the UNKNOWN fallback set with schedule_description
        pointing to the raw timing_xml column for manual inspection.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Xml
    )

    # Default fallback shape (used on parse failure or unrecognized pattern)
    $result = @{
        timing_pattern_type   = 'UNKNOWN'
        run_day_mask          = $null
        run_days_of_month     = $null
        run_times_explicit    = $null
        run_interval_minutes  = $null
        run_range_start       = $null
        run_range_end         = $null
        run_on_minute         = $null
        excluded_dates        = $null
        first_run_time_of_day = $null
        last_run_time_of_day  = $null
        expected_runs_per_day = $null
        schedule_description  = 'Unrecognized timing pattern; see raw timing_xml column'
    }

    try {
        [xml]$doc = $Xml
    }
    catch {
        return $result
    }

    # Root element can be <timingxml> or <TimingXML>; pick whichever exists
    $root = $doc.timingxml
    if ($null -eq $root) { $root = $doc.TimingXML }
    if ($null -eq $root) { return $result }

    # ------------------------------------------------------------------
    # Parse <day> elements
    # ------------------------------------------------------------------
    $weekDays      = New-Object System.Collections.Generic.List[int]
    $monthDays     = New-Object System.Collections.Generic.List[int]
    $explicitTimes = New-Object System.Collections.Generic.List[string]   # HHMM strings
    $rangeStart    = $null
    $rangeEnd      = $null
    $intervalMin   = $null
    $onMinuteVal   = $null
    $dayCount      = 0
    $usesTimeRange = $false
    $usesExplicit  = $false

    if ($null -ne $root.days -and $null -ne $root.days.day) {
        foreach ($day in @($root.days.day)) {
            $dayCount++

            # Day specifier: ofWeek or ofMonth
            $ofWeek  = $day.ofWeek
            $ofMonth = $day.ofMonth

            if (-not [string]::IsNullOrWhiteSpace($ofWeek)) {
                $w = 0
                if ([int]::TryParse($ofWeek, [ref]$w)) {
                    if ($w -eq -1) {
                        # Every day: set all positions
                        foreach ($i in 1..7) { if (-not $weekDays.Contains($i)) { $weekDays.Add($i) } }
                    }
                    elseif ($w -ge 1 -and $w -le 7) {
                        if (-not $weekDays.Contains($w)) { $weekDays.Add($w) }
                    }
                }
            }
            elseif (-not [string]::IsNullOrWhiteSpace($ofMonth)) {
                $m = 0
                if ([int]::TryParse($ofMonth, [ref]$m)) {
                    if ($m -ge 1 -and $m -le 31 -and -not $monthDays.Contains($m)) {
                        $monthDays.Add($m)
                    }
                }
            }

            # Time specifiers under this day: <time> and/or <timeRange>
            if ($null -ne $day.times) {
                # <time> entries
                if ($null -ne $day.times.time) {
                    foreach ($t in @($day.times.time)) {
                        $tv = if ($t -is [string]) { $t } else { $t.'#text' }
                        if ($tv -match '^\d{4}$') {
                            $explicitTimes.Add($tv)
                            $usesExplicit = $true
                        }
                    }
                }
                # <timeRange> entry (taking first occurrence; grammar shows one per day)
                if ($null -ne $day.times.timeRange) {
                    $tr = $day.times.timeRange
                    $usesTimeRange = $true
                    if ($tr.range -match '^(\d{4})-(\d{4})$') {
                        $rangeStart = $Matches[1]
                        $rangeEnd   = $Matches[2]
                    }
                    $iv = 0
                    if ([int]::TryParse($tr.interval, [ref]$iv)) { $intervalMin = $iv }
                    $om = 0
                    if ([int]::TryParse($tr.onMinute, [ref]$om)) { $onMinuteVal = $om }
                }
            }
        }
    }

    # ------------------------------------------------------------------
    # Parse <excludedDates>
    # ------------------------------------------------------------------
    $excluded = New-Object System.Collections.Generic.List[string]
    if ($null -ne $root.excludedDates -and $null -ne $root.excludedDates.date) {
        foreach ($d in @($root.excludedDates.date)) {
            $dv = if ($d -is [string]) { $d } else { $d.'#text' }
            if ($dv -match '^\d{2}-\d{2}$') { $excluded.Add($dv) }
        }
    }

    # ------------------------------------------------------------------
    # Can we classify this pattern?
    # ------------------------------------------------------------------
    $hasWeekDays  = ($weekDays.Count -gt 0)
    $hasMonthDays = ($monthDays.Count -gt 0)

    # Reject unparseable combinations
    if ($dayCount -eq 0)                               { return $result }
    if ($hasWeekDays -and $hasMonthDays)               { return $result }  # mixed day specifiers not supported
    if ($usesTimeRange -and $usesExplicit)             { return $result }  # mixed time specifiers not supported
    if (-not $usesTimeRange -and -not $usesExplicit)   { return $result }  # no times at all

    # ------------------------------------------------------------------
    # Classify pattern type
    # ------------------------------------------------------------------
    $patternType = 'UNKNOWN'
    $dayMask     = $null
    $dayMonthStr = $null

    if ($hasMonthDays) {
        $patternType = 'MONTHLY'
        $sortedMonth = $monthDays | Sort-Object
        $dayMonthStr = ($sortedMonth -join ',')
    }
    elseif ($hasWeekDays) {
        $dayMask = Get-DayMaskFromWeekDays -WeekDays $weekDays.ToArray()

        if ($usesTimeRange) {
            # INTERVAL = every day; MIXED = specific days
            if ($dayMask -eq 'SMTWTFS') { $patternType = 'INTERVAL' }
            else                        { $patternType = 'MIXED' }
        }
        else {
            # Explicit times; DAILY = every day; WEEKLY = specific days
            if ($dayMask -eq 'SMTWTFS') { $patternType = 'DAILY' }
            else                        { $patternType = 'WEEKLY' }
        }
    }

    # ------------------------------------------------------------------
    # Assemble column values
    # ------------------------------------------------------------------
    $result.timing_pattern_type  = $patternType
    $result.run_day_mask         = $dayMask
    $result.run_days_of_month    = $dayMonthStr
    $result.run_on_minute        = $onMinuteVal

    if ($excluded.Count -gt 0) {
        $result.excluded_dates = ($excluded | Sort-Object -Unique) -join ','
    }

    # Times (deduplicate + sort explicit times)
    $sortedTimes = @()
    if ($usesExplicit) {
        $sortedTimes = $explicitTimes | Sort-Object -Unique
        $result.run_times_explicit = ($sortedTimes | ForEach-Object { Format-HHMM -Value $_ }) -join ','
    }

    if ($usesTimeRange) {
        $result.run_range_start      = Format-HHMM -Value $rangeStart
        $result.run_range_end        = Format-HHMM -Value $rangeEnd
        $result.run_interval_minutes = $intervalMin
    }

    # First/last run times and expected_runs_per_day
    if ($usesExplicit -and $sortedTimes.Count -gt 0) {
        $result.first_run_time_of_day = Format-HHMM -Value $sortedTimes[0]
        $result.last_run_time_of_day  = Format-HHMM -Value $sortedTimes[-1]
        $result.expected_runs_per_day = $sortedTimes.Count
    }
    elseif ($usesTimeRange -and $rangeStart -and $rangeEnd -and $intervalMin -gt 0) {
        $result.first_run_time_of_day = Format-HHMM -Value $rangeStart
        $result.last_run_time_of_day  = Format-HHMM -Value $rangeEnd

        # Minutes from start to end, inclusive
        $startMin = ([int]$rangeStart.Substring(0,2) * 60) + [int]$rangeStart.Substring(2,2)
        $endMin   = ([int]$rangeEnd.Substring(0,2)   * 60) + [int]$rangeEnd.Substring(2,2)
        $spanMin  = $endMin - $startMin
        if ($spanMin -ge 0 -and $intervalMin -gt 0) {
            $result.expected_runs_per_day = [math]::Floor($spanMin / $intervalMin) + 1
        }
    }

    # ------------------------------------------------------------------
    # Build schedule_description
    # ------------------------------------------------------------------
    $description = ''

    switch ($patternType) {
        'DAILY' {
            $timesText = ($sortedTimes | ForEach-Object { Format-HHMM -Value $_ }) -join ', '
            if ($sortedTimes.Count -eq 1) {
                $description = "Daily at $timesText"
            }
            else {
                $description = "Daily at $timesText"
            }
        }
        'WEEKLY' {
            $dayText   = Get-WeekDayRangeText -Mask $dayMask
            $timesText = ($sortedTimes | ForEach-Object { Format-HHMM -Value $_ }) -join ', '
            $description = "$dayText at $timesText"
        }
        'MONTHLY' {
            $dayLabel = if ($sortedMonth.Count -eq 1) { "Day $($sortedMonth[0]) of month" } else { "Days $($sortedMonth -join ', ') of month" }
            $timesText = ($sortedTimes | ForEach-Object { Format-HHMM -Value $_ }) -join ', '
            $description = "$dayLabel at $timesText"
        }
        'INTERVAL' {
            $startHM = Format-HHMM -Value $rangeStart
            $endHM   = Format-HHMM -Value $rangeEnd
            $minuteMarker = if ($startHM -match ':(\d{2})$') { ":$($Matches[1])" } else { '' }
            $minuteText = if ($minuteMarker) { " at $minuteMarker" } else { '' }
            $description = "Every $intervalMin min$minuteText, $startHM-$endHM, daily"
        }
        'MIXED' {
            $dayText = Get-WeekDayRangeText -Mask $dayMask
            $startHM = Format-HHMM -Value $rangeStart
            $endHM   = Format-HHMM -Value $rangeEnd
            $minuteMarker = if ($startHM -match ':(\d{2})$') { ":$($Matches[1])" } else { '' }
            $minuteText = if ($minuteMarker) { " at $minuteMarker" } else { '' }
            $description = "Every $intervalMin min$minuteText, $startHM-$endHM, $dayText"
        }
    }

    if ($excluded.Count -gt 0 -and $description) {
        $description = "$description (excl. $($result.excluded_dates))"
    }

    if ($description) { $result.schedule_description = $description }

    return $result
}

# ============================================================================
# STEP 1 — SCHEDULE SYNC (Block 1, fully implemented)
# ============================================================================

function Step-SyncSchedules {
    <#
    .SYNOPSIS
        Synchronizes B2B.SI_ScheduleRegistry from b2bi.dbo.SCHEDULE.

    .DESCRIPTION
        1. Pulls every SCHEDULE row and its TIMINGXML blob in a single JOIN.
        2. Decompresses each blob and parses into structured columns.
        3. Compares to the existing registry and issues per-row INSERT/UPDATE.
        4. Deletes registry rows for schedule_ids no longer present in b2bi.
    #>
    param([bool]$PreviewOnly = $true)

    Write-Log "Step: Sync Schedules" "STEP"

    $inserted = 0
    $updated  = 0
    $deleted  = 0
    $errors   = 0

    try {
        # --------------------------------------------------------------
        # Pull all schedules + their TIMINGXML blobs in one query.
        # --------------------------------------------------------------
        $sourceQuery = @"
SELECT
    s.SCHEDULEID,
    s.SERVICENAME,
    s.SCHEDULETYPE,
    s.SCHEDULETYPEID,
    s.EXECUTIONTIMER,
    s.STATUS,
    s.EXECUTIONSTATUS,
    s.TIMINGXML,
    s.SYSTEMNAME,
    s.USERID,
    dt.DATA_OBJECT AS TIMING_BLOB
FROM dbo.SCHEDULE s
LEFT JOIN dbo.DATA_TABLE dt
    ON dt.DATA_ID = s.TIMINGXML
WHERE s.TIMINGXML IS NOT NULL
  AND s.TIMINGXML <> ''
ORDER BY s.SCHEDULEID
"@

        $sourceRows = Get-SqlData -Query $sourceQuery `
                                  -Instance $SourceInstance `
                                  -DatabaseName $SourceDatabase `
                                  -MaxCharLength 2147483647

        if (-not $sourceRows) {
            Write-Log "  No schedules returned from $SourceInstance/$SourceDatabase (or query failed)" "WARN"
            return @{ Inserted = 0; Updated = 0; Deleted = 0; Errors = 1 }
        }

        $sourceRows = @($sourceRows)
        Write-Log "  Fetched $($sourceRows.Count) schedule(s) from b2bi" "INFO"

        # --------------------------------------------------------------
        # Load existing registry snapshot for comparison.
        # --------------------------------------------------------------
        $existingQuery = @"
SELECT schedule_id, timing_xml_handle, source_status, execution_status
FROM B2B.SI_ScheduleRegistry
"@
        $existingRows = Get-SqlData -Query $existingQuery
        $existing     = @{}
        if ($existingRows) {
            foreach ($r in @($existingRows)) {
                $existing[[int]$r.schedule_id] = @{
                    handle    = $r.timing_xml_handle
                    source    = $r.source_status
                    execution = $r.execution_status
                }
            }
        }

        Write-Log "  Existing registry rows: $($existing.Count)" "INFO"

        # --------------------------------------------------------------
        # Decompress, parse, and upsert each source row.
        # --------------------------------------------------------------
        $sourceIds = New-Object System.Collections.Generic.HashSet[int]

        foreach ($row in $sourceRows) {
            $scheduleId = [int]$row.SCHEDULEID
            $sourceIds.Add($scheduleId) | Out-Null

            # Decompress TIMINGXML
            if ($row.TIMING_BLOB -is [DBNull] -or $null -eq $row.TIMING_BLOB) {
                Write-Log "  Schedule $scheduleId ($($row.SERVICENAME)): no TIMINGXML blob in DATA_TABLE, skipping" "WARN"
                $errors++
                continue
            }

            $timingXml = $null
            try {
                $timingXml = Expand-GzipBytes -Bytes ([byte[]]$row.TIMING_BLOB)
            }
            catch {
                Write-Log "  Schedule $scheduleId ($($row.SERVICENAME)): decompression failed — $($_.Exception.Message)" "ERROR"
                $errors++
                continue
            }

            if ([string]::IsNullOrWhiteSpace($timingXml)) {
                Write-Log "  Schedule $scheduleId ($($row.SERVICENAME)): empty decompressed content, skipping" "WARN"
                $errors++
                continue
            }

            # Parse TIMINGXML
            $parsed = ConvertTo-ParsedSchedule -Xml $timingXml

            # Decide INSERT vs UPDATE vs no-op
            $handle   = [string]$row.TIMINGXML
            $srcStat  = [string]$row.STATUS
            $execStat = [string]$row.EXECUTIONSTATUS

            if (-not $existing.ContainsKey($scheduleId)) {
                # INSERT
                if ($PreviewOnly) {
                    Write-Log "  [Preview] Would INSERT schedule $scheduleId ($($row.SERVICENAME)) — $($parsed.schedule_description)" "INFO"
                    $inserted++
                }
                else {
                    $ok = Invoke-ScheduleInsert -Row $row -Parsed $parsed -TimingXml $timingXml
                    if ($ok) {
                        Write-Log "  INSERT schedule $scheduleId ($($row.SERVICENAME)) — $($parsed.schedule_description)" "SUCCESS"
                        $inserted++
                    }
                    else {
                        $errors++
                    }
                }
            }
            else {
                # UPDATE only if something meaningful changed
                $prev = $existing[$scheduleId]
                $handleChanged    = ($prev.handle    -ne $handle)
                $sourceChanged    = ($prev.source    -ne $srcStat)
                $executionChanged = ($prev.execution -ne $execStat)

                if ($handleChanged -or $sourceChanged -or $executionChanged) {
                    if ($PreviewOnly) {
                        $reason = @()
                        if ($handleChanged)    { $reason += 'timing_xml_handle' }
                        if ($sourceChanged)    { $reason += 'source_status' }
                        if ($executionChanged) { $reason += 'execution_status' }
                        Write-Log "  [Preview] Would UPDATE schedule $scheduleId ($($row.SERVICENAME)) — changed: $($reason -join ', ')" "INFO"
                        $updated++
                    }
                    else {
                        $ok = Invoke-ScheduleUpdate -Row $row -Parsed $parsed -TimingXml $timingXml
                        if ($ok) {
                            $reason = @()
                            if ($handleChanged)    { $reason += 'timing_xml_handle' }
                            if ($sourceChanged)    { $reason += 'source_status' }
                            if ($executionChanged) { $reason += 'execution_status' }
                            Write-Log "  UPDATE schedule $scheduleId ($($row.SERVICENAME)) — changed: $($reason -join ', ')" "SUCCESS"
                            $updated++
                        }
                        else {
                            $errors++
                        }
                    }
                }
                # else: no change — no log, no work
            }
        }

        # --------------------------------------------------------------
        # DELETE registry rows no longer present in b2bi.
        # --------------------------------------------------------------
        foreach ($id in $existing.Keys) {
            if (-not $sourceIds.Contains($id)) {
                if ($PreviewOnly) {
                    Write-Log "  [Preview] Would DELETE schedule $id (no longer in b2bi)" "INFO"
                    $deleted++
                }
                else {
                    $delQuery = "DELETE FROM B2B.SI_ScheduleRegistry WHERE schedule_id = $id"
                    $ok = Invoke-SqlNonQuery -Query $delQuery
                    if ($ok) {
                        Write-Log "  DELETE schedule $id (no longer in b2bi)" "SUCCESS"
                        $deleted++
                    }
                    else {
                        $errors++
                    }
                }
            }
        }

        Write-Log "  Summary: inserted=$inserted updated=$updated deleted=$deleted errors=$errors" "INFO"
        return @{ Inserted = $inserted; Updated = $updated; Deleted = $deleted; Errors = $errors }
    }
    catch {
        Write-Log "  Error in Step-SyncSchedules: $($_.Exception.Message)" "ERROR"
        return @{ Inserted = $inserted; Updated = $updated; Deleted = $deleted; Errors = ($errors + 1); Error = $_.Exception.Message }
    }
}

function Format-SqlStringLiteral {
    <#
    .SYNOPSIS
        Returns a SQL literal for a string value, or 'NULL' for null/empty.
    #>
    param([string]$Value, [switch]$AllowEmpty)

    if ($null -eq $Value) { return 'NULL' }
    if (-not $AllowEmpty -and [string]::IsNullOrEmpty($Value)) { return 'NULL' }
    return "N'" + ($Value -replace "'", "''") + "'"
}

function Format-SqlIntLiteral {
    <#
    .SYNOPSIS
        Returns a SQL literal for an integer value, or 'NULL' for null.
    #>
    param($Value)

    if ($null -eq $Value) { return 'NULL' }
    if ($Value -is [DBNull]) { return 'NULL' }
    return "$Value"
}

function Invoke-ScheduleInsert {
    param(
        [Parameter(Mandatory)]$Row,
        [Parameter(Mandatory)][hashtable]$Parsed,
        [Parameter(Mandatory)][string]$TimingXml
    )

    $sql = @"
INSERT INTO B2B.SI_ScheduleRegistry (
    schedule_id, service_name, schedule_type, schedule_type_id, execution_timer,
    source_status, execution_status,
    timing_xml_handle, source_system_name, source_user_id,
    timing_pattern_type, run_day_mask, run_days_of_month, run_times_explicit,
    run_interval_minutes, run_range_start, run_range_end, run_on_minute,
    excluded_dates, first_run_time_of_day, last_run_time_of_day, expected_runs_per_day,
    schedule_description, timing_xml, last_modified_dttm
)
VALUES (
    $($Row.SCHEDULEID),
    $(Format-SqlStringLiteral $Row.SERVICENAME),
    $($Row.SCHEDULETYPE),
    $($Row.SCHEDULETYPEID),
    $($Row.EXECUTIONTIMER),
    $(Format-SqlStringLiteral $Row.STATUS -AllowEmpty),
    $(Format-SqlStringLiteral $Row.EXECUTIONSTATUS -AllowEmpty),
    $(Format-SqlStringLiteral $Row.TIMINGXML -AllowEmpty),
    $(Format-SqlStringLiteral $Row.SYSTEMNAME),
    $(Format-SqlStringLiteral $Row.USERID),
    $(Format-SqlStringLiteral $Parsed.timing_pattern_type),
    $(Format-SqlStringLiteral $Parsed.run_day_mask),
    $(Format-SqlStringLiteral $Parsed.run_days_of_month),
    $(Format-SqlStringLiteral $Parsed.run_times_explicit),
    $(Format-SqlIntLiteral   $Parsed.run_interval_minutes),
    $(Format-SqlStringLiteral $Parsed.run_range_start),
    $(Format-SqlStringLiteral $Parsed.run_range_end),
    $(Format-SqlIntLiteral   $Parsed.run_on_minute),
    $(Format-SqlStringLiteral $Parsed.excluded_dates),
    $(Format-SqlStringLiteral $Parsed.first_run_time_of_day),
    $(Format-SqlStringLiteral $Parsed.last_run_time_of_day),
    $(Format-SqlIntLiteral   $Parsed.expected_runs_per_day),
    $(Format-SqlStringLiteral $Parsed.schedule_description),
    $(Format-SqlStringLiteral $TimingXml -AllowEmpty),
    GETDATE()
)
"@

    return Invoke-SqlNonQuery -Query $sql -MaxCharLength 2147483647
}

function Invoke-ScheduleUpdate {
    param(
        [Parameter(Mandatory)]$Row,
        [Parameter(Mandatory)][hashtable]$Parsed,
        [Parameter(Mandatory)][string]$TimingXml
    )

    $sql = @"
UPDATE B2B.SI_ScheduleRegistry
SET service_name          = $(Format-SqlStringLiteral $Row.SERVICENAME),
    schedule_type         = $($Row.SCHEDULETYPE),
    schedule_type_id      = $($Row.SCHEDULETYPEID),
    execution_timer       = $($Row.EXECUTIONTIMER),
    source_status         = $(Format-SqlStringLiteral $Row.STATUS -AllowEmpty),
    execution_status      = $(Format-SqlStringLiteral $Row.EXECUTIONSTATUS -AllowEmpty),
    timing_xml_handle     = $(Format-SqlStringLiteral $Row.TIMINGXML -AllowEmpty),
    source_system_name    = $(Format-SqlStringLiteral $Row.SYSTEMNAME),
    source_user_id        = $(Format-SqlStringLiteral $Row.USERID),
    timing_pattern_type   = $(Format-SqlStringLiteral $Parsed.timing_pattern_type),
    run_day_mask          = $(Format-SqlStringLiteral $Parsed.run_day_mask),
    run_days_of_month     = $(Format-SqlStringLiteral $Parsed.run_days_of_month),
    run_times_explicit    = $(Format-SqlStringLiteral $Parsed.run_times_explicit),
    run_interval_minutes  = $(Format-SqlIntLiteral   $Parsed.run_interval_minutes),
    run_range_start       = $(Format-SqlStringLiteral $Parsed.run_range_start),
    run_range_end         = $(Format-SqlStringLiteral $Parsed.run_range_end),
    run_on_minute         = $(Format-SqlIntLiteral   $Parsed.run_on_minute),
    excluded_dates        = $(Format-SqlStringLiteral $Parsed.excluded_dates),
    first_run_time_of_day = $(Format-SqlStringLiteral $Parsed.first_run_time_of_day),
    last_run_time_of_day  = $(Format-SqlStringLiteral $Parsed.last_run_time_of_day),
    expected_runs_per_day = $(Format-SqlIntLiteral   $Parsed.expected_runs_per_day),
    schedule_description  = $(Format-SqlStringLiteral $Parsed.schedule_description),
    timing_xml            = $(Format-SqlStringLiteral $TimingXml -AllowEmpty),
    last_modified_dttm    = GETDATE()
WHERE schedule_id = $($Row.SCHEDULEID)
"@

    return Invoke-SqlNonQuery -Query $sql -MaxCharLength 2147483647
}

# ============================================================================
# STEP 2 — EXECUTION COLLECTION (Block 2, stubbed)
# ============================================================================

function Step-CollectExecutions {
    <#
    .SYNOPSIS
        [Block 2 - not yet implemented] Collects FA_CLIENTS_MAIN workflow runs
        from b2bi into B2B.SI_ExecutionTracking.

    .DESCRIPTION
        Intended behavior per the B2B architecture overview:
         - Pull WORKFLOW_IDs from b2bi.dbo.WF_INST_S for FA_CLIENTS_MAIN within
           the configured lookback window (GlobalConfig: b2b_collect_lookback_days).
         - Anti-join against SI_ExecutionTracking.workflow_id to exclude runs
           we've already captured AND marked complete (is_complete = 1).
         - Only fetch/decompress ProcessData for workflow_ids not yet seen or
           still in flight. Completed rows are never re-processed.
         - Write header-level rows into SI_ExecutionTracking with enrichment
           deferred to Step-EnrichFromIntegration.
    #>
    param([bool]$PreviewOnly = $true)

    Write-Log "Step: Collect Executions — [Block 2 stub]" "STEP"
    return @{ Collected = 0; Skipped = 0 }
}

# ============================================================================
# STEP 3 — INTEGRATION ENRICHMENT (Block 2, stubbed)
# ============================================================================

function Step-EnrichFromIntegration {
    <#
    .SYNOPSIS
        [Block 2 - not yet implemented] Live-joins Integration DB data onto
        captured execution rows and computes disagreement flags.

    .DESCRIPTION
        Intended behavior per the B2B architecture overview:
         - Bulk query Integration.ETL.tbl_B2B_CLIENTS_BATCH_STATUS for matching
           RUN_IDs against new/in-flight rows from SI_ExecutionTracking.
         - Bulk query Integration.ETL.tbl_B2B_CLIENTS_TICKETS for matching
           RUN_IDs.
         - In-memory hash-join in PowerShell (no linked server between b2bi
           and Integration, so all correlation happens here).
         - Compute int_status_missing, int_status_inconsistent, and
           alert_infrastructure_failure disagreement flags.
         - UPDATE SI_ExecutionTracking with int_* columns and flags.
    #>
    param([bool]$PreviewOnly = $true)

    Write-Log "Step: Enrich From Integration — [Block 2 stub]" "STEP"
    return @{ Enriched = 0 }
}

# ============================================================================
# STEP 4 — EXECUTION DETAIL EXTRACTION (Block 3, stubbed)
# ============================================================================

function Step-CollectExecutionDetail {
    <#
    .SYNOPSIS
        [Block 3 - not yet implemented] Extracts per-file/per-creditor detail
        from Translation output documents and writes to SI_ExecutionDetail.

    .DESCRIPTION
        Intended behavior per the B2B architecture overview:
         - Select SI_ExecutionTracking rows where has_detail_captured = 0.
         - For each, fetch the Translation output documents from
           b2bi.dbo.TRANS_DATA, decompress, parse the "skinny" output format
           (file-name header + account rows with balance and creditor keys).
         - INSERT detail rows into B2B.SI_ExecutionDetail.
         - Flip has_detail_captured = 1 on the parent row.
         - Self-throttling via the flag; doesn't re-scan completed rows.
    #>
    param([bool]$PreviewOnly = $true)

    Write-Log "Step: Collect Execution Detail — [Block 3 stub]" "STEP"
    return @{ Extracted = 0 }
}

# ============================================================================
# STEP 5 — ALERT EVALUATION (Phase 4, stubbed)
# ============================================================================

function Step-EvaluateAlerts {
    <#
    .SYNOPSIS
        [Phase 4 - not yet implemented] Evaluates alert conditions against
        captured execution data.

    .DESCRIPTION
        Alerting is disabled until the execution tracking pipeline is proven
        in production. Master switch: b2b_alerting_enabled GlobalConfig value.
        Alert conditions to be defined as execution patterns are understood.
    #>
    param([bool]$PreviewOnly = $true)

    Write-Log "Step: Evaluate Alerts — [Phase 4 stub]" "STEP"
    return @{ Detected = 0; Fired = 0 }
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

$scriptStart = Get-Date

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  xFACts B2B Execution Collector" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

if ($Execute) { Write-Log "Mode: EXECUTE (changes will be applied)" "WARN" }
else          { Write-Log "Mode: PREVIEW (no changes will be made)" "INFO" }
Write-Host ""

if (-not (Initialize-Configuration)) {
    Write-Log "Configuration initialization failed — exiting" "ERROR"

    if ($TaskId -gt 0) {
        $totalMs = [int]((Get-Date) - $scriptStart).TotalMilliseconds
        Complete-OrchestratorTask -TaskId $TaskId -ProcessId $ProcessId `
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

# Step 1 — Sync schedules (Block 1)
$stepResults.Schedules = Step-SyncSchedules -PreviewOnly $previewOnly

# Step 2 — Collect executions (Block 2 stub)
$stepResults.Executions = Step-CollectExecutions -PreviewOnly $previewOnly

# Step 3 — Integration enrichment (Block 2 stub)
$stepResults.Enrichment = Step-EnrichFromIntegration -PreviewOnly $previewOnly

# Step 4 — Execution detail (Block 3 stub)
$stepResults.Detail = Step-CollectExecutionDetail -PreviewOnly $previewOnly

# Step 5 — Alert evaluation (Phase 4 stub)
$stepResults.Alerts = Step-EvaluateAlerts -PreviewOnly $previewOnly

# ============================================================================
# SUMMARY
# ============================================================================

$scriptEnd = Get-Date
$totalMs   = [int]($scriptEnd - $scriptStart).TotalMilliseconds

$finalStatus = "SUCCESS"
if ($stepResults.Schedules.Error -or $stepResults.Schedules.Errors -gt 0) {
    $finalStatus = "FAILED"
}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Execution Summary" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Schedules:"
Write-Host "    Inserted: $($stepResults.Schedules.Inserted)"
Write-Host "    Updated:  $($stepResults.Schedules.Updated)"
Write-Host "    Deleted:  $($stepResults.Schedules.Deleted)"
Write-Host "    Errors:   $($stepResults.Schedules.Errors)"
Write-Host ""
Write-Host "  Duration: $totalMs ms"
Write-Host ""

if (-not $Execute) {
    Write-Host "  *** PREVIEW MODE — No changes were made ***" -ForegroundColor Yellow
    Write-Host "  Run with -Execute to perform actual updates" -ForegroundColor Yellow
    Write-Host ""
}

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  B2B Execution Collection Complete" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# Orchestrator callback
if ($TaskId -gt 0) {
    $output = "SchedInserted:$($stepResults.Schedules.Inserted) SchedUpdated:$($stepResults.Schedules.Updated) SchedDeleted:$($stepResults.Schedules.Deleted) Errors:$($stepResults.Schedules.Errors)"

    Complete-OrchestratorTask -TaskId $TaskId -ProcessId $ProcessId `
        -Status $finalStatus -DurationMs $totalMs `
        -Output $output
}

if ($finalStatus -eq "FAILED") { exit 1 } else { exit 0 }
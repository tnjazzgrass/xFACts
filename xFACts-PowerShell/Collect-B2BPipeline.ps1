<#
.SYNOPSIS
    xFACts - B2B pipeline collection

.DESCRIPTION
    Single collector for the B2B module. Synchronizes the schedule registry
    from b2bi.dbo.SCHEDULE, maintains the workflow definition catalog and
    version census in B2B.SI_WorkflowRegistry, and mirrors the Integration
    pipeline lifecycle tracker (ETL.tbl_B2B_CLIENTS_BATCH_STATUS) into
    B2B.INT_PipelineTracking with set-based T-SQL classification: enrichment
    from the Integration config tables, DM outcome verification against
    crs5_oltp, the BATCH_FILES pickup check for the status-4 split, and a
    b2bi runtime cross-check that detects runs that died without reaching a
    fault handler.

    Reads b2bi on FA-INT-DBP via Windows auth. Reads Integration, crs5_oltp,
    and xFACts through the AG listener; the mirror steps run as single
    cross-database statements on the listener so history and ongoing rows are
    classified by identical logic. Alert evaluation queues Teams alerts via
    the shared Send-TeamsAlert function for failure classifications and
    workflow version changes, gated by the b2b_alerting_enabled switch.

.PARAMETER ServerInstance
    SQL Server instance hosting the xFACts database. Default: AVG-PROD-LSNR.

.PARAMETER Database
    xFACts database name. Default: xFACts.

.PARAMETER SourceInstance
    SQL Server instance hosting the b2bi database. Default: FA-INT-DBP.

.PARAMETER SourceDatabase
    b2bi database name. Default: b2bi.

.PARAMETER IntegrationDatabase
    Integration database name on the listener. Default: Integration.

.PARAMETER DMDatabase
    Debt Manager database name on the listener. Default: crs5_oltp.

.PARAMETER Execute
    Perform writes. Without this flag, runs in preview/dry-run mode.

.PARAMETER TaskId
    Orchestrator TaskLog ID passed by the engine at launch. Default 0.

.PARAMETER ProcessId
    Orchestrator ProcessRegistry ID passed by the engine at launch. Default 0.

.COMPONENT
    B2B

.NOTES
    File Name : Collect-B2BPipeline.ps1
    Location  : E:\xFACts-PowerShell

    FILE ORGANIZATION
    -----------------
    CHANGELOG: CHANGE HISTORY
    PARAMETERS: SCRIPT PARAMETERS
    IMPORTS: SCRIPT DEPENDENCIES
    INITIALIZATION: SCRIPT INITIALIZATION
    FUNCTIONS: CONFIGURATION
    FUNCTIONS: SHARED HELPERS
    FUNCTIONS: SCHEDULE SYNC
    FUNCTIONS: WORKFLOW REGISTRY CENSUS
    FUNCTIONS: PIPELINE MIRROR
    FUNCTIONS: STERLING CROSS-CHECK
    FUNCTIONS: ALERT EVALUATION
    EXECUTION: SCRIPT EXECUTION
#>

<# ============================================================================
   CHANGELOG: CHANGE HISTORY
   ----------------------------------------------------------------------------
   Dated change history, most recent first. Authoritative version tracking
   lives in dbo.System_Metadata (component B2B).
   Prefix: (none)
   ============================================================================ #>

# 2026-07-12  Initial implementation, replacing Collect-B2BExecution.ps1 per the
#             B2B Roadmap section 7 decisions. Schedule sync (Block 1) carried
#             over from the retired collector. New: workflow registry census
#             into B2B.SI_WorkflowRegistry (version-change drift detection);
#             pipeline mirror into B2B.INT_PipelineTracking at the
#             BATCH_STATUS-row grain with set-based T-SQL classification (DM
#             verification for -1, BATCH_FILES pickup check for 4, dispatcher
#             rows terminal at 2); dispatcher name resolution from b2bi
#             linkage; Sterling WF_INST_S cross-check classifying aged
#             in-flight rows as DIED_UNHANDLED; Teams alert evaluation via
#             the shared Send-TeamsAlert function for failure classifications
#             and workflow version changes, gated by b2b_alerting_enabled and
#             bounded to the working window so backfilled history never
#             alerts.

# 2026-07-12  Execute-mode single-pass mirror steps: the insert and re-poll
#             DML now capture their own classification/completion facts via
#             OUTPUT into a table variable, replacing the separate pre-DML
#             breakdown queries and halving the per-cycle CTE evaluations.
#             Preview mode keeps its read-only breakdown queries. Logging
#             detail is unchanged.
# 2026-07-12  Classification refinement and CTE performance restructure from
#             the backfill profile review: -1 rows on process types with no DM
#             arm (non-NB/PAY/BDL) now classify STERLING_FAULT instead of
#             UNCLASSIFIED (the reconciler never writes -1 for those types, so
#             a -1 there is a Sterling fault regardless of BATCH_ID); the DM
#             joins are gated to BATCH_STATUS = -1 (the only population whose
#             classification reads DM evidence) and the BATCH_FILES pickup
#             EXISTS is gated to BATCH_STATUS = 4, eliminating per-row DM and
#             pickup work for the bulk of each cycle.

<# ============================================================================
   PARAMETERS: SCRIPT PARAMETERS
   ----------------------------------------------------------------------------
   Connection targets for the xFACts, b2bi, Integration, and Debt Manager
   databases, the Execute write-guard, and the orchestrator TaskId/ProcessId
   callback identifiers.
   Prefix: (none)
   ============================================================================ #>

[CmdletBinding()]
param(
    [string]$ServerInstance      = "AVG-PROD-LSNR",
    [string]$Database            = "xFACts",
    [string]$SourceInstance      = "FA-INT-DBP",
    [string]$SourceDatabase      = "b2bi",
    [string]$IntegrationDatabase = "Integration",
    [string]$DMDatabase          = "crs5_oltp",
    [switch]$Execute,
    [long]$TaskId                = 0,
    [int]$ProcessId              = 0
)

<# ============================================================================
   IMPORTS: SCRIPT DEPENDENCIES
   ----------------------------------------------------------------------------
   Shared orchestrator and script-infrastructure functions: initialization,
   logging, SQL access, and the completion callback.
   Prefix: (none)
   ============================================================================ #>

. "$PSScriptRoot\xFACts-OrchestratorFunctions.ps1"

<# ============================================================================
   INITIALIZATION: SCRIPT INITIALIZATION
   ----------------------------------------------------------------------------
   One-time startup: shared script-infrastructure init (SQL module load,
   application identity, log path).
   Prefix: (none)
   ============================================================================ #>

Initialize-XFActsScript -ScriptName 'Collect-B2BPipeline' `
    -ServerInstance $ServerInstance -Database $Database -Execute:$Execute

<# ============================================================================
   FUNCTIONS: CONFIGURATION
   ----------------------------------------------------------------------------
   Loads B2B GlobalConfig settings consumed by the mirror and cross-check
   steps.
   Prefix: b2b
   ============================================================================ #>

# Loads B2B config settings and logs the resolved values.
function Initialize-b2b_Config {
    param()

    Write-Log "Loading configuration..." "INFO"

    # Defaults (also act as fallback if GlobalConfig rows are missing)
    $script:Config = @{
        B2B_AlertingEnabled     = $false
        B2B_CollectLookbackDays = 3
        B2B_InFlightAgingMinutes = 720
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
                'b2b_alerting_enabled'      { $script:Config.B2B_AlertingEnabled     = [bool][int]$row.setting_value }
                'b2b_collect_lookback_days' { $script:Config.B2B_CollectLookbackDays = [int]$row.setting_value }
                'b2b_inflight_aging_minutes' { $script:Config.B2B_InFlightAgingMinutes = [int]$row.setting_value }
            }
        }
    }

    Write-Log "  B2B_AlertingEnabled:     $($script:Config.B2B_AlertingEnabled)" "INFO"
    Write-Log "  B2B_CollectLookbackDays: $($script:Config.B2B_CollectLookbackDays)" "INFO"
    Write-Log "  B2B_InFlightAgingMinutes: $($script:Config.B2B_InFlightAgingMinutes)" "INFO"
    Write-Log "  Source (b2bi):           $SourceInstance / $SourceDatabase" "INFO"
    Write-Log "  Mirror (listener):       $ServerInstance / $IntegrationDatabase + $DMDatabase -> $Database" "INFO"

    return $true
}

<# ============================================================================
   FUNCTIONS: SHARED HELPERS
   ----------------------------------------------------------------------------
   Low-level utilities shared across the steps: gzip decompression, SQL
   literal formatting by type, and schedule time/day formatting helpers.
   Prefix: b2b
   ============================================================================ #>

# Decompresses a gzip byte array and returns the resulting UTF-8 string.
function Expand-b2b_GzipBytes {
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

# Returns a SQL literal for a string value, or 'NULL' for null/empty.
function Format-b2b_SqlStringLiteral {
    param($Value, [switch]$AllowEmpty)

    if ($null -eq $Value) { return 'NULL' }
    if ($Value -is [DBNull]) { return 'NULL' }
    $s = [string]$Value
    if (-not $AllowEmpty -and [string]::IsNullOrEmpty($s)) { return 'NULL' }
    return "N'" + ($s -replace "'", "''") + "'"
}

# Returns a SQL literal for an integer value, or 'NULL' for null.
function Format-b2b_SqlIntLiteral {
    param($Value)

    if ($null -eq $Value) { return 'NULL' }
    if ($Value -is [DBNull]) { return 'NULL' }
    return "$Value"
}

# Returns a SQL literal for a DATETIME value, or 'NULL' for null.
function Format-b2b_SqlDateTimeLiteral {
    param($Value)

    if ($null -eq $Value) { return 'NULL' }
    if ($Value -is [DBNull]) { return 'NULL' }
    $dt = [datetime]$Value
    return "'" + $dt.ToString('yyyy-MM-dd HH:mm:ss.fff') + "'"
}

# Formats a 4-digit HHMM string as HH:MM; returns input unchanged if not 4 digits.
function Format-b2b_HHMM {
    param([string]$Value)
    if ($Value -match '^\d{4}$') {
        return "{0}:{1}" -f $Value.Substring(0,2), $Value.Substring(2,2)
    }
    return $Value
}

# Builds the CHAR(7) day-mask string from a set of Sterling ofWeek integers.
function Get-b2b_DayMaskFromWeekDays {
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

# Returns a human-readable day string for a day mask, collapsing runs into ranges.
function Get-b2b_WeekDayRangeText {
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

<# ============================================================================
   FUNCTIONS: SCHEDULE SYNC
   ----------------------------------------------------------------------------
   Parses Sterling TIMINGXML into structured schedule fields and synchronizes
   B2B.SI_ScheduleRegistry from b2bi.dbo.SCHEDULE (insert/update/delete).
   Carried over from the retired Collect-B2BExecution.ps1.
   Prefix: b2b
   ============================================================================ #>

# Parses a decompressed TIMINGXML string into the SI_ScheduleRegistry field hashtable.
function ConvertTo-b2b_ParsedSchedule {
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

    # Parse <day> elements
    $weekDays      = New-Object System.Collections.Generic.List[int]
    $monthDays     = New-Object System.Collections.Generic.List[int]
    # HHMM strings
    $explicitTimes = New-Object System.Collections.Generic.List[string]
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

    # Parse <excludedDates>
    $excluded = New-Object System.Collections.Generic.List[string]
    if ($null -ne $root.excludedDates -and $null -ne $root.excludedDates.date) {
        foreach ($d in @($root.excludedDates.date)) {
            $dv = if ($d -is [string]) { $d } else { $d.'#text' }
            if ($dv -match '^\d{2}-\d{2}$') { $excluded.Add($dv) }
        }
    }

    # Can we classify this pattern?
    $hasWeekDays  = ($weekDays.Count -gt 0)
    $hasMonthDays = ($monthDays.Count -gt 0)

    # Reject unparseable combinations
    if ($dayCount -eq 0)                               { return $result }
    if ($hasWeekDays -and $hasMonthDays)               { return $result }
    if ($usesTimeRange -and $usesExplicit)             { return $result }
    if (-not $usesTimeRange -and -not $usesExplicit)   { return $result }

    # Classify pattern type
    $patternType = 'UNKNOWN'
    $dayMask     = $null
    $dayMonthStr = $null

    if ($hasMonthDays) {
        $patternType = 'MONTHLY'
        $sortedMonth = $monthDays | Sort-Object
        $dayMonthStr = ($sortedMonth -join ',')
    }
    elseif ($hasWeekDays) {
        $dayMask = Get-b2b_DayMaskFromWeekDays -WeekDays $weekDays.ToArray()

        if ($usesTimeRange) {
            if ($dayMask -eq 'SMTWTFS') { $patternType = 'INTERVAL' }
            else                        { $patternType = 'MIXED' }
        }
        else {
            if ($dayMask -eq 'SMTWTFS') { $patternType = 'DAILY' }
            else                        { $patternType = 'WEEKLY' }
        }
    }

    # Assemble column values
    $result.timing_pattern_type  = $patternType
    $result.run_day_mask         = $dayMask
    $result.run_days_of_month    = $dayMonthStr
    $result.run_on_minute        = $onMinuteVal

    if ($excluded.Count -gt 0) {
        $result.excluded_dates = ($excluded | Sort-Object -Unique) -join ','
    }

    $sortedTimes = @()
    if ($usesExplicit) {
        $sortedTimes = $explicitTimes | Sort-Object -Unique
        $result.run_times_explicit = ($sortedTimes | ForEach-Object { Format-b2b_HHMM -Value $_ }) -join ','
    }

    if ($usesTimeRange) {
        $result.run_range_start      = Format-b2b_HHMM -Value $rangeStart
        $result.run_range_end        = Format-b2b_HHMM -Value $rangeEnd
        $result.run_interval_minutes = $intervalMin
    }

    if ($usesExplicit -and $sortedTimes.Count -gt 0) {
        $result.first_run_time_of_day = Format-b2b_HHMM -Value $sortedTimes[0]
        $result.last_run_time_of_day  = Format-b2b_HHMM -Value $sortedTimes[-1]
        $result.expected_runs_per_day = $sortedTimes.Count
    }
    elseif ($usesTimeRange -and $rangeStart -and $rangeEnd -and $intervalMin -gt 0) {
        $result.first_run_time_of_day = Format-b2b_HHMM -Value $rangeStart
        $result.last_run_time_of_day  = Format-b2b_HHMM -Value $rangeEnd

        $startMin = ([int]$rangeStart.Substring(0,2) * 60) + [int]$rangeStart.Substring(2,2)
        $endMin   = ([int]$rangeEnd.Substring(0,2)   * 60) + [int]$rangeEnd.Substring(2,2)
        $spanMin  = $endMin - $startMin
        if ($spanMin -ge 0 -and $intervalMin -gt 0) {
            $result.expected_runs_per_day = [math]::Floor($spanMin / $intervalMin) + 1
        }
    }

    # Build schedule_description
    $description = ''

    switch ($patternType) {
        'DAILY' {
            $timesText = ($sortedTimes | ForEach-Object { Format-b2b_HHMM -Value $_ }) -join ', '
            $description = "Daily at $timesText"
        }
        'WEEKLY' {
            $dayText   = Get-b2b_WeekDayRangeText -Mask $dayMask
            $timesText = ($sortedTimes | ForEach-Object { Format-b2b_HHMM -Value $_ }) -join ', '
            $description = "$dayText at $timesText"
        }
        'MONTHLY' {
            $dayLabel = if ($sortedMonth.Count -eq 1) { "Day $($sortedMonth[0]) of month" } else { "Days $($sortedMonth -join ', ') of month" }
            $timesText = ($sortedTimes | ForEach-Object { Format-b2b_HHMM -Value $_ }) -join ', '
            $description = "$dayLabel at $timesText"
        }
        'INTERVAL' {
            $startHM = Format-b2b_HHMM -Value $rangeStart
            $endHM   = Format-b2b_HHMM -Value $rangeEnd
            $minuteMarker = if ($startHM -match ':(\d{2})$') { ":$($Matches[1])" } else { '' }
            $minuteText = if ($minuteMarker) { " at $minuteMarker" } else { '' }
            $description = "Every $intervalMin min$minuteText, $startHM-$endHM, daily"
        }
        'MIXED' {
            $dayText = Get-b2b_WeekDayRangeText -Mask $dayMask
            $startHM = Format-b2b_HHMM -Value $rangeStart
            $endHM   = Format-b2b_HHMM -Value $rangeEnd
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

# Synchronizes B2B.SI_ScheduleRegistry from b2bi.dbo.SCHEDULE.
function Step-b2b_SyncSchedules {
    param([bool]$PreviewOnly = $true)

    Write-Log "Step: Sync Schedules" "STEP"

    $inserted = 0
    $updated  = 0
    $deleted  = 0
    $errors   = 0

    try {
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
                                  -MaxCharLength 2147483647 `
                                  -MaxBinaryLength 20971520

        if (-not $sourceRows) {
            Write-Log "  No schedules returned from $SourceInstance/$SourceDatabase (or query failed)" "WARN"
            return @{ Inserted = 0; Updated = 0; Deleted = 0; Errors = 1 }
        }

        $sourceRows = @($sourceRows)
        Write-Log "  Fetched $($sourceRows.Count) schedule(s) from b2bi" "INFO"

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

        $sourceIds = New-Object System.Collections.Generic.HashSet[int]

        foreach ($row in $sourceRows) {
            $scheduleId = [int]$row.SCHEDULEID
            $sourceIds.Add($scheduleId) | Out-Null

            if ($row.TIMING_BLOB -is [DBNull] -or $null -eq $row.TIMING_BLOB) {
                Write-Log "  Schedule $scheduleId ($($row.SERVICENAME)): no TIMINGXML blob in DATA_TABLE, skipping" "WARN"
                $errors++
                continue
            }

            $timingXml = $null
            try {
                $timingXml = Expand-b2b_GzipBytes -Bytes ([byte[]]$row.TIMING_BLOB)
            }
            catch {
                Write-Log "  Schedule $scheduleId ($($row.SERVICENAME)): decompression failed - $($_.Exception.Message)" "ERROR"
                $errors++
                continue
            }

            if ([string]::IsNullOrWhiteSpace($timingXml)) {
                Write-Log "  Schedule $scheduleId ($($row.SERVICENAME)): empty decompressed content, skipping" "WARN"
                $errors++
                continue
            }

            $parsed = ConvertTo-b2b_ParsedSchedule -Xml $timingXml

            $handle   = [string]$row.TIMINGXML
            $srcStat  = [string]$row.STATUS
            $execStat = [string]$row.EXECUTIONSTATUS

            if (-not $existing.ContainsKey($scheduleId)) {
                if ($PreviewOnly) {
                    Write-Log "  [Preview] Would INSERT schedule $scheduleId ($($row.SERVICENAME)) - $($parsed.schedule_description)" "INFO"
                    $inserted++
                }
                else {
                    $ok = Invoke-b2b_ScheduleInsert -Row $row -Parsed $parsed -TimingXml $timingXml
                    if ($ok) {
                        Write-Log "  INSERT schedule $scheduleId ($($row.SERVICENAME)) - $($parsed.schedule_description)" "SUCCESS"
                        $inserted++
                    }
                    else {
                        $errors++
                    }
                }
            }
            else {
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
                        Write-Log "  [Preview] Would UPDATE schedule $scheduleId ($($row.SERVICENAME)) - changed: $($reason -join ', ')" "INFO"
                        $updated++
                    }
                    else {
                        $ok = Invoke-b2b_ScheduleUpdate -Row $row -Parsed $parsed -TimingXml $timingXml
                        if ($ok) {
                            $reason = @()
                            if ($handleChanged)    { $reason += 'timing_xml_handle' }
                            if ($sourceChanged)    { $reason += 'source_status' }
                            if ($executionChanged) { $reason += 'execution_status' }
                            Write-Log "  UPDATE schedule $scheduleId ($($row.SERVICENAME)) - changed: $($reason -join ', ')" "SUCCESS"
                            $updated++
                        }
                        else {
                            $errors++
                        }
                    }
                }
            }
        }

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
        Write-Log "  Error in Step-b2b_SyncSchedules: $($_.Exception.Message)" "ERROR"
        return @{ Inserted = $inserted; Updated = $updated; Deleted = $deleted; Errors = ($errors + 1); Error = $_.Exception.Message }
    }
}

# Inserts a new SI_ScheduleRegistry row from a source schedule and parsed fields.
function Invoke-b2b_ScheduleInsert {
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
    $(Format-b2b_SqlStringLiteral $Row.SERVICENAME),
    $($Row.SCHEDULETYPE),
    $($Row.SCHEDULETYPEID),
    $($Row.EXECUTIONTIMER),
    $(Format-b2b_SqlStringLiteral $Row.STATUS -AllowEmpty),
    $(Format-b2b_SqlStringLiteral $Row.EXECUTIONSTATUS -AllowEmpty),
    $(Format-b2b_SqlStringLiteral $Row.TIMINGXML -AllowEmpty),
    $(Format-b2b_SqlStringLiteral $Row.SYSTEMNAME),
    $(Format-b2b_SqlStringLiteral $Row.USERID),
    $(Format-b2b_SqlStringLiteral $Parsed.timing_pattern_type),
    $(Format-b2b_SqlStringLiteral $Parsed.run_day_mask),
    $(Format-b2b_SqlStringLiteral $Parsed.run_days_of_month),
    $(Format-b2b_SqlStringLiteral $Parsed.run_times_explicit),
    $(Format-b2b_SqlIntLiteral   $Parsed.run_interval_minutes),
    $(Format-b2b_SqlStringLiteral $Parsed.run_range_start),
    $(Format-b2b_SqlStringLiteral $Parsed.run_range_end),
    $(Format-b2b_SqlIntLiteral   $Parsed.run_on_minute),
    $(Format-b2b_SqlStringLiteral $Parsed.excluded_dates),
    $(Format-b2b_SqlStringLiteral $Parsed.first_run_time_of_day),
    $(Format-b2b_SqlStringLiteral $Parsed.last_run_time_of_day),
    $(Format-b2b_SqlIntLiteral   $Parsed.expected_runs_per_day),
    $(Format-b2b_SqlStringLiteral $Parsed.schedule_description),
    $(Format-b2b_SqlStringLiteral $TimingXml -AllowEmpty),
    GETDATE()
)
"@

    return Invoke-SqlNonQuery -Query $sql -MaxCharLength 2147483647
}

# Updates an existing SI_ScheduleRegistry row from a source schedule and parsed fields.
function Invoke-b2b_ScheduleUpdate {
    param(
        [Parameter(Mandatory)]$Row,
        [Parameter(Mandatory)][hashtable]$Parsed,
        [Parameter(Mandatory)][string]$TimingXml
    )

    $sql = @"
UPDATE B2B.SI_ScheduleRegistry
SET service_name          = $(Format-b2b_SqlStringLiteral $Row.SERVICENAME),
    schedule_type         = $($Row.SCHEDULETYPE),
    schedule_type_id      = $($Row.SCHEDULETYPEID),
    execution_timer       = $($Row.EXECUTIONTIMER),
    source_status         = $(Format-b2b_SqlStringLiteral $Row.STATUS -AllowEmpty),
    execution_status      = $(Format-b2b_SqlStringLiteral $Row.EXECUTIONSTATUS -AllowEmpty),
    timing_xml_handle     = $(Format-b2b_SqlStringLiteral $Row.TIMINGXML -AllowEmpty),
    source_system_name    = $(Format-b2b_SqlStringLiteral $Row.SYSTEMNAME),
    source_user_id        = $(Format-b2b_SqlStringLiteral $Row.USERID),
    timing_pattern_type   = $(Format-b2b_SqlStringLiteral $Parsed.timing_pattern_type),
    run_day_mask          = $(Format-b2b_SqlStringLiteral $Parsed.run_day_mask),
    run_days_of_month     = $(Format-b2b_SqlStringLiteral $Parsed.run_days_of_month),
    run_times_explicit    = $(Format-b2b_SqlStringLiteral $Parsed.run_times_explicit),
    run_interval_minutes  = $(Format-b2b_SqlIntLiteral   $Parsed.run_interval_minutes),
    run_range_start       = $(Format-b2b_SqlStringLiteral $Parsed.run_range_start),
    run_range_end         = $(Format-b2b_SqlStringLiteral $Parsed.run_range_end),
    run_on_minute         = $(Format-b2b_SqlIntLiteral   $Parsed.run_on_minute),
    excluded_dates        = $(Format-b2b_SqlStringLiteral $Parsed.excluded_dates),
    first_run_time_of_day = $(Format-b2b_SqlStringLiteral $Parsed.first_run_time_of_day),
    last_run_time_of_day  = $(Format-b2b_SqlStringLiteral $Parsed.last_run_time_of_day),
    expected_runs_per_day = $(Format-b2b_SqlIntLiteral   $Parsed.expected_runs_per_day),
    schedule_description  = $(Format-b2b_SqlStringLiteral $Parsed.schedule_description),
    timing_xml            = $(Format-b2b_SqlStringLiteral $TimingXml -AllowEmpty),
    last_modified_dttm    = GETDATE()
WHERE schedule_id = $($Row.SCHEDULEID)
"@

    return Invoke-SqlNonQuery -Query $sql -MaxCharLength 2147483647
}

<# ============================================================================
   FUNCTIONS: WORKFLOW REGISTRY CENSUS
   ----------------------------------------------------------------------------
   Maintains B2B.SI_WorkflowRegistry from b2bi.dbo.WFD (latest version per
   definition) and logs version changes - the drift signal that Sterling
   workflows were edited.
   Prefix: b2b
   ============================================================================ #>

# Syncs the workflow definition catalog and detects version changes.
function Step-b2b_SyncWorkflowRegistry {
    param([bool]$PreviewOnly = $true)

    Write-Log "Step: Sync Workflow Registry (version census)" "STEP"

    $newDefs     = 0
    $versionChgs = 0
    $unchanged   = 0
    $errors      = 0

    try {
        $sourceQuery = @"
SELECT w.WFD_ID, w.WFD_VERSION, w.NAME, w.DESCRIPTION, w.EDITED_BY, w.STATUS, w.MOD_DATE
FROM dbo.WFD w
INNER JOIN (
    SELECT WFD_ID, MAX(WFD_VERSION) AS MAX_VERSION
    FROM dbo.WFD
    GROUP BY WFD_ID
) mx
    ON mx.WFD_ID = w.WFD_ID
   AND mx.MAX_VERSION = w.WFD_VERSION
ORDER BY w.WFD_ID
"@

        $sourceRows = Get-SqlData -Query $sourceQuery `
                                  -Instance $SourceInstance `
                                  -DatabaseName $SourceDatabase `
                                  -MaxCharLength 2147483647

        if (-not $sourceRows) {
            Write-Log "  No workflow definitions returned from $SourceInstance/$SourceDatabase (or query failed)" "WARN"
            return @{ NewDefinitions = 0; VersionChanges = 0; Unchanged = 0; Errors = 1 }
        }

        $sourceRows = @($sourceRows)
        Write-Log "  Fetched $($sourceRows.Count) workflow definition(s) from b2bi" "INFO"

        $registryRows = Get-SqlData -Query "SELECT wfd_id, current_version FROM B2B.SI_WorkflowRegistry"
        $registry = @{}
        if ($registryRows) {
            foreach ($r in @($registryRows)) {
                $registry[[int]$r.wfd_id] = [int]$r.current_version
            }
        }
        Write-Log "  Existing registry rows: $($registry.Count)" "INFO"

        # Count new definitions first so per-row logging can be suppressed on
        # bulk loads (initial deployment inserts the whole catalog).
        $newIds = @($sourceRows | Where-Object { -not $registry.ContainsKey([int]$_.WFD_ID) })
        $logEachNew = ($newIds.Count -le 20)
        if (-not $logEachNew) {
            Write-Log "  $($newIds.Count) new definition(s) - bulk load, suppressing per-row logging" "INFO"
        }

        # WFD_IDs confirmed unchanged this cycle, for the last_synced_dttm touch.
        $syncedIds = New-Object System.Collections.Generic.List[int]
        # WFD_IDs present in the source this cycle, for deletion detection.
        $sourceIdSet = New-Object 'System.Collections.Generic.HashSet[int]'

        foreach ($row in $sourceRows) {
            $wfdId   = [int]$row.WFD_ID
            $version = [int]$row.WFD_VERSION
            $name    = [string]$row.NAME
            $sourceIdSet.Add($wfdId) | Out-Null

            if (-not $registry.ContainsKey($wfdId)) {
                $newDefs++
                if ($PreviewOnly) {
                    if ($logEachNew) {
                        Write-Log "  [Preview] Would INSERT definition $wfdId ($name) v$version" "INFO"
                    }
                }
                else {
                    $insertSql = @"
INSERT INTO B2B.SI_WorkflowRegistry (
    wfd_id, workflow_name, workflow_description,
    current_version, previous_version, last_version_change_dttm,
    edited_by, source_status, source_mod_date,
    last_synced_dttm
)
VALUES (
    $wfdId,
    $(Format-b2b_SqlStringLiteral $name),
    $(Format-b2b_SqlStringLiteral $row.DESCRIPTION),
    $version,
    NULL,
    NULL,
    $(Format-b2b_SqlStringLiteral $row.EDITED_BY),
    $(Format-b2b_SqlIntLiteral $row.STATUS),
    $(Format-b2b_SqlDateTimeLiteral $row.MOD_DATE),
    GETDATE()
)
"@
                    $ok = Invoke-SqlNonQuery -Query $insertSql
                    if ($ok) {
                        if ($logEachNew) {
                            Write-Log "  NEW definition $wfdId ($name) v$version" "SUCCESS"
                        }
                    }
                    else {
                        $errors++
                    }
                }
            }
            elseif ($registry[$wfdId] -ne $version) {
                $versionChgs++
                $priorVersion = $registry[$wfdId]
                $editedBy = if ($row.EDITED_BY -is [DBNull]) { '(unknown)' } else { [string]$row.EDITED_BY }
                Write-Log "  CENSUS: $name v$priorVersion -> v$version (edited_by: $editedBy)" "WARN"

                if (-not $PreviewOnly) {
                    $updateSql = @"
UPDATE B2B.SI_WorkflowRegistry
SET workflow_name            = $(Format-b2b_SqlStringLiteral $name),
    workflow_description     = $(Format-b2b_SqlStringLiteral $row.DESCRIPTION),
    previous_version         = $priorVersion,
    current_version          = $version,
    last_version_change_dttm = GETDATE(),
    edited_by                = $(Format-b2b_SqlStringLiteral $row.EDITED_BY),
    source_status            = $(Format-b2b_SqlIntLiteral $row.STATUS),
    source_mod_date          = $(Format-b2b_SqlDateTimeLiteral $row.MOD_DATE),
    last_synced_dttm         = GETDATE()
WHERE wfd_id = $wfdId
"@
                    $ok = Invoke-SqlNonQuery -Query $updateSql
                    if (-not $ok) {
                        $errors++
                    }
                }
            }
            else {
                $unchanged++
                $syncedIds.Add($wfdId) | Out-Null
            }
        }

        # Touch last_synced_dttm for unchanged rows, chunked to keep statements bounded.
        if (-not $PreviewOnly -and $syncedIds.Count -gt 0) {
            $chunkSize = 500
            for ($i = 0; $i -lt $syncedIds.Count; $i += $chunkSize) {
                $end = [math]::Min($i + $chunkSize - 1, $syncedIds.Count - 1)
                $idList = ($syncedIds[$i..$end] -join ', ')
                $touchSql = "UPDATE B2B.SI_WorkflowRegistry SET last_synced_dttm = GETDATE() WHERE wfd_id IN ($idList)"
                $ok = Invoke-SqlNonQuery -Query $touchSql
                if (-not $ok) {
                    $errors++
                }
            }
        }

        # Deletion detection: registry rows absent from the source this cycle.
        $missing = 0
        foreach ($id in $registry.Keys) {
            if (-not $sourceIdSet.Contains($id)) { $missing++ }
        }
        if ($missing -gt 0) {
            Write-Log "  $missing registry definition(s) no longer present in b2bi (rows retained; last_synced_dttm goes stale)" "WARN"
        }

        Write-Log "  Summary: new=$newDefs versionChanges=$versionChgs unchanged=$unchanged errors=$errors" "INFO"
        return @{ NewDefinitions = $newDefs; VersionChanges = $versionChgs; Unchanged = $unchanged; Errors = $errors }
    }
    catch {
        Write-Log "  Error in Step-b2b_SyncWorkflowRegistry: $($_.Exception.Message)" "ERROR"
        return @{ NewDefinitions = $newDefs; VersionChanges = $versionChgs; Unchanged = $unchanged; Errors = ($errors + 1); Error = $_.Exception.Message }
    }
}

<# ============================================================================
   FUNCTIONS: PIPELINE MIRROR
   ----------------------------------------------------------------------------
   Mirrors Integration.ETL.tbl_B2B_CLIENTS_BATCH_STATUS into
   B2B.INT_PipelineTracking as classified rows: one set-based INSERT for new
   runs, one set-based UPDATE for incomplete runs, and dispatcher name
   resolution from b2bi linkage. Classification is computed in T-SQL on the
   listener so every path applies identical logic.
   Prefix: b2b
   ============================================================================ #>

# Returns the shared classified-source CTE text (WITH clause) for the mirror DML.
function Get-b2b_ClassifiedSourceSql {
    param(
        [Parameter(Mandatory)]
        [int]$LookbackDays
    )

    return @"
WITH src AS (
    SELECT bs.ID, bs.RUN_ID, bs.PARENT_ID, bs.CLIENT_ID, bs.SEQ_ID, bs.BATCH_ID,
           bs.BATCH_STATUS, bs.INSERT_DATE, bs.FINISH_DATE,
           f.PROCESS_TYPE, f.COMM_METHOD, mn.CLIENT_NAME,
           nb.new_bsnss_btch_stts_cd    AS nb_stts_cd,
           pay.cnsmr_pymnt_btch_stts_cd AS pay_stts_cd,
           fr.file_stts_cd              AS bdl_stts_cd,
           CASE WHEN bs.BATCH_STATUS = 4
                     AND EXISTS (
                    SELECT 1
                    FROM $IntegrationDatabase.etl.tbl_B2B_CLIENTS_BATCH_FILES bf
                    WHERE bf.RUN_ID = bs.RUN_ID
                      AND bf.FILE_SIZE > 0
                ) THEN 1 ELSE 0 END      AS has_nonzero_files,
           ROW_NUMBER() OVER (PARTITION BY bs.RUN_ID ORDER BY bs.ID DESC) AS rn
    FROM $IntegrationDatabase.etl.tbl_B2B_CLIENTS_BATCH_STATUS bs
    LEFT JOIN $IntegrationDatabase.etl.tbl_B2B_CLIENTS_FILES f
        ON f.CLIENT_ID = bs.CLIENT_ID
       AND f.SEQ_ID = bs.SEQ_ID
    LEFT JOIN $IntegrationDatabase.etl.tbl_B2B_CLIENTS_MN mn
        ON mn.CLIENT_ID = bs.CLIENT_ID
    LEFT JOIN $DMDatabase.dbo.new_bsnss_btch nb
        ON bs.BATCH_STATUS = -1
       AND f.PROCESS_TYPE = 'NEW_BUSINESS'
       AND nb.new_bsnss_btch_shrt_nm = bs.BATCH_ID
    LEFT JOIN $DMDatabase.dbo.cnsmr_pymnt_btch pay
        ON bs.BATCH_STATUS = -1
       AND f.PROCESS_TYPE = 'PAYMENT'
       AND CAST(pay.cnsmr_pymnt_btch_file_registry_id AS VARCHAR(20)) = bs.BATCH_ID
    LEFT JOIN $DMDatabase.dbo.file_registry fr
        ON bs.BATCH_STATUS = -1
       AND f.PROCESS_TYPE = 'BDL'
       AND CAST(fr.File_registry_id AS VARCHAR(20)) = bs.BATCH_ID
    WHERE bs.RUN_ID IS NOT NULL
      AND bs.INSERT_DATE >= DATEADD(DAY, -$LookbackDays, GETDATE())
),
cls AS (
    SELECT s.RUN_ID, s.PARENT_ID, s.CLIENT_ID, s.SEQ_ID, s.BATCH_ID,
           s.BATCH_STATUS, s.INSERT_DATE, s.FINISH_DATE,
           s.PROCESS_TYPE, s.COMM_METHOD, s.CLIENT_NAME,
           CASE WHEN s.PROCESS_TYPE = 'NEW_BUSINESS' THEN s.nb_stts_cd
                WHEN s.PROCESS_TYPE = 'PAYMENT'      THEN s.pay_stts_cd
                WHEN s.PROCESS_TYPE = 'BDL'          THEN s.bdl_stts_cd
           END AS dm_code,
           CASE
               WHEN s.BATCH_STATUS = -2 THEN 'CASCADE_SKIP'
               WHEN s.BATCH_STATUS = 5  THEN 'DUPLICATE'
               WHEN s.BATCH_STATUS IN (1, 3) THEN 'COMPLETE'
               WHEN s.BATCH_STATUS = 2 AND s.SEQ_ID IS NULL THEN 'COMPLETE'
               WHEN s.BATCH_STATUS = 2 THEN 'AWAITING_DM'
               WHEN s.BATCH_STATUS = 4
                    AND (s.PROCESS_TYPE IS NULL
                         OR s.PROCESS_TYPE NOT IN ('NEW_BUSINESS', 'PAYMENT', 'BDL'))
                    THEN 'NO_FILES'
               WHEN s.BATCH_STATUS = 4 AND s.has_nonzero_files = 1 THEN 'NO_HANDOFF'
               WHEN s.BATCH_STATUS = 4 THEN 'NO_FILES'
               WHEN s.BATCH_STATUS = -1 AND s.BATCH_ID IS NULL THEN 'STERLING_FAULT'
               WHEN s.BATCH_STATUS = -1 AND s.PROCESS_TYPE IS NOT NULL
                    AND s.PROCESS_TYPE NOT IN ('NEW_BUSINESS', 'PAYMENT', 'BDL')
                    THEN 'STERLING_FAULT'
               WHEN s.BATCH_STATUS = -1 AND s.PROCESS_TYPE = 'NEW_BUSINESS'
                    AND s.nb_stts_cd IN (3, 5) THEN 'DM_REJECTED'
               WHEN s.BATCH_STATUS = -1 AND s.PROCESS_TYPE = 'BDL'
                    AND s.bdl_stts_cd IN (6, 11) THEN 'DM_REJECTED'
               WHEN s.BATCH_STATUS = -1
                    AND (s.nb_stts_cd IS NOT NULL
                         OR s.pay_stts_cd IS NOT NULL
                         OR s.bdl_stts_cd IS NOT NULL) THEN 'FAULT_POST_HANDOFF'
               WHEN s.BATCH_STATUS = -1 THEN 'UNCLASSIFIED'
               WHEN s.BATCH_STATUS = 0  THEN 'IN_FLIGHT'
               ELSE 'UNCLASSIFIED'
           END AS status_classification
    FROM src s
    WHERE s.rn = 1
),
fin AS (
    SELECT c.*,
           CASE WHEN c.status_classification IN ('IN_FLIGHT', 'AWAITING_DM', 'UNCLASSIFIED')
                THEN 0 ELSE 1 END AS is_complete_calc,
           CASE WHEN c.status_classification IN ('IN_FLIGHT', 'AWAITING_DM', 'UNCLASSIFIED')
                THEN NULL ELSE COALESCE(c.FINISH_DATE, GETDATE()) END AS completed_dttm_calc
    FROM cls c
)
"@
}

# Discovers new pipeline runs in the source and inserts them as classified rows.
function Step-b2b_CollectNewRuns {
    param([bool]$PreviewOnly = $true)

    Write-Log "Step: Collect New Runs" "STEP"

    $inserted = 0

    try {
        $cte = Get-b2b_ClassifiedSourceSql -LookbackDays $script:Config.B2B_CollectLookbackDays

        if ($PreviewOnly) {
            # Read-only breakdown of would-insert rows
            $breakdownSql = $cte + @"

SELECT f.status_classification, COUNT(*) AS run_count
FROM fin f
WHERE NOT EXISTS (
    SELECT 1 FROM B2B.INT_PipelineTracking t WHERE t.run_id = f.RUN_ID
)
GROUP BY f.status_classification
ORDER BY f.status_classification
"@

            $breakdown = Get-SqlData -Query $breakdownSql
            $wouldInsert = 0
            if ($breakdown) {
                foreach ($row in @($breakdown)) {
                    Write-Log "  New: $($row.status_classification) x $($row.run_count)" "INFO"
                    $wouldInsert += [int]$row.run_count
                }
            }

            if ($wouldInsert -eq 0) {
                Write-Log "  No new runs to collect" "INFO"
                return @{ Inserted = 0 }
            }

            Write-Log "  [Preview] Would insert $wouldInsert new run(s)" "INFO"
            return @{ Inserted = $wouldInsert }
        }

        # Execute: single pass - the INSERT captures its own classification
        # breakdown via OUTPUT, so the CTE is evaluated exactly once.
        $insertSql = @"
DECLARE @captured TABLE (status_classification VARCHAR(30));

"@ + $cte + @"

INSERT INTO B2B.INT_PipelineTracking (
    run_id, parent_id, client_id, seq_id, batch_id,
    batch_status, source_insert_dttm, source_finish_dttm,
    process_type, comm_method, client_name,
    status_classification, dm_batch_status_code,
    is_complete, completed_dttm,
    last_polled_dttm
)
OUTPUT inserted.status_classification INTO @captured
SELECT f.RUN_ID, f.PARENT_ID, f.CLIENT_ID, f.SEQ_ID, f.BATCH_ID,
       f.BATCH_STATUS, f.INSERT_DATE, f.FINISH_DATE,
       f.PROCESS_TYPE, f.COMM_METHOD, f.CLIENT_NAME,
       f.status_classification, f.dm_code,
       f.is_complete_calc, f.completed_dttm_calc,
       GETDATE()
FROM fin f
WHERE NOT EXISTS (
    SELECT 1 FROM B2B.INT_PipelineTracking t WHERE t.run_id = f.RUN_ID
);

SELECT status_classification, COUNT(*) AS run_count
FROM @captured
GROUP BY status_classification
ORDER BY status_classification;
"@

        $captured = Get-SqlData -Query $insertSql
        if ($null -ne $captured) {
            foreach ($row in @($captured)) {
                Write-Log "  New: $($row.status_classification) x $($row.run_count)" "INFO"
                $inserted += [int]$row.run_count
            }
        }

        if ($inserted -eq 0) {
            Write-Log "  No new runs to collect" "INFO"
        }
        else {
            Write-Log "  Inserted $inserted new run(s)" "SUCCESS"
        }

        return @{ Inserted = $inserted }
    }
    catch {
        Write-Log "  Error in Step-b2b_CollectNewRuns: $($_.Exception.Message)" "ERROR"
        return @{ Inserted = $inserted; Error = $_.Exception.Message }
    }
}

# Re-polls incomplete tracked runs against the source and reclassifies them.
function Step-b2b_UpdateIncompleteRuns {
    param([bool]$PreviewOnly = $true)

    Write-Log "Step: Update Incomplete Runs" "STEP"

    $updated = 0

    try {
        $cte = Get-b2b_ClassifiedSourceSql -LookbackDays $script:Config.B2B_CollectLookbackDays

        if ($PreviewOnly) {
            # Read-only breakdown of the incomplete working set
            $breakdownSql = $cte + @"

SELECT f.status_classification, COUNT(*) AS run_count,
       SUM(f.is_complete_calc) AS completing_count
FROM fin f
INNER JOIN B2B.INT_PipelineTracking t
    ON t.run_id = f.RUN_ID
WHERE t.is_complete = 0
GROUP BY f.status_classification
ORDER BY f.status_classification
"@

            $breakdown = Get-SqlData -Query $breakdownSql
            $inWorkingSet = 0
            $completing = 0
            if ($breakdown) {
                foreach ($row in @($breakdown)) {
                    Write-Log "  Incomplete -> $($row.status_classification) x $($row.run_count)" "INFO"
                    $inWorkingSet += [int]$row.run_count
                    $completing += [int]$row.completing_count
                }
            }

            if ($inWorkingSet -eq 0) {
                Write-Log "  No incomplete runs in the working window" "INFO"
                return @{ Updated = 0; Completed = 0 }
            }

            Write-Log "  [Preview] Would update $inWorkingSet run(s), $completing reaching terminal classification" "INFO"
            return @{ Updated = $inWorkingSet; Completed = $completing }
        }

        # Execute: single pass - the UPDATE captures its own completion facts
        # via OUTPUT, so the CTE is evaluated exactly once.
        $completing = 0
        $updateSql = @"
DECLARE @captured TABLE (is_complete BIT, status_classification VARCHAR(30));

"@ + $cte + @"

UPDATE t
SET batch_status          = f.BATCH_STATUS,
    batch_id              = f.BATCH_ID,
    source_finish_dttm    = f.FINISH_DATE,
    process_type          = f.PROCESS_TYPE,
    comm_method           = f.COMM_METHOD,
    client_name           = f.CLIENT_NAME,
    status_classification = f.status_classification,
    dm_batch_status_code  = f.dm_code,
    is_complete           = f.is_complete_calc,
    completed_dttm        = f.completed_dttm_calc,
    last_polled_dttm      = GETDATE()
OUTPUT inserted.is_complete, inserted.status_classification INTO @captured
FROM B2B.INT_PipelineTracking t
INNER JOIN fin f
    ON f.RUN_ID = t.run_id
WHERE t.is_complete = 0;

SELECT status_classification,
       COUNT(*) AS run_count,
       SUM(CASE WHEN is_complete = 1 THEN 1 ELSE 0 END) AS completing_count
FROM @captured
GROUP BY status_classification
ORDER BY status_classification;
"@

        $captured = Get-SqlData -Query $updateSql
        if ($null -ne $captured) {
            foreach ($row in @($captured)) {
                Write-Log "  Incomplete -> $($row.status_classification) x $($row.run_count)" "INFO"
                $updated += [int]$row.run_count
                $completing += [int]$row.completing_count
            }
        }

        if ($updated -eq 0) {
            Write-Log "  No incomplete runs in the working window" "INFO"
        }
        else {
            Write-Log "  Updated $updated run(s), $completing reached terminal classification" "SUCCESS"
        }

        return @{ Updated = $updated; Completed = $completing }
    }
    catch {
        Write-Log "  Error in Step-b2b_UpdateIncompleteRuns: $($_.Exception.Message)" "ERROR"
        return @{ Updated = $updated; Completed = 0; Error = $_.Exception.Message }
    }
}

# Resolves dispatcher workflow names from b2bi for tracked runs missing them.
function Step-b2b_ResolveDispatcherNames {
    param([bool]$PreviewOnly = $true)

    Write-Log "Step: Resolve Dispatcher Names" "STEP"

    $resolved = 0

    try {
        $lookbackDays = $script:Config.B2B_CollectLookbackDays

        # Wrapper-launched rows resolve via their own RUN_ID (inline GET_LIST runs in
        # the wrapper's context); dispatched MAIN children resolve via PARENT_ID.
        $targetsQuery = @"
SELECT run_id, COALESCE(parent_id, run_id) AS lookup_wf_id
FROM B2B.INT_PipelineTracking
WHERE dispatcher_name IS NULL
  AND source_insert_dttm >= DATEADD(DAY, -$lookbackDays, GETDATE())
"@

        $targets = Get-SqlData -Query $targetsQuery
        if (-not $targets) {
            Write-Log "  No runs awaiting dispatcher resolution" "INFO"
            return @{ Resolved = 0 }
        }

        $targets = @($targets)
        Write-Log "  Runs awaiting dispatcher resolution: $($targets.Count)" "INFO"

        # Resolve names from b2bi in chunks (live + restore instance tables).
        $lookupIds = @($targets | ForEach-Object { [long]$_.lookup_wf_id } | Sort-Object -Unique)
        $nameByWfId = @{}
        $chunkSize = 500

        for ($i = 0; $i -lt $lookupIds.Count; $i += $chunkSize) {
            $end = [math]::Min($i + $chunkSize - 1, $lookupIds.Count - 1)
            $idList = ($lookupIds[$i..$end] -join ', ')

            $nameQuery = @"
SELECT inst.WORKFLOW_ID, w.NAME
FROM (
    SELECT WORKFLOW_ID, WFD_ID, WFD_VERSION
    FROM dbo.WF_INST_S
    WHERE WORKFLOW_ID IN ($idList)
    UNION ALL
    SELECT WORKFLOW_ID, WFD_ID, WFD_VERSION
    FROM dbo.WF_INST_S_RESTORE
    WHERE WORKFLOW_ID IN ($idList)
) inst
INNER JOIN dbo.WFD w
    ON w.WFD_ID = inst.WFD_ID
   AND w.WFD_VERSION = inst.WFD_VERSION
"@

            $nameRows = Get-SqlData -Query $nameQuery `
                                    -Instance $SourceInstance `
                                    -DatabaseName $SourceDatabase
            if ($nameRows) {
                foreach ($r in @($nameRows)) {
                    $nameByWfId[[long]$r.WORKFLOW_ID] = [string]$r.NAME
                }
            }
        }

        Write-Log "  Names resolved from b2bi: $($nameByWfId.Count) of $($lookupIds.Count) instance id(s)" "INFO"

        if ($nameByWfId.Count -eq 0) {
            return @{ Resolved = 0 }
        }

        # Group target run_ids by resolved name and update per distinct name.
        $runIdsByName = @{}
        foreach ($t in $targets) {
            $wfId = [long]$t.lookup_wf_id
            if ($nameByWfId.ContainsKey($wfId)) {
                $name = $nameByWfId[$wfId]
                if (-not $runIdsByName.ContainsKey($name)) {
                    $runIdsByName[$name] = New-Object System.Collections.Generic.List[long]
                }
                $runIdsByName[$name].Add([long]$t.run_id) | Out-Null
            }
        }

        foreach ($name in $runIdsByName.Keys) {
            $ids = $runIdsByName[$name]
            if ($PreviewOnly) {
                Write-Log "  [Preview] Would set dispatcher_name '$name' on $($ids.Count) run(s)" "INFO"
                $resolved += $ids.Count
                continue
            }

            for ($i = 0; $i -lt $ids.Count; $i += $chunkSize) {
                $end = [math]::Min($i + $chunkSize - 1, $ids.Count - 1)
                $idList = ($ids[$i..$end] -join ', ')
                $updateSql = @"
UPDATE B2B.INT_PipelineTracking
SET dispatcher_name = $(Format-b2b_SqlStringLiteral $name)
WHERE run_id IN ($idList)
"@
                $ok = Invoke-SqlNonQuery -Query $updateSql
                if ($ok) {
                    $resolved += ($end - $i + 1)
                }
            }
        }

        Write-Log "  Dispatcher names resolved: $resolved" "INFO"
        return @{ Resolved = $resolved }
    }
    catch {
        Write-Log "  Error in Step-b2b_ResolveDispatcherNames: $($_.Exception.Message)" "ERROR"
        return @{ Resolved = $resolved; Error = $_.Exception.Message }
    }
}

<# ============================================================================
   FUNCTIONS: STERLING CROSS-CHECK
   ----------------------------------------------------------------------------
   Checks aged in-flight rows against b2bi runtime state. A status-0 row past
   the aging threshold whose Sterling instance has terminated or vanished
   died without reaching a fault handler and will never update its own row;
   the check classifies it DIED_UNHANDLED.
   Prefix: b2b
   ============================================================================ #>

# Cross-checks aged in-flight rows against b2bi WF_INST_S and classifies dead runs.
function Step-b2b_CheckSterlingInstances {
    param([bool]$PreviewOnly = $true)

    Write-Log "Step: Check Sterling Instances" "STEP"

    $stillRunning = 0
    $diedUnhandled = 0

    try {
        $lookbackDays = $script:Config.B2B_CollectLookbackDays
        $agingMinutes = $script:Config.B2B_InFlightAgingMinutes

        $candidatesQuery = @"
SELECT run_id
FROM B2B.INT_PipelineTracking
WHERE is_complete = 0
  AND batch_status = 0
  AND source_insert_dttm <= DATEADD(MINUTE, -$agingMinutes, GETDATE())
  AND source_insert_dttm >= DATEADD(DAY, -$lookbackDays, GETDATE())
"@

        $candidates = Get-SqlData -Query $candidatesQuery
        if (-not $candidates) {
            Write-Log "  No in-flight runs past the aging threshold ($agingMinutes min)" "INFO"
            return @{ StillRunning = 0; DiedUnhandled = 0 }
        }

        $candidates = @($candidates)
        Write-Log "  In-flight run(s) past aging threshold: $($candidates.Count)" "INFO"

        # Look up instance state from b2bi (live + restore), chunked.
        $candidateIds = @($candidates | ForEach-Object { [long]$_.run_id })
        $instanceByWfId = @{}
        $chunkSize = 500

        for ($i = 0; $i -lt $candidateIds.Count; $i += $chunkSize) {
            $end = [math]::Min($i + $chunkSize - 1, $candidateIds.Count - 1)
            $idList = ($candidateIds[$i..$end] -join ', ')

            $instQuery = @"
SELECT WORKFLOW_ID, END_TIME
FROM dbo.WF_INST_S
WHERE WORKFLOW_ID IN ($idList)
UNION ALL
SELECT WORKFLOW_ID, END_TIME
FROM dbo.WF_INST_S_RESTORE
WHERE WORKFLOW_ID IN ($idList)
"@

            $instRows = Get-SqlData -Query $instQuery `
                                    -Instance $SourceInstance `
                                    -DatabaseName $SourceDatabase
            if ($instRows) {
                foreach ($r in @($instRows)) {
                    $instanceByWfId[[long]$r.WORKFLOW_ID] = $r.END_TIME
                }
            }
        }

        foreach ($runId in $candidateIds) {
            if ($instanceByWfId.ContainsKey($runId)) {
                $endTime = $instanceByWfId[$runId]

                if ($null -eq $endTime -or $endTime -is [DBNull]) {
                    # Instance found and still executing - genuinely in flight.
                    $stillRunning++
                    if ($PreviewOnly) {
                        Write-Log "  [Preview] Run $runId still RUNNING in Sterling" "DEBUG"
                    }
                    else {
                        $sql = @"
UPDATE B2B.INT_PipelineTracking
SET sterling_check_result = 'RUNNING',
    last_polled_dttm = GETDATE()
WHERE run_id = $runId
"@
                        Invoke-SqlNonQuery -Query $sql | Out-Null
                    }
                }
                else {
                    # Instance terminated but the source row never left 0.
                    $diedUnhandled++
                    if ($PreviewOnly) {
                        Write-Log "  [Preview] Run $runId TERMINATED in Sterling - would classify DIED_UNHANDLED" "WARN"
                    }
                    else {
                        $sql = @"
UPDATE B2B.INT_PipelineTracking
SET sterling_check_result = 'TERMINATED',
    status_classification = 'DIED_UNHANDLED',
    is_complete = 1,
    completed_dttm = $(Format-b2b_SqlDateTimeLiteral $endTime),
    last_polled_dttm = GETDATE()
WHERE run_id = $runId
"@
                        $ok = Invoke-SqlNonQuery -Query $sql
                        if ($ok) {
                            Write-Log "  Run $runId TERMINATED in Sterling - classified DIED_UNHANDLED" "WARN"
                        }
                    }
                }
            }
            else {
                # No instance in live or restore - aged out or never registered.
                $diedUnhandled++
                if ($PreviewOnly) {
                    Write-Log "  [Preview] Run $runId NOT_FOUND in Sterling - would classify DIED_UNHANDLED" "WARN"
                }
                else {
                    $sql = @"
UPDATE B2B.INT_PipelineTracking
SET sterling_check_result = 'NOT_FOUND',
    status_classification = 'DIED_UNHANDLED',
    is_complete = 1,
    completed_dttm = GETDATE(),
    last_polled_dttm = GETDATE()
WHERE run_id = $runId
"@
                    $ok = Invoke-SqlNonQuery -Query $sql
                    if ($ok) {
                        Write-Log "  Run $runId NOT_FOUND in Sterling - classified DIED_UNHANDLED" "WARN"
                    }
                }
            }
        }

        Write-Log "  Summary: stillRunning=$stillRunning diedUnhandled=$diedUnhandled" "INFO"
        return @{ StillRunning = $stillRunning; DiedUnhandled = $diedUnhandled }
    }
    catch {
        Write-Log "  Error in Step-b2b_CheckSterlingInstances: $($_.Exception.Message)" "ERROR"
        return @{ StillRunning = $stillRunning; DiedUnhandled = $diedUnhandled; Error = $_.Exception.Message }
    }
}

<# ============================================================================
   FUNCTIONS: ALERT EVALUATION
   ----------------------------------------------------------------------------
   Queues Teams alerts via the shared Send-TeamsAlert function: failure
   classifications (one alert per run via alert_count, bounded to the working
   window) and workflow version changes (deduped by wfd_id + version). Gated
   by the b2b_alerting_enabled GlobalConfig switch.
   Prefix: b2b
   ============================================================================ #>

# Evaluates failure classifications and workflow version changes; queues Teams alerts.
function Step-b2b_EvaluateAlerts {
    param([bool]$PreviewOnly = $true)

    Write-Log "Step: Evaluate Alert Conditions" "STEP"

    $alertsDetected = 0
    $alertsFired    = 0

    try {
        if (-not $script:Config.B2B_AlertingEnabled) {
            Write-Log "  Alerting is DISABLED (b2b_alerting_enabled = 0)" "INFO"
        }

        $lookbackDays = $script:Config.B2B_CollectLookbackDays

        # CHECK 1: Failure classifications - one alert per run, alert_count dedup.
        # Bounded to the working window so historical/backfilled failures with
        # alert_count = 0 never generate alerts.
        $failureQuery = @"
SELECT run_id, client_id, client_name, seq_id, batch_id,
       process_type, comm_method, dispatcher_name,
       batch_status, status_classification, dm_batch_status_code,
       source_insert_dttm, completed_dttm
FROM B2B.INT_PipelineTracking
WHERE status_classification IN (
        'STERLING_FAULT', 'DM_REJECTED', 'FAULT_POST_HANDOFF',
        'DIED_UNHANDLED', 'NO_HANDOFF')
  AND alert_count = 0
  AND source_insert_dttm >= DATEADD(DAY, -$lookbackDays, GETDATE())
ORDER BY source_insert_dttm
"@

        $failures = Get-SqlData -Query $failureQuery

        if ($failures) {
            foreach ($run in @($failures)) {
                $alertsDetected++
                $runId          = [long]$run.run_id
                $classification = [string]$run.status_classification
                $clientName     = if ($run.client_name -isnot [DBNull] -and $run.client_name) { [string]$run.client_name } else { "client $($run.client_id)" }

                Write-Log "  ALERT: $classification - run $runId ($clientName)" "WARN"

                if ($script:Config.B2B_AlertingEnabled -and -not $PreviewOnly) {
                    # Per-classification severity, color, and action text.
                    switch ($classification) {
                        'STERLING_FAULT' {
                            $category = 'CRITICAL'; $color = 'attention'
                            $title    = "{{FIRE}} B2B Sterling Fault: $clientName"
                            $action   = 'The workflow faulted on the Sterling side before any DM handoff. Review the run in Sterling and the Integration TICKETS table.'
                        }
                        'DM_REJECTED' {
                            $category = 'CRITICAL'; $color = 'attention'
                            $title    = "{{FIRE}} DM Rejected B2B Batch: $clientName"
                            $action   = 'DM rejected the batch after handoff. Review the batch in Debt Manager and determine corrective action.'
                        }
                        'FAULT_POST_HANDOFF' {
                            $category = 'CRITICAL'; $color = 'attention'
                            $title    = "{{FIRE}} B2B Fault After DM Handoff: $clientName"
                            $action   = 'The data landed in DM but the pipeline faulted afterward - cleanup and notification steps may not have run. Verify the DM batch and review the Sterling fault.'
                        }
                        'DIED_UNHANDLED' {
                            $category = 'CRITICAL'; $color = 'attention'
                            $title    = "{{FIRE}} B2B Run Died Unhandled: $clientName"
                            $action   = 'The run terminated in Sterling without reaching a fault handler; its status row will never self-update. Review the Sterling instance for the failure point.'
                        }
                        'NO_HANDOFF' {
                            $category = 'WARNING'; $color = 'warning'
                            $title    = "{{WARN}} B2B Files Picked Up But Never Handed Off: $clientName"
                            $action   = 'Files were acquired but the run never handed a batch to DM. Review the run to determine where the pipeline stopped.'
                        }
                    }

                    $processType  = if ($run.process_type -isnot [DBNull] -and $run.process_type) { $run.process_type } else { 'N/A' }
                    $commMethod   = if ($run.comm_method -isnot [DBNull] -and $run.comm_method) { $run.comm_method } else { 'N/A' }
                    $dispatcher   = if ($run.dispatcher_name -isnot [DBNull] -and $run.dispatcher_name) { $run.dispatcher_name } else { 'N/A' }
                    $batchIdText  = if ($run.batch_id -isnot [DBNull] -and $run.batch_id) { $run.batch_id } else { 'N/A' }
                    $dmCodeText   = if ($run.dm_batch_status_code -isnot [DBNull]) { $run.dm_batch_status_code } else { 'N/A' }
                    $startText    = if ($run.source_insert_dttm -isnot [DBNull]) { $run.source_insert_dttm.ToString('yyyy-MM-dd HH:mm:ss') } else { 'N/A' }
                    $endText      = if ($run.completed_dttm -isnot [DBNull] -and $null -ne $run.completed_dttm) { $run.completed_dttm.ToString('yyyy-MM-dd HH:mm:ss') } else { 'N/A' }
                    $detectionTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

                    $message = @"
**Run ID:** $runId
**Client:** $clientName
**Process Type:** $processType | **Comm Method:** $commMethod
**Dispatcher:** $dispatcher
**Batch ID:** $batchIdText | **DM Status Code:** $dmCodeText
**Run Start:** $startText | **Completed:** $endText

$action

**Detection:** $detectionTime
"@

                    Send-TeamsAlert -SourceModule 'B2B' -AlertCategory $category `
                        -Title $title -Message $message -Color $color `
                        -TriggerType "B2B_$classification" -TriggerValue "$runId" | Out-Null

                    # Increment alert_count
                    Invoke-SqlNonQuery -Query @"
UPDATE B2B.INT_PipelineTracking
SET alert_count = alert_count + 1
WHERE run_id = $runId
"@ | Out-Null

                    $alertsFired++
                }
            }
        }

        # CHECK 2: Workflow version changes - deduped by wfd_id + new version, so
        # each edit alerts exactly once regardless of how many cycles observe it.
        $censusQuery = @"
SELECT wfd_id, workflow_name, previous_version, current_version,
       edited_by, source_mod_date, last_version_change_dttm
FROM B2B.SI_WorkflowRegistry
WHERE last_version_change_dttm >= DATEADD(DAY, -$lookbackDays, GETDATE())
ORDER BY last_version_change_dttm
"@

        $versionChanges = Get-SqlData -Query $censusQuery

        if ($versionChanges) {
            foreach ($chg in @($versionChanges)) {
                $alertsDetected++
                $wfdName = [string]$chg.workflow_name
                Write-Log "  ALERT: Workflow version change - $wfdName v$($chg.previous_version) -> v$($chg.current_version)" "WARN"

                if ($script:Config.B2B_AlertingEnabled -and -not $PreviewOnly) {
                    $editedBy = if ($chg.edited_by -isnot [DBNull] -and $chg.edited_by) { $chg.edited_by } else { '(unknown)' }
                    $modText  = if ($chg.source_mod_date -isnot [DBNull]) { $chg.source_mod_date.ToString('yyyy-MM-dd HH:mm:ss') } else { 'N/A' }
                    $detectionTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

                    $message = @"
**Workflow:** $wfdName
**Version:** v$($chg.previous_version) -> v$($chg.current_version)
**Edited By:** $editedBy
**Sterling Mod Date:** $modText

A Sterling workflow definition changed. Definition changes alter pipeline behavior with no other notification path - review the edit and refresh the BPML corpus if the change is significant.

**Detection:** $detectionTime
"@

                    $sent = Send-TeamsAlert -SourceModule 'B2B' -AlertCategory 'WARNING' `
                        -Title "{{WARN}} Sterling Workflow Changed: $wfdName" -Message $message -Color 'warning' `
                        -TriggerType 'B2B_WorkflowVersionChange' -TriggerValue "$($chg.wfd_id)-v$($chg.current_version)"

                    if ($sent) { $alertsFired++ }
                }
            }
        }

        Write-Log "  Summary: detected=$alertsDetected fired=$alertsFired" "INFO"
        return @{ Detected = $alertsDetected; Fired = $alertsFired }
    }
    catch {
        Write-Log "  Error in Step-b2b_EvaluateAlerts: $($_.Exception.Message)" "ERROR"
        return @{ Detected = $alertsDetected; Fired = $alertsFired; Error = $_.Exception.Message }
    }
}

<# ============================================================================
   EXECUTION: SCRIPT EXECUTION
   ----------------------------------------------------------------------------
   The collection run: initialize config, sync schedules, run the workflow
   version census, collect and re-poll classified pipeline runs, resolve
   dispatcher names, cross-check aged in-flight rows against Sterling,
   evaluate alert conditions, print the summary, and fire the callback.
   Prefix: (none)
   ============================================================================ #>

$scriptStart = Get-Date

Write-Console
Write-ConsoleBanner -Label "xFACts B2B Pipeline Collector" -Color Cyan

if ($Execute) { Write-Log "Mode: EXECUTE (changes will be applied)" "WARN" }
else          { Write-Log "Mode: PREVIEW (no changes will be made)" "INFO" }
Write-Console

if (-not (Initialize-b2b_Config)) {
    Write-Log "Configuration initialization failed - exiting" "ERROR"

    if ($TaskId -gt 0) {
        $totalMs = [int]((Get-Date) - $scriptStart).TotalMilliseconds
        Complete-OrchestratorTask -TaskId $TaskId -ProcessId $ProcessId `
            -Status "FAILED" -DurationMs $totalMs `
            -ErrorMessage "Configuration initialization failed"
    }
    exit 1
}
Write-Console

$previewOnly = -not $Execute
$stepResults = @{}

Write-ConsoleBanner -Label "Executing Steps" -Color DarkGray -RuleChar '-'

# Step 1 - Sync schedules
$stepResults.Schedules = Step-b2b_SyncSchedules -PreviewOnly $previewOnly

# Step 2 - Workflow registry census
$stepResults.Census = Step-b2b_SyncWorkflowRegistry -PreviewOnly $previewOnly

# Step 3 - Collect new pipeline runs
$stepResults.Collect = Step-b2b_CollectNewRuns -PreviewOnly $previewOnly

# Step 4 - Re-poll incomplete pipeline runs
$stepResults.Update = Step-b2b_UpdateIncompleteRuns -PreviewOnly $previewOnly

# Step 5 - Resolve dispatcher names
$stepResults.Dispatchers = Step-b2b_ResolveDispatcherNames -PreviewOnly $previewOnly

# Step 6 - Sterling instance cross-check
$stepResults.CrossCheck = Step-b2b_CheckSterlingInstances -PreviewOnly $previewOnly

# Step 7 - Alert evaluation
$stepResults.Alerts = Step-b2b_EvaluateAlerts -PreviewOnly $previewOnly

# SUMMARY

$scriptEnd = Get-Date
$totalMs   = [int]($scriptEnd - $scriptStart).TotalMilliseconds

$finalStatus = "SUCCESS"
if ($stepResults.Schedules.Error -or $stepResults.Schedules.Errors -gt 0) {
    $finalStatus = "FAILED"
}
if ($stepResults.Census.Error -or $stepResults.Census.Errors -gt 0) {
    $finalStatus = "FAILED"
}
if ($stepResults.Collect.Error -or $stepResults.Update.Error) {
    $finalStatus = "FAILED"
}
if ($stepResults.Dispatchers.Error -or $stepResults.CrossCheck.Error -or $stepResults.Alerts.Error) {
    $finalStatus = "FAILED"
}

Write-Console
Write-ConsoleBanner -Label "Execution Summary" -Color Cyan
Write-Console "  Schedules:"
Write-Console "    Inserted: $($stepResults.Schedules.Inserted)  Updated: $($stepResults.Schedules.Updated)  Deleted: $($stepResults.Schedules.Deleted)  Errors: $($stepResults.Schedules.Errors)"
Write-Console
Write-Console "  Workflow Census:"
Write-Console "    New: $($stepResults.Census.NewDefinitions)  Version Changes: $($stepResults.Census.VersionChanges)  Unchanged: $($stepResults.Census.Unchanged)  Errors: $($stepResults.Census.Errors)"
Write-Console
Write-Console "  Pipeline Mirror:"
Write-Console "    New Runs:  $($stepResults.Collect.Inserted)"
Write-Console "    Updated:   $($stepResults.Update.Updated)  Completed: $($stepResults.Update.Completed)"
Write-Console "    Dispatchers Resolved: $($stepResults.Dispatchers.Resolved)"
Write-Console
Write-Console "  Sterling Cross-Check:"
Write-Console "    Still Running: $($stepResults.CrossCheck.StillRunning)  Died Unhandled: $($stepResults.CrossCheck.DiedUnhandled)"
Write-Console
Write-Console "  Alerts:"
Write-Console "    Detected: $($stepResults.Alerts.Detected)  Fired: $($stepResults.Alerts.Fired)"
Write-Console
Write-Console "  Duration: $totalMs ms"
Write-Console

if (-not $Execute) {
    Write-Console "  *** PREVIEW MODE - No changes were made ***" Yellow
    Write-Console "  Run with -Execute to perform actual updates" Yellow
    Write-Console
}

Write-ConsoleBanner -Label "B2B Pipeline Collection Complete" -Color Cyan

# Orchestrator callback
if ($TaskId -gt 0) {
    $output = "SchedIns:$($stepResults.Schedules.Inserted) SchedUpd:$($stepResults.Schedules.Updated) SchedDel:$($stepResults.Schedules.Deleted) | CensusNew:$($stepResults.Census.NewDefinitions) CensusChg:$($stepResults.Census.VersionChanges) | RunsNew:$($stepResults.Collect.Inserted) RunsUpd:$($stepResults.Update.Updated) RunsDone:$($stepResults.Update.Completed) Disp:$($stepResults.Dispatchers.Resolved) | XChkRun:$($stepResults.CrossCheck.StillRunning) XChkDead:$($stepResults.CrossCheck.DiedUnhandled) | AlertDet:$($stepResults.Alerts.Detected) AlertFired:$($stepResults.Alerts.Fired)"

    Complete-OrchestratorTask -TaskId $TaskId -ProcessId $ProcessId `
        -Status $finalStatus -DurationMs $totalMs `
        -Output $output
}
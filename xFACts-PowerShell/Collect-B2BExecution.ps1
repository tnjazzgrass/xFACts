<#
.SYNOPSIS
    xFACts - IBM Sterling B2B Integrator execution monitoring

.DESCRIPTION
    xFACts - B2B
    Script: Collect-B2BExecution.ps1

    Single collector for the B2B module. Synchronizes the schedule registry
    from b2bi.dbo.SCHEDULE and collects FA_CLIENTS_MAIN workflow executions
    from b2bi into SI_ExecutionTracking.

    This script is being built in phases matching the B2B module's development
    plan:
      Block 1 (complete) - Schedule sync into B2B.SI_ScheduleRegistry.
      Block 2 (current)  - Execution collection into B2B.SI_ExecutionTracking.
                           100% sourced from b2bi. No Integration enrichment.
      Block 3 (future)   - Detail extraction into B2B.SI_ExecutionDetail.
                           Currently stubbed.
      Phase 4 (future)   - Alert evaluation (b2bi terminal failed state → Teams).
                           Currently stubbed.

    Source server: FA-INT-DBP (b2bi database) via Windows auth.
    Target server: AVG-PROD-LSNR (xFACts database) via Windows auth.

    Architectural note: SI_ tables are 100% b2bi-sourced. Integration tables are
    live-joined in Control Center queries or future Phase 4 alerting logic,
    never mirrored into SI_ tables.

    CHANGELOG
    ---------
    2026-04-22  Fixed ConvertTo-CompletionState STATUS semantics. Original
                code had STATUS=0 treated as in-progress and STATUS=2 as
                success — inverted from Sterling's actual convention.
                Verified against production: STATUS=0 = SUCCESS, STATUS=1
                = FAILED, END_TIME populated = terminal in both cases.
                STATE is a numeric state code (always 1 in observed data)
                and is no longer consulted — it was being returned as the
                completed_status string when STATUS didn't match, which
                produced literal '1' values in the column.
    2026-04-22  Extended INTERNAL_OP POST_TRANS_SQL_QUERY match to cover
                the XPath concat() wrapping pattern used by BDL-style SP
                executors — e.g. PAY N SECONDS. The stored value is not a
                literal SQL statement but an XPath expression that builds
                the EXEC at runtime by embedding INVOKE_ID_LIST. Now matches
                both literal 'EXEC Integration.' prefixes and
                'concat(''EXEC Integration.' XPath wrappers.
    2026-04-22  Expanded ConvertTo-RunClass to eliminate UNCLASSIFIED rows
                produced by overly-narrow initial rules. INTERNAL_OP now also
                matches workflows whose POST_TRANS_SQL_QUERY begins with
                'EXEC Integration.' (SP-executor pattern regardless of
                CLIENT_ID). FILE_PROCESS now also matches workflows with
                COMM_CALL_CLA_EXE_PATH populated (external exe orchestration)
                and workflows with PROCESS_TYPE of SFTP_PUSH or SFTP_PUSH_ED25519
                (always-file-process push operations). INTERNAL_OP signals
                evaluated first so SP-executor classification wins over file
                signals when both are present.
    2026-04-22  Fixed silent ProcessData truncation — Get-ProcessDataForWorkflow
                now passes -MaxBinaryLength 20971520 to Get-SqlData. Previously
                only -MaxCharLength was specified, leaving binary blobs at the
                Invoke-Sqlcmd default of 1024 bytes. Larger ProcessData blobs
                were being silently truncated mid-stream, causing gzip
                decompression to return empty strings and workflows to appear
                as UNCLASSIFIED with empty process_data_xml. Requires matching
                -MaxBinaryLength parameter addition in xFACts-OrchestratorFunctions.ps1.
                Block 1 schedule fetch updated to match for defensiveness.
    2026-04-22  Block 2 query corrections — WF_INST_S now joins WFD on
                (WFD_ID + WFD_VERSION) and filters by name (survives
                Sterling workflow version changes). WORKFLOW_LINKAGE uses
                correct columns (C_WF_ID, P_WF_ID, ROOT_WF_ID). Sub-workflow
                invocation detection now uses ADV_STATUS 'Inline Begin'
                pattern instead of SERVICE_NAME (SERVICE_NAME is
                InvokeBusinessProcessService on invocation rows).
                Failure scan uses BASIC_STATUS NOT IN (0, 10) — 10 is
                also a non-failure state.
    2026-04-22  Block 2 implemented — Step-CollectExecutions populates
                B2B.SI_ExecutionTracking from b2bi (WF_INST_S, WORKFLOW_LINKAGE,
                WORKFLOW_CONTEXT, TRANS_DATA). Step-EnrichFromIntegration
                removed — table design is pure b2bi per revised architecture.
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
    Runs and applies changes.

================================================================================
DEPLOYMENT REMINDERS
================================================================================
1. Service account must have read access to b2bi on FA-INT-DBP via Windows auth.
2. Service account must have read/write access to xFACts database on AVG-PROD-LSNR.
3. Required GlobalConfig entries (module = 'B2B', category = 'B2B'):
   - b2b_alerting_enabled (default: 0)
   - b2b_collect_lookback_days (default: 7)
================================================================================
#>

[CmdletBinding()]
param(
    [string]$ServerInstance        = "AVG-PROD-LSNR",
    [string]$Database              = "xFACts",
    [string]$SourceInstance        = "FA-INT-DBP",
    [string]$SourceDatabase        = "b2bi",
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

# ProcessData XML field names in SP PIVOT order (matches XML element order).
# Drives both the parsing loop and the SQL column ordering in MERGE operations.
# These 73 field names are the authoritative output of USP_B2B_CLIENTS_GET_LIST's
# PIVOT, confirmed against 30 sample XMLs covering 21 process-type pairs.
$Script:ProcessDataFields = @(
    # Identity (SP PIVOT positions 1-6)
    'CLIENT_ID', 'SEQ_ID', 'CLIENT_NAME', 'PROCESS_TYPE', 'COMM_METHOD', 'FILE_ID',
    # Config (SP PIVOT positions 7-73, in emission order)
    'PRE_ARCHIVE', 'TRANSLATION_MAP', 'WORKERS_COMP', 'DUP_CHECK', 'PREPARE_SOURCE',
    'POST_ARCHIVE', 'FILE_FILTER', 'MAIL_TO', 'MAIL_CC', 'GET_DOCS_TYPE',
    'GET_DOCS_LOC', 'PUT_DOCS_TYPE', 'PUT_DOCS_LOC', 'FILE_RENAME', 'PREPARE_COMM_CALL',
    'COMM_CALL', 'BUSINESS_TYPE', 'CONVERT_TO_CSV', 'AUTO_RELEASE', 'PUT_DOCS_PROFILE_ID',
    'SQL_QUERY', 'MDOS', 'SEND_EMPTY_FILES', 'GET_DOCS_DLT', 'PREP_TRANSLATION_MAP',
    'GZIP', 'EMAIL_XSLT', 'PGP_PASSPHRASE', 'UNZIP_FILTER', 'UNZIP_PASSWORD',
    'ENCOUNTER_MAP', 'PV_FN_ADDRESS', 'GET_DOCS_PROFILE_ID', 'PDF_FILE',
    'CUSTOM_BP_PRE_TRANSLATION', 'CUSTOM_BP_PRE_PROCESS', 'SQL_QUERY_DATA_SOURCE',
    'PREP_ENCODE_FROM', 'PREP_ENCODE_TO', 'POST_TRANSLATION', 'POST_TRANS_SQL_QUERY',
    'POST_TRANSLATION_MAP', 'CLA_EXE_PATH', 'PRE_KEYWORD_REPLACE_FROM',
    'PRE_KEYWORD_REPLACE_TO', 'POST_KEYWORD_REPLACE_FROM', 'POST_KEYWORD_REPLACE_TO',
    'POST_TRANSLATION_OVERWRITE', 'MISC_REC1', 'GET_DOCS_API', 'POST_TRANSLATION_VITAL',
    'GET_EMPTY_DOCS', 'EMAIL_SUBJECT', 'POST_TRANS_FILE_RENAME', 'PRE_SQL_QUERY',
    'COMM_CALL_SQL_QUERY', 'COMM_CALL_CLA_EXE_PATH', 'COMM_CALL_WORKING_DIR',
    'DM_BATCH_SPLIT', 'TRANSLATION_STAGING', 'STAGING_CLA_EXE_PATH',
    'CUSTOM_FILE_FILTER', 'FILE_CLEAN_UP', 'PRE_DM_MERGE', 'ETL_PATH',
    'LOG_FILE_PATH', 'PREV_SEQ', 'ADDRESS_CHECK'
)

# Map of ProcessData XML field name → SI_ExecutionTracking column name.
# XML names are UPPER_CASE; our DB columns are lower_case. Built once at script
# scope from $Script:ProcessDataFields.
$Script:ProcessDataColumnMap = @{}
foreach ($f in $Script:ProcessDataFields) {
    $Script:ProcessDataColumnMap[$f] = $f.ToLower()
}

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

    return $true
}

# ============================================================================
# SHARED HELPERS
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

function Format-SqlStringLiteral {
    <#
    .SYNOPSIS
        Returns a SQL literal for a string value, or 'NULL' for null/empty.

    .NOTES
        $Value is untyped intentionally — a [string] type annotation causes
        PowerShell to coerce $null to '' at parameter binding, which defeats
        the null check on the first line and produces empty-string literals
        where we want NULL. Leaving it untyped preserves the distinction.
    #>
    param($Value, [switch]$AllowEmpty)

    if ($null -eq $Value) { return 'NULL' }
    $s = [string]$Value
    if (-not $AllowEmpty -and [string]::IsNullOrEmpty($s)) { return 'NULL' }
    return "N'" + ($s -replace "'", "''") + "'"
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

function Format-SqlBigIntLiteral {
    <#
    .SYNOPSIS
        Returns a SQL literal for a BIGINT value, or 'NULL' for null.
        Distinct from Format-SqlIntLiteral only for clarity at call sites
        where the column is BIGINT.
    #>
    param($Value)

    if ($null -eq $Value) { return 'NULL' }
    if ($Value -is [DBNull]) { return 'NULL' }
    return "$Value"
}

function Format-SqlBitLiteral {
    <#
    .SYNOPSIS
        Returns a SQL literal for a BIT value: 1, 0, or 'NULL'.
    #>
    param($Value)

    if ($null -eq $Value) { return 'NULL' }
    if ($Value -is [DBNull]) { return 'NULL' }
    if ($Value) { return '1' } else { return '0' }
}

function Format-SqlDateTimeLiteral {
    <#
    .SYNOPSIS
        Returns a SQL literal for a DATETIME value, or 'NULL' for null.
    #>
    param($Value)

    if ($null -eq $Value) { return 'NULL' }
    if ($Value -is [DBNull]) { return 'NULL' }
    $dt = [datetime]$Value
    return "'" + $dt.ToString('yyyy-MM-dd HH:mm:ss.fff') + "'"
}

# ============================================================================
# TIMINGXML PARSER (Block 1)
# ============================================================================

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
    if ($hasWeekDays -and $hasMonthDays)               { return $result }
    if ($usesTimeRange -and $usesExplicit)             { return $result }
    if (-not $usesTimeRange -and -not $usesExplicit)   { return $result }

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
            if ($dayMask -eq 'SMTWTFS') { $patternType = 'INTERVAL' }
            else                        { $patternType = 'MIXED' }
        }
        else {
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

    if ($usesExplicit -and $sortedTimes.Count -gt 0) {
        $result.first_run_time_of_day = Format-HHMM -Value $sortedTimes[0]
        $result.last_run_time_of_day  = Format-HHMM -Value $sortedTimes[-1]
        $result.expected_runs_per_day = $sortedTimes.Count
    }
    elseif ($usesTimeRange -and $rangeStart -and $rangeEnd -and $intervalMin -gt 0) {
        $result.first_run_time_of_day = Format-HHMM -Value $rangeStart
        $result.last_run_time_of_day  = Format-HHMM -Value $rangeEnd

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
            $description = "Daily at $timesText"
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
# STEP 1 — SCHEDULE SYNC (Block 1)
# ============================================================================

function Step-SyncSchedules {
    <#
    .SYNOPSIS
        Synchronizes B2B.SI_ScheduleRegistry from b2bi.dbo.SCHEDULE.
    #>
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

            $parsed = ConvertTo-ParsedSchedule -Xml $timingXml

            $handle   = [string]$row.TIMINGXML
            $srcStat  = [string]$row.STATUS
            $execStat = [string]$row.EXECUTIONSTATUS

            if (-not $existing.ContainsKey($scheduleId)) {
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
        Write-Log "  Error in Step-SyncSchedules: $($_.Exception.Message)" "ERROR"
        return @{ Inserted = $inserted; Updated = $updated; Deleted = $deleted; Errors = ($errors + 1); Error = $_.Exception.Message }
    }
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
# STEP 2 — EXECUTION COLLECTION (Block 2)
# ============================================================================

function Get-CompletedWorkflowIds {
    <#
    .SYNOPSIS
        Returns a HashSet<long> of workflow_ids already marked is_complete = 1
        in SI_ExecutionTracking. Used for anti-join against b2bi discovery.
    #>
    $query = "SELECT workflow_id FROM B2B.SI_ExecutionTracking WHERE is_complete = 1"
    $rows = Get-SqlData -Query $query

    $set = New-Object 'System.Collections.Generic.HashSet[long]'
    if ($rows) {
        foreach ($r in @($rows)) {
            $set.Add([long]$r.workflow_id) | Out-Null
        }
    }
    # Comma operator wraps return to prevent PowerShell from unwrapping
    # an empty collection into $null at the call site.
    return ,$set
}

function Parse-ProcessData {
    <#
    .SYNOPSIS
        Parses a decompressed ProcessData XML string. Returns a hashtable of
        lower-case column names to values (or $null for empty), plus the raw
        XML string.

    .DESCRIPTION
        MAIN's ProcessData has root element <Result> containing a single
        <Client> block with 73 known fields. Some older / GET_LIST-parent
        ProcessData uses root <r> instead; this function handles both.
        Self-closing empty tags (<FIELD/>) are normalized to $null.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Xml
    )

    $result = @{
        process_data_xml = $Xml
        fields           = $null
    }

    # Initialize all expected columns to null
    $fields = @{}
    foreach ($f in $Script:ProcessDataFields) {
        $fields[$Script:ProcessDataColumnMap[$f]] = $null
    }

    try {
        [xml]$doc = $Xml
    }
    catch {
        Write-Log "    ProcessData XML parse failed: $($_.Exception.Message)" "WARN"
        $result.fields = $fields
        return $result
    }

    # Locate the Client node. Try //Result/Client first (MAIN's ProcessData),
    # then //r/Client (GET_LIST-parent form).
    $clientNode = $null
    if ($null -ne $doc.Result -and $null -ne $doc.Result.Client) {
        $clientNode = @($doc.Result.Client)[0]
    }
    elseif ($null -ne $doc.r -and $null -ne $doc.r.Client) {
        $clientNode = @($doc.r.Client)[0]
    }

    if ($null -eq $clientNode) {
        Write-Log "    ProcessData has no /Result/Client or /r/Client node" "WARN"
        $result.fields = $fields
        return $result
    }

    # Extract each known field
    foreach ($xmlName in $Script:ProcessDataFields) {
        $columnName = $Script:ProcessDataColumnMap[$xmlName]
        $node = $clientNode.SelectSingleNode($xmlName)
        if ($null -eq $node) { continue }

        $text = $node.InnerText
        if ([string]::IsNullOrEmpty($text)) { continue }

        $fields[$columnName] = $text
    }

    $result.fields = $fields
    return $result
}

function Get-WorkflowContextSummary {
    <#
    .SYNOPSIS
        Fetches WORKFLOW_CONTEXT rows for a workflow and derives:
          - step count
          - had_* service-invocation flags
          - invocation counts for trans and archive
          - failure step detail (first step with BASIC_STATUS > 0)
          - root cause step (currently same as failure step; TODO below)

    .DESCRIPTION
        Returns a hashtable with:
          step_count, had_trans, had_vital, had_accounts_load, had_comm_call,
          had_archive, trans_invocation_count, archive_invocation_count,
          failure_step_id, failure_service_name, root_cause_step_id,
          root_cause_service_name, root_cause_adv_status, status_message

        TODO (future enhancement): true "root cause" detection requires scanning
        ADV_STATUS across service-specific patterns (e.g., FA_CLA_UNPGP exit
        code 255 is a root cause even with BASIC_STATUS=0). For v1, root cause
        == reported failure step. Architecture doc "Failure Signal — Nuanced"
        section covers the expansion plan.
    #>
    param(
        [Parameter(Mandatory)]
        [long]$WorkflowId
    )

    $summary = @{
        step_count                = $null
        had_trans                 = $null
        had_vital                 = $null
        had_accounts_load         = $null
        had_comm_call             = $null
        had_archive               = $null
        trans_invocation_count    = $null
        archive_invocation_count  = $null
        failure_step_id           = $null
        failure_service_name      = $null
        root_cause_step_id        = $null
        root_cause_service_name   = $null
        root_cause_adv_status     = $null
        status_message            = $null
    }

    # Single query returns all context rows needed for the summary
    $query = @"
SELECT STEP_ID, SERVICE_NAME, BASIC_STATUS, ADV_STATUS
FROM dbo.WORKFLOW_CONTEXT
WHERE WORKFLOW_ID = $WorkflowId
ORDER BY STEP_ID
"@

    $rows = Get-SqlData -Query $query `
                        -Instance $SourceInstance `
                        -DatabaseName $SourceDatabase `
                        -MaxCharLength 2147483647

    if (-not $rows) {
        # No context rows — workflow may have just started. Leave all fields null.
        $summary.step_count = 0
        return $summary
    }

    $rows = @($rows)
    $summary.step_count = $rows.Count

    # Scan for sub-workflow invocations and failure detection.
    #
    # Sub-workflow invocation detection — per b2bi convention, sub-workflow
    # invocations show up as WORKFLOW_CONTEXT rows where ADV_STATUS contains
    # the text "Inline Begin <NAME>+...". SERVICE_NAME is typically
    # "InvokeBusinessProcessService" for these rows, not the sub-workflow name.
    #
    # Failure detection — BASIC_STATUS values 0 and 10 are non-failure states;
    # anything else signals a failure. Per b2bi convention (validated against
    # the "Recent Failures" reference query).
    $transCount = 0
    $archiveCount = 0
    $hadVital = $false
    $hadAccountsLoad = $false
    $hadCommCall = $false
    $firstFailureRow = $null

    foreach ($ctx in $rows) {
        $adv = if ($ctx.ADV_STATUS -is [DBNull]) { $null } else { [string]$ctx.ADV_STATUS }

        if (-not [string]::IsNullOrEmpty($adv) -and $adv.Contains('Inline Begin ')) {
            # Cheap ordered checks — match the specific sub-workflow names we care about
            if     ($adv -match 'Inline Begin FA_CLIENTS_TRANS\b')         { $transCount++ }
            elseif ($adv -match 'Inline Begin FA_CLIENTS_ARCHIVE\b')       { $archiveCount++ }
            elseif ($adv -match 'Inline Begin FA_CLIENTS_VITAL\b')         { $hadVital = $true }
            elseif ($adv -match 'Inline Begin FA_CLIENTS_ACCOUNTS_LOAD\b') { $hadAccountsLoad = $true }
            elseif ($adv -match 'Inline Begin FA_CLIENTS_COMM_CALL\b')     { $hadCommCall = $true }
        }

        # Failure detection: first row with BASIC_STATUS NOT IN (0, 10)
        if ($null -eq $firstFailureRow) {
            if ($null -ne $ctx.BASIC_STATUS -and -not ($ctx.BASIC_STATUS -is [DBNull])) {
                $bs = [int]$ctx.BASIC_STATUS
                if ($bs -ne 0 -and $bs -ne 10) {
                    $firstFailureRow = $ctx
                }
            }
        }
    }

    $summary.had_trans                = ($transCount -gt 0)
    $summary.had_vital                = $hadVital
    $summary.had_accounts_load        = $hadAccountsLoad
    $summary.had_comm_call            = $hadCommCall
    $summary.had_archive              = ($archiveCount -gt 0)
    $summary.trans_invocation_count   = $transCount
    $summary.archive_invocation_count = $archiveCount

    if ($null -ne $firstFailureRow) {
        $stepId = [int]$firstFailureRow.STEP_ID
        $svcName = [string]$firstFailureRow.SERVICE_NAME
        $advStatus = if ($firstFailureRow.ADV_STATUS -is [DBNull]) { $null } else { [string]$firstFailureRow.ADV_STATUS }
        $basicStatus = [int]$firstFailureRow.BASIC_STATUS

        # For v1, root cause == reported failure. Expansion path documented above.
        $summary.failure_step_id         = $stepId
        $summary.failure_service_name    = $svcName
        $summary.root_cause_step_id      = $stepId
        $summary.root_cause_service_name = $svcName
        $summary.root_cause_adv_status   = $advStatus

        # Build a concise human-readable status_message (truncated ADV_STATUS)
        $advSnippet = if ($null -ne $advStatus -and $advStatus.Length -gt 400) {
            $advStatus.Substring(0, 400) + '...'
        } else {
            $advStatus
        }
        $summary.status_message = "Step $stepId ($svcName) BASIC_STATUS=$basicStatus; ADV_STATUS=$advSnippet"
    }

    return $summary
}

function Get-ProcessDataForWorkflow {
    <#
    .SYNOPSIS
        Fetches and decompresses the first DOCUMENT TRANS_DATA row for a
        workflow (the MAIN ProcessData). Returns the decompressed XML string,
        or $null on any failure.
    #>
    param(
        [Parameter(Mandatory)]
        [long]$WorkflowId
    )

    # MAIN writes its ProcessData at Step 0, so it's the first row by
    # CREATION_DATE ASC among REFERENCE_TABLE='DOCUMENT' PAGE_INDEX=0 rows.
    $query = @"
SELECT TOP 1 DATA_OBJECT
FROM dbo.TRANS_DATA
WHERE WF_ID = $WorkflowId
  AND REFERENCE_TABLE = 'DOCUMENT'
  AND PAGE_INDEX = 0
ORDER BY CREATION_DATE ASC, DATA_ID ASC
"@

    $row = Get-SqlData -Query $query `
                       -Instance $SourceInstance `
                       -DatabaseName $SourceDatabase `
                       -MaxBinaryLength 20971520

    if (-not $row) { return $null }

    $blob = $row.DATA_OBJECT
    if ($blob -is [DBNull] -or $null -eq $blob) { return $null }

    try {
        return Expand-GzipBytes -Bytes ([byte[]]$blob)
    }
    catch {
        Write-Log "    ProcessData decompression failed for WF ${WorkflowId}: $($_.Exception.Message)" "WARN"
        return $null
    }
}

function Get-WorkflowLinkage {
    <#
    .SYNOPSIS
        Resolves parent_workflow_id and root_workflow_id for a workflow.

    .DESCRIPTION
        dbo.WORKFLOW_LINKAGE has one row per parent-child relationship with
        columns ROOT_WF_ID, P_WF_ID (parent), C_WF_ID (child), TYPE.
        ROOT_WF_ID is pre-computed, so one query gets both parent and root.
        Returns a hashtable with parent_workflow_id and root_workflow_id,
        each $null if no parent exists (top-level workflow).
    #>
    param(
        [Parameter(Mandatory)]
        [long]$WorkflowId
    )

    $result = @{
        parent_workflow_id = $null
        root_workflow_id   = $null
    }

    $query = "SELECT TOP 1 P_WF_ID, ROOT_WF_ID FROM dbo.WORKFLOW_LINKAGE WHERE C_WF_ID = $WorkflowId"
    $row = Get-SqlData -Query $query `
                       -Instance $SourceInstance `
                       -DatabaseName $SourceDatabase

    if (-not $row) {
        # No linkage row — this workflow is a top-level root (no parent)
        return $result
    }

    if ($null -ne $row.P_WF_ID -and -not ($row.P_WF_ID -is [DBNull])) {
        $result.parent_workflow_id = [long]$row.P_WF_ID
    }
    if ($null -ne $row.ROOT_WF_ID -and -not ($row.ROOT_WF_ID -is [DBNull])) {
        $result.root_workflow_id = [long]$row.ROOT_WF_ID
    }

    return $result
}

function ConvertTo-RunClass {
    <#
    .SYNOPSIS
        Classifies a run as FILE_PROCESS, INTERNAL_OP, or UNCLASSIFIED based
        on ProcessData fields.

    .DESCRIPTION
        Classification is evaluated in priority order — INTERNAL_OP signals
        win over FILE_PROCESS signals because a workflow running an Integration
        SP is fundamentally an SP-executor even if it also has file-processing
        signals present.

        INTERNAL_OP signals (any match):
          1. CLIENT_ID = 328  (INTEGRATION TOOLS pseudo-client)
          2. POST_TRANS_SQL_QUERY points at an Integration SP — either
             literal ('EXEC Integration....') or XPath concat() wrapping
             the same ('concat(\'EXEC Integration....\', string(//...))').
             Both patterns indicate the workflow's primary work is executing
             an Integration SP, regardless of CLIENT_ID.

        FILE_PROCESS signals (any match, if no INTERNAL_OP signal):
          1. FILE_FILTER, GET_DOCS_TYPE, or PUT_DOCS_TYPE populated
             (standard inbound/outbound file configuration)
          2. COMM_CALL_CLA_EXE_PATH populated
             (external exe orchestration — e.g. ACADIA EO merge phase,
             REVSPRING email scrub)
          3. PROCESS_TYPE in push-operation whitelist
             (SFTP_PUSH, SFTP_PUSH_ED25519 — outbound push operations
             that don't need other signals to be configured)

        UNCLASSIFIED: anything else — legitimately unknown and worth surfacing.
        In steady state this bucket should be empty; non-zero count indicates
        a workflow pattern we haven't characterized yet.
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable]$Fields
    )

    $clientId            = $Fields['client_id']
    $processType         = $Fields['process_type']
    $fileFilter          = $Fields['file_filter']
    $getDocsType         = $Fields['get_docs_type']
    $putDocsType         = $Fields['put_docs_type']
    $commCallExePath     = $Fields['comm_call_cla_exe_path']
    $postTransSqlQuery   = $Fields['post_trans_sql_query']

    # -------------------------------------------------------------------
    # INTERNAL_OP — evaluated first (SP executor wins over file signals)
    # -------------------------------------------------------------------
    if ($clientId -eq '328') {
        return 'INTERNAL_OP'
    }
    # POST_TRANS_SQL_QUERY can be a literal SQL statement OR an XPath
    # concat() expression that builds SQL at runtime. Both patterns point
    # at Integration SPs and both indicate SP-executor runs:
    #   Literal:  EXEC Integration.FAINT.USP_FOO ...
    #   Dynamic:  concat('EXEC Integration.FAINT.USP_FOO ', string(//...))
    if (-not [string]::IsNullOrEmpty($postTransSqlQuery) -and (
            $postTransSqlQuery -match '^\s*EXEC\s+Integration\.' -or
            $postTransSqlQuery -match "^\s*concat\s*\(\s*'EXEC\s+Integration\."
        )) {
        return 'INTERNAL_OP'
    }

    # -------------------------------------------------------------------
    # FILE_PROCESS — standard file config or always-file process types
    # -------------------------------------------------------------------
    if (-not [string]::IsNullOrEmpty($fileFilter))      { return 'FILE_PROCESS' }
    if (-not [string]::IsNullOrEmpty($getDocsType))     { return 'FILE_PROCESS' }
    if (-not [string]::IsNullOrEmpty($putDocsType))     { return 'FILE_PROCESS' }
    if (-not [string]::IsNullOrEmpty($commCallExePath)) { return 'FILE_PROCESS' }

    # PROCESS_TYPE whitelist for operations that don't need additional signals.
    # Currently push-type outbound operations — they push whatever's present
    # regardless of explicit file_filter configuration.
    $alwaysFileProcessTypes = @('SFTP_PUSH', 'SFTP_PUSH_ED25519')
    if (-not [string]::IsNullOrEmpty($processType) -and
        $alwaysFileProcessTypes -contains $processType) {
        return 'FILE_PROCESS'
    }

    return 'UNCLASSIFIED'
}

function ConvertTo-CompletionState {
    <#
    .SYNOPSIS
        Evaluates whether a workflow has reached a terminal state in b2bi.
        Returns a hashtable with is_complete (bool) and completed_status
        (string or $null).

    .DESCRIPTION
        Terminal state detection: END_TIME populated on WF_INST_S is the
        signal that the workflow has ended. Verified against production
        data — every observed row with END_TIME populated represented a
        terminal state, and every in-flight workflow had END_TIME null.

        Sterling WF_INST_S.STATUS semantics (verified against prod):
          STATUS = 0  → completed successfully
          STATUS = 1  → terminated with errors (failed)
          STATUS = 2  → not observed in production (documented in some
                        Sterling references but appears unused at FAC)

        WF_INST_S.STATE is not used for classification — observed values
        are numeric state codes that add no information on top of STATUS.
    #>
    param(
        [Parameter(Mandatory)]
        $InstRow
    )

    $result = @{
        is_complete      = $false
        completed_status = $null
    }

    # END_TIME populated is our signal that the workflow has ended
    $endTime = $InstRow.END_TIME
    $hasEndTime = $null -ne $endTime -and -not ($endTime -is [DBNull])

    if (-not $hasEndTime) {
        return $result
    }

    $result.is_complete = $true

    $status = $null
    if ($null -ne $InstRow.STATUS -and -not ($InstRow.STATUS -is [DBNull])) {
        $status = [int]$InstRow.STATUS
    }

    $result.completed_status = switch ($status) {
        0       { 'SUCCESS' }
        1       { 'FAILED' }
        default { "STATUS_$status" }
    }

    return $result
}

function Invoke-ExecutionTrackingMerge {
    <#
    .SYNOPSIS
        Writes a single workflow's collected data to B2B.SI_ExecutionTracking
        via INSERT (new) or UPDATE (existing in-flight).

    .PARAMETER InstRow
        The WF_INST_S source row.

    .PARAMETER Linkage
        Hashtable from Get-WorkflowLinkage.

    .PARAMETER ContextSummary
        Hashtable from Get-WorkflowContextSummary.

    .PARAMETER ProcessData
        Hashtable from Parse-ProcessData (may have null fields / null xml
        if ProcessData couldn't be fetched or parsed — partial row is written).

    .PARAMETER RunClass
        FILE_PROCESS / INTERNAL_OP / UNCLASSIFIED, or $null.

    .PARAMETER CompletionState
        Hashtable from ConvertTo-CompletionState.

    .PARAMETER IsNewRow
        $true for INSERT, $false for UPDATE.
    #>
    param(
        [Parameter(Mandatory)]$InstRow,
        [Parameter(Mandatory)][hashtable]$Linkage,
        [Parameter(Mandatory)][hashtable]$ContextSummary,
        [Parameter(Mandatory)][hashtable]$ProcessData,
        $RunClass,
        [Parameter(Mandatory)][hashtable]$CompletionState,
        [Parameter(Mandatory)][bool]$IsNewRow
    )

    $workflowId = [long]$InstRow.WORKFLOW_ID
    $fields     = if ($null -ne $ProcessData -and $null -ne $ProcessData.fields) { $ProcessData.fields } else { @{} }
    $pdXml      = if ($null -ne $ProcessData) { $ProcessData.process_data_xml } else { $null }

    # Build ProcessData column assignment list in PIVOT order
    $pdAssignments = @()
    foreach ($xmlField in $Script:ProcessDataFields) {
        $col = $Script:ProcessDataColumnMap[$xmlField]
        $val = $fields[$col]

        # client_id, seq_id, file_id are BIGINT / INT in our schema;
        # prev_seq is INT. Everything else is string.
        $literal = switch ($col) {
            'client_id' { Format-SqlBigIntLiteral $val }
            'seq_id'    { Format-SqlIntLiteral $val }
            'prev_seq'  { Format-SqlIntLiteral $val }
            default     { Format-SqlStringLiteral $val }
        }

        $pdAssignments += @{ col = $col; literal = $literal }
    }

    # Common field literals
    $workflowStartLit   = Format-SqlDateTimeLiteral $InstRow.START_TIME
    $workflowEndLit     = Format-SqlDateTimeLiteral $InstRow.END_TIME
    $durationMsLit      = 'NULL'
    if ($null -ne $InstRow.END_TIME -and -not ($InstRow.END_TIME -is [DBNull])) {
        $duration = [int](([datetime]$InstRow.END_TIME - [datetime]$InstRow.START_TIME).TotalMilliseconds)
        $durationMsLit = "$duration"
    }
    $b2biStatusLit      = Format-SqlIntLiteral $InstRow.STATUS
    $b2biStateLit       = Format-SqlStringLiteral $InstRow.STATE
    $stepCountLit       = Format-SqlIntLiteral $ContextSummary.step_count

    $parentLit          = Format-SqlBigIntLiteral $Linkage.parent_workflow_id
    $rootLit            = Format-SqlBigIntLiteral $Linkage.root_workflow_id

    $runClassLit        = Format-SqlStringLiteral $RunClass
    $processDataXmlLit  = Format-SqlStringLiteral $pdXml -AllowEmpty

    $rcStepLit          = Format-SqlIntLiteral $ContextSummary.root_cause_step_id
    $rcServiceLit       = Format-SqlStringLiteral $ContextSummary.root_cause_service_name
    $rcAdvLit           = Format-SqlStringLiteral $ContextSummary.root_cause_adv_status
    $failStepLit        = Format-SqlIntLiteral $ContextSummary.failure_step_id
    $failServiceLit     = Format-SqlStringLiteral $ContextSummary.failure_service_name
    $statusMsgLit       = Format-SqlStringLiteral $ContextSummary.status_message

    $hadTransLit        = Format-SqlBitLiteral $ContextSummary.had_trans
    $hadVitalLit        = Format-SqlBitLiteral $ContextSummary.had_vital
    $hadAccountsLit     = Format-SqlBitLiteral $ContextSummary.had_accounts_load
    $hadCommCallLit     = Format-SqlBitLiteral $ContextSummary.had_comm_call
    $hadArchiveLit      = Format-SqlBitLiteral $ContextSummary.had_archive
    $transCountLit      = Format-SqlIntLiteral $ContextSummary.trans_invocation_count
    $archiveCountLit    = Format-SqlIntLiteral $ContextSummary.archive_invocation_count

    $isCompleteLit      = Format-SqlBitLiteral $CompletionState.is_complete
    $completedDttmLit   = if ($CompletionState.is_complete) { 'GETDATE()' } else { 'NULL' }
    $completedStatusLit = Format-SqlStringLiteral $CompletionState.completed_status

    if ($IsNewRow) {
        # Build column list and value list for INSERT
        $pdColList  = ($pdAssignments | ForEach-Object { $_.col }) -join ', '
        $pdValList  = ($pdAssignments | ForEach-Object { $_.literal }) -join ', '

        $sql = @"
INSERT INTO B2B.SI_ExecutionTracking (
    workflow_id, workflow_start_time, workflow_end_time, duration_ms,
    b2bi_status, b2bi_state, step_count,
    parent_workflow_id, root_workflow_id,
    $pdColList,
    run_class, process_data_xml,
    root_cause_step_id, root_cause_service_name, root_cause_adv_status,
    failure_step_id, failure_service_name, status_message,
    had_trans, had_vital, had_accounts_load, had_comm_call, had_archive,
    trans_invocation_count, archive_invocation_count,
    is_complete, completed_dttm, completed_status
)
VALUES (
    $workflowId, $workflowStartLit, $workflowEndLit, $durationMsLit,
    $b2biStatusLit, $b2biStateLit, $stepCountLit,
    $parentLit, $rootLit,
    $pdValList,
    $runClassLit, $processDataXmlLit,
    $rcStepLit, $rcServiceLit, $rcAdvLit,
    $failStepLit, $failServiceLit, $statusMsgLit,
    $hadTransLit, $hadVitalLit, $hadAccountsLit, $hadCommCallLit, $hadArchiveLit,
    $transCountLit, $archiveCountLit,
    $isCompleteLit, $completedDttmLit, $completedStatusLit
)
"@
    }
    else {
        # UPDATE — set all fields that might have changed since last cycle
        $pdSetClauses = ($pdAssignments | ForEach-Object { "    $($_.col) = $($_.literal)" }) -join ",`n"

        $sql = @"
UPDATE B2B.SI_ExecutionTracking
SET workflow_end_time         = $workflowEndLit,
    duration_ms               = $durationMsLit,
    b2bi_status               = $b2biStatusLit,
    b2bi_state                = $b2biStateLit,
    step_count                = $stepCountLit,
    parent_workflow_id        = $parentLit,
    root_workflow_id          = $rootLit,
$pdSetClauses,
    run_class                 = $runClassLit,
    process_data_xml          = $processDataXmlLit,
    root_cause_step_id        = $rcStepLit,
    root_cause_service_name   = $rcServiceLit,
    root_cause_adv_status     = $rcAdvLit,
    failure_step_id           = $failStepLit,
    failure_service_name      = $failServiceLit,
    status_message            = $statusMsgLit,
    had_trans                 = $hadTransLit,
    had_vital                 = $hadVitalLit,
    had_accounts_load         = $hadAccountsLit,
    had_comm_call             = $hadCommCallLit,
    had_archive               = $hadArchiveLit,
    trans_invocation_count    = $transCountLit,
    archive_invocation_count  = $archiveCountLit,
    is_complete               = $isCompleteLit,
    completed_dttm            = $completedDttmLit,
    completed_status          = $completedStatusLit
WHERE workflow_id = $workflowId
"@
    }

    return Invoke-SqlNonQuery -Query $sql -MaxCharLength 2147483647
}

function Step-CollectExecutions {
    <#
    .SYNOPSIS
        Collects FA_CLIENTS_MAIN workflow runs from b2bi into
        B2B.SI_ExecutionTracking.

    .DESCRIPTION
        Per-cycle flow:
          1. Load the set of workflow_ids already is_complete = 1 in xFACts
             (anti-join set).
          2. Load the set of in-flight workflow_ids (is_complete = 0) from
             xFACts (INSERT vs UPDATE decision set).
          3. Query b2bi WF_INST_S JOIN WFD for FA_CLIENTS_MAIN runs in the
             lookback window. Name-based filtering survives Sterling
             WFD_ID/WFD_VERSION changes.
          4. Filter out rows already complete (anti-join in memory).
          5. For each remaining workflow: gather linkage, WORKFLOW_CONTEXT
             summary, ProcessData; classify; evaluate completion; MERGE.

        Failures in individual-workflow processing are logged and the row
        is written with partial data rather than skipped — this lets
        is_complete still flip on terminal state so the row exits the
        in-flight set on future cycles.
    #>
    param([bool]$PreviewOnly = $true)

    Write-Log "Step: Collect Executions" "STEP"

    $newCount      = 0
    $updatedCount  = 0
    $completedCount = 0
    $errorCount    = 0

    try {
        # Step 1: Load already-complete workflow ids (anti-join set)
        $completedSet = Get-CompletedWorkflowIds
        Write-Log "  Already-complete rows to anti-join: $($completedSet.Count)" "INFO"

        # Step 2: Load in-flight workflow ids (rows existing with is_complete = 0).
        # Used to determine INSERT vs UPDATE for each discovered row.
        $inflightQuery = "SELECT workflow_id FROM B2B.SI_ExecutionTracking WHERE is_complete = 0"
        $inflightRows = Get-SqlData -Query $inflightQuery
        $inflightSet = New-Object 'System.Collections.Generic.HashSet[long]'
        if ($inflightRows) {
            foreach ($r in @($inflightRows)) {
                $inflightSet.Add([long]$r.workflow_id) | Out-Null
            }
        }
        Write-Log "  In-flight rows to refresh: $($inflightSet.Count)" "INFO"

        # Step 3: Query b2bi for FA_CLIENTS_MAIN runs in window.
        # Filter by workflow NAME via WFD join — robust against Sterling
        # WFD_ID/WFD_VERSION changes across redeployments. b2bi collation
        # is case-sensitive, so NAME must match exactly.
        $lookbackDays = $Script:Config.B2B_CollectLookbackDays
        $lookbackDate = (Get-Date).AddDays(-$lookbackDays).ToString('yyyy-MM-dd HH:mm:ss')

        $wfQuery = @"
SELECT wis.WORKFLOW_ID, wis.WFD_ID, wis.WFD_VERSION,
       wis.START_TIME, wis.END_TIME, wis.STATUS, wis.STATE
FROM dbo.WF_INST_S wis
INNER JOIN dbo.WFD wfd
    ON wfd.WFD_ID = wis.WFD_ID
   AND wfd.WFD_VERSION = wis.WFD_VERSION
WHERE wfd.NAME = 'FA_CLIENTS_MAIN'
  AND wis.START_TIME >= '$lookbackDate'
ORDER BY wis.START_TIME
"@

        $wfRows = Get-SqlData -Query $wfQuery `
                              -Instance $SourceInstance `
                              -DatabaseName $SourceDatabase
        if (-not $wfRows) {
            Write-Log "  No FA_CLIENTS_MAIN runs found in lookback window ($lookbackDays days)" "INFO"
            return @{ New = 0; Updated = 0; Completed = 0; Errors = 0 }
        }

        $wfRows = @($wfRows)
        Write-Log "  Fetched $($wfRows.Count) FA_CLIENTS_MAIN run(s) from b2bi" "INFO"

        # Step 4: Anti-join against completed set
        try {
            $toProcess = @()
            $skipped = 0
            foreach ($wf in $wfRows) {
                # Defensive: skip rows with null WORKFLOW_ID (shouldn't happen but
                # would throw a cryptic null-method error in the cast below)
                if ($null -eq $wf -or $null -eq $wf.WORKFLOW_ID -or $wf.WORKFLOW_ID -is [DBNull]) {
                    $skipped++
                    continue
                }
                $id = [long]$wf.WORKFLOW_ID
                if (-not $completedSet.Contains($id)) {
                    $toProcess += $wf
                }
            }
            if ($skipped -gt 0) {
                Write-Log "  Anti-join skipped $skipped row(s) with null WORKFLOW_ID" "WARN"
            }
        }
        catch {
            Write-Log "  Error during anti-join phase: $($_.Exception.Message)" "ERROR"
            throw
        }
        Write-Log "  To process (new + in-flight): $($toProcess.Count)" "INFO"

        if ($toProcess.Count -eq 0) {
            return @{ New = 0; Updated = 0; Completed = 0; Errors = 0 }
        }

        # Step 5: Per-workflow processing loop
        $processedSinceLog = 0
        $progressInterval = 100

        foreach ($wf in $toProcess) {
            $workflowId = [long]$wf.WORKFLOW_ID
            $isNew = -not $inflightSet.Contains($workflowId)

            try {
                # Gather all per-workflow data
                $linkage = Get-WorkflowLinkage -WorkflowId $workflowId
                $contextSummary = Get-WorkflowContextSummary -WorkflowId $workflowId

                # ProcessData — write partial row if fetch/parse fails.
                # Guard against null AND empty string; Parse-ProcessData rejects
                # empty strings via its Mandatory parameter binding.
                $pdXml = Get-ProcessDataForWorkflow -WorkflowId $workflowId
                $processData = if (-not [string]::IsNullOrWhiteSpace($pdXml)) {
                    Parse-ProcessData -Xml $pdXml
                } else {
                    @{ process_data_xml = $null; fields = @{} }
                }

                # Classify
                $runClass = if ($null -ne $processData.fields -and $processData.fields.Count -gt 0) {
                    ConvertTo-RunClass -Fields $processData.fields
                } else {
                    'UNCLASSIFIED'
                }

                # Evaluate completion
                $completion = ConvertTo-CompletionState -InstRow $wf

                # MERGE
                if ($PreviewOnly) {
                    $action = if ($isNew) { 'INSERT' } else { 'UPDATE' }
                    $completionNote = if ($completion.is_complete) { " [completes: $($completion.completed_status)]" } else { '' }
                    Write-Log "  [Preview] Would $action WF $workflowId ($runClass)$completionNote" "INFO"
                    if ($isNew) { $newCount++ } else { $updatedCount++ }
                    if ($completion.is_complete) { $completedCount++ }
                }
                else {
                    $ok = Invoke-ExecutionTrackingMerge `
                        -InstRow $wf `
                        -Linkage $linkage `
                        -ContextSummary $contextSummary `
                        -ProcessData $processData `
                        -RunClass $runClass `
                        -CompletionState $completion `
                        -IsNewRow $isNew

                    if ($ok) {
                        if ($isNew) { $newCount++ } else { $updatedCount++ }
                        if ($completion.is_complete) { $completedCount++ }
                    }
                    else {
                        $errorCount++
                    }
                }
            }
            catch {
                Write-Log "  WF ${workflowId}: processing failed — $($_.Exception.Message)" "ERROR"
                $errorCount++
            }

            $processedSinceLog++
            if ($processedSinceLog -ge $progressInterval) {
                Write-Log "  Progress: new=$newCount updated=$updatedCount completed=$completedCount errors=$errorCount" "INFO"
                $processedSinceLog = 0
            }
        }

        Write-Log "  Summary: new=$newCount updated=$updatedCount completed=$completedCount errors=$errorCount" "INFO"
        return @{ New = $newCount; Updated = $updatedCount; Completed = $completedCount; Errors = $errorCount }
    }
    catch {
        Write-Log "  Error in Step-CollectExecutions: $($_.Exception.Message)" "ERROR"
        return @{ New = $newCount; Updated = $updatedCount; Completed = $completedCount; Errors = ($errorCount + 1); Error = $_.Exception.Message }
    }
}

# ============================================================================
# STEP 3 — EXECUTION DETAIL EXTRACTION (Block 3, stubbed)
# ============================================================================

function Step-CollectExecutionDetail {
    <#
    .SYNOPSIS
        [Block 3 - not yet implemented] Extracts per-file/per-creditor detail
        from Translation output documents and writes to SI_ExecutionDetail.
    #>
    param([bool]$PreviewOnly = $true)

    Write-Log "Step: Collect Execution Detail — [Block 3 stub]" "STEP"
    return @{ Extracted = 0 }
}

# ============================================================================
# STEP 4 — ALERT EVALUATION (Phase 4, stubbed)
# ============================================================================

function Step-EvaluateAlerts {
    <#
    .SYNOPSIS
        [Phase 4 - not yet implemented] Evaluates terminal FAILED rows and
        queues Teams alerts for ones not already alerted on.
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

# Step 2 — Collect executions (Block 2)
$stepResults.Executions = Step-CollectExecutions -PreviewOnly $previewOnly

# Step 3 — Execution detail (Block 3 stub)
$stepResults.Detail = Step-CollectExecutionDetail -PreviewOnly $previewOnly

# Step 4 — Alert evaluation (Phase 4 stub)
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
if ($stepResults.Executions.Error -or $stepResults.Executions.Errors -gt 0) {
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
Write-Host "  Executions:"
Write-Host "    New:       $($stepResults.Executions.New)"
Write-Host "    Updated:   $($stepResults.Executions.Updated)"
Write-Host "    Completed: $($stepResults.Executions.Completed)"
Write-Host "    Errors:    $($stepResults.Executions.Errors)"
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
    $output = "SchedIns:$($stepResults.Schedules.Inserted) SchedUpd:$($stepResults.Schedules.Updated) SchedDel:$($stepResults.Schedules.Deleted) SchedErr:$($stepResults.Schedules.Errors) | ExecNew:$($stepResults.Executions.New) ExecUpd:$($stepResults.Executions.Updated) ExecDone:$($stepResults.Executions.Completed) ExecErr:$($stepResults.Executions.Errors)"

    Complete-OrchestratorTask -TaskId $TaskId -ProcessId $ProcessId `
        -Status $finalStatus -DurationMs $totalMs `
        -Output $output
}

if ($finalStatus -eq "FAILED") { exit 1 } else { exit 0 }
<#
.SYNOPSIS
    xFACts - IBM Sterling B2B Integrator execution monitoring

.DESCRIPTION
    Single collector for the B2B module. Synchronizes the schedule registry from
    b2bi.dbo.SCHEDULE and collects FA_CLIENTS_MAIN workflow executions from b2bi
    into SI_ExecutionTracking.

    This script is built in phases matching the B2B module development plan:
      Block 1 (complete) - Schedule sync into B2B.SI_ScheduleRegistry.
      Block 2 (current)  - Execution collection into B2B.SI_ExecutionTracking,
                           100% sourced from b2bi with no Integration enrichment.
      Block 3 (future)   - Detail extraction into B2B.SI_ExecutionDetail (stubbed).
      Phase 4 (future)   - Alert evaluation (b2bi terminal failed state -> Teams),
                           currently stubbed.

    Source server: FA-INT-DBP (b2bi database) via Windows auth.
    Target server: AVG-PROD-LSNR (xFACts database) via Windows auth.

    Architectural note: SI_ tables are 100% b2bi-sourced. Integration tables are
    live-joined in Control Center queries or future Phase 4 alerting logic, never
    mirrored into SI_ tables.

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

.COMPONENT
    B2B

.NOTES
    File Name : Collect-B2BExecution.ps1
    Location  : E:\xFACts-PowerShell

    FILE ORGANIZATION
    -----------------
    CHANGELOG: CHANGE HISTORY
    PARAMETERS: SCRIPT PARAMETERS
    IMPORTS: SCRIPT DEPENDENCIES
    INITIALIZATION: SCRIPT INITIALIZATION
    CONSTANTS: PROCESSDATA FIELD MAP
    VARIABLES: SCRIPT STATE
    FUNCTIONS: CONFIGURATION
    FUNCTIONS: SHARED HELPERS
    FUNCTIONS: SCHEDULE SYNC
    FUNCTIONS: EXECUTION COLLECTION
    FUNCTIONS: EXECUTION DETAIL
    FUNCTIONS: ALERT EVALUATION
    EXECUTION: SCRIPT EXECUTION
#>

<# ============================================================================
   CHANGELOG: CHANGE HISTORY
   ----------------------------------------------------------------------------
   Dated change history, most recent first. Authoritative version tracking lives
   in dbo.System_Metadata (component B2B).
   Prefix: (none)
   ============================================================================ #>

# 2026-06-19  Conformed to the xFACts PowerShell file format spec: section banners,
#             comment-based-help header with .COMPONENT, dedicated CHANGELOG section,
#             b2b-prefixed local functions and script-scope identifiers, single-line
#             purpose comments, and Write-Console output in place of Write-Host. Renamed
#             Parse-ProcessData to ConvertFrom-b2b_ProcessData (approved verb). Moved the
#             ProcessData column-map build into the INITIALIZATION section.
# 2026-04-22  Fixed ConvertTo-CompletionState STATUS semantics. Original code treated
#             STATUS=0 as in-progress and STATUS=2 as success, inverted from Sterling
#             convention. Verified against production: STATUS=0 = SUCCESS, STATUS=1 =
#             FAILED, END_TIME populated = terminal in both cases. STATE is a numeric
#             state code (always 1 in observed data) and is no longer consulted.
# 2026-04-22  Extended INTERNAL_OP POST_TRANS_SQL_QUERY match to cover the XPath concat()
#             wrapping pattern used by BDL-style SP executors. The stored value is not a
#             literal SQL statement but an XPath expression that builds the EXEC at runtime
#             by embedding INVOKE_ID_LIST. Now matches both literal EXEC Integration.
#             prefixes and the concat() XPath wrappers.
# 2026-04-22  Expanded ConvertTo-RunClass to eliminate UNCLASSIFIED rows from overly-narrow
#             initial rules. INTERNAL_OP now also matches workflows whose POST_TRANS_SQL_QUERY
#             begins with EXEC Integration. (SP-executor pattern regardless of CLIENT_ID).
#             FILE_PROCESS now also matches workflows with COMM_CALL_CLA_EXE_PATH populated
#             and PROCESS_TYPE of SFTP_PUSH or SFTP_PUSH_ED25519. INTERNAL_OP signals are
#             evaluated first so SP-executor classification wins over file signals.
# 2026-04-22  Fixed silent ProcessData truncation - Get-ProcessDataForWorkflow now passes
#             -MaxBinaryLength to Get-SqlData. Previously only -MaxCharLength was specified,
#             leaving binary blobs at the Invoke-Sqlcmd default of 1024 bytes, which silently
#             truncated larger ProcessData mid-stream and produced UNCLASSIFIED rows with
#             empty process_data_xml. Block 1 schedule fetch updated to match.
# 2026-04-22  Block 2 query corrections. WF_INST_S now joins WFD on (WFD_ID + WFD_VERSION)
#             and filters by name (survives Sterling workflow version changes). WORKFLOW_LINKAGE
#             uses C_WF_ID, P_WF_ID, ROOT_WF_ID. Sub-workflow invocation detection now uses the
#             ADV_STATUS Inline Begin pattern. Failure scan uses BASIC_STATUS NOT IN (0, 10).
# 2026-04-22  Block 2 implemented - Step-CollectExecutions populates B2B.SI_ExecutionTracking
#             from b2bi (WF_INST_S, WORKFLOW_LINKAGE, WORKFLOW_CONTEXT, TRANS_DATA).
#             Step-EnrichFromIntegration removed - table design is pure b2bi per revised
#             architecture.
# 2026-04-22  Initial implementation. Block 1 schedule sync complete; Block 2/3 steps stubbed.

<# ============================================================================
   PARAMETERS: SCRIPT PARAMETERS
   ----------------------------------------------------------------------------
   Connection targets for the xFACts and b2bi instances, the Execute write-guard, and
   the orchestrator TaskId/ProcessId callback identifiers.
   Prefix: (none)
   ============================================================================ #>

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

<# ============================================================================
   IMPORTS: SCRIPT DEPENDENCIES
   ----------------------------------------------------------------------------
   Shared orchestrator and script-infrastructure functions: initialization, logging,
   SQL access, and the completion callback.
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

Initialize-XFActsScript -ScriptName 'Collect-B2BExecution' `
    -ServerInstance $ServerInstance -Database $Database -Execute:$Execute

<# ============================================================================
   CONSTANTS: PROCESSDATA FIELD MAP
   ----------------------------------------------------------------------------
   The ProcessData XML field names in SP PIVOT order, and the (initially empty) map from
   each XML field name to its SI_ExecutionTracking column. The map is filled in the
   INITIALIZATION section.
   Prefix: b2b
   ============================================================================ #>

# ProcessData XML field names in SP PIVOT order (matches XML element order). Drives both
# the parsing loop and the SQL column ordering in MERGE operations. These 73 field names
# are the authoritative output of the GET_LIST PIVOT, confirmed against 30 sample XMLs
# covering 21 process-type pairs.
$script:b2b_ProcessDataFields = @(
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

# Map of ProcessData XML field name to SI_ExecutionTracking column name. XML names are
# UPPER_CASE; DB columns are lower_case. Populated once in the INITIALIZATION section.
$script:b2b_ProcessDataColumnMap = @{}

<# ============================================================================
   VARIABLES: SCRIPT STATE
   ----------------------------------------------------------------------------
   Mutable script-scope state populated at runtime: the loaded B2B GlobalConfig settings.
   Prefix: b2b
   ============================================================================ #>

# Loaded B2B GlobalConfig settings (alerting toggle, collection lookback window).
$script:b2b_Config = @{}

<# ============================================================================
   FUNCTIONS: CONFIGURATION
   ----------------------------------------------------------------------------
   Loads B2B GlobalConfig settings and builds the ProcessData column map used by the
   collection and parsing functions.
   Prefix: b2b
   ============================================================================ #>

# Loads B2B config, builds the ProcessData column map, and logs the resolved settings.
function Initialize-b2b_Config {
    param()

    # Build the ProcessData column map once (XML field name -> lower-case column).
    foreach ($f in $script:b2b_ProcessDataFields) {
        $script:b2b_ProcessDataColumnMap[$f] = $f.ToLower()
    }

    Write-Log "Loading configuration..." "INFO"

    # Defaults (also act as fallback if GlobalConfig row is missing)
    $script:Config = @{
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
                'b2b_alerting_enabled'      { $script:Config.B2B_AlertingEnabled     = [bool][int]$row.setting_value }
                'b2b_collect_lookback_days' { $script:Config.B2B_CollectLookbackDays = [int]$row.setting_value }
            }
        }
    }

    Write-Log "  B2B_AlertingEnabled:     $($script:Config.B2B_AlertingEnabled)" "INFO"
    Write-Log "  B2B_CollectLookbackDays: $($script:Config.B2B_CollectLookbackDays)" "INFO"
    Write-Log "  Source (b2bi):           $SourceInstance / $SourceDatabase" "INFO"
    Write-Log "  Target (xFACts):         $ServerInstance / $Database" "INFO"

    return $true
}

<# ============================================================================
   FUNCTIONS: SHARED HELPERS
   ----------------------------------------------------------------------------
   Low-level utilities shared across the steps: gzip decompression, SQL literal
   formatting by type, and schedule time/day formatting helpers.
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

# Returns a SQL literal for a BIGINT value, or 'NULL' for null.
function Format-b2b_SqlBigIntLiteral {
    param($Value)

    if ($null -eq $Value) { return 'NULL' }
    if ($Value -is [DBNull]) { return 'NULL' }
    return "$Value"
}

# Returns a SQL literal for a BIT value: 1, 0, or 'NULL'.
function Format-b2b_SqlBitLiteral {
    param($Value)

    if ($null -eq $Value) { return 'NULL' }
    if ($Value -is [DBNull]) { return 'NULL' }
    if ($Value) { return '1' } else { return '0' }
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
   Block 1: parses Sterling TIMINGXML into structured schedule fields and synchronizes
   B2B.SI_ScheduleRegistry from b2bi.dbo.SCHEDULE (insert/update/delete).
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
   FUNCTIONS: EXECUTION COLLECTION
   ----------------------------------------------------------------------------
   Block 2: collects FA_CLIENTS_MAIN workflow runs from b2bi into B2B.SI_ExecutionTracking,
   resolving linkage, context summary, ProcessData, run class, and completion state.
   Prefix: b2b
   ============================================================================ #>

# Returns a HashSet of workflow_ids already marked complete, for anti-join against b2bi.
function Get-b2b_CompletedWorkflowIds {
    param()

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

# Parses a decompressed ProcessData XML string into a column-name/value field hashtable.
function ConvertFrom-b2b_ProcessData {
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
    foreach ($f in $script:b2b_ProcessDataFields) {
        $fields[$script:b2b_ProcessDataColumnMap[$f]] = $null
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
    foreach ($xmlName in $script:b2b_ProcessDataFields) {
        $columnName = $script:b2b_ProcessDataColumnMap[$xmlName]
        $node = $clientNode.SelectSingleNode($xmlName)
        if ($null -eq $node) { continue }

        $text = $node.InnerText
        if ([string]::IsNullOrEmpty($text)) { continue }

        $fields[$columnName] = $text
    }

    $result.fields = $fields
    return $result
}

# Summarizes WORKFLOW_CONTEXT rows into step counts, invocation flags, and failure detail.
function Get-b2b_WorkflowContextSummary {
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
        # No context rows - workflow may have just started. Leave all fields null.
        $summary.step_count = 0
        return $summary
    }

    $rows = @($rows)
    $summary.step_count = $rows.Count

    # Scan for sub-workflow invocations and failure detection.
    #
    # Sub-workflow invocation detection - per b2bi convention, sub-workflow
    # invocations show up as WORKFLOW_CONTEXT rows where ADV_STATUS contains
    # the text "Inline Begin <NAME>+...". SERVICE_NAME is typically
    # "InvokeBusinessProcessService" for these rows, not the sub-workflow name.
    #
    # Failure detection - BASIC_STATUS values 0 and 10 are non-failure states;
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
            # Cheap ordered checks - match the specific sub-workflow names we care about
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

# Fetches and decompresses the MAIN ProcessData TRANS_DATA row for a workflow.
function Get-b2b_ProcessDataForWorkflow {
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
        return Expand-b2b_GzipBytes -Bytes ([byte[]]$blob)
    }
    catch {
        Write-Log "    ProcessData decompression failed for WF ${WorkflowId}: $($_.Exception.Message)" "WARN"
        return $null
    }
}

# Resolves parent_workflow_id and root_workflow_id for a workflow from WORKFLOW_LINKAGE.
function Get-b2b_WorkflowLinkage {
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
        # No linkage row - this workflow is a top-level root (no parent)
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

# Classifies a run as FILE_PROCESS, INTERNAL_OP, or UNCLASSIFIED from ProcessData fields.
function ConvertTo-b2b_RunClass {
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

    # INTERNAL_OP - evaluated first (SP executor wins over file signals)
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

    # FILE_PROCESS - standard file config or always-file process types
    if (-not [string]::IsNullOrEmpty($fileFilter))      { return 'FILE_PROCESS' }
    if (-not [string]::IsNullOrEmpty($getDocsType))     { return 'FILE_PROCESS' }
    if (-not [string]::IsNullOrEmpty($putDocsType))     { return 'FILE_PROCESS' }
    if (-not [string]::IsNullOrEmpty($commCallExePath)) { return 'FILE_PROCESS' }

    # PROCESS_TYPE whitelist for operations that don't need additional signals.
    # Currently push-type outbound operations - they push whatever's present
    # regardless of explicit file_filter configuration.
    $alwaysFileProcessTypes = @('SFTP_PUSH', 'SFTP_PUSH_ED25519')
    if (-not [string]::IsNullOrEmpty($processType) -and
        $alwaysFileProcessTypes -contains $processType) {
        return 'FILE_PROCESS'
    }

    return 'UNCLASSIFIED'
}

# Evaluates whether a workflow has reached a terminal state and its completed status.
function ConvertTo-b2b_CompletionState {
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

# Writes a workflow row to B2B.SI_ExecutionTracking via INSERT (new) or UPDATE (in-flight).
function Invoke-b2b_ExecutionTrackingMerge {
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
    foreach ($xmlField in $script:b2b_ProcessDataFields) {
        $col = $script:b2b_ProcessDataColumnMap[$xmlField]
        $val = $fields[$col]

        # client_id, seq_id, file_id are BIGINT / INT in our schema;
        # prev_seq is INT. Everything else is string.
        $literal = switch ($col) {
            'client_id' { Format-b2b_SqlBigIntLiteral $val }
            'seq_id'    { Format-b2b_SqlIntLiteral $val }
            'prev_seq'  { Format-b2b_SqlIntLiteral $val }
            default     { Format-b2b_SqlStringLiteral $val }
        }

        $pdAssignments += @{ col = $col; literal = $literal }
    }

    # Common field literals
    $workflowStartLit   = Format-b2b_SqlDateTimeLiteral $InstRow.START_TIME
    $workflowEndLit     = Format-b2b_SqlDateTimeLiteral $InstRow.END_TIME
    $durationMsLit      = 'NULL'
    if ($null -ne $InstRow.END_TIME -and -not ($InstRow.END_TIME -is [DBNull])) {
        $duration = [int](([datetime]$InstRow.END_TIME - [datetime]$InstRow.START_TIME).TotalMilliseconds)
        $durationMsLit = "$duration"
    }
    $b2biStatusLit      = Format-b2b_SqlIntLiteral $InstRow.STATUS
    $b2biStateLit       = Format-b2b_SqlStringLiteral $InstRow.STATE
    $stepCountLit       = Format-b2b_SqlIntLiteral $ContextSummary.step_count

    $parentLit          = Format-b2b_SqlBigIntLiteral $Linkage.parent_workflow_id
    $rootLit            = Format-b2b_SqlBigIntLiteral $Linkage.root_workflow_id

    $runClassLit        = Format-b2b_SqlStringLiteral $RunClass
    $processDataXmlLit  = Format-b2b_SqlStringLiteral $pdXml -AllowEmpty

    $rcStepLit          = Format-b2b_SqlIntLiteral $ContextSummary.root_cause_step_id
    $rcServiceLit       = Format-b2b_SqlStringLiteral $ContextSummary.root_cause_service_name
    $rcAdvLit           = Format-b2b_SqlStringLiteral $ContextSummary.root_cause_adv_status
    $failStepLit        = Format-b2b_SqlIntLiteral $ContextSummary.failure_step_id
    $failServiceLit     = Format-b2b_SqlStringLiteral $ContextSummary.failure_service_name
    $statusMsgLit       = Format-b2b_SqlStringLiteral $ContextSummary.status_message

    $hadTransLit        = Format-b2b_SqlBitLiteral $ContextSummary.had_trans
    $hadVitalLit        = Format-b2b_SqlBitLiteral $ContextSummary.had_vital
    $hadAccountsLit     = Format-b2b_SqlBitLiteral $ContextSummary.had_accounts_load
    $hadCommCallLit     = Format-b2b_SqlBitLiteral $ContextSummary.had_comm_call
    $hadArchiveLit      = Format-b2b_SqlBitLiteral $ContextSummary.had_archive
    $transCountLit      = Format-b2b_SqlIntLiteral $ContextSummary.trans_invocation_count
    $archiveCountLit    = Format-b2b_SqlIntLiteral $ContextSummary.archive_invocation_count

    $isCompleteLit      = Format-b2b_SqlBitLiteral $CompletionState.is_complete
    $completedDttmLit   = if ($CompletionState.is_complete) { 'GETDATE()' } else { 'NULL' }
    $completedStatusLit = Format-b2b_SqlStringLiteral $CompletionState.completed_status

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
        # UPDATE - set all fields that might have changed since last cycle
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

# Collects FA_CLIENTS_MAIN workflow runs from b2bi into B2B.SI_ExecutionTracking.
function Step-b2b_CollectExecutions {
    param([bool]$PreviewOnly = $true)

    Write-Log "Step: Collect Executions" "STEP"

    $newCount      = 0
    $updatedCount  = 0
    $completedCount = 0
    $errorCount    = 0

    try {
        # Step 1: Load already-complete workflow ids (anti-join set)
        $completedSet = Get-b2b_CompletedWorkflowIds
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
        # Filter by workflow NAME via WFD join - robust against Sterling
        # WFD_ID/WFD_VERSION changes across redeployments. b2bi collation
        # is case-sensitive, so NAME must match exactly.
        $lookbackDays = $script:Config.B2B_CollectLookbackDays
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
                $linkage = Get-b2b_WorkflowLinkage -WorkflowId $workflowId
                $contextSummary = Get-b2b_WorkflowContextSummary -WorkflowId $workflowId

                # ProcessData - write partial row if fetch/parse fails.
                # Guard against null AND empty string; ConvertFrom-b2b_ProcessData rejects
                # empty strings via its Mandatory parameter binding.
                $pdXml = Get-b2b_ProcessDataForWorkflow -WorkflowId $workflowId
                $processData = if (-not [string]::IsNullOrWhiteSpace($pdXml)) {
                    ConvertFrom-b2b_ProcessData -Xml $pdXml
                } else {
                    @{ process_data_xml = $null; fields = @{} }
                }

                # Classify
                $runClass = if ($null -ne $processData.fields -and $processData.fields.Count -gt 0) {
                    ConvertTo-b2b_RunClass -Fields $processData.fields
                } else {
                    'UNCLASSIFIED'
                }

                # Evaluate completion
                $completion = ConvertTo-b2b_CompletionState -InstRow $wf

                # MERGE
                if ($PreviewOnly) {
                    $action = if ($isNew) { 'INSERT' } else { 'UPDATE' }
                    $completionNote = if ($completion.is_complete) { " [completes: $($completion.completed_status)]" } else { '' }
                    Write-Log "  [Preview] Would $action WF $workflowId ($runClass)$completionNote" "INFO"
                    if ($isNew) { $newCount++ } else { $updatedCount++ }
                    if ($completion.is_complete) { $completedCount++ }
                }
                else {
                    $ok = Invoke-b2b_ExecutionTrackingMerge `
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
                Write-Log "  WF ${workflowId}: processing failed - $($_.Exception.Message)" "ERROR"
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
        Write-Log "  Error in Step-b2b_CollectExecutions: $($_.Exception.Message)" "ERROR"
        return @{ New = $newCount; Updated = $updatedCount; Completed = $completedCount; Errors = ($errorCount + 1); Error = $_.Exception.Message }
    }
}

<# ============================================================================
   FUNCTIONS: EXECUTION DETAIL
   ----------------------------------------------------------------------------
   Block 3 (stubbed): per-file/per-creditor detail extraction into SI_ExecutionDetail.
   Prefix: b2b
   ============================================================================ #>

# [Block 3 stub] Extracts per-file/per-creditor detail into SI_ExecutionDetail.
function Step-b2b_CollectExecutionDetail {
    param([bool]$PreviewOnly = $true)

    Write-Log "Step: Collect Execution Detail - [Block 3 stub]" "STEP"
    return @{ Extracted = 0 }
}

<# ============================================================================
   FUNCTIONS: ALERT EVALUATION
   ----------------------------------------------------------------------------
   Phase 4 (stubbed): evaluates terminal FAILED rows and queues Teams alerts.
   Prefix: b2b
   ============================================================================ #>

# [Phase 4 stub] Evaluates terminal FAILED rows and queues Teams alerts.
function Step-b2b_EvaluateAlerts {
    param([bool]$PreviewOnly = $true)

    Write-Log "Step: Evaluate Alerts - [Phase 4 stub]" "STEP"
    return @{ Detected = 0; Fired = 0 }
}

<# ============================================================================
   EXECUTION: SCRIPT EXECUTION
   ----------------------------------------------------------------------------
   The collection run: initialize config, sync schedules (Block 1), collect executions
   (Block 2), run the Block 3 / Phase 4 stubs, print the summary, and fire the callback.
   Prefix: (none)
   ============================================================================ #>

$scriptStart = Get-Date

Write-Console
Write-ConsoleBanner -Label "xFACts B2B Execution Collector" -Color Cyan

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

# Step 1 - Sync schedules (Block 1)
$stepResults.Schedules = Step-b2b_SyncSchedules -PreviewOnly $previewOnly

# Step 2 - Collect executions (Block 2)
$stepResults.Executions = Step-b2b_CollectExecutions -PreviewOnly $previewOnly

# Step 3 - Execution detail (Block 3 stub)
$stepResults.Detail = Step-b2b_CollectExecutionDetail -PreviewOnly $previewOnly

# Step 4 - Alert evaluation (Phase 4 stub)
$stepResults.Alerts = Step-b2b_EvaluateAlerts -PreviewOnly $previewOnly

# SUMMARY

$scriptEnd = Get-Date
$totalMs   = [int]($scriptEnd - $scriptStart).TotalMilliseconds

$finalStatus = "SUCCESS"
if ($stepResults.Schedules.Error -or $stepResults.Schedules.Errors -gt 0) {
    $finalStatus = "FAILED"
}
if ($stepResults.Executions.Error -or $stepResults.Executions.Errors -gt 0) {
    $finalStatus = "FAILED"
}

Write-Console
Write-ConsoleBanner -Label "Execution Summary" -Color Cyan
Write-Console "  Schedules:"
Write-Console "    Inserted: $($stepResults.Schedules.Inserted)"
Write-Console "    Updated:  $($stepResults.Schedules.Updated)"
Write-Console "    Deleted:  $($stepResults.Schedules.Deleted)"
Write-Console "    Errors:   $($stepResults.Schedules.Errors)"
Write-Console
Write-Console "  Executions:"
Write-Console "    New:       $($stepResults.Executions.New)"
Write-Console "    Updated:   $($stepResults.Executions.Updated)"
Write-Console "    Completed: $($stepResults.Executions.Completed)"
Write-Console "    Errors:    $($stepResults.Executions.Errors)"
Write-Console
Write-Console "  Duration: $totalMs ms"
Write-Console

if (-not $Execute) {
    Write-Console "  *** PREVIEW MODE - No changes were made ***" Yellow
    Write-Console "  Run with -Execute to perform actual updates" Yellow
    Write-Console
}

Write-ConsoleBanner -Label "B2B Execution Collection Complete" -Color Cyan

# Orchestrator callback
if ($TaskId -gt 0) {
    $output = "SchedIns:$($stepResults.Schedules.Inserted) SchedUpd:$($stepResults.Schedules.Updated) SchedDel:$($stepResults.Schedules.Deleted) SchedErr:$($stepResults.Schedules.Errors) | ExecNew:$($stepResults.Executions.New) ExecUpd:$($stepResults.Executions.Updated) ExecDone:$($stepResults.Executions.Completed) ExecErr:$($stepResults.Executions.Errors)"

    Complete-OrchestratorTask -TaskId $TaskId -ProcessId $ProcessId `
        -Status $finalStatus -DurationMs $totalMs `
        -Output $output
}
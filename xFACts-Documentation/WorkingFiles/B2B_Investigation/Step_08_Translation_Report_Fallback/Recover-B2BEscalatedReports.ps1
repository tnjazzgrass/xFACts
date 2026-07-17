<#
.SYNOPSIS
    xFACts - One-time recovery of escalated fault reports (Step 08)

.DESCRIPTION
    Disposable one-time utility. For every B2B.SI_FaultReport row currently
    typed MESSAGE, attempts the escalated-report recovery introduced in
    Collect-B2BPipeline.ps1 the same day: pull the full translation report
    from the run's last successful Translation step in b2bi. Where recovery
    succeeds, the row is upgraded in place -- fault_report_type becomes
    TRANSLATION_ESCALATED, raw_report_text and report_json carry the full
    report, the original one-line message moves to escalation_message -- and
    the type/code/summary snapshots on B2B.INT_PipelineTracking are
    refreshed. captured_dttm is left untouched (it records the original
    capture). Rows whose runs have aged out of b2bi retention are left as
    MESSAGE and reported. All parsing and recovery functions are copied
    verbatim from Collect-B2BPipeline.ps1; this script is deleted after its
    single run, not maintained.

.PARAMETER SourceInstance
    b2bi SQL Server instance. Default: FA-INT-DBP.

.PARAMETER SourceDatabase
    b2bi database name. Default: b2bi.

.PARAMETER ServerInstance
    xFACts-side instance for initialization and xFACts writes. Default:
    AVG-PROD-LSNR.

.PARAMETER Database
    xFACts database name. Default: xFACts.

.PARAMETER SharedFunctionsPath
    Full path to xFACts-OrchestratorFunctions.ps1. Default:
    E:\xFACts-PowerShell\xFACts-OrchestratorFunctions.ps1.

.PARAMETER Execute
    Perform writes. Without this flag, runs in preview/dry-run mode.

.COMPONENT
    B2B

.NOTES
    File Name : Recover-B2BEscalatedReports.ps1
    Location  : WorkingFiles\B2B_Investigation\Step_08_FaultReport_Content

    FILE ORGANIZATION
    -----------------
    CHANGELOG: CHANGE HISTORY
    PARAMETERS: SCRIPT PARAMETERS
    IMPORTS: SCRIPT DEPENDENCIES
    INITIALIZATION: SCRIPT INITIALIZATION
    CONSTANTS: REPORT PARSING CONFIGURATION
    FUNCTIONS: REPORT PARSING AND RECOVERY
    EXECUTION: SCRIPT EXECUTION
#>

<# ============================================================================
   CHANGELOG: CHANGE HISTORY
   ----------------------------------------------------------------------------
   Dated change history, most recent first. One-time utility; deleted after
   its single production run.
   Prefix: (none)
   ============================================================================ #>

# 2026-07-16  Initial implementation for Step 08: one-time upgrade of MESSAGE
#             fault reports to TRANSLATION_ESCALATED where the run's
#             translation report is still recoverable from b2bi.

<# ============================================================================
   PARAMETERS: SCRIPT PARAMETERS
   ----------------------------------------------------------------------------
   The b2bi source, the xFACts target, the shared-functions path, and the
   Execute write-guard.
   Prefix: (none)
   ============================================================================ #>

[CmdletBinding()]
param(
    [string]$SourceInstance      = "FA-INT-DBP",
    [string]$SourceDatabase      = "b2bi",
    [string]$ServerInstance      = "AVG-PROD-LSNR",
    [string]$Database            = "xFACts",
    [string]$SharedFunctionsPath = "E:\xFACts-PowerShell\xFACts-OrchestratorFunctions.ps1",
    [switch]$Execute
)

<# ============================================================================
   IMPORTS: SCRIPT DEPENDENCIES
   ----------------------------------------------------------------------------
   Shared orchestrator and script-infrastructure functions: initialization,
   logging, and SQL access.
   Prefix: (none)
   ============================================================================ #>

. $SharedFunctionsPath

<# ============================================================================
   INITIALIZATION: SCRIPT INITIALIZATION
   ----------------------------------------------------------------------------
   One-time startup: shared script-infrastructure init (SQL module load,
   application identity, log path).
   Prefix: (none)
   ============================================================================ #>

Initialize-XFActsScript -ScriptName 'Recover-B2BEscalatedReports' `
    -ServerInstance $ServerInstance -Database $Database -Execute:$Execute

<# ============================================================================
   CONSTANTS: REPORT PARSING CONFIGURATION
   ----------------------------------------------------------------------------
   The TRANSLATION Info-code to entry-field map consumed by the report
   parser. Copied verbatim from Collect-B2BPipeline.ps1.
   Prefix: b2b
   ============================================================================ #>

# TRANSLATION report Info codes mapped to named entry fields, in emission
# order. Codes outside this map are preserved generically in additionalInfo so
# new Sterling vocabulary is never dropped. The report-metadata codes (20
# Translation Object Name, 12 Start Time, 13 End Time, 19 Execution Time)
# intentionally stay out of this map: they surface in additionalInfo on their
# HEADER/TRAILER entries and are lifted to the payload top level by the
# parser.
$script:b2b_TranslationInfoFields = [ordered]@{
    '10002' = 'blockCount'
    '10003' = 'blockName'
    '10004' = 'fieldName'
    '10005' = 'fieldData'
    '10006' = 'exception'
    '10009' = 'fieldNumber'
    '10015' = 'rawBlockData'
    '10016' = 'blockSignatureIdTag'
    '10017' = 'mapIterationCount'
    '10019' = 'locationIndex'
}

<# ============================================================================
   FUNCTIONS: REPORT PARSING AND RECOVERY
   ----------------------------------------------------------------------------
   Gzip, report-parsing, bounding, and escalated-recovery functions, copied
   verbatim from Collect-B2BPipeline.ps1 (FUNCTIONS: FAULT REPORT ENRICHMENT
   region) so the recovery produces exactly what the live collector produces.
   Prefix: b2b
   ============================================================================ #>

# True when the blob begins with the gzip magic number (0x1F 0x8B). Some
# handles point at raw Java-serialized objects (magic 0xAC 0xED) rather than a
# compressed report; those are not decompressible reports and are skipped.
function Test-b2b_IsGzip {
    param([byte[]]$Blob)
    return ($Blob.Length -ge 2 -and $Blob[0] -eq 0x1F -and $Blob[1] -eq 0x8B)
}

# Decompresses a gzip byte array and returns the raw decompressed bytes.
function Expand-b2b_GzipToBytes {
    param([byte[]]$Bytes)

    $inStream  = New-Object System.IO.MemoryStream(, $Bytes)
    $gzip      = New-Object System.IO.Compression.GzipStream($inStream, [System.IO.Compression.CompressionMode]::Decompress)
    $outStream = New-Object System.IO.MemoryStream
    try {
        $gzip.CopyTo($outStream)
        return , $outStream.ToArray()
    }
    finally {
        $gzip.Dispose()
        $inStream.Dispose()
        $outStream.Dispose()
    }
}

# Decompresses a status-report blob and returns the readable report text with
# the Java-serialization framing removed. The report body is the value of the
# serialized "Status_Report" key: a TC_STRING (0x74) tag then a 2-byte length
# precede the text, and a trailing framing byte (0x78) follows it. Structured
# shapes are anchored on stable content headers (Map Name: / Status report) so
# the leading framing is irrelevant. For the bare MESSAGE shape the framing is
# skipped on the byte array (tag + 2-byte length) so no content byte is lost.
function Get-b2b_ReportText {
    param([byte[]]$Blob)

    $bytes = Expand-b2b_GzipToBytes -Bytes $Blob
    $raw   = [System.Text.Encoding]::UTF8.GetString($bytes)

    # Anchor structured shapes on their content headers - framing before the
    # header is irrelevant.
    $mapIdx = $raw.IndexOf('Map Name:')
    if ($mapIdx -ge 0) {
        return $raw.Substring($mapIdx).Trim()
    }
    $svcIdx = $raw.IndexOf('Status report')
    if ($svcIdx -ge 0) {
        return $raw.Substring($svcIdx).Trim()
    }

    # MESSAGE shape: locate the "Status_Report" key in the byte stream, skip the
    # TC_STRING tag (0x74) + 2-byte length that introduce the value, and decode
    # from the true content start. Trailing framing (a single 0x78) is trimmed.
    $keyBytes = [System.Text.Encoding]::ASCII.GetBytes('Status_Report')
    $keyPos = -1
    for ($i = 0; $i -le $bytes.Length - $keyBytes.Length; $i++) {
        $match = $true
        for ($j = 0; $j -lt $keyBytes.Length; $j++) {
            if ($bytes[$i + $j] -ne $keyBytes[$j]) { $match = $false; break }
        }
        if ($match) { $keyPos = $i; break }
    }

    if ($keyPos -ge 0) {
        # Content begins after: key + TC_STRING tag (1 byte) + length (2 bytes).
        $contentStart = $keyPos + $keyBytes.Length + 3
        $contentEnd = $bytes.Length
        # Trim a trailing TC_ENDBLOCKDATA (0x78) framing byte if present.
        if ($contentEnd -gt $contentStart -and $bytes[$contentEnd - 1] -eq 0x78) {
            $contentEnd--
        }
        if ($contentStart -lt $contentEnd) {
            $len = $contentEnd - $contentStart
            return [System.Text.Encoding]::UTF8.GetString($bytes, $contentStart, $len).Trim()
        }
    }

    # Fallback: return the decompressed text trimmed of non-printable edges.
    return ($raw -replace '^[^\x20-\x7E]*', '' -replace '[^\x20-\x7E]*$', '').Trim()
}

# Parses the Info key/value lines of a single report entry. Keys are lines of
# the form '<code>: <label>'; the value is the line content between one key
# line and the next (multi-line values joined with newlines, empty values
# returned as null). Returns an ordered dictionary keyed by numeric code, each
# value a hashtable of Label and Value. A key line requires a space after the
# colon and a letter-led label, so colon-bearing values such as location
# indexes (01:01:01) never read as keys. Limitation: a raw-data value line
# shaped exactly like '<digits>: <Letter...>' reads as a key line;
# raw_report_text remains the ground truth for such edge cases.
function ConvertFrom-b2b_ReportEntryInfo {
    param([string[]]$Lines)

    $pairs = [ordered]@{}
    $code  = $null
    $label = $null
    $valueLines = New-Object System.Collections.Generic.List[string]

    foreach ($line in $Lines) {
        if ($line -match '^\s*(\d{1,5}):\s+([A-Za-z].*)$') {
            if ($null -ne $code) {
                $joined = ($valueLines -join "`n").Trim()
                $pairs[$code] = @{ Label = $label; Value = $(if ($joined) { $joined } else { $null }) }
            }
            $code  = $Matches[1]
            $label = $Matches[2].Trim()
            $valueLines = New-Object System.Collections.Generic.List[string]
        }
        elseif ($null -ne $code) {
            $valueLines.Add($line.Trim()) | Out-Null
        }
    }
    if ($null -ne $code) {
        $joined = ($valueLines -join "`n").Trim()
        $pairs[$code] = @{ Label = $label; Value = $(if ($joined) { $joined } else { $null }) }
    }

    return $pairs
}

# Parses a decompressed report text into a result object carrying the summary
# fields (type, code, source, summary) and a structured payload for JSON. The
# TRANSLATION payload carries full report fidelity: per-entry Info detail
# (named fields per b2b_TranslationInfoFields plus the additionalInfo
# catch-all), report metadata lifted to the top level, and
# entry/error/warning counts.
function ConvertFrom-b2b_ReportText {
    param([string]$Text)

    # -- Shape 1: TRANSLATION --

    if ($Text -match 'Translation Report') {
        $mapName    = $null
        $mapVersion = $null
        if ($Text -match 'Map Name:\s*(.+?)(?:\s+Version:|\r|\n)') {
            $mapName = $Matches[1].Trim()
        }
        if ($Text -match 'Version:\s*([^\r\n]+)') {
            $mapVersion = $Matches[1].Trim()
        }
        $containsErrors   = [bool]($Text -match 'Contains errors \?\s*true')
        $containsWarnings = [bool]($Text -match 'Contains warnings \?\s*true')

        $translationObjectName = $null
        $startTime   = $null
        $endTime     = $null
        $executionMs = $null

        # Parse each Report Entry block into a structured entry carrying its
        # full Info detail.
        $entries = New-Object System.Collections.Generic.List[object]
        $blocks = [regex]::Split($Text, 'Report Entry:') | Select-Object -Skip 1
        $entryIndex = 0
        foreach ($b in $blocks) {
            $entryIndex++
            $section  = if ($b -match 'Section:\s*(\S+)')  { $Matches[1] } else { $null }
            $severity = if ($b -match 'Severity:\s*(\S+)') { $Matches[1] } else { $null }
            $code      = $null
            $codeLabel = $null
            if ($b -match 'Code:\s*(\d+)\s+([^\r\n]+)') {
                $code      = $Matches[1].Trim()
                $codeLabel = $Matches[2].Trim()
            }

            # Info sub-block: every line after the 'Info:' marker.
            $infoPairs = [ordered]@{}
            $blockLines = $b -split "\r?\n"
            for ($li = 0; $li -lt $blockLines.Count; $li++) {
                if ($blockLines[$li] -match '^\s*Info:\s*$') {
                    if ($li + 1 -lt $blockLines.Count) {
                        $infoPairs = ConvertFrom-b2b_ReportEntryInfo -Lines $blockLines[($li + 1)..($blockLines.Count - 1)]
                    }
                    break
                }
            }

            $entry = [ordered]@{
                entryIndex = $entryIndex
                section    = $section
                severity   = $severity
                code       = $code
                codeLabel  = $codeLabel
            }
            foreach ($k in $script:b2b_TranslationInfoFields.Keys) {
                $entry[$script:b2b_TranslationInfoFields[$k]] = $(if ($infoPairs.Contains($k)) { $infoPairs[$k].Value } else { $null })
            }

            # Unrecognized Info codes are preserved rather than dropped.
            $additional = New-Object System.Collections.Generic.List[object]
            foreach ($k in $infoPairs.Keys) {
                if (-not $script:b2b_TranslationInfoFields.Contains($k)) {
                    $additional.Add([PSCustomObject]@{
                        code  = $k
                        label = $infoPairs[$k].Label
                        value = $infoPairs[$k].Value
                    }) | Out-Null
                }
            }
            $entry['additionalInfo'] = $additional

            # Report metadata rides on HEADER/TRAILER entries; lift the first
            # occurrence of each to the payload top level.
            if ($null -eq $translationObjectName -and $infoPairs.Contains('20')) { $translationObjectName = $infoPairs['20'].Value }
            if ($null -eq $startTime -and $infoPairs.Contains('12'))   { $startTime = $infoPairs['12'].Value }
            if ($null -eq $endTime -and $infoPairs.Contains('13'))     { $endTime = $infoPairs['13'].Value }
            if ($null -eq $executionMs -and $infoPairs.Contains('19')) { $executionMs = $infoPairs['19'].Value }

            $entries.Add([PSCustomObject]$entry) | Out-Null
        }

        $errorEntries = @($entries | Where-Object { $_.severity -eq 'ERROR' })
        $errorCount   = $errorEntries.Count
        $warningCount = @($entries | Where-Object { $_.severity -eq 'WARNING' }).Count

        $summaryCode = $null
        $summaryText = $null
        if ($errorCount -eq 1) {
            $e = $errorEntries[0]
            $summaryCode = $e.code
            if ($e.exception) {
                $summaryText = $e.exception
            }
            elseif ($e.fieldName -and $e.codeLabel) {
                $summaryText = "$($e.codeLabel) - field $($e.fieldName)"
            }
            elseif ($e.blockName -and $e.codeLabel) {
                $summaryText = "$($e.codeLabel) - block $($e.blockName)"
            }
            elseif ($e.codeLabel) {
                $summaryText = $e.codeLabel
            }
            else {
                $summaryText = "Error code $($e.code)"
            }
        }
        elseif ($errorCount -gt 1) {
            $summaryCode = $errorEntries[0].code
            # Distinct error labels with counts, most frequent first.
            $groups = $errorEntries |
                Group-Object -Property codeLabel |
                Sort-Object -Property @{ Expression = 'Count'; Descending = $true }, @{ Expression = 'Name'; Descending = $false }
            $parts = foreach ($g in $groups) {
                $groupLabel = if ($g.Name) { $g.Name } else { "Error code $($g.Group[0].code)" }
                "$groupLabel ($($g.Count))"
            }
            $summaryText = "$errorCount errors: " + ($parts -join ', ')
        }
        else {
            $summaryText = "Translation report (no error entries)"
        }

        return [PSCustomObject]@{
            type    = 'TRANSLATION'
            source  = $mapName
            code    = $summaryCode
            summary = $summaryText
            payload = [PSCustomObject]@{
                mapName               = $mapName
                mapVersion            = $mapVersion
                translationObjectName = $translationObjectName
                startTime             = $startTime
                endTime               = $endTime
                executionMs           = $executionMs
                containsErrors        = $containsErrors
                containsWarnings      = $containsWarnings
                entryCount            = $entries.Count
                errorCount            = $errorCount
                warningCount          = $warningCount
                entries               = $entries
            }
        }
    }

    # -- Shape 2: SERVICE --

    if ($Text -match 'for service:\s*(.+?)[\r\n]') {
        $serviceName = $Matches[1].Trim()

        $errorTotal = if ($Text -match 'total number of errors is:\s*(\d+)') { [int]$Matches[1] } else { 0 }

        # Every ERROR line, in report order; the first is the headline.
        $errors = New-Object System.Collections.Generic.List[string]
        foreach ($line in ($Text -split "`n")) {
            if ($line -match 'ERROR:\s*(.+)$') {
                $errors.Add($Matches[1].Trim()) | Out-Null
            }
        }

        $summaryText = if ($errorTotal -gt 1) {
            "Multiple errors ($errorTotal) - see full report"
        }
        elseif ($errors.Count -gt 0) {
            $errors[0]
        }
        else {
            "Service report for $serviceName"
        }

        return [PSCustomObject]@{
            type    = 'SERVICE'
            source  = $serviceName
            code    = $null
            summary = $summaryText
            payload = [PSCustomObject]@{
                serviceName = $serviceName
                errorTotal  = $errorTotal
                errors      = $errors
            }
        }
    }

    # -- Shape 3: MESSAGE --

    # A bare single-string message: the whole text is the summary.
    $msg = $Text.Trim()
    return [PSCustomObject]@{
        type    = 'MESSAGE'
        source  = $null
        code    = $null
        summary = $msg
        payload = [PSCustomObject]@{
            message = $msg
        }
    }
}

# Truncates a string to a maximum length for a bounded summary column.
function Get-b2b_Bounded {
    param([string]$Value, [int]$Max)
    if ($null -eq $Value) { return $null }
    if ($Value.Length -le $Max) { return $Value }
    return $Value.Substring(0, $Max)
}

# Recovers the full translation report for a run whose failing step yielded
# only a bare one-line message: the map completed (its warning-bearing report
# rides on the successful Translation step) and the BPML escalated the
# outcome to a fault (Step 08 finding). Returns a hashtable of Text and
# Parsed -- with the parsed type overridden to TRANSLATION_ESCALATED -- or
# null when the run has no recoverable translation report (aged out, no
# translation step, or a non-TRANSLATION shape).
function Get-b2b_EscalatedReport {
    param([long]$RunId)

    $fallbackQuery = @"
SELECT TOP 1 STATUS_RPT
FROM dbo.WORKFLOW_CONTEXT
WHERE WORKFLOW_ID = $RunId
  AND BASIC_STATUS = 0
  AND SERVICE_NAME = 'Translation'
  AND STATUS_RPT IS NOT NULL
ORDER BY STEP_ID DESC
"@
    $handleRow = Get-SqlData -Query $fallbackQuery `
                             -Instance $SourceInstance -DatabaseName $SourceDatabase
    $handle = $null
    if ($handleRow) {
        $handleRow = @($handleRow)
        if ($handleRow.Count -gt 0) { $handle = [string]$handleRow[0].STATUS_RPT }
    }
    if ([string]::IsNullOrEmpty($handle)) {
        return $null
    }

    $blobQuery = "SELECT DATA_OBJECT FROM dbo.TRANS_DATA WHERE DATA_ID = @h AND PAGE_INDEX = 0"
    $blobRow = Get-SqlData -Query $blobQuery `
                           -Instance $SourceInstance -DatabaseName $SourceDatabase `
                           -Parameters @{ h = $handle }
    $blob = $null
    if ($blobRow) {
        $blobRow = @($blobRow)
        if ($blobRow.Count -gt 0 -and $blobRow[0].DATA_OBJECT -isnot [System.DBNull]) {
            $blob = [byte[]]$blobRow[0].DATA_OBJECT
        }
    }
    if ($null -eq $blob -or $blob.Length -eq 0) {
        return $null
    }
    if (-not (Test-b2b_IsGzip -Blob $blob)) {
        return $null
    }

    $text   = Get-b2b_ReportText -Blob $blob
    $parsed = ConvertFrom-b2b_ReportText -Text $text
    if ($parsed.type -ne 'TRANSLATION') {
        return $null
    }

    $parsed.type = 'TRANSLATION_ESCALATED'
    return @{ Text = $text; Parsed = $parsed }
}

<# ============================================================================
   EXECUTION: SCRIPT EXECUTION
   ----------------------------------------------------------------------------
   For each MESSAGE report row: attempt the escalated recovery from b2bi;
   upgrade the report row and refresh the tracking snapshots on success;
   report rows whose runs are no longer recoverable. Preview mode logs the
   would-be upgrades without touching anything.
   Prefix: (none)
   ============================================================================ #>

$previewOnly = -not $Execute
$modeLabel = if ($previewOnly) { 'PREVIEW' } else { 'EXECUTE' }
Write-Log "Recover-B2BEscalatedReports starting ($modeLabel)" "STEP"

$rows = Get-SqlData `
    -Query "SELECT fault_report_id, run_id, raw_report_text FROM B2B.SI_FaultReport WHERE fault_report_type = 'MESSAGE' ORDER BY fault_report_id" `
    -MaxCharLength 2147483647

if (-not $rows) {
    Write-Log "No MESSAGE report rows to attempt" "INFO"
    return
}

$rows = @($rows)
Write-Log "MESSAGE report rows to attempt: $($rows.Count)" "INFO"

$recoveredCount = 0
$notRecoverable = 0
$failed         = 0

foreach ($row in $rows) {
    $reportId = [long]$row.fault_report_id
    $runId    = [long]$row.run_id
    $oldRaw   = [string]$row.raw_report_text

    $recovered = Get-b2b_EscalatedReport -RunId $runId
    if (-not $recovered) {
        $notRecoverable++
        Write-Log "Report ${reportId} (run ${runId}): not recoverable (aged out or no translation report)" "INFO"
        continue
    }

    $parsed     = $recovered.Parsed
    $reportText = $recovered.Text
    $json       = $parsed.payload | ConvertTo-Json -Depth 6 -Compress
    $summary    = Get-b2b_Bounded -Value $parsed.summary -Max 500
    $code       = Get-b2b_Bounded -Value $parsed.code -Max 20
    $source     = Get-b2b_Bounded -Value $parsed.source -Max 255
    $escalation = Get-b2b_Bounded -Value $oldRaw.Trim() -Max 500

    if ($previewOnly) {
        Write-Log "[Preview] Report ${reportId} (run ${runId}): MESSAGE -> $($parsed.type) / $summary" "INFO"
        $recoveredCount++
        continue
    }

    $okReport = Invoke-SqlNonQuery -Query @"
UPDATE B2B.SI_FaultReport
SET fault_report_type = @type,
    source_name = @source,
    report_json = @json,
    raw_report_text = @raw,
    escalation_message = @esc
WHERE fault_report_id = @id
"@ -Parameters @{
        type   = $parsed.type
        source = $source
        json   = $json
        raw    = $reportText
        esc    = $escalation
        id     = $reportId
    }

    if (-not $okReport) {
        $failed++
        Write-Log "Report ${reportId}: SI_FaultReport upgrade failed" "ERROR"
        continue
    }

    $okTracking = Invoke-SqlNonQuery -Query @"
UPDATE B2B.INT_PipelineTracking
SET fault_report_type = @type,
    fault_report_code = @code,
    fault_report_summary = @summary
WHERE run_id = @run_id
"@ -Parameters @{
        type    = $parsed.type
        code    = $code
        summary = $summary
        run_id  = $runId
    }

    if (-not $okTracking) {
        $failed++
        Write-Log "Report ${reportId}: tracking snapshot refresh failed (report row upgraded)" "ERROR"
        continue
    }

    $recoveredCount++
}

if ($previewOnly) {
    Write-Log "[Preview] Would upgrade $recoveredCount, leave $notRecoverable as MESSAGE" "SUCCESS"
}
else {
    Write-Log "Upgraded $recoveredCount, left $notRecoverable as MESSAGE, $failed error(s)" "SUCCESS"
}
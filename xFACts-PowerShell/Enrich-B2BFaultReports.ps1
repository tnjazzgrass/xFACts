<#
.SYNOPSIS
    Captures Sterling translation status reports for failed B2B pipeline runs.

.DESCRIPTION
    Standalone look-back-and-fill enrichment for B2B.INT_PipelineTracking. For
    each failed run within the lookback window that has no captured fault report
    yet, it resolves the failing step's STATUS_RPT handle in b2bi
    WORKFLOW_CONTEXT, reads the gzip status-report blob from b2bi TRANS_DATA,
    decompresses it, parses one of three report shapes (TRANSLATION, SERVICE,
    MESSAGE), writes the full parsed report to B2B.SI_FaultReport, and snapshots
    the summary fields onto B2B.INT_PipelineTracking. Failures with no
    extractable report are marked NONE so they are not re-attempted.

    Idempotent: the fault_report_captured_dttm guard means each failure is
    processed once. This same logic lifts into Collect-B2BPipeline.ps1 as a
    failures-only step; the standalone form is the confirmation test and the
    one-off backfill of the current retention window.

    Preview mode (default) reports what it would capture and writes nothing.
    Supply -Execute to perform the writes.

.PARAMETER ServerInstance
    xFACts AG listener (target database host). Default: AVG-PROD-LSNR.

.PARAMETER Database
    xFACts database. Default: xFACts.

.PARAMETER SourceInstance
    Sterling b2bi host (report source). Default: FA-INT-DBP.

.PARAMETER SourceDatabase
    Sterling b2bi database. Default: b2bi.

.PARAMETER LookbackDays
    How many days back to scan for uncaptured failures. Default: 6 (just inside
    the b2bi runtime retention window; reports older than this have aged out of
    the source and cannot be captured).

.PARAMETER Execute
    Perform the writes. When omitted, runs in preview mode.

.NOTES
    File Name : Enrich-B2BFaultReports.ps1
    Location  : E:\xFACts-PowerShell

    FILE ORGANIZATION
    -----------------
    CHANGELOG: CHANGE HISTORY
    PARAMETERS: SCRIPT PARAMETERS
    IMPORTS: SCRIPT DEPENDENCIES
    INITIALIZATION: SCRIPT INITIALIZATION
    FUNCTIONS: GZIP DECOMPRESSION
    FUNCTIONS: REPORT PARSING
    FUNCTIONS: FAULT REPORT ENRICHMENT
    EXECUTION: SCRIPT EXECUTION
#>

<# ============================================================================
   CHANGELOG: CHANGE HISTORY
   ----------------------------------------------------------------------------
   Date-stamped change history. Each entry is one ISO date line followed by an
   indented description. Entries appear most-recent first.
   Prefix: (none)
   ============================================================================ #>

# 2026-07-14  Scope narrowed to Sterling-internal faults: driving classification
#             set reduced to STERLING_FAULT and DIED_UNHANDLED. DM_REJECTED and
#             FAULT_POST_HANDOFF are post-handoff (downstream) failures owned by
#             other modules and are no longer touched by this enrichment.
# 2026-07-14  MESSAGE-shape extraction reworked to skip the Java TC_STRING tag
#             and 2-byte length on the decompressed byte array (prior string
#             trim left the tag byte and clipped content). LookbackDays default
#             tightened to 6 to stay within b2bi runtime retention (older
#             failures have purged from the source and cannot be captured).
# 2026-07-14  Fault-step match broadened from BASIC_STATUS = 1 to BASIC_STATUS
#             <> 0 for a configured set of report-producing services
#             (Translation, XSLTService, InlineInvokeBusinessProcessService,
#             MailMimeService), recovering faults at other status codes (e.g.
#             450 Service Error, 300 mail). Added a gzip-magic guard so handles
#             pointing at non-gzip objects (e.g. raw-serialized process markers)
#             are skipped as NONE rather than erroring. Report-text extraction
#             re-anchored on content markers (Map Name: / Status report) with
#             precise MESSAGE framing trim, fixing leading/trailing Java
#             serialization bytes in the summary. NONE-marking factored into a
#             shared helper.
# 2026-07-14  Initial version. Look-back-and-fill capture of Sterling
#             translation status reports for failed B2B runs: resolve the
#             failing step STATUS_RPT handle, decompress the TRANS_DATA blob,
#             parse three report shapes, write SI_FaultReport and snapshot the
#             INT_PipelineTracking summary columns. NONE sentinel for failures
#             with no extractable report.

<# ============================================================================
   PARAMETERS: SCRIPT PARAMETERS
   ============================================================================ #>

[CmdletBinding()]
param(
    [string]$ServerInstance = "AVG-PROD-LSNR",
    [string]$Database       = "xFACts",
    [string]$SourceInstance = "FA-INT-DBP",
    [string]$SourceDatabase = "b2bi",
    [int]$LookbackDays      = 3,
    [switch]$Execute
)

<# ============================================================================
   IMPORTS: SCRIPT DEPENDENCIES
   ----------------------------------------------------------------------------
   Shared orchestrator and script-infrastructure functions: initialization,
   logging, and SQL access.
   Prefix: (none)
   ============================================================================ #>

. "$PSScriptRoot\xFACts-OrchestratorFunctions.ps1"

<# ============================================================================
   INITIALIZATION: SCRIPT INITIALIZATION
   ============================================================================ #>

Initialize-XFActsScript -ScriptName "Enrich-B2BFaultReports" `
    -ServerInstance $ServerInstance -Database $Database -Execute:$Execute

$PreviewOnly = -not $Execute

# Failure classifications that represent a fault INSIDE Sterling, before the
# data left the pipeline. DM_REJECTED and FAULT_POST_HANDOFF are downstream
# (post-handoff) failures owned by other modules and are deliberately excluded
# so this enrichment never touches non-Sterling failure rows.
$script:FailureClassifications = @(
    'STERLING_FAULT', 'DIED_UNHANDLED'
)

# Sterling services that emit a decompressible fault report on failure. The
# fault step is matched on BASIC_STATUS <> 0 for one of these services. Add a
# service here when a new report-producing service is discovered.
$script:FaultReportServices = @(
    'Translation'
    'XSLTService'
    'InlineInvokeBusinessProcessService'
    'MailMimeService'
)

<# ============================================================================
   FUNCTIONS: GZIP DECOMPRESSION
   ----------------------------------------------------------------------------
   Inflates the gzip-compressed status-report blob. The proven b2bi blob
   pattern (magic 0x1F8B): a gzip stream wrapping a short Java-serialization
   preamble followed by the readable report text.
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

<# ============================================================================
   FUNCTIONS: REPORT PARSING
   ----------------------------------------------------------------------------
   Detects one of three report shapes and extracts the summary fields plus a
   structured object for JSON storage:
     TRANSLATION - Map Name header, Report Entry blocks (Section/Severity/
                   Code/Info); the richest shape.
     SERVICE     - "for service: X", timestamped message lines, error total.
     MESSAGE     - a bare single-string message.
   Prefix: b2b
   ============================================================================ #>

# Parses a decompressed report text into a result object carrying the summary
# fields (type, code, source, summary) and a structured payload for JSON.
function ConvertFrom-b2b_ReportText {
    param([string]$Text)

    # --- Shape 1: TRANSLATION ---------------------------------------------
    if ($Text -match 'Translation Report') {
        $mapName = $null
        if ($Text -match 'Map Name:\s*(.+?)(?:\s+Version:|\r|\n)') {
            $mapName = $Matches[1].Trim()
        }

        # Parse each Report Entry block into a structured entry.
        $entries = New-Object System.Collections.Generic.List[object]
        $blocks = [regex]::Split($Text, 'Report Entry:') | Select-Object -Skip 1
        foreach ($b in $blocks) {
            $section  = if ($b -match 'Section:\s*(\S+)')  { $Matches[1] } else { $null }
            $severity = if ($b -match 'Severity:\s*(\S+)') { $Matches[1] } else { $null }
            $code     = $null
            $codeLabel = $null
            if ($b -match 'Code:\s*(\d+)\s+([^\r\n]+)') {
                $code      = $Matches[1].Trim()
                $codeLabel = $Matches[2].Trim()
            }
            $fieldName = if ($b -match '10004:\s*Field Name\s*[\r\n]+\s*([^\r\n]+)') { $Matches[1].Trim() } else { $null }
            $exception = if ($b -match '10006:\s*Exception\s*[\r\n]+\s*([^\r\n]+)') { $Matches[1].Trim() } else { $null }

            $entries.Add([PSCustomObject]@{
                section   = $section
                severity  = $severity
                code      = $code
                codeLabel = $codeLabel
                fieldName = $fieldName
                exception = $exception
            }) | Out-Null
        }

        $errorEntries = @($entries | Where-Object { $_.severity -eq 'ERROR' })
        $errorCount   = $errorEntries.Count

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
            elseif ($e.codeLabel) {
                $summaryText = $e.codeLabel
            }
            else {
                $summaryText = "Error code $($e.code)"
            }
        }
        elseif ($errorCount -gt 1) {
            $summaryCode = $errorEntries[0].code
            $summaryText = "Multiple errors ($errorCount) - see full report"
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
                mapName    = $mapName
                errorCount = $errorCount
                entries    = $entries
            }
        }
    }

    # --- Shape 2: SERVICE -------------------------------------------------
    if ($Text -match 'for service:\s*(.+?)[\r\n]') {
        $serviceName = $Matches[1].Trim()

        $errorTotal = if ($Text -match 'total number of errors is:\s*(\d+)') { [int]$Matches[1] } else { 0 }

        # First ERROR line is the headline error message.
        $firstError = $null
        foreach ($line in ($Text -split "`n")) {
            if ($line -match 'ERROR:\s*(.+)$') {
                $firstError = $Matches[1].Trim()
                break
            }
        }

        $summaryText = if ($errorTotal -gt 1) {
            "Multiple errors ($errorTotal) - see full report"
        }
        elseif ($firstError) {
            $firstError
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
                firstError  = $firstError
            }
        }
    }

    # --- Shape 3: MESSAGE -------------------------------------------------
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

<# ============================================================================
   FUNCTIONS: FAULT REPORT ENRICHMENT
   ----------------------------------------------------------------------------
   The look-back-and-fill pass: find uncaptured failures, resolve each one's
   status-report handle and blob, parse, and persist. Preview mode reports the
   intended captures without writing.
   Prefix: b2b
   ============================================================================ #>

# Truncates a string to a maximum length for a bounded summary column.
function Get-b2b_Bounded {
    param([string]$Value, [int]$Max)
    if ($null -eq $Value) { return $null }
    if ($Value.Length -le $Max) { return $Value }
    return $Value.Substring(0, $Max)
}

# Marks a run's fault report as NONE (attempted, nothing to capture) so the
# idempotent look-back pass does not re-process it. Honors preview mode.
function Set-b2b_FaultReportNone {
    param([long]$RunId, [string]$Reason, [bool]$PreviewOnly)

    if ($PreviewOnly) {
        Write-Log "  [Preview] Run ${RunId}: $Reason -> NONE" "DEBUG"
        return
    }
    $sql = @"
UPDATE B2B.INT_PipelineTracking
SET fault_report_type = 'NONE',
    fault_report_captured_dttm = GETDATE(),
    last_polled_dttm = GETDATE()
WHERE run_id = $RunId
"@
    Invoke-SqlNonQuery -Query $sql | Out-Null
}

# Enriches uncaptured failures within the lookback window with their Sterling
# status report. Returns a small summary hashtable of the work performed.
function Step-b2b_EnrichFaultReports {
    param([bool]$PreviewOnly = $true)

    Write-Log "Step: Enrich Fault Reports" "STEP"

    $captured = 0
    $noReport = 0
    $failed   = 0

    try {
        $classList = "'" + ($script:FailureClassifications -join "','") + "'"
        $svcList   = "'" + ($script:FaultReportServices -join "','") + "'"

        # Uncaptured failures within the window (fault_report_captured_dttm NULL).
        $candidatesQuery = @"
SELECT run_id, status_classification
FROM B2B.INT_PipelineTracking
WHERE fault_report_captured_dttm IS NULL
  AND status_classification IN ($classList)
  AND source_insert_dttm >= DATEADD(DAY, -$LookbackDays, GETDATE())
ORDER BY source_insert_dttm DESC
"@

        $candidates = Get-SqlData -Query $candidatesQuery
        if (-not $candidates) {
            Write-Log "  No uncaptured failures in the window" "INFO"
            return @{ Captured = 0; NoReport = 0; Failed = 0 }
        }

        $candidates = @($candidates)
        Write-Log "  Uncaptured failure(s) in window: $($candidates.Count)" "INFO"

        foreach ($run in $candidates) {
            $runId = [long]$run.run_id

            # Resolve the failing step's STATUS_RPT handle from b2bi. A fault
            # step carries a non-zero BASIC_STATUS (1, 300, 450, ... vary by
            # failure) for one of the report-producing services, with the report
            # handle on that step or the inline-invoke that caught it. Take the
            # first such step by step order.
            $handleQuery = @"
SELECT TOP 1 STATUS_RPT
FROM dbo.WORKFLOW_CONTEXT
WHERE WORKFLOW_ID = $runId
  AND BASIC_STATUS <> 0
  AND STATUS_RPT IS NOT NULL
  AND SERVICE_NAME IN ($svcList)
ORDER BY STEP_ID
"@

            $handleRow = Get-SqlData -Query $handleQuery `
                                     -Instance $SourceInstance -DatabaseName $SourceDatabase
            $handle = $null
            if ($handleRow) {
                $handleRow = @($handleRow)
                if ($handleRow.Count -gt 0) { $handle = [string]$handleRow[0].STATUS_RPT }
            }

            if ([string]::IsNullOrEmpty($handle)) {
                $noReport++
                Set-b2b_FaultReportNone -RunId $runId -Reason "no report handle" -PreviewOnly $PreviewOnly
                continue
            }

            # Fetch and decompress the status-report blob (parameterized so the
            # handle binds safely and the VARBINARY returns as a full byte[]).
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
                # Handle present but blob missing (aged out).
                $noReport++
                Set-b2b_FaultReportNone -RunId $runId -Reason "handle but no blob" -PreviewOnly $PreviewOnly
                continue
            }

            if (-not (Test-b2b_IsGzip -Blob $blob)) {
                # Handle points at a non-gzip object (e.g. a raw-serialized
                # process marker, not a compressed report). Nothing to capture.
                $noReport++
                Set-b2b_FaultReportNone -RunId $runId -Reason "blob not gzip" -PreviewOnly $PreviewOnly
                continue
            }

            # Decompress and parse.
            $reportText = Get-b2b_ReportText -Blob $blob
            $parsed     = ConvertFrom-b2b_ReportText -Text $reportText
            $json       = $parsed.payload | ConvertTo-Json -Depth 6 -Compress
            $summary    = Get-b2b_Bounded -Value $parsed.summary -Max 500
            $code       = Get-b2b_Bounded -Value $parsed.code -Max 20
            $source     = Get-b2b_Bounded -Value $parsed.source -Max 255

            $captured++

            if ($PreviewOnly) {
                Write-Log "  [Preview] Run ${runId}: $($parsed.type) / $($summary)" "INFO"
                continue
            }

            # Insert the full report, then snapshot the summary onto the run.
            # Parameterized to carry the NVARCHAR(MAX) content safely.
            $insertReport = @"
INSERT INTO B2B.SI_FaultReport (run_id, fault_report_type, source_name, report_json, raw_report_text)
VALUES (@run_id, @type, @source, @json, @raw)
"@
            $okInsert = Invoke-SqlNonQuery -Query $insertReport -Parameters @{
                run_id = $runId
                type   = $parsed.type
                source = $source
                json   = $json
                raw    = $reportText
            }

            if (-not $okInsert) {
                $failed++
                Write-Log "  Run ${runId}: report insert failed" "ERROR"
                continue
            }

            $updateTracking = @"
UPDATE B2B.INT_PipelineTracking
SET fault_report_type = @type,
    fault_report_code = @code,
    fault_report_summary = @summary,
    fault_report_captured_dttm = GETDATE(),
    last_polled_dttm = GETDATE()
WHERE run_id = @run_id
"@
            $okUpdate = Invoke-SqlNonQuery -Query $updateTracking -Parameters @{
                type    = $parsed.type
                code    = $code
                summary = $summary
                run_id  = $runId
            }

            if (-not $okUpdate) {
                $failed++
                Write-Log "  Run ${runId}: tracking update failed (report row inserted)" "ERROR"
            }
        }

        if ($PreviewOnly) {
            Write-Log "  [Preview] Would capture $captured, mark $noReport NONE" "INFO"
        }
        else {
            Write-Log "  Captured $captured report(s), marked $noReport NONE, $failed error(s)" "SUCCESS"
        }

        return @{ Captured = $captured; NoReport = $noReport; Failed = $failed }
    }
    catch {
        Write-Log "  Error in Step-b2b_EnrichFaultReports: $($_.Exception.Message)" "ERROR"
        return @{ Captured = $captured; NoReport = $noReport; Failed = $failed; Error = $_.Exception.Message }
    }
}

<# ============================================================================
   EXECUTION: SCRIPT EXECUTION
   ============================================================================ #>

Write-Log "===== B2B Fault Report Enrichment =====" "INFO"
Write-Log "  Target (listener): $ServerInstance / $Database" "INFO"
Write-Log "  Source (b2bi):     $SourceInstance / $SourceDatabase" "INFO"
Write-Log "  Lookback days:     $LookbackDays" "INFO"

$result = Step-b2b_EnrichFaultReports -PreviewOnly $PreviewOnly

Write-Log "===== Complete: captured=$($result.Captured) none=$($result.NoReport) failed=$($result.Failed) =====" "INFO"
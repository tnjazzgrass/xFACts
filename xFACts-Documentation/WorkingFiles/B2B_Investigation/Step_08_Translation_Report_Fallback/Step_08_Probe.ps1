<#
.SYNOPSIS
    xFACts - Step 08 blob probe: inspect b2bi report/content handles

.DESCRIPTION
    Disposable read-only investigation utility for Step 08 (Fault Report
    Content). For each supplied handle it reads the blob from b2bi
    dbo.TRANS_DATA two ways -- (a) exactly as the collector does today
    (PAGE_INDEX = 0, no -MaxBinaryLength) and (b) fully (all pages in order,
    -MaxBinaryLength 20971520) -- and compares byte counts against the SQL
    DATALENGTH, settling the pagination and silent-truncation questions
    empirically. Gzip blobs are then decompressed (full read) and inspected:
    length, presence and position of the 'Map Name:' / 'Translation Report' /
    '<StatusReport>' markers, and head/tail excerpts. Gzip and text helpers
    are copied verbatim from Collect-B2BPipeline.ps1. No writes anywhere.

.PARAMETER Handles
    One or more DATA_ID handle strings to inspect. Defaults to the four
    run-8608465 handles from the Step 08 background.

.PARAMETER SourceInstance
    b2bi SQL Server instance. Default: FA-INT-DBP.

.PARAMETER SourceDatabase
    b2bi database name. Default: b2bi.

.PARAMETER ServerInstance
    xFACts-side instance for script-infrastructure initialization. Default:
    AVG-PROD-LSNR.

.PARAMETER Database
    xFACts database name for initialization. Default: xFACts.

.PARAMETER SharedFunctionsPath
    Full path to xFACts-OrchestratorFunctions.ps1. Default:
    E:\xFACts-PowerShell\xFACts-OrchestratorFunctions.ps1.

.COMPONENT
    B2B

.NOTES
    File Name : Step_08_Probe.ps1
    Location  : WorkingFiles\B2B_Investigation\Step_08_FaultReport_Content

    FILE ORGANIZATION
    -----------------
    CHANGELOG: CHANGE HISTORY
    PARAMETERS: SCRIPT PARAMETERS
    IMPORTS: SCRIPT DEPENDENCIES
    INITIALIZATION: SCRIPT INITIALIZATION
    FUNCTIONS: BLOB AND REPORT HELPERS
    EXECUTION: SCRIPT EXECUTION
#>

<# ============================================================================
   CHANGELOG: CHANGE HISTORY
   ----------------------------------------------------------------------------
   Dated change history, most recent first. Disposable investigation utility.
   Prefix: (none)
   ============================================================================ #>

# 2026-07-16  Initial implementation for Step 08: two-way blob reads with
#             byte-count comparison (collector-style vs full paged read) and
#             decompressed-content inspection for report markers.

<# ============================================================================
   PARAMETERS: SCRIPT PARAMETERS
   ----------------------------------------------------------------------------
   The handles to inspect, the b2bi connection target, and the shared-
   functions path.
   Prefix: (none)
   ============================================================================ #>

[CmdletBinding()]
param(
    [string[]]$Handles = @(
        'FA-INT-APPP:node1:19ec26870bc:93062152',
        'FA-INT-APPP:node1:19ec26870bc:93062153',
        'FA-INT-APPP:node1:19ec26870bc:93062195',
        'FA-INT-APPP:node1:19ec26870bc:93062204'
    ),
    [string]$SourceInstance      = "FA-INT-DBP",
    [string]$SourceDatabase      = "b2bi",
    [string]$ServerInstance      = "AVG-PROD-LSNR",
    [string]$Database            = "xFACts",
    [string]$SharedFunctionsPath = "E:\xFACts-PowerShell\xFACts-OrchestratorFunctions.ps1"
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
   application identity, log path). Read-only utility; Execute never set.
   Prefix: (none)
   ============================================================================ #>

Initialize-XFActsScript -ScriptName 'Step_08_Probe' `
    -ServerInstance $ServerInstance -Database $Database

<# ============================================================================
   FUNCTIONS: BLOB AND REPORT HELPERS
   ----------------------------------------------------------------------------
   Gzip detection, decompression, and report-text extraction, copied verbatim
   from Collect-B2BPipeline.ps1 (FUNCTIONS: FAULT REPORT ENRICHMENT region)
   so the probe sees exactly what the collector sees.
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
   EXECUTION: SCRIPT EXECUTION
   ----------------------------------------------------------------------------
   Per handle: SQL-side page/byte census, collector-style read, full paged
   read, byte-count comparison, and decompressed-content inspection.
   Prefix: (none)
   ============================================================================ #>

Write-Log "Step 08 blob probe starting: $($Handles.Count) handle(s) against $SourceInstance/$SourceDatabase" "STEP"

foreach ($handle in $Handles) {
    Write-Log "---- Handle $handle ----" "STEP"

    # SQL-side truth: pages and byte lengths as the database reports them.
    $pages = Get-SqlData -Query @"
SELECT PAGE_INDEX, DATALENGTH(DATA_OBJECT) AS byte_length
FROM dbo.TRANS_DATA WITH (NOLOCK)
WHERE DATA_ID = @h
ORDER BY PAGE_INDEX
"@ -Instance $SourceInstance -DatabaseName $SourceDatabase -Parameters @{ h = $handle }

    if (-not $pages) {
        Write-Log "Not found in TRANS_DATA; checking DATA_TABLE" "WARN"
        $alt = Get-SqlData -Query "SELECT DATALENGTH(DATA_OBJECT) AS byte_length FROM dbo.DATA_TABLE WITH (NOLOCK) WHERE DATA_ID = @h" `
            -Instance $SourceInstance -DatabaseName $SourceDatabase -Parameters @{ h = $handle }
        if ($alt) {
            Write-Log "Found in DATA_TABLE: $(@($alt)[0].byte_length) bytes (probe reads TRANS_DATA only; note for findings)" "INFO"
        }
        else {
            Write-Log "Handle not found in TRANS_DATA or DATA_TABLE (aged out?)" "ERROR"
        }
        continue
    }

    $pages = @($pages)
    $sqlTotalBytes = ($pages | Measure-Object -Property byte_length -Sum).Sum
    Write-Log "SQL census: $($pages.Count) page(s), $sqlTotalBytes total byte(s), max PAGE_INDEX $($pages[-1].PAGE_INDEX)" "INFO"

    # Read (a): exactly as the collector reads today.
    $collectorRow = Get-SqlData -Query "SELECT DATA_OBJECT FROM dbo.TRANS_DATA WHERE DATA_ID = @h AND PAGE_INDEX = 0" `
        -Instance $SourceInstance -DatabaseName $SourceDatabase -Parameters @{ h = $handle }
    $collectorBytes = 0
    if ($collectorRow) {
        $collectorBlob = @($collectorRow)[0].DATA_OBJECT
        if ($collectorBlob -is [byte[]]) { $collectorBytes = $collectorBlob.Length }
    }

    # Read (b): full read -- every page in order, explicit binary ceiling.
    $fullRows = Get-SqlData -Query @"
SELECT PAGE_INDEX, DATA_OBJECT
FROM dbo.TRANS_DATA WITH (NOLOCK)
WHERE DATA_ID = @h
ORDER BY PAGE_INDEX
"@ -Instance $SourceInstance -DatabaseName $SourceDatabase -Parameters @{ h = $handle } `
       -MaxBinaryLength 20971520

    $ms = New-Object System.IO.MemoryStream
    foreach ($row in @($fullRows)) {
        $b = $row.DATA_OBJECT
        if ($b -is [byte[]]) { $ms.Write($b, 0, $b.Length) }
    }
    $fullBytes = $ms.ToArray()
    $ms.Dispose()

    Write-Log "Collector-style read: $collectorBytes byte(s) | Full paged read: $($fullBytes.Length) byte(s) | SQL total: $sqlTotalBytes" "INFO"
    if ($collectorBytes -lt $sqlTotalBytes) {
        Write-Log "COLLECTOR READ IS PARTIAL for this handle (pagination and/or binary truncation)" "WARN"
    }
    else {
        Write-Log "Collector-style read is complete for this handle" "SUCCESS"
    }

    if ($fullBytes.Length -eq 0) {
        Write-Log "No bytes retrieved on full read; skipping content inspection" "ERROR"
        continue
    }

    # Content inspection on the full bytes.
    if (Test-b2b_IsGzip -Blob $fullBytes) {
        $text = Get-b2b_ReportText -Blob $fullBytes
        Write-Log "Format: GZIP; decompressed report text length $($text.Length) char(s)" "INFO"
    }
    elseif ($fullBytes.Length -ge 2 -and $fullBytes[0] -eq 0xAC -and $fullBytes[1] -eq 0xED) {
        $text = [System.Text.Encoding]::UTF8.GetString($fullBytes)
        Write-Log "Format: JAVA_SERIALIZED (not gzip); inspecting raw bytes as text" "WARN"
    }
    else {
        $text = [System.Text.Encoding]::UTF8.GetString($fullBytes)
        Write-Log "Format: OTHER (first bytes $([System.BitConverter]::ToString($fullBytes[0..([Math]::Min(3, $fullBytes.Length - 1))]))); inspecting raw bytes as text" "WARN"
    }

    foreach ($marker in @('Map Name:', 'Translation Report', '<StatusReport>', 'Status report', '<ProcessData>')) {
        $idx = $text.IndexOf($marker)
        Write-Log "Marker '$marker': $(if ($idx -ge 0) { "found at char $idx" } else { 'not found' })" "INFO"
    }

    $headLen = [Math]::Min(800, $text.Length)
    Write-Log "HEAD ($headLen chars): $($text.Substring(0, $headLen))" "INFO"
    if ($text.Length -gt 1200) {
        Write-Log "TAIL (400 chars): $($text.Substring($text.Length - 400))" "INFO"
    }
}

Write-Log "Step 08 blob probe complete" "SUCCESS"
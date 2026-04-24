<#
.SYNOPSIS
    Step 6B - BPML Bulk Extraction
    Extracts every latest-version BPML XML from b2bi to disk, organized by family.

.DESCRIPTION
    Part of the Step 6 FA_CLIENTS_MAIN Anatomy investigation. Retrieves the
    latest-version BPML for every active (30d) workflow definition PLUS the
    17 dormant FA_CLIENTS workflows (which run inline inside MAIN and therefore
    don't appear in WF_INST_S).

    Storage model (verified Step 6B schema discovery):
    - Each (WFD_ID, WFD_VERSION) has a row in b2bi.dbo.WFD_XML
    - WFD_XML.XML is a handle (not content) pointing to DATA_TABLE.DATA_ID
    - DATA_TABLE.DATA_OBJECT holds the gzip-compressed payload
    - After gzip decompression, each blob has a variable-length Java
      serialization preamble BEFORE the XML content begins. The preamble
      can contain arbitrary bytes including stray '<' characters.
    - BPMLs may begin with one of three valid XML starts:
        <?xml    (XML declaration)
        <!--     (XML comment prologue, e.g., copyright headers)
        <process (root element directly)
    - Extraction scans the decompressed payload for all three markers and
      takes the EARLIEST occurrence - that is the true XML start.
    - No pagination - all blobs are PAGE_INDEX = 0

    CHANGELOG
    ---------
    2026-04-24  v4: Multi-marker scan. v3 looked only for '<process' and
                    failed on BPMLs with XML comment prologues where
                    '<process' appears past the 256-byte scan window.
                    New version scans for earliest of '<?xml', '<!--',
                    or '<process' in the first 1024 bytes. This is the
                    correct general-purpose XML-start detection for
                    Sterling BPMLs.
    2026-04-24  v3: Switched marker from '<' to '<process' to avoid stray
                    '<' bytes in the Sterling preamble. Regressed 2 files
                    with long XML comment prologues.
    2026-04-24  v2: Fixed StreamReader encoding corruption by decompressing
                    to bytes and slicing instead of decoding to string.
    2026-04-24  v1: Initial implementation.

.PARAMETER ServerName
    SQL Server hosting b2bi. Default: FA-INT-DBP

.PARAMETER DatabaseName
    Default: b2bi

.PARAMETER OutputDir
    Root output directory. BPMLs will be written into family subfolders under
    this path. Required - script will create the directory tree if missing.

.PARAMETER IncludeDormantFAClients
    Switch. When set (default: $true) includes the 17 dormant FA_CLIENTS
    workflows that run inline inside MAIN. Set to $false to extract only
    30d-active workflows.

.EXAMPLE
    .\Step_06B_Extract_BPMLs.ps1 -OutputDir 'E:\xFACts-Investigation\Step_06B_BPMLs'

.NOTES
    Read-only against b2bi. No data modification.
    Expected runtime: < 60 seconds for all 429 BPMLs.
    No dependencies beyond SqlServer module (Invoke-Sqlcmd).
#>

[CmdletBinding()]
param(
    [string]$ServerName             = 'FA-INT-DBP',
    [string]$DatabaseName           = 'b2bi',
    [Parameter(Mandatory=$true)]
    [string]$OutputDir,
    [bool]  $IncludeDormantFAClients = $true
)

$ErrorActionPreference = 'Stop'
$startTime             = Get-Date

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Expand-GzipToBytes {
    param([byte[]]$Bytes)

    $ms = New-Object System.IO.MemoryStream(,$Bytes)
    try {
        $gz = New-Object System.IO.Compression.GZipStream(
            $ms, [System.IO.Compression.CompressionMode]::Decompress)
        try {
            $out = New-Object System.IO.MemoryStream
            try {
                $gz.CopyTo($out)
                return $out.ToArray()
            } finally { $out.Dispose() }
        } finally { $gz.Dispose() }
    } finally { $ms.Dispose() }
}

function Find-ByteSequence {
    <#
    Search for a byte sequence inside a byte array starting at $StartOffset,
    up to $MaxOffset. Returns the 0-based index of the first match, or -1
    if not found within the scan window.
    #>
    param(
        [byte[]]$Haystack,
        [byte[]]$Needle,
        [int]   $StartOffset = 0,
        [int]   $MaxOffset   = [int]::MaxValue
    )

    $limit = [Math]::Min($Haystack.Length - $Needle.Length, $MaxOffset)
    for ($i = $StartOffset; $i -le $limit; $i++) {
        $match = $true
        for ($j = 0; $j -lt $Needle.Length; $j++) {
            if ($Haystack[$i + $j] -ne $Needle[$j]) {
                $match = $false
                break
            }
        }
        if ($match) { return $i }
    }
    return -1
}

function Get-BpmlXmlBytes {
    <#
    Strip Sterling's binary preamble from the decompressed payload.
    BPMLs can start with one of three valid XML prologues:
        <?xml    (XML declaration - 0x3C 0x3F 0x78 0x6D 0x6C)
        <!--     (XML comment      - 0x3C 0x21 0x2D 0x2D)
        <process (root element     - 0x3C 0x70 0x72 0x6F 0x63 0x65 0x73 0x73)
    Scan for all three markers and take the earliest match - that's the
    true XML start.
    #>
    param([byte[]]$DecompressedBytes)

    $scanLimit = 1024

    $xmlDeclMarker    = [byte[]](0x3C, 0x3F, 0x78, 0x6D, 0x6C)
    $xmlCommentMarker = [byte[]](0x3C, 0x21, 0x2D, 0x2D)
    $processMarker    = [byte[]](0x3C, 0x70, 0x72, 0x6F, 0x63, 0x65, 0x73, 0x73)

    $idxDecl    = Find-ByteSequence -Haystack $DecompressedBytes -Needle $xmlDeclMarker    -MaxOffset $scanLimit
    $idxComment = Find-ByteSequence -Haystack $DecompressedBytes -Needle $xmlCommentMarker -MaxOffset $scanLimit
    $idxProcess = Find-ByteSequence -Haystack $DecompressedBytes -Needle $processMarker    -MaxOffset $scanLimit

    # Pick the earliest non-negative index
    $candidates = @($idxDecl, $idxComment, $idxProcess) | Where-Object { $_ -ge 0 }
    if ($candidates.Count -eq 0) {
        throw "No XML start marker (<?xml | <!-- | <process) found in first $scanLimit bytes"
    }
    $idx = ($candidates | Measure-Object -Minimum).Minimum

    $xmlLength = $DecompressedBytes.Length - $idx
    $xmlBytes  = New-Object 'byte[]' $xmlLength
    [Array]::Copy($DecompressedBytes, $idx, $xmlBytes, 0, $xmlLength)
    return $xmlBytes
}

function Get-FamilyFolder {
    param([string]$Name)

    switch -Regex ($Name) {
        '^FA_CLIENTS_'                           { return '01_FA_CLIENTS' }
        '^FA_FROM_'                              { return '02_FA_FROM' }
        '^FA_TO_'                                { return '03_FA_TO' }
        '^FA_DM_'                                { return '04_FA_DM' }
        '^FA_B2B_'                               { return '06_FA_Specialized' }
        '^FA_INTEGRATION_'                       { return '06_FA_Specialized' }
        '^FA_CUSTOM_'                            { return '06_FA_Specialized' }
        '^FA_CLA_'                               { return '06_FA_Specialized' }
        '^FA_'                                   { return '05_FA_OTHER' }
        '^Schedule_'                             { return '07_Schedule' }
        '^FileGateway'                           { return '09_FileGateway' }
        '^(TimeoutEvent|Alert|AlertNotification|EmailOnError|Recover\.bpml|Check)' {
                                                   return '08_Sterling_Infra' }
        '^(Mailbox|AS2|AS3|EDIINT)'              { return '10_Mailbox_AS_EDI' }
        '^AFT'                                   { return '11_AFT_FILE_REMOVE' }
        '^FILE_REMOVE_'                          { return '11_AFT_FILE_REMOVE' }
        default                                  { return '12_OTHER' }
    }
}

function Get-SafeFileName {
    param([string]$Name)
    $invalid = [IO.Path]::GetInvalidFileNameChars() -join ''
    $regex   = "[$([regex]::Escape($invalid))]"
    return ($Name -replace $regex, '_')
}

# ---------------------------------------------------------------------------
# Prepare output directory
# ---------------------------------------------------------------------------

if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

$logPath      = Join-Path $OutputDir 'Step_06B_ExtractionLog.txt'
$manifestPath = Join-Path $OutputDir 'Step_06B_ExtractionManifest.csv'

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$logLines = New-Object System.Collections.Generic.List[string]
$logLines.Add("Step 6B BPML Extraction - started $startTime")
$logLines.Add("Server: $ServerName   Database: $DatabaseName")
$logLines.Add("OutputDir: $OutputDir")
$logLines.Add("IncludeDormantFAClients: $IncludeDormantFAClients")
$logLines.Add('')

Write-Host "Step 6B BPML Extraction" -ForegroundColor Cyan
Write-Host ("  Server : {0}" -f $ServerName)
Write-Host ("  Target : {0}" -f $OutputDir)
Write-Host ""

# ---------------------------------------------------------------------------
# Single round-trip query
# ---------------------------------------------------------------------------

Write-Host "Querying b2bi for target BPML blobs..." -ForegroundColor Yellow

$query = @"
-- Target set:
--   * Every WFD with activity in the last 30 days across WF_INST_S + WF_INST_S_RESTORE
--   * Plus 17 dormant FA_CLIENTS workflows (inline sub-workflows)
-- Grain: one row per WFD_ID at its latest WFD_VERSION.
-- Blob  : joined via WFD_XML -> DATA_TABLE (gzip-compressed XML with binary preamble).

WITH wfd_latest AS (
    SELECT w.WFD_ID, w.WFD_VERSION, w.NAME, w.MOD_DATE, w.EDITED_BY
    FROM b2bi.dbo.WFD w
    INNER JOIN (
        SELECT WFD_ID, MAX(WFD_VERSION) AS max_version
        FROM b2bi.dbo.WFD
        GROUP BY WFD_ID
    ) latest
      ON latest.WFD_ID = w.WFD_ID
     AND latest.max_version = w.WFD_VERSION
),
active_30d AS (
    SELECT DISTINCT WFD_ID
    FROM (
        SELECT WFD_ID FROM b2bi.dbo.WF_INST_S
        WHERE START_TIME >= DATEADD(DAY, -30, GETDATE())
        UNION ALL
        SELECT WFD_ID FROM b2bi.dbo.WF_INST_S_RESTORE
        WHERE START_TIME >= DATEADD(DAY, -30, GETDATE())
    ) a
),
dormant_fa_clients AS (
    SELECT WFD_ID FROM (VALUES
        (793),   -- FA_CLIENTS_COMM_CALL
        (796),   -- FA_CLIENTS_GET_DOCS
        (799),   -- FA_CLIENTS_PREP_SOURCE
        (803),   -- FA_CLIENTS_PREP_COMM_CALL
        (804),   -- FA_CLIENTS_DUP_CHECK
        (805),   -- FA_CLIENTS_TABLE_INSERT
        (806),   -- FA_CLIENTS_TABLE_PULL
        (807),   -- FA_CLIENTS_TRANS
        (808),   -- FA_CLIENTS_WORKERS_COMP
        (810),   -- FA_CLIENTS_FILE_MERGE
        (812),   -- FA_CLIENTS_ETL_CALL
        (817),   -- FA_CLIENTS_ACCOUNTS_LOAD
        (826),   -- FA_CLIENTS_ADDRESS_CHECK
        (828),   -- FA_CLIENTS_ENCOUNTER_ID
        (975),   -- FA_CLIENTS_POST_TRANSLATION
        (1391),  -- FA_CLIENTS_TRANSLATION_STAGING
        (1440)   -- FA_CLIENTS_REMIT_DATA_VERIFICATION
    ) v(WFD_ID)
),
targets AS (
    SELECT WFD_ID FROM active_30d
    $(if ($IncludeDormantFAClients) { 'UNION SELECT WFD_ID FROM dormant_fa_clients' })
)
SELECT
    wl.WFD_ID,
    wl.WFD_VERSION,
    wl.NAME,
    wl.MOD_DATE,
    wl.EDITED_BY,
    wx.XML                        AS data_id,
    DATALENGTH(dt.DATA_OBJECT)    AS compressed_bytes,
    dt.DATA_OBJECT                AS blob
FROM targets t
INNER JOIN wfd_latest wl    ON wl.WFD_ID = t.WFD_ID
LEFT JOIN  b2bi.dbo.WFD_XML wx ON wx.WFD_ID = wl.WFD_ID AND wx.WFD_VERSION = wl.WFD_VERSION
LEFT JOIN  b2bi.dbo.DATA_TABLE dt ON dt.DATA_ID = wx.XML
ORDER BY wl.NAME;
"@

$rows = Invoke-Sqlcmd `
    -ServerInstance     $ServerName `
    -Database           $DatabaseName `
    -Query              $query `
    -TrustServerCertificate `
    -QueryTimeout       120 `
    -MaxBinaryLength    52428800

$targetCount = @($rows).Count
Write-Host ("  Retrieved {0} rows" -f $targetCount)
Write-Host ""
$logLines.Add("Retrieved $targetCount rows from b2bi")
$logLines.Add('')

# ---------------------------------------------------------------------------
# Process each row
# ---------------------------------------------------------------------------

$manifest = New-Object System.Collections.Generic.List[PSCustomObject]
$stats    = @{
    Success       = 0
    MissingBlob   = 0
    DecompressErr = 0
    TotalBytesIn  = 0L
    TotalBytesOut = 0L
}
$familyFolders = @{}
$preambleLengths = @{}

Write-Host "Decompressing and writing BPMLs..." -ForegroundColor Yellow

foreach ($row in $rows) {
    $wfdId       = [int]$row.WFD_ID
    $wfdVersion  = [int]$row.WFD_VERSION
    $name        = [string]$row.NAME
    $dataId      = if ($row.data_id -is [DBNull]) { $null } else { [string]$row.data_id }
    $compBytes   = if ($row.compressed_bytes -is [DBNull]) { 0 } else { [int]$row.compressed_bytes }

    $family      = Get-FamilyFolder -Name $name
    $safeName    = Get-SafeFileName -Name $name
    $fileName    = "{0}__v{1:D3}.bpml.xml" -f $safeName, $wfdVersion

    if (-not $familyFolders.ContainsKey($family)) {
        $fPath = Join-Path $OutputDir $family
        if (-not (Test-Path $fPath)) {
            New-Item -ItemType Directory -Path $fPath -Force | Out-Null
        }
        $familyFolders[$family] = $fPath
    }
    $outPath = Join-Path $familyFolders[$family] $fileName

    $status       = ''
    $decompBytes  = 0
    $preambleLen  = 0
    $errMsg       = ''

    if (-not $dataId) {
        $status = 'NO_WFD_XML_ROW'
        $stats.MissingBlob++
        Write-Host ("  [WARN] {0}: no WFD_XML row" -f $name) -ForegroundColor DarkYellow
    }
    elseif ($row.blob -is [DBNull] -or $null -eq $row.blob) {
        $status = 'NO_DATA_TABLE_ROW'
        $stats.MissingBlob++
        Write-Host ("  [WARN] {0}: no DATA_TABLE row for handle {1}" -f $name, $dataId) -ForegroundColor DarkYellow
    }
    else {
        try {
            $decompressedAll = Expand-GzipToBytes -Bytes ([byte[]]$row.blob)
            $xmlBytes        = Get-BpmlXmlBytes  -DecompressedBytes $decompressedAll
            $preambleLen     = $decompressedAll.Length - $xmlBytes.Length

            [System.IO.File]::WriteAllBytes($outPath, $xmlBytes)

            $decompBytes  = $xmlBytes.Length
            $status       = 'OK'
            $stats.Success++
            $stats.TotalBytesIn  += $compBytes
            $stats.TotalBytesOut += $decompBytes

            if ($preambleLengths.ContainsKey($preambleLen)) {
                $preambleLengths[$preambleLen]++
            } else {
                $preambleLengths[$preambleLen] = 1
            }
        }
        catch {
            $status = 'DECOMPRESS_ERROR'
            $errMsg = $_.Exception.Message
            $stats.DecompressErr++
            Write-Host ("  [ERROR] {0}: {1}" -f $name, $errMsg) -ForegroundColor Red
        }
    }

    $manifest.Add([PSCustomObject]@{
        WFD_ID             = $wfdId
        WFD_VERSION        = $wfdVersion
        NAME               = $name
        family_folder      = $family
        file_name          = $fileName
        relative_path      = Join-Path $family $fileName
        compressed_bytes   = $compBytes
        decompressed_bytes = $decompBytes
        preamble_bytes     = $preambleLen
        data_id            = $dataId
        mod_date           = $row.MOD_DATE
        edited_by          = $row.EDITED_BY
        status             = $status
        error              = $errMsg
    })
}

# ---------------------------------------------------------------------------
# Write manifest CSV
# ---------------------------------------------------------------------------

$manifest | Export-Csv -Path $manifestPath -NoTypeInformation -Encoding UTF8

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

$duration = (Get-Date) - $startTime

$summaryLines = @(
    ''
    ('=' * 72)
    'EXTRACTION COMPLETE'
    ('=' * 72)
    ''
    ('Total BPMLs queried      : {0}' -f $targetCount)
    ('Successfully extracted   : {0}' -f $stats.Success)
    ('Missing blob (no row)    : {0}' -f $stats.MissingBlob)
    ('Decompression errors     : {0}' -f $stats.DecompressErr)
    ''
    ('Total compressed bytes   : {0:N0}' -f $stats.TotalBytesIn)
    ('Total XML bytes written  : {0:N0}' -f $stats.TotalBytesOut)
    ('Compression ratio        : {0:N2}x' -f `
        $(if ($stats.TotalBytesIn -gt 0) { $stats.TotalBytesOut / $stats.TotalBytesIn } else { 0 }))
    ''
    'Preamble length distribution:'
)
foreach ($len in ($preambleLengths.Keys | Sort-Object)) {
    $summaryLines += ('  {0,3} bytes : {1} files' -f $len, $preambleLengths[$len])
}
$summaryLines += @(
    ''
    ('Output directory : {0}' -f $OutputDir)
    ('Manifest         : {0}' -f $manifestPath)
    ('Log              : {0}' -f $logPath)
    ''
    ('Elapsed          : {0:N1} seconds' -f $duration.TotalSeconds)
)

$summaryLines | ForEach-Object { Write-Host $_ }
$summaryLines | ForEach-Object { $logLines.Add($_) }

Write-Host ''
Write-Host 'Per-family extraction counts:' -ForegroundColor Cyan
$logLines.Add('')
$logLines.Add('Per-family extraction counts:')
$manifest |
    Group-Object family_folder |
    Sort-Object Name |
    ForEach-Object {
        $successCount = @($_.Group | Where-Object { $_.status -eq 'OK' }).Count
        $line = "  {0,-22} {1,5} ({2} ok)" -f $_.Name, $_.Count, $successCount
        Write-Host $line
        $logLines.Add($line)
    }

[System.IO.File]::WriteAllLines($logPath, $logLines, $utf8NoBom)
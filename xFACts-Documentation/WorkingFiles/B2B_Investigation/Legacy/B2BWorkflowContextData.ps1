# ==============================================================================
# Decompress-B2BWorkflowContextData.ps1
#
# Purpose: Decompress all TRANS_DATA rows associated with a given WF_ID and
#          save decompressed content to files for inspection. Used to explore
#          what Sterling stores in WORKFLOW_CONTEXT for each workflow run.
#
# Read-only. Writes decompressed output to an OutputDir on disk.
# ==============================================================================

param(
    [string]$ServerName = "FA-INT-DBP",
    [string]$DatabaseName = "b2bi",
    [Parameter(Mandatory=$true)]
    [string]$WFID,
    [string]$OutputDir = "$env:TEMP\wf_content"
)

$ErrorActionPreference = "Stop"

function Invoke-Query {
    param([string]$Query)

    Invoke-Sqlcmd `
        -ServerInstance $ServerName `
        -Database $DatabaseName `
        -Query $Query `
        -TrustServerCertificate `
        -QueryTimeout 120 `
        -MaxBinaryLength 20971520  # 20 MB in case we hit large blobs
}

function Expand-GzipBytes {
    param([byte[]]$Bytes)

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

# Prepare output dir
if (Test-Path $OutputDir) {
    Remove-Item "$OutputDir\*" -Force -Recurse -ErrorAction SilentlyContinue
} else {
    New-Item -ItemType Directory -Path $OutputDir | Out-Null
}

Write-Host "Fetching TRANS_DATA rows for WF_ID = $WFID ..." -ForegroundColor Cyan

$query = @"
SELECT DATA_ID, PAGE_INDEX, DATA_TYPE, REFERENCE_TABLE, DATALENGTH(DATA_OBJECT) AS BYTE_LENGTH, DATA_OBJECT
FROM dbo.TRANS_DATA
WHERE WF_ID = $WFID
--AND REFERENCE_TABLE = 'DOCUMENT'
ORDER BY DATA_ID, PAGE_INDEX;
"@

$rows = Invoke-Query -Query $query

if (-not $rows) {
    Write-Host "No rows found for WF_ID $WFID." -ForegroundColor Yellow
    return
}

$total = @($rows).Count
Write-Host ("Found {0} rows. Decompressing..." -f $total) -ForegroundColor Cyan
Write-Host ""

# Group by DATA_ID since multi-page content belongs together
$grouped = $rows | Group-Object DATA_ID

$fileIndex = 0
$refTableCounts = @{}

foreach ($group in $grouped) {
    $fileIndex++
    $dataId = $group.Name
    $pages = $group.Group | Sort-Object PAGE_INDEX
    $refTable = $pages[0].REFERENCE_TABLE
    if ([string]::IsNullOrEmpty($refTable) -or $refTable -eq [DBNull]::Value) {
        $refTable = "NULL"
    }
    $dataType = $pages[0].DATA_TYPE
    $totalBytes = ($pages | Measure-Object -Property BYTE_LENGTH -Sum).Sum

    if (-not $refTableCounts.ContainsKey($refTable)) {
        $refTableCounts[$refTable] = 0
    }
    $refTableCounts[$refTable]++

    # Concatenate all pages before decompression
    $allBytes = New-Object System.Collections.Generic.List[byte]
    foreach ($page in $pages) {
        if ($page.DATA_OBJECT -is [byte[]]) {
            $allBytes.AddRange([byte[]]$page.DATA_OBJECT)
        }
    }
    $combinedBytes = $allBytes.ToArray()

    try {
        $content = Expand-GzipBytes -Bytes $combinedBytes
        $safeRefTable = $refTable -replace '[^a-zA-Z0-9_]', '_'
        $fileName = "{0:D4}_{1}_pages{2}.txt" -f $fileIndex, $safeRefTable, $pages.Count
        $outputPath = Join-Path $OutputDir $fileName

        $content | Out-File -FilePath $outputPath -Encoding UTF8

        $displaySize = if ($content.Length -lt 1024) { "{0} B" -f $content.Length }
                      elseif ($content.Length -lt 1048576) { "{0:N1} KB" -f ($content.Length / 1024) }
                      else { "{0:N1} MB" -f ($content.Length / 1048576) }

        Write-Host ("  [{0:D4}] {1} | type={2} | pages={3} | bytes={4} | decomp={5}" -f `
            $fileIndex, $refTable, $dataType, $pages.Count, $totalBytes, $displaySize) `
            -ForegroundColor DarkGray
    }
    catch {
        Write-Host ("  [{0:D4}] {1} | DECOMP ERROR: {2}" -f $fileIndex, $refTable, $_.Exception.Message) -ForegroundColor Red
    }
}

Write-Host ""
Write-Host ("=" * 80) -ForegroundColor Cyan
Write-Host "Summary by REFERENCE_TABLE:" -ForegroundColor Cyan
$refTableCounts.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
    Write-Host ("  {0,-30} {1}" -f $_.Key, $_.Value)
}
Write-Host ""
Write-Host ("Decompressed files saved to: {0}" -f $OutputDir) -ForegroundColor Cyan
Write-Host ""
Write-Host "Suggested next step: inspect the smaller files first to understand structure." -ForegroundColor Yellow
Write-Host "  Get-ChildItem `"$OutputDir`" | Sort-Object Length | Select-Object -First 5" -ForegroundColor DarkGray
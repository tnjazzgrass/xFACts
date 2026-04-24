# ==============================================================================
# Test-B2BScheduleTimingXml-Patterns.ps1
#
# Purpose: Same as Test-B2BScheduleTimingXml.ps1 but outputs ONLY distinct
#          timingXML patterns with counts. For scanning large result sets
#          (all active schedules) without per-schedule noise.
#
# Read-only. No writes to any table.
# ==============================================================================

param(
    [string]$ServerName = "FA-INT-DBP",
    [string]$DatabaseName = "b2bi",
    [string]$NamePattern = "%"
)

$ErrorActionPreference = "Stop"

function Invoke-Query {
    param([string]$Query)

    Invoke-Sqlcmd `
        -ServerInstance $ServerName `
        -Database $DatabaseName `
        -Query $Query `
        -TrustServerCertificate `
        -QueryTimeout 120
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

Write-Host "Fetching active schedules matching pattern '$NamePattern'..." -ForegroundColor Cyan

$schedQuery = @"
SELECT SCHEDULEID, SERVICENAME, STATUS, TIMINGXML
FROM dbo.SCHEDULE
WHERE SERVICENAME LIKE '$NamePattern'
  AND STATUS = 'ACTIVE'
  AND TIMINGXML IS NOT NULL
  AND TIMINGXML <> ''
ORDER BY SERVICENAME;
"@

$schedules = Invoke-Query -Query $schedQuery

if (-not $schedules) {
    Write-Host "No matching schedules found." -ForegroundColor Yellow
    return
}

$total = @($schedules).Count
Write-Host ("Found {0} schedules. Decompressing..." -f $total) -ForegroundColor Cyan

# Build a hashtable: XML -> @{ Count, SampleServices }
$patterns = @{}
$ok = 0
$errors = 0
$processed = 0

foreach ($sched in $schedules) {
    $processed++
    if ($processed % 50 -eq 0) {
        Write-Host ("  Processed {0}/{1}..." -f $processed, $total) -ForegroundColor DarkGray
    }

    $handle = $sched.TIMINGXML

    $dataQuery = @"
SELECT DATA_OBJECT
FROM dbo.DATA_TABLE
WHERE DATA_ID = '$handle';
"@

    try {
        $dataRow = Invoke-Query -Query $dataQuery
        if (-not $dataRow) { $errors++; continue }

        $xml = Expand-GzipBytes -Bytes $dataRow.DATA_OBJECT
        $ok++

        # Normalize: replace any 4-digit time with HHMM so we group by structure not clock value
        $normalized = [regex]::Replace($xml, '<time>\d{4}</time>', '<time>HHMM</time>')

        if (-not $patterns.ContainsKey($normalized)) {
            $patterns[$normalized] = @{
                Count          = 0
                SampleServices = New-Object System.Collections.Generic.List[string]
                SampleXml      = $xml
            }
        }
        $patterns[$normalized].Count++
        if ($patterns[$normalized].SampleServices.Count -lt 3) {
            $patterns[$normalized].SampleServices.Add($sched.SERVICENAME)
        }
    }
    catch {
        $errors++
    }
}

Write-Host ""
Write-Host ("=" * 80) -ForegroundColor Cyan
Write-Host ("Summary: Total={0}, OK={1}, Errors={2}, Distinct patterns={3}" -f $total, $ok, $errors, $patterns.Count) -ForegroundColor Cyan
Write-Host ("=" * 80) -ForegroundColor Cyan
Write-Host ""

# Output distinct patterns sorted by frequency
$patterns.GetEnumerator() |
    Sort-Object { $_.Value.Count } -Descending |
    ForEach-Object {
        Write-Host ("-" * 80)
        Write-Host ("Count: {0}" -f $_.Value.Count) -ForegroundColor Yellow
        Write-Host ("Sample services: {0}" -f ($_.Value.SampleServices -join ', ')) -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "Normalized structure:" -ForegroundColor Cyan
        Write-Host $_.Key
        Write-Host ""
        Write-Host "One real example:" -ForegroundColor Cyan
        Write-Host $_.Value.SampleXml
        Write-Host ""
    }
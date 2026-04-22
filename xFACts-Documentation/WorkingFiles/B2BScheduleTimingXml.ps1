# ==============================================================================
# Test-B2BScheduleTimingXml.ps1
#
# Purpose: Decompress and examine timingXML entries from Sterling's SCHEDULE
#          table for active LIFESPAN workflows. Confirms the XML format is
#          consistent across different schedule types before committing to a
#          design that relies on parsing this data.
#
# Read-only. No writes to any table.
# ==============================================================================

param(
    [string]$ServerName = "FA-INT-DBP",
    [string]$DatabaseName = "b2bi",
    [string]$NamePattern = "FA_CLIENTS_GET_LIST"
)

$ErrorActionPreference = "Stop"

function Invoke-Query {
    param([string]$Query)

    Invoke-Sqlcmd `
        -ServerInstance $ServerName `
        -Database $DatabaseName `
        -Query $Query `
        -TrustServerCertificate `
        -QueryTimeout 60
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

Write-Host "Fetching active schedules from SCHEDULE table..." -ForegroundColor Cyan

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

Write-Host ("Found {0} schedules. Decompressing timing XML for each..." -f @($schedules).Count) -ForegroundColor Cyan
Write-Host ""

$results = foreach ($sched in $schedules) {
    $handle = $sched.TIMINGXML

    # Fetch the DATA_TABLE row for this handle
    $dataQuery = @"
SELECT DATA_OBJECT
FROM dbo.DATA_TABLE
WHERE DATA_ID = '$handle';
"@

    $dataRow = Invoke-Query -Query $dataQuery

    if (-not $dataRow) {
        [pscustomobject]@{
            SCHEDULEID  = $sched.SCHEDULEID
            SERVICENAME = $sched.SERVICENAME
            HANDLE      = $handle
            XML         = '<DATA_TABLE row not found>'
            STATUS      = 'MISSING'
        }
        continue
    }

    try {
        $xml = Expand-GzipBytes -Bytes $dataRow.DATA_OBJECT

        [pscustomobject]@{
            SCHEDULEID  = $sched.SCHEDULEID
            SERVICENAME = $sched.SERVICENAME
            HANDLE      = $handle
            XML         = $xml
            STATUS      = 'OK'
        }
    }
    catch {
        [pscustomobject]@{
            SCHEDULEID  = $sched.SCHEDULEID
            SERVICENAME = $sched.SERVICENAME
            HANDLE      = $handle
            XML         = ('<decompression failed: {0}>' -f $_.Exception.Message)
            STATUS      = 'ERROR'
        }
    }
}

# Output each schedule's timing XML
foreach ($r in $results) {
    Write-Host ("-" * 80)
    Write-Host ("{0} - {1}" -f $r.SCHEDULEID, $r.SERVICENAME) -ForegroundColor Yellow
    Write-Host ("Handle: {0}" -f $r.HANDLE) -ForegroundColor DarkGray
    Write-Host ("Status: {0}" -f $r.STATUS) -ForegroundColor DarkGray
    Write-Host ""
    Write-Host $r.XML
    Write-Host ""
}

# Summary
Write-Host ("=" * 80) -ForegroundColor Cyan
Write-Host "Summary:" -ForegroundColor Cyan
Write-Host ("  Total schedules: {0}" -f @($results).Count)
Write-Host ("  OK:              {0}" -f @($results | Where-Object STATUS -eq 'OK').Count)
Write-Host ("  MISSING:         {0}" -f @($results | Where-Object STATUS -eq 'MISSING').Count)
Write-Host ("  ERROR:           {0}" -f @($results | Where-Object STATUS -eq 'ERROR').Count)
Write-Host ""

# Distinct XML structure patterns (useful for spotting variants)
Write-Host "Distinct XML patterns:" -ForegroundColor Cyan
$results |
    Where-Object STATUS -eq 'OK' |
    Group-Object XML |
    Sort-Object Count -Descending |
    ForEach-Object {
        Write-Host ""
        Write-Host ("Count: {0}" -f $_.Count) -ForegroundColor Yellow
        Write-Host $_.Name
    }
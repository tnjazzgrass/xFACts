<#
    Investigate-FailedRuns-ProcessData.ps1
    
    One-off investigation script: decompresses ProcessData for 5 failed MAIN runs
    from 2026-04-20 and writes them to disk for inspection.
    
    Targets:
      7998314 - PGP decrypt failure at 08:34
      7994488 - SSH_DISCONNECT failure at 04:00 (COACHELLA_VALLEY_ANESTHESIA child 1)
      7994489 - SSH_DISCONNECT failure at 04:00 (MSN_HEALTHCARE_SOLUTION child 1)
      7994490 - SSH_DISCONNECT failure at 04:00 (MSN_HEALTHCARE_SOLUTION child 2)
      7994491 - SSH_DISCONNECT failure at 04:00 (COACHELLA_VALLEY_ANESTHESIA child 2)
    
    Run from: any machine with network access to FA-INT-DBP
    Writes to: current directory as ProcessData_<WFID>.xml
#>

$ErrorActionPreference = 'Stop'

$wfIds = @(7998314, 7994488, 7994489, 7994490, 7994491)

function Expand-GzipBytes {
    param([byte[]]$bytes)
    $ms = New-Object System.IO.MemoryStream(,$bytes)
    $gz = New-Object System.IO.Compression.GZipStream($ms, [System.IO.Compression.CompressionMode]::Decompress)
    $sr = New-Object System.IO.StreamReader($gz)
    try {
        return $sr.ReadToEnd()
    } finally {
        $sr.Dispose(); $gz.Dispose(); $ms.Dispose()
    }
}

foreach ($wfId in $wfIds) {
    Write-Host ""
    Write-Host "=== WF $wfId ===" -ForegroundColor Cyan
    
    # Get the first ProcessData row (ordered by CREATION_DATE ASC)
    $query = @"
SELECT TOP 1 DATA_ID, DATA_OBJECT
FROM b2bi.dbo.TRANS_DATA
WHERE WF_ID = $wfId
  AND REFERENCE_TABLE = 'DOCUMENT'
  AND PAGE_INDEX = 0
ORDER BY CREATION_DATE ASC, DATA_ID ASC;
"@
    
    $row = Invoke-Sqlcmd `
        -ServerInstance 'FA-INT-DBP' `
        -Database 'b2bi' `
        -Query $query `
        -TrustServerCertificate `
        -MaxBinaryLength 20971520 `
        -ApplicationName 'xFACts-B2BInvestigation'
    
    if (-not $row) {
        Write-Host "  No ProcessData found for WF $wfId" -ForegroundColor Yellow
        continue
    }
    
    # Decompress
    $bytes = [byte[]]$row.DATA_OBJECT
    $xml = Expand-GzipBytes -bytes $bytes
    
    # Write to file
    $outFile = "ProcessData_$wfId.xml"
    $xml | Out-File -FilePath $outFile -Encoding UTF8
    Write-Host "  Wrote $outFile ($($xml.Length) chars)" -ForegroundColor Green
    
    # Parse and show key fields
    try {
        $xmlDoc = [xml]$xml
        $clients = $xmlDoc.r.Client
        $clientCount = @($clients).Count
        Write-Host "  <Client> block count: $clientCount"
        
        foreach ($client in $clients) {
            Write-Host "    CLIENT_ID:       $($client.CLIENT_ID)"
            Write-Host "    SEQ_ID:          $($client.SEQ_ID)"
            Write-Host "    CLIENT_NAME:     $($client.CLIENT_NAME)"
            Write-Host "    PROCESS_TYPE:    $($client.PROCESS_TYPE)"
            Write-Host "    COMM_METHOD:     $($client.COMM_METHOD)"
            Write-Host "    BUSINESS_TYPE:   $($client.BUSINESS_TYPE)"
            Write-Host "    TRANSLATION_MAP: $($client.TRANSLATION_MAP)"
            Write-Host "    FILE_FILTER:     $($client.FILE_FILTER)"
            Write-Host "    GET_DOCS_TYPE:   $($client.GET_DOCS_TYPE)"
            Write-Host "    GET_DOCS_LOC:    $($client.GET_DOCS_LOC)"
            Write-Host "    ---"
        }
    } catch {
        Write-Host "  WARN: could not parse XML: $_" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "Done. Five ProcessData_*.xml files written to current directory." -ForegroundColor Cyan
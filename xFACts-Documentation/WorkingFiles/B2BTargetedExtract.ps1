# ==============================================================================
# Test-B2BTargetedExtract.ps1
#
# Purpose: Verify our targeting logic by extracting ONLY the ProcessData
#          metadata and Translation step outputs for a given WF_ID.
#          Much faster than full workflow extraction — decompresses only
#          the documents we care about for collector purposes.
#
# Read-only. Writes decompressed output to OutputDir on disk.
# ==============================================================================

param(
    [string]$ServerName = "FA-INT-DBP",
    [string]$DatabaseName = "b2bi",
    [Parameter(Mandatory=$true)]
    [string]$WFID,
    [string]$OutputDir = "$env:TEMP\wf_targeted"
)

$ErrorActionPreference = "Stop"

function Invoke-Query {
    param([string]$Query)

    Invoke-Sqlcmd `
        -ServerInstance $ServerName `
        -Database $DatabaseName `
        -Query $Query `
        -TrustServerCertificate `
        -QueryTimeout 60 `
        -MaxBinaryLength 20971520
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

# Prepare output dir (create subfolder per WF_ID)
$wfDir = Join-Path $OutputDir "WF_$WFID"
if (Test-Path $wfDir) {
    Remove-Item "$wfDir\*" -Force -Recurse -ErrorAction SilentlyContinue
} else {
    New-Item -ItemType Directory -Path $wfDir -Force | Out-Null
}

Write-Host ("Targeting extraction for WF_ID = {0}" -f $WFID) -ForegroundColor Cyan
Write-Host ""

# ==============================================================================
# Step 1: Find the ProcessData document (associated with Step 0)
# ==============================================================================
Write-Host "Step 1: Locating ProcessData (Step 0 InvokeBusinessProcessService context)..." -ForegroundColor Yellow

$step0Query = @"
SELECT TOP 1 STEP_ID, SERVICE_NAME, CONTENT, START_TIME
FROM dbo.WORKFLOW_CONTEXT
WHERE WORKFLOW_ID = $WFID
  AND STEP_ID = 0
ORDER BY START_TIME;
"@

$step0 = Invoke-Query -Query $step0Query

if (-not $step0) {
    Write-Host "  No Step 0 found. Skipping ProcessData extraction." -ForegroundColor DarkYellow
} else {
    Write-Host ("  Step 0 CONTENT: {0}" -f $step0.CONTENT) -ForegroundColor DarkGray
    Write-Host ("  Step 0 SERVICE: {0}" -f $step0.SERVICE_NAME) -ForegroundColor DarkGray

    # The ProcessData XML is typically the DATA_ID 1 less than Step 0's CONTENT
    # (numeric portion of the handle). But to be safe, look for any document-type
    # TRANS_DATA row that was created just before Step 0's start time.
    $processDataQuery = @"
SELECT TOP 1 td.DATA_ID, DATALENGTH(td.DATA_OBJECT) AS BYTE_LENGTH, td.DATA_OBJECT, td.CREATION_DATE
FROM dbo.TRANS_DATA td
WHERE td.WF_ID = $WFID
  AND td.REFERENCE_TABLE = 'DOCUMENT'
  AND td.PAGE_INDEX = 0
  AND td.CREATION_DATE <= '$($step0.START_TIME)'
ORDER BY td.CREATION_DATE DESC, td.DATA_ID DESC;
"@

    $processDataRow = Invoke-Query -Query $processDataQuery

    if ($processDataRow) {
        try {
            $xml = Expand-GzipBytes -Bytes $processDataRow.DATA_OBJECT
            $outputPath = Join-Path $wfDir "01_ProcessData_Step0.xml"
            $xml | Out-File -FilePath $outputPath -Encoding UTF8
            Write-Host ("  [OK] ProcessData extracted: {0}" -f $processDataRow.DATA_ID) -ForegroundColor Green
            Write-Host ("       Size: {0} bytes compressed, {1} bytes decompressed" -f `
                $processDataRow.BYTE_LENGTH, $xml.Length) -ForegroundColor DarkGray
            Write-Host ("       Output: {0}" -f $outputPath) -ForegroundColor DarkGray

            # Quick content preview
            if ($xml -match '<CLIENT_ID>([^<]+)</CLIENT_ID>') { Write-Host ("       CLIENT_ID: {0}" -f $Matches[1]) -ForegroundColor DarkGray }
            if ($xml -match '<SEQ_ID>([^<]+)</SEQ_ID>') { Write-Host ("       SEQ_ID: {0}" -f $Matches[1]) -ForegroundColor DarkGray }
            if ($xml -match '<CLIENT_NAME>([^<]+)</CLIENT_NAME>') { Write-Host ("       CLIENT: {0}" -f $Matches[1]) -ForegroundColor DarkGray }
            if ($xml -match '<PROCESS_TYPE>([^<]+)</PROCESS_TYPE>') { Write-Host ("       PROCESS_TYPE: {0}" -f $Matches[1]) -ForegroundColor DarkGray }
            if ($xml -match '<TRANSLATION_MAP>([^<]+)</TRANSLATION_MAP>') { Write-Host ("       TRANSLATION_MAP: {0}" -f $Matches[1]) -ForegroundColor DarkGray }
        }
        catch {
            Write-Host ("  [ERROR] ProcessData decompression failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
        }
    } else {
        Write-Host "  [WARN] No matching ProcessData document found." -ForegroundColor DarkYellow
    }
}

Write-Host ""

# ==============================================================================
# Step 2: Find all Translation step outputs
# ==============================================================================
Write-Host "Step 2: Locating Translation step outputs..." -ForegroundColor Yellow

$translationQuery = @"
SELECT STEP_ID, SERVICE_NAME, DOC_ID, CONTENT, START_TIME, END_TIME
FROM dbo.WORKFLOW_CONTEXT
WHERE WORKFLOW_ID = $WFID
  AND SERVICE_NAME = 'Translation'
ORDER BY STEP_ID;
"@

$translationSteps = Invoke-Query -Query $translationQuery

if (-not $translationSteps) {
    Write-Host "  No Translation steps found in this workflow." -ForegroundColor DarkYellow
} else {
    $steps = @($translationSteps)
    Write-Host ("  Found {0} Translation step(s)" -f $steps.Count) -ForegroundColor DarkGray

    foreach ($tStep in $steps) {
        Write-Host ""
        Write-Host ("  --- Translation Step {0} ---" -f $tStep.STEP_ID) -ForegroundColor Cyan

        # Find the document created just AFTER this Translation step completed
        # (Sterling writes the output just after End_Time)
        $outputQuery = @"
SELECT TOP 3 td.DATA_ID, DATALENGTH(td.DATA_OBJECT) AS BYTE_LENGTH, td.DATA_OBJECT, td.CREATION_DATE
FROM dbo.TRANS_DATA td
WHERE td.WF_ID = $WFID
  AND td.REFERENCE_TABLE = 'DOCUMENT'
  AND td.PAGE_INDEX = 0
  AND td.CREATION_DATE >= '$($tStep.START_TIME)'
  AND td.CREATION_DATE <= DATEADD(SECOND, 2, '$($tStep.END_TIME)')
ORDER BY td.CREATION_DATE, td.DATA_ID;
"@

        $outputRows = Invoke-Query -Query $outputQuery

        if (-not $outputRows) {
            Write-Host "    [WARN] No output documents found for this Translation step." -ForegroundColor DarkYellow
            continue
        }

        $i = 0
        foreach ($row in @($outputRows)) {
            $i++
            try {
                $content = Expand-GzipBytes -Bytes $row.DATA_OBJECT
                $outputPath = Join-Path $wfDir ("02_Translation_Step{0:D3}_Output{1:D2}.xml" -f $tStep.STEP_ID, $i)
                $content | Out-File -FilePath $outputPath -Encoding UTF8

                Write-Host ("    [OK] Output {0}: {1}" -f $i, $row.DATA_ID) -ForegroundColor Green
                Write-Host ("         Size: {0} bytes compressed, {1} bytes decompressed" -f `
                    $row.BYTE_LENGTH, $content.Length) -ForegroundColor DarkGray
                Write-Host ("         Output: {0}" -f $outputPath) -ForegroundColor DarkGray

                # Quick content preview to help identify the CLIENTS_ACCTS file
                $firstTag = if ($content -match '<(\w+)[^>]*>') { $Matches[1] } else { "unknown" }
                Write-Host ("         Root element: <{0}>" -f $firstTag) -ForegroundColor DarkGray
                if ($content -match '<TRANS_TYPE>([^<]+)</TRANS_TYPE>') { Write-Host ("         TRANS_TYPE: {0}" -f $Matches[1]) -ForegroundColor DarkGray }
                if ($content -match '<FLOW_ID>([^<]+)</FLOW_ID>') { Write-Host ("         FLOW_ID: {0}" -f $Matches[1]) -ForegroundColor DarkGray }

                $txCount = ([regex]::Matches($content, '<TRANSACTION>')).Count
                if ($txCount -gt 0) { Write-Host ("         <TRANSACTION> count: {0}" -f $txCount) -ForegroundColor DarkGray }
            }
            catch {
                Write-Host ("    [ERROR] Decompression failed for {0}: {1}" -f $row.DATA_ID, $_.Exception.Message) -ForegroundColor Red
            }
        }
    }
}

Write-Host ""
Write-Host ("=" * 80) -ForegroundColor Cyan
Write-Host ("All targeted outputs written to: {0}" -f $wfDir) -ForegroundColor Cyan
Write-Host ""
Write-Host "Inspect the files to confirm:" -ForegroundColor Yellow
Write-Host "  - 01_ProcessData_Step0.xml contains the <Client> block with CLIENT_ID/SEQ_ID" -ForegroundColor DarkGray
Write-Host "  - 02_Translation_*.xml files — identify which contains the CLIENTS_ACCTS-style data" -ForegroundColor DarkGray
Write-Host "    (typically smaller, with <VITAL>/<TRANSACTIONS>/<TRANSACTION> or similar structure)" -ForegroundColor DarkGray
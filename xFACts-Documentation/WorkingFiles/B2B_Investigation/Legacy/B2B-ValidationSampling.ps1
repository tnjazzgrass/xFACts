# ==============================================================================
# B2B-ValidationSampling.ps1
#
# Investigative script — validates the CLIENTS_PARAM field inventory against
# real ProcessData XMLs, and produces a typo report for Melissa.
#
# Does three things:
#   1. Queries Integration for the 5 known typo PARAMETER_NAMEs and writes a
#      report file suitable for handing to the File Processing Supervisor
#   2. Samples ~25 recent FA_CLIENTS_MAIN runs across a target set of
#      PROCESS_TYPE/COMM_METHOD pairs, pulling 1-2 per pair as available
#   3. Decompresses each sample's ProcessData, writes the raw XML to disk,
#      and produces a validation diff: fields observed in XML vs. the
#      CLIENTS_PARAM inventory. Flags anything novel.
#
# Run from: any machine with network access to FA-INT-DBP and AVG-PROD-LSNR
# Writes to: $env:TEMP\xFACts-B2B-Samples (configurable below)
# ==============================================================================

$ErrorActionPreference = 'Stop'

# ---------------------- Configuration ----------------------

$outputRoot = Join-Path $env:TEMP 'xFACts-B2B-Samples'

$b2biServer      = 'FA-INT-DBP'
$b2biDatabase    = 'b2bi'
$integServer     = 'AVG-PROD-LSNR'
$integDatabase   = 'Integration'
$appName         = 'xFACts-B2BInvestigation'

# Recent-window for MAIN run sampling. b2bi purges aggressively; 48h should
# give us enough coverage for common types. If a rare type doesn't appear,
# the script flags it as "no recent sample found" and moves on.
$lookbackHours = 48

# Samples per (PROCESS_TYPE, COMM_METHOD) pair. 2 for heavy hitters, 1 for
# medium, best-effort for rare. Total target is ~25.
$targetPairs = @(
    @{ PT='NEW_BUSINESS';    CM='INBOUND';  Target=2 },
    @{ PT='SIMPLE_EMAIL';    CM='INBOUND';  Target=2 },
    @{ PT='REMIT';           CM='OUTBOUND'; Target=2 },
    @{ PT='SFTP_PULL';       CM='OUTBOUND'; Target=2 },
    @{ PT='NOTES';           CM='OUTBOUND'; Target=2 },
    @{ PT='PAYMENT';         CM='INBOUND';  Target=2 },
    @{ PT='RECON';           CM='INBOUND';  Target=2 },
    @{ PT='RETURN';          CM='OUTBOUND'; Target=2 },
    @{ PT='FILE_EMAIL';      CM='OUTBOUND'; Target=2 },
    @{ PT='SPECIAL_PROCESS'; CM='INBOUND';  Target=1 },
    @{ PT='FILE_DELETION';   CM='INBOUND';  Target=1 },
    @{ PT='BDL';             CM='INBOUND';  Target=1 },
    @{ PT='RETURN';          CM='INBOUND';  Target=1 },
    @{ PT='SFTP_PUSH';       CM='OUTBOUND'; Target=1 },
    @{ PT='RECON';           CM='OUTBOUND'; Target=1 },
    @{ PT='FILE_EMAIL';      CM='INBOUND';  Target=1 },
    @{ PT='SFTP_PUSH_ED25519'; CM='OUTBOUND'; Target=1 },
    @{ PT='ENCOUNTER';       CM='INBOUND';  Target=1 },
    @{ PT='NOTES';           CM='INBOUND';  Target=1 },
    @{ PT='ITS';             CM='OUTBOUND'; Target=1 },
    @{ PT='NCOA';            CM='INBOUND';  Target=1 }
)

# The canonical inventory from our earlier investigation — 58 PARAMETER_NAMEs
# from CLIENTS_PARAM + the CLIENTS_FILES direct columns + CLIENT_NAME.
# Used to diff against fields observed in XML samples.
$canonicalFields = @(
    # CLIENTS_FILES direct columns
    'CLIENT_ID', 'SEQ_ID', 'ACTIVE_FLAG', 'RUN_FLAG', 'PROCESS_TYPE',
    'COMM_METHOD', 'AUTOMATED', 'FILE_MERGE',
    # CLIENTS_MN
    'CLIENT_NAME',
    # CLIENTS_PARAM (58 distinct, canonical only — typos excluded)
    'ADDRESS_CHECK', 'AUTO_RELEASE', 'BUSINESS_TYPE', 'CLA_EXE_PATH',
    'COMM_CALL', 'COMM_CALL_CLA_EXE_PATH', 'COMM_CALL_SQL_QUERY',
    'COMM_CALL_WORKING_DIR', 'CONVERT_TO_CSV', 'CUSTOM_FILE_FILTER',
    'DM_BATCH_SPLIT', 'DUP_CHECK', 'EMAIL_SUBJECT', 'EMAIL_XSLT',
    'ENCOUNTER_MAP', 'FILE_CLEAN_UP', 'FILE_FILTER', 'FILE_RENAME',
    'GET_DOCS_API', 'GET_DOCS_DLT', 'GET_DOCS_LOC', 'GET_DOCS_PROFILE_ID',
    'GET_DOCS_TYPE', 'MAIL_CC', 'MAIL_TO', 'MISC_REC1', 'PDF_FILE',
    'PGP_PASSPHRASE', 'POST_ARCHIVE', 'POST_TRANS_FILE_RENAME',
    'POST_TRANS_SQL_QUERY', 'POST_TRANSLATION', 'POST_TRANSLATION_MAP',
    'POST_TRANSLATION_OVERWRITE', 'POST_TRANSLATION_VITAL', 'PRE_ARCHIVE',
    'PRE_DM_MERGE', 'PRE_SQL_QUERY', 'PREP_TRANSLATION_MAP',
    'PREPARE_COMM_CALL', 'PREPARE_SOURCE', 'PUT_DOCS_LOC',
    'PUT_DOCS_PROFILE_ID', 'PUT_DOCS_TYPE', 'PV_FN_ADDRESS',
    'SEND_EMPTY_FILES', 'SQL_QUERY', 'SQL_QUERY_DATA_SOURCE',
    'STAGING_CLA_EXE_PATH', 'TRANSLATION_MAP', 'TRANSLATION_STAGING',
    'UNZIP_FILTER', 'WORKERS_COMP'
)

# Known typo PARAMETER_NAMEs (these are expected-but-not-canonical; seeing
# them in XML is not surprising — they're in PARAM, so GET_LIST will pivot
# them into ProcessData as-is)
$knownTypos = @{
    'PRE_ARCHHIVE'    = 'PRE_ARCHIVE'
    'PRE_ARCHVE'      = 'PRE_ARCHIVE'
    'PRE_ARCHIVE3'    = 'PRE_ARCHIVE'
    'CONVERT_T0_CSV'  = 'CONVERT_TO_CSV'
    'SQL QUERY'       = 'SQL_QUERY'
}

# ---------------------- Helper functions ----------------------

function Expand-GzipBytes {
    param([byte[]]$Bytes)
    $ms = New-Object System.IO.MemoryStream(,$Bytes)
    try {
        $gz = New-Object System.IO.Compression.GZipStream($ms, [System.IO.Compression.CompressionMode]::Decompress)
        try {
            $sr = New-Object System.IO.StreamReader($gz)
            try { return $sr.ReadToEnd() } finally { $sr.Dispose() }
        } finally { $gz.Dispose() }
    } finally { $ms.Dispose() }
}

function Invoke-B2BIQuery {
    param([string]$Query)
    Invoke-Sqlcmd `
        -ServerInstance $b2biServer -Database $b2biDatabase `
        -Query $Query -TrustServerCertificate `
        -MaxBinaryLength 20971520 -QueryTimeout 60 `
        -ApplicationName $appName
}

function Invoke-IntegrationQuery {
    param([string]$Query)
    Invoke-Sqlcmd `
        -ServerInstance $integServer -Database $integDatabase `
        -Query $Query -TrustServerCertificate `
        -MaxBinaryLength 20971520 -QueryTimeout 60 `
        -ApplicationName $appName
}

function Get-XmlElementNames {
    # Walks an XmlNode and returns distinct element names found under it
    param([System.Xml.XmlNode]$Node)
    $names = @{}
    if ($null -ne $Node) {
        foreach ($child in $Node.ChildNodes) {
            if ($child.NodeType -eq [System.Xml.XmlNodeType]::Element) {
                $names[$child.Name] = $true
            }
        }
    }
    return $names.Keys
}

# ---------------------- Setup ----------------------

if (-not (Test-Path $outputRoot)) {
    New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
}

Write-Host ""
Write-Host "===================================================================" -ForegroundColor Cyan
Write-Host "  B2B Validation Sampling" -ForegroundColor Cyan
Write-Host "===================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Output directory: $outputRoot" -ForegroundColor Gray
Write-Host "Lookback window: last $lookbackHours hours" -ForegroundColor Gray
Write-Host "Target pairs: $($targetPairs.Count)" -ForegroundColor Gray
Write-Host ""

# ==============================================================================
# STEP 1 — Typo Report for Melissa
# ==============================================================================

Write-Host "[1/3] Building typo report..." -ForegroundColor Yellow

$typoNames = $knownTypos.Keys | ForEach-Object { "'$_'" }
$typoNamesList = $typoNames -join ','

$typoQuery = @"
SELECT 
    p.PARAMETER_NAME,
    p.CLIENT_ID,
    mn.CLIENT_NAME,
    p.SEQ_ID,
    p.PARAMETER_VALUE,
    f.PROCESS_TYPE,
    f.COMM_METHOD,
    f.ACTIVE_FLAG,
    f.AUTOMATED
FROM etl.tbl_B2b_CLIENTS_PARAM p
LEFT JOIN etl.tbl_B2B_CLIENTS_FILES f 
    ON f.CLIENT_ID = p.CLIENT_ID AND f.SEQ_ID = p.SEQ_ID
LEFT JOIN etl.tbl_B2B_CLIENTS_MN mn 
    ON mn.CLIENT_ID = p.CLIENT_ID
WHERE p.PARAMETER_NAME IN ($typoNamesList)
ORDER BY f.ACTIVE_FLAG DESC, p.PARAMETER_NAME, mn.CLIENT_NAME;
"@

$typoRows = Invoke-IntegrationQuery -Query $typoQuery

$typoReport = @"
# B2B CLIENTS_PARAM Typo Report

Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

## Overview

Five PARAMETER_NAME values in `Integration.etl.tbl_B2b_CLIENTS_PARAM` appear
to be typos of standard parameter names. Each is used by one or more
(CLIENT_ID, SEQ_ID) configurations.

**Operational concern:** Sterling's `FA_CLIENTS_MAIN` BPML evaluates rules
against specific parameter names. If a typo'd parameter name (e.g.
``PRE_ARCHHIVE``) is in the configuration, the corresponding rule
(``PreArchive?``, which references ``PRE_ARCHIVE``) will not evaluate true.
This means the intended behavior does not execute. Several of the affected
configurations are ``ACTIVE_FLAG = 1`` and processing live data today.

## Proposed Corrections

| Typo Parameter Name | Correct Name |
|---|---|
"@

foreach ($typo in ($knownTypos.Keys | Sort-Object)) {
    $correct = $knownTypos[$typo]
    $typoReport += "`r`n| ``$typo`` | ``$correct`` |"
}

$typoReport += @"


## Affected Configurations

Active configs (``ACTIVE_FLAG = 1``) are currently in production. Inactive
configs (``ACTIVE_FLAG = 0``) are disabled but remain configured.

| Status | PARAMETER_NAME | Should Be | CLIENT_ID | CLIENT_NAME | SEQ_ID | PROCESS_TYPE | COMM_METHOD | AUTOMATED | Value |
|---|---|---|---|---|---|---|---|---|---|
"@

foreach ($row in $typoRows) {
    $status = if ($row.ACTIVE_FLAG -eq 1) { '**ACTIVE**' } else { 'Inactive' }
    $correct = $knownTypos[[string]$row.PARAMETER_NAME]
    $automated = if ($null -ne $row.AUTOMATED) { [string]$row.AUTOMATED } else { '' }
    $typoReport += "`r`n| $status | ``$($row.PARAMETER_NAME)`` | ``$correct`` | $($row.CLIENT_ID) | $($row.CLIENT_NAME) | $($row.SEQ_ID) | $($row.PROCESS_TYPE) | $($row.COMM_METHOD) | $automated | ``$($row.PARAMETER_VALUE)`` |"
}

$typoReport += @"


## Suggested Fix

Each typo row can be corrected by updating the ``PARAMETER_NAME`` column.
Example SQL (REVIEW CAREFULLY BEFORE RUNNING — fixing these will change
live Sterling behavior for the affected configurations):

``````sql
-- PRE_ARCHIVE typo variants
UPDATE Integration.etl.tbl_B2b_CLIENTS_PARAM
SET PARAMETER_NAME = 'PRE_ARCHIVE'
WHERE PARAMETER_NAME IN ('PRE_ARCHHIVE', 'PRE_ARCHVE', 'PRE_ARCHIVE3');

-- CONVERT_TO_CSV typo (zero vs letter O)
UPDATE Integration.etl.tbl_B2b_CLIENTS_PARAM
SET PARAMETER_NAME = 'CONVERT_TO_CSV'
WHERE PARAMETER_NAME = 'CONVERT_T0_CSV';

-- SQL_QUERY (space vs underscore)
UPDATE Integration.etl.tbl_B2b_CLIENTS_PARAM
SET PARAMETER_NAME = 'SQL_QUERY'
WHERE PARAMETER_NAME = 'SQL QUERY';
``````

**Note:** Fixing these will cause the corresponding MAIN rules to start
firing for the affected configurations on their next run. Please review
whether the current silent no-op behavior is the intended state before
applying.
"@

$typoReportPath = Join-Path $outputRoot 'Typo_Report_for_Melissa.md'
$typoReport | Out-File -FilePath $typoReportPath -Encoding UTF8
Write-Host "  OK - typo report written: $typoReportPath" -ForegroundColor Green
Write-Host "  Affected configs: $($typoRows.Count) ($((@($typoRows | Where-Object { $_.ACTIVE_FLAG -eq 1 })).Count) active)" -ForegroundColor Gray
Write-Host ""

# ==============================================================================
# STEP 2 — Sample Selection
#
# For each target (PROCESS_TYPE, COMM_METHOD) pair, find recent successful
# FA_CLIENTS_MAIN runs. This requires two-stage query:
#
# (a) Get candidate FA_CLIENTS_MAIN WORKFLOW_IDs from b2bi WF_INST_S
# (b) Cross-reference with Integration.BATCH_STATUS to get CLIENT_ID/SEQ_ID,
#     then check PROCESS_TYPE/COMM_METHOD via CLIENTS_FILES
#
# Picking the targeted samples via this path rather than trying to grep the
# ProcessData blob, which would require decompressing each candidate.
# ==============================================================================

Write-Host "[2/3] Selecting samples..." -ForegroundColor Yellow

# Step 2a — get candidate MAIN workflows from b2bi
$candidateQuery = @"
SELECT wis.WORKFLOW_ID, wis.START_TIME, wis.STATUS, wis.STATE
FROM dbo.WF_INST_S wis
INNER JOIN dbo.WFD wfd 
    ON wfd.WFD_ID = wis.WFD_ID AND wfd.WFD_VERSION = wis.WFD_VERSION
WHERE wfd.NAME = 'FA_CLIENTS_MAIN'
  AND wis.START_TIME >= DATEADD(HOUR, -$lookbackHours, GETDATE())
  AND wis.STATUS = 0  -- successful only, for cleaner ProcessData
ORDER BY wis.START_TIME DESC;
"@

Write-Host "  Querying b2bi for recent FA_CLIENTS_MAIN candidates..." -ForegroundColor Gray
$candidates = Invoke-B2BIQuery -Query $candidateQuery
$candidatesArr = @($candidates)
Write-Host "  Found $($candidatesArr.Count) successful MAIN runs in last $lookbackHours hours" -ForegroundColor Gray

if ($candidatesArr.Count -eq 0) {
    Write-Host "  ERROR: No MAIN runs found in lookback window. Aborting." -ForegroundColor Red
    exit 1
}

# Step 2b — enrich candidates with PROCESS_TYPE/COMM_METHOD via BATCH_STATUS + CLIENTS_FILES
$candidateIds = ($candidatesArr.WORKFLOW_ID | ForEach-Object { [int64]$_ }) -join ','

$enrichmentQuery = @"
SELECT bs.RUN_ID AS WORKFLOW_ID, bs.CLIENT_ID, bs.SEQ_ID, 
       f.PROCESS_TYPE, f.COMM_METHOD
FROM ETL.tbl_B2B_CLIENTS_BATCH_STATUS bs
INNER JOIN etl.tbl_B2B_CLIENTS_FILES f 
    ON f.CLIENT_ID = bs.CLIENT_ID AND f.SEQ_ID = bs.SEQ_ID
WHERE bs.RUN_ID IN ($candidateIds);
"@

Write-Host "  Enriching with Integration BATCH_STATUS for PROCESS_TYPE/COMM_METHOD..." -ForegroundColor Gray
$enrichment = Invoke-IntegrationQuery -Query $enrichmentQuery
$enrichmentArr = @($enrichment)
Write-Host "  Matched $($enrichmentArr.Count) candidates to Integration configs" -ForegroundColor Gray

# Build lookup: workflow_id -> (process_type, comm_method, client_id, seq_id)
$wfMeta = @{}
foreach ($row in $enrichmentArr) {
    $wfMeta[[int64]$row.WORKFLOW_ID] = $row
}

# Select samples per target pair
$selectedSamples = @()
$missingPairs = @()

foreach ($target in $targetPairs) {
    $pt = $target.PT
    $cm = $target.CM
    $want = $target.Target

    $matches = @($enrichmentArr | Where-Object {
        $_.PROCESS_TYPE -eq $pt -and $_.COMM_METHOD -eq $cm
    })

    if ($matches.Count -eq 0) {
        $missingPairs += "$pt / $cm"
        continue
    }

    # Spread across distinct clients if possible
    $clientsSeen = @{}
    $picked = 0
    foreach ($m in $matches) {
        if ($picked -ge $want) { break }
        $cid = [int64]$m.CLIENT_ID
        if ($clientsSeen.ContainsKey($cid)) { continue }
        $clientsSeen[$cid] = $true
        $selectedSamples += $m
        $picked++
    }
    # Fill remainder if we didn't get enough distinct-client samples
    if ($picked -lt $want) {
        foreach ($m in $matches) {
            if ($picked -ge $want) { break }
            if ($selectedSamples -contains $m) { continue }
            $selectedSamples += $m
            $picked++
        }
    }
}

Write-Host "  Selected $($selectedSamples.Count) samples across $($targetPairs.Count - $missingPairs.Count)/$($targetPairs.Count) target pairs" -ForegroundColor Gray
if ($missingPairs.Count -gt 0) {
    Write-Host "  No samples found for:" -ForegroundColor DarkYellow
    foreach ($mp in $missingPairs) {
        Write-Host "    - $mp" -ForegroundColor DarkYellow
    }
}
Write-Host ""

# ==============================================================================
# STEP 3 — ProcessData decompression + field analysis
# ==============================================================================

Write-Host "[3/3] Decompressing and analyzing ProcessData..." -ForegroundColor Yellow

$allObservedFields = @{}    # fieldName -> hashtable of (pt/cm -> count)
$allObservedSettings = @{}  # settingName -> count
$sampleDetails = @()        # per-sample record of fields seen
$sampleErrors = @()

foreach ($sample in $selectedSamples) {
    $wfId = [int64]$sample.WORKFLOW_ID
    $pt = $sample.PROCESS_TYPE
    $cm = $sample.COMM_METHOD
    $cid = $sample.CLIENT_ID
    $sid = $sample.SEQ_ID

    $pairKey = "$pt/$cm"

    Write-Host "  WF $wfId ($pairKey) client=$cid seq=$sid..." -NoNewline -ForegroundColor DarkGray

    # Pull ProcessData
    $pdQuery = @"
SELECT TOP 1 DATA_ID, DATA_OBJECT
FROM dbo.TRANS_DATA
WHERE WF_ID = $wfId
  AND REFERENCE_TABLE = 'DOCUMENT'
  AND PAGE_INDEX = 0
ORDER BY CREATION_DATE ASC, DATA_ID ASC;
"@

    try {
        $pdRow = Invoke-B2BIQuery -Query $pdQuery
        if (-not $pdRow -or -not $pdRow.DATA_OBJECT) {
            Write-Host " no ProcessData" -ForegroundColor Yellow
            $sampleErrors += "WF $wfId ($pairKey) - no ProcessData found"
            continue
        }

        $bytes = [byte[]]$pdRow.DATA_OBJECT
        $xmlText = Expand-GzipBytes -Bytes $bytes

        # Write raw XML to disk
        $pairDir = Join-Path $outputRoot ($pt + '_' + $cm)
        if (-not (Test-Path $pairDir)) {
            New-Item -ItemType Directory -Path $pairDir -Force | Out-Null
        }
        $xmlPath = Join-Path $pairDir "WF_$wfId.xml"
        $xmlText | Out-File -FilePath $xmlPath -Encoding UTF8

        # Parse
        $xml = [xml]$xmlText

        # Field names under //Result/Client[1]
        $clientNode = $xml.SelectSingleNode('//Result/Client[1]')
        $clientFields = @()
        if ($null -ne $clientNode) {
            $clientFields = @(Get-XmlElementNames -Node $clientNode)
        }

        # Field names under //Settings/Values
        $settingsNode = $xml.SelectSingleNode('//Settings/Values')
        $settingsFields = @()
        if ($null -ne $settingsNode) {
            $settingsFields = @(Get-XmlElementNames -Node $settingsNode)
        }

        foreach ($f in $clientFields) {
            if (-not $allObservedFields.ContainsKey($f)) {
                $allObservedFields[$f] = @{}
            }
            if (-not $allObservedFields[$f].ContainsKey($pairKey)) {
                $allObservedFields[$f][$pairKey] = 0
            }
            $allObservedFields[$f][$pairKey]++
        }
        foreach ($s in $settingsFields) {
            if (-not $allObservedSettings.ContainsKey($s)) {
                $allObservedSettings[$s] = 0
            }
            $allObservedSettings[$s]++
        }

        $sampleDetails += [PSCustomObject]@{
            WorkflowId    = $wfId
            ProcessType   = $pt
            CommMethod    = $cm
            ClientId      = $cid
            SeqId         = $sid
            XmlLength     = $xmlText.Length
            ClientFields  = @($clientFields).Count
            SettingsFields= @($settingsFields).Count
            XmlPath       = $xmlPath
        }

        Write-Host " OK ($($xmlText.Length)b, $($clientFields.Count) client fields)" -ForegroundColor Green
    }
    catch {
        Write-Host " ERROR: $($_.Exception.Message)" -ForegroundColor Red
        $sampleErrors += "WF $wfId ($pairKey) - $($_.Exception.Message)"
    }
}

# ==============================================================================
# Analysis — diff observed vs canonical
# ==============================================================================

$canonicalSet = @{}
foreach ($f in $canonicalFields) { $canonicalSet[$f] = $true }

$observedClientFieldNames = @($allObservedFields.Keys)
$fieldsInXmlNotInInventory = @($observedClientFieldNames | Where-Object { -not $canonicalSet.ContainsKey($_) -and -not $knownTypos.ContainsKey($_) })
$fieldsInInventoryNotInXml = @($canonicalFields | Where-Object { -not $allObservedFields.ContainsKey($_) })
$typosObservedInXml = @($observedClientFieldNames | Where-Object { $knownTypos.ContainsKey($_) })

# ==============================================================================
# Write validation report
# ==============================================================================

Write-Host ""
Write-Host "Building validation report..." -ForegroundColor Yellow

$validationReport = @"
# B2B Field Inventory Validation Report

Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Samples analyzed: $($sampleDetails.Count) of $($selectedSamples.Count) selected
Lookback window: last $lookbackHours hours

## Summary

| Metric | Count |
|---|---:|
| Target pairs | $($targetPairs.Count) |
| Pairs with samples | $($targetPairs.Count - $missingPairs.Count) |
| Pairs without samples | $($missingPairs.Count) |
| Total samples analyzed | $($sampleDetails.Count) |
| Sample errors | $($sampleErrors.Count) |
| Distinct Client fields observed in XML | $($observedClientFieldNames.Count) |
| Distinct Settings fields observed in XML | $($allObservedSettings.Count) |
| Fields in XML NOT in inventory | **$($fieldsInXmlNotInInventory.Count)** |
| Fields in inventory NOT observed in samples | $($fieldsInInventoryNotInXml.Count) |
| Typo field names observed in XML | **$($typosObservedInXml.Count)** |

## Fields in XML NOT in CLIENTS_PARAM Inventory

These are fields that appeared in at least one ProcessData XML sample but are
not in our canonical inventory. Candidates: SP-computed fields, fields we missed
in the inventory query, or brand-new fields. **Review these carefully** — they
may indicate columns we need to add to SI_ExecutionTracking.

"@

if ($fieldsInXmlNotInInventory.Count -eq 0) {
    $validationReport += "*(None — our 58-parameter inventory fully covers what's appearing in ProcessData XML.)*`r`n"
}
else {
    $validationReport += "| Field Name | Process Types Where Seen |`r`n"
    $validationReport += "|---|---|`r`n"
    foreach ($f in ($fieldsInXmlNotInInventory | Sort-Object)) {
        $pairs = ($allObservedFields[$f].Keys | Sort-Object) -join ', '
        $validationReport += "| ``$f`` | $pairs |`r`n"
    }
}

$validationReport += @"

## Typo Fields Observed in XML

If any of our known typos show up here, it confirms Sterling's GET_LIST SP is
pivoting them into ProcessData as-is (which makes the operational issue
concrete — MAIN's rules won't evaluate them).

"@

if ($typosObservedInXml.Count -eq 0) {
    $validationReport += "*(None observed in sampled runs — typo'd configs may not have fired during the lookback window.)*`r`n"
}
else {
    $validationReport += "| Typo Field | Should Be | Seen In |`r`n"
    $validationReport += "|---|---|---|`r`n"
    foreach ($t in ($typosObservedInXml | Sort-Object)) {
        $pairs = ($allObservedFields[$t].Keys | Sort-Object) -join ', '
        $validationReport += "| ``$t`` | ``$($knownTypos[$t])`` | $pairs |`r`n"
    }
}

$validationReport += @"

## Inventory Coverage — Fields Not Observed

Inventory fields that did NOT appear in any sampled XML. These may simply be
configured on process types we didn't sample; not necessarily a problem.

"@

if ($fieldsInInventoryNotInXml.Count -eq 0) {
    $validationReport += "*(Every inventory field appeared in at least one sample.)*`r`n"
}
else {
    $validationReport += "| Field Name |`r`n"
    $validationReport += "|---|`r`n"
    foreach ($f in ($fieldsInInventoryNotInXml | Sort-Object)) {
        $validationReport += "| ``$f`` |`r`n"
    }
}

$validationReport += @"

## Observed Client Fields (Full Catalog Seen Across All Samples)

All distinct field names seen under ``<Client>`` in the sampled ProcessData
XMLs, with the process types where each appeared.

| Field Name | Total Samples | Process Types |
|---|---:|---|
"@

foreach ($f in ($observedClientFieldNames | Sort-Object)) {
    $total = 0
    foreach ($c in $allObservedFields[$f].Values) { $total += $c }
    $pairs = ($allObservedFields[$f].Keys | Sort-Object) -join ', '
    $validationReport += "`r`n| ``$f`` | $total | $pairs |"
}

$validationReport += @"


## Observed Settings Fields (Full Catalog)

All distinct field names seen under ``<Settings>/<Values>`` in the sampled
ProcessData XMLs.

| Setting Name | Sample Count |
|---|---:|
"@

foreach ($s in ($allObservedSettings.Keys | Sort-Object)) {
    $validationReport += "`r`n| ``$s`` | $($allObservedSettings[$s]) |"
}

$validationReport += @"


## Per-Sample Detail

| Workflow ID | Process Type | Comm Method | Client ID | Seq ID | XML Bytes | Client Fields | Settings Fields |
|---|---|---|---:|---:|---:|---:|---:|
"@

foreach ($s in $sampleDetails) {
    $validationReport += "`r`n| $($s.WorkflowId) | $($s.ProcessType) | $($s.CommMethod) | $($s.ClientId) | $($s.SeqId) | $($s.XmlLength) | $($s.ClientFields) | $($s.SettingsFields) |"
}

if ($missingPairs.Count -gt 0) {
    $validationReport += @"


## Missing Pair Coverage

The following target (PROCESS_TYPE, COMM_METHOD) pairs had no matching runs
in the last $lookbackHours hours. This is expected for rare process types;
the raw ``process_data_xml`` column in SI_ExecutionTracking will capture any
novel fields when these types do run.

"@
    foreach ($mp in ($missingPairs | Sort-Object)) {
        $validationReport += "- $mp`r`n"
    }
}

if ($sampleErrors.Count -gt 0) {
    $validationReport += @"


## Sample Errors

"@
    foreach ($err in $sampleErrors) {
        $validationReport += "- $err`r`n"
    }
}

$validationReportPath = Join-Path $outputRoot 'Field_Inventory_Validation.md'
$validationReport | Out-File -FilePath $validationReportPath -Encoding UTF8

Write-Host "  OK - validation report written: $validationReportPath" -ForegroundColor Green
Write-Host ""
Write-Host "===================================================================" -ForegroundColor Cyan
Write-Host "  Done." -ForegroundColor Cyan
Write-Host "===================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Files produced:" -ForegroundColor Yellow
Write-Host "  Typo report:       $typoReportPath" -ForegroundColor Gray
Write-Host "  Validation report: $validationReportPath" -ForegroundColor Gray
Write-Host "  Raw XML samples:   $outputRoot\<PROCESS_TYPE>_<COMM_METHOD>\WF_*.xml" -ForegroundColor Gray
Write-Host ""
Write-Host "Next: review validation report; key sections are 'Fields in XML NOT in" -ForegroundColor Yellow
Write-Host "CLIENTS_PARAM Inventory' and 'Typo Fields Observed in XML'." -ForegroundColor Yellow
Write-Host ""
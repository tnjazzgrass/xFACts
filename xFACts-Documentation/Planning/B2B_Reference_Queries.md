# B2B Reference Queries

## Purpose of This Document

Standalone companion reference for the B2B module investigation. Collects validated queries and code snippets used repeatedly during Sterling b2bi investigation and collector development.

This is a working reference for Dirk and Claude while the module is being built. Not intended as permanent documentation. Queries here may be used directly or adapted; comments note what they're for and what to substitute.

**Companion documents:**
- `B2B_Module_Planning.md` — roadmap and phase plan
- `B2B_ArchitectureOverview.md` — architectural reference
- `B2B_ProcessAnatomy_*.md` — per-process-type specifics

---

## b2bi — Core Investigation Queries

### Recent Workflow Runs (With Workflow Names)

Lists the 20 most recently started workflows. Useful for "what's been running lately."

```sql
SELECT TOP 20 
    wis.WORKFLOW_ID,
    wis.WFD_ID,
    wis.WFD_VERSION,
    wfd.NAME AS workflow_name,
    wis.START_TIME,
    wis.END_TIME,
    wis.STATUS,
    wis.STATE
FROM b2bi.dbo.WF_INST_S wis
INNER JOIN b2bi.dbo.WFD wfd 
    ON wfd.WFD_ID = wis.WFD_ID 
    AND wfd.WFD_VERSION = wis.WFD_VERSION
WHERE wis.START_TIME >= DATEADD(MINUTE, -30, GETDATE())
ORDER BY wis.START_TIME DESC;
```

### Sub-Workflow Invocation Markers for a Specific Run

Shows which business-level sub-workflows were invoked inside a given MAIN run. Key query for understanding what actually executed.

```sql
-- Replace @WFID with the target WORKFLOW_ID
SELECT STEP_ID, SERVICE_NAME, ADV_STATUS, START_TIME
FROM b2bi.dbo.WORKFLOW_CONTEXT
WHERE WORKFLOW_ID = @WFID
  AND ADV_STATUS LIKE '%Inline Begin%'
ORDER BY STEP_ID;
```

### ProcessData Lookup Pattern

Finds the ProcessData document for a given MAIN run. Step 0 gets the earliest document; ProcessData is reliably the first TRANS_DATA row created (typically within ~10ms of Step 0).

```sql
-- Replace @WFID with the target WORKFLOW_ID
SELECT TOP 1 DATA_ID, DATALENGTH(DATA_OBJECT) AS BYTES, CREATION_DATE
FROM b2bi.dbo.TRANS_DATA
WHERE WF_ID = @WFID
  AND REFERENCE_TABLE = 'DOCUMENT'
  AND PAGE_INDEX = 0
ORDER BY CREATION_DATE ASC, DATA_ID ASC;
```

### Active Schedules for a Specific Entity

Adjust the LIKE pattern to filter by entity name.

```sql
SELECT SCHEDULEID, SERVICENAME, STATUS, TIMINGXML
FROM b2bi.dbo.SCHEDULE
WHERE SERVICENAME LIKE '%LIFESPAN%'
  AND STATUS = 'ACTIVE'
ORDER BY SERVICENAME;
```

### Recent Failures at the MAIN (Step 0) Level

High-level failure scan — shows workflow-level failure indicators.

```sql
SELECT WORKFLOW_ID, SERVICE_NAME, START_TIME, BASIC_STATUS, ADV_STATUS
FROM b2bi.dbo.WORKFLOW_CONTEXT
WHERE BASIC_STATUS NOT IN (0, 10) 
  AND STEP_ID = 0
  AND START_TIME >= DATEADD(HOUR, -24, GETDATE())
ORDER BY START_TIME DESC;
```

### Step-Level Failure Detail for a Specific Run

For a known-failed WORKFLOW_ID, finds the exact step where the failure occurred with its diagnostic status text.

```sql
-- Replace @WFID with the target WORKFLOW_ID
SELECT STEP_ID, SERVICE_NAME, BASIC_STATUS, ADV_STATUS, START_TIME, END_TIME
FROM b2bi.dbo.WORKFLOW_CONTEXT
WHERE WORKFLOW_ID = @WFID
  AND BASIC_STATUS > 0
ORDER BY STEP_ID;
```

### WORKFLOW_LINKAGE Walk — Parent/Child Resolution

Shows the full child workflow tree spawned from a given root MAIN run. Useful for understanding dispatch pattern behavior.

```sql
-- Replace @ROOTWFID with the root WORKFLOW_ID
SELECT ROOT_WF_ID, P_WF_ID, C_WF_ID, TYPE
FROM b2bi.dbo.WORKFLOW_LINKAGE
WHERE ROOT_WF_ID = @ROOTWFID
ORDER BY C_WF_ID;
```

### Workflow Name Resolution from WF_ID

Joins WF_INST_S → WFD to resolve a WORKFLOW_ID to its human-readable name and version.

```sql
-- Replace @WFID with the target WORKFLOW_ID
SELECT wis.WORKFLOW_ID, wfd.NAME, wis.WFD_ID, wis.WFD_VERSION,
       wis.START_TIME, wis.END_TIME, wis.STATUS, wis.STATE
FROM b2bi.dbo.WF_INST_S wis
INNER JOIN b2bi.dbo.WFD wfd 
    ON wfd.WFD_ID = wis.WFD_ID 
    AND wfd.WFD_VERSION = wis.WFD_VERSION
WHERE wis.WORKFLOW_ID = @WFID;
```

---

## b2bi — BPML Extraction

Pattern for extracting a workflow's BPML definition from b2bi. Useful for understanding what a workflow actually does at the source level rather than inferring from execution traces. **Added April 20, 2026** based on lesson learned: for declaratively-defined systems like Sterling, reading the source definition first is more efficient than reverse-engineering from observed behavior.

### Step 1 — Find WFD_ID and Active Version

```sql
-- Replace the workflow name with your target
SELECT 
    wv.WFD_ID,
    wv.WFD_NAME,
    wv.DEFAULT_VERSION,
    wx.XML AS data_handle
FROM b2bi.dbo.WFD_VERSIONS wv
INNER JOIN b2bi.dbo.WFD_XML wx 
    ON wx.WFD_ID = wv.WFD_ID 
    AND wx.WFD_VERSION = wv.DEFAULT_VERSION
WHERE wv.WFD_NAME = 'FA_CLIENTS_MAIN';
```

`DEFAULT_VERSION` is the currently-active version. `XML` is the handle pointing into `DATA_TABLE.DATA_ID`. Note: b2bi collation is case-sensitive; workflow name must match exactly.

### Step 2 — List All Versions of a Workflow (Historical Changes)

```sql
-- See editing history — useful for understanding what's changed and when
SELECT WFD_VERSION, NAME, DESCRIPTION, EDITED_BY, MOD_DATE, STATUS
FROM b2bi.dbo.WFD
WHERE WFD_ID = 798
ORDER BY WFD_VERSION DESC;
```

The `DESCRIPTION` column often contains changelog-style entries from editors.

### Step 3 — Fetch and Decompress BPML (PowerShell)

```powershell
# Replace the handle with the XML value from Step 1
$dataHandle = 'FA-INT-APPP:node1:19ced66940d:69125333'

$query = @"
SELECT DATA_OBJECT, DATALENGTH(DATA_OBJECT) AS byte_size
FROM b2bi.dbo.DATA_TABLE
WHERE DATA_ID = '$dataHandle';
"@

$row = Invoke-Sqlcmd `
    -ServerInstance 'FA-INT-DBP' `
    -Database 'b2bi' `
    -Query $query `
    -TrustServerCertificate `
    -MaxBinaryLength 20971520 `
    -ApplicationName 'xFACts-B2BInvestigation'

# Decompress gzip bytes (same pattern as ProcessData, TIMINGXML)
$bytes = [byte[]]$row.DATA_OBJECT
$ms = New-Object System.IO.MemoryStream(,$bytes)
$gz = New-Object System.IO.Compression.GZipStream($ms, [System.IO.Compression.CompressionMode]::Decompress)
$sr = New-Object System.IO.StreamReader($gz)
$bpmlText = $sr.ReadToEnd()
$sr.Dispose(); $gz.Dispose(); $ms.Dispose()

Write-Host "Decompressed: $($bpmlText.Length) characters"

# Save for offline review
$outPath = Join-Path $env:TEMP "WorkflowName_BPML.xml"
$bpmlText | Out-File -FilePath $outPath -Encoding UTF8
```

**Notes:**
- `-MaxBinaryLength 20971520` (20MB) is required for the blob; defaults are too small
- Decompression pattern is identical to ProcessData and TIMINGXML — Sterling stores all its compressed XML the same way
- BPMLs for FA_CLIENTS_* workflows range from ~850 bytes (thin dispatcher wrappers) to ~50 KB (FA_CLIENTS_MAIN). None observed beyond 100 KB.

### Batch Extraction for Multiple BPMLs

```powershell
# Pass an array of workflow names to extract multiple BPMLs in one run
$targets = @(
    'FA_CLIENTS_MAIN',
    'FA_CLIENTS_GET_LIST',
    'FA_CLIENTS_GET_DOCS'
)

$handleQuery = @"
SELECT wv.WFD_NAME, wx.XML AS data_handle
FROM b2bi.dbo.WFD_VERSIONS wv
INNER JOIN b2bi.dbo.WFD_XML wx 
    ON wx.WFD_ID = wv.WFD_ID 
    AND wx.WFD_VERSION = wv.DEFAULT_VERSION
WHERE wv.WFD_NAME IN ('$($targets -join "','")');
"@

$handles = Invoke-Sqlcmd `
    -ServerInstance 'FA-INT-DBP' -Database 'b2bi' `
    -Query $handleQuery -TrustServerCertificate `
    -ApplicationName 'xFACts-B2BInvestigation'

foreach ($h in $handles) {
    $blobQuery = "SELECT DATA_OBJECT FROM b2bi.dbo.DATA_TABLE WHERE DATA_ID = '$($h.data_handle)';"
    $row = Invoke-Sqlcmd -ServerInstance 'FA-INT-DBP' -Database 'b2bi' `
        -Query $blobQuery -TrustServerCertificate -MaxBinaryLength 20971520 `
        -ApplicationName 'xFACts-B2BInvestigation'
    
    $bytes = [byte[]]$row.DATA_OBJECT
    $ms = New-Object System.IO.MemoryStream(,$bytes)
    $gz = New-Object System.IO.Compression.GZipStream($ms, [System.IO.Compression.CompressionMode]::Decompress)
    $sr = New-Object System.IO.StreamReader($gz)
    $text = $sr.ReadToEnd()
    $sr.Dispose(); $gz.Dispose(); $ms.Dispose()
    
    $outPath = Join-Path $env:TEMP "$($h.WFD_NAME)_BPML.xml"
    $text | Out-File -FilePath $outPath -Encoding UTF8
    Write-Host "$($h.WFD_NAME): $($text.Length) chars -> $outPath"
}
```

---

## Integration — Stored Procedure Source Reading

For reading the source of Integration-side stored procedures that Sterling workflows invoke. Useful for understanding what dispatcher logic is actually doing without requiring ad-hoc trace interpretation. **Added April 20, 2026.**

```sql
-- Read a stored procedure's definition (two equivalent patterns)
SELECT OBJECT_DEFINITION(OBJECT_ID('FAINT.USP_B2B_CLIENTS_GET_LIST'));

-- Or via sys.sql_modules for a cleaner structured result
SELECT sm.definition
FROM sys.sql_modules sm
INNER JOIN sys.objects o ON o.object_id = sm.object_id
WHERE o.name = 'USP_B2B_CLIENTS_GET_LIST'
  AND SCHEMA_NAME(o.schema_id) = 'FAINT';
```

Copy the definition out for analysis. **Integration SPs observed and analyzed so far:**
- `FAINT.USP_B2B_CLIENTS_GET_LIST` — dispatcher list assembly (two-branch logic based on AUTOMATED field)
- `FAINT.USP_B2B_CLIENTS_GET_SETTINGS` — global settings pivot into single-row result

Additional SPs we've seen referenced but not yet read:
- Any `USP_*` invoked via `POST_TRANS_SQL_QUERY` in Pattern 3 Internal Operations

---

## b2bi — Baseline Fingerprint Query (Phase 1 Approach)

Retained as reference. The Phase 1 activity-detection baseline approach — still useful for anomaly detection even as ProcessData becomes the primary execution record source.

```sql
;WITH ProcessRuns AS (
    SELECT 
        wc.SERVICE_NAME,
        wc.WORKFLOW_ID,
        child.child_count,
        child.total_child_steps
    FROM b2bi.dbo.WORKFLOW_CONTEXT wc
    OUTER APPLY (
        SELECT 
            COUNT(*) AS child_count,
            ISNULL(SUM(sub.step_count), 0) AS total_child_steps
        FROM b2bi.dbo.WORKFLOW_LINKAGE wl
        OUTER APPLY (
            SELECT COUNT(*) AS step_count
            FROM b2bi.dbo.WORKFLOW_CONTEXT s
            WHERE s.WORKFLOW_ID = wl.C_WF_ID AND s.STEP_ID > 0
        ) sub
        WHERE wl.ROOT_WF_ID = wc.WORKFLOW_ID
    ) child
    WHERE wc.STEP_ID = 0
      AND wc.SERVICE_NAME LIKE 'Scheduler_FA_%'
      AND wc.START_TIME >= DATEADD(DAY, -2, GETDATE())
      AND child.child_count > 0
),
RunCounts AS (
    SELECT SERVICE_NAME, child_count, total_child_steps,
           COUNT(*) AS execution_count
    FROM ProcessRuns
    GROUP BY SERVICE_NAME, child_count, total_child_steps
),
RankedBaselines AS (
    SELECT SERVICE_NAME, child_count, total_child_steps, execution_count,
           ROW_NUMBER() OVER (PARTITION BY SERVICE_NAME ORDER BY execution_count DESC) AS rn
    FROM RunCounts
)
SELECT rb.SERVICE_NAME, rb.child_count AS baseline_child_count,
       rb.total_child_steps AS baseline_total_steps,
       rb.execution_count AS baseline_occurrences,
       agg.total_executions,
       agg.total_executions - rb.execution_count AS deviated_executions,
       agg.max_child_steps AS max_observed_steps
FROM RankedBaselines rb
CROSS APPLY (
    SELECT COUNT(*) AS total_executions, MAX(total_child_steps) AS max_child_steps
    FROM ProcessRuns pr WHERE pr.SERVICE_NAME = rb.SERVICE_NAME
) agg
WHERE rb.rn = 1
ORDER BY deviated_executions DESC, rb.SERVICE_NAME;
```

---

## b2bi — MAIN Run Classification Queries

### Find Recent MAIN Runs

Filters by WFD.NAME = 'FA_CLIENTS_MAIN' to isolate the universal grain from all other workflow types.

```sql
SELECT wis.WORKFLOW_ID, wis.START_TIME, wis.END_TIME,
       wis.STATUS, wis.STATE
FROM b2bi.dbo.WF_INST_S wis
INNER JOIN b2bi.dbo.WFD wfd 
    ON wfd.WFD_ID = wis.WFD_ID AND wfd.WFD_VERSION = wis.WFD_VERSION
WHERE wfd.NAME = 'FA_CLIENTS_MAIN'
  AND wis.START_TIME >= DATEADD(HOUR, -2, GETDATE())
ORDER BY wis.START_TIME DESC;
```

### Step-Count Distribution for MAIN (Rule Evaluation Proxy)

Rough classifier of MAIN runs by total step count. Since MAIN is a single linear sequence where most steps come from conditional sub-workflow invocations, step count correlates with "how much configuration triggered rules to evaluate true."

```sql
WITH MainRuns AS (
    SELECT wis.WORKFLOW_ID,
           (SELECT COUNT(*) FROM b2bi.dbo.WORKFLOW_CONTEXT wc 
            WHERE wc.WORKFLOW_ID = wis.WORKFLOW_ID) AS step_count
    FROM b2bi.dbo.WF_INST_S wis
    INNER JOIN b2bi.dbo.WFD wfd 
        ON wfd.WFD_ID = wis.WFD_ID AND wfd.WFD_VERSION = wis.WFD_VERSION
    WHERE wfd.NAME = 'FA_CLIENTS_MAIN'
      AND wis.START_TIME >= DATEADD(HOUR, -24, GETDATE())
)
SELECT 
    CASE 
        WHEN step_count < 30 THEN '< 30 (likely short-circuit due to PREV_SEQ failure)'
        WHEN step_count < 60 THEN '30-60 (SP executor or minimal process)'
        WHEN step_count < 150 THEN '60-150 (small file process)'
        WHEN step_count < 500 THEN '150-500 (moderate file process)'
        ELSE '500+ (heavy file process or cleanup)'
    END AS step_bucket,
    COUNT(*) AS run_count
FROM MainRuns
GROUP BY CASE 
    WHEN step_count < 30 THEN '< 30 (likely short-circuit due to PREV_SEQ failure)'
    WHEN step_count < 60 THEN '30-60 (SP executor or minimal process)'
    WHEN step_count < 150 THEN '60-150 (small file process)'
    WHEN step_count < 500 THEN '150-500 (moderate file process)'
    ELSE '500+ (heavy file process or cleanup)'
END
ORDER BY MIN(step_count);
```

### Sub-Workflow Invocation Count for One Run

For a given MAIN run, counts how many times each sub-workflow was invoked. Central to understanding what actually happened during a specific run.

```sql
-- Replace @WFID with the target WORKFLOW_ID
SELECT 
    SUBSTRING(
        ADV_STATUS, 
        CHARINDEX('Inline Begin ', ADV_STATUS) + 13,
        CHARINDEX('+', ADV_STATUS, CHARINDEX('Inline Begin ', ADV_STATUS)) 
            - CHARINDEX('Inline Begin ', ADV_STATUS) - 13
    ) AS sub_workflow_name,
    COUNT(*) AS invocation_count
FROM b2bi.dbo.WORKFLOW_CONTEXT
WHERE WORKFLOW_ID = @WFID
  AND ADV_STATUS LIKE '%Inline Begin%'
GROUP BY 
    SUBSTRING(
        ADV_STATUS, 
        CHARINDEX('Inline Begin ', ADV_STATUS) + 13,
        CHARINDEX('+', ADV_STATUS, CHARINDEX('Inline Begin ', ADV_STATUS)) 
            - CHARINDEX('Inline Begin ', ADV_STATUS) - 13
    )
ORDER BY invocation_count DESC;
```

---

## Integration — Coordination Layer Queries

These queries target the Integration-side tables that Sterling workflows write to during execution. Useful for cross-referencing with b2bi observations or as an enrichment source for the collector. **Added April 20, 2026.**

**Important:** Integration is on AVG-PROD-LSNR; b2bi is on FA-INT-DBP. No linked server. These queries run against the Integration database directly.

**Source of truth reminder:** `tbl_B2B_CLIENTS_BATCH_STATUS` and `tbl_B2B_CLIENTS_TICKETS` are a convenience layer populated by Sterling BPMLs. They reflect "what Sterling workflows successfully reported" — not necessarily what actually happened. For authoritative execution state, use b2bi (`WF_INST_S`, `WORKFLOW_CONTEXT`). See architecture doc's "Source of Truth Stance" section.

### BATCH_STATUS for a Specific Sterling Workflow

Cross-references a b2bi WORKFLOW_ID (as RUN_ID in BATCH_STATUS) with the Integration-side state machine row.

```sql
-- Replace @WFID with the target WORKFLOW_ID from b2bi
SELECT CLIENT_ID, SEQ_ID, RUN_ID, PARENT_ID, BATCH_STATUS, FINISH_DATE
FROM Integration.ETL.tbl_B2B_CLIENTS_BATCH_STATUS
WHERE RUN_ID = @WFID;
```

**BATCH_STATUS value reference:**

| Value | Meaning |
|-------|---------|
| `-2` | Failed (legacy; converted to `-1` by polling SELECT) |
| `-1` | Failed |
| `0`, `1` | In progress (polled by MAIN's Wait? rule) |
| `2` | Done — dispatcher OR BDL OR NB/PAY with files |
| `3` | Done — non-NB/PAY file process with files processed |
| `4` | Done — no files, no duplicate |
| `5` | Done — duplicate file detected |

### TICKETS (Failures) for Recent Activity

```sql
-- Failure log — adjust column names if schema differs
SELECT TOP 100 *
FROM Integration.ETL.tbl_B2B_CLIENTS_TICKETS
ORDER BY TICKET_CREATED DESC;
```

Known ticket types:
- `'MAP ERROR'` — written by `FA_CLIENTS_MAIN`'s onFault handler
- `'CLIENTS GET LIST'` — written by `FA_CLIENTS_GET_LIST`'s onFault handler
- Others may exist from workflows not yet read

**Ticket-writing gaps:** Not every workflow writes to TICKETS on fault. `FA_CLIENTS_ETL_CALL` sets `BATCH_STATUS = -1` on fault but does NOT insert a TICKETS row. So ticket absence isn't definitive evidence of success for all workflow types.

### BATCH_FILES (File-Level Audit) for a Specific Run

```sql
-- Replace @WFID with the target WORKFLOW_ID from b2bi
-- Note: BATCH_FILES only records zero-size skipped files and FILE_DELETION operations.
-- Normal file pickups are NOT logged here.
SELECT CLIENT_ID, SEQ_ID, RUN_ID, FILE_NAME, FILE_SIZE, COMM_METHOD
FROM Integration.ETL.tbl_B2B_CLIENTS_BATCH_FILES
WHERE RUN_ID = @WFID;
```

### BATCH_FILES — FILE_DELETION Activity Summary

```sql
-- For a given time window, see which FILE_DELETION runs touched which files.
-- RUN_IDs here correlate with b2bi WORKFLOW_IDs — join on b2bi side for details.
SELECT bf.RUN_ID, bf.CLIENT_ID, bf.SEQ_ID, 
       COUNT(*) AS files_processed,
       MIN(bf.FILE_NAME) AS sample_filename
FROM Integration.ETL.tbl_B2B_CLIENTS_BATCH_FILES bf
WHERE /* adjust to actual timestamp column */
GROUP BY bf.RUN_ID, bf.CLIENT_ID, bf.SEQ_ID
ORDER BY files_processed DESC;
```

### Cross-Server Enrichment Pattern (For Collector)

This is the PowerShell pattern the B2B collector will use. Two separate queries (one per server), joined in memory. Demonstrates the "b2bi primary, Integration enrichment" architecture.

```powershell
# Query 1: b2bi for recent MAIN runs (the authoritative source)
$b2biQuery = @"
SELECT wis.WORKFLOW_ID, wis.START_TIME, wis.END_TIME, wis.STATUS, wis.STATE
FROM b2bi.dbo.WF_INST_S wis
INNER JOIN b2bi.dbo.WFD wfd 
    ON wfd.WFD_ID = wis.WFD_ID AND wfd.WFD_VERSION = wis.WFD_VERSION
WHERE wfd.NAME = 'FA_CLIENTS_MAIN'
  AND wis.START_TIME >= DATEADD(HOUR, -2, GETDATE())
"@

$b2biRows = Invoke-Sqlcmd `
    -ServerInstance 'FA-INT-DBP' -Database 'b2bi' `
    -Query $b2biQuery -TrustServerCertificate `
    -ApplicationName 'xFACts-B2B-Collector'

# Query 2: Integration for BATCH_STATUS rows matching (enrichment)
$wfIds = ($b2biRows.WORKFLOW_ID | ForEach-Object { $_.ToString() }) -join ','
$intQuery = @"
SELECT CLIENT_ID, SEQ_ID, RUN_ID, PARENT_ID, BATCH_STATUS, FINISH_DATE
FROM Integration.ETL.tbl_B2B_CLIENTS_BATCH_STATUS
WHERE RUN_ID IN ($wfIds);
"@

$intRows = Invoke-Sqlcmd `
    -ServerInstance 'AVG-PROD-LSNR' -Database 'Integration' `
    -Query $intQuery -TrustServerCertificate `
    -ApplicationName 'xFACts-B2B-Collector'

# Build hashtable for in-memory join
$intByRunId = @{}
foreach ($row in $intRows) { $intByRunId[[int64]$row.RUN_ID] = $row }

# Enrich and detect disagreements (alert signal)
foreach ($b2biRow in $b2biRows) {
    $intRow = $intByRunId[[int64]$b2biRow.WORKFLOW_ID]
    if ($null -eq $intRow) {
        # b2bi has the run but Integration doesn't — possible infrastructure failure
        if ($b2biRow.STATE -eq 'FAILED' -or $b2biRow.STATUS -ne 0) {
            Write-Host "ALERT: WF $($b2biRow.WORKFLOW_ID) failed in b2bi but has no Integration record"
        }
    }
    # ... further processing with both rows available
}
```

---

## Integration — Configuration Source Queries

### CLIENTS_FILES — Process-Level Classification for an Entity

```sql
-- Replace @CLIENT_ID with the target entity ID
-- AUTOMATED: 1 = scheduler-dispatched (needs RUN_FLAG gating), 2 = wrapper-dispatched
SELECT ID, CLIENT_ID, SEQ_ID, ACTIVE_FLAG, RUN_FLAG, 
       PROCESS_TYPE, COMM_METHOD, AUTOMATED, FILE_MERGE
FROM Integration.etl.tbl_B2B_CLIENTS_FILES
WHERE CLIENT_ID = @CLIENT_ID
ORDER BY SEQ_ID;
```

### CLIENTS_PARAM — Field-Level Configuration for a Process

```sql
-- Replace @CLIENT_ID and @SEQ_ID with the target process
SELECT CLIENT_ID, SEQ_ID, PARAMETER_NAME, PARAMETER_VALUE
FROM Integration.etl.tbl_B2b_CLIENTS_PARAM
WHERE CLIENT_ID = @CLIENT_ID AND SEQ_ID = @SEQ_ID
ORDER BY PARAMETER_NAME;
```

### Distinct Process Type × Comm Method Pairs

Surveys the configured process landscape. Useful when cataloging remaining process anatomies.

```sql
SELECT PROCESS_TYPE, COMM_METHOD, COUNT(*) AS process_count
FROM Integration.etl.tbl_B2B_CLIENTS_FILES
WHERE ACTIVE_FLAG = 1
GROUP BY PROCESS_TYPE, COMM_METHOD
ORDER BY PROCESS_TYPE, COMM_METHOD;
```

### Entities for a Given Process Type

Finds which entities have a given process type configured. Useful for picking candidate traces when investigating a process type.

```sql
-- Replace @PROCESS_TYPE and @COMM_METHOD
SELECT cf.CLIENT_ID, cm.CLIENT_NAME, cf.SEQ_ID, cf.ACTIVE_FLAG, cf.AUTOMATED
FROM Integration.etl.tbl_B2B_CLIENTS_FILES cf
LEFT JOIN Integration.etl.tbl_B2B_CLIENTS_MN cm ON cm.CLIENT_ID = cf.CLIENT_ID
WHERE cf.PROCESS_TYPE = @PROCESS_TYPE
  AND cf.COMM_METHOD = @COMM_METHOD
ORDER BY cm.CLIENT_NAME, cf.SEQ_ID;
```

### CLIENTS_MN Source Query

Reference for the entity sync path.

```sql
SELECT CLIENT_ID, CLIENT_NAME, ACTIVE_FLAG, AUTOMATED
FROM Integration.etl.tbl_B2B_CLIENTS_MN
ORDER BY CLIENT_ID;
```

### SETTINGS — Global Configuration

```sql
-- View global settings. Note: contains PYTHON_KEY (plaintext credential).
-- Handle with same discretion as ProcessData credentials.
SELECT PARAMETER_NAME, 
       CASE 
           WHEN PARAMETER_NAME IN ('PYTHON_KEY') THEN '***REDACTED***'
           ELSE PARAMETER_VALUE
       END AS PARAMETER_VALUE
FROM Integration.etl.tbl_B2B_CLIENTS_SETTINGS
ORDER BY PARAMETER_NAME;
```

Known settings:
- `DATABASE_SERVER`, `API_PORT`
- `DM_NB_PATH`, `DM_PAY_PATH`, `DM_BDL_PATH` — delivery paths per process type
- `DEF_PRE_ARCHIVE`, `DEF_POST_ARCHIVE` — archive root defaults
- `PYTHON_KEY` — plaintext credential
- `MARCOS_PATH` — purpose unclear

### Discovered Files Table (Pattern 3 Output)

```sql
-- Files that Pattern 3 (FA_FROM_CLIENTS_FTP_FILES_LIST_IB_D2S_RC) has discovered on SFTP endpoints.
-- Consumed by Pattern 2 (scheduler-fired GET_LIST) for per-file inbound dispatch.
SELECT TOP 100 *
FROM Integration.DBO.tbl_FA_CLIENTS_FTP_FILES_LIST_IB_D2S_RC
ORDER BY /* discovery timestamp if present */ DESC;
```

---

## ProcessData Decompression (PowerShell)

Standard extraction pattern. Uses gzip decompression against `TRANS_DATA.DATA_OBJECT` bytes.

```powershell
# Assumes $WFID is set to the target WORKFLOW_ID

$processDataQuery = @"
SELECT TOP 1 DATA_ID, DATA_OBJECT
FROM b2bi.dbo.TRANS_DATA
WHERE WF_ID = $WFID
  AND REFERENCE_TABLE = 'DOCUMENT'
  AND PAGE_INDEX = 0
ORDER BY CREATION_DATE ASC, DATA_ID ASC;
"@

$row = Invoke-Sqlcmd `
    -ServerInstance 'FA-INT-DBP' `
    -Database 'b2bi' `
    -Query $processDataQuery `
    -TrustServerCertificate `
    -MaxBinaryLength 20971520 `
    -ApplicationName 'xFACts-B2BInvestigation'

# Decompress gzip bytes
$bytes = [byte[]]$row.DATA_OBJECT
$ms = New-Object System.IO.MemoryStream(,$bytes)
$gz = New-Object System.IO.Compression.GZipStream($ms, [System.IO.Compression.CompressionMode]::Decompress)
$sr = New-Object System.IO.StreamReader($gz)
$processDataXml = $sr.ReadToEnd()
$sr.Dispose(); $gz.Dispose(); $ms.Dispose()

# Parse structure — note that MAIN only operates on //Result/Client[1],
# but PrimaryDocument may contain the full SP result set with multiple Client blocks
$xml = [xml]$processDataXml

# The Client block MAIN actually processed
$mainClient = $xml.SelectSingleNode('//Result/Client[1]')
if ($null -ne $mainClient) {
    Write-Host "MAIN processed: CLIENT_ID=$($mainClient.CLIENT_ID), SEQ_ID=$($mainClient.SEQ_ID), PROCESS_TYPE=$($mainClient.PROCESS_TYPE)"
}

# The full list of Clients GET_LIST originally returned (may be 1 or more)
$allClients = $xml.SelectNodes('//Client')
Write-Host "Total Client blocks in ProcessData: $($allClients.Count)"
```

**Notes:**
- `-MaxBinaryLength 20971520` is required for large blobs
- `-ApplicationName` should always be set on `Invoke-Sqlcmd` for DB-side attribution
- Root element is `<r>` — confirmed across all observed ProcessData documents
- **MAIN only operates on `//Result/Client[1]`.** Multiple Client blocks may exist elsewhere (e.g., `//PrimaryDocument`) but they are reference context, not work MAIN does.
- `//Settings/Values/...` node contains global settings from `USP_B2B_CLIENTS_GET_SETTINGS` — handle with credential-awareness

---

## TRANS_DATA Document Inventory for a Run

Lists all documents written during a workflow run, ordered chronologically. Useful for understanding what payloads exist beyond just ProcessData (Translation outputs, raw files, status reports, etc.).

```sql
-- Replace @WFID with the target WORKFLOW_ID
SELECT DATA_ID, CREATION_DATE, DATA_TYPE, REFERENCE_TABLE, PAGE_INDEX,
       DATALENGTH(DATA_OBJECT) AS byte_size
FROM b2bi.dbo.TRANS_DATA
WHERE WF_ID = @WFID
ORDER BY CREATION_DATE ASC, DATA_ID ASC;
```

**Interpretation hints:**
- First row with `REFERENCE_TABLE = 'DOCUMENT'` and `PAGE_INDEX = 0` is ProcessData
- `DATA_TYPE = 2` appears to be content/payload documents (files, Translation outputs)
- `DATA_TYPE = 10` appears to be metadata/status payloads
- Size hints at content — small (under ~200 bytes) is typically metadata/status, larger is real content

---

## Decompressing Any TRANS_DATA or DATA_TABLE Row

Same gzip decompression pattern applies to any compressed blob in these tables. Useful for inspecting Translation outputs, schedule TIMINGXML, BPML source, or any other payload.

```powershell
# Generic decompressor — pass in byte array
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

# Use like:
# $content = Expand-GzipBytes -bytes ([byte[]]$row.DATA_OBJECT)
```

---

## Timing XML — Decompression and Parsing Reference

Parses a schedule's TIMINGXML pointer and extracts the structured schedule. Works for all 506 active schedules tested during investigation.

```powershell
# Step 1: Get the TIMINGXML handle for a schedule
$timingQuery = @"
SELECT TIMINGXML 
FROM b2bi.dbo.SCHEDULE 
WHERE SCHEDULEID = $ScheduleId
"@

$scheduleRow = Invoke-Sqlcmd `
    -ServerInstance 'FA-INT-DBP' `
    -Database 'b2bi' `
    -Query $timingQuery `
    -TrustServerCertificate `
    -ApplicationName 'xFACts-B2BInvestigation'

$timingHandle = $scheduleRow.TIMINGXML

# Step 2: Fetch the compressed XML from DATA_TABLE
$dataQuery = @"
SELECT DATA_OBJECT 
FROM b2bi.dbo.DATA_TABLE 
WHERE DATA_ID = '$timingHandle'
"@

$dataRow = Invoke-Sqlcmd `
    -ServerInstance 'FA-INT-DBP' `
    -Database 'b2bi' `
    -Query $dataQuery `
    -TrustServerCertificate `
    -MaxBinaryLength 20971520 `
    -ApplicationName 'xFACts-B2BInvestigation'

# Step 3: Decompress
$xmlText = Expand-GzipBytes -bytes ([byte[]]$dataRow.DATA_OBJECT)
$xml = [xml]$xmlText
```

**Validated grammar:**

```xml
<timingxml>
  <days>
    <day ofWeek|ofMonth="VALUE">
      <times>
        <time>HHMM</time>
      </times>
    </day>
  </days>
  <excludedDates>
    <date>MM-DD</date>
  </excludedDates>
</timingxml>
```

**Day specifiers:**
- `ofWeek="-1"` — every day
- `ofWeek="1"` through `ofWeek="7"` — specific day of week (2=Mon, 3=Tue, 4=Wed, 5=Thu, 6=Fri; 1=Sun rarely seen; 7=Sat not observed)
- `ofMonth="1"` through `ofMonth="31"` — specific day of month

**Case variants:** Sterling system services emit `<TimingXML>` (PascalCase); FA-created workflows emit `<timingxml>` (lowercase). XML parsing handles both.

---

## Known BPMLs and Their Sizes (Reference)

For planning future extractions. All observed sizes are decompressed character counts.

| WFD Name | WFD_ID | Active Version | Decompressed Size | Notes |
|----------|-------:|---------------:|------------------:|-------|
| `FA_CLIENTS_MAIN` | 798 | 48 | ~49,600 chars | The universal worker — single linear sequence with 22 rules |
| `FA_CLIENTS_GET_LIST` | 797 | 19 | ~12,000 chars | Universal dispatcher for Patterns 2 and 4 |
| `FA_CLIENTS_GET_DOCS` | 796 | 37 | ~21,700 chars | MAIN's file acquisition sub-workflow; three GET_DOCS_TYPE branches (SFTP_PULL, FSA_PULL, API_PULL); houses FILE_DELETION logic |
| `FA_CLIENTS_ETL_CALL` | 812 | 1 | ~7,100 chars | Pervasive Cosmos 9 `djengine.exe` macro executor; alternative to MAIN when ETL_PATH is set; v1 never edited |
| `FA_FROM_ACADIA_HEALTHCARE_IB_EO` | 1503 | 13 | ~850 chars | Pattern 4 wrapper — sets CLIENT_ID + SEQ_IDS + SEQUENTIAL=1 |
| `FA_FROM_ACCRETIVE_IB_BD_PULL` | 1231 | 1 | ~860 chars | Pattern 4 wrapper — sets CLIENT_ID + PROCESS_TYPE=SFTP_PULL + SEQUENTIAL=1 |
| `FA_FROM_COACHELLA_VALLEY_ANESTHESIA_IB_BD_SFTP_PULL` | 1542 | 1 | ~850 chars | Pattern 4 wrapper — parallel (no SEQUENTIAL) |
| `FA_FROM_MONUMENT_HEALTH_IB_EO_PULL` | 933 | 2 | ~830 chars | Pattern 4 wrapper — parallel |

**Still to read (priority order):**
- `FA_CLIENTS_TRANS` — translation sub-workflow (probably large)
- `FA_CLIENTS_ACCOUNTS_LOAD` — NB account loading sub-workflow
- `FA_CLIENTS_ARCHIVE` — invoked up to 3 times per MAIN; understanding pre/post archive behavior details
- `FA_CLIENTS_COMM_CALL` — tail sub-workflow where external Python exes are invoked (ACADIA EO orchestration)

---

## Future Query Ideas (To Develop As Needed)

Queries that would be useful but haven't been written yet. Candidate additions as investigation progresses.

- Walk up from a WORKFLOW_ID to find its root and dispatch pattern classification
- Identify all MAIN runs with no sub-workflow invocations (empty runs / short-circuit runs, across patterns)
- Join WORKFLOW_LINKAGE to identify multi-child dispatcher workflows (Pattern 4 wrappers)
- Identify MAIN runs where a specific sub-workflow invocation count differs significantly from baseline
- Correlate TRANS_DATA Translation output sizes across runs of the same process (volume proxy)
- Find all ACT_XFER / ACT_NON_XFER entries tied to a specific MAIN run for SFTP activity detail
- **Detect b2bi-Integration disagreement:** MAIN runs with b2bi STATE=FAILED but no BATCH_STATUS row (infrastructure-failure alert)
- **Inverse disagreement:** BATCH_STATUS rows with no matching b2bi WF_INST_S row (shouldn't happen but worth monitoring)

---

## Document Status

| Attribute | Value |
|-----------|-------|
| Purpose | Investigation-time query/snippet reference for the B2B module work |
| Created | April 20, 2026 |
| Last Updated | April 20, 2026 |
| Status | Working reference — add queries as they are validated |
| Companion to | `B2B_Module_Planning.md`, `B2B_ArchitectureOverview.md`, `B2B_ProcessAnatomy_*.md` |

### Revision History

| Date | Revision |
|------|----------|
| April 20, 2026 (rev 1) | Initial creation. Imported all validated investigation queries from the prior `B2B_Module_Planning.md` Quick Reference Queries section plus the ProcessData decompression PowerShell snippet. Added step-count distribution classifier, sub-workflow invocation count query, Integration configuration source queries, TRANS_DATA document inventory query, generic gzip decompression helper, timing XML parsing pattern with validated grammar, and future query idea list. |
| April 20, 2026 (rev 2) | **Updated after BPML and stored procedure reads.** Additions: (1) **BPML extraction section** — three-step pattern (find WFD_ID → fetch handle → decompress) plus batch-extraction PowerShell for multiple workflows. (2) **Stored procedure source reading** pattern for analyzing Integration SPs. (3) **Coordination Layer Queries section** — BATCH_STATUS lookups, TICKETS queries, cross-server enrichment pattern with disagreement detection for the collector. (4) **Settings query** with credential redaction. (5) **Discovered files table query** (Pattern 3's output). (6) **Known BPMLs reference table** with sizes for planning future extractions. (7) **Future query ideas** expanded to include b2bi-Integration disagreement detection. Step-count classifier updated to reflect current understanding (< 30 steps = short-circuit due to PREV_SEQ failure, not "polling worker"). |
| April 20, 2026 (rev 3) | **Updated after GET_DOCS and ETL_CALL BPML reads.** Additions: (1) **BATCH_FILES queries** — per-run audit lookup and FILE_DELETION activity summary against the newly-discovered `tbl_B2B_CLIENTS_BATCH_FILES` table. (2) **Ticket-writing gaps note** — acknowledges that ETL_CALL doesn't write to TICKETS on fault, so ticket absence is not definitive for all workflow types. (3) **Known BPMLs table** expanded with GET_DOCS v37 (~21,700 chars) and ETL_CALL v1 (~7,100 chars). (4) **Still to read list** updated — removed GET_DOCS and ETL_CALL; added FA_CLIENTS_ARCHIVE and FA_CLIENTS_COMM_CALL as candidate next reads. |

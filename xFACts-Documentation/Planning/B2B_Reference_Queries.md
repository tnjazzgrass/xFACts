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

### Step-Count Distribution for MAIN (Execution Path Proxy)

Rough classifier of MAIN's execution paths based on total step counts. Useful for spotting Path B (SP Executor ~49 steps) vs. Path D (Polling Worker ~16-33 steps) vs. Path A (Standard File Processing 100+) vs. Path C (SFTP Cleanup 900+ for a busy run).

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
        WHEN step_count < 30 THEN '< 30 (possible polling worker)'
        WHEN step_count < 60 THEN '30-60 (possible SP executor skeleton)'
        WHEN step_count < 150 THEN '60-150 (possible small file process)'
        WHEN step_count < 500 THEN '150-500 (moderate file process)'
        ELSE '500+ (heavy file process or cleanup)'
    END AS step_bucket,
    COUNT(*) AS run_count
FROM MainRuns
GROUP BY CASE 
    WHEN step_count < 30 THEN '< 30 (possible polling worker)'
    WHEN step_count < 60 THEN '30-60 (possible SP executor skeleton)'
    WHEN step_count < 150 THEN '60-150 (possible small file process)'
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

## Integration — Configuration Source Queries

### CLIENTS_FILES — Process-Level Classification for an Entity

```sql
-- Replace @CLIENT_ID with the target entity ID
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
SELECT cf.CLIENT_ID, cm.CLIENT_NAME, cf.SEQ_ID, cf.ACTIVE_FLAG
FROM Integration.etl.tbl_B2B_CLIENTS_FILES cf
LEFT JOIN Integration.etl.tbl_B2B_CLIENTS_MN cm ON cm.CLIENT_ID = cf.CLIENT_ID
WHERE cf.PROCESS_TYPE = @PROCESS_TYPE
  AND cf.COMM_METHOD = @COMM_METHOD
ORDER BY cm.CLIENT_NAME, cf.SEQ_ID;
```

### INT_ClientRegistry Source Query

Reference for the sync path.

```sql
SELECT CLIENT_ID, CLIENT_NAME, ACTIVE_FLAG, AUTOMATED
FROM Integration.etl.tbl_B2B_CLIENTS_MN
ORDER BY CLIENT_ID;
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

# Parse all <Client> blocks (multi-client aware)
$xml = [xml]$processDataXml
$clients = $xml.r.Client
foreach ($client in $clients) {
    $clientId = $client.CLIENT_ID
    $seqId = $client.SEQ_ID
    $clientName = $client.CLIENT_NAME
    $processType = $client.PROCESS_TYPE
    $commMethod = $client.COMM_METHOD
    # ... etc
    Write-Host "Client: $clientName ($clientId), SEQ_ID: $seqId, Process: $processType $commMethod"
}
```

**Notes:**
- `-MaxBinaryLength 20971520` is required for large blobs — defaults are too small
- `-ApplicationName` should always be set on `Invoke-Sqlcmd` for DB-side attribution
- Root element is `<r>` (not `<Result>` or `<root>`) — confirmed across all observed ProcessData documents
- Multi-Client runs have multiple `<Client>` blocks; always iterate, never assume one

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

Same gzip decompression pattern applies to any compressed blob in these tables. Useful for inspecting Translation outputs, schedule TIMINGXML, or any other payload.

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

## Future Query Ideas (To Develop As Needed)

Queries that would be useful but haven't been written yet. Candidate additions as investigation progresses.

- Walk up from a WORKFLOW_ID to find its root and dispatch pattern classification
- Identify all MAIN runs with no sub-workflow invocations (empty runs, across patterns)
- Join WORKFLOW_LINKAGE to detect Pattern 5 dispatchers (single parent → multiple simultaneous MAIN children)
- Identify MAIN runs where a specific sub-workflow invocation count differs significantly from baseline
- Correlate TRANS_DATA Translation output sizes across runs of the same process (volume proxy)
- Find all ACT_XFER / ACT_NON_XFER entries tied to a specific MAIN run for SFTP activity detail

---

## Document Status

| Attribute | Value |
|-----------|-------|
| Purpose | Investigation-time query/snippet reference for the B2B module work |
| Created | April 20, 2026 |
| Status | Working reference — add queries as they are validated |
| Companion to | `B2B_Module_Planning.md`, `B2B_ArchitectureOverview.md`, `B2B_ProcessAnatomy_*.md` |

### Revision History

| Date | Revision |
|------|----------|
| April 20, 2026 | Initial creation. Imported all validated investigation queries from the prior `B2B_Module_Planning.md` Quick Reference Queries section plus the ProcessData decompression PowerShell snippet. Added step-count distribution classifier (Path A/B/C/D proxy), sub-workflow invocation count query, Integration configuration source queries (CLIENTS_FILES, CLIENTS_PARAM, distinct process type pairs, entities by process type), TRANS_DATA document inventory query, generic gzip decompression helper function, timing XML parsing pattern with validated grammar reference, and future query idea list. |

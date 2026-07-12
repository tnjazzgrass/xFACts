# Step 6C Findings -- Core Workflow BPML Analysis

**Date:** 2026-07-10
**Investigation folder:** `xFACts-Documentation/WorkingFiles/B2B_Investigation/Step_06C_BPML_Analysis/`
**Input corpus:** 429 BPMLs extracted in Step 6B (`Step_06B_BPMLs/`)

## Purpose

Deep-read the FA_CLIENTS family (all 28 BPMLs: 11 active + 17 dormant/inline) plus
the dispatcher population, documenting each workflow's sequence, rules, sub-workflow
invocations (with mechanism and mode), service calls, fault handlers, and external
references. Every claim in this document is verified directly against BPML source.
Runtime behavior claims remain out of scope (Step 6E); ArchitectureOverview claim
resolution remains out of scope (Step 6D) -- interim agreements/disagreements are
noted in section 10.

**Scope exceeded plan:** the Roadmap called for reading representative dispatchers.
Because a shape scan proved the dispatcher population nearly perfectly uniform, this
step instead produced a complete census of all 371 FA_FROM / FA_TO / FA_DM /
FA_OTHER / FA_Specialized BPMLs (section 3). Sampling was unnecessary.

---

## 1. Summary of change

1. **The execution model is a single spine.** Every client pipeline in Sterling runs
   through exactly one path: wrapper workflow (or schedule, or another workflow)
   sets parameters and inline-invokes `FA_CLIENTS_GET_LIST`; GET_LIST queries the
   work queue via `faint.USP_B2B_CLIENTS_GET_LIST` and dispatches one
   `FA_CLIENTS_MAIN` (or `FA_CLIENTS_ETL_CALL`) per queued client row. MAIN is
   invoked by exactly one workflow in the entire corpus: GET_LIST. There is no
   second entry point.
2. **361 of 371 wrapper-family BPMLs are byte-pattern-identical 2-operation
   wrappers** (AssignService parameter block + `InlineInvokeBusinessProcessService`
   of GET_LIST). The legacy dispatch "Pattern 1-5" taxonomy collapses: structurally
   there is one dispatcher pattern with seven parameter profiles (section 3).
3. **The GET_LIST instance-count mystery is resolved structurally.** All 367
   corpus references to GET_LIST are inline invocations, which do not produce
   `WF_INST_S` rows. The 85 standalone GET_LIST rows per 30d can only be direct
   scheduler fires. (Runtime confirmation of the schedule itself: Step 6E.)
4. **`Integration.ETL.tbl_B2B_CLIENTS_BATCH_STATUS` value vocabulary recovered from
   source** (section 7), including a correction: `-2` is written by MAIN itself
   when its predecessor in a SEQUENTIAL chain failed -- a cascade-skip marker, not
   a legacy code path.
5. **Four dead rules, two orphaned workflows, one rule tautology, one cross-workflow
   column-count contradiction, and one potential infinite-poll hazard** identified
   (section 9).
6. **Complete inventories** of the Integration DB surface, external executables,
   translation maps, XSLT stylesheets, adapter instances, client-config fields, and
   Settings values consumed by the family (sections 6-8).

---

## 2. The execution model

```
Schedule / wrapper WFD / other WFD
  |  (sets CLIENT_ID [+ SEQ_ID | SEQ_IDS | PROCESS_TYPE | SEQUENTIAL | COMM_METHOD])
  v
FA_CLIENTS_GET_LIST          (inline in wrapper; standalone only when scheduler-fired)
  |  INSERT own row -> tbl_B2B_CLIENTS_BATCH_STATUS (RUN_ID = own/wrapper invoke id)
  |  EXEC faint.USP_B2B_CLIENTS_GET_SETTINGS        -> //Settings/Values
  |  EXEC faint.USP_B2B_CLIENTS_GET_LIST ?,?,?,?,?  -> //Result/Client rows (work queue)
  |  per client row:
  |      ETL_PATH set?  -> Invoke FA_CLIENTS_ETL_CALL   (no INVOKE_MODE specified)
  |      otherwise      -> Invoke FA_CLIENTS_MAIN       (no INVOKE_MODE specified)
  |      then UPDATE etl.tbl_B2B_CLIENTS_FILES SET RUN_FLAG = 0 (unconditional)
  |  final: UPDATE own BATCH_STATUS row -> 2
  v
FA_CLIENTS_MAIN (one per client row)
  |  INSERT own BATCH_STATUS row (CLIENT_ID, SEQ_ID, RUN_ID = own id, PARENT_ID = dispatcher id)
  |  PREV_SEQ set? -> poll predecessor BATCH_STATUS until it leaves 0..2 / -999
  |  Continue? (pred in 3..5 or never polled) -> process; else short-circuit
  |  GET_DOCS -> per-file loop -> tail chain (sections 4-5)
  |  final: UPDATE own BATCH_STATUS -> computed 2/3/4/5, or -2 if short-circuited
  |  onFault: BATCH_STATUS -> -1, TICKETS insert, EmailOnError
```

Correlation keys, verified from source:

- A dispatcher (wrapper) run's `WORKFLOW_ID` in `WF_INST_S` equals the `RUN_ID` of
  the BATCH_STATUS row inserted by its inline GET_LIST, because inline invocation
  shares the process instance (`thisProcessInstance` resolves to the wrapper).
- Each MAIN run's `WORKFLOW_ID` equals its own BATCH_STATUS `RUN_ID`, and its
  `PARENT_ID` equals the dispatcher's `WORKFLOW_ID`.
- The DM batch bridge: COMM_CALL writes the DM-assigned batch id into
  `BATCH_STATUS.BATCH_ID` for the MAIN run's RUN_ID (section 5.10).

---

## 3. Dispatcher census (371 BPMLs scanned)

Families scanned: 02_FA_FROM (104), 03_FA_TO (228), 04_FA_DM (5), 05_FA_OTHER (31),
06_FA_Specialized (3). Result: **361 standard wrappers, 10 non-standard.**

Standard wrapper shape (all 361): exactly two operations --
`AssignService` (parameter block) then `InlineInvokeBusinessProcessService` with
`WFD_NAME = FA_CLIENTS_GET_LIST`. No other invocation target and no other
mechanism occurs among the 361.

Parameter profiles observed:

| Profile (assigned parameters) | Count |
|---|--:|
| CLIENT_ID, SEQ_ID | 238 |
| CLIENT_ID, SEQ_IDS, SEQUENTIAL | 47 |
| CLIENT_ID, PROCESS_TYPE | 45 |
| CLIENT_ID, SEQ_IDS | 19 |
| CLIENT_ID, PROCESS_TYPE, SEQUENTIAL | 6 |
| CLIENT_ID, SEQ_ID, SEQUENTIAL | 3 |
| CLIENT_ID, COMM_METHOD, PROCESS_TYPE | 3 |

These map one-to-one onto the `faint.USP_B2B_CLIENTS_GET_LIST ?,?,?,?,?` signature
(CLIENT_ID, SEQ_ID, SEQ_IDS, PROCESS_TYPE, SEQUENTIAL) plus a COMM_METHOD override
consumed from ProcessData in three cases. The proc is therefore the sole authority
on what a given wrapper actually selects -- wrapper BPML carries only the key.

The 10 non-standard files (6F material; one-line roles verified from source):

| Workflow | Shape |
|---|---|
| FA_FROM_PAYGROUND_ALL_CLIENTS_IB_EO_REPORTS_PULL | Single CLA op: FA_PAYGROUND...REPORTS_PULL.exe PROD |
| FA_TO_PAYGROUND_ALL_CLIENTS_OB_EO_S2J_RPT | Single CLA op: FA_PAYGROUND...S2J_RPT.exe PROD |
| FA_DM_ENOTICE_ARCHIVE | Single JDBC op: insert-select into etl.tbl_ENOTICE_TO_REVSPRING_VALDN_ARC |
| FA_DM_ENOTICE | 47 ops; reuses GET_DOCS, ARCHIVE, VITAL, EMAIL (deep read deferred to 6F) |
| FA_DM_INCEPTION_HOLD_TAG | 4 ops |
| FA_DM_ITS_REQST | 13 ops; reuses GET_DOCS, ARCHIVE |
| FA_CCI_SFTP_FILE_LIST_EMAIL | 5 ops; reuses FA_CLIENTS_EMAIL |
| FA_JACK_HUGHSTON_IB_EO_ENC_UPD_SP | Single JDBC op: EXEC FAINT.USP_FA_JACK_HUGHSTON_IB_EO_ENC_UPD |
| FA_ULS_TO_VISPA_OB_PY | Single CLA op: FA_UNLIMITED_SYSTEMS_SFTP_PULL_AND_PUSH.exe |
| FA_CUSTOM_INT_CONSUMER_ACCOUNTS_MERGE_CLA | GET_SETTINGS + FA_CONSUMER_ACCOUNTS_MERGE.exe |

Four FA_CLIENTS-named top-level workflows are themselves standard wrappers for
internal client 328: CNSMR_ACCNT_AR (SEQ_ID 5), CNSMR_TAG (SEQ_ID 4),
INVALID_ACCOUNTS_OB_EOBD_D2S_RPT (SEQ_ID 25), REMIT_DATA_VERIFICATION (SEQ_IDS 22).
The Pattern-3 pair FA_FROM_CLIENTS_FTP_FILES_LIST_IB_D2S_RC / _RC_ARC are also
client-328 wrappers (SEQ_ID 12 / 13) -- their high run counts (688 + 656 per 30d)
are ordinary wrapper runs, not a distinct mechanism.

---

## 4. FA_CLIENTS_MAIN v48 -- structural map

Shape: one root `<sequence name="Receive File">`, 590 elements, 26 choice blocks,
23 rules defined / 22 referenced, one `<onFault>`.

### 4.1 Preamble

1. ReleaseService clears INVOKE_ID_LIST / PrimaryDocument leftovers.
2. This Service captures `thisProcessInstance` (own invoke id).
3. TimestampUtilService writes `//time` as yyyyMMdd.
4. AssignService: `Ready = -999`; `ClientArchiveName` = GET_DOCS_LOC (for
   SFTP_PULL+INBOUND) else CLIENT_NAME with spaces converted to underscores.
5. JDBC INSERT into `INTEGRATION.ETL.tbl_B2B_CLIENTS_BATCH_STATUS`
   (CLIENT_ID, SEQ_ID, RUN_ID = own id, PARENT_ID = `//parentID/INVOKE_ID_LIST`).

### 4.2 Wait / Continue gates (SEQUENTIAL chain mechanics)

- `Wait?` = PREV_SEQ set AND (Ready = -999 OR 0 <= Ready <= 2). While true:
  WaitService 1s, then poll
  `SELECT CASE WHEN BATCH_STATUS = -2 THEN -1 ELSE BATCH_STATUS END ... WHERE
  CLIENT_ID = ? AND SEQ_ID = PREV_SEQ AND PARENT_ID = ?` into `Ready`; repeat.
- `Continue?` = Ready = -999 OR 3 <= Ready <= 5. A predecessor result of -1
  (fault) or -2 (cascade-skip, converted to -1 by the poll CASE) fails the gate
  and the entire processing body is skipped.
- XPath quirk: both rules parenthesize as `number(//Ready/text() <= 2)` /
  `number(//Ready/text() >= 3)` -- the comparison sits inside number(). This is
  functionally equivalent to the intended form (number of a boolean is 0/1,
  which is falsy/truthy in the same cases) but should not be copied as a pattern.

### 4.3 Rules (23 defined, 22 live)

| Rule | Condition (paraphrased; source is authoritative) | Referenced |
|---|---|---|
| AnyMoreDocs? | currentdoc <= noofdocs | yes (loop) |
| Wait? / Continue? | see 4.2 | yes |
| Prep? | PREPARE_SOURCE = 'Y' | yes |
| PreArchive? | PRE_ARCHIVE != 'N' AND (files exist OR FSA_DocumentCount > 0) | yes |
| Translate? | TRANSLATION_MAP set | yes |
| DupCheck? | DUP_CHECK set and != 'N' and files exist | yes |
| WorkersComp? | WORKERS_COMP = 'Y' and files exist and no DUPLICATE_FILE | yes |
| PostArchive? | (POST_ARCHIVE != 'N' OR POST_ARCHIVE != '') AND (files exist OR COMM_METHOD = 'OUTBOUND') | yes |
| PostArchive2? | POST_ARCHIVE != 'N' and files exist and PROCESS_TYPE in (PAYMENT, NEW_BUSINESS) | yes |
| SendEmail? | MAIL_TO set and (non-empty files, or OUTBOUND, or noofdocs > 0) | yes |
| CommCall? | COMM_CALL = 'Y' | yes |
| PrepCommCall? | non-NB/PAY with PREPARE_COMM_CALL='Y' or OUTBOUND; or NB/PAY with files, no dup, non-empty | yes |
| MergeFiles? | no POST_TRANSLATION_MAP, TRANSLATION_MAP set, files exist, PROCESS_TYPE in (PAYMENT, NEW_BUSINESS) | yes |
| VITAL? | PROCESS_TYPE != 'SFTP_PULL' | yes (x2) |
| NB? | PROCESS_TYPE = 'NEW_BUSINESS' | yes (x2, both polarities) |
| Encounter? | ENCOUNTER_MAP set | yes (x2) |
| AddressLookup? | PV_FN_ADDRESS set and != 'N' and files exist | yes |
| PostTranslation? | POST_TRANSLATION = 'Y' | yes |
| PostTranslationVITAL? | POST_TRANSLATION_VITAL = 'Y' | yes (both polarities) |
| TranslationStaging? | TRANSLATION_STAGING = 'Y' | yes |
| RemoveSpecialCharacters? | FILE_CLEAN_UP = 'Y' and no PREP_TRANSLATION_MAP | yes |
| **SaveDoc?** | FILE_RENAME = 'Y' | **no -- dead rule** |

Findings on the rules themselves:

- **`PostArchive?` first conjunct is a tautology.** `X != 'N' OR X != ''` is true
  for every value of X. The rule reduces to "files exist OR outbound", so the
  post-archive ARCHIVE invocation fires even when POST_ARCHIVE = 'N'. Downstream,
  ARCHIVE will FS_EXTRACT to extractionFolder `concat('N','\', yyyy, ...)` in that
  case. Whether the combination (POST_ARCHIVE = 'N' with files present) occurs in
  production, and where such extracts land, is a Step 6E runtime question.
- **`SaveDoc?` is dead.** FILE_RENAME handling is done inline via if() inside the
  document-save assign at the loop tail, not via this rule. This reconciles the
  two prior counts: 23 rules exist (Step 6B), 22 are live.
- MAIN's preamble **mutates client config in ProcessData**: POST_ARCHIVE = 'Y' is
  expanded to `DEF_POST_ARCHIVE \ COMM_METHOD \ ClientArchiveName`; FILE_CLEAN_UP
  is recomputed to a hard Y/N from five conditions regardless of its configured
  value (unless configured 'N'); GET_DOCS_LOC and ClientArchiveName are truncated
  at the first '/'.

### 4.4 Start_Process and the per-file loop

After `Continue?` passes: GET_DOCS is invoked (inline), then `noofdocs` is
computed -- OUTBOUND with empty GET_DOCS_TYPE: count of pipe-delimited FILE_FILTER
entries; FSA_PULL: `//FSA_DocumentCount`; otherwise `count(//DocumentList/DocumentId)`.
`FinalFileName` is assembled here (section 7.3). `EmptyFile` initializes to 1 for
PAYMENT else 0.

Loop body order per document (each stage gated by its rule):

1. Pick document: PrimaryDocument := `FSA_Document{n}` or `SFTPPrimDoc{n}` handle;
   `assignedFilename` from FSA attribute or `//Files/File[n]/Name`; VITAL FLOW_ID /
   TRANS_TYPE assigns.
2. **PreArchive** -> `PreArchiveFlag = 1`; PRE_ARCHIVE 'Y' expanded like
   POST_ARCHIVE; invoke ARCHIVE (INVOKE_MODE = INLINE); flag reset to 0.
3. **PrepSource** -> invoke PREP_SOURCE (inline participant).
4. VITAL DOC_PATH / FILE_NAME assigns; NEW_FILE_FILTER computed from the
   PGP / unzip configuration matrix.
5. **RemoveSpecialCharacters** -> CommandLineAdapter2 runs
   FA_FILE_REMOVE_SPECIAL_CHARACTERS.exe (20-minute timeout) against the dated
   PRE_ARCHIVE folder, then AS3FSAdapter FS_COLLECT re-collects the cleaned file.
6. **Translation** -> invoke TRANS (inline participant).
7. If NOT PostTranslationVITAL: **VITALInsert** (VITAL? gate) -> invoke VITAL
   (ASYNC); EmptyFile recompute; NB? -> invoke ACCOUNTS_LOAD (INVOKE_MODE = INLINE)
   else release the VITAL node; Encounter? -> invoke ENCOUNTER_LOAD (ASYNC).
8. **PostArchive** -> `PostArchiveFlag = 1`; invoke ARCHIVE (ASYNC); flag reset.
9. **TranslationStaging** -> invoke TRANSLATION_STAGING (INVOKE_MODE = INLINE).
10. **MergeFiles** -> invoke FILE_MERGE (inline participant).
11. Save current document handle as `SavedPrimDoc{n}` (from-source chosen by an
    inline if() over OUTBOUND / FILE_RENAME / PREP_COMM_CALL -- the logic the dead
    SaveDoc? rule duplicates); release per-file temporaries; currentdoc++; repeat.

### 4.5 Post-loop tail chain

1. **PostTranslation?** -> VITAL FLOW_ID / TRANS_TYPE reassign; invoke
   POST_TRANSLATION (inline participant).
2. **PostTranslationVITAL?** -> the deferred VITAL block: VITAL? -> invoke VITAL
   (ASYNC); EmptyFile recompute; NB? -> ACCOUNTS_LOAD (INVOKE_MODE = INLINE) else
   release VITAL; Encounter? -> ENCOUNTER_LOAD (ASYNC).
3. **WorkersComp?** -> invoke WORKERS_COMP (inline participant).
4. **DupCheck?** -> invoke DUP_CHECK (inline participant).
5. **PostArchive2?** -> `PostArchiveFlag = 2`; invoke ARCHIVE with runtime-chosen
   INVOKE_MODE: INLINE if PV_FN_ADDRESS is set (so the merged file is on disk
   before the address exe reads it), else ASYNC; flag reset.
6. **AddressLookup?** -> invoke ADDRESS_CHECK (inline participant).
7. **PrepCommCall?** -> invoke PREP_COMM_CALL (inline participant).
8. **CommCall?** -> invoke COMM_CALL (inline participant).
9. **SendEmail?** -> invoke EMAIL (ASYNC).

### 4.6 Tail status UPDATE

`UPDATE ... SET BATCH_STATUS = CASE WHEN (? = -1) THEN -2 ELSE ? END,
FINISH_DATE = GETDATE() WHERE RUN_ID = ?` with param1 = `//Ready` and param2
computed as: BDL -> 2; files present and no duplicate -> (NB or PAYMENT ? 2 : 3);
duplicate flagged -> 5; no files -> 4.

**Correction to prior understanding:** `-2` is not a legacy code path. MAIN writes
-2 for its own run precisely when `Ready = -1`, i.e. when its predecessor in a
SEQUENTIAL chain failed and this run short-circuited at the Continue? gate. The
poll SELECT's CASE then presents that -2 as -1 to the next member, cascading the
skip down the chain. -1 = own fault; -2 = skipped because upstream failed. These
are distinct operational stories and should be surfaced distinctly by any future
collector.

### 4.7 onFault

1. UPDATE own BATCH_STATUS -> -1 with FINISH_DATE.
2. INSERT into `ETL.tbl_B2B_CLIENTS_TICKETS` -- positional, 10 values:
   `VALUES(NULL, CLIENT_ID, SEQ_ID, RUN_ID, CLIENT_NAME, NULL, 'MAP ERROR',
   GETDATE(), NULL, NULL)`.
3. Invoke `EmailOnError` (ASYNC).

---

## 5. Sub-workflow deep reads

Each entry: role, gating, operations of note, external references. All verified
from the extracted latest-version BPML named in Step 6B's manifest.

### 5.1 FA_CLIENTS_GET_LIST v19 (dispatcher core)

Covered structurally in section 2. Additional source facts:

- Own BATCH_STATUS INSERT uses a 3-column list (CLIENT_ID, SEQ_ID, RUN_ID) with a
  CASE writing SEQ_ID NULL for whole-client runs; MAIN and ETL_CALL use the
  4-column list including PARENT_ID.
- Per-client dispatch target: `FA_CLIENTS_ETL_CALL` when ETL_PATH is set, else
  `FA_CLIENTS_MAIN`, both via `InvokeBusinessProcessService` with **no INVOKE_MODE
  assign at all** (Sterling default applies -- identifying that default's runtime
  behavior is a Step 6E item; the observed 6,153 standalone MAIN rows say the
  children get their own WF_INST_S identity).
- After each dispatch: `UPDATE etl.tbl_B2B_CLIENTS_FILES SET RUN_FLAG = 0 WHERE
  CLIENT_ID = ? AND SEQ_ID = ?` -- unconditional in the loop.
- **Dead rule:** `UpdateRunFlag?` (SEQ_ID != '') is defined and never referenced.
- Tail: own BATCH_STATUS -> 2. onFault: own BATCH_STATUS -> -1; TICKETS insert
  with **9 positional values** (see section 9.4); EmailOnError (no INVOKE_MODE).

### 5.2 FA_CLIENTS_GET_DOCS v37 (file acquisition; inline from MAIN)

Three acquisition branches on GET_DOCS_TYPE:

- **SFTP_PULL:** BeginSession (password auth; ProfileId from GET_DOCS_PROFILE_ID,
  default `FA-INT-APPT:node1:17b98dc642f:105916`), CD to GET_DOCS_LOC, LIST,
  serialize listing, then `JavaTaskFS` runs `E:\Utilities\FA_FILE_CHECK.java`
  (listing filter), recount, then per-file loop:
  - `GetMoreDocs?` supports whole-directory mode (FILE_ID = 0) and single-file
    mode (FILE_ID > 0: exactly one file, named by FILE_FILTER).
  - Normal files: SFTP GET, then remote disposition -- `DocDelete?`
    (GET_DOCS_DLT = 'Y' **or empty -- delete is the default**) -> SFTP DELETE;
    `DocArchive?` (GET_DOCS_DLT holds a path) -> SFTP MOVE to that path prefix.
    Picked-up name/size appended to tmpFiles; handle saved as `SFTPPrimDoc{n}`.
  - Zero-size files (unless GET_EMPTY_DOCS = 'Y' or PROCESS_TYPE contains _PULL),
    and ALL files when PROCESS_TYPE = 'FILE_DELETION': remote delete/move without
    pickup, plus a direct JDBC INSERT into
    `Integration.etl.tbl_B2B_CLIENTS_BATCH_FILES` (COMM_METHOD = 'SFTP_GET').
    This is how FILE_DELETION works: acquisition-side disposal only.
  - After the loop: picked-up inventory rebuilt into //Files, then Translation map
    `FA_CLIENTS_BATCH_FILES_X2S` (gated by PROCESS_TYPE != 'SFTP_PULL') writes the
    file inventory to the database -- the map's target table is not visible in
    BPML (hypothesis: tbl_B2B_CLIENTS_BATCH_FILES; verify in 6E). End session.
- **FSA_PULL:** AS3FSAdapter FS_COLLECT from GET_DOCS_LOC with FILE_FILTER;
  deleteAfterCollect unless GET_DOCS_DLT = 'N'.
- **API_PULL:** Command Line 2 Adapter instance `FA_CLA_DEFAULT` runs the
  client-configured GET_DOCS_API executable with args (DATABASE_SERVER,
  GET_DOCS_LOC, MISC_REC1) and a **10-hour timeout** (36,000,000 ms), then the
  same FS_COLLECT as FSA_PULL, then **sets GET_DOCS_TYPE := 'FSA_PULL'** so all
  downstream logic treats API acquisitions as FSA documents.

### 5.3 FA_CLIENTS_PREP_SOURCE v34 (per-file preparation; inline from MAIN)

Ten conditional stages in fixed order, each driven by client config:

1. **UnPGP** (PGP_PASSPHRASE set): CLA instance `FA_CLA_UNPGP` decrypts the dated
   PRE_ARCHIVE copy. The passphrase is passed as a plaintext command-line
   argument. Output re-collected (`.PGPOUT` / `.PGPOUT.zip`).
2. **Convert2CSV** (CONVERT_TO_CSV set, no TRANSLATION_MAP): `JavaTaskFS` runs
   `E:\Utilities\FA_CONVERT_FILE_TO_CSV.java`.
3. **UnZip** (UNZIP_FILTER set): Compression Service decompresses with
   `decompress_result = start_bpml`, **bootstrapping FA_CLIENTS_ARCHIVE as the
   result handler** with a `message_to_child` block (PRE_ARCHIVE, PreArchiveFlag
   = 1, time) -- a third invocation mechanism, and a fourth ARCHIVE call site.
   Then Sleep 5s, FA_FILE_REMOVE_SPECIAL_CHARACTERS.exe over the extracted
   members, FS_COLLECT (deleteAfterCollect = true, sortBy = FS_DATE).
4. **XSLXToCSV** (CONVERT_TO_CSV and TRANSLATION_MAP both set): Sleep 10s, then
   FA_CLIENTS_CONVERT_XLSX2CSV.exe (20-minute timeout), re-collect.
5. **PDFFile** (PDF_FILE = 'Y'): document content type set to Application/PDF.
6. **EncodeConvert** (PREP_ENCODE_FROM/TO): Encoding Conversion service.
7. **RenameDoc** (FILE_RENAME set, not 'N'): FILE_RENAME = 'Y' -> `JavaTaskFS`
   `E:\Utilities\FA_FILE_RENAME.java`; any other value is treated as an **XPath
   expression** evaluated via This Service into tmpFileRename. Document metadata
   renamed; handle re-saved as SFTPPrimDoc{n}.
8. **CustomCLA** (CLA_EXE_PATH set): client-configured executable via
   FA_CLA_DEFAULT, 10-hour timeout, args include `//Settings/Values/PYTHON_KEY`;
   output re-collected for non-OUTBOUND runs.
9. **PrepUsed** (PREP_TRANSLATION_MAP set): for inbound runs, special-character
   clean + re-collect first; then Translation with the client's prep map.
10. **SQLCall / PreSQLCall / PreKeyWordReplace:** `SQL_QUERY` (first file only)
    and `PRE_SQL_QUERY` (each file; XPath-expanded on first file) are executed
    **verbatim from client config** (query_type = ACTION) against
    SQL_QUERY_DATA_SOURCE or the default Integration pool; then DocKeywordReplace
    swaps PRE_KEYWORD_REPLACE_FROM -> _TO.

All 16 rules in this workflow are live.

### 5.4 FA_CLIENTS_TRANS v6 (translation; inline from MAIN)

OUTBOUND: release assignedFilename, Translation with the client's TRANSLATION_MAP
(output_to_process_data = NO; StatusReport captured), append VITAL TRANSACTIONS
FILE_NAME / DOC_PATH (DOC_PATH built from DEF_POST_ARCHIVE when POST_ARCHIVE is
active), append `//FILELIST/SIZE` = count of VITAL TRANSACTION nodes, and -- when
the EmptyFile? gate passes -- rename the produced document to assignedFilename via
GetDocumentInfoService. Inbound: Translation with TRANSLATION_MAP only.
`PlacementDate` is assigned from the filename at entry; no consumer of it exists
in this workflow or in MAIN (noted for 6F cross-reference).

### 5.5 FA_CLIENTS_ARCHIVE v12 (disk archival; 4 call sites)

Two conditional FS_EXTRACT operations, gated by flags set by the caller -- this
workflow reads PreArchiveFlag / PostArchiveFlag, not the client's PRE/POST_ARCHIVE
values directly:

- PreArchiveFlag = 1: extract PrimaryDocument to the dated PRE_ARCHIVE folder.
- PostArchiveFlag = 1: extract to dated POST_ARCHIVE folder as
  `assignedFilename + '.trans'` (the per-file translated output).
- PostArchiveFlag = 2: extract to dated POST_ARCHIVE folder as `FinalFileName`
  (the merged output), with assignFilename = true only for PAYMENT /
  NEW_BUSINESS / BDL.

No rules beyond the two flag gates, no JDBC, no onFault. If neither flag is hot
the run is a successful no-op. This trivial shape is consistent with (though not
proof of) the observed 0 failures in 10,167 runs; FS_EXTRACT faults remain the
only failure surface. Step 6E should also resolve where extracts land when
POST_ARCHIVE = 'N' reaches this workflow via MAIN's tautological gate (the
extraction folder would begin with the literal 'N').

### 5.6 FA_CLIENTS_VITAL v9 (VITAL insert; ASYNC from MAIN x2 sites)

Serializes the accumulated //VITAL DOM (FLOW_ID, TRANS_TYPE, TRANSACTIONS with
DOC_PATH / FILE_NAME) into a document and runs Translation map
`FA_CLIENTS_MP_VITAL`. **The database write is inside the map** -- target
tables/DB are not visible in BPML and must be verified at runtime (6E; Roadmap
section 5.10). Original PrimaryDocument saved and restored around the call.
**Dead rule:** `NB?` is defined and never referenced.

### 5.7 FA_CLIENTS_ACCOUNTS_LOAD v1 (NB accounts insert; INLINE from MAIN x2 sites)

Identical serialize-translate-restore shape to VITAL, using map
`FA_CLIENTS_X2S_ACCTS` (database write inside the map). Releases //NodeCounter.
**Dead rule:** `NB?` defined, never referenced -- same orphan pattern as VITAL.

### 5.8 FA_CLIENTS_ENCOUNTER_LOAD v2 (ASYNC from MAIN x2 sites)

Re-picks the current document, translates via the client's ENCOUNTER_MAP, and if
the map requested new IDs (ENC_ID_ADD or SERV_ID_ADD > 0) inline-invokes
ENCOUNTER_ID, then runs map `FA_CLIENTS_ENCOUNTER_LOAD_D2S` (database write
inside the map). onFault -> EmailOnError. Failure surfaces: two maps, the ID
allocator, and the lock executable -- candidates for the observed 6.1% failure
rate (6E).

### 5.9 FA_CLIENTS_ENCOUNTER_ID v8 (ID block allocator; inline from ENCOUNTER_LOAD)

External mutex + counter block allocation:

1. `FA_IBM_FILE_LOCK.exe PROD|TEST <invoke_id>` -- acquire lock.
2. Single JDBC batch under `SET TRANSACTION ISOLATION LEVEL SERIALIZABLE`:
   read `Integration.dbo.FAI_FILE_ID` counters CTR_3 (encounter ids) and CTR_4
   (service ids), advance both by the requested block sizes, return the block
   starting values.
3. `FA_IBM_FILE_LOCK.exe` again -- release lock.

The lock executable and the SERIALIZABLE transaction are belt-and-suspenders
around the same critical section. New table surface: `Integration.dbo.FAI_FILE_ID`
(CTR_3, CTR_4).

### 5.10 FA_CLIENTS_COMM_CALL v31 (DM handoff; inline from MAIN)

- `DM?` gate: BDL, or NB/PAYMENT with files, non-empty, no duplicate. Then:
  - **PreDMMerge** (NB with PRE_DM_MERGE set):
    FA_PRE_DM_MERGE_CONSUMERS.exe (1-hour timeout).
  - **DM_API_SPLIT.exe** (CLA instance `FA_CLA_DM_API`, 1-hour timeout) with
    args: DM host (DM-PROD-APP3 in prod / DM-TEST-APP otherwise -- chosen off
    `DATABASE_SERVER`), `//Settings/Values/API_PORT`, DMBatchType, FinalFileName,
    auto-release flag (AUTO_RELEASE = 'Y' or PAYMENT), DM_BATCH_SPLIT.
  - The exe's StatusReport is parsed and the DM-assigned batch id written back:
    `UPDATE ... tbl_B2B_CLIENTS_BATCH_STATUS SET BATCH_ID = ? WHERE RUN_ID = ?`.
    **This is the B2B -> Batch Monitoring bridge, verified from source.**
- **CommCallCustomCLA** (COMM_CALL_CLA_EXE_PATH set): client-configured exe,
  10-hour timeout, workingDir from COMM_CALL_WORKING_DIR.
- **CommCallSQL** (COMM_CALL_SQL_QUERY set): XPath-expanded, then executed
  verbatim (query_type = ACTION) -- third client-config arbitrary-SQL field.

### 5.11 FA_CLIENTS_PREP_COMM_CALL v9 (delivery prep; inline from MAIN)

- Sets `DMBatchType` and drops `FinalFileName` to the DM import folder:
  NB -> `//Settings/Values/DM_NB_PATH`; PAYMENT -> DM_PAY_PATH; BDL -> DM_BDL_PATH
  (BDL extract does not set assignedFilename/assignFilename; NB and PAYMENT do).
- FILE_RENAME = 'Y': per-document rename loop via FA_FILE_RENAME.java.
- OUTBOUND delivery: SFTP_PUSH (session from PUT_DOCS_PROFILE_ID; `CdUp = YES`
  then CD to PUT_DOCS_LOC; per-document PUT of SavedPrimDoc{n}, skipping empty
  files per SEND_EMPTY_FILES; delivered Name/Size parsed from the PUT
  StatusReport; row tagged Type = SFTP_PUT) or FSA_PUSH (FS_EXTRACT to
  PUT_DOCS_LOC; Type = FSA_PUT). Both paths finish by rebuilding //Files and
  running Translation map `FA_CLIENTS_BATCH_FILES_X2S` -- outbound deliveries are
  recorded through the same map as inbound pickups.
- Naming inconsistency: rule `OutBoundSFTP` lacks the family's '?' suffix
  (section 9.8).

### 5.12 FA_CLIENTS_FILE_MERGE v3 (merged-document assembly; inline from MAIN)

For PAYMENT / NEW_BUSINESS multi-file runs: extracts the accumulated merged
document and the current document at the XML root (`consumers` /
`consumer-payment-imports`), MergeDocument combines them, BatchProcessor wraps
prefix + suffix envelopes (CR Software Titanium `newbiz` or
`consumer-payment-import-job` headers assembled in BPML, including client-code,
batch-name with //time, and number-of-accounts summed from both parts), then XSLT
`FA_FILE_MERGE`. On the final document of a multi-file PAYMENT run, XSLT
`FA_PAYMENT_NODE_COUNTER` corrects the payment node count.

### 5.13 FA_CLIENTS_POST_TRANSLATION v5 (inline from MAIN, post-loop)

Optional stages: `POST_TRANS_SQL_QUERY` executed verbatim (fourth arbitrary-SQL
config field; XPath-expanded; query_type = ACTION); POST_TRANSLATION_MAP
translation; POST_TRANS_FILE_RENAME -> rename to FinalFileName;
POST_KEYWORD_REPLACE_FROM/_TO via DocKeywordReplace; POST_TRANSLATION_OVERWRITE =
'Y' resets the Files list and SavedPrimDoc1 to the single merged document.

### 5.14 FA_CLIENTS_TRANSLATION_STAGING v1 (from MAIN, INVOKE_MODE = INLINE)

Runs the client's STAGING_CLA_EXE_PATH executable (10-hour timeout; args include
the dated POST_ARCHIVE file path and PYTHON_KEY), then re-collects the file.

### 5.15 FA_CLIENTS_WORKERS_COMP v7 (inline from MAIN)

CLA instance `FA_CLA_WRKS_COMP` runs FA_CLIENTS_WORKERS_COMP.exe (10-hour
timeout; JSON config files workcomplist.json / workcompcustom.json; PROD/TEST
flag), then `EXEC faint.USP_B2B_CLIENTS_WORKERS_COMP_CHECK <run_id>`; if the proc
returns additions, XSLT `FA_WORKERS_COMP` tags the merged document.

### 5.16 FA_CLIENTS_DUP_CHECK v11 (inline from MAIN)

CLA instance `FA_CLA_DM_API` runs FA_DUP_CHECK_CALL.exe (10-hour timeout) against
the DM host; the StatusReport is parsed into Dup_Nodes. Specific duplicates ->
XSLT `FA_DUP_CHECK` removes those nodes from the merged document; a whole-file
duplicate -> `//DUPLICATE_FILE = 'Y'`, which MAIN's tail converts to
BATCH_STATUS = 5 and which suppresses WorkersComp / PrepCommCall / CommCall.

### 5.17 FA_CLIENTS_ADDRESS_CHECK v3 (inline from MAIN)

Unconditional: FA_PV_ADDRESS_UPDATE.exe (80-minute timeout) runs against the
archived merged file (POST_ARCHIVE dated path + FinalFileName) with the
PV_FN_ADDRESS config value and DM host; the updated file is re-collected. No
rules. Depends on PostArchive2 having extracted the file first -- which is why
MAIN forces PostArchive2's ARCHIVE to INLINE when PV_FN_ADDRESS is set.

### 5.18 FA_CLIENTS_EMAIL v24 (ASYNC from MAIN; also reused by 3 other workflows)

- Subject: EMAIL_SUBJECT (XPath-expanded) or a default built from CLIENT_NAME and
  the run date; a literal 'TEST ' prefix is added whenever
  `DATABASE_SERVER != 'AVG-PROD-LSNR'`.
- Attachment mode (PROCESS_TYPE contains 'EMAIL'): single FSA document or a loop
  over SavedPrimDoc{n}, each built into MIME with attachment = true.
- Body mode (EMAIL_XSLT set): client-configured XSLT renders ProcessData into an
  HTML body.
- Send: SMTP_SEND_ADAPTER, host `frostarnett-com01c.mail.protection.outlook.com`
  port 25, sender `datahelp@frost-arnett.com` (hardcoded), MAIL_TO / MAIL_CC from
  client config. onFault -> EmailOnError (ASYNC).

### 5.19 FA_CLIENTS_ETL_CALL v1 (per-client ETL path; dispatched by GET_LIST)

Same BATCH_STATUS INSERT shape as MAIN (4-column, PARENT_ID). Its WAIT? gate
differs from MAIN's: it polls while `Ready = -999 OR Ready != 3` -- it proceeds
**only** when the predecessor reached exactly 3, and its poll SELECT has no
-2 -> -1 CASE. A predecessor finishing at -1, -2, 4, or 5 therefore leaves this
workflow polling at 1-second intervals indefinitely (section 9.5). The ETL itself:
CLA instance `FA_PERVASIVE_ETL` (authentication = Yes) runs Pervasive Cosmos9
`djengine.exe -mf` with `//Settings/Values/MARCOS_PATH` and the client's ETL_PATH.
Success writes BATCH_STATUS = 1 (a value MAIN never writes); onFault writes -1
and invokes EmailOnError. Neither write sets FINISH_DATE, unlike MAIN.

### 5.20 FA_CLIENTS_JIRA_TICKETS v4 (scheduled top-level)

GET_SETTINGS, timestamp, then FA_JIRA_TICKETS_API_V2.exe (2-minute timeout)
against the DM host -- the exe converts open TICKETS rows into Jira tickets. Then
a summary SELECT over the last hour of `ETL.tbl_B2B_CLIENTS_TICKETS` joined to
`ETL.tbl_B2B_CLIENTS_ACCTS` (A.ACCT_ID = B.ID; SUM(BALANCE)); if any rows,
EMAIL is inline-invoked with EMAIL_XSLT forced to `FA_JIRA_TICKETS_SUMMARY` and
MAIL_TO forced to datahelp@frost-arnett.com. onFault -> EmailOnError.

### 5.21 FA_CLIENTS_GROUP_KEYS_SP v2 (scheduled top-level)

Single operation: `EXEC FAINT.USP_B2B_CLIENTS_GROUP_KEYS` (query_type =
PROCEDURE).

### 5.22 FA_CLIENTS_TABLE_INSERT v2 / FA_CLIENTS_TABLE_PULL v1 (orphaned)

TABLE_INSERT: single JDBC INSERT into `INTEGRATION.ETL.tbl_B2B_CLIENTS_OUTPUT_FILES`
(6 positional values: CLIENT_ID, SEQ_ID, RUN_ID, filename, the document content as
a binary stream via paramtype BinaryStreamFromDocument, date). TABLE_PULL: SELECT
`XML_FILE` from `etl.tbl_B2B_CLIENTS_MERGED_FILES` by run_id, promote to
PrimaryDocument, rename with the merged-output convention (note: this copy maps
PROCESS_TYPE 'TRANSACTION' -> '.PAY', an older vocabulary than MAIN's 'PAYMENT').
**Neither workflow is referenced anywhere in the 429-file corpus** and both are
dormant -- orphan candidates (section 9.3).

### 5.23 Client-328 wrappers (4 active FA_CLIENTS + Pattern-3 pair)

CNSMR_ACCNT_AR_IB_BDEO_S2X_BDL (SEQ_ID 5), CNSMR_TAG_IB_BDEO_S2X_BDL (SEQ_ID 4),
INVALID_ACCOUNTS_OB_EOBD_D2S_RPT (SEQ_ID 25), REMIT_DATA_VERIFICATION (SEQ_IDS 22),
FA_FROM_CLIENTS_FTP_FILES_LIST_IB_D2S_RC (SEQ_ID 12), _RC_ARC (SEQ_ID 13): all
standard wrappers for CLIENT_ID 328.

---

## 6. Invocation mechanisms (three plus one)

| Mechanism | Where seen | WF_INST_S visibility |
|---|---|---|
| `InlineInvokeBusinessProcessService` participant | 361 wrappers -> GET_LIST; MAIN -> GET_DOCS, PREP_SOURCE, TRANS, FILE_MERGE, POST_TRANSLATION, WORKERS_COMP, DUP_CHECK, ADDRESS_CHECK, PREP_COMM_CALL, COMM_CALL; ENCOUNTER_LOAD -> ENCOUNTER_ID; JIRA_TICKETS -> EMAIL | None (shares parent instance) -- structural inference; 6E confirms |
| `InvokeBusinessProcessService` + INVOKE_MODE = INLINE | MAIN -> ARCHIVE (PreArchive site), ACCOUNTS_LOAD (both sites), TRANSLATION_STAGING; PostArchive2's ARCHIVE when PV_FN_ADDRESS set | Unverified whether identical to the inline participant -- 6E question |
| `InvokeBusinessProcessService` + INVOKE_MODE = ASYNC | MAIN -> VITAL (x2), ENCOUNTER_LOAD (x2), ARCHIVE (PostArchive site; PostArchive2 default), EMAIL; all EmailOnError faults | Own WF_INST_S row |
| `InvokeBusinessProcessService`, **no INVOKE_MODE** | GET_LIST -> MAIN / ETL_CALL; GET_LIST onFault -> EmailOnError | Sterling default; children observed as own rows -- default semantics to pin down in 6E |
| Compression Service `decompress_result = start_bpml` | PREP_SOURCE -> ARCHIVE | Unknown -- 6E |

## 7. Integration DB surface (from BPML source only)

### 7.1 Tables written or read

| Table | Access | By |
|---|---|---|
| INTEGRATION.ETL.tbl_B2B_CLIENTS_BATCH_STATUS | INSERT / SELECT / UPDATE | GET_LIST, MAIN, ETL_CALL, COMM_CALL |
| Integration.etl.tbl_B2B_CLIENTS_BATCH_FILES | INSERT (direct); probable map target | GET_DOCS (zero-size path); FA_CLIENTS_BATCH_FILES_X2S map (hypothesis) |
| etl.tbl_B2B_CLIENTS_FILES | UPDATE RUN_FLAG = 0 | GET_LIST |
| ETL.tbl_B2B_CLIENTS_TICKETS | INSERT (fault paths); SELECT | MAIN, GET_LIST; JIRA_TICKETS |
| ETL.tbl_B2B_CLIENTS_ACCTS | SELECT (join) | JIRA_TICKETS |
| INTEGRATION.ETL.tbl_B2B_CLIENTS_OUTPUT_FILES | INSERT (with file blob) | TABLE_INSERT (orphaned) |
| etl.tbl_B2B_CLIENTS_MERGED_FILES | SELECT XML_FILE | TABLE_PULL (orphaned) |
| Integration.dbo.FAI_FILE_ID | SELECT / UPDATE (CTR_3, CTR_4) | ENCOUNTER_ID |
| etl.tbl_ENOTICE_TO_REVSPRING_VALDN(_ARC) | INSERT-SELECT | FA_DM_ENOTICE_ARCHIVE (6F) |

Known BATCH_STATUS columns from source: CLIENT_ID, SEQ_ID, RUN_ID, PARENT_ID,
BATCH_STATUS, FINISH_DATE, BATCH_ID.

### 7.2 Stored procedures (all schema `faint` on the Integration pool)

USP_B2B_CLIENTS_GET_SETTINGS; USP_B2B_CLIENTS_GET_LIST (CLIENT_ID, SEQ_ID,
SEQ_IDS, PROCESS_TYPE, SEQUENTIAL); USP_B2B_CLIENTS_WORKERS_COMP_CHECK (run_id);
USP_B2B_CLIENTS_GROUP_KEYS; USP_FA_JACK_HUGHSTON_IB_EO_ENC_UPD (6F). Note the
schema split: procs live in `faint` while the tables live in `etl` (plus
`dbo.FAI_FILE_ID`). (Corrected during 6D: an earlier draft of this section
claimed the legacy docs placed the procs in `etl`; the ArchitectureOverview in
fact records `faint`, agreeing with source.)

### 7.3 BATCH_STATUS value vocabulary (writer-verified)

| Value | Writer | Meaning |
|--:|---|---|
| -2 | MAIN tail (when Ready = -1) | Skipped: predecessor in SEQUENTIAL chain failed |
| -1 | MAIN / GET_LIST / ETL_CALL onFault | This run faulted |
| 1 | ETL_CALL success | ETL complete |
| 2 | GET_LIST tail; MAIN tail | GET_LIST: dispatch complete. MAIN: processed (BDL always; NB/PAYMENT with files, no dup) |
| 3 | MAIN tail | Processed, other process types (files, no dup) |
| 4 | MAIN tail | No files |
| 5 | MAIN tail | Duplicate file |

The poll SELECT in MAIN presents -2 as -1 to downstream chain members (cascade
propagation); ETL_CALL's poll does not.

The merged-output filename (MAIN preamble; ARCHIVE PostArchiveFlag = 2;
ADDRESS_CHECK; PREP_COMM_CALL DM drops):
`CLIENT_NAME(spaces->_) + '.DM.' + yyyyMMdd + '_' + <MAIN WORKFLOW_ID> +
('.NB' | '.PAY' | '.BDL' | '.') + '.txt'`.

## 8. External surface inventories

### 8.1 Command Line 2 Adapter instances

FA_CLA_DEFAULT, FA_CLA_UNPGP, FA_CLA_DM_API, FA_CLA_WRKS_COMP, FA_PERVASIVE_ETL,
CommandLineAdapter2. (Six distinct participants; instance-level config such as
target host lives in Sterling service config, not BPML.)

### 8.2 Executables and scripts (all under \\kingkong\...\Python_EXE_files\ unless noted)

| Executable | Caller | Timeout |
|---|---|---|
| FA_FILE_REMOVE_SPECIAL_CHARACTERS.exe | MAIN, PREP_SOURCE (x2 sites) | 20 min |
| FA_CLIENTS_CONVERT_XLSX2CSV.exe | PREP_SOURCE | 20 min |
| client GET_DOCS_API exe | GET_DOCS (API_PULL) | 10 h |
| client CLA_EXE_PATH exe | PREP_SOURCE | 10 h |
| client STAGING_CLA_EXE_PATH exe | TRANSLATION_STAGING | 10 h |
| client COMM_CALL_CLA_EXE_PATH exe | COMM_CALL | 10 h |
| FA_CLIENTS_WORKERS_COMP.exe (+2 JSON configs) | WORKERS_COMP | 10 h |
| FA_DUP_CHECK_CALL.exe | DUP_CHECK | 10 h |
| FA_IBM_FILE_LOCK.exe (x2: lock/unlock) | ENCOUNTER_ID | 10 h |
| FA_PV_ADDRESS_UPDATE.exe | ADDRESS_CHECK | 80 min |
| FA_PRE_DM_MERGE_CONSUMERS.exe | COMM_CALL | 1 h |
| DM_API_SPLIT.exe | COMM_CALL | 1 h |
| FA_JIRA_TICKETS_API_V2.exe | JIRA_TICKETS | 2 min |
| djengine.exe (C:\Program Files (x86)\Pervasive\Cosmos9\Common) | ETL_CALL | (default) |
| JavaTaskFS: E:\Utilities\FA_FILE_CHECK.java, FA_CONVERT_FILE_TO_CSV.java, FA_FILE_RENAME.java | GET_DOCS, PREP_SOURCE (x2) | n/a |

DM application host selection is environment-derived everywhere:
`DATABASE_SERVER = 'AVG-PROD-LSNR' -> DM-PROD-APP3, else DM-TEST-APP` (or
PROD/TEST literals for the lock and workers-comp exes).

### 8.3 Translation maps and XSLT (database writes hidden inside maps)

Maps: FA_CLIENTS_MP_VITAL (VITAL), FA_CLIENTS_X2S_ACCTS (ACCOUNTS_LOAD),
FA_CLIENTS_BATCH_FILES_X2S (GET_DOCS, PREP_COMM_CALL x2),
FA_CLIENTS_ENCOUNTER_LOAD_D2S (ENCOUNTER_LOAD), plus client-configured
TRANSLATION_MAP / PREP_TRANSLATION_MAP / POST_TRANSLATION_MAP / ENCOUNTER_MAP.
XSLT: FA_FILE_MERGE, FA_PAYMENT_NODE_COUNTER, FA_DUP_CHECK, FA_WORKERS_COMP,
FA_JIRA_TICKETS_SUMMARY, plus client-configured EMAIL_XSLT.

### 8.4 Settings values consumed (from USP_B2B_CLIENTS_GET_SETTINGS)

DATABASE_SERVER, DEF_POST_ARCHIVE, DM_NB_PATH, DM_PAY_PATH, DM_BDL_PATH,
API_PORT, PYTHON_KEY, MARCOS_PATH.

### 8.5 Client config fields consumed (the CLIENTS work-queue row surface)

Identity/flow: CLIENT_ID, SEQ_ID, PREV_SEQ, CLIENT_NAME, PROCESS_TYPE,
BUSINESS_TYPE, COMM_METHOD, SEQUENTIAL.
Acquisition: GET_DOCS_TYPE, GET_DOCS_LOC, GET_DOCS_PROFILE_ID, GET_DOCS_DLT,
GET_DOCS_API, GET_EMPTY_DOCS, FILE_FILTER, CUSTOM_FILE_FILTER, FILE_ID.
Preparation: PREPARE_SOURCE, PGP_PASSPHRASE, UNZIP_FILTER, CONVERT_TO_CSV,
PDF_FILE, PREP_ENCODE_FROM, PREP_ENCODE_TO, FILE_RENAME, CLA_EXE_PATH,
PREP_TRANSLATION_MAP, SQL_QUERY, PRE_SQL_QUERY, PRE_KEYWORD_REPLACE_FROM/_TO,
FILE_CLEAN_UP, MISC_REC1.
Translation/merge: TRANSLATION_MAP, POST_TRANSLATION, POST_TRANSLATION_MAP,
POST_TRANSLATION_VITAL, POST_TRANSLATION_OVERWRITE, POST_TRANS_SQL_QUERY,
POST_TRANS_FILE_RENAME, POST_KEYWORD_REPLACE_FROM/_TO, TRANSLATION_STAGING,
STAGING_CLA_EXE_PATH, SEND_EMPTY_FILES, SQL_QUERY_DATA_SOURCE.
Archival: PRE_ARCHIVE, POST_ARCHIVE.
Tail: DUP_CHECK, WORKERS_COMP, ENCOUNTER_MAP, PV_FN_ADDRESS, COMM_CALL,
PREPARE_COMM_CALL, COMM_CALL_SQL_QUERY, COMM_CALL_CLA_EXE_PATH,
COMM_CALL_WORKING_DIR, AUTO_RELEASE, DM_BATCH_SPLIT, PRE_DM_MERGE, ETL_PATH.
Delivery/email: PUT_DOCS_TYPE, PUT_DOCS_LOC, PUT_DOCS_PROFILE_ID, MAIL_TO,
MAIL_CC, EMAIL_SUBJECT, EMAIL_XSLT.

**Four fields carry arbitrary SQL executed verbatim** (SQL_QUERY, PRE_SQL_QUERY,
POST_TRANS_SQL_QUERY, COMM_CALL_SQL_QUERY) and **four carry executable paths**
(GET_DOCS_API, CLA_EXE_PATH, STAGING_CLA_EXE_PATH, COMM_CALL_CLA_EXE_PATH).
PGP_PASSPHRASE is stored in config and passed as a plaintext process argument.

## 9. Defects, dead code, and hazards found in source

1. **Dead rules (4):** MAIN `SaveDoc?`; GET_LIST `UpdateRunFlag?`; VITAL `NB?`;
   ACCOUNTS_LOAD `NB?`. Defined, never referenced by any case.
2. **`PostArchive?` tautology** (section 4.3): post-archive fires regardless of
   POST_ARCHIVE = 'N'; downstream extraction folder would begin with literal 'N'.
3. **Orphaned workflows (2):** TABLE_INSERT, TABLE_PULL -- dormant and referenced
   by nothing in the corpus.
4. **TICKETS insert column-count contradiction:** MAIN's fault insert writes 10
   positional values; GET_LIST's writes 9, against the same table with no column
   list. At most one matches the table; the other fails whenever it fires --
   meaning one of the two fault paths has a broken ticket insert (and, since the
   insert precedes EmailOnError inside the fault sequence, possibly a suppressed
   fault email as well, depending on Sterling fault-in-fault behavior). High-value
   Step 6E check: TICKETS column count, and whether ticket rows exist for
   GET_LIST-origin faults.
5. **ETL_CALL infinite-poll hazard:** its wait gate releases only on predecessor
   status exactly 3, and its poll lacks the -2 -> -1 CASE. Predecessor outcomes
   -1, -2, 4 (no files), and 5 (duplicate) leave it polling at 1-second intervals
   with no timeout in BPML. Whether Sterling-level lifecycle controls bound this
   is a 6E question; as authored, a no-files predecessor stalls the ETL chain.
6. **Wait?/Continue? XPath parenthesization quirk** (section 4.2): functionally
   equivalent, flagged so it is not copied as a pattern.
7. **Vocabulary drift:** TABLE_PULL maps 'TRANSACTION' -> '.PAY' where MAIN maps
   'PAYMENT' -- evidence of an older process-type vocabulary in the orphaned pair.
8. **Naming inconsistency:** PREP_COMM_CALL's rule `OutBoundSFTP` lacks the
   family's '?' suffix convention. Cosmetic.

## 10. ArchitectureOverview: interim agreement notes (full resolution in 6D)

Agreements verified from source: MAIN v48 read as the orchestrator; rule names and
general pipeline order; GET_DOCS 10-hour API timeout; `.trans` per-file archives
vs merged-file archives; onFault -> BATCH_STATUS -1 + TICKETS + EmailOnError;
Wait?/Continue? band semantics (0-2 wait / 3-5 continue); USP_B2B_CLIENTS_GET_LIST
and GET_SETTINGS as the queue/settings procs.

Corrections established from source: rule count is 23 defined / 22 live, not ~22
live; -2 is MAIN's own cascade-skip write, not a legacy code path; dispatch
patterns collapse to one wrapper shape (parameter profiles differ, mechanism does
not); GET_LIST is inline everywhere it is workflow-invoked; procs live in schema
`faint`, not `etl`; ARCHIVE has four call sites (including PREP_SOURCE via
Compression Service), not three; ARCHIVE reads caller-set flags, not client
config; JIRA_TICKETS exists and is a first-class scheduled member of the family.

## 11. Resolved questions (from Roadmap section 5.15 and Step 6A)

1. **GET_LIST shortfall (85 vs ~242 expected):** resolved structurally -- all 367
   workflow-side invocations are inline and produce no WF_INST_S rows; standalone
   rows can only be scheduler fires. Runtime confirmation of the schedule: 6E.
2. **ARCHIVE zero-failure behavior:** consistent with its trivial two-extract
   shape and flag gating; failure surface is FS_EXTRACT only.
3. **JIRA_TICKETS role:** hourly-scale conversion of TICKETS rows into Jira
   tickets plus a summary email; part of the fault pipeline.
4. **How FILE_DELETION works:** GET_DOCS ZeroSize path -- remote delete/move
   without pickup, logged directly to BATCH_FILES.
5. **Whether MAIN has other entry points:** no -- GET_LIST is its only caller.

## 12. New open questions (mostly Step 6E targets)

1. Do the two inline mechanisms (participant vs INVOKE_MODE = INLINE) and the
   Compression start_bpml path differ in WF_INST_S / WORKFLOW_CONTEXT visibility?
2. What is Sterling's default INVOKE_MODE for InvokeBusinessProcessService when
   unspecified (GET_LIST -> MAIN), and what parent/child linkage does it record
   in WORKFLOW_LINKAGE?
3. tbl_B2B_CLIENTS_TICKETS column count (resolves the 9-vs-10 contradiction), and
   whether GET_LIST-origin fault tickets exist.
4. Does POST_ARCHIVE = 'N' with files present occur, and where do the resulting
   ARCHIVE extracts land?
5. Do ETL_CALL stalls occur (long-running instances; predecessor status 4/5)?
6. What tables do the four fixed maps write (MP_VITAL, X2S_ACCTS,
   BATCH_FILES_X2S, ENCOUNTER_LOAD_D2S)? Map internals are not in b2bi BPML.
7. What schedules exist for GET_LIST, JIRA_TICKETS, GROUP_KEYS_SP, the client-328
   wrappers, and the 361 dispatchers (SI_ScheduleRegistry cross-reference)?
8. ENCOUNTER_LOAD 6.1% failures: which surface (maps, allocator, lock exe)?
9. Does the FILELIST/SIZE append in TRANS (count of VITAL transactions, not
   bytes) interact correctly with PREP_COMM_CALL's EmptyFiles? gate, which reads
   it as a size?

## Document status

| Attribute | Value |
|---|---|
| Step | 06C -- Core Workflow BPML Analysis |
| Status | **Complete** |
| Coverage | All 28 FA_CLIENTS BPMLs deep-read; all 371 wrapper-family BPMLs shape-verified; 10 non-standard flagged for 6F |
| Next | Step 6D -- Claim Verification against ArchitectureOverview |
| Roadmap impact | Section 5.6: 6C complete. Section 4: new Known True entries (execution model, wrapper census, BATCH_STATUS vocabulary, invocation mechanisms). Section 5.8 (dispatchers): resolved structurally. Section 5.15: several questions resolved, new 6E targets added. |

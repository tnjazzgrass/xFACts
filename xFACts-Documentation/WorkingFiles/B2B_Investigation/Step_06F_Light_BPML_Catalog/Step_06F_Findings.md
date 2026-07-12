# Step 6F Findings -- Light BPML Catalog

**Date:** 2026-07-10
**Investigation folder:** `xFACts-Documentation/WorkingFiles/B2B_Investigation/Step_06F_Light_BPML_Catalog/`
**Input corpus:** the 429-file Step 6B extraction

## Purpose

Catalog everything outside the FA_CLIENTS deep reads of Step 6C: the 10
non-standard wrapper-family workflows, the Sterling infrastructure families
(Schedule, Sterling_Infra, FileGateway, AFT, Other), and the business-label
(suffix) axis of the standard wrapper population. Executed ahead of Step 6E --
the two steps are independent inputs to 6G; 6F is BPML-side only.

Note: with 6F complete, every one of the 429 BPMLs in the corpus has now been
either deep-read (6C), shape-verified as a standard wrapper (6C census), or
catalogued here. No file remains unexamined.

## 1. Summary of change

1. **Two additional standard wrappers found outside the FA families.**
   FILE_REMOVE_VANDERBILT_NEWLIGHT (CLIENT_ID 522, SEQ_IDS '5,6', SEQUENTIAL)
   and GG_TEST_BP (CLIENT_ID 10670, SEQ_IDS '10,11', SEQUENTIAL) are the same
   2-operation AssignService + inline GET_LIST shape. This closes the
   arithmetic exactly: 367 corpus references to GET_LIST = 361 FA-family
   wrappers + 4 client-328 FA_CLIENTS wrappers + these 2. **The standard
   wrapper population is 367, fully enumerated, zero unexplained references.**
   GG_TEST_BP is a test harness pointed at a live client id in production --
   flagged for operational review.
2. **FA_DM_ENOTICE is a second MAIN-like pipeline** (Reg-F letters to
   RevSpring), self-contained rather than GET_LIST-dispatched: it synthesizes
   its own Client config in ProcessData and reuses GET_DOCS / ARCHIVE / VITAL /
   EMAIL. It carries its own proc set (three new faint procs), tables, maps,
   XSLTs, and a generic SQL-runner executable.
3. **A shared fault-handling defect** in FA_DM_ITS_REQST and
   FA_DM_INCEPTION_HOLD_TAG: both UPDATE BATCH_STATUS = -1 on fault for their
   own RUN_ID, but neither ever INSERTs a BATCH_STATUS row -- the fault write
   is a silent no-op and the failure is invisible to the Integration side
   (EmailOnError still fires).
4. **Seventh Command Line 2 Adapter instance** found: FA_CLA_CCI_SFTP_FILE_LIST.
5. **Sterling infrastructure catalogued**: 17 Schedule_* maintenance BPs, 7
   Sterling_Infra BPs (including EmailOnError's actual anatomy and
   AlertNotification's YFS_USER recipient lookup), 2 FileGateway listeners,
   1 mailbox purge.
6. **Wrapper suffix census**: 94 distinct suffix-code combinations across the
   367 wrappers; direction split FROM 103 / TO 223 / DM 1 / other 34 (within
   the FA-family 361). Confirms 6C's conclusion that suffixes are business
   labels only -- no structural variation accompanies any suffix.

## 2. The 10 non-standard wrapper-family workflows

### 2.1 FA_DM_ENOTICE v36 (Reg-F letter pipeline; 45 runs/30d)

The largest non-FA_CLIENTS workflow (47 operations). A self-contained pipeline
that does NOT go through GET_LIST -- it fabricates its own //Result/Client
block in ProcessData:

- GET_DOCS_TYPE = SFTP_PULL; GET_DOCS_LOC = 'integration_process' (prod) /
  'test'; FILE_FILTER = `integration_process*TTFROS*NOTICEFILE.xml.gzip*`;
  PRE/POST_ARCHIVE = `\\kingkong\dpbackup\Client_Data_Archive\Inbound\integration_process`;
  COMM_METHOD = OUTBOUND; failure email preset (XSLT FA_ENOTICE_FAILURE to
  datahelp + applications).
- Reuses FA_CLIENTS components: GET_DOCS (inline), ARCHIVE (INVOKE_MODE =
  INLINE, PreArchiveFlag = 1), VITAL (ASYNC, TRANS_TYPE = 'Other'), EMAIL
  (inline for summary; ASYNC in onFault).
- Per-file processing: FA_FILE_TOOL_GZ2X.exe gunzip (1h timeout) -> re-collect
  -> map FA_TR_X2X_APPS_TO_RS_NOTICES -> validation map
  FA_TR_X2S_APPS_TO_RS_NOTICES_VALIDATION (DB write inside map) ->
  **FA_CLIENTS_SQL_RETURN.exe** running
  `EXEC Integration.faint.USP_ENOTICE_VALIDATION_RMV <run_id>,'<file>'`
  (a generic SQL-runner executable -- new external-surface category) ->
  XSLT FA_ENOTICE_FILTER drops filtered accounts -> document re-enveloped as
  CR Software Titanium `notice-job` -> maps FA_REVSPRING_NOTICES_OB_S2X_PHONE
  and FA_REVSPRING_NOTICES_OB_X2X_PHONE_LOOKUP -> FS_EXTRACT as
  `<file>_<run_id>.xml` -> `EXEC faint.USP_ENOTICE_VALIDATION ?,?` gate:
  Valid -> re-gzip (GZ2X in GZIP mode); NotValid -> failure email path.
- Delivery: GET_DOCS again to collect produced files, then SFTP PUT loop to
  PUT_DOCS_PROFILE_ID / PUT_DOCS_LOC (RevSpring).
- Summary email: a large CTE query over
  `Integration.ETL.tbl_ENOTICE_TO_REVSPRING_VALDN` joined to
  `tbl_ENOTICE_TO_REVSPRING_LTR_TXT_CROSSWALK` (letter/SMS crosswalk),
  rendered via XSLT FA_ENOTICE_SUMMARY; then
  `EXEC faint.USP_ENOTICE_DM_CANCELLATION`.
- onFault: TICKETS insert (10-value shape, matching MAIN's) with hardcoded
  environment-dependent identity **CLIENT_ID 235 (prod) / 10221 (test),
  SEQ_ID 8, name 'Reg-F Letters'** -- two more internal entity ids for the 6E
  CLIENTS_MN check -- then EMAIL (ASYNC) with name 'FAIL - Reg-F Letters'.

New surface from this workflow alone: procs faint.USP_ENOTICE_VALIDATION,
USP_ENOTICE_VALIDATION_RMV, USP_ENOTICE_DM_CANCELLATION; tables
tbl_ENOTICE_TO_REVSPRING_VALDN, tbl_ENOTICE_TO_REVSPRING_LTR_TXT_CROSSWALK
(plus _ARC via the companion below); exes FA_FILE_TOOL_GZ2X.exe,
FA_CLIENTS_SQL_RETURN.exe; XSLTs FA_ENOTICE_FILTER, FA_ENOTICE_FAILURE,
FA_ENOTICE_SUMMARY; maps FA_TR_X2X_APPS_TO_RS_NOTICES,
FA_TR_X2S_APPS_TO_RS_NOTICES_VALIDATION, FA_REVSPRING_NOTICES_OB_S2X_PHONE,
FA_REVSPRING_NOTICES_OB_X2X_PHONE_LOOKUP.

### 2.2 FA_DM_ENOTICE_ARCHIVE v1

Single JDBC operation:
`insert into etl.tbl_ENOTICE_TO_REVSPRING_VALDN_ARC select *, getdate() from
ETL.tbl_ENOTICE_TO_REVSPRING_VALDN (nolock);`
Companion archiver for 2.1. Note the NOLOCK on a source being archived and the
absence of any delete/trim of the source -- whether the source is trimmed by a
proc elsewhere is an Integration-side question (6E item R16).

### 2.3 FA_DM_ITS_REQST v8 (13 ops)

DM-to-ITS request pipeline: fabricates Client config (SFTP_PULL from
integration_process, filter `integration_process.DM-*ESmt1_*-NOTICEFILE.xml.gzip*`),
GET_DOCS inline, per file: ARCHIVE (INLINE) -> GZ2X gunzip (via FA_CLA_DM_API)
-> re-collect -> map FA_TR_X2S_REQST_FROM_DM (DB write inside map); post-loop:
FA_ITS_API_CALLS.exe (10h timeout) against the DM host.
**Defect:** onFault runs `UPDATE ... BATCH_STATUS = -1 WHERE RUN_ID = ?` but
the workflow never inserts a BATCH_STATUS row -- the update matches nothing.
Fault visibility is EmailOnError only.

### 2.4 FA_DM_INCEPTION_HOLD_TAG v2 (4 ops)

GET_SETTINGS + FA_INCEPTION_ACCTS_HOLD_TAG.exe (1h, DM host). Same no-op
onFault BATCH_STATUS defect as 2.3.

### 2.5 FA_CCI_SFTP_FILE_LIST_EMAIL v3 (5 ops)

GET_SETTINGS -> FA_CCI_SFTP_FILES_LIST.exe via dedicated adapter instance
**FA_CLA_CCI_SFTP_FILE_LIST** (seventh CLA participant) -> EMAIL inline with
XSLT FA_CCI_SFTP_FILE_LIST_EMAIL to datahelp. No onFault.

### 2.6 FA_CUSTOM_INT_CONSUMER_ACCOUNTS_MERGE_CLA v2 (2 ops)

GET_SETTINGS + FA_CONSUMER_ACCOUNTS_MERGE.exe (timeout 15,000,000 ms ~ 4.2h,
DM host). No onFault, no BATCH_STATUS.

### 2.7 The single-op exe/proc runners

| Workflow | Payload |
|---|---|
| FA_FROM_PAYGROUND_ALL_CLIENTS_IB_EO_REPORTS_PULL | FA_PAYGROUND_ALL_CLIENTS_IB_EO_REPORTS_PULL.exe PROD (env hardcoded as a literal, not derived from DATABASE_SERVER) |
| FA_TO_PAYGROUND_ALL_CLIENTS_OB_EO_S2J_RPT | FA_PAYGROUND_ALL_CLIENTS_OB_EO_S2J_RPT.exe PROD (same hardcoding) |
| FA_JACK_HUGHSTON_IB_EO_ENC_UPD_SP | EXEC FAINT.USP_FA_JACK_HUGHSTON_IB_EO_ENC_UPD |
| FA_ULS_TO_VISPA_OB_PY | FA_UNLIMITED_SYSTEMS_SFTP_PULL_AND_PUSH.exe (no args at all -- config presumably internal to the exe) |

The PAYGROUND pair's hardcoded 'PROD' literal diverges from the family's
DATABASE_SERVER-derived environment selection -- these would hit production
even if promoted from a test Sterling instance. Flag for operational review.

## 3. Infrastructure families (light catalog)

### 3.1 07_Schedule (17 BPs -- Sterling-shipped maintenance)

All are vendor maintenance processes, most wrapped in SystemLockService with
SMTP failure notifications and onFault blocks:

AssociateBPsToDocs, AutoTerminateService (10 ops; includes UserService),
BPExpirator, BPLinkagePurgeService, BPRecovery, BackupService,
CheckExpireService, DocumentStatsArchive, IWFCDriverService (queries
`OPS_NODE_INFO where NODE_STATUS = 200`), IndexBusinessProcessService,
MessagePurge, PartialDocumentCleanUpService, PerfDataPurgeService,
ProducedMsgPurgeService, PurgeService (the Step-2 retention driver),
SAPTidCleaner, Scheduled_AlertService.

No FAC customization detected in any of them (consistent with the 6B
observation that vendor BPMLs carry comment prologues). Catalog-level
treatment is sufficient; none touch Integration.

### 3.2 08_Sterling_Infra (7 BPs)

| BP | Role (from source) |
|---|---|
| EmailOnError (8 ops) | The family-wide fault mailer: BPMetaDataInfoService pulls failing-BP metadata, CompressionService packages it, MailMimeService + SMTP send. This is what every FA_CLIENTS onFault invokes. |
| AlertNotification | Queries YFS_USER / YFS_USER_GROUP for recipient LOGINIDs, XMLEncoder + SMTP -- Sterling's alert fan-out. |
| Alert | AlertService under SystemLockService. |
| Recover.bpml (15 ops) | BP recovery machinery (BPMark/BPReport/BPStart/BPStateFilter/CleanLock services). |
| TimeoutEvent | Single EventService op -- the Tier-2 high-frequency heartbeat seen in 6A. |
| CheckActiveSessionService | Single service op. |
| CheckExpireCertsEmailNotif | Cert-expiry email (XSLT + SMTP). |

### 3.3 09_FileGateway / 11_AFT / 12_OTHER

FileGatewayListeningProducer and FileGatewayReroute: single-service listeners
(consistent with Step 1's finding that SFG is effectively unused).
AFTPurgeArchiveMailboxes: JDBC over MBX_MESSAGE/MBX_MAILBOX + MailboxDelete.
RestoreService: vendor restore under SystemLockService.
FILE_REMOVE_VANDERBILT_NEWLIGHT and GG_TEST_BP: standard GET_LIST wrappers
(section 1.1).

## 4. Wrapper suffix census (business-label axis)

Across the 361 FA-family standard wrappers: 94 distinct suffix-code
combinations. Direction prefixes: FA_TO 223, FA_FROM 103, FA_DM 1, other 34.
Top combinations: IB BD PULL (37), OB BD S2D RM (27), OB BD (25),
OB BD S2D NT (22), OB BD S2D (21), OB BD S2D RT (18), IB BD SFTP PULL (13),
OB BD RM (13). Full distribution reproducible from the corpus via the census
script; not tabulated further here because the suffix carries no structural
signal (6C s3) -- its value is as a grouping label for future CC presentation,
which is a design-phase concern.

## 5. New surface added to the platform inventories

Combining with Step_06C_Findings sections 7-8:

- **Procs (faint):** + USP_ENOTICE_VALIDATION, USP_ENOTICE_VALIDATION_RMV,
  USP_ENOTICE_DM_CANCELLATION, USP_FA_JACK_HUGHSTON_IB_EO_ENC_UPD.
- **Tables:** + etl.tbl_ENOTICE_TO_REVSPRING_VALDN, _VALDN_ARC,
  _LTR_TXT_CROSSWALK; b2bi-side OPS_NODE_INFO, YFS_USER/_GROUP,
  MBX_MESSAGE/MBX_MAILBOX (vendor).
- **CLA instances (now 7):** + FA_CLA_CCI_SFTP_FILE_LIST.
- **Executables:** + FA_FILE_TOOL_GZ2X.exe, FA_CLIENTS_SQL_RETURN.exe (generic
  SQL runner), FA_ITS_API_CALLS.exe, FA_INCEPTION_ACCTS_HOLD_TAG.exe,
  FA_CCI_SFTP_FILES_LIST.exe, FA_CONSUMER_ACCOUNTS_MERGE.exe,
  FA_PAYGROUND_*.exe (x2), FA_UNLIMITED_SYSTEMS_SFTP_PULL_AND_PUSH.exe.
- **XSLT:** + FA_ENOTICE_FILTER, FA_ENOTICE_FAILURE, FA_ENOTICE_SUMMARY,
  FA_CCI_SFTP_FILE_LIST_EMAIL.
- **Maps:** + FA_TR_X2X_APPS_TO_RS_NOTICES,
  FA_TR_X2S_APPS_TO_RS_NOTICES_VALIDATION, FA_REVSPRING_NOTICES_OB_S2X_PHONE,
  FA_REVSPRING_NOTICES_OB_X2X_PHONE_LOOKUP, FA_TR_X2S_REQST_FROM_DM.
- **Internal entity ids:** + 235 (prod) / 10221 (test) 'Reg-F Letters';
  522 (VANDERBILT_NEWLIGHT file remove); 10670 (GG_TEST_BP).

## 6. Defects and flags found in 6F

1. **No-op fault status writes** in FA_DM_ITS_REQST and
   FA_DM_INCEPTION_HOLD_TAG (UPDATE for a never-inserted RUN_ID row).
2. **GG_TEST_BP**: a test wrapper live in production, pointed at CLIENT_ID
   10670 SEQ_IDS 10,11 -- operational review candidate.
3. **PAYGROUND pair hardcodes 'PROD'** instead of deriving environment from
   DATABASE_SERVER.
4. **ENOTICE_ARCHIVE** copies with NOLOCK and never trims its source (trim
   location unknown -- 6E item R16).

## 7. New 6E items raised by 6F

| # | Target |
|---|---|
| R16 | Is tbl_ENOTICE_TO_REVSPRING_VALDN trimmed anywhere (proc/job), or does ENOTICE_ARCHIVE duplicate a growing table? |
| R17 | CLIENTS_MN identities for 235/10221, 522, 10670; confirm GG_TEST_BP's schedule/trigger status |
| R18 | Do ITS_REQST / INCEPTION_HOLD_TAG faults appear anywhere besides EmailOnError (given the no-op status write)? |

## Document status

| Attribute | Value |
|---|---|
| Step | 06F -- Light BPML Catalog |
| Status | **Complete** |
| Coverage | 429/429 corpus files now deep-read, shape-verified, or catalogued |
| Sequencing note | Executed ahead of 6E (independent inputs to 6G) |
| Next | Step 6E -- Runtime Verification (query pack R1-R18) |
| Roadmap impact | Section 5.6: 6F complete (out of order, noted). Wrapper population finalized at 367. New inventories merged into the 6C surface lists. Three new 6E items (R16-R18). |

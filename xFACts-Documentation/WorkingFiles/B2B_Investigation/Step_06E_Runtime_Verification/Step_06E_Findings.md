# Step 6E Findings -- Runtime Verification

**Date:** 2026-07-10
**Investigation folder:** `xFACts-Documentation/WorkingFiles/B2B_Investigation/Step_06E_Runtime_Verification/`
**Inputs:** Query pack results R0-R18 (run by Dirk against AVG-PROD-LSNR and FA-INT-DBP, through R8); BPML corpus cross-checks

## Purpose

Resolve the runtime/Integration-side questions accumulated from Steps 6C, 6D,
and 6F against production data. Status: all but four items resolved; the four
follow-ups are packaged in `Step_06E_Followup_Queries.sql` (single-server
blocks -- see Process note at the end).

## 1. Summary of change

1. **The GET_LIST work-queue definition is now fully known** (proc source
   read): Branch 1/2 semantics, AUTOMATED meanings, PREV_SEQ LAG computation,
   the discovered-files feed, and the 68-parameter pivot are all confirmed --
   with several corrections and two new anomalies.
2. **ETL_CALL is confirmed dead**: the proc's ETLAP block was commented out
   with the note "DISABLING ETLAP 08/26/2024"; ETL_PATH exists nowhere as a
   column (it was pivot-derived from PARAM keys + an ATLAS-DB ETLAP lookup);
   and zero BATCH_STATUS = 1 rows exist in the table's entire history.
   Checklist 1.8: VERIFIED (deprecated in effect since 2024-08-26).
3. **The TICKETS 9-vs-10 contradiction is resolved -- and it is a confirmed
   live production bug.** F1 verified ID is an identity column, so a
   positional insert must supply exactly 10 values: MAIN's insert fits,
   GET_LIST's 9-value insert cannot succeed against the current 11-column
   table. The monthly flow confirms the breakage window: GET_LIST-origin
   tickets appear in 2025-06 (2) and 2025-08 (6), then **zero from 2025-09
   through the present**, while MAIN-origin tickets flow continuously
   (roughly 1,000-2,000/month). Conclusion: the CLIENT_KEY column was added
   between 2025-08-23 and the next GET_LIST fault, and **every GET_LIST
   fault since ~September 2025 has failed its ticket insert** -- and because
   the insert precedes EmailOnError inside the fault handler, those faults
   are likely entirely unreported. Remediation (operational, outside this
   investigation): add the 10th NULL to GET_LIST's insert or, better,
   column-list both fault inserts; either is a GET_LIST v20 BPML edit.
   Side observation from the same data: MAIN-origin ticket volume spikes
   hard in specific months (2026-02: 10,039; 2026-06: 6,673 vs a ~1,100
   baseline) -- fault storms the eventual collector should surface.
4. **BATCH_STATUS = 0 resolved**: the column default is ((0)) and the BPML
   INSERTs supply no status -- 0 simply means in-flight (or died with no
   fault handler). 2,113 such rows, all with NULL FINISH_DATE. The full
   observed distribution (table lifetime since 2023-11): -2: 14,114;
   -1: 23,967; 0: 2,113; 2: 148,790; 3: 914,361; 4: 603,820; 5: 6,431;
   **1: zero rows** (see item 2).
5. **Invocation-mechanism visibility model confirmed** (R1/R2): inline
   GET_LIST leaves no trace of its own; the no-INVOKE_MODE GET_LIST -> MAIN
   dispatch produces a child WF_INST_S instance plus a WORKFLOW_LINKAGE row
   with TYPE = 'Dispatch' and ROOT_WF_ID = the wrapper's WORKFLOW_ID. The
   dispatcher WORKFLOW_ID = BATCH_STATUS.RUN_ID correlation holds exactly as
   6C predicted.
6. **BATCH_FILES scope resolved** (R6): 2.48M SFTP_GET rows (only 108K
   zero-size) + 205K SFTP_PUT rows -- the FA_CLIENTS_BATCH_FILES_X2S map
   writes pickups and deliveries to this table. Checklist 2.8: CORRECTED
   stands, confirmed. No FSA_PUT rows exist (FSA pushes either do not occur
   or bypass the map -- minor note).
7. **Corpus drift is now precisely scoped** (F3 census). Three workflows
   were edited in one coordinated session on 2026-06-22 around 03:00: MAIN
   v48 -> v49 (03:08), PREP_SOURCE v34 -> v35 (03:07), TRANS v6 -> v7
   (03:01). **Two entirely new FA_CLIENTS workflows exist** that postdate
   the corpus: FA_CLIENTS_CNSMR_ACCNT_TAG_IB_BDEO_S2X_BDL (2026-06-29) and
   FA_CLIENTS_CNSMR_ACCNT_TAG_REMOVAL_IB_BDEO_S2S_SP (2026-07-01) -- the
   family is now 30 members, not 28. Everything else is unchanged since
   extraction, **including GET_LIST (still v19, untouched since
   2023-12-05)**. F4 re-extraction is now scoped to five files: the three
   drifted plus the two new.
8. **The dispatcher-status anomaly is RESOLVED -- a fifth BATCH_STATUS
   writer exists, and it changes the vocabulary's meaning.** SQL Agent job
   "INT Clients Update Batch Status" runs
   `FAINT.USP_B2B_CLIENTS_UPDATE_BATCH_STATUS` (no proc callers; job-only),
   which promotes rows sitting at BATCH_STATUS = 2 based on **DM-side
   outcomes read from crs5_oltp**:
   - NEW_BUSINESS: joins `new_bsnss_btch` on BATCH_ID =
     new_bsnss_btch_shrt_nm; stts_cd 8 -> 3; stts_cd 5 or 3
     (deleted/failed) -> -1.
   - PAYMENT: joins `cnsmr_pymnt_btch` on BATCH_ID =
     cnsmr_pymnt_btch_file_registry_id; stts_cd 4 -> 3.
   - BDL: joins `file_registry` on BATCH_ID = File_registry_id;
     file_stts_cd 8 or 5 -> 3; 6 or 11 -> -1; the literal BATCH_ID '-1<'
     (an empty-file parse artifact) -> 3.
   - Any other PROCESS_TYPE at 2 -> 3 unconditionally.
   - NB/PAY/BDL at 2 with NULL BATCH_ID -> 4.

   This explains every F5 observation: dispatcher (GET_LIST) rows and MAIN
   rows at 2 are promoted to 3 by the any-other arm; NB/PAY/BDL rows wait
   at 2 until their DM batch reaches a terminal code (the large persistent
   blocks of 2 are exactly those -- awaiting DM, or orphaned from the
   FILES config so the inner join never promotes them).

   **Semantic consequences (first-order for the collector):**
   - BATCH_STATUS 2 is a TRANSIENT handoff state ("B2B side done"), not a
     terminal success; 3 is the confirmed-complete state, now including
     DM-side completion for NB/PAY/BDL.
   - -1 is ambiguous by writer: Sterling fault (workflow onFault) OR
     DM-side batch failure (reconciler). Distinguishing them requires
     FINISH_DATE/context, or better, the collector recording both signals
     separately.
   - The B2B <-> DM bridge is bidirectional: COMM_CALL writes BATCH_ID
     forward; this job reads DM outcomes back. Integration's BATCH_STATUS
     is therefore a full pipeline-lifecycle tracker including DM outcomes
     -- precisely the grain the future collector wants to mirror rather
     than reinvent.
   - DM-side status-code vocabularies surfaced: new_bsnss_btch_stts_cd
     (8 complete; 5/3 deleted/failed), cnsmr_pymnt_btch_stts_cd
     (4 complete), file_stts_cd (8/5 complete; 6/11 failed) -- these
     should be reconciled against Batch Monitoring's existing DM
     knowledge in the design phase.
   - Quirk: the proc trusts BATCH_ID = '-1<' as empty-BDL success -- a
     parser artifact promoted to a semantic marker; flag for cleanup.

## 2. The work-queue procs (R10 -- source now read)

### faint.USP_B2B_CLIENTS_GET_LIST

- Signature: @CLIENT_ID BIGINT = NULL, @SEQ_ID INT = NULL, @SEQ_IDS
  VARCHAR(500) = NULL, @PROCESS_TYPE VARCHAR(200) = NULL, @SEQUENTIAL INT = 0.
- **Branch 1 (@CLIENT_ID IS NULL -- scheduler fires):** merged-mode rows
  (AUTOMATED = 1, RUN_FLAG = 1, ACTIVE flags, FILE_MERGE = 1 OR
  COMM_METHOD = 'OUTBOUND') UNION per-file rows from the discovered-files
  feed. PREV_SEQ = LAG(SEQ_ID) over (CLIENT_ID, GET_DOCS_LOC, SEQ_ID) when
  the prior row shares CLIENT_ID and GET_DOCS_LOC -- chaining is per pickup
  folder, exactly as the ArchitectureOverview claimed (checklist 4.9 first
  half: VERIFIED).
- **Branch 2 (@CLIENT_ID set -- wrapper fires):** AUTOMATED = 2 rows matching
  SEQ_ID, or PROCESS_TYPE, or SEQ_ID IN dbo.StrSplit(@SEQ_IDS, ','). PREV_SEQ
  LAG adds `OR @SEQUENTIAL = 1` -- SEQUENTIAL forces chaining across
  GET_DOCS_LOC boundaries (checklist 4.9 second half: VERIFIED).
- **AUTOMATED semantics confirmed** (checklist 5.8): 1 = scheduler-eligible,
  2 = wrapper-only. ArchitectureOverview claim VERIFIED.
- **The discovered-files feed is real** (checklist 2.9 / 4.5): the @TBL CTE
  joins `Integration.DBO.tbl_FA_CLIENTS_FTP_FILES_LIST_IB_D2S_RC` on
  FILE_FILTER wildcard match (REPLACE '*' -> '%'), gated by
  (RUN_FLAG = 1 AND AUTOMATED = 1) OR (@CLIENT_ID set AND AUTOMATED = 2 AND
  PROCESS_TYPE IN ('NEW_BUSINESS','PAYMENTS','RETURN','RECON')), with
  FILE_MERGE = 0 -- this is the per-file dispatch mode.
- Pivot column list: 68 parameters -- the ~60 BPML-consumed fields (6C s8.5)
  plus parameters no FA_CLIENTS BPML reads: MDOS, GZIP, UNZIP_PASSWORD,
  CUSTOM_BP_PRE_TRANSLATION, CUSTOM_BP_PRE_PROCESS,
  CUSTOM_FILE_FILTER_DATE_OFFSET, CLN_ARCHIVE. Config surface exceeds
  workflow consumption -- catalog for the future config-mirror decision.
- GET_LIST's own BATCH_STATUS INSERT writes SEQ_ID NULL via a CASE when a
  whole-client wrapper passes no SEQ_ID (source re-verified; matches 6C).

### Anomalies found in the proc

- **'PAYMENTS' vs 'PAYMENT':** the discovered-files gate lists PROCESS_TYPE
  IN (... 'PAYMENTS' ...) but the live config vocabulary (R15) contains only
  'PAYMENT' (97 rows) -- that gate arm can never match. Latent dead
  condition or vocabulary drift; flagged (F5 note, no query needed --
  decision item for the eventual config cleanup).
- **'^' vs '|' FILE_FILTER delimiters:** merged-mode branches STRING_AGG
  FILE_FILTER values with '^', while MAIN's OUTBOUND noofdocs computation
  splits FILE_FILTER on '|'. Whether any multi-filter OUTBOUND config exists
  where this matters is a config question; flagged for the same cleanup pass.

### faint.USP_B2B_CLIENTS_GET_SETTINGS

Single pivot over etl.tbl_B2B_CLIENTS_SETTINGS producing nine values --
the eight known from 6C plus **DEF_PRE_ARCHIVE** (consumed by MAIN's
PRE_ARCHIVE expansion; now confirmed as a settings key).

### faint.USP_B2B_CLIENTS_WORKERS_COMP_CHECK

Joins new table `ETL.tbl_B2B_CLIENTS_WORKERS_COMP` to ACCTS by RUN_ID and
returns 'param1=,' + STRING_AGG of node ordinals -- exactly the string the
WORKERS_COMP BPML feeds to XSLT FA_WORKERS_COMP. Mechanism closed.

### FAINT.USP_B2B_CLIENTS_GROUP_KEYS

Authored by "Rober Makram" (rbmakram) 2023-06-22. Walks the crs5_oltp
creditor-group hierarchy (crdtr / crdtr_Grp, six levels) for keys in
`Integration.ETL.tbl_B2B_CLIENTS_CHILD_KEYS` and inserts new rows into
`Integration.ETL.tbl_B2B_CLIENTS_GROUP_KEYS`. Two new tables for the
inventory; direct crs5_oltp dependency noted.

### The ENOTICE procs

- USP_ENOTICE_VALIDATION: rollup-balance consistency counter over
  SENT = 1 rows (the Valid? gate input).
- USP_ENOTICE_VALIDATION_RMV: the reject engine -- ten-plus reason codes
  written to `tbl_ENOTICE_TO_REVSPRING_LTR_REJECT` (+ `_REJECT_CROSSWALK`
  and `_LTR_TXT_CROSSWALK` refs), joins crs5_oltp consumer/address/phone/DNC
  data, computes BEST_PHONE, handles texting eligibility. References
  `Applications.dbo.fn_FA_emailFilter`. Heavily change-managed (SD tickets in
  comments; latest edits 2025-11).
- USP_ENOTICE_DM_CANCELLATION: **authored by Dirk, 2025-09-18 (Notice Recon
  2.5)** -- step-logged via Notice_Recon.dbo.Process_Execution_Log /
  Process_Step_Log, cancels DM document requests in crs5_oltp, writes AR
  events, and queues Jira tickets through **xFACts.Jira.sp_QueueTicket**.
  The Sterling ENOTICE pipeline already terminates inside the xFACts
  ecosystem -- a design-phase fact for the collector (the ENOTICE flow is
  partially self-monitoring today).

## 3. The discovered-files feed, fully closed (F2 + R16)

Client 328 SEQ 12 (the RC wrapper's target) is configured as: SFTP_PULL from
GET_DOCS_LOC 'ETLAP' with FILE_FILTER `FTP_Files.tx*`, GET_DOCS_DLT = 'N'
(leave remote file in place), PRE/POST_ARCHIVE = 'Y', PREPARE_SOURCE = 'Y'
with **SQL_QUERY = `TRUNCATE TABLE
INTEGRATION.dbo.tbl_FA_CLIENTS_FTP_FILES_LIST_IB_D2S_RC`**, and
TRANSLATION_MAP = FA_CLIENTS_FTP_FILES_LIST_IB_D2S_RC (the map writes the
listing into that same table).

So the loop is: an external process maintains FTP_Files.txt in the ETLAP
pickup folder -> every 10 minutes the RC wrapper's MAIN run collects it,
**truncates the discovered-files table via config SQL, and reloads it via
the map** -> scheduler-fired GET_LIST Branch 1 joins the fresh table for
per-file dispatch. The table is rebuilt from scratch every 10 minutes; it is
a live snapshot, not an accumulator. (This is also the most vivid instance
yet of the config-driven arbitrary-SQL exposure catalogued in 6C s8.5: a
TRUNCATE of a dbo table, from a parameter row, every 10 minutes.)

SEQ 13 (the ARC wrapper's target) runs POST_TRANS_SQL_QUERY =
`EXEC Integration.FAINT.USP_FA_CLIENTS_FTP_FILES_LIST_IB_D2S_RC_ARC` with
COMM_CALL = 'Y' -- a new proc for the inventory (the durable archive of the
snapshot table, presumably; one sp_helptext away if ever needed).

The same pattern resolves R16: `tbl_ENOTICE_TO_REVSPRING_VALDN` held 27,830
rows all inserted **this morning** (earliest 2026-07-10 08:16) -- it too is a
transient per-cycle table, wiped and reloaded each ENOTICE run, with
`_VALDN_ARC` as the durable history via FA_DM_ENOTICE_ARCHIVE. The 6F growth
concern is withdrawn. The module search also surfaced proc
`FAINT.USP_FA_SENDRIGHT_3P_CONFIRMATIONS_IB_BD_S2S` (touches VALDN; new to
the inventory) and a retirement convention worth noting: superseded procs in
faint are kept with a `zz` name prefix (three observed).

R18 also closes: zero BATCH_STATUS rows with NULL CLIENT_ID exist, and the
ITS_REQST / INCEPTION_HOLD_TAG fault UPDATE cannot create rows -- their
faults leave **no Integration trace whatsoever**; EmailOnError is their only
signal. The 6F defect is confirmed as live behavior.

R4 closes: POST_ARCHIVE = 'N' exists in production on exactly one active
client -- 525, SEQ 1 and 2, SPECIAL_PROCESS / INBOUND. The tautological
PostArchive? gate is therefore reachable; whether those runs produce files
(and where the literal-'N'-prefixed extracts land if so) is a minor
operational curiosity, resolvable with one BATCH_FILES query for CLIENT_ID
525 if it ever matters.

## 4a. BATCH_STATUS vocabulary, final form (supersedes 6C s7.3)

The table is not a Sterling-only log -- it is a **Sterling-to-DM lifecycle
tracker** with two writer stages (workflows, then the reconciliation job):

| Value | Writer(s) | Meaning |
|--:|---|---|
| 0 | column default | In-flight (or died with no fault handler) |
| -2 | MAIN tail | Skipped: predecessor in SEQUENTIAL chain failed |
| -1 | onFault (MAIN/GET_LIST/ETL_CALL); reconciliation job | Sterling-side fault; OR DM rejected/deleted the batch post-handoff -- two failure stories, one value |
| 1 | ETL_CALL success | Unreachable since 2024-08-26 |
| 2 | GET_LIST tail; MAIN tail (NB/PAY/BDL with handoff) | Transitional: B2B side done, awaiting DM confirmation / next job pass |
| 3 | MAIN tail (other types); reconciliation job | Fully complete (DM-confirmed for NB/PAY/BDL) |
| 4 | MAIN tail; reconciliation job | No files acquired; OR reached 2 with NULL BATCH_ID (handoff never happened) |
| 5 | MAIN tail | Duplicate file |

Age-at-status-2 is the natural "stuck awaiting DM" alert signal; the Agent
job's schedule defines the reconciliation lag.

## 4. Runtime facts resolved (by target id)

| Id | Resolution |
|---|---|
| R1/R2 | Inline participant: no WF_INST_S / linkage trace. No-INVOKE_MODE dispatch: child WF_INST_S instance + WORKFLOW_LINKAGE (ROOT_WF_ID, P_WF_ID = wrapper, C_WF_ID = MAIN child, TYPE = 'Dispatch'). Correlation keys confirmed live. INVOKE_MODE=INLINE and Compression-bootstrap visibility: not yet isolated in a trace -- fold into the next natural WORKFLOW_CONTEXT inspection rather than a dedicated effort (low stakes now that the dispatch layer is proven). Timing-spacing claim: not measured; low value; dropped. |
| R3 | 11 columns (ID, ACCT_ID, CLIENT_ID, SEQ_ID, RUN_ID, CLIENT_NAME, TICKET_NUM, TICKET_REASON, INSERTED_DATE, TICKET_DATE, CLIENT_KEY). 'MAP ERROR' is the TICKET_REASON value in both writers; 354 GET_LIST-origin rows, none since 2025-08-23. Live bug per Summary item 3; follow-up F1. |
| R5 | ETL_CALL dead since 2024-08-26 proc edit (Summary item 2). Stall check moot: the dispatch arm cannot fire. Checklist 1.8 closed. |
| R6 | BATCH_FILES = pickups + deliveries via the X2S map (Summary item 6). Checklist 2.8 closed. |
| R7 | Schedules confirmed: GET_LIST hourly :05, 05:05-15:05 M-F, excl 01-01/12-25 (11/day -- ArchitectureOverview claim 4.3 VERIFIED exactly, including the excluded dates it did not know about). FTP_FILES_LIST RC every 10 min 01:13-22:53 daily (131/day); RC_ARC 01:16-23:56 (137/day) -- the ~10-minute claim VERIFIED. JIRA_TICKETS hourly :30 daily. FA_DM_ENOTICE hourly :15, 07:15-15:15 M-F. CNSMR_ACCNT_AR daily 21:00; CNSMR_TAG daily 21:15; INVALID_ACCOUNTS daily 16:00; INCEPTION_HOLD_TAG M-F 21:05; ITS_REQST M-F 12:01; CCI every 180 min 06:00-18:00 M-F; CONSUMER_ACCOUNTS_MERGE M-F 18:40; FILE_REMOVE_VANDERBILT daily 22:40. 538 FA_FROM/FA_TO schedule rows exist -- the wrapper population is overwhelmingly schedule-driven (more schedules than 30d-active wrappers, consistent with 6A's dormancy tail). |
| R8 | Zero failed ENCOUNTER_LOAD instances in the current window -- the 6.1% was an April-window phenomenon. Attribution deferred until failures recur; the WORKFLOW_CONTEXT column vocabulary (BASIC_STATUS int, ADV_STATUS text, SERVICE_NAME, STEP_ID, START/END, ENTERQ/EXITQ) is now verified for when they do. |
| R11 | Resolved (Summary item 4). BATCH_STATUS vocabulary final: 0 in-flight (column default), -2 cascade-skip, -1 fault, 2/3/4/5 per 6C, 1 defined-but-unreachable (ETL only). |
| R13 | MAIN = WFD_ID 798 (claim 1.5 VERIFIED) -- now at v49 (Summary item 7). WFD.TYPE is a vendor service-category taxonomy: 1 = business processes (1,309), 4 = EDI envelope (54), 5 = misc service (31), 6 = 4, 101 = Schedule_* (22), 102 = backup/restore (5), 103 = notifications (6), 104 = TimeoutEvent (1), 201 = mailbox (10), 203 = 2, 204 = FileGateway/EBICS (15). STATUS = 2 marks 14 retired/disabled WFDs (MapTest, AFTRoute, and 12 FA_* -- consistent with "disabled" semantics; exact vendor meaning not needed further). ONFAULT = 'false' even for MAIN, which has an onFault block -- the column does not mean "has fault handler"; parked as vendor trivia. |
| R14/R17 | 235 = REVSPRING; 328 = INTEGRATION TOOLS (ArchitectureOverview claim 3.1 VERIFIED); 522 = VANDERBILT; 10557 = ACADIA HEALTHCARE (AUTOMATED = 0); 10670 = SFTP CONNECTION TEST (GG_TEST_BP is a purpose-built connection test harness -- 6F flag downgraded from "test workflow in prod" to "named test harness"; schedule presence not found in the R7 pull, so likely manual-fire); 10724 = ACADIA HEALTHCARE EO. 10221 absent from prod MN (test-environment identity, as the ENOTICE BPML's env-switch implies). |
| R15 | Current matrix: 20+ PROCESS_TYPE values including previously undocumented ACKNOWLEDGMENT, CORE_PROCESS (blank COMM_METHOD), EMAIL_SCRUB, ENCOUNTER, FILE_EMAIL, FULL_INVENTORY, ITS, NCOA, NOTE/NOTES/NOTES_EMAIL, REMIT (246 -- the largest), SFTP_PUSH_ED25519, STANDARD_BDL. Dominants: NEW_BUSINESS/INBOUND 537, SFTP_PULL/OUTBOUND 271, REMIT/OUTBOUND 246, RECON/INBOUND 121, PAYMENT/INBOUND 97. Checklist s11 resolved; the matrix supersedes the ArchitectureOverview's 31-row version. |
| R16/R18 | **Resolved** -- see section 3 (VALDN is a transient per-cycle table with _ARC as history; ITS/INCEPTION faults leave no Integration trace). |
| R4 | **Resolved** -- see section 3 (client 525 SPECIAL_PROCESS x2, the only active POST_ARCHIVE = 'N' configs). |
| R9/R12 | Inspection items; deferred until a natural anchor run appears. Not blocking. |

## 5. F4 diff results -- the 2026-06-22 edit session decoded

The three edits form one coherent feature-plus-hardening release:

- **MAIN v49 and PREP_SOURCE v35 add the CLN_ARCHIVE feature.** A new
  ClnArchive rule (CLN_ARCHIVE config set and != 'N') gates a new
  executable, `FA_CLN_ARCHIVE.exe` (new subfolder FA_INT_Tools; 20-min
  timeout), which receives the dated PRE_ARCHIVE path and the CLN_ARCHIVE
  value -- an archive-directory cleanup step. It appears at two sites in
  MAIN (main flow plus an exception-path variant, ClnArchiveExcp) and one
  early site in PREP_SOURCE. Pleasing closure: **CLN_ARCHIVE was one of the
  seven pivot parameters flagged in section 2 as existing in the proc but
  consumed by no BPML** -- as of June 22 it is consumed. The config surface
  led the workflow surface by an unknown margin; the drift census caught
  the convergence. PREP_SOURCE v35 also adds a previously missing
  setSoTimeout (1,200,000 ms) to one existing operation.
- **TRANS v7 adds CheckWarning25**: if the translator's StatusReport
  contains 'Code: 25 Unrecognized Data Block', the workflow now raises a
  Business Process Exception -- converting a previously silent translation
  corruption into a hard fault (BATCH_STATUS -1, ticket, email via MAIN's
  onFault). This is monitoring hardening by the workflow authors, and a
  plausible contributor to the elevated 2026-06 ticket volume noted in
  Summary item 3. Design note for the collector: translation
  Code-25 events before 2026-06-22 completed "successfully."
- **JDBC layer unchanged in all three** -- no coordination-table behavior
  changed (see Summary item 8).
- **FA_CLIENTS_CNSMR_ACCNT_TAG_REMOVAL_IB_BDEO_S2S_SP v1** (new workflow,
  received): a standard wrapper -- CLIENT_ID 10575, SEQ_ID 21, inline
  GET_LIST. Wrapper population: 368. The second new workflow
  (FA_CLIENTS_CNSMR_ACCNT_TAG_IB_BDEO_S2X_BDL) was not in the upload (the
  similarly named pre-existing CNSMR_TAG arrived in its place) and remains
  outstanding; expectation is another standard wrapper.

New inventory entries: exe FA_CLN_ARCHIVE.exe (+ FA_INT_Tools folder);
CLN_ARCHIVE moves from unconsumed to consumed config; working corpus updated
with v49/v35/v7 and the REMOVAL wrapper.

## 6. Follow-up status (F-series)

| # | Item | Status |
|---|---|---|
| F1 | TICKETS identity + breakage timeline; ENOTICE trim; ITS/INCEPTION fault trace | **Fully resolved** (Summary item 3; section 3). |
| F2 | Client 328 SEQ 12/13 parameters; POST_ARCHIVE = 'N' occurrence | **Resolved** (section 3; hypothesis b eliminated for the anomaly). |
| F3 | Version-drift census | **Resolved** (Summary item 7). |
| F4 | Corpus re-extraction + diff | **Fully resolved**: diffs complete; both new workflows read -- CNSMR_ACCNT_TAG is a standard wrapper (CLIENT_ID 328, SEQ_ID 26) and REMOVAL likewise (10575/21). Wrapper population final: **369**. Working corpus current. |
| F5 | Dispatcher-row status discriminator | **Resolved with a surprise** (Summary item 8): the anomaly is universal, not client-specific -- an unidentified Integration-side rollup writes child outcomes onto parent rows. |
| F6 | Identify the BATCH_STATUS rollup writer | **Resolved** (Summary item 8): Agent job 'INT Clients Update Batch Status' -> FAINT.USP_B2B_CLIENTS_UPDATE_BATCH_STATUS. Bonus inventory from the writer census: the DUP_CHECK proc family (base + 5 client-specific variants: ACD, RTCT, ACD_RTCT, ONE_MEDICAL, RADIOLOGY_PARTNERS, ACD_RADIOLOGY_PARTNERS -- FA_DUP_CHECK_CALL.exe is a thin wrapper over per-client SQL), plus USP_FA_CLIENTS_FULL_INVENTORY_DELTAS, USP_FA_SENDRIGHT_3P_RESPONSES_IB_BD_D2S_BDL, USP_FA_MONUMENT_HEALTH_IB_EO_S2D_RPT. |

## 7. Process note (query-pack lessons)

The original pack's R1/R18 sections joined b2bi (FA-INT-DBP) to Integration
(AVG-PROD-LSNR) as if they shared an instance -- that is what forced the
server switching and manual id copying. Standing correction for all future
B2B query packs: **one server per block, no cross-server joins; when
correlation is needed, one side outputs an id list to paste into the other.**
Server map for reference: b2bi lives on FA-INT-DBP; Integration, crs5_oltp,
Notice_Recon, Applications, and xFACts are reachable via AVG-PROD-LSNR.

## Document status

| Attribute | Value |
|---|---|
| Step | 06E -- Runtime Verification |
| Status | **COMPLETE** -- all R and F items resolved (R9/R12 remain parked as natural-anchor inspection notes) |
| Resolved | R1-R8, R10, R11, R13-R18; F1-F3 |
| Folded forward | R9/R12 deferred to natural anchors |
| Next | Step 6G Consolidation: Step 6 summary document, 6D checklist final dispositions, ArchitectureOverview verdict, Roadmap v2.5 |

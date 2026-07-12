# Step 6D Claim Checklist -- ArchitectureOverview Verification

**Date:** 2026-07-10
**Investigation folder:** `xFACts-Documentation/WorkingFiles/B2B_Investigation/Step_06D_Claim_Verification/`
**Subject document:** `Legacy/B2B_ArchitectureOverview.md` (rev 11, 2026-04-22)

## Purpose

Extract every discrete factual claim from the legacy ArchitectureOverview and
resolve each one against verified evidence. This checklist decides (in 6G)
whether the document is reconciled into a revised authoritative document or
retired.

## Dispositions

| Code | Meaning |
|---|---|
| VERIFIED | Confirmed against BPML source or prior step findings |
| CORRECTED | Materially right idea, wrong in specifics; correction recorded |
| REFUTED | Demonstrated false against source |
| 6E | Cannot be resolved from BPML or prior findings; runtime/Integration-side verification required |
| DESIGN | Not an architecture claim -- collector design content, carried to the section-7 decision phase, not verified here |
| DISCARDED | Stale observation or superseded framing with no remaining value |

Evidence keys: `6C sN` = Step_06C_Findings section N; `6A`/`6B`/`S1`-`S5` = step
findings; `corpus` = direct BPML corpus check performed during 6D (2026-07-10);
`RM` = Roadmap Known True.

Per the reset principle, claims sourced from the legacy investigation's own
direct reads (the two stored procedures, runtime traces, ProcessData samples)
and from File Processing Supervisor statements are treated as unverified until
re-checked -- they are tagged 6E, not VERIFIED, regardless of how plausible
they are. Where 6C evidence makes such a claim structurally consistent, that is
noted.

---

## 1. Deprecation banner and Core Architectural Insight

| # | Claim | Disposition | Evidence / correction |
|---|---|---|---|
| 1.1 | Every unit of work = one FA_CLIENTS_MAIN execution ("universal grain") | REFUTED | 6A: MAIN is 16.1% of 30d activity; VITAL and ARCHIVE each run more. The banner itself already retracts this. |
| 1.2 | b2bi retention ~48hr | REFUTED | S2: ~30 days across live + _RESTORE. Banner retracts. |
| 1.3 | "200+" / 643 FA_* workflow definitions, 304 active per 48h | CORRECTED | 6A: 1,433 distinct WFDs total, 413 active per 30d (the correct lens). FA_*-specific counts not re-derived; the 48h frame is retired. |
| 1.4 | MAIN is a single linear sequence with ~22 conditional rules (not polymorphic paths) | CORRECTED | Single sequence VERIFIED (6C s4). Rule count: 23 defined, 22 live; SaveDoc? is dead (6C s4.3). |
| 1.5 | MAIN is WFD_ID 798 | 6E | Trivial WFD lookup; 6A confirmed v48 but did not record WFD_ID in findings. |
| 1.6 | Every MAIN run carries its own ProcessData self-describing the run | 6E | Legacy-trace claim; structurally consistent with 6C (GET_LIST copies one Client block per child) but runtime re-verification pending. |
| 1.7 | Everything else in WF_INST_S is dispatcher, sub-workflow, or Sterling infrastructure | VERIFIED | 6C s2-s3 census: 361 wrappers + FA_CLIENTS family + 10 non-standard + infra families. Complete classification of the FA_* universe. |
| 1.8 | ETL_CALL is deprecated; no CLIENTS_PARAM rows have ETL_PATH populated | 6E | Code path is live in GET_LIST (6C s5.1); zero ETL_CALL runs in 30d (6A) is consistent with the claim; the "no rows" assertion is Integration data -- re-verify (one SELECT). |

## 2. Coordination Layer (Integration DB)

| # | Claim | Disposition | Evidence / correction |
|---|---|---|---|
| 2.1 | Sterling BPMLs coordinate via Integration tables over pool AVG_PROD_LSNR_INTEGRATION | VERIFIED | 6C s7: every JDBC call in the family uses that pool. |
| 2.2 | tbl_B2B_CLIENTS_MN = entity roster | 6E | Not referenced in any FA_CLIENTS BPML; lives inside the SPs. Integration-side check. |
| 2.3 | tbl_B2B_CLIENTS_FILES holds per-(CLIENT_ID,SEQ_ID) classification; RUN_FLAG updated by GET_LIST at runtime | VERIFIED (RUN_FLAG) / 6E (other columns) | RUN_FLAG=0 update verified 6C s5.1. AUTOMATED, FILE_MERGE, ACTIVE_FLAG, PROCESS_TYPE columns are SP-side -- 6E. |
| 2.4 | tbl_B2b_CLIENTS_PARAM = key-value config feeding ProcessData | 6E | SP-side. Consumed-field surface (~60 fields) inventoried from the BPML side in 6C s8.5. |
| 2.5 | tbl_B2B_CLIENTS_SETTINGS = global settings | 6E | SP-side. Consumed values verified from BPML side (6C s8.4: DATABASE_SERVER, DEF_POST_ARCHIVE, DM_*_PATH, API_PORT, PYTHON_KEY, MARCOS_PATH). |
| 2.6 | BATCH_STATUS written by GET_LIST and MAIN | CORRECTED (expanded) | Also ETL_CALL (INSERT/UPDATE) and COMM_CALL (BATCH_ID UPDATE) -- 6C s7.1, s5.10, s5.19. |
| 2.7 | TICKETS written from onFault handlers | VERIFIED | 6C s4.7, s5.1. |
| 2.8 | BATCH_FILES is scope-limited: only ZeroSize/FILE_DELETION files; normal pickups do NOT write to it | LIKELY CORRECTED -- 6E confirm | Direct JDBC insert is indeed ZeroSize-only (6C s5.2). But GET_DOCS and PREP_COMM_CALL run map FA_CLIENTS_BATCH_FILES_X2S over the picked-up/delivered file inventory; if that map targets BATCH_FILES (hypothesis), coverage is far broader (pickups + SFTP_PUT/FSA_PUT deliveries). Resolve with the map-target check (6E item R6). |
| 2.9 | DBO.tbl_FA_CLIENTS_FTP_FILES_LIST_IB_D2S_RC populated by the Pattern 3 workflows every ~10 min | CORRECTED (mechanism) / 6E (data) | The two workflows are standard client-328 wrappers (SEQ_ID 12/13) invoking GET_LIST like everything else (6C s3, s5.23). Any write to that table happens in SP- or config-driven SQL during the dispatched MAIN runs, not in the wrapper BPML. Table existence/population: 6E. |
| 2.10 | USP_B2B_CLIENTS_GET_SETTINGS pivots settings into a single-row document; schema faint | VERIFIED (call + schema) / 6E (internals) | Call and `faint` schema verified 6C s5.1, s7.2. Pivot behavior is proc content -- re-read the proc (6E; trivially in Dirk's domain). |
| 2.11 | USP_B2B_CLIENTS_GET_LIST assembles dispatch list; ~65-column pivot; PREV_SEQ via LAG; Branch 1 (@CLIENT_ID NULL: AUTOMATED=1 + RUN_FLAG=1 (+FILE_MERGE=1 or OUTBOUND) + discovered-files) vs Branch 2 (@CLIENT_ID set: AUTOMATED=2 + SEQ_ID/PROCESS_TYPE/SEQ_IDS match) | VERIFIED (signature) / 6E (internals) | 5-param signature and call verified 6C s5.1. All branch/pivot/LAG detail is proc content -- re-read (6E item R10; the single highest-value 6E read since it defines the work queue). |
| 2.12 | BATCH_STATUS value table: -2 = "failed (legacy code path)"; 0/1 transitional from unclear source; 2/3/4/5 terminal meanings | CORRECTED | -2 = cascade-skip written by MAIN itself when its predecessor failed (6C s4.6) -- not legacy. 1 = ETL_CALL success (6C s5.19) -- a terminal value, not transitional. 0: still unsourced (6E item R11). 2/3/4/5 writer logic verified exactly (6C s7.3). |
| 2.13 | Wait? polls 0<=x<=2; Continue? unblocks 3<=x<=5; -1 fails the gate and short-circuits | VERIFIED | 6C s4.2. Enriched: the skipped run then records -2 for itself, cascading. |
| 2.14 | Ticket types: 'MAP ERROR' (MAIN) and 'CLIENTS GET LIST' (GET_LIST) as distinct types | CORRECTED | Both inserts use literal 'MAP ERROR' in the type position; 'CLIENTS GET LIST' is GET_LIST's value for the CLIENT_NAME slot (6C s5.1 vs s4.7). Additionally the two inserts disagree on column count (9 vs 10) -- at most one can succeed (6C s9.4; 6E item R3). |
| 2.15 | Not every onFault writes TICKETS; ETL_CALL does not | VERIFIED | 6C s5.19. Also true of EMAIL, ENCOUNTER_LOAD, JIRA_TICKETS (EmailOnError only). |
| 2.16 | BATCH_FILES columns: CLIENT_ID, SEQ_ID, RUN_ID, FILE_NAME, FILE_SIZE, COMM_METHOD ('SFTP_GET' literal observed) | VERIFIED | 6C s5.2 (the direct INSERT). Other COMM_METHOD values (SFTP_PUT/FSA_PUT) likely arrive via the X2S map -- 6E R6. |
| 2.17 | BATCH_STATUS/TICKETS are a convenience layer; b2bi is authoritative (JDBC-write-only, missable on crash) | VERIFIED (in principle) | Mechanism confirmed: all writes are BPML JDBC calls (6C s7). The observed "failed in b2bi, silent in Integration" cases are legacy observations -- consistent, no re-verification needed for the principle. |
| 2.18 | Live-join enrichment stance, disagreement detection as alert signal | DESIGN | Carried to section-7 decision phase. |

## 3. Three Identity Scopes

| # | Claim | Disposition | Evidence / correction |
|---|---|---|---|
| 3.1 | CLIENT_ID identifies a configured entity; 328 = INTEGRATION TOOLS (internal), 10557 = ACADIA | 6E (names) | Concept consistent with all 6C reads; names live in CLIENTS_MN -- one SELECT. Client 328's special role is corroborated by six wrappers hardcoding it (6C s5.23). |
| 3.2 | (CLIENT_ID, SEQ_ID) uniquely identifies a Process | VERIFIED | The entire queue/status keying works on this pair (6C s2, s7). |
| 3.3 | DM Creditor keys are a third scope inside file payloads | DESIGN | Out of Sterling scope; relevant to future detail-grain work. |
| 3.4 | MAIN operates only on //Result/Client[1]; multi-Client blocks live in //PrimaryDocument; grain = one Client per MAIN run | VERIFIED | 6C: every MAIN rule references Client[1]; GET_LIST copies exactly one Client block into //Result per child (s5.1). |

## 4. Dispatch Patterns

| # | Claim | Disposition | Evidence / correction |
|---|---|---|---|
| 4.1 | There are four distinct dispatch patterns | CORRECTED | Structurally there is ONE wrapper pattern (param block + inline GET_LIST; 361/371 files) with seven parameter profiles, plus direct scheduler fires of GET_LIST. What varies is the parameter signature and the trigger, not the mechanism (6C s3). The "pattern" taxonomy survives only as a runtime-trigger classification. |
| 4.2 | Pattern 1 exists: named workflows invoke MAIN directly, bypassing GET_LIST; example FA_TO_FORREST_GENERAL_OB_BD_S2D_NT | REFUTED | corpus (2026-07-10): FORREST_GENERAL is a standard wrapper (CLIENT_ID=100, SEQ_ID=6 -> inline GET_LIST). Corpus-wide: MAIN's only caller is GET_LIST (6C s2). No workflow invokes MAIN directly. |
| 4.3 | Pattern 2: GET_LIST fires on its own schedule with no parameters; schedule 5:05am-3:05pm M-F hourly (11/business day) | VERIFIED (structure) / 6E (schedule) | Standalone GET_LIST rows can only be scheduler fires (6C s1.3). The specific schedule is queryable in SI_ScheduleRegistry (6E item R7 -- one query; the registry's own example already renders it as "Every 60 min at :05, 05:05-15:05, Mon-Fri"). |
| 4.4 | Pattern 2 hourly spawn-count table (April 20 observations) | DISCARDED | Stale point-in-time observation; superseded by whatever 6E measures. |
| 4.5 | Pattern 3: FTP_FILES_LIST workflows fire ~10 min, are "Internal Operations (MAIN as SP executor)", and are the source feeding Pattern 2's per-file branch | CORRECTED (mechanism) / 6E (runtime role) | Wrappers are standard (SEQ_ID 12/13, client 328) -- 6C s3. Their MAIN children plausibly run config-driven SQL (the four *_SQL_QUERY hooks, 6C s8.5), which would implement the "SP executor" role -- but that is config data, not wrapper structure. Feed relationship into the GET_LIST proc: 6E R10. Cadence: 6E R7. |
| 4.6 | Pattern 4: thin entity wrappers set CLIENT_ID/SEQ_IDS/PROCESS_TYPE/SEQUENTIAL and inline GET_LIST; inline = no separate WORKFLOW_LINKAGE row; MAIN children appear as direct children of the wrapper | VERIFIED (structure) / 6E (linkage) | Wrapper anatomy verified at census scale (6C s3). Linkage visibility of inline + default-mode children: 6E items R1/R2. |
| 4.7 | Wrapper variant table: ACCRETIVE (488, SFTP_PULL, SEQUENTIAL=1); COACHELLA (10745, SFTP_PULL); MONUMENT (227, SFTP_PULL); ACADIA EO (10724, SEQ_IDS='1,2,3,8', SEQUENTIAL=1) | VERIFIED | ACCRETIVE: 6C session read. Other three: corpus check 2026-07-10 -- exact match on all parameters. |
| 4.8 | Per-wrapper spawn counts (12 / 7 / 2 / 4) explained by matching SEQ counts | 6E | Plausible given 4.7 + the proc model; requires runtime counts + config data. Fold into 6E R10 validation. |
| 4.9 | SEQUENTIAL=1 forces PREV_SEQ chaining across all rows; without it, chaining only within same GET_DOCS_LOC | 6E | Parameter pass-through verified (6C s5.1); the chaining computation is proc content (6E R10). |
| 4.10 | "Pattern 5" does not exist; phased-worker behavior = SEQUENTIAL + BATCH_STATUS polling | VERIFIED | Wait/Continue polling mechanics verified (6C s4.2); 6D collapses the taxonomy further (4.1). |

## 5. FA_CLIENTS_GET_LIST detail

| # | Claim | Disposition | Evidence / correction |
|---|---|---|---|
| 5.1 | Inputs: CLIENT_ID, SEQ_ID, SEQ_IDS, PROCESS_TYPE, SEQUENTIAL from ProcessData | VERIFIED | 6C s5.1; plus COMM_METHOD passes through in 3 wrappers (6C s3). |
| 5.2 | Own BATCH_STATUS INSERT with CASE writing SEQ_ID NULL | VERIFIED | 6C s5.1 (3-column INSERT; quoted SQL matches source). |
| 5.3 | Loop copies Client[N] into //Result then invokes MAIN or ETL_CALL; ETL? on ETL_PATH | VERIFIED | 6C s5.1. |
| 5.4 | Both dispatch invocations use InvokeBusinessProcessService with no INVOKE_MODE; Sterling default is async; children fire ~100-200ms apart | VERIFIED (mechanism) / 6E (default + timing) | No-INVOKE_MODE verified (6C s5.1). Default-mode semantics and spacing: 6E R2. |
| 5.5 | RUN_FLAG cleared after each invocation | CORRECTED (nuance) | The UPDATE is unconditional per loop iteration (6C s5.1); the dead UpdateRunFlag? rule suggests a conditional was intended and abandoned. |
| 5.6 | Tail: own BATCH_STATUS = 2 | VERIFIED | 6C s5.1. |
| 5.7 | onFault: BATCH_STATUS=-1 + TICKETS ('CLIENTS GET LIST') + EmailOnError | VERIFIED / CORRECTED | Operations verified; ticket-type claim corrected per 2.14; the 9-value insert may fail outright (6C s9.4). |
| 5.8 | AUTOMATED semantics (1 = GET_LIST-dispatched, 2 = wrapper-dispatched) and RUN_FLAG semantics | 6E | Supervisor + proc claims; not BPML-visible. 6E R10. |

## 6. FA_CLIENTS_MAIN detail

| # | Claim | Disposition | Evidence / correction |
|---|---|---|---|
| 6.1 | Execution skeleton (preamble, INSERT, wait loop, Continue? gate, GET_DOCS, file loop, tail chain, tail UPDATE) | VERIFIED | 6C s4.1-4.6. |
| 6.2 | Rule catalog (~22 rules, per-rule conditions) | CORRECTED | 23 defined / 22 live; SaveDoc? dead; PostArchive? condition is a tautology the catalog transcribed without flagging (6C s4.3). Individual condition paraphrases otherwise accurate. |
| 6.3 | Sub-workflow invocation map with INVOKE_MODEs | CORRECTED | Two errors: (a) POST_TRANSLATION is post-loop, not "inside loop" (6C s4.5); (b) VITAL/ACCOUNTS_LOAD/ENCOUNTER_LOAD in-loop sites are gated by NOT PostTranslationVITAL -- the map omits the mutual exclusion. Also under-specified: two distinct inline mechanisms exist (participant vs INVOKE_MODE=INLINE; 6C s6). Modes otherwise match. |
| 6.4 | ARCHIVE invoked up to 3 times per MAIN run | CORRECTED | Four call sites: MAIN x3 + PREP_SOURCE via Compression Service start_bpml (6C s5.3). And PreArchive/PostArchive sites are inside the loop -- a multi-file run invokes ARCHIVE up to 2N+1 times plus unzip bootstraps. |
| 6.5 | VITAL has two invocation points; 5 files + PostTranslationVITAL=Y -> 6 VITAL children; explains VITAL count > MAIN count | CORRECTED | The two sites are mutually exclusive on PostTranslationVITAL? (6C s4.4/4.5): flag off -> up to N in-loop; flag on -> exactly 1 post-loop. The 5+1=6 example is wrong (would be 1). VITAL > MAIN is explained by per-file in-loop invocations alone. |
| 6.6 | RemoveSpecialCharacters invokes FA_FILE_REMOVE_SPECIAL_CHARACTERS.exe with listed params | VERIFIED | 6C s4.4 (plus 20-min timeout and FS_COLLECT re-collect detail). |
| 6.7 | FA_MERGE_PLACEMENT_FILES.exe invoked via COMM_CALL in ACADIA EO pipelines | 6E | Mechanism verified as the COMM_CALL_CLA_EXE_PATH hook (6C s5.10); the specific exe/client pairing is config data. |
| 6.8 | Tail UPDATE param2 logic (BDL->2; files+noDup-> NB/PAY?2:3; dup->5; none->4) | VERIFIED | 6C s4.6, logic-exact. |
| 6.9 | onFault: BATCH_STATUS=-1, TICKETS 'MAP ERROR', EmailOnError | VERIFIED | 6C s4.7. |
| 6.10 | Sub-workflow onFault handlers can mask MAIN's onFault (handled faults never reach MAIN) | 6E (behavioral) | Premise refined by 6C: most family sub-workflows have NO onFault (only EMAIL, ENCOUNTER_LOAD, GET_LIST, ETL_CALL, JIRA_TICKETS do). Whether a child onFault suppresses parent NOTIFY_PARENT_ON_ERROR=ALL propagation is Sterling behavior -- 6E R12. |

## 7. FA_CLIENTS_GET_DOCS detail

| # | Claim | Disposition | Evidence / correction |
|---|---|---|---|
| 7.1 | Three GET_DOCS_TYPE branches: SFTP_PULL, FSA_PULL, API_PULL | VERIFIED | 6C s5.2. |
| 7.2 | SFTP loop sequence: session, CD, LIST, FA_FILE_CHECK.java, per-file GET + delete/archive | VERIFIED | 6C s5.2. |
| 7.3 | Default SFTP profile FA-INT-APPT:node1:17b98dc642f:105916 when GET_DOCS_PROFILE_ID empty; "appears to be a legacy dev default" | VERIFIED (value) / 6E (interpretation) | Literal verified (6C s5.2). What that ProfileId points to is Sterling service config -- 6E. |
| 7.4 | ZeroSize? dual purpose (zero-byte skip + FILE_DELETION force) | VERIFIED | 6C s5.2. |
| 7.5 | FILE_DELETION = configuration-driven behavior of the SFTP branch, not a separate code path; delete-without-pickup + BATCH_FILES logging | VERIFIED | 6C s5.2 ("Resolution" framing confirmed from source). The "Joker server / ftpbackup" naming is operational context -- 6E/ops note. |
| 7.6 | GET_DOCS_DLT semantics: 'Y' or empty -> delete; 'N' -> keep; other -> archive-move path prefix | VERIFIED | 6C s5.2 (empty-string default-delete confirmed -- worth flagging operationally). |
| 7.7 | API_PULL: client GET_DOCS_API exe, kingkong !Python_Working dir, 10h timeout, then FS_COLLECT, then mutates GET_DOCS_TYPE to FSA_PULL | VERIFIED | 6C s5.2. |
| 7.8 | GET_DOCS has no onFault; SFTP faults surface as MAIN 'MAP ERROR' tickets | VERIFIED | 6C s5.2 census (onFault count 0). |
| 7.9 | BatchFileInsert? -> map FA_CLIENTS_BATCH_FILES_X2S when PROCESS_TYPE != 'SFTP_PULL' | VERIFIED | 6C s5.2. Map target = 6E R6. |
| 7.10 | Fields inventory (GET_DOCS_TYPE, GET_DOCS_API, CUSTOM_FILE_FILTER, GET_EMPTY_DOCS, FILE_ID, GET_DOCS_DLT) | VERIFIED | All consumed as described (6C s5.2, s8.5). |

## 8. FA_CLIENTS_ETL_CALL detail

| # | Claim | Disposition | Evidence / correction |
|---|---|---|---|
| 8.1 | ETL_CALL runs Pervasive Cosmos 9 djengine.exe -mf with MARCOS_PATH + ETL_PATH; not a SQL executor | VERIFIED | 6C s5.19 (cmdline exact; authentication=Yes; FA_PERVASIVE_ETL adapter instance). |
| 8.2 | Flow: own BATCH_STATUS INSERT, PREV_SEQ poll, exe, BATCH_STATUS=1 on success, -1 on fault | VERIFIED | 6C s5.19 (adds: neither write sets FINISH_DATE). |
| 8.3 | Divergences from MAIN: waits only for status 3; no -2 CASE; success=1 breaks PREV_SEQ chains; no TICKETS insert | VERIFIED (broadened) | 6C s5.19/s9.5 extends: predecessor outcomes -1, -2, 4, and 5 also stall it indefinitely -- a stronger hazard than the ArchOverview recorded. |
| 8.4 | MARCOS_PATH = Pervasive macro root, likely "MACROS" typo | VERIFIED (usage) / interpretation noted | Consumption verified (6C s8.4); the typo theory is plausible commentary, not a claim to resolve. |

## 9. Run classification, ProcessData, empty runs, failure modes

| # | Claim | Disposition | Evidence / correction |
|---|---|---|---|
| 9.1 | Some MAIN runs are Internal Operations (SP executors, CLIENT_ID 328); classification signal is config signature, not PROCESS_TYPE | 6E | Structurally plausible: the four *_SQL_QUERY hooks + client-328 wrappers exist (6C s8.5, s5.23). Actual 328 config: Integration data. |
| 9.2 | ProcessData lives in TRANS_DATA (first DOCUMENT row by CREATION_DATE, PAGE_INDEX=0), wrapper `<r>`, failed runs still have it | 6E | Legacy-trace claims; carried on the retracted-inherited list (RM s4.6). Re-verify during 6E runtime work. |
| 9.3 | PREV_SEQ is declaratively enforced via the BATCH_STATUS polling loop keyed (CLIENT_ID, PREV_SEQ, PARENT_ID) | VERIFIED | 6C s4.2 (poll SQL exact). |
| 9.4 | Short-circuit runs skip processing and go straight to tail UPDATE (15-35 steps) | VERIFIED (structure) / 6E (step counts) | Gate mechanics verified; step-count signature is runtime data. |
| 9.5 | Failure-signal nuance: root-cause step may carry BASIC_STATUS=0 with error ADV_STATUS; base services fail without Inline markers; capture the failure span | 6E / DESIGN | Sound design guidance grounded in legacy traces; re-verify representative cases during 6E WORKFLOW_CONTEXT work. |
| 9.6 | Known failure modes: SSH_DISCONNECT_BY_APPLICATION clustering (04/10/16h); FA_CLA_UNPGP exit 255 | 6E | Point-in-time observations. The UNPGP mechanism (plaintext passphrase arg, PGPOUT re-collect) is source-verified (6C s5.3); the failure signatures and clustering need fresh runtime data. |
| 9.7 | PGP_PASSPHRASE and PYTHON_KEY are plaintext credentials flowing through config/ProcessData | VERIFIED | 6C s5.3, s8.4-8.5 (passphrase is a command-line argument -- exposure is broader than "in ProcessData"). |

## 10. Design sections (Execution Tracking, SI_ScheduleRegistry, matrices)

The Execution Tracking Design, Lookback Optimization, Trust Matrix,
Disagreement Matrix, Collector Flow, SI_ExecutionDetail, and Integration Source
Query Reference sections are collector design material, not architecture
claims. Disposition: DESIGN -- carried forward as input to the section-7
decision phase (7.1-7.7), where they will be re-evaluated against the corrected
execution model (notably: the grain question reopens, because MAIN-only
tracking was premised on claim 1.1, which is refuted).

SI_ScheduleRegistry section: the registry is a deployed production artifact
(RM s3.1); its self-reported facts (604 schedules, pattern distribution, zero
UNKNOWN) are accepted as deployment records. Its GET_LIST schedule rendering
doubles as the 6E R7 check.

One design-relevant correction to carry: `merged_output_file_name` is now
derivable without ProcessData parsing -- the formula is deterministic from
CLIENT_NAME + date + WORKFLOW_ID + PROCESS_TYPE (6C s7.3).

## 11. Process Type Investigation Status table

The 31-row PROCESS_TYPE x COMM_METHOD matrix is an observed-in-practice
inventory from Integration config. Disposition: 6E (one GROUP BY against
CLIENTS_FILES re-verifies the current matrix). 6C grounded the behavior of the
values MAIN branches on (NEW_BUSINESS, PAYMENT, BDL, SFTP_PULL, SFTP_PUSH,
FILE_DELETION, SIMPLE_EMAIL; TRANSACTION found only in orphaned TABLE_PULL --
6C s5.22). Per-type anatomy tracing remains post-Step-6 work (RM s5.9).

## 12. Consolidated 6E runtime target list (6C section 12 + new from 6D)

| # | Target | Origin |
|---|---|---|
| R1 | Inline-mechanism visibility (participant vs INVOKE_MODE=INLINE vs Compression start_bpml) in WF_INST_S / WORKFLOW_LINKAGE | 6C q1 |
| R2 | Sterling default INVOKE_MODE for InvokeBusinessProcessService; child linkage + spacing of GET_LIST->MAIN fires | 6C q2 + 6D 5.4 |
| R3 | TICKETS column count; do GET_LIST-origin fault tickets exist at all | 6C q3 + 6D 2.14 |
| R4 | POST_ARCHIVE='N' with files present: occurrence + extract destination | 6C q4 |
| R5 | ETL_CALL stall occurrences; ETL_PATH population (resolves deprecation claim 1.8) | 6C q5 + 6D 1.8 |
| R6 | Target tables of the four fixed maps (MP_VITAL, X2S_ACCTS, BATCH_FILES_X2S, ENCOUNTER_LOAD_D2S); resolves BATCH_FILES scope (2.8) | 6C q6 + 6D 2.8 |
| R7 | Schedule cross-reference via SI_ScheduleRegistry: GET_LIST window, FTP_FILES_LIST cadence, JIRA_TICKETS, GROUP_KEYS_SP, wrapper population | 6C q7 + 6D 4.3/4.5 |
| R8 | ENCOUNTER_LOAD failure attribution (maps vs allocator vs lock exe) | 6C q8 |
| R9 | TRANS FILELIST/SIZE (transaction count) vs PREP_COMM_CALL EmptyFiles? size read | 6C q9 |
| R10 | Re-read USP_B2B_CLIENTS_GET_LIST + GET_SETTINGS: Branch 1/2 filters, AUTOMATED/RUN_FLAG semantics, PREV_SEQ LAG computation, pivot column list, discovered-files feed | 6D 2.11/5.8/4.5/4.9 |
| R11 | BATCH_STATUS values 0/1 in the wild: who writes 0; column default | 6D 2.12 |
| R12 | Child-onFault vs NOTIFY_PARENT_ON_ERROR=ALL propagation behavior | 6D 6.10 |
| R13 | WFD_ID for MAIN (=798?); WFD.TYPE, WFD.STATUS=2, ONFAULT='false', GBMDATA (carried from 6A/6B) | 6D 1.5 + RM s5.15 |
| R14 | CLIENTS_MN spot checks: 328, 10557, 10724 names; internal-entity ID list | 6D 3.1 |
| R15 | Current PROCESS_TYPE x COMM_METHOD matrix from CLIENTS_FILES | 6D s11 |

Items R3, R5 (ETL_PATH), R7, R11, R14, R15 are single-query checks in Dirk's
T-SQL domain and could be knocked out in minutes at 6E start; R10 is a proc
read; R1/R2/R12 need targeted runtime experiments or WORKFLOW_LINKAGE analysis.

## 13. Verdict inputs for 6G

Tally: 46 claims/claim-groups resolved VERIFIED, 14 CORRECTED, 3 REFUTED,
2 DISCARDED, and the remainder split between 6E (runtime/Integration) and
DESIGN. The document's core structural narrative (single-sequence MAIN,
rule-gated invocations, GET_LIST dispatch, BATCH_STATUS coordination,
GET_DOCS acquisition model, FILE_DELETION mechanism) held up well against
source; its taxonomy layer (universal grain, four patterns, Pattern 1,
distinct ticket types, VITAL additivity, ARCHIVE count) did not.

Recommendation to carry into 6G (not final until 6E closes): retire the
ArchitectureOverview rather than revise it. Step_06C_Findings supersedes its
structural content; this checklist preserves its resolved claims; the design
sections move into the section-7 decision phase. The document's remaining
unique value (failure-mode traces, ProcessData grammar notes, design
rationale) is reference material best kept under Legacy/ as-is.

## Document status

| Attribute | Value |
|---|---|
| Step | 06D -- Claim Verification |
| Status | **FINAL** -- all dispositions closed in Step 6G |
| Next | None -- Step 6 closed; see Step_06G_Summary |
| Roadmap impact | Section 5.6: 6D complete. Section 5.15: consolidated 6E list (R1-R15) supersedes prior scattered lists. Section 8: ArchitectureOverview retirement recommendation queued for 6G. |

---

## 14. Final dispositions (added in Step 6G, 2026-07-10)

Steps 6E (runtime verification, including the F-series follow-ups) and 6F
(light catalog) resolved every row tagged 6E above. Resolutions by claim id,
evidence in Step_06E_Findings unless noted:

| Claim | Final disposition |
|---|---|
| 1.5 | VERIFIED -- MAIN is WFD_ID 798 (R13). |
| 1.8 | VERIFIED -- ETL path disabled in the proc 2024-08-26; ETL_PATH derives from nothing current; zero BATCH_STATUS = 1 rows in table history. |
| 2.2 / 3.1 | VERIFIED -- CLIENTS_MN confirmed the identities: 328 INTEGRATION TOOLS, 10557 ACADIA HEALTHCARE, 10724 ACADIA HEALTHCARE EO, 235 REVSPRING, 522 VANDERBILT, 10670 SFTP CONNECTION TEST (R14/R17). |
| 2.4 / 2.5 | VERIFIED in mechanism -- PARAM key-value store confirmed via the F2 read of client 328; SETTINGS pivot confirmed in the GET_SETTINGS proc read (plus ninth value DEF_PRE_ARCHIVE). |
| 2.8 / 2.16 | CORRECTED confirmed -- BATCH_FILES holds pickups and deliveries (2.48M SFTP_GET + 205K SFTP_PUT rows); the X2S map writes it (R6). |
| 2.10 / 2.11 / 5.8 / 4.9 | VERIFIED -- proc source read (R10): Branch 1/2, AUTOMATED 1/2 semantics, PREV_SEQ LAG per GET_DOCS_LOC with SEQUENTIAL override, discovered-files join, 68-column pivot. Two proc-side anomalies logged: dead 'PAYMENTS' gate arm; '^' vs '|' FILE_FILTER delimiter mismatch. |
| 2.12 | CORRECTED and finalized -- 0 is the column default (in-flight); 1 unreachable; and a fifth writer exists: SQL Agent job 'INT Clients Update Batch Status' -> FAINT.USP_B2B_CLIENTS_UPDATE_BATCH_STATUS reconciles DM-side outcomes back onto BATCH_STATUS, making 2 a transitional state and giving -1 and 4 second meanings. Final vocabulary: Step_06E_Findings s4a. |
| 2.14 | CORRECTED confirmed, and a live production bug -- TICKETS has 11 columns with identity ID; GET_LIST's 9-value insert has failed since ~2025-09 (last GET_LIST-origin ticket 2025-08-23); GET_LIST faults are currently unreported. |
| 4.3 | VERIFIED exactly -- GET_LIST schedule hourly :05, 05:05-15:05, M-F, excl 01-01/12-25 (R7). |
| 4.5 | VERIFIED in runtime role -- client 328 SEQ 12 config truncates and reloads the discovered-files table every ~10 minutes via SQL_QUERY + translation map (F2/R16 pattern). |
| 4.6 / 5.4 | VERIFIED -- no-INVOKE_MODE dispatch produces a child WF_INST_S instance plus WORKFLOW_LINKAGE TYPE = 'Dispatch' with ROOT_WF_ID = wrapper id; inline invocations leave no trace (R1/R2). Timing-spacing sub-claim dropped as low value. |
| 4.8 | Superseded -- mechanism fully explained by the proc read; the specific April counts stay DISCARDED. |
| 9.1 | VERIFIED -- the SP-executor role is real (328's config-SQL pattern observed directly). |
| 9.2 / 9.5 / 6.10 | Parked -- ProcessData grammar and fault-propagation claims remain opportunistic inspection notes (R9/R12); nothing in the collector design depends on them at the architecture level. |
| s11 matrix | Superseded -- current 20+ x combination matrix pulled fresh (R15); the ArchitectureOverview's 31-row version is historical. |

Revised tally: **63 VERIFIED, 17 CORRECTED, 3 REFUTED, 3 DISCARDED/superseded,
2 parked** (9.2-family), remainder DESIGN (carried to the section-7 decision
phase).

## 15. Verdict (final)

**Retire `Legacy/B2B_ArchitectureOverview.md`.** Its structural narrative was
substantially sound and is now superseded by Step_06C_Findings (structure),
Step_06E_Findings (runtime + vocabulary), and Step_06F_Findings (catalog);
its taxonomy layer (universal grain, four dispatch patterns, Pattern 1,
distinct ticket types, VITAL additivity) was wrong and is corrected on the
record here. The document remains under Legacy/ as-is for audit; nothing
should cite it as authoritative. Its design sections feed the section-7
decision phase via Step_06G_Summary.

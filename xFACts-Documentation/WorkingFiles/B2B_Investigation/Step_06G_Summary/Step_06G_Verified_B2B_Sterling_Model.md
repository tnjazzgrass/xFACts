# Step 6G Summary -- The Verified B2B/Sterling Model

**Date:** 2026-07-10
**Investigation folder:** `xFACts-Documentation/WorkingFiles/B2B_Investigation/Step_06G_Consolidation/`
**Status:** Step 6 (sub-steps 6A-6G) is CLOSED. This document is the entry
point to everything Step 6 established; details live in the per-step
findings docs (map in section 9).

## 1. The system in one page

Sterling B2B Integrator 6.1 at FAC is a single-node business-process engine
(no file gateway, no EDI runtime). 1,433 workflow definitions exist; ~413
are active in any 30-day window; retention is ~30 days across live +
_RESTORE tables.

**Every client pipeline runs through one spine.** A wrapper workflow (369 of
them, all structurally identical: a parameter block + inline GET_LIST
invoke) or the hourly scheduler fires `FA_CLIENTS_GET_LIST`, which queries
the work queue (`faint.USP_B2B_CLIENTS_GET_LIST` over the CLIENTS config
tables plus a discovered-files table rebuilt every 10 minutes) and
dispatches one `FA_CLIENTS_MAIN` per queued client row. MAIN is invoked by
exactly one workflow in the corpus: GET_LIST. MAIN's 22 live rules gate a
fixed pipeline -- acquire (GET_DOCS: SFTP/FSA/API), prepare (PREP_SOURCE:
PGP, unzip, conversions, config SQL), translate (TRANS + maps), merge
(FILE_MERGE: Titanium envelopes), check (DUP_CHECK, WORKERS_COMP,
ADDRESS_CHECK), deliver (PREP_COMM_CALL drops to DM import folders or
SFTP-pushes outbound; COMM_CALL calls the DM API and writes the DM batch id
back), notify (EMAIL). Sub-workflows run inline (invisible at runtime) or
async/dispatched (own WF_INST_S rows; WORKFLOW_LINKAGE TYPE='Dispatch'
links GET_LIST children to the wrapper).

**One table tracks the whole lifecycle.**
`Integration.ETL.tbl_B2B_CLIENTS_BATCH_STATUS` -- one row per run, RUN_ID =
Sterling WORKFLOW_ID, PARENT_ID = dispatcher id, BATCH_ID = the DM batch --
is written by the workflows and then **reconciled against DM outcomes** by
SQL Agent job 'INT Clients Update Batch Status'
(FAINT.USP_B2B_CLIENTS_UPDATE_BATCH_STATUS), which reads crs5_oltp batch
tables and promotes statuses. Final vocabulary (Step_06E_Findings s4a):
0 in-flight; -2 cascade-skip; -1 Sterling fault OR DM-rejected; 1
unreachable; 2 B2B-done-awaiting-DM (transitional); 3 fully complete;
4 no files OR no handoff; 5 duplicate.

## 2. The numbers

429-file BPML corpus (now current through 2026-07): 30 FA_CLIENTS family
members (deep-read), 369 standard wrappers (census-verified, 7 parameter
profiles), 10 non-standard workflows (catalogued), ~30 Sterling
infrastructure BPs (catalogued). Every file accounted for. FA_CLIENTS_MAIN
= WFD_ID 798, v49; MAIN is 16% of workflow volume -- VITAL and ARCHIVE
each run more often (per-file in-loop invocations).

## 3. What the collector inherits (design-phase inputs)

1. **The grain**: one BATCH_STATUS row per pipeline run, with parent
   linkage, DM batch bridge, and DM-outcome reconciliation already
   materialized in production. The collector mirrors; it does not invent.
2. **Correlation keys, proven live**: wrapper WF_INST_S.WORKFLOW_ID =
   GET_LIST-portion RUN_ID; MAIN child RUN_ID + PARENT_ID; WORKFLOW_LINKAGE
   'Dispatch' rows; merged-output filename derivable as
   CLIENT_NAME.DM.yyyyMMdd_WORKFLOWID.(NB|PAY|BDL|.).txt.
3. **Schedules**: SI_ScheduleRegistry already covers them; GET_LIST hourly
   :05 (05:05-15:05 M-F), FTP_FILES_LIST every 10 min, plus per-wrapper
   schedules (538 FROM/TO schedule rows).
4. **Alert signals ready to define**: age-at-status-2 (stuck awaiting DM);
   status-0 age (in-flight too long / died unhandled); -1 with vs without
   DM context; ticket-volume spikes (2026-02 hit 10,039 vs ~1,100
   baseline); WFD version drift (one-query census, proven twice this
   step); reconciliation-job lag.
5. **Known blind spots to design around**: inline invocations are runtime-
   invisible; VITAL/ACCOUNTS/BATCH_FILES/ENCOUNTER writes hide in
   translation maps; ITS_REQST and INCEPTION_HOLD_TAG faults leave no
   Integration trace; scheduler-fired GET_LIST rows park at 2 forever.

## 4. Defects and operational flags (actionable, ordered by severity)

1. **GET_LIST fault tickets broken since ~2025-09**: its 9-value TICKETS
   insert cannot succeed against the 11-column table (CLIENT_KEY added
   ~Aug 2025). GET_LIST faults are currently unreported. Fix: GET_LIST v20
   -- column-list the insert (and MAIN's, while there).
2. **ITS_REQST / INCEPTION_HOLD_TAG fault writes are no-ops** (UPDATE for
   a never-inserted row); EmailOnError is their only signal.
3. **-1 and 4 dual meanings** (Sterling vs reconciler) -- CC presentation
   must disambiguate or accept the merge.
4. **ETL_CALL is dead code** (proc arm disabled 2024-08-26) with a latent
   infinite-poll hazard if ever revived.
5. **PostArchive? tautology** in MAIN -- reachable via client 525
   (SPECIAL_PROCESS, POST_ARCHIVE='N').
6. **PGP_PASSPHRASE and PYTHON_KEY are plaintext** in config and on
   command lines.
7. Minor: proc-side dead 'PAYMENTS' gate arm; '^' vs '|' FILE_FILTER
   delimiter mismatch; BATCH_ID '-1<' parse artifact as semantic marker;
   PAYGROUND exes hardcode 'PROD'; GG_TEST_BP (SFTP test harness) live;
   4 dead BPML rules; TABLE_INSERT/TABLE_PULL orphaned.

## 5. ArchitectureOverview verdict

**RETIRED** (Step_06D_Claim_Checklist s15). Final tally: 63 verified, 17
corrected, 3 refuted, 3 discarded, 2 parked, remainder design-phase. It
stays under Legacy/ for audit only.

## 6. Residual open items (none blocking)

R9 (TRANS FILELIST/SIZE vs EmptyFiles?) and R12 (child-onFault
propagation): opportunistic WORKFLOW_CONTEXT inspections when a natural
anchor run appears. The reconciliation job's schedule/frequency: one
sysjobs query when the collector design needs the lag number.

## 7. What happens next

The investigation phase is over. Next is the **decision phase** -- Roadmap
section 7 (7.1-7.7): rebuild-vs-evolve SI_ExecutionTracking, one collector
or many, sub-workflow tracking depth, dispatcher representation,
Integration mirroring strategy, in-flight visibility, and execution-detail
extraction -- now answerable with a verified model. Design work follows
xFACts standing rules: guidelines validation before DDL, one object at a
time, investigation docs archived once the module ships.

## 8. Version-currency discipline (standing)

Sterling changed under us mid-investigation (MAIN v49, two new wrappers,
caught by a one-query WFD census). The census belongs in the eventual
collector as a drift signal, and any future BPML-dependent work starts by
re-running it.

## 9. Document map

| Document | Content |
|---|---|
| Step_01..05_Findings | Environment, retention, universe, WF_INACTIVE, CORRELATION_SET |
| Step_06A_Findings | Active catalog, 30d counts, extraction targets |
| Step_06B_Findings | BPML storage model, extraction tooling |
| Step_06C_Findings | Structural deep reads: MAIN + family, dispatcher census, inventories |
| Step_06D_Claim_Checklist | Every ArchitectureOverview claim, dispositioned; final verdict |
| Step_06E_Findings | Runtime verification: procs, schedules, vocabulary, reconciliation job, bugs |
| Step_06F_Findings | Non-standard workflows, infrastructure, suffix census |
| Step_06G_Summary | This document |
| B2B_Roadmap v2.5 | Status board; decision-phase queue |

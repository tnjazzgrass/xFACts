# B2B Module Roadmap

**Status:** Active — **collection layer AND Control Center page LIVE**. Collection went live 2026-07-12; the B2B Pipeline page went live 2026-07-13. The 2026-07-16 session added the sterling_status coarse-status model, pivoted the whole page onto it, enabled per-condition alerting, and ran a large dispatcher_name historical backfill. Next: resolve the remaining ~150K scheduled-dispatcher rows (needs a run→schedule link), and general page/enrichment iteration.
**Version:** 3.0
**Last updated:** 2026-07-16

---

## ⚡ Next Session — Start Here

**This section is the first thing to read when opening this document in a new session.**

### What's next

**Everything built is live, and the page now runs on the sterling_status model** (§4.2a, §7.9). The collection layer (`B2B.INT_PipelineTracking`, `B2B.SI_WorkflowRegistry`, `B2B.SI_ScheduleRegistry`, `B2B.SI_FaultReport`, `Collect-B2BPipeline.ps1`) runs under the orchestrator, and the **B2B Pipeline page** at /b2b-pipeline drives off the coarse five-value sterling_status: pulse tiles (non-clickable live-sourced top row / clickable table-sourced bottom row), process-type-badge live activity, the year/month/day history tree bucketed by sterling_status, the runs modal filtered by sterling_status and by a data-driven type filter, and a dual-status run-detail slideout. Alerting is enabled with per-condition routing. Open directions, in priority order:

1. **🎯 Dispatcher resolution — the remaining ~412K NULLs (§4.2a, dispatcher backfill).** The 2026-07-16 backfill resolved ~1.3M of ~1.7M NULL dispatchers (GET_LIST parent/child chain + single-match sibling lookup). What remains is fully characterized and split into two populations: (a) **~150K top-level scheduled-dispatcher parent runs** whose dispatcher IS a schedule's `service_name` but which have no in-table link to it — plus the ~250K children that inherit from them; and (b) **~13K parentless seq'd orphans** + 2 dual-routed ambiguous combos, deliberately left NULL. Population (a) is blocked on a **durable run→SI_ScheduleRegistry link that does not exist in the table today**. Two paths: **(i)** find/capture a run→schedule key at the Integration/b2bi source (the real fix — would also enable live-view dispatcher); **(ii)** re-run the single-match sibling backfill periodically as more schedule-fired runs accumulate under the collector, growing the match set for weekly/monthly/weekend cadences that had no recent row to match. Arrival-time cadence correlation against SI_ScheduleRegistry is a possible **inference** approach but must be designed carefully with uncertainty marking — never written into dispatcher_name as fact.
2. **Enrichment survey** — deciding what additional Integration/b2bi data to capture into the mirror and where to draw the line. Working framework from 2026-07-16: capture facts not interpretations; capture what you filter/group/alert on, not lookup-only detail (fetch-on-demand otherwise, like the fault report); capture at the grain you use; and capture when the source ages out (else join on demand). CLIENTS_PARAM (per-client key/value config) is a candidate reference source but should almost certainly be join-on-demand, not copied in.
3. **Page/docs iteration** — parent/child hierarchical run view in the history tree (now on firm ground — parent linkage proven; note ~13K childless-dispatcher leaves would need filtering); a B2B docs-zone page + NavRegistry doc_page_id; the classification-model verification for NO_HANDOFF/DUPLICATE/CASCADE_SKIP (held in sterling_status UNDEFINED pending source-verified meaning — one-line CASE edit each once confirmed).
4. **WORKFLOW_CONTEXT live-step verification** — the remaining path to "step X of Y" live display (WF_INST_S confirmed write-at-termination, §4.2a). Needs column/timestamp verification then business-hours sampling.

### Required context

1. **§3, §4.2a, §7 of this Roadmap** — the live architecture, the verified dispatch model, and the decisions.
2. **`WorkingFiles/B2B_Investigation/Step_06G_Consolidation/Step_06G_Summary.md`** — the verified Sterling model.
3. For page work: `CC_PS_Spec.md`, `CC_CSS_Spec.md`, `CC_JS_Spec.md`, `CC_HTML_Spec.md` and the Guidelines CC-page checklist.

### Session start prompt template

> Continuing the B2B module (dispatcher run→schedule linkage / enrichment survey / page iteration). Cache-busted manifest URL: https://raw.githubusercontent.com/tnjazzgrass/xFACts/main/manifest.json?v=<value>

### Minor open items

- Dispatcher-resolution shortfall (b2bi live path): ~750 in-window instance ids resolve in neither WF_INST_S nor WF_INST_S_RESTORE; benign (rows retry while in-window, then rest at NULL). Note the go-forward collector dispatcher step (b2bi WF_INST_S linkage) only resolves within Sterling's ~48h runtime retention and only for the last b2b_collect_lookback_days — it deployed ~2026-07-10 14:56, which is the hard boundary between the all-NULL history before it and the near-fully-populated rows after.
- Classification labels still read "Sterling Fault" / "Fault Post-Handoff" on the detail (classification) layer by design — the clean "Failed" wording lives on the sterling_status headline, so the fault/failure distinction now reads as a genuine detail layer rather than an inconsistency (no rename needed).

## 1. Purpose

Authoritative entry point for all B2B module work. Tracks investigation state, records what we've verified, and drives architectural decisions toward a comprehensive Sterling monitoring collector.

**What this document is:**
- An investigation tracker and status board
- A decision record for architectural choices
- The orientation document for new sessions
- The single slim reference — detail lives in per-step findings docs

**What this document is NOT:**
- An architecture specification
- An implementation plan
- A detailed technical reference (that's in the step findings docs)

Implementation decisions were held until the investigation phase completed. That gate was passed: the investigation closed 2026-07-10, the §7 decisions were recorded 2026-07-12, and the build executed the same day. The document now records the decisions, the live architecture, and what follows.

---

## 2. Operating Principles

- **No new tables, columns, or collectors under the B2B schema** until investigation is complete. Exceptions must be explicit decisions recorded here, not drift into premature building. (Gate passed: investigation closed 2026-07-10; build decisions recorded in §7 on 2026-07-12.)
- **Every "Known True" claim must be directly verified** against production data or BPML source, with date of verification recorded. Inherited claims don't count until re-verified.
- **BPML is an authoritative structural source** for what each workflow can do. Runtime observation (WORKFLOW_CONTEXT, ProcessData) verifies what workflows *actually did* in specific runs. Both are needed; neither alone is sufficient.
- **Uncertainty gets written down as an open question** rather than assumed away.
- **Operational staff are first-class information sources** but are not the primary path — we're building documentation that never existed. Dirk is the customer of Sterling at FAC, not its architect. The original architect (`rbmakram`) and other historical editors are no longer available for consultation.
- **Existing production artifacts** (`SI_ScheduleRegistry`, `SI_ExecutionTracking`, `Collect-B2BExecution.ps1`) stay as-is during investigation. They function for their narrow scope and are collecting data. All of them will be re-evaluated when investigation completes — they may fold into the eventual comprehensive collector, or be replaced. Nothing downstream consumes them yet (no alerting, no CC pages), so replacement is a clean-slate option. (Executed 2026-07-12: `SI_ExecutionTracking` dropped, `Collect-B2BExecution.ps1` retired and deregistered, ProcessRegistry repointed to `Collect-B2BPipeline.ps1`; `SI_ScheduleRegistry` continues as-is per 7.2 with its sync carried into the new collector.)
- **The investigation documents (this Roadmap + step findings) are working documents, not permanent documentation.** Their purpose is to inform the module build. Once the module is built, these documents will eventually be archived and real HTML documentation will be authored from them.
- **Step 6 is checkpointed across multiple sessions.** The original "do it all in one session" framing was abandoned after scope expanded to cover the full workflow universe (not just MAIN). Each sub-step produces its own findings and Roadmap update.

---

## 3. Current State

### 3.1 Production artifacts (live as of 2026-07-12)

| Artifact | Scope | Status |
|---|---|---|
| `B2B.INT_PipelineTracking` | One row per pipeline run mirrored from Integration BATCH_STATUS, disambiguated classification (§7.8), full history to 2021-06-23 (1,717,835 backfilled rows + live collection). Carries `sterling_status` (§7.9): coarse five-value Sterling-level status derived from status_classification, the page's primary axis. `dispatcher_name` historically backfilled 2026-07-16 (§4.2a). | Live |
| `B2B.SI_WorkflowRegistry` | Workflow definition catalog + version census memory from `b2bi.dbo.WFD` (1,460 definitions at initial load) | Live |
| `B2B.SI_ScheduleRegistry` | Schedule catalog sync from `b2bi.dbo.SCHEDULE` | Live (sync carried into the new collector unchanged) |
| `B2B.SI_FaultReport` | One row per Sterling-internal failure carrying an extractable status report; full parsed report (JSON) + raw decompressed text, captured from b2bi TRANS_DATA via the failing step's STATUS_RPT handle | Live |
| `Collect-B2BPipeline.ps1` | Eight-step collector: schedule sync, version census, classified mirror insert + re-poll (both now derive `sterling_status` inline, §7.9), dispatcher resolution, Sterling cross-check, fault-report enrichment, Teams alert evaluation (per-condition routing, scoped to STERLING_FAULT + DIED_UNHANDLED for the failure alert) | Live, FIRE_AND_FORGET, dependency_group 10 || GlobalConfig settings | `b2b_alerting_enabled` (BIT, 1 — enabled 2026-07-16), `b2b_alert_sterling_fault_routing` + `b2b_alert_workflow_change_routing` (per-condition routing, PMT pattern 0/1/2/3), `b2b_collect_lookback_days` (INT, 3), `b2b_inflight_aging_minutes` (INT, 720), `refresh_b2b_seconds` (ControlCenter/Refresh, 10) | Alerting enabled with per-condition routing |
| B2B Pipeline CC page | `/b2b-pipeline`: B2BPipeline.ps1, B2BPipeline-API.ps1, b2b-pipeline.css, b2b-pipeline.js. **Pivoted to sterling_status 2026-07-16** (§7.9): pulse tiles (top row Runs Today / In Flight / Awaiting DM, non-clickable, live-sourced so counts match the live window; bottom row Success / No Action / Failed, clickable, table-sourced), live activity with leading process-type badges (NB/PMT/BDL share chrome tokens with Batch Monitoring, others page-local, NULL→DISPATCHER) + Run ID, dispatcher dropped from live (kept on history), year/month/day history tree bucketed by the five sterling_status values (In Progress blue, dash-for-zero), runs modal filtered by sterling_status and a data-driven /process-types type filter, dual-status run-detail slideout (sterling_status headline + classification detail). Recent Workflow Changes section + /census endpoint removed. Engine card (slug b2b), platform nav at sort 120, permissions (roles 2/3 operate, 4 view) | Live to all users |

Retired 2026-07-12: `B2B.SI_ExecutionTracking` (dropped; MAIN-as-grain premise refuted), `Collect-B2BExecution.ps1` (deleted; schedule sync absorbed into the replacement). Registrations deactivated, metadata preserved inactive.

### 3.2 Coverage model

The mirror covers 100% of client pipeline runs (the BATCH_STATUS grain) with DM-verified outcomes. Sterling engine activity outside the pipeline (VITAL/ARCHIVE swarms, infrastructure BPs — the "84%") is deliberately not mirrored per decisions 7.3/7.7; it remains a live-query concern for the future CC engine panel. The classification vocabulary and its full-history census live in §7.8 and §4.2a.

---

## 4. Known True

Facts verified against production data or BPML source. Each entry dated with source. Entries only added after direct verification.

### 4.1 Sterling environment

**2026-04-24 — Sterling B2B Integrator version 6.1.0.0** — source: `SI_VERSION` table
Installed 2021-03-23. Matches IBM docs at `ibm.com/docs/en/b2b-integrator/6.1.0`. Version-accurate reference.

**2026-04-24 — b2bi database shape** — source: Step 1 catalog
773 tables total, 186 populated, 587 empty. ~11.5M rows, ~33GB. Zero foreign keys (no DB-enforced referential integrity). 2 views, 1 stored procedure. Relationships are code-enforced.

**2026-04-24 — FAC uses pure BP-execution mode** — source: Step 1 catalog
File Gateway (SFG) tables are installed but effectively empty (0-6 rows across all FG_* tables). EDIINT/AS2/AS3/Mailbox features are present as workflow definitions but have zero runtime activity. FAC uses Sterling as a Business Process engine, not as a file gateway or EDI trading partner.

**2026-04-24 — Sterling is single-node** — source: Step 6A
All 413 active workflows in a 30-day window show `distinct_nodes_seen = 1` in `WF_INST_S.NODEEXECUTED`. No clustering.

### 4.2 Workflow definitions and activity

**2026-04-24 — 1,433 distinct workflow definitions exist** — source: Step 3 and re-confirmed Step 6A (WFD deduplicated by WFD_ID via MAX(WFD_VERSION))
Not 200+ as previously believed. Not 2,467 either — that count includes version history.

**2026-04-24 — 413 distinct workflows are active in any 30-day window** — source: Step 6A
Step 3's 332 active count was at 48h and undercounted weekly/monthly workflows. The 30-day window is the correct investigation lens. Remaining 1,020 WFDs are dormant.

**2026-04-24 — FA_CLIENTS_MAIN is 16.1% of total Sterling activity over 30 days** — source: Step 6A
Not the "universal grain" claimed in legacy `B2B_ArchitectureOverview.md`. `FA_CLIENTS_VITAL` runs 26.6% and `FA_CLIENTS_ARCHIVE` runs 26.6% of total — each more often than MAIN. Top 3 combined = 69.3% of all Sterling workflow volume over 30 days.

**2026-04-24 — Four velocity tiers exist in the workflow universe** — source: Step 3
- Tier 1: pipeline sub-workflows (1000s/day): MAIN, ARCHIVE, VITAL
- Tier 2: infrastructure + dispatchers (100s/day): FileGateway*, TimeoutEvent, Schedule_*, Pattern 3 dispatchers, FA_CLIENTS_EMAIL, FA_CLIENTS_GET_LIST
- Tier 3: named scheduled pullers/pushers (10-50/day): FA_FROM_*_PULL, FA_TO_*_PUSH, client-specific wrappers
- Tier 4: daily workflows (1-2/day): vast majority of client-specific FA_FROM_*/FA_TO_*

**2026-04-24 — 11 active FA_CLIENTS top-level workflows; 17 dormant FA_CLIENTS workflows** — source: Step 6A; roles corrected by Step 6C
Active top-level: MAIN, VITAL, ARCHIVE, EMAIL, JIRA_TICKETS, GET_LIST, ENCOUNTER_LOAD, CNSMR_ACCNT_AR_IB_BDEO_S2X_BDL, CNSMR_TAG_IB_BDEO_S2X_BDL, GROUP_KEYS_SP, INVALID_ACCOUNTS_OB_EOBD_D2S_RPT.
Step 6C corrected the earlier "all 17 dormant run inline inside MAIN" framing. Verified roles: 13 are invoked from MAIN (GET_DOCS, PREP_SOURCE, TRANS, ARCHIVE*, FILE_MERGE, POST_TRANSLATION, WORKERS_COMP, DUP_CHECK, ADDRESS_CHECK, PREP_COMM_CALL, COMM_CALL, ACCOUNTS_LOAD, TRANSLATION_STAGING — mix of inline and async mechanisms, see Step_06C_Findings §6); ETL_CALL is dispatched by GET_LIST for ETL_PATH clients (not deprecated — it is the Pervasive djengine path); ENCOUNTER_ID is invoked only by ENCOUNTER_LOAD; REMIT_DATA_VERIFICATION is a top-level client-328 wrapper (simply idle in the observed 30d window); TABLE_INSERT and TABLE_PULL are orphaned — referenced by nothing in the corpus. (*ARCHIVE/VITAL/ACCOUNTS_LOAD/ENCOUNTER_LOAD appear in both lists because they run standalone when invoked async and invisibly when invoked inline.)

**2026-04-24 — MAIN currently at WFD_VERSION 48, ran at 2 distinct versions in the 30-day window** — source: Step 6A
Mid-flight version migration is the observed mechanism — when MAIN is edited, in-flight instances continue running the old version until they complete. BPML extraction must use MAX(WFD_VERSION) per WFD_ID.

**2026-04-24 — FA_CLIENTS_MAIN v48 has 23 top-level rules and 590 total elements** — source: Step 6B; refined by Step 6C
Rule names verified from BPML source: AnyMoreDocs?, Prep?, PreArchive?, Translate?, DupCheck?, WorkersComp?, PostArchive?, SendEmail?, CommCall?, MergeFiles?, PrepCommCall?, VITAL?, PostArchive2?, Wait?, Continue?, NB?, Encounter?, AddressLookup?, SaveDoc?, PostTranslation?, PostTranslationVITAL?, TranslationStaging?, RemoveSpecialCharacters?. Step 6C: 23 rules are defined but only 22 are live — `SaveDoc?` is never referenced by any case. This reconciles the legacy "~22" with 6B's "23".

### 4.2a Execution model and dispatchers (Step 6C)

**2026-07-10 — The execution model is a single spine** — source: Step 6C (BPML corpus)
Every client pipeline runs: wrapper/schedule sets parameters → inline-invokes `FA_CLIENTS_GET_LIST` → GET_LIST runs `faint.USP_B2B_CLIENTS_GET_SETTINGS` and `faint.USP_B2B_CLIENTS_GET_LIST ?,?,?,?,?` → per queued client row invokes `FA_CLIENTS_MAIN` (or `FA_CLIENTS_ETL_CALL` when ETL_PATH is set) with no INVOKE_MODE specified → unconditionally clears `etl.tbl_B2B_CLIENTS_FILES.RUN_FLAG`. **MAIN is invoked by exactly one workflow in the entire 429-file corpus: GET_LIST.** There is no second entry point.

**2026-07-10 — 361 of 371 wrapper-family BPMLs are identical 2-operation wrappers** — source: Step 6C census (complete, not sampled)
Shape: AssignService parameter block + `InlineInvokeBusinessProcessService` of GET_LIST. Seven parameter profiles map one-to-one onto the GET_LIST proc signature (CLIENT_ID, SEQ_ID, SEQ_IDS, PROCESS_TYPE, SEQUENTIAL) plus a COMM_METHOD override (3 files). The legacy "Pattern 1-5" dispatcher taxonomy collapses to one structural pattern. The 10 non-standard files are catalogued in Step_06C_Findings §3 for 6F. The Pattern-3 pair and four FA_CLIENTS-named top-level workflows are ordinary client-328 wrappers.

**2026-07-10 — The GET_LIST instance-count shortfall is resolved structurally** — source: Step 6C
All 367 corpus references to GET_LIST are inline invocations, which produce no WF_INST_S rows. The 85 standalone GET_LIST rows per 30d can only be direct scheduler fires. Runtime confirmation of the schedule itself: 6E.

**2026-07-10 — tbl_B2B_CLIENTS_BATCH_STATUS vocabulary and correlation keys** — source: Step 6C
Writer-verified values: -2 = skipped because predecessor in a SEQUENTIAL chain failed (written by MAIN's own tail when its poll returned -1 — a cascade-skip marker, **not** a legacy code path); -1 = own fault; 1 = ETL complete (ETL_CALL only); 2 = GET_LIST dispatch complete, or MAIN processed (BDL always; NB/PAYMENT with files, no dup); 3 = MAIN processed, other types; 4 = no files; 5 = duplicate. Correlation: dispatcher WF_INST_S.WORKFLOW_ID = RUN_ID of its inline GET_LIST's row; MAIN's WORKFLOW_ID = its own RUN_ID with PARENT_ID = dispatcher's id; COMM_CALL writes the DM-assigned batch id into BATCH_STATUS.BATCH_ID (the B2B → Batch Monitoring bridge, source-verified). Known columns: CLIENT_ID, SEQ_ID, RUN_ID, PARENT_ID, BATCH_STATUS, FINISH_DATE, BATCH_ID.

**2026-07-10 — Integration stored procedures live in schema `faint`; tables in `etl` (plus `dbo.FAI_FILE_ID`)** — source: Step 6C, refined in 6D
USP_B2B_CLIENTS_GET_SETTINGS, USP_B2B_CLIENTS_GET_LIST, USP_B2B_CLIENTS_WORKERS_COMP_CHECK, USP_B2B_CLIENTS_GROUP_KEYS (+ USP_FA_JACK_HUGHSTON_IB_EO_ENC_UPD in a 6F workflow). The ArchitectureOverview records the same `faint` schema, agreeing with source.

**2026-07-10 — Three sub-workflow invocation mechanisms exist, plus a default** — source: Step 6C
(1) `InlineInvokeBusinessProcessService` participant; (2) `InvokeBusinessProcessService` with INVOKE_MODE=INLINE; (3) Compression Service `decompress_result=start_bpml` (PREP_SOURCE bootstraps ARCHIVE this way — ARCHIVE has four call sites, not three); plus InvokeBusinessProcessService with no INVOKE_MODE at all (GET_LIST → MAIN/ETL_CALL, Sterling default). Whether the inline variants differ in WF_INST_S/WORKFLOW_LINKAGE visibility is a 6E question.

**2026-07-10 — The merged-output filename formula** — source: Step 6C (MAIN preamble; consumed by ARCHIVE flag-2, ADDRESS_CHECK, PREP_COMM_CALL DM drops)
`CLIENT_NAME(spaces→_) + '.DM.' + yyyyMMdd + '_' + <MAIN WORKFLOW_ID> + ('.NB'|'.PAY'|'.BDL'|'.') + '.txt'`.

**2026-07-10 — Source-level defects catalogued** — source: Step 6C, §9
Four dead rules (MAIN SaveDoc?, GET_LIST UpdateRunFlag?, VITAL NB?, ACCOUNTS_LOAD NB?); PostArchive? rule tautology (fires even when POST_ARCHIVE='N'); two orphaned workflows (TABLE_INSERT, TABLE_PULL); a TICKETS-insert column-count contradiction between MAIN (10 values) and GET_LIST (9 values) — at most one can succeed; an ETL_CALL infinite-poll hazard (waits for predecessor status exactly 3; -1/-2/4/5 stall it forever). Details and 6E follow-ups in Step_06C_Findings §9 and §12.

**2026-07-10 — BATCH_STATUS is a Sterling-to-DM lifecycle tracker with a reconciliation stage** — source: Step 6E (F6)
SQL Agent job 'INT Clients Update Batch Status' runs `FAINT.USP_B2B_CLIENTS_UPDATE_BATCH_STATUS`, promoting rows at status 2 against DM outcomes in crs5_oltp (new_bsnss_btch, cnsmr_pymnt_btch, file_registry). Final vocabulary in Step_06E_Findings §4a: 0 in-flight (column default), -2 cascade-skip, -1 Sterling fault OR DM-rejected, 1 unreachable, 2 transitional (B2B done, awaiting DM), 3 fully complete, 4 no files OR no handoff, 5 duplicate.

**2026-07-10 — GET_LIST fault tickets broken in production since ~2025-09** — source: Step 6E (R3/F1)
tbl_B2B_CLIENTS_TICKETS has 11 columns with identity ID; GET_LIST's 9-value positional insert cannot succeed (CLIENT_KEY added ~Aug 2025). Last GET_LIST-origin ticket: 2025-08-23. GET_LIST faults are currently unreported. Fix path: GET_LIST v20 with column-listed inserts.

**2026-07-10 — ETL_CALL confirmed dead** — source: Step 6E (R5/R10)
The proc's ETLAP arm carries the comment "DISABLING ETLAP 08/26/2024"; ETL_PATH is pivot-derived from nothing current; zero BATCH_STATUS = 1 rows exist in table history.

**2026-07-10 — Dispatch visibility model verified live** — source: Step 6E (R1/R2)
Inline invocations leave no runtime trace; the no-INVOKE_MODE GET_LIST → MAIN dispatch creates a child WF_INST_S instance plus a WORKFLOW_LINKAGE row (TYPE='Dispatch', ROOT_WF_ID = wrapper). Correlation keys from Step 6C hold exactly.

**2026-07-10 — Wrapper population final: 369; corpus current** — source: Steps 6E-6F
The 2026-06-22 Sterling edit session (MAIN v49, PREP_SOURCE v35, TRANS v7 — CLN_ARCHIVE cleanup feature + Code-25 translation hardening) and two new client-328/10575 wrappers were caught by a one-query WFD version census and merged into the corpus. GET_LIST unchanged since 2023-12 (still v19).

**2026-07-10 — Work-queue proc internals verified** — source: Step 6E (R10)
Branch 1 (scheduler, AUTOMATED=1) / Branch 2 (wrappers, AUTOMATED=2); PREV_SEQ via LAG per (CLIENT_ID, GET_DOCS_LOC) with SEQUENTIAL override; the discovered-files table is truncated and reloaded every ~10 minutes by client 328 SEQ 12 (config SQL_QUERY + translation map); 68-parameter pivot. Schedules verified via SI_ScheduleRegistry (GET_LIST hourly :05, 05:05-15:05 M-F).

**2026-07-12 — Reconciliation job schedule: every 1 minute, 00:15:00-18:59:59 daily** — source: msdb sysjobs/sysjobschedules/sysschedules
Job 'INT Clients Update Batch Status' (enabled) runs on schedule 'Daily': freq_type 4 (daily), every 1 minute (freq_subday_type 4, freq_subday_interval 1), active 00:15:00-18:59:59. Two consequences: (a) reconciliation lag is ~1 minute inside the window — status-2 transitions are far too fast for any collector polling interval to observe reliably, eliminating transition-watching as a discriminator; (b) the job is OFF from 19:00 to 00:15 (~5.25 hours), so evening-scheduled wrapper runs (the ~21:00 daily crowd: CNSMR_ACCNT_AR, CNSMR_TAG, INCEPTION_HOLD_TAG, FILE_REMOVE_VANDERBILT) legitimately sit at status 2 until the 00:15 pass. Status-2 aging alert thresholds must account for the off-window.

**2026-07-12 — The reconciler updates BATCH_STATUS only; promotion requires status 2; PROCESS_TYPE is derived** — source: proc source (FAINT.USP_B2B_CLIENTS_UPDATE_BATCH_STATUS, read end-to-end)
Every arm inner-joins `etl.tbl_B2B_CLIENTS_FILES` on CLIENT_ID + SEQ_ID (PROCESS_TYPE is not a BATCH_STATUS column — it comes from this join) and requires BATCH_STATUS = 2; the final UPDATE sets BATCH_STATUS and nothing else (FINISH_DATE untouched, so FINISH_DATE cannot discriminate writers). Mechanism confirmation: scheduler-fired GET_LIST rows carry SEQ_ID NULL and can never satisfy the join — they park at 2 forever, exactly as observed in 6E. -1 is written only through an inner join to a DM batch in failed/deleted state (NB stts_cd 5/3; BDL file_stts_cd 6/11); 4 is written only for NB/PAY/BDL rows at 2 with NULL BATCH_ID. New minor quirks for the defect ledger: the NB-success arm omits a PROCESS_TYPE filter (any status-2 row whose BATCH_ID matches an NB batch short name would promote — harmless with today's BATCH_ID vocabularies, but asymmetric by inspection); #TMP can theoretically collect the same ID twice with different statuses, leaving the final status to join order.

**2026-07-12 — tbl_B2B_CLIENTS_BATCH_STATUS full column list** — source: sys.columns
ID (int, identity), CLIENT_ID (bigint), SEQ_ID (int), PARENT_ID (int), RUN_ID (int), BATCH_ID (varchar(20)), BATCH_STATUS (int, default 0), INSERT_DATE (datetime, default getdate()), FINISH_DATE (datetime). All nullable except ID. INSERT_DATE is the age anchor for in-flight and stuck-at-status alerting. There is no PROCESS_TYPE column (derived via the FILES join — see reconciler entry above).

**2026-07-12 — tbl_B2B_CLIENTS_BATCH_FILES full column list; RUN_ID is NOT NULL** — source: sys.columns
ID (int, identity), CLIENT_ID (bigint), SEQ_ID (int), RUN_ID (int, NOT NULL), FILE_NAME (varchar(255), NOT NULL), FILE_SIZE (bigint), INSERT_DATE (datetime, default getdate()), COMM_METHOD (varchar(200)). Every pickup/delivery row is attributable to its pipeline run — the discriminator input for the status-4 split (§7.8).

**2026-07-12 — Full-history classification census (backfill profile)** — source: staged backfill against production, all 1,717,835 rows
BATCH_STATUS history reaches 2021-06-23 (not 2023-11 as previously assumed). Zero NULL RUN_IDs, zero duplicate RUN_IDs — the RUN_ID-unique grain holds across all history. Classification census: COMPLETE 1,065,789; NO_FILES 601,076; STERLING_FAULT 21,815 (~12/day, incl. 241 faults on non-handoff process types recovered from UNCLASSIFIED by the classification refinement); CASCADE_SKIP 14,131; DUPLICATE 6,441; NO_HANDOFF 4,133; DM_REJECTED 2,165; DIED_UNHANDLED 2,113 (exactly matching the 6E stuck-at-0 count — independent cross-validation); AWAITING_DM 170 (permanent limbo: handoffs whose DM batch never reached a recognized terminal code, all config-resolved); FAULT_POST_HANDOFF 2; UNCLASSIFIED 0. Classification refinement recorded in §7.8: -1 on a process type outside NB/PAY/BDL is a Sterling fault regardless of BATCH_ID (the reconciler never writes -1 for those types). Workflow definition count at census load: 1,460 (up 27 from the April investigation snapshot — the census exists precisely to catch this).

**2026-07-13 — WF_INST_S rows are written at termination, not during execution** — source: repeated production checks including during active processing windows
Queries for WF_INST_S rows with END_TIME IS NULL returned zero across multiple checks, including while pipeline processes were actively launching. Sterling does not expose running instances through this table; the old collector's "in-flight refresh" model (a retracted inherited claim, §4.6) is definitively dead. Consequence: a live "what is Sterling executing right now" engine panel cannot be built from WF_INST_S. The page's Live Pipeline Activity instead reads Integration BATCH_STATUS directly (rows appear the instant GET_LIST writes them), which covers pipeline-level liveness completely. WORKFLOW_CONTEXT remains the unverified candidate for step-level live data — its per-step rows exist, but whether they are written during execution or flushed at completion is unknown.

**2026-07-14 — INT_PipelineTracking classifies downstream (non-Sterling) failures, which is module overreach** — source: fault-report scoping review
The classification is derived from the Integration tracker's BATCH_STATUS = -1, which captures failures anywhere in the pipeline — including downstream of Sterling. DM_REJECTED and FAULT_POST_HANDOFF are post-handoff failures: the data left Sterling successfully and failed in DM or after handoff. These are owned by other modules (Batch Monitoring et al.), not by B2B, and runs classified this way often succeeded inside Sterling (all translation steps BASIC_STATUS = 0). The fault-report enrichment is correctly scoped to Sterling-internal faults only (STERLING_FAULT, DIED_UNHANDLED). The broader question — whether this module should classify/track downstream failures at all, or narrow its scope to Sterling-internal outcomes and defer downstream to the modules that own it — is a known scoping cleanup, deferred (this reinforces why the fault-report end result is driven off Sterling evidence rather than the Integration -1 population).

**2026-07-16 — Two parallel dispatch mechanisms; a run's dispatcher is arrival-time-routed** — source: production data analysis (parent/child chain + SI_ScheduleRegistry + reconciler behavior)
Files are dispatched by whichever of two mechanisms reaches them first, based on arrival time: (a) **GET_LIST**, the hourly compiler proc `FAINT.USP_B2B_CLIENTS_GET_LIST` (runs :05 past the hour, 05:05-15:05 M-F), which sweeps whatever files are present at its run; and (b) **per-client schedules** in SI_ScheduleRegistry (e.g. every-15-min, daily-at-05:30), which fire on their own timers and catch files that arrived in their window. A file landing at 08:03 is caught by GET_LIST at 08:05; the same client's file landing at 08:28 is caught by its 08:30 schedule. **Consequence:** the same (client_id, seq_id, process_type, comm_method) can legitimately carry different dispatchers on different runs — this is arrival-time routing, not ambiguous data. This explains the two dual-dispatcher combos found during the backfill uniqueness check. In the mirror, GET_LIST runs appear as their own parent rows (process_type='CORE_PROCESS', client_name='CLIENTS GET LIST', client_id=0, dispatcher_name='FA_CLIENTS_GET_LIST', self-naming); every run they launch is a child linked by parent_id. Scheduled-dispatcher runs are top-level parent rows (NULL seq_id/process_type) whose true dispatcher is the firing schedule's service_name. The childless NULL-dispatcher rows are scheduled sweeps that fired and found no work (empty polls).

**2026-07-16 — Dispatcher backfill: ~1.3M of ~1.7M NULL dispatcher_name resolved from durable in-table structure** — source: staged backfills against production
Prior to 2026-07-16, dispatcher_name was NULL for ~1.7M rows: the collector's dispatcher-resolution step (b2bi WF_INST_S linkage) deployed ~2026-07-10 14:56 and only resolves the last b2b_collect_lookback_days within Sterling's ~48h runtime retention, so all pre-deploy history stayed NULL. Two structural backfills closed most of the gap without touching b2bi: (1) **GET_LIST population** — the ~13,064 CORE_PROCESS sweep parents (self-named) plus their ~236,927 children (resolved via parent_id → CORE_PROCESS parent, keyed on the parent's durable process_type not its dispatcher, so order-independent). (2) **Single-match sibling lookup** — for NULL rows, looked up (client_id, seq_id, process_type, comm_method) among the ~6 days of real-time-collected resolved rows, applying the dispatcher only where that key maps to exactly one distinct non-GET_LIST dispatcher (HAVING COUNT(DISTINCT)=1); populated ~1,052,954 rows. All writes guarded on dispatcher_name IS NULL. **Remaining ~412K NULLs, fully characterized:** ~263K non-seq parent rows + ~150K of these are top-level scheduled dispatchers (149,879), whose ~250K children point up to them; plus ~13K parentless seq'd orphans and 2 dual-routed ambiguous combos left NULL by design. The remainder is **blocked on a durable run→SI_ScheduleRegistry link, which does not exist in the table today** — the genuine open problem (see Next Session §1). Accepted assumption for the sibling backfill: a client/seq's dispatcher identity is stable over time (dispatchers edited in place, not swapped) — likely but unverified for full history; the two ambiguous combos may be the canaries if it ever fails.

**2026-07-16 — SI_ScheduleRegistry is a comprehensive, current mirror of b2bi.dbo.SCHEDULE — NOT a legacy slice** — source: collector Step-b2b_SyncSchedules source read
The schedule sync was built in April for the first (FA_CLIENTS_MAIN-scoped) B2B attempt, raising a concern that it might only cover a legacy client subset. Reading the running source disproves this: the sync's source query pulls `FROM dbo.SCHEDULE` with the only filter being `TIMINGXML IS NOT NULL AND <> ''` (excludes timing-less rows, not a business-scope filter), and it does full insert/update/delete reconciliation (deletes schedules no longer in b2bi). Uneven last_modified timestamps across schedules are correct behavior — the sync only rewrites a row when its TIMINGXML/status actually changes, so stable schedules keep old timestamps. The table is trustworthy and comprehensive as a dispatcher-identity source; what is missing is only the run→schedule *link*, not schedule coverage.

**2026-07-16 — Sterling runtime retention is ~48h for the dispatcher-resolution path** — source: 2026-07-16 session (Dirk)
Note this refines the operative window for dispatcher resolution specifically: the b2bi core runtime tables backing WF_INST_S dispatcher lookup hold ~48h, not the ~30-day combined live+RESTORE archive horizon recorded 2026-04-24 (§4.3). The b2bi module enable on 2026-07-12 loaded whatever ~48h of runtime data existed at that moment. Practical effect: the b2bi path can never backfill historical dispatchers — hence the in-table structural approach above. (The ~30-day §4.3 figure was the WF_INST_S + WF_INST_S_RESTORE archive combination; the ~48h is the live runtime window relevant to same-cycle resolution. Flagged for reconciliation if these prove to be describing the same tables.)

### 4.3 Retention and archive

**2026-04-24 — Data horizon is ~30 days, not ~48 hours** — source: Step 2
`WF_INST_S`: ~7 days live. `WF_INST_S_RESTORE`: ~22 days archived. Combined: ~30 days. Clean archive model — live/restore are disjoint.

**2026-04-24 — Archive is transactional across related tables** — source: Step 2
`TRANS_DATA_RESTORE` has zero orphans relative to `WF_INST_S_RESTORE`. Payloads and workflows archive in lockstep.

**2026-04-24 — `ARCHIVE_INFO` drives purge, is forward-looking** — source: Step 2
4-column table with WF_ID, GROUP_ID, ARCHIVE_FLAG, ARCHIVE_DATE. `ARCHIVE_DATE` represents when Sterling *will* archive, not when it did. Four `GROUP_ID` values appear to represent archive table-group tiers. `ARCHIVE_FLAG = -1` is a post-purge bookkeeping state, not "never archive."

**2026-04-24 — `WORKFLOW_CONTEXT` and `TRANS_DATA` live tables have orphan rows** — source: Step 2 addendum
~0.02% of rows in each are from workflows whose `WF_INST_S` parent has been archived. Archive inconsistency at the edges. Benign but worth knowing for collector robustness.

**2026-07-14 — Fault-report capture is bounded by ~3-4 day handle retention, not blob retention** — source: fault-report feature investigation
WORKFLOW_CONTEXT and its restore sibling WFC_S_RESTORE purge within roughly 3-4 days (WFC_S_RESTORE oldest row observed at ~4 days). TRANS_DATA report blobs persist far longer (1.25M rows back to 2025-03, ~16 months), but are unreachable once the STATUS_RPT handle in WORKFLOW_CONTEXT is gone — there is no linkage from run to blob without it. Consequence: fault-report capture is go-forward only. The collector captures within its lookback window (b2b_collect_lookback_days, default 3) and preserves each report permanently in SI_FaultReport; no historical backfill beyond a few days is possible. Two fault-detection facts also verified: STATUS_RPT is populated on ordinary successful steps too (routine per-step status output — SFTP transfers, timestamps, waits), so a genuine fault is identified by BASIC_STATUS <> 0 on a report-producing service (Translation, XSLTService, InlineInvokeBusinessProcessService, MailMimeService), not by the presence of a handle; and some handles resolve to raw-serialized objects (magic 0xACED, e.g. BUSINESS_PROCESS_MARK) rather than gzip reports (0x1F8B), so a gzip-magic check gates decompression.

### 4.4 Sterling table semantics

**2026-04-24 — `WF_INACTIVE` is an indefinite audit log, not a current-state table** — source: Step 4
1,745 of 1,746 rows are orphans from purged workflows. All rows have `REASON = 105`. 73% of rows come from two incident clusters (Nov 23-26, 2025 and Dec 9-16, 2025). Useless for retrospective queries. Could be a real-time alert trigger if combined with workflow-context capture at insert-time.

**2026-04-24 — `CORRELATION_SET` is SFTP/Translation event metadata** — source: Step 5
Per-document key-value pairs scoped to only 3 workflow families: MAIN (primary), ENCOUNTER_LOAD, DM_ENOTICE. Only ~14% of MAIN runs are instrumented (those doing actual SFTP pickup + translation). 12-key vocabulary dominated by SFTP transfer metadata. Retention matches WF_INST_S.

**2026-04-24 — WFD primary key is `(WFD_ID, WFD_VERSION)`** — source: Step 3 correction, confirmed Step 6A
Every workflow edit creates a new WFD row with incremented WFD_VERSION. Joining to WFD on WFD_ID alone produces cartesian products across version history. Collector code must join on `(WFD_ID, WFD_VERSION)` or use a one-row-per-WFD_ID lookup CTE.

**2026-04-24 — `WF_INST_S.STATUS` shows only values 0 and 1 in 30 days of production** — source: Step 6A
Across 38,211 instance rows, only STATUS values 0 and 1 are observed. Legacy framing "0 = success, 1 = terminated with errors" is consistent with this observation but semantic meaning has not been independently verified — noted as an open question for Step 6E.

**2026-04-24 — BPML storage model** — source: Step 6B
`b2bi.dbo.WFD_XML` is a thin 4-column lookup (one row per (WFD_ID, WFD_VERSION)). Its `XML` column is a handle (nvarchar(255)) joining to `b2bi.dbo.DATA_TABLE.DATA_ID`. The actual BPML lives in `DATA_TABLE.DATA_OBJECT` (image type), gzip-compressed, with a 6-32 byte Java serialization preamble before the XML content. No pagination — all blobs at PAGE_INDEX=0. Total corpus for 429 latest-version BPMLs: ~193 KB compressed, ~640 KB decompressed.

### 4.5 Workflow identity and structure

**2026-04-24 — FA_FROM_* / FA_TO_* suffix convention encodes direction and business type** — source: Step 3
Active suffix codes observed: `_PULL`, `_PUSH`, `_S2D`, `_D2S`, `_IB`, `_OB`, `_BD`, `_EO`, `_NB`, `_NT`, `_RT`, `_RM`, `_SP`, `_TR`, `_RC`, `_FD`. This is the natural classification axis for client-specific workflows. Step 6C's dispatcher census showed the suffix encodes business labeling only — structurally all standard wrappers are identical, so suffix parsing matters for cataloguing (6F), not for execution-model analysis.

**2026-04-24 — Every b2bi BPML has `<process>` as its root element** — source: Step 6B
All 429 extracted BPMLs parse as well-formed XML with root tag `<process name="...">`. Element counts range from 7 (smallest workflow) to 590 (FA_CLIENTS_MAIN v48). Median BPML has 16 elements. Corpus total: 11,045 elements.

**2026-04-24 — BPMLs can optionally include XML comment prologues** — source: Step 6B
Sterling-shipped workflows (AFT*, some Schedule_*) include copyright/documentation `<!-- ... -->` blocks before `<process>`. FAC-authored (FA_*) workflows do not. Not functionally significant but noted as a classification signal for 6F.

### 4.6 Retracted inherited claims (from prior investigation; to be re-verified)

The previous Roadmap §4.6 ("Carried forward from v1") included claims about ProcessData location, WORKFLOW_CONTEXT marker conventions, ROOT_WF_ID behavior, STATUS/STATE semantics, and MAIN sub-workflow invocation patterns. **These were inherited from pre-investigation documents and legacy single-run traces, not verified in Steps 1-5.** Per the reset, they are null-and-void until re-verified through BPML reading (Step 6C) or runtime observation (Step 6E).

Status update (v2.4): MAIN sub-workflow invocation patterns are now re-verified from BPML source (Step 6C, §4.2a above). Still requiring re-verification:
- ProcessData is gzip-compressed in TRANS_DATA.DATA_OBJECT, first DOCUMENT row by CREATION_DATE ASC
- Write-at-termination for WF_INST_S with ~5-10 min lag
- WORKFLOW_CONTEXT is written in real-time during workflow execution
- ROOT_WF_ID accurately identifies workflow tree roots in WORKFLOW_LINKAGE
- STATUS semantics (0 = success, 1 = error) — value range confirmed in Step 6A, semantics not verified

---

## 5. Investigation Register

Each topic has a status, a short summary of what we know, and a link to the relevant findings doc. For detailed technical data, refer to the findings doc directly — this section intentionally stays slim.

### 5.1 b2bi Database Catalog

**Status:** ✅ Resolved
**Findings:** `Step_01_Database_Catalog/Step_01_Findings.md`

b2bi has 773 tables, 186 populated. Zero FKs. Full inventory of the workflow-execution surface identified. `_RESTORE` table family discovered. Sterling version 6.1.0.0 confirmed.

### 5.2 Retention and Archive

**Status:** ✅ Resolved
**Findings:** `Step_02_Retention_and_Archive/Step_02_Findings.md`

30-day data horizon across live + `_RESTORE` tables. Clean archive model. `ARCHIVE_INFO` drives forward-looking purge. No need for external historical sources (VITAL, Integration) for backfill as long as collector runs continuously.

### 5.3 Workflow Universe

**Status:** ✅ Resolved (updated in Step 6A)
**Findings:** `Step_03_Workflow_Definition_Catalog_and_Active_Inventory/Step_03_Findings.md`, updated in `Step_06A_Active_Workflow_Catalog/Step_06A_Findings.md`

1,433 distinct workflow definitions; 413 active in a 30-day window (up from Step 3's 332 at 48h). Four velocity tiers characterized. FA_* naming convention documented. MAIN is 16% of activity; ARCHIVE and VITAL each run more often than MAIN. 11 active + 17 dormant FA_CLIENTS workflows catalogued for BPML extraction in Step 6B.

### 5.4 WF_INACTIVE

**Status:** ✅ Resolved — deprioritized
**Findings:** `Step_04_WF_INACTIVE/Step_04_Findings.md`

Halt audit log with indefinite retention. 99.94% orphan rate. Potentially useful as real-time alert signal if captured at insert-time, but not for retrospective queries.

### 5.5 CORRELATION_SET

**Status:** ✅ Resolved — role identified as enrichment
**Findings:** `Step_05_CORRELATION_SET/Step_05_Findings.md`

Per-document SFTP/translation metadata for a narrow subset of workflow families. Valuable enrichment layer for MAIN runs that do file ingestion. Not a universal workflow source.

### 5.6 FA_CLIENTS_MAIN Anatomy (Step 6 umbrella)

**Status:** ✅ CLOSED — all sub-steps 6A-6G complete (2026-07-10)
**Findings so far:**
- `Step_06A_Active_Workflow_Catalog/Step_06A_Findings.md`
- `Step_06B_BPMLs/Step_06B_Findings.md`
- `Step_06C_BPML_Analysis/Step_06C_Findings.md`

Step 6 has been restructured into checkpointed sub-steps after the scope expanded from "MAIN anatomy only" to "verify the full architecture described in the legacy ArchitectureOverview document." The legacy document contains both accurate and known-false content about MAIN, its sub-workflows, and the broader Sterling architecture. Step 6 extracts every factual claim into a verification checklist and resolves each against BPML source or runtime observation.

Sub-step sequence:

- **6A — Active Workflow Catalog** ✅ Complete. 1,433 WFDs catalogued, 413 active in 30d, extraction target list of 429 BPMLs identified (413 active + 17 dormant FA_CLIENTS, minus 1 overlap).
- **6B — BPML Bulk Extraction** ✅ Complete. BPML storage model discovered (WFD_XML → DATA_TABLE indirection, gzip+Java-preamble encoding). All 429 BPMLs extracted, parsed as well-formed XML, and organized by family. Extraction tool `Step_06B_Extract_BPMLs.ps1` available for re-extraction as b2bi evolves. (The BPML corpus was later removed from the repo for manifest-size reasons; re-supply as a zip or re-extract.)
- **6C — Core Workflow BPML Analysis** ✅ Complete. All 28 FA_CLIENTS BPMLs deep-read; all 371 wrapper-family BPMLs shape-verified (census, not sample). Execution model verified as a single spine; dispatcher taxonomy collapsed to one wrapper pattern; BATCH_STATUS vocabulary recovered; invocation mechanisms catalogued; Integration DB surface, executables, maps, and client-config surface inventoried; four dead rules, two orphaned workflows, and several source-level defects found. Output: `Step_06C_BPML_Analysis/Step_06C_Findings.md`.
- **6D — Claim Verification** ✅ Complete. Every ArchitectureOverview claim dispositioned in `Step_06D_Claim_Verification/Step_06D_Claim_Checklist.md`; final tally 63 verified / 17 corrected / 3 refuted; verdict: retire the document.
- **6E — Runtime Verification** ✅ Complete (`Step_06E_Runtime_Verification/Step_06E_Findings.md`). All R1-R18 + F1-F6 targets resolved: reconciliation job discovered, final BATCH_STATUS vocabulary, TICKETS bug, ETL_CALL death, dispatch visibility, schedules, proc internals, corpus refresh.
- **6F — Light Catalog** ✅ Complete (`Step_06F_Light_BPML_Catalog/Step_06F_Findings.md`), executed ahead of 6E. All 429 corpus files accounted for; ENOTICE pipeline mapped; two out-of-family wrappers found.
- **6G — Consolidation** ✅ Complete: `Step_06G_Consolidation/Step_06G_Summary.md` is the entry point to the verified model; checklist finalized; ArchitectureOverview RETIRED.

**What comes after Step 6:** collector architecture decisions (§7) can finally be addressed with verified structural knowledge of every workflow in play.

### 5.7 Sub-workflow Families (ARCHIVE, VITAL, EMAIL, ENCOUNTER_LOAD)

**Status:** ✅ Structural coverage complete (Step 6C); standalone runtime deep-dives deferred
**What we know:** ARCHIVE runs 10,167/30d; VITAL runs 10,179/30d; EMAIL 620/30d; ENCOUNTER_LOAD 82/30d (6.1% fail rate — highest among FA_CLIENTS). Step 6C deep-read all of them: ARCHIVE is a trivial two-extract workflow gated by caller flags (consistent with its zero-failure record); VITAL and ACCOUNTS_LOAD write to the database through translation maps (targets invisible in BPML — 6E); ENCOUNTER_LOAD's failure surfaces are two maps, the ID allocator, and a lock executable; EMAIL is environment-aware with hardcoded SMTP relay/sender. Runtime behavior analysis (failure modes across runs, output content) comes after Step 6 completes.

### 5.8 Dispatcher Workflows

**Status:** ✅ Resolved structurally (Step 6C census); dispatcher_name population ~76% backfilled (2026-07-16), remainder blocked on run→schedule link
**What we know:** All 371 FA_FROM/FA_TO/FA_DM/FA_OTHER/FA_Specialized BPMLs were shape-verified — 361 are identical 2-operation wrappers (parameter assign + inline GET_LIST invoke) with seven parameter profiles; the legacy Pattern 1-5 taxonomy collapses to one structural pattern. The Pattern-3 pair are ordinary client-328 wrappers (SEQ_ID 12/13). The GET_LIST shortfall (85 standalone vs ~242 expected) is explained: all workflow-side invocations are inline and produce no WF_INST_S rows; standalone rows are scheduler fires only.
**Dispatch model + backfill (2026-07-16, see §4.2a):** the two-mechanism arrival-time-routed dispatch model is now verified from production data. dispatcher_name was historically backfilled — ~1.3M of ~1.7M NULLs resolved via the GET_LIST parent/child chain and single-match sibling lookup, both sourced from durable in-table structure rather than the ~48h b2bi runtime. The remaining ~412K is characterized: ~150K top-level scheduled-dispatcher parents (+ ~250K inheriting children) blocked on a durable run→SI_ScheduleRegistry link that does not exist in the table today, plus ~13K parentless orphans and 2 ambiguous combos left NULL. **The run→schedule linkage is the open dispatcher problem** — either a source-side key (Integration/b2bi) or periodic re-runs of the sibling backfill as more schedule-fired data accumulates. CLIENTS_PARAM's TRANSLATION_MAP was evaluated and rejected as a dispatcher source: it names the execution/translation service, not the dispatcher, and disagreed with trusted resolved rows.

### 5.9 Process Type Semantics

**Status:** 🔄 Partially grounded by Step 6C; verification deferred
**What we know:** Legacy `ArchitectureOverview` documents 31 distinct PROCESS_TYPE × COMM_METHOD combinations. Step 6C verified from source how the major values behave inside MAIN and its sub-workflows (NEW_BUSINESS, PAYMENT, BDL, SFTP_PULL, SFTP_PUSH, FILE_DELETION, SIMPLE_EMAIL, OUTBOUND as COMM_METHOD) and found an older 'TRANSACTION' vocabulary in the orphaned TABLE_PULL. Full combination-matrix verification happens after Step 6 provides the runtime baseline.

### 5.10 Integration Database Tables

**Status:** 🔄 Sterling-side references now verified (Step 6C); Integration-side verification deferred
**What we know (source-verified):** Sterling BPMLs reference tables `etl.tbl_B2B_CLIENTS_BATCH_STATUS` (incl. BATCH_ID), `_BATCH_FILES`, `_FILES` (RUN_FLAG), `_TICKETS`, `_ACCTS`, `_OUTPUT_FILES` (orphaned writer), `_MERGED_FILES` (orphaned reader), `dbo.FAI_FILE_ID`, and `etl.tbl_ENOTICE_TO_REVSPRING_VALDN(_ARC)`; procs live in schema `faint` (see §4.2a); `WORKFLOW_ID` = `RUN_ID` correlation is confirmed from the BPML side. **Update 2026-07-12:** BATCH_STATUS and BATCH_FILES table shapes are now verified from sys.columns (§4.2a); TICKETS column count was verified in 6E. Still unverified on the Integration side: the four translation maps' target tables and the CLIENTS config table backing USP_B2B_CLIENTS_GET_LIST (~60 consumed fields inventoried in Step_06C_Findings §8.5, including four arbitrary-SQL fields and four executable-path fields).

### 5.11 VITAL Database

**Status:** 🔄 Not yet addressed — likely deprioritized

### 5.12 Other Unexamined Tables

**Status:** 🔄 Listed, not yet investigated
**Candidates:** `ACT_XFER` (33K rows), `ACT_NON_XFER` (48K rows), `ACTIVITY_INFO` (33K rows), `DATA_FLOW` (30K rows), `ACT_SESSION` (17K rows), `DOCUMENT` (348K rows), `DOCUMENT_EXTENSION` (235K rows), `SCHEDULE` (605 rows; already known via `SI_ScheduleRegistry`), `SERVICE_INSTANCE`, `SERVICE_DEF`, `SERVICE_PARM_LIST`.

### 5.13 Historical Coverage Strategy

**Status:** 🔄 Reframed; simpler than previously thought

### 5.14 Real-Time In-Flight Visibility

**Status:** ✅ Decided (7.6) — derived from mirror aging; no live Sterling querying in v1

### 5.15 Open questions

**Closed as of Step 6G.** All investigation questions resolved (see Step_06E_Findings §4-5 and Step_06D_Claim_Checklist §14). Residual non-blocking notes: R9 (TRANS FILELIST/SIZE quirk) and R12 (child-onFault propagation) remain opportunistic inspection items. The reconciliation job's schedule, previously parked here, was resolved 2026-07-12 (§4.2a).

---

## 6. Out of Scope

- Sterling clustering / multi-node architecture — single-node deployment
- Sterling version upgrades or migration planning
- b2bi admin console internals — not a SQL data source
- Direct integration with Sterling REST APIs
- Anything pre-Sterling (Pervasive-era) beyond what VITAL captures, if we even pursue VITAL

---

## 7. Decisions (recorded 2026-07-12)

All seven architecture decisions were made in one session against the fully verified model, supplemented by same-day discovery reads: the reconciliation job schedule, the reconciler proc source end-to-end, and the BATCH_STATUS / BATCH_FILES column lists (all recorded in §4.2a). §7.8 records the status disambiguation model settled alongside them.

### 7.1 SI_ExecutionTracking scope — DECIDED: clean rebuild

The existing collector was premised on MAIN as the universal grain, which the investigation refuted. The verified grain is the BATCH_STATUS row: one per pipeline run, parent-linked, DM-bridged, and DM-reconciled. The old table holds ~3-4 days of data with no downstream consumers; replacement carries no blast radius. `B2B.SI_ExecutionTracking` and `Collect-B2BExecution.ps1` are retired as part of the build.

### 7.2 Collector architecture — DECIDED: one primary collector + census drift signal

One collector mirrors BATCH_STATUS (enriched at collection time — see 7.8). The WFD version census (the one-query check that caught Sterling changing twice during the investigation) is included as a standing drift signal; whether it lives inside the same collector script or as a small sibling is settled during the build against existing collector patterns. `B2B.SI_ScheduleRegistry` and its sync continue as-is.

### 7.3 Sub-workflow execution detail — DECIDED: not tracked in v1

Inline invocations are runtime-invisible by mechanism; async children (VITAL, ARCHIVE, EMAIL, ENCOUNTER_LOAD) do not change the pipeline outcome the BATCH_STATUS row already records. Tracking them adds volume without adding decisions anyone would make differently. Revisit only if fault triage demonstrates need.

### 7.4 Dispatcher tracking — DECIDED: attribute, not entity

All 369 wrappers are structurally identical shells; the wrapper run IS the pipeline run (its WORKFLOW_ID = the GET_LIST-portion RUN_ID). Dispatcher identity is a descriptive attribute on the run record, not its own table or discriminator scheme.

### 7.5 VITAL / Integration strategy — DECIDED: mirror Integration; VITAL not pursued

The reconciliation job means Integration's BATCH_STATUS already holds pipeline-final outcomes including DM confirmation. The collector mirrors it rather than recomputing the lifecycle. VITAL is not pursued.

### 7.6 Real-time in-flight visibility — DECIDED: derived from the mirror; no live Sterling querying in v1

Rows aging at status 0 (in-flight / died unhandled) and status 2 (awaiting DM) ARE the in-flight view, anchored on INSERT_DATE. Thresholds must respect the reconciler off-window (§4.2a). Live WF_INST_S querying is deferred unless the aging view proves insufficient in practice.

### 7.7 Block 3 (execution detail extraction) — DECIDED: skipped in v1

WORKFLOW_CONTEXT parsing is the most expensive component with documented blind spots. The operational questions when something fails (which client, which run, what status, how long stuck) are answered by the mirror. Add later only if real fault-triage usage demands step-level detail.

### 7.8 Status disambiguation model (decision-phase output)

Per Dirk's direction, the dual-meaning statuses are disambiguated so the mirror matches what actually exists in the Integration process today. All discriminators are source-verified against the reconciler proc and work retroactively:

| Status | Classification rule |
|--:|---|
| -2 | Always cascade-skip (unambiguous). |
| -1, NULL BATCH_ID | Sterling fault pre-handoff (the reconciler never writes -1 without a DM join on BATCH_ID). |
| -1, BATCH_ID present, DM batch failed/deleted | DM rejection (the reconciler's write, re-derived from the same DM tables). |
| -1, BATCH_ID present, DM batch healthy | Sterling fault post-handoff — the data landed in DM but the pipeline died afterward. A distinct alert category, surfaced for free by this model. |
| 2 | Transitional. Aging is the signal; thresholds respect the reconciler off-window (§4.2a). |
| 4, PROCESS_TYPE not NB/PAY/BDL | No files, definitively (the reconciler's 4 applies only to NB/PAY/BDL). |
| 4, NB/PAY/BDL | Split via BATCH_FILES: pickup rows exist for the RUN_ID with FILE_SIZE > 0 → files were acquired → handoff never happened; none → genuinely no files. (FILE_SIZE > 0 required because the zero-size pathway also writes rows.) |

Refinement (2026-07-12, from the full-history profile): -1 on a process type outside NEW_BUSINESS/PAYMENT/BDL classifies STERLING_FAULT regardless of BATCH_ID — the reconciler never writes -1 for those types, so no DM rejection is possible there. This recovered all 241 historically UNCLASSIFIED rows. Transition-watching and FINISH_DATE were both evaluated and eliminated as discriminators (reconciler lag ~1 minute; reconciler never touches FINISH_DATE — §4.2a). DM outcome vocabularies for the -1/3 classification, from the reconciler source: new_bsnss_btch_stts_cd 8 complete / 5,3 deleted-failed; cnsmr_pymnt_btch_stts_cd 4 complete; file_stts_cd 8,5 complete / 6,11 failed; BATCH_ID literal '-1<' = empty-BDL success (parser artifact promoted to semantic marker — flagged for cleanup). These reconcile against Batch Monitoring's existing DM knowledge during schema design.

### 7.9 Coarse status model (sterling_status) — DECIDED 2026-07-16: two-layer status

status_classification (§7.8) is the detailed, full-vocabulary final classification. On top of it sits **sterling_status**, a closed five-value coarse status that is the page's primary display axis and answers the Sterling-level question independent of downstream DM outcome:

| sterling_status | Rolls up (status_classification) |
|---|---|
| SUCCESS | COMPLETE, AWAITING_DM, DM_REJECTED, FAULT_POST_HANDOFF (Sterling handed off; downstream DM outcome is secondary — AWAITING_DM is SUCCESS because Sterling is done at handoff) |
| FAILED | STERLING_FAULT, DIED_UNHANDLED (Sterling's own failures) |
| NO_ACTION | NO_FILES |
| IN_PROGRESS | IN_FLIGHT |
| UNDEFINED | UNCLASSIFIED, NO_HANDOFF, DUPLICATE, CASCADE_SKIP + ELSE catch-all |

Rationale: the module shows **end-to-end Sterling**, so the primary axis is the Sterling-level outcome; the detailed classification (including DM disposition) is the detail layer, surfaced only on the run-detail slideout. UNDEFINED doubles as a **drift sentinel** — any new/unmapped classification lands there and is visible at the year-summary level, so a non-zero UNDEFINED is the signal to investigate. NO_HANDOFF/DUPLICATE/CASCADE_SKIP are held in UNDEFINED pending source-verified meaning (one-line CASE edit each to re-bucket once confirmed). Column stored (not derived at display) with a CHECK constraint and DEFAULT 'UNDEFINED'; the collector derives it inline in both the insert and re-poll paths so history and go-forward match; historical rows backfilled. Object_Metadata descriptions are purpose-only (what the value IS), deliberately NOT listing rollups, so re-bucketing never forces a metadata edit.

Note on labels: sterling_status carries the clean UI wording ("Failed"); the classification layer keeps its own vocabulary ("Sterling Fault", "Fault Post-Handoff"). Adjacent on the slideout this reads as a genuine coarse/detail distinction rather than an inconsistency — no rename needed.

---

## 8. Reference Material

### Investigation findings (chronological)

All under `xFACts-Documentation/WorkingFiles/B2B_Investigation/` (flat sub-step folders):

1. `Step_01_Database_Catalog/Step_01_Findings.md` — 773 tables, Sterling 6.1 confirmed
2. `Step_02_Retention_and_Archive/Step_02_Findings.md` — 30-day horizon
3. `Step_03_Workflow_Definition_Catalog_and_Active_Inventory/Step_03_Findings.md` — workflow taxonomy + velocity tiers
4. `Step_04_WF_INACTIVE/Step_04_Findings.md` — audit log, deprioritized
5. `Step_05_CORRELATION_SET/Step_05_Findings.md` — enrichment role
6. Step 6 sub-steps:
   - `Step_06A_Active_Workflow_Catalog/Step_06A_Findings.md` ✅ Complete
   - `Step_06B_BPMLs/Step_06B_Findings.md` ✅ Complete (BPML corpus removed from repo; re-suppliable as zip or via `Step_06B_Extract_BPMLs.ps1`)
   - `Step_06C_BPML_Analysis/Step_06C_Findings.md` ✅ Complete — the structural reference for the FA_CLIENTS world
   - `Step_06D_Claim_Verification/Step_06D_Claim_Checklist.md` ✅ Complete (final dispositions §14-15)
   - `Step_06E_Runtime_Verification/Step_06E_Findings.md` ✅ Complete (+ query packs)
   - `Step_06F_Light_BPML_Catalog/Step_06F_Findings.md` ✅ Complete
   - `Step_06G_Consolidation/Step_06G_Summary.md` ✅ Complete — **read this first in any future session**

Each findings doc includes: purpose, summary of change, detailed findings, implications for the collector, resolved questions, new questions, and document status.

### Legacy pre-investigation docs (reference-only — reclassified)

Under `WorkingFiles/B2B_Investigation/Legacy/`:

- **`B2B_ArchitectureOverview.md`** — **RETIRED** (Step 6G verdict, 2026-07-10). Superseded by the Step 6C/6E/6F findings; every claim dispositioned in the 6D checklist. Kept for audit only; cite nothing from it.
- `B2B_Module_Planning.md` — Historical planning notes.
- `B2B_Reference_Queries.md` — SQL queries against b2bi/Integration. Partial verification.
- `B2B_ProcessAnatomy_NewBusiness.md` — Single ACADIA NB trace. Mostly accurate for its narrow scope but *not* a universal template.
- `B2B_Roadmap_V1.md` — Pre-investigation Roadmap, preserved for audit trail.
- `B2BInvestigate-*.ps1`, `B2BScheduleTimingXml*.ps1`, etc. — Legacy PowerShell investigation scripts. Useful for extraction patterns; not authoritative for conclusions.

### External references

- IBM Sterling B2B Integrator 6.1.0 docs: https://www.ibm.com/docs/en/b2b-integrator/6.1.0
- SterlingSync blog (practitioner reference): https://sterlingsync.com/

---

## 9. Next Actions

1. **🎯 Dispatcher run→schedule linkage.** The lead open problem (see Next Session §1 and §4.2a). Resolve the remaining ~150K top-level scheduled-dispatcher parents (+ ~250K inheriting children) by finding/capturing a durable run→SI_ScheduleRegistry key at the Integration/b2bi source, or by periodically re-running the single-match sibling backfill as more schedule-fired runs accumulate. Arrival-time cadence correlation is a possible inference fallback (design with uncertainty marking; never write inferred values into dispatcher_name as fact).
2. **Enrichment survey.** Decide what additional Integration/b2bi data to capture into the mirror, using the capture/join-on-demand framework (Next Session §2). CLIENTS_PARAM is a candidate reference source — likely join-on-demand, not copied in.
3. **Page/docs iteration.** Parent/child hierarchical run view in the history tree (parent linkage now proven; childless-dispatcher leaves need filtering); B2B docs-zone page + NavRegistry doc_page_id; classification-model verification for NO_HANDOFF/DUPLICATE/CASCADE_SKIP (held in sterling_status UNDEFINED — §7.9).
4. **WORKFLOW_CONTEXT live-step verification.** The remaining path to "step X of Y" live display now that WF_INST_S is confirmed write-at-termination (§4.2a).
5. **Operational fixes** (independent of the module; owner: Dirk/ops): GET_LIST v20 fault-insert fix (headline — 21,815 historical Sterling faults and ~12/day ongoing are ticket-invisible), ITS/INCEPTION fault-write no-ops, plaintext-credential review, reconciler minor quirks (§4.2a), remaining minor quirks per Summary §4.
6. **Minor collector items:** dispatcher-resolution shortfall diagnostic (~750 unresolvable in-window instance ids).
7. **Scope cleanup (deferred).** INT_PipelineTracking classifies downstream/non-Sterling failures (DM_REJECTED, FAULT_POST_HANDOFF) that other modules own — module overreach identified during the fault-report build. Evaluate narrowing the classification model to Sterling-internal outcomes, or clearly demarcating which failures this module is authoritative for.

**Done this session (2026-07-16):** alerting enabled with per-condition routing; sterling_status model + full page pivot (§7.9); dispatcher historical backfill (~1.3M rows, §4.2a); Recent Workflow Changes section removed; process-type badges + data-driven type filter.

## Document History

| Version | Date | Change |
|---|---|---|
| 3.0 | 2026-07-16 | **sterling_status model, page pivot, alerting enablement, dispatcher backfill.** New §7.9 records the two-layer status model: sterling_status (closed five-value coarse status) added to INT_PipelineTracking as the page's primary axis, derived from status_classification, UNDEFINED doubling as a drift sentinel. §3.1 updated: the CC page pivoted to sterling_status (pulse tiles restructured live-vs-table, process-type badges + Run ID on live/history, dual-status slideout, data-driven type filter, Recent Workflow Changes removed); collector derives sterling_status inline; alerting enabled with per-condition routing. §4.2a adds four Known True entries: the two-mechanism arrival-time dispatch model (GET_LIST vs. per-client schedules), the ~1.3M-row dispatcher_name backfill (GET_LIST parent/child chain + single-match sibling lookup) with the fully-characterized ~412K remainder, SI_ScheduleRegistry verified as a comprehensive current mirror (not a legacy slice), and the ~48h runtime-retention refinement. §5.8 and §9 updated; Next Session rewritten to lead with the run→schedule linkage as the open dispatcher problem. |
| 2.9 | 2026-07-14 | **Fault-report capture feature.** New `B2B.SI_FaultReport` table (§3.1) plus four summary columns on INT_PipelineTracking, populated by a new collector Step 7 (fault-report enrichment): resolves the failing step's STATUS_RPT handle in b2bi WORKFLOW_CONTEXT, decompresses the TRANS_DATA blob, parses three report shapes (TRANSLATION/SERVICE/MESSAGE), and captures the report — surfacing Sterling translation errors that were previously only visible via IBM Status Report access. §4 adds the handle-retention bound (go-forward capture only) and the downstream-failure overreach finding; §9 adds the scope-cleanup action. Collector now eight steps.|
| 2.8 | 2026-07-13 | **Control Center page live.** §3 adds the B2B Pipeline page artifacts (four WebAssets, engine card, nav at platform sort 120, wide-open permissions, refresh_b2b_seconds) - live to all users after three visual passes; Live Pipeline Activity reads the Integration source directly for true real-time visibility. §4.2a adds the WF_INST_S write-at-termination Known True (live engine panel via that table is dead; WORKFLOW_CONTEXT is the remaining step-level candidate). Collector execute-mode single-pass optimization recorded (127s to 56s cycles). §9 rebuilt: page iteration (Workflow Changes placement, parent/child grouping, docs page), alerting enablement, WORKFLOW_CONTEXT verification, ops fixes, dispatcher diagnostic. CSS spacing-token drift resolved to zero. |
| 2.7 | 2026-07-12 | **Build phase complete — collection layer live.** §3 rewritten for the live architecture: `INT_PipelineTracking` (full backfill to 2021-06, 1,717,835 rows), `SI_WorkflowRegistry` (1,460 definitions), `Collect-B2BPipeline.ps1` (seven steps incl. built-and-gated Teams alerting); legacy collector and `SI_ExecutionTracking` retired, ProcessRegistry repointed. §4.2a adds the full-history classification census (incl. the 2,113 DIED_UNHANDLED = 6E cross-validation and the 2021-06 history discovery). §7.8 records the -1 non-handoff-type refinement (UNCLASSIFIED → 0). §6 alerting/CC lines removed (now §9 items 1-2). SI_/INT_ source-provenance prefix convention in production. Next Session rewritten: CC page and alerting enablement are the open directions; minor items logged (dispatcher-resolution shortfall, cycle-time optimization option). |
| 2.6 | 2026-07-12 | **Decision phase closed.** §7 rewritten from pending-decisions queue to recorded decisions 7.1-7.7 plus new §7.8 status disambiguation model (source-verified discriminators for -1 and 4; transition-watching and FINISH_DATE eliminated). §4.2a extended with four new Known True entries: reconciliation job schedule (every 1 min, 00:15-18:59:59) + off-window consequence; reconciler proc behavior (BATCH_STATUS-only UPDATE, derived PROCESS_TYPE, park-at-2 mechanism confirmed, two new minor quirks); BATCH_STATUS full column list (INSERT_DATE age anchor); BATCH_FILES full column list (RUN_ID NOT NULL). §5.10 updated for verified table shapes; §5.14 marked decided per 7.6; §5.15 reconciler-schedule residual resolved. §1/§2 gate language updated to reflect the passed investigation gate; §6 stale "deferred until investigation complete" wording updated. Next Session rewritten for the design phase (mirror schema); Next Actions renumbered. |
| 2.5 | 2026-07-10 | Steps 6D, 6E, 6F, 6G complete — **investigation phase closed.** §5.6 all sub-steps ✅; §4.2a extended with six new Known True entries (BATCH_STATUS lifecycle tracker + reconciliation job, GET_LIST ticket bug, ETL_CALL death, dispatch visibility model, wrapper population 369 + corpus refresh, work-queue proc internals); §5.15 closed; §8 tree updated, ArchitectureOverview marked RETIRED; §9 rewritten for the decision phase; Next Session rewritten to open with Step_06G_Summary. |
| 2.4 | 2026-07-10 | Step 6C complete. §5.6 updated to show 6C ✅ with census summary; new §4.2a Known True block (execution model single spine, 361/371 wrapper census, GET_LIST shortfall resolution, BATCH_STATUS vocabulary + BATCH_ID bridge, faint proc schema, invocation mechanisms, merged-output filename formula, defects catalog). §4.2 dormant-workflow entry corrected with verified roles (ETL_CALL not deprecated; TABLE_INSERT/TABLE_PULL orphaned; ENCOUNTER_ID under ENCOUNTER_LOAD; REMIT_DATA_VERIFICATION a top-level wrapper); MAIN rule entry refined to 23 defined / 22 live. §4.6 notes MAIN invocation patterns re-verified. §5.7 structural coverage complete; §5.8 resolved structurally; §5.9 partially grounded; §5.10 Sterling-side references verified. §5.15 restructured: 6C resolutions recorded, nine new 6E targets referenced. §8 reference tree corrected to the repo's flat sub-step folder layout (the nested Step_06_MAIN_Anatomy paths never existed) and notes the BPML corpus removal from the repo. Next Session rewritten for 6D start; Next Actions renumbered. |
| 2.3 | 2026-04-24 | Step 6B complete. §5.6 updated to show 6B ✅; §4.2 adds FA_CLIENTS_MAIN rule-count (23 rules) fact from BPML inspection; §4.4 adds BPML storage model as verified Known True; §4.5 adds `<process>` root confirmation + XML comment prologue observation. §5.7 and §5.8 note that BPML corpus is now available for 6C deep reads. §5.15 adds GBMDATA handle as new open question. §8 reference tree updated to show BPMLs folder. Next Session section rewritten for 6C start. |
| 2.2 | 2026-04-24 | Step 6A complete. §5.6 restructured to reflect Step 6 split into 6A-6G sub-steps. §4.2 updated to use 30-day active count (413) from Step 6A; added Step 6A findings about FA_CLIENTS active/dormant split and MAIN's version-48 current state. §4.6 "Carried forward from v1" entries retracted as inherited-and-unverified; moved to explicit "Retracted inherited claims" block to be re-verified. §4.4 expanded with Step 6A's STATUS-values-observed finding. §5.3 updated to reference Step 6A supplement. §5.7, §5.8, §5.10 reframed to note that Step 6C's BPML analysis will cover structural aspects. §5.15 added — seven new open questions raised by Step 6A. Legacy ArchitectureOverview reclassified in §8 as "structured hypothesis document" rather than "reference with errors." §7 items consolidated — all remain deferred until Step 6 closes. Operating Principles §2 adjusted: removed "must complete in single session" constraint; added "BPML is an authoritative structural source" principle. Next Session section rewritten for 6B start. Next Actions renumbered. |
| 2.1 | 2026-04-24 | Added "Next Session" priming section at top. Swapped §9 ordering — MAIN anatomy now precedes sub-workflow deep-dives. §5.6 reframed as active "next up" entry; §5.7 added for sub-workflow families as deferred. §2 Operating Principles added: high-stakes investigations must not split across sessions. Legacy file paths corrected to `Legacy/` subfolder. Step_03 and Step_05 findings paths corrected to match actual GitHub folder names. |
| 2.0 | 2026-04-24 | Full refresh after Steps 1-5. Slim structure; cross-references to findings docs. Significant updates to Known True, Investigation Register, Pending Decisions. v1 archived. |
| 1.0 | 2026-04-23 | Initial reset document after recognizing MAIN-only scope was incomplete. |

# IBM/B2B Pipeline

*Watching the middleman — so files don't vanish into the space between systems*

The B2B Pipeline module watches IBM Sterling B2B Integrator — the middleware that moves files between the outside world and Debt Manager. It follows each run from the moment a file shows up to the moment the work either lands safely in DM or fails, tells you which of those actually happened, and captures the error report when something breaks. It turns a black box into a page you can read.






The Problem

Files don't teleport from a client into Debt Manager. They pass through a middleman: IBM Sterling B2B Integrator. Sterling picks files up, translates them, hands them off, sends things back out, and generally does the unglamorous work of connecting systems that were never designed to talk to each other.

When it works, nobody thinks about it. When it doesn't, the questions start — and they're surprisingly hard to answer. Did the file actually arrive? Did it get processed, or is it still sitting in a queue? Did it make it into DM, or did it fault somewhere in the middle? Was that failure a real problem, or just a run that correctly found nothing to do?

Historically, answering any of those meant logging into Sterling's own admin console and reading through screens designed for administrators, not humans. The information existed, but it was locked behind a tool nobody wanted to open at 7 AM. The pipeline was doing thousands of runs a day and almost none of them were visible.






What It Does

The B2B Pipeline module keeps a running mirror of every pipeline run and, crucially, decides what each one *means*. A run isn't just "done" or "not done" — the module sorts each one into a plain outcome so you're not left interpreting raw status codes.

| Outcome | What It Means |
| --- | --- |
| **Success** | The run did its job. If it handed work off to Debt Manager, DM confirmed it landed. |
| **No Action** | The run genuinely had nothing to do — a scheduled check that looked, found no files waiting, and correctly moved on. Not a problem. |
| **Failed** | Something broke — a translation error, a rejection from DM, or a run that died without ever reaching a clean ending. |


That "No Action" bucket is the quiet hero. A huge share of pipeline runs are scheduled pollers that check for files and find nothing. Without a way to recognize those as normal, every quiet run looks like a suspicious non-event. Separating "nothing to do" from "something went wrong" is most of what makes the page readable.

Underneath the three plain outcomes sits a more detailed classification — a dozen finer shades like "waiting on DM to confirm," "faulted before any handoff," or "died without reaching a fault handler." You don't need those to read the page, but they're there the moment you want to know exactly what a specific run did.






Following a Run



File
Arrives
→
Sterling
Processes
→
Hand Off
to DM
→
DM
Confirms
→
Outcome
Recorded

A file's journey through the middleman — and where the module is watching at each step


Not every run takes the full journey. Some hand work to Debt Manager and wait for DM to confirm the batch landed; those aren't marked complete until that confirmation comes back. Others never hand anything off at all — a file gets emailed, a report gets sent, a folder gets swept — and those finish on the Sterling side alone. The module knows the difference and doesn't hold a run open waiting for a confirmation that was never coming.

Each run also gets tagged with who it was for (the client) and what kind of work it was (new business, a payment, a bulk data load, an outbound file, and so on). That's what lets you search the history for a specific client or filter down to just one type of activity.






When Things Break

A failed run is only useful if you can find out *why* it failed. Sterling produces a detailed status report when a translation goes wrong — which field, which record, what rule it violated — but that report normally lives inside Sterling's own tooling.

This module reaches in, grabs that report at the moment of failure, and keeps it. When you open a failed run, the error report is right there: the specific problem, in a readable layout, without a single login to Sterling. For the trickier cases — a run that faulted after already handing off to DM, or one that died so hard it never wrote a proper ending — the module has specific handling so those don't just show up as a shrug.

Failures also raise their voice. When a run fails in a way that matters, a Teams alert goes out automatically, so the first anyone hears of a problem isn't a client asking where their file went.






The Control Center View

The B2B Pipeline page in the Control Center is the live window into all of this. The top gives you today at a glance — how many runs, how many are still in motion, how many succeeded, did nothing, or failed. A live activity panel shows what's moving through the pipeline right now. And a full run history, organized by year, month, and day, lets you drill down to any single run and read its whole story — the files it touched, any Jira tickets it generated, and the error report if it failed.

It's the page you open when a client asks "did you get our file?" and you'd like to answer with a fact instead of a guess.






The Bottom Line

Middleware is one of those things that works beautifully until it doesn't — and when it doesn't, it tends to fail silently, in the gap between two systems where nobody's looking. The B2B Pipeline module puts a light in that gap.

Every run is tracked. Every outcome is named in plain language. Every failure keeps its evidence and raises an alert. What used to require an administrator and a Sterling login is now a page anyone can read — and the difference between "the file is fine" and "the file never made it" is no longer a mystery you have to go digging for.

---

# IBM/B2B Pipeline — Control Center Guide

---

## Architecture
# IBM/B2B Pipeline Architecture

The narrative page tells you *what* the B2B Pipeline module does and *why*. This page tells you *how*. One collector mirrors Sterling's pipeline runs into six tables and classifies each one; the page reads those tables through a two-layer status model. The first half of this page is how a run gets tracked and classified; the second half is how the page presents it.






Schema Overview

The B2B module's data lives in six tables in the `B2B` schema. One is the spine everything hangs off; two catalog Sterling's own configuration (schedules and workflow definitions); three enrich a tracked run with related detail (files, tickets, fault reports). All logic lives in a single PowerShell collector — there are no stored procedures or triggers in the module, so the tables store state and the collector does everything else.



This diagram shows keys and relationships only — the shape of the module, not every field. For the column-by-column definition of any table, see the Reference page.

| Table | Role | Cardinality |
| --- | --- | --- |
| `INT_PipelineTracking` | The spine. Both status values, timing, identity, and outcome evidence for a run. | One row per tracked run |
| `SI_ScheduleRegistry` | A current mirror of Sterling's schedule catalog — what runs when. | One row per Sterling schedule |
| `SI_WorkflowRegistry` | Workflow-definition catalog and version memory — used to notice definition changes. | One row per workflow definition |
| `INT_RunFiles` | The files a run touched. Feeds the run-detail Files card. | One row per file per run |
| `INT_RunTickets` | Per-run Jira ticket outcomes. Feeds the Tickets card and hero badge. | One row per run per ticket reason |
| `SI_FaultReport` | The captured Sterling status report for a failed run. Feeds the fault-report slideout. | One row per failed run with a report |



The `SI_` and `INT_` prefixes carry meaning. `SI_` tables mirror or catalog Sterling's own state (schedules, workflow definitions, fault reports). `INT_` tables are sourced from the Integration database's pipeline-tracking layer (the run mirror, its files, its tickets). The prefix tells you where a table's data originates.







Where the Data Comes From

The page doesn't talk to Sterling. It reads the `B2B` tables, which the collector (`Collect-B2BPipeline.ps1`) keeps current on a configurable cycle. Understanding that split matters, because it explains why one part of the page behaves differently from the rest.

The collector reads three source systems: Sterling's `b2bi` database on its own server (via Windows auth), and the Integration and Debt Manager databases through the availability-group listener. The mirror steps run as single cross-database statements on the listener, so history and ongoing rows get classified by identical logic. The page's API, by contrast, only ever reads the `B2B` tables in xFACts — a clean read-only surface with no live dependency on Sterling being reachable when someone loads the page.


One section skips the collector. The Live Pipeline Activity panel reads the Integration source *directly* rather than waiting for the next collection cycle, so it shows genuinely in-motion runs in real time. Everything else reads the collector's mirror. That's the reason live rows aren't clickable through to full detail: a run that just started may not have been mirrored yet, so its stored detail would be empty.







The Collection Cycle

Each collector run works through a fixed sequence of steps. The early steps keep the Sterling catalogs current; the middle steps mirror and classify runs and enrich them; the late steps cross-check aged runs, capture fault reports, and evaluate alerts.




1–2. Catalogs
Sync schedules,
workflow census

→

3–4. Mirror
Collect new runs,
re-poll incomplete

→

5–7. Enrich
Files, tickets,
dispatcher names

→

8–9. Resolve
Sterling cross-check,
fault reports

→

10. Alert
Evaluate and
queue alerts


One cycle, ten steps — catalogs first, then the run mirror, then enrichment, cross-check, and alerting


| # | Step | What It Does |
| --- | --- | --- |
| 1 | Sync Schedules | Refreshes `SI_ScheduleRegistry` from Sterling's schedule catalog. |
| 2 | Workflow Census | Refreshes the workflow-definition catalog and detects version changes since the last cycle. |
| 3 | Collect New Runs | Inserts newly-seen runs into the tracker, classifying each as it lands. |
| 4 | Re-poll Incomplete | Re-evaluates runs still in flight or awaiting DM and updates any that have since resolved. |
| 5 | Mirror Run Files | Copies each tracked run's file listing into `INT_RunFiles`. |
| 6 | Capture Run Tickets | Captures per-run Jira ticket outcomes into `INT_RunTickets`. |
| 7 | Resolve Dispatcher Names | Fills in the dispatching schedule name for runs that don't carry one directly. |
| 8 | Sterling Cross-Check | Catches aged in-flight runs that died silently (see below). |
| 9 | Fault Report Enrichment | Captures the Sterling status report for freshly-failed runs. |
| 10 | Alert Evaluation | Queues Teams/Jira alerts for the conditions that warrant them. |



Mirror and classify are one pass. The insert and re-poll steps classify each run inside the same statement that writes it, capturing the classification via OUTPUT rather than re-querying afterward. History rows and ongoing rows run through the identical classification logic, so a run from three years ago and a run from three minutes ago are judged the same way.







Run Classification

Classification is the heart of the collector — it's what turns a raw source status into a meaning. The tracker keeps one row per run (keyed on the run's Sterling `WORKFLOW_ID`), mirrors the source's raw status verbatim, and alongside it derives a `status_classification` from that status plus supporting evidence.

How the Source Status Maps

The source carries a coarse numeric status, and two of its values are ambiguous — they mean two different things depending on what happened. The raw value alone can't tell them apart, so the collector consults independent evidence to disambiguate:

| Ambiguous Value | Could Mean | Resolved By |
| --- | --- | --- |
| Fault (&minus;1) | A Sterling workflow fault, *or* a DM batch rejection written back by the reconciliation job | Checking the DM batch tables directly — the same tables the reconciliation job reads |
| Finished (4) | No files were acquired, *or* files came in but the handoff never happened | Checking for nonzero-size file pickups on the run |


With those two resolved, the full mapping falls out. Each source signal, plus any evidence it needs, lands on one classification:

| Source Signal | Evidence Consulted | Resulting Classification |
| --- | --- | --- |
| Still running | None (may later be cross-checked) | IN_FLIGHT |
| Handed off, awaiting DM | Whether a sequence id is present | AWAITING_DM (or COMPLETE for non-handoff types) |
| Finished on the Sterling side | Whether any nonzero-size files were picked up | NO_HANDOFF (files present) or NO_FILES (none) |
| Faulted | Whether a DM batch id exists; process type; DM's own status code | STERLING_FAULT, DM_REJECTED, or FAULT_POST_HANDOFF |
| Skipped in a sequential chain | None | CASCADE_SKIP |
| Duplicate suppressed | None | DUPLICATE |



A fault means different things depending on the arm. When a run faults, the collector asks whether it ever reached Debt Manager. No DM batch id, or a process type that has no DM arm at all (anything outside new business, payment, and BDL), means the fault is purely Sterling's — STERLING_FAULT. A DM batch that reached a rejection code is DM_REJECTED. A fault that occurred *after* DM had already accepted the work is FAULT_POST_HANDOFF — the data landed, but cleanup or notification may not have finished.


The Twelve Classifications

Every tracked run lands on exactly one of these. The meanings below are the same plain-English descriptions shown in the run-detail slideout.

| Classification | Meaning |
| --- | --- |
| **IN_FLIGHT** | Presumed executing — the source row is still open and hasn't aged past the cross-check threshold. |
| **AWAITING_DM** | The Sterling side is done; waiting for the Integration reconciliation job to confirm the DM outcome. |
| **COMPLETE** | Fully complete. For handoff types this includes DM-side confirmation. |
| **NO_FILES** | The run genuinely acquired no files — a normal outcome for a poll that found nothing waiting. |
| **NO_HANDOFF** | Files were acquired but the run never handed a batch to DM. |
| **DUPLICATE** | A duplicate file was detected and processing was suppressed. |
| **CASCADE_SKIP** | Skipped because a predecessor in a sequential chain failed. |
| **STERLING_FAULT** | Faulted on the Sterling side with no DM rejection possible — before any handoff, or on a type with no DM arm. |
| **DM_REJECTED** | DM rejected the batch after handoff; the DM batch reached a failed or deleted terminal code. |
| **FAULT_POST_HANDOFF** | The data landed in DM but the pipeline faulted afterward — cleanup and notification may not have run. |
| **DIED_UNHANDLED** | Terminated in Sterling without reaching a fault handler; its source row will never self-update. Set by the cross-check. |
| **UNCLASSIFIED** | The collector could not resolve a classification from the available evidence. Persistent unclassified runs indicate a collector or source problem. |







Two-Layer Status Model

Every tracked run carries *two* status values, and the reason isn't just "detailed versus summary" — the two answer genuinely different questions.

This module was meant to treat Sterling as the endpoint: a run happens in Sterling, and it either worked or it didn't. But the setup isn't that clean. A reconciliation process running in Sterling looks at what happened *after* the data left — whether Debt Manager accepted or rejected the handed-off batch — and writes that back into the source. So the source status carries the full pipeline story, downstream outcomes and all. The `status_classification` is that full story: the twelve values above, which include downstream dispositions like a DM rejection or a post-handoff fault.

That created a problem. If a run handed off cleanly and DM later rejected the batch, the full story is "DM rejected it" — but from *Sterling's* point of view, the run succeeded. It did its job and passed the work along. To keep a clean answer to "how did this end in Sterling," a second status was added: `sterling_status`, the rolled-up result considering Sterling alone as the endpoint. It's the primary status the page is organized around — the clickable pulse tiles, the history-tree columns, and the status filter all speak this vocabulary.

| sterling_status | Meaning (Sterling as the endpoint) |
| --- | --- |
| **SUCCESS** | The run reached a successful terminal state within Sterling. |
| **NO_ACTION** | The run performed no processing — there was nothing to act on. |
| **FAILED** | The run failed within Sterling. |
| **IN_PROGRESS** | The run has not yet reached a terminal state within Sterling. |
| **UNDEFINED** | The Sterling-level status hasn't been determined. Also a **drift sentinel**: several classifications are still under review for how they should roll up, so a persistent UNDEFINED is a signal that a case is still being worked out. |



Success and DM Rejected can sit side by side — on purpose. A run can show `sterling_status` = SUCCESS and `status_classification` = DM_REJECTED at the same time, and that's correct: Sterling succeeded (it handed off cleanly), and the rejection happened downstream. That downstream outcome is really Batch Monitoring's territory — there's a bit of baked-in crossover between the two modules that only became clear once the pipeline was built out. On this page, the coarse status deliberately answers only the Sterling question and leaves the downstream story to the detail layer.


The two show up together in the run-detail slideout: the hero strip carries a Sterling badge (the coarse "how did it end in Sterling") and a Classification badge (the full "what happened to it") side by side, with the classification's plain-English meaning underneath. Tiles and history use the coarse status because it's the clean at-a-glance answer; the slideout adds the classification because that's where you've gone to understand the whole run, downstream and all. The page never computes either value — both are written by the collector and read as-is.






Sterling Cross-Check

Most runs report their own ending — they finish, and the source row updates to a terminal status the collector can classify. But some runs die so hard they never reach a fault handler, which means their source row stays "still running" forever. Left alone, those would sit as IN_FLIGHT indefinitely, quietly wrong.

The cross-check is the safety net. Each cycle it looks at in-flight runs that have aged past a configurable threshold, and checks each one against Sterling's own runtime instance state. If the run's Sterling instance has terminated or vanished, the run died without a handler and will never self-update — so the cross-check reclassifies it as DIED_UNHANDLED.


Why the aging threshold exists. A run that's only been in flight a few minutes might genuinely still be working. The threshold gives every run a fair chance to finish and report itself before the cross-check steps in. Only runs that have been in flight too long to be plausibly alive get checked against Sterling — and only the confirmed-dead ones get reclassified.







Fault Report Capture

A failed run is only useful if you can find out why. Sterling produces a detailed status report when a step fails, but it lives compressed inside Sterling's own runtime tables. The fault-report step reaches in and captures it so nobody has to open Sterling.

Capture is scoped to the two Sterling-internal failures — STERLING_FAULT and DIED_UNHANDLED. Downstream failures (a DM rejection, or a fault after handoff) are owned by other parts of the pipeline and deliberately excluded. For an eligible run without a captured report yet, the collector resolves the failing step's report handle, reads and decompresses the report blob, parses it, and writes both the parsed structure and the raw text to `SI_FaultReport` — then snapshots a short summary onto the tracking row so the run-detail slideout can show a callout without opening the full report.

Report Shapes

The captured report arrives in one of a few shapes, and the collector parses each into a consistent structure the slideout can render:

| Shape | What It Is |
| --- | --- |
| **TRANSLATION** | A translation/map failure. Parsed to full fidelity — report metadata, per-entry detail (field, block, exception, raw block data), and error/warning/entry counts. |
| **TRANSLATION_ESCALATED** | A map that completed with warnings, where the workflow then escalated the outcome to a fault. The full report is recovered from the run's last successful translation step; the failing step's one-liner is preserved as an escalation message. |
| **SERVICE** | A service-level failure. Captures the service identity and every reported error line. |
| **MESSAGE** | A report-less failure (for example, a database error surfaced through an adapter). No report blob exists, so the error text is lifted from the failing step's status field. |



Unknown vocabulary is never dropped. The translation parser maps the report's known detail codes to named fields, but any code it doesn't recognize is preserved generically rather than discarded — so a new Sterling report field shows up in the captured detail even before the parser has a name for it. A run whose failure produces no recognizable report at all is recorded as having no report, rather than left looking uncaptured.







Files & Tickets

Two enrichment steps attach related detail to each run so the run-detail slideout can tell a fuller story.

Run Files

The file mirror copies each tracked run's file listing into `INT_RunFiles` — one row per file per run, with the file name, size, and how it arrived. It's idempotent on the source file row, so re-running a cycle never duplicates a file, and it captures files for every run regardless of status or type.

Run Tickets

The ticket capture records Jira ticket outcomes at the (run, ticket reason) grain — a single run can generate more than one ticket for different reasons. Each ticket carries an assignment state that the slideout badges:

| State | Meaning |
| --- | --- |
| **GENERATED** | A ticket number has been assigned. |
| **PENDING** | Recognized but not yet assigned a number — recently seen and still expected to be assigned. |
| **AGED_OUT** | Went unassigned long enough that it's no longer expected to be. A late assignment still promotes an aged row back to GENERATED. |


In the run-detail slideout, the worst assignment state across a run's tickets wins the hero's Jira badge — so a run with one aged-out ticket among several reads as aged-out at a glance, and only shows the full picture when you look at the Tickets card.






Alerting

The page is how you find a problem when you go looking; alerting is how a problem finds you when you're not. The final collector step evaluates two conditions and, when they fire, queues an alert through the shared Teams/Jira dispatch.

| Condition | Fires When |
| --- | --- |
| **Sterling Fault** | A run classifies as a Sterling-internal failure (STERLING_FAULT or DIED_UNHANDLED). |
| **Workflow Change** | A Sterling workflow definition changed version between cycles — a behavior change with no other notification path. |


Alerting sits behind a master switch, and each of the two conditions has its own routing so they can be sent to Teams, raised as a Jira ticket, both, or neither — independently. Alerting is also bounded to the working window, so backfilling years of history never fires a storm of alerts for runs that failed long ago.


The failure alert is deliberately narrow. Only the two Sterling-internal faults alert. A DM rejection or a post-handoff fault is real, but it's visible and owned elsewhere in the pipeline — alerting on it here would be a duplicate. The B2B alert covers exactly the failures that *only* this module can see.







Refresh Model

The page refreshes on two different rhythms, matching how each section gets its data.

| Sections | Rhythm | Badge |
| --- | --- | --- |
| Pulse tiles, Live Activity | A polling timer on a configurable live interval | Live (pulsing dot) |
| Run History tree | Refreshes when the collector completes a cycle | Event (lightning bolt) |


The live sections poll because they need to feel current between collection cycles; the history tree is event-driven because it only changes when the collector writes new tracked rows, so refreshing it on completion is both sufficient and efficient. A separate timer forces a full page reload when the calendar date rolls over, so an open page doesn't sit on yesterday's "today."






How Everything Connects

The collector reads from three source systems and writes to the `B2B` tables plus the shared alert queue. The data flow is one-directional — read from the sources, write to xFACts, never back.

Page to Data

| Section | Reads From | Via |
| --- | --- | --- |
| Pulse (bottom row), History, Runs/Day slideouts, Run Detail | `INT_PipelineTracking` | The read-only page API |
| Live Activity + Pulse (top row) | The Integration source, directly | The page API's live endpoint |
| Run-detail Files card | `INT_RunFiles` | The run-files endpoint |
| Run-detail Tickets card + hero badge | `INT_RunTickets` | The run-tickets endpoint |
| Fault-report slideout | `SI_FaultReport` | The fault-report endpoint |


Source Systems

| Source | Read By | Purpose |
| --- | --- | --- |
| Sterling `b2bi` database | Schedule sync, workflow census, cross-check, fault capture | Schedules, workflow definitions, runtime instance state, and the compressed fault reports |
| Integration database | Run mirror, files, tickets, live panel | The pipeline-tracking layer that is the run mirror's source, plus per-run files and tickets |
| Debt Manager (`crs5_oltp`) | Classification (fault runs) | DM batch status codes that distinguish a Sterling fault from a DM rejection |


Platform Dependencies

| Dependency | Purpose |
| --- | --- |
| `Orchestrator.ProcessRegistry` | Runs the collector on its interval and drives the engine card's health indicator. |
| `dbo.GlobalConfig` | The live refresh interval, the collection lookback and in-flight aging thresholds, the alerting master switch, and the per-condition routing. |
| `Teams.AlertQueue` / Jira | Where the collector queues alerts for Sterling-internal failures and workflow-definition changes. |

---

## Reference

### INT_PipelineTracking

Pipeline-run lifecycle tracking mirrored from Integration.ETL.tbl_B2B_CLIENTS_BATCH_STATUS, the Sterling-to-DM lifecycle tracker. One row per pipeline run (RUN_ID unique), carrying the raw source status verbatim plus a disambiguated classification that resolves the dual-meaning source values (-1 and 4) via independent DM batch verification and BATCH_FILES pickup evidence. Enrichment columns snapshot client identity and process configuration at collection time. The INT_ prefix marks the table as mirrored from the Integration database, as opposed to SI_ tables sourced directly from b2bi.

**Data Flow:** Rows originate in Integration.ETL.tbl_B2B_CLIENTS_BATCH_STATUS, the Sterling-to-DM lifecycle tracker written by the pipeline workflows and the Integration reconciliation job. Collect-B2BPipeline.ps1 mirrors them each cycle: step 3 INSERTs classified rows for source runs not yet mirrored (bounded by b2b_collect_lookback_days), step 4 re-polls tracked rows with is_complete = 0 inside the same window via a set-based UPDATE. Classification is computed in T-SQL on the listener at collection time - config enrichment (process_type, comm_method) from the FILES join, client_name from the MN clients master, DM outcome verification against the crs5_oltp batch tables for -1 rows, and the BATCH_FILES nonzero-size pickup check for the status-4 split. Step 5 stamps dispatcher_name from b2bi instance linkage (resolvable only within the ~30-day Sterling runtime window); step 6 sets sterling_check_result and promotes aged in-flight rows to DIED_UNHANDLED; step 7 increments alert_count when a failure alert is queued.

**Source Provenance Prefix Convention:** [sort:1] B2B module tables carry a prefix declaring their source system: SI_ tables are sourced directly from the b2bi database on FA-INT-DBP (Sterling itself), while INT_ tables mirror rows written to the Integration database on the AG listener. The module is inherently a hybrid of the two source systems, and the prefix makes data provenance readable straight from the object name.

**Raw Status Plus Classification:** [sort:2] The table deliberately carries both the raw source status (batch_status, mirrored verbatim) and a derived classification (status_classification). Two source values are ambiguous by writer: -1 means either a Sterling workflow fault or a DM batch rejection, and 4 means either no files acquired or a handoff that never happened. The classification resolves these using independent evidence - the DM batch tables for -1 (the same tables the Integration reconciliation job reads) and BATCH_FILES pickup rows with nonzero size for 4. Keeping the raw value preserves the audit trail against the source; the classification is the operational reading.

**Snapshot Enrichment:** [sort:3] client_name, process_type, and comm_method are stamped onto the row at collection time rather than resolved by join at display time. Historical rows keep the values that were true when the run executed, so config renames and reconfigurations do not rewrite history. dispatcher_name is likewise a point-in-time resolution, and is additionally constrained by the Sterling runtime retention window - it is NULL for rows collected more than ~30 days after their run.

**Terminal Means Classified:** [sort:4] is_complete is driven by the classification, not the raw source status. A row at source status -1 is not complete until the DM verification has resolved which failure story it represents, and a row at source status 0 is not abandoned until the Sterling cross-check has determined whether it is running or dead. This keeps the incremental poll working the classification queue, not just mirroring status changes.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| tracking_id (IDENTITY) | int | No | IDENTITY | Clustered identity primary key. |
| run_id | int | No | — | The Sterling WORKFLOW_ID of the run. Mirrors BATCH_STATUS.RUN_ID. Unique - one tracking row per pipeline run. |
| parent_id | int | Yes | — | Mirrors BATCH_STATUS.PARENT_ID - links a dispatched child run (FA_CLIENTS_MAIN) to the dispatcher run that launched it. NULL for dispatcher rows themselves. |
| client_id | bigint | Yes | — | Mirrors BATCH_STATUS.CLIENT_ID - the B2B client this run processed. |
| seq_id | int | Yes | — | Mirrors BATCH_STATUS.SEQ_ID - the client config sequence this run executed. NULL identifies a scheduler-fired GET_LIST dispatcher row (whole-client dispatch with no single sequence). |
| batch_id | varchar(20) | Yes | — | Mirrors BATCH_STATUS.BATCH_ID - the DM batch identifier written back by COMM_CALL after handoff. The bridge between the B2B pipeline and Debt Manager batch processing. NULL when no handoff occurred. |
| batch_status | int | No | — | The raw source status value, mirrored verbatim from BATCH_STATUS.BATCH_STATUS. Preserved as the audit trail against the source; see status_classification for the disambiguated reading. |
| source_insert_dttm | datetime | No | — | Mirrors BATCH_STATUS.INSERT_DATE - when the run began (the source column defaults to GETDATE() at row creation). The age anchor for in-flight and stuck-at-status calculations. |
| source_finish_dttm | datetime | Yes | — | Mirrors BATCH_STATUS.FINISH_DATE - set by the workflow tail or fault handler. NULL for in-flight runs and runs that died without reaching a handler. Not updated by the reconciliation job. |
| process_type | varchar(100) | Yes | — | Snapshotted from etl.tbl_B2B_CLIENTS_FILES.PROCESS_TYPE via the CLIENT_ID + SEQ_ID join at collection time - the same derivation the Integration reconciliation job uses. NULL when the join cannot resolve (scheduler-fired dispatcher rows). |
| comm_method | varchar(255) | Yes | — | Snapshotted from etl.tbl_B2B_CLIENTS_FILES.COMM_METHOD via the CLIENT_ID + SEQ_ID join at collection time. |
| client_name | varchar(255) | Yes | — | Snapshotted from etl.tbl_B2B_CLIENTS_MN.CLIENT_NAME at collection time. Historical rows keep the name that was current when collected. |
| dispatcher_name | varchar(255) | Yes | — | The wrapper workflow definition name that fired this pipeline run, resolved from b2bi runtime linkage. Resolvable only within the Sterling runtime retention window (~30 days), so NULL for backfilled history and aged rows. |
| sterling_status | varchar(20) | No | 'UNDEFINED' | The overall status of the run at the Sterling Integrator level, independent of any downstream outcome. The primary status the Control Center surfaces for each run. |
| status_classification | varchar(30) | No | — | The detailed final classification of the run, carrying the specific pipeline outcome including downstream disposition. The detail layer behind the sterling_status column. |
| dm_batch_status_code | int | Yes | — | The DM-side batch status code observed when the collector performed the DM verification for this run. NULL when no BATCH_ID exists or no DM lookup applied. |
| sterling_check_result | varchar(20) | Yes | — | Outcome of the b2bi WF_INST_S cross-check performed for in-flight rows aging past threshold. Distinguishes genuinely running instances from runs that died without reaching a fault handler. See Status Values. |
| fault_report_type | varchar(30) | Yes | — | The shape of the captured Sterling fault report, or NONE when the failure carried no extractable report. Snapshotted from SI_FaultReport for join-free display; NONE is the sentinel marking that the collector looked and found nothing, so the run is not re-attempted. NULL until the collector has attempted capture. See Status Values. |
| fault_report_code | varchar(20) | Yes | — | The primary error code from the fault report (e.g. 112 for Data Too Long, 721 for an UPDATE/INSERT/DELETE execution error). NULL for SERVICE/MESSAGE/NONE reports or when no single code applies. |
| fault_report_summary | varchar(500) | Yes | — | The one-line failure headline shown on the run row and slideout. For a single error it is the specific message (the downstream exception text when present, else the code label); for multiple errors it is a generic count pointing to the full report. |
| fault_report_captured_dttm | datetime | Yes | — | When the collector attempted fault-report capture for this run. Doubles as the look-back-and-fill guard: NULL means never attempted, so the enrichment pass is idempotent and only processes unattempted failures. |
| is_complete | bit | No | 0 | 1 when the run has reached a terminal classification and needs no further polling. Drives the collector incremental scan. |
| completed_dttm | datetime | Yes | — | When the row reached its terminal classification. |
| alert_count | int | No | 0 | Number of alerts fired for this run. Used to prevent duplicate alerting. |
| collected_dttm | datetime | No | getdate() | When this row was first inserted by the collector. |
| last_polled_dttm | datetime | No | — | When this row was last updated by the collector. |

  - **PK_INT_PipelineTracking** (CLUSTERED): tracking_id -- PRIMARY KEY
  - **IX_INT_PipelineTracking_Incomplete** (NONCLUSTERED): is_complete, last_polled_dttm [includes: run_id, batch_status, status_classification, batch_id, source_insert_dttm, client_id]
  - **IX_INT_PipelineTracking_SourceInsert** (NONCLUSTERED): source_insert_dttm [includes: client_id, client_name, process_type, batch_status, status_classification, is_complete]
  - **UQ_INT_PipelineTracking_run_id** (NONCLUSTERED): run_id

**Check Constraints:**

  - **CK_INT_PipelineTracking_fault_report_type**: `([fault_report_type] IS NULL OR [fault_report_type]='NONE' OR [fault_report_type]='MESSAGE' OR [fault_report_type]='SERVICE' OR [fault_report_type]='TRANSLATION' OR [fault_report_type]='TRANSLATION_ESCALATED')`
  - **CK_INT_PipelineTracking_status_classification**: `([status_classification]='UNCLASSIFIED' OR [status_classification]='DIED_UNHANDLED' OR [status_classification]='FAULT_POST_HANDOFF' OR [status_classification]='DM_REJECTED' OR [status_classification]='STERLING_FAULT' OR [status_classification]='CASCADE_SKIP' OR [status_classification]='DUPLICATE' OR [status_classification]='NO_HANDOFF' OR [status_classification]='NO_FILES' OR [status_classification]='COMPLETE' OR [status_classification]='AWAITING_DM' OR [status_classification]='IN_FLIGHT')`
  - **CK_INT_PipelineTracking_sterling_check_result**: `([sterling_check_result] IS NULL OR ([sterling_check_result]='NOT_FOUND' OR [sterling_check_result]='TERMINATED' OR [sterling_check_result]='RUNNING'))`
  - **CK_INT_PipelineTracking_sterling_status**: `([sterling_status]='UNDEFINED' OR [sterling_status]='IN_PROGRESS' OR [sterling_status]='NO_ACTION' OR [sterling_status]='FAILED' OR [sterling_status]='SUCCESS')`

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| batch_status | 0 | In-flight (source column default; the workflow INSERT supplies no status). Also the permanent value for runs that died without reaching a fault handler. | 1 |
| batch_status | 2 | Transitional: the B2B side is done. For NB/PAY/BDL runs, awaiting DM confirmation by the reconciliation job. For dispatcher rows with NULL SEQ_ID, permanent (the reconciliation join cannot promote them). | 2 |
| batch_status | 3 | Fully complete. For NB/PAY/BDL runs this includes DM-side confirmation written by the reconciliation job. | 3 |
| batch_status | 4 | Dual meaning at the source: no files acquired (workflow tail), or reached status 2 with NULL BATCH_ID meaning the handoff never happened (reconciliation job, NB/PAY/BDL only). Disambiguated in status_classification. | 4 |
| batch_status | 5 | Duplicate file detected; processing suppressed. | 5 |
| batch_status | -1 | Dual meaning at the source: a Sterling-side workflow fault (onFault handler), or a DM-side batch rejection written by the reconciliation job. Disambiguated in status_classification. | 6 |
| batch_status | -2 | Cascade-skip: this run short-circuited because its predecessor in a SEQUENTIAL chain failed. | 7 |
| batch_status | 1 | Defined for the retired ETL_CALL success path. Unreachable since 2024-08; zero rows exist in source history. | 8 |
| fault_report_type | TRANSLATION | The run's fault report is a translation-map report with structured entries. Full report in SI_FaultReport. | 1 |
| fault_report_type | SERVICE | The run's fault report is a service report (e.g. XSLT Service) carrying a service-level exception. Full report in SI_FaultReport. | 2 |
| fault_report_type | MESSAGE | The run's fault report is a bare single-string message. Full report in SI_FaultReport. | 3 |
| fault_report_type | NONE | The collector attempted capture but the failure carried no extractable report. Sentinel that prevents re-attempting; no SI_FaultReport row exists. | 4 |
| status_classification | IN_FLIGHT | Source status 0 and the run is presumed executing (young row, or Sterling cross-check confirmed RUNNING). | 1 |
| status_classification | AWAITING_DM | Source status 2 on a non-dispatcher run: the B2B side is done and the run awaits promotion by the reconciliation job (DM batch confirmation for NB/PAY/BDL handoffs; immediate promotion for other process types). Rows whose DM batch never reaches a recognized terminal code remain here indefinitely - a small permanent-limbo population exists in history. | 2 |
| status_classification | COMPLETE | Fully complete. Source status 3, or a dispatcher/non-handoff run whose terminal state is success. | 3 |
| status_classification | NO_FILES | Source status 4 where the run genuinely acquired no files: either a non-NB/PAY/BDL process type (the reconciliation job never writes 4 for those), or an NB/PAY/BDL run with no nonzero-size pickup rows in BATCH_FILES. | 4 |
| status_classification | NO_HANDOFF | Source status 4 on an NB/PAY/BDL run that acquired files (nonzero-size pickups exist in BATCH_FILES) but never handed off to DM - it reached status 2 with NULL BATCH_ID and the reconciliation job demoted it. | 5 |
| status_classification | DUPLICATE | Source status 5: duplicate file detected, processing suppressed. | 6 |
| status_classification | CASCADE_SKIP | Source status -2: skipped because the predecessor in a SEQUENTIAL chain failed. | 7 |
| status_classification | STERLING_FAULT | Source status -1 where no DM rejection is possible: either NULL BATCH_ID (the workflow faulted before any DM handoff), or a process type outside NEW_BUSINESS/PAYMENT/BDL (the reconciliation job never writes -1 for those types, so the -1 is the workflow fault handler regardless of BATCH_ID). | 8 |
| status_classification | DM_REJECTED | Source status -1 with a BATCH_ID whose DM batch shows a failed or deleted terminal code: DM rejected the batch after handoff (the reconciliation job write, independently re-verified against the DM tables). | 9 |
| status_classification | FAULT_POST_HANDOFF | Source status -1 with a BATCH_ID whose DM batch is healthy: the data landed in DM but the pipeline faulted afterward (cleanup or notification steps died). A distinct triage category. | 10 |
| status_classification | DIED_UNHANDLED | Source status 0 past the aging threshold with a Sterling cross-check of TERMINATED or NOT_FOUND: the run died without reaching a fault handler and will never update its own row. | 11 |
| status_classification | UNCLASSIFIED | The collector could not resolve a classification (missing evidence, verification unavailable). A holding state that should be rare; persistent UNCLASSIFIED rows indicate a collector or source problem. | 12 |
| sterling_check_result | RUNNING | The b2bi WF_INST_S instance for this RUN_ID was found and is still executing. The run is genuinely in flight. | 1 |
| sterling_check_result | TERMINATED | The b2bi instance was found but has ended. Combined with source status 0, the run died without writing a terminal status. | 2 |
| sterling_check_result | NOT_FOUND | No b2bi instance exists for this RUN_ID - the instance aged out of the Sterling runtime retention window (~30 days) or never registered. | 3 |
| sterling_status | SUCCESS | The process reached a successful terminal state within Sterling Integrator. | 1 |
| sterling_status | FAILED | The process failed within Sterling Integrator. | 2 |
| sterling_status | NO_ACTION | The run performed no processing - there was nothing to act on. | 3 |
| sterling_status | IN_PROGRESS | The run has not yet reached a terminal state within Sterling Integrator. | 4 |
| sterling_status | UNDEFINED | The Sterling-level status has not been determined. | 5 |

  - **Collect-B2BPipeline.ps1**: [sort:1] Primary writer. Inserts classified new runs, re-polls and reclassifies incomplete rows inside the lookback working window, resolves dispatcher_name, applies Sterling cross-check results, and increments alert_count when alerts are queued. Rows outside the working window are never touched after reaching their final collected state.
  - **Integration.ETL.tbl_B2B_CLIENTS_BATCH_STATUS**: [sort:2] The mirrored source (external, AVG-PROD-LSNR). One tracking row per source RUN_ID; batch_status, the source dates, and the identity columns are mirrored verbatim. The source row is written by the pipeline workflows themselves (first-party status writes verified from BPML source) and promoted by the reconciliation job FAINT.USP_B2B_CLIENTS_UPDATE_BATCH_STATUS, which runs every minute 00:15-18:59:59.
  - **crs5_oltp DM batch tables**: [sort:3] Classification evidence (external). The -1 disambiguation re-reads the same DM tables the reconciliation job reads: new_bsnss_btch (by batch short name), cnsmr_pymnt_btch and file_registry (by cast registry id). batch_id is the bridge to Debt Manager batch processing and joins to the BatchOps tracking tables (NB_BatchTracking, PMT_BatchTracking) for cross-module analysis of the same batches.
  - **SI_FaultReport**: [sort:4] On failure, the collector captures the Sterling status report into SI_FaultReport (one row per run, linked by run_id) and snapshots the summary fields (fault_report_type, fault_report_code, fault_report_summary, fault_report_captured_dttm) onto this row for join-free display. The full report is fetched from SI_FaultReport only on demand.


### INT_RunFiles

One row per file associated with a Sterling run: the Integration file listing (etl.tbl_B2B_CLIENTS_BATCH_FILES) mirrored for tracked runs, covering both pickups and deliveries.

**Data Flow:** Collect-B2BPipeline.ps1 mirrors file rows from Integration etl.tbl_B2B_CLIENTS_BATCH_FILES for runs present in INT_PipelineTracking, inserting any source rows not yet captured and keyed on source_file_id, on each cycle, within the collection lookback period.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| run_file_id (IDENTITY) | bigint | No | IDENTITY | Surrogate identity key. |
| run_id | bigint | No | — | Sterling workflow/run id the file is associated with; joins INT_PipelineTracking.run_id. |
| source_file_id | int | No | — | Source row ID from etl.tbl_B2B_CLIENTS_BATCH_FILES; the mirror's idempotency key. |
| client_id | bigint | Yes | — | Client identifier as recorded on the source file row. |
| seq_id | int | Yes | — | Client sequence identifier as recorded on the source file row. |
| file_name | varchar(255) | No | — | File name or path as recorded at pickup or delivery. |
| file_size | bigint | Yes | — | File size in bytes as recorded on the source row. |
| comm_method | varchar(200) | Yes | — | Transfer method recorded on the source row (observed values: SFTP_GET, SFTP_PUT). |
| source_insert_dttm | datetime | Yes | — | Source row INSERT_DATE from Integration. |
| captured_dttm | datetime | No | getdate() | When the mirror captured the row. |

  - **PK_INT_RunFiles** (CLUSTERED): run_file_id -- PRIMARY KEY
  - **IX_INT_RunFiles_run_id** (NONCLUSTERED): run_id [includes: file_name, file_size, comm_method, source_insert_dttm]
  - **UQ_INT_RunFiles_source_file_id** (NONCLUSTERED): source_file_id


### INT_RunTickets

One row per (run, ticket reason): the Jira ticket outcomes recorded against a Sterling run, aggregated from the per-failed-account rows in Integration etl.tbl_B2B_CLIENTS_TICKETS.

**Data Flow:** Collect-B2BPipeline.ps1 aggregates etl.tbl_B2B_CLIENTS_TICKETS rows with a populated RUN_ID for tracked runs to (run_id, ticket_reason) grain each cycle within the collection lookback: new pairs are inserted, existing pairs are updated when the ticket number, ticket date, or row count changes, and ticket_status is set from the assignment state (GENERATED when a ticket number is present, PENDING while unassigned within 24 hours of the first source row, AGED_OUT after). The Control Center B2B Pipeline run-detail slideout reads this table on demand.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| run_ticket_id (IDENTITY) | bigint | No | IDENTITY | Surrogate identity key. |
| run_id | bigint | No | — | Sterling workflow/run id the ticket rows are recorded against; joins INT_PipelineTracking.run_id. |
| ticket_reason | varchar(1000) | Yes | — | Ticket reason text as recorded at the source; free text. |
| ticket_num | varchar(100) | Yes | — | Jira ticket number assigned by the ticket generator. |
| ticket_date | datetime | Yes | — | Assignment timestamp recorded with the ticket number. |
| ticket_row_count | int | No | — | Count of source ticket rows aggregated into this row. |
| ticket_status | varchar(20) | No | 'PENDING' | Assignment state of the ticket row: GENERATED, PENDING, or AGED_OUT. |
| first_inserted_dttm | datetime | Yes | — | Earliest source row INSERTED_DATE for the run and reason. |
| captured_dttm | datetime | No | getdate() | When the capture first recorded the row. |
| updated_dttm | datetime | Yes | — | When the capture last refreshed the row (ticket assignment or count growth). |

  - **PK_INT_RunTickets** (CLUSTERED): run_ticket_id -- PRIMARY KEY
  - **IX_INT_RunTickets_run_id** (NONCLUSTERED): run_id [includes: ticket_num, ticket_reason, ticket_date, ticket_row_count]

**Check Constraints:**

  - **CK_INT_RunTickets_ticket_status**: `([ticket_status]='GENERATED' OR [ticket_status]='PENDING' OR [ticket_status]='AGED_OUT')`


### SI_FaultReport

Per-run capture of the Sterling translation status report for failed B2B pipeline runs. One row per failed run that carried an extractable report, sourced from b2bi.dbo.TRANS_DATA via the failing step's STATUS_RPT handle in WORKFLOW_CONTEXT. Stores the full parsed report as JSON plus the raw decompressed text, captured once at collection time and retained permanently.

**Data Flow:** Collect-B2BPipeline.ps1 enriches failed runs in a look-back-and-fill pass: for each INT_PipelineTracking failure within the retention window lacking a captured report, it resolves the failing step's STATUS_RPT handle in b2bi.dbo.WORKFLOW_CONTEXT, reads the gzip blob from b2bi.dbo.TRANS_DATA, decompresses and parses it, then inserts one row here (report_json + raw_report_text) and snapshots the summary fields onto INT_PipelineTracking. When the failing step's report parses as a bare one-line MESSAGE, the collector falls back to the run's last successful Translation step, captures that step's full report instead (fault_report_type = TRANSLATION_ESCALATED), and preserves the one-line message in escalation_message. The Control Center B2B Pipeline run-detail slideout reads this table on demand when the user opens the full report.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| fault_report_id (IDENTITY) | int | No | IDENTITY | Surrogate key. |
| run_id | int | No | — | The failed pipeline run this report belongs to. One-to-one with INT_PipelineTracking.run_id (enforced by a unique constraint and a foreign key). Cross-prefix by design: SI_ marks Sterling provenance, the parent INT_ row is Integration-spined. |
| fault_report_type | varchar(30) | No | — | The report shape captured, which determines how the JSON is structured and rendered. See Status Values. |
| source_name | varchar(255) | Yes | — | The translation map name (TRANSLATION) or service name (SERVICE) the report came from. NULL for a bare MESSAGE report. |
| escalation_message | nvarchar(1000) | Yes | — | The failing step's one-line status message, preserved when the run's report was recovered from the last successful Translation step in the same run (fault_report_type = TRANSLATION_ESCALATED). NULL for reports captured directly from the failing step. |
| report_json | nvarchar(MAX) | Yes | — | The full parsed report as JSON: every report entry with its section, severity, code, and detail. The complete record for on-demand display, independent of the summary fields snapshotted onto INT_PipelineTracking. |
| raw_report_text | nvarchar(MAX) | Yes | — | The decompressed report text as extracted from the blob, before parsing. Preserved as a fallback so no source content is lost even if the parse model changes. |
| captured_dttm | datetime | No | getdate() | When the collector decompressed and captured this report. |

  - **PK_SI_FaultReport** (CLUSTERED): fault_report_id -- PRIMARY KEY
  - **UQ_SI_FaultReport_run_id** (NONCLUSTERED): run_id

**Check Constraints:**

  - **CK_SI_FaultReport_fault_report_type**: `([fault_report_type]='MESSAGE' OR [fault_report_type]='SERVICE' OR [fault_report_type]='TRANSLATION' OR [fault_report_type]='TRANSLATION_ESCALATED')`

**Foreign Keys:**

  - **FK_SI_FaultReport_INT_PipelineTracking**: run_id -> B2B.INT_PipelineTracking.run_id

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| fault_report_type | TRANSLATION | A translation-map report with structured entries (section, severity, code, field/exception detail). The richest shape. | 1 |
| fault_report_type | SERVICE | A service report (e.g. XSLT Service): timestamped message lines and an error total, carrying a service-level exception rather than translation codes. | 2 |
| fault_report_type | MESSAGE | A bare single-string message with no further structure (e.g. the terse wrapper text an inline invoke records). | 3 |

  - **INT_PipelineTracking**: [sort:1] run_id links each report to its failed pipeline run (unique, foreign-keyed). The prefixes differ intentionally: SI_ marks Sterling-sourced content while the parent INT_ row is spined on Integration data. The summary fields (fault_report_type, fault_report_code, fault_report_summary, fault_report_captured_dttm) are snapshotted onto INT_PipelineTracking so the run row and slideout headline need no join; this table holds the full report for on-demand display.


### SI_ScheduleRegistry

Master catalog of IBM Sterling B2B Integrator schedules. Stores one row per SCHEDULEID from b2bi.dbo.SCHEDULE with parsed TIMINGXML structure and a human-readable schedule description. The collector fully synchronizes this table with b2bi on each cycle: new schedules are inserted, changed schedules are re-parsed and updated, and schedules no longer present in b2bi are removed. This table is the authoritative source for "what schedules exist in Sterling, when they run, and their current operational status" for the xFACts B2B module.

**Data Flow:** Collect-B2BExecution.ps1 fully synchronizes this table with b2bi.dbo.SCHEDULE on every collection cycle. The collector queries all rows from SCHEDULE, fetches each TIMINGXML blob from b2bi.dbo.DATA_TABLE, decompresses the gzip content, parses the XML into the structured columns (run_day_mask, run_times_explicit, run_range_start/end, run_interval_minutes, excluded_dates, etc.), generates the human-readable schedule_description, and MERGEs the result. New schedules are INSERTed; existing schedules are re-parsed if the timing_xml_handle has changed; schedules no longer present in b2bi are DELETEd from the registry. The Control Center B2B page (future) reads this table to display the schedule modal/panel. No other xFACts components currently read this table; it will become a join target for SI_ExecutionTracking in Phase 3 Block 2 to correlate observed workflow runs against their expected schedules.

**Raw XML Stored Inline:** [sort:1] The grammar variety observed across 506 active schedules in b2bi produced 73 distinct structural patterns. The parser handles the documented grammar (timingxml/TimingXML root elements, ofWeek/ofMonth day specifiers, <time> and <timeRange> time specifiers, excludedDates), but Sterling has been observed to evolve schedule configurations over time, and a future schedule may introduce grammar that the parser does not recognize. By capturing the raw decompressed XML on every row, the forensic record is preserved regardless of parser coverage. If the parser ever needs to be extended, historical rows can be re-parsed against the same timing_xml column without re-fetching from b2bi, which purges aggressively.

**Full Sync, Not Soft Delete:** [sort:2] Schedules are master data, not operational history. The registry's purpose is to represent "what is configured in Sterling right now" for join and display purposes. If schedule X is removed from Sterling, we do not need to retain a row here — execution history is tracked separately in SI_ExecutionTracking via captured WORKFLOW_ID values, which are independent of the schedule registry. A DELETE on this table does not lose anything that matters, and it keeps the table lean with no lifecycle audit columns (no first_seen, last_seen, is_deleted_in_source, deleted_in_source_dttm). If operational interest in "when did schedule X go away" ever arises, that tracking belongs in a different table with explicit audit semantics.

**run_day_mask as CHAR(7) Bitmap:** [sort:3] Position order is Sun-Mon-Tue-Wed-Thu-Fri-Sat. Each position is either the first letter of that day (S/M/T/W/T/F/S) when the schedule runs that day, or a dash (-) when it does not. This format is directly human-readable in ad-hoc queries (a Mon-Fri schedule shows as "-MTWTF-") and supports fast LIKE-based filtering (e.g., "schedules that run Monday" becomes WHERE run_day_mask LIKE '_M_____'). Seven separate BIT columns would have been more normalized but produce wider rows and noisier query output; an integer bitmap would have been more compact but unreadable without decoding. CHAR(7) with letter-or-dash is the readable compromise.

**Parsed Structure vs. Raw XML: Intent:** [sort:4] Why duplicate the information? Different access patterns. Structured columns support fast queries ("which schedules run in the next hour", "which schedules are weekday-only", "which schedules exclude holidays"). The schedule_description supports display — Control Center modal, report output, ad-hoc investigation — without requiring UI-side parse logic. Raw timing_xml supports forensic re-parse if the grammar evolves. All three views of the same information, each serving a distinct use case. Because the source of truth is b2bi.dbo.SCHEDULE and the collector owns all derivation, the three representations cannot drift.

**onMinute is Vestigial in Practice:** [sort:5] The <onMinute> element appears in every <timeRange> block in every observed schedule, always with value 0. The actual minute marker of fire times (e.g., 05:05 hourly firing at :05 past each hour) is anchored by the minute portion of the range_start value, not by onMinute. This appears to be a Sterling grammar element that is either vestigial, reserved for future use, or overridden by the range definition in practice. The column is retained for lineage completeness, but the schedule_description generator uses the range_start minute rather than run_on_minute to describe the actual fire pattern.

**Columns Dropped From Source SCHEDULE Table:** [sort:6] Dropped columns (all verified constant across 506 active schedules): PARAMS (never populated), EXECUTIONDATE (always 0), EXECUTIONHOUR (always 0), EXECUTIONMINUTE (always 0), EXECUTIONCOUNT (always -1), EXECUTIONCURCOUNT (always 0), ORGANIZATIONKEY (always a single space character — a Sterling multi-tenancy field not used at FAC), XAPIMETHOD (always NULL), XAPIXML (always NULL). Capturing them would add width with no information value. If any of these ever becomes populated with meaningful data in the future, the raw timing_xml column does not help — these live directly on the SCHEDULE row, not in TIMINGXML. They would need to be added to both the table schema and the collector projection. Low-risk given their observed uniformity, but flagged here for future review if Sterling behavior changes.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| schedule_id | int | No | — | Primary key. SCHEDULEID value from b2bi.dbo.SCHEDULE. Immutable identifier assigned by Sterling. |
| service_name | nvarchar(128) | No | — | SERVICENAME from b2bi.dbo.SCHEDULE. Name of the Sterling workflow (business process) this schedule fires. Examples: "FA_CLIENTS_GET_LIST", "FA_AMSURG_MHS_IB_BD_NB", "BackupService". |
| schedule_type | int | No | — | SCHEDULETYPE from b2bi.dbo.SCHEDULE. Sterling-internal integer classifying schedule type. Semantics defined by Sterling, not xFACts; captured for lineage and future correlation. |
| schedule_type_id | int | No | — | SCHEDULETYPEID from b2bi.dbo.SCHEDULE. Sterling-internal secondary classifier. Semantics defined by Sterling; captured for lineage. |
| execution_timer | int | No | — | EXECUTIONTIMER from b2bi.dbo.SCHEDULE. Sterling-internal execution mode flag. Has three distinct observed values across all active schedules (0, 1, 2) — value 1 is dominant. Semantics defined by Sterling; captured for classification research. |
| source_status | nvarchar(50) | No | — | STATUS value from b2bi.dbo.SCHEDULE. Sterling-managed state of the schedule itself — not xFACts-managed. Observed values include ACTIVE, HOLD. Pass-through from Sterling; interpret against Sterling documentation if needed. |
| execution_status | nvarchar(50) | No | — | EXECUTIONSTATUS value from b2bi.dbo.SCHEDULE. Sterling scheduler state for the schedule's execution pipeline — not xFACts-managed. Typical value observed is WAIT. Pass-through from Sterling. |
| timing_xml_handle | nvarchar(255) | No | — | TIMINGXML handle from b2bi.dbo.SCHEDULE — a DATA_ID pointer into b2bi.dbo.DATA_TABLE where the gzip-compressed TIMINGXML blob is stored. Captured for lineage traceability; the collector decompresses this at collection time and stores the result in timing_xml. |
| source_system_name | nvarchar(50) | Yes | — | SYSTEMNAME from b2bi.dbo.SCHEDULE. Sterling cluster node that owns the schedule (e.g., "node1"). Relevant if Sterling is ever run multi-node. |
| source_user_id | nvarchar(255) | Yes | — | USERID from b2bi.dbo.SCHEDULE. User account that created or owns the schedule in Sterling (typically "admin"). |
| timing_pattern_type | varchar(20) | No | — | Derived classifier for the schedule's timing pattern. See status_value entries for valid values and their meanings. Used for UI filtering and classification. Derived by collector from timing_xml structure. |
| run_day_mask | char(7) | Yes | — | CHAR(7) bitmap-style string representing days of week the schedule runs. Position order: Sun-Mon-Tue-Wed-Thu-Fri-Sat. Each position is either the first letter of that day (S/M/T/W/T/F/S) if the schedule runs that day, or a dash (-) if it does not. Examples: "SMTWTFS" = every day (ofWeek=-1), "-MTWTF-" = Mon-Fri, "S-----S" = Sat and Sun. NULL when timing_pattern_type is MONTHLY (ofMonth only). |
| run_days_of_month | varchar(100) | Yes | — | Comma-delimited list of days of month the schedule runs, when ofMonth is used in TIMINGXML. Example: "1,15" for a twice-monthly schedule. NULL when the schedule uses ofWeek instead. |
| run_times_explicit | nvarchar(500) | Yes | — | Comma-delimited list of explicit HH:MM times the schedule runs, when the TIMINGXML contains <time> elements. Example: "05:00,06:00,07:00,...,18:00" for a schedule with 14 hourly fire times. NULL when the schedule uses <timeRange> instead. |
| run_interval_minutes | int | Yes | — | Interval in minutes between runs, parsed from <interval> inside <timeRange>. Example: 60 for hourly. NULL for schedules using explicit <time> entries. |
| run_range_start | char(5) | Yes | — | HH:MM start of the run window, parsed from the first four chars of <range> inside <timeRange>. Example: "05:05". NULL for schedules using explicit <time> entries. |
| run_range_end | char(5) | Yes | — | HH:MM end of the run window, parsed from the last four chars of <range> inside <timeRange>. Example: "15:05". NULL for schedules using explicit <time> entries. |
| run_on_minute | int | Yes | — | Value from <onMinute> inside <timeRange>, captured for lineage completeness. Observed value is 0 for virtually every schedule; the actual minute marker of fire times is derived from run_range_start. Retained for forensic purposes. |
| excluded_dates | nvarchar(500) | Yes | — | Comma-delimited list of MM-DD dates the schedule skips, when <excludedDates> is populated. Example: "01-01,12-25" for a schedule that excludes New Year's Day and Christmas. NULL when no exclusions configured. |
| first_run_time_of_day | char(5) | Yes | — | HH:MM of the earliest run time on any active day, derived from either the minimum <time> value or the start of the <timeRange>. Useful for "will this run in the next hour" queries. NULL only when parsing cannot determine a value (i.e., timing_pattern_type = UNKNOWN). |
| last_run_time_of_day | char(5) | Yes | — | HH:MM of the latest run time on any active day. Useful for "when is the last fire of the day" queries. NULL only when timing_pattern_type = UNKNOWN. |
| expected_runs_per_day | int | Yes | — | Total number of times per day this schedule is expected to fire. For explicit-time patterns, count of <time> entries. For interval patterns, derived from range span and interval. Useful for volume planning and Phase 4 schedule-adherence monitoring. |
| schedule_description | nvarchar(500) | No | — | Human-readable summary generated at parse time. Intended for Control Center display (schedule modal) and ad-hoc query results. Examples: "Daily at 04:00", "Mon-Fri at 14:00", "Every 60 min at :05, 05:05-15:05, Mon-Fri (excl. 01-01, 12-25)", "Days 1,15 of month at 09:00". |
| timing_xml | nvarchar(MAX) | No | — | Full decompressed TIMINGXML content from b2bi.dbo.DATA_TABLE, captured at collection time. Stored raw as the forensic safety net: if the grammar evolves beyond what the parser handles, or the parser has a bug, the raw content is preserved for re-parse without re-fetching from b2bi (which purges aggressively). |
| last_modified_dttm | datetime | No | getdate() | Timestamp of the most recent change to any column on this row. Set to GETDATE() on INSERT by default; updated by the collector on every detected change. |

  - **PK_SI_ScheduleRegistry** (CLUSTERED): schedule_id -- PRIMARY KEY
  - **IX_SI_ScheduleRegistry_service_name** (NONCLUSTERED): service_name [includes: source_status, schedule_description]
  - **IX_SI_ScheduleRegistry_source_status** (NONCLUSTERED): source_status [includes: service_name, schedule_description]
  - **IX_SI_ScheduleRegistry_timing_pattern_type** (NONCLUSTERED): timing_pattern_type

**Check Constraints:**

  - **CK_SI_ScheduleRegistry_timing_pattern_type**: `([timing_pattern_type]='UNKNOWN' OR [timing_pattern_type]='MIXED' OR [timing_pattern_type]='INTERVAL' OR [timing_pattern_type]='MONTHLY' OR [timing_pattern_type]='WEEKLY' OR [timing_pattern_type]='DAILY')`

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| timing_pattern_type | DAILY | Schedule runs every day (ofWeek="-1"), one or more explicit <time> fire points per day. Most common pattern; covers schedules like "Daily at 04:00" or "Daily at 05:00, 06:00, ..., 18:00". | 1 |
| timing_pattern_type | WEEKLY | Schedule runs on specific days of the week (ofWeek="1" through "7") with one or more explicit <time> fire points. Covers patterns like "Mon-Fri at 14:00" or "Sundays at 11:00". | 2 |
| timing_pattern_type | MONTHLY | Schedule runs on specific days of the month (ofMonth="N") with one or more explicit <time> fire points. Covers patterns like "1st of month at 10:41" or "1st and 15th at 09:00". | 3 |
| timing_pattern_type | INTERVAL | Schedule uses <timeRange> pattern with <interval> and <onMinute> — fires every N minutes within a defined HH:MM-HH:MM window. Covers patterns like "Every 60 min, 05:35-23:35, daily" and "Every 5 min, 00:00-23:59, daily". | 4 |
| timing_pattern_type | MIXED | Schedule uses <timeRange> pattern on specific days of week. Example: the FA_CLIENTS_GET_LIST schedule fires every 60 min from 05:05-15:05 on Mon-Fri only. | 5 |
| timing_pattern_type | UNKNOWN | TIMINGXML content did not match any of the documented grammar patterns the parser handles. The raw XML is captured in timing_xml for inspection and parser extension. Rows with this classification should be investigated — either the grammar has evolved or the parser has a gap. | 6 |


### SI_WorkflowRegistry

**Data Flow:** Populated and maintained solely by Collect-B2BPipeline.ps1 step 2. Each cycle queries b2bi.dbo.WFD deduplicated to MAX(WFD_VERSION) per WFD_ID and compares against this table: definitions not yet catalogued INSERT (first_captured_dttm stamps their appearance), version bumps UPDATE current_version while preserving previous_version and stamping last_version_change_dttm, and unchanged rows receive a chunked last_synced_dttm touch. Definitions that disappear from the source are logged and retained - a stale last_synced_dttm marks them. Version changes recorded here feed the collector alert step, which queues a Teams alert per edit (deduped by wfd_id + version).

**Version Census Memory:** [sort:1] The census works by comparison: each sync computes MAX(WFD_VERSION) per WFD_ID at the source and compares it to current_version here. A higher source version means the workflow was edited - previous_version preserves what it changed from, last_version_change_dttm records when the change was observed, and the change is logged. A WFD_ID absent from the registry means a new workflow appeared in Sterling. Both conditions are operationally significant: Sterling definition changes alter pipeline behavior with no other notification path.

**Latest Version Only:** [sort:2] The registry deduplicates to one row per definition. The WFD table primary key is (WFD_ID, WFD_VERSION) and Sterling retains every historical version; joining WFD on WFD_ID alone produces cartesian products across version history. The registry deliberately carries only the latest version and the immediately prior one - full version forensics remain a b2bi query. Sterling engine-tuning attributes (persistence, recovery, priority, lifespan) are deliberately not mirrored; they carry no monitoring value.

**Source Provenance Prefix Convention:** [sort:3] B2B module tables carry a prefix declaring their source system: SI_ tables are sourced directly from the b2bi database on FA-INT-DBP (Sterling itself), while INT_ tables mirror rows written to the Integration database on the AG listener. This table is b2bi-sourced: its content comes from Sterling internal definition storage, not from anything the Integration process writes.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| workflow_registry_id (IDENTITY) | int | No | IDENTITY | Clustered identity primary key. |
| wfd_id | int | No | — | The Sterling workflow definition id (b2bi.dbo.WFD.WFD_ID). Unique - one catalog row per definition, independent of version history. |
| workflow_name | varchar(255) | No | — | The workflow definition name (e.g. FA_CLIENTS_MAIN, FA_FROM_ACADIA_HEALTHCARE_PULL). |
| workflow_description | varchar(255) | Yes | — | The definition description text from the source, when populated. |
| current_version | int | No | — | MAX(WFD_VERSION) for this WFD_ID as of the last sync. Sterling increments the version on every edit of the workflow. |
| previous_version | int | Yes | — | The version this definition held before its most recent observed change. NULL until the first version change is captured. Holds the immediately prior version only - multiple edits between sync cycles record the net change; full version history remains queryable in b2bi. |
| last_version_change_dttm | datetime | Yes | — | When the collector observed the most recent version change. NULL until the first change is captured. |
| edited_by | varchar(50) | Yes | — | The Sterling account that saved the current version (WFD.EDITED_BY of the latest version row). |
| source_status | int | No | — | The definition status code from the source (WFD.STATUS), mirrored verbatim. |
| source_mod_date | datetime | Yes | — | When Sterling recorded the current version being saved (WFD.MOD_DATE of the latest version row). |
| first_captured_dttm | datetime | No | getdate() | When this definition was first captured into the registry. For definitions present at initial deployment this is the deployment date; afterward it marks when a new workflow appeared in Sterling. |
| last_synced_dttm | datetime | No | — | When the census last confirmed this row against the source. Every sync cycle touches this. |

  - **PK_SI_WorkflowRegistry** (CLUSTERED): workflow_registry_id -- PRIMARY KEY
  - **IX_SI_WorkflowRegistry_Name** (NONCLUSTERED): workflow_name [includes: current_version, previous_version, last_version_change_dttm, source_status, source_mod_date]
  - **UQ_SI_WorkflowRegistry_wfd_id** (NONCLUSTERED): wfd_id

  - **Collect-B2BPipeline.ps1**: [sort:1] Sole writer. Step 2 performs the census sync every cycle; step 7 reads recent version changes from this table to queue workflow-change alerts.
  - **b2bi.dbo.WFD**: [sort:2] The source (external, FA-INT-DBP). The WFD primary key is (WFD_ID, WFD_VERSION) with a new version row per workflow edit; the census reads only the latest version per definition. Full version history remains queryable in b2bi and is not mirrored here.


### Collect-B2BPipeline.ps1

Single collector for the B2B module. Eight steps per cycle: schedule sync from b2bi.dbo.SCHEDULE into SI_ScheduleRegistry; workflow version census from b2bi.dbo.WFD into SI_WorkflowRegistry, logging definition changes as the drift signal that Sterling workflows were edited; a set-based classified INSERT of new pipeline runs from Integration.ETL.tbl_B2B_CLIENTS_BATCH_STATUS into INT_PipelineTracking; a set-based re-poll of incomplete runs in the lookback working window; dispatcher name resolution from b2bi instance linkage; a Sterling WF_INST_S cross-check that classifies aged in-flight runs whose instance terminated or vanished as DIED_UNHANDLED; fault-report enrichment that captures the Sterling translation status report for Sterling-internal failures into SI_FaultReport and snapshots summary columns onto INT_PipelineTracking; and Teams alert evaluation via the shared Send-TeamsAlert function - failure classifications alert once per run via alert_count and workflow version changes alert once per edit via trigger dedup, gated by b2b_alerting_enabled and bounded to the working window. Reads GlobalConfig settings b2b_alerting_enabled, b2b_collect_lookback_days, and b2b_inflight_aging_minutes.

**Data Flow:** Step 1 (schedule sync): single JOIN query against b2bi.dbo.SCHEDULE and b2bi.dbo.DATA_TABLE on FA-INT-DBP fetches all schedule rows with their gzip-compressed TIMINGXML blobs (-MaxBinaryLength 20971520). Each blob is decompressed in-memory and parsed into structured columns and a human-readable schedule_description; the step diffs against B2B.SI_ScheduleRegistry and INSERTs new schedules, UPDATEs changed ones, and DELETEs rows whose schedule_id no longer appears in b2bi.    Step 2 (workflow census): queries b2bi.dbo.WFD deduplicated to MAX(WFD_VERSION) per WFD_ID and compares against B2B.SI_WorkflowRegistry: new definitions INSERT, version bumps UPDATE (preserving previous_version, stamping last_version_change_dttm, logging at WARN as the Sterling-edit drift signal), unchanged rows get last_synced_dttm touched in chunked IN-list UPDATEs. Registry rows absent from the source are logged and retained.    Steps 3-4 (pipeline mirror): one shared classified-source CTE runs on the listener against Integration.ETL.tbl_B2B_CLIENTS_BATCH_STATUS joined to the FILES config (PROCESS_TYPE/COMM_METHOD via CLIENT_ID + SEQ_ID, the same derivation the Integration reconciliation job uses), the MN clients master (client_name snapshot), the crs5_oltp DM batch tables per process type (DM outcome verification for the -1 split), and a BATCH_FILES nonzero-size pickup EXISTS (the status-4 split). Step 3 INSERTs classified rows for source runs not yet mirrored, bounded by b2b_collect_lookback_days; step 4 re-polls tracked rows with is_complete = 0 inside the same window via a set-based UPDATE, re-stamping status, enrichment, classification, and completion.    Step 5 (dispatcher resolution): tracked rows missing dispatcher_name resolve COALESCE(parent_id, run_id) against b2bi WF_INST_S/WF_INST_S_RESTORE joined to WFD on WFD_ID + WFD_VERSION, in 500-id chunks, and UPDATE per distinct resolved name.    Step 6 (Sterling cross-check): in-flight rows (batch_status 0) older than b2b_inflight_aging_minutes are checked against WF_INST_S/WF_INST_S_RESTORE: instance present with NULL END_TIME marks sterling_check_result RUNNING; terminated or absent instances classify DIED_UNHANDLED (is_complete = 1, completed_dttm from Sterling END_TIME when available).    Step 7 (fault-report enrichment): Sterling-internal failures (STERLING_FAULT, DIED_UNHANDLED) with fault_report_captured_dttm NULL inside b2b_collect_lookback_days are enriched from b2bi. For each, the failing step's STATUS_RPT handle (BASIC_STATUS <> 0 on a report-producing service - Translation, XSLTService, InlineInvokeBusinessProcessService, MailMimeService) is resolved in WORKFLOW_CONTEXT, the gzip status-report blob is read from TRANS_DATA (parameterized, native byte array) and decompressed, and the report is parsed into one of three shapes (TRANSLATION, SERVICE, MESSAGE). The full parsed report writes to B2B.SI_FaultReport (one row per run) and the summary columns (fault_report_type, fault_report_code, fault_report_summary, fault_report_captured_dttm) snapshot onto INT_PipelineTracking. Failures with no extractable report are marked NONE so they are not re-attempted.    Step 8 (alerts): queries INT_PipelineTracking for failure classifications (STERLING_FAULT, DM_REJECTED, FAULT_POST_HANDOFF, DIED_UNHANDLED, NO_HANDOFF) with alert_count = 0 inside the working window, logs every detection, and queues a Teams alert via Send-TeamsAlert (trigger B2B_<classification> / run_id) and increments alert_count. A second check queries SI_WorkflowRegistry for version changes inside the window and queues a WARNING alert per edit (trigger B2B_WorkflowVersionChange / wfd_id-version); Send-TeamsAlert dedup against Teams.RequestLog guarantees once-per-edit delivery. Orchestration context (TaskId, ProcessId) is passed in by the engine; on completion Complete-OrchestratorTask updates Orchestrator.TaskLog and Orchestrator.ProcessRegistry.

**One collector, seven steps:** [sort:1] The script performs schedule sync, workflow census, pipeline mirror (insert + re-poll), dispatcher resolution, Sterling cross-check, fault-report enrichment, and alert evaluation in every cycle. The single-collector design keeps the orchestrator footprint minimal and shares the b2bi connection, config, and logging machinery. Steps are independent: a failure in one does not block the others, and the summary aggregates per-step results into the orchestrator callback.

**Set-based T-SQL classification on the listener:** [sort:2] Classification is not computed in PowerShell. Because Integration, crs5_oltp, and xFACts are all reachable through the AG listener, one CTE joins the batch-status source to config, client, DM, and pickup evidence and derives status_classification, is_complete, and completed_dttm entirely in T-SQL; the insert and re-poll steps are single cross-database DML statements built around that shared CTE. PowerShell orchestrates and logs; T-SQL classifies.

**is_complete anti-join and the working window:** [sort:3] New-run discovery anti-joins on run_id so mirrored rows are never re-inserted, and the re-poll is bounded to is_complete = 0 rows whose source INSERT_DATE falls inside the lookback window. The window bound matters because history contains permanently-incomplete populations (config-orphaned rows parked at status 2, dead in-flight rows) that would otherwise be re-evaluated every cycle forever: they remain honestly incomplete in the table but sit outside the working set. IX_INT_PipelineTracking_Incomplete supports the incomplete scan.

**Dispatcher resolution via COALESCE(parent_id, run_id):** [sort:4] Wrapper-launched pipeline rows are written by the inline GET_LIST invocation, which executes in the wrapper's own workflow context - so the row's RUN_ID is the wrapper's WORKFLOW_ID and resolves directly to the wrapper WFD name. Dispatched MAIN children carry the dispatcher's WORKFLOW_ID in PARENT_ID instead. COALESCE(parent_id, run_id) therefore yields the correct lookup id for both shapes with no branching. Names resolve only within Sterling's ~30-day runtime retention; older rows keep dispatcher_name NULL.

**Sterling cross-check semantics:** [sort:5] The cross-check unions WF_INST_S and WF_INST_S_RESTORE so archived instances still resolve. Terminal state is detected from END_TIME populated (the same signal the retired collector used); an instance present with NULL END_TIME is genuinely executing and the row stays IN_FLIGHT with sterling_check_result RUNNING. Terminated or absent instances mean the run died without reaching a fault handler - its source row will never leave status 0 - so the row classifies DIED_UNHANDLED with completed_dttm taken from Sterling's END_TIME when available. The aging threshold (b2b_inflight_aging_minutes, default 720) is deliberately conservative because legitimate runs can carry 10-hour executable timeouts.

**VARBINARY fetch uses -MaxBinaryLength:** [sort:6] b2bi stores TIMINGXML as gzip-compressed VARBINARY(MAX). The schedule-sync fetch passes -MaxBinaryLength 20971520 (20MB) on Get-SqlData.

**Fault-report enrichment:** [sort:7] Step 7 processes only Sterling-internal failure classifications (STERLING_FAULT, DIED_UNHANDLED) whose fault_report_captured_dttm is NULL, so it is idempotent and each failure is handled once. It matches the failing step on BASIC_STATUS <> 0 for a configured set of report-producing services (Translation, XSLTService, InlineInvokeBusinessProcessService, MailMimeService), reads and gzip-decompresses the referenced TRANS_DATA blob, and parses one of three report shapes. A blob without the gzip magic bytes is skipped. Failures with no extractable report are stamped NONE rather than left unmarked, so the idempotent scan does not re-attempt them. The report text and the summary columns are written in the collector, not derived in the API, so the capture is permanent and read-time is join-free.

  - **B2B.SI_ScheduleRegistry**: [sort:1] Sole writer. Step 1 issues per-row INSERT, UPDATE, and DELETE statements against this table based on diff with b2bi.dbo.SCHEDULE.
  - **B2B.SI_WorkflowRegistry**: [sort:2] Sole writer. Step 2 INSERTs newly appeared workflow definitions, UPDATEs version-changed ones (preserving previous_version and stamping last_version_change_dttm), and touches last_synced_dttm on unchanged rows in chunked IN-list UPDATEs.
  - **B2B.INT_PipelineTracking**: [sort:3] Primary writer. Steps 3-7 INSERT classified new runs, re-poll and reclassify incomplete rows, resolve dispatcher_name, apply Sterling cross-check results, and snapshot the fault-report summary columns (fault_report_type, fault_report_code, fault_report_summary, fault_report_captured_dttm) on Sterling-internal failures.
  - **xFACts-OrchestratorFunctions.ps1**: [sort:4] Dot-sourced at script startup. Provides Initialize-XFActsScript for SQL module loading and application identity tagging, Get-SqlData and Invoke-SqlNonQuery for database access (including -MaxBinaryLength for the TIMINGXML blob reads), Write-Log and the console helpers, and Complete-OrchestratorTask for the orchestrator completion callback.
  - **b2bi (IBM Sterling B2B Integrator)**: [sort:5] Reads from b2bi on FA-INT-DBP via Windows auth: dbo.SCHEDULE and dbo.DATA_TABLE (schedule sync), dbo.WFD (workflow census and name resolution), dbo.WF_INST_S and dbo.WF_INST_S_RESTORE (dispatcher resolution and the in-flight cross-check). All cross-server correlation happens in PowerShell memory; b2bi is never joined to listener databases in SQL.
  - **Integration and crs5_oltp (via the AG listener)**: [sort:6] The classified-source CTE reads Integration.ETL.tbl_B2B_CLIENTS_BATCH_STATUS, tbl_B2B_CLIENTS_FILES, tbl_B2B_CLIENTS_MN, and tbl_B2B_CLIENTS_BATCH_FILES, plus the crs5_oltp DM batch tables (new_bsnss_btch, cnsmr_pymnt_btch, file_registry) as cross-database joins on the listener connection. The DM joins re-derive the same outcome evidence the Integration reconciliation job (FAINT.USP_B2B_CLIENTS_UPDATE_BATCH_STATUS) reads, so the mirror's -1 disambiguation matches production reconciliation semantics.
  - **Orchestrator.ProcessRegistry**: [sort:7] Registered in Orchestrator.ProcessRegistry as module B2B, process Collect-B2BPipeline (the entry repointed from the retired Collect-B2BExecution at transition). Scheduling and run mode are controlled there; runtime status fields (running_count, last_execution_status, last_duration_ms) are updated by the Complete-OrchestratorTask callback at the end of each run. dependency_group bucket = 10 (collectors).
  - **SI_FaultReport**: [sort:8] Sole writer. Step 7 (fault-report enrichment) INSERTs one row per Sterling-internal failure that carried an extractable status report, decompressed from b2bi TRANS_DATA via the failing step's STATUS_RPT handle. The summary of each report is also snapshotted onto INT_PipelineTracking for join-free display.



# Step 08 -- Fault Report Content: Findings

## 1. Context and goal

The Step 08 goal was fault-report *content completeness*. After the formatted
status-report modal shipped (parser fidelity work, same day), Melissa's review
found it rendered beautifully for some faults but showed a single useless line
for others -- the population captured with `fault_report_type = MESSAGE`. Her
report: the extended detail those faults need exists in Sterling under the
Instance Data "info" column (a section she scrolls to past a wall of XML,
labeled "Translation Report"), and it mirrors what the well-rendering faults
already show. This step confirmed the mechanism, changed the collector to
capture it, remediated history, and surfaced the report in the modal.

## 2. The parser was lossy; the capture was always complete

Reading the collector's parser against a real specimen (run 8605129) showed
`raw_report_text` had always stored the full Sterling report -- all entries,
all Info detail. The gap was in the parser: the TRANSLATION shape kept only
section, severity, code, code label, field name, and exception per entry, and
dropped the entire `Info:` sub-block (block name, field name/number/**data**,
raw block data, signature tag, iteration count, location index) plus report
metadata (map version, translation object name, start/end time, execution ms).
Twelve identical "Mandatory Data Missing" entries collapsed to twelve rows of
nulls in our JSON, while IBM showed each with its distinct block and location.

Because the raw text was complete, **this was a parsing problem, not a
capture or retention problem** -- fixable retroactively by re-parsing stored
raw text. The parser was rewritten to capture full per-entry Info detail into
named fields, preserve unrecognized Info codes generically in `additionalInfo`
(so future Sterling vocabulary is never silently dropped), lift report
metadata to the payload top level, and capture every ERROR line in the SERVICE
shape. `Reparse-B2BFaultReports.ps1` re-parsed all existing rows from
`raw_report_text`; `report_json` must remain fully derivable from the raw text,
so that invariant is why the one-liner (below) could not simply be appended to
raw text.

## 3. The escalated-fault mechanism (the MESSAGE population explained)

The workflow trace for run 8608465 (FA_CLIENTS_MAIN, 2026-07-16 10:14) decoded
the one-liner population. The relevant steps:

| Step | Service | Status | STATUS_RPT | CONTENT |
|---|---|---|---|---|
| 60 | Translation (inside FA_CLIENTS_TRANS) | SUCCESS (BASIC_STATUS 0) | present | present |
| 62 | BPExceptionService | ERROR (ADV 25) | NULL | NULL |
| 63 | InlineInvokeBusinessProcessService | ERROR (ADV 25) | one-liner | present |

Contrast with run 8605129 (which renders beautifully): there the Translation
step itself errored, so the full report rode the error path and the collector's
`BASIC_STATUS <> 0 AND STATUS_RPT IS NOT NULL` filter found it.

For run 8608465 the **map succeeded** -- it produced a report with warnings
(Contains errors ? false, Contains warnings ? true, the Vpakela "Pending
Information from Payer" rows) -- and then the **BPML** inspected that outcome
and deliberately raised a business exception (`BPExceptionService`,
ADV_STATUS 25). So the failing steps (62, 63) carry either no report or a
generic one-liner ("Unrecognized Data Block detected in translator. Please
refer to the Translation Service Log for more details."), which is what our
MESSAGE rows stored. The real report -- the one Melissa reads, with the Raw
Block Data and Location Index -- lives on the **successful Translation step's
STATUS_RPT** (step 60), and a byte-identical copy is embedded in the error
step's CONTENT process-data blob.

## 4. Probe findings (Step_08_Probe.ps1)

The probe read each candidate blob two ways -- exactly as the collector reads
(PAGE_INDEX 0, no binary ceiling) and fully (all pages, `-MaxBinaryLength`) --
and compared both against SQL `DATALENGTH`, then decompressed and inspected
content. Results:

- **Same report in both places.** Step 60 STATUS_RPT decompressed to 1,947
  chars of clean `Map Name: ... Translation Report` text; step 63 CONTENT
  decompressed to the identical report text followed by ~2,300 chars of Java
  process-data serialization (`PROCESS_DATA_HASH_KEYS`, `INLINE_INVOKE_STACK`,
  handle lists). The `<StatusReport>` XML Melissa sees is reconstructed by the
  IBM UI from that serialization, not stored as such.
- **No pagination.** Across 349 recent report/content handles, zero were
  multi-page (max PAGE_INDEX 0, largest blob ~70KB). The collector's
  PAGE_INDEX = 0 read is empirically complete.
- **No binary truncation at these sizes.** The parameterized `Get-SqlData`
  read returned byte counts matching SQL `DATALENGTH` on every handle;
  `-MaxBinaryLength` is not required for report blobs at current sizes.
- **Coverage.** Section 4 census: of runs with any error step in the window,
  none had their report *only* on a successful Translation step in a way that
  left it invisible -- presence was never the problem; the error-step report
  being worthless for the escalated class was.

## 5. Decision: recover from the successful step, not from CONTENT

The collector now falls back, when the failing step's report parses as a bare
MESSAGE, to the run's **last successful Translation step**
(`BASIC_STATUS = 0, SERVICE_NAME = 'Translation', STATUS_RPT IS NOT NULL`,
max STEP_ID), captures that full report as **`TRANSLATION_ESCALATED`**, and
preserves the failing step's one-liner in `SI_FaultReport.escalation_message`.
Runs with a MESSAGE report and no recoverable translation step stay plain
MESSAGE, so genuine service messages keep their meaning.

**CONTENT scraping was evaluated and rejected.** It carries the same report,
but wrapped in Java serialization with no clean end boundary (the report text
runs straight into serialized binary), whereas the successful step's STATUS_RPT
is the exact format the parser already speaks and the raw column stays a
verbatim Sterling report. CONTENT's extra context (FileName, PlacementDate)
belongs to the enrichment survey, sourced cleanly from Integration, not scraped
from a serialization blob. Caveat carried forward: "the two copies are always
identical" is proven for one run and strongly implied by the census; the
historical recovery pass (Section 7) doubled as the wider test.

**Provenance decision.** `TRANSLATION_ESCALATED` was chosen over MESSAGE/
TRANSLATION so the recovered-from-a-different-step provenance is visible at a
glance in the type column. Standing rule: because a raw-text re-parse re-derives
the shape as plain TRANSLATION, **any future re-parse must preserve
TRANSLATION_ESCALATED wherever `escalation_message` is populated.**

## 6. Schema changes and the width lesson

- `SI_FaultReport` gained `escalation_message NVARCHAR(500) NULL` (nullable,
  no default -- metadata-only add), with an Object_Metadata column-description
  row and the table's `data_flow` note updated for the escalated path.
- Both CHECK constraints (`CK_SI_FaultReport_fault_report_type`,
  `CK_INT_PipelineTracking_fault_report_type`) amended to admit
  `TRANSLATION_ESCALATED`.
- **Width lesson:** the first recovery run failed with "String or binary data
  would be truncated." `TRANSLATION_ESCALATED` is 21 characters and
  `fault_report_type` was `VARCHAR(20)`. A CHECK amendment does **not** validate
  against column width -- the constraint happily admitted a value the column
  could not hold. Fix: widen `fault_report_type` `VARCHAR(20) -> VARCHAR(30)`
  on both tables (drop CHECK -> ALTER COLUMN -> re-add CHECK, since ALTER COLUMN
  is blocked while a CHECK references the column). Recorded reflex: when adding
  an enum value longer than the existing set, check the column length.

## 7. Historical recovery and the retention wall

`Recover-B2BEscalatedReports.ps1` (one-time, preview-first) walked all 13
existing MESSAGE rows and attempted the same recovery from b2bi:

- **5 recovered** to TRANSLATION_ESCALATED (runs from 2026-07-15 and 07-16):
  report row upgraded (type, source, json, raw text, escalation_message) and
  the tracking snapshots refreshed; `captured_dttm` left untouched as the
  original-capture record.
- **8 left as MESSAGE** (runs from 2026-07-14 and earlier): aged out of b2bi
  retention.

This pins the fault-report handle retention wall between **2026-07-14 and
2026-07-15**, consistent with the ~3-4 day handle retention (Roadmap §4.3).
The 8 unrecoverable reports are the permanent cost of the escalated-recovery
gap existing between when the pattern first appeared and when it was closed --
not a defect in the fix.

## 8. UI

The fault-report API endpoint now returns `escalation_message`. The modal
treats `TRANSLATION_ESCALATED` identically to TRANSLATION (full formatted
view) with an "Escalated By" metadata row carrying the one-liner, and
warning-only reports (typical for escalated recoveries, which carry warnings
rather than errors) default to the all-entries view so the user is not greeted
by an empty errors-only list. The raw-report toggle remains the acceptance
surface: the verbatim `raw_report_text` set next to Sterling's Status Report
screen for character-for-character confirmation.

## 9. Residual and follow-ons

- 8 pre-retention-wall MESSAGE rows remain MESSAGE permanently (reports no
  longer exist at the source).
- Genuine (non-escalated) MESSAGE captures are correct as-is and unchanged.
- Melissa to confirm whether Sterling ever produces multiple report-bearing
  error steps in one run (open question from the parser-fidelity work); the
  current grain remains one report row per run.
- CONTENT's file/client context feeds the enrichment survey, not the fault
  report.

## Artifacts in this step folder

| File | Purpose |
|---|---|
| Step_08_Query.sql | Handle-resolution, pagination, coverage, and per-run pattern census |
| Step_08_Probe.ps1 | Two-way blob read + content inspection (disposable) |
| Recover-B2BEscalatedReports.ps1 | One-time historical recovery (disposable) |
| Step_08_Findings.md | This document |

Related deliverables (not in this folder): the collector change
(Collect-B2BPipeline.ps1), the re-parse utility (Reparse-B2BFaultReports.ps1,
Step 08's sibling parser-fidelity work), the schema scripts (transient), and
the API/JS/CSS modal changes.

## Document status

| Attribute | Value |
|---|---|
| Step | 08 -- Fault Report Content |
| Status | **Complete** |
| Next | Enrichment survey (per-run file/client/record/Jira summary); deferred B2B System_Metadata bump folds in all 2026-07-16 structural work |
| Roadmap impact | §4.2b added (four Known True entries); §3.1 collector line, §8 findings list, §9, Next Session, and history updated to v3.2; fault-report content marked done; enrichment survey promoted to lead |

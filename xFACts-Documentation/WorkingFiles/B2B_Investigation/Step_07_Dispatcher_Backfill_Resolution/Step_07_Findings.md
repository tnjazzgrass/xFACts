# Step 07 -- Dispatcher Resolution: Findings

## 1. Context and goal

After the 2026-07-16 structural backfill, ~412K rows in `B2B.INT_PipelineTracking`
still carried NULL `dispatcher_name`: ~149K top-level scheduled parents, ~250K
children, and ~13K parentless seq'd orphans. The open problem was framed as a
missing "run -> schedule link." Step 07 re-examined that framing, verified the
structural rules against live ground truth, discovered and corrected a
false-positive mechanism in the prior backfill, validated a schedule-timing
disambiguation method, and executed a write pass that resolved 142,264 NULLs
and corrected 806 mislabeled rows.

## 2. The reframe: there never was a missing schedule link

Reading `Collect-B2BPipeline.ps1` Step-b2b_ResolveDispatcherNames showed the
live path never consults `SCHEDULE` at all. For each unresolved row it looks up
`COALESCE(parent_id, run_id)` in `b2bi.dbo.WF_INST_S` (+ `_RESTORE`), joins to
`dbo.WFD`, and takes the workflow definition NAME. Consequences:

- A top-level scheduled parent's dispatcher is **its own workflow definition
  name** (self-naming); it equals the firing schedule's `service_name` only
  because that is the workflow the schedule launches.
- The historical gap was never a missing column in `SCHEDULE` or
  `SI_ScheduleRegistry`; it is the purge of the run -> definition mapping when
  `WF_INST_S` rows age out of Sterling's runtime retention.
- Corollary verified by query (Step_07_Query section 5a, second result set,
  empty): **every live-resolved dispatcher value is a `service_name` in
  `SI_ScheduleRegistry`** -- the registry's coverage is complete for this
  purpose.

## 3. Verified rule: child dispatcher = parent dispatcher

Across 6,201 live parent/child pairs where both sides were resolved from b2bi
independently (each on its own instance id), **zero mismatches**. A child's
`dispatcher_name` always equals its parent's, and parents self-name. This
upgraded the propagation design from assumption to verified fact and licensed
both the upward propagation (children name their parent) and the correction of
children that contradict a known parent value.

## 4. Discovery: sibling-backfill false positives (conflict families)

The 2026-07-16 single-match sibling backfill applied a dispatcher wherever a
(client_id, seq_id, process_type, comm_method) key mapped to exactly one
distinct dispatcher in the ~6-day live reference window. Step 07 found 1,548
NULL parents whose resolved children *disagreed* -- impossible under the
verified rule, therefore at least one value per parent was wrong. The
signatures resolved to a small set of **sibling-schedule families** serving the
same clients (arrival-time routing): HSS_HB EOBD/EOBD_2, ACADIA EO/EO_FD/
EO_P2S_RC (+RTNT), HSS INSURANCE D2S_RC/NB_TR, LEXIS_NEXIS SP/SP2, MEDICAL
CENTER NB/RT, REVSPRING BD_PULL/IB_PULL, a REVSPRING ITS 5-way, and a
Vanderbilt pair. Mechanism: when only one family member appeared in the live
window, the single-match test passed and mislabeled historical rows actually
dispatched by the other member.

Exposure beyond the visible conflicts: 13,988 *agreeing* parents carried an
agreed value belonging to a conflict family ("unanimous but possibly
unanimously wrong"). Post-adjudication measurement: only 13 of these were
actually overruled by timing -- the fear was real but small. In total **806
children carried provably wrong values and were corrected** (largest blocks:
ACADIA P2S_RC -> EO 295, LEXIS_NEXIS SP2 -> SP 229, ACADIA FD -> EO 149,
REVSPRING BD_PULL -> IB_PULL 76).

## 5. Schedule-timing disambiguation: calibrated, validated, adopted

Within a conflict family the question collapses to "which of these few
schedules fired this run," and `SI_ScheduleRegistry` holds each candidate's
declared fire times. Calibration and validation against live ground truth
(parents whose dispatcher is known from b2bi):

- **Lag calibration:** 92% of live scheduled runs land within 1 minute of a
  declared fire time (715 of 776); the remainder (60 runs at 16+ minutes) are
  off-schedule launches no timing method should classify.
- **Blind validation:** hiding the known dispatcher and letting smallest-lag
  pick among family candidates scored **147 correct / 4 incorrect / 0 ties**.
  All four misses were off-schedule FA_FROM_REVSPRING_IB_PULL runs captured by
  BD_PULL's 14-times-daily grid -- exactly the population a lag threshold
  rejects. Every other family scored 100%.
- **Adopted parameters:** accept a timing pick only when the winning lag is
  <= 2 minutes and there is no tie. Candidates without explicit fire times
  cannot win by construction. Day-of-week masks are ignored (validated as-is;
  errors from that simplification would have surfaced as incorrect verdicts
  and did not).

**Decision (recorded):** timing-resolved values are inference, not source
fact. For `dispatcher_name` specifically this is accepted without a marker
column: the field is informational (not a reporting touchpoint), the
go-forward path is exact, and the method measured ~100% accurate under the
threshold on ground truth. This bounds and supersedes the earlier Roadmap
caution ("never write inferred values into dispatcher_name as fact") for this
field only; the general investigation-first stance is unchanged.

## 6. The write pass (Step_07_Dispatcher_Backfill.sql)

Resolution paths over the 104,846 NULL scheduled parents with resolved-child
evidence (of 148,939 total at execution time):

| Path | Parents | Meaning |
|---|---|---|
| A-STRUCTURAL | 89,310 | Children unanimous, value outside all conflict families |
| B-TIMING | 14,507 | Conflicted or exposed; timing pick accepted (lag <= 2, no tie) |
| B-FALLBACK-UNANIMOUS | 205 | Exposed, no accepted timing pick; unanimous child value taken |
| UNRESOLVED-CONFLICT | 824 | Conflicted, no accepted timing pick; left NULL |

Writes, in order: 104,022 parents resolved; 806 provably-wrong children
corrected to their parent's value (the only non-NULL updates, per explicit
decision); 38,005 NULL children inherited from resolved parents (looped to
stability); 249 residual sibling single-match rows filled with conflict-family
values excluded from the reference set. Post-pass rule check across the whole
table: **zero** parent/child dispatcher disagreements.

NULL census, before -> after: scheduled parents 148,936 -> 44,917; seq'd
orphans 13,108 -> 12,987; children 249,881 -> 211,757; total 411,925 ->
269,661. Table-wide dispatcher coverage moved from ~76% to ~84%.

## 7. Discovery: the 2023-12-01 parent-row boundary

The residual census split the remaining NULL children with a surgical date
boundary:

| Residual category | Rows | Date span |
|---|---|---|
| Parent not in table | 88,752 | 2021-09-22 -> 2023-12-01 12:05 |
| Parent in table, still NULL | 123,017 | 2023-12-01 12:30 -> present |

The oldest scheduled parent row anywhere in the mirror is 2023-12-01 12:10.
**Top-level scheduled parent rows do not exist in BATCH_STATUS history before
midday 2023-12-01.** The 88,752 pre-boundary children reference parent runs
that never wrote a status row at the source -- not a capture gap in the mirror.
The yearly ramp of these children (2021: 3,917; 2022: 19,806; 2023: 65,029)
reflects volume growth up to the cutover. Mechanism hypothesis (unverified): a
source-side wrapper/BPML change on that date began inserting a parent
BATCH_STATUS row for scheduled sweeps. Practical consequence: these 88,752
rows are structurally unrecoverable in-table -- no method can name a parent
that does not exist.

## 8. Final residual and open threads

Remaining 269,661 NULLs, fully characterized:

- 44,917 scheduled parents: ~44,093 sweeps with no resolved-child evidence
  (mostly empty polls and retired keys) + 824 unresolved conflicts.
- 123,017 children under those parents.
- 88,752 pre-boundary children (parents never existed at the source).
- 12,987 seq'd orphans (keys never observed in the live window; largely
  retired clients/cadences).

Open threads:

1. **CLIENTS_PARAM fuzzy-match experiment** (flagged, not started): per-client
   translation-map values partially resemble service names; a final-attempt
   inference pass over the residual could be explored once designed. Note:
   TRANSLATION_MAP was previously evaluated and **rejected as a direct
   dispatcher source** (Roadmap section 5.8 -- it names the execution/
   translation service, not the dispatcher, and disagreed with trusted
   resolved rows), so expectations are low; a fuzzy variant would need its
   own accuracy validation before any write.
2. **Periodic sibling re-run** is near-exhausted as a recovery tool (249 rows
   this pass); rare cadences may still trickle in but expectations are low.
3. Go-forward path is healthy: 100% daily resolution since 2026-07-11; the
   known benign shortfall (~750 instance ids resolving in neither WF_INST_S
   nor _RESTORE) persists at small scale.

## Artifacts in this step folder

| File | Purpose |
|---|---|
| Step_07_Query.sql | Verification + calibration + validation queries |
| Step_07_Results.txt | Results of the above |
| Step_07_Dispatcher_Backfill.sql | The write pass (build/preview/write/verify) |
| Dispatcher_Backfill_Update_Results.txt | Write-pass output |
| Step_07_Residual_Census.sql | Residual characterization queries |
| Step_07_Findings.md | This document |

Predecessor artifact (pre-formalization): B2B_Dispatcher_Backfill_Census.sql,
the ad-hoc census that surfaced the propagation opportunity and the conflicts.

## Document status

| Attribute | Value |
|---|---|
| Step | 07 -- Dispatcher Resolution |
| Status | **Complete** |
| Next | Roadmap refresh (v3.1); enrichment survey (run-level file/client/record summary concept) |
| Roadmap impact | Next Session section 1 (dispatcher problem) closes to a characterized residual; section 4.2a gains the reframe (run -> definition, not run -> schedule), the verified child = parent rule, the sibling false-positive mechanism + correction, the timing method + accepted-inference decision, and the 2023-12-01 parent-row boundary; section 9 item 1 replaced by the CLIENTS_PARAM experiment as an optional final attempt |

/* ============================================================================
   Step 07 -- Dispatcher Resolution: verification + schedule-timing calibration
   Read-only, no writes anywhere. Run against the xFACts database (AG listener).
   Step through by section.

   Purpose:
     1. Prove the propagation rule (child dispatcher = parent dispatcher) as
        verified fact using live-resolved ground truth.
     2. Measure how strongly the 103K "agreeing" parents are supported.
     3. Characterize the 1,548 conflict families (sibling-schedule pairs).
     4. Measure how many agreeing parents are exposed to the same false-positive
        mechanism that produced the conflicts.
     5. Calibrate and validate schedule-timing disambiguation against live
        ground truth (known-dispatcher parents vs SI_ScheduleRegistry times).

   Row categories (as in the census):
     Scheduled parent : parent_id IS NULL AND seq_id IS NULL
                        AND (process_type IS NULL OR process_type <> 'CORE_PROCESS')
     Child            : parent_id IS NOT NULL
   ============================================================================ */

DECLARE @LiveBoundary DATETIME = '2026-07-10T14:56:00';  -- collector dispatcher-step deploy

/* ============================================================================
   SECTION 1 -- Propagation-rule proof (live ground truth)
   Every live-resolved child should carry exactly its live-resolved parent's
   dispatcher (both sides resolved from b2bi by the collector, independently).
   Expected: mismatched_rows = 0. Any nonzero breaks the propagation design.
   ============================================================================ */

SELECT COUNT(*) AS live_child_parent_pairs,
       SUM(CASE WHEN c.dispatcher_name <> p.dispatcher_name THEN 1 ELSE 0 END) AS mismatched_rows
FROM B2B.INT_PipelineTracking c
INNER JOIN B2B.INT_PipelineTracking p
        ON p.run_id = c.parent_id
WHERE c.dispatcher_name IS NOT NULL
  AND p.dispatcher_name IS NOT NULL
  AND c.source_insert_dttm >= @LiveBoundary
  AND p.source_insert_dttm >= @LiveBoundary;

-- Sample any mismatches for inspection (empty result = rule holds).
SELECT TOP 20
       c.run_id, c.parent_id,
       c.dispatcher_name AS child_dispatcher,
       p.dispatcher_name AS parent_dispatcher,
       c.source_insert_dttm
FROM B2B.INT_PipelineTracking c
INNER JOIN B2B.INT_PipelineTracking p
        ON p.run_id = c.parent_id
WHERE c.dispatcher_name IS NOT NULL
  AND p.dispatcher_name IS NOT NULL
  AND c.source_insert_dttm >= @LiveBoundary
  AND p.source_insert_dttm >= @LiveBoundary
  AND c.dispatcher_name <> p.dispatcher_name
ORDER BY c.source_insert_dttm DESC;

/* ============================================================================
   SECTION 2 -- Agreement strength for the propagation set
   How many resolved children back each agreeing NULL parent? A parent backed
   by one sibling-matched child is weaker evidence than one backed by several.
   ============================================================================ */

WITH AgreeingParents AS (
    SELECT p.run_id,
           COUNT(CASE WHEN c.dispatcher_name IS NOT NULL
                       AND c.dispatcher_name <> 'FA_CLIENTS_GET_LIST' THEN 1 END) AS resolved_children
    FROM B2B.INT_PipelineTracking p
    INNER JOIN B2B.INT_PipelineTracking c
            ON c.parent_id = p.run_id
    WHERE p.dispatcher_name IS NULL
      AND p.parent_id IS NULL
      AND p.seq_id IS NULL
      AND (p.process_type IS NULL OR p.process_type <> 'CORE_PROCESS')
    GROUP BY p.run_id
    HAVING COUNT(DISTINCT CASE WHEN c.dispatcher_name IS NOT NULL
                                AND c.dispatcher_name <> 'FA_CLIENTS_GET_LIST'
                               THEN c.dispatcher_name END) = 1
)
SELECT CASE
           WHEN resolved_children = 1 THEN '1 resolved child'
           WHEN resolved_children = 2 THEN '2 resolved children'
           WHEN resolved_children <= 5 THEN '3-5 resolved children'
           ELSE '6+ resolved children'
       END AS support_level,
       COUNT(*) AS parent_count
FROM AgreeingParents
GROUP BY CASE
           WHEN resolved_children = 1 THEN '1 resolved child'
           WHEN resolved_children = 2 THEN '2 resolved children'
           WHEN resolved_children <= 5 THEN '3-5 resolved children'
           ELSE '6+ resolved children'
       END
ORDER BY support_level;

/* ============================================================================
   SECTION 3 -- Conflict family census
   Groups the 1,548 conflicted parents by the distinct set of dispatcher values
   their children carry (the family signature). Expected: a small number of
   sibling-schedule families accounting for nearly all conflicts.
   ============================================================================ */

WITH ConflictParents AS (
    SELECT p.run_id
    FROM B2B.INT_PipelineTracking p
    INNER JOIN B2B.INT_PipelineTracking c
            ON c.parent_id = p.run_id
           AND c.dispatcher_name IS NOT NULL
           AND c.dispatcher_name <> 'FA_CLIENTS_GET_LIST'
    WHERE p.dispatcher_name IS NULL
      AND p.parent_id IS NULL
      AND p.seq_id IS NULL
      AND (p.process_type IS NULL OR p.process_type <> 'CORE_PROCESS')
    GROUP BY p.run_id
    HAVING COUNT(DISTINCT c.dispatcher_name) > 1
),
Signatures AS (
    SELECT cp.run_id,
           STUFF((SELECT ' | ' + d.dispatcher_name
                  FROM (SELECT DISTINCT c.dispatcher_name
                        FROM B2B.INT_PipelineTracking c
                        WHERE c.parent_id = cp.run_id
                          AND c.dispatcher_name IS NOT NULL
                          AND c.dispatcher_name <> 'FA_CLIENTS_GET_LIST') d
                  ORDER BY d.dispatcher_name
                  FOR XML PATH(''), TYPE).value('.', 'VARCHAR(MAX)'), 1, 3, '') AS family_signature
    FROM ConflictParents cp
)
SELECT family_signature,
       COUNT(*) AS conflicted_parents
FROM Signatures
GROUP BY family_signature
ORDER BY COUNT(*) DESC;

/* ============================================================================
   SECTION 4 -- Risk exposure of the agreeing parents
   An agreeing parent whose agreed dispatcher belongs to a conflict family
   could be unanimously mislabeled by the same single-match false-positive
   mechanism. Counts that exposure, by dispatcher.
   ============================================================================ */

WITH ConflictParents AS (
    SELECT p.run_id
    FROM B2B.INT_PipelineTracking p
    INNER JOIN B2B.INT_PipelineTracking c
            ON c.parent_id = p.run_id
           AND c.dispatcher_name IS NOT NULL
           AND c.dispatcher_name <> 'FA_CLIENTS_GET_LIST'
    WHERE p.dispatcher_name IS NULL
      AND p.parent_id IS NULL
      AND p.seq_id IS NULL
      AND (p.process_type IS NULL OR p.process_type <> 'CORE_PROCESS')
    GROUP BY p.run_id
    HAVING COUNT(DISTINCT c.dispatcher_name) > 1
),
ConflictDispatchers AS (
    SELECT DISTINCT c.dispatcher_name
    FROM ConflictParents cp
    INNER JOIN B2B.INT_PipelineTracking c
            ON c.parent_id = cp.run_id
    WHERE c.dispatcher_name IS NOT NULL
      AND c.dispatcher_name <> 'FA_CLIENTS_GET_LIST'
),
AgreeingParents AS (
    SELECT p.run_id,
           MAX(CASE WHEN c.dispatcher_name IS NOT NULL
                     AND c.dispatcher_name <> 'FA_CLIENTS_GET_LIST'
                    THEN c.dispatcher_name END)                            AS agreed_dispatcher,
           COUNT(CASE WHEN c.dispatcher_name IS NULL THEN 1 END)           AS null_children
    FROM B2B.INT_PipelineTracking p
    INNER JOIN B2B.INT_PipelineTracking c
            ON c.parent_id = p.run_id
    WHERE p.dispatcher_name IS NULL
      AND p.parent_id IS NULL
      AND p.seq_id IS NULL
      AND (p.process_type IS NULL OR p.process_type <> 'CORE_PROCESS')
    GROUP BY p.run_id
    HAVING COUNT(DISTINCT CASE WHEN c.dispatcher_name IS NOT NULL
                                AND c.dispatcher_name <> 'FA_CLIENTS_GET_LIST'
                               THEN c.dispatcher_name END) = 1
)
SELECT ap.agreed_dispatcher,
       COUNT(*)              AS exposed_parents,
       SUM(ap.null_children) AS exposed_null_children
FROM AgreeingParents ap
INNER JOIN ConflictDispatchers cd
        ON cd.dispatcher_name = ap.agreed_dispatcher
GROUP BY ap.agreed_dispatcher
ORDER BY COUNT(*) DESC;

/* ============================================================================
   SECTION 5a -- Schedule registry timing-shape census + coverage
   How much of the live scheduled-parent population is covered by schedules
   with explicit fire times (the shape the timing method can match against)?
   Second query: live parents whose dispatcher matches no registry schedule.
   ============================================================================ */

SELECT s.timing_pattern_type,
       CASE
           WHEN s.run_times_explicit IS NOT NULL AND s.run_times_explicit <> '' THEN 'EXPLICIT TIMES'
           WHEN s.run_interval_minutes IS NOT NULL                              THEN 'INTERVAL'
           ELSE 'OTHER'
       END AS timing_shape,
       COUNT(DISTINCT s.service_name) AS schedules,
       COUNT(lp.run_id)               AS live_parent_runs
FROM B2B.SI_ScheduleRegistry s
LEFT JOIN B2B.INT_PipelineTracking lp
       ON lp.dispatcher_name = s.service_name
      AND lp.parent_id IS NULL
      AND lp.seq_id IS NULL
      AND (lp.process_type IS NULL OR lp.process_type <> 'CORE_PROCESS')
      AND lp.dispatcher_name IS NOT NULL
      AND lp.source_insert_dttm >= @LiveBoundary
GROUP BY s.timing_pattern_type,
         CASE
             WHEN s.run_times_explicit IS NOT NULL AND s.run_times_explicit <> '' THEN 'EXPLICIT TIMES'
             WHEN s.run_interval_minutes IS NOT NULL                              THEN 'INTERVAL'
             ELSE 'OTHER'
         END
ORDER BY s.timing_pattern_type, timing_shape;

-- Coverage gap: live-resolved scheduled parents with no matching registry schedule.
SELECT lp.dispatcher_name,
       COUNT(*) AS live_parent_runs_unmatched
FROM B2B.INT_PipelineTracking lp
WHERE lp.parent_id IS NULL
  AND lp.seq_id IS NULL
  AND (lp.process_type IS NULL OR lp.process_type <> 'CORE_PROCESS')
  AND lp.dispatcher_name IS NOT NULL
  AND lp.source_insert_dttm >= @LiveBoundary
  AND NOT EXISTS (
      SELECT 1 FROM B2B.SI_ScheduleRegistry s
      WHERE s.service_name = lp.dispatcher_name
  )
GROUP BY lp.dispatcher_name
ORDER BY COUNT(*) DESC;

/* ============================================================================
   SECTION 5b -- Lag calibration (live ground truth, explicit-times schedules)
   For live-resolved scheduled parents, minutes between the schedule's nearest
   preceding declared fire time and the parent's source_insert_dttm. Measures
   the fire-to-status-row write delay the timing method must tolerate. A
   consistent small lag validates the approach; wide scatter argues against it.
   Note: day-of-week masks are ignored here (lag wraps within the day).
   ============================================================================ */

WITH FireTimes AS (
    SELECT s.service_name,
           DATEPART(HOUR, ft.fire_time) * 60 + DATEPART(MINUTE, ft.fire_time) AS fire_mod
    FROM B2B.SI_ScheduleRegistry s
    CROSS APPLY (SELECT CAST('<t>' + REPLACE(s.run_times_explicit, ',', '</t><t>') + '</t>' AS XML) AS xdoc) d
    CROSS APPLY d.xdoc.nodes('/t') x(n)
    CROSS APPLY (SELECT CAST(LTRIM(RTRIM(x.n.value('.', 'VARCHAR(10)'))) AS TIME) AS fire_time) ft
    WHERE s.run_times_explicit IS NOT NULL
      AND s.run_times_explicit <> ''
),
LiveParents AS (
    SELECT run_id, dispatcher_name,
           DATEPART(HOUR, source_insert_dttm) * 60 + DATEPART(MINUTE, source_insert_dttm) AS parent_mod
    FROM B2B.INT_PipelineTracking
    WHERE parent_id IS NULL
      AND seq_id IS NULL
      AND (process_type IS NULL OR process_type <> 'CORE_PROCESS')
      AND dispatcher_name IS NOT NULL
      AND source_insert_dttm >= @LiveBoundary
),
Lags AS (
    SELECT lp.run_id, lp.dispatcher_name,
           MIN((lp.parent_mod - ft.fire_mod + 1440) % 1440) AS lag_minutes
    FROM LiveParents lp
    INNER JOIN FireTimes ft
            ON ft.service_name = lp.dispatcher_name
    GROUP BY lp.run_id, lp.dispatcher_name, lp.parent_mod
)
SELECT dispatcher_name,
       COUNT(*)                                   AS runs,
       MIN(lag_minutes)                           AS min_lag,
       CAST(AVG(1.0 * lag_minutes) AS DECIMAL(8,2)) AS avg_lag,
       MAX(lag_minutes)                           AS max_lag
FROM Lags
GROUP BY dispatcher_name
ORDER BY MAX(lag_minutes) DESC;

-- Overall lag histogram across all explicit-times live parents.
WITH FireTimes AS (
    SELECT s.service_name,
           DATEPART(HOUR, ft.fire_time) * 60 + DATEPART(MINUTE, ft.fire_time) AS fire_mod
    FROM B2B.SI_ScheduleRegistry s
    CROSS APPLY (SELECT CAST('<t>' + REPLACE(s.run_times_explicit, ',', '</t><t>') + '</t>' AS XML) AS xdoc) d
    CROSS APPLY d.xdoc.nodes('/t') x(n)
    CROSS APPLY (SELECT CAST(LTRIM(RTRIM(x.n.value('.', 'VARCHAR(10)'))) AS TIME) AS fire_time) ft
    WHERE s.run_times_explicit IS NOT NULL
      AND s.run_times_explicit <> ''
),
LiveParents AS (
    SELECT run_id, dispatcher_name,
           DATEPART(HOUR, source_insert_dttm) * 60 + DATEPART(MINUTE, source_insert_dttm) AS parent_mod
    FROM B2B.INT_PipelineTracking
    WHERE parent_id IS NULL
      AND seq_id IS NULL
      AND (process_type IS NULL OR process_type <> 'CORE_PROCESS')
      AND dispatcher_name IS NOT NULL
      AND source_insert_dttm >= @LiveBoundary
),
Lags AS (
    SELECT lp.run_id,
           MIN((lp.parent_mod - ft.fire_mod + 1440) % 1440) AS lag_minutes
    FROM LiveParents lp
    INNER JOIN FireTimes ft
            ON ft.service_name = lp.dispatcher_name
    GROUP BY lp.run_id, lp.parent_mod
)
SELECT CASE
           WHEN lag_minutes <= 1  THEN '0-1 min'
           WHEN lag_minutes <= 5  THEN '2-5 min'
           WHEN lag_minutes <= 15 THEN '6-15 min'
           ELSE '16+ min'
       END AS lag_bucket,
       COUNT(*) AS runs
FROM Lags
GROUP BY CASE
           WHEN lag_minutes <= 1  THEN '0-1 min'
           WHEN lag_minutes <= 5  THEN '2-5 min'
           WHEN lag_minutes <= 15 THEN '6-15 min'
           ELSE '16+ min'
       END
ORDER BY lag_bucket;

/* ============================================================================
   SECTION 5c -- Disambiguation validation against live ground truth
   For live-resolved parents whose dispatcher belongs to a conflict family,
   pretend we do not know the dispatcher: offer every family candidate and let
   the smallest lag pick. Compare the pick to the known truth.
   Verdicts: CORRECT (timing picked the real dispatcher), INCORRECT, TIE.
   High CORRECT rate = the method is safe to apply to the conflicted parents.
   Candidates without explicit fire times drop out (see 5a coverage).
   ============================================================================ */

WITH ConflictParents AS (
    SELECT p.run_id
    FROM B2B.INT_PipelineTracking p
    INNER JOIN B2B.INT_PipelineTracking c
            ON c.parent_id = p.run_id
           AND c.dispatcher_name IS NOT NULL
           AND c.dispatcher_name <> 'FA_CLIENTS_GET_LIST'
    WHERE p.dispatcher_name IS NULL
      AND p.parent_id IS NULL
      AND p.seq_id IS NULL
      AND (p.process_type IS NULL OR p.process_type <> 'CORE_PROCESS')
    GROUP BY p.run_id
    HAVING COUNT(DISTINCT c.dispatcher_name) > 1
),
ConflictChildren AS (
    SELECT c.parent_id, c.dispatcher_name
    FROM ConflictParents cp
    INNER JOIN B2B.INT_PipelineTracking c
            ON c.parent_id = cp.run_id
    WHERE c.dispatcher_name IS NOT NULL
      AND c.dispatcher_name <> 'FA_CLIENTS_GET_LIST'
),
Pairs AS (
    SELECT DISTINCT a.dispatcher_name AS actual_d, b.dispatcher_name AS cand_d
    FROM ConflictChildren a
    INNER JOIN ConflictChildren b
            ON b.parent_id = a.parent_id
           AND b.dispatcher_name <> a.dispatcher_name
),
Candidates AS (
    SELECT actual_d, cand_d FROM Pairs
    UNION
    SELECT DISTINCT actual_d, actual_d FROM Pairs
),
FireTimes AS (
    SELECT s.service_name,
           DATEPART(HOUR, ft.fire_time) * 60 + DATEPART(MINUTE, ft.fire_time) AS fire_mod
    FROM B2B.SI_ScheduleRegistry s
    CROSS APPLY (SELECT CAST('<t>' + REPLACE(s.run_times_explicit, ',', '</t><t>') + '</t>' AS XML) AS xdoc) d
    CROSS APPLY d.xdoc.nodes('/t') x(n)
    CROSS APPLY (SELECT CAST(LTRIM(RTRIM(x.n.value('.', 'VARCHAR(10)'))) AS TIME) AS fire_time) ft
    WHERE s.run_times_explicit IS NOT NULL
      AND s.run_times_explicit <> ''
),
LiveParents AS (
    SELECT run_id, dispatcher_name,
           DATEPART(HOUR, source_insert_dttm) * 60 + DATEPART(MINUTE, source_insert_dttm) AS parent_mod
    FROM B2B.INT_PipelineTracking
    WHERE parent_id IS NULL
      AND seq_id IS NULL
      AND (process_type IS NULL OR process_type <> 'CORE_PROCESS')
      AND dispatcher_name IS NOT NULL
      AND source_insert_dttm >= @LiveBoundary
      AND dispatcher_name IN (SELECT DISTINCT actual_d FROM Pairs)
),
CandLags AS (
    SELECT lp.run_id,
           lp.dispatcher_name AS actual_dispatcher,
           cd.cand_d          AS candidate,
           MIN((lp.parent_mod - ft.fire_mod + 1440) % 1440) AS best_lag
    FROM LiveParents lp
    INNER JOIN Candidates cd
            ON cd.actual_d = lp.dispatcher_name
    INNER JOIN FireTimes ft
            ON ft.service_name = cd.cand_d
    GROUP BY lp.run_id, lp.dispatcher_name, cd.cand_d, lp.parent_mod
),
Scored AS (
    SELECT *,
           MIN(best_lag) OVER (PARTITION BY run_id) AS min_lag
    FROM CandLags
),
Verdicts AS (
    SELECT run_id,
           actual_dispatcher,
           MAX(CASE WHEN best_lag = min_lag THEN candidate END)  AS picked_dispatcher,
           SUM(CASE WHEN best_lag = min_lag THEN 1 ELSE 0 END)   AS tied_candidates,
           MIN(min_lag)                                          AS min_lag
    FROM Scored
    GROUP BY run_id, actual_dispatcher
)
SELECT CASE
           WHEN tied_candidates > 1                      THEN '3-TIE'
           WHEN picked_dispatcher = actual_dispatcher    THEN '1-CORRECT'
           ELSE                                               '2-INCORRECT'
       END AS verdict,
       COUNT(*) AS runs
FROM Verdicts
GROUP BY CASE
           WHEN tied_candidates > 1                      THEN '3-TIE'
           WHEN picked_dispatcher = actual_dispatcher    THEN '1-CORRECT'
           ELSE                                               '2-INCORRECT'
       END
ORDER BY verdict;

-- Same validation broken out by the true dispatcher, to see which families
-- separate cleanly and which do not.
WITH ConflictParents AS (
    SELECT p.run_id
    FROM B2B.INT_PipelineTracking p
    INNER JOIN B2B.INT_PipelineTracking c
            ON c.parent_id = p.run_id
           AND c.dispatcher_name IS NOT NULL
           AND c.dispatcher_name <> 'FA_CLIENTS_GET_LIST'
    WHERE p.dispatcher_name IS NULL
      AND p.parent_id IS NULL
      AND p.seq_id IS NULL
      AND (p.process_type IS NULL OR p.process_type <> 'CORE_PROCESS')
    GROUP BY p.run_id
    HAVING COUNT(DISTINCT c.dispatcher_name) > 1
),
ConflictChildren AS (
    SELECT c.parent_id, c.dispatcher_name
    FROM ConflictParents cp
    INNER JOIN B2B.INT_PipelineTracking c
            ON c.parent_id = cp.run_id
    WHERE c.dispatcher_name IS NOT NULL
      AND c.dispatcher_name <> 'FA_CLIENTS_GET_LIST'
),
Pairs AS (
    SELECT DISTINCT a.dispatcher_name AS actual_d, b.dispatcher_name AS cand_d
    FROM ConflictChildren a
    INNER JOIN ConflictChildren b
            ON b.parent_id = a.parent_id
           AND b.dispatcher_name <> a.dispatcher_name
),
Candidates AS (
    SELECT actual_d, cand_d FROM Pairs
    UNION
    SELECT DISTINCT actual_d, actual_d FROM Pairs
),
FireTimes AS (
    SELECT s.service_name,
           DATEPART(HOUR, ft.fire_time) * 60 + DATEPART(MINUTE, ft.fire_time) AS fire_mod
    FROM B2B.SI_ScheduleRegistry s
    CROSS APPLY (SELECT CAST('<t>' + REPLACE(s.run_times_explicit, ',', '</t><t>') + '</t>' AS XML) AS xdoc) d
    CROSS APPLY d.xdoc.nodes('/t') x(n)
    CROSS APPLY (SELECT CAST(LTRIM(RTRIM(x.n.value('.', 'VARCHAR(10)'))) AS TIME) AS fire_time) ft
    WHERE s.run_times_explicit IS NOT NULL
      AND s.run_times_explicit <> ''
),
LiveParents AS (
    SELECT run_id, dispatcher_name,
           DATEPART(HOUR, source_insert_dttm) * 60 + DATEPART(MINUTE, source_insert_dttm) AS parent_mod
    FROM B2B.INT_PipelineTracking
    WHERE parent_id IS NULL
      AND seq_id IS NULL
      AND (process_type IS NULL OR process_type <> 'CORE_PROCESS')
      AND dispatcher_name IS NOT NULL
      AND source_insert_dttm >= @LiveBoundary
      AND dispatcher_name IN (SELECT DISTINCT actual_d FROM Pairs)
),
CandLags AS (
    SELECT lp.run_id,
           lp.dispatcher_name AS actual_dispatcher,
           cd.cand_d          AS candidate,
           MIN((lp.parent_mod - ft.fire_mod + 1440) % 1440) AS best_lag
    FROM LiveParents lp
    INNER JOIN Candidates cd
            ON cd.actual_d = lp.dispatcher_name
    INNER JOIN FireTimes ft
            ON ft.service_name = cd.cand_d
    GROUP BY lp.run_id, lp.dispatcher_name, cd.cand_d, lp.parent_mod
),
Scored AS (
    SELECT *,
           MIN(best_lag) OVER (PARTITION BY run_id) AS min_lag
    FROM CandLags
),
Verdicts AS (
    SELECT run_id,
           actual_dispatcher,
           MAX(CASE WHEN best_lag = min_lag THEN candidate END)  AS picked_dispatcher,
           SUM(CASE WHEN best_lag = min_lag THEN 1 ELSE 0 END)   AS tied_candidates
    FROM Scored
    GROUP BY run_id, actual_dispatcher
)
SELECT actual_dispatcher,
       COUNT(*)                                                              AS runs,
       SUM(CASE WHEN tied_candidates = 1
                 AND picked_dispatcher = actual_dispatcher THEN 1 ELSE 0 END) AS correct,
       SUM(CASE WHEN tied_candidates = 1
                 AND picked_dispatcher <> actual_dispatcher THEN 1 ELSE 0 END) AS incorrect,
       SUM(CASE WHEN tied_candidates > 1 THEN 1 ELSE 0 END)                   AS ties
FROM Verdicts
GROUP BY actual_dispatcher
ORDER BY actual_dispatcher;

/* ============================================================================
   Step 09 -- Child-Fault Silent Coverage Gap: sweep + tracker discriminator
   Read-only, no writes anywhere. Step through by section.

   Purpose:
     1. Sweep b2bi WORKFLOW_CONTEXT for failed steps (BASIC_STATUS = 1) over the
        recent window, naming the workflow definition for each.
     2. Take the distinct failed instance ids the sweep returns and check each
        against BOTH tracking surfaces (Integration BATCH_STATUS and the mirror
        B2B.INT_PipelineTracking) to see which failures are recorded and which
        are not.

   Window note: the sweep looks back five days, but b2bi holds only ~48 hours of
   data live in its primary tables, so the returned rows span roughly two days.
   The five-day lookback is deliberately wide to be sure nothing available was
   missed. The history / _RESTORE equivalents were not queried here and may hold
   more. Run the check at least every couple of days.
   ============================================================================ */

/* ============================================================================
   SECTION 1 -- WORKFLOW_CONTEXT failed-step sweep (the interim daily check)
   Every failed step (BASIC_STATUS = 1) in the window, with the workflow
   definition name. WFD is deduplicated to one row per (WFD_ID, NAME) so the
   join does not multiply across version history.
   ============================================================================ */

SELECT WFD.NAME, WC.WORKFLOW_ID, WC.SERVICE_NAME, WC.START_TIME
FROM b2bi.dbo.WORKFLOW_CONTEXT WC
JOIN (SELECT WFD_ID, NAME FROM b2bi.dbo.WFD GROUP BY WFD_ID, NAME) WFD
  ON WFD.WFD_ID = WC.WFD_ID
WHERE WC.BASIC_STATUS = 1
  AND WC.START_TIME >= DATEADD(DAY, -5, GETDATE())
ORDER BY WC.START_TIME DESC;

/* ============================================================================
   SECTION 2 -- Tracker discriminator
   The distinct failed instance ids from Section 1, tagged by family, checked
   against both tracking surfaces. src_status is the Integration BATCH_STATUS
   value; status_classification is the mirror's classification. NULL/NULL on
   both sides = the failure is untracked (silent).
   ============================================================================ */

SELECT s.WORKFLOW_ID, s.family, t.BATCH_STATUS AS src_status, p.status_classification
FROM (VALUES
  (8651738,'MAIN-inline'),(8652033,'MAIN-inline'),(8651660,'MAIN-inline'),(8651808,'MAIN-inline'),
  (8644331,'MAIN-inline'),(8644454,'MAIN-inline'),(8643690,'MAIN-inline'),(8643242,'MAIN-inline'),(8639052,'MAIN-inline'),
  (8652186,'VITAL'),(8652125,'VITAL'),(8650911,'VITAL'),(8644971,'VITAL'),(8644854,'VITAL'),
  (8643625,'VITAL'),(8636965,'VITAL'),(8636856,'VITAL'),(8636114,'VITAL'),(8633697,'VITAL'),(8631918,'VITAL'),
  (8651070,'ENCOUNTER'),(8648628,'ENCOUNTER'),(8642940,'GET_LIST')
) s(WORKFLOW_ID, family)
LEFT JOIN Integration.ETL.tbl_B2B_CLIENTS_BATCH_STATUS t ON t.RUN_ID = s.WORKFLOW_ID
LEFT JOIN xFACts.B2B.INT_PipelineTracking p ON p.run_id = s.WORKFLOW_ID
ORDER BY s.family, s.WORKFLOW_ID;

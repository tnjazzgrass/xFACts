# CC File Format Initiative — Session 28 Summary

**Focus:** Full migration of the **Index Maintenance** page (component `ServerOps.Index`) to the cc-shared model and CC spec conformance. All four source files converted, deployed, live-tested, and drift-cleaned to the expected residual set.

---

## 1. What was done

The Index Maintenance page's four source files were fully migrated and are deployed and functioning:

- `index-maintenance.css`
- `IndexMaintenance.ps1` (page route)
- `index-maintenance.js`
- `IndexMaintenance-API.ps1` (API route)

The page renders and functions identically to its pre-migration state, with one cosmetic item knowingly deferred (schedule slideout, see §4).

### Final drift (post-fix run)

| File | Total | Compliant | Non-compliant |
|------|-------|-----------|---------------|
| index-maintenance.css | 357 | 357 | 0 |
| index-maintenance.js | 571 | 571 | 0 |
| IndexMaintenance-API.ps1 | 157 | 157 | 0 |
| IndexMaintenance.ps1 | 249 | 242 | 7 |

All 7 remaining rows are expected (see §3). CSS, JS, and API are fully clean.

---

## 2. Notable conversions

### 2.1 API data-access conversion (raw ADO → CCShared)

This was the first endpoint file taken fully off hand-rolled ADO onto the shared data-access helpers. All 15 endpoints converted:

- Listener reads → `Invoke-XFActsQuery -Query -Parameters` (returns an ArrayList of column-keyed hashtables — the same shape the old code built by hand, so `$row['col']` access and `-is [DBNull]` checks carried over unchanged).
- Listener writes → `Invoke-XFActsNonQuery -Query -Parameters -TimeoutSeconds`.
- `ExecuteScalar` cases → `Invoke-XFActsQuery` reading `[0]` of the first row.
- All string-interpolated datetime/threshold/run-id values → `@param` placeholders with `-Parameters @{}`.
- Dynamic column identifiers (`hrNN`, holiday SET clause) → preserved as validated identifier interpolation (cannot parameterize an identifier; validated 0–23 first).

The file shrank ~300 lines. Verified non-destructive: endpoint set byte-for-byte identical (15→15, same paths/methods), every `[PSCustomObject]` response shape preserved field-for-field. The shrink is entirely connection/adapter/dataset boilerplate absorbed by the wrappers, no logic lost.

### 2.2 Two endpoints with genuinely changed data-access shape

- **`active-execution`** queries live session DMVs on *each maintenance server's own `master`* — arbitrary per-server targets, not the AG. No CCShared wrapper fits that (`Invoke-AGReadQuery` routes to the AG secondary via the listener, which is the wrong instance). So that single query uses raw `Invoke-Sqlcmd -ServerInstance $serverName -Database master -TrustServerCertificate -ApplicationName 'xFACts Control Center' -QueryTimeout 10` — spec-permitted (the populator only requires TrustServerCertificate + ApplicationName on raw `Invoke-Sqlcmd`). Its result rows use `$row.Property` access (DataRow), correct for that path.
- **`update-batch`** was restructured from a per-row `BeginTransaction`/`Commit`/`Rollback` loop on a shared connection into a single batched `SET XACT_ABORT ON; BEGIN TRANSACTION; <N parameterized UPDATEs>; COMMIT;` statement sent in one `Invoke-XFActsNonQuery` call (the wrapper opens/closes its own connection per call, so a shared cross-loop transaction isn't possible). Atomicity preserved, one round trip.

These two are the only spots where a behavioral difference could hide; worth a deliberate test when EXECUTE actually runs and when drag-selecting a batch of schedule cells.

### 2.3 Admin launch gating (server-side)

The legacy page set `window.isAdmin` via an inline `<script>`, which the HTML spec forbids and cc-shared.js doesn't provide. Resolved server-side: `/api/index/process-status` calls `Get-UserContext -WebEvent $WebEvent`, reads `.IsAdmin`, and includes a per-process `CanLaunch` boolean in the JSON. The JS draws the in-card launch badge only when `CanLaunch` is true; it never references `window.isAdmin`. The `launch-process` endpoint keeps `Test-ActionEndpoint` as the real security guard. Refinable later to "admin OR specific grant" server-side with no JS change.

---

## 3. Drift disposition (the 7 route rows — all expected)

**Migration-window constants (2 rows) — clear at end-of-migration:**
- `MISSING_RBAC_CHECK_PAGE` and `MISPLACED_IMPORT`. Both arise because the per-route CCShared import block is the first statement of the page-route scriptblock (see §5.1). These are the constant 2-row drift signature on *every* page during the migration window. They clear when `Start-ControlCenter.ps1` switches to loading CCShared natively and the per-route import is removed from every route file.

**Engine-card rows (5 rows) — clear when placeholder processes go live:**
- `ENGINE_CARD_ORDER_MISMATCH` (1) + `ENGINE_SLUG_REGISTRY_MISMATCH` (4, one per card).
- Root cause: the four placeholder processes in `Orchestrator.ProcessRegistry` are `run_mode=0`, and the populator's engine checks filter to `run_mode=1`. So the populator builds its "expected" engine-card set from a filtered-empty view of the registry, and the four real cards (sync/scan/execute/stats, in cc_sort_order 1–4) cannot match. This is a *registration-state* artifact, **not** a markup ordering defect — the cards are in correct order.
- These clear when the placeholder processes are flipped to `run_mode=1`. **Deliberately not done this session:** run_mode=1 makes the heartbeat execute the scripts, and these must not run unattended yet.

No row in the residual set is a real markup, logic, or data-access defect.

---

## 4. Visual fixes applied during live test

The first deploy rendered with several visual problems, all fixed in a follow-up pass (CSS + JS; API unchanged):

- **Duplicated process cards + missing launch badges:** root cause was an invalid nested `<button>` inside `<button>` (card was a button, launch badge a nested button), which the browser fragments. Fixed via Option A: card is now a `<div class="idx-process-card">` (position: relative) containing a full-cover transparent `<button class="idx-process-card-hit">` for the click-to-open, with the launch badge as a sibling `<button>` layered above (z-index). Exact UX preserved; the in-card admin badge design is retained.
- **White background on the queue empty-state block and the calendar icon:** these became `<button>` elements for spec conformance and inherited the browser's default button background/border. Fixed with button-resets (`background: none; border: none; font-family: inherit`, etc.) on `idx-clickable`, `idx-schedule-icon`, and the new hit button.

**Deferred (not a defect):** the schedule slideout renders as a full-page slide rather than a compact panel. Functionally correct. Being deliberately deferred — to be converted to a centered `cc-xwide` modal (swap `cc-slide-overlay`/`cc-dialog-slide` → `cc-modal-overlay`/`cc-dialog-modal` on that one overlay) and bundled with other Index Maintenance page edits planned later.

---

## 5. Key learnings to bank

### 5.1 Per-route CCShared import is mandatory on page routes during migration
`Start-ControlCenter.ps1` currently auto-loads the legacy `xFACts-Helpers.psm1` at startup. The legacy module's chrome helpers emit old-prefix classes, and it lacks `Get-ChromeBannersHtml` entirely. So every migrated **page route** must, as its first statement, `Import-Module -Name '...xFACts-CCShared.psm1' -Force -DisableNameChecking` to override Helpers for that route's chrome emission. Omitting it 500s the page (the original 500 this session). **Page routes only** — API routes emit no chrome and do not get the import (their `Get-UserContext`/`Test-ActionEndpoint` calls resolve equivalently in both modules). This import is the source of the constant 2-row drift per page and is removed from all route files at end-of-migration. This is an environment/loading-model fact, not visible in the specs or helper signatures.

### 5.2 Big-shrink verification discipline (standing practice)
On any file that drops significantly in size, verify nothing was dropped by diffing the *inventory* that would change if something were omitted — not the line count. For a route/API file that's the endpoint set (paths + methods) and the response-object shapes; for a module it's the function/export list; for a spec it's the section banners. Line count is a smoke alarm, not a proof. This is now a standing part of delivery on any significant shrink.

### 5.3 `Invoke-AGReadQuery` is listener-secondary only
It routes to the AG secondary replica via the listener for AG-hosted databases. It is **not** usable for querying an arbitrary remote server's DMVs (e.g. per-maintenance-server `sys.dm_exec_query_profiles`). That case requires raw `Invoke-Sqlcmd -ServerInstance` with TrustServerCertificate + ApplicationName.

### 5.4 CCShared SQL surface (confirmed)
`Invoke-XFActsQuery -Query -Parameters` → ArrayList of column-keyed hashtables; `Invoke-XFActsNonQuery -Query -Parameters -TimeoutSeconds` → rows affected; `Invoke-XFActsProc`; `Invoke-AGReadQuery -Database -Query`; `Get-UserContext -WebEvent` returns `.IsAdmin`; `Get-ChromeBannersHtml` (no params, pure string builder, exists only in CCShared). All confirmed exported.

---

## 6. Next session — DM Operations (named candidate)

**Next refactor target: the DM Operations page.** It is the only other outlier left — standalone scripts not yet orchestrated, needs manual launch buttons added to the UI, same profile as Index Maintenance. Every other CC page already has full orchestration.

### 6.1 Admin launch port (the carry-forward "fresh" item)
DM Operations gets the same admin manual-launch functionality Index Maintenance now has. **Model it on Index's launch flow**, added as the *last* step of DM Operations' own refactor (not grafted onto the unrefactored page, which would create conformant islands in non-conformant files and muddy the drift signal). The four pieces:
1. API `launch-process` endpoint: `Test-ActionEndpoint` first line, script-name map, `Start-Process` with `-WindowStyle Hidden`, JSON response.
2. `CanLaunch = [bool]$ctx.IsAdmin` added to the process-status (or equivalent) endpoint via `Get-UserContext`.
3. JS: in-card admin launch badge rendered only when `CanLaunch` is true; confirm-modal flow on click.
4. CSS: the launch-badge styling (and button-reset if the badge/card click targets are buttons).

### 6.2 ProcessRegistry placeholders
DM Operations' standalone scripts are being registered in `Orchestrator.ProcessRegistry` now (run_mode=0, same pattern as Index process_id 24–27). This means DM Operations' engine cards will exhibit the same 5-ish expected engine-card drift rows until the processes go live — known and benign. **At session start, provide the assigned `cc_engine_slug` / `cc_sort_order` / `cc_page_route` values** for the DM Operations placeholders, so the engine cards' slugs and order are written to match the registry exactly (keeps card-order drift to the transient run_mode=0 kind, not a real mismatch).

---

## 7. Other carry-forwards (pushed, not urgent)

- **Engine-card enforcement gap:** a `run_mode=1` process registered to a page with no corresponding card / ENGINE_PROCESSES entry should fire drift (Option 3 — card validity keyed off cc_* columns, not run_mode). Design depends on the still-undesigned orchestration pattern. Less pressing now that the catalog already flags the inverse (cards referencing not-yet-live processes), so the gap is visible in the table today. Circle back after the outlier pages are migrated.
- **Index Maintenance schedule slideout → centered cc-xwide modal**, bundled with other planned Index edits (see §4).
- **Index placeholder processes → run_mode=1** flip clears the 5 engine rows — do only when ready for the orchestrator to run them unattended.
- **Doc staleness:** `xFACts_Development_Guidelines.md` (§3.6) and `xFACts_Platform_Registry.md` still list `xFACts-Helpers.psm1` as the CC shared module; should be updated to CCShared at end-of-migration when the swap is real.

---

## 8. Cross-references

- `CC_Session_Summary_27.md` — predecessor; overlay-close consistency pass across the five then-migrated pages, spec amendments (HTML §5.4, JS §11.5, PS §11.1 canonical form incl. the Test-ActionEndpoint guard form).
- `CC_PS_Spec.md` — §11 routes (page-route `Get-UserAccess`-first / `Write-PodeHtmlResponse`-last; api-route `Test-ActionEndpoint`-first / `Write-PodeJsonResponse`-last; §12 SQL here-strings; raw `Invoke-Sqlcmd` requires `-TrustServerCertificate` + `-ApplicationName`).
- `CC_HTML_Spec.md` — body shell attrs, page-shell whitespace rule, §5.4 overlays, §7.5 action-attribute placement.
- `CC_CSS_Spec.md` — per-class and per-`@media`-internal-class purpose comments, state-on-element, no descendant/depth-3 selectors.
- `CC_JS_Spec.md` — banner order, `idx_init` sole INITIALIZATION content, prefix rules, §11.5 overlay handlers.
- `xFACts_Platform_Registry.md` — `ServerOps.Index` component (source of truth for classification).

---

*End of Session 28. Index Maintenance is fully migrated and functioning; residual drift is entirely expected (2 migration-window + 5 engine-registration rows). Next session: DM Operations — the last orchestration-outlier page — migrated the same way, with the admin launch port modeled on Index Maintenance as the final step. Provide the DM Operations ProcessRegistry cc_engine_slug / cc_sort_order / cc_page_route values at session start.*

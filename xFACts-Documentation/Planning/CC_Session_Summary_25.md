# CC Session Summary 25 -- Client Relations Migration, API Shim Convention, and Platform Registry Export Enhancement

*Session date: 2026-06-02.*

---

## Session focus

Continuation of the page-by-page CC File Format migration. This session completed the **Client Relations** departmental page (all four files), corrected and verified the API-route module-import convention, and enhanced the documentation pipeline's Platform Registry export to close a metadata gap. **Business Services** was started but deliberately deferred to keep its four files aligned in a single pass (see carry-forward). Client Relations is deployed and confirmed working.

This is the natural boundary between the spec-copy pages (Client Relations was the second-to-last; Business Services is the last page with `-spec.css`/`-spec.js` reference copies) and the full-refactor pages that follow. Everything after Business Services is a from-scratch refactor of an existing page with no spec-base copy to lean on.

---

## What landed

### 1. Client Relations page -- full migration (DEPLOYED, working)

All four files refactored to the four-spec format and deployed together. Component `DeptOps.ClientRelations`; `cc_prefix = clr`; `section_key = departmental`; route `/departmental/client-relations`; slug `client-relations`; body class `cc-section-departmental`. No registered orchestrator processes -> no engine cards, empty engine row omitted entirely. Page serves a heavy non-performant Reg F queue from a page-level cache.

- **client-relations.css** -- ~451 lines, LF, no BOM, pure ASCII. Built from the spec-base copy. Main systematic fix: compound-modifier pattern per CSS spec Section 7.1 (every modifier token `clr-`-prefixed with its own standalone definition; compound rule only for genuine intersections). Em-dashes in comments converted to ASCII `--` (the spec-base carried them; the encoding standard requires pure ASCII for `.css` too -- caught late, worth remembering for Business Services).
- **client-relations.js** -- 784 lines, LF, node --check passed. Structural rewrite from the superseded engine-events.js contract to the current cc-shared.js bootloader contract. Contract identifiers resolved by computed name on `window` are `var`-declared and `clr_`-prefixed. Removed the page-local connection-error banner (superseded chrome -- cc-shared owns `cc-connection-banner`). Cache indicator moved out of the header into the content area (Option A) as page-local `clr-cache-indicator`; header uses the standard chrome refresh row.
- **ClientRelations.ps1** (page route) -- CRLF, comment-based-help header, `CHANGELOG: CHANGE HISTORY` + `ROUTE: PAGE PATH` banners. Carries the transitional `Import-Module xFACts-CCShared` shim as the first scriptblock statement.
- **ClientRelations-API.ps1** (API route) -- CRLF. Comment-based-help header, `ROUTE: API ENDPOINTS` banner only. The Reg F CTE query preserved exactly. See the convention correction below.

### 2. API-route module-import convention -- corrected and verified

The first delivery of `ClientRelations-API.ps1` wrongly carried the `Import-Module xFACts-CCShared` shim and a `CHANGELOG` section. Both were corrected after the drift report and a verification pass. The settled, verified conventions:

- **Page routes carry the shim; API routes do not.** The page route needs it because the chrome-emission helpers (`Get-NavBarHtml`, `Get-PageHeaderHtml`, `Get-ChromeBannersHtml`) must come from the *new* module to emit `cc-` prefixed classes. The API route emits no chrome; its helpers (`Test-ActionEndpoint`, `Get-CachedResult`, `Invoke-CRS5ReadQuery`) exist with identical behavior in *both* the old `xFACts-Helpers.psm1` (startup-loaded) and the new `xFACts-CCShared.psm1`, so a shimless API route resolves them correctly from the startup-loaded old module. Verified from both modules' source: `xFACts-CCShared.psm1` is a documented drop-in superset successor that contains every helper both route types use.
- **Pode scope mechanic (verified/reasoned):** an `Import-Module` inside one route's scriptblock does NOT leak into a sibling route's scriptblock -- separate `Add-PodeRoute` registrations, separate execution scopes, separate requests. So the page route's shim does not reach the API route's execution; a shimless API route resolves helpers from the startup module.
- **api-route role permits ONLY the `ROUTE` section.** No `CHANGELOG` section in API files (drift: `UNKNOWN_SECTION_TYPE`, with consequent `FILE_ORG_MISMATCH`). Page-route role permits `CHANGELOG` + `ROUTE`. With no shim, `Test-ActionEndpoint` is the genuine first statement and no displaced-RBAC drift occurs.

**Process lesson (recorded plainly):** I added the shim to the API file reasoning from a "every route emits 2 drift rows" expectation rather than verifying the established convention on the already-refactored API files. The working precedent was right there. When a working precedent exists, verify against it first -- don't reason from a count.

### 3. Expected/known drift (per-page, transitional)

- **Page route** emits exactly **2 transitional drift rows** from the shim: `MISSING_RBAC_CHECK_PAGE` (the import displaces `Get-UserAccess` from literal-first) plus the import statement in the ROUTE section. Both clear at module cutover.
- **API route** carries no shim -> clean (no transitional rows), matching the other refactored API files.
- CSS and JS clean.
- **Cutover:** when the last page migrates, `xFACts-Helpers.psm1` is deleted, `Start-ControlCenter.ps1` is switched to load `xFACts-CCShared.psm1` at startup, and every page route's shim line is removed. The old module is still startup-loaded today because unmigrated pages depend on it.

### 4. Platform Registry export enhancement (doc pipeline)

Closed the gap that forced manual prefix/section_key supply this session: the Platform Registry export did not include `cc_prefix`, and lacked the nav and process registry content. The export is the `$TableExports` array in the "Generate Platform Registry" / "Reference Table Export" step, present in **both** `Publish-GitHubRepository.ps1` (GitHub, uses `Get-SqlData`) and `Consolidate-UploadFiles.ps1` (local backup, uses `Invoke-Sqlcmd`). The four original queries are byte-identical between the two scripts (verified); the surrounding plumbing differs, so only the array literal is shared.

Deliverable: `TableExports-block.ps1` -- the six-entry replacement array, drop-in for both scripts in place of the existing four-entry `$TableExports = @( ... )`. Nothing else in either step changes; the generic rendering loop auto-derives columns and picks up the new columns/tables.

Changes (all column names verified against live row data the user supplied -- no guesses):
- **Component Registry**: added `cc_prefix` (after `description`) and `doc_cc_slug` (with the doc columns).
- **Nav Registry** (new): `page_route, nav_label, display_title, description, section_key, sort_order, doc_page_id, show_in_nav, show_on_home` from `dbo.RBAC_NavRegistry WHERE is_active = 1` ORDER BY `section_key, sort_order, page_route`. Curated: dropped `nav_id` + audit columns.
- **Process Registry** (new): `module_name, process_name, description, script_path, procedure_name, execution_mode, dependency_group, interval_seconds, scheduled_time, timeout_seconds, run_mode, allow_concurrent, cc_engine_slug, cc_engine_label, cc_page_route, cc_sort_order` from `Orchestrator.ProcessRegistry` ORDER BY `dependency_group, module_name, process_name`. Curated: dropped `process_id`, the volatile runtime columns (`running_count`, `last_execution_*`, `last_duration_ms`, `last_successful_date` -- would churn the doc every scheduler cycle), and audit columns. **No `is_active` filter** -- the table has no `is_active` column (would throw if added).

Status: delivered as the array block; NOT yet applied to either script by the user. Apply identically to both, then regenerate.

---

## Carry-forward

### 1. Business Services -- finish the full four-file migration in one session (HIGH -- next session lead)

Started this session, deliberately not built, to avoid splitting four-file alignment across sessions (the cross-session seam is where alignment breaks). It is the **last** page with `-spec.css`/`-spec.js` reference copies. All five source files are available (uploaded this session or fetchable): current + spec-base CSS and JS, the page route (fetched), and the API route (uploaded). `cc-shared.css/js/psm1` already verified this session.

Component `DeptOps.BusinessServices`; `cc_prefix = bsv`; route `/departmental/business-services`; section `departmental`. **Uses the standard chrome refresh row -- NO header cache-indicator customization** (that was Client Relations-specific).

Page is heavier than Client Relations:
- **Two engine cards** (Collect, Distribute) -> a real `cc-engine-row` with two `cc-card-engine` blocks. Preserve the spec-mandated forms: `cc-engine-bar cc-disabled` (the `disabled` modifier is `cc-`-prefixed in the compound) and the `&nbsp;` countdown content (`cc-engine-cd`). These are explicitly spec-mandated -- do not "fix" them.
- **A slideout** (`slideout`/`slideout-backdrop`) -> `cc-slide-overlay` + `cc-dialog cc-dialog-slide`.
- **A modal** (`detail-modal` / `modal-overlay hidden` / `modal-dialog modal-wide`) -> `cc-modal-overlay cc-hidden` / `cc-dialog cc-dialog-modal cc-wide`.
- Flip cards, a two-column `top-row` layout, group filter badges, a year/month/day history tree -- all page-local `bsv-` content.
- Multiple inline `onclick` (`pageRefresh()`, `closeSlideout()` x2, `closeDetailModal()`) -> `data-action-click` dispatch. `pageRefresh` -> chrome `cc-page-refresh`; the others -> `bsv-`-prefixed page-local dispatch keys.

**CSS specifics (analysis already done this session):**
- The spec-base CSS is the right foundation (bsv- prefixed, tokenized, chrome stripped). The current `business-services.css` is the genuinely old pre-refactor file -- ignore it as a source, use the spec-base.
- The one systematic fix is the Section 7.1 compound-modifier pattern. The exact list of unprefixed modifier tokens to convert to standalone `bsv-` definitions: `card-warning`, `card-critical`, `flipped`, `user-high`, `user-full`, `active`, `completed`. Genuine intersections that keep a compound rule: `.bsv-flip-card-front.bsv-flipped` / `.bsv-flip-card-back.bsv-flipped` (different transforms per face), `.bsv-dist-user-name.bsv-user-high/full` and `.bsv-dist-user-bar-fill.bsv-user-high/full` (different properties per parent), `.bsv-group-badge.bsv-active`, `.bsv-year-stat.bsv-completed`.
- `bsv-section-body` is legitimately page-local (cc-shared has no `cc-section-body`).
- Spec-base CSS has ~30 em-dashes in comments -> convert to ASCII `--`.

**JS specifics:** expect the same superseded engine-events-contract problem Client Relations had -> structural rewrite to the cc-shared.js bootloader contract, not just prefix fixes. This page has two engine cards, so `bsv_ENGINE_PROCESSES` (var, window-scoped) is real here, plus `cc_connectEngineEvents()`.

**JS spec authority reminder:** the `-spec.js` copies were written against superseded decisions; validate against the current specs and cc-shared contracts, not the spec-base.

### 2. Apply the Platform Registry export block (LOW -- mechanical)

`TableExports-block.ps1` (delivered this session) replaces the four-entry `$TableExports` array in BOTH `Publish-GitHubRepository.ps1` and `Consolidate-UploadFiles.ps1`. Apply identically, regenerate. After that, `cc_prefix`/`section_key`/nav/process data is in `xFACts_Platform_Registry.md` -- future pages read prefix and section wiring from the doc instead of asking.

### 3. Full-refactor pages (after Business Services)

Everything after Business Services has no spec-base copy. The approach changes: refactor the existing page directly against the four specs and cc-shared contracts. Worth a brief planning pass at the start of that phase -- how to sequence, what to watch for without a spec-base to diff against.

---

## Verified conventions (reference)

- **Encoding (Dev Guidelines 2.6.2b):** UTF-8 no BOM, pure ASCII (plain hyphens not em-dashes, `--` not em-dash, `...` not ellipsis, ASCII arrows). CRLF for `.ps1`/`.psm1`; LF for `.css`/`.js`. Trailing newline. `Section ` not the section symbol in source.
- **Shim:** page routes only; first scriptblock statement; `Import-Module -Name 'E:\xFACts-ControlCenter\scripts\modules\xFACts-CCShared.psm1' -Force -DisableNameChecking`. API routes: no shim, `Test-ActionEndpoint` first.
- **Section types by role:** page-route permits CHANGELOG + ROUTE; api-route permits ROUTE only.
- **Spec is the sole authority.** No page is a template. Spec-base copies show prior intent, not current truth. Questions only on genuine spec ambiguity. Verify column/identifier names against source -- never guess.
- **GitHub manifest:** `https://raw.githubusercontent.com/tnjazzgrass/xFACts/main/manifest.json?v=<n>` -> sub-manifest `manifest-cc-app.json` -> exact `raw_url` per file. Don't retry failed fetches to the same domain (account-scoped rate limit). Uploaded files are leaner than fetches when context is tight.

## State at session end

Client Relations deployed and working (4 files). API shim convention corrected and verified against module source + Pode scope mechanics. Platform Registry export block delivered (not yet applied). Business Services deferred whole to next session with full breadcrumbs above. Clean entry point: next session leads with the complete Business Services four-file migration in one pass.

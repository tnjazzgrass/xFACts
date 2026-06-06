# CC Session Summary 37 — BDL Import Page Migration

## 1. Session focus

CC File Format Initiative, page migration thread. Target: the **BDL Import**
page (component `Tools.BDLImport`, cc_prefix `bdl`, route `/bdl-import`, body
section `cc-section-tools`). All four files refactored to the four CC specs,
deployed, visually verified against pre-refactor behavior, and drift-cleaned to
the expected end-of-migration floor.

This session was a clean reboot of an earlier BDL attempt that had gone off the
rails. The page-per-session cadence holds: BDL Import is done. **Three CC pages
remain: Client Portal, Platform Monitoring, Admin.** After those three, the
Control Center migration is complete and legacy shared content can be retired.

---

## 2. What was delivered

Four full drop-in replacements, exact production filenames, byte-disciplined
(pure ASCII, no BOM, PS + CSS CRLF, JS LF, single trailing newline, no trailing
whitespace):

- `BDLImport.ps1` — page route (~373 lines)
- `BDLImport-API.ps1` — API route, 23 endpoints (~2,612 lines)
- `bdl-import.js` — page module (~6,235 lines)
- `bdl-import.css` — page styles (~5,239 lines)

Build order held: route → API → CSS → JS (delivered CSS/JS first this session,
then route, then API, due to the reboot sequencing; final set is internally
consistent). BDL is a functional, destructive page (real DM data loads via the
BDL XML pipeline), so behavior preservation was the governing constraint
throughout.

### Refactor highlights

**Route (`BDLImport.ps1`).** CBH header (`.COMPONENT Tools.BDLImport` — the old
`ControlCenter.BDLImport` header value was stale; registry wins) + CHANGELOG +
single `ROUTE: PAGE PATH` banner. CCShared import shim as first statement
*inside* the route scriptblock, absolute path
(`E:\xFACts-ControlCenter\scripts\modules\xFACts-CCShared.psm1`),
`-Force -DisableNameChecking`. Body `cc-section-tools` /
`data-cc-page="bdl-import"` / `data-cc-prefix="bdl"`. Dropped engine-events
refs, the inline back-link script, and all `window.isAdmin` / `window.userTier`
/ `__IS_ADMIN__` / `__USER_TIER__` injection (admin gating now fully
server-side). Five static `cc-` overlay constructs in a contiguous block:
template preview slideout, save-template modal, prod-advisory, alignment,
promote-advisory.

**API (`BDLImport-API.ps1`).** CBH header + single `ROUTE: API ENDPOINTS` banner
(no CHANGELOG — forbidden in api-route; the 7 historical entries were preserved
in the S37 delivery notes, not in the file). `Test-ActionEndpoint` guard added
as the first statement of all 23 endpoints (was 0). All 52 box-drawing banners
and 47 `# ----` mini-banners removed/converted. One nested function
(`Get-SqlTypeFromMeta`) inlined at both call sites — matching the identical
switch already inlined in PATH B/C of the same endpoint. One raw-ADO poll loop
(per-server poll against `crs5_oltp.dbo.File_Registry` on a target DM instance)
converted to `Invoke-Sqlcmd` with `-TrustServerCertificate` +
`-ApplicationName 'xFACts Control Center'`, single-quoted here-string so the
`$(regId)` SQLCMD variable reaches the cmdlet literally. `can_delete` flag added
to templates GET (admin-tier, server-computed — matches original admin-only
delete UI). 80/80 original SQL here-strings preserved byte-for-byte; only the
poll query intentionally rewritten.

**CSS (`bdl-import.css`).** Full refactor + `CONTENT: INLINE-STYLE REPLACEMENTS`
addendum (39 page-local classes replacing former inline styles, tokens-where-
defined, original values replicated exactly). All forbidden selectors flattened
to state-on-element; no descendant/child/id/attribute selectors; compound depth
≤2.

**JS (`bdl-import.js`).** Revealing-module IIFE unwound to ~196 top-level
`bdl_`-prefixed functions; three dispatch tables (click/change/input), one
delegated listener each. Five-step wizard, validation/remediation, real DM-load
executor, alignment, promote, templates, import-history accordion. Shared
helpers used correctly (`cc_escapeHtml`, `cc_showAlert`/`cc_showConfirm`
Promise-form, `cc_engineFetch`, `cc_connectEngineEvents`).

---

## 3. Spec-forced corrections this session

- **§5.4 overlay verdict.** prod-advisory, alignment, and promote-advisory were
  initially built as dynamic JS overlays. The HTML spec requires defined,
  recurring overlays to be **static** route constructs; the dynamic pattern
  (§11.5.1) is for genuinely transient overlays only. Converted all three to
  static `cc-modal-overlay` constructs with §11.5.2 fill-body + toggle-`cc-hidden`
  handlers (guarded `(target,event)` close). field-info and entity-transition
  stay dynamic (genuinely transient — per-field payload; 1.5s auto-dismiss toast).
- **Overlay ID conformance.** Template overlay IDs renamed to the §5.4 form
  (`bdl-slideout-template-preview`, `bdl-modal-save-template`); inner title/body
  renamed to `bdl-template-preview-title/-body` to avoid the overlay-outer-ID
  pattern collision (BSV S26 precedent).
- **Action-on-non-interactive (§7.5).** 5 stepper `<div>` and 3 history `<span>`
  carrying `data-action-click` converted to `<button type="button">` with CSS
  UA-reset added to `.bdl-step`, `.bdl-history-chip`, `.bdl-history-toggle-btn`
  (background/border none, font/color/text-align inherit) so the visual is
  unchanged. The 5 remaining `data-action-click`-on-`<div>` are the overlay outer
  containers, allowed by §7.5.
- **CSS comment-convention split (reinforced).** base / `:root` / `@keyframes` /
  `@media` / pseudo-element (`::placeholder`) → **preceding** single-line purpose
  comment; pseudo-class and compound-state **variants** (`:focus`, `:hover`) →
  **inline** trailing `{ /* ... */` comment. Tripped this twice this session
  (first leaving `::placeholder` after `:focus` with inline comments, then
  over-correcting `:focus` to preceding-comment form). Both directions are drift.
- **Unresolved hook classes removed.** `bdl-entity-grid`, `bdl-btn-back`,
  `bdl-history-chip-env` were vestigial (id-hooks or functionless labels, no CSS
  definition, never selected) — removed rather than defined.

---

## 4. Deployment debugging

- **Header defaulting / old Helpers still loading.** First route deploy showed a
  defaulting header. Root cause: the delivered import line used
  `$PSScriptRoot\..\modules\...` (empty in Pode route runspaces — the JBoss S31
  trap) with `-ErrorAction SilentlyContinue` (swallowed the failed import) and
  `-Function Get-ChromeBannersHtml` (single-function import, so the other chrome
  helpers fell through to the legacy Helpers module). Fixed to the known-good
  convention: absolute path, `-Force -DisableNameChecking`, full-module import.
  **Lesson: the CCShared import shim is verbatim boilerplate from a deployed
  route — lift it exactly, never reconstruct from memory.**

---

## 5. Drift result

Pre-refactor non-compliant counts: 740 / 174 / 55 / 210 (css / js / api / route).
Post-refactor, after the cleanup passes:

- `bdl-import.css` — **0** (after fixing the placeholder ordering + variant-
  comment rounds)
- `bdl-import.js` — **0**
- `BDLImport-API.ps1` — **0**
- `BDLImport.ps1` — **2** (the known transitional `MISSING_RBAC_CHECK_PAGE` +
  `MISPLACED_IMPORT` from the CCShared shim; clears at end-of-migration cutover)

Populator runtime spiked ~2 min on one run, returned to the ~3 min norm on the
next — treated as a fluke.

---

## 6. The CSS/JS line-growth question (resolved with measurement)

BDL's files were unexpectedly large (JS 2,353 → 6,235; CSS 1,319 → 5,239),
prompting a "did this explode?" check. Measured decomposition of the JS growth:

- **+779 brace-only lines** (one-statement-per-line + brace-on-own-line) —
  the dominant contributor.
- **+225 comment lines** (per-function/section purpose comments).
- **+135 blank lines** (one-blank-between-constructs).
- IIFE unwrap added the `bdl_` prefixing (196 functions) but few *lines* — it's a
  character-level change, not a line multiplier.

Clinching number: **non-whitespace characters grew only 1.27×** (164,789 →
208,987) while line count grew 2.65×. So ~75% of the growth is spec-mandated
whitespace/formatting applied to an unusually dense original, not new code. The
real code mass grew ~27%, traceable to comments + data-action markup + `bdl_`
prefixes — all deliberate.

**Implication for the remaining pages (esp. Admin): line-count growth tracks how
densely the original was formatted, not how much logic the page has.** A page
already written one-statement-per-line will barely grow; a tightly-packed one
will balloon regardless of size. Do not treat a large post-refactor line count
as a red flag without the non-whitespace-character check.

---

## 7. Dead-code / orphan-detection investigation (exploratory; roadmap item)

Prompted by the BDL CSS bloat question. Investigated whether the asset catalog
can surface orphaned (defined-but-unused) content **today**, as a triage aid.

- **Finding:** yes, as a *triage* list for CSS classes, not a verdict. A
  definition with no usage is computable from existing rows, but runtime-built
  class names (`'bdl-foo-' + x`) never appear as literal usage rows and surface
  as false positives.
- **Critical schema fact:** a CSS class is *defined* in the `.css` file but
  *applied* in the route HTML and JS files, which carry **different**
  `object_registry_id` values (BDL: route 324, API 325, JS 326, CSS 327). The
  usage check must span all of a page's WebAsset files. Scope is resolved via
  `Component_Registry.cc_prefix` →
  `Object_Registry.component_name` (object_category = 'WebAsset').
- **Result for BDL:** 580 defined CSS classes → 105 orphan candidates → ~46 after
  source-absence + stem-suppression filtering, of which a genuine dead-CSS core
  exists (verified zero-trace: `bdl-exec-map-arrow`, `bdl-execute-mapping`,
  `bdl-validation-context`, `bdl-xml-value`, `bdl-fixed-value-banner`).
- **Deliverables (not yet in repo):** `orphan_candidates.sql` (cc_prefix-scoped,
  CSS-only, returns the candidate set for any page by prefix) and
  `DeadCode_Detection_Findings.md` (full funnel + the Tier-2 resolver-enhancement
  design).
- **Roadmap intent (not now):** build this as a complete cross-file check (CSS
  classes, JS functions, endpoints), authoritative rather than triage. That
  requires the resolver to record dynamic construction as a fact (emit a
  stem USAGE row with `has_dynamic_content=1` for `'bdl-foo-' + x`), then a new
  **advisory-severity** drift code (`UNUSED_CSS_CLASS` / `UNREFERENCED_FUNCTION` /
  `UNREFERENCED_ENDPOINT`) — kept separate from hard-fail codes because the
  false-positive floor from dynamic construction means a human must confirm
  before deletion. Likely needs populator updates + capture-time DDL.
- **BDL CSS cleanup itself is deferred** — a separate behavior-affecting pass, not
  part of the conformance work (which preserves 100% functionality).

---

## 8. CC File Format Initiative — overall status

- BDL Import migrated (this session). Previously migrated: Server Health, Batch
  Monitoring, Job Flow, File Monitoring, DBCC Operations, JBoss, all
  orchestration-outlier pages (DM Operations last), all departmental pages, all
  Server Operations pages, plus Replication, Index Maintenance, Backup,
  Applications & Integration.
- **Three CC pages remain: Client Portal, Platform Monitoring, Admin.** After
  these three, every CC page is migrated and the legacy-shared-content retirement
  can proceed.
- Going-forward cadence: one page per session. Remaining pages are full refactors
  against the four specs directly.
- Transitional per-page import shim (page routes only) produces the 2 known route
  drift rows that clear at end-of-migration.
- **Helper-module consolidation (the end goal):** delete `xFACts-Helpers.psm1`,
  remove the transitional `Import-Module` shim lines from every page route, update
  `Start-ControlCenter.ps1` to load CCShared at startup, delete
  `engine-events.css` / `engine-events.js`, and retire `Get-PageScriptTagHtml`
  (S35 §5). **Blocked until all three remaining pages are migrated.**

---

## 9. Carry-forward (open items)

### Page migration (primary thread)
- **9.1 — Next CC page: Client Portal, Platform Monitoring, or Admin** (by-ear at
  next session start; only these three remain). Full refactor against the four
  specs. Admin is expected to be the largest/most complex of the three. Apply the
  §4.2 lookback-floor treatment to any Platform Monitoring endpoint that ranks
  full snapshot history.

### BDL Import (from this session)
- **9.2 — `RBAC_ActionRegistry` rows for the BDL write/destructive endpoints**
  (execute, retry-trigger, execute-ar-log, align-rows, reset-alignment,
  staging-cleanup POST, template mutations). `Test-ActionEndpoint` is now wired on
  all 23 endpoints but is fail-open until rows exist; adding rows enforces admin
  server-side automatically. (DB hardening.)
- **9.3 — Tab-resume history refresh (verify live).** `cc_connectEngineEvents`
  early-returns when `bdl_ENGINE_PROCESSES` is absent (BDL has no engine cards),
  before registering the visibilitychange listener that fires
  `bdl_onPageResumed`. Whether the history panel auto-refreshes on tab-return on a
  no-engine page needs an eyeball; page is otherwise fully functional.
- **9.4 — BDL CSS dead-class cleanup** (separate behavior-affecting pass; see §7).
  Candidate trail available via `orphan_candidates.sql`. Not part of conformance.
- **9.5 — Known bug to fix** (user-identified, weekend work; details TBD — not a
  refactor regression, surfaced separately during page review).

### Dead-code detection (roadmap; from this session)
- **9.6 — Build orphan/unreferenced detection as a complete cross-file catalog
  check** (CSS classes, JS functions, endpoints). Resolver enhancement + advisory
  drift code + likely capture-time DDL. See §7 and `DeadCode_Detection_Findings.md`.
  Not a near-term item; circle back after the migration completes.

### Carried from prior sessions (still open)
- **9.7 — `RBAC_ActionRegistry` rows for Job Flow write endpoints** (S34).
- **9.8 — Job Flow section-load-failure presentation** (S34; minor, behavior-only).
- **9.9 — `RBAC_ActionRegistry` rows for File Monitoring write endpoints** (S33).
- **9.10 — `RBAC_ActionRegistry` rows for DM Operations launch/abort endpoints**
  (S29/30).
- **9.11 — DM Operations Archive launch not yet tested** (S29/30; Shell Purge
  confirmed live).
- **9.12 — `RBAC_ActionRegistry` row for JBoss `switch-server`** (S31).
- **9.13 — `RBAC_ActionRegistry` rows for DBCC launch/abort endpoints** (S32).

### Populator / pipeline (carried)
- **9.14 — JS populator performance** (S31; PowerShell per-statement
  interpretation suspected as the floor).
- **9.15 — Script-tag pattern, platform-wide** (S35; whether to inline the literal
  `<script src="/js/cc-shared.js">` everywhere and retire `Get-PageScriptTagHtml`
  — feeds the helper-consolidation cleanup).
- **9.16 — Dynamic-reference cataloging** (S32; `'prefix-' + expr` → `DYNAMIC_REF`
  construct with benign verdict. Directly relevant to 9.6 — the stem-capture
  mechanism is the same.).
- **9.17 — Admin pipeline UI** (S31; per-stage status → Admin API → Admin tile).

### Platform / backlog (carried)
- **9.18 — Retention strategy for snapshot tables** (no retention anywhere today).
- **9.19 — DBCC disk-alert suppression during CHECKDB runs** (medium; cross-
  component awareness).

---

## 10. Session boot sequence (next session)

1. Read the instructions, then this summary (CC_Session_Summary_37).
2. `project_knowledge_search` for the active anchor docs (this summary,
   Development Guidelines, Backlog, Platform Registry) to confirm Project
   Knowledge state; `web_fetch` cache-busted manifest for anything else.
3. Pick the next page (Client Portal / Platform Monitoring / Admin), confirm its
   `Component_Registry` row (component_name, cc_prefix, section_key, route),
   then request the four current files.
4. Build order: route → API → CSS → JS. Lift the CCShared import shim verbatim
   from a deployed route (do not reconstruct).

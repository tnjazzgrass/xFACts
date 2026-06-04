# CC Session Summary 34 — Job Flow Monitoring Page Migration

## 1. Session focus

CC File Format Initiative, page migration thread. Target: the **Job Flow
Monitoring** page (component `JobFlow`, cc_prefix `jfm`, route
`/jobflow-monitoring`, slug `jobflow-monitoring`, body section
`cc-section-platform`). All four files refactored to the four CC specs,
deployed, live-debugged, and drift-cleaned to the expected end-of-migration
floor.

Job Flow was selected by-ear at the start of this session per the Session 33
close. The page-per-session cadence holds: Job Flow is done; the next page
(Batch Monitoring) is selected for next session.

---

## 2. What was delivered

Four full drop-in replacements, exact production filenames, byte-disciplined
(pure ASCII, no BOM, PS + CSS CRLF, JS LF, single trailing newline):

- `JobFlowMonitoring.ps1` — page route (~257 lines)
- `JobFlowMonitoring-API.ps1` — API route, 15 endpoints (~1981 lines)
- `jobflow-monitoring.css` — page styles (~2037 lines)
- `jobflow-monitoring.js` — page module (~2314 lines)

Build order held: route → API → CSS → JS. One engine card
(`Monitor-JobFlow`, slug `jobflow`, label `JobFlow`).

### Refactor highlights

**Route.** Comment-based-help header + CHANGELOG + single `ROUTE: PAGE PATH`
banner. CCShared import shim as first statement *inside* the route scriptblock
(absolute path, `-Force -DisableNameChecking`); page route only, API route
carries no import. `Get-UserAccess` gate, chrome helpers, `$bannerHtml`. Body
`cc-section-platform` / `data-cc-page="jobflow-monitoring"` /
`data-cc-prefix="jfm"`. Five overlay constructs: the flow/day/pending/ad-hoc/
stall slideout (`cc-slide-overlay` / `cc-dialog cc-dialog-slide cc-xwide`), and
four `cc-modal-overlay` modals (tasks = `cc-wide`, confirm = default,
configsync = `cc-wide`, cs-confirm = default). All backdrop-close wired via
`data-action-click`.

**API.** All raw ADO eliminated. xFACts reads → `Invoke-XFActsQuery`; xFACts
writes → `Invoke-XFActsNonQuery`; crs5_oltp reads → `Invoke-CRS5ReadQuery`;
app-server Task Scheduler reads → `Invoke-Command` remoting (unchanged). Every
endpoint calls `Test-ActionEndpoint` first; every endpoint ends
`Write-PodeJsonResponse`. The five configsync save writes adopt the `FAC\`
username prefix (`"FAC\$($WebEvent.Auth.User.Username)"`) via a single
`$modifiedBy` built once and reused. No CHANGELOG (forbidden in api-route),
no `Write-Host`, no `'Control Center'` literal.

**CSS.** 347 → ~185 rules. All chrome/overlay/modal/slideout shells deleted
(now shared). Slideout summary/stat/section-title/job-tables mapped to shared
`cc-slide-*`; section tables (Live Activity executing/pending, Execution
History month-summary/history) kept page-local per the hybrid decision. 59
forbidden selectors flattened to state-on-element; all reprefixed `jfm-`;
literals tokenized only on exact match (the configsync blue tint
`rgba(86,156,214,0.08)` stayed literal — no exact token). No `@keyframes`,
no `:root`, no `!important`, no attribute selectors.

**JS.** Full restructure to the bootloader contract: `jfm_init` entry,
`jfm_ENGINE_PROCESSES` as `var`, all 70 functions + state `jfm_`-prefixed.
Every inline `onclick`/`onchange` → `data-action-*` routed through
`jfm_clickActions`/`jfm_changeActions` dispatch tables via two delegated body
listeners. Shared adoption: `cc_connectEngineEvents`, `cc_engineFetch`,
`cc_escapeHtml`, `cc_showAlert`. Slideout open/close per §11.5 static-slide
pattern; modals via `cc-hidden` toggle with backdrop guard. Three near-identical
builders DRY'd into helpers (`jfm_buildJobsTable`, `jfm_buildStallEpisodeRow`,
`jfm_buildValidationBadge`). Raw glyphs → HTML entities (innerHTML) or `\u`
escapes (textContent).

---

## 3. Deployment / drift debugging arc (in order)

Nine issues found across deployment, visual testing, and two populator passes;
all fixed.

1. **Both `todays-summary` and `history` returned HTTP 500.** Root cause:
   `-TimeoutSeconds` passed to `Invoke-XFActsQuery`, which accepts only `-Query`
   and `-Parameters`. The parameter was carried over from the `Invoke-CRS5ReadQuery`
   signature (which *does* have it) without verifying the xFActs wrapper's actual
   signature. The bug was in 13 `Invoke-XFActsQuery` calls across the file (every
   endpoint, not just the two first loaded). Fix: strip `-TimeoutSeconds` from the
   13 Query calls; the 3 `Invoke-XFActsNonQuery` and 3 `Invoke-CRS5ReadQuery`
   calls legitimately keep it. **Lesson: verify every external function's real
   signature against CCShared before emitting a call — a sibling wrapper having a
   parameter does not mean this one does.**

2. **`cc_showAlert` modal-spam on section-load failure.** The 500s surfaced as
   two stacked blocking modals because the section loaders used `cc_showAlert`
   (a modal) where the original used a non-blocking inline banner. Noted as a
   behavior regression; the modal fired because the underlying 500 was real.
   Once issue 1 was fixed the modals stopped. (Section-load-failure presentation
   left as-is for now; modals only appear on genuine failure.)

3. **Execution History defaulted to month-expanded on load.** The tree toggle
   was converted from inline `style="display:none"` to a `data-collapsed`
   attribute, but nothing acted on the attribute on initial render (the
   attribute-selector that would bridge it is `FORBIDDEN_ATTRIBUTE_SELECTOR`
   outside FOUNDATION). Fix: a post-render `jfm_applyHistoryCollapse` helper sets
   `style.display='none'` on `data-collapsed="true"` elements after the tree is
   built (same pattern as the progress-bar width helper).

4. **Config Sync tile had no pointer cursor.** The original affordance came from
   an inline `style="cursor:pointer"` dropped with the inline `onclick` and never
   replaced. Fix: `jfm-status-card-clickable` class (CSS `cursor: pointer`)
   emitted on the config-sync card alongside its action attribute.

5. **CSS: 56 `MISSING_PURPOSE_COMMENT` on state classes.** State classes
   (`jfm-status-card-warning`, `jfm-flow-status-badge-complete`, etc.) were
   written with the trailing inline-comment form `{ /* state */`. That form is
   only for pseudo-class variants (`.foo:hover`) and class-on-class compounds
   (`.foo.bar`). A standalone single-class rule is a **base class** (§6.1) and
   needs a *preceding* `/* Purpose. */` comment regardless of semantic
   "state-ness." Converted all 57 such rules to preceding-comment form.

6. **CSS + JS: `MALFORMED_FILE_HEADER` (+ CSS `FILE_ORG_MISMATCH`).** Both files
   led straight into the first section banner with no file header. The spec (§2)
   requires a distinct file-header block carrying a FILE ORGANIZATION list naming
   every section banner verbatim in order. Added proper headers to both; verified
   the FILE ORGANIZATION lists match the body banners exactly (12/12 CSS,
   24/24 JS).

7. **JS: 8 `JS_CSS_CLASS_UNRESOLVED` on `jfm-cs-hidden`.** The class was emitted
   (reprefixed from the original `cs-hidden`) but never defined in the CSS — the
   usage was migrated, the definition dropped. Fix: define
   `.jfm-cs-hidden { display: none; }` in the CONFIGSYNC section.

8. **Route: `MALFORMED_MODAL_STRUCTURE` on `jfm-modal-configsync`.** The flow
   selector bar sat as a fourth direct child of `.cc-dialog`, between header and
   body. §5.4 permits only header / body / optional actions footer as `.cc-dialog`
   children. Carried over from the pre-refactor markup without re-validating.
   Fix: move the selector bar *inside* `.cc-dialog-body`, with the JS-targeted
   content in a sibling `jfm-cs-content` wrapper so the body's `innerHTML`
   rewrites do not wipe the selector. The `jfm-configsync-body` ID rode along to
   the inner wrapper, so no JS change was needed.

9. **App Server Tasks modal: indicator/button never hid; staging looked broken.**
   Root cause: `cc-hidden` is an *empty* shared class that hides only via the
   compound `.cc-modal-overlay.cc-hidden`. Used as a general hide utility on three
   non-overlay elements (pending-count badge, pending-changes indicator, Apply
   button), it did nothing — they stayed permanently visible (the "shadow"). The
   spec forbids a page file defining a `.cc-hidden` compound (page classes must be
   `jfm-`-prefixed, §5). Fix: a page-local `jfm-hidden { display: none; }` swapped
   in for those three elements only (CSS + JS toggles + route initial markup); the
   five overlay toggles correctly stay on `cc-hidden`. This single fix resolved
   every reported App Server Tasks symptom (no count update, empty confirmation
   body, Apply appearing dead, close not resetting) — all were downstream of the
   never-hiding elements and muddled staging state. **Lesson: same pattern as
   issues 1 and 4 — verify what a shared name actually does before adopting it;
   `cc-hidden` looked like a hide utility but is overlay-specific.**

---

## 4. Final drift state

| File | Non-compliant |
|------|---------------|
| `JobFlowMonitoring-API.ps1` | 0 |
| `jobflow-monitoring.css` | 0 (after issues 5–7 fixes) |
| `jobflow-monitoring.js` | 0 (after issues 6–7 fixes) |
| `JobFlowMonitoring.ps1` | 2 — known transitional shim rows |

The route's 2 residual rows are `MISPLACED_IMPORT` + `MISSING_RBAC_CHECK_PAGE`
from the transitional CCShared import shim; they clear at end-of-migration when
the helper-module consolidation lands. Pre-refactor non-compliant counts were
405 / 398 / 15 / 156 (css / js / api / route).

---

## 5. Lessons reinforced this session

- **Verify external signatures before calling.** The `-TimeoutSeconds` 500 (issue
  1), the `cc-hidden` shadow (issue 9), and the missing cursor (issue 4) are one
  failure mode: adopting a shared name or sibling-function parameter without
  confirming what it actually provides. Read the real definition first.
- **When removing an inline attribute, ask what *else* it carried.** Removing an
  inline `onclick`/`style` correctly drops the handler, but the same attribute may
  also have carried a cursor, a `display`, or a title that must be re-expressed in
  CSS/markup. Issues 3, 4, and 9 all trace to incidental side-effects lost in the
  inline→class/dispatch conversion.
- **A single standalone class is a base class, not a variant** (§6.1/§7). The
  trailing `{ /* state */ }` comment form is reserved for pseudo-class variants
  and class-on-class compounds; everything else needs a preceding purpose comment.
- **The file header is a distinct required construct** (§2), separate from the
  first section banner, with a FILE ORGANIZATION list matching the banners
  verbatim in order.
- **`MALFORMED_MODAL_STRUCTURE`** keys off the strict `.cc-dialog` → header / body /
  optional actions child set (§5.4). Page-specific dialog controls (selector bars,
  toolbars) go *inside* the body, not as additional dialog children — unless a
  shared dialog-toolbar slot is added (chrome-consolidation phase, not now).
- **Migrating markup ≠ validating it.** Several issues (8, 9, and the original
  page's inline patterns) came from faithfully carrying the pre-refactor structure
  forward. The original layout is not authority; the spec is.

---

## 6. CC File Format Initiative — overall status

- Job Flow Monitoring migrated (this session). Previously migrated: File
  Monitoring, DBCC Operations, JBoss, all orchestration-outlier pages (DM
  Operations last), all departmental pages, all Server Operations pages, plus
  Replication, Index Maintenance, Backup, Applications & Integration.
- Going-forward cadence: one page per session. Remaining pages are full refactors
  against the four specs directly.
- Transitional per-page import shim (page routes only) produces the 2 known route
  drift rows that clear at end-of-migration.
- Helper-module consolidation (delete `xFACts-Helpers.psm1`, remove transitional
  `Import-Module` lines, update `Start-ControlCenter.ps1` to load CCShared at
  startup, delete `engine-events.css`/`engine-events.js`) cannot happen until all
  remaining CC pages are migrated.

---

## 7. Carry-forward (open items)

### Page migration (primary thread)
- **7.1 — Next CC page: Batch Monitoring** (selected for next session). Full
  refactor against the four specs.

### Job Flow (from this session)
- **7.2 — `RBAC_ActionRegistry` rows for the Job Flow write endpoints**
  (`app-tasks/toggle`, `app-tasks/batch`, `configsync/save`). Currently rely on
  `Test-ActionEndpoint` fail-open + UI. Confirm whether server-side RBAC rows are
  wanted; verify scope against the endpoint set before acting. (DB hardening.)
- **7.3 — Section-load-failure presentation.** Section loaders currently surface
  API failures via `cc_showAlert` (modal). Consider reverting to a non-blocking
  inline state for background loads, reserving `cc_showAlert` for user-initiated
  action failures (save/apply). Minor; behavior-only.

### Carried from prior sessions (still open)
- **7.4 — `RBAC_ActionRegistry` rows for DM Operations launch/abort endpoints**
  (S29/30).
- **7.5 — Archive launch not yet tested** (S29/30; Shell Purge confirmed live).
- **7.6 — `RBAC_ActionRegistry` row for JBoss `switch-server`** (S31).
- **7.7 — `RBAC_ActionRegistry` rows for File Monitoring write endpoints** (S33).
- **7.8 — JS populator performance** (sub-phase instrumentation; PowerShell
  per-statement interpretation suspected as the floor; full-pipeline baseline
  ~4:51, gated by the JS populator).
- **7.9 — Admin pipeline UI** (incremental per-stage status → Admin API endpoints
  → Admin modal/tile). Co-equal priority with page refactoring.
- **7.10 — Retention strategy for snapshot tables** (§5.2; none platform-wide).
- **7.11 — DBCC backlog: disk alert suppression during CHECKDB runs** (medium;
  cross-component awareness so disk alerts are suppressed/annotated while CHECKDB
  is actively running). Distinct from the (completed) DBCC page migration.
- **7.12 — 4th overlay construct (shared slide-up dock).** Pages with a slide-up
  panel keep it page-local until the shared construct exists.
- **7.13 — Chrome-consolidation phase.** Establish shared section-table chrome,
  then map the outlier page-local section tables (Job Flow's Live Activity and
  Execution History tables among them) to it. Later phase.

---

## 8. Session boot sequence (next session)

1. Read the instructions, then this summary (CC_Session_Summary_34).
2. Verify anchor docs in Project Knowledge via `project_knowledge_search`:
   active planning doc + Development Guidelines + Backlog + Platform Registry.
3. Next target is **Batch Monitoring** (§7.1). Request a cache-busting value for
   the root `manifest.json`, fetch the CC app sub-manifest, then fetch the four
   current Batch Monitoring files (route, API, css, js) plus the four specs as
   needed.
4. Build order per page: route → API → CSS → JS, one complete drop-in file at a
   time, exact production filenames, byte discipline throughout (PS + CSS CRLF,
   JS LF, no BOM, pure ASCII, single trailing newline).
5. Before emitting any call to a CCShared wrapper or shared class/utility, verify
   its actual signature/definition against `xFACts-CCShared.psm1` / `cc-shared.css`
   first (this session's recurring failure mode).
6. Sessions are not scoped to the carry-forward list — once Batch Monitoring is
   done, continue to the next item by-ear (another page, or the pipeline UI /
   populator investigation). Nothing is deferred unless context limits force it.

---

*End of Session 34 summary. Job Flow Monitoring is migrated, deployed,
visually verified, and drift-clean to the 2-row transitional floor. Next
session: migrate Batch Monitoring (page selection confirmed), verifying shared
signatures before use.*

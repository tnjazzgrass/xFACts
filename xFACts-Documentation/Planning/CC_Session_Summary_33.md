# CC Session Summary 33

## 1. Session focus

Continuation of the CC File Format Initiative. This session migrated the
**File Monitoring** page (component `FileOps`, prefix `flm`, route
`/file-monitoring`) -- all four files refactored to the four format specs,
deployed, visually verified, and drift-cleaned to the expected end-of-migration
floor. The session also surfaced and corrected a page-to-page consistency gap
in how clickable non-interactive cards were authored, and identified a small
HTML-spec wording gap that allowed that inconsistency to occur.

The page-per-session cadence holds: File Monitoring is done; next page selected
by-ear at the start of the next session.

---

## 2. What was migrated -- File Monitoring

All four files were rebuilt to the specs and deployed:

- `FileMonitoring.ps1` (page route)
- `FileMonitoring-API.ps1` (API route)
- `file-monitoring.css`
- `file-monitoring.js`

### Route (`FileMonitoring.ps1`)
- Comment-based-help header + CHANGELOG + single `ROUTE: PAGE PATH` banner.
- CCShared import shim as first statement *inside* the route scriptblock,
  absolute path (`E:\xFACts-ControlCenter\scripts\modules\xFACts-CCShared.psm1`),
  `-Force -DisableNameChecking`. Page route only; API route carries no import.
  (File-scope placement was the initial bug -- Pode runspaces do not inherit
  file-scope imports, so chrome helpers resolved to the legacy Helpers module
  and produced default/unstyled nav + header. Fix: shim inside the scriptblock.)
- `Get-UserAccess` gate, `Get-UserContext`, then chrome helpers
  (`Get-NavBarHtml`, `Get-PageHeaderHtml`, `Get-PageBrowserTitle`,
  `Get-ChromeBannersHtml`) into the `$html` here-string.
- Body `cc-section-platform`, `data-cc-page="file-monitoring"
  data-cc-prefix="flm"`.
- One engine card: process `Scan-SFTPFiles`, slug `sftp`, label `SFTP`,
  run_mode 1.
- Page-shell head whitespace: exactly one blank line at `</title>` -> first
  `<link>`, and between the two `<link>` lines (cleared
  `MALFORMED_PAGE_SHELL_WHITESPACE`).
- Three `cc-` overlay constructs: day detail slideout
  (`cc-slide-overlay` / `cc-dialog cc-dialog-slide cc-xwide` = 1000px), scheduled
  modal (`cc-dialog-modal cc-medium`), webhook modal (`cc-dialog-modal` default).
  All backdrop-close wired via `data-action-click`; modals start hidden via
  `cc-hidden`.
- Slide-up management console kept **page-local** (`flm-console-overlay`
  backdrop + `flm-console-panel`) -- it is not one of the three recognized `cc-`
  overlays; the shared slide-up dock does not yet exist (4th-construct backlog).
- Two config cards (`Monitors`, `Servers`) authored as `<button>` elements (see
  section 4) -- not `<div>` -- so they are keyboard/screen-reader accessible and resolve
  `ACTION_ON_NON_INTERACTIVE_ELEMENT`.
- Single `<script src="/js/cc-shared.js">`.

### API (`FileMonitoring-API.ps1`)
- CBH header + single `ROUTE: API ENDPOINTS` banner (no CHANGELOG -- forbidden in
  api-route files).
- 12 endpoints, each with `Test-ActionEndpoint` as the first line, here-string
  SQL, parameterized, `Write-PodeJsonResponse` last. All raw ADO replaced with
  `Invoke-XFActsQuery` / `Invoke-XFActsNonQuery` wrappers.
- `scheduled` endpoint: the SQL-local `DECLARE @CurrentTime` / `DECLARE
  @DayOfWeek` were replaced with PowerShell-computed values passed via
  `-Parameters @{ CurrentTime = ...; DayOfWeek = ... }` (cleared
  `MISSING_PARAMETER_DECLARATION` -- the populator cannot distinguish SQL-local
  DECLAREs from Pode `@param` placeholders, so the parameterized form is both
  spec-clean and more correct). Day-of-week math: `[int](Get-Date).DayOfWeek + 1`
  to match `DATEPART(WEEKDAY, GETDATE())` under default `@@DATEFIRST = 7`
  (Sunday = 1).

### CSS (`file-monitoring.css`)
- All `flm-` prefixed, all selectors flattened to state-on-element classes (no
  element/ID/descendant/combinator/stacked-pseudo selectors, no `:root`,
  no `@keyframes`). FILE ORGANIZATION matches banners.
- Token-vs-literal calls upheld: genuinely token-less values kept as literals
  (Jira colors `#cd3830`/`#e28432`/`#4bac52`/`#3769b2`, purple `#c586c0`, alert
  tints, the 18px card/year-label font size, 0.2-alpha tints). A value becomes a
  token only when an exact token value exists -- never round to the nearest tier
  (see section 4 / section 6).
- Button-reset added to `.flm-config-card` (`width: 100%`, `margin: 0`,
  `text-align: left`, `font-family: inherit`, `color: inherit`) so the
  now-`<button>` cards render identically to the former `<div>`; box styling
  (background/border/radius/padding) already lives on `flm-section`.

### JS (`file-monitoring.js`)
- Section order: CONSTANTS (ENGINE PROCESSES `var flm_ENGINE_PROCESSES`, ACTION
  DISPATCH `flm_clickActions`/`flm_changeActions`, LOOKUPS) -> STATE: PAGE STATE
  -> FUNCTIONS: INITIALIZATION (`flm_init` only) -> FUNCTIONS: ACTION DISPATCH ->
  work functions -> FUNCTIONS: PAGE LIFECYCLE HOOKS (last; the three hooks only).
- Migrated to the `cc-shared.js` bootloader contract: bootloader reads
  `data-cc-prefix`, calls `flm_init`; `flm_init` registers delegated body
  click + change listeners, calls `cc_connectEngineEvents()`, loads all data.
- Shared-call adoption: `cc_engineFetch`, `cc_escapeHtml`, `cc_formatTimeOfDay`,
  `cc_showConfirm`/`cc_showAlert`, `cc_pageRefresh`, `cc_DAY_NAMES`/
  `cc_MONTH_NAMES`, shared connection banner. Page-local helpers kept (no shared
  equivalent): `flm_escAttr`, `flm_fmtTimeOnly`, `flm_fmtTimeInput`.
- All `onclick` -> `data-action-click="flm-*"` + `data-action-flm-*` argument
  attributes; all routing via `flm_clickActions` / `flm_changeActions` dispatch
  tables.
- Overlay handlers per the JS spec patterns: static-modal close (`cc-hidden`
  toggle, `(target, event)` backdrop guard `event.target === target`) for the
  two modals; static slide-overlay open/close for the day slideout (add `cc-open`
  to overlay then inner dialog via `requestAnimationFrame`; close via one-shot
  `transitionend` on the inner dialog).
- Hooks: `flm_onPageRefresh`, `flm_onPageResumed`, `flm_onEngineProcessCompleted`.

Byte discipline on all four (and on every redelivery): no BOM, pure ASCII,
PS + CSS CRLF, JS LF, single trailing newline (CSS/JS exactly one).

---

## 3. Final drift state (post-fix)

| file | TotalRows | Compliant | NonCompliant |
|---|---|---|---|
| file-monitoring.css | 505 | 505 | 0 |
| file-monitoring.js | ~659 | all | 0 |
| FileMonitoring-API.ps1 | 94 | 94 | 0 |
| FileMonitoring.ps1 | ~278 | -- | **3** (expected) |

(Pre-refactor non-compliant was 331 / 250 / 43 / 185 respectively.)

The 3 residual route rows are all expected / tracked:
- `MISPLACED_IMPORT` + `MISSING_RBAC_CHECK_PAGE` (2) -- the CCShared import shim
  in the ROUTE section; clears platform-wide at end-of-migration module cutover.
- `ACTION_ON_NON_INTERACTIVE_ELEMENT` (1) -- the page-local console **backdrop**
  div. Page-local backdrops get no section 7.5 overlay carve-out; clears when the 4th
  overlay construct (shared slide-up dock) ships. Same category as the A&I dock
  rows (A&I has 2 -- a backdrop *and* a handle div; File Monitoring's console has
  only the backdrop, hence 1).

Note: the route had a higher non-compliant count across intermediate passes
(283 on the JS in particular) before the comment-syntax fix described in section 4.

---

## 4. Diagnostics and corrections this session

Five rounds, in order:

1. **Nav/header rendered as defaults** -- CCShared import shim was at file scope.
   Moved inside the route scriptblock (first statement). Pode runspaces do not
   inherit file-scope imports. (Matches the Session 32 DBCC finding.)

2. **Day detail slideout dimmed but did not appear** -- the slide open/close only
   toggled `cc-open` on the outer overlay, not the inner `.cc-dialog`. Fixed to
   the static slide-overlay pattern: `cc-open` on overlay then on inner dialog
   via `requestAnimationFrame`; close via one-shot `transitionend`. Also widened
   `cc-wide` (800) -> `cc-xwide` (1000) -- round *up* to the next shared tier when
   a legacy width (875) falls between tiers, to avoid right-edge text clipping.

3. **Daily Queue rows squashed / no separators** -- root cause: the original
   styled queue cells with an *element* selector (`.monitor-table td { padding;
   border-bottom }`). Flattening moved those properties to a class
   (`.flm-monitor-table-td`), but the JS emitted bare `<td>` cells, so they got
   zero padding and no border. Fixed by emitting `flm-monitor-table-td` on every
   queue cell, `flm-monitor-table-th` on header cells, and moving the group
   divider class onto its `<td>` so the separator renders under
   `border-collapse`. (The "Escalated/Monitoring/Detected" group-header labels
   that exist in the original CSS were dead code -- the original JS never rendered
   them; not restored.) Lesson: a flattening refactor can silently orphan styling
   when an element selector becomes a class the markup/JS does not apply.

4. **JS comment syntax -- the 283-row miss** -- the entire JS file was written with
   `//` line comments. The JS spec (section 2/section 3/section 13) requires `/* */` block comments
   for the file header, section banners, and purpose comments (same shapes as the
   CSS and PS files); `//` is permitted only inside function bodies. The wrong
   syntax meant the populator recognized no header (`MALFORMED_FILE_HEADER`), saw
   200 `FORBIDDEN_FILE_SCOPE_LINE_COMMENT` rows, recognized no banners (so every
   declaration cascaded to `MISSING_SECTION_BANNER` + `MISSING_*_COMMENT`), and
   fired the placement codes (`ENGINE_PROCESSES_MISPLACED`, `INIT_MISPLACED`,
   `HOOK_MISPLACED`) that key off banner recognition. Converted the whole comment
   layer to `/* */`; code bodies unchanged. Lesson: "read the spec end to end"
   includes the comment-syntax section for each language even when the language's
   own idiom (`//`) differs from the spec.

5. **Two residual JS rows after the comment fix** -- `BANNER_MALFORMED_TITLE_LINE`
   on the STATE banner + the resulting `FILE_ORG_MISMATCH`. Every banner title
   must parse as `<TYPE>: <NAME>` (per `BANNER_MISSING_NAME` -- only the fixed
   singletons `ENGINE PROCESSES` / `INITIALIZATION` / `PAGE LIFECYCLE HOOKS` get
   canonical names; all others need a chosen human-readable NAME). The bare
   `STATE` title had no NAME. Renamed to `STATE: PAGE STATE` in both the banner
   and the FILE ORGANIZATION list; both rows cleared.

### Config-card consistency fix (the page-to-page discrepancy)
The two config cards (`Monitors`, `Servers`) were initially authored as
`<div data-action-click>`, drawing `ACTION_ON_NON_INTERACTIVE_ELEMENT`. Prior
pages handled the equivalent clickable tiles differently: **Applications &
Integration** (S30) converted its admin tool-cards to `<button>` / `<a>`, and
**Index Maintenance** (S28) used a full-cover transparent `<button>` hit-target.
Leaving the File Monitoring cards as divs was an unintended inconsistency.
Resolved by converting both cards to `<button class="flm-section
flm-section-compact flm-config-card">` (card-is-button form -- valid here because
the cards contain no nested interactive elements) with button-reset CSS. This
both makes them accessible and restores consistency. The console **backdrop**
row is *not* a card -- it is the same category as the A&I dock backdrop and
correctly stays parked against the 4th-construct backlog item.

---

## 5. Decisions locked this session

- **Clickable non-interactive regions are `<button>` elements, not action-bearing
  `<div>`s** -- card-is-button form by default; full-cover transparent hit-button
  only when the region must contain a nested interactive element (button cannot
  legally nest a button or anchor). This is the standing resolution for
  `ACTION_ON_NON_INTERACTIVE_ELEMENT` on cards/tiles, consistent with A&I and
  Index Maintenance.
- **Slide-overlay open/close uses the RAF-open + transitionend-close pattern**
  with `cc-open` on both the overlay and the inner `.cc-dialog`. Static-modal
  uses the `cc-hidden` toggle with the `event.target === target` backdrop guard.
- **Round overlay widths UP to the next shared tier** when a legacy width falls
  between tiers (875 -> `cc-xwide` 1000, not `cc-wide` 800).
- **Tokenize only on exact match** -- a CSS value becomes a token only when an
  exact token value exists; genuinely token-less values stay literals. Never
  round to the nearest tier (the 18px card/year-label regression this session).
- **JS comment syntax is `/* */`** for header, banners, and purpose comments;
  `//` is permitted only inside function bodies.
- **Every banner title is `<TYPE>: <NAME>`**; non-singleton sections (e.g. STATE)
  require a chosen NAME (`STATE: PAGE STATE`).

---

## 6. Spec amendment (HTML section 7.5) -- to apply

section 7.5 already states the *constraint* (action attributes only on interactive
elements or the three overlay-container classes; closed carve-out list) but not
the *constructive resolution*. Add one bullet to the section 7.5 list so the resolution
is evident at authoring time rather than only inferable from the drift row:

> - A clickable non-interactive region (card, tile, row) is expressed as a
>   `<button>`; when it must contain a nested interactive element, it remains a
>   container with a transparent full-cover `<button>` as the click target.

No populator change required -- `<button>` is already permitted by the existing
first bullet, so this is documentation of how to use the existing rule, not a
loosening of it, and cannot introduce new drift. (User is applying this bullet
to the working copy of CC_HTML_Spec.md directly.)

---

## 7. CC File Format Initiative -- overall status

- File Monitoring migrated (this session). Previously migrated: DBCC Operations,
  JBoss, all orchestration-outlier pages (DM Operations last), all departmental
  pages, all Server Operations pages, plus Replication, Index Maintenance,
  Backup, Applications & Integration.
- Going-forward cadence: one page per session. Remaining pages are full refactors
  against the four specs directly.
- Transitional per-page import shim (page routes only) produces the 2 known route
  drift rows that clear at end-of-migration.
- Helper-module consolidation (delete `xFACts-Helpers.psm1`, remove transitional
  `Import-Module` lines, update `Start-ControlCenter.ps1` to load CCShared at
  startup, delete `engine-events.css`/`engine-events.js`) cannot happen until all
  remaining CC pages are migrated.

---

## 8. Carry-forward (open items)

### Page migration (primary thread)
- **8.1 -- Next CC page: selection by-ear at next session start.** Full refactor
  against the four specs.

### File Monitoring (from this session)
- **8.2 -- `RBAC_ActionRegistry` rows for the File Monitoring write endpoints**
  (config save / webhook create / monitor save). Currently rely on
  `Test-ActionEndpoint` fail-open + UI; confirm whether server-side RBAC rows are
  wanted. (DB hardening -- verify scope against the endpoint set before acting.)

### Spec / populator
- **8.3 -- Apply HTML section 7.5 clickable-region bullet** (see section 6) -- being applied to
  the working copy this session; confirm it lands before the next page so the
  rule is in force.
- **8.4 -- `STATE_NOT_COMPOUNDED` enforcement** (from S32 section 6.1): add the drift
  code to CC_CSS_Spec section 18 and build populator detection. Triggers a JBoss
  conversion pass when enabled.
- **8.5 -- Dynamic-reference cataloging design** (from S32 section 6.2): decide whether
  to capture prefix-known dynamic references and how (possible third verdict
  bucket).
- **8.6 -- FORBIDDEN_FUNCTION_IN_API_ROUTE coverage** investigation (from S31
  section 5.1).

### Carried (still open)
- **8.7 -- `RBAC_ActionRegistry` rows for DM Operations launch/abort endpoints.**
- **8.8 -- Archive launch not yet tested** (DM Operations; Shell Purge confirmed).
- **8.9 -- `RBAC_ActionRegistry` rows for the DBCC launch/abort endpoints.**
- **8.10 -- `RBAC_ActionRegistry` row for the JBoss `switch-server` endpoint.**
- **8.11 -- JS populator performance** (sub-phase instrumentation; full-pipeline
  wall-clock baseline ~4:51, gated almost entirely by the JS populator).
- **8.12 -- Admin pipeline UI** (incremental per-stage status -> Admin API
  endpoints -> Admin modal/tile). Co-equal priority with page refactoring.
- **8.13 -- 4th overlay construct (side-by-side slide-up dock)** -- model the
  page-local docks/consoles as a proper fourth `cc-` overlay so their
  backdrops/handles become carve-out-eligible. Consumers: A&I catalog dock,
  File Monitoring management console, Admin. Resolves the parked
  `ACTION_ON_NON_INTERACTIVE_ELEMENT` backdrop/handle rows. Design against all
  consumers, not one example.
- **8.14 -- Retention strategy for snapshot tables** (no retention platform-wide
  today).
- **8.15 -- DBCC backlog: disk alert suppression during CHECKDB runs** (medium).
- **8.16 -- Live cross-check of DBCC Live Progress + Today's Executions** during a
  real DBCC run.

---

## 9. Session boot sequence (next session)

1. Read the instructions, then this summary (CC_Session_Summary_33).
2. Verify anchor docs in Project Knowledge via `project_knowledge_search`:
   active planning doc + Development Guidelines + Backlog + Platform Registry.
3. Select the next page by-ear; request a cache-busting value for the root
   `manifest.json`, fetch the CC app sub-manifest, then fetch the four current
   files for the chosen page (route, API, css, js) plus the four specs as needed.
4. Build order per page: route -> API -> CSS -> JS, one complete drop-in file at
   a time, exact production filenames, byte discipline throughout (PS + CSS CRLF,
   JS LF, no BOM, pure ASCII, single trailing newline).
5. Sessions are not scoped to the carry-forward list -- once the page is done,
   continue to the next item by-ear (another page, or the pipeline UI / populator
   investigation / spec-enforcement items). Nothing is deferred unless context
   limits force it.

---

*End of Session 33 summary. Next session: migrate the next Control Center page
(selection by-ear), with HTML section 7.5 amendment confirmed in force.*

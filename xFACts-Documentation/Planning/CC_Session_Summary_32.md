# CC Session Summary 32 — DBCC Operations Page Migration

## 1. Session focus

CC File Format Initiative, page migration thread. Target: the **DBCC
Operations** page (`ServerOps.DBCC`, cc_prefix `dbc`, route `/dbcc-operations`,
slug `dbcc-operations`, body section `cc-section-platform`). All four files
refactored to the four CC specs, deployed, live-debugged, and drift-cleaned.

DBCC was selected at the close of Session 31 (§8.1). The page is the DBCC
*page* migration — distinct from the DBCC *monitoring* backlog item (disk-alert
suppression during CHECKDB), which remains a separate carry-forward.

---

## 2. What was delivered

Four full drop-in replacements, exact production filenames, byte-disciplined
(pure ASCII, no BOM, PS/CSS CRLF + JS LF applied at deployment):

- `DBCCOperations.ps1` — page route (~199 lines)
- `DBCCOperations-API.ps1` — API route, 10 endpoints (~621 lines)
- `dbcc-operations.css` — page styles (~1162 lines)
- `dbcc-operations.js` — page module (~1548 lines)

Build order held: route → API → CSS → JS. One engine card (`Execute-DBCC`,
slug `dbcc`, `cc_sort_order` 1, `run_mode` 1 live).

### Refactor highlights
- Route: spec comment-based-help header + CHANGELOG/ROUTE banners, CCShared
  import shim as first statement inside the route scriptblock, `$bannerHtml`
  chrome, three static `cc-dialog-modal` overlays (pending + schedule = `cc-wide`,
  edit = default) with `data-action-click` close actions, single `cc-shared.js`.
  Removed `window.isAdmin`/`__IS_ADMIN__` inline script, all `onclick`,
  engine-events asset pair.
- API: all raw ADO → `Invoke-XFActsQuery` here-strings; SQL injection via
  interpolation eliminated (parameterized); cross-server DMV query via raw
  `Invoke-Sqlcmd` with `-TrustServerCertificate` + `-ApplicationName`; every
  route (GET + POST) calls `Test-ActionEndpoint` first (§11.1, fail-open);
  `/api/dbcc/schedule` returns `{ IsAdmin, Schedules }` for server-side admin
  gating; `FAC\` username prefix preserved.
- CSS: dropped local `@keyframes`, element/`*`/attribute selectors, `!important`,
  `.modal-*`, `[data-value]` selectors; state-on-element throughout; class-based
  collapse/expand (`dbc-expanded`) across all four accordion levels.
- JS: full `dbc_` prefix discipline, `dbc_init` boot + per-event dispatch tables,
  four lifecycle hooks last, shared utilities (`cc_engineFetch`, `cc_escapeHtml`,
  `cc_DAY_NAMES`, `cc_MONTH_NAMES`), static-modal open/close per §11.5.2,
  progress-bar width via DOM property (no inline-style emission).

---

## 3. Deployment debugging arc (live, in order)

Five issues found by deploying and testing on the live system; all fixed.

1. **Page-shell scope: CCShared import shim misplaced.** Originally placed at
   file scope before `Add-PodeRoute`. Pode route scriptblocks run in their own
   runspace and do not inherit file-scope imports, so `Get-NavBarHtml`,
   `Get-PageHeaderHtml`, and `Get-ChromeBannersHtml` (the last exists only in
   CCShared) resolved to the old Helpers module → unstyled vertical nav, wrong
   header, and a 400 on clean reload. **Fix:** shim moved to be the first
   statement *inside* the route scriptblock, absolute path. This is the deployed
   convention (confirmed against DmOperations.ps1). Corrects a prior imprecise
   memory framing that described the shim as file-scope.

2. **`/api/dbcc/schedule` 500 — DBNull int cast.** `Invoke-XFActsQuery` returns
   `[System.DBNull]` for NULL columns; code used `$null -eq $row['x']` (false
   for DBNull), so `[int]$row['run_day']` threw on a NULL. **Fix:** all 41
   nullable-column checks across the API changed from `$null -eq $row['x']` to
   `$row['x'] -is [System.DBNull]`. (This was the actual 500, distinct from the
   single-row array-unwrap hardening also applied — see below.)

3. **Single-row array unwrap (hardening).** PowerShell collapses a one-element
   array to a scalar; a single schedule/result row would serialize as a JSON
   object, breaking JS `.forEach`/`.filter`. **Fix:** all five collection
   endpoints wrap the response value in `@(...)`; `$schedules = @($schedules)`
   before the response object; JS loader normalizes with `Array.isArray`.

4. **Engine card showing no status.** Rewriting the old `DOMContentLoaded` boot
   into `dbc_init` dropped the call to `cc_connectEngineEvents()` — the platform
   entry point that initializes per-slug engine state, loads `/api/engine/state`
   bootstrap, opens the WebSocket, and starts the ticker. **Fix:** added
   `cc_connectEngineEvents();` to `dbc_init`.

5. **Polling cadence (non-issue).** Two API calls per tick (live-progress +
   todays-executions) is by design; cadence (~10s via
   `/api/config/refresh-interval`) is correct. The dense Network tab was an
   accumulated long-running tab, not a rate bug.

Header/nav initially appeared "wrong/default" — this was the pre-shim-fix /
cached state, fully resolved by fix 1. Final visual: correct horizontal nav and
header matching the platform standard.

---

## 4. Drift outcome

Pre-refactor → post-refactor (final):

| file | Total (was→now) | NonCompliant (was→now) | % compliant |
|---|---|---|---|
| dbcc-operations.css | 251→478 | 208→**0** | 17%→**100%** |
| dbcc-operations.js | 408→506 | 182→**0** | 55%→**100%** |
| DBCCOperations-API.ps1 | 56→73 | 8→**0** | 86%→**100%** |
| DBCCOperations.ps1 | 166→160 | 109→**2** | 34%→**99%** |

The route's residual **2 rows** are the transitional import-shim floor:
`MISPLACED_IMPORT` + `MISSING_RBAC_CHECK_PAGE`. Identical to DmOperations.ps1.
Clears at end-of-migration when the shim is removed platform-wide. This is the
expected target, not a defect.

### Drift cleared in the second pass (notable)
- **CSS `UNDEFINED_CLASS_USAGE` + JS `JS_CSS_CLASS_UNRESOLVED` (~66 rows
  combined):** compound state tokens (`dbc-success`, `dbc-running`,
  `dbc-expanded`, `dbc-on`, `dbc-active`, `dbc-pill-*`, `dbc-op-*`, etc.) lacked
  standalone single-class definitions. Per CC_CSS_Spec §7.1 (and the Backup/DM
  precedent), each token now has an empty standalone `.dbc-x { }` with a purpose
  comment; the compound carries the styling + a trailing inline comment. 30
  standalone defs added (28 state/choice tokens + 2 bases `dbc-detail-table-row`,
  `dbc-detail-cell`). Same fix clears both files (shared resolution rule).
- **CSS `MISSING_PURPOSE_COMMENT`:** the `@media`-nested `.dbc-two-column`
  redefinition gained a preceding purpose comment (Backup precedent).
- **JS `JS_HTML_ID_UNRESOLVED` on `dbc-toggle-checkdb`:** the lone hardcoded
  `getElementById('dbc-toggle-checkdb')` was a dynamically-created ID; changed to
  the dynamic form `'dbc-toggle-' + dbc_OPERATION_KEYS[0].key` used everywhere
  else, so no phantom static USAGE row is emitted.
- **Route `MALFORMED_PAGE_SHELL_WHITESPACE`:** added the single blank line
  between `<head>` `<link>` elements (page-shell whitespace rule; DM precedent).

---

## 5. Spec amendment applied this session (CC_CSS_Spec, §7.1)

The compound/state-token shape is now codified. Two bullets added/clarified in
§7.1:

- A class-on-class compound carries no purpose comment and a trailing inline
  comment; each token is defined by a separate single-class rule; the state
  token's rule is empty (`{ }`) with its purpose comment, and the compound
  carries the styling. (This also corrected a prior contradiction: the old text
  forbade a trailing comment on compounds, but the deployed convention uses one.)
- A state or choice condition is expressed as a state token on a base class via
  a compound; a distinct class baking base and state into one styled rule is the
  non-preferred shape.

**These bullets are guidance, currently NOT strictly enforced.** They define the
target shape for remaining pages during the refactor.

### Pattern survey that settled the rule
- Compound pattern (empty standalone + styled compound): **Backup** (first
  migration), **DM Operations** (most recent), **DBCC** (this session). De facto
  standard.
- Distinct-class pattern (fully-styled class per base+state, no compound):
  **JBoss** — the lone outlier.

---

## 6. Discussion points for a future session (NOT yet acted on)

### 6.1 — `STATE_NOT_COMPOUNDED` drift code + populator enforcement
The §7.1 shape rule is guidance only. To enforce it, a drift code must be added
**and** the populator taught to detect the JBoss shape. The proposed code was
drafted but **removed from the spec for now** (kept out until the populator can
back it). If we proceed:
- Add to CC_CSS_Spec §18: `STATE_NOT_COMPOUNDED` — "A state or choice condition
  is a distinct styled class instead of a state token applied to a base via a
  compound."
- **Enforceability assessment:** a CSS-file-local rule alone CANNOT distinguish a
  distinct state class (`jbm-badge-ok`) from a legitimate styled base
  (`dmo-abort-btn`) — they are structurally identical. Recommended mechanism: a
  **defined closed state-token vocabulary** in the spec + rule "a styled
  single-class rule whose trailing name segment is a state token AND which never
  appears in a compound = drift." Deterministic, file-local, high-coverage (not
  airtight). Alternative (usage co-occurrence cross-referencing) is accurate but
  expensive and blinded by dynamic class application. Recommendation: vocabulary
  approach.
- Consequence: enabling this flags **JBoss** across its state classes → JBoss
  needs a future conversion pass (CSS restructure + JS toggle rewrite). This is
  the initiative working as intended (surfacing outliers), not unplanned tax.

### 6.2 — Dynamic-reference cataloging (gray area)
Dynamically-built class/ID references (`'dbc-toggle-' + key`) are invisible to
the populator, so they emit no USAGE rows and aren't catalogued. The catalog's
intent is "everything valuable is represented," which this dynamic content is
not. Open question: can/should dynamic references be captured? Proposed tiers:
static literal (catalogued, resolved — today's behavior); prefix-known dynamic
(`'literal-' + expr` → catalogue as a distinct `DYNAMIC_REF`/`PARTIAL_ID_USAGE`
construct, recording the known prefix, with a benign non-drift verdict);
opaque (not catalogued). Caution: do NOT attempt parser-side partial evaluation
to resolve suffixes from local constants — inconsistent once a suffix comes from
an API, which is the worst outcome. Likely needs a third verdict bucket
(out-of-judgeable-scope) so `DYNAMIC_REF` rows don't distort the
compliant/non-compliant ratio. Pros/cons and populator impact to be weighed; not
committed.

---

## 7. CC File Format Initiative — overall status

- DBCC Operations migrated (this session). Previously migrated: JBoss, all
  orchestration-outlier pages (DM Operations last), all departmental pages, all
  Server Operations pages, plus Replication, Index Maintenance, Backup,
  Applications & Integration.
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
- **8.1 — Next CC page: File Monitoring** (`FileOps`; selected for next session).
  Full refactor against the four specs.

### DBCC (from this session)
- **8.2 — `RBAC_ActionRegistry` rows for the DBCC launch/abort endpoints.**
  Launch and abort endpoints enforce admin via the `IsAdmin`/`CanLaunch` API
  flag and UI gating only; need server-side RBAC rows. (DB hardening.)
- **8.3 — Live cross-check of Live Progress + Today's Executions** when a real
  DBCC run occurs (next scheduled run ~Saturday; the leftmost live sections
  could not be verified with live data in-session).

### Spec / populator (from this session)
- **8.4 — `STATE_NOT_COMPOUNDED` enforcement** (see §6.1): add the drift code to
  CC_CSS_Spec §18 and build populator detection (recommended: state-token
  vocabulary + non-compound styled-suffix check). Triggers a JBoss conversion
  pass when enabled.
- **8.5 — Dynamic-reference cataloging design** (see §6.2): decide whether to
  capture prefix-known dynamic references and how, including a possible third
  verdict bucket.

### Carried from Session 31 (still open)
- **8.6 — `RBAC_ActionRegistry` rows for DM Operations launch/abort endpoints.**
- **8.7 — Archive launch not yet tested** (DM Operations; Shell Purge confirmed).
- **8.8 — `RBAC_ActionRegistry` row for the JBoss `switch-server` endpoint.**
- **8.9 — FORBIDDEN_FUNCTION_IN_API_ROUTE coverage** investigation (§5.1).
- **8.10 — JS populator performance** (sub-phase instrumentation; full-pipeline
  wall-clock baseline ~4:51, gated by the JS populator).
- **8.11 — Admin pipeline UI** (incremental status → Admin API endpoints → Admin
  modal/tile). Co-equal priority with page refactoring.
- **8.12 — Retention strategy for snapshot tables** (no retention platform-wide
  today).
- **8.13 — DBCC backlog: disk alert suppression during CHECKDB runs** (medium;
  distinct from the DBCC page migration completed this session).

---

## 9. Session boot sequence (next session)

1. Read the instructions, then this summary (CC_Session_Summary_32).
2. Verify anchor docs in Project Knowledge via `project_knowledge_search`:
   active planning doc + Development Guidelines + Backlog + Platform Registry.
3. Next target is **File Monitoring** (§8.1). Request a cache-busting value for
   the root `manifest.json`, fetch the CC app sub-manifest, then fetch the four
   current File Monitoring files (route, API, css, js) plus the four specs as
   needed.
4. Build order per page: route → API → CSS → JS, one complete drop-in file at a
   time, exact production filenames, byte discipline throughout.
5. Sessions are not scoped to the carry-forward list — once File Monitoring is
   done, continue to the next item by-ear (another page, or the pipeline UI /
   populator investigation / spec-enforcement items). Nothing is deferred unless
   context limits force it.

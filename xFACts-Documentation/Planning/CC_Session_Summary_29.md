# CC Session Summary 29

**Focus:** DM Operations page migration — the last orchestration-outlier page brought onto the CC file-format specs. All four source files (page route, API route, CSS, JS) converted to spec-conformant form, deployed, and verified drift-clean except for the expected end-of-migration residual.

---

## 1. What this session was

A single-page migration: `DmOperations.ps1` (page route), `DmOperations-API.ps1` (API route), `dm-operations.css`, and `dm-operations.js` converted to conform to `CC_PS_Spec.md`, `CC_HTML_Spec.md`, `CC_CSS_Spec.md`, and `CC_JS_Spec.md`. DM Operations was the second of the two orchestration-outlier pages (Index Maintenance was Session 28); the admin launch port was modeled on the Index Maintenance precedent.

Build order was page route -> API -> **CSS -> JS** (CSS before JS, swapped from the original plan, so the page-local class vocabulary was locked before the JS referenced it — avoiding rework on the coupled class-name references).

Going forward the cadence is **one page per session** — sustainable and keeps steady progress without overreach.

---

## 2. Files delivered (all drop-in, exact production names)

| File | Role | Result |
|---|---|---|
| `DmOperations.ps1` | page route | Pure shell; 5 benign residual rows (see §5) |
| `DmOperations-API.ps1` | API route | 0 non-compliant |
| `dm-operations.css` | page styles | 0 non-compliant |
| `dm-operations.js` | page module | 0 non-compliant |

Byte discipline: PS + CSS = CRLF + pure ASCII + no BOM; JS = LF + pure ASCII + no BOM. JS Node-syntax-validated.

---

## 3. Locked design decisions (the substantive changes)

These are the decisions that shaped the migration, all confirmed against the specs and the Index Maintenance precedent:

- **Admin gating moved fully server-side.** The page route carries no admin logic at all — no `window.isAdmin`, no string-replace. Admin capability rides on a per-process `CanLaunch = [bool]$ctx.IsAdmin` flag returned by the `lifetime-totals` API. The JS renders the admin control cluster (Schedule / Abort / Launch) only when `CanLaunch` is true; non-admins get an empty cluster because the render bails. This resolved the old inline `window.isAdmin` + `style="display:none"` pattern (both now forbidden).

- **`lifetime-totals` API restructured to self-contained per-process objects.** Each process is now complete on its own: `Archive` and `ShellPurge` each carry their own totals + `Aborted` + `CanLaunch` + a `Remaining` sub-object. The old top-level scatter (`ArchiveAborted`, `ShellPurgeAborted`, a shared `Remaining` grab-bag) is gone. `CanLaunch` is the same value on both objects (admin is per-user) — accepted redundancy as the cost of each object being self-describing. This created a hard JS<->API contract: the two files deploy together.

- **New `POST /api/dmops/launch-process` endpoint.** Admin launch port. Maps `archive`->`Execute-DmConsumerArchive.ps1`, `shell`->`Execute-DmShellPurge.ps1` (names from `Orchestrator.ProcessRegistry`), `Test-Path` guards, fires via `Start-Process -WindowStyle Hidden`. Modeled on Index Maintenance's launch endpoint.

- **Schedule converted slideout -> centered modal** (`dmo-modal-schedule`, shared `cc-dialog-modal cc-wide` = 800px). The click-and-drag 24-hour grid reads better as a centered pop-up than a full-height side panel. One shared modal instance serves both processes (JS swaps title/body/data per-process); batch-detail is a slideout (`dmo-slideout-batch-detail`, `cc-xwide` = 1000px); launch is a modal (`dmo-modal-launch`).

- **Overlay activation moved to shared mechanics.** The old `.active` class is gone — slideouts use the shared `cc-open` (+ `requestAnimationFrame` open / `transitionend` close), modals use the `cc-hidden` toggle. All static-overlay close handlers take `(target, event)` and use the guarded form (backdrop or explicit control closes; interior clicks ignored). This finally resolved the long-standing `.active`->`.open` divergence the old CSS CHANGELOG had flagged as future cleanup.

- **Action dispatch.** All inline `onclick` handlers replaced by `data-action-click` attributes routed through a `dmo_clickActions` table via a single delegated `dmo_handleClick` listener on `document.body` (registered in `dmo_init`). The schedule drag — `mousedown`/`mouseover`/`mouseup`, which aren't in the dispatch event set and run on a dynamically-rendered grid — uses document-level listeners registered in `dmo_init` (§12.2-permitted), resolving cells via `closest('.dmo-schedule-cell')`. This matches the Index Maintenance pattern exactly.

- **Two process-key namespaces, handled deliberately.** Engine-card slug = `shell` (matches `cc_engine_slug`). The read/schedule/abort API paths and params use `shellpurge`. Only the launch payload sends `shell`. The JS keeps `shellpurge` as its internal process key everywhere except the launch call, which maps `shellpurge`->`shell`. Documented in-code so it isn't mistaken for an accident.

- **CSS porting (chrome consumption).** Deleted all page-local chrome duplicates now consumed from `cc-shared.css` (base layout, `@keyframes pulse`, header-bar/refresh-info cluster, `.section*` framing, `.loading`, dead `.connection-error`, the entire `.slide-panel*`/`.modal-close` overlay block). Kept genuinely page-specific content re-prefixed `dmo-` and conformed (summary cards, today stats, status/bidata/mode badges, delete-order chips, history accordion, batch tables, batch-detail body, schedule grid). The lifetime/today **cards stayed page-local** — they don't map cleanly to the shared `cc-slide-stat` (different size context + color variants shared lacks).

- **Width snaps (flagged, best-judgment):** batch-detail slideout 980 -> 1000 (`cc-xwide`); schedule now an 800px modal (was a 780px side slideout — width + position change); schedule cells collapsed to a single 24px (was 18px base overridden to 24px in the modal).

---

## 4. Two live-only bugs (not caught by the populator)

Both surfaced only on the running page — the populator validates conformance, not behavior — and both were caught by eyeballing the deployed page:

1. **Accordions defaulted open and didn't collapse.** When the forbidden inline `style="display:none"` toggling was removed, the collapsed state was parked in a `data-dmo-collapsed` attribute, but (a) no CSS rule hid a collapsed section and (b) the CSS spec forbids attribute selectors anyway. **Fix:** a `dmo-collapsed` **state class** — each collapsible body's base class carries its visible display (`dmo-year-content` -> `block`, the two `<tr>` bodies -> `table-row`), and a `.base.dmo-collapsed` compound sets `display: none`. JS drives it via `classList`. Clean state-on-element, and correct for the div-vs-tr display difference.

2. **The two history columns grew in tandem.** Expanding one column's history stretched the other column's container (container grew, content didn't). Cause: the CSS grid stretching both columns to the taller one's height. **Fix:** `align-items: start` on `dmo-two-column-layout` so each column sizes to its own content.

Lesson reinforced: the populator can't see layout/behavior bugs. A live click-through (overlay close paths, schedule drag, accordion toggles, column independence) remains the necessary behavioral proof alongside the drift report.

---

## 5. Final drift state

| File | Total | Compliant | Non-compliant |
|---|---|---|---|
| dm-operations.css | 553 | 553 | **0** |
| dm-operations.js | 573 | 573 | **0** |
| DmOperations-API.ps1 | 139 | 139 | **0** |
| DmOperations.ps1 | 190 | 185 | 5 (all benign) |

The 5 page-route rows are the two known end-of-migration categories, not file defects:
- **Import shim (2):** `MISPLACED_IMPORT` + `MISSING_RBAC_CHECK_PAGE` — the transitional `Import-Module xFACts-CCShared.psm1` as the first statement (so `Get-UserAccess` isn't literally first). Clears when `Start-ControlCenter.ps1` loads CCShared at startup and the shim line is removed at end-of-migration.
- **Engine cards (3):** `ENGINE_CARD_ORDER_MISMATCH` + 2x `ENGINE_SLUG_REGISTRY_MISMATCH` — the `archive`/`shell` cards reference processes not yet registered/live in `Orchestrator.ProcessRegistry`. Clears when the DM processes go live (run_mode flip).

Real conformance drift fixed this session (drift -> 0): one `FORBIDDEN_WRITE_HOST` in the API (removed; error already surfaced in `Remaining.Error`); the `dmo-last` `UNDEFINED_CLASS_USAGE` (added the standalone `.dmo-last { }` definition the compound needs); and 12 `JS_CSS_CLASS_UNRESOLVED` on `dmo-no-activity` (switched all usages to the shared `cc-slide-empty` rather than define a redundant page-local class — the porting rule applied: it maps cleanly to existing chrome, so use the shared one).

Baseline -> final non-compliant: css 284->0, js 263->0, api 36->0, ps 122->5-benign.

---

## 6. Zone progress snapshot (cc zone, as of today)

**Migrated (clean + benign page-route residual only):**
Backup, BIDATA Monitoring, Business Intelligence, Business Services, Client Relations, Index Maintenance, Replication Monitoring, **DM Operations** (new this session). Plus the shared/vendored files already clean: `cc-shared.css`, `cc-shared.js`, and the three vendored libs.

**Pending (real conformance drift remaining), heaviest first:**
Admin (~1502), BDL Import (~1313), Server Health (~1149), JobFlow Monitoring (~974), File Monitoring (~809), Platform Monitoring (~683), Batch Monitoring (~674), DBCC Operations (~507), JBoss Monitoring (~453), Client Portal (~416), Applications & Integration (~390).

**Soon-to-be-deprecated (do not migrate):** `engine-events.css` / `engine-events.js` (replaced by cc-shared; deleted once the last page migrates off them) and `xFACts-Helpers.psm1` (the legacy chrome module being replaced by `xFACts-CCShared.psm1`).

At one page per session, ~11 pending pages remain. Admin, BDL Import, and Server Health are the largest and should be expected to take the most care (Admin and Server Health especially — large JS/PS files, like Index Maintenance was).

---

## 7. Carry-forwards

**Real, addressable (not yet done):**
- **RBAC_ActionRegistry rows for the DM launch/abort endpoints.** `Test-ActionEndpoint` is fail-open for unregistered endpoints, so `launch-process` and `abort` currently *work* but are only admin-*hidden* (the JS gates the UI on `CanLaunch`), not admin-*enforced* server-side. They need registry rows to be properly gated. Index Maintenance's launch endpoint presumably has a corresponding row — verify and mirror. This is a DB concern, outside the four files, flagged when the API was built.

**End-of-migration items (blocked until the whole zone migrates):**
- Remove the transitional `Import-Module` shim from every page route once `Start-ControlCenter.ps1` loads `xFACts-CCShared.psm1` at startup (clears all the import-shim drift rows zone-wide).
- DM engine-process go-live (run_mode flip) clears the DM engine-card drift; same pattern as the Index placeholder processes.
- Delete `engine-events.css` / `engine-events.js` after the last page migrates off them.
- FK Step 3 in `Populate-AssetRegistry-PS.ps1` (delete shims, delete `Get-ObjectRegistryMap`, update bulk-insert signature) — was pending on JS+HTML populator migration; revisit.
- Per-page credential migration off Helpers onto CCShared.
- `xFACts_Development_Guidelines.md` (§3.6) and `xFACts_Platform_Registry.md` still list `xFACts-Helpers.psm1` as the CC shared module; update to CCShared at end-of-migration when the swap is real.

**Other (pushed, not urgent):**
- Engine-card enforcement gap: a `run_mode=1` process registered to a page with no corresponding card / `ENGINE_PROCESSES` entry should fire drift. Design depends on the still-undesigned orchestration pattern; the inverse (cards referencing not-yet-live processes) is already flagged, so the gap is visible in the table today. Circle back after more pages migrate.
- Index Maintenance schedule slideout -> centered modal (the same conversion done for DM this session), bundled with other planned Index edits when convenient.

---

## 8. Cross-references

- `CC_Session_Summary_28.md` — predecessor; Index Maintenance migration (the orchestration-outlier pattern + admin launch port this session modeled on).
- `CC_Session_Summary_27.md` — site-wide overlay-close consistency pass; the guarded `(target, event)` close pattern DM's overlays use.
- `CC_PS_Spec.md` — §11 routes (page-route `Get-UserAccess`-first / `Write-PodeHtmlResponse`-last; api-route `Test-ActionEndpoint`-first / `Write-PodeJsonResponse`-last, no CHANGELOG; §12 SQL here-strings).
- `CC_HTML_Spec.md` — body shell attrs, §5.4 overlays (outer overlay backdrop-close action), §7 action attributes.
- `CC_CSS_Spec.md` — LAYOUT/CONTENT sections, per-class purpose comments, state-on-element (no attribute selectors), compound token definitions, tokens-where-defined.
- `CC_JS_Spec.md` — page-file banner order (CONSTANTS/STATE/FUNCTIONS), `dmo_init` sole INITIALIZATION content, hooks-banner-last, dispatch tables, §11.5 overlay handlers, §12.2 document-level delegation.
- `xFACts_Platform_Registry.md` — `DmOps` component (cc_prefix `dmo`, section_key `platform`).

---

*End of Session 29. DM Operations is fully migrated and functioning; residual drift is entirely expected (2 import-shim + 3 engine-registration rows). Both live-only bugs (accordion default-open, tandem column growth) fixed. Eight pages now migrated; ~11 remain with real drift. Next session: one page — candidate to pick at session start (Admin / BDL Import / Server Health are the heaviest; a mid-size page keeps the one-per-session cadence comfortable). Provide the target page's ProcessRegistry cc_engine_slug / cc_sort_order / cc_page_route values at session start if it has engine cards.*

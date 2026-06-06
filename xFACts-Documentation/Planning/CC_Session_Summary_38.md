# CC Session Summary 38 — Client Portal migration

**Date:** 2026-06-06
**Page migrated:** Client Portal (`Tools.ClientPortal`, prefix `clp`, route `/client-portal`, section `tools`)
**Outcome:** All four files migrated and deployed. Final drift: CSS 0, JS 0, API 0, route 2 (transitional). Page verified functional and visually faithful via live walkthrough.

---

## 1. What shipped

Four files, full drop-in replacements, deployed as a set:

- `ClientPortal.ps1` (page route)
- `ClientPortal-API.ps1` (13 read-only GET endpoints, crs5_oltp)
- `client-portal.css`
- `client-portal.js`

The Client Portal is a four-view SPA (search / results / consumer detail / account detail) rendered as one route. It is a **deliberately light-themed content area** inside the dark CC shell — a single-page design choice, kept page-local per CSS spec §4.1 rather than mapped to dark chrome.

---

## 2. Final drift state

| File | Pre | Post |
|---|---|---|
| client-portal.css | 157 | **0** |
| client-portal.js | 107 | **0** |
| ClientPortal-API.ps1 | 16 | **0** (after the marker fix in §4) |
| ClientPortal.ps1 | 136 | **2** (transitional) |

The route's 2 are the known end-of-migration category, not file defects:
- **Import shim (2):** `MISPLACED_IMPORT` + `MISSING_RBAC_CHECK_PAGE` — the transitional `Import-Module xFACts-CCShared.psm1` as the first statement (so `Get-UserAccess` isn't literally first). Clears platform-wide when `Start-ControlCenter.ps1` loads CCShared at startup and the shim line is removed at end-of-migration.

CSS came in fully clean: the light-theme color literals did **not** flag, confirming `DRIFT_HEX_LITERAL` only fires where a shell token holds that exact value — the dark shell holds none of these light values. The Option-A approach (dimensional/timing values via shared tokens, light colors as literals) was the correct read.

---

## 3. Key decisions made this session

1. **Light-theme content stays page-local (`clp-` classes), not mapped to `cc-section`.** The portal's white cards are specific to one page; CSS §4.1 routes one-page variations to page-local classes rather than chrome. This preserves the deliberate light design and is conformant.
2. **CSS Option A** — dimensional/timing values mapped to shared tokens where the value matches (verified value-correct, no appearance change); light-theme colors as hex literals (no shared-token equivalent exists). This is the minimum-drift conformant form for a light page in a dark shell.
3. **Lookup-status readout moved into page content** (top of the search section), not the header center column. This *avoided* `cc-has-center` drift entirely rather than incurring it, and the indicator looked out of place in the header anyway. (Note: `cc-has-center` remains a known pending-populator-catch-up category for pages that *do* use the center column — Server Health — but Client Portal sidesteps it.)
4. **Tables flattened to class-per-cell.** The spec forbids bare-element (`th`/`td`/`thead`/`tr`) and descendant selectors outside the shell FOUNDATION. Tables now emit `clp-table`/`clp-thead`/`clp-th`/`clp-td`/`clp-row`/`clp-text-right`/`clp-totals-row`/`clp-totals-cell`. This couples CSS↔JS: the CSS defines the cell classes, the JS table-builders must emit them.
5. **Toggle = state-on-element.** The old `.toggle-switch.active .toggle-knob` descendant rule became two independent single-class rules; the JS adds `clp-active` to **both** the switch (track color) and the knob (slide position).
6. **Dropped the portal's `*` reset and `body` rule** — redundant with the shared FOUNDATION the page now loads. Only `overflow-x: hidden` genuinely disappears; tables handle their own overflow via `.clp-scroll-container { overflow-x: auto }`. No visual regression observed.
7. **Search interactions via dispatch tables** (`clp_keydownActions` Enter-to-search, `clp_inputActions` debounced client-filter) for platform consistency.

---

## 4. Post-deploy fixes (real drift / bugs caught after first deploy)

Three issues surfaced after the initial deploy; all fixed. Logged because they are recurring-pattern lessons:

- **API — 2× `MALFORMED_SUBSECTION_MARKER`** (the only non-zero API drift; I had predicted 0). The original `/search` endpoint had two inline divider comments `# ---- TWO-STEP PATH ----` and `# ---- SINGLE-QUERY PATH ----`. The box-banner removal pass stripped the `# ===` section banners but left these `# ----` sub-section dividers, which don't match the spec's strict §13.2 form. **Fix:** reshaped to `# -- Two-step path --` and `# -- Single-query path --`, each isolated by a blank line before and after. (Kept, not deleted — they mark two genuinely distinct search strategies.) **Lesson for remaining pages:** fold sub-section-marker normalization into the box-banner removal pass — scan for `# ----`-style dividers up front rather than discovering them at audit.
- **CSS — totals row greyed out** (cosmetic, caught in walkthrough). Flattening the tables split the original blanket `td { color: #1f2937 }` into `.clp-td`. The totals cells use `.clp-totals-cell`, which I'd left without a color, so the totals text washed out against the light band. **Fix:** added `color: #1f2937; font-weight: 600` to `.clp-totals-cell`. **Lesson:** when flattening a blanket element rule into per-class rules, every class that the element rule used to cover must inherit its properties — don't just create the "main" cell class and forget the variants.
- **Deploy — "Page boot function not found" banner on first load** (deploy-side, not a file defect). The route/API/CSS deployed but the JS was a stale pre-migration copy (still defined the old `Portal` IIFE, not `clp_init`). The bootloader injects `/js/<page>.js` with **no cache-busting query string**, so a stale page module is easy to get stuck on. **Lesson:** after deploying a migrated page, hard-refresh (Ctrl+F5); if the boot banner appears, first suspect a stale/partial JS deploy or browser cache of the un-versioned page module, not the file logic. (Confirmed clp_init globalizes correctly from a classic script even with top-level `const` present — verified via Node global-eval; the file was never the problem.)

---

## 5. Verification approach that worked

- **Node `--check`** on the JS for a real parse (no PowerShell runtime available; this catches syntax errors the structural scans miss). Worth doing on every JS file before declaring it ready — the structural/pattern scans do not parse.
- **Classic-script global-eval simulation** to confirm `<prefix>_init` actually lands on `window` (function declarations globalize even with top-level `const`/`let` present; `const`/`let` themselves do not attach to `window`, which is fine — dispatchers reference them lexically).
- **Cross-file integrity checks**: every emitted `data-action` value has a handler; every handler maps to an emitted action; every `clp-` CSS class the JS uses exists in the stylesheet; every DOM id the JS reads exists in the route. These caught nothing real this time but are the right gate.
- **Live walkthrough remains the only proof of behavior and appearance** — the totals-color bug was invisible to every populator and scan; only the eye caught it.

---

## 6. Zone progress

**Migrated (clean + transitional residual only), per S37 list plus this session:**
Backup, BIDATA Monitoring, Business Intelligence, Business Services, Client Relations, Index Maintenance, Replication Monitoring, DM Operations, JBoss Monitoring, **Client Portal** (new this session).

**Remaining: 2 pages.**
- **Platform Monitoring** (`ControlCenter.Platform`, prefix `plt`) — next session. Scoped below.
- **Admin** — last (meta-page; it manages the registry/version machinery the initiative itself uses).

After both, the end-of-migration cutover: `Start-ControlCenter.ps1` loads CCShared at startup, the per-route import shims are stripped (clears all the transitional `MISPLACED_IMPORT` + `MISSING_RBAC_CHECK_PAGE` rows platform-wide), and the legacy shared files (`engine-events.js`/`.css`, `xFACts-Helpers.psm1`) retire.

---

## 7. Platform Monitoring — scoping for next session

Scoped by reading the four current files this session (read-only; no build started). **Estimated drift baseline ~683 non-compliant rows** (per S35 zone snapshot) — middle of the pack, comparable to Batch Monitoring, lighter than Server Health (~1149) or Admin (~1502).

### 7.1 What the page is (corrected understanding)

Platform Monitoring is an **on-demand snapshot page**, NOT a live-polling / engine-card page. It measures the environmental impact of every xFACts process plus API/process metrics. Data is pulled **on page load, on manual refresh, and on tab-resume** — there is no polling schedule and there are no engine cards or registered orchestrator processes feeding it.

**Critical correction to first-glance read:** the JS contains engine-card *scaffolding* that is **vestigial / inert**, copied from a card-based template this page never actually used:
- `var ENGINE_PROCESSES = {}` — empty. No processes, no cards.
- `onEngineProcessCompleted(...)` — body is `// No event-driven sections on this page`. No-op.
- `onSessionExpired()` — empty `{ }`. No-op.
- `connectEngineEvents()` — called once in init, but connects to a stream the page doesn't use.

**Genuinely live behavior to PRESERVE:**
- `onPageResumed() { pageRefresh(); }` — re-pulls the snapshot when the tab regains focus. Real. → `PAGE LIFECYCLE HOOKS` banner.
- A `setInterval` that is a **midnight-rollover reload** (`if (new Date().toDateString() !== pageLoadDate) window.location.reload()` every 60s) — NOT data polling; it rolls the "today" window for a page left open overnight. Decide next session where this lives (likely a small init-registered timer; confirm spec placement).

**Decision for next session (spec-read, don't assume):** on a card-less page, does the spec want an empty `CONSTANTS: ENGINE PROCESSES` block present, or is its presence itself the drift signal to remove the scaffolding? Working hypothesis: **remove** the engine scaffolding entirely (no `plt_ENGINE_PROCESSES`, drop the `onEngineProcessCompleted` no-op) — this is *deletion*, not migration, and it reduces the lift. Confirm against the JS spec's engine-processes/hooks sections before acting.

### 7.2 Registry facts (CONFIRMED from Component_Registry)

Authoritative — confirmed from `Component_Registry` row (component_id 16):
- **Component:** `ControlCenter.Platform` (module **`ControlCenter`** — NOT ServerOps)
- **cc_prefix:** **`plt`**
- **Route:** `/platform-monitoring`
- **Section:** **`admin`** (NOT `controlcenter` — see access model below)
- **doc_cc_slug:** `platform`, doc_title "Platform Monitoring"

**Access model — tile-only, admin-gated, not in nav.** Platform Monitoring is NOT a nav-visible page. It has no nav entry and is reachable ONLY via a tile on the Admin page, restricted to admin users. It is xFACts-stats / environmental-impact content for admins. This is the **same pattern as Admin itself** (no nav visibility except the gear icon; `ControlCenter.Admin`, prefix `adm`). Component module (`ControlCenter`) and nav section (`admin`) are different axes: the component says who owns the code, the section says where it lives in the nav/access model.

**Consequences:**
- Body shell is **`cc-section-admin`** (not `cc-section-controlcenter`). The H1/frame renders in the admin section accent — which maps to `--color-accent-platform` in cc-shared.css (admin pages use the platform accent). Confirm the exact present-vs-new frame color on the walkthrough.
- Because the page is **not in the nav**, do NOT assume the standard nav-registry helpers (`Get-NavBarHtml`, `Get-PageHeaderHtml`, `Get-PageBrowserTitle`) resolve the same way they do for nav pages. **Check the Admin route as the precedent** — Admin works identically (tile/gear-accessed, non-nav) and is the authoritative example for how a non-nav admin-gated page wires its chrome and header. Do this before building the route.

**CRITICAL — prefix migration is part of the lift.** The existing files are on the WRONG prefix: the JS uses the `PM` module and `pm_`/`PM.` identifiers, the CSS uses `pm-` classes throughout, and the route uses `pm-` ids. The registered prefix is **`plt`**. So every identifier must be re-prefixed:
- CSS: every `.pm-*` class → `.plt-*` (touches essentially every selector — on top of the ~86-selector flatten)
- JS: every `PM.`/`pm_` identifier → `plt_`; the `PM` module name disappears with the IIFE unwind
- Route: every `pm-` id, class, and `data-action` value → `plt-`
- Cross-file: the CSS class rename and the JS class references must stay in lockstep — a class renamed in CSS but missed in the JS fires `JS_CSS_CLASS_UNRESOLVED`. The cross-file integrity check (§5) catches these, but it is volume.

This makes Platform's lift **larger than a clean-prefix page** — the pervasive `pm`→`plt` rename is mechanical but touches all four files and every cross-file reference. Budget for it.

**Chrome section:** body gets **`cc-section-admin`** (NOT controlcenter — the page is admin-gated and tile-accessed, §7.2 access model), `data-cc-page="platform-monitoring"`, `data-cc-prefix="plt"`. The H1/frame color follows the admin section accent (`--color-accent-platform`) — likely a visible frame-color change from today (same kind of intended shift seen on Client Portal's tools-accent). Because the page is non-nav, mirror the Admin route's chrome/header wiring rather than assuming the nav-page pattern (§7.2).

(Earlier scoping incorrectly inferred `pm`/`ServerOps.PlatformMonitoring` from file contents — the registry overrides. Standing rule #1: verify from source, never infer from existing files. The files were on a wrong prefix, which is itself part of what the migration fixes.)

### 7.3 File-by-file lift estimate

Sizes (current): route 260 / API 520 / CSS 475 / JS 1015 lines.

- **API (`PlatformMonitoring-API.ps1`) — LIGHTEST.** 10 read-only GET endpoints. Only **1** inline single-line SQL literal (vs Client Portal's 26); **20** queries already in here-string form. Work is mostly: CBH header, single `ROUTE: API ENDPOINTS` banner, `Test-ActionEndpoint` guard as first statement per endpoint, box-banner removal, convert the 1 inline literal. **Watch:** the em-dash/BOM byte issues seen in Client Portal's API — check for them here too.

- **Route (`PlatformMonitoring.ps1`) — MODERATE.** Single page route, `/platform-monitoring`. Currently loads `engine-events.css` (retire — folded into cc-shared), Chart.js from **CDN** (see 7.4), and has an **inline `<script>` block** (~line 198) that must move into the JS module. Reshell chrome to `cc-*` (header-bar/refresh-info/banners), body `cc-section-admin` + `data-cc-page="platform-monitoring"` + `data-cc-prefix="plt"`, lift the import shim verbatim, single `cc-shared.js` tag last (after vendored Chart.js tags). `onclick` handlers (6) → `data-action-*` dispatch with `plt-` values. **Non-nav page — mirror the Admin route's chrome/header wiring (§7.2).**

- **CSS (`platform-monitoring.css`) — HEAVIEST LIFT.** No `:root`, no custom properties already (good — no token-extraction war; dark-palette page, 178 hex literals that should mostly map to existing shell tokens). Two compounding jobs: **(a) selector flattening** — ~86 forbidden selectors (**55 descendant**, **22 element**, 3 attribute, 5 group, 1 depth-3, 1 universal, plus 6 `!important` to remove); **(b) prefix rename** `pm-` → `plt-` on every class. Mostly `.pm-x .pm-y` descendant rules → flattened class-per-element `.plt-*`, same pattern as Client Portal's tables but at ~5× the volume.

- **JS (`platform-monitoring.js`) — MODERATE-HEAVY.** ~1015 lines, `PM = (function(){...})()` revealing-module IIFE to unwind to top-level **`plt_`** functions (~48 functions, 138 `var`, 0 `let`, 0 `window.` assignments — clean starting point). The `PM` module name disappears with the unwind; every `PM.`/`pm_` identifier becomes `plt_`. Only 6 `onclick` → small dispatch tables. **Has Chart.js charting** (CPU-trend-over-time) to preserve. **Has the vestigial engine scaffolding to delete** (see 7.1). Inline route `<script>` block to absorb. Migrate `esc`→`cc_escapeHtml`, raw fetch→`cc_engineFetch`, `alert()`→`cc_showAlert` as usual.

### 7.4 Chart.js — vendored, not CDN (spec-encoded pattern)

The page pulls Chart.js from a CDN (`https://cdn.jsdelivr.net/npm/chart.js`). This is drift. The fix is a **known, spec-encoded pattern** (CC_HTML_Spec §3.2.2, closed vendored-library set) — the Replication Monitoring migration drove the web→local move and the vendored files are already committed under `/public/js/` and already anchored by the populator. No new files to create.

- CDN `<script>` → `<script src="/js/chart.min.js"></script>` (local, no `defer`/`async`/`type`).
- If the CPU-trend chart uses a time-scale axis (almost certainly), also add `<script src="/js/chartjs-adapter-date-fns.min.js"></script>`.
- Both vendored tags go in `<body>`, after page content, **immediately before** the mandatory `<script src="/js/cc-shared.js"></script>` (which is always last). No other `<script>` tags permitted.
- The charting **JS** (Chart construction/config) moves from the inline route `<script>` block into `platform-monitoring.js`.

### 7.5 Estimated effort

Comparable in total to Client Portal, with a different distribution: **API much lighter**, **CSS notably heavier** (the ~86-selector flatten is the long pole), JS moderate (IIFE unwind + charting preserve + scaffolding delete). The engine-scaffolding removal *reduces* work relative to a true card page like JBoss. Realistic single-session page if the CSS flatten goes smoothly; the CSS is where to budget the time.

---

## 8. Session boot sequence (next session)

1. Read the instructions, then this summary (CC_Session_Summary_38).
2. `project_knowledge_search` for the active anchor docs (this summary, Development Guidelines, Backlog, Platform Registry) to confirm Project Knowledge state; `web_fetch` cache-busted manifest for anything else.
3. Platform Monitoring registry facts are **confirmed** (§7.2): `ControlCenter.Platform`, prefix **`plt`**, route `/platform-monitoring`, section **`admin`** (tile-only, admin-gated, non-nav — same pattern as Admin). The existing files are on the wrong prefix (`pm`); the `pm`→`plt` rename across all four files is part of the migration (§7.2). Body is `cc-section-admin`. Mirror the **Admin route** for non-nav chrome/header wiring.
4. Request the four current files.
5. Build order: route → API → CSS → JS. Lift the CCShared import shim verbatim from a deployed route (do not reconstruct).
6. Resolve the engine-scaffolding question (§7.1) by reading the JS spec's engine-processes/hooks sections **before** building the JS.
7. Verify each file with the gates from §5 (Node `--check` on JS; classic-script global-eval for init; cross-file integrity; live walkthrough for behavior/appearance).

---

## 9. Carried backlog (unchanged from S37 unless noted)

- Sub-section-marker normalization folded into box-banner removal pass (new this session — §4).
- `FORBIDDEN_FUNCTION_IN_API_ROUTE` populator coverage-gap investigation (from S31).
- DmOps launch/abort `RBAC_ActionRegistry` rows; DmOps Archive launch testing (Shell Purge confirmed).
- Retention strategy for snapshot tables (no retention anywhere today).
- DBCC disk-alert suppression during CHECKDB runs (medium).
- B2B module: `B2B_Roadmap.md` is the authoritative entry point; investigation-first stance.
- End-of-migration cutover (after Platform + Admin): startup CCShared load, strip import shims, retire `engine-events.*` and `xFACts-Helpers.psm1`.

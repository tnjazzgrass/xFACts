# CC Migration — Phase 1: Page-by-Page Migration to cc-shared

*Working document. Tracks the per-page Phase 1 conversion across the Control Center. Retired or archived when Phase 1 is complete on every page.*

---

## 1. Purpose

Phase 1 is the per-page migration that brings every Control Center page off the legacy shared infrastructure (`engine-events.css`, `engine-events.js`, inline event handlers, DOMContentLoaded boot pattern, free-form file structure) and onto the current spec-compliant infrastructure (`cc-shared.css`, `cc-shared.js`, bootloader-driven boot, dispatch-table event handling, structured banners and sections, contract identifiers in their required homes).

Phase 1 is **one pass per page**. A page is considered Phase 1 complete when:

- It operates correctly and visually identically (or better) than its pre-migration state
- It consumes `cc-shared.css` and `cc-shared.js` and no longer references the legacy engine-events files
- Its four files are structurally spec-compliant (file headers, banners, sections, prefix discipline, contract identifiers)
- Its event handling uses the dispatch-table pattern via `data-action-<event>` attributes — no inline `onclick` handlers, no per-element `addEventListener` loops
- The catalog after migration shows zero authoring drift; any remaining drift is documented catalog tooling or spec gaps tracked in §11

Page-by-page migration runs in parallel with catalog tooling and spec refinement: each page migration surfaces real-world drift that drives tooling and spec fixes, and each tooling/spec fix removes false-positive drift that would otherwise look like authoring issues on future pages.

**Important framing note.** An earlier draft of this document split Phase 1 into "skeleton refactor" with chrome consolidation and dispatch migration deferred to later phases. That framing was abandoned after the first page migration (Backup) demonstrated that chrome mismatches break page rendering and inline event handlers prevent catalog cleanliness — both have to be addressed in the same pass that brings the page onto `cc-shared.*`. The current framing reflects that reality: Phase 1 is one complete pass per page, not a structural skeleton.

---

## 2. Scope

### 2.1 In scope (required for every Phase 1 conversion)

Everything needed for the page to operate cleanly on `cc-shared.*`:

- File-header conformance to the relevant spec (CSS / JS / PS / HTML embedded inside .ps1)
- Section banners in spec form (76-character `=` rules and `-` separators, `TYPE: NAME` title, description block, Prefix line)
- FILE ORGANIZATION list matches body banners exactly
- Section taxonomy and ordering per spec
- Page-side contract identifiers (`<prefix>_ENGINE_PROCESSES`, `<prefix>_init`, page lifecycle hooks like `<prefix>_onPageRefresh`) in their required homes with correct prefix discipline. cc-shared.js resolves these at runtime via `window[cc_pagePrefix + '_<name>']` lookup
- Page-prefix discipline on all page-local identifiers (HTML IDs, CSS classes, JS top-level functions/state/constants)
- Body declares `data-cc-page="<page>"` and `data-cc-prefix="<prefix>"`
- Page CSS and JS consume only `cc-shared.css` and `cc-shared.js`; references to `engine-events.*` are removed
- Chrome class names rendered by the page (in .ps1 markup and in JS that builds HTML) match what `cc-shared.css` actually defines — verified, not assumed
- Inline event handlers migrated to `data-action-<event>` + dispatch table entries
- Per-element event listeners replaced with one delegated listener per event registered inside `<prefix>_init`
- Page JS uses `<prefix>_init` as the entry point; no `DOMContentLoaded` handlers
- Lifecycle hooks (`<prefix>_onPageRefresh`, `<prefix>_onPageResumed`, `<prefix>_onSessionExpired`, `<prefix>_onEngineProcessCompleted`, `<prefix>_onEngineEventRaw`) declared if the page uses them
- All identifier declarations use the spec-required keyword (`const` for CONSTANTS, `var` for STATE; `let` forbidden anywhere)
- All function declarations use the `function name() {}` form (no const arrow, no const function expression at file scope)
- Comment style per spec (block comments at file scope, line comments allowed inside function bodies)

### 2.2 Out of scope

Purely cosmetic catalog drift that does not affect page function, readability, or spec compliance, and that has no impact on subsequent page migrations:

- `EXCESS_BLANK_LINES` on lines that don't affect parsing or readability
- Other purely cosmetic drift codes documented as deferrable in §11

Anything else that would surface as authoring drift after migration is in scope and must be addressed before the page is declared Phase 1 complete.

### 2.3 The "investigation before design" principle

Several Backup-page surprises stemmed from extrapolating shared-file content rather than verifying it. The hard rule for every page migration going forward:

- Before referencing a class name from `cc-shared.css`, confirm the class exists in `cc-shared.css` — not in `engine-events.css` (which may use different names), not in another page's CSS, not in your memory
- Before rendering a `data-action-<event>` value in HTML or JS, confirm the dispatcher (either the page's own dispatch table or `cc-shared.js`'s shared dispatcher) handles that action name
- Before declaring an HTML ID, confirm the ID is referenced from somewhere (JS that consumes it, or shared chrome that depends on it). Chrome IDs (`last-update`, `connection-banner`, `page-error-banner`, engine card IDs) have established names — use exactly those, not page-prefixed variants
- If anything looks ambiguous, fetch the source file and read it. The cost of a fetch is far less than the cost of fixing a class-name guess after deployment

---

## 3. Prerequisites

Before any page enters Phase 1:

- All four populators (CSS, HTML, JS, PS) are at current spec parity, or the known catalog/spec gaps for the in-scope page are documented in §11 with a plan to resolve before drift can be considered representative
- A full backup of the entire CC site and all scripts has been generated (handled externally per session lead)
- The Phase 1 conversion target page has been chosen
- The current catalog state for the target page has been queried and saved for comparison

---

## 4. The four files per page

Every page conversion touches the same four files:

1. **Page route `.ps1`** (e.g., `Backup.ps1`) — emits the page's HTML chrome and content scaffolding
2. **API route `.ps1`** (e.g., `Backup-API.ps1`) — handles the page's API endpoints
3. **Page JS** (e.g., `backup.js`) — page-specific data loading, rendering, and event dispatch
4. **Page CSS** (e.g., `backup.css`) — page-local content styling

Page-shared CSS and JS infrastructure (`cc-shared.css`, `cc-shared.js`) and platform helpers (`xFACts-CCShared.psm1` for migrated pages, `xFACts-Helpers.psm1` for non-migrated) are not in scope for individual page conversions, but page migrations frequently surface gaps in those shared files that need to be addressed before the page can complete. When that happens:

- Fix the shared-file gap first
- Verify the fix doesn't break any other live page (other pages still on `engine-events.*` are unaffected by `cc-shared.*` changes; only pages already migrated need to be re-validated)
- Continue the page migration

---

## 5. Per-file checklists

### 5.1 Page route `.ps1` (e.g. `Backup.ps1`)

| # | Item | Notes |
|---|---|---|
| 1 | File header rewritten to PS spec form: `<# .SYNOPSIS .DESCRIPTION .PARAMETER .COMPONENT .NOTES #>`, with `.NOTES` containing File Name, Location, and FILE ORGANIZATION block | Required by PS spec §2 |
| 2 | All section banners in spec form (76-char `=` rules and `-` separators, `TYPE: NAME` title, description block, Prefix line) | Required by PS spec §3 |
| 3 | FILE ORGANIZATION list matches body banners exactly | Required by PS spec §2.2 |
| 4 | `ROUTE` banner present and named `PAGE PATH` | Required by PS spec §4.4 |
| 5 | RBAC check via `Get-UserAccess` present at top of the route block | Required by PS spec for page-route role |
| 6 | Body HTML emission: `<body class="cc-section-<key>" data-cc-page="<page>" data-cc-prefix="<prefix>">` | Required — bootloader reads `data-cc-page` and `data-cc-prefix`; `cc-section-<key>` drives H1 color routing |
| 7 | Page header rendered via `Get-PageHeaderHtml -PageRoute '/route'` | Helper emits `<h1 class="cc-page-h1 cc-section-<key>"><a class="cc-page-h1-link">...</a></h1>` plus `<p class="cc-page-subtitle">...</p>`; matches cc-shared.css selectors |
| 8 | `<div id="cc-page-error-banner" class="cc-page-error-banner"></div>` placeholder emitted between header bar and content | Required — bootloader uses this to render boot failures |
| 9 | `<div id="cc-connection-banner" class="cc-connection-banner"></div>` placeholder emitted between header bar and content | Required — cc-shared.js connection-state UI uses this |
| 10 | Refresh button uses `data-action-click="cc-page-refresh"` (with the `cc-` prefix) | The shared dispatcher in cc-shared.js handles `cc-*` actions; without the prefix the action falls through unhandled |
| 11 | Engine card HTML uses cc-shared.css class names exactly: `.cc-engine-row`, `.cc-engine-card`, `.cc-engine-label`, `.cc-engine-bar`, `.cc-engine-countdown`, IDs `cc-card-engine-<slug>`, `cc-engine-bar-<slug>`, `cc-engine-cd-<slug>` | These names are required for cc-shared.js to find and update the cards via WebSocket events |
| 12 | Section markup uses `.cc-section`, `.cc-section-header`, `.cc-section-title`, `.cc-section-header-right`, `.cc-refresh-badge-event` / `.cc-refresh-badge-live` / `.cc-refresh-badge-static` / `.cc-refresh-badge-action` | All defined in cc-shared.css; pages compose from these |
| 13 | Modal markup uses single-element nested structure: outer `.cc-modal-overlay` carries the `<prefix>-modal-<purpose>` ID; nested `.cc-modal` child carries no ID. Header / body classes are `.cc-modal-header`, `.cc-modal-body`, `.cc-modal-close` | Per HTML spec §4.3.2 (resolved §11.2.2). Modal close button uses `.cc-modal-close`, not `.modal-close`. Compound modifiers like `.wide`, `.hidden` stay unprefixed per §7.4 |
| 14 | Slideout markup uses `.cc-slide-overlay`, `.cc-slide-panel` (with compound modifiers `.wide` / `.xwide` per §7.4), `.cc-slide-panel-header`, `.cc-slide-panel-title`, `.cc-slide-panel-body`, close button as `.cc-modal-close` (shared between modals and slideouts per cc-shared.css) | Slide overlay and panel are paired sibling elements with separate `<prefix>-slideout-<purpose>-overlay` and `<prefix>-slideout-<purpose>` IDs |
| 15 | All clickable elements declare `data-action-click="<action>"`; no inline `onclick` handlers anywhere | Required for dispatch-table pattern |
| 16 | All page-local IDs and any classes defined by `<page>.css` carry the page prefix (`<prefix>-`); chrome classes and IDs (defined in cc-shared.css) carry the `cc-` prefix per §11.2.4 unified prefix rule. Compound modifiers (`wide`, `hidden`, `open`, `expanded`, `disabled`) stay unprefixed per §7.4 | Catalog cross-resolves prefixed classes against either page CSS (`<prefix>-*`) or cc-shared.css (`cc-*`); compound modifiers resolved per the compound-selector rule |
| 17 | Single `<script src="/js/cc-shared.js">` tag emitted immediately before `</body>` via `Get-PageScriptTagHtml` helper | Required — bootloader is the entry point; old two-script-tag pattern removed |

### 5.2 API route `.ps1` (e.g. `Backup-API.ps1`)

| # | Item | Notes |
|---|---|---|
| 1 | File header rewritten to PS spec form | Required by PS spec §2 |
| 2 | Section banners in spec form (76-char rules, full title, Prefix line) | Required by PS spec §3 |
| 3 | FILE ORGANIZATION list matches body banners | Required by PS spec §2.2 |
| 4 | `ROUTE` banner present and named `API ENDPOINTS` | Required by PS spec §4.4 |
| 5 | Every API route calls `Test-ActionEndpoint` | Required by PS spec §13 |
| 6 | `Invoke-Sqlcmd` calls retain `-TrustServerCertificate -ApplicationName`; SQL stays as here-strings | Required by PS spec |
| 7 | Existing helper functions placed inside `FUNCTIONS` banners with `Prefix: bkp` (or page-equivalent) | Required by PS spec §7 |

### 5.3 Page JS (e.g. `backup.js`)

| # | Item | Notes |
|---|---|---|
| 1 | File header rewritten to JS spec form | Required by JS spec §2 |
| 2 | Section banners in spec form with type, name, description, Prefix line | Required by JS spec §3 |
| 3 | FILE ORGANIZATION list matches body banners | Required by JS spec §2.1 |
| 4 | Page sections organized into IMPORTS / CONSTANTS / STATE / FUNCTIONS taxonomy (no INITIALIZATION section) | Required by JS spec §4.1 |
| 5 | `<prefix>_init` function declared at top level inside FUNCTIONS section | Required — bootloader's call target |
| 6 | Existing `DOMContentLoaded` handler logic moved verbatim into `<prefix>_init` body; DOMContentLoaded handler itself deleted | Required — bootloader handles DOMContentLoaded centrally |
| 7 | `cc_connectEngineEvents()` called from `<prefix>_init` (if the page uses engine cards) | Required — engine card connection depends on this. Function name carries the `cc_` prefix per §11.2.4 |
| 8 | `<prefix>_ENGINE_PROCESSES` declared in `CONSTANTS: ENGINE PROCESSES` banner with `Prefix: <prefix>`; shape is `{ 'Process-Name': { slug: 'slug-value' } }` matching `Orchestrator.ProcessRegistry`. Declared with `var`, not `const`, per JS spec §7.4.4 | Required by JS spec §7.4. The `var` exception exists because cc-shared.js resolves the binding via `window[cc_pagePrefix + '_ENGINE_PROCESSES']` — only `var` and `function` declarations populate the global object in classic scripts |
| 9 | Page lifecycle hook functions (`<prefix>_onPageRefresh`, `<prefix>_onPageResumed`, `<prefix>_onSessionExpired`, `<prefix>_onEngineProcessCompleted`, `<prefix>_onEngineEventRaw`) declared in `FUNCTIONS: PAGE LIFECYCLE HOOKS` banner with `Prefix: <prefix>`; banner is the last banner in the file | Required by JS spec §8. cc-shared.js resolves each hook via `window[cc_pagePrefix + '_<hookSuffix>']` — function declarations populate the global object so no `var` exception is needed |
| 10 | Per-event dispatch tables (`<prefix>_clickActions`, `<prefix>_changeActions`, etc.) declared in a CONSTANTS banner; every `data-action-<event>` value rendered in HTML or JS markup has a matching entry | Required by JS spec for dispatch-driven event handling |
| 11 | One delegated listener per event registered inside `<prefix>_init` on `document.body`; the listener routes through the matching `<prefix>_handle<Event>Action` function which consults the dispatch table | Required by JS spec |
| 12 | Page consumes only `cc-shared.js` for shared functions; no `engine-events.js` references | Required — engine-events is being retired |
| 13 | All top-level identifiers carry the page prefix (`<prefix>_`). The §11.2.4 unified prefix rule removed the prior contract-identifier exemption — `<prefix>_ENGINE_PROCESSES` and `<prefix>_onPageRefresh` etc. are page-prefixed; cc-shared.js resolves them at runtime via `window[<computed-name>]` lookup | Required by JS spec §5 |
| 14 | All function declarations use `function name() { }` form; no `const x = () => { }`, no `const x = function() { }` at file scope | Required by JS spec |
| 15 | `var` for STATE, `const` for CONSTANTS (except `<prefix>_ENGINE_PROCESSES`, which uses `var` per §7.4.4), no `let` anywhere | Required by JS spec §7 |
| 16 | Class names rendered in JS-built HTML match what cc-shared.css defines exactly (verified, not extrapolated) | Required for shared chrome styling to apply |

### 5.4 Page CSS (e.g. `backup.css`)

| # | Item | Notes |
|---|---|---|
| 1 | File header rewritten to CSS spec form | Required by CSS spec §2 |
| 2 | Section banners in spec form with type, name, description, Prefix line | Required by CSS spec §3 |
| 3 | FILE ORGANIZATION list matches body banners | Required by CSS spec §2.1 |
| 4 | Sections organized into the spec's section-type taxonomy | Required by CSS spec §4 |
| 5 | All class names defined in this file carry the page prefix (`<prefix>-`) | Required by CSS spec §5 (Prefix) |
| 6 | No locally-redeclared classes that shadow `cc-shared.css` equivalents — page CSS contains only content rules, not chrome rules | Chrome lives in cc-shared.css; pages compose from chrome classes, they don't redefine them |
| 7 | No duplicate keyframe definitions (e.g., local `pulse`, `spin`) — keyframes consumed from cc-shared.css | Same principle as item 6 |
| 8 | Token references used everywhere (no hex/px literals where a token exists) | Required by CSS spec |
| 9 | No descendant combinators in selectors (use compound class names or variant classes) | Required by CSS spec |

---

## 6. Conversion sequence per page

A Phase 1 conversion runs in this order. Each step is fully completed before the next begins.

1. **Catalog snapshot.** Capture current `Asset_Registry` rows for the target page across all four file types. Save the row counts and drift code distribution.
2. **Backup confirmation.** Confirm the most recent backup includes the target page's four files plus any shared files (`cc-shared.css`, `cc-shared.js`, `xFACts-CCShared.psm1`) that might be modified during the migration.
3. **Fetch current source.** Use the GitHub manifest, project knowledge, or both to retrieve the current versions of the target page's four files plus the shared files needed for cross-reference (`cc-shared.css`, `cc-shared.js`, `xFACts-CCShared.psm1`, relevant specs).
4. **Refactor the four files.** Apply the §5 checklists. Recommended order: page CSS first (defines what's available for the page route to render), then page route .ps1 (consumes those classes), then API route .ps1 (no chrome dependencies), then page JS (renders HTML that consumes cc-shared.css classes for shared chrome and the page CSS for page content).
5. **Audit chrome class names.** Before deployment, do a side-by-side comparison of every chrome class name and ID used in the four files against what `cc-shared.css` actually defines. Don't assume names; look them up. Mismatches caught at this step cost minutes; mismatches caught after deployment cost a debugging cycle.
6. **Deploy the refactored files** to the Control Center server.
7. **Restart Pode** (or whatever restart mechanism the live deployment requires).
8. **Visual validation walkthrough.** Use the checklist in §7. Confirm the page renders correctly and every interaction works.
9. **Console check.** Open browser DevTools console. Confirm no JS errors, no failed network requests, no missing-resource warnings.
10. **Catalog refresh.** Run all four populators (`CSS → HTML → JS → PS`).
11. **Drift review.** Compare post-conversion drift codes against pre-conversion. Authoring drift should go to zero. Any remaining drift should match known catalog tooling or spec gaps documented in §11. If new drift appears that doesn't map to a known gap, investigate before declaring the page complete.
12. **Record the outcome** in §8 below.
13. **Version bump** in `System_Metadata` for each affected component.

---

## 7. Validation walkthrough checklist

Every Phase 1 conversion must pass this walkthrough before being marked complete. Items not applicable to a particular page (e.g., engine cards on a page that doesn't have any) are skipped.

### 7.1 Page chrome

- [ ] Page loads in Control Center without console errors
- [ ] Page title renders in the correct section color (platform = blue, departmental = yellow, tools = light blue, admin = blue)
- [ ] Page title is not underlined and not the link-default color
- [ ] Page title hover changes color to the link-hover color
- [ ] Clicking the page title opens the documentation page in a new tab
- [ ] No extra vertical space below the title when the subtitle is empty
- [ ] Nav bar renders correctly; current page's nav link is highlighted with the section accent color
- [ ] Refresh info row renders correctly with pulsing live indicator
- [ ] Manual page refresh button works and shows the spinning state briefly

### 7.2 Engine cards (if applicable)

- [ ] Engine cards render with their labels (BACKUP, NETWORK, AWS, etc.)
- [ ] Engine bars show appropriate color (idle=green, running=blue, overdue=yellow, critical=red, disabled=gray)
- [ ] Engine countdowns update from WebSocket events
- [ ] Clicking an engine card opens the engine detail popup
- [ ] Engine card popup close button works

### 7.3 Sections

- [ ] All sections render with correct headers, titles, and refresh badges
- [ ] Section content loads correctly
- [ ] Live-polling sections refresh on the configured interval
- [ ] Event-driven sections refresh when their backing orchestrator process completes (verifiable by triggering the process and watching for the section to update)

### 7.4 Modals

- [ ] Clickable cards open their detail modals
- [ ] Modal renders with correct title, body, and close button (X)
- [ ] Modal stays within viewport even when content exceeds 90vh
- [ ] Modal body scrolls internally when content overflows
- [ ] Modal close button (X) works
- [ ] Clicking outside the modal (on the overlay) closes it
- [ ] Modal does not close when clicking inside the modal body

### 7.5 Slideouts

- [ ] Clickable cards open their slideouts (where applicable)
- [ ] Slideout renders with correct title, body, and close button
- [ ] Slideout content is styled correctly (summary stats, accordion headers, tables)
- [ ] Slideout body scrolls when content exceeds available height
- [ ] Accordion headers expand/collapse on click
- [ ] Chevron icons rotate when their accordion expands
- [ ] Slideout close button works
- [ ] Clicking the overlay closes the slideout

### 7.6 Connection and session behavior

- [ ] WebSocket connection establishes on page load
- [ ] Disconnect simulation (stop Pode briefly) shows the disconnected connection banner
- [ ] Reconnect clears the banner
- [ ] Idle overlay activates after the configured inactivity timeout
- [ ] Mouse movement or keypress dismisses the idle overlay
- [ ] Page resume after tab visibility change triggers `<prefix>_onPageResumed` (verifiable by watching for the post-resume refresh)

### 7.7 Console and network

- [ ] Browser console shows no JavaScript errors
- [ ] Network tab shows no failed requests (404, 500, etc.)
- [ ] `cc-shared.css` and `cc-shared.js` load successfully (200 OK)
- [ ] Page CSS and JS load successfully
- [ ] No requests to deleted/legacy paths (e.g., `engine-events.css`, `engine-events.js`)

### 7.8 Page scroll behavior

- [ ] Page scrolls naturally when content overflows the viewport
- [ ] No "stuck" pages where content is clipped below the fold without scroll affordance

---

## 8. Per-page outcomes tracker

Order of conversion is not predetermined. Pages are selected based on impact, complexity, and team availability at each conversion session.

| Page | Phase 1 status | Date | Cumulative drift post-conversion | Notes |
|---|---|---|---|---|
| Backup | complete to Phase 1 expectations | 2026-05-17 (additional changes 2026-05-18) | drift attributed to known populator gaps in §11.1 + one pending CSS spec amendment in §11.2.5 | First page migrated. Validated the bootloader architecture, dispatch-table pattern, prefix discipline, lifecycle hooks, four-file conversion model, and (via the §11.2.4 rename pass) the unified cc-prefixed chrome convention and the route-scoped `Import-Module xFACts-CCShared` mechanic. Surfaced multiple shared-file gaps and populator gaps that are documented in §11. See §8.1 for full write-up. |
| Admin | not started | — | — | High complexity; deferred to later in sequence |
| ApplicationsIntegration | not started | — | — | |
| BatchMonitoring | not started | — | — | ProcessRegistry pre-populated |
| BDLImport | not started | — | — | High complexity; deferred |
| BIDATAMonitoring | not started | — | — | |
| BusinessIntelligence | not started | — | — | |
| BusinessServices | not started | — | — | |
| ClientPortal | not started | — | — | |
| ClientRelations | not started | — | — | |
| DBCCOperations | not started | — | — | |
| DmOperations | not started | — | — | |
| FileMonitoring | not started | — | — | |
| Home | not started | — | — | Minimal page |
| IndexMaintenance | not started | — | — | |
| JBossMonitoring | not started | — | — | |
| JobFlowMonitoring | not started | — | — | |
| PlatformMonitoring | not started | — | — | High complexity; deferred |
| ReplicationMonitoring | not started | — | — | |
| ServerHealth | not started | — | — | High complexity; deferred |

`Phase 1 status` values: `not started`, `in progress`, `complete to Phase 1 expectations`, `blocked` (with reason in Notes).

### 8.1 Backup page outcome (2026-05-17, additional changes 2026-05-18)

Backup was the first page to migrate from `engine-events.*` to `cc-shared.*`. The conversion validated the bootloader architecture end-to-end and surfaced the platform-wide gaps documented in §11. Additional changes followed during the §11.2.4 unified prefix rename pass on 2026-05-18, when the deployment included the platform-wide cc-prefixed chrome convention.

**Files refactored (final line counts after §11.2.4 rename):**
- `Backup.ps1` — 289 lines
- `Backup-API.ps1` — 1,041 lines (not in scope for §11.2.4 rename — API endpoints emit JSON, not HTML)
- `backup.js` — 1,294 lines
- `backup.css` — 703 lines (with `bkp-` prefixed classes throughout, design tokens applied)

**Architecture confirmed working:**
- Shared file consumption: chrome (nav, header, refresh info, engine cards, sections, slideouts, modals, idle overlay) provided by `cc-shared.css`/`cc-shared.js`; page CSS and JS contain only page-specific content
- Bootloader: `<body data-cc-page="backup" data-cc-prefix="bkp">` declares the page; cc-shared.js bootloader injects `/js/backup.js`, captures `cc_pagePrefix = "bkp"`, and calls `bkp_init()`
- Per-event dispatch tables: `bkp_clickActions` maps page-local actions; the shared dispatcher in cc-shared.js handles all `cc-*` actions via `cc_clickActions`
- Page-prefix discipline: all page-local identifiers carry `bkp-` or `bkp_`; chrome identifiers carry `cc-` or `cc_` per the §11.2.4 unified prefix rule; cc-shared.js resolves page-local contract identifiers via `window[cc_pagePrefix + '_<name>']`
- Engine event integration: four orchestrator processes (`Collect-BackupStatus`, `Process-BackupNetworkCopy`, `Process-BackupAWSUpload`, `Process-BackupRetention`) mapped to engine card slugs in `bkp_ENGINE_PROCESSES`; cards update from WebSocket; `bkp_onEngineProcessCompleted` triggers per-process refreshes
- Lifecycle hooks: `bkp_onPageRefresh`, `bkp_onPageResumed`, `bkp_onSessionExpired`, `bkp_onEngineProcessCompleted` all wired and validated
- Module loading mechanic: the route ScriptBlock explicitly `Import-Module xFACts-CCShared` shadows the auto-loaded `xFACts-Helpers` for that route's execution; validated working in production with no cross-route contamination observed

**Status:** Complete to Phase 1 expectations. The page is fully functional, the architecture is validated, and the catalog drift is all attributable to documented populator gaps in §11.1 plus one pending CSS spec amendment in §11.2.5. Once those gaps are resolved, the catalog should refresh to zero drift on this page without further file authoring.

**Final files deployed:** `Backup.ps1`, `Backup-API.ps1`, `backup.js`, `backup.css`. Shared files introduced or modified: `cc-shared.css` (created from `engine-events.css` with the cc-prefixed chrome conventions and the three patches above), `cc-shared.js` (created from `engine-events.js` with cc_ prefixed identifiers and the windowed lookup pattern), `xFACts-CCShared.psm1` (new module providing cc-prefixed nav/header emissions).

---

## 9. Subsequent phases

This document originally anticipated a Phase 2 (inline event handler migration to dispatch tables) and Phase 3+ (chrome consolidation). With Phase 1 reframed as one-pass per page, those phases are no longer needed as separate page passes — both bodies of work happen inside each page's Phase 1 conversion.

Remaining cross-page work after all pages have completed Phase 1:

- **`engine-events.*` retirement.** Once the last page has migrated, delete `engine-events.css`, `engine-events.js`, and any related infrastructure (e.g., references in helpers or planning docs).
- **Catalog tooling refinement.** The catalog tooling and spec gaps documented in §11 may continue to be addressed in parallel with page migrations or after Phase 1 is complete platform-wide; whichever order produces the highest catalog accuracy soonest.
- **Documentation cleanup.** Once `engine-events.*` is retired, planning docs that reference it (this document among them) get archived or updated to historical-only.

A possible Phase 2 may emerge from the catalog data once a meaningful number of pages have migrated — most likely scoped to cross-page patterns that only become visible after the catalog has rows from many pages (e.g., consolidating page-local patterns that several pages independently implemented into shared chrome). That phase will get its own document if and when it materializes.

---

## 10. Cross-references

- `CC_File_Format_Initiative.md` — the umbrella initiative tracker. Phase 1 is the active operational phase under that initiative
- `CC_Catalog_Pipeline_Working_Doc.md` — populator status, schema state, lessons learned
- `CC_CSS_Spec.md`, `CC_JS_Spec.md`, `CC_HTML_Spec.md`, `CC_PS_Spec.md` — the four specs defining what compliant files look like
- `xFACts-CCShared.psm1` — source of `Get-PageHeaderHtml`, `Get-PageBrowserTitle`, `Get-PageScriptTagHtml`, `Get-NavBarHtml`, RBAC helpers, and the shared DB-access functions every migrated page route consumes. The successor to `xFACts-Helpers.psm1`; emits cc-prefixed chrome classes per §11.2.4. Non-migrated pages continue to consume `xFACts-Helpers.psm1` until they migrate
- `xFACts-Helpers.psm1` — legacy helper module, still consumed by non-migrated pages. Retired and deleted once every page has migrated
- `cc-shared.js`, `cc-shared.css` — the new shared anchor files every Phase 1 page consumes
- `Populate-AssetRegistry-CSS.ps1`, `Populate-AssetRegistry-HTML.ps1`, `Populate-AssetRegistry-JS.ps1`, `Populate-AssetRegistry-PS.ps1` — the four populators driving the catalog
- `xFACts-AssetRegistryFunctions.ps1` — shared infrastructure consumed by all four populators

---

## 11. Catalog tooling and spec gap backlog

This section captures every populator defect, spec ambiguity, and shared-file fix discovered during page migrations. Each entry has enough context for a future session to address it without rediscovering the issue. The list is the input to ongoing catalog tooling and spec refinement work.

### 11.1 Populator defects

#### 11.1.1 PS populator — file-header recognition with section dividers

**Source:** Backup migration (2026-05-17).
**Symptom:** PS populator emits `MALFORMED_FILE_HEADER` on a comment-based-help block that is structurally spec-compliant — `.SYNOPSIS`, `.DESCRIPTION`, `.COMPONENT`, `.NOTES` keywords present, FILE ORGANIZATION list present and matching body banners — when the `.NOTES` block uses the spec's File Name / Location fields followed by a `-----------------` separator line above the FILE ORGANIZATION block.
**Root cause:** The populator's header-shape recognizer doesn't accept the spec's exact section-divider style.
**Impact:** Every Phase 1 PS file produces a false-positive `MALFORMED_FILE_HEADER` row.
**Fix scope:** Adjust the header recognizer in `Populate-AssetRegistry-PS.ps1` to accept the spec-compliant `File Name :`, `Location :`, divider, `FILE ORGANIZATION` block pattern.

#### 11.1.2 PS populator — FILE_ORG_MISMATCH false positives

**Source:** Backup migration (2026-05-17).
**Symptom:** PS populator emits `FILE_ORG_MISMATCH` even when the FILE ORGANIZATION list inside `.NOTES` exactly matches the section banner titles in the file body, by content and by order.
**Root cause:** Suspected over-strict normalization or list-vs-banner matching. Needs investigation.
**Impact:** Every Phase 1 PS file produces a false-positive `FILE_ORG_MISMATCH` row that obscures real mismatches.
**Fix scope:** Trace the matcher's expected vs. actual values on a known-good file to identify the divergence.

#### 11.1.3 PS populator — section banner rule lines flagged as forbidden dividers

**Source:** Backup migration (2026-05-17).
**Symptom:** PS populator emits `FORBIDDEN_INLINE_DIVIDER` on the `# ===` opening and closing rule lines of section banners, and on the `# ---` separator line inside the banner description block.
**Root cause:** The forbidden-divider detector doesn't distinguish between rule lines that are part of a section banner (allowed and required by spec) and rule lines that appear free-standing in code (forbidden).
**Impact:** Every Phase 1 PS file produces 6-8 false-positive `FORBIDDEN_INLINE_DIVIDER` rows per banner.
**Fix scope:** Update the detector to skip rule lines that are part of an enclosing recognized banner. Also confirm with the spec whether free-standing inline dividers should remain forbidden or be allowed for readability (related to §11.2.1).

#### 11.1.4 CSS populator — modifier classes defined as compound selectors not resolved

**Source:** Backup migration (2026-05-17). Confirmed cross-populator during post-§11.2.4 drift review.
**Symptom:** CSS USAGE rows for modifier classes like `disabled`, `wide`, `hidden`, used alongside chrome classes (e.g., `<div class="cc-modal wide">`), fire `CLASS_PREFIX_MISMATCH` because the modifier class is "not defined in cc-shared.css." HTML populator surfaces the same false positives on its CSS_CLASS USAGE rows.
**Root cause:** `cc-shared.css` defines these modifiers as compound selectors (`.cc-modal.wide { ... }`, `.cc-engine-bar.disabled { ... }`). The populator's USAGE resolver looks for standalone `.disabled` and `.hidden` DEFINITION rows; compound-only definitions aren't recognized.
**Resolution:** §11.2.3 decided to teach populators to recognize compound-only modifier definitions (Option B/B1). The populator update is pending.
**Fix scope:** Update `Populate-AssetRegistry-CSS.ps1` and `Populate-AssetRegistry-HTML.ps1` USAGE resolvers to recognize compound-only modifier definitions in cc-shared.css as legitimate. Related: the qualification criteria for what counts as a compound modifier is a separate spec gap; see §11.2.5.

#### 11.1.5 HTML populator — slideout body IDs treated as panel definitions

**Source:** Backup migration (2026-05-17). Confirmed in post-§11.2.4 drift.
**Symptom:** HTML populator emits `INCOMPLETE_OVERLAY_PAIR` and `OVERLAY_PANEL_NOT_CONTIGUOUS` on slideouts where the slideout's body element has its own ID (e.g., `<div id="bkp-local-retention-body">`) or where adjacent slideouts are declared as separate paired groups.
**Root cause:** The overlay-pair matcher treats every ID inside a slideout's containing div as a candidate for the overlay/panel pair, and doesn't recognize separate paired groups of slideouts as compliant.
**Fix scope:** Update the matcher to only pair the immediate `.cc-slide-overlay` / `.cc-slide-panel` siblings; ignore IDs on descendant elements. Recognize separate paired-group declarations of slideouts as valid (a page may declare multiple paired slideouts adjacent to each other; each pair stands on its own).

#### 11.1.6 HTML populator — single-element nested modal pattern not recognized

**Source:** Backup migration (2026-05-17). Confirmed in post-§11.2.4 drift.
**Symptom:** HTML populator emits `INCOMPLETE_OVERLAY_PAIR` on the spec-compliant single-element nested modal — outer `.cc-modal-overlay` carrying the ID with a nested `.cc-modal` child carrying no ID.
**Root cause:** The populator's modal-pair detector expects the legacy two-element sibling-overlay-plus-dialog pattern with separate IDs.
**Resolution:** §11.2.2 decided modals are single-element nested constructs (one ID on the outer overlay, nested `.cc-modal` child carries no ID). The HTML spec was amended accordingly.
**Fix scope:** Update `Populate-AssetRegistry-HTML.ps1` modal detection to recognize the nested form: outer overlay with ID, nested dialog with no ID. The `INCOMPLETE_OVERLAY_PAIR` code stays scoped to slideouts and slide-up panels (which remain genuine pair constructs).

#### 11.1.7 HTML and JS populators — `cc-` chrome prefix not recognized

**Source:** Backup migration (2026-05-17). Reframed by §11.2.4 unified prefix rename.
**Symptom:** Both populators flag `MISSING_PREFIX_ID` (HTML) or `JS_HTML_ID_MALFORMED` (JS) on IDs that legitimately carry the `cc-` chrome prefix (`cc-last-update`, `cc-card-engine-<slug>`, `cc-engine-bar-<slug>`, `cc-engine-cd-<slug>`, `cc-page-error-banner`, `cc-connection-banner`).
**Root cause:** The populators' prefix-or-malformed checks predate the §11.2.4 unified prefix rule. They treat every ID as page-local and check only the page's `cc_prefix`; the `cc-` chrome prefix is not in their recognition set.
**Resolution:** §11.2.4 established `cc-` as the canonical chrome prefix for chrome IDs and classes alongside the per-page prefix. The exemption-list approach is no longer needed; the populators just need to recognize `cc-` as a valid alternative prefix on every ID.
**Fix scope:** Update `Populate-AssetRegistry-HTML.ps1` and `Populate-AssetRegistry-JS.ps1` prefix-or-malformed checks to accept either the page's `cc_prefix` or `cc` as the prefix. Update populator descriptions/error messages accordingly.

#### 11.1.8 CSS and JS populators — `MALFORMED_PREFIX_VALUE` on `Prefix: cc` banners

**Source:** Post-§11.2.4 drift review (this session, 2026-05-19).
**Symptom:** CSS and JS populators emit `MALFORMED_PREFIX_VALUE` on every section banner in `cc-shared.css` and `cc-shared.js`. The drift text says: "Banner declares Prefix 'cc' which is neither a 3-char lowercase prefix nor (none)."
**Root cause:** The populators' prefix-value validator still enforces the pre-§11.2.4 rule of "3-char lowercase prefix or `(none)`". The §11.2.4 amendment introduced `cc` as a 2-character accepted value for chrome-anchor files.
**Impact:** Every banner in `cc-shared.css` (8) and `cc-shared.js` (11) produces a false-positive `MALFORMED_PREFIX_VALUE` row. 19 rows total clear with one populator fix.
**Fix scope:** Update the prefix-value validators in `Populate-AssetRegistry-CSS.ps1` and `Populate-AssetRegistry-JS.ps1` to accept `cc` (alongside per-page prefixes and `(none)`) as a legitimate prefix value when the section is in a chrome-anchor file.

#### 11.1.9 JS populator — §7.4.4 ENGINE_PROCESSES carve-out not implemented

**Source:** Post-§11.2.4 drift review and §7.4.4 spec amendment (this session, 2026-05-19).
**Symptom:** JS populator emits `WRONG_DECLARATION_KEYWORD` on `<prefix>_ENGINE_PROCESSES` declared with `var` in a `CONSTANTS: ENGINE PROCESSES` banner. The declaration is spec-compliant per the newly-amended §7.4.4.
**Root cause:** Per JS spec §7.4.4 (amended this session), `<prefix>_ENGINE_PROCESSES` MUST be declared with `var`, not `const`, because cc-shared.js resolves the binding via `window[<computed-name>]` lookup and `const` declarations don't populate `window` in classic scripts. The populator wasn't updated to reflect the carve-out.
**Fix scope:** Update `Populate-AssetRegistry-JS.ps1`:
- Exempt identifiers matching the `<prefix>_ENGINE_PROCESSES` pattern from `WRONG_DECLARATION_KEYWORD` when declared with `var` in a `CONSTANTS: ENGINE PROCESSES` banner.
- Emit the row as `JS_STATE` (not `JS_CONSTANT_VARIANT`) per the amended JS spec §15.4 / §17.6. The ENGINE_PROCESSES-level drift codes (`ENGINE_PROCESS_PAGE_MISMATCH`, `ENGINE_SLUG_JS_MISMATCH`) now attach to the `JS_STATE` row, not `JS_CONSTANT_VARIANT`.

#### 11.1.10 JS populator — UNKNOWN_HOOK_NAME matches full identifier instead of suffix

**Source:** Post-§11.2.4 drift review (this session, 2026-05-19).
**Symptom:** JS populator emits `UNKNOWN_HOOK_NAME` on every page-lifecycle hook (e.g., `bkp_onPageRefresh`) because the populator's recognized-hook set still contains the unprefixed names (`onPageRefresh`, `onPageResumed`, `onSessionExpired`, `onEngineProcessCompleted`, `onEngineEventRaw`).
**Root cause:** Per JS spec §19.3 (amended in §11.2.4 work), `UNKNOWN_HOOK_NAME` is supposed to check the suffix (the part after `<prefix>_`) against the recognized set, not the full identifier. The populator wasn't updated.
**Fix scope:** Update `Populate-AssetRegistry-JS.ps1` UNKNOWN_HOOK_NAME check to strip the file's `cc_prefix` plus underscore from the function name and match the remainder against the recognized hook-suffix set.

#### 11.1.11 JS populator — `MALFORMED_ACTION_KEY` on chrome dispatch entries in cc-shared.js

**Source:** Post-§11.2.4 drift review (this session, 2026-05-19).
**Symptom:** JS populator emits `MALFORMED_ACTION_KEY` on `cc-page-refresh` and `cc-reload-page` dispatch entries in `cc_clickActions` (defined in cc-shared.js). The drift text says: "page-side key starts with 'cc-' which is reserved for shared chrome actions."
**Root cause:** The populator classifies these entries as page-side (scope=LOCAL) when they should be classified as shared chrome (scope=SHARED) since they live in cc-shared.js. The action-key validation rule should be inverted based on scope: scope=SHARED entries MUST start with `cc-`, scope=LOCAL entries must NOT start with `cc-`.
**Fix scope:** Update `Populate-AssetRegistry-JS.ps1` to classify dispatch entries by their containing file (cc-shared.js → SHARED, page files → LOCAL) and apply the appropriate validation rule per scope.

#### 11.1.12 JS populator — runtime-created and fallback chrome IDs flagged as unresolved

**Source:** Post-§11.2.4 drift review (this session, 2026-05-19).
**Symptom:** JS populator emits `JS_HTML_ID_UNRESOLVED` on several IDs in cc-shared.js that legitimately don't appear in any source HTML file:
- `cc-engine-popup`, `cc-engine-idle-overlay` — created at runtime via `document.createElement` and never defined in markup.
- `cc-engine-bar`, `cc-card-engine`, `cc-engine-cd` — single-process fallback IDs (the bare form, no slug suffix) that `cc_getEngineElements` falls back to when a page uses a single engine card without slug-suffixed IDs.
**Root cause:** The populator's USAGE resolver looks up every ID against the HTML_ID DEFINITION catalog. Runtime-created elements never appear in DEFINITION rows, and the single-process fallback pattern isn't recognized as a platform convention.
**Fix scope:** Update `Populate-AssetRegistry-JS.ps1` USAGE resolver to:
- Detect when an ID is created via `document.createElement(...)` + `element.id = '...'` and exempt it from `JS_HTML_ID_UNRESOLVED`.
- Recognize single-process chrome fallback IDs (the bare `cc-engine-bar`, `cc-card-engine`, `cc-engine-cd` forms) as platform conventions and exempt them.

### 11.2 Spec ambiguities and open questions

#### 11.2.1 PS spec — inline divider lines outside banners (RESOLVED)

**Source:** Backup migration (2026-05-17). Resolved in Session 3 (§11.2.1 decision, 2026-05-18).
**Decision:** Free-standing `# ====` and `# ----` divider lines outside section banners remain forbidden. The PS spec's `FORBIDDEN_INLINE_DIVIDER` rule is correct as written. The populator's defect (§11.1.3) is that it doesn't distinguish banner rule lines from free-standing ones; that's a populator fix, not a spec change.

#### 11.2.2 HTML spec / cc-shared.css — modal structure (RESOLVED)

**Source:** Backup migration (2026-05-17). Resolved in Session 3 (§11.2.2 decision, 2026-05-18).
**Decision:** Modals are a single-element nested construct. The outer element carries `.cc-modal-overlay` and exactly one ID (`<prefix>-modal-<purpose>`); the nested `.cc-modal` child carries no ID. HTML spec §4.3.2 amended; new drift code `MALFORMED_MODAL_STRUCTURE` flags missing nested child. The `INCOMPLETE_OVERLAY_PAIR` rule scoped to slideouts and slide-up panels only (which remain genuine pair constructs).

#### 11.2.3 CSS spec / cc-shared.css — compound modifier classes (RESOLVED)

**Source:** Backup migration (2026-05-17). Resolved in Session 3 (§11.2.3 decision, 2026-05-18).
**Decision:** Adopted Option B (CSS populator recognizes compound-only modifier definitions) plus B1 (no carve-outs for `cc-shared.css`; every base class is `cc-`-prefixed; modifiers themselves remain unprefixed). CSS spec §7.4 added defining the compound-modifier pattern; HTML spec rules updated accordingly. Populator implementation pending (see §11.1.4).

#### 11.2.4 JS spec — chrome ID exemption and unified prefix (RESOLVED)

**Source:** Backup migration (2026-05-17). Resolved in Session 3 (§11.2.4 decision, 2026-05-18) as part of the unified prefix rename.
**Decision:** The unified prefix rule established `cc-` as the canonical chrome prefix for both chrome IDs and chrome classes. Page-local IDs carry `<prefix>-`; chrome IDs and classes carry `cc-`. The "exemption list" approach is no longer needed — chrome IDs legitimately begin with `cc-` and are valid alongside page-prefixed IDs. CSS, JS, HTML, and PS specs all amended; downstream rename pass executed across `cc-shared.css`, `cc-shared.js`, `xFACts-CCShared.psm1`, `Backup.ps1`, and `backup.js` during the Backup §11.2.4 deployment. Populator implementation pending (see §11.1.7 and §11.1.8).

#### 11.2.5 CSS spec — compound modifier qualification criteria

**Source:** Post-§11.2.4 drift review (this session, 2026-05-19).
**Question:** CSS spec §7.4 sanctions compound modifier classes (`wide`, `hidden`, `open`, `expanded`, `disabled`) but does not define an explicit test for which classes qualify as compound modifiers. An author writing a new class against the spec cannot determine from the spec text alone whether a given class belongs in the compound-modifier set (unprefixed) or should be a proper sibling chrome class (cc-prefixed). The ambiguity surfaced this session on `slide-auto-height` in cc-shared.css, which was introduced during the §11.2.4 rename as an unprefixed compound modifier but doesn't fit the generic-adjective pattern — it modifies only `.cc-slide-panel` and describes a slide-panel-specific layout variant rather than a generic state or size.
**Proposed resolution:** Amend §7.4 with explicit qualification criteria. Candidate text: "A compound modifier class qualifies for the unprefixed form only when ALL of the following are true: (1) it is a generic adjective describing state, size, or layout behavior; (2) it is or could reasonably be applied to multiple base classes across the codebase; (3) its meaning is consistent regardless of the base it modifies. Classes that only modify a single base, or whose names describe a domain-specific variant rather than a generic adjective, do not qualify and must carry the chrome prefix as proper sibling classes."
**Resolution path:** Next session — CSS spec amendment. Then update `cc-shared.css` line 1056/1065 to either treat `slide-auto-height` as a true compound modifier (compound it consistently with `.cc-slide-panel.slide-auto-height.open`) or promote it to `.cc-slide-auto-height` as a proper sibling class. The choice depends on whether the amended §7.4 admits it as a compound modifier.
**Audit follow-up:** Once the spec amendment lands, audit the rest of `cc-shared.css` for other modifier-pretending-to-be-base patterns. `.medium` on `.cc-modal` is a candidate — only used on modals; might be `cc-modal-medium` instead. The catalog query "list every compound-modifier class and the bases it pairs with" makes this audit mechanical once the populators are caught up.

### 11.3 Shared file gaps fixed during page migrations

This subsection records platform-wide shared-file fixes that page migrations have surfaced. Each fix is described with enough context that the rationale is clear if the fix is later questioned.

#### 11.3.1 cc-shared.css — body viewport reverted to natural document flow

**Source:** Backup migration (2026-05-17).
**Original state:** `body { height: 100vh; overflow: hidden; display: flex; flex-direction: column; }`.
**Reason for fix:** Identical configuration was reverted in `engine-events.css` on 2026-05-05 because pages without explicit `.cc-section.fill` content clipped below the fold on small viewports. `cc-shared.css` carried back the pre-revert configuration when created; needed to be re-reverted.
**Fixed state:** `body { min-height: 100vh; display: flex; flex-direction: column; }` (overflow constraint removed).
**Impact:** Pages on `cc-shared.css` now scroll naturally when content exceeds viewport. Pages still on `engine-events.css` are unaffected because they don't load cc-shared.css.

#### 11.3.2 cc-shared.css — empty subtitle collapses

**Source:** Backup migration (2026-05-17).
**Original state:** No `.cc-page-subtitle:empty` rule.
**Reason for fix:** Pages whose `RBAC_NavRegistry.description` is empty rendered the `<p class="cc-page-subtitle"></p>` placeholder with default paragraph margin, leaving a visible gap below the title.
**Fixed state:** `.cc-page-subtitle:empty { display: none; }` added after the base `.cc-page-subtitle` rule.
**Impact:** Empty subtitles collapse cleanly; pages with subtitle content render unchanged.

#### 11.3.3 cc-shared.css — modal scroll behavior

**Source:** Backup migration (2026-05-17).
**Original state:** `.cc-modal` had no `max-height`; `.cc-modal-body` had no `overflow-y` or `flex` declarations.
**Reason for fix:** Modals with content exceeding viewport height extended beyond the viewport in both directions (centered overflow) with no scroll affordance. User-visible bug on the pipeline-detail and queue-detail modals.
**Fixed state:** `.cc-modal` gets `max-height: 90vh; display: flex; flex-direction: column`; `.cc-modal-body` gets `overflow-y: auto; flex: 1`. Header and footer (if any) stay pinned; body scrolls internally.
**Impact:** Modals on `cc-shared.css` are now viewport-constrained with internal body scroll. Pages still on `engine-events.css` are unaffected.

#### 11.3.4 Helpers module — Get-PageHeaderHtml emits cc-prefixed classes

**Source:** Backup migration (2026-05-17). Updated and migrated to `xFACts-CCShared.psm1` during the §11.2.4 unified prefix rename (Backup deployment, 2026-05-18).
**Original state:** `Get-PageHeaderHtml` in `xFACts-Helpers.psm1` emitted bare `<h1>` and `<a>` tags without classes. Output: `<h1><a href="...">Title</a></h1><p class="page-subtitle">...</p>`.
**Reason for fix:** `cc-shared.css` styles `.cc-page-h1`, `.cc-page-h1.cc-section-<key>`, and `.cc-page-h1-link` selectors. With no classes emitted, none of those selectors match, and the `<a>` falls through to user-agent default styling (underlined, link-color). `engine-events.css` styles bare `h1` and `h1 a` directly, so non-migrated pages were unaffected.
**Fixed state:** `Get-PageHeaderHtml` (now in `xFACts-CCShared.psm1`) emits `<h1 class="cc-page-h1 cc-section-<key>"><a href="..." class="cc-page-h1-link">Title</a></h1><p class="cc-page-subtitle">...</p>`. Section key sourced from the registry's `section_key` field. Pages still on `engine-events.css` consume the legacy `xFACts-Helpers.psm1` module, which still emits the bare form.
**Migration mechanic:** During the cross-over period, migrated pages explicitly `Import-Module xFACts-CCShared` at the top of their route ScriptBlock to shadow the auto-loaded `xFACts-Helpers` for that route's execution. Once every page has migrated, `xFACts-Helpers.psm1` is deleted, `Start-ControlCenter.ps1` is updated to load `xFACts-CCShared.psm1` at startup, and the explicit `Import-Module` lines in route files are removed.
**Impact:** Migrated pages render with the platform section color, no underline, and proper hover behavior. Non-migrated pages continue to consume `xFACts-Helpers.psm1` unchanged.

### 11.4 Process improvements identified

#### 11.4.1 Audit chrome classes before deployment

**Source:** Backup migration (2026-05-17).
**Observation:** Several class-name mismatches between `Backup.ps1`/`backup.js` and `cc-shared.css` were discovered post-deployment when the page rendered incorrectly. They could have been caught pre-deployment by a systematic side-by-side comparison of class names rendered vs. classes defined in cc-shared.css.
**Process change:** Added §6 step 5 "Audit chrome class names" between refactor and deployment.

#### 11.4.2 Investigation before design extends to shared CSS class names

**Source:** Backup migration (2026-05-17). Re-confirmed during the post-§11.2.4 Backup deployment (2026-05-18).
**Observation:** During the Backup conversion, slide-panel content classes were named based on extrapolation rather than verification, producing class names that didn't match what `cc-shared.css` actually defined. The retention slideout rendered unstyled after deployment until the class-name mismatches were corrected. This pattern recurred during the §11.2.4 rename pass — `backup.js` initially emitted `slide-summary`, `slide-stat`, `slide-accordion-*`, `slide-table`, `slide-empty` per the legacy unprefixed form, but cc-shared.css after the rename defined them as `cc-slide-summary`, `cc-slide-stat`, etc.
**Process change:** Added §2.3 "Investigation before design" principle covering CSS class names. Fetch and verify; don't extrapolate. The cost of grepping `cc-shared.css` for every chrome class a page renders is minutes; the cost of catching it post-deployment is a debugging cycle.

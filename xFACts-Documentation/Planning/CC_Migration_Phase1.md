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
- Contract identifiers (`ENGINE_PROCESSES`, lifecycle hooks) in their required homes with the correct prefix discipline
- Page-prefix discipline on all page-local identifiers (HTML IDs, CSS classes, JS top-level functions/state/constants)
- Body declares `data-page="<page>"` and `data-prefix="<prefix>"`
- Page CSS and JS consume only `cc-shared.css` and `cc-shared.js`; references to `engine-events.*` are removed
- Chrome class names rendered by the page (in .ps1 markup and in JS that builds HTML) match what `cc-shared.css` actually defines — verified, not assumed
- Inline event handlers migrated to `data-action-<event>` + dispatch table entries
- Per-element event listeners replaced with one delegated listener per event registered inside `<prefix>_init`
- Page JS uses `<prefix>_init` as the entry point; no `DOMContentLoaded` handlers
- Lifecycle hooks (`onPageRefresh`, `onPageResumed`, `onSessionExpired`, `onEngineProcessCompleted`) declared if the page uses them
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

Page-shared CSS and JS infrastructure (`cc-shared.css`, `cc-shared.js`) and platform helpers (`xFACts-Helpers.psm1`) are not in scope for individual page conversions, but page migrations frequently surface gaps in those shared files that need to be addressed before the page can complete. When that happens:

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
| 6 | Body HTML emission: `<body class="section-<key>" data-page="<page>" data-prefix="<prefix>">` | Required — bootloader reads `data-page` and `data-prefix`; `section-<key>` drives H1 color routing |
| 7 | Page header rendered via `Get-PageHeaderHtml -PageRoute '/route'` | Helper emits `<h1 class="page-h1 section-<key>"><a class="page-h1-link">...</a></h1>` plus `<p class="page-subtitle">...</p>`; matches cc-shared.css selectors |
| 8 | `<div id="page-error-banner" class="page-error-banner"></div>` placeholder emitted between header bar and content | Required — bootloader uses this to render boot failures |
| 9 | `<div id="connection-banner" class="connection-banner"></div>` placeholder emitted between header bar and content | Required — cc-shared.js connection-state UI uses this |
| 10 | Refresh button uses `data-action-click="cc-page-refresh"` (with the `cc-` prefix) | The shared dispatcher in cc-shared.js handles `cc-*` actions; without the prefix the action falls through unhandled |
| 11 | Engine card HTML uses cc-shared.css class names exactly: `.engine-row`, `.engine-card`, `.engine-label`, `.engine-bar`, `.engine-countdown`, IDs `card-engine-<slug>`, `engine-bar-<slug>`, `engine-cd-<slug>` | These names are required for cc-shared.js to find and update the cards via WebSocket events |
| 12 | Section markup uses `.section`, `.section-header`, `.section-title`, `.section-header-right`, `.refresh-badge-event` / `.refresh-badge-live` / `.refresh-badge-static` / `.refresh-badge-action` | All defined in cc-shared.css; pages compose from these |
| 13 | Modal markup uses `.xf-modal-overlay`, `.xf-modal`, `.xf-modal-header`, `.xf-modal-body`, `.xf-modal-close` (close button is `.xf-modal-close`, not `.modal-close`) | These names are exact; spec divergence reported as drift |
| 14 | Slideout markup uses `.slide-overlay`, `.slide-panel`, `.slide-panel.wide` / `.slide-panel.xwide`, `.slide-panel-header`, `.slide-panel-title`, `.slide-panel-body`, with close button as `.xf-modal-close` (shared between modals and slideouts per cc-shared.css) | Slide overlay is `.slide-overlay`, not `.slide-panel-overlay`; the panel itself is `.slide-panel` |
| 15 | All clickable elements declare `data-action-click="<action>"`; no inline `onclick` handlers anywhere | Required for dispatch-table pattern |
| 16 | All page-local IDs and any classes defined by `backup.css` carry the page prefix; chrome classes (defined in cc-shared.css) used unprefixed | Catalog cross-resolves prefixed classes against page CSS and unprefixed against cc-shared.css |
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
| 7 | `connectEngineEvents()` called from `<prefix>_init` (if the page uses engine cards) | Required — engine card connection depends on this |
| 8 | `ENGINE_PROCESSES` const declared in `CONSTANTS: ENGINE PROCESSES` banner with `Prefix: (none)`; shape is `{ 'Process-Name': { slug: 'slug-value' } }` matching `Orchestrator.ProcessRegistry` | Required by JS spec §7.4; contract identifier per §5.5 |
| 9 | Page lifecycle hook functions (`onPageRefresh`, `onPageResumed`, `onSessionExpired`, `onEngineProcessCompleted`) declared in `FUNCTIONS: PAGE LIFECYCLE HOOKS` banner with `Prefix: (none)`; banner is the last banner in the file | Required by JS spec §8 |
| 10 | Per-event dispatch tables (`<prefix>_clickActions`, `<prefix>_changeActions`, etc.) declared in a CONSTANTS banner; every `data-action-<event>` value rendered in HTML or JS markup has a matching entry | Required by JS spec for dispatch-driven event handling |
| 11 | One delegated listener per event registered inside `<prefix>_init` on `document.body`; the listener routes through the matching `<prefix>_handle<Event>Action` function which consults the dispatch table | Required by JS spec |
| 12 | Page consumes only `cc-shared.js` for shared functions; no `engine-events.js` references | Required — engine-events is being retired |
| 13 | All top-level identifiers carry the page prefix (`<prefix>_`) with the exception of `ENGINE_PROCESSES` and the lifecycle hook functions (which are contract identifiers and never prefixed) | Required by JS spec §5 |
| 14 | All function declarations use `function name() { }` form; no `const x = () => { }`, no `const x = function() { }` at file scope | Required by JS spec |
| 15 | `var` for STATE, `const` for CONSTANTS, no `let` anywhere | Required by JS spec |
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
2. **Backup confirmation.** Confirm the most recent backup includes the target page's four files plus any shared files (`cc-shared.css`, `cc-shared.js`, `xFACts-Helpers.psm1`) that might be modified during the migration.
3. **Fetch current source.** Use the GitHub manifest, project knowledge, or both to retrieve the current versions of the target page's four files plus the shared files needed for cross-reference (`cc-shared.css`, `cc-shared.js`, `xFACts-Helpers.psm1`, relevant specs).
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
- [ ] Page resume after tab visibility change triggers `onPageResumed` (verifiable by watching for the post-resume refresh)

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
| Backup | complete to Phase 1 expectations | 2026-05-17 | 24 rows / 1,137 catalog rows (2.1%); all rows are known catalog/spec gaps per §11 | First page migrated. Validated the bootloader architecture, dispatch-table pattern, prefix discipline, lifecycle hooks, and the four-file conversion model. Surfaced multiple shared-file gaps that were fixed in the same session. See §8.1 for full write-up. |
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

### 8.1 Backup page outcome (2026-05-17)

Backup was the first page to migrate from `engine-events.*` to `cc-shared.*`. The conversion validated the bootloader architecture end-to-end and surfaced the platform-wide gaps documented in §11.

**Files refactored (final line counts):**
- `Backup.ps1` — 246 lines
- `Backup-API.ps1` — 1,041 lines
- `backup.js` — 1,287 lines
- `backup.css` — 703 lines (with `bkp-` prefixed classes throughout, design tokens applied)

**Architecture confirmed working:**
- Shared file consumption: chrome (nav, header, refresh info, engine cards, sections, slideouts, modals, idle overlay) provided by `cc-shared.css`/`cc-shared.js`; page CSS and JS contain only page-specific content
- Bootloader: `<body data-page="backup" data-prefix="bkp">` declares the page; cc-shared.js bootloader injects `/js/backup.js` and calls `bkp_init()`
- Per-event dispatch tables: `bkp_clickActions` maps page-local actions; the shared dispatcher in cc-shared.js handles all `cc-*` actions
- Page-prefix discipline: all page-local identifiers carry `bkp-` or `bkp_`; contract identifiers (`ENGINE_PROCESSES`, lifecycle hooks) are unprefixed per spec
- Engine event integration: four orchestrator processes (`Collect-BackupStatus`, `Process-BackupNetworkCopy`, `Process-BackupAWSUpload`, `Process-BackupRetention`) mapped to engine card slugs in `ENGINE_PROCESSES`; cards update from WebSocket; `onEngineProcessCompleted` triggers per-process refreshes
- Lifecycle hooks: `onPageRefresh`, `onPageResumed`, `onSessionExpired`, `onEngineProcessCompleted` all wired and validated

**Cumulative drift post-conversion:**
- `backup.css`: 0 rows
- `Backup-API.ps1`: 4 rows (1 `FILE_ORG_MISMATCH` + 3 banner-rule-line false-positives — all known catalog gaps per §11)
- `backup.js`: 1 row (`JS_HTML_ID_MALFORMED` on `last-update`, the chrome-ID exemption gap per §11)
- `Backup.ps1`: 19 rows (PS file-header recognition + banner-rule-line false-positives + compound-modifier-class resolution gaps + nested modal pattern gaps — all known gaps per §11)
- **Total: 24 rows / 1,137 catalog rows. Zero authoring drift.**

**Shared file gaps caught and fixed during the Backup conversion:**
- `cc-shared.css` body rule used `height: 100vh; overflow: hidden`, which was the same configuration `engine-events.css` had reverted on 2026-05-05 because pages without explicit fill sections clipped below the fold on small viewports. Reverted `cc-shared.css` body to `min-height: 100vh` with natural document flow, matching the engine-events.css revert.
- `cc-shared.css` had no `.page-subtitle:empty { display: none; }` rule, causing visible empty space below the title on pages where the registry's `description` field is empty. Added the collapse rule.
- `cc-shared.css` `.xf-modal` had no `max-height` or scrollable body configuration. Modals with large content (e.g., pipeline-detail file lists) exceeded the viewport with no scroll affordance. Added `max-height: 90vh`, `display: flex; flex-direction: column` to `.xf-modal` and `overflow-y: auto; flex: 1` to `.xf-modal-body`.
- `xFACts-Helpers.psm1` `Get-PageHeaderHtml` emitted bare `<h1>` and `<a>` tags without the `page-h1`, `section-<key>`, or `page-h1-link` classes that `cc-shared.css` selectors target. On Backup (the only page using `cc-shared.css`), this caused the title to render with default link styling (underlined, link-color). Other pages still on `engine-events.css` were unaffected because that file targets bare `h1` and `h1 a`. Updated `Get-PageHeaderHtml` to emit the classes; safe for non-migrated pages because `engine-events.css` ignores the added classes.

**Status:** Complete to Phase 1 expectations. The page is fully functional, the architecture is validated, and the catalog drift is all attributable to documented catalog/spec gaps in §11. Once those gaps are resolved, the catalog should refresh to zero drift on this page without further file authoring.

**Final files deployed:** `Backup.ps1`, `Backup-API.ps1`, `backup.js`, `backup.css`. Shared file edits: `cc-shared.css` (three patches), `xFACts-Helpers.psm1` (one patch in `Get-PageHeaderHtml`).

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
- `xFACts-Helpers.psm1` — source of `Get-PageHeaderHtml`, `Get-PageBrowserTitle`, `Get-PageScriptTagHtml`, `Get-NavBarHtml`, RBAC helpers, and the shared DB-access functions every page route consumes
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

**Source:** Backup migration (2026-05-17).
**Symptom:** CSS USAGE rows for modifier classes like `disabled`, `wide`, `hidden`, used alongside chrome classes (e.g., `<div class="xf-modal wide">`), fire `CLASS_PREFIX_MISMATCH` because the modifier class is "not defined in cc-shared.css."
**Root cause:** `cc-shared.css` defines these modifiers as compound selectors (`.xf-modal.wide { ... }`, `.engine-bar.disabled { ... }`). The populator's USAGE resolver looks for standalone `.disabled` and `.hidden` DEFINITION rows; compound-only definitions aren't recognized.
**Impact:** Every page that uses modifier classes alongside cc-shared.css chrome classes produces false-positive `CLASS_PREFIX_MISMATCH` rows.
**Fix scope:** Either teach the CSS populator to recognize compound-only modifier definitions as legitimate, or add standalone modifier rules in `cc-shared.css`. The first option preserves the current CSS structure; the second adds CSS rules. Decision belongs in §11.2.3.

#### 11.1.5 HTML populator — slideout body IDs treated as panel definitions

**Source:** Backup migration (2026-05-17).
**Symptom:** HTML populator emits `INCOMPLETE_OVERLAY_PAIR` and `OVERLAY_PANEL_NOT_CONTIGUOUS` on slideouts where the slideout's body element has its own ID (e.g., `<div id="bkp-local-retention-body">`). The populator counts the body ID as a third "panel definition," expecting it to pair with another overlay.
**Root cause:** The overlay-pair matcher treats every ID inside a slideout's containing div as a candidate for the overlay/panel pair.
**Impact:** Every page with a slideout that has an ID on its body element produces false-positive overlay-pair drift.
**Fix scope:** Update the matcher to only pair the immediate `.slide-overlay` / `.slide-panel` siblings; ignore IDs on descendant elements.

#### 11.1.6 HTML populator — nested modal pattern not recognized

**Source:** Backup migration (2026-05-17).
**Symptom:** HTML populator emits drift on the nested `.xf-modal-overlay` > `.xf-modal` > `.xf-modal-header` / `.xf-modal-body` structure required for the modal's flex-centering to work.
**Root cause:** The populator's modal-pair detector expects sibling overlay + dialog, not nested overlay containing dialog.
**Impact:** Every page using the cc-shared.css modal pattern produces false-positive drift.
**Fix scope:** Either teach the HTML populator to recognize nested modal structure, or refactor `xf-modal` to use sibling overlay+dialog (CSS-only change, but affects every existing modal). Decision belongs in §11.2.2.

#### 11.1.7 JS populator — chrome IDs not exempted from MALFORMED_ID

**Source:** Backup migration (2026-05-17).
**Symptom:** JS populator emits `JS_HTML_ID_MALFORMED` on `document.getElementById('last-update')` calls because `last-update` doesn't begin with the page's prefix.
**Root cause:** The malformed-ID rule applies uniformly to every ID referenced from JS; there's no carve-out for chrome IDs that are defined by `cc-shared.css`/`cc-shared.js` and intentionally shared across all pages (`last-update`, `connection-banner`, `page-error-banner`, engine card IDs like `card-engine-<slug>`).
**Impact:** Every page that references a chrome ID from JS produces at least one false-positive `JS_HTML_ID_MALFORMED` row.
**Fix scope:** Maintain a list of known chrome IDs in either the JS populator or the spec; exempt them from the prefix-or-malformed rule. Decision belongs in §11.2.4.

### 11.2 Spec ambiguities and open questions

#### 11.2.1 PS spec — inline divider lines outside banners

**Source:** Backup migration (2026-05-17).
**Question:** Should free-standing `# ====` or `# ----` rule lines outside section banners be permitted? Some PS files use them as section dividers inside long functions for readability.
**Current behavior:** PS spec / populator treats them as forbidden (`FORBIDDEN_INLINE_DIVIDER`).
**Preferred behavior (per Dirk):** Allowed for readability inside function bodies.
**Resolution path:** Update PS spec to clarify; update populator to honor the new rule.

#### 11.2.2 HTML spec / cc-shared.css — modal structure

**Source:** Backup migration (2026-05-17).
**Question:** Should `.xf-modal-overlay` continue to use nested overlay > dialog structure (current pattern, required for flex-centering), or should it refactor to sibling overlay + dialog (HTML spec is happier, modal styling needs different CSS)?
**Trade-off:** Nested keeps the current CSS pattern but requires HTML spec / populator amendment. Sibling refactors HTML markup across every page that uses `xf-modal` but keeps the spec strict.
**Resolution path:** Decide, then either amend the HTML spec or refactor `xf-modal` CSS + markup platform-wide.

#### 11.2.3 CSS spec / cc-shared.css — modifier classes

**Source:** Backup migration (2026-05-17).
**Question:** Should modifier classes (`disabled`, `wide`, `hidden`, `xwide`, `medium`, etc.) be defined as standalone rules in `cc-shared.css` so the CSS populator's USAGE resolver finds them, or should the populator be taught to recognize compound-only definitions?
**Trade-off:** Standalone rules add CSS that's never used without a chrome class context (potentially confusing). Teaching the populator is a one-time fix that preserves the current CSS structure.
**Resolution path:** Decide, then either add the standalone rules or update the CSS populator's resolver.

#### 11.2.4 JS spec — chrome ID exemption

**Source:** Backup migration (2026-05-17).
**Question:** Should the JS spec document a list of chrome IDs that are exempt from the prefix-or-malformed rule, or should the JS populator maintain that list internally?
**Trade-off:** Spec documentation makes the exemption discoverable but ties the spec to specific chrome IDs that might change. Populator-internal keeps the spec abstract but hides the list from readers.
**Resolution path:** Decide; either amend the JS spec with a documented list or update the populator with the list plus a comment pointing to the chrome source.

### 11.3 Shared file gaps fixed during page migrations

This subsection records platform-wide shared-file fixes that page migrations have surfaced. Each fix is described with enough context that the rationale is clear if the fix is later questioned.

#### 11.3.1 cc-shared.css — body viewport reverted to natural document flow

**Source:** Backup migration (2026-05-17).
**Original state:** `body { height: 100vh; overflow: hidden; display: flex; flex-direction: column; }`.
**Reason for fix:** Identical configuration was reverted in `engine-events.css` on 2026-05-05 because pages without explicit `.section.fill` content clipped below the fold on small viewports. `cc-shared.css` carried back the pre-revert configuration when created; needed to be re-reverted.
**Fixed state:** `body { min-height: 100vh; display: flex; flex-direction: column; }` (overflow constraint removed).
**Impact:** Pages on `cc-shared.css` now scroll naturally when content exceeds viewport. Pages still on `engine-events.css` are unaffected because they don't load cc-shared.css.

#### 11.3.2 cc-shared.css — empty subtitle collapses

**Source:** Backup migration (2026-05-17).
**Original state:** No `.page-subtitle:empty` rule.
**Reason for fix:** Pages whose `RBAC_NavRegistry.description` is empty rendered the `<p class="page-subtitle"></p>` placeholder with default paragraph margin, leaving a visible gap below the title.
**Fixed state:** `.page-subtitle:empty { display: none; }` added after the base `.page-subtitle` rule.
**Impact:** Empty subtitles collapse cleanly; pages with subtitle content render unchanged.

#### 11.3.3 cc-shared.css — modal scroll behavior

**Source:** Backup migration (2026-05-17).
**Original state:** `.xf-modal` had no `max-height`; `.xf-modal-body` had no `overflow-y` or `flex` declarations.
**Reason for fix:** Modals with content exceeding viewport height extended beyond the viewport in both directions (centered overflow) with no scroll affordance. User-visible bug on the pipeline-detail and queue-detail modals.
**Fixed state:** `.xf-modal` gets `max-height: 90vh; display: flex; flex-direction: column`; `.xf-modal-body` gets `overflow-y: auto; flex: 1`. Header and footer (if any) stay pinned; body scrolls internally.
**Impact:** Modals on `cc-shared.css` are now viewport-constrained with internal body scroll. Pages still on `engine-events.css` are unaffected.

#### 11.3.4 xFACts-Helpers.psm1 — Get-PageHeaderHtml emits classes

**Source:** Backup migration (2026-05-17).
**Original state:** `Get-PageHeaderHtml` emitted bare `<h1>` and `<a>` tags without classes. Output: `<h1><a href="...">Title</a></h1><p class="page-subtitle">...</p>`.
**Reason for fix:** `cc-shared.css` styles `.page-h1`, `.page-h1.section-<key>`, and `.page-h1-link` selectors. With no classes emitted, none of those selectors match, and the `<a>` falls through to user-agent default styling (underlined, link-color). `engine-events.css` styles bare `h1` and `h1 a` directly, so non-migrated pages were unaffected.
**Fixed state:** `Get-PageHeaderHtml` now emits `<h1 class="page-h1 section-<key>"><a href="..." class="page-h1-link">Title</a></h1><p class="page-subtitle">...</p>`. Section key sourced from the registry's `section_key` field. Added classes are ignored by `engine-events.css` selectors, so the helper change is safe for both migrated and non-migrated pages.
**Impact:** Backup's title now renders with the platform section color, no underline, and proper hover behavior. Future page migrations get the right styling automatically.

### 11.4 Process improvements identified

#### 11.4.1 Audit chrome classes before deployment

**Source:** Backup migration (2026-05-17).
**Observation:** Several class-name mismatches between `Backup.ps1`/`backup.js` and `cc-shared.css` were discovered post-deployment when the page rendered incorrectly. They could have been caught pre-deployment by a systematic side-by-side comparison of class names rendered vs. classes defined in cc-shared.css.
**Process change:** Added §6 step 5 "Audit chrome class names" between refactor and deployment.

#### 11.4.2 Investigation before design extends to shared CSS class names

**Source:** Backup migration (2026-05-17).
**Observation:** During the Backup conversion, slide-panel content classes were named based on extrapolation from `.slide-panel-overlay` and `.slide-panel` (which were visible in the markup), assuming the rest of the slideout components would follow the same `slide-panel-` prefix. They don't — cc-shared.css uses `.slide-summary`, `.slide-stat`, `.slide-accordion-*`, `.slide-table-*` without the `-panel` infix.
**Process change:** Added §2.3 "Investigation before design" principle covering CSS class names. Fetch and verify; don't extrapolate.

# Control Center Chrome Standardization Plan

**Created:** April 30, 2026
**Status:** v0.5 - Active execution. Steps 0-3 complete (Backup canonical including modal migration); Step 4 in progress -- JBoss, BIDATA, and BatchMon complete; FileMon and remaining batches pending.
**Owner:** Dirk
**Target File:** `xFACts-Documentation/Planning/CC_Chrome_Standardization_Plan.md`

---

## Purpose

The Control Center pages have grown organically. Each new page was built standalone, with chrome (top-of-page elements like the nav bar, page title, refresh indicator, connection banner) duplicated and slightly modified per page. The Phase 3d work consolidated the nav bar itself but left the rest of the chrome scattered across 19 page CSS files, with subtle differences that have drifted further over time.

This plan establishes a single, documented contract for what every CC page looks like above the content area, consolidates the implementation into shared CSS, and refactors each page to conform.

The goal is captured in a single principle:

> **The top quarter of every Control Center page should look identical, with the only allowed variation coming from declared, documented data sources (page title text, section color, engine cards present).**

---

## Part 1 - The Chrome Contract

This is the plain-English specification of what every CC page looks like, top to bottom, above the content area. This text is now codified in `xFACts_Development_Guidelines.md` Section 5.12.

### 1.1 The Five Chrome Elements

Every CC page renders these elements in this order, with no exceptions:

1. **Nav bar** - Fixed to top of viewport, 40px tall. Rendered by `Get-NavBarHtml`. Contains Home + section links + admin gear (for admins). Standardized in `engine-events.css`.

2. **Page title row** - Below the nav bar, contains:
   - **Left side:** Page H1 (24px) and subtitle (14px gray). Both sourced from `RBAC_NavRegistry` via `Get-PageHeaderHtml`. H1 color is determined by the page's `section_key` (see Section 1.3).
   - **Right side:** Refresh info row, present on every page without exception. Contains the live indicator dot, "Live | Updated: \<timestamp\>", and a refresh button. The timestamp reflects the last actual refresh of any kind: initial page load is the first refresh, and any subsequent polling, websocket update, or manual refresh updates it. Pages with no auto-refresh logic still display the row with the page-load timestamp; the live dot still pulses to indicate the UI is responsive.

3. **Engine cards row** (optional, where applicable) - Below the refresh info row, on the right side. Pages declare which engine cards apply via their HTML; no engine cards if no orchestrator-driven processes feed the page.

4. **Connection banner** (always present, hidden until needed) - Sits between the chrome and the content area. Placeholder in HTML is `<div id="connection-banner" class="connection-banner"></div>`. The legacy `id="connection-error"` and `class="connection-error"` are retired and not used anywhere.

5. **Content area** - Page-specific content begins here. Whatever sections and columns the page needs.

### 1.2 Viewport Constraint Rule

**The page never causes browser-level scroll.** The total height from nav bar to bottom of page never exceeds the viewport. Content sections that overflow scroll **within themselves**, not via the browser's scroll bar.

This means `body` is always viewport-height-constrained with `overflow: hidden` and a flex-column layout. The chrome takes its natural height; the content area fills the remaining space and manages its own internal scrolling.

The standard pattern for sections that need to consume remaining space and scroll internally is the shared `.section-fill` class in `engine-events.css`. Pages apply `.section-fill` to any section that should expand to fill its column's remaining height. Internal content containers within those sections use `flex: 1; overflow-y: auto; min-height: 0`. This pattern replaces the older approach of `max-height: calc(100vh - X)` with hardcoded pixel offsets, which broke when chrome heights changed.

### 1.3 Section Color Mechanism

The page H1 color is determined entirely by which section the page belongs to. This is registry-driven and there are no exceptions or overrides.

The section color palette aligns with the existing nav accent classes:

| Section | Color | Value |
|---|---|---|
| `platform` | Blue | `#569cd6` |
| `departmental` | Yellow | `#dcdcaa` |
| `tools` | Soft blue | `#9cdcfe` |
| `admin` | Blue | `#569cd6` (matches platform - admin pages are part of the platform visual family) |

The mechanism uses a body class. Each route file looks up `section_key` from `RBAC_NavRegistry` and applies it as `<body class="section-{key}">`. Shared CSS rules then key off the body class:

```css
body.section-platform     h1 { color: #569cd6; }
body.section-departmental h1 { color: #dcdcaa; }
body.section-tools        h1 { color: #9cdcfe; }
body.section-admin        h1 { color: #569cd6; }
```

Changing the color for an entire section is a one-line edit. Changing a page's section in the registry automatically updates its color. The colors themselves stay in CSS (where styling belongs) but are driven by data (`section_key`).

This complements the existing nav-link and Home-tile section coloring (which uses `accent_class` from `RBAC_NavSection` applied as `nav-section-X` classes on individual elements). All three surfaces - nav bar accent, Home tile accent, and page H1 - share the same color value per section.

### 1.4 Allowed Per-Page Variations

These are the only deviations from the standard chrome that are permitted.

- **Engine cards present or absent** - declared by the page's HTML. Pages with no orchestrator-driven processes don't render engine cards.
- **Page title and subtitle text** - sourced from `RBAC_NavRegistry`.
- **Section color of H1** - sourced from `section_key` in `RBAC_NavRegistry`.
- **Center-column layout (Server Health only)** - applied via `class="has-center"` on the page's `.header-bar` element. Pulls H1 to the center column.

Anything else is the same on every page.

### 1.5 Slide-Panel and Modal Width Tiers

Shared `.slide-panel` and `.xf-modal` infrastructure from `engine-events.css` provides three width tiers each. Pages select the tier appropriate for their content rather than redefining widths page-locally.

| Tier | `.slide-panel` width | `.xf-modal` width |
|---|---|---|
| Default | 550px | 460px |
| `.wide` | 800px | 800px |
| `.xwide` | 950px | (not defined; rare for modals) |

Production usage as of v0.5:

| Page | Element | Class | Width |
|---|---|---|---|
| Backup | Local Retention slideout | `.slide-panel.wide` | 800px |
| Backup | Network Retention slideout | `.slide-panel.wide` | 800px |
| JBoss | Info modal | `.xf-modal.wide` | 800px |
| JBoss | DM Server Switch modal | `.xf-modal` | 460px |
| BIDATA | Build details slideout | `.slide-panel` | 550px |
| BIDATA | Date range modal | `.xf-modal` | 460px |
| BatchMon | Batch detail slideout | `.slide-panel.xwide` | 950px |

Pages added later in Step 4 should continue selecting from the existing tiers. New tiers should only be added to `engine-events.css` when an existing tier genuinely doesn't fit -- not as an excuse for fine-grained sizing variation.

---

## Part 2 - The Majority-Wins Audit

The audit below documents what was found across the existing CC pages before consolidation. The "majority value" became the shared standard. This is preserved here for posterity; the values themselves are now in `engine-events.css`.

(Audit table omitted in this version of the doc -- see git history of v0.1 through v0.4 for the full audit. Values are codified in the shared CSS and no longer need to live here.)

### 2.8 Platform Nav Accent Color Correction

The platform nav accent was previously rendered as teal (`#4ec9b0`) due to a CSS specificity issue where `.nav-section-platform` rules were never reaching some pages' nav links. The shared `engine-events.css` now sets the platform nav accent to blue (`#569cd6`), matching the Home-tile platform color and the platform H1 color. Visual change applied in Step 2.

---

## Part 3 - Per-Page Detail

### 3.1 Backup (canonical, complete)

Backup served as the proof-of-concept page for the chrome contract. Its CSS, route HTML, and JS were brought into full alignment with the shared infrastructure during Step 3, including migration of its pipeline/queue detail modal from the legacy `.modal-*` pattern to the shared `xf-modal-*` system. The work added three reusable additions to `engine-events.css` (later used by JBoss):

- `.xf-modal.wide` -- 800px modal width tier
- `.xf-modal-overlay.hidden` -- static-toggle visibility pattern (versus the dynamic Promise-based `showAlert`/`showConfirm`)
- `.modal-close` promoted to a top-level shared rule

Two slideouts (Local Retention, Network Retention) use the shared `.slide-panel.wide` class.

### 3.2 JBoss Monitoring (complete)

Completed Apr 30, 2026. Three modal/dialog systems migrated to shared infrastructure in the same session as the chrome alignment:

- **Info modal:** migrated from local `.info-modal` markup to `.xf-modal-overlay.hidden/.xf-modal.wide` with shared `.modal-close`. The info-content sub-components (`.info-list`, `.info-item`, `.info-thresholds`, `.info-green`, `.info-yellow`, `.info-red`, `.info-icon`, `.section-info-icon`) remain in `jboss-monitoring.css` as page content rendered inside the shared modal body. `showInfo()` / `closeInfoModal()` toggle `.hidden` on the overlay.
- **DM Server Switch modal (picker):** migrated from local `.dm-modal-overlay/.dm-modal` (separate sibling elements) to shared `.xf-modal-overlay/.xf-modal/.xf-modal-header/.xf-modal-body` (single nested structure). The picker buttons (`.dm-server-btn`) and status text (`.dm-status`) remain in `jboss-monitoring.css` as page content rendered inside the shared modal body. The legacy `.locked` state is now a `.dm-locked` class on the overlay (renamed for clarity); the descendant selector `.xf-modal-overlay.dm-locked .modal-close` hides the close X during the 90-second switch operation.
- **Confirm dialog:** the local `.confirm-overlay/.confirm-dialog` HTML and the local `showConfirm`/`cancelConfirm`/`executeConfirm`/`pendingConfirm` JS were deleted entirely. The single call site in `selectServer()` now uses the shared Promise-based `showConfirm()` from `engine-events.js` with `confirmClass: 'xf-modal-btn-danger'` for the destructive switch action.

Discovery during this work: the shared `engine-events.js` already provides `showAlert(message, options)` and `showConfirm(message, options)` helpers that return Promises and handle their own overlay lifecycle. These are sufficient for almost all modal needs across the platform; new shared modal helpers should not be required for subsequent page migrations unless we encounter a fundamentally different interaction pattern.

### 3.3 BIDATA Monitoring (complete)

Completed Apr 30, 2026. Single slideout (build details) and single modal (custom date range) both migrated to shared infrastructure.

**Notable changes:**

- Build details slideout migrated from page-local `.slideout/.slideout-overlay/.slideout-content/.slideout-header/.slideout-body/.slideout-close` to shared `.slide-panel-overlay/.slide-panel/.slide-panel-header/.slide-panel-body/.modal-close`. Default 550px width (the new shared default) fits the build summary plus step detail table.
- Date range modal migrated to `.xf-modal-overlay.hidden/.xf-modal/.xf-modal-header/.xf-modal-body/.modal-close/.xf-modal-actions/.xf-modal-btn-cancel/.xf-modal-btn-primary` using the static-toggle pattern.
- Two `.section`s converted to `.section-fill` flex-based height (Build Execution and Build History). Removed `height: 550px` and `max-height: calc(100vh - 380px)` rules.
- Slideout overlay ID renamed `#slideout-overlay` to `#build-slideout-overlay` for unambiguous naming.

**Shared utility promotions during this pass:**

- `escapeHtml()` -- promoted to shared (was duplicated across pages with regex-based and DOM-based variants; the shared version uses the DOM `textContent`/`innerHTML` approach which is the safer pattern).
- `formatTimeOfDay(val)` -- promoted to shared. Handles ISO strings, `.NET /Date(ms)/` format, and Date objects.
- `MONTH_NAMES` -- promoted to shared as a 1-indexed array (so `MONTH_NAMES[12]` returns `'December'`, eliminating off-by-one errors in callers).

**Page-specific items kept local with rationale:**

- `getStatusClass(status)` -- BIDATA-specific status to CSS class mapper.
- `formatDate(dateStr)` -- locale date format only used by BIDATA's status cards. Promote candidate when a 2nd page needs the same format.
- `formatDuration(seconds)` -- BIDATA-specific output as `H:MM:SS`. Companion to BatchMon's `formatDurationMinutes` (`Xm`/`Xh Xm`/`Xd Xh`); two formatters exist intentionally because the output formats differ. Naming convention review pending during the final pass.
- `calculateElapsed(startTimeStr)` -- one-liner only used in BIDATA's IN_PROGRESS card render.
- Render functions, tree toggle functions, and BIDATA-specific data-shape utilities (`formatRunTime`, `calculateEndTime`) all stay local.

### 3.4 BatchMon (complete)

Completed Apr 30, 2026. Single slideout (batch detail) migrated to shared infrastructure. No page-local modals existed to migrate.

**Notable changes:**

- Batch detail slideout migrated from page-local `.slideout/.slideout-overlay/.slideout-content/.slideout-header/.slideout-body/.slideout-close` to shared `.slide-panel-overlay/.slide-panel.xwide/.slide-panel-header/.slide-panel-body/.modal-close`. The `.xwide` tier (950px) matches the page's prior page-local width.
- Slideout overlay ID renamed `#slideout-overlay` to `#batch-slideout-overlay`.
- Active Batches and Batch History sections converted to `.section-fill`. Active Batches table got `position: sticky` on its `<th>` elements so the table header stays visible during scroll.
- Filter button rules consolidated: `.filter-btn` and `.active-filter-btn` had identical styling and are now shared selectors.
- Stripped orphan `.refresh-btn` block (dead code from the legacy section-level refresh button that was replaced by the universal shared `.page-refresh-btn`). All pages now have one shared refresh control; per-section refresh buttons are not used anywhere.
- UTF-8 mojibake (`â€"` artifacts) cleaned in `parseDateOnly` comments to ASCII `--`.

**Shared utility promotions during this pass:**

- `DAY_NAMES` -- 3-letter day-of-week array, 0-indexed to match `Date.getDay()`. Pre-emptive promotion (FileMon also has this constant; promoting now saves redundant work later).
- `safeInt(val)` -- null-safe `parseInt` returning 0 for null/undefined/empty/NaN/'DBNull'. Useful anywhere SQL-derived values are displayed.
- `safeFloat(val)` -- companion to `safeInt`.
- `formatTimeSince(seconds)` -- elapsed formatter (`Xs` / `Xm` / `Xh Xm` / `Xd Xh`).
- `formatAge(minutes)` -- age formatter (same output format, minutes input).

**Page-specific items kept local with rationale:**

- `nbStatusMap`, `nbMergeStatusMap`, `pmtStatusMap` -- DM-specific reference table value translations. Domain knowledge.
- `friendlyStatus(raw, map)` -- generic status-code-to-display translator. Currently only used by BatchMon; promote when a 2nd page needs it.
- `nbStatusBadgeClass`, `pmtStatusBadgeClass`, `bdlStatusBadgeClass` -- DM status code to CSS class mappers. Domain-specific.
- `formatDurationMinutes(minutes)` -- output format `Xm`/`Xh Xm`/`Xd Xh`. Companion to BIDATA's `formatDuration` which takes seconds and outputs `H:MM:SS`. Intentional dual implementation pending naming review during final pass.
- `formatDisplayDate(dateStr)` -- "January 15, 2026" form. Generic but only used by BatchMon today.
- `parseDateOnly(val)` -- returns `YYYY-MM-DD` string for grouping; different intent from `formatTimeOfDay`. Specialized.
- `phaseRow()`, `metricSpan()`, `getBatchOutcome()`, `toggleBatchRow()` -- page-specific component builders for the slideout's batch detail rendering.

### 3.5 Standard pages: FileMon, JobFlow, IndexMaint, DBCC

**Current state:** Standard chrome but with duplicated rules. Each has its own copy of body, h1, page-subtitle, header-bar, header-right, refresh-info, live-indicator, last-updated, connection-error, plus pulse and spin keyframes.

**Per-page changes (route, CSS, JS):**

*Route file:*
- Set `<body class="section-platform">`
- Rename connection banner placeholder: `id="connection-error" class="connection-error"` to `id="connection-banner" class="connection-banner"`

*CSS file:*
- Strip duplicated chrome rules (body, h1, page-subtitle, anchor, header-bar, header-right, refresh-info, live-indicator, last-updated, `@keyframes pulse`, `@keyframes spin`, `.connection-error` block, base `.section` / `.section-header` / `.section-title` rules)
- Restructure section heights to use `.section-fill` flex pattern instead of `max-height: calc(100vh - X)` overrides on inner content elements
- Retain page-specific content rules

*JS file (per Part 7 alignment pattern):*
- Remove local `showError()` / `clearError()` functions if present
- Replace `showError()` call sites with `console.error()` in `.catch()` handlers
- Remove local `pageRefresh()` function if present
- Add `onPageRefresh()` hook (delegates to whatever the page's refresh function is)
- Remove local copies of any utilities that have been promoted to shared (`escapeHtml`, `formatTimeOfDay`, `MONTH_NAMES`, `DAY_NAMES`, `safeInt`, `safeFloat`, `formatTimeSince`, `formatAge`)
- Migrate page-specific modals/dialogs to shared `xf-modal-*` infrastructure if applicable
- Migrate page-specific slideouts to shared `.slide-panel-*` infrastructure if applicable
- Verify `onPageResumed()` and `onSessionExpired()` hooks exist (most pages already have these)
- File-encoding pass: replace any non-ASCII characters with ASCII or HTML entities

**FileMon-specific notes** (heaviest of Batch A; expected to require dedicated session):
- Day Detail slideout (875px page-local width) migrates to `.slide-panel.xwide` (950px)
- New Webhook modal (400px page-local) migrates to `.xf-modal` default (460px)
- Scheduled Monitors modal (480px page-local) migrates to `.xf-modal` default (460px)
- Slide-up management console stays page-specific (unique bottom-anchored UX, not slide-panel-shaped)
- Page-local utility candidates for review: `escAttr(text)`, `fmtTimeOnly(timeStr)`, `fmtTimeInput(timeStr)` -- evaluate whether to promote during the migration

### 3.6 Server Health (center-column page)

Same as Section 3.5 plus:
- Add `class="has-center"` to its `.header-bar` element in the route file's HTML

### 3.7 Replication Monitoring, Platform Monitoring (already viewport-constrained)

Same as Section 3.5 plus:
- Platform Monitoring: rename `.pm-subtitle` to `.page-subtitle` and `.pm-error` to `.connection-banner` in CSS, route HTML, and JS

### 3.8 Departmental pages: Applications & Integration, Business Services, Business Intelligence, Client Relations

Same as Section 3.5 with these adjustments:
- Set `<body class="section-departmental">` on all four route files
- Remove the local `h1 { color: #dcdcaa; }` rule from each page's CSS - color now comes from shared `body.section-departmental h1`
- Apps/Int and BI: **add** the refresh info row HTML per the universal-presence rule. Set the page-load timestamp once on render
- Client Relations: keeps its custom cache indicator since that's content, not chrome

### 3.9 DM Operations

Same as Section 3.5 plus:
- The local `.last-updated { color: #569cd6; }` drift goes away (shared rule provides teal)
- **DmOps slide-panel `.active` to `.open` JS alignment is done in this same sweep** - the shared slide-panel CSS uses `.open` for visibility toggles, but DmOps's JS still toggles `.active`. Update the JS class name references during the JS file pass

### 3.10 Admin Page (significant refactor)

Same as Section 3.5 with these adjustments:
- Refactor route HTML to use `.header-bar` and `.page-subtitle` (drops `.page-header` and `.header-subtitle` entirely)
- Strip Admin-specific body padding override (`75px 40px 0 40px`); shared `body` rule applies
- Rename `pulse-live` keyframe references to `pulse` (shared)
- Set `<body class="section-admin">`
- Keep all timeline/canvas/sidebar/process-row content as page-specific

### 3.11 BDL Import

Same as Section 3.5 with these adjustments:
- Set `<body class="section-tools">`
- Add the refresh info row HTML with page-load timestamp (currently absent)
- Remove `.connection-error { display: none }` override
- All wizard content unchanged
- **Visual change at deploy:** H1 color shifts from `#569cd6` (blue) to `#9cdcfe` (soft blue) per section-color alignment

### 3.12 Client Portal (final cleanup, separate session)

**Status:** Last to be done. Out of scope for the page batch sweep. See Part 4 Step 7.

**Intent:** Refactor to standard chrome (matching every other page) with the portal content embedded inside one large `.section` container that fills the viewport-constrained content area. The current "header card + portal-page divs" pattern goes away.

This is treated separately because it's a structural refactor, not just a CSS cleanup. The page's JS (which uses `.portal-page.active` to switch between Search/Results/Consumer/Account "subpages") needs review, the HTML needs rewriting, and the light-themed portal content area needs to fit cleanly inside the dark CC chrome.

When this work is done, ClientPortal will get `<body class="section-tools">` with the soft-blue H1 like other tools-section pages.

---

## Part 4 - Execution Plan

### Step 0: Approve this plan **[COMPLETE]**

### Step 1: Update `xFACts_Development_Guidelines.md` **[COMPLETE]**

Sections 5.12 (CC Page Chrome Contract), 2.X (File Encoding Standard), and 4.5 step 1.5 (chrome inheritance step) added. v1.6.0 revision history entry added.

### Step 2: Update `engine-events.css` and `engine-events.js` with the shared baseline **[COMPLETE]**

`engine-events.css` reorganized into 11 logical sections with all chrome rules added. Platform nav accent fix applied. Animation keyframes consolidated. The `.section-fill` pattern, `.slide-panel` infrastructure with three width tiers (default 550px, `.wide` 800px, `.xwide` 950px), and `.xf-modal` infrastructure with two width tiers (default 460px, `.wide` 800px) are all in place.

`engine-events.js` provides shared utilities that pages adopt as they migrate: `escapeHtml`, `formatTimeOfDay`, `MONTH_NAMES`, `DAY_NAMES`, `safeInt`, `safeFloat`, `formatTimeSince`, `formatAge`, `showAlert`, `showConfirm`, `engineFetch`, `pageRefresh` (with `onPageRefresh`/`onPageResumed`/`onSessionExpired` hooks). New shared utilities are added during page migrations as identified -- the inventory has grown across the JBoss/BIDATA/BatchMon passes.

### Step 3: Refactor Backup as canonical proof-of-concept **[COMPLETE]**

Backup is fully chrome-aligned end-to-end (CSS + route + JS). All chrome contract elements work correctly: body section class, connection-banner placeholder, viewport constraint, section coloring, refresh info row, engine cards, modals, slideouts. JS aligned with shared chrome (no local error display functions, no local `pageRefresh`, hooks for shared functions in place).

Backup serves as the reference page for all subsequent batch work.

Backlog item discovered (Pipeline Detail timing bug): The `/api/backup/pipeline-detail` endpoint returns empty file lists due to timestamp mismatches between `Orchestrator.TaskLog` and `ServerOps.Backup_ExecutionLog`. Pre-existing bug, unrelated to chrome work. See Part 8.

### Step 4: Sweep remaining pages in batches **[IN PROGRESS]**

Each page sweep is now confirmed to be a **3-file deploy** per page (route .ps1 + page .css + page .js) per Part 7's alignment pattern. Some pages may also have associated API .ps1 files that need attention if they touch chrome - but most do not. Some pages will additionally require an `engine-events.js` deploy when new shared utilities are promoted during the pass.

Pages frequently have their own **modal/dialog systems** that should also be migrated to shared `xf-modal-*` infrastructure during the same sweep. This was added to Part 7's alignment checklist after the Backup decision to fold modal migration into Backup's session rather than defer it. JBoss confirmed the value of this approach -- three modal/dialog systems migrated in the same session as the chrome work, leaving the page fully aligned with no follow-up debt.

Pages also frequently have **page-local slideouts** that should be migrated to shared `.slide-panel-*` infrastructure during the same sweep. Width selection is per the tiers documented in Section 1.5.

Suggested batches (pacing varies by page complexity; pages with multiple modal systems are larger sessions):

- **Batch A:** ~~JBoss~~ (complete), ~~BIDATA~~ (complete), ~~BatchMon~~ (complete), FileMon -- the standard ones
- **Batch B:** JobFlow, IndexMaint, DBCC, ServerHealth (ServerHealth uses center column)
- **Batch C:** Replication, Platform Monitoring (the rename work for PM)
- **Batch D:** Apps/Int, Business Services, Business Intelligence, Client Relations (departmental coloring + refresh info row addition for Apps/Int and BI)
- **Batch E:** BDL Import (refresh info row addition + tools color shift), DM Operations (slide-panel JS alignment)
- **Batch F:** Admin (significant refactor, do alone)

Each page in a batch:
1. Survey the page first (route HTML, page CSS, page JS) before generating changes -- check for unanticipated custom modals, dialogs, or chrome elements
2. Update the route's HTML for body class, connection banner placeholder rename, refresh info row presence, modal HTML migration if applicable, slideout HTML migration if applicable
3. Strip duplicated chrome rules (and any legacy modal/slideout chrome rules if migrating) from the page's CSS, including converting fixed-height sections to `.section-fill` where appropriate
4. Update the page's JS per Part 7 (showError/clearError removal, pageRefresh consolidation, hooks, engineFetch migration, modal helper migration, removal of local utilities now provided by shared)
5. If new shared utilities are promoted during the pass, update `engine-events.js` and deploy first
6. Deploy all files for the page
7. Visually verify the page
8. Update this plan doc with what was completed (per-page subsection in Part 3, plus completion marker on the batch line above)

Pages already complete in Step 4:
- **JBoss Monitoring** (Apr 30, 2026) -- chrome alignment + three modal/dialog migrations to shared infrastructure (see Section 3.2)
- **BIDATA Monitoring** (Apr 30, 2026) -- chrome alignment + slideout/modal migration + 3 utility promotions (`escapeHtml`, `formatTimeOfDay`, `MONTH_NAMES`) (see Section 3.3)
- **BatchMon** (Apr 30, 2026) -- chrome alignment + slideout migration + 5 utility promotions (`DAY_NAMES`, `safeInt`, `safeFloat`, `formatTimeSince`, `formatAge`) (see Section 3.4)

### Step 5: Backup modal migration to shared `xf-modal-*` **[COMPLETE]**

Backup's pipeline/queue detail modal migrated from the legacy custom `.modal-*` pattern to the shared `xf-modal-*` system in `engine-events.css`. Done in the same session as Step 3 to avoid leaving Backup half-aligned. See Section 3.1 for full details.

Side benefit: this work added two reusable variants to `engine-events.css` (`.xf-modal.wide` and `.xf-modal-overlay.hidden`) and promoted `.modal-close` to a shared top-level rule. These were used immediately by JBoss in Step 4 and will be available for all subsequent page migrations.

### Step 6: Brandon's banner re-investigation **[STILL OUTSTANDING]**

Brandon tested Backup after the chrome work was deployed. Result: he still sees the false banner -- but **only on Backup now**, not on the other pages he was previously seeing it on.

This rules out the simpler hypothesis that the issue was a `.connection-error` vs `.connection-banner` markup conflict (Backup is now using the new markup and the issue persists). The fact that it's localized to Backup also rules out a whole-codebase root cause like a session-cookie or auth-redirect race.

Most likely now:
- Something Backup-specific in its WebSocket initialization or JS init order is causing the false connection-state read
- Possibly related to the engine card setup or the `loadAllData` initial fetch sequence
- Could be a state-machine bug where `engineConnectionState` momentarily reports `disconnected` between init steps

Investigation deferred to a dedicated session. To be picked up after Step 4 completes (so we have a fully-aligned codebase to debug from). See Part 8 for the running tracking item.

### Step 7: Client Portal refactor

Separate effort, after the rest of the standardization is complete. Restructure the page HTML to put portal content inside one large `.section` container; strip header-card styling; verify the JS-driven page switching still works inside the new structure. Set `<body class="section-tools">` so H1 renders soft blue.

### Step 8: Archive RBAC working doc

After all chrome work is complete, the RBAC working doc is fully done. Move `RBAC_Working_Document.md` to `Legacy/` per the established pattern.

### Step 9: Final pass review

After every CC page is aligned, do a comprehensive review of what's still NOT shared on each page. Look for:
- Patterns that exist on 2+ pages with similar (or identical) implementations and could be promoted to shared
- Tree toggle functions (year/month expand-collapse) appear on BIDATA, BatchMon, and FileMon -- strong candidate for promotion at this stage
- Duration formatters: BIDATA's `formatDuration` (seconds to H:MM:SS) and BatchMon's `formatDurationMinutes` (minutes to Xm/Xh Xm/Xd Xh) -- decide on naming convention and whether to promote
- Any local utility that ended up duplicated despite our intent during the per-page passes
- CSS classes defined locally that mirror shared classes with minor differences

The `Page_Local_Component_Registry` cataloging effort (see Part 8) will inform this pass with structured data rather than relying on memory or document review.

---

## Part 5 - Development Guidelines Updates **[COMPLETE]**

The following changes were made to `xFACts_Development_Guidelines.md` during Step 1:

1. **Section 5.12 (CC Page Chrome Contract)** added with subsections 5.12.1 through 5.12.6 covering the five chrome elements, viewport constraint rule, section color mechanism, allowed variations, customization scope, and implementation reference.

2. **Section 2.X (File Encoding Standard)** added requiring UTF-8 without BOM, ASCII-only source content, with verification scripts for both PowerShell and bash.

3. **Section 4.5 step 1.5** inserted into the "Adding a New Control Center Page" workflow, covering body section class assignment and chrome inheritance.

4. **Revision History v1.6.0** entry added documenting the additions.

A future Development Guidelines update is anticipated (post-Phase 4) to document the slide-panel/xf-modal width tier system formally and to point to the database-backed shared component registry once that's built (see Part 8).

---

## Part 6 - What This Work Does NOT Cover

Locking scope so we don't drift:

- **Visual design changes** - colors, fonts, spacing, sizing all stay where the majority-wins audit puts them. Two deliberate visual changes are flagged: (1) Platform nav accent corrects from teal to blue per Section 2.8, (2) Tools section H1 shifts from `#569cd6` blue to `#9cdcfe` soft blue per Section 1.3 alignment.
- **JS behavior changes beyond chrome alignment** - per Part 7, JS alignment is in scope. Other JS behavior changes (e.g., new features, refactoring data flow) are not.
- **Engine card visual style** - already shared, not touched.
- **Doc-page RBAC integration** - separate effort, deferred.
- **Adding new chrome elements** - anything not currently shared by 2+ pages stays page-specific until proven otherwise.
- **Schema design for the shared component registry** - the cataloging effort tracked in Part 8 is acknowledged here but its database design is deferred until a dedicated session, ideally informed by the FileMon migration data.

---

## Part 7 - Per-Page JS Alignment Pattern

Discovered during Step 3 (Backup) and refined through subsequent migrations: pages have local copies of chrome-related JS that mirror what `engine-events.js` already provides. These need to be aligned during the page sweep so the shared infrastructure can do its job correctly. This pattern applies to every page in Step 4.

### What to look for in each page's JS

**1. Local `showError()` / `clearError()` functions targeting the connection banner**

Pattern:
```javascript
function showError(message) {
    var errorDiv = document.getElementById('connection-error');
    errorDiv.textContent = message;
    errorDiv.classList.add('visible');
}

function clearError() {
    var errorDiv = document.getElementById('connection-error');
    errorDiv.classList.remove('visible');
}
```

These were misusing the connection-error banner as a generic API-error display. Connection state is now exclusively handled by `updateConnectionBanner()` in `engine-events.js`.

**Action:** Remove both functions entirely. Their callers fall into two categories:

- **`.catch(function(err) { showError(...); })` handlers** - replace with `console.error('descriptive prefix:', err.message);`
- **`if (data.error) { showError(...); return; }` branches inside `.then()` handlers** - replace with `console.error('descriptive prefix:', data.error); return;`
- **`clearError();` calls (typically at the start of successful render paths)** - simply delete them

After this change, API failures log to console instead of displaying as a visible banner. This is consistent with the chrome contract: the connection banner is for connection state, not application errors.

**2. Local `pageRefresh()` function**

Pattern: pages define their own `pageRefresh()` that the universal refresh button calls via `onclick="pageRefresh()"`.

**Action:** Remove the local function. Define `onPageRefresh()` instead, which the shared `pageRefresh` wrapper in `engine-events.js` calls. This gives the shared module control over the spin animation while letting the page handle its own data refresh logic.

**3. Local utility functions that are now shared**

As of v0.5, the following utilities are provided by `engine-events.js` and should be removed from page-local code:

- `escapeHtml(val)` (DOM-based; safer than regex variants)
- `formatTimeOfDay(val)` (handles ISO, `.NET /Date(ms)/`, and Date objects)
- `MONTH_NAMES` (1-indexed; `MONTH_NAMES[12]` is `'December'`)
- `DAY_NAMES` (0-indexed 3-letter; `DAY_NAMES[0]` is `'Sun'`)
- `safeInt(val)`, `safeFloat(val)` (null-safe parse, returns 0)
- `formatTimeSince(seconds)` (`Xs`/`Xm`/`Xh Xm`/`Xd Xh`)
- `formatAge(minutes)` (same output, minutes input)
- `pageRefresh()` (with `onPageRefresh` hook)
- `showAlert(msg, opts)`, `showConfirm(msg, opts)` (Promise-returning replacements for native `alert`/`confirm`)
- `engineFetch(url, options)` (visibility/session-aware fetch wrapper)

**Action:** Remove local copies and update call sites to use shared. If a page has a local utility with a slightly different signature or behavior than the shared version, evaluate whether the page's intent is special (keep local with a comment explaining why) or whether it can switch to the shared version.

**4. `onPageResumed()` and `onSessionExpired()` hooks**

Most pages already have these defined. Verify they exist and that `onSessionExpired()` cleans up any page-specific timers (calling something like `stopLivePolling()`).

**5. Raw `fetch()` calls**

Pages historically used raw `fetch()` for API calls. These should be migrated to `engineFetch()` for consistent tab-visibility/session-expiry/idle-pause handling.

Pattern:
```javascript
// Before
var response = await fetch('/api/endpoint');
var data = await response.json();

// After
var data = await engineFetch('/api/endpoint');
if (!data) return;  // hidden tab or session expired
```

**6. Page-specific modal/dialog migration**

Pages that have their own modal/dialog systems should migrate to shared `xf-modal-*` infrastructure during the same sweep. Two patterns are available:

- **Static-HTML modals** (toggled with `.classList.add/remove('hidden')`): use when the modal HTML is declared in the route file and shown/hidden in response to user actions. Patterns: see Backup pipeline detail modal, BIDATA date range modal.
- **Promise-based dynamic modals**: use shared `showAlert(msg, opts)` and `showConfirm(msg, opts)` when an alert or confirmation needs to be shown programmatically. Returns a Promise. Pattern: see JBoss confirm dialog migration.

**7. Page-specific slideout migration**

Pages with their own slideouts should migrate to shared `.slide-panel-*` infrastructure. Width selection per Section 1.5. Patterns: see BIDATA build details (default 550px), BatchMon batch detail (`.xwide` 950px), Backup retention slideouts (`.wide` 800px).

**8. Native `alert()` and `confirm()` calls**

Replace with shared `showAlert()` / `showConfirm()` for visual consistency with the dark theme. These are async (Promise-returning), so call sites may need slight refactoring to use `.then()` or `await`.

**9. File-encoding pass**

Replace any non-ASCII characters in source files with ASCII or HTML entities to maintain the UTF-8-without-BOM, ASCII-only source content standard. Common artifacts to look for: mojibake (`â€"`, `Ã©`, etc.), raw em-dashes, smart quotes, raw Unicode emoji in JS (use HTML entities like `&#9881;` instead).

---

## Part 8 - Backlog and Deferred Items

Items discovered during this work that are out of scope for the chrome standardization but tracked here for awareness.

### Pipeline Detail timing bug (Backup)

**Discovered:** Step 3 testing.
**Symptom:** `/api/backup/pipeline-detail` returns empty `files` lists for completed pipelines.
**Root cause:** The endpoint joins `Orchestrator.TaskLog` to `ServerOps.Backup_ExecutionLog` on a timestamp-based query that fails when the join window doesn't capture the expected `Backup_ExecutionLog` rows. The TaskLog completion timestamp and the ExecutionLog start/end timestamps don't align as the query assumes.
**Scope:** Likely affects multiple processes that share this logging pattern, not just retention.
**Owner:** Dirk plans to address in a separate session focused on the orchestrator/process scripts.

### Brandon's banner issue

**Status:** Confirmed as a real bug, not a markup conflict.

**Latest test (after Backup chrome deployment):** Brandon still sees the false banner -- but now **only on Backup**, not on the other pages he was previously seeing it on. This rules out the simpler hypothesis that the issue was a `.connection-error` vs `.connection-banner` markup mismatch.

**Implications:**
- The fix is not "make all pages use consistent markup" -- the bug persists after that's done
- It's localized to Backup currently, suggesting either a Backup-specific JS bug or an interaction between Backup's specific init order and the shared infrastructure
- As more pages migrate to the shared chrome, we'll learn whether the issue spreads to them too (suggesting a shared-code bug) or stays Backup-only (suggesting a Backup-specific bug)

**Investigation deferred** to a dedicated session after Step 4 completes. At that point we'll have a fully-aligned codebase and clearer signal about which pages reproduce the issue.

### DBCC disk space alert suppression during CHECKDB FULL

**Status:** Cross-component awareness item from Dirk's broader xFACts roadmap. ServerHealth disk-space alerts should be suppressed or annotated when DBCC CHECKDB FULL is active. Medium priority. Not chrome-related; tracked for awareness in this doc since DBCC is one of the pages we're touching.

### `pageRefresh` shared-module guard cleanup

**Status:** Tracking. The shared `engine-events.js` defines `pageRefresh` inside an `if (typeof pageRefresh !== 'function')` guard for backward compatibility with pages that still define their own local `pageRefresh()`. Once all CC pages have been migrated to the `onPageRefresh()` hook pattern (i.e., Step 4 complete and Step 7 ClientPortal complete), the guard can be removed and the shared definition becomes unconditional.

### `formatTime` migration on Backup

**Status:** Tracking. Backup's local `formatTime()` likely also handles `.NET /Date()/` format like BatchMon's did. Now that the shared `formatTimeOfDay()` handles both ISO and `.NET /Date(ms)/` formats, Backup should migrate to the shared version during a future Backup-touch session. Not a blocker for any Phase 4 work; flagged for the eventual final pass review.

### Shared component registry (database-backed cataloging)

**Status:** Design discussion deferred to a dedicated session, ideally informed by FileMon migration data.

**Concept:** Catalog shared CSS classes, JS functions/constants, page-local utilities, and width-tier usage in database tables rather than markdown documents. The structured data would support refactor impact analysis ("if I change shared `formatTimeOfDay`, which pages use it?"), promotion decisions ("how many pages have a similar local utility?"), and cleanup audits ("which shared classes are not referenced by any page?").

The current per-page kept-local audit (in each page's Section 3.x sub-section) is the documentary precursor to this. As pages are migrated, the audit data accumulates. A test extraction will be done on one page (likely after FileMon completes) to inform the schema design before broader implementation.

The cataloging effort is scoped as platform infrastructure -- analogous to `Object_Registry`/`Object_Metadata` for SQL/PowerShell objects, but covering front-end shared infrastructure. Tables and their objects will be registered in `Object_Registry` once designed.

### Final-pass shared promotion candidates

**Status:** Tracking for Step 9.

Identified during Phase 4 page passes but deferred until the full set of pages is visible:

- **Tree toggle functions** (year/month expand-collapse). Found in BIDATA, BatchMon. FileMon also has similar logic. Strong candidate for shared promotion at Step 9.
- **Duration formatters** -- BIDATA has `formatDuration(seconds)` returning `H:MM:SS`. BatchMon has `formatDurationMinutes(minutes)` returning `Xm/Xh Xm/Xd Xh`. The dual implementation is intentional (different use cases) but the naming is inconsistent. Step 9 should review.
- **Date-grouping helpers** -- BatchMon has `parseDateOnly()`, BIDATA has internal date-string slicing. Promote candidate when a 3rd page needs it.
- **Friendly-status mapping pattern** -- BatchMon has `friendlyStatus(raw, map)` taking a status code and a translation map. Generic enough that other pages may want it.

---

## Revision History

| Version | Date | Description |
|---|---|---|
| 0.1 | 2026-04-30 | Initial draft for review |
| 0.2 | 2026-04-30 | Refresh info row universal (no per-page omission). H1 color palette aligned to nav accent palette: tools shifts to `#9cdcfe`. Platform nav accent corrected from teal to blue (Section 2.8). H1 color overrides eliminated entirely (registry-driven only). Server Health corrected to have 4 engine cards. File encoding standard added to Development Guidelines update. Animation handling clarified (most-common-wins values applied universally, no preserved per-page differences since none were intentional). |
| 0.3 | 2026-04-30 | Steps 0-3 marked complete with results. Plan now reflects active execution rather than pre-execution draft. Added Part 7 (Per-Page JS Alignment Pattern) capturing the discovery from Backup that pages have local `showError`/`clearError` and `pageRefresh` functions that need to be removed and replaced with hooks. Added Part 8 (Backlog and Deferred Items) tracking the Pipeline Detail timing bug, Brandon's banner, and DBCC disk space suppression. Step 4 batch checklist expanded to include JS file changes (3 files per page, not 2). Backup modal migration to `xf-modal-*` system added as Step 5 to ensure it doesn't fall through the cracks. DmOps slide-panel `.active` to `.open` JS alignment moved from "out of scope" to in-scope (handled during the DmOps batch). Open Questions section removed - all answered during execution. Section 1.1 element 4 updated with the connection-banner placeholder ID/class rename. Various status markers ([COMPLETE], [DEPLOYED], [READY TO BEGIN]) added throughout. |
| 0.4 | 2026-04-30 | Backup modal migration completed in same session as Step 3 (Step 5 marked [COMPLETE]; details folded into Section 3.1). JBoss completed as first page in Step 4 (new Section 3.2 with full details; previous catch-all Section 3.2 demoted to Section 3.2.1; per-page table updated). JBoss work added three reusable additions to engine-events.css: `.xf-modal.wide`, `.xf-modal-overlay.hidden`, and a promoted shared `.modal-close` rule. Part 7 expanded with two new alignment items: (5) raw `fetch()` to `engineFetch()` migration for consistent tab-visibility/session-expiry/idle-pause handling, and (6) page-specific modal/dialog migration to shared `xf-modal-*` infrastructure with reference to both available patterns (dynamic `showAlert`/`showConfirm` helpers and static-HTML `.hidden`-toggled modals). Verification checklist expanded to include modal-specific checks. Brandon's banner Part 8 entry updated with the post-Backup-deployment finding: issue persists but is now localized to Backup only, ruling out the markup-conflict hypothesis. Step 6 description rewritten to reflect this. |
| 0.5 | 2026-04-30 | BIDATA and BatchMon completed in Step 4 (new Sections 3.3 and 3.4 with full details, including notable changes, shared utility promotions, and kept-local items). Previous Section 3.2.1 ("Standard pages: BIDATA, BatchMon, FileMon, JobFlow, IndexMaint, DBCC") split: BIDATA promoted to Section 3.3, BatchMon to Section 3.4, the remaining standard-pages section renumbered to Section 3.5 with FileMon-specific notes added. Subsequent sections renumbered (3.3-3.9 became 3.6-3.12). Section 1.5 added documenting the slide-panel and xf-modal width tier system with current production usage table. Section 1.2 expanded to document the `.section-fill` flex pattern explicitly. Part 4 Step 2 description expanded to enumerate the shared utilities now provided by engine-events.js (added `DAY_NAMES`, `safeInt`, `safeFloat`, `formatTimeSince`, `formatAge` during the BIDATA and BatchMon passes). Part 4 Step 4 batch list updated with strikethrough completion markers. Part 7 expanded: item 3 (now "Local utility functions that are now shared") lists the full inventory of utilities pages should remove during their pass; new items 7-9 (slideout migration, native alert/confirm replacement, file-encoding pass) added. Part 4 Step 9 (Final pass review) added as a planned post-migration cleanup pass. Part 8 expanded with four new tracking items: `pageRefresh` shared-module guard cleanup, Backup `formatTime` migration, shared component registry (database-backed cataloging effort), and final-pass shared promotion candidates. Part 6 updated to acknowledge the shared component registry effort as out-of-scope-for-now-but-coming. |

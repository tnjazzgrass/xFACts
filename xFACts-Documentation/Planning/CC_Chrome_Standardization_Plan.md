# Control Center Chrome Standardization Plan

**Created:** April 30, 2026
**Status:** v0.4 - Active execution. Steps 0-3 complete (Backup canonical including modal migration); Step 4 in progress -- JBoss complete; remaining Batch A pages (BIDATA, BatchMon, FileMon) and subsequent batches pending.
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

These are the only deviations from the standard chrome that are permitted. Each requires a documented reason:

| Variation | Where | Reason |
|---|---|---|
| Center-column server selector | Server Health only | Page needs a server picker affecting all displayed metrics; placement in the title row keeps it visible without consuming vertical space |
| No engine cards | Pages without orchestrator-driven processes | Engine cards reflect orchestrator-managed processes only; pages without them have nothing to show |

H1 color is **not** an allowed variation - it is always determined by the page's `section_key` in the registry. Refresh info row is **not** optional - every page has it. Anything else beyond the table above requires a Development Guidelines update first.

### 1.5 What Pages May Customize

Pages own everything below the chrome:
- Section layouts, column counts, custom widgets
- Content-specific styling (e.g., the portal light theme inside Client Portal's content area, the timeline canvas inside Admin)
- Page-specific modals, panels, slideouts (using the shared `xf-modal-*` system; see Part 7)

But the chrome itself - body padding, header-bar layout, h1 sizing, page-subtitle styling, refresh-info layout, live-indicator, last-updated, connection banner, sections used inside engine card rows - is shared and not redefined per page.

---

## Part 2 - Shared CSS Inventory

This section lists everything in `engine-events.css`. All items shown below are now deployed (Step 2 complete). Items marked **[NEW]** were added in this consolidation; items marked **[EXISTING]** were already there; items marked **[FIX]** existed but were corrected.

### 2.1 Base Reset and Body **[NEW - DEPLOYED]**

```css
* { box-sizing: border-box; }

body {
    font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
    margin: 0;
    padding: 20px 40px;
    padding-top: 60px;
    background: #1e1e1e;
    color: #d4d4d4;
    height: 100vh;
    overflow: hidden;
    display: flex;
    flex-direction: column;
}

a { color: #9cdcfe; }
```

### 2.2 Page Header (H1 + Subtitle) **[NEW - DEPLOYED]**

```css
h1 { color: #569cd6; margin: 0 0 2px 0; font-size: 24px; }

body.section-platform     h1 { color: #569cd6; }
body.section-departmental h1 { color: #dcdcaa; }
body.section-tools        h1 { color: #9cdcfe; }
body.section-admin        h1 { color: #569cd6; }

.page-subtitle { color: #888; font-size: 14px; margin: 0; }
```

### 2.3 Header Bar Layout **[NEW - DEPLOYED]**

```css
.header-bar {
    display: flex;
    justify-content: space-between;
    align-items: flex-start;
    margin-bottom: 15px;
    flex-wrap: wrap;
    gap: 8px;
    flex-shrink: 0;
}

.header-right {
    display: flex;
    flex-direction: column;
    align-items: flex-end;
    gap: 12px;
}

/* Server Health center-column opt-in */
.header-bar.has-center { position: relative; }
.header-center {
    position: absolute;
    left: 50%;
    transform: translateX(-50%);
    top: 4px;
}
```

### 2.4 Refresh Info Row **[NEW - DEPLOYED]**

```css
.refresh-info {
    display: flex;
    align-items: center;
    gap: 8px;
    color: #888;
    font-size: 13px;
}

.live-indicator {
    display: inline-block;
    width: 8px;
    height: 8px;
    background: #4ec9b0;
    border-radius: 50%;
    margin-right: 6px;
    animation: pulse 2s infinite;
}

.last-updated { color: #4ec9b0; }
```

Every page renders this row, including pages with no auto-refresh logic. On those pages, the timestamp is set once at page load and the live dot still pulses.

### 2.5 Connection Banner **[EXISTING - UNCHANGED]**

Already in `engine-events.css`. The placeholder element is `<div id="connection-banner" class="connection-banner"></div>` (renamed from `connection-error` during Step 2). State classes added by JS at runtime:

```css
.connection-banner.reconnecting    { ... blue ... }
.connection-banner.disconnected    { ... red ... }
.connection-banner.session-expired { ... amber with sign-in link ... }
.connection-banner.reloading       { ... teal "server reconnected" ... }
```

### 2.6 Section Container Defaults **[NEW - DEPLOYED]**

```css
.section {
    background: #252526;
    border: 1px solid #404040;
    border-radius: 6px;
    padding: 15px;
    margin-bottom: 15px;
    display: flex;
    flex-direction: column;
    overflow: hidden;
}

.section-fill { flex: 1; flex-shrink: 1; min-height: 0; overflow-y: auto; }

.section-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 12px;
    border-bottom: 1px solid #404040;
    padding-bottom: 8px;
    flex-shrink: 0;
}

.section-title {
    font-size: 14px;
    font-weight: 600;
    color: #4ec9b0;
    text-transform: uppercase;
    letter-spacing: 1px;
    margin: 0;
}
```

### 2.7 Common Animations **[NEW - DEPLOYED]**

```css
@keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.5; } }
@keyframes spin { from { transform: rotate(0deg); } to { transform: rotate(360deg); } }

.spinning-gear { display: inline-block; animation: spin 1s linear infinite; }
.spinning      { animation: spin 0.8s ease-in-out; }
```

### 2.8 Nav Bar Accent Color Correction **[FIX - DEPLOYED]**

Platform nav active link color corrected from `#4ec9b0` (teal) to `#569cd6` (blue) so all three section accent surfaces (nav, Home tiles, page H1) share matching colors per section.

### 2.9 Already Shared, No Changes **[EXISTING]**

The following are in `engine-events.css` and stay as-is:

- Engine cards (`.engine-card`, `.engine-row`, `.engine-bar`, `.engine-label`, `.engine-countdown`, status modifiers)
- Engine popup (`.engine-popup` and children)
- Idle overlay (`.idle-overlay`, `.idle-message`)
- Scrollbars (`::-webkit-scrollbar` rules and `scrollbar-width` for Firefox)
- Refresh badges (`.refresh-badge-event`, `.refresh-badge-live`, `.refresh-badge-static`, `.refresh-badge-action`)
- Page refresh button (`.page-refresh-btn`)
- Slide panels (`.slide-panel-overlay`, `.slide-panel`, etc.)
- Styled modal system (`.xf-modal-*`)
- Nav bar base styles
- Nav-section-departmental and nav-section-tools accent classes
- Back link (`.back-link`)

---

## Part 3 - Per-Page Variance Inventory

For each page, what's currently different from the standard and what changes in the cleanup.

### Reference: which chrome elements each page needs

| Page | Section | Refresh info row | Engine cards | Center column | Notes |
|---|---|---|---|---|---|
| /server-health | platform | yes | yes (4 cards) | yes (server selector) | Only page with center column |
| /jboss-monitoring | platform | yes | yes (1: JBOSS) | no | **DONE** - includes migration of info modal, DM picker modal, and confirm dialog to shared infrastructure |
| /jobflow-monitoring | platform | yes | yes | no | |
| /batch-monitoring | platform | yes | yes (NB/PMT/BDL) | no | |
| /backup | platform | yes | yes (BACKUP/NETWORK/AWS/RETENTION) | no | **DONE** - canonical reference page |
| /index-maintenance | platform | yes | yes (placeholder) | no | Engine cards wired but not active |
| /dbcc-operations | platform | yes | yes | no | |
| /bidata-monitoring | platform | yes | yes | no | |
| /file-monitoring | platform | yes | yes | no | |
| /replication-monitoring | platform | yes | yes | no | Already viewport-constrained |
| /dm-operations | platform | yes | yes (placeholder) | no | Engine cards wired but not active. Slide-panel `.active` to `.open` JS alignment to be done in this sweep (see Section 3.6) |
| /platform-monitoring | platform | yes | no | no | Custom layout, no engine cards |
| /admin | admin | yes | no | no | Custom layout |
| /departmental/applications-integration | departmental | yes (page-load timestamp) | no | no | Static landing page; refresh row still rendered |
| /departmental/business-services | departmental | yes | no | no | |
| /departmental/business-intelligence | departmental | yes (page-load timestamp) | no | no | Static landing page; refresh row still rendered |
| /departmental/client-relations | departmental | yes | no | no | Has custom cache indicator alongside standard refresh info |
| /client-portal | tools | yes | no | no | Major refactor - see Section 3.8 |
| /bdl-import | tools | yes (page-load timestamp) | no | no | Wizard-style; refresh row still rendered |

### 3.1 Backup **[COMPLETE]**

Status: Fully aligned, including modal migration. Serves as the canonical reference for all subsequent page work.

Chrome alignment changes:
- Stripped duplicated chrome rules from `backup.css`
- Set `<body class="section-platform">` in route file
- Renamed connection banner placeholder from `id="connection-error" class="connection-error"` to `id="connection-banner" class="connection-banner"`
- Removed local `showError()` and `clearError()` functions from `backup.js`
- Removed local `pageRefresh()` function (uses shared one from `engine-events.js`)
- Added `onPageRefresh()` hook so shared `pageRefresh()` can drive page-specific refresh
- Replaced `showError()` call sites with `console.error()` in `.catch()` handlers and `data.error` branches
- File-encoding cleanup: emoji literals in `.innerHTML` strings replaced with HTML entities

Modal migration changes (done in same session):
- Migrated pipeline/queue detail modal from legacy `.modal/.modal-content/.modal-header/.modal-body` to shared `.xf-modal-overlay/.xf-modal.wide/.xf-modal-header/.xf-modal-body`
- Added `.xf-modal.wide` (800px width variant) to `engine-events.css` for modals containing wide tabular content
- Added `.xf-modal-overlay.hidden` state to `engine-events.css` for modals declared statically in HTML and toggled via JS (complements the existing dynamic-create pattern used by `showAlert`/`showConfirm`)
- Promoted `.modal-close` to a shared top-level rule in `engine-events.css`, used by both slide-panel headers and `xf-modal` headers
- Renamed Backup's modal sub-components from `.modal-summary/.modal-table/.modal-empty` to `.detail-summary/.detail-table/.detail-empty` (they are content rendered inside the shared modal body, not chrome)

### 3.2 JBoss Monitoring **[COMPLETE]**

Status: Fully aligned, including migration of three local modal/dialog systems to shared infrastructure.

Chrome alignment changes:
- Stripped duplicated chrome rules from `jboss-monitoring.css`
- Set `<body class="section-platform">` in route file
- Renamed connection banner placeholder from `id="connection-error" class="connection-error"` to `id="connection-banner" class="connection-banner"`
- Removed local `showError()` and `hideError()` functions from `jboss-monitoring.js`; replaced call sites with `console.error()`
- Removed local `pageRefresh()` function; added `onPageRefresh()` hook
- Migrated raw `fetch()` calls in `loadServerStatus`, `loadQueueStatus`, and `loadRefreshInterval` to `engineFetch()` for consistent session-expiry / idle-pause / hidden-tab handling

Modal migration changes (done in same session):
- **Info modal (help bubbles):** migrated from local `.info-modal-overlay/.info-modal/.info-modal-header/.info-modal-body/.info-modal-close` to shared `.xf-modal-overlay/.xf-modal.wide/.xf-modal-header/.xf-modal-body`. The info-content sub-components (`.info-list`, `.info-item`, `.info-thresholds`, `.info-green`, `.info-yellow`, `.info-red`, `.info-icon`, `.section-info-icon`) remain in `jboss-monitoring.css` as page content rendered inside the shared modal body. `showInfo()` / `closeInfoModal()` toggle `.hidden` on the overlay.
- **DM Server Switch modal (picker):** migrated from local `.dm-modal-overlay/.dm-modal` (separate sibling elements) to shared `.xf-modal-overlay/.xf-modal/.xf-modal-header/.xf-modal-body` (single nested structure). The picker buttons (`.dm-server-btn`) and status text (`.dm-status`) remain in `jboss-monitoring.css` as page content rendered inside the shared modal body. The legacy `.locked` state is now a `.dm-locked` class on the overlay (renamed for clarity); the descendant selector `.xf-modal-overlay.dm-locked .modal-close` hides the close X during the 90-second switch operation.
- **Confirm dialog:** the local `.confirm-overlay/.confirm-dialog` HTML and the local `showConfirm`/`cancelConfirm`/`executeConfirm`/`pendingConfirm` JS were deleted entirely. The single call site in `selectServer()` now uses the shared Promise-based `showConfirm()` from `engine-events.js` with `confirmClass: 'xf-modal-btn-danger'` for the destructive switch action.

Discovery during this work: the shared `engine-events.js` already provides `showAlert(message, options)` and `showConfirm(message, options)` helpers that return Promises and handle their own overlay lifecycle. These are sufficient for almost all modal needs across the platform; new shared modal helpers should not be required for subsequent page migrations unless we encounter a fundamentally different interaction pattern.

### 3.2.1 Standard pages: BIDATA, BatchMon, FileMon, JobFlow, IndexMaint, DBCC

**Current state:** Standard chrome but with duplicated rules. Each has its own copy of body, h1, page-subtitle, header-bar, header-right, refresh-info, live-indicator, last-updated, connection-error, plus pulse and spin keyframes.

**Per-page changes (route, CSS, JS):**

*Route file:*
- Set `<body class="section-platform">`
- Rename connection banner placeholder: `id="connection-error" class="connection-error"` to `id="connection-banner" class="connection-banner"`

*CSS file:*
- Strip duplicated chrome rules (body, h1, page-subtitle, anchor, header-bar, header-right, refresh-info, live-indicator, last-updated, `@keyframes pulse`, `@keyframes spin`, `.connection-error` block, base `.section` / `.section-header` / `.section-title` rules)
- Retain page-specific content rules

*JS file (per Part 7 alignment pattern):*
- Remove local `showError()` / `clearError()` functions if present
- Replace `showError()` call sites with `console.error()` in `.catch()` handlers
- Remove local `pageRefresh()` function if present
- Add `onPageRefresh()` hook (delegates to whatever the page's refresh function is)
- Verify `onPageResumed()` and `onSessionExpired()` hooks exist (most pages already have these)
- File-encoding pass: replace any non-ASCII characters with ASCII or HTML entities

### 3.3 Server Health (center-column page)

Same as Section 3.2.1 plus:
- Add `class="has-center"` to its `.header-bar` element in the route file's HTML

### 3.4 Replication Monitoring, Platform Monitoring (already viewport-constrained)

Same as Section 3.2.1 plus:
- Platform Monitoring: rename `.pm-subtitle` to `.page-subtitle` and `.pm-error` to `.connection-banner` in CSS, route HTML, and JS

### 3.5 Departmental pages: Applications & Integration, Business Services, Business Intelligence, Client Relations

Same as Section 3.2.1 with these adjustments:
- Set `<body class="section-departmental">` on all four route files
- Remove the local `h1 { color: #dcdcaa; }` rule from each page's CSS - color now comes from shared `body.section-departmental h1`
- Apps/Int and BI: **add** the refresh info row HTML per the universal-presence rule. Set the page-load timestamp once on render
- Client Relations: keeps its custom cache indicator since that's content, not chrome

### 3.6 DM Operations

Same as Section 3.2.1 plus:
- The local `.last-updated { color: #569cd6; }` drift goes away (shared rule provides teal)
- **DmOps slide-panel `.active` to `.open` JS alignment is done in this same sweep** - the shared slide-panel CSS uses `.open` for visibility toggles, but DmOps's JS still toggles `.active`. Update the JS class name references during the JS file pass

### 3.7 Admin Page (significant refactor)

Same as Section 3.2.1 with these adjustments:
- Refactor route HTML to use `.header-bar` and `.page-subtitle` (drops `.page-header` and `.header-subtitle` entirely)
- Strip Admin-specific body padding override (`75px 40px 0 40px`); shared `body` rule applies
- Rename `pulse-live` keyframe references to `pulse` (shared)
- Set `<body class="section-admin">`
- Keep all timeline/canvas/sidebar/process-row content as page-specific

### 3.8 BDL Import

Same as Section 3.2.1 with these adjustments:
- Set `<body class="section-tools">`
- Add the refresh info row HTML with page-load timestamp (currently absent)
- Remove `.connection-error { display: none }` override
- All wizard content unchanged
- **Visual change at deploy:** H1 color shifts from `#569cd6` (blue) to `#9cdcfe` (soft blue) per section-color alignment

### 3.9 Client Portal (final cleanup, separate session)

**Status:** Last to be done. Out of scope for the page batch sweep. See Part 4 Step 6.

**Intent:** Refactor to standard chrome (matching every other page) with the portal content embedded inside one large `.section` container that fills the viewport-constrained content area. The current "header card + portal-page divs" pattern goes away.

This is treated separately because it's a structural refactor, not just a CSS cleanup. The page's JS (which uses `.portal-page.active` to switch between Search/Results/Consumer/Account "subpages") needs review, the HTML needs rewriting, and the light-themed portal content area needs to fit cleanly inside the dark CC chrome.

When this work is done, ClientPortal will get `<body class="section-tools">` with the soft-blue H1 like other tools-section pages.

---

## Part 4 - Execution Plan

### Step 0: Approve this plan **[COMPLETE]**

### Step 1: Update `xFACts_Development_Guidelines.md` **[COMPLETE]**

Sections 5.12 (CC Page Chrome Contract), 2.X (File Encoding Standard), and 4.5 step 1.5 (chrome inheritance step) added. v1.6.0 revision history entry added.

### Step 2: Update `engine-events.css` and `engine-events.js` with the shared baseline **[COMPLETE]**

`engine-events.css` reorganized into 11 logical sections with all chrome rules added. Platform nav accent fix applied. Animation keyframes consolidated.

`engine-events.js` updated: `getElementById('connection-error')` calls renamed to `getElementById('connection-banner')` at three call sites in `updateConnectionBanner()` and `showReloadingBanner()`.

### Step 3: Refactor Backup as canonical proof-of-concept **[COMPLETE]**

Backup is fully chrome-aligned end-to-end (CSS + route + JS). All chrome contract elements work correctly: body section class, connection-banner placeholder, viewport constraint, section coloring, refresh info row, engine cards, modals, slideouts. JS aligned with shared chrome (no local error display functions, no local `pageRefresh`, hooks for shared functions in place).

Backup serves as the reference page for all subsequent batch work.

Backlog item discovered (Pipeline Detail timing bug): The `/api/backup/pipeline-detail` endpoint returns empty file lists due to timestamp mismatches between `Orchestrator.TaskLog` and `ServerOps.Backup_ExecutionLog`. Pre-existing bug, unrelated to chrome work. See Part 8.

### Step 4: Sweep remaining pages in batches **[IN PROGRESS]**

Each page sweep is now confirmed to be a **3-file deploy** per page (route .ps1 + page .css + page .js) per Part 7's alignment pattern. Some pages may also have associated API .ps1 files that need attention if they touch chrome - but most do not.

Important addition learned during JBoss work: pages frequently have their own **modal/dialog systems** that should also be migrated to shared `xf-modal-*` infrastructure during the same sweep. This was added to Part 7's alignment checklist after the Backup decision to fold modal migration into Backup's session rather than defer it. JBoss confirmed the value of this approach -- three modal/dialog systems migrated in the same session as the chrome work, leaving the page fully aligned with no follow-up debt.

Suggested batches (pacing varies by page complexity; pages with multiple modal systems are larger sessions):

- **Batch A:** ~~JBoss~~ (complete), BIDATA, BatchMon, FileMon -- the standard ones
- **Batch B:** JobFlow, IndexMaint, DBCC, ServerHealth (ServerHealth uses center column)
- **Batch C:** Replication, Platform Monitoring (the rename work for PM)
- **Batch D:** Apps/Int, Business Services, Business Intelligence, Client Relations (departmental coloring + refresh info row addition for Apps/Int and BI)
- **Batch E:** BDL Import (refresh info row addition + tools color shift), DM Operations (slide-panel JS alignment)
- **Batch F:** Admin (significant refactor, do alone)

Each page in a batch:
1. Survey the page first (route HTML, page CSS, page JS) before generating changes -- check for unanticipated custom modals, dialogs, or chrome elements
2. Update the route's HTML for body class, connection banner placeholder rename, refresh info row presence, modal HTML migration if applicable
3. Strip duplicated chrome rules (and any legacy modal chrome rules if migrating modals) from the page's CSS
4. Update the page's JS per Part 7 (showError/clearError removal, pageRefresh consolidation, hooks, engineFetch migration, modal helper migration)
5. Deploy all files for the page
6. Visually verify the page
7. Update this plan doc with what was completed

Pages already complete in Step 4:
- **JBoss Monitoring** (Apr 30, 2026) -- chrome alignment + three modal/dialog migrations to shared infrastructure

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

---

## Part 5 - Development Guidelines Updates **[COMPLETE]**

The following changes were made to `xFACts_Development_Guidelines.md` during Step 1:

1. **Section 5.12 (CC Page Chrome Contract)** added with subsections 5.12.1 through 5.12.6 covering the five chrome elements, viewport constraint rule, section color mechanism, allowed variations, customization scope, and implementation reference.

2. **Section 2.X (File Encoding Standard)** added requiring UTF-8 without BOM, ASCII-only source content, with verification scripts for both PowerShell and bash.

3. **Section 4.5 step 1.5** inserted into the "Adding a New Control Center Page" workflow, covering body section class assignment and chrome inheritance.

4. **Revision History v1.6.0** entry added documenting the additions.

---

## Part 6 - What This Work Does NOT Cover

Locking scope so we don't drift:

- **Visual design changes** - colors, fonts, spacing, sizing all stay where the majority-wins audit puts them. Two deliberate visual changes are flagged: (1) Platform nav accent corrects from teal to blue per Section 2.8, (2) Tools section H1 shifts from `#569cd6` blue to `#9cdcfe` soft blue per Section 1.3 alignment.
- **JS behavior changes beyond chrome alignment** - per Part 7, JS alignment is in scope. Other JS behavior changes (e.g., new features, refactoring data flow) are not.
- **Engine card visual style** - already shared, not touched.
- **Doc-page RBAC integration** - separate effort, deferred.
- **Adding new chrome elements** - anything not currently shared by 2+ pages stays page-specific until proven otherwise.

---

## Part 7 - Per-Page JS Alignment Pattern

Discovered during Step 3 (Backup): pages have local copies of chrome-related JS that mirror what `engine-events.js` already provides. These need to be aligned during the page sweep so the shared infrastructure can do its job correctly. This pattern applies to every page in Step 4.

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

Pattern:
```javascript
function pageRefresh() {
    var btn = document.querySelector('.page-refresh-btn');
    if (btn) {
        btn.classList.add('spinning');
        btn.addEventListener('animationend', function() {
            btn.classList.remove('spinning');
        }, { once: true });
    }
    refreshAll();   // or whatever the page calls its refresh worker
}
```

`engine-events.js` provides a defensive `pageRefresh()` that handles the spin animation and calls `onPageRefresh()` if defined. The local definition wins over the shared one because page JS loads first, leaving the shared version unused.

**Action:**
- Remove the local `pageRefresh()` function entirely
- Add `function onPageRefresh() { refreshAll(); }` (or whatever the page's refresh worker is named) so the shared `pageRefresh()` can delegate to it
- The button spin animation, the `animationend` cleanup, and the dispatch to `onPageRefresh()` are all handled by the shared function

**3. Other engine-events hooks (typically already present)**

Most pages already define these correctly:
- `function onPageResumed()` - fires when tab becomes visible after being hidden
- `function onSessionExpired()` - fires when JS detects auth has expired
- `function onEngineProcessCompleted(processName, event)` - fires when a tracked process completes via WebSocket (only on pages with engine cards)

**Action:** Verify these exist and are sensible. No changes needed if they're already wired up.

**4. File encoding pass**

Per the encoding standard added in Step 1:
- Search for any non-ASCII bytes in the JS source
- Replace emoji/Unicode literals in `.innerHTML` strings with HTML entities (browser renders them identically)
- Replace em-dashes, en-dashes, curly quotes, ellipsis characters, Unicode arrows, Unicode bullets in code/comments with their ASCII equivalents

**5. Raw `fetch()` calls in API loaders**

Pattern:
```javascript
fetch('/api/some-endpoint').then(function(r){return r.json();}).then(function(data){
    // ...handle data...
});
```

The shared `engineFetch()` in `engine-events.js` provides consistent handling of tab visibility (skips fetches when tab is hidden), session expiry (detects auth redirects and stops polling), and idle pause (skips fetches when user is idle). Pages mixing raw `fetch` and `engineFetch` produce inconsistent behavior -- some calls keep firing when the tab is hidden, others don't.

**Action:** Migrate all raw `fetch()` calls in API loaders to `engineFetch()`:

```javascript
// Before
fetch('/api/some-endpoint').then(function(r){return r.json();}).then(function(data){
    if (data.error) showError(data.error);
    // ...
}).catch(function(err) { showError(err.message); });

// After
engineFetch('/api/some-endpoint').then(function(data) {
    if (!data) return;  // hidden tab or session expired
    if (data.error) { console.error('endpoint failed:', data.error); return; }
    // ...
}).catch(function(err) { console.error('Failed to load endpoint:', err.message); });
```

Note: `engineFetch()` returns `null` when the tab is hidden, session is expired, or the page is idle-paused. Always check `if (!data) return;` before processing.

**6. Page-specific modals or dialogs**

If the page has its own modal/dialog system (e.g., `.info-modal-*`, `.dm-modal-*`, `.confirm-overlay`), migrate it to the shared `xf-modal-*` infrastructure as part of the same session. Two patterns are available:

- **For dynamic alerts/confirms:** use the shared `showAlert(message, options)` and `showConfirm(message, options)` helpers from `engine-events.js`. Both return Promises. `showConfirm` accepts a `confirmClass` option (`xf-modal-btn-primary`, `xf-modal-btn-danger`) for the action button styling.

- **For async-content modals (open empty, populate via API call, close on user action):** declare the modal HTML statically in the route file using `xf-modal-overlay/.xf-modal/.xf-modal-header/.xf-modal-body` with the `.hidden` class on the overlay as initial state. Page JS toggles `.hidden` to show/hide. Body content can include any page-specific sub-components (rename them away from `modal-*` prefix to avoid implying chrome ownership; e.g., `.modal-summary` becomes `.detail-summary`).

Available `xf-modal` variants:
- Default 460px width (suits `showAlert`/`showConfirm` and simple modals)
- `.xf-modal.wide` (800px) for modals with tabular content
- `.xf-modal-overlay.hidden` for static-HTML modals toggled via JS

Backup and JBoss serve as reference implementations for both patterns.

### Verification per page after JS update

- Page loads completely (no infinite "Loading..." stuck states)
- No console errors on initial page load
- Manual refresh button works (button spins, data reloads)
- All page-specific interactions still work (modals, slideouts, click handlers)
- If modals were migrated:
  - Each modal opens correctly via its trigger
  - Each modal closes correctly via the X button and via clicking the overlay (where supported)
  - Modal content renders correctly (titles, body content, action buttons)
  - Confirm dialogs return correct truthy/falsy via the Promise chain
- Connection banner test: while page is open, restart the CC service - "Reconnecting" banner appears, "Server reconnected, reloading" appears briefly, page auto-reloads

---

## Part 8 - Backlog and Deferred Items

Items discovered or accumulated during chrome standardization that are out of scope for this work but need to be tracked.

### Pipeline Detail timing bug

**Discovered:** Step 3 (Backup canonical refactor)
**Symptom:** `/api/backup/pipeline-detail` endpoint returns empty `files: []` arrays even when ExecutionLog clearly contains records for the run.
**Root cause:** Timestamp mismatch between `Orchestrator.TaskLog` (window starts at 21:00:06) and `ServerOps.Backup_ExecutionLog` (records timestamped 21:00:01). Records exist outside the API's query window.
**Suspected cause:** Process scripts (e.g., `Process-BackupRetention.ps1`) likely capture a fixed timestamp at the start of execution and reuse it for batch logging, while `TaskLog.start_dttm` reflects when the orchestrator records the task as starting (after the work is already underway).
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

---

## Revision History

| Version | Date | Description |
|---|---|---|
| 0.1 | 2026-04-30 | Initial draft for review |
| 0.2 | 2026-04-30 | Refresh info row universal (no per-page omission). H1 color palette aligned to nav accent palette: tools shifts to `#9cdcfe`. Platform nav accent corrected from teal to blue (Section 2.8). H1 color overrides eliminated entirely (registry-driven only). Server Health corrected to have 4 engine cards. File encoding standard added to Development Guidelines update. Animation handling clarified (most-common-wins values applied universally, no preserved per-page differences since none were intentional). |
| 0.3 | 2026-04-30 | Steps 0-3 marked complete with results. Plan now reflects active execution rather than pre-execution draft. Added Part 7 (Per-Page JS Alignment Pattern) capturing the discovery from Backup that pages have local `showError`/`clearError` and `pageRefresh` functions that need to be removed and replaced with hooks. Added Part 8 (Backlog and Deferred Items) tracking the Pipeline Detail timing bug, Brandon's banner, and DBCC disk space suppression. Step 4 batch checklist expanded to include JS file changes (3 files per page, not 2). Backup modal migration to `xf-modal-*` system added as Step 5 to ensure it doesn't fall through the cracks. DmOps slide-panel `.active` to `.open` JS alignment moved from "out of scope" to in-scope (handled during the DmOps batch). Open Questions section removed - all answered during execution. Section 1.1 element 4 updated with the connection-banner placeholder ID/class rename. Various status markers ([COMPLETE], [DEPLOYED], [READY TO BEGIN]) added throughout. |
| 0.4 | 2026-04-30 | Backup modal migration completed in same session as Step 3 (Step 5 marked [COMPLETE]; details folded into Section 3.1). JBoss completed as first page in Step 4 (new Section 3.2 with full details; previous catch-all Section 3.2 demoted to Section 3.2.1; per-page table updated). JBoss work added three reusable additions to engine-events.css: `.xf-modal.wide`, `.xf-modal-overlay.hidden`, and a promoted shared `.modal-close` rule. Part 7 expanded with two new alignment items: (5) raw `fetch()` to `engineFetch()` migration for consistent tab-visibility/session-expiry/idle-pause handling, and (6) page-specific modal/dialog migration to shared `xf-modal-*` infrastructure with reference to both available patterns (dynamic `showAlert`/`showConfirm` helpers and static-HTML `.hidden`-toggled modals). Verification checklist expanded to include modal-specific checks. Brandon's banner Part 8 entry updated with the post-Backup-deployment finding: issue persists but is now localized to Backup only, ruling out the markup-conflict hypothesis. Step 6 description rewritten to reflect this. |

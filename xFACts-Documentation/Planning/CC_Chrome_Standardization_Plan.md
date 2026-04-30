# Control Center Chrome Standardization Plan

**Created:** April 30, 2026
**Status:** Draft - v0.2, awaiting approval
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

This is the plain-English specification of what every CC page looks like, top to bottom, above the content area. This text will be added verbatim (or near-verbatim) to `xFACts_Development_Guidelines.md`.

### 1.1 The Five Chrome Elements

Every CC page renders these elements in this order, with no exceptions:

1. **Nav bar** - Fixed to top of viewport, 40px tall. Rendered by `Get-NavBarHtml`. Contains Home + section links + admin gear (for admins). Already standardized in `engine-events.css`.

2. **Page title row** - Below the nav bar, contains:
   - **Left side:** Page H1 (24px) and subtitle (14px gray). Both sourced from `RBAC_NavRegistry` via `Get-PageHeaderHtml`. H1 color is determined by the page's `section_key` (see Section 1.3).
   - **Right side:** Refresh info row, present on every page without exception. Contains the live indicator dot, "Live | Updated: \<timestamp\>", and a refresh button. The timestamp reflects the last actual refresh of any kind: initial page load is the first refresh, and any subsequent polling, websocket update, or manual refresh updates it. Pages with no auto-refresh logic still display the row with the page-load timestamp; the live dot still pulses to indicate the UI is responsive.

3. **Engine cards row** (optional, where applicable) - Below the refresh info row, on the right side. Pages declare which engine cards apply via their HTML; no engine cards if no orchestrator-driven processes feed the page.

4. **Connection banner** (always present, hidden until needed) - Sits between the chrome and the content area. Uses `.connection-banner.{reconnecting|disconnected|session-expired|reloading}`. The legacy `.connection-error` class is retired and not used anywhere.

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

**Note on the nav accent fix:** The current `engine-events.css` `.nav-link.nav-section-platform.active` uses `#4ec9b0` (teal) instead of `#569cd6` (blue). This is corrected as part of this work so all three surfaces share matching colors per section.

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
- Page-specific modals, panels, slideouts

But the chrome itself - body padding, header-bar layout, h1 sizing, page-subtitle styling, refresh-info layout, live-indicator, last-updated, connection banner, sections used inside engine card rows - is shared and not redefined per page.

---

## Part 2 - Shared CSS Inventory

This section lists everything that will live in `engine-events.css`. Items marked **[NEW]** are being added in this consolidation; items marked **[EXISTING]** are already there and stay; items marked **[FIX]** already exist but are being corrected.

### 2.1 Base Reset and Body **[NEW]**

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

**Most-common-wins reasoning:**
- `font-family` - the longer fallback chain `'Segoe UI', Tahoma, Geneva, Verdana, sans-serif` appears on JBoss, BatchMon, FileMon, IndexMaint, ClientPortal. The `'Segoe UI', Arial, sans-serif` shorter form appears elsewhere. Going with the longer form for better fallback robustness.
- `padding: 20px 40px; padding-top: 60px` - the most common variant. ServerHealth, JobFlow, BusServ, ClientRelations have an extra `30px` bottom padding that was never explained; we drop it for consistency.
- `height: 100vh; overflow: hidden; flex-column` - implements the viewport constraint rule. Currently only ReplMon and PlatformMon have this; making it universal.

### 2.2 Page Header (H1 + Subtitle) **[NEW]**

```css
h1 { color: #569cd6; margin: 0 0 2px 0; font-size: 24px; }

body.section-platform     h1 { color: #569cd6; }
body.section-departmental h1 { color: #dcdcaa; }
body.section-tools        h1 { color: #9cdcfe; }
body.section-admin        h1 { color: #569cd6; }

.page-subtitle { color: #888; font-size: 14px; margin: 0; }
```

The base `h1` rule provides a default; the body-class rules drive the actual color per section. Pages do not redefine `h1` color in their own CSS files.

### 2.3 Header Bar Layout **[NEW]**

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

**Most-common-wins reasoning:**
- `margin-bottom: 15px` - most common (vs. some pages using 20px or 24px).
- `flex-wrap: wrap; gap: 8px` - appears on most pages with refresh info; harmless on pages without.
- `flex-shrink: 0` - required for the new viewport-constrained layout to keep the header from collapsing.

### 2.4 Refresh Info Row **[NEW]**

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

**Notes:**
- Every page renders this row, including pages with no auto-refresh logic. On those pages, the timestamp is set once at page load and the live dot still pulses.
- DmOps's drift to `last-updated { color: #569cd6; }` is reverted to teal.
- Admin's renamed `.header-subtitle` is dropped in favor of standard `.page-subtitle`.

### 2.5 Connection Banner Already Shared **[EXISTING]**

Already in `engine-events.css`. No changes:

```css
.connection-banner { ... }
.connection-banner.reconnecting   { ... }
.connection-banner.disconnected   { ... }
.connection-banner.session-expired { ... }
.connection-banner.reloading      { ... }
```

The legacy `.connection-error` class is removed from all page CSS files. Any HTML markup referencing `class="connection-error"` is updated to `class="connection-banner"` (with state classes added by JS as appropriate).

### 2.6 Section Container Defaults **[NEW]**

Every page uses `.section` containers for its content panels. These vary slightly today; we standardize:

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

.section-fill {
    flex: 1;
    flex-shrink: 1;
    min-height: 0;
    overflow-y: auto;
}

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

`.section-fill` is the helper class for sections that should consume remaining space within the viewport (used inside the new viewport-constrained layout). This already exists on DBCC and DmOps; we promote it to shared.

### 2.7 Common Animations **[NEW]**

```css
@keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.5; } }
@keyframes spin { from { transform: rotate(0deg); } to { transform: rotate(360deg); } }

.spinning-gear { display: inline-block; animation: spin 1s linear infinite; }
.spinning      { animation: spin 0.8s ease-in-out; }
```

The `pulse` and `spin` keyframes are duplicated across 12+ and 6+ page files respectively. They go to shared and the duplicates are stripped. Pages using these animations continue working unchanged - keyframes defined in shared CSS are globally available to all pages.

Most-common-wins values: `pulse` 0.5 opacity / 2s duration; `spin` 1s linear infinite. Pages with deliberately different timing (e.g., DmOps used 2s spin, BIDATA used 0.4 pulse opacity) accept the shared values. None of the differences were intentional design decisions.

### 2.8 Nav Bar Accent Color Correction **[FIX]**

The current `.nav-link.nav-section-platform.active` rule in `engine-events.css` uses `#4ec9b0` (teal). Per the section-color palette in Section 1.3, platform should be `#569cd6` (blue). Update:

```css
/* BEFORE */
.nav-link.nav-section-platform.active {
    color: #4ec9b0;
    border-bottom-color: #4ec9b0;
}

/* AFTER */
.nav-link.nav-section-platform.active {
    color: #569cd6;
    border-bottom-color: #569cd6;
}
```

After this fix, all three section accent surfaces (nav, Home tiles, page H1) share matching colors per section.

**Visual impact at deploy:** Platform nav links currently underline in teal when active; after the fix they'll underline in blue. This matches the existing platform page H1 color, so the active nav link will visually pair with the page header rather than appearing as a separate accent.

### 2.9 Already Shared, No Changes **[EXISTING]**

The following are already in `engine-events.css` and stay as-is:

- Engine cards (`.engine-card`, `.engine-row`, `.engine-bar`, `.engine-label`, `.engine-countdown`, status modifiers)
- Engine popup (`.engine-popup` and children)
- Idle overlay (`.idle-overlay`, `.idle-message`)
- Scrollbars (`::-webkit-scrollbar` rules and `scrollbar-width` for Firefox)
- Refresh badges (`.refresh-badge-event`, `.refresh-badge-live`, `.refresh-badge-static`, `.refresh-badge-action`)
- Page refresh button (`.page-refresh-btn`)
- Slide panels (`.slide-panel-overlay`, `.slide-panel`, etc.)
- Styled modal system (`.xf-modal-*`)
- Nav bar base styles (just the platform accent color is being fixed in Section 2.8)
- Nav-section-departmental and nav-section-tools accent classes
- Back link (`.back-link`)
- Connection banner classes (per Section 2.5)

---

## Part 3 - Per-Page Variance Inventory

For each page, what's currently different from the standard and what changes in the cleanup.

### Reference: which chrome elements each page needs

| Page | Section | Refresh info row | Engine cards | Center column | Notes |
|---|---|---|---|---|---|
| /server-health | platform | yes | yes (4 cards) | yes (server selector) | Only page with center column |
| /jboss-monitoring | platform | yes | yes (1: JBOSS) | no | |
| /jobflow-monitoring | platform | yes | yes | no | |
| /batch-monitoring | platform | yes | yes (NB/PMT/BDL) | no | |
| /backup | platform | yes | yes (BACKUP/NETWORK/AWS/RETENTION) | no | The reference screenshot |
| /index-maintenance | platform | yes | yes (placeholder) | no | Engine cards wired but not active |
| /dbcc-operations | platform | yes | yes | no | |
| /bidata-monitoring | platform | yes | yes | no | |
| /file-monitoring | platform | yes | yes | no | |
| /replication-monitoring | platform | yes | yes | no | Already viewport-constrained |
| /dm-operations | platform | yes | yes (placeholder) | no | Engine cards wired but not active |
| /platform-monitoring | platform | yes | no | no | Custom layout, no engine cards |
| /admin | admin | yes | no | no | Custom layout |
| /departmental/applications-integration | departmental | yes (page-load timestamp) | no | no | Static landing page; refresh row still rendered |
| /departmental/business-services | departmental | yes | no | no | |
| /departmental/business-intelligence | departmental | yes (page-load timestamp) | no | no | Static landing page; refresh row still rendered |
| /departmental/client-relations | departmental | yes | no | no | Has custom cache indicator alongside standard refresh info |
| /client-portal | tools | yes | no | no | Major refactor - see Section 3.7 |
| /bdl-import | tools | yes (page-load timestamp) | no | no | Wizard-style; refresh row still rendered |

### 3.1 Backup, BIDATA, BatchMon, JBoss, FileMon, JobFlow, IndexMaint, DBCC (the standard pages)

**Current state:** Standard chrome but with duplicated rules. Each has its own copy of body, h1, page-subtitle, header-bar, header-right, refresh-info, live-indicator, last-updated, connection-error, plus pulse and spin keyframes.

**Changes:**
- Strip everything in Sections 2.1, 2.2, 2.3 (without center-column rule), 2.4, 2.6, 2.7 from page CSS (rules now in shared).
- Strip the page's local `.connection-error` rule entirely; update HTML to use `.connection-banner` instead (route file change).
- Set `<body class="section-platform">` in route file.
- All retain their content-specific rules unchanged.

**Verification per page:** Page renders, top region looks identical to reference, no console errors.

### 3.2 Server Health (center-column page)

**Current state:** Standard chrome plus a center-column server selector. Has 4 engine cards driven by the Health/Disk/AG/ServerInfo collectors.

**Changes:**
- Standard chrome cleanup per Section 3.1.
- Add `class="has-center"` to its `.header-bar` element in the route file's HTML (center column rule already in shared per Section 2.3).
- Set `<body class="section-platform">`.

### 3.3 Replication Monitoring, Platform Monitoring (already viewport-constrained)

**Current state:** Already have viewport-constrained body. Will simplify with the new shared base.

**Changes:**
- Strip duplicated chrome rules per Section 3.1.
- Platform Monitoring: rename `.pm-subtitle` to `.page-subtitle` and `.pm-error` to `.connection-banner` in both CSS and route HTML/JS. The `.pm-` prefixed class names go away for chrome elements.
- Set `<body class="section-platform">` on both.

### 3.4 Departmental Pages: Applications & Integration, Business Services, Business Intelligence, Client Relations

**Current state:** Standard chrome but with `h1 { color: #dcdcaa; }` (yellow) and Apps/Int + BI have no refresh info row at all today.

**Changes:**
- Strip standard chrome rules per Section 3.1.
- Remove the local `h1 { color: #dcdcaa; }` rule - color now comes from `body.section-departmental h1` in shared CSS.
- Set `<body class="section-departmental">` on all four route files.
- Apps/Int and BI: **add** the refresh info row HTML per the new universal-presence rule. Set the page-load timestamp once on render; live dot pulses normally even though there's no live data underneath.
- Client Relations: keeps its custom cache indicator since that's content, not chrome. The custom refresh button stays as page-specific. The standard refresh info row appears alongside.

### 3.5 BDL Import

**Current state:** No live data, no engine cards, no refresh info row today. Uses `.connection-error { display: none }` to hide the legacy banner.

**Changes:**
- Strip standard chrome rules per Section 3.1.
- Add the refresh info row HTML with page-load timestamp.
- Remove `.connection-error { display: none }`. Connection banner is now globally present but hidden by default - no per-page hiding needed.
- Set `<body class="section-tools">`.
- All wizard content unchanged.

**Visual change at deploy:** H1 color shifts from `#569cd6` (blue) to `#9cdcfe` (soft blue) per the section-color alignment.

### 3.6 DM Operations

**Current state:** Standard chrome with one drift: `last-updated { color: #569cd6; }` instead of teal. Engine cards wired but not yet driven by orchestrator schedule.

**Changes:**
- Strip standard chrome rules per Section 3.1.
- The `.last-updated` blue color drift goes away (now teal from shared).
- Set `<body class="section-platform">`.
- DmOps slide-panel `.active` to `.open` JS alignment is **out of scope** for this work - separate backlog item from the RBAC working doc.

### 3.7 Admin Page (significant refactor)

**Current state:** The outlier. Uses `.page-header` instead of `.header-bar`. Uses `.header-subtitle` instead of `.page-subtitle`. Uses `pulse-live` keyframe instead of `pulse`. Body padding is `75px 40px 0 40px` instead of standard. Body has `display: flex; flex-direction: column; height: 100%; overflow: hidden`.

**Changes:**
- Refactor route HTML to use `.header-bar` and `.page-subtitle` (drops `.page-header` and `.header-subtitle` entirely).
- Strip Admin-specific body padding override; use shared `body` rule (which now also enforces viewport constraint, matching what Admin already needed).
- Rename `pulse-live` to `pulse` (shared).
- Strip all standard chrome rules per Section 3.1.
- Set `<body class="section-admin">`.
- Keep all timeline/canvas/sidebar/process-row content as page-specific.

### 3.8 Client Portal (final cleanup, separate session)

**Status:** Last to be done. Out of scope for the initial sweep. See Part 4 Step 6.

**Intent:** Refactor to standard chrome (matching every other page) with the portal content embedded inside one large `.section` container that fills the viewport-constrained content area. The current "header card + portal-page divs" pattern goes away.

This is treated separately because it's a structural refactor, not just a CSS cleanup. The page's JS (which uses `.portal-page.active` to switch between Search/Results/Consumer/Account "subpages") needs review, the HTML needs rewriting, and the light-themed portal content area needs to fit cleanly inside the dark CC chrome.

When this work is done, ClientPortal will get `<body class="section-tools">` with the soft-blue H1 like other tools-section pages.

---

## Part 4 - Execution Plan

### Step 0: Approve this plan

Lock the spec. No code changes until the plan is approved and any disputed items are resolved.

### Step 1: Update `xFACts_Development_Guidelines.md`

Add a new section codifying the chrome contract from Part 1 of this plan. Reference `engine-events.css` for implementation details. Update the "Adding a New CC Page" workflow to reflect what the page must NOT redefine (chrome) and what's expected of it (set body section class, declare header-bar class if center column needed, etc.).

Also adds the file encoding standard to the guidelines (UTF-8 without BOM, ASCII-only source content) per the lessons learned during this session.

This is documentation only - no behavior changes yet.

### Step 2: Update `engine-events.css` with the shared baseline

Append all rules from Part 2 Sections 2.1 through 2.7 that are marked **[NEW]**. Apply the Section 2.8 fix for the platform nav accent color. Comment block at the top of each new section references the Development Guidelines section as the spec.

Deploy. At this point all pages still work because their per-page rules still override (cascade order - page CSS loads after engine-events.css). The platform nav accent fix takes effect immediately and is visible everywhere.

### Step 3: Refactor one canonical page (Backup) and validate

Pick Backup since it's the reference screenshot:
- Update route file HTML: `<body class="section-platform">`, ensure connection banner placeholder is present (or relies on JS injection - verified during Step 1 prep), update HTML class references for any chrome elements affected.
- Strip duplicated chrome rules from `backup.css`.
- Deploy. Visually verify the top region looks identical to before. Verify viewport constraint works.
- This is the proof of concept. If anything is broken, fix the shared CSS or the page approach before proceeding.

### Step 4: Sweep remaining pages in batches

Suggested batches (4-5 pages per session):

- **Batch A:** JBoss, BIDATA, BatchMon, FileMon (the standard ones)
- **Batch B:** JobFlow, IndexMaint, DBCC, ServerHealth (ServerHealth uses center column)
- **Batch C:** Replication, Platform Monitoring (the rename work for PM)
- **Batch D:** Apps/Int, Business Services, Business Intelligence, Client Relations (departmental coloring + refresh info row addition for Apps/Int and BI)
- **Batch E:** BDL Import (refresh info row addition + tools color shift), DM Operations
- **Batch F:** Admin (significant refactor, do alone)

Each batch:
1. Update each route's HTML for body class, connection banner, refresh info row presence, any class renames
2. Strip duplicated chrome rules from each page's CSS
3. Deploy together
4. Visually verify all pages in the batch
5. Update this plan doc with what was completed

### Step 5: Brandon's banner re-investigation

Once all pages are using `.connection-banner` (no more `.connection-error`), the banner system is consistent. We re-test Brandon's page loads:
- If banner no longer falsely appears, it was a `.connection-error` vs `.connection-banner` conflict, resolved as a side effect of cleanup.
- If banner still appears, we have a clean codebase to debug from. Likely candidates: WebSocket initialization race for ReadOnly users, an inverted state check in `engine-events.js`, or a session-cookie issue.

### Step 6: Client Portal refactor

Separate effort, after the rest of the standardization is complete. Restructure the page HTML to put portal content inside one large `.section` container; strip header-card styling; verify the JS-driven page switching still works inside the new structure. Set `<body class="section-tools">` so H1 renders soft blue.

### Step 7: Archive RBAC working doc

After all chrome work is complete, the RBAC working doc is fully done (Phase 3d had unspoken chrome scope; this plan covers it). Move `RBAC_Working_Document.md` to `Legacy/` per the established pattern.

---

## Part 5 - Development Guidelines Updates

The following text gets added to `xFACts_Development_Guidelines.md` as a new subsection (likely `5.X CC Page Chrome Contract` or similar - exact placement TBD when drafting).

Content of the section is the entirety of Part 1 of this plan, lightly edited for reference-doc tone (less "we will" more "every page must").

The existing Section 4.5 "Adding a New Control Center Page" gets a new step inserted between current Step 1 (NavRegistry insert) and Step 2 (PermissionMapping insert):

> **1.5. Determine the page's chrome.**
>
> By default, the page inherits standard chrome from `engine-events.css`. The route file is responsible for:
> - Setting `<body class="section-{section_key}">` to drive the H1 color from the section.
> - Including the standard header-bar, refresh info row (always present), and engine card row (if applicable) HTML structure as documented in Section 5.X.
> - Not redefining chrome rules in the page-specific CSS file.
>
> Reference any existing standard page (e.g., Backup) as the template.

A second new section is added covering file encoding:

> **File Encoding Standard**
>
> All `.ps1`, `.psm1`, `.psd1`, `.js`, `.css`, `.html`, `.md`, and `.sql` files must be saved as **UTF-8 without BOM** with **CRLF line endings** (the Windows convention, since the platform runs on Windows).
>
> Within these files, use only ASCII characters (bytes 0x00-0x7F) in code, comments, and string literals. Specifically:
>
> - Use plain hyphens, not em-dashes or en-dashes
> - Use straight quotes, not curly quotes
> - Use three-dot ellipsis, not the single ellipsis character
> - Use ASCII arrows like `->` and `=>`, not Unicode arrow characters
> - Use `*` or `-` for list bullets in comments, not Unicode bullet characters
>
> **Exception:** HTML entities (`&#NNNN;` or `&name;`) in HTML/heredoc strings are encouraged for non-ASCII display characters since they're pure ASCII in the source.
>
> **Why:** Non-ASCII characters in source files frequently get corrupted in transit between editors and operating systems with different code-page defaults. A single Windows-1252 byte in an otherwise UTF-8 file causes GitHub to classify the file as binary and prevents standard tooling from reading it. ASCII-only source eliminates this entire class of issue.

Section 5.11 (shared CSS/JS inventory) is updated to reflect the expanded `engine-events.css` scope.

---

## Part 6 - What This Work Does NOT Cover

Locking scope so we don't drift:

- **Visual design changes** - colors, fonts, spacing, sizing all stay where the majority-wins audit puts them. Two deliberate visual changes are flagged: (1) Platform nav accent corrects from teal to blue per Section 2.8, (2) Tools section H1 shifts from `#569cd6` blue to `#9cdcfe` soft blue per Section 1.3 alignment.
- **JS behavior changes** - except for the connection-error to connection-banner rename, which is a class-name update only, not a logic change.
- **Engine card visual style** - already shared, not touched.
- **Modal system** - already shared, not touched.
- **Client Portal restructure** - explicitly Step 6, not part of the main sweep.
- **DmOps slide-panel `.active` to `.open` JS alignment** - separate backlog item from the RBAC working doc.
- **Doc-page RBAC integration** - separate effort, deferred.
- **Brandon's banner root cause** - investigated only AFTER cleanup, may resolve as a side effect.
- **Adding new chrome elements** - anything not currently shared by 2+ pages stays page-specific until proven otherwise.

---

## Open Questions / Decisions Needed Before Execution

These are flagged for confirmation before Step 1 begins:

1. **Connection banner DOM placement** - Does engine-events.js inject the banner element dynamically, or expect a placeholder in each page's HTML? Check `engine-events.js` and document the answer in Section 1.1 element 4 of this plan before Step 2.

2. **Refresh info row HTML for non-polling pages** - The HTML structure includes `<span id="last-update" class="last-updated">-</span>`. For pages without polling, does the route file render the timestamp directly (server-side) or does each page need a small JS snippet to set it on page load? Standardizing on one approach prevents drift.

3. **Documentation home for this plan** - does it stay in `Planning/` indefinitely, get merged into the Development Guidelines, or get archived once execution is complete? My suggestion: Planning/ during execution, Legacy/ after.

---

## Revision History

| Version | Date | Description |
|---|---|---|
| 0.1 | 2026-04-30 | Initial draft for review |
| 0.2 | 2026-04-30 | Refresh info row universal (no per-page omission). H1 color palette aligned to nav accent palette: tools shifts to `#9cdcfe`. Platform nav accent corrected from teal to blue (Section 2.8). H1 color overrides eliminated entirely (registry-driven only). Server Health corrected to have 4 engine cards. File encoding standard added to Development Guidelines update. Animation handling clarified (most-common-wins values applied universally, no preserved per-page differences since none were intentional). |

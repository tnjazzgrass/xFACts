# CC CSS Refactor Migration Notes

**Created:** May 3, 2026
**Status:** Active — populated as each CSS file is refactored under the Part 11 initiative
**Owner:** Dirk
**Target File:** `xFACts-Documentation/Planning/CC_CSS_Refactor_Migration_Notes.md`

---

## Purpose

This document records what changed in each CSS file during the CC CSS Refactor Initiative (see Part 11 of `CC_FileFormat_Standardization.md`). It captures the **non-spec changes** — class renames, structural changes, deletions, additions, and visual/behavioral changes — that are not directly inferable from the spec itself but that **downstream files (JS, HTML route .ps1, inline HTML in route handlers) must be updated to reflect**.

The format spec doc says how a CSS file should be structured. This doc says **what specifically changed in this file when it was brought to the spec**. The two are complementary:

- A future session opening JS migration work reads this doc to find the list of class renames and structural changes it needs to apply to the JS file.
- A future session updating an HTML route file reads this doc to find class references in the rendered HTML that need to change.
- The format spec doc is consulted for "how do I write a spec-compliant file"; this doc is consulted for "what changed when this specific file was brought to spec".

## How to read an entry

Each refactored CSS file gets one entry. Every entry covers the same six categories:

1. **Class renames.** Every class whose name changed. Almost always due to prefix application (`.foo` → `.bkp-foo`) but can include other renames when classes were merged or split.
2. **Class structure changes.** Cases where state or modifiers moved from one element to another in the selector — for example, a state class that was on a parent in the original (`.parent.warning .child`) now lives on the child element (`.child.warning`). These changes require **HTML markup updates** (the state class needs to be added to a different element) and **JS updates** (any code that toggles the state class needs to target the new element).
3. **Class deletions.** Classes from the original file that no longer exist in the refactored version. May happen when a class became redundant under the new structure or when its function was absorbed by a shared class in cc-shared.css.
4. **Class additions.** New classes that didn't exist in the original. Usually appear when descendant rules got refactored into state classes on the leaf element (the leaf needs a new state-bearing class).
5. **Visual or behavioral changes.** Anything where the rendered output is meaningfully different from before. Usually this is "no visible change" because the refactor is mechanical, but if a value was tightened (e.g., a one-off color was unified to the shared token, and the token's hex isn't byte-identical), it's noted here.
6. **cc-shared.css impact.** Any change made to `cc-shared.css` that was triggered by this page's refactor — token additions, token value bumps, new shared classes promoted from page-local. These are permanent platform changes that affect every future file consuming the shared resource. Anchored to the page that triggered them so future readers can trace why a change landed.

Each entry also includes a **Downstream impact** section summarizing what JS/HTML files need to know.

---

## backup.css

**Refactored:** 2026-05-03
**Component:** ServerOps.Backup
**Prefix:** `bkp-`
**Lines (before → after):** ~350 → 710
**Catalog rows (before → after):** 124 / 95% drift → 245 / 0% drift
**Downstream files:** `xFACts-ControlCenter/scripts/routes/Backup.ps1`, `xFACts-ControlCenter/scripts/routes/Backup-API.ps1`, `xFACts-ControlCenter/public/js/backup.js`

### 1. Class renames

Every page-local class in `backup.css` was prefixed with `bkp-`. The original file used unprefixed names; the new file scopes everything under the registered prefix per the spec.

The full rename list (original → new):

| Original | Renamed to |
|---|---|
| `.two-column-layout` | `.bkp-two-column-layout` |
| `.left-column` | `.bkp-left-column` |
| `.right-column` | `.bkp-right-column` |
| `.pipeline-card` | `.bkp-pipeline-card` |
| `.pipeline-header` | `.bkp-pipeline-header` |
| `.pipeline-title` | `.bkp-pipeline-title` |
| `.pipeline-body` | `.bkp-pipeline-body` |
| `.status-card` | `.bkp-status-card` |
| `.status-card-header` | `.bkp-status-card-header` |
| `.status-card-body` | `.bkp-status-card-body` |
| `.operation-table` | `.bkp-operation-table` |
| `.operation-row` | `.bkp-operation-row` |
| `.operation-name` | `.bkp-operation-name` |
| `.operation-status` | `.bkp-operation-status` |
| `.storage-drive` | `.bkp-storage-drive` |
| `.drive-label` | `.bkp-drive-label` |
| `.drive-bar` | `.bkp-drive-bar` |
| `.drive-bar-fill` | `.bkp-drive-bar-fill` |
| `.drive-stats` | `.bkp-drive-stats` |
| `.backup-type-badge` | `.bkp-backup-type-badge` |
| `.log-entry` | `.bkp-log-entry` |
| `.log-badge` | `.bkp-log-badge` |
| `.log-message` | `.bkp-log-message` |
| `.detail-summary` | `.bkp-detail-summary` |
| `.detail-list` | `.bkp-detail-list` |
| `.detail-item` | `.bkp-detail-item` |
| `.progress-bar` | `.bkp-progress-bar` |
| `.progress-bar-fill` | `.bkp-progress-bar-fill` |

(This list is the canonical reference. If a class shows up in a route file or JS file with the unprefixed name, it needs to be updated to the prefixed form.)

### 2. Class structure changes

The original file used descendant selectors to express drive warning/critical state; this is forbidden by the spec (section 3.13 — `FORBIDDEN_DESCENDANT`). The state moved from the parent element to the leaf element using the state-on-element pattern (spec section 3.7.1).

**Storage drive warning state:**

| Original | Refactored |
|---|---|
| `.storage-drive.storage-warning .drive-label { color: #d4a017; }` | `.bkp-drive-label.warning { color: var(--color-status-warning); }` |
| `.storage-drive.storage-warning .drive-bar-fill { background: #d4a017; }` | `.bkp-drive-bar-fill.warning { background: var(--color-status-warning); }` |

**Storage drive critical state:**

| Original | Refactored |
|---|---|
| `.storage-drive.storage-critical .drive-label { color: #c83232; }` | `.bkp-drive-label.critical { color: var(--color-status-critical); }` |
| `.storage-drive.storage-critical .drive-bar-fill { background: #c83232; }` | `.bkp-drive-bar-fill.critical { background: var(--color-status-critical); }` |

**What this means for HTML/JS:**

- In the old model, the **parent** `.storage-drive` element carried `storage-warning` or `storage-critical` and the children inherited the state via the descendant selector.
- In the new model, the **leaf elements** (`.bkp-drive-label`, `.bkp-drive-bar-fill`) each carry the state class directly.
- HTML markup needs the state class moved from the `.bkp-storage-drive` wrapper down onto the `.bkp-drive-label` and `.bkp-drive-bar-fill` children.
- JS code that toggles drive state must `classList.add('warning')` (or `'critical'`) on the **two leaf elements** rather than on the parent. Same for `.remove()`.

### 3. Class deletions

The following original classes no longer exist in the refactored file:

- `.storage-warning` — was a parent state class consumed only by descendant selectors. State now lives on the leaves as `.warning`. The HTML can drop this class entirely from the `.bkp-storage-drive` element.
- `.storage-critical` — same as above, replaced by `.critical` on the leaves.

### 4. Class additions

The following classes are new in the refactored file (no equivalent existed in the original):

- `.bkp-drive-label.warning` — leaf state variant; replaces the descendant rule from category 2 above.
- `.bkp-drive-label.critical` — same pattern.
- `.bkp-drive-bar-fill.warning` — leaf state variant for the bar fill color.
- `.bkp-drive-bar-fill.critical` — same pattern.

These four classes (technically two base classes plus four variants in spec terms) are the structural replacement for the old descendant rules. JS that previously added `.storage-warning` to the parent now adds `.warning` to each of the two leaf elements.

### 5. Visual or behavioral changes

**No intentional visible changes.** The refactor was mechanical: same colors, same sizes, same layout, just structured against the spec. A few specific points to flag for visual sanity-check during HTML/JS migration:

- **Hex literals replaced with `cc-shared.css` token references.** Every color in the original file (e.g., `#1a1a1a`, `#d4a017`, `#c83232`, `#2d6b5e`) is now `var(--color-*)` from cc-shared. Values are byte-identical to the originals, so no rendered difference. The exception is the log-badge color `#b5b07a` which is a one-off and was kept as a page-local hex literal.
- **Pixel sizes replaced with `var(--size-*)` references** where shared tokens exist. Where a size was page-unique (e.g., a specific column width that no other page uses), it stayed as a px literal.
- **Progress-bar gradient consumed via shared token.** The original used an inline `linear-gradient(90deg, #2d6b5e, #266053)`; the refactored version uses `var(--gradient-progress-default)` defined in cc-shared.css. Same gradient stops, same direction, no visual difference.
- **`@media` rule retained.** The original file's responsive `@media (max-width: 768px)` block was kept intact (now permitted under spec amendment Gap 6). Class names inside the @media block were updated to `bkp-` prefixes to match.
- **CHANGELOG block removed from header.** No visible effect; the spec forbids CHANGELOG blocks (history is in git).
- **Monospace font drift fixed.** The original file declared font-family in a few places using slightly different monospace stacks. All now reference `var(--font-family-mono)` from cc-shared so the entire page renders in one consistent monospace stack.

### 6. cc-shared.css impact

The `--gradient-progress-default` token was added to `cc-shared.css`'s FOUNDATION block during this refactor. Original value: `linear-gradient(90deg, #2d6b5e, #266053)`. The token was promoted because cross-page progress bars are an obvious shared pattern; backup.css was the first consumer.

### Downstream impact summary

When the JS/HTML migration session opens `Backup.ps1`, `Backup-API.ps1`, and `backup.js`:

1. **Class reference updates (everywhere).** Every reference to one of the 28 renamed classes in the table above must be updated to its `bkp-` prefixed form. This is a mechanical find-and-replace per row in the rename table. Affects HTML emission strings in the .ps1 files, JS `classList` calls, JS `querySelector(...)` calls, and any HTML template literals.

2. **Drive state toggling logic change.** Any JS code that currently does something like `driveElement.classList.add('storage-warning')` (toggling state on the `.bkp-storage-drive` parent) must change to toggle `'warning'` (or `'critical'`) on the two leaf elements separately:

   ```javascript
   // Old:
   driveEl.classList.add('storage-warning');

   // New:
   driveEl.querySelector('.bkp-drive-label').classList.add('warning');
   driveEl.querySelector('.bkp-drive-bar-fill').classList.add('warning');
   ```

   (Or however the JS prefers to track the references — the point is that `warning` and `critical` are now leaf-element state classes, not parent-element state classes.) Same applies to `.remove()` operations.

3. **HTML markup updates.** The `.bkp-storage-drive` element no longer needs `class="storage-warning"` or `class="storage-critical"`. Drop those from the rendered HTML. The state classes belong on the `.bkp-drive-label` and `.bkp-drive-bar-fill` children instead.

4. **No JS event-binding changes.** All event bindings (clicks, hovers, etc.) remain conceptually the same — only the class names being matched have changed. Update the selector strings; don't restructure the event logic.

---

## business-intelligence.css

**Refactored:** 2026-05-03
**Component:** DeptOps.BusinessIntelligence
**Prefix:** `biz-`
**Lines (before → after):** ~245 → 251
**Catalog rows (before → after):** 43 / 100% drift → 67 / 0% drift
**Downstream files:** `xFACts-ControlCenter/scripts/routes/BusinessIntelligence.ps1`, `xFACts-ControlCenter/scripts/routes/BusinessIntelligence-API.ps1`, `xFACts-ControlCenter/public/js/business-intelligence.js`

### 1. Class renames

Every surviving page-local class in `business-intelligence.css` was prefixed with `biz-`. Classes that were dropped because cc-shared.css now provides them are listed in category 3, not here.

The full rename list (original → new):

| Original | Renamed to |
|---|---|
| `.section-subtitle` | `.biz-section-subtitle` |
| `.hidden` | `.biz-hidden` |
| `.tool-cards` | `.biz-tool-cards` |
| `.tool-card` | `.biz-tool-card` |
| `.tool-card.placeholder` | `.biz-tool-card.placeholder` |
| `.tool-card.notice-recon-tile` | `.biz-tool-card.notice-recon-tile` |
| `.tool-icon` | `.biz-tool-icon` |
| `.tool-label` | `.biz-tool-label` |
| `.tool-status` | `.biz-tool-status` |
| `.nr-badges` | `.biz-nr-badges` |
| `.nr-badge` | `.biz-nr-badge` |
| `.nr-badge.success` | `.biz-nr-badge.success` |
| `.nr-badge.warning` | `.biz-nr-badge.warning` |
| `.nr-badge.error` | `.biz-nr-badge.error` |
| `.nr-badge.running` | `.biz-nr-badge.running` |
| `.nr-badge.pending` | `.biz-nr-badge.pending` |
| `.nr-badge.future` | `.biz-nr-badge.future` |
| `.nr-status-pill` | `.biz-nr-status-pill` |
| `.nr-status-pill.success` | `.biz-nr-status-pill.success` |
| `.nr-status-pill.warning` | `.biz-nr-status-pill.warning` |
| `.nr-status-pill.error` | `.biz-nr-status-pill.error` |
| `.nr-status-pill.running` | `.biz-nr-status-pill.running` |
| `.nr-status-pill.pending` | `.biz-nr-status-pill.pending` |

State modifier names (`.success`, `.warning`, `.error`, `.running`, `.pending`, `.future`, `.placeholder`, `.notice-recon-tile`) were not changed — they remain as-is on the prefixed base classes.

### 2. Class structure changes

The original file scoped a slide-panel width override using an ID-based selector with a depth-3 compound:

| Original | Refactored |
|---|---|
| `#nr-detail-panel.slide-panel.wide { width: 1000px; right: -1020px; }` | _(deleted — page now consumes shared `.slide-panel.xwide` directly)_ |
| `#nr-detail-panel.slide-panel.wide.open { right: 0; }` | _(deleted — same reason)_ |

**What this means for HTML/JS:** The `<div id="nr-detail-panel" class="slide-panel wide">` HTML element should change to `<div id="nr-detail-panel" class="slide-panel xwide">` — i.e., swap the `wide` width tier for the `xwide` width tier. The ID can remain (it's used by JS for element lookup) but does not participate in CSS scoping anymore. JS code that opens or closes the panel needs no logic change; only the static HTML class list changes.

The `.section-header h2` descendant rule was also removed; the page's `<h2>` element inside a section header should change to `<h2 class="section-title">` so it matches the shared chrome. This is a markup-only change — no JS impact.

### 3. Class deletions

The following original classes were removed entirely. Each was either superseded by a `cc-shared.css` equivalent or constituted dead code:

- `body` (element rule), `.header-bar`, `h1` (element rule), `.page-subtitle`, `.header-right`, `.refresh-info`, `.last-updated` — universal page chrome, now provided by `cc-shared.css`.
- `.connection-error` — superseded by the shared `.connection-banner` system in `cc-shared.css`. The HTML's `<div class="connection-error">` placeholder element should be replaced by `<div class="connection-banner">` and the JS that toggles the `visible` class should toggle one of the four shared connection-banner state classes (`reconnecting`, `disconnected`, `session-expired`, `reloading`) instead.
- `.section`, `.section-header`, `.section-header h2` — shared section primitives now in `cc-shared.css`. The page's HTML continues to use `<div class="section">` and `<div class="section-header">` against the shared definitions; the `<h2>` inside a section header should gain `class="section-title"` per category 2 above.
- `#nr-detail-panel.slide-panel.wide` and `#nr-detail-panel.slide-panel.wide.open` — replaced by direct consumption of shared `.slide-panel.xwide` (see category 2 above).

### 4. Class additions

No new classes added beyond the prefix renames. The refactor was a strict prefix-and-strip-chrome operation; no new structural classes were introduced.

### 5. Visual or behavioral changes

**No intentional visible changes** beyond the cc-shared chrome contract being applied. Specific points to flag for visual sanity-check during HTML/JS migration:

- **Hex literals replaced with `cc-shared.css` token references** where exact-value matches existed: `#1e1e1e` → `--color-bg-page`, `#333` → `--color-border-divider`, `#dcdcaa` → `--color-accent-departmental`, `#22c55e` → `--color-status-idle`, `#569cd6` → `--color-accent-platform`, `#f48771` → `--color-status-critical`, `#444` → `--color-status-disabled`, `#888` → `--color-text-muted`, `#4ec9b0` → `--color-accent-shared`. Values are byte-identical to the originals; no rendered difference.
- **Page-specific RGBA tints retained as literals.** The Notice Recon badge backgrounds (`rgba(34, 197, 94, 0.18)`, `rgba(220, 220, 170, 0.18)`, `rgba(244, 135, 113, 0.18)`, `rgba(86, 156, 214, 0.18)`, `rgba(68, 68, 68, 0.4)`) and the corresponding status-pill backgrounds (`rgba(78, 201, 176, 0.15)`, `rgba(204, 167, 0, 0.15)`, `rgba(241, 76, 76, 0.15)`, `rgba(86, 156, 214, 0.15)`) don't match any existing cc-shared token's alpha value (existing glow tokens are at 0.4 alpha; tint tokens are at 0.08). Kept as literals; promotion to shared tokens is deferred until the catalog confirms cross-page reuse.
- **Page-specific status pill colors retained as literals.** `#cca700` (warning amber) and `#f14c4c` (error red) appear only on this page's status pills and don't have cc-shared equivalents. Kept as literals.
- **Slide panel width:** the page's detail panel renders 50px wider than before (1000px instead of 950px) due to the cc-shared `.slide-panel.xwide` token bump (see category 6). This is barely noticeable and was an explicit design decision during refactor — the alternative (a fully page-local panel class) was rejected as more complex than the value bump.
- **CHANGELOG block removed from header.** No visible effect; the spec forbids CHANGELOG blocks (history is in git).
- **Body padding-bottom drift fixed.** The original file's `body` rule had `padding: 20px 40px 30px 40px` (a 30px bottom). The shared body rule uses `padding: 20px 40px` (a 20px bottom). The page now uses the shared 20px bottom. Visual difference: 10px less whitespace at the bottom of the page.

### 6. cc-shared.css impact

The `--size-panel-width-xwide` and `--size-panel-offset-xwide` tokens were updated:

| Token | Before | After |
|---|---|---|
| `--size-panel-width-xwide` | `950px` | `1000px` |
| `--size-panel-offset-xwide` | `-970px` | `-1020px` |

The bump was triggered by the BI page's Notice Recon detail panel which needs 1000px to render its step-detail table without cramping. The alternative (introducing a new `.slide-panel.xxwide` tier or creating a fully page-local panel class) was rejected — the existing `.xwide` tier had no other consumers at the time of the bump (only `.wide` is used by backup.css; `.xwide` was unused), so the value bump is non-breaking.

The shared file's `.slide-panel.xwide` description was also updated to note the BI use case as the canonical consumer of the widest panel tier.

### Downstream impact summary

When the JS/HTML migration session opens `BusinessIntelligence.ps1`, `BusinessIntelligence-API.ps1`, and `business-intelligence.js`:

1. **Class reference updates (everywhere).** Every reference to one of the page-local classes in the rename table must be updated to its `biz-` prefixed form. Mechanical find-and-replace per row.

2. **Connection error → connection banner replacement.** The `<div class="connection-error">` HTML placeholder must become `<div class="connection-banner">`. Any JS code that does `el.classList.add('visible')` to show the error and `el.classList.remove('visible')` to hide it needs to be replaced with the shared connection banner state model — set one of `reconnecting`, `disconnected`, `session-expired`, or `reloading` based on the event type, and remove all of them to clear. The shared `engine-events.js` already provides `updateConnectionBanner()` for this; the page's local error-display logic can be removed entirely in favor of letting shared chrome handle it.

3. **Section title H2 class.** Every `<h2>` rendered inside a `<div class="section-header">` needs `class="section-title"` added.

4. **Detail panel width-tier swap.** The HTML element with `id="nr-detail-panel"` should change its class list from `slide-panel wide` to `slide-panel xwide`. No JS change required — the panel's open/close logic already toggles `.open` on the same element.

5. **No JS event-binding changes.** All event bindings remain conceptually the same.

---

## client-relations.css

**Refactored:** 2026-05-03
**Component:** DeptOps.ClientRelations
**Prefix:** `clr-`
**Lines (before → after):** ~440 → 455
**Catalog rows (before → after):** 80 / 74% drift → 141 / 0% drift
**Downstream files:** `xFACts-ControlCenter/scripts/routes/ClientRelations.ps1`, `xFACts-ControlCenter/scripts/routes/ClientRelations-API.ps1`, `xFACts-ControlCenter/public/js/client-relations.js`

### 1. Class renames

Every surviving page-local class in `client-relations.css` was prefixed with `clr-`. Classes dropped because cc-shared.css now provides them are listed in category 3.

The full rename list (original → new):

| Original | Renamed to |
|---|---|
| `.cache-indicator` | `.clr-cache-indicator` |
| `.loading` | `.clr-loading` |
| `.hidden` | `.clr-hidden` |
| `.no-data` | `.clr-no-data` |
| `.text-right` | `.clr-text-right` |
| `.section-body` | `.clr-section-body` |
| `.section-body-table` | `.clr-section-body-table` |
| `.summary-cards` | `.clr-summary-cards` |
| `.summary-card` | `.clr-summary-card` |
| `.summary-card.card-warning` | `.clr-summary-card.card-warning` |
| `.summary-card.card-critical` | `.clr-summary-card.card-critical` |
| `.summary-card-value` | `.clr-summary-card-value` |
| `.summary-card-label` | `.clr-summary-card-label` |
| `.search-input` | `.clr-search-input` |
| `.search-input::placeholder` | `.clr-search-input::placeholder` |
| `.reason-filters` | `.clr-reason-filters` |
| `.filter-badge` | `.clr-filter-badge` |
| `.filter-badge.active` | `.clr-filter-badge.active` |
| `.queue-scroll-container` | `.clr-queue-scroll-container` |
| `.queue-table` | `.clr-queue-table` |
| `.col-expand` | `.clr-col-expand` |
| `.col-count` | `.clr-col-count` |
| `.consumer-row` | `.clr-consumer-row` |
| `.consumer-row.expanded` | `.clr-consumer-row.expanded` |
| `.expand-icon` | `.clr-expand-icon` |
| `.account-count-badge` | `.clr-account-count-badge` |
| `.reason-badge` | `.clr-reason-badge` |
| `.reason-letter` | `.clr-reason-letter` |
| `.reason-other` | `.clr-reason-other` |
| `.reason-zero-dollar` | `.clr-reason-zero-dollar` |
| `.reason-no-data` | `.clr-reason-no-data` |
| `.reason-discrepancy` | `.clr-reason-discrepancy` |
| `.account-row` | `.clr-account-row` |
| `.account-detail-container` | `.clr-account-detail-container` |
| `.account-sub-table` | `.clr-account-sub-table` |

State modifier names (`.expanded`, `.active`, `.card-warning`, `.card-critical`) were not changed — they remain as-is on the prefixed base classes.

### 2. Class structure changes

The original file used multiple descendant selectors against table elements; this is forbidden by the spec (`FORBIDDEN_DESCENDANT`). Every descendant rule was refactored into a class on the leaf element. The HTML must be updated to add the new class to each affected element.

**Queue table cells:**

| Original | Refactored |
|---|---|
| `.queue-table thead th { ... }` | `.clr-queue-table-th { ... }` |
| `.consumer-row td { ... }` | `.clr-consumer-row-td { ... }` |

**Account sub-table cells:**

| Original | Refactored |
|---|---|
| `.account-sub-table thead th { ... }` | `.clr-account-sub-table-th { ... }` |
| `.account-sub-table tbody td { ... }` | `.clr-account-sub-table-td { ... }` |
| `.account-sub-table tbody tr:hover { ... }` | `.clr-account-sub-table-row:hover { ... }` |
| `.account-sub-table tbody tr:last-child td { ... }` | _(deleted — see category 3)_ |

**Account row cell padding:**

| Original | Refactored |
|---|---|
| `.account-row > td { ... }` | `.clr-account-row-td { ... }` |

**What this means for HTML/JS:**

- Every `<th>` in the queue table needs `class="clr-queue-table-th"`.
- Every `<td>` in a consumer row needs `class="clr-consumer-row-td"`.
- Every `<th>` in an account sub-table needs `class="clr-account-sub-table-th"`.
- Every `<td>` in an account sub-table body needs `class="clr-account-sub-table-td"`.
- Every `<tr>` in an account sub-table body needs `class="clr-account-sub-table-row"` (so the `:hover` rule can attach to it).
- Every `<td>` in the wrapper `.clr-account-row` needs `class="clr-account-row-td"`.

JS code that programmatically renders these tables (likely a `tableHtml.push('<th>...</th>')`-style pattern in `client-relations.js`) needs to add the class names at every cell.

### 3. Class deletions

The following original classes were removed entirely. Each was either superseded by a `cc-shared.css` equivalent, replaced by a structurally different pattern, or constituted dead code:

- `* { box-sizing: border-box }` (universal selector reset), `body` (element rule, including narrow-viewport `body { padding: 60px 15px 20px 15px }`), `h1` (element rule), `.page-subtitle`, `.header-bar`, `.header-right`, `.refresh-info`, `.last-updated` — universal page chrome, now provided by `cc-shared.css`.
- `.btn`, `.btn-sm`, `.btn-refresh`, `.btn-refresh:hover`, `.btn-refresh.spinning` — page-local refresh button. Page should adopt the shared `.page-refresh-btn` from `cc-shared.css` instead. The cache indicator (`.clr-cache-indicator`) remains and continues to render alongside the shared refresh button.
- `@keyframes spin` — already defined in `cc-shared.css`'s FOUNDATION block. The duplicate in this file was removed (and was orphaned anyway after `.btn-refresh.spinning` was dropped).
- `.connection-error`, `.connection-error.visible` — superseded by the shared `.connection-banner` system in `cc-shared.css`. The HTML's `<div class="connection-error">` placeholder should become `<div class="connection-banner">`; JS that toggled the `visible` class should drive the shared connection banner instead.
- `.section`, `.section-header`, `.section-header h2`, `.section-controls` — shared section primitives now in `cc-shared.css`. The page's HTML continues to use `<div class="section">` and `<div class="section-header">`. The right-side container `.section-controls` should be renamed to the shared `.section-header-right`. The `<h2>` inside a section header should gain `class="section-title"`.
- `.queue-table thead th`, `.consumer-row td`, `.account-row > td`, `.account-sub-table thead th`, `.account-sub-table tbody td`, `.account-sub-table tbody tr:hover`, `.account-sub-table tbody tr:last-child td` — descendant rules; refactored into leaf-element classes per category 2 above.
- `.consumer-row:hover .expand-icon` — the parent-hover-cascading-to-child rule that turned the expand icon teal when its row was hovered. Dropped because the spec forbids descendant selectors. Visual loss: the icon no longer changes color on row hover. The row itself still highlights on hover. See TODO in the QUEUE TABLE banner of the refactored CSS file for potential future restoration via JS-driven class toggle.
- `body { padding: 60px 15px 20px 15px }` (inside `@media (max-width: 900px)`) — narrow-viewport body padding override; chrome concern, dropped along with the base body rule.

### 4. Class additions

The following classes are new in the refactored file (no equivalent existed in the original):

- `.clr-queue-table-th` — leaf class for queue table header cells; replaces the descendant rule from category 2.
- `.clr-consumer-row-td` — leaf class for consumer row cells; replaces the descendant rule from category 2.
- `.clr-account-sub-table-th` — leaf class for account sub-table header cells.
- `.clr-account-sub-table-td` — leaf class for account sub-table data cells.
- `.clr-account-sub-table-row` — base class for account sub-table data rows (the `:hover` variant is what consumes this; the base class itself has no own styling).
- `.clr-account-row-td` — leaf class for cells inside the account-row wrapper element.

These six classes are the structural replacement for the dropped descendant rules. JS that programmatically renders the tables must add these class names to the corresponding `<th>`, `<td>`, and `<tr>` elements.

### 5. Visual or behavioral changes

**No intentional visible changes** beyond the cc-shared chrome contract being applied and the dropped icon-hover effect noted in category 3. Specific points to flag for visual sanity-check during HTML/JS migration:

- **Hex literals replaced with `cc-shared.css` token references** where exact-value matches existed: `#1e1e1e` → `--color-bg-page`, `#252526` → `--color-bg-card`, `#2d2d2d` → `--color-bg-card-hover`, `#2a2a2a` → `--color-bg-card-deep`, `#404040` → `--color-border-default`, `#333` → `--color-border-divider`, `#888` → `--color-text-muted`, `#666` → `--color-text-subtle`, `#d4d4d4` → `--color-text-primary`, `#4ec9b0` → `--color-accent-shared`, `#569cd6` → `--color-accent-platform`, `#f48771` → `--color-status-critical`. Values are byte-identical to the originals.
- **Page-specific colors retained as literals.** Several color values used only by this page have no cc-shared equivalent and were kept as literals: `#5a1d1d`, `#264f78`, `#2d5a8a`, `#4d3800`, `#4d2800`, `#cca700`, `#f14c4c`, `#6cb6ff`, `#e8925c`, `#c0c0c0`, `#2a2d2e` and the small amber/red surface tints `rgba(204, 167, 0, 0.05)` and `rgba(241, 76, 76, 0.05)`. Promotion to shared tokens is deferred until the catalog confirms cross-page reuse.
- **Body padding-bottom drift fixed.** The original file's `body` rule had `padding: 20px 40px 30px 40px` (a 30px bottom). The shared body rule uses `padding: 20px 40px` (a 20px bottom). Visual difference: 10px less whitespace at the bottom of the page.
- **Narrow-viewport body padding lost.** The original `@media (max-width: 900px)` block included `body { padding: 60px 15px 20px 15px }`. This is dropped along with the base body rule; the page now uses the shared body padding at narrow viewports. Visual difference at narrow viewports: more horizontal padding (40px from shared vs. 15px from old override). Small mobile-only impact.
- **Last-row border in account sub-table retained.** The original suppressed the bottom border on the cells of the last row in each sub-table (`tbody tr:last-child td`). The refactored file does not reproduce this — the spec-clean alternatives (a `.last` modifier that requires JS to apply, or a descendant selector) were both judged worse than accepting a faint extra border line at the bottom of the table. Visual difference: small horizontal border line at the bottom of every account sub-table.
- **Refresh button visual change.** The page-local `.btn-refresh` (a flat dark button with teal hover) is replaced by the shared `.page-refresh-btn` (a transparent border-only button with teal hover). The shared button is visually different but functions identically. Hover and spinning behavior preserved (shared file has its own `page-refresh-spin` keyframe).
- **Expand-icon hover effect lost.** Per category 3: the icon no longer turns teal on row hover. The row still highlights. See TODO in CSS file.
- **CHANGELOG block removed from header.** No visible effect; the spec forbids CHANGELOG blocks (history is in git).

### 6. cc-shared.css impact

No changes to `cc-shared.css` were triggered by this page's refactor. All shared tokens and classes consumed by `client-relations.css` already existed.

### Downstream impact summary

When the JS/HTML migration session opens `ClientRelations.ps1`, `ClientRelations-API.ps1`, and `client-relations.js`:

1. **Class reference updates (everywhere).** Every reference to one of the page-local classes in the rename table must be updated to its `clr-` prefixed form. Mechanical find-and-replace per row.

2. **Refresh button replacement.** The custom `.btn-refresh` button HTML in the route file must be replaced with the shared `.page-refresh-btn` markup. Any JS that adds/removes the `.spinning` class on `.btn-refresh` must target the shared button instead. Visual styling will change slightly but click behavior is preserved.

3. **Connection error → connection banner replacement.** Same pattern as the BI page: replace `<div class="connection-error">` with `<div class="connection-banner">`; replace local error-display logic with calls into the shared `updateConnectionBanner()` helper from `engine-events.js`.

4. **Section header restructuring.** Three changes inside every section header in the route's HTML:
   - The right-side container class `section-controls` must be renamed to `section-header-right`.
   - The `<h2>` element inside the section header must gain `class="section-title"`.
   - No new wrapper elements are needed; only class names change.

5. **Table cell class additions (significant).** Every table cell rendered by the route file or the JS must gain the appropriate leaf class:
   - Queue table `<th>` → add `class="clr-queue-table-th"`.
   - Queue table consumer-row `<td>` → add `class="clr-consumer-row-td"`.
   - Account sub-table `<th>` → add `class="clr-account-sub-table-th"`.
   - Account sub-table `<td>` → add `class="clr-account-sub-table-td"`.
   - Account sub-table `<tr>` → add `class="clr-account-sub-table-row"`.
   - Account-row wrapper `<td>` → add `class="clr-account-row-td"`.

   This is the most mechanical-but-tedious part of the migration. The JS likely builds these tables via string concatenation or template literals; every cell-emission point needs the class added.

6. **No JS event-binding changes.** All event bindings remain conceptually the same — only the class names being matched have changed.

---

## replication-monitoring.css

**Refactored:** 2026-05-03 (Phase 1, file 3 of ~28)
**Result:** 131 rows / 97% drift → 252 rows / 0% drift
**Prefix:** `rpm-`
**Component:** `ServerOps.Replication`

The replication monitoring page is a higher-density layout than the prior Phase 1 files. It's structurally a four-pane page: a top charts row, a lower grid that splits into a column of small charts on the left and an event log on the right. Layout containers, agent status cards, charts, the event log itself, the event log control widgets, the help info-panel content, and tiny "loading"/"no data" utilities are all distinct concerns — so the file's CONTENT sections are split granularly.

The page also exercises two patterns that hadn't surfaced in BI or CR: a slide-out help panel structurally identical to the shared `.slide-panel` (consumed via the shared chrome rather than duplicated), and a family of `event-type-*` classes whose suffix is a backend event-type code in upper-snake-case (preserved verbatim so JS can compose the class name without a casing transform).

### 1. Class renames

The wholesale `*` → `rpm-*` prefix application accounts for the bulk of the renames. Every page-local class gained the `rpm-` prefix.

| Original | Refactored |
|----------|------------|
| `.info-icon` | `.rpm-info-icon` |
| `.agent-cards-grid` | `.rpm-agent-cards-grid` |
| `.agent-card` | `.rpm-agent-card` |
| `.agent-card.status-healthy` | `.rpm-agent-card.status-healthy` |
| `.agent-card.status-idle` | `.rpm-agent-card.status-idle` |
| `.agent-card.status-warning` | `.rpm-agent-card.status-warning` |
| `.agent-card.status-critical` | `.rpm-agent-card.status-critical` |
| `.agent-card.status-stopped` | `.rpm-agent-card.status-stopped` |
| `.agent-card.status-unknown` | `.rpm-agent-card.status-unknown` |
| `.agent-card-header` | `.rpm-agent-card-header` |
| `.agent-card-title` | `.rpm-agent-card-title` |
| `.agent-card-subtitle` | `.rpm-agent-card-subtitle` |
| `.agent-status-badge` | `.rpm-agent-status-badge` |
| `.badge-running` | `.rpm-badge-running` |
| `.badge-idle` | `.rpm-badge-idle` |
| `.badge-started` | `.rpm-badge-started` |
| `.badge-retrying` | `.rpm-badge-retrying` |
| `.badge-failed` | `.rpm-badge-failed` |
| `.badge-stopped` | `.rpm-badge-stopped` |
| `.badge-unknown` | `.rpm-badge-unknown` |
| `.agent-card-metrics` | `.rpm-agent-card-metrics` |
| `.agent-metric` | `.rpm-agent-metric` |
| `.agent-metric-label` | `.rpm-agent-metric-label` |
| `.agent-metric-value` | `.rpm-agent-metric-value` |
| `.agent-metric-value.queue-healthy` | `.rpm-agent-metric-value.queue-healthy` |
| `.agent-metric-value.queue-warning` | `.rpm-agent-metric-value.queue-warning` |
| `.agent-metric-value.queue-critical` | `.rpm-agent-metric-value.queue-critical` |
| `.agent-metric-unit` | `.rpm-agent-metric-unit` |
| `.agent-type-tag` | `.rpm-agent-type-tag` |
| `.agent-type-tag.tag-logreader` | `.rpm-agent-type-tag.tag-logreader` |
| `.agent-type-tag.tag-push` | `.rpm-agent-type-tag.tag-push` |
| `.agent-type-tag.tag-pull` | `.rpm-agent-type-tag.tag-pull` |
| `.charts-row` | `.rpm-charts-row` |
| `.chart-section` | `.rpm-chart-section` |
| `.chart-container` | `.rpm-chart-container` |
| `.chart-wide` | `.rpm-chart-wide` |
| `.chart-half` | `.rpm-chart-half` |
| `.lower-grid` | `.rpm-lower-grid` |
| `.lower-left` | `.rpm-lower-left` |
| `.lower-right` | `.rpm-lower-right` |
| `.section-event-log` | `.rpm-section-event-log` |
| `.event-log-container` | `.rpm-event-log-container` |
| `.time-buttons` | `.rpm-time-buttons` |
| `.time-btn` | `.rpm-time-btn` |
| `.time-btn:hover` | `.rpm-time-btn:hover` |
| `.time-btn.active` | `.rpm-time-btn.active` |
| `.event-row` | `.rpm-event-row` |
| `.event-row:hover` | `.rpm-event-row:hover` |
| `.event-row:last-child` | `.rpm-event-row:last-child` |
| `.event-time` | `.rpm-event-time` |
| `.event-type-badge` | `.rpm-event-type-badge` |
| `.event-type-STATE_CHANGE` | `.rpm-event-type-STATE_CHANGE` |
| `.event-type-AGENT_START` | `.rpm-event-type-AGENT_START` |
| `.event-type-AGENT_STOP` | `.rpm-event-type-AGENT_STOP` |
| `.event-type-ERROR` | `.rpm-event-type-ERROR` |
| `.event-type-RETRY` | `.rpm-event-type-RETRY` |
| `.event-type-INFO` | `.rpm-event-type-INFO` |
| `.event-publication` | `.rpm-event-publication` |
| `.event-agent-type` | `.rpm-event-agent-type` |
| `.event-transition` | `.rpm-event-transition` |
| `.event-correlation` | `.rpm-event-correlation` |
| `.event-message` | `.rpm-event-message` |
| `.event-message-text` | `.rpm-event-message-text` |
| `.event-date-picker` | `.rpm-event-date-picker` |
| `.event-date-picker:disabled` | `.rpm-event-date-picker:disabled` |
| `.btn-correlation` | `.rpm-btn-correlation` |
| `.btn-correlation:hover` | `.rpm-btn-correlation:hover` |
| `.btn-correlation.active` | `.rpm-btn-correlation.active` |
| `.event-agent-filter` | `.rpm-event-agent-filter` |
| `.event-agent-btn` | `.rpm-event-agent-btn` |
| `.event-agent-btn:hover` | `.rpm-event-agent-btn:hover` |
| `.event-agent-btn.active` | `.rpm-event-agent-btn.active` |
| `.no-data` | `.rpm-no-data` |
| `.loading` | `.rpm-loading` |
| `.event-log-container::-webkit-scrollbar` | `.rpm-event-log-container::-webkit-scrollbar` |
| `.event-log-container::-webkit-scrollbar-track` | `.rpm-event-log-container::-webkit-scrollbar-track` |
| `.event-log-container::-webkit-scrollbar-thumb` | `.rpm-event-log-container::-webkit-scrollbar-thumb` |
| `.event-log-container::-webkit-scrollbar-thumb:hover` | `.rpm-event-log-container::-webkit-scrollbar-thumb:hover` |

### 2. Class structure changes

Three structural reshapings beyond the prefix application.

**Descendant rules flattened to leaf classes.** The original page uses several descendant rules to apply per-context styling. Each was flattened into a leaf class that the markup now carries directly:

| Original (descendant rule) | Refactored (leaf class) | What the markup needs |
|----------------------------|--------------------------|------------------------|
| `.info-panel-body p { ... }` | `.rpm-info-panel-body-p` | every `<p>` inside the help panel body needs `class="rpm-info-panel-body-p"` |
| `.info-panel-body strong { ... }` | `.rpm-info-panel-body-strong` | every `<strong>` inside the help panel body needs `class="rpm-info-panel-body-strong"` |
| `.info-panel-body em { ... }` | `.rpm-info-panel-body-em` | every `<em>` inside the help panel body needs `class="rpm-info-panel-body-em"` |
| `.event-transition .state-from { ... }` | `.rpm-state-from` | the from-state span inside an event-transition cell needs `class="rpm-state-from"` |
| `.event-transition .state-arrow { ... }` | `.rpm-state-arrow` | the arrow span inside an event-transition cell needs `class="rpm-state-arrow"` |
| `.event-transition .state-to { ... }` | `.rpm-state-to` | the to-state span inside an event-transition cell needs `class="rpm-state-to"` |
| `.section-event-log .event-log-container { ... }` | folded into `.rpm-event-log-container` | rule body (`flex: 1; max-height: none; min-height: 0;`) merged into the base class |
| `.lower-left .section { margin-bottom: 0; }` | dropped | shared `.section` already has correct margins; the override was vestigial |
| `.lower-left .chart-half { height: 251px; }` | new class `.rpm-chart-half-tall` | the chart-half elements in the lower-left column need `class="rpm-chart-half rpm-chart-half-tall"` (or replace `rpm-chart-half` outright) |

**Slide-out help panel consumed from cc-shared.css.** The original page had a full local slide-panel implementation: `.info-overlay` + `.info-panel` + `.info-panel-header` + `.info-panel-header h3` + `.info-panel-close` + `.info-panel-body`, plus `.open` state variants on the overlay and panel. All of that chrome is replaced by cc-shared's existing `.slide-overlay` + `.slide-panel` (default 550px width — slightly wider than the original 440px, accepted as part of standardization). Only the inner content classes (the page-local `<p>`/`<strong>`/`<em>` typography listed above) remain page-local.

**`@media`-wrapped rules carry preceding purpose comments.** Per the spec's rule that `@media`-wrapped rules are subject to all other spec rules (Section 3.13), the three responsive rules (`.rpm-charts-row`, `.rpm-lower-grid`, `.rpm-agent-cards-grid` inside `@media (max-width: 1200px)` and `@media (max-width: 900px)`) each carry a preceding single-line purpose comment. No structural difference from how a base class is annotated; the rules just happen to be inside an `@media` block.

### 3. Class deletions

Page-chrome classes that the page reinvented locally are now provided by cc-shared.css and are gone from this file. Markup must consume the shared classes instead.

| Deleted from rpm | Replaced by (in cc-shared.css) | Notes |
|------------------|--------------------------------|-------|
| `body { ... }` | (provided by cc-shared.css's CHROME) | rule deleted |
| `* { box-sizing: border-box; }` | (provided by cc-shared.css's FOUNDATION reset) | rule deleted |
| `h1 { ... }` | `.page-h1` (with section-class state classes) | the `<h1>` markup needs `class="page-h1 section-platform"` (or the appropriate section class) |
| `a { color: ... }` | (provided by cc-shared.css's FOUNDATION) | rule deleted |
| `.page-subtitle` | `.page-subtitle` (shared) | no change needed at markup; same class name |
| `.header-bar` | `.header-bar` (shared) | no change needed at markup; same class name |
| `.refresh-info` | `.refresh-info` (shared) | no change needed at markup; same class name |
| `.last-updated` | `.last-updated` (shared) | no change needed at markup; same class name |
| `.live-indicator` + `@keyframes pulse` | `.live-indicator` (shared, with shared `pulse` keyframe in FOUNDATION) | no change needed at markup; same class name |
| `.header-right` | `.header-right` (shared) | no change needed at markup; same class name |
| `.section` | `.section` (shared) | no change needed at markup; same class name |
| `.section-header` | `.section-header` (shared) | no change needed at markup; same class name |
| `.section-title` | `.section-title` (shared) | no change needed at markup; same class name |
| `.refresh-badge` | `.refresh-badge-static` (shared, plus `.refresh-badge-event` / `.refresh-badge-live` for event-driven and live-polling cases) | the markup picks the right shared variant for the page's polling mode |
| `.connection-error` + `.connection-error.visible` | `.connection-banner` + `.connection-banner.disconnected` (and other state variants) | the markup uses the shared banner with state classes |
| `.info-overlay` + `.info-overlay.open` | `.slide-overlay` + `.slide-overlay.open` | markup change required |
| `.info-panel` + `.info-panel.open` | `.slide-panel` + `.slide-panel.open` | markup change required |
| `.info-panel-header` | `.slide-panel-header` (shared) | markup change required |
| `.info-panel-header h3` | (shared header h3 styling provided by cc-shared) | descendant rule was page-local; shared version covers it |
| `.info-panel-close` + `.info-panel-close:hover` | `.slide-panel-close` + `.slide-panel-close:hover` (shared) | markup change required |
| `.info-panel-body` | `.slide-panel-body` (shared) | markup change required |

### 4. Class additions

Three additions, each addressing a specific case:

| New class | Why |
|-----------|-----|
| `.rpm-chart-half-tall` | Replaces the descendant rule `.lower-left .chart-half { height: 251px; }`. Used in the lower-left column where vertical space allows a slightly taller chart container. |
| `.rpm-info-panel-body-p` | Leaf class replacing the descendant `.info-panel-body p { ... }` rule. |
| `.rpm-info-panel-body-strong` | Leaf class replacing the descendant `.info-panel-body strong { ... }` rule. |
| `.rpm-info-panel-body-em` | Leaf class replacing the descendant `.info-panel-body em { ... }` rule. |
| `.rpm-state-from` | Leaf class replacing the descendant `.event-transition .state-from { ... }` rule. |
| `.rpm-state-arrow` | Leaf class replacing the descendant `.event-transition .state-arrow { ... }` rule. |
| `.rpm-state-to` | Leaf class replacing the descendant `.event-transition .state-to { ... }` rule. |

### 5. Visual / behavioral changes

Two intentional visual changes; everything else is byte-for-byte preserved.

1. **Help slide-panel width: 440px → 550px.** The original page-local `.info-panel` was 440px wide (and its closed-state offset was -450px). The shared `.slide-panel` defaults to 550px wide (offset -570px). The page now uses the shared default. This is a conscious standardization choice — slightly wider help panels across pages improve consistency for the user's eye and the help text was a touch cramped at 440px. If during QA the wider panel looks wrong, the fix is either to consume `.slide-panel` with a page-local override class or (longer-term) to add a narrower tier to cc-shared's slide-panel sizing.
2. **Page-local scrollbar overrides simplified.** The original `.event-log-container::-webkit-scrollbar` overrides used hardcoded hex literals and the same widths as cc-shared's defaults except for the scrollbar width itself (6px vs 8px). The refactor preserves the 6px override (it's the actual page-local concern) and consumes shared color tokens for track and thumb. No visual change.

### 6. cc-shared.css impact

**No change required.** Every value the page needs already has a token in cc-shared.css. No new tokens added, no existing tokens modified. cc-shared.css remains at 622 rows / 0 drift.

### Downstream impact summary

When the JS/HTML migration session opens `ReplicationMonitoring.ps1`, `ReplicationMonitoring-API.ps1`, and `replication-monitoring.js`:

1. **Class reference updates (everywhere).** Every reference to one of the page-local classes in the rename table must be updated to its `rpm-` prefixed form. Mechanical find-and-replace per row. The `event-type-*` classes preserve their uppercase suffix (`STATE_CHANGE`, `AGENT_START`, etc.) so the JS code that composes the class name can stay simple — just prepend `rpm-event-type-` to the existing event-type code.

2. **Page chrome migration.** Replace local references to the page chrome elements with the shared classes:
   - `<h1>` → add `class="page-h1 section-platform"` (or whichever section class is correct for this page).
   - `<div class="header-bar">` keeps the same class name; no change.
   - `<div class="refresh-info">` keeps the same class name; no change.
   - `<div class="header-right">` keeps the same class name; no change.
   - `<span class="last-updated">` keeps the same class name; no change.
   - `<span class="live-indicator">` keeps the same class name; no change.
   - `<div class="section">`, `<div class="section-header">`, `<h2 class="section-title">`, `<span class="refresh-badge">` all keep their class names (where the markup currently uses these classes). The `refresh-badge` element should be updated to use the appropriate shared variant (e.g., `refresh-badge-static` or `refresh-badge-live` depending on the page's polling mode — replication monitoring is event-driven via WebSocket, so `refresh-badge-event` is the appropriate choice).

3. **Connection error → connection banner replacement.** Same pattern as BI and CR:
   - Replace `<div class="connection-error">` with `<div class="connection-banner">`.
   - Replace local error-display logic with calls into the shared `updateConnectionBanner()` helper from `engine-events.js`.

4. **Slide-out help panel migration (markup change).** The biggest single-place markup change:
   - `<div class="info-overlay">` → `<div class="slide-overlay">`
   - `<div class="info-panel">` → `<div class="slide-panel">`
   - `<div class="info-panel-header">` → `<div class="slide-panel-header">`
   - `<h3>` inside the panel header — keep the element, but the styling no longer comes from a descendant rule; if the shared `.slide-panel-header` includes `<h3>` styling natively, no change is needed; otherwise add `class="slide-panel-header-title"` (whatever the shared file uses).
   - `<button class="info-panel-close">` → `<button class="slide-panel-close">`
   - `<div class="info-panel-body">` → `<div class="slide-panel-body">`
   - JS that adds/removes `.open` on `.info-overlay` and `.info-panel` must target the shared classes instead.

5. **Info-panel content typography (significant).** Every `<p>`, `<strong>`, and `<em>` element inside the panel body must gain a leaf class:
   - `<p>` → add `class="rpm-info-panel-body-p"`
   - `<strong>` → add `class="rpm-info-panel-body-strong"`
   - `<em>` → add `class="rpm-info-panel-body-em"`

   This is mechanical-but-tedious if the help text is sizable. A find-and-replace pass through the help-panel HTML is the cleanest approach.

6. **Event-transition leaf classes.** Every event-transition cell rendered by the JS must have its inner spans carry leaf classes:
   - The "from state" span → add `class="rpm-state-from"`
   - The arrow span → add `class="rpm-state-arrow"`
   - The "to state" span → add `class="rpm-state-to"`

   The JS probably builds these inline via string concatenation. Each transition-rendering point needs the three classes added to the spans it emits.

7. **Lower-left tall-chart class addition.** Any `.chart-half` element rendered into the lower-left column of the lower-grid currently relies on the descendant rule `.lower-left .chart-half { height: 251px; }` to override its default 180px height. After the refactor the markup must explicitly add `class="rpm-chart-half rpm-chart-half-tall"` (or use `rpm-chart-half-tall` alone) on those elements. JS or route-file HTML that renders charts into the lower-left needs to apply the additional class.

8. **No JS event-binding changes.** All event bindings remain conceptually the same — only the class names being matched have changed.

---

## (Future entries land here as files are refactored)

Each new refactored file follows the same six-category structure plus the Downstream impact summary. Keep entries in the order files are refactored (chronological), not alphabetical, so the change history reads naturally.

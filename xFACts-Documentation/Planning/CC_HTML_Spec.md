# Control Center HTML File Format Specification

**Status:** `[DRAFT — design session not yet held]`
**Owner:** Dirk

> Part of the Control Center File Format initiative. For initiative direction, current state, session log, and the platform-wide prefix registry, see `CC_Initiative.md`.

---

## Purpose

This specification will define the structural conventions for HTML emitted by Control Center route files and helper modules. CC pages do not have standalone `.html` files; HTML is emitted as inline strings from PS route files (`*.ps1` in `scripts/routes/`) and from JS file rendering functions. This spec covers the structural rules for that emitted HTML — element ID conventions, class attribute conventions, and the boundaries of what's required versus recommended.

**This document is currently in pre-design state.** The spec body sections below are stubs. The "Pre-design observations" section holds harvested content from the retired `CC_FileFormat_Spec.md` (v0.2, April 2026) that predates the CSS-era principles established during the CSS spec design (typed sections, three-character page prefixes, variants-as-rows catalog model, drift codes). The harvested content has not been validated against those principles, and additionally predates the cc-shared.css migration — many of the IDs identified as mandatory in the retired Spec doc may now be rendered by shared chrome rather than by route HTML. The HTML spec design session will review every harvested item, decide what survives, and draft the actual spec body.

---

## Pre-design observations

Harvested from the retired `CC_FileFormat_Spec.md` (v0.2, April 2026). Each observation carries review notes flagging items the design session needs to evaluate. **None of the content below is authoritative.** When the design session lands, content moves out of this section into the appropriate numbered sections, with whatever revisions emerge. This section gets deleted when it is empty.

### Populator housekeeping reminder (not a spec item)

When the HTML investigation begins, before any spec-derived changes, `Populate-AssetRegistry-HTML.ps1` needs catch-up work for issues unrelated to the format spec itself:

- **Schema-migrated columns (2026-05-03):** the populator references `state_modifier`, `component_subtype`, and `parent_object` — all dropped from `dbo.Asset_Registry` in the CSS spec migration. Bulk insert fails before reaching the HTML format spec questions.
- **Schema cleanup columns (2026-05-04, G-INIT-3):** the populator references `design_notes` and `related_asset_id` in its DataTable definition and writes NULL to both. These columns were dropped from the table along with `is_active`. Remove the `[void]$dt.Columns.Add(...)` calls and the corresponding NULL writes.
- **`is_active` filter on Asset_Registry SELECT:** the populator's CSS_CLASS DEFINITION lookup query has `AND is_active = 1` filtering against `Asset_Registry`. With that column gone, the filter must be removed. (The separate `WHERE is_active = 1` in the `Object_Registry` SELECT is reading a different table's column — leave that one alone.)
- **`purpose_description` writes:** the populator currently writes hardcoded NULL. The HTML spec design session decides whether HTML rows should carry purpose-description content (and from where), so this stays NULL until the spec lands.

These are housekeeping items, not design questions — fix them as the first pass of the HTML investigation so the populator can run cleanly against the current schema, then move into spec design.

### Observation 1 — Mandated ID conventions

The retired Spec doc identified these IDs as mandated by the chrome contract — required to appear on every CC page:

| ID | Purpose | Required? |
|---|---|---|
| `connection-banner` | Connection state banner placeholder | Required on every page |
| `last-update` | Last-updated timestamp display | Required on every page |
| `engine-row` | Engine cards container | Required if the page has engine cards |
| `card-engine-<slug>` or `card-engine` | Per-process engine card | Required per engine card |
| `engine-bar-<slug>` or `engine-bar` | Per-process engine status bar | Required per engine card |
| `engine-cd-<slug>` or `engine-cd` | Per-process countdown text | Required per engine card |

**Review notes (this is the most important review pass for this spec):**

- The retired Spec doc was written before `cc-shared.css` existed. Several of these IDs may now be rendered by shared chrome rather than by route HTML — `connection-banner` in particular is part of cc-shared's CHROME section (`.connection-banner` class with state variants), and route files that previously declared `<div id="connection-banner">` placeholders may no longer need to. The design session needs to verify, for each mandatory ID listed:
  - Does the element still appear in route HTML, or is it rendered by shared chrome on every page automatically?
  - If by shared chrome, the ID is mandated *by virtue of being part of shared chrome*, not by the route file. The route file shouldn't redeclare it.
  - If by route HTML, the route file is the authoritative source and the spec should mandate it there.
- The `<slug>` suffix convention (e.g., `card-engine-bidata`, `card-engine-batchmon`) matches a real pattern but the design session should confirm against the actual codebase what the slug values are and whether they're documented anywhere.
- The "or `engine-bar`" alternative (without slug) is used on pages that have only a single engine. Whether this is actually a valid pattern or a legacy one worth deprecating is a design question.

### Observation 2 — Page-specific IDs

The retired Spec doc proposed these recommended (not mandated) naming patterns for page-specific IDs:

- Slideout overlays: `<purpose>-slideout-overlay`
- Slideout panels: `<purpose>-slide-panel`
- Modal overlays: `<purpose>-modal-overlay`
- Modals: `<purpose>-modal`
- Form fields: `<form>-<field>` (e.g., `date-range-start`)

The retired Spec doc captured: pages may define their own IDs for slideouts, modals, content containers, etc. The parser extracts every `id="..."` it finds and emits an `HTML_ID` row. Pages can use any IDs they need; the spec recommends but does not strictly mandate naming conventions for page-specific IDs.

**Review notes:**

- The recommended-not-mandated stance is consistent with the CSS spec's authoring discipline approach (where some patterns are enforced by drift codes and others are guidance).
- The `<purpose>-slideout-overlay` pattern interacts with the CSS spec's typed-section model. If route HTML uses `<div id="bsv-request-slideout-overlay" class="slide-overlay">`, the ID has the page prefix (`bsv-`) embedded in the purpose portion. Whether the design session mandates page-prefix scoping for IDs (analogous to the CSS class prefix rule) is a real question — it would tighten consistency but adds authoring discipline that may not pay off.
- The "Form fields: `<form>-<field>`" pattern (e.g., `date-range-start`) is from the retired Spec doc but isn't obviously in current use across pages. The design session should validate against actual route HTML.

### Observation 3 — What is NOT mandated

The retired Spec doc listed:

- Class attributes inside route HTML — those reference `CSS_CLASS` components already cataloged from the CSS file
- Element types (`<div>`, `<button>`, etc.)
- Inline styles
- Event handler attributes (`onclick=...`)

**Review notes:**

- Class attributes inside route HTML *do* matter under the new model. The CSS spec mandates page-prefix scoping for page-local classes (`.bsv-pipeline-card`); the HTML emitting that class must use the prefixed form (`<div class="bsv-pipeline-card">`). This isn't mandated by the HTML spec per se — it's mandated by the CSS spec via the rule that classes referenced in HTML must match CSS-defined classes. The HTML spec should reflect this consistency expectation.
- Inline styles arguably should be flagged. The CSS spec's whole point is to centralize styling decisions; inline styles in route HTML defeat the spec by hiding styling decisions outside the cataloged CSS files. The design session should consider whether `style="..."` attributes warrant a drift code.
- Event handler attributes (`onclick="..."`) are how route HTML connects to JS. The CSS spec's no-descendant rule and the state-on-element pattern (Section 7.3 of `CC_CSS_Spec.md`) both push toward JS-driven state class toggles, which means `onclick` attributes are the connection point. They should not be forbidden but their format conventions might be worth specifying.

### Observation 4 — HTML emission contexts

The retired Spec doc didn't explicitly distinguish between HTML emitted from PS route files and HTML emitted from JS rendering functions, but both contexts produce HTML that the catalog parser may need to scan.

**Review notes:**

- The design session needs to define how the catalog parser handles HTML in both contexts. Options:
  - Parse PS route files for HTML (currently scoped in `CC_PS_Route_Spec.md` Observation 6 — HTML_ID extraction from inline strings).
  - Parse JS files for HTML emitted by template literals or string concatenation (currently not scoped anywhere).
  - Recognize that JS-emitted HTML is inherently dynamic and harder to parse than PS-emitted HTML, and decide whether to attempt it at all.
- This affects what the HTML spec actually covers. If JS-emitted HTML is in scope, the HTML spec's rules apply to JS template strings too, which adds complexity.

### Observation 5 — Element type and structural conventions

The retired Spec doc was silent on element-type conventions (when to use `<button>` vs `<div onclick>`, when to use `<table>` vs `<div>` grids, etc.). These are downstream of CSS spec rules and JS spec rules but may warrant explicit HTML-spec coverage.

**Review notes:**

- The CSS spec's no-element-selector rule (`FORBIDDEN_ELEMENT_SELECTOR` outside FOUNDATION) means CSS rules don't depend on element types. This gives HTML authors flexibility but also removes one source of consistency enforcement.
- Whether the HTML spec mandates element types for specific patterns (e.g., interactive elements must use `<button>` for accessibility) is a design question. The accessibility angle is genuinely valuable but may be out of scope for the catalog-driven enforcement model.

---

## 1. Scope and contexts  *[stub]*

(To be defined during HTML spec design. Will cover what HTML this spec applies to: route-file inline HTML, helper-emitted HTML, JS-emitted HTML, etc.)

---

## 2. Mandated IDs  *[stub]*

(To be defined during HTML spec design. Will cover the platform-wide IDs every page or every-engine-card-page must include.)

---

## 3. Recommended ID naming patterns  *[stub]*

(To be defined during HTML spec design.)

---

## 4. Class attribute conventions  *[stub]*

(To be defined during HTML spec design. Will tie class names in HTML back to the CSS spec's prefix rules.)

---

## 5. Inline style policy  *[stub]*

(To be defined during HTML spec design. Will decide whether `style="..."` attributes are forbidden, discouraged, or unrestricted.)

---

## 6. Event handler attribute conventions  *[stub]*

(To be defined during HTML spec design.)

---

## 7. Element type conventions  *[stub]*

(To be defined during HTML spec design.)

---

## 8. Required patterns summary  *[stub]*

(To be defined during HTML spec design.)

---

## 9. Forbidden patterns  *[stub]*

(To be defined during HTML spec design.)

---

## 10. Illustrative example  *[stub]*

(To be defined during HTML spec design.)

---

## 11. Catalog model essentials  *[stub]*

(To be defined during HTML spec design.)

---

## 12. What the parser extracts  *[stub]*

(To be defined during HTML spec design.)

---

## 13. Drift codes reference  *[stub]*

(To be defined during HTML spec design. HTML-specific drift codes only.)

---

## 14. Compliance queries  *[stub]*

(To be defined during HTML spec design.)

---

## Revision history

| Version | Date | Description |
|---|---|---|
| 0.2 | 2026-05-04 | Added populator housekeeping reminder at the top of pre-design observations covering the dropped columns from the 2026-05-03 schema migration and the 2026-05-04 G-INIT-3 cleanup. Reminder is bookkeeping, not spec content; gets removed once the populator catch-up lands. |
| 0.1 | 2026-05-04 | Initial scaffold. Pre-design observations harvested from the retired `CC_FileFormat_Spec.md` Part 5, awaiting review during HTML spec design session. |

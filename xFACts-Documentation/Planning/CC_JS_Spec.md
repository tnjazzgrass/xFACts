# Control Center JavaScript File Format Specification

**Status:** `[DRAFT — design session not yet held]`
**Owner:** Dirk

> Part of the Control Center File Format initiative. For initiative direction, current state, session log, and the platform-wide prefix registry, see `CC_Initiative.md`.

---

## Purpose

This specification will define the structural conventions every Control Center JavaScript file must follow. The conventions exist for one reason: machine readability. Every rule will be justified by a specific extraction the catalog parser performs against the file.

**This document is currently in pre-design state.** The spec body sections below are stubs. The "Pre-design observations" section holds harvested content from the retired `CC_FileFormat_Spec.md` (v0.2, April 2026) that predates the CSS-era principles established during the CSS spec design (typed sections, three-character page prefixes, variants-as-rows catalog model, drift codes, custom property tokens, state-on-element pattern). The harvested content has not been validated against those principles. The JS spec design session will review every harvested item, decide what survives, and draft the actual spec body.

---

## Pre-design observations

Harvested from the retired `CC_FileFormat_Spec.md` (v0.2, April 2026). Each observation carries review notes flagging items the JS spec design session needs to evaluate. **None of the content below is authoritative.** When the design session lands, content moves out of this section into the appropriate numbered sections, with whatever revisions emerge. This section gets deleted when it is empty.

### Populator housekeeping reminder (not a spec item)

When the JS investigation begins, before any spec-derived changes, `Populate-AssetRegistry-JS.ps1` needs catch-up work for issues unrelated to the format spec itself:

- **Schema-migrated columns (2026-05-03):** the populator references `state_modifier`, `component_subtype`, and `parent_object` — all dropped from `dbo.Asset_Registry` in the CSS spec migration. Bulk insert fails before reaching the JS format spec questions.
- **Schema cleanup columns (2026-05-04, G-INIT-3):** the populator references `design_notes` and `related_asset_id` in its DataTable definition and writes NULL to both. These columns were dropped from the table along with `is_active`. Remove the `[void]$dt.Columns.Add(...)` calls and the corresponding NULL writes.
- **`is_active` filter on Asset_Registry SELECT:** the populator's CSS_CLASS DEFINITION lookup query has `AND is_active = 1` filtering against `Asset_Registry`. With that column gone, the filter must be removed. (The separate `WHERE is_active = 1` in the `Object_Registry` SELECT is reading a different table's column — leave that one alone.)
- **`purpose_description` writes:** the populator currently writes hardcoded NULL. The JS spec design session decides whether JS rows should carry purpose-description content (and from where), so this stays NULL until the spec lands.

These are housekeeping items, not design questions — fix them as the first pass of the JS investigation so the populator can run cleanly against the current schema, then move into spec design.

### Observation 1 — File header structure

The retired Spec doc proposed this JS file header template:

```javascript
// ============================================================================
// xFACts Control Center - <Component Description> (<filename>)
// Location: E:\xFACts-ControlCenter\public\js\<filename>
// Version: Tracked in dbo.System_Metadata (component: <Component>)
//
// <Purpose paragraph>
//
// CHANGELOG
// ---------
// YYYY-MM-DD  <Description>
// ============================================================================
```

Required content was specified as: file identity line, location line, version line, blank line, free-form purpose paragraph, blank line, CHANGELOG heading, reverse-chronological dated entries.

**Review notes:**

- The CHANGELOG block needs to be reconsidered. The CSS spec adopted "git is the source of truth for change history" and forbids CHANGELOG blocks (drift code `FORBIDDEN_CHANGELOG_BLOCK`). The same logic likely applies to JS, but the design session should make this an explicit decision rather than an inherited assumption.
- The retired Spec doc carved out "FILE ORGANIZATION heading (CSS only — sections are too few to enumerate in JS/PS1 headers)" — implying JS headers don't get a FILE ORGANIZATION list. Whether typed sections in JS warrant such a list is a design question for the session. If the JS spec adopts a typed-section model analogous to CSS's, a FILE ORGANIZATION list becomes useful.
- Component name extraction from the `Version:` line is consistent with what the CSS parser does and should carry forward as a pattern.

### Observation 2 — Section banner format

The retired Spec doc proposed this JS section banner template:

```javascript
// ============================================================================
// N. <SECTION TITLE IN CAPS>
// ----------------------------------------------------------------------------
// <Free-form description, one or more lines, explaining the section's
// purpose and any cross-references.>
// ============================================================================
```

Banner format was specified as four lines: top rule (78 `=` characters), section number and title in caps, bottom rule (78 `-` characters) followed by free-form section description, closing rule. Section numbering started at 1 and incremented without gaps; sub-sections were not used in banners.

**Review notes:**

- The CSS spec adopted a 5-line banner format with `<TYPE>: <NAME>` titles and a mandatory `Prefixes:` declaration line, replacing the numbered free-form titles. The design session should decide whether JS adopts the same typed-section model with the same banner shape, or whether JS's organizational concerns are different enough to warrant a different banner shape.
- The "every line of code below the file header must belong to exactly one section" rule from the retired Spec doc carries forward in principle. The CSS spec enforces this strictly; JS should too.
- The "no sub-section banners (sub-sections live in the description paragraph if needed)" rule reflects pre-typed-section thinking. The CSS spec adopted sub-section markers (`/* -- label -- */`) as a separate lightweight construct distinct from banners, with discipline about when to use which (Section 9 of `CC_CSS_Spec.md`). The design session should decide if JS adopts the same pattern.

### Observation 3 — Mandatory section structure (highest-value harvested content)

This is the most substantive design thinking in the retired Spec doc and is the strongest starting point for JS spec design.

**Mandatory section names** were proposed for specific kinds of content. The parser uses these section names to classify components correctly.

| Section name | Contents | Required? |
|---|---|---|
| `<N>. SHARED CONSTANTS` | Top-level `var`/`let`/`const` constants intended for cross-file consumption | Required if the file exports any constants |
| `<N>. PAGE CONSTANTS` | Top-level constants used only within this file | Optional |
| `<N>. STATE` | Top-level mutable variables (state holders) | Required if the file declares any state |
| `<N>. PAGE HOOKS` | The `onPageRefresh`, `onPageResumed`, `onSessionExpired` etc. hook functions | Required if the file defines any page hooks |
| Other named sections | Functions grouped by purpose | As many as needed |

The section name `STATE` was mandated, not free-form. A file calling its state section `VARIABLES` or `MODULE STATE` would fail compliance.

The section name `SHARED CONSTANTS` was mandated when constants are exposed for external use. Internal-only constants go in `PAGE CONSTANTS` (also mandated name).

**Mandatory section ordering** was proposed:

1. `SHARED CONSTANTS` (if present)
2. `PAGE CONSTANTS` (if present)
3. `STATE` (if present)
4. Any number of functional sections, in whatever order makes sense for the file
5. `PAGE HOOKS` (always last among the mandated sections, if present)

The retired Spec doc captured the rationale: "This rigidity is what lets the parser distinguish a top-level var that's a cataloged constant from a top-level var that's mutable state, without inspecting whether the variable gets reassigned later."

**Review notes:**

- The mandatory-named-sections concept maps cleanly to the CSS spec's typed-section model (FOUNDATION, CHROME, LAYOUT, CONTENT, OVERRIDES, FEEDBACK_OVERLAYS). Both are about giving the parser a deterministic way to classify content. The JS spec session should decide whether to adopt the typed-section model wholesale (e.g., banner format `<N>. SHARED CONSTANTS` becomes `SHARED_CONSTANTS: <name>` to match CSS's `<TYPE>: <NAME>` shape) or whether the JS use case is different enough to keep a JS-flavored variant.
- The choice of names is worth re-deciding. `SHARED CONSTANTS`, `PAGE CONSTANTS`, `STATE`, `PAGE HOOKS` are JS-flavored and probably correct. The CSS-era types don't map directly (no JS analogue of FOUNDATION or CHROME).
- Whether each section needs a `Prefixes:` declaration analogue is unclear. JS doesn't have CSS's leftmost-class scoping problem, but page-prefix-scoped JS function names (e.g., `bsv_loadActivity()` for `business-services.js`) could enforce the same page-identity discipline. The design session should decide.
- `SHARED CONSTANTS` vs `PAGE CONSTANTS` is a sub-categorization within "constants" — analogous to how `CONTENT` can have multiple banners (CONTENT: PIPELINE STATUS, CONTENT: STORAGE STATUS) in CSS. Consider whether the JS analogue should formally use `<TYPE>: <NAME>` format like CSS, or stay as straight section names.
- Whether `PAGE HOOKS` is genuinely mandatory-last or just conventionally-last is worth re-deciding. The CSS-era principle is that ordering rules should reflect real cascade dependencies (e.g., FOUNDATION before CHROME because chrome consumes foundation tokens). What's the analogous dependency reason for PAGE HOOKS being last?

### Observation 4 — What the parser extracts

The retired Spec doc proposed these component types for JS files:

- **JS_CONSTANT** — top-level `var`/`let`/`const` declarations under a `SHARED CONSTANTS` or `PAGE CONSTANTS` section
- **JS_STATE** — top-level `var`/`let`/`const` declarations under a `STATE` section
- **JS_FUNCTION** — top-level function declarations not under a `PAGE HOOKS` section
- **JS_HOOK** — top-level function declarations under a `PAGE HOOKS` section

For each extracted component:

- `component_name` — the variable or function name
- `signature` — for functions: `(arg1, arg2, ...)`. For constants/state: the literal value if short, or `<type>` (e.g., `array`, `object`, `null`) if not
- `source_section` — the section banner the declaration appears under
- `purpose_description` — extracted from the JSDoc comment block above the declaration

**Review notes:**

- The component types are reasonable starting points and align with the CSS spec's classification approach.
- Function `signature` shape — should it be just the parameter list, or include return type / JSDoc annotations? Worth deciding based on what queries we expect to run against the catalog.
- "Literal value if short, or `<type>` if not" for constants/state — the threshold for "short" needs definition.
- Alignment with the variants-as-rows catalog model — JS doesn't have CSS-style selector variants, but might have analogous patterns (e.g., multiple function definitions of the same name across guards, like the `pageRefresh` example in Observation 7). Whether those need a `variant_type` value (e.g., `guard`) is a design question.

### Observation 5 — Function documentation

The retired Spec doc proposed two acceptable formats for function documentation comments:

**Format A — JSDoc (preferred):**

```javascript
/**
 * <One-line summary, mandatory>
 *
 * <Optional longer description>
 *
 * @param {<type>} <name> - <description>
 * @returns {<type>} <description>
 */
function functionName(arg1, arg2) {
    ...
}
```

**Format B — Plain block comment (acceptable for short functions):**

```javascript
// <One-line summary, mandatory>
function functionName(arg1, arg2) {
    ...
}
```

The first non-`@`-tagged line of the docstring becomes `purpose_description`. Compliance violations: function declared with no preceding comment, or function declared with a comment that's not directly above it (blank line in between).

**Review notes:**

- The two-format approach is reasonable. The design session should decide whether JSDoc is genuinely preferred (worth flagging plain-block as a `WARNING` or similar lower-severity drift) or whether a simpler standard (one-line summary mandatory, full JSDoc optional for complex functions) is cleaner.
- The CSS spec's parallel concept is the per-class purpose comment (single-line block comment, one-sentence purpose). JS function docs are richer because functions take parameters and return values. The mapping isn't 1:1.

### Observation 6 — Constant and state documentation

The retired Spec doc proposed: top-level constants and state variables must be preceded by a single-line comment describing their purpose.

```javascript
// 1-indexed array; MONTH_NAMES[12] returns 'December'
var MONTH_NAMES = ['', 'January', ...];

// Per-slug state: { lastEvent, countdown, lastRefresh }
var engineState = {};
```

The comment becomes `purpose_description` in the registry. Compliance violation: top-level declarations under SHARED CONSTANTS, PAGE CONSTANTS, or STATE without a preceding single-line comment.

**Review notes:**

- This pattern aligns directly with the CSS spec's purpose-comment requirement on base classes. Carries forward cleanly.

### Observation 7 — Module-level guards

The retired Spec doc captured: the `if (typeof pageRefresh !== 'function') { window.pageRefresh = ... }` pattern in `engine-events.js` is a known case where a function is conditionally assigned to `window`. The proposed treatment was to catalog this as a `JS_FUNCTION` named `pageRefresh` defined in the section the guard appears in, with a `notes` field flagging it as a conditional definition.

The retired Spec doc also noted: when the guard is removed (per the chrome plan's backlog item), this special case can be removed from the parser too.

**Review notes:**

- This is a real edge case the parser will need to handle. The proposed treatment is reasonable.
- The dependency on the chrome plan's backlog item is a known cleanup task. If `engine-events.js` retires fully (per the cc-shared.css migration), this special case may become moot.

### Observation 8 — What is NOT extracted from JS files

The retired Spec doc proposed these exclusions:

- Inner functions (anything declared inside another function)
- IIFE-wrapped code
- Anonymous functions assigned to variables (extracted as the variable's value, not as functions in their own right)
- Object methods (extracted as part of the parent object's value, not standalone)
- Private utility functions inside `function` scope
- Comments (used for `purpose_description` extraction, not cataloged separately)

**Review notes:**

- The exclusion list is sensible on its face. The design session should validate against actual JS files in the codebase to confirm none of these exclusions hide content that should be cataloged.
- Anonymous functions assigned to top-level `var`/`let`/`const` (e.g., `var loadData = function() { ... }`) are a JS pattern that blurs the JS_CONSTANT vs JS_FUNCTION distinction. The design session should decide whether these are JS_FUNCTION rows (because they behave like functions) or JS_CONSTANT rows with `<type>` = function in signature.

---

## 1. Required structure  *[stub]*

(To be defined during JS spec design.)

---

## 2. File header  *[stub]*

(To be defined during JS spec design.)

---

## 3. Section banners  *[stub]*

(To be defined during JS spec design.)

---

## 4. Section types  *[stub]*

(To be defined during JS spec design.)

---

## 5. Naming conventions  *[stub]*

(To be defined during JS spec design. Includes: page-prefix scoping for function names, constant naming conventions, state variable naming conventions, hook function naming conventions.)

---

## 6. Function definitions  *[stub]*

(To be defined during JS spec design.)

---

## 7. Constant and state definitions  *[stub]*

(To be defined during JS spec design.)

---

## 8. Hook functions  *[stub]*

(To be defined during JS spec design.)

---

## 9. Comments  *[stub]*

(To be defined during JS spec design.)

---

## 10. Module-level guards and conditional definitions  *[stub]*

(To be defined during JS spec design.)

---

## 11. Required patterns summary  *[stub]*

(To be defined during JS spec design.)

---

## 12. Forbidden patterns  *[stub]*

(To be defined during JS spec design.)

---

## 13. Illustrative example  *[stub]*

(To be defined during JS spec design.)

---

## 14. Catalog model essentials  *[stub]*

(To be defined during JS spec design. Will document the JS-relevant component_type values, variant_type values if any, and how the parser populates `dbo.Asset_Registry` for JS files.)

---

## 15. What the parser extracts  *[stub]*

(To be defined during JS spec design.)

---

## 16. Drift codes reference  *[stub]*

(To be defined during JS spec design. JS-specific drift codes only.)

---

## 17. Compliance queries  *[stub]*

(To be defined during JS spec design. CSS-scoped queries from `CC_CSS_Spec.md` are a starting reference for what to model. JS-specific queries scoped to `WHERE file_type = 'JS'`.)

---

## Revision history

| Version | Date | Description |
|---|---|---|
| 0.2 | 2026-05-04 | Added populator housekeeping reminder at the top of pre-design observations covering the dropped columns from the 2026-05-03 schema migration and the 2026-05-04 G-INIT-3 cleanup. Reminder is bookkeeping, not spec content; gets removed once the populator catch-up lands. |
| 0.1 | 2026-05-04 | Initial scaffold. Pre-design observations harvested from the retired `CC_FileFormat_Spec.md` Part 3, awaiting review during JS spec design session. |

# Control Center PowerShell Route File Format Specification

**Status:** `[DRAFT — design session not yet held]`
**Owner:** Dirk

> Part of the Control Center File Format initiative. For initiative direction, current state, session log, and the platform-wide prefix registry, see `CC_Initiative.md`.

---

## Purpose

This specification will define the structural conventions every Control Center PowerShell route file must follow. Route files are page route handlers and API route handlers — `*.ps1` files in `scripts/routes/` that define HTML routes (page rendering) or API endpoints. The conventions exist for one reason: machine readability. Every rule will be justified by a specific extraction the catalog parser performs against the file.

**This document is currently in pre-design state.** The spec body sections below are stubs. The "Pre-design observations" section holds harvested content from the retired `CC_FileFormat_Spec.md` (v0.2, April 2026) that predates the CSS-era principles established during the CSS spec design. The harvested content has not been validated against those principles. The PS route spec design session will review every harvested item, decide what survives, and draft the actual spec body.

---

## Pre-design observations

Harvested from the retired `CC_FileFormat_Spec.md` (v0.2, April 2026). Each observation carries review notes flagging items the design session needs to evaluate. **None of the content below is authoritative.** When the design session lands, content moves out of this section into the appropriate numbered sections, with whatever revisions emerge. This section gets deleted when it is empty.

### Observation 1 — Two kinds of PS1 files

The retired Spec doc identified that CC PowerShell files come in two flavors with different extraction rules:

- **Type 1 — Route files** (page route + API route files, e.g., `BIDATAMonitoring.ps1`, `BIDATAMonitoring-API.ps1`). Define HTML routes (page rendering) or API endpoints. Use `Add-PodeRoute` for route registration. Parser extracts `API_ROUTE` rows and (for page route files) `HTML_ID` rows from inline HTML.
- **Type 2 — Module files** (helpers, e.g., `xFACts-Helpers.psm1`). Define PowerShell functions. Use `Export-ModuleMember` at the bottom. Parser extracts `PS_FUNCTION` rows.

This document covers Type 1 (route files). Type 2 (module files) is covered in `CC_PS_Module_Spec.md`.

**Review notes:**

- The route-vs-module distinction is real and reflects how the codebase is organized. The split into two spec docs is consistent with the file-type-per-doc principle established in this initiative.
- Some structural rules will be shared between route and module specs (file header structure, section banner format). Where they're identical, both specs duplicate the rule rather than cross-referencing.

### Observation 2 — File header structure

The retired Spec doc proposed this PS1 file header template:

```powershell
# ============================================================================
# xFACts Control Center - <Component Description> (<filename>)
# Location: E:\xFACts-ControlCenter\scripts\<full-path>
# Version: Tracked in dbo.System_Metadata (component: <Component>)
#
# <Purpose paragraph>
#
# CHANGELOG
# ---------
# YYYY-MM-DD  <Description>
# ============================================================================
```

**Review notes:**

- The CHANGELOG block needs to be reconsidered. The CSS spec adopted "git is the source of truth for change history" and forbids CHANGELOG blocks. The same logic likely applies to PS, but the design session should make this an explicit decision.
- The retired Spec doc carved out PS1 headers as not having a FILE ORGANIZATION list (CSS-only feature). Whether route files benefit from a FILE ORGANIZATION list is a design question — depends on whether the typed-section model adopted for CSS extends to PS.

### Observation 3 — Required structure

The retired Spec doc proposed this top-level structure for both types of PS1 files:

```
File header block
[blank line]
Section banner: 1. <First section>
[content]
...
Section banner: N. <Last section>
[content]
[end of file]
```

For route files specifically, the conventional sections were not strictly mandated by name (unlike JS where `SHARED CONSTANTS`, `STATE`, etc. were mandatory).

**Review notes:**

- The CSS spec adopted typed sections (FOUNDATION, CHROME, LAYOUT, etc.) with strict ordering. Whether route files benefit from typed sections is a design question. Possible candidates: `IMPORTS`, `CONSTANTS`, `ROUTES`, `HELPERS`. The design session should evaluate against actual route files to see what natural groupings exist.

### Observation 4 — Section banner format

The retired Spec doc proposed this PS1 section banner template:

```powershell
# ============================================================================
# N. <SECTION TITLE IN CAPS>
# ----------------------------------------------------------------------------
# <Free-form description, one or more lines, explaining the section's
# purpose and any cross-references.>
# ============================================================================
```

Same four-line shape as the JS spec. Numbered free-form sections starting at 1.

**Review notes:**

- The CSS spec adopted a 5-line banner format with `<TYPE>: <NAME>` titles and a mandatory `Prefixes:` declaration line. The design session should decide whether route files adopt the same shape, or whether the route-file use case is different enough to keep numbered free-form sections.
- Whether route files need a `Prefixes:` analogue is a real design question. Page-prefix scoping in PS would mean function names, route paths, or helper variable names tagged with the page's three-character prefix — but route paths are externally-facing identifiers (URLs hit by JavaScript fetch calls) and may not benefit from prefix scoping the way CSS classes and JS function names do.

### Observation 5 — Sub-section markers

The retired Spec doc proposed:

```powershell
# -- <Sub-section description> --
```

Single-line comment, dash-flanked, ignored by the parser, used as visual reading aid only.

**Review notes:**

- Carries forward in principle. Same as the CSS spec's `/* -- label -- */` sub-section markers.
- The CSS spec also formalized the discipline rule: prefer creating a new banner over expanding an existing one when adding distinct concepts. The same discipline should apply to PS route files.

### Observation 6 — What the parser extracts from route files

The retired Spec doc proposed these component types for files containing `Add-PodeRoute` calls:

- **API_ROUTE** — every `Add-PodeRoute` invocation. `component_name` = the path (e.g., `/api/bidata/todays-build`). `signature` = `<METHOD> <path>`. `source_section` = section banner. `purpose_description` = comment block immediately preceding the `Add-PodeRoute` call.

For page route files (the non-API variant), additionally:

- **HTML_ID** — every `id="..."` attribute appearing in inline HTML strings. `component_name` = the ID value. `source_section` = section banner.

Compliance violation proposed: `Add-PodeRoute` call with no preceding comment block.

**Review notes:**

- The component types align with the CSS spec's pattern of one row per cataloguable construct.
- Whether `API_ROUTE` `purpose_description` extraction comes from a comment block immediately preceding the `Add-PodeRoute` call is a reasonable starting point. The design session should evaluate against actual route files to see if a more structured approach (e.g., comment-based help on the ScriptBlock) would be more consistent with how module functions are documented.
- HTML_ID extraction from inline HTML strings embedded in PS string literals is non-trivial parser work. The design session should confirm the approach is feasible. The CSS parser already handles HTML_ID extraction from CSS selectors; the PS implementation will be different because the IDs are inside string literals, not in PS syntax.

### Observation 7 — Route documentation pattern

The retired Spec doc proposed this convention for documenting routes:

```powershell
# -- /api/bidata/todays-build --
# Returns today's BIDATA build status, step counts, and average durations.
# Used by loadLiveActivity in bidata-monitoring.js.
Add-PodeRoute -Method Get -Path '/api/bidata/todays-build' -Authentication 'ADLogin' -ScriptBlock {
    ...
}
```

The first line is the sub-section marker (route path). The lines after are the description. The parser uses up to the blank line or `Add-PodeRoute` line.

**Review notes:**

- Reasonable starting pattern. The design session should validate against actual route files.
- The cross-reference convention ("Used by loadLiveActivity in bidata-monitoring.js") is useful but not enforceable by the parser. Whether to mandate it or recommend it is a design question.

### Observation 8 — Inline JavaScript handling

The retired Spec doc captured this rule: route files (page route .ps1, not API .ps1) may contain `<script>` blocks within their inline HTML strings. The convention is that **page logic lives in the separate .js file**, not inline. Inline `<script>` blocks are tolerated for narrow purposes only.

**Acceptable inline JS:**

- A single small `<script>` block immediately before the `engine-events.js` script tag, defining the `ENGINE_PROCESSES` map and any other configuration the shared module needs at load time.
- Inline event handler attributes (`onclick="someFunction()"`, `onchange="..."`, etc.) referencing functions defined in the page's `.js` file. These are normal HTML usage.

**Substantive inline JS — flagged as WARNING:**

- A `<script>` block of more than 5 lines (excluding blank lines and comments)
- Function definitions inside `<script>` blocks (any number of lines)
- Logic beyond simple variable initialization

The compliance violation message proposed: `Line N: Substantive inline <script> block (X lines). Move to <pagename>.js per CC convention.`

**Review notes:**

- This is genuinely valuable content. The 5-line threshold and the no-function-definitions rule give a concrete WARNING-level test that could land directly.
- The "Move to <pagename>.js per CC convention" guidance assumes every page has a corresponding `.js` file. Confirm against actual page inventory — there might be pages without dedicated JS files where the bootstrap pattern legitimately needs more than 5 lines.
- The CSS spec's drift code model uses `WARNING` severity implicitly through parser behavior. Whether route files need an explicit severity model is a design question, or whether substantive inline JS just emits a drift code (analogous to `FORBIDDEN_DESCENDANT` or similar).

### Observation 9 — Component name extraction from Version line

The retired Spec doc identified that the `Version: Tracked in dbo.System_Metadata (component: <Component>)` line in the file header is the canonical source of the file's component name, used by the parser for cross-reference validation.

**Review notes:**

- Carries forward as a pattern. Same convention used in CSS spec's file header.

---

## 1. Required structure  *[stub]*

(To be defined during PS route spec design.)

---

## 2. File header  *[stub]*

(To be defined during PS route spec design.)

---

## 3. Section banners  *[stub]*

(To be defined during PS route spec design.)

---

## 4. Section types  *[stub]*

(To be defined during PS route spec design.)

---

## 5. Route definitions  *[stub]*

(To be defined during PS route spec design.)

---

## 6. Route documentation  *[stub]*

(To be defined during PS route spec design.)

---

## 7. Inline HTML in route files  *[stub]*

(To be defined during PS route spec design. Will cover ID conventions in inline HTML, the relationship to `CC_HTML_Spec.md`, and the boundaries between HTML emitted from PS and HTML emitted from JS.)

---

## 8. Inline JavaScript in route files  *[stub]*

(To be defined during PS route spec design. Will cover the acceptable-vs-substantive thresholds for inline `<script>` blocks.)

---

## 9. Comments  *[stub]*

(To be defined during PS route spec design.)

---

## 10. Required patterns summary  *[stub]*

(To be defined during PS route spec design.)

---

## 11. Forbidden patterns  *[stub]*

(To be defined during PS route spec design.)

---

## 12. Illustrative example  *[stub]*

(To be defined during PS route spec design.)

---

## 13. Catalog model essentials  *[stub]*

(To be defined during PS route spec design.)

---

## 14. What the parser extracts  *[stub]*

(To be defined during PS route spec design.)

---

## 15. Drift codes reference  *[stub]*

(To be defined during PS route spec design. PS-route-specific drift codes only.)

---

## 16. Compliance queries  *[stub]*

(To be defined during PS route spec design. PS-route queries scoped to `WHERE file_type = 'PS'` plus filename pattern matching for routes.)

---

## Revision history

| Version | Date | Description |
|---|---|---|
| 0.1 | 2026-05-04 | Initial scaffold. Pre-design observations harvested from the retired `CC_FileFormat_Spec.md` Part 4 (route portions) plus universal Section 1.1 / 1.2 PS portions, awaiting review during PS route spec design session. |

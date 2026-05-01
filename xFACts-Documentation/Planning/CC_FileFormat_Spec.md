# Control Center File Format Specification

**Created:** April 30, 2026
**Status:** v0.2 - Q4 and Q5 resolved. Ready to drive parser implementation.
**Owner:** Dirk
**Target File:** `xFACts-Documentation/Planning/CC_FileFormat_Spec.md`

---

## Purpose

This specification defines the structural conventions every Control Center source file must follow. The conventions exist for one reason: **machine readability**. Each rule in this document is justified by a specific extraction the `Extract-CCComponents.ps1` parser performs against the file.

The spec is intentionally opinionated and rigid. Files that follow the spec parse cleanly into the `PageComponent_Registry` table without ambiguity or fallback logic. Files that don't follow the spec fail the parser with a specific compliance error pointing at the violation.

This is the contract. Format work during the CC Chrome Standardization initiative consists of bringing each file into compliance with this spec.

---

## Part 1 - Universal File Conventions

These conventions apply to every CC source file regardless of language.

### 1.1 File Header Block

Every file begins with a header block. The block format varies slightly per language (CSS uses `/* */`, JS uses `//`, PS1 uses `#`) but the **content** is identical.

**Required content, in this order:**

1. File identity line: `xFACts Control Center - <Component Description>`
2. Location line: `Location: E:\xFACts-ControlCenter\<full-path>`
3. Version line: `Version: Tracked in dbo.System_Metadata (component: <Component>)`
4. Blank line
5. Free-form purpose paragraph (1-3 sentences explaining what the file is)
6. Blank line
7. `FILE ORGANIZATION` heading (CSS only — sections are too few to enumerate in JS/PS1 headers)
8. Numbered list of section titles matching the actual section banners in the file
9. Blank line
10. `CHANGELOG` heading
11. Reverse-chronological dated entries

**Parser uses:**
- Component name extraction from `Version:` line
- Cross-validation between `FILE ORGANIZATION` list (CSS) and actual section banners

**CSS template:**

```css
/* ============================================================================
   xFACts Control Center - <Component Description> (<filename>)
   Location: E:\xFACts-ControlCenter\public\css\<filename>
   Version: Tracked in dbo.System_Metadata (component: <Component>)

   <Purpose paragraph>

   FILE ORGANIZATION
   -----------------
   1. <Section Title>
   2. <Section Title>
   3. <Section Title>

   CHANGELOG
   ---------
   YYYY-MM-DD  <Description>
   ============================================================================ */
```

**JS template:**

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

**PS1 template:**

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

### 1.2 Section Banners

Every section in the file is introduced by a section banner. A section is a logical grouping of related code (e.g., "Foundation", "Connection Banner", "RBAC Functions"). Sections are mandatory — every line of code below the file header must belong to exactly one section.

**Required banner format:**

The banner is exactly four lines:
1. Top rule (78 `=` characters)
2. Section number and title in caps (e.g., `1. FOUNDATION`)
3. Bottom rule (78 `-` characters) followed by free-form section description (any number of lines)
4. Closing top rule (78 `=` characters)

**Section numbering:**
- Numbers start at 1 and increment without gaps
- Numbers reset per file
- Sub-sections (e.g., "1.1") are NOT used in banners; they live in the description paragraph if needed

**CSS section banner template:**

```css
/* ============================================================================
   N. <SECTION TITLE IN CAPS>
   ----------------------------------------------------------------------------
   <Free-form description, one or more lines, explaining the section's
   purpose and any cross-references.>
   ============================================================================ */
```

**JS section banner template:**

```javascript
// ============================================================================
// N. <SECTION TITLE IN CAPS>
// ----------------------------------------------------------------------------
// <Free-form description, one or more lines, explaining the section's
// purpose and any cross-references.>
// ============================================================================
```

**PS1 section banner template:**

```powershell
# ============================================================================
# N. <SECTION TITLE IN CAPS>
# ----------------------------------------------------------------------------
# <Free-form description, one or more lines, explaining the section's
# purpose and any cross-references.>
# ============================================================================
```

**Parser uses:** Every component extracted from the file is tagged with the section number and title it appears under (`source_section` column in the registry).

**Compliance violations the parser flags:**
- Section number gaps (e.g., 1, 2, 4 with no 3)
- Section banners not matching the template format exactly
- Code outside any section (between file header and first banner, or between sections)
- Sub-section banners (no numbered sub-sections allowed)

### 1.3 Sub-Section Markers

Sub-sections within a section are marked with a single-line comment, NOT a banner. This is the only intra-section structural marker the parser recognizes.

**CSS sub-section marker:**
```css
/* -- <Sub-section description> -- */
```

**JS sub-section marker:**
```javascript
// -- <Sub-section description> --
```

**PS1 sub-section marker:**
```powershell
# -- <Sub-section description> --
```

**Parser uses:** Sub-section markers are NOT extracted into the registry. They exist for human readability only. The parser ignores them.

**Why we still mandate format:** consistency. If sub-section markers are written in random comment styles, the parser has to distinguish them from incidental comments. The dash-flanked format is unambiguous.

---

## Part 2 - CSS File Spec

### 2.1 Required structure

Every CSS file follows this top-to-bottom structure:

```
File header block (Section 1.1)
[blank line]
Section banner: 1. <First section>
[CSS rules and sub-section markers]
[blank line]
Section banner: 2. <Second section>
[CSS rules and sub-section markers]
...
Section banner: N. <Last section>
[CSS rules]
[end of file]
```

### 2.2 What the parser extracts from CSS files

For each CSS file, the parser extracts:

- **CSS_CLASS** — every class selector defined in the file
- **CSS_KEYFRAME** — every `@keyframes` definition

For each extracted component:

- `component_name` — the class name without the leading `.` or the keyframe name
- `signature` — the full selector text (for classes) or the keyframe name with `@keyframes` prefix
- `source_file` — the file being parsed
- `source_section` — the section banner the rule appears under
- `default_value` and `variants` — see Section 2.5 for the width tier convention

### 2.3 CSS class selectors

**Mandatory rules:**

- Every class selector must be defined under exactly one section
- Class definitions must use single-quote-free selectors (no `[class~='foo']` style — use class selectors directly)
- Compound selectors (`.foo.bar`) emit a row for each class with the full compound as `signature`
- Pseudo-classes and state modifiers (`.foo:hover`, `.foo.active`) emit a row tagged as a state variant of the parent class — see Section 2.4

### 2.4 State variants and pseudo-classes

State variants like `.foo.active`, `.foo:hover`, `.foo.disabled` are NOT extracted as separate `CSS_CLASS` rows. They're treated as variants of the parent class.

**Parser behavior:**

- `.engine-bar.idle` is a variant of `.engine-bar`
- `.engine-bar:hover` is a variant of `.engine-bar`
- `.connection-banner.reconnecting` is a variant of `.connection-banner`

**Storage:** The `variants` column on the parent class row gets a JSON-shaped string listing variant names. Example for `.engine-bar`:

```
variants: ["idle", "running", "overdue", "critical", "disabled"]
```

**Why:** Variants are part of the same component conceptually. Cataloging each as its own row would inflate the registry without query benefit.

### 2.5 Width tier convention

Some shared CSS classes have explicit width tiers (`.slide-panel` default 550px, `.wide` 800px, `.xwide` 950px). These are special:

- `default_value` = the base width (e.g., `550px`)
- `variants` = JSON object mapping variant name to value (e.g., `{"wide": "800px", "xwide": "950px"}`)

**Detection:** The parser detects a width tier when:
- The base class definition contains `width: <value>px`
- A variant rule with the same base name contains a different `width: <value>px`
- Both are in the same section

This is a strict pattern. If a file uses width tiers without following the pattern, the parser does not auto-detect them — they must be explicitly tagged with a comment marker.

**Explicit width tier marker (when auto-detection isn't enough):**

```css
/* @width-tier base */
.foo { width: 550px; }

/* @width-tier wide */
.foo.wide { width: 800px; }
```

For now, this marker is reserved for cases where auto-detection fails. We'll know if we need it once the parser runs.

### 2.6 Keyframes

Every `@keyframes` definition is extracted as a separate `CSS_KEYFRAME` row.

- `component_name` — the keyframe name (e.g., `pulse`, `spin`)
- `signature` — `@keyframes <name>`
- All keyframes should be defined in a single section, conventionally the first section ("Foundation")

**Compliance violation:** Keyframes defined outside the Foundation section (or whatever section the file designates as the keyframe home) are flagged.

### 2.7 What is NOT extracted from CSS files

- ID selectors (`#foo`) — IDs are page-defined in route HTML, not CSS
- Element selectors (`body`, `h1`, `a`) — the parser only catalogs class-based components
- Universal selectors (`*`)
- Attribute selectors
- Media queries (the rules inside them ARE extracted; the `@media` block itself is not)
- Comments
- CSS custom properties (CSS variables) — none are currently used; if added later, this spec will be extended

---

## Part 3 - JavaScript File Spec

### 3.1 Required structure

Every JS file follows this top-to-bottom structure:

```
File header block (Section 1.1)
[blank line]
Section banner: 1. <First section> (typically constants)
[declarations]
[blank line]
Section banner: 2. STATE
[state variable declarations]
[blank line]
Section banner: 3. <First functional section>
[function declarations]
...
Section banner: N. <Last section>
[function declarations]
[end of file]
```

### 3.2 Mandatory section structure for JS files

JS files have **mandatory section names** for specific kinds of content. The parser uses these section names to classify components correctly.

| Section name | Contents | Required? |
|---|---|---|
| `<N>. SHARED CONSTANTS` | Top-level `var`/`let`/`const` constants intended for cross-file consumption | Required if the file exports any constants |
| `<N>. PAGE CONSTANTS` | Top-level constants used only within this file | Optional |
| `<N>. STATE` | Top-level mutable variables (state holders) | Required if the file declares any state |
| `<N>. PAGE HOOKS` | The `onPageRefresh`, `onPageResumed`, `onSessionExpired` etc. hook functions | Required if the file defines any page hooks |
| Other named sections | Functions grouped by purpose | As many as needed |

**The section name "STATE" is mandated**, not free-form. A file that calls its state section "VARIABLES" or "MODULE STATE" fails compliance.

**The section name "SHARED CONSTANTS" is mandated when constants are exposed for external use.** Internal-only constants go in "PAGE CONSTANTS" (also mandated name).

This rigidity is what lets the parser distinguish a top-level `var` that's a cataloged constant from a top-level `var` that's mutable state, without inspecting whether the variable gets reassigned later.

**Mandatory section ordering:**

When these sections are present in a JS file, they must appear in this order:

1. `SHARED CONSTANTS` (if present)
2. `PAGE CONSTANTS` (if present)
3. `STATE` (if present)
4. Any number of functional sections, in whatever order makes sense for the file
5. `PAGE HOOKS` (always last among the mandated sections, if present)

**Compliance violations:**
- `STATE` appearing before `SHARED CONSTANTS` or `PAGE CONSTANTS`
- `PAGE HOOKS` appearing before any non-mandated section (it must be the last mandated section)
- A mandated section (e.g., `STATE`) using a non-mandated name (e.g., `VARIABLES`)

### 3.3 What the parser extracts from JS files

For each JS file, the parser extracts:

- **JS_CONSTANT** — top-level `var`/`let`/`const` declarations under a `SHARED CONSTANTS` or `PAGE CONSTANTS` section
- **JS_STATE** — top-level `var`/`let`/`const` declarations under a `STATE` section
- **JS_FUNCTION** — top-level function declarations not under a `PAGE HOOKS` section
- **JS_HOOK** — top-level function declarations under a `PAGE HOOKS` section

For each extracted component:

- `component_name` — the variable or function name
- `signature` — for functions: `(arg1, arg2, ...)`. For constants/state: the literal value if short, or `<type>` (e.g., `array`, `object`, `null`) if not
- `source_section` — the section banner the declaration appears under
- `purpose_description` — extracted from the JSDoc comment block above the declaration if present (see 3.4)

### 3.4 Function documentation

Every top-level function declaration **must** have a documentation comment immediately preceding it. The parser supports two formats:

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

**Parser uses:** The first non-`@`-tagged line of the docstring becomes `purpose_description`.

**Compliance violations:**
- Function declared with no preceding comment
- Function declared with a comment that's not directly above it (blank line in between)

### 3.5 Constant and state documentation

Top-level constants and state variables **must** be preceded by a single-line comment describing their purpose:

```javascript
// 1-indexed array; MONTH_NAMES[12] returns 'December'
var MONTH_NAMES = ['', 'January', ...];

// Per-slug state: { lastEvent, countdown, lastRefresh }
var engineState = {};
```

The comment becomes `purpose_description` in the registry.

**Compliance violation:** Top-level declarations under SHARED CONSTANTS, PAGE CONSTANTS, or STATE without a preceding single-line comment.

### 3.6 What is NOT extracted from JS files

- Inner functions (anything declared inside another function)
- IIFE-wrapped code
- Anonymous functions assigned to variables (these get extracted as the variable's value, not as functions in their own right)
- Object methods (extracted as part of the parent object's value, not standalone)
- Private utility functions inside `function` scope
- Comments (used for `purpose_description` extraction, not cataloged separately)

### 3.7 Module-level guards

The `if (typeof pageRefresh !== 'function') { window.pageRefresh = ... }` pattern in `engine-events.js` is a known case where a function is conditionally assigned to `window`. The parser treats this as a JS_FUNCTION named `pageRefresh` defined in the section the guard appears in, with a `notes` field flagging it as a conditional definition.

When the guard is removed (per the chrome plan's backlog item), this special case can be removed from the parser too.

---

## Part 4 - PowerShell File Spec

### 4.1 Two kinds of PS1 files

CC PowerShell files come in two flavors. The spec applies to both but with different extraction rules.

**Type 1 — Route files** (page route + API route files, e.g., `BIDATAMonitoring.ps1`, `BIDATAMonitoring-API.ps1`)
- Define HTML routes (page rendering) or API endpoints
- Use `Add-PodeRoute` for route registration
- Parser extracts API_ROUTE rows and (for page route files) HTML_ID rows from inline HTML

**Type 2 — Module files** (helpers, e.g., `xFACts-Helpers.psm1`)
- Define PowerShell functions
- Use `Export-ModuleMember` at the bottom
- Parser extracts PS_FUNCTION rows

### 4.2 Required structure (both types)

```
File header block (Section 1.1)
[blank line]
Section banner: 1. <First section>
[content]
...
Section banner: N. <Last section>
[content]
[end of file]
```

For module files, the final section is conventionally `EXPORT` and contains the `Export-ModuleMember` call.

### 4.3 Function documentation (Module files)

Every top-level function declaration **must** have a comment-based help block:

```powershell
function Function-Name {
    <#
    .SYNOPSIS
        <One-line summary, mandatory>
    .DESCRIPTION
        <Optional longer description>
    .PARAMETER <name>
        <description>
    .RETURNS
        <description>
    .EXAMPLE
        <example usage>
    #>
    param( ... )
    ...
}
```

**Parser uses:**
- `.SYNOPSIS` content becomes `purpose_description`
- `param()` block becomes `signature`

**Compliance violations:**
- Function with no comment-based help block
- Comment-based help block missing `.SYNOPSIS`

### 4.4 What the parser extracts from Route files

For files containing `Add-PodeRoute` calls:

- **API_ROUTE** — every `Add-PodeRoute` invocation
  - `component_name` — the path (e.g., `/api/bidata/todays-build`)
  - `signature` — `<METHOD> <path>`
  - `source_section` — section banner
  - `purpose_description` — comment block immediately preceding the `Add-PodeRoute` call (see 4.6)

For page route files (the non-API variant), additionally:

- **HTML_ID** — every `id="..."` attribute appearing in inline HTML strings
  - `component_name` — the ID value
  - `source_section` — section banner

**Compliance violations:**
- `Add-PodeRoute` call with no preceding comment block

### 4.5 What the parser extracts from Module files

- **PS_FUNCTION** — every `function Verb-Noun { ... }` declaration
  - `component_name` — the function name
  - `signature` — extracted from `param()` block: `(Param1, Param2, ...)`
  - `purpose_description` — from `.SYNOPSIS`
  - `source_section` — section banner

The parser also reads the `Export-ModuleMember -Function @( ... )` list and validates that every exported function exists in the file. Functions in the file but not in the export list are extracted with a flag indicating they're internal.

### 4.6 Route documentation

Every `Add-PodeRoute` call must be preceded by a comment block describing the endpoint:

```powershell
# -- /api/bidata/todays-build --
# Returns today's BIDATA build status, step counts, and average durations.
# Used by loadLiveActivity in bidata-monitoring.js.
Add-PodeRoute -Method Get -Path '/api/bidata/todays-build' -Authentication 'ADLogin' -ScriptBlock {
    ...
}
```

The first line is the sub-section marker per Section 1.3 (route path). The lines after are the description (parser uses up to the blank line or `Add-PodeRoute` line).

### 4.7 Internal functions and script-scope variables

Module files may contain:

- `$script:VariableName = ...` declarations (script-scope variables)
- `function Internal-Helper { ... }` declarations not exported

These are extracted but flagged as internal:

- `$script:` variables become PS_STATE rows with `scope = LOCAL` (file-internal)
- Non-exported functions become PS_FUNCTION rows with a `notes` flag indicating internal-only

**Compliance violations:**
- `$script:` variables outside any section
- Internal functions still subject to comment-based help requirement

### 4.8 Inline JavaScript in Route files

Route files (page route .ps1, not API .ps1) may contain `<script>` blocks within their inline HTML strings. The convention is that **page logic lives in the separate .js file**, not inline. Inline `<script>` blocks are tolerated for narrow purposes only.

**Acceptable inline JS:**

- A single small `<script>` block immediately before the `engine-events.js` script tag, defining the `ENGINE_PROCESSES` map and any other configuration the shared module needs at load time. Example:

```html
<script>
    var ENGINE_PROCESSES = {
        'Monitor-BIDATABuild': { slug: 'bidata' }
    };
</script>
<script src="/js/engine-events.js"></script>
```

- Inline event handler attributes (`onclick="someFunction()"`, `onchange="..."`, etc.) referencing functions defined in the page's .js file. These are normal HTML usage, not "inline JS" in the spec sense.

**Substantive inline JS — flagged as WARNING:**

- A `<script>` block of more than 5 lines (excluding blank lines and comments)
- Function definitions inside `<script>` blocks (any number of lines)
- Logic beyond simple variable initialization

**Parser behavior:**

- Inline `<script>` blocks are detected by the parser
- Each block is line-counted (excluding blank lines and comments)
- Blocks failing the "acceptable" criteria emit a WARNING-level violation
- The parser does NOT extract components from inline JS — substantive inline JS must be moved to the .js file before its contents can be cataloged

**Compliance violation message:**

```
Line N: Substantive inline <script> block (X lines). Move to <pagename>.js per CC convention.
```

This becomes a chrome-work item for the affected page.

---

## Part 5 - HTML ID Conventions (Route files only)

HTML IDs appear inside the inline HTML strings in page route files (`BIDATAMonitoring.ps1`, etc.). The parser extracts them.

### 5.1 Mandated ID conventions

Specific IDs are mandated by the chrome contract and must appear on every page:

| ID | Purpose | Required? |
|---|---|---|
| `connection-banner` | Connection state banner placeholder | Required on every page |
| `last-update` | Last-updated timestamp display | Required on every page |
| `engine-row` | Engine cards container | Required if the page has engine cards |
| `card-engine-<slug>` or `card-engine` | Per-process engine card | Required per engine card |
| `engine-bar-<slug>` or `engine-bar` | Per-process engine status bar | Required per engine card |
| `engine-cd-<slug>` or `engine-cd` | Per-process countdown text | Required per engine card |

### 5.2 Page-specific IDs

Pages may define their own IDs for slideouts, modals, content containers, etc. These follow recommended naming patterns:

- Slideout overlays: `<purpose>-slideout-overlay`
- Slideout panels: `<purpose>-slide-panel`
- Modal overlays: `<purpose>-modal-overlay`
- Modals: `<purpose>-modal`
- Form fields: `<form>-<field>` (e.g., `date-range-start`)

The parser extracts every `id="..."` it finds and emits an HTML_ID row. Pages can use any IDs they need; the spec recommends but does not strictly mandate naming conventions for page-specific IDs.

### 5.3 What is NOT mandated

- Class attributes inside route HTML — those reference CSS_CLASS components already cataloged from the CSS file
- Element types (`<div>`, `<button>`, etc.)
- Inline styles
- Event handler attributes (`onclick=...`)

---

## Part 6 - Compliance Reporting

The parser produces two outputs per run:

1. **Component CSV** — one row per extracted component, the inventory data for the registry
2. **Compliance report** — a separate markdown file listing every spec violation found

### 6.1 Compliance report structure

```markdown
# CC File Format Compliance Report
Generated: <timestamp>
Files scanned: <N>

## File: <filename>
Status: PASS | FAIL (<N> violations)

### Violations
- Line 42: Section banner missing closing rule
- Line 87: Function declared without preceding documentation
- Line 110: Top-level variable in STATE section without preceding comment

## File: <filename>
Status: PASS

...

## Summary
- Files passing: <N>
- Files failing: <N>
- Total violations: <N>
- Most common violation: <description> (<count> occurrences)
```

### 6.2 Severity levels

The parser supports three severity levels for violations:

- **ERROR** — the parser cannot extract components from the affected region. Emit no rows for that region. File status is FAIL.
- **WARNING** — the parser can extract components but the format violates the spec. File status is FAIL but rows are still emitted.
- **INFO** — minor format inconsistency (e.g., extra blank lines). File status is PASS but the issue is reported.

### 6.3 Stop-on-first-error mode

The parser supports a `-StrictMode` flag that aborts on the first ERROR-level violation. Default is permissive (extract what's extractable, report all violations).

---

## Part 7 - Spec Evolution

### 7.1 When the spec changes

The spec may need updates as we encounter file structures it doesn't cover. Updates follow this process:

1. Identify the gap (a file structure the spec doesn't address, or a parser ambiguity)
2. Discuss the proposed addition (during a session or via this document)
3. Update the spec
4. Update the parser
5. Run the parser against all currently-compliant files to verify no regressions
6. Update file headers and CHANGELOGs of any files affected by the change

### 7.2 Versioning

The spec carries a version number in its header. Major version bumps indicate breaking changes that require existing files to be updated. Minor version bumps indicate additions that don't break existing compliant files.

### 7.3 Backward compatibility during migration

While the chrome standardization initiative is in progress, files exist in three states:

- **Pre-chrome** — file has not yet been touched by chrome work; spec compliance not expected
- **Chrome-aligned** — file has been brought into chrome compliance but format spec compliance is still pending
- **Format-compliant** — file follows this spec end-to-end

The parser supports running against any of these states. Pre-chrome and chrome-aligned files will produce a high count of compliance violations; that's expected. The compliance report becomes the to-do list for that file's format pass.

---

## Part 8 - Open Questions

Items deferred to discussion before parser implementation begins.

**Q1: How does the parser handle the existing `engine-events.css` and `engine-events.js`?**

These files are the "canonical" reference but were authored before this spec existed. They will likely need touch-ups to fully comply. The plan: run the parser against them first and use the compliance report to drive a small reformatting pass before any other work.

**Q2: Does the spec apply to the `xFACts-Helpers.psm1` file in this initiative or later?**

Decision: later. Helpers module reformat is a separate post-chrome effort.

**Q3: Module-level guards (the `pageRefresh` example) — keep the parser special case or refactor the file?**

Decision: keep the parser special case for now. Refactor when the chrome plan's backlog item to remove the guard is addressed.

**Q4: Should the spec mandate file ordering (e.g., constants before state before functions)?**

Decision: JS file ordering is mandated (see Section 3.2 update); CSS file ordering remains content-driven. See Section 3.2 for the mandated JS order.

**Q5: How should the parser handle inline JS in route .ps1 files?**

Decision: parser flags substantive inline JS as a WARNING. See Section 4.8 for what counts as substantive.

**Q6: Width tier auto-detection — does the heuristic in Section 2.5 actually work, or do we need explicit markers from day one?**

The auto-detection looks for a base class with a `width` property and variants with the same base name and different `width` properties. This should work for `slide-panel`, `xf-modal`, and similar cases. We'll know after the parser runs. If it doesn't, we add the explicit marker syntax.

---

## Revision History

| Version | Date | Description |
|---|---|---|
| 0.1 | 2026-04-30 | Initial draft. Strict/opinionated structure across CSS, JS, and PS1 files. Defines section banner format, mandated section names for JS, comment-based help requirements for PS1, and HTML ID conventions for route files. Compliance reporting structure and severity levels defined. Six open questions deferred for review. |
| 0.2 | 2026-04-30 | Resolved Q4 (JS section ordering mandated, CSS ordering content-driven) and Q5 (inline JS in route files flagged as WARNING when substantive). Added explicit ordering rule to Section 3.2 and new Section 4.8 covering inline JS handling in route files. |

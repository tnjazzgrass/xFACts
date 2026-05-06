# Control Center CSS File Format Specification

*These rules are the current authority for Control Center CSS files. They are settled until explicitly amended; any proposed change is discussed before adoption. Where rationale exists for a rule, it appears in the Appendix at the corresponding section number.*

---

## 1. Required structure

A CSS file consists of three parts in this exact order:

1. **File header** - a single block comment opening at line 1, ending with `*/` followed by exactly one blank line.
2. **Section bodies** - one or more sections, each consisting of a section banner followed by class definitions and optional sub-section markers.
3. **End-of-file** - the file ends after the last `}` of the last section's last rule. No trailing content.

Every line of code in the file lives inside exactly one of these three parts.

---

## 2. File header

The header is a single block comment at the very top of the file. Every field is mandatory and appears in this exact order:

```
xFACts Control Center - <Component Description> (<filename>)
Location: E:\xFACts-ControlCenter\public\css\<filename>
Version: Tracked in dbo.System_Metadata (component: <Component>)

<Purpose paragraph: 1 to 5 sentences describing what this file is.>

FILE ORGANIZATION
-----------------
<Section banner title 1>
<Section banner title 2>
<Section banner title N>
```

### 2.1 Header rules

- The header is the only construct that may appear before the first section banner. Anything else above the first banner is a parse error.
- The closing `*/` is followed by exactly one blank line, then the first section banner.
- The Component Description and Component values come from `dbo.System_Metadata` and `dbo.Component_Registry`.
- No CHANGELOG block. Drift code: `FORBIDDEN_CHANGELOG_BLOCK`.
- The FILE ORGANIZATION list must match the section banner titles in the file body, verbatim, in order. Each list entry is exactly the `<TYPE>: <NAME>` of one banner. Drift code: `FILE_ORG_MISMATCH`.
- The list may be unnumbered (current convention) or numbered with `1.`, `2.` prefixes (legacy form, still accepted). Trailing `-- <description>` text on list entries is permitted and is stripped by the parser before comparison.

---

## 3. Section banners

Each section opens with a banner: a multi-line block comment with this format:

```
<TYPE>: <NAME>
----------------------------------------------------------------------------
<Description: 1 to 5 sentences describing what's in this section.>
Prefix: <prefix>
```

(The opening and closing rule lines are sequences of `=` characters of any length five or more, and the inner separator is `-` characters of any length.)

### 3.1 Banner format rules

- The opening and closing `=` rules each consist of `=` characters of any length 5 or more.
- The middle `-` rule separates the title line from the description block.
- `<TYPE>` must be one of the six recognized section types (Section 4). The TYPE token is uppercase letters and underscores only.
- `<NAME>` is human-readable and may contain spaces, commas, and other punctuation.
- The description block is 1-5 sentences explaining what the section contains. Required.
- The `Prefix:` line declares the page prefix that scopes class names in this section (Section 5). Required, singular.

### 3.2 Banner authoring discipline

When adding new content to a file, prefer creating a new banner over expanding an existing one if the new content is a distinct concept. See Section 9 for the full rule on sub-section markers vs. new banners.

---

## 4. Section types

Six section types are recognized, in fixed order:

| Order | TYPE | Purpose | Where it lives |
|-------|------|---------|----------------|
| 1 | `FOUNDATION` | Custom property tokens, CSS resets, scrollbar styling, keyframes, animation utilities | Shared resource files only (`cc-shared.css`). Pages do not have FOUNDATION sections. |
| 2 | `CHROME` | Universal page chrome - nav bar, header bar, refresh info, engine cards, connection banner | Shared resource files only (`cc-shared.css`). Pages do not have CHROME sections. |
| 3 | `LAYOUT` | Page-level structural layout (column grids, page wrappers, multi-column flex containers) | Page files. Each page has at most one LAYOUT section. |
| 4 | `CONTENT` | Page-specific content components - cards, tables, badges, panels, sub-components | Page files. Pages typically have multiple CONTENT sections (one per logical concept). |
| 5 | `OVERRIDES` | Last-resort overrides of shared classes for page-specific contexts | Page files. Use sparingly. |
| 6 | `FEEDBACK_OVERLAYS` | Transient, behavior-driven viewport-overlay elements - idle overlay, toast notifications, loading spinners, confirmation flashes | Either shared (`cc-shared.css`) or page files, depending on whether the overlay is universal or page-specific. |

A file may contain multiple sections of the same type; they are author-ordered by author choice. The order rule is between types, not between sections within a type.

### 4.1 Type-order rule

Section types must appear in the order shown. Drift code: `SECTION_TYPE_ORDER_VIOLATION`.

### 4.2 Multiple-banners-of-same-type rule

A page may contain multiple `CONTENT` banners (e.g., `CONTENT: PIPELINE STATUS`, `CONTENT: STORAGE STATUS`, `CONTENT: BACKUP TYPE BADGES`). They are independent banners with their own descriptions and prefix declarations. This is encouraged - each banner per distinct concept makes the file's organization visible at a glance.

### 4.3 Type uniqueness across files

`FOUNDATION` and `CHROME` sections may exist in only one file across the codebase: `cc-shared.css`. Drift codes: `DUPLICATE_FOUNDATION`, `DUPLICATE_CHROME`.

---

## 5. Prefix

Every section banner declares a single page prefix via the `Prefix:` line. Every base class definition in that section must have a leftmost class name that begins with the declared prefix (followed by a `-`). Drift code: `PREFIX_MISMATCH`.

### 5.1 Special values

- `Prefix: (none)` - sentinel value. Declares the section has no class definitions, so prefix-matching is intentionally disabled. Used by `cc-shared.css`'s sections (which contain platform-wide chrome and tokens, not page-prefixed content) and by FOUNDATION sections containing only reset rules, keyframes, and custom properties (which are not classes). The line itself is still required as a structural marker.
- The `Prefix:` line is mandatory. Drift code if absent: `MISSING_PREFIX_DECLARATION`.

### 5.2 Prefix selection rules

1. **3 characters, fixed.** Prefix length is exactly three characters platform-wide. Not 2, not 4.
2. **Lowercase letters only.** No digits, no underscores, no hyphens. The hyphen separates the prefix from the rest of the class name.
3. **No collisions.** No two pages may share a prefix.
4. **No platform-token collisions.** Prefixes must not start with strings reserved for platform tokens (`color`, `size`, `font`, `duration`, `shadow`, `z`, `gradient`).

### 5.3 Single prefix per banner

Each banner declares exactly one prefix or `(none)`. Multiple comma-separated prefixes are not permitted. A file represents one CC page (or the shared resource), and that page has a single registered prefix; every section in the file uses that same prefix. Drift code if a banner declares anything other than a single 3-character prefix or `(none)`: `MALFORMED_PREFIX_VALUE`.

### 5.4 Registry validation

Each page's prefix is registered in `dbo.Component_Registry.cc_prefix` for the component that owns the page's CSS file. The parser cross-references each banner's declared prefix against the registry and emits drift on disagreement.

- If a file's component has `cc_prefix = NULL` (a shared or infrastructure component, e.g., `ControlCenter.Shared`), every section banner in the file must declare `Prefix: (none)`. A non-`(none)` declaration emits `PREFIX_REGISTRY_MISMATCH` on the banner row.
- If a file's component has `cc_prefix = X` (e.g., `bkp` for `ServerOps.Backup`), every section banner in the file must declare `Prefix: X`. A different value emits `PREFIX_REGISTRY_MISMATCH` on the banner row.
- The registry is the source of truth. When a declared prefix and the registry disagree, the file is wrong and the file is updated.

---

## 6. Class definitions

A class definition is a CSS rule whose selector is a single class (the base form) or a single class plus its variants (Section 7). Each base class definition must:

- Be preceded by a single-line purpose comment immediately above the rule. Drift code: `MISSING_PURPOSE_COMMENT`. The purpose comment becomes the row's `purpose_description` in the catalog.
- Use only properties supported by the spec (see Section 13 for forbidden patterns).
- Reside in a section whose declared prefix matches the class's leftmost name token.

The base class produces a `CSS_CLASS DEFINITION` row in the catalog. See Section 18 for examples.

### 6.1 Pseudo-element rules attached to a class

Pseudo-element rules attached to a class (e.g., `.foo::placeholder`, `.foo::before`, `.foo::after`) are cataloged as `CSS_CLASS DEFINITION` rows by the parser, **not** as variants of `.foo`. The variant model (Section 7) covers pseudo-classes (`:hover`, `:focus`, `:active`) but not pseudo-elements.

A pseudo-element rule needs a preceding purpose comment (like any base class), not the trailing inline comment used for variants.

---

## 7. Variants and modifiers

A variant is a rule whose selector adds qualifiers to a base class. Three variant shapes are recognized:

| variant_type | Shape | Example | qualifier_1 | qualifier_2 |
|--------------|-------|---------|-------------|-------------|
| `class` | `.base-class.modifier` | `.bkp-pipeline-card.status-warning` | `status-warning` | (NULL) |
| `pseudo` | `.base-class:pseudo` | `.bkp-status-card:hover` | (NULL) | `hover` |
| `compound_pseudo` | `.base-class.modifier:pseudo` | `.bkp-status-card.clickable:hover` | `clickable` | `hover` |

### 7.1 Variants are catalog rows of their own

Each variant produces its own `CSS_VARIANT DEFINITION` row in the catalog, with `component_name` set to the base class's name (per the leftmost-class rule). The variant qualifiers are stored in the dedicated `variant_qualifier_1` and `variant_qualifier_2` columns; the `variant_type` column discriminates which shape applies.

### 7.2 Variant authoring rules

- A variant must follow its base class's purpose comment in the file. It does not need its own purpose comment, but every variant must carry a trailing inline comment on the same line as the opening `{`, describing the state or context. Drift code: `MISSING_VARIANT_COMMENT`.
- Variants must adhere to the same prefix rule as their base class.
- The compound depth limit is two class tokens. A selector with three or more class tokens (`.foo.bar.baz`) emits `COMPOUND_DEPTH_3PLUS`.
- Stacked pseudo-classes are forbidden. Drift code: `FORBIDDEN_STACKED_PSEUDO`.
- The `:not(...)` pseudo-class is forbidden in any form. Drift code: `FORBIDDEN_NOT_PSEUDO`.

### 7.3 State-on-element pattern

When an element's appearance depends on a state (warning, critical, active, disabled, etc.), the state class belongs on the element being styled, not inherited via a descendant rule from a parent's state class. Descendant combinators are forbidden; drift code: `FORBIDDEN_DESCENDANT`.

The HTML places the state class on the styled element directly. JavaScript that toggles state operates on the element directly, with no parent-class coordination needed.

When a refactor surfaces a `.foo:not(:disabled)` guard, a `.parent.state .child` descendant, or a `.foo.bar.baz` depth-3 compound, the resolution is almost always state-on-element form. See Section 18 for examples.

---

## 8. Comments

Comments serve four roles, and only four:

1. **Purpose comments** - single-line block comment immediately preceding a base class definition. Format: `/* One-sentence purpose. */`. Required (Section 6).
2. **Trailing variant comments** - inline block comment on the same line as the opening `{` of a variant. Format: `.foo.bar { /* state or context */ ... }`. Required (Section 7).
3. **Section banners** - multi-line block comments enclosing a section's title, description, and prefix declaration. Required (Section 3).
4. **Sub-section markers** - inline block comment between definitions in a section, used as a lightweight visual divider. Format: `/* -- label -- */`. Optional (Section 9).

No other comment forms are recognized. Stray block comments at file scope are a parse error.

### 8.1 Comment content rules

- Purpose and trailing comments are written in present-tense, descriptive style. They describe what the rule does, not why it does it.
- Section banner descriptions may be 1-5 sentences. They explain what the section contains.

---

## 9. Sub-section markers vs. new banners

When a section's content grows, two structural tools are available: sub-section markers (lightweight visual dividers within a single banner) and new banners of the same type.

### 9.1 Use a new banner when

- The new content is a distinct concept with its own purpose
- The new content has its own audience or readership context
- A reader scanning the file's FILE ORGANIZATION list would benefit from seeing the new content as a top-level entry

A new banner gets its own row in the FILE ORGANIZATION list.

### 9.2 Use a sub-section marker when

- The new content is a sub-component of an existing concept
- Grouping is for visual reading aid only, not a structural distinction

Sub-section markers use the inline format `/* -- <label> -- */`. They are decorative; the parser ignores them. They do not appear in the FILE ORGANIZATION list and do not nest.

See Section 18 for a worked example illustrating the new-banner pattern.

---

## 10. Custom property tokens

Custom properties (CSS variables) are the canonical mechanism for sharing values across the codebase. Tokens live in `:root` declarations inside the `FOUNDATION` section of `cc-shared.css`. Pages consume tokens via `var(--token-name)` references.

### 10.1 Token naming convention

```
--<category>-<role>-<modifier>
```

| Component | Purpose | Examples |
|-----------|---------|----------|
| `category` | Token type. Fixed enum: `color`, `size`, `font`, `duration`, `shadow`, `z`, `gradient`. | `color`, `size`, `font` |
| `role` | Functional purpose, role-based not appearance-based. | `bg-card`, `accent-platform`, `text-muted` |
| `modifier` | Optional. Distinguishes variants of the same role. | `hover`, `default`, `lg`, `sm` |

The category enum is closed. Adding a new category requires a spec amendment.

### 10.2 Token usage rules

- Values used in 2+ places across the codebase are tokens. Values used only once may stay as literals; the catalog will surface promotion candidates when a literal repeats.
- Pages reference tokens via `var(...)` only. Direct hex literals where a token exists emit `DRIFT_HEX_LITERAL`.
- Direct pixel literals where a size token exists emit `DRIFT_PX_LITERAL`.
- Tokens are defined once in `cc-shared.css`'s FOUNDATION section. Page files do not redeclare tokens or override them locally.
- Adding a new token requires a small update to `cc-shared.css` and a `Component_Registry` version bump on `ControlCenter.Shared`.

---

## 11. @keyframes

`@keyframes` definitions are permitted only in the FOUNDATION section of `cc-shared.css`. Pages may consume keyframes via `animation: <keyframe-name> ...` references, but may not define new keyframes locally. Drift code: `FORBIDDEN_KEYFRAMES_LOCATION`.

Each `@keyframes` block produces a catalog row of type `CSS_KEYFRAMES DEFINITION` with the keyframe name as `component_name`.

---

## 12. Required patterns summary

Every CSS file must:

1. Open with a spec-compliant file header (Section 2).
2. Define all sections under recognized section types in declared order (Sections 3, 4).
3. Declare a valid prefix in every section banner (Section 5).
4. Precede every base class with a purpose comment (Section 6).
5. Add a trailing inline comment on every variant (Section 7).
6. Use the state-on-element pattern for stateful UI (Section 7.3).
7. Use a new banner per distinct concept; sub-section markers only for sub-components (Section 9).
8. Reference shared values via `var(--token-name)` only (Section 10).
9. Match the FILE ORGANIZATION list to banner titles verbatim, in order (Section 2).
10. Place all `@keyframes` definitions in `cc-shared.css`'s FOUNDATION section (Section 11).

---

## 13. Forbidden patterns

| Pattern | Drift code |
|---------|------------|
| Element selector outside FOUNDATION (e.g., `body`, `h1`, `a`) | `FORBIDDEN_ELEMENT_SELECTOR` |
| Universal selector outside FOUNDATION (`*`) | `FORBIDDEN_UNIVERSAL_SELECTOR` |
| Attribute selector outside FOUNDATION (`[type="text"]`) | `FORBIDDEN_ATTRIBUTE_SELECTOR` |
| Pseudo-element outside FOUNDATION not attached to a class | `FORBIDDEN_PSEUDO_ELEMENT_LOCATION` |
| Descendant combinator (whitespace-separated selectors) | `FORBIDDEN_DESCENDANT` |
| Child combinator (`>`) | `FORBIDDEN_CHILD_COMBINATOR` |
| Adjacent sibling combinator (`+`) | `FORBIDDEN_ADJACENT_SIBLING` |
| General sibling combinator (`~`) | `FORBIDDEN_GENERAL_SIBLING` |
| Compound depth >= 3 (`.foo.bar.baz`) | `COMPOUND_DEPTH_3PLUS` |
| Stacked pseudo-classes (`:hover:focus`) | `FORBIDDEN_STACKED_PSEUDO` |
| `:not(...)` in any form | `FORBIDDEN_NOT_PSEUDO` |
| Selector group (comma-separated) | `FORBIDDEN_GROUP_SELECTOR` |
| ID selector (`#foo`) | `FORBIDDEN_ID_SELECTOR` |
| Pseudo-class interleaved between class tokens (`.a:hover.b`) | `PSEUDO_INTERLEAVED` |
| `@import` | `FORBIDDEN_AT_IMPORT` |
| `@font-face` | `FORBIDDEN_AT_FONT_FACE` |
| `@supports` | `FORBIDDEN_AT_SUPPORTS` |
| `@keyframes` outside FOUNDATION | `FORBIDDEN_KEYFRAMES_LOCATION` |
| Custom property defined outside FOUNDATION | `FORBIDDEN_CUSTOM_PROPERTY_LOCATION` |
| Hex literal where token exists | `DRIFT_HEX_LITERAL` |
| Pixel literal where token exists | `DRIFT_PX_LITERAL` |
| CHANGELOG block in file header | `FORBIDDEN_CHANGELOG_BLOCK` |
| Two or more declarations on the same line | `FORBIDDEN_COMPOUND_DECLARATION` |
| Blank line inside a class definition | `BLANK_LINE_INSIDE_RULE` |
| More than one blank line between top-level constructs | `EXCESS_BLANK_LINES` |
| Comment style not matching the four allowed kinds | `FORBIDDEN_COMMENT_STYLE` |
| Banner declares anything other than a single 3-char prefix or `(none)` | `MALFORMED_PREFIX_VALUE` |
| Banner's declared prefix disagrees with `Component_Registry.cc_prefix` | `PREFIX_REGISTRY_MISMATCH` |

`@media` is permitted in any section. Wrapped rules are subject to all other spec rules. The wrapping `@media` expression is captured in the catalog's `parent_function` column.

The complete drift code reference with descriptions appears in Section 16.

---

## 14. Catalog model

This section covers the catalog mechanism as it relates to CSS files. Every cataloged CSS construct gets one row in `dbo.Asset_Registry`.

### 14.1 What the catalog represents

A row's identity is described by the combination of `component_type`, `component_name`, `reference_type`, `file_name`, and `occurrence_index`. The parser populates one row per definition or usage instance found while walking source files.

The catalog is the answer to questions like: "where is `.bkp-pipeline-card` defined?", "how many pages have a hover variant of their primary card class?", "which CSS files contain spec drift today, and of what kinds?". Every such question becomes a SQL query against this table.

### 14.2 CSS-relevant component_type values

| component_type | Meaning |
|---|---|
| `FILE_HEADER` | The file's header block. One row per scanned file. Carries header-level drift codes and serves as the "this file was scanned" anchor regardless of what else the file contains. |
| `CSS_CLASS` | A class definition (`.foo { ... }`). Pseudo-element rules attached to a class (e.g., `.foo::placeholder`) are also cataloged as `CSS_CLASS` rows, not as variants. |
| `CSS_VARIANT` | A class variant definition - a row whose selector compounds the parent class with additional class or pseudo-class qualifiers. The `component_name` is the parent's class name; qualifiers live in `variant_qualifier_1` / `variant_qualifier_2`. Pseudo-classes only - pseudo-elements are CSS_CLASS rows. |
| `CSS_KEYFRAMES` | An `@keyframes` definition or a reference. |
| `CSS_VARIABLE` | A custom property definition (`--name: value`) or a `var(--name)` reference. |
| `CSS_RULE` | A rule with no class, no id, and no keyframe - e.g., `body { ... }`, `* { ... }`, `[type="radio"] { ... }`. These are forbidden by the spec but cataloged for visibility into drift. |
| `HTML_ID` | An `#id` selector defined in or referenced by a CSS file. Compounds containing both an ID and classes (e.g., `#foo.bar`) emit both an HTML_ID row and a CSS_CLASS/CSS_VARIANT row. |
| `COMMENT_BANNER` | A section banner comment. |

### 14.3 CSS variant_type values

| variant_type | qualifier_1 | qualifier_2 | Example selector |
|---|---|---|---|
| `class` | The compound class | (NULL) | `.btn.disabled` -> qualifier_1 = `disabled` |
| `pseudo` | (NULL) | The pseudo-class name | `.btn:hover` -> qualifier_2 = `hover` |
| `compound_pseudo` | The compound class | The pseudo-class | `.btn.disabled:hover` -> qualifier_1 = `disabled`, qualifier_2 = `hover` |

### 14.4 Drift recording

The parser evaluates every row against the spec and records two things when the row deviates:

- `drift_codes` - comma-separated list of stable short codes
- `drift_text` - joined human-readable descriptions corresponding to each code

A row may carry zero, one, or many drift codes. Both columns are NULL when the row is fully spec-compliant. Empty strings are treated as NULL.

The full code-to-description mapping for CSS appears in Section 16.

---

## 15. What the parser extracts

| Row type | Source | Notes |
|----------|--------|-------|
| `FILE_HEADER DEFINITION` | The opening file header block | One per file. Carries `purpose_description` from the header text. |
| `COMMENT_BANNER DEFINITION` | Each section banner | `signature` = TYPE, `component_name` = NAME, `purpose_description` = description block. |
| `CSS_CLASS DEFINITION` | Each base class declaration | `component_name` = class name, `purpose_description` = the preceding purpose comment. |
| `CSS_VARIANT DEFINITION` | Each variant of a base class | `component_name` = base class name, `signature` = full variant selector, `variant_type` and `qualifier_*` describe the variant shape. |
| `CSS_VARIABLE DEFINITION` | Each `--token: value` declaration in `:root` | One per token. Lives only in `cc-shared.css`'s FOUNDATION. |
| `CSS_VARIABLE USAGE` | Each `var(--token-name)` reference | One per reference. Includes the source rule's selector in `parent_function`. |
| `CSS_KEYFRAMES DEFINITION` | Each `@keyframes name { ... }` block | One per keyframe definition. |
| `CSS_RULE DEFINITION` | Forbidden at-rules emitted to attach drift codes | Used internally for `@import`, `@font-face`, `@supports`. |
| `HTML_ID DEFINITION` | Each `#id` selector in a primary compound | Compounds with both an ID and classes emit both row types. |
| `HTML_ID USAGE` | Each `#id` selector in a descendant compound | (Descendant compounds are forbidden, so these only appear with `FORBIDDEN_DESCENDANT` drift attached.) |

Each row may carry one or more drift codes in `drift_codes` (comma-delimited string) when the rule violates a spec requirement.

---

## 16. Drift codes reference

### 16.1 File-level codes

| Code | Description |
|---|---|
| `MALFORMED_FILE_HEADER` | The file's header block is missing, malformed, or contains required fields out of order. |
| `FORBIDDEN_CHANGELOG_BLOCK` | The file header contains a CHANGELOG block. |
| `FILE_ORG_MISMATCH` | The FILE ORGANIZATION list in the header does not exactly match the section banner titles in the file body, by content or by order. |

### 16.2 Section-level codes

| Code | Description |
|---|---|
| `MISSING_SECTION_BANNER` | A class definition (or other catalogable construct) appears outside any banner. |
| `MALFORMED_SECTION_BANNER` | A section banner exists but does not follow the strict 5-line format with rule lines, title line, separator, description block, and `Prefix:` line. |
| `UNKNOWN_SECTION_TYPE` | A section banner declares a TYPE not in the enumerated list (FOUNDATION, CHROME, LAYOUT, CONTENT, OVERRIDES, FEEDBACK_OVERLAYS). |
| `SECTION_TYPE_ORDER_VIOLATION` | Section types appear out of the required order. |
| `MISSING_PREFIX_DECLARATION` | A section banner is missing the mandatory `Prefix:` line. |
| `MALFORMED_PREFIX_VALUE` | A section banner's `Prefix:` line declares anything other than a single 3-character prefix or `(none)`. |
| `PREFIX_REGISTRY_MISMATCH` | A section banner's declared prefix does not match `Component_Registry.cc_prefix` for the file's component. |
| `DUPLICATE_FOUNDATION` | More than one CSS file in the codebase contains a FOUNDATION section. |
| `DUPLICATE_CHROME` | More than one CSS file in the codebase contains a CHROME section. |

### 16.3 Class-level codes

| Code | Description |
|---|---|
| `PREFIX_MISMATCH` | A class name does not begin with the prefix declared in its containing section's banner. |
| `MISSING_PURPOSE_COMMENT` | A base class definition is not preceded by a single-line purpose comment. Pseudo-element rules attached to a class are cataloged as base CSS_CLASS rows by the parser and therefore require a preceding purpose comment, not the trailing inline comment used for variants. |
| `MISSING_VARIANT_COMMENT` | A class variant does not carry a trailing inline comment after the opening brace. |

### 16.4 Selector-level codes

| Code | Description |
|---|---|
| `FORBIDDEN_ELEMENT_SELECTOR` | A rule's selector is an element selector (e.g., `body`, `h1`, `a`) and the rule is outside a FOUNDATION section. Suppressed by the parser when the active section is FOUNDATION-typed. |
| `FORBIDDEN_UNIVERSAL_SELECTOR` | A rule uses the universal selector `*` and the rule is outside a FOUNDATION section. Suppressed in FOUNDATION. |
| `FORBIDDEN_ATTRIBUTE_SELECTOR` | A rule's selector contains an attribute matcher (`[type="radio"]`) and the rule is outside a FOUNDATION section. Suppressed in FOUNDATION. |
| `FORBIDDEN_PSEUDO_ELEMENT_LOCATION` | A pseudo-element selector (e.g., `::before`, `::-webkit-scrollbar`) appears outside FOUNDATION and is not attached to a class. |
| `FORBIDDEN_ID_SELECTOR` | A rule's selector includes an `#id` token (alone or compound). Class-based styling required. |
| `FORBIDDEN_GROUP_SELECTOR` | A rule's selector contains a comma (`,`). Each selector gets its own definition block. |
| `FORBIDDEN_DESCENDANT` | A rule's selector contains a descendant combinator (whitespace between two simple selectors). Restructure as a separate class definition. |
| `FORBIDDEN_CHILD_COMBINATOR` | A rule's selector contains a child combinator (`>`). Restructure as a separate class definition. |
| `FORBIDDEN_ADJACENT_SIBLING` | A rule's selector contains an adjacent sibling combinator (`+`). Restructure as a separate class definition. |
| `FORBIDDEN_GENERAL_SIBLING` | A rule's selector contains a general sibling combinator (`~`). Restructure as a separate class definition. |
| `COMPOUND_DEPTH_3PLUS` | A compound selector contains three or more class tokens (`.a.b.c`). Refactor as a single class plus at most one modifier class. |
| `PSEUDO_INTERLEAVED` | A pseudo-class appears between two class tokens (`.a:hover.b`). Pseudo-classes must come last in any compound. |
| `FORBIDDEN_NOT_PSEUDO` | A selector contains `:not(...)`. Express the negation as an explicit state class instead. |
| `FORBIDDEN_STACKED_PSEUDO` | A compound selector contains two or more pseudo-classes. Reduce to a single pseudo and express the additional condition as a class modifier. |

### 16.5 At-rule codes

| Code | Description |
|---|---|
| `FORBIDDEN_AT_IMPORT` | The file contains an `@import` rule. |
| `FORBIDDEN_AT_FONT_FACE` | The file contains an `@font-face` rule. |
| `FORBIDDEN_AT_SUPPORTS` | The file contains an `@supports` rule. |
| `FORBIDDEN_KEYFRAMES_LOCATION` | An `@keyframes` definition appears in a section other than FOUNDATION (or in a file with no FOUNDATION). |
| `FORBIDDEN_CUSTOM_PROPERTY_LOCATION` | A custom property definition (`--name: value`) appears in a section other than FOUNDATION. |

### 16.6 Value codes

| Code | Description |
|---|---|
| `DRIFT_HEX_LITERAL` | A hex color literal appears in a class declaration's value where a custom property has been defined for that color. |
| `DRIFT_PX_LITERAL` | A pixel literal appears in a class declaration's value where a size token has been defined for that size. |

### 16.7 Comment and structure codes

| Code | Description |
|---|---|
| `FORBIDDEN_COMMENT_STYLE` | A comment exists that is not one of the four allowed kinds. |
| `FORBIDDEN_COMPOUND_DECLARATION` | Two or more declarations appear on the same line. Each declaration must be on its own line. |
| `BLANK_LINE_INSIDE_RULE` | A blank line appears inside a class definition (between the opening `{` and the closing `}`). |
| `EXCESS_BLANK_LINES` | More than one blank line appears between top-level constructs. |

---

## 17. Compliance queries

Standard SQL queries against `dbo.Asset_Registry` for CSS compliance reporting. Each query is scoped to `WHERE file_type = 'CSS'`.

### 17.1 Q1 - Chrome consolidation candidates

Find every class or variant that has a SHARED definition AND one or more LOCAL definitions. Each result is a page reinventing what's already shared chrome.

```sql
SELECT
    local.file_name        AS reinventing_file,
    local.line_start       AS local_line,
    local.component_type   AS kind,
    local.component_name   AS reinvented_class,
    shared.source_file     AS shared_definition_lives_in,
    shared.line_start      AS shared_line
FROM dbo.Asset_Registry local
INNER JOIN dbo.Asset_Registry shared
    ON  local.component_name  = shared.component_name
    AND local.component_type  = shared.component_type
WHERE local.file_type           = 'CSS'
  AND local.reference_type      = 'DEFINITION'
  AND local.scope               = 'LOCAL'
  AND shared.scope              = 'SHARED'
  AND shared.reference_type     = 'DEFINITION'
ORDER BY local.component_name, local.file_name;
```

Q1 produces candidates, not confirmed problems. Each result row is a "this might be reinvention" finding that requires human review. Two unrelated classes can legitimately share a name across files because the name happens to fit two different concepts. For each match, look at the `raw_text` of both rows to compare the actual rule bodies - if equivalent, consolidate; if materially different, rename one of them.

### 17.2 Q2 - Drift summary per file

Counts of total rows and rows-with-drift per file. Use this to prioritize conversion work.

```sql
SELECT
    file_name,
    COUNT(*)                                                     AS total_rows,
    SUM(CASE WHEN drift_codes IS NOT NULL THEN 1 ELSE 0 END)     AS rows_with_drift
FROM dbo.Asset_Registry
WHERE file_type = 'CSS'
GROUP BY file_name
ORDER BY rows_with_drift DESC;
```

### 17.3 Q3 - Drift code distribution

What's the most common kind of drift across the codebase?

```sql
SELECT
    TRIM(value)         AS code,
    COUNT(*)            AS occurrences
FROM dbo.Asset_Registry
CROSS APPLY STRING_SPLIT(drift_codes, ',')
WHERE file_type    = 'CSS'
  AND drift_codes  IS NOT NULL
  AND TRIM(value)  <> ''
GROUP BY TRIM(value)
ORDER BY COUNT(*) DESC;
```

### 17.4 Q4 - Per-file rewrite checklist

For one specific file, what does the work look like, grouped by drift code?

```sql
SELECT
    drift_codes,
    COUNT(*)            AS occurrences,
    MIN(line_start)     AS first_line,
    MAX(line_start)     AS last_line
FROM dbo.Asset_Registry
WHERE file_type    = 'CSS'
  AND file_name    = '<filename.css>'
  AND drift_codes  IS NOT NULL
GROUP BY drift_codes
ORDER BY occurrences DESC;
```

### 17.5 Q5 - Promotion-to-shared candidates

Find class names defined locally in three or more files, where no shared definition exists. Each result is a candidate for promotion to `cc-shared.css`.

```sql
WITH LocalCounts AS (
    SELECT
        component_type,
        component_name,
        COUNT(DISTINCT file_name) AS local_file_count
    FROM dbo.Asset_Registry
    WHERE file_type        = 'CSS'
      AND reference_type   = 'DEFINITION'
      AND scope            = 'LOCAL'
      AND component_type IN ('CSS_CLASS', 'CSS_VARIANT')
    GROUP BY component_type, component_name
),
ExistingShared AS (
    SELECT DISTINCT component_type, component_name
    FROM dbo.Asset_Registry
    WHERE file_type        = 'CSS'
      AND reference_type   = 'DEFINITION'
      AND scope            = 'SHARED'
)
SELECT
    lc.component_type,
    lc.component_name,
    lc.local_file_count,
    STRING_AGG(ar.file_name, ', ') WITHIN GROUP (ORDER BY ar.file_name) AS local_files
FROM LocalCounts lc
LEFT JOIN ExistingShared es
    ON  es.component_type = lc.component_type
    AND es.component_name = lc.component_name
INNER JOIN dbo.Asset_Registry ar
    ON  ar.component_type = lc.component_type
    AND ar.component_name = lc.component_name
    AND ar.scope          = 'LOCAL'
    AND ar.reference_type = 'DEFINITION'
    AND ar.file_type      = 'CSS'
WHERE lc.local_file_count >= 3
  AND es.component_name IS NULL
GROUP BY lc.component_type, lc.component_name, lc.local_file_count
ORDER BY lc.local_file_count DESC, lc.component_name;
```

Like Q1, Q5 surfaces candidates, not verdicts. Same name doesn't always mean same intent - three pages defining `.section-header` might be styling three different concepts. Compare `raw_text` rule bodies before promoting. The `>= 3` threshold is heuristic; adjust based on how aggressive you want to be about promoting things.

---

## 18. Examples

### 18.1 Minimal complete page file

A small page demonstrating every required pattern. Real pages have more sections.

```css
/* ============================================================================
   xFACts Control Center - Example Page Styles (example.css)
   Location: E:\xFACts-ControlCenter\public\css\example.css
   Version: Tracked in dbo.System_Metadata (component: ExampleModule.ExamplePage)

   Page-specific styles for the Example dashboard. Universal chrome (nav
   bar, header bar, refresh info, sections, modals) is provided by
   cc-shared.css. This file contains only the example page's local content
   classes - example cards and example badges.

   FILE ORGANIZATION
   -----------------
   LAYOUT: PAGE GRID
   CONTENT: EXAMPLE CARDS
   CONTENT: EXAMPLE BADGES
   ============================================================================ */


/* ============================================================================
   LAYOUT: PAGE GRID
   ----------------------------------------------------------------------------
   Top-level layout for the example page content area.
   Prefix: ex
   ============================================================================ */

/* The two-column grid container for the example page. */
.ex-page-grid {
    display: grid;
    grid-template-columns: 2fr 1fr;
    gap: var(--size-spacing-2xl);
}


/* ============================================================================
   CONTENT: EXAMPLE CARDS
   ----------------------------------------------------------------------------
   Example status cards. Each card may render in success, warning, or
   critical state via state classes on the card element.
   Prefix: ex
   ============================================================================ */

/* Example status card - base card layout. */
.ex-status-card {
    background: var(--color-bg-card-hover);
    border: var(--size-border-thin) solid var(--color-border-default);
    border-radius: var(--size-radius-lg);
    padding: var(--size-spacing-lg);
}

.ex-status-card.success { /* success state - teal accent */
    border-color: var(--color-accent-shared);
}

.ex-status-card.warning { /* warning state - yellow accent */
    border-color: var(--color-accent-departmental);
}

.ex-status-card.critical { /* critical state - orange accent */
    border-color: var(--color-status-critical);
}

.ex-status-card:hover { /* hover state - subtle background lift */
    background: var(--color-bg-card-deep);
}


/* ============================================================================
   CONTENT: EXAMPLE BADGES
   ----------------------------------------------------------------------------
   Small pill badges used inside the status cards to label entry types.
   Prefix: ex
   ============================================================================ */

/* Example badge pill - base styling. */
.ex-badge {
    display: inline-block;
    font-size: var(--font-size-default);
    font-weight: 600;
    padding: 2px var(--size-spacing-md);
    border-radius: var(--size-radius-sm);
    text-transform: uppercase;
}

.ex-badge.type-info { /* informational badge - blue */
    background: var(--color-bg-tag-info);
    color: var(--color-accent-platform);
}

.ex-badge.type-warning { /* warning badge - yellow */
    background: var(--color-bg-tag-warning);
    color: var(--color-accent-departmental);
}
```

This file produces the following catalog rows when parsed:

- 1 x `FILE_HEADER DEFINITION`
- 3 x `COMMENT_BANNER DEFINITION` (one per section)
- 3 x `CSS_CLASS DEFINITION` (`ex-page-grid`, `ex-status-card`, `ex-badge` are bases)
- Multiple `CSS_VARIANT DEFINITION` rows for each `.foo.bar` and `.foo:hover` (variants of the bases)
- Multiple `CSS_VARIABLE USAGE` rows for every `var(...)` reference

Zero drift rows expected.

### 18.2 Base class with purpose comment

```css
/* The pipeline status card - backup-page-specific. */
.bkp-pipeline-card {
    background: var(--color-bg-card-hover);
    border: var(--size-border-thin) solid var(--color-border-default);
    border-radius: var(--size-radius-lg);
    padding: var(--size-spacing-lg);
}
```

### 18.3 Pseudo-element rule attached to a class

```css
/* Placeholder text styling for the search input (dimmed gray). */
.clr-search-input::placeholder {
    color: var(--color-text-subtle);
}
```

### 18.4 State-on-element pattern

Anti-pattern (forbidden - emits `FORBIDDEN_DESCENDANT`):

```css
.bkp-storage-drive.storage-warning .bkp-drive-label {
    color: var(--color-accent-departmental);
}
```

Correct pattern:

```css
.bkp-drive-label.warning { /* drive is past warning threshold */
    color: var(--color-accent-departmental);
}
```

The HTML places the `.warning` class on the `.bkp-drive-label` element directly. JavaScript that toggles state operates on the element directly, no parent-class coordination needed.

### 18.5 Token naming examples

- `--color-bg-card` - base card background
- `--color-bg-card-hover` - card background on hover
- `--color-accent-platform` - platform-section accent color
- `--size-spacing-md` - medium spacing token
- `--font-size-content` - content text size
- `--duration-default` - default animation duration
- `--z-modal` - modal stacking context z-index
- `--shadow-popup` - drop shadow for popup elements
- `--gradient-progress-default` - canonical progress bar gradient

### 18.6 Two banners of the same type (FEEDBACK_OVERLAYS)

When toast notifications are added later, the right pattern is two banners of the same type rather than jumbling both under a single FEEDBACK_OVERLAYS banner with sub-section markers separating them.

```
/* ============================================================================
   FEEDBACK_OVERLAYS: IDLE OVERLAY
   ...
   Prefix: idle
   ============================================================================ */
.idle-overlay { ... }
.idle-message { ... }

/* ============================================================================
   FEEDBACK_OVERLAYS: TOAST NOTIFICATIONS
   ...
   Prefix: toast
   ============================================================================ */
.toast { ... }
.toast.success { ... }
```

Each banner has its own description and prefix declaration. The FILE ORGANIZATION list gets a new entry. The catalog's prefix-matching enforces that toast classes don't accidentally end up in the idle overlay banner.

---

## Appendix - Rationale

This appendix explains why selected rules are what they are. Entries are keyed to body section numbers. Sections without entries here have no rationale beyond the rule itself.

### A.1 Required structure

The strict three-part structure (header, sections, end-of-file) is what lets the parser walk a file deterministically: the parse position is always either reading the header, reading inside a section, or done.

### A.2 File header

CHANGELOG blocks are forbidden because git is the source of truth for change history. CHANGELOG blocks duplicate what git already provides and create drift between the two records.

The FILE ORGANIZATION list must match the body banners verbatim because verbatim matching makes the list a real table of contents - a reader sees the section titles in the list and can navigate to them by exact-string search.

### A.4 Section types

The fixed type-order rule reflects a real cascade dependency: tokens (FOUNDATION) must be defined before they are consumed; shared chrome classes must be defined before page-specific content can override them; overrides must follow the classes they override.

`FOUNDATION` and `CHROME` are limited to one source file because single-source ownership is what makes them genuinely shared. If multiple files defined `FOUNDATION` content, "the canonical color token" would not have a single home.

### A.5 Prefix

Three-character prefix length is fixed platform-wide because the fixed length keeps class names predictable and makes the prefix visually distinct from the rest of the class name. `.bkp-pipeline-card` reads cleanly; `.bk-pipeline-card` and `.bkpe-pipeline-card` do not.

The single-prefix-per-file rule reflects that a file represents one CC page (or the shared resource), and each page has exactly one registered prefix. Multiple comma-separated values in the `Prefixes:` line was a legacy form that conflated section-grouping commentary with prefix declaration; the singular form removes that ambiguity.

The platform-token collision rule prevents authorial confusion when reading a class like `.color-primary-card` - "color" is a reserved category, and seeing it as a prefix would create ambiguity about whether "color" is a prefix or a category.

The registry validation rule (Section 5.4) makes `Component_Registry.cc_prefix` the source of truth for which prefix belongs to which page. Before the registry existed, the prefix was declared only in the file header and could drift from the platform's understanding silently. Pinning each file's prefix to its component row in the registry surfaces drift as queryable catalog rows.

### A.6 Class definitions

Pseudo-element rules are cataloged as base CSS_CLASS rows rather than variants because pseudo-elements create a new rendering tree node (the placeholder, the ::before box). They style a distinct piece of generated content rather than modifying a state of the base element. The variant model exists for state modifiers, not for styling generated content.

### A.7 Variants and modifiers

The row-per-variant design (rather than aggregating variants as JSON on the parent class row) makes `SELECT * FROM dbo.Asset_Registry WHERE component_name = 'bkp-status-card' AND variant_type IS NOT NULL` a complete answer to "list every variant of this class." Each variant carries its own drift annotations independently. Adding a new variant inserts a new row rather than mutating an existing one.

The trailing-comment-only rule for variants reflects that a variant is a state of an already-explained class. Describing the state is enough; describing the class's full purpose would be redundant.

The compound-depth limit and stacked-pseudo prohibition share a root cause: both express "this state AND that state" patterns that almost always indicate a state should be promoted to the styled element directly. The cap forces this discipline.

The state-on-element pattern produces three measurable benefits: a glance at HTML markup tells you exactly which elements are in which state with no need to mentally trace ancestor classes; the state is queryable through the catalog by exact class name rather than by inferred descendant relationships; and JavaScript that toggles state operates on the element directly with no parent-class coordination. The principle is broader than just compliance with the no-descendants rule - it produces clearer HTML, more inspectable state, and better catalog queryability.

### A.10 Custom property tokens

The fixed-category enum keeps the variable space organized and enables targeted catalog queries ("show me all color tokens", "show me all size tokens"). Role is descriptive of purpose, not appearance - `--color-bg-card`, not `--color-bg-darkgray`. This keeps naming stable when colors change. If the card background were renamed to a literal-color token, every cosmetic refresh of the platform would invalidate the token name.

The 2+ usage threshold for tokenizing values is a deliberate cutoff. A token-for-every-value model is over-engineered; a single-value token represents a permanent commitment to a value that pays no dividend over a literal. The catalog will surface promotion candidates when a literal repeats.

### A.11 @keyframes

The single-source rule for keyframes mirrors the custom-property single-source rule and exists for the same reason: animation primitives are platform-wide, not page-specific. If two pages each defined a `pulse` keyframe, they could drift.

### A.13 Forbidden patterns

The forbidden combinators (descendant, child, adjacent sibling, general sibling) all share the same justification: combinators couple a class's styling to its ancestor's, parent's, or sibling's structure, breaking inspectability and catalog queryability. The state-on-element pattern (Section 7.3) is the canonical resolution for almost every case where a combinator feels necessary.

Element selectors, universal selectors, and attribute selectors are permitted in FOUNDATION because reset rules legitimately rely on them. They are forbidden everywhere else because page-level styling targets classes, not elements - element-targeted rules at the page level couple CSS to HTML element types or attributes that are not class-mediated.

ID selectors are forbidden because IDs in CSS couple styling to specific HTML element instances rather than to a reusable class abstraction. The styling discipline is class-based across the platform.

`:not()` is forbidden because it expresses "everything except" which is structurally fragile and inverts the inspectability principle - a reader has to compute the negation rather than read it directly. The state-on-element pattern produces the same behavior with explicit, readable state classes.

Selector groups (comma-separated) are forbidden because each class gets its own definition block. Groups make catalog row emission ambiguous: does the rule body belong to one class or many? Splitting a group into separate rules removes the ambiguity.

`@import`, `@font-face`, and `@supports` are forbidden because they create capabilities the catalog cannot represent: `@import` creates a hidden dependency graph; `@font-face` is outside the spec's scope; `@supports` introduces conditional CSS that is not currently needed. If any of these become necessary in the future, they will be added as deliberate spec amendments rather than as informal exceptions.

The compound-declaration prohibition (each declaration on its own line) exists for line-numbered diffs and parsing predictability. The blank-lines-inside-rule prohibition reflects that class bodies are contiguous; blank lines inside a body suggest the body should be split into separate definitions.

### A.14 Catalog model

A row's identity is composite (component_type, component_name, reference_type, file_name, occurrence_index) because no single column is sufficient to disambiguate. The same class can be defined in multiple files (LOCAL vs SHARED), and a single file can reference the same identifier multiple times. The composite identity supports queries like "where is this defined" (single row), "where is this used" (multiple rows), and "what's in this file" (rows scoped by file_name).

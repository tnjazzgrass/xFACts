# Control Center CSS File Format Specification

## 1. File structure

A CSS file consists of, in this exact order:

1. A file header (§2).
2. One or more sections (§3, §4).
3. End of file.

Nothing else may appear at file scope.

---

## 2. File header

The header is a single block comment at the top of the file, opening at line 1 and followed by exactly one blank line before the first section banner. Required content, in order:

```
/* ============================================================================
   xFACts Control Center - <Component Description> (<filename>)
   Location: E:\xFACts-ControlCenter\public\css\<filename>
   Version: Tracked in dbo.System_Metadata (component: <Component>)

   <Purpose paragraph: 1 to 5 sentences describing what this file is.>

   FILE ORGANIZATION
   -----------------
   <Section banner title 1>
   <Section banner title 2>
   <Section banner title N>
   ============================================================================ */
```

### 2.1 Rules

- Component Description, filename, path, and Component are sourced from `dbo.Component_Registry` and `dbo.System_Metadata`.
- The header is the only construct permitted before the first banner.
- The FILE ORGANIZATION list contains exactly the `<TYPE>: <NAME>` of each section banner, verbatim, in order. No numbering. No trailing description text.
- No CHANGELOG block. Change history lives in git.

---

## 3. Section banners

Each section opens with a multi-line block comment:

```
/* ============================================================================
   <TYPE>: <NAME>
   ----------------------------------------------------------------------------
   <Description: 1 to 5 sentences describing what's in this section.>
   Prefix: <prefix>
   ============================================================================ */
```

### 3.1 Rules

- The file header (§2) and every section banner use the same comment shape: `/*` followed by a space and exactly 76 `=` characters on line 1; interior lines indented three spaces; closing line of three spaces followed by exactly 76 `=` characters, a space, and `*/`. Section banners additionally include an interior separator line of three spaces and exactly 76 `-` characters between the title line and the description block.
- `<TYPE>` is one of the recognized section types (§4), uppercase letters and underscores only.
- `<NAME>` is human-readable text.
- The description block is required.
- The `Prefix:` line declares exactly one prefix value (§5).
- A new banner is created for each distinct concept rather than expanding an existing banner.

---

## 4. Section types

Five section types are recognized:

| Order | TYPE | Purpose | Where it lives |
|-------|------|---------|----------------|
| 1 | `FOUNDATION` | Custom property tokens, CSS resets, scrollbar styling, keyframes, animation utilities. | Shell file only. |
| 2 | `CHROME` | Universal page chrome — nav bar, header bar, refresh info, engine cards, connection banner. | Shell file only. |
| 3 | `LAYOUT` | Page-level structural layout. | Page files. At most one LAYOUT section per page. |
| 4 | `CONTENT` | Page-specific content components — cards, tables, badges, panels, sub-components. | Page files. Multiple CONTENT sections permitted, one per logical concept. |
| 5 | `FEEDBACK_OVERLAYS` | Transient, behavior-driven viewport-overlay elements — idle overlay, toast notifications, loading spinners, confirmation flashes. | Shell file or page file, scoped by overlay scope. |

### 4.1 Rules

- `FOUNDATION` and `CHROME` sections live in exactly one file per component — the component's shell file. Any other file containing a FOUNDATION or CHROME section is drift.
- Section types appear in the order shown.
- Multiple sections of the same type may appear in any author-chosen order. The type-order rule governs ordering between different types only.
- A page file does not redefine or selectively modify chrome classes. When a page needs a behavior that chrome does not provide, the resolution is either a spec amendment that adds the variation to the chrome layer, or a page-local class under the page's prefix. Choose the chrome path when the variation is broadly reusable; the page-local path when it is specific to one page.

### 4.2 Shell files

| Component | Shell file |
|-----------|-------------|
| `ControlCenter.Shared` (CC application) | `cc-shared.css` |
| `Documentation.Site` (docs application) | `docs-shared.css` |

Adding a platform domain that needs its own shell file requires a spec amendment to the table above.

A file's shell designation is recorded in `Object_Registry` as `scope_tier = SHELL`; the populator reads it from there rather than matching file names.

---

## 5. Prefix

Every section banner declares one prefix via the `Prefix:` line. The prefix scopes class names within the section: every base class definition in the section must begin with the declared prefix followed by `-`.

### 5.1 Prefix forms

Two forms, no others:

- **Page prefix** — the value of `Component_Registry.cc_prefix` for the file's component. Used in LAYOUT, CONTENT, and page-file FEEDBACK_OVERLAYS sections of page files.
- **Chrome prefix** — the literal token `cc`. Used in FOUNDATION, CHROME, and shell-file FEEDBACK_OVERLAYS sections of the shell file.

### 5.2 Rules

- A page-file banner declares the page prefix from `Component_Registry.cc_prefix`.
- A shell-file banner declares `cc`.
- The `Prefix:` line declares exactly one value. Comma-separated values are not permitted.
- `Component_Registry.cc_prefix` is the source of truth. When the file and registry disagree, the file is wrong.

---

## 6. Class definitions

A class definition is a CSS rule whose selector is a single class or a single class plus its variants (§7).

### 6.1 Rules

- Every base class definition is preceded immediately by a single-line purpose comment in the form `/* One-sentence purpose. */`. The comment is required and describes what the class does in present tense.
- The class resides in a section whose declared prefix matches the leftmost token of the class name.
- Pseudo-element rules attached to a class (`.foo::before`, `.foo::after`, `.foo::placeholder`) are base class definitions, not variants. They require a preceding purpose comment.

---

## 7. Variants

A variant is a rule whose selector extends a base class with a pseudo-class state:

| variant_type | Shape           | Example                  |
|--------------|-----------------|--------------------------|
| `pseudo`     | `.base:pseudo`  | `.bkp-status-card:hover` |

Pseudo-class is the only recognized variant shape.

A class-on-class compound (`.foo.bar`) is not a variant. It is a rule that styles elements carrying both classes; each class is a class in its own right, subject to §5 and §6.

### 7.1 Rules

- A variant follows its base class's purpose comment in the file. It does not carry its own purpose comment.
- Every variant has a base class definition in the same file. A pseudo-class variant or a class-on-class compound that references a class without a single-class definition in the same file is drift.
- A base class definition precedes its pseudo-element rules, which precede its pseudo-class variants. A pseudo-element rule appearing before its base, or after a variant on the same class, is drift. A variant appearing before its base class definition is drift.
- A class-on-class compound rule carries no purpose comment and a trailing inline comment describing the state: `.foo.bar { /* state */ ... }`. Each token is defined by a separate single-class rule in the same file; the state token's rule is empty (`{ }`) with its purpose comment, and the compound carries the styling.- Every variant carries a trailing inline comment on the same line as the opening `{`, describing the state: `.foo:hover { /* state */ ... }`.
- Every class token in a compound selector carries its section's declared prefix (§5).
- Compound depth is capped at two class tokens. `.foo.bar.baz` and deeper compounds are forbidden.
- Stacked pseudo-classes (`.foo:hover:focus`) are forbidden.
- `:not(...)` is forbidden in any form.
- A pseudo-class appearing between class tokens (`.a:hover.b`) is forbidden.
- A state or choice condition is expressed as a state token on a base class via a compound. A distinct class baking base and state into one styled rule is drift.

### 7.2 State-on-element pattern

When an element's appearance depends on a state (warning, critical, active, disabled), the state class is applied directly to the element being styled. Descendant relationships between a parent's state class and a child's appearance are forbidden — the state goes on the element that changes, not on an ancestor.

---

## 8. Comments

Four comment forms are recognized:

1. **Purpose comments** — single-line block comment immediately preceding a base class definition: `/* One-sentence purpose. */`. Required (§6).
2. **Trailing variant comments** — inline block comment on the same line as a variant's opening `{`: `.foo.bar { /* state or context */ ... }`. Required (§7).
3. **Section banners** — multi-line block comments enclosing a section's title, description, and prefix declaration (§3).
4. **Sub-section markers** — inline block comment between definitions within a section: `/* -- <label> -- */`. Optional (§9).

### 8.1 Rules

- No other comment forms are recognized. Any block comment at file scope that does not fit one of the four forms above is a parse error.
- Purpose and trailing comments use present-tense descriptive style. They describe what the rule does, not why.

---

## 9. Sub-section markers vs. new banners

When a section's content grows, choose between a new banner or a sub-section marker.

### 9.1 Rules

- Use a **new banner** when the new content is a distinct concept with its own purpose. The new banner gets its own entry in the FILE ORGANIZATION list.
- Use a **sub-section marker** (`/* -- <label> -- */`) when the new content is a sub-component of an existing concept, grouped for visual reading aid only. Sub-section markers do not appear in the FILE ORGANIZATION list and do not nest.

---

## 10. Custom property tokens

Custom properties (CSS variables) are the mechanism for sharing values across the codebase. Tokens live in `:root` declarations inside the FOUNDATION section of the component's shell file (§4.2). Pages consume tokens via `var(--token-name)` references.

### 10.1 Token naming

Tokens follow the form `--<category>-<role>-<modifier>`, where:

- `category` is one of the recognized token categories: `color`, `size`, `font`, `duration`, `shadow`, `z`, `gradient`. The set is closed; adding a new category requires a spec amendment.
- `role` describes the token's functional purpose (e.g., `bg-card`, `accent-platform`, `text-muted`). Role is purpose-based, not appearance-based.
- `modifier` is optional and distinguishes variants of the same role (e.g., `hover`, `default`, `lg`, `sm`).

### 10.2 Rules

- Tokens are defined once, in the component's shell file FOUNDATION section. Page files do not redeclare or override tokens locally.
- A value used in two or more places in the codebase is a token. Single-use values may remain literals.
- Pages reference tokens via `var(--token-name)` only. Hex literals or pixel literals where a token exists are drift.
- Exactly one `:root` block per file. Multiple `:root` blocks are drift.
- The `:root` block is preceded by a purpose comment in the form `/* One-sentence purpose. */`.
- Sub-section markers are permitted inside `:root` as group labels.
- Within `:root`, blank lines may separate token groups. This is the only location where blank lines inside a rule body are permitted.

---

## 11. @keyframes

`@keyframes` definitions are permitted only in the FOUNDATION section of the component's shell file (§4.2). Every `@keyframes` block is preceded by a purpose comment in the form `/* One-sentence purpose. */`. Pages consume keyframes via `animation: <keyframe-name> ...` references but do not define new keyframes.

---

## 12. @media

`@media` blocks may appear inside any section. Rules wrapped by `@media` are subject to all other spec rules.

### 12.1 Rules

- Every `@media` block is preceded by a purpose comment in the form `/* One-sentence purpose. */`.
- An `@media` block is a top-level construct subject to the blank-line rule (§13).

---

## 13. File-level discipline

Rules that apply to the file as a whole.

### 13.1 Rules

- Every two adjacent top-level constructs are separated by exactly one blank line. Top-level constructs are: the file header, every section banner, every class definition, every variant, every pseudo-element rule, every sub-section marker, every `@media` block, every `@keyframes` block, and the `:root` block.
- Every section banner is followed by at least one cataloguable construct before the next banner or end-of-file.
- The file ends with `}` followed by exactly one newline (`\n`).

---

## 14. Forbidden patterns

| Pattern | Notes |
|---------|-------|
| Element selector outside FOUNDATION (`body`, `h1`, `a`, etc.) | Permitted only inside FOUNDATION for resets. |
| Universal selector (`*`) outside FOUNDATION | Same as above. |
| Attribute selector (`[type="text"]`) outside FOUNDATION | Same. |
| Pseudo-element outside FOUNDATION not attached to a class (`::before` standalone) | A pseudo-element attached to a class (`.foo::before`) is a class definition (§6.1). |
| ID selector (`#foo`) | Class-based styling required. |
| Selector group (comma-separated selectors) | Each selector gets its own definition block. |
| Descendant combinator (whitespace-separated selectors) | Use state-on-element (§7.2). |
| Child combinator (`>`) | Same. |
| Adjacent sibling combinator (`+`) | Same. |
| General sibling combinator (`~`) | Same. |
| Compound depth ≥ 3 (`.foo.bar.baz`) | Cap at two class tokens. |
| Stacked pseudo-classes (`.foo:hover:focus`) | One pseudo per selector. |
| `:not(...)` in any form | Express the negation as an explicit state class. |
| Pseudo-class interleaved between class tokens (`.a:hover.b`) | Pseudo-classes come last in any compound. |
| `@import` | — |
| `@font-face` | — |
| `@supports` | — |
| `@keyframes` outside the shell file FOUNDATION | — |
| Custom property defined outside the shell file FOUNDATION | — |
| Hex literal where a token exists | Use `var(--token-name)`. |
| Pixel literal where a size token exists | Same. |
| CHANGELOG block in file header | Change history lives in git. |
| Two or more declarations on the same line | One declaration per line. |
| Blank line inside a class definition | Permitted only inside `:root` (§10.2). |
| More than one blank line between top-level constructs | — |
| Comment form not matching the four recognized kinds (§8) | — |

`@media` is permitted in any section. Wrapped rules are subject to all other rules.

---

## 15. Drift code reference

The populator emits a drift code on every spec violation. Each code maps to a single rule. This table is the contract between the spec and the populator.

| Code | Description | Rule |
|------|-------------|------|
| `MALFORMED_FILE_HEADER` | File header is missing, malformed, or has required fields out of order. | §2 |
| `FORBIDDEN_CHANGELOG_BLOCK` | File header contains a CHANGELOG block. | §2.1 |
| `FILE_ORG_MISMATCH` | FILE ORGANIZATION list does not match section banner titles verbatim, in order. | §2.1 |
| `MISSING_SECTION_BANNER` | A catalogable construct appears outside any banner. | §3 |
| `BANNER_INLINE_SHAPE` | A section banner uses a single-line form. | §3.1 |
| `BANNER_INVALID_RULE_CHAR` | A banner's opening or closing rule line is not all `=`. | §3.1 |
| `BANNER_INVALID_RULE_LENGTH` | A banner's opening or closing rule line is not exactly 76 characters. | §3.1 |
| `BANNER_INVALID_SEPARATOR_CHAR` | A banner's middle separator is not all `-`. | §3.1 |
| `BANNER_INVALID_SEPARATOR_LENGTH` | A banner's middle separator is not exactly 76 characters. | §3.1 |
| `BANNER_MALFORMED_TITLE_LINE` | A banner's title line does not parse as `<TYPE>: <NAME>`. | §3.1 |
| `BANNER_MISSING_DESCRIPTION` | A banner has no description text. | §3.1 |
| `UNKNOWN_SECTION_TYPE` | A banner declares a TYPE not in the recognized list. | §4 |
| `SECTION_TYPE_ORDER_VIOLATION` | Section types appear out of order. | §4.1 |
| `DUPLICATE_FOUNDATION` | A FOUNDATION section appears in a non-shell file. | §4.1 |
| `DUPLICATE_CHROME` | A CHROME section appears in a non-shell file. | §4.1 |
| `MISSING_PREFIX_DECLARATION` | A banner is missing the `Prefix:` line. | §5.2 |
| `MALFORMED_PREFIX_VALUE` | A banner declares a `Prefix:` value that is neither a page prefix nor `cc`, or declares multiple comma-separated values. | §5.2 |
| `PREFIX_REGISTRY_MISMATCH` | A page-file banner's declared prefix does not match `Component_Registry.cc_prefix`. | §5.2 |
| `SHELL_SECTION_INVALID_PREFIX` | A FOUNDATION, CHROME, or shell-file FEEDBACK_OVERLAYS section declares a prefix other than `cc`. | §5.2 |
| `PREFIX_MISMATCH` | A class name's leftmost token does not begin with the declared prefix. Every class token in a compound selector is checked. | §5, §6.1, §7.1 |
| `UNDEFINED_CLASS_USAGE` | A class participating in a class-on-class compound rule has no standalone single-class definition in the same file. | §7.1 |
| `ORPHAN_VARIANT` | A pseudo-class variant references a class with no single-class definition in the same file. | §7.1 |
| `PSEUDO_ELEMENT_OUT_OF_ORDER` | A pseudo-element rule appears before its base class or after a variant on the same class. | §7.1 |
| `VARIANT_BEFORE_BASE` | A class variant appears before its base class definition in the file. | §7.1 |
| `MISSING_PURPOSE_COMMENT` | A class definition, `:root` block, `@keyframes` block, or `@media` block is not preceded by a single-line purpose comment. | §6.1, §10.2, §11, §12.1 |
| `MISSING_VARIANT_COMMENT` | A variant does not carry a trailing inline comment. | §7.1 |
| `DUPLICATE_ROOT_BLOCK` | A file contains more than one `:root` block. | §10.2 |
| `FORBIDDEN_ELEMENT_SELECTOR` | Element selector outside FOUNDATION. | §14 |
| `FORBIDDEN_UNIVERSAL_SELECTOR` | Universal selector outside FOUNDATION. | §14 |
| `FORBIDDEN_ATTRIBUTE_SELECTOR` | Attribute selector outside FOUNDATION. | §14 |
| `FORBIDDEN_PSEUDO_ELEMENT_LOCATION` | Pseudo-element outside FOUNDATION not attached to a class. | §14 |
| `FORBIDDEN_ID_SELECTOR` | Selector includes an `#id` token. | §14 |
| `FORBIDDEN_GROUP_SELECTOR` | Selector contains a comma. | §14 |
| `FORBIDDEN_DESCENDANT` | Selector contains a descendant combinator. | §7.2, §14 |
| `FORBIDDEN_CHILD_COMBINATOR` | Selector contains a `>` combinator. | §14 |
| `FORBIDDEN_ADJACENT_SIBLING` | Selector contains a `+` combinator. | §14 |
| `FORBIDDEN_GENERAL_SIBLING` | Selector contains a `~` combinator. | §14 |
| `COMPOUND_DEPTH_3PLUS` | Compound selector contains three or more class tokens. | §7.1, §14 |
| `FORBIDDEN_STACKED_PSEUDO` | Compound selector contains two or more pseudo-classes. | §7.1, §14 |
| `FORBIDDEN_NOT_PSEUDO` | Selector contains `:not(...)`. | §7.1, §14 |
| `PSEUDO_INTERLEAVED` | Pseudo-class appears between two class tokens. | §14 |
| `FORBIDDEN_AT_IMPORT` | File contains `@import`. | §14 |
| `FORBIDDEN_AT_FONT_FACE` | File contains `@font-face`. | §14 |
| `FORBIDDEN_AT_SUPPORTS` | File contains `@supports`. | §14 |
| `FORBIDDEN_KEYFRAMES_LOCATION` | `@keyframes` appears outside the shell file FOUNDATION. | §11, §14 |
| `FORBIDDEN_CUSTOM_PROPERTY_LOCATION` | Custom property definition appears outside the shell file FOUNDATION. | §10.2, §14 |
| `DRIFT_HEX_LITERAL` | Hex color literal where a token exists. | §10.2, §14 |
| `DRIFT_PX_LITERAL` | Pixel literal where a size token exists. | §10.2, §14 |
| `FORBIDDEN_COMPOUND_DECLARATION` | Two or more declarations on the same line. | §14 |
| `BLANK_LINE_INSIDE_RULE` | Blank line inside a class definition outside `:root`. | §10.2, §14 |
| `EXCESS_BLANK_LINES` | More than one blank line between top-level constructs. | §13.1, §14 |
| `FORBIDDEN_COMMENT_STYLE` | Comment does not match one of the four recognized forms. | §8, §14 |
| `MISSING_BLANK_LINE_SEPARATOR` | Two adjacent top-level constructs have no blank line between them. | §13.1 |
| `EMPTY_SECTION` | A section banner is not followed by any cataloguable construct before the next banner or end-of-file. | §13.1 |
| `MISSING_TRAILING_NEWLINE` | The file does not end with a single trailing newline. | §13.1 |

# Control Center JavaScript File Format Specification

*These rules are the current authority for Control Center JavaScript files. They are settled until explicitly amended; any proposed change is discussed before adoption. Where rationale exists for a rule, it appears in the Appendix at the corresponding section number.*

---

## 1. Required structure

A JavaScript file consists of three parts in this exact order:

1. **File header** - a single block comment opening at line 1, ending with `*/` followed by exactly one blank line.
2. **Section bodies** - one or more sections, each consisting of a section banner followed by the declarations and statements that section contains.
3. **End-of-file** - the file ends after the last meaningful statement of the last section. No trailing content.

Every line of code in the file lives inside exactly one of these three parts.

---

## 2. File header

The header is a single block comment at the very top of the file. Every field is mandatory and appears in this exact order:

```
xFACts Control Center - <Component Description> (<filename>)
Location: E:\xFACts-ControlCenter\public\js\<filename>
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
- The list is unnumbered. Trailing `-- <description>` text on list entries is permitted and is stripped by the parser before comparison.

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
- `<TYPE>` must be one of the recognized section types (Section 4). The TYPE token is uppercase letters and underscores only.
- `<NAME>` is human-readable and may contain spaces, commas, and other punctuation.
- The description block is 1-5 sentences explaining what the section contains. Required.
- The `Prefix:` line declares the page prefix that scopes identifiers in this section (Section 5). Required, singular.

### 3.2 Banner authoring discipline

When adding new content to a file, prefer creating a new banner over expanding an existing one if the new content is a distinct concept.

---

## 4. Section types

The recognized section types differ between page files and the shared file `cc-shared.js`.

### 4.1 Page files

Five section types, in fixed order:

| Order | TYPE | Purpose | Multiple banners? |
|-------|------|---------|-------------------|
| 1 | `IMPORTS` | ES module imports or `require` statements. | No - single banner only. |
| 2 | `CONSTANTS` | Module-scope `const` declarations of immutable values. | Yes - group by concept. |
| 3 | `STATE` | Module-scope `var` declarations of mutable values. | Yes - group by concept. |
| 4 | `INITIALIZATION` | The `DOMContentLoaded` handler and any one-time setup functions called from it. | No - single banner only. |
| 5 | `FUNCTIONS` | Everything else - data loading, rendering, event handlers, helpers, hooks. | Yes. The banner for page lifecycle hooks has a fixed name (Section 8) and must be last. |

### 4.2 The shared file `cc-shared.js`

Four section types, in fixed order:

| Order | TYPE | Purpose | Multiple banners? | Where it lives |
|-------|------|---------|-------------------|----------------|
| 1 | `IMPORTS` | ES module imports or `require` statements. Reserved for future use. | No. | Both. |
| 2 | `FOUNDATION` | Platform-wide immutable constants and primitives. Holds `const` declarations only. | Yes - group by concept. | `cc-shared.js` only. |
| 3 | `STATE` | Platform-wide mutable runtime state. Holds `var` declarations only. | Yes - group by concept. | Both. |
| 4 | `CHROME` | Universal page chrome and shared utilities. | Yes - group by concept. | `cc-shared.js` only. |

`FOUNDATION` is `cc-shared.js`'s name for what page files call `CONSTANTS`; `CHROME` is its name for `INITIALIZATION` plus `FUNCTIONS` combined; `STATE` keeps the same name and meaning in both file kinds.

### 4.3 Type-order rule

Section types must appear in the order shown. Drift code: `SECTION_TYPE_ORDER_VIOLATION`.

### 4.4 Type uniqueness across files

`FOUNDATION` and `CHROME` sections may exist in only one file across the codebase: `cc-shared.js`. Drift codes: `DUPLICATE_FOUNDATION`, `DUPLICATE_CHROME`.

---

## 5. Prefixes

Every section banner declares a single page prefix via the `Prefix:` line. Every top-level identifier (function name, constant name, state variable name) defined in that section must begin with the declared prefix followed by an underscore. Drift code: `PREFIX_MISMATCH`.

### 5.1 Prefix selection rules

The page prefix is a 3-character lowercase identifier and is the same prefix used by the page's CSS file. The separator after the prefix is an underscore (`_`), not a hyphen.

### 5.2 Special values

- `Prefix: (none)` - sentinel value. Declares the section has no page-prefix scoping. Used by:
  - All sections in `cc-shared.js`.
  - The page lifecycle hooks banner in any page file.
  - The `IMPORTS` and `INITIALIZATION` sections of any file.

The `Prefix:` line itself is mandatory regardless of value. Drift code if absent: `MISSING_PREFIX_DECLARATION`.

---

## 6. Function definitions

A function definition has exactly one form:

```
function name() { ... }
```

Forbidden alternatives, all emitting `FORBIDDEN_ANONYMOUS_FUNCTION` on the row representing the const/var declaration:

| Form | Reason forbidden |
|------|------------------|
| `const name = function() { ... };` | Anonymous function expression |
| `const name = () => { ... };` | Arrow function expression |
| `const name = function namedThing() { ... };` | Named function expression |

The narrow exception is callback arguments to other calls; see Section 14.1.

### 6.1 Function comment requirement

Every function definition must be preceded by a single block comment immediately above the declaration. The comment is at minimum a single-sentence purpose. JSDoc-format parameter and return documentation is allowed and encouraged but not mandatory. Drift code: `MISSING_FUNCTION_COMMENT`.

### 6.2 Function naming rules

- Top-level function names in a page file must begin with the page prefix followed by an underscore (Section 5).
- Functions in the page lifecycle hooks banner (Section 8) use the fixed hook names instead.
- Functions in `cc-shared.js` are not page-prefixed; their `Prefix:` line is `(none)`.

### 6.3 Async and generator functions

`async` and `generator` functions are permitted forms of `function` declarations and are catalog-distinguished as `JS_FUNCTION_VARIANT` rows with `variant_type='async'` or `variant_type='generator'` (Section 16.5).

---

## 7. Constants and state

Module-scope declarations split into two kinds based on the section they live in:

- **`CONSTANTS` and `FOUNDATION` sections**: declarations are `const`. Primitive values produce `JS_CONSTANT DEFINITION` rows; compound values (objects, arrays, regexes, computed expressions) produce `JS_CONSTANT_VARIANT DEFINITION` rows. See Section 16.5.
- **`STATE` sections**: declarations are `var`. They produce `JS_STATE DEFINITION` rows.

Drift code if `var` appears in a `CONSTANTS` or `FOUNDATION` section, or `const` in a `STATE` section: `WRONG_DECLARATION_KEYWORD`.

`let` is forbidden anywhere in the codebase. Drift code: `FORBIDDEN_LET`.

### 7.1 Comment requirement

Every constant and state declaration must be preceded by a single-line block comment describing its purpose. Drift codes: `MISSING_CONSTANT_COMMENT` (constants), `MISSING_STATE_COMMENT` (state variables).

### 7.2 Naming conventions

- **Constants**: SCREAMING_SNAKE_CASE preferred for primitive values; camelCase acceptable for objects and lookup tables. Both must carry the page prefix.
- **State variables**: camelCase. Must carry the page prefix.

The case-distinction rule is conventional, not parser-enforced.

### 7.3 Multiple declarations per statement

`var a, b, c;` and `const a = 1, b = 2;` are forbidden. Each declaration gets its own statement. Drift code: `FORBIDDEN_MULTI_DECLARATION`.

---

## 8. Page lifecycle hooks

Page lifecycle hooks are the named callbacks that `cc-shared.js` invokes on each page when relevant events occur. The set is fixed:

| Hook | When called | What it should do |
|------|-------------|-------------------|
| `onPageRefresh` | User clicks the page refresh button | Re-fetch all sections marked Action or Live |
| `onPageResumed` | Tab regained visibility after being hidden | Re-fetch live data; reconnect WebSocket if needed |
| `onSessionExpired` | Auth check failed; session is dead | Stop all page-specific polling timers |
| `onEngineProcessCompleted` | An orchestrator process this page cares about finished | Re-fetch event-driven sections |
| `onEngineEventRaw` | Every WebSocket event before filtering (Admin only) | Used by the Admin page to drive the process timeline |

A page file defines only the hooks it uses. `cc-shared.js` probes for each via `typeof onX === 'function'` before calling.

### 8.1 The hooks banner

If any hooks are defined, they live in a `FUNCTIONS` banner with the fixed name `PAGE LIFECYCLE HOOKS`. The banner declares `Prefix: (none)`. See Section 20 for an example.

### 8.2 Banner placement rule

If the `FUNCTIONS: PAGE LIFECYCLE HOOKS` banner exists, it must be the last banner in the file. Drift code: `HOOKS_BANNER_NOT_LAST`.

### 8.3 Catalog representation

Functions inside the hooks banner produce `JS_HOOK DEFINITION` rows (or `JS_HOOK_VARIANT DEFINITION` for async hooks; see Section 16.5), not `JS_FUNCTION DEFINITION` rows. The function comment requirement still applies.

### 8.4 Hook naming

Hook names are the API contract with `cc-shared.js`. They cannot be renamed. The hooks banner declares `Prefix: (none)` so functions inside the banner do not trigger `PREFIX_MISMATCH`. A function inside the banner whose name is not in the recognized set emits `UNKNOWN_HOOK_NAME`.

---

## 9. Classes and methods

JS classes are not currently used in any Control Center page file but are covered for forward compatibility.

### 9.1 Class declarations

Class declarations live at module scope inside a `FUNCTIONS` section and produce a `JS_CLASS DEFINITION` row. Class names follow the same prefix rule as functions. A class declaration must be preceded by a single-sentence purpose comment. Drift code: `MISSING_CLASS_COMMENT`.

### 9.2 Methods

Methods inside a class body produce `JS_METHOD DEFINITION` rows for regular methods, or `JS_METHOD_VARIANT DEFINITION` for static/getter/setter/async forms (Section 16.5). Each method must carry a preceding single-sentence purpose comment. Drift code: `MISSING_METHOD_COMMENT`.

Methods do not carry the page prefix; they are namespaced inside the class itself.

---

## 10. Imports

`IMPORTS` sections contain ES module `import` statements or Node `require` calls. The current Control Center JS code uses neither, so this section is empty in every current file.

Each import produces a `JS_IMPORT DEFINITION` row keyed on the imported binding name. The source module path lives in `variant_qualifier_2`. See Section 16.5 for the variant grid.

---

## 11. Initialization

The `INITIALIZATION` section contains:

1. The `document.addEventListener('DOMContentLoaded', ...)` handler that runs page setup
2. Any one-time setup functions called only from that handler

Functions in this section may invoke functions from any later section. Functions in `FUNCTIONS` may not depend on initialization having run beyond the constants and state being populated.

The `DOMContentLoaded` handler itself is anonymous and is registered via `addEventListener`. It does not produce a `JS_FUNCTION DEFINITION` row; the parser treats it as initialization code, not a named definition. This is one of the allowed-callback contexts described in Section 14.1.

---

## 12. Comments

Comments serve four roles, and only four:

1. **File header** - a single block comment at line 1 (Section 2).
2. **Section banners** - multi-line block comments enclosing a section's title, description, and prefix declaration (Section 3).
3. **Purpose comments** - single block comment immediately preceding a function, class, method, constant, state variable, or hook.
4. **Sub-section markers** - inline block comment between definitions in a section, used as a lightweight visual divider. Format: `/* -- label -- */`. Optional.

No other comment forms are recognized. Stray block comments at file scope are a parse error.

### 12.1 Inline comments

Inline `//` line comments are permitted inside function bodies for explaining specific lines or blocks of logic. They are not cataloged.

Inline `//` line comments are forbidden at file scope. Each file-scope `//` comment emits a `JS_LINE_COMMENT` row at its own line with `FORBIDDEN_FILE_SCOPE_LINE_COMMENT` drift attached.

### 12.2 Comment content rules

- Purpose comments are written in present-tense, descriptive style. They describe what the function/constant/state does, not why it does it.
- Section banner descriptions may be 1-5 sentences. They explain what the section contains.

---

## 13. Sub-section markers vs. new banners

When a section's content grows, two structural tools are available: sub-section markers (lightweight visual dividers within a single banner) and new banners of the same type.

### 13.1 Use a new banner when

- The new content is a distinct concept with its own purpose
- The new content has its own audience or readership context
- A reader scanning the file's FILE ORGANIZATION list would benefit from seeing the new content as a top-level entry

A new banner gets its own row in the FILE ORGANIZATION list.

### 13.2 Use a sub-section marker when

- The new content is a sub-component of an existing concept
- Grouping is for visual reading aid only, not a structural distinction

Sub-section markers use the inline format `/* -- <label> -- */`. They are decorative; the parser ignores them. They do not appear in the FILE ORGANIZATION list and do not nest.

---

## 14. Forbidden patterns

Every forbidden pattern emits a row in the catalog with the relevant drift code attached. A clean codebase has zero rows with drift; any drift is an action item to fix.

Some forbidden patterns ride on the row of an existing declaration. Others have no natural declaration to host the drift, so the parser emits a dedicated row at the violation site using a component_type that exists solely to represent the forbidden pattern.

| Pattern | Drift code | Row host |
|---------|------------|----------|
| `let` declarations | `FORBIDDEN_LET` | The declaration row (JS_CONSTANT / JS_STATE / etc.) |
| Multiple declarations per statement (`var a, b, c`) | `FORBIDDEN_MULTI_DECLARATION` | The declaration row |
| Top-level function declared inside an `if`/`while`/`try` block | `FORBIDDEN_CONDITIONAL_DEFINITION` | The function row |
| Anonymous function or arrow expression outside an allowed callback context | `FORBIDDEN_ANONYMOUS_FUNCTION` | The const/var declaration row |
| Defining a function whose name matches a `cc-shared.js` export | `SHADOWS_SHARED_FUNCTION` | The function row |
| Element-property event assignment (`el.onclick = handler`) | `FORBIDDEN_PROPERTY_ASSIGN_EVENT` | The JS_EVENT row |
| IIFE at file scope (`(function() { ... })()`) | `FORBIDDEN_IIFE` | A `JS_IIFE` row at the violation line |
| `eval(...)` | `FORBIDDEN_EVAL` | A `JS_EVAL` row at the violation line |
| `document.write(...)` | `FORBIDDEN_DOCUMENT_WRITE` | A `JS_DOCUMENT_WRITE` row at the violation line |
| `window.<name> = ...` outside `cc-shared.js` | `FORBIDDEN_WINDOW_ASSIGNMENT` | A `JS_WINDOW_ASSIGNMENT` row at the violation line |
| Inline `<style>` content in a template literal or string literal | `FORBIDDEN_INLINE_STYLE_IN_JS` | A `JS_INLINE_STYLE` row at the violation line |
| Inline `<script>` content in a template literal or string literal | `FORBIDDEN_INLINE_SCRIPT_IN_JS` | A `JS_INLINE_SCRIPT` row at the violation line |
| File-scope `//` line comment | `FORBIDDEN_FILE_SCOPE_LINE_COMMENT` | A `JS_LINE_COMMENT` row at the violation line |
| CHANGELOG block in file header | `FORBIDDEN_CHANGELOG_BLOCK` | The FILE_HEADER row |

### 14.1 Allowed anonymous callback contexts

A function or arrow expression passed as an argument to another call may be anonymous. This covers patterns like `addEventListener` callbacks, `.forEach` / `.map` callbacks, `.then` callbacks, and `setTimeout` / `setInterval` callbacks.

The parser walks into the anonymous body normally, so any function calls, class usage, or HTML markup inside the callback still produce rows. The `parent_function` column on those rows records the name of the outer call.

No other carve-outs. Anonymous functions assigned to a const or var, returned from another function, or used as object property values are all `FORBIDDEN_ANONYMOUS_FUNCTION` violations.

---

## 15. Required patterns summary

Every JS file must:

1. Open with a spec-compliant file header (Section 2).
2. Define all sections under recognized section types in declared order (Sections 3, 4).
3. Declare a valid prefix in every section banner (Section 5).
4. Precede every function, constant, state variable, hook, class, and method with a single block comment (Sections 6, 7, 8, 9, 12).
5. Use `const` in CONSTANTS sections and `var` in STATE sections (Section 7).
6. Define functions only as `function name() {}` declarations (Section 6).
7. Bind events only via `addEventListener` (Section 14).
8. Place page lifecycle hooks in a `FUNCTIONS: PAGE LIFECYCLE HOOKS` banner that is last in the file (Section 8).
9. Use one declaration per statement (Section 7.3).
10. Use the page prefix on every top-level identifier in a page file, except hooks (Section 5).
11. Use unprefixed identifiers in `cc-shared.js`, with `Prefix: (none)` declared (Sections 4.2, 5.2).
12. Match the FILE ORGANIZATION list to banner titles verbatim, in order (Section 2).

---

## 16. Catalog model

This section covers the catalog mechanism as it relates to JS files. Every cataloged JS construct gets one row in `dbo.Asset_Registry`.

### 16.1 What the catalog represents

The catalog represents everything the parser found in the file, with drift codes telling the operator what's wrong. Forbidden patterns produce rows just like permitted ones; the difference is the drift codes attached. A clean codebase has zero rows with non-NULL `drift_codes`.

A row's identity is the combination of `component_type`, `component_name`, `reference_type`, `file_name`, `occurrence_index`, `variant_type`, `variant_qualifier_1`, and `variant_qualifier_2`.

### 16.2 JS-relevant component_type values

| component_type | Meaning |
|---|---|
| `FILE_HEADER` | The file's header block. One row per scanned file. |
| `COMMENT_BANNER` | A section banner comment. One row per section. The section type lives in `signature`. |
| `JS_IMPORT` | An ES `import` statement or Node `require` call. The imported binding name is `component_name`. The source module path is `variant_qualifier_2`. Always non-NULL `variant_type`. |
| `JS_CONSTANT` | A `const` declaration of a primitive value in a `CONSTANTS` or `FOUNDATION` section. |
| `JS_CONSTANT_VARIANT` | A `const` declaration of a compound or computed value in a `CONSTANTS` or `FOUNDATION` section. |
| `JS_STATE` | A `var` declaration in a `STATE` section. No variants. |
| `JS_FUNCTION` | A regular `function name() {}` declaration. |
| `JS_FUNCTION_VARIANT` | An `async function name()` or `function* name()` (generator) declaration. |
| `JS_HOOK` | A regular sync function inside the `FUNCTIONS: PAGE LIFECYCLE HOOKS` banner. |
| `JS_HOOK_VARIANT` | An async function inside the hooks banner. |
| `JS_CLASS` | A class declaration at module scope. No variants. |
| `JS_METHOD` | A regular method defined inside a class body. The class name lives in `parent_function`. |
| `JS_METHOD_VARIANT` | A static method, getter, setter, or async method inside a class body. |
| `JS_TIMER` | A `setInterval` or `setTimeout` call assigned to a tracked handle. The handle name is `component_name`. Always non-NULL `variant_type`. |
| `JS_EVENT` | An `addEventListener` event handler binding. The event name is `component_name`. No variants. |
| `JS_IIFE` | An IIFE at file scope. Exists solely to host `FORBIDDEN_IIFE` drift. |
| `JS_EVAL` | An `eval(...)` call. Exists solely to host `FORBIDDEN_EVAL` drift. |
| `JS_DOCUMENT_WRITE` | A `document.write(...)` call. Exists solely to host `FORBIDDEN_DOCUMENT_WRITE` drift. |
| `JS_WINDOW_ASSIGNMENT` | A `window.<name> = ...` assignment outside `cc-shared.js`. Exists solely to host `FORBIDDEN_WINDOW_ASSIGNMENT` drift. |
| `JS_INLINE_STYLE` | A `<style>` element found in a JS template/string literal. Exists solely to host `FORBIDDEN_INLINE_STYLE_IN_JS` drift. |
| `JS_INLINE_SCRIPT` | A `<script>` element found in a JS template/string literal. Exists solely to host `FORBIDDEN_INLINE_SCRIPT_IN_JS` drift. |
| `JS_LINE_COMMENT` | A `//` line comment at file scope. Exists solely to host `FORBIDDEN_FILE_SCOPE_LINE_COMMENT` drift. |
| `CSS_CLASS` | A class name found inside a template literal, string literal, `classList.*` call, `className` assignment, or `setAttribute('class', ...)` call. Always `USAGE`. |
| `HTML_ID` | An `id="..."` attribute (DEFINITION) or a literal-string argument to `getElementById` / `querySelector('#...')` (USAGE). |

### 16.3 Scope determination

- DEFINITION rows in `cc-shared.js`: scope is `SHARED`.
- DEFINITION rows in any page file: scope is `LOCAL`.
- USAGE rows of functions: `SHARED` if the called function is defined in `cc-shared.js`; `LOCAL` if defined in the same page file. Calls to uncataloged identifiers do not produce rows.
- CSS_CLASS USAGE rows: resolved against existing CSS_CLASS DEFINITION rows in the consumer's zone.
- HTML_ID rows: always `LOCAL`.
- Forbidden-pattern rows: scope follows the file's overall scope. The drift code is the action item; the scope value is informational.

### 16.4 Drift recording

The parser evaluates every row against the spec and records two things when the row deviates:

- `drift_codes` - comma-separated list of stable short codes
- `drift_text` - joined human-readable descriptions corresponding to each code

A row may carry zero, one, or many drift codes. Both columns are NULL when the row is fully spec-compliant.

The full code-to-description mapping for JS appears in Section 18.

### 16.5 Variant model

Variant columns (`variant_type`, `variant_qualifier_1`, `variant_qualifier_2`) discriminate sub-flavors of certain component types. Two patterns are in use:

- **Base + `_VARIANT` companion type** - a base case with alternative semantically-distinct forms. Examples: `JS_FUNCTION` / `JS_FUNCTION_VARIANT`.
- **Single component type, always non-NULL `variant_type`** - every instance is a variant with no natural base. Examples: `JS_TIMER`, `JS_IMPORT`.

#### JS_FUNCTION (base) and JS_FUNCTION_VARIANT (variant)

| component_type | variant_type | qualifier_1 | qualifier_2 | Source pattern |
|---|---|---|---|---|
| `JS_FUNCTION` | NULL | NULL | NULL | `function bsv_load() {}` |
| `JS_FUNCTION_VARIANT` | `async` | NULL | NULL | `async function bsv_load() {}` |
| `JS_FUNCTION_VARIANT` | `generator` | NULL | NULL | `function* bsv_iter() {}` |

#### JS_CONSTANT (base) and JS_CONSTANT_VARIANT (variant)

| component_type | variant_type | qualifier_1 | qualifier_2 | Source pattern |
|---|---|---|---|---|
| `JS_CONSTANT` | NULL | NULL | NULL | Primitive value (string, number, boolean, null) |
| `JS_CONSTANT_VARIANT` | `object` | NULL | NULL | `const bsv_CONFIG = { foo: 1 }` |
| `JS_CONSTANT_VARIANT` | `array` | NULL | NULL | `const bsv_LEVELS = [1, 2, 3]` |
| `JS_CONSTANT_VARIANT` | `regex` | NULL | NULL | `const bsv_RE = /^foo/` |
| `JS_CONSTANT_VARIANT` | `expression` | NULL | NULL | Value computed from a function call or expression |

#### JS_HOOK (base) and JS_HOOK_VARIANT (variant)

| component_type | variant_type | qualifier_1 | qualifier_2 | Source pattern |
|---|---|---|---|---|
| `JS_HOOK` | NULL | NULL | NULL | `function onPageRefresh() {}` |
| `JS_HOOK_VARIANT` | `async` | NULL | NULL | `async function onPageRefresh() {}` |

#### JS_METHOD (base) and JS_METHOD_VARIANT (variant)

| component_type | variant_type | qualifier_1 | qualifier_2 | Source pattern |
|---|---|---|---|---|
| `JS_METHOD` | NULL | NULL | NULL | `foo() {}` (regular method) |
| `JS_METHOD_VARIANT` | `static` | NULL | NULL | `static foo() {}` |
| `JS_METHOD_VARIANT` | `getter` | NULL | NULL | `get foo() {}` |
| `JS_METHOD_VARIANT` | `setter` | NULL | NULL | `set foo(v) {}` |
| `JS_METHOD_VARIANT` | `async` | NULL | NULL | `async foo() {}` |

For all JS_METHOD and JS_METHOD_VARIANT rows, `parent_function` carries the enclosing class name.

#### JS_TIMER (always non-NULL variant_type)

| component_type | variant_type | qualifier_1 | qualifier_2 | Source pattern |
|---|---|---|---|---|
| `JS_TIMER` | `interval` | NULL | NULL | `bsv_pollTimer = setInterval(...)` |
| `JS_TIMER` | `timeout` | NULL | NULL | `bsv_retryTimer = setTimeout(...)` |

`component_name` is the handle variable name. The handle must be declared as a `JS_STATE` variable.

#### JS_IMPORT (always non-NULL variant_type)

| component_type | variant_type | qualifier_1 | qualifier_2 | Source pattern |
|---|---|---|---|---|
| `JS_IMPORT` | `default` | NULL | source-module-path | `import foo from 'bar'` |
| `JS_IMPORT` | `named` | NULL | source-module-path | `import { foo } from 'bar'` |
| `JS_IMPORT` | `namespace` | NULL | source-module-path | `import * as foo from 'bar'` |
| `JS_IMPORT` | `require` | NULL | source-module-path | `const foo = require('bar')` |

`component_name` is the imported binding name.

#### Component types with no variants

`FILE_HEADER`, `COMMENT_BANNER`, `JS_STATE`, `JS_CLASS`, `JS_EVENT`, `JS_IIFE`, `JS_EVAL`, `JS_DOCUMENT_WRITE`, `JS_WINDOW_ASSIGNMENT`, `JS_INLINE_STYLE`, `JS_INLINE_SCRIPT`, `JS_LINE_COMMENT` - variant columns are always NULL.

`CSS_CLASS` and `HTML_ID` rows emitted by the JS populator do not carry variant_type values.

---

## 17. What the parser extracts

| Row type | Source | Notes |
|----------|--------|-------|
| `FILE_HEADER DEFINITION` | The opening file header block | One per file. `purpose_description` carries the header's purpose paragraph. |
| `COMMENT_BANNER DEFINITION` | Each section banner | `signature` = TYPE, `component_name` = NAME, `purpose_description` = description block. |
| `JS_IMPORT DEFINITION` | Each `import` statement or `require` call | One per imported binding. `variant_type` = import shape; `variant_qualifier_2` = source module path. |
| `JS_CONSTANT DEFINITION` / `JS_CONSTANT_VARIANT DEFINITION` | Each `const` declaration in a `CONSTANTS` or `FOUNDATION` section | Base for primitive values; variant for objects, arrays, regexes, computed expressions. `purpose_description` = preceding purpose comment. |
| `JS_STATE DEFINITION` | Each `var` declaration in a `STATE` section | `purpose_description` = preceding purpose comment. |
| `JS_FUNCTION DEFINITION` / `JS_FUNCTION_VARIANT DEFINITION` | Each top-level `function` declaration in a `FUNCTIONS` section other than `PAGE LIFECYCLE HOOKS` | Base for plain function declarations; variant for async and generator forms. `signature` = function signature with parameter names. |
| `JS_HOOK DEFINITION` / `JS_HOOK_VARIANT DEFINITION` | Each `function` declaration in the hooks banner | Base for sync hooks; variant for async hooks. |
| `JS_CLASS DEFINITION` | Each top-level class declaration | `purpose_description` = preceding purpose comment. |
| `JS_METHOD DEFINITION` / `JS_METHOD_VARIANT DEFINITION` | Each method inside a class body | Base for regular methods; variant for static/getter/setter/async forms. `parent_function` = class name. |
| `JS_TIMER DEFINITION` | Each `setInterval` / `setTimeout` call assigned to a tracked handle | `component_name` = handle name. |
| `JS_FUNCTION USAGE` | Each call to a function defined in the same file or in `cc-shared.js` | Calls to unknown identifiers are not cataloged. |
| `JS_EVENT USAGE` | Each `addEventListener('event', ...)` call | `component_name` = event name. |
| `CSS_CLASS USAGE` | Each class name in a template literal, classList call, or setAttribute('class', ...) | Resolved to SHARED or LOCAL via the CSS_CLASS DEFINITION map. |
| `HTML_ID DEFINITION` | Each `id="..."` in a template/string literal or `setAttribute('id', ...)` or `el.id = '...'` | LOCAL scope. |
| `HTML_ID USAGE` | Each `getElementById('...')` or `querySelector('#...')` argument | LOCAL scope. |
| `JS_IIFE DEFINITION` | Each IIFE at file scope | Always `FORBIDDEN_IIFE` drift. |
| `JS_EVAL USAGE` | Each `eval(...)` call | Always `FORBIDDEN_EVAL` drift. |
| `JS_DOCUMENT_WRITE USAGE` | Each `document.write(...)` call | Always `FORBIDDEN_DOCUMENT_WRITE` drift. |
| `JS_WINDOW_ASSIGNMENT DEFINITION` | Each `window.<name> = ...` assignment outside `cc-shared.js` | Always `FORBIDDEN_WINDOW_ASSIGNMENT` drift. |
| `JS_INLINE_STYLE DEFINITION` | Each `<style>` tag in a JS template/string literal | Always `FORBIDDEN_INLINE_STYLE_IN_JS` drift. |
| `JS_INLINE_SCRIPT DEFINITION` | Each `<script>` tag in a JS template/string literal | Always `FORBIDDEN_INLINE_SCRIPT_IN_JS` drift. |
| `JS_LINE_COMMENT DEFINITION` | Each `//` line comment at file scope | Always `FORBIDDEN_FILE_SCOPE_LINE_COMMENT` drift. |

---

## 18. Drift codes reference

### 18.1 File-level codes

| Code | Description |
|---|---|
| `MALFORMED_FILE_HEADER` | The file's header block is missing, malformed, or contains required fields out of order. |
| `FORBIDDEN_CHANGELOG_BLOCK` | The file header contains a CHANGELOG block. |
| `FILE_ORG_MISMATCH` | The FILE ORGANIZATION list in the header does not exactly match the section banner titles in the file body. |

### 18.2 Section-level codes

| Code | Description |
|---|---|
| `MISSING_SECTION_BANNER` | A definition appears outside any banner. |
| `MALFORMED_SECTION_BANNER` | A section banner exists but does not follow the strict format. |
| `UNKNOWN_SECTION_TYPE` | A section banner declares a TYPE not in the enumerated list. |
| `SECTION_TYPE_ORDER_VIOLATION` | Section types appear out of the required order. |
| `MISSING_PREFIX_DECLARATION` | A section banner is missing the mandatory `Prefix:` line. |
| `DUPLICATE_FOUNDATION` | More than one JS file in the codebase contains a FOUNDATION section. |
| `DUPLICATE_CHROME` | More than one JS file in the codebase contains a CHROME section. |
| `HOOKS_BANNER_NOT_LAST` | A `FUNCTIONS: PAGE LIFECYCLE HOOKS` banner exists but is not the last banner in the file. |

### 18.3 Definition-level codes

| Code | Description |
|---|---|
| `PREFIX_MISMATCH` | A top-level identifier name does not begin with the prefix declared in its containing section's banner. |
| `MISSING_FUNCTION_COMMENT` | A function definition is not preceded by a single block comment. |
| `MISSING_CONSTANT_COMMENT` | A `const` declaration in a CONSTANTS section is not preceded by a single block comment. |
| `MISSING_STATE_COMMENT` | A `var` declaration in a STATE section is not preceded by a single block comment. |
| `MISSING_CLASS_COMMENT` | A class declaration is not preceded by a single block comment. |
| `MISSING_METHOD_COMMENT` | A method inside a class body is not preceded by a single block comment. |
| `WRONG_DECLARATION_KEYWORD` | A `var` declaration appears in a CONSTANTS or FOUNDATION section, or a `const` declaration appears in a STATE section. |
| `SHADOWS_SHARED_FUNCTION` | A page file defines a function whose name matches a `cc-shared.js` export. |
| `UNKNOWN_HOOK_NAME` | A function inside the hooks banner has a name not in the recognized hook set. |

### 18.4 Forbidden-pattern codes

| Code | Description | Row host |
|---|---|---|
| `FORBIDDEN_LET` | A `let` declaration appears anywhere in the file. | Declaration row |
| `FORBIDDEN_MULTI_DECLARATION` | A single statement declares multiple variables. | Declaration row |
| `FORBIDDEN_CONDITIONAL_DEFINITION` | A top-level function or class is declared inside an `if`/`while`/`try` block. | Function/class row |
| `FORBIDDEN_ANONYMOUS_FUNCTION` | A function or arrow expression has no name and is not passed as a callback argument. | The const/var row |
| `FORBIDDEN_PROPERTY_ASSIGN_EVENT` | An event handler is bound via `el.on<event> = handler` instead of `addEventListener`. | JS_EVENT row |
| `FORBIDDEN_IIFE` | An IIFE appears at file scope. | JS_IIFE row |
| `FORBIDDEN_EVAL` | A call to `eval(...)` appears in the file. | JS_EVAL row |
| `FORBIDDEN_DOCUMENT_WRITE` | A call to `document.write(...)` appears in the file. | JS_DOCUMENT_WRITE row |
| `FORBIDDEN_WINDOW_ASSIGNMENT` | An assignment to `window.<name>` appears outside `cc-shared.js`. | JS_WINDOW_ASSIGNMENT row |
| `FORBIDDEN_INLINE_STYLE_IN_JS` | A template literal or string literal contains a `<style>` element. | JS_INLINE_STYLE row |
| `FORBIDDEN_INLINE_SCRIPT_IN_JS` | A template literal or string literal contains a `<script>` element. | JS_INLINE_SCRIPT row |
| `FORBIDDEN_FILE_SCOPE_LINE_COMMENT` | A `//` line comment appears at file scope. | JS_LINE_COMMENT row |

### 18.5 Comment / structure codes

| Code | Description |
|---|---|
| `FORBIDDEN_COMMENT_STYLE` | A comment exists that is not one of the allowed kinds. |
| `BLANK_LINE_INSIDE_FUNCTION_BODY_AT_SCOPE` | More than one consecutive blank line appears inside a function body. |
| `EXCESS_BLANK_LINES` | More than one blank line appears between top-level constructs. |

---

## 19. Compliance queries

Standard SQL queries against `dbo.Asset_Registry` for JS compliance reporting. Each query is scoped to `WHERE file_type = 'JS'`.

### 19.1 Q1 - Shared-function shadowing

Find every page file that defines a function whose name matches a `cc-shared.js` export.

```sql
SELECT
    local.file_name        AS reinventing_file,
    local.line_start       AS local_line,
    local.component_name   AS function_name,
    shared.line_start      AS shared_line
FROM dbo.Asset_Registry local
INNER JOIN dbo.Asset_Registry shared
    ON  local.component_name = shared.component_name
    AND local.component_type IN ('JS_FUNCTION', 'JS_FUNCTION_VARIANT')
    AND shared.component_type IN ('JS_FUNCTION', 'JS_FUNCTION_VARIANT')
    AND local.reference_type  = 'DEFINITION'
    AND shared.reference_type = 'DEFINITION'
WHERE local.file_type    = 'JS'
  AND local.scope        = 'LOCAL'
  AND shared.scope       = 'SHARED'
  AND shared.file_name   = 'cc-shared.js'
ORDER BY local.component_name, local.file_name;
```

### 19.2 Q2 - Drift summary per file

Counts of total rows and rows-with-drift per file. Use this to prioritize conversion work.

```sql
SELECT
    file_name,
    COUNT(*)                                                     AS total_rows,
    SUM(CASE WHEN drift_codes IS NOT NULL THEN 1 ELSE 0 END)     AS rows_with_drift
FROM dbo.Asset_Registry
WHERE file_type = 'JS'
GROUP BY file_name
ORDER BY rows_with_drift DESC;
```

### 19.3 Q3 - Drift code distribution

What's the most common kind of drift across the JS codebase?

```sql
SELECT
    TRIM(value)         AS code,
    COUNT(*)            AS occurrences
FROM dbo.Asset_Registry
CROSS APPLY STRING_SPLIT(drift_codes, ',')
WHERE file_type    = 'JS'
  AND drift_codes  IS NOT NULL
  AND TRIM(value)  <> ''
GROUP BY TRIM(value)
ORDER BY COUNT(*) DESC;
```

### 19.4 Q4 - Hook implementation matrix

Which pages implement which hooks?

```sql
SELECT
    file_name AS page_file,
    SUM(CASE WHEN component_name = 'onPageRefresh'            THEN 1 ELSE 0 END) AS has_onPageRefresh,
    SUM(CASE WHEN component_name = 'onPageResumed'            THEN 1 ELSE 0 END) AS has_onPageResumed,
    SUM(CASE WHEN component_name = 'onSessionExpired'         THEN 1 ELSE 0 END) AS has_onSessionExpired,
    SUM(CASE WHEN component_name = 'onEngineProcessCompleted' THEN 1 ELSE 0 END) AS has_onEngineProcessCompleted,
    SUM(CASE WHEN component_name = 'onEngineEventRaw'         THEN 1 ELSE 0 END) AS has_onEngineEventRaw
FROM dbo.Asset_Registry
WHERE file_type      = 'JS'
  AND component_type IN ('JS_HOOK', 'JS_HOOK_VARIANT')
  AND reference_type = 'DEFINITION'
GROUP BY file_name
ORDER BY file_name;
```

### 19.5 Q5 - Page glossary (function reference)

For one specific page, list every function it defines with its purpose comment.

```sql
SELECT
    component_name      AS function_name,
    line_start          AS line,
    source_section      AS in_section,
    purpose_description AS purpose
FROM dbo.Asset_Registry
WHERE file_type      = 'JS'
  AND file_name      = '<filename.js>'
  AND component_type IN ('JS_FUNCTION', 'JS_FUNCTION_VARIANT', 'JS_HOOK', 'JS_HOOK_VARIANT')
  AND reference_type = 'DEFINITION'
ORDER BY line_start;
```

### 19.6 Q6 - Forbidden-pattern inventory

List every forbidden-pattern occurrence with line and context. Once the codebase is fully spec-compliant, this query returns zero rows.

```sql
SELECT
    file_name,
    line_start,
    component_type,
    drift_codes,
    drift_text
FROM dbo.Asset_Registry
WHERE file_type      = 'JS'
  AND component_type IN ('JS_IIFE', 'JS_EVAL', 'JS_DOCUMENT_WRITE',
                         'JS_WINDOW_ASSIGNMENT', 'JS_INLINE_STYLE',
                         'JS_INLINE_SCRIPT', 'JS_LINE_COMMENT')
ORDER BY file_name, line_start;
```

---

## 20. Examples

### 20.1 Minimal complete page file

A small page demonstrating every required pattern. Real pages have more sections.

```javascript
/* ============================================================================
   xFACts Control Center - Example Page (example.js)
   Location: E:\xFACts-ControlCenter\public\js\example.js
   Version: Tracked in dbo.System_Metadata (component: ExampleModule.ExamplePage)

   Page-specific JavaScript for the Example dashboard. Loads agent data,
   renders status cards, and wires the page lifecycle hooks consumed by
   cc-shared.js.

   FILE ORGANIZATION
   -----------------
   CONSTANTS: PAGE CONFIGURATION
   STATE: PAGE STATE
   INITIALIZATION: PAGE BOOT
   FUNCTIONS: DATA LOADING
   FUNCTIONS: RENDERING
   FUNCTIONS: PAGE LIFECYCLE HOOKS
   ============================================================================ */


/* ============================================================================
   CONSTANTS: PAGE CONFIGURATION
   ----------------------------------------------------------------------------
   Static configuration values for the example page.
   Prefix: ex
   ============================================================================ */

/* Engine processes this page cares about, mapped to engine card slugs. */
const ex_ENGINE_PROCESSES = {
    'Collect-ExampleStatus': { slug: 'example' }
};

/* Default polling interval in seconds; overridden by GlobalConfig on load. */
const ex_DEFAULT_REFRESH_INTERVAL = 10;


/* ============================================================================
   STATE: PAGE STATE
   ----------------------------------------------------------------------------
   Mutable values that track the page's current display state.
   Prefix: ex
   ============================================================================ */

/* Currently selected agent filter; ALL or a specific agent ID. */
var ex_currentFilter = 'ALL';

/* Live polling timer handle, or null if polling is stopped. */
var ex_livePollingTimer = null;


/* ============================================================================
   INITIALIZATION: PAGE BOOT
   ----------------------------------------------------------------------------
   DOMContentLoaded handler and one-time setup. Runs once on page load.
   Prefix: (none)
   ============================================================================ */

document.addEventListener('DOMContentLoaded', async function() {
    await ex_loadConfig();
    ex_refreshAll();
    connectEngineEvents();
});


/* ============================================================================
   FUNCTIONS: DATA LOADING
   ----------------------------------------------------------------------------
   Fetchers for agent data, threshold configuration, and event log entries.
   Prefix: ex
   ============================================================================ */

/* Loads page configuration from GlobalConfig via the shared fetch wrapper. */
async function ex_loadConfig() {
    const data = await engineFetch('/api/config/refresh-interval?page=example');
    if (data && data.interval) {
        ex_currentFilter = data.interval;
    }
}

/* Loads the current set of example agents and refreshes the display. */
function ex_refreshAll() {
    ex_loadAgents();
}

/* Loads agent records and dispatches them to the renderer. */
function ex_loadAgents() {
    engineFetch('/api/example/agents')
        .then(function(data) {
            if (data) ex_renderAgents(data);
        });
}


/* ============================================================================
   FUNCTIONS: RENDERING
   ----------------------------------------------------------------------------
   DOM construction for agent cards and status badges.
   Prefix: ex
   ============================================================================ */

/* Renders the agent cards into the page's agent container. */
function ex_renderAgents(agents) {
    const container = document.getElementById('agent-cards');
    container.innerHTML = agents.map(ex_buildAgentCard).join('');
}

/* Builds the HTML for a single agent card. */
function ex_buildAgentCard(agent) {
    return '<div class="ex-agent-card">' +
           '<span class="ex-agent-name">' + escapeHtml(agent.name) + '</span>' +
           '</div>';
}


/* ============================================================================
   FUNCTIONS: PAGE LIFECYCLE HOOKS
   ----------------------------------------------------------------------------
   Callbacks consumed by cc-shared.js. These names form an API contract
   with the shared module - do not rename.
   Prefix: (none)
   ============================================================================ */

/* Manual refresh handler - re-fetches all sections. */
function onPageRefresh() {
    ex_refreshAll();
}

/* Tab regained visibility - refresh live data. */
function onPageResumed() {
    ex_refreshAll();
}
```

This file produces the following catalog rows when parsed:

- 1 x `FILE_HEADER DEFINITION`
- 6 x `COMMENT_BANNER DEFINITION` (one per section)
- 1 x `JS_CONSTANT_VARIANT DEFINITION` (`ex_ENGINE_PROCESSES`, variant_type='object')
- 1 x `JS_CONSTANT DEFINITION` (`ex_DEFAULT_REFRESH_INTERVAL`)
- 2 x `JS_STATE DEFINITION` (`ex_currentFilter`, `ex_livePollingTimer`)
- 1 x `JS_FUNCTION_VARIANT DEFINITION` (`ex_loadConfig`, variant_type='async')
- 4 x `JS_FUNCTION DEFINITION` (`ex_refreshAll`, `ex_loadAgents`, `ex_renderAgents`, `ex_buildAgentCard`)
- 2 x `JS_HOOK DEFINITION` (`onPageRefresh`, `onPageResumed`)
- Multiple `JS_FUNCTION USAGE` rows for shared-module calls (`engineFetch`, `escapeHtml`, `connectEngineEvents`) and same-file calls
- Multiple `CSS_CLASS USAGE` rows for class names in template strings (`ex-agent-card`, `ex-agent-name`)
- 1 x `HTML_ID USAGE` (`agent-cards` from `getElementById`)

Zero drift rows expected.

### 20.2 Function definition forms

Permitted:

```javascript
function bsv_loadAgents() { ... }
async function bsv_loadConfig() { ... }
function* bsv_iterRange(start, end) { ... }
```

Forbidden:

```javascript
const bsv_loadAgents = function() { ... };       // FORBIDDEN_ANONYMOUS_FUNCTION
const bsv_loadAgents = () => { ... };            // FORBIDDEN_ANONYMOUS_FUNCTION
const bsv_loadAgents = function namedThing() { ... };  // FORBIDDEN_ANONYMOUS_FUNCTION
```

### 20.3 Constants and state

```javascript
/* Default polling interval in seconds; overridden by GlobalConfig on page load. */
const bsv_DEFAULT_REFRESH_INTERVAL = 10;

/* Currently selected agent filter; ALL or a specific agent ID. */
var bsv_currentFilter = 'ALL';
```

### 20.4 Function with JSDoc parameter and return documentation

```javascript
/**
 * Calculates the countdown to the next scheduled execution.
 *
 * @param {Object} event - PROCESS_COMPLETED event with intervalSeconds, scheduledTime, runMode, status
 * @param {number} now - Current time in ms (Date.now())
 * @returns {number|null} Countdown in seconds, or null if no countdown applies
 */
function calcCountdownFromEvent(event, now) { ... }
```

### 20.5 Class with methods

```javascript
/* Renders an agent status card and manages its update lifecycle. */
class bsv_AgentCard {

    /* Constructor - takes the agent record and the container element. */
    constructor(agent, container) { ... }

    /* Renders the current state of the card to the DOM. */
    render() { ... }

    /* Updates the card's pending-command count display. */
    updatePending(count) { ... }
}
```

---

## Appendix - Rationale

This appendix explains why selected rules are what they are. Entries are keyed to body section numbers. Sections without entries here have no rationale beyond the rule itself.

### A.1 Required structure

The strict three-part structure (header, sections, end-of-file) is what lets the parser walk a file deterministically: the parse position is always either reading the header, reading inside a section, or done.

### A.2 File header

The header is mandated as a single block comment rather than line comments because the parser receives it as a single `Block` comment AST node. Detection is trivially "is the first node of the source a block comment in the right shape," with no need to coalesce a run of consecutive line comments.

CHANGELOG blocks are forbidden because git is the source of truth for change history. CHANGELOG blocks duplicate what git already provides and create drift between the two records.

The FILE ORGANIZATION list must match the body banners verbatim because verbatim matching makes the list a real table of contents - a reader sees the section titles in the list and can navigate to them by exact-string search.

### A.4 Section types

`FOUNDATION` and `CHROME` exist as distinct types in `cc-shared.js` (rather than reusing `CONSTANTS` and `FUNCTIONS`) because the names signal which ownership model applies. Page files declare local `CONSTANTS` and `STATE` and put their boot code in `INITIALIZATION` and `FUNCTIONS`. The shared file declares platform-wide `FOUNDATION` (immutable) and `STATE` (mutable) and puts its worker code in `CHROME`. The two file kinds use disjoint type vocabularies so a reader can tell which kind of file they're reading by glancing at any banner.

The fixed type-order rule reflects a real cascade dependency: imports must come before anything that consumes them; foundation primitives and state must be declared before chrome (in `cc-shared.js`) or before initialization (in page files) references them; the initialization sequence wires up the page before any function it calls can be invoked; and functions sit at the bottom because they are the body of work the rest of the file orchestrates.

`FOUNDATION` and `CHROME` are limited to one source file because single-source ownership is what makes them genuinely shared. If multiple files defined `FOUNDATION` content, "the canonical month names array" would not have a single home.

### A.5 Prefixes

The page prefix is what makes function names globally identifiable across the platform's JS namespace. Reading `bsv_loadActivity()` anywhere in the codebase instantly tells the reader where the function lives: `business-services.js`. There is no ambiguity, no cross-file grep needed.

The same discipline applies to `cc-shared.js` exports in inverse: any unprefixed identifier in a Control Center JS file is, by spec, a `cc-shared.js` import. The reader does not have to ask where `escapeHtml` comes from; the lack of a prefix is the answer.

The separator after the prefix is an underscore because JS identifiers do not allow hyphens. CSS uses a hyphen because CSS class names allow hyphens. The two-language separator difference is the only divergence; the prefix itself is identical between the page's CSS file and JS file.

### A.6 Function definitions

The single-form rule (`function name() {}` only) exists for uniformity: the spec picks one form and forbids the others so the catalog never has to ask "which way of writing a function did the developer pick this time?"

Async and generator functions are not forbidden because they are real semantic distinctions that the catalog records as variants. The base `JS_FUNCTION` type covers plain (sync, non-generator) function declarations; async and generator forms are `JS_FUNCTION_VARIANT` rows.

### A.7 Constants and state

The `WRONG_DECLARATION_KEYWORD` rule (forbidding `var` in `CONSTANTS` or `FOUNDATION` sections, or `const` in `STATE` sections) makes the section type and the keyword line up so a reader scanning either signal arrives at the same conclusion about whether a value is mutable.

`let` is forbidden because the codebase uses `var` everywhere; `let` introduces a third concept without a corresponding cataloging distinction.

The one-declaration-per-statement rule guarantees one declaration per `VariableDeclarator` in the AST and makes per-declaration comment requirements unambiguous - the comment must precede a single declaration, not a multi-declaration list.

### A.8 Page lifecycle hooks

Hooks get their own component type (`JS_HOOK` rather than `JS_FUNCTION`) because the role is different - these are API-contract callbacks consumed by the shared module. Giving them their own component type means a query like `SELECT file_name, component_name FROM Asset_Registry WHERE component_type IN ('JS_HOOK', 'JS_HOOK_VARIANT')` becomes a one-line answer to "which pages implement which hooks."

The hooks banner must be last because hooks call functions defined elsewhere in the file. Placing them at the bottom puts the consumer below the producers - same cascade dependency reason that drives the section type ordering.

### A.10 Imports

The current platform loads JS via `<script>` tags and shares a global namespace, so files have no IMPORTS banner today. The spec defines `IMPORTS` for forward compatibility against a future migration to ES modules.

### A.14 Forbidden patterns

Some forbidden patterns ride on the row of an existing declaration (e.g., `FORBIDDEN_LET` attaches to the row for the `let`-declared variable). Others have no natural declaration to host the drift, so the parser emits a dedicated row at the violation site using a component_type that exists solely to represent the forbidden pattern (e.g., `JS_IIFE`, `JS_EVAL`). Either way, every violation is visible in the row set with no aggregation needed.

The `FORBIDDEN_ANONYMOUS_FUNCTION` carve-out for callback arguments exists because requiring a named function for every `.then` or `.forEach` callback would force every page to invent dozens of trivial names whose only purpose is to be passed once and never referenced again. The catalog gains nothing from naming these; the surrounding call site already identifies what the callback is for.

### A.16 Catalog model

Forbidden patterns produce rows just like permitted ones because the catalog is meant to represent everything the parser found in the file. Cataloging only compliant constructs would hide violations from queries.

The `_VARIANT` companion-type pattern (e.g., `JS_FUNCTION` / `JS_FUNCTION_VARIANT`) is used where there is a clear base case and the variants are alternative ways of expressing semantically-distinct constructs. Where every instance is inherently a variant with no natural base (e.g., `JS_TIMER` is always an interval or a timeout), a single component type is used and `variant_type` is always non-NULL.

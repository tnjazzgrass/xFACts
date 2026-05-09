# Control Center JavaScript File Format Specification

*These rules are the current authority for Control Center JavaScript files. They are settled until explicitly amended; any proposed change is discussed before adoption. Where rationale exists for a rule, it appears in the Appendix at the corresponding section number.*

*Specs describe rules and shapes — never present contents. Statements about how many files currently do something, which files are empty today, or what the codebase looks like right now do not belong in this document; they age into inaccuracy the moment the codebase changes. If census-style information is needed, it lives in queries against `dbo.Asset_Registry`, not here.*

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

The opening and closing rule lines are exactly 76 `=` characters. The inner separator is exactly 76 `-` characters.

### 3.1 Banner format rules

- The opening and closing `=` rule lines each consist of exactly 76 `=` characters.
- The middle `-` rule line is exactly 76 `-` characters and separates the title line from the description block.
- `<TYPE>` must be one of the recognized section types (Section 4). The TYPE token is uppercase letters and underscores only.
- `<NAME>` is human-readable and may contain spaces, commas, and other punctuation.
- The description block is 1-5 sentences explaining what the section contains. Required.
- The `Prefix:` line declares the page prefix that scopes identifiers in this section (Section 5). Required, singular.

### 3.2 Banner authoring discipline

When adding new content to a file, prefer creating a new banner over expanding an existing one if the new content is a distinct concept. See Section 14 for the full rule on sub-section markers vs. new banners.

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

## 5. Prefix

Every section banner declares a single page prefix via the `Prefix:` line. Every top-level identifier (function name, constant name, state variable name) defined in that section must begin with the declared prefix followed by an underscore. Drift code: `PREFIX_MISMATCH`.

### 5.1 Prefix selection rules

The page prefix is a 3-character lowercase identifier and is the same prefix used by the page's CSS file. The separator after the prefix is an underscore (`_`), not a hyphen.

### 5.2 Special values

- `Prefix: (none)` - sentinel value. Declares the section has no page-prefix scoping. Used by:
  - All sections in `cc-shared.js`.
  - The page lifecycle hooks banner in any page file.
  - The `IMPORTS` and `INITIALIZATION` sections of any file.
  - The `CONSTANTS: ENGINE PROCESSES` banner in any page file (§7.4).

The `Prefix:` line itself is mandatory regardless of value. Drift code if absent: `MISSING_PREFIX_DECLARATION`.

### 5.3 Single prefix per banner

Each banner declares exactly one prefix or `(none)`. Multiple comma-separated prefixes are not permitted. A file represents one CC page (or the shared resource), and that page has a single registered prefix; every page-prefixed section in the file uses that same prefix. Drift code if a banner declares anything other than a single 3-character prefix or `(none)`: `MALFORMED_PREFIX_VALUE`.

### 5.4 Registry validation

Each page's prefix is registered in `dbo.Component_Registry.cc_prefix` for the component that owns the page's JS file. The parser cross-references each banner's declared prefix against the registry and emits drift on disagreement.

- If a file's component has `cc_prefix = NULL` (a shared or infrastructure component, e.g., `ControlCenter.Shared`), every section banner in the file must declare `Prefix: (none)`. A non-`(none)` declaration emits `PREFIX_REGISTRY_MISMATCH` on the banner row.
- If a file's component has `cc_prefix = X` (e.g., `bkp` for `ServerOps.Backup`), every page-prefixed section banner must declare `Prefix: X`. Sections that legitimately use `(none)` (the hooks banner, IMPORTS, INITIALIZATION) are exempt from this check. A section whose banner declares a different prefix value emits `PREFIX_REGISTRY_MISMATCH` on the banner row.
- Top-level identifiers (function names, top-level constants, top-level state variables, top-level classes, and revealing-module wrappers) must begin with the file's registered `cc_prefix` followed by an underscore. This rule applies independently of banners. Hooks and methods inside classes are exempt. Drift code: `PREFIX_MISSING`.
- The registry is the source of truth. When a declared prefix and the registry disagree, the file is wrong and the file is updated.

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

The narrow exception is callback arguments to other calls; see Section 15.1.

### 6.1 Function comment requirement

Every function definition must be preceded by a single block comment immediately above the declaration. The comment is at minimum a single-sentence purpose. JSDoc-format parameter and return documentation is allowed and encouraged but not mandatory. Drift code: `MISSING_FUNCTION_COMMENT`.

### 6.2 Function naming rules

- Top-level function names in a page file must begin with the page prefix followed by an underscore (Section 5).
- Functions in the page lifecycle hooks banner (Section 8) use the fixed hook names instead.
- Functions in `cc-shared.js` are not page-prefixed; their `Prefix:` line is `(none)`.

### 6.3 Async and generator functions

`async` and `generator` functions are permitted forms of `function` declarations and are catalog-distinguished as `JS_FUNCTION_VARIANT` rows with `variant_type='async'` or `variant_type='generator'` (Section 17.5).

---

## 7. Constants and state

Module-scope declarations split into two kinds based on the section they live in:

- **`CONSTANTS` and `FOUNDATION` sections**: declarations are `const`. Primitive values produce `JS_CONSTANT DEFINITION` rows; compound values (objects, arrays, regexes, computed expressions) produce `JS_CONSTANT_VARIANT DEFINITION` rows. See Section 17.5.
- **`STATE` sections**: declarations are `var`. They produce `JS_STATE DEFINITION` rows.

Drift code if `var` appears in a `CONSTANTS` or `FOUNDATION` section, or `const` in a `STATE` section: `WRONG_DECLARATION_KEYWORD`.

`let` is forbidden anywhere in the codebase. Drift code: `FORBIDDEN_LET`.

### 7.1 Comment requirement

Every constant and state declaration must be preceded by a single-line block comment describing its purpose. Drift codes: `MISSING_CONSTANT_COMMENT` (constants), `MISSING_STATE_COMMENT` (state variables).

### 7.2 Naming conventions
- **Constants holding fixed configuration values written as primitive literals** (numbers, strings, booleans): SCREAMING_SNAKE_CASE.
- **Constants holding objects, arrays, or computed values**: camelCase.
- **State variables**: camelCase.
- All identifiers must carry the page prefix (except in the anchor file `cc-shared.js`, which uses `Prefix: (none)`).
The case-distinction rule is conventional, not parser-enforced.

### 7.3 Multiple declarations per statement

`var a, b, c;` and `const a = 1, b = 2;` are forbidden. Each declaration gets its own statement. Drift code: `FORBIDDEN_MULTI_DECLARATION`.

### 7.4 Engine processes contract banner

The `ENGINE_PROCESSES` constant is a name contract with `cc-shared.js`: the identifier is read by exact name and cannot carry a page prefix. Pages that call `connectEngineEvents()` declare it in a fixed-form `CONSTANTS` banner with the name `ENGINE PROCESSES` and `Prefix: (none)`. The value is `{}` when the page has no collectors; the banner is still present.

When the banner exists, it precedes any page-prefixed `CONSTANTS` banner.

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

If any hooks are defined, they live in a `FUNCTIONS` banner with the fixed name `PAGE LIFECYCLE HOOKS`. The banner declares `Prefix: (none)`. See Section 21 for an example.

### 8.2 Banner placement rule

If the `FUNCTIONS: PAGE LIFECYCLE HOOKS` banner exists, it must be the last banner in the file. Drift code: `HOOKS_BANNER_NOT_LAST`.

### 8.3 Catalog representation

Functions inside the hooks banner produce `JS_HOOK DEFINITION` rows (or `JS_HOOK_VARIANT DEFINITION` for async hooks; see Section 17.5), not `JS_FUNCTION DEFINITION` rows. The function comment requirement still applies.

### 8.4 Hook naming

Hook names are the API contract with `cc-shared.js`. They cannot be renamed. The hooks banner declares `Prefix: (none)` so functions inside the banner do not trigger `PREFIX_MISMATCH` or `PREFIX_MISSING`. A function inside the banner whose name is not in the recognized set emits `UNKNOWN_HOOK_NAME`.

---

## 9. Classes and methods

JS classes are not currently used in any Control Center page file but are covered for forward compatibility.

### 9.1 Class declarations

Class declarations live at module scope inside a `FUNCTIONS` section and produce a `JS_CLASS DEFINITION` row. Class names follow the same prefix rule as functions. A class declaration must be preceded by a single-sentence purpose comment. Drift code: `MISSING_CLASS_COMMENT`.

### 9.2 Methods

Methods inside a class body produce `JS_METHOD DEFINITION` rows for regular methods, or `JS_METHOD_VARIANT DEFINITION` for static/getter/setter/async forms (Section 17.5). Each method must carry a preceding single-sentence purpose comment. Drift code: `MISSING_METHOD_COMMENT`.

Methods do not carry the page prefix; they are namespaced inside the class itself.

---

## 10. Imports

`IMPORTS` sections contain ES module `import` statements or Node `require` calls. If a file has no imports, the IMPORTS banner is omitted entirely, along with its corresponding FILE ORGANIZATION entry.

Each import produces a `JS_IMPORT DEFINITION` row keyed on the imported binding name. The source module path lives in `variant_qualifier_2`. See Section 17.5 for the variant grid.

---

## 11. Initialization

The `INITIALIZATION` section contains:

1. The `document.addEventListener('DOMContentLoaded', ...)` handler that runs page setup
2. Any one-time setup functions called only from that handler

Functions in this section may invoke functions from any later section. Functions in `FUNCTIONS` may not depend on initialization having run beyond the constants and state being populated.

The `DOMContentLoaded` handler itself is anonymous and is registered via `addEventListener`. It does not produce a `JS_FUNCTION DEFINITION` row; the parser treats it as initialization code, not a named definition. This is one of the allowed-callback contexts described in Section 15.1.

---

## 12. Event handler binding

Event handlers are attached via `addEventListener`. The canonical form is event delegation.

### 12.1 Delegation pattern

A delegation binding has three parts:

1. A stable parent — an element that exists in the page's static markup or is rendered exactly once and not replaced.
2. A single `addEventListener` call on that parent, registered during page boot inside the `INITIALIZATION` section.
3. A handler function that dispatches by examining `event.target` via `event.target.matches(selector)` or `event.target.closest(selector)`.

Per-row context (record IDs, group IDs, tracking IDs, etc.) is carried on rendered elements via `data-*` attributes and read by the handler via `event.target.dataset.<name>` or `event.target.closest('.<row-class>').dataset.<name>`.

### 12.2 Permitted direct-binding cases

Direct binding is permitted in exactly these cases:

1. **Singleton elements bound at page boot.** An element that exists exactly once on the page and is not subject to re-rendering, bound during the `DOMContentLoaded` handler in `INITIALIZATION`.
2. **Window-level and document-level events.** Events bound on `window` or `document`.

Any binding case that fits neither §12.1 nor §12.2 is evaluated as a spec amendment, not as a per-file authoring choice.

---

## 13. Comments

Comments serve four roles, and only four:

1. **File header** - a single block comment at line 1 (Section 2).
2. **Section banners** - multi-line block comments enclosing a section's title, description, and prefix declaration (Section 3).
3. **Purpose comments** - single block comment immediately preceding a function, class, method, constant, state variable, or hook.
4. **Sub-section markers** - inline block comment between definitions in a section, used as a lightweight visual divider. Format: `/* -- label -- */`. Optional.

No other comment forms are recognized. Stray block comments at file scope are a parse error.

### 13.1 Inline comments

Inline `//` line comments are permitted inside function bodies for explaining specific lines or blocks of logic. They are not cataloged.

Inline `//` line comments are forbidden at file scope. Each file-scope `//` comment emits a `JS_LINE_COMMENT` row at its own line with `FORBIDDEN_FILE_SCOPE_LINE_COMMENT` drift attached.

### 13.2 Comment content rules

- Purpose comments are written in present-tense, descriptive style. They describe what the function/constant/state does, not why it does it.
- Section banner descriptions may be 1-5 sentences. They explain what the section contains.

---

## 14. Sub-section markers vs. new banners

When a section's content grows, two structural tools are available: sub-section markers (lightweight visual dividers within a single banner) and new banners of the same type.

### 14.1 Use a new banner when

- The new content is a distinct concept with its own purpose
- The new content has its own audience or readership context
- A reader scanning the file's FILE ORGANIZATION list would benefit from seeing the new content as a top-level entry

A new banner gets its own row in the FILE ORGANIZATION list.

### 14.2 Use a sub-section marker when

- The new content is a sub-component of an existing concept
- Grouping is for visual reading aid only, not a structural distinction

Sub-section markers use the inline format `/* -- <label> -- */`. They are decorative; the parser ignores them. They do not appear in the FILE ORGANIZATION list and do not nest.

---

## 15. Forbidden patterns

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
| Per-element `addEventListener` call inside a loop on rendered list/grid content | `FORBIDDEN_PER_ELEMENT_LISTENER_LOOP` | The JS_EVENT row |
| IIFE at file scope (`(function() { ... })()`) | `FORBIDDEN_IIFE` | A `JS_IIFE` row at the violation line |
| Top-level `const X = (function(){...})()` or `var X = (function(){...})()` (revealing-module IIFE) | `FORBIDDEN_REVEALING_MODULE` | The const/var declaration row |
| `eval(...)` | `FORBIDDEN_EVAL` | A `JS_EVAL` row at the violation line |
| `document.write(...)` | `FORBIDDEN_DOCUMENT_WRITE` | A `JS_DOCUMENT_WRITE` row at the violation line |
| `window.<name> = ...` outside `cc-shared.js` | `FORBIDDEN_WINDOW_ASSIGNMENT` | A `JS_WINDOW_ASSIGNMENT` row at the violation line |
| Inline `<style>` content in a template literal or string literal | `FORBIDDEN_INLINE_STYLE_IN_JS` | A `JS_INLINE_STYLE` row at the violation line |
| Inline `<script>` content in a template literal or string literal | `FORBIDDEN_INLINE_SCRIPT_IN_JS` | A `JS_INLINE_SCRIPT` row at the violation line |
| Inline `on<event>="..."` attribute in a template literal or string literal | `FORBIDDEN_INLINE_EVENT_IN_JS` | A `JS_INLINE_EVENT` row at the violation line |
| File-scope `//` line comment | `FORBIDDEN_FILE_SCOPE_LINE_COMMENT` | A `JS_LINE_COMMENT` row at the violation line |
| CHANGELOG block in file header | `FORBIDDEN_CHANGELOG_BLOCK` | The FILE_HEADER row |

### 15.1 Allowed anonymous callback contexts

A function or arrow expression passed as an argument to another call may be anonymous. This covers patterns like `addEventListener` callbacks, `.forEach` / `.map` callbacks, `.then` callbacks, and `setTimeout` / `setInterval` callbacks.

The parser walks into the anonymous body normally, so any function calls, class usage, or HTML markup inside the callback still produce rows. The `parent_function` column on those rows records the name of the outer call.

No other carve-outs. Anonymous functions assigned to a const or var, returned from another function, or used as object property values are all `FORBIDDEN_ANONYMOUS_FUNCTION` violations.

### 15.2 Forbidden wrapper patterns

Two top-level wrapper patterns are forbidden:

- **Top-level IIFE** — `(function() { ... })();` or `(() => { ... })();` as a standalone statement. Drift code: `FORBIDDEN_IIFE`. Row host: `JS_IIFE`.
- **Revealing-module IIFE** — `const X = (function() { ... })();`, `var X = (function() { ... })();`, or arrow equivalents. Drift code: `FORBIDDEN_REVEALING_MODULE`. Row host: the const/var declaration row (`JS_CONSTANT_VARIANT` or `JS_STATE`).

Both patterns require a full file rewrite, not in-place repair.

---

## 16. Required patterns summary

Every JS file must:

1. Open with a spec-compliant file header (Section 2).
2. Define all sections under recognized section types in declared order (Sections 3, 4).
3. Declare a valid prefix in every section banner (Section 5).
4. Precede every function, constant, state variable, hook, class, and method with a single block comment (Sections 6, 7, 8, 9, 13).
5. Use `const` in CONSTANTS sections and `var` in STATE sections (Section 7).
6. Define functions only as `function name() {}` declarations (Section 6).
7. Bind events only via `addEventListener`, with delegation as the canonical pattern and the carve-outs in Section 12.2 as the only direct-binding cases permitted (Section 12).
8. Place page lifecycle hooks in a `FUNCTIONS: PAGE LIFECYCLE HOOKS` banner that is last in the file (Section 8).
9. Use one declaration per statement (Section 7.3).
10. Use the page prefix on every top-level identifier in a page file, except hooks (Section 5).
11. Use unprefixed identifiers in `cc-shared.js`, with `Prefix: (none)` declared (Sections 4.2, 5.2).
12. Match the FILE ORGANIZATION list to banner titles verbatim, in order (Section 2).

---

## 17. Catalog model

This section covers the catalog mechanism as it relates to JS files. Every cataloged JS construct gets one row in `dbo.Asset_Registry`.

### 17.1 What the catalog represents

The catalog represents everything the parser found in the file, with drift codes telling the operator what's wrong. Forbidden patterns produce rows just like permitted ones; the difference is the drift codes attached. A clean codebase has zero rows with non-NULL `drift_codes`.

A row's identity is the combination of `component_type`, `component_name`, `reference_type`, `file_name`, `occurrence_index`, `variant_type`, `variant_qualifier_1`, and `variant_qualifier_2`.

### 17.2 JS-relevant component_type values

| component_type | Meaning |
|---|---|
| `FILE_HEADER` | The file's header block. One row per scanned file. |
| `COMMENT_BANNER` | A section banner comment. One row per section. The section type lives in `signature`. |
| `JS_IMPORT` | An ES `import` statement or Node `require` call. The imported binding name is `component_name`. The source module path is `variant_qualifier_2`. Always non-NULL `variant_type`. |
| `JS_CONSTANT` | A `const` declaration of a primitive value in a `CONSTANTS` or `FOUNDATION` section. |
| `JS_CONSTANT_VARIANT` | A `const` declaration of a compound or computed value in a `CONSTANTS` or `FOUNDATION` section. Also the row host for revealing-module wrappers (Section 15.2). |
| `JS_STATE` | A `var` declaration in a `STATE` section. No variants. Also the row host for revealing-module wrappers using `var` (Section 15.2). |
| `JS_FUNCTION` | A regular `function name() {}` declaration. |
| `JS_FUNCTION_VARIANT` | An `async function name()` or `function* name()` (generator) declaration. |
| `JS_HOOK` | A regular sync function inside the `FUNCTIONS: PAGE LIFECYCLE HOOKS` banner. |
| `JS_HOOK_VARIANT` | An async function inside the hooks banner. |
| `JS_CLASS` | A class declaration at module scope. No variants. |
| `JS_METHOD` | A regular method defined inside a class body. The class name lives in `parent_function`. |
| `JS_METHOD_VARIANT` | A static method, getter, setter, or async method inside a class body. |
| `JS_TIMER` | A `setInterval` or `setTimeout` call assigned to a tracked handle. The handle name is `component_name`. Always non-NULL `variant_type`. |
| `JS_EVENT` | An `addEventListener` event handler binding. The event name is `component_name`. No variants. Hosts `FORBIDDEN_PROPERTY_ASSIGN_EVENT` drift on element-property assignments and `FORBIDDEN_PER_ELEMENT_LISTENER_LOOP` drift on per-element listener loops. |
| `JS_IIFE` | An IIFE at file scope. Exists solely to host `FORBIDDEN_IIFE` drift. |
| `JS_EVAL` | An `eval(...)` call. Exists solely to host `FORBIDDEN_EVAL` drift. |
| `JS_DOCUMENT_WRITE` | A `document.write(...)` call. Exists solely to host `FORBIDDEN_DOCUMENT_WRITE` drift. |
| `JS_WINDOW_ASSIGNMENT` | A `window.<name> = ...` assignment outside `cc-shared.js`. Exists solely to host `FORBIDDEN_WINDOW_ASSIGNMENT` drift. |
| `JS_INLINE_STYLE` | A `<style>` element found in a JS template/string literal. Exists solely to host `FORBIDDEN_INLINE_STYLE_IN_JS` drift. |
| `JS_INLINE_SCRIPT` | A `<script>` element found in a JS template/string literal. Exists solely to host `FORBIDDEN_INLINE_SCRIPT_IN_JS` drift. |
| `JS_INLINE_EVENT` | An inline `on<event>="..."` attribute found in a JS template literal or string literal. Exists solely to host `FORBIDDEN_INLINE_EVENT_IN_JS` drift. |
| `JS_LINE_COMMENT` | A `//` line comment at file scope. Exists solely to host `FORBIDDEN_FILE_SCOPE_LINE_COMMENT` drift. |
| `CSS_CLASS` | A class name found inside a template literal, string literal, `classList.*` call, `className` assignment, or `setAttribute('class', ...)` call. Always `USAGE`. |
| `HTML_ID` | An `id="..."` attribute (DEFINITION) or a literal-string argument to `getElementById` / `querySelector('#...')` (USAGE). |

### 17.3 Scope determination

- DEFINITION rows in `cc-shared.js`: scope is `SHARED`.
- DEFINITION rows in any page file: scope is `LOCAL`.
- USAGE rows of functions: `SHARED` if the called function is defined in `cc-shared.js`; `LOCAL` if defined in the same page file. Calls to uncataloged identifiers do not produce rows.
- CSS_CLASS USAGE rows: resolved against existing CSS_CLASS DEFINITION rows in the consumer's zone.
- HTML_ID rows: always `LOCAL`.
- Forbidden-pattern rows: scope follows the file's overall scope. The drift code is the action item; the scope value is informational.

### 17.4 Drift recording

The parser evaluates every row against the spec and records two things when the row deviates:

- `drift_codes` - comma-separated list of stable short codes
- `drift_text` - joined human-readable descriptions corresponding to each code

A row may carry zero, one, or many drift codes. Both columns are NULL when the row is fully spec-compliant.

The full code-to-description mapping for JS appears in Section 19.

### 17.5 Variant model

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
| `JS_CONSTANT_VARIANT` | `expression` | NULL | NULL | Value computed from a function call or expression. Includes the revealing-module wrapper case (Section 15.2). |

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

## 18. What the parser extracts

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
| `JS_EVENT USAGE` | Each `addEventListener('event', ...)` call | `component_name` = event name. Hosts `FORBIDDEN_PROPERTY_ASSIGN_EVENT` drift on element-property assignments and `FORBIDDEN_PER_ELEMENT_LISTENER_LOOP` drift on per-element listener loops. |
| `CSS_CLASS USAGE` | Each class name in a template literal, classList call, or setAttribute('class', ...) | Resolved to SHARED or LOCAL via the CSS_CLASS DEFINITION map. |
| `HTML_ID DEFINITION` | Each `id="..."` in a template/string literal or `setAttribute('id', ...)` or `el.id = '...'` | LOCAL scope. |
| `HTML_ID USAGE` | Each `getElementById('...')` or `querySelector('#...')` argument | LOCAL scope. |
| `JS_IIFE DEFINITION` | Each IIFE at file scope | Always `FORBIDDEN_IIFE` drift. |
| `JS_EVAL USAGE` | Each `eval(...)` call | Always `FORBIDDEN_EVAL` drift. |
| `JS_DOCUMENT_WRITE USAGE` | Each `document.write(...)` call | Always `FORBIDDEN_DOCUMENT_WRITE` drift. |
| `JS_WINDOW_ASSIGNMENT DEFINITION` | Each `window.<name> = ...` assignment outside `cc-shared.js` | Always `FORBIDDEN_WINDOW_ASSIGNMENT` drift. |
| `JS_INLINE_STYLE DEFINITION` | Each `<style>` tag in a JS template/string literal | Always `FORBIDDEN_INLINE_STYLE_IN_JS` drift. |
| `JS_INLINE_SCRIPT DEFINITION` | Each `<script>` tag in a JS template/string literal | Always `FORBIDDEN_INLINE_SCRIPT_IN_JS` drift. |
| `JS_INLINE_EVENT DEFINITION` | Each inline `on<event>="..."` attribute in a JS template/string literal | Always `FORBIDDEN_INLINE_EVENT_IN_JS` drift. |
| `JS_LINE_COMMENT DEFINITION` | Each `//` line comment at file scope | Always `FORBIDDEN_FILE_SCOPE_LINE_COMMENT` drift. |

---

## 19. Drift codes reference

### 19.1 File-level codes

| Code | Description |
|---|---|
| `MALFORMED_FILE_HEADER` | The file's header block is missing, malformed, or contains required fields out of order. |
| `FORBIDDEN_CHANGELOG_BLOCK` | The file header contains a CHANGELOG block. |
| `FILE_ORG_MISMATCH` | The FILE ORGANIZATION list in the header does not exactly match the section banner titles in the file body. |

### 19.2 Section-level codes

The banner format defined in Section 3 is enforced via granular drift codes — each format violation produces its own code so refactor work can be triaged precisely. A non-conformant banner produces a `COMMENT_BANNER` row carrying drift codes that describe every way the banner deviates from §3.1.

| Code | Description |
|---|---|
| `MISSING_SECTION_BANNER` | A definition appears outside any banner. |
| `BANNER_INLINE_SHAPE` | A banner uses the inline single-line form (`/* ===== Title ===== */`). The canonical form is multi-line with rule lines, title line, separator, description block, and `Prefix:` line. |
| `BANNER_INVALID_RULE_CHAR` | A banner's opening or closing bracketing line is not composed entirely of `=` characters. |
| `BANNER_INVALID_RULE_LENGTH` | A banner's opening or closing `=` rule line is not exactly 76 characters long. |
| `BANNER_INVALID_SEPARATOR_CHAR` | A banner's middle separator line is missing or is not composed entirely of `-` characters. |
| `BANNER_INVALID_SEPARATOR_LENGTH` | A banner's middle separator line is not exactly 76 `-` characters long. |
| `BANNER_MALFORMED_TITLE_LINE` | A banner's title line does not parse as `<TYPE>: <NAME>`. |
| `BANNER_MISSING_DESCRIPTION` | A banner has no description text between the separator line and the `Prefix:` line. |
| `UNKNOWN_SECTION_TYPE` | A section banner declares a TYPE not in the enumerated list for the file kind. Page files allow IMPORTS, CONSTANTS, STATE, INITIALIZATION, FUNCTIONS. cc-shared.js allows IMPORTS, FOUNDATION, STATE, CHROME. |
| `SECTION_TYPE_ORDER_VIOLATION` | Section types appear out of the required order. |
| `MISSING_PREFIX_DECLARATION` | A section banner is missing the mandatory `Prefix:` line. |
| `MALFORMED_PREFIX_VALUE` | A section banner's `Prefix:` line declares anything other than a single 3-character prefix or `(none)`. |
| `PREFIX_REGISTRY_MISMATCH` | A section banner's declared prefix does not match `Component_Registry.cc_prefix` for the file's component. |
| `DUPLICATE_FOUNDATION` | A FOUNDATION section appears in a JS file other than `cc-shared.js`. |
| `DUPLICATE_CHROME` | A CHROME section appears in a JS file other than `cc-shared.js`. |
| `HOOKS_BANNER_NOT_LAST` | A `FUNCTIONS: PAGE LIFECYCLE HOOKS` banner exists but is not the last banner in the file. |

### 19.3 Definition-level codes

| Code | Description |
|---|---|
| `PREFIX_MISMATCH` | A top-level identifier name does not begin with the prefix declared in its containing section's banner. |
| `PREFIX_MISSING` | A top-level identifier does not begin with the file's registered `Component_Registry.cc_prefix` followed by an underscore. Independent of banners. Hooks and methods inside classes are exempt. |
| `MISSING_FUNCTION_COMMENT` | A function definition is not preceded by a single block comment. |
| `MISSING_CONSTANT_COMMENT` | A `const` declaration in a CONSTANTS section is not preceded by a single block comment. |
| `MISSING_STATE_COMMENT` | A `var` declaration in a STATE section is not preceded by a single block comment. |
| `MISSING_CLASS_COMMENT` | A class declaration is not preceded by a single block comment. |
| `MISSING_METHOD_COMMENT` | A method inside a class body is not preceded by a single block comment. |
| `WRONG_DECLARATION_KEYWORD` | A `var` declaration appears in a CONSTANTS or FOUNDATION section, or a `const` declaration appears in a STATE section. |
| `SHADOWS_SHARED_FUNCTION` | A page file defines a function whose name matches a `cc-shared.js` export. |
| `UNKNOWN_HOOK_NAME` | A function inside the hooks banner has a name not in the recognized hook set. |

### 19.4 Forbidden-pattern codes

| Code | Description | Row host |
|---|---|---|
| `FORBIDDEN_LET` | A `let` declaration appears anywhere in the file. | Declaration row |
| `FORBIDDEN_MULTI_DECLARATION` | A single statement declares multiple variables. | Declaration row |
| `FORBIDDEN_CONDITIONAL_DEFINITION` | A top-level function or class is declared inside an `if`/`while`/`try` block. | Function/class row |
| `FORBIDDEN_ANONYMOUS_FUNCTION` | A function or arrow expression has no name and is not passed as a callback argument. | The const/var row |
| `FORBIDDEN_PROPERTY_ASSIGN_EVENT` | An event handler is bound via `el.on<event> = handler` instead of `addEventListener`. | JS_EVENT row |
| `FORBIDDEN_PER_ELEMENT_LISTENER_LOOP` | An `addEventListener` call is bound to a per-iteration element inside a `forEach`, `for...of`, or `for` loop. The canonical pattern is delegation on a stable parent (Section 12). | JS_EVENT row |
| `FORBIDDEN_IIFE` | An IIFE appears at file scope. | JS_IIFE row |
| `FORBIDDEN_REVEALING_MODULE` | A `const` or `var` declaration is initialized by an immediately-invoked function expression (the revealing-module pattern). | The const/var declaration row (`JS_CONSTANT_VARIANT` or `JS_STATE`) |
| `FORBIDDEN_EVAL` | A call to `eval(...)` appears in the file. | JS_EVAL row |
| `FORBIDDEN_DOCUMENT_WRITE` | A call to `document.write(...)` appears in the file. | JS_DOCUMENT_WRITE row |
| `FORBIDDEN_WINDOW_ASSIGNMENT` | An assignment to `window.<name>` appears outside `cc-shared.js`. | JS_WINDOW_ASSIGNMENT row |
| `FORBIDDEN_INLINE_STYLE_IN_JS` | A template literal or string literal contains a `<style>` element. | JS_INLINE_STYLE row |
| `FORBIDDEN_INLINE_SCRIPT_IN_JS` | A template literal or string literal contains a `<script>` element. | JS_INLINE_SCRIPT row |
| `FORBIDDEN_INLINE_EVENT_IN_JS` | A template literal or string literal contains an inline `on<event>="..."` attribute. Bind events via `addEventListener` after rendering. | JS_INLINE_EVENT row |
| `FORBIDDEN_FILE_SCOPE_LINE_COMMENT` | A `//` line comment appears at file scope. | JS_LINE_COMMENT row |

### 19.5 Comment / structure codes

| Code | Description |
|---|---|
| `FORBIDDEN_COMMENT_STYLE` | A comment exists that is not one of the allowed kinds. |
| `BLANK_LINE_INSIDE_FUNCTION_BODY_AT_SCOPE` | More than one consecutive blank line appears inside a function body. |
| `EXCESS_BLANK_LINES` | More than one blank line appears between top-level constructs. |

---

## 20. Compliance queries

Standard SQL queries against `dbo.Asset_Registry` for JS compliance reporting. Each query is scoped to `WHERE file_type = 'JS'`.

### 20.1 Q1 - Shared-function shadowing

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

### 20.2 Q2 - Drift summary per file

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

### 20.3 Q3 - Drift code distribution

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

### 20.4 Q4 - Hook implementation matrix

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

### 20.5 Q5 - Page glossary (function reference)

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

### 20.6 Q6 - Forbidden-pattern inventory

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

## 21. Examples

### 21.1 Minimal complete page file

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

    /* Delegated click handler on the agent grid. */
    const agentGrid = document.getElementById('ex-agent-grid');
    agentGrid.addEventListener('click', ex_onAgentGridClick);

    /* Singleton refresh button. */
    const refreshBtn = document.getElementById('ex-refresh-btn');
    refreshBtn.addEventListener('click', ex_refreshAll);

    /* Window resize listener. */
    window.addEventListener('resize', ex_onWindowResize);
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
    const container = document.getElementById('ex-agent-grid');
    container.innerHTML = agents.map(ex_buildAgentCard).join('');
}

/* Builds the HTML for a single agent card. */
function ex_buildAgentCard(agent) {
    return '<div class="ex-agent-card" data-agent-id="' + agent.id + '">' +
           '<span class="ex-agent-name">' + escapeHtml(agent.name) + '</span>' +
           '</div>';
}

/* Delegated handler for clicks inside the agent grid. */
function ex_onAgentGridClick(event) {
    const card = event.target.closest('.ex-agent-card');
    if (!card) return;
    const agentId = card.dataset.agentId;
    ex_handleAgentClick(agentId);
}

/* Acts on a click for a specific agent. */
function ex_handleAgentClick(agentId) {
    /* ... */
}

/* Window resize handler. */
function ex_onWindowResize() {
    /* ... */
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
- 7 x `JS_FUNCTION DEFINITION` (`ex_refreshAll`, `ex_loadAgents`, `ex_renderAgents`, `ex_buildAgentCard`, `ex_onAgentGridClick`, `ex_handleAgentClick`, `ex_onWindowResize`)
- 2 x `JS_HOOK DEFINITION` (`onPageRefresh`, `onPageResumed`)
- 3 x `JS_EVENT USAGE` (the agent-grid click delegation, the singleton refresh button, the window resize listener)

Zero drift rows expected.

---

## Appendix - Rationale

This appendix explains why selected rules are what they are. Entries are keyed to body section numbers. Sections without entries here have no rationale beyond the rule itself.

### A.3 Section banners

The 76-character rule for both `=` rule lines and `-` separator lines is a fixed value rather than a range. A fixed length makes banners visually uniform across the codebase. The chosen value (76) fits within an 80-column convention with margin for `/* ` and ` */` comment delimiters.

### A.4 Section types

`FOUNDATION` and `CHROME` belong only in `cc-shared.js` because they are platform-wide constructs. CSS has the same constraint via the anchor-file rule (`CC_CSS_Spec.md` §4.3); JS reuses the same model with `cc-shared.js` as the platform's single anchor file for shared JS constructs.

### A.5 Prefix

The single-prefix-per-file rule reflects that a file represents one CC page (or the shared resource), and each page has exactly one registered prefix.

The registry validation rule (Section 5.4) makes `Component_Registry.cc_prefix` the source of truth for which prefix belongs to which page. Before the registry existed, the prefix was declared only in the file header and could drift from the platform's understanding silently. Pinning each file's prefix to its component row in the registry surfaces drift as queryable catalog rows.

The `PREFIX_MISSING` rule (Section 5.4 final bullet) extends the prefix discipline to identifiers themselves, independent of banners. Banner-anchored `PREFIX_MISMATCH` is silent on a file with no banners; `PREFIX_MISSING` closes that gap and ensures every top-level identifier is checked against the file's registered `cc_prefix` regardless of whether banners are in place.

### A.6 Function definitions

The single-form rule for function declarations exists to make the catalog's function row count predictable. If functions could be declared as `const name = function() {}` or `const name = () => {}`, the parser would have to either treat those as JS_FUNCTION rows (conflating const declarations with function declarations) or as JS_CONSTANT_VARIANT rows (making "list all functions" require a JOIN between two component types). One form means one row type. The narrow callback exception preserves natural JS idioms (`addEventListener('click', function() { ... })`) without compromising the catalog's clarity.

### A.7 Constants and state

The `const` vs `var` split by section reflects the semantic distinction. CONSTANTS are immutable; STATE mutates over the page's lifetime. Forcing the keyword to match the section makes the file's structure self-documenting: a reader skimming the STATE section knows everything in it can change at runtime; everything in CONSTANTS or FOUNDATION cannot.

`let` is forbidden because it adds a third declaration kind without adding semantic value over `const` and `var`. The two-kind discipline keeps the spec's section-keyword mapping clean.

### A.8 Page lifecycle hooks

The hooks-banner-last rule produces a stable file-scanning experience. A reader looking for "this page's contract with cc-shared.js" knows exactly where to find it (last banner in the file). The `Prefix: (none)` declaration prevents the spec's prefix-matching from erroneously flagging hook names as PREFIX_MISMATCH violations.

### A.12 Event handler binding

Event delegation is canonical because it survives re-rendering. CC pages render and re-render their content as data updates; a delegated listener attached at page boot to a stable parent survives every subsequent re-render without rebinding. Direct binding requires the page author to remember to rebind after every render. That is a footgun the spec avoids by mandating delegation as the default.

The carve-outs in §12.2 are deliberately narrow. Each represents a case where the canonical pattern is mechanically inapplicable, not where it is pragmatically suboptimal:

- **Singleton elements** (carve-out 1) exist exactly once on the page and are not subject to re-rendering. They have no related siblings the listener could be delegated across; the only available delegation parent is the page's root or `document.body`, which would funnel every page-level click through one global router. Direct binding on the singleton itself is structurally cleaner.
- **Window/document-level events** (carve-out 2) bind to the top of the DOM tree. There is no parent to delegate from. The "delegation" pattern and the "direct binding" pattern collapse to the same thing here: `window.addEventListener('resize', handler)`.

The form-input case is covered by delegation, not by a carve-out. A form is a stable parent; its inputs are reachable via `event.target.matches('#...')` or `event.target.matches('[name=...]')`. The handler routes per-input via that check. This trades a small amount of routing boilerplate for consistency with the canonical pattern across every other binding case in the file. The trade is worth it because the initiative's premise is that there is one way to do this; carve-outs erode that premise unless they represent a structural inapplicability of the canonical form, which the form case does not.

The `FORBIDDEN_PER_ELEMENT_LISTENER_LOOP` drift code targets the dominant anti-pattern: a `forEach` over rendered list/grid elements that calls `addEventListener` on each. This shape is mechanically detectable at the AST level — a loop containing an `addEventListener` call on a per-iteration element — and represents the most common authoring mistake delegation prevents. The drift fires on the JS_EVENT row inside the loop, with the `parent_function` column carrying the enclosing function name so the operator can locate the rebind site.

The carve-out rule is an authoring rule. The parser cannot in general distinguish a legitimate singleton-element direct binding from a misapplied direct binding to an element that should have been delegated; both look identical at the AST level. This is the same shape as other authoring rules in the spec — §6.1 (function comment quality), §7.2 (case distinction in constant naming), §13 (sub-section marker vs new banner judgment), §14 (banner authoring discipline). The pattern is consistent: the spec sets the rule; the parser catches what it can; humans catch the rest. The catalog still surfaces useful signal — a high `JS_EVENT` row count on a page is a flag for review even when the populator cannot auto-classify each row.

### A.15 Forbidden patterns

The dedicated component_type rows for forbidden patterns (JS_IIFE, JS_EVAL, JS_DOCUMENT_WRITE, etc.) exist because these patterns have no natural declaration row to host the drift. An IIFE doesn't have a name; eval doesn't have a binding. The dedicated row gives every forbidden-pattern occurrence a queryable catalog presence regardless of where in the source it appears.

The revealing-module pattern (`const X = (function(){...})()`) is treated as a forbidden wrapper rather than a forbidden construct because it does have a natural host — the const or var declaration that binds the IIFE result to a name. The wrapper row carries the drift; the inner functions are not cataloged because they have no spec-equivalent identity. This parallels how the top-level IIFE is handled, with the JS_IIFE row hosting the drift in that case. The two patterns share a common diagnosis: the file's design is structurally non-spec and requires rewriting, not in-place repair.

### A.19 Drift codes — banner granularity

The §19.2 banner code set is intentionally granular rather than coarse. A single combined code would collapse every kind of banner non-conformance into one verdict, which makes refactor work hard to triage — a reader could not tell from the code alone whether the banner had the wrong rule-line length, was missing a description, used an inline shape, or had a malformed title line. Each granular code (`BANNER_INVALID_RULE_LENGTH`, `BANNER_INLINE_SHAPE`, `BANNER_MISSING_DESCRIPTION`, etc.) describes exactly one violation, allowing precise queries like "find every banner with the wrong rule length" or "list every inline-shape banner candidate for refactor." A non-conformant banner may carry several granular codes simultaneously when it violates multiple rules.

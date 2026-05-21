# Control Center JavaScript File Format Specification

## 1. File structure

A JavaScript file consists of, in this exact order:

1. A file header (§2).
2. One or more sections (§3, §4).
3. End of file.

Nothing else may appear at file scope.

---

## 2. File header

The header is a single block comment at the top of the file, opening at line 1 and followed by exactly one blank line before the first section banner. Required content, in order:

```
xFACts Control Center - <Component Description> (<filename>)
Location: <absolute path>
Version: Tracked in dbo.System_Metadata (component: <Component>)

<Purpose paragraph, 1-5 sentences.>

FILE ORGANIZATION
-----------------
<Banner title 1>
<Banner title 2>
<Banner title N>
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
<TYPE>: <NAME>
----------------------------------------------------------------------------
<Description, 1-5 sentences.>
Prefix: <prefix>
```

### 3.1 Rules

- The opening and closing rule lines are each exactly 76 `=` characters.
- The middle separator is exactly 76 `-` characters.
- `<TYPE>` is one of the recognized section types (§4), uppercase letters and underscores only.
- `<NAME>` is human-readable text.
- The description block is required.
- The `Prefix:` line declares exactly one prefix value (§5).
- A new banner is created for each distinct concept rather than expanding an existing banner.

---

## 4. Section types

The recognized section types differ between page files and the shared file `cc-shared.js`.

### 4.1 Page files

Four section types, in fixed order:

| Order | TYPE | Purpose | Multiple banners? |
|-------|------|---------|-------------------|
| 1 | `IMPORTS` | ES module imports or `require` statements. | No — single banner only. |
| 2 | `CONSTANTS` | Module-scope `const` declarations of immutable values. Includes per-event dispatch tables (§11). | Yes — group by concept. |
| 3 | `STATE` | Module-scope `var` declarations of mutable values. | Yes — group by concept. |
| 4 | `FUNCTIONS` | Function declarations, including the mandatory `<prefix>_init` page boot function (§11) and the page lifecycle hooks banner (§8). | Yes. The hooks banner has a fixed name (§8) and is last. |

### 4.2 The shared file `cc-shared.js`

Five section types, in fixed order:

| Order | TYPE | Purpose | Multiple banners? |
|-------|------|---------|-------------------|
| 1 | `IMPORTS` | ES module imports or `require` statements. | No. |
| 2 | `FOUNDATION` | Platform-wide immutable constants and primitives. Holds `const` declarations only. | Yes — group by concept. |
| 3 | `STATE` | Platform-wide mutable runtime state. Holds `var` declarations only. | Yes — group by concept. |
| 4 | `BOOTLOADER` | Page-module discovery, loading, lifecycle invocation, and the shared dispatch tables. | No — single banner only. |
| 5 | `CHROME` | Universal page chrome and shared utilities. | Yes — group by concept. |

### 4.3 Rules

- Section types appear in the order shown.
- `FOUNDATION`, `BOOTLOADER`, and `CHROME` sections live only in `cc-shared.js`. Any other JS file containing one of these sections is drift.
- A file with no imports omits the IMPORTS banner entirely, along with its FILE ORGANIZATION entry.

---

## 5. Prefix

Every section banner declares one prefix via the `Prefix:` line. Every top-level identifier (function name, constant name, state variable name, class name) defined in that section begins with the declared prefix followed by an underscore.

### 5.1 Prefix forms

Two forms, no others:

- **Page prefix** — the value of `Component_Registry.cc_prefix` for the file's component. Declared in every section banner of page files. Identifiers in these sections begin with `<page-prefix>_`.
- **Chrome prefix** — the literal token `cc`. Declared in every section banner of `cc-shared.js`. Identifiers in `cc-shared.js` begin with `cc_`.

### 5.2 Rules

- A page-file banner declares the page prefix from `Component_Registry.cc_prefix`.
- A `cc-shared.js` banner declares `cc`.
- The `Prefix:` line declares exactly one value. Comma-separated values are not permitted.
- `Component_Registry.cc_prefix` is the source of truth. When the file and registry disagree, the file is wrong.
- Every top-level identifier in a JS file begins with the file's prefix followed by an underscore. There are no exemptions: hooks, ENGINE_PROCESSES, dispatch tables, and every other top-level identifier all follow this rule.
- Methods inside classes are exempt — they are namespaced within the class itself.

---

## 6. Function definitions

A function definition has exactly one form:

```
function name() { ... }
```

### 6.1 Rules

- Every function definition is preceded immediately by a single block comment describing its purpose in present tense. JSDoc-format parameter and return documentation is permitted but not mandatory.
- Top-level function names follow the prefix discipline in §5.
- `async` and `generator` function declarations are permitted forms.
- The only permitted anonymous function form is a callback argument passed to another call (e.g., `addEventListener('click', function() {...})`, `array.forEach(function(item) {...})`, `promise.then(function(result) {...})`). Anonymous functions assigned to const/var, returned from another function, or used as object property values are forbidden.

---

## 7. Constants and state

Module-scope declarations split into two kinds based on the section they live in:

- **`CONSTANTS` and `FOUNDATION` sections** — declarations use `const`.
- **`STATE` sections** — declarations use `var`.

`let` is forbidden anywhere in any JS file.

### 7.1 Rules

- Every constant or state declaration is preceded immediately by a single block comment describing its purpose.
- A `var` declaration in a `CONSTANTS` or `FOUNDATION` section is drift. A `const` declaration in a `STATE` section is drift.
- One declaration per statement. `var a, b, c;` and `const a = 1, b = 2;` are forbidden.
- Constants holding primitive literals (numbers, strings, booleans) use SCREAMING_SNAKE_CASE after the prefix. Constants holding objects, arrays, or computed values use camelCase after the prefix. State variables use camelCase after the prefix.

### 7.2 Engine processes constant

Pages with engine cards registered in `Orchestrator.ProcessRegistry` declare a `<prefix>_ENGINE_PROCESSES` constant in a `CONSTANTS` banner with the fixed name `ENGINE PROCESSES`:

```javascript
var <prefix>_ENGINE_PROCESSES = {
    '<process-name>': { slug: '<slug>' },
    '<process-name>': { slug: '<slug>' }
};
```

#### 7.2.1 Rules

- The banner declaring `<prefix>_ENGINE_PROCESSES` has the fixed name `ENGINE PROCESSES`. Declaration in any other banner is drift.
- Keys match `Orchestrator.ProcessRegistry.process_name`. Slug values match `Orchestrator.ProcessRegistry.cc_engine_slug` for the corresponding process.
- `<prefix>_ENGINE_PROCESSES` is declared with `var`, not `const`. This is the sole exception to the CONSTANTS-section-uses-const rule and exists because `cc-shared.js` resolves the binding via `window[pageKey + '_ENGINE_PROCESSES']`, and in classic scripts only `var` and `function` declarations populate `window`.

---

## 8. Page lifecycle hooks

Page lifecycle hooks are named callbacks that `cc-shared.js` invokes when relevant events occur. The set of recognized hook suffixes is fixed:

| Hook suffix | When called |
|---|---|
| `onPageRefresh` | User clicks the page refresh button. |
| `onPageResumed` | Tab regained visibility after being hidden. |
| `onSessionExpired` | Auth check failed; session is dead. |
| `onEngineProcessCompleted` | An orchestrator process this page cares about finished. |
| `onEngineEventRaw` | Every WebSocket event before filtering (Admin only). |

A page defines only the hooks it uses. `cc-shared.js` probes for each via `typeof window[pageKey + '_<suffix>'] === 'function'` before calling.

### 8.1 Rules

- Hooks live in a `FUNCTIONS` banner with the fixed name `PAGE LIFECYCLE HOOKS`. The banner is the last banner in the file.
- Hook function names follow the form `<prefix>_<hookSuffix>` where `<hookSuffix>` is one of the recognized values above.
- A function whose suffix matches a recognized hook name must be declared inside the hooks banner. Declaration elsewhere in the file is drift.
- A function inside the hooks banner whose suffix is not in the recognized set is drift.

---

## 9. Classes and methods

### 9.1 Rules

- Class declarations live at module scope inside a `FUNCTIONS` section.
- Class names follow the prefix discipline in §5.
- Class declarations and methods are each preceded immediately by a single block comment describing purpose.
- Methods do not carry the page prefix; they are namespaced inside the class.

---

## 10. Imports

`IMPORTS` sections contain ES module `import` statements or Node `require` calls. A file with no imports omits the IMPORTS banner entirely, along with its corresponding FILE ORGANIZATION entry.

---

## 11. Page boot and action dispatch

Every page file declares a single page boot function named `<prefix>_init`. The bootloader in `cc-shared.js` invokes it after the page's JS module loads. The page registers its own delegated event listeners inside `<prefix>_init` and routes events through per-event dispatch tables.

### 11.1 Page boot function

- `<prefix>_init` is a top-level `function` declaration in a `FUNCTIONS` section. `const` or `var` arrow-expression forms are forbidden — the bootloader resolves the function via `window[pageKey + '_init']`, and only `function` declarations populate `window` in classic scripts.
- Functions called from `<prefix>_init` may invoke functions from anywhere else in the file.

### 11.2 Dispatch tables

A page connects its `data-action-<event>` attributes (declared in HTML markup per the HTML spec) to handler functions via per-event dispatch tables. Tables are object literals declared as `const` in a `CONSTANTS` banner.

#### 11.2.1 Page-side dispatch tables

Page-side tables follow the naming pattern `<prefix>_<event>Actions`:

```javascript
const bch_clickActions = {
    'bch-open-batch-detail':     bch_openBatchDetail,
    'bch-close-detail-slideout': bch_closeDetailSlideout
};

const bch_changeActions = {
    'bch-filter-by-status': bch_filterByStatus
};
```

- Keys are action values matching `data-action-<event>` attribute values in HTML.
- Keys carry the page prefix per the HTML spec §4 unified prefix rule: `<page-prefix>-<name>`.
- Values are bare function identifier references defined elsewhere in the same file.

#### 11.2.2 Chrome dispatch tables

Chrome dispatch tables live in `cc-shared.js`'s `BOOTLOADER` section, named `cc_<event>Actions` (one table per recognized event from the HTML spec §7.3). Tables are empty `{}` literals when no chrome actions exist for that event.

- Keys are action values prefixed with `cc-` (e.g., `'cc-page-refresh'`, `'cc-reload-page'`).
- Values are bare function identifier references defined elsewhere in `cc-shared.js`.

### 11.3 Delegated listener registration

The page registers one delegated `addEventListener` per event for which it has a non-empty dispatch table. Each listener is attached to `document.body` inside `<prefix>_init`. The listener's handler examines `event.target.closest('[data-action-<event>]')`, looks up the action value in the corresponding dispatch table, and invokes the handler with `(target, event)`.

### 11.4 Rules

- Every dispatch table entry's handler value resolves to a function defined in the same file.
- A page-side dispatch table key carries the page prefix. A chrome dispatch table key carries the `cc-` prefix. Keys not matching the table's prefix are drift.

---

## 12. Event handler binding

Event handlers are attached via `addEventListener`. The canonical pattern is event delegation, including the per-event delegated dispatchers registered inside `<prefix>_init` per §11.3.

### 12.1 Delegation pattern

A delegation binding has three parts:

1. A stable parent — an element that exists in the page's static markup or is rendered exactly once and not replaced.
2. A single `addEventListener` call on that parent, registered during page boot inside the `<prefix>_init` function.
3. A handler that dispatches by examining `event.target` via `event.target.matches(selector)` or `event.target.closest(selector)`.

Per-row context (record IDs, group IDs, tracking IDs, etc.) is carried on rendered elements via `data-*` attributes and read by the handler via `event.target.dataset.<name>` or `event.target.closest('.<row-class>').dataset.<name>`.

### 12.2 Permitted direct-binding cases

Direct binding (without delegation) is permitted in exactly these cases:

1. **Singleton elements bound at page boot.** An element that exists exactly once on the page and is not subject to re-rendering, bound during `<prefix>_init`.
2. **Window-level and document-level events.** Events bound on `window` or `document`.

### 12.3 Rules

- The `el.on<event> = handler` style of binding is forbidden. Only `addEventListener` is permitted.
- Per-element listener attachment inside loops (`forEach`, `for...of`, `for`) is forbidden. Delegate on a stable parent instead.

---

## 13. Comments

Five comment forms are recognized:

1. **File header** — single block comment at line 1 (§2).
2. **Section banners** — multi-line block comments enclosing a section's title, description, and prefix declaration (§3).
3. **Purpose comments** — single block comment immediately preceding a function, class, method, constant, state variable, or hook declaration. Required.
4. **Sub-section markers** — inline block comment between definitions in a section, used as a lightweight visual divider: `/* -- <label> -- */`. Optional.
5. **Inline body comments** — block comment inside a function body explaining the immediately-following statement or sub-group. Permitted only inside function bodies.

### 13.1 Rules

- Purpose comments are written in present-tense, descriptive style. They describe what the function/constant/state does, not why.
- Inline `//` line comments are permitted inside function bodies. They are forbidden at file scope.
- Any block comment at file scope that does not fit one of the five forms above is drift.

---

## 14. Sub-section markers vs. new banners

When a section's content grows, choose between a new banner or a sub-section marker.

### 14.1 Rules

- Use a **new banner** when the new content is a distinct concept with its own purpose. The new banner gets its own entry in the FILE ORGANIZATION list.
- Use a **sub-section marker** (`/* -- <label> -- */`) when the new content is a sub-component of an existing concept, grouped for visual reading aid only. Sub-section markers do not appear in the FILE ORGANIZATION list and do not nest.

---

## 15. Forbidden patterns

| Pattern | Rule |
|---------|------|
| `let` declaration anywhere | §7 |
| Multiple declarations in one statement (`var a, b;` or `const a = 1, b = 2;`) | §7.1 |
| Top-level function or class declared inside `if`/`while`/`try` block | §6 |
| Anonymous function or arrow expression outside the callback exception | §6.1 |
| `el.on<event> = handler` event binding | §12.3 |
| `addEventListener` bound to per-iteration elements inside a loop | §12.3 |
| Top-level wrapper pattern (IIFE or revealing-module `const X = (function(){})()`) | — |
| `eval(...)` call | — |
| `document.write(...)` call | — |
| `window.<name> = ...` assignment outside `cc-shared.js` | — |
| `<style>` element inside template or string literal | — |
| `<script>` element inside template or string literal | — |
| Inline `on<event>="..."` attribute inside template or string literal | — |
| `//` line comment at file scope | §13.1 |
| Block comment at file scope not matching one of the five recognized forms | §13.1 |
| More than one consecutive blank line inside a top-level function body | — |
| More than one blank line between top-level constructs | — |

---

## 16. Chrome identifier reference

The `cc_*` identifiers referenced by the JS spec are defined in `cc-shared.js`. The list below is the contract — when this spec references a chrome identifier, that identifier must exist in `cc-shared.js` with the same name. Adding or renaming a chrome identifier referenced by this spec requires updates in both files.

### 16.1 Dispatch tables

| Identifier | Purpose |
|---|---|
| `cc_clickActions` | Shared click action dispatch table (§11.2.2) |
| `cc_changeActions` | Shared change action dispatch table |
| `cc_inputActions` | Shared input action dispatch table |
| `cc_submitActions` | Shared submit action dispatch table |
| `cc_keydownActions` | Shared keydown action dispatch table |
| `cc_keyupActions` | Shared keyup action dispatch table |
| `cc_focusActions` | Shared focus action dispatch table |
| `cc_blurActions` | Shared blur action dispatch table |

### 16.2 Recognized hook suffixes

The five hook suffixes a page may implement, per §8:

| Suffix | When called |
|---|---|
| `onPageRefresh` | Page refresh button clicked. |
| `onPageResumed` | Tab regained visibility. |
| `onSessionExpired` | Auth session ended. |
| `onEngineProcessCompleted` | Orchestrator process this page cares about finished. |
| `onEngineEventRaw` | Every WebSocket event before filtering (Admin only). |

---

## 17. Drift code reference

The populator emits a drift code on every spec violation. Each code maps to a single rule. This table is the contract between the spec and the populator.

| Code | Description | Rule |
|------|-------------|------|
| `MALFORMED_FILE_HEADER` | File header missing, malformed, or fields out of order. | §2 |
| `FORBIDDEN_CHANGELOG_BLOCK` | File header contains a CHANGELOG block. | §2.1 |
| `FILE_ORG_MISMATCH` | FILE ORGANIZATION list does not match section banner titles verbatim, in order. | §2.1 |
| `MISSING_SECTION_BANNER` | A top-level construct appears outside any banner. | §3 |
| `BANNER_INLINE_SHAPE` | Banner uses a single-line form. | §3.1 |
| `BANNER_INVALID_RULE_CHAR` | Banner opening or closing rule line is not all `=`. | §3.1 |
| `BANNER_INVALID_RULE_LENGTH` | Banner opening or closing rule line is not exactly 76 characters. | §3.1 |
| `BANNER_INVALID_SEPARATOR_CHAR` | Banner middle separator is not all `-`. | §3.1 |
| `BANNER_INVALID_SEPARATOR_LENGTH` | Banner middle separator is not exactly 76 characters. | §3.1 |
| `BANNER_MALFORMED_TITLE_LINE` | Banner title line does not parse as `<TYPE>: <NAME>`. | §3.1 |
| `BANNER_MISSING_DESCRIPTION` | Banner has no description text. | §3.1 |
| `UNKNOWN_SECTION_TYPE` | Banner declares a TYPE not in the recognized list for the file kind. | §4 |
| `SECTION_TYPE_ORDER_VIOLATION` | Section types appear out of order. | §4.3 |
| `DUPLICATE_FOUNDATION` | FOUNDATION section appears outside `cc-shared.js`. | §4.3 |
| `DUPLICATE_BOOTLOADER` | BOOTLOADER section appears outside `cc-shared.js`. | §4.3 |
| `DUPLICATE_CHROME` | CHROME section appears outside `cc-shared.js`. | §4.3 |
| `MISSING_PREFIX_DECLARATION` | Banner missing the `Prefix:` line. | §5.2 |
| `MALFORMED_PREFIX_VALUE` | Banner declares a `Prefix:` value that is neither a page prefix nor `cc`, or declares multiple comma-separated values. | §5.2 |
| `PREFIX_REGISTRY_MISMATCH` | Page-file banner's declared prefix does not match `Component_Registry.cc_prefix`. | §5.2 |
| `CHROME_FILE_INVALID_PREFIX` | `cc-shared.js` banner declares a prefix other than `cc`. | §5.2 |
| `PREFIX_MISSING` | Top-level identifier does not begin with the file's prefix followed by an underscore. | §5.2 |
| `PREFIX_MISMATCH` | Top-level identifier does not begin with the declared section prefix. | §5.2 |
| `MISSING_FUNCTION_COMMENT` | Function declaration not preceded by a purpose comment. | §6.1 |
| `MISSING_CONSTANT_COMMENT` | Constant declaration not preceded by a purpose comment. | §7.1 |
| `MISSING_STATE_COMMENT` | State variable declaration not preceded by a purpose comment. | §7.1 |
| `MISSING_CLASS_COMMENT` | Class declaration not preceded by a purpose comment. | §9.1 |
| `MISSING_METHOD_COMMENT` | Method declaration not preceded by a purpose comment. | §9.1 |
| `MISSING_PAGE_INIT` | Page file does not declare `<prefix>_init` as a top-level function declaration. | §11.1 |
| `WRONG_DECLARATION_KEYWORD` | `var` in CONSTANTS/FOUNDATION, or `const` in STATE. `<prefix>_ENGINE_PROCESSES` in its required banner is exempt. | §7.1, §7.2.1 |
| `FORBIDDEN_MULTI_DECLARATION` | Single statement declares multiple variables. | §7.1 |
| `ENGINE_PROCESSES_MISPLACED` | `<prefix>_ENGINE_PROCESSES` declared outside its required `CONSTANTS: ENGINE PROCESSES` banner. | §7.2.1 |
| `HOOKS_BANNER_NOT_LAST` | `FUNCTIONS: PAGE LIFECYCLE HOOKS` banner exists but is not the last banner. | §8.1 |
| `UNKNOWN_HOOK_NAME` | Function inside the hooks banner has a suffix not in the recognized hook set. | §8.1 |
| `HOOK_MISPLACED` | Function whose suffix matches a recognized hook name is declared outside the hooks banner. | §8.1 |
| `FORBIDDEN_ANONYMOUS_FUNCTION` | Anonymous or arrow function used outside the callback-argument exception. | §6.1 |
| `FORBIDDEN_CONDITIONAL_DEFINITION` | Top-level function or class declared inside a conditional or loop block. | §6 |
| `FORBIDDEN_LET` | `let` declaration appears in the file. | §7 |
| `MALFORMED_ACTION_KEY` | Dispatch table key does not carry the prefix matching the table's scope (`<prefix>-` for page tables, `cc-` for chrome tables). | §11.2, §11.4 |
| `UNRESOLVED_DISPATCH_HANDLER` | Dispatch table entry references a handler function name not defined in the same file. | §11.4 |
| `FORBIDDEN_PROPERTY_ASSIGN_EVENT` | Event bound via `el.on<event> = handler` instead of `addEventListener`. | §12.3 |
| `FORBIDDEN_PER_ELEMENT_LISTENER_LOOP` | `addEventListener` bound to per-iteration element inside a loop. | §12.3 |
| `FORBIDDEN_TOP_LEVEL_WRAPPER` | Top-level IIFE or revealing-module wrapper at file scope. | §15 |
| `FORBIDDEN_EVAL` | `eval(...)` call in the file. | §15 |
| `FORBIDDEN_DOCUMENT_WRITE` | `document.write(...)` call in the file. | §15 |
| `FORBIDDEN_WINDOW_ASSIGNMENT` | `window.<name> = ...` assignment outside `cc-shared.js`. | §15 |
| `FORBIDDEN_INLINE_STYLE_IN_JS` | Template or string literal contains a `<style>` element. | §15 |
| `FORBIDDEN_INLINE_SCRIPT_IN_JS` | Template or string literal contains a `<script>` element. | §15 |
| `FORBIDDEN_INLINE_EVENT_IN_JS` | Template or string literal contains an inline `on<event>="..."` attribute. | §15 |
| `FORBIDDEN_FILE_SCOPE_LINE_COMMENT` | `//` line comment appears at file scope. | §13.1 |
| `FORBIDDEN_COMMENT_STYLE` | Comment does not match one of the five recognized forms. | §13.1 |
| `BLANK_LINE_INSIDE_FUNCTION_BODY_AT_SCOPE` | More than one consecutive blank line inside a top-level function body. | §15 |
| `EXCESS_BLANK_LINES` | More than one blank line between top-level constructs. | §15 |
| `ENGINE_PROCESS_PAGE_MISMATCH` | `<prefix>_ENGINE_PROCESSES` entry references a process whose page route does not match this page. | §7.2.1 |
| `ENGINE_SLUG_JS_MISMATCH` | `<prefix>_ENGINE_PROCESSES` entry's slug does not match `Orchestrator.ProcessRegistry.cc_engine_slug`. | §7.2.1 |
| `JS_HTML_ID_UNRESOLVED` | `getElementById` or `querySelector('#...')` references an ID that does not resolve to any HTML `id` declaration in the catalog. | §11 |
| `JS_HTML_ID_MALFORMED` | HTML ID string referenced from JS contains characters other than lowercase letters, digits, and hyphens, or does not begin with the page's prefix or `cc-`. | §11 |
| `SHADOWS_SHARED_FUNCTION` | Page file defines a function whose name matches a `cc-shared.js` export. | §5 |

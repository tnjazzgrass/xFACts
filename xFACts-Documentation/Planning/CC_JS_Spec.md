# Control Center JavaScript File Format Specification

*These rules are the current authority for Control Center JavaScript files. They are settled until explicitly amended; any proposed change is discussed before adoption. Where rationale exists for a rule, it appears in the Appendix at the corresponding section number.*

*Specs describe rules and shapes — never present contents. Statements about how many files currently do something, which files are empty today, or what the codebase looks like right now do not belong in this document; they age into inaccuracy the moment the codebase changes. If census-style information is needed, it lives in queries against `dbo.Asset_Registry`, not here.*

---

## Spec Authoring Conventions

*This section governs how this spec is written. It applies to every section and every edit.*

1. **Rules state what, not why.** Each rule is a short declarative statement of the requirement. No rationale, explanation, or background in the rule itself.
2. **One rule per bullet, where possible.** Numbered or bulleted lists make rules scannable. Prose paragraphs are reserved for cases where a single rule genuinely requires more than a sentence.
3. **No introductory framing.** Section headings introduce what the section governs; the section body goes straight to rules. Paragraphs like "This section addresses X because Y" or "The purpose of these rules is Z" do not belong in the body.
4. **Rationale lives in the Appendix.** Where a rule's reasoning is worth recording, it goes in the Appendix at the corresponding section number. Most rules do not need a rationale entry.
5. **Drift codes live in a consolidated reference at the end of the spec, not inline with rules.** Each rule states the requirement only. The drift codes section (§19) maps each code to its rule section and description in the format `Code | Section | Description`. A rule that has a drift code is implicitly enforceable; the code is documented in the reference.
6. **Examples earn their place.** A code block illustrating a rule should be the shortest form that conveys the rule. Multi-example blocks belong in the spec's Examples section, not inline with rules.
7. **No status, history, or progress information.** The spec describes rules. What the codebase does today, what was added when, and what is planned live elsewhere.
8. **Inline SQL or script query blocks do not belong in the spec.** Operational queries live in Object_Metadata `common_queries` on the relevant script. The spec references the script; it does not contain executable queries.

*New content added to this spec conforms to these conventions immediately. Existing sections may contain prose that predates these conventions and will be cleaned up in a dedicated pass.*

---

## 1. Required structure

A JavaScript file consists of three parts in this exact order:

1. **File header** - a single block comment opening at line 1, ending with `*/` followed by exactly one blank line.
2. **Section bodies** - one or more sections, each consisting of a section banner followed by the declarations and statements that section contains.
3. **End-of-file** - the file ends after the last meaningful statement of the last section. No trailing content.

Every line of code in the file lives inside exactly one of these three parts.

---

## 2. File header

*Catalog-side note: the parser additionally emits a single `JS_FILE` anchor row per scanned file, representing the file as a whole. The anchor row is a populator function, not a source-file construct — the author writes nothing for it. See §17.2 for details.*

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

Four section types, in fixed order:

| Order | TYPE | Purpose | Multiple banners? |
|-------|------|---------|-------------------|
| 1 | `IMPORTS` | ES module imports or `require` statements. | No - single banner only. |
| 2 | `CONSTANTS` | Module-scope `const` declarations of immutable values. Includes per-event dispatch tables (§11.3). | Yes - group by concept. |
| 3 | `STATE` | Module-scope `var` declarations of mutable values. | Yes - group by concept. |
| 4 | `FUNCTIONS` | Everything else - data loading, rendering, event handlers, helpers, hooks, and the mandatory `<prefix>_init` page boot function (Section 11). | Yes. The banner for page lifecycle hooks has a fixed name (Section 8) and must be last. |

### 4.2 The shared file `cc-shared.js`

Five section types, in fixed order:

| Order | TYPE | Purpose | Multiple banners? | Where it lives |
|-------|------|---------|-------------------|----------------|
| 1 | `IMPORTS` | ES module imports or `require` statements. Reserved for future use. | No. | Both. |
| 2 | `FOUNDATION` | Platform-wide immutable constants and primitives. Holds `const` declarations only. | Yes - group by concept. | `cc-shared.js` only. |
| 3 | `STATE` | Platform-wide mutable runtime state. Holds `var` declarations only. | Yes - group by concept. | Both. |
| 4 | `BOOTLOADER` | Page-module discovery, loading, and lifecycle invocation. Holds the `cc_RECOGNIZED_EVENTS` constant, the eight `cc_<event>Actions` dispatch tables, the delegated event listener registration, and the page-module loader. | No - single banner only. | `cc-shared.js` only. |
| 5 | `CHROME` | Universal page chrome and shared utilities. | Yes - group by concept. | `cc-shared.js` only. |

`FOUNDATION` is `cc-shared.js`'s name for what page files call `CONSTANTS`; `CHROME` covers the universal chrome utilities pages consume after boot; `STATE` keeps the same name and meaning in both file kinds.

### 4.3 Type-order rule

Section types must appear in the order shown. Drift code: `SECTION_TYPE_ORDER_VIOLATION`.

### 4.4 Type uniqueness across files

`FOUNDATION`, `BOOTLOADER`, and `CHROME` sections may exist in only one file across the codebase: `cc-shared.js`. Drift codes: `DUPLICATE_FOUNDATION`, `DUPLICATE_BOOTLOADER`, `DUPLICATE_CHROME`.

---

## 5. Prefix

Every section banner declares one prefix via the `Prefix:` line. Every top-level identifier (function name, constant name, state variable name, class name) defined in that section must begin with the declared prefix followed by an underscore. Drift code: `PREFIX_MISMATCH`.

### 5.1 Two prefix forms

The prefix system has exactly two forms. No other forms are valid.

- **Page prefix** — the value of `Component_Registry.cc_prefix` for the file's component. Declared in every section banner of page files. Example: `Prefix: bch`. Identifiers in these sections begin with `<page_prefix>_`.
- **Chrome prefix** — the literal token `cc`. Declared in every section banner of `cc-shared.js`. Identifiers in `cc-shared.js` begin with `cc_`.

### 5.2 Prefix declaration rules

- The `Prefix:` line is mandatory in every section banner. Drift code: `MISSING_PREFIX_DECLARATION`.
- A page-file section banner declares the page prefix from `Component_Registry.cc_prefix`. A different value emits `PREFIX_REGISTRY_MISMATCH`.
- A `cc-shared.js` section banner declares `Prefix: cc`. A different value emits `CHROME_FILE_INVALID_PREFIX`.
- The `Prefix:` line declares exactly one value. Multiple comma-separated values are not permitted. A banner declaring anything other than a single page prefix or `cc` emits `MALFORMED_PREFIX_VALUE`.

### 5.3 Registry as source of truth

`Component_Registry.cc_prefix` is the source of truth for which prefix belongs to which component. The parser cross-references each banner's declared prefix against the registry and emits drift on disagreement. When a declared prefix and the registry disagree, the file is wrong and the file is updated.

### 5.4 Identifier prefix rule

Every top-level identifier defined in a JS file begins with the file's prefix followed by an underscore:

- Page files: `<page_prefix>_<name>` (e.g., `bch_init`, `bch_clickActions`, `bch_onPageRefresh`, `bch_ENGINE_PROCESSES`).
- `cc-shared.js`: `cc_<name>` (e.g., `cc_clickActions`, `cc_loadPageModule`, `cc_showAlert`).

Drift code: `PREFIX_MISSING`. Hooks, ENGINE_PROCESSES, methods inside classes, and every other top-level identifier are all subject to this rule. There are no exemptions.

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

- Top-level function names in a page file begin with the page prefix followed by an underscore (Section 5).
- Functions in the page lifecycle hooks banner (Section 8) begin with the page prefix followed by the hook suffix (e.g., `<prefix>_onPageRefresh`).
- Functions in `cc-shared.js` begin with `cc_` followed by the function name (e.g., `cc_loadPageModule`, `cc_showAlert`).

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
- **Constants holding fixed configuration values written as primitive literals** (numbers, strings, booleans): SCREAMING_SNAKE_CASE after the prefix (e.g., `bch_DEFAULT_REFRESH_INTERVAL`, `cc_RECOGNIZED_EVENTS`).
- **Constants holding objects, arrays, or computed values**: camelCase after the prefix (e.g., `bch_clickActions`, `cc_clickActions`).
- **State variables**: camelCase after the prefix.
- Every identifier carries the file's prefix per §5.4: `<page_prefix>_` for page files, `cc_` for `cc-shared.js`.

The case-distinction rule is conventional, not parser-enforced.

### 7.3 Multiple declarations per statement

`var a, b, c;` and `const a = 1, b = 2;` are forbidden. Each declaration gets its own statement. Drift code: `FORBIDDEN_MULTI_DECLARATION`.

### 7.4 Engine processes constant

Pages that have engine cards registered in `Orchestrator.ProcessRegistry` declare a `<prefix>_ENGINE_PROCESSES` constant in a fixed-form `CONSTANTS` banner with the name `ENGINE PROCESSES`. The banner declares the file's page prefix per §5.

#### 7.4.1 ENGINE_PROCESSES shape

```javascript
const bch_ENGINE_PROCESSES = {
    '<process-name>': { slug: '<slug>' },
    '<process-name>': { slug: '<slug>' }
};
```

- Keys are process names matching `Orchestrator.ProcessRegistry.process_name`.
- Values are object literals with at least a `slug` field. The slug must match `Orchestrator.ProcessRegistry.cc_engine_slug` for the corresponding process.
- An empty `{}` is permitted when the page has no engine cards but the page still needs to declare the constant (e.g., to satisfy a future-state expectation). When the page has no engine cards registered in ProcessRegistry, the constant may be omitted entirely.

When the banner exists, it precedes any other `CONSTANTS` banner.

#### 7.4.2 ENGINE_PROCESSES validation

The parser cross-references the declared `<prefix>_ENGINE_PROCESSES` entries against `Orchestrator.ProcessRegistry` rows that have `cc_page_route` matching the page's route and `run_mode = 1`. Four drift codes apply:

- `MISSING_ENGINE_PROCESSES_DECLARATION` — ProcessRegistry has one or more active scheduled processes (`run_mode = 1`) registered with `cc_page_route` matching this page, but the JS file does not declare a `<prefix>_ENGINE_PROCESSES` constant. Attached to the `JS_FILE` anchor row.
- `ENGINE_PROCESS_PAGE_MISMATCH` — A `<prefix>_ENGINE_PROCESSES` entry references a process whose `cc_page_route` does not match the page hosting this JS file. Attached to the `JS_CONSTANT_VARIANT` row.
- `ENGINE_SLUG_JS_MISMATCH` — A `<prefix>_ENGINE_PROCESSES` entry's `slug` value does not match `cc_engine_slug` for the corresponding process in ProcessRegistry. Attached to the `JS_CONSTANT_VARIANT` row.
- `MISSING_ENGINE_CARD_FOR_REGISTERED_PROCESS` — ProcessRegistry has an active scheduled process (`run_mode = 1`) registered with `cc_page_route` matching this page, but the JS file's `<prefix>_ENGINE_PROCESSES` declaration does not include it. Attached to the `JS_FILE` anchor row.

#### 7.4.3 ENGINE_PROCESSES placement

`<prefix>_ENGINE_PROCESSES` must be declared inside the `CONSTANTS: ENGINE PROCESSES` banner. Declaration anywhere else in the file is not permitted. Drift code: `ENGINE_PROCESSES_MISPLACED`.

---

## 8. Page lifecycle hooks

Page lifecycle hooks are the named callbacks that `cc-shared.js` invokes on each page when relevant events occur. The set of recognized hook names is fixed:

| Hook (page-prefixed form) | When called | What it should do |
|---|---|---|
| `<prefix>_onPageRefresh` | User clicks the page refresh button | Re-fetch all sections marked Action or Live |
| `<prefix>_onPageResumed` | Tab regained visibility after being hidden | Re-fetch live data; reconnect WebSocket if needed |
| `<prefix>_onSessionExpired` | Auth check failed; session is dead | Stop all page-specific polling timers |
| `<prefix>_onEngineProcessCompleted` | An orchestrator process this page cares about finished | Re-fetch event-driven sections |
| `<prefix>_onEngineEventRaw` | Every WebSocket event before filtering (Admin only) | Used by the Admin page to drive the process timeline |

A page file defines only the hooks it uses. `cc-shared.js` probes for each via computed-name lookup (`typeof window[pageKey + '_onPageRefresh'] === 'function'`) before calling.

### 8.1 The hooks banner

If any hooks are defined, they live in a `FUNCTIONS` banner with the fixed name `PAGE LIFECYCLE HOOKS`. The banner declares the file's page prefix per §5.

### 8.2 Banner placement rule

If the `FUNCTIONS: PAGE LIFECYCLE HOOKS` banner exists, it must be the last banner in the file. Drift code: `HOOKS_BANNER_NOT_LAST`.

### 8.3 Catalog representation

Functions inside the hooks banner produce `JS_HOOK DEFINITION` rows (or `JS_HOOK_VARIANT DEFINITION` for async hooks; see Section 17.5), not `JS_FUNCTION DEFINITION` rows. The function comment requirement still applies.

### 8.4 Hook naming

A function inside the hooks banner has the form `<prefix>_<hookSuffix>` where `<hookSuffix>` is one of the five recognized values from §8: `onPageRefresh`, `onPageResumed`, `onSessionExpired`, `onEngineProcessCompleted`, `onEngineEventRaw`. A hook function whose suffix is not in the recognized set emits `UNKNOWN_HOOK_NAME`.

### 8.5 Hook function placement

A function whose name matches `<prefix>_<recognized-hook-suffix>` must be declared inside the `FUNCTIONS: PAGE LIFECYCLE HOOKS` banner. Declaration anywhere else in the file is not permitted. Drift code: `HOOK_MISPLACED`.

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

## 11. Page boot and action dispatch

Every page file declares a single page boot function named `<prefix>_init`. The bootloader (§4.2) invokes it by computed name (`window[pageKey + '_init']()`) after the page's JS module loads. The page registers its own delegated event listeners inside `<prefix>_init` and exposes per-event dispatch tables (§11.3) that those listeners route into.

### 11.1 Form

`<prefix>_init` is a top-level `function` declaration in the `FUNCTIONS` section. `const` or `var` arrow-expression forms are not permitted. Drift code: `MISSING_PAGE_INIT`.

### 11.2 Ordering

Functions called from `<prefix>_init` may invoke functions from anywhere else in the file. Other functions may not depend on `<prefix>_init` having completed beyond the constants and state being populated.

### 11.3 Dispatch tables

A page connects its `data-action-<event>` attributes (declared in HTML markup per CC_HTML_Spec.md §6) to handler functions via per-event dispatch tables. The tables are object literals declared as `const` in a `CONSTANTS` banner.

#### 11.3.1 Page-side dispatch tables

Page-side dispatch tables follow the naming pattern `<prefix>_<event>Actions` where `<event>` is lowercase and matches one of the recognized events from CC_HTML_Spec.md §6.4 (`click`, `change`, `input`, `submit`, `keydown`, `keyup`, `focus`, `blur`):

```javascript
const bch_clickActions = {
    'open-batch-detail':     bch_openBatchDetail,
    'close-detail-slideout': bch_closeDetailSlideout
};

const bch_changeActions = {
    'filter-by-status': bch_filterByStatus
};
```

- Keys are action values matching `data-action-<event>` attribute values in HTML. Keys use kebab-case (lowercase letters, digits, hyphens). The `cc-` prefix is reserved for shared chrome actions and must not appear on page-side dispatch keys.
- Values are bare function identifier references. The referenced function must be defined elsewhere in the same file as a `JS_FUNCTION` or `JS_FUNCTION_VARIANT`.

#### 11.3.2 Chrome dispatch tables

Chrome dispatch tables live in `cc-shared.js`'s `BOOTLOADER` section and follow the naming pattern `cc_<event>Actions` where `<event>` is lowercase (`cc_clickActions`, `cc_changeActions`, etc.). One table per recognized event from CC_HTML_Spec.md §6.4. Tables are empty `{}` literals when no chrome actions exist for that event.

- Keys are action values prefixed with `cc-` (e.g., `'cc-page-refresh'`, `'cc-reload-page'`).
- Values are bare function identifier references defined elsewhere in `cc-shared.js`. Per §5.4, these function names begin with `cc_`.

#### 11.3.3 Per-event delegated listener registration

The page registers one delegated `addEventListener` per event for which it has a non-empty dispatch table. Each listener is attached to `document.body` (or another stable parent) inside `<prefix>_init`. The listener's handler examines `event.target.closest('[data-action-<event>]')`, looks up the action value in the corresponding dispatch table, and invokes the handler with `(target, event)`.

```javascript
function bch_init() {
    document.body.addEventListener('click', bch_handleClickAction);
    document.body.addEventListener('change', bch_handleChangeAction);
}

function bch_handleClickAction(event) {
    const target = event.target.closest('[data-action-click]');
    if (!target) return;
    const action = target.getAttribute('data-action-click');
    if (!action || action.indexOf('cc-') === 0) return;  /* shared actions handled by cc-shared.js */
    const handler = bch_clickActions[action];
    if (!handler) {
        console.warn('[bch] Unknown page click action: ' + action);
        return;
    }
    handler(target, event);
}
```

#### 11.3.4 Dispatch table validation

The parser cross-references dispatch table entries against HTML-side `data-action-<event>` attribute declarations cataloged by the HTML populator. Two drift codes apply at scan time:

- `UNRESOLVED_DISPATCH_HANDLER` — A dispatch table entry references a handler function name that is not defined in the same file. Attached to the `JS_DISPATCH_ENTRY` row.
- `MALFORMED_ACTION_KEY` — A dispatch table key contains characters other than lowercase letters, digits, and hyphens, or (for page-side tables) begins with `cc-`, or (for chrome tables) does not begin with `cc-`. Attached to the `JS_DISPATCH_ENTRY` row.

Cross-spec resolution against HTML rows (whether the dispatch entry has a matching HTML `data-action-<event>` usage) happens during the JS populator's scan-time cross-population check (see §17.6).

---

## 12. Event handler binding

Event handlers are attached via `addEventListener`. The canonical form is event delegation, including the per-event delegated dispatchers registered inside `<prefix>_init` per §11.3.3.

### 12.1 Delegation pattern

A delegation binding has three parts:

1. A stable parent — an element that exists in the page's static markup or is rendered exactly once and not replaced.
2. A single `addEventListener` call on that parent, registered during page boot inside the `<prefix>_init` function (Section 11).
3. A handler function that dispatches by examining `event.target` via `event.target.matches(selector)` or `event.target.closest(selector)`.

Per-row context (record IDs, group IDs, tracking IDs, etc.) is carried on rendered elements via `data-*` attributes and read by the handler via `event.target.dataset.<name>` or `event.target.closest('.<row-class>').dataset.<name>`.

### 12.2 Permitted direct-binding cases

Direct binding is permitted in exactly these cases:

1. **Singleton elements bound at page boot.** An element that exists exactly once on the page and is not subject to re-rendering, bound during the page's `<prefix>_init` function (Section 11).
2. **Window-level and document-level events.** Events bound on `window` or `document`.

Any binding case that fits neither §12.1 nor §12.2 is evaluated as a spec amendment, not as a per-file authoring choice.

---

## 13. Comments
Comments serve five roles, and only five:
1. **File header** - a single block comment at line 1 (Section 2).
2. **Section banners** - multi-line block comments enclosing a section's title, description, and prefix declaration (Section 3).
3. **Purpose comments** - single block comment immediately preceding a function, class, method, constant, state variable, hook, or top-level expression statement that introduces named behavior (e.g., `document.addEventListener('DOMContentLoaded', ...)`). Required for the named definitions in that list; optional for top-level expression statements where the author judges a comment helpful.
4. **Sub-section markers** - inline block comment between definitions in a section, used as a lightweight visual divider. Format: `/* -- label -- */`. Optional.
5. **Inline body comments** - block comment appearing inside a function body, explaining the immediately-following statement or sub-group of statements. Always optional. Permitted only inside function bodies (not at file scope, not between class members).
No other comment forms are recognized. Stray block comments outside the five allowed kinds emit `FORBIDDEN_COMMENT_STYLE` drift on the file's `JS_FILE` row.
### 13.1 Inline comments
Inline `//` line comments are permitted inside function bodies for explaining specific lines or blocks of logic. They are not cataloged.
Inline `//` line comments are forbidden at file scope. Each file-scope `//` comment emits a `JS_LINE_COMMENT` row at its own line with `FORBIDDEN_FILE_SCOPE_LINE_COMMENT` drift attached.
### 13.2 Comment content rules
- Purpose comments are written in present-tense, descriptive style. They describe what the function/constant/state does, not why it does it.
- Section banner descriptions may be 1-5 sentences. They explain what the section contains.
- Inline body comments explain what the next statement or block of statements does. They are not required, and trivial or self-explanatory code should not carry them. Their presence is a judgment call by the author.

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
10. Use the file's prefix (`<page_prefix>_` in page files, `cc_` in `cc-shared.js`) on every top-level identifier (Section 5).
11. Declare the page prefix in every section banner of page files, and `cc` in every section banner of `cc-shared.js` (Sections 4.2, 5).
12. Match the FILE ORGANIZATION list to banner titles verbatim, in order (Section 2).
13. Declare a `<prefix>_init` top-level function as the page boot entry point (Section 11).
14. Declare per-event dispatch tables in a CONSTANTS banner when the page has page-local actions (Section 11.3).

---

## 17. Catalog model

This section covers the catalog mechanism as it relates to JS files. Every cataloged JS construct gets one row in `dbo.Asset_Registry`.

### 17.1 What the catalog represents

The catalog represents everything the parser found in the file, with drift codes telling the operator what's wrong. Forbidden patterns produce rows just like permitted ones; the difference is the drift codes attached. A clean codebase has zero rows with non-NULL `drift_codes`.

A row's identity is the combination of `component_type`, `component_name`, `reference_type`, `file_name`, `occurrence_index`, `variant_type`, `variant_qualifier_1`, and `variant_qualifier_2`.

### 17.2 JS-relevant component_type values

| component_type | Meaning |
|---|---|
| `JS_FILE` | The file-level anchor row. One row per scanned `.js` file. Serves as the universal "this file was scanned" anchor and the host for file-overall drift codes (`EXCESS_BLANK_LINES`, `FORBIDDEN_COMMENT_STYLE`, `MISSING_ENGINE_PROCESSES_DECLARATION`, `MISSING_ENGINE_CARD_FOR_REGISTERED_PROCESS`). Carries no `raw_text`, `purpose_description`, or `signature` — the row is purely structural. The same anchor-row pattern exists in the CSS, HTML, and PS populators as `CSS_FILE`, `HTML_FILE`, and `PS_FILE`. |
| `FILE_HEADER` | The parsed file-header block. One row per scanned file. Carries header-block-specific drift codes (`MALFORMED_FILE_HEADER`, `FORBIDDEN_CHANGELOG_BLOCK`, `FILE_ORG_MISMATCH`) and the header's `purpose_description`. |
| `COMMENT_BANNER` | A section banner comment. One row per section. The section type lives in `signature`. |
| `JS_IMPORT` | An ES `import` statement or Node `require` call. The imported binding name is `component_name`. The source module path is `variant_qualifier_2`. Always non-NULL `variant_type`. |
| `JS_CONSTANT` | A `const` declaration of a primitive value in a `CONSTANTS` or `FOUNDATION` section. |
| `JS_CONSTANT_VARIANT` | A `const` declaration of a compound or computed value in a `CONSTANTS` or `FOUNDATION` section. Also the row host for revealing-module wrappers (Section 15.2) and for ENGINE_PROCESSES-level drift codes (`ENGINE_PROCESS_PAGE_MISMATCH`, `ENGINE_SLUG_JS_MISMATCH`). |
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
| `JS_DISPATCH_ENTRY` | A single key-value entry within a per-event dispatch table (`<prefix>_<event>Actions` or `cc_<event>Actions`). The action value is `component_name`; the event name is `variant_qualifier_1`; the handler function name is `variant_qualifier_2`; the dispatch table variable name is `parent_function`. One row per entry. `variant_type` is NULL; the event name's placement in `variant_qualifier_1` mirrors the HTML populator's column placement for the same concept (CC_HTML_Spec.md §6.5) for cross-spec query symmetry. |
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
- JS_DISPATCH_ENTRY rows: `SHARED` when emitted from `cc-shared.js` (entries in `cc_<event>Actions` tables); `LOCAL` when emitted from page files (entries in `<prefix>_<event>Actions` tables).
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
- **Single component type, NULL `variant_type` with non-NULL qualifiers** - the discriminating value lives in `variant_qualifier_1` rather than `variant_type` because the populator must mirror the column placement of a related row type from another populator for cross-spec queryability. The current example is `JS_DISPATCH_ENTRY`, which mirrors the event-name placement of the HTML populator's `HTML_DATA_ATTRIBUTE` rows for `data-action-<event>`. Without this mirroring, every cross-spec join would have to remember which side stores the event name in which column. See Appendix A.17.

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
| `JS_HOOK` | NULL | NULL | NULL | `function bch_onPageRefresh() {}` |
| `JS_HOOK_VARIANT` | `async` | NULL | NULL | `async function bch_onPageRefresh() {}` |

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

#### JS_DISPATCH_ENTRY (NULL variant_type, event name in qualifier_1)

| component_type | variant_type | qualifier_1 | qualifier_2 | Source pattern |
|---|---|---|---|---|
| `JS_DISPATCH_ENTRY` | NULL | `click`   | handler fn name | `'open-detail': bch_openDetail` (in `bch_clickActions`) |
| `JS_DISPATCH_ENTRY` | NULL | `change`  | handler fn name | `'filter-status': bch_filterStatus` (in `bch_changeActions`) |
| `JS_DISPATCH_ENTRY` | NULL | `input`   | handler fn name | analogous |
| `JS_DISPATCH_ENTRY` | NULL | `submit`  | handler fn name | analogous |
| `JS_DISPATCH_ENTRY` | NULL | `keydown` | handler fn name | analogous |
| `JS_DISPATCH_ENTRY` | NULL | `keyup`   | handler fn name | analogous |
| `JS_DISPATCH_ENTRY` | NULL | `focus`   | handler fn name | analogous |
| `JS_DISPATCH_ENTRY` | NULL | `blur`    | handler fn name | analogous |

`component_name` is the action value (the kebab-case key from the dispatch table). `variant_qualifier_1` is the event name, derived from the dispatch table variable name (`<prefix>_<event>Actions` → lowercase event; `cc_<event>Actions` → lowercase event). `variant_qualifier_2` is the handler function name (the bare identifier referenced as the value). `parent_function` is the dispatch table variable name. The recognized event set matches CC_HTML_Spec.md §6.4. The event name is placed in `variant_qualifier_1` rather than `variant_type` to match the column placement used by the HTML populator's `HTML_DATA_ATTRIBUTE` rows for `data-action-<event>` (CC_HTML_Spec.md §6.5), keeping cross-spec join queries symmetric.

#### Component types with no variants

`FILE_HEADER`, `COMMENT_BANNER`, `JS_STATE`, `JS_CLASS`, `JS_EVENT`, `JS_IIFE`, `JS_EVAL`, `JS_DOCUMENT_WRITE`, `JS_WINDOW_ASSIGNMENT`, `JS_INLINE_STYLE`, `JS_INLINE_SCRIPT`, `JS_LINE_COMMENT` - variant columns are always NULL.

`CSS_CLASS` and `HTML_ID` rows emitted by the JS populator do not carry variant_type values.

### 17.6 Cross-populator dependencies

The JS populator's emitted rows resolve their cross-populator references against existing catalog rows at scan time. The JS populator never edits rows emitted by other populators; it reads them.

- `CSS_CLASS USAGE` rows have `scope` and `source_file` resolved against `CSS_CLASS DEFINITION` rows already in the catalog at JS-populator scan time. Per pipeline order CSS → HTML → JS → PS, CSS DEFINITION rows always exist when JS scans.
- `HTML_ID USAGE` rows resolve against `HTML_ID DEFINITION` rows already in the catalog from the HTML populator's scan. Drift code `JS_HTML_ID_UNRESOLVED` is attached to USAGE rows that don't resolve. Drift code `JS_HTML_ID_MALFORMED` is attached when the ID-string referenced from JS contains characters other than lowercase letters, digits, and hyphens, or does not begin with a recognized prefix followed by a hyphen. The recognized prefixes are the page's `cc_prefix` (page files only) and `cc` (any file). In `cc-shared.js`, only `cc-` prefixed IDs are recognized; in page files, both the page prefix and `cc-` are recognized.
- `JS_DISPATCH_ENTRY DEFINITION` rows resolve against `HTML_DATA_ATTRIBUTE DEFINITION` rows where `component_name LIKE 'data-action-%'`. Both sides store the event name in `variant_qualifier_1`; the action value lives in `component_name` on the JS side and in `variant_type` on the HTML side (the HTML side uses `component_name` for the attribute name itself). The match key for cross-spec joins is `(variant_qualifier_1, component_name)` on the JS side vs. `(variant_qualifier_1, variant_type)` on the HTML side. Unmatched JS dispatch entries do not emit drift at scan time — the entry may exist for a future HTML usage, and the HTML spec's queries (Q16.11/Q16.12) surface mismatches both directions.
- ENGINE_PROCESSES validation runs against `Orchestrator.ProcessRegistry` directly (not against another populator's rows). The four drift codes from §7.4.2 attach as described.

When the JS populator runs standalone (before the HTML populator has scanned, or against an empty Asset_Registry), HTML-side resolution lookups return empty. The populator emits a startup warning and continues; HTML_ID rows resolve to `source_file = '<undefined>'`, and dispatch entries simply don't carry HTML-cross-validation drift. Standalone runs are valid for development and testing; production pipeline runs always follow the CSS → HTML → JS → PS order.

---

## 18. What the parser extracts

| Row type | Source | Notes |
|----------|--------|-------|
| `JS_FILE DEFINITION` | The file as a whole | One per scanned file. Universal anchor row. `component_name` = bare filename. No `raw_text` or `purpose_description`. Hosts file-overall drift codes including `MISSING_ENGINE_PROCESSES_DECLARATION` and `MISSING_ENGINE_CARD_FOR_REGISTERED_PROCESS`. |
| `FILE_HEADER DEFINITION` | The opening file header block | One per file. `purpose_description` carries the header's purpose paragraph. Hosts header-block-specific drift codes. |
| `COMMENT_BANNER DEFINITION` | Each section banner | `signature` = TYPE, `component_name` = NAME, `purpose_description` = description block. |
| `JS_IMPORT DEFINITION` | Each `import` statement or `require` call | One per imported binding. `variant_type` = import shape; `variant_qualifier_2` = source module path. |
| `JS_CONSTANT DEFINITION` / `JS_CONSTANT_VARIANT DEFINITION` | Each `const` declaration in a `CONSTANTS` or `FOUNDATION` section | Base for primitive values; variant for objects, arrays, regexes, computed expressions. `purpose_description` = preceding purpose comment. The `ENGINE_PROCESSES` declaration produces a `JS_CONSTANT_VARIANT` row that also hosts `ENGINE_PROCESS_PAGE_MISMATCH` and `ENGINE_SLUG_JS_MISMATCH` drift codes. |
| `JS_STATE DEFINITION` | Each `var` declaration in a `STATE` section | `purpose_description` = preceding purpose comment. |
| `JS_FUNCTION DEFINITION` / `JS_FUNCTION_VARIANT DEFINITION` | Each top-level `function` declaration in a `FUNCTIONS` section other than `PAGE LIFECYCLE HOOKS` | Base for plain function declarations; variant for async and generator forms. `signature` = function signature with parameter names. |
| `JS_HOOK DEFINITION` / `JS_HOOK_VARIANT DEFINITION` | Each `function` declaration in the hooks banner | Base for sync hooks; variant for async hooks. |
| `JS_CLASS DEFINITION` | Each top-level class declaration | `purpose_description` = preceding purpose comment. |
| `JS_METHOD DEFINITION` / `JS_METHOD_VARIANT DEFINITION` | Each method inside a class body | Base for regular methods; variant for static/getter/setter/async forms. `parent_function` = class name. |
| `JS_TIMER DEFINITION` | Each `setInterval` / `setTimeout` call assigned to a tracked handle | `component_name` = handle name. |
| `JS_DISPATCH_ENTRY DEFINITION` | Each key-value pair within a `<prefix>_<event>Actions` or `cc_<event>Actions` object literal | `component_name` = action value (kebab-case key). `variant_qualifier_1` = event name. `variant_qualifier_2` = handler function name. `variant_type` = NULL. `parent_function` = dispatch table variable name. `scope` = LOCAL for page-side, SHARED for cc-shared.js. |
| `JS_FUNCTION USAGE` | Each call to a function defined in the same file or in `cc-shared.js` | Calls to unknown identifiers are not cataloged. |
| `JS_EVENT USAGE` | Each `addEventListener('event', ...)` call | `component_name` = event name. Hosts `FORBIDDEN_PROPERTY_ASSIGN_EVENT` drift on element-property assignments and `FORBIDDEN_PER_ELEMENT_LISTENER_LOOP` drift on per-element listener loops. |
| `CSS_CLASS USAGE` | Each class name in a template literal, classList call, or setAttribute('class', ...) | Resolved to SHARED or LOCAL via the CSS_CLASS DEFINITION map. |
| `HTML_ID DEFINITION` | Each `id="..."` in a template/string literal or `setAttribute('id', ...)` or `el.id = '...'` | LOCAL scope. |
| `HTML_ID USAGE` | Each `getElementById('...')` or `querySelector('#...')` argument | LOCAL scope. Hosts `JS_HTML_ID_UNRESOLVED` and `JS_HTML_ID_MALFORMED` drift codes per §17.6. |
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
| `MISSING_ENGINE_PROCESSES_DECLARATION` | A page that has engine cards registered in `Orchestrator.ProcessRegistry` (`run_mode = 1` with matching `cc_page_route`) lacks an `ENGINE_PROCESSES` constant declaration in its JS file. Attached to the `JS_FILE` anchor row. |
| `MISSING_ENGINE_CARD_FOR_REGISTERED_PROCESS` | `Orchestrator.ProcessRegistry` has one or more active scheduled processes (`run_mode = 1`) registered with `cc_page_route` matching this page, but the JS file's `ENGINE_PROCESSES` declaration does not include them. Attached to the `JS_FILE` anchor row. |

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
| `UNKNOWN_SECTION_TYPE` | A section banner declares a TYPE not in the enumerated list for the file kind. Page files allow IMPORTS, CONSTANTS, STATE, FUNCTIONS. cc-shared.js allows IMPORTS, FOUNDATION, STATE, BOOTLOADER, CHROME. |
| `SECTION_TYPE_ORDER_VIOLATION` | Section types appear out of the required order. |
| `MISSING_PREFIX_DECLARATION` | A section banner is missing the mandatory `Prefix:` line. |
| `MALFORMED_PREFIX_VALUE` | A section banner's `Prefix:` line declares anything other than the registered page prefix or `cc`. |
| `PREFIX_REGISTRY_MISMATCH` | A page-file section banner's declared prefix does not match `Component_Registry.cc_prefix` for the file's component. |
| `CHROME_FILE_INVALID_PREFIX` | A `cc-shared.js` section banner declares a prefix other than `cc`. |
| `DUPLICATE_FOUNDATION` | A FOUNDATION section appears in a JS file other than `cc-shared.js`. |
| `DUPLICATE_BOOTLOADER` | A BOOTLOADER section appears in a JS file other than `cc-shared.js`. |
| `DUPLICATE_CHROME` | A CHROME section appears in a JS file other than `cc-shared.js`. |
| `HOOKS_BANNER_NOT_LAST` | A `FUNCTIONS: PAGE LIFECYCLE HOOKS` banner exists but is not the last banner in the file. |

### 19.3 Definition-level codes

| Code | Description |
|---|---|
| `PREFIX_MISMATCH` | A top-level identifier name does not begin with the prefix declared in its containing section's banner. |
| `PREFIX_MISSING` | A top-level identifier does not begin with the file's prefix followed by an underscore. The file's prefix is the page prefix (page files) or `cc` (`cc-shared.js`). Independent of banners. Methods inside classes are exempt (they are namespaced within the class). |
| `MISSING_PAGE_INIT` | A page file does not contain a top-level function declaration named `<prefix>_init`, or `<prefix>_init` is declared as a `const`/`var` arrow expression rather than a `function` declaration. The bootloader cannot invoke the page without it. |
| `MISSING_FUNCTION_COMMENT` | A function definition is not preceded by a single block comment. |
| `MISSING_CONSTANT_COMMENT` | A `const` declaration in a CONSTANTS section is not preceded by a single block comment. |
| `MISSING_STATE_COMMENT` | A `var` declaration in a STATE section is not preceded by a single block comment. |
| `MISSING_CLASS_COMMENT` | A class declaration is not preceded by a single block comment. |
| `MISSING_METHOD_COMMENT` | A method inside a class body is not preceded by a single block comment. |
| `WRONG_DECLARATION_KEYWORD` | A `var` declaration appears in a CONSTANTS or FOUNDATION section, or a `const` declaration appears in a STATE section. |
| `SHADOWS_SHARED_FUNCTION` | A page file defines a function whose name matches a `cc-shared.js` export. |
| `UNKNOWN_HOOK_NAME` | A function inside the hooks banner has a suffix (the part after `<prefix>_`) not in the recognized hook set (`onPageRefresh`, `onPageResumed`, `onSessionExpired`, `onEngineProcessCompleted`, `onEngineEventRaw`). |
| `ENGINE_PROCESSES_MISPLACED` | The `<prefix>_ENGINE_PROCESSES` constant is declared outside its required `CONSTANTS: ENGINE PROCESSES` banner (§7.4.3). Attached to the declaration row (`JS_CONSTANT_VARIANT` or `JS_STATE` depending on the declaration keyword). |
| `HOOK_MISPLACED` | A function whose name matches `<prefix>_<recognized-hook-suffix>` is declared outside the `FUNCTIONS: PAGE LIFECYCLE HOOKS` banner (§8.5). Attached to the `JS_FUNCTION` row. |
| `ENGINE_PROCESS_PAGE_MISMATCH` | A `<prefix>_ENGINE_PROCESSES` entry references a process whose `cc_page_route` does not match the page hosting this JS file. Attached to the `JS_CONSTANT_VARIANT` row. |
| `ENGINE_SLUG_JS_MISMATCH` | A `<prefix>_ENGINE_PROCESSES` entry's `slug` value does not match `cc_engine_slug` for the corresponding process in `Orchestrator.ProcessRegistry`. Attached to the `JS_CONSTANT_VARIANT` row. |
| `UNRESOLVED_DISPATCH_HANDLER` | A dispatch table entry references a handler function name that is not defined in the same file. Attached to the `JS_DISPATCH_ENTRY` row. |
| `MALFORMED_ACTION_KEY` | A dispatch table key contains characters other than lowercase letters, digits, and hyphens; or a page-side table key begins with `cc-`; or a chrome table key does not begin with `cc-`. Attached to the `JS_DISPATCH_ENTRY` row. |
| `JS_HTML_ID_UNRESOLVED` | A `getElementById` or `querySelector('#...')` reference uses an ID-string argument that does not resolve to any `HTML_ID DEFINITION` row in the catalog at JS-populator scan time. Attached to the `HTML_ID USAGE` row. |
| `JS_HTML_ID_MALFORMED` | An HTML ID string referenced from JS contains characters other than lowercase letters, digits, and hyphens, or does not begin with a recognized prefix followed by a hyphen. Recognized prefixes are the page's `cc_prefix` (page files only) and `cc` (any file). Attached to the `HTML_ID USAGE` row. |

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
| `BLANK_LINE_INSIDE_FUNCTION_BODY_AT_SCOPE` | More than one consecutive blank line appears inside a top-level function declaration's body. The rule is scoped to top-level `function name() {}` declarations only; methods inside classes are out of scope. See Appendix A.19. |
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

Which pages implement which hooks? Hook function names are `<prefix>_<suffix>`; this query matches on the suffix.

```sql
SELECT
    file_name AS page_file,
    SUM(CASE WHEN component_name LIKE '%_onPageRefresh'            THEN 1 ELSE 0 END) AS has_onPageRefresh,
    SUM(CASE WHEN component_name LIKE '%_onPageResumed'            THEN 1 ELSE 0 END) AS has_onPageResumed,
    SUM(CASE WHEN component_name LIKE '%_onSessionExpired'         THEN 1 ELSE 0 END) AS has_onSessionExpired,
    SUM(CASE WHEN component_name LIKE '%_onEngineProcessCompleted' THEN 1 ELSE 0 END) AS has_onEngineProcessCompleted,
    SUM(CASE WHEN component_name LIKE '%_onEngineEventRaw'         THEN 1 ELSE 0 END) AS has_onEngineEventRaw
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

### 20.7 Q7 - Dispatch entry inventory by page

For one specific page, list every dispatch entry it defines, grouped by event.

```sql
SELECT
    parent_function       AS dispatch_table,
    variant_qualifier_1   AS event_name,
    component_name        AS action_value,
    variant_qualifier_2   AS handler_function,
    line_start
FROM dbo.Asset_Registry
WHERE file_type      = 'JS'
  AND file_name      = '<filename.js>'
  AND component_type = 'JS_DISPATCH_ENTRY'
  AND reference_type = 'DEFINITION'
ORDER BY variant_qualifier_1, line_start;
```

### 20.8 Q8 - Dispatch entries with unresolved handlers

Find every dispatch entry whose handler function name doesn't resolve to a function defined in the same file. Surfaces broken dispatch wiring.

```sql
SELECT
    de.file_name,
    de.parent_function       AS dispatch_table,
    de.variant_qualifier_1   AS event_name,
    de.component_name        AS action_value,
    de.variant_qualifier_2   AS missing_handler,
    de.line_start
FROM dbo.Asset_Registry de
LEFT JOIN dbo.Asset_Registry fn
       ON  fn.file_name      = de.file_name
       AND fn.component_name = de.variant_qualifier_2
       AND fn.component_type IN ('JS_FUNCTION', 'JS_FUNCTION_VARIANT')
       AND fn.reference_type = 'DEFINITION'
WHERE de.file_type      = 'JS'
  AND de.component_type = 'JS_DISPATCH_ENTRY'
  AND de.reference_type = 'DEFINITION'
  AND fn.component_name IS NULL
ORDER BY de.file_name, de.line_start;
```

### 20.9 Q9 - ENGINE_PROCESSES vs. ProcessRegistry coverage

Find pages where the JS-declared ENGINE_PROCESSES set differs from the ProcessRegistry-registered set. Surfaces engine card definitions that are out of sync between the two sources of truth.

```sql
WITH js_engine_processes AS (
    SELECT
        file_name,
        CHARINDEX('-', file_name) AS first_dash,
        file_name AS js_file
    FROM dbo.Asset_Registry
    WHERE file_type      = 'JS'
      AND component_type = 'JS_CONSTANT_VARIANT'
      AND component_name = 'ENGINE_PROCESSES'
      AND reference_type = 'DEFINITION'
),
registry_processes AS (
    SELECT
        cc_page_route,
        process_name,
        cc_engine_slug,
        cc_engine_label
    FROM Orchestrator.ProcessRegistry
    WHERE run_mode = 1
      AND cc_page_route IS NOT NULL
)
SELECT
    rp.cc_page_route,
    rp.process_name,
    rp.cc_engine_slug,
    rp.cc_engine_label
FROM registry_processes rp
ORDER BY rp.cc_page_route, rp.process_name;
```

(The full reconciliation join — comparing each JS file's ENGINE_PROCESSES entries to the registry's process list for that page's route — is performed by the JS populator at scan time and emits the drift codes from §19.1 and §19.3.)

---

## 21. Examples

### 21.1 Minimal complete page file

A small page demonstrating every required pattern under the bootloader-driven model. Real pages have more sections.

```javascript
/* ============================================================================
   xFACts Control Center - Example Page (example.js)
   Location: E:\xFACts-ControlCenter\public\js\example.js
   Version: Tracked in dbo.System_Metadata (component: ExampleModule.ExamplePage)

   Page-specific JavaScript for the Example dashboard. Declares its
   engine-processes contract with cc-shared.js, defines page-local
   dispatch tables for delegated event routing, and registers the
   mandatory <prefix>_init page boot function consumed by the
   cc-shared.js bootloader.

   FILE ORGANIZATION
   -----------------
   CONSTANTS: ENGINE PROCESSES
   CONSTANTS: PAGE CONFIGURATION
   CONSTANTS: DISPATCH TABLES
   STATE: PAGE STATE
   FUNCTIONS: PAGE BOOT
   FUNCTIONS: DATA LOADING
   FUNCTIONS: RENDERING
   FUNCTIONS: ACTION HANDLERS
   FUNCTIONS: PAGE LIFECYCLE HOOKS
   ============================================================================ */


/* ============================================================================
   CONSTANTS: ENGINE PROCESSES
   ----------------------------------------------------------------------------
   Maps process names registered in Orchestrator.ProcessRegistry to their
   engine card slugs. Read by cc-shared.js via computed-name lookup
   (window[pageKey + '_ENGINE_PROCESSES']).
   Prefix: ex
   ============================================================================ */

/* Engine processes this page cares about, mapped to engine card slugs. */
const ex_ENGINE_PROCESSES = {
    'Collect-ExampleStatus': { slug: 'example' }
};


/* ============================================================================
   CONSTANTS: PAGE CONFIGURATION
   ----------------------------------------------------------------------------
   Static configuration values for the example page.
   Prefix: ex
   ============================================================================ */

/* Default polling interval in seconds; overridden by GlobalConfig on load. */
const ex_DEFAULT_REFRESH_INTERVAL = 10;


/* ============================================================================
   CONSTANTS: DISPATCH TABLES
   ----------------------------------------------------------------------------
   Per-event dispatch tables consumed by the delegated event listeners
   registered in ex_init. Each table maps page-local data-action-<event>
   values to handler functions. Shared cc-* actions are handled by
   cc-shared.js and never appear here.
   Prefix: ex
   ============================================================================ */

/* Page-local click action dispatch table. */
const ex_clickActions = {
    'view-agent-detail': ex_viewAgentDetail,
    'refresh-section':   ex_refreshSection
};

/* Page-local change action dispatch table. */
const ex_changeActions = {
    'filter-agents': ex_filterAgents
};


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
   FUNCTIONS: PAGE BOOT
   ----------------------------------------------------------------------------
   The mandatory <prefix>_init function called by the cc-shared.js
   bootloader after this module loads. Performs one-time page setup,
   connects to the engine event stream, and registers per-event delegated
   listeners that route page-local actions to the dispatch tables.
   Prefix: ex
   ============================================================================ */

/* Page boot function. Called by the cc-shared.js bootloader after this
   module is loaded. Loads configuration, performs the initial render,
   wires the engine subsystem, and registers delegated event listeners. */
async function ex_init() {
    await ex_loadConfig();
    ex_refreshAll();
    connectEngineEvents();

    /* Delegated listeners for page-local actions. */
    document.body.addEventListener('click', ex_handleClickAction);
    document.body.addEventListener('change', ex_handleChangeAction);
}


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
    return '<div class="ex-agent-card" data-action-click="view-agent-detail" ' +
           'data-action-agent-id="' + agent.id + '">' +
           '<span class="ex-agent-name">' + escapeHtml(agent.name) + '</span>' +
           '</div>';
}


/* ============================================================================
   FUNCTIONS: ACTION HANDLERS
   ----------------------------------------------------------------------------
   Delegated dispatchers for page-local data-action-<event> values plus
   the handler functions referenced from the dispatch tables.
   Prefix: ex
   ============================================================================ */

/* Delegated dispatcher for page-local click actions. */
function ex_handleClickAction(event) {
    const target = event.target.closest('[data-action-click]');
    if (!target) return;
    const action = target.getAttribute('data-action-click');
    if (!action || action.indexOf('cc-') === 0) return;
    const handler = ex_clickActions[action];
    if (!handler) {
        console.warn('[ex] Unknown page click action: ' + action);
        return;
    }
    handler(target, event);
}

/* Delegated dispatcher for page-local change actions. */
function ex_handleChangeAction(event) {
    const target = event.target.closest('[data-action-change]');
    if (!target) return;
    const action = target.getAttribute('data-action-change');
    if (!action || action.indexOf('cc-') === 0) return;
    const handler = ex_changeActions[action];
    if (!handler) {
        console.warn('[ex] Unknown page change action: ' + action);
        return;
    }
    handler(target, event);
}

/* Handler for view-agent-detail clicks. Opens the agent detail slideout. */
function ex_viewAgentDetail(target, event) {
    const agentId = target.dataset.actionAgentId;
    /* ... open slideout with agent details ... */
}

/* Handler for refresh-section clicks. Re-fetches data for a specific section. */
function ex_refreshSection(target, event) {
    /* ... */
}

/* Handler for filter-agents changes. Updates the current filter and re-renders. */
function ex_filterAgents(target, event) {
    ex_currentFilter = target.value;
    ex_refreshAll();
}


/* ============================================================================
   FUNCTIONS: PAGE LIFECYCLE HOOKS
   ----------------------------------------------------------------------------
   Callbacks invoked by cc-shared.js via computed-name lookup
   (window[pageKey + '_<hookSuffix>']). The hook suffixes are platform
   contracts; the page prefix carries the page's identity.
   Prefix: ex
   ============================================================================ */

/* Manual refresh handler - re-fetches all sections. */
function ex_onPageRefresh() {
    ex_refreshAll();
}

/* Tab regained visibility - refresh live data. */
function ex_onPageResumed() {
    ex_refreshAll();
}
```

This file produces the following catalog rows when parsed:

- 1 x `JS_FILE DEFINITION`
- 1 x `FILE_HEADER DEFINITION`
- 9 x `COMMENT_BANNER DEFINITION` (one per section)
- 1 x `JS_CONSTANT_VARIANT DEFINITION` (`ex_ENGINE_PROCESSES`, variant_type='object')
- 1 x `JS_CONSTANT DEFINITION` (`ex_DEFAULT_REFRESH_INTERVAL`)
- 2 x `JS_CONSTANT_VARIANT DEFINITION` (`ex_clickActions` and `ex_changeActions`, variant_type='object')
- 3 x `JS_DISPATCH_ENTRY DEFINITION` (`view-agent-detail` and `refresh-section` under `ex_clickActions`; `filter-agents` under `ex_changeActions`)
- 2 x `JS_STATE DEFINITION` (`ex_currentFilter`, `ex_livePollingTimer`)
- 2 x `JS_FUNCTION_VARIANT DEFINITION` (`ex_init` and `ex_loadConfig`, both variant_type='async')
- 8 x `JS_FUNCTION DEFINITION` (`ex_refreshAll`, `ex_loadAgents`, `ex_renderAgents`, `ex_buildAgentCard`, `ex_handleClickAction`, `ex_handleChangeAction`, `ex_viewAgentDetail`, `ex_refreshSection`, `ex_filterAgents`)
- 2 x `JS_HOOK DEFINITION` (`ex_onPageRefresh`, `ex_onPageResumed`)
- 2 x `JS_EVENT USAGE` (the delegated click listener and the delegated change listener)

Zero drift rows expected.

---

## Appendix - Rationale

This appendix explains why selected rules are what they are. Entries are keyed to body section numbers. Sections without entries here have no rationale beyond the rule itself.

### A.3 Section banners

The 76-character rule for both `=` rule lines and `-` separator lines is a fixed value rather than a range. A fixed length makes banners visually uniform across the codebase. The chosen value (76) fits within an 80-column convention with margin for `/* ` and ` */` comment delimiters.

### A.4 Section types

`FOUNDATION`, `BOOTLOADER`, and `CHROME` belong only in `cc-shared.js` because they are platform-wide constructs. CSS has the same constraint via the anchor-file rule (`CC_CSS_Spec.md` §4.3); JS reuses the same model with `cc-shared.js` as the platform's single anchor file for shared JS constructs.

`BOOTLOADER` is conceptually distinct from `CHROME` because of its lifecycle role. Chrome utilities (the connection banner, the engine card system, the shared fetch wrapper, modals, formatting helpers) are *consumed by* pages — pages call them. The bootloader does the inverse: it *consumes* the page by fetching the page's JS module and invoking the page's `<prefix>_init` function. The bootloader runs first, before any chrome utility runs, before any page code exists in the browser. Giving it its own section type makes that ordering visible in the file structure and queryable in the catalog (`WHERE section_type = 'BOOTLOADER'`).

### A.5 Prefix

The single-prefix-per-file rule reflects that a file represents one CC page (or the shared resource), and each page has exactly one registered prefix.

The registry validation rule (§5.3) makes `Component_Registry.cc_prefix` the source of truth for which prefix belongs to which page. Before the registry existed, the prefix was declared only in the file header and could drift from the platform's understanding silently. Pinning each file's prefix to its component row in the registry surfaces drift as queryable catalog rows.

The `PREFIX_MISSING` rule (§5.4) extends the prefix discipline to identifiers themselves, independent of banners. Banner-anchored `PREFIX_MISMATCH` is silent on a file with no banners; `PREFIX_MISSING` closes that gap and ensures every top-level identifier is checked against the file's prefix regardless of whether banners are in place.

The elimination of the `Prefix: (none)` sentinel and the platform-token / 3-character constraints follows the same model as the CSS spec (CC_CSS_Spec.md §5 and Appendix A.5). The prefix system has two forms — page prefix or `cc` — and the registry governs which value a page-file uses. The spec does not constrain prefix shape; that lives with whoever assigns prefixes in the registry.

### A.5 (cont.) Unified prefix model

Every top-level JS identifier carries the file's prefix per §5.4 — `<page_prefix>_` for page files, `cc_` for `cc-shared.js`. No carve-outs, no exemption lists, no contract identifiers that escape the rule. This produces three benefits.

First, reading any JS identifier tells the reader where it lives: `bch_onPageRefresh` is in the batch-monitoring page; `cc_loadPageModule` is in `cc-shared.js`. No identifier requires lookup to know its source.

Second, the bootloader's calling convention is uniform: cc-shared.js looks up page-module references via computed name (`window[pageKey + '_<name>']`). The same pattern resolves `<prefix>_init`, `<prefix>_ENGINE_PROCESSES`, `<prefix>_onPageRefresh`, and every other page-side identifier cc-shared.js needs to call. There is no special case for hooks vs. init vs. constants — every reference uses the same lookup.

Third, the spec has no exemption list to maintain. Future hooks or platform-recognized identifiers added later automatically follow the prefix rule; no list edit is required and no audit of prefix-check sites is needed.

The `_MISPLACED` drift codes (`ENGINE_PROCESSES_MISPLACED`, `HOOK_MISPLACED`) survive the unified-prefix change because they validate banner placement, not identifier naming. A hook function whose name is `bch_onPageRefresh` is correctly named regardless of which banner it sits in; the `HOOK_MISPLACED` code fires when the hook is in the wrong banner. The placement check is by full `<TYPE>: <NAME>` banner identity.

The placement codes are independent of `WRONG_DECLARATION_KEYWORD`. A file with `var bch_ENGINE_PROCESSES` inside the correct banner fires `WRONG_DECLARATION_KEYWORD` but not `ENGINE_PROCESSES_MISPLACED`. A file with `const bch_ENGINE_PROCESSES` in a STATE section fires `ENGINE_PROCESSES_MISPLACED` but not `WRONG_DECLARATION_KEYWORD`. Both fire together when the declaration is in the wrong section with the wrong keyword.

Each misplaced hook fires its own row's drift code, so a file with three hooks declared outside the hooks banner produces three separate `HOOK_MISPLACED` firings on three separate `JS_FUNCTION` rows. Misplaced hook functions are catalogued as `JS_FUNCTION DEFINITION` (not `JS_HOOK DEFINITION`); only functions inside the hooks banner produce `JS_HOOK` rows. The catalog reflects what the file actually does; the drift code tells refactor work where the function should move.

### A.6 Function definitions

The single-form rule for function declarations exists to make the catalog's function row count predictable. If functions could be declared as `const name = function() {}` or `const name = () => {}`, the parser would have to either treat those as JS_FUNCTION rows (conflating const declarations with function declarations) or as JS_CONSTANT_VARIANT rows (making "list all functions" require a JOIN between two component types). One form means one row type. The narrow callback exception preserves natural JS idioms (`addEventListener('click', function() { ... })`) without compromising the catalog's clarity.

### A.7 Constants and state

The `const` vs `var` split by section reflects the semantic distinction. CONSTANTS are immutable; STATE mutates over the page's lifetime. Forcing the keyword to match the section makes the file's structure self-documenting: a reader skimming the STATE section knows everything in it can change at runtime; everything in CONSTANTS or FOUNDATION cannot.

`let` is forbidden because it adds a third declaration kind without adding semantic value over `const` and `var`. The two-kind discipline keeps the spec's section-keyword mapping clean.

### A.7.4 Engine processes validation

The four ENGINE_PROCESSES drift codes (§7.4.2) cross between the JS file and `Orchestrator.ProcessRegistry`. The validation lives in the JS spec rather than the HTML spec because the JS file declares the contract — `ENGINE_PROCESSES` is a JS constant — and the drift attaches to JS rows (the `JS_FILE` anchor for declaration presence/coverage, the `JS_CONSTANT_VARIANT` row for entry-level mismatches). The HTML spec catalogs the on-page engine card markup separately (`HTML_ID` rows for `card-engine-<slug>` etc.) and has its own engine-card drift codes that validate against ProcessRegistry from the HTML side.

Splitting the validation surface across the two specs reflects that engine cards have two anchors in the codebase — the JS contract declaration and the HTML chrome markup — and both can drift independently from the registry. Catching each from its own side surfaces precise refactor work: a `MISSING_ENGINE_PROCESSES_DECLARATION` says "fix the JS file"; a `MISSING_ENGINE_CARD_REGISTRATION` (HTML spec §2.3) says "fix ProcessRegistry."

### A.8 Page lifecycle hooks

The hooks-banner-last rule produces a stable file-scanning experience. A reader looking for "this page's contract with cc-shared.js" knows exactly where to find it (last banner in the file).

Hook function names follow the unified prefix rule: `<prefix>_<hookSuffix>`. The page prefix carries the page's identity; the hook suffix carries the platform's role. cc-shared.js resolves hooks via computed-name lookup (`window[pageKey + '_<hookSuffix>']`) — the same pattern used for `<prefix>_init` and every other page-module reference. The bootloader probes each known hook suffix; pages that don't implement a given hook simply lack the corresponding identifier and the probe skips it.

The `HOOK_MISPLACED` rule (§8.5) is independent of identifier naming. A correctly named hook function (`bch_onPageRefresh`) declared outside the hooks banner fires `HOOK_MISPLACED` — refactor work moves the function into the right banner. The drift code carries the structural signal the populator can give.

### A.11 Page boot

The `<prefix>_init` function exists as the single platform entry point each page exposes to the bootloader. A fixed, derivable name (`<prefix>` plus `_init`) lets the bootloader resolve the entry point without per-page configuration — every page has exactly one, every page names it the same way, and the bootloader knows where to find it.

The top-level `function` declaration requirement (rather than allowing `const ex_init = () => {}` or `var ex_init = function() {}`) exists because the bootloader looks the function up via `window[pageKey + '_init']`. Top-level `function` declarations attach to `window` automatically; `const` and `var` declarations do not. Allowing the arrow-expression form would break the bootloader silently — the page would load, no error would fire, but `<prefix>_init` would never run.

Keeping `<prefix>_init` in the `FUNCTIONS` section (rather than giving it its own section type, mirroring the legacy `INITIALIZATION`) reflects that the page boot function is structurally just another function. It produces the same `JS_FUNCTION DEFINITION` or `JS_FUNCTION_VARIANT DEFINITION` row in the catalog as any other function; its specialness lives in the bootloader's runtime behavior, not in the file's structural anatomy.

### A.11.3 Dispatch tables

The per-event dispatch table pattern (§11.3) is the page-side half of the bootloader-driven event routing model. The HTML side declares actions on elements via `data-action-<event>` attributes; the JS side declares handlers in `<prefix>_<event>Actions` (page files) or `cc_<event>Actions` (cc-shared.js) object literals; the bootloader's delegated listeners (in cc-shared.js for `cc-*` actions) and the page's own delegated listeners (registered in `<prefix>_init` for page-local actions) route at runtime.

The event-name-per-table design (one table per event type rather than one table with event-keyed entries) reflects how the per-event delegated listeners need to look up handlers. A `click` event handler should examine only click-action mappings; it should never see `change` or `keydown` entries. Per-event tables make that scoping mechanical rather than requiring runtime filtering inside the dispatcher.

Both page-side and chrome-side tables follow the same naming pattern (`<prefix>_<event>Actions`, lowercase event), differing only in the prefix value (`bch_` vs `cc_`). The unified naming gives the catalog symmetric row shapes and makes cross-table queries straightforward. The word `shared` is not in the chrome table names — the `cc_` prefix already conveys "shared chrome."

The `cc-` reservation on action keys gives the runtime a structural test for routing: any `data-action-<event>` value starting with `cc-` belongs to the chrome dispatcher; any other value belongs to the page's own dispatcher. The page-side dispatcher checks `action.indexOf('cc-') === 0` and returns early on a match, ensuring chrome actions are never double-handled. This separation lets pages add page-local actions without worrying about colliding with future chrome actions.

### A.12 Event handler binding

Event delegation is canonical because it survives re-rendering. CC pages render and re-render their content as data updates; a delegated listener attached at page boot to a stable parent survives every subsequent re-render without rebinding. Direct binding requires the page author to remember to rebind after every render. That is a footgun the spec avoids by mandating delegation as the default.

The carve-outs in §12.2 are deliberately narrow. Each represents a case where the canonical pattern is mechanically inapplicable, not where it is pragmatically suboptimal:

- **Singleton elements** (carve-out 1) exist exactly once on the page and are not subject to re-rendering. They have no related siblings the listener could be delegated across; the only available delegation parent is the page's root or `document.body`, which would funnel every page-level click through one global router. Direct binding on the singleton itself is structurally cleaner.
- **Window/document-level events** (carve-out 2) bind to the top of the DOM tree. There is no parent to delegate from. The "delegation" pattern and the "direct binding" pattern collapse to the same thing here: `window.addEventListener('resize', handler)`.

The form-input case is covered by delegation, not by a carve-out. A form is a stable parent; its inputs are reachable via `event.target.matches('#...')` or `event.target.matches('[name=...]')`. The handler routes per-input via that check. This trades a small amount of routing boilerplate for consistency with the canonical pattern across every other binding case in the file. The trade is worth it because the initiative's premise is that there is one way to do this; carve-outs erode that premise unless they represent a structural inapplicability of the canonical form, which the form case does not.

The `FORBIDDEN_PER_ELEMENT_LISTENER_LOOP` drift code targets the dominant anti-pattern: a `forEach` over rendered list/grid elements that calls `addEventListener` on each. This shape is mechanically detectable at the AST level — a loop containing an `addEventListener` call on a per-iteration element — and represents the most common authoring mistake delegation prevents. The drift fires on the JS_EVENT row inside the loop, with the `parent_function` column carrying the enclosing function name so the operator can locate the rebind site.

The carve-out rule is an authoring rule. The parser cannot in general distinguish a legitimate singleton-element direct binding from a misapplied direct binding to an element that should have been delegated; both look identical at the AST level. This is the same shape as other authoring rules in the spec — §6.1 (function comment quality), §7.2 (case distinction in constant naming), §13 (sub-section marker vs new banner judgment), §14 (banner authoring discipline). The pattern is consistent: the spec sets the rule; the parser catches what it can; humans catch the rest. The catalog still surfaces useful signal — a high `JS_EVENT` row count on a page is a flag for review even when the populator cannot auto-classify each row.

### A.13 Comments

The five allowed comment kinds correspond to the spec's structural concerns at three levels:

- The file (header), the sections that organize it (banners), and the definitions inside those sections (purpose comments) all have structural identity that the spec already enumerates. Comments at these levels serve a clear documentation role tied to the structural element they accompany.
- Inside a function body, individual statements and sub-groups of statements are content the spec does not enumerate. Authors routinely need to explain "this block does X" or "the next three lines handle the Y case." Permitting inline body comments here acknowledges that function bodies are the content layer where author judgment about clarity matters, and that forbidding explanatory comments inside functions would degrade readability without serving any spec concern.
- Top-level expression statements (the bootloader's `document.addEventListener('DOMContentLoaded', ...)` is the canonical case) do not have the same declaration shape as functions or constants but still introduce named platform behavior. A purpose comment immediately above such a statement is permitted on the same principle as for declarations: the author is documenting a structurally significant element.

The five-kind taxonomy intentionally treats inline body comments as optional rather than required. A trivial three-line function does not need them; a 50-line function with five logical sub-operations clearly benefits from them. The choice belongs to the author.

### A.15 Forbidden patterns

The dedicated component_type rows for forbidden patterns (JS_IIFE, JS_EVAL, JS_DOCUMENT_WRITE, etc.) exist because these patterns have no natural declaration row to host the drift. An IIFE doesn't have a name; eval doesn't have a binding. The dedicated row gives every forbidden-pattern occurrence a queryable catalog presence regardless of where in the source it appears.

The revealing-module pattern (`const X = (function(){...})()`) is treated as a forbidden wrapper rather than a forbidden construct because it does have a natural host — the const or var declaration that binds the IIFE result to a name. The wrapper row carries the drift; the inner functions are not cataloged because they have no spec-equivalent identity. This parallels how the top-level IIFE is handled, with the JS_IIFE row hosting the drift in that case. The two patterns share a common diagnosis: the file's design is structurally non-spec and requires rewriting, not in-place repair.

### A.17 Catalog model — JS_DISPATCH_ENTRY

The per-entry row design for dispatch tables (one `JS_DISPATCH_ENTRY` row per key-value pair, rather than one row per whole table) makes per-action queries directly answerable. "Which page handles `data-action-click="open-detail"`?" becomes `WHERE component_type = 'JS_DISPATCH_ENTRY' AND component_name = 'open-detail'`. "Show every dispatch entry that routes to `bch_openDetail`" becomes `WHERE variant_qualifier_2 = 'bch_openDetail'`. The whole-table-row alternative would have required parsing the row's `raw_text` or signature to answer those questions, which the catalog deliberately avoids.

The column shape places the event name in `variant_qualifier_1` and leaves `variant_type` NULL. This is a deliberate departure from the variant-model patterns used by other always-non-NULL-`variant_type` types in the spec (JS_TIMER, JS_IMPORT). The departure exists because cross-spec query symmetry is more valuable here than intra-row variant-model tidiness.

The HTML populator's `HTML_DATA_ATTRIBUTE` rows for `data-action-<event>` attributes already place the event name in `variant_qualifier_1` (CC_HTML_Spec.md §6.5). The HTML side has no choice in this — `variant_type` is already occupied by the action value, because the HTML side's `component_name` carries the attribute name itself (e.g., `data-action-click`), leaving `variant_type` as the only available column for the action value. The event name is forced into `variant_qualifier_1` as the remaining slot.

On the JS side, both `component_name` and `variant_type` are theoretically available — the JS side catalogs a dispatch table entry where `component_name` naturally takes the action value (the kebab-case key) and the action value can't live in two places. Placing the event name in `variant_type` was the original choice for intra-row tidiness, but the result was that the same conceptual identifier (the event name) lived in different columns on the two sides, and every cross-spec join had to remember which side stores it where. Symmetric column placement — both sides put the event name in `variant_qualifier_1` — eliminates that asymmetry. Cross-spec joins read cleanly as `ON h.variant_qualifier_1 = j.variant_qualifier_1`.

The action value's placement remains asymmetric — `component_name` on the JS side, `variant_type` on the HTML side — but that asymmetry is structurally unavoidable. The two populators catalog different source constructs (an object literal entry vs. an HTML attribute), and there is no way to fit the action value into the same column on both sides without misrepresenting one populator's natural row shape.

`variant_qualifier_2` holds the handler function name to support reverse lookups — finding every action that targets a given handler. This is a frequently-needed query during refactoring (when renaming a handler, find every dispatch entry that references it). Storing the handler name on the entry row makes the lookup a direct equality check rather than a join through `raw_text` parsing.

`parent_function` carries the dispatch table variable name (`bch_clickActions`, `cc_clickActions`) so queries can aggregate by table — "list every action in `bch_clickActions`" or "compare entries between `bch_clickActions` and `cc_clickActions`" become straightforward.

### A.17.6 Cross-populator dependencies

The cross-populator resolution model for JS rows mirrors the HTML populator's read-only model from CC_HTML_Spec.md §13.6. The JS populator reads from upstream populators' DEFINITION rows but never edits them. CSS_CLASS USAGE rows resolve against existing CSS_CLASS DEFINITION rows from the CSS populator; HTML_ID USAGE rows resolve against existing HTML_ID DEFINITION rows from the HTML populator.

The JS_DISPATCH_ENTRY resolution is symmetric to the HTML-side `data-action-<event>` resolution: HTML emits `HTML_DATA_ATTRIBUTE DEFINITION` rows for each attribute; JS emits `JS_DISPATCH_ENTRY DEFINITION` rows for each table entry; cross-spec queries (HTML spec Q16.11/Q16.12) surface mismatches in both directions. Per the JS spec's scan-time-only resolution principle (no post-pipeline pass, no orchestrator sweep — see §17.6), the JS populator emits dispatch entry rows without attaching cross-spec drift codes; the HTML spec's queries do the cross-check at query time. This keeps the populator's responsibility crisp: each populator validates its own file against its spec; cross-spec consistency is observable via the catalog.

The `JS_HTML_ID_UNRESOLVED` and `JS_HTML_ID_MALFORMED` drift codes are JS-spec-side because the violation is in the JS file's reference (the wrong string, the malformed ID format). They attach to the `HTML_ID USAGE` row at JS scan time when HTML DEFINITION rows are present in the catalog; in standalone JS-only runs, the validation suppresses and emits a startup warning, matching the same pattern the CSS resolution uses today.

### A.19 Drift codes — banner granularity

The §19.2 banner code set is intentionally granular rather than coarse. A single combined code would collapse every kind of banner non-conformance into one verdict, which makes refactor work hard to triage — a reader could not tell from the code alone whether the banner had the wrong rule-line length, was missing a description, used an inline shape, or had a malformed title line. Each granular code (`BANNER_INVALID_RULE_LENGTH`, `BANNER_INLINE_SHAPE`, `BANNER_MISSING_DESCRIPTION`, etc.) describes exactly one violation, allowing precise queries like "find every banner with the wrong rule length" or "list every inline-shape banner candidate for refactor." A non-conformant banner may carry several granular codes simultaneously when it violates multiple rules.

### A.19 (cont.) Drift codes — function-body blank-line scope

The `BLANK_LINE_INSIDE_FUNCTION_BODY_AT_SCOPE` rule (§19.5) is intentionally scoped to top-level `function name() {}` declarations only. Methods inside class bodies are deliberately excluded for now.

The reasoning is that the spec's broader "inside function body" allowances (e.g., §13.1 permitting inline `//` line comments inside function bodies) are framed in the context of top-level functions, not class methods. Class methods are also not currently used anywhere in the codebase, so making the scope narrow-by-default is low-risk. The decision is left open for future revisit: if class methods become common, the rule can be broadened to cover their bodies as well, with the populator attaching the drift code to the relevant `JS_METHOD` / `JS_METHOD_VARIANT` row in place of (or in addition to) the function row it targets today.

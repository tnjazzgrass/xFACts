# Control Center JavaScript File Format Specification

**Status:** `[DRAFT — pending populator validation]`
**Owner:** Dirk

> Part of the Control Center File Format initiative. For initiative direction, current state, session log, and the platform-wide prefix registry, see `CC_Initiative.md`.

---

## Purpose

This specification defines the structural conventions every Control Center JavaScript file must follow. The conventions exist for one reason: **machine readability**. Every rule in this document is justified by a specific extraction the catalog parser performs against the file. Files that follow the spec parse cleanly into `dbo.Asset_Registry` without ambiguity. Files that don't follow the spec fail with a specific compliance code pointing at the violation.

The spec is intentionally opinionated and rigid. There is no allowance for stylistic drift. Authoring discipline is what makes the catalog reliable, and the catalog is what makes drift detection possible.

---

## 1. Required structure

A JavaScript file consists of three parts in this exact order:

1. **File header** — a single block comment opening at line 1, ending with `*/` followed by exactly one blank line.
2. **Section bodies** — one or more sections, each consisting of a section banner followed by the declarations and statements that section contains.
3. **End-of-file** — the file ends after the last meaningful statement of the last section. No trailing content.

Every line of code in the file lives inside exactly one of these three parts. There is no other content category. The strict three-part structure is what lets the parser walk a file deterministically: the parse position is always either reading the header, reading inside a section, or done.

---

## 2. File header

The header is a single block comment at the very top of the file. Every field is mandatory and appears in this exact order:

```javascript
/* ============================================================================
   xFACts Control Center - <Component Description> (<filename>)
   Location: E:\xFACts-ControlCenter\public\js\<filename>
   Version: Tracked in dbo.System_Metadata (component: <Component>)

   <Purpose paragraph: 1 to 5 sentences describing what this file is.>

   FILE ORGANIZATION
   -----------------
   <Section banner title 1>
   <Section banner title 2>
   <Section banner title N>
   ============================================================================ */
```

### 2.1 Header rules

- The header is the only construct that may appear before the first section banner. Anything else above the first banner — stray comments, blank lines beyond the single mandatory blank, or executable code — is a parse error.
- The closing `*/` is followed by **exactly one** blank line, then the first section banner.
- The Component Description and Component values come from `dbo.System_Metadata` and `dbo.Component_Registry` respectively. The parser extracts the description as `purpose_description` on the FILE_HEADER row.
- **No CHANGELOG block.** Git is the source of truth for change history. CHANGELOG blocks duplicate what git already provides and create drift between the two records.
- **The FILE ORGANIZATION list must match the section banner titles in the file body, verbatim, in order.** Each list entry is exactly the `<TYPE>: <NAME>` of one banner. No abstractions, no shortenings, no descriptions. The parser cross-validates the list against the banners and emits `FILE_ORG_MISMATCH` if they diverge in content or order. Verbatim matching makes the FILE ORGANIZATION list a real table of contents — a reader sees the section titles in the list and can navigate to them by exact-string search.
- The list is unnumbered. Trailing `-- <description>` text on list entries is permitted and stripped by the parser before comparison; it is not part of the canonical match.

### 2.2 Why a block comment instead of `//` line comments

JavaScript permits both `/* */` block comments and `//` line comments at file scope. The spec mandates a block comment for the file header for two reasons. First, the parser receives the header as a single `Block` comment AST node — detection is trivially "is the first node of the source a block comment in the right shape," with no need to coalesce a run of consecutive line comments. Second, the format mirrors `CC_CSS_Spec.md` Section 2 verbatim, so the same authoring habits apply across both file types.

---

## 3. Section banners

Each section opens with a banner — a multi-line block comment with strict format:

```javascript
/* ============================================================================
   <TYPE>: <NAME>
   ----------------------------------------------------------------------------
   <Description: 1 to 5 sentences describing what's in this section.>
   Prefix: <prefix>
   ============================================================================ */
```

### 3.1 Banner format rules

- The opening and closing `=` rules each consist of `=` characters of any length ≥ 5; the parser does not enforce a fixed character count.
- The middle `-` rule separates the title line from the description block.
- `<TYPE>` must be one of the recognized section types (Section 4). The TYPE token is uppercase letters and underscores only — no spaces (a space would break the parser's `<TYPE>: <NAME>` regex match).
- `<NAME>` is human-readable and may contain spaces, commas, and other punctuation.
- The description block is 1-5 sentences explaining what the section contains. It is required.
- The `Prefix:` line declares the page prefix that scopes identifiers in this section (Section 5). It is required and singular — a JS file has at most one prefix.

### 3.2 Banner authoring discipline

When adding new content to a file, prefer creating a new banner over expanding an existing one if the new content is a distinct concept. The cost of an extra banner is small; the cost of jumbled-content sections is large because a reader can no longer tell at a glance what a section contains.

---

## 4. Section types

The recognized section types differ slightly between page files and the shared file `cc-shared.js`. Page files use a five-type taxonomy; `cc-shared.js` adds two foundational types that exist nowhere else.

### 4.1 Page files

Five section types, in fixed order:

| Order | TYPE | Purpose | Multiple banners? |
|-------|------|---------|-------------------|
| 1 | `IMPORTS` | ES module imports or `require` statements. | No — single banner only. |
| 2 | `CONSTANTS` | Module-scope `const` declarations of immutable values: lookup tables, color maps, threshold defaults, configuration objects. | Yes — group by concept. |
| 3 | `STATE` | Module-scope `var` declarations of mutable values: chart instances, timer handles, current filter values, cached data. | Yes — group by concept. |
| 4 | `INITIALIZATION` | The `DOMContentLoaded` handler and any one-time setup functions called from it. The "boot sequence" of the file. | No — single banner only. |
| 5 | `FUNCTIONS` | Everything else — data loading, rendering, event handlers, helpers, hooks. | Yes — group by concept. The banner for page lifecycle hooks has a fixed name (Section 8) and must be last. |

### 4.2 The shared file `cc-shared.js`

Seven section types, in fixed order:

| Order | TYPE | Purpose | Multiple banners? | Where it lives |
|-------|------|---------|-------------------|----------------|
| 1 | `IMPORTS` | Same as page files. | No. | Both. |
| 2 | `FOUNDATION` | Platform-wide constants and primitives — month/day name lookups, status code mappings, default timeout values. The JS analogue of CSS custom property tokens. | Yes — group by concept. | `cc-shared.js` only. |
| 3 | `CHROME` | Universal page chrome and shared utilities — `escapeHtml`, `formatTimeOfDay`, `engineFetch`, `showAlert`, `showConfirm`, the WebSocket / idle / visibility / connection-banner machinery. | Yes — group by concept. | `cc-shared.js` only. |
| 4 | `CONSTANTS` | Same as page files. | Yes. | Both. |
| 5 | `STATE` | Same as page files. | Yes. | Both. |
| 6 | `INITIALIZATION` | Same as page files. | No. | Both. |
| 7 | `FUNCTIONS` | Same as page files. | Yes. | Both. |

### 4.3 Type-order rule

Section types must appear in the order shown. An `INITIALIZATION` banner may not appear before a `STATE` banner. Violations emit `SECTION_TYPE_ORDER_VIOLATION`. The fixed ordering reflects a real cascade dependency: imports must come before anything that consumes them; foundation primitives must be defined before chrome utilities use them; constants and state must be declared before the initialization sequence references them; the initialization sequence wires up the page before any function it calls can be invoked; and functions sit at the bottom because they are the body of work the rest of the file orchestrates.

### 4.4 Type uniqueness across files

`FOUNDATION` and `CHROME` sections may exist in only one file across the codebase — `cc-shared.js`. Duplicates emit `DUPLICATE_FOUNDATION` or `DUPLICATE_CHROME`. Single-source ownership of foundation primitives and shared chrome is what makes them genuinely shared; if multiple files defined `FOUNDATION` content, "the canonical month names array" would not have a single home.

---

## 5. Prefixes

Every section banner declares a single page prefix via the `Prefix:` line. Every top-level identifier (function name, constant name, state variable name) defined in that section must begin with the declared prefix followed by an underscore. Violations emit `PREFIX_MISMATCH`.

Examples for `business-services.js` (prefix `bsv`):

```javascript
function bsv_loadActivity() { ... }
function bsv_renderQueueChart(data) { ... }
const bsv_DEFAULT_THRESHOLDS = { ... };
var bsv_currentFilter = 'ALL';
```

### 5.1 Prefix selection rules

The page prefix is declared in the `CC_Initiative.md` Prefix Registry. It is a 3-character lowercase identifier and is the same prefix used by the page's CSS file.

The separator after the prefix is an **underscore** (`_`), not a hyphen. CSS uses a hyphen because CSS class names allow hyphens; JS uses underscore because JS identifiers do not allow hyphens. The two-language separator difference is the only divergence; the prefix itself is identical.

### 5.2 Special values

- `Prefix: (none)` — sentinel value. Declares the section has no page-prefix scoping. Used by:
  - **All sections in `cc-shared.js`.** The shared file's exports (`escapeHtml`, `formatTimeOfDay`, `engineFetch`, etc.) are consumed across every page; prefixing them would break that consumption.
  - **The page lifecycle hooks banner in any page file.** Hook names (`onPageRefresh`, `onPageResumed`, etc.) form an API contract with `cc-shared.js` and cannot be renamed.
  - **The `IMPORTS` and `INITIALIZATION` sections of any file.** These sections do not introduce identifiers subject to prefix scoping.

The `Prefix:` line itself is mandatory regardless of value. If absent entirely, the parser emits `MISSING_PREFIX_DECLARATION`.

### 5.3 Why prefix scoping matters

Reading `bsv_loadActivity()` anywhere in the codebase — in another page's JS, in a route HTML file, in an API call site — instantly tells the reader where the function lives: `business-services.js`. There is no ambiguity, no cross-file grep needed. Catalog queries that need to associate an identifier with its owning page become substring matches on the prefix rather than join chains.

The same discipline applies to `cc-shared.js` exports, but in inverse: any unprefixed identifier in a Control Center JS file is, by spec, a `cc-shared.js` import. The reader does not have to ask where `escapeHtml` comes from; the lack of a prefix is the answer.

---

## 6. Function definitions

A function definition is one of three forms:

1. **Function declaration** — `function name() { ... }`
2. **Function expression assigned to a `var` or `const`** — `const name = function() { ... }`
3. **Arrow function expression assigned to a `var` or `const`** — `const name = () => { ... }`

All three produce a `JS_FUNCTION DEFINITION` row in the catalog when they appear at module scope inside a `FUNCTIONS` section. Function declarations inside other functions are not cataloged (the spec forbids nested function declarations except as anonymous callbacks; see Section 14).

### 6.1 Function comment requirement

Every function definition must be preceded by a single block comment immediately above the declaration. The comment is at minimum a single-sentence purpose. JSDoc-format parameter and return documentation is allowed and encouraged for non-trivial functions, but not mandatory. The comment becomes the row's `purpose_description` in the catalog.

```javascript
/* Loads the current set of replication agents and renders the agent cards. */
function bsv_loadAgents() { ... }
```

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

Missing function comments emit `MISSING_FUNCTION_COMMENT`.

### 6.2 Function naming rules

- Top-level function names in a page file must begin with the page prefix followed by an underscore (Section 5).
- The exception is functions in the page lifecycle hooks banner (Section 8), which use the fixed hook names.
- Functions in `cc-shared.js` are not page-prefixed (their `Prefix:` line is `(none)`).

### 6.3 Anonymous functions assigned at module scope

A function or arrow expression assigned to a module-scope `const` or `var` is a function. It produces a `JS_FUNCTION DEFINITION` row, not a `JS_CONSTANT DEFINITION` row. The catalog reflects role, not syntactic form.

```javascript
/* Resolves the chart color set for a given publication name. */
const bsv_getColor = function(name) {
    return bsv_chartColors[name] || { line: '#888', fill: 'rgba(136, 136, 136, 0.08)' };
};
```

This row gets `component_type = 'JS_FUNCTION'`, not `JS_CONSTANT`.

---

## 7. Constants and state

Module-scope declarations split into two kinds based on the section they live in:

- **`CONSTANTS` sections:** declarations are `const`. They produce `JS_CONSTANT DEFINITION` rows.
- **`STATE` sections:** declarations are `var`. They produce `JS_STATE DEFINITION` rows.

The keyword (`const` vs `var`) is itself a redundant compliance signal — a `const` declaration in a `STATE` section, or a `var` declaration in a `CONSTANTS` section, emits `WRONG_DECLARATION_KEYWORD`. The intent is to make the section type and the keyword line up so a reader scanning either signal arrives at the same conclusion about whether a value is mutable.

`let` is forbidden anywhere in the codebase. All declarations are either `const` (constants) or `var` (state). The rationale is consistency with the existing codebase, which uses `var` everywhere; `let` introduces a third concept without a corresponding cataloging distinction. Drift code: `FORBIDDEN_LET`.

### 7.1 Comment requirement

Every constant and state declaration must be preceded by a single-line block comment describing its purpose. The comment becomes the row's `purpose_description` in the catalog.

```javascript
/* Default polling interval in seconds; overridden by GlobalConfig on page load. */
const bsv_DEFAULT_REFRESH_INTERVAL = 10;

/* Currently selected agent filter; ALL or a specific agent ID. */
var bsv_currentFilter = 'ALL';
```

Missing comments emit `MISSING_CONSTANT_COMMENT` (constants) or `MISSING_STATE_COMMENT` (state variables).

### 7.2 Naming conventions

- **Constants:** SCREAMING_SNAKE_CASE preferred for primitive values (`bsv_DEFAULT_REFRESH_INTERVAL`). camelCase acceptable for objects and lookup tables (`bsv_chartColors`). Both must carry the page prefix.
- **State variables:** camelCase (`bsv_currentFilter`, `bsv_queueChart`, `bsv_livePollingTimer`). Must carry the page prefix.

The case-distinction rule is conventional, not parser-enforced. The parser checks prefix presence and section placement; case is a readability convention.

### 7.3 Multiple declarations per statement

`var a, b, c;` and `const a = 1, b = 2;` are forbidden. Each declaration gets its own statement. This guarantees one declaration per `VariableDeclarator` in the AST and makes per-declaration comment requirements unambiguous (the comment must precede a single declaration, not a multi-declaration list).

Drift code: `FORBIDDEN_MULTI_DECLARATION`.

---

## 8. Page lifecycle hooks

Page lifecycle hooks are the named callbacks that `cc-shared.js` invokes on each page when relevant events occur. The set is fixed:

| Hook | When called | What it should do |
|---|---|---|
| `onPageRefresh` | User clicks the page refresh button | Re-fetch all sections marked Action or Live |
| `onPageResumed` | Tab regained visibility after being hidden | Re-fetch live data; reconnect WebSocket if needed |
| `onSessionExpired` | Auth check failed; session is dead | Stop all page-specific polling timers |
| `onEngineProcessCompleted` | An orchestrator process this page cares about finished | Re-fetch event-driven sections |
| `onEngineEventRaw` | Every WebSocket event before filtering (Admin only) | Used by the Admin page to drive the process timeline |

A page file defines only the hooks it uses. `cc-shared.js` probes for each via `typeof onX === 'function'` before calling.

### 8.1 The hooks banner

If any hooks are defined, they live in a `FUNCTIONS` banner with the **fixed name** `PAGE LIFECYCLE HOOKS`:

```javascript
/* ============================================================================
   FUNCTIONS: PAGE LIFECYCLE HOOKS
   ----------------------------------------------------------------------------
   Callbacks consumed by cc-shared.js. These names form an API contract
   with the shared module — do not rename. The shared module probes for
   each via `typeof onX === 'function'` and calls only those that exist.
   Prefix: (none)
   ============================================================================ */

/* Manual refresh handler — called when user clicks the refresh button. */
function onPageRefresh() {
    bsv_refreshAll();
}

/* Tab regained visibility — refresh live data. */
function onPageResumed() {
    bsv_pageRefresh();
}

/* Session expired — stop page polling. */
function onSessionExpired() {
    bsv_stopPolling();
}
```

### 8.2 Banner placement rule

If the `FUNCTIONS: PAGE LIFECYCLE HOOKS` banner exists, it must be the **last banner in the file**. Hooks call functions defined elsewhere in the file, so placing them at the bottom puts the consumer below the producers — same cascade dependency reason that drives the section type ordering.

A file with hooks but with the hooks banner not last emits `HOOKS_BANNER_NOT_LAST`.

### 8.3 Catalog representation

Functions inside a `FUNCTIONS: PAGE LIFECYCLE HOOKS` banner produce `JS_HOOK DEFINITION` rows, not `JS_FUNCTION DEFINITION` rows. The role is different — these are API-contract callbacks consumed by the shared module — and giving them their own component type means a query like `SELECT file_name, component_name FROM Asset_Registry WHERE component_type = 'JS_HOOK'` becomes a one-line answer to "which pages implement which hooks."

The function comment requirement still applies (`MISSING_FUNCTION_COMMENT` if absent).

### 8.4 No prefix on hook names

Hook names are the API contract with `cc-shared.js`. They cannot be renamed. The hooks banner declares `Prefix: (none)` to signal the prefix exemption to the parser; functions inside the banner do not trigger `PREFIX_MISMATCH`.

---

## 9. Classes and methods

JS classes are not currently used in any Control Center page file, but the spec covers them for forward compatibility.

### 9.1 Class declarations

Class declarations live at module scope inside a `FUNCTIONS` section. They produce a `JS_CLASS DEFINITION` row. Class names follow the same prefix rule as functions (`bsv_QueueChart`, `bsv_AgentRenderer`).

A class declaration must be preceded by a single-sentence purpose comment. Missing class comments emit `MISSING_CLASS_COMMENT`.

```javascript
/* Renders an agent status card and manages its update lifecycle. */
class bsv_AgentCard { ... }
```

### 9.2 Methods

Methods inside a class body produce `JS_METHOD DEFINITION` rows. Each method must carry a preceding single-sentence purpose comment. Missing method comments emit `MISSING_METHOD_COMMENT`.

Methods do not carry the page prefix — they are namespaced inside the class itself.

```javascript
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

## 10. Imports

`IMPORTS` sections contain ES module `import` statements or Node `require` calls. The current Control Center JS code uses neither (page JS is loaded via `<script>` tags, with `cc-shared.js` loaded first to expose its globals), so this section is empty in every current file.

The spec defines `IMPORTS` for forward compatibility. If a future page adopts ES modules, imports will live here. Each import produces a `JS_IMPORT DEFINITION` row keyed on the imported binding name; the source module path lives in the row's `parent_object` column.

---

## 11. Initialization

The `INITIALIZATION` section contains:

1. The `document.addEventListener('DOMContentLoaded', ...)` handler that runs page setup
2. Any one-time setup functions called only from that handler

This is the boot sequence. Functions in this section may invoke functions from any later section (FUNCTIONS), but functions in FUNCTIONS may not depend on initialization having run beyond the constants and state being populated.

The handler itself is anonymous (no name) and is registered via `addEventListener`, which means it does not produce a `JS_FUNCTION DEFINITION` row — the parser treats it as initialization code, not a named definition. The setup functions called from it (named functions like `bsv_init`, `bsv_injectInfoPanel`) do produce `JS_FUNCTION DEFINITION` rows under the page prefix.

```javascript
document.addEventListener('DOMContentLoaded', async function() {
    bsv_injectInfoPanel();
    bsv_injectInfoIcons();
    await bsv_loadRefreshInterval();
    bsv_loadThresholds();
    bsv_refreshAll();
    connectEngineEvents();
    initEngineCardClicks();
    bsv_startAutoRefresh();
});
```

Note that calls to unprefixed functions (`connectEngineEvents`, `initEngineCardClicks`) are calls into `cc-shared.js`. The lack of a prefix is the signal.

Imports live in the separate `IMPORTS` section, not here. The spec defines `IMPORTS` for forward compatibility. If a future page adopts ES modules, imports will live there. Each import produces a `JS_IMPORT` row keyed on the imported binding name; the source module path lives in the row's `variant_qualifier_2` column. See Section 17 for the full row shape.

---

## 12. Comments

Comments serve four roles, and only four:

1. **File header** — a single block comment at line 1 (Section 2). Required.
2. **Section banners** — multi-line block comments enclosing a section's title, description, and prefix declaration (Section 3). Required, one per section.
3. **Purpose comments** — single block comment immediately preceding a function, class, method, constant, state variable, or hook (Sections 6, 7, 8, 9). Required for every cataloged definition.
4. **Sub-section markers** — inline block comment between definitions in a section, used as a lightweight visual divider. Format: `/* -- label -- */`. Optional.

No other comment forms are recognized. Stray block comments at file scope (between sections, before the first banner after the file header, or after the last statement) are a parse error.

### 12.1 Inline comments

Inline `//` line comments are permitted **inside function bodies** for explaining specific lines or blocks of logic. They are not cataloged.

Inline `//` line comments are forbidden at file scope (outside function bodies). All file-scope comments must be one of the four block-comment kinds in Section 12.

Drift code: `FORBIDDEN_FILE_SCOPE_LINE_COMMENT`.

### 12.2 Comment content rules

- Purpose comments are written in present-tense, descriptive style. They describe what the function/constant/state does, not why it does it. Why-it-does-it belongs in the section banner's description block.
- Section banner descriptions may be 1-5 sentences. They explain what the section contains, the design intent, and any cross-section relationships worth noting.

---

## 13. Sub-section markers vs. new banners

When a section's content grows, two structural tools are available: sub-section markers (lightweight visual dividers within a single banner) and new banners of the same type. The choice determines whether new content is a **distinct concept** with its own description, or a **sub-component** of an existing concept.

### 13.1 Use a new banner when

- The new content is a distinct concept with its own purpose
- The new content has its own audience or readership context
- A reader scanning the file's FILE ORGANIZATION list would benefit from seeing the new content as a top-level entry

A new banner gets its own row in the FILE ORGANIZATION list; the parser enforces `FILE_ORG_MISMATCH` against it. The cost of a new banner is small (six lines of comment); the value is real (the file's organization is visible at a glance).

### 13.2 Use a sub-section marker when

- The new content is a sub-component of an existing concept
- Grouping is for visual reading aid only, not a structural distinction

Sub-section markers use the inline format `/* -- <label> -- */`. They are decorative; the parser ignores them for catalog row emission. They do not appear in the FILE ORGANIZATION list. Sub-section markers do not nest — there is one level of grouping.

---

## 14. Forbidden patterns

| Pattern | Drift code | Rationale |
|---------|------------|-----------|
| `let` declarations | `FORBIDDEN_LET` | The codebase uses `var` for state and `const` for constants. `let` adds a third concept without a corresponding cataloging distinction. |
| Multiple declarations per statement (`var a, b, c`) | `FORBIDDEN_MULTI_DECLARATION` | One declaration per statement guarantees one comment per declaration. |
| Top-level function declared inside an `if`/`while`/`try` block | `FORBIDDEN_CONDITIONAL_DEFINITION` | Definitions must be unconditional so the parser can find them deterministically. The legacy `if (typeof pageRefresh !== 'function')` guard in `engine-events.js` retires under this rule. |
| `IIFE` at file scope (`(function() { ... })()`) | `FORBIDDEN_IIFE` | Scope isolation is unnecessary when each file is loaded as a single `<script>` tag. IIFEs hide content from the parser. |
| `eval(...)` | `FORBIDDEN_EVAL` | Security and parser-visibility hazard. |
| `document.write(...)` | `FORBIDDEN_DOCUMENT_WRITE` | Obsolete API. |
| `window.<name> = ...` outside `cc-shared.js` | `FORBIDDEN_WINDOW_ASSIGNMENT` | Page files should not pollute the global namespace. Top-level function declarations are already global; explicit `window.` assignment is unnecessary. The shared file is the only place that legitimately attaches to `window`. |
| Inline `<style>` content in a template literal or string literal | `FORBIDDEN_INLINE_STYLE_IN_JS` | CSS lives in dedicated `.css` files. Inline `<style>` invisible to the CSS parser. |
| Inline `<script>` content in a template literal or string literal | `FORBIDDEN_INLINE_SCRIPT_IN_JS` | JS lives in dedicated `.js` files. |
| Defining a function whose name matches a `cc-shared.js` export | `SHADOWS_SHARED_FUNCTION` | Page files must not redefine shared utilities. Use the shared one. The catalog detects this by joining the page file's `JS_FUNCTION DEFINITION` rows against `cc-shared.js`'s shared definitions. |
| File-scope `//` line comment | `FORBIDDEN_FILE_SCOPE_LINE_COMMENT` | Spec mandates block comments for the four cataloged comment roles. |
| CHANGELOG block in file header | `FORBIDDEN_CHANGELOG_BLOCK` | Git is the source of truth for change history. |
| Element-style ID assignment `el.id = '...'` outside utility constructors | `FORBIDDEN_IMPERATIVE_ID_OUTSIDE_CONSTRUCTOR` | Imperative ID assignment is permitted but discouraged; the catalog flags it for visibility. Fires only when the assignment is in a function whose role is rendering rather than DOM construction. *(Tracked but not enforced — see Section 18 for compliance-detection caveats.)* |

---

## 15. Required patterns summary

Every JS file must:

1. Open with a spec-compliant file header (Section 2)
2. Define all sections under recognized section types in declared order (Sections 3, 4)
3. Declare a valid prefix in every section banner (Section 5)
4. Precede every function, constant, state variable, hook, class, and method with a single block comment (Sections 6, 7, 8, 9, 12)
5. Use `const` in CONSTANTS sections and `var` in STATE sections (Section 7)
6. Place page lifecycle hooks in a `FUNCTIONS: PAGE LIFECYCLE HOOKS` banner that is last in the file (Section 8)
7. One declaration per statement (Section 7.3)
8. Use the page prefix on every top-level identifier in a page file, except hooks (Section 5)
9. Use unprefixed identifiers in `cc-shared.js`, with `Prefix: (none)` declared (Sections 4.2, 5.2)
10. Match the FILE ORGANIZATION list to banner titles verbatim, in order (Section 2)

---

## 16. Illustrative example

A minimal complete page JS file demonstrating every required pattern. This represents a hypothetical small page; real pages have more sections.

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
   with the shared module — do not rename.
   Prefix: (none)
   ============================================================================ */

/* Manual refresh handler — re-fetches all sections. */
function onPageRefresh() {
    ex_refreshAll();
}

/* Tab regained visibility — refresh live data. */
function onPageResumed() {
    ex_refreshAll();
}
```

This file produces the following catalog rows when parsed:

- 1 × `FILE_HEADER DEFINITION`
- 6 × `COMMENT_BANNER DEFINITION` (one per section)
- 2 × `JS_CONSTANT DEFINITION` (`ex_ENGINE_PROCESSES`, `ex_DEFAULT_REFRESH_INTERVAL`)
- 2 × `JS_STATE DEFINITION` (`ex_currentFilter`, `ex_livePollingTimer`)
- 5 × `JS_FUNCTION DEFINITION` (`ex_loadConfig`, `ex_refreshAll`, `ex_loadAgents`, `ex_renderAgents`, `ex_buildAgentCard`)
- 2 × `JS_HOOK DEFINITION` (`onPageRefresh`, `onPageResumed`)
- Multiple `JS_FUNCTION USAGE` rows for shared-module calls (`engineFetch`, `escapeHtml`, `connectEngineEvents`) and same-file calls
- Multiple `CSS_CLASS USAGE` rows for class names in template strings (`ex-agent-card`, `ex-agent-name`)
- 1 × `HTML_ID USAGE` (`agent-cards` from `getElementById`)

Zero drift rows expected.

---

## 17. Catalog model essentials

This section covers the catalog mechanism as it relates to JS files. The rules below explain what the parser writes to `dbo.Asset_Registry` when it walks a JS file, with enough detail to write spec-compliant code. The full catalog schema, including columns not relevant to JS, is documented in `CC_Catalog_Pipeline_Working_Doc.md`.

### 17.1 What the catalog represents

Every cataloged JS construct gets one row in `dbo.Asset_Registry`. A row's identity is described by the combination of `component_type`, `component_name`, `reference_type`, `file_name`, `occurrence_index`, `variant_type`, `variant_qualifier_1`, and `variant_qualifier_2`. The parser populates one row per definition or usage instance found while walking source files.

### 17.2 JS-relevant component_type values

| component_type | Meaning |
|---|---|
| `FILE_HEADER` | The file's header block. One row per scanned file. Carries header-level drift codes and serves as the "this file was scanned" anchor. |
| `COMMENT_BANNER` | A section banner comment. One row per section. The section type (`IMPORTS`, `CONSTANTS`, etc.) lives in `signature`. |
| `JS_IMPORT` | An ES `import` statement or Node `require` call. The imported binding name is `component_name`. The source module path is `variant_qualifier_2`. Always carries a non-NULL `variant_type`. See 17.5. |
| `JS_CONSTANT` | A `const` declaration of a primitive value (string, number, boolean, null) in a `CONSTANTS` or `FOUNDATION` section. The base form. |
| `JS_CONSTANT_VARIANT` | A `const` declaration of a compound value (object, array, regex) in a `CONSTANTS` or `FOUNDATION` section. The variant form. See 17.5. |
| `JS_STATE` | A `var` declaration in a `STATE` section. No variant types. |
| `JS_FUNCTION` | A regular `function name() {}` declaration at module scope (in any `FUNCTIONS` section other than the `PAGE LIFECYCLE HOOKS` banner), or a `cc-shared.js` function called from another file (USAGE row). The base form. |
| `JS_FUNCTION_VARIANT` | A function defined as an arrow expression, function expression, async function, async arrow, or generator. The variant form. See 17.5. |
| `JS_HOOK` | A function inside the `FUNCTIONS: PAGE LIFECYCLE HOOKS` banner. No variant types. |
| `JS_CLASS` | A class declaration at module scope. No variant types. |
| `JS_METHOD` | A regular method defined inside a class body. The class name lives in `parent_function`. The base form. |
| `JS_METHOD_VARIANT` | A static method, getter, setter, or async method inside a class body. The class name lives in `parent_function`. The variant form. See 17.5. |
| `JS_TIMER` | A `setInterval` or `setTimeout` call assigned to a tracked handle (a `JS_STATE` variable). The handle name is `component_name`. Always carries a non-NULL `variant_type`. See 17.5. |
| `JS_EVENT` | An event handler binding via `addEventListener` or direct `.on<event> =` assignment. The event name (`click`, `change`, etc.) is `component_name`. Always carries a non-NULL `variant_type`. See 17.5. |
| `CSS_CLASS` | A class name found inside a template literal, string literal, `classList.*` call, `className` assignment, or `setAttribute('class', ...)` call. Always `USAGE`. |
| `HTML_ID` | An `id="..."` attribute in a template/string literal, `el.id = '...'` assignment, or `setAttribute('id', ...)` call (DEFINITION); a literal-string argument to `getElementById` / `querySelector('#...')` (USAGE). |

### 17.3 Scope determination

- **For DEFINITION rows in `cc-shared.js`:** scope is SHARED.
- **For DEFINITION rows in any page file:** scope is LOCAL.
- **For USAGE rows of functions:** scope is SHARED if the called function is defined in `cc-shared.js`; LOCAL if defined in the same page file. Calls to functions defined in neither place (uncataloged identifiers) do not produce rows.
- **For CSS_CLASS USAGE rows:** scope is resolved against existing CSS_CLASS DEFINITION rows in the consumer's zone. SHARED if the class has a SHARED CSS DEFINITION in that zone; LOCAL otherwise. (Requires the CSS populator to have run first; the JS populator emits a degraded-output warning if no CSS_CLASS DEFINITION rows are found in the catalog.)
- **For HTML_ID rows:** always LOCAL (IDs are inherently page-specific).

### 17.4 Drift recording

The parser evaluates every row against the spec in this document and records two things when the row deviates:

- `drift_codes` — comma-separated list of stable short codes (e.g., `MISSING_FUNCTION_COMMENT,PREFIX_MISMATCH`)
- `drift_text` — joined human-readable descriptions corresponding to each code

A row may carry zero, one, or many drift codes. Both columns are NULL when the row is fully spec-compliant.

The full code-to-description mapping for JS appears in Section 19.

### 17.5 Variant model

The variant columns (`variant_type`, `variant_qualifier_1`, `variant_qualifier_2`) discriminate sub-flavors of certain component types. The model mirrors the CSS populator's variant pattern: separate `_VARIANT` component_type values where there is a true "base" form distinguishable from variant expressions, and a single component_type with always-non-NULL `variant_type` where every instance is inherently a variant of something.

**Why two patterns:** for JS_FUNCTION, JS_CONSTANT, and JS_METHOD, there is a clear base case (regular function declaration; primitive const; regular method) and the variants are alternative ways of expressing the same construct (arrow function; object/array const; static method). Splitting base from variant gives queries a clean way to ask "show me the regular functions" vs. "show me everything function-shaped." For JS_TIMER, JS_IMPORT, and JS_EVENT, there is no base — a timer is always either an interval or a timeout; an import is always one of four shapes; an event binding is always either a listener or a property assign. Splitting these would force an empty base type with no rows.

#### JS_FUNCTION (base) and JS_FUNCTION_VARIANT (variant)

| component_type | variant_type | qualifier_1 | qualifier_2 | Source pattern |
|---|---|---|---|---|
| `JS_FUNCTION` | NULL | NULL | NULL | `function bsv_load() {}` |
| `JS_FUNCTION_VARIANT` | `arrow` | NULL | NULL | `const bsv_load = () => {}` |
| `JS_FUNCTION_VARIANT` | `expression` | NULL | NULL | `const bsv_load = function() {}` |
| `JS_FUNCTION_VARIANT` | `async` | NULL | NULL | `async function bsv_load() {}` |
| `JS_FUNCTION_VARIANT` | `async_arrow` | NULL | NULL | `const bsv_load = async () => {}` |
| `JS_FUNCTION_VARIANT` | `generator` | NULL | NULL | `function* bsv_iter() {}` |

#### JS_CONSTANT (base) and JS_CONSTANT_VARIANT (variant)

| component_type | variant_type | qualifier_1 | qualifier_2 | Source pattern |
|---|---|---|---|---|
| `JS_CONSTANT` | NULL | NULL | NULL | `const bsv_API = '/api/...'` (any primitive: string, number, boolean, null) |
| `JS_CONSTANT_VARIANT` | `object` | NULL | NULL | `const bsv_CONFIG = { foo: 1 }` |
| `JS_CONSTANT_VARIANT` | `array` | NULL | NULL | `const bsv_LEVELS = [1, 2, 3]` |
| `JS_CONSTANT_VARIANT` | `regex` | NULL | NULL | `const bsv_RE = /^foo/` |

#### JS_METHOD (base) and JS_METHOD_VARIANT (variant)

| component_type | variant_type | qualifier_1 | qualifier_2 | Source pattern |
|---|---|---|---|---|
| `JS_METHOD` | NULL | NULL | NULL | `foo() {}` (regular method) |
| `JS_METHOD_VARIANT` | `static` | NULL | NULL | `static foo() {}` |
| `JS_METHOD_VARIANT` | `getter` | NULL | NULL | `get foo() {}` |
| `JS_METHOD_VARIANT` | `setter` | NULL | NULL | `set foo(v) {}` |
| `JS_METHOD_VARIANT` | `async` | NULL | NULL | `async foo() {}` |

For all JS_METHOD and JS_METHOD_VARIANT rows, `parent_function` carries the enclosing class name.

#### JS_TIMER (no separate type; always carries variant_type)

| component_type | variant_type | qualifier_1 | qualifier_2 | Source pattern |
|---|---|---|---|---|
| `JS_TIMER` | `interval` | NULL | NULL | `bsv_pollTimer = setInterval(...)` |
| `JS_TIMER` | `timeout` | NULL | NULL | `bsv_retryTimer = setTimeout(...)` |

`component_name` is the handle variable name. The handle must be declared as a `JS_STATE` variable in a `STATE` section.

#### JS_IMPORT (no separate type; always carries variant_type)

| component_type | variant_type | qualifier_1 | qualifier_2 | Source pattern |
|---|---|---|---|---|
| `JS_IMPORT` | `default` | NULL | source-module-path | `import foo from 'bar'` |
| `JS_IMPORT` | `named` | NULL | source-module-path | `import { foo } from 'bar'` |
| `JS_IMPORT` | `namespace` | NULL | source-module-path | `import * as foo from 'bar'` |
| `JS_IMPORT` | `require` | NULL | source-module-path | `const foo = require('bar')` |

`component_name` is the imported binding name. `variant_qualifier_2` carries the source module path so that `WHERE variant_qualifier_2 = 'lodash'` queries are direct.

#### JS_EVENT (no separate type; always carries variant_type)

| component_type | variant_type | qualifier_1 | qualifier_2 | Source pattern |
|---|---|---|---|---|
| `JS_EVENT` | `add_listener` | NULL | NULL | `el.addEventListener('click', handler)` |
| `JS_EVENT` | `property_assign` | NULL | NULL | `el.onclick = handler` |

`component_name` is the event name (`'click'`, `'change'`, etc.).

#### Component types with no variants

`FILE_HEADER`, `COMMENT_BANNER`, `JS_STATE`, `JS_HOOK`, `JS_CLASS` — variant columns are always NULL.

`CSS_CLASS` and `HTML_ID` rows emitted by the JS populator do not carry variant_type values; the variant model on those rows is owned by the CSS populator (for CSS_CLASS) or treated as inapplicable (for HTML_ID).

---

## 18. What the parser extracts

For each JS file, the parser produces rows of these types:

| Row type | Source | Notes |
|----------|--------|-------|
| `FILE_HEADER DEFINITION` | The opening file header block | One per file. `purpose_description` carries the header's purpose paragraph. |
| `COMMENT_BANNER DEFINITION` | Each section banner | `signature` = TYPE, `component_name` = NAME, `purpose_description` = description block. |
| `JS_IMPORT DEFINITION` | Each `import` statement or `require` call | One per imported binding. |
| `JS_CONSTANT DEFINITION` | Each `const` declaration in a `CONSTANTS` section | `purpose_description` = preceding purpose comment. |
| `JS_STATE DEFINITION` | Each `var` declaration in a `STATE` section | `purpose_description` = preceding purpose comment. |
| `JS_FUNCTION DEFINITION` | Each top-level function / function-expression / arrow-expression in a `FUNCTIONS` section other than `PAGE LIFECYCLE HOOKS` | `signature` = function signature with parameter names. `purpose_description` = preceding purpose comment. |
| `JS_HOOK DEFINITION` | Each function in the `FUNCTIONS: PAGE LIFECYCLE HOOKS` banner | Same shape as `JS_FUNCTION DEFINITION` but distinct component type. |
| `JS_CLASS DEFINITION` | Each top-level class declaration | `purpose_description` = preceding purpose comment. |
| `JS_METHOD DEFINITION` | Each method inside a class body | `parent_object` = class name. `purpose_description` = preceding purpose comment. |
| `JS_TIMER DEFINITION` | Each `setInterval` / `setTimeout` call assigned to a tracked handle | `component_name` = handle name. `signature` = the timer function's interval/delay expression. |
| `JS_FUNCTION USAGE` | Each call to a function defined in the same file or in `cc-shared.js` | Calls to unknown identifiers are not cataloged. |
| `JS_EVENT USAGE` | Each `addEventListener('event', ...)` or `.on<event> = ...` | `component_name` = event name. |
| `CSS_CLASS USAGE` | Each class name in a template literal, classList call, or setAttribute('class', ...) | Resolved to SHARED or LOCAL via the CSS_CLASS DEFINITION map loaded at startup. |
| `HTML_ID DEFINITION` | Each `id="..."` in a template/string literal or in `setAttribute('id', ...)` or `el.id = '...'` | LOCAL scope. |
| `HTML_ID USAGE` | Each `getElementById('...')` or `querySelector('#...')` argument | LOCAL scope. |

Each row may carry one or more drift codes in `drift_codes` (comma-delimited string) when the rule violates a spec requirement.

---

## 19. Drift codes reference

Every drift code the JS parser may emit, with description.

### 19.1 File-level codes

| Code | Description |
|---|---|
| `MALFORMED_FILE_HEADER` | The file's header block is missing, malformed, or contains required fields out of order. |
| `FORBIDDEN_CHANGELOG_BLOCK` | The file header contains a CHANGELOG block. CHANGELOG blocks are not allowed in JS file headers — version is tracked in `dbo.System_Metadata`, file change history is tracked in git. |
| `FILE_ORG_MISMATCH` | The FILE ORGANIZATION list in the header does not exactly match the section banner titles in the file body, by content or by order. |

### 19.2 Section-level codes

| Code | Description |
|---|---|
| `MISSING_SECTION_BANNER` | A definition (function, constant, state variable, etc.) appears outside any banner. |
| `MALFORMED_SECTION_BANNER` | A section banner exists but does not follow the strict format with rule lines, title line, separator, description block, and `Prefix:` line. |
| `UNKNOWN_SECTION_TYPE` | A section banner declares a TYPE not in the enumerated list (IMPORTS, FOUNDATION, CHROME, CONSTANTS, STATE, INITIALIZATION, FUNCTIONS). |
| `SECTION_TYPE_ORDER_VIOLATION` | Section types appear out of the required order. |
| `MISSING_PREFIX_DECLARATION` | A section banner is missing the mandatory `Prefix:` line in its description block. |
| `DUPLICATE_FOUNDATION` | More than one JS file in the codebase contains a FOUNDATION section. Exactly one is allowed (`cc-shared.js`). |
| `DUPLICATE_CHROME` | More than one JS file in the codebase contains a CHROME section. Exactly one is allowed (`cc-shared.js`). |
| `HOOKS_BANNER_NOT_LAST` | A `FUNCTIONS: PAGE LIFECYCLE HOOKS` banner exists but is not the last banner in the file. |

### 19.3 Definition-level codes

| Code | Description |
|---|---|
| `PREFIX_MISMATCH` | A top-level identifier name does not begin with the prefix declared in its containing section's banner. |
| `MISSING_FUNCTION_COMMENT` | A function definition is not preceded by a single block comment describing its purpose. |
| `MISSING_CONSTANT_COMMENT` | A `const` declaration in a CONSTANTS section is not preceded by a single block comment. |
| `MISSING_STATE_COMMENT` | A `var` declaration in a STATE section is not preceded by a single block comment. |
| `MISSING_CLASS_COMMENT` | A class declaration is not preceded by a single block comment. |
| `MISSING_METHOD_COMMENT` | A method inside a class body is not preceded by a single block comment. |
| `WRONG_DECLARATION_KEYWORD` | A `var` declaration appears in a CONSTANTS section, or a `const` declaration appears in a STATE section. |
| `SHADOWS_SHARED_FUNCTION` | A page file defines a function whose name matches a `cc-shared.js` export. Use the shared one. |

### 19.4 Forbidden-pattern codes

| Code | Description |
|---|---|
| `FORBIDDEN_LET` | A `let` declaration appears anywhere in the file. |
| `FORBIDDEN_MULTI_DECLARATION` | A single statement declares multiple variables (`var a, b, c`). |
| `FORBIDDEN_CONDITIONAL_DEFINITION` | A top-level function or class is declared inside an `if`/`while`/`try` block. |
| `FORBIDDEN_IIFE` | An immediately-invoked function expression appears at file scope. |
| `FORBIDDEN_EVAL` | A call to `eval(...)` appears in the file. |
| `FORBIDDEN_DOCUMENT_WRITE` | A call to `document.write(...)` appears in the file. |
| `FORBIDDEN_WINDOW_ASSIGNMENT` | An assignment to `window.<name>` appears outside `cc-shared.js`. |
| `FORBIDDEN_INLINE_STYLE_IN_JS` | A template literal or string literal contains a `<style>` element. |
| `FORBIDDEN_INLINE_SCRIPT_IN_JS` | A template literal or string literal contains a `<script>` element. |
| `FORBIDDEN_FILE_SCOPE_LINE_COMMENT` | A `//` line comment appears at file scope. |

### 19.5 Comment / structure codes

| Code | Description |
|---|---|
| `FORBIDDEN_COMMENT_STYLE` | A comment exists that is not one of the allowed kinds (file header, section banner, purpose comment, sub-section marker, in-function inline). |
| `BLANK_LINE_INSIDE_FUNCTION_BODY_AT_SCOPE` | More than one consecutive blank line appears inside a function body. |
| `EXCESS_BLANK_LINES` | More than one blank line appears between top-level constructs. |

---

## 20. Compliance queries

Standard SQL queries against `dbo.Asset_Registry` for JS compliance reporting. Each query is scoped to `WHERE file_type = 'JS'`.

### 20.1 Q1 — Shared-function shadowing

Find every page file that defines a function whose name matches a `cc-shared.js` export. Each result is a page reinventing what's already shared.

```sql
SELECT
    local.file_name        AS reinventing_file,
    local.line_start       AS local_line,
    local.component_name   AS function_name,
    shared.line_start      AS shared_line
FROM dbo.Asset_Registry local
INNER JOIN dbo.Asset_Registry shared
    ON  local.component_name = shared.component_name
    AND local.component_type = 'JS_FUNCTION'
    AND shared.component_type = 'JS_FUNCTION'
    AND local.reference_type  = 'DEFINITION'
    AND shared.reference_type = 'DEFINITION'
WHERE local.file_type    = 'JS'
  AND local.scope        = 'LOCAL'
  AND shared.scope       = 'SHARED'
  AND shared.file_name   = 'cc-shared.js'
ORDER BY local.component_name, local.file_name;
```

### 20.2 Q2 — Drift summary per file

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

### 20.3 Q3 — Drift code distribution

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

### 20.4 Q4 — Hook implementation matrix

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
  AND component_type = 'JS_HOOK'
  AND reference_type = 'DEFINITION'
GROUP BY file_name
ORDER BY file_name;
```

### 20.5 Q5 — Page glossary (function reference)

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
  AND component_type IN ('JS_FUNCTION', 'JS_HOOK')
  AND reference_type = 'DEFINITION'
ORDER BY line_start;
```

---

## Revision history

| Version | Date | Description |
|---|---|---|
| 1.1 | 2026-05-05 | Status backed off from FINALIZED to DRAFT — pending populator validation against refactored files. Section 17 "Catalog model essentials" expanded with the variant model (Section 17.5): three component types gain `_VARIANT` siblings (`JS_FUNCTION_VARIANT`, `JS_CONSTANT_VARIANT`, `JS_METHOD_VARIANT`) for sub-flavors with a true base form; three component types (`JS_IMPORT`, `JS_TIMER`, `JS_EVENT`) keep their single name and always carry a non-NULL `variant_type` because every instance is inherently a variant. Variant qualifier columns mostly NULL on JS rows; `JS_IMPORT` uses `variant_qualifier_2` for the source module path. All four `parent_object` references in the v1.0 spec text remapped: three to `parent_function` (JS_METHOD class containment) and one to `variant_qualifier_2` (JS_IMPORT source path); `parent_object` was dropped from `dbo.Asset_Registry` in the 2026-05-03 schema migration and the v1.0 references were stale. CSS_CLASS USAGE scope determination clarified to note the dependency on the CSS populator running first. Spec body otherwise unchanged. |
| 1.0 | 2026-05-04 | Initial release. Spec body finalized after design session. Section types defined: `IMPORTS` → `[FOUNDATION → CHROME →]` `CONSTANTS` → `STATE` → `INITIALIZATION` → `FUNCTIONS` (FOUNDATION and CHROME limited to `cc-shared.js`). Page lifecycle hooks live in a fixed-name `FUNCTIONS: PAGE LIFECYCLE HOOKS` banner that must be last. Twelve component types established: FILE_HEADER, COMMENT_BANNER, JS_IMPORT, JS_CONSTANT, JS_STATE, JS_FUNCTION, JS_HOOK, JS_CLASS, JS_METHOD, JS_TIMER, JS_EVENT, plus existing CSS_CLASS USAGE and HTML_ID DEFINITION/USAGE. Page-prefix scoping mandated for all top-level identifiers in page files (`<prefix>_<name>` form, underscore separator), with exemptions for hook names, the `cc-shared.js` file as a whole, and the IMPORTS/INITIALIZATION sections. Mandatory preceding block comment on every cataloged definition. CHANGELOG blocks forbidden. `let` forbidden; `const` for constants and `var` for state. Drift code reference covers ~35 codes across file-level, section-level, definition-level, forbidden-pattern, and comment/structure categories. |

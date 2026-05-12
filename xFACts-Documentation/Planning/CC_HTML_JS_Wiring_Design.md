# CC HTML/JS Wiring Design

A working document opened to drive a single design conversation: should CC pages continue to use the current HTML→JS wiring pattern (inline `<script>` tags and `onclick=` attributes referencing globally-named JS functions), or shift to an inverted pattern (HTML declares page identity via `data-page`; a bootloader discovers and loads the page's JS module; JS attaches itself via delegated event listeners against `data-action` markers)?

This document has no settled answers yet. It exists to make the questions discussable. Any framing or characterization in this document is *for discussion*, not predetermined direction.

The conversation is paused work elsewhere — see "Paused dependencies" below. Resuming the broader CC File Format initiative depends on this conversation settling.

---

## Related documents

| Document | Contains |
|---|---|
| `CC_Initiative.md` | Initiative-level direction, current state, prefix registry, anchor file registry, decision history. Updates flagged the active wiring conversation. |
| `CC_Catalog_Pipeline_Working_Doc.md` | Operational tracker for the parser pipeline. Updates flagged the paused work pending the wiring conversation. |
| `CC_HTML_Spec.md` | HTML markup specification. Currently mandates per-page `<script>` tags (§3.2) and inline event handlers (§6 covers them as a recognized pattern). Both sections would change under an inverted model. |
| `CC_JS_Spec.md` | JavaScript file format specification. §12 already mandates delegated `addEventListener` patterns over per-element listeners — a partial step toward the inverted model. |

---

## Why this conversation is happening

The HTML populator's universal anchor-row refactor completed 2026-05-12. As part of verifying the refactor, a query against the catalog surfaced an asymmetric resolution gap: `JS_FILE USAGE` rows on the HTML side resolved 41 unresolved / 0 resolved against `JS_FILE DEFINITION` rows on the JS side, despite the JS populator emitting those DEFINITION rows correctly.

The cause: pipeline order. CSS runs before HTML, so HTML's `CSS_FILE USAGE` rows resolve cleanly at HTML scan time (37 resolved / 0 unresolved). But JS runs *after* HTML, so HTML's `JS_FILE USAGE` and `JS_FUNCTION USAGE` rows have no DEFINITION rows to resolve against when HTML scans. They start as `<undefined>` and stay that way unless something resolves them later.

Total catalog rows currently in this state:

- `JS_FILE USAGE` (HTML-side, from `<script src=>`): 41 rows
- `JS_FUNCTION USAGE` (HTML-side, from `onclick=` attributes): 284 rows
- Combined: 325 rows of permanent `<undefined>` source_file values

Investigation of resolution options surfaced a deeper architectural question: do these USAGE rows *need* to exist in the catalog at all? They exist because the current HTML markup pattern is "HTML references JS by file path and by function name." A different markup pattern — HTML declares page identity and dispatches via data attributes, with JS discovering and binding itself — would eliminate those references entirely. The unresolvable rows would not exist in the catalog because the references they describe would not exist in source code.

This document opens that broader architectural conversation.

---

## The two models, head to head

### Current model — HTML references JS

Today every CC page emits HTML that explicitly names JS files and JS functions:

```html
<head>
    <link rel="stylesheet" href="/css/business-services.css">
    <link rel="stylesheet" href="/css/cc-shared.css">
</head>
<body class="section-departmental">
    ...
    <button onclick="bsv_openRequestDetail(123)">Open</button>
    ...
    <script src="/js/business-services.js"></script>
    <script src="/js/cc-shared.js"></script>
</body>
```

Page-specific JS becomes globally scoped on load. Inline `onclick=` attributes resolve handler names against window globals at click time.

### Inverted model — JS self-registers

The HTML carries no JS-specific references. It declares its page identity via `data-page` on body and marks interactive elements with `data-action`:

```html
<head>
    <link rel="stylesheet" href="/css/business-services.css">
    <link rel="stylesheet" href="/css/cc-shared.css">
</head>
<body class="section-departmental" data-page="bsv">
    ...
    <button data-action="open-request-detail" data-request-id="123">Open</button>
    ...
</body>
```

A platform-level bootloader — whose form and location is itself an open question (see Q1) — reads `data-page`, loads the page's JS module, and calls its init function. The JS file attaches delegated `addEventListener` calls on stable parents and dispatches by `data-action` plus the supporting `data-*` attributes.

### Comparison

| Concern | Current model | Inverted model |
|---|---|---|
| Page self-containment | Page HTML names every asset it loads | Page HTML names no assets; bootloader infers |
| Function naming coupling | Renaming JS function requires HTML edit | Renaming JS function never touches HTML |
| Catalog asymmetry on JS_FILE / JS_FUNCTION | 325 unresolvable USAGE rows | Those row types don't exist (nothing to extract) |
| CSP `'unsafe-inline'` requirement | Required | Not required |
| Failure radius (single page JS breaks) | One page broken | One page broken |
| Failure radius (shared infrastructure breaks) | Every page broken (`cc-shared.js` is already shared) | Every page broken (same shared dependency) |
| File size (HTML) | Smaller (concise `onclick=`) | Slightly larger (`data-action=` + `data-<arg>=`) |
| File size (JS) | Larger (functions named for global lookup) | Smaller (private functions OK; dispatch table replaces named entry points) |
| Multi-module per page | Requires multiple `<script>` tags and coordination through globals | Bootloader can load multiple modules; `data-modules=` attribute or equivalent declares them |
| Recognizability to new contributors | Familiar pattern from any web tutorial | Less common; requires understanding the dispatch convention |
| HTML spec complexity | More rules (§3.2 mandated script tags, §6 inline event handlers) | Fewer rules (§3.2 simplifies, §6 collapses) |
| JS spec complexity | Mature; well-established patterns | Adds one section (entry point + dispatch); simplifies others |

### Properties of each model

The inverted model has these properties: each file kind owns its own concerns (HTML for structure/semantics, JS for behavior/binding, CSS for visual styling); cross-references existing in source code (HTML→CSS for stylesheets and class names) all resolve at scan time under the current pipeline order; the catalog is self-consistent because the unresolvable HTML→JS references do not exist in source; renaming a JS function never requires HTML edits; the dispatch mechanism (data-attribute-driven) is less familiar to developers coming from traditional web tutorials.

The current model has these properties: page assets are named in the page's own HTML, so reading a route file tells you which CSS and JS load; failure modes appear in devtools directly (`<script>` 404 = JS didn't load); inline `onclick=` couples HTML markup to JS function names by name, so renaming a JS function requires corresponding HTML edits; the pattern matches what most web developers learn first; the catalog carries 325+ HTML→JS USAGE rows that cannot resolve at scan time under any linear pipeline order.

The blast-radius profile depends on the bootloader implementation (see Q1). Some Q1 options keep blast-radius identical to the current model; others change it.

CSS work is unaffected by the choice regardless of which Q1 option is selected. The CSS spec, populator, completed Phase 1 refactors, and docs-site CSS queue all stand under both models.

---

## The seven design questions

These are the concrete questions a settled design needs to answer. None has been settled yet.

### Q1 — Bootloader location and behavior

Where does the bootloader live, and what form does it take? Options:

- **(a) Folded into `cc-shared.js`.** No new file. The existing `cc-shared.js` (already loaded by every page today) gains conditional logic that reads `data-page` and loads the page module. Pages with `data-page` get inverted-model behavior; pages without `data-page` get unchanged behavior. The bootloader is JavaScript code inside an existing JavaScript file. The page's HTML continues to emit `<script src="/js/cc-shared.js"></script>`. Single point of failure count stays at 1 (`cc-shared.js`).

- **(b) Separate file (`cc-bootloader.js`).** New small file (estimated 5-30 lines depending on scope) whose only job is module discovery and loading. `cc-shared.js` stays focused on chrome behaviors. The page's HTML emits `<script src="/js/cc-bootloader.js"></script>` (and possibly still emits the cc-shared.js tag, or cc-bootloader.js could load cc-shared.js as a prerequisite). Single point of failure count rises to 2 (one small new file, one existing file). The bootloader's small surface area limits its bug potential but doesn't eliminate it.

- **(c) Pode middleware (server-side).** The bootloader-equivalent runs in PowerShell during HTTP response generation, not in the browser. A Pode middleware function inspects outgoing HTML responses (or page-rendering helper output) and injects whatever `<script>` tags the page needs based on server-side knowledge — `data-page`, available JS modules, environment, etc. The page's HTML source on disk never contains the `<script>` tag; Pode adds it during response generation. Server-side determination of what loads on each page; route files have no asset-loading concerns at all; central enforcement of script-loading conventions. Failure radius depends on middleware implementation — a middleware bug could affect every HTTP response site-wide. Debugging is split between server-side PS code (which decides what to inject) and client-side JS behavior (which runs the injected modules).

What does the bootloader-equivalent actually do? At minimum:

- Identify the page (`data-page="<prefix>"` on body, or server-side knowledge of the route)
- Determine the JS file(s) to load for that page
- Cause those files to be loaded by the browser
- Cause a standardized entry point on each loaded module to run (typically after DOMContentLoaded)

Plus the existing `cc-shared.js` chrome work (engine cards, refresh button, connection banner, session expiry, idle pause, etc.) keeps happening regardless of which option is chosen.

The three options differ in *where the bootloader logic lives* (client-side JS in an existing file, client-side JS in a new file, server-side PowerShell in middleware) and in *who knows what at which moment* (browser parses HTML and discovers `data-page` vs. server determines page identity before HTML reaches the browser). Each has distinct implications for debuggability, deployability, failure mode visibility, and architectural coupling.

**For discussion:** the three options aren't on the same axis — (a) and (b) are variations of "client-side JS bootloader" while (c) is "server-side response injection." A decision here might involve picking one of the three outright, or might involve picking a primary mechanism plus a fallback (e.g., server-side injection with a client-side bootloader as the executor of injected logic).

### Q2 — Asset path convention

How does the bootloader find the JS file for a page? Options:

- **(a) Direct convention.** Always `/js/<prefix>.js`. Simple, predictable, matches current naming.

- **(b) Multi-module declaration.** `<body data-page="admin" data-modules="core,bdl,schedules">` loads `/js/admin-core.js`, `/js/admin-bdl.js`, `/js/admin-schedules.js` in parallel. Each module has its own init function. Explicit per-page module list in HTML.

- **(c) Section-scoped modules.** Bootloader scans `<section data-module="bdl">` markers and loads matching JS only when relevant sections are present. Useful for pages where markup is partially conditional (admin's tabs, BDL Import's wizard steps).

- **(d) Registry-driven.** A small JS-side registry (or even a server-side lookup) maps page-prefix to module list. Most flexible, adds infrastructure.

**For discussion:** Pages today are organized one JS file per page. The codebase has several files (Admin, BDLImport, ServerHealth, PlatformMonitoring) large enough that splitting into modules would be relevant if the design supports it. The options differ in declarative location (HTML `data-modules` attribute, HTML `data-module` section markers, server-side registry, implicit by convention) and in whether multi-file is a first-class case or a special case of single-file. The decision interacts with Q6 (multi-file per page) — the answer to one may dictate the other.

### Q3 — JS module entry point convention

Once the bootloader loads `business-services.js`, what runs? Options:

- **(a) Named entry function.** Each page JS file declares a `<prefix>_init()` function. Bootloader calls it by computed name. Fits the existing JS spec's prefix discipline. Function shows up in the catalog as a regular `JS_FUNCTION DEFINITION`.

- **(b) ES module export.** Each page JS file `export`s an `init` function. Bootloader's dynamic import call awaits it. Requires `type="module"` on the bootloader script. More modern but adds module-system semantics to the project.

- **(c) Implicit init via DOMContentLoaded.** Each page JS file binds itself on load via `document.addEventListener('DOMContentLoaded', ...)`. Bootloader's only job is to import. No standardized entry point.

**For discussion:** the three options differ in how the entry point is identified (named-by-convention, ES module export, implicit-on-load), in whether the module-system semantics of ES modules become part of the project (relevant to build setup, browser support assumptions, debugging), and in how easy it is to re-invoke the init logic after the initial page load (relevant for slideouts, content re-renders, partial-page updates). The catalog implications also differ — a named entry function appears as a `JS_FUNCTION DEFINITION` row; an exported function would need new catalog row handling for ES module exports; an implicit DOMContentLoaded handler doesn't appear as a named entry point in the catalog at all.

### Q4 — `data-*` discipline for action wiring

This is the meatiest design question. The inverted model needs a convention for how HTML elements declare actions and pass data to handlers.

**Naming:**

- **(a) Unprefixed actions.** `data-action="open-request-detail"`. The page's `data-page="bsv"` provides context; no need to repeat the prefix on every action.

- **(b) Prefixed actions.** `data-action="bsv-open-request-detail"`. Explicit, unambiguous, matches the page-prefix discipline applied to IDs and classes elsewhere.

- **(c) Hybrid.** Unprefixed for page-local actions; prefixed (e.g., `cc-`) for shared chrome actions.

**Argument passing:**

Most current `onclick=` handlers pass arguments: `onclick="bsv_openRequestDetail(123, 'pending')"`. The inverted model reads arguments from `data-*` attributes:

```html
<button data-action="open-request-detail"
        data-request-id="123"
        data-status="pending">Open</button>
```

JS reads `event.target.closest('[data-action]').dataset.requestId` etc. More verbose in HTML but more declarative.

**Dispatch mechanism:**

- **(a) Switch statement.** `case 'open-request-detail': bsv_openRequestDetail(...); break;` for each action.

- **(b) Lookup table.** `const bsv_actions = { 'open-request-detail': bsv_openRequestDetail, ... };` keyed by action name.

(b) catalogs more cleanly — `bsv_actions` becomes a `JS_CONSTANT_VARIANT` row whose keys are catalogable as something like `data-action` definitions. New catalog row type or extension.

**For discussion:** Q4 actually contains three sub-decisions (naming, argument passing form, dispatch mechanism) that could be settled independently. Naming choice interacts with the page-prefix discipline applied to IDs and classes — whether `data-action` extends that discipline or is exempted. Argument passing via `data-*` is forced by the model; the only design freedom there is naming convention for the attributes (camelCase via `dataset.requestId`, kebab-case via `data-request-id` in HTML — both representations of the same data). The dispatch mechanism interacts with the catalog model: a switch statement has no catalogable shape beyond the case labels; a lookup table is a constant that could be cataloged structurally if a new row type or extension is added.

### Q5 — Non-click events

Most CC inline handlers are `onclick=`, but the codebase also has `onchange=` (form fields), `onkeydown=` (search inputs, Enter to submit), `oninput=` (filter typing), occasional `onmouseover=` etc.

Options:

- **(a) Single `data-action` per event type.** `data-action="..."` for clicks, `data-action-change="..."` for changes, `data-action-keydown="..."` for keyboard. The JS init function registers delegated listeners for each event type it cares about.

- **(b) Single `data-action` reused.** Same attribute serves all event types; the JS dispatch resolves by both `data-action` value and event type. Less attribute proliferation, more dispatch complexity.

- **(c) Event-specific attributes.** `data-on-click`, `data-on-change`, `data-on-keydown`. Most explicit, most verbose.

**For discussion:** the three options differ in attribute proliferation (one base attribute name vs. multiple), in JS-side dispatch complexity (single switch on action name vs. event-type-keyed dispatch tables), and in catalog row identity (whether `data-action` and `data-action-change` produce distinct catalog rows or share an attribute namespace). The choice may also depend on how many distinct event types CC pages actually use — if `onclick=` dominates by a wide margin, optimizing for it specifically may be worth more than treating all event types uniformly.

### Q6 — Multi-file per page (the multi-module question)

Does the design accommodate splitting a page's JS into multiple modules?

If yes: the bootloader needs to load multiple files per page (or one main file that lazy-imports siblings). Page HTML needs to indicate which modules apply. The JS spec needs to address how modules within a page share state and call each other's functions.

If no: every page is exactly one JS file. Large pages stay large.

**For discussion:** the decision interacts with Q1 (bootloader implementation) and Q2 (asset path convention). Designing for multi-file from the start vs. retrofitting later have different costs — building the design with multi-file in mind costs more design effort now but less rework later, while a single-file-only design is simpler upfront but constrains future page splits. The pages that would benefit most from splitting (Admin, BDLImport, ServerHealth, PlatformMonitoring) are also the pages where complexity makes refactoring risky regardless of which model is adopted. The conversation should consider whether the platform's complexity trajectory makes splitting eventually inevitable for some pages.

### Q7 — Migration path

How does the codebase transition from current model to inverted model?

The technical answer is straightforward: the two models coexist cleanly. A page with `data-page` on body and no inline handlers is a new-model page; a page without `data-page` and with `<script>` tags + `onclick=` is an old-model page. `cc-shared.js` (or the bootloader) handles both based on whether `data-page` is present. No big-bang transition needed.

Options for migration order:

- **(a) Pilot first, then formalize.** Pick one representative non-departmental page. Refactor it under a draft of the new model. Use it for a week. If it works, formalize the spec amendments and roll out to subsequent pages as they come up for refactor.

- **(b) Spec first, then refactor.** Settle the design via discussion. Amend the HTML and JS specs. Then refactor pages.

- **(c) Hybrid.** Sketch the design at high level; build the bootloader; pilot on one page; learn what we got wrong; finalize spec amendments; refactor remaining pages.

**For discussion:** each migration approach has different risk/learning trade-offs. (a) and (c) involve early real-world validation but require the spec to remain provisional during the pilot phase. (b) settles the design conceptually first but commits to spec amendments before any code has validated the model in practice. The previous use of (c) in the inline-event-handler migration is precedent worth weighing but not necessarily determinative — that prior migration was a narrower scope than what's contemplated here.

---

## The pilot page question

**This question is prominent and unsettled.**

If we go with a pilot-first approach, which page validates the model? Constraints surfaced in conversation:

- **Not a departmental page.** Departmental pages (ApplicationsIntegration, BusinessServices, BusinessIntelligence, ClientPortal, ClientRelations, DeptOps subcomponents) have atypical interaction patterns — direct OLTP queries, no DDL or collection actions, minimal engine integration. They're not representative of the platform's typical interaction shape. ClientRelations specifically was flagged: using it as a refactor benchmark previously may have created downstream work because subsequent typical pages exercised patterns ClientRelations doesn't have.

- **Not a Phase 1 page.** Phase 1 pages (the five departmental refactors: backup, business-intelligence, client-relations, replication-monitoring, business-services) are already partially refactored to current spec. Refactoring them again under a new model would duplicate work and complicate clean validation.

- **Not mid-restructure.** ServerHealth has planned restructuring work (Lead Blocker consolidation, Top Wait Types card, TempDB Pressure card, in-slideout KILL SPID). Combining the structural refactor with the wiring conversion would entangle learnings between two different scopes.

- **Not behavior-heaviest.** Admin and BDLImport are the most behaviorally complex pages on the platform. Using them as pilots entangles the wiring discussion with their behavioral complexity, making it harder to attribute observed problems to the wiring model itself versus to the page's existing complexity. Validating the model on a less behaviorally-complex page first allows wiring-specific learnings to be separated from page-specific complexity, with these heavier pages addressed once the pattern is settled.

### Candidate pages for the pilot

Operational monitoring pages with typical CC interaction patterns:

| Page | Catalog `<undefined>` row count | Interaction patterns | Notes |
|---|---|---|---|
| BatchMonitoring | 5 | Engine cards, slideouts, filters, action buttons | Smallest unresolved row count of the candidates |
| DBCCOperations | 13 | Engine cards, slideouts, DDL action buttons, filters | Narrower domain than BatchMonitoring; otherwise similar shape |
| IndexMaintenance | 17 | Similar shape with long-running operations and state machines | More behavior than BatchMonitoring |
| DmOperations | 11 | DM-specific patterns, slideouts, action buttons | |
| FileMonitoring | 20 | Similar pattern; alerting and threshold-based behavior | |
| JBossMonitoring | 11 | Similar shape; some specialized interactions | |
| JobFlowMonitoring | 15 | Monitoring shape with job-tracking complexity | |
| BIDATAMonitoring | 7 | Similar pattern with smaller surface | |
| PlatformMonitoring | 39 | Representative interaction surface; the file itself needs full rewrite (revealing-module wrapper). Could combine the pilot with the rewrite. | High-leverage if pilot succeeds; larger commitment if it doesn't |

Pages explicitly excluded by the constraints above (departmental, Phase 1, mid-restructure, behavior-heaviest): the seven Phase 1 / departmental pages, ServerHealth, Admin, BDLImport.

**For discussion:** the trade-off across candidates is roughly "smaller surface = lower validation completeness, smaller risk if model fails" vs. "larger surface = higher validation completeness, larger commitment if model fails." Each candidate also has its own incidental characteristics (PlatformMonitoring would combine the wiring pilot with a needed rewrite of its revealing-module wrapper; FileMonitoring has alerting patterns that other candidates don't; etc.) that might inform the choice based on what specific aspects of the model the pilot needs to validate.

---

## What gets paused, what stays active

### Paused dependencies

- **HTML populator Wave 2.1** (drift code attachment work for additional HTML constructs). Several of Wave 2.1's planned drift codes target patterns whose status depends on which model is adopted — under the current model they remain, under the inverted model some change or are removed. Premature to implement them before the wiring conversation settles.

- **JS_FILE / JS_FUNCTION USAGE resolution back-fill.** The 325 unresolved rows discussed in this document's preamble. Three options were identified for the current model (back-fill from JS populator; orchestrator post-pass; accept as `<undefined>`); the inverted model presents a fourth option that supersedes the first three (the USAGE rows do not exist). Holding the resolution decision pending the wiring outcome.

- **HTML Spec amendments to §3 (asset references) and §6 (event handlers).** These sections describe the current wiring pattern. Whether they amend, simplify, expand, or are removed depends on which model is adopted. Possibly §1 (page shell) is also touched.

- **JS Spec amendments.** Whether any new sections are added (e.g., for entry-point and dispatch conventions if the inverted model is adopted) or whether existing sections are extended (e.g., §12 event handler binding) depends on which model is adopted. The current model would not require new JS Spec sections.

### Stays active

- **CSS work in all forms** — populator, spec, Phase 1 CSS refactors (complete), docs-site CSS queue. Completely unaffected by the wiring conversation.

- **CSS populator development**, future docs-shared.css migration, per-file CSS refactors. All proceed independently.

- **PowerShell populator and PS Module / PS Route specs** — pre-design. Can be sketched in parallel since they're independent of the HTML/JS wiring decision.

- **Infrastructure and shared helpers** — `xFACts-AssetRegistryFunctions.ps1`, `xFACts-OrchestratorFunctions.ps1`, etc. Continue evolving as needed for non-wiring concerns.

---

## What this document is for, and isn't for

This document opens the conversation. It is not the design.

The next-session use of this document is to anchor a structured discussion that produces decisions on the seven design questions plus the pilot page question. Once decisions are made, they get captured in updates to the HTML and JS specs (not in this document), and this document gets retired when the wiring model goes live and is reflected in the appropriate spec and platform documentation.

If the conversation settles toward the current model (no inversion), this document gets retired with a brief decision history entry in `CC_Initiative.md` noting "explored the inverted model in conversation; chose to retain the current model for reasons X, Y, Z."

If the conversation settles toward the inverted model, this document gets retired in favor of spec amendments and a brief decision-history entry in `CC_Initiative.md`.

Either way, no permanent home for this content. Temporary scaffold for one conversation.

---

## Decision history

*Empty for now. Decisions get logged here as they're made.*

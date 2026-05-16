# CC File Format Initiative

*This is a working document tracking active multi-session work. It is the carry-forward artifact between sessions. When the initiative completes, this document is deleted; the decisions land permanently in the specs themselves and in `System_Metadata` version history.*

---

## 1. What this initiative is

A standardization pass across every Control Center file type (CSS, JS, HTML, PowerShell), centered on a paradigm shift in how page HTML and page JS are wired together. The trigger was a catalog asymmetry (HTML→JS function-name references couldn't resolve cleanly under any populator pipeline order), but the broader purpose is internal consistency across the platform: every file follows its type's spec exactly, every populator catalogs it cleanly, every cross-file relationship is queryable, and authoring patterns are uniform from one page to the next.

The architectural change at the core: HTML stops referencing JS function names. Instead, HTML elements declare what should happen via `data-action` attributes, and JS reads those values at runtime via a delegated dispatch table. Page boot is orchestrated by a single bootloader in `cc-shared.js` that loads each page's JS module by convention and invokes a mandatory `<prefix>_init` function.

---

## 2. Where things stand right now

### 2.1 Completed across sessions

#### Session 1 — JS spec amendments + bootloader implementation

**JS spec amendments** (`CC_JS_Spec.md`):
- §4.1 — `INITIALIZATION` removed from page-file section types; page files now have four section types (IMPORTS, CONSTANTS, STATE, FUNCTIONS)
- §4.2 — `BOOTLOADER` added to cc-shared.js section types as a new type between STATE and CHROME; cc-shared.js now has five section types
- §4.4 — `BOOTLOADER` joined `FOUNDATION` and `CHROME` in the uniqueness rule
- §5.2, §5.4 — `INITIALIZATION` removed from prefix-exemption lists
- §11 — Rewritten as terse "Page boot" rules describing the `<prefix>_init` requirement; rationale moved to Appendix A.11
- §12.1, §12.2 — Updated to reference `<prefix>_init` instead of the INITIALIZATION section
- §19.2 — `DUPLICATE_BOOTLOADER` added; `UNKNOWN_SECTION_TYPE` description updated
- §19.3 — `MISSING_PAGE_INIT` added
- §21 — Example file rewritten to use `<prefix>_init` instead of a DOMContentLoaded handler; catalog-row inventory updated
- Appendix A.4, A.11 — Rationale entries added for BOOTLOADER section type and the `<prefix>_init` rule

**cc-shared.js bootloader implementation:**
- New `BOOTLOADER: PAGE BOOT AND ACTION DISPATCH` section inserted between STATE and CHROME
- `sharedActions` dispatch table (initial entries: `cc-page-refresh` → `pageRefresh`, `cc-reload-page` → `reloadPage`)
- `DOMContentLoaded` handler that reads `data-page`, registers the shared action listener, and triggers page-module loading
- `loadPageModule(pageKey)` — injects `<script src="/js/<prefix>.js">` with onload/onerror handling
- `invokePageInit(pageKey)` — looks up `window[<prefix>_init]` and calls it with try/catch
- `renderPageError(pageKey, message)` — populates the `#page-error-banner` placeholder on failure
- `handleSharedAction(event)` — delegated dispatcher for `cc-*` actions on `document.body`
- 113 lines added; rest of file untouched

**cc-shared.css page-error-banner styling:**
- New `CHROME: PAGE ERROR BANNER` section inserted between CONNECTION BANNER and BACK LINK
- `#page-error-banner` styled with `display: none` default and `.page-error-banner-visible` reveal class
- `.page-error-banner-message`, `.page-error-banner-refresh`, `.page-error-banner-contact` styling
- Uses existing tokens; no new tokens introduced
- 59 lines added; CSS spec did not need amendment

**Throwaway test artifacts:**
- `BootloaderTest.ps1` — Pode route at `/bootloader-test`, AD-authenticated, minimal page shell with `<body data-page="test">`, `#page-error-banner` placeholder, three test buttons, and inline instructions for the failure-mode tests
- `test.js` — page module written to the new spec demonstrating `test_init`, the page-local dispatch table, and a delegated click listener

**Validation completed end-to-end in the browser:**
- Happy path: `test_init` runs, indicator updates
- Page-local dispatch: `run-test-action` routes correctly and the handler writes to the result div
- Shared dispatch: `cc-page-refresh` routes to `pageRefresh` cleanly
- Unknown shared action: `cc-bogus-action` produces the expected console.warn
- Per-event-type filtering: the page-local listener correctly ignores `cc-*` clicks
- Failure mode 1 (script 404): page-error-banner appears with "Page module failed to load"
- Failure mode 2 (missing init): page-error-banner appears with "Page boot function not found"
- Failure mode 3 (init throws): page-error-banner appears with "Page boot failed"

#### Session 2 — HTML spec amendments + helper additions + PS spec design

**HTML spec amendments** (`CC_HTML_Spec.md`) — completed and shipped. The shipped spec contains 17 numbered sections plus Appendix, 2176 lines, 104 drift codes (net change: +18 new codes, -4 retired, 16 relocated from prior section). All 13 amendment areas from §4.2 of this initiative doc are reflected. Key locked decisions:

- Two body attributes: `data-page` (page key) and `data-prefix` (CSS/JS prefix); JS files keep slug names
- Fully explicit `data-action-<event>` (no implicit click)
- Hybrid prefix convention: page-local `data-action` values unprefixed, shared chrome actions prefixed `cc-`
- 8-event closed set (click/change/input/submit/keydown/keyup/focus/blur)
- Per-event dispatch tables (`<prefix>_clickActions`, `sharedClickActions`)
- Argument attributes via `data-action-<arg-name>`
- Umbrella code `FORBIDDEN_INLINE_EVENT_HANDLER` plus 16 specific shape codes
- New component type `HTML_EVENT_HANDLER`
- Three accuracy-pass corrections applied during finalization

**HTML helper additions** (`xFACts-Helpers.psm1`):
- `Get-PageScriptTagHtml` — returns the single `<script src="/js/cc-shared.js"></script>` string for embedding before `</body>` in page route files. Centralizes the script-tag emission so it produces one `CSS_FILE USAGE` catalog row from a SHARED-scope helper instead of one row per consuming page.
- Inventory line added to the file header function list.

**Bootloader test page validation:**
- All five validation outcomes confirmed in-browser: `test_init` ran, page-local action fired, bogus action logged warning, shared dispatch works, page-refresh button correctly no-ops on a test page that has no `.page-refresh-btn` element.

**PS spec preliminary notes** (`CC_PS_Spec_Notes.md`) — a 680-line working doc captured to bootstrap the PS spec drafting next session. Captures HTML/PS division of labor, file role taxonomy, banner format inheritance, file header structure, dedicated CHANGELOG section design, catalog row types, per-role file shape templates, function-level rules, drift code categories, populator architecture, and open questions for spec drafting.

#### Session 3 — PS spec drafted and published

**PS spec drafted and shipped** (`CC_PS_Spec.md`). The shipped spec contains 20 numbered sections plus Appendix, ~1900 lines. Consolidates the prior preliminary docs (`CC_PS_Module_Spec.md`, `CC_PS_Route_Spec.md`) and the working notes doc (`CC_PS_Spec_Notes.md`) into a single specification covering all PowerShell file roles. Key locked decisions:

- Six file roles: page-route, api-route, module, standalone, shared-library, plus the special-case path mapping for `Start-ControlCenter.ps1` (handled as standalone). `server.psd1` and other `.psd1` files are out of scope.
- File header format: PowerShell native comment-based-help (`<# .SYNOPSIS .DESCRIPTION .PARAMETER .COMPONENT .NOTES #>`) with `.NOTES` containing exactly three fields: File Name, Location, and FILE ORGANIZATION block. `.COMPONENT` carries the component name (replacing the prior signpost-style Version line). `.EXAMPLE` and other PS help keywords forbidden.
- 10 section types: `CHANGELOG`, `IMPORTS`, `PARAMETERS`, `INITIALIZATION`, `CONSTANTS`, `VARIABLES`, `FUNCTIONS`, `EXECUTION`, `ROUTE`, `EXPORTS`. Naming aligned with PowerShell idiom (`VARIABLES` not `STATE`, `EXECUTION` not `MAIN`).
- Banner format: 76-char `=` rules and `-` separator inherited from CSS/JS specs, with `Prefix:` declaration line. Generic singleton NAMEs (e.g., `ROUTE: PAGE PATH`, `ROUTE: API ENDPOINTS`, `EXPORTS: MODULE EXPORTS`).
- Role-allowed-types matrix specifies which section types each role allows, forbids, or requires (e.g., page-route requires exactly 1 ROUTE; module requires 1+ FUNCTIONS and exactly 1 EXPORTS; standalone requires exactly 1 EXECUTION; CHANGELOG forbidden in api-route and module).
- Date-driven CHANGELOG with per-entry catalog rows (`PS_CHANGELOG_ENTRY`); no version numbers anywhere.
- All API routes regardless of HTTP method must call `Test-ActionEndpoint` (fail-open against `RBAC_ActionRegistry` for unregistered endpoints — the call is the universal hook point so registration takes effect automatically when added).
- SQL queries embedded as here-strings (`@"..."@`); `Invoke-Sqlcmd` calls require `-TrustServerCertificate` and `-ApplicationName`.
- Function-level rules: `[CmdletBinding()]` mandatory, comment-based-help docblock mandatory (with `.PARAMETER` for each parameter); Verb-Noun naming with PowerShell approved-verb list.
- Mini-banners (`# ---`), box-drawing dividers (`# ──`), removed-code headstones, and free-standing block comments outside header/banner/docblock are forbidden.
- Catalog model: full `PS_FILE` anchor, `FILE_HEADER`, `COMMENT_BANNER`, `PS_CHANGELOG_ENTRY`, `PS_FUNCTION`/`_VARIANT`, `PS_PARAMETER`, `PS_CONSTANT`/`PS_VARIABLE`, `PS_ROUTE`, `PS_EXPORT`, `SQL_QUERY`, `GLOBALCONFIG_REF`, `RBAC_CHECK`, `MODULE_IMPORT`, plus forbidden-pattern host rows.
- 9 compliance queries shipped: drift summary, drift distribution, per-file rewrite checklist, function inventory, CHANGELOG entries in date range, forbidden-pattern inventory, function call graph, SQL query coverage, API endpoint inventory (with RBAC_ActionRegistry coverage gap query).

**Preliminary docs deleted** (per §4.12): `CC_PS_Module_Spec.md`, `CC_PS_Route_Spec.md`, `CC_PS_Spec_Notes.md`. Content fully consolidated into `CC_PS_Spec.md`.

#### Session 4 — JS spec and populator amendments; strategic shift to per-page migration

**JS spec amendments** (`CC_JS_Spec.md`) — shipped:
- §5.5 added: "Contract identifiers" centralizes the concept. Identifies `ENGINE_PROCESSES` plus the five hook function names as contract identifiers that are read by exact name from `cc-shared.js`, cannot carry the page prefix, and live in fixed home banners. Lists the full set in tabular form.
- §7.4.3 added: ENGINE_PROCESSES placement rule. Declaration outside `CONSTANTS: ENGINE PROCESSES` banner emits `ENGINE_PROCESSES_MISPLACED`.
- §8.5 added: Hook function placement rule. Hook function declared outside `FUNCTIONS: PAGE LIFECYCLE HOOKS` banner emits `HOOK_MISPLACED`.
- §8.4 updated: References §5.5 contract identifier carve-out instead of relying on the `Prefix: (none)` banner declaration.
- §19.3 updated: New drift codes `ENGINE_PROCESSES_MISPLACED` and `HOOK_MISPLACED` added to the definition-level codes table. Existing `JS_HTML_ID_UNRESOLVED`, `JS_HTML_ID_MALFORMED`, `UNRESOLVED_DISPATCH_HANDLER`, `MALFORMED_ACTION_KEY`, and the four ENGINE_PROCESSES validation codes (`MISSING_ENGINE_PROCESSES_DECLARATION`, `ENGINE_PROCESS_PAGE_MISMATCH`, `ENGINE_SLUG_JS_MISMATCH`, `MISSING_ENGINE_CARD_FOR_REGISTERED_PROCESS`) referenced consistently.
- Appendix A.5.5 added: rationale for the contract identifier concept, the `_MISPLACED` suffix family, the prefix carve-out, and the banner-name-match check semantics. Appendix A.8 updated to reference §5.5.

**JS populator updates** (`Populate-AssetRegistry-JS.ps1`) — shipped across two rounds in this session:

*First round (bootloader / dispatch / ENGINE_PROCESSES baseline):*
- BOOTLOADER section type recognized in cc-shared.js
- INITIALIZATION removed from page-file allowed section types
- `DUPLICATE_BOOTLOADER` detection added
- `MISSING_PAGE_INIT` detection added
- JS_DISPATCH_ENTRY emission added — one row per key-value pair in `<prefix>_<event>Actions` (page-side) or `shared<event>Actions` (cc-shared.js side)
- ENGINE_PROCESSES capture and validation added against `Orchestrator.ProcessRegistry`
- HTML_ID DEFINITION preload added for cross-spec resolution; `JS_HTML_ID_UNRESOLVED` and `JS_HTML_ID_MALFORMED` codes fire on HTML_ID USAGE rows

*Second round (contract identifiers and bug fixes):*
- Two bugs found during first test run and fixed: dispatch-table regex hardcoded 3-char prefix (now accepts variable-length lowercase prefix); ENGINE_PROCESSES capture only handled ArrayExpression and `const` (now handles ObjectExpression and works for both `const` and `var`)
- `$ContractIdentifiers` constant added (ENGINE_PROCESSES + five hook names)
- `Test-IsContractIdentifier` helper added
- `Test-PrefixMissing` extended to short-circuit on contract identifiers — single fix covers all four PREFIX_MISSING call sites (function decl, var/const decl, class decl, revealing-module wrapper)
- PREFIX_MISMATCH check at three call sites extended to exempt contract identifiers
- `ENGINE_PROCESSES_MISPLACED` detection added at VariableDeclaration emission
- `HOOK_MISPLACED` detection added at FunctionDeclaration emission

**Strategic shift to per-page migration approach.** Mid-session, after the second JS populator round and full pipeline run, agreed to shift from "complete each populator before page conversion" to "bring HTML populator to parity in one pass, then convert pages one at a time to surface real-file drift." Rationale: specs and populators built without real refactored files have repeatedly surfaced gaps that only become visible against actual page content. Per-page conversion provides authoritative validation. Phase 1 (skeleton refactor only — no chrome consolidation, no behavior changes) defined as the operational pattern; full playbook captured in `CC_Migration_Phase1.md`.

**JS populator performance.** First full-pipeline run (all four populators) surfaced a ~6x per-row slowdown in the JS populator vs the other three. ~7.5 minutes vs ~80 seconds for the next-slowest (PS). Investigation deferred until correctness work and at least one Phase 1 page conversion are complete; detailed measurements and investigation paths captured in `CC_Catalog_Pipeline_Working_Doc.md`.

### 2.2 What's deployable now

- `cc-shared.js` with bootloader section: deployed and validated (Session 1)
- `cc-shared.css` with page-error-banner styling: deployed and validated (Session 1)
- `CC_JS_Spec.md` v2: published (Session 1)
- `CC_HTML_Spec.md` with bootloader-driven dispatch amendments: published (Session 2)
- `xFACts-Helpers.psm1` with `Get-PageScriptTagHtml` helper: deployed (Session 2)
- `BootloaderTest.ps1` and `test.js`: deployed; will be deleted at the end of the initiative
- `CC_PS_Spec.md`: published (Session 3)
- `CC_JS_Spec.md` v3 with contract identifier framework, `_MISPLACED` family, §5.5 / §7.4.3 / §8.5 placement rules: published (Session 4)
- `Populate-AssetRegistry-JS.ps1` v3 with BOOTLOADER section, MISSING_PAGE_INIT, JS_DISPATCH_ENTRY emission, ENGINE_PROCESSES validation against ProcessRegistry, contract identifier carve-outs, `_MISPLACED` detection: deployed (Session 4)
- `CC_Migration_Phase1.md`: drafted (Session 4); operational starting point for the page migration phase

### 2.3 What's still running on the legacy model

Every existing page is still using:
- `engine-events.js` / `engine-events.css` as the shared files (not yet pointing at `cc-shared.*`)
- `<script src="/js/<page>.js">` plus `<script src="/js/engine-events.js">` (two script tags)
- `document.addEventListener('DOMContentLoaded', ...)` handlers inside their page JS files
- Inline `onclick="functionName()"` patterns in their HTML

None of these pages run through the bootloader yet. The bootloader is purely additive in cc-shared.js — pages that don't declare `data-page` are completely unaffected by the new code.

The five offline-refactored page files mentioned at the start of the initiative (originally refactored to the current CSS/JS specs and intended to swap in once tested) need to be re-refactored against the new spec before they go live. They are still page files in waiting; they haven't replaced anything in production.

---

## 3. Decisions reference

Outcomes from the design discussion that drove the JS spec amendments, HTML spec amendments, and bootloader implementation. Use this as a quick lookup; full rationale lives in the spec appendices.

| # | Topic | Outcome |
|---|---|---|
| Q1 | Bootloader location | Folded into `cc-shared.js`; not a separate file. One `<script src="/js/cc-shared.js">` tag per page. |
| Q2 | Module path convention | Direct: `/js/<prefix>.js`. Multi-module support exists in the design but is event-triggered (see §5). |
| Q3 | Module entry point | Named function `<prefix>_init`. Bootloader invokes via `window[<prefix>_init]`. Must be a top-level `function` declaration. |
| Q3 sub | Init naming | `<prefix>_init`. One per page. Lives in FUNCTIONS section. |
| Q3 sub | Hooks framing | Page lifecycle hooks (`onPageRefresh`, etc.) remain separate, unprefixed, in their own banner. Init is required + prefixed; hooks are optional + unprefixed. |
| Q3 sub | Failure handling | Three failure modes (script 404, init not defined, init throws) each populate the `#page-error-banner` placeholder + log to console. |
| Q4a | `data-action` naming | Hybrid. Page-local actions unprefixed (`data-action="open-request-detail"`); shared chrome actions prefixed `cc-` (`data-action="cc-page-refresh"`). |
| Q4b | Argument naming | Structured. Action arguments use `data-action-<arg-name>` (e.g., `data-action-request-id="123"`). Distinguishes argument attributes from event-type attributes via reference to a known event list. |
| Q4c | Dispatch mechanism | Per-event-type dispatch tables. Each page declares `<prefix>_<event>Actions` constants; cc-shared.js declares `shared<event>Actions`. Dispatcher pre-resolves `closest('[data-action-<event>]')` and calls handler with `(target, event)`. |
| Q5 | Non-click events | All events use `data-action-<event>` (no implicit click). Recognized event closed set: click, change, input, submit, keydown, keyup, focus, blur. Each event type gets its own dispatch table and its own delegated listener. |
| Q5 sub | Argument rule | Arguments are always explicit (`data-action-<arg-name>`), regardless of event type. |
| Q6 | Multi-file per page | Single file per page by default. Multi-module support deferred until a concrete page warrants splitting; see §5. |
| Q7 | Migration order | Spec first. Build infrastructure to spec. Validate runtime. Update populators. Convert pages. Roll out. |
| Q8 | Body attributes | Two attributes: `data-page` (used by the bootloader to find the module) and `data-prefix` (used to look up the prefix's dispatch tables and to scope IDs/classes/JS identifiers). |
| Q9 | HTML helper for the script tag | `Get-PageScriptTagHtml` in `xFACts-Helpers.psm1` returns the script-tag string. Pages call it once and substitute it into their HTML emission before `</body>`. |
| Q10 | PS file header form | PowerShell native comment-based-help (`<# .SYNOPSIS ... #>`) with `.COMPONENT` carrying the component name (unlocks native `Get-Help -Component` filtering) and `.NOTES` carrying three fields: File Name, Location, and FILE ORGANIZATION. `.EXAMPLE` and other PS help keywords forbidden. No version literals anywhere in the header. |
| Q11 | PS section types and naming | 10 types: `CHANGELOG`, `IMPORTS`, `PARAMETERS`, `INITIALIZATION`, `CONSTANTS`, `VARIABLES`, `FUNCTIONS`, `EXECUTION`, `ROUTE`, `EXPORTS`. PowerShell-idiomatic naming (`VARIABLES` not `STATE`, `EXECUTION` not `MAIN`). |
| Q12 | PS role taxonomy | Five roles: page-route, api-route, module, standalone, shared-library. `Start-ControlCenter.ps1` mapped to standalone via path exception. `.psd1` files out of scope. |
| Q13 | PS RBAC discipline | Every API route regardless of HTTP method calls `Test-ActionEndpoint`. Fail-open against `RBAC_ActionRegistry` (the override layer; currently sparse and intentionally so — it's for specific action permissions, not a comprehensive endpoint inventory). Page-level RBAC via `Get-UserAccess`. The catalog itself (via `PS_ROUTE` rows) serves as the comprehensive endpoint inventory. |

### 3.1 The multi-consumer principle

The design conversation crystallized a principle that should guide every subsequent spec discussion: a pattern is acceptable only if it serves all four of its consumers — the developer reading the file, the populator parsing the file, the catalog querying across files, and the runtime executing the file. A pattern that's individually valid HTML/JS/CSS/PS but creates ambiguity for the populator, weakness in the catalog, or fragility at runtime fails the spec's purpose even if no rule technically forbids it.

This principle should be captured in `xFACts_Development_Guidelines.md` so it's available to inform future design decisions across the platform.

### 3.2 Naming summary

| Construct kind | Page-local | Shared |
|---|---|---|
| HTML IDs | `<prefix>-foo` | unprefixed (e.g., `last-update`) |
| CSS classes | `<prefix>-foo` | unprefixed (e.g., `nav-link`) |
| JS top-level identifiers | `<prefix>_foo` | unprefixed (e.g., `pageRefresh`) |
| PS top-level identifiers | `<prefix>_foo` | unprefixed in shared-library/module files |
| **`data-action` values** | **unprefixed** (e.g., `open-request-detail`) | **`cc-` prefixed** (e.g., `cc-page-refresh`) |

The `data-action` rule is intentionally inverted from IDs/classes/identifiers because the prefix carries dispatch-routing information at runtime (which dispatcher should handle this event), not categorization information.

### 3.3 Catalog pipeline execution model

The Asset_Registry catalog pipeline (CSS populator → HTML populator → JS populator → PS populator) is **100% manual standalone execution**. It is not a scheduled process, has no orchestrator wrapper, emits no ProcessRegistry rows, and is not invoked by the engine. An operator runs the pipeline by hand when they want a fresh catalog — typically after a refactor session, a page conversion, or a spec amendment.

Any populator pre-design documents or comments that reference Orchestrator.ProcessRegistry, engine card validation via ProcessRegistry joins, or scheduled-process integration are stale relative to this decision and need to be removed when those populators are next touched. The §4.5 HTML populator update explicitly removes the Wave 4 ProcessRegistry plan. PS populator (§4.7) is being built fresh and so will not introduce orchestrator coupling at all.

A simple invocation wrapper script may be added later to chain the four populators in order (CSS → HTML → JS → PS) for convenience, but the wrapper is a standalone tool the operator runs manually, not a registered process.

---

## 4. Path forward

The remaining work, organized by what's complete, what's actively running, and what's still ahead.

### Completed

| § | Item | Notes |
|---|---|---|
| 4.1 | JS spec amendments | Shipped Session 1. See §2.1. |
| 4.2 | Bootloader implementation in cc-shared.js + cc-shared.css | Shipped Session 1 and validated end-to-end. |
| 4.3 | HTML spec amendments | Shipped Session 2 as `CC_HTML_Spec.md`. |
| 4.4 | HTML helper-function additions (partial) | `Get-PageScriptTagHtml` shipped Session 2. Other helper updates fold into per-page conversions in §4.10. |
| 4.5 | JS populator update | Shipped Session 4 across two rounds. BOOTLOADER recognition, MISSING_PAGE_INIT, JS_DISPATCH_ENTRY emission, ENGINE_PROCESSES validation, contract identifier carve-outs, `_MISPLACED` family detection. See §2.1 Session 4. |
| 4.7 | PS Spec drafted and finalized | Shipped Session 3 as `CC_PS_Spec.md`. Prelim docs deleted. |

### Active and unblocked

#### 4.6 HTML populator update

The HTML populator (`Populate-AssetRegistry-HTML.ps1`) already exists at Wave 2 functionality and is the authoritative source of HTML cataloging. It scans `.ps1` and `.psm1` files (there are no standalone `.html` files in the CC app — every page's HTML lives inside PowerShell here-strings or StringBuilder append chains), uses PowerShell AST walking to locate HTML-emission constructs, then runs its own HTML tokenizer (which treats PowerShell interpolation as first-class) to extract the markup. It emits `file_type = 'HTML'` rows with the host `.ps1`/`.psm1` file as `file_name`.

Current state: Wave 1 (file discovery + tokenizer + page-shell drift codes) and Wave 2 (attribute-level row extraction — `HTML_ID`, `HTML_DATA_ATTRIBUTE`, `CSS_CLASS USAGE`, `CSS_FILE USAGE`, `JS_FILE USAGE`, `JS_FUNCTION USAGE`) are delivered. Wave 2.1 (drift code attachment for the new row types) is the active next step; Wave 3 (HTML_TEXT, HTML_ENTITY, HTML_SVG, HTML_COMMENT extraction) is planned. The original Wave 4 plan included Orchestrator.ProcessRegistry-driven engine card validation — that scope is now removed (see §3.3); engine-card validation, if retained at all, becomes a direct catalog query without ProcessRegistry coupling.

Updates required for this initiative, now unblocked since the HTML spec amendments are shipped:
- Recognize `data-page` and `data-prefix` as chrome attributes on `<body>`; emit drift codes `MISSING_DATA_PAGE`, `MISSING_DATA_PREFIX` if absent
- Recognize the `#page-error-banner` placeholder requirement; emit drift code `MISSING_PAGE_ERROR_BANNER` if absent
- Validate the single-`<script>`-tag rule (now exactly one `<script src="/js/cc-shared.js">`, not two)
- Drop the existing inline event-handler validation rules — those rules are deleted from the spec
- Recognize the `data-action` family attributes: distinguish dispatch tokens, event-type attributes (`data-action-<event>`), and argument attributes (`data-action-<arg-name>`) via the recognized-event closed set
- Recognize the umbrella `FORBIDDEN_INLINE_EVENT_HANDLER` plus the 16 specific shape codes
- Emit `HTML_EVENT_HANDLER` rows for any inline `on*` attributes found
- Emit new `data-action` family drift codes: `ORPHANED_ACTION_ARGUMENT`, `UNRESOLVED_DATA_ACTION`, `UNKNOWN_EVENT_TYPE`, `EVENT_ATTRIBUTE_WITHOUT_HANDLER`
- Cross-populator resolution: validate `data-action` values against `<prefix>_<event>Actions` / `shared<event>Actions` dispatch-table entries cataloged by the JS populator (clean lookup against rows, no more parsing source for case labels or function names)
- Remove all Orchestrator.ProcessRegistry references from the populator's planned Wave 4

These changes are folded together with all previously-planned wave items (Wave 2.1 drift attachment, Wave 3 HTML_TEXT/HTML_ENTITY/HTML_SVG/HTML_COMMENT extraction) into a single focused completion pass. The goal is "complete to current spec knowledge," matching the level the CSS/JS/PS populators are at: not exhaustively comprehensive, but covering everything the current specs define. No more staged waves.

After the populator updates, run a full catalog refresh. Every existing page file fires expected drift codes (`MISSING_DATA_PAGE`, `MISSING_DATA_PREFIX`, `MISSING_PAGE_ERROR_BANNER`, the now-illegal `onclick=` patterns, the second `<script>` tag, etc.). BootloaderTest.ps1's HTML emission fires zero drift on the new rules (it's the reference shape).

This work is the prerequisite to §4.9 Phase 1 migrations. Once HTML populator is at parity, Phase 1 page conversion begins. Page conversions surface real-file drift; populator and spec amendments follow from that evidence rather than from speculation.

#### 4.8 PS populator — build

The PS populator does not yet exist. Build it now that the PS spec is finalized, implementing the unified spec across all file roles.

This populator catalogs **PowerShell-side constructs only**. The HTML inside `.ps1` here-strings is the existing HTML populator's territory — the two populators scan the same `.ps1`/`.psm1` files but emit non-overlapping row sets. The HTML populator emits `file_type = 'HTML'` rows for HTML constructs; the PS populator emits `file_type = 'PS'` rows for PowerShell constructs. Neither touches the other's domain. The PS populator owns: PowerShell function declarations, parameter blocks, variable assignments, `Add-PodeRoute` registrations (page and API routes), `Add-PodeMiddleware` registrations, `Add-PodeRouteWebSocket` registrations, `Export-ModuleMember` statements, comment-based-help docblocks, SQL query invocations, GlobalConfig references, RBAC check calls, `Import-Module` / dot-source statements, and non-banner comments.

Structure follows the CSS populator pattern:
- File-role detection by filename, extension, and directory (~10 lines)
- Shared structural validation: file header, section banners, FILE ORGANIZATION list, prefix declaration (where applicable per role), comment style, blank-line discipline. Written once, applies to all roles.
- Role-conditional section-type validation: an `allowedTypes[role]` lookup driving the type check
- Role-conditional row extraction
- AST walking via `[System.Management.Automation.Language.Parser]::ParseInput()`, the same approach the HTML populator already uses

The PS populator is smaller than the HTML populator because it doesn't deal with HTML at all — no tokenizer, no embedded-language parsing, no `PowerShell interpolation as first-class concept` work. Just AST walking for PS constructs plus spec-driven structural validation. Estimated size: 1500-2500 lines.

Pipeline ordering: PS populator runs after the HTML populator. The HTML populator's USAGE rows resolve against CSS/JS DEFINITION rows; the PS populator's USAGE rows (e.g., cross-component references in helper calls) resolve against existing CSS/JS/HTML DEFINITION rows. No circular dependencies.

### Sequenced

#### 4.9 Phase 1 migrations — page-by-page skeleton refactor

The migration of every Control Center page from the legacy architecture (engine-events shared files, inline event handlers, DOMContentLoaded boot, free-form file structure) onto the current spec is structured as a series of phases. Phase 1 is the skeleton refactor: the minimal change set that gets a page operating on the new shared infrastructure (`cc-shared.js`, `cc-shared.css`) without changing existing behavior. Everything that violates the spec but doesn't break the page is left in place and surfaces as drift in the catalog. Those drift codes are the input to Phase 2 and beyond.

The full Phase 1 playbook lives in `CC_Migration_Phase1.md`. It includes:
- Scope rules (what's in scope, what's deferred)
- A 16-item per-file checklist across the four files of each page (page route .ps1, API route .ps1, page JS, page CSS)
- Conversion sequence per page (catalog snapshot → backup confirm → refactor → deploy → live validation → catalog refresh → drift review → record outcome)
- Validation criteria (zero structural drift, all remaining drift in deferred categories)
- Per-page outcomes tracker
- Forward reference to Phase 2 (inline event handler migration to dispatch tables) and Phase 3+ (chrome consolidation)

Page selection order is not predetermined. Pages will be chosen based on impact, complexity, and team availability at each conversion session. Tracker in the Phase 1 doc.

Prerequisite: §4.6 (HTML populator completion to current spec knowledge).

#### 4.10 Phase 2 onward

Each subsequent phase will be defined in its own `CC_Migration_PhaseN.md` document. Scope is determined by what the catalog surfaces after the prior phase. Tentative scope:

- **Phase 2:** Migrate inline `onclick`/event-handler patterns to `data-action-<event>` + dispatch table entries across each page. Populate the empty dispatch tables declared in Phase 1. Address related catalog drift.
- **Phase 3+:** Chrome consolidation (remove duplicated local classes, helpers, keyframes; promote where appropriate; address `WRONG_DECLARATION_KEYWORD`, `FORBIDDEN_LET`, style drift). Scope finalized once Phases 1 and 2 are at meaningful per-page coverage.

Each phase has its own playbook, conversion sequence, validation criteria, and per-page tracker, mirroring the Phase 1 structure.

#### 4.11 engine-events retirement (finish line)

When every page has converted off `engine-events.js` and `engine-events.css`, both files are deleted.

Two steps:
- Catalog query: confirm no row in `Asset_Registry` references `engine-events.js` or `engine-events.css` (no JS usage rows, no HTML script-tag references)
- Delete both files from the codebase and the GitHub repo
- Final System_Metadata version bumps marking the migration complete on every affected component

#### 4.12 Cleanup

- Delete `BootloaderTest.ps1` and `test.js`
- Delete `CC_HTML_JS_Wiring_Design.md` (the document that kicked off this initiative; its decisions are now reflected in the JS spec, HTML spec, and this initiative doc's §3)
- Delete this document (`CC_File_Format_Initiative.md`)
- Final version bumps on every component touched during the initiative

---

## 5. Triggered events

Conditions that, if met during the work in §4, interrupt the main sequence for a bounded sub-effort and then resume.

### 5.1 A page warrants splitting into multiple modules

**Trigger:** During a page conversion (§4.10), a page is too complex to live cleanly as a single JS file. Candidates noted at session start: Admin, BDLImport, ServerHealth, PlatformMonitoring.

**Sub-effort when triggered:**
- Bootloader code update in cc-shared.js — accept `data-modules` attribute on `<body>`, parse comma-separated list, load each file in parallel, await all loads before invoking `<prefix>_init`
- JS spec amendment — `data-modules` attribute documented; clarification that multiple files may share one prefix when splitting
- HTML spec amendment — `data-modules` joins the chrome attribute set
- HTML populator update — recognize `data-modules` and validate its format
- JS populator update — recognize that one prefix may map to multiple files when `data-modules` is present in any consumer
- Convert the triggering page using the multi-module pattern

**After the sub-effort:** Resume the main page-conversion sequence. Subsequent pages may use single-module or multi-module form as appropriate.

The sub-effort is bounded: roughly one focused session. Most of the work is the page split itself (which would happen anyway); the bootloader and spec changes are small.

---

## 6. Loose-end touch-ups

Small items surfaced during the initiative that need attention at the next natural opportunity. Not separate work items, just attach-to-the-next-relevant-edit notes.

- **`cc-shared.js` `CHROME: INITIALIZATION` section description** — currently says pages call `connectEngineEvents()` from "their DOMContentLoaded handler." Update to "from their `<prefix>_init` function" when the first page conversion goes through.
- **`cc-shared.css` `CHROME: CONNECTION BANNER` section description** — currently says the banner is driven by `updateConnectionBanner()` in engine-events.js. Update to "in cc-shared.js" when next touched.
- **Multi-consumer principle** — capture in `xFACts_Development_Guidelines.md` as a permanent guideline. One short paragraph explaining the four consumers and the test.
- **Page-error-banner emission helper** — currently each page would need to emit `<div id="page-error-banner" class="page-error-banner"></div>` directly inside its HTML. Consider whether the existing `Get-PageHeaderHtml` helper should be extended to emit it, or whether a new helper (`Get-PageErrorBannerHtml`?) is the cleaner shape. Decide during the first page conversion (§4.9) when the actual pattern is concrete.
- **JS populator performance** — runtime is significantly higher per row than the other three populators (~6x vs PS, ~5x vs HTML, ~4.6x vs CSS based on the 2026-05-16 first-full-run measurements). Acceptable for current dev-cycle catalog builds; needs investigation and likely optimization before the Admin-tile control goes live (planned interactive operation, 3-4 invocations/day, screen-locked while running). Investigation paths and detailed measurements are captured in `CC_Catalog_Pipeline_Working_Doc.md` § JS populator performance investigation. Revisit once the bootloader/dispatch/contract-identifier work is fully validated and at least one Phase 1 page conversion has completed.

---

## 7. Key files and links

- **Specs (permanent, in `Planning/`):** `CC_HTML_Spec.md`, `CC_JS_Spec.md`, `CC_CSS_Spec.md`, `CC_PS_Spec.md`
- **Operational pipeline tracker (in `Planning/`):** `CC_Catalog_Pipeline_Working_Doc.md` — populator status, schema state, lessons learned. Parallel to this initiative doc; both retired at end of initiative.
- **Permanent platform docs:** `xFACts_Development_Guidelines.md`, `xFACts_Platform_Registry.md`, `xFACts_Backlog_Items.md`
- **Source-of-truth assets:** `cc-shared.js`, `cc-shared.css`, `xFACts-Helpers.psm1`
- **Legacy shared files (slated for deletion at §4.11):** `engine-events.js`, `engine-events.css`, `engine-events-API.ps1`
- **Test artifacts (slated for deletion at §4.12):** `BootloaderTest.ps1` (route at `/bootloader-test`), `test.js`
- **Documents slated for deletion at §4.12:** `CC_File_Format_Initiative.md` (this document), `CC_HTML_JS_Wiring_Design.md`, `CC_Initiative.md` (predecessor of this doc; frozen pre-bootloader, historical reference only)

---

## 8. Deferred enhancements

Ideas evaluated during the initiative but consciously not pursued, recorded so they don't get re-discovered and re-evaluated from scratch later.

### 8.1 Asset_Registry cc_prefix and base_name columns

Evaluated in mid-initiative. Proposed two new columns on `Asset_Registry`: `cc_prefix` capturing the prefix portion of `component_name` (when present), and `base_name` capturing the name with the prefix and separator stripped. Intent was to enable cross-page consolidation queries (e.g., "show every page that declares a modal-confirmation pattern") and surface candidates for chrome promotion.

**Outcome: deferred.** The naive split-on-first-separator extraction was run against current data and returned ~300 distinct cc_prefix values, the majority of which were compound-word first segments (`slideout`, `engine`, `card`, `section`) rather than real page prefixes. The naive extraction produces too much noise to be useful as drift detection on current data; a validated extraction (require the prefix to exist in `Component_Registry.cc_prefix`) would erase most of the signal because the codebase pre-dates prefix discipline and currently uses many informal prefixes that aren't formally registered.

The columns are forward-looking — they'd be useful once the codebase has been refactored to follow `<page-prefix>-<base>` discipline uniformly. Pre-refactor, the value proposition isn't compelling enough to justify adding speculative infrastructure. Revisit after the page conversions in §4.9 and §4.10 have made naming conventions consistent; at that point concrete query use cases will drive exactly what shape the columns should take.

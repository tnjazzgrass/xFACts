# CC Catalog Pipeline Working Document

Operational tracker for the parser pipeline that builds `dbo.Asset_Registry`. Tracks architecture decisions, schema state, populator status, environment state, and lessons learned.

This is operational documentation parallel to the CC file format spec docs. The spec docs say what source files have to look like; this doc says how the parser pipeline that catalogs them is built and where it stands today. This doc will be discarded after the parser pipeline goes live, with content useful for permanent documentation harvested into Control Center HTML.

---

## Related documents

| Document | Contains |
|---|---|
| `CC_Initiative.md` | Initiative-level direction, current state, prefix registry, decision history. |
| `CC_CSS_Spec.md` | CSS file format specification (rules every CSS source file must follow). |
| `CC_JS_Spec.md` | JavaScript file format specification. |
| `CC_HTML_Spec.md` | HTML route file specification (pre-design). |
| `CC_PS_Route_Spec.md` | PowerShell route file specification (pre-design). |
| `CC_PS_Module_Spec.md` | PowerShell module file specification (pre-design). |

---

## Current state

Catalog is functional and queryable. Production populator scripts are deployed and running successfully against the full Control Center codebase.

**Production scripts:**

- `Populate-AssetRegistry-CSS.ps1` — at current spec generation. Captures purpose_description across all four CSS comment sources (file header, section banner, per-class, per-variant) at 100% coverage on spec-compliant files. Currently uses direct-recursion walking model and running-state section tracking. Refactor in progress to consume new `xFACts-AssetRegistryFunctions.ps1` and adopt visitor pattern, pre-built section list, and prefix registry validation. Source files have been edited to singular `Prefix:` form; populator does not yet enforce this — will catch up in the alignment refactor.
- `Populate-AssetRegistry-JS.ps1` — spec-aware extractor. Variant emission across all relevant component families. `parent_function` threading on USAGE rows and on JS_METHOD/JS_METHOD_VARIANT rows. Section-aware drift detection covering ~30 codes. Verbatim source capture into widened columns (no text trimming). Top-level IIFE structural skip with full-body capture in raw_text. Per-file AST walk wrapped in try/catch with line-number and stack-trace diagnostics. Zone-aware shared/local resolution (CC zone vs docs zone, with separate shared file lists per zone). HTML_ID rows always emit scope='LOCAL' per spec. cc-shared.js validates at zero file-attributable drift. Refactor queued (after CSS) to consume `xFACts-AssetRegistryFunctions.ps1` and add prefix registry validation.
- `Populate-AssetRegistry-HTML.ps1` — production-grade structure but pre-dates the most recent CSS spec migration. References dropped columns and emits the retired `state_modifier='<dynamic>'` shape. Catch-up pending; will also be refactored to consume the helpers file.

**Shared infrastructure (new this session, not yet deployed):**

- `xFACts-AssetRegistryFunctions.ps1` — domain-specific helpers file for the Asset Registry populator family. ~1,015 lines, 20 functions. Centralizes row construction, dedupe tracking, drift code attachment (hybrid: master-table validation plus optional row-specific context), occurrence-index computation, Object_Registry / Component_Registry registry loads, bulk insert plus DataTable shape, comment-text cleanup, banner detection plus parsing, file-header parsing, pre-built section list construction with body-line ranges, file-org match check, and the generic AST visitor walker. Pattern parallels `xFACts-IndexFunctions.ps1`: each populator dot-sources `xFACts-OrchestratorFunctions.ps1` first, then `xFACts-AssetRegistryFunctions.ps1`, then calls `Initialize-XFActsScript`. Will deploy together with the refactored CSS populator.

**Not yet built:**

- `Refresh-AssetRegistry.ps1` orchestrator. Each populator runs standalone today. The cross-cutting "TRUNCATE the table, then run all populators in order" coordination is currently manual.

---

## Where we left off

Sessions are organized around populator and spec work. Pickup options below assume the prefix registry migration (described in the Initiative doc) is complete.

1. **Refactor `Populate-AssetRegistry-CSS.ps1` to consume the new helpers file plus add prefix registry validation.** Detailed eleven-item action list in `CC_Initiative.md` Current State. Substantive refactor; CSS populator is currently 2,394 lines, target post-refactor is ~450 lines. Includes the registry-validation work that was originally scoped as a small five-change pass before the alignment expansion.
2. **Refactor `Populate-AssetRegistry-JS.ps1` to consume the new helpers file plus add prefix registry validation.** Larger delta (3,983 lines down to ~2,400-2,500). May land in the same session as CSS if context permits, otherwise the next session.
3. **HTML populator catch-up plus HTML spec design.** Bring `Populate-AssetRegistry-HTML.ps1` current: clean up references to dropped columns (`state_modifier`, `component_subtype`, `parent_object`, plus `related_asset_id` / `design_notes` / `is_active`); resolve the dynamic-class strategy question (Open question 1 below); confirm the bulk-insert DataTable shape matches current `dbo.Asset_Registry`; remove `WHERE is_active = 1` filters from CSS_CLASS DEFINITION lookups; refactor to consume `xFACts-AssetRegistryFunctions.ps1`. Then design `CC_HTML_Spec.md` against the HTML conventions already in use across CC route files.
4. **PS populator plus PS spec design.** Two specs (module and route) plus one populator covering both. PS populator will also consume the helpers file.
5. **Phase 1 batch sweep.** Once all four populators are current and all four specs are in production: refactor the five Phase 1 pages (`backup`, `business-intelligence`, `client-relations`, `replication-monitoring`, `business-services`) across CSS, JS, HTML, and PS together. Output: five fully-compliant Phase 1 pages plus deactivation of `engine-events.js` once page JS files migrate to `cc-shared.js`.
6. **Page-at-a-time migration for remaining ~22 pages.** After Phase 1 closes.
7. **`Refresh-AssetRegistry.ps1` orchestrator.** Cross-populator orchestrator: single TRUNCATE, then dispatch CSS to HTML to JS to PS in order, with `sp_getapplock` single-instance locking and consolidated logging. Sequencing-wise this can land any time after all populators are current; not a blocker for migration work.

**Validation strategy.** Every existing source file across CSS/JS/HTML/PS is non-spec-compliant, so running a populator over the full codebase produces thousands of drift rows that don't tell us anything we don't already know. The genuinely valuable validation per file type is the first refactored shared/reference file (CSS validated against `cc-shared.css`; JS against `cc-shared.js`; HTML and PS will follow the same pattern). The Phase 1 batch sweep then iterates page by page; each refactored page is a fresh validation point that can surface spec/populator gaps. The CSS populator alignment refactor itself will be validated by re-running against `cc-shared.css` and the five Phase 1 page CSS files (all currently at zero drift on the pre-refactor populator); if the refactored populator preserves zero-drift on those files, behavior parity is confirmed.

---

## Architecture decisions

### Naming and structure

- Table: `dbo.Asset_Registry` — single table, not three per-language tables.
- Schema: `dbo` (no CC-specific schema prefix).
- Three populators plus one orchestrator (orchestrator pending). CSS, HTML, JS each have their own dedicated populator. Each parser has substantial complexity (Node + PostCSS, PS-native, Node + acorn) and different debugging surfaces.
- Helper Node scripts live alongside (`parse-css.js`, `parse-js.js` registered under `Tools.Utilities` in `Object_Registry`).
- Shared PowerShell helpers live in `xFACts-AssetRegistryFunctions.ps1`, dot-sourced by each populator after `xFACts-OrchestratorFunctions.ps1`.
- Manual trigger from Admin page (no scheduling initially).
- Location: xFACts.dbo (currently AVG-PROD-LSNR)

### Single-table model with reference_type/scope

The table holds one row per instance (definition or usage). DEFINITION vs USAGE is captured in the `reference_type` column. SHARED vs LOCAL is captured in the `scope` column. A shared component used on multiple pages produces multiple USAGE rows, one per consumer location.

### Refresh strategy: TRUNCATE plus reload per file_type

The catalog represents current state only. Standardization work is expected to retire more rows than it adds per run; under a MERGE plus soft-delete model, the table would fill with retired rows that every query would need to filter out.

Refresh semantics:

- **Standalone execution:** each populator deletes only its own slice (`WHERE file_type = 'CSS'` etc.) before bulk-inserting. Each populator independently re-runnable.
- **Orchestrated execution:** the orchestrator TRUNCATEs the whole table once at the start, and each populator's DELETE-WHERE becomes a harmless no-op on already-empty data.

No external tables FK to `asset_id`, so identity stability across runs is not required. Manual annotations, when added later, go in a separate annotations table keyed on the natural key, not on the unstable `asset_id`.

### Schema columns under truncate+reload

- **`occurrence_index`** — per-file ordinal disambiguator for multiple instances of the same component within a parse. Forms part of the natural key. Computed during parse, not maintained across runs.
- **`last_parsed_dttm`** — set to `SYSDATETIME()` on every insert under truncate+reload.

### Extraction targets are content types, not file extensions

The catalog organizes by what's being extracted, not by file extension. A single physical file can be visited by multiple extractors, each catching different content types within it.

| Source file | What it contains |
|---|---|
| `*.css` | CSS only |
| `*.js` | JS code, plus JS template strings that may contain embedded HTML markup |
| `*.ps1` (routes) | PS code, plus here-strings containing HTML markup (which may contain inline `<style>` or `<script>` blocks) |
| `*.ps1` (APIs, suffix `-API.ps1`) | PS code primarily |
| `*.psm1` (helpers) | PS code plus HTML emission |

Production extractors are organized by content type they extract:

- The CSS populator reads only `.css` files.
- The HTML populator reads `.ps1` and `.psm1` files (looking for HTML markup in string tokens).
- The JS populator reads `.js` files and emits both Group A rows (HTML markup found in template strings) and Group B rows (JS code itself).

The `file_type` column on each row reflects what content type was extracted, not the file extension. A row from a JS template string in `bidata-monitoring.js` has `file_type='HTML'` and `file_name='bidata-monitoring.js'`.

### Coverage gaps from the content-type model

Two known content-type gaps remain:

- **Gap 1:** Inline `<style>` blocks in route HTML. A route `.ps1` file with CSS rules inside an HTML `<style>` block within a here-string has those rules invisible to all current populators. Convention discourages inline `<style>`, so prevalence is likely low. Future phase work.
- **Gap 2:** Inline `<script>` blocks in route HTML. Same shape as Gap 1 but for JS functions defined inline in route HTML. Convention discourages inline `<script>`; prevalence likely very low. Future phase work.

(A third gap, HTML inside JS template strings, has been closed by the JS populator's Group A coverage.)

---

## Component types

The full master list of `component_type` values across all populators. Per-file-type spec docs only list the subsets relevant to their file type; this list is the canonical aggregate.

| Type | What it represents | Emitted by |
|---|---|---|
| `FILE_HEADER` | The file's header block. One row per scanned file. | CSS, JS |
| `COMMENT_BANNER` | A section banner comment. | CSS, JS |
| `CSS_CLASS` | A CSS class definition, or a USAGE reference to a class. | CSS, HTML, JS (Group A) |
| `CSS_VARIANT` | A class variant definition (`class`, `pseudo`, or `compound_pseudo` shape). | CSS |
| `CSS_VARIABLE` | A CSS custom property definition or a `var(--name)` reference. | CSS |
| `CSS_KEYFRAME` | A `@keyframes` definition or a reference. | CSS |
| `CSS_RULE` | A non-class rule (e.g., `body`, `*`) — captured for drift visibility. | CSS |
| `HTML_ID` | An `id="..."` attribute occurrence. | HTML, JS (Group A), CSS (when `#id` appears in selectors) |
| `JS_IMPORT` | An ES module import or Node `require` statement. Always non-NULL `variant_type`. | JS |
| `JS_CONSTANT` | A primitive-value `const` declaration in a CONSTANTS or FOUNDATION section. | JS |
| `JS_CONSTANT_VARIANT` | A compound-value or computed-expression `const` declaration. | JS |
| `JS_STATE` | A `var` declaration in a STATE section. | JS |
| `JS_FUNCTION` | A regular `function name() {}` declaration, or a `cc-shared.js` function called from another file (USAGE). | JS |
| `JS_FUNCTION_VARIANT` | An async or generator function declaration. | JS |
| `JS_HOOK` | A regular page lifecycle hook function inside the hooks banner. | JS |
| `JS_HOOK_VARIANT` | An async page lifecycle hook function. | JS |
| `JS_CLASS` | A JavaScript class declaration. | JS |
| `JS_METHOD` | A regular method defined inside a class body. | JS |
| `JS_METHOD_VARIANT` | A static, getter, setter, or async method. | JS |
| `JS_TIMER` | A `setInterval` or `setTimeout` call assigned to a tracked handle. Always non-NULL `variant_type`. | JS |
| `JS_EVENT` | An event handler binding. | JS |
| `JS_IIFE` | An IIFE at file scope. Hosts `FORBIDDEN_IIFE` drift. | JS |
| `JS_EVAL` | An `eval(...)` call. Hosts `FORBIDDEN_EVAL` drift. | JS |
| `JS_DOCUMENT_WRITE` | A `document.write(...)` call. Hosts `FORBIDDEN_DOCUMENT_WRITE` drift. | JS |
| `JS_WINDOW_ASSIGNMENT` | A `window.<name> = ...` assignment outside `cc-shared.js`. Hosts `FORBIDDEN_WINDOW_ASSIGNMENT` drift. | JS |
| `JS_INLINE_STYLE` | A `<style>` element in a JS template/string literal. Hosts `FORBIDDEN_INLINE_STYLE_IN_JS` drift. | JS |
| `JS_INLINE_SCRIPT` | A `<script>` element in a JS template/string literal. Hosts `FORBIDDEN_INLINE_SCRIPT_IN_JS` drift. | JS |
| `JS_LINE_COMMENT` | A `//` line comment at file scope. Hosts `FORBIDDEN_FILE_SCOPE_LINE_COMMENT` drift. | JS |
| `PS_FUNCTION` | A PowerShell function definition. | (Future) |
| `PS_PARAM` | A PowerShell parameter. | (Future) |
| `PS_COMMAND` | A PowerShell command invocation worth cataloging. | (Future) |
| `PS_ASSIGNMENT` | A PowerShell module-scope assignment. | (Future) |
| `API_ROUTE` | An `Add-PodeRoute` definition. | (Future) |

### Variant model

The variant columns (`variant_type`, `variant_qualifier_1`, `variant_qualifier_2`) discriminate sub-flavors of certain component types. Two patterns are in use:

- **Base + `_VARIANT` companion type** — used where there is a clear base case distinguishable from variant expressions. Examples: `CSS_CLASS` / `CSS_VARIANT`; `JS_FUNCTION` / `JS_FUNCTION_VARIANT`; `JS_CONSTANT` / `JS_CONSTANT_VARIANT`; `JS_HOOK` / `JS_HOOK_VARIANT`; `JS_METHOD` / `JS_METHOD_VARIANT`.
- **Single component type, always non-NULL `variant_type`** — used where every instance is inherently a variant. Examples: `JS_IMPORT`, `JS_TIMER`, `JS_EVENT`.

Per-file-type spec docs document the full variant_type / qualifier_1 / qualifier_2 grid for their language.

### file_type values

`CSS`, `JS`, `PS`, `HTML`. The `HTML` value is for rows extracted from HTML markup — these rows have `file_name` pointing at the .ps1/.psm1/.js file the markup lives in.

### Scope determination

- **CSS DEFINITIONs:** SHARED if the file is in the curated shared-files list for its zone. LOCAL otherwise.
- **JS DEFINITIONs:** SHARED if the file is in the curated shared-files list for its zone. LOCAL otherwise.
  - CC zone shared files: `cc-shared.js`, `engine-events.js` (during migration period).
  - Docs zone shared files: `nav.js`, `docs-controlcenter.js`, `ddl-erd.js`, `ddl-loader.js`.
- **HTML USAGEs (CSS_CLASS USAGE rows from the HTML and JS populators):** cross-referenced against existing CSS_CLASS DEFINITION rows in the consumer's zone. SHARED if the class has any SHARED CSS DEFINITION in that zone; LOCAL if only LOCAL DEFINITION exists; LOCAL with `source_file = '<undefined>'` if no DEFINITION exists in any CSS file in the zone.
- **HTML IDs:** always LOCAL.
- **Forbidden-pattern rows:** scope follows the file's overall scope.

### Methodology

- **CSS:** Node + PostCSS 8.5.12 + postcss-selector-parser 7.1.1 (subprocess from PowerShell).
- **JS:** Node + acorn 8.16.0 + acorn-walk 8.3.5 (subprocess from PowerShell).
- **PowerShell tokenization for HTML extraction:** built-in `[System.Management.Automation.Language.Parser]::ParseFile()` — no external dependency.

### Populator alignment (in progress)

The CSS and JS populators were independently developed and currently diverge on several structural axes. Alignment is in progress as of 2026-05-06. Decisions locked:

- **Walking model:** visitor pattern for both. JS already uses this (`Invoke-AstWalk` plus visitor scriptblock); CSS migrates from direct recursion. Visitor receives parent chain (ancestor type strings) plus parent nodes (ancestor node references) for parent-context queries. SKIP_CHILDREN signal returnable from visitor for structural skips (e.g., top-level IIFEs, where the construct itself emits a drift row but per-row cataloging of the body would produce cascade drift).
- **Section tracking:** pre-built section list with body-line ranges. JS already does this via `New-SectionList` plus `Get-SectionForLine`; CSS migrates from running-state (`$script:CurrentBannerInfo`, `$script:PreviousSibling`). The pre-built model is correct under any walking order, where running state depends on walker-equals-source-order which is fragile.
- **Drift attachment:** hybrid model. Master `$script:DriftDescriptions` ordered hashtable per populator (different drift codes per language). `Add-DriftCode` validates the code against the master table (refuses unknown codes with WARN); description text defaults to the master entry but can be overridden per-call with a `-Context` string for row-specific detail. Output-boundary check (`Test-DriftCodesAgainstMasterTable`) runs before bulk insert and warns on any code that escaped validation.
- **Banner detection plus parsing:** parameterized via `-ValidSectionTypes`. Each populator passes its own valid-types list (CSS: FOUNDATION, CHROME, LAYOUT, CONTENT, OVERRIDES, FEEDBACK_OVERLAYS; JS: FOUNDATION, CHROME, IMPORTS, CONSTANTS, STATE, INITIALIZATION, FUNCTIONS); the helpers handle format validation uniformly.
- **File-header parsing:** separates parse from emit. `Get-FileHeaderInfo` returns a structured info object; row emission and drift attachment happen in the calling populator.
- **FILE_ORG_MISMATCH:** moved from cross-file Pass 3 (CSS legacy) to per-file Pass 2 (matches JS). The check is per-file by nature; cross-file location was an accident.
- **Catch-all codes for unknown values in closed enums:** `UNKNOWN_SECTION_TYPE`, `UNKNOWN_HOOK_NAME` (JS only). Fired when a banner's TYPE or a hook function's name doesn't match the closed enum. Surfaces unknown-but-encountered values to the catalog for human review.

The shared infrastructure delivered as `xFACts-AssetRegistryFunctions.ps1` provides the helpers; per-language logic stays in each populator. The architectural-divergence section that previously lived here in this doc is retired; alignment is the active state.

---

## Schema (current state)

The schema below reflects what is currently live in `dbo.Asset_Registry`.

```sql
CREATE TABLE dbo.Asset_Registry (
    asset_id              INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    file_name             VARCHAR(200)   NOT NULL,
    object_registry_id    INT            NULL,
    file_type             VARCHAR(10)    NOT NULL,    -- CSS, JS, PS, HTML
    line_start            INT            NOT NULL,
    line_end              INT            NULL,
    column_start          INT            NULL,
    component_type        VARCHAR(20)    NOT NULL,    -- per master list above
    component_name        VARCHAR(500)   NULL,
    variant_type          VARCHAR(30)    NULL,
    variant_qualifier_1   VARCHAR(100)   NULL,
    variant_qualifier_2   VARCHAR(500)   NULL,
    reference_type        VARCHAR(20)    NOT NULL,    -- DEFINITION, USAGE
    scope                 VARCHAR(20)    NOT NULL,    -- SHARED, LOCAL
    source_file           VARCHAR(200)   NOT NULL,
    source_section        VARCHAR(300)   NULL,
    signature             VARCHAR(MAX)   NULL,
    parent_function       VARCHAR(200)   NULL,
    raw_text              VARCHAR(MAX)   NULL,
    purpose_description   VARCHAR(MAX)   NULL,
    occurrence_index      INT            NOT NULL DEFAULT(1),
    drift_codes           VARCHAR(500)   NULL,
    drift_text            VARCHAR(MAX)   NULL,
    last_parsed_dttm      DATETIME2(7)   NOT NULL DEFAULT(SYSDATETIME())
);
```

**Constraints:** CHECK on `file_type` in {CSS, JS, PS, HTML}, CHECK on `component_type` in enumerated list, CHECK on `reference_type` in {DEFINITION, USAGE}, CHECK on `scope` in {SHARED, LOCAL}.

**Width notes:**

- `drift_codes` is `VARCHAR(500)`. Sufficient for the worst realistic case (~280 characters from 8 maximum-length codes plus separators).
- `variant_type` is `VARCHAR(30)`. Largest current value is `compound_pseudo` (15 chars).
- `parent_function` is `VARCHAR(200)`. Function/method/class names rarely exceed 50 characters.
- `component_name` widened to `VARCHAR(500)` to absorb edge cases.
- `variant_qualifier_2` widened to `VARCHAR(500)` to hold JS_IMPORT module paths with deeply-nested directory structures.
- `source_section` widened to `VARCHAR(300)` to hold long banner titles.

**No CREATE TABLE in source control.** The DDL has not been committed to `xFACts-SQL/`. The schema's authoritative documentation lives here and in `Object_Metadata` (column descriptions, design notes, status_value enumerations). When the parser pipeline goes live and this working doc is retired, the CREATE TABLE may be checked in.

**Object_Registry / Asset_Registry column-name asymmetry.** `Object_Registry`'s primary key is `registry_id`. `Asset_Registry`'s foreign-key column referencing it is `object_registry_id`. The populators' `Object_Registry` load query selects `registry_id`; the bulk-insert into `Asset_Registry` writes that value to `object_registry_id`. The shared helper `Get-ObjectRegistryMap` handles this internally. Worth flagging because the asymmetric naming is a footgun for future query writers.

---

## occurrence_index design

Under truncate+reload, occurrence_index serves a single purpose: uniquely identify multiple instances of the same component within a file's parse. Computed fresh on each run.

- **Definition:** 1-based ordinal of how many times this specific tuple has been seen so far during the current parse, in source-position order. The tuple shape varies by component type — for CSS_VARIANT rows it includes `variant_type` and the qualifier columns; for simpler rows it's just `(file_name, component_name, reference_type)`.
- **Computation:** during parse, the populator maintains a counter dictionary keyed by the tuple. When emitting a row, it increments the counter and assigns the new value to occurrence_index. After alignment, this lives in the shared helper `Set-OccurrenceIndices` using the fuller CSS-style key (includes variant columns); JS rows without variant columns have empty strings in those parts of the key, behaving identically to a simpler key.
- **Forms part of the natural key** `(file_name, component_type, component_name, reference_type, occurrence_index, variant_type, variant_qualifier_1, variant_qualifier_2)`. This is the stable identifier for cross-references — e.g., when a future annotations table needs to attach a design note to "the second `.bkp-pipeline-card.warning` variant in `backup.css`."
- **Not stable across reorderings:** if a developer removes the 1st instance, the formerly-2nd one becomes the new 1st. Acceptable because the catalog represents current state, not history.

---

## Phases

| Phase | Description | Status |
|---|---|---|
| 0 | Schema design + DDL | DONE |
| 0.5 | Object_Registry + Object_Metadata baselines | DONE |
| 1A | CSS extraction | DONE — at current spec generation; alignment refactor in progress |
| 1B | HTML extraction from .ps1/.psm1 string tokens | PRE-MIGRATION — production-grade structure but emits old `state_modifier='<dynamic>'` shape and needs catch-up |
| 1C | HTML extraction from .js template strings | DONE — covered by JS populator's Group A |
| 1D | Production rewrite + orchestrator | PARTIAL — populators production-grade; helpers file delivered; alignment refactor in progress; orchestrator not yet built |
| 2 | JS function/constant/hook/class/method extraction | DONE — at current spec generation; cc-shared.js validated at zero file-attributable drift; alignment refactor queued |
| 3 | PS function/route extraction from .ps1/.psm1 | FUTURE |
| 4 | Inline `<style>` extraction from route HTML | FUTURE — closes Gap 1 |
| 5 | Inline `<script>` extraction from route HTML | FUTURE — closes Gap 2 |
| 6 | Admin UI integration | FUTURE — manual trigger button on Admin page |
| 7 | Generated documentation views | FUTURE — auto-generated markdown from registry queries |
| Future | Annotations table | FUTURE — separate table keyed on natural key |

---

## Production-rewrite remaining work

Most of what was originally scoped under "production rewrite" has shipped. What remains:

### Populator alignment refactor

In progress. Helpers file (`xFACts-AssetRegistryFunctions.ps1`) delivered. CSS populator refactor next (eleven-item action list in `CC_Initiative.md` Current State). JS populator refactor immediately following.

### HTML populator catch-up to current spec

The HTML populator references the pre-migration `state_modifier='<dynamic>'` pattern in its docstring and dynamic-handling logic. Bring it current:

- Replace `state_modifier='<dynamic>'` rows. Either drop the dynamic-modifier capture entirely (it was never very useful) or migrate to a `variant_qualifier_*` representation if there's a defensible mapping.
- Validate against full HTML row set after change.
- Update docstring and CHANGELOG.
- Confirm the populator's bulk-insert DataTable schema matches the current `dbo.Asset_Registry` shape.
- Remove `WHERE is_active = 1` filters from CSS_CLASS DEFINITION lookups.
- Refactor to consume `xFACts-AssetRegistryFunctions.ps1`.

### Populator end-of-run RunStatus / DegradedReason banner

Each populator currently runs interactively and prints freeform progress and summary lines. When the populator pipeline runs from the Admin tile (Phase 6), a structured end-of-run banner with `RunStatus` (success / degraded / failed) and `DegradedReason` fields will let the Admin UI parse and surface run state cleanly. Backlogged until the Admin tile work begins.

### `Refresh-AssetRegistry.ps1` orchestrator (not yet built)

When built, the orchestrator should:

1. Acquire `sp_getapplock` for single-instance protection.
2. TRUNCATE `dbo.Asset_Registry` once.
3. Run CSS populator (must run first — produces the CSS_CLASS DEFINITION rows that HTML and JS populators cross-reference for scope resolution).
4. Run HTML populator.
5. Run JS populator.
6. (When PS populator lands) run PS populator.
7. Release applock.
8. Per-file success/failure summary at end.
9. Standard logging via `Write-Log` from `xFACts-OrchestratorFunctions.ps1`.

The CSS-must-run-first dependency is real and not currently enforced anywhere except by manual run order. The orchestrator landing closes that hole.

### Production script classification (open)

Where the populators get classified in `Object_Registry` is still parked. Two reasonable options:

- **Tools.Utilities** — parallel to `sp_SyncColumnOrdinals` (Object_Metadata maintenance utility). Parser helpers `parse-css.js` and `parse-js.js` are already registered here.
- **Documentation.Pipeline** — parallel to `Generate-DDLReference.ps1` (produces JSON that downstream documentation pages consume).

Decide when the orchestrator lands. The new `xFACts-AssetRegistryFunctions.ps1` shared helpers file gets the same classification as the populators themselves once decided.

---

## Open questions

### 1. HTML populator dynamic-class strategy

Under the pre-migration schema, the HTML populator emitted `state_modifier='<dynamic>'` rows for class values that mixed static and dynamic portions (`class="nav-link$accentClass"`). Under the post-migration schema, `state_modifier` doesn't exist. What replaces it?

- **Option A:** drop dynamic-modifier capture entirely. The static class portion still gets a CSS_CLASS USAGE row; the dynamic part is acknowledged in operator-facing docs as a known coverage gap, not in the catalog.
- **Option B:** map to `variant_type`, e.g., `variant_type='dynamic'` with the static portion in `component_name`. Adds a new variant_type value to the enum.
- **Option C:** capture the entire raw `class="..."` value in `raw_text` only; emit one row for the static portion and rely on raw_text inspection for dynamic-fragment investigation.

To decide during HTML populator catch-up.

### 2. Admin UI trigger pattern

Sibling to Documentation Pipeline trigger? Or its own button? Or part of a unified "Refresh Catalogs" page? Defer to Phase 6.

### 3. Refresh frequency

User mentioned "at least 3-4x per day" earlier. Specific schedule (cron / Pode timer / on-deploy) is Phase 4 design when the orchestrator lands.

### 4. Object_Metadata enrichment timing

Baseline registration done — Object_Registry row exists and column descriptions are populated. Still deferred: enrichment Object_Metadata content (data_flow, design_note, status_value, query, relationship_note rows). Generated only after the orchestrator lands and production behavior is stable.

### 5. Helper consumption gap

`xFACts-Helpers.psm1` currently produces a small fraction of the HTML rows that visual inspection suggests are present. The dominant pattern is string-variable indirection — a class name is built into a variable on one line, and the variable is injected into HTML on another line. The HTML populator can't see this statically.

The CC File Format Standardization initiative addresses this as a coding-convention issue rather than a parser-complexity issue. Files refactored to conform to the format spec produce complete extraction; files that haven't converted produce reduced row counts on indirection patterns.

### 6. Underlying visitor null-deref (latent)

During the JS populator's earlier work, four docs JS files (`ddl-erd.js`, `ddl-loader.js`, `docs-controlcenter.js`, `nav.js`) failed AST walk at the visitor's recursive call site with "You cannot call a method on a null-valued expression." After the IIFE structural skip was added (which prevents the walker from descending into top-level IIFE bodies), the failures stopped because the walker no longer encountered the offending node shapes. The bug itself remains latent — contained behind the IIFE skip plus the per-file try/catch wrapper, but not diagnosed. Investigation deferred until a concrete file fails again outside the IIFE-skip carve-out. Worth a fresh look during the alignment refactor since the visitor walker now lives in shared infrastructure.

### 7. Object_Metadata enrichment for the populator family

As of 2026-05-06, `dbo.Object_Metadata` carries:

- Asset_Registry table: full base rows plus 24 column-description rows
- `parse-css.js`, `parse-js.js`: base rows only (description, module, category)
- `Populate-AssetRegistry-CSS.ps1`, `Populate-AssetRegistry-JS.ps1`: base rows only
- `xFACts-AssetRegistryFunctions.ps1`: base rows plus 1 data_flow row plus 2 design_note rows

The deferred enrichment is intentional: the two populators are about to be substantively refactored, the HTML and PS populators don't exist yet, and the orchestrator hasn't been built. Populating rich enrichment rows now would just create churn as those scripts change.

Return to this after all four populators are aligned, deployed, and the `Refresh-AssetRegistry.ps1` orchestrator is in production. Add the full enrichment row set across the family: data_flow rows describing what each populator reads and writes, design_note rows capturing architectural patterns (visitor walking model, pre-built section list, drift attachment, registry validation, zone-aware shared/local resolution), and any relationship_note rows linking populators to the table they populate and to their helper scripts. The Asset_Registry table itself may also get additional design_note rows (truncate-and-reload model, natural key, Object_Registry column-name asymmetry, variant model) and `query` rows from the spec docs' compliance queries. Same level of richness the helpers file currently reaches, scaled across the family.

Pure documentation work, no external dependency beyond the pipeline being complete. Captured here so it doesn't get overlooked.

---

## Catalog data observations (point-in-time snapshots)

These are operational findings from specific catalog snapshots. Not living truth — re-running the populators will produce different counts. Kept here as reference points for the standardization work's scope.

### 2026-05-04 snapshot (post-G-INIT-4)

Total rows: 7,577. 33 CSS files scanned (28 in the CC zone, 7 in the docs zone, plus `business-services-spec.css` and four other `*-spec.css` files representing the new-format reference implementations). Rows-with-drift: 5,180 (68.4%) — the high percentage reflects that most CSS files are pre-spec.

`purpose_description` coverage on the comment-derived row classes:

| Row class | Total | With purpose | Without purpose |
|---|---|---|---|
| FILE_HEADER | 33 | 25 | 8 |
| COMMENT_BANNER | 308 | 117 | 191 |
| CSS_CLASS DEFINITION | 3,557 | 715 | 2,842 |
| CSS_VARIANT DEFINITION | 1,349 | 161 | 1,188 |

Filtering to just the five new-format spec-compliant CSS files: 100% coverage on all four row classes.

Top drift codes: `MISSING_PURPOSE_COMMENT` (2,842), `FORBIDDEN_DESCENDANT` (1,378), `MISSING_VARIANT_COMMENT` (1,188), `MISSING_SECTION_BANNER` (684). All four are pre-spec residue and will close as files migrate during the page-at-a-time phase.

### Refactor candidates surfaced by the catalog (2026-05-02 snapshot, still useful)

- **Keyframe duplication:** 26 LOCAL definitions of `pulse`, `spin` etc. that should be using the SHARED keyframes in `engine-events.css`.
- **Custom modal cleanup:** 81 custom `modal-*` uses across 12 pages should migrate to shared `xf-modal-*`.
- **slide-panel naming:** BatchMonitoring uses `xwide`, DmOperations uses `extra-wide`, everyone else uses `wide`. Rename for consistency.
- **server-health.css line 715/729:** 11 ID-prefixed rules duplicating shared `.slide-panel.wide` styles.
- **index-maintenance.css line 887/896:** same pattern, 6 ID-prefixed rules.
- **ApplicationsIntegration `admin-badge`/`admin-tool`:** classes used in HTML with no CSS definition.
- **Admin page `af-*`/`gc-*`/`meta-*`/`sched-*-header-right`:** classes used in HTML without CSS definitions.
- **Home.ps1 `subtitle` vs shared `page-subtitle`:** possible rename opportunity.

### Per-page consumption profile (2026-05-02 snapshot)

Pages clustered into three groups:

- **Heavy SHARED users** (well-aligned to engine-events infrastructure): BIDATA, Backup, IndexMaintenance, DmOperations, BatchMonitoring.
- **Balanced:** DBCC, JobFlow, JBoss, FileMonitoring, ReplicationMonitoring, BusinessServices, BusinessIntelligence.
- **Heavy LOCAL users:** Admin (largest LOCAL catalog), PlatformMonitoring, ServerHealth, BDLImport, ApplicationsIntegration, ClientPortal (intentionally has own visual language).

---

## Environment state (FA-SQLDBB)

```
C:\Program Files\
+-- nodejs\                          <- Node.js 24.15.0 (npm 11.12.1)
|
+-- nodejs-libs\                     <- Active parser libraries
|   +-- _downloads\                  (.tgz tarballs, kept for re-extraction)
|   +-- node_modules\
|       +-- acorn\                   <- acorn 8.16.0
|       +-- acorn-walk\              <- acorn-walk 8.3.5
|       +-- postcss\                 <- postcss 8.5.12
|       +-- postcss-selector-parser\ <- 7.1.1
|       +-- nanoid\                  (postcss dep)
|       +-- picocolors\              (postcss dep)
|       +-- source-map-js\           (postcss dep)
|       +-- cssesc\                  (postcss-selector-parser dep)
|       +-- util-deprecate\          (postcss-selector-parser dep)
|
+-- dotnet-lib\                      <- LEGACY — clean up post-launch
    +-- Esprima.3.0.6\               UNUSED
    +-- ExCSS.4.3.1\                 UNUSED
    +-- Acornima.1.6.1\              UNUSED
```

`dotnet-lib` cleanup is deferred until the orchestrator lands and the pipeline is verified working end-to-end.

### Per-language parser stack

| Language | Parser | Install location |
|---|---|---|
| PowerShell | `[System.Management.Automation.Language.Parser]` | Built into PS 5.1 — no external dep |
| JavaScript | acorn 8.16.0 (Node subprocess) | `nodejs-libs\node_modules\acorn\` |
| CSS | PostCSS 8.5.12 + postcss-selector-parser 7.1.1 (Node subprocess) | `nodejs-libs\node_modules\postcss\` |

---

## Helper scripts

- `E:\xFACts-PowerShell\parse-js.js` — Node helper for JS AST extraction. Reads JS from stdin, emits ESTree AST as JSON. Invoked by `Populate-AssetRegistry-JS.ps1`. Registered in `Object_Registry` under `Tools.Utilities`.
- `E:\xFACts-PowerShell\parse-css.js` — Node helper for CSS AST extraction. Reads CSS from stdin, emits structured JSON with rules, atRules, comments, and selector trees. Invoked by `Populate-AssetRegistry-CSS.ps1`. Registered in `Object_Registry` under `Tools.Utilities`.
- `E:\xFACts-PowerShell\xFACts-AssetRegistryFunctions.ps1` — PowerShell shared helpers for the populator family. Dot-sourced by each populator after `xFACts-OrchestratorFunctions.ps1`. Object_Registry / Object_Metadata registration pending deployment.

The Node helpers are stable and don't need changes for the orchestrator work — they're invoked the same way by the populators today.

---

## Lessons learned

### .NET Framework + PS 5.1 + NuGet = dependency hell

The single biggest takeaway. PowerShell 5.1 isn't a real NuGet resolver. NuGet packages target multiple frameworks with different transitive dependency assumptions. Every NuGet package's runtime dependency cluster has to be manually assembled. If anyone in the future considers parsing CSS or JS via a .NET library on PS 5.1, this is the path everyone has tried and failed.

### Why Node + acorn / Node + PostCSS won

- Native to JS ecosystem — runs in its native environment, no impedance mismatch.
- Tiny dependency clusters (acorn = 0 deps; postcss = 3 small deps; selector-parser = 2 small deps).
- Battle-tested — what every modern web tool uses.
- Air-gappable — Node MSI installs offline, .tgz transfers offline, no internet at runtime.
- Subprocess overhead is ~50-100ms per file — non-issue for ~80 files.
- Trivial PowerShell integration via stdin/stdout JSON.
- Standard `node_modules\` layout means modules find each other automatically.

### Library layout

Initial install used `nodejs-libs\<package>\package\` layout, which broke when modules tried to require their dependencies. Fixed by restructuring to standard `nodejs-libs\node_modules\<package>\`. Lesson: when integrating with an ecosystem, use that ecosystem's standard conventions.

### Out-of-scope / discarded approaches

Listed for reference so we don't reconsider these absent new information:

- **ExCSS** — no line numbers, dropped @keyframes/@media handling.
- **Esprima.NET** — abandoned upstream, last active development ~3 years ago.
- **Acornima** — same .NET Framework dependency conflicts as Esprima, no path forward without binding redirects.
- **Hand-rolled CSS or JS tokenizer** — would only catch known patterns, miss edge cases, no value over Node + standard parser.
- **Jurassic / NiL.JS / YantraJS** — JS interpreters not designed for AST-extraction workflows.
- **Roslyn** — C#/VB analyzer, not for JS or CSS.
- **PostCSS via .NET wrapper** — no good standalone .NET CSS parser exists.

### Encoding policy

Source files, populator scripts, and parser output are all ASCII-only. No BOM, no extended characters (em-dashes, smart quotes, arrows). Mixed encodings caused parsing artifacts and hex-escape display issues; unifying on ASCII closed both classes of problem.

### AST walk resilience

Per-file try/catch around the AST walk in both populators. Walk failures are populator tooling defects, not source-file spec drift, so they don't emit drift codes. Diagnostics include populator line number, line content, and full ScriptStackTrace. Failures contained — the populator continues to the next file rather than halting the run.

### SKIP_CHILDREN signal

The walker (now in `xFACts-AssetRegistryFunctions.ps1`'s `Invoke-AstWalk`) supports a SKIP_CHILDREN return value from the visitor scriptblock, used for top-level IIFE handling: the IIFE itself emits a JS_IIFE row with `FORBIDDEN_IIFE` drift, and the walker does not descend into the IIFE's body. This pattern generalizes — whenever a walked node should be recorded but its children should not be visited, the visitor returns SKIP_CHILDREN.

### Verification queries belong in SSMS, not in populators

Earlier populator versions accumulated end-of-run "Verification:" query blocks (3 in CSS, 8 in JS) for inspecting catalog content alongside summary output during console runs. These were development conveniences only; the actual operational query was the per-file drift summary, run separately in SSMS. The verification blocks added ~150 lines of code with no production value and were removed during the alignment refactor.

---

## Pipeline implementation history

A compressed record of substantive implementation events on the pipeline. One or two lines per entry. Older entries have been condensed.

- **2026-04-30** — Initial framework draft. Schema proposed.
- **2026-05-01** — Environment setup. Parsers validated. Node + acorn / Node + PostCSS chosen after .NET path failed.
- **2026-05-02** — Phase 0 (DDL) plus Phase 1A (CSS) plus Phase 1B (HTML) completed. ~7,400 catalog rows. Refresh strategy decided as TRUNCATE plus reload per file_type. Object_Registry plus Object_Metadata baselines registered.
- **2026-05-03** — Schema migration. Dropped `state_modifier`, `component_subtype`, `parent_object`, `first_parsed_dttm`. Added `variant_type`, `variant_qualifier_1`, `variant_qualifier_2`, `drift_codes`, `drift_text`.
- **2026-05-04** — Renamed from `Asset_Registry_Working_Doc.md` to current name. Schema updated to post-migration shape. Phase 1C reclassified as DONE (covered by JS populator's Group A).
- **2026-05-04** — `purpose_description` not populating diagnosed. Three columns dropped from `Asset_Registry` (`related_asset_id`, `design_notes`, `is_active`) — manual-annotation use cases relocate to a future annotations table keyed on the natural key. CSS populator patched to populate `purpose_description` from file headers and section banners.
- **2026-05-04** — CSS populator extended to capture per-class purpose comments and per-variant trailing inline comments. 100% coverage on Phase 1 reference files. All four CSS comment sources now flow into the catalog.
- **2026-05-05** — JS variant model added. Three component types gained `_VARIANT` siblings; three kept single-name with always-non-NULL variant_type. Schema rewritten verbatim from `INFORMATION_SCHEMA.COLUMNS` (corrected three pre-existing documentation drifts on column widths).
- **2026-05-05** — JS populator change pass implemented and deployed. Variant emission helpers per component family. `parent_function` AST-walker threading. `FORBIDDEN_ANONYMOUS_FUNCTION` detection per Section 14.1 callback carve-out. All `Limit-Text` text-trimming removed in favor of widened columns. Three columns widened: `component_name` to VARCHAR(500), `variant_qualifier_2` to VARCHAR(500), `source_section` to VARCHAR(300).
- **2026-05-05** — cc-shared.js created and validated. 224 catalog rows; first spec-compliant JS file. Two known first-banner off-by-one populator bugs flagged for next session.
- **2026-05-06** — JS populator Phase 1 fixes applied. Fixed first-banner off-by-one bugs (FILE_HEADER purpose extraction; phantom banner; SectionTypeOrder map updated for v1.3 spec). Fixed encoding (UTF-8 BOM and 41 non-ASCII chars in CSS; Windows-1252 plus 3 em-dashes in JS — both normalized to ASCII).
- **2026-05-06** — JS populator zone architecture added. Split shared file lists into CC zone (`cc-shared.js`, `engine-events.js`) and docs zone (`nav.js`, `docs-controlcenter.js`, `ddl-erd.js`, `ddl-loader.js`). Pre-load query produces per-zone shared/local class maps. `Get-JsZone` and zone-aware accessor functions added. `SHADOWS_SHARED_FUNCTION` check zone-aware.
- **2026-05-06** — JS populator HTML_ID always-LOCAL fix per spec.
- **2026-05-06** — Top-level IIFE structural skip implemented. JS visitor emits `JS_IIFE` row with full body in `raw_text` plus `FORBIDDEN_IIFE` drift, then returns SKIP_CHILDREN. Walker no longer descends into IIFE body. Code outside the IIFE still cataloged normally.
- **2026-05-06** — AST walk resilience added to both populators. Per-file try/catch with diagnostic capture (populator line, line content, ScriptStackTrace). Walk failures contained and don't emit drift codes (they're populator tooling defects, not file spec drift).
- **2026-05-06** — Both populators validated cleanly on Phase 1 reference files. Cc-shared.css at 626 rows / 0 drift. Cc-shared.js at 223 rows / 0 drift. Five spec-aligned CSS files all at 0 drift, total 1,868 rows.
- **2026-05-06** — `xFACts-AssetRegistryFunctions.ps1` shared helpers file created (~1,015 lines, 20 functions). Centralizes row construction, drift attachment, registry loads, banner parsing, file-header parsing, pre-built section list, and the generic AST visitor walker. Pattern parallels `xFACts-IndexFunctions.ps1`. Each populator dot-sources OrchestratorFunctions then AssetRegistryFunctions explicitly. Helpers file delivered but not yet deployed; deploys with the refactored CSS populator that consumes it.
- **2026-05-06** — Populator alignment design locked. Visitor pattern for both populators; pre-built section list; hybrid drift attachment (master-table validation plus optional context); separated file-header parse/emit; FILE_ORG_MISMATCH per-file in Pass 2; closed-enum catch-all codes; output-boundary drift code check. End-of-run verification query blocks removed from both populators (deleted ~150 lines across the two scripts; SSMS handles inspection going forward).
- **2026-05-06** — Strict prefix registry validation (Option B) chosen. CSS: every banner must declare the file's `cc_prefix`; no per-section `(none)` carve-outs. JS: every banner must declare the file's `cc_prefix` except the hooks banner, IMPORTS section, and INITIALIZATION section per `CC_JS_Spec.md` §5.2. Closes the loophole that a permissive reading would leave open.
- **2026-05-06** — Asset_Registry column descriptions populated in `dbo.Object_Metadata` (24 description rows, populator-agnostic, brief). Two populators and the helpers file registered in `dbo.Object_Registry` under `Tools.Utilities`. Populators got base metadata rows only since they're about to be substantively refactored; helpers file got base rows plus a data_flow row and two design_note rows since it's in final form. Full enrichment for the populator family deferred to Open Question 7.

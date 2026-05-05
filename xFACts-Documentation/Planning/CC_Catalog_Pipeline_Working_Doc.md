# CC Asset Registry Working Document

**Purpose:** Single working document for the Asset_Registry parser implementation effort. Tracks the parser pipeline state, environment, schema state, populator status, lessons learned, and next-session pickup points. This is operational documentation parallel to the CC File Format spec docs — the spec docs say what source files have to look like; this doc says how the parser pipeline that catalogs them is built and where it stands today.

**Will be discarded after the parser pipeline goes live.** Permanent documentation will be HTML in the Control Center, harvesting relevant content from this doc.

> Part of the Control Center File Format initiative. For initiative direction, current state, session log, and the platform-wide prefix registry, see `CC_Initiative.md`. For per-file-type spec content (rules every source file must follow), see the relevant `CC_*_Spec.md` doc.

---

## Where we left off

**Catalog is functional and queryable.** Production populator scripts are deployed and have run successfully against the full Control Center codebase. CSS populator is at the current spec generation. JS populator has been rewritten as a spec-aware extractor against `CC_JS_Spec.md` v1.0; populator validation against the codebase ran 2026-05-04 and surfaced the gap inventory described below. HTML populator is production-grade but pre-dates the most recent CSS spec migration and may have catch-up work pending.

**Production scripts that exist:**

- `Populate-AssetRegistry-CSS.ps1` — at current spec generation. CHANGELOG runs through 2026-05-04 with G-INIT-4 (per-class purpose comment capture).
- `Populate-AssetRegistry-HTML.ps1` — production-grade structure. Latest CHANGELOG entry is 2026-05-02. Is one spec generation behind CSS — populator docstring still describes the `state_modifier='<dynamic>'` pattern that the schema migration retired. Bring-current work pending.
- `Populate-AssetRegistry-JS.ps1` — spec-aware rewrite delivered 2026-05-04 against `CC_JS_Spec.md` v1.0. New row types (FILE_HEADER, COMMENT_BANNER, JS_STATE, JS_HOOK, JS_TIMER); section-aware drift detection covering ~25 codes; purpose_description capture on every cataloged definition; cross-file shadowing detection. Validation run produced 8,360 rows with confirmed correct CSS_CLASS USAGE scope resolution when run after the CSS populator. **Pending changes** (next session): variant model wiring per Section 17.5 of `CC_JS_Spec.md` v1.1; `parent_function` AST-walker threading; louder pre-load reporting when CSS_CLASS DEFINITION rows are missing; `drift_codes` width truncation aligned to `VARCHAR(500)` schema.

**What has NOT been built yet:**

- `Refresh-AssetRegistry.ps1` orchestrator. Each populator runs standalone today. The cross-cutting "TRUNCATE the table, then run all three populators in order" coordination is currently a manual sequence. Listed as Phase 1D scope.

### Next session pickup options

1. **JS populator change pass (next session's opener)** — apply the variant model + parent_function + pre-load reporting + width fix changes to `Populate-AssetRegistry-JS.ps1`. Pre-work landed in `CC_JS_Spec.md` v1.1 (variant grid in Section 17.5) and this doc (master component_type list updated with three new `_VARIANT` types). The `ALTER_AssetRegistry_AddJsVariantTypes.sql` script must run before the new populator (extends the `component_type` CHECK constraint to accept the new values). Detailed change list:

   - **Variant emission:** add helper functions `Get-FunctionVariantShape`, `Get-ConstantVariantShape`, `Get-MethodVariantShape`, `Get-TimerVariantShape`, `Get-ImportVariantShape`, `Get-EventVariantShape` modeled after the CSS populator's `Get-VariantShape`. Each helper returns `@{ ComponentType, VariantType, VariantQualifier1, VariantQualifier2 }` for its component family. Thread the result into the row builder via new parameters on `New-AssetRow` / `Add-JsDefinitionRow`. Update the bulk-insert DataTable to include the three variant columns.
   - **`parent_function` wiring:** thread enclosing-function-name context through `Invoke-AstWalk`. Visitor receives `($Node, $ParentChain, $ParentFunctionName)`. The walker maintains the stack: when entering a `FunctionDeclaration` / `FunctionExpression` / `ArrowFunctionExpression` / `MethodDefinition`, push the function name; pop on exit. Every USAGE row stamps `parent_function` from the current top-of-stack value. For `JS_METHOD` and `JS_METHOD_VARIANT` rows, `parent_function` carries the enclosing class name (push class name when entering `ClassDeclaration` / `ClassExpression` body).
   - **CSS pre-load reporting:** when `Get-SqlData` returns 0 CSS_CLASS DEFINITION rows, emit a banner-style warning at the END of the run summary (so it's the last thing the user sees, not buried mid-run). Format: `"⚠ DEGRADED OUTPUT: N CSS_CLASS USAGE rows have source_file='<undefined>' because no CSS_CLASS DEFINITION rows were available for cross-reference. Run Populate-AssetRegistry-CSS.ps1 first if you want correct scope/source_file values."`
   - **`drift_codes` width fix:** populator currently calls `Get-NullableValue $r.DriftCodes 4000`. Change to `500` to match live schema. Same pattern review for `source_section` (`VARCHAR(150)`) and `parent_function` (`VARCHAR(200)`).

   **Verification:** after the populator pass, the verification query results should show (a) variant columns populated for the relevant component types — non-zero count of rows where `variant_type IS NOT NULL`; (b) `parent_function` populated for all USAGE rows that fall inside a function body and for all `JS_METHOD` / `JS_METHOD_VARIANT` rows; (c) the column-fill audit confirms every column in the table receives at least one non-NULL value across the row set.

2. **HTML populator catch-up to current spec** — bring `Populate-AssetRegistry-HTML.ps1` to current state. References the dropped columns from the 2026-05-03 migration plus G-INIT-3. HTML format spec design follows.

3. **engine-events.js → cc-shared.js refactor** — once the JS populator runs clean, refactor the canonical shared file to be the spec reference implementation. After cc-shared.js is clean, refactor remaining page files one at a time.

4. **Refresh-AssetRegistry.ps1 orchestrator** — write the cross-populator orchestrator. Single TRUNCATE, then dispatch CSS → HTML → JS in order, with `sp_getapplock` single-instance locking and consolidated logging.

---

## Architecture decisions (locked in)

### Naming and structure

- Table: `dbo.Asset_Registry` — single table, not three per-language tables.
- Schema: `dbo` (no CC-specific schema prefix).
- **Three populators + one orchestrator** (orchestrator pending). CSS, HTML, JS each have their own dedicated populator. Each parser has substantial complexity (Node + PostCSS, PS-native, Node + Acorn) and different debugging surfaces; length and maintainability favor separation.
- Helper Node scripts live alongside (`parse-css.js`, `parse-js.js` registered under `Tools.Utilities` in `Object_Registry`).
- Manual trigger from Admin page (no scheduling initially). Currently each populator runs standalone via direct PowerShell execution.
- Standalone server (FA-SQLDBB), not AG.

### Single-table model with reference_type/scope

The table holds **one row per instance** (definition or usage). DEFINITION vs USAGE is captured in the `reference_type` column. SHARED vs LOCAL is captured in the `scope` column. A shared component used on multiple pages produces multiple USAGE rows — one per consumer location. Lets a single query return the complete picture for any page or any component without joins.

### Refresh strategy: TRUNCATE + reload per file_type

The catalog represents **current state only**. There is no operational value in tracking historical "this used to exist." Standardization work is expected to retire more rows than it adds per run; under a MERGE+soft-delete model, the table would fill with retired rows that every query would need to filter out. Truncate-and-reload sidesteps that entirely.

Refresh semantics:

- **Standalone execution:** each populator deletes only its own slice (`WHERE file_type = 'CSS'` etc.) before bulk-inserting. Makes each populator independently re-runnable for development without disturbing the other slices.
- **Orchestrated execution (when `Refresh-AssetRegistry.ps1` is built):** the orchestrator TRUNCATEs the whole table once at the start, and each populator's DELETE-WHERE becomes a harmless no-op on already-empty data.

No external tables FK to `asset_id`, so identity stability across runs is not required. Manual annotations — when added later — go in a **separate annotations table keyed on the natural key** `(file_name, component_type, component_name, reference_type, occurrence_index, variant_type, variant_qualifier_1, variant_qualifier_2)`, NOT on the unstable `asset_id`. The annotations table is where the use cases originally targeted at `design_notes` and `related_asset_id` (cross-references between rows, freeform design rationale on specific rows) will live; those columns were dropped from `Asset_Registry` as part of OQ-INIT-1 / G-INIT-3 resolution.

### Schema columns under truncate+reload

- **`occurrence_index`** — per-file ordinal disambiguator for multiple instances of the same component within a parse. Forms part of the natural key. Computed during parse, not maintained across runs. CSS populator has `Set-OccurrenceIndices` function that runs after the row set is built.
- **`last_parsed_dttm`** — set to `SYSDATETIME()` on every insert under truncate+reload (every row is freshly inserted each run). Reserved for any future shift in refresh strategy.

### Extraction targets are content types, not file extensions

The catalog organizes by what's being extracted, not by file extension. A single physical file can be visited by multiple extractors, each catching different content types within it.

| Source file extension | What it contains |
|---|---|
| `*.css` | CSS only |
| `*.js` | JS code, plus JS template strings that may contain embedded HTML markup (and rarely embedded CSS) |
| `*.ps1` (routes in `/scripts/routes/`) | PS code, plus here-strings containing HTML markup (which may contain inline `<style>` blocks with CSS or `<script>` blocks with JS) |
| `*.ps1` (APIs, suffix `-API.ps1`) | PS code primarily; rarely contains HTML/CSS/JS |
| `*.psm1` (helpers in `/scripts/modules/`) | PS code plus HTML emission (here-strings or string-concatenation patterns) |

The production extractors are organized by content type they extract, not by file extension they read:

- The CSS populator reads only `.css` files
- The HTML populator reads `.ps1` and `.psm1` files (looking for HTML markup wherever it appears in string tokens)
- The JS populator reads `.js` files and emits both Group A rows (HTML markup found in template strings — closes the consumption gap left by the HTML populator) and Group B rows (JS code itself)

The `file_type` column on each row reflects what content type was extracted, not the file extension. A row from a JS template string in `bidata-monitoring.js` would have `file_type='HTML'` and `file_name='bidata-monitoring.js'` — distinguishable from `file_type='JS'` rows in the same file.

### Coverage gaps from the content-type model

Two known content-type gaps remain:

**Gap 1: Inline `<style>` blocks in route HTML.** A route .ps1 file with CSS rules inside an HTML `<style>` block within a here-string has those rules invisible to all current populators. The HTML extractor sees the `class="..."` USAGE but not the inline definition. The defined class shows up as `source_file = '<undefined>'`. Convention discourages inline `<style>` in this codebase, so prevalence is likely low. Future phase work.

**Gap 2: Inline `<script>` blocks in route HTML.** Same shape as Gap 1 but for JS functions defined inline in route HTML. Convention discourages inline `<script>` (JS lives in dedicated .js files), so prevalence is likely very low. Future phase work.

(Phase 1C — HTML inside JS template strings — has been **closed** by the JS populator's Group A coverage. Earlier doc revisions described this as an open gap; it is no longer.)

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
| `JS_IMPORT` | An ES module import or Node `require` statement. Always carries a non-NULL `variant_type` (default / named / namespace / require). | JS |
| `JS_CONSTANT` | A primitive-value `const` declaration (string, number, boolean, null) in a CONSTANTS or FOUNDATION section. The base form. | JS |
| `JS_CONSTANT_VARIANT` | A compound-value `const` declaration (object, array, regex) in a CONSTANTS or FOUNDATION section. | JS |
| `JS_STATE` | A `var` declaration in a STATE section. | JS |
| `JS_FUNCTION` | A regular `function name() {}` declaration at module scope, or a `cc-shared.js` function called from another file (USAGE row). The base form. | JS |
| `JS_FUNCTION_VARIANT` | A function defined as an arrow expression, function expression, async function, async arrow, or generator. | JS |
| `JS_HOOK` | A page lifecycle hook function (e.g., `onPageRefresh`) inside the `FUNCTIONS: PAGE LIFECYCLE HOOKS` banner. | JS |
| `JS_CLASS` | A JavaScript class declaration. | JS |
| `JS_METHOD` | A regular method defined inside a class body. The base form. | JS |
| `JS_METHOD_VARIANT` | A static method, getter, setter, or async method inside a class body. | JS |
| `JS_TIMER` | A `setInterval` or `setTimeout` call assigned to a tracked handle. Always carries a non-NULL `variant_type` (interval / timeout). | JS |
| `JS_EVENT` | An event handler binding (`addEventListener` or direct `.on<event>=` assignment). Always carries a non-NULL `variant_type` (add_listener / property_assign). | JS |
| `PS_FUNCTION` | A PowerShell function definition. | (Future — Phase 3) |
| `PS_PARAM` | A PowerShell parameter. | (Future — Phase 3) |
| `PS_COMMAND` | A PowerShell command invocation worth cataloging. | (Future — Phase 3) |
| `PS_ASSIGNMENT` | A PowerShell module-scope assignment. | (Future — Phase 3) |
| `API_ROUTE` | An `Add-PodeRoute` definition. | (Future — Phase 3) |

### Variant model

The variant columns (`variant_type`, `variant_qualifier_1`, `variant_qualifier_2`) discriminate sub-flavors of certain component types. Two patterns are in use, depending on whether the component family has a true "base" form:

- **Base + `_VARIANT` companion type** — used where there is a clear base case distinguishable from variant expressions. Examples: `CSS_CLASS` / `CSS_VARIANT` (CSS); `JS_FUNCTION` / `JS_FUNCTION_VARIANT`, `JS_CONSTANT` / `JS_CONSTANT_VARIANT`, `JS_METHOD` / `JS_METHOD_VARIANT` (JS).
- **Single component type, always non-NULL `variant_type`** — used where every instance is inherently a variant of something. Examples: `JS_IMPORT` (always default / named / namespace / require), `JS_TIMER` (always interval / timeout), `JS_EVENT` (always add_listener / property_assign).

Per-file-type spec docs document the full variant_type / qualifier_1 / qualifier_2 grid for their language. See `CC_CSS_Spec.md` Section X (TBD) for CSS variants and `CC_JS_Spec.md` Section 17.5 for JS variants.

### file_type values

`CSS`, `JS`, `PS`, `HTML`. The `HTML` value is for rows extracted from HTML markup — these rows have `file_name` pointing at the .ps1/.psm1/.js file the markup lives in.

### Scope determination

- **For CSS DEFINITIONs:** SHARED if the file is in the curated shared-files list for its zone (CC zone: `engine-events.css`. Docs zone: the seven `docs-*.css` files). LOCAL otherwise.
- **For JS DEFINITIONs:** SHARED if the file is in the curated shared-files list for its zone (CC zone: `engine-events.js`. Docs zone: `nav.js`, `docs-controlcenter.js`, `ddl-erd.js`, `ddl-loader.js`). LOCAL otherwise.
- **For HTML USAGEs (CSS_CLASS USAGE rows from the HTML and JS populators):** cross-referenced against existing CSS_CLASS DEFINITION rows in the consumer's zone. SHARED if the class has any SHARED CSS DEFINITION in that zone; LOCAL if only LOCAL DEFINITION exists in that zone; LOCAL with `source_file = '<undefined>'` if no DEFINITION exists in any CSS file in the zone.
- **For HTML IDs:** always LOCAL (IDs are inherently page-specific).

### Methodology

- **CSS:** Node + PostCSS 8.5.12 + postcss-selector-parser 7.1.1 (subprocess from PowerShell)
- **JS:** Node + acorn 8.16.0 + acorn-walk 8.3.5 (subprocess from PowerShell)
- **PowerShell tokenization for HTML extraction:** built-in `[System.Management.Automation.Language.Parser]::ParseFile()` — no external dependency

---

## Schema (current state)

The schema below reflects what is currently live in `dbo.Asset_Registry` on FA-SQLDBB, verified against `INFORMATION_SCHEMA.COLUMNS` on 2026-05-05.

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
    component_name        VARCHAR(256)   NULL,
    variant_type          VARCHAR(30)    NULL,        -- per-language values; NULL for base rows of types that have a base form
    variant_qualifier_1   VARCHAR(100)   NULL,
    variant_qualifier_2   VARCHAR(100)   NULL,
    reference_type        VARCHAR(20)    NOT NULL,    -- DEFINITION, USAGE
    scope                 VARCHAR(20)    NOT NULL,    -- SHARED, LOCAL
    source_file           VARCHAR(200)   NOT NULL,    -- where defined; '<undefined>' if no def
    source_section        VARCHAR(150)   NULL,        -- COMMENT_BANNER title for context
    signature             VARCHAR(MAX)   NULL,        -- full selector / declaration / function signature
    parent_function       VARCHAR(200)   NULL,        -- enclosing function name; for JS_METHOD/JS_METHOD_VARIANT, the enclosing class name
    raw_text              VARCHAR(MAX)   NULL,        -- raw source snippet
    purpose_description   VARCHAR(MAX)   NULL,        -- parser-populated from purpose comments / banner descriptions / file header purpose paragraphs
    occurrence_index      INT            NOT NULL DEFAULT(1),
    drift_codes           VARCHAR(500)   NULL,        -- comma-separated stable short codes
    drift_text            VARCHAR(MAX)   NULL,        -- joined human-readable drift descriptions
    last_parsed_dttm      DATETIME2(7)   NOT NULL DEFAULT(SYSDATETIME())
);
```

**Constraints:** CHECK on `file_type` ∈ {CSS, JS, PS, HTML}, CHECK on `component_type` ∈ enumerated list, CHECK on `reference_type` ∈ {DEFINITION, USAGE}, CHECK on `scope` ∈ {SHARED, LOCAL}.

**Variant model:** Per-language values for `variant_type`, `variant_qualifier_1`, `variant_qualifier_2` are documented in the per-language spec docs. See the "Variant model" subsection of "Component types" above for the architectural pattern (base + `_VARIANT` companion vs. single type with always-non-NULL `variant_type`) and pointers into the per-language specs.

**Schema history:**

- The 2026-05-03 schema migration dropped `state_modifier`, `component_subtype`, `parent_object`, and `first_parsed_dttm`.
- The 2026-05-04 G-INIT-3 cleanup dropped `related_asset_id`, `design_notes`, and `is_active`. The annotation use cases for `related_asset_id` and `design_notes` are reserved for a future separate annotations table keyed on the natural key.
- The 2026-05-05 JS variant introduction added `JS_FUNCTION_VARIANT`, `JS_CONSTANT_VARIANT`, and `JS_METHOD_VARIANT` to the `component_type` CHECK constraint enumeration. See `ALTER_AssetRegistry_AddJsVariantTypes.sql`.

**Width notes:**

- `drift_codes` is `VARCHAR(500)`, not `VARCHAR(MAX)`. Sufficient for ~25 typical code names; populators should truncate to 500 if they ever approach the limit.
- `variant_type` is `VARCHAR(30)`. Largest current value is `compound_pseudo` (15 chars) for CSS. JS variant_type values fit comfortably (`property_assign` = 15, `async_arrow` = 11).

**No CREATE TABLE in source control.** The DDL has not been committed to `xFACts-SQL/`. The schema's authoritative documentation lives here and in `Object_Metadata` (column descriptions, design notes, status_value enumerations). When the parser pipeline goes live and this working doc is retired, the CREATE TABLE may be checked in alongside.

---

## occurrence_index design

Under truncate+reload, occurrence_index serves a single purpose: **uniquely identify multiple instances of the same component within a file's parse**. Computed fresh on each run.

**Definition:** 1-based ordinal of how many times this specific tuple has been seen so far during the current parse, in source-position order. The tuple shape varies by component type — for CSS_VARIANT rows it includes `variant_type` and the qualifier columns; for simpler rows it's just `(file_name, component_name, reference_type)`.

**Computation:** during parse, the populator maintains a counter dictionary keyed by the tuple. When emitting a row, it increments the counter and assigns the new value to occurrence_index. The CSS populator's `Set-OccurrenceIndices` function does this in a final pass after the row set is built.

**Forms part of the natural key** `(file_name, component_type, component_name, reference_type, occurrence_index, variant_type, variant_qualifier_1, variant_qualifier_2)`. This is the stable identifier for cross-references — for example, when a future annotations table needs to attach a design note to "the second `.bkp-pipeline-card.warning` variant in `backup.css`."

**Not stable across reorderings:** if a developer removes the 1st instance, the formerly-2nd one becomes the new 1st. Annotations attached to occurrence_index=1 would now apply to a different physical instance. Acceptable because the catalog represents current state, not history; reorderings of identical components are rare in practice; and annotations layer on top via a separate table where reordering issues can be reconciled.

---

## Production-rewrite remaining work

Most of what was originally scoped under "production rewrite" has shipped. What remains:

### HTML populator catch-up to current spec

The HTML populator still references the pre-migration `state_modifier='<dynamic>'` pattern in its docstring and dynamic-handling logic. Bring it current:

- Replace `state_modifier='<dynamic>'` rows with the post-migration schema. Either drop the dynamic-modifier capture entirely (it was never very useful) or migrate to a `variant_qualifier_*` representation if there's a defensible mapping.
- Validate against full HTML row set after change.
- Update its docstring and CHANGELOG to reflect the new approach.
- Confirm the populator's bulk-insert DataTable schema matches the current `dbo.Asset_Registry` shape (no extra columns being written that the table no longer has).

### Refresh-AssetRegistry.ps1 orchestrator (not yet built)

When built, the orchestrator should:

1. Acquire `sp_getapplock` for single-instance protection.
2. TRUNCATE `dbo.Asset_Registry` once.
3. Run CSS populator (must run first — it produces the CSS_CLASS DEFINITION rows that HTML and JS populators cross-reference for scope resolution).
4. Run HTML populator.
5. Run JS populator.
6. Release applock.
7. Per-file success/failure summary at end.
8. Standard logging via `Write-Log` from `xFACts-OrchestratorFunctions.ps1`.

The CSS-must-run-first dependency is real and not currently enforced anywhere except by manual run order. The orchestrator landing closes that hole.

### Production script classification (open question)

Where the populators get classified in `Object_Registry` is still parked. Two reasonable options:

- **Tools.Utilities** — parallel to `sp_SyncColumnOrdinals` (Object_Metadata maintenance utility). Parser helpers `parse-css.js` and `parse-js.js` are already registered here, so the populators going here would keep the whole parser pipeline grouped together.
- **Documentation.Pipeline** — parallel to `Generate-DDLReference.ps1` (produces JSON that downstream documentation pages consume). Asset_Registry data may eventually drive generated documentation views, making this the natural home if that's the long-term intent.

Decide when the orchestrator lands; the decision doesn't affect functionality, only registration metadata.

---

## Phases (current state)

| Phase | Description | Status |
|---|---|---|
| 0 | Schema design + DDL | **DONE** — table created, columns finalized through testing, schema migration shipped 2026-05-03, follow-up cleanup landed 2026-05-04 |
| 0.5 | Object_Registry + Object_Metadata baselines | **DONE** — registered under Engine.SharedInfrastructure with column descriptions, design notes, and status_value enumerations |
| 1A | CSS extraction | **DONE** — production populator at current spec generation. All four `purpose_description` sources wired (G-INIT-3 + G-INIT-4) |
| 1B | HTML extraction from .ps1/.psm1 string tokens | **DONE** but **PRE-MIGRATION** — production-grade structure, but emits old `state_modifier='<dynamic>'` shape and needs catch-up to post-migration schema |
| 1C | HTML extraction from .js template strings | **DONE** — covered by JS populator's Group A |
| 1D | Production rewrite + orchestrator | **PARTIAL** — populators are production-grade; orchestrator (`Refresh-AssetRegistry.ps1`) not yet built |
| 2 | JS function/constant/hook/class/method extraction | **DONE** — covered by JS populator's Group B |
| 3 | PS function/route extraction from .ps1/.psm1 | FUTURE — function definitions, Add-PodeRoute calls |
| 4 | Inline `<style>` extraction from route HTML | FUTURE — closes Gap 1 |
| 5 | Inline `<script>` extraction from route HTML | FUTURE — closes Gap 2 |
| 6 | Admin UI integration | FUTURE — manual trigger button on Admin page |
| 7 | Generated documentation views | FUTURE — auto-generated markdown from registry queries |
| Future | Annotations table | FUTURE — separate table keyed on natural key for design notes and cross-references when manual annotation work begins |

---

## Open questions (still to resolve)

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

Baseline registration done — Object_Registry row exists and column descriptions are populated. **Still deferred:** enrichment Object_Metadata content (data_flow, design_note, status_value, query, relationship_note rows). Generated only after the orchestrator lands and the production behavior is stable.

### 5. Helper consumption gap

`xFACts-Helpers.psm1` currently produces a small fraction of the HTML rows that visual inspection suggests are present. The dominant pattern is string-variable indirection — a class name is built into a variable on one line, and the variable is injected into HTML on another line. The HTML populator can't see this statically.

Open question: how much investigation is worthwhile before living with what's there? The CC File Format Standardization initiative addresses this as a coding-convention issue rather than a parser-complexity issue. Files refactored to conform to the format spec produce complete extraction; files that haven't converted produce reduced row counts on indirection patterns. The catalog itself becomes a measure of conversion progress.

---

## Catalog data observations (point-in-time snapshots)

These are operational findings from specific catalog snapshots. **Not living truth** — re-running the populators will produce different counts. Kept here as reference points for the standardization work's scope and as a record of the kinds of insights the catalog surfaces.

### 2026-05-04 snapshot (post-G-INIT-4)

Total rows: 7,577. 33 CSS files scanned (28 in the CC zone, 7 in the docs zone, plus `business-services-spec.css` and four other `*-spec.css` files representing the new-format reference implementations). Rows-with-drift: 5,180 (68.4%) — the high percentage reflects that most CSS files are pre-spec.

`purpose_description` coverage on the comment-derived row classes:

| Row class | Total | With purpose | Without purpose |
|---|---|---|---|
| FILE_HEADER | 33 | 25 | 8 |
| COMMENT_BANNER | 308 | 117 | 191 |
| CSS_CLASS DEFINITION | 3,557 | 715 | 2,842 |
| CSS_VARIANT DEFINITION | 1,349 | 161 | 1,188 |

Filtering to just the five new-format spec-compliant CSS files: 100% coverage on all four row classes (37 of 37 COMMENT_BANNER, 261 of 261 CSS_CLASS DEFINITION, 106 of 106 CSS_VARIANT DEFINITION, 5 of 5 FILE_HEADER). The non-compliant files contribute every miss in the global numbers — drift counts (`MISSING_PURPOSE_COMMENT` = 2,842, `MISSING_VARIANT_COMMENT` = 1,188) match the row-class miss counts exactly.

Top drift codes: `MISSING_PURPOSE_COMMENT` (2,842), `FORBIDDEN_DESCENDANT` (1,378), `MISSING_VARIANT_COMMENT` (1,188), `MISSING_SECTION_BANNER` (684). All four are pre-spec residue and will close as files migrate during the page-at-a-time phase.

### Refactor candidates surfaced by the catalog (2026-05-02 snapshot, still useful)

- **Keyframe duplication:** 26 LOCAL definitions of `pulse`, `spin` etc. that should be using the SHARED keyframes in `engine-events.css`.
- **Custom modal cleanup:** 81 custom `modal-*` uses across 12 pages should migrate to shared `xf-modal-*`. Easy targets: Backup, BIDATA, JBoss (already partially adopted).
- **slide-panel naming:** BatchMonitoring uses `xwide`, DmOperations uses `extra-wide`, everyone else uses `wide`. Rename for consistency.
- **server-health.css line 715/729:** 11 ID-prefixed rules duplicating shared `.slide-panel.wide` styles (the 33-class enumeration discovered during investigation).
- **index-maintenance.css line 887/896:** same pattern, 6 ID-prefixed rules.
- **ApplicationsIntegration `admin-badge`/`admin-tool`:** classes used in HTML with no CSS definition.
- **Admin page `af-*`/`gc-*`/`meta-*`/`sched-*-header-right`:** classes used in HTML without CSS definitions.
- **Home.ps1 `subtitle` vs shared `page-subtitle`:** possible rename opportunity.

### Per-page consumption profile (2026-05-02 snapshot)

Pages clustered into three groups:

- **Heavy SHARED users** (well-aligned to engine-events infrastructure): BIDATA, Backup, IndexMaintenance, DmOperations, BatchMonitoring.
- **Balanced:** DBCC, JobFlow, JBoss, FileMonitoring, ReplicationMonitoring, BusinessServices, BusinessIntelligence.
- **Heavy LOCAL users** (mostly own UI vocabulary): Admin (largest LOCAL catalog), PlatformMonitoring, ServerHealth, BDLImport, ApplicationsIntegration, ClientPortal (intentionally has own visual language — light theme inside CC dark shell).

---

## Environment state (FA-SQLDBB)

```
C:\Program Files\
├── nodejs\                          ← Node.js 24.15.0 (npm 11.12.1) — actively used
│
├── nodejs-libs\                     ← Active parser libraries
│   ├── _downloads\                  (.tgz tarballs, kept for re-extraction)
│   └── node_modules\
│       ├── acorn\                   ← acorn 8.16.0
│       ├── acorn-walk\              ← acorn-walk 8.3.5
│       ├── postcss\                 ← postcss 8.5.12
│       ├── postcss-selector-parser\ ← 7.1.1
│       ├── nanoid\                  (postcss dep)
│       ├── picocolors\              (postcss dep)
│       ├── source-map-js\           (postcss dep)
│       ├── cssesc\                  (postcss-selector-parser dep)
│       └── util-deprecate\          (postcss-selector-parser dep)
│
└── dotnet-lib\                      ← LEGACY — clean up post-launch
    ├── Esprima.3.0.6\               UNUSED
    ├── ExCSS.4.3.1\                 UNUSED
    ├── Acornima.1.6.1\              UNUSED
    └── (System.* support libs for the abandoned NuGet packages)
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

The Node helpers are stable and don't need changes for the orchestrator work — they're invoked the same way by the populators today. G-INIT-4's comment-text capture happens entirely in the PowerShell side; the Node parser already emits each comment node's `text` field in its JSON output, so the populator just had to start reading the field.

---

## Lessons learned

### .NET Framework + PS 5.1 + NuGet = dependency hell

The single biggest takeaway. PowerShell 5.1 isn't a real NuGet resolver. NuGet packages target multiple frameworks with different transitive dependency assumptions. Every NuGet package's runtime dependency cluster has to be manually assembled. If anyone in the future considers parsing CSS or JS via a .NET library on PS 5.1, this is the path everyone has tried and failed.

### Why Node + acorn / Node + PostCSS won

- Native to JS ecosystem — runs in its native environment, no impedance mismatch
- Tiny dependency clusters (acorn = 0 deps; postcss = 3 small deps; selector-parser = 2 small deps)
- Battle-tested — what every modern web tool uses
- Air-gappable — Node MSI installs offline, .tgz transfers offline, no internet at runtime
- Subprocess overhead is ~50-100ms per file — non-issue for ~80 files
- Trivial PowerShell integration via stdin/stdout JSON
- Standard `node_modules\` layout means modules find each other automatically

### Lesson about library layout

Initial install used `nodejs-libs\<package>\package\` layout, which broke when modules tried to require their dependencies. Fixed by restructuring to standard `nodejs-libs\node_modules\<package>\`. **Lesson:** when integrating with an ecosystem, use that ecosystem's standard conventions.

### Out-of-scope / discarded approaches

Listed for reference so we don't reconsider these absent new information:

- **ExCSS** — no line numbers, dropped @keyframes/@media handling
- **Esprima.NET** — abandoned upstream, last active development ~3 years ago
- **Acornima** — same .NET Framework dependency conflicts as Esprima, no path forward without binding redirects
- **Hand-rolled CSS or JS tokenizer** — would only catch known patterns, miss edge cases, no value over Node + standard parser
- **Jurassic / NiL.JS / YantraJS** — JS interpreters not designed for AST-extraction workflows
- **Roslyn** — C#/VB analyzer, not for JS or CSS
- **PostCSS via .NET wrapper** — no good standalone .NET CSS parser exists

---

## Document maintenance

Updated at session end with: decisions made, environment changes, populator status changes, next pickup point. When pipeline goes live (orchestrator built, all phases through 7 reached), content useful for permanent docs gets harvested into HTML inside Control Center, and this file is discarded.

### Revision history

| Date | Description |
|---|---|
| 2026-05-05 | JS variant model designed and documented. Three new component_type values added to the master list — `JS_FUNCTION_VARIANT`, `JS_CONSTANT_VARIANT`, `JS_METHOD_VARIANT` — to capture sub-flavors that have a true base form distinguishable from variant expressions (mirroring the CSS_CLASS / CSS_VARIANT split). Three component types — `JS_IMPORT`, `JS_TIMER`, `JS_EVENT` — keep their single name and always carry a non-NULL `variant_type` because every instance is inherently a variant. Schema (current state) DDL block rewritten to match `INFORMATION_SCHEMA.COLUMNS` output verbatim — corrects pre-existing widths (`drift_codes` is `VARCHAR(500)` not `VARCHAR(MAX)`; `variant_type` is `VARCHAR(30)` not `VARCHAR(20)`); confirms `related_asset_id` / `design_notes` / `is_active` shipped as dropped from G-INIT-3; aligns column ordering. New "Variant model" subsection under Component types documents the architectural pattern (base + `_VARIANT` companion vs. single type with always-non-NULL `variant_type`). "Where we left off" pickup options reordered to lead with the JS populator change pass; full change list documented inline (variant emission helpers per component family, parent_function AST-walker threading, CSS pre-load louder reporting, drift_codes width fix). Companion deliverables: `CC_JS_Spec.md` v1.1 (Section 17 expanded with variant grid in 17.5), `ALTER_AssetRegistry_AddJsVariantTypes.sql` (component_type CHECK constraint extension). |
| 2026-05-04 | G-INIT-4 implemented and verified live. CSS populator now captures per-class purpose comments onto `CSS_CLASS DEFINITION` rows and per-variant trailing inline comments onto `CSS_VARIANT DEFINITION` rows via the new `ConvertTo-CleanCommentText` helper and threaded `-PrecedingCommentText` / `-TrailingInlineCommentText` parameters. Coverage at 100% on the five new-format spec-compliant CSS files. Schema documentation updated to reflect post-G-INIT-3/4 shape. Phases table updated. Pickup options reordered to lead with JS spec design. Added 2026-05-04 catalog snapshot. |
| 2026-05-04 | G-INIT-3 closed and verified live — DDL drops applied, patched populator running, FILE_HEADER and COMMENT_BANNER rows populating `purpose_description` correctly. G-INIT-4 raised in `CC_Initiative.md` to track the remaining CSS coverage gap: per-class purpose comments on `CSS_CLASS DEFINITION` rows and per-variant trailing inline comments on `CSS_VARIANT DEFINITION` rows. Tagged as next session's opener. Pickup options reordered to lead with G-INIT-4. |
| 2026-05-04 | OQ-INIT-1 (`purpose_description` not populated) diagnosed and resolved. Root cause: the CSS populator's `New-RowSkeleton` does not include a `PurposeDescription` field, so every row inserts NULL for this column. The file-header purpose paragraph was being written to `signature` instead, and section-banner descriptions extracted by `Get-BannerInfo` were being computed and discarded. Resolution scope agreed: keep the column, wire up parser population (Option B). Three additional columns identified for removal as part of the same investigation — `related_asset_id`, `design_notes`, and `is_active`. The first two are manual-annotation columns whose use cases relocate to a separate annotations table keyed on the natural key (since manual content cannot survive truncate-and-reload at the row level). The third is dead under the truncate-and-reload model (every row is always active by construction; the column adds zero query value and creates a misleading state-tracking signal). **Implementation delivered:** `Drop_AssetRegistry_Columns.sql` (DDL drop script with default-constraint handling for `is_active`) and patched `Populate-AssetRegistry-CSS.ps1` (PurposeDescription added to row skeleton; Add-FileHeaderRow and Add-CommentBannerRow wired up; DataTable column list trimmed; new verification query reports purpose_description coverage). Cross-populator audit confirmed no other CSS populator references to the dropped columns; HTML and JS populators have pre-existing issues against the 2026-05-03 schema migration plus references to the columns being dropped today, all of which are deferred to their respective spec catch-up sessions. Schema section in this doc rewritten to reflect target post-resolution shape. |
| 2026-05-04 | Renamed from `Asset_Registry_Working_Doc.md` to `CC_Catalog_Pipeline_Working_Doc.md` to align with the CC_* doc family. Doc consolidation note updated to reflect the file format documentation reorganization (retirement of `CC_Component_Registry_Plan.md`, `CC_FileFormat_Standardization.md`, `CC_FileFormat_Spec.md`, `CC_FileFormat_Parser_Friendly_Conventions_Recommendations.md`; replacement by `CC_Initiative.md` plus the `CC_*_Spec.md` family). Schema DDL rewritten to reflect post-migration shape (dropped `state_modifier`, `component_subtype`, `parent_object`, `first_parsed_dttm`; added `variant_type`, `variant_qualifier_1`, `variant_qualifier_2`, `drift_codes`, `drift_text`). Test populator section replaced with current populator status (production scripts exist; HTML populator is one spec generation behind CSS; no orchestrator built yet). Phase 1C reclassified as DONE (covered by JS populator's Group A). Phase 1D reclassified as PARTIAL. Project goal section trimmed (full motivation now lives in `CC_Initiative.md` Purpose). Single-table model and refresh strategy sections trimmed (covered by spec docs' catalog model essentials). `purpose_description` not currently being populated noted explicitly with pointer to OQ-INIT-1. |
| 2026-05-02 | Phase 0 (DDL) + Phase 1A (CSS) + Phase 1B (HTML) all completed. ~7,400 rows of catalog data. Drift detection and consumption matrix working. Refresh strategy decision: TRUNCATE + reload per file_type, not MERGE upsert. Object_Registry row + Object_Metadata baselines + column descriptions + design notes + status_value enumerations inserted (Asset_Registry under Engine.SharedInfrastructure). Parser helpers `parse-css.js` and `parse-js.js` registered under Tools.Utilities. Added "extraction targets are content types not file extensions" framing — formalized Gaps 1/2/3 (HTML-in-JS, inline `<style>`, inline `<script>`) as future phases 1C / 4 / 5. |
| 2026-05-01 | Environment setup complete. Parsers validated. Phase 0 next. |
| 2026-04-30 | Initial framework draft (as `CC_Component_Registry_Plan.md`). Schema proposed, motivation captured. |

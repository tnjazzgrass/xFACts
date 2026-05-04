# CC Asset Registry Working Document

**Purpose:** Single working document for the Asset_Registry parser implementation effort. Tracks the parser pipeline state, environment, schema state, populator status, lessons learned, and next-session pickup points. This is operational documentation parallel to the CC File Format spec docs — the spec docs say what source files have to look like; this doc says how the parser pipeline that catalogs them is built and where it stands today.

**Will be discarded after the parser pipeline goes live.** Permanent documentation will be HTML in the Control Center, harvesting relevant content from this doc.

> Part of the Control Center File Format initiative. For initiative direction, current state, session log, and the platform-wide prefix registry, see `CC_Initiative.md`. For per-file-type spec content (rules every source file must follow), see the relevant `CC_*_Spec.md` doc.

---

## Where we left off

**Catalog is functional and queryable.** Production populator scripts are deployed and have run successfully against the full Control Center codebase. CSS populator is at the current spec generation; HTML and JS populators are production-grade but pre-date the most recent CSS spec migration and may have catch-up work pending.

**Production scripts that exist:**

- `Populate-AssetRegistry-CSS.ps1` — at current spec generation. CHANGELOG runs through 2026-05-03 with entries reflecting the variant_qualifier schema migration, FOUNDATION exemptions, FEEDBACK_OVERLAYS section type, FILE ORG list parser, and OQ-CSS-1 resolution (`:not()` and stacked pseudos forbidden).
- `Populate-AssetRegistry-HTML.ps1` — production-grade structure (full comment-based help, orchestrator integration, write-log, per-file try/catch). Latest CHANGELOG entry is 2026-05-02. **Is one spec generation behind CSS** — populator docstring still describes the `state_modifier='<dynamic>'` pattern that the schema migration retired. Bring-current work pending.
- `Populate-AssetRegistry-JS.ps1` — production-grade structure. Latest CHANGELOG entry is 2026-05-02. Three row groups: A (HTML-from-JS — closes the consumption gap left by the HTML populator), B (JS as own language — `JS_FUNCTION`, `JS_CONSTANT`, `JS_CLASS`, `JS_METHOD`, `JS_IMPORT`, plus `COMMENT_BANNER`), C (JS events — `addEventListener` and direct `.on<event>=` assignments).

**What has NOT been built yet:**

- `Refresh-AssetRegistry.ps1` orchestrator. Each populator runs standalone today. The cross-cutting "TRUNCATE the table, then run all three populators in order" coordination is currently a manual sequence. Listed as Phase 1D scope.

**Next session pickup options:**

1. **G-INIT-4 implementation (next session's opener)** — Complete CSS `purpose_description` coverage. The CSS populator currently captures purpose-description text from two of three sources (file headers and section banners, both wired up in G-INIT-3). The third source — comments attached directly to class definitions — is not yet captured. Add per-class purpose comment text to `CSS_CLASS DEFINITION` rows; add per-variant trailing inline comment text to `CSS_VARIANT DEFINITION` rows. Plumbing involves capturing comment text at the detection points (currently the populator only sets `$hasPrecedingComment = $true` and the `$hasTrailingInlineComment` boolean — text is discarded), then threading the text through `Add-RowsForSelector` and `Add-CssClassOrVariantRow` parameter signatures, and writing to `$row.PurposeDescription`. See `CC_Initiative.md` G-INIT-4 for full context.
2. **HTML populator investigation** — bring `Populate-AssetRegistry-HTML.ps1` to current state. Already known broken against the post-2026-05-03 schema migration: references dropped columns `state_modifier`, `component_subtype`, `parent_object`. Plus the three columns dropped today (`design_notes`, `related_asset_id`, `is_active`-via-SELECT). Run an investigation pass against the table and the current state of `parse-html.js` (or wherever HTML parsing logic lives), then design what an HTML format spec looks like applying the same "what would parse-friendly look like 100% of the time" lens that produced the CSS spec.
3. **JS populator investigation** — same investigation pattern as HTML. JS populator has the same dropped-column references plus the same `WHERE is_active = 1` issue against Asset_Registry's CSS_CLASS DEFINITION lookup. JS spec design follows.
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

No external tables FK to `asset_id`, so identity stability across runs is not required. Manual annotations — when added later — go in a **separate annotations table keyed on the natural key** `(file_name, component_type, component_name, reference_type, occurrence_index, variant_type, variant_qualifier_1, variant_qualifier_2)`, NOT on the unstable `asset_id`. The annotations table is where the use cases originally targeted at `design_notes` and `related_asset_id` (cross-references between rows, freeform design rationale on specific rows) will live; those columns are being dropped from `Asset_Registry` as part of OQ-INIT-1 resolution.

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
| `FILE_HEADER` | The file's header block. One row per scanned file. | CSS |
| `COMMENT_BANNER` | A section banner comment. | CSS, JS |
| `CSS_CLASS` | A CSS class definition, or a USAGE reference to a class. | CSS, HTML, JS (Group A) |
| `CSS_VARIANT` | A class variant definition (`class`, `pseudo`, or `compound_pseudo` shape). | CSS |
| `CSS_VARIABLE` | A CSS custom property definition or a `var(--name)` reference. | CSS |
| `CSS_KEYFRAME` | A `@keyframes` definition or a reference. | CSS |
| `CSS_RULE` | A non-class rule (e.g., `body`, `*`) — captured for drift visibility. | CSS |
| `HTML_ID` | An `id="..."` attribute occurrence. | HTML, JS (Group A), CSS (when `#id` appears in selectors) |
| `JS_FUNCTION` | A JavaScript function declaration or expression — definition or usage. | JS |
| `JS_CONSTANT` | A top-level (module-scope) `const`/`let`/`var` non-function declaration. | JS |
| `JS_CLASS` | A JavaScript class declaration. | JS |
| `JS_METHOD` | A method defined inside a class body. | JS |
| `JS_IMPORT` | An ES module import or Node `require` statement. | JS |
| `JS_EVENT` | An event handler binding (`addEventListener` or direct `.on<event>=` assignment). | JS |
| `PS_FUNCTION` | A PowerShell function definition. | (Future — Phase 3) |
| `PS_PARAM` | A PowerShell parameter. | (Future — Phase 3) |
| `PS_COMMAND` | A PowerShell command invocation worth cataloging. | (Future — Phase 3) |
| `PS_ASSIGNMENT` | A PowerShell module-scope assignment. | (Future — Phase 3) |
| `API_ROUTE` | An `Add-PodeRoute` definition. | (Future — Phase 3) |

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

The schema below reflects the **post-OQ-INIT-1-resolution** target shape. Three columns are slated for removal in a follow-up DDL pass; one (`purpose_description`) is slated to begin being parser-populated. Until those changes ship, the live table still contains the dropped columns.

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
    variant_type          VARCHAR(20)    NULL,        -- class, pseudo, compound_pseudo (CSS_VARIANT only)
    variant_qualifier_1   VARCHAR(100)   NULL,        -- e.g., 'disabled' on .btn.disabled
    variant_qualifier_2   VARCHAR(100)   NULL,        -- e.g., 'hover' on .btn:hover
    reference_type        VARCHAR(20)    NOT NULL,    -- DEFINITION, USAGE
    scope                 VARCHAR(20)    NOT NULL,    -- SHARED, LOCAL
    source_file           VARCHAR(200)   NOT NULL,    -- where defined; '<undefined>' if no def
    source_section        VARCHAR(150)   NULL,        -- COMMENT_BANNER title for context
    signature             VARCHAR(MAX)   NULL,        -- full selector / declaration / function signature
    parent_function       VARCHAR(200)   NULL,        -- e.g., '@media (max-width: 1200px)' or containing function name
    raw_text              VARCHAR(MAX)   NULL,        -- raw source snippet
    purpose_description   VARCHAR(MAX)   NULL,        -- parser-populated from purpose comments / banner descriptions / file header purpose paragraphs
    drift_codes           VARCHAR(MAX)   NULL,        -- comma-separated stable short codes
    drift_text            VARCHAR(MAX)   NULL,        -- joined human-readable drift descriptions
    occurrence_index      INT            NOT NULL DEFAULT(1),
    last_parsed_dttm      DATETIME2(7)   NOT NULL DEFAULT(SYSDATETIME())
);
```

**Constraints:** CHECK on `file_type` ∈ {CSS, JS, PS, HTML}, CHECK on `component_type` ∈ enumerated list, CHECK on `reference_type` ∈ {DEFINITION, USAGE}, CHECK on `scope` ∈ {SHARED, LOCAL}, CHECK on `variant_type` ∈ {class, pseudo, compound_pseudo} when not NULL.

**Columns dropped in the 2026-05-03 schema migration (do NOT exist in current table):** `state_modifier`, `component_subtype`, `parent_object`, `first_parsed_dttm`. Earlier revisions of this doc included them in the DDL; that DDL was stale.

**Columns slated for removal under OQ-INIT-1 resolution (still in the live table; will drop in a follow-up DDL pass):**

| Column | Reason for removal |
|---|---|
| `related_asset_id` | Manual annotation column. Manual annotations move to a separate annotations table keyed on the natural key, since manual content cannot survive truncate-and-reload at the row level. |
| `design_notes` | Same as `related_asset_id` — manual annotation column relocates to the annotations table. |
| `is_active` | Defaults to 1 and never changes under truncate-and-reload. The column communicates a state-tracking model the table doesn't actually implement. |

**Column getting newly wired up under OQ-INIT-1 resolution:**

| Column | Status |
|---|---|
| `purpose_description` | The CSS populator's `New-RowSkeleton` does not currently include this column, so every row inserts NULL. The column was originally specified for parser extraction (file header purpose paragraphs, section banner descriptions, class purpose comments) — wiring is the gap. Fix scope: add `PurposeDescription` to the row skeleton; update `Add-FileHeaderRow` to write the purpose paragraph there (currently being smuggled into `signature`); update `Add-CommentBannerRow` to write `BannerInfo.Description` there; update bulk-insert DataTable schema. Optional follow-up: capture preceding-purpose-comment text on CSS_CLASS DEFINITION rows (requires plumbing comment text through several call sites). |

**No CREATE TABLE in source control.** The DDL has not been committed to `xFACts-SQL/`. The schema's authoritative documentation lives in `Object_Metadata` (column descriptions, design notes, status_value enumerations). When the parser pipeline goes live and this working doc is retired, the CREATE TABLE may be checked in alongside.

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
| 0 | Schema design + DDL | **DONE** — table created, columns finalized through testing, schema migration shipped 2026-05-03 |
| 0.5 | Object_Registry + Object_Metadata baselines | **DONE** — registered under Engine.SharedInfrastructure with column descriptions, design notes, and status_value enumerations |
| 1A | CSS extraction | **DONE** — production populator at current spec generation |
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

## Catalog data observations (point-in-time, 2026-05-02 snapshot)

These are operational findings from a specific catalog snapshot. **Not living truth** — re-running the populators will produce different counts. Kept here as reference points for the standardization work's scope and as a record of the kinds of insights the catalog surfaces.

### Refactor candidates surfaced by the catalog

- **Keyframe duplication:** 26 LOCAL definitions of `pulse`, `spin` etc. that should be using the SHARED keyframes in `engine-events.css`.
- **Custom modal cleanup:** 81 custom `modal-*` uses across 12 pages should migrate to shared `xf-modal-*`. Easy targets: Backup, BIDATA, JBoss (already partially adopted).
- **slide-panel naming:** BatchMonitoring uses `xwide`, DmOperations uses `extra-wide`, everyone else uses `wide`. Rename for consistency.
- **server-health.css line 715/729:** 11 ID-prefixed rules duplicating shared `.slide-panel.wide` styles (the 33-class enumeration discovered during investigation).
- **index-maintenance.css line 887/896:** same pattern, 6 ID-prefixed rules.
- **ApplicationsIntegration `admin-badge`/`admin-tool`:** classes used in HTML with no CSS definition.
- **Admin page `af-*`/`gc-*`/`meta-*`/`sched-*-header-right`:** classes used in HTML without CSS definitions.
- **Home.ps1 `subtitle` vs shared `page-subtitle`:** possible rename opportunity.

### Per-page consumption profile

Pages clustered into three groups in the 2026-05-02 snapshot:

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

The Node helpers are stable and don't need changes for the orchestrator work — they're invoked the same way by the populators today.

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
| 2026-05-04 | G-INIT-3 closed and verified live — DDL drops applied, patched populator running, FILE_HEADER and COMMENT_BANNER rows populating `purpose_description` correctly. G-INIT-4 raised in `CC_Initiative.md` to track the remaining CSS coverage gap: per-class purpose comments on `CSS_CLASS DEFINITION` rows and per-variant trailing inline comments on `CSS_VARIANT DEFINITION` rows. Tagged as next session's opener. Pickup options reordered to lead with G-INIT-4. |
| 2026-05-04 | OQ-INIT-1 (`purpose_description` not populated) diagnosed and resolved. Root cause: the CSS populator's `New-RowSkeleton` does not include a `PurposeDescription` field, so every row inserts NULL for this column. The file-header purpose paragraph was being written to `signature` instead, and section-banner descriptions extracted by `Get-BannerInfo` were being computed and discarded. Resolution scope agreed: keep the column, wire up parser population (Option B). Three additional columns identified for removal as part of the same investigation — `related_asset_id`, `design_notes`, and `is_active`. The first two are manual-annotation columns whose use cases relocate to a separate annotations table keyed on the natural key (since manual content cannot survive truncate-and-reload at the row level). The third is dead under the truncate-and-reload model (every row is always active by construction; the column adds zero query value and creates a misleading state-tracking signal). **Implementation delivered:** `Drop_AssetRegistry_Columns.sql` (DDL drop script with default-constraint handling for `is_active`) and patched `Populate-AssetRegistry-CSS.ps1` (PurposeDescription added to row skeleton; Add-FileHeaderRow and Add-CommentBannerRow wired up; DataTable column list trimmed; new verification query reports purpose_description coverage). Cross-populator audit confirmed no other CSS populator references to the dropped columns; HTML and JS populators have pre-existing issues against the 2026-05-03 schema migration plus references to the columns being dropped today, all of which are deferred to their respective spec catch-up sessions. Schema section in this doc rewritten to reflect target post-resolution shape. |
| 2026-05-04 | Renamed from `Asset_Registry_Working_Doc.md` to `CC_Asset_Registry_Working_Doc.md` to align with the CC_* doc family. Doc consolidation note updated to reflect the file format documentation reorganization (retirement of `CC_Component_Registry_Plan.md`, `CC_FileFormat_Standardization.md`, `CC_FileFormat_Spec.md`, `CC_FileFormat_Parser_Friendly_Conventions_Recommendations.md`; replacement by `CC_Initiative.md` plus the `CC_*_Spec.md` family). Schema DDL rewritten to reflect post-migration shape (dropped `state_modifier`, `component_subtype`, `parent_object`, `first_parsed_dttm`; added `variant_type`, `variant_qualifier_1`, `variant_qualifier_2`, `drift_codes`, `drift_text`). Test populator section replaced with current populator status (production scripts exist; HTML populator is one spec generation behind CSS; no orchestrator built yet). Phase 1C reclassified as DONE (covered by JS populator's Group A). Phase 1D reclassified as PARTIAL. Project goal section trimmed (full motivation now lives in `CC_Initiative.md` Purpose). Single-table model and refresh strategy sections trimmed (covered by spec docs' catalog model essentials). `purpose_description` not currently being populated noted explicitly with pointer to OQ-INIT-1. |
| 2026-05-02 | Phase 0 (DDL) + Phase 1A (CSS) + Phase 1B (HTML) all completed. ~7,400 rows of catalog data. Drift detection and consumption matrix working. Refresh strategy decision: TRUNCATE + reload per file_type, not MERGE upsert. Object_Registry row + Object_Metadata baselines + column descriptions + design notes + status_value enumerations inserted (Asset_Registry under Engine.SharedInfrastructure). Parser helpers `parse-css.js` and `parse-js.js` registered under Tools.Utilities. Added "extraction targets are content types not file extensions" framing — formalized Gaps 1/2/3 (HTML-in-JS, inline `<style>`, inline `<script>`) as future phases 1C / 4 / 5. |
| 2026-05-01 | Environment setup complete. Parsers validated. Phase 0 next. |
| 2026-04-30 | Initial framework draft (as `CC_Component_Registry_Plan.md`). Schema proposed, motivation captured. |

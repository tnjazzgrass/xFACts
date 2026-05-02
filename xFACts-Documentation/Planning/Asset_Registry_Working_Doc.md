# Asset_Registry Working Document

**Purpose**: Single working document for the Asset_Registry project. Tracks decisions, schema state, current data state, parser dependencies, and next-session pickup points. Will be discarded after pipeline goes live; permanent documentation will be HTML in the Control Center, harvesting relevant content from this doc.

**Doc consolidation note**: This doc supersedes the older `CC_Component_Registry_Plan.md` (delete after this consolidation). Parser-relevant recommendations have been added to `CC_FileFormat_Spec.md` separately; that spec remains a forward-looking living document for chrome standardization conventions.

---

## Where we left off (last session: 2026-05-02)

**Catalog is functional and queryable.** Test populator scripts have run successfully against the full Control Center codebase, producing ~7,400+ rows across CSS and HTML extraction. Drift queries work. Consumption matrix is real.

**What's built and working:**
- Schema: `dbo.Asset_Registry` with full column set including `state_modifier`, `occurrence_index`, `signature/raw_text` as VARCHAR(MAX)
- Object_Registry / Object_Metadata baselines registered (description, module, category, column descriptions, design notes, status_value enumerations)
- CSS extraction populator (test): walks all CSS files, generates DEFINITION/USAGE rows for CSS_CLASS/CSS_VARIABLE/CSS_KEYFRAME/CSS_RULE/COMMENT_BANNER. Compound vs descendant selector logic correctly distinguishes state modifiers from descendant relationships.
- HTML extraction populator (test): walks all .ps1/.psm1 files, scans both here-strings and regular string tokens for HTML attributes. Produces CSS_CLASS USAGE rows and HTML_ID DEFINITION rows. Cross-references USAGE rows against CSS DEFINITION rows to resolve scope (SHARED vs LOCAL) and source_file.

**Current row counts:**
- CSS: 4,839 rows (190 LOCAL + 12 SHARED comment banners; 3,826 LOCAL + 132 SHARED CSS_CLASS DEFINITIONs; 447 LOCAL + 13 SHARED CSS_CLASS USAGEs; 26 LOCAL + 4 SHARED CSS_KEYFRAME DEFINITIONs; 22 SHARED CSS_KEYFRAME USAGEs; 67 LOCAL + 11 SHARED CSS_RULEs; 19 LOCAL CSS_VARIABLE DEFINITIONs; 70 LOCAL CSS_VARIABLE USAGEs)
- HTML: 2,598 rows (1,331 LOCAL + 649 SHARED CSS_CLASS USAGEs; 618 HTML_ID DEFINITIONs)

**Known coverage gaps (formal Gap 1/2/3 framing):**
- Gap 1: HTML inside JS template strings — not yet captured, addressed by Phase 1C
- Gap 2: Inline `<style>` blocks in route HTML — not yet captured, addressed by Phase 4
- Gap 3: Inline `<script>` blocks in route HTML — not yet captured, addressed by Phase 5

**Next session pickup options** (decide at session start):
1. **Phase 1C** — extend HTML extraction to JS template strings, closing Gap 1. Relatively small parser change. Helps standardization by surfacing client-side-rendered markup.
2. **Phase 1D** — production rewrite of CSS + HTML test populators. Adds proper structure (truncate+reload, occurrence_index computation, GlobalConfig externalization, logging, error handling). Phase 1C work could be folded in.
3. **Phase 2** — JS function/constant/hook extraction. Distinct from Phase 1C (which is HTML-in-JS); this is JS-as-its-own-language cataloging. Uses Acorn parser already validated.

Reasonable order: 1C → 1D (rolling Phase 1C work in) → 2 → 3 → 4 → 5.

---

## Project goal

Build `dbo.Asset_Registry`: a SQL-table-backed inventory cataloging every component (CSS classes, JS functions, HTML IDs, etc.) across all Control Center source files, distinguishing local from shared, and mapping consumption to definition.

**Why it matters**:
1. Answer "what's in this script" / "is there a function/class that does X" without grep
2. **Drift prevention** — surface naming inconsistencies (the canonical example: DmOps' historical use of `slide-panel.active` while shared infrastructure uses `slide-panel.open` for the same purpose) before they accumulate
3. **Consumption tracking** — for any shared component, know exactly which pages consume it. Refactor confidence: rename or change a shared utility, immediately see impact
4. **Pattern enforcement** — when building new pages, query the catalog for established conventions instead of guessing

The intent:

> A developer building a new CC page should be able to query the catalog before writing a single line, find every existing pattern they should reuse, and add new rows for whatever they invent. By the time the page ships, the catalog is current. The catalog is the architecture; the source files are the implementation.

---

## Test populators (current artifacts in WorkingFiles)

Two test populator scripts are saved to GitHub `WorkingFiles/` as templates for the production version. They are NOT production scripts — DELETE+INSERT model, no header conventions, no logging integration, no change detection. They exist purely as the algorithmic reference for the production rewrite.

**These files will be hard-deleted as soon as production replacements are built. No long-term retention.**

### `Populate-AssetRegistry-CSS.ps1` (test)
- Uses Node + PostCSS via subprocess (parse-css.js helper)
- Two-pass: pass 1 collects SHARED definitions; pass 2 generates rows
- Compound vs descendant selector logic with state_modifier extraction
- Multi-selector dedupe via HashSet on `(file, line, component_name, reference_type, state_modifier)` tuple
- Wipes all CSS rows then bulk-inserts everything fresh
- **Does NOT compute occurrence_index** — relies on schema default of 1. Production must add per-tuple counter logic.

### `Populate-AssetRegistry-HTML.ps1` (test)
- Uses PowerShell built-in parser (no Node helper needed)
- Scans HereStringExpandable, HereStringLiteral, StringExpandable, StringLiteral tokens for HTML
- Heuristic filter to skip non-HTML strings before regex
- Cross-references USAGE rows against CSS DEFINITION rows to determine scope and source_file
- Wipes all HTML rows then bulk-inserts everything fresh
- **Does NOT compute occurrence_index either** — same gap as CSS test populator. Earlier doc revisions incorrectly stated otherwise. Production must add per-tuple counter logic.

### What to preserve from the test scripts (when writing production)

- The PostCSS-based CSS AST extraction approach (parse-css.js helper stays as-is)
- The selector tree walking logic with compound vs descendant detection
- The dedupe key pattern within a single parse run
- The PowerShell built-in parser approach for PS files (no Node helper needed)
- The HTML attribute regex patterns (`\b(class|id)\s*=\s*(["'])([^"']*)\2`)
- The bulk-insert pattern via SqlBulkCopy
- The two-pass CSS approach (collect SHARED definitions in pass 1, then walk for usage in pass 2)
- The string-token heuristic filter (skip strings without `<\w` or `class=`/`id=`)

---

## Architecture decisions (locked in)

### Naming and structure

- Table: `dbo.Asset_Registry` (single table, not three per-language tables)
- Schema: `dbo` (no CC prefix)
- **Three extractor scripts** + one orchestrator: CSS, HTML, JS each get their own dedicated populator. Reasoning: each parser has substantial complexity (Node+PostCSS, PS-native, Node+Acorn) and different debugging surfaces. Length and maintainability favor separation.
- Helper Node scripts live alongside (e.g., `parse-js.js`, `parse-css.js`)
- Manual trigger from Admin page (no scheduling initially)
- Standalone server (FA-SQLDBB), not AG

### Single-table model with reference_type/scope

The table holds **one row per instance** (definition or usage). DEFINITION vs USAGE is captured in the `reference_type` column. SHARED vs LOCAL is captured in the `scope` column.

A shared component used on multiple pages will have multiple USAGE rows in the registry — one per consumer location. That's deliberate: lets a single query return the complete picture for any page or any component without joins. Disk cost is irrelevant; cognitive cost is "remember to filter by `scope` and `file_name` appropriately."

A separate dependency table was considered and rejected. It would have meant two-table queries for almost every common question, with no offsetting benefit.

### Refresh strategy: TRUNCATE + reload per file_type

After running test populators against the full codebase and observing the volume of consolidation candidates surfaced, the decision was made to use **truncate + bulk insert** rather than MERGE upsert. Reasoning:

- The catalog represents **current state only** — there is no operational value in tracking historical "this used to exist."
- Chrome standardization is expected to deactivate more rows than it adds per run. Under MERGE+soft-delete, the table would fill with `is_active=0` history rows that would need to be filtered out of every query.
- No external tables FK to `asset_id`, so identity stability across runs is not required.
- Manual annotations (purpose_description, design_notes, related_asset_id) are not yet in use; when they are added later, they go in a **separate annotations table keyed on the natural key** `(file_name, component_type, component_name, reference_type, occurrence_index)`, NOT on the unstable `asset_id`.
- Truncate+reload is dramatically simpler: no MERGE matching logic, no per-file change detection, no `WHEN NOT MATCHED BY SOURCE` handling, no occurrence_index bookkeeping across runs.
- "Historical view" if ever needed comes from periodic snapshots into a separate table — not from soft-delete in the main table.

The MERGE pattern remains valid for some hypothetical future state (mature, stable catalog with external FKs and accumulated annotations). For where the catalog is now, truncate+reload is the right call. The schema accommodates either model — only the populator logic differs.

### Schema columns kept with revised purpose under truncate+reload

- **`occurrence_index`** — still useful as a per-file ordinal disambiguator within each parse, ensuring multiple instances of the same component get distinct rows. Forms part of the natural key. Computed during parse, not maintained across runs.
- **`is_active`** — defaults to 1 always under the parser. Reserved for **manual deactivation** of specific rows (marking known-dead-code, excluding noise from reports) without deleting them. Not used by the parser.
- **`first_parsed_dttm` / `last_parsed_dttm`** — both equal under truncate+reload (every row is freshly inserted each run). Reserved for any future shift in refresh strategy.

### Extraction targets are content types, not file extensions

A subtle but important point: the catalog organizes by what's being extracted, not by file extension. A single physical file can be visited by multiple extractors, each catching different content types within it.

**Content distribution by file extension:**

| Source file extension | What it contains |
|---|---|
| `*.css` | CSS only |
| `*.js` | JS code, plus JS template strings that may contain embedded HTML markup (and rarely embedded CSS) |
| `*.ps1` (routes in `/scripts/routes/`) | PS code, plus here-strings containing HTML markup (which may contain inline `<style>` blocks with CSS or `<script>` blocks with JS) |
| `*.ps1` (APIs, suffix `-API.ps1`) | PS code primarily; rarely contains HTML/CSS/JS |
| `*.psm1` (helpers in `/scripts/modules/`) | PS code plus HTML emission (here-strings or string-concatenation patterns) |

**Implication for parser design:**

The production extractors are organized by **content type they extract**, not by file extension they read. Multiple extractors can visit the same physical file:

- The HTML extractor reads .ps1, .psm1, AND .js files (looking for HTML markup wherever it appears)
- A future inline-CSS extractor reads .ps1 and .psm1 files (looking for `<style>` blocks inside HTML)
- A future inline-JS extractor reads .ps1 and .psm1 files (looking for `<script>` blocks inside HTML)
- The JS function extractor reads only .js files (functions don't appear inline in HTML)
- The PS function extractor reads .ps1 and .psm1 files (PS code only, ignoring the embedded HTML)

The `file_type` column on each row reflects what content type was extracted, not the file extension. A row from an inline `<style>` block in `ServerHealth.ps1` would have `file_type='CSS'` and `file_name='ServerHealth.ps1'` — distinguishable from PS code rows in the same file via file_type.

### Coverage gaps from the content-type model

Three known content-type gaps in the current Phase 1A/1B coverage:

**Gap 1: HTML inside JS template strings.** Pages that render markup at runtime via template strings (e.g., `const html = '<div class="xf-modal">...';`) are not contributing to the catalog. The CSS class USAGE rows for those dynamically-rendered classes are missing. This is widespread — many pages do significant client-side rendering, particularly for slideout content, table row population, and modal contents. Phase 1C closes this gap.

**Gap 2: Inline `<style>` blocks in route HTML.** If a route .ps1 file has CSS rules inside an HTML `<style>` block within a here-string, those rules are invisible to both extractors today. The HTML extractor sees the `class="..."` USAGE but not the inline definition; the CSS extractor doesn't read .ps1 files. The defined class shows up as `source_file = '<undefined>'`. Convention discourages inline `<style>` in this codebase, so prevalence is likely low — but a quick audit is worthwhile. Phase 4 closes this gap.

**Gap 3: Inline `<script>` blocks in route HTML.** Same shape as Gap 2 but for JS functions defined inline in route HTML. Convention discourages inline `<script>` (JS lives in dedicated `.js` files), so prevalence is likely very low. Phase 5 closes this gap.

### Standardization value of HTML-in-JS visibility

Once Gap 1 closes (Phase 1C), the catalog will be able to answer questions that drive standardization decisions:

- Which pages do most of their rendering server-side (HTML in .ps1 here-strings) vs. client-side (HTML in .js template strings)? The split per page reveals architectural style.
- Are there JS files that are essentially just template engines? Heavy HTML-in-JS suggests a candidate for refactoring into a shared rendering helper.
- During chrome standardization, which pages need BOTH the .ps1 AND the .js touched to get complete markup coverage? Currently invisible — could be missed during chrome work.
- Is shared infrastructure (xf-modal, slide-panel, etc.) being consumed via static HTML, dynamic JS, or both? Different pages may have different consumption patterns that aren't visible today.

The catalog answering these questions makes chrome standardization more comprehensive — the work won't accidentally miss markup that lives in JS.

### Component types (final 14)

| Type | What it represents |
|---|---|
| `CSS_CLASS` | A CSS class — DEFINITION rows from CSS files, USAGE rows from CSS files (descendants) and HTML files |
| `CSS_VARIABLE` | A CSS custom property (`--foo`) — DEFINITION and USAGE rows |
| `CSS_KEYFRAME` | A `@keyframes` rule — DEFINITION + USAGE (animation references) |
| `CSS_RULE` | A non-class CSS rule (e.g., `body`, `*`) — captured as DEFINITION only |
| `COMMENT_BANNER` | A section header comment in a file (5+ '=' chars) |
| `HTML_ID` | An `id="..."` attribute occurrence — DEFINITION rows from HTML extraction |
| `JS_FUNCTION` | A JS function declaration or expression (future) |
| `JS_CONSTANT` | A JS top-level const/let/var (future) |
| `JS_HOOK` | A JS function the page defines for the shared module to call (future) |
| `PS_FUNCTION` | A PowerShell function definition (future) |
| `PS_PARAM` | A PowerShell parameter (future) |
| `PS_COMMAND` | A PowerShell command invocation worth cataloging (future) |
| `PS_ASSIGNMENT` | A PowerShell module-scope assignment (future) |
| `API_ROUTE` | An `Add-PodeRoute` definition (future) |

### file_type values

`CSS`, `JS`, `PS`, `HTML`. The `HTML` value is for rows extracted from HTML markup — these rows have `file_name` pointing at the .ps1/.psm1 file the markup lives in. So a single `BIDATAMonitoring.ps1` file produces rows of `file_type='HTML'` (its markup) AND eventually `file_type='PS'` (its function definitions).

### Scope determination

- **For CSS DEFINITIONs**: SHARED if the file is in the curated shared-files list (currently `engine-events.css`); LOCAL otherwise
- **For HTML USAGEs**: cross-referenced against existing CSS DEFINITION rows. SHARED if the class has any SHARED CSS DEFINITION; LOCAL if only LOCAL DEFINITION exists; LOCAL with `source_file = '<undefined>'` if no DEFINITION exists in any CSS file (pure state modifiers, dynamic-only classes, dead refs)
- **For HTML IDs**: always LOCAL (IDs are inherently page-specific)

### Schema decisions resolved during testing

- **`state_modifier` (VARCHAR(200), comma-separated)** — captures compound CSS state modifiers like `.foo.active` as a single primary class definition with the modifier in this column. Multi-modifier cases like `.slide-panel.wide.open` use comma-separated values (`'wide, open'`). 99% of cases are single-modifier; rare multi-modifier patterns are concentrated in specific places (file-monitoring's mini-badge state grid, server-health's slide-panel.wide.open variants).
- **`signature` and `raw_text` are VARCHAR(MAX)** — no truncation. Some multi-selector lists (server-health.css line 729: 11 IDs × 3-class compound) hit ~1,200 chars in signature.
- **`occurrence_index`** — stable identity for the same (file_name, component_type, component_name, reference_type) tuple. See "occurrence_index design" below.
- **`object_registry_id`** — populated during production rewrite, not test scripts. Joins file_name → Object_Registry.

### Methodology: AST-based parsing throughout

- **CSS**: Node + PostCSS 8.5.12 + postcss-selector-parser 7.1.1 (subprocess from PowerShell)
- **JS**: Node + acorn 8.16.0 + acorn-walk 8.3.5 (subprocess from PowerShell)
- **PowerShell**: built-in `[System.Management.Automation.Language.Parser]::ParseFile()` — no external dependency

The PS parser handles HTML extraction too: walk the token list looking for HereStringExpandable/HereStringLiteral/StringExpandable/StringLiteral tokens, apply heuristic to skip non-HTML strings, regex-extract `class="..."` and `id="..."` attributes from the survivors.

---

## Schema (current state)

```sql
CREATE TABLE dbo.Asset_Registry (
    asset_id              INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    file_name             VARCHAR(200)   NOT NULL,
    object_registry_id    INT            NULL,
    file_type             VARCHAR(10)    NOT NULL,    -- CSS, JS, PS, HTML
    line_start            INT            NOT NULL,
    line_end              INT            NULL,
    column_start          INT            NULL,
    component_type        VARCHAR(20)    NOT NULL,    -- 14 values; see above
    component_name        VARCHAR(256)   NULL,
    component_subtype     VARCHAR(100)   NULL,        -- manual; for finer typing
    state_modifier        VARCHAR(200)   NULL,        -- comma-separated for rare multi-modifier
    reference_type        VARCHAR(20)    NOT NULL,    -- DEFINITION, USAGE
    scope                 VARCHAR(20)    NOT NULL,    -- SHARED, LOCAL
    source_file           VARCHAR(200)   NOT NULL,    -- where defined; '<undefined>' if no def
    source_section        VARCHAR(150)   NULL,        -- COMMENT_BANNER title for context
    signature             VARCHAR(MAX)   NULL,        -- full selector / declaration
    parent_function       VARCHAR(200)   NULL,        -- e.g., '@media (max-width: 1200px)'
    parent_object         VARCHAR(200)   NULL,        -- manual; for cross-refs
    raw_text              VARCHAR(MAX)   NULL,        -- raw source snippet
    purpose_description   VARCHAR(MAX)   NULL,        -- manual
    design_notes          VARCHAR(MAX)   NULL,        -- manual
    related_asset_id      INT            NULL,        -- self-FK
    occurrence_index      INT            NOT NULL DEFAULT(1),  -- stable identity for MERGE
    first_parsed_dttm     DATETIME2(7)   NOT NULL DEFAULT(SYSDATETIME()),
    last_parsed_dttm      DATETIME2(7)   NOT NULL DEFAULT(SYSDATETIME()),
    is_active             BIT            NOT NULL DEFAULT(1)
);
```

Constraints: CHECK on `file_type` ∈ {CSS,JS,PS,HTML}, CHECK on `component_type` ∈ {14 values}, CHECK on `reference_type` ∈ {DEFINITION,USAGE}, CHECK on `scope` ∈ {SHARED,LOCAL}.

---

## occurrence_index design

Under truncate+reload, occurrence_index serves a single purpose: **uniquely identify multiple instances of the same component within a file's parse**. It is computed fresh on each run.

**Definition**: 1-based ordinal of how many times this specific `(file_name, component_type, component_name, reference_type)` tuple has been seen so far during the current parse, in source-position order.

Example: if `class="xf-modal"` appears 3 times in BIDATAMonitoring.ps1, those USAGE rows get occurrence_index 1, 2, 3.

**Computation**: during parse, the populator maintains a counter dictionary keyed by the tuple. When emitting a row, it increments the counter and assigns the new value to occurrence_index.

```powershell
$occurrenceCounter = @{}

# When emitting a row...
$tupleKey = "$fileName|$componentType|$componentName|$referenceType"
if (-not $occurrenceCounter.ContainsKey($tupleKey)) {
    $occurrenceCounter[$tupleKey] = 0
}
$occurrenceCounter[$tupleKey]++
$row.occurrence_index = $occurrenceCounter[$tupleKey]
```

**Forms part of the natural key** `(file_name, component_type, component_name, reference_type, occurrence_index)`. This is the stable identifier for cross-references — for example, when a future annotations table needs to attach a design note to "the second xf-modal usage in BIDATAMonitoring.ps1." The natural key is preserved across runs as long as source order doesn't shift; even when ordering changes, the natural key remains a meaningful identifier (the Nth occurrence in current source order).

**Not stable across reorderings**: if a developer removes the 1st xf-modal usage, the formerly-2nd one becomes the new 1st. Annotations attached to occurrence_index=1 would now apply to a different physical instance. This is acceptable because:
1. The catalog represents current state, not history
2. Reorderings of identical components are rare in practice
3. Annotations layer on top via a separate table; if reorderings cause issues, they can be reconciled there

**Not used in MERGE matching**: under truncate+reload, MERGE statements aren't used. occurrence_index exists only for natural-key uniqueness within a single parse output.

---

## What we know works (validated against full platform)

### CSS extraction

Validated against all CSS files in `E:\xFACts-ControlCenter\public\css\`. Key findings:

- Selector tree walking with compound vs descendant logic is correct. `.foo.active` produces 1 DEFINITION row with `state_modifier='active'`. `.foo .bar` produces 1 DEFINITION for `foo` and 1 USAGE for `bar`.
- Multi-selector dedupe via HashSet correctly handles cases like `.foo, .foo .bar` that previously produced 2 DEFINITION rows for `foo`.
- Per-rule class distribution: 3,446 rules with 1 class, 455 with 2, 18 with 3, 2 with 4. No outliers — the previous 33-class outlier (server-health.css line 729 enumerating 11 panel IDs) now correctly collapses to 1 row.
- 19 LOCAL CSS_VARIABLE DEFINITIONs all in `client-portal.css` — that page intentionally has its own `--portal-*` light theme inside the dark CC shell. No platform-wide shared variable system yet.
- 26 LOCAL keyframe DEFINITIONs vs 4 SHARED — significant duplication of `pulse`, `spin`, etc. across pages. Refactor opportunity.

### HTML extraction (from .ps1/.psm1 string tokens)

Validated against all 41 .ps1/.psm1 files in `E:\xFACts-ControlCenter\scripts\routes\` and `\modules\`. Key findings:

- Token-kind scan reaches HereStringExpandable, HereStringLiteral, StringExpandable, StringLiteral — captures both the dominant pattern (here-strings) and the helper-function pattern (string concatenation across multiple regular strings).
- xf-modal regression check: BIDATAMonitoring.ps1 produces 7 SHARED USAGE rows for the Custom Date Range modal at lines 177-195, all sourced from engine-events.css. The original "where does this consumption show up" question is now visibly answered.
- Helper function consumption: xFACts-Helpers.psm1 produces 8 rows showing `nav-bar`, `nav-link`, `nav-separator`, `nav-spacer` SHARED consumption sourced from engine-events.css, plus 3 `<undefined>` LOCAL rows for `denied-container`, `denied-icon`, `home-link` that have no CSS definitions.
- Variable interpolation (`class="$x"`) is correctly skipped — can't statically resolve.

### Drift detection working

- Slide-panel variant audit query shows: most pages converged on `wide` as the size modifier; outliers are `xwide` (BatchMonitoring) and `extra-wide` (DmOperations). Naming drift visible.
- Custom modal vs shared xf-modal: 12 pages still use custom `.modal-*` classes; 3 pages have adopted shared `xf-modal-*`; 3 pages (Backup/BIDATA/JBoss) have BOTH (partial migrations — easiest cleanup wins).
- ServerHealth.ps1 with 26 custom modal uses is the biggest single refactor target.

---

## Catalog data observations (worth referencing)

### Per-page consumption profile

Pages cluster into three groups:

**Heavy SHARED users** (well-aligned to engine-events infrastructure):
- BIDATA: 46/25 (32 distinct shared / 16 local)
- Backup: 61/28 (28/14)
- IndexMaintenance: 73/38 (21/19)
- DmOperations: 49/29 (22/14)
- BatchMonitoring: 50/32 (25/16)

**Balanced**:
- DBCC, JobFlow, JBoss, FileMonitoring, ReplicationMonitoring, BusinessServices, BusinessIntelligence

**Heavy LOCAL users** (mostly own UI vocabulary):
- Admin: 6/231 (5/126) — biggest catalog of LOCAL classes
- PlatformMonitoring: 17/173 (9/67)
- ServerHealth: 111/143 (24/44) — biggest absolute SHARED count AND biggest LOCAL
- BDLImport: 7/122 (7/75)
- ApplicationsIntegration: 5/74 (3/30)
- ClientPortal: 8/78 (4/33) — intentionally has own visual language (light theme inside CC dark shell)

### Refactor candidates surfaced by the catalog

- **Keyframe duplication**: 26 LOCAL definitions of `pulse`, `spin` etc. that should be using the 4 SHARED keyframes in engine-events.css
- **Custom modal cleanup**: 81 custom `modal-*` uses across 12 pages should migrate to shared `xf-modal-*`. Easy targets: Backup, BIDATA, JBoss (already partially adopted)
- **slide-panel naming**: BatchMonitoring uses `xwide`, DmOperations uses `extra-wide`, everyone else uses `wide`. Rename one to match
- **server-health.css line 715/729**: 11 ID-prefixed rules duplicating shared `.slide-panel.wide` styles (the 33-class enumeration we discovered)
- **index-maintenance.css line 887/896**: same pattern, 6 ID-prefixed rules
- **ApplicationsIntegration `admin-badge`/`admin-tool`**: classes used in HTML with no CSS definition
- **Admin page `af-*`/`gc-*`/`meta-*`/`sched-*-header-right`**: classes used in HTML without CSS definitions
- **Home.ps1 `subtitle` vs shared `page-subtitle`**: possible rename opportunity

### Known gaps in current data

These are coverage gaps in Phase 1A/1B output that will be closed by future phases. See the "Coverage gaps from the content-type model" section above for the formal Gap 1/2/3 framing.

- **Gap 1: HTML-in-JS not captured** — Pages that build markup via `innerHTML = '<div class="...">'` or template strings in JS files don't contribute to the consumption matrix yet. CSS class USAGE rows for those dynamically-rendered classes are missing from the catalog. Phase 1C closes this. **Significant for standardization** — chrome work done against .ps1 files alone may miss markup living in .js files. Closing this gap reveals which pages do client-side rendering and which classes those renderings consume.
- **JS classList manipulation also not captured** — `element.classList.add('open')` etc. reflects runtime class assignments. This is technically a separate sub-gap from inline HTML in JS template strings, but addressed by the same Phase 1C parser (scanning JS string literals and AST patterns for class manipulation).
- **Gap 2: Inline `<style>` blocks in route HTML not captured** — A route .ps1 file with CSS rules inside an HTML `<style>` block within a here-string would have those rules invisible to both extractors today. The class would show up as `source_file = '<undefined>'` in the catalog despite being defined inline. Phase 4 closes this. Convention discourages inline `<style>`, so prevalence is likely low.
- **Gap 3: Inline `<script>` blocks in route HTML not captured** — Same shape as Gap 2 but for JS functions defined inline. Phase 5 closes this. Convention discourages inline `<script>`, so prevalence is likely very low.
- **Helper function HTML may be partially missed** — xFACts-Helpers.psm1 only produced 8 rows total. Some helpers may use string-concatenation patterns that fragment class= values across multiple string tokens (`'<div class="' + $cls + '">'`), which we can't statically resolve. Investigate whether more helpers exist; some content may genuinely just not be there. Recommendations have been added to `CC_FileFormat_Spec.md` to make helper HTML emission more parser-friendly going forward.

---

## Production rewrite scope

The test scripts (`Populate-AssetRegistry-CSS.ps1`, `Populate-AssetRegistry-HTML.ps1`) are throwaway — they get hard-deleted as soon as production replacements exist. Production version needs:

### Three populators + orchestrator

- `Populate-AssetRegistry-CSS.ps1` — Node + PostCSS via subprocess
- `Populate-AssetRegistry-HTML.ps1` — PS-native parser
- `Populate-AssetRegistry-JS.ps1` — Node + Acorn via subprocess (FUTURE — Phase 2)
- `Refresh-AssetRegistry.ps1` — orchestrator that dispatches and handles cross-cutting concerns

### Required production changes

1. **TRUNCATE + bulk insert per file_type** — wrapped in a transaction so readers see either old or new state, never empty. Each populator deletes only its own file_type rows then inserts fresh data.
2. **occurrence_index computation in parser** — each populator maintains a per-tuple counter during parse and assigns occurrence_index sequentially to multiple instances. Forms the natural key for cross-references.
3. **Object_Registry integration** — JOIN file_name → Object_Registry to populate `object_registry_id` on every row.
4. **GlobalConfig externalization** — paths (`node_exe`, `nodejs_libs`, `cc_root`) and shared-files list move from hardcoded values to `dbo.GlobalConfig` rows.
5. **Standard logging** — use `Write-Log` from xFACts-Helpers, respect log levels, write to log files in `E:\xFACts-PowerShell\logs\`.
6. **Standard error handling** — file-level try/catch so one failing file doesn't kill the run. Per-file success/failure reported at end.
7. **Standard headers and CHANGELOG** — per Development Guidelines, since these are permanent scripts.
8. **No version number in script header** — version lives in System_Metadata per platform convention.
9. **Better separation of concerns** — extract phase, transform phase, load phase as distinct functions.
10. **Single-instance lock via sp_getapplock** — prevent concurrent runs from corrupting the table during truncate+insert.

### What truncate+reload removes from scope

The MERGE-based design we initially considered would have required:
- Per-file change detection (skip unchanged files)
- MERGE matching logic with `WHEN NOT MATCHED BY SOURCE` handling
- Soft-delete reconciliation
- Cross-run occurrence_index stability

None of these are needed under truncate+reload. The production scripts are correspondingly simpler.

---

## Phases (current state)

| Phase | Description | Status |
|---|---|---|
| 0 | Schema design + DDL | **DONE** — table created, columns finalized through testing |
| 0.5 | Object_Registry + Object_Metadata baselines | **DONE** — registered under Engine.SharedInfrastructure with column descriptions, design notes, and status_value enumerations |
| 1A | CSS extraction from .css files (test populator) | **DONE** — 4,839 rows, drift detection working |
| 1B | HTML extraction from .ps1/.psm1 string tokens (test populator) | **DONE** — 2,598 rows, consumption matrix real |
| 1C | HTML extraction from .js template strings | PENDING — closes Gap 1: dynamic markup rendered client-side |
| 1D | Production rewrite of CSS + HTML populators | PENDING — truncate+reload, occurrence_index computation, registry integration |
| 2 | JS function/constant/hook extraction from .js files | FUTURE — catalogs JS code itself, distinct from HTML-in-JS |
| 3 | PS function/route extraction from .ps1/.psm1 | FUTURE — function definitions, Add-PodeRoute calls |
| 4 | Inline `<style>` extraction from route HTML | FUTURE — closes Gap 2: CSS defined inside HTML in .ps1 files |
| 5 | Inline `<script>` extraction from route HTML | FUTURE — closes Gap 3: JS defined inside HTML in .ps1 files |
| 6 | Admin UI integration | FUTURE — manual trigger button on Admin page |
| 7 | Generated documentation views | FUTURE — auto-generated markdown from registry queries |
| Future | Annotations table | FUTURE — separate table keyed on natural key for purpose_description / design_notes / cross-references when manual annotation work begins |

---

## Open questions (still to resolve)

### 1. Object_Registry / Object_Metadata enrichment timing

Baseline registration done in this session — Object_Registry row exists and column descriptions are populated. **Still deferred**: enrichment Object_Metadata content (data_flow, design_note, status_value, query, relationship_note rows). These are generated only after Phase 1D production rewrite is implemented and verified, so the design notes accurately reflect the production behavior rather than the test-populator approach.

### 2. Helper consumption gap

xFACts-Helpers.psm1 produced 8 HTML rows. Real number is probably higher but limited by string-concatenation patterns we can't statically resolve. Open question: how much investigation is worthwhile before we just live with what we have? Probably defer until JS extraction (Phase 1C/2) is done — the combined picture may be more complete than either alone. Format spec recommendations now exist for making future helper code parser-friendlier.

### 3. State modifier handling in HTML USAGE rows

Currently HTML extraction produces separate USAGE rows for primary class + each modifier (e.g., `class="xf-modal-overlay hidden"` → 2 rows). CSS extraction groups them into one DEFINITION + state_modifier. Inconsistent. Future enhancement: HTML extraction could group multi-class values into one primary USAGE + state_modifier. Defer until production rewrite.

### 4. Admin UI trigger pattern

Sibling to Documentation Pipeline trigger? Or its own button? Or part of a unified "Refresh Catalogs" page? Defer to Phase 4.

### 5. Refresh frequency

User mentioned "at least 3-4x per day" — confirms why MERGE pattern matters. Specific schedule (cron / Pode timer / on-deploy) is Phase 4 design.

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
└── dotnet-lib\                      ← LEGACY — can be cleaned up post-launch
    ├── Esprima.3.0.6\               UNUSED
    ├── ExCSS.4.3.1\                 UNUSED
    ├── Acornima.1.6.1\              UNUSED
    └── (System.* support libs for the abandoned NuGet packages)
```

`dotnet-lib` cleanup is deferred until Phase 1D production rewrite is verified working.

### Per-language parser stack

| Language | Parser | Install location |
|---|---|---|
| PowerShell | `[System.Management.Automation.Language.Parser]` | Built into PS 5.1 — no external dep |
| JavaScript | acorn 8.16.0 (Node subprocess) | `nodejs-libs\node_modules\acorn\` |
| CSS | PostCSS 8.5.12 + postcss-selector-parser 7.1.1 (Node subprocess) | `nodejs-libs\node_modules\postcss\` |

---

## Helper scripts (current state)

`E:\xFACts-PowerShell\parse-js.js` — Node helper for JS AST extraction. Reads JS from stdin, emits ESTree AST as JSON. Used by future JS populator.

`E:\xFACts-PowerShell\parse-css.js` — Node helper for CSS AST extraction. Reads CSS from stdin, emits structured JSON with rules, atRules, comments, and selector trees. Used by current CSS populator.

The parse-js.js / parse-css.js helpers are stable and don't need changes for the production rewrite — they're invoked the same way by the new wrapper scripts.

---

## Lessons learned (preserved)

### .NET Framework + PS 5.1 + NuGet = dependency hell

The single biggest takeaway. PowerShell 5.1 isn't a real NuGet resolver. NuGet packages target multiple frameworks with different transitive dependency assumptions. Every NuGet package's runtime dependency cluster has to be manually assembled.

### Why Node + acorn / Node + PostCSS won

- Native to JS ecosystem — runs in its native environment, no impedance mismatch
- Tiny dependency clusters (acorn = 0 deps; postcss = 3 small deps; selector-parser = 2 small deps)
- Battle-tested — what every modern web tool uses
- Air-gappable — Node MSI installs offline, .tgz transfers offline, no internet at runtime
- Subprocess overhead is ~50-100ms per file — non-issue for ~80 files
- Trivial PowerShell integration via stdin/stdout JSON
- Standard `node_modules\` layout means modules find each other automatically

### Lesson about library layout

Initial install used `nodejs-libs\<package>\package\` layout, which broke when modules tried to require their dependencies. Fixed by restructuring to standard `nodejs-libs\node_modules\<package>\`. **Lesson**: when integrating with an ecosystem, use that ecosystem's standard conventions.

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

Updated at session end with: decisions made, environment changes, current row counts, next pickup point. When pipeline goes live, content useful for permanent docs gets harvested into HTML inside Control Center, and this file is discarded.

### Revision history

| Date | Description |
|---|---|
| 2026-04-30 | Initial framework draft (as `CC_Component_Registry_Plan.md`). Schema proposed, motivation captured. |
| 2026-05-01 | Environment setup complete. Parsers validated. Renamed to `Asset_Registry_Working_Doc.md`. Phase 0 next. |
| 2026-05-02 | Phase 0 (DDL) + Phase 1A (CSS) + Phase 1B (HTML) all completed. ~7,400 rows of catalog data. Drift detection and consumption matrix working. state_modifier and occurrence_index columns added. Production rewrite scoped. Old `CC_Component_Registry_Plan.md` superseded and queued for deletion. Parser-friendly recommendations added to `CC_FileFormat_Spec.md`. **Refresh strategy decision: TRUNCATE + reload per file_type, not MERGE upsert.** Given chrome standardization will deactivate more than it adds per run, soft-delete trail would pollute the table with dead rows. Current state only; manual annotations (when added later) live in a separate annotations table keyed on natural key. Object_Registry row + Object_Metadata baselines + column descriptions + design notes + status_value enumerations inserted. Added "extraction targets are content types not file extensions" framing — formalized Gaps 1/2/3 (HTML-in-JS, inline `<style>`, inline `<script>`) as future phases 1C / 4 / 5. |

# CC Catalog Pipeline Working Document

Operational tracker for the parser pipeline that builds `dbo.Asset_Registry`. Tracks architecture decisions, schema state, populator status, environment state, and lessons learned.

This is operational documentation parallel to the CC file format spec docs. The spec docs say what source files have to look like; this doc says how the parser pipeline that catalogs them is built and where it stands today. This doc will be discarded after the parser pipeline goes live, with content useful for permanent documentation harvested into Control Center HTML.

---

## Related documents

| Document | Contains |
|---|---|
| `CC_Initiative.md` | Initiative-level direction, current state, prefix registry, anchor file registry, decision history. |
| `CC_HTML_JS_Wiring_Design.md` | Active design conversation: should CC pages continue current HTML→JS wiring pattern or shift to inverted (bootloader-driven, data-attribute dispatch) pattern? Drives a pause in HTML populator Wave 2.1 and several related work items. |
| `CC_CSS_Spec.md` | CSS file format specification (rules every CSS source file must follow). |
| `CC_JS_Spec.md` | JavaScript file format specification. |
| `CC_HTML_Spec.md` | HTML markup specification (markup emitted by route .ps1 files and helper module functions). |
| `CC_PS_Route_Spec.md` | PowerShell route file specification (pre-design). |
| `CC_PS_Module_Spec.md` | PowerShell module file specification (pre-design). |

---

## Current state

Catalog is functional and queryable. All three production populator scripts (CSS, JS, HTML) are deployed and running successfully against the full Control Center codebase plus the docs site CSS files. Universal anchor-row refactor delivered 2026-05-12 across all three populators: every file produces a pure-anchor `<TYPE>_FILE` row; FILE_HEADER is reserved for the parsed-header construct (where one exists). HTML doesn't emit FILE_HEADER because HTML markup has no file-header construct. All schema additions implied by the HTML spec are deployed. Helpers file in production.

**Direction pause (2026-05-12):** HTML populator Wave 2.1 paused pending the HTML/JS wiring design conversation. See `CC_HTML_JS_Wiring_Design.md`. The pause affects HTML populator drift code attachment work, the JS_FILE / JS_FUNCTION USAGE resolution decision, the Phase 1 batch sweep approach, and HTML Spec §3.2 / §6 amendments. CSS work, PS populator design, and infrastructure work continue independently.

**Production scripts:**

- `Populate-AssetRegistry-CSS.ps1` — current. Refactored across the 2026-05-06 and 2026-05-07 sessions to consume the `xFACts-AssetRegistryFunctions.ps1` helpers file, adopt the visitor pattern, use the pre-built section list, perform prefix registry validation, and split banner detection into permissive admission plus strict validation. Captures purpose_description across all four CSS comment sources at 100% coverage on spec-compliant files. Emits granular banner drift codes. Universal anchor refactor 2026-05-12: now emits `Add-CssFileRow` as the pure-anchor row builder, with FILE_HEADER reserved for the parsed-header construct.

- `Populate-AssetRegistry-JS.ps1` — current. Refactored across the 2026-05-07 session for alignment work, then patched 2026-05-08 for inline event handler detection and 2026-05-09 for per-element listener loop detection. The populator consumes `xFACts-AssetRegistryFunctions.ps1`, walks via `Invoke-AstWalk`, uses the pre-built section list, performs prefix registry validation with strict-with-carve-outs, and splits banner detection into permissive admission plus strict validation. Drift codes emitted include `FORBIDDEN_REVEALING_MODULE`, `PREFIX_MISSING`, `FORBIDDEN_INLINE_EVENT_IN_JS`, and `FORBIDDEN_PER_ELEMENT_LISTENER_LOOP`. Spec and populator are aligned; the populator emits exactly the drift codes the JS spec defines. Definition-suppression mechanism implemented for forbidden top-level wrapper patterns. Universal anchor refactor 2026-05-12: now emits `Add-JsFileRow` as the pure-anchor row builder, with FILE_HEADER reserved for the parsed-header construct. Three previously-unattached drift codes (`FORBIDDEN_COMMENT_STYLE`, `EXCESS_BLANK_LINES`, `BLANK_LINE_INSIDE_FUNCTION_BODY_AT_SCOPE`) were attached to their proper rows during the universal anchor work; they now surface ~25 drift rows on appropriate files as expected.

- `Populate-AssetRegistry-HTML.ps1` — current at Wave 2 functionality. Built across multiple sessions following the locked-and-amended HTML spec. Consumes `xFACts-AssetRegistryFunctions.ps1`. Tokenizes PS files via `[System.Management.Automation.Language.Parser]::ParseFile()`. Implements PS-AST walker for emission discovery. Emits the `HTML_FILE` anchor row plus Wave 2 row types (HTML_ID, HTML_DATA_ATTRIBUTE, CSS_CLASS USAGE, JS_FUNCTION USAGE, CSS_FILE USAGE, JS_FILE USAGE) plus COMMENT_BANNER. Implements page-prefix stripping for HTML_TEXT categorical naming. Implements purpose comment harvesting for slideouts/modals/panels. Read-only cross-populator model per spec §13.6: HTML populator reads from upstream DEFINITION rows, never edits them. Universal anchor refactor 2026-05-12: pre-load queries retargeted from FILE_HEADER (interim) to `CSS_FILE` / `JS_FILE` (universal model). **Wave 2.1 paused** pending the HTML/JS wiring conversation — several Wave 2.1 drift codes target patterns that may change or disappear under the inverted wiring model.

**Shared infrastructure (deployed):**

- `xFACts-AssetRegistryFunctions.ps1` — domain-specific helpers file for the Asset Registry populator family. ~1,295 lines, 22 functions; patched 2026-05-11 to wire `has_dynamic_content` through `New-AssetRegistryRow` and `Invoke-AssetRegistryBulkInsert`. Centralizes row construction, dedupe tracking, drift code attachment (hybrid: master-table validation plus optional row-specific context), occurrence-index computation, Object_Registry / Component_Registry registry loads, bulk insert plus DataTable shape, comment-text cleanup, banner detection (permissive `Test-IsBannerComment` plus strict `Get-BannerInfo`), file-header parsing, pre-built section list construction with body-line ranges, file-org match check, and the generic AST visitor walker. Pattern parallels `xFACts-IndexFunctions.ps1`. Consumed by all three production populators (CSS, JS, HTML).

**Not yet built:**

- `Refresh-AssetRegistry.ps1` orchestrator. Each populator runs standalone today. The cross-cutting "TRUNCATE the table, then run all populators in order" coordination is currently manual. On-demand execution from Admin page (matching documentation pipeline pattern) will land alongside the orchestrator; no scheduling.

- PS populator. Design pending; can proceed in parallel with the wiring conversation since PS work is largely independent.

---

## Where we left off

Sessions are organized around populator and spec work. Pickup options below assume work through 2026-05-12 is complete: universal anchor-row refactor delivered across all three populators; HTML populator at Wave 2 functionality; JS drift code attachment fixes deployed; HTML/JS wiring conversation opened with `CC_HTML_JS_Wiring_Design.md` as the active discussion doc.

1. **Resolve the HTML/JS wiring conversation.** Active discussion. Outcome determines: HTML Spec §3.2 / §6 amendment scope; JS Spec entry-point and dispatch section additions; HTML populator Wave 2.1 drift code work; JS_FILE / JS_FUNCTION USAGE resolution approach; Phase 1 batch sweep refactor pattern; pilot page selection. Until settled, Wave 2.1 and related items are paused. See `CC_HTML_JS_Wiring_Design.md`.

2. **HTML populator Wave 2.1 (paused).** Drift code attachment work for additional HTML constructs per spec §15. Resumes after wiring conversation. Several Wave 2.1 codes target §3.2 (script tag placement) and §6 (event handlers) patterns that may change or disappear under the inverted model.

3. **JS_FILE / JS_FUNCTION USAGE resolution (paused).** 41 unresolved JS_FILE USAGE rows and 284 unresolved JS_FUNCTION USAGE rows on the HTML side (root cause: pipeline order means JS runs after HTML; HTML's USAGE rows have no DEFINITION rows to resolve against at scan time). Three resolution options identified plus a fourth surfaced by the wiring discussion (USAGE rows don't exist under inverted model). Decision deferred.

4. **JS spec cross-spec rule additions.** Pending wiring outcome. Originally scheduled as a post-HTML-populator catch-up pass for ID string validation (`JS_HTML_ID_UNRESOLVED`, `JS_HTML_ID_MALFORMED`), data-* attribute resolution (`JS_DATA_ATTRIBUTE_UNRESOLVED`), has_dynamic_content flag application, and `ENGINE_PROCESSES` validation against `Orchestrator.ProcessRegistry`. The inverted wiring model could change parts of this — `data-action` dispatch validation would replace or extend the existing scope.

5. **PS populator plus PS spec design (unblocked).** Two specs (module and route) plus one populator covering both. Can proceed in parallel with the wiring conversation. PS populator will consume the helpers file and follow the permissive-admission pattern. Emits its own per-file PS_FILE anchor row.

6. **Phase 1 batch sweep (paused).** Once all four populators are current and all four specs are in production, refactor the five Phase 1 pages across CSS, JS, HTML, and PS together. CSS and JS halves are complete. HTML and PS halves pending wiring outcome — if inverted model is adopted, the JS refactor work for these files extends to `data-action` dispatch refactoring.

7. **`docs-base.css` → `docs-shared.css` migration (unblocked).** Parallel to `engine-events.css` → `cc-shared.css`. Anchor file for `Documentation.Site`. Includes a small populator change to recognize the second anchor file. See `CC_Initiative.md` Queued Work.

8. **Per-file refactor for the seven docs CSS files (unblocked).** Joins the per-file refactor queue.

9. **Page-at-a-time migration for remaining ~22 CC pages (paused).** After Phase 1 closes.

10. **`Refresh-AssetRegistry.ps1` orchestrator (unblocked).** Cross-populator orchestrator: single TRUNCATE, then dispatch CSS → HTML → JS → PS in order, with `sp_getapplock` single-instance locking, on-demand execution from Admin page, and consolidated logging. Sequencing-wise can land any time after all populators are current.

**Validation strategy.** Every existing source file across CSS/JS/HTML/PS is non-spec-compliant, so running a populator over the full codebase produces thousands of drift rows that don't tell us anything we don't already know. The genuinely valuable validation per file type is the first refactored shared/reference file (CSS validated against `cc-shared.css`; JS against `cc-shared.js`; HTML pending), then the first non-trivial page-file refactor. The HTML populator's Wave 2 runs have validated the cross-population resolution model: CSS_FILE resolves cleanly (37 resolved / 0 unresolved); CSS_CLASS USAGE resolves correctly via the CSS_CLASS DEFINITION rows. The JS_FILE / JS_FUNCTION asymmetric resolution gap is structural to pipeline order and surfaced the wiring conversation rather than being a populator bug.

---

## Architecture decisions

### Naming and structure

- Table: `dbo.Asset_Registry` — single table, not three per-language tables.
- Schema: `dbo` (no CC-specific schema prefix).
- Four populators plus one orchestrator (orchestrator pending). CSS, HTML, JS, PS each have their own dedicated populator.
- Helper Node scripts live alongside (`parse-css.js`, `parse-js.js` registered under `Tools.Utilities` in `Object_Registry`).
- Shared PowerShell helpers live in `xFACts-AssetRegistryFunctions.ps1`, dot-sourced by each populator after `xFACts-OrchestratorFunctions.ps1`.
- Manual trigger from Admin page (no scheduling).
- Location: xFACts.dbo (currently AVG-PROD-LSNR)

### Universal anchor-row model

As of 2026-05-12, every populator produces a `<TYPE>_FILE` anchor row for every scanned file:

| Populator | Anchor row | Parsed-header row |
|---|---|---|
| CSS | `CSS_FILE` (always) | `FILE_HEADER` (when file has parseable header block) |
| JS  | `JS_FILE` (always) | `FILE_HEADER` (when file has parseable header block) |
| HTML | `HTML_FILE` (always) | — (no file-header construct in markup) |
| PS (future) | `PS_FILE` (always) | `FILE_HEADER` (when present) |

The anchor row is a pure existence-marker (`reference_type = 'DEFINITION'`, `component_name` = bare filename or page route, scope set by file classification). It hosts file-level drift codes (e.g., HTML's §15.1 page-shell codes attach to HTML_FILE).

The FILE_HEADER row, where it exists, holds parsed-header content (purpose, prefix declaration, etc.) and any header-specific drift.

The two rows coexist cleanly on the same physical file. The model also accommodates files coexisting in the catalog with different file_type values — e.g., a PS route file produces an `HTML_FILE` anchor row (file_type = 'HTML') for its HTML emission and will eventually produce a `PS_FILE` anchor row (file_type = 'PS') from the PS populator for its PowerShell concerns.

Asset-reference resolution between populators uses the `<TYPE>_FILE` anchor rows: HTML's `<link rel="stylesheet">` references resolve against `CSS_FILE` rows; HTML's `<script src=>` references resolve against `JS_FILE` rows. The CSS resolution works at scan time (CSS runs before HTML). The JS resolution doesn't work at scan time (JS runs after HTML) — see "Pipeline order and the resolution asymmetry" below.

### Pipeline order: CSS → HTML → JS → PS

The four populators run in a fixed order driven by the cross-population dependency relationships. CSS is the grandparent. HTML is the parent. JS is both child and grandchild. PS runs last.

The order was revised 2026-05-10 during HTML spec drafting. Under the corrected order, HTML DEFINITION rows for IDs and data-attributes exist when JS scans, so JS USAGE rows resolve cleanly. The architecture supports this: HTML depends only on CSS (which runs first); JS extends its existing CSS resolution mechanism to HTML.

The 2026-05-11 §13.6 amendment locked in a strict read-only cross-populator model: no populator ever edits another populator's rows; all cross-references resolve at scan time against existing DEFINITION rows produced by upstream populators. Each populator is independently re-runnable. The populator family invariant "produce rows, never modify others' rows" holds uniformly.

### Pipeline order and the resolution asymmetry

The pipeline order resolves most cross-references at scan time, but not all. The asymmetry, surfaced 2026-05-12:

- CSS references from HTML resolve cleanly (CSS runs before HTML): `CSS_FILE USAGE` 37/0, `CSS_CLASS USAGE` works correctly.
- JS references from HTML cannot resolve at scan time (JS runs after HTML): `JS_FILE USAGE` 0/41, `JS_FUNCTION USAGE` 0/284.

The asymmetry is structural — under any linear pipeline order, the HTML↔JS relationship has one direction that can't resolve at scan time (HTML→JS under current order; would invert under JS→HTML order, breaking the JS→HTML direction).

This asymmetry surfaced the HTML/JS wiring conversation (see `CC_HTML_JS_Wiring_Design.md`). The conversation considers whether the HTML→JS references should exist at all — under an inverted wiring model (HTML declares `data-page`; bootloader discovers JS modules; JS dispatches via `data-action`), those references would not exist in the HTML markup, and the catalog asymmetry would not arise. The conversation also considers options that retain the current wiring pattern with various resolution strategies for the unresolvable rows.

Until the wiring conversation settles, the unresolved rows remain `<undefined>` in the catalog. This is honest — it reflects what the HTML populator can see at its own scan time — but it's also the trigger for the design discussion.

### Single-table model with reference_type/scope

The table holds one row per instance (definition or usage). DEFINITION vs USAGE is captured in the `reference_type` column. SHARED vs LOCAL is captured in the `scope` column. A shared component used on multiple pages produces multiple USAGE rows, one per consumer location.

### Refresh strategy: TRUNCATE plus reload per file_type

The catalog represents current state only. Standardization work is expected to retire more rows than it adds per run; under a MERGE plus soft-delete model, the table would fill with retired rows that every query would need to filter out.

Refresh semantics:

- **Standalone execution:** each populator deletes only its own slice (`WHERE file_type = 'CSS'` etc.) before bulk-inserting. Each populator independently re-runnable.
- **Orchestrated execution:** the orchestrator TRUNCATEs the whole table once at the start, and each populator's DELETE-WHERE becomes a harmless no-op on already-empty data.

No external tables FK to `asset_id`, so identity stability across runs is not required.

### Schema columns under truncate+reload

- **`occurrence_index`** — per-file ordinal disambiguator for multiple instances of the same component within a parse. Forms part of the natural key. Computed during parse, not maintained across runs.
- **`last_parsed_dttm`** — set to `SYSDATETIME()` on every insert under truncate+reload.
- **`has_dynamic_content`** (BIT NULL, added 2026-05-10) — flag column for partial extraction. Set TRUE on rows where the parent attribute or text construct contains additional runtime-only content the populator cannot statically resolve. Applies to HTML and JS populator rows; CSS rows leave it NULL.

### Extraction targets are content types, not file extensions

The catalog organizes by what's being extracted, not by file extension. A single physical file can be visited by multiple extractors, each catching different content types within it.

| Source file | What it contains |
|---|---|
| `*.css` | CSS only |
| `*.js` | JS code, plus JS template strings that may contain embedded HTML markup |
| `*.ps1` (routes) | PS code, plus here-strings containing HTML markup (which may contain inline `<style>` or `<script>` blocks) |
| `*.ps1` (APIs, suffix `-API.ps1`) | PS code primarily |
| `*.psm1` (helpers) | PS code plus HTML emission |

Production extractors are organized by content type they extract. The `file_type` column on each row reflects what content type was extracted, not the file extension.

### Coverage gaps from the content-type model

Two content-type gaps remain:

- **Gap 1:** Inline `<style>` blocks in route HTML. A route `.ps1` file with CSS rules inside an HTML `<style>` block within a here-string has those rules invisible to the CSS populator. The HTML spec forbids inline `<style>` blocks (drift code `FORBIDDEN_INLINE_STYLE_BLOCK`), so the catalog detects presence via drift codes; the actual CSS rules inside remain unparsed.

- **Gap 2:** Inline `<script>` blocks in route HTML. Same shape as Gap 1 but for JS functions defined inline in route HTML. The HTML spec forbids inline `<script>` blocks containing code (drift code `FORBIDDEN_INLINE_SCRIPT_BLOCK`).

### Detector / validator split (permissive admission, strict validation)

The populator family follows a consistent design principle: detection (admission) is permissive, validation (conformance check) is strict, and every detected construct produces a row regardless of conformance. Drift codes carry the conformance verdict.

Both the CSS and JS populators implement this for section banners: `Test-IsBannerComment` (permissive) admits any banner-shaped comment; `Get-BannerInfo` (strict) validates against §3.1 and emits granular drift codes for each violation. A non-conformant banner produces a `COMMENT_BANNER` row with one or more drift codes attached; it does not get dropped.

The HTML populator extends the same pattern to HTML constructs with defined shapes. The principle generalizes across the populator family.

### Definition suppression for forbidden top-level wrappers

The JS populator implements a definition-suppression mechanism for forbidden top-level wrapper patterns (top-level IIFE and revealing-module IIFE). When the visitor detects either pattern, it emits the wrapper row with the appropriate `FORBIDDEN_*` drift, then sets `$script:CurrentSuppressDefinitions = $true`. The walker continues to descend into the wrapper body, but the visitor's definition-emitting cases check the flag and early-return. USAGE rows continue to fire so the cross-reference catalog stays complete. The flag resets at the start of each per-file iteration.

The mechanism replaced an earlier `SKIP_CHILDREN` approach that suppressed everything inside the wrapper.

---

## Component types

The full master list of `component_type` values across all populators.

| Type | What it represents | Emitted by |
|---|---|---|
| `CSS_FILE` | File-level anchor row for CSS files. One per scanned .css file. | CSS |
| `JS_FILE` | File-level anchor row for JS files. One per scanned .js file. Also USAGE rows from HTML `<script src=>` references. | JS, HTML |
| `HTML_FILE` | File-level anchor row for HTML emission. One per scanned PS file with HTML emission. Hosts §15.1 page-shell drift codes for route files. | HTML |
| `PS_FILE` | File-level anchor row for PS code (future). | (Future) |
| `FILE_HEADER` | The file's parsed-header construct. Emitted only when a header block exists. Hosts header-specific drift. | CSS, JS, (PS future) |
| `COMMENT_BANNER` | A section banner comment. | CSS, JS, HTML, (PS future) |
| `CSS_CLASS` | A CSS class definition, or a USAGE reference to a class. | CSS, HTML, JS (Group A) |
| `CSS_VARIANT` | A class variant definition (`class`, `pseudo`, or `compound_pseudo` shape). | CSS |
| `CSS_VARIABLE` | A CSS custom property definition or a `var(--name)` reference. | CSS |
| `CSS_KEYFRAME` | A `@keyframes` definition or a reference. | CSS |
| `CSS_RULE` | A non-class rule (e.g., `body`, `*`) — captured for drift visibility. | CSS |
| `HTML_ID` | An `id="..."` attribute occurrence (DEFINITION) or `getElementById` reference (USAGE). | HTML, JS (Group A), CSS (when `#id` appears in selectors) |
| `HTML_DATA_ATTRIBUTE` | A `data-*` attribute (DEFINITION) or JS dataset/getAttribute reference (USAGE). | HTML, JS |
| `HTML_TEXT` | Element text content or user-facing attribute value (`title`, `placeholder`, `aria-label`, `alt`). | HTML |
| `HTML_ENTITY` | An HTML entity reference or direct Unicode character. | HTML |
| `HTML_SVG` | An inline `<svg>` element (one row per outer `<svg>`, internals in `raw_text`). | HTML |
| `HTML_COMMENT` | An HTML comment (categorized as section divider, inline annotation, or panel purpose comment). | HTML |
| `JS_IMPORT` | An ES module import or Node `require` statement. Always non-NULL `variant_type`. | JS |
| `JS_CONSTANT` | A primitive-value `const` declaration in a CONSTANTS or FOUNDATION section. | JS |
| `JS_CONSTANT_VARIANT` | A compound-value or computed-expression `const` declaration. Also hosts `FORBIDDEN_REVEALING_MODULE` drift on revealing-module wrappers. | JS |
| `JS_STATE` | A `var` declaration in a STATE section. Also hosts `FORBIDDEN_REVEALING_MODULE` drift on revealing-module wrappers using `var`. | JS |
| `JS_FUNCTION` | A regular `function name() {}` declaration, or a `cc-shared.js` function called from another file (USAGE). | JS, HTML (USAGE rows from event handler attributes) |
| `JS_FUNCTION_VARIANT` | An async or generator function declaration. | JS |
| `JS_HOOK` | A regular page lifecycle hook function inside the hooks banner. | JS |
| `JS_HOOK_VARIANT` | An async page lifecycle hook function. | JS |
| `JS_CLASS` | A JavaScript class declaration. | JS |
| `JS_METHOD` | A regular method defined inside a class body. | JS |
| `JS_METHOD_VARIANT` | A static, getter, setter, or async method. | JS |
| `JS_TIMER` | A `setInterval` or `setTimeout` call assigned to a tracked handle. Always non-NULL `variant_type`. | JS |
| `JS_EVENT` | An event handler binding via `addEventListener`. | JS |
| `JS_IIFE` | An IIFE at file scope. Hosts `FORBIDDEN_IIFE` drift. | JS |
| `JS_EVAL` | An `eval(...)` call. Hosts `FORBIDDEN_EVAL` drift. | JS |
| `JS_DOCUMENT_WRITE` | A `document.write(...)` call. Hosts `FORBIDDEN_DOCUMENT_WRITE` drift. | JS |
| `JS_WINDOW_ASSIGNMENT` | A `window.<name> = ...` assignment outside `cc-shared.js`. Hosts `FORBIDDEN_WINDOW_ASSIGNMENT` drift. | JS |
| `JS_INLINE_STYLE` | A `<style>` element in a JS template/string literal. Hosts `FORBIDDEN_INLINE_STYLE_IN_JS` drift. | JS |
| `JS_INLINE_SCRIPT` | A `<script>` element in a JS template/string literal. Hosts `FORBIDDEN_INLINE_SCRIPT_IN_JS` drift. | JS |
| `JS_INLINE_EVENT` | An inline `on<event>="..."` attribute in a JS template/string literal. Hosts `FORBIDDEN_INLINE_EVENT_IN_JS` drift. | JS |
| `JS_LINE_COMMENT` | A `//` line comment at file scope. Hosts `FORBIDDEN_FILE_SCOPE_LINE_COMMENT` drift. | JS |
| `PS_FUNCTION` | A PowerShell function definition. | (Future) |
| `PS_PARAM` | A PowerShell parameter. | (Future) |
| `PS_COMMAND` | A PowerShell command invocation worth cataloging. | (Future) |
| `PS_ASSIGNMENT` | A PowerShell module-scope assignment. | (Future) |
| `API_ROUTE` | An `Add-PodeRoute` definition. | (Future) |

`CK_Asset_Registry_component_type` CHECK constraint admits 44 values total as of 2026-05-12.

### Variant model

The variant columns (`variant_type`, `variant_qualifier_1`, `variant_qualifier_2`) discriminate sub-flavors of certain component types. Two patterns are in use:

- **Base + `_VARIANT` companion type** — used where there is a clear base case distinguishable from variant expressions. Examples: `CSS_CLASS` / `CSS_VARIANT`; `JS_FUNCTION` / `JS_FUNCTION_VARIANT`; `JS_CONSTANT` / `JS_CONSTANT_VARIANT`; `JS_HOOK` / `JS_HOOK_VARIANT`; `JS_METHOD` / `JS_METHOD_VARIANT`.
- **Single component type, always non-NULL `variant_type`** — used where every instance is inherently a variant. Examples: `JS_IMPORT`, `JS_TIMER`, `JS_EVENT`, `HTML_ENTITY` (uses `signature` for the form distinction).

### file_type values

`CSS`, `JS`, `PS`, `HTML`. The `HTML` value is for rows extracted from HTML markup — these rows have `file_name` pointing at the .ps1/.psm1/.js file the markup lives in.

### Scope determination

- **CSS DEFINITIONs:** SHARED if the file is in the curated shared-files list for its zone. LOCAL otherwise.
- **JS DEFINITIONs:** SHARED if the file is in the curated shared-files list for its zone. LOCAL otherwise.
  - CC zone shared files: `cc-shared.js`, `engine-events.js` (during migration period).
  - Docs zone shared files: `nav.js`, `docs-controlcenter.js`, `ddl-erd.js`, `ddl-loader.js`.
- **HTML USAGEs:** cross-referenced against existing DEFINITION rows in the consumer's zone.
- **HTML_FILE DEFINITIONs:** LOCAL for route files; SHARED for helper files.
- **HTML_ID DEFINITIONs:** LOCAL for page-emitted IDs, SHARED for helper-emitted (chrome) IDs.
- **Forbidden-pattern rows:** scope follows the file's overall scope.

### Methodology

- **CSS:** Node + PostCSS 8.5.12 + postcss-selector-parser 7.1.1 (subprocess from PowerShell).
- **JS:** Node + acorn 8.16.0 + acorn-walk 8.3.5 (subprocess from PowerShell).
- **HTML/PowerShell tokenization:** built-in `[System.Management.Automation.Language.Parser]::ParseFile()` — no external dependency.

### Populator alignment (status)

The CSS, JS, and HTML populators are all aligned on the same structural shape:

- **Walking model:** visitor pattern. JS uses `Invoke-AstWalk` plus visitor scriptblock for JS AST; CSS uses the same for CSS AST; HTML uses its own PS-AST walker (distinct from JS/CSS AST shape).
- **Section tracking:** pre-built section list with body-line ranges via `New-SectionList` plus `Get-SectionForLine`.
- **Drift attachment:** hybrid model. Master `$script:DriftDescriptions` ordered hashtable per populator. `Add-DriftCode` validates against the master table. Output-boundary check before bulk insert.
- **Banner detection plus parsing:** permissive admission via `Test-IsBannerComment`, strict validation via `Get-BannerInfo`. Each populator passes its own valid-types list.
- **File-header parsing:** separates parse from emit via `Get-FileHeaderInfo`.
- **FILE_ORG_MISMATCH:** per-file in Pass 2.
- **Anchor-file enforcement (CSS):** per-component, looking up the file's component's anchor file.
- **Forbidden-wrapper handling (JS only):** definition-suppression flag mechanism.
- **Universal anchor-row model (all):** every file produces a `<TYPE>_FILE` anchor row; FILE_HEADER reserved for parsed-header construct.

The shared infrastructure delivered as `xFACts-AssetRegistryFunctions.ps1` provides the helpers; per-language logic stays in each populator.

---

## Schema (current state)

The schema below reflects what is currently live in `dbo.Asset_Registry` and `Orchestrator.ProcessRegistry`.

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
    has_dynamic_content   BIT            NULL,        -- added 2026-05-10 per HTML spec
    last_parsed_dttm      DATETIME2(7)   NOT NULL DEFAULT(SYSDATETIME())
);

ALTER TABLE Orchestrator.ProcessRegistry
ADD cc_engine_slug    VARCHAR(20)  NULL,
    cc_engine_label   VARCHAR(50)  NULL,
    cc_page_route     VARCHAR(100) NULL,
    cc_sort_order     INT          NULL;
```

**Constraints:** CHECK on `file_type` in {CSS, JS, PS, HTML}, CHECK on `component_type` in enumerated list (44 values as of 2026-05-12), CHECK on `reference_type` in {DEFINITION, USAGE}, CHECK on `scope` in {SHARED, LOCAL}.

**Width notes:**

- `drift_codes` is `VARCHAR(500)`. Sufficient for the worst realistic case (~280 characters from 8 maximum-length codes plus separators).
- `variant_type` is `VARCHAR(30)`. Largest current value is `compound_pseudo` (15 chars).
- `parent_function` is `VARCHAR(200)`. Function/method/class names rarely exceed 50 characters.
- `component_name` widened to `VARCHAR(500)` to absorb edge cases.
- `variant_qualifier_2` widened to `VARCHAR(500)` to hold JS_IMPORT module paths with deeply-nested directory structures.
- `source_section` widened to `VARCHAR(300)` to hold long banner titles.
- `has_dynamic_content` is `BIT NULL` — TRUE on rows whose parent attribute or text construct contains additional runtime-only content; NULL on CSS rows (always literal) and on rows where the populator fully captured the parent construct.

**Object_Registry / Asset_Registry column-name asymmetry.** `Object_Registry`'s primary key is `registry_id`. `Asset_Registry`'s foreign-key column referencing it is `object_registry_id`. Worth flagging because the asymmetric naming is a footgun for future query writers.

---

## occurrence_index design

Under truncate+reload, occurrence_index serves a single purpose: uniquely identify multiple instances of the same component within a file's parse. Computed fresh on each run.

- **Definition:** 1-based ordinal of how many times this specific tuple has been seen so far during the current parse, in source-position order.
- **Computation:** during parse, the populator maintains a counter dictionary keyed by the tuple. Lives in the shared helper `Set-OccurrenceIndices`.
- **Forms part of the natural key** `(file_name, component_type, component_name, reference_type, occurrence_index, variant_type, variant_qualifier_1, variant_qualifier_2)`.
- **Not stable across reorderings:** if a developer removes the 1st instance, the formerly-2nd one becomes the new 1st. Acceptable because the catalog represents current state, not history.

---

## Phases

| Phase | Description | Status |
|---|---|---|
| 0 | Schema design + DDL | DONE |
| 0.5 | Object_Registry + Object_Metadata baselines | DONE |
| 1A | CSS extraction | DONE — at current spec generation |
| 1B | HTML extraction from .ps1/.psm1 string tokens | DONE — Wave 2 complete; Wave 2.1 paused pending wiring conversation |
| 1C | HTML extraction from .js template strings | DONE — covered by JS populator's Group A |
| 1D | Production rewrite + orchestrator | PARTIAL — populators production-grade; helpers file in production; orchestrator not yet built |
| 2 | JS function/constant/hook/class/method extraction | DONE — at current spec generation |
| 3 | PS function/route extraction from .ps1/.psm1 | UNBLOCKED — can proceed in parallel with wiring conversation |
| 4 | Inline `<style>` extraction from route HTML | FUTURE — closes Gap 1; HTML spec already detects presence via `FORBIDDEN_INLINE_STYLE_BLOCK` drift |
| 5 | Inline `<script>` extraction from route HTML | FUTURE — closes Gap 2; HTML spec already detects presence via `FORBIDDEN_INLINE_SCRIPT_BLOCK` drift |
| 6 | Admin UI integration | FUTURE — manual trigger button on Admin page |
| 7 | Generated documentation views | FUTURE — auto-generated markdown from registry queries |
| Future | Annotations table | FUTURE — separate table keyed on natural key |

---

## Production-rewrite remaining work

Most of what was originally scoped under "production rewrite" has shipped. What remains:

### HTML populator Wave 2.1 (paused)

Drift code attachment work for additional HTML constructs per spec §15. Pending wiring conversation outcome. Several Wave 2.1 codes target §3.2 (script tag placement) and §6 (event handlers) patterns that may change or disappear under the inverted model.

### JS populator cross-spec rule additions (paused)

The JS spec gains cross-spec rules originally scheduled as a post-HTML-populator catch-up pass:

- ID string validation: `JS_HTML_ID_UNRESOLVED`, `JS_HTML_ID_MALFORMED`
- data-* attribute resolution: `JS_DATA_ATTRIBUTE_UNRESOLVED`
- `has_dynamic_content` flag application to JS-side CSS_CLASS USAGE rows from template literals
- ENGINE_PROCESSES validation: `MISSING_ENGINE_PROCESSES_DECLARATION`, `ENGINE_PROCESS_PAGE_MISMATCH`, `ENGINE_SLUG_JS_MISMATCH`, `MISSING_ENGINE_CARD_FOR_REGISTERED_PROCESS`

The inverted wiring model could change parts of this — `data-action` dispatch validation would replace or extend the existing scope. Spec and populator updates land after wiring conversation settles.

### Populator end-of-run RunStatus / DegradedReason banner

Each populator currently runs interactively and prints freeform progress and summary lines. When the populator pipeline runs from the Admin tile, a structured end-of-run banner with `RunStatus` (success / degraded / failed) and `DegradedReason` fields will let the Admin UI parse and surface run state cleanly. Backlogged until the Admin tile work begins.

### `Refresh-AssetRegistry.ps1` orchestrator (not yet built; unblocked)

When built, the orchestrator should:

1. Acquire `sp_getapplock` for single-instance protection.
2. TRUNCATE `dbo.Asset_Registry` once.
3. Run CSS populator.
4. Run HTML populator.
5. Run JS populator.
6. (When PS populator lands) run PS populator.
7. Release applock.
8. Per-file success/failure summary at end.
9. Standard logging via `Write-Log` from `xFACts-OrchestratorFunctions.ps1`.
10. On-demand execution from Admin page.

The orchestrator could also host a post-pass resolution sweep if the HTML/JS wiring conversation settles on retaining HTML→JS USAGE rows with a back-fill resolution strategy. See `CC_HTML_JS_Wiring_Design.md`.

### Production script classification (open)

Where the populators get classified in `Object_Registry` is still parked. Two reasonable options:

- **Tools.Utilities** — parallel to `sp_SyncColumnOrdinals`. Parser helpers are already registered here.
- **Documentation.Pipeline** — parallel to `Generate-DDLReference.ps1`.

Decide when the orchestrator lands.

---

## Open questions

### 1. (Resolved 2026-05-10) HTML populator dynamic-class strategy

Under the pre-migration schema, the HTML populator emitted `state_modifier='<dynamic>'` rows for class values that mixed static and dynamic portions. Under the post-migration schema, `state_modifier` doesn't exist.

**Resolution:** the HTML spec mandates a single dynamic class assembly pattern (array-join, §5.2.1) and forbids inline interpolation mixing. The populator emits one CSS_CLASS USAGE row per literal class name in the array. The `has_dynamic_content` BIT flag is set TRUE on the static rows when parameter-fed classes are present.

### 2. Admin UI trigger pattern

On-demand execution from Admin page (matching documentation pipeline trigger pattern), no scheduling. Pattern locked. Implementation lands in Phase 6 alongside the orchestrator.

### 3. (Active) HTML/JS wiring model

See `CC_HTML_JS_Wiring_Design.md`. Drives several decisions: HTML Spec §3.2/§6 amendments, JS Spec entry-point and dispatch additions, HTML populator Wave 2.1 drift codes, JS_FILE/JS_FUNCTION USAGE resolution approach, Phase 1 batch sweep refactor pattern, pilot page selection.

### 4. Helper consumption gap

`xFACts-Helpers.psm1` currently produces a small fraction of the HTML rows that visual inspection suggests are present. The dominant pattern is string-variable indirection. The CC File Format Standardization initiative addresses this as a coding-convention issue.

---

## Catalog data observations (point-in-time snapshots)

These are operational findings from specific catalog snapshots. Not living truth — re-running the populators will produce different counts. Kept here as reference points for the standardization work's scope.

### 2026-05-12 — Universal anchor-row refactor verification; resolution asymmetry surfaces

Catalog state immediately after universal anchor-row refactor deployment:

```
component_type   reference_type   unresolved   resolved
CSS_FILE         USAGE            0            37
JS_FILE          USAGE            41           0

file_type        anchor_rows
CSS              33
HTML             21
JS               30
```

Anchor rows present and well-formed across all three populators. CSS_FILE resolution clean (37/0); JS_FILE resolution structurally impossible at scan time (0/41) due to pipeline order CSS → HTML → JS. JS_FUNCTION USAGE rows on HTML side: 284 unresolved, all `<undefined>` source_file.

Per-page distribution of unresolved HTML→JS USAGE rows:

| Page | Count |
|---|---|
| ServerHealth.ps1 | 55 |
| Admin.ps1 | 54 |
| PlatformMonitoring.ps1 | 39 |
| BDLImport.ps1 | 24 |
| FileMonitoring.ps1 | 20 |
| IndexMaintenance.ps1 | 17 |
| ClientPortal.ps1 | 15 |
| JobFlowMonitoring.ps1 | 15 |
| DBCCOperations.ps1 | 13 |
| DmOperations.ps1 | 11 |
| JBossMonitoring.ps1 | 11 |
| ApplicationsIntegration.ps1 | 10 |
| Backup.ps1 | 9 |
| BIDATAMonitoring.ps1 | 7 |
| ReplicationMonitoring.ps1 | 7 |
| BusinessServices.ps1 | 6 |
| BatchMonitoring.ps1 | 5 |
| BusinessIntelligence.ps1 | 4 |
| ClientRelations.ps1 | 3 |

Total: 325 rows of permanent `<undefined>` source_file values from HTML→JS USAGE references. These surface the structural asymmetry that drove the HTML/JS wiring conversation (see `CC_HTML_JS_Wiring_Design.md`). The distribution informs pilot page selection — heavy pages (ServerHealth, Admin, PlatformMonitoring) are also the most behaviorally complex; moderate pages (BatchMonitoring, DBCCOperations) are more representative of typical CC interaction patterns.

Three previously-unattached JS drift codes (`FORBIDDEN_COMMENT_STYLE`, `EXCESS_BLANK_LINES`, `BLANK_LINE_INSIDE_FUNCTION_BODY_AT_SCOPE`) were attached to their proper rows during the universal anchor work. They now surface ~25 drift rows on appropriate files as expected.

### 2026-05-10 — HTML spec drafting session; pipeline order revised

HTML spec drafted in a single session (~1,930 lines, 17 numbered sections plus Appendix, 88 drift codes). Pipeline order revised from the test populator's CSS → JS → HTML to the production order CSS → HTML → JS → PS based on cross-population dependency analysis.

Architecture decisions: `has_dynamic_content` flag column on `dbo.Asset_Registry`; four cc-prefixed columns on `Orchestrator.ProcessRegistry`; categorical naming for `HTML_TEXT` rows with page-prefix stripping; cross-spec consistency principle extended to HTML.

### 2026-05-09 — Four Phase 1 page JS files at zero structural drift

All four Phase 1 page JS files refactored to spec compliance, delivered as offline `*-spec.js` companions. The methodology stabilized through the four sessions. Each refactor was a coordinated single pass: structural changes plus inline event handler migration to delegated `addEventListener` bindings plus per-element listener loop migration to delegation.

Notable discoveries: pre-existing bugs surfaced by careful reading (`replication-monitoring.js` had `onSessionExpired() { stopPolling(); }` referring to a function that doesn't exist; `updateTimestamp` defined twice via JS hoisting); `business-intelligence.js` rewrite eliminated revealing-module wrapper; per-element listener loop pattern caught by inspection in three of four files; shared-function migration coverage reaching critical mass; first production run of §12 populator catch-up surfaced exactly three genuine violations all resolved in the same session.

### 2026-05-08 — Inline event handler drift surfaced; first non-trivial Phase 1 page validation

Two operational findings during the first non-trivial Phase 1 page JS refactor session:

- **Inline event handler detection added.** The `business-services.js` refactor returned at zero structural drift on first run, but the file contains nine inline `onclick="..."` attribute strings inside template literals. Spec amended; populator patched. Re-run with patched populator: 9 rows on `business-services.js`, 0 on `client-relations.js`, 281 across the rest of the unrefactored codebase.

- **`client-relations.js` and `business-services.js` validate as the first non-trivial spec-compliant page-file pair.** Both files exercised the engine processes contract banner (§7.4). The methodology is now stabilized for the remaining Phase 1 page JS files.

- **`Get-BannerInfo` case-sensitivity bug fixed.** One-character fix: `-match` → `-cmatch` on the title-line regex.

### 2026-05-07 snapshot (post-JS-alignment-refactor)

Total JS rows: 9,639. Drift rate: 20.9% (2,019 of 9,639 rows). All 25 JS files walk to completion with zero AST walk failures. cc-shared.js continues at zero file-attributable drift.

Definition suppression behaving correctly: revealing-module files show `js_func_defs` ≤ 4 each. Top-level IIFE files show 0 inner JS function definitions. Cross-reference USAGE rows continue to flow from inside both wrapper patterns.

### 2026-05-07 snapshot (post-CSS-alignment-refactor)

Total rows: 7,617 (up from 7,584 pre-refactor). 33 additional banner rows now correctly captured from pre-spec files whose dash-bracketed banners the old detector had silently missed. All 33 carry appropriate granular drift codes. Confirms the permissive-admission/strict-validation model recovers visibility on banner-shaped constructs that strict-only admission silently dropped.

Docs-site CSS files now formally cataloged at 1,055 rows total across 7 files, with 627 (59.4%) carrying drift.

### Refactor candidates surfaced by the catalog (2026-05-02 snapshot, still useful)

- **Keyframe duplication:** 26 LOCAL definitions of `pulse`, `spin` etc. that should be using the SHARED keyframes in `engine-events.css`.
- **Custom modal cleanup:** 81 custom `modal-*` uses across 12 pages should migrate to shared `xf-modal-*`.
- **slide-panel naming:** BatchMonitoring uses `xwide`, DmOperations uses `extra-wide`, everyone else uses `wide`. Rename for consistency.
- **server-health.css line 715/729:** 11 ID-prefixed rules duplicating shared `.slide-panel.wide` styles.
- **index-maintenance.css line 887/896:** same pattern, 6 ID-prefixed rules.
- **ApplicationsIntegration `admin-badge`/`admin-tool`:** classes used in HTML with no CSS definition.
- **Admin page `af-*`/`gc-*`/`meta-*`/`sched-*-header-right`:** classes used in HTML without CSS definitions.

### Per-page consumption profile (2026-05-02 snapshot)

Pages clustered into three groups:

- **Heavy SHARED users** (well-aligned to engine-events infrastructure): BIDATA, Backup, IndexMaintenance, DmOperations, BatchMonitoring.
- **Balanced:** DBCC, JobFlow, JBoss, FileMonitoring, ReplicationMonitoring, BusinessServices, BusinessIntelligence.
- **Heavy LOCAL users:** Admin (largest LOCAL catalog), PlatformMonitoring, ServerHealth, BDLImport, ApplicationsIntegration, ClientPortal.

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
+-- dotnet-lib\                      <- LEGACY -- clean up post-launch
    +-- Esprima.3.0.6\               UNUSED
    +-- ExCSS.4.3.1\                 UNUSED
    +-- Acornima.1.6.1\              UNUSED
```

`dotnet-lib` cleanup is deferred until the orchestrator lands and the pipeline is verified working end-to-end.

### Per-language parser stack

| Language | Parser | Install location |
|---|---|---|
| PowerShell | `[System.Management.Automation.Language.Parser]` | Built into PS 5.1 -- no external dep |
| JavaScript | acorn 8.16.0 (Node subprocess) | `nodejs-libs\node_modules\acorn\` |
| CSS | PostCSS 8.5.12 + postcss-selector-parser 7.1.1 (Node subprocess) | `nodejs-libs\node_modules\postcss\` |

---

## Helper scripts

- `E:\xFACts-PowerShell\parse-js.js` -- Node helper for JS AST extraction.
- `E:\xFACts-PowerShell\parse-css.js` -- Node helper for CSS AST extraction.
- `E:\xFACts-PowerShell\xFACts-AssetRegistryFunctions.ps1` -- PowerShell shared helpers for the populator family.

The Node helpers are stable and don't need changes for the orchestrator work. The HTML populator does not require a Node helper; it uses PowerShell's built-in `[System.Management.Automation.Language.Parser]`.

---

## Lessons learned

### .NET Framework + PS 5.1 + NuGet = dependency hell

The single biggest takeaway. PowerShell 5.1 isn't a real NuGet resolver. NuGet packages target multiple frameworks with different transitive dependency assumptions. Every NuGet package's runtime dependency cluster has to be manually assembled. If anyone in the future considers parsing CSS or JS via a .NET library on PS 5.1, this is the path everyone has tried and failed.

### Why Node + acorn / Node + PostCSS won

- Native to JS ecosystem -- runs in its native environment, no impedance mismatch.
- Tiny dependency clusters.
- Battle-tested.
- Air-gappable.
- Subprocess overhead is ~50-100ms per file.
- Trivial PowerShell integration via stdin/stdout JSON.

### Encoding policy

Source files, populator scripts, and parser output are all ASCII-only. No BOM, no extended characters. Mixed encodings caused parsing artifacts and hex-escape display issues.

### AST walk resilience

Per-file try/catch around the AST walk in all populators. Walk failures are populator tooling defects, not source-file spec drift, so they don't emit drift codes. Failures contained -- the populator continues to the next file rather than halting the run.

### Permissive admission, strict validation

The 2026-05-07 banner-detection refactor confirmed a design principle worth naming: the catalog represents what exists in the source code, and any construct with a defined shape should be admitted permissively (any candidate becomes a row) and validated strictly (drift codes describe each violation). The earlier strict-only admission model silently dropped non-conforming banners from the catalog. The corrected model recovered 33 banner rows on the first run that were previously invisible. The principle is named here for future populator work to internalize.

### PowerShell pipeline-unwrapping on IEnumerable returns

A function that returns an `IEnumerable` (HashSet, List, array) can have its return value silently collapsed to `$null` at the call site when the collection is empty. PowerShell's pipeline unwrap iterates the IEnumerable on return and emits each element separately; an empty collection emits zero values, and the receiving variable captures `$null`.

Fix pattern: wrap the return with a leading comma operator -- `return ,$hs` instead of `return $hs`. The comma forces the value into a single-element array.

### Validate populator behavior with data, not narrative

When a populator change ships, the right way to verify the change is to query the catalog table and look at the actual rows produced. Reasoning about "what the change should do" without checking the data is unreliable. Subsequent populator changes should query first, theorize second.

### Spec-compliant clean run isn't proof the spec is complete

The 2026-05-08 inline-event-handler discovery is the canonical illustration. `business-services.js` came back at zero structural drift on first refactor, but contained nine inline `onclick="..."` attributes inside template literals — a pattern the spec hadn't addressed. The clean drift report confirmed the file followed the rules the spec had, not that the file was free of patterns we'd want the spec to forbid.

Each new file refactored is a fresh chance to discover gaps.

### Cross-population dependencies must drive pipeline order

The 2026-05-10 HTML spec drafting session surfaced a pipeline order issue. The dependency relationships drive ordering, not file-extension alphabetization or perceived complexity. The 2026-05-12 resolution asymmetry surfaced a related lesson: pipeline order can resolve dependencies in one direction at scan time, but cross-references in both directions (HTML→JS via `<script src=>` plus JS→HTML via `getElementById`) cannot both resolve under any linear ordering. This drove the HTML/JS wiring conversation.

### Read-only cross-populator model

The 2026-05-11 §13.6 amendment crystallized a design principle: no populator ever edits another populator's rows. Cross-references resolve at scan time against existing DEFINITION rows produced by upstream populators. Every populator is independently re-runnable under the new model. The populator family invariant "produce rows, never modify others' rows" holds uniformly.

This principle creates a tension with cross-references that cannot resolve at scan time under any linear pipeline order (see HTML→JS case above). Resolution options that preserve the read-only model include: accept `<undefined>` in the catalog, eliminate the reference at the source-code level (via the inverted wiring model), or use an orchestrator post-pass for resolution (which is a write but is owned by the orchestrator, not a populator).

### Universal anchor-row model

The 2026-05-12 refactor adopted a universal pattern: every populator emits a `<TYPE>_FILE` anchor row for every scanned file, separately from any parsed-header construct. The pattern replaces an earlier dual-purpose model where CSS and JS populators emitted FILE_HEADER as both anchor and parsed-header row. The new model is cleaner because the two concerns (file-existence-marker, file-header-parsed-content) are conceptually distinct and have different drift attachment needs. The model also supports types that lack a parsed-header construct (HTML, which has no file-header in markup).

---

## Pipeline implementation history

A compressed record of substantive implementation events on the pipeline. One or two lines per entry.

- **2026-04-30** -- Initial framework draft. Schema proposed.
- **2026-05-01** -- Environment setup. Parsers validated.
- **2026-05-02** -- Phase 0 (DDL) plus Phase 1A (CSS) plus Phase 1B (HTML) completed.
- **2026-05-03** -- Schema migration. Dropped `state_modifier`, `component_subtype`, `parent_object`, `first_parsed_dttm`. Added variant columns plus drift columns.
- **2026-05-04** -- Renamed working doc; schema updated. Three columns dropped (`related_asset_id`, `design_notes`, `is_active`). CSS populator wired purpose_description.
- **2026-05-04** -- CSS populator extended to capture per-class purpose comments and per-variant trailing inline comments. 100% coverage on Phase 1 reference files.
- **2026-05-05** -- JS variant model added. Schema rewritten from `INFORMATION_SCHEMA.COLUMNS`.
- **2026-05-05** -- JS populator change pass implemented. cc-shared.js created and validated at zero file-attributable drift.
- **2026-05-06** -- JS populator Phase 1 fixes. JS populator zone architecture added. AST walk resilience added.
- **2026-05-06** -- `xFACts-AssetRegistryFunctions.ps1` shared helpers file created.
- **2026-05-06** -- Populator alignment design locked.
- **2026-05-06** -- Strict prefix registry validation (Option B) chosen.
- **2026-05-06** -- Asset_Registry column descriptions populated in `dbo.Object_Metadata`.
- **2026-05-07** -- CSS populator alignment refactor delivered.
- **2026-05-07** -- Banner detection refactored to permissive admission plus strict validation. Granular banner drift codes adopted.
- **2026-05-07** -- Anchor-file generalization landed in `CC_CSS_Spec.md`.
- **2026-05-07** -- Docs-site CSS investigation complete. Files brought into per-file refactor queue.
- **2026-05-07** -- JS populator alignment refactor delivered.
- **2026-05-07** -- Definition-suppression flag mechanism added to JS populator.
- **2026-05-07** -- `FORBIDDEN_REVEALING_MODULE` and `PREFIX_MISSING` drift codes added.
- **2026-05-07** -- Latent visitor null-deref closed via comma-operator fix on `Get-ZoneSharedFunctions`.
- **2026-05-08** -- `client-relations.js` refactored to spec compliance. First non-trivial Phase 1 page JS file.
- **2026-05-08** -- `Get-BannerInfo` case-sensitivity bug fixed.
- **2026-05-08** -- `business-services.js` refactored to structural spec compliance.
- **2026-05-08** -- `FORBIDDEN_INLINE_EVENT_IN_JS` drift code adopted; populator patched.
- **2026-05-09** -- JS spec §12 (Event handler binding) amendment landed. New drift code `FORBIDDEN_PER_ELEMENT_LISTENER_LOOP`.
- **2026-05-09** -- Four Phase 1 page JS file refactors delivered to spec at zero structural drift.
- **2026-05-09** -- JS populator catch-up for `FORBIDDEN_PER_ELEMENT_LISTENER_LOOP` delivered.
- **2026-05-10** -- HTML spec drafted across a single session.
- **2026-05-10** -- Schema additions for HTML spec implementation: `has_dynamic_content`; four cc-prefixed columns on `Orchestrator.ProcessRegistry`.
- **2026-05-10** -- Open question 1 (HTML populator dynamic-class strategy) resolved.
- **2026-05-10** -- Cross-spec consistency principle extended to HTML.
- **2026-05-11** -- HTML spec amended: §13.6 strict read-only cross-populator model; §13.1/§13.2/§14 add `HTML_FILE` component type; `CK_Asset_Registry_component_type` updated to admit `HTML_FILE`.
- **2026-05-11** -- Helpers file patched for `has_dynamic_content` column support.
- **2026-05-11** -- HTML populator build deferred to fresh session.
- **2026-05-12** -- HTML populator built across multiple sessions; reached Wave 2 functionality (HTML_FILE anchor row, HTML_ID, HTML_DATA_ATTRIBUTE, CSS_CLASS USAGE, JS_FUNCTION USAGE, CSS_FILE USAGE, JS_FILE USAGE plus COMMENT_BANNER and HTML construct row types). Read-only cross-populator model per spec §13.6.
- **2026-05-12** -- Universal anchor-row refactor delivered across all three populators (CSS, JS, HTML). CSS and JS populators split FILE_HEADER into pure-anchor `CSS_FILE` / `JS_FILE` rows plus parsed-header FILE_HEADER rows. HTML populator's pre-load queries retargeted from FILE_HEADER (interim) to `CSS_FILE` / `JS_FILE` (universal). HTML doesn't emit FILE_HEADER (no file-header construct in markup). `CK_Asset_Registry_component_type` admits 44 values total.
- **2026-05-12** -- Three previously-unattached JS drift codes (`FORBIDDEN_COMMENT_STYLE`, `EXCESS_BLANK_LINES`, `BLANK_LINE_INSIDE_FUNCTION_BODY_AT_SCOPE`) attached to their proper rows. Surface ~25 drift rows on appropriate files as expected.
- **2026-05-12** -- JS_FILE / JS_FUNCTION USAGE resolution gap surfaced after universal anchor verification. Root cause: pipeline order. CSS resolves cleanly; JS cannot resolve at scan time. Decision deferred pending HTML/JS wiring conversation.
- **2026-05-12** -- HTML/JS wiring conversation opened. `CC_HTML_JS_Wiring_Design.md` created as the planning doc for the discussion. HTML populator Wave 2.1 and several related items paused.
- **2026-05-12** -- Universal anchor working document (`Asset_Registry_Universal_Anchor_Refactor.md`) retired. Work integrated into `CC_Initiative.md` and this document.

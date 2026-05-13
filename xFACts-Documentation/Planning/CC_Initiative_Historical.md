# Control Center File Format Initiative

The CC File Format initiative defines a strict, machine-parseable file format for every CC source file type and refactors the existing CC codebase to conform. The goal is drift detection: files that follow a strict spec catalog cleanly into `dbo.Asset_Registry`, and the catalog is the queryable source of truth for "what exists in the codebase, what's shared, what's reinvented, and what's out of compliance."

The xFACts platform already has comprehensive cataloging on the SQL and PowerShell side via `dbo.Object_Registry` and `dbo.Object_Metadata`. The Control Center side previously had no equivalent — pages are made up of route .ps1 files, page CSS files, page JS files, and API .ps1 files, and the only way to answer "do we already have a CSS class for X" or "is there an API endpoint for Y" was to grep through source files. The catalog flips that: convention reuse becomes a query, not a guess.

This is the navigation hub for the initiative. It does not contain spec content — each file-type spec lives in its own document.

---

## Related documents

| Document | Contains |
|---|---|
| `CC_Catalog_Pipeline_Working_Doc.md` | Operational tracker for the parser pipeline that builds `dbo.Asset_Registry`. Architecture decisions, schema state, populator status, environment state, lessons learned. |
| `CC_HTML_JS_Wiring_Design.md` | Active design conversation: should CC pages continue current HTML→JS wiring pattern or shift to inverted (bootloader-driven, data-attribute dispatch) pattern? Currently driving a pause in HTML populator Wave 2.1 work. |
| `CC_CSS_Spec.md` | CSS file format specification. |
| `CC_JS_Spec.md` | JavaScript file format specification. |
| `CC_HTML_Spec.md` | HTML markup specification (markup emitted by route .ps1 files and helper module functions). |
| `CC_PS_Route_Spec.md` | PowerShell route file format specification (pre-design). |
| `CC_PS_Module_Spec.md` | PowerShell module file format specification (pre-design). |
| `CC_CSS_Refactor_Migration_Notes.md` | Per-file CSS refactor record (active during transition; retires after Phase 1 completes). |

---

## Session start protocol

A new session starts with these steps:

1. Dirk provides a cache-busted manifest URL (`https://raw.githubusercontent.com/tnjazzgrass/xFACts/main/manifest.json?v=<value>`).
2. Fetch the top-level manifest, then the documentation manifest from it.
3. Fetch this document and read Current State.
4. Fetch any document(s) referenced as active in Current State.
5. Begin work in that area. Honor any "Blocked on" or "Queued next" items.

This document is authoritative for project direction and state. Each spec document is authoritative for its file type. If anything in Project Knowledge or Claude's memory contradicts what is written here, the documents win.

Before ending a session, update Current State and add an entry to the Initiative decision history if a substantive decision was made.

---

## Current direction

Bring all four populators (CSS, HTML, JS, PS) and their specs current first. Then sweep the Phase 1 page set across all four file types together. Then page-at-a-time migration for the remaining ~22 pages. The docs site CSS files (and eventually JS files) are part of this scope: they conform to the same single-source-of-truth specs the CC application files do, with the per-component anchor file rule (`CC_CSS_Spec.md` §4.3) accommodating the docs site's separate visual chrome.

**Direction pause (2026-05-12):** The HTML/JS wiring model is under active design review. The current model (HTML references JS via `<script src=>` and `onclick=`) exposed an architectural asymmetry in the catalog — `JS_FILE` and `JS_FUNCTION` USAGE rows emitted on the HTML side cannot resolve at scan time because JS runs after HTML in the pipeline order. An inverted model (HTML declares page identity via `data-page`; bootloader discovers and loads JS modules; JS dispatches via delegated event listeners against `data-action` markers) is one candidate alternative under discussion; the resolution gap can also be addressed within the current model via back-fill, orchestrator post-pass, or accepted as a property of pipeline order. The choice has downstream impact on the HTML and JS specs, the HTML populator's Wave 2.1 drift code work, and how every subsequent page refactor is structured. See `CC_HTML_JS_Wiring_Design.md` for the full conversation framework. Wave 2.1 and several related work items are paused pending this conversation.

---

## Current state

*Last updated: 2026-05-12.*

**HTML populator Wave 2 complete; universal anchor-row refactor delivered across all three populators (2026-05-12).** The production HTML populator (`Populate-AssetRegistry-HTML.ps1`) was built across multiple sessions and reached Wave 2 functionality: HTML_FILE anchor row, HTML_ID, HTML_DATA_ATTRIBUTE, CSS_CLASS USAGE, JS_FUNCTION USAGE, CSS_FILE USAGE, JS_FILE USAGE row emission, plus the COMMENT_BANNER and HTML construct row types. Three previously-unattached JS drift codes (FORBIDDEN_COMMENT_STYLE, EXCESS_BLANK_LINES, BLANK_LINE_INSIDE_FUNCTION_BODY_AT_SCOPE) were attached to their proper rows during the universal anchor work; they now surface 25 drift rows on the new files as expected. The 2026-05-12 universal anchor-row refactor split the dual-purpose FILE_HEADER row on CSS and JS populators into pure-anchor CSS_FILE / JS_FILE rows plus parsed-header FILE_HEADER rows. The HTML populator's pre-load queries were retargeted from FILE_HEADER (interim) to CSS_FILE / JS_FILE as the universal model went live. All three populators (CSS, JS, HTML) now follow the universal model: every file gets a `<TYPE>_FILE` anchor row; FILE_HEADER is the parsed-header construct (where one exists). HTML doesn't emit FILE_HEADER because HTML markup has no file-header construct; the host PS file's header will be cataloged by the future PS populator. The universal-anchor working document (`Asset_Registry_Universal_Anchor_Refactor.md`) was retired 2026-05-12 with the work integrated into this doc and the Catalog Pipeline doc.

**Resolution gap surfaced; HTML/JS wiring conversation opened (2026-05-12).** Verification queries after the universal anchor work confirmed CSS_FILE resolution clean (37 resolved / 0 unresolved on HTML side) but JS_FILE resolution unresolved (0 resolved / 41 unresolved on HTML side). Root cause: pipeline order CSS → HTML → JS → PS means HTML's JS_FILE USAGE rows have no DEFINITION rows to resolve against when HTML scans. Same for JS_FUNCTION USAGE rows from `onclick=` attributes (284 unresolved). Investigation of resolution options surfaced a deeper architectural question — whether these USAGE rows need to exist in the catalog at all, or whether an inverted HTML/JS wiring model would eliminate them. The wiring conversation paused HTML populator Wave 2.1 work and several related items. See `CC_HTML_JS_Wiring_Design.md` for the full discussion framework.

**HTML spec amended for `HTML_FILE` anchor row and cross-populator read-only model (2026-05-11).** `CC_HTML_Spec.md` was drafted 2026-05-10 (17 numbered sections plus Appendix, ~1,930 lines, 88 drift codes) and amended 2026-05-11 ahead of the HTML populator build. The 2026-05-11 amendments: (a) §13.1, §13.2, and §14 add the `HTML_FILE` component type — a file-level anchor row, one per scanned PS file containing HTML emission, hosting the §15.1 page-shell drift codes; (b) §13.6 rewritten to lock in a strict read-only cross-populator model — no populator ever edits another populator's rows, all cross-references resolve at scan time against existing DEFINITION rows produced by upstream populators; (c) §5.3 removes the `parent_object` row from the CSS_CLASS USAGE column table (parent_object column does not exist on the live schema); (d) §14 removes a stale reference to "route path (later filled in by PS populator)"; (e) §15.1 introduces the §15.1 codes attaching to the `HTML_FILE` anchor row. The `CK_Asset_Registry_component_type` CHECK constraint was updated in the same session to admit `HTML_FILE`. Pipeline order CSS → HTML → JS → PS confirmed.

**CSS and JS populator alignments are both delivered.** The 2026-05-07 session brought the JS populator current with the same alignment treatment CSS received earlier in the session: helpers-file consumption, visitor pattern, prefix registry validation, permissive-admission/strict-validation banner detection, plus two JS-specific additions (FORBIDDEN_REVEALING_MODULE detection for the revealing-module IIFE pattern, PREFIX_MISSING for top-level identifier validation against Component_Registry independent of banners). Both populators are in production, walking their full file sets cleanly. Universal anchor refactor 2026-05-12 split FILE_HEADER into pure-anchor `<TYPE>_FILE` rows plus parsed-header FILE_HEADER rows on both populators.

**Helpers file in production.** `xFACts-AssetRegistryFunctions.ps1` (~1,295 lines, 22 functions) is deployed and consumed by all three populators (CSS, JS, HTML). Centralizes row construction, dedupe tracking, drift code attachment (hybrid model: master-table validation plus optional row-specific context), occurrence-index computation, Object_Registry and Component_Registry registry loads, bulk insert plus DataTable shape, comment-text cleanup, banner detection (permissive `Test-IsBannerComment`) and parsing (strict `Get-BannerInfo` emitting granular drift codes), file-header parsing, pre-built section list construction with body-line ranges, file-org match check, and the generic AST visitor walker. Per-language logic stays in each populator. The file lives alongside `xFACts-OrchestratorFunctions.ps1` and `xFACts-IndexFunctions.ps1` in `E:\xFACts-PowerShell\`. Patched 2026-05-11 to wire `has_dynamic_content` through `New-AssetRegistryRow` and `Invoke-AssetRegistryBulkInsert`.

**Phase 1 JS refactor work complete.** All four Phase 1 page JS files are refactored to spec compliance and parsing at zero structural drift, with inline event handlers migrated to delegated `addEventListener` bindings in the same session as each structural refactor: `client-relations.js`, `business-services.js`, `backup.js`, `replication-monitoring.js`, `business-intelligence.js`. The `business-intelligence.js` refactor was a full file rewrite (revealing-module wrapper eliminated). All five files (including the previously-completed `client-relations.js` and the rewritten `business-intelligence.js`) are spec-validation artifacts living offline alongside the running pre-spec versions; they go live during the Phase 1 batch sweep when CSS/JS/HTML/PS for each page migrate together. Note: the wiring design conversation (2026-05-12) may modify how this batch sweep proceeds; if the inverted wiring model is adopted, these files may need additional refactor work for `data-action` dispatch patterns before going live.

**Active spec documents:**

- `CC_CSS_Spec.md` — Production. Singular `Prefix:` form, registry validation in §5.4, drift codes `MALFORMED_PREFIX_VALUE` and `PREFIX_REGISTRY_MISMATCH` in §16. As of 2026-05-07: anchor file generalization in §4.3 and §11; 76-character banner rule lines (§3.1); granular banner drift codes in §16.2; permissive admission/strict validation note in §3.2.
- `CC_JS_Spec.md` — Production. As of 2026-05-09: §12 introduces an event-handler-binding section (§12.1 delegation pattern as canonical, §12.2 permitted direct-binding cases for singleton elements and document/window-level events). Sections §13 onward renumbered; §15 forbidden-patterns table and §19.4 add `FORBIDDEN_PER_ELEMENT_LISTENER_LOOP` for the `forEach + addEventListener` pattern. The JS populator was patched the same session to detect the new code. As of 2026-05-08: spec hygiene principle added to preamble (specs describe rules and shapes, never present contents); §7.4 introduces the fixed-form `CONSTANTS: ENGINE PROCESSES` banner; §10 clarifies that an empty IMPORTS section omits its banner entirely; §14 / §16.2 / §17 / §18.4 add `FORBIDDEN_INLINE_EVENT_IN_JS` covering inline `on<event>="..."` attributes in template/string literals; §7.2 distinguishes SCREAMING_SNAKE_CASE for primitives from camelCase for objects/arrays/computed values; §8 hooks pattern preserved unchanged. As of 2026-05-07: §3.1 tightened to the 76-character banner rule (matching CSS); §3.2 permissive admission/strict validation paragraph; §5.4 added the `PREFIX_MISSING` rule for top-level identifiers; §14 added `FORBIDDEN_REVEALING_MODULE` row and a new §14.2 on forbidden wrapper patterns; §18.2 retired `MALFORMED_SECTION_BANNER` in favor of seven granular `BANNER_*` codes; §18.3 added `PREFIX_MISSING`; §18.4 added `FORBIDDEN_REVEALING_MODULE`. The spec and the populator are aligned; the populator emits exactly the drift codes the spec defines. JS spec may gain additional rules pending HTML/JS wiring model decision (see `CC_HTML_JS_Wiring_Design.md`).
- `CC_HTML_Spec.md` — First draft locked 2026-05-10, amended 2026-05-11. 17 sections plus Appendix; 88 drift codes. Pipeline order CSS → HTML → JS → PS. Sections §3.2 (asset references) and §6 (event handlers) are under review pending the wiring design conversation; amendments may follow.
- `CC_PS_Module_Spec.md`, `CC_PS_Route_Spec.md` — pre-design (stubs). Queued; some PS work may proceed in parallel since it's independent of the HTML/JS wiring decision.

**Phase 1 CSS refactor work — complete and at zero drift:**

| File | Prefix |
|------|--------|
| `cc-shared.css` | (uses `--<category>-*` token namespace; banners declare `Prefix: (none)`) |
| `backup.css` | `bkp` |
| `business-intelligence.css` | `biz` |
| `client-relations.css` | `clr` |
| `replication-monitoring.css` | `rpm` |
| `business-services.css` | `bsv` |

**Phase 1 JS refactor work — complete:**

| File | Prefix | Status |
|------|--------|--------|
| `cc-shared.js` | (uses prefix-free shared namespace; banners declare `Prefix: (none)`) | DONE — zero file-attributable drift |
| `engine-events.js` | (legacy shared file) | LEGACY — deactivates after Phase 1 page JS files migrate to `cc-shared.js` during the Phase 1 batch sweep |
| `client-relations.js` | `clr` | DONE — zero drift |
| `business-services.js` | `bsv` | DONE — zero drift after inline event handler migration |
| `backup.js` | `bkp` | DONE — zero drift; full structural refactor with delegated event handling |
| `replication-monitoring.js` | `rpm` | DONE — zero drift; full structural refactor with delegated event handling |
| `business-intelligence.js` | `biz` | DONE — zero drift; full file rewrite (revealing-module wrapper eliminated) |

All four Phase 1 page JS files are spec-validation artifacts (delivered as `*-spec.js` companions) living offline alongside the running pre-spec versions. They go live during the Phase 1 batch sweep when CSS, JS, HTML, and PS for each page migrate together, with the corresponding route HTML updates coordinated as part of the same flip. The wiring design conversation may add `data-action` dispatch refactor work to this set before they go live.

**Docs site CSS files — refactor queued:**

| File | Lines | Total catalog rows | Rows with drift | Refactor priority |
|------|-------|--------------------|------------------|------|
| `docs-base.css` | 373 | 158 | 99 (62.7%) | Anchor-file migration (becomes `docs-shared.css` — see queued work item below) |
| `docs-controlcenter.css` | 805 | 344 | 248 (72.1%) | Largest, densest; refactor after `docs-shared.css` migration |
| `docs-reference.css` | 479 | 186 | 107 (57.5%) | After `docs-shared.css` migration |
| `docs-architecture.css` | 333 | 140 | 71 (50.7%) | After `docs-shared.css` migration |
| `docs-hub.css` | 170 | 99 | 49 (49.5%) | After `docs-shared.css` migration |
| `docs-narrative.css` | 118 | 73 | 32 (43.8%) | After `docs-shared.css` migration |
| `docs-erd.css` | 167 | 55 | 21 (38.2%) | After `docs-shared.css` migration; needs JS coordination (combined `.is-pk-fk` class) |

The drift counts are roughly comparable to unrefactored CC files. The dominant codes are `MISSING_PURPOSE_COMMENT` (315), `FORBIDDEN_DESCENDANT` (204), `FORBIDDEN_COMPOUND_DECLARATION` (149), `MISSING_VARIANT_COMMENT` (99), `MISSING_PREFIX_DECLARATION` (78), `BANNER_MALFORMED_TITLE_LINE` (76), `DRIFT_HEX_LITERAL` (69, all in `docs-controlcenter.css` mock-page rules), `BANNER_INLINE_SHAPE` (65), and `FORBIDDEN_GROUP_SELECTOR` (33). All resolutions are the same as for unrefactored CC files.

**Forbidden-wrapper JS files — refactor queued (full rewrite required):**

| File | Wrapper pattern | Drift code | Status |
|------|----------------|------------|--------|
| `admin.js` | `const Admin = (function(){...})()` | `FORBIDDEN_REVEALING_MODULE` | Queued for per-page migration phase |
| `bdl-import.js` | `const BDL = (function(){...})()` | `FORBIDDEN_REVEALING_MODULE` | Queued for per-page migration phase |
| `applications-integration.js` | revealing-module | `FORBIDDEN_REVEALING_MODULE` | Queued for per-page migration phase |
| `client-portal.js` | revealing-module | `FORBIDDEN_REVEALING_MODULE` | Queued for per-page migration phase |
| `business-intelligence.js` | revealing-module (eliminated) | `FORBIDDEN_REVEALING_MODULE` | DONE — rewritten 2026-05-09 (Phase 1) |
| `platform-monitoring.js` | revealing-module | `FORBIDDEN_REVEALING_MODULE` | Queued for per-page migration phase |
| `ddl-erd.js` | top-level IIFE | `FORBIDDEN_IIFE` | Queued for per-page migration phase |
| `ddl-loader.js` | top-level IIFE | `FORBIDDEN_IIFE` | Queued for per-page migration phase |
| `docs-controlcenter.js` | top-level IIFE | `FORBIDDEN_IIFE` | Queued for per-page migration phase |
| `nav.js` | top-level IIFE | `FORBIDDEN_IIFE` | Queued for per-page migration phase |

Nine of the original ten files require full rewrite rather than in-place repair. Their inner functions and constants live inside a wrapper namespace that has no equivalent in the spec'd top-level-function model; migrating any of them means restructuring every call site that references the wrapper namespace. Until they're rewritten, the catalog continues to flag the wrapper as forbidden via drift on the wrapper row, and the cross-reference USAGE rows from inside their bodies continue to populate the catalog so cross-page consumption queries during Phase 1 remain accurate. `business-intelligence.js` was completed during the 2026-05-09 Phase 1 JS refactor session; the other nine remain queued for the per-page migration phase. Note: if the wiring conversation settles toward the inverted model, the refactor pattern for these files would change — the revealing-module rewrite would extend to `data-action` dispatch refactoring as part of the wiring conversion.

**Next steps (queued work):**

1. **Settle the HTML/JS wiring conversation.** Active discussion driven by `CC_HTML_JS_Wiring_Design.md`. Outcome determines: whether HTML Spec §3.2 / §6 amend; whether JS Spec gains entry-point and dispatch sections; whether HTML populator's `JS_FILE USAGE` and `JS_FUNCTION USAGE` row emission stays or gets removed; how subsequent Phase 1 batch sweep page refactors are structured; pilot-page selection. Until this settles, HTML populator Wave 2.1 and several related items are paused.

2. **HTML populator Wave 2.1 (paused).** Drift code attachment work for additional HTML constructs. Will resume after wiring conversation settles. Some Wave 2.1 drift codes target patterns (§6 event handlers, §3.2 script tag placement) that may change or disappear under the inverted model; premature to implement them yet.

3. **JS_FILE / JS_FUNCTION USAGE resolution decision (paused).** Three options on the table — back-fill from JS populator (~30 lines added to JS populator, violates read-only cross-populator model); orchestrator post-pass (defers to future orchestrator build); accept as `<undefined>` (reflects pipeline reality but leaves catalog incomplete). The inverted wiring model adds a fourth option — the USAGE rows simply don't exist — which supersedes the first three. Holding decision pending wiring outcome.

4. **PS populator plus PS spec design (modules and routes).** Two specs, one populator covering both. Can proceed in parallel with wiring conversation since PS work is largely independent of the HTML/JS wiring decision. Will also consume the helpers file and follow the permissive-admission pattern. The PS populator emits its own anchor row (PS_FILE) for each scanned PS file; the HTML populator's `HTML_FILE` anchor row coexists with that.

5. **Phase 1 batch sweep — complete the Phase 1 pages across HTML and PS to bring the pages fully online.** CSS is done; JS is done. HTML and PS are the remaining halves. The flip for each page is coordinated. Pending wiring outcome — if inverted model is adopted, the JS refactor work for these files extends to `data-action` dispatch patterns.

6. **`docs-base.css` → `docs-shared.css` migration.** Parallel to `engine-events.css` → `cc-shared.css`. Create `docs-shared.css` next to `docs-base.css`; migrate sections incrementally using the populator's SHARED/LOCAL scope columns to track progress; retire `docs-base.css` when empty; update `<link>` tags across all docs pages. The populator's anchor-file enforcement check (drift codes `DUPLICATE_FOUNDATION`, `DUPLICATE_CHROME`) will need to learn about the second anchor file — small change, lands alongside the first docs CSS file refactor when we get there.

7. **Per-file refactor for the seven docs CSS files.** Joins the same queue as the unrefactored CC files. Same six-category treatment per file. `FORBIDDEN_DESCENDANT` resolutions require coordinated HTML updates across docs pages; these fall under the same per-file refactor scope. `docs-erd.css` additionally requires a `ddl-erd.js` change to emit a single combined `.is-pk-fk` class.

8. **Page-at-a-time migration for the remaining ~22 CC pages.** Pending wiring outcome and Phase 1 batch sweep completion.

**Schema state:** All schema additions implied by the HTML spec are deployed.

1. `dbo.Asset_Registry.has_dynamic_content BIT NULL` — deployed. Helpers file patched 2026-05-11 to wire the column through `New-AssetRegistryRow` and `Invoke-AssetRegistryBulkInsert`.
2. `Orchestrator.ProcessRegistry.cc_engine_slug VARCHAR(20) NULL` — deployed.
3. `Orchestrator.ProcessRegistry.cc_engine_label VARCHAR(50) NULL` — deployed.
4. `Orchestrator.ProcessRegistry.cc_page_route VARCHAR(100) NULL` — deployed.
5. `Orchestrator.ProcessRegistry.cc_sort_order INT NULL` — deployed. Content backfill pending.
6. `CK_Asset_Registry_component_type` CHECK constraint — admits `HTML_FILE`, `CSS_FILE`, `JS_FILE` and the parsed-header FILE_HEADER for CSS/JS. Constraint admits 44 values total as of 2026-05-12.

The four cc-prefixed columns on ProcessRegistry are populated for active scheduled processes (`run_mode = 1`) only; queue processors (`run_mode = 2`) and inactive processes (`run_mode = 0`) leave them NULL. The HTML spec validates this discipline via drift codes `MISSING_ENGINE_CARD_REGISTRATION` and `UNEXPECTED_ENGINE_CARD_REGISTRATION`.

**Open Items / Decisions Needed:**

1. **HTML/JS wiring model decision.** The single biggest open question. See `CC_HTML_JS_Wiring_Design.md`. Drives several downstream decisions including the JS_FILE/JS_FUNCTION resolution question, HTML Spec §3.2/§6 amendments, JS Spec entry-point and dispatch additions, Phase 1 batch sweep approach, and pilot page selection.

2. **`Refresh-AssetRegistry.ps1` orchestrator pattern.** On-demand execution from Admin page (matching documentation pipeline trigger pattern), no scheduling. Sequential CSS → HTML → JS → PS execution under `sp_getapplock` single-instance protection. Orchestrator landing can happen any time after all populators are current; not a blocker for migration work. Detailed design in `CC_Catalog_Pipeline_Working_Doc.md`.

3. **CSS and JS spec rationale cleanup pass.** The HTML spec applies a stricter format principle than CSS and JS achieve today: rules-only-in-body, all rationale in Appendix. CSS and JS specs have inline rationale in some sections that should be moved to their respective appendices for cross-spec consistency. Not blocking; cleanup pass when convenient.

**Blocked on:** HTML/JS wiring conversation (for Wave 2.1, resolution back-fill, Phase 1 batch sweep approach). Other work streams (PS populator, docs-site CSS, infrastructure) unblocked.

---

## Prefix Registry

The prefix registry lives in `dbo.Component_Registry.cc_prefix`. Each CC page's component carries a 3-character lowercase prefix that scopes its page-local identifiers across CSS class names, HTML class attributes, HTML IDs, and JS top-level identifiers. Components without a CC page (shared resources, infrastructure, vendor libraries, the docs site) carry `cc_prefix = NULL` and their files declare `Prefix: (none)` in section banners.

The column is enforced by:

- A filtered unique index (`UQ_Component_Registry_cc_prefix`) preventing two components from claiming the same prefix.
- A CHECK constraint (`CK_Component_Registry_cc_prefix`) requiring exactly three lowercase ASCII letters, with a case-sensitive collation override so uppercase variants are rejected.

The CSS, JS, and HTML populators read this column at startup to validate banner-declared prefixes (CSS, JS) and to validate top-level identifier names, page-local IDs, page-local class names, and event handler function calls against the file's registered prefix. See `CC_CSS_Spec.md` Section 5.4, `CC_JS_Spec.md` Section 5.4, and `CC_HTML_Spec.md` §4.2 / §5.1 / §6.2 for the validation rules.

Adding a new CC page: insert the component row in `Component_Registry` with the chosen `cc_prefix`, then create the page's CSS and JS files with banners that declare that prefix, and ensure the page's HTML route file uses prefixed IDs and class names. The populators will validate on the next run.

---

## Anchor file registry

Each component anchor file (`CC_CSS_Spec.md` §4.3) is the single owner of its component's FOUNDATION and CHROME sections. The platform recognizes one anchor file per component:

| Component | Anchor file | Status |
|-----------|-------------|--------|
| `ControlCenter.Shared` | `cc-shared.css` | In production. |
| `Documentation.Site` | `docs-shared.css` | Planned. Currently `docs-base.css` until the migration described in Queued Work item 6 completes. |

Adding a new platform domain that needs its own anchor file requires a small spec amendment (`CC_CSS_Spec.md` §4.3 table addition) plus a populator update. No other CSS file in the codebase may carry FOUNDATION or CHROME sections; the populator emits `DUPLICATE_FOUNDATION` / `DUPLICATE_CHROME` on any such file.

---

## Universal anchor-row model

As of 2026-05-12, all three populators (CSS, JS, HTML) follow the universal anchor-row model. Every scanned file produces a `<TYPE>_FILE` anchor row regardless of header presence; FILE_HEADER rows are emitted only where a parsed-header construct exists.

| Populator | Anchor row | Header row |
|---|---|---|
| CSS | `CSS_FILE` (always) | `FILE_HEADER` (when present) |
| JS  | `JS_FILE` (always) | `FILE_HEADER` (when present) |
| HTML | `HTML_FILE` (always) | — (HTML markup has no file-header construct; the host PS file's header is the PS populator's concern) |
| PS (future) | `PS_FILE` (always) | `FILE_HEADER` (when present) |

The anchor row hosts file-level drift codes (e.g., HTML's §15.1 page-shell codes attach to HTML_FILE). The FILE_HEADER row, where it exists, holds the parsed-header content and any header-specific drift. The two rows coexist cleanly on the same physical file.

Asset-reference resolution between populators uses the `<TYPE>_FILE` anchor rows: HTML's `<link rel="stylesheet">` references resolve against `CSS_FILE` rows; HTML's `<script src=>` references resolve against `JS_FILE` rows (subject to the pipeline-order resolution constraint discussed in `CC_HTML_JS_Wiring_Design.md`).

---

## Conversion tracking model

Files exist in one of three states during the initiative:

- **Pre-spec** — file has not been refactored against any current spec. Drift codes in the catalog reflect the file's pre-refactor state.
- **Partially compliant** — file has been refactored against one or more file-type specs but not all. The page works but the catalog reflects mixed compliance.
- **Fully compliant** — file has been refactored against every applicable spec and parses at zero drift across all of them.

The current direction (page-at-a-time migration after JS, HTML, and PS specs land) means each page transitions directly from pre-spec to fully compliant within a single coordinated session, eliminating the partially-compliant state for those pages. The wiring conversation outcome may alter this — if the inverted model is adopted, "fully compliant" may include `data-action` dispatch conformance as a fourth dimension beyond CSS/JS/HTML/PS spec compliance.

---

## HTML spec evolution

This section tracks the evolution of `CC_HTML_Spec.md` since the initiative began. Each entry summarizes what changed in the spec and why, in chronological order.

### 2026-05-10 — Initial draft

Defined the complete HTML markup specification across 17 numbered sections plus an Appendix, totaling 88 drift codes. Mirrors the rhythm of the CSS and JS specs (numbered rule sections, drift codes inline, summary/forbidden-patterns/catalog-model meta-sections, compliance queries, examples).

The structural pattern of body sections: §1 (page shell required structure), §2 (page chrome — header bar, refresh info, engine cards, connection banner placeholder), §3 (asset references — exactly two CSS files and two JS files in mandated forms with mandated order), §4 (ID conventions — chrome ID closed set, page-local prefix discipline, slideout/modal/panel ID conventions, purpose comments mandated for slideouts/modals/panels), §5 (class attribute conventions including the array-join pattern as the one mandated dynamic class assembly form), §6 (event handler conventions — exactly one function call per handler, no inline expressions, no revealing-module calls), §7 (data-* attribute conventions), §8 (text content with categorical naming derivation for cross-page comparison), §9 (inline SVG treated as opaque markup at the catalog level), §10 (HTML comments).

Meta-sections aggregate from the rule sections: §11 required patterns summary, §12 forbidden patterns table, §13 catalog model, §14 what the parser extracts, §15 drift codes reference, §16 compliance queries, §17 examples, Appendix rationale.

The HTML spec is the first to apply rules-only-in-body / rationale-in-appendix completely. The CSS and JS specs have inline rationale in some sections that future cleanup passes will move to their respective appendices for cross-spec consistency.

Significant cross-cutting decisions:

- **Pipeline order revised to CSS → HTML → JS → PS.** HTML moves earlier in the pipeline (was previously last among CSS/HTML/JS) because JS USAGE rows for IDs and data-attributes need to resolve against HTML DEFINITION rows. The relationship: CSS is the grandparent (no upstream dependencies); HTML is the parent (depends on CSS for class scope resolution); JS is both child and grandchild (depends on CSS for class scope and on HTML for ID and data-attribute resolution); PS runs last and emits its own per-file anchor row distinct from HTML's HTML_FILE anchor row.

- **On-demand execution from Admin page.** No orchestrator scheduling; the pipeline runs interactively from an Admin button matching the documentation pipeline pattern.

- **Engine cards sourced from `Orchestrator.ProcessRegistry` via four new cc-prefixed columns** (`cc_engine_slug`, `cc_engine_label`, `cc_page_route`, `cc_sort_order`). Active scheduled processes (`run_mode = 1`) require all four populated; queue processors (`run_mode = 2`) require all four NULL; inactive processes (`run_mode = 0`) are unvalidated.

- **`has_dynamic_content` flag column added to `dbo.Asset_Registry`** as a BIT NULL column. Set TRUE on HTML and JS populator rows where the parent attribute or text construct contains additional runtime-only content the populator cannot statically resolve.

- **One mandated dynamic class assembly pattern (array-join).** The PowerShell array-join idiom is the only legitimate way to construct a dynamic class string. All other forms are forbidden, with four granular drift codes covering specific syntactic violations.

- **Categorical naming for `HTML_TEXT` rows.** `component_name` for text rows holds a derived categorical identifier rather than the literal text. The page prefix is stripped from leading class tokens during derivation so categories are comparable across pages.

- **Slideout/modal/panel ID role-first ordering.** ID conventions follow `<prefix>-slideout-<purpose>-overlay` form (role between prefix and purpose).

- **Mandated HTML purpose comments for slideouts, modals, and slide-up panels.** Comment immediately preceding the overlay/backdrop is read into `purpose_description`.

- **Three forms of HTML entity references catalogued separately.** Named entities (`&times;`), numeric entities (`&#9881;`), and direct Unicode characters (`⚙`) each produce their own `HTML_ENTITY` row.

- **Helper functions are page-agnostic.** Helpers may emit chrome IDs and chrome function calls, but never page-prefixed IDs, page-prefixed function calls, or page-specific `data-*` attributes.

- **Access-denied page (`Get-AccessDeniedHtml`) carve-out.** The 403 page does not conform to the standard page shell.

### 2026-05-11 — `HTML_FILE` anchor row and read-only cross-populator model

Two structural amendments landed ahead of the production HTML populator build, both surfaced during pre-build review of the spec against the live schema and against the populator family's working invariants.

**§13.6 rewritten to lock in a strict read-only cross-populator model.** No populator ever edits another populator's rows; all cross-references resolve at scan time against existing DEFINITION rows produced by upstream populators. Replaces an earlier model implied by the prior §13.6 where the PS populator would enrich existing HTML rows by filling in `parent_object` values after the fact. The new model is cleaner: every populator is independently re-runnable, no populator depends on another populator's write-back, and the populator family's invariant "produce rows, never modify others' rows" holds uniformly. The `parent_object` column does not exist on the live schema; §5.3's CSS_CLASS USAGE column table was corrected to remove its row. §14 was also cleaned up to drop a stale "route path (later filled in by PS populator)" reference. HTML rows fill `parent_function` directly during the HTML populator's own PS-AST walk from the enclosing function context.

**`HTML_FILE` component type adopted as the file-level anchor row.** §13.1 and §13.2 add the new type to the catalog model and component_type table. §14 adds two `HTML_FILE` row shapes: route files (one row, `scope=LOCAL`, `component_name` = page route, hosts §15.1 page-shell drift codes) and helper files (one row, `scope=SHARED`, `component_name` = helper function name, §15.1 codes do not fire). §15.1 introduces an intro paragraph directing the page-shell drift codes to attach to the `HTML_FILE` anchor row. `CK_Asset_Registry_component_type` was updated in the same session to admit `HTML_FILE`.

The helpers file (`xFACts-AssetRegistryFunctions.ps1`) was patched the same session to wire `has_dynamic_content` through the row builder and bulk-insert DataTable.

### 2026-05-12 — Universal anchor-row refactor; resolution gap surfaces wiring conversation

The HTML populator's CSS_FILE / JS_FILE pre-load queries were retargeted to align with the universal anchor-row refactor that completed across the populator family. The CSS and JS populators had previously emitted dual-purpose `FILE_HEADER` rows that served both as file-level anchors and as parsed-header rows. The universal refactor split these: every file now emits a pure-anchor `<TYPE>_FILE` row (CSS_FILE for CSS, JS_FILE for JS, HTML_FILE for HTML), with FILE_HEADER reserved for the parsed file-header construct (where one exists). HTML doesn't emit a FILE_HEADER row because HTML markup has no file-header construct.

The HTML populator's pre-load queries that previously targeted `FILE_HEADER` (as an interim measure) were retargeted to `CSS_FILE` and `JS_FILE`. Spec sections describing cross-populator resolution (§3, §13.6, §14) were reviewed and confirmed correct against the post-refactor model — they had always described resolution against `CSS_FILE DEFINITION` and `JS_FILE DEFINITION` rows in the post-refactor target shape; only the populator's interim implementation had used FILE_HEADER as a workaround.

Verification after deployment revealed an asymmetric resolution gap: CSS_FILE resolved cleanly (37 / 0) but JS_FILE did not (0 / 41), plus JS_FUNCTION had 284 unresolved rows. Root cause: pipeline order. CSS runs before HTML so HTML's CSS USAGE rows resolve cleanly; JS runs after HTML so HTML's JS USAGE rows have no DEFINITION rows to resolve against at scan time.

The gap is structural to the pipeline order and surfaces a deeper architectural question: do HTML→JS USAGE rows need to exist in the catalog at all? An alternative wiring model — HTML declares page identity via `data-page` and dispatches via `data-action` markers; a bootloader discovers and loads JS modules; JS attaches itself via delegated event listeners — would eliminate those USAGE rows entirely because the references they describe would not exist in source code. See `CC_HTML_JS_Wiring_Design.md` for the active design conversation, which considers both this alternative and several options that retain the current wiring pattern.

HTML spec §3.2 (asset references) and §6 (event handlers) are paused pending the wiring conversation outcome. Wave 2.1 of the HTML populator (drift code attachment work) is similarly paused since several Wave 2.1 codes target patterns that may change or disappear under the inverted model.

---

## JS spec evolution

This section tracks the evolution of `CC_JS_Spec.md` since the initiative began. Each entry summarizes what changed in the spec and why, in chronological order.

### 2026-05-04 — Initial release

Defined the section-type taxonomy (`IMPORTS`, `CONSTANTS`, `STATE`, `INITIALIZATION`, `FUNCTIONS` for page files; `FOUNDATION` and `CHROME` reserved for `cc-shared.js`). Established the page-prefix discipline for top-level identifiers (`<prefix>_<name>` form, underscore separator), with exemptions for hook names and the `cc-shared.js` file. Mandated a single block comment preceding every cataloged definition. Forbade CHANGELOG blocks in file headers. Forbade `let`. Established the page lifecycle hooks contract with `cc-shared.js` and the requirement that hooks live in a fixed-name banner placed last in the file. Defined twelve component types and the initial drift code reference covering ~35 codes.

### 2026-05-05 — Variant model added

Catalog model section expanded to introduce the variant model: three component types gained `_VARIANT` siblings (`JS_FUNCTION_VARIANT`, `JS_CONSTANT_VARIANT`, `JS_METHOD_VARIANT`) for sub-flavors with a true base form, while three other component types (`JS_IMPORT`, `JS_TIMER`, `JS_EVENT`) kept their single name and always carry a non-NULL `variant_type`. Stale references to a `parent_object` column (dropped in the 2026-05-03 schema migration) were remapped: three to `parent_function` for class containment on JS_METHOD rows, and one to `variant_qualifier_2` for the source module path on JS_IMPORT rows. CSS_CLASS USAGE scope determination clarified to note its dependency on the CSS populator running first.

### 2026-05-05 — Single-form-only rules

Spec tightened to single-form-only rules during the populator change-pass design. Where JavaScript permits multiple ways to express a construct, the spec now picks one and forbids the others. Function definitions: only `function name() {}` declarations are permitted; arrow functions and function expressions assigned to a const/var are forbidden and emit `FORBIDDEN_ANONYMOUS_FUNCTION`. The `JS_FUNCTION_VARIANT` table was trimmed to two rows (`async`, `generator`). Event bindings: `el.on<event> = handler` style was forbidden; only `addEventListener` is permitted (new drift code `FORBIDDEN_PROPERTY_ASSIGN_EVENT`). The anonymous-function carve-out narrowed to "callback arguments to other calls" only. Forbidden patterns without a natural declaration host gained dedicated component types (`JS_IIFE`, `JS_EVAL`, `JS_DOCUMENT_WRITE`, `JS_WINDOW_ASSIGNMENT`, `JS_INLINE_STYLE`, `JS_INLINE_SCRIPT`, `JS_LINE_COMMENT`) so every violation produces a queryable row. Other additive changes: `JS_CONSTANT_VARIANT` extended with an `expression` row for computed values; new component type `JS_HOOK_VARIANT` for async lifecycle hooks; new drift code `UNKNOWN_HOOK_NAME`.

### 2026-05-05 — cc-shared.js taxonomy realignment

The `cc-shared.js` section taxonomy was rewritten to align with the same structural pattern used by page files: declarations come first, worker code comes last. The previous seven-type list (`IMPORTS` -> `FOUNDATION` -> `CHROME` -> `CONSTANTS` -> `STATE` -> `INITIALIZATION` -> `FUNCTIONS`) placed `CHROME` before `STATE`, requiring CHROME functions to reference STATE variables declared textually below them via JS hoisting. The new four-type taxonomy is `IMPORTS` -> `FOUNDATION` -> `STATE` -> `CHROME`, with `FOUNDATION` as `cc-shared.js`'s name for what page files call `CONSTANTS`, `CHROME` as its name for `INITIALIZATION` plus `FUNCTIONS` combined, and `STATE` keeping the same name and meaning in both file kinds. The `WRONG_DECLARATION_KEYWORD` rule was updated to specify that `var` is forbidden in `FOUNDATION` sections (not just `CONSTANTS`), and `const` is forbidden in `STATE` sections in either file kind. No populator code change was needed — the populator already treated `FOUNDATION` as a constants-style section.

### 2026-05-06 — Editorial restructure

Spec restructured to operating-manual style. Body sections now contain rules only, with rationale moved to a dedicated Appendix at the end. All inline code examples consolidated into a single Examples section. Status, Owner, and cross-document references removed from the preamble. The previous in-doc revision history was migrated to this Initiative document and removed from the spec itself. No rule changes — this was a structural cleanup of how the spec is presented, not what it requires.

### 2026-05-06 — Prefix registry validation

Section 5 expanded with a new 5.3 (single prefix per banner) and 5.4 (registry validation against `Component_Registry.cc_prefix`) to formalize the relationship between file-header-declared prefixes and the platform's prefix registry. Two new drift codes added: `MALFORMED_PREFIX_VALUE` (banner declares anything other than a single 3-char prefix or `(none)`) and `PREFIX_REGISTRY_MISMATCH` (declared prefix disagrees with the registry's value for the file's component). The JS spec already used singular `Prefix:` form, so no rename was needed; this was a pure addition. §5.4 carries the strict-with-carve-outs reading: every banner on a non-shared file must declare the file's `cc_prefix`, except the hooks banner, IMPORTS section, and INITIALIZATION section, which may declare `(none)`. Populator enforcement is queued for the alignment refactor.

### 2026-05-07 — Banner format tightening, granular drift codes, forbidden wrapper patterns, prefix coverage

Multiple amendments landed in the same session as the populator alignment refactor, all with the goal of bringing the spec and the populator into alignment so the populator emits exactly the drift codes the spec defines.

§3.1 was tightened to specify exactly 76 characters for both the `=` opening/closing rule lines and the `-` middle separator (previously "any length 5 or more" / "any length"). The fixed length matches the CSS spec's tightened rule from the same session, fits within an 80-column convention with margin for `/* ` and ` */` comment delimiters, and aligns with the granular drift codes the populator enforces. The cross-spec consistency principle is explicit: where rules can be the same across CSS, JS, HTML, and PS, they are the same.

A new §3.2 (Banner detection and validation) was added documenting the permissive-admission/strict-validation pattern: any block comment that is banner-shaped produces a `COMMENT_BANNER` row regardless of conformance, and the drift codes carry the conformance verdict. This codifies a design principle that always existed informally but had drifted into a stricter regex-only admission model in the populator. Same pattern as the CSS spec adopted in its 2026-05-07 amendment.

The legacy `MALFORMED_SECTION_BANNER` drift code was retired and replaced with seven granular codes in §18.2. Each code describes exactly one violation, allowing precise refactor triage.

§14 was extended with a new entry for the revealing-module IIFE pattern (`const X = (function(){...})()` and var equivalent) and the new drift code `FORBIDDEN_REVEALING_MODULE`. A new §14.2 was added grouping both forbidden top-level wrapper patterns and explaining their treatment.

§5.4 added a new bullet introducing the `PREFIX_MISSING` drift code: top-level identifiers themselves must begin with the file's registered `cc_prefix` followed by an underscore, independently of banners.

### 2026-05-08 — First Phase 1 page refactors surface spec gaps; engine processes contract banner; inline event handlers; spec hygiene preamble

The first two Phase 1 page JS refactors drove a cluster of related amendments. The work followed a "spec describes what we want; files conform to spec, not vice versa" principle — every gap surfaced by an actual refactor was closed in the spec rather than worked around in the file.

A spec hygiene principle was added to the spec preamble: specs describe rules and shapes, never present contents.

§7.4 introduces the fixed-form `CONSTANTS: ENGINE PROCESSES` banner with `Prefix: (none)`. The `ENGINE_PROCESSES` constant is a name contract with `cc-shared.js`.

§7.2 distinguished SCREAMING_SNAKE_CASE casing rules: primitives use SSC; objects/arrays/computed values use camelCase.

§10 clarified the empty IMPORTS section rule: when a file has no imports, the IMPORTS banner is omitted entirely.

§14, §16.2, §17, and §18.4 added `FORBIDDEN_INLINE_EVENT_IN_JS` drift covering inline `on<event>="..."` attribute strings inside template literals or string literals.

### 2026-05-09 — Event handler binding section (§12); per-element listener loop pattern forbidden

The remaining three Phase 1 page JS refactors drove the next round of spec amendments. The dominant pattern surfaced was per-element listener attachment via `forEach + addEventListener`.

§12 (Event handler binding) introduces this topic explicitly. The opening establishes that handlers are attached via `addEventListener` and that the canonical form is event delegation. §12.1 names the three structural pieces. §12.2 names the only two cases where direct binding is allowed: singleton elements bound at page boot, and window/document-level events.

Sections §13 onward renumbered. §15 adds `FORBIDDEN_PER_ELEMENT_LISTENER_LOOP`. §19.4 carries the same code.

The JS populator was patched the same session to detect the new code.

**Note for forward planning:** §12.1's delegation pattern is a partial step toward the inverted wiring model now under discussion in `CC_HTML_JS_Wiring_Design.md`. If the inverted model is adopted, the JS spec would gain coverage for entry-point conventions and dispatch table patterns (the specific shape depends on Q3 and Q4 in the wiring design doc); §12 would extend to cover delegation against `data-action` markers. If the current model is retained, no new JS spec sections are needed for wiring concerns.

---

## CSS spec evolution

This section tracks the evolution of `CC_CSS_Spec.md` since the initiative began.

### 2026-05-04 — Initial release

Defined the section-type taxonomy (`FOUNDATION`, `CHROME`, `LAYOUT`, `CONTENT`, `OVERRIDES`, `FEEDBACK_OVERLAYS`) with FOUNDATION and CHROME limited to `cc-shared.css`. Established the 3-character page-prefix discipline for class names. Mandated a single-line purpose comment preceding every base class and a trailing inline comment on every variant. Defined the variant model. Forbade descendant combinators and depth-3+ compounds, establishing the state-on-element pattern. Centralized custom property tokens in FOUNDATION with the `--<category>-<role>-<modifier>` naming convention.

### 2026-05-06 — Editorial restructure

Spec restructured to operating-manual style, matching the JS spec's pattern. Body sections now contain rules only, with rationale moved to a dedicated Appendix at the end. No rule changes.

### 2026-05-06 — Prefix singularization and registry validation

The plural `Prefixes:` field name was retired in favor of singular `Prefix:`, matching the JS spec's existing convention. Three associated changes: drift code `MISSING_PREFIXES_DECLARATION` renamed to `MISSING_PREFIX_DECLARATION`; new drift code `MALFORMED_PREFIX_VALUE`; new Section 5.3. Section 5.4 added to formalize registry validation against `Component_Registry.cc_prefix`.

### 2026-05-07 — Anchor file generalization

The FOUNDATION and CHROME single-file rule (§4.3) was generalized from "lives in `cc-shared.css`" to "lives in the component's anchor file." The platform now recognizes multiple anchor files — one per component-scope domain.

### 2026-05-07 — Banner format tightening and granular drift codes

§3.1 was tightened to specify exactly 76 characters for both the `=` opening/closing rule lines and the `-` middle separator. The legacy `MALFORMED_SECTION_BANNER` drift code was retired and replaced with seven granular codes in §16.2. A new §3.2 (Banner detection and validation) documented the permissive-admission/strict-validation pattern.

---

## Initiative decision history

A compressed record of cross-cutting decisions made across sessions. One or two lines per entry. Not a session log; not a revision history of this document. Decisions only.

- **2026-04-30** — Initiative scope and motivation defined. Goal: machine-parseable file formats per source-file type, with `dbo.Asset_Registry` as the queryable source of truth for the CC codebase.
- **2026-05-01** — Parser stack settled on Node + acorn (JS) and Node + PostCSS (CSS) after .NET-based approaches failed dependency-resolution tests on PS 5.1.
- **2026-05-02** — Refresh strategy: TRUNCATE plus reload per file_type, not MERGE upsert.
- **2026-05-03** — Schema migration: dropped `state_modifier`, `component_subtype`, `parent_object`, `first_parsed_dttm` from `Asset_Registry`.
- **2026-05-04** — Doc reorganization: retired `CC_FileFormat_Standardization.md` and related legacy docs. Created this Initiative doc as the navigation hub. Created stub spec docs for each file type.
- **2026-05-04** — `Asset_Registry` schema cleanup: dropped `related_asset_id`, `design_notes`, `is_active`. CSS populator wired purpose_description capture across all four CSS comment sources reaching 100% coverage on Phase 1 reference files.
- **2026-05-04** — Phase 1 CSS refactor work complete. cc-shared.css plus the five Phase 1 page CSS files all at zero drift.
- **2026-05-05** — JS variant model defined.
- **2026-05-05** — JS populator change pass implemented. cc-shared.js created and validated against `CC_JS_Spec.md`, reaching zero file-attributable drift.
- **2026-05-05** — Initiative direction shift adopted. Bring all four populators current first, then sweep Phase 1 across all file types together, then page-at-a-time migration.
- **2026-05-06** — Specs restructured to operating-manual style with rationale appendices and consolidated examples.
- **2026-05-06** — Cross-reference rule established. Permanent docs reference no other docs and stay self-contained.
- **2026-05-06** — Specs no longer carry versioning, status, or owner. A spec is settled until amended; amendments are recorded in this doc's Spec Evolution sections.
- **2026-05-06** — Decided to migrate the Prefix Registry from this doc to a `cc_prefix CHAR(3) NULL` column on `Component_Registry`. Migration completed same session.
- **2026-05-06** — Prefix declaration form standardized to singular `Prefix:` across both CSS and JS specs.
- **2026-05-06** — Pivoted from a small five-change populator pass to a coordinated alignment refactor after re-reading the populators with fresh eyes revealed substantial divergence.
- **2026-05-06** — Alignment design decisions locked. Visitor pattern; pre-built section list with body-line ranges; hybrid drift attachment; separated file-header parse/emit; FILE_ORG_MISMATCH per-file in Pass 2; closed-enum catch-all codes; output-boundary drift code check.
- **2026-05-06** — Strict registry validation (Option B) chosen over permissive.
- **2026-05-06** — Shared infrastructure architecture decided. New `xFACts-AssetRegistryFunctions.ps1` created as a domain-specific helpers file parallel to `xFACts-IndexFunctions.ps1`.
- **2026-05-06** — End-of-run verification queries removed from both populators.
- **2026-05-06** — Asset_Registry column descriptions populated in `dbo.Object_Metadata`.
- **2026-05-07** — Banner detection refactored to permissive-admission / strict-validation.
- **2026-05-07** — Granular banner drift codes adopted.
- **2026-05-07** — Anchor-file generalization adopted; single-spec model preserved across CC application and docs site.
- **2026-05-07** — Docs site CSS refactor brought into initiative scope.
- **2026-05-07** — JS populator alignment refactor delivered.
- **2026-05-07** — `FORBIDDEN_REVEALING_MODULE` drift code adopted in the JS spec.
- **2026-05-07** — `PREFIX_MISSING` drift code adopted in the JS spec.
- **2026-05-07** — Definition-suppression flag mechanism adopted for forbidden top-level wrapper handling in the JS populator.
- **2026-05-07** — Cross-spec consistency principle made explicit.
- **2026-05-08** — Spec hygiene principle adopted.
- **2026-05-08** — `CONSTANTS: ENGINE PROCESSES` banner adopted in JS spec §7.4.
- **2026-05-08** — `FORBIDDEN_INLINE_EVENT_IN_JS` drift code adopted in JS spec.
- **2026-05-09** — JS spec §12 (Event handler binding) adopted.
- **2026-05-09** — JS populator catch-up delivered same session.
- **2026-05-09** — Phase 1 JS refactor work complete (all four pages plus rewritten business-intelligence.js).
- **2026-05-09** — JS populator surfaces three `FORBIDDEN_PER_ELEMENT_LISTENER_LOOP` rows on first run, all genuine and all resolved in the same session. Validates §12 + populator combination end-to-end.
- **2026-05-10** — HTML spec drafted across a single session. Pipeline order revised to CSS → HTML → JS → PS.
- **2026-05-10** — Engine card model formalized via four cc-prefixed columns on `Orchestrator.ProcessRegistry`.
- **2026-05-10** — `has_dynamic_content` BIT flag column added to `dbo.Asset_Registry`.
- **2026-05-10** — One mandated dynamic class assembly pattern (array-join) adopted.
- **2026-05-10** — Categorical naming for `HTML_TEXT` rows adopted.
- **2026-05-10** — Slideout/modal/panel ID role-first ordering adopted.
- **2026-05-10** — Mandated HTML purpose comments for slideouts, modals, and slide-up panels.
- **2026-05-10** — Three forms of HTML entity references catalogued separately.
- **2026-05-10** — Helper functions confirmed page-agnostic.
- **2026-05-11** — HTML spec §13.6 rewritten to lock in strict read-only cross-populator model.
- **2026-05-11** — `HTML_FILE` component type adopted as the file-level anchor row.
- **2026-05-11** — Helpers file patched to support `has_dynamic_content`.
- **2026-05-12** — Universal anchor-row refactor adopted and delivered across all three populators (CSS, JS, HTML). Every file gets a pure-anchor `<TYPE>_FILE` row; FILE_HEADER becomes the parsed-header construct (where present). HTML doesn't emit FILE_HEADER (no file-header construct in markup). HTML populator's CSS_FILE / JS_FILE pre-load queries retargeted to the universal model. Three previously-unattached JS drift codes (FORBIDDEN_COMMENT_STYLE, EXCESS_BLANK_LINES, BLANK_LINE_INSIDE_FUNCTION_BODY_AT_SCOPE) attached to their proper rows. Universal anchor working document retired with work integrated into this doc and the Catalog Pipeline doc.
- **2026-05-12** — JS_FILE / JS_FUNCTION USAGE resolution gap surfaced. CSS resolves cleanly (37/0) but JS doesn't (0/41 for JS_FILE; 0/284 for JS_FUNCTION). Root cause: pipeline order CSS → HTML → JS means JS DEFINITION rows don't exist when HTML scans. Three resolution options identified (back-fill from JS populator, orchestrator post-pass, accept as `<undefined>`) plus a fourth surfaced by the wiring discussion (USAGE rows don't exist under inverted model). Decision deferred pending wiring conversation.
- **2026-05-12** — HTML/JS wiring conversation opened. The catalog asymmetry between HTML→CSS resolution (clean) and HTML→JS resolution (structurally unresolvable at scan time) surfaced an architectural question about whether HTML→JS USAGE rows should exist at all. An inverted wiring model — HTML declares page identity via `data-page`; bootloader-driven JS module loading; delegated dispatch via `data-action` markers — was identified as one candidate that would eliminate the unresolvable rows by changing what the HTML source contains. Other candidate approaches retain the current wiring pattern with various resolution strategies for the unresolvable USAGE rows. New planning doc `CC_HTML_JS_Wiring_Design.md` opened to frame the discussion with seven design questions plus a pilot page question. No decisions made. Wave 2.1, JS_FILE/JS_FUNCTION resolution back-fill, Phase 1 batch sweep approach, and HTML Spec §3/§6 amendment scope paused pending the conversation. CSS work and PS populator design proceed independently.

---

## Future considerations

These are forward-looking platform improvements identified during initiative work but not currently in scope. Wish-list items rather than active commitments.

### Standardized empty-state text via helpers

Add helper functions to `xFACts-Helpers.psm1` that return standardized empty-state messages. Pages call these helpers instead of hardcoding text. Cross-page consistency: every page using `Get-EmptyStateMessage -Type 'no-executions'` displays identical text.

### Separate page-prefix into its own catalog column

Today, `component_name` for `CSS_CLASS` and `HTML_ID` rows includes the page prefix. Proposed change: add a `cc_prefix` column to `dbo.Asset_Registry`. `component_name` holds the un-prefixed name; `cc_prefix` holds the prefix separately. Phase 3 candidate after the initial spec rollout settles.

### UI display truncation surfacing

Some pages truncate values when displaying them in tables, slideouts, etc. Possible approach: a spec rule for CSS/JS requiring explicit justification for truncation patterns.

### Level 3 engine card model — fully registry-driven

The HTML spec's Level 2 model establishes engine card slug/label/page/sort sourced from `Orchestrator.ProcessRegistry`. Level 3 makes engine card markup itself registry-driven: a helper function reads ProcessRegistry and emits the markup; route files use a `$engineCardsHtml` substitution. Requires no further DDL changes — only consumption-pattern work.

### ProcessRegistry export to Platform Registry

`Orchestrator.ProcessRegistry` is foundational platform data. Adding ProcessRegistry to the Platform Registry export pipeline is a small backlog item that surfaces process inventory in the same generated documentation as other platform foundations.

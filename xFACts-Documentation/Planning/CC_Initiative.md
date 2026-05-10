# Control Center File Format Initiative

The CC File Format initiative defines a strict, machine-parseable file format for every CC source file type and refactors the existing CC codebase to conform. The goal is drift detection: files that follow a strict spec catalog cleanly into `dbo.Asset_Registry`, and the catalog is the queryable source of truth for "what exists in the codebase, what's shared, what's reinvented, and what's out of compliance."

The xFACts platform already has comprehensive cataloging on the SQL and PowerShell side via `dbo.Object_Registry` and `dbo.Object_Metadata`. The Control Center side previously had no equivalent — pages are made up of route .ps1 files, page CSS files, page JS files, and API .ps1 files, and the only way to answer "do we already have a CSS class for X" or "is there an API endpoint for Y" was to grep through source files. The catalog flips that: convention reuse becomes a query, not a guess.

This is the navigation hub for the initiative. It does not contain spec content — each file-type spec lives in its own document.

---

## Related documents

| Document | Contains |
|---|---|
| `CC_Catalog_Pipeline_Working_Doc.md` | Operational tracker for the parser pipeline that builds `dbo.Asset_Registry`. Architecture decisions, schema state, populator status, environment state, lessons learned. |
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
4. Read whichever spec document is named as active in Current State.
5. Begin work in that area. Honor any "Blocked on" or "Queued next" items.

This document is authoritative for project direction and state. Each spec document is authoritative for its file type. If anything in Project Knowledge or Claude's memory contradicts what is written here, the documents win.

Before ending a session, update Current State and add an entry to the Initiative decision history if a substantive decision was made.

---

## Current direction

Bring all four populators (CSS, HTML, JS, PS) and their specs current first. Then sweep the Phase 1 page set across all four file types together. Then page-at-a-time migration for the remaining ~22 pages. The docs site CSS files (and eventually JS files) are part of this scope: they conform to the same single-source-of-truth specs the CC application files do, with the per-component anchor file rule (`CC_CSS_Spec.md` §4.3) accommodating the docs site's separate visual chrome.

The original plan was to drive each spec to completion sequentially while refactoring Phase 1 pages within each file type as the spec stabilized. The cost-vs-progress trade became unfavorable — each spec/populator iteration was expensive, page-by-page refactors within a single file type didn't ship visible value, and we weren't yet in a position to migrate any page end-to-end.

---

## Current state

*Last updated: 2026-05-10.*

**HTML spec drafted (2026-05-10).** `CC_HTML_Spec.md` is a complete first-draft specification: 17 numbered sections plus an Appendix, ~1,930 lines, 88 drift codes spanning page shell (11), page chrome (19), asset references (12), IDs (11), class attributes (8), event handlers (16), data-* attributes (3), text content (2), SVG (1), comments (3), and inline asset blocks (2). Mirrors the rhythm of the CSS and JS specs (numbered rule sections, drift codes inline, summary/forbidden-patterns/catalog-model meta-sections, compliance queries, examples) with rationale strictly relegated to the Appendix per a stricter format principle than the existing CSS and JS specs achieve. The HTML spec is the first to apply rules-only-in-body / rationale-in-appendix completely; the CSS and JS specs have inline rationale in some sections that future cleanup passes will move to their respective appendices for cross-spec consistency. Population pipeline order revised to **CSS → HTML → JS → PS** (HTML moved earlier than its previous position) so JS USAGE rows can resolve against HTML DEFINITION rows for IDs and data-attributes; on-demand orchestrator execution from Admin page (matching documentation pipeline pattern), no scheduling. Spec is considered locked as the pre-populator settled-decisions list; amendments expected once the production HTML populator runs against real files.

**CSS and JS populator alignments are both delivered.** The 2026-05-07 session brought the JS populator current with the same alignment treatment CSS received earlier in the session: helpers-file consumption, visitor pattern, prefix registry validation, permissive-admission/strict-validation banner detection, plus two JS-specific additions (FORBIDDEN_REVEALING_MODULE detection for the revealing-module IIFE pattern, PREFIX_MISSING for top-level identifier validation against Component_Registry independent of banners). Both populators are in production, walking their full file sets cleanly.

**Helpers file in production.** `xFACts-AssetRegistryFunctions.ps1` (~1,295 lines, 22 functions) is deployed and consumed by both the CSS and JS populators. Centralizes row construction, dedupe tracking, drift code attachment (hybrid model: master-table validation plus optional row-specific context), occurrence-index computation, Object_Registry and Component_Registry registry loads, bulk insert plus DataTable shape, comment-text cleanup, banner detection (permissive `Test-IsBannerComment`) and parsing (strict `Get-BannerInfo` emitting granular drift codes), file-header parsing, pre-built section list construction with body-line ranges, file-org match check, and the generic AST visitor walker. Per-language logic (visitor scriptblock body, per-row emitters, selector decomposition, variant shape helpers, HTML attribute extraction, AST parent-context helpers) stays in each populator. The file lives alongside `xFACts-OrchestratorFunctions.ps1` and `xFACts-IndexFunctions.ps1` in `E:\xFACts-PowerShell\`.

**Phase 1 JS refactor work complete.** All four Phase 1 page JS files are refactored to spec compliance and parsing at zero structural drift, with inline event handlers migrated to delegated `addEventListener` bindings in the same session as each structural refactor: `client-relations.js`, `business-services.js`, `backup.js`, `replication-monitoring.js`, `business-intelligence.js`. The `business-intelligence.js` refactor was a full file rewrite (revealing-module wrapper eliminated). All five files (including the previously-completed `client-relations.js` and the rewritten `business-intelligence.js`) are spec-validation artifacts living offline alongside the running pre-spec versions; they go live during the Phase 1 batch sweep when CSS/JS/HTML/PS for each page migrate together. Per-page coordination work for the batch sweep includes a JS update pass to refactor ID strings used in `getElementById` calls to match the new HTML-spec-mandated prefixed forms (e.g., `getElementById('detail-modal')` → `getElementById('bsv-modal-detail')`), driven by drift surfacing in the catalog after the HTML populator runs.

**Active spec documents:**

- `CC_CSS_Spec.md` — Production. Singular `Prefix:` form, registry validation in §5.4, drift codes `MALFORMED_PREFIX_VALUE` and `PREFIX_REGISTRY_MISMATCH` in §16. As of 2026-05-07: anchor file generalization in §4.3 and §11; 76-character banner rule lines (§3.1); granular banner drift codes in §16.2; permissive admission/strict validation note in §3.2.
- `CC_JS_Spec.md` — Production. As of 2026-05-09: §12 introduces an event-handler-binding section (§12.1 delegation pattern as canonical, §12.2 permitted direct-binding cases for singleton elements and document/window-level events). Sections §13 onward renumbered; §15 forbidden-patterns table and §19.4 add `FORBIDDEN_PER_ELEMENT_LISTENER_LOOP` for the `forEach + addEventListener` pattern. The JS populator was patched the same session to detect the new code. As of 2026-05-08: spec hygiene principle added to preamble (specs describe rules and shapes, never present contents); §7.4 introduces the fixed-form `CONSTANTS: ENGINE PROCESSES` banner; §10 clarifies that an empty IMPORTS section omits its banner entirely; §14 / §16.2 / §17 / §18.4 add `FORBIDDEN_INLINE_EVENT_IN_JS` covering inline `on<event>="..."` attributes in template/string literals; §7.2 distinguishes SCREAMING_SNAKE_CASE for primitives from camelCase for objects/arrays/computed values; §8 hooks pattern preserved unchanged. As of 2026-05-07: §3.1 tightened to the 76-character banner rule (matching CSS); §3.2 permissive admission/strict validation paragraph; §5.4 added the `PREFIX_MISSING` rule for top-level identifiers; §14 added `FORBIDDEN_REVEALING_MODULE` row and a new §14.2 on forbidden wrapper patterns; §18.2 retired `MALFORMED_SECTION_BANNER` in favor of seven granular `BANNER_*` codes; §18.3 added `PREFIX_MISSING`; §18.4 added `FORBIDDEN_REVEALING_MODULE`. The spec and the populator are aligned; the populator emits exactly the drift codes the spec defines. JS spec gains additional rules during HTML populator validation pass (see Open Items / Decisions Needed).
- `CC_HTML_Spec.md` — First draft locked 2026-05-10. 17 sections plus Appendix; 88 drift codes. Pipeline order revised to CSS → HTML → JS → PS. Considered the pre-populator settled-decisions list; amendments expected once the production HTML populator runs against real files.
- `CC_PS_Module_Spec.md`, `CC_PS_Route_Spec.md` — pre-design (stubs). Queued after HTML populator validation pass completes.

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

All four Phase 1 page JS files are spec-validation artifacts (delivered as `*-spec.js` companions) living offline alongside the running pre-spec versions. They go live during the Phase 1 batch sweep when CSS, JS, HTML, and PS for each page migrate together, with the corresponding route HTML updates (renamed function references in inline `onclick` attributes, retirement of the local `connection-error` element in favor of cc-shared's `connection-banner`, etc.) coordinated as part of the same flip. A JS-side update pass to refactor ID strings used in `getElementById` calls to match the new HTML-spec-mandated prefixed forms is also part of the per-page coordination, driven by `JS_HTML_ID_UNRESOLVED` drift surfacing in the catalog after the HTML populator runs.

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

Nine of the original ten files require full rewrite rather than in-place repair. Their inner functions and constants live inside a wrapper namespace that has no equivalent in the spec'd top-level-function model; migrating any of them means restructuring every call site that references the wrapper namespace. Until they're rewritten, the catalog continues to flag the wrapper as forbidden via drift on the wrapper row, and the cross-reference USAGE rows from inside their bodies continue to populate the catalog so cross-page consumption queries during Phase 1 remain accurate. `business-intelligence.js` was completed during the 2026-05-09 Phase 1 JS refactor session; the other nine remain queued for the per-page migration phase.

**Next steps (queued work):**

1. Build production `Populate-AssetRegistry-HTML.ps1` against the locked HTML spec. Fresh build (the existing test populator is a sketch only, not a basis for production work). The production populator consumes `xFACts-AssetRegistryFunctions.ps1`, follows the visitor pattern, performs prefix registry validation, adopts permissive-admission/strict-validation, and emits the 88 drift codes per `CC_HTML_Spec.md` §15. Schema additions required before deployment — see Open Schema Items below.
2. Run the populator pipeline once end-to-end (CSS → HTML → JS) against current state. Validate the cross-population resolution model: HTML DEFINITION rows for IDs and data-attributes get produced; JS USAGE rows for the same constructs resolve against them. Catalog will surface significant drift on every existing route file (every page is spec-non-compliant) — that's the spec working as intended. The validation question is whether the populator emits the right drift codes on the right rows, not whether the codebase is clean.
3. Update `CC_JS_Spec.md` with the cross-spec rules surfaced during HTML spec drafting (see Open Items / Decisions Needed). Add JS-side ID string validation, data-attribute resolution, has_dynamic_content flag application to JS rows from template literals, and ENGINE_PROCESSES registry validation. New drift codes: `JS_HTML_ID_UNRESOLVED`, `JS_HTML_ID_MALFORMED`, `JS_DATA_ATTRIBUTE_UNRESOLVED`, `MISSING_ENGINE_PROCESSES_DECLARATION`, `ENGINE_PROCESS_PAGE_MISMATCH`, `ENGINE_SLUG_JS_MISMATCH`, `MISSING_ENGINE_CARD_FOR_REGISTERED_PROCESS`. Re-run the JS populator after the JS spec update to validate the new rules fire correctly.
4. PS populator plus PS spec design (modules and routes). Two specs, one populator covering both. Will also consume the helpers file and follow the permissive-admission pattern. The `parent_object` enrichment pass on existing HTML rows (filling in route paths) lands as part of PS populator implementation.
5. Phase 1 batch sweep — complete the Phase 1 pages across HTML and PS to bring the pages fully online. CSS is done (Phase 1 CSS files at zero drift); JS is done (all four Phase 1 page JS files plus the rewritten `business-intelligence.js` at zero drift, delivered as offline `*-spec.js` companions); HTML and PS are the remaining halves. The flip for each page is coordinated: route HTML inline `onclick` references update to the renamed function names, route HTML `connection-error` elements migrate to the cc-shared `connection-banner` pattern, route HTML `<script>` tags add the cc-shared.js load alongside or in place of engine-events.js, JS-side ID strings refactor to the new prefixed forms, and the page is tested as a unit before declaring it migrated.
6. **`docs-base.css` → `docs-shared.css` migration.** Parallel to the `engine-events.css` → `cc-shared.css` migration. Create `docs-shared.css` next to `docs-base.css`; migrate sections incrementally (FOUNDATION first — variables and resets; then chrome; then layout primitives) using the populator's SHARED/LOCAL scope columns to track progress; retire `docs-base.css` when empty; update `<link>` tags across all docs pages. The populator's anchor-file enforcement check (drift codes `DUPLICATE_FOUNDATION`, `DUPLICATE_CHROME`) will need to learn about the second anchor file — small change, lands alongside the first docs CSS file refactor when we get there.
7. **Per-file refactor for the seven docs CSS files** — joins the same queue as the unrefactored CC files. Same six-category treatment per file (banner conversion, prefix declarations, descendant-combinator resolutions, group selector splits, hex-to-token swaps, etc.). Note: `FORBIDDEN_DESCENDANT` resolutions require coordinated HTML updates across docs pages (`index.html`, `engine-room.html`, `teams.html`, `arch/*.html`, `cc/*.html`, `ref/*.html`); these fall under the same per-file refactor scope. `docs-erd.css` additionally requires a `ddl-erd.js` change to emit a single combined `.is-pk-fk` class (replacing the depth-3 compound `.erd-table-col.is-pk.is-fk`).
8. Page-at-a-time migration for the remaining ~22 CC pages.

**Open Schema Items (DDL changes implied by the HTML spec):**

These schema changes are required for the production HTML populator to function as specified. They are tracked here as next-step items rather than open decisions because the design has been settled; the work is implementation, not deliberation.

1. `dbo.Asset_Registry.has_dynamic_content BIT NULL` — flag column for partial extraction. Set TRUE on rows where the parent attribute or text construct contains additional runtime-only content the populator cannot statically resolve. NULL-allowed because the column applies to HTML and JS populator rows (parent constructs that may have dynamic composition); CSS rows (which are always literal) leave it NULL.
2. `Orchestrator.ProcessRegistry.cc_engine_slug VARCHAR(20) NULL` — engine card slug for processes that drive engine cards. NULL for non-engine-card processes (queue processors, daily summaries that aren't displayed as cards, inactive processes).
3. `Orchestrator.ProcessRegistry.cc_engine_label VARCHAR(50) NULL` — display label text for the engine card.
4. `Orchestrator.ProcessRegistry.cc_page_route VARCHAR(100) NULL` — page route on which the process appears as an engine card.
5. `Orchestrator.ProcessRegistry.cc_sort_order INT NULL` — display order of the card within the page's engine row.

The four cc-prefixed columns on ProcessRegistry are populated for active scheduled processes (`run_mode = 1`) only; queue processors (`run_mode = 2`) and inactive processes (`run_mode = 0`) leave them NULL. The HTML spec validates this discipline via drift codes `MISSING_ENGINE_CARD_REGISTRATION` (active process missing card data) and `UNEXPECTED_ENGINE_CARD_REGISTRATION` (queue processor with card data). The four columns also enable a future Level 3 transition to fully registry-driven engine cards (helper-emitted card markup driven by the registry, dropping `ENGINE_PROCESSES` JS declarations) without further DDL changes.

**Open Items / Decisions Needed:**

1. **JS spec update — cross-spec rules surfaced during HTML spec drafting.** The JS spec needs new rules and drift codes to validate JS-side references against the HTML spec's new structures. Specifically:
   - ID string validation in `getElementById` and similar calls. ID strings must conform to the chrome ID set (`CC_HTML_Spec.md` §4.1) or the page-local format `<prefix>-<purpose>` (§4.2). Drift codes: `JS_HTML_ID_UNRESOLVED` (USAGE row resolves to `<undefined>` in the catalog because no HTML defines that ID), `JS_HTML_ID_MALFORMED` (ID string format doesn't match chrome or page-local conventions).
   - `data-*` attribute resolution. JS that reads `data-*` attributes via `element.dataset.foo` or `element.getAttribute('data-foo')` produces USAGE rows that must resolve against HTML DEFINITION rows. Drift code: `JS_DATA_ATTRIBUTE_UNRESOLVED`. Populator must normalize between camelCase JS form and kebab-case HTML form.
   - `has_dynamic_content` flag application to JS-side CSS_CLASS USAGE rows from template literals (Group A). Same rules as HTML populator; flag set TRUE when class composition involves runtime data not statically resolvable.
   - `ENGINE_PROCESSES` validation against `Orchestrator.ProcessRegistry`. Every entry's slug must match `cc_engine_slug`; every entry must reference a process whose `cc_page_route` matches the page's route; every active scheduled process registered for the page must appear in the page's `ENGINE_PROCESSES`. Drift codes: `MISSING_ENGINE_PROCESSES_DECLARATION`, `ENGINE_PROCESS_PAGE_MISMATCH`, `ENGINE_SLUG_JS_MISMATCH`, `MISSING_ENGINE_CARD_FOR_REGISTERED_PROCESS`.

   These updates land after the HTML populator has run once and produced the cross-population resolution data needed to validate the rules work as intended. Per-page refactor work follows.

2. **`Refresh-AssetRegistry.ps1` orchestrator pattern.** On-demand execution from Admin page (matching documentation pipeline trigger pattern), no scheduling. Sequential CSS → HTML → JS → PS execution under `sp_getapplock` single-instance protection. Orchestrator landing can happen any time after all populators are current; not a blocker for migration work. Detailed design in `CC_Catalog_Pipeline_Working_Doc.md`.

3. **CSS and JS spec rationale cleanup pass.** The HTML spec applies a stricter format principle than CSS and JS achieve today: rules-only-in-body, all rationale in Appendix. CSS and JS specs have inline rationale in some sections that should be moved to their respective appendices for cross-spec consistency. Not blocking; cleanup pass when convenient.

**Blocked on:** nothing.

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

## Conversion tracking model

Files exist in one of three states during the initiative:

- **Pre-spec** — file has not been refactored against any current spec. Drift codes in the catalog reflect the file's pre-refactor state.
- **Partially compliant** — file has been refactored against one or more file-type specs but not all. The page works but the catalog reflects mixed compliance.
- **Fully compliant** — file has been refactored against every applicable spec and parses at zero drift across all of them.

The current direction (page-at-a-time migration after JS, HTML, and PS specs land) means each page transitions directly from pre-spec to fully compliant within a single coordinated session, eliminating the partially-compliant state for those pages.

---

## HTML spec evolution

This section tracks the evolution of `CC_HTML_Spec.md` since the initiative began. Each entry summarizes what changed in the spec and why, in chronological order.

### 2026-05-10 — Initial draft

Defined the complete HTML markup specification across 17 numbered sections plus an Appendix, totaling 88 drift codes. Mirrors the rhythm of the CSS and JS specs (numbered rule sections, drift codes inline, summary/forbidden-patterns/catalog-model meta-sections, compliance queries, examples).

The structural pattern of body sections: §1 (page shell required structure), §2 (page chrome — header bar, refresh info, engine cards, connection banner placeholder), §3 (asset references — exactly two CSS files and two JS files in mandated forms with mandated order), §4 (ID conventions — chrome ID closed set, page-local prefix discipline, slideout/modal/panel ID conventions, purpose comments mandated for slideouts/modals/panels), §5 (class attribute conventions including the array-join pattern as the one mandated dynamic class assembly form), §6 (event handler conventions — exactly one function call per handler, no inline expressions, no revealing-module calls), §7 (data-* attribute conventions), §8 (text content with categorical naming derivation for cross-page comparison), §9 (inline SVG treated as opaque markup at the catalog level), §10 (HTML comments).

Meta-sections aggregate from the rule sections: §11 required patterns summary, §12 forbidden patterns table, §13 catalog model, §14 what the parser extracts, §15 drift codes reference, §16 compliance queries, §17 examples, Appendix rationale.

The HTML spec is the first to apply rules-only-in-body / rationale-in-appendix completely. The CSS and JS specs have inline rationale in some sections that future cleanup passes will move to their respective appendices for cross-spec consistency.

Significant cross-cutting decisions:

- **Pipeline order revised to CSS → HTML → JS → PS.** HTML moves earlier in the pipeline (was previously last among CSS/HTML/JS) because JS USAGE rows for IDs and data-attributes need to resolve against HTML DEFINITION rows. The relationship: CSS is the grandparent (no upstream dependencies); HTML is the parent (depends on CSS for class scope resolution); JS is both child and grandchild (depends on CSS for class scope and on HTML for ID and data-attribute resolution); PS runs last and enriches HTML rows with route paths via the `parent_object` column. Standalone-reload of any populator out of pipeline order falls back to `<undefined>` for unresolved cross-populator references.

- **On-demand execution from Admin page.** No orchestrator scheduling; the pipeline runs interactively from an Admin button matching the documentation pipeline pattern. Catalog refreshes are user-initiated.

- **Engine cards sourced from `Orchestrator.ProcessRegistry` via four new cc-prefixed columns** (`cc_engine_slug`, `cc_engine_label`, `cc_page_route`, `cc_sort_order`). Active scheduled processes (`run_mode = 1`) require all four populated; queue processors (`run_mode = 2`) require all four NULL; inactive processes (`run_mode = 0`) are unvalidated. The four-column model also supports a future Level 3 transition to fully registry-driven engine cards (helper-emitted card markup driven by the registry, dropping `ENGINE_PROCESSES` JS declarations) without further DDL changes — only code refactor.

- **`has_dynamic_content` flag column added to `dbo.Asset_Registry`** as a BIT NULL column. Set TRUE on HTML and JS populator rows where the parent attribute or text construct contains additional runtime-only content the populator cannot statically resolve. Lets queries distinguish between fully-captured class compositions and partially-captured ones where additional runtime classes may be applied.

- **One mandated dynamic class assembly pattern (array-join).** The PowerShell array-join idiom — initialize array with base class, conditionally append modifiers, join with single space, substitute single resolved variable into attribute — is the only legitimate way to construct a dynamic class string. All other forms of dynamic class composition are forbidden, with four granular drift codes (`INLINE_CLASS_CONCATENATION`, `INLINE_CLASS_PREFIX_MIX`, `INLINE_CLASS_MULTI_INTERPOLATION`, `INLINE_CLASS_BRACED_INTERPOLATION`) covering specific syntactic violations.

- **Categorical naming for `HTML_TEXT` rows.** `component_name` for text rows holds a derived categorical identifier (e.g., `h2-section-title`, `attr-title`, `button-page-refresh-btn`) rather than the literal text. Actual text content lives in `raw_text`. The page prefix is stripped from leading class tokens during derivation so categories are comparable across pages (`<h2 class="bsv-section-title">` and `<h2 class="bch-section-title">` both produce `component_name = h2-section-title`). This makes cross-page consistency comparison queries indexable via `component_name` rather than requiring text scans.

- **Slideout/modal/panel ID role-first ordering.** ID conventions follow `<prefix>-slideout-<purpose>-overlay`, `<prefix>-modal-<purpose>-overlay`, and `<prefix>-slideup-<purpose>-backdrop` form (role between prefix and purpose) rather than purpose-first. Optimizes for "all slideouts on this page" queries (`LIKE 'bsv-slideout-%'` returns every slideout) over "everything related to this purpose" queries.

- **Mandated HTML purpose comments for slideouts, modals, and slide-up panels.** Comment immediately preceding the overlay/backdrop is read into `purpose_description` for both rows of the construct. Drift code `MISSING_PANEL_PURPOSE_COMMENT` fires on missing comments. Other constructs (page-local IDs, form fields) don't require purpose comments — only the structural constructs that vary in messaging across pages.

- **Three forms of HTML entity references catalogued separately.** Named entities (`&times;`), numeric entities (`&#9881;`), and direct Unicode characters (`⚙`) each produce their own `HTML_ENTITY` row when found. Future Phase 3 may mandate one form (likely numeric for typographic safety); the catalog tracks all three until then so cross-form consistency analysis informs the decision.

- **Helper functions are page-agnostic.** Helpers may emit chrome IDs and chrome function calls, but never page-prefixed IDs, page-prefixed function calls, or page-specific `data-*` attributes. Drift codes `FORBIDDEN_HELPER_PAGE_PREFIX_ID`, `FORBIDDEN_HELPER_PAGE_FUNCTION_CALL`, `FORBIDDEN_HELPER_PAGE_DATA_ATTRIBUTE` enforce this.

- **Access-denied page (`Get-AccessDeniedHtml`) carve-out.** The 403 page does not conform to the standard page shell because it renders before authenticated resources are reachable. It is permitted to use inline `<style>`, omit external asset references, and skip page-shell substitutions. All other spec rules apply normally.

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

The legacy `MALFORMED_SECTION_BANNER` drift code was retired and replaced with seven granular codes in §18.2: `BANNER_INLINE_SHAPE`, `BANNER_INVALID_RULE_CHAR`, `BANNER_INVALID_RULE_LENGTH`, `BANNER_INVALID_SEPARATOR_CHAR`, `BANNER_INVALID_SEPARATOR_LENGTH`, `BANNER_MALFORMED_TITLE_LINE`, `BANNER_MISSING_DESCRIPTION`. Each code describes exactly one violation, allowing precise refactor triage. A non-conformant banner may carry several granular codes simultaneously when it violates multiple rules. Same set of granular codes adopted in the CSS spec.

§14 was extended with a new entry for the revealing-module IIFE pattern (`const X = (function(){...})()` and var equivalent) and the new drift code `FORBIDDEN_REVEALING_MODULE`. A new §14.2 was added grouping both forbidden top-level wrapper patterns (top-level IIFE per the existing §14, plus the new revealing-module pattern) and explaining their treatment: the wrapper row carries the drift; inner USAGE rows continue to flow so the cross-reference catalog stays complete; inner DEFINITION rows are suppressed because those identifiers have no independent identity in the spec'd version. The populator implements this via a definition-suppression flag. Migration of either pattern requires a file rewrite, not in-place repair.

§5.4 added a new bullet introducing the `PREFIX_MISSING` drift code: top-level identifiers themselves (function names, constants, state vars, classes, revealing-module wrappers) must begin with the file's registered `cc_prefix` followed by an underscore, independently of banners. Hooks (whose names are spec-fixed) and methods inside classes (which are namespaced by their class) are exempt. This closes the gap where pre-spec files with no banners yet were silently exempt from prefix scrutiny; the rule now applies to every top-level identifier regardless of whether the file's banners are in place.

§16.2 was updated to reflect that `JS_CONSTANT_VARIANT` and `JS_STATE` can host `FORBIDDEN_REVEALING_MODULE` drift on revealing-module wrappers. §17 added a paragraph describing the suppression behavior for inner definitions inside forbidden wrappers. §18.4 added the `FORBIDDEN_REVEALING_MODULE` drift code entry. §18.3 added the `PREFIX_MISSING` drift code entry. §8.4 was updated to note that hooks are exempt from `PREFIX_MISSING` as well as `PREFIX_MISMATCH`.

A misplaced pair of rows in §14 (carrying `MALFORMED_PREFIX_VALUE` and `PREFIX_REGISTRY_MISMATCH`, which are banner-level codes that belong only in §18.2) was corrected: those rows were removed from §14, leaving the codes in §18.2 alone. Editorial cleanup, not a rule change.

Appendix entries A.3 (banners), A.4 (anchor file analog), A.5 (PREFIX_MISSING rationale), and A.14 (revealing-module rationale) were added or updated to match.

### 2026-05-08 — First Phase 1 page refactors surface spec gaps; engine processes contract banner; inline event handlers; spec hygiene preamble

The first two Phase 1 page JS refactors (`client-relations.js` and `business-services.js`) drove a cluster of related amendments. The work followed a "spec describes what we want; files conform to spec, not vice versa" principle — every gap surfaced by an actual refactor was closed in the spec rather than worked around in the file.

A spec hygiene principle was added to the spec preamble: specs describe rules and shapes, never present contents. Statements about how many files currently do something, which files are empty today, or what the codebase looks like right now do not belong in the spec; they age into inaccuracy the moment the codebase changes. This principle propagates to the other CC specs as they're touched.

§7.4 introduces the fixed-form `CONSTANTS: ENGINE PROCESSES` banner with `Prefix: (none)`. The `ENGINE_PROCESSES` constant is a name contract with `cc-shared.js` — read by exact name from the page's global scope, not subject to page-prefix scoping. Pages that call `connectEngineEvents()` must declare the banner, even when the value is `{}`. The banner precedes any page-prefixed `CONSTANTS` banner. This mirrors §8's hooks pattern: contract surfaces between page files and `cc-shared.js` get structural visibility via dedicated banners, not name-based prefix exemptions inside otherwise-prefixed sections. §5.2 was extended with the corresponding `Prefix: (none)` carve-out entry. Investigation of the page-file gang of five confirmed `ENGINE_PROCESSES` is the only platform-defined contract identifier — the hooks contract covers the function side; this banner covers the data side.

§7.2 distinguished SCREAMING_SNAKE_CASE casing rules: primitives (numbers, strings, booleans) use SSC; objects, arrays, and computed values use camelCase. The previous wording included "preferred" weasel language; the rule is now categorical based on value kind. Intent matches what the existing spec-compliant files were already doing, made explicit.

§10 clarified the empty IMPORTS section rule: when a file has no imports, the IMPORTS banner is omitted entirely along with the FILE ORGANIZATION entry. Previous wording was ambiguous about whether the banner should remain as a placeholder; the corrected rule keeps the file structure honest about what the section actually contains.

§14, §16.2, §17, and §18.4 added `FORBIDDEN_INLINE_EVENT_IN_JS` drift covering inline `on<event>="..."` attribute strings inside template literals or string literals. This pattern was previously uncovered — the spec covered direct property assignment (`el.onclick = handler`) and inline `<script>`/`<style>` in template literals, but inline event attributes fell through the gap. Surfaced when `business-services.js` came back at zero drift on first refactor despite containing nine inline `onclick="..."` handlers; the populator wasn't checking for them. Spec amended; populator patched (see Pipeline doc); 281 inline-event rows surfaced across the unrefactored codebase, plus 9 in `business-services.js` and 0 in `client-relations.js`. The architectural rationale for migrating these to `addEventListener` is independent of the spec change: CSP hardening, catalog discoverability (so `JS_EVENT` rows appear instead of opaque drift), and refactor safety (JS-source search reliably finds bindings; template-string search is brittle).

### 2026-05-09 — Event handler binding section (§12); per-element listener loop pattern forbidden

The remaining three Phase 1 page JS refactors (`backup.js`, `replication-monitoring.js`, `business-intelligence.js`) drove the next round of spec amendments. The dominant pattern surfaced across these files was per-element listener attachment via `forEach + addEventListener` — code that walks a node list and calls `addEventListener` on each element. This is functionally equivalent to per-element inline event handlers (one listener per DOM element) but written as JavaScript rather than HTML attributes, so the existing `FORBIDDEN_INLINE_EVENT_IN_JS` rule did not catch it. The refactor authoring discipline had been consistent — delegate at a stable parent and dispatch by `event.target` — but the spec did not name event handler binding as a topic in its own right.

§12 (Event handler binding) introduces this topic explicitly. The opening establishes that handlers are attached via `addEventListener` and that the canonical form is event delegation. §12.1 (Delegation pattern) names the three structural pieces: a stable parent element that exists in INITIALIZATION (or is captured at boot), exactly one `addEventListener` call on that parent, and a handler that dispatches by `event.target.matches` / `closest` plus `data-*` attributes carried on the rendered children. §12.2 (Permitted direct-binding cases) names the only two cases where binding directly to a specific element is allowed: singleton elements bound at page boot (modals, overlays, page-level containers that exist for the lifetime of the page after injection), and window-level or document-level events (visibility change, beforeunload, document keydown for keyboard shortcuts). A form-input carve-out was considered and rejected: per-input listeners are still per-element listeners, and form input changes can be delegated on the form itself.

Sections §13 onward were renumbered to accommodate. §15 (Forbidden patterns) adds `FORBIDDEN_PER_ELEMENT_LISTENER_LOOP` to its table; §19.4 (Drift codes reference) carries the same code with its description. The JS populator was patched the same session to detect the new code: a `Test-IsInsideElementLoop` helper walks the parent-node chain looking for an enclosing `forEach` (or sibling `map`/`filter`/`find`/`some`/`every`) callback or a `for...of` / `for...in` / `for` loop body, stopping at any nested `FunctionDeclaration` so inner functions don't false-positive; when the check fires inside the existing `addEventListener` block in the visitor's `CallExpression` case, the drift code attaches to the same `JS_EVENT` USAGE row that fires for the listener — no separate row, no new emitter. Spec and populator are aligned on every drift code. Book closed on JS for now.

The architectural rationale: per-element listener loops fail on dynamically-injected content (any element added after the loop runs has no listener), accumulate listener leaks on re-render (each fresh loop adds new listeners without removing the old ones unless the rendering also explicitly removes them), and obscure handler ownership (the handler reference is anonymous inside the loop, so debugging tools can't show which listener fires when). Delegation has none of these problems and produces one listener row in the catalog instead of N.

---

## CSS spec evolution

This section tracks the evolution of `CC_CSS_Spec.md` since the initiative began. Each entry summarizes what changed in the spec and why, in chronological order.

### 2026-05-04 — Initial release

Defined the section-type taxonomy (`FOUNDATION`, `CHROME`, `LAYOUT`, `CONTENT`, `OVERRIDES`, `FEEDBACK_OVERLAYS`) with FOUNDATION and CHROME limited to `cc-shared.css`. Established the 3-character page-prefix discipline for class names, with the `Prefixes:` line in every section banner. Mandated a single-line purpose comment preceding every base class and a trailing inline comment on every variant. Forbade CHANGELOG blocks in file headers. Defined the variant model (class, pseudo, compound_pseudo) with `variant_qualifier_1` and `variant_qualifier_2` columns capturing the variant shape. Forbade descendant combinators and depth-3+ compounds, establishing the state-on-element pattern as the canonical alternative. Centralized custom property tokens in FOUNDATION with the `--<category>-<role>-<modifier>` naming convention and a closed category enum. Defined eight CSS-relevant component types and a drift code reference covering ~30 codes.

### 2026-05-06 — Editorial restructure

Spec restructured to operating-manual style, matching the JS spec's pattern. Body sections now contain rules only, with rationale moved to a dedicated Appendix at the end. All inline code examples consolidated into a single Examples section. The forbidden-patterns table's Rationale column was dropped from the body and consolidated into the Appendix. Status, Owner, and cross-document references removed from the preamble. The previous one-line revision history was migrated to this Initiative document and removed from the spec itself. No rule changes.

### 2026-05-06 — Prefix singularization and registry validation

The plural `Prefixes:` field name was retired in favor of singular `Prefix:`, matching the JS spec's existing convention. The plural form had encouraged misuse: section banners in `cc-shared.css` had accumulated comma-separated lists of section-grouping commentary words (`nav`, `page, header`, `engine`, etc.) that were not valid page prefixes at all. The singular form makes the field's meaning unambiguous — exactly one page prefix, or `(none)`. Three associated changes: drift code `MISSING_PREFIXES_DECLARATION` was renamed to `MISSING_PREFIX_DECLARATION`; new drift code `MALFORMED_PREFIX_VALUE` covers banners declaring anything other than a single 3-char prefix or `(none)`; new Section 5.3 documents the single-prefix-per-banner rule. Section 5.4 was added to formalize registry validation: each banner's declared prefix is cross-referenced against `Component_Registry.cc_prefix` for the file's component, with `PREFIX_REGISTRY_MISMATCH` drift on disagreement. CSS validation is strict (no per-section `(none)` carve-outs — CSS has no analog to JS's hooks/IMPORTS/INITIALIZATION sections that legitimately declare `(none)` on a page file). Populator enforcement is queued for the alignment refactor.

### 2026-05-07 — Anchor file generalization

The FOUNDATION and CHROME single-file rule (§4.3) was generalized from "lives in `cc-shared.css`" to "lives in the component's anchor file." The platform now recognizes multiple anchor files — one per component-scope domain. CC application files anchor on `cc-shared.css`; docs site files anchor on `docs-shared.css` (planned; currently `docs-base.css` pending the migration described in Initiative Queued Work). The single-source-of-truth principle is preserved per-component: there is exactly one place for a component's tokens, keyframes, and chrome to live. The same generalization was applied to §11 (`@keyframes`) and §10 (custom property tokens). Drift codes `FORBIDDEN_KEYFRAMES_LOCATION` and `FORBIDDEN_CUSTOM_PROPERTY_LOCATION` now check anchor-file membership rather than literal cc-shared.css membership. `DUPLICATE_FOUNDATION` and `DUPLICATE_CHROME` similarly fire when those sections appear in any non-anchor file.

This amendment unblocks the docs site CSS files joining the same spec rather than requiring a separate `Docs_CSS_Spec.md`. The single-spec model is preserved; the rule is "one structure across the codebase" with the anchor-file scope being explicit about which files own foundational content for each domain.

### 2026-05-07 — Banner format tightening and granular drift codes

§3.1 was tightened to specify exactly 76 characters for both the `=` opening/closing rule lines and the `-` middle separator (previously "any length 5 or more" / "any length"). The fixed length matches what refactored files already use, fits within an 80-column convention with margin for `/* ` and ` */` comment delimiters, and aligns with the granular drift codes the populator enforces.

The legacy `MALFORMED_SECTION_BANNER` drift code was retired and replaced with seven granular codes in §16.2: `BANNER_INLINE_SHAPE`, `BANNER_INVALID_RULE_CHAR`, `BANNER_INVALID_RULE_LENGTH`, `BANNER_INVALID_SEPARATOR_CHAR`, `BANNER_INVALID_SEPARATOR_LENGTH`, `BANNER_MALFORMED_TITLE_LINE`, `BANNER_MISSING_DESCRIPTION`. Each code describes exactly one violation, allowing precise refactor triage. A non-conformant banner may carry several granular codes simultaneously when it violates multiple rules.

A new §3.2 (Banner detection and validation) was added documenting the permissive-admission/strict-validation pattern: any block comment that is banner-shaped produces a `COMMENT_BANNER` row regardless of conformance, and the drift codes carry the conformance verdict. This codifies a design principle that always existed informally but had drifted into a stricter regex-only admission model in the populator. The populator was refactored to match: `Test-IsBannerComment` (permissive) admits any banner-shaped comment; `Get-BannerInfo` (strict) emits granular drift on any §3.1 violation. Output: 33 additional banner rows now correctly captured from pre-spec files whose dash-bracketed banners the old detector had missed.

---

## Initiative decision history

A compressed record of cross-cutting decisions made across sessions. One or two lines per entry. Not a session log; not a revision history of this document. Decisions only.

- **2026-04-30** — Initiative scope and motivation defined. Goal: machine-parseable file formats per source-file type, with `dbo.Asset_Registry` as the queryable source of truth for the CC codebase.
- **2026-05-01** — Parser stack settled on Node + acorn (JS) and Node + PostCSS (CSS) after .NET-based approaches failed dependency-resolution tests on PS 5.1.
- **2026-05-02** — Refresh strategy: TRUNCATE plus reload per file_type, not MERGE upsert. The catalog represents current state only; historical rows would require filtering on every query.
- **2026-05-03** — Schema migration: dropped `state_modifier`, `component_subtype`, `parent_object`, `first_parsed_dttm` from `Asset_Registry`.
- **2026-05-04** — Doc reorganization: retired `CC_FileFormat_Standardization.md` and related legacy docs. Created this Initiative doc as the navigation hub. Created stub spec docs for each file type (`CC_CSS_Spec.md` finalized first; JS, HTML, PS routes, PS modules stubbed).
- **2026-05-04** — `Asset_Registry` schema cleanup: dropped `related_asset_id`, `design_notes`, `is_active`. CSS populator wired purpose_description capture across all four CSS comment sources (file header, section banner, per-class, per-variant) reaching 100% coverage on Phase 1 reference files.
- **2026-05-04** — Phase 1 CSS refactor work complete. cc-shared.css plus the five Phase 1 page CSS files all at zero drift.
- **2026-05-05** — JS variant model defined. Three component types (`JS_FUNCTION`, `JS_CONSTANT`, `JS_METHOD`) gained `_VARIANT` siblings; three (`JS_IMPORT`, `JS_TIMER`, `JS_EVENT`) kept single names with always-non-NULL variant_type.
- **2026-05-05** — JS populator change pass implemented. cc-shared.js created and validated against `CC_JS_Spec.md`, reaching zero file-attributable drift.
- **2026-05-05** — Initiative direction shift adopted. Bring all four populators current first, then sweep Phase 1 across all file types together, then page-at-a-time migration for the remaining ~22 pages.
- **2026-05-06** — Specs restructured to operating-manual style with rationale appendices and consolidated examples. Three-homes content model adopted: rules in spec body, rationale in spec appendix, decision history in working docs (Initiative doc for project-level decisions, Pipeline doc for populator-implementation events).
- **2026-05-06** — Cross-reference rule established. Permanent docs (specs, Development Guidelines) reference no other docs and stay self-contained. Working docs (Initiative, Pipeline, planning trackers) may reference companions; references are at the doc level or named-section level, never section numbers.
- **2026-05-06** — Specs no longer carry versioning, status, or owner. A spec is settled until amended; amendments are recorded in this doc's Spec Evolution sections.
- **2026-05-06** — PowerShell script CHANGELOG entries going forward will be one-line summaries, not narrative paragraphs. Implementation events that need narrative context land in this doc or the Pipeline doc.
- **2026-05-06** — Decided to migrate the Prefix Registry from this doc to a `cc_prefix CHAR(3) NULL` column on `Component_Registry`. Once the column exists, populators read it at startup and validate file-header-declared prefixes against it.
- **2026-05-06** — Prefix Registry migration completed. `Component_Registry.cc_prefix` column added with filtered unique index and case-sensitive CHECK constraint. 19 page-component prefixes backfilled. The doc-based Prefix Registry section in this document was retired in favor of the database-resident registry.
- **2026-05-06** — Prefix declaration form standardized to singular `Prefix:` across both CSS and JS specs. The plural `Prefixes:` form had encouraged misuse in CSS (section-grouping commentary words leaking into the prefix declaration); the singular form removes that ambiguity. Each banner declares exactly one 3-character prefix or `(none)`. Two new drift codes, `MALFORMED_PREFIX_VALUE` and `PREFIX_REGISTRY_MISMATCH`, formalize banner-level validation against the registry. Populator enforcement queued.
- **2026-05-06** — Pivoted from a small five-change populator pass to a coordinated alignment refactor after re-reading the populators with fresh eyes revealed substantial divergence between CSS and JS in walking model, banner-detection helpers, drift-attachment models, and section-tracking. Doing the registry validation work in two divergent codebases would require writing the same logic twice in two idioms, then refactoring both during a future alignment pass. Decision: fold the registry validation into the alignment pass, touch each populator once.
- **2026-05-06** — Alignment design decisions locked. Visitor pattern for both populators (parameterized via `Invoke-AstWalk` with parent chain and parent nodes; SKIP_CHILDREN signal for structural skips). Pre-built section list with body-line ranges (replaces CSS's running-state model). Hybrid drift attachment (master-table validation plus optional row-specific context string). File-header parsing separates parse from emit. FILE_ORG_MISMATCH check happens per-file in Pass 2, not cross-file Pass 3. Closed enums get catch-all `UNKNOWN_*` codes for unknown values; output-boundary check catches drift codes not in the master list; explicit detection for spec-defined rules.
- **2026-05-06** — Strict registry validation (Option B) chosen over permissive (Option A). For CSS, every banner must declare the file's `cc_prefix` (no `(none)` carve-outs — CSS has no per-section legitimacy of `(none)` on page files). For JS, every banner must declare the file's `cc_prefix` except the hooks banner, IMPORTS section, and INITIALIZATION section per `CC_JS_Spec.md` §5.2, which legitimately declare `(none)`. Closes the loophole that a permissive reading would leave open.
- **2026-05-06** — Shared infrastructure architecture decided. New `xFACts-AssetRegistryFunctions.ps1` created as a domain-specific helpers file parallel to `xFACts-IndexFunctions.ps1`. Each populator dot-sources `xFACts-OrchestratorFunctions.ps1` and `xFACts-AssetRegistryFunctions.ps1` explicitly (matching the established two-line pattern from the index family). Helpers file does not internally dot-source OrchestratorFunctions; the calling script does. Function naming inside helpers file is mixed: `Verb-AssetRegistryThing` for domain-scoped functions whose bare names would be ambiguous, bare `Verb-Thing` for genuinely generic utilities.
- **2026-05-06** — End-of-run verification queries removed from both populators. The query blocks at the end of each populator (3 queries in CSS, 8 in JS) were development conveniences for inspecting catalog content alongside summary output during console runs. Catalog inspection moves to SSMS going forward.
- **2026-05-06** — Asset_Registry column descriptions populated in `dbo.Object_Metadata`. 24 description rows, one per column. Descriptions are intentionally brief (a handful of words to one sentence) and populator-agnostic — no references to specific populators, no value enumerations, no per-language branching. Specifics live in the per-file-type spec docs and in per-populator enrichment rows. Two populators (`Populate-AssetRegistry-CSS.ps1`, `Populate-AssetRegistry-JS.ps1`) and the helpers file (`xFACts-AssetRegistryFunctions.ps1`) registered in `dbo.Object_Registry` under `Tools.Utilities`. Populators got base metadata rows only since they're about to be substantively refactored; helpers file got base rows plus data_flow and two design_note rows since it's in final form. Full enrichment for the populator family deferred to the backlog.
- **2026-05-07** — Banner detection refactored to permissive-admission / strict-validation. The CSS populator's banner detection was split into two passes: `Test-IsBannerComment` (permissive) admits any banner-shaped comment, and `Get-BannerInfo` (strict) validates against §3.1 and emits granular drift codes per violation. This corrects an earlier drift toward "no row for non-conforming banners" — every detected banner candidate now produces a catalog row with appropriate drift, never silent omission. The pattern generalizes across the populator family for any construct with a defined shape. Output: catalog row count rose 7,584 → 7,617, with 33 dash-bracketed banners now correctly captured.
- **2026-05-07** — Granular banner drift codes adopted. The legacy `MALFORMED_SECTION_BANNER` was retired in favor of seven granular codes (`BANNER_INLINE_SHAPE`, `BANNER_INVALID_RULE_CHAR`, `BANNER_INVALID_RULE_LENGTH`, `BANNER_INVALID_SEPARATOR_CHAR`, `BANNER_INVALID_SEPARATOR_LENGTH`, `BANNER_MALFORMED_TITLE_LINE`, `BANNER_MISSING_DESCRIPTION`). Each describes exactly one violation, enabling precise refactor triage. `CC_CSS_Spec.md` §3.1 was simultaneously tightened to "exactly 76 characters" for both `=` rule lines and `-` separator, matching what the populator enforces and what refactored files already use.
- **2026-05-07** — Anchor-file generalization adopted; single-spec model preserved across CC application and docs site. The FOUNDATION/CHROME single-file rule was generalized from "lives in `cc-shared.css`" to "lives in the component's anchor file." Each component anchors on one file; CC components anchor on `cc-shared.css`, `Documentation.Site` anchors on `docs-shared.css` (planned, currently `docs-base.css`). The single-spec model is preserved — `CC_CSS_Spec.md` governs both the CC application and the docs site CSS — with the anchor-file scope being the only generalization needed. A separate `Docs_CSS_Spec.md` was considered and rejected as violating the "one structure across the codebase" principle. Single-source-of-truth is preserved per-component.
- **2026-05-07** — Docs site CSS refactor brought into initiative scope. The seven `docs-*.css` files (1,055 catalog rows, 627 with drift) join the per-file refactor queue alongside unrefactored CC files. Drift profile is comparable to unrefactored CC files; resolutions are the same. A `docs-base.css` → `docs-shared.css` migration mirroring the `engine-events.css` → `cc-shared.css` migration is queued as the first step. HTML coordination work for descendant-combinator resolutions across docs pages is part of the per-file refactor scope. `ddl-erd.js` requires a small change to emit a combined `.is-pk-fk` class. Position in queue: after Phase 1 CC pages complete and the four populators are aligned.
- **2026-05-07** — JS populator alignment refactor delivered. Same shape as the CSS work (helpers consumption, visitor pattern, pre-built section list, prefix registry validation, permissive-admission/strict-validation banner detection). Cross-spec consistency is now visible at the populator level: both populators share the helpers file, walk via `Invoke-AstWalk`, and emit drift codes through the same hybrid model.
- **2026-05-07** — `FORBIDDEN_REVEALING_MODULE` drift code adopted in the JS spec. Detects the revealing-module IIFE pattern (`const X = (function(){...})()` and var equivalent) at the AST level. Six files identified by the first production run: admin.js, bdl-import.js, applications-integration.js, client-portal.js, business-intelligence.js, platform-monitoring.js. The platform-monitoring.js finding was new — the file had not previously been classified as a revealing-module file. All six require full rewrite rather than in-place repair; their inner functions live inside a wrapper namespace with no equivalent in the spec'd top-level-function model. business-intelligence.js is in the Phase 1 set; the other five are queued for the per-page migration phase.
- **2026-05-07** — `PREFIX_MISSING` drift code adopted in the JS spec. Fires on top-level definitions when the file has a registered `cc_prefix` in Component_Registry but the identifier name doesn't begin with that prefix + underscore. Independent of banners; closes the gap where pre-spec files (no banners yet) were silently exempt from prefix scrutiny. Hooks and methods inside classes are exempt. The rule is documented in CC_JS_Spec.md §5.4 final bullet.
- **2026-05-07** — Definition-suppression flag mechanism adopted for forbidden top-level wrapper handling in the JS populator. Replaces an earlier SKIP_CHILDREN approach that suppressed everything inside the wrapper. The new mechanism allows USAGE rows to flow from inside the wrapper body so the cross-reference catalog stays complete; only DEFINITION rows are suppressed. The drift on the wrapper row still tells the operator the file requires rewrite; the inner USAGE rows tell the operator what other files will be affected by that rewrite. The two mechanisms (SKIP_CHILDREN, suppression flag) coexist in the populator family for different use cases.
- **2026-05-07** — Cross-spec consistency principle made explicit. Where rules can be the same across CSS, JS, HTML, and PS, they are the same. This applies to banner format (76-character rule lines, 76-character separator), banner drift codes (the seven granular `BANNER_*` codes), permissive-admission/strict-validation pattern, and the prefix discipline. Per-spec divergence exists only where the underlying language genuinely differs (e.g., section TYPE values differ between CSS and JS because the languages have different structural concerns). HTML and PS specs, when designed, will inherit the same cross-spec elements rather than redefining them.
- **2026-05-08** — Spec hygiene principle adopted. Specs describe rules and shapes, never present contents. Statements about how many files currently do something, which files are empty today, or what the codebase looks like right now do not belong in the spec; they age into inaccuracy the moment the codebase changes. Added to the JS spec preamble; propagates to other CC specs as they're touched.
- **2026-05-08** — `CONSTANTS: ENGINE PROCESSES` banner adopted in JS spec §7.4. Fixed-form banner with `Prefix: (none)` that hosts the `ENGINE_PROCESSES` page-to-platform contract identifier. Mirrors the §8 hooks pattern: contract surfaces between page files and `cc-shared.js` get their own structurally visible banner with `(none)` prefix, rather than being treated as name-based prefix exemptions inside otherwise-prefixed sections. Investigation of the page-file gang of five confirmed `ENGINE_PROCESSES` is the only platform-defined contract identifier on the data side (the hooks contract handles the function side).
- **2026-05-08** — `FORBIDDEN_INLINE_EVENT_IN_JS` drift code adopted in JS spec. Surfaced when the first non-trivial Phase 1 page refactor (`business-services.js`) returned at structural zero drift despite containing nine inline `onclick="..."` attribute strings inside template literals — the spec had no rule for that pattern, so the populator's clean check was misleading. Spec amended (§14, §16.2, §17, §18.4) and populator patched. 281 inline-event rows surfaced across the unrefactored codebase plus 9 in business-services.js. The cleanup work is per-file: when each Phase 1 page is refactored, its inline event handlers are migrated to `addEventListener` in the same session so the page lands at fully zero drift. Architectural rationale: CSP hardening, catalog discoverability, refactor safety.
- **2026-05-09** — JS spec §12 (Event handler binding) adopted. Establishes event delegation as the canonical form for event handler binding in CC page files. §12.1 names the three structural pieces (stable parent element, single `addEventListener` call, handler dispatching by `event.target` plus `data-*`). §12.2 permits direct binding only for singleton elements bound at page boot and window/document-level events. Sections §13 onward renumbered. New drift code `FORBIDDEN_PER_ELEMENT_LISTENER_LOOP` added to §15 and §19.4 covers the `forEach + addEventListener` pattern that attaches one listener per element rather than delegating.
- **2026-05-09** — JS populator catch-up delivered in the same session. `FORBIDDEN_PER_ELEMENT_LISTENER_LOOP` detection added via a `Test-IsInsideElementLoop` helper called from the existing `addEventListener` block in the visitor's `CallExpression` case. The check walks the parent-node chain to find an enclosing `forEach` (or sibling `map`/`filter`/`find`/`some`/`every`) callback or a `for...of`/`for...in`/`for` loop body, stopping at any nested `FunctionDeclaration` so inner functions don't false-positive. The drift attaches to the same `JS_EVENT` USAGE row that already fires for the listener — no separate emitter, no new component_type. Spec and populator are now aligned on every drift code; book closed on JS for now. Next session moves to HTML.
- **2026-05-09** — Phase 1 JS refactor work complete. All four Phase 1 page JS files (`backup.js`, `replication-monitoring.js`, `business-intelligence.js`, plus the previously-completed `business-services.js` with its inline event handler cleanup) refactored to spec compliance and parsing at zero structural drift. Each refactor was a coordinated single pass: structural changes (banners, prefix application, dead code removal, cc-shared.js function migration) plus inline event handler migration to delegated `addEventListener` bindings, plus per-element listener loop migration to delegation. The `business-intelligence.js` work was a full file rewrite eliminating its revealing-module wrapper. All four files are spec-validation artifacts living offline as `*-spec.js` companions; the route HTML companion changes (renamed function references in inline `onclick` attributes, retirement of local `connection-error` elements, route `<script>` tag updates to load `cc-shared.js`) land during the Phase 1 batch sweep when CSS/JS/HTML/PS for each page migrate together.
- **2026-05-09** — JS populator surfaces three `FORBIDDEN_PER_ELEMENT_LISTENER_LOOP` rows on its first run after the catch-up landed, all genuine and all resolved in the same session. Two in `client-relations-spec.js` (REASON FILTER BADGES at line ~414, QUEUE TABLE at line ~552) refactored to delegated handlers bound once at DOMContentLoaded on the stable `#reason-filters` and `#queue-table` containers. One in `cc-shared.js` (`initEngineCardClicks` at line ~774) eliminated entirely by folding the open-popup-on-card-click behavior into the existing document-level `handleGlobalClick` handler that already handled the close-popup-on-outside-click branch; identity is read from each card's existing `id` attribute (`card-engine` or `card-engine-{slug}`), no new HTML attributes required. Cursor styling moved from a JS attribute mutation in `initEngineCardClicks` to a CSS rule on `.engine-card` in `cc-shared.css`. Validates the §12 + populator combination end-to-end: spec rule fires, file changes resolve drift, no spec amendments needed.
- **2026-05-10** — HTML spec drafted across a single session. 17 rule sections plus appendix; 88 drift codes; rules-only-in-body / rationale-in-appendix format applied strictly. Pipeline order revised to CSS → HTML → JS → PS so JS USAGE rows can resolve against HTML DEFINITION rows for IDs and data-attributes. Pipeline execution model: on-demand from Admin page (matching documentation pipeline pattern), no scheduling.
- **2026-05-10** — Engine card model formalized via four cc-prefixed columns on `Orchestrator.ProcessRegistry` (`cc_engine_slug`, `cc_engine_label`, `cc_page_route`, `cc_sort_order`). Populated for active scheduled processes (`run_mode = 1`); NULL for queue processors (`run_mode = 2`) and inactive processes (`run_mode = 0`). The discipline is catalog-detectable via `MISSING_ENGINE_CARD_REGISTRATION` and `UNEXPECTED_ENGINE_CARD_REGISTRATION` drift codes. Future Level 3 transition to fully registry-driven engine cards (helper-emitted markup driven by registry, dropping JS `ENGINE_PROCESSES` declarations) requires no further DDL — only code refactor.
- **2026-05-10** — `has_dynamic_content` BIT flag column added to `dbo.Asset_Registry`. Set TRUE on rows where the parent attribute or text construct contains additional runtime-only content the populator cannot statically resolve. Applies to HTML and JS populator rows; CSS rows leave it NULL. Lets queries distinguish between catalog rows where the analysis is fully captured and those where additional runtime content may apply.
- **2026-05-10** — One mandated dynamic class assembly pattern (array-join). The PowerShell array-join idiom (initialize array with base class, conditionally append modifiers, join with single space, substitute single resolved variable into attribute) is the only legitimate way to construct a dynamic class string. Four granular drift codes cover specific syntactic violations of the rule. Same single-form-only discipline applied earlier to JS function declarations.
- **2026-05-10** — Categorical naming for `HTML_TEXT` rows. `component_name` for text content holds a derived categorical identifier (e.g., `h2-section-title`, `attr-title`) rather than the literal text. Page prefix is stripped from leading class tokens during derivation so categories are comparable across pages. Actual text content lives in `raw_text`. Optimizes for cross-page consistency comparison queries (`WHERE component_name = 'h2-section-title'` returns every page's section title with the literal text in `raw_text` for inspection).
- **2026-05-10** — Slideout/modal/panel ID role-first ordering. ID conventions follow `<prefix>-slideout-<purpose>-overlay`, `<prefix>-modal-<purpose>-overlay`, and `<prefix>-slideup-<purpose>-backdrop` form. Optimizes for "all slideouts on this page" queries (`LIKE 'bsv-slideout-%'` returns every slideout) over "everything related to this purpose" queries.
- **2026-05-10** — Mandated HTML purpose comments for slideouts, modals, and slide-up panels. Comment immediately preceding the overlay/backdrop is read into `purpose_description` for both rows of the construct. Drift code `MISSING_PANEL_PURPOSE_COMMENT` fires on missing comments. Other constructs (page-local IDs, form fields) don't require purpose comments — only the structural constructs that vary in messaging across pages.
- **2026-05-10** — Three forms of HTML entity references catalogued separately. Named entities (`&times;`), numeric entities (`&#9881;`), and direct Unicode characters (`⚙`) each produce their own `HTML_ENTITY` row when found. Future Phase 3 may mandate one form (likely numeric for typographic safety); the catalog tracks all three until then so cross-form consistency analysis informs the decision.
- **2026-05-10** — Helper functions are page-agnostic. Helpers may emit chrome IDs and chrome function calls, but never page-prefixed IDs, page-prefixed function calls, or page-specific `data-*` attributes. Three drift codes (`FORBIDDEN_HELPER_PAGE_PREFIX_ID`, `FORBIDDEN_HELPER_PAGE_FUNCTION_CALL`, `FORBIDDEN_HELPER_PAGE_DATA_ATTRIBUTE`) enforce this.

---

## Future considerations

These are forward-looking platform improvements identified during initiative work but not currently in scope. Wish-list items rather than active commitments. Each represents an architectural pattern worth pursuing once the current refactor work is complete.

### Standardized empty-state text via helpers

Add helper functions to `xFACts-Helpers.psm1` that return standardized empty-state messages. Pages call these helpers instead of hardcoding text. Cross-page consistency: every page using `Get-EmptyStateMessage -Type 'no-executions'` displays identical text. Centralized maintenance: copy changes happen in one place. Catalog visibility: helper-emitted text is `scope = SHARED`, distinguishable from page-specific text. Workflow: populator first surfaces existing empty-state messages across pages; identify which messages are conceptually identical with cosmetic variations; standardize the helper functions; refactor pages to call them.

### Separate page-prefix into its own catalog column

Today, `component_name` for `CSS_CLASS` and `HTML_ID` rows includes the page prefix (e.g., `bsv-pipeline-card`, `bsv-modal-detail`). This is structurally correct because the prefix is part of the actual identifier in the source code. But it makes cross-page queries cumbersome — "find every page's pipeline-card class" requires `LIKE '%-pipeline-card'` (leading wildcard, slow, fragile).

Proposed change: add a `cc_prefix` column to `dbo.Asset_Registry`. `component_name` holds the un-prefixed name (e.g., `pipeline-card`); `cc_prefix` holds the prefix separately (e.g., `bsv`). Shared/chrome rows have NULL prefix. Cross-page identifier comparison becomes trivial: `WHERE component_name = 'pipeline-card'` returns every page's variant. Page-specific filtering remains clean: `WHERE cc_prefix = 'bsv'`. Shared-vs-local filtering works: `WHERE cc_prefix IS NULL` for shared.

Cost: schema migration on Asset_Registry (one new column, plus a pass to backfill from existing rows); CSS spec, JS spec, and HTML spec all need to acknowledge the new column model; populators need to be updated to split prefix on row emission; existing catalog queries against `component_name` would continue to work but need review for whether they should be updated to the new model. Phase 3 candidate after the initial spec rollout settles. The current HTML spec drafting works around it by making `HTML_TEXT` row category names prefix-stripped at derivation time (no schema impact, since `HTML_TEXT` rows are new).

### UI display truncation surfacing

Some pages truncate values when displaying them in tables, slideouts, etc. — making it difficult to see full content. Tracking these down is currently manual. Possible approach: a spec rule for CSS/JS — `text-overflow: ellipsis` and similar truncation patterns require explicit justification, perhaps via a comment annotation that the catalog records. Not a current spec concern, but worth tracking. Cross-domain (CSS spec for `text-overflow`, JS spec for runtime substring truncation).

### Level 3 engine card model — fully registry-driven

The HTML spec's Level 2 model establishes engine card slug/label/page/sort sourced from `Orchestrator.ProcessRegistry` cc-prefixed columns, with route files still hand-authoring engine card markup and JS files declaring `ENGINE_PROCESSES`. Level 3 makes engine card markup itself registry-driven: a helper function (`Get-EngineCardsHtml -PageRoute '/batch-monitoring'`) reads ProcessRegistry and emits the markup; route files use a `$engineCardsHtml` substitution; JS files drop `ENGINE_PROCESSES` declarations because the engine-events shared module reads card definitions from a `/api/engine/cards-for-page` endpoint.

Critically, Level 2 → Level 3 requires no DDL changes — the four cc-prefixed columns on ProcessRegistry support both models. The transition is purely consumption-pattern work: add helper function, add API endpoint, refactor pages to use substitution, update shared JS module. Estimated 1-2 sessions post-refactor when convenient.

### ProcessRegistry export to Platform Registry

`Orchestrator.ProcessRegistry` is foundational platform data — same kind of thing as `ServerRegistry`. Adding ProcessRegistry to the Platform Registry export pipeline is a small backlog item that surfaces process inventory in the same generated documentation as other platform foundations.

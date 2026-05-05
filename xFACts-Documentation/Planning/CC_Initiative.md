# Control Center File Format Initiative

**Status:** Active
**Owner:** Dirk

**Current direction:** Complete JS spec → update all Phase 1 JS files → complete HTML spec → update all Phase 1 HTML files → then migrate one page at a time across all file types.

---

## Purpose

The Control Center File Format initiative is the program of work that defines a strict, machine-parseable file format specification per file type and refactors the existing CC codebase to conform. The motivation is drift detection: files that follow a strict spec catalog cleanly into `dbo.Asset_Registry`, and the catalog is the queryable source of truth for "what exists in the codebase, what's shared, what's reinvented, and what's out of compliance."

The xFACts platform has comprehensive cataloging coverage for the SQL and PowerShell side via `dbo.Object_Registry` and `dbo.Object_Metadata`. Together those two tables fully describe every database object and PowerShell script in the platform, allowing fast queries to answer questions like "do we already have a stored procedure that does X" or "what columns are in this table." The Control Center side previously had no equivalent. Pages are made up of route .ps1 files, page CSS files, page JS files, and API .ps1 files, and the only way to answer "do we already have a CSS class for X" or "is there an API endpoint for Y" or "where is this JS function defined" was to grep through source files. The cost was real and recurring: time spent investigating, slight variations in naming creeping in, duplicate work when something already existed, and refactor risk when shared changes propagated to consumers no one tracked.

The catalog is descriptive (what exists) but its highest-value outcome is prescriptive (what naming and pattern conventions to follow when building new things). The DmOps slideout case is illustrative — DmOps's slide-panel JS toggles `.active` while every other CC page uses `.open` for the same purpose. This wasn't a deliberate divergence; DmOps was built without visibility into the convention that already existed. Multiply that drift by every page over the lifetime of the platform and the cumulative cost is significant. A queryable catalog flips the dynamic: "what's the convention for slideout activation classes" becomes a query, not a guess.

The intent is captured in this principle:

> A developer building a new CC page should be able to query the catalog before writing a single line, find every existing pattern they should reuse, and add new rows for whatever they invent. By the time the page ships, the catalog is current. The catalog is the architecture; the source files are the implementation.

This document is the initiative's navigation hub. It does not contain spec content. Each file-type spec lives in its own document.

---

## Documents in this initiative

| Document | Contains |
|---|---|
| `CC_Initiative.md` | This document — direction, current state, prefix registry, session log, open questions, conversion tracking model, spec evolution process |
| `CC_Catalog_Pipeline_Working_Doc.md` | Operational tracker for the parser pipeline that builds `dbo.Asset_Registry`. Catalog architecture decisions, master component_type list, schema (current state), populator status, where-we-left-off pickup list, environment state, and lessons learned. Will be retired and harvested into Control Center HTML once the pipeline goes live. |
| `CC_CSS_Spec.md` | CSS file format specification |
| `CC_JS_Spec.md` | JavaScript file format specification |
| `CC_PS_Route_Spec.md` | PowerShell route file format specification |
| `CC_PS_Module_Spec.md` | PowerShell module file format specification |
| `CC_HTML_Spec.md` | HTML route file ID conventions and structure |
| `CC_CSS_Refactor_Migration_Notes.md` | Per-file CSS refactor record (active during the transition; retires after Phase 1 pages migrate across all file types) |

---

## Session Start Protocol

If you are Claude starting a new session on this initiative, do exactly this in order. Do not ask Dirk to re-establish context that is captured below.

1. Dirk provides a cache-busted manifest URL at session start (`https://raw.githubusercontent.com/tnjazzgrass/xFACts/main/manifest.json?v=<value>`). Fetch it.
2. From the top-level manifest, locate `manifest-documentation.json` and fetch it.
3. From the documentation manifest, locate the `raw_url` for `xFACts-Documentation/Planning/CC_Initiative.md` (this document) and fetch it.
4. Read the Current State section below. That section contains everything needed to know where work stands.
5. Read whichever spec document is named as active in Current State.
6. Begin work in that area. Honor any "Blocked on" or "Queued next" items in Current State.

**Authoritative source rule:** This document is authoritative for direction and state. The named spec document is authoritative for its file type. If anything in Project Knowledge or Claude's memory contradicts what is written in these documents, the documents win. Project Knowledge is summarized periodically and may lag the docs by a session or more.

**End-of-session discipline:** Before ending any session that touches this initiative, Claude updates Current State (below) and adds an entry to the Session Log. This is not optional — the protocol only works if Current State is kept current.

---

## Current State

*Last updated: 2026-05-05 (end of session — JS spec at v1.1 with variant model designed; JS populator change pass is next).*

**Recent work:** Two sessions of JS work since the 2026-05-04 G-INIT-4 close.

**Session 1 (2026-05-04):** JS spec design session held. Produced `CC_JS_Spec.md` v1.0 — full spec body covering required structure, file headers, section banners, the seven section types (`IMPORTS`, `[FOUNDATION → CHROME →]` `CONSTANTS`, `STATE`, `INITIALIZATION`, `FUNCTIONS`), prefix scoping, function/constant/state/hook/class/method definitions, comments, sub-section markers, ~25 forbidden patterns, ~35 drift codes, and compliance queries. Twelve component types established. Page lifecycle hooks live in a fixed-name `FUNCTIONS: PAGE LIFECYCLE HOOKS` banner that must be last. Page-prefix scoping mandated for all top-level identifiers in page files (`<prefix>_<name>` form, underscore separator). `let` forbidden; `const` for constants and `var` for state. CHANGELOG blocks forbidden. `Populate-AssetRegistry-JS.ps1` rewritten as a spec-aware extractor against the new spec.

**Session 2 (2026-05-05, this session):** JS populator validation run + spec v1.1.

- *Validation run:* 8,360 rows generated across 24 .js files. Drift counts as expected for an unrefactored codebase: 917 `MISSING_SECTION_BANNER`, 661 `MISSING_FUNCTION_COMMENT`, 195 `MISSING_STATE_COMMENT`, plus low-volume specific findings (17 `SHADOWS_SHARED_FUNCTION`, 14 `MALFORMED_FILE_HEADER`, 8 `FORBIDDEN_LET`, 6 `FORBIDDEN_CHANGELOG_BLOCK`, 6 `FORBIDDEN_MULTI_DECLARATION`, 4 `FORBIDDEN_IIFE`, 3 `FORBIDDEN_WINDOW_ASSIGNMENT`, 18 `FORBIDDEN_FILE_SCOPE_LINE_COMMENT`).
- *Mega-object pattern surfaced:* five files (admin.js, applications-integration.js, bdl-import.js, business-intelligence.js, client-portal.js) hide all their function definitions inside a `const PageObject = { ... }` mega-object. The populator catalogs only the outer const, so these files appear nearly drift-free — not because they're spec-aligned but because their internal definitions are invisible to the parser. Resolution is to refactor the files (the spec doesn't allow mega-objects), not to teach the populator about them.
- *CSS pre-load investigated:* initial run produced `source_file = '<undefined>'` on all 4,446 CSS_CLASS USAGE rows because the CSS populator hadn't run since the last schema rev. Re-run with CSS-first sequencing produced correctly-resolved scope (476 SHARED, 3,970 LOCAL). Confirmed not a code bug; populator change pass will add louder degraded-output reporting so the gap is the last thing the operator sees rather than buried mid-run.
- *Column-fill audit:* every column in `dbo.Asset_Registry` writes from somewhere except three — `variant_type`, `variant_qualifier_1`, `variant_qualifier_2`. Decision: extend the variant model to JS rather than leave the columns NULL on JS rows.
- *Schema verification:* `INFORMATION_SCHEMA.COLUMNS` query confirmed live shape. `related_asset_id`, `design_notes`, `is_active` shipped as dropped (working doc said "still in the live table" — stale). `drift_codes` is `VARCHAR(500)` not `VARCHAR(MAX)` (working doc was stale on width too). `variant_type` is `VARCHAR(30)` not `VARCHAR(20)`.
- *Spec v1.1:* status backed off from FINALIZED to `[DRAFT — pending populator validation]`. Section 17 expanded with the variant model in 17.5 — three component types gain `_VARIANT` siblings (`JS_FUNCTION_VARIANT`, `JS_CONSTANT_VARIANT`, `JS_METHOD_VARIANT`) where there's a true base form; three component types (`JS_IMPORT`, `JS_TIMER`, `JS_EVENT`) keep their single name and always carry a non-NULL `variant_type` because every instance is inherently a variant. Four stale `parent_object` references in v1.0 remapped — three to `parent_function` (JS_METHOD class containment), one to `variant_qualifier_2` (JS_IMPORT source path).
- *Working doc updated:* master component_type list added the missing JS_HOOK / JS_STATE / JS_TIMER baselines plus the three new JS_*_VARIANT types; Schema (current state) section rewritten verbatim from `INFORMATION_SCHEMA.COLUMNS`; new "Variant model" subsection documents the architectural pattern (base + `_VARIANT` companion vs. single type with always-non-NULL `variant_type`).
- *Companion deliverable:* `ALTER_AssetRegistry_AddJsVariantTypes.sql` extends the `component_type` CHECK constraint to accept the three new values. Must run before next session's populator pass.

**Phase 1 CSS refactor work — complete and at zero drift:**

| File | Prefix |
|------|--------|
| `cc-shared.css` | (uses `--<category>-*` token namespace) |
| `backup.css` | `bkp` |
| `business-intelligence.css` | `biz` |
| `client-relations.css` | `clr` |
| `replication-monitoring.css` | `rpm` |
| `business-services.css` | `bsv` |

The remaining ~22 CSS files are deferred to the page-at-a-time migration phase that begins after JS and HTML specs land.

**Phase 1 JS refactor work — not yet started.** Refactor begins after the populator change pass validates clean. First target is `engine-events.js` → `cc-shared.js` (the canonical shared file, becomes the spec reference implementation). Then page files one at a time. Phase 1 JS scope mirrors CSS: the same six files (cc-shared + the five Phase 1 page files), using the same prefixes.

**Active spec documents:**

- `CC_CSS_Spec.md` — production. CSS populator runs against it cleanly.
- `CC_JS_Spec.md` v1.1 (DRAFT) — populator validation pending. **This is the active spec document for next session.**
- `CC_HTML_Spec.md` — pre-design (stub).
- `CC_PS_Module_Spec.md`, `CC_PS_Route_Spec.md` — pre-design (stubs).

**Queued next:**

1. **JS populator change pass (next session's opener).** Detailed change list with verification criteria lives in `CC_Catalog_Pipeline_Working_Doc.md` "Where we left off" pickup item #1. Four discrete changes: variant model wiring per `CC_JS_Spec.md` v1.1 Section 17.5; `parent_function` AST-walker threading; louder pre-load reporting when CSS_CLASS DEFINITION rows are missing; `drift_codes` width truncation aligned to `VARCHAR(500)` schema. `ALTER_AssetRegistry_AddJsVariantTypes.sql` must run first.
2. **engine-events.js → cc-shared.js refactor.** After populator validates clean. Becomes the spec reference implementation; remaining page files follow one at a time.
3. **HTML populator catch-up + spec design session.** Same pattern as JS. Bring `Populate-AssetRegistry-HTML.ps1` to current schema (clean up dropped-column references and `state_modifier='<dynamic>'` pattern), then design the HTML format spec.

**Blocked on:** nothing.

---

## Prefix Registry

Each CC page declares a 3-character prefix that scopes its page-local identifiers across CSS class names, HTML class attributes, and JS selectors. The prefix is a page-wide identity, not a per-file-type rule.

The table below is the canonical prefix-to-page mapping. New CC pages get a row here at the time they are created. Prefix selection rules and authoring discipline are documented in the relevant per-file-type spec docs.

| Page | Prefix |
|------|--------|
| `admin` | `adm` |
| `applications-integration` | `aai` |
| `backup` | `bkp` |
| `batch-monitoring` | `bat` |
| `bdl-import` | `bdl` |
| `bidata-monitoring` | `bid` |
| `business-intelligence` | `biz` |
| `business-services` | `bsv` |
| `client-portal` | `clp` |
| `client-relations` | `clr` |
| `dbcc-operations` | `dbc` |
| `dm-operations` | `dmo` |
| `file-monitoring` | `flm` |
| `index-maintenance` | `idx` |
| `jboss-monitoring` | `jbm` |
| `jobflow-monitoring` | `jfm` |
| `platform-monitoring` | `plt` |
| `replication-monitoring` | `rpm` |
| `server-health` | `srv` |

`cc-shared.css` does not have a prefix — it uses the `--<category>-*` token namespace for custom properties and prefix-free class names for shared chrome.

The documentation CSS files (`docs-*.css`) are evaluated separately and do not have prefixes assigned at this time.

---

## Conversion tracking model

Files in the CC codebase exist in one of three states during the initiative:

| State | Meaning |
|---|---|
| **Pre-spec** | File has not yet been refactored against any current spec. Spec compliance not expected; drift codes in the catalog reflect the file's pre-refactor state. |
| **Partially compliant** | File has been refactored against one or more file-type specs but not all. Example: a page whose CSS is at zero drift but whose HTML and JS still reference unprefixed class names. The page works but the catalog reflects mixed compliance. |
| **Fully compliant** | File has been refactored against every applicable spec (CSS, JS, HTML, and PS where applicable) and parses at zero drift across all of them. |

Per-file progress during the transition lives in the per-file-type migration notes documents. Once all Phase 1 pages reach the fully compliant state, those migration notes documents retire — at that point the catalog's drift metrics are sufficient to track ongoing compliance and per-file narrative documentation is no longer needed.

The current direction (page-at-a-time migration after JS and HTML specs land) means that during the post-Phase-1 work, each page transitions directly from pre-spec to fully compliant within a single coordinated session, eliminating the partially-compliant state for those pages.

---

## Spec evolution process

When a spec needs to change — because validation surfaces a gap, because a new pattern emerges, or because a rule turns out to be impractical — updates follow this process:

1. Identify the gap in the relevant spec doc (a file structure the spec doesn't address, a parser ambiguity, or a rule that produces friction without value).
2. Discuss the proposed change.
3. Update the spec doc directly, baking the new rule and its rationale into the relevant section.
4. Update the parser to enforce the new rule.
5. Run the parser against currently-compliant files to verify no regressions.
6. Update any non-compliant files affected by the change.

### Versioning

Each spec doc carries its own version in its revision history.

- **Major version bumps** (`1.0` → `2.0`) indicate breaking changes that require existing compliant files to be updated.
- **Minor version bumps** (`1.0` → `1.1`) indicate additions or clarifications that don't break existing compliant files.

Specs reach version `1.0` when they promote from `[DRAFT]` to `[FINALIZED]`.

---

## Known gaps and enhancements

Items where the desired outcome is understood but the implementation hasn't happened yet, or where a known design problem has been identified but not fully solved. Distinct from open questions (which capture genuine unknowns).

### G-INIT-1 — Prefix uniqueness enforcement at the database layer

**Desired outcome:** Database-level enforcement of prefix uniqueness across all CC pages, plus catalog queryability of "which page does this class belong to" via prefix join.

**Current state:** The Prefix Registry table in this document is the canonical mapping. Uniqueness is enforced by manual review at registry-update time. Catalog queries that need to associate a class with its owning page have to derive the association from the class name's prefix substring rather than via a join.

**Partial design — known not to work:** The first thought was to add a `prefix CHAR(3) NULL` column to `dbo.Module_Registry` with a unique constraint. This doesn't work because the relationship between pages and modules is many-to-one — a single module can own multiple pages (via component decomposition), so a prefix column on `Module_Registry` cannot have the right cardinality for unique enforcement.

**What needs to be solved:**

- Identify the right table for the prefix column. Candidates: a new dedicated `dbo.Page_Registry` table keyed at the page level; an existing page-grain table if one exists; or a separate `dbo.CC_Prefix_Registry` table that exists solely for this purpose.
- Decide whether the prefix should be authoritative in the database (any catalog-driven workflow consults the table) or in this document (the table mirrors the doc).
- Define the relationship to `Object_Registry` so the spec parsers can resolve a CSS file's expected prefix from a registry lookup rather than from a hardcoded mapping.

**Why this matters:** without database-level enforcement, prefix collisions are caught only at human review time, and catalog queries can't cleanly answer "which page owns this class" without name-parsing logic.

### G-INIT-2 — Development guidelines updated to instruct catalog-first authoring

**Desired outcome:** `xFACts_Development_Guidelines.md` instructs developers building new CC pages to query `dbo.Asset_Registry` before authoring code, in order to find existing naming conventions, shared utilities, and component patterns. The catalog becomes the first stop, not the last resort.

**Current state:** The development guidelines do not reference the catalog. Catalog-first authoring is the eventual intent of this initiative but the supporting infrastructure isn't ready: catalog coverage is currently CSS-only across five Phase 1 pages plus `cc-shared.css`, JS and HTML are not yet cataloged, and the catalog's component vocabulary will continue to evolve as JS and HTML specs land.

**What needs to be solved:**

- Catalog coverage needs to reach a threshold where catalog-first queries return useful answers across all file types — not just CSS. Realistically, this means at minimum Phase 1 pages fully migrated across CSS, JS, and HTML, with all three specs finalized.
- The development guidelines need a new section drafted that names the queryable patterns: "looking for an existing CSS class," "looking for an existing JS utility function," "looking for an existing API endpoint shape," and so on. Each pattern is a documented query against `dbo.Asset_Registry`.
- The Q1 (chrome consolidation candidates) and Q5 (promotion-to-shared candidates) queries from the spec docs are the closest existing reference; a developer-facing version of these — narrower scope, less drift-detection-oriented, more "what already exists I should reuse" — would land in the guidelines.

**Why this matters:** the catalog's prescriptive value (drift prevention via convention reuse) is fully realized only when authoring workflows actually consult it. Without the guidelines update, the catalog remains a detection tool used after the fact rather than an authoring tool used before the fact.

### G-INIT-3 — `dbo.Asset_Registry` schema cleanup and `purpose_description` wiring [RESOLVED]

**Desired outcome:** the `Asset_Registry` table holds only columns that are either parser-populated or structurally required (PK, FK, refresh metadata). Manual-annotation columns are removed from this table and live in a separate annotations table keyed on the natural key. The `purpose_description` column — currently always NULL — is wired into the CSS populator to capture file-header purpose paragraphs and section-banner descriptions.

**Current state: RESOLVED 2026-05-04.** DDL drops applied (`related_asset_id`, `design_notes`, `is_active`). Patched CSS populator deployed; FILE_HEADER rows now carry the file's purpose paragraph and COMMENT_BANNER rows now carry the section's description block. The complementary coverage gap on per-class and per-variant comments was tracked separately as G-INIT-4 and has since also closed.

**Cross-populator audit (completed in same session):**

- **CSS populator** — no other references to dropped columns; `is_active` only appears in the `Object_Registry` SELECT (different table, not affected). Patch is clean.
- **HTML populator** — pre-existing references to schema-migrated columns `state_modifier`, `component_subtype`, `parent_object` plus the three columns being dropped today. Has been non-functional against the post-2026-05-03 schema. Catch-up deferred to the HTML format spec design session.
- **JS populator** — same pattern as HTML. Deferred to the JS format spec design session.

Both HTML and JS populators have `WHERE is_active = 1` filters in their `Asset_Registry` CSS_CLASS DEFINITION lookups. These will need to be removed when those populators are caught up; not blocking today's CSS-only deployment.

**Why this matters:** the parser is already extracting purpose-comment text from file headers and section banners; throwing it away leaves the catalog less informative than it could be. The mandated purpose comments in the CSS spec exist specifically so the parser can capture this metadata. The three column drops trim the schema to its actual operational surface, eliminating dead columns that would otherwise need to be filtered or ignored in every query.

### G-INIT-4 — Complete CSS `purpose_description` coverage for all commented descriptions [RESOLVED]

**Desired outcome:** every CSS catalog row whose source has a description comment carries that comment text in `purpose_description`. The catalog becomes the queryable answer to "what does this class do" without needing to open the source file.

**Current state: RESOLVED 2026-05-04.** Both remaining comment sources are now wired up. Per-class purpose comments land on `CSS_CLASS DEFINITION` rows; per-variant trailing inline comments land on `CSS_VARIANT DEFINITION` rows. Pseudo-element rules attached to a class (e.g., `.foo::placeholder`) are spec-classified as `CSS_CLASS` rows and pick up the same preceding-comment treatment via the existing base-class emission path. Verification on the five new-format spec-compliant CSS files showed 100% coverage across all four comment-derived row classes (FILE_HEADER, COMMENT_BANNER, CSS_CLASS DEFINITION, CSS_VARIANT DEFINITION).

**What was solved:**

- **Per-class purpose comments → `CSS_CLASS DEFINITION` rows.** New `ConvertTo-CleanCommentText` helper normalizes line endings, trims each line, drops blank lines, joins with `\n`. Returns NULL for whitespace-only input. Capture point added in the rule-handling branch of `Add-RowsFromAst` alongside the existing presence-detection logic; text threaded through new `-PrecedingCommentText` parameter on `Add-RowsForSelector` and `-PurposeDescription` parameter on `Add-CssClassOrVariantRow`.
- **Per-variant trailing inline comments → `CSS_VARIANT DEFINITION` rows.** Same plumbing path, separate variable (`$trailingInlineCommentText`), separate parameter (`-TrailingInlineCommentText`). `Add-RowsForSelector` selects the right text per emitted row based on `$shape.VariantType` — base classes get the preceding text, variants get the trailing text, descendant USAGE rows get NULL (the comment belongs to the primary).
- **Multi-line preservation.** Comment line breaks are retained in the captured text so multi-sentence purpose comments render cleanly in any future reference view that displays them. Per-line indentation (a visual artifact of source formatting) is stripped.

**Why this matters:** the per-class purpose comment is arguably the highest-value `purpose_description` content in the catalog. Every class is required to have one, every comment is one sentence, and querying `SELECT component_name, purpose_description FROM Asset_Registry WHERE component_type = 'CSS_CLASS' AND reference_type = 'DEFINITION'` becomes a useful one-line glossary of every class in the codebase. The variant trailing-comment text similarly answers "what state is this variant for" without needing to open the source file. With G-INIT-3 and G-INIT-4 both closed, all four comment sources defined by the CSS spec — file header, section banner, per-class, per-variant — flow into the catalog.

**Implications for future spec work:** the per-class and per-variant comment-capture pattern established here is the template for analogous comment capture when JS and HTML spec design sessions land. Function-level doc comments in JS and component-level structural comments in HTML will use the same "detect presence at parse time, capture text alongside the presence flag, thread through to PurposeDescription" approach.

---

## Open questions

Cross-cutting questions that don't fit cleanly inside any single spec doc. Per-spec-doc open questions live in the relevant spec doc, not here.

### OQ-INIT-2 — Long-term home for migration notes content

The CSS refactor migration notes capture per-file refactor decisions (class renames, structural flattenings, shared-token additions, etc.) that may have long-term reference value beyond the active migration period. Under the truncate-and-reload model `dbo.Asset_Registry` doesn't carry persistent annotations; manual annotations of any kind go in a separate annotations table keyed on the natural key.

If any migration notes content has long-term reference value, a permanent SQL home that survives parser reloads and is linkable to `Asset_Registry` rows would be useful. The annotations table itself may be the right home, or a separate per-file decision-log table parallel to it. To be evaluated as Phase 1 page migrations complete and the migration notes documents approach retirement.

---

## Session log

A running log of session-by-session activity. Lightweight entries — what was done, what's queued next.

| Date | Activity |
|---|---|
| 2026-05-05 | JS populator validation run + JS spec v1.0 and v1.1. Validation produced 8,360 rows across 24 .js files; drift counts as expected for an unrefactored codebase (917 MISSING_SECTION_BANNER dominant; low-volume specifics include 17 SHADOWS_SHARED_FUNCTION, 14 MALFORMED_FILE_HEADER, 8 FORBIDDEN_LET, 6 FORBIDDEN_CHANGELOG_BLOCK, 4 FORBIDDEN_IIFE, 3 FORBIDDEN_WINDOW_ASSIGNMENT). Mega-object pattern surfaced in five files (admin.js, applications-integration.js, bdl-import.js, business-intelligence.js, client-portal.js) — populator catalogs only the outer const, hiding internal definitions; resolution is to refactor the files, not change the populator. CSS pre-load investigated and confirmed not a code bug — running CSS populator before JS produces correctly-resolved scope (476 SHARED, 3,970 LOCAL); populator change pass will add louder degraded-output reporting. Column-fill audit identified `variant_type` / `variant_qualifier_1` / `variant_qualifier_2` as the only never-populated columns; decision to extend the variant model to JS rather than leave them NULL on JS rows. Live `INFORMATION_SCHEMA.COLUMNS` query confirmed the schema and surfaced three documentation drifts in the working doc — `related_asset_id` / `design_notes` / `is_active` already shipped as dropped (working doc said still-in-table); `drift_codes` is `VARCHAR(500)` not `VARCHAR(MAX)`; `variant_type` is `VARCHAR(30)` not `VARCHAR(20)`. **Spec v1.1 produced:** status backed off from FINALIZED to DRAFT — pending populator validation; Section 17 expanded with variant model in 17.5 — three component types gain `_VARIANT` siblings (`JS_FUNCTION_VARIANT`, `JS_CONSTANT_VARIANT`, `JS_METHOD_VARIANT`) where there's a true base form; three component types (`JS_IMPORT`, `JS_TIMER`, `JS_EVENT`) keep their single name and always carry a non-NULL `variant_type` because every instance is inherently a variant; four stale `parent_object` references remapped (three to `parent_function` for JS_METHOD class containment, one to `variant_qualifier_2` for JS_IMPORT source path). **Working doc updated:** master component_type list got the missing JS_HOOK / JS_STATE / JS_TIMER baselines plus the three new JS_*_VARIANT types; Schema (current state) section rewritten verbatim from `INFORMATION_SCHEMA.COLUMNS`; new "Variant model" subsection documents the architectural pattern. **Companion deliverable:** `ALTER_AssetRegistry_AddJsVariantTypes.sql` extends the `component_type` CHECK constraint to accept the three new values; must run before next session's populator pass. JS populator change pass is the new top-of-queue. |
| 2026-05-04 | G-INIT-4 implemented and verified. CSS populator now captures per-class purpose comments onto `CSS_CLASS DEFINITION` rows and per-variant trailing inline comments onto `CSS_VARIANT DEFINITION` rows. Implementation: new `ConvertTo-CleanCommentText` helper preserving multi-line structure; capture points added at existing presence-detection sites; new `-PrecedingCommentText` / `-TrailingInlineCommentText` parameters on `Add-RowsForSelector`; new `-PurposeDescription` parameter on `Add-CssClassOrVariantRow`. Verification query consolidated into a single 4-row report covering FILE_HEADER, COMMENT_BANNER, CSS_CLASS DEFINITION, and CSS_VARIANT DEFINITION coverage. Run produced 7,577 total rows; on the five new-format spec-compliant CSS files coverage is 100% across all four row classes. Closed G-INIT-4. JS spec design session is the new top-of-queue. Doc retirement (originally queued item 2) was completed locally and is no longer on the queue. |
| 2026-05-04 | Major file format documentation reorganization session. Produced finalized `CC_CSS_Spec.md` (extracted from retired `CC_FileFormat_Standardization.md` Part 3 + Section 11.8 + CSS portions of Appendix A; rationale moved inline next to the rules it justifies; Prefix Registry centralized in this Initiative doc). Created this Initiative doc as the navigation hub with single-line current direction, Documents-in-this-initiative table, Session Start Protocol, Current State, Prefix Registry, Conversion tracking model, Spec evolution process, Known gaps and enhancements, Open questions, Session log. Did reconciliation passes on `CC_FileFormat_Spec.md` and `CC_Component_Registry_Plan.md` (full disposition tables — most content SUPERSEDED, motivational framing HARVESTED into Initiative doc Purpose). Produced four stubbed spec docs `[DRAFT — design session not yet held]`: `CC_JS_Spec.md`, `CC_PS_Route_Spec.md`, `CC_PS_Module_Spec.md`, `CC_HTML_Spec.md` — each with standard outline sections stubbed plus "Pre-design observations" section at top holding harvested content from the retired Spec doc with review notes. Renamed `Asset_Registry_Working_Doc.md` to `CC_Catalog_Pipeline_Working_Doc.md` and trimmed redundancies that now live in spec docs and Initiative doc; updated schema DDL to reflect the post-2026-05-03-migration shape. **OQ-INIT-1 resolved with implementation delivered:** Diagnosed `purpose_description` not populated because CSS populator's `New-RowSkeleton` doesn't include the field. Resolution scope captured as G-INIT-3: drop `related_asset_id`, `design_notes`, and `is_active` from the table; wire up `purpose_description` for FILE_HEADER and COMMENT_BANNER rows. Implementation artifacts produced: `Drop_AssetRegistry_Columns.sql` (DDL drop with default-constraint handling for is_active) and patched `Populate-AssetRegistry-CSS.ps1`. Cross-populator audit confirmed CSS-only patch is safe; HTML and JS populators have pre-existing breakage against post-migration schema, deferred to their respective spec sessions. Added G-INIT-2 (catalog-first authoring guidelines update) during gap-tracking discussion. |

Earlier sessions (CSS refactor of Phase 1 pages, parser implementation, schema migrations, design discussions for the CSS spec) are recorded in the retired `CC_FileFormat_Standardization.md` Session Log and are not duplicated here. Once the retired docs move out of `Planning/`, the session history before this date lives in those archived files.

---

## Revision history

| Version | Date | Description |
|---|---|---|
| 1.3 | 2026-05-05 | JS populator validation run + JS spec design refinements. `CC_JS_Spec.md` advanced from pre-design v0.2 → v1.0 → v1.1 (full spec body, prior session, also captured in this revision since it precedes any other recorded v1.x entry) → v1.1 (variant model added in Section 17.5; status backed off from FINALIZED to DRAFT pending populator validation; four stale `parent_object` references remapped). `CC_Catalog_Pipeline_Working_Doc.md` updated: master component_type list extended with the three new JS_*_VARIANT types plus the JS_HOOK / JS_STATE / JS_TIMER baselines that had been missing since v1.0; Schema (current state) DDL block rewritten verbatim from live `INFORMATION_SCHEMA.COLUMNS` (corrects three documentation drifts on column widths and dropped-column status); new "Variant model" subsection documents the architectural pattern (base + `_VARIANT` companion vs. single type with always-non-NULL `variant_type`); "Where we left off" pickup list rewritten to lead with the JS populator change pass with full change list and verification criteria. Current State section in this Initiative doc rewritten with explicit per-session breakdowns, new "Active spec documents" subsection naming the active spec for next session, and a "Phase 1 JS refactor work — not yet started" placeholder mirroring the CSS Phase 1 table structure. New SQL artifact: `ALTER_AssetRegistry_AddJsVariantTypes.sql` extends the `component_type` CHECK constraint to accept `JS_FUNCTION_VARIANT`, `JS_CONSTANT_VARIANT`, `JS_METHOD_VARIANT`; must run before next session's JS populator pass. Queued-next reordered to lead with JS populator change pass. |
| 1.2 | 2026-05-04 | G-INIT-4 closed — patched CSS populator deployed and verified. Per-class purpose comments now flow to `CSS_CLASS DEFINITION` rows; per-variant trailing inline comments now flow to `CSS_VARIANT DEFINITION` rows. Coverage at 100% on the five new-format spec-compliant files. Current State updated. G-INIT-4 marked RESOLVED in Known gaps and enhancements (following the same convention used for G-INIT-3). Queued-next reordered to lead with JS spec design session. Doc retirement removed from queue (completed locally). |
| 1.1 | 2026-05-04 | G-INIT-3 closed — DDL drops applied successfully; patched CSS populator deployed; FILE_HEADER and COMMENT_BANNER rows now populate `purpose_description` correctly. G-INIT-4 raised to capture remaining CSS `purpose_description` coverage gap (per-class purpose comments and per-variant trailing inline comments) — tagged as next session's opener so CSS comment capture is fully landed before attention shifts to HTML or JS. Current State updated. Queued-next reordered to lead with G-INIT-4. |
| 1.0 | 2026-05-04 | Initial release. |

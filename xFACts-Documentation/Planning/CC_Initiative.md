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

*Last updated: 2026-05-04 (end of session — file format documentation reorganization complete; OQ-INIT-1 resolved and G-INIT-3 applied; G-INIT-4 queued as next session's opener).*

**This session's work:** File format documentation reorganization completed. The previous structure (one large `CC_FileFormat_Standardization.md` plus the abandoned `CC_FileFormat_Spec.md` plus the obsolete `CC_Component_Registry_Plan.md` and the never-merged `CC_FileFormat_Parser_Friendly_Conventions_Recommendations.md`) is replaced by a per-spec-doc structure with this initiative doc as the navigation hub. CSS spec is `[FINALIZED]`. Four other spec docs (`CC_JS_Spec.md`, `CC_PS_Route_Spec.md`, `CC_PS_Module_Spec.md`, `CC_HTML_Spec.md`) are stubbed with pre-design observations awaiting their respective design sessions. The Asset Registry working doc is renamed `CC_Asset_Registry_Working_Doc.md` and trimmed of redundancies that now live elsewhere. OQ-INIT-1 (`purpose_description` column not populated) was diagnosed, resolved, implemented, and applied. G-INIT-3 closes (DDL drops applied; CSS populator wiring landed for FILE_HEADER and COMMENT_BANNER rows). G-INIT-4 raised to capture the remaining CSS `purpose_description` coverage gap — per-class purpose comments and per-variant trailing inline comments need wiring.

**Phase 1 CSS refactor work — complete and at zero drift:**

| File | Prefix |
|------|--------|
| `cc-shared.css` | (uses `--<category>-*` token namespace) |
| `backup.css` | `bkp` |
| `business-intelligence.css` | `biz` |
| `client-relations.css` | `clr` |
| `replication-monitoring.css` | `rpm` |
| `business-services.css` | `bsv` |

The remaining ~22 CSS files are deferred. Per the current direction, JS spec design and Phase 1 JS file refactor come next; CSS work on remaining pages happens during the page-at-a-time migration phase that begins after JS and HTML specs land.

**Queued next:**

1. **G-INIT-4 implementation (next session's opener)** — complete CSS `purpose_description` coverage. Capture per-class purpose comment text on `CSS_CLASS DEFINITION` rows; capture per-variant trailing inline comment text on `CSS_VARIANT DEFINITION` rows. Do this before shifting attention to other file types so the comment-capture pattern is fully established for CSS.
2. Retirement of deprecated docs out of `Planning/` — Dirk's local archive cleanup. Targets: `CC_FileFormat_Standardization.md`, `CC_FileFormat_Spec.md`, `CC_FileFormat_Parser_Friendly_Conventions_Recommendations.md`, `CC_Component_Registry_Plan.md`, `Asset_Registry_Working_Doc.md` (replaced by `CC_Asset_Registry_Working_Doc.md`), and the working `CC_FileFormat_Spec_Reconciliation.md` from this session.
3. JS spec design session — after G-INIT-4 closes, review pre-design observations in `CC_JS_Spec.md`, draft the JS spec body, validate against an existing JS file. Populator catch-up housekeeping documented at the top of the spec doc handles cleanly first.
4. HTML populator catch-up + spec design session — same pattern as JS. Bring `Populate-AssetRegistry-HTML.ps1` to current schema, then design the HTML format spec.

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

### G-INIT-3 — `dbo.Asset_Registry` schema cleanup and `purpose_description` wiring

**Desired outcome:** the `Asset_Registry` table holds only columns that are either parser-populated or structurally required (PK, FK, refresh metadata). Manual-annotation columns are removed from this table and live in a separate annotations table keyed on the natural key. The `purpose_description` column — currently always NULL — is wired into the CSS populator to capture file-header purpose paragraphs and section-banner descriptions.

**Current state:** Implementation artifacts delivered, awaiting application. Two artifacts produced in the OQ-INIT-1 resolution session: `Drop_AssetRegistry_Columns.sql` (drops `related_asset_id`, `design_notes`, `is_active` with default-constraint handling for the latter) and a patched `Populate-AssetRegistry-CSS.ps1` (adds `PurposeDescription` to row skeleton; routes file-header purpose paragraphs and section-banner descriptions to the column; trims the bulk-insert DataTable to drop the three column references; adds a verification query that reports `purpose_description` coverage on FILE_HEADER and COMMENT_BANNER rows after each run). When Dirk applies these, OQ-INIT-1 closes and this gap retires.

**Cross-populator audit (completed in same session):**

- **CSS populator** — no other references to dropped columns; `is_active` only appears in the `Object_Registry` SELECT (different table, not affected). Patch is clean.
- **HTML populator** — pre-existing references to schema-migrated columns `state_modifier`, `component_subtype`, `parent_object` plus the three columns being dropped today. Has been non-functional against the post-2026-05-03 schema. Catch-up deferred to the HTML format spec design session.
- **JS populator** — same pattern as HTML. Deferred to the JS format spec design session.

Both HTML and JS populators have `WHERE is_active = 1` filters in their `Asset_Registry` CSS_CLASS DEFINITION lookups. These will need to be removed when those populators are caught up; not blocking today's CSS-only deployment.

**Why this matters:** the parser is already extracting purpose-comment text from file headers and section banners; throwing it away leaves the catalog less informative than it could be. The mandated purpose comments in the CSS spec exist specifically so the parser can capture this metadata. The three column drops trim the schema to its actual operational surface, eliminating dead columns that would otherwise need to be filtered or ignored in every query.

**Optional follow-up** (separate gap or session if pursued): capture preceding-purpose-comment text on CSS_CLASS DEFINITION rows. Currently the populator only checks for the comment's presence (to emit `MISSING_PURPOSE_COMMENT` drift); it could also capture the comment text and route it to `PurposeDescription`. More invasive — requires plumbing comment text through several call sites — but the spec mandates these comments precisely so their content can become catalog metadata. Not part of this gap; would land as a future enhancement.

### G-INIT-4 — Complete CSS `purpose_description` coverage for all commented descriptions

**Desired outcome:** every CSS catalog row whose source has a description comment carries that comment text in `purpose_description`. The catalog becomes the queryable answer to "what does this class do" without needing to open the source file.

**Current state:** G-INIT-3 wired up two of the three CSS comment sources — file header purpose paragraphs land on `FILE_HEADER` rows, section banner descriptions land on `COMMENT_BANNER` rows. The third source — comments attached directly to class definitions — is not yet captured. The CSS spec mandates a single-line purpose comment immediately preceding each base class definition and a trailing inline comment after the opening brace of each variant; the populator detects the *presence* of these comments today (to emit `MISSING_PURPOSE_COMMENT` and `MISSING_VARIANT_COMMENT` drift codes) but discards the comment text.

**What needs to be solved:**

- **Per-class purpose comments → `CSS_CLASS DEFINITION` rows.** The `/* One-sentence purpose. */` comment that the spec mandates before each base class. Today the populator sets `$hasPrecedingComment = $true` and moves on; it needs to also capture the comment text into a variable (`$precedingCommentText`) and plumb it through `Add-RowsForSelector` → `Add-CssClassOrVariantRow` → `$row.PurposeDescription`. Several call sites' parameter signatures grow.
- **Per-variant trailing inline comments → `CSS_VARIANT DEFINITION` rows.** The `/* hovered */` style comment after the opening brace of each variant. Today detected via `$firstChild.type -eq 'comment' -and $firstChild.source.start.line -eq $line` for the `MISSING_VARIANT_COMMENT` drift check; the comment node's text needs to be extracted (PostCSS represents this as the rule's first child comment node) and routed to `PurposeDescription` on the emitted variant row.
- **Optional — sub-section markers.** The spec also recognizes a fifth comment type for sub-section markers within larger sections. These don't currently produce dedicated catalog rows; if the design session decides they should, they'd be another `purpose_description` source.

**Why this matters:** the per-class purpose comment is arguably the highest-value `purpose_description` content in the catalog. Every class is required to have one, every comment is one sentence, and querying `SELECT component_name, purpose_description FROM Asset_Registry WHERE component_type = 'CSS_CLASS' AND reference_type = 'DEFINITION'` becomes a useful one-line glossary of every class in the codebase. The mandate exists precisely so this metadata can flow into the catalog; not capturing it today leaves the most important purpose-description case unwired.

**Sequencing note:** This is the first thing to address in the next session, before shifting attention to HTML/JS investigations. The per-class comment-capture pattern that emerges here will likely apply analogously to JS function/method/constant doc comments and HTML comment annotations when those format specs land — so doing CSS completely first establishes the pattern.

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
| 2026-05-04 | Major file format documentation reorganization session. Produced finalized `CC_CSS_Spec.md` (extracted from retired `CC_FileFormat_Standardization.md` Part 3 + Section 11.8 + CSS portions of Appendix A; rationale moved inline next to the rules it justifies; Prefix Registry centralized in this Initiative doc). Created this Initiative doc as the navigation hub with single-line current direction, Documents-in-this-initiative table, Session Start Protocol, Current State, Prefix Registry, Conversion tracking model, Spec evolution process, Known gaps and enhancements, Open questions, Session log. Did reconciliation passes on `CC_FileFormat_Spec.md` and `CC_Component_Registry_Plan.md` (full disposition tables — most content SUPERSEDED, motivational framing HARVESTED into Initiative doc Purpose). Produced four stubbed spec docs `[DRAFT — design session not yet held]`: `CC_JS_Spec.md`, `CC_PS_Route_Spec.md`, `CC_PS_Module_Spec.md`, `CC_HTML_Spec.md` — each with standard outline sections stubbed plus "Pre-design observations" section at top holding harvested content from the retired Spec doc with review notes. Renamed `Asset_Registry_Working_Doc.md` to `CC_Asset_Registry_Working_Doc.md` and trimmed redundancies that now live in spec docs and Initiative doc; updated schema DDL to reflect the post-2026-05-03-migration shape. **OQ-INIT-1 resolved with implementation delivered:** Diagnosed `purpose_description` not populated because CSS populator's `New-RowSkeleton` doesn't include the field. Resolution scope captured as G-INIT-3: drop `related_asset_id`, `design_notes`, and `is_active` from the table; wire up `purpose_description` for FILE_HEADER and COMMENT_BANNER rows. Implementation artifacts produced: `Drop_AssetRegistry_Columns.sql` (DDL drop with default-constraint handling for is_active) and patched `Populate-AssetRegistry-CSS.ps1`. Cross-populator audit confirmed CSS-only patch is safe; HTML and JS populators have pre-existing breakage against post-migration schema, deferred to their respective spec sessions. Added G-INIT-2 (catalog-first authoring guidelines update) during gap-tracking discussion. |

Earlier sessions (CSS refactor of Phase 1 pages, parser implementation, schema migrations, design discussions for the CSS spec) are recorded in the retired `CC_FileFormat_Standardization.md` Session Log and are not duplicated here. Once the retired docs move out of `Planning/`, the session history before this date lives in those archived files.

---

## Revision history

| Version | Date | Description |
|---|---|---|
| 1.1 | 2026-05-04 | G-INIT-3 closed — DDL drops applied successfully; patched CSS populator deployed; FILE_HEADER and COMMENT_BANNER rows now populate `purpose_description` correctly. G-INIT-4 raised to capture remaining CSS `purpose_description` coverage gap (per-class purpose comments and per-variant trailing inline comments) — tagged as next session's opener so CSS comment capture is fully landed before attention shifts to HTML or JS. Current State updated. Queued-next reordered to lead with G-INIT-4. |
| 1.0 | 2026-05-04 | Initial release. |

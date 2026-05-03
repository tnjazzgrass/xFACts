# Control Center File Format Standardization

**Created:** May 2, 2026
**Status:** Active - CSS spec drafted, parser running cleanly against all 27 CSS files; sanity sweep surfaced parser bugs and one spec gap; bug-fix pass and validation queued for next session
**Owner:** Dirk
**Target File:** `xFACts-Documentation/Planning/CC_FileFormat_Standardization.md`

---

## Purpose

This document is the single source of truth for the Control Center file format standardization initiative. It establishes a strict, machine-parseable file format specification per file type, then drives the conversion of every CC source file to conform to that specification.

The initiative has two outputs:

1. **A complete, opinionated specification** that defines exactly how every CC source file must be structured, with no allowance for stylistic drift. The cataloging parser commits to extracting cleanly from any conforming file.
2. **A converted codebase** where every existing source file has been refactored to conform to the spec.

The Asset_Registry catalog is both the verification mechanism (does the parser see what the spec says it should see?) and the visible measure of progress (catalog completeness grows as files convert; drift codes shrink as files are refactored).

When this work is complete, this document and its peers in `Planning/` migrate to comprehensive HTML guide pages on the Control Center documentation site. The working documents themselves retire to `Legacy/`.

---

## Documents this consolidates

- `CC_FileFormat_Spec.md` (v0.2) — first-pass spec from April 2026. Content folds into this doc as we progress; original retires to `Legacy/` once obsolete.
- `CC_FileFormat_Parser_Friendly_Conventions_Recommendations.md` — observations from earlier parser work. Content folds into the relevant per-file-type sections of this doc; original retires to `Legacy/` once obsolete.

The `CC_Chrome_Standardization_Plan.md` is a related but distinct effort focused on visual/structural alignment of the page chrome. It stays in active execution as its own document. This format spec work and the chrome work share no dependency in either direction.

---

## Session Start Protocol

**If you are Claude starting a new session on this initiative, do exactly this in order. Do not ask Dirk to re-establish context that is captured below.**

1. Dirk provides a cache-busted manifest URL at session start (`https://raw.githubusercontent.com/tnjazzgrass/xFACts/main/manifest.json?v=<value>`). Fetch it.
2. From the top-level manifest, locate `manifest-documentation.json` and fetch it.
3. From the documentation manifest, locate the `raw_url` for `xFACts-Documentation/Planning/CC_FileFormat_Standardization.md` (this document) and fetch it.
4. Read the "Current State" subsection immediately below this protocol. That paragraph contains everything needed to know where work stands.
5. Read whichever file-type section is named as active in Current State.
6. Begin work in that section. Honor any "Blocked on" or "Queued next" items in Current State.

**Authoritative source rule:** This document is authoritative. If anything in Project Knowledge or Claude's memory contradicts what is written here, this document wins. Project Knowledge is summarized periodically and may lag the doc by a session or more. The doc reflects the most recent session-end state.

**End-of-session discipline:** Before ending any session that touches this initiative, Claude updates Current State (below) and adds an entry to the Session Log. This is not optional — the protocol only works if Current State is kept current.

### Current State

*Last updated: 2026-05-03 (end of session — first parser run complete).*

**Active section:** Part 3 - CSS Files. Status `[DRAFT]`. Spec written, parser updated and run successfully against the codebase. Validation pass on a representative file is queued for next session.

**Last decisions made this session:**
- Asset_Registry catalog model finalized. New columns: `variant_type`, `variant_qualifier_1`, `variant_qualifier_2`, `drift_codes`, `drift_text`. Dropped columns: `state_modifier`, `component_subtype`, `parent_object`, `first_parsed_dttm`. Net column count: -4 / +5. Variant qualifier columns are generic and serve all file types — per-file-type meaning is documented in Object_Metadata when each format spec finalizes.
- Variants get their own catalog rows, not JSON aggregation on a parent. The leftmost-class rule means `parent_name` is redundant with `component_name`, so no `parent_name` column was added.
- CSS spec finalized: 5-line strict banner format, 78-char rules, mandatory descriptions, mandatory `Prefixes:` line. Five enumerated section types in fixed order: FOUNDATION, CHROME, LAYOUT, CONTENT, OVERRIDES. Each file conforms to one ruleset (no per-file-type variation).
- Forbidden CSS constructs: grouped selectors, descendant/child/sibling combinators, ID-scoped selectors, attribute selectors, element-only selectors, universal `*`, compound depth ≥ 3, pseudo-class interleaved with classes, hex literals where a custom property exists, `@import`, `@font-face`, `@media`, `@supports`, comments other than per-class purpose comments and sub-section markers.
- Custom properties (`--name: value`) and `@keyframes` are mandatory mechanisms for value reuse and animation reuse, defined only in the file containing FOUNDATION, consumed everywhere else.
- File header CHANGELOG block forbidden — version tracked in `dbo.System_Metadata`, file changes tracked in git.
- Spec compliance is binary per file (PASS / FAIL) with all FAIL rows carrying drift codes. No severity levels — every rule is mandatory.
- New component types: `CSS_VARIANT` for class variants (variant_type IS NOT NULL) and `FILE_HEADER` for the file-header-block row (one per scanned file).
- Schema migration approach: DROP + CREATE rather than ALTER, since existing data is discarded under truncate-and-reload anyway.
- Indexes start with reasonable defaults: PK on `asset_id`, `(file_type, file_name)`, `(component_type, component_name)`, `(scope, source_file)`, plus filtered index on `drift_codes WHERE drift_codes IS NOT NULL`. Will iterate based on observed query patterns.

**This session produced:**
- Updated `CC_FileFormat_Standardization.md` (this file) with new Part 2 (Asset_Registry Catalog Model) and Part 3 (CSS Files), Appendix A (drift codes reference), and renumbered Parts 4-10.
- Schema migration script (`Migrate_Asset_Registry.sql`) — drops and recreates `dbo.Asset_Registry` with the new shape.
- Component_type CHECK constraint update (`Update_Asset_Registry_ComponentType_Constraint.sql`) — adds `CSS_VARIANT` and `FILE_HEADER` to the allowed values.
- Updated CSS populator (`Populate-AssetRegistry-CSS.ps1`) — variant emission, drift detection (32 distinct codes), FILE_HEADER row emission, three-pass execution model (shared collection → per-file walk → cross-file drift checks).
- First successful parser run: 5,913 rows produced, 87.1% with drift codes (5,150 of 5,913). Top drift codes match expected pattern: `MISSING_PURPOSE_COMMENT` (2,842), `DRIFT_HEX_LITERAL` (1,684), `FORBIDDEN_DESCENDANT` (1,377), `MISSING_VARIANT_COMMENT` (1,188), `MISSING_SECTION_BANNER` (670).

**Two parser bugs fixed during this session (both in the same run cycle):**
1. **Drift codes concatenated without delimiters.** PowerShell array-vs-string trap: when `-split` returned a single-element string instead of an array, `+=` did string concatenation rather than array append. Fixed by wrapping with `@(...)` to force array context. Side effect: dedupe check `-contains` was also broken because it was looking for the new code as a substring of the glued string. Same fix resolved both.
2. **Every file's header was being misidentified as a malformed banner.** Both file headers and section banners contain `=` rules, and `Get-BannerInfo` was matching headers as if they were banners. Fixed by having `Get-BannerInfo` early-return null when the comment contains header-specific markers (`Location:`, `Version:`, or the xFACts identity line).

**Queued next:** A sanity-sweep over the populated catalog after this session's first run surfaced both parser bugs and a spec gap. Next session priorities, in order:

1. **Parser bug fix pass** — bundle these into one `Populate-AssetRegistry-CSS.ps1` update:
   - Forbidden-selector drift codes (`FORBIDDEN_UNIVERSAL_SELECTOR`, `FORBIDDEN_ELEMENT_SELECTOR`, `FORBIDDEN_ATTRIBUTE_SELECTOR`) intermittently fail to attach to `CSS_RULE` rows. 30 of 91 CSS_RULE rows are missing their forbidden-construct codes. Investigate the no-class branch of `Add-RowsForSelector` (the `Where-Object` evaluation) and the `Get-CompoundList` rewrite output shape.
   - `COMPOUND_DEPTH_3PLUS` skipped on descendant compounds. 4 rows where depth-3 modifiers (`q1='det.off'`, `q1='esc.off'`, etc.) appear in a descendant compound — drift attribution only fires on the primary compound today.
   - ID + class compounds emit only the class variant row, dropping the HTML_ID row. When `#foo.bar.baz` is the primary, only the `bar` variant row is emitted; the `#foo` id should also get its own HTML_ID row for catalog completeness.
   - **Shared-scope resolution conflates Control Center and documentation zones.** Today's `$sharedClassMap` is one global dictionary shared across both zones. Result: page-CSS USAGE rows (e.g., backup.css's `.status-card .card-content`) wrongly resolve to `docs-reference.css` because the docs zone happens to define a class with the same name. Architectural fix: split into `$ccSharedClassMap` (consumer pool: CC pages; source: `engine-events.css` only) and `$docsSharedClassMap` (consumer pool: docs pages; source: `docs-*.css`). Same split for the variable and keyframe maps. Resolve based on the consumer file's zone (derivable from filepath: `\public\docs\css\` → docs zone, otherwise CC zone). Affects ~25 USAGE rows in the current data; will fall through to LOCAL with source_file=consumer when the corrected resolver finds no match.
   - **`raw_text` should capture the full rule body, not just the selector.** Today, `raw_text` for CSS_CLASS rows duplicates the `signature` (the selector text). It's much more useful for downstream queries — particularly Q1 follow-up, where comparing two definitions requires comparing their declarations — if `raw_text` holds the entire rule including the declarations between `{` and `}`. Same applies to CSS_VARIANT and CSS_RULE rows. (CSS_VARIABLE, CSS_KEYFRAME, COMMENT_BANNER, and FILE_HEADER rows already use `raw_text` correctly.)

2. **Spec discussion: `:not()` and stacked pseudo-classes.** 13 rows produce malformed `variant_qualifier_2` values like `not:hover`, `hover:not`, `hover:not:not`. Real cases include `.svc-btn.svc-stop:not(:disabled):hover`, `.nav-btn:hover:not(:disabled)`, `.dm-server-btn:hover:not(.active):not(:disabled)`. The current spec did not address (a) whether `:not()` is allowed at all, (b) whether multiple pseudo-classes can stack on a single selector, or (c) if either is allowed, how the parser should catalog them in the two-qualifier-slot model. Two paths: forbid both (replaceable with class modifiers; simpler spec, more rewrites; tag with `FORBIDDEN_NOT_PSEUDO` and `FORBIDDEN_STACKED_PSEUDO`) or allow them with a cataloging extension (third qualifier, JSON shape, or documented multi-pseudo separator).

3. **Validation pass on one representative CSS file** — query Asset_Registry for that file's rows → manual audit → rewrite to spec → re-run parser → confirm clean. Suggested file: `client-relations.css` (small, 81 rows) or `bidata-monitoring.css` (181 rows, more representative). This validates the spec end-to-end against real data and promotes Part 3 from `[DRAFT]` to `[FINALIZED]`.

This validation proves the spec and parser are accurate before scaling conversion to all 27 files.

**Important framing for the consolidation initiative:** Part 9.1 documents an asymmetry that emerged from end-of-session discussion. The CSS catalog can today **detect** chrome consolidation candidates (via Q1: things already shared but reinvented locally; via Q5: things repeated locally and consolidatable to shared). It cannot yet **verify** that a consolidation actually worked, because verification requires USAGE rows showing a page consuming the shared definition through its HTML — and HTML parsing is Part 5/7, not yet built. Practical implication: actual consolidation work should wait until the HTML parser exists. Until then, detection queries are useful for planning but consolidation steps lack a deterministic catalog signature for the after-state.

**Blocked on:** Nothing.

---

## How to use this document

### Status markers

Each major section carries a status marker showing where it is in the lifecycle:

| Marker | Meaning |
|---|---|
| `[OUTLINE]` | Section exists as a placeholder. No content drafted yet. |
| `[IN DISCUSSION]` | Active design discussion. Decisions being made; content in flux. |
| `[DRAFT]` | Decisions made and written down. Spec content present. Not yet locked in — may shift as real data surfaces issues. |
| `[FINALIZED]` | Section is complete, locked, and ready for the eventual HTML guide migration. |

### Decision logs

Every per-file-type section has a "Decision Log" subsection. Decisions land there as they're made, with date, brief rationale, and any options considered but rejected. This captures *why* a rule exists, which matters when revisiting later.

### Illustrative examples

Where this document includes example code (a complete CSS file, a sample function declaration, etc.), the examples are illustrative — they show the spec applied. **The spec text is authoritative.** If an example and the spec text disagree, the example is wrong and gets corrected.

### Forbidden patterns

Each file-type section enumerates explicit forbidden patterns alongside the required ones. The format is "Don't do X — do Y instead." The forbidden examples are as important as the required ones, because they make implicit rules explicit.

### Drift codes

Each file-type section enumerates the drift codes the parser emits when it encounters spec violations in that file type. A drift code is a stable short identifier (e.g., `FORBIDDEN_DESCENDANT`, `MISSING_PURPOSE_COMMENT`) used in SQL queries to surface specific kinds of non-conformance. Human-readable descriptions of every code live in Appendix A.

---

## Session log

A running log of progress across sessions. Each session adds a dated entry describing what was decided, what was drafted, and what's queued next.

| Date | Activity |
|---|---|
| 2026-05-02 | Document created. Scaffold and structure established with nine major parts. Session Start Protocol and Current State sections added. Status marker conventions defined. Decision-log pattern established. Discussion order set: CSS first, then JS, PS route files, PS module files, documentation HTML. CSS section queued for next session. |
| 2026-05-03 | CSS spec design discussion completed end-to-end. Q1-Q30 decisions captured. Asset_Registry catalog model finalized (Part 2): variants as own rows, generic qualifier columns, no `parent_name`, drift annotation via `drift_codes`/`drift_text`. CSS spec drafted (Part 3): five section types in fixed order, mandatory `Prefixes:` line in banners, three variant shapes, full forbidden-pattern list, illustrative example, parser-extraction reference. Appendix A (32 drift codes with descriptions) added. Old Parts 3-9 renumbered to 4-10. Schema migration executed: `dbo.Asset_Registry` dropped and recreated with new shape. CHECK constraint updated to include `CSS_VARIANT` and `FILE_HEADER` component types. Parser rewritten: variant emission, inline drift detection (32 codes), FILE_HEADER row per file, three-pass execution. **Two bugs found and fixed during runs:** (1) drift codes concatenated without delimiters (PowerShell `-split`-then-`+=` returned string instead of array); (2) file headers misidentified as malformed banners. First successful clean run: 5,913 rows, 87.1% drift coverage. Drift code distribution validated: top 5 codes match design expectations. **Sanity sweep over the populated catalog surfaced four issues for next session:** (a) forbidden-selector drift codes intermittently fail to attach to CSS_RULE rows (30 of 91 affected); (b) `COMPOUND_DEPTH_3PLUS` skipped on descendant compounds (4 cases); (c) ID + class compounds drop the HTML_ID row when both are present in the primary compound; (d) `$sharedClassMap` conflates Control Center and documentation zones, producing ~25 wrongly-resolved USAGE rows that point CC files at docs source files; (e) `raw_text` for class/variant rows duplicates the selector instead of capturing the full rule body — limits Q1 follow-up review. **One spec gap surfaced:** `:not()` and stacked pseudo-classes (13 cases) aren't representable in the two-qualifier-slot model — needs a forbid-or-extend decision next session. Documented as OQ-CSS-1 in Part 10. Clarifying note added to Part 3.14 about where chrome consumption shows up in the catalog. **Part 8 (Compliance Reporting) populated with five standard queries** — the chrome-consolidation candidates query (Q1, "things shared and reinvented locally") and the promotion-to-shared candidates query (Q5, "things repeated locally that should be promoted") together address both halves of the chrome standardization work. Real-data run found 33 Q1 collisions and a similar-shape set of Q5 candidates. Part 8 status bumped from `[OUTLINE]` to `[DRAFT]`. **Part 9.1 (detection-vs-verification asymmetry) added** to capture the end-of-session realization: detection works today from CSS data alone, but verification of consolidation requires the HTML-side parser. Practical implication: actual consolidation work should wait until Parts 5/7 (HTML parsing) are built. **OQ-CSS-2 added** to Part 10 documenting the same-functionality-different-names grouping problem (e.g., `.refresh-info` vs `.update-text` vs `.last-updated-display` for the same conceptual element). Originally `component_subtype` was envisioned for this purpose but was never populated and was dropped in the v0.2 migration. Several solution shapes outlined (manual annotations table, heuristic auto-grouping, property-body similarity, JSON tags); decision deferred until chrome standardization begins. |

---

## Part 1 - Universal Conventions  `[OUTLINE]`

Conventions that apply to every file type. Will be filled in as we work through individual file types — universal rules emerge from the per-file-type discussions and get promoted up to this section.

### 1.1 File header block

(To be filled in once two or more file-type specs are drafted and patterns can be promoted.)

### 1.2 Section banners

(To be filled in once two or more file-type specs are drafted and patterns can be promoted.)

### 1.3 Sub-section markers

(To be filled in once two or more file-type specs are drafted and patterns can be promoted.)

### 1.4 File encoding and line endings

(To be filled in once two or more file-type specs are drafted and patterns can be promoted.)

### 1.5 Decision log

(Decisions affecting universal conventions land here.)

---

## Part 2 - Asset_Registry Catalog Model  `[DRAFT]`

The Asset_Registry table is the parser's output and the queryable source of truth for every component the parser extracts from CC source files. Decisions about its shape outlive any single file-type spec; this section captures those decisions independent of CSS, JS, PowerShell, or any other format.

### 2.1 What the catalog represents

Every cataloged construct gets one row in `dbo.Asset_Registry`. A row's identity is described by the combination of `component_type`, `component_name`, `reference_type`, `file_name`, and `occurrence_index`. The parser populates one row per definition or usage instance found while walking source files.

The catalog is the answer to questions like: "where is `.engine-card` defined?", "which pages use the shared `xfModalConfirm` function?", "how many pages have a hover variant of their primary button class?", "which CSS files contain spec drift today, and of what kinds?". Every such question becomes a SQL query against this table — no joins, no JSON parsing, no string heuristics.

### 2.2 Column shape

The complete column list, after the schema migration that accompanies this spec:

| Column | Type | Purpose |
|---|---|---|
| `asset_id` | INT IDENTITY PK | Surrogate key. Not stable across truncate+reload. |
| `file_name` | VARCHAR(200) | The file in which the catalog row was emitted. |
| `object_registry_id` | INT NULL | FK to `dbo.Object_Registry` for the source file. |
| `file_type` | VARCHAR(10) | `CSS`, `JS`, `PS`, `HTML`. |
| `line_start` | INT | First line of the construct in the source file. |
| `line_end` | INT NULL | Last line of the construct. |
| `column_start` | INT NULL | Column position of the construct's first character. |
| `component_type` | VARCHAR(20) | The kind of construct (`CSS_CLASS`, `CSS_KEYFRAME`, `COMMENT_BANNER`, etc.). Controlled vocabulary; see Section 2.3. |
| `component_name` | VARCHAR(256) NULL | The construct's name. For variants, this is the parent class's name (per the leftmost-class rule); the variant qualifiers live in `variant_qualifier_1` and `variant_qualifier_2`. |
| `variant_type` | VARCHAR(30) NULL | The kind of variant relationship this row represents, when applicable. NULL for base components. Controlled vocabulary; see Section 2.4. |
| `variant_qualifier_1` | VARCHAR(100) NULL | First qualifier slot. Per-file-type meaning documented in each spec. |
| `variant_qualifier_2` | VARCHAR(100) NULL | Second qualifier slot. Per-file-type meaning documented in each spec. |
| `reference_type` | VARCHAR(20) | `DEFINITION` or `USAGE`. |
| `scope` | VARCHAR(20) | `SHARED` or `LOCAL`. |
| `source_file` | VARCHAR(200) | Where the construct is defined (may differ from `file_name` for USAGE rows). |
| `source_section` | VARCHAR(150) NULL | The section banner title under which the construct lives. |
| `signature` | VARCHAR(MAX) NULL | The full source text of the construct's identifier (full selector for CSS, function signature for JS, etc.). |
| `parent_function` | VARCHAR(200) NULL | When a construct lives inside a wrapping construct (e.g., a CSS rule inside `@media (max-width: 768px)`, a JS function nested in another function), the wrapper's identifier. |
| `raw_text` | VARCHAR(MAX) NULL | The full raw source snippet of the construct. |
| `purpose_description` | VARCHAR(MAX) NULL | Human-readable description extracted by the parser from the construct's preceding comment. |
| `design_notes` | VARCHAR(MAX) NULL | Manual annotation slot (not parser-populated). |
| `related_asset_id` | INT NULL | Self-FK for explicit cross-references (not parser-populated). |
| `occurrence_index` | INT NOT NULL DEFAULT 1 | 1-based ordinal disambiguator when multiple instances of the same `(file_name, component_type, component_name, reference_type)` tuple appear. |
| `drift_codes` | VARCHAR(500) NULL | Comma-separated list of stable short codes naming every spec deviation observed for this row. NULL when the row is fully spec-compliant. |
| `drift_text` | VARCHAR(MAX) NULL | Human-readable joined descriptions of every drift code in `drift_codes`. NULL when `drift_codes` is NULL. |
| `is_active` | BIT NOT NULL DEFAULT 1 | Manual deactivation flag. The parser always writes 1; manual review may set it to 0 to exclude noise. |
| `last_parsed_dttm` | DATETIME2(7) | Set by the parser. |

### 2.3 component_type controlled vocabulary

A component_type is the parser's classification of what kind of construct produced the row. Each file-type spec adds the values it produces. CSS-specific values appear in Part 3. The full controlled vocabulary will assemble as later file-type specs are added.

CSS component types (from Part 3):

| component_type | Meaning |
|---|---|
| `FILE_HEADER` | The file's header block. One row per scanned file. Carries header-level drift codes and serves as the "this file was scanned" anchor regardless of what else the file contains. |
| `CSS_CLASS` | A class definition (`.foo { ... }`). |
| `CSS_VARIANT` | A class variant definition — a row whose selector compounds the parent class with additional class or pseudo-class qualifiers. The `component_name` is the parent's class name; qualifiers live in `variant_qualifier_1` / `variant_qualifier_2`. |
| `CSS_KEYFRAME` | An `@keyframes` definition or a reference. |
| `CSS_VARIABLE` | A custom property definition (`--name: value`) or a `var(--name)` reference. |
| `CSS_RULE` | A rule with no class, no id, and no keyframe — e.g., `body { ... }`, `* { ... }`, `[type="radio"] { ... }`. These are forbidden by the spec but cataloged for visibility into drift. |
| `HTML_ID` | An `#id` selector defined in a CSS file. |
| `COMMENT_BANNER` | A section banner comment. |

### 2.4 variant_type controlled vocabulary

The `variant_type` column discriminates what the variant qualifier columns mean for a given row. It is NULL for base components (rows that are not variants of anything). When non-NULL, the meaning of `variant_qualifier_1` and `variant_qualifier_2` is determined by `variant_type`.

CSS variant types (from Part 3):

| variant_type | qualifier_1 | qualifier_2 | Example selector |
|---|---|---|---|
| `class` | The compound class | (NULL) | `.btn.disabled` → qualifier_1 = `disabled` |
| `pseudo` | (NULL) | The pseudo-class name | `.btn:hover` → qualifier_2 = `hover` |
| `compound_pseudo` | The compound class | The pseudo-class | `.btn.disabled:hover` → qualifier_1 = `disabled`, qualifier_2 = `hover` |

Future file-type specs will add their own variant types. Examples reserved for later definition: `method` (JS namespace methods), `parameter_set` (PowerShell function parameter sets), `filter` (SQL view filtered variants).

### 2.5 Variants as their own rows

Every variant is its own catalog row, not a sub-record of a parent. A class with three variants produces four rows total: one base + three variants. This applies regardless of file type.

The parent-child relationship is implicit through `component_name`. Per the leftmost-class rule (CSS) and equivalent rules in other file types, both a base and its variants share the same `component_name` value. The discriminator is `variant_type`:

- Base row: `component_name = 'btn'`, `variant_type = NULL`
- Variant rows: `component_name = 'btn'`, `variant_type = 'class' | 'pseudo' | 'compound_pseudo'`

This makes "find all variants of X" a single-clause query: `WHERE component_name = 'X' AND variant_type IS NOT NULL`. No joins, no JSON parsing.

### 2.6 Drift recording

The parser evaluates every row against the relevant file-type spec and records two things when the row deviates:

- `drift_codes` — comma-separated list of stable short codes (e.g., `FORBIDDEN_DESCENDANT,COMPOUND_DEPTH_3PLUS`)
- `drift_text` — joined human-readable descriptions corresponding to each code

A row may carry zero, one, or many drift codes. Both columns are NULL when the row is fully spec-compliant. Empty strings are treated as NULL — the absence of drift is always NULL, never the empty string.

The full code-to-description mapping for CSS is in Appendix A. Future file-type specs add their own codes to the appendix.

### 2.7 What was removed

Four columns were removed during the schema migration that accompanies this spec:

- `state_modifier` — replaced by the explicit `variant_type` + `variant_qualifier_1` + `variant_qualifier_2` triple. The old column comma-joined multiple modifiers and never captured pseudo-classes.
- `component_subtype` — described in DDL as "manual; for finer typing." Never populated by any parser; redundant with `component_type` and `variant_type` together.
- `parent_object` — described in DDL as "manual; for cross-refs." Never populated by any parser; redundant with `component_name` under the leftmost-class rule.
- `first_parsed_dttm` — vestigial. Originated under an earlier MERGE-based refresh strategy where the column distinguished "row's first appearance" from "row's most recent appearance." Under the current truncate-and-reload model both timestamps would always be equal on every row; only `last_parsed_dttm` survives.

`parent_function` was retained because it captures wrapping-construct context (e.g., `@media` query, nested function) that is genuinely distinct from the variant relationship.

### 2.8 Decision log

| Date | Decision | Reasoning |
|---|---|---|
| 2026-05-03 | Variants get their own rows (not JSON aggregation on parent). | SQL queries become trivial column filters. No JSON parsing. Adding a new variant inserts a new row instead of mutating an existing one. |
| 2026-05-03 | No `parent_name` column. | Empirical analysis of 4,964 catalog rows showed every divergence between leftmost-class and component_name was caused by selectors that are now spec-forbidden (descendants, groups, sibling combinators). After spec conformance, the columns are always identical — the column is pure redundancy. |
| 2026-05-03 | Generic `variant_qualifier_1` / `variant_qualifier_2` instead of file-type-specific column names. | Two slots cover every variant relationship across CSS, JS, PowerShell, and SQL examined to date. Per-file-type meaning is documented in Object_Metadata when each format spec finalizes. Avoids per-file-type column proliferation. |
| 2026-05-03 | `variant_type` column name (rejected: `variant_kind`). | Consistent with `component_type`, `reference_type`, `file_type` naming convention already in the table. |
| 2026-05-03 | Drift codes split into two columns (`drift_codes`, `drift_text`). | Codes are machine-friendly and queryable; text is human-readable for reports and audits. Both can be NULL together for clean rows. |
| 2026-05-03 | Column name `drift_codes` (rejected: `violations`, `spec_findings`, `compliance_codes`). | "Drift" matches existing platform vocabulary (Asset_Registry's stated purpose includes "drift detection"). Less judgmental than "violations"; more concrete than "findings". |
| 2026-05-03 | Drop `state_modifier`, `component_subtype`, `parent_object`. | Replaced or redundant under the new model. |
| 2026-05-03 | Keep `parent_function`. | Captures wrapping-construct context (e.g., `@media`, nested function) — genuinely distinct from variant relationship. |
| 2026-05-03 | No `Object_Metadata` rows for the new columns yet. | Catalog model expected to iterate as JS/PS/HTML specs reveal new variant patterns. Defer Object_Metadata population until shape stabilizes across all file types. |
| 2026-05-03 | Drop `first_parsed_dttm`. | Made sense under MERGE-based refresh where it distinguished first vs last seen. Under truncate-and-reload it equals `last_parsed_dttm` on every row — pure redundancy. |
| 2026-05-03 | Migration via DROP + CREATE rather than ALTER TABLE. | Single coherent operation; no order-of-operations risk between drops and adds. Existing data is being thrown away anyway under the truncate-and-reload model, so no preservation requirement. |
| 2026-05-03 | Indexes start with reasonable defaults rather than matching the existing set. | Table is small and usage patterns will only become clear once all file types are cataloged. Easier to add indexes against observed query pain than to predict them upfront. Defaults: PK on `asset_id`, indexes on `(file_type, file_name)`, `(component_type, component_name)`, `(scope, source_file)`, plus a filtered index on `drift_codes WHERE drift_codes IS NOT NULL`. |

---

## Part 3 - CSS Files  `[DRAFT]`

### 3.1 Required structure

A CSS file consists of three parts in this order, with no other content allowed at file scope:

1. **File header** — a single block comment opening at line 1, ending with `*/` followed by exactly one blank line.
2. **Section bodies** — one or more sections, each consisting of a section banner followed by class definitions and optional sub-section markers.
3. **End-of-file** — the file ends after the last `}` of the last section's last rule. No trailing content.

There is no other content category. Every line of code in the file lives inside exactly one of these three parts.

### 3.2 File header

The header is a single block comment at the very top of the file. Every field is mandatory and appears in this exact order:

```
/* ============================================================================
   xFACts Control Center - <Component Description> (<filename>)
   Location: E:\xFACts-ControlCenter\public\css\<filename>
   Version: Tracked in dbo.System_Metadata (component: <Component>)

   <Purpose paragraph: 1 to 5 sentences describing what this file is.>

   FILE ORGANIZATION
   -----------------
   1. <Section title>
   2. <Section title>
   N. <Section title>
   ============================================================================ */
```

Notes:

- The header is the only construct that may appear before the first section banner. Anything else above the first banner (including stray comments, blank lines beyond the single mandatory blank, or rules) is a parse error.
- The closing `*/` is followed by **exactly one** blank line, then the first section banner.
- The Component Description and Component values come from `dbo.System_Metadata` and `dbo.Component_Registry` respectively. The parser extracts them as `purpose_description` (Component Description) and uses Component for cross-reference validation.
- The FILE ORGANIZATION list enumerates section banner titles in the order they appear in the file. The parser cross-validates this list against the actual banners; mismatches produce drift codes.
- **No CHANGELOG block.** Version is tracked in `dbo.System_Metadata`; file-level change history is tracked in git. Including a CHANGELOG block in any CSS file header is a parse error.

### 3.3 Section banners

Every section in the file begins with a banner comment in this exact 5-line format:

```
/* ============================================================================
   <TYPE>: <NAME>
   ----------------------------------------------------------------------------
   <Description: 1+ non-blank lines explaining what this section contains.>
   Prefixes: <prefix1>[, <prefix2>, <prefix3>]
   ============================================================================ */
```

Banner format rules:

- Two horizontal rules are 78 `=` characters; the middle rule is 78 `-` characters. Exactly. No more, no fewer.
- The TYPE is one of the five enumerated section types (Section 3.4) — uppercase A-Z and underscores only.
- The NAME is descriptive free text — uppercase A-Z, digits, spaces, colons, parentheses, and ASCII hyphens are allowed. No special characters or Unicode.
- The description block has at least one non-blank line. Multi-line descriptions are allowed. The line "Prefixes: ..." is part of the description block and is mandatory; it must be the last non-blank line of the description block.
- "Prefixes:" lists one to four allowed class-name prefixes for the section, comma-separated. Every class definition in the section must begin with one of these prefixes followed by a hyphen. The prefix list is matched case-sensitive.

### 3.4 Section types

A CSS file's sections are drawn from a fixed enumerated list of types. Section types appear in this order in the file (sections of types not present in the file are skipped):

| Type | Purpose | Where allowed |
|---|---|---|
| `FOUNDATION` | CSS reset rules, custom property definitions (`--name: value`), `@keyframes` definitions. The shared building blocks every page consumes. | Allowed in any CSS file, but the spec requires that exactly one CSS file in the codebase contains a FOUNDATION section. |
| `CHROME` | Styles for chrome elements that appear on every page (nav bar, header bar, page-refresh badge, connection banner). | Allowed in any CSS file, but the spec requires that exactly one CSS file in the codebase contains a CHROME section. By convention, the same file holds both FOUNDATION and CHROME. |
| `LAYOUT` | Page-level structural rules — page body container, section dividers, primary grid containers. | Any CSS file. |
| `CONTENT` | The bulk of a page's classes — interactive components, panels, modals, status indicators. A file may contain multiple CONTENT sections, each with a distinct NAME. | Any CSS file. |
| `OVERRIDES` | Page-specific specificity bumps over shared chrome rules. Should ideally be empty post-conversion; exists as a transitional escape valve while pages still need to override shared rules they cannot otherwise reach. | Any CSS file. |

Type ordering is rigid: FOUNDATION → CHROME → LAYOUT → CONTENT → OVERRIDES. Sections within a type (e.g., multiple CONTENT sections) are author-ordered.

### 3.5 Class definitions

Every class definition follows this exact shape:

```css
/* <Single-line purpose description.> */
.<class-name> {
    <property>: <value>;
    <property>: <value>;
}
```

Rules:

- The selector and opening brace are on the same line, separated by a single space.
- Every class definition is preceded by a single-line block comment describing its purpose. The comment is on the line immediately above the selector with no blank line between them.
- Each declaration is on its own line. Compound declarations (`padding: 4px; margin: 2px;` on one line) are forbidden.
- The closing brace is on its own line, no other content on it.
- The class name follows the section's declared `Prefixes:` — it must start with one of the listed prefixes followed by a hyphen.

### 3.6 Variants

A variant of a class shares the parent's `component_name` and discriminates via `variant_type`. The selector forms allowed for variants:

```css
.btn.disabled { /* button when in disabled state */
    opacity: 0.4;
}

.btn:hover { /* hover state for the button */
    background: var(--color-bg-hover);
}

.btn.disabled:hover { /* hover state when disabled */
    background: var(--color-bg-disabled);
}
```

Variant rules:

- Variants do **not** require a preceding purpose comment. Instead, they carry a **trailing inline comment** on the selector line, immediately after the opening `{`. The trailing comment describes the variant.
- The trailing comment populates `purpose_description` for the variant row.
- Variants follow the same brace/declaration rules as base classes.

Three variant shapes are allowed:

| Shape | variant_type | qualifier_1 | qualifier_2 |
|---|---|---|---|
| `.parent.modifier` | `class` | `modifier` | NULL |
| `.parent:pseudo` | `pseudo` | NULL | `pseudo` |
| `.parent.modifier:pseudo` | `compound_pseudo` | `modifier` | `pseudo` |

### 3.7 Sub-section markers

Within a section, an optional sub-section marker may break up groups of related rules:

```css
/* -- <descriptive label> -- */
```

Rules:

- Format is exactly: opening `/*`, single space, two hyphens, single space, label text, single space, two hyphens, single space, closing `*/`.
- On its own line. No content before or after on the same line.
- Sub-section markers do not nest. There is one level of sub-section.
- Sub-section markers are not cataloged into Asset_Registry — they are read-time visual aids for humans, ignored by the parser for row emission.

### 3.8 Comments

Only four kinds of comments are allowed in a CSS file:

1. The file header (Section 3.2)
2. Section banners (Section 3.3)
3. Per-class purpose comments (Section 3.5) and trailing variant comments (Section 3.6)
4. Sub-section markers (Section 3.7)

Any other comment style — decorative borders, mid-rule comments, "TODO" notes, multi-line notes between rules — is forbidden. The parser flags them with `FORBIDDEN_COMMENT_STYLE`.

### 3.9 Custom properties

Custom properties are CSS-level constants:

```css
--color-accent: #4ec9b0;
```

Rules:

- All custom property definitions live in the FOUNDATION section, declared on a single `:root` rule.
- Page CSS files reference custom properties (`var(--color-accent)`) but never define them.
- Any value that appears in two or more rules anywhere in the codebase **must** be defined as a custom property and referenced via `var(...)`. Hex literals, fixed pixel sizes, animation durations, breakpoints, and similar values fall under this rule.
- Hex literals are allowed only in the custom property's definition itself. Inside any class definition, a hex literal where a custom property exists is `DRIFT_HEX_LITERAL`.

### 3.10 @keyframes

Animation recipes:

```css
@keyframes pulse {
    0%, 100% { opacity: 1; }
    50%      { opacity: 0.5; }
}
```

Rules:

- All `@keyframes` definitions live in the FOUNDATION section.
- Page CSS files reference keyframes via the `animation` or `animation-name` properties but never define them.
- Each `@keyframes` is preceded by a single-line purpose comment, same convention as classes.

### 3.11 Required patterns summary

Every CSS file must contain:

- A header block per Section 3.2.
- One or more section banners per Section 3.3, types drawn from Section 3.4 in fixed order.
- Class definitions per Section 3.5.
- Variants in one of the three allowed shapes per Section 3.6.
- Custom property usage (`var(...)`) wherever a value would repeat per Section 3.9.

The CSS file containing the FOUNDATION section additionally contains custom property definitions and `@keyframes` definitions per Sections 3.9 and 3.10.

### 3.12 Forbidden patterns

The parser flags every occurrence of the following with the named drift code (full descriptions in Appendix A):

| Pattern | Drift code |
|---|---|
| Element-only selector (`body`, `h1`, `a`) | `FORBIDDEN_ELEMENT_SELECTOR` |
| Universal selector (`*`) | `FORBIDDEN_UNIVERSAL_SELECTOR` |
| Attribute selector (`[type="radio"]`) | `FORBIDDEN_ATTRIBUTE_SELECTOR` |
| ID selector (`#foo`) or ID-scoped selector (`#foo.bar`) | `FORBIDDEN_ID_SELECTOR` |
| Grouped selector (`.foo, .bar`) | `FORBIDDEN_GROUP_SELECTOR` |
| Descendant selector (`.foo .bar`) | `FORBIDDEN_DESCENDANT` |
| Child selector (`.foo > .bar`) | `FORBIDDEN_CHILD_COMBINATOR` |
| Sibling selector (`.foo + .bar`, `.foo ~ .bar`) | `FORBIDDEN_SIBLING_COMBINATOR` |
| Compound selector with depth ≥ 3 (`.foo.bar.baz`) | `COMPOUND_DEPTH_3PLUS` |
| Pseudo-class interleaved with classes (`.foo:hover.bar`) | `PSEUDO_INTERLEAVED` |
| `@import` rule | `FORBIDDEN_AT_IMPORT` |
| `@font-face` rule | `FORBIDDEN_AT_FONT_FACE` |
| `@media` rule | `FORBIDDEN_AT_MEDIA` |
| `@supports` rule | `FORBIDDEN_AT_SUPPORTS` |
| `@keyframes` outside the FOUNDATION section | `FORBIDDEN_KEYFRAMES_LOCATION` |
| Custom property definition outside FOUNDATION | `FORBIDDEN_CUSTOM_PROPERTY_LOCATION` |
| Hex literal where a custom property is defined | `DRIFT_HEX_LITERAL` |
| Comment style other than allowed kinds | `FORBIDDEN_COMMENT_STYLE` |
| Multiple declarations on a single line | `FORBIDDEN_COMPOUND_DECLARATION` |
| Class definition without preceding purpose comment | `MISSING_PURPOSE_COMMENT` |
| Variant without trailing comment | `MISSING_VARIANT_COMMENT` |
| Class name does not match a declared section prefix | `PREFIX_MISMATCH` |
| Class definition outside any banner | `MISSING_SECTION_BANNER` |
| Section banner missing `Prefixes:` line | `MISSING_PREFIXES_DECLARATION` |
| Section banner with malformed structure | `MALFORMED_SECTION_BANNER` |
| Section type not in the enumerated list | `UNKNOWN_SECTION_TYPE` |
| Section types out of required order | `SECTION_TYPE_ORDER_VIOLATION` |
| FILE ORGANIZATION list does not match section banners | `FILE_ORG_MISMATCH` |
| File header missing or malformed | `MALFORMED_FILE_HEADER` |
| File header CHANGELOG block present | `FORBIDDEN_CHANGELOG` |
| Blank line inside a class definition | `BLANK_LINE_INSIDE_RULE` |
| More than one blank line between top-level constructs | `EXCESS_BLANK_LINES` |
| Multiple FOUNDATION sections across the codebase | `DUPLICATE_FOUNDATION` |
| Multiple CHROME sections across the codebase | `DUPLICATE_CHROME` |

### 3.13 Illustrative example

A complete spec-compliant CSS file (page-level, no FOUNDATION):

```css
/* ============================================================================
   xFACts Control Center - Server Health Page Styles (server-health.css)
   Location: E:\xFACts-ControlCenter\public\css\server-health.css
   Version: Tracked in dbo.System_Metadata (component: ControlCenter.ServerHealth)

   Page-specific styles for the Server Health page. Renders the per-server
   status grid, the slide-out panels for transaction history and alert
   detail, and the configuration timeline visualization.

   FILE ORGANIZATION
   -----------------
   1. LAYOUT: Page Body
   2. CONTENT: Server Status Grid
   3. CONTENT: Transaction Slide Panel
   ============================================================================ */

/* ============================================================================
   LAYOUT: PAGE BODY
   ----------------------------------------------------------------------------
   The root flex column that holds the page header and the status grid below
   it. Sized to fill the viewport minus the global nav-bar height.
   Prefixes: sh
   ============================================================================ */

/* The root container for the Server Health page. */
.sh-page-body {
    display: flex;
    flex-direction: column;
    height: calc(100vh - var(--nav-bar-height));
    background: var(--color-bg-page);
}

/* ============================================================================
   CONTENT: SERVER STATUS GRID
   ----------------------------------------------------------------------------
   The grid of server status cards. Each card represents one server and shows
   its connection status, last-update timestamp, and any active alerts.
   Prefixes: sh
   ============================================================================ */

/* The grid container holding every server status card. */
.sh-status-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(240px, 1fr));
    gap: 12px;
    padding: 16px;
}

/* One server's status card. */
.sh-status-card {
    background: var(--color-bg-card);
    border: 1px solid var(--color-border-default);
    border-radius: 4px;
    padding: 12px;
}

.sh-status-card.alert { /* card when the server has an active alert */
    border-color: var(--color-border-alert);
    background: var(--color-bg-alert);
}

.sh-status-card.offline { /* card when the server is unreachable */
    opacity: 0.5;
}

.sh-status-card:hover { /* hover state for the card */
    border-color: var(--color-border-hover);
}

.sh-status-card.alert:hover { /* hover state when alert is active */
    border-color: var(--color-border-alert-hover);
}

/* ============================================================================
   CONTENT: TRANSACTION SLIDE PANEL
   ----------------------------------------------------------------------------
   The slide-out panel that displays transaction history when the user clicks
   a server card. Inherits the shared slide-panel chrome from FOUNDATION and
   adds page-specific content classes.
   Prefixes: sh
   ============================================================================ */

/* The header row inside the transaction slide panel. */
.sh-trans-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 12px 16px;
    border-bottom: 1px solid var(--color-border-default);
}

/* The body container for the transaction list. */
.sh-trans-body {
    flex: 1;
    overflow-y: auto;
    padding: 8px 16px;
}
```

### 3.14 What the parser extracts

For every spec-compliant CSS file the parser writes the following Asset_Registry rows:

| For every... | Row of type | component_name | Notes |
|---|---|---|---|
| Scanned file | `FILE_HEADER` DEFINITION | The filename | One row per file. Carries header-level drift codes (`MALFORMED_FILE_HEADER`, `FORBIDDEN_CHANGELOG`, `FILE_ORG_MISMATCH`) and serves as the file's anchor in the catalog regardless of what else the file contains. |
| Section banner | `COMMENT_BANNER` | The banner's NAME | Carries the section title to subsequent rows via `source_section`. Stores the section TYPE in `signature` for query convenience. |
| Custom property definition | `CSS_VARIABLE` DEFINITION | The property name (without `--`) | Only emitted from the FOUNDATION section. |
| Custom property reference | `CSS_VARIABLE` USAGE | The property name | One row per `var(--name)` reference inside any property value. |
| `@keyframes` definition | `CSS_KEYFRAME` DEFINITION | The keyframe name | Only from FOUNDATION. |
| `@keyframes` usage | `CSS_KEYFRAME` USAGE | The keyframe name | One row per name appearing in `animation` or `animation-name` property values. |
| Class definition (base) | `CSS_CLASS` DEFINITION | The class name | `variant_type` is NULL. |
| Class variant | `CSS_VARIANT` DEFINITION | The parent class's name | `variant_type` is `class`, `pseudo`, or `compound_pseudo`. Qualifiers populated. |
| Forbidden selector encountered | `CSS_RULE` DEFINITION (or `HTML_ID` for ID selectors) | NULL (CSS_RULE) or the id name (HTML_ID) | Cataloged for visibility into drift even though forbidden. Drift codes attached. |
| Comment | (none) | (none) | Comments are not cataloged as their own rows except for `COMMENT_BANNER` and `FILE_HEADER`. |

The parser does not suppress rows because of drift. Every construct in the source — compliant or not — produces its row. Drift codes annotate which rules each row participated in violating; the row itself stays in the catalog.

**Where chrome consumption appears in the catalog.** A common expectation when querying Asset_Registry is "show me the shared-chrome classes this page consumes." The catalog answers this question in two complementary ways:

- **Redefinition detection (CSS-side, available today).** Asking "is this page reinventing a class that's already defined as shared chrome?" is a single SQL query against the existing CSS rows: find every `CSS_CLASS` (or `CSS_VARIANT`) that has both a SHARED DEFINITION and one or more LOCAL DEFINITIONs across files. Each result is a candidate for chrome consolidation — the page should delete its local definition and use the shared one. The query lives in Part 8 as a standard report.
- **Consumption tracking (HTML/JS-side, later).** Asking "how many shared-chrome classes does this page actually use" requires the HTML-side parser (Part 5) and JS-side parser (Part 4), since pages consume chrome primarily through HTML class attributes (`class="xf-modal-overlay"`) rather than CSS selectors. Page CSS files generally do not reference shared classes via selectors except for the rare descendant-override case; that's why CSS_CLASS USAGE rows pointing at engine-events.css are scarce. Once the HTML-side parser is implemented, chrome-usage volume per page will be directly queryable.

The CSS-side parser only emits a SHARED USAGE row when a page's CSS selector explicitly references a shared class (e.g., a descendant selector like `.metrics-column .section`, where `.section` is defined in engine-events.css). These cases are rare by design — the shared infrastructure's whole purpose is to be consumed without redefinition.

### 3.15 Decision log

| Date | Decision | Reasoning |
|---|---|---|
| 2026-05-03 | 5-line strict banner format, 78-char rules. | Multi-line banner with fixed structure is the highest-signal, lowest-collision marker possible. Embedded description block forces useful section documentation. |
| 2026-05-03 | No section number in banner (Q2 Option A — position-based matching). | FILE ORGANIZATION list ordering provides the cross-validation. Less drift surface — author can't get banner number out of sync with FILE ORG entry. |
| 2026-05-03 | Five enumerated section types: FOUNDATION, CHROME, LAYOUT, CONTENT, OVERRIDES. | Three categories of buckets: shared (FOUNDATION + CHROME), structural (LAYOUT), content (CONTENT, repeatable), and transitional (OVERRIDES). Five is small enough to learn, large enough to fit observed real-world content. |
| 2026-05-03 | One file type, one ruleset. | Foundation/chrome sections are allowed in any file, but spec enforces they appear in exactly one file. Same rule applied uniformly is cleaner than two file-type variants. |
| 2026-05-03 | FOUNDATION must precede CHROME, LAYOUT, etc. (rigid type order). | Predictability at parse time and read time. Ordering within a type (multiple CONTENT sections) remains author-determined. |
| 2026-05-03 | Per-section prefix declaration mandatory; allow up to 4 prefixes per section. | Catalog data showed most sections naturally use a single prefix; some legitimate cases (year/month/day in BATCH HISTORY, multiple field types in MONITOR ROWS) need 2-4. Banner's `Prefixes:` line declares them; parser validates every class against the list. |
| 2026-05-03 | Compound depth ≥ 3 forbidden. Compound depth 2 allowed. | Catalog showed 20 occurrences of depth-3 compounds across 4,964 rows (0.4%). All twenty are restructurable into single-class or depth-2-compound forms. Catalog clarity payoff substantial. |
| 2026-05-03 | `pseudo_after_compound` (`.foo.bar:hover`) allowed; `pseudo_interleaved` (`.foo:hover.bar`) forbidden. | Catalog showed 42 occurrences of compound+pseudo across 14 files. Zero interleaved cases. Codifying "classes first, pseudo last" matches existing universal practice. |
| 2026-05-03 | Variants carry trailing inline comment instead of preceding line comment. | Variants don't get full purpose paragraphs; trailing comment is exactly the right scale. Parser pulls trailing-comment text as variant's purpose_description. |
| 2026-05-03 | All grouped, descendant, child, and sibling selectors forbidden. | Catalog showed 1,316 combinator selectors and 153 grouped selectors (combined ~30% of CSS_CLASS rows). All of these couple multiple classes structurally outside the catalog. Forbidding them is the largest single rewrite cost in CSS conversion but is the single biggest catalog-clarity win. |
| 2026-05-03 | Custom properties mandatory for any value used twice or more (reversal of earlier "forbidden" call). | Custom properties are CSS's native named-constant mechanism. Forbidding them would force value duplication everywhere. Mandating them eliminates the duplication. Defined only in FOUNDATION; consumed everywhere via `var(...)`. |
| 2026-05-03 | `@keyframes` allowed only in FOUNDATION. | Catalog showed 26 LOCAL keyframe definitions duplicating 4 SHARED ones. Centralizing to FOUNDATION eliminates the duplication permanently. New animations require a FOUNDATION edit (small cost; encourages reuse). |
| 2026-05-03 | CHANGELOG block forbidden in CSS file headers. | Per development guidelines, CC files have no changelogs. Versioning is via `dbo.System_Metadata`; file change history is via git. CHANGELOG would add maintenance burden with little value. |
| 2026-05-03 | Binary PASS/FAIL per file. No severity levels. | Spec is rigid and intentionally so. Every rule is mandatory. Severity tiering implies some rules are negotiable, which contradicts the design philosophy. |
| 2026-05-03 | First parser run succeeded; 5,913 rows produced with 87.1% drift coverage. | Confirms the parser exercises every spec rule. Top drift codes match expectations: `MISSING_PURPOSE_COMMENT` (2,842), `DRIFT_HEX_LITERAL` (1,684), `FORBIDDEN_DESCENDANT` (1,377), `MISSING_VARIANT_COMMENT` (1,188), `MISSING_SECTION_BANNER` (670). Drift distribution surfaces the real shape of conversion work. |
| 2026-05-03 | Parser implementation note: drift codes use `@()` array construction in `Add-Drift` to avoid the PowerShell single-element `-split` returning a string instead of an array (which makes `+=` do string concatenation). | Subtle bug discovered on first run; fixed in the same session. Future maintenance: any function that accumulates list-shaped data in a hashtable property must force array context with `@(...)`. |
| 2026-05-03 | Parser implementation note: `Get-BannerInfo` early-returns null for comments containing header markers (`Location:`, `Version:`, xFACts identity line) so file headers are not misclassified as section banners. | Both file headers and section banners contain `=` rules. Distinguishing by content marker is more reliable than trying to distinguish by structure. |
| 2026-05-03 | Section status remains `[DRAFT]` (not `[FINALIZED]`) pending validation pass. | The parser produces what the spec describes, and the data tells a coherent story, but real validation requires round-tripping a file (manual audit → rewrite to spec → re-parse → confirm clean). Status will move to `[FINALIZED]` after that round-trip succeeds. |

---

## Part 4 - JavaScript Files  `[OUTLINE]`

### 4.1 Required structure

(To be filled in.)

### 4.2 What every JS file contains

(To be filled in.)

### 4.3 Required patterns

(To be filled in.)

### 4.4 Forbidden patterns

(To be filled in.)

### 4.5 Illustrative example

(To be filled in.)

### 4.6 What the parser extracts

(To be filled in.)

### 4.7 Decision log

(Decisions affecting JS spec land here.)

---

## Part 5 - PowerShell Route Files  `[OUTLINE]`

Route files (page route handlers and API route handlers — `*.ps1` files in `scripts/routes/`).

### 5.1 Required structure

(To be filled in.)

### 5.2 What every route file contains

(To be filled in.)

### 5.3 HTML emission patterns

This is the section where the indirection issues observed during cataloger development get resolved. R1 and R2 from the recommendations doc fold in here, refined and made firm.

(To be filled in.)

### 5.4 Required patterns

(To be filled in.)

### 5.5 Forbidden patterns

(To be filled in.)

### 5.6 Illustrative example

(To be filled in.)

### 5.7 What the parser extracts

(To be filled in.)

### 5.8 Decision log

(Decisions affecting PS route file spec land here.)

---

## Part 6 - PowerShell Module Files  `[OUTLINE]`

Module files (`*.psm1` files — primarily `xFACts-Helpers.psm1` for now). Functions exported for use by route files and other modules.

### 6.1 Required structure

(To be filled in.)

### 6.2 Function organization

(To be filled in.)

### 6.3 HTML-emitting helper functions

The other place where R1 and R2 fold in — most of the indirection patterns observed in cataloger development came from helper modules.

(To be filled in.)

### 6.4 Required patterns

(To be filled in.)

### 6.5 Forbidden patterns

(To be filled in.)

### 6.6 Illustrative example

(To be filled in.)

### 6.7 What the parser extracts

(To be filled in.)

### 6.8 Decision log

(Decisions affecting PS module spec land here.)

---

## Part 7 - HTML in Documentation Pages  `[OUTLINE]`

The static HTML files in `xFACts-ControlCenter/public/docs/` (Confluence-published documentation pages, separate from the route-file inline HTML).

### 7.1 Required structure

(To be filled in.)

### 7.2 Required patterns

(To be filled in.)

### 7.3 Forbidden patterns

(To be filled in.)

### 7.4 Illustrative example

(To be filled in.)

### 7.5 What the parser extracts

(To be filled in.)

### 7.6 Decision log

(Decisions affecting documentation HTML spec land here.)

---

## Part 8 - Compliance Reporting  `[DRAFT]`

How the parser surfaces drift across the codebase. With the catalog model in place (Part 2's `drift_codes` and `drift_text` columns), compliance reporting reduces to SQL queries against Asset_Registry. This section will enumerate the standard reports and their queries.

### 8.1 Standard queries

Initial set, will grow as more queries prove their value:

**Q1 — Chrome consolidation candidates.** Find every class or variant that has a SHARED definition AND one or more LOCAL definitions. Each result is a page reinventing what's already shared chrome. Use this as the to-do list for chrome consolidation work.

```sql
SELECT
    local.file_name        AS reinventing_file,
    local.line_start       AS local_line,
    local.component_type   AS kind,
    local.component_name   AS reinvented_class,
    shared.source_file     AS shared_definition_lives_in,
    shared.line_start      AS shared_line
FROM dbo.Asset_Registry local
INNER JOIN dbo.Asset_Registry shared
    ON  local.component_name  = shared.component_name
    AND local.component_type  = shared.component_type
WHERE local.file_type           = 'CSS'
  AND local.reference_type      = 'DEFINITION'
  AND local.scope               = 'LOCAL'
  AND shared.scope              = 'SHARED'
  AND shared.reference_type     = 'DEFINITION'
ORDER BY local.component_name, local.file_name;
```

**Reading Q1 results.** Q1 produces *candidates*, not confirmed problems. Each result row is a "this might be reinvention" finding that requires human review for two reasons:

- **Intentional collisions exist.** Two unrelated classes can legitimately share a name across files because the name happens to fit two different concepts (e.g., a top-level navigation `header-bar` in engine-events.css versus a panel-internal `header-bar` somewhere else). The catalog can't distinguish "same name, same intent, should consolidate" from "same name, different intent, should rename for clarity." Both outcomes are valid resolutions; the query just surfaces the cases worth looking at.
- **Until the zone-conflation parser bug is fixed (queued for next session), Q1 will produce false positives** where a CC page's class name happens to match a class defined in a docs-*.css file, even though CC pages can't actually consume docs CSS. After the fix, only legitimate same-zone collisions appear.

Treat Q1 as a starting list to walk through, not a list to act on automatically. For each match, look at the `raw_text` of both rows to compare the actual rule bodies — if they're equivalent, consolidate; if they're materially different, rename one of them.

**Q1 covers one consolidation mode: classes that are already shared and being reinvented locally.** A second consolidation mode is just as important: **classes that are not yet shared but appear locally in many pages, suggesting they should be promoted to shared.** That's Q5 below.

**Q5 — Promotion-to-shared candidates.** Find class names defined locally in three or more files, where no shared definition exists. Each result is a candidate for promotion to engine-events.css (or whichever file holds the FOUNDATION/CHROME sections), after which all the local definitions can be deleted and the pages will consume the new shared version through HTML.

```sql
WITH LocalCounts AS (
    SELECT
        component_type,
        component_name,
        COUNT(DISTINCT file_name) AS local_file_count
    FROM dbo.Asset_Registry
    WHERE file_type        = 'CSS'
      AND reference_type   = 'DEFINITION'
      AND scope            = 'LOCAL'
      AND component_type IN ('CSS_CLASS', 'CSS_VARIANT')
    GROUP BY component_type, component_name
),
ExistingShared AS (
    SELECT DISTINCT component_type, component_name
    FROM dbo.Asset_Registry
    WHERE file_type        = 'CSS'
      AND reference_type   = 'DEFINITION'
      AND scope            = 'SHARED'
)
SELECT
    lc.component_type,
    lc.component_name,
    lc.local_file_count,
    STRING_AGG(ar.file_name, ', ') WITHIN GROUP (ORDER BY ar.file_name) AS local_files
FROM LocalCounts lc
LEFT JOIN ExistingShared es
    ON  es.component_type = lc.component_type
    AND es.component_name = lc.component_name
INNER JOIN dbo.Asset_Registry ar
    ON  ar.component_type = lc.component_type
    AND ar.component_name = lc.component_name
    AND ar.scope          = 'LOCAL'
    AND ar.reference_type = 'DEFINITION'
    AND ar.file_type      = 'CSS'
WHERE lc.local_file_count >= 3
  AND es.component_name IS NULL
GROUP BY lc.component_type, lc.component_name, lc.local_file_count
ORDER BY lc.local_file_count DESC, lc.component_name;
```

**Reading Q5 results.** Like Q1, this surfaces candidates, not verdicts:

- **Same name doesn't always mean same intent.** Three pages defining `.section-header` might be styling three different concepts that happen to share a name. Compare the `raw_text` of each row before promoting — if the rule bodies diverge significantly, the right move may be renaming for clarity rather than promoting to shared.
- **Same intent might be hiding under different names.** A "small refresh status text" element might be `.refresh-info` on one page, `.update-text` on another, `.last-updated-display` on a third. Q5 only catches name-matched cases; behavioral-similarity matching across different names is documented as OQ-CSS-2 (Part 10) — a real gap in the catalog's chrome-consolidation lens, with several possible solutions, deferred until chrome standardization actually begins.
- **The `>= 3` threshold is heuristic.** Two pages defining the same class might be coincidence; three is the smallest pattern worth investigating. Adjust the threshold based on how aggressive you want to be about promoting things.

Q5 produces the to-do list for the "engine-events.css is not yet comprehensive — what should be added to it" half of the chrome standardization initiative, complementing Q1 (which addresses the "engine-events.css already has it but pages reinvent it" half).

**Q2 — Drift summary per file.** Counts of total rows and rows-with-drift per file. Use this to prioritize conversion work.

```sql
SELECT
    file_name,
    COUNT(*)                                                     AS total_rows,
    SUM(CASE WHEN drift_codes IS NOT NULL THEN 1 ELSE 0 END)     AS rows_with_drift
FROM dbo.Asset_Registry
WHERE file_type = 'CSS'
GROUP BY file_name
ORDER BY rows_with_drift DESC;
```

**Q3 — Drift code distribution across the codebase.** What's the most common kind of drift?

```sql
SELECT
    TRIM(value)         AS code,
    COUNT(*)            AS occurrences
FROM dbo.Asset_Registry
CROSS APPLY STRING_SPLIT(drift_codes, ',')
WHERE file_type    = 'CSS'
  AND drift_codes  IS NOT NULL
  AND TRIM(value)  <> ''
GROUP BY TRIM(value)
ORDER BY COUNT(*) DESC;
```

**Q4 — Per-file rewrite checklist.** For one specific file, what does the work look like, grouped by drift code?

```sql
SELECT
    drift_codes,
    COUNT(*)            AS occurrences,
    MIN(line_start)     AS first_line,
    MAX(line_start)     AS last_line
FROM dbo.Asset_Registry
WHERE file_type    = 'CSS'
  AND file_name    = '<filename.css>'
  AND drift_codes  IS NOT NULL
GROUP BY drift_codes
ORDER BY occurrences DESC;
```

More queries will be added as patterns emerge (e.g., variant-specific reports, hex-literal-to-custom-property migration lists, file-organization-mismatch details).

### 8.2 Per-file drift summary

(Reserved — Q2 covers the basics; this section will be filled out as we identify additional per-file lenses worth standardizing.)

### 8.3 Codebase-wide drift summary

(Reserved — Q3 covers the basics; this section will expand as we discover other codebase-wide views worth capturing.)

---

## Part 9 - Conversion Tracking  `[OUTLINE]`

Per-file conversion progress. As file types finalize and we begin converting existing files to conform to the spec, this section tracks status per file.

### 9.1 The detection-vs-verification asymmetry (important)

The catalog supports two related but distinct activities:

1. **Detection** — "what work needs to be done?" Surfaced by the standard queries in Part 8. Q1 finds chrome that's reinvented locally despite being shared; Q5 finds chrome that's repeated locally and could be promoted to shared. Both queries work today against CSS-side data alone.
2. **Verification** — "did the work I did actually have the intended effect?" Confirms after consolidation that a page is now drawing styling from the shared source rather than its own local copy.

**Detection is available now. Verification is not.** Here's why.

When `slideout-stat-label` is consolidated out of `jobflow-monitoring.css` and the parser re-runs, the local DEFINITION row simply disappears from the catalog — that's the easy half of verification (the local copy is gone). But proving that the page is now consuming the shared definition requires a USAGE row attributing the consumption to the shared source. Page chrome is consumed primarily through HTML class attributes (`class="slideout-stat-label"` in an HTML element), not through CSS selectors, so that USAGE row only appears once the **HTML-side parser** (Part 7, and the route-file inline-HTML half of Part 5) is implemented and walks the route files' emitted HTML.

This means the practical work order for the chrome standardization initiative is:

1. **Finish CSS spec & parser** (in progress; Part 3 to be promoted to `[FINALIZED]` after the next-session validation round-trip).
2. **Build the HTML/route spec & parser** (Parts 5 and 7) so the consumption side of the catalog comes online.
3. **Run both parsers and verify the catalog reports both DEFINITION and USAGE rows correctly** for shared chrome.
4. **Then begin actual chrome consolidation work**, using Q1 and Q5 to identify candidates and the catalog re-runs to verify each consolidation step. Each consolidated class should produce: (a) the local DEFINITION row disappearing from the page's CSS, AND (b) USAGE rows appearing in the page's HTML pointing at engine-events.css.

Doing the consolidation work earlier than step 4 is possible, but the verification half of "did this consolidation actually work" relies on visual inspection rather than a catalog query. Once the HTML parser exists, every consolidation step has a deterministic before/after catalog signature.

### 9.2 CSS files

(File list and conversion status, populated when CSS spec runs against the catalog and we have a baseline.)

### 9.3 JS files

(File list and conversion status, populated when JS spec finalizes.)

### 9.4 PowerShell route files

(File list and conversion status, populated when route spec finalizes.)

### 9.5 PowerShell module files

(File list and conversion status, populated when module spec finalizes.)

### 9.6 Documentation HTML files

(File list and conversion status, populated when documentation HTML spec finalizes.)

---

## Part 10 - Open Questions and Known Tensions  `[OUTLINE]`

Items that surface during design discussions but don't fit cleanly into one section, or that need cross-cutting consideration. Captured here so they don't get lost.

### OQ-CSS-1 — `:not()` and stacked pseudo-classes

The CSS spec as currently drafted (Part 3) does not address two related constructs:

1. **`:not(...)`** — a pseudo-class that takes a complex argument (e.g., `:not(:disabled)`, `:not(.active)`).
2. **Stacked pseudo-classes** on a single selector (e.g., `.btn:hover:not(:disabled)` chains `:hover` and `:not(:disabled)`).

The first parser run found 13 occurrences across 6 files. The two-qualifier-slot model (`variant_qualifier_1`, `variant_qualifier_2`) cannot represent these cleanly — the parser produces malformed values like `not:hover`, `hover:not`, `hover:not:not`.

Two possible directions:
- **Forbid both.** Add `FORBIDDEN_NOT_PSEUDO` and `FORBIDDEN_STACKED_PSEUDO` drift codes. Rewriters use class-modifier patterns instead (e.g., `.btn:hover:not(:disabled)` becomes `.btn.enabled:hover` with explicit `.enabled` toggling). Simpler spec, more rewrites.
- **Allow with cataloging extension.** Either a third qualifier slot, a JSON-shaped qualifier, or accept `:` as a documented multi-pseudo separator. More flexible, more parser complexity.

To be discussed in the next session before the validation round-trip.

### OQ-CSS-2 — Same-functionality, different-names grouping

Q5 in Part 8 finds classes repeated locally in many files by exact name match. But chrome standardization also needs to identify the trickier case where the same functionality exists across multiple pages under different names — a "small refresh status text" element might be `.refresh-info` on one page, `.update-text` on another, `.last-updated-display` on a third. Each is implemented from scratch, none share a name, and exact-match queries miss the duplication entirely.

The previous Asset_Registry shape included a manual `component_subtype` column that was never populated but was originally intended for this purpose — manually grouping classes into logical buckets like SLIDEOUT, MODAL, OVERLAY, BADGE so analysis queries could surface "every component in the SLIDEOUT bucket" regardless of name. The column was dropped in the v0.2 schema migration because it was unused and redundant with `component_type`/`variant_type` for the typing role. The grouping concept itself is still valid and unsolved.

Possible directions when this is revisited:

- **Manual classification via a separate annotations table** keyed on natural identity (`component_type` + `component_name`). Survives truncate-and-reload of Asset_Registry. A class can belong to multiple groups (a `SLIDEOUT` class can also be an `OVERLAY`).
- **Heuristic auto-grouping from existing data** — pattern-match on component_name (anything containing `slide` → SLIDEOUT bucket, anything containing `modal` → MODAL bucket). Approximate but zero manual cost. Could seed the manual layer.
- **Property-body similarity matching** — compare `raw_text` (full rule bodies, once that fix lands) across rows to find classes whose declarations are substantially similar even though their names differ. Hardest but most accurate.
- **JSON or many-to-many tags column on Asset_Registry directly.** Simpler than a separate table; ties tags to the row lifecycle (rebuilt every parse run), so heuristic auto-grouping fits this shape better than manual classification.

To be revisited when chrome standardization actually begins. Not blocking; flagged here so the consideration doesn't get lost.

### (Other open questions added as they arise.)

---

## Appendix A - Drift Codes Reference

Every drift code emitted by the parser into the `drift_codes` column on Asset_Registry rows. Each row's `drift_text` column holds the joined human-readable descriptions corresponding to its codes.

CSS drift codes (from Part 3):

| Code | Description |
|---|---|
| `MALFORMED_FILE_HEADER` | The file's header block is missing, malformed, or contains required fields out of order. |
| `FORBIDDEN_CHANGELOG` | The file header contains a CHANGELOG block. CHANGELOG blocks are not allowed in CSS file headers — version is tracked in dbo.System_Metadata, file change history is tracked in git. |
| `FILE_ORG_MISMATCH` | The FILE ORGANIZATION list in the header does not exactly match the section banner titles in the file body, by content or by order. |
| `MISSING_SECTION_BANNER` | A class definition (or other catalogable construct) appears outside any banner — no section banner precedes it in the file. |
| `MALFORMED_SECTION_BANNER` | A section banner exists but does not follow the strict 5-line format with 78-character rules. |
| `UNKNOWN_SECTION_TYPE` | A section banner declares a TYPE not in the enumerated list (FOUNDATION, CHROME, LAYOUT, CONTENT, OVERRIDES). |
| `SECTION_TYPE_ORDER_VIOLATION` | Section types appear out of the required order (FOUNDATION → CHROME → LAYOUT → CONTENT → OVERRIDES). |
| `MISSING_PREFIXES_DECLARATION` | A section banner is missing the mandatory `Prefixes:` line in its description block. |
| `DUPLICATE_FOUNDATION` | More than one CSS file in the codebase contains a FOUNDATION section. Exactly one is allowed. |
| `DUPLICATE_CHROME` | More than one CSS file in the codebase contains a CHROME section. Exactly one is allowed. |
| `PREFIX_MISMATCH` | A class name does not begin with one of the prefixes declared in its containing section's banner. |
| `MISSING_PURPOSE_COMMENT` | A base class definition is not preceded by a single-line purpose comment. |
| `MISSING_VARIANT_COMMENT` | A class variant does not carry a trailing inline comment after the opening brace. |
| `FORBIDDEN_ELEMENT_SELECTOR` | A rule's selector is an element selector (e.g., `body`, `h1`, `a`). Element-only styling must move to FOUNDATION as part of shared chrome. |
| `FORBIDDEN_UNIVERSAL_SELECTOR` | A rule uses the universal selector `*`. Reset rules must move to FOUNDATION. |
| `FORBIDDEN_ATTRIBUTE_SELECTOR` | A rule's selector contains an attribute matcher (`[type="radio"]`). Attribute-based styling must be replaced with class-based styling. |
| `FORBIDDEN_ID_SELECTOR` | A rule's selector includes an `#id` token (alone or compound). Class-based styling required. |
| `FORBIDDEN_GROUP_SELECTOR` | A rule's selector contains a comma (`,`). Each selector gets its own definition block. |
| `FORBIDDEN_DESCENDANT` | A rule's selector contains a descendant combinator (whitespace between two simple selectors). Restructure as a separate class definition. |
| `FORBIDDEN_CHILD_COMBINATOR` | A rule's selector contains a child combinator (`>`). Restructure as a separate class definition. |
| `FORBIDDEN_SIBLING_COMBINATOR` | A rule's selector contains a sibling combinator (`+` or `~`). Restructure as a separate class definition. |
| `COMPOUND_DEPTH_3PLUS` | A compound selector contains three or more class tokens (`.a.b.c`). Refactor as a single class plus at most one modifier class. |
| `PSEUDO_INTERLEAVED` | A pseudo-class appears between two class tokens (`.a:hover.b`). Pseudo-classes must come last in any compound. |
| `FORBIDDEN_AT_IMPORT` | The file contains an `@import` rule. |
| `FORBIDDEN_AT_FONT_FACE` | The file contains an `@font-face` rule. Font definitions are not part of the CSS file format spec. |
| `FORBIDDEN_AT_MEDIA` | The file contains an `@media` rule. Responsive styling is currently outside the spec. |
| `FORBIDDEN_AT_SUPPORTS` | The file contains an `@supports` rule. |
| `FORBIDDEN_KEYFRAMES_LOCATION` | An `@keyframes` definition appears in a section other than FOUNDATION (or in a file with no FOUNDATION). |
| `FORBIDDEN_CUSTOM_PROPERTY_LOCATION` | A custom property definition (`--name: value`) appears in a section other than FOUNDATION. |
| `DRIFT_HEX_LITERAL` | A hex color literal appears in a class declaration's value where a custom property has been defined for that color. |
| `FORBIDDEN_COMMENT_STYLE` | A comment exists that is not one of the allowed kinds (file header, section banner, per-class purpose comment, trailing variant comment, sub-section marker). |
| `FORBIDDEN_COMPOUND_DECLARATION` | Two or more declarations appear on the same line (`padding: 4px; margin: 2px;`). Each declaration must be on its own line. |
| `BLANK_LINE_INSIDE_RULE` | A blank line appears inside a class definition (between the opening `{` and the closing `}`). |
| `EXCESS_BLANK_LINES` | More than one blank line appears between top-level constructs. |

Future file-type specs (JS, PowerShell, HTML) will add their own drift codes here as they are drafted.

---

## Revision History

| Version | Date | Description |
|---|---|---|
| 0.1 | 2026-05-02 | Document created. Scaffold and structure only - all content sections marked `[OUTLINE]` pending design discussions. Consolidates `CC_FileFormat_Spec.md` v0.2 and `CC_FileFormat_Parser_Friendly_Conventions_Recommendations.md`; both will retire to `Legacy/` as content folds in. Session Start Protocol and Current State sections added near the top to support seamless cross-session handoff. |
| 0.2 | 2026-05-03 | CSS spec design and implementation completed end-to-end in one session. **Design phase:** Q1-Q30 decisions captured. New Part 2 added (Asset_Registry Catalog Model) covering schema migration, variant model, controlled vocabularies for component_type and variant_type, drift recording mechanism. Part 3 (CSS Files) drafted with full structural spec, allowed/forbidden patterns, illustrative example, and parser-extraction reference. Old Parts 3-9 renumbered to Parts 4-10 to accommodate the new Part 2. Appendix A (32 drift codes with descriptions) added. **Implementation phase:** Schema migration script ran successfully (drop & recreate with new shape; CSS_VARIANT and FILE_HEADER added to component_type CHECK constraint). Updated CSS populator (`Populate-AssetRegistry-CSS.ps1`) — variant emission, drift detection, FILE_HEADER row, three-pass execution. **Validation phase:** First clean parser run produced 5,913 rows with 87.1% drift coverage (5,150 of 5,913). Two parser bugs caught and fixed in the same session: drift code array concatenation, file header misclassification as malformed banner. **Sanity sweep findings:** Five additional parser bugs queued for next session (forbidden-selector drift on CSS_RULE rows, COMPOUND_DEPTH_3PLUS on descendants, HTML_ID dropped when ID is compounded with classes, zone-conflation across CC and docs shared maps, `raw_text` capturing only the selector instead of the full rule body). One spec gap documented as OQ-CSS-1: `:not()` and stacked pseudo-classes don't fit the two-qualifier-slot model; needs forbid-or-extend decision. **Part 8 (Compliance Reporting) populated with five standard queries** addressing both halves of the chrome standardization initiative — Q1 surfaces classes already shared but reinvented locally, Q5 surfaces classes repeated locally that should be promoted to shared. **Part 9.1 added** documenting the detection-vs-verification asymmetry: the catalog can detect consolidation candidates today from CSS data alone, but verifying that a consolidation worked requires USAGE rows from HTML-side parsing (Parts 5/7). Practical implication: actual consolidation work should wait until the HTML parser is built. **Next session:** parser bug-fix pass → spec discussion on OQ-CSS-1 → validation round-trip on one representative CSS file → if clean, promote Part 3 to `[FINALIZED]` and begin Part 4 (JS spec). |

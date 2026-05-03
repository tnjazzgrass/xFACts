# Control Center File Format Standardization

**Created:** May 2, 2026
**Status:** Active - CSS spec drafted, parser bug-fix pass complete, OQ-CSS-1 resolved, FOUNDATION-section exemptions added (Gaps 1-3), cc-shared.css build queued as next checkpoint
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

*Last updated: 2026-05-03 (end of session — FOUNDATION exemptions complete, cc-shared.css build queued).*

**Active section:** Part 3 - CSS Files. Status `[DRAFT]`. Spec amendments for FOUNDATION-section exemptions complete; parser updated and verified. The validation round-trip is now reframed as a two-file build-and-verify exercise: a new `cc-shared.css` file (the central shared resource, replacing the de-facto-shared but un-renamed `engine-events.css`) plus one CC page file (`backup.css`) refactored to consume from it. On both files passing clean, Part 3 promotes to `[FINALIZED]`.

**This session's work — FOUNDATION-exemption checkpoint:**

While preparing the cc-shared.css design, four spec gaps surfaced that needed addressing before any rewrite could happen. Three were genuine spec amendments; one was authoring discipline.

1. **Gap 1 (resolved): Element / universal / attribute selectors permitted in FOUNDATION.** The spec previously forbade `*`, `body`, `[type="radio"]`, etc. as drift codes, but FOUNDATION's stated purpose includes "CSS reset rules" which fundamentally rely on these selectors. Suppression added: when active section type is FOUNDATION, `FORBIDDEN_ELEMENT_SELECTOR`, `FORBIDDEN_UNIVERSAL_SELECTOR`, and `FORBIDDEN_ATTRIBUTE_SELECTOR` do not fire. Reset rules in FOUNDATION are spec-compliant.

2. **Gap 2 (resolved): Pseudo-element location rule.** Pseudo-elements (`::before`, `::after`, `::-webkit-scrollbar`) had no explicit treatment in the spec. New drift code `FORBIDDEN_PSEUDO_ELEMENT_LOCATION` fires when a pseudo-element appears outside FOUNDATION and is not attached to a class. Inside FOUNDATION pseudo-elements are unrestricted (consistent with reset-rule freedom); outside FOUNDATION they must be class-scoped (`.foo::before` ok; bare `::before` not ok).

3. **Gap 3 (resolved): `Prefixes: (none)` sentinel.** FOUNDATION sections with reset rules and no class definitions need a way to declare "the Prefixes line is present but no prefix matching applies." The literal value `(none)` is now recognized in the banner extractor as a valid declaration that opts out of `PREFIX_MISMATCH` checks. `MISSING_PREFIXES_DECLARATION` still fires when the line is entirely absent — `(none)` is a present-but-empty declaration, structurally valid.

4. **Gap 4 (authoring discipline, no spec text): cross-section prefix overlap.** A prefix family (e.g., `refresh-*`) should live in exactly one section, not be split. Resolved by the cc-shared.css design choice to put `refresh-badge-*` under CHROME: REFRESH INFO rather than splitting between REFRESH INFO and CONTENT: SECTIONS as the legacy `engine-events.css` did. No parser change needed; the discipline is enforced by the spec section-banner system itself.

**Verified parser behavior** with the post-amendment parser run:
- Total rows: 5,949 (unchanged from prior run)
- Drift coverage: 87.4% (was 87.3%)
- New code `FORBIDDEN_PSEUDO_ELEMENT_LOCATION` correctly attaches to the four bare scrollbar pseudo-element rules in `engine-events.css` (lines 109-112). All four are caught — `::-webkit-scrollbar`, `::-webkit-scrollbar-track`, `::-webkit-scrollbar-thumb`, `::-webkit-scrollbar-thumb:hover`.
- Pre-existing drift code counts unchanged because no FOUNDATION-typed banner exists in the codebase yet — the suppression has nothing to suppress until cc-shared.css is built.

**Major direction decision: new shared file alongside `engine-events.css`.**

Across multiple prior sessions, "engine-events.css" has been the de-facto shared resource pool, but its name doesn't reflect that role. Its component registration (`ControlCenter.Shared`) confirms the intent, but the filename causes recurring confusion when reading the codebase. Resolution: build a new file `cc-shared.css` that is spec-compliant from day one, lives alongside `engine-events.css`, and is migrated to one page at a time. `engine-events.css` stays in place during the migration (zero production breakage) and is deleted when the last page has migrated.

This is a one-time decision with permanent effect on the codebase. The name `cc-shared.css` is unambiguous — every CC page consumes from it. Other candidates considered (`cc-foundation.css`, `cc-chrome.css`, `xfacts-core.css`) all had drawbacks — too narrow, too generic, or too platform-bound.

**Custom property naming convention** (designed from scratch, locked in for permanent use):

```
--<category>-<role>-<modifier>
```

- `category` is one of a fixed enum: `color`, `size`, `font`, `duration`, `shadow`, `z`
- `role` is descriptive of purpose, not literal value (e.g., `bg-card`, not `dark-gray`)
- `modifier` is optional, describing state, size step, or variant
- All lowercase, hyphen-separated

Examples: `--color-bg-card`, `--color-text-muted`, `--color-status-overdue`, `--size-padding-md`, `--size-nav-height`, `--duration-default`, `--z-modal`. The fixed category enum keeps the variable space organized and makes drift-tracking queries possible (e.g., "show me hex literals where a `--color-*` exists").

**Queued next — Checkpoint B (cc-shared.css build):**

1. Query Asset_Registry for repeated values across CC files: every hex literal that appears 2+ times, every pixel size that appears 2+ times, every duration that appears 2+ times. This produces the comprehensive list of values to centralize in cc-shared's `:root` block.
2. Build `cc-shared.css` from scratch following the new spec — file header, FOUNDATION section with `:root`, resets, and keyframes, plus CHROME and CONTENT sections matching the structure of today's `engine-events.css` but spec-compliant throughout.
3. Run parser; expected outcome: zero drift codes on any cc-shared.css row.

**Queued after — Checkpoint C (backup.css refactor):**

1. Pull `backup.css` from GitHub, query its current drift inventory.
2. Rewrite `backup.css` to spec, consuming custom properties and shared classes from cc-shared.css.
3. Run parser; expected outcome: zero drift codes on any backup.css row.

**Then — Checkpoint D (validation complete, doc update):**

Both files clean → Part 3 promotes from `[DRAFT]` to `[FINALIZED]`. Part 4 (JS spec) becomes the next active section.

**Backup.css chosen as test page** (over client-relations, bidata-monitoring): Backup is mostly a window into nightly backup status, with limited day-to-day user traffic. Lower risk than a heavily-trafficked page like bidata-monitoring; more representative than the very-small client-relations page which doesn't exercise the full spec well.

**Important framing for the consolidation initiative:** Part 9.1 documents an asymmetry. The CSS catalog can today **detect** chrome consolidation candidates (Q1, Q5). It cannot yet **verify** that a consolidation actually worked, because verification requires USAGE rows showing a page consuming a shared definition through its HTML — and HTML parsing is Part 5/7, not yet built. Practical implication: actual consolidation work should wait until the HTML parser exists. Until then, detection queries are useful for planning but consolidation steps lack a deterministic catalog signature for the after-state.

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
| 2026-05-03 (1) | CSS spec design discussion completed end-to-end. Q1-Q30 decisions captured. Asset_Registry catalog model finalized (Part 2): variants as own rows, generic qualifier columns, no `parent_name`, drift annotation via `drift_codes`/`drift_text`. CSS spec drafted (Part 3): five section types in fixed order, mandatory `Prefixes:` line in banners, three variant shapes, full forbidden-pattern list, illustrative example, parser-extraction reference. Appendix A (32 drift codes with descriptions) added. Old Parts 3-9 renumbered to 4-10. Schema migration executed: `dbo.Asset_Registry` dropped and recreated with new shape. CHECK constraint updated to include `CSS_VARIANT` and `FILE_HEADER` component types. Parser rewritten: variant emission, inline drift detection (32 codes), FILE_HEADER row per file, three-pass execution. **Two bugs found and fixed during runs:** (1) drift codes concatenated without delimiters (PowerShell `-split`-then-`+=` returned string instead of array); (2) file headers misidentified as malformed banners. First successful clean run: 5,913 rows, 87.1% drift coverage. **Sanity sweep over the populated catalog surfaced four more parser issues plus one spec gap, queued for next session.** Part 8 (Compliance Reporting) populated with five standard queries. Part 9.1 added documenting the detection-vs-verification asymmetry. OQ-CSS-1 (`:not()` and stacked pseudos) and OQ-CSS-2 (same-functionality-different-names) added to Part 10. |
| 2026-05-03 (2) | Parser bug-fix pass completed: all five sanity-sweep issues resolved in one `Populate-AssetRegistry-CSS.ps1` update. (1) `CSS_RULE` drift codes wrapped with `@(...)` for array safety. (2) Per-compound drift checks consolidated into `Add-CompoundDriftCodes`, called from both primary and descendant paths. (3) HTML_ID emission decoupled from CSS_CLASS/CSS_VARIANT emission so compounds with both an ID and classes produce both row types; `Add-HtmlIdRow` extended with `ReferenceType` so descendant IDs become USAGE rows. (4) Shared-map architecture split into per-zone maps with `Get-CssZone` helper deriving zone from filepath. (5) `Format-RuleBody` builds full rule text from AST declarations; threaded through `Add-RowsForSelector` so `raw_text` captures the rule body. **OQ-CSS-1 resolved** by forbidding `:not()` and stacked pseudo-classes; two new drift codes added (`FORBIDDEN_NOT_PSEUDO`, `FORBIDDEN_STACKED_PSEUDO`); refactor recipe (state-class pattern) documented in Part 10's resolution entry. **Two clean parser runs:** post-bug-fix run produced 5,949 rows / 87.3% drift; OQ-CSS-1 run unchanged in row count and confirmed both new drift codes attach to expected cases (13 stacked, 15 `:not()` instances across 13 source cases). **Notable finding:** CC zone has zero shared custom properties (`engine-events.css` defines none); 32 are docs-zone-only. This is a content gap for the conversion phase, not a parser issue, but explains why `DRIFT_HEX_LITERAL` flags are currently docs-zone-only. |
| 2026-05-03 (3) | FOUNDATION-section exemption checkpoint and cc-shared.css design. Surfaced four spec gaps during cc-shared.css design preparation, three resolved as spec amendments and one as authoring discipline. **Gap 1:** element / universal / attribute selectors now permitted inside FOUNDATION; the three corresponding drift codes are suppressed when the active section is FOUNDATION-typed. **Gap 2:** new drift code `FORBIDDEN_PSEUDO_ELEMENT_LOCATION` flags pseudo-elements outside FOUNDATION that aren't attached to a class. **Gap 3:** `Prefixes: (none)` sentinel recognized in banner extractor as a valid declaration that opts out of `PREFIX_MISMATCH`; `MISSING_PREFIXES_DECLARATION` only fires when the line is entirely absent. **Gap 4:** cross-section prefix overlap resolved as authoring discipline (no parser change). Parser updated and verified: total 5,949 rows / 87.4% drift; `FORBIDDEN_PSEUDO_ELEMENT_LOCATION` correctly attaches to all four bare scrollbar pseudo-element rules in `engine-events.css` (lines 109-112). FOUNDATION suppression has nothing to suppress today since no FOUNDATION-typed banner exists in the codebase yet. **Major direction decision:** new file `cc-shared.css` will be built spec-compliant from day one and will live alongside `engine-events.css` until pages migrate one-by-one. Solves the longstanding naming-confusion problem where the de-facto shared resource was called `engine-events.css` despite serving as `ControlCenter.Shared`. **Custom property naming convention locked in:** three-part `--<category>-<role>-<modifier>` pattern with fixed category enum (`color`, `size`, `font`, `duration`, `shadow`, `z`). **Backup.css selected as the test page** for the page-level rewrite, chosen for low traffic and reasonable representativeness. **Queued next:** Checkpoint B (cc-shared.css build) → Checkpoint C (backup.css refactor) → Checkpoint D (validation complete, Part 3 promotes to `[FINALIZED]`). |
| 2026-05-03 (4) | **Checkpoint B — cc-shared.css build, validated.** Full file built from value-extraction queries against the existing catalog: 96 custom property tokens (48 color, 24 size, 11 font, 6 duration, 5 z, 2 shadow, plus a gradient added later in Checkpoint C), 11 spec-compliant section banners, 4 keyframes in FOUNDATION, 1,384 lines total. Object_Registry registration script delivered as a single `dbo.Object_Registry` insert under `ControlCenter.Shared` (WebAssets are not duplicated into Object_Metadata per platform convention). **Three drift iterations to reach zero:** first run flagged FILE_ORG_MISMATCH (numbered list vs un-numbered banners), three COMPOUND_DEPTH_3PLUS issues on `.nav-link.nav-section-*.active` patterns, one MALFORMED_SECTION_BANNER on FEEDBACK OVERLAYS (space in TYPE name), and one MISSING_VARIANT_COMMENT. Resolutions surfaced **Gap 5 spec amendment** (FEEDBACK_OVERLAYS as sixth section type — section type order is now FOUNDATION → CHROME → LAYOUT → CONTENT → OVERRIDES → FEEDBACK_OVERLAYS), and required parser updates: FILE ORG list parser accepts both numbered and un-numbered entries with optional `-- description` strip; **BannerTitles bug fix** — the FILE_ORG_MISMATCH check was comparing list-side `<TYPE>: <NAME>` strings against banner-side `<NAME>` strings (using `ComponentName` alone instead of the full title). Updated to assemble `"$Signature: $ComponentName"` so both sides compare apples-to-apples. Final iteration also surfaced a depth-3 `.slide-panel.auto-height.open` selector resolved by renaming to `.slide-auto-height` so the leftmost class matches the section's `slide` prefix — illustrates the "build for the future, don't shoehorn today" principle. **Final result: 622 rows, zero drift.** First file in the codebase fully spec-compliant. Custom property model held: every value consumed via `var(...)`, no hex literals leaked. Spec scales — 622 rows from one file (vs typical 150-300 for page files) all parsed cleanly. |
| 2026-05-03 (5) | **Checkpoint C — backup.css refactor, validated.** Page-level test of the spec. Original backup.css (350 lines, 124 rows / 95% drift) refactored into spec-compliant version (709 lines, 245 rows / 0% drift). Refactor scope: removed CHANGELOG block from header (git is the source of truth), replaced 4-line section banners with 5-line banners carrying TYPE: NAME format and `Prefixes:` declarations, replaced ~35 hex literals with `var(--color-*)` references, replaced ~20 px sizes with `var(--size-*)` references where shared tokens exist, flattened all descendant selectors to single classes with state modifiers, applied `bk-` prefix to every page-local class, kept the `@media` rule (now permitted), and added per-class purpose comments and per-variant trailing comments throughout. **Gap 6 spec amendment** during this work: `@media` is no longer forbidden; permitted in any section; wrapped rules are still spec-evaluated normally and cataloged with the `@media` expression in the `parent_function` column; `FORBIDDEN_AT_MEDIA` drift code retired. **Gap 7 surfaced and queued (Part 10 OQ-CSS-3):** `@media`-wrapped rules currently classify as `CSS_CLASS` rows but are conceptually variants of the same-selector base class — should add a new `media` `variant_type` value and carry the `@media` expression in `qualifier_2`. Deferred but tracked, not lost. **Two new shared tokens added to cc-shared.css:** `--gradient-progress-default` (for cross-page progress bars) — `#b5b07a` (the muted yellow on the log-type backup badge) intentionally kept as a one-off hex literal until a second page proves cross-page reuse, illustrating the "values used once stay literal; tokens are for repetition" principle. **State-on-element pattern recognized** as a recurring design principle that has now surfaced in OQ-CSS-1 (`:not(:disabled)` cases), the depth-3 nav-link compounds, and the storage-drive descendant rules — formalized in Part 3 as a dedicated subsection. **Class prefixing strategy:** spec-version files carry `bk-` prefixes on page-local classes, but live HTML/JS still references unprefixed names — the prefixed CSS file is staged as a side-by-side reference for the future coordinated CSS+HTML+JS migration session. **Final result: 245 rows, zero drift on backup.css** alongside cc-shared.css's 622/0 — spec proven end-to-end on a page consuming from the shared file. |
| 2026-05-03 (6) | **Checkpoint D — Part 3 promoted to `[FINALIZED]`.** Doc rewrite under Option B (clean reference-doc structure, design history moved out of the main body). Part 3 restructured: 3.1 file header, 3.2 section banners, 3.3 section types (now six including FEEDBACK_OVERLAYS), 3.4 prefixes, 3.5 class definitions, 3.6 variants and modifiers (with **3.6.1 State-on-element pattern** as the new dedicated subsection capturing the recurring principle from OQ-CSS-1, nav-link refactor, storage-drive refactor), 3.7 sub-section markers vs new banner pattern (the discipline rule: prefer creating a new banner over expanding an existing one when adding distinct concepts), 3.8 forbidden patterns, 3.9 custom property tokens (the `--<category>-<role>-<modifier>` convention), 3.10 design decisions (where the design history — Q1-Q30, Gaps 1-7, OQs — gets attribution, separate from the spec body itself). **Gap 7 added to Part 10 as OQ-CSS-3** with concrete shape (variant_type enum addition, qualifier_2 carries the @media expression). **New Part 11 — CSS Refactor Initiative** added: file queue, sequencing strategy (easier pages first, big pages last), `*-spec.css` pattern for parsed-but-unregistered side-by-side files, expected token-promotion workflow, engine-events.css retirement timeline. **Prefix registry decision:** 3-character prefixes fixed platform-wide for consistency, future-proofing, and readability. Backup.css renamed `bk-` → `bkp-` (93 occurrences updated) before the file was committed live, demonstrating the cost-of-change is low when caught pre-commit. Full prefix mapping for all 18 CC pages added to the spec doc as Section 11.8 (Prefix Registry) — single source of truth. Future enhancement noted for adding a `prefix` column to `dbo.Module_Registry` so prefix uniqueness is enforced at the database layer. **Spec status:** validated against two files (one shared, one page) at zero drift; subject to small amendments as more pages migrate but considered solid. **Queued next:** Part 11 Phase 1 — start the page-by-page refactor sequence beginning with the smaller files (replication-monitoring, client-relations, business-intelligence, business-services). |

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
| `raw_text` | VARCHAR(MAX) NULL | The full raw source snippet of the construct. For CSS rules, this captures the full body (selector + declarations) so query-time comparison of two rule bodies does not require re-opening the source files. |
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
| `HTML_ID` | An `#id` selector defined in or referenced by a CSS file. Emitted as DEFINITION in primary compounds and as USAGE in descendant compounds, mirroring CSS_CLASS/CSS_VARIANT behavior. Compounds containing both an ID and classes (e.g., `#foo.bar`) emit both an HTML_ID row and a CSS_CLASS/CSS_VARIANT row, neither of which excludes the other. |
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
| 2026-05-03 | HTML_ID rows are emitted independently of CSS_CLASS/CSS_VARIANT rows when an ID and one or more classes appear in the same compound. | Earlier behavior treated class-vs-id as exclusive (class won; ID dropped from catalog). The catalog should reflect every cataloguable construct in the source; if `#foo.bar` appears as a selector, the catalog should hold a row for `#foo` and a row for `.bar`, both with appropriate drift codes. Same logic extends to descendant compounds — descendant HTML_IDs become USAGE rows. |

---

## Part 3 - CSS Files  `[FINALIZED]`

The CSS spec is finalized as of 2026-05-03 (validated against `cc-shared.css` at 622 rows / 0 drift and `backup.css` at 245 rows / 0 drift). The parser implements every rule in this part. Future small amendments are expected as more page files migrate; the spec is robust enough that any such amendments will be surgical patches rather than structural rewrites.

For the design history behind these rules — what was considered, what was decided, what was rejected, and which gaps surfaced during initial validation — see Section 3.16 (Design Decisions). The body of Part 3 is the spec itself; the body says what *is*, not what was discussed.

---

### 3.1 Required structure

A CSS file consists of three parts in this exact order:

1. **File header** — a single block comment opening at line 1, ending with `*/` followed by exactly one blank line.
2. **Section bodies** — one or more sections, each consisting of a section banner followed by class definitions and optional sub-section markers.
3. **End-of-file** — the file ends after the last `}` of the last section's last rule. No trailing content.

Every line of code in the file lives inside exactly one of these three parts. There is no other content category.

---

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
   <Section banner title 1>
   <Section banner title 2>
   <Section banner title N>
   ============================================================================ */
```

Rules:

- The header is the only construct that may appear before the first section banner. Anything else above the first banner — stray comments, blank lines beyond the single mandatory blank, or rules — is a parse error.
- The closing `*/` is followed by **exactly one** blank line, then the first section banner.
- The Component Description and Component values come from `dbo.System_Metadata` and `dbo.Component_Registry` respectively. The parser extracts them as `purpose_description` and uses Component for cross-reference validation.
- **No CHANGELOG block.** Git is the source of truth for change history. CHANGELOG blocks in CSS files are forbidden.
- **The FILE ORGANIZATION list must match the section banner titles in the file body, verbatim, in order.** Each list entry is exactly the `<TYPE>: <NAME>` of one banner. No abstractions, no shortenings, no descriptions. The parser cross-validates the list against the banners and emits `FILE_ORG_MISMATCH` if they diverge in content or order.
- The list may be unnumbered (current convention) or numbered with `1. `, `2. ` prefixes (legacy form, still accepted). Trailing `-- <description>` text on list entries is permitted and stripped by the parser before comparison; it is not part of the canonical match.

---

### 3.3 Section banners

Each section opens with a banner — a multi-line block comment with strict format:

```
/* ============================================================================
   <TYPE>: <NAME>
   ----------------------------------------------------------------------------
   <Description: 1 to 5 sentences describing what's in this section.>
   Prefixes: <prefix1>, <prefix2>, ...
   ============================================================================ */
```

Rules:

- The opening and closing `=` rules each consist of `=` characters of any length ≥ 5; the parser does not enforce a fixed character count.
- The middle `-` rule separates the title line from the description block.
- `<TYPE>` must be one of the six recognized section types (Section 3.4). The TYPE token is uppercase letters and underscores only — no spaces (a space would break the parser's `<TYPE>: <NAME>` regex match).
- `<NAME>` is human-readable and may contain spaces, commas, and other punctuation.
- The description block is 1-5 sentences explaining what the section contains. It is required.
- The `Prefixes:` line declares which class name prefixes are valid in this section (Section 3.5). It is required.
- Banner authoring discipline: when adding new content within an existing section type, prefer creating a new banner over expanding an existing one if the new content is a distinct concept. See Section 3.8 for the full rule.

---

### 3.4 Section types

Six section types are recognized, in fixed order:

| Order | TYPE | Purpose | Where it lives |
|-------|------|---------|----------------|
| 1 | `FOUNDATION` | Custom property tokens, CSS resets, scrollbar styling, keyframes, animation utilities | Shared resource files only (cc-shared.css). Pages do not have FOUNDATION sections. |
| 2 | `CHROME` | Universal page chrome — nav bar, header bar, refresh info, engine cards, connection banner | Shared resource files only (cc-shared.css). Pages do not have CHROME sections. |
| 3 | `LAYOUT` | Page-level structural layout (column grids, page wrappers, multi-column flex containers) | Page files. Each page has at most one LAYOUT section. |
| 4 | `CONTENT` | Page-specific content components — cards, tables, badges, panels, sub-components | Page files. Pages typically have multiple CONTENT sections (one per logical concept). |
| 5 | `OVERRIDES` | Last-resort overrides of shared classes for page-specific contexts | Page files. Use sparingly. |
| 6 | `FEEDBACK_OVERLAYS` | Transient, behavior-driven viewport-overlay elements — idle overlay, toast notifications, loading spinners, confirmation flashes | Either shared (cc-shared.css) or page files, depending on whether the overlay is universal or page-specific. |

A file may contain multiple sections of the same type; they are author-ordered by author choice. The order rule is between *types*, not between sections within a type. Rules:

- **Type-order rule.** Section types must appear in the order shown above. A `CHROME` banner may not appear after a `CONTENT` banner. Violations emit `SECTION_TYPE_ORDER_VIOLATION`.
- **Multiple-banners-of-same-type rule.** A page may contain multiple `CONTENT` banners (e.g., `CONTENT: PIPELINE STATUS`, `CONTENT: STORAGE STATUS`, `CONTENT: BACKUP TYPE BADGES`). They are independent banners with their own descriptions and prefix declarations.
- **Type uniqueness across files.** `FOUNDATION` and `CHROME` sections may exist in only one file across the codebase — `cc-shared.css` (or its predecessor `engine-events.css` during the transition period). Duplicates emit `DUPLICATE_FOUNDATION` or `DUPLICATE_CHROME`.

---

### 3.5 Prefixes

Every section banner declares one or more class name prefixes via the `Prefixes:` line. Every base class definition in that section must have a leftmost class name that begins with one of the declared prefixes (followed by a `-`). Violations emit `PREFIX_MISMATCH`.

Examples:

- `Prefixes: nav, gear` — class names must start with `nav-` or `gear-` (e.g., `.nav-link`, `.gear-icon`).
- `Prefixes: bk` — class names must start with `bk-` (e.g., `.bk-pipeline-card`).

Special values:

- `Prefixes: (none)` — sentinel value. Declares the section has no class definitions, so prefix-matching is intentionally disabled. Used primarily by `FOUNDATION` sections that contain only reset rules, keyframes, and custom properties (which are not classes). The line itself is still required as a structural marker; using `(none)` opts out of `PREFIX_MISMATCH` only.
- The `Prefixes:` line is mandatory. If absent entirely, the parser emits `MISSING_PREFIXES_DECLARATION`.

Authoring discipline:

- Prefixes do not need to be globally unique. Two sections in different files may declare overlapping prefixes if their concerns are genuinely separate. Authors are responsible for avoiding ambiguous overlaps that would obscure scope; the parser does not enforce uniqueness.
- Page-local class definitions should use a page-identifying prefix (e.g., `bk-` for backup, `jbm-` for JBoss Monitoring). This makes scope visible at a glance in HTML and CSS, and enables prefix-based catalog queries. The migration to prefixed page-local classes is a coordinated CSS+HTML+JS effort tracked under Part 11 (CSS Refactor Initiative).

---

### 3.6 Class definitions

A class definition is a CSS rule whose selector is a single class (the base form) or a single class plus its variants (Section 3.7). Each base class definition must:

- Be preceded by a single-line purpose comment immediately above the rule. The comment is one sentence describing what the class does. Missing purpose comments emit `MISSING_PURPOSE_COMMENT`.
- Use only properties supported by the spec (see Section 3.13 for forbidden patterns).
- Reside in a section whose declared prefixes match the class's leftmost name token.

```css
/* The pipeline status card — backup-page-specific. */
.bk-pipeline-card {
    background: var(--color-bg-card-hover);
    border: var(--size-border-thin) solid var(--color-border-default);
    border-radius: var(--size-radius-lg);
    padding: var(--size-spacing-lg);
}
```

The base class produces a `CSS_CLASS DEFINITION` row in the catalog. The class's purpose comment is captured in the row's `purpose_description` column.

---

### 3.7 Variants and modifiers

A variant is a rule whose selector adds qualifiers to a base class. Three variant shapes are recognized:

| variant_type | Shape | Example | qualifier_1 | qualifier_2 |
|--------------|-------|---------|-------------|-------------|
| `class` | `.base-class.modifier` | `.bk-pipeline-card.status-warning` | `status-warning` | (NULL) |
| `pseudo` | `.base-class:pseudo` | `.bk-status-card:hover` | `:hover` | (NULL) |
| `compound_pseudo` | `.base-class.modifier:pseudo` | `.bk-status-card.clickable:hover` | `clickable` | `:hover` |

Authoring rules for variants:

- A variant must follow its base class's purpose comment, but does not need its own purpose comment. Instead, **every variant must carry a trailing inline comment** on the same line as the opening `{`, describing the state or context. Missing trailing comments emit `MISSING_VARIANT_COMMENT`.
- Variants must adhere to the same prefix rules as their base class (the leftmost class token in the variant must match the section's declared prefixes).
- The compound depth limit is two class tokens. A selector with three or more class tokens (`.foo.bar.baz`) emits `COMPOUND_DEPTH_3PLUS`.
- Stacked pseudo-classes are forbidden (`.foo:hover:focus` emits `FORBIDDEN_STACKED_PSEUDO`). Each rule may carry at most one pseudo-class.
- The `:not(...)` pseudo-class is forbidden in any form (emits `FORBIDDEN_NOT_PSEUDO`). Use the state-on-element pattern (Section 3.7.1) instead.

Each variant produces its own `CSS_VARIANT DEFINITION` row in the catalog. The base class's purpose comment is shared across all variants of that class.

#### 3.7.1 State-on-element pattern  `[FINALIZED]`

When an element's appearance depends on a state (warning, critical, active, disabled, etc.), the state class belongs **on the element being styled**, not inherited via a descendant rule from a parent's state class.

This pattern is mandatory because the spec forbids descendant combinators (Section 3.13) — but the principle is broader than just compliance. It produces clearer HTML, more inspectable state, and better catalog queryability:

- A glance at HTML markup tells you exactly which elements are in which state. No need to mentally trace ancestor classes.
- The state is queryable through the catalog by exact class name (`.bk-drive-label.warning`) rather than by inferred descendant relationships.
- JavaScript that toggles state operates on the element directly, no parent-class coordination needed.

Anti-pattern (forbidden):

```css
.bk-storage-drive.storage-warning .bk-drive-label {
    color: var(--color-accent-departmental);
}
```

Correct pattern:

```css
.bk-drive-label.warning { /* drive is past warning threshold */
    color: var(--color-accent-departmental);
}
```

The HTML must place the `.warning` class on the `.bk-drive-label` element directly. JS that detects warning conditions toggles the class on the label element, not on a parent.

This pattern has surfaced repeatedly during validation: the original `.nav-link.nav-section-platform.active` depth-3 compound, the `:not(:disabled)` guard cases (OQ-CSS-1), and the storage-drive descendant rules (Checkpoint C). All three resolved to the same form: state class on the styled element. The spec treats this as the canonical authoring pattern for stateful UI.

---

### 3.8 Sub-section markers vs new banners

When a section's content grows, two structural tools are available: sub-section markers (lightweight visual dividers within a single banner) and new banners of the same type. The choice determines whether new content is a **distinct concept** with its own description and prefix declaration, or a **sub-component** of an existing concept.

**Use a new banner when:**

- The new content is a distinct concept with its own purpose
- The new content has its own prefix family (e.g., `idle-` vs `toast-` within FEEDBACK_OVERLAYS)
- The new content has its own audience or readership context
- A user reading the file's table of contents would benefit from seeing the new content as a top-level entry

A new banner gets its own row in the FILE ORGANIZATION list; the parser enforces FILE_ORG_MISMATCH against it.

**Use a sub-section marker when:**

- The new content is a sub-component of an existing concept
- Grouping is for visual reading aid only, not a structural distinction

Sub-section markers use the inline format `/* -- <label> -- */`. They are decorative; the parser ignores them for catalog row emission. They do not appear in the FILE ORGANIZATION list. Sub-section markers do not nest — there is one level of grouping.

This rule prevents the "fast-and-loose" failure mode where unrelated additions get jumbled together under an existing banner. Banner-per-concept maintains structural clarity that the catalog can enforce; sub-section markers are for finer-grained groupings within a single concept.

Worked example. FEEDBACK_OVERLAYS today contains only the idle overlay. When toast notifications are added later, the right pattern is:

```
/* ============================================================================
   FEEDBACK_OVERLAYS: IDLE OVERLAY
   ...
   Prefixes: idle
   ============================================================================ */
.idle-overlay { ... }
.idle-message { ... }

/* ============================================================================
   FEEDBACK_OVERLAYS: TOAST NOTIFICATIONS
   ...
   Prefixes: toast
   ============================================================================ */
.toast { ... }
.toast.success { ... }
```

Two banners of the same type, each with its own description and prefix declaration. The FILE ORGANIZATION list gets a new entry. The catalog's prefix-matching enforces that toast classes don't accidentally end up in the idle overlay banner.

---

### 3.9 Comments

Comments serve four roles:

1. **Purpose comments** — single-line block comment immediately preceding a base class definition. Format: `/* One-sentence purpose. */`. Required (Section 3.6).
2. **Trailing variant comments** — inline block comment on the same line as the opening `{` of a variant. Format: `.foo.bar { /* state or context */ ... }`. Required (Section 3.7).
3. **Section banners** — multi-line block comments enclosing a section's title, description, and prefix declaration. Required (Section 3.3).
4. **Sub-section markers** — inline block comment between banners of the same section. Format: `/* -- label -- */`. Optional (Section 3.8).

No other comment forms are recognized. Stray block comments at file scope (between sections, before the first banner after the file header, or after the last `}`) are a parse error.

Comment content rules:

- Purpose and trailing comments are written in present-tense, descriptive style. They describe what the rule does, not why it does it.
- Section banner descriptions may be 1-5 sentences. They explain what the section contains, the design intent, and any cross-section or cross-file relationships worth noting.

---

### 3.10 Custom property tokens

Custom properties (CSS variables) are the canonical mechanism for sharing values across the codebase. Tokens live in `:root` declarations inside the FOUNDATION section of `cc-shared.css`. Pages consume tokens via `var(--token-name)` references.

Token naming convention:

```
--<category>-<role>-<modifier>
```

| Component | Purpose | Examples |
|-----------|---------|----------|
| `category` | Token type. Fixed enum: `color`, `size`, `font`, `duration`, `shadow`, `z`, `gradient`. | `color`, `size`, `font` |
| `role` | Functional purpose, role-based not appearance-based. | `bg-card`, `accent-platform`, `text-muted` |
| `modifier` | Optional. Distinguishes variants of the same role. | `hover`, `default`, `lg`, `sm` |

Examples:

- `--color-bg-card` — base card background
- `--color-bg-card-hover` — card background on hover
- `--color-accent-platform` — platform-section accent color
- `--size-spacing-md` — medium spacing token
- `--font-size-content` — content text size
- `--duration-default` — default animation duration
- `--z-modal` — modal stacking context z-index
- `--shadow-popup` — drop shadow for popup elements
- `--gradient-progress-default` — canonical progress bar gradient

Token usage rules:

- Values used in 2+ places across the codebase are tokens. Values used only once may stay as literals; the catalog will surface promotion candidates if a literal repeats.
- Pages reference tokens via `var(...)` only. Direct hex literals where a token exists emit `DRIFT_HEX_LITERAL`.
- Tokens are defined once in cc-shared.css's FOUNDATION section. Page files do not redeclare tokens or override them.
- Adding a new token requires a small update to cc-shared.css and a Component_Registry version bump on `ControlCenter.Shared`. Each new token is a permanent commitment to a value.

The category enum is closed. Adding a new category (e.g., `--breakpoint-*` for responsive thresholds) requires a spec amendment.

---

### 3.11 @keyframes

`@keyframes` definitions are permitted only in the FOUNDATION section of `cc-shared.css`. Pages may consume keyframes via `animation: <keyframe-name> ...` references, but may not define new keyframes locally.

Violations emit `FORBIDDEN_KEYFRAMES_LOCATION`.

Each `@keyframes` block produces a catalog row of type `CSS_KEYFRAMES DEFINITION` with the keyframe name as `component_name`.

---

### 3.12 Required patterns summary

Every CSS file must:

1. Open with a spec-compliant file header (Section 3.2)
2. Define all sections under recognized section types in declared order (Sections 3.3, 3.4)
3. Declare valid prefixes in every section banner (Section 3.5)
4. Precede every base class with a purpose comment (Section 3.6)
5. Add a trailing inline comment on every variant (Section 3.7)
6. Use the state-on-element pattern for stateful UI (Section 3.7.1)
7. Use a new banner per distinct concept; sub-section markers only for sub-components (Section 3.8)
8. Reference shared values via `var(--token-name)` only (Section 3.10)
9. Match the FILE ORGANIZATION list to banner titles verbatim, in order (Section 3.2)
10. Place all `@keyframes` definitions in cc-shared.css's FOUNDATION section (Section 3.11)

---

### 3.13 Forbidden patterns

| Pattern | Drift code | Notes |
|---------|------------|-------|
| Element selector outside FOUNDATION (e.g., `body`, `h1`, `a`) | `FORBIDDEN_ELEMENT_SELECTOR` | Only permitted in FOUNDATION for CSS reset rules. |
| Universal selector outside FOUNDATION (`*`) | `FORBIDDEN_UNIVERSAL_SELECTOR` | Only permitted in FOUNDATION. |
| Attribute selector outside FOUNDATION (`[type="text"]`) | `FORBIDDEN_ATTRIBUTE_SELECTOR` | Only permitted in FOUNDATION. |
| Pseudo-element outside FOUNDATION not attached to a class | `FORBIDDEN_PSEUDO_ELEMENT_LOCATION` | `.foo::before` is OK (class-scoped); bare `::-webkit-scrollbar` is not. |
| Descendant combinator (whitespace-separated selectors) | `FORBIDDEN_DESCENDANT` | Use state-on-element pattern (Section 3.7.1). |
| Child combinator (`>`) | `FORBIDDEN_CHILD_COMBINATOR` | Same rationale as descendant. |
| Adjacent sibling combinator (`+`) | `FORBIDDEN_ADJACENT_SIBLING` | Same rationale. |
| General sibling combinator (`~`) | `FORBIDDEN_GENERAL_SIBLING` | Same rationale. |
| Compound depth ≥ 3 (`.foo.bar.baz`) | `COMPOUND_DEPTH_3PLUS` | Maximum two classes per selector. |
| Stacked pseudo-classes (`:hover:focus`) | `FORBIDDEN_STACKED_PSEUDO` | One pseudo-class per rule maximum. |
| `:not(...)` in any form | `FORBIDDEN_NOT_PSEUDO` | Use state-on-element pattern. |
| `@import` | `FORBIDDEN_AT_IMPORT` | All shared content via cc-shared.css linked from HTML. |
| `@font-face` | `FORBIDDEN_AT_FONT_FACE` | Font definitions are not part of the spec. |
| `@supports` | `FORBIDDEN_AT_SUPPORTS` | Conditional CSS not currently needed. |
| `@keyframes` outside FOUNDATION | `FORBIDDEN_KEYFRAMES_LOCATION` | See Section 3.11. |
| Custom property defined outside FOUNDATION | `FORBIDDEN_CUSTOM_PROPERTY_LOCATION` | All tokens centralized in cc-shared.css. |
| Hex literal where token exists | `DRIFT_HEX_LITERAL` | Use `var(--color-...)` references. |
| Pixel literal where token exists | `DRIFT_PX_LITERAL` | Use `var(--size-...)` references. |
| CHANGELOG block in file header | `FORBIDDEN_CHANGELOG_BLOCK` | Git is the source of truth for change history. |

`@media` is **permitted** in any section as of the Gap 6 spec amendment. Wrapped rules are still subject to all other spec rules (class naming, prefix matching, no descendants, etc.). The wrapping `@media` expression is captured in the catalog's `parent_function` column.

The complete list of drift codes with descriptions appears in Appendix A.

---

### 3.14 Illustrative example

A minimal complete page CSS file demonstrating every required pattern:

```css
/* ============================================================================
   xFACts Control Center - Example Page Styles (example.css)
   Location: E:\xFACts-ControlCenter\public\css\example.css
   Version: Tracked in dbo.System_Metadata (component: ExampleModule.ExamplePage)

   Page-specific styles for the Example dashboard. Universal chrome (nav
   bar, header bar, refresh info, sections, modals) is provided by
   cc-shared.css. This file contains only the example page's local content
   classes — example cards and example badges.

   FILE ORGANIZATION
   -----------------
   LAYOUT: PAGE GRID
   CONTENT: EXAMPLE CARDS
   CONTENT: EXAMPLE BADGES
   ============================================================================ */


/* ============================================================================
   LAYOUT: PAGE GRID
   ----------------------------------------------------------------------------
   Top-level layout for the example page content area.
   Prefixes: ex
   ============================================================================ */

/* The two-column grid container for the example page. */
.ex-page-grid {
    display: grid;
    grid-template-columns: 2fr 1fr;
    gap: var(--size-spacing-2xl);
}


/* ============================================================================
   CONTENT: EXAMPLE CARDS
   ----------------------------------------------------------------------------
   Example status cards. Each card may render in success, warning, or
   critical state via state classes on the card element.
   Prefixes: ex
   ============================================================================ */

/* Example status card — base card layout. */
.ex-status-card {
    background: var(--color-bg-card-hover);
    border: var(--size-border-thin) solid var(--color-border-default);
    border-radius: var(--size-radius-lg);
    padding: var(--size-spacing-lg);
}

.ex-status-card.success { /* success state — teal accent */
    border-color: var(--color-accent-shared);
}

.ex-status-card.warning { /* warning state — yellow accent */
    border-color: var(--color-accent-departmental);
}

.ex-status-card.critical { /* critical state — orange accent */
    border-color: var(--color-status-critical);
}

.ex-status-card:hover { /* hover state — subtle background lift */
    background: var(--color-bg-card-deep);
}


/* ============================================================================
   CONTENT: EXAMPLE BADGES
   ----------------------------------------------------------------------------
   Small pill badges used inside the status cards to label entry types.
   Prefixes: ex
   ============================================================================ */

/* Example badge pill — base styling. */
.ex-badge {
    display: inline-block;
    font-size: var(--font-size-default);
    font-weight: 600;
    padding: 2px var(--size-spacing-md);
    border-radius: var(--size-radius-sm);
    text-transform: uppercase;
}

.ex-badge.type-info { /* informational badge — blue */
    background: var(--color-bg-tag-info);
    color: var(--color-accent-platform);
}

.ex-badge.type-warning { /* warning badge — yellow */
    background: var(--color-bg-tag-warning);
    color: var(--color-accent-departmental);
}
```

This file produces the following catalog rows when parsed:

- 1 × `FILE_HEADER DEFINITION`
- 3 × `COMMENT_BANNER DEFINITION` (one per section)
- 7 × `CSS_CLASS DEFINITION` (`ex-page-grid`, `ex-status-card`, `ex-badge` are bases; the others are variants of those)
- Multiple `CSS_VARIANT DEFINITION` rows for each `.foo.bar` and `.foo:hover`
- Multiple `CSS_VARIABLE USAGE` rows for every `var(...)` reference

Zero drift rows expected.

---

### 3.15 What the parser extracts

For each CSS file, the parser produces rows of these types:

| Row type | Source | Notes |
|----------|--------|-------|
| `FILE_HEADER DEFINITION` | The opening file header block | One per file. Carries `purpose_description` from the header text. |
| `COMMENT_BANNER DEFINITION` | Each section banner | `signature` = TYPE, `component_name` = NAME, `purpose_description` = description block. |
| `CSS_CLASS DEFINITION` | Each base class declaration | `component_name` = class name, `purpose_description` = the preceding purpose comment. |
| `CSS_VARIANT DEFINITION` | Each variant of a base class | `component_name` = base class name, `signature` = full variant selector, `variant_type` and `qualifier_*` describe the variant shape. |
| `CSS_VARIABLE DEFINITION` | Each `--token: value` declaration in `:root` | One per token. Lives only in cc-shared.css's FOUNDATION. |
| `CSS_VARIABLE USAGE` | Each `var(--token-name)` reference | One per reference. Includes the source rule's selector in `parent_function`. |
| `CSS_KEYFRAMES DEFINITION` | Each `@keyframes name { ... }` block | One per keyframe definition. |
| `CSS_RULE DEFINITION` | Forbidden at-rules emitted to attach drift codes | Used internally for `@import`, `@font-face`, `@supports`. |

Each row may carry one or more drift codes in `drift_codes` (newline-delimited string) when the rule violates a spec requirement.

---

### 3.16 Design decisions

The decisions that shaped this spec, with rationale. Treat as historical reference; the body of Part 3 above is the spec proper. Decisions are dated and grouped by theme.

#### Foundational decisions (initial spec design, 2026-05-03)

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-05-03 | Variants are own catalog rows, not annotations on the base class. | A variant is a distinct rule with its own properties, drift conditions, and consumption pattern. Treating it as a separate row makes "list every variant of `.bk-pipeline-card`" a single SELECT and supports cleaner per-variant drift annotation. |
| 2026-05-03 | Generic qualifier columns (`qualifier_1`, `qualifier_2`) rather than typed columns per variant shape. | Three variant shapes (class, pseudo, compound_pseudo) fit cleanly into two qualifier slots. Adding a new shape would mean schema migration; keeping the columns generic absorbs reasonable growth without that cost. |
| 2026-05-03 | Drift detection is row-level via `drift_codes` and `drift_text` columns. | Putting drift codes on the row itself (rather than a separate annotations table) makes "show me every row in violation" a single filter. Multiple drift codes on a row are newline-delimited. |
| 2026-05-03 | Sections are author-ordered within a type. | Type-order rules (FOUNDATION → CHROME → LAYOUT → CONTENT → OVERRIDES → FEEDBACK_OVERLAYS) are enforced; ordering between same-type sections is the author's call. |
| 2026-05-03 | Compound depth is capped at two classes. | Three-class compounds (`.foo.bar.baz`) are typically signs that a state should be promoted to the styled element directly (Section 3.7.1). The cap forces this discipline. |

#### Spec gaps surfaced during initial validation (2026-05-03)

| Gap | Resolution |
|-----|------------|
| **Gap 1** — Element / universal / attribute selectors needed inside FOUNDATION for CSS resets. | These three drift codes are suppressed when the active section is FOUNDATION. Outside FOUNDATION they remain forbidden. |
| **Gap 2** — Pseudo-elements like `::-webkit-scrollbar` are legitimate FOUNDATION content. | New drift code `FORBIDDEN_PSEUDO_ELEMENT_LOCATION` flags pseudo-elements outside FOUNDATION not attached to a class. Inside FOUNDATION pseudo-elements are unrestricted; outside FOUNDATION only class-scoped pseudo-elements (`.foo::before`) are permitted. |
| **Gap 3** — `Prefixes: (none)` sentinel. | FOUNDATION sections have no class definitions to validate. The `Prefixes:` line is still required as a structural marker; using `(none)` opts out of `PREFIX_MISMATCH`. `MISSING_PREFIXES_DECLARATION` still fires when the line is entirely absent. |
| **Gap 4** — Cross-section prefix overlap. | Authoring discipline only, no parser change. Two sections may declare overlapping prefixes if the concerns are genuinely separate. |
| **Gap 5** — `FEEDBACK_OVERLAYS` as sixth section type. | Added as the sixth recognized type. Section type order is now FOUNDATION → CHROME → LAYOUT → CONTENT → OVERRIDES → FEEDBACK_OVERLAYS. Covers idle overlays, toast notifications, loading spinners, confirmation flashes — transient, behavior-driven viewport elements that don't fit cleanly into the other five types. |
| **Gap 6** — `@media` permitted in any section. | Originally forbidden, but responsive design is a legitimate need. `@media` is now permitted; wrapped rules are spec-evaluated normally; the `@media` expression is captured in the catalog's `parent_function` column. `FORBIDDEN_AT_MEDIA` drift code retired. See OQ-CSS-3 in Part 10 for the deferred follow-on (modeling `@media`-wrapped rules as variants rather than as fresh class definitions). |

#### Direction decisions (Checkpoint B onward)

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-05-03 | New `cc-shared.css` file built spec-compliant from day one; `engine-events.css` retires after pages migrate. | Solves the longstanding naming-confusion problem where the de-facto shared resource was called `engine-events.css` despite serving as `ControlCenter.Shared`. New file is spec-compliant from day one; old file stays in place during page-by-page migration so production never breaks; old file is deleted when the last page has migrated. |
| 2026-05-03 | Custom property naming convention: `--<category>-<role>-<modifier>` with fixed category enum. | Designed from scratch rather than carrying forward existing ad-hoc conventions. Category enum (`color`, `size`, `font`, `duration`, `shadow`, `z`, `gradient`) keeps the variable space organized and enables targeted drift queries. Role is descriptive of purpose, not appearance, which keeps naming stable when colors change. |
| 2026-05-03 | FILE ORG list matches banner titles verbatim. | The list was originally numbered with abbreviated titles, which forced a separate matching layer between list and banners. Switching to verbatim makes the list a true table of contents — exactly the banner titles in order. The parser cross-validates with no abstraction layer in between. |
| 2026-05-03 | State-on-element pattern formalized as Section 3.7.1. | Surfaced in three independent contexts during initial validation (OQ-CSS-1, the depth-3 nav-link compounds, the storage-drive descendant rules) — every one of them resolved to the same form. Worth promoting to a named pattern with its own subsection. |
| 2026-05-03 | Sub-section markers vs new banners. | Documented as Section 3.8 to prevent the "fast-and-loose" failure mode of jumbling unrelated content under one banner. New banner per distinct concept; sub-section markers for sub-components only. |
| 2026-05-03 | One-off literals stay as hex/px literals; tokens are for repetition. | Adding a token to cc-shared.css for a value used only once over-engineers the shared resource. The catalog will surface promotion candidates if a literal appears in 2+ places. |
| 2026-05-03 | Section status promoted from `[DRAFT]` to `[FINALIZED]`. | Validated against two files (cc-shared.css 622/0, backup.css 245/0). Spec is robust enough that future amendments will be surgical patches rather than structural rewrites. Subject to small amendments as more pages migrate, but considered solid as of this date. |

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

**Reading Q1 results.** Q1 produces *candidates*, not confirmed problems. Each result row is a "this might be reinvention" finding that requires human review:

- **Intentional collisions exist.** Two unrelated classes can legitimately share a name across files because the name happens to fit two different concepts (e.g., a top-level navigation `header-bar` in engine-events.css versus a panel-internal `header-bar` somewhere else). The catalog can't distinguish "same name, same intent, should consolidate" from "same name, different intent, should rename for clarity." Both outcomes are valid resolutions; the query just surfaces the cases worth looking at.

Treat Q1 as a starting list to walk through, not a list to act on automatically. For each match, look at the `raw_text` of both rows to compare the actual rule bodies — if they're equivalent, consolidate; if they're materially different, rename one of them. (Since the bug-fix pass, `raw_text` captures the full rule body, so comparison is a single SQL query rather than a manual file-open exercise.)

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

### OQ-CSS-1 — `:not()` and stacked pseudo-classes  `[RESOLVED 2026-05-03]`

**Resolution: forbid both.**

The CSS spec's two-qualifier-slot model represents three variant shapes (class, pseudo, compound_pseudo). Two real-world constructs in the codebase did not fit:

1. **`:not(...)`** — a pseudo-class that takes a complex argument (e.g., `:not(:disabled)`, `:not(.active)`).
2. **Stacked pseudo-classes** on a single selector (e.g., `.btn:hover:not(:disabled)` chains `:hover` and `:not(:disabled)`).

The first parser run found 13 occurrences across 6 files. Two paths considered: forbid both, or extend the catalog model to accommodate them.

**Decision.** Forbid both, with two new drift codes:

- `FORBIDDEN_NOT_PSEUDO` — flags any selector containing `:not(...)`.
- `FORBIDDEN_STACKED_PSEUDO` — flags any compound with two or more pseudo-classes.

**Rationale.** Catalog clarity is the initiative's purpose. Allowing these would require either a third qualifier slot, JSON-shaped qualifiers, or a delimiter convention inside `variant_qualifier_2` — all of which break the clean "every variant fits one of three shapes" property and force SQL queries to handle special cases. The 13 affected source cases are a one-time rewrite cost; the catalog clarity is permanent. State-class patterns (which is where the rewrites land) are also more inspectable than `:not()` constructs because the state lives in HTML class names rather than invisible CSS guards.

**Refactor recipe** (used during conversion):

The general pattern: replace any `:not(:state)` guard or stacked-pseudo construct with explicit state classes, ordered in the file so cascade does the override.

Worked example — `.nav-btn:hover:not(:disabled)`:

*Before:*
```css
.nav-btn { ... }

.nav-btn:hover:not(:disabled) {
    background: var(--color-bg-button-hover);
}

.nav-btn:disabled {
    background: var(--color-bg-disabled);
    opacity: 0.5;
    cursor: not-allowed;
}
```

The HTML uses the native `disabled` attribute on `<button>`.

*After:*
```css
.nav-btn { ... }

.nav-btn:hover { /* hover state for the navigation button */
    background: var(--color-bg-button-hover);
}

.nav-btn.disabled { /* disabled state — overrides hover via cascade order */
    background: var(--color-bg-disabled);
    opacity: 0.5;
    cursor: not-allowed;
}
```

The HTML now adds an explicit `disabled` *class* alongside the native `disabled` *attribute*. JavaScript that toggles the disabled state must add/remove the class together with the attribute.

**General refactor steps:**

1. Identify the guard pseudo (typically `:not(:disabled)` or `:not(.active)`).
2. Drop the guard from the hover/active rule so it's just `.foo:hover` or `.foo:active`.
3. Promote the guarded condition to its own rule (`.foo.disabled` or `.foo.active`).
4. Place the guarded rule *after* the hover/active rule so cascade order makes it win.
5. Update HTML and JS so the guarded class is added/removed alongside any underlying state (e.g., the native `disabled` attribute).

**Catalog effect.** Each refactored case nets out to roughly +1 to +2 catalog rows, because what was one fused rule becomes two or three discrete rules. Across the 13 cases, expect approximately +15 to +20 net new rows post-refactor. This is the intended behavior — the catalog gaining rows from refactoring reflects the splitting of one tangled construct into several cleanly-cataloguable components.

### OQ-CSS-2 — Same-functionality, different-names grouping

Q5 in Part 8 finds classes repeated locally in many files by exact name match. But chrome standardization also needs to identify the trickier case where the same functionality exists across multiple pages under different names — a "small refresh status text" element might be `.refresh-info` on one page, `.update-text` on another, `.last-updated-display` on a third. Each is implemented from scratch, none share a name, and exact-match queries miss the duplication entirely.

The previous Asset_Registry shape included a manual `component_subtype` column that was never populated but was originally intended for this purpose — manually grouping classes into logical buckets like SLIDEOUT, MODAL, OVERLAY, BADGE so analysis queries could surface "every component in the SLIDEOUT bucket" regardless of name. The column was dropped in the v0.2 schema migration because it was unused and redundant with `component_type`/`variant_type` for the typing role. The grouping concept itself is still valid and unsolved.

Possible directions when this is revisited:

- **Manual classification via a separate annotations table** keyed on natural identity (`component_type` + `component_name`). Survives truncate-and-reload of Asset_Registry. A class can belong to multiple groups (a `SLIDEOUT` class can also be an `OVERLAY`).
- **Heuristic auto-grouping from existing data** — pattern-match on component_name (anything containing `slide` → SLIDEOUT bucket, anything containing `modal` → MODAL bucket). Approximate but zero manual cost. Could seed the manual layer.
- **Property-body similarity matching** — compare `raw_text` (full rule bodies, available since the bug-fix pass) across rows to find classes whose declarations are substantially similar even though their names differ. Hardest but most accurate; now feasible since `raw_text` actually carries the body content.
- **JSON or many-to-many tags column on Asset_Registry directly.** Simpler than a separate table; ties tags to the row lifecycle (rebuilt every parse run), so heuristic auto-grouping fits this shape better than manual classification.

To be revisited when chrome standardization actually begins. Not blocking; flagged here so the consideration doesn't get lost.

### (Other open questions added as they arise.)

### OQ-CSS-3 — `@media`-wrapped rules as variants  `[QUEUED 2026-05-03]`

**Surfaced during Checkpoint C (backup.css refactor).** The Gap 6 amendment permits `@media` in any section, but the parser currently catalogs `@media`-wrapped rules as `CSS_CLASS DEFINITION` rows — same as a fresh class definition. This forces authors to add a purpose comment before the wrapped rule, even though conceptually the wrapped rule is the *same class* under different conditions, not a new definition.

The cleaner model: classify `@media`-wrapped rules as `CSS_VARIANT` rows. Add a fourth `variant_type` value `media`; carry the `@media` expression in `qualifier_2`. The wrapped rule then needs only the trailing inline comment (variant rule) rather than a preceding purpose comment (base class rule).

**Concrete shape:**

| variant_type | qualifier_1 | qualifier_2 | example |
|---|---|---|---|
| `media` | (NULL) | the media query expression | `.foo { ... }` inside `@media (max-width: 1200px)` |

**Why deferred and not addressed in Gap 6:** the immediate fix to allow `@media` was small (delete from the forbidden list, drop the drift code). Reclassifying wrapped rules as variants involves changes to row-emission logic, the variant_type CHECK constraint on `Asset_Registry`, the catalog query patterns documented in Part 8, and the spec's variant table in Section 3.7. Worth doing, but as a clean follow-on rather than bolted onto the Gap 6 fix.

**Target:** revisit during the Part 11 CSS refactor initiative when more page files surface `@media` rules and the variant model is exercised at scale. If by file 8-10 of the refactor the current "wrapped rules need purpose comments" requirement is producing meaningful friction, this jumps to top priority. If the friction is minor, the change can wait until JS spec work begins (where similar context-modifier patterns may surface and inform a unified design).

**Acceptance criteria when this is taken on:**

- `Asset_Registry.variant_type` CHECK constraint includes `media`
- Parser emits `CSS_VARIANT DEFINITION` rows for `@media`-wrapped rules with `variant_type = 'media'` and the `@media` expression in `qualifier_2`
- Spec Section 3.7 variant table updated to four shapes
- Section 3.6 (class definitions) and 3.7 (variants) text adjusted to clarify that purpose comments precede base classes only, not their `@media` variants
- Migration: existing rows from prior parser runs are reclassified by re-running the parser (truncate-and-reload model means no historic-data migration cost)

---

## Part 11 - CSS Refactor Initiative  `[ACTIVE 2026-05-03]`

The CSS spec is finalized (Part 3) and validated end-to-end against two files (cc-shared.css 622/0, backup.css 245/0). Before pivoting to Part 4 (JS spec), all remaining CSS files in the codebase get refactored to spec. This section captures the plan.

### 11.1 Rationale

Three reasons to do this now, in sequence, before JS work begins:

1. **Validation at scale.** Two files is a small sample. Refactoring all ~28 CSS files will reveal whatever spec gaps remain. If 26 more files pass through and surface no new amendments, that's strong evidence the spec is genuinely complete. If 2-3 surface gaps, finding them now is much cheaper than finding them after JS work has built on a "stable" CSS foundation that turned out to have holes.
2. **The drift report becomes a powerful before/after.** Most CC pages currently show 70-90% drift. After this initiative, every spec-version file will show 0% drift while originals stay cataloged at their current drift level. The catalog literally shows the platform's CSS hygiene improving in real time.
3. **No deferred-work failure mode.** Items that get filed under "we'll come back to this" tend to never get done. Doing the refactor now — keeping CSS focus until CSS is *done* — eliminates that risk.

### 11.2 The `*-spec.css` pattern

Files dropped into `\public\css\` get parsed regardless of Object_Registry registration. The parser registers them in `Asset_Registry` with whatever filename they have; un-registered files just don't get a source-of-truth link.

This enables a clean side-by-side workflow:

- **Original `<page>.css`** stays in place; live page keeps working
- **New `<page>-spec.css`** sits alongside as the spec-compliant version
- **Parser sees both;** drift report shows original at its current drift level, spec version at zero drift
- **Object_Registry stays clean** — no junk entries to remember to delete

When a future coordinated CSS+HTML+JS migration session brings the page on-spec, the spec-version file becomes the new live file and the original retires. The catalog reflects the cutover automatically.

### 11.3 Sequencing

Work runs in three phases by file size and complexity. Smaller files first for momentum and quick validation cycles.

#### Phase 1 — Small pages (~80-180 rows each)

Quick wins. Build muscle memory with the spec. Each should fit in a single session.

| File | Current rows | Current drift |
|------|--------------|---------------|
| `business-intelligence.css` | 43 | 100% |
| `client-relations.css` | 81 | 93% |
| `replication-monitoring.css` | 133 | 97% |
| `business-services.css` | 177 | 95% |

#### Phase 2 — Medium pages (~150-300 rows each)

The bulk of the work. Spec-version files here may surface 1-2 small gaps; expect to amend the spec or parser as needed before continuing.

| File | Current rows | Current drift |
|------|--------------|---------------|
| `applications-integration.css` | 160 | 92% |
| `jboss-monitoring.css` | 151 | 95% |
| `bidata-monitoring.css` | 181 | 96% |
| `client-portal.css` | 224 | 67% |
| `dbcc-operations.css` | 213 | 91% |
| `dm-operations.css` | 237 | 100% |
| `index-maintenance.css` | 197 | 99% |
| `batch-monitoring.css` | 237 | 95% |
| `platform-monitoring.css` | 232 | 97% |
| `file-monitoring.css` | 296 | 94% |
| `server-health.css` | 289 | 96% |

#### Phase 3 — Large pages (~400-750 rows each)

Most complex. Likely to surface the most spec-stress. Tackle last with smaller-page lessons under the belt. May need 2+ sessions per file.

| File | Current rows | Current drift |
|------|--------------|---------------|
| `jobflow-monitoring.css` | 397 | 93% |
| `admin.css` | 592 | 95% |
| `bdl-import.css` | 749 | 96% |

#### Phase 4 — Engine-events.css retirement

Once enough page files have migrated to consume from `cc-shared.css`, `engine-events.css` can be progressively pruned and eventually retired. The parser will report `engine-events.css` row counts dropping over time as page files stop referencing classes that were duplicated there.

#### Phase 5 — Documentation CSS files (separate evaluation)

The `docs-*.css` files (`docs-controlcenter.css`, `docs-base.css`, `docs-reference.css`, etc.) serve the documentation HTML pages, not Control Center pages. Their lower current-drift percentages (50-70%) suggest they were already partially aligned. These are evaluated separately after CC pages are done — the spec may apply directly, or they may need a docs-specific sub-spec.

### 11.4 Per-file workflow

Each file follows the same pattern:

1. **Pull current file from GitHub** at session start
2. **Inspect current drift** via the catalog to understand what's out of compliance
3. **Identify any token gaps** — values used in this file but not in cc-shared.css. Decide per value: promote to a token (if used in 2+ pages) or keep as one-off literal.
4. **If tokens needed,** add to cc-shared.css first. Re-validate cc-shared.css for zero drift after each token addition.
5. **Build the spec-version file** as `<page>-spec.css`
6. **Drop in `\public\css\`** alongside original
7. **Re-run parser**
8. **Validate zero drift** on the spec-version file
9. **Iterate as needed** — if drift surfaces, fix and re-run
10. **Commit to GitHub** once clean

### 11.5 Token gap handling

cc-shared.css will grow modestly during this work. New tokens get added when:

- Value appears in 2+ pages (cross-page reuse confirmed)
- Existing token names are extended (e.g., new `--gradient-progress-warning` if a warning-state progress bar surfaces)

cc-shared.css does *not* grow when:

- Value appears in only one page (stays as a literal there; promotion candidate flagged in catalog)
- Existing token covers the use case adequately

The catalog query "what hex/px literals appear in 2+ unmigrated files" surfaces promotion candidates *before* the file refactor, so tokens get added in advance and the file refactor consumes the token directly.

### 11.6 Spec amendments expected

Realistic expectation: 2-4 small spec amendments will surface during this work. Each follows the established pattern:

- Gap surfaces during a refactor session
- Resolution decided (parser change, spec amendment, authoring discipline)
- Parser updated, doc updated, CHANGELOG entries added
- Re-run all previously-validated files to confirm no regression
- Continue with current file's refactor

The spec is robust; the catalog is the verification engine; small amendments don't destabilize the work.

### 11.7 Tracking

A simple status table tracks per-file progress:

| File | Status | Spec-version rows | Drift | Session refactored |
|------|--------|-------------------|-------|--------------------|
| `cc-shared.css` | ✓ DONE | 622 | 0 | 2026-05-03 (Checkpoint B) |
| `backup.css` | ✓ DONE | 245 | 0 | 2026-05-03 (Checkpoint C) |
| (remaining 26 files) | pending | | | |

The table is updated at the end of every refactor session. Done = the spec-version file is committed to GitHub and validated at zero drift in the catalog.

### 11.8 Prefix Registry

Each CC page CSS file declares a 3-character prefix that scopes its page-local classes. The prefix appears in every class name (`.bkp-pipeline-card`, `.adm-user-table`, etc.) and in the `Prefixes:` line of every section banner in that file. Prefix length is fixed at 3 characters platform-wide for consistency, future-proofing, and readability.

The table below is the canonical mapping. **Every new CC page CSS file gets a row here at the time the file is created — no exceptions.** This is the single source of truth for prefix-to-page assignment.

| File | Prefix | Status |
|------|--------|--------|
| `cc-shared.css` | (none — uses `--<category>-*` token namespace) | DONE |
| `admin.css` | `adm` | pending |
| `applications-integration.css` | `aai` | pending |
| `backup.css` | `bkp` | DONE |
| `batch-monitoring.css` | `bat` | pending |
| `bdl-import.css` | `bdl` | pending |
| `bidata-monitoring.css` | `bid` | pending |
| `business-intelligence.css` | `biz` | pending |
| `business-services.css` | `bsv` | pending |
| `client-portal.css` | `clp` | pending |
| `client-relations.css` | `clr` | pending |
| `dbcc-operations.css` | `dbc` | pending |
| `dm-operations.css` | `dmo` | pending |
| `file-monitoring.css` | `flm` | pending |
| `index-maintenance.css` | `idx` | pending |
| `jboss-monitoring.css` | `jbm` | pending |
| `jobflow-monitoring.css` | `jfm` | pending |
| `platform-monitoring.css` | `plt` | pending |
| `replication-monitoring.css` | `rpm` | pending |
| `server-health.css` | `srv` | pending |
| `docs-*.css` files | TBD | Phase 5 evaluation |

#### Prefix selection rules

1. **3 characters.** Fixed length platform-wide. Not 2, not 4 — three.
2. **Lowercase letters only.** No digits, no underscores, no hyphens. The hyphen separates the prefix from the rest of the class name (`.bkp-pipeline-card`).
3. **Derive from the page name.** First-letter abbreviations of the meaningful words in the page name are preferred (`jobflow-monitoring` → `jfm`, `replication-monitoring` → `rpm`). Fall back to phonetic shortenings when first-letter shortenings collide (`business-intelligence` → `biz` rather than `bus` since `bus-` would collide with `business-services`).
4. **No collisions.** No two pages may share a prefix. The catalog can verify this by querying `Object_Registry` once `prefix` is added as a column (see future enhancement note below).
5. **No platform-token collisions.** Prefixes must not start with strings reserved for platform tokens (`color`, `size`, `font`, `duration`, `shadow`, `z`, `gradient`). This prevents authorial confusion when reading a class like `.color-primary-card` (is "color" a prefix or a category?).

#### Future enhancement — prefix tracking in the catalog

Today, the prefix-to-page mapping lives only in this Markdown table. A future enhancement is to add a `prefix` column to `dbo.Module_Registry` (or `dbo.Object_Registry`, depending on which table is the better home) so the platform itself enforces and queries prefix uniqueness:

```sql
ALTER TABLE dbo.Module_Registry ADD prefix CHAR(3) NULL;
ALTER TABLE dbo.Module_Registry ADD CONSTRAINT UQ_Module_Registry_prefix UNIQUE (prefix);
```

Benefits:

- **Uniqueness enforced at the database layer** — a developer adding a duplicate prefix gets a constraint violation rather than discovering the conflict later.
- **Catalog queries can join on prefix** — "show me every CSS class belonging to JobFlow Monitoring" becomes `JOIN Module_Registry mr ON 'jfm-' = mr.prefix + '-' WHERE Asset_Registry.component_name LIKE mr.prefix + '%'` (rough sketch).
- **The CSS spec parser can validate prefixes against `Module_Registry`** — flag any section banner whose declared prefix doesn't match the registered prefix for the file's component.

Tracked as a deferred enhancement; revisit during the Refactor Initiative or when the parser exercises `Module_Registry` more heavily. Until then, this table is the canonical mapping.

### 11.9 Completion criteria

The CSS refactor initiative completes when:

1. Every CC page CSS file has a `*-spec.css` counterpart at zero drift
2. Documentation CSS files are evaluated and (if applicable) refactored
3. `engine-events.css` is retired or has a documented retirement timeline
4. The catalog drift report shows >95% of all CSS rows in the codebase at zero drift

At that point Part 11 promotes to `[COMPLETE]` and Part 4 (JS spec design) begins.

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
| `UNKNOWN_SECTION_TYPE` | A section banner declares a TYPE not in the enumerated list (FOUNDATION, CHROME, LAYOUT, CONTENT, OVERRIDES, FEEDBACK_OVERLAYS). |
| `SECTION_TYPE_ORDER_VIOLATION` | Section types appear out of the required order (FOUNDATION → CHROME → LAYOUT → CONTENT → OVERRIDES → FEEDBACK_OVERLAYS). |
| `MISSING_PREFIXES_DECLARATION` | A section banner is missing the mandatory `Prefixes:` line in its description block. |
| `DUPLICATE_FOUNDATION` | More than one CSS file in the codebase contains a FOUNDATION section. Exactly one is allowed. |
| `DUPLICATE_CHROME` | More than one CSS file in the codebase contains a CHROME section. Exactly one is allowed. |
| `PREFIX_MISMATCH` | A class name does not begin with one of the prefixes declared in its containing section's banner. |
| `MISSING_PURPOSE_COMMENT` | A base class definition is not preceded by a single-line purpose comment. |
| `MISSING_VARIANT_COMMENT` | A class variant does not carry a trailing inline comment after the opening brace. |
| `FORBIDDEN_ELEMENT_SELECTOR` | A rule's selector is an element selector (e.g., `body`, `h1`, `a`) and the rule is **outside** a FOUNDATION section. Element-only styling is permitted in FOUNDATION (where reset rules legitimately rely on it) but forbidden everywhere else. Suppressed by the parser when the active section is FOUNDATION-typed. |
| `FORBIDDEN_UNIVERSAL_SELECTOR` | A rule uses the universal selector `*` and the rule is **outside** a FOUNDATION section. Permitted in FOUNDATION for reset rules; forbidden everywhere else. Suppressed by the parser when the active section is FOUNDATION-typed. |
| `FORBIDDEN_ATTRIBUTE_SELECTOR` | A rule's selector contains an attribute matcher (`[type="radio"]`) and the rule is **outside** a FOUNDATION section. Permitted in FOUNDATION (form-element normalization); forbidden everywhere else. Suppressed by the parser when the active section is FOUNDATION-typed. |
| `FORBIDDEN_ID_SELECTOR` | A rule's selector includes an `#id` token (alone or compound). Class-based styling required. |
| `FORBIDDEN_GROUP_SELECTOR` | A rule's selector contains a comma (`,`). Each selector gets its own definition block. |
| `FORBIDDEN_DESCENDANT` | A rule's selector contains a descendant combinator (whitespace between two simple selectors). Restructure as a separate class definition. |
| `FORBIDDEN_CHILD_COMBINATOR` | A rule's selector contains a child combinator (`>`). Restructure as a separate class definition. |
| `FORBIDDEN_SIBLING_COMBINATOR` | A rule's selector contains a sibling combinator (`+` or `~`). Restructure as a separate class definition. |
| `COMPOUND_DEPTH_3PLUS` | A compound selector contains three or more class tokens (`.a.b.c`). Refactor as a single class plus at most one modifier class. |
| `PSEUDO_INTERLEAVED` | A pseudo-class appears between two class tokens (`.a:hover.b`). Pseudo-classes must come last in any compound. |
| `FORBIDDEN_NOT_PSEUDO` | A selector contains `:not(...)`. Express the negation as an explicit state class instead (see Part 10's OQ-CSS-1 resolution for the refactor recipe). |
| `FORBIDDEN_STACKED_PSEUDO` | A compound selector contains two or more pseudo-classes. Reduce to a single pseudo and express the additional condition as a class modifier. |
| `FORBIDDEN_PSEUDO_ELEMENT_LOCATION` | A pseudo-element selector (e.g., `::before`, `::-webkit-scrollbar`) appears outside FOUNDATION and is not attached to a class. Pseudo-elements are unrestricted inside FOUNDATION; outside FOUNDATION they must be class-scoped (`.foo::before` ok, bare `::before` not ok). |
| `FORBIDDEN_AT_IMPORT` | The file contains an `@import` rule. |
| `FORBIDDEN_AT_FONT_FACE` | The file contains an `@font-face` rule. Font definitions are not part of the CSS file format spec. |
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
| 0.2 | 2026-05-03 | CSS spec design and implementation completed end-to-end in one session. **Design phase:** Q1-Q30 decisions captured. New Part 2 added (Asset_Registry Catalog Model). Part 3 (CSS Files) drafted with full structural spec, allowed/forbidden patterns, illustrative example, and parser-extraction reference. Old Parts 3-9 renumbered to Parts 4-10. Appendix A (32 drift codes) added. **Implementation phase:** Schema migration ran successfully. CSS populator rewritten with variant emission, drift detection, FILE_HEADER row, three-pass execution. **Validation phase:** First clean parser run produced 5,913 rows with 87.1% drift coverage. Two parser bugs caught and fixed: drift code array concatenation, file header misclassification. **Sanity sweep findings:** Five additional parser bugs queued for next session and one spec gap (OQ-CSS-1). Part 8 (Compliance Reporting) populated with five standard queries. Part 9.1 added documenting the detection-vs-verification asymmetry. OQ-CSS-2 (same-functionality-different-names) added to Part 10. |
| 0.3 | 2026-05-03 | Bug-fix-pass and OQ-CSS-1 checkpoint. **Parser bug-fix pass complete:** all five sanity-sweep issues from v0.2 resolved in a single populator update. (1) `CSS_RULE` drift codes wrapped with `@(...)` for array safety. (2) Per-compound drift checks consolidated into `Add-CompoundDriftCodes`, called from both primary and descendant paths. (3) HTML_ID emission decoupled from CSS_CLASS/CSS_VARIANT emission so compounds with both an ID and classes produce both row types; descendant IDs become USAGE rows. (4) Shared-map architecture split per-zone (CC vs docs) with `Get-CssZone` deriving zone from filepath. (5) `Format-RuleBody` builds full rule text from AST declarations, threaded through to every emitted row so `raw_text` captures the rule body. **OQ-CSS-1 resolved by forbidding `:not()` and stacked pseudo-classes** — two new drift codes added (`FORBIDDEN_NOT_PSEUDO`, `FORBIDDEN_STACKED_PSEUDO`); refactor recipe (state-class pattern) documented in Part 10's resolution entry. **Two clean parser runs:** post-bug-fix produced 5,949 rows / 87.3% drift; OQ-CSS-1 run unchanged in row count and confirmed both new drift codes attach to expected cases (13 stacked, 15 `:not()` instances across 13 source cases). **Notable finding documented in Part 3.15 decision log:** CC zone has zero shared custom properties; this is a content gap for the conversion phase. **Doc updates:** Part 2.3 (HTML_ID description expanded for primary/descendant emission). Part 2.8 decision log entry for HTML_ID emission rule. Part 3.6 cross-reference to OQ-CSS-1 resolution. Part 3.12 forbidden-patterns table extended with two new codes. Part 3.14 zone-aware scope resolution note added. Part 3.15 decision log extended with five bug-fix-pass entries plus OQ-CSS-1 resolution and the empty-CC-vars finding. Part 10 OQ-CSS-1 marked `[RESOLVED]` with full rationale and refactor recipe. Appendix A extended with two new codes. **Queued next:** validation round-trip on one representative CSS file → drift-code wiring tidy pass → if clean, promote Part 3 to `[FINALIZED]` and begin Part 4 (JS spec). |
| 0.4 | 2026-05-03 | FOUNDATION-section exemption checkpoint and cc-shared.css design. Spec amendments Gaps 1-4 incorporated. Direction set on cc-shared.css build, custom property naming convention, backup.css as test page. Section status remained `[DRAFT]` pending validation pass. (See session log entry "2026-05-03 (3)" for full detail.) |
| 0.5 | 2026-05-03 | **Part 3 promoted to `[FINALIZED]`.** Three checkpoints completed in one session: Checkpoint B (cc-shared.css built, 622 rows / 0 drift), Checkpoint C (backup.css refactored, 245 rows / 0 drift), Checkpoint D (doc finalization). Doc rewrite under Option B (clean reference structure, design history moved to Section 3.16 with attribution). **New spec content:** Section 3.7.1 State-on-element pattern as a dedicated subsection capturing the recurring discipline from OQ-CSS-1, the depth-3 nav-link compounds, and the storage-drive descendant rules. Section 3.8 Sub-section markers vs new banners — the discipline rule preventing the "fast-and-loose" failure mode of jumbling unrelated content under one banner. **Spec amendments:** Gap 5 (`FEEDBACK_OVERLAYS` as sixth section type — full integration into ordering, parser arrays, drift-code descriptions). Gap 6 (`@media` permitted in any section; `FORBIDDEN_AT_MEDIA` retired). Gap 7 surfaced and queued as OQ-CSS-3 in Part 10 with concrete shape (treat `@media`-wrapped rules as `CSS_VARIANT` with new `media` variant_type carrying the @media expression in `qualifier_2`). **Parser updates:** `$SectionTypeOrder` array gains `FEEDBACK_OVERLAYS`; FILE ORG list parser accepts both numbered and un-numbered entries with `-- description` strip; **BannerTitles bug fix** — comparison was using `ComponentName` (just NAME) against list-side `<TYPE>: <NAME>` strings; fixed to assemble `"$Signature: $ComponentName"`. `@media` removed from forbidden at-rules. New shared tokens added to cc-shared.css: `--gradient-progress-default`. **New Part 11 added — CSS Refactor Initiative:** plan to refactor all remaining ~28 CSS files to spec before pivoting to JS spec design. Three-phase sequencing (small pages first, large pages last), `*-spec.css` side-by-side pattern (parser sees both, Object_Registry stays clean), per-file workflow, token gap handling, expected 2-4 small spec amendments along the way. Status table tracks per-file progress; cc-shared.css and backup.css already DONE. **Section 11.8 Prefix Registry added** — 3-character prefixes fixed platform-wide; full mapping table for all 18 CC pages (e.g., `bkp` for backup, `bdl` for BDL Import, `biz` for Business Intelligence). Backup.css renamed `bk-` → `bkp-` to conform; 93 occurrences updated cleanly. Future enhancement noted: add `prefix` column to `dbo.Module_Registry` for database-level uniqueness enforcement. **Queued next:** Part 11 Phase 1 — page-by-page refactor sequence beginning with the smaller files. |
| 0.4 | 2026-05-03 | FOUNDATION-section exemptions checkpoint and cc-shared.css design preparation. **Four spec gaps surfaced and resolved during cc-shared.css design preparation:** (1) Element / universal / attribute selectors permitted inside FOUNDATION sections only; the three corresponding drift codes are suppressed when the active section is FOUNDATION-typed. (2) New drift code `FORBIDDEN_PSEUDO_ELEMENT_LOCATION` flags pseudo-elements outside FOUNDATION that aren't attached to a class. (3) `Prefixes: (none)` sentinel recognized in banner extractor as a valid declaration that opts out of `PREFIX_MISMATCH`; `MISSING_PREFIXES_DECLARATION` only fires when the line is entirely absent. (4) Cross-section prefix overlap addressed as authoring discipline (no parser change). **Parser updated and verified:** 5,949 rows / 87.4% drift; new code correctly attaches to all four bare scrollbar pseudo-element rules in `engine-events.css`; FOUNDATION-aware suppression has nothing to suppress yet because no FOUNDATION-typed banner exists in the codebase. **Major direction decision:** new file `cc-shared.css` will be built spec-compliant from day one and will live alongside `engine-events.css` until pages migrate one-by-one. Solves the longstanding naming-confusion problem where the de-facto shared resource was called `engine-events.css` despite serving as `ControlCenter.Shared`. **Custom property naming convention locked in:** three-part `--<category>-<role>-<modifier>` pattern with fixed category enum (`color`, `size`, `font`, `duration`, `shadow`, `z`). **Backup.css selected as the test page** for the page-level rewrite, chosen for low traffic and reasonable representativeness. **Doc updates:** Top-level status bumped. Current State rewritten with this checkpoint summary, the new naming convention, the cc-shared decision, and the Checkpoints B-D plan. Session log extended with entry (3). Part 3.3 extended with `(none)` sentinel rule. Part 3.4 FOUNDATION row extended with the reset-rule allowance note. Part 3.12 forbidden-patterns table updated for the three exempted codes plus new `FORBIDDEN_PSEUDO_ELEMENT_LOCATION`. Part 3.15 decision log extended with five new entries (Gaps 1-3, cc-shared decision, naming convention). Appendix A extended with new code; three exempted codes' descriptions updated to note FOUNDATION-aware suppression. **Queued next:** Checkpoint B (cc-shared.css build) → Checkpoint C (backup.css refactor) → Checkpoint D (validation complete, Part 3 promotes to `[FINALIZED]`). |

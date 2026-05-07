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
| `CC_HTML_Spec.md` | HTML route file ID conventions and structure (pre-design). |
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

Bring all four populators (CSS, HTML, JS, PS) and their specs current first. Then sweep the Phase 1 page set across all four file types together. Then page-at-a-time migration for the remaining ~22 pages.

The original plan was to drive each spec to completion sequentially while refactoring Phase 1 pages within each file type as the spec stabilized. The cost-vs-progress trade became unfavorable — each spec/populator iteration was expensive, page-by-page refactors within a single file type didn't ship visible value, and we weren't yet in a position to migrate any page end-to-end.

---

## Current state

*Last updated: 2026-05-06.*

**Active workstream — populator alignment plus prefix registry validation.** What started as a small change pass for prefix registry validation expanded mid-session into a broader populator alignment effort after the populators were re-read with fresh eyes. The CSS and JS populators currently use different traversal patterns, different banner-detection helpers, different drift-attachment models, and different section-tracking approaches. Doing the registry validation work in two divergent codebases would mean writing the same logic twice in two idioms, then refactoring both during a future alignment pass. Decision was made to fold the registry validation work into a single coordinated alignment pass rather than touch the populators twice.

**Helpers file delivered this session.** `xFACts-AssetRegistryFunctions.ps1` (~1015 lines, 20 functions) was created as a new shared infrastructure script. Centralizes row construction, dedupe tracking, drift code attachment (hybrid model: master-table validation plus optional row-specific context), occurrence-index computation, Object_Registry and Component_Registry registry loads, bulk insert plus DataTable shape, comment-text cleanup, banner detection plus parsing, file-header parsing, pre-built section list construction with body-line ranges, file-org match check, and the generic AST visitor walker. Per-language logic (visitor scriptblock body, per-row emitters, selector decomposition, variant shape helpers, HTML attribute extraction, AST parent-context helpers) stays in each populator. The file lives alongside `xFACts-OrchestratorFunctions.ps1` and `xFACts-IndexFunctions.ps1` in `E:\xFACts-PowerShell\`. Not yet deployed to production — needs to ship together with the refactored CSS populator that consumes it.

**Next session action item — refactor `Populate-AssetRegistry-CSS.ps1` to consume the new helpers file and to perform prefix registry validation.** This is a substantive refactor (CSS populator is currently 2,394 lines) covering eleven discrete change items:

1. **Add second dot-source line.** Open of script becomes:
   ```powershell
   . "$PSScriptRoot\xFACts-OrchestratorFunctions.ps1"
   . "$PSScriptRoot\xFACts-AssetRegistryFunctions.ps1"
   Initialize-XFActsScript -ScriptName 'Populate-AssetRegistry-CSS' -Execute:$Execute
   ```

2. **Delete helper functions that moved to the helpers file.** From the CSS populator, remove the local definitions of `New-RowSkeleton`, `Add-Drift`, `Test-AddDedupeKey`, `Set-OccurrenceIndices`, `Get-BannerInfo`, `ConvertTo-CleanCommentText`, `Get-NullableValue`, and the inline DataTable construction logic. All replaced by helpers-file equivalents (`New-AssetRegistryRow`, `Add-DriftCode`, etc.). Update all call sites accordingly.

3. **Update `$DriftDescriptions` master table.** Rename `MISSING_PREFIXES_DECLARATION` → `MISSING_PREFIX_DECLARATION` (no backwards-compat alias). Add `MALFORMED_PREFIX_VALUE` and `PREFIX_REGISTRY_MISMATCH`. Add table entries for the spec drift codes that are missing from the populator's table: `FORBIDDEN_ADJACENT_SIBLING`, `FORBIDDEN_GENERAL_SIBLING`, `DRIFT_PX_LITERAL`. Detection wiring for these is item 12 below.

4. **Update Object_Registry load to use helper.** Replace the inline query with `Get-ObjectRegistryMap -FileType 'CSS'`. Note column-name asymmetry: `Object_Registry`'s PK is `registry_id`; `Asset_Registry`'s FK column is `object_registry_id`. The helper handles this internally.

5. **Add `Get-ComponentRegistryPrefixMap` call.** Loads `(file_name → cc_prefix)` map alongside the Object_Registry load. Used by the registry-validation logic in step 8.

6. **Convert walking model from direct recursion to visitor pattern.** The 290-line `Add-RowsFromAst` recursive walker becomes a visitor scriptblock body invoked via `Invoke-AstWalk` from the helpers file. Most of the per-node dispatch logic translates directly. Note that `Invoke-AstWalk`'s skip list was extended to handle PostCSS node properties (`selector`, `selectors`, `prop`, `important`, `text`, `params`) in addition to acorn's; behavior should be correct but is the most likely place for a CSS-specific edge case to surface.

7. **Replace running-state section tracking with pre-built section list.** Remove `$script:CurrentBannerInfo`, `$script:CurrentBannerOuter`, `$script:CurrentSectionTypes`, `$script:CurrentFilePrefixes`, `$script:PreviousSibling` and the running-state updates inside the walker. Replace with a per-file call to `New-SectionList` at the top of Pass 2's per-file loop, then `Get-SectionForLine` lookups inside the per-row emitters. The section list provides the same information the running state did, but correctly indexed by line range rather than dependent on walker traversal order.

8. **Add registry validation logic for COMMENT_BANNER rows.** Per `CC_CSS_Spec.md` §5.4 and §13. Two new drift codes ride on the COMMENT_BANNER row:
   - `MALFORMED_PREFIX_VALUE` — banner declares anything other than a single 3-char lowercase token or `(none)`. Use the helpers' `Test-PrefixValueIsValid`.
   - `PREFIX_REGISTRY_MISMATCH` — banner's declared prefix disagrees with the registry. **Strict (Option B) for CSS:** if the file's `cc_prefix = NULL`, banners must declare `(none)`; any non-`(none)` value is `PREFIX_REGISTRY_MISMATCH`. If the file's `cc_prefix = X`, banners must declare `X`; any other value (including `(none)`) is `PREFIX_REGISTRY_MISMATCH`. CSS has no per-section legitimate `(none)` cases — the strict reading applies uniformly across every banner.
   
   These checks live alongside the existing `MISSING_PREFIX_DECLARATION` and `UNKNOWN_SECTION_TYPE` logic in the comment-handling branch of the visitor.

9. **Remove the entire verification block at the end of the script.** The end-of-run "Verification:" section with its three `Get-SqlData` queries and `Format-Table` outputs is deleted. These were development-only conveniences; queries run in SSMS instead going forward.

10. **Update CHANGELOG.** One concise entry describing the alignment refactor and registry validation work. Header CHANGELOG entries from this point forward stay short; older wordy entries stay as-is.

11. **Source file pairing already done.** Dirk completed the source-file edits before this session: every CSS file has `Prefixes:` → `Prefix:`, and `cc-shared.css`'s non-FOUNDATION banners have their values reset to `(none)`. The populator is currently out of sync with these source files — running it produces drift on every banner — and stays out of sync until this refactor lands. Acceptable per the "do it right, do it once" stance.

12. **Wire detection logic for previously-undetected CSS drift codes.** The CSS spec defines several drift codes whose detection logic was never implemented in the populator. Wire each one as part of this refactor:
    - `BLANK_LINE_INSIDE_RULE` — blank line between the opening `{` and closing `}` of a class definition. Detect via PostCSS source position analysis on each rule's body.
    - `EXCESS_BLANK_LINES` — more than one blank line between top-level constructs. Detect during the pass that walks top-level nodes; track gap line counts.
    - `FORBIDDEN_COMPOUND_DECLARATION` — two or more declarations on the same line (`color: red; padding: 10px;`). Detect via PostCSS source position analysis on adjacent declarations.
    - `FORBIDDEN_COMMENT_STYLE` — a block comment that doesn't match one of the four allowed kinds (purpose, trailing variant, banner, sub-section marker). Hardest to define rigorously; may end up flagging anything that doesn't structurally fit the four shapes. Acceptable starting heuristic: any block comment that isn't immediately above a class definition (purpose), isn't on the same line as a `{` (trailing variant), isn't banner-shaped (rule lines plus TYPE: NAME), and doesn't match the `/* -- label -- */` marker form.
    - Plus the three new entries from item 3 (`FORBIDDEN_ADJACENT_SIBLING`, `FORBIDDEN_GENERAL_SIBLING`, `DRIFT_PX_LITERAL`). The first two are PostCSS selector-tree checks (mirror the existing `FORBIDDEN_DESCENDANT` and `FORBIDDEN_CHILD_COMBINATOR` logic). The third needs a known size-token list to compare against — same shape as the existing `DRIFT_HEX_LITERAL` check.

The refactored CSS populator is the validation case for the helpers file. Function signatures may need small tweaks during this pass; that's expected. Estimated post-refactor size: ~450 lines (down from 2,394). The size drop comes from extracting helpers, removing the verification block, and removing duplicate state-tracking code.

**JS populator is the second target.** After CSS lands and validates, `Populate-AssetRegistry-JS.ps1` (3,983 lines) gets the same alignment treatment plus the JS-specific registry validation. JS validation is **strict with carve-outs (Option B)**: every banner on a non-shared file must declare the file's `cc_prefix`, EXCEPT the hooks banner, IMPORTS section, and INITIALIZATION section, which legitimately declare `(none)` per `CC_JS_Spec.md` §5.2. Estimated post-refactor size: ~2,400-2,500 lines (down from 3,983). The JS populator is larger because the visitor scriptblock body and the per-row emitters are irreducibly per-language. JS may not fit in a single session with CSS; depends on context budget.

**Active spec documents:**

- `CC_CSS_Spec.md` — Production. Singular `Prefix:` form, registry validation in §5.4, drift codes `MALFORMED_PREFIX_VALUE` and `PREFIX_REGISTRY_MISMATCH` in §13. Spec is ahead of the populator; populator catches up via the alignment refactor described above.
- `CC_JS_Spec.md` — Production. §5.4 registry validation includes the explicit carve-out for the hooks banner, IMPORTS, and INITIALIZATION sections. Spec is ahead of the populator.
- `CC_HTML_Spec.md` — pre-design (stub). Active when HTML populator catch-up resumes.
- `CC_PS_Module_Spec.md`, `CC_PS_Route_Spec.md` — pre-design (stubs). Queued after HTML.

**Phase 1 CSS refactor work — complete and at zero drift:**

| File | Prefix |
|------|--------|
| `cc-shared.css` | (uses `--<category>-*` token namespace; banners declare `Prefix: (none)`) |
| `backup.css` | `bkp` |
| `business-intelligence.css` | `biz` |
| `client-relations.css` | `clr` |
| `replication-monitoring.css` | `rpm` |
| `business-services.css` | `bsv` |

**Phase 1 JS refactor work:**

| File | Prefix | Status |
|------|--------|--------|
| `cc-shared.js` | (uses prefix-free shared namespace; banners declare `Prefix: (none)`) | DONE — zero file-attributable drift |
| `engine-events.js` | (legacy shared file) | LEGACY — deactivates after Phase 1 page JS files migrate to `cc-shared.js` |
| `backup.js` | `bkp` | QUEUED for Phase 1 batch |
| `business-intelligence.js` | `biz` | QUEUED for Phase 1 batch |
| `client-relations.js` | `clr` | QUEUED for Phase 1 batch |
| `replication-monitoring.js` | `rpm` | QUEUED for Phase 1 batch |
| `business-services.js` | `bsv` | QUEUED for Phase 1 batch |

The five Phase 1 page JS files batch with their CSS, HTML, and PS counterparts during the Phase 1 batch sweep. Each Phase 1 page transitions from pre-spec to fully compliant in a single coordinated session.

**Queued work:**

1. CSS populator alignment refactor plus registry validation (next session — see action item above).
2. JS populator alignment refactor plus registry validation (immediately following CSS — same session if context permits, otherwise next session).
3. HTML populator catch-up plus HTML spec design. Bring `Populate-AssetRegistry-HTML.ps1` to current schema, resolve the dynamic-class strategy question (see Pipeline doc), then design `CC_HTML_Spec.md` against existing HTML conventions. HTML populator should also be refactored to consume `xFACts-AssetRegistryFunctions.ps1` for consistency.
4. PS populator plus PS spec design (modules and routes). Two specs, one populator covering both. Will also consume the helpers file.
5. Phase 1 batch sweep — refactor the five Phase 1 pages across all four file types together.
6. Page-at-a-time migration for the remaining ~22 pages.

**Blocked on:** nothing.

---

## Prefix Registry

The prefix registry lives in `dbo.Component_Registry.cc_prefix`. Each CC page's component carries a 3-character lowercase prefix that scopes its page-local identifiers across CSS class names, HTML class attributes, and JS top-level identifiers. Components without a CC page (shared resources, infrastructure, vendor libraries) carry `cc_prefix = NULL` and their files declare `Prefix: (none)` in section banners.

The column is enforced by:

- A filtered unique index (`UQ_Component_Registry_cc_prefix`) preventing two components from claiming the same prefix.
- A CHECK constraint (`CK_Component_Registry_cc_prefix`) requiring exactly three lowercase ASCII letters, with a case-sensitive collation override so uppercase variants are rejected.

The CSS and JS populators read this column at startup to validate banner-declared prefixes. See `CC_CSS_Spec.md` Section 5.4 and `CC_JS_Spec.md` Section 5.4 for the validation rule.

Adding a new CC page: insert the component row in `Component_Registry` with the chosen `cc_prefix`, then create the page's CSS and JS files with banners that declare that prefix. The populators will validate on the next run.

---

## Conversion tracking model

Files exist in one of three states during the initiative:

- **Pre-spec** — file has not been refactored against any current spec. Drift codes in the catalog reflect the file's pre-refactor state.
- **Partially compliant** — file has been refactored against one or more file-type specs but not all. The page works but the catalog reflects mixed compliance.
- **Fully compliant** — file has been refactored against every applicable spec and parses at zero drift across all of them.

The current direction (page-at-a-time migration after JS and HTML specs land) means each page transitions directly from pre-spec to fully compliant within a single coordinated session, eliminating the partially-compliant state for those pages.

---

## Open questions

### OQ-INIT-1 — Long-term home for migration notes content

The CSS refactor migration notes capture per-file refactor decisions (class renames, structural flattenings, shared-token additions) that may have long-term reference value beyond the active migration period. Under the truncate-and-reload model `dbo.Asset_Registry` doesn't carry persistent annotations; manual annotations of any kind go in a separate annotations table keyed on the natural key.

If any migration notes content has long-term reference value, a permanent SQL home that survives parser reloads and is linkable to `Asset_Registry` rows would be useful. The annotations table itself may be the right home, or a separate per-file decision-log table parallel to it. To be evaluated as Phase 1 page migrations complete and the migration notes documents approach retirement.

### OQ-INIT-2 — `(none)` loophole on JS page files

Under the strict-with-carve-outs (Option B) registry validation rule for JS, only the hooks banner, IMPORTS section, and INITIALIZATION section may declare `Prefix: (none)` on a page file. Any other section declaring `(none)` on a page file is `PREFIX_REGISTRY_MISMATCH`. This is the chosen behavior — closes the loophole that a permissive (Option A) reading would leave open, where a developer could declare `(none)` on any banner to bypass prefix-matching entirely. Captured here as a closed question for traceability; no further action needed.

### OQ-INIT-3 — Object_Metadata enrichment for the populator family

The Asset_Registry table itself has full column-level descriptions in `dbo.Object_Metadata` as of 2026-05-06. The four parser scripts (`parse-css.js`, `parse-js.js`, `Populate-AssetRegistry-CSS.ps1`, `Populate-AssetRegistry-JS.ps1`) and the shared helpers file (`xFACts-AssetRegistryFunctions.ps1`) carry only base rows (description, module, category) plus, for the helpers file, a data_flow row and two design_note rows. The populators specifically were left with base rows only because their content was about to be substantively rewritten in the alignment refactor — populating rich enrichment for soon-to-change scripts would just create churn.

After all four populators (CSS, HTML, JS, PS) are aligned, deployed, and the orchestrator (`Refresh-AssetRegistry.ps1`) is in production, return to the populator family and add the full enrichment row set: data_flow rows describing what each populator reads and writes, design_note rows capturing the architectural patterns used (visitor walking model, pre-built section list, drift attachment, registry validation, zone-aware shared/local resolution), and any relationship_note rows linking populators to the table they populate and to their helper scripts. Same level of richness the helpers file's current rows reach, scaled across the family.

The Asset_Registry table itself may also benefit from additional enrichment beyond column descriptions: design_note rows for the truncate-and-reload model, the natural key, the Object_Registry / Asset_Registry column-name asymmetry, and the variant model. Compliance queries from each spec doc could land as `query` rows. To revisit at the same time as the populator enrichment.

This work has no external dependency beyond the populator pipeline being complete; it's a pure documentation pass. Captured here so it doesn't get overlooked.

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

---

## CSS spec evolution

This section tracks the evolution of `CC_CSS_Spec.md` since the initiative began. Each entry summarizes what changed in the spec and why, in chronological order.

### 2026-05-04 — Initial release

Defined the section-type taxonomy (`FOUNDATION`, `CHROME`, `LAYOUT`, `CONTENT`, `OVERRIDES`, `FEEDBACK_OVERLAYS`) with FOUNDATION and CHROME limited to `cc-shared.css`. Established the 3-character page-prefix discipline for class names, with the `Prefixes:` line in every section banner. Mandated a single-line purpose comment preceding every base class and a trailing inline comment on every variant. Forbade CHANGELOG blocks in file headers. Defined the variant model (class, pseudo, compound_pseudo) with `variant_qualifier_1` and `variant_qualifier_2` columns capturing the variant shape. Forbade descendant combinators and depth-3+ compounds, establishing the state-on-element pattern as the canonical alternative. Centralized custom property tokens in FOUNDATION with the `--<category>-<role>-<modifier>` naming convention and a closed category enum. Defined eight CSS-relevant component types and a drift code reference covering ~30 codes.

### 2026-05-06 — Editorial restructure

Spec restructured to operating-manual style, matching the JS spec's pattern. Body sections now contain rules only, with rationale moved to a dedicated Appendix at the end. All inline code examples consolidated into a single Examples section. The forbidden-patterns table's Rationale column was dropped from the body and consolidated into the Appendix. Status, Owner, and cross-document references removed from the preamble. The previous one-line revision history was migrated to this Initiative document and removed from the spec itself. No rule changes.

### 2026-05-06 — Prefix singularization and registry validation

The plural `Prefixes:` field name was retired in favor of singular `Prefix:`, matching the JS spec's existing convention. The plural form had encouraged misuse: section banners in `cc-shared.css` had accumulated comma-separated lists of section-grouping commentary words (`nav`, `page, header`, `engine`, etc.) that were not valid page prefixes at all. The singular form makes the field's meaning unambiguous — exactly one page prefix, or `(none)`. Three associated changes: drift code `MISSING_PREFIXES_DECLARATION` was renamed to `MISSING_PREFIX_DECLARATION`; new drift code `MALFORMED_PREFIX_VALUE` covers banners declaring anything other than a single 3-char prefix or `(none)`; new Section 5.3 documents the single-prefix-per-banner rule. Section 5.4 was added to formalize registry validation: each banner's declared prefix is cross-referenced against `Component_Registry.cc_prefix` for the file's component, with `PREFIX_REGISTRY_MISMATCH` drift on disagreement. CSS validation is strict (no per-section `(none)` carve-outs — CSS has no analog to JS's hooks/IMPORTS/INITIALIZATION sections that legitimately declare `(none)` on a page file). Populator enforcement is queued for the alignment refactor.

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
- **2026-05-06** — Shared infrastructure architecture decided. New `xFACts-AssetRegistryFunctions.ps1` created as a domain-specific helpers file parallel to `xFACts-IndexFunctions.ps1`. Each populator dot-sources `xFACts-OrchestratorFunctions.ps1` and `xFACts-AssetRegistryFunctions.ps1` explicitly (matching the established two-line pattern from the index family). Helpers file does not internally dot-source OrchestratorFunctions; the calling script does. Function naming inside helpers file is mixed: `Verb-AssetRegistryThing` for domain-scoped functions whose bare names would be ambiguous, bare `Verb-Thing` for genuinely generic utilities. Helpers file delivered this session (~1015 lines, 20 functions); not yet deployed pending the CSS populator refactor that consumes it.
- **2026-05-06** — End-of-run verification queries removed from both populators. The query blocks at the end of each populator (3 queries in CSS, 8 in JS) were development conveniences for inspecting catalog content alongside summary output during console runs. Catalog inspection moves to SSMS going forward. Frees ~150 lines across the two populators.
- **2026-05-06** — Asset_Registry column descriptions populated in `dbo.Object_Metadata`. 24 description rows, one per column. Descriptions are intentionally brief (a handful of words to one sentence) and populator-agnostic — no references to specific populators, no value enumerations, no per-language branching. Specifics live in the per-file-type spec docs and in per-populator enrichment rows. Two populators (`Populate-AssetRegistry-CSS.ps1`, `Populate-AssetRegistry-JS.ps1`) and the helpers file (`xFACts-AssetRegistryFunctions.ps1`) registered in `dbo.Object_Registry` under `Tools.Utilities`. Populators got base metadata rows only (description, module, category) since they're about to be substantively refactored; helpers file got base rows plus data_flow and two design_note rows since it's in final form. Full enrichment for the populator family deferred to OQ-INIT-3.

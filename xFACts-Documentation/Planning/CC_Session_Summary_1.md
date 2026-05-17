# Session Summary - JS Populator Calibration and Comment Taxonomy Amendment

**Date:** 2026-05-17
**Focus:** JS populator drift calibration, CC_JS_Spec.md Section 13 amendment, cc-shared.js cleanup, Object_Registry + Object_Metadata baseline rows for HTML and PS populators, PS populator scope narrowed to exclude .psd1
**Disposition:** All planned work landed and verified via post-rerun results. cc-shared.js drift dropped from 25 rows to 4 (all expected residuals). -spec files now show only architectural-migration drift. HTML and PS populators registered in Object_Registry with baseline Object_Metadata rows; full enrichment deferred. PS populator no longer scans .psd1 config files - they live in Object_Registry only, per the table-role distinction surfaced this session. Ready for Phase 1 page migrations next session.

---

## Context entering the session

Prior session ended with the HTML populator item 9 (HTML_TEXT categorical naming) implemented and 4 populators run end-to-end. JS populator produced 25 drift rows on cc-shared.js and substantial drift across the 5 -spec files (business-services-spec, replication-monitoring-spec, business-intelligence-spec, batch-monitoring-spec, dmops-archive-spec). The decision had been made to promote the -spec files over re-doing from production (1.1% drift on -spec files vs 36-95% drift on production files), but the architectural carryover from pre-bootloader days remained: -spec files still contain `INITIALIZATION: PAGE BOOT` banner sections with `DOMContentLoaded` handlers that should be `<prefix>_init` functions inside `FUNCTIONS:` sections under the current bootloader pattern.

A draft §13 amendment had been started but was rejected because it would have re-introduced `INITIALIZATION` to the section taxonomy, which had been deliberately removed when the bootloader shift was finalized. This session restarted that work from the correct premise.

---

## Drift group analysis (cc-shared.js as canonical reference)

The 25 drift rows broke down into 8 groups when analyzed file-by-file. Investigation showed several groups were populator false positives rather than real source-side drift.

| Group | Drift Code | Verdict | Disposition |
|-------|-----------|---------|-------------|
| 1 | EXCESS_BLANK_LINES | Populator bug | Fixed via Change 1+3 |
| 2 | FILE_ORG_MISMATCH | Bootloader migration carry-over | Resolves on page refactor |
| 3 | UNKNOWN_SECTION_TYPE | Same as Group 2 | Resolves on page refactor |
| 4 | (Various rename-resolved codes) | Real | Resolves on refactor |
| 5a | JS_HTML_ID_UNRESOLVED (page-side IDs) | Real | Resolves when HTML migrated |
| 5b | JS_HTML_ID_UNRESOLVED (`engine-popup`, `engine-idle-overlay`) | Populator gap | Added to backlog |
| 5c | JS_HTML_ID_UNRESOLVED (`page-error-banner`) | Real | Resolves when page shells add placeholder |
| 6 | MISSING_CONSTANT_COMMENT | Real | Fixed in cc-shared.js this session |
| 7 | FORBIDDEN_PROPERTY_ASSIGN_EVENT | Real | Fixed in cc-shared.js this session |
| 8 | BLANK_LINE_INSIDE_FUNCTION_BODY_AT_SCOPE | Populator bug | Fixed via Change 1+2 |

Plus the pervasive **FORBIDDEN_COMMENT_STYLE** drift, which on examination was firing on legitimate inline body comments inside function bodies and on legitimate purpose comments preceding the `DOMContentLoaded` bootloader expression. Both cases were spec-coverage gaps, not source drift.

---

## Populator bug root cause

Two detection sites in Populate-AssetRegistry-JS.ps1 used the same flawed logic:

**EXCESS_BLANK_LINES** (Pass 3, top-level constructs) and **BLANK_LINE_INSIDE_FUNCTION_BODY_AT_SCOPE** (inside FunctionDeclaration visitor) both computed `($curStart - $prevEnd) -gt 2` as their drift threshold. This counts line-number deltas, which inflates whenever comment lines sit between two statements. A statement ending on line 217, followed by one blank line (218), followed by a four-line purpose comment (219-222), followed by the next statement (223), produces `curStart - prevEnd = 6` even though only ONE blank line exists. Both checks fired falsely on every reasonably-formatted function.

Verification: `awk` over cc-shared.js confirmed zero sequences of two-or-more consecutive blank lines anywhere in the file. The drift was 100% false positive.

---

## Spec amendment (CC_JS_Spec.md §13)

Section 13 previously enumerated four comment kinds: file header, section banner, purpose comment, sub-section marker. The amendment broadens to five.

### Changes

1. **Kind 3 (purpose comment) - scope broadened.** Now permitted before top-level expression statements that introduce named behavior, not just before named definitions. Required for declarations; optional for expression statements. The canonical case is `document.addEventListener('DOMContentLoaded', ...)`.

2. **Kind 5 (NEW) - inline body comment.** Block comments inside function bodies, explaining the next statement or sub-group. Always optional. Catalogued as JS_BLOCK_COMMENT rows for queryability, but no drift fires for presence or absence.

3. **§13.2 picked up a third bullet** describing the content rules for inline body comments: not required, judgment call by author, trivial code shouldn't carry them.

### Final text (replacing the prior §13 in CC_JS_Spec.md)

```markdown
## 13. Comments
Comments serve five roles, and only five:
1. **File header** - a single block comment at line 1 (Section 2).
2. **Section banners** - multi-line block comments enclosing a section's title, description, and prefix declaration (Section 3).
3. **Purpose comments** - single block comment immediately preceding a function, class, method, constant, state variable, hook, or top-level expression statement that introduces named behavior (e.g., `document.addEventListener('DOMContentLoaded', ...)`). Required for the named definitions in that list; optional for top-level expression statements where the author judges a comment helpful.
4. **Sub-section markers** - inline block comment between definitions in a section, used as a lightweight visual divider. Format: `/* -- label -- */`. Optional.
5. **Inline body comments** - block comment appearing inside a function body, explaining the immediately-following statement or sub-group of statements. Always optional. Permitted only inside function bodies (not at file scope, not between class members).
No other comment forms are recognized. Stray block comments outside the five allowed kinds emit `FORBIDDEN_COMMENT_STYLE` drift on the file's `JS_FILE` row.
### 13.1 Inline comments
Inline `//` line comments are permitted inside function bodies for explaining specific lines or blocks of logic. They are not cataloged.
Inline `//` line comments are forbidden at file scope. Each file-scope `//` comment emits a `JS_LINE_COMMENT` row at its own line with `FORBIDDEN_FILE_SCOPE_LINE_COMMENT` drift attached.
### 13.2 Comment content rules
- Purpose comments are written in present-tense, descriptive style. They describe what the function/constant/state does, not why it does it.
- Section banner descriptions may be 1-5 sentences. They explain what the section contains.
- Inline body comments explain what the next statement or block of statements does. They are not required, and trivial or self-explanatory code should not carry them. Their presence is a judgment call by the author.
```

**Status:** Drafted in this session. **Not yet applied** to CC_JS_Spec.md in GitHub. Dirk to apply.

---

## Populator changes (Populate-AssetRegistry-JS.ps1)

Five surgical changes total. Final file in `/mnt/user-data/outputs/Populate-AssetRegistry-JS.ps1` (4087 lines, 831/831 braces balanced).

### Change 1: New `Get-MaxConsecutiveBlankLines` helper

Added after `Test-LineInsideFunction` in the `AST POSITION / CONTEXT HELPERS` section. Examines source text between two statement positions, counts the longest run of whitespace-only lines, returns the max. Comment lines count as content. Handles CRLF endings.

### Change 2: BLANK_LINE_INSIDE_FUNCTION_BODY_AT_SCOPE uses new helper

Inside the `FunctionDeclaration` visitor case. Replaces `($curStart - $prevEnd) -gt 2` with `(Get-MaxConsecutiveBlankLines -Source $script:CurrentFileSource -StartLine $prevEnd -EndLine $curStart) -gt 1`. Now correctly detects more than one consecutive truly-blank line between body statements.

### Change 3: EXCESS_BLANK_LINES (Pass 3) uses new helper

Pass 3 cross-file compliance section. Same shift from line-delta to actual blank count. Uses `$cached.Source` accessor (added a `$cached = $astCache[$file]` line to make this work).

### Change 4: Stray block comment detection recognizes inline body comments

Inside the `FORBIDDEN_COMMENT_STYLE` block. Two parts:

1. **Moved the `$functionRanges` computation up** above the stray-comment loop. It was previously computed only for the line-comment check that follows; now it's needed by both.
2. **Added a fifth check** to the stray-comment loop: if a block comment's line falls inside any function body range (via the existing `Test-LineInsideFunction` helper), it's an inline body comment and is skipped. Updated the drift context message from "four allowed kinds" to "five allowed kinds (file header, banner, purpose comment, sub-section marker, inline body comment)".

### Change 5: ExpressionStatement visitor marks preceding comments as consumed

Inside the `ExpressionStatement` case in the visitor. Adds a `Get-PrecedingBlockComment` call at the end of the case body whose only purpose is to mark the comment (if any) as `Used=true`. No row is emitted. This makes the stray-comment check skip purpose comments preceding `document.addEventListener('DOMContentLoaded', ...)` and similar named-behavior expression statements. The case body was also slightly restructured to return early if not top-level, removing a wasted check.

### Application snag and recovery

The user applied Changes 1-4 manually from old/new code blocks. The partial application of Change 2 lost the closing `}` at the end of the FunctionDeclaration case (replacement block had 4 closing braces before `'VariableDeclaration'`; the original had 5). Brace check showed 830/829. Diagnosed by comparing the user's intermediate file to the GitHub original. Fixed with one `str_replace` adding the missing brace. Then applied Change 5. Final state: 831/831 balanced.

**Lesson noted:** Multi-change partial replacements are error-prone, especially when adjacent cases share visually similar closing-brace patterns. Full-file replacement is safer for any non-trivial set of edits.

---

## cc-shared.js changes (Groups 6 and 7)

Final file in `/mnt/user-data/outputs/cc-shared.js` (1721 lines, brace-balanced).

### Group 6: Per-table purpose comments on dispatch tables

The eight `shared<Event>Actions` dispatch tables previously shared one umbrella comment that only covered `sharedClickActions`. The spec's MISSING_CONSTANT_COMMENT rule requires each const to have its own preceding purpose comment. Replaced the group comment with eight individual comments. `sharedClickActions` gets a focused comment specific to click routing; the seven empty tables get short comments noting they parallel `sharedClickActions` for their respective event.

### Group 7: `script.onload` / `script.onerror` -> `addEventListener`

Inside `loadPageModule()`. Both property-assign event handlers (`script.onload = function() {...}` and `script.onerror = function() {...}`) converted to `script.addEventListener('load', function() {...})` and `script.addEventListener('error', function() {...})`. Spec Section 12 requires this form; the property-assign style postdates when these 5 -spec files were originally refactored, so the prior pattern made historical sense but is now non-spec.

---

## Expected drift picture after re-run

When Dirk:
1. Drops in the patched `Populate-AssetRegistry-JS.ps1`
2. Drops in the updated `cc-shared.js`
3. Applies the §13 spec amendment to CC_JS_Spec.md
4. Re-runs the JS populator with `-Execute`

**cc-shared.js drift should land at zero rows or very close to it.** The 25 rows break down as:
- ~10 rows: BLANK_LINE_INSIDE_FUNCTION_BODY_AT_SCOPE false positives -> gone (populator fix)
- ~1 row: EXCESS_BLANK_LINES file-level false positive -> gone (populator fix)
- ~6 rows: FORBIDDEN_COMMENT_STYLE on inline body comments -> gone (spec + populator fix)
- ~1 row: FORBIDDEN_COMMENT_STYLE on DOMContentLoaded purpose comment -> gone (spec + populator fix)
- 7 rows: MISSING_CONSTANT_COMMENT on empty dispatch tables -> gone (Group 6 fix)
- 2 rows: FORBIDDEN_PROPERTY_ASSIGN_EVENT on script.onload/onerror -> gone (Group 7 fix)

The 5 -spec files should similarly drop most of their drift, leaving primarily the architectural-migration drift (FILE_ORG_MISMATCH, UNKNOWN_SECTION_TYPE) that resolves only when each page completes its bootloader migration.

---

## Post-rerun actual results

Dirk re-ran the populator with all changes applied. The numbers landed as expected. Confirmed via Asset_Registry query of remaining drift rows on the shared file plus the -spec files.

**cc-shared.js:** 4 real drift rows remaining (down from 25). All Group 6 / Group 7 / populator-false-positive drift gone. The 4 remaining rows are exactly the items we knew would stay:
- 3 rows: `engine-popup` and `engine-idle-overlay` JS_HTML_ID_UNRESOLVED (runtime-created IDs - on the populator backlog)
- 1 row: `page-error-banner` JS_HTML_ID_UNRESOLVED (page shells haven't included the placeholder)

**cc-shared.css:** 3 drift rows, all involving `page-error-banner`:
- Line 861: FORBIDDEN_ID_SELECTOR on the base `#page-error-banner` rule
- Line 874: FORBIDDEN_ID_SELECTOR + MISSING_PURPOSE_COMMENT on `#page-error-banner.page-error-banner-visible`
- A duplicate HTML_ID DEFINITION row for the same selector

**Each -spec file:** 4-9 architectural-migration drift rows. Specifically:
- EXCESS_BLANK_LINES on the JS_FILE row (real - source has multi-blank sequences somewhere; quick to clean)
- FILE_ORG_MISMATCH on the FILE_HEADER (FILE ORGANIZATION list still says `INITIALIZATION: PAGE BOOT`)
- UNKNOWN_SECTION_TYPE on the `INITIALIZATION: PAGE BOOT` banner itself (section type no longer valid in the post-bootloader taxonomy)
- ENGINE_PROCESS_PAGE_MISMATCH on the ENGINE_PROCESSES const (page route derived from `-spec` suffix doesn't match ProcessRegistry)
- JS_HTML_ID_UNRESOLVED on IDs the corresponding HTML hasn't migrated yet (`nr-detail-steps`, `info-panel-title`, `info-panel-body`, `info-overlay`, `info-panel`)

The populator is now reporting honestly: every remaining drift row is real, fixable, and traceable to a specific migration step. No more noise to wade through.

---

## Remaining drift fix recipes

The fixes below are queued for upcoming sessions. None of them are exotic - they're either small cleanups absorbed into Phase 1 page migrations, or simple structural rewrites that fall out naturally from the bootloader-pattern migration.

### Fix recipe 1: `page-error-banner` cleanup (touches cc-shared.js, cc-shared.css, all page HTMLs)

This single fix closes out the only remaining real drift on cc-shared.js plus 3 of the 3 drift rows on cc-shared.css. Worth doing as a quick warmup before Phase 1 page migrations begin, since it touches the page shells anyway.

Three coordinated edits:

1. **Page shells: add a static placeholder.** Each page's HTML route file needs `<div id="page-error-banner" class="page-error-banner"></div>` added near the top of the page body, inside the main content container. This creates the HTML_ID DEFINITION row the JS USAGE is looking for and the class hook the CSS will switch to.

2. **cc-shared.css: convert ID selectors to class selectors.**
   - Line 861: change `#page-error-banner` to `.page-error-banner`
   - Line 874: change `#page-error-banner.page-error-banner-visible` to `.page-error-banner.page-error-banner-visible`
   - Add a single-line purpose comment above the base class rule (resolves MISSING_PURPOSE_COMMENT on the visible variant; the base rule needs the same)

3. **cc-shared.js: update `renderPageError` to target by class.** The function currently does `document.getElementById('page-error-banner')` - keep it (the placeholder gives the ID a real definition row), or switch to `document.querySelector('.page-error-banner')` if class-based addressing is preferred for consistency with the CSS change. Either resolves the JS_HTML_ID_UNRESOLVED. Recommendation: keep `getElementById` since the placeholder provides the definition row - simpler and faster than `querySelector`.

Estimated time: 20 minutes. Net drift impact: -4 rows (1 from cc-shared.js, 3 from cc-shared.css).

### Fix recipe 2: -spec file architectural migration (per-file, becomes Phase 1)

For each of the 5 -spec files (business-services-spec, replication-monitoring-spec, business-intelligence-spec, batch-monitoring-spec, dmops-archive-spec), the migration follows a fixed sequence. Drift codes named in parentheses are the ones each step closes.

1. **Convert `INITIALIZATION: PAGE BOOT` banner to a FUNCTIONS banner.** New banner: `FUNCTIONS: PAGE INIT` or similar. (Closes: UNKNOWN_SECTION_TYPE)

2. **Convert the `DOMContentLoaded` handler to a `<prefix>_init` function.** Hoist the handler body into a named function whose name is `<prefix>_init` (e.g., `bsv_init`, `rpm_init`). Add a purpose comment above it.

3. **Remove any duplicate engine-events wiring.** The bootloader in cc-shared.js now handles engine-events registration automatically after invoking `<prefix>_init`. Any code in the prior handler that called engine-events registration manually should be removed.

4. **Update the FILE ORGANIZATION list in the header.** Replace `INITIALIZATION: PAGE BOOT` entry with the new FUNCTIONS banner name. Verify the rest of the list still matches the file's actual banners in order. (Closes: FILE_ORG_MISMATCH)

5. **Verify ENGINE_PROCESSES placement.** The const must live inside a `CONSTANTS: ENGINE PROCESSES` banner. If it's there already (which it appears to be in the spec files), no action needed. Otherwise move it. (Already correct in current -spec files; this is verification only.)

6. **Rename file from `<page>-spec.js` to `<page>.js`.** This single rename resolves ENGINE_PROCESS_PAGE_MISMATCH because the page route is derived from the filename. The renamed file replaces the production file outright.

7. **Update Object_Registry and Component_Registry.** The renamed file needs its registry entries (the prior production file's entries can be reused; the rename happens at the Asset_Registry / catalog level via the populator re-scan).

8. **Clean up any EXCESS_BLANK_LINES.** Quick scan of the file for multi-blank-line sequences; collapse to single blanks. The populator now flags these correctly.

9. **Run JS populator scoped to the single file** (`-FileFilter <page>.js`) to verify drift drops to zero or near-zero. Remaining drift should only be the cross-spec items that need HTML migration (JS_HTML_ID_UNRESOLVED on page-specific IDs).

10. **For the JS_HTML_ID_UNRESOLVED rows** (e.g., `nr-detail-steps` for business-intelligence, `info-panel-*` for replication-monitoring): these resolve when the corresponding HTML route file gets its placeholder elements added. Either bundle the HTML change into the same migration step (preferred - keeps the page coherent) or follow up separately.

### Fix recipe 3: Populator backlog (deferred, not blocking)

These remain on the populator backlog from the prior section. Listed here for visibility - none of them block migrations.

- HTML sniff over-detection (JBossMonitoring-API.ps1 false positives)
- Dynamic ID creation detection (`engine-popup`, `engine-idle-overlay` runtime-created elements)
- Object_Registry registration gaps for the populator scripts themselves

---

## Backlog additions

Two items added to the populator/platform backlog this session. None are blocking page migrations.

1. **HTML sniff over-detection in JS populator.** Currently fires on `JBossMonitoring-API.ps1` 6 times due to literal `<commit>`, `<show>`, `<jobs>` XML strings inside `$baseUrl` interpolations for Palo Alto firewall API calls. Detection should require an HTML-emission context (`Write-PodeHtmlResponse` wrapper, return-from-route shape, or function-name convention like `Get-*Html`) rather than substring matches on HTML-looking text.

2. **Dynamic ID creation detection in JS populator.** Currently fires JS_HTML_ID_UNRESOLVED on `engine-popup` and `engine-idle-overlay` because they're created at runtime via `popup.id = 'engine-popup'` inside `showEnginePopup()` rather than declared in HTML. Populator should recognize `element.id = 'literal'` followed by `appendChild` as a JS-side ID definition, emit HTML_ID DEFINITION rows with scope=LOCAL and source_file=the JS file, and resolve USAGE rows against them.

**Resolved this session:** The third backlog item from earlier in the session (Object_Registry registration gaps for `Populate-AssetRegistry-HTML.ps1`, `Populate-AssetRegistry-PS.ps1`) was closed by the Object_Registry and Object_Metadata baseline insert scripts. The related `server.psd1` registration miss was investigated and resolved by removing `.psd1` from the PS populator's scan scope rather than papering over the warning - see the dedicated section below for reasoning.

---

## Object_Registry and Object_Metadata baseline registration

Closed out the populator registration gap. The CSS and JS populators had been registered in `dbo.Object_Registry` (registry_id 375, 376) and had their three baseline rows in `dbo.Object_Metadata` (metadata_id 5061-5066), but the HTML and PS populators were missing from both tables.

**Object_Registry inserts** mirror the CSS/JS rows exactly: `module_name = 'Tools'`, `component_name = 'Tools.Utilities'`, `object_category = 'PowerShell'`, `object_type = 'Script'`. Descriptions follow the same three-sentence shape as the existing rows (Asset_Registry parser pipeline component for X / walks Y / validates against Z) and fit comfortably under the 500-char limit (366 chars for HTML, 328 for PS).

**Object_Metadata baseline inserts** add the three required rows per script (description, module, category) so the populators appear in the JSON export and on reference pages. description text matches the Object_Registry description by convention. Six rows total across the two scripts.

**Enrichment deferred.** Per OQ-INIT-3 in CC_Initiative.md, full enrichment (data_flow, design_note, etc.) waits until all four populators are stable and the orchestrator is in production. The baselines unlock the documentation surface without committing to enrichment text that may need rewriting once the populator family is finalized.

Two SQL scripts produced this session for FA-SQLDBB:
- `Add-PopulatorObjectRegistry.sql` - 2 inserts into `dbo.Object_Registry`
- `Add-PopulatorObjectMetadata-Baselines.sql` - 6 inserts into `dbo.Object_Metadata`

Both wrapped in transactions with verification SELECTs before the COMMIT.

---

## PS populator scope narrowed: .psd1 files removed

While investigating an Object_Registry miss warning on `server.psd1`, surfaced a deeper table-role distinction worth recording:

**Object_Registry** answers "what files exist in the platform?" - file-level identity, ownership, classification. One row per file. Captures every file related to xFACts.

**Asset_Registry** answers "what's inside every file?" - element-level catalog with drift validation against language specs. Many rows per file, all about the constructs inside.

The two tables share a purpose (platform self-documentation) but have distinct roles. The PS_FILE / CSS_FILE / JS_FILE / HTML_FILE anchor rows blur the line because they're file-level rows in Asset_Registry, but they exist as the attachment point for file-level drift codes and the catalog anchor that other Asset_Registry rows attribute back to. They serve Asset_Registry's purpose, not Object_Registry's.

The test for whether a file belongs in Asset_Registry: **will it ever have constructs to catalog, or file-level drift to validate against a spec?** Source files (.ps1, .psm1, .css, .js, embedded HTML) pass. Configuration files like `server.psd1` fail - no functions or classes to catalog, no spec to validate against, no drift to detect. The PS_FILE anchor row for `server.psd1` was carrying nothing.

**Decision:** remove `.psd1` from the PS populator's scan scope. The `'data-file'` role classification and its associated short-circuit branches in Pass 1 and Pass 2 were removed.

Four targeted edits applied to `Populate-AssetRegistry-PS.ps1`:
1. Remove `'*.psd1'` from the `Get-ChildItem -Include` filter in EXECUTION: FILE DISCOVERY (added an explanatory comment in its place)
2. Remove the `.psd1` branch from `Get-PSFileRole`
3. Remove the `'data-file'` short-circuit in EXECUTION: PASS 1
4. Remove the `'data-file'` short-circuit in EXECUTION: PASS 2

The `.SYNOPSIS` block's "Five file roles" enumeration was already correct - the `data-file` role was an implementation-only addition introduced later when `.psd1` discovery was bolted on, never listed in the canonical role set. No header edit needed.

After this change: re-running the PS populator produces no PS_FILE row for `server.psd1` and no Object_Registry miss warning. The file remains in Object_Registry exactly as it should, fully categorized as a config file. The principle - "configuration data lives in Object_Registry only; code lives in both" - is documented and the populator behavior matches it.

---

## Deferred items (tracked for next session or beyond)

Items surfaced or held over this session. None are blocking Phase 1 page migrations.

**Documentation enrichment (deferred per OQ-INIT-3)**
- HTML populator Object_Metadata enrichment (data_flow, design_note). Baselines in; full enrichment waits until the populator family is stable.
- PS populator Object_Metadata enrichment. Same as above.
- CSS and JS populators also need their data_flow and design_note rows when enrichment unblocks - their baselines have been in for some time.

**Populator standardization audit (queued for after Phase 1)**

Surfaced when investigating why PS warns on `server.psd1` and HTML doesn't. The four populators share concepts but each implements them independently, and they have already drifted apart in correctness. PS still has the same `($curStart - $prevEnd) -gt 2` bug in EXCESS_BLANK_LINES and BLANK_LINE_INSIDE_FUNCTION_BODY_AT_SCOPE that we fixed in JS this session.

- **Promote shared detectors to xFACts-AssetRegistryFunctions.ps1.** Same-concept detectors implemented per-populator are a long-term maintenance hazard. The `Get-MaxConsecutiveBlankLines` helper added to the JS populator this session should be promoted to shared infrastructure so PS picks it up automatically. Other candidates: blank-line counting machinery generally, line-comment-vs-content classification helpers.
- **Backport the JS blank-line fixes to PS.** Once the helper is in shared infrastructure, PS can be updated to use it instead of its current flawed implementation.
- **CSS populator review.** CSS likely has its own implementations of the same checks. Need to inspect and confirm whether it's correct or carries the same bug.
- **Document the file-classification methodology divergence.** HTML uses Object_Registry-driven classification at processing time. PS uses path-based classification first, registry only for FK resolution at the end. Both are defensible but they're philosophically different. Pick a canonical approach or document both formally.

---

## Files in /mnt/user-data/outputs at session end

- `Populate-AssetRegistry-JS.ps1` - patched populator with all 5 changes (4087 lines)
- `cc-shared.js` - Group 6 and Group 7 cleanups applied (1721 lines)
- `Populate-AssetRegistry-HTML.ps1` - prior session's HTML item 9 work (still current)
- `CC_HTML_Spec_Amendments.md` - prior session's HTML amendments (still current)
- `Add-PopulatorObjectRegistry.sql` - 2 Object_Registry inserts (HTML + PS populators)
- `Add-PopulatorObjectMetadata-Baselines.sql` - 6 Object_Metadata baseline inserts

Plus an in-place edit to `Populate-AssetRegistry-PS.ps1` to remove `.psd1` from scan scope (four small drop-in edits applied by Dirk against his working copy; no full-file replacement produced this session).

---

## Next session plan

**Primary focus:** Begin Phase 1 page migrations. The 5 -spec files are ready to promote to production, but each needs its `INITIALIZATION: PAGE BOOT` -> `FUNCTIONS:` + `<prefix>_init` architectural migration completed.

**Suggested starting page:** `business-services-spec.js` - it was the comparison reference earlier in the project, the drift baseline is well understood, and Brandon's BI team uses the Business Services page actively so post-migration testing has a natural owner.

**Per-page migration recipe (will be refined in practice):**

1. Rename `INITIALIZATION: PAGE BOOT` banner to `FUNCTIONS: PAGE INIT` (or whatever banner name fits).
2. Convert the `DOMContentLoaded` handler to a top-level `<prefix>_init` function with a purpose comment.
3. Remove any engine-events wiring that cc-shared.js now owns (bootloader handles registration after `<prefix>_init` is invoked).
4. Update the FILE ORGANIZATION list in the header.
5. Verify ENGINE_PROCESSES constant placement matches its required `CONSTANTS: ENGINE PROCESSES` banner.
6. Rename file from `<page>-spec.js` to `<page>.js` (the production name).
7. Update Object_Registry, Component_Registry mappings if needed.
8. Run JS populator scoped to the single file (`-FileFilter`) to verify drift is gone.

**Open TODO carried into next session:** Populator Object_Metadata enrichment (data_flow, design_note rows) for all four populators - CSS, HTML, JS, PS. Baselines are now in for all four; enrichment was deliberately deferred until the populator family is stable and the orchestrator is in production. When that unlocks, the enrichment is one coherent pass across all four populators rather than piecemeal.


# CC Session Summary 6 — Four-Spec Refactor: CSS, HTML, JS, PS

*Session date: 2026-05-21. Executed the Spec Audit and Refactor Plan against all four Control Center file format specs. All four specs delivered as drop-in replacements. Populator alignment work deferred to dedicated follow-up sessions.*

---

## 1. Purpose

The Session 4 outcome was the recognition that the four CC specs had drifted from each other and from the underlying code, in ways that made cross-spec consistency hard to maintain. The Spec Refactor Plan called for a clean rewrite of each spec: rules only, no rationale, no examples sections, no catalog-model bleed-through, consolidated drift code references.

This session executed that plan across all four specs in sequence. CSS → HTML → JS → PS, same as the original initiative ordering.

The original specs were preserved as `Old_CSS_Spec.md`, `Old_HTML_Spec.md`, `Old_JS_Spec.md`, and `Old_PS_Spec.md` for reference during the populator work and per-page migration work that follows.

---

## 2. Work completed this session

### 2.1 CSS spec rewritten

`CC_CSS_Spec.md` reduced from ~1,000 lines to **292 lines**. Same architecture: section types, prefix discipline, banner format, drift code reference. Cuts: catalog model, compliance queries, examples, appendix rationale, all inline drift code annotations.

### 2.2 HTML spec rewritten

`CC_HTML_Spec.md` reduced from ~2,200 lines to **583 lines**. Major architectural decisions locked:

- **Compound modifier framework eliminated entirely.** Every class is properly prefixed (`.cc-disabled` not `.disabled`, `.cc-hidden` not `.hidden`, etc.). Sweeping rename required across all files on rewrite. `cc-shared.css` becomes non-conformant in places using compound modifiers (`.cc-modal-overlay.hidden`, `.cc-modal.medium`, etc.) — expected drift to be cleaned up on rewrite pass.
- **Action value prefix inverted convention flipped.** Page-local action values now carry the page prefix (`data-action-click="bsv-open-request"` not `data-action-click="open-request"`). JS dispatch tables rekey accordingly. HTML §4.0 carve-out for action values eliminated.
- **Inline event handler shape codes collapsed.** 16 granular codes → single umbrella `FORBIDDEN_INLINE_EVENT_HANDLER`.
- **Dynamic class interpolation shape codes collapsed.** 4 granular codes → single umbrella `FORBIDDEN_DYNAMIC_CLASS_PATTERN`.
- **HTML structural drift codes consolidated.** 11 granular header bar / refresh info / engine card codes → 4 umbrellas (`MALFORMED_HEADER_BAR_STRUCTURE`, `MALFORMED_REFRESH_INFO_STRUCTURE`, `MALFORMED_ENGINE_ROW_STRUCTURE`, `MALFORMED_ENGINE_CARD`).
- **Chrome class names locked to cc-prefixed target state.** `xf-modal-*` (legacy in engine-events.css) → `cc-modal-*` (current in cc-shared.css). HTML spec writes against target state.
- **§13 Chrome class reference section added.** Lists every chrome class HTML spec references (~25 entries). Cross-spec contract anchor with `cc-shared.css`.
- **FILE ORGANIZATION accommodation eliminated.** No numbered legacy form, no trailing description text. Verbatim match only.

### 2.3 JS spec rewritten

`CC_JS_Spec.md` reduced from ~1,500 lines to **438 lines**. Major architectural decisions locked:

- **Dispatch table keys now carry the unified prefix.** Page-local: `'bch-open-batch-detail'`. Chrome: `'cc-page-refresh'`. The bootloader logic simplifies — no more "strip `cc-` and route between page-local and shared tables." Direct lookup by full prefixed key.
- **Top-level wrapper drift codes collapsed.** `FORBIDDEN_IIFE` + `FORBIDDEN_REVEALING_MODULE` → single umbrella `FORBIDDEN_TOP_LEVEL_WRAPPER`.
- **`<prefix>_ENGINE_PROCESSES` `var` exception preserved.** Real JavaScript language constraint (only `var` and `function` declarations populate `window` in classic scripts; `cc-shared.js` resolves the binding via `window[pageKey + '_ENGINE_PROCESSES']`). Stated crisply as the sole exception, with the technical reason inline.
- **§12.2 direct-binding carve-outs preserved.** Singleton elements + window/document events. Real structural realities of how delegation works, not accommodations.
- **§16 Chrome identifier reference section added.** Lists the eight `cc_<event>Actions` dispatch tables and the five hook suffixes. Narrow scope — only identifiers the spec itself references by name.
- **§13 Comments tightened.** The old "top-level expression statement" allowance for `DOMContentLoaded` is gone (bootloader-driven model means pages don't write their own DOMContentLoaded handlers).

### 2.4 PS spec rewritten

`CC_PS_Spec.md` reduced from ~1,938 lines to **519 lines**. Major architectural decisions locked:

- **§4.1 role matrix tightened.** Page-route allows only CHANGELOG + ROUTE. Api-route allows only ROUTE. `INITIALIZATION` is forbidden for both. `IMPORTS`, `CONSTANTS`, `VARIABLES` are forbidden in route files. This matches the §6.2.1/§6.2.2 examples and §A.4.1 rationale of the old spec. The old §4.1 matrix had drifted to be more permissive than the §6.2 examples; the new spec resolves the conflict in favor of the more restrictive interpretation (the original intent).
- **`Prefix: (none)` sentinel preserved as PS-only carve-out.** Shared-library files have `Component_Registry.cc_prefix = NULL` and their functions follow `Verb-Noun` naming, exempt from the platform prefix discipline. The reason is documented inline.
- **CHANGELOG as a dedicated section.** Never embedded in the file header. Produces a dedicated `PS_CHANGELOG_ENTRY` row per entry in the catalog. The intent: keep file headers concise; make CHANGELOG history queryable cleanly.
- **§6.2 role file shapes** trimmed to prose summaries. The five verbose code-block examples from the old spec eliminated. The prose summaries plus the §4.1 matrix together carry the same information.

---

## 3. Cumulative state of the new specs

All four specs are now drop-in replacements at `xFACts-Documentation/Planning/`. The original specs were renamed to `Old_<X>_Spec.md` and kept in the same folder for reference during the populator and migration work.

### 3.1 Structural shape (all four specs)

Every new spec follows the same pattern:

1. Numbered sections in sequence, no preamble, no "Spec Authoring Conventions" block.
2. Rules only, stated as bullet lists.
3. Sparse inline examples inside rule shapes (e.g., the canonical SQL form, a sample dispatch table).
4. **Forbidden patterns** section near the end, table form, with rule cross-references.
5. **Chrome class reference / Chrome identifier reference** section (HTML and JS only) for cross-spec contract anchoring.
6. **Drift code reference** section as the final section. One row per drift code with rule cross-reference.
7. No appendix, no rationale section, no compliance queries section, no catalog model section, no examples section.

### 3.2 Cross-spec contract anchors

The HTML and JS specs each have a dedicated section listing the chrome identifiers they reference by name. These are the cross-spec contracts:

- **HTML spec §13** lists chrome classes (`cc-modal-overlay`, `cc-header-bar`, etc., ~25 entries). Contract with `cc-shared.css`.
- **JS spec §16** lists chrome identifiers (the 8 `cc_<event>Actions` dispatch tables + 5 hook suffixes). Contract with `cc-shared.js`.

These sections exist specifically to catch the stale-reference problem that surfaced mid-session ("the HTML spec still says `xf-modal-overlay` but `cc-shared.css` already defines `cc-modal-overlay`"). If a chrome identifier renames, the contract anchor section is the canonical list of where the spec references it; updates happen in lockstep.

### 3.3 Drift code consolidation summary

Major consolidations across the four specs:

| Spec | Consolidations |
|---|---|
| HTML | 16 inline event handler codes → 1 umbrella. 4 dynamic class codes → 1 umbrella. 11 structural codes → 4 umbrellas. |
| JS | 2 top-level wrapper codes → 1 umbrella. |
| CSS, PS | Drift code reorganization without consolidations — codes were already at appropriate granularity. |

### 3.4 What `cc-shared.css` and `cc-shared.js` look like after the spec changes land

Both files are currently non-conformant with the new specs in specific ways:

- **`cc-shared.css`** uses compound modifiers throughout (`.cc-modal-overlay.hidden`, `.cc-modal.medium`, `.cc-modal.wide`, `.cc-slide-accordion-chevron.expanded`, etc.). Each needs to become a properly prefixed sibling class (`.cc-hidden`, `.cc-medium`, `.cc-wide`, `.cc-expanded`). This is expected drift queued for the next file rewrite pass.
- **`cc-shared.js`** is in better shape — the dispatch tables and hook resolution mechanism already align with the new JS spec. The main change needed is at the bootloader's per-event delegated dispatcher: the "strip `cc-` and route between page-local and shared tables" logic simplifies to a direct lookup by full prefixed key, since both table types now have full prefixed keys.

Backup page in production serves as the reference for current production state. Non-functional drift on `cc-shared.*` and on backup files is acceptable; cleanup happens after populator updates.

---

## 4. Populator alignment plan

The next phase is updating the four populators to enforce the new specs. **Each populator gets a dedicated session.** This avoids context exhaustion and ensures each populator gets full attention.

### 4.1 Why dedicated sessions per populator

Three reasons:
- **Context budget.** Each populator is a large PowerShell file (HTML at 5,500+ lines, JS substantial). Surgical edits across that volume of code need fresh context.
- **Different mode of work.** Spec refactor was removal-and-condensation. Populator work is additive-and-modification — adding new drift codes, modifying validators, retiring deprecated codes. Different mental gear.
- **Intentional drift introduction.** Each populator update will surface new drift on existing files (the cumulative state of changes locked in this session). Working through that drift well needs fresh context per session.

### 4.2 Recommended order

Same as the spec sequence: **CSS → HTML → JS → PS**. CSS confirms the working pattern; HTML and JS are the heaviest; PS is most invasive but benefits from warming up on the others first.

### 4.3 Per-populator scope

#### 4.3.1 CSS populator (`Populate-AssetRegistry-CSS.ps1`)

The CSS spec changes are mostly structural condensations with no new drift code categories. The populator should already enforce most of what the new spec says. The main alignment work:

- **Verify no remaining FILE ORGANIZATION accommodation.** The strict-verbatim rule means no trailing description text on FILE ORG entries, no numbered legacy form.
- **Compound modifier framework elimination.** The old `CSS_VARIANT DEFINITION` rows that backed compound modifiers (`.cc-engine-bar.disabled`, etc.) need to be retired or repurposed. Every class must now be properly prefixed in its own right.
- **Drift code retirement.** Any drift codes that backed the compound modifier framework or the FILE ORG accommodation need to be removed.
- **Per-file Pass 2 FILE_ORG_MISMATCH check tightening.** No description-stripping before comparison.

Expected drift after populator update: `cc-shared.css` surfaces compound modifier drift on every compound usage. This is expected and queues the file for rewrite.

#### 4.3.2 HTML populator (`Populate-AssetRegistry-HTML.ps1`)

The HTML spec changes are extensive. This is the heaviest populator alignment work.

- **Action value prefix flip.** Page-local action values now carry the page prefix. The dispatch table cross-population check needs to validate full prefixed keys. Any logic that detects "unprefixed action value, look up by full name" needs to become "prefixed action value, look up by full key matching the prefix."
- **Inline event handler umbrella code.** Retire the 16 granular shape codes (`MULTIPLE_HANDLER_STATEMENTS`, `INLINE_HANDLER_EXPRESSION`, `MALFORMED_HANDLER_CALL`, `TRAILING_HANDLER_SEMICOLON`, `FORBIDDEN_REVEALING_MODULE_CALL`, `FORBIDDEN_BUILTIN_METHOD_CALL`, `HANDLER_FUNCTION_NAME_MISMATCH`, etc.). Replace with single `FORBIDDEN_INLINE_EVENT_HANDLER` umbrella that fires on any inline `on*` event handler attribute.
- **Dynamic class interpolation umbrella code.** Retire the 4 granular codes (`INLINE_CLASS_CONCATENATION`, `INLINE_CLASS_PREFIX_MIX`, `INLINE_CLASS_MULTI_INTERPOLATION`, `INLINE_CLASS_BRACED_INTERPOLATION`). Replace with single `FORBIDDEN_DYNAMIC_CLASS_PATTERN` umbrella.
- **Structural drift code consolidation.** Retire the 11 granular structure codes (`MALFORMED_HEADER_BAR_CONTAINER`, `MALFORMED_HEADER_BAR_LEFT`, `MALFORMED_HEADER_BAR_RIGHT`, `MALFORMED_HEADER_RIGHT_CHILDREN`, `MALFORMED_LIVE_INDICATOR`, `MALFORMED_LIVE_STATUS_LINE`, `MALFORMED_REFRESH_BUTTON`, `MALFORMED_ENGINE_ROW_CONTAINER`, `MALFORMED_ENGINE_ROW_CHILDREN`, `MALFORMED_ENGINE_CARD_ATTRIBUTES`, `MALFORMED_ENGINE_LABEL`, `MALFORMED_ENGINE_BAR`, `MALFORMED_ENGINE_COUNTDOWN`). Replace with 4 structural umbrellas.
- **Compound modifier validation removed.** The HTML populator's USAGE-resolution step that validated compound modifiers against their registered compound bases needs to be retired. Every class is now resolved as a proper prefixed class.
- **Chrome class names tightened to `cc-modal-*` family.** The HTML populator's chrome class recognition needs to accept `cc-modal-overlay`, `cc-modal`, `cc-slide-overlay`, `cc-slide-panel`, etc., as the canonical forms. The `xf-modal-*` family becomes legacy (eventually removed entirely from `engine-events.css`).
- **§13 chrome class reference validation.** Optionally, the populator can validate that every chrome class the spec lists in §13 actually exists in `cc-shared.css`. This is the queryable enforcement of the cross-spec contract anchor.

Major HTML populator reduction is expected from the drift code consolidations — the umbrella codes replace large amounts of pattern-shape detection logic with simpler "is this an inline event handler? yes/no" or "is this a dynamic class pattern? yes/no" detection.

#### 4.3.3 JS populator (`Populate-AssetRegistry-JS.ps1`)

- **Dispatch table key validation.** Page-side tables: keys carry the page prefix. Chrome tables: keys carry `cc-`. The current spec already has this concept but inverted ("page tables must NOT have `cc-` prefix"). The new form is simpler: every key has a prefix and the prefix tells you which table it belongs in. Update `MALFORMED_ACTION_KEY` logic accordingly.
- **`UNRESOLVED_DISPATCH_HANDLER` cross-spec resolution.** Verify the JS populator's cross-spec resolution against HTML `data-action-<event>` rows still works correctly under the new prefixed-key convention.
- **Top-level wrapper umbrella code.** Retire `FORBIDDEN_IIFE` and `FORBIDDEN_REVEALING_MODULE`. Replace with single `FORBIDDEN_TOP_LEVEL_WRAPPER`.
- **`<prefix>_ENGINE_PROCESSES` `var` exception verification.** Already in the spec; confirm the populator's `WRONG_DECLARATION_KEYWORD` check still has the `var` exemption for `ENGINE PROCESSES` banner content.
- **§16 chrome identifier reference validation.** Optionally validate that the 8 `cc_<event>Actions` dispatch tables actually exist in `cc-shared.js`.
- **DOMContentLoaded comment carve-out removed.** The §13 comment forms list no longer permits "top-level expression statement" comments, which was the carve-out for `document.addEventListener('DOMContentLoaded', ...)`. Pages don't write their own DOMContentLoaded handlers under the bootloader model.

Note: this populator was last documented at 5,500+ lines and is the heaviest. Plan for a session focused on careful section-by-section edits.

#### 4.3.4 PS populator (`Populate-AssetRegistry-PS.ps1`)

- **`$ValidSectionTypesByRole` tightening.** The current populator has `IMPORTS`, `INITIALIZATION`, `CONSTANTS`, `VARIABLES` listed as allowed for page-route and api-route. The new spec forbids all of these in routes. Update the hashtable to match:
  - `page-route` → `@('CHANGELOG', 'ROUTE')`
  - `api-route` → `@('ROUTE')`
  - `module` → `@('IMPORTS', 'CONSTANTS', 'VARIABLES', 'FUNCTIONS', 'EXPORTS')`
  - `standalone` → unchanged (`@('CHANGELOG', 'IMPORTS', 'PARAMETERS', 'INITIALIZATION', 'CONSTANTS', 'VARIABLES', 'FUNCTIONS', 'EXECUTION')`)
  - `shared-library` → `@('CHANGELOG', 'CONSTANTS', 'VARIABLES', 'FUNCTIONS')`
- **`FORBIDDEN_CHANGELOG_IN_HEADER` drift code.** New code per the spec's §2.1 rule that CHANGELOG content does not appear in the file header. Validator: scan `.NOTES` content for date-prefixed lines or version literals; fire drift if found.
- **`FORBIDDEN_SECTION_TYPE` should already be working** — verify it fires correctly under the tightened matrix.
- **`MISSING_REQUIRED_SECTION` should already be working** for the `ROUTE` requirement on page-route/api-route and `EXECUTION` on standalone.
- **`Prefix: (none)` sentinel acceptance.** Already in place; the populator already accepts `(none)` as a valid prefix value. Verify the new spec's §5.1 three-form rule (page prefix, `cc`, `(none)`) is enforced correctly.
- **No new fundamental drift code categories** beyond `FORBIDDEN_CHANGELOG_IN_HEADER`. Most of the work is matrix tightening plus retire-and-update.

Expected drift after populator update: every page-route file with current `IMPORTS`, `CONSTANTS`, `VARIABLES`, or `INITIALIZATION` sections surfaces `FORBIDDEN_SECTION_TYPE` drift on those sections. This is expected and queues those files for the Phase 1 migration work.

### 4.4 Per-session deliverable shape

Each populator session should produce:

1. **Updated populator script** as a full file replacement (preferred for files of this size and complexity; targeted edits OK for surgical changes).
2. **Verification queries against the catalog** showing the new drift codes firing on files that should have them, and the retired codes not firing anywhere.
3. **A note in the session summary capturing**: what changed in the populator, what new drift surfaced on which files, and which files are now queued for the next file-rewrite pass.

### 4.5 What happens after all four populators are aligned

After all four populators match the new specs, the per-page file rewrite work begins. This is the heaviest single phase of the initiative — every CC page's CSS, HTML route, JS, and any related modules get rewritten to conform.

The rewrite work is page-by-page and benefits from the catalog telling us exactly which files have which drift after the populator updates. The work proceeds in dependency order: shared files first (`cc-shared.css`, `cc-shared.js`, helper modules), then individual pages.

Backup page is already in production at zero functional drift; it serves as the reference page during the per-page rewrites and gets its own rewrite pass last (when all the lessons learned from other pages are available).

---

## 5. Key locked decisions across the four specs

This section consolidates the architectural decisions that span specs, for quick reference at session start.

### 5.1 Unified prefix rule

Every identifier in the codebase is prefixed.

- **HTML:** all IDs, classes, page-emitted `data-*` attribute names. Body attributes are `data-cc-page` and `data-cc-prefix`.
- **CSS:** all class definitions. Chrome classes in `cc-shared.css` use `cc-` prefix. Anchor file sections declare `Prefix: cc`.
- **JS:** all top-level identifiers. Hooks are `<prefix>_<hookSuffix>`. `ENGINE_PROCESSES` is `<prefix>_ENGINE_PROCESSES`. Chrome dispatch tables are `cc_<event>Actions`.
- **PS:** all top-level identifiers in prefixable sections begin with the file's registered prefix. Shared-library functions follow `Verb-Noun` (the only place `(none)` is a valid prefix).

### 5.2 Action value convention

Page-local action values carry the page prefix: `data-action-click="bsv-open-request"`. Chrome action values carry `cc-`: `data-action-click="cc-page-refresh"`. Dispatch table keys match: `bsv_clickActions = { 'bsv-open-request': ... }`, `cc_clickActions = { 'cc-page-refresh': ... }`. No prefix stripping in the bootloader; direct full-key lookup.

### 5.3 Compound modifier elimination (CSS)

Every CSS class is properly prefixed. State modifiers like `.disabled`, `.hidden`, `.wide`, `.open`, `.expanded`, `.active` become `.cc-disabled`, `.cc-hidden`, `.cc-wide`, `.cc-open`, `.cc-expanded`, `.cc-active` (or page-prefixed if used only on page-local elements). No "compound modifier" concept anymore.

### 5.4 Chrome class lockdown (HTML)

Modal family: `cc-modal-overlay`, `cc-modal`, `cc-modal-header`, `cc-modal-title`, `cc-modal-body`, `cc-modal-actions`, `cc-modal-close`. Slide panel family: `cc-slide-overlay`, `cc-slide-panel`, `cc-slide-panel-header`, `cc-slide-panel-title`, `cc-slide-panel-body`. The `xf-modal-*` family is legacy in `engine-events.css`, being retired.

### 5.5 Drift code consolidation principle

Granular codes that describe how a violation looks were consolidated into umbrella codes that describe what the violation is. Examples:
- 16 inline-event-handler shape codes → 1 `FORBIDDEN_INLINE_EVENT_HANDLER`.
- 4 dynamic-class shape codes → 1 `FORBIDDEN_DYNAMIC_CLASS_PATTERN`.
- 2 top-level-wrapper shape codes → 1 `FORBIDDEN_TOP_LEVEL_WRAPPER`.
- 11 HTML structural shape codes → 4 structural umbrellas.

The principle: developers fixing drift don't need to know which shape of violation they have; they need to know what to fix. The umbrella codes give them that.

### 5.6 No accommodation principle

Every spec eliminates accommodations of existing code:
- FILE ORGANIZATION trailing description text → not permitted; strict verbatim match.
- Old numbered FILE ORGANIZATION form → not permitted.
- Compound modifier framework → eliminated.
- Inverted action value prefix → flipped to match the unified prefix rule.

The four `Old_<X>_Spec.md` files preserve the prior accommodations for reference, but the new specs do not carry them forward.

### 5.7 PS-specific `Prefix: (none)` sentinel

The only place `(none)` remains a valid prefix is the PS spec. This is because shared-library files have `Component_Registry.cc_prefix = NULL` (no prefix to declare), and their functions use PowerShell's `Verb-Noun` convention which is exempt from the platform's prefix discipline. The reason is documented inline in §5.1 of the PS spec.

---

## 6. Open items / launching pad for next session

### 6.1 Immediate next step

**CSS populator alignment session.** Recommended as the first follow-up because:
- CSS spec changes are the most contained.
- Confirms the working pattern (read spec, identify drift code categories that retire/add, update populator, verify drift surfaces correctly).
- Lower risk than HTML or JS (smaller populator, fewer cross-spec implications).

### 6.2 Session start checklist for populator work

When starting any populator alignment session:

1. **Read the new spec.** It's the authoritative source. Old specs are reference-only.
2. **Read the current populator script.** Locate the spec constants section, the drift code descriptions hashtable, and the per-rule validators.
3. **List drift codes the populator currently emits.** Cross-reference against the new spec's drift code reference table.
4. **Identify three categories**: (a) codes retired by the new spec, (b) codes still active under the new spec, (c) new codes the populator must add.
5. **Plan the edit sequence.** Surgical edits for surgical changes; full file replacement if the changes are pervasive.
6. **Run the populator** in preview mode on a representative sample of files to verify the new drift codes surface and the retired codes do not.

### 6.3 Reference files for populator work

- `xFACts-Documentation/Planning/CC_CSS_Spec.md` (new)
- `xFACts-Documentation/Planning/CC_HTML_Spec.md` (new)
- `xFACts-Documentation/Planning/CC_JS_Spec.md` (new)
- `xFACts-Documentation/Planning/CC_PS_Spec.md` (new)
- `xFACts-Documentation/Planning/Old_CSS_Spec.md`, `Old_HTML_Spec.md`, `Old_JS_Spec.md`, `Old_PS_Spec.md` (reference)
- `xFACts-PowerShell/Populate-AssetRegistry-CSS.ps1`
- `xFACts-PowerShell/Populate-AssetRegistry-HTML.ps1`
- `xFACts-PowerShell/Populate-AssetRegistry-JS.ps1`
- `xFACts-PowerShell/Populate-AssetRegistry-PS.ps1`
- `xFACts-PowerShell/xFACts-AssetRegistryFunctions.ps1` (shared infrastructure)

### 6.4 What can wait

- **Per-page file rewrites.** These wait until all four populators are aligned, so the catalog tells us reliably which files need which work.
- **`Object_Metadata` enrichment** for the four populators. The Asset Registry pipeline initiative had this queued as `OQ-INIT-3` — full enrichment after all four populators are in production. The populator alignment work in this phase doesn't need Object_Metadata updates at the same time.
- **`cc-shared.css` and `cc-shared.js` rewrites.** These happen after the HTML and JS populators are aligned, so the catalog shows the expected drift on those shared files.

---

## 7. Session metrics

| Metric | Value |
|---|---|
| Specs rewritten | 4 (CSS, HTML, JS, PS) |
| Total line count, old specs | ~6,638 |
| Total line count, new specs | 1,832 |
| Reduction | ~72% |
| Old specs preserved as | `Old_CSS_Spec.md`, `Old_HTML_Spec.md`, `Old_JS_Spec.md`, `Old_PS_Spec.md` |
| Cross-spec contract anchor sections added | 2 (HTML §13, JS §16) |
| Major architectural decisions locked | 7 (unified prefix, action value flip, compound modifier elimination, chrome class lockdown, drift code consolidation, no accommodation principle, PS `(none)` sentinel preservation) |
| Populator alignment sessions queued | 4 (one per populator) |
| File rewrite phase status | Deferred until populator alignment complete |

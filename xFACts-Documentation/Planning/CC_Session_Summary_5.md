# CC Session Summary 5 — Populator Defect Batch and CSS Spec Section 11.2.5 Closeout

*Session date: 2026-05-19. Picks up the populator-defect roadmap produced by Session 4 (`CC_Migration_Phase1.md` Section 11.1). This session resolved Section 11.2.5 (the carryover CSS spec amendment), shipped Section 11.1.8 across CSS and JS populators, shipped Section 11.1.9 / 11.1.10 / 11.1.11 as a JS populator batch, surfaced and fixed a previously-undocumented HTML-vs-JS spec drift, and captured a JS populator performance baseline for future investigation.*

---

## 1. Purpose

The Session 4 outcome was a clean populator-defect roadmap and a Backup page in production with drift that mapped entirely to documented gaps. This session's job was to start working that roadmap.

The plan was small-and-batched: pick the highest-impact items first, ship them together where the changes share a populator file, verify after each landing. That plan held. Five populator defects resolved and one CSS spec amendment closed out, all verified against the catalog before moving on.

The session also surfaced one thing that wasn't pre-planned: the JS spec and HTML spec disagreed on the name of the chrome dispatch tables. Discovered while reading populator code for Section 11.1.11. Fixed during the session because the populator-side fix was tightly coupled to it.

---

## 2. Work completed this session

### 2.1 CSS Section 11.2.5 closeout

Last session's Section 11.2.5 amendment (compound modifier qualification criteria and the `cc-shared.css` rename of `.slide-auto-height` to `.cc-slide-auto-height`) was fully delivered except for one drift row. The opening of this session resolved it.

The remaining row was on line 1057 — the new `.cc-slide-panel.cc-slide-auto-height` variant rule had a preceding purpose-style comment, but CSS spec Section 7.2 requires variants to carry a *trailing inline* comment. The original delivery used the wrong comment placement. Resolution was an inline edit: replaced the 9-line opening block (preceding purpose comment plus selector line) with a single line carrying the inline comment in the spec-compliant trailing form.

Result: `cc-shared.css` landed at 12 drift rows, all `MALFORMED_PREFIX_VALUE` on section banners — the exact Section 11.1.8 baseline predicted by Session 4's drift roadmap.

### 2.2 Section 11.1.8 — chrome prefix `cc` recognized across CSS and JS populators

Three coordinated edits delivered as inline patches (no full-file replacements; surgical changes only).

**Edit 1 — `xFACts-AssetRegistryFunctions.ps1`:** extended `Test-PrefixValueIsValid` to accept `cc` as a third well-formed prefix form alongside the existing 3-char lowercase page-prefix pattern and the `(none)` sentinel. Updated comment to explain all three forms and to explicitly note that "is this the right value for this section" is the `PREFIX_REGISTRY_MISMATCH` check's job, not the validator's.

**Edit 2 — `Populate-AssetRegistry-CSS.ps1`:** added two new constants (`$CcAnchorCssFile = 'cc-shared.css'`, `$DocsAnchorCssFile = 'docs-base.css'`) and extended the `PREFIX_REGISTRY_MISMATCH` logic to handle chrome-anchor files. New branch logic:

- File has `cc_prefix = NULL` AND is the chrome anchor file → banner must declare `cc`.
- File has `cc_prefix = NULL` AND is NOT the chrome anchor → banner must declare `(none)`.
- File has `cc_prefix = X` → banner must declare X. Neither `(none)` nor `cc` is valid in a page-file banner.

The mismatch context message was reworded from "Component_Registry says cc_prefix = X" to "the expected value for this file is X" because the registry column says `NULL` for chrome anchors but the *expected* banner value is `cc` — the new wording is correct in both cases.

**Edit 3 — `Populate-AssetRegistry-JS.ps1`:** mirror of Edit 2 using the JS populator's existing `$CanonicalSharedFile = 'cc-shared.js'` constant (no new constant needed there). Threaded the new `cc` logic through the existing carve-outs for hooks banner / `IMPORTS` section / `CONSTANTS` section declaring `(none)`. Added an explicit `cc` rejection on page-file banners since `cc` is now well-formed and would otherwise have bypassed the existing mismatch logic.

The JS populator's stale `INITIALIZATION` comment reference was corrected to `IMPORTS and CONSTANTS` (the actual current carve-out set per the 2026-05-14 bootloader amendment).

**Design decision worth recording:** the `Component_Registry.cc_prefix` column stays `NULL` for `ControlCenter.Shared` and `Documentation.Site`. The chrome-anchor concept lives in the populator as constants, not in the registry as a column value. Rationale:

- `cc_prefix` is the page-prefix column; the registry's `CK_Component_Registry_cc_prefix` check constraint requires exactly 3 lowercase ASCII letters. Loosening it would conflate page-prefix with anchor-declaration.
- The chrome anchor set is closed and small (one CSS anchor per zone, one JS anchor per zone). Closed sets of this size belong as populator constants, parallel to the existing `$SharedFiles` / `$DocsSharedFiles` / `$CanonicalSharedFile` constants.
- The schema change would ripple across the registry CHECK constraint, the filtered unique index, multiple populator call sites, and several `common_queries` in `Object_Metadata`. The populator-only change is much smaller surface area.

**Verification:**
- `cc-shared.css`: 12 → 0 drift rows.
- `cc-shared.js` banner rows: 0 `MALFORMED_PREFIX_VALUE`, 0 `PREFIX_REGISTRY_MISMATCH` after the JS populator ran the first time post-edit.
- `backup.css`: 0 drift held (no regression).

### 2.3 Section 11.1.9 / 11.1.10 / 11.1.11 batch (JS populator)

Three more populator defects, all in `Populate-AssetRegistry-JS.ps1`, shipped as a single batch since they share a file and are independent fixes.

**Section 11.1.10 (UNKNOWN_HOOK_NAME and HOOK_MISPLACED suffix matching):** added `Get-HookSuffix` helper near `Test-HtmlIdMalformed`. The helper strips the file's registered prefix plus underscore from the function name; falls back to the full name when the file has no registered prefix. Updated two check sites in the `FunctionDeclaration` visitor branch — the `UNKNOWN_HOOK_NAME` check and the immediately-following `HOOK_MISPLACED` check — to compare suffix against `$RecognizedHookNames` instead of full identifier. The `HOOK_MISPLACED` site had the same bug as `UNKNOWN_HOOK_NAME`; both fixed in lockstep.

**Section 11.1.9 (ENGINE_PROCESSES carve-out):** added `Test-IsEngineProcessesName` helper alongside `Get-HookSuffix`. The helper recognizes both the bare `ENGINE_PROCESSES` form and the prefixed `<prefix>_ENGINE_PROCESSES` form (per the post-Section-11.2.4 unified prefix rule).

The original backlog scope for Section 11.1.9 was "exempt the identifier from `WRONG_DECLARATION_KEYWORD`." Mid-design, scope expanded to four touchpoints in the populator:

1. **Row-type derivation** — when the carve-out applies, emit the row as `JS_STATE` (not `JS_CONSTANT_VARIANT`), per the amended JS spec Sections 15.4 / 17.6.
2. **WRONG_DECLARATION_KEYWORD check** — skip the drift code when the carve-out shape applies (identifier ends in `_ENGINE_PROCESSES`, declared with `var`, sitting in the `CONSTANTS: ENGINE PROCESSES` banner).
3. **ENGINE_PROCESSES_MISPLACED check** — recognize the prefixed form so the misplacement check actually fires correctly on prefixed declarations.
4. **ENGINE_PROCESSES capture site for post-walk validation** — recognize the prefixed form so `$script:CurrentEngineProcessesRow` actually captures the row when the file uses the prefixed form. Without this, the post-walk `ENGINE_PROCESS_PAGE_MISMATCH` and `ENGINE_SLUG_JS_MISMATCH` validations would never fire for any page file using the post-Section-11.2.4 form, and `MISSING_ENGINE_PROCESSES_DECLARATION` would fire on every page that has correctly declared the prefixed identifier.

The expanded scope is worth noting: future similar work on the populator should look at *all* sites that test against a contract identifier, not just the one named in the backlog entry. The `Test-IsEngineProcessesName` helper centralizes that recognition.

**Section 11.1.11 (chrome dispatch table name recognition):** replaced the chrome-side regex in `Get-DispatchTableInfo` from `^shared([A-Z][a-z]+)Actions$` (e.g., `sharedClickActions`) to `^cc_([a-z]+)Actions$` (e.g., `cc_clickActions`). The chrome regex is checked first so the page-side regex `^([a-z]+)_([a-z]+)Actions$` doesn't inadvertently classify `cc_clickActions` as a page-side table with prefix `cc`.

The validation rule inside `Add-JsDispatchEntryRows` didn't need changes — once classification is correct, the existing scope-inverted rule (shared keys must start with `cc-`, page keys must not) produces correct results.

**Spec drift surfaced and fixed during this work:** the HTML spec Section 6.1 and 6.2 still referenced `sharedClickActions` and `sharedXxxActions` — pre-Section-11.2.4 wording that wasn't updated when the JS spec moved to the `cc_*Actions` naming convention. The JS spec Section 11.3.2 had the correct current naming. The actual deployed `cc-shared.js` matched the JS spec. The populator's `Get-DispatchTableInfo` matched the stale HTML spec, which is why it was failing — the populator was working off the wrong spec.

Three coordinated prose updates landed in this session:

1. **`Populate-AssetRegistry-JS.ps1`** — both the `Get-DispatchTableInfo` function body (regex change) and its preceding comment block (description update).
2. **`CC_HTML_Spec.md` Section 6.1** — bullet about shared chrome actions changed from `sharedClickActions, sharedChangeActions` to `cc_clickActions, cc_changeActions`. Added cross-reference to JS spec Section 11.3.2.
3. **`CC_HTML_Spec.md` Section 6.2** — dispatch-resolution example updated from `sharedClickActions['save']` to `cc_clickActions['save']`.

**Verification:**
- `backup.js`: 7 → 1 drift rows. Cleared: 4 × `UNKNOWN_HOOK_NAME`, 1 × `MISSING_ENGINE_PROCESSES_DECLARATION`, 1 × `WRONG_DECLARATION_KEYWORD`. Remaining: 1 × `JS_HTML_ID_MALFORMED` (Section 11.1.7, not in this session's scope).
- `cc-shared.js`: 2 × `MALFORMED_ACTION_KEY` cleared.

### 2.4 Section 11.1.12 became visible

Late in the session, `cc-shared.js` showed 6 rows of `JS_HTML_ID_UNRESOLVED` that hadn't been visible earlier. Not a regression. Root cause:

The JS populator emits `JS_HTML_ID_UNRESOLVED` only when `HTML_ID DEFINITION` rows are loaded at startup for cross-spec resolution. Earlier in the session, the JS populator runs logged a startup warning that HTML_ID rows couldn't be loaded — so the code was suppressed. Between then and the final JS populator run, the HTML populator must have run separately, populating those rows. The next JS populator run loaded them successfully and could finally evaluate cross-spec resolution.

The 6 rows that appeared are exactly the Section 11.1.12 backlog items: runtime-created chrome IDs (`cc-engine-popup`, `cc-engine-idle-overlay` created via `document.createElement`) and single-process fallback IDs (`cc-engine-bar`, `cc-card-engine`, `cc-engine-cd`). All documented as platform conventions that the populator should exempt; that exemption logic is the Section 11.1.12 fix, still pending.

### 2.5 ASCII-only constraint for PowerShell scripts

Discovered when I used the `§` symbol in PowerShell comments. The constraint is firm: PowerShell scripts in this codebase must be pure ASCII. The Section symbol (and presumably any other non-ASCII character) can cause GitHub `web_fetch` retrievals to fail by misidentifying the file as binary.

The convention going forward: use the literal word `Section ` (with the trailing space) in place of `§` in PowerShell comments. This applies retroactively — any populator comment I've delivered this session with `§` needs to be reviewed; Dirk did the replacement inline as he applied the edits.

This constraint should be honored by default for all PowerShell work in future sessions. Markdown spec docs and other text files are fine with the symbol.

### 2.6 JS populator performance baseline captured

Pipeline run timings from the final pass:

| Populator | Total | Pass 1 (parse + shared collection) | Pass 2 (per-file walk + emission) | Pass 3 (cross-file) | Bulk insert | Rows |
|---|---|---|---|---|---|---|
| CSS | ~63 s | 21 s | 38 s | ~2 s | 2 s | 7,549 |
| JS | **~6 min 25 s** | 1 min 33 s | **4 min 43 s** | ~3 s | 5 s | 10,633 |
| PS | ~45 s | 2 s | 35 s | ~1 s | 7 s | 12,758 |

**Finding:** JS Pass 2 (per-file walk) is the dominant cost. About 10 s/file on average for JS versus 1.2 s/file for CSS — a ~8x per-file slowdown. JS Pass 1 is also ~5x slower per-file than CSS (3 s vs. 0.66 s).

**Not the bottleneck:** preloads (CSS_CLASS DEFINITION preload completed in <1 s), DB bulk insert (5 s for 10,633 rows is fine), cross-file Pass 3 (3 s).

**Recommended approach when this becomes a priority:** instrument before optimizing. Add `Stopwatch` timers around the major work categories inside the Pass 2 visitor scriptblock — node visits per AST node type, row emission paths, drift-code attachment — so we have real data instead of guesses. PowerShell performance intuition is unreliable; "the per-file walk is slow" could mean any of a dozen things. Instrument first, propose fixes based on real numbers.

Deferred. Becomes important once the pipeline wrapper for push-button execution lands; until then, all runs are manual and timing is tolerable.

---

## 3. Decisions reached

1. **`Component_Registry.cc_prefix` stays NULL for chrome-anchor components.** Anchor identity lives in populator constants, not in the registry column. Keeps the registry's column semantics clean and matches the precedent set by the JS populator's existing `$CanonicalSharedFile` constant.

2. **PowerShell scripts must be pure ASCII.** The Section symbol cannot appear in `.ps1` files (or shared `.ps1` infrastructure like `xFACts-AssetRegistryFunctions.ps1`). Use the literal word `Section ` instead. Markdown docs are unaffected.

3. **Populator-defect tracking moves to session summaries going forward.** The Session 11.1.x numbering in `CC_Migration_Phase1.md` stays as historical artifact for items already documented there. New defects surfaced after this session are described in the session that discovers them and referenced by description rather than formal number. The Migration doc returns to its original purpose: per-page conversion template and tracker. Once the project completes, only the four specs survive; everything else (including all the session summaries) is scaffolding.

4. **Performance work waits for the pipeline wrapper.** Manual runs are tolerable at current speeds. The JS populator's ~6x-slower characteristic is documented; instrumentation work begins when push-button daily-multiple-times execution becomes the use case.

5. **HTML spec drift fixes against current JS spec are folded into the populator-fix session that surfaces them.** The HTML spec Section 6.1 / 6.2 wording was wrong; rather than defer to a separate spec-cleanup session, it was fixed inline because the populator fix required choosing which spec to align with. The corrected JS spec is the authoritative source for chrome dispatch table naming.

---

## 4. Files modified this session

### 4.1 PowerShell populator and shared infrastructure

| File | Status | Notes |
|---|---|---|
| `xFACts-AssetRegistryFunctions.ps1` | DEPLOYED | `Test-PrefixValueIsValid` extended to accept `cc` as a third well-formed prefix form. Pure validator change; "correctness for context" remains the populators' concern. |
| `Populate-AssetRegistry-CSS.ps1` | DEPLOYED | New `$CcAnchorCssFile` and `$DocsAnchorCssFile` constants. `PREFIX_REGISTRY_MISMATCH` block extended with chrome-anchor branch logic. Mismatch context message reworded from "Component_Registry says" to "the expected value for this file is" for accuracy in chrome-anchor cases. |
| `Populate-AssetRegistry-JS.ps1` | DEPLOYED | Section 11.1.8: `PREFIX_REGISTRY_MISMATCH` block extended in parallel with CSS populator, plus stale `INITIALIZATION` comment corrected to `IMPORTS and CONSTANTS`. Section 11.1.10: new `Get-HookSuffix` helper plus updated `UNKNOWN_HOOK_NAME` and `HOOK_MISPLACED` checks. Section 11.1.9: new `Test-IsEngineProcessesName` helper plus four updated touchpoints (row-type derivation, WRONG_DECLARATION_KEYWORD check, ENGINE_PROCESSES_MISPLACED check, ENGINE_PROCESSES capture site). Section 11.1.11: `Get-DispatchTableInfo` chrome-side regex changed from `sharedXxxActions` to `cc_xxxActions`, plus the function's preceding comment block updated to match. |

### 4.2 Spec documents

| File | Status | Notes |
|---|---|---|
| `CC_HTML_Spec.md` | DEPLOYED | Section 6.1 bullet about shared chrome actions updated from `sharedClickActions, sharedChangeActions` to `cc_clickActions, cc_changeActions`. Cross-reference to JS spec Section 11.3.2 added. Section 6.2 dispatch-resolution example updated correspondingly. Closes a pre-existing wording drift against `CC_JS_Spec.md` Section 11.3.2. |

### 4.3 CSS source

| File | Status | Notes |
|---|---|---|
| `cc-shared.css` | DEPLOYED | Final Section 11.2.5 drift cleared. The `.cc-slide-panel.cc-slide-auto-height` variant on line 1057 now carries the spec-required trailing inline comment instead of the previous preceding purpose-style block. |

### 4.4 Files NOT modified this session

- `CC_CSS_Spec.md`, `CC_JS_Spec.md`, `CC_PS_Spec.md` — Session 3 / 4 amendments still current; no further amendments this session.
- `Populate-AssetRegistry-HTML.ps1`, `Populate-AssetRegistry-PS.ps1` — out of scope for this session's items.
- All page files (HTML/CSS/JS/PS) — out of scope; this was populator-and-spec session.

---

## 5. Cumulative drift state after this session

| File | Drift count | Composition |
|---|---|---|
| `cc-shared.css` | 0 | Clean |
| `cc-shared.js` | 6 | All `JS_HTML_ID_UNRESOLVED` on lines 979-1473 — Section 11.1.12 (runtime-created and fallback chrome IDs) |
| `backup.css` | 0 | Clean |
| `backup.js` | 1 | `JS_HTML_ID_MALFORMED` on line 1144 — Section 11.1.7 (chrome `cc-` prefix not recognized on IDs) |
| `engine-events.css` | 139 | Legacy deprecation target; expected noise, ignored per Session 4 framing |
| `engine-events.js` | (substantial) | Same — legacy deprecation target |
| Other page files (non-migrated) | Varied | Pre-migration drift; per-page work resolves them |

**Backup page status:** still fully functional in production. The remaining `JS_HTML_ID_MALFORMED` on line 1144 is a Section 11.1.7 catalog-cleanliness concern, not a functional one.

---

## 6. Open items / launching pad for next session

### 6.1 What's left in the populator-defect work

Items still pending from the Session 4 roadmap (described, not numbered, going forward):

1. **HTML and JS populator: `cc-` chrome prefix recognition on IDs.** Currently both populators flag `cc-*` IDs as malformed because they only recognize the page's `cc_prefix` as a valid ID prefix. Per the Section 11.2.4 unified prefix rule, `cc-` is also valid on chrome IDs. Single-change fix in each populator: extend the prefix check to accept either form. Clears 1 row on `backup.js` plus 15+ rows on `Backup.ps1`. This is the most impactful next item.

2. **JS populator: runtime-created and fallback chrome ID exemptions.** Section 11.1.12. The 6 rows currently firing on `cc-shared.js` are legitimate platform conventions:
   - `cc-engine-popup`, `cc-engine-idle-overlay` — created at runtime via `document.createElement`; never appear in markup.
   - `cc-engine-bar`, `cc-card-engine`, `cc-engine-cd` — single-process fallback IDs the chrome falls back to when the page has only one engine card.
   
   Two exemption mechanisms needed: (a) detect the `document.createElement(...)` + `element.id = '...'` pattern and exempt resulting IDs from `JS_HTML_ID_UNRESOLVED`; (b) recognize the single-process fallback ID set as platform conventions.

3. **CSS and HTML populators: compound modifier USAGE resolution.** Section 11.1.4. Design-heavy; the populator currently fires `CLASS_PREFIX_MISMATCH` on every compound modifier (`disabled`, `hidden`, `wide`) used from a page file because those classes don't carry the page's `cc_prefix`. Per Section 11.2.5, compound modifiers are legitimate as bare class names when used in compound selectors (`.cc-slide-panel.cc-slide-auto-height`). Resolution requires a two-pass approach to recognize compound-modifier classes as valid chrome usage. Touches both CSS populator and HTML populator.

4. **HTML populator: slideout/modal pattern recognition.** Sections 11.1.5 and 11.1.6. Pre-existing items from Session 4's roadmap. Slideout body IDs and nested modal pattern.

5. **PS populator: file-header / FILE_ORG / banner-rule-line gaps.** Sections 11.1.1, 11.1.2, 11.1.3. Also pre-existing items from Session 4.

### 6.2 Other tracked items

- **JS populator performance instrumentation.** Deferred per Decision 4 in Section 3 above. Becomes priority when pipeline wrapper for push-button execution arrives.

- **Page migration resumption.** Once the populator-defect work has cleared enough false positives that future page migrations don't keep surfacing the same gaps, Phase 1 page-by-page conversion resumes. The Backup page is the working template (`CC_Migration_Phase1.md` Section 8).

- **`Object_Registry` registration gaps.** The CSS and JS populator runs both log warnings about four missing files (`business-intelligence-spec.css/.js`, `business-services-spec.css/.js`, `client-relations-spec.css/.js`, `replication-monitoring-spec.css/.js`). Each populator warning, not drift. Adding these files to `dbo.Object_Registry` would enable FK linkage on subsequent runs. Low priority; addresses cataloging warnings, not behavior.

### 6.3 Suggested priority for next session

The chrome-`cc-`-prefix-on-IDs item (point 1 above) is the highest-impact next move. It clears ~16 drift rows across the most-touched files, and the change is structurally simple in both populators. Doing it next would also bring `Backup.ps1` itself closer to zero-drift, since most of `Backup.ps1`'s pending firings are this same code.

After that, the runtime-created chrome ID exemptions (point 2) close out the last visible drift on `cc-shared.js`. That's a more satisfying "this anchor file is now clean" outcome and a good place to pause.

The compound-modifier work (point 3) is the heaviest of the remaining items and probably warrants its own focused session.

### 6.4 Workflow notes for next session

- Continue to enforce: PowerShell scripts pure ASCII. Use `Section ` instead of `§`.
- Pipeline timings captured here are the baseline; comparing future runs against them will indicate whether any new populator work has unintentionally regressed performance.
- The Section 11.1.x backlog in `CC_Migration_Phase1.md` stays as historical reference; new defects surfaced in future sessions are described in their session summary rather than added to the Migration doc backlog.

---

## 7. End-of-session state, in one sentence

**Six populator-defect items shipped clean (Section 11.2.5 finish-out, plus Section 11.1.8, 11.1.9, 11.1.10, 11.1.11, and an inline HTML-spec drift fix), `cc-shared.css` at zero drift, `cc-shared.js` and `backup.js` carrying only the next two pending items between them, JS populator performance characterized and deferred, and a documentation-discipline decision made about where defect work gets recorded going forward.**

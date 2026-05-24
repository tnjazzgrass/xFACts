# CC Session Summary 9 — HTML Populator Rewrite and Shared Drift Accumulation

## Session focus

Ninth session in the CC File Format Standardization initiative. Picks up where Session 8 left off: the HTML spec was locked, the alignment plan was the roadmap, and no decisions blocked implementation work. This session executed the HTML populator rewrite end-to-end against the new spec, ran it in production, audited the results, and surfaced a shared-infrastructure improvement that benefits the entire populator family.

The session deliverables are the rewritten `Populate-AssetRegistry-HTML.ps1` (three delivery cycles, 6,312 lines final) and a behavior change to `Add-DriftCode` in `xFACts-AssetRegistryFunctions.ps1` enabling multi-context drift accumulation when the same drift code fires multiple times on the same row.

The next session opens on the JS phase, beginning with a spec gap audit of `CC_JS_Spec.md` — same shape as the CSS spec audit that produced Session 7's deliverables and the HTML spec audit that produced Session 8's.

---

## What landed

### Deliverable 1 — `Populate-AssetRegistry-HTML.ps1` (full rewrite)

Complete drop-in replacement of the prior populator. 6,312 lines final (up from ~5,500 pre-rewrite). Delivered across three cycles within the session as new validators were added and scope refinements applied.

**Steps 1+2+3 (Delivery 1, 5,590 lines):**

- 21 drift codes retired (overlay pair model, deprecated class/ID name codes)
- 13 new drift codes added (page shell ordering, whitespace discipline, attribute order, action element typing, platform data attribute closed set, argument prefix matching, route variable assignments, route local helper functions, body class prefix discipline)
- Class and ID renames applied: `cc-engine-card` → `cc-card-engine`, `cc-engine-countdown` → `cc-engine-cd`
- Full overlay validator rewrite: prior pair-model (overlay + panel as separate sibling elements) replaced with nested single-rooted model using the `cc-dialog` family per spec Gap 10 resolution
- New `Test-OverlayConstructStructure` validator wired in
- New closed-set constants surfaced as module-level: `$ChromeIdExactSet`, `$ChromeIdSlugPrefixes`, `$PlatformDataAttributes`, `$ActionPermittedTags`, `$ActionPermittedOverlayClasses`

**Steps 4–7 (Delivery 2, 6,235 lines):** Nine new validators added covering the remaining alignment plan items:

1. `Test-RouteVariableAssignments` (PS AST-based) — emits `MISSING_BROWSER_TITLE_VAR`, `MISSING_NAV_HTML_VAR`, `MISSING_HEADER_HTML_VAR`
2. `Test-RouteLocalHelperFunctions` (PS AST-based) — emits `FORBIDDEN_ROUTE_LOCAL_HELPER`
3. `Test-BodyClassPrefixDiscipline` — emits `FORBIDDEN_PAGE_PREFIXED_BODY_CLASS`
4. `Test-PageShellOrder` — emits `MALFORMED_PAGE_SHELL_ORDER`
5. `Test-PageShellWhitespace` — emits `MALFORMED_PAGE_SHELL_WHITESPACE`
6. `Test-AttributeOrder` — emits `MALFORMED_ATTRIBUTE_ORDER`
7. `Test-ActionElementType` — emits `ACTION_ON_NON_INTERACTIVE_ELEMENT`
8. `Test-ArgumentPrefixMatch` — emits `ARGUMENT_PREFIX_MISMATCH`
9. `Test-PlatformDataAttributeClosedSet` — emits `UNREGISTERED_PLATFORM_DATA_ATTRIBUTE`

Production run after Delivery 2: 4,394 rows inserted, 51.5% drift rate. End-to-end success confirmed.

**Step 8 (Delivery 3, 6,312 lines):** `Test-PageShellWhitespace` scope narrowing per spec §1.2.3.

Initial implementation enforced the blank-line rule on every adjacent-element pair within the page shell. Re-reading spec §1.2.3 closely revealed the rule applies only to the elements mandated in §1.2.1 (head) and §1.2.2 (body), NOT to structural opening/closing tags like `<!DOCTYPE>`, `<html>`, `<head>`, `<body>`. The validator was narrowed to enforce exactly five in-scope pairs:

- Inside `<head>`: `</title>` → `<link page.css>`; `<link page.css>` → `<link cc-shared.css>`
- Inside `<body>`: `$navHtml` → `cc-header-bar`; `cc-header-bar` end → `cc-connection-banner`; `cc-connection-banner` end → `cc-page-error-banner`

Page-specific-content boundary pairs and out-of-scope structural pairs are silently skipped. Discrepancy logged as backlog item — spec §1.2.3 may need amendment to address page-specific-content boundaries explicitly.

### Deliverable 2 — `xFACts-AssetRegistryFunctions.ps1` (`Add-DriftCode` behavior change)

Single function modified; rest of file byte-identical to GitHub state. Surfaced when auditing the HTML populator's first production run: Backup.ps1's four engine cards each emitted only a single context in `drift_text` despite the validator firing four structural sub-checks per card. Investigation revealed `Add-DriftCode` was fully idempotent on the drift code — a second call with the same code on the same row silently dropped the caller-supplied `-Context` string.

The new behavior:

- `drift_codes` column still dedupes — a code appears at most once in the comma-separated list
- `drift_text` column now appends caller-supplied `-Context` strings unconditionally when the same code fires multiple times on the same row
- When `Add-DriftCode` is called without `-Context` (caller relies on the master-table description), the description is appended only on first attachment — repeating the generic description would be noise

The change is non-breaking for existing populators. CSS, JS, and PS populators use the aggregate-then-fire pattern for their `FORBIDDEN_COMMENT_STYLE` checks (collect all violations into a list, then make one `Add-DriftCode` call with all lines joined into the context). Since they only call once per code per row, the new accumulation path never triggers for them. Their output is unchanged.

Production re-run after the change confirmed multi-context accumulation works as designed. Backup.ps1 row 146 (cc-card-engine-collection) now shows all four sub-issues in `drift_text`:

```
Card class is 'cc-engine-card'; expected exactly 'cc-card-engine'. |
cc-engine-bar div class is 'cc-engine-bar disabled'; expected exactly 'cc-engine-bar'. |
cc-engine-cd span class is 'cc-engine-countdown'; expected exactly 'cc-engine-cd'. |
cc-engine-cd span contains content; spec requires the element be empty.
```

Pre-change, only the first sub-issue would have survived.

---

## Findings from production audit

After the populator was running cleanly, an audit pass against the catalog surfaced a structural observation worth recording for future work but explicitly deferred from this session.

### Engine card detection scope

`MALFORMED_ENGINE_CARD` fires only on Backup.ps1 because Backup is the only page that has been partially refactored to the new spec — its engine card IDs use the new `cc-card-engine-<slug>` convention, which is the pattern the structural validator keys off (`Invoke-EngineCardValidation` line 4948).

Other pages with engine cards use the pre-refactor convention (`card-engine-<slug>` without the `cc-` prefix, e.g., BatchMonitoring.ps1, BIDATAMonitoring.ps1, BusinessServices.ps1, DBCCOperations.ps1, DmOperations.ps1, FileMonitoring.ps1, IndexMaintenance.ps1, JBossMonitoring.ps1, JobFlowMonitoring.ps1, ReplicationMonitoring.ps1, ServerHealth.ps1). Even further variations exist on Admin.ps1 (`engine-pip`, `engine-backdrop`, `engine-panel`) and ClientRelations.ps1 (`engine-row`).

These elements ARE captured in the catalog as `HTML_ID` rows. They DO fire drift — `MISSING_PREFIX_ID` ("A page-local ID does not begin with the page's prefix"). But they do NOT receive the chrome-construct-specific drift codes (`MALFORMED_ENGINE_CARD`, `MALFORMED_ENGINE_ROW_CONTAINER`) because the structural validators only admit elements that already match the new naming convention.

### The principle this reveals

The HTML populator operates under two different validation philosophies simultaneously:

1. **Element-level cataloging** (HTML_ID, HTML_CLASS, HTML_ACTION rows): permissive admission — the row exists regardless of conformance; drift codes describe what's wrong at the attribute level.
2. **Structural chrome validation** (header bar, refresh info, engine row, engine cards): strict admission — found only when the expected structure is present and named correctly; everything else is invisible to these validators.

The two philosophies don't coordinate. Unrefactored pages get element-level rows for their non-prefixed IDs (with `MISSING_PREFIX_ID`), but never get chrome-specific drift codes because the structural validators couldn't find anything to validate as chrome.

### Decision

Deferred. The current state is acceptable for driving refactor work: every legacy chrome element on every page IS in the catalog and IS firing SOME drift code signaling it needs attention. The drift code is less specific than ideal (a `MISSING_PREFIX_ID` on `card-engine-archive` is technically true but misleading — the right fix isn't "add the page prefix," it's "rename to chrome conventions and conform to the engine card structural spec"). But the signal is sufficient for a human reviewer to identify and plan the refactor.

Rather than expanding chrome detection in another delivery cycle, the populator phase closes here so refactor work can begin. Permissive chrome detection is logged as a backlog item below.

---

## Specs and rules confirmed during the rewrite

A handful of design principles were confirmed in passing during validator implementation. Recording them so they don't have to be re-derived next session:

- **Same-code accumulation is the platform default now.** `Add-DriftCode` accumulates contexts when a validator fires the same code multiple times on the same row. New validators do not need to use the aggregate-then-fire pattern (collect a list, then make one call); they can call `Add-DriftCode` inline at each violation site. Existing aggregate-then-fire callers (PS/JS/CSS `FORBIDDEN_COMMENT_STYLE`) continue working unchanged.

- **Page-shell whitespace rule is scoped, not universal.** Spec §1.2.3's blank-line discipline applies only to elements mandated in §1.2.1 and §1.2.2. Structural HTML scaffolding (DOCTYPE, html, head, body open/close) and page-specific-content boundaries are out of scope. The implementation enforces exactly five in-scope pairs.

- **Engine card structural validation requires Process_Registry routes context.** `Invoke-EngineCardValidation` early-exits if Process_Registry rows are unloaded or if no route paths are mapped for the file. This is correct — engine cards reference orchestrator processes and validation depends on knowing which processes are registered to the page.

- **Overlay validation runs on the concatenated stream, not per-emission.** Modal and slideout constructs can span emission boundaries when constructed in helper functions, so overlay validators receive the full concatenated token stream. This is established behavior carried forward into the new overlay model.

---

## Backlog items added this session

### Permissive chrome construct detection

Engine cards, engine row containers, header bars, refresh-info blocks, modals, and slideouts only get full structural validation when found in spec-conformant location with spec-conformant naming. Pages using legacy chrome conventions get partial cataloging at the element level (with `MISSING_PREFIX_ID` drift) but not chrome-specific drift codes.

Acceptable for the current refactor sweep because every legacy element still fires SOME drift code signaling refactor need. Revisit when chrome refactor is underway and the catalog needs to differentiate "this is the wrong page prefix" from "this is a chrome construct that needs refactoring to chrome conventions."

One possible middle-path resolution: a single new drift code `LEGACY_CHROME_CONSTRUCT` attached to elements matching legacy-shape patterns. Doesn't replicate the four sub-checks of `MALFORMED_ENGINE_CARD`; just flags the row as "this element looks like a chrome construct that hasn't been refactored." Lower implementation cost than full permissive admission across every chrome validator.

### Spec §1.2.3 boundary at page-specific content

The blank-line discipline rule doesn't explicitly address what happens at the boundary between mandated chrome elements and page-specific content. Implementation silently skips these pairs. Spec amendment may be warranted to either include them, exclude them, or define a separate boundary rule.

### Stray `hidden` class definition in `bdl-import.css`

Legacy carry-over from before the class was moved to `cc-shared.css`. Surfaced incidentally during cross-file inspection; not blocking anything but flagged for cleanup the next time the file is touched.

### Optional: port aggregate-then-fire callers to inline pattern

With `Add-DriftCode` natively accumulating contexts, the PS/JS/CSS populators' aggregate-then-fire pattern for `FORBIDDEN_COMMENT_STYLE` could be replaced with inline calls. Low priority — current behavior is correct and produces arguably cleaner output for that specific case (one mention of the rule context, comma-joined line numbers). The inline pattern would produce one entry per line with the rule context repeated. Both work; neither is broken.

---

## Files created this session

- `/mnt/user-data/outputs/Populate-AssetRegistry-HTML.ps1` — final 6,312-line populator, drop-in replacement, in production
- `/mnt/user-data/outputs/xFACts-AssetRegistryFunctions.ps1` — `Add-DriftCode` behavior change applied, drop-in replacement
- `/mnt/user-data/outputs/CC_Session_Summary_9.md` — this document

The `CC_HTML_Populator_Alignment_Plan.md` working doc from Session 8 has served its purpose. It can be moved to `xFACts-Documentation/Planning/WorkingFiles/` for archival reference.

---

## Next session focus

**Open the JS phase with a spec gap audit of `CC_JS_Spec.md`.** Same shape as Session 7's CSS spec audit and Session 8's HTML spec audit.

### The audit question

> If all I had was the spec, could I create a compliant JS file from scratch?

For every section of the spec, walk through what a developer (or Claude) would need to produce conformant content, and identify where the spec is ambiguous, under-specified, or missing constraints. Each gap gets a decision recorded in the same session — gaps are not deferred to backlog; the spec encodes the answer.

### Why this comes before populator alignment

The JS populator can only enforce what the spec defines. Aligning the populator to an incomplete spec produces a populator that's incomplete in the same places. Sessions 7 and 8 demonstrated that the audit-first approach produces clean populator rewrites with no architectural backtracking. Sessions 9 (this session) executed cleanly because the spec was locked before any code was written.

### Session boot sequence

1. Fetch the manifest URL with a fresh cache-buster (`https://raw.githubusercontent.com/tnjazzgrass/xFACts/main/manifest.json?v=<random>`).
2. Fetch the current `CC_JS_Spec.md`.
3. Fetch `Populate-AssetRegistry-JS.ps1` for reference (where the current populator validates).
4. Fetch one or two representative JS files for spec-vs-reality reconciliation (probably `engine-events.js` as the platform anchor and one page-specific JS file).
5. Confirm `CC_CSS_Spec.md` and `CC_HTML_Spec.md` are in Project Knowledge as reference points for the level of precision being targeted.

### Entry-point principle

Same as Session 7 and Session 8: audit the spec section by section. Every gap surfaces, every gap gets a decision, every decision lands in the rewritten spec before any populator work begins.

### Sequence after the spec audit

Following sessions, in order:

1. **JS spec rewrite** (this session's audit output) — produces the new `CC_JS_Spec.md` and a `CC_JS_Populator_Alignment_Plan.md`.
2. **JS populator rewrite** — implements the alignment plan against the new spec, mirroring this session's HTML populator work.
3. **PS phase opens** — same audit-first → spec rewrite → populator rewrite sequence.

After PS, the populator family is fully aligned and the cross-file refactor initiative can proceed against a complete catalog.

---

## Cross-file refactor initiative — current standing

Unchanged from Session 8 except for the items completed this session:

**Now complete:**

- HTML populator rewrite (Session 9 — this session).
- `Add-DriftCode` shared-helper accumulation (Session 9 — incidental but benefits all four populators).

**Currently parked in the initiative:**

- `cc-shared.css` rewrite to migrate `cc-modal-*` and `cc-slide-panel-*` separate families to the unified `cc-dialog-*` family from HTML spec Gap 10. Largest pending item; coordinates with cc-shared.js overlay click-handler logic; required before Backup's overlay constructs can be rewritten to Category-A compliance.
- Helper module audit. Confirm `xFACts-CCShared.psm1` emits only chrome IDs from the closed set in HTML spec §5.1.
- Chrome construct legacy-shape detection (newly added — see Backlog above).

**Not parked in this initiative (handled by future sessions):**

- JS populator rewrite (next session opens the audit).
- PS populator rewrite (after JS).
- Backup Category-A compliance for non-overlay constructs (eventually).

---

## End-of-session state, in one sentence

**HTML populator rewrite complete and verified in production at 4,394 rows / 51.5% drift, `Add-DriftCode` accumulation behavior now the platform default and unlocking multi-context drift detail across all four populators, structural chrome-detection gap surfaced and consciously deferred to enable refactor work to begin, and the JS phase opens next session with a spec gap audit following the established audit-first sequence.**

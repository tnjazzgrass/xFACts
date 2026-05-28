# CC Session Summary 16 — Shape A → Shape B Overlay Migration, Spec Amendments, Clean Baseline Established

*Session date: 2026-05-27.*

---

## 1. Purpose

This session closed out the queued work items from Session 15 and brought the refactored CC file set to a clean drift baseline. Three threads landed end-to-end:

1. The §4.2 engine-card countdown reconciliation, queued from Session 15.
2. The §4.1 Shape A → Shape B overlay migration across the CC platform, executed via the Option X dialog-class arrangement after Option B failed mid-deployment.
3. Spec amendments mandating the new dialog secondary class, a CC JS Spec section codifying the overlay open/close handler patterns, and an access-denied page carve-out for the inline `<style>` block.

By session end, the four populators were re-run against the deployed file set with zero unexpected drift on refactored files. The remaining drift on `Backup.ps1` (two transitional codes from the temporary `Import-Module` line) and the cross-module `DUPLICATE_FUNCTION_DEFINITION` codes are both gated on completing the page-by-page refactor pass, which is the next phase.

---

## 2. What was done

### 2.1 §4.2 — Engine-card countdown reconciliation

**Files:** `CC_HTML_Spec.md`, `cc-shared.js`, `Populate-AssetRegistry-HTML.ps1`

Three coordinated changes:

- `CC_HTML_Spec.md` §2.3 template: removed the placeholder `--` content from the `cc-engine-cd` span. The span is rendered empty in the source template; runtime text comes from `cc-shared.js`.
- `cc-shared.js` `cc_tickEngineIndicator`: removed two `els.cd.innerHTML = '&nbsp;'` placeholder writes that conflicted with the new empty-template rule.
- `Populate-AssetRegistry-HTML.ps1`: tightened the engine-card countdown empty check from `IsNullOrWhiteSpace($bt.Raw)` to `$bt.Raw.Length -eq 0` so the validator matches the new "truly empty" template requirement. A separate doc-comment fix corrected a `<span class="cc-dialog-title">` → `<h3 class="cc-dialog-title">` reference. BOM stripped.

### 2.2 §4.1 — Shape A → Shape B overlay migration

The platform's overlay markup was migrated from Shape A (outer overlay element and inner dialog as siblings, with the outer carrying both dimmer styling and inner-panel layout) to Shape B (outer overlay containing a nested `.cc-dialog` direct child, with the outer responsible only for full-viewport dimming and the inner dialog responsible for its own positioning and sizing).

#### 2.2.1 The Option B → Option X pivot

Initial deployment used Option B: outer overlay carried both the full-viewport dimmer styling and the inner-panel positioning (using descendant or child combinators on the outer's state classes). This failed in production — neither retention slideout opened, and modals rendered with funky sizing. Root cause was a CSS Spec §7.2/§14 violation: descendant and child combinators are forbidden by the state-on-element pattern, so the CSS rules that would have made Option B work could not be written in spec-compliant form.

Option X resolved this. The outer overlay (`cc-modal-overlay`, `cc-slide-overlay`, `cc-slideup-overlay`) is purely a full-viewport dimmer with no responsibility for the dialog's size or position. The inner `.cc-dialog` carries a secondary class identifying which overlay it belongs to — `cc-dialog-modal`, `cc-dialog-slide`, or `cc-dialog-slideup` — and those secondary classes carry the dialog's positioning, sizing, and animation behavior. Width-tier modifiers (`cc-medium`, `cc-wide`, `cc-xwide`) live on the inner dialog alongside the secondary class. All CSS is single-class-per-rule, spec-compliant, and works correctly.

#### 2.2.2 Slide-overlay animation timing

A second bug surfaced after the Option X CSS rules went live: slide overlays did not animate on open. Adding `cc-open` to the outer overlay and the inner `.cc-dialog` in the same JavaScript tick caused the browser to skip the CSS transition because the dialog wasn't yet in the render tree at the moment the transition target was applied.

The fix is the canonical open/close handler pattern now codified in CC_JS_Spec §11.5.3:

- **On open:** add `cc-open` to the outer overlay (so the dialog enters the render tree at its off-screen position), then `requestAnimationFrame` to add `cc-open` to the inner dialog (giving the browser one paint cycle to record the starting position before the transition target applies).
- **On close:** remove `cc-open` from the inner dialog first (which starts the slide-out transition), and register a one-shot `transitionend` listener that removes `cc-open` from the outer overlay only after the dialog finishes sliding out (so the dimmer stays in place during the slide).

This pattern applies to slide and slide-up overlays. Dynamic modals (overlay created at handler runtime) and static modals (declared in HTML with `cc-hidden`) do not need rAF or transitionend timing — their CSS animations are keyframe-based and run on first paint regardless.

#### 2.2.3 Attribute-rename revert

During mid-session debugging, an incorrect fix was briefly applied that renamed the slideout argument attributes from `data-action-bkp-type` to `data-bkp-type` (and the retention-card attribute from `data-action-bkp-retention-type` to `data-bkp-retention-type`). After re-reading CC_HTML_Spec §7.4.1, the original names were confirmed spec-compliant: argument attributes live in the `data-action-*` namespace by design so the populator can distinguish events from arguments via the §7.3 closed-set check. The rename was reverted. The actual bug was that the JS-side dataset reads were using `target.dataset.bkpType` and `target.dataset.bkpRetentionType` instead of the spec-correct `target.dataset.actionBkpType` and `target.dataset.actionBkpRetentionType`. The JS reads were corrected; the HTML attributes stayed at their spec-compliant names.

#### 2.2.4 Files delivered

- `cc-shared.css` — Option X overlay system; new `.cc-dialog-modal`, `.cc-dialog-slide`, `.cc-dialog-slideup` rules; engine popup state classes replacing inline style; new `--z-engine-popup` token.
- `cc-shared.js` — `cc_showAlert` and `cc_showConfirm` emit Shape B markup with the secondary dialog class; engine popup status uses state-class pattern instead of inline style; redundant `el.style.display` calls removed from connection banner functions.
- `Backup.ps1` — three Shape B overlays (modal + two slideouts) with correctly-prefixed `data-action-bkp-type` attributes per spec §7.4.1; outer overlay IDs simplified.
- `backup.js` — retention card emits `data-action-bkp-retention-type`; dataset reads use correct `actionBkpRetentionType` and `actionBkpType` camelCase; slide-overlay open/close handlers implement the rAF + transitionend timing pattern.
- `backup.css` — em-dash sweeps; comment references updated from `cc-modal-body` family to `cc-dialog-body` family.

All five files: pure ASCII, no BOM, correct line endings (CRLF for `.ps1`, LF for `.css`/`.js`).

### 2.3 Spec amendments

**Files:** `CC_HTML_Spec.md`, `CC_JS_Spec.md`

#### CC_HTML_Spec amendments

Six surgical edits, no other content changed:

- §5.4 prose intro: added the factual statement that the inner `.cc-dialog` carries a matching secondary class.
- §5.4.1 / §5.4.2 / §5.4.3 templates: opening dialog div now reads `<div class="cc-dialog cc-dialog-modal">` / `cc-dialog-slide` / `cc-dialog-slideup` respectively.
- §5.4.4 rules: added one bullet mandating the secondary class on the inner dialog.
- §12 forbidden-patterns table: added a row covering the missing secondary class case.
- §13.2 overlay construct class table: added three rows for `cc-dialog-modal`, `cc-dialog-slide`, `cc-dialog-slideup`.
- §14 drift code reference: added `MISSING_DIALOG_CLASS` entry.

#### CC_JS_Spec amendments

Two edits in rule-only style consistent with the rest of §11:

- New §11.5 "Overlay open/close handler patterns" with three subsections (§11.5.1 dynamic modal, §11.5.2 static modal, §11.5.3 static slide overlay) plus §11.5.4 rules. Each subsection: one-sentence framing, code template, terse rule bullet.
- §12.2 direct-binding carve-out list extended with item 3: one-shot `transitionend` listeners inside overlay close handlers per §11.5.3.

No new drift codes for §11.5 — the handler-pattern violations are not statically detectable.

### 2.4 Access-denied page carve-out

**Files:** `CC_HTML_Spec.md`, `Populate-AssetRegistry-HTML.ps1`, `xFACts-CCShared.psm1`

The populator was firing `FORBIDDEN_INLINE_STYLE_BLOCK` and `FORBIDDEN_INLINE_STYLE_ATTRIBUTE` on the `Get-AccessDeniedHtml` function inside `xFACts-CCShared.psm1`. The function inlines a `<style>` block because authentication or authorization failure may coincide with conditions that prevent loading `/css/cc-shared.css`, and the page must remain styled in that case. A narrow carve-out was added rather than restructuring the page to depend on a separate stylesheet.

Three coordinated changes:

- `CC_HTML_Spec.md` §1.4 rewritten to acknowledge the inline `<style>` block carve-out, scoped specifically to the `Get-AccessDeniedHtml` helper. The brief rationale is retained in the spec text because the exception is unusual enough to warrant it. The inline `style="..."` attribute prohibition is explicitly unaffected.
- §12 forbidden-patterns table row for the `<style>` block annotated with `(except per §1.4)`. §14 drift code entry for `FORBIDDEN_INLINE_STYLE_BLOCK` annotated with the same.
- `Populate-AssetRegistry-HTML.ps1`: the FORBIDDEN_INLINE_STYLE_BLOCK emission point now checks `$ParentFunction -ne 'Get-AccessDeniedHtml'` before firing. The walker already had `$ParentFunction` in scope from `Invoke-HtmlTokenWalk`'s parameter list, sourced from `$em.FunctionName` at the call site.
- `xFACts-CCShared.psm1` `Get-AccessDeniedHtml`: the one inline `style="font-size: 12px; color: #666;"` on the small subtext paragraph was folded into a new `.denied-subtext` class inside the `<style>` block. This keeps `FORBIDDEN_INLINE_STYLE_ATTRIBUTE` strict (no carve-out for inline attributes anywhere) and limits the `<style>` block carve-out to exactly one function.

### 2.5 New populator drift code wiring

**File:** `Populate-AssetRegistry-HTML.ps1`

Two-part addition:

- `MISSING_DIALOG_CLASS` added to the `$DriftDescriptions` master table.
- New `Test-OverlayDialogClass` helper function (~50 lines): given an outer-overlay token index and the overlay kind, walks to the inner `.cc-dialog`, reads its class tokens, and returns whether the expected secondary class is present. Returns `$true` when the kind is unrecognized or the inner dialog cannot be located (those cases are the structural validator's concern).
- `Invoke-OverlayPostWalkValidation` extended: the existing per-construct foreach now branches on whether the structural check passed. On structural failure, the existing `MALFORMED_<KIND>_STRUCTURE` code fires as before. On structural pass, the new dialog-class check runs and fires `MISSING_DIALOG_CLASS` with a context message naming the expected class. Both code emissions attach to the construct's `HTML_ID` row when available, falling back to the file's `HTML_FILE` row.

The section comment above `Test-OverlayConstructStructure` was updated to describe three validators instead of two, with the new check listed in source order.

---

## 3. Locked decisions and principles reinforced

### 3.1 Outer overlay versus inner dialog responsibility (Option X)

The outer overlay element (`cc-modal-overlay`, `cc-slide-overlay`, `cc-slideup-overlay`) is responsible only for full-viewport dimming. The inner `.cc-dialog` carries its own positioning, sizing, and animation via a secondary class (`cc-dialog-modal`, `cc-dialog-slide`, or `cc-dialog-slideup`). Width tiers (`cc-medium`, `cc-wide`, `cc-xwide`) attach to the inner dialog. This arrangement is the only spec-compliant way to give each construct independent position and size when CSS combinators are forbidden by CSS Spec §7.2/§14.

### 3.2 Argument attributes live in the `data-action-*` namespace

HTML Spec §7.4.1 requires argument attribute names to take the form `data-action-<prefix>-<arg-name>`. This is intentional and not a mistake — the populator distinguishes events from arguments via the §7.3 closed-set check, all within one parse pass. Corollary: JS-side dataset reads must use the corresponding camelCase form (`data-action-bkp-type` → `dataset.actionBkpType`, not `dataset.bkpType`).

### 3.3 Three overlay open/close handler patterns

JS Spec §11.5 codifies three patterns, selected by overlay lifecycle rather than overlay kind:

- **Dynamic modal** (§11.5.1) — handler builds the overlay element via `document.createElement`, appends to body, removes on close. CSS keyframe runs on first paint.
- **Static modal** (§11.5.2) — overlay declared in HTML with `cc-hidden`. Open removes `cc-hidden`; close adds it. CSS keyframe runs when display flips from `none` to `flex`.
- **Static slide overlay** (§11.5.3) — overlay declared in HTML without `cc-hidden`. Open adds `cc-open` to outer, then `requestAnimationFrame` adds `cc-open` to inner dialog. Close removes `cc-open` from dialog, waits for `transitionend` to remove `cc-open` from outer.

### 3.4 Access-denied page is the sole inline `<style>` carve-out

CC_HTML_Spec §1.4 carves out the `<style>` block prohibition for the `Get-AccessDeniedHtml` helper specifically. Every other location in the platform is strict: no `<style>` blocks outside SVG, no `style="..."` attributes anywhere. Future similar needs require a spec amendment, not informal exception.

### 3.5 Spec drift codes are not the place for rationale

The CC spec family is held to a rule-only discipline to prevent the document set from ballooning over time. Rationale or explanatory text in the spec is reserved for exceptions where a rule is unusual enough that "why" is essential context (the §1.4 access-denied carve-out qualifies; the §11.5 handler patterns do not). Code comments inside populator source are where mechanism-level explanation lives.

---

## 4. Drift baseline at session end

### 4.1 Day-over-day delta

Last clean run 2026-05-26 vs last run 2026-05-27:

| Populator | 5/26 rows | 5/27 rows | Delta | Drift count delta |
|---|---|---|---|---|
| CSS | 8665 | 8659 | −6 | 0 |
| HTML | 4387 | 4380 | −7 | −9 |
| JS | 10614 | 10622 | +8 | 0 |
| PS | 17392 | 17421 | +14 | −11 |

Net: −20 drift codes across all four populators. Row deltas explained by: CSS Option X consolidation removing some duplicated rules; HTML Shape A → Shape B compression of sibling pairs into nested constructs; JS Shape B emission additions; PS source growth from the populator code we modified this session.

### 4.2 Remaining drift on refactored files

Only two transitional drift codes remain on the refactored file set, both on `Backup.ps1`:

- `MISSING_RBAC_CHECK_PAGE` — fires because `Import-Module xFACts-CCShared.psm1` is the first statement in the route scriptblock instead of `Get-UserAccess`.
- `MISPLACED_IMPORT` — fires because that same Import-Module line lives in the ROUTE section instead of an IMPORTS section.

Both clear automatically once the Import-Module line is removed, which happens during the helper-module consolidation at the end of the page-by-page refactor phase (see §5).

### 4.3 Pre-existing drift not addressed this session

`DUPLICATE_FUNCTION_DEFINITION` across `xFACts-CCShared.psm1` and `xFACts-Helpers.psm1` continues to fire on every duplicated function name. These clear once `xFACts-Helpers.psm1` is deleted, which is gated on completing the page-by-page refactor.

---

## 5. Transition to phase 2 — page-by-page refactor

The CC File Format Standardization initiative now moves into its second phase: refactoring the 18 remaining page routes (and their companion API, JS, CSS files) to the new spec. Each page is refactored from the spec alone. The specs are complete and self-contained; that is the entire point of the initiative. Page files vary widely in functionality across xFACts, and no existing page is held up as a canonical reference for the others. Where the spec is unclear on a particular question during a refactor, the gap should be discussed prior to any action being taken. This may result in a spec amendment but it must be discussed first.
**We must never adjust the spec or a populator to accommodate existing page content under any circumstances!** 
Backup Monitoring is available for reference if confusion arises about how a particular spec rule manifests in working code, but it is not a template — refactors do not copy its structure or pattern-match against it.

### 5.1 Sequencing constraint

`xFACts-Helpers.psm1` cannot be deleted until every page route has been refactored. The currently-unrefactored 18 pages still call functions that exist only in `xFACts-Helpers.psm1`; deleting it now would break them. Each page's refactor includes adding the transitional `Import-Module xFACts-CCShared.psm1` line at the top of its scriptblock so the page uses the cc-prefixed emission helpers. This line is transitional, exists only during phase 2, and is removed when the helper-module consolidation runs.

Once all 18 pages are refactored, the helper-module consolidation runs as a single final step: modify `Start-ControlCenter.ps1` to load `xFACts-CCShared.psm1` at startup, remove the transitional Import-Module line from every refactored page in one pass, delete `xFACts-Helpers.psm1`, re-run populators. This step clears Backup's two transitional drift codes and the cross-module `DUPLICATE_FUNCTION_DEFINITION` codes in one batch.

### 5.2 First page for phase 2 — Replication Monitoring

Dirk's choice. Rationale: during an early stage of the CC File Format Standardization initiative, five CSS and JS files were refactored to an early-version draft of the spec. Copies of those refactored files exist and are much closer to the current spec than the files currently running in production. Starting with Replication Monitoring may save substantial time on the CSS and JS portion of that refactor — the early-draft files provide a head start rather than refactoring from scratch.

Session 17 opens with this. Subsequent page order is Dirk's choice and will be set per session.

### 5.3 Workflow loop per page

For each page, the refactor loop is roughly:

1. Pull the current page route + API + JS + CSS files (and the early-draft copies if they exist for this page).
2. Rewrite each file directly from the relevant CC spec. CC_HTML_Spec governs page-route HTML emission; CC_PS_Spec governs the PowerShell shape; CC_JS_Spec governs the JS file; CC_CSS_Spec governs the CSS file. The spec is the only reference.
3. Push to GitHub.
4. Re-run the four populators against the deployed files.
5. Read the drift catalog for the four updated files. Fix any flagged items. Re-push.
6. Move to next page.

### 5.4 Resources entering phase 2

- **Specs** — CC_HTML_Spec, CC_CSS_Spec, CC_JS_Spec, CC_PS_Spec are all current and authoritative on file shape.
- **Populators** — All four populators are current and reflect the spec. Drift output is the work-list for each page refactor.
- **Backup reference** — `Backup.ps1`, `Backup-API.ps1`, `backup.js`, `backup.css` are available for reference if a question comes up about how a specific spec rule manifests in working code. They are not a template. Page refactors are driven from the spec; the Backup file set is consulted only when needed to disambiguate a spec rule, not as a starting point or pattern to imitate.
- **Cross-references** — `xFACts-CCShared.psm1` exports the cc-prefixed emission helpers (`Get-NavBarHtml`, `Get-PageHeaderHtml`, `Get-PageBrowserTitle`, `Get-AccessDeniedHtml`, etc.) and is the target the transitional `Import-Module` line points at on each refactored page.

---

## 6. Files changed and pushed in session 16

| File | Change |
|---|---|
| `CC_HTML_Spec.md` | §1.4 access-denied carve-out; §5.4 dialog secondary class; §12 forbidden-patterns rows; §13.2 class table additions; §14 drift code additions |
| `CC_JS_Spec.md` | New §11.5 overlay handler patterns; §12.2 transitionend carve-out |
| `Populate-AssetRegistry-HTML.ps1` | `MISSING_DIALOG_CLASS` drift code; `Test-OverlayDialogClass` helper; per-construct dialog-class validation in `Invoke-OverlayPostWalkValidation`; engine-card countdown empty check tightened; `Get-AccessDeniedHtml` carve-out on FORBIDDEN_INLINE_STYLE_BLOCK; BOM stripped |
| `cc-shared.css` | Option X overlay system; new `.cc-dialog-modal/-slide/-slideup` rules; engine popup state classes; `--z-engine-popup` token |
| `cc-shared.js` | Shape B alert/confirm emission; engine popup state-class pattern; banner display-call cleanup; em-dash sweep |
| `Backup.ps1` | Shape B overlays; spec-compliant `data-action-bkp-type` argument attributes; outer overlay ID rename |
| `backup.js` | Spec-compliant `data-action-bkp-retention-type`; correct dataset reads; slide-overlay open/close timing handlers |
| `backup.css` | Em-dash sweep; comment reference updates to `cc-dialog-*` family |
| `xFACts-CCShared.psm1` | `Get-AccessDeniedHtml` updated: `.denied-subtext` class folded into `<style>` block, inline `style="..."` removed; description updated to reference §1.4 carve-out |

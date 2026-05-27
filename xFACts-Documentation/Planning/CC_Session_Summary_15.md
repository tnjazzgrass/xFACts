# CC Session Summary 15 — PS Populator Prefix Carve-Out + Backup Page Initial Cleanup

*Session date: 2026-05-27.*

---

## 1. Purpose

This session addressed three populator-side defects surfaced by the prior session's drift run, then applied initial cleanup to `Backup.ps1` to clear the safe portion of its HTML drift. Two structural questions about the codebase surfaced during the work and are queued as the lead items for the next session before further page refactoring proceeds.

The session opened with an investigation into whether changing the PS populator's `PREFIX_REGISTRY_MISMATCH` semantics would affect the HTML populator. The investigation confirmed the two populators do not cross-reference each other's banner state, clearing the way for the PS-side changes to land without downstream risk.

---

## 2. What was done

### 2.1 PS spec amendment — `PREFIX_REGISTRY_MISMATCH` carve-out

**File:** `CC_PS_Spec.md`

The §17 drift table entry for `PREFIX_REGISTRY_MISMATCH` was rewritten to scope the check to identifier-bearing sections only (CONSTANTS, VARIABLES, FUNCTIONS). Identifier-free sections (CHANGELOG, IMPORTS, PARAMETERS, INITIALIZATION, EXECUTION, ROUTE, EXPORTS) declare `(none)` regardless of the file's registered prefix and are explicitly exempt from the check.

A new drift code `MISPLACED_NONE_PREFIX` was added to the §17 drift table to capture the case where an identifier-bearing section declares `Prefix: (none)` in a file whose component has a registered (non-NULL) `cc_prefix`. This is structurally distinct from `PREFIX_REGISTRY_MISMATCH` (declaring a wrong prefix value) and warrants its own diagnostic signal.

### 2.2 PS populator — `PREFIX_REGISTRY_MISMATCH` rewrite + new drift emission

**File:** `Populate-AssetRegistry-PS.ps1`

Two new config constants added at the top of the populator:

- `$IdentifierBearingSectionTypes = @('CONSTANTS','VARIABLES','FUNCTIONS')`
- `$IdentifierFreeSectionTypes = @('CHANGELOG','IMPORTS','PARAMETERS','INITIALIZATION','EXECUTION','ROUTE','EXPORTS')`

The banner-prefix validation block (previously firing `PREFIX_REGISTRY_MISMATCH` blindly on `(none)` whenever the file had a registered prefix) was rewritten to:

- Skip the registry check entirely on identifier-free sections.
- Fire `MISPLACED_NONE_PREFIX` when an identifier-bearing section declares `(none)` in a registered-prefix file.
- Continue firing `PREFIX_REGISTRY_MISMATCH` when an identifier-bearing section declares a prefix that does not match the registry.

The new `MISPLACED_NONE_PREFIX` code was added to `$script:DriftDescriptions`.

### 2.3 Helpers — `FORBIDDEN_CHANGELOG_IN_HEADER` false-positive fix

**File:** `xFACts-AssetRegistryFunctions.ps1`

`Get-PSFileHeaderInfo` Pass 4 was extended with a second carve-out on the FILE ORGANIZATION block region. List entries inside that block name the file's section banners verbatim; when the file has a `CHANGELOG` section banner, the list entry for it also begins with `CHANGELOG`. The Pass 4 keyword scan now computes `$fileOrgBlockStart` (two lines after the FILE ORG label, skipping the label and separator) and `$fileOrgBlockEnd` (first blank line or end of header), and skips the `CHANGELOG`-keyword check inside that range. The existing separator carve-out behavior was preserved unchanged.

A new 2026-05-27 CHANGELOG entry was added to the helpers file documenting the carve-out.

### 2.4 PS populator — `EXCESS_BLANK_LINES` rewrite

**File:** `Populate-AssetRegistry-PS.ps1`

The previous implementation measured line-number gaps between adjacent AST `EndBlock.Statements` entries, which incorrectly counted intervening banner block comments (not AST statements but non-blank source content) as if they were blank lines. The rewrite scans the source text line-by-line, counting consecutive runs of whitespace-only lines, and skips lines that fall inside multi-line constructs (block comments, here-strings) where blank lines are author content not subject to the top-level discipline. Skip regions are computed from the parser's token stream via the tokens' `.Extent.StartLineNumber` and `.Extent.EndLineNumber`.

### 2.5 Spec section reference cleanup

**Files:** `Populate-AssetRegistry-PS.ps1`, `xFACts-AssetRegistryFunctions.ps1`

All `§N.N`, `Section N.N`, `Per CC_PS_Spec.md Section N`, and similar in-code references to spec section numbers were stripped from both files. The rule prose was preserved or rephrased so the comment stands alone as a description of what the code does, rather than pointing at an external section number that may shift independently.

### 2.6 Backup.ps1 — partial HTML drift cleanup (5 of 10 rows)

**File:** `Backup.ps1`

Five drift rows on `Backup.ps1` were cleared via direct HTML emission edits:

- Engine card outer class: `cc-engine-card` → `cc-card-engine` (×4 cards)
- Engine bar div class: `cc-engine-bar cc-disabled` → `cc-engine-bar` (×4 cards; runtime JS still toggles `cc-disabled` via `cc-shared.js`, which is invisible to the populator and unaffected)
- Engine countdown span class: `cc-engine-countdown` → `cc-engine-cd` (×4 cards)
- Engine countdown span content: `&nbsp;` → empty (×4 cards)
- Page-shell whitespace: one blank line added between `cc-connection-banner` and `cc-page-error-banner` divs

The five remaining `Backup.ps1` drift rows (1 × `MALFORMED_MODAL_STRUCTURE`, 2 × `MALFORMED_SLIDEOUT_STRUCTURE`, 2 × `OVERLAY_BLOCK_NON_CONTIGUOUS`) are not cleanly fixable inside `Backup.ps1` alone — they require a coordinated migration across `Backup.ps1`, `backup.js`, `backup.css`, `cc-shared.js`, and `cc-shared.css`. This work is queued as the lead item for next session (§4.1).

The `MISSING_RBAC_CHECK_PAGE` and `MISPLACED_IMPORT` rows on `Backup.ps1` remain — these are tracked as known-temporary migration shim items, not addressed this session.

---

## 3. Expected drift catalog deltas

Of the 16 drift rows from the session-start drift report:

- 3 × `PREFIX_REGISTRY_MISMATCH` on `(none)` banners (Backup-API.ps1, Backup.ps1) → **cleared** by §2.2
- 1 × `FORBIDDEN_CHANGELOG_IN_HEADER` on `Backup.ps1` → **cleared** by §2.3
- 1 × `EXCESS_BLANK_LINES` on `xFACts-CCShared.psm1` → **cleared** by §2.4
- 5 × `MALFORMED_ENGINE_CARD` / `MALFORMED_PAGE_SHELL_WHITESPACE` on `Backup.ps1` → **cleared** by §2.6
- 2 × known-temporary on `Backup.ps1` (`MISSING_RBAC_CHECK_PAGE`, `MISPLACED_IMPORT`) → remain (tracked)
- 1 × `FORBIDDEN_INLINE_STYLE_BLOCK` / `FORBIDDEN_INLINE_STYLE_ATTRIBUTE` on `xFACts-CCShared.psm1` → remains (cross-file refactor queued)
- 5 × Backup.ps1 overlay drift (`MALFORMED_MODAL_STRUCTURE`, `MALFORMED_SLIDEOUT_STRUCTURE` ×2, `OVERLAY_BLOCK_NON_CONTIGUOUS` ×2) → remain (queued as §4.1)

Post-session expected: **11 rows down to 8 rows**, with the remaining 8 all queued or known-temporary.

---

## 4. Next session — investigation-first agenda

The next session's lead items are **two structural investigations + one coordinated refactor**, in this order. Page refactoring (Replication Monitoring is the named candidate) does NOT begin until these three items resolve, because each one has the potential to invalidate work done before it.

### 4.1 CC Overlay Migration — Shape B (single-nested with `.cc-dialog`)

**Carries:** 5 drift rows on `Backup.ps1` (1 × `MALFORMED_MODAL_STRUCTURE`, 2 × `MALFORMED_SLIDEOUT_STRUCTURE`, 2 × `OVERLAY_BLOCK_NON_CONTIGUOUS`).

Migration of all three overlay types (modal, slideout, slide-up) from sibling-pair to single-nested form with the unified `.cc-dialog` inner shape. Current state: `CC_HTML_Spec.md` defines Shape B; the HTML populator validates Shape B; the deployed `Backup.ps1`, `backup.js`, `cc-shared.js` (`cc_showAlert` / `cc_showConfirm`), and CSS still use Shape A. The platform runs Shape A everywhere; Shape B exists only as documentation.

**Brief history (so we don't relitigate the direction):**

1. Original spec used sibling pairs everywhere — overlay backdrop and dialog panel as two top-level siblings with two IDs.
2. §11.2.2 (2026-05-18) moved modals to single-nested after recognizing the modal "overlay" was just a flex-centering wrapper, never addressed independently from the dialog at runtime. Slideouts and slide-ups stayed as sibling pairs at that point.
3. Subsequent spec evolution moved slideouts and slide-ups to single-nested with the unified `.cc-dialog` family — applying the same insight more broadly: the "second runtime element" concern can be handled via event delegation on the outer overlay rather than requiring a separate sibling element.

Shape B is the endpoint of this direction, not a flip-flop. The further-evolution rationale was the unified `.cc-dialog` shape — one CSS rule set styles header/body/actions across modals, slideouts, and slide-ups; one ID per construct instead of two; one purpose comment instead of two.

**Scope:**

1. **First task: read `cc-shared.css` and `backup.css`** to inventory current Shape A selectors and identify whether any `.cc-dialog` family rules already exist from prior partial migration attempts. This determines whether step 2 below is "add and sunset" or "replace from scratch".
2. Update `cc-shared.css` to add the `.cc-dialog` family rules: `.cc-dialog`, `.cc-dialog-header`, `.cc-dialog-title`, `.cc-dialog-close`, `.cc-dialog-body`, `.cc-dialog-actions`. Migrate the modal animation rule (`cc-modal-overlay` show/hide) and slideout animation rule (`cc-slide-overlay` show/slide) to target the new nested shape — backdrop fade on the outer, slide-in on the inner `.cc-dialog`. Sunset old `.cc-modal-*` and `.cc-slide-panel-*` rules in the same pass.
3. Update `cc_showAlert` and `cc_showConfirm` in `cc-shared.js` to emit Shape B markup (`cc-dialog` family classes inside their generated overlays).
4. Update `backup.js` slideout open/close handlers (`bkp_openRetentionDetail`, `bkp_closeRetentionSlideout`) to operate on a single consolidated ID per construct instead of separate overlay and panel IDs. Modal show/hide handlers (`bkp_openModal` / similar) remain on `bkp-modal-detail-overlay` since that ID stays.
5. Update `Backup.ps1` HTML emission to Shape B: collapse each slideout's sibling pair into one outer overlay containing a `.cc-dialog`. Modal gets the same `.cc-dialog` family rename. Single purpose comment per construct.
6. Verify the Backup page works end-to-end: modal open/close, both retention slideouts open/close, backdrop dismiss on click, slide and fade animations.
7. Run all four populators; confirm the 5 modal/slideout drift rows clear.

**Outcome:** Shape B established as the working convention. Future page migrations (starting with Replication Monitoring) author Shape B from the start with no Shape A baggage.

### 4.2 Spec / populator / runtime reconciliation pass

**Discovered:** This session, when the spec example showed `<span class="cc-engine-cd">--</span>` while the populator enforces an empty span, and `cc-shared.js` writes `&nbsp;` to the same element at runtime when no countdown value is set. Three sources of truth disagree about what content should appear inside an engine countdown span before the first tick.

**Why this is a session-blocker, not a backlog item:**

Drift codes are the contract between the spec (what the rule is supposed to be) and the populator (what the rule actually enforces). When they disagree, work done against the spec's text can fail validation against the populator. This session that cost a round-trip on the countdown content; in a more complex case it could mask real bugs or generate phantom drift that wastes investigation cycles.

The risk is structural, not just cosmetic. Page refactoring relies on knowing exactly what each drift code means and what authored markup satisfies it. If the populator enforces something different from what the spec describes, every refactor pass has to be re-checked against the populator's actual behavior, not the spec's text.

**Scope:**

1. **Engine card countdown content specifically.** Decide which of the three sources is canonical:
   - Empty span (what the populator enforces today)
   - Literal `--` (what `CC_HTML_Spec.md` §2.3 currently shows in the canonical template)
   - `&nbsp;` (what `cc-shared.js` writes at runtime when there is no countdown value, and what the original spec specified)
   
   Then sync the other two to match. Most likely outcome: empty wins (JS overwrites with the actual countdown immediately on first tick anyway), spec text updates to remove the `--`, and the JS `cdText` fallback changes from `els.cd.innerHTML = '&nbsp;'` to leaving the element empty.

2. **General spec/populator drift audit.** Walk the §17/§14 drift code tables in each spec against the actual populator's drift descriptors and check logic. For each code, confirm:
   - The spec's description matches what the populator's drift context message says.
   - The spec's rule prose matches what the populator's check logic actually tests.
   - Any canonical examples in the spec body are accepted by the populator without firing drift.
   
   Where they disagree, decide which one is right and sync the other.

3. **Investigate the empty-span check observation from this session.** When the deployed `Backup.ps1` had empty cc-engine-cd spans, both empty (`></span>`) and single-space (`> </span>`) passed the populator's empty-content check after a fresh HTML populator run. Both should pass given the populator's `Text + IsNullOrWhiteSpace` skip condition, but it's worth confirming the boundary is exactly where the populator code says it is and that there isn't an edge case (e.g., truly-zero-content vs. whitespace-only-content) that would surface differently with different tokenizer output.

### 4.3 `cc-shared.psm1` inline style cleanup (1 row, queued)

**Carries:** 1 row on `xFACts-CCShared.psm1` — `FORBIDDEN_INLINE_STYLE_BLOCK` (line 1495) and `FORBIDDEN_INLINE_STYLE_ATTRIBUTE` (line 1522) on `Get-AccessDeniedHtml`. Cross-file refactor that's been queued for some time.

Migrate the inline `<style>` block and inline `style="..."` attribute in `Get-AccessDeniedHtml` to a stylesheet — either an addition to `cc-shared.css` or a dedicated `cc-access-denied.css` loaded by the access-denied response. This is a small, contained refactor and is grouped here so all known cross-file drift items resolve in the same session as the overlay migration, leaving the codebase in a clean baseline state before page-by-page refactoring resumes.

---

## 5. After the next session

Once §4.1, §4.2, and §4.3 land cleanly, the platform is at "all known drift resolved or known-tracked, all specs and populators reconciled, Shape B established as the working overlay convention." That's the baseline state for resuming page-by-page refactor work.

**Replication Monitoring** is the named next page after the baseline lands. It gets refactored against the post-§4 state: Shape B overlays from the start, full spec/populator alignment, no Shape A baggage. The refactor follows the four-file pattern (`ReplicationMonitoring.ps1` + `ReplicationMonitoring-API.ps1` + `replication-monitoring.js` + `replication-monitoring.css`) and aims for zero drift on first populator run.

Subsequent pages follow the same model. Each page refactor becomes a contained per-page exercise rather than a coordinated cross-file effort, because the cross-file infrastructure (shared CSS, shared JS, helpers, populators, specs) is stable.

---

## 6. Deliverables summary

Files delivered this session:

- `CC_PS_Spec.md` — §17 drift table updates
- `Populate-AssetRegistry-PS.ps1` — prefix carve-out, MISPLACED_NONE_PREFIX, EXCESS_BLANK_LINES rewrite, spec reference cleanup
- `xFACts-AssetRegistryFunctions.ps1` — FORBIDDEN_CHANGELOG_IN_HEADER carve-out, spec reference cleanup, new CHANGELOG entry
- `Backup.ps1` — 5 engine card / page-shell drift rows cleared

No new files; all deliverables are full-file replacements of existing files.

# CC Session Summary 23 — BI Page Migration + Tighten-Up Pass

## Session focus

Two threads, both completed:

1. **Business Intelligence page migration** — the departmental BI page brought fully onto the new CC file-format specs + shared-file architecture (CSS, JS, page-route PS1, API PS1).
2. **Tighten-up pass** — resolved a batch of lingering, non-transitional drift on the already-refactored pages and shared files that would otherwise have propagated into every future page migration. Drove the catalog to fully clean except known-transitional drift.

The overarching goal achieved: a trustworthy "if there's a drift code, there's a real issue" baseline, so remaining page refactors proceed with high confidence in the specs and populators rather than fighting catalog noise.

---

## Part 1 — Business Intelligence page migration

Prefix `biz`, component `DeptOps.BusinessIntelligence`, route `/departmental/business-intelligence`. All four files delivered and deployed; page functions correctly.

### Deliverables (all deployed)
- **business-intelligence.css** — compound modifiers eliminated into standalone `biz-` classes; `CONTENT: ERROR DISPLAY` section added using the established `--size-*`/`--color-*`/`--font-*` token family. Populator clean.
- **business-intelligence.js** — full IIFE -> top-level `biz_` rewrite; bootloader-invoked `biz_init`; `biz_clickActions` dispatch; shared calls use real `cc_`-prefixed names; slideout uses the §11.5.3 cc-open rAF/transitionend pattern. Populator clean.
- **BusinessIntelligence-API.ps1** — CBH header, single `ROUTE: API ENDPOINTS` banner, no CHANGELOG, `Test-ActionEndpoint -WebEvent` guard per endpoint; queries/JSON unchanged. Populator clean.
- **BusinessIntelligence.ps1** (page route) — new shell, transitional CCShared import, spec-exact refresh info, chrome banners, tool cards, Notice Recon slideout. Final state: 2 known-transitional drift rows only.

### Post-deployment fixes during the session
- **Chrome unstyled / white H1 symptom** — root cause was the missing transitional `Import-Module xFACts-CCShared.psm1 -Force -DisableNameChecking` as the first statement in the route scriptblock. Without it the route resolved `Get-NavBarHtml`/`Get-PageHeaderHtml` to the still-startup-loaded deprecated `xFACts-Helpers.psm1`, which emits legacy (non-`cc-`) chrome classes that `cc-shared.css` does not style. Added the import (matching the Backup/Replication pattern); chrome rendered correctly. **See carry-forward item 1.**
- **Three real bugs caught by the populator** (not transitional):
  - `MISSING_CONNECTION_BANNER` — banner emitted without its `id`; added `id="cc-connection-banner"`.
  - `ACTION_ON_NON_INTERACTIVE_ELEMENT` — BDL Import tile was a `<div>` carrying `data-action-click`; converted to `<a href="/bdl-import">` and dropped the action + its JS handler/dispatch entry.
  - `MALFORMED_SLIDEOUT_STRUCTURE` — overlay and dialog were siblings; nested the `.cc-dialog` inside the `cc-slide-overlay` per §5.4.4, removed the inner panel `id`, and updated the JS open/close handlers to `overlay.querySelector('.cc-dialog')`. Added a backdrop-click guard so clicks inside the dialog body don't dismiss the panel (the nesting introduced that bubbling path).
  - One follow-on whitespace row (`MALFORMED_PAGE_SHELL_WHITESPACE`) from the banner-id fix; added the required single blank line.
- Final BI route drift: the 2 known-transitional rows (`MISSING_RBAC_CHECK_PAGE`, `MISPLACED_IMPORT`), identical to Backup/Replication.

---

## Part 2 — Tighten-up pass (22 drift rows -> known-transitional only)

Four groups of lingering drift, each resolved at the correct layer.

### Group 1 — Engine-card class naming (10 rows: Backup x8, Replication x2) — RESOLVED
`cc-shared.css` and `cc-shared.js` were the lagging holdouts still using the old `cc-engine-card` / `cc-engine-countdown` names, while the spec, the HTML populator, the emitted HTML, and the element IDs all used `cc-card-engine` / `cc-engine-cd`. The spec was already correct; the two shared files were the stale ones (a deferred realignment that got lost in a prior session).

Decision (after weighing readability vs. consistency): unify on **`cc-card-engine` / `cc-engine-cd`** — the name the IDs, spec, populator, and refactored pages already use. The IDs (`cc-card-engine-{slug}`, `cc-engine-cd-{slug}`) being on that form was the deciding tell.

Files changed: **cc-shared.css** (5 rule renames incl. compound state rules), **cc-shared.js** (className writes at the tick + waiting/started states; the popup click selector `closest('.cc-engine-card')` -> `closest('.cc-card-engine')` — a real behavioral catch, missing it would have silently broken engine-popup clicks; one comment). IDs and ID-lookup logic untouched (already correct).

**Deploy-verify (carry-forward item 2):** load a live engine-card page (Backup or Replication), confirm cards still style with correct state coloring AND clicking a card still opens the detail popup.

### Group 2 — `bkp-*-table-row` unresolved (5 rows in backup.js) — RESOLVED
`bkp-detail-table-row` and `bkp-operation-table-row` were referenced only via `:hover` compound rules in `backup.css`; no bare base-class declaration existed, so the resolver found no `CSS_CLASS DEFINITION` to match the `<tr>` usages emitted by `backup.js`. Added bare `.bkp-detail-table-row { }` and `.bkp-operation-table-row { }` before their `:hover` variants, matching the file's existing bare-class convention (`.bkp-align-right { }`, `.bkp-status-success { }`, etc.). The rows have no base styling of their own, so bare classes are the complete and correct fix. Only **backup.css** changed.

### Group 3 — Access-denied page classes (4 rows in xFACts-CCShared.psm1) — RESOLVED
`Get-AccessDeniedHtml` (the 403 page, primarily a direct-URL-access defense) defines `denied-container`/`denied-icon`/`denied-subtext`/`home-link` inside its permitted inline `<style>` block (the §1.4 carve-out — self-contained so it renders even if `cc-shared.css` fails to load). The classes are used in the same function's markup, but no `CSS_CLASS DEFINITION` rows existed for them (no populator parses `<style>`-block contents), so the resolver stamped them unresolved.

Diagnosis: a **cataloging gap**, not a resolver special case. Fix split cleanly:
- **HTML populator** (`Populate-AssetRegistry-HTML.ps1`): extended the existing `Get-AccessDeniedHtml` `<style>` carve-out to also parse the block's bare class selectors and emit a `CSS_CLASS DEFINITION` row per class — honestly shaped as `file_type='HTML'`, `scope='LOCAL'`, same zone. The carve-out is enforced here (only this one function), so the resolver stays function-agnostic.
- **Resolver** (`Resolve-AssetRegistryReferences.ps1`): added `EdgeHtmlCssClassSelf`, a **resolve-only, same-file** edge (`d.file_name = u.file_name`, `d.file_type='HTML'`), ordered before the general `EdgeHtmlCssClass`. It claims the same-file usages and never stamps, leaving the general edge as the sole owner of `HTML_CSS_CLASS_UNRESOLVED`. Added a null-`StampSql` guard in `Invoke-EdgeResolution` (a reusable "resolve-only edge" capability). Stripped the resolver's BOM and fixed both files' trailing newlines while in them (incidental PS-spec drift).

Verified end-to-end: populator emitted 4 DEFINITION rows, resolver matched the 4 USAGE rows, all resolved to `scope='LOCAL'` with null drift.

**Principle locked (carry-forward item 3):** any *future* inline-`<style>` definition case requires both a populator change (emit the definitions) and a spec change (sanction the exception) — never a resolver-only tweak. The resolver is not a dumping ground for things that should resolve upstream.

### Group 3-banners — `cc-shared.js` chrome-ID references (3 rows) — DIAGNOSED, fix roadmapped (NOT yet implemented)
`cc-shared.js` does `getElementById('cc-connection-banner')` (x2) and `getElementById('cc-page-error-banner')` (x1). These chrome IDs are declared `LOCAL` on each page's shell (mandated by §2.4/§2.5), not in the shared component, so the resolver's `EdgeJsHtmlId` (which matches same-component-or-`ControlCenter.Shared`) can't resolve a shared-file reference to them.

Investigation established this is the surface of a deeper architectural inconsistency: chrome IDs are validated by an **enumerated list** (HTML populator `$ChromeIdExactSet`/`Test-IsChromeId`, spec §5.1) — the lone identity-based exception in an otherwise structural/prefix-based system. The JS populator, by contrast, already validates chrome IDs **structurally** (`Test-HtmlIdMalformed`: any `cc-` ID is well-formed, no list). The two halves of the pipeline disagree, and the JS side is already doing it the right way.

**Decision:** replace the enumerated chrome-ID set with a structural prefix rule platform-wide (a chrome ID is any `cc-`-prefixed id emitted and referenced by platform code; slug-bearing chrome IDs keep their existing `Orchestrator.ProcessRegistry` slug validation). This resolves the 3 banner rows as a natural consequence and eliminates the hand-synced list. **Full file-by-file implementation roadmap written:** `CC_ChromeID_StructuralRule_Roadmap.md`. This is the lead item for next session.

---

## Files changed and delivered this session

| File | Change |
|---|---|
| `business-intelligence.css` | Standalone `biz-` classes; error-display section. New file (BI migration). |
| `business-intelligence.js` | IIFE -> top-level rewrite; dispatch; slideout pattern; banner guard; BDL handler removed. New file (BI migration). |
| `BusinessIntelligence.ps1` | New shell; transitional CCShared import; banner id; BDL anchor; nested slideout; shell whitespace. New file (BI migration). |
| `BusinessIntelligence-API.ps1` | Spec wrapper; behavior-identical. New file (BI migration). |
| `cc-shared.css` | Engine-card rename to `cc-card-engine` / `cc-engine-cd` (5 rules). |
| `cc-shared.js` | Engine-card className writes + popup click selector renamed; comment. |
| `backup.css` | Bare base classes `.bkp-detail-table-row` / `.bkp-operation-table-row`. |
| `Populate-AssetRegistry-HTML.ps1` | Access-denied `<style>` carve-out now emits CSS_CLASS DEFINITION rows; trailing newline added. |
| `Resolve-AssetRegistryReferences.ps1` | New `EdgeHtmlCssClassSelf` resolve-only same-file edge; null-StampSql guard; BOM stripped; trailing newline. |
| `CC_ChromeID_StructuralRule_Roadmap.md` | New design doc for the chrome-ID structural-rule conversion (next-session lead item). |

(JS populator `Populate-AssetRegistry-JS.ps1` was read for the Group 3-banners investigation but needs no change — it already validates structurally.)

---

## Carry-forward items (living knowledge — NOT to be baked into specs/docs)

1. **Transitional Import-Module, per page.** Every page refactored under the Section 11.2.4 migration needs `Import-Module -Name 'E:\xFACts-ControlCenter\scripts\modules\xFACts-CCShared.psm1' -Force -DisableNameChecking` as the FIRST statement in its route scriptblock (with the explaining comment), because `Start-ControlCenter.ps1` still startup-loads the deprecated `xFACts-Helpers.psm1`. Produces 2 accepted drift rows per page (`MISSING_RBAC_CHECK_PAGE`, `MISPLACED_IMPORT`). All of it — the import line on every migrated route AND the drift — clears in one pass when `Start-ControlCenter.ps1` is switched to load `xFACts-CCShared.psm1` at startup and `xFACts-Helpers.psm1` is deleted. Deliberately kept as carry-forward only, not in any spec/doc, to avoid it getting stranded amid course corrections.

2. **Engine-card rename deploy-verify.** Confirm a live engine-card page (Backup/Replication) still styles correctly AND the click-popup still opens (the fix touched a runtime click selector, not just CSS).

3. **Inline-`<style>` definition principle.** Future cases of classes defined in an inline `<style>` block require a populator change + a spec change, never a resolver-only fix. The access-denied page is the only sanctioned case today (§1.4).

---

## Next session — priority sequence

1. **Chrome-ID structural-rule conversion** (lead item). Execute `CC_ChromeID_StructuralRule_Roadmap.md`: settle the two open paper-decisions (drift-code name; resolver R1 vs R2 — R2 leaning), run the full-repo hidden-consumer grep, edit the HTML populator + resolver + HTML spec (JS populator confirmed no-change), re-run, confirm the 3 banner rows clear with no new drift. All three code-side sections are verified; only spec prose remains to author.
2. **Resume page refactors.** With specs and populators trustworthy and the catalog clean except known-transitional drift, proceed to the remaining original-five pages (Client Relations, Business Services) and onward. Build each new route the migrated way from the start (transitional import included).

## State at session end

Catalog is clean except: known-transitional per-page import drift (item 1), and the 3 chrome-ID banner rows (diagnosed, roadmapped, clearing next session as the lead item). This is the trustworthy baseline that signals full-speed-ahead on page refactoring.

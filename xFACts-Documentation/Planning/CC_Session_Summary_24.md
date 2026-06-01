# CC Session Summary 24 — Banner Chrome → Shared Helper + Enumerated Chrome-ID List Elimination

## Session focus

Two related threads, both completed and verified against the live catalog:

1. **Banner chrome moved to a shared helper.** The connection and page-error banners became shared-emitted chrome via a new `Get-ChromeBannersHtml` helper in `xFACts-CCShared.psm1`, resolving the 3 long-standing `cc-shared.js` banner drift rows at their root cause.
2. **Enumerated chrome-ID list eliminated platform-wide.** The hardcoded chrome-ID closed set was removed from the HTML populator and the spec, bringing the HTML side in line with the JS side's already-structural validation.

Both landed clean: pipeline came back green except the known transitional per-page import drift. The end state is the trustworthy "if there's a drift code, there's a real issue" baseline, now extended to banners and chrome IDs.

---

## Part 1 — Banner chrome → shared helper

### The problem (recap)
`cc-shared.js` *references* the banners (`getElementById('cc-connection-banner')` ×2 in `cc_updateConnectionBanner` / `cc_showReloadingBanner`; `getElementById('cc-page-error-banner')` ×1 in `cc_renderPageError`) but does not *create* them. Each page hand-wrote the banner `<div>`s in its own shell, producing N scattered `LOCAL` definitions and no single shared home. The resolver's `EdgeJsHtmlId` (matches same-component or `ControlCenter.Shared`) therefore could not resolve a shared-file reference, leaving 3 `JS_HTML_ID_UNRESOLVED` rows.

### Direction history (important — supersedes prior planning)
- The prior session (23) produced `CC_ChromeID_StructuralRule_Roadmap.md`, which proposed resolving the banners via a resolver trick (structural prefix rule + a resolve-only edge).
- The amended Session 23 summary then **superseded the roadmap for the banners specifically** in favor of the helper approach.
- This session confirmed and executed the helper approach. **All resolver-trick alternatives (match-any-page, chrome-ID list, same-zone, contract sentinel) are abandoned for the banners.** The roadmap doc is disposable scratch and was not rewritten; this summary records the supersession.

### Investigation (read-only, before any code)
The helper approach rested on one unverified assumption: *does the HTML populator parse helper function bodies in `xFACts-CCShared.psm1` and attribute their emitted markup to `ControlCenter.Shared`?* Verified empirically and by reading source:

- **Nav-classes query confirmed the foundation.** `cc-nav-bar` / `cc-nav-link` / `cc-nav-separator` appear as USAGE rows from `xFACts-CCShared.psm1`, `parent_function = Get-NavBarHtml`, `scope = SHARED`, resolving clean (null drift) against `cc-shared.css` definitions. Helper-emitted shared markup IS cataloged as `ControlCenter.Shared`. (This also answered Dirk's standing question "are we capturing nav to the table?" — yes.)
- **Nav is class-only — it emits zero IDs** (confirmed by reading `Get-NavBarHtml` source AND the catalog). Nav is class-driven because nav has *repeating* elements (IDs must be unique); that reasoning does NOT transfer to the banners, which are singular and naturally ID-shaped.
- **`Get-NavBarHtml` uses StringBuilder emission**, which the HTML populator's discovery handles (proven by the catalog). Modeling `Get-ChromeBannersHtml` on it guarantees discovery.

### ID vs. class decision — Path A (keep IDs) chosen
- **Path A (chosen):** helper emits the banners WITH their `id`s; `cc-shared.js` keeps `getElementById`. Resolves via the EXISTING `EdgeJsHtmlId` against `ControlCenter.Shared` definitions. No resolver change, no JS change, no chrome-ID-list change. Banner stays semantically an ID (it's singular).
- **Path B (fallback, not chosen):** emit as a class, switch JS to `querySelector('.cc-connection-banner')`.
- **Precedent check:** queried for any existing JS HTML_ID USAGE resolving against a `ControlCenter.Shared` definition. Found 3 rows in `engine-events.js` (deprecating shared file) resolving clean — but those are SAME-FILE. Path A needed cross-file-same-component (`cc-shared.js` usage → `xFACts-CCShared.psm1` definition, both `ControlCenter.Shared`). Confirmed via reading `EdgeJsHtmlId` that it matches on COMPONENT, not file, so the precedent's mechanism covers Path A's need. Verdict: A is evidence-backed; the cross-file shape was first-of-its-kind but mechanically sound — and the pipeline run then proved it live.

### Banners confirmed as one always-together unit
Read all 3 migrated route shells (BI, Backup, Replication). In all three the two banners are present, adjacent (connection then error, one blank line between), identical bare-empty markup, connection-before-error. Therefore: ONE helper emitting both, ONE `$bannerHtml` substitution, and a SINGLE collapsed spec section is the honest design. (BI has a page-local `biz-nr-error` div immediately after the banners; it stays in the route, untouched.)

### Deliverables (all applied and verified)
1. **`Get-ChromeBannersHtml`** added to `xFACts-CCShared.psm1` (FUNCTIONS: DYNAMIC NAVIGATION section, after `Get-NavBarHtml`; added to alphabetical `Export-ModuleMember`). No params; StringBuilder emission mirroring `Get-NavBarHtml`; emits both banner `<div>`s with their `cc-` id+class and the internal blank line reproduced (rendered HTML byte-for-byte identical to before).
2. **`Populate-AssetRegistry-HTML.ps1`** banner-check rework (see Part 1 populator changes below).
3. **Three route files** (`BusinessIntelligence.ps1`, `Backup.ps1`, `ReplicationMonitoring.ps1`): added `$bannerHtml = Get-ChromeBannersHtml` alongside the other `Get-*Html` declarations; replaced the two literal banner `<div>` lines with the `$bannerHtml` substitution. BI preserved the `biz-nr-error` whitespace boundary.

### Populator changes for the banner work
- Removed the two literal-div banner checks (`MISSING_CONNECTION_BANNER` / `FORBIDDEN_BANNER_CONTENT` / `MISSING_PAGE_ERROR_BANNER` / `FORBIDDEN_PAGE_ERROR_BANNER_CONTENT`) and the dead `PAGE_ERROR_BANNER_ORDER_VIOLATION` (defined but never emitted).
- Added `MISSING_BANNER_SUBSTITUTION` (route missing the `$bannerHtml` token; mirrors `MISSING_NAV_SUBSTITUTION`).
- Added `FORBIDDEN_LITERAL_BANNER` — guard against a route hand-writing a literal banner div instead of using `$bannerHtml`. Scans ALL route files (no legacy accommodation — migration noise is wanted signal). This guard catches the future rogue/uninformed page and subsumes the old emptiness check.
- Added `MISSING_BANNER_HTML_VAR` and the `bannerHtml → Get-ChromeBannersHtml` entry in `Test-RouteVariableAssignments` (mirrors `MISSING_NAV_HTML_VAR`).
- `Test-PageShellOrder`: dropped the two banner-div landmarks; added a single `banner-html` landmark on the `$bannerHtml` token; `$expectedOrder` now `…header-bar, banner-html, shared-script…`.
- `Test-PageShellWhitespace`: pairs reduced from 5 to 4; pair D is now `cc-header-bar → $bannerHtml`; the old connection→error pair E removed (that boundary now lives inside the helper).

### Trust-boundary shift (consciously accepted)
The populator no longer validates banner *markup* per-page (ids, classes, emptiness, ordering). That correctness is now a property of the single `Get-ChromeBannersHtml` helper, guaranteed by construction — exactly the trust boundary nav already relies on (`Get-NavBarHtml` internals aren't per-page validated either).

### Verified result (live catalog)
The 3 `cc-shared.js` banner rows now show `resolved_source_file = xFACts-CCShared.psm1`, `def_component = ControlCenter.Shared`, `drift_codes = NULL`. This is the first cross-file shared-HTML_ID resolution in the catalog, proven working. Page render confirmed normal (no console errors). The helper produces exactly 5 stable catalog rows: 2 × HTML_ID DEFINITION (the resolution targets), 2 × CSS_CLASS USAGE, 1 × PS_DOCBLOCK DEFINITION.

---

## Part 2 — Enumerated chrome-ID list eliminated platform-wide

### The driver
Dirk's standing goal is to get away from enumerated lists and hardcoding entirely. The HTML side validated chrome IDs against a hardcoded closed set (`$ChromeIdExactSet`, `$ChromeIdSlugPrefixes`, `Test-IsChromeId`, spec §5.1 table) — the lone identity-based exception in an otherwise structural system. The JS side already validated structurally (`Test-HtmlIdMalformed`: any `cc-` ID is well-formed, no list). The two halves disagreed; the JS side was already where we wanted to land.

### Verification before editing (no guessing)
- **JS populator** (`Populate-AssetRegistry-JS.ps1`): read `Test-HtmlIdMalformed` — purely structural (character check, then `cc-` prefix → valid, else page prefix). No list. **No change needed.**
- **CSS populator** (`Populate-AssetRegistry-CSS.ps1`): grepped — no chrome-ID enumeration (CSS is classes). **No change needed.**
- **Resolver** (`Resolve-AssetRegistryReferences.ps1`): grepped — no list dependency; and confirmed it positively catches the typo case (`EdgeJsHtmlId` → `JS_HTML_ID_UNRESOLVED`, final `UNRESOLVED_REFERENCE` catch-all). **No change needed.**

### The structural rule (replaces the list)
A chrome ID is any `cc-`-prefixed identifier. Engine-card IDs (`cc-card-engine-<slug>`, `cc-engine-bar-<slug>`, `cc-engine-cd-<slug>`) keep their slug rule — but that is **relational** (validated against `Orchestrator.ProcessRegistry` via the §2.3 `ENGINE_SLUG_REGISTRY_MISMATCH` machinery), not enumerated, so it stays and continues to protect engine cards. Typo protection is preserved without a list: a malformed-character id trips `MALFORMED_ID_VALUE`; a well-formed-but-nonexistent `cc-` id passes the structural check but fails to resolve, so the resolver flags it.

### Populator changes for the list removal
- Deleted `$ChromeIdExactSet` and `$ChromeIdSlugPrefixes`.
- Deleted `Test-IsChromeId` entirely.
- `Get-IdValueDriftCodes`: the `cc-` branch now accepts any well-formed `cc-` id as valid (helper and route/API alike) — mirrors the JS side.
- Removed `CHROME_ID_OUTSIDE_CLOSED_SET`.
- **Renamed `HELPER_EMITS_UNREGISTERED_ID` → `FORBIDDEN_HELPER_NON_CHROME_ID`**, kept as a structural guard: a helper must emit `cc-`-prefixed ids; a non-`cc-` helper id is still flagged (by prefix, not by list). (This resolves prior-session open decision A.)

### Spec changes for the list removal
- §5.1: closed-set table → "A chrome ID is any identifier beginning with `cc-`. Engine-card IDs carry an additional slug rule (§2.3)."
- §4: "set of valid chrome IDs is the closed set in §5.1" → "a chrome ID is any `cc-`-prefixed identifier (§5.1)."
- §11.1: helper-ID rule → "every ID a helper emits is `cc-` prefixed."
- §12 / §15: removed `CHROME_ID_OUTSIDE_CLOSED_SET`; renamed the helper code.

### Behavioral effect
No new drift and no cleared drift from the list removal itself (every existing `cc-` id was already in the list, so `CHROME_ID_OUTSIDE_CLOSED_SET` was firing on nothing). The change is purely "stop enforcing a redundant gate." Future-facing: a new `cc-` chrome id is automatically valid by prefix — no spec amendment to a list required — and is only flagged if it fails to resolve.

---

## Spec amendment (`CC_HTML_Spec.md`) — both threads, one drop-in

- **§2.4 + §2.5 → one §2.4 "Banner chrome"** section describing the `$bannerHtml` substitution from `Get-ChromeBannersHtml` (parallel to §2.1's `$headerHtml` treatment); §2.5 removed; §2 ends at 2.4.
- §1 / §1.2.2 templates + prose: two banner comment lines → one `<!-- banner chrome ($bannerHtml) -->`; body-order prose updated.
- §2 intro chrome list updated.
- §14.1: banner class rows repointed (§2.5 → §2.4); classes retained (still in `cc-shared.css`).
- §5.1 / §4 / §11.1: enumerated-set language replaced with the structural rule.
- §12 / §15: banner codes collapsed to the three new codes; chrome-ID closed-set code removed; helper code renamed.
- The `$bannerHtml` declaration rule lives in §2.4 (matching how `$headerHtml`'s rule lives in §2.1, not §1.1) — deliberate consistency choice, flagged to Dirk.

---

## Files changed and delivered this session

| File | Change |
|---|---|
| `xFACts-CCShared.psm1` | New `Get-ChromeBannersHtml` helper (DYNAMIC NAVIGATION section); added to alphabetical Export-ModuleMember. Applied via in-place insert by Dirk. |
| `Populate-AssetRegistry-HTML.ps1` | Banner checks reworked to `$bannerHtml` substitution model + `FORBIDDEN_LITERAL_BANNER` guard; enumerated chrome-ID list machinery deleted; `Test-IsChromeId` removed; `HELPER_EMITS_UNREGISTERED_ID` → `FORBIDDEN_HELPER_NON_CHROME_ID`. Full drop-in. |
| `BusinessIntelligence.ps1` | `$bannerHtml = Get-ChromeBannersHtml` added; literal banner divs → `$bannerHtml`; `biz-nr-error` boundary preserved. Applied in-place by Dirk. |
| `Backup.ps1` | Same banner substitution. Applied in-place by Dirk. |
| `ReplicationMonitoring.ps1` | Same banner substitution. Applied in-place by Dirk. |
| `CC_HTML_Spec.md` | Banner collapse (§2.4/§2.5 → §2.4) + enumerated-list removal (§5.1, §4, §11.1, §12, §15). Full drop-in. |

**Confirmed NO change needed:** `Populate-AssetRegistry-JS.ps1` (already structural), `Populate-AssetRegistry-CSS.ps1` (classes, no chrome-ID list), `Resolve-AssetRegistryReferences.ps1` (no list dependency; it is the typo safety net).

---

## Diagnosed and dismissed: catalog row-count fluctuation

Total catalog rows (not drift) moved across runs: HTML 4426→4414 (−12) after the helper; PS 17617→17620 (+3) after the helper; PS 17620→17617 (−3) after the enum removal; HTML unchanged at 4414; CSS and JS unchanged throughout. All benign and expected:
- HTML −12 = the 3 routes × 4 banner rows each (2 ids + 2 classes) leaving the route files.
- PS gain = the banner chrome relocating into the helper, now cataloged once instead of three times (net platform-wide row count went DOWN — quantitative proof duplication was eliminated).
- The +3/−3 PS wobble was the catalog re-parsing and settling across runs. Confirmed final state via query: the helper produces exactly 5 stable, correct rows (2 HTML_ID DEFINITION, 2 CSS_CLASS USAGE, 1 PS_DOCBLOCK DEFINITION). Nothing lost or double-counted.

---

## Carry-forward items (living knowledge — NOT baked into specs/docs)

1. **Transitional per-page Import-Module shim** (unchanged from prior sessions). Every migrated route has `Import-Module ... xFACts-CCShared.psm1 -Force -DisableNameChecking` as the first statement in its scriptblock, producing 2 accepted drift rows per page (`MISSING_RBAC_CHECK_PAGE`, `MISPLACED_IMPORT`). All of it clears in one pass when `Start-ControlCenter.ps1` switches to load `xFACts-CCShared.psm1` at startup and `xFACts-Helpers.psm1` is deleted. This is the "known unresolvable temporary drift" referenced this session.

2. **Catalog-completeness coverage check (backlog item, surfaced this session).** The HTML populator discovers emitted HTML via three patterns only (here-strings, StringBuilder chains, single string-literal returns) passing `Test-LooksLikeHtmlEmission`. HTML assembled by string concatenation with `+`, or otherwise not tripping the sniff, is SILENTLY skipped. A clean catalog does not prove completeness. Proposed future check: flag helper functions whose bodies contain HTML markers (`<div`, `class=`, `id=`) but produced zero catalog rows. Separate from any current work; medium value.

3. **Chrome-ID structural rule — now fully realized for IDs.** The enumerated list is gone platform-wide; HTML and JS sides are aligned (structural). The original roadmap's broader scope is effectively complete for chrome IDs. `CC_ChromeID_StructuralRule_Roadmap.md` is fully superseded and can be deleted as disposable scratch.

---

## State at session end

Catalog is clean except the known transitional per-page import drift (carry-forward 1). Banners resolve via shared attribution; the enumerated chrome-ID list is eliminated; HTML/JS/CSS populators and the resolver are mutually consistent; the spec matches enforced reality. Trustworthy baseline intact and extended.

## Next session — priority

**Resume page refactoring in full.** With banners, chrome-ID validation, the specs, and the populators all trustworthy and the catalog clean except known-transitional drift, proceed to the remaining original-five pages (Client Relations, Business Services next) and onward, building each new route the migrated way from the start (transitional import included; banners via `$bannerHtml = Get-ChromeBannersHtml`).

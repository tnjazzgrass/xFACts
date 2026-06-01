# Chrome-ID Structural-Rule Conversion — Implementation Roadmap

**Status:** Design locked, implementation pending. Written end of Session 23 for immediate pickup next session.
**Scope:** Replace the enumerated chrome-ID set with a structural prefix rule. Three artifacts change: the HTML populator, the resolver, and the HTML spec. The JS populator already implements the structural rule (verified Session 23) and needs no change — it is the corroborating precedent.
**Not blocking:** Page refactors can proceed without this. Doing it first means future pages and the remaining drift land cleanly with no chrome-ID carve-outs.

---

## 1. The decision, in one paragraph

Today a "chrome ID" is recognized by membership in a hard-coded list (`cc-last-update`, `cc-connection-banner`, `cc-page-error-banner`, plus three slug-prefixes). That list lives in at least two places (HTML spec section 5.1 and the HTML populator's `$ChromeIdExactSet` / `$ChromeIdSlugPrefixes`), is hand-synced, and is the one place in the whole prefix system that validates by *identity* (specific names) instead of by *structure* (prefix + ownership) like every other identifier rule. We are replacing the enumerated set with a structural rule: **a chrome ID is any `id` that begins with `cc-`, emitted by platform-owned code (chrome JS/CSS or a helper module) and referenced by platform-owned code.** Slug-bearing chrome IDs (engine cards) keep their existing data-driven slug validation against `Orchestrator.ProcessRegistry` — that check never depended on the enumerated list. Typo protection does not disappear; it moves from "populator knows the spelling" to "resolver catches a shared-JS reference that resolves to no page-provided element," which validates the actual relationship rather than a spelling dictionary.

This also resolves, as a natural consequence, the three `cc-shared.js` `JS_HTML_ID_UNRESOLVED` rows (`cc-connection-banner` x2, `cc-page-error-banner` x1) that motivated the investigation — without any banner-specific special case.

---

## 2. Why the structural rule is correct (rationale to preserve)

- **Consistency with the rest of the system.** Every other prefix rule is structural: page-owned ID = "starts with the page's `cc_prefix-`"; platform class = "starts with `cc-`"; page class = "starts with `cc_prefix-`". Chrome IDs are the lone exception that enumerates members. The redesign makes IDs obey the same pattern-based discipline as everything else.
- **No hand-maintained roster.** The enumerated set must be kept in agreement across spec + populator (+ resolver if extended). A prefix rule has nothing to sync.
- **Typo detection improves, not regresses.** With the list, `cc-conection-banner` (misspelled) is caught as "not in set." With the structural rule it is a structurally valid chrome ID that simply never resolves — the resolver flags the shared-JS reference to `cc-connection-banner` because no page provides that element. The cross-reference is the integrity check, which is the catalog's core philosophy.
- **Engine-card slugs already data-driven.** `ENGINE_SLUG_REGISTRY_MISMATCH` cross-references the card slug against `Orchestrator.ProcessRegistry` independently of the enumerated list (HTML populator ~line 5409). It survives unchanged.

---

## 3. The structural rule, stated precisely (the new contract)

An `id` attribute value is one of exactly three things:

1. **Page-local ID** — begins with the page's `cc_prefix` + `-`. (Unchanged.)
2. **Chrome ID** — begins with `cc-`. Valid when emitted by platform-owned code (a helper module function, or a page route emitting a mandated chrome element) and referenced by platform-owned code (`cc-shared.js` / `cc-shared.css`). No name list.
   - **Slug-bearing chrome IDs** (`cc-card-engine-<slug>`, `cc-engine-bar-<slug>`, `cc-engine-cd-<slug>`): the `cc-` prefix makes them chrome; the `<slug>` portion is validated against `Orchestrator.ProcessRegistry` by the existing engine-card cross-reference check. (Behavior preserved, now the *only* slug rule rather than a list entry.)
3. **Malformed** — anything that is neither (character-set violations still fire `MALFORMED_ID_VALUE`; a non-`cc-`, non-page-prefixed ID still fires `MISSING_PREFIX_ID`; another page's prefix still fires `CROSS_PAGE_PREFIX_COLLISION`).

Character-set validation (`^[a-z][a-z0-9\-]*$` -> `MALFORMED_ID_VALUE`) is independent of all the above and stays.

---

## 4. File-by-file changes

> Confidence key: **[VERIFIED]** = read in full this session, before/after is exact. **[CONFIRM]** = must read the real file next session before editing; intent is firm, exact lines to be filled in.

### 4.1 HTML populator — `Populate-AssetRegistry-HTML.ps1` **[VERIFIED]**

**REMOVE:**
- The constant `$ChromeIdExactSet = @('cc-last-update','cc-connection-banner','cc-page-error-banner')` (around line 243) and its comment block.
- The constant `$ChromeIdSlugPrefixes = @('cc-card-engine-','cc-engine-bar-','cc-engine-cd-')` (around line 251) and its comment block.
  - NOTE: keep the *concept* of slug-bearing IDs in mind — see "KEEP" below. The slug-prefix list itself is removed *only if* nothing other than `Test-IsChromeId` consumes it. Confirm `$ChromeIdSlugPrefixes` has no other consumer before deleting (grep showed only `Test-IsChromeId` references it — verify again after edits).
- The function `Test-IsChromeId` (around lines 1733–1743) in its entirety.

**CHANGE — `Get-IdValueDriftCodes` (around lines 1746–1810):** This is the heart of the change. Current logic for a `cc-`-prefixed ID calls `Test-IsChromeId` and fires `HELPER_EMITS_UNREGISTERED_ID` (helper emission) or `CHROME_ID_OUTSIDE_CLOSED_SET` (route emission) when the ID is not in the enumerated set. New logic:

- A `cc-`-prefixed ID is, by structure, a chrome ID. It is valid by virtue of its prefix.
  - **Helper emission of a `cc-` ID:** valid, no drift. (Platform code emitting platform chrome is definitionally fine.) The current `HELPER_EMITS_UNREGISTERED_ID` branch for `cc-`-prefixed helper IDs is deleted.
  - **Route emission of a `cc-` ID:** valid, no drift. The current `CHROME_ID_OUTSIDE_CLOSED_SET` branch is deleted. (A page emitting a mandated chrome placeholder such as `cc-connection-banner` is correct per section 2.4/2.5; a page inventing a random `cc-` ID is constrained by the fact that page-owned IDs must use the page prefix — and if a page emits a `cc-` ID that no shared code references, the resolver simply never links it, which is the desired "unused/typo" signal.)
- The non-`cc-` branches are UNCHANGED:
  - Helper emitting a page-prefixed ID -> `FORBIDDEN_HELPER_PAGE_PREFIX_ID` (keep).
  - Helper emitting a non-`cc-`, non-page-prefixed ID -> currently `HELPER_EMITS_UNREGISTERED_ID`. **DECISION NEEDED (section 6, item A):** this code name is shared with the now-deleted `cc-` case. Either rename this to something like `HELPER_EMITS_NON_CHROME_ID` or keep `HELPER_EMITS_UNREGISTERED_ID` with a description rewrite. The *behavior* (helper must emit `cc-` chrome IDs only) is retained; only the trigger logic and possibly the code name change.
  - Page-local emission: `MISSING_PREFIX_ID` / `CROSS_PAGE_PREFIX_COLLISION` (keep exactly).
- Keep the `MALFORMED_ID_VALUE` character-set check at the top (unchanged).

**KEEP (do not touch):**
- The engine-card slug cross-reference at ~line 5409 (`ENGINE_SLUG_REGISTRY_MISMATCH`) — independent of the enumerated set, validates slug against `Orchestrator.ProcessRegistry`. This is now the sole mechanism that constrains slug-bearing chrome IDs, which is correct.
- `$script:knownPagePrefixes` machinery and the page-local prefix logic.

**DRIFT-CODE DESCRIPTIONS (around lines 319/336/352):**
- `CHROME_ID_OUTSIDE_CLOSED_SET` (line 336): **REMOVE** — no longer emitted. Confirm no other emission site (grep showed only the one in `Get-IdValueDriftCodes`).
- `HELPER_EMITS_UNREGISTERED_ID` (line 352): **REVISE or RENAME** per the decision in section 6 item A. If the non-`cc-` helper case is renamed, update accordingly; if kept, rewrite the description to "A helper module function emits an ID that is neither a `cc-` chrome ID nor permitted" (or similar).
- `ENGINE_SLUG_REGISTRY_MISMATCH` (line 319): **KEEP** unchanged.

### 4.2 Resolver — `Resolve-AssetRegistryReferences.ps1` **[VERIFIED]**

**The problem today:** `EdgeJsHtmlId` resolves a JS `HTML_ID` USAGE against an `HTML_ID` DEFINITION where `obj_d.component_name = obj_u.component_name OR obj_d.component_name = 'ControlCenter.Shared'`. `cc-shared.js`'s own component is `ControlCenter.Shared`, so it only finds IDs defined in shared. The banner IDs are defined `LOCAL` on each page, so they don't match -> `JS_HTML_ID_UNRESOLVED`.

**The structural fix:** a JS `HTML_ID` USAGE whose component_name begins with `cc-` is a chrome-ID reference. Chrome IDs are guaranteed to be provided by pages (mandated chrome) or by helpers. So a `cc-`-prefixed `HTML_ID` USAGE from `cc-shared.js` should resolve whenever *any* page in the same zone declares that exact chrome ID as a DEFINITION.

**Two candidate mechanisms (DECISION NEEDED, section 6 item B):**

- **Option R1 — widen `EdgeJsHtmlId` matching for `cc-` IDs.** Add an alternative match path: when `u.component_name LIKE 'cc-%'`, match a DEFINITION of the same `component_name` and `zone` in *any* component (drop the same-component/shared restriction for chrome IDs only). This keeps it one edge. Risk: "any component" is broad; constrain to "any HTML-origin DEFINITION in the same zone" so it can't match cross-zone or odd file types.
- **Option R2 — a dedicated chrome-ID resolution edge** (parallel to the same-file `EdgeHtmlCssClassSelf` we added this session): a resolve-only edge that runs before `EdgeJsHtmlId`, claims `cc-`-prefixed JS HTML_ID usages by matching any same-zone page DEFINITION, and never stamps — leaving `EdgeJsHtmlId` as the sole stamp owner for non-chrome JS HTML_ID usages. Mirrors the pattern we just validated and keeps the general edge untouched. **Tentative preference: R2** — it is the established pattern (resolve-only edge, ordered first, no stamp), keeps each edge's rule precise, and avoids loosening the general edge's scoping for everyone.

**Either way:** no enumerated list in the resolver. The match is structural (`cc-%` prefix) + relational (a page actually declares it). A misspelled chrome reference in shared JS resolves to nothing and correctly stamps — typo protection preserved at the relationship level.

**Reuse from this session:** the `Invoke-EdgeResolution` null-`StampSql` guard added in Session 23 already supports a resolve-only edge, so R2 needs no runner change.

### 4.3 JS populator — `Populate-AssetRegistry-JS.ps1` **[VERIFIED — read in full Session 23]**

**Finding: the JS populator already implements the structural rule and needs NO chrome-ID change.** It has no enumerated chrome-ID set and no `Test-IsChromeId`. Its sole ID-validation helper, `Test-HtmlIdMalformed` (~line 1227), is purely structural:

```
if ($IdName -cnotmatch '^[a-z0-9-]+$') { return $true }   # character set
if ($IdName.StartsWith('cc-'))         { return $false }   # ANY cc- ID is well-formed -- no list
# otherwise must start with the page's registered prefix + '-'
```

So the JS side has *always* treated "chrome ID" as "starts with `cc-`" — exactly the structural rule this roadmap adopts platform-wide. The two halves of the pipeline currently disagree: the HTML populator enumerates chrome IDs by name; the JS populator validates by prefix. **The conversion makes the HTML populator and spec match what the JS populator already does** — strong corroboration that the structural rule is the correct primitive.

ID-row emission (`Add-JsHtmlIdRow`, ~line 1589): DEFINITION rows -> `scope='LOCAL'`, `source_file=current JS file`; USAGE rows (e.g. `getElementById('cc-connection-banner')` from `cc-shared.js`) -> `scope='<pending>'`, deferred to the resolver. `JS_HTML_ID_MALFORMED` does NOT fire on `cc-`-prefixed usages (they are well-formed by prefix), so the banner usages emit clean-and-pending exactly as needed. The resolver (section 4.2) is the sole place the banner rows currently fail and the sole place they get fixed.

**Action for this file: none for chrome-ID logic.** (Optional hygiene only if separately desired — its encoding came in clean: no BOM, ASCII, CRLF, so nothing to normalize.) Do NOT edit this file as part of the conversion; just confirm at re-run that its `HTML_ID USAGE` rows for the banners still emit `<pending>` and resolve via the resolver change.

### 4.4 HTML spec — `CC_HTML_Spec.md` **[CONFIRM — exact wording next session]**

- **Section 5.1 (Chrome IDs):** replace the closed-set table with the structural rule from section 3 of this doc. State that a chrome ID is any `cc-`-prefixed `id` emitted and referenced by platform code; that slug-bearing chrome IDs validate their slug against `Orchestrator.ProcessRegistry`; and that "adding a chrome ID" is no longer a spec amendment — it is simply emitting a `cc-`-prefixed id from platform code. Keep the three current IDs as *examples*, not as an exhaustive registry.
- **Section 11.1 (Helper-emitted HTML):** the rule "Every ID a helper emits is a chrome ID from the closed set in section 5.1" becomes "Every ID a helper emits is a `cc-`-prefixed chrome ID" (structural, no closed set).
- **Section 4 prefix discipline:** the line "The set of valid chrome IDs is the closed set in section 5.1 ... Adding a new platform identifier requires a spec amendment" — revise the chrome-ID portion to the structural rule. (The `data-cc-*` closed set in 14.4 and chrome action set are SEPARATE decisions and are NOT in scope here — do not touch them.)
- **Section 12 (Forbidden patterns):** the rows "Chrome ID outside the closed set in section 5.1" and "Helper emitting an ID not in the section 5.1 chrome ID closed set" — revise to reflect the structural rule (a helper emitting a non-`cc-` ID is the violation; a page emitting a `cc-` ID is fine).

**Constitutional note:** this is a deliberate amendment to an authoritative spec, reasoned from first principles (structural validation is the system's consistent primitive; the enumerated set was the lone identity-based exception). Record it as such in the next session summary.

---

## 5. Expected drift outcome after implementation

- The 3 `cc-shared.js` rows (`cc-connection-banner` x2, `cc-page-error-banner` x1) resolve and clear — as a consequence of the resolver change, not a special case.
- No new drift introduced on the three refactored pages (BI, Backup, Replication): their `cc-` banner IDs were already correct; they simply stop being validated against a list and start being validated structurally.
- `ENGINE_SLUG_REGISTRY_MISMATCH` behavior unchanged (still the slug guard).
- Net: catalog reaches fully clean except the known transitional import drift (the per-page `Import-Module xFACts-CCShared.psm1` shim + its `MISSING_RBAC_CHECK_PAGE` companion), which is separate and clears when `Start-ControlCenter.ps1` flips to CCShared platform-wide.

---

## 6. Open decisions to settle at the start of next session

**A. `HELPER_EMITS_UNREGISTERED_ID` fate.** The non-`cc-` helper-emission case still needs a drift code (a helper must emit `cc-` chrome IDs, so a non-`cc-` helper ID is drift). Decide: rename to `HELPER_EMITS_NON_CHROME_ID` (clearer under the new model) vs. keep the name with a revised description. Cheap either way; pick for clarity.

**B. Resolver mechanism R1 vs R2.** Widen `EdgeJsHtmlId` for `cc-` IDs (R1) vs. add a resolve-only chrome-ID edge ordered first (R2). Tentative preference R2 (matches the same-file edge pattern from this session, keeps the general edge's scoping intact, reuses the null-StampSql guard). Confirm after re-reading `EdgeJsHtmlId`.

**C. JS populator scope. RESOLVED (Session 23): no change needed.** The JS populator already validates IDs structurally (`Test-HtmlIdMalformed`: any `cc-` ID is well-formed, no enumerated set). It emits banner usages as `<pending>` HTML_ID USAGE rows that defer to the resolver. The conversion makes the HTML populator and spec match the JS populator's existing behavior. See section 4.3.

**D. Does anything else consume the enumerated set?** Partial answer established in Session 23: across the files on hand (HTML populator, CSS populator, resolver), all 14 chrome-ID-machinery references (`ChromeIdExactSet`, `ChromeIdSlugPrefixes`, `Test-IsChromeId`, `CHROME_ID_OUTSIDE_CLOSED_SET`, `HELPER_EMITS_UNREGISTERED_ID`) are in the HTML populator ONLY; the CSS populator and resolver have zero. The resolver carries no literal banner IDs either. Still to check next session: the JS populator (not on hand — see C), and a full-repo grep for any docs/tooling that hard-codes the three IDs as literals before deleting `$ChromeIdExactSet`.

---

## 7. Suggested execution order next session

1. Settle decisions A and B on paper (5 minutes). (C and D-JS are resolved; D still needs the full-repo literal-ID grep.)
2. Full-repo grep for hidden consumers of the enumerated set (decision D): `ChromeIdExactSet`, `ChromeIdSlugPrefixes`, `Test-IsChromeId`, `CHROME_ID_OUTSIDE_CLOSED_SET`, and the three IDs as literals — across docs/tooling not seen this session. (Files on hand already confirmed clean: machinery is HTML-populator-only.)
3. HTML populator edits (section 4.1) — verified, the substantive code change.
4. Resolver edit (section 4.2) — chosen mechanism (R1/R2 per decision B).
5. JS populator — NO change (section 4.3); confirmed already structural.
6. HTML spec amendments (section 4.4).
7. Re-run all four populators + resolver; confirm the 3 banner rows clear, no new drift, engine cards still validate, and JS `HTML_ID` banner usages still emit pending-then-resolved.
8. Record the amendment and rationale in the session summary.

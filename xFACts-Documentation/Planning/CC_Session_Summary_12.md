# CC Session Summary 12 — PS Populator Wrap-Up; Shared Helper Performance Pass; PS Spec Cleanup

**Date:** 2026-05-25
**Focus:** Closed out all remaining PS populator work (subsection-marker handling, cross-file Pass 3 checks). Landed two shared-helper performance changes that also benefit the JS populator. Tightened the PS spec on banner shape (interior bare-content rule + inline `<#`/`#>` delimiters matching CSS/JS), added §13.2 for sub-section markers, and renamed the corresponding drift code from `FORBIDDEN_*` to `MALFORMED_*` to reflect the new permitted-but-strict stance.

**Disposition:** PS populator complete. Spec, shared helper, and populator all internally consistent and aligned. Final test run inserted 17,342 rows into `dbo.Asset_Registry`. Next session opens on the JS populator only — the remaining items from earlier carry-over lists (B1 FILE_HEADER phantom fix, B4 visitor scriptblock → function, B5 batch Node subprocess) are the entire remaining populator-completion scope.

---

## Files delivered

| File | Path | Net change |
|---|---|---|
| `CC_PS_Spec.md` | `xFACts-Documentation/Planning/` | +16 lines (575 → 591) |
| `xFACts-AssetRegistryFunctions.ps1` | `xFACts-PowerShell/` | +42 lines (2148 → 2190) |
| `Populate-AssetRegistry-PS.ps1` | `xFACts-PowerShell/` | +152 lines (3542 → 3694) |

All three were applied as surgical edits against the actual current files (uploaded by Dirk at session start where applicable; fetched via cache-busted manifest URL otherwise) and verified by line-count delta against expectation before delivery.

---

## 1. Shared helper performance pass (xFACts-AssetRegistryFunctions.ps1)

Three changes from the JS populator performance investigation doc landed in the shared helper. All three benefit both the JS and CSS populators since both call into this library. No drift output changes — pure correctness-preserving performance work.

### Change 1: `Get-SectionForLine` — linear scan → binary search

The function is called once per row emission in Pass 2 of every populator. JS files emit ~10K rows each, so per-file lookup cost matters. The old implementation walked the section list linearly; the new implementation uses a binary search over the section list (already sorted by banner start line by `New-SectionList`). Drops per-lookup cost from O(N) to O(log N).

### Change 2: `Invoke-AstWalk` — `PSObject.Properties.Name -contains 'type'` → `$null -ne $Node.type`

Hot-path optimization in the generic AST walker. Every node visit checked for a `.type` property via PSObject property-name enumeration, which is materially slower than a direct null check on the property. Same semantics on well-formed JS/CSS AST nodes (every node has `.type`). Walker is called ~10-15K times per JS file.

### Change 3: `Invoke-AstWalk` — `-Visitor` parameter accepts a function name (string) in addition to a scriptblock

PowerShell scriptblock dispatch is substantially slower than function-call dispatch. The parameter type was loosened from `[scriptblock]` to untyped; PowerShell's `&` call operator handles both forms identically, so no change at the call site. Existing scriptblock callers continue to work; future callers that switch to function-name dispatch get faster invocation on the hot path. **This change is currently latent — no caller in the codebase yet passes a function name.** Activating it is part of the next session's B4 work (convert `$JsVisitor` scriptblock to `Invoke-JsVisitor` function on the JS populator side, plus the equivalent for CSS).

### Performance expectation

The investigation doc projected these three changes (plus the deferred B4) close 80-90% of the JS populator's per-file walk-time gap. Changes 1 and 2 alone are projected at 60-70%. Real-world measurement not yet collected for the JS populator at the new helper version; the PS populator run reported in this session ran in ~54 seconds for 85 files (3500-line populator scanning files totaling tens of thousands of source lines), which is comfortably within target range and not the gating bottleneck.

---

## 2. PS spec changes (CC_PS_Spec.md)

Five surgical edits, no rule-level rewrites.

### §3 Section banners — inline `<#` / `#>` delimiters

Banner shape now matches CSS/JS visual convention with the delimiters inline with the opening and closing rule:

```
<# ============================================================================
   <TYPE>: <NAME>
   ----------------------------------------------------------------------------
   <Description: 1 to 5 sentences explaining what the section contains.>
   Prefix: <prefix>
   ============================================================================ #>
```

Previously the `<#` and `#>` sat on their own lines and the interior content varied between bare and `# `-prefixed shapes across the codebase. The new shape:

- Line 1: `<#`, one space, exactly 76 `=` characters
- Closing line: three spaces, exactly 76 `=` characters, one space, `#>`
- Interior lines (title, separator, description, Prefix) indented three spaces with no `#` prefix
- File headers and function docblocks retain the standard PowerShell comment-based-help shape — `Get-Help` compatibility was the deciding factor against converting those.

No new drift codes — the existing `BANNER_INVALID_RULE_CHAR`, `BANNER_INVALID_RULE_LENGTH`, `BANNER_INVALID_SEPARATOR_CHAR`, `BANNER_INVALID_SEPARATOR_LENGTH`, and `BANNER_MALFORMED_TITLE_LINE` already cover violations of the new shape once the populator's validators see the bare interior content. Helper-side validators were verified to already strip the `<#` / `#>` delimiters and per-line leading whitespace before validation, so the shape change required no populator code change.

### §13 Comments — fifth recognized form

Sub-section markers are now a permitted comment form, mirroring the CSS and JS specs. Five recognized comment forms: file header, section banners, function docblocks, `#` line comments, and sub-section markers.

### New §13.2 Sub-section markers

Defines the strict shape and the surrounding-blank-line rules:

- Shape: `# -- <Label> --` — exactly two dashes either side, single space delimiters, label contains at least one letter
- Standalone single line — not part of a multi-line `#` comment run
- Preceded by at least one blank line (the banner-closing blank satisfies this transitively when the marker is the first content after a banner)
- Followed by at least one blank line
- Sub-section markers do not appear in the FILE ORGANIZATION list and do not nest

Banner-vs-marker authoring guidance included: new banner for distinct concepts (gets its own FILE ORGANIZATION entry); marker for visual grouping of related items within a section.

### §13.1 — sub-section markers removed from forbidden list

Sub-section markers were previously listed as forbidden. Removed from the §13.1 forbidden-patterns enumeration since they're now permitted under the §13.2 rules.

### §16 forbidden patterns table — sub-section marker row removed

The "Sub-section marker comment | §13.1" row removed from the §16 table for the same reason.

### §17 drift code reference — `FORBIDDEN_SUBSECTION_MARKER` → `MALFORMED_SUBSECTION_MARKER`

Code renamed and description rewritten to reflect that the drift fires only on shape violations or surrounding-context violations, not on the presence of a sub-section marker.

### Editorial — bloat removal

Several rule statements that carried "is drift" framing or runtime-behavior rationale were tightened to plain rule statements per Dirk's mid-session feedback that the spec contains rules only, never explanatory commentary on what constitutes drift (§17 is the contract for drift; the body sections state rules). Affected sections: §1, §3.2, §8.1, §12.2, §13.1, §14.1, §15.1, §16.1. No rule meanings changed.

---

## 3. PS populator changes (Populate-AssetRegistry-PS.ps1)

Three feature additions plus an audit-driven scope-collision fix.

### A1 — Sub-section marker detection (Pass F comment-pass)

The leading-comment dispatch loop was restructured into two passes:

**First pass: marker extraction.** Walks the leading-comment array and identifies marker-shaped entries before the run-grouping logic decides what to do with consecutive `#` lines. Strict match regex `^--\s\S(.*?\S)?\s--$` plus a letter-content check. An "almost-marker" regex `^-{2,}.*-{2,}$` catches authoring attempts with wrong dash counts, missing spaces, or other shape violations. Both strict-shape and almost-shape entries get extracted from the run pool and emitted as standalone `PS_INLINE_BANNER` rows with `-Style 'subsection-marker'`. Drift attribution per spec §13.2:

- Almost-shape (didn't pass strict regex) → `MALFORMED_SUBSECTION_MARKER` with reason "comment uses sub-section marker shape but does not match the strict '# -- <Label> --' form"
- Adjacent `#` comment on previous line → `MALFORMED_SUBSECTION_MARKER` with reason "marker is preceded by a '#' comment on the immediately previous line"
- Adjacent `#` comment on next line → `MALFORMED_SUBSECTION_MARKER` with reason "marker is followed by a '#' comment on the immediately next line"
- Previous source line is non-blank → `MALFORMED_SUBSECTION_MARKER` with reason "marker is not preceded by a blank line"
- Next source line is non-blank → `MALFORMED_SUBSECTION_MARKER` with reason "marker is not followed by a blank line"

Multiple reasons accumulate into a single drift-code attachment with all reasons joined into the context message.

**Second pass: standard run-grouping.** The non-marker remaining entries proceed through the existing single-line / multi-line / ASCII-divider / box-drawing / removed-code dispatch unchanged.

Per spec §13.2 the key correctness guarantee is that a marker-shaped line cannot be silently absorbed into a multi-line `#` comment run. This restructure ensures markers always get their own `PS_INLINE_BANNER` row regardless of context — well-formed markers emit no drift; everything else fires `MALFORMED_SUBSECTION_MARKER`.

`Add-PSInlineBannerRow`'s `'subsection-marker'` switch case was also updated to stop firing the old `FORBIDDEN_SUBSECTION_MARKER` drift unconditionally; the caller now handles drift attribution.

The master `$DriftDescriptions` table was updated: `FORBIDDEN_SUBSECTION_MARKER` renamed to `MALFORMED_SUBSECTION_MARKER` with new description.

### A3 — `ORPHAN_FUNCTION_CALL` (Add-PSFunctionCallRow modification)

Added a new branch to `Add-PSFunctionCallRow`'s scope-resolution cascade. The function previously returned `$null` for any call name that didn't resolve to either a shared-library function or a current-file local function — meaning external module calls, built-in cmdlets, and orphan xFACts-shaped calls all looked identical (no row emitted). The new branch catches xFACts-shaped names (`Verb-prefix_Noun` per spec §8.1) that don't resolve to any cataloged definition:

```
elseif ($fnName -cmatch '^[A-Z][a-zA-Z]+-[a-z][a-z0-9]*_[A-Za-z]') {
    $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }
    $sourceFile = $null
    $isOrphan = $true
}
```

When the match hits, the row gets emitted with the file's natural scope (no new `ORPHAN` scope value introduced, to keep any DDL CHECK constraints intact) and `ORPHAN_FUNCTION_CALL` drift attached. Bare-Verb-Noun uncataloged calls (e.g., `Get-ADUser`, `Where-Object`, `Invoke-Sqlcmd`) continue to silently skip — they're indistinguishable from external-module / built-in calls by name shape alone, and the spec's bucket-3 dependencies (Pode routes, SQL queries, exports, imports) already have dedicated row types covering the meaningful ones.

### A3 — `DUPLICATE_FUNCTION_DEFINITION` (Pass 3 cross-file scan)

Added immediately after the existing `SHADOWS_SHARED_FUNCTION` block in Pass 3. Groups all `PS_FUNCTION` / `PS_FUNCTION_VARIANT` DEFINITION rows by component name; any group spanning two or more distinct files gets `DUPLICATE_FUNCTION_DEFINITION` drift attached to every row in the group, with context naming the other files involved.

### Mid-session bug: `$rows` variable name clobbered `$script:rows`

First test run produced "Total rows generated: 1" despite Pass 2 generating ~21K rows. Root cause: the new `DUPLICATE_FUNCTION_DEFINITION` block used `$rows = $functionDefsByName[$fnName]` inside a foreach loop body at script scope. PowerShell treats bare assignments at script scope as writes to the script-scope variable, so `$rows = ...` clobbered `$script:rows` (the master row collection the bulk inserter reads from). By the end of Pass 3, `$script:rows` held only the last group's row list — one row.

Fixed by renaming the loop-local variables to `$defRows` and `$defRow`. Re-run inserted 17,342 rows, which is the expected magnitude.

This is a known sharp edge in PowerShell scope semantics — variables used as foreach iterators are loop-local, but bare assignments inside the loop body are not. The lesson is to be extra-careful with variable naming when the surrounding script scope already uses `$rows` (or any other common name) for something operationally critical.

---

## 4. Test run results

| Run | Total rows | Notes |
|---|---|---|
| First attempt (after all changes) | 1 (catastrophic) | `$rows` scope clobber bug — fixed in delivery |
| Second attempt (after fix) | 17,342 | Back in expected range; Pass 3 cross-file checks operational |

Per-file Pass 2 totals from the run log show the distribution is healthy — standalone scripts emit a few hundred rows each, the larger CC modules and shared libraries emit several hundred each, page-route files emit ~15 each, api-route files vary from a dozen to several hundred depending on endpoint count. Nothing collapsed and nothing exploded — proportions look right.

Component_Registry rows loaded: 88 prefix entries, 33 distinct component names. Object_Registry rows loaded: 88 — matches the prefix count, so every cataloged file should resolve its FK. No miss report at the end of the run.

---

## 5. PS populator status

**Complete.** All deferred work from prior sessions has landed:

- ✅ FILE_HEADER phantom-row fix (Session 11)
- ✅ Bare-content banner rule + inline `<#`/`#>` envelope shape (this session)
- ✅ Sub-section marker detection with strict shape + blank-line rules (this session)
- ✅ `DUPLICATE_FUNCTION_DEFINITION` cross-file Pass 3 check (this session)
- ✅ `ORPHAN_FUNCTION_CALL` xFACts-shape detection on uncataloged calls (this session)
- ✅ Master drift table rename `FORBIDDEN_SUBSECTION_MARKER` → `MALFORMED_SUBSECTION_MARKER` (this session)

Spec, shared helper, and populator are internally consistent. The PS populator can be relied on as the catalog source-of-truth for the upcoming PS file refactoring work.

---

## 6. JS populator — remaining work for next session

The JS populator is the **only remaining populator with outstanding work**. Three items from earlier carry-over lists are all that's left to fully wrap the populator family:

### B1 — FILE_HEADER phantom-row fix

Mechanical mirror of the PS fix that landed in Session 11. Verification query after the PS fix (`SELECT COUNT(*) FROM dbo.Asset_Registry WHERE component_type = 'FILE_HEADER' AND raw_text IS NULL`) returned 5 rows, all from JS files. The fix: locate the JS populator's "no header found" branch (likely emits an `Add-JSFileHeaderRow` call with NULL raw_text), replace with drift attachment to the `JS_FILE` anchor row using whatever drift code corresponds to MALFORMED_FILE_HEADER on the JS side.

### B4 — Visitor scriptblock → function (JS and CSS populators)

The shared helper's `Invoke-AstWalk` now accepts function-name dispatch (Change 3 above), but no caller has been switched yet. The JS populator's `$JsVisitor` scriptblock body is large (~1000 lines per the performance investigation doc). Converting it to a standalone `Invoke-JsVisitor` function involves moving the body, updating the single call site, and dealing with any scope-related semantics that change between scriptblock and function dispatch (closure variable visibility, `return` behavior, automatic variable handling). Same operation on the CSS populator's `$CssVisitor`, smaller in scope.

### B5 — Batch Node subprocess for parse-js.js / parse-css.js

The populators currently spawn a fresh `node parse-js.js` (or `parse-css.js`) subprocess per scanned file in Pass 1. The investigation doc proposes batching: one long-running Node process that reads file paths from stdin and emits parse results to stdout, drastically reducing subprocess startup overhead. Affects `parse-js.js`, `parse-css.js`, and Pass 1 of both populators.

### Plus — late-discovery cleanup items still applicable to JS

- Performance fix 2.1 (`Get-SectionForLine` binary search): **already landed** in the shared helper this session, applies to JS automatically.
- Performance fix 2.3 (`$null -ne $Node.type` direct property check): **already landed** in the shared helper this session, applies to JS automatically.
- Performance fix 2.2 (scriptblock → function): **shared helper side ready**, needs JS populator caller change (B4 above).
- Performance fix 2.4 (batch Node subprocess): **B5 above**.

So the helper-side perf gains are already active for the JS populator now — re-running the JS populator at the current helper version should already show measurable improvement before any JS populator code changes land. The JS-side perf work in the next session activates the remaining 20-30% of the projected gap.

---

## 7. Cataloging stance — decisions confirmed this session

Mid-session, Dirk asked whether the populator's silent-skip behavior on built-in cmdlets, .NET method calls, and external-module function calls was the right cataloging decision, or whether more should be emitted as rows. The walkthrough:

| Bucket | Examples | Current behavior | Outcome |
|---|---|---|---|
| 1: PowerShell built-in cmdlets | `Where-Object`, `ForEach-Object`, `Out-Null` | Silently skipped | Confirmed correct — language plumbing, no refactor value |
| 2: .NET method calls | `[string]::IsNullOrEmpty()`, `$list.Add()` | Silently skipped | Confirmed correct — language plumbing |
| 3: External module cmdlets that matter | `Add-PodeRoute`, `Invoke-Sqlcmd`, `Export-ModuleMember` | Captured via dedicated row types (`PS_ROUTE`, `SQL_QUERY`, `PS_EXPORT`, etc.) | Confirmed sufficient — meaningful external deps already first-class |
| 4: Pode framework helpers inside scriptblocks | `Get-UserAccess`, `Test-ActionEndpoint`, `Write-PodeHtmlResponse`, `Write-PodeJsonResponse` | Spec checks fire on the enclosing `PS_ROUTE` row; no standalone call rows | Confirmed sufficient — the example query "find every API route missing `Test-ActionEndpoint`" already works via `WHERE component_type = 'PS_ROUTE' AND drift_codes LIKE '%MISSING_RBAC_CHECK_API%'` |
| 5: xFACts internal cross-file calls | `Get-bkp_OpenBatches`, `Invoke-XFActsQuery` | Captured as `PS_FUNCTION_CALL` USAGE rows | Confirmed correct — this is the bucket the populator catalogs explicitly |

The honest cataloging gap was the orphan case in bucket 5: an xFACts-shaped call to a function that doesn't exist anywhere in the catalog. Previously this was silently skipped along with everything else, indistinguishable from a `Where-Object` call. The new `ORPHAN_FUNCTION_CALL` detection (A3, above) closes this gap by recognizing the `Verb-prefix_Noun` shape and emitting a row with drift when no definition resolves.

---

## 8. Spec-content discipline reaffirmed

Dirk's mid-session feedback: *"The spec contains NO content beyond explicitly stating the rule. No comments on what constitutes drift. Stop bloating the spec."* Several rule statements in the PS spec had drifted toward including "is drift" framing or runtime-behavior rationale (e.g., "Such collisions shadow the shared function at runtime and are drift"). All such phrasings were tightened to plain rule statements. §17 (drift code reference table) is the contract between spec and populator and remains in place; body sections state rules only.

Going forward, the CSS, JS, HTML, and PS specs should all be held to this same discipline. Rules are stated; the populator enforces; §17 (or equivalent) maps codes to rules.

---

## 9. Process notes

### Working-copy reconstruction is unsafe for large files

Mid-session I attempted to reconstruct `xFACts-AssetRegistryFunctions.ps1` from Project Knowledge search results rather than fetching the actual file. The reconstruction was 383 lines shorter than the real file — the gap was mostly comment density that the search-result chunks didn't fully expose. Dirk caught the discrepancy and requested the actual file by upload. The actual file was then used as the working copy, with the three target changes applied via `str_replace` against the real content.

**Going forward:** for any populator-class file (>1000 lines), always fetch the actual current file (via cache-busted manifest URL) or have Dirk upload it before making changes. Working from memory or reconstructed search-result content is not acceptable — too much drift risk on bodies, comments, and CHANGELOGs that the search results don't fully cover.

### PowerShell script-scope variable hygiene

The `$rows` variable name collision with `$script:rows` (Pass 3 bulk-insert collection) caused the catastrophic first-attempt run. Lesson: when adding new code to the PS populator at script scope, treat any variable name that already exists at script scope as off-limits for reuse. Common candidates to watch: `$rows`, `$row` (when used outside a foreach iterator), `$file`, `$name`, `$role`, `$ast`, `$parsed`, `$leading`, `$trailing`. If in doubt, prefix the local name (e.g., `$defRows` instead of `$rows`) or scope it explicitly with `Set-Variable -Scope Private`.

---

## 10. Backlog moving forward

After JS populator wrap-up next session, the populator-completion milestone is hit. The next initiative beyond that is the **per-page file refactor** against the four specs, starting with **Backup** (the four files Backup.ps1, Backup-API.ps1, backup.css, backup.js) as the reference implementation. The shared-file drift cleanup in `cc-shared.css`, `cc-shared.js`, and `xFACts-CCShared.psm1` also lives in that refactor stage.

The catalog (post-JS-wrap) becomes the source-of-truth driver for refactor work: drift queries against `dbo.Asset_Registry` produce the per-file remediation list directly.

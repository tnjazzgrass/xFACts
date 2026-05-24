# Asset Registry Populator Performance Investigation

*Carry-forward roadmap for performance work on the Asset_Registry populators. Created at the close of the JS spec ↔ populator alignment session (2026-05-24). The JS, CSS, and HTML populators are functionally correct and aligned with their specs; this document captures the performance picture and the change plan for a dedicated follow-up session.*

---

## 1. Measured baseline (2026-05-24, full pipeline run)

All three populators executed in sequence (`-Execute`) against the live codebase. Times are wall-clock from console output.

| Populator | Files | Total time | Walk time | Per-file walk avg | Rows emitted |
|---|---|---|---|---|---|
| CSS | 32 | ~1m 22s | ~45s | ~1.4s | 8,610 |
| HTML | 41 | ~24s | ~17s | ~0.4s | 4,394 |
| **JS** | **29** | **~6m 30s** | **~283s** | **~9.8s** | **10,633** |

The JS walk is **~7x slower per file than CSS** and **~25x slower than HTML**. Pass 1 (parse) and Pass 3 (cross-file) plus bulk-insert are comparable across all three populators. The pathology is specifically in Pass 2 — the per-file AST walk.

---

## 2. Diagnosis

Four contributing factors, listed in roughly descending order of impact.

### 2.1 `Get-SectionForLine` is O(N) linear scan, called once per row emission

Lives in `xFACts-AssetRegistryFunctions.ps1`. Every row emitted by `New-JsRow` (and equivalently `New-CssRow`) triggers a section attribution lookup. The function walks the section list linearly looking for the section whose body range contains the row's line number.

**Why JS is worst affected:**
- ~10,633 total JS rows across 29 files
- Average ~30 banners per JS file
- ~10,633 × 30 = **~320,000 comparisons** for section attribution alone
- Each comparison accesses `BodyStartLine` and `BodyEndLine` via PSCustomObject property navigation (slow in PowerShell)

CSS has fewer rows per file, so the same algorithm hurts less. HTML uses a different emission shape that avoids the lookup almost entirely.

**Fix:** sections are mutually exclusive and ordered by line number. Replace the linear scan with one of:
- A pre-built sorted array searched by binary search, OR
- A "current section index" cursor that advances forward as line numbers increase (since AST nodes are visited in roughly source order)

Either approach drops section lookup from ~3s/file to milliseconds.

**Scope:** shared helper — fixing it benefits CSS and JS together.

### 2.2 The visitor scriptblock is dispatched per AST node

`$JsVisitor` is a 984-line `[scriptblock]` invoked by `Invoke-AstWalk` for every AST node in the file. PowerShell scriptblock invocation has substantially higher overhead than function calls — for each of typically 5,000–15,000 AST nodes per file, the entire scriptblock body is dispatched even though only one `switch` branch handles each node type.

**Per-file impact:** 5,000–15,000 scriptblock invocations × scriptblock overhead per call.

**Fix:** convert `$JsVisitor` from a `[scriptblock]` to a regular function `Invoke-JsVisitor`. Mechanical change — copy the scriptblock body verbatim into a function with the same three parameters; in `Invoke-AstWalk`, change `& $Visitor $Node $ParentChain $ParentNodes` to a direct function call.

**Scope:** the CSS populator uses the same pattern, so apply the same change there for parity. The shared `Invoke-AstWalk` needs a way to accept either form, or we standardize on functions.

### 2.3 `PSObject.Properties.Name -contains 'X'` in hot paths

Used in `Invoke-AstWalk` itself (the `if ($Node.PSObject.Properties.Name -contains 'type')` guard) and in helpers called from the visitor (`Test-IsInsideElementLoop`, `Test-CalleeMatchesEnd`, `Get-CurrentParentName`, `Get-NameForFunctionExpression`).

Each call:
1. Enumerates all properties of the PSCustomObject into a string array
2. Performs a linear `-contains` scan against that array

This is unnecessary for AST nodes. Every well-formed acorn output node has `type`. The check exists for defensive null-handling on malformed inputs that don't reach this code in practice.

**Fix:** replace `$Node.PSObject.Properties.Name -contains 'type'` with `$null -ne $Node.type`. PowerShell returns `$null` for missing properties on PSCustomObject without throwing. Same pattern in the helpers.

**Scope:** the helpers are JS-specific; the `Invoke-AstWalk` change is shared.

### 2.4 Node subprocess overhead (~3s/file in Pass 1)

`Invoke-JsParse` spawns `node parse-js.js` once per file. With 29 files this is ~87s of Pass 1 alone. CSS pays the same per-file penalty against PostCSS but it doesn't visibly hurt because CSS's overall walk is faster.

**Fix:** send all files to one long-running Node process via a pipeline or batch protocol. The parse-side script would read filenames from stdin and emit one JSON object per line.

**Scope:** the JS populator's Pass 1, plus `parse-js.js`. CSS would benefit from the same treatment with `parse-css.js`.

**Complexity:** highest of the four. Defer until the other three fixes don't bring the walk into line.

---

## 3. Recommended execution order

1. **Section-lookup fix (2.1)** — smallest change, largest expected impact, shared infrastructure improvement.
2. **Property-check fix (2.3)** — mechanical, second-largest impact.
3. **Scriptblock → function (2.2)** — mechanical, medium impact, touches the walker contract.
4. **Subprocess batching (2.4)** — only if 1–3 don't get us into the same range as CSS.

After fixes 1–3, expected walk time drops from ~283s to ~70–100s — closer to PS's ~80s and CSS's ~45s.

Each step gets measured against the same baseline:
- Same input files (full codebase)
- Same `-Execute` flag (so the bulk-insert step is measured too)
- Row counts compared exactly to the baseline (any drift in row counts is a correctness regression)

---

## 4. Cross-populator implications

The performance work is not JS-only. The CSS populator shares `Invoke-AstWalk` and `Get-SectionForLine`, so fixes 2.1 and 2.3 will improve CSS too. The scriptblock-vs-function pattern (2.2) is identical in CSS.

**The PS populator** is on a different track. It uses PowerShell's native AST with `.FindAll({ predicate }, $true)` rather than walking PSObject properties via `Invoke-AstWalk`. It has its own performance characteristics and is not affected by 2.1, 2.2, or 2.3 directly.

**The HTML populator** is also different. It does its own walk of HTML emissions extracted from PowerShell here-strings. Not affected directly by the JS-side fixes, though `Get-SectionForLine` is shared and HTML does call it.

---

## 5. Validation strategy

For every change in this initiative:

1. **Pre-change baseline**: confirm current row counts per populator (CSS 8,610 / HTML 4,394 / JS 10,633 — adjust on the day if codebase has shifted).
2. **Apply change** to one populator at a time.
3. **Run that populator with `-Execute`**.
4. **Confirm row counts match exactly** — drift in row counts is a correctness regression.
5. **Confirm drift code counts match exactly** — drift in drift code counts is the same kind of regression.
6. **Measure time delta** against baseline.
7. **Document** in this file or a session summary.

If anything diverges in row or drift counts, stop and investigate before continuing. Performance work that silently changes catalog output is the worst kind of regression because it pollutes downstream data.

---

## 6. Out of scope for this initiative

These are tempting parallel cleanups but should not be bundled with the perf work:

- **Object_Metadata enrichment** for the populators (OQ-INIT-3). Already tracked separately.
- **PS populator's `($curStart - $prevEnd) -gt 2` blank-line counting bug**. Tracked elsewhere.
- **Spec changes**. The four CC specs (CSS, HTML, JS, PS) are locked from earlier sessions; no spec changes in this initiative.
- **Behavior changes to drift detection**. This is a performance pass — same inputs produce same outputs, just faster. Any code path that emits different rows or different drift codes is out of scope.

---

## 7. Open questions for the next session

- **Profiling first?** Worth adding `Stopwatch` instrumentation around the four hot paths (section lookup, scriptblock dispatch, property checks, subprocess spawn) before making changes? Gives hard numbers per phase instead of relative estimates. Adds ~30 minutes to the session but produces measurable evidence of each fix's impact.
- **One-by-one or batched delivery?** Each fix delivered as its own measurement cycle (slower but cleaner attribution), or bundle fixes 1–3 together (faster but harder to diagnose if one regresses)?
- **CSS populator: parallel pass or follow-up?** Touch CSS in the same session (better consistency, more changes per session) or land JS first and follow with CSS (cleaner reviews, smaller surface per session)?

---

## 8. Reference: relevant files

- `xFACts-PowerShell/xFACts-AssetRegistryFunctions.ps1` — shared `Invoke-AstWalk` (line ~1537), `Get-SectionForLine` (line ~1463)
- `xFACts-PowerShell/Populate-AssetRegistry-JS.ps1` — `$JsVisitor` scriptblock (line ~2649)
- `xFACts-PowerShell/Populate-AssetRegistry-CSS.ps1` — equivalent CSS visitor
- `xFACts-PowerShell/parse-js.js` — Node helper for AST extraction
- `xFACts-PowerShell/parse-css.js` — Node helper for CSS AST extraction

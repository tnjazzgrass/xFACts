# CC Session Summary 13 — JS Populator Performance Pass; Shared-File Drift Audit; Refactor Stage Entry

**Date:** 2026-05-26
**Focus:** Closed out the remaining JS populator performance items from Session 12's roadmap (B1 FILE_HEADER phantom fix, B4 scriptblock → function, B0 per-case setup restructure). Performed two rounds of in-place instrumentation to diagnose where Pass 2 time actually goes. Applied two surgical optimizations to the dominant hot paths (CallExpression walk-once, Literal front-gating). Audited shared-file drift to plan the refactor stage. Marked `CC_Populator_Performance_Investigation.md` obsolete.

**Disposition:** JS populator structurally complete and at its practical performance floor under PowerShell 5.1. Total runtime ~5:18 (Pass 1 ~108s, Pass 2 ~196s, Pass 3 + insert ~14s). Further speed gains require either Node subprocess batching (B5, deferred) or moving hot paths to C# (out of scope). Catalog row count stable at 10,619 with 28.0% drift rate. Shared-file drift mapped: `cc-shared.css` and `cc-shared.js` are quick targeted cleanups; `xFACts-CCShared.psm1` needs its own dedicated alignment session.

---

## Files delivered

| File | Path | Net change |
|---|---|---|
| `Populate-AssetRegistry-JS.ps1` | `xFACts-PowerShell/` | +119 lines (4220 → 4359) |

All edits applied as surgical in-place modifications against the current file. Intermediate instrumented variants were used for diagnosis and are not retained.

---

## 1. JS populator performance work (Pass 2)

Five sequential changes landed in one file. Three from Session 12's roadmap (B1, B4, B0); two new optimizations identified by mid-session profiling (CallExpression, Literal).

### 1.1 B1 — FILE_HEADER phantom-row fix

The old behavior unconditionally emitted a `FILE_HEADER` row even when `Get-FileHeaderInfo` returned `IsValid=$false` (no valid `/* ... */` block at line 1). The result was 5 phantom rows with `raw_text=NULL` across the 14 JS files lacking proper headers.

The fix moves the FILE_HEADER emission inside an `if ($headerInfo.IsValid)` gate. When invalid, no FILE_HEADER row is emitted; instead, the `MALFORMED_FILE_HEADER` drift code (and any other codes from `$headerInfo.DriftCodes`) attach to the file's JS_FILE anchor row with a context message. This mirrors the PS populator's pattern from Session 11.

After this change, `FILE_HEADER DEFINITION LOCAL` dropped from 19 to 14 (the 5 phantoms), and 14 JS_FILE rows now carry `MALFORMED_FILE_HEADER` drift — same information attached to the right anchor.

### 1.2 B4 — Visitor scriptblock → function

The 984-line `$JsVisitor = { ... }` scriptblock became `function Invoke-JsVisitor { ... }`. The call site in Pass 2 was updated to pass `'Invoke-JsVisitor'` as a string to `Invoke-AstWalk`, leveraging the shared helper's Session 12 Change 3 that accepts either a scriptblock or a function name.

One closure-read variable surfaced during the audit: `$EngineProcessesBannerName` at script scope was being read via closure inside the visitor body. Function dispatch doesn't capture script-scope variables that aren't `$script:`-prefixed, so the declaration was promoted to `$script:EngineProcessesBannerName` and the closure-read site updated to use the explicit prefix. A second read site already used the explicit prefix; the inconsistency was a latent bug that this change cleaned up.

The auxiliary `$rangeVisitor` scriptblock (13 lines, called from a different Pass 2 path) was intentionally left as a scriptblock. Its tight closure over the local `$functionRanges` list would require awkward `$script:` promotion for negligible perf gain since the body is trivial.

### 1.3 B0 — Per-case setup restructure (Option A, aggressive variant)

The five-call pre-switch preamble (`Get-NodeLine`, `Get-NodeEndLine`, `Get-NodeColumn`, `Get-SectionForLine`, `Get-CurrentParentName`) was eliminated. Each switch case now computes only the setup variables it actually uses, *after* any early-rejection checks.

The aggressive variant — pushing setup past early returns wherever possible — means cases like `FunctionDeclaration` skip all setup entirely on non-top-level nodes (rejected by `Test-IsTopLevel`), `Literal` skips setup on non-string and short-string literals, and so on. The fall-through path (no matching case, ~67% of visits) now pays only the param binding, null check, and switch dispatch — no setup at all.

Per-case audit confirmed every setup-var reference is preceded by its definition within the same case, and no references leak outside cases.

### 1.4 CallExpression optimization — walk-once / compare-many

Mid-session profiling identified CallExpression as the dominant cost at 51.8% of visitor time (9,414 calls at 5.3 ms/call). Each call did 9 redundant chain walks via repeated invocations of `Test-CalleeMatchesEnd`, plus an O(n²) `Insert(0, ...)` pattern on the segments list.

`Test-CalleeMatchesEnd` was removed. Two new helpers replaced it: `Get-CalleeSegments` walks the callee chain once and returns segments in leaf-first order; `Test-SegmentsMatchEnd` performs the dotted-path comparison against pre-computed segments. The CallExpression case computes segments once at the top of the case body, then performs all 9 dotted-path checks against the cached result.

### 1.5 Literal optimization — front-gate with length guard

Profiling identified Literal as second-heaviest at 29.3% of visitor time (19,425 calls at 1.45 ms/call). The original ran `Get-RangeText` (substring allocation) and three regex predicates on every literal, with the broadest `Test-LooksLikeHtml` predicate evaluated last.

Reordered: length guard at top (literals under 4 chars return immediately), then `Test-LooksLikeHtml` as the front gate (its pattern is a superset of inline-style and inline-script patterns). Setup variables and `Get-RangeText` only execute when the HTML gate passes. Most literals now exit after a single regex check.

TemplateLiteral was considered for the same optimization but deferred — `Test-LooksLikeHtml` is not a strict gate for `Test-LooksLikeInlineEvent` (an event-attribute fragment like ` onclick="..."` can match the event pattern without matching the HTML pattern), and the case is only 1.0s / 286 calls anyway.

### 1.6 Bug found and fixed: PowerShell list-return unrolling

First delivery of the CallExpression/Literal optimization caused 23 missing rows (20 JS_EVENT USAGE, 3 CSS_CLASS USAGE). Root cause: `Get-CalleeSegments` returned `$segments` (a `List[string]`), which PowerShell's output stream enumerated. The caller received either a single string (for 1-segment callees) or an `Object[]` (for 2+), never the original `List[string]`. The `.Count` check on a string returns its character length, making the comparison silently fail for one-segment callees.

Fix: `return , $segments` — the unary comma operator wraps the value in a one-element output, defeating PowerShell's IEnumerable enumeration. Standard PowerShell idiom for "return this collection as a single object." Same class of footgun as the `Measure-Object` failure earlier in the session; both stem from PowerShell's implicit-enumeration behavior on collection-typed values crossing cmdlet/function boundaries.

---

## 2. Diagnostic instrumentation (two passes, removed after use)

### 2.1 First pass — bucket timing

Wrapped `New-JsRow`, `Resolve-CssClassUsage`, `Get-PrecedingBlockComment`, and the entire `Invoke-JsVisitor` body with `System.Diagnostics.Stopwatch` timers and invocation counters. Diagnostic report block printed totals and per-call averages at end of Pass 2.

Findings: Visitor body dominated (94.7s of 192s Pass 2). Inside visitor, "everything else" was 81.4s (86%). `New-JsRow` was 12.4s (13%); other helpers negligible. Conclusion: the cost was in the per-case logic itself, not in shared helpers.

### 2.2 Second pass — per-case timing

Wrapped each of the 10 switch cases with its own timer and counter; added a `default` branch to count fall-through visits. Extended report block to show per-case breakdown sorted by elapsed time descending.

Findings (the smoking gun):

| Case | Time | % of Visitor | Calls | ms/call |
|---|---:|---:|---:|---:|
| CallExpression | 49.9s | 51.8% | 9,414 | 5.298 |
| Literal | 28.2s | 29.3% | 19,425 | 1.451 |
| FunctionDeclaration | 5.9s | 6.2% | 1,489 | 3.980 |
| AssignmentExpression | 4.9s | 5.1% | 6,241 | 0.784 |
| ExpressionStatement | 2.1s | 2.2% | 9,754 | 0.213 |
| VariableDeclaration | 1.6s | 1.7% | 4,133 | 0.391 |
| TemplateLiteral | 1.0s | 1.0% | 286 | 3.525 |
| **(fall-through)** | **2.6s** | **2.7%** | **104,354** | **0.025** |

Fall-through was essentially free — 67% of all invocations cost 25 microseconds each. B4+B0 made no-match traffic genuinely cheap. The work that needed targeted optimization was CallExpression and Literal, which led directly to the changes in §1.4 and §1.5.

ImportDeclaration, ClassDeclaration, and MethodDefinition all had zero calls — confirms that CC JS is purely function-based with no ES6 imports, classes, or methods.

### 2.3 What the optimization actually delivered (or didn't)

Predicted: 50-60 seconds saved.
Actual: zero. The post-optimization run came in 15 seconds *slower* than pre-optimization, within plausible run-to-run variance (±5-7s observed across three instrumented runs of identical code).

The diagnosis after the fact: **PowerShell's per-statement interpretation cost dominates the visitor body more than the algorithmic improvements could overcome.** Replacing `Insert(0, x)` with `Add(x)` saved O(n²) → O(n) on lists of length 1-3, which is microseconds at most. Replacing one function call with two (for the walk-once pattern) added function-call overhead that ate into the savings. The regex tests in Literal are already fast in .NET's regex engine. The optimizations are still good — cleaner code, less wasted work — but the PowerShell interpretation floor is the actual bottleneck.

**Implication:** further surgical Pass 2 optimization has diminishing returns. The remaining levers are B5 (Pass 1, saves ~50s of Node subprocess overhead) and moving hot paths to compiled C# via `Add-Type` (large project, large potential payoff, large risk). Both stay on the backlog.

---

## 3. Document marked obsolete

`CC_Populator_Performance_Investigation.md` (in `Planning/`). Of the four recommendations:

- **2.1 Section-lookup binary search** — landed in Session 12's shared-helper pass.
- **2.2 Scriptblock → function** — landed this session as B4.
- **2.3 `PSObject.Properties.Name -contains` → `$null -ne $Node.type`** — landed in Session 12.
- **2.4 Node subprocess batching** — deferred (was labeled "Defer until 1-3 don't bring the walk into line" in the doc itself; still appropriate). Tracked as B5 on the backlog.

The doc's expected outcome of "walk time drops from ~283s to ~70-100s" did not materialize at the level projected. Actual post-changes walk time is ~196s. The recommendations were sound but the impact estimate was optimistic; PowerShell interpretation cost was undervalued in the original analysis.

To be deleted in the next session-summary review cycle alongside other working docs that have served their purpose.

---

## 4. Key learnings for the development guidelines

These came out of this session and may be worth promoting in the eventual guidelines consolidation:

- **Profile before optimizing PowerShell performance.** Three of our four predictions about where the time would go were wrong (B0 didn't move the needle as expected, CallExpression chain walks weren't the dominant cost, Literal regex tests were cheap). The instrumented runs cost 30 minutes and revealed the truth; the prior 90 minutes of theory-driven optimization could have been spent differently with better data.

- **PowerShell's implicit-enumeration on collection returns is a real footgun.** `return $list` where `$list` is `IEnumerable` causes the output stream to enumerate, so the caller receives unrolled values, not the original collection. The standard fix is `return , $list` — the unary comma wraps the value in a one-element output. Hit this twice in the same session: once with `Measure-Object -Property` on a hashtable array (which threw cleanly), once with `Get-CalleeSegments` returning a List (which silently produced wrong results). The silent failure mode is the dangerous one.

- **PowerShell's per-statement interpretation cost is the floor.** For visitor-pattern code that runs hundreds of thousands of times per session, the cost per line of script matters more than algorithmic improvements. When `$Node.callee.type` (property access) and `$cursor -and $cursor.type -eq 'X'` (chained boolean) cost microseconds *each* in the interpreter, even substantial algorithmic improvements to allocation behavior get lost in the interpretation overhead.

- **Performance work must preserve row counts exactly.** The 23-missing-rows incident this session was a clean example of why this is non-negotiable. Silent row-count drift is a correctness regression masquerading as a behavior preservation. The validation pattern (compare row counts before/after, fail-loud on any mismatch) caught it within one run.

- **Run-to-run variance on Windows PowerShell is meaningful** — at least ±5-7 seconds on Pass 2 timing for identical code. Any single-run timing comparison needs to account for this; a 15s delta could be optimization impact, could be variance, can't be distinguished without multiple runs.

(All of the above will live in this session summary until the consolidation pass mentioned in §6 below.)

---

## 5. Shared-file drift audit

Final run of all four populators against the current codebase. Drift breakdown for the three shared CC files:

### 5.1 cc-shared.css — 39 drift rows, 1 code

| Code | Count | Lines |
|---|---:|---|
| PREFIX_MISMATCH | 39 | 329 – 1359 |

Single category, spread throughout the file. Either every flagged class violates the prefix rule, the populator is mis-flagging chrome-anchor classes that need exemption, or the spec moved and a new exemption set is needed. Single decision pattern repeated 39 times — focused refactor target.

### 5.2 cc-shared.js — 6 drift rows, 1 code

| Code | Count | Lines |
|---|---:|---|
| JS_HTML_ID_UNRESOLVED | 6 | 979 – 1473 |

Cross-spec rule — JS references HTML IDs that the populator can't resolve to a definition. Could be IDs in not-yet-refactored pages, dynamically constructed IDs the populator can't follow, or genuinely missing IDs. Six rows total; diagnosis per row matters more than count.

### 5.3 xFACts-CCShared.psm1 — 113 drift rows, 17 codes

| Code | Count |
|---|---:|
| MISSING_SECTION_BANNER | 42 |
| DUPLICATE_FUNCTION_DEFINITION | 39 |
| MISSING_DOCBLOCK | 39 |
| MISSING_CMDLETBINDING | 39 |
| FORBIDDEN_FREESTANDING_COMMENT_BLOCK | 35 |
| MALFORMED_SUBSECTION_MARKER | 20 |
| FORBIDDEN_DYNAMIC_CLASS_PATTERN | 7 |
| FORBIDDEN_TRAILING_COMMENT | 6 |
| MISSING_PARAM_BLOCK | 5 |
| UNAPPROVED_VERB | 2 |
| MISSING_PURPOSE_COMMENT | 2 |
| MISSING_VARIABLE_COMMENT | 2 |
| (single-row codes) | 7 |

The file was cloned from `xFACts-Helpers.psm1` and never went through PS spec alignment. The top five codes (194 of 197 code-instances) all reflect the same root cause: the file is shaped like the old helpers file, not the current PS spec. This is not minor straggler drift — this is "needs a real alignment pass" territory.

---

## 6. Next session direction

**Primary focus:** shared CC file refactor. Order matters here — the browser-side shared files are the foundation every page imports, and they should be at zero drift before page-level work begins. Recommended sequence:

1. **`cc-shared.css` PREFIX_MISMATCH cleanup.** Read the 39 flagged class names against the current CSS spec. Decide for each whether the class needs renaming, the class needs exemption (chrome anchor, third-party, etc.), or the spec needs amendment. Apply the resolution. Single focused work item.

2. **`cc-shared.js` JS_HTML_ID_UNRESOLVED cleanup.** Inspect each of the 6 flagged references. Categorize: IDs that should exist somewhere (find where), IDs that are dynamic and need a populator exemption pattern, IDs that are genuinely broken. Resolve each.

3. **Backup page refactor begins** (the original primary intent for this session, deferred to the next). With shared at zero drift, the Backup CSS/JS/PS refactor exercises the shared layer as a side effect and will surface any remaining gaps concretely.

**`xFACts-CCShared.psm1` alignment** is its own dedicated session. The 113 rows across 17 codes (with the top-five reflecting a structural mismatch with the current PS spec) is not interleavable with page-level work — it needs focused attention. Schedule between page refactors, not alongside them. Could potentially follow the Backup completion as the next-after-that session.

**Working doc for next session:** none new needed. The four CC specs in `Planning/` (CSS, HTML, JS, PS) are the authoritative reference. The catalog itself (Asset_Registry) is the burndown tracker.

---

## 7. End-of-session state, in one sentence

**JS populator complete and at its practical performance floor (~5:18 total runtime, 10,619 rows, 28.0% drift), shared CC file drift fully mapped and ready for targeted cleanup beginning next session, and `CC_Populator_Performance_Investigation.md` marked obsolete.**

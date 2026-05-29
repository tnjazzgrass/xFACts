# CC Session Summary 18 — Cross-Spec Resolver Complete

## Session focus

Completing the cross-spec reference resolution architecture for the Asset Registry. Three threads:

1. Closing remaining catalog-data defects so all five resolution edges produce clean output
2. Rewriting `Resolve-AssetRegistryReferences.ps1` for spec compliance against `CC_PS_Spec.md`
3. Identifying spec defects that surfaced during the rewrite

The resolver was operational before this session but flagged ~80% of cross-spec USAGE rows as `<undefined>` due to two latent populator bugs (URL-vs-basename mismatch in HTML, zone tracking gap in JS vendored anchors). Both bugs are now fixed; the resolver itself is now spec-compliant down to a single known-and-flagged drift code that will resolve to zero once a minor spec amendment lands next session.

---

## Completed work

### 1. HTML populator basename fix

**Files**: `Populate-AssetRegistry-HTML.ps1`, two functions
**Functions changed**: `Add-CssFileUsageRow`, `Add-JsFileUsageRow`
**Delivery**: Drop-in function replacements (working copy in outputs is the cumulative state)

The HTML populator was writing `component_name = $Href` (the full URL path from `<link rel="stylesheet" href="...">` or `<script src="...">`), e.g., `/css/cc-shared.css` or `/js/cc-shared.js`. The CSS and JS populators write `component_name = $script:CurrentFile` (the bare filename), e.g., `cc-shared.css` or `cc-shared.js`. The resolver's SQL joins on `component_name` equality and never matched URL-path strings against bare-filename strings, so all 37 CSS_FILE and 41 JS_FILE USAGE rows fell through to Phase B and got stamped `<undefined>`.

Fix: extract the basename with `[System.IO.Path]::GetFileName($Href)` at the top of each function, then use the bare name for both the dedupe key and `component_name`. Full URL stays preserved in `raw_text` (which holds the full `<link>` or `<script>` element).

This makes the catalog data self-consistent: `component_name` consistently means "the thing being referenced, by its canonical name" across all populators.

### 2. JS populator vendored anchor zone fix

**File**: `Populate-AssetRegistry-JS.ps1`, line ~4105
**Delivery**: One-line drop-in addition

The JS populator's vendored-library anchor loop (which emits a single DEFINITION row for each locally-hosted third-party JS library — `chart.min.js`, `chartjs-adapter-date-fns.min.js`, `xlsx.full.min.js`) sets `$script:CurrentFile` and `$script:CurrentFileIsShared` before calling `Add-JsFileRow`, but did not set `$script:CurrentFileZone`. The vendored anchors emitted with whatever zone the last per-file walk happened to leave the variable in — typically `docs`, depending on processing order.

Result: vendored library DEFINITION rows had `zone = 'docs'` while HTML USAGE references had `zone = 'cc'`, so the resolver's `AND d.zone = u.zone` filter rejected them. The 3 local vendored library references stayed unresolved alongside the 2 legitimate CDN references.

Fix: one-line addition setting `$script:CurrentFileZone = 'cc'` in the vendored anchor loop. Vendored libraries always live in `xFACts-ControlCenter/public/js/` (always cc-zone), so the explicit value is correct in every case.

### 3. Resolver rewrite for PS spec compliance

**File**: `Resolve-AssetRegistryReferences.ps1` (875 lines)
**Delivery**: Full file replacement

The resolver was functionally complete from prior work but didn't comply with `CC_PS_Spec.md` — it predated the spec. The rewrite restructures the file against the spec's positive requirements while preserving the working logic.

Structure delivered:

```
Section 1: File header (CBH)
  - .SYNOPSIS, .DESCRIPTION, .PARAMETER Execute, .COMPONENT Tools.Utilities
  - .NOTES with File Name, Location, FILE ORGANIZATION list
  - FILE ORGANIZATION list uses 17-dash separator, lists 6 banners verbatim

Section 2: PARAMETERS: SCRIPT PARAMETERS
  - [CmdletBinding()] + param([switch]$Execute)

Section 3: IMPORTS: SCRIPT DEPENDENCIES
  - Dot-source xFACts-OrchestratorFunctions.ps1

Section 4: INITIALIZATION: SCRIPT INITIALIZATION
  - Initialize-XFActsScript ...

Section 5: CONSTANTS: EDGE DEFINITIONS
  - Sub-sections (# -- ... --) for:
    - Script preferences ($script:ErrorActionPreference)
    - 5 edge definitions ($script:EdgeHtml*, $script:EdgeJs*)
    - Edge collection ($script:Edges array)
    - Final catch-all SQL ($script:FinalCatchAllSql)

Section 6: FUNCTIONS: EDGE EXECUTION
  - 5 functions, each with [CmdletBinding()], param(), and a docblock:
    - Show-EdgePreview, Invoke-EdgeResolution (parametrized by edge hashtable)
    - Show-PreRunSnapshot, Invoke-FinalCatchAll, Show-PostRunSummary (parameterless)

Section 7: EXECUTION: SCRIPT EXECUTION
  - Procedural orchestration: snapshot, preview branch, edge loop, catch-all, summary
  - Just function calls; no top-level $script: declarations
```

Spec-compliance details:
- All 6 section banners use the exact 76-equals / 76-dashes / 3-space-indent format from §3.1
- All banners declare `Prefix: (none)` (Tools.Utilities has `cc_prefix = NULL`)
- All 8 sub-section markers use the exact `# -- <Label> --` format from §13.2 (two dashes per side) with required blank lines before and after
- All 5 functions have `[CmdletBinding()]`, `param()`, docblock in the §8.1 order, with `.SYNOPSIS` / `.DESCRIPTION` / `.PARAMETER` only (no forbidden keywords)
- Function names use bare `Verb-Noun` with approved verbs (`Show`, `Invoke`)
- All top-level mutable state moved into function locals so EXECUTION is a flat sequence of function calls

The file's physical order is `PARAMETERS → IMPORTS → INITIALIZATION → CONSTANTS → FUNCTIONS → EXECUTION`, which differs from §4.2's current canonical order (`IMPORTS → PARAMETERS → ...`). See "Spec defects identified" below.

---

## Validation results — final catalog state

Cross-spec USAGE row resolution, end of session:

| Edge | Resolved | Unresolved | Notes |
|---|---|---|---|
| HTML → CSS_CLASS | 1,799 | 223 | Unresolved = refactoring debt (CSS class references from unrefactored pages) |
| HTML → CSS_FILE | 37 | 0 | Clean |
| HTML → JS_FILE | 39 | 2 | The 2 unresolved are CDN `chart.js` references |
| JS → CSS_CLASS | 3,392 | 1,395 | Unresolved = refactoring debt |
| JS → HTML_ID | 892 | 79 | Unresolved = refactoring debt |

Overall resolution rate: ~80%. Every unresolved row carries an edge-specific drift code (`HTML_CSS_CLASS_UNRESOLVED`, `JS_HTML_ID_UNRESOLVED`, etc.) plus a `<undefined>` source_file. No silent fallthrough.

---

## Spec defects identified

### Defect 1: §4.2 type ordering is incompatible with PowerShell language semantics

**Description**: §4.2 prescribes section type ordering as `CHANGELOG, IMPORTS, PARAMETERS, INITIALIZATION, ...`. This places IMPORTS before PARAMETERS.

**Problem**: At PowerShell script scope, the `param()` block must be the first executable statement after the CBH header. Any executable statement before `param()` — including a dot-source — prevents script parameters from binding. So `IMPORTS` before `PARAMETERS` cannot be physically realized in a standalone `.ps1` file.

**Why it hasn't surfaced before**: Standalone scripts are the only role where the conflict can manifest. Among other roles, page-route and api-route files have only `ROUTE` sections; module files don't have script-level `param()`; shared-library files are forbidden from having IMPORTS. The two fully-refactored CC files (Backup.ps1, ReplicationMonitoring.ps1) are page-route files. The resolver is the first standalone-role file the spec has been applied to.

**Resolution**: Swap the order of `IMPORTS` and `PARAMETERS` in §4.2 itself. The change is a single word-order edit:

> Current: `CHANGELOG, IMPORTS, PARAMETERS, INITIALIZATION, ...`
> Amended: `CHANGELOG, PARAMETERS, IMPORTS, INITIALIZATION, ...`

This is preferable to a role-specific carve-out because:

1. **Standalone is the only role where both PARAMETERS and IMPORTS can co-exist in one file.** For modules, IMPORTS is allowed but PARAMETERS is forbidden, so changing their relative order doesn't affect modules — they only ever have IMPORTS at the top. For all other roles, neither section appears.
2. **`PARAMETERS → IMPORTS` is actually the more intuitive physical layout.** PowerShell `param()` blocks use built-in types (`[string]`, `[int]`, `[switch]`, `[Parameter()]`, `[ValidateSet()]`), not types from imports. Having the executable `param()` block immediately follow its CBH documentation (the `.PARAMETER` blocks) keeps related content adjacent rather than separating them with IMPORTS.
3. **One word-order change, no conditional logic.** No role-specific exceptions, no per-role parsing branches in the populator, no spec language about "standalone files do X while other files do Y."

**Spec amendment needed (next session)**: Edit §4.2 as shown above. Also update the populator's section-type-order check to expect the new canonical order. After the amendment lands, the resolver's `SECTION_TYPE_ORDER_VIOLATION` drift code goes away naturally with no file changes.

### Defect 2: §5.1 "chrome prefix" (`cc`) is dead language for PS files

**Description**: §5.1 lists three prefix forms: page prefix, chrome prefix (literal `cc`), and `(none)` sentinel.

**Problem**: The `Component_Registry.cc_prefix` column has a CHECK constraint requiring exactly three lowercase letters. No component can have `cc_prefix = 'cc'` (two characters). The "chrome prefix" form is therefore unreachable for any PS file.

**Spec amendment needed (next session)**: Either remove the chrome-prefix language from §5.1, or document that it's specifically inapplicable to PS files (and the rule exists only because the spec text was copied from the CSS/JS specs, where chrome classes literally start with `cc-`).

---

## Other follow-ups

### CDN chart.js references should be refactored to local chart.min.js

Two `<script src="https://cdn.jsdelivr.net/npm/chart.js">` references remain in:

- `PlatformMonitoring.ps1`
- `ServerHealth.ps1`

The local `chart.min.js` is already in `xFACts-ControlCenter/public/js/` and is cataloged. Replacing the CDN reference with `/js/chart.min.js` would:

1. Make these pages work offline / on the air-gapped FA-SQLDBB host
2. Resolve the last 2 `HTML_JS_FILE_UNRESOLVED` drift entries
3. Bring the pages in line with `ReplicationMonitoring.ps1` which already uses the local file

Not a session-blocking item. Worth doing during the next refactoring pass on those pages.

---

## Next session focus

### Primary: Populator spec compliance pass

All four populators (`Populate-AssetRegistry-CSS.ps1`, `Populate-AssetRegistry-HTML.ps1`, `Populate-AssetRegistry-JS.ps1`, `Populate-AssetRegistry-PS.ps1`) currently drift against `CC_PS_Spec.md`. They predate the spec. Bringing them into compliance is the next major lift. Each file is ~4,000–6,000 lines, so this is bigger than the resolver rewrite.

Notable populator-specific issues that will need attention during this pass:

- **Section banners**: Populators currently use `# CONFIGURATION: Paths and Discovery` and `# DOT-SOURCE SHARED INFRASTRUCTURE`-style headers, not the spec-prescribed `<# ============== ... ============== #>` banners
- **Comment bloat**: All four populators have heavy multi-paragraph comment blocks (especially around CSS variable mappings, AST walker logic, and drift code lookup tables). Trimming and tightening these is a stated goal
- **CHANGELOG entry concision**: Existing changelog entries tend toward narrative paragraphs. Goal is concise one-line entries with continuation only when genuinely needed
- **IMPORTS section**: Populators have dot-source statements outside any IMPORTS section, generating `MISPLACED_IMPORT` drift. Will need a proper IMPORTS banner emitted after the new canonical `PARAMETERS → IMPORTS` order (assuming §4.2 amendment lands first)

### Secondary: Spec amendments

The two amendments above — the §4.2 ordering swap and §5.1 chrome-prefix removal — should land first, before the populator pass. Both are small textual changes; the §4.2 one also requires a small populator update to expect the new order. Doing the spec amendments first means the populator pass can target zero drift instead of "zero drift except the known order violation."

### Tertiary: Verify resolver behavior is preserved

Should run the resolver against the new spec-compliant version end-to-end to confirm the orchestration still produces correct catalog state. The validation done in this session was incremental (changed populator → re-ran → checked counts), but the rewritten resolver itself wasn't yet validated as a complete end-to-end orchestrator. Quick sanity run early next session.

---

## Files delivered this session

Working copies (cumulative state) in `/mnt/user-data/outputs/`:

- `Populate-AssetRegistry-HTML.ps1` — basename fix applied to `Add-CssFileUsageRow` and `Add-JsFileUsageRow`
- `Populate-AssetRegistry-JS.ps1` — vendored anchor zone fix applied (one-line `$script:CurrentFileZone = 'cc'`)
- `Resolve-AssetRegistryReferences.ps1` — full spec-compliant rewrite (875 lines)

Drop-in snippets delivered inline for the two populator fixes (single-function or single-line changes); user applied to the production copies.

---

## Standing rules reaffirmed / lessons from this session

- **Read the spec fully before writing.** Initial resolver rewrite put `$ErrorActionPreference` in INITIALIZATION based on a loose reading of §4 ("setup function calls"). Populator correctly flagged it because §9.2 requires all top-level assignments to live in CONSTANTS or VARIABLES regardless of what they assign to. INITIALIZATION is for function *calls*, not assignments.
- **Multi-line `#` comments are accepted by the populator** as valid purpose comments, despite §9.2 saying "single-line `#` comment". The populator interprets the rule consistent with §13.1 ("runs of consecutive lines starting with `#`" are valid line comments). Useful for trimming populator comment bloat next session without going overboard on terseness.
- **`Get-SqlData` returns `$null` on empty result sets, not an empty array.** Wrap with `@(...)` when iterating to handle the no-rows case cleanly. Already applied in resolver functions.
- **Prefer fixing the spec over carving exceptions into it.** Initial impulse on the §4.2 conflict was to write a role-specific carve-out for standalone scripts. The cleaner answer was to fix the canonical ordering itself, since `PARAMETERS → IMPORTS` is the more intuitive layout independently of PowerShell language constraints and the swap has no downside in any other role. When a spec rule conflicts with reality, the rule is usually wrong, not reality.
- **One drift code per session-delivered file is acceptable when the drift code represents a known, flagged spec defect.** The resolver's single `SECTION_TYPE_ORDER_VIOLATION` is honest and pinpoint — it tells future readers exactly what's going on, and the drift goes to zero once §4.2 is amended.

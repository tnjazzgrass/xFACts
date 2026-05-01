# Asset_Registry Working Document

**Purpose**: Active scratchpad for the Asset_Registry pipeline build. Tracks decisions, environment state, open questions, and next-session pickup points. Will be discarded after pipeline goes live; permanent documentation will be HTML in the Control Center, harvesting relevant content from this doc.

---

## Where we left off (last session: 2026-05-01)

- Environment setup is **complete** for all three parsers
- JavaScript parsing finalized: **Node + acorn + acorn-walk**
- CSS parsing finalized: **Node + PostCSS + postcss-selector-parser**
- PowerShell parsing: built-in `[System.Management.Automation.Language.Parser]`
- All three approaches validated against real CC files (engine-events.* and bidata-monitoring.*); outputs are clean and complete
- **Next session pickup**: resolve remaining open schema questions, then DDL for `dbo.Asset_Registry`, then write extractor scripts in order: JS, then CSS, then PS, then orchestrator

---

## Project goal

Build `dbo.Asset_Registry`: a SQL-table-backed inventory cataloging every component (functions, classes, IDs, routes, etc.) across all Control Center source files. Single table; three per-language extractor scripts; one orchestrator; manual trigger from Admin page (sibling to Documentation Pipeline).

**Why it matters**: Answer "what's in this script" / "is there a function that does X" without grep. Library/inventory aspect is the primary value — not just compliance reporting.

---

## Architecture decisions (locked in)

### Naming
- Table: `dbo.Asset_Registry` (renamed from `CC_Component_Registry`)
- Schema: `dbo` (no CC prefix)
- Working doc: `Asset_Registry_Working_Doc.md` in `Planning/`
- Plan doc: needs rename `CC_Component_Registry_Plan.md` → `Asset_Registry_Plan.md`

### Scope and structure
- **Single table** for all asset types (not three per-language tables)
- **Three extractor scripts** + one orchestrator (mirrors Documentation Pipeline pattern)
- Scripts live flat at `E:\xFACts-PowerShell\` (sibling to Doc Pipeline scripts; flat structure, only `logs\` subfolder)
- Helper Node scripts live alongside (e.g., `parse-js.js`, `parse-css.js`)
- Manual trigger from Admin page (no scheduling)
- Standalone server (FA-SQLDBB), not AG

### Extraction depth: full (everything available)
- **Decision: extract everything reachable from each parser's AST.** Start permissive, trim later if noise is excessive.
- Includes: top-level declarations, nested functions, IIFE-wrapped code, methods on objects, function expressions assigned anywhere; CSS classes, IDs, element selectors, pseudos, @keyframes, @media-nested rules
- Rationale: easier to filter down than to bolt on additional capabilities later. A "give me everything I can possibly get" pass first lets the user see the full picture and decide.
- **Open**: for nested items (e.g., nested functions, rules inside @media), schema needs a way to express scope/parent context — see Open Questions.

### Versioning and history
- Current state only — no version history tracking
- Soft delete only (rows aren't physically removed; flagged inactive on rebuild)

### Methodology consistency
- AST-based parsing throughout (no hybrid regex/AST)
- Each language uses an industry-standard parser
- JS and CSS share the same Node runtime — unified mental model

---

## Environment setup state

### FA-SQLDBB — current installed state

```
C:\Program Files\
├── nodejs\                          ← Node.js 24.15.0 (npm 11.12.1) - actively used
│
├── nodejs-libs\                     ← Active parser libraries
│   ├── _downloads\                  (.tgz tarballs, kept for re-extraction)
│   └── node_modules\                ← Standard Node.js layout
│       ├── acorn\                   ← acorn 8.16.0 (JS parser)
│       ├── acorn-walk\              ← acorn-walk 8.3.5 (JS AST walker)
│       ├── postcss\                 ← postcss 8.5.12 (CSS parser)
│       ├── postcss-selector-parser\ ← postcss-selector-parser 7.1.1 (selector decomposition)
│       ├── nanoid\                  (postcss dep)
│       ├── picocolors\              (postcss dep)
│       ├── source-map-js\           (postcss dep)
│       ├── cssesc\                  (postcss-selector-parser dep)
│       └── util-deprecate\          (postcss-selector-parser dep)
│
└── dotnet-lib\                      ← LEGACY, can be cleaned up at session-end
    ├── Esprima.3.0.6\               ← UNUSED (abandoned)
    ├── ExCSS.4.3.1\                 ← UNUSED (abandoned)
    ├── Acornima.1.6.1\              ← UNUSED (abandoned)
    ├── System.Memory.4.5.5\
    ├── System.Buffers.4.5.1\
    ├── System.Numerics.Vectors.4.5.0\
    ├── System.Runtime.CompilerServices.Unsafe.4.5.3\
    └── _downloads\                  (.nupkg files for the abandoned libs)
```

**Cleanup deferred**: `dotnet-lib` folder can be removed once Asset_Registry pipeline is fully running.

### Per-language parser stack

| Language | Parser | Install location | Notes |
|---|---|---|---|
| PowerShell | `[System.Management.Automation.Language.Parser]` | Built into PS 5.1 | No external dependency. |
| JavaScript | acorn 8.16.0 (via Node subprocess) | `nodejs-libs\node_modules\acorn\` | Industry standard. Used by ESLint, Webpack, Rollup. |
| CSS | PostCSS 8.5.12 + postcss-selector-parser 7.1.1 (via Node subprocess) | `nodejs-libs\node_modules\postcss\` etc. | Industry standard. Used by Wikipedia, Twitter, Tailwind, Stylelint, Autoprefixer, Next.js, Vue.js. |

### How parsers will be loaded by extractor scripts

**JS/CSS (Node subprocess pattern)**:
```powershell
$nodeExe = 'C:\Program Files\nodejs\node.exe'
$parseScript = 'E:\xFACts-PowerShell\parse-js.js'   # or parse-css.js
$ast = Get-Content $file -Raw | & $nodeExe $parseScript | ConvertFrom-Json
```

**PS**:
```powershell
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $psFile, [ref]$null, [ref]$errors
)
```

### Path config in `dbo.GlobalConfig` (to be added next session)

```sql
INSERT INTO dbo.GlobalConfig (...) VALUES
    ('Platform', 'Libraries', 'node_exe',     'C:\Program Files\nodejs\node.exe',         'VARCHAR', '...'),
    ('Platform', 'Libraries', 'nodejs_libs',  'C:\Program Files\nodejs-libs',             'VARCHAR', '...');
```

(Need to verify exact GlobalConfig column names from DDL JSON before generating actual INSERT.)

---

## What we know works (validated)

### JS via acorn — validated against engine-events.js and bidata-monitoring.js

**engine-events.js**: 33 top-level FunctionDeclarations, 21 VariableDeclarations, 248 comments, all with line numbers. Async modifier and parameters captured.

**bidata-monitoring.js**: 38 top-level FunctionDeclarations, 9 VariableDeclarations, 110 comments, all with line numbers. async function `loadRefreshInterval` correctly identified at line 100.

**Comparison to yesterday's regex run**: strictly better. No single-character class bug equivalent. No false positives. Plus extracts: async flag, parameters, end lines, comment positions.

### CSS via PostCSS — validated against engine-events.css and bidata-monitoring.css

**engine-events.css**: 151 rules, 4 at-rules (all @keyframes), 108 comments, 104 distinct class names, 0 IDs, 14 element selectors. All with line numbers. Multi-selector decomposition works (e.g., `.xf-modal-header h3, .xf-modal-header .xf-modal-title` correctly split). Compound selectors decomposed (e.g., `.nav-link.nav-section-departmental.active` → 3 separate class nodes). All 4 @keyframes captured (`pulse`, `spin`, `page-refresh-spin`, `xfModalFadeIn`).

**bidata-monitoring.css**: 134 rules, 1 @media at-rule with its 2 nested rules accessible, 19 comments, 95 distinct class names. Class line numbers track all occurrences across all rules (e.g., `activity-card` at lines 92, 110, 111, 121, 127, 148, 149, 150, ...).

**Single-char class check**: PASS on both files. Yesterday's regex bug eliminated.

**Edge cases noted**:
- Universal selector `*` returns empty decomposition — special-case (likely benign, will skip).
- `0%`, `100%` inside @keyframes returned as `tag:0%`, `tag:100%` — selector-parser categorizes keyframe steps as tag types. Filter or accept based on registry preference.
- `body`, `a`, etc. correctly classified as element selectors (will need a column to mark these as low-value for the registry).

**Comparison to ExCSS test**: vastly better. ExCSS lacked line numbers, dropped @keyframes, threw on @media. PostCSS handles all of it cleanly.

### PS via built-in AST

Already used in other xFACts scripts. No exploratory test needed — the API is well-documented and stable.

---

## Methodology decisions per language

### JavaScript (acorn via Node subprocess)

**What we extract** (open to expansion based on first-pass review):
- FunctionDeclaration nodes (name, line, end line, params, async)
- VariableDeclaration nodes (kind, name, line, whether init is a function)
- ExpressionStatement nodes that are FunctionExpression/ArrowFunctionExpression assignments
- ClassDeclaration nodes (name, line, methods)
- Nested functions (with scope context — see Open Questions)
- Maybe: top-level fetch() calls (for API consumption tracking — TBD)
- Maybe: addEventListener registrations (for event tracking — TBD)

**Helper script**: `parse-js.js` (~50 lines) at `E:\xFACts-PowerShell\parse-js.js`. Reads JS from stdin, outputs full ESTree AST as JSON to stdout.

### CSS (PostCSS + postcss-selector-parser via Node subprocess)

**What we extract**:
- Class names from selectors (with line numbers; multiple lines if class appears in multiple rules)
- ID names from selectors (same)
- Element selectors with `is_element_selector` flag for low-value filtering
- @keyframes definitions (name, line, contained rules)
- @media block contents (with media query as scope context)
- @supports, @font-face, etc. (any other at-rule)
- Comments with line positions (potentially useful for section detection)
- Custom properties (`--foo: ...`) — TBD if useful

**Helper script**: `parse-css.js` (~80 lines) at `E:\xFACts-PowerShell\parse-css.js`. Reads CSS from stdin, outputs structured JSON: `{ rules: [...], atRules: [...], comments: [...], classNames: {name -> [lines]}, idNames: {...}, elementSelectors: {...} }`.

### PowerShell (built-in AST)

**What we extract**:
- FunctionDefinitionAst (name, line, params)
- ParamBlockAst at script level
- Pode route definitions (Add-PodeRoute calls — these are a Frost Arnett pattern)
- Module-level variable assignments

**Pode route detection** specifically: these are CommandAst nodes whose CommandElements start with "Add-PodeRoute". Worth its own extraction step since they map to API endpoints.

---

## Open questions (need decisions before extractors are final)

### 1. Schema: how to express scope/parent context for nested items

This applies to both nested functions in JS *and* nested rules inside @media in CSS.

If `engine-events.js` has function `validateInput` at line 245 inside `connectEngineEvents` at line 108, what does the row look like?
If `bidata-monitoring.css` has `.activity-grid` at line 607 inside `@media (max-width: 1200px)` at line 605, what does the row look like?

Options:
- **Option A**: Add `parent_component_id` FK column. Pure tree.
- **Option B**: Add `scope_path` VARCHAR column with dot-notation: `connectEngineEvents.validateInput` or `@media:max-width-1200.activity-grid`.
- **Option C**: Add both `scope_path` (for human-readable display) and `parent_component_id` (for joins).

**Recommendation**: Option C. Slight schema bloat, but makes both human reading and SQL joining easy. Need to confirm in next session.

### 2. IIFE handling

If a JS file is wrapped in `(function() { ... })()`, do we treat the IIFE as a module wrapper (extract things inside as if top-level), or as a regular function (extract things as nested)?

**TBD** — need to spot-check whether any CC files use IIFE patterns. If not, no decision needed yet.

### 3. Section banner detection

Block comments at line 1, 73, 85, etc. of engine-events.css and similar in bidata-monitoring.css are clearly section markers. Should we:
- **A**: Use the spec'd section banner format strictly (compliance violation if missing)
- **B**: Detect any block comment that looks like a section header (e.g., starts with `=====`) and use it
- **C**: Hybrid — prefer compliant banners, fall back to block-comment heuristic

**Recommendation**: C, but defer until we've extracted from a few files and see what actually exists.

### 4. Element selectors and pseudo-elements in CSS

Should `body { ... }` produce a row? What about `::-webkit-scrollbar` (a pseudo-element)?

**Recommendation**: Capture them but mark with a `selector_type` column (`class`, `id`, `element`, `pseudo`, `keyframe-step`) so they can be filtered out easily for "real" component queries while still being available for completeness reports.

### 5. What's "noise" in the first-pass extraction?

Per the "extract everything" decision, first-pass output may include things that aren't useful (e.g., every `var` declaration, every `body` element selector, every internal helper function). The decision criteria for trimming will be:
- Does it answer "what's in this file" or "is there a function that does X"?
- Is it consumed by other files (cross-file reference)?
- Is it part of the public API of the file?

Only after seeing first-pass output can we make these calls.

---

## Next session plan

In order:

1. **Quick housekeeping**:
   - Rename `CC_Component_Registry_Plan.md` → `Asset_Registry_Plan.md`
   - Add GlobalConfig entries for `node_exe` and `nodejs_libs` paths
   
2. **Resolve schema open questions** (especially #1 — parent/scope context for nested items). Look at the relevant DDL JSON for `dbo` schema to understand existing patterns.

3. **Generate DDL for `dbo.Asset_Registry`** — single object, validated against `xFACts_Development_Guidelines.md`. No Object_Metadata until DDL is approved and implemented.

4. **Write `parse-js.js`** helper — Node script that reads from stdin and emits structured JSON for JS files.

5. **Write the JS extractor PowerShell script** — `Extract-AssetsJS.ps1`. Tests against engine-events.js, bidata-monitoring.js. Outputs to a staging table or CSV first, before going to Asset_Registry.

6. **Write `parse-css.js`** helper — Node script that reads from stdin and emits structured JSON for CSS files.

7. **Write the CSS extractor PowerShell script** — `Extract-AssetsCSS.ps1`. Tests against engine-events.css, bidata-monitoring.css.

8. **Write the PS extractor** — `Extract-AssetsPS.ps1`. Built-in AST. Probably the simplest of the three since no subprocess needed.

9. **Orchestrator** — `Invoke-AssetPipeline.ps1`. Walks all CC source files, dispatches to the right extractor based on extension, handles soft-delete logic.

10. **Admin page integration** — sibling button to Documentation Pipeline trigger.

---

## Lessons learned (from environment setup)

Useful future reference if we ever revisit any of these.

### .NET Framework + PS 5.1 + NuGet = dependency hell

The single biggest takeaway. PowerShell 5.1 isn't a real NuGet resolver. NuGet packages target multiple frameworks (`netstandard2.0`, `net462`, `net8.0`, etc.) with different transitive dependency assumptions, and PS 5.1 picks the netstandard2.0 binaries but doesn't get the framework-bundled facades that newer .NET runtimes do. This means every NuGet package's runtime dependency cluster has to be manually assembled.

### Specific dependency cluster gotcha

When using `System.Memory` 4.5.5 (which ships AssemblyVersion 4.0.1.2 — package version ≠ assembly version), the matching `System.Runtime.CompilerServices.Unsafe` is **4.5.3** (assembly 4.0.4.1), NOT 6.0.0. Mixing them causes `PerTypeValues<T>` type initializer exception at runtime.

### ExCSS specifically

Tested against `engine-events.css`. Confirmed dealbreakers:
- ❌ No line number metadata on rules
- ❌ Multi-selector returned as single combined string
- ❌ `Rules` returned 0 entries while `StyleRules` returned 139 — @keyframes and @media lost
- ❌ `@media` access threw null-reference exception

### Esprima.NET specifically

Worked for tiny test strings but failed on real `engine-events.js` (~1300 lines) due to a different `System.Numerics.Vectors` version requirement (4.1.3.0 vs 4.1.4.0). Last GitHub refresh ~3 years old; maintainer (Sébastien Ros) explicitly handed off active development to Acornima.

### Acornima specifically

Modern fork of Esprima.NET. Active maintenance. Cleaner API. **But** — same dependency cluster issues on PS 5.1. Hit irreconcilable conflict between System.Memory 4.0.1.2 (which won't work with Unsafe 6.0.0) and Acornima's compile-time reference to Unsafe 6.0.0. Would have required assembly binding redirects at the powershell.exe.config level.

### Why Node + acorn / Node + PostCSS won

- Native to JS ecosystem — runs in its native environment, no impedance mismatch
- Tiny dependency clusters (acorn = 0 deps; postcss = 3 small deps; selector-parser = 2 small deps)
- Battle-tested — what every modern web tool uses
- Air-gappable — Node MSI installs offline, .tgz transfers offline, no internet at runtime
- Subprocess overhead is ~50-100ms per file — non-issue for ~80 files
- Trivial PowerShell integration via stdin/stdout JSON
- Standard `node_modules\` layout means modules find each other automatically

### Lesson about library layout

Initial install used `nodejs-libs\<package>\package\` layout, which broke when modules tried to require their dependencies (Node looks for `node_modules\<dep>\`, not the cute structure I'd built). Fixed by restructuring to standard `nodejs-libs\node_modules\<package>\` layout. **Lesson**: when integrating with an ecosystem, use that ecosystem's standard conventions, don't get clever. Same lesson as the .NET dependency mess.

---

## Out-of-scope / discarded approaches

Listed for reference so we don't reconsider these absent new information:

- **ExCSS** — no line numbers, dropped @keyframes/@media handling
- **Esprima.NET** — abandoned upstream, last active development ~3 years ago
- **Acornima** — same .NET Framework dependency conflicts as Esprima, no path forward without binding redirects
- **Hand-rolled CSS tokenizer** — was on the table after ExCSS rejected, but PostCSS exploration showed it gives us strictly more (proper selector decomposition, attribute handling, edge cases) for less code we own
- **Hand-rolled JS tokenizer** — would only catch known patterns, miss edge cases, no value over Node + acorn
- **Jurassic / NiL.JS / YantraJS** — JS interpreters not designed for AST-extraction workflows; same .NET dependency issues
- **Roslyn** — C#/VB analyzer, not for JS or CSS
- **PostCSS via .NET wrapper** — no good standalone .NET CSS parser exists

---

## Document maintenance

This document is updated at session end with: decisions made, environment changes, next pickup point. When pipeline goes live, content useful for permanent docs gets harvested into HTML inside Control Center, and this file is discarded.

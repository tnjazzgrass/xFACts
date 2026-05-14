# xFACts Catalog Initiative — Session Update Summary

**Session**: PS Populator Build + First-Run Validation
**Status**: PS populator complete, producing usable catalog data.
            Several follow-on items deferred to next session.

---

## What was delivered this session

### PS Populator (`Populate-AssetRegistry-PS.ps1`)

Built from scratch following the spec patterns established by CSS/JS.
First successful production run completed:

- **87 files scanned** across xFACts-PowerShell, xFACts-ControlCenter\scripts,
  xFACts-ControlCenter\scripts\routes, and xFACts-ControlCenter\scripts\modules
- **12,038 rows generated** representing every catalogable construct
- **31% drift rate** (3,731 rows with drift codes) — heavily concentrated
  in cosmetic/format concerns rather than structural problems
- **5 file roles** correctly classified: standalone, shared-library, module,
  page-route, api-route, plus new data-file role for `.psd1` inventory
- **80 shared functions** collected from `xFACts-OrchestratorFunctions.ps1`,
  `xFACts-AssetRegistryFunctions.ps1`, `xFACts-IndexFunctions.ps1`,
  `xFACts-Helpers.psm1` for cross-file USAGE resolution
- **3,829 SHARED + 1,321 LOCAL PS_FUNCTION_CALL USAGE rows** captured —
  full cross-file call graph now in catalog

### Schema changes applied

1. **CK_Asset_Registry_component_type** — dropped 4 stale values
   (`API_ROUTE`, `PS_ASSIGNMENT`, `PS_COMMAND`, `PS_PARAM`), added 19 new
   PS-spec values. Constraint now admits 59 values.
2. **Asset_Registry.component_type** widened from `VARCHAR(20)` to
   `VARCHAR(50)` to accommodate `PS_REMOVED_CODE_COMMENT` (23 chars) and
   future longer component type names.

### Helpers improvements (`xFACts-AssetRegistryFunctions.ps1`)

- **8 new PS-specific helpers added**: `Get-PSFileHeaderInfo`,
  `Find-PSAstNodes`, `Get-PSAstParentChain`, `Get-PSAstNodeLine`/
  `EndLine`/`Column`, `Test-IsTopLevelPSAst`,
  `Test-IsConditionallyDefinedPSAst`. Total helper count now 28.
- **Defensive field truncation** added: new `Get-TruncatedFieldValue`
  helper applied to all bounded VARCHAR columns inside
  `New-AssetRegistryRow`. Long values get a `...` suffix when truncated.
  Protects every populator (CSS, JS, HTML, PS) against `SqlBulkCopy`
  "invalid column length" failures from pre-spec content.

### Bug fixes during validation

Several iterations were required to get the first successful insert:

- **Variable-colon string interpolation parse error** (line 440) — fixed
  by wrapping `${FilePath}` and `${line}` in `${}` delimiters
- **`#>` inside outer `<# #>` block** (helpers file CHANGELOG) —
  prematurely closed the file's comment-based-help block; reworded to
  avoid the literal delimiter inside narrative text
- **`-FileType` parameter alias mismatch** — populator was passing
  Object_Registry `object_type` values; corrected to use the helper's
  populator-facing alias (`'PS'` not `'Script'`)
- **Page-route regex assumed nested folders** — actual structure is
  flat (`scripts\routes\Admin.ps1`, not `scripts\routes\Admin\Admin.ps1`).
  Regex corrected. 20+ files reclassified from `standalone` to
  `page-route`.
- **`Start-ControlCenter.ps1` missing from scan** — added
  `\scripts\` as a fourth scan root with de-duplication
- **`PS_EXPORT` array-literal extraction** — `Export-ModuleMember -function @(...)`
  with the `@()` form was producing one PS_EXPORT row containing the
  entire array as its name (1500+ chars truncated to 500). New
  `Get-ExportedNamesFromAst` recursive helper handles `ArrayExpressionAst`,
  `ParenExpressionAst`, `StatementBlockAst`, `PipelineAst`, and
  `CommandExpressionAst` wrappers. Result: 1 broken row → 37 properly-
  named rows for `xFACts-Helpers.psm1`.

### `server.psd1` cataloging

New `data-file` role for `.psd1` files. Pass 1 and Pass 2 short-circuit
to emit a single `PS_FILE` anchor row per data file — no AST walk,
no banner detection, no drift checks. Provides basic file inventory
without the cataloging machinery that doesn't apply to data hashtables.

---

## What was deferred to next session

### Component type consolidation (next session's primary work)

A separate planning doc has been drafted: `CC_Catalog_Consolidation_Plan.md`.
The work consolidates redundant file-type-prefixed component types
(e.g., `JS_FUNCTION`, `PS_FUNCTION` → universal `FUNCTION`) and folds
forbidden-pattern types into base types with drift codes
(e.g., `PS_WRITE_HOST` → `FUNCTION_CALL` row + `FORBIDDEN_WRITE_HOST`
drift). Reduces CK constraint admitted values from 59 to ~35-40 with
no loss of expressiveness. Touches all four populators, all four spec
docs, and requires a wipe-and-repopulate.

`*_FILE` types (`CSS_FILE`, `HTML_FILE`, `JS_FILE`, `PS_FILE`) are
kept with their prefixes — they're emitted from multiple file types
(as anchor rows from their own file_type, and as USAGE rows from HTML
when files are referenced via `<link>` / `<script>`).

### Spec decisions to make during consolidation

1. **Purpose comment syntactic form**: Should purpose comments require
   line-comment form (`#` / `//`) or be allowed in either form?
   Proposed position: line form only; block form reserved for function
   docblocks. Decision pending audit of JS populator behavior and
   sampling of existing conventions across files. New drift code
   `WRONG_PURPOSE_COMMENT_FORM` to be added once decided.

### Deferred PS populator bug fixes (tied to consolidation work)

1. **`PS_REMOVED_CODE_COMMENT` regex too loose** — false-positive
   matches on mid-sentence wrap-arounds and sub-section labels.
   Tighter patterns drafted in consolidation plan. Will be applied
   when the emitter migrates to `LINE_COMMENT` row + drift code form.

2. **`MISSING_PURPOSE_COMMENT` multi-line block collapse** — current
   detector picks only the last `#` line of a multi-line comment block
   as the purpose, producing trailing-fragment purposes and false
   `MISSING_PURPOSE_COMMENT` firings. Fix is in `Get-PrecedingPSLineComment`:
   collapse contiguous `#` lines on consecutive lines into one logical
   comment block. Applied at same time as the purpose-comment-form
   decision since both touch the same logic.

### PS_VARIABLE classification question (deferred earlier; still open)

The populator can't reliably distinguish "real declaration" from
"working state inside execution flow" at the AST level
(e.g., `$astCache = @{}` vs. `$PSScanRoots = @('...')`). Currently
treating all top-level assignments as `PS_VARIABLE` with drift codes.
**Deferred pending refactor experience** — once 5-10 PS files are
refactored to spec, real-world data will clarify whether the catalog
should distinguish these categories and how. Three resolution paths
captured (single PS_VARIABLE with new ambiguity drift code; new
PS_WORKING_STATE component type; pre-spec-files emit only file-level
signal).

---

## Current PS catalog summary

| Category | Count |
|---|---|
| Total PS rows | 12,038 |
| Files scanned | 87 |
| Rows with drift codes | 3,731 (31%) |
| PS_FUNCTION definitions | 508 (427 LOCAL + 81 SHARED) |
| PS_FUNCTION_CALL USAGE | 5,150 (1,321 LOCAL + 3,829 SHARED) |
| PS_ROUTE definitions | 245 |
| PS_PARAMETER | 1,285 |
| PS_VARIABLE | 795 |
| SQL_QUERY | 1,232 |
| RBAC_CHECK | 72 |
| GLOBALCONFIG_REF | 52 |
| Forbidden pattern rows (write-host, inline-banner, removed-code) | 2,277 |

Top drift categories (estimated from row counts; query needed for
exact distribution):

- `FORBIDDEN_INLINE_DIVIDER` — ~1,803 occurrences (PS_INLINE_BANNER rows)
- `MISSING_DOCBLOCK` + `MISSING_CMDLETBINDING` + `MISSING_SECTION_BANNER` on functions — high (most functions in pre-spec files trigger all three)
- `FORBIDDEN_WRITE_HOST` — ~467
- `MISSING_SECTION_BANNER` on PS_VARIABLE — ~795
- `MISSING_PURPOSE_COMMENT` — overlapping with above
- `FORBIDDEN_REMOVED_CODE_COMMENT` — 7 (with known false positives)

---

## Object_Registry gaps to resolve

Four files cataloged with NULL object_registry_id:

- `BootloaderTest.ps1` — test file scheduled for deletion (plus its
  JS counterpart). Not adding to registry; will be removed.
- `Populate-AssetRegistry-HTML.ps1` — populator file, needs registry entry
- `Populate-AssetRegistry-PS.ps1` — populator file, needs registry entry
- `server.psd1` — new data-file inventory, needs `Config` object_type
  registry entry

These don't block the catalog; they just leave FK linkage as NULL
until added.

---

## State of the broader initiative

- **CSS populator**: Production-ready, in use. Will receive consolidation
  pass updates next session.
- **JS populator**: Production-ready, in use. Will receive consolidation
  pass updates and purpose-comment-form audit next session.
- **HTML populator**: In development. Paused pending consolidation pass
  so HTML work proceeds against the cleaned-up taxonomy from the start.
- **PS populator**: Now production-ready as of this session.
- **Catalog**: Healthy and growing. CSS/JS/PS data all queryable; HTML
  pending populator completion.

---

## Next session opening agenda

1. Re-read `CC_Catalog_Consolidation_Plan.md` for context
2. Resolve the open questions in that doc (especially purpose-comment-form
   decision and JS_INLINE_* triplet target)
3. Execute the consolidation: CK ALTER → spec updates → 4 populator
   updates → wipe and repopulate → spot-check
4. Resume HTML populator development against the consolidated taxonomy

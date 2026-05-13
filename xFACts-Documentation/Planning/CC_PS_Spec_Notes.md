# CC PowerShell Spec — Preliminary Notes

*This is a working document capturing design decisions made during the PS spec design conversation. It is NOT the spec itself. It exists to bootstrap the next session, where the actual `CC_PS_Spec.md` is drafted. When the spec is published, this document is deleted along with the prior preliminary docs (`CC_PS_Module_Spec.md`, `CC_PS_Route_Spec.md`).*

*All decisions captured here are settled unless explicitly marked as open. Open questions appear at the end of the doc; everything else carries forward as agreed-upon design input.*

---

## 1. Context and scope

The PS spec is the fourth and final file-format spec in the Control Center File Format Initiative. It follows the CSS, JS, and HTML specs and consumes patterns from each (banner format, drift code granularity, populator pipeline ordering, catalog row anchoring). The corresponding PS populator does not yet exist; it will be built after the spec is published.

The spec covers **all PowerShell files in the xFACts codebase**, broken into five roles based on file location and naming convention:

| Role | Filename pattern | Location |
|---|---|---|
| Page route file | `<Name>.ps1` | `xFACts-ControlCenter/scripts/routes/` |
| API route file | `<Name>-API.ps1` | `xFACts-ControlCenter/scripts/routes/` |
| Module file | `<Name>.psm1` | `xFACts-ControlCenter/scripts/modules/` |
| Standalone script (collector, monitor, orchestrator, populator, documentation pipeline) | `<Name>.ps1` | `E:\xFACts-PowerShell\` |
| (Other locations) | `<Name>.ps1` | TBD — see open questions |

File role is determined unambiguously by filename pattern plus directory. The populator inspects the path of each scanned file and routes to the appropriate role-conditional rules.

The two preliminary docs `CC_PS_Module_Spec.md` and `CC_PS_Route_Spec.md` are consolidated into a single `CC_PS_Spec.md` per the initiative doc's §4.5 decision. Both prelim docs are deleted when the spec is published.

---

## 2. Division of labor between HTML and PS populators

Both populators read `.ps1` and `.psm1` files. They emit non-overlapping row sets distinguished by `file_type` (`HTML` vs `PS`).

### 2.1 HTML populator territory

The HTML populator walks the PS AST to locate string-emission constructs (here-strings, StringBuilder appends, return statements that yield HTML strings), then runs its own HTML tokenizer over the string contents. It emits rows with `file_type = 'HTML'` for:

- `HTML_FILE` (anchor row per scanned file containing HTML emission)
- `HTML_ID` (every `id="..."` attribute)
- `HTML_DATA_ATTRIBUTE` (every `data-*` attribute, including `data-action-*`)
- `HTML_TEXT` (text content + four user-facing attributes: `title`, `placeholder`, `aria-label`, `alt`)
- `HTML_ENTITY` (icons, glyphs, direct Unicode)
- `HTML_SVG` (inline `<svg>` markup)
- `HTML_COMMENT` (HTML comments inside markup)
- `HTML_EVENT_HANDLER` (forbidden `onclick=` etc., catalogued so drift can attach)
- `CSS_CLASS USAGE` (class attribute references)
- `CSS_FILE USAGE` (`<link rel="stylesheet">` references)
- `JS_FILE USAGE` (the `<script src=>` reference)

### 2.2 PS populator territory

The PS populator catalogs everything in `.ps1` and `.psm1` files that is **not** HTML markup. Emits rows with `file_type = 'PS'`. The proposed row types are listed in §6 of this doc.

### 2.3 Boundary cases

**PowerShell variable interpolation inside HTML strings.** A here-string contains `<h1>$browserTitle</h1>`. The HTML populator catalogs this as `HTML_TEXT` with `has_dynamic_content = TRUE`. The PS populator separately catalogs `$browserTitle` from the PS-side perspective (as a variable read within the function's body, not as its own row). Both populators see the same token from different angles.

**A function that returns HTML** (e.g., `Get-NavBarHtml`). The PS populator emits `PS_FUNCTION DEFINITION` for the function declaration plus rows for its parameters, comment-based-help, and body's PS-side constructs. The HTML populator emits `HTML_*` rows for the markup the function emits, with `parent_function` set to the function name. The two populators share the function name in their respective rows, making queries like "show me the HTML emitted by `Get-NavBarHtml`" trivial.

**`Add-PodeRoute` ScriptBlock parameter body.** A page route registration's scriptblock contains both PS logic and HTML emission. PS populator walks the entire scriptblock body; HTML populator walks only the here-strings inside it. Each emits its own non-overlapping rows.

### 2.4 API endpoints are PS-side, not HTML-side

An `Add-PodeRoute -Path '/api/...' -Method ...` call is a PowerShell function invocation that registers a web endpoint. The endpoint's path, method, authentication, and the fact-of-registration are all PS-side constructs cataloged via `API_ROUTE DEFINITION` rows. Any HTML emitted from the route's scriptblock is the HTML populator's territory.

---

## 3. Banner format (shared with CSS / JS / HTML specs)

PowerShell section banners use the canonical form shared across the file format initiative. The shape is identical to the CSS spec §3 form, with PowerShell `#` as the comment character:

```
# ============================================================================
# TYPE: NAME
# ----------------------------------------------------------------------------
# Description block: 1-5 sentences explaining what this section contains.
# Prefix: <prefix>
# ============================================================================
```

Rules carried forward from CSS spec §3:

- Two 76-character `=` bracket lines (opening and closing)
- One 76-character `-` separator between title and description
- Title line in the form `TYPE: NAME` where `TYPE` is from the section type closed enum for that file role
- Description: 1-5 sentences explaining what this section contains
- `Prefix:` line declaring the page/module prefix or `(none)`

Drift codes carried forward verbatim from CSS spec:
- `BANNER_INLINE_SHAPE`, `BANNER_INVALID_RULE_CHAR`, `BANNER_INVALID_RULE_LENGTH`
- `BANNER_INVALID_SEPARATOR_CHAR`, `BANNER_INVALID_SEPARATOR_LENGTH`
- `BANNER_MALFORMED_TITLE_LINE`, `BANNER_MISSING_DESCRIPTION`
- `UNKNOWN_SECTION_TYPE`, `SECTION_TYPE_ORDER_VIOLATION`
- `MISSING_PREFIX_DECLARATION`, `MALFORMED_PREFIX_VALUE`, `PREFIX_REGISTRY_MISMATCH`

These detect identical structural violations across CSS, JS, HTML, and PS files, sharing the same drift code identifiers.

---

## 4. File header

The file header is the canonical PowerShell comment-based-help block at the top of the file. It uses PowerShell's native `<# ... #>` block comment syntax with `.SYNOPSIS`, `.DESCRIPTION`, `.NOTES` (and optionally `.PARAMETER` for scripts that accept parameters):

```powershell
<#
.SYNOPSIS
    Short one-line description of what this file does.

.DESCRIPTION
    Longer description, 1-5 sentences. Explains the file's purpose,
    its role in the application, and what consumers should know.

.NOTES
    File Name : <Name>.ps1 (or .psm1)
    Location  : E:\xFACts-...\full\path
    Version   : Tracked in dbo.System_Metadata (component: <Component>)
#>
```

Notes:

- `.SYNOPSIS`, `.DESCRIPTION`, `.NOTES` are mandatory in all roles
- `.PARAMETER` blocks are mandatory for scripts/functions that declare `param()` blocks (the comment-based-help element must exist for each parameter)
- File header CONTAINS NO CHANGELOG — the CHANGELOG is a separate section per §5
- The file header appears as the first construct in the file, before any code

### 4.1 File header drift codes

- `MALFORMED_FILE_HEADER` — header missing, malformed, or required fields out of order
- `MISSING_SYNOPSIS` — no `.SYNOPSIS` element in header
- `MISSING_DESCRIPTION` — no `.DESCRIPTION` element in header
- `MISSING_NOTES` — no `.NOTES` element in header
- `MISSING_PARAMETER_DOC` — function/script accepts parameters but no `.PARAMETER` block for one or more of them
- `FORBIDDEN_CHANGELOG_IN_HEADER` — changelog content found inside the file header block (must be in dedicated CHANGELOG section per §5)

---

## 5. CHANGELOG section

The CHANGELOG is a dedicated section appearing **between the file header and the IMPORTS section** in roles that require it. It uses the standard banner format from §3.

### 5.1 CHANGELOG section shape

```powershell
<# File header per §4 #>

# ============================================================================
# CHANGELOG
# ----------------------------------------------------------------------------
# Date-stamped change history. Each entry is one ISO date line followed by an
# indented description. Entries appear most-recent first.
# Prefix: (none)
# ============================================================================

# 2026-05-13  Bootloader integration: route now emits data-page and data-prefix
#             attributes on <body>; removed inline onclick handlers.
# 2026-04-29  Phase 3d header refactor: page title now sourced from registry
#             via Get-PageHeaderHtml helper.

# ============================================================================
# IMPORTS
# ============================================================================
```

### 5.2 CHANGELOG entry format

- One entry per change, most-recent first (top of section)
- Each entry begins with `# YYYY-MM-DD  <description>` (ISO date format)
- Continuation lines for multi-line descriptions are indented to align with the start of the first line's description text
- No version numbers in entries (version lives in `System_Metadata`; the date is the timeline anchor)
- Entries are not separated by blank lines (run continuously)

### 5.3 CHANGELOG requirement by role

| File role | CHANGELOG section |
|---|---|
| Page route file | **Required** |
| API route file | **Forbidden** |
| Module file (`.psm1`) | **Forbidden** |
| Standalone script (collector, monitor, orchestrator, populator, documentation pipeline — anything in `E:\xFACts-PowerShell\`) | **Required** |

### 5.4 CHANGELOG drift codes

- `MISSING_CHANGELOG_SECTION` — CHANGELOG section absent in a role that requires it
- `FORBIDDEN_CHANGELOG_SECTION` — CHANGELOG section present in a role that forbids it
- `MALFORMED_CHANGELOG_ENTRY` — entry doesn't begin with `# YYYY-MM-DD  ` shape
- `MALFORMED_CHANGELOG_DATE` — date is not in ISO YYYY-MM-DD format
- `CHANGELOG_ORDER_VIOLATION` — entries not in most-recent-first order

### 5.5 CHANGELOG catalog rows

The CHANGELOG section is catalogable as its own row type — see §6. This gives queries like "show every CHANGELOG entry across all route files from the last 30 days" or "find files that haven't changed in 6 months" a direct catalog source.

---

## 6. Catalog row types

The PS populator emits the following row types. All carry `file_type = 'PS'`. Cross-population relationships (e.g., a PS function call resolving to a function definition in another file) are tracked via the same `DEFINITION`/`USAGE` mechanism CSS/JS/HTML use.

### 6.1 File-level structural rows

| Row type | Source construct | When emitted |
|---|---|---|
| `PS_FILE` | The file itself | One per scanned file. Universal anchor row (mirrors `CSS_FILE`, `HTML_FILE`). |
| `FILE_HEADER` | The `<# ... #>` block at the file's top | One per file. Same row type as CSS/JS — shared anchor row across all populators. |
| `COMMENT_BANNER` | Each section banner | One per banner. Same row type as CSS/JS — shared row across all populators. |
| `PS_CHANGELOG` | The dedicated CHANGELOG section | One section row plus one row per entry (TBD whether per-entry rows are warranted — see open questions). |

### 6.2 Declaration rows

| Row type | Source construct | When emitted |
|---|---|---|
| `PS_FUNCTION DEFINITION` | `function FunctionName { ... }` | One per function declaration. |
| `PS_PARAMETER DEFINITION` | Each named parameter inside a `param()` block | One per parameter, with attributes captured (`[Parameter(Mandatory)]`, type, default value, etc.). |
| `PS_VARIABLE DEFINITION` | Top-level or `$script:` variable assignment | One per declared variable. |
| `PS_EXPORT` | Each function/variable in `Export-ModuleMember` | One per exported name. Modules only. |

### 6.3 Routing rows

| Row type | Source construct | When emitted |
|---|---|---|
| `API_ROUTE DEFINITION` | `Add-PodeRoute -Method <M> -Path <P> -ScriptBlock {...}` | One per route registration. Page routes have one; API files have many; modules should have none. |
| `WEBSOCKET_ROUTE DEFINITION` | `Add-PodeRouteWebSocket ...` | One per WebSocket route registration. |
| `MIDDLEWARE DEFINITION` | `Add-PodeMiddleware ...` | One per middleware registration. |

### 6.4 Reference / usage rows

| Row type | Source construct | When emitted |
|---|---|---|
| `PS_FUNCTION USAGE` | Function call to a function defined in another PS file | One per call site. Resolved against `PS_FUNCTION DEFINITION` rows. |
| `SQL_QUERY USAGE` | `Invoke-XFActsQuery` / `Invoke-XFActsNonQuery` / `Invoke-CRS5ReadQuery` / `Invoke-AGReadQuery` / `Invoke-XFActsProc` call | One per call site. Captures SQL query text plus parameter shape. |
| `GLOBALCONFIG_REF USAGE` | Reference to a GlobalConfig setting (via direct query or helper) | One per reference. |
| `RBAC_CHECK USAGE` | `Get-UserAccess` / `Test-ActionPermission` / `Test-ActionEndpoint` call | One per check site. |
| `MODULE_IMPORT USAGE` | `Import-Module` / `Import-PodeModule` / dot-source statement | One per import. |

### 6.5 Content rows

| Row type | Source construct | When emitted |
|---|---|---|
| `PS_COMMENT` | Block or line comments that are not file header, banner, or comment-based-help | One per comment. |
| `PS_DOCBLOCK` | Comment-based-help block on a function (`<# .SYNOPSIS ... #>` form) | One per docblock. |

---

## 7. File role shapes

The structural rules above apply to all roles. The differences across roles are in **what content is allowed** — primarily which section types are valid and what kinds of declarations may appear.

### 7.1 Page route file

```powershell
<# File header per §4 #>

# ============================================================================
# CHANGELOG
# ============================================================================
# [Entries...]

# ============================================================================
# IMPORTS
# ----------------------------------------------------------------------------
# Module imports and dot-source statements required for this route.
# Prefix: <page-prefix>
# ============================================================================

# (Imports go here)

# ============================================================================
# CONSTANTS
# ----------------------------------------------------------------------------
# Script-scope constants used only by this route.
# Prefix: <page-prefix>
# ============================================================================

# (Constants go here)

# ============================================================================
# ROUTE: /<page-path>
# ----------------------------------------------------------------------------
# Page route registration. The ScriptBlock body contains the RBAC check,
# any inline data fetches needed for initial render, and the HTML emission.
# Prefix: <page-prefix>
# ============================================================================

Add-PodeRoute -Method Get -Path '/<page-path>' -Authentication 'ADLogin' -ScriptBlock {
    # Route handler body
}
```

**Section types (in order):** `CHANGELOG`, `IMPORTS`, `CONSTANTS`, `ROUTE`

**Rules:**
- CHANGELOG required (per §5.3)
- Exactly one ROUTE section per file (one page = one route registration)
- Function declarations are not permitted inside page route files — helpers belong in modules. Drift code: `FORBIDDEN_FUNCTION_IN_ROUTE`
- The Prefix value in section banners is the page's `cc_prefix` from `Component_Registry`

### 7.2 API route file

```powershell
<# File header per §4 #>

# ============================================================================
# IMPORTS
# ============================================================================

# ============================================================================
# CONSTANTS
# ============================================================================

# ============================================================================
# ROUTES: <Module>.<Component>
# ----------------------------------------------------------------------------
# All API endpoint registrations for this component. Each Add-PodeRoute
# inside this section is one endpoint; this section type is plural because
# one section can contain many endpoints.
# Prefix: <page-prefix>
# ============================================================================

Add-PodeRoute -Method Get -Path '/api/.../endpoint-1' -Authentication 'ADLogin' -ScriptBlock { ... }
Add-PodeRoute -Method Post -Path '/api/.../endpoint-2' -Authentication 'ADLogin' -ScriptBlock { ... }
# More endpoints...
```

**Section types (in order):** `IMPORTS`, `CONSTANTS`, `ROUTES` (plural)

**Rules:**
- No CHANGELOG section (forbidden per §5.3)
- One ROUTES section containing all endpoints (not one section per endpoint)
- Function declarations are not permitted — helpers belong in modules
- The Prefix value matches the page's `cc_prefix` (same as the corresponding page route file)

### 7.3 Module file (`.psm1`)

```powershell
<# File header per §4 #>

# ============================================================================
# IMPORTS
# ============================================================================

# ============================================================================
# CONSTANTS
# ----------------------------------------------------------------------------
# Module-scope constants and $script: state variables.
# Prefix: <module-prefix>  or  (none) for shared modules
# ============================================================================

$script:SomeConstant = ...

# ============================================================================
# FUNCTIONS: <Logical-Grouping>
# ----------------------------------------------------------------------------
# Description of what this group of functions does.
# Prefix: <module-prefix>  or  (none) for shared modules
# ============================================================================

function Get-Something { ... }
function Set-Something { ... }

# Multiple FUNCTIONS sections allowed in modules, grouped by purpose.
# (e.g., xFACts-Helpers.psm1 currently has separate concerns for
#  database, RBAC, navigation, audit logging — these become formal
#  FUNCTIONS sections.)

# ============================================================================
# EXPORT
# ----------------------------------------------------------------------------
# Module export declarations. Mandatory closing section.
# Prefix: (none)
# ============================================================================

Export-ModuleMember -Function Get-Something, Set-Something, ...
```

**Section types (in order):** `IMPORTS`, `CONSTANTS`, `FUNCTIONS` (one or more), `EXPORT`

**Rules:**
- No CHANGELOG section (forbidden per §5.3)
- Multiple FUNCTIONS sections allowed, each with its own banner (logical grouping)
- Mandatory EXPORT section at the end of the file containing `Export-ModuleMember`
- The Prefix value is the module's prefix (component-scoped modules) or `(none)` for shared modules like `xFACts-Helpers.psm1`

### 7.4 Standalone script

Standalone scripts (collectors, monitors, orchestrator scripts, populators, documentation pipeline) live in `E:\xFACts-PowerShell\` — not in `xFACts-ControlCenter`. They follow a shape similar to the page route file but with different section types reflecting their non-web nature:

```powershell
<# File header per §4 #>

# ============================================================================
# CHANGELOG
# ============================================================================

# ============================================================================
# IMPORTS
# ============================================================================

. "$PSScriptRoot\xFACts-OrchestratorFunctions.ps1"
# Other dot-sources or Import-Module statements...

# ============================================================================
# CONFIGURATION
# ----------------------------------------------------------------------------
# Script-scope configuration values: paths, scan roots, target servers.
# Prefix: (none)  [or script-specific prefix if applicable]
# ============================================================================

# ============================================================================
# FUNCTIONS: <Logical-Grouping>  [zero or more sections, optional]
# ============================================================================

# ============================================================================
# <SCRIPT-SPECIFIC SECTIONS>
# ============================================================================
# Standalone scripts may have role-specific section types reflecting their
# execution model — populators have PASS sections, collectors may have
# COLLECTOR sections, etc. The closed enum is TBD per script type.
```

**Section types:** `CHANGELOG`, `IMPORTS`, `CONFIGURATION`, `FUNCTIONS` (zero or more), plus script-type-specific sections

**Rules:**
- CHANGELOG required (per §5.3)
- Each standalone script is its own deployable unit with its own version line in System_Metadata
- The exact closed enum of section types depends on the script's sub-type (orchestrator, populator, collector). This is an open question — see §10.

The populator script we read as the reference (`Populate-AssetRegistry-CSS.ps1`) is a standalone script. Its section types include `DOT-SOURCE SHARED INFRASTRUCTURE`, `CONFIGURATION`, `SPEC CONSTANTS`, `SCRIPT-SCOPE STATE`, `POSTCSS COMMENT-SHAPE ADAPTER`, `FILE / ZONE / PARSER HELPERS`, `SELECTOR DECOMPOSITION`, `PASS 1`, `REGISTRY LOADS`, `ZONE-AWARE SHARED MAP ACCESSORS`, `CSS-SPECIFIC ROW EMITTERS`, `PER-COMPOUND DRIFT ATTRIBUTION`, `PER-SELECTOR ROW GENERATION`, `CSS VISITOR`, `PASS 2`, `PASS 3`, `OUTPUT BOUNDARY VALIDATION`, `OCCURRENCE INDEX COMPUTATION`, `SUMMARY OUTPUT`, `DATABASE WRITE`, `OBJECT_REGISTRY MISS REPORT`. Many of these are populator-specific; the spec will define which are general standalone-script types and which are sub-type-specific.

---

## 8. Function-level rules

These rules apply to every function declaration in modules (and to the rare function declarations in standalone scripts; functions are forbidden in route files per §7.1 and §7.2).

### 8.1 Mandatory function attributes

- `[CmdletBinding()]` is mandatory on every function
- `param()` block is mandatory if the function accepts parameters
- Comment-based-help docblock (`<# .SYNOPSIS ... #>`) is mandatory on every function

### 8.2 Optional function attributes

- `[OutputType()]` is optional (recommended for functions with deterministic return types)

### 8.3 Function naming

- Functions follow PowerShell's `Verb-Noun` convention
- The verb must be from PowerShell's approved verb list (run `Get-Verb` for the canonical list)
- The noun follows the file's prefix convention:
  - In shared modules (prefix `(none)`): noun is unprefixed (e.g., `Get-NavBarHtml`, `Invoke-XFActsQuery`)
  - In component-scoped modules: noun is prefixed with the module's prefix (e.g., `Get-BchBatchStatus` if the module's prefix is `bch`)
- Functions starting with an underscore or any non-letter character are forbidden

### 8.4 Function drift codes

- `MISSING_CMDLETBINDING` — function lacks `[CmdletBinding()]`
- `MISSING_PARAM_BLOCK` — function takes parameters but no `param()` block
- `MISSING_DOCBLOCK` — function lacks comment-based-help
- `MALFORMED_DOCBLOCK` — docblock is malformed (missing required elements, wrong order)
- `FORBIDDEN_FUNCTION_IN_ROUTE` — function declaration found inside a page route file
- `FORBIDDEN_FUNCTION_IN_API_ROUTE` — function declaration found inside an API route file
- `FORBIDDEN_NESTED_FUNCTION` — function declared inside another function's body
- `MALFORMED_FUNCTION_NAME` — function name doesn't follow `Verb-Noun` or violates prefix rules
- `UNAPPROVED_VERB` — function uses a verb not in PowerShell's approved verb list

---

## 9. Other drift code categories

This is a wide-net inventory. The actual spec will refine these and add codes for cases discovered during the populator build.

### 9.1 Variable drift codes

- `FORBIDDEN_GLOBAL_VARIABLE` — `$global:foo` usage
- `MALFORMED_SCRIPT_SCOPE` — variable that should be `$script:` declared at top-level without scope qualifier
- `MISSING_PREFIX_VARIABLE` — script-scope variable in a component-scoped file lacks the prefix
- `FORBIDDEN_AUTOVAR_REASSIGNMENT` — assignment to PowerShell automatic variables (e.g., `$args`, `$_`, `$matches`)

### 9.2 Module export drift codes (modules only)

- `MISSING_EXPORT_SECTION` — module has no `Export-ModuleMember` statement
- `FORBIDDEN_WILDCARD_EXPORT` — `Export-ModuleMember -Function *`
- `EXPORTED_FUNCTION_NOT_DEFINED` — function name in `Export-ModuleMember` doesn't match any declared function in the file
- `DEFINED_FUNCTION_NOT_EXPORTED` — function is declared but not in the export list

### 9.3 Route drift codes

- `MISSING_AUTHENTICATION` — `Add-PodeRoute` without `-Authentication`
- `WRONG_AUTHENTICATION_VALUE` — `-Authentication` is something other than `'ADLogin'`
- `MISSING_RBAC_CHECK` — page or API route doesn't call `Get-UserAccess` / `Test-ActionEndpoint` early in the scriptblock
- `INLINE_SCRIPTBLOCK_TOO_LARGE` — scriptblock body exceeds a threshold (TBD — see open questions)
- `MISSING_RESPONSE_WRITE` — route doesn't end with `Write-PodeHtmlResponse` / `Write-PodeJsonResponse`

### 9.4 SQL / data drift codes

- `INLINE_SQL_STRING_LITERAL` — SQL embedded as a plain string literal vs. using a here-string (the canonical form for SQL queries)
- `MISSING_PARAMETER_DECLARATION` — `Invoke-XFActsQuery` with `-Parameters` hashtable missing for queries containing `@variable` references
- `FORBIDDEN_LINKED_SERVER` — query references a linked server (linked servers are forbidden in production scripts per platform principles)

### 9.5 Formatting drift codes

- `EXCESS_BLANK_LINES` — more than one blank line between constructs
- `INCONSISTENT_INDENTATION` — mixed tabs and spaces, or inconsistent indent depth
- `TRAILING_WHITESPACE` — lines ending in whitespace
- `FORBIDDEN_COMMENT_STYLE` — comments not in one of the allowed forms (file header, banner, docblock, inline annotation)

### 9.6 Cross-file drift codes (Pass 3)

- `DUPLICATE_FUNCTION_DEFINITION` — same function name declared in multiple PS files
- `ORPHAN_FUNCTION_CALL` — function call doesn't resolve to any DEFINITION row in the catalog
- `ORPHAN_MODULE_IMPORT` — `Import-Module` references a module not present in the codebase

---

## 10. Open questions for next session

These are items that need decisions before or during spec drafting. Listed roughly by priority.

### 10.1 Section type closed enums per role

The proposed section types in §7 are sketches. The spec will lock the closed enum for each file role:

- **Page route:** `CHANGELOG`, `IMPORTS`, `CONSTANTS`, `ROUTE` — likely correct as-is, but verify against actual current route files during next session
- **API route:** `IMPORTS`, `CONSTANTS`, `ROUTES` — same
- **Module:** `IMPORTS`, `CONSTANTS`, `FUNCTIONS`, `EXPORT` — verify multi-FUNCTIONS sections work cleanly
- **Standalone script:** This is the messiest case. Populators have `PASS 1`, `PASS 2`, etc. as section types; collectors may have different needs; orchestrator scripts different again. Options:
  - Define one universal `standalone script` enum that covers all sub-types
  - Define sub-type-specific enums (populator, collector, orchestrator, documentation-pipeline)
  - Allow any section type with `BANNER_MALFORMED_TITLE_LINE` as the only structural rule (more permissive)

### 10.2 PS_CHANGELOG row granularity

Should the changelog emit one catalog row per section (carrying the entire changelog text as `raw_text`), or one row per entry (carrying just that entry's date and description)?

Trade-offs:
- One row per section: simpler populator, less granular queries
- One row per entry: per-entry filtering ("show changes from last 30 days") works cleanly, but more rows

Recommendation lean: **one row per entry** for queryability, with the section itself catalogued as a `COMMENT_BANNER` row.

### 10.3 Comment-based-help requirement granularity

The spec proposes `MISSING_SYNOPSIS`, `MISSING_DESCRIPTION`, `MISSING_NOTES`, `MISSING_PARAMETER_DOC` as separate drift codes (§4.1). Worth confirming this granularity vs. a single `MALFORMED_DOCBLOCK` umbrella code. The CSS spec experience suggests granular codes are better for refactor planning.

### 10.4 Scriptblock size threshold

`INLINE_SCRIPTBLOCK_TOO_LARGE` (§9.3) needs a concrete threshold. Options:
- Line count (e.g., > 100 lines body)
- Statement count
- Cyclomatic complexity-ish
- Skip this drift code entirely and let other checks (MISSING_FUNCTION_IN_ROUTE for embedded helpers, etc.) catch the problem indirectly

### 10.5 SQL embedding canonical form

If `INLINE_SQL_STRING_LITERAL` is drift, what's the canonical alternative? Options:
- Always use a here-string (the de facto current practice)
- Require here-string with a specific preceding comment shape
- Require dedicated SQL section banner inside the function (probably overkill)

### 10.6 Module location convention

Are modules outside `xFACts-ControlCenter/scripts/modules/` a thing? If `xFACts-OrchestratorFunctions.ps1` is a `.ps1` (not `.psm1`) dot-sourced rather than imported, how does the spec classify it? Worth checking the standalone script directory's contents.

### 10.7 Approved-verb policy

PowerShell's approved verb list (`Get-Verb`) is the standard. The spec proposes `UNAPPROVED_VERB` as drift. Confirm:
- Whether this should be drift or just a warning (some existing code might use unapproved verbs intentionally)
- Whether there's a project-specific extension to the approved list (e.g., `Confirm-` is approved, but is `Validate-` ever acceptable?)

### 10.8 Where exactly does CHANGELOG appear

§5.1 proposes CHANGELOG **between** the file header and the IMPORTS section. Verify this matches existing convention — `Populate-AssetRegistry-CSS.ps1` has the CHANGELOG inside the file header block (so to comply with this spec, it would need to move). Confirm the move is acceptable for all existing CHANGELOG-bearing files.

### 10.9 `param()` block on a script vs. on a function

PowerShell scripts can have a top-level `param()` block (script-level parameters), and individual functions also have `param()` blocks. Are both subject to the same rules? Drift codes for script-level `param()` should probably mirror function-level rules but apply to the script's file header context.

---

## 11. Populator architecture (PS-specific notes)

The PS populator will mirror the CSS populator's shape (three-pass model, shared helpers from `xFACts-AssetRegistryFunctions.ps1`, etc.) with these PS-specific deviations:

### 11.1 No external parser

CSS populator uses Node.js + PostCSS. JS populator uses Node.js + acorn. The PS populator uses **PowerShell's native AST** via `[System.Management.Automation.Language.Parser]::ParseInput()`. No external process invocation, no JSON adapter. The AST shape is different from PostCSS or acorn but the visitor pattern is the same.

The HTML populator is the existing reference for AST walking via the PowerShell native parser — it already does this for finding HTML emission constructs. The PS populator can borrow the AST walking machinery.

### 11.2 Role detection

The CSS populator has zones (cc vs docs). The PS populator has **file roles** (page route, API route, module, standalone). Role detection happens at the top of Pass 2 by combining filename pattern and directory:

```powershell
function Get-PsFileRole {
    param([string]$FullPath)

    $fileName = [System.IO.Path]::GetFileName($FullPath)
    $ext = [System.IO.Path]::GetExtension($fileName)

    if ($ext -eq '.psm1') { return 'module' }
    if ($FullPath -match 'scripts\\routes\\' -and $fileName -match '-API\.ps1$') { return 'api-route' }
    if ($FullPath -match 'scripts\\routes\\') { return 'page-route' }
    return 'standalone'
}
```

Once the role is detected, the role-conditional section-type validator and role-specific row emitters are selected via lookup tables.

### 11.3 Three-pass model

| Pass | Purpose |
|---|---|
| Pass 1 | Build cross-file function definition map (so Pass 2 can resolve `PS_FUNCTION USAGE` references). Mirrors CSS Pass 1's shared-scope class definition collection. |
| Pass 2 | Per-file walk: emit `PS_FILE` anchor, file header, section banners (including CHANGELOG), then walk the AST emitting declaration, routing, reference, and content rows. |
| Pass 3 | Codebase-level drift checks: `DUPLICATE_FUNCTION_DEFINITION`, `ORPHAN_FUNCTION_CALL`, `ORPHAN_MODULE_IMPORT`, etc. |

### 11.4 Estimated size

Following the CSS populator's pattern (2067 lines), with no external parser overhead but more row types and three file roles to handle: estimated **1500-2500 lines**.

### 11.5 Pipeline position

PS populator runs **last** in the standard pipeline: CSS → HTML → JS → PS. Cross-population references from PS USAGE rows resolve against existing CSS/JS/HTML DEFINITION rows. No circular dependencies.

---

## 12. Inheritance from CSS / JS / HTML specs

The PS spec inherits the following patterns from the existing specs. They are not re-derived; they are referenced and adapted.

| Pattern | Origin | PS adaptation |
|---|---|---|
| Banner format (76-char rules, separator, description, Prefix) | CSS spec §3 | Same shape, `#` comment character |
| File header structure | CSS / JS spec | PowerShell comment-based-help (`<# .SYNOPSIS #>`) |
| Drift code granularity | CSS spec (15.x), JS spec (19.x), HTML spec (15.x) | Same philosophy — each rule violation gets its own code |
| Catalog row anchors (FILE_HEADER, COMMENT_BANNER) | Shared across CSS, JS, HTML | Same row types reused |
| Universal `<FileType>_FILE` anchor row | CSS / HTML / JS pattern | `PS_FILE` is added |
| Three-pass populator model | CSS populator | Same model |
| Shared infrastructure (`xFACts-AssetRegistryFunctions.ps1`) | All populators | Same |
| Pipeline ordering | Catalog pipeline (CSS → HTML → JS → PS) | PS is last |

---

## 13. Files affected by spec adoption

These are all files in the codebase. When the PS spec is published, all of them are eligible for refactoring to spec.

**Page route files** (in `xFACts-ControlCenter/scripts/routes/`, no `-API` suffix):
- `Admin.ps1`, `ApplicationsIntegration.ps1`, `Backup.ps1`, `BatchMonitoring.ps1`, `BDLImport.ps1`, `BIDATAMonitoring.ps1`, `BootloaderTest.ps1` (deletable per initiative §4.10), `BusinessIntelligence.ps1`, `BusinessServices.ps1`, `ClientPortal.ps1`, `ClientRelations.ps1`, `DBCCOperations.ps1`, `DmOperations.ps1`, `FileMonitoring.ps1`, `Home.ps1`, `IndexMaintenance.ps1`, `JBossMonitoring.ps1`, `JobFlowMonitoring.ps1`, `PlatformMonitoring.ps1`, `ReplicationMonitoring.ps1`, `ServerHealth.ps1`

**API route files** (in `xFACts-ControlCenter/scripts/routes/`, with `-API` suffix):
- `Admin-API.ps1`, `ApplicationsIntegration-API.ps1`, `Backup-API.ps1`, `BatchMonitoring-API.ps1`, `BDLImport-API.ps1`, `BIDATAMonitoring-API.ps1`, `BusinessIntelligence-API.ps1`, `BusinessServices-API.ps1`, `ClientPortal-API.ps1`, `ClientRelations-API.ps1`, `DBCCOperations-API.ps1`, `DmOperations-API.ps1`, `engine-events-API.ps1` (deletable per initiative §4.9), `FileMonitoring-API.ps1`, `IndexMaintenance-API.ps1`, `JBossMonitoring-API.ps1`, `JobFlowMonitoring-API.ps1`, `PlatformMonitoring-API.ps1`, `ReplicationMonitoring-API.ps1`, `ServerHealth-API.ps1`

**Module files** (in `xFACts-ControlCenter/scripts/modules/`):
- `xFACts-Helpers.psm1`

**Other CC files** (in `xFACts-ControlCenter/scripts/`):
- `server.psd1` (data manifest — likely not subject to PS spec; verify in next session)
- `Start-ControlCenter.ps1` (startup script — likely standalone or new category)

**Standalone scripts** (in `E:\xFACts-PowerShell\`): The PowerShell manifest enumerates 44 files. These include populators, collectors, orchestrator scripts, and documentation pipeline scripts. Full list to be enumerated next session if needed.

---

## 14. Next-session agenda

The PS spec drafting session should:

1. Resolve the open questions in §10 (or carve them into explicit "deferred to spec amendment" status)
2. Draft `CC_PS_Spec.md` using the structure of CC_HTML_Spec.md as a template, with role-conditional rules expressed as sub-sections
3. Compare draft against representative existing files from each role (at minimum: one page route, one API route, `xFACts-Helpers.psm1`, one populator) to validate the rules describe real code accurately
4. Produce the final drift code reference (§15-equivalent)
5. Produce the compliance queries (§16-equivalent)
6. Delete the two preliminary docs (`CC_PS_Module_Spec.md`, `CC_PS_Route_Spec.md`) at the end of spec adoption
7. Delete this preliminary notes doc

---

*End of preliminary notes.*

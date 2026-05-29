# Control Center PowerShell File Format Specification

## 1. File structure

A PowerShell file consists of, in this exact order:

1. A file header (§2).
2. One or more sections (§3, §4).
3. End of file.

Nothing else may appear at file scope.

---

## 2. File header

The header is a single comment-based-help block at the top of the file, opening at line 1 with `<#` and closing with `#>`, followed by exactly one blank line before the first section banner. The header uses PowerShell's native `<# ... #>` syntax with recognized keyword elements in fixed order:

```powershell
<#
.SYNOPSIS
    <One-line summary of what this file does.>

.DESCRIPTION
    <Purpose paragraph, 1-5 sentences.>

.PARAMETER <ParamName>
    <Per-parameter description. One block per declared parameter.>

.COMPONENT
    <Component name from dbo.Component_Registry>

.NOTES
    File Name : <filename>.ps1
    Location  : <absolute path>

    FILE ORGANIZATION
    -----------------
    <Section banner title 1>
    <Section banner title 2>
    <Section banner title N>
#>
```

### 2.1 Rules

- Recognized keywords appear in this exact order: `.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER` (one per parameter, only if the file accepts parameters), `.COMPONENT`, `.NOTES`. When the file declares multiple parameters, the `.PARAMETER` blocks appear in the same order as the parameters in the `param()` block.
- `.COMPONENT` is required in every file regardless of role. The declared value matches a row in `dbo.Component_Registry.component_name`.
- All other comment-based-help keywords (`.EXAMPLE`, `.INPUTS`, `.OUTPUTS`, `.LINK`, `.ROLE`, `.FUNCTIONALITY`, `.FORWARDHELPTARGETNAME`, `.REMOTEHELPRUNSPACE`, `.EXTERNALHELP`) are forbidden.
- `.NOTES` contains exactly three fields, in this order: File Name, Location, FILE ORGANIZATION list. The header contains no Author, Date, Version, Function Inventory, or Deployment fields, and no inline `===` or `---` divider rules outside the `.NOTES` block's FILE ORGANIZATION separator.
- The FILE ORGANIZATION separator is exactly 17 `-` characters (`-----------------`), positioned on the single line immediately after the `FILE ORGANIZATION` label. Any other dash count, or a separator in any other position, is treated as a forbidden inline divider.
- The FILE ORGANIZATION list contains exactly the `<TYPE>: <NAME>` of each section banner, verbatim, in order. No numbering. No trailing description text.
- CHANGELOG content does not appear in the file header. Change history lives in the dedicated `CHANGELOG` section (§7) for roles that permit it.

---

## 3. Section banners

Each section opens with a single block comment (`<# ... #>`):

```
<# ============================================================================
   <TYPE>: <NAME>
   ----------------------------------------------------------------------------
   <Description: 1 to 5 sentences explaining what the section contains.>
   Prefix: <prefix>
   ============================================================================ #>
```

### 3.1 Rules

- The banner is one `<# ... #>` block comment, not a run of `#` line comments.
- Line 1 is `<#`, a single space, and exactly 76 `=` characters. The opening `<#` shares the line with the opening rule.
- The closing line is three spaces, exactly 76 `=` characters, a single space, and `#>`. The closing `#>` shares the line with the closing rule.
- Interior content lines (the title line, the `-` separator, the description, and the `Prefix:` line) are indented three spaces and contain no `#` prefix.
- The interior separator between the title line and the description is exactly 76 `-` characters (preceded by the three-space indent).
- `<TYPE>` is one of the recognized section types (§4), uppercase letters and underscores only.
- `<NAME>` is required and human-readable. Bare `<TYPE>` or `<TYPE>:` titles with no NAME are not permitted. Singleton sections use the fixed NAMEs from §4.4; multi-banner types (CONSTANTS, VARIABLES, FUNCTIONS) use author-chosen NAMEs describing the section's grouping.
- The description block is required.
- The `Prefix:` line declares exactly one prefix value (§5).
- Two banners in the same file may not share the same `<TYPE>: <NAME>` combination.
- A new banner is created for each distinct concept rather than expanding an existing banner.

### 3.2 Block-comment syntax is reserved

PowerShell's `<# ... #>` block-comment syntax is reserved for the three structural documentation forms in this spec:

- The file header (§2.1).
- Section banners (§3).
- Function docblocks (§8.1).

All other commentary uses `#` line comments.

---

## 4. Section types

| TYPE | Purpose |
|---|---|
| `CHANGELOG` | Date-driven change history. The single source of file-level change tracking. |
| `PARAMETERS` | The `[CmdletBinding()]` attribute and `param()` block declaring script-level parameters. |
| `IMPORTS` | Dot-source statements and `Import-Module` calls. |
| `INITIALIZATION` | One-time setup function calls that must execute at file scope before other content (e.g., `Initialize-XFActsScript`). |
| `CONSTANTS` | `$script:` declarations of immutable values. |
| `VARIABLES` | `$script:` declarations of mutable values. |
| `FUNCTIONS` | Function definitions. |
| `EXECUTION` | The procedural execution body. The "do the work" code at the end of a script. |
| `ROUTE` | `Add-PodeRoute` registrations (page-route and api-route files). |
| `EXPORTS` | `Export-ModuleMember` declaration (module files). |

### 4.1 Allowed types per role

| TYPE | page-route | api-route | module | standalone | shared-library |
|---|---|---|---|---|---|
| `CHANGELOG` | Allowed | Forbidden | Forbidden | Allowed | Allowed |
| `PARAMETERS` | Forbidden | Forbidden | Forbidden | Allowed | Forbidden |
| `IMPORTS` | Forbidden | Forbidden | Allowed | Allowed | Forbidden |
| `INITIALIZATION` | Forbidden | Forbidden | Forbidden | Allowed | Forbidden |
| `CONSTANTS` | Forbidden | Forbidden | Allowed | Allowed | Allowed |
| `VARIABLES` | Forbidden | Forbidden | Allowed | Allowed | Allowed |
| `FUNCTIONS` | Forbidden | Forbidden | Required (1+) | Allowed | Required (1+) |
| `EXECUTION` | Forbidden | Forbidden | Forbidden | Required (exactly 1) | Forbidden |
| `ROUTE` | Required (exactly 1) | Required (exactly 1) | Forbidden | Forbidden | Forbidden |
| `EXPORTS` | Forbidden | Forbidden | Required (exactly 1) | Forbidden | Forbidden |

### 4.2 Type ordering

When multiple section types appear, they appear in this fixed order: `CHANGELOG`, `PARAMETERS`, `IMPORTS`, `INITIALIZATION`, `CONSTANTS`, `VARIABLES`, `FUNCTIONS`, then either `EXECUTION` or `ROUTE` (mutually exclusive per the matrix), then `EXPORTS`.

### 4.3 Multiple banners of the same type

`CONSTANTS`, `VARIABLES`, and `FUNCTIONS` may have multiple banners, each with its own NAME (e.g., `FUNCTIONS: DATABASE HELPERS`, `FUNCTIONS: RBAC HELPERS`). Other types are singletons.

### 4.4 Singleton banner NAMEs

Singleton sections use fixed banner titles:

| TYPE | Banner title |
|---|---|
| `CHANGELOG` | `CHANGELOG: CHANGE HISTORY` |
| `PARAMETERS` | `PARAMETERS: SCRIPT PARAMETERS` |
| `IMPORTS` | `IMPORTS: SCRIPT DEPENDENCIES` |
| `INITIALIZATION` | `INITIALIZATION: SCRIPT INITIALIZATION` |
| `EXECUTION` | `EXECUTION: SCRIPT EXECUTION` |
| `ROUTE` (page-route) | `ROUTE: PAGE PATH` |
| `ROUTE` (api-route) | `ROUTE: API ENDPOINTS` |
| `EXPORTS` | `EXPORTS: MODULE EXPORTS` |

---

## 5. Prefix

Every section banner declares one prefix via the `Prefix:` line.

### 5.1 Prefix forms

Two forms, no others:

- **Page prefix** — the value of `Component_Registry.cc_prefix` for the file's component. Used in page-related files where identifiers carry the page prefix.
- **`(none)` sentinel** — used in files whose component has `cc_prefix = NULL` (shared-library files and modules whose component is a platform-wide bucket), and in section types that have no top-level identifiers to govern (CHANGELOG, IMPORTS, PARAMETERS, INITIALIZATION, EXECUTION, ROUTE, EXPORTS). Functions in these files use PowerShell's `Verb-Noun` naming, which is not subject to the platform's prefix discipline.

### 5.2 Banner prefix rules

- The `Prefix:` line is mandatory in every section banner.
- The `Prefix:` line declares exactly one value. Comma-separated values are not permitted.
- Sections without prefix-bearing identifiers (CHANGELOG, PARAMETERS, IMPORTS, INITIALIZATION, EXECUTION, ROUTE, EXPORTS) declare `Prefix: (none)`.
- Sections with prefix-bearing identifiers (CONSTANTS, VARIABLES, FUNCTIONS) declare the file's registered prefix from `Component_Registry.cc_prefix`. When the file's component has `cc_prefix = NULL`, these sections declare `Prefix: (none)`.
- `Component_Registry.cc_prefix` is the source of truth. When the file and registry disagree, the file is wrong.

### 5.3 Identifier prefix rules

- In prefixable files (files whose component has a non-NULL `cc_prefix`), top-level identifiers in CONSTANTS, VARIABLES, and FUNCTIONS sections begin with the file's registered prefix followed by an underscore.
- In files whose component has `cc_prefix = NULL`, top-level identifiers are not prefix-constrained. This applies regardless of file role, including standalone scripts (e.g., `Start-ControlCenter.ps1`), shared-library files, and modules whose components are platform-wide buckets. Function-naming rules in these files are governed by §8.1.

---

## 6. File roles

The file role determines which section types are allowed and which structural rules apply. Role is determined by file extension, filename pattern, and directory.

### 6.1 Role detection

| Role | Detection rule |
|---|---|
| `page-route` | `.ps1`, path is `xFACts-ControlCenter\scripts\routes\<Name>.ps1` with no `-API` suffix. |
| `api-route` | `.ps1`, path is `xFACts-ControlCenter\scripts\routes\<Name>-API.ps1`. |
| `module` | `.psm1`, path is `xFACts-ControlCenter\scripts\modules\<Name>.psm1`. |
| `standalone` | `.ps1`, path is `xFACts-PowerShell\<Name>.ps1` where `<Name>` does NOT start with `xFACts-`. The Pode application entry point at `xFACts-ControlCenter\scripts\Start-ControlCenter.ps1` is also treated as standalone. |
| `shared-library` | `.ps1`, path is `xFACts-PowerShell\xFACts-<Name>.ps1`. |

Files at other paths or with other extensions are out of scope for this spec — including any `.ps1` file in `xFACts-ControlCenter\scripts\` other than `Start-ControlCenter.ps1`. `.psd1` data files such as `server.psd1` are out of scope.

### 6.2 Role file structure

Each role's file consists of the role's required section types in order, with the role's allowed section types optionally interleaved per §4.1. The §4.4 singleton banner NAMEs apply.

#### 6.2.1 page-route

Required: `ROUTE` (exactly one, with NAME `PAGE PATH`, containing exactly one `Add-PodeRoute` call).
Allowed: `CHANGELOG`.
Forbidden: all other types.

#### 6.2.2 api-route

Required: `ROUTE` (exactly one, with NAME `API ENDPOINTS`, containing one or more `Add-PodeRoute` calls).
Allowed: none.
Forbidden: all other types.

#### 6.2.3 module

Required: `FUNCTIONS` (1+, with descriptive NAMEs), `EXPORTS` (exactly one, with NAME `MODULE EXPORTS`).
Allowed: `IMPORTS`, `CONSTANTS`, `VARIABLES`.
Forbidden: `CHANGELOG`, `PARAMETERS`, `INITIALIZATION`, `EXECUTION`, `ROUTE`.

#### 6.2.4 standalone

Required: `EXECUTION` (exactly one, with NAME `SCRIPT EXECUTION`).
Allowed: `CHANGELOG`, `PARAMETERS`, `IMPORTS`, `INITIALIZATION`, `CONSTANTS`, `VARIABLES`, `FUNCTIONS`.
Forbidden: `ROUTE`, `EXPORTS`.

#### 6.2.5 shared-library

Required: `FUNCTIONS` (1+).
Allowed: `CHANGELOG`, `CONSTANTS`, `VARIABLES`.
Forbidden: `PARAMETERS`, `IMPORTS`, `INITIALIZATION`, `EXECUTION`, `ROUTE`, `EXPORTS`.

---

## 7. CHANGELOG section

A CHANGELOG section is a dedicated banner-bounded section containing dated change entries. CHANGELOG is allowed in page-route, standalone, and shared-library files; forbidden in api-route and module files.

The CHANGELOG section produces a dedicated `PS_CHANGELOG_ENTRY` row per entry in the catalog. Change history is not embedded in the file header.

### 7.1 Entry format

```
# YYYY-MM-DD  <description>
#             <continuation lines, indented to align with description>
# YYYY-MM-DD  <description>
```

### 7.2 Rules

- One entry per dated change, most-recent first (at the top of the section).
- Each entry begins with `# YYYY-MM-DD  ` (ISO date, two spaces, then description).
- Continuation lines for multi-line descriptions are indented to align with the start of the first line's description text.
- No version numbers in entries.
- Entries run continuously with no blank lines between them.

---

## 8. Function definitions

A function definition has exactly one form. The four constructs inside the function body appear in this exact order: `[CmdletBinding()]`, then `param()`, then the comment-based-help docblock, then the function body code:

```powershell
function Verb-Noun {
    [CmdletBinding()]
    param( ... )

    <#
    .SYNOPSIS
        <One-line summary>
    .DESCRIPTION
        <Description>
    .PARAMETER <ParamName>
        <Per-parameter description>
    #>

    # Function body
}
```

### 8.1 Rules

- `[CmdletBinding()]` is mandatory on every function and appears first inside the function body.
- Every function declares a `param()` block, even if empty, immediately after `[CmdletBinding()]`. The `param()` block is required by `[CmdletBinding()]` and is the canonical place to declare parameter contracts. Functions taking pipeline input or no parameters at all still declare `param()` — empty, or with the appropriate parameter attributes.
- The comment-based-help docblock is mandatory on every function and is always positioned as the third construct inside the function body, after `[CmdletBinding()]` and `param()` and before the body code.
- The docblock requires `.SYNOPSIS` and `.DESCRIPTION`. `.PARAMETER` blocks correspond 1:1 with declared parameters — every declared parameter has a matching `.PARAMETER` block, no `.PARAMETER` block references a parameter the function does not declare, and the `.PARAMETER` blocks appear in the same order as the parameters in the `param()` block. `.COMPONENT`, `.NOTES`, `.EXAMPLE`, and other keywords are forbidden in function docblocks.
- Function names follow PowerShell's `Verb-Noun` convention. The verb is from the PowerShell approved verb list (`Get-Verb`). Functions starting with an underscore or any non-letter character are forbidden.
- In files whose component has a non-NULL `cc_prefix`, the noun half of the function name begins with that prefix followed by an underscore (e.g., `Get-bkp_OpenBatches` in a file with prefix `bkp`). In files whose component has `cc_prefix = NULL`, no prefix is applied; the function name is bare `Verb-Noun` (e.g., `Initialize-XFActsScript`).
- The `filter` keyword form is forbidden. All functions use the `function` keyword. Pipeline-processing functions declare an explicit `process { ... }` block instead.
- Function declarations are forbidden inside page-route and api-route files. Helpers belong in modules.
- Function declarations are forbidden inside another function's body.
- Function declarations are forbidden inside conditional or loop blocks (`if`, `else`, `while`, `do`, `for`, `foreach`, `switch`, `try`, `catch`, `finally`).
- Function names in non-shared files must not match the name of any function defined in a shared-library file.
- The same function name must not be declared by more than one PS file across the codebase.
- Function calls reference names defined in a cataloged PS file or in an imported external module.
- `[OutputType()]` is permitted but not required.

---

## 9. Variables and constants

Top-level declarations split into two kinds based on the section they live in:

- **`CONSTANTS` sections** — declarations of immutable values.
- **`VARIABLES` sections** — declarations of mutable values.

### 9.1 Declaration form

All top-level declarations use the `$script:` scope qualifier (lowercase):

```powershell
$script:DefaultTimeout = 300        # in a CONSTANTS section
$script:Config = @{}                # in a VARIABLES section
```

### 9.2 Rules

- `$script:` (lowercase) is the only permitted scope qualifier for top-level declarations.
- `$global:` declarations are forbidden anywhere in the file.
- Assignment to PowerShell automatic variables (`$args`, `$_`, `$matches`, `$input`, `$PSScriptRoot`, etc.) is forbidden.
- Each declaration gets its own statement. Chained assignments (`$a = $b = $c = 0`) are forbidden.
- Every constant and variable declaration is preceded by a single-line `#` comment describing its purpose.
- In prefixable files, identifier names begin with the file's registered prefix followed by an underscore. Naming convention is `PascalCase` after the prefix.
- A `$script:` declaration that appears outside a CONSTANTS or VARIABLES section is misplaced.

---

## 10. Imports

The `IMPORTS` section contains dot-source statements and `Import-Module` calls. Modules and standalone scripts may have IMPORTS sections; route files and shared-library files may not.

### 10.1 Rules

- One import per statement. Chained imports are forbidden.
- Import statements appear only in the IMPORTS section. An import elsewhere in the file is misplaced.
- Three forms are recognized:
  - Dot-source: `. "$PSScriptRoot\xFACts-OrchestratorFunctions.ps1"`
  - Import-Module by path: `Import-Module -Name "$PSScriptRoot\modules\xFACts-CCShared.psm1"`
  - Import-Module by name: `Import-Module SqlServer`
- A file with no imports omits the IMPORTS banner entirely, along with its FILE ORGANIZATION entry.

---

## 11. Routes

The `ROUTE` section contains `Add-PodeRoute` calls registering web endpoints. Page-route files have exactly one route under `ROUTE: PAGE PATH`; api-route files have one or more routes under `ROUTE: API ENDPOINTS`.

### 11.1 Rules

- Every `Add-PodeRoute` call declares `-Authentication 'ADLogin'`.
- Page routes call `Get-UserAccess` as the first statement of the scriptblock, before any other work. The result governs whether the route renders the page or returns an access-denied response.
- Every API route, regardless of HTTP method, calls `Test-ActionEndpoint` somewhere inside the scriptblock. The call is the universal hook point; `Test-ActionEndpoint` is fail-open for endpoints not yet registered in `RBAC_ActionRegistry`, so registration takes effect automatically when added.
- Page routes end the scriptblock with `Write-PodeHtmlResponse`.
- API routes end the scriptblock with `Write-PodeJsonResponse`.
- Page-route files emit HTML via PowerShell here-strings (`@"..."@`).

---

## 12. SQL query embedding

SQL queries embedded in PowerShell files use here-strings (`@"..."@`), not inline single-line string literals.

### 12.1 Canonical form

```powershell
$results = Invoke-XFActsQuery -Query @"
    SELECT
        column_a,
        column_b
    FROM dbo.MyTable
    WHERE column_c = @param_value
"@ -Parameters @{ param_value = 'foo' }
```

### 12.2 Rules

- Multi-line SQL queries use the `@"..."@` here-string form.
- `Invoke-Sqlcmd` calls include `-TrustServerCertificate`.
- `Invoke-Sqlcmd` calls include `-ApplicationName` for DMV attribution.
- Queries referencing `@parameter` placeholders are parameterized via `-Parameters @{...}` rather than constructed via string concatenation.
- Queries do not reference linked servers.

---

## 13. Comments

Five comment forms are recognized:

1. **File header** — a single `<# ... #>` block comment at line 1 (§2).
2. **Section banners** — `<# ... #>` block comments enclosing a section's title, description, and prefix declaration (§3).
3. **Docblocks** — `<# ... #>` block comments on function definitions (§8.1).
4. **`#` line comments** — single lines or runs of consecutive lines starting with `#`. Used for inline annotations preceding the code they describe.
5. **Sub-section markers** — single-line `#` comment of the form `# -- <Label> --`, used as a lightweight visual divider between groups of related declarations within a section (§13.2).

No other comment forms are recognized. `<# ... #>` block-comment syntax is reserved for forms 1, 2, and 3 above (§3.2).

### 13.1 Forbidden comment patterns

- Mini-banners using `# ---` characters.
- Box-drawing banners using `# ──` characters or other Unicode line-drawing.
- Headstone comments describing removed code.
- Free-standing block comments outside the file header, a section banner, or a function docblock.
- **Trailing comments** — a `#` comment at the end of a code line is forbidden. Comments lead the line they describe; they do not trail on it.

### 13.2 Sub-section markers

A sub-section marker is a single-line `#` comment that visually groups related declarations within a section. Used in long FUNCTIONS sections (and other sections with many declarations) where banner-level grouping would over-fragment the FILE ORGANIZATION list.

```
# -- <Label> --
```

- Shape: `#`, a single space, exactly two `-` characters, a single space, label text, a single space, exactly two `-` characters, end of line. No trailing whitespace.
- The label contains at least one letter.
- The marker is a single `#` line comment, not a run.
- The marker is preceded by at least one blank line. (The blank line preceding a section banner satisfies this when the marker is the first content after the banner.)
- The marker is followed by at least one blank line.
- Sub-section markers do not appear in the FILE ORGANIZATION list.
- Sub-section markers do not nest. A section may contain multiple markers, each grouping the declarations that follow it until the next marker or the section's end.

A new banner is created when the new content is a distinct concept with its own purpose; a sub-section marker is used when the new content is a sub-group of an existing concept within the same section.

---

## 14. Module exports

Module files declare exactly one `EXPORTS` section containing one or more `Export-ModuleMember` calls.

### 14.1 Rules

- `Export-ModuleMember -Function *` (wildcard) is forbidden. Exports are enumerated explicitly.
- Every function named in an `Export-ModuleMember` call is declared in the file.
- Every function declared in a module file appears in some `Export-ModuleMember` call.

---

## 15. Logging and output

Standalone scripts and shared-library files use `Write-Log` (defined in `xFACts-OrchestratorFunctions.ps1`) for operator-facing output. `Write-Host` calls are forbidden in these roles.

### 15.1 Rules

- Standalone and shared-library files use `Write-Log` for operator output. `Write-Host` calls are forbidden in these roles. Exempt files are enumerated below; amendments to this list require a spec amendment.

| Exempt file | Reason |
|---|---|
| `Start-xFACtsOrchestrator.ps1` | Platform entry-point script. Runs interactively with no orchestrator parent; uses `Write-Host` for direct operator feedback during startup. |

---

## 16. Forbidden patterns

| Pattern | Rule |
|---------|------|
| `.EXAMPLE`, `.INPUTS`, `.OUTPUTS`, `.LINK`, `.ROLE`, `.FUNCTIONALITY`, `.FORWARDHELPTARGETNAME`, `.REMOTEHELPRUNSPACE`, `.EXTERNALHELP` in file header | §2.1 |
| Author, Date, or Version field in file header | §2.1 |
| Function Inventory list in file header | §2.1 |
| Deployment block in file header | §2.1 |
| Inline `===` or `---` divider rules in file header outside the `.NOTES` FILE ORGANIZATION separator | §2.1 |
| `.NOTES` fields out of canonical order (File Name, Location, FILE ORGANIZATION) | §2.1 |
| `.PARAMETER` blocks not matching `param()` order | §2.1, §8.1 |
| Missing `.COMPONENT` declaration | §2.1 |
| `.COMPONENT`, `.NOTES`, `.EXAMPLE`, etc. in function docblock | §8.1 |
| Section type appearing in a role that forbids it | §4.1 |
| Bare-TYPE or `<TYPE>:` banner title with no NAME | §3.1 |
| Mini-banner using `# ---` | §13.1 |
| Box-drawing banner using `# ──` | §13.1 |
| Headstone comment describing removed code | §13.1 |
| Free-standing block comment outside header/banner/docblock | §13.1 |
| `$Script:` (capital S), `$global:`, or any non-`$script:` scope qualifier for top-level declarations | §9.2 |
| Assignment to PowerShell automatic variables | §9.2 |
| Chained variable assignment (`$a = $b = $c = 0`) | §9.2 |
| Function declared inside `if`/`else`/`while`/`do`/`for`/`foreach`/`switch`/`try`/`catch`/`finally` block | §8.1 |
| Function declared inside another function's body | §8.1 |
| Function name not following `Verb-Noun` with an approved verb | §8.1 |
| Function declaration in a page-route or api-route file | §8.1 |
| Function defined with the `filter` keyword | §8.1 |
| Function name matching a shared-library function's name | §8.1 |
| Duplicate function definition across PS files | §8.1 |
| Function call to a name not defined in any cataloged PS file | §8.1 |
| `Add-PodeRoute` without `-Authentication 'ADLogin'` | §11.1 |
| Page route without `Get-UserAccess` as first statement | §11.1 |
| API route without `Test-ActionEndpoint` call | §11.1 |
| Page route without `Write-PodeHtmlResponse` | §11.1 |
| API route without `Write-PodeJsonResponse` | §11.1 |
| Multi-line SQL as single-line string literal instead of here-string | §12.2 |
| `Invoke-Sqlcmd` without `-TrustServerCertificate` | §12.2 |
| `Invoke-Sqlcmd` without `-ApplicationName` | §12.2 |
| SQL query referencing `@parameter` without `-Parameters @{...}` | §12.2 |
| SQL query referencing linked server | §12.2 |
| `Export-ModuleMember -Function *` (wildcard) | §14.1 |
| `Export-ModuleMember` referencing undefined function | §14.1 |
| Module function declared but not exported | §14.1 |
| `Write-Host` in standalone or shared-library file (except files enumerated in §15.1) | §15.1 |
| Import statement outside the IMPORTS section | §10.1 |
| More than one blank line between top-level constructs | §16.1 |
| Trailing whitespace on a line | §16.1 |

### 16.1 Whitespace discipline

- Top-level constructs (sections, functions, declarations) are separated by exactly one blank line.
- Lines do not end with trailing whitespace.

---

## 17. Drift code reference

The populator emits a drift code on every spec violation. Each code maps to a single rule. This table is the contract between the spec and the populator.

| Code | Description | Rule |
|------|-------------|------|
| `MALFORMED_FILE_HEADER` | File header missing, malformed, or keywords out of order. | §2 |
| `FORBIDDEN_HEADER_KEYWORD` | File header contains a forbidden comment-based-help keyword. | §2.1 |
| `MALFORMED_NOTES_FIELD` | `.NOTES` block missing required fields or containing extra fields. | §2.1 |
| `NOTES_FIELD_ORDER_VIOLATION` | `.NOTES` fields appear out of canonical order (File Name, Location, FILE ORGANIZATION). | §2.1 |
| `PARAMETER_DOC_ORDER_VIOLATION` | `.PARAMETER` blocks do not appear in the same order as the parameters in the `param()` block. Applies to both file-header docblocks and function docblocks. | §2.1, §8.1 |
| `MISSING_COMPONENT_DECLARATION` | File header is missing a `.COMPONENT` declaration. | §2.1 |
| `FORBIDDEN_AUTHOR_IN_HEADER` | File header contains an Author bookkeeping field. | §2.1 |
| `FORBIDDEN_DATE_IN_HEADER` | File header contains a Date or Last Modified bookkeeping field. | §2.1 |
| `FORBIDDEN_VERSION_IN_HEADER` | File header contains a Version field. | §2.1 |
| `FORBIDDEN_FUNCTION_INVENTORY` | File header contains a function inventory list. | §2.1 |
| `FORBIDDEN_DEPLOYMENT_BLOCK` | File header contains a Deployment block. | §2.1 |
| `FORBIDDEN_INLINE_DIVIDER_IN_HEADER` | File header contains inline `===` or `---` divider rules outside `.NOTES`. | §2.1 |
| `FILE_ORG_MISMATCH` | FILE ORGANIZATION list does not match section banner titles verbatim, in order. | §2.1 |
| `FORBIDDEN_CHANGELOG_IN_HEADER` | CHANGELOG content appears in the file header instead of the dedicated section. | §2.1 |
| `MISSING_SECTION_BANNER` | A top-level construct appears outside any banner. | §3 |
| `BANNER_INVALID_RULE_CHAR` | Banner opening or closing rule line is not composed entirely of `=` characters. | §3.1 |
| `BANNER_INVALID_RULE_LENGTH` | Banner opening or closing rule line is not exactly 76 `=` characters. | §3.1 |
| `BANNER_INVALID_SEPARATOR_CHAR` | Banner middle separator is not composed entirely of `-` characters. | §3.1 |
| `BANNER_INVALID_SEPARATOR_LENGTH` | Banner middle separator is not exactly 76 `-` characters. | §3.1 |
| `BANNER_MALFORMED_TITLE_LINE` | Banner title line does not parse as `<TYPE>: <NAME>`. | §3.1 |
| `BANNER_MISSING_DESCRIPTION` | Banner has no description text. | §3.1 |
| `BANNER_MISSING_NAME` | Banner declares a bare `<TYPE>` or `<TYPE>:` with no NAME. | §3.1 |
| `DUPLICATE_BANNER_NAME` | Two banners in the same file share a `<TYPE>: <NAME>` combination. | §3.1 |
| `UNKNOWN_SECTION_TYPE` | Banner declares a TYPE not in the role's allowed list. | §4 |
| `SECTION_TYPE_ORDER_VIOLATION` | Section types appear out of order. | §4.2 |
| `FORBIDDEN_SECTION_TYPE` | Section type forbidden in this role appears in the file. | §4.1 |
| `MISSING_REQUIRED_SECTION` | A type required for this role is absent. | §4.1 |
| `DUPLICATE_SINGULAR_SECTION` | A type marked "exactly one" appears more than once. | §4.1 |
| `MALFORMED_SINGLETON_NAME` | A singleton section's banner title does not match the fixed value from §4.4. | §4.4 |
| `MISSING_PREFIX_DECLARATION` | Banner missing the `Prefix:` line. | §5.2 |
| `MALFORMED_PREFIX_VALUE` | Banner declares a `Prefix:` value that is neither the registered page prefix, nor `(none)`. | §5.2 |
| `PREFIX_REGISTRY_MISMATCH` | An identifier-bearing section (CONSTANTS, VARIABLES, FUNCTIONS) declares a `Prefix:` value that does not match the file's registered `Component_Registry.cc_prefix`. Identifier-free sections (CHANGELOG, IMPORTS, PARAMETERS, INITIALIZATION, EXECUTION, ROUTE, EXPORTS) declare `(none)` regardless of the file's registered prefix and are exempt from this check. | §5.2 |
| `MISPLACED_NONE_PREFIX` | An identifier-bearing section (CONSTANTS, VARIABLES, FUNCTIONS) declares `Prefix: (none)` in a file whose component has a registered (non-NULL) `cc_prefix`. The section's identifiers carry the file's registered prefix, so the banner must declare that prefix rather than `(none)`. | §5.2 |
| `PREFIX_MISSING` | Top-level identifier in a prefixable section does not begin with the file's registered prefix. | §5.3 |
| `PREFIX_MISMATCH` | Top-level identifier does not begin with the section's declared prefix. | §5.3 |
| `MALFORMED_CHANGELOG_ENTRY` | CHANGELOG entry does not begin with `# YYYY-MM-DD  `. | §7.2 |
| `MALFORMED_CHANGELOG_DATE` | CHANGELOG entry date is not in ISO YYYY-MM-DD format. | §7.2 |
| `CHANGELOG_ORDER_VIOLATION` | CHANGELOG entries appear out of most-recent-first order. | §7.2 |
| `FORBIDDEN_VERSION_IN_CHANGELOG` | A CHANGELOG entry contains a version literal. | §7.2 |
| `MISSING_DOCBLOCK` | Function has no comment-based-help docblock in its required position. | §8.1 |
| `MISPLACED_DOCBLOCK` | Function docblock is present but not in the required position (above the function declaration or after body code instead of immediately after `[CmdletBinding()]` and `param()`). | §8.1 |
| `MISSING_CMDLETBINDING` | Function declaration missing `[CmdletBinding()]`. | §8.1 |
| `MISSING_PARAM_BLOCK` | Function missing a `param()` block. | §8.1 |
| `MALFORMED_DOCBLOCK` | Function docblock missing required elements or in wrong order. | §8.1 |
| `MISSING_SYNOPSIS` | Function docblock missing `.SYNOPSIS`. | §8.1 |
| `MISSING_DESCRIPTION` | Function docblock missing `.DESCRIPTION`. | §8.1 |
| `MISSING_PARAMETER_DOC` | Function parameter without a matching `.PARAMETER` block in the docblock. | §8.1 |
| `EXTRA_PARAMETER_DOC` | Function docblock contains a `.PARAMETER` block for a parameter the function does not define. | §8.1 |
| `FORBIDDEN_DOCBLOCK_KEYWORD` | Function docblock contains `.COMPONENT`, `.NOTES`, `.EXAMPLE`, or other forbidden keywords. | §8.1 |
| `MALFORMED_FUNCTION_NAME` | Function name does not follow `Verb-Noun`. | §8.1 |
| `UNAPPROVED_VERB` | Function uses a verb not in PowerShell's approved verb list. | §8.1 |
| `FORBIDDEN_FUNCTION_IN_ROUTE` | Function declared in a page-route file. | §8.1 |
| `FORBIDDEN_FUNCTION_IN_API_ROUTE` | Function declared in an api-route file. | §8.1 |
| `FORBIDDEN_CONDITIONAL_DEFINITION` | Function declared inside a conditional or loop block. | §8.1 |
| `FORBIDDEN_NESTED_FUNCTION` | Function declared inside another function's body. | §8.1 |
| `FORBIDDEN_FILTER_FUNCTION` | Function declared with the `filter` keyword instead of `function`. | §8.1 |
| `SHADOWS_SHARED_FUNCTION` | Non-shared file defines a function whose name matches a shared-library export. | §8.1 |
| `DUPLICATE_FUNCTION_DEFINITION` | The same function name is declared by more than one PS file across the codebase. | §8.1 |
| `ORPHAN_FUNCTION_CALL` | Function call references a name not defined in any cataloged PS file. | §8.1 |
| `FORBIDDEN_SCOPE_QUALIFIER` | Declaration uses `$Script:` (capital S) or other non-`$script:` scope. | §9.2 |
| `FORBIDDEN_GLOBAL_VARIABLE` | Declaration uses `$global:` scope. | §9.2 |
| `FORBIDDEN_AUTOVAR_REASSIGNMENT` | Assignment to a PowerShell automatic variable. | §9.2 |
| `FORBIDDEN_MULTI_DECLARATION` | Chained assignment in a single statement. | §9.2 |
| `MISSING_CONSTANT_COMMENT` | Constant declaration not preceded by a purpose comment. | §9.2 |
| `MISSING_VARIABLE_COMMENT` | Variable declaration not preceded by a purpose comment. | §9.2 |
| `MISPLACED_DECLARATION` | `$script:` declaration appears outside a CONSTANTS or VARIABLES section. | §9.2 |
| `MISPLACED_IMPORT` | Import statement appears outside the IMPORTS section. | §10.1 |
| `MISSING_AUTHENTICATION` | `Add-PodeRoute` call lacks `-Authentication 'ADLogin'`. | §11.1 |
| `MISSING_RBAC_CHECK_PAGE` | Page route scriptblock does not call `Get-UserAccess` as the first statement. | §11.1 |
| `MISSING_RBAC_CHECK_API` | API route scriptblock does not call `Test-ActionEndpoint`. | §11.1 |
| `MISSING_RESPONSE_WRITE_PAGE` | Page route scriptblock does not end with `Write-PodeHtmlResponse`. | §11.1 |
| `MISSING_RESPONSE_WRITE_API` | API route scriptblock does not end with `Write-PodeJsonResponse`. | §11.1 |
| `FORBIDDEN_INLINE_SQL_LITERAL` | Multi-line SQL embedded as single-line string literal. | §12.2 |
| `MISSING_TRUST_SERVER_CERTIFICATE` | `Invoke-Sqlcmd` call lacks `-TrustServerCertificate`. | §12.2 |
| `MISSING_APPLICATION_NAME` | `Invoke-Sqlcmd` call lacks `-ApplicationName`. | §12.2 |
| `MISSING_PARAMETER_DECLARATION` | Query referencing `@parameter` lacks `-Parameters` hashtable. | §12.2 |
| `FORBIDDEN_LINKED_SERVER` | Query references a linked server. | §12.2 |
| `FORBIDDEN_INLINE_BANNER` | `# ---` mini-banner appears in the file. | §13.1 |
| `FORBIDDEN_BOX_DRAWING_BANNER` | `# ──` box-drawing banner appears in the file. | §13.1 |
| `FORBIDDEN_REMOVED_CODE_COMMENT` | Headstone comment describing removed code. | §13.1 |
| `MALFORMED_SUBSECTION_MARKER` | Comment uses the sub-section marker shape but violates the §13.2 rules (wrong dash count, missing label, inside a `#` comment run, or missing required surrounding blank line). | §13.2 |
| `FORBIDDEN_FREESTANDING_COMMENT_BLOCK` | Free-standing block comment outside header/banner/docblock. | §13.1 |
| `FORBIDDEN_TRAILING_COMMENT` | `#` comment appears at the end of a code line. Comments must lead, not trail. | §13.1 |
| `FORBIDDEN_WILDCARD_EXPORT` | `Export-ModuleMember -Function *` used. | §14.1 |
| `EXPORTED_FUNCTION_NOT_DEFINED` | `Export-ModuleMember` references a function not defined in the file. | §14.1 |
| `DEFINED_FUNCTION_NOT_EXPORTED` | Function declared in module file but not exported. | §14.1 |
| `MISSING_EXPORTS_SECTION` | Module file lacks an EXPORTS section. | §14.1 |
| `FORBIDDEN_WRITE_HOST` | `Write-Host` call in standalone or shared-library file (excluding files enumerated in §15.1). | §15.1 |
| `EXCESS_BLANK_LINES` | More than one blank line between top-level constructs. | §16.1 |
| `TRAILING_WHITESPACE` | Line ends with trailing whitespace. | §16.1 |

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

- Recognized keywords appear in this exact order: `.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER` (one per parameter, only if the file accepts parameters), `.COMPONENT`, `.NOTES`.
- `.COMPONENT` content matches a row in `dbo.Component_Registry.component_name`.
- All other comment-based-help keywords (`.EXAMPLE`, `.INPUTS`, `.OUTPUTS`, `.LINK`, `.ROLE`, `.FUNCTIONALITY`, `.FORWARDHELPTARGETNAME`, `.REMOTEHELPRUNSPACE`, `.EXTERNALHELP`) are forbidden.
- `.NOTES` contains exactly the three fields shown — File Name, Location, and FILE ORGANIZATION list. No author, date, version, or other metadata fields.
- The FILE ORGANIZATION list contains exactly the `<TYPE>: <NAME>` of each section banner, verbatim, in order. No numbering. No trailing description text.
- CHANGELOG content does not appear in the file header. Change history lives in the dedicated `CHANGELOG` section (§7) for roles that permit it.

---

## 3. Section banners

Each section opens with a multi-line `#` comment block:

```
# ============================================================================
# <TYPE>: <NAME>
# ----------------------------------------------------------------------------
# <Description, 1-5 sentences.>
# Prefix: <prefix>
# ============================================================================
```

### 3.1 Rules

- Every line of the banner begins with `# ` (hash + space).
- The opening and closing rule lines each consist of `#` plus 76 `=` characters.
- The middle separator is `#` plus 76 `-` characters.
- `<TYPE>` is one of the recognized section types (§4), uppercase letters and underscores only.
- `<NAME>` is required and human-readable. Bare `<TYPE>:` titles with no NAME are not permitted, including for singleton sections — use the role-specific singleton names from §4.4.
- The description block is required.
- The `Prefix:` line declares exactly one prefix value (§5).
- Two banners in the same file may not share the same `<TYPE>: <NAME>` combination.
- A new banner is created for each distinct concept rather than expanding an existing banner.

---

## 4. Section types

| TYPE | Purpose |
|---|---|
| `CHANGELOG` | Date-driven change history. The single source of file-level change tracking. |
| `IMPORTS` | Dot-source statements and `Import-Module` calls. |
| `PARAMETERS` | The `[CmdletBinding()]` attribute and `param()` block declaring script-level parameters. |
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
| `IMPORTS` | Forbidden | Forbidden | Allowed | Allowed | Forbidden |
| `PARAMETERS` | Forbidden | Forbidden | Forbidden | Allowed | Forbidden |
| `INITIALIZATION` | Forbidden | Forbidden | Forbidden | Allowed | Forbidden |
| `CONSTANTS` | Forbidden | Forbidden | Allowed | Allowed | Allowed |
| `VARIABLES` | Forbidden | Forbidden | Allowed | Allowed | Allowed |
| `FUNCTIONS` | Forbidden | Forbidden | Required (1+) | Allowed | Required (1+) |
| `EXECUTION` | Forbidden | Forbidden | Forbidden | Required (exactly 1) | Forbidden |
| `ROUTE` | Required (exactly 1) | Required (exactly 1) | Forbidden | Forbidden | Forbidden |
| `EXPORTS` | Forbidden | Forbidden | Required (exactly 1) | Forbidden | Forbidden |

### 4.2 Type ordering

When multiple section types appear, they appear in this fixed order: `CHANGELOG`, `IMPORTS`, `PARAMETERS`, `INITIALIZATION`, `CONSTANTS`, `VARIABLES`, `FUNCTIONS`, then either `EXECUTION` or `ROUTE` (mutually exclusive per the matrix), then `EXPORTS`.

### 4.3 Multiple banners of the same type

`CONSTANTS`, `VARIABLES`, and `FUNCTIONS` may have multiple banners, each with its own NAME (e.g., `FUNCTIONS: DATABASE HELPERS`, `FUNCTIONS: RBAC HELPERS`). Other types are singletons.

### 4.4 Singleton banner NAMEs

Singleton sections use fixed NAME values:

| TYPE | NAME |
|---|---|
| `CHANGELOG` | `CHANGELOG` (the banner title is just `CHANGELOG`) |
| `IMPORTS` | `IMPORTS` (the banner title is just `IMPORTS`) |
| `PARAMETERS` | `SCRIPT PARAMETERS` |
| `INITIALIZATION` | `SCRIPT INITIALIZATION` |
| `EXECUTION` | `SCRIPT EXECUTION` |
| `ROUTE` (page-route) | `PAGE PATH` |
| `ROUTE` (api-route) | `API ENDPOINTS` |
| `EXPORTS` | `MODULE EXPORTS` |

---

## 5. Prefix

Every section banner declares one prefix via the `Prefix:` line.

### 5.1 Prefix forms

Three forms, no others:

- **Page prefix** — the value of `Component_Registry.cc_prefix` for the file's component. Used in page-related files where identifiers carry the page prefix.
- **Chrome prefix** — the literal token `cc`. Reserved for files whose component's `cc_prefix` is `cc`.
- **`(none)` sentinel** — used in files whose component has `cc_prefix = NULL` (shared-library and shared-module files), and in section types that have no top-level identifiers to govern (CHANGELOG, IMPORTS, PARAMETERS, INITIALIZATION, EXECUTION, ROUTE, EXPORTS). Functions in shared-library files use PowerShell's `Verb-Noun` naming, which is not subject to the platform's prefix discipline.

### 5.2 Rules

- The `Prefix:` line is mandatory in every section banner.
- The `Prefix:` line declares exactly one value. Comma-separated values are not permitted.
- `Component_Registry.cc_prefix` is the source of truth for which prefix a file's identifiers carry. Files whose component has `cc_prefix = NULL` declare `Prefix: (none)` in every section banner.
- Sections without prefix-bearing identifiers (CHANGELOG, IMPORTS, PARAMETERS, INITIALIZATION, EXECUTION, ROUTE, EXPORTS) declare `Prefix: (none)`.
- Sections with prefix-bearing identifiers (CONSTANTS, VARIABLES, FUNCTIONS) declare the file's registered prefix from `Component_Registry`, or `Prefix: (none)` if the file's component has `cc_prefix = NULL`.
- Top-level identifiers in CONSTANTS and VARIABLES sections of prefixable files begin with the file's registered `cc_prefix` followed by an underscore.
- Function names in shared-library and shared-module files follow PowerShell's `Verb-Noun` convention and are exempt from the platform's prefix discipline. The verb must be from the PowerShell approved verb list.

---

## 6. File roles

The file role determines which section types are allowed and which structural rules apply. Role is determined by file extension, filename pattern, and directory.

### 6.1 Role detection

| Role | Detection rule |
|---|---|
| `page-route` | `.ps1`, path is `xFACts-ControlCenter\scripts\routes\<Name>.ps1` with no `-API` suffix. |
| `api-route` | `.ps1`, path is `xFACts-ControlCenter\scripts\routes\<Name>-API.ps1`. |
| `module` | `.psm1`, path is `xFACts-ControlCenter\scripts\modules\<Name>.psm1`. |
| `standalone` | `.ps1`, path is `xFACts-PowerShell\<Name>.ps1` where `<Name>` does NOT start with `xFACts-`. The special-case path `xFACts-ControlCenter\scripts\Start-ControlCenter.ps1` is also treated as standalone. |
| `shared-library` | `.ps1`, path is `xFACts-PowerShell\xFACts-<Name>.ps1`. |

Files at other paths or with other extensions are out of scope for this spec. `.psd1` data files such as `server.psd1` are out of scope.

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
Allowed: `CHANGELOG`, `IMPORTS`, `PARAMETERS`, `INITIALIZATION`, `CONSTANTS`, `VARIABLES`, `FUNCTIONS`.
Forbidden: `ROUTE`, `EXPORTS`.

#### 6.2.5 shared-library

Required: `FUNCTIONS` (1+).
Allowed: `CHANGELOG`, `CONSTANTS`, `VARIABLES`.
Forbidden: `IMPORTS`, `PARAMETERS`, `INITIALIZATION`, `EXECUTION`, `ROUTE`, `EXPORTS`.

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

A function definition has exactly one form:

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

- `[CmdletBinding()]` is mandatory on every function.
- `param()` block is mandatory if the function accepts parameters.
- Comment-based-help docblock is mandatory on every function. The docblock requires `.SYNOPSIS` and `.DESCRIPTION` and one `.PARAMETER` block per declared parameter. `.COMPONENT`, `.NOTES`, `.EXAMPLE`, and other keywords are forbidden in function docblocks.
- Function names follow PowerShell's `Verb-Noun` convention. The verb is from the PowerShell approved verb list (`Get-Verb`). Functions starting with an underscore or any non-letter character are forbidden.
- In prefixable files, function nouns begin with the file's registered prefix followed by an underscore. In shared-library and shared-module files, names follow `Verb-Noun` only.
- Function declarations are forbidden inside page-route and api-route files. Helpers belong in modules.
- Function declarations are forbidden inside another function's body.
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
  - Import-Module by path: `Import-Module -Name "$PSScriptRoot\modules\xFACts-Helpers.psm1"`
  - Import-Module by name: `Import-Module SqlServer`
- A file with no imports omits the IMPORTS banner entirely, along with its FILE ORGANIZATION entry.

---

## 11. Routes

The `ROUTE` section contains `Add-PodeRoute` calls registering web endpoints. Page-route files have exactly one route under `ROUTE: PAGE PATH`; api-route files have one or more routes under `ROUTE: API ENDPOINTS`.

### 11.1 Rules

- Every `Add-PodeRoute` call declares `-Authentication 'ADLogin'`.
- Page routes begin the scriptblock with a `Get-UserAccess` RBAC check.
- Every API route, regardless of HTTP method, invokes `Test-ActionEndpoint` inside the scriptblock. The call is the universal hook point; `Test-ActionEndpoint` is fail-open for endpoints not yet registered in `RBAC_ActionRegistry`, so registration takes effect automatically when added.
- Page routes end the scriptblock with `Write-PodeHtmlResponse`.
- API routes end the scriptblock with `Write-PodeJsonResponse`.
- Page-route files emit HTML via PowerShell here-strings (`@"..."@`). The HTML content is governed by the HTML spec.

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

- Multi-line SQL queries use the `@"..."@` here-string form. Single-line string literals containing SQL are drift.
- `Invoke-Sqlcmd` calls include `-TrustServerCertificate`.
- `Invoke-Sqlcmd` calls include `-ApplicationName` for DMV attribution.
- Queries referencing `@parameter` placeholders are parameterized via `-Parameters @{...}` rather than constructed via string concatenation.
- Queries do not reference linked servers.

---

## 13. Comments

Four comment forms are recognized:

1. **File header** — a single comment-based-help block at line 1 (§2).
2. **Section banners** — multi-line `#` comment blocks enclosing a section's title, description, and prefix declaration (§3).
3. **Docblocks** — comment-based-help blocks on function definitions (§8.1).
4. **Single-line `#` comments** — inline annotations inside function bodies and immediately preceding declarations.

No other comment forms are recognized.

### 13.1 Forbidden comment patterns

- Mini-banners using `# ---` characters.
- Box-drawing banners using `# ──` characters or other Unicode line-drawing.
- Headstone comments describing removed code.
- Sub-section markers (any inline divider comment not matching one of the four recognized forms).
- Free-standing block comments outside the file header, a section banner, or a function docblock.

---

## 14. Module exports

Module files declare exactly one `EXPORTS` section containing one or more `Export-ModuleMember` calls.

### 14.1 Rules

- `Export-ModuleMember -Function *` (wildcard) is forbidden. Exports are enumerated explicitly.
- Every function named in an `Export-ModuleMember` call must be declared in the file. References to undefined functions are drift.
- Every function declared in a module file should appear in some `Export-ModuleMember` call. A defined function not exported is drift.

---

## 15. Logging and output

Standalone scripts and shared-library files use `Write-Log` (defined in `xFACts-OrchestratorFunctions.ps1`) for operator-facing output. `Write-Host` calls are forbidden in these roles.

### 15.1 Rules

- `Write-Host` calls in standalone or shared-library files are drift. The exception is `Start-xFACtsOrchestrator.ps1` (the platform entry-point script) which legitimately uses `Write-Host` for direct operator output.

---

## 16. Forbidden patterns

| Pattern | Rule |
|---------|------|
| `.EXAMPLE`, `.INPUTS`, `.OUTPUTS`, `.LINK`, `.ROLE`, `.FUNCTIONALITY`, `.FORWARDHELPTARGETNAME`, `.REMOTEHELPRUNSPACE`, `.EXTERNALHELP` in file header | §2.1 |
| `.COMPONENT`, `.NOTES`, `.EXAMPLE`, etc. in function docblock | §8.1 |
| Section type appearing in a role that forbids it | §4.1 |
| Mini-banner using `# ---` | §13.1 |
| Box-drawing banner using `# ──` | §13.1 |
| Headstone comment describing removed code | §13.1 |
| Sub-section marker comment | §13.1 |
| Free-standing block comment outside header/banner/docblock | §13.1 |
| `$Script:` (capital S), `$global:`, or any non-`$script:` scope qualifier for top-level declarations | §9.2 |
| Assignment to PowerShell automatic variables | §9.2 |
| Chained variable assignment (`$a = $b = $c = 0`) | §9.2 |
| Function declared inside `if`/`while`/`do`/`for`/`try`/`catch`/`switch` block | §8.1 |
| Function declared inside another function's body | §8.1 |
| Function name not following `Verb-Noun` with an approved verb | §8.1 |
| Function declaration in a page-route or api-route file | §8.1 |
| `Add-PodeRoute` without `-Authentication 'ADLogin'` | §11.1 |
| Page route without `Get-UserAccess` RBAC check | §11.1 |
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
| `Write-Host` in standalone or shared-library file (except `Start-xFACtsOrchestrator.ps1`) | §15.1 |
| Import statement outside the IMPORTS section | §10.1 |
| More than one blank line between top-level constructs | — |
| Trailing whitespace on a line | — |

---

## 17. Drift code reference

The populator emits a drift code on every spec violation. Each code maps to a single rule. This table is the contract between the spec and the populator.

| Code | Description | Rule |
|------|-------------|------|
| `MALFORMED_FILE_HEADER` | File header missing, malformed, or keywords out of order. | §2 |
| `FORBIDDEN_HEADER_KEYWORD` | File header contains a forbidden comment-based-help keyword. | §2.1 |
| `MALFORMED_NOTES_FIELD` | `.NOTES` block missing required fields or containing extra fields. | §2.1 |
| `FILE_ORG_MISMATCH` | FILE ORGANIZATION list does not match section banner titles verbatim, in order. | §2.1 |
| `FORBIDDEN_CHANGELOG_IN_HEADER` | CHANGELOG content appears in the file header instead of the dedicated section. | §2.1 |
| `MISSING_SECTION_BANNER` | A top-level construct appears outside any banner. | §3 |
| `BANNER_INVALID_RULE_CHAR` | Banner opening or closing rule line is not `#` plus `=` characters. | §3.1 |
| `BANNER_INVALID_RULE_LENGTH` | Banner opening or closing rule line is not exactly `#` plus 76 `=`. | §3.1 |
| `BANNER_INVALID_SEPARATOR_CHAR` | Banner middle separator is not `#` plus `-` characters. | §3.1 |
| `BANNER_INVALID_SEPARATOR_LENGTH` | Banner middle separator is not exactly `#` plus 76 `-`. | §3.1 |
| `BANNER_MALFORMED_TITLE_LINE` | Banner title line does not parse as `# <TYPE>: <NAME>`. | §3.1 |
| `BANNER_MISSING_DESCRIPTION` | Banner has no description text. | §3.1 |
| `BANNER_MISSING_NAME` | Banner declares `<TYPE>:` with no NAME. | §3.1 |
| `DUPLICATE_BANNER_NAME` | Two banners in the same file share a `<TYPE>: <NAME>` combination. | §3.1 |
| `UNKNOWN_SECTION_TYPE` | Banner declares a TYPE not in the role's allowed list. | §4 |
| `SECTION_TYPE_ORDER_VIOLATION` | Section types appear out of order. | §4.2 |
| `FORBIDDEN_SECTION_TYPE` | Section type forbidden in this role appears in the file. | §4.1 |
| `MISSING_REQUIRED_SECTION` | A type required for this role is absent. | §4.1 |
| `DUPLICATE_SINGULAR_SECTION` | A type marked "exactly one" appears more than once. | §4.1 |
| `MALFORMED_SINGLETON_NAME` | A singleton section's NAME does not match the fixed value from §4.4. | §4.4 |
| `MISSING_PREFIX_DECLARATION` | Banner missing the `Prefix:` line. | §5.2 |
| `MALFORMED_PREFIX_VALUE` | Banner declares a `Prefix:` value that is neither the registered page prefix, `cc`, nor `(none)`. | §5.2 |
| `PREFIX_REGISTRY_MISMATCH` | Banner's declared prefix does not match `Component_Registry.cc_prefix` for the file's component. | §5.2 |
| `PREFIX_MISSING` | Top-level identifier in a prefixable section does not begin with the file's registered prefix. | §5.2 |
| `PREFIX_MISMATCH` | Top-level identifier does not begin with the section's declared prefix. | §5.2 |
| `MISSING_DOCBLOCK` | Function declaration not preceded by a comment-based-help docblock. | §8.1 |
| `MISSING_CMDLETBINDING` | Function declaration missing `[CmdletBinding()]`. | §8.1 |
| `MISSING_PARAM_BLOCK` | Function with parameters missing a `param()` block. | §8.1 |
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
| `SHADOWS_SHARED_FUNCTION` | Non-shared file defines a function whose name matches a shared-library export. | §8.1 |
| `MALFORMED_CHANGELOG_ENTRY` | CHANGELOG entry does not begin with `# YYYY-MM-DD  `. | §7.2 |
| `MALFORMED_CHANGELOG_DATE` | CHANGELOG entry date is not in ISO YYYY-MM-DD format. | §7.2 |
| `CHANGELOG_ORDER_VIOLATION` | CHANGELOG entries appear out of most-recent-first order. | §7.2 |
| `FORBIDDEN_VERSION_IN_CHANGELOG` | A CHANGELOG entry contains a version literal. | §7.2 |
| `FORBIDDEN_SCOPE_QUALIFIER` | Declaration uses `$Script:` (capital S) or other non-`$script:` scope. | §9.2 |
| `FORBIDDEN_GLOBAL_VARIABLE` | Declaration uses `$global:` scope. | §9.2 |
| `FORBIDDEN_AUTOVAR_REASSIGNMENT` | Assignment to a PowerShell automatic variable. | §9.2 |
| `FORBIDDEN_MULTI_DECLARATION` | Chained assignment in a single statement. | §9.2 |
| `MISSING_CONSTANT_COMMENT` | Constant declaration not preceded by a purpose comment. | §9.2 |
| `MISSING_VARIABLE_COMMENT` | Variable declaration not preceded by a purpose comment. | §9.2 |
| `MISPLACED_DECLARATION` | `$script:` declaration appears outside a CONSTANTS or VARIABLES section. | §9.2 |
| `MISPLACED_IMPORT` | Import statement appears outside the IMPORTS section. | §10.1 |
| `MISSING_AUTHENTICATION` | `Add-PodeRoute` call lacks `-Authentication 'ADLogin'`. | §11.1 |
| `MISSING_RBAC_CHECK_PAGE` | Page route scriptblock does not begin with `Get-UserAccess`. | §11.1 |
| `MISSING_RBAC_CHECK_API` | API route scriptblock does not call `Test-ActionEndpoint`. | §11.1 |
| `MISSING_RESPONSE_WRITE_PAGE` | Page route scriptblock does not end with `Write-PodeHtmlResponse`. | §11.1 |
| `MISSING_RESPONSE_WRITE_API` | API route scriptblock does not end with `Write-PodeJsonResponse`. | §11.1 |
| `INLINE_SQL_STRING_LITERAL` | Multi-line SQL embedded as single-line string literal. | §12.2 |
| `MISSING_TRUST_SERVER_CERTIFICATE` | `Invoke-Sqlcmd` call lacks `-TrustServerCertificate`. | §12.2 |
| `MISSING_APPLICATION_NAME` | `Invoke-Sqlcmd` call lacks `-ApplicationName`. | §12.2 |
| `MISSING_PARAMETER_DECLARATION` | Query referencing `@parameter` lacks `-Parameters` hashtable. | §12.2 |
| `FORBIDDEN_LINKED_SERVER` | Query references a linked server. | §12.2 |
| `FORBIDDEN_WILDCARD_EXPORT` | `Export-ModuleMember -Function *` used. | §14.1 |
| `EXPORTED_FUNCTION_NOT_DEFINED` | `Export-ModuleMember` references a function not defined in the file. | §14.1 |
| `DEFINED_FUNCTION_NOT_EXPORTED` | Function declared in module file but not exported. | §14.1 |
| `MISSING_EXPORTS_SECTION` | Module file lacks an EXPORTS section. | §14.1 |
| `FORBIDDEN_WRITE_HOST` | `Write-Host` call in standalone or shared-library file (excluding entry-point exemption). | §15.1 |
| `FORBIDDEN_INLINE_BANNER` | `# ---` mini-banner appears in the file. | §13.1 |
| `FORBIDDEN_BOX_DRAWING_BANNER` | `# ──` box-drawing banner appears in the file. | §13.1 |
| `FORBIDDEN_REMOVED_CODE_COMMENT` | Headstone comment describing removed code. | §13.1 |
| `FORBIDDEN_SUBSECTION_MARKER` | Sub-section marker comment. | §13.1 |
| `FORBIDDEN_FREESTANDING_COMMENT_BLOCK` | Free-standing block comment outside header/banner/docblock. | §13.1 |
| `EXCESS_BLANK_LINES` | More than one blank line between top-level constructs. | §16 |
| `TRAILING_WHITESPACE` | Line ends with trailing whitespace. | §16 |

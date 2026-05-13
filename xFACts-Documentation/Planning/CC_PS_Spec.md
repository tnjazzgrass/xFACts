# Control Center PowerShell File Format Specification

*These rules are the current authority for Control Center PowerShell files. They are settled until explicitly amended; any proposed change is discussed before adoption. Where rationale exists for a rule, it appears in the Appendix at the corresponding section number.*

*Specs describe rules and shapes — never present contents. Statements about how many files currently do something, which files are empty today, or what the codebase looks like right now do not belong in this document; they age into inaccuracy the moment the codebase changes. If census-style information is needed, it lives in queries against `dbo.Asset_Registry`, not here.*

---

## 1. Required structure

A PowerShell file consists of three parts in this exact order:

1. **File header** — a single comment-based-help block opening at line 1, ending with `#>` followed by exactly one blank line.
2. **Section bodies** — one or more sections, each consisting of a section banner followed by the declarations and statements that section contains.
3. **End-of-file** — the file ends after the last meaningful statement of the last section. No trailing content.

Every line of code in the file lives inside exactly one of these three parts.

---

## 2. File header

*Catalog-side note: the parser additionally emits a single `PS_FILE` anchor row per scanned file, representing the file as a whole. The anchor row is a populator function, not a source-file construct — the author writes nothing for it. See §16.2 for details.*

The header is a single comment-based-help block at the very top of the file. The block uses PowerShell's native `<# ... #>` syntax with recognized keyword elements in a fixed order.

```powershell
<#
.SYNOPSIS
    <One-line summary of what this file does.>

.DESCRIPTION
    <Purpose paragraph: 1 to 5 sentences describing what this file is.>

.PARAMETER <ParamName1>
    <Per-parameter description, one block per parameter the file accepts.>

.PARAMETER <ParamName2>
    <Per-parameter description.>

.COMPONENT
    <Component name from dbo.Component_Registry>

.NOTES
    File Name : <filename>.ps1
    Location  : <full path to the file>

    FILE ORGANIZATION
    -----------------
    <Section banner title 1>
    <Section banner title 2>
    <Section banner title N>
#>
```

### 2.1 Header keyword rules

Recognized keywords appear in this exact order:

| Order | Keyword | Required? | Content |
|---|---|---|---|
| 1 | `.SYNOPSIS` | Required | Single-line summary, no multi-line content |
| 2 | `.DESCRIPTION` | Required | Pure prose paragraph, 1-5 sentences |
| 3 | `.PARAMETER <name>` | Conditional | One block per parameter declared in the file's `param()` block; required when the file accepts parameters |
| 4 | `.COMPONENT` | Required | Single-line component name matching a row in `dbo.Component_Registry.component_name` |
| 5 | `.NOTES` | Required | Three labeled fields plus FILE ORGANIZATION list (see §2.2) |

All other comment-based-help keywords (`.EXAMPLE`, `.INPUTS`, `.OUTPUTS`, `.LINK`, `.ROLE`, `.FUNCTIONALITY`, `.FORWARDHELPTARGETNAME`, `.REMOTEHELPRUNSPACE`, `.EXTERNALHELP`) are forbidden. Drift code: `FORBIDDEN_HEADER_KEYWORD`.

### 2.2 `.NOTES` field rules

The `.NOTES` section contains exactly these three fields in this order:

```
File Name : <filename>.ps1
Location  : <full path>

FILE ORGANIZATION
-----------------
<banner title 1>
<banner title 2>
<banner title N>
```

- `File Name` — the bare filename including extension. Required.
- `Location` — the full directory path where the file lives. Required.
- `FILE ORGANIZATION` — an unnumbered list enumerating the section banner titles in the file body, verbatim, in order. Each list entry is exactly the `<TYPE>: <NAME>` of one banner.

Drift codes:
- `MALFORMED_NOTES_FIELD` — `.NOTES` contains any field other than the three above
- `NOTES_FIELD_ORDER_VIOLATION` — fields appear out of the required order
- `MISSING_FILE_ORGANIZATION` — FILE ORGANIZATION block absent
- `FILE_ORG_MISMATCH` — FILE ORGANIZATION list does not exactly match the section banner titles in the file body, by content or by order

### 2.3 Header content forbidden everywhere

The following content is forbidden anywhere inside the file header docblock:

| Forbidden content | Drift code |
|---|---|
| CHANGELOG block embedded in `.DESCRIPTION`, `.NOTES`, or anywhere else | `FORBIDDEN_CHANGELOG_IN_HEADER` |
| `Author` field | `FORBIDDEN_AUTHOR_IN_HEADER` |
| `Last Modified` / `Date` field | `FORBIDDEN_DATE_IN_HEADER` |
| Version literal (e.g., `2.1.0`) or `Version` line | `FORBIDDEN_VERSION_IN_HEADER` |
| Function inventory list (the `# Functions: ...` pattern) | `FORBIDDEN_FUNCTION_INVENTORY` |
| `=== DEPLOYMENT REMINDERS ===` or similar embedded blocks | `FORBIDDEN_DEPLOYMENT_BLOCK` |
| Free-form `===` divider blocks inside any keyword | `FORBIDDEN_INLINE_DIVIDER_IN_HEADER` |

### 2.4 Header placement rules

- The header is the only construct that may appear before the first section banner. Anything else above the first banner is a parse error.
- The closing `#>` is followed by exactly one blank line, then the first section banner.
- The `.COMPONENT` value is cross-referenced against `dbo.Component_Registry.component_name`. A value not present in the registry emits `COMPONENT_REGISTRY_MISMATCH`.

---

## 3. Section banners

Each section opens with a banner: a multi-line `#` comment block with this format:

```
# ============================================================================
# <TYPE>: <NAME>
# ----------------------------------------------------------------------------
# <Description: 1 to 5 sentences describing what's in this section.>
# Prefix: <prefix>
# ============================================================================
```

The opening and closing rule lines are exactly 76 `=` characters, each preceded by `# ` (the comment marker plus one space). The inner separator is exactly 76 `-` characters, each preceded by `# `.

### 3.1 Banner format rules

- The opening and closing `=` rule lines each consist of exactly 76 `=` characters following `# `.
- The middle `-` rule line is exactly 76 `-` characters following `# ` and separates the title line from the description block.
- `<TYPE>` must be one of the recognized section types (Section 4). The TYPE token is uppercase letters and underscores only.
- `<NAME>` is human-readable and may contain spaces, commas, and other punctuation. The NAME is required — no banner may have a title line consisting of `<TYPE>:` alone or `<TYPE>` without a colon.
- The description block is 1-5 sentences explaining what the section contains. Each line is prefixed with `# `. Required.
- The `Prefix:` line declares the prefix that scopes identifiers in this section (Section 5). Required, singular.

### 3.2 Banner authoring discipline

When adding new content to a file, prefer creating a new banner over expanding an existing one if the new content is a distinct concept. See Section 14 for the full rule on sub-section markers vs. new banners.

### 3.3 Banner drift codes

| Code | Description |
|---|---|
| `BANNER_INLINE_SHAPE` | A banner uses an inline single-line form (`# === Title ===`). The canonical form is multi-line with rule lines, title line, separator, description block, and `Prefix:` line. |
| `BANNER_INVALID_RULE_CHAR` | A banner's opening or closing bracketing line is not composed entirely of `=` characters. |
| `BANNER_INVALID_RULE_LENGTH` | A banner's opening or closing `=` rule line is not exactly 76 characters long. |
| `BANNER_INVALID_SEPARATOR_CHAR` | A banner's middle separator line is missing or is not composed entirely of `-` characters. |
| `BANNER_INVALID_SEPARATOR_LENGTH` | A banner's middle separator line is not exactly 76 `-` characters long. |
| `BANNER_MALFORMED_TITLE_LINE` | A banner's title line does not parse as `<TYPE>: <NAME>`. |
| `BANNER_MISSING_DESCRIPTION` | A banner has no description text between the separator line and the `Prefix:` line. |
| `BANNER_MISSING_NAME` | A banner's title line has the TYPE token but no NAME after the colon. |
| `UNKNOWN_SECTION_TYPE` | A section banner declares a TYPE not in the enumerated list for the file role (Section 4). |
| `SECTION_TYPE_ORDER_VIOLATION` | Section types appear out of the required order (Section 4.3). |
| `MISSING_PREFIX_DECLARATION` | A section banner is missing the mandatory `Prefix:` line. |
| `MALFORMED_PREFIX_VALUE` | A section banner's `Prefix:` line declares anything other than a single 3-character prefix or `(none)`. |
| `PREFIX_REGISTRY_MISMATCH` | A section banner's declared prefix does not match `Component_Registry.cc_prefix` for the file's component. |

---

## 4. Section types

The recognized section types and their semantics. Each role allows a subset of these types (Section 4.2).

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
| `IMPORTS` | Allowed | Allowed | Allowed | Allowed | Forbidden |
| `PARAMETERS` | Forbidden | Forbidden | Forbidden | Allowed | Forbidden |
| `INITIALIZATION` | Forbidden | Forbidden | Forbidden | Allowed | Forbidden |
| `CONSTANTS` | Allowed | Allowed | Allowed | Allowed | Allowed |
| `VARIABLES` | Allowed | Allowed | Allowed | Allowed | Allowed |
| `FUNCTIONS` | Forbidden | Forbidden | Required (1+) | Allowed | Required (1+) |
| `EXECUTION` | Forbidden | Forbidden | Forbidden | Required (exactly 1) | Forbidden |
| `ROUTE` | Required (exactly 1) | Required (exactly 1) | Forbidden | Forbidden | Forbidden |
| `EXPORTS` | Forbidden | Forbidden | Required (exactly 1) | Forbidden | Forbidden |

A section type marked "Forbidden" for a role emits `FORBIDDEN_SECTION_TYPE` when present. A type marked "Required (exactly 1)" emits `MISSING_REQUIRED_SECTION` when absent and `DUPLICATE_SINGULAR_SECTION` when more than one appears. A type marked "Required (1+)" emits `MISSING_REQUIRED_SECTION` when none appear.

### 4.2 Multiple banners of the same type

A file may contain multiple banners of types not marked singular. Multiple `CONSTANTS`, `VARIABLES`, or `FUNCTIONS` sections are encouraged when grouping by concept (e.g., `FUNCTIONS: DATABASE HELPERS`, `FUNCTIONS: RBAC HELPERS`). Each banner has its own NAME, description, and prefix declaration.

The order rule is between types, not between sections within a type. Three `FUNCTIONS` banners appearing in sequence is valid; a `FUNCTIONS` banner followed by a `CONSTANTS` banner followed by another `FUNCTIONS` banner is a type-order violation.

### 4.3 Type-order rule

Section types must appear in the order shown in §4. Drift code: `SECTION_TYPE_ORDER_VIOLATION`.

### 4.4 Singleton banner NAMEs

For section types that appear exactly once per file, the banner NAME is a fixed generic value (not file-specific data):

| TYPE | Singleton role | Banner NAME |
|---|---|---|
| `ROUTE` | page-route | `PAGE PATH` |
| `ROUTE` | api-route | `API ENDPOINTS` |
| `EXPORTS` | module | `MODULE EXPORTS` |
| `PARAMETERS` | standalone | `SCRIPT PARAMETERS` |
| `INITIALIZATION` | standalone | `SCRIPT INITIALIZATION` |
| `EXECUTION` | standalone | `SCRIPT EXECUTION` |

Drift code if a singleton banner uses a different NAME: `MALFORMED_SINGLETON_NAME`.

---

## 5. Prefix

Every section banner declares a single prefix via the `Prefix:` line. Every top-level identifier (function name, constant name, variable name) defined in that section must begin with the declared prefix followed by an underscore. Drift code: `PREFIX_MISMATCH`.

### 5.1 Prefix selection rules

The prefix is a 3-character lowercase identifier and is the same prefix used by the file's component in `Component_Registry.cc_prefix`. The separator after the prefix is an underscore (`_`).

### 5.2 Special values

- `Prefix: (none)` — sentinel value. Declares the section has no prefix scoping. Used by:
  - All sections in shared-library files (their component has `cc_prefix = NULL`)
  - All sections in CC-shared module files (their component has `cc_prefix = NULL`)
  - The `CHANGELOG`, `IMPORTS`, `PARAMETERS`, `INITIALIZATION`, `ROUTE`, and `EXPORTS` sections in any file role (these contain no prefixable identifiers)

The `Prefix:` line itself is mandatory regardless of value. Drift code if absent: `MISSING_PREFIX_DECLARATION`.

### 5.3 Single prefix per banner

Each banner declares exactly one prefix or `(none)`. Multiple comma-separated prefixes are not permitted. Drift code if a banner declares anything other than a single 3-character prefix or `(none)`: `MALFORMED_PREFIX_VALUE`.

### 5.4 Registry validation

Each file's prefix is registered in `dbo.Component_Registry.cc_prefix` for the component identified in the file header's `.COMPONENT` field. The parser cross-references each banner's declared prefix against the registry and emits drift on disagreement.

- If a file's component has `cc_prefix = NULL` (a shared or infrastructure component), every section banner in the file must declare `Prefix: (none)`. A non-`(none)` declaration emits `PREFIX_REGISTRY_MISMATCH` on the banner row.
- If a file's component has `cc_prefix = X` (e.g., `bch` for `BatchOps`), every prefixable section banner must declare `Prefix: X`. Sections that legitimately use `(none)` (per §5.2) are exempt from this check. A section whose banner declares a different prefix value emits `PREFIX_REGISTRY_MISMATCH` on the banner row.
- Top-level identifiers (function names, top-level constants, top-level state variables) in prefixable sections must begin with the file's registered `cc_prefix` followed by an underscore. This rule applies independently of banners. Drift code: `PREFIX_MISSING`.
- The registry is the source of truth. When a declared prefix and the registry disagree, the file is wrong and the file is updated.

---

## 6. File header roles

The file role determines which section types are allowed and which structural rules apply. Role is determined by file extension, filename pattern, and directory.

### 6.1 Role detection

| Role | Detection rule |
|---|---|
| `page-route` | File extension `.ps1`, path matches `xFACts-ControlCenter\scripts\routes\<Name>.ps1` with no `-API` suffix |
| `api-route` | File extension `.ps1`, path matches `xFACts-ControlCenter\scripts\routes\<Name>-API.ps1` |
| `module` | File extension `.psm1`, path matches `xFACts-ControlCenter\scripts\modules\<Name>.psm1` |
| `standalone` | File extension `.ps1`, path is `xFACts-PowerShell\<Name>.ps1` where `<Name>` does NOT start with `xFACts-`. Plus the special-case path `xFACts-ControlCenter\scripts\Start-ControlCenter.ps1`. |
| `shared-library` | File extension `.ps1`, path is `xFACts-PowerShell\xFACts-<Name>.ps1` |

Files at other paths or with other extensions are out of scope for this spec. The populator emits a `PS_FILE` anchor row only and no further structural validation. This includes `.psd1` data files such as `server.psd1`.

### 6.2 Role-specific shapes

#### 6.2.1 page-route

```powershell
<#
.SYNOPSIS
    <One-line summary>
.DESCRIPTION
    <Description>
.COMPONENT
    <Component>
.NOTES
    File Name : <Name>.ps1
    Location  : E:\xFACts-ControlCenter\scripts\routes

    FILE ORGANIZATION
    -----------------
    CHANGELOG
    ROUTE: PAGE PATH
#>

# ============================================================================
# CHANGELOG
# ----------------------------------------------------------------------------
# <Description>
# Prefix: (none)
# ============================================================================

# <changelog entries here>

# ============================================================================
# ROUTE: PAGE PATH
# ----------------------------------------------------------------------------
# <Description>
# Prefix: (none)
# ============================================================================

Add-PodeRoute -Method Get -Path '/<page-path>' -Authentication 'ADLogin' -ScriptBlock {
    # Route handler body: RBAC check, data fetch, HTML emission
}
```

Page-route files have exactly one `ROUTE` section containing exactly one `Add-PodeRoute` call. CHANGELOG is allowed; all other section types are forbidden.

#### 6.2.2 api-route

```powershell
<#
.SYNOPSIS
    <One-line summary>
.DESCRIPTION
    <Description>
.COMPONENT
    <Component>
.NOTES
    File Name : <Name>-API.ps1
    Location  : E:\xFACts-ControlCenter\scripts\routes

    FILE ORGANIZATION
    -----------------
    ROUTE: API ENDPOINTS
#>

# ============================================================================
# ROUTE: API ENDPOINTS
# ----------------------------------------------------------------------------
# <Description>
# Prefix: (none)
# ============================================================================

Add-PodeRoute -Method Get  -Path '/api/.../endpoint-1' -Authentication 'ADLogin' -ScriptBlock { ... }
Add-PodeRoute -Method Post -Path '/api/.../endpoint-2' -Authentication 'ADLogin' -ScriptBlock { ... }
Add-PodeRoute -Method Get  -Path '/api/.../endpoint-3' -Authentication 'ADLogin' -ScriptBlock { ... }
# Additional endpoints follow...
```

Api-route files have exactly one `ROUTE: API ENDPOINTS` section containing one or more `Add-PodeRoute` calls. CHANGELOG is forbidden; all endpoint registrations live under the single ROUTE banner.

#### 6.2.3 module

```powershell
<#
.SYNOPSIS
    <One-line summary>
.DESCRIPTION
    <Description>
.COMPONENT
    <Component>
.NOTES
    File Name : <Name>.psm1
    Location  : E:\xFACts-ControlCenter\scripts\modules

    FILE ORGANIZATION
    -----------------
    IMPORTS
    CONSTANTS: <Group Name>
    VARIABLES: <Group Name>
    FUNCTIONS: <Group Name 1>
    FUNCTIONS: <Group Name 2>
    EXPORTS: MODULE EXPORTS
#>

# ============================================================================
# IMPORTS
# ============================================================================
# (optional — only if module imports other modules)

# ============================================================================
# CONSTANTS: <Group Name>
# ============================================================================

$script:SomeConstant = ...

# ============================================================================
# FUNCTIONS: <Group Name 1>
# ============================================================================

function Get-Something { ... }

# ============================================================================
# FUNCTIONS: <Group Name 2>
# ============================================================================

function Set-Something { ... }

# ============================================================================
# EXPORTS: MODULE EXPORTS
# ============================================================================

Export-ModuleMember -Function Get-Something, Set-Something
```

Module files require at least one `FUNCTIONS` section and exactly one `EXPORTS` section. CHANGELOG is forbidden. Multiple FUNCTIONS sections allowed (and encouraged for logical grouping). `CONSTANTS` and `VARIABLES` sections are allowed for module-scope state.

#### 6.2.4 standalone

```powershell
<#
.SYNOPSIS
    <One-line summary>
.DESCRIPTION
    <Description>
.PARAMETER ServerInstance
    <Per-parameter description>
.PARAMETER Execute
    <Per-parameter description>
.COMPONENT
    <Component>
.NOTES
    File Name : <Name>.ps1
    Location  : E:\xFACts-PowerShell

    FILE ORGANIZATION
    -----------------
    CHANGELOG
    IMPORTS
    PARAMETERS: SCRIPT PARAMETERS
    INITIALIZATION: SCRIPT INITIALIZATION
    CONSTANTS: <Group Name>
    VARIABLES: <Group Name>
    FUNCTIONS: <Group Name 1>
    FUNCTIONS: <Group Name 2>
    EXECUTION: SCRIPT EXECUTION
#>

# ============================================================================
# CHANGELOG
# ============================================================================

# (changelog entries)

# ============================================================================
# IMPORTS
# ============================================================================

. "$PSScriptRoot\xFACts-OrchestratorFunctions.ps1"

# ============================================================================
# PARAMETERS: SCRIPT PARAMETERS
# ============================================================================

[CmdletBinding()]
param(
    [string]$ServerInstance = "AVG-PROD-LSNR",
    [switch]$Execute,
    [long]$TaskId = 0,
    [int]$ProcessId = 0
)

# ============================================================================
# INITIALIZATION: SCRIPT INITIALIZATION
# ============================================================================

Initialize-XFActsScript -ScriptName '<Name>' `
    -ServerInstance $ServerInstance -Database $Database -Execute:$Execute

# ============================================================================
# VARIABLES: <Group Name>
# ============================================================================

$script:Config = @{}

# ============================================================================
# FUNCTIONS: <Group Name>
# ============================================================================

function <Verb-Noun> { ... }

# ============================================================================
# EXECUTION: SCRIPT EXECUTION
# ============================================================================

# Procedural execution body — the "do the work" code that invokes the functions
# defined above in sequence.
```

Standalone scripts require exactly one `EXECUTION` section. CHANGELOG, IMPORTS, PARAMETERS, INITIALIZATION, CONSTANTS, VARIABLES, and FUNCTIONS sections are allowed. PARAMETERS, INITIALIZATION, and EXECUTION use their fixed singleton NAMEs from §4.4.

#### 6.2.5 shared-library

```powershell
<#
.SYNOPSIS
    <One-line summary>
.DESCRIPTION
    <Description>
.COMPONENT
    <Component>
.NOTES
    File Name : xFACts-<Name>.ps1
    Location  : E:\xFACts-PowerShell

    FILE ORGANIZATION
    -----------------
    CHANGELOG
    CONSTANTS: <Group Name>
    VARIABLES: <Group Name>
    FUNCTIONS: <Group Name 1>
    FUNCTIONS: <Group Name 2>
#>

# ============================================================================
# CHANGELOG
# ============================================================================

# (changelog entries)

# ============================================================================
# VARIABLES: <Group Name>
# ============================================================================

$script:SharedState = $null

# ============================================================================
# FUNCTIONS: <Group Name>
# ============================================================================

function <Verb-Noun> { ... }
```

Shared-library files require at least one `FUNCTIONS` section. IMPORTS, PARAMETERS, INITIALIZATION, EXECUTION, ROUTE, and EXPORTS sections are forbidden. CHANGELOG, CONSTANTS, and VARIABLES are allowed.

*Note: shared-library files are structurally identical to module files (§6.2.3) with the EXPORTS section removed. Where the module pattern serves as a working example, the shared-library form is the same shape minus that singleton section.*

---

## 7. CHANGELOG section

The `CHANGELOG` section, where present, is a banner-bounded section containing dated change entries. CHANGELOG is allowed in page-route, standalone, and shared-library files. It is forbidden in api-route and module files.

### 7.1 CHANGELOG entry format

Each entry begins with `# YYYY-MM-DD  <description>` followed by zero or more continuation lines indented to align with the start of the first line's description text.

```
# ============================================================================
# CHANGELOG
# ----------------------------------------------------------------------------
# Date-stamped change history. Each entry is one ISO date line followed by an
# indented description. Entries appear most-recent first.
# Prefix: (none)
# ============================================================================

# 2026-05-13  Migrated to file format spec v1.
#             Renamed sections, normalized banner format, removed embedded
#             CHANGELOG from file header.
# 2026-04-29  Phase 3d header refactor.
#             Page title now sourced from registry via Get-PageHeaderHtml helper.
```

### 7.2 CHANGELOG rules

- One entry per change, most-recent first (top of section)
- Each entry begins with `# YYYY-MM-DD  <description>` (ISO date format, two spaces between date and description)
- Continuation lines for multi-line descriptions are indented to align with the start of the first line's description text
- No version numbers in entries (the timeline anchor is the date)
- Entries run continuously with no blank lines between them

### 7.3 CHANGELOG drift codes

| Code | Description |
|---|---|
| `FORBIDDEN_CHANGELOG_SECTION` | CHANGELOG section present in a role that forbids it (api-route, module) |
| `MALFORMED_CHANGELOG_ENTRY` | Entry does not begin with `# YYYY-MM-DD  ` shape |
| `MALFORMED_CHANGELOG_DATE` | Date is not in ISO YYYY-MM-DD format |
| `CHANGELOG_ORDER_VIOLATION` | Entries appear out of most-recent-first order |
| `FORBIDDEN_VERSION_IN_CHANGELOG` | An entry contains a version literal (e.g., `2.1.0`, `v3`) |

### 7.4 CHANGELOG catalog rows

The populator emits one `PS_CHANGELOG_ENTRY` row per entry, carrying the date, description, and source line range. This makes per-entry queries straightforward ("show every change across the codebase in the last 30 days").

The CHANGELOG section's banner itself produces a `COMMENT_BANNER` row like any other section.

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
    ...
    #>

    # Function body
}
```

### 8.1 Mandatory function attributes

- `[CmdletBinding()]` is mandatory on every function. Drift code: `MISSING_CMDLETBINDING`.
- `param()` block is mandatory if the function accepts parameters. Drift code: `MISSING_PARAM_BLOCK`.
- Comment-based-help docblock (`<# .SYNOPSIS .DESCRIPTION ... #>`) is mandatory on every function. Drift code: `MISSING_DOCBLOCK`.

### 8.2 Function docblock rules

The function docblock follows the same content rules as the file header docblock with these differences:

- `.PARAMETER` blocks are mandatory for each declared parameter
- `.COMPONENT` is forbidden (component is file-level, not function-level)
- `.NOTES` is forbidden (no file-level metadata at function level)
- `.EXAMPLE` is forbidden (per §2.1)
- `.SYNOPSIS` and `.DESCRIPTION` are required

Drift codes:
- `MALFORMED_DOCBLOCK` — docblock missing required elements or in wrong order
- `MISSING_SYNOPSIS` — no `.SYNOPSIS` in function docblock
- `MISSING_DESCRIPTION` — no `.DESCRIPTION` in function docblock
- `MISSING_PARAMETER_DOC` — function accepts parameters but `.PARAMETER` block missing for one or more
- `FORBIDDEN_DOCBLOCK_KEYWORD` — function docblock contains `.COMPONENT`, `.NOTES`, `.EXAMPLE`, or other forbidden keywords

### 8.3 Function naming

- Functions follow PowerShell's `Verb-Noun` convention
- The verb must be from PowerShell's approved verb list (`Get-Verb`)
- The noun follows the file's prefix convention from §5
- Functions starting with an underscore or any non-letter character are forbidden

Drift codes:
- `MALFORMED_FUNCTION_NAME` — function name doesn't follow `Verb-Noun`
- `UNAPPROVED_VERB` — function uses a verb not in PowerShell's approved verb list
- `PREFIX_MISMATCH` — function noun doesn't begin with the section's declared prefix

### 8.4 Other function rules

- Function declarations are not permitted inside route files (page-route or api-route). Helpers belong in modules. Drift codes: `FORBIDDEN_FUNCTION_IN_ROUTE`, `FORBIDDEN_FUNCTION_IN_API_ROUTE`.
- Function declarations are not permitted inside another function's body. Drift code: `FORBIDDEN_NESTED_FUNCTION`.
- `[OutputType()]` is permitted but not required.

### 8.5 Catalog representation

Each function definition produces a `PS_FUNCTION` row (or `PS_FUNCTION_VARIANT` for filter functions; see §16.5). The docblock is cataloged as a `PS_DOCBLOCK` row attached to the function's row via `parent_function`. Each parameter is cataloged as a `PS_PARAMETER` row.

---

## 9. Variables and constants

Top-level declarations split into two kinds based on the section they live in:

- **`CONSTANTS` sections**: declarations of immutable values. Produce `PS_CONSTANT DEFINITION` rows.
- **`VARIABLES` sections**: declarations of mutable values. Produce `PS_VARIABLE DEFINITION` rows.

### 9.1 Declaration form

All top-level declarations use the `$script:` scope qualifier (lowercase).

```powershell
$script:DefaultTimeout = 300        # in a CONSTANTS section
$script:Config = @{}                # in a VARIABLES section
```

### 9.2 Scope rules

- `$script:` (lowercase) is the only permitted scope qualifier for top-level declarations. Drift code: `FORBIDDEN_SCOPE_QUALIFIER` for `$Script:` (capital S), `$global:`, or any other scope.
- `$global:` declarations are forbidden anywhere in the file. Drift code: `FORBIDDEN_GLOBAL_VARIABLE`.
- Assignment to PowerShell automatic variables (`$args`, `$_`, `$matches`, `$input`, `$PSScriptRoot`, etc.) is forbidden. Drift code: `FORBIDDEN_AUTOVAR_REASSIGNMENT`.

### 9.3 Naming conventions

- `CONSTANTS` declarations holding primitive literals (numbers, strings, booleans): `PascalCase` after the prefix (e.g., `$script:bch_DefaultTimeout`)
- `CONSTANTS` declarations holding objects, hashtables, or computed values: `PascalCase` after the prefix
- `VARIABLES` declarations: `PascalCase` after the prefix
- All identifiers in prefixable sections must carry the section's declared prefix followed by an underscore

The case-distinction rule between constants and variables is conventional, not parser-enforced. PowerShell does not have a true `const` keyword; declared values in CONSTANTS sections are conventionally treated as immutable.

### 9.4 Multiple declarations per statement

`$a = $b = $c = 0` and similar chained assignments are forbidden. Each declaration gets its own statement. Drift code: `FORBIDDEN_MULTI_DECLARATION`.

### 9.5 Declaration comment requirement

Every constant and variable declaration must be preceded by a single-line `#` comment describing its purpose. Drift codes:
- `MISSING_CONSTANT_COMMENT` (in CONSTANTS sections)
- `MISSING_VARIABLE_COMMENT` (in VARIABLES sections)

---

## 10. Imports

The `IMPORTS` section contains dot-source statements (`. "$PSScriptRoot\..."`) and `Import-Module` calls. If a file has no imports, the IMPORTS banner is omitted entirely, along with its corresponding FILE ORGANIZATION entry.

### 10.1 Import forms

| Form | Pattern | Catalog row |
|---|---|---|
| Dot-source | `. "$PSScriptRoot\xFACts-OrchestratorFunctions.ps1"` | `MODULE_IMPORT USAGE` with `variant_type='dot-source'` |
| Import-Module by path | `Import-Module -Name "$PSScriptRoot\modules\xFACts-Helpers.psm1"` | `MODULE_IMPORT USAGE` with `variant_type='module-path'` |
| Import-Module by name | `Import-Module SqlServer` | `MODULE_IMPORT USAGE` with `variant_type='module-name'` |

### 10.2 Import rules

- One import per statement (no chained imports)
- Import statements appear only in the IMPORTS section, never elsewhere in the file. Drift code: `MISPLACED_IMPORT`.
- Each import produces a `MODULE_IMPORT USAGE` row keyed on the imported module name. The source path lives in `variant_qualifier_2`.

---

## 11. Routes (page-route and api-route only)

The `ROUTE` section contains one or more `Add-PodeRoute` calls registering web endpoints. Page-route files have exactly one route; api-route files have one or more, all under the same `ROUTE: API ENDPOINTS` banner.

### 11.1 Route registration rules

- Every `Add-PodeRoute` call must include `-Authentication 'ADLogin'`. Drift code: `MISSING_AUTHENTICATION`.
- Page routes must begin with a `Get-UserAccess` RBAC check. Drift code: `MISSING_RBAC_CHECK_PAGE`.
- Every API route, regardless of HTTP method, must call `Test-ActionEndpoint` (or equivalent RBAC enforcement) inside the scriptblock. Drift code: `MISSING_RBAC_CHECK_API`. The `Test-ActionEndpoint` call is fail-open for endpoints not registered in `RBAC_ActionRegistry`, so this rule does not require every endpoint to be registered — it requires every endpoint's scriptblock to invoke the check so registration takes effect automatically when added.
- Page routes must end the scriptblock with `Write-PodeHtmlResponse`. Drift code: `MISSING_RESPONSE_WRITE_PAGE`.
- API routes must end the scriptblock with `Write-PodeJsonResponse`. Drift code: `MISSING_RESPONSE_WRITE_API`.

### 11.2 Route HTML embedding (page-route)

Page-route files emit HTML via PowerShell here-strings (`@"..."@`). The HTML inside is the HTML populator's territory; the PS populator catalogs:

- The `Add-PodeRoute` registration as a `PS_ROUTE DEFINITION` row
- The here-string itself as content the route emits (not cataloged structurally)

Cross-population: HTML rows emitted by the HTML populator from the same here-string carry `parent_function` referencing the route's scriptblock context.

### 11.3 Route catalog rows

Each `Add-PodeRoute` call produces a `PS_ROUTE DEFINITION` row with:
- `component_name` — the route path
- `variant_type` — the HTTP method (`get`, `post`, `put`, `delete`)
- `variant_qualifier_1` — the authentication scheme name

---

## 12. SQL query embedding

SQL queries embedded in PowerShell files must be expressed as here-strings, not as inline single-line string literals.

### 12.1 Canonical SQL form

```powershell
$results = Invoke-XFActsQuery -Query @"
    SELECT
        column_a,
        column_b
    FROM dbo.MyTable
    WHERE column_c = @param_value
"@ -Parameters @{ param_value = 'foo' }
```

### 12.2 SQL form rules

- SQL queries longer than one line must use the `@"..."@` here-string form. Drift code: `INLINE_SQL_STRING_LITERAL`.
- `Invoke-Sqlcmd` calls must include `-TrustServerCertificate`. Drift code: `MISSING_TRUST_SERVER_CERTIFICATE`.
- `Invoke-Sqlcmd` calls must include `-ApplicationName` for DMV attribution. Drift code: `MISSING_APPLICATION_NAME`.
- Queries that reference variables must use parameterized queries via `-Parameters @{...}`. Drift code: `MISSING_PARAMETER_DECLARATION`.
- Queries must not reference linked servers. Drift code: `FORBIDDEN_LINKED_SERVER`.

### 12.3 SQL query catalog rows

Each `Invoke-XFActsQuery`, `Invoke-XFActsNonQuery`, `Invoke-XFActsProc`, `Invoke-CRS5ReadQuery`, `Invoke-AGReadQuery`, `Get-SqlData`, or `Invoke-SqlNonQuery` call produces a `SQL_QUERY USAGE` row carrying the query text, parameter shape, and target database context.

---

## 13. Comments

Comments serve four roles, and only four:

1. **File header** — a single comment-based-help block at line 1 (Section 2)
2. **Section banners** — multi-line `#` comment blocks enclosing a section's title, description, and prefix declaration (Section 3)
3. **Docblocks** — comment-based-help blocks on function definitions (Section 8.2)
4. **Single-line `#` comments** — inline annotations inside function bodies and preceding declarations (Sections 8.1, 9.5)

No other comment forms are recognized. Stray block comments at file scope are a parse error.

### 13.1 Forbidden comment forms

| Forbidden form | Drift code |
|---|---|
| `# ---` mini-banner (informal level-2 banner) | `FORBIDDEN_INLINE_BANNER` |
| `# ── HEADING ──` (box-drawing characters) | `FORBIDDEN_BOX_DRAWING_BANNER` |
| Headstone comments describing removed code (e.g., "This was removed because...") | `FORBIDDEN_REMOVED_CODE_COMMENT` |
| Multi-line `#` comment blocks outside section banners or function bodies | `FORBIDDEN_FREESTANDING_COMMENT_BLOCK` |

### 13.2 Comment content rules

- Purpose comments preceding declarations are written in present-tense, descriptive style. They describe what the declaration is for, not why it exists.
- Section banner descriptions may be 1-5 sentences. They explain what the section contains.
- Function docblock content follows the same content rules as the file header.

---

## 14. Sub-section markers vs. new banners

When a section's content grows, two structural tools are available: new banners of the same type, or new logical groupings within a single banner.

### 14.1 Use a new banner when

- The new content is a distinct concept with its own purpose
- The new content has its own audience or readership context
- A reader scanning the file's FILE ORGANIZATION list would benefit from seeing the new content as a top-level entry

A new banner gets its own row in the FILE ORGANIZATION list. Multiple `FUNCTIONS` banners with distinct NAMEs (e.g., `FUNCTIONS: DATABASE HELPERS`, `FUNCTIONS: RBAC HELPERS`) is the standard pattern.

### 14.2 No sub-section markers

PowerShell files do not use sub-section markers within a banner. CSS and JS allow inline `/* -- label -- */` markers as decorative dividers within a single banner. PowerShell's prefix-comment syntax does not have a clean inline-marker equivalent, and the multi-banner pattern (§14.1) covers all real grouping needs. Drift code if a sub-section marker is found: `FORBIDDEN_SUBSECTION_MARKER`.

---

## 15. Forbidden patterns summary

Patterns forbidden across all PowerShell files, with their drift codes and where the catalog row hosting the drift lives.

### 15.1 Variable scoping

| Pattern | Drift code | Row host |
|---|---|---|
| `$global:foo` declaration | `FORBIDDEN_GLOBAL_VARIABLE` | The declaration row |
| `$Script:` (capital S) instead of `$script:` | `FORBIDDEN_SCOPE_QUALIFIER` | The declaration row |
| Assignment to automatic variables | `FORBIDDEN_AUTOVAR_REASSIGNMENT` | The declaration row |
| Multiple declarations per statement | `FORBIDDEN_MULTI_DECLARATION` | The declaration row |

### 15.2 Function definitions

| Pattern | Drift code | Row host |
|---|---|---|
| Function without `[CmdletBinding()]` | `MISSING_CMDLETBINDING` | The function row |
| Function name not in `Verb-Noun` form | `MALFORMED_FUNCTION_NAME` | The function row |
| Function using unapproved verb | `UNAPPROVED_VERB` | The function row |
| Function declared inside another function's body | `FORBIDDEN_NESTED_FUNCTION` | The inner function row |
| Function in page-route file | `FORBIDDEN_FUNCTION_IN_ROUTE` | The function row |
| Function in api-route file | `FORBIDDEN_FUNCTION_IN_API_ROUTE` | The function row |
| Function without docblock | `MISSING_DOCBLOCK` | The function row |

### 15.3 Header content

| Pattern | Drift code | Row host |
|---|---|---|
| CHANGELOG block embedded in file header | `FORBIDDEN_CHANGELOG_IN_HEADER` | The FILE_HEADER row |
| Author/Date field in header | `FORBIDDEN_AUTHOR_IN_HEADER` / `FORBIDDEN_DATE_IN_HEADER` | The FILE_HEADER row |
| Version literal in header | `FORBIDDEN_VERSION_IN_HEADER` | The FILE_HEADER row |
| Function inventory list in header | `FORBIDDEN_FUNCTION_INVENTORY` | The FILE_HEADER row |
| Deployment reminders block in header | `FORBIDDEN_DEPLOYMENT_BLOCK` | The FILE_HEADER row |
| Inline `===` divider inside header keyword | `FORBIDDEN_INLINE_DIVIDER_IN_HEADER` | The FILE_HEADER row |
| Unrecognized help keyword (`.EXAMPLE`, etc.) | `FORBIDDEN_HEADER_KEYWORD` | The FILE_HEADER row |

### 15.4 SQL

| Pattern | Drift code | Row host |
|---|---|---|
| Inline single-line SQL string literal | `INLINE_SQL_STRING_LITERAL` | The SQL_QUERY row |
| `Invoke-Sqlcmd` without `-TrustServerCertificate` | `MISSING_TRUST_SERVER_CERTIFICATE` | The SQL_QUERY row |
| `Invoke-Sqlcmd` without `-ApplicationName` | `MISSING_APPLICATION_NAME` | The SQL_QUERY row |
| Query referencing linked server | `FORBIDDEN_LINKED_SERVER` | The SQL_QUERY row |
| Missing parameter declaration | `MISSING_PARAMETER_DECLARATION` | The SQL_QUERY row |

### 15.5 Routes

| Pattern | Drift code | Row host |
|---|---|---|
| `Add-PodeRoute` without `-Authentication 'ADLogin'` | `MISSING_AUTHENTICATION` | The PS_ROUTE row |
| Page route without RBAC check | `MISSING_RBAC_CHECK_PAGE` | The PS_ROUTE row |
| API route without RBAC check | `MISSING_RBAC_CHECK_API` | The PS_ROUTE row |
| Page route without `Write-PodeHtmlResponse` | `MISSING_RESPONSE_WRITE_PAGE` | The PS_ROUTE row |
| API route without `Write-PodeJsonResponse` | `MISSING_RESPONSE_WRITE_API` | The PS_ROUTE row |

### 15.6 Module exports

| Pattern | Drift code | Row host |
|---|---|---|
| Module without `Export-ModuleMember` | `MISSING_EXPORTS_SECTION` | The PS_FILE row |
| `Export-ModuleMember -Function *` (wildcard) | `FORBIDDEN_WILDCARD_EXPORT` | The PS_EXPORT row |
| Function in export list not defined in file | `EXPORTED_FUNCTION_NOT_DEFINED` | The PS_EXPORT row |
| Function defined but not in export list | `DEFINED_FUNCTION_NOT_EXPORTED` | The function row |

### 15.7 Logging and output

| Pattern | Drift code | Row host |
|---|---|---|
| `Write-Host` in a standalone or shared-library file (use `Write-Log`) | `FORBIDDEN_WRITE_HOST` | A `PS_WRITE_HOST` row at the call site |

### 15.8 Comments and structure

| Pattern | Drift code | Row host |
|---|---|---|
| `# ---` mini-banner | `FORBIDDEN_INLINE_BANNER` | A `PS_INLINE_BANNER` row at the violation line |
| `# ──` box-drawing divider | `FORBIDDEN_BOX_DRAWING_BANNER` | A `PS_INLINE_BANNER` row at the violation line |
| Removed-code headstone comment | `FORBIDDEN_REMOVED_CODE_COMMENT` | A `PS_REMOVED_CODE_COMMENT` row at the violation line |
| Free-standing block comment outside header/banner/docblock | `FORBIDDEN_FREESTANDING_COMMENT_BLOCK` | A `PS_COMMENT_BLOCK` row at the violation line |
| Excess blank lines between top-level constructs | `EXCESS_BLANK_LINES` | The PS_FILE row |
| Trailing whitespace on a line | `TRAILING_WHITESPACE` | The PS_FILE row |

---

## 16. Catalog model

This section covers the catalog mechanism as it relates to PowerShell files. Every cataloged PS construct gets one row in `dbo.Asset_Registry`.

### 16.1 What the catalog represents

A row's identity is described by the combination of `component_type`, `component_name`, `reference_type`, `file_name`, `occurrence_index`, `variant_type`, `variant_qualifier_1`, and `variant_qualifier_2`. The parser populates one row per definition or usage instance found while walking source files.

The catalog is the answer to questions like: "where is `Get-UserAccess` defined?", "which standalone scripts call `Initialize-XFActsScript`?", "which files contain spec drift today and of what kinds?", "show me every CHANGELOG entry across the codebase from the last 30 days." Every such question becomes a SQL query against this table.

### 16.2 PS-relevant component_type values

| component_type | Meaning |
|---|---|
| `PS_FILE` | The file-level anchor row. One row per scanned PowerShell file. Carries no `raw_text`, `purpose_description`, or `signature` — the row is purely structural. Hosts file-overall drift codes (`EXCESS_BLANK_LINES`, `TRAILING_WHITESPACE`, `MISSING_EXPORTS_SECTION`). The same anchor-row pattern exists in the CSS, HTML, and JS populators as `CSS_FILE`, `HTML_FILE`, and `JS_FILE`. |
| `FILE_HEADER` | The parsed file-header docblock. One row per scanned file. Carries header-block-specific drift codes (`MALFORMED_FILE_HEADER`, `FORBIDDEN_CHANGELOG_IN_HEADER`, `FILE_ORG_MISMATCH`, `MALFORMED_NOTES_FIELD`) and the header's purpose paragraph in `purpose_description`. |
| `COMMENT_BANNER` | A section banner. One row per banner. `signature` carries the TYPE, `component_name` carries the NAME, `purpose_description` carries the description block. |
| `PS_CHANGELOG_ENTRY` | A single dated entry inside a CHANGELOG section. One row per entry. `component_name` = date (YYYY-MM-DD), `purpose_description` = the entry's description text. |
| `PS_FUNCTION` | A regular function definition. |
| `PS_FUNCTION_VARIANT` | A filter function (`filter Name { ... }`). |
| `PS_DOCBLOCK` | A comment-based-help block attached to a function. `parent_function` = the function name. |
| `PS_PARAMETER` | A parameter declared in a `param()` block (either script-level or function-level). `parent_function` = function name or `(script)` for script-level. |
| `PS_CONSTANT` | A declaration in a `CONSTANTS` section. |
| `PS_VARIABLE` | A declaration in a `VARIABLES` section. |
| `PS_ROUTE` | An `Add-PodeRoute` call. `component_name` = route path, `variant_type` = HTTP method. |
| `PS_MIDDLEWARE` | An `Add-PodeMiddleware` call. |
| `PS_WEBSOCKET_ROUTE` | An `Add-PodeRouteWebSocket` call. |
| `PS_EXPORT` | A function or variable name in `Export-ModuleMember`. One row per exported name. |
| `SQL_QUERY` | A call to `Invoke-XFActsQuery`, `Invoke-XFActsNonQuery`, `Invoke-XFActsProc`, `Invoke-CRS5ReadQuery`, `Invoke-AGReadQuery`, `Get-SqlData`, or `Invoke-SqlNonQuery`. `component_name` = a hash or short identifier of the query; `raw_text` = the SQL query text. |
| `GLOBALCONFIG_REF` | A reference to a GlobalConfig setting (via direct query or helper). `component_name` = the setting name. |
| `RBAC_CHECK` | A call to `Get-UserAccess`, `Test-ActionPermission`, or `Test-ActionEndpoint`. `component_name` = the function name being called. |
| `MODULE_IMPORT` | A dot-source or `Import-Module` statement. `component_name` = imported module name or short path; `variant_qualifier_2` = source path. |
| `PS_FUNCTION_CALL` | A call to a function defined in this file or a known shared library/module. `component_name` = called function name. Only emitted for cross-cataloged functions. |
| `PS_WRITE_HOST` | A `Write-Host` call. Exists solely to host `FORBIDDEN_WRITE_HOST` drift. |
| `PS_INLINE_BANNER` | An informal `# ---` or `# ──` divider. Exists solely to host `FORBIDDEN_INLINE_BANNER` or `FORBIDDEN_BOX_DRAWING_BANNER` drift. |
| `PS_REMOVED_CODE_COMMENT` | A headstone comment describing removed code. Exists solely to host `FORBIDDEN_REMOVED_CODE_COMMENT` drift. |
| `PS_COMMENT_BLOCK` | A free-standing block comment outside header/banner/docblock. Exists solely to host `FORBIDDEN_FREESTANDING_COMMENT_BLOCK` drift. |

### 16.3 Scope determination

- DEFINITION rows in shared-library files (`xFACts-<Name>.ps1` under `E:\xFACts-PowerShell`): scope is `SHARED`.
- DEFINITION rows in the CC module (`xFACts-Helpers.psm1`): scope is `SHARED`.
- DEFINITION rows in standalone, page-route, api-route files: scope is `LOCAL`.
- USAGE rows of functions: `SHARED` if the called function is defined in a shared-library or module; `LOCAL` if defined in the same file.
- Forbidden-pattern rows: scope follows the file's overall scope. The drift code is the action item; the scope value is informational.

### 16.4 Drift recording

The parser evaluates every row against the spec and records two things when the row deviates:

- `drift_codes` — comma-separated list of stable short codes
- `drift_text` — joined human-readable descriptions corresponding to each code

A row may carry zero, one, or many drift codes. Both columns are NULL when the row is fully spec-compliant. Empty strings are treated as NULL.

The complete code-to-description mapping for PowerShell appears in Section 18.

### 16.5 Variant model

Variant columns (`variant_type`, `variant_qualifier_1`, `variant_qualifier_2`) discriminate sub-flavors of certain component types. Two patterns are in use, the same as JS:

- **Base + `_VARIANT` companion type** — a base case with semantically-distinct alternatives. Example: `PS_FUNCTION` (regular) / `PS_FUNCTION_VARIANT` (filter).
- **Single component type, always non-NULL `variant_type`** — every instance is a variant with no natural base. Examples: `PS_ROUTE`, `MODULE_IMPORT`.

#### PS_FUNCTION (base) and PS_FUNCTION_VARIANT (variant)

| component_type | variant_type | qualifier_1 | qualifier_2 | Source pattern |
|---|---|---|---|---|
| `PS_FUNCTION` | NULL | NULL | NULL | `function Get-Something { ... }` |
| `PS_FUNCTION_VARIANT` | `filter` | NULL | NULL | `filter Get-Something { ... }` |

#### PS_ROUTE (always non-NULL variant_type)

| component_type | variant_type | qualifier_1 | qualifier_2 | Source pattern |
|---|---|---|---|---|
| `PS_ROUTE` | `get` | auth scheme | route path | `Add-PodeRoute -Method Get -Path '/foo' -Authentication 'ADLogin' ...` |
| `PS_ROUTE` | `post` | auth scheme | route path | `Add-PodeRoute -Method Post -Path '/foo' -Authentication 'ADLogin' ...` |
| `PS_ROUTE` | `put` | auth scheme | route path | (analogous) |
| `PS_ROUTE` | `delete` | auth scheme | route path | (analogous) |

#### MODULE_IMPORT (always non-NULL variant_type)

| component_type | variant_type | qualifier_1 | qualifier_2 | Source pattern |
|---|---|---|---|---|
| `MODULE_IMPORT` | `dot-source` | NULL | source path | `. "$PSScriptRoot\xFACts-OrchestratorFunctions.ps1"` |
| `MODULE_IMPORT` | `module-path` | NULL | source path | `Import-Module -Name "$PSScriptRoot\modules\..."` |
| `MODULE_IMPORT` | `module-name` | NULL | module name | `Import-Module SqlServer` |

#### Component types with no variants

`PS_FILE`, `FILE_HEADER`, `COMMENT_BANNER`, `PS_CHANGELOG_ENTRY`, `PS_DOCBLOCK`, `PS_PARAMETER`, `PS_CONSTANT`, `PS_VARIABLE`, `PS_MIDDLEWARE`, `PS_WEBSOCKET_ROUTE`, `PS_EXPORT`, `SQL_QUERY`, `GLOBALCONFIG_REF`, `RBAC_CHECK`, `PS_FUNCTION_CALL`, `PS_WRITE_HOST`, `PS_INLINE_BANNER`, `PS_REMOVED_CODE_COMMENT`, `PS_COMMENT_BLOCK` — variant columns are always NULL.

---

## 17. What the parser extracts

| Row type | Source | Notes |
|---|---|---|
| `PS_FILE DEFINITION` | The file as a whole | One per scanned file. Universal anchor row. `component_name` = bare filename. No `raw_text` or `purpose_description`. Hosts file-overall drift codes. |
| `FILE_HEADER DEFINITION` | The opening comment-based-help block | One per file. `purpose_description` = `.DESCRIPTION` content. Hosts header-block-specific drift codes. |
| `COMMENT_BANNER DEFINITION` | Each section banner | `signature` = TYPE, `component_name` = NAME, `purpose_description` = description block. Format violations attach as drift codes (§18.2). |
| `PS_CHANGELOG_ENTRY DEFINITION` | Each dated entry in a CHANGELOG section | `component_name` = date (YYYY-MM-DD), `purpose_description` = description text. |
| `PS_FUNCTION DEFINITION` / `PS_FUNCTION_VARIANT DEFINITION` | Each function declaration | Base for `function`; variant for `filter`. `signature` = parameter list signature. |
| `PS_DOCBLOCK DEFINITION` | Each function's docblock | `parent_function` = function name. `purpose_description` = `.DESCRIPTION` content. |
| `PS_PARAMETER DEFINITION` | Each parameter inside a `param()` block | `component_name` = parameter name; `parent_function` = function name or `(script)` for script-level params; `signature` = type and attributes. |
| `PS_CONSTANT DEFINITION` | Each declaration in a CONSTANTS section | `component_name` = variable name (without `$script:`); `purpose_description` = preceding purpose comment. |
| `PS_VARIABLE DEFINITION` | Each declaration in a VARIABLES section | Same as PS_CONSTANT. |
| `PS_ROUTE DEFINITION` | Each `Add-PodeRoute` call | `component_name` = route path; `variant_type` = HTTP method. |
| `PS_MIDDLEWARE DEFINITION` | Each `Add-PodeMiddleware` call | `component_name` = middleware name. |
| `PS_WEBSOCKET_ROUTE DEFINITION` | Each `Add-PodeRouteWebSocket` call | `component_name` = WebSocket path. |
| `PS_EXPORT DEFINITION` | Each name in `Export-ModuleMember` | `component_name` = exported function or variable name. One row per name. |
| `SQL_QUERY USAGE` | Each SQL helper call | `component_name` = a short identifier; `raw_text` = the SQL text. |
| `GLOBALCONFIG_REF USAGE` | Each reference to a GlobalConfig setting | `component_name` = setting name. |
| `RBAC_CHECK USAGE` | Each RBAC helper call | `component_name` = the function called. |
| `MODULE_IMPORT USAGE` | Each `Import-Module` or dot-source statement | `component_name` = imported module name; `variant_qualifier_2` = source path. |
| `PS_FUNCTION_CALL USAGE` | Each call to a function defined in the same file or in a shared library/module | Calls to unknown identifiers are not cataloged. |
| `PS_WRITE_HOST USAGE` | Each `Write-Host` call in a standalone or shared-library file | Always `FORBIDDEN_WRITE_HOST` drift. |
| `PS_INLINE_BANNER DEFINITION` | Each `# ---` or `# ──` divider | Always `FORBIDDEN_INLINE_BANNER` or `FORBIDDEN_BOX_DRAWING_BANNER` drift. |
| `PS_REMOVED_CODE_COMMENT DEFINITION` | Each headstone comment | Always `FORBIDDEN_REMOVED_CODE_COMMENT` drift. |
| `PS_COMMENT_BLOCK DEFINITION` | Each free-standing block comment outside header/banner/docblock | Always `FORBIDDEN_FREESTANDING_COMMENT_BLOCK` drift. |

Each row may carry one or more drift codes in `drift_codes` (comma-delimited string) when the rule violates a spec requirement.

---

## 18. Drift codes reference

### 18.1 File-level codes

| Code | Description |
|---|---|
| `MALFORMED_FILE_HEADER` | The file's header block is missing, malformed, or contains required keywords out of order. |
| `MISSING_SYNOPSIS` | The file header has no `.SYNOPSIS` element. |
| `MISSING_DESCRIPTION` | The file header has no `.DESCRIPTION` element. |
| `MISSING_COMPONENT` | The file header has no `.COMPONENT` element. |
| `MISSING_NOTES` | The file header has no `.NOTES` element. |
| `MISSING_PARAMETER_DOC` | The file accepts parameters but `.PARAMETER` block missing for one or more. |
| `MALFORMED_NOTES_FIELD` | The `.NOTES` section contains a field other than File Name, Location, or FILE ORGANIZATION. |
| `NOTES_FIELD_ORDER_VIOLATION` | The `.NOTES` fields appear out of the required order. |
| `MISSING_FILE_ORGANIZATION` | The `.NOTES` section is missing the FILE ORGANIZATION block. |
| `FILE_ORG_MISMATCH` | The FILE ORGANIZATION list does not exactly match the section banner titles in the file body. |
| `FORBIDDEN_HEADER_KEYWORD` | The file header contains a forbidden keyword (`.EXAMPLE`, `.INPUTS`, `.OUTPUTS`, `.LINK`, etc.). |
| `FORBIDDEN_CHANGELOG_IN_HEADER` | The file header contains a CHANGELOG block. |
| `FORBIDDEN_AUTHOR_IN_HEADER` | The file header contains an Author field. |
| `FORBIDDEN_DATE_IN_HEADER` | The file header contains a Last Modified or Date field. |
| `FORBIDDEN_VERSION_IN_HEADER` | The file header contains a Version field or version literal. |
| `FORBIDDEN_FUNCTION_INVENTORY` | The file header contains a function inventory list. |
| `FORBIDDEN_DEPLOYMENT_BLOCK` | The file header contains a `=== DEPLOYMENT REMINDERS ===` or similar embedded block. |
| `FORBIDDEN_INLINE_DIVIDER_IN_HEADER` | The file header contains a free-form `===` divider block inside a keyword. |
| `COMPONENT_REGISTRY_MISMATCH` | The `.COMPONENT` value is not present in `dbo.Component_Registry.component_name`. |

### 18.2 Section/banner-level codes

| Code | Description |
|---|---|
| `MISSING_SECTION_BANNER` | A definition appears outside any banner. |
| `BANNER_INLINE_SHAPE` | A banner uses an inline single-line form. |
| `BANNER_INVALID_RULE_CHAR` | A banner's opening or closing bracketing line is not composed entirely of `=` characters. |
| `BANNER_INVALID_RULE_LENGTH` | A banner's opening or closing `=` rule line is not exactly 76 characters long. |
| `BANNER_INVALID_SEPARATOR_CHAR` | A banner's middle separator line is missing or is not composed entirely of `-` characters. |
| `BANNER_INVALID_SEPARATOR_LENGTH` | A banner's middle separator line is not exactly 76 `-` characters long. |
| `BANNER_MALFORMED_TITLE_LINE` | A banner's title line does not parse as `<TYPE>: <NAME>`. |
| `BANNER_MISSING_DESCRIPTION` | A banner has no description text between the separator line and the `Prefix:` line. |
| `BANNER_MISSING_NAME` | A banner's title line has the TYPE token but no NAME after the colon. |
| `UNKNOWN_SECTION_TYPE` | A section banner declares a TYPE not in the enumerated list for the file role. |
| `SECTION_TYPE_ORDER_VIOLATION` | Section types appear out of the required order. |
| `MISSING_REQUIRED_SECTION` | A section type required for the file role is absent. |
| `FORBIDDEN_SECTION_TYPE` | A section type forbidden for the file role is present. |
| `DUPLICATE_SINGULAR_SECTION` | A section type that must appear exactly once appears multiple times. |
| `MALFORMED_SINGULAR_NAME` | A singleton section's NAME differs from the required generic NAME for its role. |
| `MISSING_PREFIX_DECLARATION` | A section banner is missing the mandatory `Prefix:` line. |
| `MALFORMED_PREFIX_VALUE` | A section banner's `Prefix:` line declares anything other than a single 3-character prefix or `(none)`. |
| `PREFIX_REGISTRY_MISMATCH` | A section banner's declared prefix does not match `Component_Registry.cc_prefix` for the file's component. |

### 18.3 CHANGELOG codes

| Code | Description |
|---|---|
| `FORBIDDEN_CHANGELOG_SECTION` | CHANGELOG section appears in a role that forbids it (api-route, module). |
| `MALFORMED_CHANGELOG_ENTRY` | A CHANGELOG entry does not begin with `# YYYY-MM-DD  ` shape. |
| `MALFORMED_CHANGELOG_DATE` | A CHANGELOG entry's date is not in ISO YYYY-MM-DD format. |
| `CHANGELOG_ORDER_VIOLATION` | CHANGELOG entries appear out of most-recent-first order. |
| `FORBIDDEN_VERSION_IN_CHANGELOG` | A CHANGELOG entry contains a version literal. |

### 18.4 Function-level codes

| Code | Description |
|---|---|
| `MISSING_CMDLETBINDING` | A function definition lacks `[CmdletBinding()]`. |
| `MISSING_PARAM_BLOCK` | A function that takes parameters lacks a `param()` block. |
| `MISSING_DOCBLOCK` | A function lacks a comment-based-help docblock. |
| `MALFORMED_DOCBLOCK` | A function docblock is missing required elements or has elements in the wrong order. |
| `FORBIDDEN_DOCBLOCK_KEYWORD` | A function docblock contains a forbidden keyword (`.COMPONENT`, `.NOTES`, `.EXAMPLE`, etc.). |
| `MALFORMED_FUNCTION_NAME` | A function name doesn't follow `Verb-Noun`. |
| `UNAPPROVED_VERB` | A function uses a verb not in PowerShell's approved verb list. |
| `FORBIDDEN_FUNCTION_IN_ROUTE` | A function declaration appears inside a page-route file. |
| `FORBIDDEN_FUNCTION_IN_API_ROUTE` | A function declaration appears inside an api-route file. |
| `FORBIDDEN_NESTED_FUNCTION` | A function declaration appears inside another function's body. |
| `PREFIX_MISMATCH` | A function noun does not begin with its section's declared prefix. |
| `PREFIX_MISSING` | A top-level identifier does not begin with the file's registered `cc_prefix`. |

### 18.5 Variable and constant codes

| Code | Description |
|---|---|
| `MISSING_CONSTANT_COMMENT` | A constant declaration is not preceded by a purpose comment. |
| `MISSING_VARIABLE_COMMENT` | A variable declaration is not preceded by a purpose comment. |
| `FORBIDDEN_GLOBAL_VARIABLE` | A `$global:foo` declaration appears in the file. |
| `FORBIDDEN_SCOPE_QUALIFIER` | A declaration uses `$Script:` (capital S) instead of `$script:`. |
| `FORBIDDEN_AUTOVAR_REASSIGNMENT` | An assignment to a PowerShell automatic variable appears in the file. |
| `FORBIDDEN_MULTI_DECLARATION` | A single statement declares multiple variables (chained assignments). |
| `MISPLACED_DECLARATION` | A `$script:` declaration appears outside a CONSTANTS or VARIABLES section. |

### 18.6 SQL codes

| Code | Description |
|---|---|
| `INLINE_SQL_STRING_LITERAL` | A multi-line SQL query is embedded as a single-line string literal instead of a here-string. |
| `MISSING_TRUST_SERVER_CERTIFICATE` | An `Invoke-Sqlcmd` call lacks `-TrustServerCertificate`. |
| `MISSING_APPLICATION_NAME` | An `Invoke-Sqlcmd` call lacks `-ApplicationName`. |
| `MISSING_PARAMETER_DECLARATION` | A query referencing `@variable` parameters lacks a `-Parameters` hashtable. |
| `FORBIDDEN_LINKED_SERVER` | A query references a linked server. |

### 18.7 Route codes

| Code | Description |
|---|---|
| `MISSING_AUTHENTICATION` | An `Add-PodeRoute` call lacks `-Authentication 'ADLogin'`. |
| `MISSING_RBAC_CHECK_PAGE` | A page route's scriptblock does not begin with `Get-UserAccess`. |
| `MISSING_RBAC_CHECK_API` | An API route's scriptblock does not include a `Test-ActionEndpoint` call. Applies to all API routes regardless of HTTP method. |
| `MISSING_RESPONSE_WRITE_PAGE` | A page route's scriptblock does not end with `Write-PodeHtmlResponse`. |
| `MISSING_RESPONSE_WRITE_API` | An API route's scriptblock does not end with `Write-PodeJsonResponse`. |

### 18.8 Module export codes

| Code | Description |
|---|---|
| `MISSING_EXPORTS_SECTION` | A module file lacks an `EXPORTS` section. |
| `FORBIDDEN_WILDCARD_EXPORT` | `Export-ModuleMember -Function *` (wildcard) is used. |
| `EXPORTED_FUNCTION_NOT_DEFINED` | A function name in `Export-ModuleMember` does not match any declared function in the file. |
| `DEFINED_FUNCTION_NOT_EXPORTED` | A function is declared but not in the export list. |

### 18.9 Import codes

| Code | Description |
|---|---|
| `MISPLACED_IMPORT` | An `Import-Module` or dot-source statement appears outside the IMPORTS section. |
| `ORPHAN_MODULE_IMPORT` | An import references a module not present in the codebase. |

### 18.10 Forbidden output codes

| Code | Description |
|---|---|
| `FORBIDDEN_WRITE_HOST` | A `Write-Host` call appears in a standalone or shared-library file. |

### 18.11 Comment and structure codes

| Code | Description |
|---|---|
| `FORBIDDEN_INLINE_BANNER` | A `# ---` informal banner appears in the file. |
| `FORBIDDEN_BOX_DRAWING_BANNER` | A `# ──` (box-drawing characters) banner appears in the file. |
| `FORBIDDEN_REMOVED_CODE_COMMENT` | A comment describing removed code (headstone comment) appears in the file. |
| `FORBIDDEN_FREESTANDING_COMMENT_BLOCK` | A free-standing block comment appears outside the file header, a section banner, or a function docblock. |
| `FORBIDDEN_SUBSECTION_MARKER` | A sub-section marker comment appears in the file. |
| `EXCESS_BLANK_LINES` | More than one blank line appears between top-level constructs. |
| `TRAILING_WHITESPACE` | A line ends with trailing whitespace characters. |

### 18.12 Cross-file codes (Pass 3)

| Code | Description |
|---|---|
| `DUPLICATE_FUNCTION_DEFINITION` | The same function name is declared in multiple PS files. |
| `ORPHAN_FUNCTION_CALL` | A function call does not resolve to any DEFINITION row in the catalog. |

---

## 19. Compliance queries

Standard SQL queries against `dbo.Asset_Registry` for PS compliance reporting. Each query is scoped to `WHERE file_type = 'PS'`.

### 19.1 Q1 — Drift summary per file

Counts of total rows and rows-with-drift per file. Use this to prioritize conversion work.

```sql
SELECT
    file_name,
    COUNT(*)                                                     AS total_rows,
    SUM(CASE WHEN drift_codes IS NOT NULL THEN 1 ELSE 0 END)     AS rows_with_drift
FROM dbo.Asset_Registry
WHERE file_type = 'PS'
GROUP BY file_name
ORDER BY rows_with_drift DESC;
```

### 19.2 Q2 — Drift code distribution

What's the most common kind of drift across the PS codebase?

```sql
SELECT
    TRIM(value)         AS code,
    COUNT(*)            AS occurrences
FROM dbo.Asset_Registry
CROSS APPLY STRING_SPLIT(drift_codes, ',')
WHERE file_type    = 'PS'
  AND drift_codes  IS NOT NULL
  AND TRIM(value)  <> ''
GROUP BY TRIM(value)
ORDER BY COUNT(*) DESC;
```

### 19.3 Q3 — Per-file rewrite checklist

For one specific file, what does the work look like, grouped by drift code?

```sql
SELECT
    drift_codes,
    COUNT(*)            AS occurrences,
    MIN(line_start)     AS first_line,
    MAX(line_start)     AS last_line
FROM dbo.Asset_Registry
WHERE file_type    = 'PS'
  AND file_name    = '<filename.ps1>'
  AND drift_codes  IS NOT NULL
GROUP BY drift_codes
ORDER BY occurrences DESC;
```

### 19.4 Q4 — Function inventory by file

For one specific file, list every function it defines with its purpose.

```sql
SELECT
    component_name      AS function_name,
    line_start          AS line,
    source_section      AS in_section,
    purpose_description AS purpose
FROM dbo.Asset_Registry
WHERE file_type      = 'PS'
  AND file_name      = '<filename.ps1>'
  AND component_type IN ('PS_FUNCTION', 'PS_FUNCTION_VARIANT')
  AND reference_type = 'DEFINITION'
ORDER BY line_start;
```

### 19.5 Q5 — CHANGELOG entries in date range

Every CHANGELOG entry across the codebase in a given date range.

```sql
SELECT
    file_name,
    component_name      AS entry_date,
    purpose_description AS description
FROM dbo.Asset_Registry
WHERE file_type      = 'PS'
  AND component_type = 'PS_CHANGELOG_ENTRY'
  AND reference_type = 'DEFINITION'
  AND component_name BETWEEN '2026-04-01' AND '2026-05-31'
ORDER BY component_name DESC, file_name;
```

### 19.6 Q6 — Forbidden-pattern inventory

List every forbidden-pattern occurrence with line and context. Once the codebase is fully spec-compliant, this query returns zero rows.

```sql
SELECT
    file_name,
    line_start,
    component_type,
    drift_codes,
    drift_text
FROM dbo.Asset_Registry
WHERE file_type      = 'PS'
  AND component_type IN ('PS_WRITE_HOST', 'PS_INLINE_BANNER',
                         'PS_REMOVED_CODE_COMMENT', 'PS_COMMENT_BLOCK')
ORDER BY file_name, line_start;
```

### 19.7 Q7 — Function call graph

For a specific function, find every place it's called from.

```sql
SELECT
    callers.file_name        AS calling_file,
    callers.parent_function  AS calling_function,
    callers.line_start       AS calling_line
FROM dbo.Asset_Registry callers
WHERE callers.file_type      = 'PS'
  AND callers.component_type = 'PS_FUNCTION_CALL'
  AND callers.component_name = '<function-name>'
  AND callers.reference_type = 'USAGE'
ORDER BY callers.file_name, callers.line_start;
```

### 19.8 Q8 — SQL query coverage

For each PowerShell file, count distinct SQL queries embedded in it.

```sql
SELECT
    file_name,
    COUNT(*)              AS sql_query_count,
    COUNT(DISTINCT raw_text) AS distinct_queries
FROM dbo.Asset_Registry
WHERE file_type      = 'PS'
  AND component_type = 'SQL_QUERY'
  AND reference_type = 'USAGE'
GROUP BY file_name
ORDER BY sql_query_count DESC;
```

### 19.9 Q9 — API endpoint inventory

Complete inventory of every API endpoint registered across the codebase. The catalog is the canonical source for "what API endpoints exist in xFACts."

```sql
SELECT
    file_name,
    component_name      AS endpoint_path,
    variant_type        AS http_method,
    variant_qualifier_1 AS auth_scheme,
    line_start
FROM dbo.Asset_Registry
WHERE file_type      = 'PS'
  AND component_type = 'PS_ROUTE'
  AND reference_type = 'DEFINITION'
ORDER BY component_name, variant_type;
```

Joined against `RBAC_ActionRegistry`, the same inventory surfaces endpoints registered in code but not in the action registry (and vice versa):

```sql
-- Endpoints defined in PS files but not registered in RBAC_ActionRegistry
SELECT
    ar.file_name,
    ar.component_name  AS endpoint_path,
    ar.variant_type    AS http_method
FROM dbo.Asset_Registry ar
LEFT JOIN dbo.RBAC_ActionRegistry rar
    ON  rar.api_endpoint = ar.component_name
    AND rar.http_method  = UPPER(ar.variant_type)
WHERE ar.file_type      = 'PS'
  AND ar.component_type = 'PS_ROUTE'
  AND ar.reference_type = 'DEFINITION'
  AND rar.action_id IS NULL
ORDER BY ar.component_name;
```

---

## 20. Examples

### 20.1 Minimal complete page-route file

```powershell
<#
.SYNOPSIS
    xFACts - Example Page Route

.DESCRIPTION
    Renders the Example dashboard page showing example metrics from BatchOps.
    The route performs an RBAC check, fetches navigation context, builds the
    page HTML via shared helpers, and emits the response.

.COMPONENT
    BatchOps

.NOTES
    File Name : Example.ps1
    Location  : E:\xFACts-ControlCenter\scripts\routes

    FILE ORGANIZATION
    -----------------
    CHANGELOG
    ROUTE: PAGE PATH
#>

# ============================================================================
# CHANGELOG
# ----------------------------------------------------------------------------
# Date-stamped change history. Each entry is one ISO date line followed by an
# indented description. Entries appear most-recent first.
# Prefix: (none)
# ============================================================================

# 2026-05-13  Migrated to file format spec v1.

# ============================================================================
# ROUTE: PAGE PATH
# ----------------------------------------------------------------------------
# Page route registration. The ScriptBlock body performs the RBAC check,
# fetches nav and header context, and emits the page HTML.
# Prefix: (none)
# ============================================================================

Add-PodeRoute -Method Get -Path '/example' -Authentication 'ADLogin' -ScriptBlock {

    # RBAC access check
    $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/example'
    if (-not $access.HasAccess) {
        Write-PodeHtmlResponse -Value (Get-AccessDeniedHtml -DisplayName $access.DisplayName -PageRoute '/example') -StatusCode 403
        return
    }

    # User context for header rendering
    $ctx = Get-UserContext -WebEvent $WebEvent

    # Render dynamic nav bar and page header
    $navHtml      = Get-NavBarHtml      -UserContext $ctx -CurrentPageRoute '/example'
    $headerHtml   = Get-PageHeaderHtml   -PageRoute '/example'
    $browserTitle = Get-PageBrowserTitle -PageRoute '/example'

    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>$browserTitle</title>
    <link rel="stylesheet" href="/css/example.css">
    <link rel="stylesheet" href="/css/cc-shared.css">
</head>
<body data-page="example" data-prefix="exa">
$navHtml
    <div class="header-bar">
        <div>$headerHtml</div>
    </div>
    <div id="page-error-banner" class="page-error-banner"></div>
    <div class="example-content">
        <!-- page content here -->
    </div>
    <script src="/js/cc-shared.js"></script>
</body>
</html>
"@
    Write-PodeHtmlResponse -Value $html
}
```

### 20.2 Minimal complete api-route file

```powershell
<#
.SYNOPSIS
    xFACts - Example API

.DESCRIPTION
    API endpoints for the Example dashboard. All endpoints require ADLogin
    authentication and return JSON.

.COMPONENT
    BatchOps

.NOTES
    File Name : Example-API.ps1
    Location  : E:\xFACts-ControlCenter\scripts\routes

    FILE ORGANIZATION
    -----------------
    ROUTE: API ENDPOINTS
#>

# ============================================================================
# ROUTE: API ENDPOINTS
# ----------------------------------------------------------------------------
# All API endpoint registrations for the Example dashboard. Each Add-PodeRoute
# inside this section is one endpoint; all endpoints live under this single
# section.
# Prefix: (none)
# ============================================================================

Add-PodeRoute -Method Get -Path '/api/example/data' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }

    try {
        $results = Invoke-XFActsQuery -Query @"
            SELECT example_id, example_name, example_value
            FROM dbo.ExampleTable
            ORDER BY example_id
"@
        Write-PodeJsonResponse -Value @{ data = $results }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

Add-PodeRoute -Method Post -Path '/api/example/update' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }

    try {
        $body = $WebEvent.Data
        Invoke-XFActsNonQuery -Query @"
            UPDATE dbo.ExampleTable
            SET example_value = @newValue
            WHERE example_id = @id
"@ -Parameters @{ newValue = $body.value; id = $body.id }

        Write-PodeJsonResponse -Value @{ success = $true }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}
```

### 20.3 Minimal complete standalone file

```powershell
<#
.SYNOPSIS
    xFACts - Example Collector

.DESCRIPTION
    Collects example data from the source system and writes it to the
    xFACts BatchOps schema. Follows the standard xFACts collector pattern
    with AG-aware replica reads and preview-mode support.

.PARAMETER ServerInstance
    SQL Server instance hosting the xFACts database.

.PARAMETER Database
    xFACts database name.

.PARAMETER Execute
    Perform writes. Without this flag, runs in preview/dry-run mode.

.PARAMETER TaskId
    Orchestrator TaskLog ID passed by the engine at launch.

.PARAMETER ProcessId
    Orchestrator ProcessRegistry ID passed by the engine at launch.

.COMPONENT
    BatchOps

.NOTES
    File Name : Collect-Example.ps1
    Location  : E:\xFACts-PowerShell

    FILE ORGANIZATION
    -----------------
    CHANGELOG
    IMPORTS
    PARAMETERS: SCRIPT PARAMETERS
    INITIALIZATION: SCRIPT INITIALIZATION
    VARIABLES: SCRIPT STATE
    FUNCTIONS: COLLECTION HELPERS
    EXECUTION: SCRIPT EXECUTION
#>

# ============================================================================
# CHANGELOG
# ----------------------------------------------------------------------------
# Date-stamped change history. Each entry is one ISO date line followed by an
# indented description. Entries appear most-recent first.
# Prefix: (none)
# ============================================================================

# 2026-05-13  Initial implementation per file format spec v1.

# ============================================================================
# IMPORTS
# ----------------------------------------------------------------------------
# Shared infrastructure for xFACts standalone scripts.
# Prefix: (none)
# ============================================================================

. "$PSScriptRoot\xFACts-OrchestratorFunctions.ps1"

# ============================================================================
# PARAMETERS: SCRIPT PARAMETERS
# ----------------------------------------------------------------------------
# Script-level parameters with engine integration defaults.
# Prefix: (none)
# ============================================================================

[CmdletBinding()]
param(
    [string]$ServerInstance = "AVG-PROD-LSNR",
    [string]$Database = "xFACts",
    [switch]$Execute,
    [long]$TaskId = 0,
    [int]$ProcessId = 0
)

# ============================================================================
# INITIALIZATION: SCRIPT INITIALIZATION
# ----------------------------------------------------------------------------
# One-time setup of shared infrastructure, log file path, and application
# identity for DMV attribution.
# Prefix: (none)
# ============================================================================

Initialize-XFActsScript -ScriptName 'Collect-Example' `
    -ServerInstance $ServerInstance -Database $Database -Execute:$Execute

# ============================================================================
# VARIABLES: SCRIPT STATE
# ----------------------------------------------------------------------------
# Mutable script-scope state populated during execution.
# Prefix: (none)
# ============================================================================

# Collected records count for execution summary
$script:RecordsCollected = 0

# ============================================================================
# FUNCTIONS: COLLECTION HELPERS
# ----------------------------------------------------------------------------
# Helper functions for fetching source data, transforming records, and
# writing results to the xFACts database.
# Prefix: (none)
# ============================================================================

function Get-ExampleSourceData {
    [CmdletBinding()]
    param()
    <#
    .SYNOPSIS
        Fetches example records from the source system.
    .DESCRIPTION
        Queries the source database for new example records using the
        AG-aware read server determined at initialization.
    #>

    Get-SqlData -Query @"
        SELECT example_id, example_name, example_value, example_created_dttm
        FROM dbo.ExampleSource
        WHERE example_created_dttm >= DATEADD(HOUR, -24, GETDATE())
"@
}

function Write-ExampleData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [array]$Records
    )
    <#
    .SYNOPSIS
        Writes collected example records to xFACts.
    .DESCRIPTION
        Inserts the provided records into BatchOps.Example using
        parameterized INSERT statements.
    #>

    foreach ($record in $Records) {
        Invoke-SqlNonQuery -Query @"
            INSERT INTO BatchOps.Example (example_id, example_name, example_value, created_dttm)
            VALUES (@id, @name, @value, @createdDttm)
"@ -Parameters @{
            id          = $record.example_id
            name        = $record.example_name
            value       = $record.example_value
            createdDttm = $record.example_created_dttm
        }
        $script:RecordsCollected++
    }
}

# ============================================================================
# EXECUTION: SCRIPT EXECUTION
# ----------------------------------------------------------------------------
# Main script execution: fetch source data, write to xFACts, complete
# the orchestrator task callback.
# Prefix: (none)
# ============================================================================

Write-Log "Starting Collect-Example" "INFO"

$sourceRecords = Get-ExampleSourceData

if ($sourceRecords) {
    Write-Log "Fetched $($sourceRecords.Count) source records" "INFO"
    if ($Execute) {
        Write-ExampleData -Records $sourceRecords
        Write-Log "Wrote $script:RecordsCollected records to xFACts" "SUCCESS"
    }
    else {
        Write-Log "Preview mode - would write $($sourceRecords.Count) records" "INFO"
    }
}
else {
    Write-Log "No source records found" "INFO"
}

if ($TaskId -gt 0) {
    Complete-OrchestratorTask -TaskId $TaskId -ProcessId $ProcessId -Status 'SUCCESS' `
        -OutputSummary "Collected $script:RecordsCollected records"
}
```

### 20.4 Minimal complete module file

```powershell
<#
.SYNOPSIS
    xFACts - Example Helpers Module

.DESCRIPTION
    PowerShell module providing example helper functions for the Control
    Center. Loaded via Import-Module at server startup.

.COMPONENT
    ControlCenter.Shared

.NOTES
    File Name : xFACts-ExampleHelpers.psm1
    Location  : E:\xFACts-ControlCenter\scripts\modules

    FILE ORGANIZATION
    -----------------
    IMPORTS
    CONSTANTS: MODULE CONSTANTS
    FUNCTIONS: EXAMPLE HELPERS
    EXPORTS: MODULE EXPORTS
#>

# ============================================================================
# IMPORTS
# ----------------------------------------------------------------------------
# External module dependencies.
# Prefix: (none)
# ============================================================================

Import-Module SqlServer

# ============================================================================
# CONSTANTS: MODULE CONSTANTS
# ----------------------------------------------------------------------------
# Module-scope constants used by helper functions.
# Prefix: (none)
# ============================================================================

# Default connection string for the xFACts database
$script:ConnectionString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Application Name=xFACts Control Center;"

# ============================================================================
# FUNCTIONS: EXAMPLE HELPERS
# ----------------------------------------------------------------------------
# Helper functions for the Example module.
# Prefix: (none)
# ============================================================================

function Get-ExampleData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$ExampleId
    )
    <#
    .SYNOPSIS
        Retrieves a single example record by ID.
    .DESCRIPTION
        Queries BatchOps.Example for the record matching the provided ID
        and returns it as a hashtable.
    .PARAMETER ExampleId
        The example_id to retrieve.
    #>

    # function body
}

# ============================================================================
# EXPORTS: MODULE EXPORTS
# ----------------------------------------------------------------------------
# Public functions exported from this module.
# Prefix: (none)
# ============================================================================

Export-ModuleMember -Function Get-ExampleData
```

---

## Appendix — Rationale

This appendix explains why selected rules are what they are. Entries are keyed to body section numbers. Sections without entries here have no rationale beyond the rule itself.

### A.1 Required structure

The strict three-part structure (header, sections, end-of-file) is what lets the parser walk a file deterministically: the parse position is always either reading the header, reading inside a section, or done. This mirrors the same discipline used by CSS, JS, and HTML specs in this codebase.

### A.2 File header

PowerShell's native comment-based-help is the parseable PowerShell standard for file-level metadata. `Get-Help <file>` consumes it automatically, editor tooling parses it, and PowerShell ecosystem conventions assume its presence. Choosing comment-based-help over a `#`-line-comment block aligns the spec with the language's native facility.

`.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER`, `.COMPONENT`, and `.NOTES` are the five keywords with clear single-purpose semantics; the others (`.EXAMPLE`, `.INPUTS`, etc.) are forbidden because they either bloat the header without consistent value (`.EXAMPLE`), have no natural fit (`.INPUTS`, `.OUTPUTS`, `.LINK`), or duplicate semantics covered by the five core keywords.

`.EXAMPLE` is forbidden specifically because example blocks tend to either repeat what `.SYNOPSIS` and `.PARAMETER` already say, or go stale when calling conventions change. Operators invoking xFACts scripts use the engine's task launcher; they don't typically read script `.EXAMPLE` blocks. Removing them eliminates a maintenance liability without functional cost.

`.COMPONENT` carries the component name. This is the keyword's native PowerShell semantic — `Get-Help -Component <name>` filters help topics by this field. Putting the component name there unlocks that native filter while also serving as the canonical single source of truth for cross-referencing against `dbo.Component_Registry`.

`.NOTES` carries File Name, Location, and FILE ORGANIZATION. PowerShell convention puts structured file-level metadata in `.NOTES`; FILE ORGANIZATION fits that mold as "structured metadata about the file's structure." Three fields, fixed order, no author/date/version fields — that boilerplate has no value when git is the source of truth for change attribution and date-driven CHANGELOG is the change history mechanism.

The FILE ORGANIZATION list mirrors the same approach used by CSS and JS specs. Verbatim matching against body banners makes the list a real table of contents — readers can search the file for any entry's text and find the corresponding banner.

### A.3 Section banners

The 76-character rule for both `=` and `-` rule lines is shared with CSS, JS, and HTML specs. A fixed length makes banners visually uniform across the codebase, with the chosen value fitting within an 80-column convention plus the `# ` comment-marker prefix.

The mandatory `Prefix:` line is the mechanism for catalog-time validation of identifier scoping. Without it, the catalog has no way to distinguish "function should have a prefix" from "function should not have a prefix" without re-parsing the file's context. With it, the populator emits one `COMMENT_BANNER` row carrying the prefix and uses that as the authority for validating identifiers in the section.

The mandatory NAME (no banner with a bare `<TYPE>:` title) keeps the FILE ORGANIZATION list's entries informative. A list with `FUNCTIONS`, `FUNCTIONS`, `FUNCTIONS` is uninformative; `FUNCTIONS: DATABASE HELPERS`, `FUNCTIONS: RBAC HELPERS`, `FUNCTIONS: NAVIGATION` is a real table of contents.

### A.4 Section types

The 10-type enum was reached by working from the CSS/JS spec precedent (`IMPORTS`, `CONSTANTS`, `STATE`/`VARIABLES`, `FUNCTIONS`) and adding PowerShell-specific types for concepts that don't exist in CSS/JS: `CHANGELOG` (PS uses date-driven change history; CSS/JS forbid this), `PARAMETERS` (PS-specific `param()` block concept), `INITIALIZATION` (one-shot setup calls at file scope, no JS analog), `EXECUTION` (procedural body at file end, no JS analog), `ROUTE` (Pode-specific), `EXPORTS` (`.psm1`-specific).

The naming choice of `VARIABLES` over JS's `STATE`, and `EXECUTION` over JS's `MAIN`-equivalent, reflects PowerShell idiom: a PowerShell developer reading `# === VARIABLES ===` immediately understands top-level `$script:` declarations. `STATE` carries JS connotations that don't translate.

`CONSTANTS` and `VARIABLES` separation, despite PowerShell not enforcing immutability at the language level, signals authorial intent — values in CONSTANTS are not modified after declaration; values in VARIABLES are. The convention is parser-cataloged but not language-enforced.

`CONFIGURATION` was considered as a separate type for GlobalConfig-loading patterns but rejected. The defaults-then-load-from-DB pattern collapses cleanly into a `$script:Config` hashtable declared in VARIABLES (with hardcoded defaults) and overwritten in EXECUTION (when the script loads GlobalConfig values). No separate type needed.

### A.4.1 Allowed types per role

The matrix in §4.1 reflects what each role's purpose demands:

- **page-route** holds exactly one Pode `Add-PodeRoute` call and may carry a CHANGELOG. No functions (helpers belong in modules), no state at file scope (the route scriptblock has its own scope), no procedural execution at file scope.
- **api-route** holds one or more Pode `Add-PodeRoute` calls under a single `ROUTE: API ENDPOINTS` banner. No CHANGELOG (the api-route is owned-by-its-page-route and changes track via the page-route's CHANGELOG or via the catalog itself).
- **module** is a function library with explicit exports. Functions are required (otherwise the module is meaningless); EXPORTS is required (otherwise nothing is callable from outside); CHANGELOG is forbidden (modules are referenced by their callers, not consumed as standalone deliverables).
- **standalone** is a self-contained script that performs work. EXECUTION is required (a standalone without procedural code is not a standalone, it's a function library — that's the shared-library role). PARAMETERS and INITIALIZATION are PS-only concepts standalones use to declare script-level params and call shared-infra setup.
- **shared-library** is a function library distributed via dot-source. Functions are required; CHANGELOG is allowed (these are deliverables in their own right and have their own change history); EXECUTION is forbidden (libraries don't execute, they're consumed).

The role of api-route receiving no CHANGELOG warrants explanation: api-routes are tightly coupled to their corresponding page-routes (e.g., `BatchMonitoring.ps1` and `BatchMonitoring-API.ps1` are versioned as a single unit). Duplicating CHANGELOG between them would invite divergence. Treating the page-route's CHANGELOG as the canonical record for the page+API pair keeps the change history single-sourced.

### A.5 Prefix

The 3-character prefix length is shared with CSS and JS. Same component, same prefix value across all file types belonging to the component — a single discipline that makes class names, function names, and IDs immediately recognizable as belonging to their owning component.

The underscore separator (`<prefix>_<base>`) differs from CSS's hyphen separator (`<prefix>-<base>`). PowerShell identifiers cannot contain hyphens at the top level of an unquoted name, so the underscore is the natural choice — and it matches JS's underscore convention for the same reason.

The registry validation rule (Section 5.4) makes `Component_Registry.cc_prefix` the source of truth for which prefix belongs to which component. The same mechanism is used by CSS and JS specs to detect drift between authored prefix values and the platform's registered understanding.

### A.7 CHANGELOG section

Date-driven change history is the platform's chosen mechanism for tracking file-level changes. Version numbers were retired in favor of dates because the engine ecosystem (with shared infrastructure dot-sourced into many scripts) made version-number coordination across files painful and unreliable. Dates are unambiguous, append-only, and naturally chronological.

The per-entry catalog row design (`PS_CHANGELOG_ENTRY` rather than catching the whole CHANGELOG block as one row) lets the catalog answer queries like "show every change across the codebase in the last 30 days" with a single `WHERE component_name BETWEEN '2026-04-13' AND '2026-05-13'` predicate. Aggregating by date or by file is straightforward.

CHANGELOG forbidden in api-route and module files reflects the coupling described in A.4.1 — these files don't have independent release cadence from their consumers.

### A.8 Function definitions

`[CmdletBinding()]` is mandatory because it unlocks advanced function features (common parameters like `-Verbose`, `-ErrorAction`; parameter validation; pipeline behaviors). Without it, a function is a "simple function" that loses these features. There's no good reason for an xFACts function to forgo them.

Comment-based-help on every function is mandatory because the function is part of the platform's discoverable API. `Get-Help Get-UserAccess` should return formatted help; that requires the docblock. Without it, a function is opaque to anyone who isn't reading the source.

The Verb-Noun convention plus approved-verb list comes from PowerShell itself. `Get-Verb` enumerates the canonical set; using verbs outside the list trips PowerShell warnings on module load. Following the convention also makes function purpose self-documenting — `Get-`, `Set-`, `Test-`, `Invoke-` carry near-universal meaning across PowerShell codebases.

Functions forbidden in route files because route files are about route registration, not about defining reusable logic. A helper inside `BatchMonitoring.ps1` is not callable from other pages and is not discoverable in the module catalog. Putting helpers in `xFACts-Helpers.psm1` (or a dedicated module) makes them shareable and cataloged.

### A.9 Variables and constants

The `$script:` (lowercase) scope qualifier is mandatory because PowerShell's case-equivalence between `$script:` and `$Script:` makes the catalog ambiguous if both forms are allowed. Picking one and forbidding the other gives the populator a single canonical form to validate.

The CONSTANTS vs VARIABLES distinction, despite PowerShell not enforcing immutability, is a discipline aid. `Set-Variable -Option Constant` exists in the language but is rarely used because it's verbose. Declaring intent via section placement (immutable values in CONSTANTS, mutable in VARIABLES) is lighter-weight and parser-cataloged.

### A.10 Imports

The single-IMPORTS-section rule (versus scattering imports throughout the file) makes dependency tracking trivial — every import is in one place, and the populator emits `MODULE_IMPORT USAGE` rows for all of them at known line ranges.

Dot-source vs `Import-Module` semantics differ in PowerShell: dot-source brings the source file's content into the current scope (so `$script:` variables set by `Initialize-XFActsScript` become visible in the calling script), while `Import-Module` creates a separate module scope. Both are permitted in IMPORTS because both are legitimate patterns the codebase uses — the dot-source for shared infrastructure libraries, `Import-Module` for proper `.psm1` modules.

### A.11 Routes

The mandatory `-Authentication 'ADLogin'` parameter on every route reflects platform policy: no route is publicly accessible without authentication. The drift code surfaces violations at catalog time rather than at runtime, when an unauthenticated public endpoint would already be deployed.

The RBAC-check rules (`Get-UserAccess` for pages, `Test-ActionEndpoint` for mutating APIs) layer on top of authentication. Authentication answers "who is this user?"; RBAC answers "is this user allowed to do this?". Both are required for the system's defense-in-depth model.

### A.12 SQL query embedding

Here-string SQL (`@"..."@`) is the canonical form because multi-line SQL is more readable than escaped-quote single-line strings, and the catalog can extract the SQL text cleanly. Inline single-line SQL works for one-line queries but produces unreadable code for anything with joins, multiple WHERE clauses, or CTEs.

The `-TrustServerCertificate` requirement comes from the environment — the SQL Server certificates in use aren't fully trusted by the calling host, so explicit acceptance is required for every call. Forgetting it causes runtime connection failures; cataloging the requirement and emitting drift on absence catches the omission at file-format-check time.

The `-ApplicationName` requirement enables DMV attribution — queries appearing in `sys.dm_exec_sessions` and `sys.dm_exec_requests` can be traced back to their originating xFACts script. Without it, DMV output shows generic "Microsoft SQL Server" as the application name for every connection.

### A.13 Comments

The four-comment-form rule (header, banner, docblock, inline `#`) is restrictive on purpose. PowerShell allows many comment forms; the spec narrows to four to make the parser's life simple and to make the catalog's view of "where comments live" complete and queryable.

Mini-banners (`# ---`) and box-drawing characters (`# ──`) are forbidden because they create informal sub-structure within a section that the populator can't reliably catalog. Authors who feel the urge to add a mini-banner should instead create a new top-level banner (Section 14.1) — that's catalog-visible and queryable.

Headstone comments ("this code was removed because...") are forbidden because git history is the source of truth for removed code. A headstone comment duplicates what git already provides and creates a permanent reminder of something no longer relevant.

### A.16 Catalog model

A row's composite identity (component_type, component_name, reference_type, file_name, occurrence_index, variant_type, variant_qualifier_1, variant_qualifier_2) supports queries that need to distinguish multiple definitions of the same name (LOCAL vs SHARED), multiple usages of the same identifier within a file, and variant forms of base types.

Variant model design mirrors JS — base-plus-variant pattern for types with a natural "regular" form (e.g., `PS_FUNCTION` base, `PS_FUNCTION_VARIANT` for filters), and always-non-NULL-variant pattern for types where every instance has a variant flavor (e.g., `PS_ROUTE` with HTTP method as variant, `MODULE_IMPORT` with import-form as variant).

### A.18 Drift codes — granularity

The drift code set is intentionally granular. A single combined code (`MALFORMED_FILE_HEADER`, say) would collapse every kind of header non-conformance into one verdict, which makes refactor work hard to triage. Granular codes (`MISSING_SYNOPSIS`, `MISSING_DESCRIPTION`, `FORBIDDEN_CHANGELOG_IN_HEADER`, `MALFORMED_NOTES_FIELD`, etc.) let queries like "find every file missing `.COMPONENT`" or "list every header still carrying an Author field" target the precise refactor work.

The same philosophy is shared with CSS, JS, and HTML specs — each rule violation gets its own code, allowing both per-rule queries and per-file rollups via `STRING_SPLIT(drift_codes, ',')`.

# xFACts PowerShell File Format Specification

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

| TYPE | page-route | api-route | module | standalone | shared-library | cc-bootstrap |
|---|---|---|---|---|---|---|
| `CHANGELOG` | Allowed | Forbidden | Forbidden | Allowed | Allowed | Allowed |
| `PARAMETERS` | Forbidden | Forbidden | Forbidden | Allowed | Forbidden | Forbidden |
| `IMPORTS` | Forbidden | Forbidden | Allowed | Allowed | Forbidden | Allowed |
| `INITIALIZATION` | Forbidden | Forbidden | Forbidden | Allowed | Forbidden | Forbidden |
| `CONSTANTS` | Forbidden | Forbidden | Allowed | Allowed | Allowed | Allowed |
| `VARIABLES` | Forbidden | Forbidden | Allowed | Allowed | Allowed | Allowed |
| `FUNCTIONS` | Forbidden | Forbidden | Required (1+) | Allowed | Required (1+) | Forbidden |
| `EXECUTION` | Forbidden | Forbidden | Forbidden | Required (exactly 1) | Forbidden | Required (exactly 1) |
| `ROUTE` | Required (exactly 1) | Required (exactly 1) | Forbidden | Forbidden | Forbidden | Forbidden |
| `EXPORTS` | Forbidden | Forbidden | Required (exactly 1) | Forbidden | Forbidden | Forbidden |

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
- In files whose component has `cc_prefix = NULL`, top-level identifiers are not prefix-constrained. This applies regardless of file role, and includes standalone scripts unassociated with a module, the `cc-bootstrap` file, shared-library files, and modules whose components are platform-wide buckets. Function-naming rules in these files are governed by §8.1.

---

## 6. File roles

The file role determines which section types are allowed and which structural rules apply. Role is derived from the file's dbo.Object_Registry classification (§6.1).

Separately, files carry classification attributes (zone, scope, scope_tier) from dbo.Object_Registry that govern resolution and documentation treatment — see §6.3.

### 6.1 Role detection

Role is derived from the file's dbo.Object_Registry `object_type`, `scope`, and `scope_tier`, evaluated in this order:

| Role | Detection rule |
|---|---|
| `cc-bootstrap` | `scope_tier` is `BOOTSTRAP`. Evaluated first. |
| `module` | `object_type` is `Module`. |
| `api-route` | `object_type` is `API`. |
| `page-route` | `object_type` is `Route`. |
| `shared-library` | `object_type` is `Script` and `scope` is `SHARED`. |
| `standalone` | `object_type` is `Script` and `scope` is not `SHARED`. |

A file with no active Object_Registry row, or with an unrecognized `object_type`, resolves to role `<undefined>` and is skipped for role-specific section checks (`FILE_NOT_REGISTERED` still fires; see §17). `.psd1` data files such as `server.psd1` are out of scope.

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

#### 6.2.6 cc-bootstrap

The Control Center server composition root (`Start-ControlCenter.ps1`). Unlike the page/api route files it loads, its working body is a single `Start-PodeServer` block, bannered as `EXECUTION` and treated as opaque: the `Add-PodeRoute`, `Add-PodeMiddleware`, and import statements registered inside that block are not subject to file-scope section placement (they cannot be lifted out of the server scriptblock, which Pode requires them to run inside). Accordingly, `ROUTE_OUTSIDE_ROUTE_SECTION`, `MIDDLEWARE_OUTSIDE_INIT_SECTION`, and `MISPLACED_IMPORT` (for imports inside the `EXECUTION` block) do not apply to this role.

Required: `EXECUTION` (exactly one, with NAME `SCRIPT EXECUTION`).
Allowed: `CHANGELOG`, `IMPORTS`, `CONSTANTS`, `VARIABLES`.
Forbidden: `PARAMETERS`, `INITIALIZATION`, `FUNCTIONS`, `ROUTE`, `EXPORTS`.

#### 6.3 Classification: zone, scope, and scope_tier

Files are classified by three dbo.Object_Registry attributes, independent of role. Each applies only where meaningful; rows where an attribute does not apply hold NULL.

- zone — cc, docs, standalone, or exempt. References resolve only within the same zone.
- scope — LOCAL or SHARED.
- scope_tier — PLATFORM or SCOPED for SHARED function-bearing files; BOOTSTRAP for the Control Center composition root; otherwise NULL. PLATFORM and SCOPED determine docblock treatment (§8.3 / §8.4); BOOTSTRAP designates the cc-bootstrap role (§6.1).

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

*Rules in this section vary by file. A file's complete rule set is the General Rules (§8.1) plus the one subsection that applies: §8.2 for page-route and api-route files, §8.3 for PLATFORM-tier files, §8.4 for SCOPED-tier and standalone files. General alone is incomplete, and exactly one subsection applies.*

### 8.1 General rules

These rules apply to every function in any file whose role permits functions.

- Every function declares a `param()` block, even if empty. Functions taking pipeline input or no parameters at all still declare `param()` — empty, or with the appropriate parameter attributes.
- Function names follow PowerShell's `Verb-Noun` convention. The verb is from the PowerShell approved verb list (`Get-Verb`). Functions starting with an underscore or any non-letter character are forbidden.
- In files whose component has a non-NULL `cc_prefix`, the noun half of the function name begins with that prefix followed by an underscore (e.g., `Get-bkp_OpenBatches` in a file with prefix `bkp`). In files whose component has `cc_prefix = NULL`, no prefix is applied; the function name is bare `Verb-Noun` (e.g., `Initialize-XFActsScript`).
- The `filter` keyword form is forbidden. All functions use the `function` keyword. Pipeline-processing functions declare an explicit `process { ... }` block instead.
- Function declarations are forbidden inside another function's body.
- Function declarations are forbidden inside conditional or loop blocks (`if`, `else`, `while`, `do`, `for`, `foreach`, `switch`, `try`, `catch`, `finally`).
- **Within a zone**, a function name in a non-shared file must not match the name of a SHARED function in the same zone.
- **Within a zone**, the same function name must not be declared by more than one PS file.
- Function calls reference names defined in a cataloged PS file or in an imported external module.
- `[OutputType()]` is permitted but not required.
- Every function is documented. The form of documentation depends on file role — see the role subsection below.

### 8.2 Page-route and api-route files

- Function declarations are forbidden. Helpers belong in modules.

### 8.3 PLATFORM-tier files

Applies to files with scope_tier = PLATFORM (broadly-consumed shared infrastructure).

- `[CmdletBinding()]` is mandatory and appears first inside the function body, before `param()`.
- The comment-based-help docblock is mandatory and is positioned as the third construct inside the function body, after `[CmdletBinding()]` and `param()` and before the body code:

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

- The docblock requires `.SYNOPSIS` and `.DESCRIPTION`. `.PARAMETER` blocks correspond 1:1 with declared parameters — every declared parameter has a matching `.PARAMETER` block, no `.PARAMETER` block references a parameter the function does not declare, and the `.PARAMETER` blocks appear in the same order as the parameters in the `param()` block. `.COMPONENT`, `.NOTES`, `.EXAMPLE`, and other keywords are forbidden in function docblocks.

### 8.4 SCOPED-tier and standalone files

Applies to files with scope_tier = SCOPED (narrowly-scoped shared helpers), to standalone-role scripts (which carry no scope_tier), and to the cc-bootstrap file (should it ever define functions). The latter two carry no scope_tier.- `[CmdletBinding()]` is permitted but not required.

- Each function carries a single-line `#` purpose comment on the line directly above the function declaration, stating the purpose the docblock's `.SYNOPSIS` would otherwise convey.
- A comment-based-help docblock is not used.

---

## 9. Variables and constants

*Rules in this section vary by file role. A file's complete rule set is the General Rules (§9.2) plus the one role subsection matching the file — General alone is incomplete, and only one role subsection applies.*

Top-level declarations split into two kinds based on the section they live in:

- **`CONSTANTS` sections** — declarations of immutable values.
- **`VARIABLES` sections** — declarations of mutable values.

### 9.1 Declaration form

All top-level declarations use the `$script:` scope qualifier (lowercase):

```powershell
$script:DefaultTimeout = 300        # in a CONSTANTS section
$script:Config = @{}                # in a VARIABLES section
```

### 9.2 General rules

- `$script:` (lowercase) is the only permitted scope qualifier for top-level variable and constant declarations.
- `$global:` declarations are forbidden anywhere in the file.
- The `$env:` provider may be written at file scope only for these environment variables: `NODE_PATH`.
- Assignment to PowerShell automatic variables (`$args`, `$_`, `$matches`, `$input`, `$PSScriptRoot`, etc.) is forbidden.
- Each declaration gets its own statement. Chained assignments (`$a = $b = $c = 0`) are forbidden.
- Every constant and variable declaration is preceded by a single-line `#` comment describing its purpose.
- In prefixable files, identifier names begin with the file's registered prefix followed by an underscore. Naming convention is `PascalCase` after the prefix.
- A constant — a value assigned once and not reassigned — lives in a CONSTANTS section. A mutable variable — a value reassigned or accumulated into after initialization — lives in a VARIABLES section.

### 9.3 Standalone files

- A top-level assignment that performs work as the script runs lives in the EXECUTION section. It is part of execution, not a file-scope declaration.

---

## 10. Imports

The `IMPORTS` section contains dot-source statements and `Import-Module` calls. Modules and standalone scripts may have IMPORTS sections; route files and shared-library files may not.

### 10.1 Rules

- One import per statement. Chained imports are forbidden.
- Import statements appear only in the IMPORTS section. A file-scope import elsewhere is misplaced.
- Three forms are recognized:
  - Dot-source: `. "$PSScriptRoot\xFACts-OrchestratorFunctions.ps1"`
  - Import-Module by path: `Import-Module -Name "$PSScriptRoot\modules\xFACts-CCShared.psm1"`
  - Import-Module by name: `Import-Module SqlServer`
- A file with no imports omits the IMPORTS banner entirely, along with its FILE ORGANIZATION entry.

### 10.2 In-function imports

An Import-Module or dot-source inside a function body is permitted only in the shared-library role; in all other roles it is misplaced.

---

## 11. Routes

The `ROUTE` section contains `Add-PodeRoute` calls registering web endpoints. Page-route files have exactly one route under `ROUTE: PAGE PATH`; api-route files have one or more routes under `ROUTE: API ENDPOINTS`.

### 11.1 Required form

Page route — `Get-UserAccess` first, `Write-PodeHtmlResponse` last:

```powershell
Add-PodeRoute -Method Get -Path '/example' -Authentication 'ADLogin' -ScriptBlock {
    $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/example'
    if (-not $access.HasAccess) {
        Write-PodeHtmlResponse -Value (Get-AccessDeniedHtml -DisplayName $access.DisplayName -PageRoute '/example') -StatusCode 403
        return
    }
    # ...page rendering...
    Write-PodeHtmlResponse -Value $html
}
```

API route — `Test-ActionEndpoint` guard as the first statement of each endpoint, `Write-PodeJsonResponse` last:

```powershell
Add-PodeRoute -Method Post -Path '/api/example/do-thing' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    # ...action logic...
    Write-PodeJsonResponse -Value $result
}
```

### 11.2 Rules

- Every `Add-PodeRoute` call declares `-Authentication 'ADLogin'`, except the named infrastructure routes listed in §11.3, which legitimately carry no AD authentication.
- Page routes call `Get-UserAccess` as the first statement of the scriptblock, before any other work. The result governs whether the route renders the page or returns an access-denied response.
- Every API route, regardless of HTTP method, calls `Test-ActionEndpoint` as the first line of the scriptblock. The call is the universal hook point; `Test-ActionEndpoint` is fail-open for endpoints not yet registered in `RBAC_ActionRegistry`, so registration takes effect automatically when added.
- Page routes end the scriptblock with `Write-PodeHtmlResponse`.
- API routes end the scriptblock with `Write-PodeJsonResponse`.
- Page-route files emit HTML via PowerShell here-strings (`@"..."@`).

### 11.3 Authentication-exempt infrastructure routes

A small, closed set of infrastructure routes legitimately carry no `-Authentication 'ADLogin'`, because AD form-login is either impossible or the wrong mechanism for them. These are exempt from the authentication requirement; every other route still requires it, and a new unauthenticated route flags `MISSING_AUTHENTICATION` on first scan. Adding to this set requires a spec amendment.

| Route | Why exempt |
|---|---|
| `/login` | The login page itself. Requiring authentication would redirect-loop, since it is reached precisely when the user is not authenticated. |
| `/logout` | Clears the session. Authentication to log out is backwards and breaks the expired-session case. |
| `/api/internal/engine-event` | Machine-to-machine endpoint the orchestrator POSTs engine events to. AD form-login is the wrong authentication type for a non-interactive caller; the route is protected instead by a localhost-only IP check (`127.0.0.1`/`::1`, else 403). |

---

## 12. SQL query embedding

SQL queries embedded in PowerShell files use here-strings (`@"..."@`), not inline single-line string literals.

### 12.1 Required form

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

PowerShell files use two sanctioned output mechanisms: `Write-Log` (defined in `xFACts-OrchestratorFunctions.ps1`) for durable, operator-facing output that belongs in the record, and the `Write-Console` helper family for ephemeral console output during interactive runs. `Write-Host` is forbidden in all files, with no exceptions.

### 15.1 Rules

- `Write-Log` is the mechanism for durable operator output (the audit/run record).
- `Write-Console` (and its companions `Write-ConsoleBanner` and `Write-ConsoleRule`) is the mechanism for ephemeral console output — real-time, colored, operator-facing narration during an interactive run. It is a faithful replacement for the console behavior `Write-Host` provided.
- `Write-Host` is forbidden in all files, with one exception: it is permitted inside the bodies of the sanctioned console-helper functions `Write-Console`, `Write-ConsoleBanner`, and `Write-ConsoleRule`. These helpers are the one place the primitive legitimately lives, because they are what make `Write-Host` unnecessary everywhere else. A `Write-Host` call anywhere else is always drift; the sanctioned path is `Write-Console`.

---

## 16. Forbidden patterns

| Pattern | Rule |
|---------|------|
| `.EXAMPLE`, `.INPUTS`, `.OUTPUTS`, `.LINK`, `.ROLE`, `.FUNCTIONALITY`, `.FORWARDHELPTARGETNAME`, `.REMOTEHELPRUNSPACE`, `.EXTERNALHELP` in file header | §2.1 |
| Author, Date, or Version field in file header | §2.1 |
| Function Inventory list in file header | §2.1 |
| Deployment block in file header | §2.1 |
| Inline `===` or `---` divider rules in file header outside the `.NOTES` FILE ORGANIZATION separator | §2.1 |
| `.NOTES` fields out of required order (File Name, Location, FILE ORGANIZATION) | §2.1 |
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
| Function name matching a SHARED function's name in the same zone | §8.1 |
| Duplicate function definition within a zone | §8.1 |
| Function call to a name not defined in any cataloged PS file | §8.1 |
| `Add-PodeRoute` without `-Authentication 'ADLogin'` (except the §11.3 infrastructure routes) | §11.2, §11.3 |
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
| `Write-Host` outside the sanctioned console-helper bodies (`Write-Console`, `Write-ConsoleBanner`, `Write-ConsoleRule`) | §15.1 |
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
| `NOTES_FIELD_ORDER_VIOLATION` | `.NOTES` fields appear out of required order (File Name, Location, FILE ORGANIZATION). | §2.1 |
| `PARAMETER_DOC_ORDER_VIOLATION` | `.PARAMETER` blocks do not appear in the same order as the parameters in the `param()` block. Applies to file-header docblocks (§2.1) and PLATFORM-tier function docblocks (§8.3). | §2.1, §8.3 |
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
| `FILE_NOT_REGISTERED` | A scanned `.ps1`/`.psm1` file has no active `Object_Registry` row; its zone and scope stamp as `<undefined>`. | §6.3 |
| `MALFORMED_CHANGELOG_ENTRY` | CHANGELOG entry does not begin with `# YYYY-MM-DD  `. | §7.2 |
| `MALFORMED_CHANGELOG_DATE` | CHANGELOG entry date is not in ISO YYYY-MM-DD format. | §7.2 |
| `CHANGELOG_ORDER_VIOLATION` | CHANGELOG entries appear out of most-recent-first order. | §7.2 |
| `FORBIDDEN_VERSION_IN_CHANGELOG` | A CHANGELOG entry contains a version literal. | §7.2 |
| `MISSING_DOCBLOCK` | Function has no comment-based-help docblock in its required position. | §8.3 |
| `MISPLACED_DOCBLOCK` | Function docblock is present but not in the required position (above the function declaration or after body code instead of immediately after `[CmdletBinding()]` and `param()`). | §8.3 |
| `MISSING_CMDLETBINDING` | Function declaration missing `[CmdletBinding()]`. | §8.3 |
| `MISSING_PARAM_BLOCK` | Function missing a `param()` block. | §8.1 |
| `MISSING_SYNOPSIS` | Function docblock missing `.SYNOPSIS`. | §8.3 |
| `MISSING_DESCRIPTION` | Function docblock missing `.DESCRIPTION`. | §8.3 |
| `MISSING_PARAMETER_DOC` | Function parameter without a matching `.PARAMETER` block in the docblock. | §8.3 |
| `EXTRA_PARAMETER_DOC` | Function docblock contains a `.PARAMETER` block for a parameter the function does not define. | §8.3 |
| `FORBIDDEN_DOCBLOCK_KEYWORD` | Function docblock contains `.COMPONENT`, `.NOTES`, `.EXAMPLE`, or other forbidden keywords. | §8.3 |
| `MALFORMED_FUNCTION_NAME` | Function name does not follow `Verb-Noun`. | §8.1 |
| `UNAPPROVED_VERB` | Function uses a verb not in PowerShell's approved verb list. | §8.1 |
| `FORBIDDEN_FUNCTION_IN_ROUTE` | Function declared in a page-route file. | §8.2 |
| `FORBIDDEN_FUNCTION_IN_API_ROUTE` | Function declared in an api-route file. | §8.2 |
| `FORBIDDEN_CONDITIONAL_DEFINITION` | Function declared inside a conditional or loop block. | §8.1 |
| `FORBIDDEN_NESTED_FUNCTION` | Function declared inside another function's body. | §8.1 |
| `FORBIDDEN_FILTER_FUNCTION` | Function declared with the `filter` keyword instead of `function`. | §8.1 |
| `SHADOWS_SHARED_FUNCTION` | A function in a non-shared file matches the name of a `SHARED` function in the same zone. | §8.1 |
| `DUPLICATE_FUNCTION_DEFINITION` | The same function name is declared by more than one PS file within the same zone. | §8.1 |
| `ORPHAN_FUNCTION_CALL` | Function call references a name not defined in any cataloged PS file. | §8.1 |
| `FORBIDDEN_DOCBLOCK_IN_STANDALONE` | A function in a SCOPED-tier or standalone file has a comment-based-help docblock. These functions use a single-line purpose comment instead. | §8.4 |
| `MISSING_FUNCTION_PURPOSE_COMMENT` | A function in a SCOPED-tier or standalone file has no single-line `#` purpose comment on the line directly above its declaration. | §8.4 |
| `FORBIDDEN_SCOPE_QUALIFIER` | Declaration uses `$Script:` (capital S) or other non-`$script:` scope. | §9.2 |
| `FORBIDDEN_GLOBAL_VARIABLE` | Declaration uses `$global:` scope. | §9.2 |
| `FORBIDDEN_ENV_ASSIGNMENT` | A `$env:` write targets a variable not on the permitted list. | §9.2 |
| `FORBIDDEN_AUTOVAR_REASSIGNMENT` | Assignment to a PowerShell automatic variable. | §9.2 |
| `FORBIDDEN_MULTI_DECLARATION` | Chained assignment in a single statement. | §9.2 |
| `MISSING_CONSTANT_COMMENT` | Constant declaration not preceded by a purpose comment. | §9.2 |
| `MISSING_VARIABLE_COMMENT` | Variable declaration not preceded by a purpose comment. | §9.2 |
| `MISPLACED_DECLARATION` | `$script:` declaration appears outside a CONSTANTS or VARIABLES section. | §9.2 |
| `MISPLACED_IMPORT` | Import statement appears outside the IMPORTS section. | §10.1 |
| `MISSING_AUTHENTICATION` | `Add-PodeRoute` lacks `-Authentication 'ADLogin'`. The §11.3 infrastructure routes (login, logout, internal engine-event) are exempt. | §11.2, §11.3 |
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

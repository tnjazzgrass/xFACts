<#
.SYNOPSIS
    xFACts - Asset Registry PowerShell Populator

.DESCRIPTION
    Walks every .ps1 and .psm1 file under the xFACts PowerShell roots
    (E:\xFACts-PowerShell, E:\xFACts-ControlCenter\scripts\routes,
    E:\xFACts-ControlCenter\scripts\modules), parses each file with the
    native PowerShell AST parser, and generates Asset_Registry rows
    describing every catalogable construct found in the file plus drift
    codes against CC_PS_Spec.md.

    Five file roles are recognized via path-based classification:
      - 'page-route'      - scripts\routes\<Page>\<Page>.ps1
      - 'api-route'       - scripts\routes\<Page>\<Page>-API.ps1
      - 'module'          - any .psm1 file
      - 'shared-library'  - xFACts-PowerShell\xFACts-<name>.ps1
      - 'standalone'      - any other .ps1 under xFACts-PowerShell

    Each role has a role-specific valid-section-types set passed to
    Get-BannerInfo so a role-inappropriate banner produces
    UNKNOWN_SECTION_TYPE drift rather than being silently accepted.

    This populator consumes shared infrastructure from
    xFACts-AssetRegistryFunctions.ps1: row construction, drift attachment,
    bulk insert, banner detection / parsing, file-header parsing
    (Get-PSFileHeaderInfo specifically for PS comment-based-help blocks),
    section list construction, registry loads, PS AST navigation
    (Find-PSAstNodes, Test-IsTopLevelPSAst, Test-IsConditionallyDefinedPSAst,
    position helpers).

    Categories of rows emitted:

    Structural (per CC_PS_Spec.md Sections 4-6):
      PS_FILE, FILE_HEADER, COMMENT_BANNER, PS_CHANGELOG

    Definitions (per CC_PS_Spec.md Section 7):
      PS_FUNCTION, PS_FUNCTION_VARIANT (filter), PS_DOCBLOCK,
      PS_PARAMETER, PS_CONSTANT, PS_VARIABLE, PS_EXPORT

    Pode infrastructure (per CC_PS_Spec.md Section 8):
      PS_ROUTE, PS_MIDDLEWARE, PS_WEBSOCKET_ROUTE

    Cross-file references:
      PS_FUNCTION_CALL (USAGE), MODULE_IMPORT, RBAC_CHECK,
      GLOBALCONFIG_REF, SQL_QUERY

    Forbidden patterns (per CC_PS_Spec.md Section 13):
      PS_WRITE_HOST, PS_INLINE_BANNER, PS_REMOVED_CODE_COMMENT

    Comment structure:
      PS_COMMENT_BLOCK (free-standing block comments)

    First-run expectation: substantial drift across most files since the
    PS file format spec is brand new and almost no PS files have been
    refactored yet. The catalog will reflect the current state and the
    refactor work ahead.

.PARAMETER Execute
    Required to actually delete the PS rows from Asset_Registry and write
    the new row set. Without this flag, runs in preview mode.

.PARAMETER FileFilter
    Optional file-name filter for processing a single file or subset
    (e.g., -FileFilter 'Collect-DMVMetrics.ps1' processes only that file).

.COMPONENT
    ControlCenter.AssetRegistry

.NOTES
    FILE ORGANIZATION
        1. CONFIGURATION: Paths and Discovery
        2. CONSTANTS: Spec Constants
        3. CONSTANTS: Drift Descriptions
        4. VARIABLES: Script-Scope State
        5. FUNCTIONS: File Role Detection
        6. FUNCTIONS: PS Parser and Comment Normalization
        7. FUNCTIONS: Format Helpers
        8. FUNCTIONS: SQL / GlobalConfig / RBAC Detection
        9. FUNCTIONS: Variant Shape Helpers
       10. FUNCTIONS: Local Definition Collection
       11. FUNCTIONS: Row Emitters
       12. FUNCTIONS: Comment Index
       13. EXECUTION: Pass 1 - Parse and Collect Shared Definitions
       14. EXECUTION: Registry Loads
       15. EXECUTION: Pass 2 - Per-File Walk
       16. EXECUTION: Pass 3 - Cross-File Compliance Checks
       17. EXECUTION: Output Boundary Validation
       18. EXECUTION: Occurrence Index Computation
       19. EXECUTION: Summary Output
       20. EXECUTION: Database Write
       21. EXECUTION: Object_Registry Miss Report
#>

[CmdletBinding()]
param(
    [switch]$Execute,
    [string]$FileFilter
)

# ============================================================================
# DOT-SOURCE SHARED INFRASTRUCTURE
# ============================================================================

. "$PSScriptRoot\xFACts-OrchestratorFunctions.ps1"
. "$PSScriptRoot\xFACts-AssetRegistryFunctions.ps1"

Initialize-XFActsScript -ScriptName 'Populate-AssetRegistry-PS' -Execute:$Execute

$ErrorActionPreference = 'Stop'


# ============================================================================
# CONFIGURATION: PATHS AND DISCOVERY
# ============================================================================

# Four scan roots cover all PS files in the xFACts platform:
#   1. xFACts-PowerShell                     - standalone scripts + shared libs
#   2. xFACts-ControlCenter\scripts          - Pode entry point (Start-ControlCenter.ps1)
#                                              and any other top-level CC bootstrap scripts
#                                              (server.psd1 lives here but is out of scope -
#                                              this populator only scans .ps1 and .psm1)
#   3. xFACts-ControlCenter\scripts\routes   - page-route and api-route .ps1
#   4. xFACts-ControlCenter\scripts\modules  - .psm1 helper modules
# Note: roots 2/3/4 are nested. The discovery loop walks each with -Recurse,
# which would double-count files under routes\ and modules\. Discovery
# de-duplicates by FullName after collection.
$PSScanRoots = @(
    'E:\xFACts-PowerShell',
    'E:\xFACts-ControlCenter\scripts',
    'E:\xFACts-ControlCenter\scripts\routes',
    'E:\xFACts-ControlCenter\scripts\modules'
)

# Shared library files (live in xFACts-PowerShell root). Functions defined
# in these files are visible to all consumers; the Pass 1 walk collects
# them into a shared-functions HashSet so PS_FUNCTION_CALL USAGE rows can
# resolve scope=SHARED with source_file pointing at the defining library.
$SharedLibraryFiles = @(
    'xFACts-OrchestratorFunctions.ps1',
    'xFACts-AssetRegistryFunctions.ps1',
    'xFACts-IndexFunctions.ps1'
)

# Module files (.psm1) exporting cataloged helpers. The CC route handlers
# import these and call their exported functions. Same treatment as shared
# libraries for USAGE resolution.
$SharedModuleFiles = @(
    'xFACts-Helpers.psm1'
)

# Path-based standalone exceptions: files that live in a routes-style
# directory but are structurally standalone (e.g. Start-ControlCenter.ps1
# is the Pode entry point, not a page route).
$StandalonePathExceptions = @(
    'Start-ControlCenter.ps1'
)

# Files exempt from Write-Host drift. The xFACts orchestrator entry-point
# script and a handful of CLI-style utilities legitimately use Write-Host
# for operator-facing output. Add to this list as needed; default behavior
# is to flag every Write-Host call as drift.
$WriteHostExemptFiles = @(
    'Start-xFACtsOrchestrator.ps1'
)


# ============================================================================
# CONSTANTS: SPEC CONSTANTS
# ============================================================================

# The 10 recognized section types per CC_PS_Spec.md Section 4. Different
# file roles permit different subsets; the per-role valid-section-types
# table below carves out the valid set for each role.
$AllValidSectionTypes = @(
    'CHANGELOG',
    'IMPORTS',
    'PARAMETERS',
    'INITIALIZATION',
    'CONSTANTS',
    'VARIABLES',
    'FUNCTIONS',
    'EXECUTION',
    'ROUTE',
    'EXPORTS'
)

# Required section order per CC_PS_Spec.md Section 4.1. The hashtable maps
# each section type to its order slot; lower slot = appears earlier. ROUTE
# and EXECUTION share slot 8 because they are mutually exclusive based on
# file role (page-routes have ROUTE; standalone scripts have EXECUTION).
$SectionTypeOrder = @{
    'CHANGELOG'      = 1
    'IMPORTS'        = 2
    'PARAMETERS'     = 3
    'INITIALIZATION' = 4
    'CONSTANTS'      = 5
    'VARIABLES'      = 6
    'FUNCTIONS'      = 7
    'EXECUTION'      = 8
    'ROUTE'          = 8
    'EXPORTS'        = 9
}

# Per-role valid section types. A banner whose type is not in the role's
# allowed list produces UNKNOWN_SECTION_TYPE drift via Get-BannerInfo.
# Per CC_PS_Spec.md Section 4.2:
#   page-route     - CHANGELOG, IMPORTS, INITIALIZATION, CONSTANTS,
#                    VARIABLES, FUNCTIONS, ROUTE
#   api-route      - CHANGELOG, IMPORTS, INITIALIZATION, CONSTANTS,
#                    VARIABLES, FUNCTIONS, ROUTE
#   module         - CHANGELOG, IMPORTS, CONSTANTS, VARIABLES,
#                    FUNCTIONS, EXPORTS
#   standalone     - CHANGELOG, IMPORTS, PARAMETERS, INITIALIZATION,
#                    CONSTANTS, VARIABLES, FUNCTIONS, EXECUTION
#   shared-library - CHANGELOG, IMPORTS, CONSTANTS, VARIABLES,
#                    FUNCTIONS, EXPORTS
$ValidSectionTypesByRole = @{
    'page-route'     = @('CHANGELOG','IMPORTS','INITIALIZATION','CONSTANTS','VARIABLES','FUNCTIONS','ROUTE')
    'api-route'      = @('CHANGELOG','IMPORTS','INITIALIZATION','CONSTANTS','VARIABLES','FUNCTIONS','ROUTE')
    'module'         = @('CHANGELOG','IMPORTS','CONSTANTS','VARIABLES','FUNCTIONS','EXPORTS')
    'standalone'     = @('CHANGELOG','IMPORTS','PARAMETERS','INITIALIZATION','CONSTANTS','VARIABLES','FUNCTIONS','EXECUTION')
    'shared-library' = @('CHANGELOG','IMPORTS','CONSTANTS','VARIABLES','FUNCTIONS','EXPORTS')
}

# Roles for which .COMPONENT in the file header is required (rather than
# merely allowed). Standalone scripts typically have .COMPONENT pointing
# at the component they serve; modules and shared libraries always do.
# Page-routes and api-routes do too. This is checked by Get-PSFileHeaderInfo
# when called with -RequireComponent.
$ComponentRequiredRoles = @('page-route','api-route','module','shared-library','standalone')

# Function names that count as RBAC checks per CC_PS_Spec.md Section 12.
# Calls to these functions produce RBAC_CHECK rows.
$RBACCheckFunctions = @(
    'Get-UserAccess',
    'Test-ActionEndpoint',
    'Get-UserPageTier',
    'Test-UserHasRole'
)

# Function names that take a -Query parameter pointing at a SQL string.
# Used by Pass D detection to fire SQL_QUERY rows on the -Query argument
# at the call site. (Permissive mode also fires SQL_QUERY rows on any
# here-string or string literal that passes Test-LooksLikeSQL regardless
# of how it's used; this list is for guaranteed-SQL detection.)
$SQLQueryFunctions = @(
    'Invoke-Sqlcmd',
    'Invoke-XFActsQuery',
    'Invoke-XFActsNonQuery',
    'Invoke-CRS5ReadQuery',
    'Invoke-AGReadQuery',
    'Invoke-SqlNonQuery',
    'Get-SqlData'
)

# Function names that take a -Setting parameter pointing at a GlobalConfig
# setting name. Used by GLOBALCONFIG_REF detection.
$GlobalConfigFunctions = @(
    'Get-GlobalConfigValue',
    'Set-GlobalConfigValue',
    'Test-GlobalConfigSetting'
)


# ============================================================================
# CONSTANTS: DRIFT DESCRIPTIONS
# ============================================================================
# Master table of every drift code the populator can emit. Used by
# Add-DriftCode (from helpers) to validate codes before attachment.
# Aligned with CC_PS_Spec.md Section 17.

$DriftDescriptions = [ordered]@{
    # ---- File header (Section 17.1) ----
    'MALFORMED_FILE_HEADER'             = "The file's header block is missing, malformed, or contains required fields out of order."
    'FORBIDDEN_CHANGELOG_IN_HEADER'     = "The file header contains a CHANGELOG block. CHANGELOG belongs in a dedicated section outside the header, not inside the comment-based-help block."
    'FORBIDDEN_AUTHOR_IN_HEADER'        = "The file header contains an Author: bookkeeping line. Authorship belongs in System_Metadata, not in source headers."
    'FORBIDDEN_DATE_IN_HEADER'          = "The file header contains a Date: bookkeeping line. Dates belong in System_Metadata, not in source headers."
    'FORBIDDEN_VERSION_IN_HEADER'       = "The file header contains a Version: line with content other than 'Tracked in dbo.System_Metadata'. Version numbers belong in System_Metadata only."
    'FORBIDDEN_FUNCTION_INVENTORY'      = "The file header contains a Function Inventory block. The function list belongs in the FILE ORGANIZATION section, not as a separate enumeration."
    'FORBIDDEN_DEPLOYMENT_BLOCK'        = "The file header contains a Deployment: block. Deployment instructions belong in an external runbook, not in the source file header."
    'FORBIDDEN_INLINE_DIVIDER_IN_HEADER' = "The file header contains inline divider rules of '=' or '-' characters. Use .NOTES blocks or section banners for separation; inline rules inside the header are not part of the comment-based-help spec."
    'MISSING_COMPONENT_DECLARATION'     = "The file header is missing a .COMPONENT declaration. Files in this role must declare which Component_Registry component they belong to."
    'INVALID_COMPONENT_VALUE'           = "The file header's .COMPONENT value does not match any active row in Component_Registry."
    'FILE_ORG_MISMATCH'                 = "The FILE ORGANIZATION list inside .NOTES does not exactly match the section banner titles in the file body, by content or by order."

    # ---- Section banners (Section 17.2) ----
    'MISSING_SECTION_BANNER'            = "A function definition (or other catalogable construct) appears outside any banner -- no section banner precedes it in the file."
    'BANNER_INLINE_SHAPE'               = "A section banner uses the single-line ===== Title ===== form. The spec requires a multi-line banner with bracketing rule lines, title line, separator, description block, and Prefix line."
    'BANNER_INVALID_RULE_CHAR'          = "A section banner's opening or closing bracketing line is not composed entirely of '=' characters. Both bracket lines must be all '='."
    'BANNER_INVALID_RULE_LENGTH'        = "A section banner's opening or closing bracketing line is composed of '=' characters but is not exactly 76 characters long."
    'BANNER_INVALID_SEPARATOR_CHAR'     = "A section banner's middle separator line is missing or is not composed entirely of '-' characters. The separator must be all '-'."
    'BANNER_INVALID_SEPARATOR_LENGTH'   = "A section banner's middle separator line is not exactly 76 '-' characters long."
    'BANNER_MALFORMED_TITLE_LINE'       = "A section banner has no recognizable title line in the form '<TYPE>: <NAME>'. The TYPE token must be uppercase letters and underscores only."
    'BANNER_MISSING_DESCRIPTION'        = "A section banner has no description content between the separator and the Prefix line. The description is required (1 to 5 sentences explaining what the section contains)."
    'UNKNOWN_SECTION_TYPE'              = "A section banner declares a TYPE not valid for the file's role. Each role has its own permitted section-type set per CC_PS_Spec.md Section 4.2."
    'SECTION_TYPE_ORDER_VIOLATION'      = "Section types appear out of the required order for the file role."
    'MISSING_PREFIX_DECLARATION'        = "A section banner is missing the mandatory Prefix line in its description block."
    'MALFORMED_PREFIX_VALUE'            = "A section banner's Prefix line declares anything other than a single 3-character lowercase prefix or (none)."
    'PREFIX_REGISTRY_MISMATCH'          = "A section banner's declared prefix does not match Component_Registry.cc_prefix for the file's component."
    'DUPLICATE_BANNER_NAME'             = "Two or more section banners with the same TYPE and NAME appear in the file. Each banner must be unique within a file."

    # ---- Function definitions (Section 17.3) ----
    'MISSING_DOCBLOCK'                  = "A function definition is not preceded by a comment-based-help block (<# .SYNOPSIS ... #>). Every function must carry a docblock."
    'MISSING_CMDLETBINDING'             = "A function definition is missing the [CmdletBinding()] attribute. Per spec, all functions must declare CmdletBinding."
    'PREFIX_MISMATCH'                   = "A function name does not begin with the prefix declared in its containing section's banner followed by '-'."
    'PREFIX_MISSING'                    = "A top-level function does not start with the file's registered prefix. Component_Registry declares a cc_prefix for the file but the function name does not match. Fires independently of banners; surfaces prefix non-conformance in pre-spec files."
    'SHADOWS_SHARED_FUNCTION'           = "A non-shared file defines a function whose name matches a shared-library export."
    'FORBIDDEN_CONDITIONAL_DEFINITION'  = "A function is declared inside an if/while/do/for/try/catch/switch block. Functions must be defined unconditionally at top level."
    'NESTED_FUNCTION_DEFINITION'        = "A function is defined inside another function's body. Helper logic should be a separate top-level function with its own prefix."

    # ---- Parameters (Section 17.4) ----
    'MISSING_PARAMETER_DOC'             = "A function parameter lacks a corresponding .PARAMETER tag in the docblock. Every parameter must be documented."
    'EXTRA_PARAMETER_DOC'               = "The docblock contains a .PARAMETER tag for a parameter the function does not define."

    # ---- Constants and variables (Section 17.5) ----
    'WRONG_DECLARATION_SECTION'         = "An assignment statement appears in a section type that disallows it (e.g., a constant in a VARIABLES section)."
    'MISSING_PURPOSE_COMMENT'           = "A constant or variable declaration is not preceded by a single-line purpose comment."

    # ---- Pode infrastructure (Section 17.6) ----
    'ROUTE_OUTSIDE_ROUTE_SECTION'       = "An Add-PodeRoute call appears outside a ROUTE section."
    'MIDDLEWARE_OUTSIDE_INIT_SECTION'   = "An Add-PodeMiddleware call appears outside an INITIALIZATION section."

    # ---- Forbidden patterns (Section 17.7) ----
    'FORBIDDEN_WRITE_HOST'              = "A Write-Host call appears in the file. Use Write-Log or the appropriate orchestrator output function instead."
    'FORBIDDEN_INLINE_DIVIDER'          = "A line of '=' or '-' characters appears as a comment to visually separate code (e.g., '# ----'). Section banners are the only permitted divider form."
    'FORBIDDEN_REMOVED_CODE_COMMENT'    = "A comment indicates removed or deleted code (e.g., '# Removed:', '# Was:', '# Deleted:'). Removed code should be deleted entirely; the git history preserves it if needed."
    'FORBIDDEN_LINKED_SERVER'           = "A query references a linked server (four-part name). PowerShell collectors must hit each instance directly with separate Invoke-Sqlcmd calls."
    'MISSING_TRUSTSERVERCERTIFICATE'    = "An Invoke-Sqlcmd call is missing the -TrustServerCertificate parameter. All AG-listener and instance connections in this environment require it."
    'MISSING_APPLICATIONNAME'           = "An Invoke-Sqlcmd call is missing the -ApplicationName parameter. Collectors must identify themselves in DMV attribution."

    # ---- Comment structure (Section 17.8) ----
    'FORBIDDEN_COMMENT_STYLE'           = "A free-standing block comment exists that does not match any of the allowed kinds (file header, section banner, docblock, sub-section marker)."
    'EXCESS_BLANK_LINES'                = "More than one blank line appears between top-level constructs."
}


# ============================================================================
# VARIABLES: SCRIPT-SCOPE STATE
# ============================================================================

# Row collection and dedupe tracker. The helpers reference these directly
# via Test-AddDedupeKey and Add-DriftCode.
$script:rows       = New-Object System.Collections.Generic.List[object]
$script:dedupeKeys = New-Object 'System.Collections.Generic.HashSet[string]'

# Per-file PS_FILE row references. Pass 3 / post-walk code uses this map to
# attach file-overall drift codes (EXCESS_BLANK_LINES, FORBIDDEN_COMMENT_STYLE)
# to each file's PS_FILE anchor row. The PS_FILE row is the universal "this
# file was scanned" anchor, parallel to CSS_FILE, JS_FILE, HTML_FILE.
$script:psFileRowByFile = @{}

# Shared definition maps populated by Pass 1. Each cataloged function in a
# shared-library or shared-module file is added here; PS_FUNCTION_CALL USAGE
# rows in any consumer file resolve scope=SHARED with source_file = the
# defining shared file.
$script:sharedFunctions  = New-Object 'System.Collections.Generic.HashSet[string]'
$script:sharedSourceFile = @{}

# Per-file context populated by the per-file walk loop. Each emitter reads
# from these to apply file-scoped attribution to the rows it creates.
$script:CurrentFile               = $null    # filename only (no path)
$script:CurrentFileFullPath       = $null    # absolute path for diagnostics
$script:CurrentFileRole           = $null    # 'page-route', 'api-route', 'module', 'standalone', 'shared-library'
$script:CurrentFileIsShared       = $false   # shorthand for shared-library OR module file
$script:CurrentFileSource         = $null    # raw text of the file
$script:CurrentAst                = $null    # ScriptBlockAst returned by the parser
$script:CurrentTokens             = $null    # token array from Parser::ParseFile
$script:CurrentParseErrors        = $null    # array of ParseErrors (non-fatal; partial AST is still usable)
$script:CurrentFileLineCount      = 0
$script:CurrentSections           = $null    # output of New-SectionList
$script:CurrentNormalizedComments = $null    # PS comment tokens converted to normalized shape
$script:CurrentCommentIndex       = $null    # for preceding-comment lookup (docblocks, purpose comments)
$script:CurrentLocalFunctions     = $null    # HashSet of function names defined in this file
$script:CurrentRegistryPrefix     = $null    # cc_prefix from Component_Registry for this file (or $null)
$script:CurrentRegistryHasMapping = $false   # whether the file has any Object_Registry/Component_Registry entry
$script:CurrentValidSectionTypes  = $null    # role-specific valid section types
$script:CurrentRequiresComponent  = $false   # whether the role requires .COMPONENT in the header


# ============================================================================
# FUNCTIONS: FILE ROLE DETECTION
# ============================================================================

# Classify a .ps1 or .psm1 file into one of five roles. Path-based:
#   *.psm1 anywhere                                          -> 'module'
#   *.psd1 anywhere                                          -> 'data-file' (basic inventory only)
#   ...\scripts\routes\<Name>\<Name>-API.ps1                 -> 'api-route'
#   ...\scripts\routes\<Name>\<Name>.ps1                     -> 'page-route'
#   ...\xFACts-PowerShell\xFACts-<Name>.ps1                  -> 'shared-library' (if in $SharedLibraryFiles)
#   any .ps1 in $StandalonePathExceptions                    -> 'standalone' (e.g. Start-ControlCenter.ps1)
#   any other .ps1 under xFACts-PowerShell\                  -> 'standalone'
# Returns the role string. Throws if the path doesn't match any known shape;
# the caller decides whether to skip or error.
function Get-PSFileRole {
    param([Parameter(Mandatory)][string]$FullPath)

    $fileName = [System.IO.Path]::GetFileName($FullPath)

    # Modules: extension wins regardless of location
    if ($fileName -match '\.psm1$') { return 'module' }

    # Data files (.psd1): module manifests and Pode server config. These
    # are cataloged as a basic file inventory only (PS_FILE row, no AST
    # walk). They're a restricted subset of PowerShell syntax and don't
    # have functions, parameters, routes, or any of the other catalogable
    # constructs Pass 2 looks for.
    if ($fileName -match '\.psd1$') { return 'data-file' }

    # Shared libraries: explicit list lookup
    if ($SharedLibraryFiles -contains $fileName) { return 'shared-library' }

    # Standalone path exceptions (files in a routes-style directory that
    # aren't actually routes)
    if ($StandalonePathExceptions -contains $fileName) { return 'standalone' }

    # API routes: filename ends in -API.ps1
    if ($fileName -match '-API\.ps1$') { return 'api-route' }

    # Page routes: file lives directly under \scripts\routes\ as a flat
    # .ps1 file (not in a per-page subfolder). The -API.ps1 form was already
    # caught above; any remaining .ps1 directly under routes\ is a page-route.
    if ($FullPath -match '\\scripts\\routes\\[^\\]+\.ps1$') { return 'page-route' }

    # Standalone: any other .ps1 under xFACts-PowerShell\
    return 'standalone'
}


# ============================================================================
# FUNCTIONS: PS PARSER AND COMMENT NORMALIZATION
# ============================================================================

# Parse a PowerShell file using the native AST parser. Returns a hashtable
# with the AST, the token stream, any parse errors (non-fatal), and the raw
# source text. The PS parser is resilient -- it returns a usable AST even
# when there are parse errors, and we proceed with what we get.
function Invoke-PSParse {
    param([Parameter(Mandatory)][string]$FilePath)

    try {
        $source = Get-Content -Path $FilePath -Raw -Encoding UTF8
        if ($null -eq $source) { $source = '' }

        $tokens = $null
        $parseErrors = $null

        # ParseFile returns the root ScriptBlockAst; tokens and errors are
        # populated by reference. This is the PS-native parsing entry point.
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $FilePath, [ref]$tokens, [ref]$parseErrors
        )

        if ($parseErrors -and $parseErrors.Count -gt 0) {
            $firstError = $parseErrors[0]
            $line = if ($firstError.Extent) { $firstError.Extent.StartLineNumber } else { '?' }
            Write-Log "PS parser reported $($parseErrors.Count) error(s) in ${FilePath} (first at line ${line}: $($firstError.Message)). Continuing with partial AST." 'WARN'
        }

        return @{
            Ast         = $ast
            Tokens      = $tokens
            ParseErrors = $parseErrors
            Source      = $source
        }
    }
    catch {
        Write-Log "Exception during parse of ${FilePath}: $($_.Exception.Message)" 'ERROR'
        return $null
    }
}

# Convert the PowerShell token stream's Comment tokens into the normalized
# shape that the helpers' Test-IsBannerComment and New-SectionList expect:
#   .Type      - 'Block' for <# #> comments and comment-based-help blocks
#                'Line'  for # single-line comments
#   .Text      - inner text with delimiters stripped
#   .LineStart - 1-based start line from .Extent
#   .LineEnd   - 1-based end line from .Extent
#   .ColumnStart - 1-based start column
# Returns a list sorted by LineStart ascending.
function Convert-PSCommentsToNormalized {
    param([Parameter(Mandatory)]$Tokens)

    $list = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Tokens) { return $list }

    foreach ($tok in $Tokens) {
        if ($tok.Kind -ne 'Comment') { continue }

        $text = $tok.Text
        $isBlock = $false
        $innerText = $text

        # Distinguish block comments from line comments by delimiter.
        # PowerShell block: <# ... #>  (may span multiple lines)
        # Line comment:     # ...      (single line)
        if ($text -match '^\s*<#') {
            $isBlock = $true
            $innerText = $text -replace '^\s*<#\s*', ''
            $innerText = $innerText -replace '\s*#>\s*$', ''
        }
        elseif ($text -match '^\s*#') {
            $innerText = $text -replace '^\s*#\s?', ''
        }

        $startLine = if ($tok.Extent) { [int]$tok.Extent.StartLineNumber } else { 1 }
        $endLine   = if ($tok.Extent) { [int]$tok.Extent.EndLineNumber } else { $startLine }
        $startCol  = if ($tok.Extent) { [int]$tok.Extent.StartColumnNumber } else { 1 }

        $list.Add([pscustomobject]@{
            Type         = if ($isBlock) { 'Block' } else { 'Line' }
            Text         = $innerText
            LineStart    = $startLine
            LineEnd      = $endLine
            ColumnStart  = $startCol
            OriginalToken = $tok
        })
    }

    # Sort by line so downstream consumers can binary-search if needed.
    return @($list | Sort-Object LineStart)
}


# ============================================================================
# FUNCTIONS: FORMAT HELPERS
# ============================================================================

# Collapse multi-line text to a single line. Used to normalize raw_text and
# signature values where line breaks would interfere with display.
function Format-SingleLine {
    param([string]$Text)
    if ($null -eq $Text) { return $null }
    $crlf = "`r`n"; $lf = "`n"; $cr = "`r"
    return ($Text -replace $crlf, ' ' -replace $lf, ' ' -replace $cr, ' ').Trim()
}

# Build a parameter-list signature string from a FunctionDefinitionAst's
# parameters. Returns "(p1, [string]$p2, [int]$p3 = 0)" form (without the
# leading function name; the caller prepends).
function Format-ParameterList {
    param([Parameter(Mandatory)]$FunctionAst)

    $params = @()

    # Parameters can live in two places: the function's [CmdletBinding()]
    # param() block (preferred), or function MyFunc($a, $b) parameter list.
    $paramAsts = $null
    if ($FunctionAst.Body -and $FunctionAst.Body.ParamBlock -and $FunctionAst.Body.ParamBlock.Parameters) {
        $paramAsts = $FunctionAst.Body.ParamBlock.Parameters
    }
    elseif ($FunctionAst.Parameters) {
        $paramAsts = $FunctionAst.Parameters
    }

    if ($null -eq $paramAsts) { return '()' }

    foreach ($p in $paramAsts) {
        $name = $p.Name.VariablePath.UserPath
        $typeText = ''
        if ($p.StaticType -and $p.StaticType.FullName -ne 'System.Object') {
            $typeText = "[$($p.StaticType.Name)]"
        }
        $defaultText = ''
        if ($p.DefaultValue) {
            $defaultText = " = $($p.DefaultValue.Extent.Text)"
        }
        $params += "$typeText`$$name$defaultText"
    }

    return "($($params -join ', '))"
}

# Determine whether a FunctionDefinitionAst has a [CmdletBinding()] attribute.
# Required by spec on all functions. Returns $true if present.
function Test-HasCmdletBinding {
    param([Parameter(Mandatory)]$FunctionAst)

    if ($null -eq $FunctionAst.Body -or $null -eq $FunctionAst.Body.ParamBlock) {
        return $false
    }

    $attrs = $FunctionAst.Body.ParamBlock.Attributes
    if ($null -eq $attrs) { return $false }

    foreach ($attr in $attrs) {
        $typeName = if ($attr.TypeName) { $attr.TypeName.Name } else { '' }
        if ($typeName -eq 'CmdletBinding') { return $true }
    }
    return $false
}


# ============================================================================
# FUNCTIONS: SQL / GLOBALCONFIG / RBAC DETECTION
# ============================================================================

# Cheap pre-check: does this text look like a SQL query? Conservative pattern
# matching on common SQL keywords at common positions. False positives are
# acceptable on first run (per the permissive-first decision); the catalog
# will reveal noise patterns to tighten later.
function Test-LooksLikeSQL {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    if ($Text.Length -lt 10) { return $false }

    # Strip leading whitespace and the first few lines of pure comment/blank
    # so a query introduced by a few lines of context still matches.
    $sample = $Text.Trim()

    # Check the first ~500 chars (most queries start in that window).
    $checkText = if ($sample.Length -gt 500) { $sample.Substring(0, 500) } else { $sample }

    # Match common starting tokens. \b boundaries to avoid false hits on
    # things like 'SELECTABLE' (not real but illustrative).
    $patterns = @(
        '(?im)^\s*SELECT\b',
        '(?im)^\s*WITH\b.*\bAS\b',
        '(?im)^\s*INSERT\s+INTO\b',
        '(?im)^\s*UPDATE\b.*\bSET\b',
        '(?im)^\s*DELETE\s+FROM\b',
        '(?im)^\s*MERGE\b.*\bUSING\b',
        '(?im)^\s*EXEC(?:UTE)?\b',
        '(?im)^\s*TRUNCATE\s+TABLE\b',
        '(?im)^\s*CREATE\s+(?:TABLE|INDEX|VIEW|PROCEDURE|FUNCTION)\b',
        '(?im)^\s*ALTER\s+(?:TABLE|INDEX|VIEW|PROCEDURE|FUNCTION)\b',
        '(?im)^\s*DROP\s+(?:TABLE|INDEX|VIEW|PROCEDURE|FUNCTION)\b'
    )

    foreach ($pattern in $patterns) {
        if ($checkText -match $pattern) { return $true }
    }

    # Permissive fallback: any text containing both SELECT and FROM in close
    # proximity is highly likely SQL even if it doesn't start that way.
    if ($checkText -match '(?im)\bSELECT\b[\s\S]{0,200}?\bFROM\b') { return $true }

    return $false
}

# Find references to GlobalConfig setting names in a text block. Returns an
# array of @{ SettingName; LineOffset; ColumnStart } occurrences. Two
# detection patterns:
#   1. SQL string with setting_name = 'xxx' (the SQL WHERE clause form)
#   2. Hardcoded string literals matching known GlobalConfig setting names
#      (broadcasted via the permissive approach; will produce noise on first
#      run)
function Get-GlobalConfigReferences {
    param([string]$Text)

    $results = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrWhiteSpace($Text)) { return @($results.ToArray()) }

    # Pattern 1: setting_name = 'xxx' (case-insensitive, allows whitespace)
    $pattern = "setting_name\s*=\s*['""]([^'""]+)['""]"
    $matchList = [regex]::Matches($Text, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    foreach ($m in $matchList) {
        $charIndex   = $m.Index
        $textBefore  = $Text.Substring(0, $charIndex)
        $lineOffset  = ($textBefore -split "`n").Count - 1
        $lastNewline = $textBefore.LastIndexOf("`n")
        $columnStart = if ($lastNewline -ge 0) { $charIndex - $lastNewline } else { $charIndex + 1 }

        $results.Add([ordered]@{
            SettingName = $m.Groups[1].Value
            LineOffset  = $lineOffset
            ColumnStart = $columnStart
            MatchKind   = 'sql-where'
        })
    }

    return @($results.ToArray())
}


# ============================================================================
# FUNCTIONS: VARIANT SHAPE HELPERS
# ============================================================================

# PS_FUNCTION (base, regular function) vs PS_FUNCTION_VARIANT (filter).
# PowerShell distinguishes filter functions structurally: filter funcs
# have FunctionDefinitionAst.IsFilter = $true. The spec catalogs filter
# as a variant of the base function type.
function Get-PSFunctionVariantShape {
    param([Parameter(Mandatory)]$FunctionAst)
    if ($FunctionAst.IsFilter -eq $true) {
        return @{ ComponentType = 'PS_FUNCTION_VARIANT'; VariantType = 'filter' }
    }
    return @{ ComponentType = 'PS_FUNCTION'; VariantType = $null }
}

# Extract the list of exported names from the AST node following a
# -Function / -Cmdlet / -Alias / -Variable parameter on Export-ModuleMember.
# Handles every shape PowerShell will hand back from that position:
#
#   StringConstantExpressionAst      single name, returns [single]
#   ExpandableStringExpressionAst    single name in double quotes, returns [single]
#   ArrayLiteralAst                  comma-separated names, returns each element
#   ParenExpressionAst               unwrap and recurse
#   ArrayExpressionAst               the @(...) form -- unwrap SubExpression and recurse
#   StatementBlockAst                unwrap and recurse into statements
#   PipelineAst                      unwrap into the pipeline's first PipelineElement
#
# Returns an array of strings. Skips any element whose text doesn't reduce
# cleanly to a name (e.g. a function-call expression inside the array);
# those would be invalid exports anyway.
#
# Motivation: the @() form with multi-line interspersed comments is common
# in real codebases. PowerShell parses @('Foo', 'Bar') as
# ArrayExpressionAst > StatementBlockAst > PipelineAst > ArrayLiteralAst >
# [StringConstantExpressionAst]. The naive "is ArrayLiteralAst?" check
# misses this and emits a single PS_EXPORT row whose ComponentName is the
# entire @(...) block's text -- 1000+ characters.
function Get-ExportedNamesFromAst {
    param([Parameter(Mandatory)]$Node)

    $names = New-Object System.Collections.Generic.List[string]

    if ($null -eq $Node) { return @() }

    # Direct string literal: terminal case
    if ($Node -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
        $Node -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
        $val = $Node.Value
        if ([string]::IsNullOrWhiteSpace($val)) {
            # Fall back to extent text minus quotes if .Value didn't help
            $val = $Node.Extent.Text.Trim("'`"")
        }
        if (-not [string]::IsNullOrWhiteSpace($val)) { [void]$names.Add($val) }
        return @($names.ToArray())
    }

    # Array literal: iterate elements
    if ($Node -is [System.Management.Automation.Language.ArrayLiteralAst]) {
        foreach ($elt in $Node.Elements) {
            foreach ($n in (Get-ExportedNamesFromAst -Node $elt)) {
                [void]$names.Add($n)
            }
        }
        return @($names.ToArray())
    }

    # Parenthesized expression: unwrap
    if ($Node -is [System.Management.Automation.Language.ParenExpressionAst]) {
        return Get-ExportedNamesFromAst -Node $Node.Pipeline
    }

    # @(...) form: unwrap SubExpression and recurse into the statement block
    if ($Node -is [System.Management.Automation.Language.ArrayExpressionAst]) {
        return Get-ExportedNamesFromAst -Node $Node.SubExpression
    }

    # Statement block: walk its statements
    if ($Node -is [System.Management.Automation.Language.StatementBlockAst]) {
        foreach ($stmt in $Node.Statements) {
            foreach ($n in (Get-ExportedNamesFromAst -Node $stmt)) {
                [void]$names.Add($n)
            }
        }
        return @($names.ToArray())
    }

    # Pipeline: walk the first pipeline element (the only one in this context)
    if ($Node -is [System.Management.Automation.Language.PipelineAst]) {
        foreach ($pe in $Node.PipelineElements) {
            foreach ($n in (Get-ExportedNamesFromAst -Node $pe)) {
                [void]$names.Add($n)
            }
        }
        return @($names.ToArray())
    }

    # Command expression wrapping an expression (e.g. when a single value
    # sits inside an @() block, it's parsed as a CommandExpressionAst)
    if ($Node -is [System.Management.Automation.Language.CommandExpressionAst]) {
        return Get-ExportedNamesFromAst -Node $Node.Expression
    }

    # Unrecognized shape -- the caller will handle this as "no names extracted"
    return @($names.ToArray())
}


# ============================================================================
# FUNCTIONS: LOCAL DEFINITION COLLECTION
# ============================================================================

# Walk the top-level statements of a parsed AST and collect the names of
# every top-level function defined. Used for:
#   - Same-file USAGE resolution (PS_FUNCTION_CALL pointing at local funcs)
#   - SHADOWS_SHARED_FUNCTION cross-file check
function Get-LocalPSFunctions {
    param([Parameter(Mandatory)]$Ast)

    $funcs = New-Object 'System.Collections.Generic.HashSet[string]'

    # Find top-level FunctionDefinitionAst nodes only -- nested functions
    # don't count for cataloging purposes.
    $topLevelFns = Find-PSAstNodes -Ast $Ast `
        -AstType ([System.Management.Automation.Language.FunctionDefinitionAst]) `
        -TopLevelOnly
    foreach ($fn in $topLevelFns) {
        if ($fn.Name) { [void]$funcs.Add($fn.Name) }
    }

    return $funcs
}


# ============================================================================
# FUNCTIONS: COMMENT INDEX (PRECEDING-COMMENT LOOKUP)
# ============================================================================

# Build a per-file index of block comments for fast preceding-comment lookup.
# Used by docblock detection (every function should have a comment-based-help
# block immediately above it) and purpose-comment detection (constants and
# variables should have a single-line purpose comment above).
function New-PSCommentIndex {
    param([Parameter(Mandatory)]$NormalizedComments)
    $idx = New-Object System.Collections.Generic.List[object]
    foreach ($c in $NormalizedComments) {
        if ($null -eq $c.LineStart -or $c.LineStart -le 0) { continue }
        $idx.Add([ordered]@{
            Type      = $c.Type
            StartLine = [int]$c.LineStart
            EndLine   = [int]$c.LineEnd
            Text      = $c.Text
            Used      = $false
        })
    }
    return $idx
}

# Find the block comment immediately preceding a definition. "Immediately
# preceding" means the comment ends on the line directly above the
# definition (allowing a single blank-line gap), and the comment has not
# been claimed by a closer-following definition. Returns the matched index
# entry (with .Text and .StartLine) or $null.
function Get-PrecedingPSBlockComment {
    param(
        [Parameter(Mandatory)]$CommentIndex,
        [Parameter(Mandatory)][int]$DefinitionLine
    )
    if ($null -eq $CommentIndex -or $CommentIndex.Count -eq 0) { return $null }

    $best = $null
    foreach ($c in $CommentIndex) {
        if ($c.Used) { continue }
        if ($c.Type -ne 'Block') { continue }
        $gap = $DefinitionLine - $c.EndLine
        if ($gap -ge 1 -and $gap -le 2) {
            if ($null -eq $best -or $c.EndLine -gt $best.EndLine) {
                $best = $c
            }
        }
    }
    if ($best) {
        $best.Used = $true
        return $best
    }
    return $null
}

# Like Get-PrecedingPSBlockComment but for single-line comments (for
# purpose-comment detection on constants/variables).
function Get-PrecedingPSLineComment {
    param(
        [Parameter(Mandatory)]$CommentIndex,
        [Parameter(Mandatory)][int]$DefinitionLine
    )
    if ($null -eq $CommentIndex -or $CommentIndex.Count -eq 0) { return $null }

    $best = $null
    foreach ($c in $CommentIndex) {
        if ($c.Used) { continue }
        if ($c.Type -ne 'Line') { continue }
        $gap = $DefinitionLine - $c.EndLine
        if ($gap -eq 1) {
            if ($null -eq $best -or $c.EndLine -gt $best.EndLine) {
                $best = $c
            }
        }
    }
    if ($best) {
        $best.Used = $true
        return $best
    }
    return $null
}



# ============================================================================
# FUNCTIONS: ROW EMITTERS
# ============================================================================

# Wrap New-AssetRegistryRow with the per-file context every PS row carries.
# Returns the row but does not add it to $script:rows (callers add through
# the type-specific emitters below, which handle dedupe and section context).
function New-PSRow {
    param(
        [int]$LineStart = 1,
        [int]$LineEnd = 0,
        [int]$ColumnStart = 0,
        [string]$ComponentType,
        [string]$ComponentName,
        [string]$VariantType,
        [string]$VariantQualifier1,
        [string]$VariantQualifier2,
        [string]$ReferenceType = 'DEFINITION',
        [string]$Scope,
        [string]$SourceFile,
        [string]$SourceSection,
        [string]$Signature,
        [string]$ParentFunction,
        [string]$RawText,
        [string]$PurposeDescription,
        [switch]$SuppressSectionLookup
    )

    if (-not $SourceFile) { $SourceFile = $script:CurrentFile }
    if (-not $SourceSection -and -not $SuppressSectionLookup) {
        $sec = Get-SectionForLine -Sections $script:CurrentSections -Line $LineStart
        if ($sec) { $SourceSection = $sec.FullTitle }
    }

    return New-AssetRegistryRow `
        -FileName           $script:CurrentFile `
        -FileType           'PS' `
        -LineStart          $LineStart `
        -LineEnd            $LineEnd `
        -ColumnStart        $ColumnStart `
        -ComponentType      $ComponentType `
        -ComponentName      $ComponentName `
        -VariantType        $VariantType `
        -VariantQualifier1  $VariantQualifier1 `
        -VariantQualifier2  $VariantQualifier2 `
        -ReferenceType      $ReferenceType `
        -Scope              $Scope `
        -SourceFile         $SourceFile `
        -SourceSection      $SourceSection `
        -Signature          $Signature `
        -ParentFunction     $ParentFunction `
        -RawText            $RawText `
        -PurposeDescription $PurposeDescription
}

# Emit the PS_FILE anchor row for the current file. Universal "this file
# was scanned" anchor; carries no raw_text, no purpose_description, no
# signature. Pass 3 attaches file-overall drift codes here.
function Add-PSFileRow {
    param([int]$LineEnd)

    $key = "$($script:CurrentFile)|1|PS_FILE|$($script:CurrentFile)|DEFINITION|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }
    $row = New-PSRow `
        -ComponentType 'PS_FILE' `
        -ComponentName $script:CurrentFile `
        -LineStart     1 `
        -LineEnd       $LineEnd `
        -ColumnStart   1 `
        -ReferenceType 'DEFINITION' `
        -Scope         $scope `
        -SuppressSectionLookup
    $script:rows.Add($row)
    $script:psFileRowByFile[$script:CurrentFile] = $row
    return $row
}

# Emit a FILE_HEADER row for the <# .SYNOPSIS ... #> block at line 1.
# All header drift codes from Get-PSFileHeaderInfo carry over by the caller.
function Add-PSFileHeaderRow {
    param(
        [int]$LineStart, [int]$LineEnd,
        [string]$RawText, [string]$PurposeDescription
    )
    $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }
    $row = New-PSRow `
        -ComponentType      'FILE_HEADER' `
        -ComponentName      $script:CurrentFile `
        -LineStart          $LineStart `
        -LineEnd            $LineEnd `
        -ReferenceType      'DEFINITION' `
        -Scope              $scope `
        -RawText            $RawText `
        -PurposeDescription $PurposeDescription `
        -SuppressSectionLookup
    $script:rows.Add($row)
    return $row
}

# Emit a COMMENT_BANNER row from a Section entry produced by New-SectionList.
# Per-banner drift codes (from Get-BannerInfo) are carried over here.
# SECTION_TYPE_ORDER_VIOLATION, MALFORMED_PREFIX_VALUE,
# PREFIX_REGISTRY_MISMATCH, DUPLICATE_BANNER_NAME are added based on
# cross-section / cross-registry information.
function Add-PSCommentBannerRow {
    param(
        $Section,
        [int]$PreviousSectionTypeOrderIdx = -1,
        $SeenBannerNames = $null
    )

    if ($null -eq $Section) { return $null }

    $b = $Section.BannerComment
    $rawSnippet = Format-SingleLine -Text $b.Text

    $key = "$($script:CurrentFile)|$($Section.BannerStartLine)|COMMENT_BANNER|$($Section.FullTitle)|DEFINITION|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $componentName = if ($Section.BannerName) { $Section.BannerName } else { $Section.FullTitle }
    $scope         = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }

    $row = New-PSRow `
        -ComponentType      'COMMENT_BANNER' `
        -ComponentName      $componentName `
        -LineStart          $Section.BannerStartLine `
        -LineEnd            $Section.BannerEndLine `
        -ColumnStart        $b.ColumnStart `
        -ReferenceType      'DEFINITION' `
        -Scope              $scope `
        -Signature          $Section.TypeName `
        -RawText            $rawSnippet `
        -PurposeDescription $Section.Description `
        -SuppressSectionLookup
    $script:rows.Add($row)

    foreach ($code in $Section.BannerDriftCodes) {
        Add-DriftCode -Row $row -Code $code
    }

    if ($Section.TypeName -and $script:SectionTypeOrder.ContainsKey($Section.TypeName)) {
        $newIdx = [int]$script:SectionTypeOrder[$Section.TypeName]
        if ($PreviousSectionTypeOrderIdx -ge 0 -and $newIdx -lt $PreviousSectionTypeOrderIdx) {
            Add-DriftCode -Row $row -Code 'SECTION_TYPE_ORDER_VIOLATION'
        }
    }

    if ($SeenBannerNames -and $SeenBannerNames.Contains($Section.FullTitle)) {
        Add-DriftCode -Row $row -Code 'DUPLICATE_BANNER_NAME' `
            -Context "Banner '$($Section.FullTitle)' appears more than once in this file."
    }

    if ($Section.Prefix -and -not (Test-PrefixValueIsValid -Prefix $Section.Prefix)) {
        Add-DriftCode -Row $row -Code 'MALFORMED_PREFIX_VALUE' `
            -Context "Banner declares Prefix '$($Section.Prefix)' which is neither a 3-char lowercase prefix nor (none)."
    }

    # PREFIX_REGISTRY_MISMATCH: registry-driven validation
    if ($script:CurrentRegistryHasMapping -and $Section.Prefix -and (Test-PrefixValueIsValid -Prefix $Section.Prefix)) {
        $bannerVal = Get-BannerPrefixValue -Prefix $Section.Prefix
        $isNone    = Test-IsPrefixNone -Prefix $Section.Prefix
        $regVal    = $script:CurrentRegistryPrefix

        $mismatch = $false
        if ($null -eq $regVal) {
            if (-not $isNone) { $mismatch = $true }
        } else {
            if ($isNone -or $bannerVal -ne $regVal) { $mismatch = $true }
        }

        if ($mismatch) {
            $regDisplay    = if ($null -eq $regVal) { '(none)' } else { $regVal }
            $bannerDisplay = if ($isNone) { '(none)' } else { $bannerVal }
            Add-DriftCode -Row $row -Code 'PREFIX_REGISTRY_MISMATCH' `
                -Context "Banner declares Prefix '$bannerDisplay' but Component_Registry says cc_prefix = '$regDisplay' for this file."
        }
    }

    return $row
}

# Emit a single PS_CHANGELOG row representing the entire CHANGELOG section
# of a file. Per-entry granularity was considered and rejected -- one row
# per file is sufficient. The full section text goes into raw_text.
function Add-PSChangelogRow {
    param([Parameter(Mandatory)]$Section)

    $key = "$($script:CurrentFile)|$($Section.BodyStartLine)|PS_CHANGELOG|$($script:CurrentFile)|DEFINITION|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }

    $changelogText = $null
    if ($script:CurrentFileSource) {
        $sourceLines = $script:CurrentFileSource -split "`r?`n"
        $startIdx = [Math]::Max(0, $Section.BodyStartLine - 1)
        $endIdx   = [Math]::Min($sourceLines.Count - 1, $Section.BodyEndLine - 1)
        if ($endIdx -ge $startIdx) {
            $changelogText = ($sourceLines[$startIdx..$endIdx] -join "`n")
        }
    }

    $row = New-PSRow `
        -ComponentType      'PS_CHANGELOG' `
        -ComponentName      $script:CurrentFile `
        -LineStart          $Section.BodyStartLine `
        -LineEnd            $Section.BodyEndLine `
        -ColumnStart        1 `
        -ReferenceType      'DEFINITION' `
        -Scope              $scope `
        -Signature          $Section.FullTitle `
        -RawText            (Format-SingleLine -Text $changelogText) `
        -PurposeDescription (ConvertTo-CleanCommentText -CommentText $changelogText) `
        -SuppressSectionLookup
    $script:rows.Add($row)
    return $row
}

# Emit a PS_FUNCTION or PS_FUNCTION_VARIANT row for a top-level function.
# Handles per-function attribution: docblock detection, CmdletBinding check,
# prefix validation, section context, conditional/nested definition checks.
function Add-PSFunctionRow {
    param([Parameter(Mandatory)]$FunctionAst)
    if ([string]::IsNullOrEmpty($FunctionAst.Name)) { return $null }

    $fnName = $FunctionAst.Name
    $line   = Get-PSAstNodeLine    -Node $FunctionAst
    $endLn  = Get-PSAstNodeEndLine -Node $FunctionAst
    $col    = Get-PSAstNodeColumn  -Node $FunctionAst

    $shape  = Get-PSFunctionVariantShape -FunctionAst $FunctionAst
    $params = Format-ParameterList       -FunctionAst $FunctionAst
    $sig    = "function $fnName $params"

    $section = Get-SectionForLine -Sections $script:CurrentSections -Line $line
    $sectionTitle = if ($section) { $section.FullTitle } else { $null }

    $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }
    $key = "$($script:CurrentFile)|$line|$col|$($shape.ComponentType)|$fnName|DEFINITION|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $docBlock     = Get-PrecedingPSBlockComment -CommentIndex $script:CurrentCommentIndex -DefinitionLine $line
    $docBlockText = if ($docBlock) { $docBlock.Text } else { $null }
    $purpose      = $null
    if ($docBlockText) {
        if ($docBlockText -match '(?ms)^\s*\.SYNOPSIS\s*\r?\n(.+?)(?=^\s*\.[A-Z]+|\z)') {
            $purpose = $matches[1].Trim()
        }
        elseif ($docBlockText -match '(?ms)^\s*\.DESCRIPTION\s*\r?\n(.+?)(?=^\s*\.[A-Z]+|\z)') {
            $purpose = ConvertTo-CleanCommentText -CommentText $matches[1]
        }
        else {
            $purpose = ConvertTo-CleanCommentText -CommentText $docBlockText
        }
    }

    $row = New-PSRow `
        -ComponentType      $shape.ComponentType `
        -ComponentName      $fnName `
        -VariantType        $shape.VariantType `
        -LineStart          $line `
        -LineEnd            $endLn `
        -ColumnStart        $col `
        -ReferenceType      'DEFINITION' `
        -Scope              $scope `
        -SourceFile         $script:CurrentFile `
        -SourceSection      $sectionTitle `
        -Signature          $sig `
        -RawText            $sig `
        -PurposeDescription $purpose `
        -SuppressSectionLookup
    $script:rows.Add($row)

    if ($null -eq $docBlockText) {
        Add-DriftCode -Row $row -Code 'MISSING_DOCBLOCK' `
            -Context "Function '$fnName' has no preceding comment-based-help block."
    }

    if (-not (Test-HasCmdletBinding -FunctionAst $FunctionAst)) {
        Add-DriftCode -Row $row -Code 'MISSING_CMDLETBINDING' `
            -Context "Function '$fnName' is missing the [CmdletBinding()] attribute."
    }

    if ($null -eq $section) {
        Add-DriftCode -Row $row -Code 'MISSING_SECTION_BANNER' `
            -Context "Function '$fnName' appears outside any section banner."
    }

    # PREFIX_MISMATCH against section banner prefix
    if ($section -and -not $section.IsPrefixNone) {
        $expectedPrefix = $section.PrefixValue
        if (-not [string]::IsNullOrEmpty($expectedPrefix)) {
            # Accept either Verb-prefix_Noun or prefix_Noun naming forms.
            $escaped = [regex]::Escape($expectedPrefix)
            $matched = ($fnName -match "^[A-Za-z]+-${escaped}[-_]") -or
                       ($fnName -match "^${escaped}[-_]")
            if (-not $matched) {
                Add-DriftCode -Row $row -Code 'PREFIX_MISMATCH' `
                    -Context "Function '$fnName' does not include section prefix '$expectedPrefix'."
            }
        }
    }

    # PREFIX_MISSING against Component_Registry cc_prefix
    if ($script:CurrentRegistryHasMapping -and -not [string]::IsNullOrEmpty($script:CurrentRegistryPrefix)) {
        $expected = $script:CurrentRegistryPrefix
        $escaped = [regex]::Escape($expected)
        $matched = ($fnName -match "^[A-Za-z]+-${escaped}[-_]") -or
                   ($fnName -match "^${escaped}[-_]")
        if (-not $matched) {
            Add-DriftCode -Row $row -Code 'PREFIX_MISSING' `
                -Context "Function '$fnName' does not include the file's registered prefix '$expected'."
        }
    }

    if (Test-IsConditionallyDefinedPSAst -Node $FunctionAst) {
        Add-DriftCode -Row $row -Code 'FORBIDDEN_CONDITIONAL_DEFINITION' `
            -Context "Function '$fnName' is declared inside a control-flow block."
    }

    # NESTED_FUNCTION_DEFINITION: walk parents for another FunctionDefinitionAst
    $cursor = $FunctionAst.Parent
    $isNested = $false
    while ($null -ne $cursor) {
        if ($cursor -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
            $isNested = $true
            break
        }
        $cursor = $cursor.Parent
    }
    if ($isNested) {
        Add-DriftCode -Row $row -Code 'NESTED_FUNCTION_DEFINITION' `
            -Context "Function '$fnName' is nested inside another function."
    }

    return $row
}

# Emit a PS_DOCBLOCK row representing the comment-based-help block above
# a function. ParentFunction holds the function name; raw_text holds the
# full docblock body.
function Add-PSDocblockRow {
    param(
        [Parameter(Mandatory)][string]$FunctionName,
        [Parameter(Mandatory)][string]$DocblockText,
        [Parameter(Mandatory)][int]$LineStart,
        [Parameter(Mandatory)][int]$LineEnd
    )
    if ([string]::IsNullOrWhiteSpace($DocblockText)) { return $null }

    $key = "$($script:CurrentFile)|$LineStart|PS_DOCBLOCK|$FunctionName|DEFINITION|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }

    $row = New-PSRow `
        -ComponentType      'PS_DOCBLOCK' `
        -ComponentName      $FunctionName `
        -LineStart          $LineStart `
        -LineEnd            $LineEnd `
        -ColumnStart        1 `
        -ReferenceType      'DEFINITION' `
        -Scope              $scope `
        -ParentFunction     $FunctionName `
        -RawText            (Format-SingleLine -Text $DocblockText) `
        -PurposeDescription (ConvertTo-CleanCommentText -CommentText $DocblockText)
    $script:rows.Add($row)
    return $row
}

# Emit a PS_PARAMETER row for one parameter of a function.
function Add-PSParameterRow {
    param(
        [Parameter(Mandatory)][string]$FunctionName,
        [Parameter(Mandatory)]$ParameterAst
    )

    $paramName = $ParameterAst.Name.VariablePath.UserPath
    if ([string]::IsNullOrEmpty($paramName)) { return $null }

    $line = Get-PSAstNodeLine    -Node $ParameterAst
    $col  = Get-PSAstNodeColumn  -Node $ParameterAst

    $key = "$($script:CurrentFile)|$line|$col|PS_PARAMETER|$FunctionName.$paramName|DEFINITION|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }

    $typeText = ''
    if ($ParameterAst.StaticType -and $ParameterAst.StaticType.FullName -ne 'System.Object') {
        $typeText = "[$($ParameterAst.StaticType.Name)] "
    }
    $defaultText = ''
    if ($ParameterAst.DefaultValue) {
        $defaultText = " = $($ParameterAst.DefaultValue.Extent.Text)"
    }
    $sig = "$typeText`$$paramName$defaultText"

    $row = New-PSRow `
        -ComponentType  'PS_PARAMETER' `
        -ComponentName  $paramName `
        -LineStart      $line `
        -LineEnd        $line `
        -ColumnStart    $col `
        -ReferenceType  'DEFINITION' `
        -Scope          $scope `
        -ParentFunction $FunctionName `
        -Signature      $sig `
        -RawText        $sig
    $script:rows.Add($row)
    return $row
}

# Emit a PS_CONSTANT or PS_VARIABLE row for a top-level assignment.
# Component type chosen from section context; outside CONSTANTS/VARIABLES
# sections, defaults to PS_VARIABLE with WRONG_DECLARATION_SECTION drift.
function Add-PSAssignmentRow {
    param([Parameter(Mandatory)]$AssignmentAst)

    $left = $AssignmentAst.Left
    if ($null -eq $left) { return $null }

    $varName = $null
    if ($left -is [System.Management.Automation.Language.VariableExpressionAst]) {
        $varName = $left.VariablePath.UserPath
    }
    elseif ($left.Extent) {
        $extentText = $left.Extent.Text
        if ($extentText -match '\$(\w+)$') { $varName = $matches[1] }
    }

    if ([string]::IsNullOrEmpty($varName)) { return $null }

    $line  = Get-PSAstNodeLine    -Node $AssignmentAst
    $endLn = Get-PSAstNodeEndLine -Node $AssignmentAst
    $col   = Get-PSAstNodeColumn  -Node $AssignmentAst

    $section = Get-SectionForLine -Sections $script:CurrentSections -Line $line
    $sectionType = if ($section) { $section.TypeName } else { $null }

    $componentType = 'PS_VARIABLE'
    if ($sectionType -eq 'CONSTANTS') { $componentType = 'PS_CONSTANT' }
    elseif ($sectionType -eq 'VARIABLES') { $componentType = 'PS_VARIABLE' }

    $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }
    $key = "$($script:CurrentFile)|$line|$col|$componentType|$varName|DEFINITION|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $sig = if ($AssignmentAst.Extent) { Format-SingleLine -Text $AssignmentAst.Extent.Text } else { "`$$varName = ..." }

    $purposeComment = Get-PrecedingPSLineComment -CommentIndex $script:CurrentCommentIndex -DefinitionLine $line
    $purpose = if ($purposeComment) { $purposeComment.Text.Trim() } else { $null }

    $row = New-PSRow `
        -ComponentType      $componentType `
        -ComponentName      $varName `
        -LineStart          $line `
        -LineEnd            $endLn `
        -ColumnStart        $col `
        -ReferenceType      'DEFINITION' `
        -Scope              $scope `
        -Signature          $sig `
        -RawText            $sig `
        -PurposeDescription $purpose
    $script:rows.Add($row)

    if ($null -eq $section) {
        Add-DriftCode -Row $row -Code 'MISSING_SECTION_BANNER' `
            -Context "Top-level assignment `$$varName appears outside any section banner."
    }
    elseif ($sectionType -ne 'CONSTANTS' -and $sectionType -ne 'VARIABLES') {
        Add-DriftCode -Row $row -Code 'WRONG_DECLARATION_SECTION' `
            -Context "Top-level assignment `$$varName appears in a $sectionType section; spec requires CONSTANTS or VARIABLES."
    }

    if ($null -eq $purposeComment) {
        Add-DriftCode -Row $row -Code 'MISSING_PURPOSE_COMMENT' `
            -Context "`$$varName has no preceding purpose comment."
    }

    return $row
}

# Emit a PS_ROUTE row for an Add-PodeRoute call. Variant qualifiers:
# q1 = HTTP method (GET/POST/etc), q2 = route path.
function Add-PSRouteRow {
    param(
        [Parameter(Mandatory)]$CommandAst,
        [string]$Method,
        [string]$Path
    )

    $line  = Get-PSAstNodeLine    -Node $CommandAst
    $endLn = Get-PSAstNodeEndLine -Node $CommandAst
    $col   = Get-PSAstNodeColumn  -Node $CommandAst

    $componentName = if ($Path) { $Path } else { '<unknown>' }
    $key = "$($script:CurrentFile)|$line|$col|PS_ROUTE|$componentName|DEFINITION|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }
    $sig = if ($CommandAst.Extent) { Format-SingleLine -Text $CommandAst.Extent.Text } else { 'Add-PodeRoute' }

    $section = Get-SectionForLine -Sections $script:CurrentSections -Line $line

    $row = New-PSRow `
        -ComponentType     'PS_ROUTE' `
        -ComponentName     $componentName `
        -VariantQualifier1 $Method `
        -VariantQualifier2 $Path `
        -LineStart         $line `
        -LineEnd           $endLn `
        -ColumnStart       $col `
        -ReferenceType     'DEFINITION' `
        -Scope             $scope `
        -Signature         $sig `
        -RawText           $sig
    $script:rows.Add($row)

    # ROUTE_OUTSIDE_ROUTE_SECTION: spec requires PS_ROUTE in a ROUTE section
    if ($section -and $section.TypeName -ne 'ROUTE') {
        Add-DriftCode -Row $row -Code 'ROUTE_OUTSIDE_ROUTE_SECTION' `
            -Context "Add-PodeRoute call appears in a $($section.TypeName) section; spec requires the ROUTE section."
    }

    return $row
}

# Emit a PS_MIDDLEWARE row for an Add-PodeMiddleware call.
function Add-PSMiddlewareRow {
    param([Parameter(Mandatory)]$CommandAst, [string]$MiddlewareName)

    $line  = Get-PSAstNodeLine    -Node $CommandAst
    $endLn = Get-PSAstNodeEndLine -Node $CommandAst
    $col   = Get-PSAstNodeColumn  -Node $CommandAst

    $componentName = if ($MiddlewareName) { $MiddlewareName } else { '<unnamed>' }
    $key = "$($script:CurrentFile)|$line|$col|PS_MIDDLEWARE|$componentName|DEFINITION|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }
    $sig = if ($CommandAst.Extent) { Format-SingleLine -Text $CommandAst.Extent.Text } else { 'Add-PodeMiddleware' }

    $section = Get-SectionForLine -Sections $script:CurrentSections -Line $line

    $row = New-PSRow `
        -ComponentType 'PS_MIDDLEWARE' `
        -ComponentName $componentName `
        -LineStart     $line `
        -LineEnd       $endLn `
        -ColumnStart   $col `
        -ReferenceType 'DEFINITION' `
        -Scope         $scope `
        -Signature     $sig `
        -RawText       $sig
    $script:rows.Add($row)

    if ($section -and $section.TypeName -ne 'INITIALIZATION') {
        Add-DriftCode -Row $row -Code 'MIDDLEWARE_OUTSIDE_INIT_SECTION' `
            -Context "Add-PodeMiddleware call appears in a $($section.TypeName) section; spec requires INITIALIZATION."
    }

    return $row
}

# Emit a PS_WEBSOCKET_ROUTE row for an Add-PodeRouteWebSocket call.
function Add-PSWebSocketRouteRow {
    param([Parameter(Mandatory)]$CommandAst, [string]$Path)

    $line  = Get-PSAstNodeLine    -Node $CommandAst
    $endLn = Get-PSAstNodeEndLine -Node $CommandAst
    $col   = Get-PSAstNodeColumn  -Node $CommandAst

    $componentName = if ($Path) { $Path } else { '<unknown>' }
    $key = "$($script:CurrentFile)|$line|$col|PS_WEBSOCKET_ROUTE|$componentName|DEFINITION|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }
    $sig = if ($CommandAst.Extent) { Format-SingleLine -Text $CommandAst.Extent.Text } else { 'Add-PodeRouteWebSocket' }

    $row = New-PSRow `
        -ComponentType     'PS_WEBSOCKET_ROUTE' `
        -ComponentName     $componentName `
        -VariantQualifier2 $Path `
        -LineStart         $line `
        -LineEnd           $endLn `
        -ColumnStart       $col `
        -ReferenceType     'DEFINITION' `
        -Scope             $scope `
        -Signature         $sig `
        -RawText           $sig
    $script:rows.Add($row)
    return $row
}

# Emit a PS_EXPORT row for an Export-ModuleMember call.
function Add-PSExportRow {
    param([Parameter(Mandatory)]$CommandAst, [string]$ExportedName, [string]$ExportKind = 'function')

    $line = Get-PSAstNodeLine    -Node $CommandAst
    $col  = Get-PSAstNodeColumn  -Node $CommandAst

    if ([string]::IsNullOrEmpty($ExportedName)) { return $null }

    $key = "$($script:CurrentFile)|$line|$col|PS_EXPORT|$ExportedName|DEFINITION|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }
    $sig = "Export-ModuleMember -${ExportKind} $ExportedName"

    $row = New-PSRow `
        -ComponentType   'PS_EXPORT' `
        -ComponentName   $ExportedName `
        -VariantType     $ExportKind `
        -LineStart       $line `
        -LineEnd         $line `
        -ColumnStart     $col `
        -ReferenceType   'DEFINITION' `
        -Scope           $scope `
        -Signature       $sig `
        -RawText         $sig
    $script:rows.Add($row)
    return $row
}

# Emit a PS_FUNCTION_CALL USAGE row for a call to a cataloged function.
# Resolves scope=SHARED if the function is in the shared-functions map;
# scope=LOCAL if it's in the current file's local functions. Returns
# $null for calls to functions outside the catalog (built-in cmdlets,
# external commands, etc.) -- those are not cataloged.
function Add-PSFunctionCallRow {
    param([Parameter(Mandatory)]$CommandAst)

    $fnName = $CommandAst.GetCommandName()
    if ([string]::IsNullOrEmpty($fnName)) { return $null }

    $scope = $null
    $sourceFile = $null

    if ($script:sharedFunctions.Contains($fnName)) {
        $scope = 'SHARED'
        $sourceFile = if ($script:sharedSourceFile.ContainsKey($fnName)) { $script:sharedSourceFile[$fnName] } else { '<shared>' }
    }
    elseif ($script:CurrentLocalFunctions -and $script:CurrentLocalFunctions.Contains($fnName)) {
        $scope = 'LOCAL'
        $sourceFile = $script:CurrentFile
    }
    else {
        return $null
    }

    $line = Get-PSAstNodeLine    -Node $CommandAst
    $col  = Get-PSAstNodeColumn  -Node $CommandAst

    $key = "$($script:CurrentFile)|$line|$col|PS_FUNCTION_CALL|$fnName|USAGE|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $sig = if ($CommandAst.Extent) { Format-SingleLine -Text $CommandAst.Extent.Text } else { "$fnName(...)" }

    # Determine the enclosing function (parent_function attribution)
    $parentFn = $null
    $cursor = $CommandAst.Parent
    while ($null -ne $cursor) {
        if ($cursor -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
            $parentFn = $cursor.Name
            break
        }
        $cursor = $cursor.Parent
    }

    $row = New-PSRow `
        -ComponentType  'PS_FUNCTION_CALL' `
        -ComponentName  $fnName `
        -LineStart      $line `
        -LineEnd        $line `
        -ColumnStart    $col `
        -ReferenceType  'USAGE' `
        -Scope          $scope `
        -SourceFile     $sourceFile `
        -ParentFunction $parentFn `
        -Signature      $sig `
        -RawText        $sig
    $script:rows.Add($row)
    return $row
}

# Emit a PS_WRITE_HOST row for a Write-Host call. Files in
# $WriteHostExemptFiles skip this entirely (caller checks before calling).
function Add-PSWriteHostRow {
    param([Parameter(Mandatory)]$CommandAst)

    $line = Get-PSAstNodeLine    -Node $CommandAst
    $col  = Get-PSAstNodeColumn  -Node $CommandAst

    $key = "$($script:CurrentFile)|$line|$col|PS_WRITE_HOST|<write-host>|USAGE|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }
    $sig = if ($CommandAst.Extent) { Format-SingleLine -Text $CommandAst.Extent.Text } else { 'Write-Host ...' }

    $parentFn = $null
    $cursor = $CommandAst.Parent
    while ($null -ne $cursor) {
        if ($cursor -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
            $parentFn = $cursor.Name
            break
        }
        $cursor = $cursor.Parent
    }

    $row = New-PSRow `
        -ComponentType  'PS_WRITE_HOST' `
        -ComponentName  '<write-host>' `
        -LineStart      $line `
        -LineEnd        $line `
        -ColumnStart    $col `
        -ReferenceType  'USAGE' `
        -Scope          $scope `
        -ParentFunction $parentFn `
        -Signature      $sig `
        -RawText        $sig
    $script:rows.Add($row)

    Add-DriftCode -Row $row -Code 'FORBIDDEN_WRITE_HOST' `
        -Context "Write-Host call at line $line in $($script:CurrentFile)."
    return $row
}

# Emit a PS_INLINE_BANNER row for a comment line that looks like a
# divider (e.g., '# ==========' or '# ----------'). These are forbidden
# as visual separators; section banners are the only permitted divider.
function Add-PSInlineBannerRow {
    param([int]$LineStart, [int]$ColumnStart, [string]$RawText)

    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|PS_INLINE_BANNER|<inline-banner>|DEFINITION|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }

    $row = New-PSRow `
        -ComponentType 'PS_INLINE_BANNER' `
        -ComponentName '<inline-banner>' `
        -LineStart     $LineStart `
        -LineEnd       $LineStart `
        -ColumnStart   $ColumnStart `
        -ReferenceType 'DEFINITION' `
        -Scope         $scope `
        -Signature     $RawText `
        -RawText       $RawText `
        -SuppressSectionLookup
    $script:rows.Add($row)
    Add-DriftCode -Row $row -Code 'FORBIDDEN_INLINE_DIVIDER' `
        -Context "Inline divider line at line $LineStart."
    return $row
}

# Emit a PS_REMOVED_CODE_COMMENT row for a comment indicating removed code.
function Add-PSRemovedCodeCommentRow {
    param([int]$LineStart, [int]$ColumnStart, [string]$RawText)

    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|PS_REMOVED_CODE_COMMENT|<removed-code>|DEFINITION|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }

    $row = New-PSRow `
        -ComponentType 'PS_REMOVED_CODE_COMMENT' `
        -ComponentName '<removed-code>' `
        -LineStart     $LineStart `
        -LineEnd       $LineStart `
        -ColumnStart   $ColumnStart `
        -ReferenceType 'DEFINITION' `
        -Scope         $scope `
        -Signature     (Format-SingleLine -Text $RawText) `
        -RawText       $RawText `
        -SuppressSectionLookup
    $script:rows.Add($row)
    Add-DriftCode -Row $row -Code 'FORBIDDEN_REMOVED_CODE_COMMENT' `
        -Context "Removed-code headstone comment at line $LineStart."
    return $row
}

# Emit a PS_COMMENT_BLOCK row for a free-standing block comment that
# isn't a header, banner, or docblock.
function Add-PSCommentBlockRow {
    param([int]$LineStart, [int]$LineEnd, [int]$ColumnStart, [string]$RawText)

    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|PS_COMMENT_BLOCK|<block-comment>|DEFINITION|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }

    $row = New-PSRow `
        -ComponentType      'PS_COMMENT_BLOCK' `
        -ComponentName      '<block-comment>' `
        -LineStart          $LineStart `
        -LineEnd            $LineEnd `
        -ColumnStart        $ColumnStart `
        -ReferenceType      'DEFINITION' `
        -Scope              $scope `
        -RawText            (Format-SingleLine -Text $RawText) `
        -PurposeDescription (ConvertTo-CleanCommentText -CommentText $RawText) `
        -SuppressSectionLookup
    $script:rows.Add($row)
    return $row
}

# Emit a MODULE_IMPORT row for a dot-source statement or Import-Module call.
function Add-PSModuleImportRow {
    param(
        [Parameter(Mandatory)]$ImportAst,
        [string]$ImportKind,
        [string]$ImportedPath
    )

    $line = Get-PSAstNodeLine    -Node $ImportAst
    $col  = Get-PSAstNodeColumn  -Node $ImportAst

    $componentName = if ($ImportedPath) { $ImportedPath } else { '<unknown>' }
    $key = "$($script:CurrentFile)|$line|$col|MODULE_IMPORT|$componentName|USAGE|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }
    $sig = if ($ImportAst.Extent) { Format-SingleLine -Text $ImportAst.Extent.Text } else { "$ImportKind $componentName" }

    $row = New-PSRow `
        -ComponentType     'MODULE_IMPORT' `
        -ComponentName     $componentName `
        -VariantType       $ImportKind `
        -VariantQualifier2 $ImportedPath `
        -LineStart         $line `
        -LineEnd           $line `
        -ColumnStart       $col `
        -ReferenceType     'USAGE' `
        -Scope             $scope `
        -Signature         $sig `
        -RawText           $sig
    $script:rows.Add($row)
    return $row
}

# Emit a SQL_QUERY row for a SQL query found in the source.
function Add-PSSqlQueryRow {
    param(
        [Parameter(Mandatory)][int]$LineStart,
        [Parameter(Mandatory)][int]$LineEnd,
        [int]$ColumnStart = 1,
        [string]$QueryText,
        [string]$ParentFunction,
        [string]$Kind = 'literal'
    )

    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|SQL_QUERY|<sql-query>|USAGE|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }
    $sig = Format-SingleLine -Text $QueryText
    if ($sig -and $sig.Length -gt 200) { $sig = $sig.Substring(0, 200) + '...' }

    $row = New-PSRow `
        -ComponentType  'SQL_QUERY' `
        -ComponentName  '<sql-query>' `
        -VariantType    $Kind `
        -LineStart      $LineStart `
        -LineEnd        $LineEnd `
        -ColumnStart    $ColumnStart `
        -ReferenceType  'USAGE' `
        -Scope          $scope `
        -ParentFunction $ParentFunction `
        -Signature      $sig `
        -RawText        $QueryText
    $script:rows.Add($row)
    return $row
}

# Emit a GLOBALCONFIG_REF row for a GlobalConfig setting reference.
function Add-PSGlobalConfigRefRow {
    param(
        [Parameter(Mandatory)][string]$SettingName,
        [Parameter(Mandatory)][int]$LineStart,
        [int]$ColumnStart = 1,
        [string]$ParentFunction,
        [string]$RefKind = 'sql-where'
    )

    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|GLOBALCONFIG_REF|$SettingName|USAGE|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }

    $row = New-PSRow `
        -ComponentType  'GLOBALCONFIG_REF' `
        -ComponentName  $SettingName `
        -VariantType    $RefKind `
        -LineStart      $LineStart `
        -LineEnd        $LineStart `
        -ColumnStart    $ColumnStart `
        -ReferenceType  'USAGE' `
        -Scope          $scope `
        -ParentFunction $ParentFunction `
        -Signature      "GlobalConfig: $SettingName" `
        -RawText        "GlobalConfig: $SettingName"
    $script:rows.Add($row)
    return $row
}

# Emit an RBAC_CHECK row for a call to an RBAC permission-check function.
function Add-PSRBACCheckRow {
    param(
        [Parameter(Mandatory)]$CommandAst,
        [Parameter(Mandatory)][string]$CheckFunction
    )

    $line = Get-PSAstNodeLine    -Node $CommandAst
    $col  = Get-PSAstNodeColumn  -Node $CommandAst

    $key = "$($script:CurrentFile)|$line|$col|RBAC_CHECK|$CheckFunction|USAGE|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }
    $sig = if ($CommandAst.Extent) { Format-SingleLine -Text $CommandAst.Extent.Text } else { "$CheckFunction(...)" }

    $parentFn = $null
    $cursor = $CommandAst.Parent
    while ($null -ne $cursor) {
        if ($cursor -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
            $parentFn = $cursor.Name
            break
        }
        $cursor = $cursor.Parent
    }

    $row = New-PSRow `
        -ComponentType  'RBAC_CHECK' `
        -ComponentName  $CheckFunction `
        -LineStart      $line `
        -LineEnd        $line `
        -ColumnStart    $col `
        -ReferenceType  'USAGE' `
        -Scope          $scope `
        -ParentFunction $parentFn `
        -Signature      $sig `
        -RawText        $sig
    $script:rows.Add($row)
    return $row
}


# ============================================================================
# EXECUTION: FILE DISCOVERY
# ============================================================================

Write-Log "Discovering PS files..."

$PSFiles = New-Object System.Collections.Generic.List[string]
$seenPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
foreach ($root in $PSScanRoots) {
    if (-not (Test-Path $root)) {
        Write-Log "Scan root not found, skipping: $root" 'WARN'
        continue
    }
    $found = @(Get-ChildItem -Path $root -Include '*.ps1','*.psm1','*.psd1' -Recurse -File |
                 Select-Object -ExpandProperty FullName)
    foreach ($f in $found) {
        # De-duplicate: scan roots overlap (scripts\ contains routes\ and
        # modules\), so the same file can surface from multiple roots.
        # First-write-wins; later occurrences are silently ignored.
        if ($seenPaths.Add($f)) {
            [void]$PSFiles.Add($f)
        }
    }
}

if (-not [string]::IsNullOrEmpty($FileFilter)) {
    $filtered = New-Object System.Collections.Generic.List[string]
    foreach ($f in $PSFiles) {
        $name = [System.IO.Path]::GetFileName($f)
        if ($name -eq $FileFilter -or $name -like $FileFilter) {
            [void]$filtered.Add($f)
        }
    }
    $PSFiles = $filtered
    Write-Log ("FileFilter applied: '{0}' -> {1} file(s)" -f $FileFilter, $PSFiles.Count)
} else {
    Write-Log ("Discovered {0} PS files to scan" -f $PSFiles.Count)
}


# ============================================================================
# EXECUTION: PASS 1 - PARSE AND COLLECT SHARED DEFINITIONS
# ============================================================================
# Walk every file once to (a) cache the parse result and (b) collect top-level
# function definitions from shared-library and shared-module files into the
# shared-functions HashSet. PS_FUNCTION_CALL USAGE rows in Pass 2 use this
# map to resolve scope=SHARED.

Write-Log "Pass 1: parse all files, collect shared-scope function definitions..."

$astCache = @{}

foreach ($file in $PSFiles) {
    $name = [System.IO.Path]::GetFileName($file)
    $role = Get-PSFileRole -FullPath $file

    # Data files (.psd1) get cataloged with a PS_FILE anchor row only.
    # No parse, no AST walk - they're not script files. We still cache a
    # marker entry so Pass 2 emits the inventory row.
    if ($role -eq 'data-file') {
        Write-Host "  Inventorying $name (role=$role)... " -NoNewline
        try {
            $lineCount = (Get-Content -Path $file -Encoding UTF8 | Measure-Object -Line).Lines
        } catch {
            $lineCount = 1
        }
        $astCache[$file] = @{
            Parsed = $null
            Role   = $role
            LineCount = $lineCount
        }
        Write-Host "ok" -ForegroundColor Green
        continue
    }

    Write-Host "  Parsing $name (role=$role)..." -NoNewline
    $parsed = Invoke-PSParse -FilePath $file
    if ($null -eq $parsed) {
        Write-Host " FAILED" -ForegroundColor Red
        continue
    }
    Write-Host " ok" -ForegroundColor Green
    $astCache[$file] = @{ Parsed = $parsed; Role = $role }

    # Only collect shared-scope functions from shared-library and module files.
    $isSharedScope = ($role -eq 'shared-library' -or $role -eq 'module')
    if (-not $isSharedScope) { continue }

    $topLevelFns = Find-PSAstNodes -Ast $parsed.Ast `
        -AstType ([System.Management.Automation.Language.FunctionDefinitionAst]) `
        -TopLevelOnly
    foreach ($fn in $topLevelFns) {
        if ($fn.Name) {
            [void]$script:sharedFunctions.Add($fn.Name)
            if (-not $script:sharedSourceFile.ContainsKey($fn.Name)) {
                $script:sharedSourceFile[$fn.Name] = $name
            }
        }
    }
}

Write-Log ("  Shared functions collected: {0}" -f $script:sharedFunctions.Count)


# ============================================================================
# EXECUTION: REGISTRY LOADS
# ============================================================================

Write-Log "Loading Object_Registry mapping for FK resolution..."
$objectRegistryMap = Get-ObjectRegistryMap `
    -ServerInstance $script:XFActsServerInstance `
    -Database       $script:XFActsDatabase `
    -FileType       @('PS','Route','API','Module')
Write-Log ("  Object_Registry rows loaded: {0}" -f $objectRegistryMap.Count)

Write-Log "Loading Component_Registry prefix map for registry validation..."
$componentPrefixMap = Get-ComponentRegistryPrefixMap `
    -ServerInstance $script:XFActsServerInstance `
    -Database       $script:XFActsDatabase `
    -FileType       @('PS','Route','API','Module')
Write-Log ("  Component_Registry prefix rows loaded: {0}" -f $componentPrefixMap.Count)

$objectRegistryMisses = New-Object 'System.Collections.Generic.HashSet[string]'


# ============================================================================
# EXECUTION: PASS 2 - PER-FILE WALK
# ============================================================================

Write-Log "Pass 2: generating Asset_Registry rows..."

foreach ($file in $PSFiles) {
    $name = [System.IO.Path]::GetFileName($file)
    if (-not $astCache.ContainsKey($file)) {
        Write-Log "  Skipping (no parsed AST): $name" 'WARN'
        continue
    }

    $cacheEntry = $astCache[$file]
    $parsed = $cacheEntry.Parsed
    $role   = $cacheEntry.Role

    # Data files (.psd1) get a basic file-inventory row only and skip the
    # full AST walk. Set minimal per-file context, emit PS_FILE, move on.
    if ($role -eq 'data-file') {
        $script:CurrentFile               = $name
        $script:CurrentFileFullPath       = $file
        $script:CurrentFileRole           = $role
        $script:CurrentFileIsShared       = $false
        $script:CurrentFileSource         = $null
        $script:CurrentAst                = $null
        $script:CurrentTokens             = $null
        $script:CurrentParseErrors        = $null
        $script:CurrentValidSectionTypes  = @()
        $script:CurrentRequiresComponent  = $false
        $script:CurrentRegistryHasMapping = $componentPrefixMap.ContainsKey($name)
        $script:CurrentRegistryPrefix     = if ($script:CurrentRegistryHasMapping) { $componentPrefixMap[$name] } else { $null }
        $script:CurrentFileLineCount      = $cacheEntry.LineCount
        $script:CurrentNormalizedComments = @()
        $script:CurrentCommentIndex       = @()
        $script:CurrentSections           = @()
        $script:CurrentLocalFunctions     = New-Object 'System.Collections.Generic.HashSet[string]'

        Write-Host ("  Inventorying {0} (data-file)..." -f $name) -ForegroundColor Cyan
        [void](Add-PSFileRow -LineEnd $script:CurrentFileLineCount)
        Write-Host "    -> 1 row (inventory only)" -ForegroundColor Green
        continue
    }

    # ---- Set per-file context ----
    $script:CurrentFile               = $name
    $script:CurrentFileFullPath       = $file
    $script:CurrentFileRole           = $role
    $script:CurrentFileIsShared       = ($role -eq 'shared-library' -or $role -eq 'module')
    $script:CurrentFileSource         = $parsed.Source
    $script:CurrentAst                = $parsed.Ast
    $script:CurrentTokens             = $parsed.Tokens
    $script:CurrentParseErrors        = $parsed.ParseErrors
    $script:CurrentValidSectionTypes  = $ValidSectionTypesByRole[$role]
    $script:CurrentRequiresComponent  = ($ComponentRequiredRoles -contains $role)
    $script:CurrentRegistryHasMapping = $componentPrefixMap.ContainsKey($name)
    $script:CurrentRegistryPrefix     = if ($script:CurrentRegistryHasMapping) { $componentPrefixMap[$name] } else { $null }

    # File line count from the source text
    $sourceLines = $parsed.Source -split "`r?`n"
    $script:CurrentFileLineCount = $sourceLines.Count

    # Build normalized comments + section list + comment index
    $script:CurrentNormalizedComments = Convert-PSCommentsToNormalized -Tokens $parsed.Tokens
    $script:CurrentCommentIndex       = New-PSCommentIndex -NormalizedComments $script:CurrentNormalizedComments
    $script:CurrentSections = New-SectionList `
        -Comments          $script:CurrentNormalizedComments `
        -FileLineCount     $script:CurrentFileLineCount `
        -ValidSectionTypes $script:CurrentValidSectionTypes

    # Build local-functions set
    $script:CurrentLocalFunctions = Get-LocalPSFunctions -Ast $parsed.Ast

    $startCount = $script:rows.Count
    $scopeLabel = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }
    Write-Host ("  Walking {0} ({1}, role={2})..." -f $name, $scopeLabel, $role) -ForegroundColor Cyan

    # ---- Emit PS_FILE anchor row ----
    $psFileRow = Add-PSFileRow -LineEnd $script:CurrentFileLineCount

    # ---- Emit FILE_HEADER row ----
    # PS header is the first comment-based-help block in the token stream
    # (Block-type comment starting at line 1 or near it).
    $headerComment = $null
    foreach ($c in $script:CurrentNormalizedComments) {
        if ($c.Type -eq 'Block' -and $c.LineStart -le 3) {
            $headerComment = $c
            break
        }
    }

    if ($headerComment) {
        $headerInfo = Get-PSFileHeaderInfo `
            -RawText   $headerComment.Text `
            -StartLine $headerComment.LineStart `
            -EndLine   $headerComment.LineEnd `
            -RequireComponent:$script:CurrentRequiresComponent

        $headerRawText = Format-SingleLine -Text $headerComment.Text

        $headerRow = Add-PSFileHeaderRow `
            -LineStart          $headerInfo.StartLine `
            -LineEnd            $headerInfo.EndLine `
            -RawText            $headerRawText `
            -PurposeDescription $headerInfo.Description
        foreach ($code in $headerInfo.DriftCodes) {
            Add-DriftCode -Row $headerRow -Code $code
        }

        # Mark header comment as used so it doesn't count as a stray block.
        $headerComment.OriginalToken | Out-Null
        foreach ($ci in $script:CurrentCommentIndex) {
            if ($ci.StartLine -eq $headerComment.LineStart) {
                $ci.Used = $true
                break
            }
        }

        # Validate .COMPONENT against Component_Registry if present
        if (-not [string]::IsNullOrEmpty($headerInfo.Component) -and $componentPrefixMap.Count -gt 0) {
            # Check if any file in componentPrefixMap maps to this component_name.
            # We don't have a direct component_name lookup here, but we can validate
            # presence via a second query. For now, defer to first-run analysis.
            # TODO: validate INVALID_COMPONENT_VALUE on a follow-up pass.
        }

        # FILE_ORG_MISMATCH
        if ($headerInfo.IsValid -or $headerInfo.FileOrgList.Count -gt 0) {
            $orgMatches = Test-FileOrgMatchesBanners `
                -FileOrgList $headerInfo.FileOrgList `
                -Sections    $script:CurrentSections
            if (-not $orgMatches) {
                Add-DriftCode -Row $headerRow -Code 'FILE_ORG_MISMATCH'
            }
        }
    }
    else {
        # No header found at all
        $headerRow = Add-PSFileHeaderRow `
            -LineStart 1 -LineEnd 1 `
            -RawText   $null `
            -PurposeDescription $null
        Add-DriftCode -Row $headerRow -Code 'MALFORMED_FILE_HEADER' `
            -Context "No comment-based-help block found at the top of the file."
    }

    # ---- Emit COMMENT_BANNER rows from the section list ----
    $previousSectionTypeOrderIdx = -1
    $seenBannerNames = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($s in $script:CurrentSections) {
        if ($null -eq $s) { continue }
        [void](Add-PSCommentBannerRow -Section $s `
            -PreviousSectionTypeOrderIdx $previousSectionTypeOrderIdx `
            -SeenBannerNames $seenBannerNames)
        if ($s.TypeName -and $script:SectionTypeOrder.ContainsKey($s.TypeName)) {
            $idx = [int]$script:SectionTypeOrder[$s.TypeName]
            if ($idx -gt $previousSectionTypeOrderIdx) {
                $previousSectionTypeOrderIdx = $idx
            }
        }
        [void]$seenBannerNames.Add($s.FullTitle)

        # If this is the CHANGELOG section, emit the PS_CHANGELOG row.
        if ($s.TypeName -eq 'CHANGELOG') {
            [void](Add-PSChangelogRow -Section $s)
        }
    }

    # ---- AST WALK: PASS A - Top-level functions ----
    try {
        $topLevelFns = Find-PSAstNodes -Ast $parsed.Ast `
            -AstType ([System.Management.Automation.Language.FunctionDefinitionAst]) `
            -TopLevelOnly
        foreach ($fn in $topLevelFns) {
            $fnRow = Add-PSFunctionRow -FunctionAst $fn
            if ($null -eq $fnRow) { continue }

            # Emit PS_DOCBLOCK if a preceding block comment exists for this function.
            # Get-PrecedingPSBlockComment marks comments as used; re-find here by
            # iterating the comment index for the most recent unused-or-used block
            # that ends just before the function. Since the row was already added
            # and the docblock comment was marked Used by Add-PSFunctionRow's
            # lookup, we replicate the index lookup but tolerate Used==true here.
            $fnLine = Get-PSAstNodeLine -Node $fn
            $docCandidate = $null
            foreach ($c in $script:CurrentCommentIndex) {
                if ($c.Type -ne 'Block') { continue }
                $gap = $fnLine - $c.EndLine
                if ($gap -ge 1 -and $gap -le 2) {
                    if ($null -eq $docCandidate -or $c.EndLine -gt $docCandidate.EndLine) {
                        $docCandidate = $c
                    }
                }
            }
            if ($docCandidate) {
                Add-PSDocblockRow `
                    -FunctionName $fn.Name `
                    -DocblockText $docCandidate.Text `
                    -LineStart    $docCandidate.StartLine `
                    -LineEnd      $docCandidate.EndLine | Out-Null
            }

            # PS_PARAMETER rows for each parameter
            $paramAsts = $null
            if ($fn.Body -and $fn.Body.ParamBlock -and $fn.Body.ParamBlock.Parameters) {
                $paramAsts = $fn.Body.ParamBlock.Parameters
            }
            elseif ($fn.Parameters) {
                $paramAsts = $fn.Parameters
            }
            if ($paramAsts) {
                foreach ($p in $paramAsts) {
                    Add-PSParameterRow -FunctionName $fn.Name -ParameterAst $p | Out-Null
                }
            }
        }
    } catch {
        Write-Log "Pass A (top-level functions) failed on ${name}: $($_.Exception.Message)" 'WARN'
    }

    # ---- AST WALK: PASS B - Top-level assignments (CONSTANTS/VARIABLES) ----
    try {
        # Look at the top-level statements only -- nested assignments inside
        # functions aren't cataloged at the file level.
        $endBlock = $parsed.Ast.EndBlock
        if ($endBlock -and $endBlock.Statements) {
            foreach ($stmt in $endBlock.Statements) {
                if ($stmt -is [System.Management.Automation.Language.AssignmentStatementAst]) {
                    Add-PSAssignmentRow -AssignmentAst $stmt | Out-Null
                }
            }
        }
    } catch {
        Write-Log "Pass B (top-level assignments) failed on ${name}: $($_.Exception.Message)" 'WARN'
    }

    # ---- AST WALK: PASS C - CommandAst for Pode infrastructure + imports ----
    try {
        $allCommands = Find-PSAstNodes -Ast $parsed.Ast `
            -AstType ([System.Management.Automation.Language.CommandAst])
        foreach ($cmd in $allCommands) {
            $cmdName = $cmd.GetCommandName()
            if ([string]::IsNullOrEmpty($cmdName)) { continue }

            switch -Regex ($cmdName) {
                '^Add-PodeRoute$' {
                    # Extract -Path, -Method from CommandElements (named or positional)
                    $method = $null
                    $path = $null
                    $elements = $cmd.CommandElements
                    for ($ei = 1; $ei -lt $elements.Count; $ei++) {
                        $el = $elements[$ei]
                        if ($el -is [System.Management.Automation.Language.CommandParameterAst]) {
                            $paramName = $el.ParameterName
                            $next = if (($ei + 1) -lt $elements.Count) { $elements[$ei + 1] } else { $null }
                            if ($next -and $next -isnot [System.Management.Automation.Language.CommandParameterAst]) {
                                $valText = $next.Extent.Text.Trim("'`"")
                                if ($paramName -eq 'Method') { $method = $valText }
                                elseif ($paramName -eq 'Path') { $path = $valText }
                            }
                        }
                    }
                    Add-PSRouteRow -CommandAst $cmd -Method $method -Path $path | Out-Null
                }
                '^Add-PodeRouteWebSocket$' {
                    $path = $null
                    $elements = $cmd.CommandElements
                    for ($ei = 1; $ei -lt $elements.Count; $ei++) {
                        $el = $elements[$ei]
                        if ($el -is [System.Management.Automation.Language.CommandParameterAst] -and $el.ParameterName -eq 'Path') {
                            $next = if (($ei + 1) -lt $elements.Count) { $elements[$ei + 1] } else { $null }
                            if ($next) { $path = $next.Extent.Text.Trim("'`"") }
                        }
                    }
                    Add-PSWebSocketRouteRow -CommandAst $cmd -Path $path | Out-Null
                }
                '^Add-PodeMiddleware$' {
                    $mwName = $null
                    $elements = $cmd.CommandElements
                    for ($ei = 1; $ei -lt $elements.Count; $ei++) {
                        $el = $elements[$ei]
                        if ($el -is [System.Management.Automation.Language.CommandParameterAst] -and $el.ParameterName -eq 'Name') {
                            $next = if (($ei + 1) -lt $elements.Count) { $elements[$ei + 1] } else { $null }
                            if ($next) { $mwName = $next.Extent.Text.Trim("'`"") }
                        }
                    }
                    Add-PSMiddlewareRow -CommandAst $cmd -MiddlewareName $mwName | Out-Null
                }
                '^Export-ModuleMember$' {
                    # Extract -Function / -Cmdlet / -Alias / -Variable names and
                    # emit one PS_EXPORT row per name. The value expression after
                    # the parameter can take multiple AST shapes:
                    #
                    #   -Function 'Foo'              -> StringConstantExpressionAst
                    #   -Function 'Foo','Bar'        -> ArrayLiteralAst
                    #   -Function ('Foo','Bar')      -> ParenExpressionAst wrapping ArrayLiteralAst
                    #   -Function @('Foo','Bar')     -> ArrayExpressionAst wrapping
                    #                                   StatementBlockAst > PipelineAst > ArrayLiteralAst
                    #
                    # The @() form is common in real codebases for multi-line
                    # exports with interspersed comments. Use a helper to walk
                    # whichever shape we find and pull out the string literals.
                    $elements = $cmd.CommandElements
                    $exportKind = 'function'
                    for ($ei = 1; $ei -lt $elements.Count; $ei++) {
                        $el = $elements[$ei]
                        if ($el -is [System.Management.Automation.Language.CommandParameterAst]) {
                            $pn = $el.ParameterName
                            if ($pn -eq 'Function' -or $pn -eq 'Cmdlet' -or $pn -eq 'Alias' -or $pn -eq 'Variable') {
                                $exportKind = $pn.ToLower()
                                $next = if (($ei + 1) -lt $elements.Count) { $elements[$ei + 1] } else { $null }
                                if ($next) {
                                    $exportedNames = Get-ExportedNamesFromAst -Node $next
                                    foreach ($nm in $exportedNames) {
                                        if (-not [string]::IsNullOrWhiteSpace($nm)) {
                                            Add-PSExportRow -CommandAst $cmd -ExportedName $nm -ExportKind $exportKind | Out-Null
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                '^Import-Module$' {
                    $importedPath = $null
                    if ($cmd.CommandElements.Count -gt 1) {
                        $importedPath = $cmd.CommandElements[1].Extent.Text.Trim("'`"")
                    }
                    Add-PSModuleImportRow -ImportAst $cmd -ImportKind 'Import-Module' -ImportedPath $importedPath | Out-Null
                }
                '^Write-Host$' {
                    if ($WriteHostExemptFiles -notcontains $name) {
                        Add-PSWriteHostRow -CommandAst $cmd | Out-Null
                    }
                }
                default {
                    # RBAC checks
                    if ($RBACCheckFunctions -contains $cmdName) {
                        Add-PSRBACCheckRow -CommandAst $cmd -CheckFunction $cmdName | Out-Null
                    }
                    # Cataloged function calls
                    Add-PSFunctionCallRow -CommandAst $cmd | Out-Null
                }
            }
        }
    } catch {
        Write-Log "Pass C (CommandAst processing) failed on ${name}: $($_.Exception.Message)" 'WARN'
    }

    # ---- AST WALK: PASS D - Dot-source statements ----
    try {
        # Dot-source statements appear in the AST as CommandAst with InvocationOperator='Dot'.
        # We catch these here separately because they don't match a command name.
        $dotSources = Find-PSAstNodes -Ast $parsed.Ast `
            -AstType ([System.Management.Automation.Language.CommandAst]) | Where-Object {
                $_.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Dot
            }
        foreach ($cmd in $dotSources) {
            $importedPath = $null
            if ($cmd.CommandElements.Count -ge 1) {
                $importedPath = $cmd.CommandElements[0].Extent.Text.Trim("'`"")
            }
            Add-PSModuleImportRow -ImportAst $cmd -ImportKind 'dot-source' -ImportedPath $importedPath | Out-Null
        }
    } catch {
        Write-Log "Pass D (dot-source detection) failed on ${name}: $($_.Exception.Message)" 'WARN'
    }

    # ---- AST WALK: PASS E - String / here-string scanning for SQL and GlobalConfig ----
    try {
        # Find every string-bearing AST node. We look at both
        # StringConstantExpressionAst (single/double-quoted single-line strings
        # and here-string content nodes) and ExpandableStringExpressionAst.
        $stringNodes = @(
            Find-PSAstNodes -Ast $parsed.Ast -AstType ([System.Management.Automation.Language.StringConstantExpressionAst])
            Find-PSAstNodes -Ast $parsed.Ast -AstType ([System.Management.Automation.Language.ExpandableStringExpressionAst])
        )
        foreach ($sn in $stringNodes) {
            $text = $sn.Value
            if ([string]::IsNullOrWhiteSpace($text)) { continue }
            # Skip very short strings -- can't be SQL or meaningful config refs.
            if ($text.Length -lt 10) { continue }

            $line = Get-PSAstNodeLine    -Node $sn
            $endLn = Get-PSAstNodeEndLine -Node $sn
            $col  = Get-PSAstNodeColumn  -Node $sn

            # Find enclosing function for parent_function attribution
            $parentFn = $null
            $cursor = $sn.Parent
            while ($null -ne $cursor) {
                if ($cursor -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
                    $parentFn = $cursor.Name
                    break
                }
                $cursor = $cursor.Parent
            }

            if (Test-LooksLikeSQL -Text $text) {
                Add-PSSqlQueryRow `
                    -LineStart $line -LineEnd $endLn -ColumnStart $col `
                    -QueryText $text -ParentFunction $parentFn -Kind 'literal' | Out-Null

                # GlobalConfig refs inside this SQL
                $gcRefs = Get-GlobalConfigReferences -Text $text
                foreach ($ref in $gcRefs) {
                    $refLine = $line + $ref.LineOffset
                    Add-PSGlobalConfigRefRow `
                        -SettingName $ref.SettingName `
                        -LineStart   $refLine `
                        -ColumnStart $ref.ColumnStart `
                        -ParentFunction $parentFn `
                        -RefKind $ref.MatchKind | Out-Null
                }
            }
            else {
                # Even non-SQL strings can contain setting_name = 'xxx' references
                # (in permissive mode); scan anyway.
                $gcRefs = Get-GlobalConfigReferences -Text $text
                foreach ($ref in $gcRefs) {
                    $refLine = $line + $ref.LineOffset
                    Add-PSGlobalConfigRefRow `
                        -SettingName $ref.SettingName `
                        -LineStart   $refLine `
                        -ColumnStart $ref.ColumnStart `
                        -ParentFunction $parentFn `
                        -RefKind $ref.MatchKind | Out-Null
                }
            }
        }
    } catch {
        Write-Log "Pass E (string scanning) failed on ${name}: $($_.Exception.Message)" 'WARN'
    }

    # ---- AST WALK: PASS F - Comment-level passes ----
    try {
        foreach ($c in $script:CurrentNormalizedComments) {
            $text = $c.Text
            if ([string]::IsNullOrEmpty($text)) { continue }

            if ($c.Type -eq 'Line') {
                # Inline dividers: a single-line comment whose content is
                # entirely '=' or '-' (with optional whitespace).
                if ($text -match '^[\s]*[=\-]{4,}[\s]*$' -or
                    $text -match '^[\s]*[\u2500-\u257F]{4,}[\s]*$') {
                    Add-PSInlineBannerRow -LineStart $c.LineStart -ColumnStart $c.ColumnStart `
                        -RawText $c.OriginalToken.Text | Out-Null
                    continue
                }

                # Removed-code headstones
                if ($text -match '(?i)^\s*(removed|deleted|was|todo:?\s*remove)\b') {
                    Add-PSRemovedCodeCommentRow -LineStart $c.LineStart -ColumnStart $c.ColumnStart `
                        -RawText $c.OriginalToken.Text | Out-Null
                }
            }
            elseif ($c.Type -eq 'Block') {
                # Free-standing block comments that aren't header, banner, or docblock.
                # Skip if already claimed (e.g. by a function as its docblock, or as
                # the file header).
                $isClaimed = $false
                foreach ($ci in $script:CurrentCommentIndex) {
                    if ($ci.StartLine -eq $c.LineStart -and $ci.Used) {
                        $isClaimed = $true
                        break
                    }
                }
                if ($isClaimed) { continue }

                # Skip section banners
                if (Test-IsBannerComment -CommentText $text -ValidSectionTypes $script:CurrentValidSectionTypes) {
                    continue
                }

                # Sub-section markers: text like '-- label --'
                $trimmedText = $text.Trim()
                if ($trimmedText -match '^--.+--$') { continue }

                # Anything left over is a stray block comment
                Add-PSCommentBlockRow -LineStart $c.LineStart -LineEnd $c.LineEnd `
                    -ColumnStart $c.ColumnStart -RawText $c.OriginalToken.Text | Out-Null
            }
        }
    } catch {
        Write-Log "Pass F (comment passes) failed on ${name}: $($_.Exception.Message)" 'WARN'
    }

    # ---- FORBIDDEN_COMMENT_STYLE: stray block comments accounting ----
    # Aggregate stray block comments and attach the drift code to PS_FILE.
    $strayLines = New-Object System.Collections.Generic.List[int]
    foreach ($c in $script:CurrentNormalizedComments) {
        if ($c.Type -ne 'Block') { continue }
        # Skip the file header
        if ($c.LineStart -le 3) { continue }
        # Skip section banners
        if (Test-IsBannerComment -CommentText $c.Text -ValidSectionTypes $script:CurrentValidSectionTypes) { continue }
        # Skip sub-section markers
        $trimmedText = if ($c.Text) { $c.Text.Trim() } else { '' }
        if ($trimmedText -match '^--.+--$') { continue }
        # Skip if claimed by a definition
        $isClaimed = $false
        foreach ($ci in $script:CurrentCommentIndex) {
            if ($ci.StartLine -eq $c.LineStart -and $ci.Used) {
                $isClaimed = $true
                break
            }
        }
        if ($isClaimed) { continue }
        $strayLines.Add([int]$c.LineStart)
    }
    if ($strayLines.Count -gt 0 -and $psFileRow) {
        $linesText = ($strayLines | Sort-Object) -join ', '
        Add-DriftCode -Row $psFileRow -Code 'FORBIDDEN_COMMENT_STYLE' `
            -Context "Stray block comments at line(s): $linesText."
    }

    $delta = $script:rows.Count - $startCount
    Write-Host ("    -> {0} rows" -f $delta) -ForegroundColor Green
}


# ============================================================================
# EXECUTION: PASS 3 - CROSS-FILE COMPLIANCE CHECKS
# ============================================================================

Write-Log "Pass 3: cross-file compliance checks..."

# EXCESS_BLANK_LINES: walk each file's top-level statements and compare each
# statement's start line to the previous statement's end line. Gap > 2 means
# 2+ blank lines between top-level constructs.
foreach ($file in $PSFiles) {
    $name = [System.IO.Path]::GetFileName($file)
    if (-not $astCache.ContainsKey($file)) { continue }
    $parsed = $astCache[$file].Parsed
    if ($null -eq $parsed) { continue }                # data-files have no AST
    if ($null -eq $parsed.Ast.EndBlock) { continue }
    $stmts = $parsed.Ast.EndBlock.Statements
    if ($null -eq $stmts -or $stmts.Count -lt 2) { continue }

    $excessFound = $false
    for ($ni = 1; $ni -lt $stmts.Count; $ni++) {
        $prev = $stmts[$ni - 1]
        $cur  = $stmts[$ni]
        $prevEnd  = if ($prev.Extent) { [int]$prev.Extent.EndLineNumber } else { 0 }
        $curStart = if ($cur.Extent)  { [int]$cur.Extent.StartLineNumber } else { 0 }
        if ($prevEnd -gt 0 -and $curStart -gt 0 -and ($curStart - $prevEnd) -gt 2) {
            $excessFound = $true
            break
        }
    }

    if ($excessFound -and $script:psFileRowByFile.ContainsKey($name)) {
        Add-DriftCode -Row $script:psFileRowByFile[$name] -Code 'EXCESS_BLANK_LINES' `
            -Context "More than one blank line appears between top-level constructs in $name."
    }
}

# SHADOWS_SHARED_FUNCTION: a non-shared file defining a function whose name
# matches a shared-library export.
$shadowCandidates = @($script:rows | Where-Object {
    ($_.ComponentType -eq 'PS_FUNCTION' -or $_.ComponentType -eq 'PS_FUNCTION_VARIANT') -and
    $_.ReferenceType -eq 'DEFINITION' -and
    $_.Scope -eq 'LOCAL'
})
foreach ($row in $shadowCandidates) {
    if ($script:sharedFunctions.Contains($row.ComponentName)) {
        $shadowSrc = if ($script:sharedSourceFile.ContainsKey($row.ComponentName)) { $script:sharedSourceFile[$row.ComponentName] } else { '<shared>' }
        Add-DriftCode -Row $row -Code 'SHADOWS_SHARED_FUNCTION' `
            -Context "Function '$($row.ComponentName)' shadows the shared definition in '$shadowSrc'."
    }
}


# ============================================================================
# EXECUTION: OUTPUT BOUNDARY VALIDATION
# ============================================================================

Test-DriftCodesAgainstMasterTable -Rows $script:rows


# ============================================================================
# EXECUTION: OCCURRENCE INDEX COMPUTATION
# ============================================================================

Write-Log "Computing occurrence_index for all rows..."
Set-OccurrenceIndices -Rows $script:rows


# ============================================================================
# EXECUTION: SUMMARY OUTPUT
# ============================================================================

Write-Log ("Total rows generated: {0}" -f $script:rows.Count)

if ($script:rows.Count -gt 0) {
    $script:rows | Group-Object { "$($_.ComponentType) / $($_.ReferenceType) / $($_.Scope)" } |
        Sort-Object Count -Descending |
        Format-Table @{L='Component / Ref / Scope';E='Name'}, Count -AutoSize

    $driftedCount = @($script:rows | Where-Object { $_.DriftCodes }).Count
    Write-Log ("Rows with drift codes: {0} of {1} ({2:F1}%)" -f $driftedCount, $script:rows.Count, ($driftedCount / [double]$script:rows.Count * 100))
}


# ============================================================================
# EXECUTION: DATABASE WRITE
# ============================================================================

if (-not $Execute) {
    Write-Log "PREVIEW MODE - no rows written to Asset_Registry. Use -Execute to insert." 'WARN'
    return
}

Write-Log "Clearing existing PS rows from Asset_Registry..."
if (-not [string]::IsNullOrEmpty($FileFilter)) {
    $cleared = Invoke-SqlNonQuery -Query "DELETE FROM dbo.Asset_Registry WHERE file_type = 'PS' AND file_name LIKE @pattern;" `
        -Parameters @{ pattern = $FileFilter }
} else {
    $cleared = Invoke-SqlNonQuery -Query "DELETE FROM dbo.Asset_Registry WHERE file_type = 'PS';"
}
if (-not $cleared) {
    Write-Log "Failed to clear existing PS rows. Aborting." 'ERROR'
    exit 1
}

if ($script:rows.Count -eq 0) {
    Write-Log "No rows to insert." 'WARN'
    exit 0
}

Write-Log "Bulk-inserting $($script:rows.Count) rows..."
try {
    $inserted = Invoke-AssetRegistryBulkInsert `
        -ServerInstance     $script:XFActsServerInstance `
        -Database           $script:XFActsDatabase `
        -Rows               $script:rows `
        -ObjectRegistryMap  $objectRegistryMap `
        -Misses             $objectRegistryMisses
    Write-Log ("Inserted {0} rows into dbo.Asset_Registry." -f $inserted) 'SUCCESS'
}
catch {
    Write-Log "Bulk insert failed: $($_.Exception.Message)" 'ERROR'
    exit 1
}


# ============================================================================
# EXECUTION: OBJECT_REGISTRY MISS REPORT
# ============================================================================

if ($objectRegistryMisses.Count -gt 0) {
    Write-Log ("Object_Registry registration gaps detected for {0} file(s):" -f $objectRegistryMisses.Count) 'WARN'
    foreach ($missing in ($objectRegistryMisses | Sort-Object)) {
        Write-Log ("  MISSING: $missing") 'WARN'
    }
    Write-Log "Add the file(s) above to dbo.Object_Registry to enable FK linkage on subsequent runs." 'WARN'
}

Write-Log "Done."
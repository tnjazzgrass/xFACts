<#
.SYNOPSIS
    xFACts - Asset Registry PowerShell Populator

.DESCRIPTION
    Walks every .ps1 and .psm1 file under the xFACts PowerShell roots,
    parses each with the native PowerShell AST parser, and generates
    Asset_Registry rows describing every catalogable construct plus drift
    codes. Five file roles are recognized via path-based classification
    (page-route, api-route, module, shared-library, standalone), each with
    its own valid-section-types set.

.PARAMETER Execute
    Required to delete the existing PS rows and write the new row set.
    Without this flag, runs in preview mode.

.PARAMETER FileFilter
    Optional file-name filter for processing a single file or subset.

.COMPONENT
    Tools.Utilities

.NOTES
    File Name : Populate-AssetRegistry-PS.ps1
    Location  : E:\xFACts-PowerShell

    FILE ORGANIZATION
    -----------------
    CHANGELOG: CHANGE HISTORY
    PARAMETERS: SCRIPT PARAMETERS
    IMPORTS: SCRIPT DEPENDENCIES
    INITIALIZATION: SCRIPT INITIALIZATION
    CONSTANTS: EXECUTION PREFERENCES
    CONSTANTS: PATHS AND DISCOVERY
    CONSTANTS: SPEC CONSTANTS
    CONSTANTS: DRIFT DESCRIPTIONS
    VARIABLES: SCRIPT-SCOPE STATE
    FUNCTIONS: FILE ROLE DETECTION
    FUNCTIONS: PS PARSER AND COMMENT NORMALIZATION
    FUNCTIONS: FORMAT HELPERS
    FUNCTIONS: SQL / GLOBALCONFIG / RBAC DETECTION
    FUNCTIONS: VARIANT SHAPE HELPERS
    FUNCTIONS: LOCAL DEFINITION COLLECTION
    FUNCTIONS: COMMENT INDEX
    FUNCTIONS: ROW EMITTERS
    EXECUTION: SCRIPT EXECUTION
#>

<# ============================================================================
   CHANGELOG: CHANGE HISTORY
   ----------------------------------------------------------------------------
   Date-stamped change history. Each entry is one ISO date line followed by an
   indented description. Entries appear most-recent first.
   Prefix: (none)
   ============================================================================ #>

# 2026-05-31  Added FORBIDDEN_ENV_ASSIGNMENT. The $env: provider is now
#             permitted at file scope only for the variables in
#             $AuthorizedEnvVars (currently NODE_PATH); any other $env: write
#             is drift. Previously every $env: write fired
#             FORBIDDEN_SCOPE_QUALIFIER.
# 2026-05-31  Dropped the separate Get-ObjectRegistryMap call. The zone/scope
#             map now also carries registry_id, so the file makes one
#             Object_Registry query instead of two. A transitional shim at the
#             bulk-insert call projects registry_id back to the flat map shape
#             the bulk insert still expects.
# 2026-05-29  Conformed the working file to the Control Center PowerShell file
#             format spec: block-comment section banners, canonical section
#             order, single EXECUTION section with sub-section markers, and
#             leading purpose comments on script-scope declarations.

<# ============================================================================
   PARAMETERS: SCRIPT PARAMETERS
   ----------------------------------------------------------------------------
   Script-level parameters: the execute switch and an optional single-file filter.
   Prefix: (none)
   ============================================================================ #>

[CmdletBinding()]
param(
    [switch]$Execute,
    [string]$FileFilter
)

<# ============================================================================
   IMPORTS: SCRIPT DEPENDENCIES
   ----------------------------------------------------------------------------
   Dot-sourced shared infrastructure: orchestrator helpers and the Asset
   Registry shared functions (row construction, banner parsing, registry loads).
   Prefix: (none)
   ============================================================================ #>

. "$PSScriptRoot\xFACts-OrchestratorFunctions.ps1"
. "$PSScriptRoot\xFACts-AssetRegistryFunctions.ps1"

<# ============================================================================
   INITIALIZATION: SCRIPT INITIALIZATION
   ----------------------------------------------------------------------------
   One-time setup of shared infrastructure, logging, and application identity.
   Prefix: (none)
   ============================================================================ #>

Initialize-XFActsScript -ScriptName 'Populate-AssetRegistry-PS' -Execute:$Execute

<# ============================================================================
   CONSTANTS: EXECUTION PREFERENCES
   ----------------------------------------------------------------------------
   PowerShell preference variables that govern script execution behavior.
   Prefix: (none)
   ============================================================================ #>

# Stop on any error so failures surface immediately rather than continuing
# against partial state.
$ErrorActionPreference = 'Stop'

<# ============================================================================
   CONSTANTS: PATHS AND DISCOVERY
   ----------------------------------------------------------------------------
   Scan roots and file-classification lists (shared libraries, shared modules,
   standalone path exceptions, Write-Host exemptions).
   Prefix: (none)
   ============================================================================ #>

# Scan roots covering all PS files in the platform. Roots are nested, so
# discovery de-duplicates by full path after collection.
$PSScanRoots = @(
    'E:\xFACts-PowerShell',
    'E:\xFACts-ControlCenter\scripts',
    'E:\xFACts-ControlCenter\scripts\routes',
    'E:\xFACts-ControlCenter\scripts\modules'
)

# Shared library files (xFACts-PowerShell root). Their functions are visible
# to all consumers and resolve as scope=SHARED.
$SharedLibraryFiles = @(
    'xFACts-OrchestratorFunctions.ps1',
    'xFACts-AssetRegistryFunctions.ps1',
    'xFACts-IndexFunctions.ps1'
)

# Module files (.psm1) exporting cataloged helpers consumed by CC routes.
$SharedModuleFiles = @(
    'xFACts-Helpers.psm1',
    'xFACts-CCShared.psm1'
)

# Files in a routes-style directory that are structurally standalone.
$StandalonePathExceptions = @(
    'Start-ControlCenter.ps1'
)

# Files exempt from Write-Host drift; these legitimately use Write-Host for
# operator-facing output.
$WriteHostExemptFiles = @(
    'Start-xFACtsOrchestrator.ps1'
)

<# ============================================================================
   CONSTANTS: SPEC CONSTANTS
   ----------------------------------------------------------------------------
   The recognized section types and the per-role valid-type, ordering, singleton,
   prefix-classification, and required-section tables.
   Prefix: (none)
   ============================================================================ #>

# The recognized section types. Per-role tables below carve out which subset
# each file role permits.
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

# Required section order. Each type maps to an order slot; lower = earlier.
# ROUTE and EXECUTION share slot 8 because they are mutually exclusive by role
# (page-routes have ROUTE; standalone scripts have EXECUTION).
$SectionTypeOrder = @{
    'CHANGELOG'      = 1
    'PARAMETERS'     = 2
    'IMPORTS'        = 3
    'INITIALIZATION' = 4
    'CONSTANTS'      = 5
    'VARIABLES'      = 6
    'FUNCTIONS'      = 7
    'EXECUTION'      = 8
    'ROUTE'          = 8
    'EXPORTS'        = 9
}

# Per-role valid section types. A banner whose type is not in the role list
# produces UNKNOWN_SECTION_TYPE drift.
$ValidSectionTypesByRole = @{
    'page-route'     = @('CHANGELOG','ROUTE')
    'api-route'      = @('ROUTE')
    'module'         = @('CHANGELOG','IMPORTS','CONSTANTS','VARIABLES','FUNCTIONS','EXPORTS')
    'standalone'     = @('CHANGELOG','IMPORTS','PARAMETERS','INITIALIZATION','CONSTANTS','VARIABLES','FUNCTIONS','EXECUTION')
    'shared-library' = @('CHANGELOG','IMPORTS','CONSTANTS','VARIABLES','FUNCTIONS','EXPORTS')
}

# Section types that appear exactly once per file (DUPLICATE_SINGULAR_SECTION).
# CONSTANTS, VARIABLES, and FUNCTIONS may repeat.
$SingletonSectionTypes = @(
    'CHANGELOG','IMPORTS','PARAMETERS','INITIALIZATION','EXPORTS',
    'EXECUTION','ROUTE'
)

# Identifier-bearing sections: their contents declare the file prefix.
$IdentifierBearingSectionTypes = @(
    'CONSTANTS','VARIABLES','FUNCTIONS'
)
# Identifier-free sections: their contents declare (none).
$IdentifierFreeSectionTypes = @(
    'CHANGELOG','IMPORTS','PARAMETERS','INITIALIZATION','EXECUTION','ROUTE','EXPORTS'
)

# Canonical banner NAMEs for singleton section types. A mismatch fires
# MALFORMED_SINGLETON_NAME. ROUTE has two valid NAMEs based on role.
$SingletonSectionCanonicalNames = @{
    'CHANGELOG'      = @('CHANGE HISTORY')
    'IMPORTS'        = @('SCRIPT DEPENDENCIES')
    'PARAMETERS'     = @('SCRIPT PARAMETERS')
    'INITIALIZATION' = @('SCRIPT INITIALIZATION')
    'EXPORTS'        = @('MODULE EXPORTS')
    'EXECUTION'      = @('SCRIPT EXECUTION')
    'ROUTE'          = @('PAGE PATH','API ENDPOINTS')
}

# Sections required per role; absence fires MISSING_REQUIRED_SECTION.
$RequiredSectionsByRole = @{
    'page-route'     = @('ROUTE')
    'api-route'      = @('ROUTE')
    'module'         = @('FUNCTIONS','EXPORTS')
    'standalone'     = @('EXECUTION')
    'shared-library' = @('FUNCTIONS')
}

# Roles for which .COMPONENT in the header is required rather than optional.
$ComponentRequiredRoles = @('page-route','api-route','module','shared-library','standalone')

# Function names that count as RBAC checks.
$RBACCheckFunctions = @(
    'Get-UserAccess',
    'Test-ActionEndpoint',
    'Get-UserPageTier',
    'Test-UserHasRole'
)

# Function names that take a -Query parameter pointing at a SQL string;
# used by SQL_QUERY call-site detection.
$SQLQueryFunctions = @(
    'Invoke-Sqlcmd',
    'Invoke-XFActsQuery',
    'Invoke-XFActsNonQuery',
    'Invoke-CRS5ReadQuery',
    'Invoke-AGReadQuery',
    'Invoke-SqlNonQuery',
    'Get-SqlData'
)

# Function names that take a GlobalConfig setting name; used by
# GLOBALCONFIG_REF detection.
$GlobalConfigFunctions = @(
    'Get-GlobalConfigValue',
    'Set-GlobalConfigValue',
    'Test-GlobalConfigSetting'
)

# Environment variables a file may write at file scope via the $env: provider.
# Any $env: write to a name not listed here fires FORBIDDEN_ENV_ASSIGNMENT.
# Matched case-insensitively (Windows environment names are case-insensitive).
$AuthorizedEnvVars = @(
    'NODE_PATH'
)

<# ============================================================================
   CONSTANTS: DRIFT DESCRIPTIONS
   ----------------------------------------------------------------------------
   Master table of every drift code the populator can emit, grouped by category.
   Used by Add-DriftCode to validate codes before attachment.
   Prefix: (none)
   ============================================================================ #>

# Master table mapping every drift code to its human-readable description.
$DriftDescriptions = [ordered]@{
    # File header
    'MALFORMED_FILE_HEADER'             = "The file's header block is missing, malformed, or contains required fields out of order."
    'FORBIDDEN_HEADER_KEYWORD'          = "The file header contains a forbidden comment-based-help keyword (.EXAMPLE, .INPUTS, .OUTPUTS, .LINK, .ROLE, .FUNCTIONALITY, .FORWARDHELPTARGETNAME, .REMOTEHELPRUNSPACE, or .EXTERNALHELP)."
    'MALFORMED_NOTES_FIELD'             = "The .NOTES block is missing required fields (File Name, Location, FILE ORGANIZATION) or contains extra fields."
    'NOTES_FIELD_ORDER_VIOLATION'       = "The .NOTES block's fields appear out of canonical order. The required order is File Name, Location, FILE ORGANIZATION list."
    'PARAMETER_DOC_ORDER_VIOLATION'     = "The .PARAMETER blocks do not appear in the same order as the parameters in the param() block. Applies to both file-header docblocks and function docblocks."
    'MISSING_COMPONENT_DECLARATION'     = "The file header is missing a .COMPONENT declaration. Every file must declare which Component_Registry component it belongs to."
    'INVALID_COMPONENT_VALUE'           = "The file header's .COMPONENT value does not match any active row in Component_Registry."
    'FORBIDDEN_CHANGELOG_IN_HEADER'     = "The file header contains a CHANGELOG block. CHANGELOG belongs in a dedicated section outside the header, not inside the comment-based-help block."
    'FORBIDDEN_AUTHOR_IN_HEADER'        = "The file header contains an Author: bookkeeping line. Authorship belongs in System_Metadata, not in source headers."
    'FORBIDDEN_DATE_IN_HEADER'          = "The file header contains a Date: or Last Modified bookkeeping line. Dates belong in System_Metadata, not in source headers."
    'FORBIDDEN_VERSION_IN_HEADER'       = "The file header contains a Version: line. Version numbers belong in System_Metadata only."
    'FORBIDDEN_FUNCTION_INVENTORY'      = "The file header contains a Function Inventory block. The function list belongs in the FILE ORGANIZATION section, not as a separate enumeration."
    'FORBIDDEN_DEPLOYMENT_BLOCK'        = "The file header contains a Deployment: block. Deployment instructions belong in an external runbook, not in the source file header."
    'FORBIDDEN_INLINE_DIVIDER_IN_HEADER' = "The file header contains inline divider rules of '=' or '-' characters outside the .NOTES block's FILE ORGANIZATION separator. Inline rules inside the header are not part of the comment-based-help spec."
    'FILE_ORG_MISMATCH'                 = "The FILE ORGANIZATION list inside .NOTES does not exactly match the section banner titles in the file body, by content or by order."

    # Section banners
    'MISSING_SECTION_BANNER'            = "A function definition (or other catalogable construct) appears outside any banner -- no section banner precedes it in the file."
    'BANNER_INLINE_SHAPE'               = "A section banner uses the single-line ===== Title ===== form. The spec requires a multi-line banner with bracketing rule lines, title line, separator, description block, and Prefix line."
    'BANNER_INVALID_RULE_CHAR'          = "A section banner's opening or closing bracketing line is not composed entirely of '=' characters."
    'BANNER_INVALID_RULE_LENGTH'        = "A section banner's opening or closing bracketing line is not exactly 76 '=' characters."
    'BANNER_INVALID_SEPARATOR_CHAR'     = "A section banner's middle separator line is missing or is not composed entirely of '-' characters."
    'BANNER_INVALID_SEPARATOR_LENGTH'   = "A section banner's middle separator line is not exactly 76 '-' characters."
    'BANNER_MALFORMED_TITLE_LINE'       = "A section banner has no recognizable title line in the form '<TYPE>: <NAME>'. The TYPE token must be uppercase letters and underscores only."
    'BANNER_MISSING_DESCRIPTION'        = "A section banner has no description content between the separator and the Prefix line. The description is required (1 to 5 sentences explaining what the section contains)."
    'BANNER_MISSING_NAME'               = "A section banner declares a bare <TYPE> or <TYPE>: with no NAME. Every banner requires a human-readable NAME; singletons use the fixed NAMEs."
    'DUPLICATE_BANNER_NAME'             = "Two or more section banners with the same TYPE and NAME appear in the file. Each banner must be unique within a file."

    # Section types
    'UNKNOWN_SECTION_TYPE'              = "A section banner declares a TYPE not valid for the file's role. Each role has its own permitted section-type set."
    'SECTION_TYPE_ORDER_VIOLATION'      = "Section types appear out of the required order for the file role."
    'FORBIDDEN_SECTION_TYPE'            = "A section type appears in a file role that forbids it (e.g., INITIALIZATION in a page-route file)."
    'MISSING_REQUIRED_SECTION'          = "A section type required for this role is absent from the file (e.g., a module file with no EXPORTS section)."
    'DUPLICATE_SINGULAR_SECTION'        = "A section type marked 'exactly one' appears more than once in the file."
    'MALFORMED_SINGLETON_NAME'          = "A singleton section's banner title does not match its canonical fixed value."

    # Prefix
    'MISSING_PREFIX_DECLARATION'        = "A section banner is missing the mandatory Prefix line in its description block."
    'MALFORMED_PREFIX_VALUE'            = "A section banner's Prefix line declares a value that is neither the registered page prefix nor '(none)'."
    'PREFIX_REGISTRY_MISMATCH'          = "An identifier-bearing section (CONSTANTS, VARIABLES, FUNCTIONS) declares a Prefix value that does not match the file's registered Component_Registry.cc_prefix. Identifier-free sections (CHANGELOG, IMPORTS, PARAMETERS, INITIALIZATION, EXECUTION, ROUTE, EXPORTS) legitimately declare '(none)' and are exempt from this check."
    'MISPLACED_NONE_PREFIX'             = "An identifier-bearing section (CONSTANTS, VARIABLES, FUNCTIONS) declares 'Prefix: (none)' in a file whose component has a registered (non-NULL) cc_prefix. The section's identifiers carry the file's registered prefix, so the banner must declare that prefix rather than '(none)'."
    'PREFIX_MISSING'                    = "A top-level identifier does not start with the file's registered prefix. Component_Registry declares a cc_prefix for the file but the identifier name does not match. Fires independently of banners; surfaces prefix non-conformance in pre-spec files."
    'PREFIX_MISMATCH'                   = "A top-level identifier name does not begin with the prefix declared in its containing section's banner followed by an underscore."

    # CHANGELOG
    'MALFORMED_CHANGELOG_ENTRY'         = "A CHANGELOG entry does not begin with '# YYYY-MM-DD ' (ISO date, two spaces, then description)."
    'MALFORMED_CHANGELOG_DATE'          = "A CHANGELOG entry's date is not in ISO YYYY-MM-DD format."
    'CHANGELOG_ORDER_VIOLATION'         = "CHANGELOG entries appear out of most-recent-first order."
    'FORBIDDEN_VERSION_IN_CHANGELOG'    = "A CHANGELOG entry contains a version literal. Versions are tracked in System_Metadata, not in CHANGELOG entries."

    # Function definitions
    'MISSING_DOCBLOCK'                  = "A function definition has no comment-based-help docblock in its required position. The docblock must appear as the third construct inside the function body, after [CmdletBinding()] and param(), before the body code."
    'MISPLACED_DOCBLOCK'                = "A function docblock is present but is not in the required position. The docblock must appear as the third construct inside the function body, after [CmdletBinding()] and param(), before the body code. Docblocks above the function declaration or after body code fire this drift."
    'MISSING_CMDLETBINDING'             = "A function definition is missing the [CmdletBinding()] attribute. Per spec, every function must declare CmdletBinding."
    'MISSING_PARAM_BLOCK'               = "A function is missing a param() block. Every function declares a param() block even if empty."
    'MISSING_SYNOPSIS'                  = "A function docblock is missing the .SYNOPSIS field."
    'MISSING_DESCRIPTION'               = "A function docblock is missing the .DESCRIPTION field."
    'FORBIDDEN_DOCBLOCK_KEYWORD'        = "A function docblock contains a forbidden keyword (.COMPONENT, .NOTES, .EXAMPLE, etc.). Function docblocks only allow .SYNOPSIS, .DESCRIPTION, and .PARAMETER blocks."
    'FORBIDDEN_DOCBLOCK_IN_STANDALONE'  = "A function in a standalone file has a comment-based-help docblock. Standalone functions use a single-line purpose comment instead."
    'MISSING_FUNCTION_PURPOSE_COMMENT'  = "A function in a standalone file has no single-line comment on the line directly above its declaration."
    'MALFORMED_FUNCTION_NAME'           = "A function name does not follow the Verb-Noun convention."
    'UNAPPROVED_VERB'                   = "A function uses a verb not in PowerShell's approved verb list (Get-Verb)."
    'FORBIDDEN_FUNCTION_IN_ROUTE'       = "A function is declared in a page-route file. Helpers belong in modules, not route files."
    'FORBIDDEN_FUNCTION_IN_API_ROUTE'   = "A function is declared in an api-route file. Helpers belong in modules, not route files."
    'FORBIDDEN_CONDITIONAL_DEFINITION'  = "A function is declared inside a conditional or loop block (if/else/while/do/for/foreach/switch/try/catch/finally). Functions must be defined unconditionally at top level."
    'FORBIDDEN_NESTED_FUNCTION'         = "A function is defined inside another function's body. Helper logic should be a separate top-level function."
    'FORBIDDEN_FILTER_FUNCTION'         = "A function is declared with the 'filter' keyword. The 'filter' keyword form is forbidden; use 'function' with an explicit process { ... } block for pipeline processing."
    'SHADOWS_SHARED_FUNCTION'           = "A non-shared file defines a function whose name matches a shared-library export. Such collisions shadow the shared function at runtime."
    'DUPLICATE_FUNCTION_DEFINITION'     = "The same function name is declared by more than one PS file across the codebase. Cross-file duplicates resolve unpredictably at runtime."
    'ORPHAN_FUNCTION_CALL'              = "A function call references a name not defined in any cataloged PS file. External-module calls that don't import the source module are common causes."

    # Parameters
    'MISSING_PARAMETER_DOC'             = "A function parameter lacks a corresponding .PARAMETER tag in the docblock. Every parameter must be documented."
    'EXTRA_PARAMETER_DOC'               = "The docblock contains a .PARAMETER tag for a parameter the function does not define."

    # Variables and constants
    'FORBIDDEN_SCOPE_QUALIFIER'         = "A top-level declaration uses '`$Script:' (capital S) or another non-'`$script:' scope qualifier. Only '`$script:' (lowercase) is permitted."
    'FORBIDDEN_GLOBAL_VARIABLE'         = "A declaration uses the '`$global:' scope qualifier. '`$global:' is forbidden anywhere in the file."
    'FORBIDDEN_ENV_ASSIGNMENT'          = "A `$env: write targets an environment variable not on the permitted list. Only the variables in `$AuthorizedEnvVars may be written at file scope."
    'FORBIDDEN_AUTOVAR_REASSIGNMENT'    = "Assignment to a PowerShell automatic variable (`$args, `$_, `$matches, `$input, `$PSScriptRoot, etc.) is forbidden."
    'FORBIDDEN_MULTI_DECLARATION'       = "Chained variable assignment in a single statement (`$a = `$b = `$c = 0). Each declaration gets its own statement."
    'MISSING_CONSTANT_COMMENT'          = "A constant declaration is not preceded by a single-line purpose comment."
    'MISSING_VARIABLE_COMMENT'          = "A variable declaration is not preceded by a single-line purpose comment."
    'MISSING_PURPOSE_COMMENT'           = "A constant or variable declaration is not preceded by a single-line purpose comment. (Legacy code; new emissions should use MISSING_CONSTANT_COMMENT or MISSING_VARIABLE_COMMENT.)"
    'MISPLACED_DECLARATION'             = "A '`$script:' declaration appears outside a CONSTANTS or VARIABLES section."
    'WRONG_DECLARATION_SECTION'         = "An assignment statement appears in a section type that disallows it (e.g., a constant in a VARIABLES section)."

    # Imports
    'MISPLACED_IMPORT'                  = "An import statement (dot-source or Import-Module) appears outside the IMPORTS section."

    # Routes
    'ROUTE_OUTSIDE_ROUTE_SECTION'       = "An Add-PodeRoute call appears outside a ROUTE section."
    'MIDDLEWARE_OUTSIDE_INIT_SECTION'   = "An Add-PodeMiddleware call appears outside an INITIALIZATION section."
    'MISSING_AUTHENTICATION'            = "An Add-PodeRoute call lacks -Authentication 'ADLogin'."
    'MISSING_RBAC_CHECK_PAGE'           = "A page route scriptblock does not call Get-UserAccess as the first statement."
    'MISSING_RBAC_CHECK_API'            = "An API route scriptblock does not call Test-ActionEndpoint anywhere in the scriptblock."
    'MISSING_RESPONSE_WRITE_PAGE'       = "A page route scriptblock does not end with Write-PodeHtmlResponse."
    'MISSING_RESPONSE_WRITE_API'        = "An API route scriptblock does not end with Write-PodeJsonResponse."

    # SQL
    'FORBIDDEN_INLINE_SQL_LITERAL'      = "Multi-line SQL is embedded as a single-line string literal instead of a here-string. Use @`"...`"@ for multi-line SQL."
    'MISSING_TRUST_SERVER_CERTIFICATE'  = "An Invoke-Sqlcmd call is missing the -TrustServerCertificate parameter. All AG-listener and instance connections in this environment require it."
    'MISSING_APPLICATION_NAME'          = "An Invoke-Sqlcmd call is missing the -ApplicationName parameter. Collectors must identify themselves in DMV attribution."
    'MISSING_PARAMETER_DECLARATION'     = "A query references @parameter placeholders but lacks a -Parameters @{...} hashtable. Parameterize SQL rather than constructing it via string concatenation."
    'FORBIDDEN_LINKED_SERVER'           = "A query references a linked server (four-part name). PowerShell collectors must hit each instance directly with separate Invoke-Sqlcmd calls."

    # Comments
    'FORBIDDEN_INLINE_BANNER'           = "A '# ---' mini-banner appears in the file. Section banners are the only permitted divider form."
    'FORBIDDEN_BOX_DRAWING_BANNER'      = "A '# --' box-drawing banner appears in the file (Unicode line-drawing characters). Section banners are the only permitted divider form."
    'FORBIDDEN_REMOVED_CODE_COMMENT'    = "A comment indicates removed or deleted code (e.g., '# Removed:', '# Was:', '# Deleted:'). Removed code should be deleted entirely; the git history preserves it if needed."
    'MALFORMED_SUBSECTION_MARKER'       = "A comment uses the sub-section marker shape but violates the rules: wrong dash count, missing label, inside a '#' comment run, or missing the required blank line before or after the marker."
    'FORBIDDEN_FREESTANDING_COMMENT_BLOCK' = "A free-standing block comment exists that does not match any of the allowed kinds (file header, section banner, docblock)."
    'FORBIDDEN_TRAILING_COMMENT'        = "A '#' comment appears at the end of a code line. Comments must lead the line they describe, not trail on it."

    # Module exports
    'FORBIDDEN_WILDCARD_EXPORT'         = "Export-ModuleMember -Function * (wildcard) is used. Exports must be enumerated explicitly."
    'EXPORTED_FUNCTION_NOT_DEFINED'     = "Export-ModuleMember references a function not defined in the file."
    'DEFINED_FUNCTION_NOT_EXPORTED'     = "A function declared in a module file is not exported via Export-ModuleMember."
    'MISSING_EXPORTS_SECTION'           = "A module file lacks an EXPORTS section."

    # Logging
    'FORBIDDEN_WRITE_HOST'              = "A Write-Host call appears in a standalone or shared-library file. Use Write-Log instead. The Start-xFACtsOrchestrator.ps1 entry-point script is exempt."

    # Registration
    'FILE_NOT_REGISTERED'               = "The file has no active row in Object_Registry, so its zone and scope could not be determined. Every scanned file must be registered; add it to dbo.Object_Registry. Rows from this file carry zone and scope of '<undefined>'."

    # Whitespace
    'EXCESS_BLANK_LINES'                = "More than one blank line appears between top-level constructs."
    'TRAILING_WHITESPACE'               = "A line ends with trailing whitespace."
}

<# ============================================================================
   VARIABLES: SCRIPT-SCOPE STATE
   ----------------------------------------------------------------------------
   Mutable script-scope state populated during execution: row collection,
   dedupe tracking, shared-definition maps, and per-file walk context.
   Prefix: (none)
   ============================================================================ #>

# Row collection list, built up across the walk and written at the end.
$script:rows       = New-Object System.Collections.Generic.List[object]
# Dedupe tracker keyed per row, referenced by Test-AddDedupeKey and Add-DriftCode.
$script:dedupeKeys = New-Object 'System.Collections.Generic.HashSet[string]'

# Per-file PS_FILE anchor row references. Post-walk code attaches file-overall
# drift codes to each file's anchor row through this map.
$script:psFileRowByFile = @{}

# Shared-scope function names per zone. Keyed by zone (cc, docs, standalone);
# each value is a HashSet of function names defined in SHARED-scope files in
# that zone. Resolution is strictly within-zone: a call resolves SHARED only
# against shared functions in the caller's own zone.
$script:sharedFunctionsByZone  = @{}
# Map of zone -> @{ function name -> defining source file } for SHARED-scope
# functions. Parallel to $sharedFunctionsByZone; supplies source_file on a
# within-zone SHARED resolution and the shadow-source file name.
$script:sharedSourceFileByZone = @{}

# Per-file context populated by the per-file walk loop. Each emitter reads
# from these to apply file-scoped attribution to the rows it creates.
# Filename only (no path) for the file being walked.
$script:CurrentFile               = $null
# Absolute path, for diagnostics.
$script:CurrentFileFullPath       = $null
# Role: page-route, api-route, module, standalone, or shared-library.
$script:CurrentFileRole           = $null
# Resolution zone for the current file, read from Object_Registry (cc, docs,
# standalone, exempt, or '<undefined>' when the file is not registered).
$script:CurrentFileZone           = $null
# Resolution scope for the current file, read from Object_Registry (LOCAL,
# SHARED, exempt, or '<undefined>' when the file is not registered). Stamped
# on every row the file produces.
$script:CurrentFileScope          = $null
# Documentation tier for the current file, read from Object_Registry (PLATFORM,
# SCOPED, or $null). PLATFORM selects full comment-based-help docblock treatment
# (spec 8.3); SCOPED and unset select the light single-line purpose comment
# treatment (spec 8.4).
$script:CurrentFileScopeTier      = $null
# Shorthand for a shared-library or module file.
$script:CurrentFileIsShared       = $false
# Raw text of the file.
$script:CurrentFileSource         = $null
# ScriptBlockAst returned by the parser.
$script:CurrentAst                = $null
# Token array from the parser.
$script:CurrentTokens             = $null
# Non-fatal parse errors; partial AST is still usable.
$script:CurrentParseErrors        = $null
# Line count of the current file.
$script:CurrentFileLineCount      = 0
# Output of New-SectionList.
$script:CurrentSections           = $null
# PS comment tokens in normalized shape.
$script:CurrentNormalizedComments = $null
# Preceding-comment lookup for docblocks and purpose comments.
$script:CurrentCommentIndex       = $null
# HashSet of function names defined in this file.
$script:CurrentLocalFunctions     = $null
# Function line ranges for scope attribution.
$script:CurrentFunctionRanges     = $null
# cc_prefix from Component_Registry for this file, or null.
$script:CurrentRegistryPrefix     = $null
# Whether the file has an Object/Component_Registry entry.
$script:CurrentRegistryHasMapping = $false
# Role-specific valid section types.
$script:CurrentValidSectionTypes  = $null
# Whether the role requires .COMPONENT in the header.
$script:CurrentRequiresComponent  = $false

# Cached PowerShell approved verb list, populated lazily on first function-name
# validation. Used by the MALFORMED_FUNCTION_NAME / UNAPPROVED_VERB checks.
$script:ApprovedVerbs             = $null

<# ============================================================================
   FUNCTIONS: FILE ROLE DETECTION
   ----------------------------------------------------------------------------
   Path-based classification of each .ps1/.psm1 file into one of the five
   recognized roles.
   Prefix: (none)
   ============================================================================ #>

# Classify a .ps1 or .psm1 file into one of five roles. Path-based:
# *.psm1 anywhere                                          -> 'module'
# *.psd1 anywhere                                          -> 'data-file' (basic inventory only)
# ...\scripts\routes\<Name>\<Name>-API.ps1                 -> 'api-route'
# ...\scripts\routes\<Name>\<Name>.ps1                     -> 'page-route'
# ...\xFACts-PowerShell\xFACts-<Name>.ps1                  -> 'shared-library' (if in $SharedLibraryFiles)
# any .ps1 in $StandalonePathExceptions                    -> 'standalone' (e.g. Start-ControlCenter.ps1)
# any other .ps1 under xFACts-PowerShell\                  -> 'standalone'
# Returns the role string. Throws if the path doesn't match any known shape;
# the caller decides whether to skip or error.
function Get-PSFileRole {
    param([Parameter(Mandatory)][string]$FullPath)

    $fileName = [System.IO.Path]::GetFileName($FullPath)

    # Modules: extension wins regardless of location
    if ($fileName -match '\.psm1$') { return 'module' }

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

<# ============================================================================
   FUNCTIONS: PS PARSER AND COMMENT NORMALIZATION
   ----------------------------------------------------------------------------
   Native AST parsing and conversion of PowerShell comment tokens into the
   normalized shape the rest of the populator consumes.
   Prefix: (none)
   ============================================================================ #>

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
# .Type      - 'Block' for <# #> comments and comment-based-help blocks
# 'Line'  for # single-line comments
# .Text      - inner text with delimiters stripped
# .LineStart - 1-based start line from .Extent
# .LineEnd   - 1-based end line from .Extent
# .ColumnStart - 1-based start column
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
        # PowerShell block: <# ... #> (may span multiple lines)
        # Line comment: # ... (single line)
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

<# ============================================================================
   FUNCTIONS: FORMAT HELPERS
   ----------------------------------------------------------------------------
   Small text and signature formatting helpers.
   Prefix: (none)
   ============================================================================ #>

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

<# ============================================================================
   FUNCTIONS: SQL / GLOBALCONFIG / RBAC DETECTION
   ----------------------------------------------------------------------------
   Heuristics for recognizing SQL queries, GlobalConfig references, and
   function variant shapes within source text.
   Prefix: (none)
   ============================================================================ #>

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
# 1. SQL string with setting_name = 'xxx' (the SQL WHERE clause form)
# 2. Hardcoded string literals matching known GlobalConfig setting names
# (broadcasted via the permissive approach; will produce noise on first
# run)
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

<# ============================================================================
   FUNCTIONS: VARIANT SHAPE HELPERS
   ----------------------------------------------------------------------------
   Helpers that classify function variants and extract exported names from
   the several AST shapes Export-ModuleMember arguments can take.
   Prefix: (none)
   ============================================================================ #>

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
# StringConstantExpressionAst      single name, returns [single]
# ExpandableStringExpressionAst    single name in double quotes, returns [single]
# ArrayLiteralAst                  comma-separated names, returns each element
# ParenExpressionAst               unwrap and recurse
# ArrayExpressionAst               the @(...) form -- unwrap SubExpression and recurse
# StatementBlockAst                unwrap and recurse into statements
# PipelineAst                      unwrap into the pipeline's first PipelineElement
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

<# ============================================================================
   FUNCTIONS: LOCAL DEFINITION COLLECTION
   ----------------------------------------------------------------------------
   Collection of top-level function names defined in a file, for same-file
   and cross-file resolution.
   Prefix: (none)
   ============================================================================ #>

# Walk the top-level statements of a parsed AST and collect the names of
# every top-level function defined. Used for:
# - Same-file USAGE resolution (PS_FUNCTION_CALL pointing at local funcs)
# - SHADOWS_SHARED_FUNCTION cross-file check
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

<# ============================================================================
   FUNCTIONS: COMMENT INDEX
   ----------------------------------------------------------------------------
   Per-file block-comment index and the preceding/positioned-comment lookups
   used by docblock and purpose-comment detection.
   Prefix: (none)
   ============================================================================ #>

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
#
# Used for the MISPLACED_DOCBLOCK detection path: when no docblock is
# found in the canonical inside-body position by Get-PSFunctionDocblock,
# this helper checks whether a block comment ABOVE the function declaration
# was the author's (incorrect) attempt at a docblock. If so, fire
# MISPLACED_DOCBLOCK rather than MISSING_DOCBLOCK so the catalog signals
# the difference between "no docblock at all" and "docblock in the wrong
# place."
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

# Find the docblock for a function and report its position. Per the
# canonical docblock position is INSIDE the function body, as the third
# construct after [CmdletBinding()] and param(), positioned before the
# first body statement. Returns an ordered hashtable:
# DocBlock - the matched block comment from CommentIndex, or $null
# Position - 'inside-body' (canonical), 'above-function' (the legacy
# location, fires MISPLACED_DOCBLOCK), 'misplaced' (block
# comment inside body but not in the canonical position),
# or 'missing' (no docblock anywhere associated with this
# function)
#
# Detection algorithm:
# 1. Compute the line range for the canonical position:
# - Start line: the line AFTER the param() block's closing ')' if
# present, otherwise the line of the function's opening '{'.
# - End line: the line of the first non-blank, non-comment
# statement in the function body (the body's "first real
# statement"). If the body is empty, end line is the line of
# the function's closing '}'.
# 2. Look for an unused block comment in CommentIndex whose StartLine
# falls within that range and whose EndLine is less than the first
# real statement's line. If found, position is 'inside-body'.
# 3. If nothing found inside the body in the canonical position, fall
# back to the legacy detector (Get-PrecedingPSBlockComment): a block
# comment ending 1-2 lines above the function declaration. If found,
# position is 'above-function'.
# 4. As a last fallback, scan the entire function body for ANY block
# comment; if found, position is 'misplaced'. (Catches cases where
# the docblock was placed after some body code.)
# 5. If nothing matches, position is 'missing'.
#
# In every case where a docblock is found, its .Used flag is set so the
# comment is not double-claimed by later passes.
function Get-PSFunctionDocblock {
    param(
        [Parameter(Mandatory)]$FunctionAst,
        [Parameter(Mandatory)]$CommentIndex
    )

    $result = [ordered]@{
        DocBlock = $null
        Position = 'missing'
    }

    if ($null -eq $CommentIndex -or $CommentIndex.Count -eq 0) {
        # Fall through to the legacy above-function check anyway so the
        # caller gets a consistent return shape.
        $result.Position = 'missing'
        return $result
    }

    # Compute the canonical window's start and end lines.
    $fnStartLine = Get-PSAstNodeLine -Node $FunctionAst
    $fnEndLine   = Get-PSAstNodeEndLine -Node $FunctionAst

    $paramBlock = $null
    if ($FunctionAst.Body -and $FunctionAst.Body.ParamBlock) {
        $paramBlock = $FunctionAst.Body.ParamBlock
    }

    $canonicalStart = if ($paramBlock) {
        (Get-PSAstNodeEndLine -Node $paramBlock) + 1
    } else {
        $fnStartLine + 1
    }

    # Find the first real statement in the function body. "Real" means an
    # AST statement node, not a comment (PowerShell comments live outside
    # the AST in CommentIndex). The body's EndBlock holds the
    # post-param-block statements; that's where the docblock's neighbors
    # are. If EndBlock is null or has no statements, the body is empty
    # and the canonical window runs to the function's closing brace.
    $firstStmtLine = $fnEndLine
    if ($FunctionAst.Body -and $FunctionAst.Body.EndBlock -and
        $FunctionAst.Body.EndBlock.Statements) {
        $stmts = $FunctionAst.Body.EndBlock.Statements
        if ($stmts.Count -gt 0) {
            $firstStmtLine = Get-PSAstNodeLine -Node $stmts[0]
        }
    }

    # Pass 1: look for the docblock in the canonical inside-body position.
    # The block comment must START at or after canonicalStart and END
    # strictly before firstStmtLine (so the comment ends before the first
    # real statement begins). Pick the latest-ending block comment if
    # multiple qualify.
    $insideBest = $null
    foreach ($c in $CommentIndex) {
        if ($c.Used) { continue }
        if ($c.Type -ne 'Block') { continue }
        if ($c.StartLine -ge $canonicalStart -and $c.EndLine -lt $firstStmtLine) {
            if ($null -eq $insideBest -or $c.EndLine -gt $insideBest.EndLine) {
                $insideBest = $c
            }
        }
    }
    if ($insideBest) {
        $insideBest.Used = $true
        $result.DocBlock = $insideBest
        $result.Position = 'inside-body'
        return $result
    }

    # Pass 2: legacy above-function position. Reuse the existing detector
    # for consistency with the previous behavior; it marks the comment as
    # Used.
    $above = Get-PrecedingPSBlockComment -CommentIndex $CommentIndex -DefinitionLine $fnStartLine
    if ($above) {
        $result.DocBlock = $above
        $result.Position = 'above-function'
        return $result
    }

    # Pass 3: any block comment anywhere inside the function body. Catches
    # docblocks placed AFTER body code (rare but possible).
    $anyBodyBest = $null
    foreach ($c in $CommentIndex) {
        if ($c.Used) { continue }
        if ($c.Type -ne 'Block') { continue }
        if ($c.StartLine -ge $fnStartLine -and $c.EndLine -le $fnEndLine) {
            if ($null -eq $anyBodyBest -or $c.StartLine -lt $anyBodyBest.StartLine) {
                $anyBodyBest = $c
            }
        }
    }
    if ($anyBodyBest) {
        $anyBodyBest.Used = $true
        $result.DocBlock = $anyBodyBest
        $result.Position = 'misplaced'
        return $result
    }

    return $result
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

<# ============================================================================
   FUNCTIONS: ROW EMITTERS
   ----------------------------------------------------------------------------
   One emitter per catalog row type. Each builds a row, applies per-construct
   drift codes, and adds it to the row collection.
   Prefix: (none)
   ============================================================================ #>

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
        -Zone               $script:CurrentFileZone `
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

    $scope = $script:CurrentFileScope
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
    $scope = $script:CurrentFileScope
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
    $scope         = $script:CurrentFileScope

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

    # MALFORMED_SINGLETON_NAME: singleton section banner must use the
    # canonical NAME from . ROUTE has role-conditional valid names.
    if ($Section.TypeName -and $Section.BannerName -and
        $SingletonSectionTypes -contains $Section.TypeName -and
        $SingletonSectionCanonicalNames.ContainsKey($Section.TypeName)) {
        $validNames = $SingletonSectionCanonicalNames[$Section.TypeName]
        if ($Section.BannerName -cnotin $validNames) {
            # For ROUTE, refine the message based on the file role.
            $expectedDisplay = if ($Section.TypeName -eq 'ROUTE') {
                if ($script:CurrentFileRole -eq 'api-route') { 'API ENDPOINTS' }
                elseif ($script:CurrentFileRole -eq 'page-route') { 'PAGE PATH' }
                else { ($validNames -join "' or '") }
            } else {
                $validNames[0]
            }
            Add-DriftCode -Row $row -Code 'MALFORMED_SINGLETON_NAME' `
                -Context "Singleton banner '$($Section.TypeName): $($Section.BannerName)' should use canonical NAME '$expectedDisplay'."
        }
    }

    if ($Section.Prefix -and -not (Test-PrefixValueIsValid -Prefix $Section.Prefix -AllowNoneSentinel)) {
        Add-DriftCode -Row $row -Code 'MALFORMED_PREFIX_VALUE' `
            -Context "Banner prefix '$($Section.Prefix)' is not one of the following: registered page prefix, 'cc' literal, or '(none)'."
    }

    # PREFIX_REGISTRY_MISMATCH / MISPLACED_NONE_PREFIX: registry-driven
    # validation, scoped by section-type classification.
    #
    # The section-type classification splits banner content into two
    # categories:
    #
    # - Identifier-bearing sections (CONSTANTS, VARIABLES, FUNCTIONS)
    # declare PowerShell identifiers that the platform prefix discipline
    # governs. Their Prefix value must match the file's registered
    # cc_prefix. '(none)' on these sections in a registered-prefix file
    # fires MISPLACED_NONE_PREFIX. A non-matching prefix fires
    # PREFIX_REGISTRY_MISMATCH.
    #
    # - Identifier-free sections (CHANGELOG, IMPORTS, PARAMETERS,
    # INITIALIZATION, EXECUTION, ROUTE, EXPORTS) declare '(none)'
    # regardless of the file's registered cc_prefix. Their banner
    # contents are not prefix-bearing identifiers, so the registry
    # check is skipped. A non-(none) Prefix value on these sections
    # would still pass MALFORMED_PREFIX_VALUE (above) since 'bkp' and
    # 'cc' are syntactically valid; we don't fire a separate code for
    # a mismatch since the spec position is that (none) is the
    # canonical declaration on these sections.
    if ($script:CurrentRegistryHasMapping -and $Section.Prefix -and
        (Test-PrefixValueIsValid -Prefix $Section.Prefix -AllowNoneSentinel)) {

        $bannerVal = Get-BannerPrefixValue -Prefix $Section.Prefix
        $isNone    = Test-IsPrefixNone -Prefix $Section.Prefix
        $regVal    = $script:CurrentRegistryPrefix
        $isIdentifierBearing = ($IdentifierBearingSectionTypes -contains $Section.TypeName)

        if ($isIdentifierBearing) {
            # Identifier-bearing section validation.
            if ($null -eq $regVal) {
                # File has no registered cc_prefix; (none) is the legitimate
                # declaration. Non-(none) fires registry mismatch.
                if (-not $isNone) {
                    Add-DriftCode -Row $row -Code 'PREFIX_REGISTRY_MISMATCH' `
                        -Context "Banner declares Prefix '$bannerVal' but Component_Registry has no cc_prefix registered for this file. Identifier-bearing sections in unregistered files declare '(none)'."
                }
            } else {
                # File has a registered cc_prefix. (none) on an
                # identifier-bearing section is the misplaced-(none) case;
                # any non-matching prefix value is a registry mismatch.
                if ($isNone) {
                    Add-DriftCode -Row $row -Code 'MISPLACED_NONE_PREFIX' `
                        -Context "Section '$($Section.TypeName): $($Section.BannerName)' declares Prefix '(none)' but Component_Registry has cc_prefix = '$regVal' for this file. Identifier-bearing sections must declare the file's registered prefix."
                }
                elseif ($bannerVal -ne $regVal) {
                    Add-DriftCode -Row $row -Code 'PREFIX_REGISTRY_MISMATCH' `
                        -Context "Section '$($Section.TypeName): $($Section.BannerName)' declares Prefix '$bannerVal' but Component_Registry has cc_prefix = '$regVal' for this file."
                }
            }
        }
        # Identifier-free sections: no registry check. (none) is canonical
        # regardless of the file's registered cc_prefix, and a non-(none)
        # value on these sections is tolerated (the platform prefix
        # discipline does not govern these sections' content).
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

    $scope = $script:CurrentFileScope

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

    # CHANGELOG entry validation
    # # - Each entry begins with `# YYYY-MM-DD <description>` (ISO date, two spaces).
    # - Entries are ordered most-recent-first.
    # - No version numbers in entries.
    if ($null -ne $changelogText) {
        $entryLines = $changelogText -split "`n"
        $entryDates = New-Object System.Collections.Generic.List[datetime]
        $entryLineNums = New-Object System.Collections.Generic.List[int]
        for ($li = 0; $li -lt $entryLines.Count; $li++) {
            $ln = $entryLines[$li]
            $absLine = $Section.BodyStartLine + $li
            if ($ln -notmatch '^\s*#') { continue }
            $stripped = $ln -replace '^\s*#\s*', ''
            # Entries start with YYYY-MM-DD followed by two spaces.
            # Continuation lines have leading whitespace and are not validated here.
            if ([string]::IsNullOrWhiteSpace($stripped)) { continue }
            if ($stripped -notmatch '^\d') {
                # Non-date-starting content line. Could be continuation (allowed)
                # or malformed (we conservatively skip continuation patterns).
                continue
            }

            # First-position character is a digit  -  this should be a date-led entry.
            if ($stripped -match '^(\d{4}-\d{2}-\d{2})\s\s(\S.*)$') {
                $dateText = $matches[1]
                try {
                    $parsed = [datetime]::ParseExact($dateText, 'yyyy-MM-dd', $null)
                    $entryDates.Add($parsed)
                    $entryLineNums.Add($absLine)
                } catch {
                    Add-DriftCode -Row $row -Code 'MALFORMED_CHANGELOG_DATE' `
                        -Context "Line ${absLine}: date '$dateText' is not a valid ISO YYYY-MM-DD value."
                }
            }
            else {
                Add-DriftCode -Row $row -Code 'MALFORMED_CHANGELOG_ENTRY' `
                    -Context "Line ${absLine}: entry does not begin with '# YYYY-MM-DD <description>'."
            }

            # FORBIDDEN_VERSION_IN_CHANGELOG: version literal in the entry text.
            # Patterns like '1.2.3', 'v1.2', 'Version 2.0'.
            if ($stripped -match '\b(v?\d+\.\d+(\.\d+)?)\b' -or
                $stripped -match '(?i)\bversion\s+\d+\.\d+\b') {
                Add-DriftCode -Row $row -Code 'FORBIDDEN_VERSION_IN_CHANGELOG' `
                    -Context "Line ${absLine}: entry contains a version literal."
            }
        }

        # CHANGELOG_ORDER_VIOLATION: dates must be most-recent-first.
        for ($i = 1; $i -lt $entryDates.Count; $i++) {
            if ($entryDates[$i] -gt $entryDates[$i - 1]) {
                Add-DriftCode -Row $row -Code 'CHANGELOG_ORDER_VIOLATION' `
                    -Context "Line $($entryLineNums[$i]): entry date $($entryDates[$i].ToString('yyyy-MM-dd')) is newer than the prior entry. Most-recent-first ordering required."
                break
            }
        }
    }

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

    $scope = $script:CurrentFileScope
    $key = "$($script:CurrentFile)|$line|$col|$($shape.ComponentType)|$fnName|DEFINITION|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    # Locate the function's docblock and report its position. Canonical
    # position is inside the function body, after [CmdletBinding()]
    # and param(), before the first body statement. Anything else fires
    # MISPLACED_DOCBLOCK if a docblock was found in some other location, or
    # MISSING_DOCBLOCK if no docblock was found at all.
    $docInfo      = Get-PSFunctionDocblock -FunctionAst $FunctionAst -CommentIndex $script:CurrentCommentIndex
    $docBlock     = $docInfo.DocBlock
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

    # Documentation rules are determined by scope_tier (spec 8.3 / 8.4).
    # PLATFORM-tier files (broadly-consumed shared infrastructure) carry a
    # comment-based-help docblock in the canonical position (after
    # [CmdletBinding()] and param()) and declare [CmdletBinding()]. SCOPED-tier
    # files and standalone scripts (scope_tier unset) instead carry a single-line
    # purpose comment above the declaration and do not use a docblock;
    # [CmdletBinding()] is permitted but not required.
    if ($script:CurrentFileScopeTier -eq 'PLATFORM') {
        # PLATFORM: docblock mandatory in the canonical position.
        if ($docInfo.Position -eq 'above-function') {
            Add-DriftCode -Row $row -Code 'MISPLACED_DOCBLOCK' `
                -Context "Function '$fnName' has a docblock above the function declaration; the docblock must appear inside the function body after [CmdletBinding()] and param()."
        }
        elseif ($docInfo.Position -eq 'misplaced') {
            Add-DriftCode -Row $row -Code 'MISPLACED_DOCBLOCK' `
                -Context "Function '$fnName' has a docblock inside the body but not in the canonical position immediately after [CmdletBinding()] and param()."
        }
        elseif ($docInfo.Position -eq 'missing') {
            Add-DriftCode -Row $row -Code 'MISSING_DOCBLOCK' `
                -Context "Function '$fnName' has no comment-based-help docblock."
        }

        if (-not (Test-HasCmdletBinding -FunctionAst $FunctionAst)) {
            Add-DriftCode -Row $row -Code 'MISSING_CMDLETBINDING' `
                -Context "Function '$fnName' is missing the [CmdletBinding()] attribute."
        }
    }
    else {
        # SCOPED-tier and standalone: a docblock is not used.
        if ($docInfo.Position -ne 'missing') {
            Add-DriftCode -Row $row -Code 'FORBIDDEN_DOCBLOCK_IN_STANDALONE' `
                -Context "Function '$fnName' has a comment-based-help docblock; SCOPED-tier and standalone functions use a single-line purpose comment instead."
        }
        # A single-line purpose comment is required directly above the declaration.
        $fnPurpose = Get-PrecedingPSLineComment -CommentIndex $script:CurrentCommentIndex -DefinitionLine $line
        if ($null -eq $fnPurpose) {
            Add-DriftCode -Row $row -Code 'MISSING_FUNCTION_PURPOSE_COMMENT' `
                -Context "Function '$fnName' has no single-line purpose comment on the line directly above its declaration."
        }
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

    # FORBIDDEN_NESTED_FUNCTION: walk parents for another FunctionDefinitionAst
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
        Add-DriftCode -Row $row -Code 'FORBIDDEN_NESTED_FUNCTION' `
            -Context "Function '$fnName' is nested inside another function."
    }

    # FORBIDDEN_FILTER_FUNCTION: filter keyword form is forbidden
    if ($FunctionAst.IsFilter) {
        Add-DriftCode -Row $row -Code 'FORBIDDEN_FILTER_FUNCTION' `
            -Context "Function '$fnName' is declared with the 'filter' keyword. Use 'function' with explicit process { ... } instead."
    }

    # FORBIDDEN_FUNCTION_IN_ROUTE / FORBIDDEN_FUNCTION_IN_API_ROUTE:
    # Function declarations are forbidden in page-route and api-route files.
    if ($script:CurrentFileRole -eq 'page-route') {
        Add-DriftCode -Row $row -Code 'FORBIDDEN_FUNCTION_IN_ROUTE' `
            -Context "Function '$fnName' declared in a page-route file. Helpers belong in modules."
    }
    elseif ($script:CurrentFileRole -eq 'api-route') {
        Add-DriftCode -Row $row -Code 'FORBIDDEN_FUNCTION_IN_API_ROUTE' `
            -Context "Function '$fnName' declared in an api-route file. Helpers belong in modules."
    }

    # MISSING_PARAM_BLOCK: Every function declares a param() block, even if empty.
    # The AST exposes this as ParamBlock on either Body.ParamBlock (typical) or
    # the function's own ParamBlock property (rare alternative form).
    $hasParamBlock = ($null -ne $FunctionAst.Body -and $null -ne $FunctionAst.Body.ParamBlock) -or
                     ($null -ne $FunctionAst.Parameters)
    if (-not $hasParamBlock) {
        Add-DriftCode -Row $row -Code 'MISSING_PARAM_BLOCK' `
            -Context "Function '$fnName' is missing a param() block. All functions declare param() even if empty."
    }

    # MALFORMED_FUNCTION_NAME / UNAPPROVED_VERB:
    # Function names follow Verb-Noun. The verb must be in PowerShell's approved list.
    # Underscore prefix or non-letter start is forbidden. PowerShell verbs are
    # accessible via Get-Verb; we cache the list on first use.
    if ($fnName -match '^[^A-Za-z]' -or $fnName -match '^_') {
        Add-DriftCode -Row $row -Code 'MALFORMED_FUNCTION_NAME' `
            -Context "Function name '$fnName' starts with a non-letter character. Names must follow Verb-Noun."
    }
    elseif ($fnName -notmatch '^[A-Z][a-zA-Z]*-[A-Za-z]') {
        Add-DriftCode -Row $row -Code 'MALFORMED_FUNCTION_NAME' `
            -Context "Function name '$fnName' does not follow Verb-Noun (PascalCase Verb, hyphen, then noun)."
    }
    else {
        # Extract the verb (text before the first hyphen) and validate against approved list.
        $verb = $fnName -replace '^([A-Z][a-zA-Z]*)-.*$', '$1'
        if ($null -eq $script:ApprovedVerbs) {
            $script:ApprovedVerbs = @(Get-Verb | Select-Object -ExpandProperty Verb)
        }
        if ($verb -notin $script:ApprovedVerbs) {
            Add-DriftCode -Row $row -Code 'UNAPPROVED_VERB' `
                -Context "Function '$fnName' uses verb '$verb' which is not in the PowerShell approved verb list."
        }
    }

    # Docblock content validation
    # docblock must include .SYNOPSIS and .DESCRIPTION. .PARAMETER
    # blocks correspond 1:1 with declared parameters and appear in param() order.
    # Forbidden keywords: .COMPONENT, .NOTES, .EXAMPLE, .INPUTS, .OUTPUTS,
    # .LINK, .ROLE, .FUNCTIONALITY, .FORWARDHELPTARGETNAME,
    # .REMOTEHELPRUNSPACE, .EXTERNALHELP. Only PLATFORM-tier files use docblocks,
    # so docblock-content validation applies only to them; a docblock in a
    # SCOPED-tier or standalone file is flagged by FORBIDDEN_DOCBLOCK_IN_STANDALONE
    # alone, not subjected to content rules it is not meant to satisfy.
    if ($null -ne $docBlockText -and $script:CurrentFileScopeTier -eq 'PLATFORM') {
        # MISSING_SYNOPSIS / MISSING_DESCRIPTION
        $hasSynopsis    = $docBlockText -match '(?ms)^\s*\.SYNOPSIS\b'
        $hasDescription = $docBlockText -match '(?ms)^\s*\.DESCRIPTION\b'
        if (-not $hasSynopsis) {
            Add-DriftCode -Row $row -Code 'MISSING_SYNOPSIS' `
                -Context "Function '$fnName' docblock is missing the .SYNOPSIS field."
        }
        if (-not $hasDescription) {
            Add-DriftCode -Row $row -Code 'MISSING_DESCRIPTION' `
                -Context "Function '$fnName' docblock is missing the .DESCRIPTION field."
        }

        # FORBIDDEN_DOCBLOCK_KEYWORD
        $forbiddenDocKeywords = @(
            '.COMPONENT', '.NOTES', '.EXAMPLE', '.INPUTS', '.OUTPUTS',
            '.LINK', '.ROLE', '.FUNCTIONALITY', '.FORWARDHELPTARGETNAME',
            '.REMOTEHELPRUNSPACE', '.EXTERNALHELP'
        )
        $foundForbidden = New-Object System.Collections.Generic.List[string]
        foreach ($kw in $forbiddenDocKeywords) {
            $escapedKw = [regex]::Escape($kw)
            if ($docBlockText -match "(?ms)^\s*$escapedKw\b") {
                $foundForbidden.Add($kw)
            }
        }
        if ($foundForbidden.Count -gt 0) {
            Add-DriftCode -Row $row -Code 'FORBIDDEN_DOCBLOCK_KEYWORD' `
                -Context "Function '$fnName' docblock contains forbidden keyword(s): $($foundForbidden -join ', ')."
        }

        # Parameter cross-validation
        # Collect declared param names from AST and .PARAMETER blocks from docblock.
        $declaredParams = @()
        if ($null -ne $FunctionAst.Body -and $null -ne $FunctionAst.Body.ParamBlock) {
            $declaredParams = @($FunctionAst.Body.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        }
        $docParams = @()
        $docParamMatches = [regex]::Matches($docBlockText, '(?ms)^\s*\.PARAMETER\s+(\w+)\b')
        foreach ($m in $docParamMatches) { $docParams += $m.Groups[1].Value }

        # MISSING_PARAMETER_DOC: declared but not documented
        foreach ($p in $declaredParams) {
            if ($p -notin $docParams) {
                Add-DriftCode -Row $row -Code 'MISSING_PARAMETER_DOC' `
                    -Context "Function '$fnName' parameter '$p' has no matching .PARAMETER block."
            }
        }
        # EXTRA_PARAMETER_DOC: documented but not declared
        foreach ($dp in $docParams) {
            if ($dp -notin $declaredParams) {
                Add-DriftCode -Row $row -Code 'EXTRA_PARAMETER_DOC' `
                    -Context "Function '$fnName' docblock has .PARAMETER '$dp' but no matching parameter is declared."
            }
        }
        # PARAMETER_DOC_ORDER_VIOLATION: 1:1 match but order differs
        if ($declaredParams.Count -gt 0 -and $docParams.Count -gt 0 -and
            $declaredParams.Count -eq $docParams.Count) {
            $sameSet = (@($declaredParams | Sort-Object) -join '|') -eq (@($docParams | Sort-Object) -join '|')
            $sameOrder = ($declaredParams -join '|') -eq ($docParams -join '|')
            if ($sameSet -and -not $sameOrder) {
                Add-DriftCode -Row $row -Code 'PARAMETER_DOC_ORDER_VIOLATION' `
                    -Context "Function '$fnName' .PARAMETER blocks are not in the same order as the param() block."
            }
        }
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

    $scope = $script:CurrentFileScope

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

    $scope = $script:CurrentFileScope

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

    $scope = $script:CurrentFileScope
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
        # In a standalone file, an assignment inside the EXECUTION section performs
        # work as the script runs; it is part of execution, not a file-scope
        # declaration, so it does not fire the CONSTANTS/VARIABLES placement drift.
        $isStandaloneExecution = ($script:CurrentFileRole -eq 'standalone' -and $sectionType -eq 'EXECUTION')
        if (-not $isStandaloneExecution) {
            Add-DriftCode -Row $row -Code 'WRONG_DECLARATION_SECTION' `
                -Context "Top-level assignment `$$varName appears in a $sectionType section; spec requires CONSTANTS or VARIABLES."
            # Also flag as MISPLACED_DECLARATION (spec-named code; sibling to WRONG_DECLARATION_SECTION)
            Add-DriftCode -Row $row -Code 'MISPLACED_DECLARATION' `
                -Context "`$script: declaration appears outside a CONSTANTS or VARIABLES section."
        }
    }

    # Purpose comment (granular: CONSTANT/VARIABLE specific). A standalone
    # EXECUTION-section assignment is an execution statement, not a declaration
    # (per the section 9.3 carve-out above), so the declaration purpose-comment
    # requirement does not apply to it.
    $isStandaloneExecution = ($script:CurrentFileRole -eq 'standalone' -and $sectionType -eq 'EXECUTION')
    if ($null -eq $purposeComment -and -not $isStandaloneExecution) {
        # Emit the granular code matching the section type, plus retain
        # MISSING_PURPOSE_COMMENT for legacy compatibility / catch-all.
        Add-DriftCode -Row $row -Code 'MISSING_PURPOSE_COMMENT' `
            -Context "`$$varName has no preceding purpose comment."
        if ($componentType -eq 'PS_CONSTANT') {
            Add-DriftCode -Row $row -Code 'MISSING_CONSTANT_COMMENT' `
                -Context "Constant `$$varName has no preceding purpose comment."
        }
        elseif ($componentType -eq 'PS_VARIABLE') {
            Add-DriftCode -Row $row -Code 'MISSING_VARIABLE_COMMENT' `
                -Context "Variable `$$varName has no preceding purpose comment."
        }
    }

    # Scope qualifier validation
    # only $script: (lowercase) is permitted at file scope.
    # $Script: (capital S), $global:, and other qualifiers are drift.
    # Walk the left-side AST text to find the literal qualifier as written.
    $leftText = if ($left.Extent) { $left.Extent.Text } else { '' }
    if ($leftText -match '^\$([A-Za-z]+):') {
        $qualifier = $matches[1]
        if ($qualifier -ceq 'Script') {
            Add-DriftCode -Row $row -Code 'FORBIDDEN_SCOPE_QUALIFIER' `
                -Context "Declaration uses `$Script: (capital S). Only `$script: (lowercase) is permitted."
        }
        elseif ($qualifier -ceq 'global') {
            Add-DriftCode -Row $row -Code 'FORBIDDEN_GLOBAL_VARIABLE' `
                -Context "Declaration uses `$global: scope. `$global: is forbidden anywhere in the file."
        }
        elseif ($qualifier -eq 'env') {
            # The $env: provider is permitted only for authorized environment
            # variables. $varName carries the full provider path (e.g.
            # 'env:NODE_PATH'); strip the 'env:' prefix to get the bare name.
            $envVarName = $varName -replace '^env:', ''
            if ($AuthorizedEnvVars -notcontains $envVarName) {
                Add-DriftCode -Row $row -Code 'FORBIDDEN_ENV_ASSIGNMENT' `
                    -Context "`$env:$envVarName is not on the authorized list. Only $($AuthorizedEnvVars -join ', ') may be written at file scope."
            }
        }
        elseif ($qualifier -ne 'script' -and $qualifier -ne 'private' -and $qualifier -ne 'local') {
            Add-DriftCode -Row $row -Code 'FORBIDDEN_SCOPE_QUALIFIER' `
                -Context "Declaration uses `$${qualifier}: scope. Only `$script: is permitted at file scope."
        }
    }

    # Automatic variable assignment
    # assignment to PowerShell automatic variables is forbidden.
    $automaticVars = @(
        'args', '_', 'matches', 'input', 'PSScriptRoot', 'PSCommandPath',
        'MyInvocation', 'PSBoundParameters', 'Error', 'Host', 'HOME',
        'PID', 'PROFILE', 'PSCulture', 'PSUICulture', 'PSVersionTable',
        'ShellId', 'StackTrace', 'this', 'true', 'false', 'null',
        'ExecutionContext', 'foreach', 'switch', 'OFS', 'PSCmdlet'
    )
    if ($varName -in $automaticVars) {
        Add-DriftCode -Row $row -Code 'FORBIDDEN_AUTOVAR_REASSIGNMENT' `
            -Context "Assignment to PowerShell automatic variable `$$varName is forbidden."
    }

    # Multi-declaration / chained assignment
    # chained assignments ($a = $b = $c = 0) are forbidden.
    # An AssignmentStatementAst whose Right is itself another AssignmentStatementAst
    # signals chained form.
    if ($null -ne $AssignmentAst.Right -and
        $AssignmentAst.Right -is [System.Management.Automation.Language.PipelineAst]) {
        $rightExpr = $AssignmentAst.Right.PipelineElements
        if ($rightExpr.Count -eq 1 -and
            $rightExpr[0] -is [System.Management.Automation.Language.CommandExpressionAst] -and
            $rightExpr[0].Expression -is [System.Management.Automation.Language.AssignmentStatementAst]) {
            Add-DriftCode -Row $row -Code 'FORBIDDEN_MULTI_DECLARATION' `
                -Context "Chained assignment detected. Each declaration must be its own statement."
        }
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

    $scope = $script:CurrentFileScope
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

    # Route argument and body validation
    # Requires:
    # - -Authentication 'ADLogin' on every Add-PodeRoute call
    # - page routes: Get-UserAccess as the first statement, end with Write-PodeHtmlResponse
    # - api routes: Test-ActionEndpoint somewhere in the scriptblock, end with Write-PodeJsonResponse

    # MISSING_AUTHENTICATION: walk command elements looking for -Authentication 'ADLogin'
    $hasAdLoginAuth = $false
    if ($null -ne $CommandAst.CommandElements) {
        for ($i = 0; $i -lt $CommandAst.CommandElements.Count - 1; $i++) {
            $elem = $CommandAst.CommandElements[$i]
            if ($elem -is [System.Management.Automation.Language.CommandParameterAst] -and
                $elem.ParameterName -eq 'Authentication') {
                $nextElem = $CommandAst.CommandElements[$i + 1]
                if ($null -ne $nextElem -and $nextElem.Extent) {
                    $authValue = $nextElem.Extent.Text -replace "^['""]|['""]$", ''
                    if ($authValue -eq 'ADLogin') { $hasAdLoginAuth = $true }
                }
                break
            }
        }
    }
    if (-not $hasAdLoginAuth) {
        Add-DriftCode -Row $row -Code 'MISSING_AUTHENTICATION' `
            -Context "Add-PodeRoute call lacks -Authentication 'ADLogin'."
    }

    # Locate the route scriptblock (the -ScriptBlock argument value).
    $scriptBlockAst = $null
    if ($null -ne $CommandAst.CommandElements) {
        for ($i = 0; $i -lt $CommandAst.CommandElements.Count - 1; $i++) {
            $elem = $CommandAst.CommandElements[$i]
            if ($elem -is [System.Management.Automation.Language.CommandParameterAst] -and
                $elem.ParameterName -eq 'ScriptBlock') {
                $nextElem = $CommandAst.CommandElements[$i + 1]
                if ($nextElem -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
                    $scriptBlockAst = $nextElem.ScriptBlock
                }
                break
            }
        }
    }

    if ($null -ne $scriptBlockAst -and $null -ne $scriptBlockAst.EndBlock) {
        $statements = $scriptBlockAst.EndBlock.Statements
        $stmtCount = $statements.Count

        # MISSING_RBAC_CHECK_PAGE: page route first statement must call Get-UserAccess
        # MISSING_RBAC_CHECK_API: api route must call Test-ActionEndpoint somewhere
        if ($script:CurrentFileRole -eq 'page-route') {
            $firstCallsGetUserAccess = $false
            if ($stmtCount -gt 0) {
                $firstStmt = $statements[0]
                if ($firstStmt.Extent -and $firstStmt.Extent.Text -match '\bGet-UserAccess\b') {
                    $firstCallsGetUserAccess = $true
                }
            }
            if (-not $firstCallsGetUserAccess) {
                Add-DriftCode -Row $row -Code 'MISSING_RBAC_CHECK_PAGE' `
                    -Context "Page route scriptblock does not call Get-UserAccess as the first statement."
            }
        }
        elseif ($script:CurrentFileRole -eq 'api-route') {
            $callsTestActionEndpoint = $false
            foreach ($stmt in $statements) {
                if ($stmt.Extent -and $stmt.Extent.Text -match '\bTest-ActionEndpoint\b') {
                    $callsTestActionEndpoint = $true
                    break
                }
            }
            if (-not $callsTestActionEndpoint) {
                Add-DriftCode -Row $row -Code 'MISSING_RBAC_CHECK_API' `
                    -Context "API route scriptblock does not call Test-ActionEndpoint."
            }
        }

        # MISSING_RESPONSE_WRITE_PAGE / MISSING_RESPONSE_WRITE_API: last statement
        if ($stmtCount -gt 0) {
            $lastStmt = $statements[$stmtCount - 1]
            $lastText = if ($lastStmt.Extent) { $lastStmt.Extent.Text } else { '' }
            if ($script:CurrentFileRole -eq 'page-route' -and $lastText -notmatch '\bWrite-PodeHtmlResponse\b') {
                Add-DriftCode -Row $row -Code 'MISSING_RESPONSE_WRITE_PAGE' `
                    -Context "Page route scriptblock does not end with Write-PodeHtmlResponse."
            }
            elseif ($script:CurrentFileRole -eq 'api-route' -and $lastText -notmatch '\bWrite-PodeJsonResponse\b') {
                Add-DriftCode -Row $row -Code 'MISSING_RESPONSE_WRITE_API' `
                    -Context "API route scriptblock does not end with Write-PodeJsonResponse."
            }
        }
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

    $scope = $script:CurrentFileScope
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

    $scope = $script:CurrentFileScope
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

    $scope = $script:CurrentFileScope
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

# Emit a SQL_QUERY row representing a call to a known SQL-querying command
# (Invoke-Sqlcmd and the Invoke-XFActs* family). The row also carries any
# per-call drift codes for violations: missing -TrustServerCertificate,
# missing -ApplicationName, parameter references without -Parameters, and
# linked-server references. Returns $null if the call is not a SQL command.
function Add-PSSqlCallRow {
    param([Parameter(Mandatory)]$CommandAst)

    $cmdName = $CommandAst.GetCommandName()
    if ([string]::IsNullOrEmpty($cmdName)) { return $null }
    if ($cmdName -notin $SQLQueryFunctions) { return $null }

    $line = Get-PSAstNodeLine    -Node $CommandAst
    $col  = Get-PSAstNodeColumn  -Node $CommandAst

    $key = "$($script:CurrentFile)|$line|$col|SQL_QUERY|$cmdName|USAGE|sqlcmd-call"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $scope = $script:CurrentFileScope
    $sig = if ($CommandAst.Extent) { Format-SingleLine -Text $CommandAst.Extent.Text } else { "$cmdName ..." }
    if ($sig -and $sig.Length -gt 200) { $sig = $sig.Substring(0, 200) + '...' }

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
        -ComponentType  'SQL_QUERY' `
        -ComponentName  $cmdName `
        -VariantType    'sqlcmd-call' `
        -LineStart      $line `
        -LineEnd        $line `
        -ColumnStart    $col `
        -ReferenceType  'USAGE' `
        -Scope          $scope `
        -ParentFunction $parentFn `
        -Signature      $sig `
        -RawText        $sig
    $script:rows.Add($row)

    # Walk command elements once, collecting which parameters appear and
    # capturing the -Query value when present for downstream checks.
    $hasTrustServerCert  = $false
    $hasApplicationName  = $false
    $hasParameters       = $false
    $queryText           = $null

    if ($null -ne $CommandAst.CommandElements) {
        for ($i = 0; $i -lt $CommandAst.CommandElements.Count; $i++) {
            $elem = $CommandAst.CommandElements[$i]
            if ($elem -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
            $pn = $elem.ParameterName
            switch -Regex ($pn) {
                '^TrustServerCertificate$' { $hasTrustServerCert = $true }
                '^ApplicationName$'        { $hasApplicationName = $true }
                '^Parameters$'             { $hasParameters = $true }
                '^Query$' {
                    $next = if (($i + 1) -lt $CommandAst.CommandElements.Count) { $CommandAst.CommandElements[$i + 1] } else { $null }
                    if ($null -ne $next -and $next.Extent) {
                        $queryText = $next.Extent.Text
                    }
                }
            }
        }
    }

    # Only Invoke-Sqlcmd requires -TrustServerCertificate and -ApplicationName;
    # the Invoke-XFActs* wrappers handle those internally.
    if ($cmdName -eq 'Invoke-Sqlcmd') {
        if (-not $hasTrustServerCert) {
            Add-DriftCode -Row $row -Code 'MISSING_TRUST_SERVER_CERTIFICATE' `
                -Context "Invoke-Sqlcmd at line $line is missing -TrustServerCertificate."
        }
        if (-not $hasApplicationName) {
            Add-DriftCode -Row $row -Code 'MISSING_APPLICATION_NAME' `
                -Context "Invoke-Sqlcmd at line $line is missing -ApplicationName."
        }
    }

    # If the query text references @parameter placeholders but -Parameters
    # is not declared, that's MISSING_PARAMETER_DECLARATION drift.
    if ($null -ne $queryText -and $queryText -match '@\w+\b' -and -not $hasParameters) {
        Add-DriftCode -Row $row -Code 'MISSING_PARAMETER_DECLARATION' `
            -Context "Query at line $line references @parameter placeholders but -Parameters @{...} is not declared."
    }

    # FORBIDDEN_LINKED_SERVER: four-part name in the query text.
    # Pattern: [server].[db].[schema].[table] or server.db.schema.table.
    if ($null -ne $queryText -and $queryText -match '\b\[?[A-Za-z][A-Za-z0-9_-]*\]?\s*\.\s*\[?[A-Za-z][A-Za-z0-9_]*\]?\s*\.\s*\[?[A-Za-z][A-Za-z0-9_]*\]?\s*\.\s*\[?[A-Za-z][A-Za-z0-9_]*\]?\b') {
        Add-DriftCode -Row $row -Code 'FORBIDDEN_LINKED_SERVER' `
            -Context "Query at line $line references a linked-server (four-part name)."
    }

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
    $isOrphan = $false

    # Resolution is strictly within the calling file's zone. Resolution order:
    #  1. Shared function in the SAME zone        -> SHARED (resolved here).
    #  2. Local function in the current file       -> LOCAL  (resolved here).
    #  3. Shared function in a DIFFERENT zone       -> <pending> (cross-zone
    #     reference, deferred to the resolver -- not resolvable in-populator).
    #  4. xFACts-shaped name matching nothing       -> orphan, flagged here.
    #  5. Anything else (built-ins, external)       -> skipped (not cataloged).
    $zoneShared = if ($script:sharedFunctionsByZone.ContainsKey($script:CurrentFileZone)) {
                      $script:sharedFunctionsByZone[$script:CurrentFileZone]
                  } else { $null }

    if ($null -ne $zoneShared -and $zoneShared.Contains($fnName)) {
        $scope = 'SHARED'
        $srcMap = $script:sharedSourceFileByZone[$script:CurrentFileZone]
        $sourceFile = if ($srcMap.ContainsKey($fnName)) { $srcMap[$fnName] } else { '<shared>' }
    }
    elseif ($script:CurrentLocalFunctions -and $script:CurrentLocalFunctions.Contains($fnName)) {
        $scope = 'LOCAL'
        $sourceFile = $script:CurrentFile
    }
    else {
        # Not resolvable within this zone. Determine whether the function is
        # shared in some OTHER zone (cross-zone reference -> defer to resolver
        # as <pending>) regardless of its name shape, or matches nothing at all.
        $sharedOtherZone = $false
        foreach ($z in $script:sharedFunctionsByZone.Keys) {
            if ($z -eq $script:CurrentFileZone) { continue }
            if ($script:sharedFunctionsByZone[$z].Contains($fnName)) { $sharedOtherZone = $true; break }
        }

        if ($sharedOtherZone) {
            $scope = '<pending>'
            $sourceFile = '<pending>'
        }
        elseif ($fnName -cmatch '^[A-Z][a-zA-Z]+-[a-z][a-z0-9]*_[A-Za-z]') {
            # xFACts-shaped name (Verb-prefix_Noun) that does not resolve to any
            # cataloged function in any zone. Emit a row carrying
            # ORPHAN_FUNCTION_CALL so the catalog flags the missing target.
            # Bare-Verb-Noun uncataloged calls remain silently skipped because
            # they're indistinguishable from external-module / built-in calls.
            $scope = $script:CurrentFileScope
            $sourceFile = $null
            $isOrphan = $true
        }
        else {
            return $null
        }
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

    if ($isOrphan) {
        Add-DriftCode -Row $row -Code 'ORPHAN_FUNCTION_CALL' `
            -Context "Call to '$fnName' at line $line resolves to no cataloged function definition (xFACts-shaped name with no matching definition in any scanned PS file)."
    }

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

    $scope = $script:CurrentFileScope
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
    param(
        [int]$LineStart,
        [int]$ColumnStart,
        [string]$RawText,
        [ValidateSet('ascii', 'box-drawing', 'subsection-marker')]
        [string]$Style = 'ascii'
    )

    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|PS_INLINE_BANNER|<inline-banner>|DEFINITION|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $scope = $script:CurrentFileScope

    $row = New-PSRow `
        -ComponentType 'PS_INLINE_BANNER' `
        -ComponentName '<inline-banner>' `
        -VariantType   $Style `
        -LineStart     $LineStart `
        -LineEnd       $LineStart `
        -ColumnStart   $ColumnStart `
        -ReferenceType 'DEFINITION' `
        -Scope         $scope `
        -Signature     $RawText `
        -RawText       $RawText `
        -SuppressSectionLookup
    $script:rows.Add($row)

    switch ($Style) {
        'box-drawing' {
            Add-DriftCode -Row $row -Code 'FORBIDDEN_BOX_DRAWING_BANNER' `
                -Context "Box-drawing banner at line $LineStart (Unicode line-drawing characters)."
        }
        'subsection-marker' {
            # Sub-section markers are a permitted comment form.
            # The caller is responsible for firing MALFORMED_SUBSECTION_MARKER
            # when the shape or surrounding-blank-line rules are violated.
        }
        default {
            Add-DriftCode -Row $row -Code 'FORBIDDEN_INLINE_BANNER' `
                -Context "Inline divider line at line $LineStart."
        }
    }
    return $row
}

# Emit a PS_INLINE_COMMENT row for a '#' line comment or a run of
# consecutive '#' line comments. Pure inventory cataloging: a run of N
# adjacent line comments becomes one row spanning $LineStart..$LineEnd.
# Variant types:
# 'single-line' - one comment line
# 'multi-line'  - two or more consecutive comment lines
# 'trailing'    - a '#' comment on the same line as code (drift)
# Only the 'trailing' variant carries a drift code. Leading line comments
# are normal annotations and produce no drift.
function Add-PSInlineCommentRow {
    param(
        [Parameter(Mandatory)][int]$LineStart,
        [Parameter(Mandatory)][int]$LineEnd,
        [Parameter(Mandatory)][int]$ColumnStart,
        [Parameter(Mandatory)][string]$RawText,
        [ValidateSet('single-line', 'multi-line', 'trailing')]
        [string]$Variant = 'single-line'
    )

    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|PS_INLINE_COMMENT|<inline-comment>|DEFINITION|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $scope = $script:CurrentFileScope

    # Build a parent_function attribution by scanning function ranges.
    # Reuse the cached function range list built during the walk.
    $parentFn = $null
    if ($null -ne $script:CurrentFunctionRanges) {
        foreach ($rng in $script:CurrentFunctionRanges) {
            if ($LineStart -ge $rng.LineStart -and $LineStart -le $rng.LineEnd) {
                $parentFn = $rng.Name
                break
            }
        }
    }

    $sig = Format-SingleLine -Text $RawText
    if ($sig -and $sig.Length -gt 200) { $sig = $sig.Substring(0, 200) + '...' }

    $row = New-PSRow `
        -ComponentType  'PS_INLINE_COMMENT' `
        -ComponentName  '<inline-comment>' `
        -VariantType    $Variant `
        -LineStart      $LineStart `
        -LineEnd        $LineEnd `
        -ColumnStart    $ColumnStart `
        -ReferenceType  'DEFINITION' `
        -Scope          $scope `
        -ParentFunction $parentFn `
        -Signature      $sig `
        -RawText        $RawText `
        -SuppressSectionLookup
    $script:rows.Add($row)

    if ($Variant -eq 'trailing') {
        Add-DriftCode -Row $row -Code 'FORBIDDEN_TRAILING_COMMENT' `
            -Context "Trailing '#' comment on code line at line $LineStart. Comments must lead the line."
    }

    return $row
}

# Emit a PS_REMOVED_CODE_COMMENT row for a comment indicating removed code.
function Add-PSRemovedCodeCommentRow {
    param([int]$LineStart, [int]$ColumnStart, [string]$RawText)

    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|PS_REMOVED_CODE_COMMENT|<removed-code>|DEFINITION|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $scope = $script:CurrentFileScope

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

    $scope = $script:CurrentFileScope

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

    # FORBIDDEN_FREESTANDING_COMMENT_BLOCK: any block comment cataloged here
    # is, by definition, not a file header / section banner / function docblock
    # (those are routed to their own row builders before this point).
    Add-DriftCode -Row $row -Code 'FORBIDDEN_FREESTANDING_COMMENT_BLOCK' `
        -Context "Free-standing block comment at line $LineStart. Block-comment syntax is reserved for file header, section banners, and function docblocks."
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

    $scope = $script:CurrentFileScope
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

    # MISPLACED_IMPORT: imports must appear in the IMPORTS section.
    $section = Get-SectionForLine -Sections $script:CurrentSections -Line $line
    if ($null -eq $section -or $section.TypeName -ne 'IMPORTS') {
        $where = if ($section) { "the $($section.TypeName) section" } else { 'outside any section banner' }
        Add-DriftCode -Row $row -Code 'MISPLACED_IMPORT' `
            -Context "Import statement appears in $where; spec requires the IMPORTS section."
    }

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

    $scope = $script:CurrentFileScope
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

    $scope = $script:CurrentFileScope

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

    $scope = $script:CurrentFileScope
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

<# ============================================================================
   EXECUTION: SCRIPT EXECUTION
   ----------------------------------------------------------------------------
   The populator run: discover files, parse and collect shared definitions, load
   registries, walk each file emitting rows, run cross-file checks, validate,
   index, summarize, and write to the database.
   Prefix: (none)
   ============================================================================ #>

# -- File Discovery --

Write-Log "Discovering PS files..."

$PSFiles = New-Object System.Collections.Generic.List[string]
$seenPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
foreach ($root in $PSScanRoots) {
    if (-not (Test-Path $root)) {
        Write-Log "Scan root not found, skipping: $root" 'WARN'
        continue
    }
    # .psd1 files (Pode server config, module manifests) are intentionally
    # out of scope. They are configuration data, not source code: no
    # functions, classes, or other catalogable constructs, and no spec to
    # validate against. They live in Object_Registry (which captures file
    # identity and ownership) and have no constructs for Asset_Registry to
    # catalog. If a future spec covers .psd1 structure, scan them via a
    # dedicated populator with its own file_type, not by re-extending PS.
    $found = @(Get-ChildItem -Path $root -Include '*.ps1','*.psm1' -Recurse -File |
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

# -- Object_Registry Zone/Scope Classification --

# Loaded before Pass 1 because the shared-function collection gate keys off
# each file's table scope (SHARED) rather than its detected role.
Write-Log "Loading Object_Registry zone/scope classification map..."
$objectZoneScopeMap = Get-ObjectRegistryZoneScopeMap `
    -ServerInstance $script:XFActsServerInstance `
    -Database       $script:XFActsDatabase `
    -FileType       @('PS','Route','API','Module')
Write-Log ("  Object_Registry zone/scope rows loaded: {0}" -f $objectZoneScopeMap.Count)

# -- Pass 1: Parse and Collect Shared Definitions --

# Walk every file once to (a) cache the parse result and (b) collect top-level
# function definitions from SHARED-scope files into the shared-functions
# HashSet. PS_FUNCTION_CALL USAGE rows in Pass 2 use this map to resolve
# scope=SHARED.

Write-Log "Pass 1: parse all files, collect shared-scope function definitions..."

$astCache = @{}

foreach ($file in $PSFiles) {
    $name = [System.IO.Path]::GetFileName($file)
    $role = Get-PSFileRole -FullPath $file

    Write-Host "  Parsing $name (role=$role)..." -NoNewline
    $parsed = Invoke-PSParse -FilePath $file
    if ($null -eq $parsed) {
        Write-Host " FAILED" -ForegroundColor Red
        continue
    }
    Write-Host " ok" -ForegroundColor Green
    $astCache[$file] = @{ Parsed = $parsed; Role = $role }

    # Collect shared-scope functions from files whose Object_Registry scope is
    # SHARED, bucketed by the file's zone. Resolution is strictly within-zone,
    # so a function shared in one zone is invisible to callers in another. A
    # file absent from the map is a registration gap: it contributes no shared
    # functions and is flagged in Pass 2.
    if (-not $objectZoneScopeMap.ContainsKey($name)) { continue }
    $fileZone  = $objectZoneScopeMap[$name].Zone
    $fileScope = $objectZoneScopeMap[$name].Scope
    if ($fileScope -ne 'SHARED') { continue }

    if (-not $script:sharedFunctionsByZone.ContainsKey($fileZone)) {
        $script:sharedFunctionsByZone[$fileZone]  = New-Object 'System.Collections.Generic.HashSet[string]'
        $script:sharedSourceFileByZone[$fileZone] = @{}
    }

    $topLevelFns = Find-PSAstNodes -Ast $parsed.Ast `
        -AstType ([System.Management.Automation.Language.FunctionDefinitionAst]) `
        -TopLevelOnly
    foreach ($fn in $topLevelFns) {
        if ($fn.Name) {
            [void]$script:sharedFunctionsByZone[$fileZone].Add($fn.Name)
            if (-not $script:sharedSourceFileByZone[$fileZone].ContainsKey($fn.Name)) {
                $script:sharedSourceFileByZone[$fileZone][$fn.Name] = $name
            }
        }
    }
}

Write-Log ("  Shared functions collected across {0} zone(s)." -f $script:sharedFunctionsByZone.Count)

# -- Registry Loads --

Write-Log "Loading Component_Registry prefix map for registry validation..."
$componentPrefixMap = Get-ComponentRegistryPrefixMap `
    -ServerInstance $script:XFActsServerInstance `
    -Database       $script:XFActsDatabase `
    -FileType       @('PS','Route','API','Module')
Write-Log ("  Component_Registry prefix rows loaded: {0}" -f $componentPrefixMap.Count)

Write-Log "Loading Component_Registry component_name set for INVALID_COMPONENT_VALUE validation..."
$componentNameSet = Get-ComponentRegistryNameSet `
    -ServerInstance $script:XFActsServerInstance `
    -Database       $script:XFActsDatabase
Write-Log ("  Component_Registry component_name rows loaded: {0}" -f $componentNameSet.Count)

$objectRegistryMisses = New-Object 'System.Collections.Generic.HashSet[string]'

# -- Pass 2: Per-File Walk --

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

    # Set per-file context
    $script:CurrentFile               = $name
    $script:CurrentFileFullPath       = $file
    $script:CurrentFileRole           = $role

    # Zone and scope come from Object_Registry, not from role or path. A file
    # absent from the map is a registration gap: stamp '<undefined>' for both
    # so the gap surfaces as drift (FILE_NOT_REGISTERED on the anchor row)
    # rather than being silently misclassified.
    if ($objectZoneScopeMap.ContainsKey($name)) {
        $script:CurrentFileZone      = $objectZoneScopeMap[$name].Zone
        $script:CurrentFileScope     = $objectZoneScopeMap[$name].Scope
        $script:CurrentFileScopeTier = $objectZoneScopeMap[$name].ScopeTier
    } else {
        $script:CurrentFileZone      = '<undefined>'
        $script:CurrentFileScope     = '<undefined>'
        $script:CurrentFileScopeTier = $null
        [void]$objectRegistryMisses.Add($name)
    }
    $script:CurrentFileIsShared       = ($script:CurrentFileScope -eq 'SHARED')
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

    # Build per-function line ranges for inline-comment parent_function attribution.
    # Includes nested functions so that comments inside any function get attributed
    # to the innermost enclosing function (first match wins; we sort innermost-first
    # by reverse-sorting by LineStart descending so closer-to-target ranges come first).
    $script:CurrentFunctionRanges = New-Object System.Collections.Generic.List[object]
    $allFnNodes = Find-PSAstNodes -Ast $parsed.Ast `
        -AstType ([System.Management.Automation.Language.FunctionDefinitionAst])
    foreach ($fn in $allFnNodes) {
        if (-not $fn.Name) { continue }
        $fnStart = Get-PSAstNodeLine    -Node $fn
        $fnEnd   = Get-PSAstNodeEndLine -Node $fn
        $script:CurrentFunctionRanges.Add([ordered]@{
            Name      = $fn.Name
            LineStart = $fnStart
            LineEnd   = $fnEnd
        })
    }
    # Sort by LineStart descending so nested (later, deeper) ranges come first
    # in the lookup. Inner functions have larger LineStart values than their
    # enclosing function, so this gives innermost-first matching.
    if ($script:CurrentFunctionRanges.Count -gt 1) {
        $sorted = @($script:CurrentFunctionRanges | Sort-Object -Property LineStart -Descending)
        $script:CurrentFunctionRanges = New-Object System.Collections.Generic.List[object]
        foreach ($r in $sorted) { $script:CurrentFunctionRanges.Add($r) }
    }

    $startCount = $script:rows.Count
    $scopeLabel = $script:CurrentFileScope
    Write-Host ("  Walking {0} ({1}, role={2})..." -f $name, $scopeLabel, $role) -ForegroundColor Cyan

    # Emit PS_FILE anchor row
    $psFileRow = Add-PSFileRow -LineEnd $script:CurrentFileLineCount

    # Emit FILE_HEADER row
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

        # Validate .COMPONENT against Component_Registry if present.
        # The name must appear in $componentNameSet (active component_names).
        if (-not [string]::IsNullOrEmpty($headerInfo.Component) -and $componentNameSet.Count -gt 0) {
            if (-not $componentNameSet.Contains($headerInfo.Component)) {
                Add-DriftCode -Row $headerRow -Code 'INVALID_COMPONENT_VALUE' `
                    -Context "Header .COMPONENT value '$($headerInfo.Component)' does not match any active row in Component_Registry."
            }
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
        # No <# #> block found at line 1. No FILE_HEADER row is emitted --
        # the drift attaches to the PS_FILE anchor row instead, following
        # the same pattern used by MISSING_SECTION_BANNER (attached to the
        # function row, not to a phantom banner row).
        if ($null -ne $psFileRow) {
            Add-DriftCode -Row $psFileRow -Code 'MALFORMED_FILE_HEADER' `
                -Context "No comment-based-help block found at the top of the file."
        }
    }

    # Emit COMMENT_BANNER rows from the section list
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

    # AST WALK: PASS A - Top-level functions
    try {
        $topLevelFns = Find-PSAstNodes -Ast $parsed.Ast `
            -AstType ([System.Management.Automation.Language.FunctionDefinitionAst]) `
            -TopLevelOnly
        foreach ($fn in $topLevelFns) {
            $fnRow = Add-PSFunctionRow -FunctionAst $fn
            if ($null -eq $fnRow) { continue }

            # Emit PS_DOCBLOCK if a docblock exists for this function in any
            # position. Get-PSFunctionDocblock (called by Add-PSFunctionRow)
            # already marked the matching comment as Used; we re-find here by
            # repeating the same three-position search but TOLERATING the
            # Used flag this time. Position priority matches the helper:
            # canonical inside-body first, then above-function, then any
            # other body position.
            $fnLine    = Get-PSAstNodeLine    -Node $fn
            $fnEndLine = Get-PSAstNodeEndLine -Node $fn

            $paramBlk = if ($fn.Body -and $fn.Body.ParamBlock) { $fn.Body.ParamBlock } else { $null }
            $canonStart = if ($paramBlk) {
                (Get-PSAstNodeEndLine -Node $paramBlk) + 1
            } else {
                $fnLine + 1
            }
            $firstStmtLine = $fnEndLine
            if ($fn.Body -and $fn.Body.EndBlock -and $fn.Body.EndBlock.Statements -and
                $fn.Body.EndBlock.Statements.Count -gt 0) {
                $firstStmtLine = Get-PSAstNodeLine -Node $fn.Body.EndBlock.Statements[0]
            }

            $docCandidate = $null
            # Pass A.1: canonical inside-body position.
            foreach ($c in $script:CurrentCommentIndex) {
                if ($c.Type -ne 'Block') { continue }
                if ($c.StartLine -ge $canonStart -and $c.EndLine -lt $firstStmtLine) {
                    if ($null -eq $docCandidate -or $c.EndLine -gt $docCandidate.EndLine) {
                        $docCandidate = $c
                    }
                }
            }
            # Pass A.2: above-function (legacy position).
            if ($null -eq $docCandidate) {
                foreach ($c in $script:CurrentCommentIndex) {
                    if ($c.Type -ne 'Block') { continue }
                    $gap = $fnLine - $c.EndLine
                    if ($gap -ge 1 -and $gap -le 2) {
                        if ($null -eq $docCandidate -or $c.EndLine -gt $docCandidate.EndLine) {
                            $docCandidate = $c
                        }
                    }
                }
            }
            # Pass A.3: anywhere else inside the function body.
            if ($null -eq $docCandidate) {
                foreach ($c in $script:CurrentCommentIndex) {
                    if ($c.Type -ne 'Block') { continue }
                    if ($c.StartLine -ge $fnLine -and $c.EndLine -le $fnEndLine) {
                        if ($null -eq $docCandidate -or $c.StartLine -lt $docCandidate.StartLine) {
                            $docCandidate = $c
                        }
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

    # AST WALK: PASS B - Top-level assignments (CONSTANTS/VARIABLES)
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

    # AST WALK: PASS C - CommandAst for Pode infrastructure + imports
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
                    # -Function 'Foo'              -> StringConstantExpressionAst
                    # -Function 'Foo','Bar'        -> ArrayLiteralAst
                    # -Function ('Foo','Bar')      -> ParenExpressionAst wrapping ArrayLiteralAst
                    # -Function @('Foo','Bar')     -> ArrayExpressionAst wrapping
                    # StatementBlockAst > PipelineAst > ArrayLiteralAst
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
                                            $exportRow = Add-PSExportRow -CommandAst $cmd -ExportedName $nm -ExportKind $exportKind
                                            if ($null -ne $exportRow) {
                                                # FORBIDDEN_WILDCARD_EXPORT: '*' wildcard is not permitted.
                                                if ($nm -eq '*') {
                                                    Add-DriftCode -Row $exportRow -Code 'FORBIDDEN_WILDCARD_EXPORT' `
                                                        -Context "Export-ModuleMember -$exportKind * uses wildcard. Exports must be enumerated explicitly."
                                                }
                                                # EXPORTED_FUNCTION_NOT_DEFINED: only for -Function exports;
                                                # function name not declared in this file.
                                                elseif ($exportKind -eq 'function' -and
                                                        $script:CurrentLocalFunctions -and
                                                        -not $script:CurrentLocalFunctions.Contains($nm)) {
                                                    Add-DriftCode -Row $exportRow -Code 'EXPORTED_FUNCTION_NOT_DEFINED' `
                                                        -Context "Export-ModuleMember references function '$nm' which is not defined in this file."
                                                }
                                            }
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
                    # SQL-querying command calls (Invoke-Sqlcmd + Invoke-XFActs*)
                    if ($SQLQueryFunctions -contains $cmdName) {
                        Add-PSSqlCallRow -CommandAst $cmd | Out-Null
                    }
                    # Cataloged function calls
                    Add-PSFunctionCallRow -CommandAst $cmd | Out-Null
                }
            }
        }
    } catch {
        Write-Log "Pass C (CommandAst processing) failed on ${name}: $($_.Exception.Message)" 'WARN'
    }

    # AST WALK: PASS D - Dot-source statements
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

    # AST WALK: PASS E - String / here-string scanning for SQL and GlobalConfig
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
                $sqlRow = Add-PSSqlQueryRow `
                    -LineStart $line -LineEnd $endLn -ColumnStart $col `
                    -QueryText $text -ParentFunction $parentFn -Kind 'literal'

                # FORBIDDEN_INLINE_SQL_LITERAL: multi-line SQL embedded in a
                # single-line string literal (rather than a here-string).
                # Detection: the string is StringConstantExpressionAst with a
                # StringConstantType of SingleQuoted or DoubleQuoted (not here-string),
                # AND the query text contains newline characters.
                if ($null -ne $sqlRow -and
                    $sn -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                    $strType = $sn.StringConstantType.ToString()
                    if ($strType -notmatch 'HereString' -and $text -match "`n") {
                        Add-DriftCode -Row $sqlRow -Code 'FORBIDDEN_INLINE_SQL_LITERAL' `
                            -Context "Multi-line SQL at line $line is embedded as a $strType string literal. Use a here-string (@`"...`"@)."
                    }
                }

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

    # AST WALK: PASS F - Comment-level passes
    # Walks every comment token in the file and dispatches by shape. Three
    # broad categories are handled:
    #
    # 1. Block comments (<# ... #>)
    # - File header / section banner / function docblock: already claimed
    # by their respective row builders; skipped here.
    # - Anything else: emits a PS_COMMENT_BLOCK row with the
    # FORBIDDEN_FREESTANDING_COMMENT_BLOCK drift code (block-comment
    # syntax is reserved for structural docs).
    #
    # 2. Line comments (#) at the start of a line, or runs of consecutive
    # such lines. Coalesced into a single PS_INLINE_COMMENT row per
    # contiguous run. Special single-line forms (divider patterns,
    # removed-code headstones) get their own row types instead.
    #
    # 3. Trailing line comments (# at the end of a code line). Each emits
    # its own PS_INLINE_COMMENT row with variant='trailing' and the
    # FORBIDDEN_TRAILING_COMMENT drift code.
    try {
        # Build source-lines once for trailing-comment detection.
        $srcLines = if ($null -ne $script:CurrentFileSource) {
            $script:CurrentFileSource -split "`r?`n"
        } else { @() }

        # Partition comments into block comments and line comments.
        # Line comments get further partitioned into leading vs trailing
        # using the source-line "is there non-whitespace before the # column"
        # test. A line comment whose column is 1, or whose preceding text on
        # the same line is all whitespace, is leading. Otherwise trailing.
        $lineComments = New-Object System.Collections.Generic.List[object]
        $blockComments = New-Object System.Collections.Generic.List[object]
        foreach ($c in $script:CurrentNormalizedComments) {
            if ($c.Type -eq 'Block') {
                $blockComments.Add($c)
                continue
            }
            # Line comment: classify leading vs trailing.
            $isTrailing = $false
            if ($c.ColumnStart -gt 1 -and $srcLines.Count -ge $c.LineStart) {
                $lineText = $srcLines[$c.LineStart - 1]
                if ($null -ne $lineText -and $lineText.Length -ge ($c.ColumnStart - 1)) {
                    $beforeHash = $lineText.Substring(0, $c.ColumnStart - 1)
                    if ($beforeHash -match '\S') { $isTrailing = $true }
                }
            }
            $lineComments.Add([pscustomobject]@{
                Comment    = $c
                IsTrailing = $isTrailing
            })
        }

        # Trailing line comments: one row each, all carry drift
        foreach ($entry in $lineComments) {
            if (-not $entry.IsTrailing) { continue }
            $c = $entry.Comment
            Add-PSInlineCommentRow `
                -LineStart   $c.LineStart `
                -LineEnd     $c.LineStart `
                -ColumnStart $c.ColumnStart `
                -RawText     $c.OriginalToken.Text `
                -Variant     'trailing' | Out-Null
        }

        # Leading line comments: extract sub-section markers, then coalesce runs
        # A run is a maximal sequence of leading line comments on consecutive
        # source lines (no gap). The "next" line must immediately follow the
        # previous (LineStart difference of 1) and must also be a leading line
        # comment. Any blank line or code line breaks the run.
        #
        # Sub-section markers are extracted BEFORE run-grouping
        # so they cannot be silently absorbed into a multi-line `#` comment
        # run. A marker-shaped line (strict `# -- <Label> -- ` shape, plus a
        # marker-looking but not-quite "almost" shape) gets pulled out of the
        # leading array and emitted as a PS_INLINE_BANNER row in its own
        # right. The remaining leading entries proceed through the standard
        # run-grouping logic. This guarantees that a marker which violates
        # any the rule (wrong shape, missing surrounding blank, inside
        # a run) surfaces as MALFORMED_SUBSECTION_MARKER drift instead of
        # disappearing into a comment-run row.
        $leading = @($lineComments | Where-Object { -not $_.IsTrailing } |
                     ForEach-Object { $_.Comment } |
                     Sort-Object LineStart)

        # First pass: identify markers, emit their banner rows with drift as
        # appropriate, collect the line numbers we've consumed so the run
        # builder can skip them.
        $markerConsumedLines = New-Object 'System.Collections.Generic.HashSet[int]'

        # Strict marker shape: '#' has been stripped by Convert-PSCommentsToNormalized,
        # so $text starts with '--'. Pattern:
        # ^--      exactly two dashes at start
        # \s       exactly one space
        # \S       at least one non-space (label start)
        # .*?      non-greedy any
        # \S       label ends in non-space (no trailing inner space)
        # \s       exactly one space
        # --$      exactly two dashes at end (no trailing whitespace)
        $strictMarkerRe = '^--\s\S(.*?\S)?\s--$'
        # "Almost-marker" shape: starts with --, ends with --, but didn't pass
        # the strict regex. Used to catch authoring attempts with wrong dash
        # counts, missing spaces, etc.
        $almostMarkerRe = '^-{2,}.*-{2,}$'

        foreach ($entry in $leading) {
            $entryText = $entry.Text
            $isStrict = ($entryText -match $strictMarkerRe) -and ($entryText -match '[A-Za-z]')
            $isAlmost = (-not $isStrict) -and ($entryText -match $almostMarkerRe)

            if (-not ($isStrict -or $isAlmost)) { continue }

            # This entry is a marker (strict) or marker-shaped (almost).
            # Extract it from the run-building pool and emit its banner row.
            [void]$markerConsumedLines.Add($entry.LineStart)

            $markerRow = Add-PSInlineBannerRow `
                -LineStart   $entry.LineStart `
                -ColumnStart $entry.ColumnStart `
                -RawText     $entry.OriginalToken.Text `
                -Style       'subsection-marker'
            if ($null -eq $markerRow) { continue }

            # Drift attribution.
            $driftReasons = New-Object System.Collections.Generic.List[string]

            if ($isAlmost) {
                $driftReasons.Add("comment uses sub-section marker shape but does not match the strict '# -- <Label> --' form")
            }

            # Adjacency-to-`#`-comment check (the marker must not be part
            # of a `#` comment run). Use the leading-comments collection
            # itself rather than the raw source: a previous/next line is a
            # `#` comment iff there's an entry at LineStart-1 or LineStart+1.
            $hasCommentAbove = $leading | Where-Object { $_.LineStart -eq ($entry.LineStart - 1) }
            $hasCommentBelow = $leading | Where-Object { $_.LineStart -eq ($entry.LineStart + 1) }
            if ($hasCommentAbove) {
                $driftReasons.Add("marker is preceded by a '#' comment on the immediately previous line (markers must stand alone)")
            }
            if ($hasCommentBelow) {
                $driftReasons.Add("marker is followed by a '#' comment on the immediately next line (markers must stand alone)")
            }

            # Surrounding-blank-line check. Look at the raw
            # source lines. The line above the marker must be blank OR be
            # the closing line of a section banner (a banner's closing '#>'
            # line is followed by exactly one blank line, so
            # the marker's leading-blank rule is satisfied transitively).
            # The line below the marker must be blank.
            if ($srcLines.Count -gt 0) {
                # 0-based source index
                $lineIdx = $entry.LineStart - 1

                # Leading check
                if ($lineIdx -gt 0 -and -not $hasCommentAbove) {
                    $prevText = $srcLines[$lineIdx - 1]
                    if (-not [string]::IsNullOrWhiteSpace($prevText)) {
                        $driftReasons.Add("marker is not preceded by a blank line")
                    }
                }

                # Trailing check (skip if marker is on the last line of file)
                if (($lineIdx + 1) -lt $srcLines.Count -and -not $hasCommentBelow) {
                    $nextText = $srcLines[$lineIdx + 1]
                    if (-not [string]::IsNullOrWhiteSpace($nextText)) {
                        $driftReasons.Add("marker is not followed by a blank line")
                    }
                }
            }

            if ($driftReasons.Count -gt 0) {
                $reasonText = $driftReasons -join '; '
                Add-DriftCode -Row $markerRow -Code 'MALFORMED_SUBSECTION_MARKER' `
                    -Context "Sub-section marker at line $($entry.LineStart): $reasonText."
            }
        }

        # Second pass: standard run-grouping over the leading entries that
        # weren't consumed as markers.
        $remaining = @($leading | Where-Object { -not $markerConsumedLines.Contains($_.LineStart) })

        $i = 0
        while ($i -lt $remaining.Count) {
            # Build the run starting at $i.
            $runStart = $i
            $runEnd   = $i
            for ($j = $i + 1; $j -lt $remaining.Count; $j++) {
                $prev = $remaining[$j - 1]
                $cur  = $remaining[$j]
                if ($cur.LineStart -eq ($prev.LineStart + 1)) {
                    $runEnd = $j
                } else {
                    break
                }
            }

            $runLength = $runEnd - $runStart + 1
            $firstComment = $remaining[$runStart]
            $lastComment  = $remaining[$runEnd]

            if ($runLength -eq 1) {
                # Single-line run. Check for special drift-emitting patterns first.
                $text = $firstComment.Text
                $matched = $false

                if ($text -match '^[\s]*[=\-]{4,}[\s]*$') {
                    Add-PSInlineBannerRow `
                        -LineStart   $firstComment.LineStart `
                        -ColumnStart $firstComment.ColumnStart `
                        -RawText     $firstComment.OriginalToken.Text `
                        -Style       'ascii' | Out-Null
                    $matched = $true
                }
                elseif ($text -match '^[\s]*[\u2500-\u257F]{4,}[\s]*$') {
                    Add-PSInlineBannerRow `
                        -LineStart   $firstComment.LineStart `
                        -ColumnStart $firstComment.ColumnStart `
                        -RawText     $firstComment.OriginalToken.Text `
                        -Style       'box-drawing' | Out-Null
                    $matched = $true
                }
                elseif ($text -match '(?i)^\s*(removed|deleted|was|todo:?\s*remove)\b') {
                    Add-PSRemovedCodeCommentRow `
                        -LineStart   $firstComment.LineStart `
                        -ColumnStart $firstComment.ColumnStart `
                        -RawText     $firstComment.OriginalToken.Text | Out-Null
                    $matched = $true
                }

                if (-not $matched) {
                    # Plain single-line inline annotation.
                    Add-PSInlineCommentRow `
                        -LineStart   $firstComment.LineStart `
                        -LineEnd     $firstComment.LineStart `
                        -ColumnStart $firstComment.ColumnStart `
                        -RawText     $firstComment.OriginalToken.Text `
                        -Variant     'single-line' | Out-Null
                }
            }
            else {
                # Multi-line run. Concatenate the original tokens for raw_text
                # so the catalog preserves the developer's text verbatim.
                $rawParts = @()
                for ($k = $runStart; $k -le $runEnd; $k++) {
                    $rawParts += $remaining[$k].OriginalToken.Text
                }
                $rawJoined = $rawParts -join "`n"

                Add-PSInlineCommentRow `
                    -LineStart   $firstComment.LineStart `
                    -LineEnd     $lastComment.LineStart `
                    -ColumnStart $firstComment.ColumnStart `
                    -RawText     $rawJoined `
                    -Variant     'multi-line' | Out-Null
            }

            $i = $runEnd + 1
        }

        # Block comments: existing dispatch (header / banner / docblock claimed-check, fallback to PS_COMMENT_BLOCK)
        foreach ($c in $blockComments) {
            $text = $c.Text
            if ([string]::IsNullOrEmpty($text)) { continue }

            # Skip if already claimed (file header, function docblock, etc.).
            $isClaimed = $false
            foreach ($ci in $script:CurrentCommentIndex) {
                if ($ci.StartLine -eq $c.LineStart -and $ci.Used) {
                    $isClaimed = $true
                    break
                }
            }
            if ($isClaimed) { continue }

            # Skip section banners (these are cataloged via Add-PSCommentBannerRow).
            if (Test-IsBannerComment -CommentText $text -ValidSectionTypes $script:CurrentValidSectionTypes) {
                continue
            }

            # Anything left over is a stray block comment (FORBIDDEN_FREESTANDING_COMMENT_BLOCK).
            Add-PSCommentBlockRow `
                -LineStart   $c.LineStart `
                -LineEnd     $c.LineEnd `
                -ColumnStart $c.ColumnStart `
                -RawText     $c.OriginalToken.Text | Out-Null
        }
    } catch {
        Write-Log "Pass F (comment passes) failed on ${name}: $($_.Exception.Message)" 'WARN'
    }

    # Module-level export checks (module role only)
    # # - MISSING_EXPORTS_SECTION: module file lacks an EXPORTS section.
    # - DEFINED_FUNCTION_NOT_EXPORTED: function declared but not exported.
    if ($script:CurrentFileRole -eq 'module' -and $null -ne $psFileRow) {
        # Collect EXPORTS section presence and the names actually exported.
        $hasExportsSection = $false
        if ($script:CurrentSections) {
            foreach ($sec in $script:CurrentSections) {
                if ($sec.TypeName -eq 'EXPORTS') { $hasExportsSection = $true; break }
            }
        }
        if (-not $hasExportsSection) {
            Add-DriftCode -Row $psFileRow -Code 'MISSING_EXPORTS_SECTION' `
                -Context "Module file lacks an EXPORTS section."
        }

        # Collect exported function names from PS_EXPORT rows generated for this file.
        $exportedFns = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($r in $script:rows) {
            if ($r.FileName -eq $script:CurrentFile -and
                $r.ComponentType -eq 'PS_EXPORT' -and
                $r.VariantType -eq 'function') {
                [void]$exportedFns.Add($r.ComponentName)
            }
        }
        # Find functions declared in this file (via PS_FUNCTION rows) that
        # are NOT in the exported set. Each one gets a DEFINED_FUNCTION_NOT_EXPORTED
        # drift code attached to its own row.
        foreach ($r in $script:rows) {
            if ($r.FileName -eq $script:CurrentFile -and
                $r.ComponentType -eq 'PS_FUNCTION' -and
                $r.ReferenceType -eq 'DEFINITION' -and
                -not $exportedFns.Contains($r.ComponentName)) {
                Add-DriftCode -Row $r -Code 'DEFINED_FUNCTION_NOT_EXPORTED' `
                    -Context "Function '$($r.ComponentName)' declared in module file but not exported."
            }
        }
    }

    # TRAILING_WHITESPACE: per-file line scan
    # Walks each source line; if any line ends with whitespace, attach the
    # drift code to the PS_FILE row. One drift code attachment per file
    # regardless of count; the context lists offending line numbers.
    if ($null -ne $psFileRow -and $null -ne $script:CurrentFileSource) {
        $trailingLines = New-Object System.Collections.Generic.List[int]
        $sourceLines = $script:CurrentFileSource -split "`r?`n"
        for ($li = 0; $li -lt $sourceLines.Count; $li++) {
            $ln = $sourceLines[$li]
            if ($ln.Length -gt 0 -and $ln -match '[\s]+$') {
                $trailingLines.Add($li + 1)
            }
        }
        if ($trailingLines.Count -gt 0) {
            $lineSummary = if ($trailingLines.Count -le 10) {
                ($trailingLines -join ', ')
            } else {
                ($trailingLines[0..9] -join ', ') + ", +$($trailingLines.Count - 10) more"
            }
            Add-DriftCode -Row $psFileRow -Code 'TRAILING_WHITESPACE' `
                -Context "Lines with trailing whitespace: $lineSummary."
        }
    }

    # File-level role/section checks
    # MISSING_REQUIRED_SECTION: a section type required for this role is absent.
    # DUPLICATE_SINGULAR_SECTION: a singleton section appears more than once.
    # FORBIDDEN_SECTION_TYPE: a section's type isn't valid for this role
    # (currently emitted as UNKNOWN_SECTION_TYPE via Get-BannerInfo; we also
    # surface it explicitly on the PS_FILE row here for visibility).
    if ($null -ne $psFileRow -and $null -ne $script:CurrentSections -and $null -ne $script:CurrentFileRole) {
        # Build per-type section counts.
        $typeCounts = @{}
        $foundTypes = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($sec in $script:CurrentSections) {
            if ($null -eq $sec -or [string]::IsNullOrEmpty($sec.TypeName)) { continue }
            if (-not $typeCounts.ContainsKey($sec.TypeName)) { $typeCounts[$sec.TypeName] = 0 }
            $typeCounts[$sec.TypeName] += 1
            [void]$foundTypes.Add($sec.TypeName)
        }

        # MISSING_REQUIRED_SECTION
        if ($RequiredSectionsByRole.ContainsKey($script:CurrentFileRole)) {
            $required = $RequiredSectionsByRole[$script:CurrentFileRole]
            $missing = New-Object System.Collections.Generic.List[string]
            foreach ($req in $required) {
                if (-not $foundTypes.Contains($req)) { $missing.Add($req) }
            }
            if ($missing.Count -gt 0) {
                Add-DriftCode -Row $psFileRow -Code 'MISSING_REQUIRED_SECTION' `
                    -Context "Role '$($script:CurrentFileRole)' requires section(s): $($missing -join ', ')."
            }
        }

        # DUPLICATE_SINGULAR_SECTION
        $dupSingletons = New-Object System.Collections.Generic.List[string]
        foreach ($typeName in $typeCounts.Keys) {
            if ($SingletonSectionTypes -contains $typeName -and $typeCounts[$typeName] -gt 1) {
                $count = $typeCounts[$typeName]
                $dupSingletons.Add("$typeName (${count}x)")
            }
        }
        if ($dupSingletons.Count -gt 0) {
            Add-DriftCode -Row $psFileRow -Code 'DUPLICATE_SINGULAR_SECTION' `
                -Context "Singleton sections appear more than once: $($dupSingletons -join ', ')."
        }

        # FORBIDDEN_SECTION_TYPE
        $allowedForRole = if ($ValidSectionTypesByRole.ContainsKey($script:CurrentFileRole)) {
            $ValidSectionTypesByRole[$script:CurrentFileRole]
        } else { @() }
        $forbiddenFound = New-Object System.Collections.Generic.List[string]
        foreach ($typeName in $foundTypes) {
            if ($typeName -notin $allowedForRole) {
                $forbiddenFound.Add($typeName)
            }
        }
        if ($forbiddenFound.Count -gt 0) {
            Add-DriftCode -Row $psFileRow -Code 'FORBIDDEN_SECTION_TYPE' `
                -Context "Section type(s) not allowed for role '$($script:CurrentFileRole)': $($forbiddenFound -join ', ')."
        }
    }

    $delta = $script:rows.Count - $startCount
    Write-Host ("    -> {0} rows" -f $delta) -ForegroundColor Green
}

# -- Pass 3: Cross-File Compliance Checks --

Write-Log "Pass 3: cross-file compliance checks..."

# FILE_NOT_REGISTERED: any file absent from the Object_Registry zone/scope map
# was stamped zone/scope '<undefined>' during the walk and recorded in
# $objectRegistryMisses. Attach the drift code to each such file's PS_FILE
# anchor row so the registration gap surfaces in drift analysis rather than
# only in the console miss report.
foreach ($missing in $objectRegistryMisses) {
    if ($script:psFileRowByFile.ContainsKey($missing)) {
        Add-DriftCode -Row $script:psFileRowByFile[$missing] -Code 'FILE_NOT_REGISTERED' `
            -Context "File '$missing' has no active Object_Registry row; zone and scope are '<undefined>'."
    }
}

# EXCESS_BLANK_LINES: walk each file's source and find consecutive runs of
# truly blank lines (whitespace-only) between top-level constructs. The
# previous implementation measured the line-number gap between adjacent
# AST EndBlock.Statements entries; that approach incorrectly counted
# intervening banner block comments (which are not AST statements but do
# fill the gap with non-blank content) as if they were blank lines, and
# fired drift on files that had zero consecutive blank-line runs in the
# source. The corrected implementation scans the source text directly,
# counting actual blank-line runs and skipping content inside here-strings
# and multi-line block comments where blank lines are author content not
# subject to the top-level discipline.
foreach ($file in $PSFiles) {
    $name = [System.IO.Path]::GetFileName($file)
    if (-not $astCache.ContainsKey($file)) { continue }
    $parsed = $astCache[$file].Parsed
    # data-files have no AST
    if ($null -eq $parsed) { continue }
    if ([string]::IsNullOrEmpty($parsed.Source)) { continue }

    $sourceLines = $parsed.Source -split "`r?`n"

    # Build a flag array marking each line as "skip" when it is inside a
    # multi-line construct that may legitimately contain its own blank
    # lines. Two skip regions:
    # - Block comments <# ... #>: spec allows blank lines inside banner
    # descriptions; we don't measure them.
    # - Here-strings @" ... "@ and @' ... '@: the contained text is data,
    # not source-level construct separation.
    # Skip detection uses the parser's token stream; tokens carry start
    # and end line numbers via their .Extent property.
    $skip = New-Object 'System.Collections.Generic.HashSet[int]'
    if ($null -ne $parsed.Tokens) {
        foreach ($tok in $parsed.Tokens) {
            if ($null -eq $tok.Extent) { continue }
            $isMultilineBlock = $false
            if ($tok.Kind -eq 'Comment') {
                # PowerShell tokenizer flags <# #> via TokenFlags.None on a
                # Comment token whose text starts with '<#'. We just check
                # the source.
                $tokText = $tok.Extent.Text
                if ($tokText -and $tokText.StartsWith('<#')) {
                    $isMultilineBlock = $true
                }
            }
            elseif ($tok.Kind -eq 'HereStringExpandable' -or
                    $tok.Kind -eq 'HereStringLiteral' -or
                    $tok.Kind -eq 'StringExpandable' -or
                    $tok.Kind -eq 'StringLiteral') {
                # Multi-line strings (whether here-string or regular) can
                # contain blank lines that aren't source-level separators.
                if ($tok.Extent.EndLineNumber -gt $tok.Extent.StartLineNumber) {
                    $isMultilineBlock = $true
                }
            }
            if ($isMultilineBlock) {
                for ($l = $tok.Extent.StartLineNumber; $l -le $tok.Extent.EndLineNumber; $l++) {
                    [void]$skip.Add($l)
                }
            }
        }
    }

    # Walk the source line-by-line and detect any run of 2+ consecutive
    # blank lines that are not inside a skip region. The first occurrence
    # triggers the drift; we don't need to find all of them.
    $excessFound = $false
    $blankRun = 0
    for ($idx = 0; $idx -lt $sourceLines.Count; $idx++) {
        # 1-based for skip-set comparison
        $lineNum = $idx + 1
        if ($skip.Contains($lineNum)) {
            $blankRun = 0
            continue
        }
        if ([string]::IsNullOrWhiteSpace($sourceLines[$idx])) {
            $blankRun++
            if ($blankRun -ge 2) {
                $excessFound = $true
                break
            }
        } else {
            $blankRun = 0
        }
    }

    if ($excessFound -and $script:psFileRowByFile.ContainsKey($name)) {
        Add-DriftCode -Row $script:psFileRowByFile[$name] -Code 'EXCESS_BLANK_LINES' `
            -Context "More than one blank line appears between top-level constructs in $name."
    }
}

# SHADOWS_SHARED_FUNCTION: a non-shared file defining a function whose name
# matches a shared function IN THE SAME ZONE. Cross-zone same-name functions
# are separate namespaces (never loaded into the same runtime), so they are
# not shadows.
$shadowCandidates = @($script:rows | Where-Object {
    ($_.ComponentType -eq 'PS_FUNCTION' -or $_.ComponentType -eq 'PS_FUNCTION_VARIANT') -and
    $_.ReferenceType -eq 'DEFINITION' -and
    $_.Scope -eq 'LOCAL'
})
foreach ($row in $shadowCandidates) {
    $zoneShared = if ($script:sharedFunctionsByZone.ContainsKey($row.Zone)) {
                      $script:sharedFunctionsByZone[$row.Zone]
                  } else { $null }
    if ($null -ne $zoneShared -and $zoneShared.Contains($row.ComponentName)) {
        $srcMap = $script:sharedSourceFileByZone[$row.Zone]
        $shadowSrc = if ($srcMap.ContainsKey($row.ComponentName)) { $srcMap[$row.ComponentName] } else { '<shared>' }
        Add-DriftCode -Row $row -Code 'SHADOWS_SHARED_FUNCTION' `
            -Context "Function '$($row.ComponentName)' shadows the shared definition in '$shadowSrc'."
    }
}

# DUPLICATE_FUNCTION_DEFINITION: the same function name declared by more than
# one PS file across the codebase. Group all PS_FUNCTION / PS_FUNCTION_VARIANT
# DEFINITION rows by ComponentName; any group spanning two or more distinct
# files gets the drift code attached to every row in that group, with context
# naming the other files involved.
# DUPLICATE_FUNCTION_DEFINITION: the same function name declared by more than
# one PS file WITHIN THE SAME ZONE. Grouping is by zone + name: a function
# defined in two files of the same zone is a real runtime collision; the same
# name in two different zones is not (separate resolution universes, never
# loaded together). Any same-zone group spanning two or more distinct files
# gets the drift code on every row in that group.
$allFunctionDefRows = @($script:rows | Where-Object {
    ($_.ComponentType -eq 'PS_FUNCTION' -or $_.ComponentType -eq 'PS_FUNCTION_VARIANT') -and
    $_.ReferenceType -eq 'DEFINITION'
})
$functionDefsByKey = @{}
foreach ($row in $allFunctionDefRows) {
    $key = "$($row.Zone)|$($row.ComponentName)"
    if (-not $functionDefsByKey.ContainsKey($key)) {
        $functionDefsByKey[$key] = New-Object System.Collections.Generic.List[object]
    }
    [void]$functionDefsByKey[$key].Add($row)
}
foreach ($key in $functionDefsByKey.Keys) {
    $defRows = $functionDefsByKey[$key]
    $distinctFiles = @($defRows | ForEach-Object { $_.FileName } | Sort-Object -Unique)
    if ($distinctFiles.Count -lt 2) { continue }
    foreach ($defRow in $defRows) {
        $otherFiles = @($distinctFiles | Where-Object { $_ -ne $defRow.FileName })
        $otherList  = $otherFiles -join ', '
        Add-DriftCode -Row $defRow -Code 'DUPLICATE_FUNCTION_DEFINITION' `
            -Context "Function '$($defRow.ComponentName)' is also defined in: $otherList. Cross-file duplicate definitions in the same zone resolve unpredictably at runtime."
    }
}

# -- Output Boundary Validation --

Test-DriftCodesAgainstMasterTable -Rows $script:rows

# -- Occurrence Index Computation --

Write-Log "Computing occurrence_index for all rows..."
Set-OccurrenceIndices -Rows $script:rows

# -- Summary Output --

Write-Log ("Total rows generated: {0}" -f $script:rows.Count)

if ($script:rows.Count -gt 0) {
    $script:rows | Group-Object { "$($_.ComponentType) / $($_.ReferenceType) / $($_.Scope)" } |
        Sort-Object Count -Descending |
        Format-Table @{L='Component / Ref / Scope';E='Name'}, Count -AutoSize

    $driftedCount = @($script:rows | Where-Object { $_.DriftCodes }).Count
    Write-Log ("Rows with drift codes: {0} of {1} ({2:F1}%)" -f $driftedCount, $script:rows.Count, ($driftedCount / [double]$script:rows.Count * 100))
}

# -- Database Write --

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
    # Transitional shim: Invoke-AssetRegistryBulkInsert still takes the FK map
    # as object_name -> registry_id. Project it from the combined zone/scope
    # map (which now carries RegistryId) until the bulk insert is updated to
    # accept the combined shape directly, at which point this shim is removed.
    $objectRegistryMap = @{}
    foreach ($objName in $objectZoneScopeMap.Keys) {
        $objectRegistryMap[$objName] = $objectZoneScopeMap[$objName].RegistryId
    }

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

# -- Object_Registry Miss Report --

if ($objectRegistryMisses.Count -gt 0) {
    Write-Log ("Object_Registry registration gaps detected for {0} file(s):" -f $objectRegistryMisses.Count) 'WARN'
    foreach ($missing in ($objectRegistryMisses | Sort-Object)) {
        Write-Log ("  MISSING: $missing") 'WARN'
    }
    Write-Log "Add the file(s) above to dbo.Object_Registry to enable FK linkage on subsequent runs." 'WARN'
}

Write-Log "Done."
<#
.SYNOPSIS
    xFACts - Asset Registry HTML Populator

.DESCRIPTION
    Walks every .ps1 and .psm1 file under the Control Center route and
    helper directories, discovers HTML-emitting constructs (here-strings,
    StringBuilder sequences, and string-literal returns), and emits
    Asset_Registry rows plus CC_HTML_Spec.md drift codes for each
    catalogable construct. Implements its own HTML tokenizer that treats
    PowerShell interpolation as first-class, since HTML here lives inside
    PowerShell strings. Consumes shared infrastructure from
    xFACts-AssetRegistryFunctions.ps1. Runs after the CSS populator.

.PARAMETER Execute
    Required to actually delete the HTML rows from Asset_Registry and
    write the new row set. Without this flag, runs in preview mode.

.PARAMETER FileFilter
    Optional file-name filter for processing a single file or subset
    (e.g., -FileFilter 'BusinessServices.ps1' processes only that file).

.COMPONENT
    Tools.Utilities

.NOTES
    File Name : Populate-AssetRegistry-HTML.ps1
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
    FUNCTIONS: POWERSHELL AST PARSING
    FUNCTIONS: AST CONTEXT HELPERS
    FUNCTIONS: HTML EMISSION DISCOVERY
    FUNCTIONS: HTML TOKENIZER
    FUNCTIONS: ATTRIBUTE PARSER
    FUNCTIONS: CLASS-NAME SPLITTING AND VALIDATION
    FUNCTIONS: ID VALIDATION
    FUNCTIONS: OVERLAY CONSTRUCT DETECTION
    FUNCTIONS: EVENT HANDLER ANALYSIS
    FUNCTIONS: DATA-ACTION ATTRIBUTE VALIDATION
    FUNCTIONS: ROW EMITTERS
    FUNCTIONS: PAGE SHELL VALIDATION
    FUNCTIONS: STRUCTURE AND CHROME VALIDATORS
    FUNCTIONS: MAIN TOKEN WALKER
    FUNCTIONS: OVERLAY POST-WALK VALIDATION
    FUNCTIONS: DUPLICATE ID CHECK
    FUNCTIONS: ENGINE CARD VALIDATION
    FUNCTIONS: PAGE CHROME VALIDATION
    EXECUTION: SCRIPT EXECUTION
#>

<# ============================================================================
   CHANGELOG: CHANGE HISTORY
   ----------------------------------------------------------------------------
   Date-stamped change history. Each entry is one ISO date line followed by an
   indented description. Entries appear most-recent first.
   Prefix: (none)
   ============================================================================ #>

# 2026-06-02  Removed the local Get-PodeRoutes, Get-CommandAstName, and
#             Get-StringValueFromExpression definitions; these were lifted to
#             xFACts-AssetRegistryFunctions.ps1 so the HTML and JS populators
#             share one Add-PodeRoute -Path extraction implementation. Call
#             sites (Get-AddPodeRoutePathForScriptBlock and the main-walk route
#             discovery) now resolve to the shared versions. The now-empty
#             FUNCTIONS: ROUTE DISCOVERY section and its FILE ORGANIZATION entry
#             were removed.
# 2026-05-31  Converted to the Control Center PowerShell file format spec:
#             block-comment header and section banners, spec-mandated section
#             order, dedicated CHANGELOG section, single EXECUTION section
#             with sub-section markers, and leading purpose comments on
#             script-scope declarations. Made the per-row zone stamp
#             table-driven: zone now comes from dbo.Object_Registry via
#             Get-ObjectRegistryZoneScopeMap rather than a hardcoded 'cc'.
#             Dropped the separate Get-ObjectRegistryMap call and the
#             hand-rolled object_type query; the zone/scope map now carries
#             registry_id and object_type, so the file makes one
#             Object_Registry query. A transitional shim at the bulk-insert
#             call projects registry_id back to the flat map shape the bulk
#             insert still expects. Added FILE_NOT_REGISTERED for files
#             absent from Object_Registry.

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
   Dot-source the shared orchestrator and Asset Registry function libraries.
   Prefix: (none)
   ============================================================================ #>

. "$PSScriptRoot\xFACts-OrchestratorFunctions.ps1"
. "$PSScriptRoot\xFACts-AssetRegistryFunctions.ps1"

<# ============================================================================
   INITIALIZATION: SCRIPT INITIALIZATION
   ----------------------------------------------------------------------------
   Common script setup: connection context and logging.
   Prefix: (none)
   ============================================================================ #>

Initialize-XFActsScript -ScriptName 'Populate-AssetRegistry-HTML' -Execute:$Execute

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
   The Control Center root and the PS file roots scanned for embedded HTML.
   Prefix: (none)
   ============================================================================ #>

# Control Center root directory.
$CcRoot = 'E:\xFACts-ControlCenter'

# Roots scanned for HTML-emitting PS files (routes\ and modules\). Per-file
# classification (Route vs API vs Module) comes from Object_Registry at
# processing time, not from path or extension.
$PsScanRoots = @(
    @{ Path = "$CcRoot\scripts\routes";  Pattern = '*.ps1'  }
    @{ Path = "$CcRoot\scripts\modules"; Pattern = '*.psm1' }
)

<# ============================================================================
   CONSTANTS: SPEC CONSTANTS
   ----------------------------------------------------------------------------
   Closed sets the validators check against: recognized events, vendored JS
   libraries, HTML void elements, chrome IDs, platform data-* attributes, and
   the elements permitted to carry action attributes.
   Prefix: (none)
   ============================================================================ #>

# Closed event set. Used to validate the event name on data-action-<event>
# attributes. Inline on* attributes are forbidden entirely, regardless of
# event name.
$RecognizedEvents = @('click','change','input','submit','blur','focus','keydown','keyup')

# Vendored third-party JS libraries (locally-hosted under public/js/, not CDN).
# Recognized references, not drift: excluded from the single-script-tag count
# and exempt from the cc-shared.js src check. Closed set; adding requires a
# spec amendment.
$VendoredJsFiles = @('chart.min.js','chartjs-adapter-date-fns.min.js','xlsx.full.min.js')

# HTML void elements (per HTML5): cannot have content, never produce a closing
# tag. The walker's element-stack tracker skips pushing these as parent context.
$HtmlVoidElements = @(
    'area','base','br','col','embed','hr','img','input','link',
    'meta','param','source','track','wbr'
)

# Platform-owned data-cc-* attribute closed set. Only these data-cc-*
# names are valid; anything else fires UNREGISTERED_PLATFORM_DATA_ATTRIBUTE.
$PlatformDataAttributes = @(
    'data-cc-page',
    'data-cc-prefix'
)

# Elements permitted to carry data-action-<event> attributes.
$ActionPermittedTags = @('button','a','input','select','textarea')

# Overlay container classes also permitted to carry action attributes (the
# "click outside the dialog to close" carve-out).
$ActionPermittedOverlayClasses = @(
    'cc-modal-overlay',
    'cc-slide-overlay',
    'cc-slideup-overlay'
)

<# ============================================================================
   CONSTANTS: DRIFT DESCRIPTIONS
   ----------------------------------------------------------------------------
   Master table mapping every drift code this populator can emit to its
   human-readable description. Add-DriftCode validates against this table.
   Prefix: (none)
   ============================================================================ #>

$DriftDescriptions = [ordered]@{
    # Page shell codes (attached to HTML_FILE)
    'MALFORMED_DOCTYPE'                 = "The HTML document does not open with <!DOCTYPE html> on its own line in the required form."
    'MALFORMED_HTML_ROOT'               = "The root <html> element has attributes; attributes are not permitted on the root element."
    'MALFORMED_HEAD'                    = "The <head> element contains constructs other than <title> and <link> (e.g., inline <style>, <meta>, <script>)."
    'FORBIDDEN_HARDCODED_TITLE'         = "The <title> content is a hardcoded string instead of the `$browserTitle PowerShell variable substitution."
    'MISSING_BODY_SECTION_CLASS'        = "The <body> element does not declare a class=`"cc-section-<sectionKey>`" attribute."
    'MISSING_DATA_CC_PAGE'              = "The <body> element does not declare a data-cc-page=`"<slug>`" attribute."
    'MISSING_DATA_CC_PREFIX'            = "The <body> element does not declare a data-cc-prefix=`"<prefix>`" attribute."
    'FORBIDDEN_PAGE_PREFIXED_BODY_CLASS' = "The <body> class attribute contains a page-prefixed class; only cc-section-<key> and cc- prefixed chrome classes are permitted."
    'MISSING_NAV_SUBSTITUTION'          = "The first content inside <body> is not the `$navHtml substitution."
    'MISSING_HEADER_BAR'                = "The page header bar is missing as the first content after `$navHtml."
    'FORBIDDEN_HARDCODED_PAGE_HEADER'   = "The page header content is hardcoded instead of the `$headerHtml PowerShell variable substitution."
    'MISSING_BANNER_SUBSTITUTION'       = "The connection and page-error banner chrome is missing; the page shell does not include the `$bannerHtml substitution."
    'FORBIDDEN_LITERAL_BANNER'          = "A route declares a literal connection or page-error banner div; banners must be included via the `$bannerHtml substitution from Get-ChromeBannersHtml."
    'MALFORMED_BODY_CLOSE'              = "Content appears between the shared script reference and </body>."
    'MALFORMED_PAGE_SHELL_ORDER'        = "The mandated page-shell elements are not in the order shown in the spec template."
    'MALFORMED_PAGE_SHELL_WHITESPACE'   = "Adjacent mandated page-shell elements are not separated by exactly one blank line."
    'MALFORMED_ATTRIBUTE_ORDER'         = "Attributes on a mandated structural element are not in the order shown in the spec template."
    'MISSING_BROWSER_TITLE_VAR'         = "The route file does not declare `$browserTitle = Get-PageBrowserTitle ... before its HTML emission."
    'MISSING_NAV_HTML_VAR'              = "The route file does not declare `$navHtml = Get-NavBarHtml ... before its HTML emission."
    'MISSING_HEADER_HTML_VAR'           = "The route file does not declare `$headerHtml = Get-PageHeaderHtml ... before its HTML emission."
    'MISSING_BANNER_HTML_VAR'           = "The route file does not declare `$bannerHtml = Get-ChromeBannersHtml ... before its HTML emission."
    'FORBIDDEN_ROUTE_LOCAL_HELPER'      = "A function defined inside a route file's ScriptBlock returns HTML; route files emit HTML inline only, helpers live in modules."

    # Page chrome codes
    'MALFORMED_HEADER_BAR_STRUCTURE'    = "The page header bar's structure deviates from the mandated shape (outer container, left/right children, or required descendants)."
    'MALFORMED_REFRESH_INFO_STRUCTURE'  = "The refresh info block's structure deviates from the mandated shape (container, live indicator, status line, or refresh button)."
    'MALFORMED_ENGINE_ROW_STRUCTURE'    = "The engine row container's structure deviates from the mandated shape (outer container or non-card children)."
    'ENGINE_CARD_ORDER_MISMATCH'        = "Engine cards are not in declaration order matching Orchestrator.ProcessRegistry.cc_sort_order."
    'MALFORMED_ENGINE_CARD'             = "An engine card's structure deviates from the mandated form (outer attributes, body shape, label, bar, or countdown)."
    'MISSING_ENGINE_CARD_REGISTRATION'  = "An active scheduled process (run_mode = 1) has NULL values in cc_engine_slug, cc_engine_label, cc_page_route, or cc_sort_order."
    'ENGINE_SLUG_REGISTRY_MISMATCH'     = "The slug used in card IDs doesn't match Orchestrator.ProcessRegistry.cc_engine_slug for the corresponding process."
    'ENGINE_LABEL_REGISTRY_MISMATCH'    = "The label text in the engine label span doesn't match Orchestrator.ProcessRegistry.cc_engine_label."
    'ENGINE_CARD_PAGE_MISMATCH'         = "An engine card appears on a page whose route doesn't match Orchestrator.ProcessRegistry.cc_page_route."

    # Asset reference codes
    'MALFORMED_CSS_LINK'                = "A <link> element uses attributes beyond rel=`"stylesheet`" and href=`"...`", or has an incorrect form."
    'MALFORMED_PAGE_CSS_REFERENCE'      = "The page-specific CSS reference's href doesn't match /css/<page>.css form."
    'MALFORMED_SHARED_CSS_REFERENCE'    = "The shared CSS reference is not exactly <link rel=`"stylesheet`" href=`"/css/cc-shared.css`">."
    'CSS_REFERENCE_ORDER_VIOLATION'     = "The page-specific CSS reference does not appear before the shared reference."
    'UNEXPECTED_CSS_REFERENCE'          = "A page references more or fewer than two CSS files in <head>."
    'MISSING_SHARED_SCRIPT_TAG'         = "A page does not include the mandatory <script src=`"/js/cc-shared.js`"></script> tag as the last content in <body>."
    'UNEXPECTED_SCRIPT_TAG'             = "A page contains more than one <script> tag; exactly one is permitted."
    'WRONG_SCRIPT_SOURCE'               = "A <script> element's src attribute is not exactly `"/js/cc-shared.js`"."
    'MALFORMED_JS_SCRIPT'               = "A <script> element uses attributes beyond src, or has body content."
    'FORBIDDEN_HELPER_ASSET_REFERENCE'  = "A helper module function emits a <link> or <script> element; helpers do not declare asset references."

    # ID codes
    'CHROME_ID_REUSED_AS_LOCAL'         = "A page-local element carries a chrome ID."
    'MISSING_PREFIX_ID'                 = "A page-local ID does not begin with the page's prefix."
    'CROSS_PAGE_PREFIX_COLLISION'       = "A page-local ID begins with another page's registered prefix."
    'DUPLICATE_ID_DECLARATION'          = "The same ID value is declared more than once on a page."
    'MALFORMED_ID_VALUE'                = "An ID value contains characters other than lowercase letters, digits, and hyphens."
    'MALFORMED_SLIDEOUT_ID'             = "A slideout outer element ID does not follow <prefix>-slideout-<purpose> form."
    'MALFORMED_MODAL_ID'                = "A modal outer element ID does not follow <prefix>-modal-<purpose> form."
    'MALFORMED_SLIDEUP_ID'              = "A slide-up panel outer element ID does not follow <prefix>-slideup-<purpose> form."
    'MALFORMED_MODAL_STRUCTURE'         = "A modal's outer cc-modal-overlay is missing its nested .cc-dialog child, or the .cc-dialog is missing required child elements."
    'MALFORMED_SLIDEOUT_STRUCTURE'      = "A slideout's outer cc-slide-overlay is missing its nested .cc-dialog child, or the .cc-dialog is missing required child elements."
    'MALFORMED_SLIDEUP_STRUCTURE'       = "A slide-up panel's outer cc-slideup-overlay is missing its nested .cc-dialog child, or the .cc-dialog is missing required child elements."
    'MISSING_DIALOG_CLASS'              = "An overlay construct's inner .cc-dialog does not carry the matching secondary class (cc-dialog-modal inside a modal, cc-dialog-slide inside a slideout, cc-dialog-slideup inside a slide-up panel)."
    'MISSING_PANEL_PURPOSE_COMMENT'     = "An overlay construct is not preceded by an HTML purpose comment."
    'MISSING_OVERLAY_BACKDROP_CLOSE'    = "An overlay construct's outer element does not carry a data-action-click matching its .cc-dialog-close button's close action; a backdrop click will not dismiss the construct."
    'OVERLAY_BLOCK_NON_CONTIGUOUS'      = "A non-overlay element or non-purpose comment appears within the overlay block; only formatting whitespace and per-construct purpose comments are permitted between constructs."
    'MALFORMED_DOCK_STRUCTURE'          = "A dock element does not carry both cc-dialog and cc-dialog-dock, is missing its .cc-dialog-header or .cc-dialog-body, has them out of order, carries a .cc-dialog-actions footer, or its header does not contain exactly one .cc-dialog-back button followed by one .cc-dialog-title."
    'MALFORMED_DOCK_ID'                 = "A dock element ID does not follow <prefix>-dock-<purpose> form."
    'FORBIDDEN_HELPER_PAGE_PREFIX_ID'   = "A helper module function emits HTML with a page-prefixed ID."
    'FORBIDDEN_HELPER_NON_CHROME_ID'    = "A helper module function emits an ID that is not cc- prefixed; helper-emitted IDs are shared chrome and must carry the cc- prefix."

    # Class attribute codes
    'MALFORMED_CLASS_VALUE_WHITESPACE'  = "A class attribute value contains multiple consecutive spaces, leading/trailing whitespace, or tabs."
    'MALFORMED_CLASS_NAME'              = "A class name contains characters other than lowercase letters, digits, and hyphens."
    'DUPLICATE_CLASS_IN_VALUE'          = "The same class name appears more than once in the same class attribute."
    'CLASS_PREFIX_MISMATCH'             = "A class name does not carry the page prefix or cc- prefix."
    'FORBIDDEN_DYNAMIC_CLASS_PATTERN'   = "A dynamic class attribute does not use the array-join pattern (a single fully-resolved variable holding the joined class string)."
    'FORBIDDEN_HELPER_PAGE_PREFIX_CLASS' = "A helper module function emits a page-prefixed class."

    # Action attribute codes
    'UNKNOWN_EVENT_TYPE'                = "A data-action-<event> attribute names an event not in the recognized closed set."
    'MALFORMED_ACTION_VALUE'            = "A data-action-<event> attribute value contains characters other than lowercase letters, digits, and hyphens."
    'ACTION_PREFIX_MISMATCH'            = "A data-action-<event> value does not carry the page prefix or cc- prefix."
    'UNRESOLVED_DATA_ACTION'            = "A data-action-<event> value has no matching entry in the corresponding dispatch table."
    'ACTION_ON_NON_INTERACTIVE_ELEMENT' = "A data-action-<event> attribute appears on an element not permitted to carry one (not an interactive element and not an overlay container)."
    'ORPHANED_ACTION_ARGUMENT'          = "An argument attribute appears on an element that has no data-action-<event> attribute."
    'ARGUMENT_PREFIX_MISMATCH'          = "An argument attribute name does not carry the same prefix as its parent element's action value."
    'ARGUMENT_NAME_COLLIDES_WITH_EVENT' = "An argument attribute name matches an event name from the recognized event set."
    'MALFORMED_ACTION_ARGUMENT_NAME'    = "An argument attribute name contains characters other than lowercase letters, digits, and hyphens after the data-action-<prefix>- prefix."
    'FORBIDDEN_INLINE_ACTION_ARGUMENT_INTERPOLATION' = "An argument attribute value mixes static text with PowerShell interpolation."
    'FORBIDDEN_HELPER_PAGE_ACTION'      = "A helper module function emits a page-prefixed action value."
    'FORBIDDEN_HELPER_PAGE_ACTION_ARGUMENT' = "A helper module function emits an argument attribute whose interpolated value references state outside the helper's parameters and foreach iterators."

    # data-* attribute codes
    'MALFORMED_DATA_ATTRIBUTE_NAME'     = "A data-* attribute name is not in the platform-owned set and does not begin with data-<page-prefix>-."
    'UNREGISTERED_PLATFORM_DATA_ATTRIBUTE' = "A data-cc-* attribute name is not in the platform-owned closed set."
    'FORBIDDEN_INLINE_DATA_INTERPOLATION' = "A data-* attribute value mixes static text with PowerShell interpolation."
    'FORBIDDEN_HELPER_PAGE_DATA_ATTRIBUTE' = "A helper module function emits a data-* attribute with a page-specific prefix."

    # Text content codes
    'FORBIDDEN_TEXT_INTERPOLATION'      = "Text content uses a forbidden interpolation pattern (mixed static text with interpolation, or multiple top-level interpolations)."
    'EMPTY_DISPLAY_TEXT'                = "A user-facing attribute (title, placeholder, aria-label, alt) is declared with an empty value."

    # SVG codes
    'MALFORMED_SVG_INTERPOLATION'       = "An SVG element's outer markup contains forbidden interpolation patterns."

    # Comment codes
    'MALFORMED_COMMENT_DASHES'          = "An HTML comment body contains '--' other than the closing -->."
    'FORBIDDEN_COMMENT_INTERPOLATION'   = "An HTML comment contains PowerShell variable interpolation."
    'MALFORMED_COMMENT_UNCLOSED'        = "An HTML comment's opening <!-- does not have a matching closing -->."

    # Inline asset block codes
    'FORBIDDEN_INLINE_STYLE_BLOCK'      = "A <style> block appears in HTML markup outside SVG. Inline style blocks are forbidden."
    'FORBIDDEN_INLINE_SCRIPT_BLOCK'     = "A <script> element contains body content; only the asset reference form <script src=`"...`"></script> is permitted."
    'FORBIDDEN_INLINE_STYLE_ATTRIBUTE'  = "An element carries an inline style=`"...`" attribute."

    # Inline event handler codes (umbrella + shapes)
    'FORBIDDEN_INLINE_EVENT_HANDLER'    = "An element carries an inline on* event handler attribute. Inline event handlers are forbidden; use data-action-<event> attributes routed through the bootloader dispatch table."
    'MULTIPLE_HANDLER_STATEMENTS'       = "An event handler attribute contains multiple statements."
    'INLINE_HANDLER_EXPRESSION'         = "An event handler attribute contains expressions other than a single function call."
    'MALFORMED_HANDLER_CALL'            = "An event handler's function call has whitespace between the function name and the opening parenthesis."
    'TRAILING_HANDLER_SEMICOLON'        = "An event handler attribute ends with a trailing semicolon."
    'FORBIDDEN_REVEALING_MODULE_CALL'   = "An event handler calls a function via dotted property access."
    'FORBIDDEN_BUILTIN_METHOD_CALL'     = "An event handler calls a method on a built-in object."
    'HANDLER_FUNCTION_NAME_MISMATCH'    = "An event handler's function name is not registered as chrome and does not match the page's prefix."
    'FORBIDDEN_EVENT_METHOD_CALL'       = "An event handler calls a method on the event object."
    'FORBIDDEN_HANDLER_CONDITIONAL'     = "An event handler contains conditional logic."
    'FORBIDDEN_INLINE_DOM_OPERATION'    = "An event handler performs DOM manipulation inline."
    'FORBIDDEN_INLINE_ASSIGNMENT'       = "An event handler contains assignment expressions."
    'FORBIDDEN_JAVASCRIPT_PROTOCOL'     = "An event handler uses the javascript: pseudo-protocol."
    'FORBIDDEN_ARGUMENT_EXPRESSION'     = "An event handler argument is an expression other than a literal, this, or this.<property>."
    'MALFORMED_ARGUMENT_QUOTING'        = "A string literal argument uses double quotes that conflict with the surrounding attribute value's quoting."
    'MALFORMED_ARGUMENT_LIST'           = "Multiple arguments are not separated by ', ' (comma followed by single space)."
    'FORBIDDEN_HELPER_PAGE_FUNCTION_CALL' = "A helper module function emits an event handler that calls a page-prefixed function."

    # File-level infrastructure codes
    'FILE_NOT_REGISTERED'               = "The file has no active row in Object_Registry, so its zone and scope could not be determined. Every scanned file must be registered; add it to dbo.Object_Registry. Rows from this file carry zone and scope of '<undefined>'."
}
<# ============================================================================
   VARIABLES: SCRIPT-SCOPE STATE
   ----------------------------------------------------------------------------
   Row collection, dedupe tracker, per-file walk context, and the
   classification / prefix lookup maps loaded once at startup.
   Prefix: (none)
   ============================================================================ #>

# Row collection accumulated across all files and bulk-inserted at the end.
$script:rows       = New-Object System.Collections.Generic.List[object]

# Dedupe tracker. The helpers reference this set directly via Test-AddDedupeKey.
$script:dedupeKeys = New-Object 'System.Collections.Generic.HashSet[string]'

# Per-file HTML_FILE row references for cross-pass attachment of page-shell
# drift codes. Page-shell drift codes are file-level concerns.
$script:htmlFileRowByFile = @{}

# Bare filename of the file currently being walked (e.g., 'BusinessServices.ps1').
$script:CurrentFile         = $null

# Full path of the file currently being walked.
$script:CurrentFullPath     = $null

# Object_Registry classification of the current file: 'Route', 'API', 'Module', or $null.
$script:CurrentRegisteredType = $null

# cc_prefix for the current file's component, or $null.
$script:CurrentCcPrefix     = $null

# Zone for the current file from Object_Registry, or '<undefined>' on a registration miss.
$script:CurrentFileZone     = $null

# Per-file Object_Registry classification map, populated once at startup from
# Get-ObjectRegistryZoneScopeMap: object_name -> @{ RegistryId; Zone; Scope;
# ScopeTier; ObjectType }. A file absent from this map is a registration gap.
$script:zoneScopeMap        = @{}

# Per-file cc_prefix lookup map. Populated once at startup from
# Component_Registry (a separate source from Object_Registry).
$script:ccPrefixByFile      = @{}

# Orchestrator.ProcessRegistry rows for engine card validation. Loaded
# once at startup; the per-file walk queries this list when an engine
# card is encountered.
$script:processRegistryRows = @()

# Per-page known prefixes from Component_Registry, used for cross-page
# prefix collision detection on IDs.
$script:knownPagePrefixes   = New-Object 'System.Collections.Generic.HashSet[string]'

<# ============================================================================
   FUNCTIONS: POWERSHELL AST PARSING
   ----------------------------------------------------------------------------
   Parse a PS file into an AST with the native PowerShell parser.
   Prefix: (none)
   ============================================================================ #>

# Parse a PowerShell file via the built-in Parser. Returns the AST, tokens,
# parse errors, source, and line count. Returns $null only on file-read
# failure; parse errors are non-fatal (the AST is still returned).
function Invoke-HtmlPsParse {
    param([Parameter(Mandatory)][string]$FilePath)

    try {
        $source = Get-Content -Path $FilePath -Raw -Encoding UTF8
        if (-not $source) { $source = '' }

        $tokens = $null
        $parseErrors = $null

        $ast = [System.Management.Automation.Language.Parser]::ParseInput(
            $source,
            $FilePath,
            [ref]$tokens,
            [ref]$parseErrors
        )

        if ($parseErrors -and $parseErrors.Count -gt 0) {
            foreach ($e in $parseErrors) {
                $loc = if ($e.Extent) {
                    "line $($e.Extent.StartLineNumber):$($e.Extent.StartColumnNumber)"
                } else { 'unknown' }
                Write-Log "PS parse error in ${FilePath} at ${loc}: $($e.Message)" 'WARN'
            }
        }

        $lineCount = ($source -split "`n").Count

        return @{
            Ast         = $ast
            Tokens      = $tokens
            ParseErrors = $parseErrors
            Source      = $source
            LineCount   = $lineCount
        }
    }
    catch {
        Write-Log "Exception during PS parse of ${FilePath}: $($_.Exception.Message)" 'ERROR'
        return $null
    }
}

<# ============================================================================
   FUNCTIONS: AST CONTEXT HELPERS
   ----------------------------------------------------------------------------
   Resolve the enclosing function and caller-given variable names for an
   AST node, used to scope helper-emission argument validation.
   Prefix: (none)
   ============================================================================ #>

# Look up the enclosing function name for an AST node by walking its parent
# chain to a FunctionDefinitionAst or an Add-PodeRoute -ScriptBlock. Returns
# the function name, a '<route:/path>' marker for route handlers, or $null at
# file scope.
function Get-EnclosingPsContext {
    param($Node)
    if ($null -eq $Node) { return $null }

    $cursor = $Node
    while ($null -ne $cursor) {
        if ($cursor -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
            return $cursor.Name
        }
        if ($cursor -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
            $routePath = Get-AddPodeRoutePathForScriptBlock -ScriptBlockAst $cursor
            if ($null -ne $routePath) {
                return "<route:$routePath>"
            }
        }
        $cursor = $cursor.Parent
    }
    return $null
}

# Returns the caller-given variable names (no leading $) in a function:
# declared parameters plus foreach iterator names. Foreach iterators count
# as caller-given because that is the contract a well-formed helper enforces.
function Get-CallerGivenVariableNames {
    param($FunctionDefinitionAst)
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    if ($null -eq $FunctionDefinitionAst) { return $set }
    if (-not ($FunctionDefinitionAst -is [System.Management.Automation.Language.FunctionDefinitionAst])) {
        return $set
    }

    # Parameter names. PowerShell exposes parameters via two paths:
    #   1. function Foo([string]$Bar, [int]$Baz) { ... }
    #      -> FunctionDefinitionAst.Parameters
    #   2. function Foo { param([string]$Bar, [int]$Baz) ... }
    #      -> FunctionDefinitionAst.Body.ParamBlock.Parameters
    $paramLists = @()
    if ($null -ne $FunctionDefinitionAst.Parameters) {
        $paramLists += ,$FunctionDefinitionAst.Parameters
    }
    if ($null -ne $FunctionDefinitionAst.Body -and $null -ne $FunctionDefinitionAst.Body.ParamBlock -and $null -ne $FunctionDefinitionAst.Body.ParamBlock.Parameters) {
        $paramLists += ,$FunctionDefinitionAst.Body.ParamBlock.Parameters
    }
    foreach ($plist in $paramLists) {
        foreach ($p in $plist) {
            if ($null -ne $p.Name -and $null -ne $p.Name.VariablePath -and -not [string]::IsNullOrEmpty($p.Name.VariablePath.UserPath)) {
                [void]$set.Add($p.Name.VariablePath.UserPath)
            }
        }
    }

    # Foreach iterator names. Walk the function body's AST and collect
    # every ForEachStatementAst's iterator variable.
    if ($null -ne $FunctionDefinitionAst.Body) {
        $foreachNodes = $FunctionDefinitionAst.Body.FindAll(
            { param($n) $n -is [System.Management.Automation.Language.ForEachStatementAst] },
            $true
        )
        foreach ($fe in $foreachNodes) {
            if ($null -ne $fe.Variable -and $null -ne $fe.Variable.VariablePath -and -not [string]::IsNullOrEmpty($fe.Variable.VariablePath.UserPath)) {
                [void]$set.Add($fe.Variable.VariablePath.UserPath)
            }
        }
    }

    return $set
}

# Walk up from an AST node to its enclosing FunctionDefinitionAst.
# Returns the FunctionDefinitionAst, or $null if the node is not inside a
# function definition (e.g., top-level emissions, route ScriptBlocks).
function Get-EnclosingFunctionDefinitionAst {
    param($Node)
    if ($null -eq $Node) { return $null }
    $cursor = $Node
    while ($null -ne $cursor) {
        if ($cursor -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
            return $cursor
        }
        $cursor = $cursor.Parent
    }
    return $null
}

# If the supplied ScriptBlockExpressionAst is the -ScriptBlock argument to
# an Add-PodeRoute call, return that call's -Path value. Otherwise return
# $null.
function Get-AddPodeRoutePathForScriptBlock {
    param([Parameter(Mandatory)][System.Management.Automation.Language.ScriptBlockExpressionAst]$ScriptBlockAst)

    $parent = $ScriptBlockAst.Parent
    if ($null -eq $parent) { return $null }

    while ($null -ne $parent -and -not ($parent -is [System.Management.Automation.Language.CommandAst])) {
        $parent = $parent.Parent
        if ($parent -is [System.Management.Automation.Language.ScriptBlockAst]) { return $null }
    }
    if ($null -eq $parent) { return $null }

    $cmd = $parent
    if ($cmd.CommandElements.Count -lt 1) { return $null }
    $cmdName = Get-CommandAstName -CommandAst $cmd
    if ($cmdName -ne 'Add-PodeRoute') { return $null }

    $elements = $cmd.CommandElements
    for ($i = 0; $i -lt $elements.Count; $i++) {
        $el = $elements[$i]
        if ($el -is [System.Management.Automation.Language.CommandParameterAst]) {
            if ($el.ParameterName -ieq 'Path') {
                if ($null -ne $el.Argument) {
                    return Get-StringValueFromExpression -Expr $el.Argument
                }
                if ($i + 1 -lt $elements.Count) {
                    return Get-StringValueFromExpression -Expr $elements[$i + 1]
                }
            }
        }
    }
    return $null
}

<# ============================================================================
   FUNCTIONS: HTML EMISSION DISCOVERY
   ----------------------------------------------------------------------------
   Find HTML-emitting constructs in a parsed file: here-strings, builder
   Append sequences, and string-literal returns whose content is HTML.
   Prefix: (none)
   ============================================================================ #>

# Each discovered emission is a logical object carrying .Text, .StartLine,
# .EndLine, .FunctionName ('<route:/path>' for route ScriptBlocks, $null at top
# level), .Pattern (HereString|StringBuilder|StringLiteral), and .NodeRef.

# Does this string look like an HTML emission? Short-circuits on strong HTML
# signals (DOCTYPE, <html>, comments, class=, id=), else requires two tag-like
# openers with a matching open/close pair. XML payloads ('<?xml') are rejected
# (those belong to the PS populator's catalog).
function Test-LooksLikeHtmlEmission {
    param([string]$Text)
    if ($null -eq $Text) { return $false }
    if ($Text.Length -lt 16) { return $false }

    # Explicit rejection: XML payloads (declaration-led). XML emissions
    # belong to the PS populator's catalog of helper functions; the HTML
    # populator does not catalog XML markup.
    if ($Text -match '^\s*<\?xml\b') { return $false }

    # Strong signals - any one is sufficient.
    if ($Text -match '(?i)<!DOCTYPE\s+html')   { return $true }
    if ($Text -match '(?i)<html\b')            { return $true }
    if ($Text -match '(?im)^\s*<!--')          { return $true }
    if ($Text -match '\bclass\s*=\s*["'']')    { return $true }
    if ($Text -match '\bid\s*=\s*["''][a-z]')  { return $true }

    # Structural signal: at least two tag-like openers AND at least one
    # opening tag has a matching closing tag of the same name.
    $openTags = [regex]::Matches($Text, '<([a-zA-Z][a-zA-Z0-9]*)\b')
    if ($openTags.Count -lt 2) {
        # Single-tag emissions (e.g., '<script src="/js/cc-shared.js"></script>')
        # qualify only when the single tag has a matching closer in the
        # same string OR is recognized as a self-closing form.
        if ($openTags.Count -eq 1) {
            $name = $openTags[0].Groups[1].Value.ToLower()
            $closePattern = "</$([regex]::Escape($name))\s*>"
            if ($Text -match $closePattern) { return $true }
        }
        return $false
    }

    $tagNames = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($m in $openTags) {
        [void]$tagNames.Add($m.Groups[1].Value.ToLower())
    }
    foreach ($name in $tagNames) {
        $closePattern = "</$([regex]::Escape($name))\s*>"
        if ($Text -match $closePattern) {
            return $true
        }
    }

    return $false
}

# Walk the AST and collect HereString-style HTML emissions.
function Get-HereStringEmissions {
    param([Parameter(Mandatory)]$Ast)

    $emissions = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Ast) { return $emissions }

    $allStrings = $Ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
        $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst]
    }, $true)

    foreach ($node in $allStrings) {
        $sct = $node.StringConstantType
        $isHereString = ($sct -eq 'SingleQuotedHereString' -or $sct -eq 'DoubleQuotedHereString')
        if (-not $isHereString) { continue }

        $text = $node.Value
        if (-not (Test-LooksLikeHtmlEmission -Text $text)) { continue }

        $startLine = if ($node.Extent) { $node.Extent.StartLineNumber } else { 0 }
        $endLine   = if ($node.Extent) { $node.Extent.EndLineNumber }   else { $startLine }
        $context   = Get-EnclosingPsContext -Node $node

        $emissions.Add([ordered]@{
            Text         = $text
            StartLine    = $startLine
            EndLine      = $endLine
            FunctionName = $context
            Pattern      = 'HereString'
            NodeRef      = $node
        })
    }

    return $emissions
}

# Collect StringBuilder-style HTML emissions (Append/AppendLine/AppendFormat
# on a StringBuilder variable), grouped by enclosing function and variable.
function Get-StringBuilderEmissions {
    param([Parameter(Mandatory)]$Ast)

    $emissions = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Ast) { return $emissions }

    $allInvokes = $Ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst]
    }, $true)

    $buckets = @{}

    foreach ($inv in $allInvokes) {
        if ($null -eq $inv.Member) { continue }
        $memberName = $null
        if ($inv.Member -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
            $memberName = $inv.Member.Value
        }
        if ([string]::IsNullOrEmpty($memberName)) { continue }
        if ($memberName -notin @('AppendLine','Append','AppendFormat')) { continue }

        if (-not ($inv.Expression -is [System.Management.Automation.Language.VariableExpressionAst])) { continue }
        $varName = $inv.Expression.VariablePath.UserPath
        if ([string]::IsNullOrEmpty($varName)) { continue }

        $context = Get-EnclosingPsContext -Node $inv
        if ([string]::IsNullOrEmpty($context)) { continue }

        if ($null -eq $inv.Arguments -or $inv.Arguments.Count -eq 0) { continue }
        $arg = $inv.Arguments[0]
        $argText = Get-StringValueFromExpression -Expr $arg
        if ($null -eq $argText) { continue }

        $bucketKey = "$context|$varName"
        if (-not $buckets.ContainsKey($bucketKey)) {
            $buckets[$bucketKey] = New-Object System.Collections.Generic.List[object]
        }
        [void]$buckets[$bucketKey].Add([ordered]@{
            FunctionName = $context
            VariableName = $varName
            Method       = $memberName
            ArgText      = $argText
            StartLine    = if ($inv.Extent) { $inv.Extent.StartLineNumber } else { 0 }
            EndLine      = if ($inv.Extent) { $inv.Extent.EndLineNumber }   else { 0 }
            NodeRef      = $inv
        })
    }

    foreach ($key in $buckets.Keys) {
        $items = @($buckets[$key] | Sort-Object { $_.StartLine })
        if ($items.Count -eq 0) { continue }

        $sb = New-Object System.Text.StringBuilder
        foreach ($item in $items) {
            [void]$sb.Append($item.ArgText)
            if ($item.Method -eq 'AppendLine') {
                [void]$sb.Append("`n")
            }
        }
        $text = $sb.ToString()

        if (-not (Test-LooksLikeHtmlEmission -Text $text)) { continue }

        $first = $items[0]
        $last  = $items[$items.Count - 1]

        $emissions.Add([ordered]@{
            Text         = $text
            StartLine    = $first.StartLine
            EndLine      = $last.EndLine
            FunctionName = $first.FunctionName
            Pattern      = 'StringBuilder'
            NodeRef      = $first.NodeRef
        })
    }

    return $emissions
}

# Collect plain string-literal HTML emissions: non-here-string quoted strings
# (a function's return/last statement) whose content passes the HTML sniff and
# whose enclosing context is a named function (not a route ScriptBlock).
function Get-StringLiteralEmissions {
    param([Parameter(Mandatory)]$Ast)

    $emissions = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Ast) { return $emissions }

    $allStrings = $Ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
        $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst]
    }, $true)

    foreach ($node in $allStrings) {
        $sct = $node.StringConstantType
        # Skip here-strings (already handled by Get-HereStringEmissions)
        if ($sct -eq 'SingleQuotedHereString' -or $sct -eq 'DoubleQuotedHereString') { continue }

        $text = $node.Value
        if (-not (Test-LooksLikeHtmlEmission -Text $text)) { continue }

        # Require an enclosing named function context. Plain string literals
        # at file scope or inside route scriptblocks aren't catalogable as
        # standalone HTML emissions - they'd be substring concatenation
        # fragments inside a larger here-string that's already cataloged,
        # or junk SQL/data strings that happened to pass the sniff.
        $context = $null
        $cursor = $node.Parent
        $insideRouteScriptBlock = $false
        while ($null -ne $cursor) {
            if ($cursor -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
                $context = $cursor.Name
                break
            }
            if ($cursor -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
                $routePath = Get-AddPodeRoutePathForScriptBlock -ScriptBlockAst $cursor
                if ($null -ne $routePath) {
                    $insideRouteScriptBlock = $true
                    break
                }
            }
            $cursor = $cursor.Parent
        }
        if ($insideRouteScriptBlock) { continue }
        if ([string]::IsNullOrEmpty($context)) { continue }

        $startLine = if ($node.Extent) { $node.Extent.StartLineNumber } else { 0 }
        $endLine   = if ($node.Extent) { $node.Extent.EndLineNumber }   else { $startLine }

        $emissions.Add([ordered]@{
            Text         = $text
            StartLine    = $startLine
            EndLine      = $endLine
            FunctionName = $context
            Pattern      = 'StringLiteral'
            NodeRef      = $node
        })
    }

    return $emissions
}

# Combined emission discovery across all three patterns. Returns one
# source-line-ordered list per file.
function Get-HtmlEmissions {
    param([Parameter(Mandatory)]$Ast)

    $hereStrings    = @(Get-HereStringEmissions    -Ast $Ast)
    $stringBuilders = @(Get-StringBuilderEmissions -Ast $Ast)
    $stringLiterals = @(Get-StringLiteralEmissions -Ast $Ast)

    $combined = New-Object System.Collections.Generic.List[object]
    foreach ($e in $hereStrings)    { [void]$combined.Add($e) }
    foreach ($e in $stringBuilders) { [void]$combined.Add($e) }
    foreach ($e in $stringLiterals) { [void]$combined.Add($e) }

    return @($combined | Sort-Object { $_.StartLine })
}

<# ============================================================================
   FUNCTIONS: HTML TOKENIZER
   ----------------------------------------------------------------------------
   Tokenize embedded HTML into tags, text, comments, and entities while
   treating PowerShell interpolation as a first-class token concept.
   Prefix: (none)
   ============================================================================ #>

# Tokenize embedded HTML into tag, text, comment, and entity tokens, tracking
# PowerShell interpolation ($var, ${name}, $(expr)) as first-class 'PsInterp'
# tokens preserved verbatim. StartTag/SelfClose tokens carry .AttrText for
# later attribute parsing; all tokens carry source-relative position info.
function ConvertTo-HtmlTokens {
    param([Parameter(Mandatory)][string]$Text)

    $tokens = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrEmpty($Text)) { return $tokens }

    $i = 0
    $n = $Text.Length
    $line = 0
    $col = 1

    # Helper local: extract a substring of length k starting at p without
    # crashing past end of string.
    $safeSubstring = {
        param([int]$p, [int]$k)
        if ($p -ge $n) { return '' }
        $remaining = $n - $p
        if ($k -gt $remaining) { $k = $remaining }
        return $Text.Substring($p, $k)
    }

    while ($i -lt $n) {
        $ch = $Text[$i]

        # HTML comment: <!-- ... -->
        if ($ch -eq '<' -and (& $safeSubstring $i 4) -eq '<!--') {
            $startLine = $line
            $startCol  = $col
            $end = $Text.IndexOf('-->', $i + 4)
            if ($end -lt 0) {
                # Unclosed comment. Capture everything to end-of-input with
                # an Unclosed flag the comment validator reads.
                $body = $Text.Substring($i)
                $tokens.Add([ordered]@{
                    Kind        = 'Comment'
                    Raw         = $body
                    Body        = $body.Substring(4)
                    LineOffset  = $startLine
                    ColumnStart = $startCol
                    Unclosed    = $true
                })
                while ($i -lt $n) {
                    if ($Text[$i] -eq "`n") { $line++; $col = 1 } else { $col++ }
                    $i++
                }
                continue
            }
            $raw = $Text.Substring($i, $end - $i + 3)
            $body = $Text.Substring($i + 4, $end - $i - 4)
            $tokens.Add([ordered]@{
                Kind        = 'Comment'
                Raw         = $raw
                Body        = $body
                LineOffset  = $startLine
                ColumnStart = $startCol
                Unclosed    = $false
            })
            for ($k = 0; $k -lt $raw.Length; $k++) {
                if ($raw[$k] -eq "`n") { $line++; $col = 1 } else { $col++ }
                $i++
            }
            continue
        }

        # DOCTYPE: <!DOCTYPE html> (case-insensitive sniff)
        if ($ch -eq '<' -and (& $safeSubstring $i 9) -match '^(?i)<!doctype') {
            $startLine = $line
            $startCol  = $col
            $end = $Text.IndexOf('>', $i)
            if ($end -lt 0) {
                $raw = $Text.Substring($i)
                $tokens.Add([ordered]@{
                    Kind        = 'Doctype'
                    Raw         = $raw
                    LineOffset  = $startLine
                    ColumnStart = $startCol
                })
                while ($i -lt $n) {
                    if ($Text[$i] -eq "`n") { $line++; $col = 1 } else { $col++ }
                    $i++
                }
                continue
            }
            $raw = $Text.Substring($i, $end - $i + 1)
            $tokens.Add([ordered]@{
                Kind        = 'Doctype'
                Raw         = $raw
                LineOffset  = $startLine
                ColumnStart = $startCol
            })
            for ($k = 0; $k -lt $raw.Length; $k++) {
                if ($raw[$k] -eq "`n") { $line++; $col = 1 } else { $col++ }
                $i++
            }
            continue
        }

        # Closing tag: </name>
        if ($ch -eq '<' -and ($i + 1) -lt $n -and $Text[$i + 1] -eq '/') {
            $startLine = $line
            $startCol  = $col
            $end = $Text.IndexOf('>', $i)
            if ($end -lt 0) {
                $tokens.Add([ordered]@{
                    Kind        = 'Text'
                    Raw         = $ch
                    LineOffset  = $line
                    ColumnStart = $col
                })
                if ($ch -eq "`n") { $line++; $col = 1 } else { $col++ }
                $i++
                continue
            }
            $raw = $Text.Substring($i, $end - $i + 1)
            $nameRaw = $raw.Substring(2, $raw.Length - 3).Trim()
            $tokens.Add([ordered]@{
                Kind        = 'EndTag'
                Raw         = $raw
                TagName     = $nameRaw.ToLower()
                LineOffset  = $startLine
                ColumnStart = $startCol
            })
            for ($k = 0; $k -lt $raw.Length; $k++) {
                if ($raw[$k] -eq "`n") { $line++; $col = 1 } else { $col++ }
                $i++
            }
            continue
        }

        # Opening tag / self-close: <name attrs...> or <name attrs.../>
        if ($ch -eq '<' -and ($i + 1) -lt $n -and ($Text[$i + 1] -match '[A-Za-z]')) {
            $startLine = $line
            $startCol  = $col

            # Find end of tag, respecting attribute values that contain '>'
            # inside quoted strings.
            $j = $i + 1
            $inQuote = $null
            while ($j -lt $n) {
                $c2 = $Text[$j]
                if ($null -ne $inQuote) {
                    if ($c2 -eq $inQuote) { $inQuote = $null }
                } else {
                    if ($c2 -eq '"' -or $c2 -eq "'") { $inQuote = $c2 }
                    elseif ($c2 -eq '>') { break }
                }
                $j++
            }
            if ($j -ge $n) {
                $tokens.Add([ordered]@{
                    Kind        = 'Text'
                    Raw         = $Text.Substring($i)
                    LineOffset  = $line
                    ColumnStart = $col
                })
                while ($i -lt $n) {
                    if ($Text[$i] -eq "`n") { $line++; $col = 1 } else { $col++ }
                    $i++
                }
                continue
            }

            $raw = $Text.Substring($i, $j - $i + 1)
            $inner = $raw.Substring(1, $raw.Length - 2)
            $isSelfClose = $inner -match '/\s*$'
            if ($isSelfClose) {
                $inner = $inner.Substring(0, $inner.Length - ($inner.Length - $inner.TrimEnd().Length) - 1).TrimEnd()
            }

            $tagName = $inner
            $wsIdx = $inner.IndexOfAny(@(' ', "`t", "`n", "`r"))
            if ($wsIdx -ge 0) { $tagName = $inner.Substring(0, $wsIdx) }
            $tagName = $tagName.Trim().ToLower()

            $attrText = ''
            if ($wsIdx -ge 0) { $attrText = $inner.Substring($wsIdx + 1).Trim() }

            $tokens.Add([ordered]@{
                Kind        = $(if ($isSelfClose) { 'SelfClose' } else { 'StartTag' })
                Raw         = $raw
                TagName     = $tagName
                AttrText    = $attrText
                LineOffset  = $startLine
                ColumnStart = $startCol
            })
            for ($k = 0; $k -lt $raw.Length; $k++) {
                if ($raw[$k] -eq "`n") { $line++; $col = 1 } else { $col++ }
                $i++
            }
            continue
        }

        # HTML entity: &name; &#N; &#xN;
        # Test before PowerShell interpolation because '&' is unambiguous.
        if ($ch -eq '&' -and ($i + 1) -lt $n) {
            $semi = $Text.IndexOf(';', $i + 1)
            if ($semi -gt $i -and ($semi - $i) -le 12) {
                $entityBody = $Text.Substring($i + 1, $semi - $i - 1)
                $isNamed   = $entityBody -match '^[A-Za-z][A-Za-z0-9]*$'
                $isDecimal = $entityBody -match '^#[0-9]+$'
                $isHex     = $entityBody -match '^#[Xx][0-9A-Fa-f]+$'
                if ($isNamed -or $isDecimal -or $isHex) {
                    $raw = $Text.Substring($i, $semi - $i + 1)
                    $form = if ($isNamed) { 'Named' }
                            elseif ($isDecimal) { 'Numeric' }
                            else { 'Hex' }
                    $tokens.Add([ordered]@{
                        Kind        = 'Entity'
                        Raw         = $raw
                        Body        = $entityBody
                        Form        = $form
                        LineOffset  = $line
                        ColumnStart = $col
                    })
                    for ($k = 0; $k -lt $raw.Length; $k++) {
                        if ($raw[$k] -eq "`n") { $line++; $col = 1 } else { $col++ }
                        $i++
                    }
                    continue
                }
            }
            # Not a valid entity - fall through to Text handling.
        }

        # PS interpolation: $var, ${name}, $(...). An unparseable $-led form is
        # consumed as a single literal char below, so the text accumulator's
        # $-detection cannot re-trigger on it and infinite-loop.
        $consumedAsInterp = $false
        if ($ch -eq '$' -and ($i + 1) -lt $n) {
            $next = $Text[$i + 1]
            if ($next -eq '{') {
                $end = $Text.IndexOf('}', $i + 2)
                if ($end -gt 0) {
                    $raw = $Text.Substring($i, $end - $i + 1)
                    $tokens.Add([ordered]@{
                        Kind        = 'PsInterp'
                        Raw         = $raw
                        Form        = 'Braced'
                        LineOffset  = $line
                        ColumnStart = $col
                    })
                    for ($k = 0; $k -lt $raw.Length; $k++) {
                        if ($raw[$k] -eq "`n") { $line++; $col = 1 } else { $col++ }
                        $i++
                    }
                    $consumedAsInterp = $true
                }
            }
            elseif ($next -eq '(') {
                $depth = 1
                $j = $i + 2
                while ($j -lt $n -and $depth -gt 0) {
                    $c2 = $Text[$j]
                    if ($c2 -eq '(') { $depth++ }
                    elseif ($c2 -eq ')') { $depth-- }
                    $j++
                }
                if ($depth -eq 0) {
                    $raw = $Text.Substring($i, $j - $i)
                    $tokens.Add([ordered]@{
                        Kind        = 'PsInterp'
                        Raw         = $raw
                        Form        = 'Paren'
                        LineOffset  = $line
                        ColumnStart = $col
                    })
                    for ($k = 0; $k -lt $raw.Length; $k++) {
                        if ($raw[$k] -eq "`n") { $line++; $col = 1 } else { $col++ }
                        $i++
                    }
                    $consumedAsInterp = $true
                }
            }
            elseif ($next -match '[A-Za-z_]') {
                $j = $i + 1
                while ($j -lt $n -and $Text[$j] -match '[A-Za-z0-9_]') { $j++ }
                $raw = $Text.Substring($i, $j - $i)
                $tokens.Add([ordered]@{
                    Kind        = 'PsInterp'
                    Raw         = $raw
                    Form        = 'Bare'
                    LineOffset  = $line
                    ColumnStart = $col
                })
                for ($k = 0; $k -lt $raw.Length; $k++) {
                    if ($raw[$k] -eq "`n") { $line++; $col = 1 } else { $col++ }
                    $i++
                }
                $consumedAsInterp = $true
            }
        }
        if ($consumedAsInterp) { continue }

        # Text fallback: reached only when no specialized branch matched.
        # CRITICAL: always consume the first character, then break only on
        # SUBSEQUENT special chars, so the outer loop always advances by at
        # least one character and cannot infinite-loop on an unparseable '<'/'&'.
        $startLine = $line
        $startCol  = $col
        $textStart = $i

        # Always consume the first character, whatever it is.
        if ($ch -eq "`n") { $line++; $col = 1 } else { $col++ }
        $i++

        # Now accumulate further text until the next special char or end.
        while ($i -lt $n) {
            $c2 = $Text[$i]
            if ($c2 -eq '<') { break }
            if ($c2 -eq '&') { break }
            if ($c2 -eq '$' -and ($i + 1) -lt $n) {
                $n2 = $Text[$i + 1]
                if ($n2 -match '[A-Za-z_({]') { break }
            }
            if ($c2 -eq "`n") { $line++; $col = 1 } else { $col++ }
            $i++
        }
        $raw = $Text.Substring($textStart, $i - $textStart)
        if ($raw.Length -gt 0) {
            $tokens.Add([ordered]@{
                Kind        = 'Text'
                Raw         = $raw
                LineOffset  = $startLine
                ColumnStart = $startCol
            })
        }
    }

    return $tokens
}
<# ============================================================================
   FUNCTIONS: ATTRIBUTE PARSER
   ----------------------------------------------------------------------------
   Split a start-tag token into its attribute name/value pairs, tracking
   interpolation in each value.
   Prefix: (none)
   ============================================================================ #>
#
# Split a start-tag token's verbatim .AttrText into structured attribute records
# (.Name, .Value, .Quote, .HasInterp, .HasPureInterp, .RawValue). Walks
# character by character because regex can't reliably handle attribute values
# mixing quotes with PS interpolation.
function Get-AttributesFromToken {
    param([string]$AttrText)

    $attrs = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrWhiteSpace($AttrText)) { return $attrs }

    $text = $AttrText
    $n = $text.Length
    $i = 0

    while ($i -lt $n) {
        while ($i -lt $n -and $text[$i] -match '\s') { $i++ }
        if ($i -ge $n) { break }

        $nameStart = $i
        while ($i -lt $n) {
            $ch = $text[$i]
            if ($ch -match '\s' -or $ch -eq '=' -or $ch -eq '/' -or $ch -eq '>') { break }
            $i++
        }
        if ($i -eq $nameStart) { break }
        $attrName = $text.Substring($nameStart, $i - $nameStart).ToLower()

        while ($i -lt $n -and $text[$i] -match '\s') { $i++ }

        # Value-less attribute (e.g., disabled, checked, readonly).
        if ($i -ge $n -or $text[$i] -ne '=') {
            $attrs.Add([ordered]@{
                Name          = $attrName
                Value         = $null
                Quote         = $null
                HasInterp     = $false
                HasPureInterp = $false
                RawValue      = $null
            })
            continue
        }

        # skip '='
        $i++
        while ($i -lt $n -and $text[$i] -match '\s') { $i++ }
        if ($i -ge $n) {
            $attrs.Add([ordered]@{
                Name          = $attrName
                Value         = ''
                Quote         = $null
                HasInterp     = $false
                HasPureInterp = $false
                RawValue      = ''
            })
            break
        }

        $quote = $null
        $first = $text[$i]
        if ($first -eq '"' -or $first -eq "'") {
            $quote = $first
            $valStart = $i + 1
            $i++
            $parenDepth = 0
            $braceDepth = 0
            while ($i -lt $n) {
                $ch = $text[$i]
                if ($ch -eq '$' -and ($i + 1) -lt $n -and $text[$i + 1] -eq '(') {
                    $parenDepth++; $i += 2; continue
                }
                if ($parenDepth -gt 0 -and $ch -eq '(') { $parenDepth++; $i++; continue }
                if ($parenDepth -gt 0 -and $ch -eq ')') { $parenDepth--; $i++; continue }
                if ($ch -eq '$' -and ($i + 1) -lt $n -and $text[$i + 1] -eq '{') {
                    $braceDepth++; $i += 2; continue
                }
                if ($braceDepth -gt 0 -and $ch -eq '{') { $braceDepth++; $i++; continue }
                if ($braceDepth -gt 0 -and $ch -eq '}') { $braceDepth--; $i++; continue }
                if (($parenDepth -gt 0 -or $braceDepth -gt 0)) { $i++; continue }
                if ($ch -eq $quote) { break }
                $i++
            }
            $valEnd = $i
            $value = $text.Substring($valStart, [Math]::Min($valEnd, $n) - $valStart)
            $rawValue = $quote + $value + $(if ($valEnd -lt $n) { $quote } else { '' })
            if ($i -lt $n) { $i++ }
        } else {
            $valStart = $i
            while ($i -lt $n) {
                $ch = $text[$i]
                if ($ch -match '\s' -or $ch -eq '/' -or $ch -eq '>') { break }
                $i++
            }
            $value = $text.Substring($valStart, $i - $valStart)
            $rawValue = $value
        }

        $hasInterp = ($value -match '\$\(' -or $value -match '\$\{' -or $value -match '\$[A-Za-z_]')

        # Pure interpolation = value is essentially just the PS expression
        # with no static content alongside it. Used to skip rows that would
        # be keyed on the unresolvable variable name (e.g., id="$foo").
        $hasPureInterp = $false
        if ($hasInterp) {
            $stripped = $value
            $stripped = [regex]::Replace($stripped, '\$\([^)]*\)', '')
            $stripped = [regex]::Replace($stripped, '\$\{[^}]*\}', '')
            $stripped = [regex]::Replace($stripped, '\$[A-Za-z_][A-Za-z0-9_]*', '')
            if ([string]::IsNullOrWhiteSpace($stripped)) { $hasPureInterp = $true }
        }

        $attrs.Add([ordered]@{
            Name          = $attrName
            Value         = $value
            Quote         = $quote
            HasInterp     = $hasInterp
            HasPureInterp = $hasPureInterp
            RawValue      = $rawValue
        })
    }

    return $attrs
}

# Convenience: return the first attribute matching a name, or $null.
# Tolerates a null/empty Attrs list (attribute-less tags like <head>) by
# returning $null without traversing.
function Get-AttributeByName {
    param(
        $Attrs,
        [string]$Name
    )
    if ($null -eq $Attrs) { return $null }
    if ([string]::IsNullOrEmpty($Name)) { return $null }
    $lower = $Name.ToLower()
    foreach ($a in $Attrs) {
        if ($a.Name -eq $lower) { return $a }
    }
    return $null
}

<# ============================================================================
   FUNCTIONS: CLASS-NAME SPLITTING AND VALIDATION
   ----------------------------------------------------------------------------
   Split a class attribute value into individual class names and validate
   each for whitespace, character set, duplication, and prefix.
   Prefix: (none)
   ============================================================================ #>
#
# Split a class attribute value into individual static class names (one
# CSS_CLASS USAGE row each). Dynamic values use the array-join pattern (a single
# $cssClasses-style substitution); interpolation tokens are dropped before
# splitting so static names survive.
function Split-StaticClassTokens {
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return @() }

    $cleaned = $Value
    $cleaned = [regex]::Replace($cleaned, '\$\([^)]*\)', ' ')
    $cleaned = [regex]::Replace($cleaned, '\$\{[^}]*\}', ' ')
    $cleaned = [regex]::Replace($cleaned, '\$[A-Za-z_][A-Za-z0-9_]*', ' ')

    $tokens = @($cleaned -split '\s+' | Where-Object { $_ -and $_ -ne '' })
    return $tokens
}

# Validate a class attribute value's shape, returning drift codes to attach to
# each CSS_CLASS USAGE row: whitespace, dynamic-pattern, duplicate-class, and
# malformed-name violations.
function Get-ClassValueDriftCodes {
    param([string]$Value)
    $codes = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrEmpty($Value)) { return @($codes.ToArray()) }

    # Whitespace checks
    if ($Value -match '\t')                          { [void]$codes.Add('MALFORMED_CLASS_VALUE_WHITESPACE') }
    if ($Value -match '^\s' -or $Value -match '\s$') { [void]$codes.Add('MALFORMED_CLASS_VALUE_WHITESPACE') }
    if ($Value -match '\s\s')                        { [void]$codes.Add('MALFORMED_CLASS_VALUE_WHITESPACE') }

    # Interpolation: the array-join pattern is a single top-level interpolation
    # with no other content. Anything else is FORBIDDEN_DYNAMIC_CLASS_PATTERN.
    $interpMatches = @([regex]::Matches($Value, '(\$\([^)]*\))|(\$\{[^}]*\})|(\$[A-Za-z_][A-Za-z0-9_]*)'))
    if ($interpMatches.Count -gt 0) {
        $isCleanArrayJoin = $false
        # Single interpolation, value is exactly that interpolation (allowing
        # surrounding whitespace), nothing else.
        if ($interpMatches.Count -eq 1) {
            $stripped = $Value.Trim()
            if ($stripped -eq $interpMatches[0].Value) {
                $isCleanArrayJoin = $true
            }
        }
        if (-not $isCleanArrayJoin) {
            [void]$codes.Add('FORBIDDEN_DYNAMIC_CLASS_PATTERN')
        }
    }

    # Per-token validation: class-name shape and duplicates
    $tokens = Split-StaticClassTokens -Value $Value
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($t in $tokens) {
        if (-not [string]::IsNullOrEmpty($t)) {
            if ($t -notmatch '^[a-z][a-z0-9\-]*$') {
                if (-not $codes.Contains('MALFORMED_CLASS_NAME')) { [void]$codes.Add('MALFORMED_CLASS_NAME') }
            }
            if (-not $seen.Add($t)) {
                if (-not $codes.Contains('DUPLICATE_CLASS_IN_VALUE')) { [void]$codes.Add('DUPLICATE_CLASS_IN_VALUE') }
            }
        }
    }

    return @($codes.ToArray())
}
<# ============================================================================
   FUNCTIONS: ID VALIDATION
   ----------------------------------------------------------------------------
   Validate an id value for character set, prefix discipline, chrome-set
   membership, and cross-page collisions.
   Prefix: (none)
   ============================================================================ #>
#
# Every id carries the page's cc_prefix (page-local) or the literal 'cc-'
# (chrome) followed by a hyphen; neither is drift. Chrome ids are structural
# (cc- prefix + character set), not an enumerated set. Engine-card slugs are
# checked against Orchestrator.ProcessRegistry separately
# (ENGINE_SLUG_REGISTRY_MISMATCH); a well-formed cc- id naming nothing real is
# caught at resolution time (JS_HTML_ID_UNRESOLVED), not here.

# Validate ID value shape and prefix membership. Returns drift code array.
function Get-IdValueDriftCodes {
    param(
        [Parameter(Mandatory)][string]$IdValue,
        [string]$PagePrefix,
        [bool]$IsHelperEmission
    )
    $codes = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrEmpty($IdValue)) { return @($codes.ToArray()) }

    # Character set check
    if ($IdValue -notmatch '^[a-z][a-z0-9\-]*$') {
        [void]$codes.Add('MALFORMED_ID_VALUE')
    }

    # Chrome-prefixed IDs: any cc- prefixed id is a valid chrome id. No
    # enumerated set; the cc- prefix is sufficient. (Helper and route/API
    # emission alike.)
    if ($IdValue.StartsWith('cc-')) {
        return @($codes.ToArray())
    }

    if ($IsHelperEmission) {
        # Helper module functions emit SHARED HTML. If they produce a
        # page-prefixed ID, that couples shared code to a page.
        if (-not [string]::IsNullOrEmpty($PagePrefix) -and $IdValue.StartsWith("$PagePrefix-")) {
            [void]$codes.Add('FORBIDDEN_HELPER_PAGE_PREFIX_ID')
        }
        # Helper-emitted IDs that don't carry the cc- prefix are not shared
        # chrome; helpers emit shared chrome only.
        [void]$codes.Add('FORBIDDEN_HELPER_NON_CHROME_ID')
    } else {
        # Page-local emission: must start with the page's cc_prefix + '-'.
        if ([string]::IsNullOrEmpty($PagePrefix)) {
            # No prefix on file - flag any non-chrome ID.
            [void]$codes.Add('MISSING_PREFIX_ID')
        } else {
            $expected = "$PagePrefix-"
            if (-not $IdValue.StartsWith($expected)) {
                [void]$codes.Add('MISSING_PREFIX_ID')
                # Cross-page collision: ID starts with a DIFFERENT
                # registered page prefix.
                foreach ($otherPrefix in $script:knownPagePrefixes) {
                    if ($otherPrefix -eq $PagePrefix) { continue }
                    if ($IdValue.StartsWith("$otherPrefix-")) {
                        [void]$codes.Add('CROSS_PAGE_PREFIX_COLLISION')
                        break
                    }
                }
            }
        }
    }

    return @($codes.ToArray())
}
<# ============================================================================
   FUNCTIONS: OVERLAY CONSTRUCT DETECTION
   ----------------------------------------------------------------------------
   Recognize modal, slideout, and slide-up overlay constructs and capture
   their structure for post-walk validation.
   Prefix: (none)
   ============================================================================ #>
#
# Classify an overlay id into its construct kind (modal / slideout / slideup /
# $null) and flag a MALFORMED_*_ID drift code when the id matches a construct
# pattern but its purpose portion is malformed.
function Get-OverlayIdInfo {
    param([Parameter(Mandatory)][string]$IdValue)

    $info = [ordered]@{
        OverlayKind = $null
        DriftCode   = $null
    }

    if ([string]::IsNullOrEmpty($IdValue)) { return $info }

    # Modal: <prefix>-modal-<purpose>
    if ($IdValue -match '^([a-z][a-z0-9]*)-modal-(.+)$') {
        $info.OverlayKind = 'modal'
        $purpose = $matches[2]
        if ($purpose -notmatch '^[a-z][a-z0-9\-]*$') {
            $info.DriftCode = 'MALFORMED_MODAL_ID'
        }
        return $info
    }

    # Slideout: <prefix>-slideout-<purpose>
    if ($IdValue -match '^([a-z][a-z0-9]*)-slideout-(.+)$') {
        $info.OverlayKind = 'slideout'
        $purpose = $matches[2]
        if ($purpose -notmatch '^[a-z][a-z0-9\-]*$') {
            $info.DriftCode = 'MALFORMED_SLIDEOUT_ID'
        }
        return $info
    }

    # Slide-up: <prefix>-slideup-<purpose>
    if ($IdValue -match '^([a-z][a-z0-9]*)-slideup-(.+)$') {
        $info.OverlayKind = 'slideup'
        $purpose = $matches[2]
        if ($purpose -notmatch '^[a-z][a-z0-9\-]*$') {
            $info.DriftCode = 'MALFORMED_SLIDEUP_ID'
        }
        return $info
    }

    # Dock: <prefix>-dock-<purpose>
    if ($IdValue -match '^([a-z][a-z0-9]*)-dock-(.+)$') {
        $info.OverlayKind = 'dock'
        $purpose = $matches[2]
        if ($purpose -notmatch '^[a-z][a-z0-9\-]*$') {
            $info.DriftCode = 'MALFORMED_DOCK_ID'
        }
        return $info
    }

    return $info
}

# Identify an outer overlay element by class. Returns the OverlayKind
# ('modal' | 'slideout' | 'slideup') if the supplied class value declares
# one of the three outer overlay classes; otherwise $null.
function Get-OverlayKindFromClass {
    param([string]$ClassValue)
    if ([string]::IsNullOrEmpty($ClassValue)) { return $null }
    $tokens = @($ClassValue.Trim() -split '\s+')
    foreach ($tk in $tokens) {
        switch ($tk) {
            'cc-modal-overlay'   { return 'modal' }
            'cc-slide-overlay'   { return 'slideout' }
            'cc-slideup-overlay' { return 'slideup' }
            'cc-dialog-dock'     { return 'dock' }
        }
    }
    return $null
}
<# ============================================================================
   FUNCTIONS: EVENT HANDLER ANALYSIS
   ----------------------------------------------------------------------------
   Analyze inline on* event-handler attributes (always forbidden) and the
   handler-expression shape for drift detail.
   Prefix: (none)
   ============================================================================ #>
#
# Inline on* event handlers are forbidden (the platform uses data-action-*
# dispatch). This emits an HTML_EVENT_HANDLER DEFINITION row per on* attribute
# (with FORBIDDEN_INLINE_EVENT_HANDLER plus shape-specific codes) and an
# HTML_DATA_ATTRIBUTE row per data-action-<event> attribute.

# Validate the shape of an event handler value. Returns drift code array.
# These are the per-shape codes; they accompany the umbrella
# FORBIDDEN_INLINE_EVENT_HANDLER code.
function Get-EventHandlerDriftCodes {
    param(
        [string]$Value,
        [string]$AttrName,
        [string]$PagePrefix,
        [bool]$IsHelperEmission
    )
    $codes = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrEmpty($Value)) { return @($codes.ToArray()) }

    $trimmed = $Value.Trim()

    # Trailing semicolon
    if ($trimmed.EndsWith(';')) {
        [void]$codes.Add('TRAILING_HANDLER_SEMICOLON')
        $trimmed = $trimmed.TrimEnd(';').Trim()
    }

    # Multiple statements: presence of semicolons between code
    if ($trimmed -match ';') {
        [void]$codes.Add('MULTIPLE_HANDLER_STATEMENTS')
    }

    # javascript: protocol
    if ($trimmed -match '^(?i)javascript\s*:') {
        [void]$codes.Add('FORBIDDEN_JAVASCRIPT_PROTOCOL')
    }

    # Conditional logic
    if ($trimmed -match '\bif\s*\(' -or $trimmed -match '\?\s*[^:]+\s*:' -or $trimmed -match '\b(?:return|switch|case)\b') {
        [void]$codes.Add('FORBIDDEN_HANDLER_CONDITIONAL')
    }

    # Assignment
    if ($trimmed -match '[^=!<>]=[^=]' -or $trimmed -match '\+=' -or $trimmed -match '-=') {
        [void]$codes.Add('FORBIDDEN_INLINE_ASSIGNMENT')
    }

    # DOM operations via 'this'
    if ($trimmed -match '\bthis\.(?:classList|innerHTML|innerText|textContent|setAttribute|removeAttribute|append|remove|focus|blur)\b') {
        [void]$codes.Add('FORBIDDEN_INLINE_DOM_OPERATION')
    }

    # Event method calls (event.X())
    if ($trimmed -match '\bevent\.[A-Za-z_][A-Za-z0-9_]*\s*\(') {
        [void]$codes.Add('FORBIDDEN_EVENT_METHOD_CALL')
    }

    # Built-in object method calls (window.X, document.X, location.X, etc.)
    if ($trimmed -match '\b(?:window|document|location|history|navigator|console|localStorage|sessionStorage)\.[A-Za-z_][A-Za-z0-9_]*') {
        [void]$codes.Add('FORBIDDEN_BUILTIN_METHOD_CALL')
    }

    # Try to extract a single function call (the only legal-shape form).
    $callPattern = '^\s*([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*)\s*\(([^)]*)\)\s*$'
    if ($trimmed -match $callPattern) {
        $fnName = $matches[1]
        $argList = $matches[2]

        # Dotted (revealing-module) form
        if ($fnName.Contains('.')) {
            [void]$codes.Add('FORBIDDEN_REVEALING_MODULE_CALL')
        }

        # Whitespace between name and '('
        if ($trimmed -match '[A-Za-z0-9_]\s+\(') {
            [void]$codes.Add('MALFORMED_HANDLER_CALL')
        }

        # Argument analysis
        if (-not [string]::IsNullOrWhiteSpace($argList)) {
            # Multi-arg separator format check: must be ", " between args.
            # Use $handlerArgs (not $args) because $args is a PowerShell
            # automatic variable holding the enclosing function's
            # unbound arguments; reassigning it has unpredictable
            # behavior depending on PS version.
            $handlerArgs = @($argList -split ',')
            if ($handlerArgs.Count -gt 1) {
                $trimmedArgs = @($handlerArgs | ForEach-Object { $_.Trim() })
                $expected = ($trimmedArgs -join ', ')
                if ($expected -ne $argList.Trim()) {
                    [void]$codes.Add('MALFORMED_ARGUMENT_LIST')
                }
            }

            foreach ($a in $handlerArgs) {
                $a = $a.Trim()
                if ([string]::IsNullOrEmpty($a)) { continue }

                # Allowed forms:
                #   - 'this' literal
                #   - 'this.<property>'
                #   - numeric literal
                #   - single-quoted string literal
                $isLiteral = (
                    $a -eq 'this' -or
                    $a -match '^this\.[A-Za-z_][A-Za-z0-9_]*$' -or
                    $a -match '^-?\d+(\.\d+)?$' -or
                    $a -match "^'[^']*'$"
                )

                if (-not $isLiteral) {
                    # Double-quoted strings clash with the surrounding
                    # attribute value's double quotes.
                    if ($a -match '^"[^"]*"$') {
                        [void]$codes.Add('MALFORMED_ARGUMENT_QUOTING')
                    } else {
                        [void]$codes.Add('FORBIDDEN_ARGUMENT_EXPRESSION')
                    }
                }
            }
        }

        # Function name vs page prefix check (only meaningful for
        # non-dotted, non-helper-emitted handlers).
        if (-not $fnName.Contains('.') -and -not $IsHelperEmission -and -not [string]::IsNullOrEmpty($PagePrefix)) {
            # 'cc_' prefix is shared (chrome dispatch); page prefix is local.
            $expectedPrefix = "${PagePrefix}_"
            $isChromeName = $fnName.StartsWith('cc_')
            $isPageName   = $fnName.StartsWith($expectedPrefix)
            if (-not $isChromeName -and -not $isPageName) {
                [void]$codes.Add('HANDLER_FUNCTION_NAME_MISMATCH')
            }
        }

        # Helper emission calling a page-prefixed function = forbidden coupling.
        if ($IsHelperEmission -and -not [string]::IsNullOrEmpty($PagePrefix)) {
            foreach ($p in $script:knownPagePrefixes) {
                if ($fnName.StartsWith("${p}_")) {
                    [void]$codes.Add('FORBIDDEN_HELPER_PAGE_FUNCTION_CALL')
                    break
                }
            }
        }
    } else {
        # Value doesn't match the single-function-call shape - it's an
        # inline expression of some other form.
        if (-not $codes.Contains('MULTIPLE_HANDLER_STATEMENTS') -and
            -not $codes.Contains('FORBIDDEN_HANDLER_CONDITIONAL') -and
            -not $codes.Contains('FORBIDDEN_INLINE_ASSIGNMENT')) {
            [void]$codes.Add('INLINE_HANDLER_EXPRESSION')
        }
    }

    return @($codes.ToArray())
}

# Extract the function name (or dotted-call leftmost name) from a handler
# value. Used for the HTML_EVENT_HANDLER row's variant_qualifier_1.
function Get-HandlerFunctionName {
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return $null }
    if ($Value -match '^\s*([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*)\s*\(') {
        return $matches[1]
    }
    return $null
}
<# ============================================================================
   FUNCTIONS: DATA-ACTION ATTRIBUTE VALIDATION
   ----------------------------------------------------------------------------
   Validate data-action-<event> attributes and their argument attributes
   for event set, prefix discipline, and placement.
   Prefix: (none)
   ============================================================================ #>
#
# data-action-* attributes are two families: event attributes
# (data-action-<event>="<action-value>", event in the closed set, value
# prefixed) and argument attributes (data-action-<prefix>-<arg-name>, valid
# only on an element that also declares an event attribute). Both emit
# HTML_DATA_ATTRIBUTE DEFINITION rows; the event family carries the event name
# in variant_qualifier_1.

# Classify a data-action-* attribute: 'event' (single-word suffix in the
# recognized set), 'argument' (multi-word kebab, first segment a prefix),
# 'unknown-event' (single-word but unrecognized -- event row shape, fires
# UNKNOWN_EVENT_TYPE), or $null (not data-action-*).
function Get-DataActionAttributeKind {
    param([string]$AttrName)
    if ([string]::IsNullOrEmpty($AttrName)) { return $null }
    if ($AttrName -notmatch '^data-action-(.+)$') { return $null }
    $suffix = $matches[1]
    # Single-word suffix: event-like. If in the recognized set, it's an
    # event attribute; otherwise still event-shaped but unknown event.
    if ($suffix -match '^[a-z]+$') {
        if ($RecognizedEvents -contains $suffix) { return 'event' }
        return 'unknown-event'
    }
    return 'argument'
}
# Extract the event name from a data-action-<event> attribute name.
function Get-EventFromDataActionName {
    param([string]$AttrName)
    if ($AttrName -match '^data-action-([a-z]+)$') {
        return $matches[1]
    }
    return $null
}

# Suffix after 'data-action-' (everything after the literal prefix).
function Get-DataActionSuffix {
    param([string]$AttrName)
    if ($AttrName -match '^data-action-(.+)$') {
        return $matches[1]
    }
    return $null
}

# Extract the prefix portion of an argument attribute name.
# 'data-action-bsv-batch-id'  -> 'bsv'
# 'data-action-cc-batch-id'   -> 'cc'
# Returns $null if the name doesn't have a recognizable prefix segment.
function Get-ArgumentAttributePrefix {
    param([string]$AttrName)
    if ([string]::IsNullOrEmpty($AttrName)) { return $null }
    if ($AttrName -notmatch '^data-action-([a-z][a-z0-9]*)-') { return $null }
    return $matches[1]
}

# Extract the prefix portion of an action value.
# 'bsv-open-batch'      -> 'bsv'
# 'cc-page-refresh'     -> 'cc'
# Returns $null when the value doesn't start with a prefix-hyphen pair.
function Get-ActionValuePrefix {
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return $null }
    if ($Value -notmatch '^([a-z][a-z0-9]*)-') { return $null }
    return $matches[1]
}

# Event-attribute validation. Returns drift codes for:
#   UNKNOWN_EVENT_TYPE     - single-word suffix not in the recognized set
#   MALFORMED_ACTION_VALUE - value contains chars outside [a-z0-9-]
#   ACTION_PREFIX_MISMATCH - value does not carry a recognized prefix
#                            (page prefix or cc-)
function Get-DataActionEventValidationCodes {
    param(
        [string]$AttrName,
        [string]$Value,
        [string]$PagePrefix
    )
    $codes = New-Object System.Collections.Generic.List[string]

    $suffix = Get-DataActionSuffix -AttrName $AttrName
    # UNKNOWN_EVENT_TYPE: single-word suffix that is not in the recognized set.
    if ($null -ne $suffix -and $suffix -match '^[a-z]+$' -and $RecognizedEvents -notcontains $suffix) {
        [void]$codes.Add('UNKNOWN_EVENT_TYPE')
    }

    if (-not [string]::IsNullOrEmpty($Value)) {
        if ($Value -notmatch '^[a-z][a-z0-9\-]*$') {
            [void]$codes.Add('MALFORMED_ACTION_VALUE')
        }
        # Prefix check: value must begin with PagePrefix-... or cc-...
        $valPrefix = Get-ActionValuePrefix -Value $Value
        $ok = $false
        if ($valPrefix -eq 'cc') { $ok = $true }
        elseif (-not [string]::IsNullOrEmpty($PagePrefix) -and $valPrefix -eq $PagePrefix) { $ok = $true }
        if (-not $ok) {
            [void]$codes.Add('ACTION_PREFIX_MISMATCH')
        }
    }

    return @($codes.ToArray())
}

# Argument-attribute validation: returns codes for a suffix colliding with an
# event name, a malformed suffix (chars outside [a-z0-9-]), or a value mixing
# static text with interpolation.
function Get-DataActionArgumentValidationCodes {
    param(
        [string]$AttrName,
        [string]$Value,
        [bool]$HasInterp,
        [bool]$HasPureInterp
    )
    $codes = New-Object System.Collections.Generic.List[string]

    $suffix = Get-DataActionSuffix -AttrName $AttrName
    if ($null -ne $suffix) {
        # Arg name is <prefix>-<arg-name>. The <arg-name> portion after the
        # first hyphen must not match an event name and must be kebab-case.
        if ($suffix -match '^[a-z]+$' -and $RecognizedEvents -contains $suffix) {
            [void]$codes.Add('ARGUMENT_NAME_COLLIDES_WITH_EVENT')
        } elseif ($suffix -notmatch '^[a-z][a-z0-9\-]*$') {
            [void]$codes.Add('MALFORMED_ACTION_ARGUMENT_NAME')
        } else {
            # Check that the part after the first hyphen (the arg-name proper)
            # is not itself a recognized event.
            if ($suffix -match '^[a-z][a-z0-9]*-([a-z][a-z0-9\-]*)$') {
                $argNameProper = $matches[1]
                if ($argNameProper -match '^[a-z]+$' -and $RecognizedEvents -contains $argNameProper) {
                    [void]$codes.Add('ARGUMENT_NAME_COLLIDES_WITH_EVENT')
                }
            }
        }
    }

    # Interpolation rule: static text + $interp mixed in the same value is
    # forbidden. Pure interpolation (value is just $variable or $(...)) is
    # acceptable and tracked via has_dynamic_content on the row.
    if ($HasInterp -and -not $HasPureInterp -and -not [string]::IsNullOrEmpty($Value)) {
        [void]$codes.Add('FORBIDDEN_INLINE_ACTION_ARGUMENT_INTERPOLATION')
    }

    return @($codes.ToArray())
}

# Extract the root variable names in an attribute value's PS interpolations
# (the leftmost variable: for $($section.id.ToString()) the root is 'section').
# Function-call interpolations yield no root. Each result carries .Root,
# .IsScoped (explicit scope prefix, never allowed in helper-emitted args), and
# .RawExpr.
function Get-InterpolationRootVariables {
    param([string]$Value)
    $result = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrEmpty($Value)) { return @($result.ToArray()) }

    $n = $Value.Length
    $i = 0
    while ($i -lt $n) {
        $ch = $Value[$i]
        if ($ch -ne '$') { $i++; continue }
        # Possible interpolation starting at $i.
        if (($i + 1) -lt $n -and $Value[$i + 1] -eq '(') {
            # $(...) form - find the matching ).
            $start = $i + 2
            $depth = 1
            $j = $start
            while ($j -lt $n -and $depth -gt 0) {
                if ($Value[$j] -eq '(') { $depth++ }
                elseif ($Value[$j] -eq ')') { $depth-- }
                if ($depth -gt 0) { $j++ }
            }
            if ($j -ge $n) { break }
            $expr = $Value.Substring($start, $j - $start).Trim()
            $info = Get-RootVariableFromExpression -Expression $expr
            $info.RawExpr = $expr
            $result.Add($info) | Out-Null
            $i = $j + 1
            continue
        }
        if (($i + 1) -lt $n -and $Value[$i + 1] -eq '{') {
            # ${name} form (with possible scope).
            $start = $i + 2
            $j = $start
            while ($j -lt $n -and $Value[$j] -ne '}') { $j++ }
            if ($j -ge $n) { break }
            $expr = $Value.Substring($start, $j - $start)
            $info = Get-RootVariableFromExpression -Expression $expr
            $info.RawExpr = $expr
            $result.Add($info) | Out-Null
            $i = $j + 1
            continue
        }
        if (($i + 1) -lt $n -and $Value[$i + 1] -match '[A-Za-z_]') {
            # $name form (bare variable, possibly $scope:name).
            $start = $i + 1
            $j = $start
            while ($j -lt $n -and $Value[$j] -match '[A-Za-z0-9_:]') { $j++ }
            $expr = $Value.Substring($start, $j - $start)
            $info = Get-RootVariableFromExpression -Expression $expr
            $info.RawExpr = $expr
            $result.Add($info) | Out-Null
            $i = $j
            continue
        }
        # Lone $ with no recognizable interpolation; skip.
        $i++
    }
    return @($result.ToArray())
}

# Parse an interpolation expression and extract its root variable: bare/scoped
# variables and property/method access yield the leftmost variable (scoped forms
# set IsScoped); function calls and empty input yield $null.
function Get-RootVariableFromExpression {
    param([string]$Expression)
    $info = [ordered]@{
        Root     = $null
        IsScoped = $false
        RawExpr  = $Expression
    }
    if ([string]::IsNullOrWhiteSpace($Expression)) { return $info }

    $trimmed = $Expression.Trim()

    # An expression starting with $name (after the populator already
    # stripped the outer $/$(/${) means we're looking at the variable
    # itself. We expect either:
    #   <name>          bare
    #   <scope>:<name>  scoped (script:, global:, env:, etc.)
    # followed optionally by property/method access (. or :: or ()).
    if ($trimmed -notmatch '^([A-Za-z_][A-Za-z0-9_]*)(:([A-Za-z_][A-Za-z0-9_]*))?') {
        return $info
    }
    $first  = $matches[1]
    $second = if ($matches.Count -ge 4) { $matches[3] } else { $null }

    # PowerShell scope prefixes.
    $scopePrefixes = @('script','global','local','private','env','function','variable','using')
    if (-not [string]::IsNullOrEmpty($second) -and $scopePrefixes -contains $first.ToLower()) {
        $info.Root = "${first}:${second}"
        $info.IsScoped = $true
        return $info
    }

    $info.Root = $first
    return $info
}

# Derive the categorical text name from the parent's first class token: strip a
# leading '<page-prefix>-' (hyphen-anchored, so 'bsv' strips 'bsv-section' but
# not 'bsvfoo-bar'); fall back to '<tag>-text' when no class is present.
function Get-HtmlTextCategoricalName {
    param(
        [string]$ParentTag,
        [string]$ParentClass,
        [string]$PagePrefix
    )

    # Defensive fallback for missing tag context.
    if ([string]::IsNullOrEmpty($ParentTag)) {
        return 'unknown-text'
    }
    $tag = $ParentTag.ToLowerInvariant()

    # No-class fallback: '<tag>-text'.
    if ([string]::IsNullOrWhiteSpace($ParentClass)) {
        return "$tag-text"
    }

    # First space-separated token; additional tokens ignored.
    $firstToken = ($ParentClass.Trim() -split '\s+')[0]
    if ([string]::IsNullOrEmpty($firstToken)) {
        return "$tag-text"
    }

    # Hyphen-anchored prefix stripping. Only strip when the token starts
    # with '<prefix>-'. Bare prefix matches (e.g., 'bsvfoo' against prefix
    # 'bsv') do not strip.
    if (-not [string]::IsNullOrEmpty($PagePrefix)) {
        $stripCandidate = "$PagePrefix-"
        if ($firstToken.StartsWith($stripCandidate, [System.StringComparison]::OrdinalIgnoreCase)) {
            $firstToken = $firstToken.Substring($stripCandidate.Length)
            if ([string]::IsNullOrEmpty($firstToken)) {
                return "$tag-text"
            }
        }
    }

    return "$tag-$firstToken"
}
<# ============================================================================
   FUNCTIONS: ROW EMITTERS
   ----------------------------------------------------------------------------
   Construct Asset_Registry rows for each cataloguable HTML construct,
   attaching drift codes detected during emission.
   Prefix: (none)
   ============================================================================ #>

# Wrap New-AssetRegistryRow with per-file context. Every HTML row carries
# file_name = the current PS file's bare name and file_type = 'HTML'.
function New-HtmlRow {
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
        [Nullable[bool]]$HasDynamicContent = $null
    )

    if (-not $SourceFile) { $SourceFile = $script:CurrentFile }

    return New-AssetRegistryRow `
        -FileName           $script:CurrentFile `
        -FileType           'HTML' `
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
        -PurposeDescription $PurposeDescription `
        -HasDynamicContent  $HasDynamicContent
}

# Emit the file-level HTML_FILE anchor row, one per host file.
function Add-HtmlFileRow {
    param(
        [Parameter(Mandatory)][string]$ComponentName,
        [Parameter(Mandatory)][ValidateSet('LOCAL','SHARED')][string]$Scope,
        [Parameter(Mandatory)][int]$LineEnd,
        [string[]]$RoutePaths = @()
    )

    $key = "$($script:CurrentFile)|1|HTML_FILE|$ComponentName|DEFINITION|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $rawText = if ($RoutePaths -and $RoutePaths.Count -gt 0) {
        ($RoutePaths -join ' | ')
    } else {
        $null
    }

    $row = New-HtmlRow `
        -ComponentType  'HTML_FILE' `
        -ComponentName  $ComponentName `
        -ReferenceType  'DEFINITION' `
        -Scope          $Scope `
        -SourceFile     $script:CurrentFile `
        -LineStart      1 `
        -LineEnd        $LineEnd `
        -ColumnStart    1 `
        -RawText        $rawText
    $script:rows.Add($row)
    $script:htmlFileRowByFile[$script:CurrentFile] = $row
    return $row
}

# Emit an HTML_ID DEFINITION row for an id="..." attribute.
function Add-HtmlIdRow {
    param(
        [Parameter(Mandatory)][string]$IdValue,
        [Parameter(Mandatory)][int]$LineStart,
        [Parameter(Mandatory)][int]$ColumnStart,
        [string]$Signature,
        [string]$ParentFunction,
        [string]$RawText,
        [string]$PurposeDescription,
        [Nullable[bool]]$HasDynamicContent = $null,
        [string[]]$DriftCodes = @()
    )
    if ([string]::IsNullOrWhiteSpace($IdValue)) { return $null }

    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|HTML_ID|$IdValue|DEFINITION|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $row = New-HtmlRow `
        -ComponentType      'HTML_ID' `
        -ComponentName      $IdValue `
        -ReferenceType      'DEFINITION' `
        -Scope              'LOCAL' `
        -SourceFile         $script:CurrentFile `
        -LineStart          $LineStart `
        -LineEnd            $LineStart `
        -ColumnStart        $ColumnStart `
        -Signature          $Signature `
        -ParentFunction     $ParentFunction `
        -RawText            $RawText `
        -PurposeDescription $PurposeDescription `
        -HasDynamicContent  $HasDynamicContent
    foreach ($code in $DriftCodes) { Add-DriftCode -Row $row -Code $code }
    $script:rows.Add($row)
    return $row
}

# Emit an HTML_DATA_ATTRIBUTE DEFINITION row for a data-* attribute.
function Add-HtmlDataAttributeRow {
    param(
        [Parameter(Mandatory)][string]$AttrName,
        [Parameter(Mandatory)][ValidateSet('LOCAL','SHARED')][string]$Scope,
        [Parameter(Mandatory)][int]$LineStart,
        [Parameter(Mandatory)][int]$ColumnStart,
        [string]$VariantType,
        [string]$VariantQualifier1,
        [string]$Signature,
        [string]$ParentFunction,
        [string]$RawText,
        [Nullable[bool]]$HasDynamicContent = $null,
        [string[]]$DriftCodes = @()
    )
    if ([string]::IsNullOrWhiteSpace($AttrName)) { return $null }

    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|HTML_DATA_ATTRIBUTE|$AttrName|DEFINITION|$VariantType|$VariantQualifier1"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $row = New-HtmlRow `
        -ComponentType      'HTML_DATA_ATTRIBUTE' `
        -ComponentName      $AttrName `
        -VariantType        $VariantType `
        -VariantQualifier1  $VariantQualifier1 `
        -ReferenceType      'DEFINITION' `
        -Scope              $Scope `
        -SourceFile         $script:CurrentFile `
        -LineStart          $LineStart `
        -LineEnd            $LineStart `
        -ColumnStart        $ColumnStart `
        -Signature          $Signature `
        -ParentFunction     $ParentFunction `
        -RawText            $RawText `
        -HasDynamicContent  $HasDynamicContent
    foreach ($code in $DriftCodes) { Add-DriftCode -Row $row -Code $code }
    $script:rows.Add($row)
    return $row
}

# Emit an HTML_EVENT_HANDLER row for an inline on* attribute (always forbidden).
# component_name      = the on* attribute name (e.g., 'onclick')
# variant_qualifier_1 = the called function name (when extractable)
# Every row gets FORBIDDEN_INLINE_EVENT_HANDLER as the umbrella code; the
# caller passes additional shape-specific codes.
function Add-HtmlEventHandlerRow {
    param(
        [Parameter(Mandatory)][string]$AttrName,
        [Parameter(Mandatory)][int]$LineStart,
        [Parameter(Mandatory)][int]$ColumnStart,
        [string]$CalledFunctionName,
        [string]$Signature,
        [string]$ParentFunction,
        [string]$RawText,
        [Nullable[bool]]$HasDynamicContent = $null,
        [string[]]$DriftCodes = @()
    )
    if ([string]::IsNullOrWhiteSpace($AttrName)) { return $null }

    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|HTML_EVENT_HANDLER|$AttrName|DEFINITION|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $row = New-HtmlRow `
        -ComponentType      'HTML_EVENT_HANDLER' `
        -ComponentName      $AttrName `
        -VariantQualifier1  $CalledFunctionName `
        -ReferenceType      'DEFINITION' `
        -Scope              'LOCAL' `
        -SourceFile         $script:CurrentFile `
        -LineStart          $LineStart `
        -LineEnd            $LineStart `
        -ColumnStart        $ColumnStart `
        -Signature          $Signature `
        -ParentFunction     $ParentFunction `
        -RawText            $RawText `
        -HasDynamicContent  $HasDynamicContent
    Add-DriftCode -Row $row -Code 'FORBIDDEN_INLINE_EVENT_HANDLER'
    foreach ($code in $DriftCodes) { Add-DriftCode -Row $row -Code $code }
    $script:rows.Add($row)
    return $row
}

# Emit an HTML_TEXT DEFINITION row for element body text or a user-facing
# attribute (title/placeholder/aria-label/alt). component_name is a categorical
# label ('<tag>-<class-after-prefix-strip>' or 'attr-<attrname>') for queryable
# structural role; the literal text goes in raw_text.
function Add-HtmlTextRow {
    param(
        [Parameter(Mandatory)][string]$ComponentName,
        [Parameter(Mandatory)][int]$LineStart,
        [Parameter(Mandatory)][int]$ColumnStart,
        [string]$Signature,
        [string]$ParentFunction,
        [string]$RawText,
        [Nullable[bool]]$HasDynamicContent = $null,
        [string[]]$DriftCodes = @()
    )

    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|HTML_TEXT|$ComponentName|DEFINITION|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $row = New-HtmlRow `
        -ComponentType      'HTML_TEXT' `
        -ComponentName      $ComponentName `
        -ReferenceType      'DEFINITION' `
        -Scope              'LOCAL' `
        -SourceFile         $script:CurrentFile `
        -LineStart          $LineStart `
        -LineEnd            $LineStart `
        -ColumnStart        $ColumnStart `
        -Signature          $Signature `
        -ParentFunction     $ParentFunction `
        -RawText            $RawText `
        -HasDynamicContent  $HasDynamicContent
    foreach ($code in $DriftCodes) { Add-DriftCode -Row $row -Code $code }
    $script:rows.Add($row)
    return $row
}

# Emit an HTML_ENTITY DEFINITION row for a named, numeric, or Unicode entity.
# component_name = the literal reference; signature = 'entity_named' or
# 'entity_numeric' (decimal and hex both map to entity_numeric).
function Add-HtmlEntityRow {
    param(
        [Parameter(Mandatory)][string]$Literal,
        [Parameter(Mandatory)][string]$SpecForm,
        [Parameter(Mandatory)][int]$LineStart,
        [Parameter(Mandatory)][int]$ColumnStart,
        [string]$ParentFunction,
        [string]$RawText
    )

    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|HTML_ENTITY|$Literal|DEFINITION|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $row = New-HtmlRow `
        -ComponentType      'HTML_ENTITY' `
        -ComponentName      $Literal `
        -ReferenceType      'DEFINITION' `
        -Scope              'LOCAL' `
        -SourceFile         $script:CurrentFile `
        -LineStart          $LineStart `
        -LineEnd            $LineStart `
        -ColumnStart        $ColumnStart `
        -Signature          $SpecForm `
        -ParentFunction     $ParentFunction `
        -RawText            $RawText
    $script:rows.Add($row)
    return $row
}

# Emit an HTML_SVG DEFINITION row capturing an inline SVG outer element.
# SVG markup is cataloged at the outer element level.
# component_name = a categorical label (e.g., 'inline-icon', 'inline-illustration')
# raw_text = the full SVG outer-element markup.
function Add-HtmlSvgRow {
    param(
        [Parameter(Mandatory)][string]$ComponentName,
        [Parameter(Mandatory)][int]$LineStart,
        [Parameter(Mandatory)][int]$LineEnd,
        [Parameter(Mandatory)][int]$ColumnStart,
        [string]$Signature,
        [string]$ParentFunction,
        [string]$RawText,
        [Nullable[bool]]$HasDynamicContent = $null,
        [string[]]$DriftCodes = @()
    )

    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|HTML_SVG|$ComponentName|DEFINITION|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $row = New-HtmlRow `
        -ComponentType      'HTML_SVG' `
        -ComponentName      $ComponentName `
        -ReferenceType      'DEFINITION' `
        -Scope              'LOCAL' `
        -SourceFile         $script:CurrentFile `
        -LineStart          $LineStart `
        -LineEnd            $LineEnd `
        -ColumnStart        $ColumnStart `
        -Signature          $Signature `
        -ParentFunction     $ParentFunction `
        -RawText            $RawText `
        -HasDynamicContent  $HasDynamicContent
    foreach ($code in $DriftCodes) { Add-DriftCode -Row $row -Code $code }
    $script:rows.Add($row)
    return $row
}

# Emit an HTML_COMMENT DEFINITION row. Three kinds: comment-section-divider
# (introduces a structural block), comment-panel-purpose (immediately precedes
# an overlay construct), comment-inline (any other). component_name = the kind;
# raw_text = the body.
function Add-HtmlCommentRow {
    param(
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][int]$LineStart,
        [Parameter(Mandatory)][int]$LineEnd,
        [Parameter(Mandatory)][int]$ColumnStart,
        [string]$Signature,
        [string]$ParentFunction,
        [string]$RawText,
        [string]$PurposeDescription,
        [string[]]$DriftCodes = @()
    )

    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|HTML_COMMENT|$Kind|DEFINITION|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $row = New-HtmlRow `
        -ComponentType      'HTML_COMMENT' `
        -ComponentName      $Kind `
        -ReferenceType      'DEFINITION' `
        -Scope              'LOCAL' `
        -SourceFile         $script:CurrentFile `
        -LineStart          $LineStart `
        -LineEnd            $LineEnd `
        -ColumnStart        $ColumnStart `
        -Signature          $Signature `
        -ParentFunction     $ParentFunction `
        -RawText            $RawText `
        -PurposeDescription $PurposeDescription
    foreach ($code in $DriftCodes) { Add-DriftCode -Row $row -Code $code }
    $script:rows.Add($row)
    return $row
}

# Emit a CSS_CLASS USAGE row for a class name, resolving scope against existing CSS DEFINITION rows.
function Add-CssClassUsageRow {
    param(
        [Parameter(Mandatory)][string]$ClassName,
        [Parameter(Mandatory)][int]$LineStart,
        [Parameter(Mandatory)][int]$ColumnStart,
        [string]$Signature,
        [string]$ParentFunction,
        [string]$RawText,
        [Nullable[bool]]$HasDynamicContent = $null,
        [string[]]$DriftCodes = @()
    )
    if ([string]::IsNullOrWhiteSpace($ClassName)) { return $null }

    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|CSS_CLASS|$ClassName|USAGE|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $row = New-HtmlRow `
        -ComponentType      'CSS_CLASS' `
        -ComponentName      $ClassName `
        -ReferenceType      'USAGE' `
        -Scope              '<pending>' `
        -SourceFile         '<pending>' `
        -LineStart          $LineStart `
        -LineEnd            $LineStart `
        -ColumnStart        $ColumnStart `
        -Signature          $Signature `
        -ParentFunction     $ParentFunction `
        -RawText            $RawText `
        -HasDynamicContent  $HasDynamicContent
    foreach ($code in $DriftCodes) { Add-DriftCode -Row $row -Code $code }
    $script:rows.Add($row)
    return $row
}

# Emit a CSS_FILE USAGE row for a <link rel="stylesheet"> reference.
function Add-CssFileUsageRow {
    param(
        [Parameter(Mandatory)][string]$Href,
        [Parameter(Mandatory)][int]$LineStart,
        [Parameter(Mandatory)][int]$ColumnStart,
        [string]$Signature,
        [string]$ParentFunction,
        [string]$RawText,
        [Nullable[bool]]$HasDynamicContent = $null,
        [string[]]$DriftCodes = @()
    )
    if ([string]::IsNullOrWhiteSpace($Href)) { return $null }

    # Use the bare filename (not the full URL path) as component_name and
    # dedupe key. This matches the CSS populator's CSS_FILE DEFINITION
    # rows, which use $script:CurrentFile (a bare filename). The full URL
    # is preserved in raw_text for debugging context.
    $bare = [System.IO.Path]::GetFileName($Href)

    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|CSS_FILE|$bare|USAGE|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $row = New-HtmlRow `
        -ComponentType      'CSS_FILE' `
        -ComponentName      $bare `
        -ReferenceType      'USAGE' `
        -Scope              '<pending>' `
        -SourceFile         '<pending>' `
        -LineStart          $LineStart `
        -LineEnd            $LineStart `
        -ColumnStart        $ColumnStart `
        -Signature          $Signature `
        -ParentFunction     $ParentFunction `
        -RawText            $RawText `
        -HasDynamicContent  $HasDynamicContent
    foreach ($code in $DriftCodes) { Add-DriftCode -Row $row -Code $code }
    $script:rows.Add($row)
    return $row
}

# Emit a JS_FILE USAGE row for a <script src="..."> reference.
function Add-JsFileUsageRow {
    param(
        [Parameter(Mandatory)][string]$Src,
        [Parameter(Mandatory)][int]$LineStart,
        [Parameter(Mandatory)][int]$ColumnStart,
        [string]$Signature,
        [string]$ParentFunction,
        [string]$RawText,
        [Nullable[bool]]$HasDynamicContent = $null,
        [string[]]$DriftCodes = @()
    )
    if ([string]::IsNullOrWhiteSpace($Src)) { return $null }

    # Use the bare filename (not the full URL path) as component_name and
    # dedupe key. This matches the JS populator's JS_FILE DEFINITION rows,
    # which use $script:CurrentFile (a bare filename). The full URL is
    # preserved in raw_text for debugging context.
    $bare = [System.IO.Path]::GetFileName($Src)

    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|JS_FILE|$bare|USAGE|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $row = New-HtmlRow `
        -ComponentType      'JS_FILE' `
        -ComponentName      $bare `
        -ReferenceType      'USAGE' `
        -Scope              '<pending>' `
        -SourceFile         '<pending>' `
        -LineStart          $LineStart `
        -LineEnd            $LineStart `
        -ColumnStart        $ColumnStart `
        -Signature          $Signature `
        -ParentFunction     $ParentFunction `
        -RawText            $RawText `
        -HasDynamicContent  $HasDynamicContent
    foreach ($code in $DriftCodes) { Add-DriftCode -Row $row -Code $code }
    $script:rows.Add($row)
    return $row
}

<# ============================================================================
   FUNCTIONS: PAGE SHELL VALIDATION
   ----------------------------------------------------------------------------
   Validate the mandated page-shell structure: doctype, head, body, asset
   references, and element order.
   Prefix: (none)
   ============================================================================ #>

# Page-shell validation runs ONLY on files classified as 'Route' (the full-page
# shape per CC_HTML_Spec Sec. 1). API fragments and Module helpers are not
# complete pages.

# Find the first token whose Kind matches and whose predicate returns $true.
function Find-TokenIndex {
    param(
        [Parameter(Mandatory)]$Tokens,
        [Parameter(Mandatory)][string]$Kind,
        [scriptblock]$Predicate,
        [int]$StartAt = 0
    )
    for ($i = $StartAt; $i -lt $Tokens.Count; $i++) {
        $t = $Tokens[$i]
        if ($t.Kind -ne $Kind) { continue }
        if ($Predicate -and -not (& $Predicate $t)) { continue }
        return $i
    }
    return -1
}

# Find the next "significant" token from $StartAt, skipping whitespace-only
# Text tokens. Significant = not just whitespace.
function Find-NextSignificantToken {
    param(
        [Parameter(Mandatory)]$Tokens,
        [Parameter(Mandatory)][int]$StartAt
    )
    for ($i = $StartAt; $i -lt $Tokens.Count; $i++) {
        $t = $Tokens[$i]
        if ($t.Kind -eq 'Text' -and [string]::IsNullOrWhiteSpace($t.Raw)) { continue }
        return $i
    }
    return -1
}

# Find the EndTag closing the StartTag at $StartTagIdx, tracking depth for
# same-name nesting. Returns the closing EndTag index, or -1 if none/not a
# StartTag.
function Find-MatchingClose {
    param(
        [Parameter(Mandatory)]$Tokens,
        [Parameter(Mandatory)][int]$StartTagIdx
    )
    if ($StartTagIdx -lt 0 -or $StartTagIdx -ge $Tokens.Count) { return -1 }
    $startTok = $Tokens[$StartTagIdx]
    if ($startTok.Kind -ne 'StartTag') { return -1 }
    $tagName = $startTok.TagName
    $depth = 1
    for ($i = $StartTagIdx + 1; $i -lt $Tokens.Count; $i++) {
        $t = $Tokens[$i]
        if ($t.TagName -ne $tagName) { continue }
        if ($t.Kind -eq 'StartTag') { $depth++; continue }
        if ($t.Kind -eq 'EndTag') {
            $depth--
            if ($depth -eq 0) { return $i }
        }
    }
    return -1
}

# Test whether a token's StartTag attribute text contains a specific
# attribute=value match using a regex pattern.
function Test-AttrTextMatches {
    param(
        [string]$AttrText,
        [string]$Pattern
    )
    if ([string]::IsNullOrEmpty($AttrText)) { return $false }
    return $AttrText -match $Pattern
}

# Get the page-shell drift codes for a route file's tokenized HTML. Returns
# an array of drift-code strings to attach to the file's HTML_FILE row.
function Get-PageShellDrift {
    param([Parameter(Mandatory)]$Tokens)

    $codes = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Tokens -or $Tokens.Count -eq 0) {
        # Empty token stream for a route file - all required landmarks are absent.
        [void]$codes.Add('MALFORMED_DOCTYPE')
        [void]$codes.Add('MISSING_NAV_SUBSTITUTION')
        [void]$codes.Add('MISSING_HEADER_BAR')
        [void]$codes.Add('MISSING_BANNER_SUBSTITUTION')
        [void]$codes.Add('MISSING_SHARED_SCRIPT_TAG')
        return $codes.ToArray()
    }

    # DOCTYPE: exact-case required form
    # The DOCTYPE token must be exactly <!DOCTYPE html> (uppercase keyword,
    # lowercase tag name).
    $firstSigIdx = Find-NextSignificantToken -Tokens $Tokens -StartAt 0
    if ($firstSigIdx -ge 0 -and $Tokens[$firstSigIdx].Kind -eq 'Doctype') {
        $rawDt = $Tokens[$firstSigIdx].Raw.Trim()
        if ($rawDt -cne '<!DOCTYPE html>') {
            [void]$codes.Add('MALFORMED_DOCTYPE')
        }
    } else {
        [void]$codes.Add('MALFORMED_DOCTYPE')
    }

    # <html> root with no attributes
    $htmlStartIdx = Find-TokenIndex -Tokens $Tokens -Kind 'StartTag' `
        -Predicate { param($t) $t.TagName -eq 'html' }
    if ($htmlStartIdx -ge 0) {
        $attrText = $Tokens[$htmlStartIdx].AttrText
        if (-not [string]::IsNullOrWhiteSpace($attrText)) {
            [void]$codes.Add('MALFORMED_HTML_ROOT')
        }
    }

    # <head> contents validation
    $headStartIdx = Find-TokenIndex -Tokens $Tokens -Kind 'StartTag' `
        -Predicate { param($t) $t.TagName -eq 'head' }
    $headEndIdx = -1
    if ($headStartIdx -ge 0) {
        $headEndIdx = Find-TokenIndex -Tokens $Tokens -Kind 'EndTag' `
            -Predicate { param($t) $t.TagName -eq 'head' } `
            -StartAt $headStartIdx
    }
    # ordered list of href values inside <head>
    $linkRefs = @()
    if ($headStartIdx -ge 0 -and $headEndIdx -gt $headStartIdx) {
        $hasMalformedChild = $false
        $hasHardcodedTitle = $false

        for ($i = $headStartIdx + 1; $i -lt $headEndIdx; $i++) {
            $t = $Tokens[$i]
            if ($t.Kind -eq 'Text' -and [string]::IsNullOrWhiteSpace($t.Raw)) { continue }
            if ($t.Kind -eq 'StartTag') {
                if ($t.TagName -eq 'title') {
                    $titleEndIdx = Find-TokenIndex -Tokens $Tokens -Kind 'EndTag' `
                        -Predicate { param($x) $x.TagName -eq 'title' } `
                        -StartAt $i
                    if ($titleEndIdx -gt $i) {
                        $bodyHasOnlyVar = $false
                        $bodyHasContent = $false
                        for ($k = $i + 1; $k -lt $titleEndIdx; $k++) {
                            $bt = $Tokens[$k]
                            if ($bt.Kind -eq 'Text' -and [string]::IsNullOrWhiteSpace($bt.Raw)) { continue }
                            $bodyHasContent = $true
                            if ($bt.Kind -eq 'PsInterp' -and
                                ($bt.Raw -eq '$browserTitle' -or $bt.Raw -eq '${browserTitle}')) {
                                $bodyHasOnlyVar = $true
                            } else {
                                $bodyHasOnlyVar = $false
                                break
                            }
                        }
                        if ($bodyHasContent -and -not $bodyHasOnlyVar) {
                            $hasHardcodedTitle = $true
                        }
                    }
                    $i = $titleEndIdx
                    continue
                }
                if ($t.TagName -eq 'link') {
                    $attrs = Get-AttributesFromToken -AttrText $t.AttrText
                    $href = Get-AttributeByName -Attrs $attrs -Name 'href'
                    if ($href) { $linkRefs += [string]$href.Value }
                    continue
                }
                # Anything other than title or link inside <head> is malformed.
                $hasMalformedChild = $true
                continue
            }
            if ($t.Kind -eq 'SelfClose') {
                if ($t.TagName -eq 'link') {
                    $attrs = Get-AttributesFromToken -AttrText $t.AttrText
                    $href = Get-AttributeByName -Attrs $attrs -Name 'href'
                    if ($href) { $linkRefs += [string]$href.Value }
                    continue
                }
                $hasMalformedChild = $true
                continue
            }
            if ($t.Kind -eq 'Comment') {
                # Comments in <head> are tolerated.
                continue
            }
            if ($t.Kind -eq 'PsInterp') {
                # Bare PS interpolation in <head> outside any element = malformed.
                $hasMalformedChild = $true
                continue
            }
        }

        if ($hasMalformedChild) { [void]$codes.Add('MALFORMED_HEAD') }
        if ($hasHardcodedTitle) { [void]$codes.Add('FORBIDDEN_HARDCODED_TITLE') }
    }

    # CSS reference count and order validation
    # Exactly two CSS references in <head>: the page-specific CSS first,
    # then cc-shared.css.
    if ($linkRefs.Count -ne 2) {
        [void]$codes.Add('UNEXPECTED_CSS_REFERENCE')
    } else {
        $first  = [System.IO.Path]::GetFileName($linkRefs[0])
        $second = [System.IO.Path]::GetFileName($linkRefs[1])
        if ($second -ne 'cc-shared.css' -and $first -eq 'cc-shared.css') {
            [void]$codes.Add('CSS_REFERENCE_ORDER_VIOLATION')
        }
    }

    # <body> attributes: section class, data-cc-page, data-cc-prefix
    $bodyStartIdx = Find-TokenIndex -Tokens $Tokens -Kind 'StartTag' `
        -Predicate { param($t) $t.TagName -eq 'body' }
    $bodyEndIdx = -1
    if ($bodyStartIdx -ge 0) {
        $bodyEndIdx = Find-TokenIndex -Tokens $Tokens -Kind 'EndTag' `
            -Predicate { param($t) $t.TagName -eq 'body' } `
            -StartAt $bodyStartIdx
        $bodyAttrs = $Tokens[$bodyStartIdx].AttrText
        if (-not (Test-AttrTextMatches -AttrText $bodyAttrs -Pattern 'class\s*=\s*["'']cc-section-[a-z0-9\-_]+[^"'']*["'']')) {
            [void]$codes.Add('MISSING_BODY_SECTION_CLASS')
        }
        if (-not (Test-AttrTextMatches -AttrText $bodyAttrs -Pattern 'data-cc-page\s*=\s*["''][^"'']+["'']')) {
            [void]$codes.Add('MISSING_DATA_CC_PAGE')
        }
        if (-not (Test-AttrTextMatches -AttrText $bodyAttrs -Pattern 'data-cc-prefix\s*=\s*["''][^"'']+["'']')) {
            [void]$codes.Add('MISSING_DATA_CC_PREFIX')
        }
    }

    # First content inside <body> must be $navHtml
    if ($bodyStartIdx -ge 0) {
        $afterBody = Find-NextSignificantToken -Tokens $Tokens -StartAt ($bodyStartIdx + 1)
        $hasNav = $false
        if ($afterBody -ge 0) {
            $t = $Tokens[$afterBody]
            if ($t.Kind -eq 'PsInterp' -and
                ($t.Raw -eq '$navHtml' -or $t.Raw -eq '${navHtml}')) {
                $hasNav = $true
            }
        }
        if (-not $hasNav) {
            [void]$codes.Add('MISSING_NAV_SUBSTITUTION')
        }
    }

    # Page header bar: first content after $navHtml must be cc-header-bar
    $headerBarFound = $false
    $hardcodedPageHeader = $false
    if ($bodyStartIdx -ge 0) {
        $navTokenIdx = -1
        for ($k = $bodyStartIdx + 1; $k -lt $Tokens.Count; $k++) {
            if ($k -gt $bodyEndIdx -and $bodyEndIdx -gt 0) { break }
            $tt = $Tokens[$k]
            if ($tt.Kind -eq 'PsInterp' -and ($tt.Raw -eq '$navHtml' -or $tt.Raw -eq '${navHtml}')) {
                $navTokenIdx = $k
                break
            }
        }
        $startFrom = if ($navTokenIdx -ge 0) { $navTokenIdx + 1 } else { $bodyStartIdx + 1 }
        $afterNav = Find-NextSignificantToken -Tokens $Tokens -StartAt $startFrom
        if ($afterNav -ge 0) {
            $tt = $Tokens[$afterNav]
            if ($tt.Kind -eq 'StartTag' -and $tt.TagName -eq 'div' -and
                (Test-AttrTextMatches -AttrText $tt.AttrText -Pattern 'class\s*=\s*["'']cc-header-bar["'']')) {
                $headerBarFound = $true
                $hbStart = $afterNav
                $hbEnd = Find-MatchingClose -Tokens $Tokens -StartTagIdx $hbStart
                $hasHeaderInterp = $false
                if ($hbEnd -gt $hbStart) {
                    for ($k = $hbStart + 1; $k -lt $hbEnd; $k++) {
                        $bt = $Tokens[$k]
                        if ($bt.Kind -eq 'PsInterp' -and
                            ($bt.Raw -eq '$headerHtml' -or $bt.Raw -eq '${headerHtml}')) {
                            $hasHeaderInterp = $true
                            break
                        }
                    }
                }
                if (-not $hasHeaderInterp) {
                    $hardcodedPageHeader = $true
                }
            }
        }
    }
    if (-not $headerBarFound -and $bodyStartIdx -ge 0) {
        [void]$codes.Add('MISSING_HEADER_BAR')
    }
    if ($hardcodedPageHeader) {
        [void]$codes.Add('FORBIDDEN_HARDCODED_PAGE_HEADER')
    }

    # Banner chrome: the connection and page-error banners are emitted by
    # Get-ChromeBannersHtml and included via the $bannerHtml substitution
    # (parallel to $navHtml / $headerHtml). The page shell must contain the
    # $bannerHtml PsInterp token; its absence fires MISSING_BANNER_SUBSTITUTION.
    $hasBannerSubstitution = $false
    for ($k = 0; $k -lt $Tokens.Count; $k++) {
        $t = $Tokens[$k]
        if ($t.Kind -eq 'PsInterp' -and ($t.Raw -eq '$bannerHtml' -or $t.Raw -eq '${bannerHtml}')) {
            $hasBannerSubstitution = $true
            break
        }
    }
    if (-not $hasBannerSubstitution) {
        [void]$codes.Add('MISSING_BANNER_SUBSTITUTION')
    }

    # Literal banner guard: a route must not hand-write a connection or
    # page-error banner div. The banner markup lives in Get-ChromeBannersHtml;
    # any literal <div id="cc-connection-banner"> or
    # <div id="cc-page-error-banner"> in a route file is drift, whether or not
    # it carries content. Fires FORBIDDEN_LITERAL_BANNER.
    $literalBannerFound = $false
    for ($k = 0; $k -lt $Tokens.Count; $k++) {
        $t = $Tokens[$k]
        if ($t.Kind -ne 'StartTag' -and $t.Kind -ne 'SelfClose') { continue }
        if ($t.TagName -ne 'div') { continue }
        if ((Test-AttrTextMatches -AttrText $t.AttrText -Pattern 'id\s*=\s*["'']cc-connection-banner["'']') -or
            (Test-AttrTextMatches -AttrText $t.AttrText -Pattern 'id\s*=\s*["'']cc-page-error-banner["'']')) {
            $literalBannerFound = $true
            break
        }
    }
    if ($literalBannerFound) {
        [void]$codes.Add('FORBIDDEN_LITERAL_BANNER')
    }

    # Shared script tag must be last inside <body>
    if ($bodyStartIdx -ge 0 -and $bodyEndIdx -gt $bodyStartIdx) {
        $scriptTags = @()
        for ($k = $bodyStartIdx + 1; $k -lt $bodyEndIdx; $k++) {
            $t = $Tokens[$k]
            if (($t.Kind -eq 'StartTag' -or $t.Kind -eq 'SelfClose') -and $t.TagName -eq 'script') {
                # Vendored library references are recognized, not counted:
                # exclude any <script> whose src bare filename is in the
                # vendored allow-list so they don't trip the single-tag
                # count or the shared-src check below.
                $sAttrs = Get-AttributesFromToken -AttrText $t.AttrText
                $sSrc   = Get-AttributeByName -Attrs $sAttrs -Name 'src'
                if ($null -ne $sSrc -and -not [string]::IsNullOrWhiteSpace($sSrc.Value)) {
                    $sBare = [System.IO.Path]::GetFileName([string]$sSrc.Value)
                    if ($VendoredJsFiles -contains $sBare) { continue }
                }
                $scriptTags += $k
            }
        }

        if ($scriptTags.Count -eq 0) {
            [void]$codes.Add('MISSING_SHARED_SCRIPT_TAG')
        } else {
            if ($scriptTags.Count -gt 1) {
                [void]$codes.Add('UNEXPECTED_SCRIPT_TAG')
            }
            # Validate the shared script tag's src attribute
            $sharedFound = $false
            foreach ($sIdx in $scriptTags) {
                $attrs = Get-AttributesFromToken -AttrText $Tokens[$sIdx].AttrText
                $src = Get-AttributeByName -Attrs $attrs -Name 'src'
                if ($src -and $src.Value -eq '/js/cc-shared.js') {
                    $sharedFound = $true
                }
            }
            if (-not $sharedFound) {
                if ($scriptTags.Count -gt 0) {
                    [void]$codes.Add('WRONG_SCRIPT_SOURCE')
                } else {
                    [void]$codes.Add('MISSING_SHARED_SCRIPT_TAG')
                }
            }

            # Content between last script and </body> = malformed
            $lastScriptIdx = $scriptTags[$scriptTags.Count - 1]
            $lastScriptClose = $lastScriptIdx
            if ($Tokens[$lastScriptIdx].Kind -eq 'StartTag') {
                $lastScriptClose = Find-TokenIndex -Tokens $Tokens -Kind 'EndTag' `
                    -Predicate { param($x) $x.TagName -eq 'script' } -StartAt $lastScriptIdx
                if ($lastScriptClose -lt 0) { $lastScriptClose = $lastScriptIdx }
            }
            for ($k = $lastScriptClose + 1; $k -lt $bodyEndIdx; $k++) {
                $t = $Tokens[$k]
                if ($t.Kind -eq 'Text' -and [string]::IsNullOrWhiteSpace($t.Raw)) { continue }
                [void]$codes.Add('MALFORMED_BODY_CLOSE')
                break
            }
        }
    }

    return $codes.ToArray()
}

<# ============================================================================
   FUNCTIONS: STRUCTURE AND CHROME VALIDATORS
   ----------------------------------------------------------------------------
   Structural validators for page-shell whitespace, attribute order, head
   composition, refresh info, and the connection / error banners.
   Prefix: (none)
   ============================================================================ #>
#
# Each function below contributes additional drift detection beyond the
# baseline Get-PageShellDrift / Invoke-PageChromeValidation pair. They are
# called from the per-file walk on Route files (or, where applicable, on
# all file kinds) after the main token walker has emitted per-construct
# rows. All drift attaches either to the file's HTML_FILE row or to the
# specific construct row at the offending location.

# Confirm a route file declares the page-shell substitution variables
# ($browserTitle, $navHtml, $headerHtml, $bannerHtml), each assigned from its
# matching Get-* helper; a missing one fires the corresponding MISSING_*_VAR
# code. The RHS must invoke the helper, so a literal-string assignment still
# counts as missing.
function Test-RouteVariableAssignments {
    param(
        [Parameter(Mandatory)]$Ast,
        [Parameter(Mandatory)]$FileRow
    )
    if ($null -eq $Ast) { return }

    # Required mapping: variable name -> required helper command name.
    $required = [ordered]@{
        'browserTitle' = @{ Helper = 'Get-PageBrowserTitle'; Code = 'MISSING_BROWSER_TITLE_VAR' }
        'navHtml'      = @{ Helper = 'Get-NavBarHtml';       Code = 'MISSING_NAV_HTML_VAR'     }
        'headerHtml'   = @{ Helper = 'Get-PageHeaderHtml';   Code = 'MISSING_HEADER_HTML_VAR'  }
        'bannerHtml'   = @{ Helper = 'Get-ChromeBannersHtml'; Code = 'MISSING_BANNER_HTML_VAR' }
    }

    # Find every assignment in the AST.
    $assignments = $Ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst]
    }, $true)

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    foreach ($asn in $assignments) {
        # Left side must be a variable expression.
        if (-not ($asn.Left -is [System.Management.Automation.Language.VariableExpressionAst])) { continue }
        $varName = $asn.Left.VariablePath.UserPath
        if ([string]::IsNullOrEmpty($varName)) { continue }
        if (-not $required.Contains($varName)) { continue }

        # Right side must contain a call to the matching helper.
        $expectedHelper = $required[$varName].Helper
        $rightCalls = $asn.Right.FindAll({
            param($n) $n -is [System.Management.Automation.Language.CommandAst]
        }, $true)
        $found = $false
        foreach ($cmd in $rightCalls) {
            $cmdName = Get-CommandAstName -CommandAst $cmd
            if ($cmdName -eq $expectedHelper) { $found = $true; break }
        }
        if ($found) { [void]$seen.Add($varName) }
    }

    foreach ($varName in $required.Keys) {
        if (-not $seen.Contains($varName)) {
            Add-DriftCode -Row $FileRow -Code $required[$varName].Code
        }
    }
}

# Route files emit HTML inline only; helpers live in modules. Fires
# FORBIDDEN_ROUTE_LOCAL_HELPER for every function defined inside an Add-PodeRoute
# ScriptBlock (determined by walking the parent chain to a route ScriptBlock
# before hitting any other function).
function Test-RouteLocalHelperFunctions {
    param(
        [Parameter(Mandatory)]$Ast,
        [Parameter(Mandatory)]$FileRow
    )
    if ($null -eq $Ast) { return }

    $fnDefs = $Ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $true)

    foreach ($fn in $fnDefs) {
        # Walk up from the function definition's parent.
        $cursor = $fn.Parent
        $insideRouteSb = $false
        while ($null -ne $cursor) {
            if ($cursor -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
                # Nested inside another function (not directly inside a route SB).
                break
            }
            if ($cursor -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
                $routePath = Get-AddPodeRoutePathForScriptBlock -ScriptBlockAst $cursor
                if ($null -ne $routePath) {
                    $insideRouteSb = $true
                    break
                }
            }
            $cursor = $cursor.Parent
        }
        if ($insideRouteSb) {
            $fnLine = if ($fn.Extent) { $fn.Extent.StartLineNumber } else { 0 }
            Add-DriftCode -Row $FileRow -Code 'FORBIDDEN_ROUTE_LOCAL_HELPER' `
                -Context "Function '$($fn.Name)' is defined inside a route ScriptBlock at line $fnLine."
        }
    }
}

# <body> may carry only cc-section-<key> and cc-* chrome classes. Page-prefixed
# classes on <body> are forbidden (it is platform-managed chrome, not page
# content) and fire FORBIDDEN_PAGE_PREFIXED_BODY_CLASS.
function Test-BodyClassPrefixDiscipline {
    param(
        [Parameter(Mandatory)]$Tokens,
        [Parameter(Mandatory)]$FileRow,
        [string]$PagePrefix
    )
    if ($null -eq $Tokens -or $Tokens.Count -eq 0) { return }
    if ([string]::IsNullOrEmpty($PagePrefix)) { return }

    $bodyIdx = Find-TokenIndex -Tokens $Tokens -Kind 'StartTag' `
        -Predicate { param($t) $t.TagName -eq 'body' }
    if ($bodyIdx -lt 0) { return }

    $bodyAttrs = Get-AttributesFromToken -AttrText $Tokens[$bodyIdx].AttrText
    $bodyClass = Get-AttributeByName -Attrs $bodyAttrs -Name 'class'
    if ($null -eq $bodyClass -or [string]::IsNullOrEmpty($bodyClass.Value)) { return }

    $expected = "$PagePrefix-"
    $tokens = @($bodyClass.Value.Trim() -split '\s+')
    foreach ($tk in $tokens) {
        if ([string]::IsNullOrEmpty($tk)) { continue }
        if ($tk.StartsWith($expected)) {
            Add-DriftCode -Row $FileRow -Code 'FORBIDDEN_PAGE_PREFIXED_BODY_CLASS' `
                -Context "Body class '$tk' carries the page prefix '$PagePrefix-'; only cc-section-<key> and cc- prefixed chrome classes are permitted on <body>."
        }
    }
}

# Verify the mandated page-shell landmarks appear in source order; any deviation
# fires MALFORMED_PAGE_SHELL_ORDER. This is the additive ordering catch-all --
# Get-PageShellDrift still fires MISSING_* for absent landmarks.
function Test-PageShellOrder {
    param(
        [Parameter(Mandatory)]$Tokens,
        [Parameter(Mandatory)]$FileRow
    )
    if ($null -eq $Tokens -or $Tokens.Count -eq 0) { return }

    # Build the landmark name list in source order.
    $landmarks = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $Tokens.Count; $i++) {
        $t = $Tokens[$i]
        if ($t.Kind -eq 'Doctype') { [void]$landmarks.Add('doctype'); continue }
        if ($t.Kind -eq 'StartTag') {
            switch ($t.TagName) {
                'html' { [void]$landmarks.Add('html'); continue }
                'head' { [void]$landmarks.Add('head'); continue }
                'body' { [void]$landmarks.Add('body'); continue }
                'div'  {
                    if (Test-AttrTextMatches -AttrText $t.AttrText -Pattern 'class\s*=\s*["'']cc-header-bar["'']') {
                        [void]$landmarks.Add('header-bar')
                    }
                    continue
                }
                'script' {
                    if (Test-AttrTextMatches -AttrText $t.AttrText -Pattern 'src\s*=\s*["'']/js/cc-shared\.js["'']') {
                        [void]$landmarks.Add('shared-script')
                    }
                    continue
                }
            }
        }
        if ($t.Kind -eq 'EndTag') {
            if ($t.TagName -eq 'head') { [void]$landmarks.Add('/head'); continue }
            if ($t.TagName -eq 'body') { [void]$landmarks.Add('/body'); continue }
        }
        if ($t.Kind -eq 'PsInterp' -and ($t.Raw -eq '$navHtml' -or $t.Raw -eq '${navHtml}')) {
            [void]$landmarks.Add('nav-html')
            continue
        }
        if ($t.Kind -eq 'PsInterp' -and ($t.Raw -eq '$bannerHtml' -or $t.Raw -eq '${bannerHtml}')) {
            [void]$landmarks.Add('banner-html')
            continue
        }
    }

    # Compare landmarks to expected order (first occurrence only). Missing ones
    # are not flagged here -- Get-PageShellDrift fires MISSING_* for those.
    $expectedOrder = @(
        'doctype','html','head','/head','body','nav-html',
        'header-bar','banner-html',
        'shared-script','/body'
    )

    $seenFirst = @{}
    foreach ($lm in $landmarks) {
        if (-not $seenFirst.ContainsKey($lm)) {
            $seenFirst[$lm] = $landmarks.IndexOf($lm)
        }
    }

    # Walk expected order; verify each seen landmark appears after the
    # previous seen one.
    $lastSeenIdx = -1
    $outOfOrder = $false
    $offending = $null
    $expectedAfter = $null
    foreach ($lm in $expectedOrder) {
        if (-not $seenFirst.ContainsKey($lm)) { continue }
        $idx = $seenFirst[$lm]
        if ($idx -lt $lastSeenIdx) {
            $outOfOrder = $true
            $offending = $lm
            break
        }
        $lastSeenIdx = $idx
        $expectedAfter = $lm
    }

    if ($outOfOrder) {
        Add-DriftCode -Row $FileRow -Code 'MALFORMED_PAGE_SHELL_ORDER' `
            -Context "Page shell landmark '$offending' appears out of template order (encountered before its expected predecessor in source)."
    }
}

# Enforce exactly one blank line between adjacent mandated page-shell elements,
# on the 4 pairs with well-defined single-element endpoints: </title>-><link
# page.css>, <link page.css>-><link cc-shared.css>, $navHtml-><cc-header-bar>,
# and </cc-header-bar>->$bannerHtml. Structural tags (DOCTYPE, <html>, <head>,
# <body>, etc.) and boundaries touching the "page-specific content" slot are NOT
# checked (ambiguous endpoint; a backlog item will formalize them).
# Q4 carve-out: multi-emission files skip the check, since concatenation-
# synthesized boundary whitespace isn't authored content.
function Test-PageShellWhitespace {
    param(
        [Parameter(Mandatory)]$Tokens,
        [Parameter(Mandatory)]$FileRow,
        [Parameter(Mandatory)][int]$EmissionCount
    )
    if ($null -eq $Tokens -or $Tokens.Count -eq 0) { return }
    # Q4 carve-out: skip multi-emission files
    if ($EmissionCount -ne 1) { return }

    # Locate endpoint tokens for each in-scope pair
    # Each in-scope pair's gap text is the Text tokens between the prior
    # landmark's end-token and the next landmark's start-token; it must contain
    # exactly one blank-line sequence.

    # Title and link locators (inside <head>)
    # <title> is a StartTag whose EndTag '</title>' closes it.
    # <link> elements are SelfClose tokens with rel="stylesheet".
    $titleStartIdx = -1
    $titleEndIdx   = -1
    $linkPageIdx   = -1
    $linkSharedIdx = -1

    for ($i = 0; $i -lt $Tokens.Count; $i++) {
        $t = $Tokens[$i]
        if ($t.Kind -eq 'StartTag' -and $t.TagName -eq 'title' -and $titleStartIdx -lt 0) {
            $titleStartIdx = $i
            continue
        }
        if ($t.Kind -eq 'EndTag' -and $t.TagName -eq 'title' -and $titleEndIdx -lt 0) {
            $titleEndIdx = $i
            continue
        }
        if (($t.Kind -eq 'SelfClose' -or $t.Kind -eq 'StartTag') -and $t.TagName -eq 'link') {
            if (-not (Test-AttrTextMatches -AttrText $t.AttrText -Pattern 'rel\s*=\s*["'']stylesheet["'']')) { continue }
            if (Test-AttrTextMatches -AttrText $t.AttrText -Pattern 'href\s*=\s*["'']/css/cc-shared\.css["'']') {
                if ($linkSharedIdx -lt 0) { $linkSharedIdx = $i }
            }
            elseif (Test-AttrTextMatches -AttrText $t.AttrText -Pattern 'href\s*=\s*["'']/css/[^"'']+\.css["'']') {
                if ($linkPageIdx -lt 0) { $linkPageIdx = $i }
            }
        }
    }

    # Body landmark locators
    # $navHtml is the PsInterp token whose Raw is '$navHtml' or '${navHtml}'.
    # $bannerHtml is the PsInterp token whose Raw is '$bannerHtml' or
    # '${bannerHtml}' (the connection + page-error banner chrome substitution).
    $navHtmlIdx          = -1
    $headerBarStartIdx   = -1
    $headerBarEndIdx     = -1
    $bannerHtmlIdx       = -1

    for ($i = 0; $i -lt $Tokens.Count; $i++) {
        $t = $Tokens[$i]
        if ($t.Kind -eq 'PsInterp' -and ($t.Raw -eq '$navHtml' -or $t.Raw -eq '${navHtml}')) {
            if ($navHtmlIdx -lt 0) { $navHtmlIdx = $i }
            continue
        }
        if ($t.Kind -eq 'PsInterp' -and ($t.Raw -eq '$bannerHtml' -or $t.Raw -eq '${bannerHtml}')) {
            if ($bannerHtmlIdx -lt 0) { $bannerHtmlIdx = $i }
            continue
        }
        if ($t.Kind -eq 'StartTag' -and $t.TagName -eq 'div') {
            if ($headerBarStartIdx -lt 0 -and (Test-AttrTextMatches -AttrText $t.AttrText -Pattern 'class\s*=\s*["'']cc-header-bar["'']')) {
                $headerBarStartIdx = $i
                $headerBarEndIdx   = Find-MatchingClose -Tokens $Tokens -StartTagIdx $i
                continue
            }
        }
    }

    # Inline helper: count blank lines in the gap between two token indices.
    # If a non-whitespace, non-Text token (e.g. a comment or unexpected element)
    # appears in the gap, the pair is silently skipped -- an intervening element
    # means the two aren't structurally adjacent in the spec's sense.
    $measureGap = {
        param([int]$PrevEndIdx, [int]$NextStartIdx, [string]$PairLabel)
        if ($PrevEndIdx -lt 0 -or $NextStartIdx -lt 0) { return }
        # nothing between
        if ($NextStartIdx -le $PrevEndIdx + 1) { return }

        $gapTextSb = New-Object System.Text.StringBuilder
        $intervening = $false
        for ($k = $PrevEndIdx + 1; $k -lt $NextStartIdx; $k++) {
            $tt = $Tokens[$k]
            if ($tt.Kind -eq 'Text') {
                [void]$gapTextSb.Append($tt.Raw)
                continue
            }
            # Any non-Text token (Comment, StartTag, etc.) breaks adjacency.
            $intervening = $true
            break
        }
        if ($intervening) { return }

        $gapText = $gapTextSb.ToString()
        $blankLineCount = ([regex]::Matches($gapText, "\r?\n\s*\r?\n")).Count
        if ($blankLineCount -ne 1) {
            Add-DriftCode -Row $FileRow -Code 'MALFORMED_PAGE_SHELL_WHITESPACE' `
                -Context "Whitespace at $PairLabel boundary contains $blankLineCount blank line(s); spec requires exactly 1."
        }
    }

    # Pair A: </title> -> <link page.css>
    & $measureGap $titleEndIdx $linkPageIdx "</title> -> <link page.css>"

    # Pair B: <link page.css> -> <link cc-shared.css>
    # Both link tokens are SelfClose (or StartTag for invalid markup), so
    # the prior landmark's last token IS the SelfClose token itself.
    & $measureGap $linkPageIdx $linkSharedIdx "<link page.css> -> <link cc-shared.css>"

    # Pair C: $navHtml -> <div class="cc-header-bar">
    & $measureGap $navHtmlIdx $headerBarStartIdx '$navHtml -> cc-header-bar'

    # Pair D: </div> of cc-header-bar -> $bannerHtml
    & $measureGap $headerBarEndIdx $bannerHtmlIdx 'cc-header-bar -> $bannerHtml'
}

# Test-AttributeOrder
# Verifies that attributes on mandated structural elements appear in the
# order shown in the spec template. Fires MALFORMED_ATTRIBUTE_ORDER on the
# file's HTML_FILE row for each violation.
#
# Check that mandated page-shell elements carry their attributes in template
# order (link: rel,href; body: class,data-cc-page,data-cc-prefix; script: src).
# Absent elements are not checked (Get-PageShellDrift fires MISSING_*).
function Test-AttributeOrder {
    param(
        [Parameter(Mandatory)]$Tokens,
        [Parameter(Mandatory)]$FileRow
    )
    if ($null -eq $Tokens -or $Tokens.Count -eq 0) { return }

    # tag name -> expected attribute order
    $expectedOrders = @{
        'link'   = @('rel','href')
        'body'   = @('class','data-cc-page','data-cc-prefix')
        'script' = @('src')
    }

    for ($i = 0; $i -lt $Tokens.Count; $i++) {
        $t = $Tokens[$i]
        if ($t.Kind -ne 'StartTag' -and $t.Kind -ne 'SelfClose') { continue }
        if (-not $expectedOrders.ContainsKey($t.TagName)) { continue }
        if ([string]::IsNullOrWhiteSpace($t.AttrText)) { continue }
        $expected = $expectedOrders[$t.TagName]
        $attrs = Get-AttributesFromToken -AttrText $t.AttrText
        if ($null -eq $attrs -or $attrs.Count -eq 0) { continue }

        # Build the ordered list of attribute names that ARE in the
        # expected list (other attrs ignored; they're flagged separately).
        $observed = @()
        foreach ($a in $attrs) {
            if ($expected -contains $a.Name) { $observed += $a.Name }
        }
        # Build the expected sub-sequence keeping only names that appear.
        $expectedSub = @()
        foreach ($n in $expected) {
            if ($observed -contains $n) { $expectedSub += $n }
        }
        # Compare order.
        if ($observed.Count -gt 1) {
            $outOfOrder = $false
            for ($k = 0; $k -lt $observed.Count; $k++) {
                if ($observed[$k] -ne $expectedSub[$k]) { $outOfOrder = $true; break }
            }
            if ($outOfOrder) {
                $absLine = $t.LineOffset
                Add-DriftCode -Row $FileRow -Code 'MALFORMED_ATTRIBUTE_ORDER' `
                    -Context "Attribute order on <$($t.TagName)> at line offset $absLine is [$($observed -join ', ')]; spec template requires [$($expectedSub -join ', ')]."
            }
        }
    }
}

# An element carrying a data-action-<event> must be interactive (button, a,
# input, select, textarea) or an overlay outer container (cc-modal-overlay /
# cc-slide-overlay / cc-slideup-overlay -- the click-outside-to-dismiss
# carve-out). Anything else fires ACTION_ON_NON_INTERACTIVE_ELEMENT on the
# data-action attribute's row.
function Test-ActionElementType {
    param(
        [Parameter(Mandatory)]$Tokens,
        [Parameter(Mandatory)][int]$FileLine0
    )
    if ($null -eq $Tokens -or $Tokens.Count -eq 0) { return }

    for ($i = 0; $i -lt $Tokens.Count; $i++) {
        $t = $Tokens[$i]
        if ($t.Kind -ne 'StartTag' -and $t.Kind -ne 'SelfClose') { continue }
        if ([string]::IsNullOrWhiteSpace($t.AttrText)) { continue }
        $attrs = Get-AttributesFromToken -AttrText $t.AttrText

        # Does this element carry any data-action-<event>?
        $eventAttrs = @()
        foreach ($a in $attrs) {
            $kind = Get-DataActionAttributeKind -AttrName $a.Name
            if ($kind -eq 'event' -or $kind -eq 'unknown-event') {
                $eventAttrs += $a
            }
        }
        if ($eventAttrs.Count -eq 0) { continue }

        # Check element eligibility.
        $isInteractive = ($ActionPermittedTags -contains $t.TagName)
        $isOverlayContainer = $false
        if (-not $isInteractive) {
            $classAttr = Get-AttributeByName -Attrs $attrs -Name 'class'
            if ($null -ne $classAttr -and -not [string]::IsNullOrEmpty($classAttr.Value)) {
                $classTokens = @($classAttr.Value.Trim() -split '\s+')
                foreach ($cls in $classTokens) {
                    if ($ActionPermittedOverlayClasses -contains $cls) {
                        $isOverlayContainer = $true
                        break
                    }
                }
            }
        }
        if ($isInteractive -or $isOverlayContainer) { continue }

        # Drift: attach ACTION_ON_NON_INTERACTIVE_ELEMENT to each event
        # attribute's row on this element.
        $absLine = $FileLine0 + $t.LineOffset
        foreach ($evAttr in $eventAttrs) {
            $matchingRow = $null
            foreach ($r in $script:rows) {
                if ($r.FileName -eq $script:CurrentFile -and
                    $r.ComponentType -eq 'HTML_DATA_ATTRIBUTE' -and
                    $r.ComponentName -eq $evAttr.Name -and
                    $r.LineStart -eq $absLine) {
                    $matchingRow = $r
                    break
                }
            }
            if ($null -ne $matchingRow) {
                Add-DriftCode -Row $matchingRow -Code 'ACTION_ON_NON_INTERACTIVE_ELEMENT' `
                    -Context "Element <$($t.TagName)> carries action attribute '$($evAttr.Name)' but is not an interactive element and not an overlay outer container."
            }
        }
    }
}

# For an element with both an event attribute and argument attributes, each
# argument attribute name's prefix must match the parent action value's prefix
# (e.g. data-action-click="bsv-open" requires data-action-bsv-*). A mismatch
# fires ARGUMENT_PREFIX_MISMATCH on the argument attribute's row.
function Test-ArgumentPrefixMatch {
    param(
        [Parameter(Mandatory)]$Tokens,
        [Parameter(Mandatory)][int]$FileLine0
    )
    if ($null -eq $Tokens -or $Tokens.Count -eq 0) { return }

    for ($i = 0; $i -lt $Tokens.Count; $i++) {
        $t = $Tokens[$i]
        if ($t.Kind -ne 'StartTag' -and $t.Kind -ne 'SelfClose') { continue }
        if ([string]::IsNullOrWhiteSpace($t.AttrText)) { continue }
        $attrs = Get-AttributesFromToken -AttrText $t.AttrText

        # Find the element's parent action value's prefix. Take the first
        # event attribute on the element; that's the action whose prefix
        # arguments must match.
        $actionPrefix = $null
        foreach ($a in $attrs) {
            $kind = Get-DataActionAttributeKind -AttrName $a.Name
            if ($kind -ne 'event' -and $kind -ne 'unknown-event') { continue }
            if (-not [string]::IsNullOrEmpty($a.Value) -and -not $a.HasPureInterp) {
                $actionPrefix = Get-ActionValuePrefix -Value $a.Value
            }
            break
        }
        if ([string]::IsNullOrEmpty($actionPrefix)) { continue }

        # For each argument attribute, extract its prefix and compare.
        $absLine = $FileLine0 + $t.LineOffset
        foreach ($a in $attrs) {
            $kind = Get-DataActionAttributeKind -AttrName $a.Name
            if ($kind -ne 'argument') { continue }
            $argPrefix = Get-ArgumentAttributePrefix -AttrName $a.Name
            if ([string]::IsNullOrEmpty($argPrefix)) { continue }
            if ($argPrefix -eq $actionPrefix) { continue }

            $matchingRow = $null
            foreach ($r in $script:rows) {
                if ($r.FileName -eq $script:CurrentFile -and
                    $r.ComponentType -eq 'HTML_DATA_ATTRIBUTE' -and
                    $r.ComponentName -eq $a.Name -and
                    $r.LineStart -eq $absLine) {
                    $matchingRow = $r
                    break
                }
            }
            if ($null -ne $matchingRow) {
                Add-DriftCode -Row $matchingRow -Code 'ARGUMENT_PREFIX_MISMATCH' `
                    -Context "Argument attribute '$($a.Name)' carries prefix '$argPrefix'; parent action value's prefix is '$actionPrefix'."
            }
        }
    }
}

# Test-PlatformDataAttributeClosedSet
# data-cc-* attributes belong to a closed platform-owned set. Any data-cc-*
# attribute name outside the set fires UNREGISTERED_PLATFORM_DATA_ATTRIBUTE
# on the attribute's row.
function Test-PlatformDataAttributeClosedSet {
    param(
        [Parameter(Mandatory)]$Tokens,
        [Parameter(Mandatory)][int]$FileLine0
    )
    if ($null -eq $Tokens -or $Tokens.Count -eq 0) { return }

    for ($i = 0; $i -lt $Tokens.Count; $i++) {
        $t = $Tokens[$i]
        if ($t.Kind -ne 'StartTag' -and $t.Kind -ne 'SelfClose') { continue }
        if ([string]::IsNullOrWhiteSpace($t.AttrText)) { continue }
        $attrs = Get-AttributesFromToken -AttrText $t.AttrText
        $absLine = $FileLine0 + $t.LineOffset
        foreach ($a in $attrs) {
            if ($a.Name -notlike 'data-cc-*') { continue }
            if ($PlatformDataAttributes -contains $a.Name) { continue }

            $matchingRow = $null
            foreach ($r in $script:rows) {
                if ($r.FileName -eq $script:CurrentFile -and
                    $r.ComponentType -eq 'HTML_DATA_ATTRIBUTE' -and
                    $r.ComponentName -eq $a.Name -and
                    $r.LineStart -eq $absLine) {
                    $matchingRow = $r
                    break
                }
            }
            if ($null -ne $matchingRow) {
                Add-DriftCode -Row $matchingRow -Code 'UNREGISTERED_PLATFORM_DATA_ATTRIBUTE' `
                    -Context "Attribute name '$($a.Name)' is not in the platform-owned closed set."
            }
        }
    }
}

<# ============================================================================
   FUNCTIONS: MAIN TOKEN WALKER
   ----------------------------------------------------------------------------
   Walk the token stream for one HTML emission, emitting construct rows
   and accumulating overlay constructs for post-walk validation.
   Prefix: (none)
   ============================================================================ #>
#
# Walk the tokenized HTML for one emission, emitting all per-construct rows and
# drift codes. Returns an object whose .OverlayConstructs list (each recording
# the outer token index, kind, id, line, and purpose comment) feeds the
# post-walk contiguity and structural validators.
function Invoke-HtmlTokenWalk {
    param(
        [Parameter(Mandatory)]$Tokens,
        [Parameter(Mandatory)][int]$FileLine0,
        [string]$ParentFunction,
        [Parameter(Mandatory)][ValidateSet('LOCAL','SHARED')][string]$DataScope,
        [Parameter(Mandatory)][bool]$IsHelperEmission,
        [string]$PagePrefix,
        $CallerGivenVars
    )

    # Normalize CallerGivenVars to a HashSet (handles $null, arrays, hashsets).
    if ($null -eq $CallerGivenVars) {
        $CallerGivenVars = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    } elseif (-not ($CallerGivenVars -is [System.Collections.Generic.HashSet[string]])) {
        $hs = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($v in $CallerGivenVars) { [void]$hs.Add([string]$v) }
        $CallerGivenVars = $hs
    }

    $result = [ordered]@{
        OverlayConstructs = New-Object System.Collections.Generic.List[object]
    }

    if ($null -eq $Tokens -or $Tokens.Count -eq 0) { return $result }

    # Pre-pass: pin each non-whitespace token to its most-recently-preceding
    # comment token (if any). Used by overlay construct detection to attach
    # the purpose comment to its outer element.
    $pendingCommentByTokenIdx = @{}
    $lastCommentTokenIdx = -1
    for ($i = 0; $i -lt $Tokens.Count; $i++) {
        $t = $Tokens[$i]
        if ($t.Kind -eq 'Comment') {
            $lastCommentTokenIdx = $i
            continue
        }
        if ($t.Kind -eq 'Text' -and [string]::IsNullOrWhiteSpace($t.Raw)) { continue }
        if ($lastCommentTokenIdx -ge 0) {
            $pendingCommentByTokenIdx[$i] = $lastCommentTokenIdx
        }
        $lastCommentTokenIdx = -1
    }

    # Open-element stack (each entry: Tag + ClassValue) so a text emission can
    # peek the top to derive its categorical name. StartTags push; SelfClose and
    # void elements never push; EndTag pops the matching top (mismatches
    # tolerated).
    $elementStack = New-Object System.Collections.Generic.Stack[object]

    # Walk every token.
    for ($i = 0; $i -lt $Tokens.Count; $i++) {
        $t = $Tokens[$i]
        $absLine = $FileLine0 + $t.LineOffset

        # Element stack maintenance: handle EndTag
        if ($t.Kind -eq 'EndTag') {
            if ($elementStack.Count -gt 0 -and $elementStack.Peek().Tag -eq $t.TagName) {
                [void]$elementStack.Pop()
            }
            continue
        }

        # Comment rows
        if ($t.Kind -eq 'Comment') {
            $body = $t.Body
            $bodyTrim = if ($null -ne $body) { $body.Trim() } else { '' }

            # Classify the comment. Kinds:
            #   comment-section-divider  - structural divider banners
            #   comment-panel-purpose    - immediately precedes an overlay
            #                              construct (modal/slideout/slideup)
            #   comment-inline           - any other comment
            $kind = 'comment-inline'
            if ($bodyTrim -match '^[=\-_*]{5,}$') {
                $kind = 'comment-section-divider'
            } elseif ($bodyTrim -match '^[A-Z][A-Z\s_]+$' -and $bodyTrim.Length -gt 5) {
                $kind = 'comment-section-divider'
            }

            # Check next significant token: if it's an outer overlay
            # element (class cc-modal-overlay / cc-slide-overlay /
            # cc-slideup-overlay), classify as comment-panel-purpose.
            $nextSigIdx = Find-NextSignificantToken -Tokens $Tokens -StartAt ($i + 1)
            if ($nextSigIdx -ge 0) {
                $nt = $Tokens[$nextSigIdx]
                if ($nt.Kind -eq 'StartTag' -or $nt.Kind -eq 'SelfClose') {
                    $nattrs = Get-AttributesFromToken -AttrText $nt.AttrText
                    $nclass = Get-AttributeByName -Attrs $nattrs -Name 'class'
                    if ($nclass -and -not [string]::IsNullOrEmpty($nclass.Value)) {
                        $ok = Get-OverlayKindFromClass -ClassValue $nclass.Value
                        if ($null -ne $ok) {
                            $kind = 'comment-panel-purpose'
                        }
                    }
                }
            }

            $commentCodes = New-Object System.Collections.Generic.List[string]
            if ($t.Unclosed) { [void]$commentCodes.Add('MALFORMED_COMMENT_UNCLOSED') }
            if ($null -ne $body -and $body -match '--') {
                [void]$commentCodes.Add('MALFORMED_COMMENT_DASHES')
            }
            if ($null -ne $body -and ($body -match '\$\(' -or $body -match '\$\{' -or $body -match '\$[A-Za-z_]')) {
                [void]$commentCodes.Add('FORBIDDEN_COMMENT_INTERPOLATION')
            }

            Add-HtmlCommentRow `
                -Kind            $kind `
                -LineStart       $absLine `
                -LineEnd         $absLine `
                -ColumnStart     $t.ColumnStart `
                -Signature       $t.Raw `
                -ParentFunction  $ParentFunction `
                -RawText         $bodyTrim `
                -PurposeDescription $(if ($kind -eq 'comment-panel-purpose') { $bodyTrim } else { $null }) `
                -DriftCodes      @($commentCodes.ToArray()) | Out-Null
            continue
        }

        # Entity rows
        if ($t.Kind -eq 'Entity') {
            $specForm = switch ($t.Form) {
                'Named'   { 'entity_named' }
                'Numeric' { 'entity_numeric' }
                'Hex'     { 'entity_numeric' }
                default   { 'entity_named' }
            }
            Add-HtmlEntityRow `
                -Literal        $t.Raw `
                -SpecForm       $specForm `
                -LineStart      $absLine `
                -ColumnStart    $t.ColumnStart `
                -ParentFunction $ParentFunction `
                -RawText        $t.Raw | Out-Null
            continue
        }

        # Text rows
        if ($t.Kind -eq 'Text') {
            if (-not [string]::IsNullOrWhiteSpace($t.Raw)) {
                $parentTag = ''
                $parentClass = ''
                if ($elementStack.Count -gt 0) {
                    $top = $elementStack.Peek()
                    $parentTag = $top.Tag
                    $parentClass = $top.ClassValue
                }
                $textComponentName = Get-HtmlTextCategoricalName `
                    -ParentTag   $parentTag `
                    -ParentClass $parentClass `
                    -PagePrefix  $PagePrefix
                Add-HtmlTextRow `
                    -ComponentName  $textComponentName `
                    -LineStart      $absLine `
                    -ColumnStart    $t.ColumnStart `
                    -Signature      ($t.Raw -replace '\s+', ' ').Trim() `
                    -ParentFunction $ParentFunction `
                    -RawText        $t.Raw | Out-Null
            }
            continue
        }

        # StartTag / SelfClose tokens
        if ($t.Kind -ne 'StartTag' -and $t.Kind -ne 'SelfClose') { continue }

        # Parse attributes once at the top of the StartTag handler so the
        # element-stack push has access to the class value and downstream
        # per-attribute processing can reuse the same parse result.
        $attrs = $null
        if (-not [string]::IsNullOrWhiteSpace($t.AttrText)) {
            $attrs = Get-AttributesFromToken -AttrText $t.AttrText
        }

        # Overlay construct discovery (outer overlay element, or dock)
        # Capture dock/overlay construct entries (by class, not id, so the
        # structural validator catches them even when the id is missing). Docks
        # (OverlayKind 'dock') are validated separately in the post-walk.
        if ($t.Kind -eq 'StartTag' -and $null -ne $attrs) {
            $classAttrForOverlay = Get-AttributeByName -Attrs $attrs -Name 'class'
            $idAttrForOverlay    = Get-AttributeByName -Attrs $attrs -Name 'id'
            $overlayKindByClass  = if ($null -ne $classAttrForOverlay) {
                Get-OverlayKindFromClass -ClassValue $classAttrForOverlay.Value
            } else { $null }
            if ($null -ne $overlayKindByClass) {
                $idVal = if ($null -ne $idAttrForOverlay) { $idAttrForOverlay.Value } else { $null }
                $purposeText = $null
                $hasPurpose = $false
                if ($pendingCommentByTokenIdx.ContainsKey($i)) {
                    $cIdx = $pendingCommentByTokenIdx[$i]
                    $cToken = $Tokens[$cIdx]
                    $cBody = if ($null -ne $cToken.Body) { $cToken.Body.Trim() } else { '' }
                    if (-not [string]::IsNullOrWhiteSpace($cBody)) {
                        $hasPurpose = $true
                        $purposeText = $cBody
                    }
                }
                $result.OverlayConstructs.Add([ordered]@{
                    OuterTokenIdx       = $i
                    OverlayKind         = $overlayKindByClass
                    IdValue             = $idVal
                    AbsLine             = $absLine
                    HasPurposeComment   = $hasPurpose
                    PurposeCommentText  = $purposeText
                }) | Out-Null
            }
        }

        # ---- Element stack maintenance: push for non-self-closing,
        # non-void StartTag tokens. SelfClose tokens are skipped entirely
        # because they have no body; void elements are skipped because
        # they cannot have content. The svg element is also skipped
        # because the walker uses a fast-path (below) that jumps past
        # </svg> without ever encountering the matching EndTag token.
        if ($t.Kind -eq 'StartTag' -and
            $null -ne $t.TagName -and
            $t.TagName.ToLowerInvariant() -ne 'svg' -and
            $HtmlVoidElements -notcontains $t.TagName.ToLowerInvariant()) {
            $classAttr = if ($null -ne $attrs) { Get-AttributeByName -Attrs $attrs -Name 'class' } else { $null }
            $classValue = if ($null -ne $classAttr) { [string]$classAttr.Value } else { '' }
            [void]$elementStack.Push([ordered]@{
                Tag        = $t.TagName.ToLowerInvariant()
                ClassValue = $classValue
            })
        }

        # SVG outer-element capture
        if ($t.TagName -eq 'svg') {
            $svgEndIdx = Find-TokenIndex -Tokens $Tokens -Kind 'EndTag' `
                -Predicate { param($x) $x.TagName -eq 'svg' } -StartAt $i
            $endLine = $absLine
            $rawSvg  = $t.Raw
            $hasInterp = $false
            if ($svgEndIdx -gt $i) {
                $endLine = $FileLine0 + $Tokens[$svgEndIdx].LineOffset
                $sbSvg = New-Object System.Text.StringBuilder
                for ($k = $i; $k -le $svgEndIdx; $k++) {
                    [void]$sbSvg.Append($Tokens[$k].Raw)
                    if ($Tokens[$k].Kind -eq 'PsInterp') { $hasInterp = $true }
                }
                $rawSvg = $sbSvg.ToString()
            }
            $svgCodes = New-Object System.Collections.Generic.List[string]
            if ($hasInterp -and $rawSvg -match '\$\([^)]*\)' -and $rawSvg -match '\$\{[^}]*\}') {
                [void]$svgCodes.Add('MALFORMED_SVG_INTERPOLATION')
            }
            Add-HtmlSvgRow `
                -ComponentName     'inline-svg' `
                -LineStart         $absLine `
                -LineEnd           $endLine `
                -ColumnStart       $t.ColumnStart `
                -Signature         $t.Raw `
                -ParentFunction    $ParentFunction `
                -RawText           $rawSvg `
                -HasDynamicContent ([Nullable[bool]]$hasInterp) `
                -DriftCodes        @($svgCodes.ToArray()) | Out-Null
            if ($svgEndIdx -gt $i) { $i = $svgEndIdx }
            continue
        }

        # Inline <style> block forbidden - attach to HTML_FILE row.
        # Per the access-denied carve-out, a <style> block inside
        # the Get-AccessDeniedHtml helper is permitted and does not fire.
        # The carve-out page is self-contained: it defines its own classes
        # in this <style> block and uses them in its own markup. Emit a
        # CSS_CLASS DEFINITION row for each class defined here so the
        # resolver's same-file edge can match the page's own usages. The
        # carve-out is enforced here (only this function), not in the
        # resolver, so no other file can self-resolve inline-style classes.
        if ($t.TagName -eq 'style' -and $t.Kind -eq 'StartTag') {
            if ($ParentFunction -ne 'Get-AccessDeniedHtml') {
                if ($script:htmlFileRowByFile.ContainsKey($script:CurrentFile)) {
                    Add-DriftCode -Row $script:htmlFileRowByFile[$script:CurrentFile] `
                        -Code 'FORBIDDEN_INLINE_STYLE_BLOCK' `
                        -Context "Inline <style> block at line $absLine"
                }
            }
            else {
                # Accumulate the style block's inner text, then emit one
                # CSS_CLASS DEFINITION row per bare class selector defined in it.
                $styleEndIdx = Find-TokenIndex -Tokens $Tokens -Kind 'EndTag' `
                    -Predicate { param($x) $x.TagName -eq 'style' } -StartAt $i
                if ($styleEndIdx -gt $i) {
                    $sbStyle = New-Object System.Text.StringBuilder
                    for ($k = $i + 1; $k -lt $styleEndIdx; $k++) {
                        if ($Tokens[$k].Kind -eq 'Text') { [void]$sbStyle.Append($Tokens[$k].Raw) }
                    }
                    $styleText = $sbStyle.ToString()
                    $seenStyleClass = @{}
                    foreach ($m in [regex]::Matches($styleText, '\.(-?[A-Za-z_][A-Za-z0-9_-]*)')) {
                        $clsName = $m.Groups[1].Value
                        if ($seenStyleClass.ContainsKey($clsName)) { continue }
                        $seenStyleClass[$clsName] = $true
                        $defRow = New-HtmlRow `
                            -ComponentType 'CSS_CLASS' `
                            -ComponentName $clsName `
                            -ReferenceType 'DEFINITION' `
                            -Scope         'LOCAL' `
                            -LineStart     $absLine `
                            -ColumnStart   $t.ColumnStart `
                            -Signature     ".$clsName" `
                            -ParentFunction $ParentFunction `
                            -RawText       ".$clsName"
                        $script:rows.Add($defRow)
                    }
                }
            }
        }

        # Inline <script> body content forbidden
        if ($t.TagName -eq 'script' -and $t.Kind -eq 'StartTag') {
            $scriptEndIdx = Find-TokenIndex -Tokens $Tokens -Kind 'EndTag' `
                -Predicate { param($x) $x.TagName -eq 'script' } -StartAt $i
            if ($scriptEndIdx -gt $i) {
                $hasBody = $false
                for ($k = $i + 1; $k -lt $scriptEndIdx; $k++) {
                    $bt = $Tokens[$k]
                    if ($bt.Kind -eq 'Text' -and [string]::IsNullOrWhiteSpace($bt.Raw)) { continue }
                    $hasBody = $true
                    break
                }
                if ($hasBody -and $script:htmlFileRowByFile.ContainsKey($script:CurrentFile)) {
                    Add-DriftCode -Row $script:htmlFileRowByFile[$script:CurrentFile] `
                        -Code 'FORBIDDEN_INLINE_SCRIPT_BLOCK' `
                        -Context "Inline <script> body at line $absLine"
                }
            }
        }

        # Skip downstream per-attribute work for elements with no attributes.
        if ($null -eq $attrs -or $attrs.Count -eq 0) { continue }

        $tagName = $t.TagName

        # Asset references: <link rel="stylesheet" ...>
        if ($tagName -eq 'link') {
            $rel  = Get-AttributeByName -Attrs $attrs -Name 'rel'
            $href = Get-AttributeByName -Attrs $attrs -Name 'href'
            if ($rel -and $href -and $rel.Value -and $rel.Value.Trim().ToLower() -eq 'stylesheet' -and -not [string]::IsNullOrWhiteSpace($href.Value)) {
                $linkCodes = New-Object System.Collections.Generic.List[string]
                if ($IsHelperEmission) { [void]$linkCodes.Add('FORBIDDEN_HELPER_ASSET_REFERENCE') }
                $allowedLinkAttrs = @('rel','href')
                foreach ($a in $attrs) {
                    if ($allowedLinkAttrs -notcontains $a.Name) {
                        if (-not $linkCodes.Contains('MALFORMED_CSS_LINK')) { [void]$linkCodes.Add('MALFORMED_CSS_LINK') }
                    }
                }
                $hrefVal = [string]$href.Value
                $bare = [System.IO.Path]::GetFileName($hrefVal)
                if ($bare -eq 'cc-shared.css') {
                    if ($hrefVal -ne '/css/cc-shared.css') {
                        [void]$linkCodes.Add('MALFORMED_SHARED_CSS_REFERENCE')
                    }
                } else {
                    if ($hrefVal -notmatch '^/css/[a-z][a-z0-9\-]*\.css$') {
                        [void]$linkCodes.Add('MALFORMED_PAGE_CSS_REFERENCE')
                    }
                }
                Add-CssFileUsageRow `
                    -Href            $hrefVal `
                    -LineStart       $absLine `
                    -ColumnStart     $t.ColumnStart `
                    -Signature       $t.Raw `
                    -ParentFunction  $ParentFunction `
                    -RawText         $t.Raw `
                    -HasDynamicContent ([Nullable[bool]]$href.HasInterp) `
                    -DriftCodes      @($linkCodes.ToArray()) | Out-Null
            }
        }
        elseif ($tagName -eq 'script') {
            $src = Get-AttributeByName -Attrs $attrs -Name 'src'
            if ($src -and -not [string]::IsNullOrWhiteSpace($src.Value)) {
                $scriptCodes = New-Object System.Collections.Generic.List[string]
                if ($IsHelperEmission -and $src.Value -ne '/js/cc-shared.js') {
                    [void]$scriptCodes.Add('FORBIDDEN_HELPER_ASSET_REFERENCE')
                }
                $allowedScriptAttrs = @('src')
                foreach ($a in $attrs) {
                    if ($allowedScriptAttrs -notcontains $a.Name) {
                        if (-not $scriptCodes.Contains('MALFORMED_JS_SCRIPT')) { [void]$scriptCodes.Add('MALFORMED_JS_SCRIPT') }
                    }
                }
                $srcBare = [System.IO.Path]::GetFileName([string]$src.Value)
                if ($src.Value -ne '/js/cc-shared.js' -and $VendoredJsFiles -notcontains $srcBare) {
                    [void]$scriptCodes.Add('WRONG_SCRIPT_SOURCE')
                }
                Add-JsFileUsageRow `
                    -Src             $src.Value `
                    -LineStart       $absLine `
                    -ColumnStart     $t.ColumnStart `
                    -Signature       $t.Raw `
                    -ParentFunction  $ParentFunction `
                    -RawText         $t.Raw `
                    -HasDynamicContent ([Nullable[bool]]$src.HasInterp) `
                    -DriftCodes      @($scriptCodes.ToArray()) | Out-Null
            }
        }

        # Per-attribute row extraction
        # Pre-pass: detect whether this element has any data-action-<event>
        # attribute. The flag is needed for orphan-argument detection.
        $elementHasEventAttribute = $false
        foreach ($a in $attrs) {
            if ([string]::IsNullOrEmpty($a.Name)) { continue }
            $kind = Get-DataActionAttributeKind -AttrName $a.Name
            if ($kind -eq 'event' -or $kind -eq 'unknown-event') {
                $elementHasEventAttribute = $true
                break
            }
        }

        foreach ($a in $attrs) {
            if ([string]::IsNullOrEmpty($a.Name)) { continue }

            # id="..." -> HTML_ID
            if ($a.Name -eq 'id') {
                if (-not [string]::IsNullOrWhiteSpace($a.Value) -and -not $a.HasPureInterp) {
                    $idCodes = @(Get-IdValueDriftCodes -IdValue $a.Value -PagePrefix $PagePrefix -IsHelperEmission $IsHelperEmission)

                    # Overlay-ID shape check (single-rooted form,
                    # <prefix>-modal-<purpose> etc). An id is treated as an
                    # overlay-outer id only when its element also carries the
                    # matching cc-*-overlay class. This prevents a natural
                    # inner id such as <prefix>-slideout-title (the dialog
                    # title element, which has no overlay class) from being
                    # mistaken for an overlay outer and drawing a spurious
                    # MISSING_PANEL_PURPOSE_COMMENT or MALFORMED_*_ID.
                    $oinfo = Get-OverlayIdInfo -IdValue $a.Value
                    $elementOverlayClass = $null
                    $classAttrForOverlayId = Get-AttributeByName -Attrs $attrs -Name 'class'
                    if ($null -ne $classAttrForOverlayId) {
                        $elementOverlayClass = Get-OverlayKindFromClass -ClassValue $classAttrForOverlayId.Value
                    }
                    $purposeText = $null
                    $hasPurpose = $false
                    if ($null -ne $oinfo.OverlayKind -and $null -ne $elementOverlayClass) {
                        if ($null -ne $oinfo.DriftCode) { $idCodes += $oinfo.DriftCode }
                        # Purpose comment for overlay outer elements
                        if ($pendingCommentByTokenIdx.ContainsKey($i)) {
                            $cIdx = $pendingCommentByTokenIdx[$i]
                            $cToken = $Tokens[$cIdx]
                            $cBody = if ($null -ne $cToken.Body) { $cToken.Body.Trim() } else { '' }
                            if (-not [string]::IsNullOrWhiteSpace($cBody)) {
                                $hasPurpose = $true
                                $purposeText = $cBody
                            }
                        }
                        if (-not $hasPurpose) {
                            $idCodes += 'MISSING_PANEL_PURPOSE_COMMENT'
                        }
                    }

                    Add-HtmlIdRow `
                        -IdValue            $a.Value `
                        -LineStart          $absLine `
                        -ColumnStart        $t.ColumnStart `
                        -Signature          "id=`"$($a.Value)`"" `
                        -ParentFunction     $ParentFunction `
                        -RawText            "id=`"$($a.Value)`"" `
                        -PurposeDescription $purposeText `
                        -HasDynamicContent  ([Nullable[bool]]$a.HasInterp) `
                        -DriftCodes         $idCodes | Out-Null
                }
                continue
            }

            # class="..." -> one CSS_CLASS USAGE per static class name
            if ($a.Name -eq 'class') {
                if (-not [string]::IsNullOrWhiteSpace($a.Value)) {
                    $classCodes = @(Get-ClassValueDriftCodes -Value $a.Value)
                    $classTokens = Split-StaticClassTokens -Value $a.Value
                    foreach ($cls in $classTokens) {
                        $perClassCodes = @($classCodes)
                        if (-not $IsHelperEmission -and -not [string]::IsNullOrEmpty($PagePrefix)) {
                            $expectedPrefix = "$PagePrefix-"
                            $isCcPrefixed = $cls.StartsWith('cc-')
                            if (-not $cls.StartsWith($expectedPrefix) -and -not $isCcPrefixed) {
                                $perClassCodes += 'CLASS_PREFIX_MISMATCH'
                            }
                        }
                        # Helper-emitted page-prefixed class: forbidden coupling.
                        if ($IsHelperEmission -and -not $cls.StartsWith('cc-')) {
                            foreach ($p in $script:knownPagePrefixes) {
                                if ($cls.StartsWith("$p-")) {
                                    $perClassCodes += 'FORBIDDEN_HELPER_PAGE_PREFIX_CLASS'
                                    break
                                }
                            }
                        }
                        Add-CssClassUsageRow `
                            -ClassName       $cls `
                            -LineStart       $absLine `
                            -ColumnStart     $t.ColumnStart `
                            -Signature       "class=`"$($a.Value)`"" `
                            -ParentFunction  $ParentFunction `
                            -RawText         "class=`"$($a.Value)`"" `
                            -HasDynamicContent ([Nullable[bool]]$a.HasInterp) `
                            -DriftCodes      $perClassCodes | Out-Null
                    }
                }
                continue
            }

            # style="..." (forbidden inline style attribute)
            if ($a.Name -eq 'style') {
                if ($script:htmlFileRowByFile.ContainsKey($script:CurrentFile)) {
                    Add-DriftCode -Row $script:htmlFileRowByFile[$script:CurrentFile] `
                        -Code 'FORBIDDEN_INLINE_STYLE_ATTRIBUTE' `
                        -Context "Inline style attribute on <$($t.TagName)> at line $absLine"
                }
                continue
            }

            # data-action-* -> HTML_DATA_ATTRIBUTE, branching on event vs argument
            $daKind = Get-DataActionAttributeKind -AttrName $a.Name
            if ($null -ne $daKind) {
                $val = if ($a.Value) { $a.Value } else { '' }
                $daCodes = New-Object System.Collections.Generic.List[string]
                $eventName = $null
                $variantType = $val

                if ($daKind -eq 'event' -or $daKind -eq 'unknown-event') {
                    # data-action-<event>: variant_type = value, variant_qualifier_1 = event
                    $eventName = Get-EventFromDataActionName -AttrName $a.Name
                    foreach ($c in @(Get-DataActionEventValidationCodes `
                        -AttrName $a.Name `
                        -Value $val `
                        -PagePrefix $PagePrefix)) {
                        [void]$daCodes.Add($c)
                    }
                    # Helper-emission check: action value must use 'cc-' prefix.
                    if ($IsHelperEmission -and -not [string]::IsNullOrEmpty($val) -and -not $a.HasPureInterp) {
                        if (-not $val.StartsWith('cc-')) {
                            [void]$daCodes.Add('FORBIDDEN_HELPER_PAGE_ACTION')
                        }
                    }
                } else {
                    # data-action-<arg-name>: variant_type = value, no qualifier
                    foreach ($c in @(Get-DataActionArgumentValidationCodes `
                        -AttrName $a.Name `
                        -Value $val `
                        -HasInterp ([bool]$a.HasInterp) `
                        -HasPureInterp ([bool]$a.HasPureInterp))) {
                        [void]$daCodes.Add($c)
                    }
                    # Orphan check: argument attribute requires at least one
                    # event attribute on the same element.
                    if (-not $elementHasEventAttribute) {
                        [void]$daCodes.Add('ORPHANED_ACTION_ARGUMENT')
                    }
                    # Helper-emission check: value must be fully static or
                    # interpolations must reference parameters / foreach
                    # iterators of the enclosing helper function only.
                    if ($IsHelperEmission -and $a.HasInterp -and -not [string]::IsNullOrEmpty($val)) {
                        $roots = @(Get-InterpolationRootVariables -Value $val)
                        $forbidden = $false
                        foreach ($r in $roots) {
                            if ($r.IsScoped) { $forbidden = $true; break }
                            if ($null -eq $r.Root) { $forbidden = $true; break }
                            if (-not $CallerGivenVars.Contains($r.Root)) {
                                $forbidden = $true; break
                            }
                        }
                        if ($forbidden) {
                            [void]$daCodes.Add('FORBIDDEN_HELPER_PAGE_ACTION_ARGUMENT')
                        }
                    }
                }

                # Row scope is determined by the action value's prefix:
                # cc-prefixed values resolve to the shared dispatch table and
                # are SHARED; everything else is LOCAL.
                $rowScope = 'LOCAL'
                if (($daKind -eq 'event' -or $daKind -eq 'unknown-event') -and -not [string]::IsNullOrEmpty($val) -and $val.StartsWith('cc-')) {
                    $rowScope = 'SHARED'
                }

                Add-HtmlDataAttributeRow `
                    -AttrName          $a.Name `
                    -Scope             $rowScope `
                    -LineStart         $absLine `
                    -ColumnStart       $t.ColumnStart `
                    -VariantType       $variantType `
                    -VariantQualifier1 $eventName `
                    -Signature         "$($a.Name)=`"$val`"" `
                    -ParentFunction    $ParentFunction `
                    -RawText           "$($a.Name)=`"$val`"" `
                    -HasDynamicContent ([Nullable[bool]]$a.HasInterp) `
                    -DriftCodes        @($daCodes.ToArray()) | Out-Null
                continue
            }

            # data-* (non-action)
            if ($a.Name -like 'data-*') {
                $daCodes = New-Object System.Collections.Generic.List[string]
                if ($a.Name -notmatch '^data-[a-z][a-z0-9\-]*$') {
                    [void]$daCodes.Add('MALFORMED_DATA_ATTRIBUTE_NAME')
                }
                if ($a.HasInterp -and -not $a.HasPureInterp -and -not [string]::IsNullOrEmpty($a.Value)) {
                    [void]$daCodes.Add('FORBIDDEN_INLINE_DATA_INTERPOLATION')
                }
                if ($IsHelperEmission -and $a.Name -notlike 'data-cc-*' -and $a.Name -notlike 'data-action-*') {
                    [void]$daCodes.Add('FORBIDDEN_HELPER_PAGE_DATA_ATTRIBUTE')
                }
                Add-HtmlDataAttributeRow `
                    -AttrName        $a.Name `
                    -Scope           $DataScope `
                    -LineStart       $absLine `
                    -ColumnStart     $t.ColumnStart `
                    -Signature       "$($a.Name)=`"$($a.Value)`"" `
                    -ParentFunction  $ParentFunction `
                    -RawText         "$($a.Name)=`"$($a.Value)`"" `
                    -HasDynamicContent ([Nullable[bool]]$a.HasInterp) `
                    -DriftCodes      @($daCodes.ToArray()) | Out-Null
                continue
            }

            # on* event handler -> HTML_EVENT_HANDLER
            if ($a.Name -match '^on[a-z]+$') {
                $fnName = Get-HandlerFunctionName -Value $a.Value
                $shapeCodes = @(Get-EventHandlerDriftCodes -Value $a.Value -AttrName $a.Name -PagePrefix $PagePrefix -IsHelperEmission $IsHelperEmission)
                Add-HtmlEventHandlerRow `
                    -AttrName           $a.Name `
                    -LineStart          $absLine `
                    -ColumnStart        $t.ColumnStart `
                    -CalledFunctionName $fnName `
                    -Signature          "$($a.Name)=`"$($a.Value)`"" `
                    -ParentFunction     $ParentFunction `
                    -RawText            "$($a.Name)=`"$($a.Value)`"" `
                    -HasDynamicContent  ([Nullable[bool]]$a.HasInterp) `
                    -DriftCodes         $shapeCodes | Out-Null
                continue
            }

            # User-facing attribute values - emit as 'attr-<attrname>'.
            # The attribute carries text the end user reads (tooltip,
            # placeholder, screen-reader label, image alt) and is
            # categorized by the attribute name regardless of the element
            # it appears on.
            if ($a.Name -in @('title','placeholder','aria-label','alt')) {
                $textCodes = New-Object System.Collections.Generic.List[string]
                if ($null -eq $a.Value -or [string]::IsNullOrWhiteSpace($a.Value)) {
                    [void]$textCodes.Add('EMPTY_DISPLAY_TEXT')
                }
                $componentName = "attr-$($a.Name)"
                Add-HtmlTextRow `
                    -ComponentName   $componentName `
                    -LineStart       $absLine `
                    -ColumnStart     $t.ColumnStart `
                    -Signature       "$($a.Name)=`"$($a.Value)`"" `
                    -ParentFunction  $ParentFunction `
                    -RawText         $a.Value `
                    -HasDynamicContent ([Nullable[bool]]$a.HasInterp) `
                    -DriftCodes      @($textCodes.ToArray()) | Out-Null
                continue
            }
        }
    }

    return $result
}
<# ============================================================================
   FUNCTIONS: OVERLAY POST-WALK VALIDATION
   ----------------------------------------------------------------------------
   Per-construct structure, secondary dialog class, and overlay-block
   contiguity. Construct shape per CC_HTML_Spec Sec. 5.4.
   Prefix: (none)
   ============================================================================ #>

# Test the structural shape of one overlay construct's outer element (Sec.
# 5.4). Returns $true on conformance; the caller attaches MALFORMED_<KIND>_
# STRUCTURE on $false. Secondary dialog-class check lives in Test-OverlayDialogClass.
function Test-OverlayConstructStructure {
    param(
        [Parameter(Mandatory)]$Tokens,
        [Parameter(Mandatory)][int]$OuterTokenIdx
    )

    if ($OuterTokenIdx -lt 0 -or $OuterTokenIdx -ge $Tokens.Count) { return $false }
    $outerTok = $Tokens[$OuterTokenIdx]
    if ($outerTok.Kind -ne 'StartTag') { return $false }

    $outerCloseIdx = Find-MatchingClose -Tokens $Tokens -StartTagIdx $OuterTokenIdx
    if ($outerCloseIdx -le $OuterTokenIdx) { return $false }

    # Collect direct-child StartTag indices of the outer overlay element.
    $dialogChildren = @()
    $cursor = $OuterTokenIdx + 1
    while ($cursor -lt $outerCloseIdx) {
        $tt = $Tokens[$cursor]
        if ($tt.Kind -eq 'Text' -and [string]::IsNullOrWhiteSpace($tt.Raw)) { $cursor++; continue }
        if ($tt.Kind -eq 'Comment') { $cursor++; continue }
        if ($tt.Kind -eq 'EndTag') { $cursor++; continue }
        if ($tt.Kind -eq 'PsInterp') { $cursor++; continue }
        if ($tt.Kind -eq 'Entity') { $cursor++; continue }
        if ($tt.Kind -eq 'StartTag' -or $tt.Kind -eq 'SelfClose') {
            $dialogChildren += $cursor
            if ($tt.Kind -eq 'SelfClose') { $cursor++; continue }
            $childClose = Find-MatchingClose -Tokens $Tokens -StartTagIdx $cursor
            if ($childClose -lt 0 -or $childClose -ge $outerCloseIdx) {
                $cursor = $outerCloseIdx
            } else {
                $cursor = $childClose + 1
            }
            continue
        }
        # Bare text content inside the outer overlay element is invalid.
        if ($tt.Kind -eq 'Text') { return $false }
        $cursor++
    }

    # Exactly one direct child, which must be <div class="cc-dialog">.
    if ($dialogChildren.Count -ne 1) { return $false }
    $dialogIdx = $dialogChildren[0]
    $dialogTok = $Tokens[$dialogIdx]
    if ($dialogTok.TagName -ne 'div') { return $false }
    $dialogAttrs = if (-not [string]::IsNullOrWhiteSpace($dialogTok.AttrText)) {
        Get-AttributesFromToken -AttrText $dialogTok.AttrText
    } else { @() }
    $dialogClass = Get-AttributeByName -Attrs $dialogAttrs -Name 'class'
    if ($null -eq $dialogClass) { return $false }
    $dialogClassTokens = @($dialogClass.Value.Trim() -split '\s+')
    if ($dialogClassTokens -notcontains 'cc-dialog') { return $false }

    # Walk dialog's children and verify the header, body, optional actions
    # sequence.
    $dialogCloseIdx = Find-MatchingClose -Tokens $Tokens -StartTagIdx $dialogIdx
    if ($dialogCloseIdx -le $dialogIdx) { return $false }

    $dialogSubChildren = @()
    $cursor = $dialogIdx + 1
    while ($cursor -lt $dialogCloseIdx) {
        $tt = $Tokens[$cursor]
        if ($tt.Kind -eq 'Text' -and [string]::IsNullOrWhiteSpace($tt.Raw)) { $cursor++; continue }
        if ($tt.Kind -eq 'Comment') { $cursor++; continue }
        if ($tt.Kind -eq 'EndTag') { $cursor++; continue }
        if ($tt.Kind -eq 'PsInterp') { $cursor++; continue }
        if ($tt.Kind -eq 'Entity') { $cursor++; continue }
        if ($tt.Kind -eq 'StartTag' -or $tt.Kind -eq 'SelfClose') {
            $dialogSubChildren += $cursor
            if ($tt.Kind -eq 'SelfClose') { $cursor++; continue }
            $childClose = Find-MatchingClose -Tokens $Tokens -StartTagIdx $cursor
            if ($childClose -lt 0 -or $childClose -ge $dialogCloseIdx) {
                $cursor = $dialogCloseIdx
            } else {
                $cursor = $childClose + 1
            }
            continue
        }
        if ($tt.Kind -eq 'Text') { return $false }
        $cursor++
    }

    # Children: header, optional subheader, body, optional actions (2 to 4).
    if ($dialogSubChildren.Count -lt 2 -or $dialogSubChildren.Count -gt 4) { return $false }

    # Helper to extract first class token of a child element.
    $childClassFirstToken = {
        param([int]$idx)
        $tok = $Tokens[$idx]
        if ($null -eq $tok -or [string]::IsNullOrWhiteSpace($tok.AttrText)) { return $null }
        $aa = Get-AttributesFromToken -AttrText $tok.AttrText
        $cc = Get-AttributeByName -Attrs $aa -Name 'class'
        if ($null -eq $cc -or [string]::IsNullOrEmpty($cc.Value)) { return $null }
        $tokens = @($cc.Value.Trim() -split '\s+')
        if ($tokens.Count -eq 0) { return $null }
        return $tokens[0]
    }

    # Forward-cursor sequence walk: header, optional subheader, body,
    # optional actions, in order. One boolean branch per optional slot.
    $seqPos = 0
    $headerIdx = $dialogSubChildren[$seqPos]
    if ((& $childClassFirstToken $headerIdx) -ne 'cc-dialog-header') { return $false }
    $seqPos++

    # Optional subheader.
    if ($seqPos -lt $dialogSubChildren.Count -and
        (& $childClassFirstToken $dialogSubChildren[$seqPos]) -eq 'cc-dialog-subheader') {
        $seqPos++
    }

    # Body (required).
    if ($seqPos -ge $dialogSubChildren.Count) { return $false }
    $bodyIdx = $dialogSubChildren[$seqPos]
    if ((& $childClassFirstToken $bodyIdx) -ne 'cc-dialog-body') { return $false }
    $seqPos++

    # Optional actions footer.
    if ($seqPos -lt $dialogSubChildren.Count) {
        if ((& $childClassFirstToken $dialogSubChildren[$seqPos]) -ne 'cc-dialog-actions') { return $false }
        $seqPos++
    }

    # No trailing unexpected children.
    if ($seqPos -ne $dialogSubChildren.Count) { return $false }

    # Header must contain exactly one .cc-dialog-title and one .cc-dialog-close.
    $headerCloseIdx = Find-MatchingClose -Tokens $Tokens -StartTagIdx $headerIdx
    if ($headerCloseIdx -le $headerIdx) { return $false }
    $headerChildren = @()
    $cursor = $headerIdx + 1
    while ($cursor -lt $headerCloseIdx) {
        $tt = $Tokens[$cursor]
        if ($tt.Kind -eq 'Text' -and [string]::IsNullOrWhiteSpace($tt.Raw)) { $cursor++; continue }
        if ($tt.Kind -eq 'Comment') { $cursor++; continue }
        if ($tt.Kind -eq 'EndTag') { $cursor++; continue }
        if ($tt.Kind -eq 'PsInterp') { $cursor++; continue }
        if ($tt.Kind -eq 'Entity') { $cursor++; continue }
        if ($tt.Kind -eq 'StartTag' -or $tt.Kind -eq 'SelfClose') {
            $headerChildren += $cursor
            if ($tt.Kind -eq 'SelfClose') { $cursor++; continue }
            $childClose = Find-MatchingClose -Tokens $Tokens -StartTagIdx $cursor
            if ($childClose -lt 0 -or $childClose -ge $headerCloseIdx) {
                $cursor = $headerCloseIdx
            } else {
                $cursor = $childClose + 1
            }
            continue
        }
        $cursor++
    }
    # Header: title first, close last, with an optional single
    # cc-dialog-header-actions cluster between them (2 or 3 children).
    if ($headerChildren.Count -lt 2 -or $headerChildren.Count -gt 3) { return $false }
    $titleClass = & $childClassFirstToken $headerChildren[0]
    $closeClass = & $childClassFirstToken $headerChildren[$headerChildren.Count - 1]
    if ($titleClass -ne 'cc-dialog-title') { return $false }
    if ($closeClass -ne 'cc-dialog-close') { return $false }
    if ($headerChildren.Count -eq 3) {
        $midClass = & $childClassFirstToken $headerChildren[1]
        if ($midClass -ne 'cc-dialog-header-actions') { return $false }
    }

    return $true
}

# Validate a dock construct's structure (CC_HTML_Spec Sec. 5.4.5/5.4.6): a
# single element carrying cc-dialog and cc-dialog-dock, children being
# .cc-dialog-header, optional .cc-dialog-subheader, then .cc-dialog-body (no
# actions footer); header is one .cc-dialog-back then one .cc-dialog-title with
# an optional .cc-dialog-header-actions last. Drift: MALFORMED_DOCK_STRUCTURE.
function Test-DockConstructStructure {
    param(
        [Parameter(Mandatory)]$Tokens,
        [Parameter(Mandatory)][int]$DockTokenIdx
    )

    if ($DockTokenIdx -lt 0 -or $DockTokenIdx -ge $Tokens.Count) { return $false }
    $dockTok = $Tokens[$DockTokenIdx]
    if ($dockTok.Kind -ne 'StartTag') { return $false }
    if ($dockTok.TagName -ne 'div') { return $false }

    # The dock element must carry both cc-dialog and cc-dialog-dock.
    $dockAttrs = if (-not [string]::IsNullOrWhiteSpace($dockTok.AttrText)) {
        Get-AttributesFromToken -AttrText $dockTok.AttrText
    } else { @() }
    $dockClass = Get-AttributeByName -Attrs $dockAttrs -Name 'class'
    if ($null -eq $dockClass) { return $false }
    $dockClassTokens = @($dockClass.Value.Trim() -split '\s+')
    if ($dockClassTokens -notcontains 'cc-dialog')      { return $false }
    if ($dockClassTokens -notcontains 'cc-dialog-dock') { return $false }

    $dockCloseIdx = Find-MatchingClose -Tokens $Tokens -StartTagIdx $DockTokenIdx
    if ($dockCloseIdx -le $DockTokenIdx) { return $false }

    # Collect direct-child StartTag indices of the dock element.
    $children = @()
    $cursor = $DockTokenIdx + 1
    while ($cursor -lt $dockCloseIdx) {
        $tt = $Tokens[$cursor]
        if ($tt.Kind -eq 'Text' -and [string]::IsNullOrWhiteSpace($tt.Raw)) { $cursor++; continue }
        if ($tt.Kind -eq 'Comment') { $cursor++; continue }
        if ($tt.Kind -eq 'EndTag') { $cursor++; continue }
        if ($tt.Kind -eq 'PsInterp') { $cursor++; continue }
        if ($tt.Kind -eq 'Entity') { $cursor++; continue }
        if ($tt.Kind -eq 'StartTag' -or $tt.Kind -eq 'SelfClose') {
            $children += $cursor
            if ($tt.Kind -eq 'SelfClose') { $cursor++; continue }
            $childClose = Find-MatchingClose -Tokens $Tokens -StartTagIdx $cursor
            if ($childClose -lt 0 -or $childClose -ge $dockCloseIdx) {
                $cursor = $dockCloseIdx
            } else {
                $cursor = $childClose + 1
            }
            continue
        }
        if ($tt.Kind -eq 'Text') { return $false }
        $cursor++
    }

    # Helper to extract first class token of a child element.
    $childClassFirstToken = {
        param([int]$idx)
        $tok = $Tokens[$idx]
        if ($null -eq $tok -or [string]::IsNullOrWhiteSpace($tok.AttrText)) { return $null }
        $aa = Get-AttributesFromToken -AttrText $tok.AttrText
        $cc = Get-AttributeByName -Attrs $aa -Name 'class'
        if ($null -eq $cc -or [string]::IsNullOrEmpty($cc.Value)) { return $null }
        $tokens = @($cc.Value.Trim() -split '\s+')
        if ($tokens.Count -eq 0) { return $null }
        return $tokens[0]
    }

    # Children: header, optional subheader, body. No actions footer (2 or 3).
    if ($children.Count -lt 2 -or $children.Count -gt 3) { return $false }
    $headerClass = & $childClassFirstToken $children[0]
    $bodyClass   = & $childClassFirstToken $children[$children.Count - 1]
    if ($headerClass -ne 'cc-dialog-header') { return $false }
    if ($bodyClass   -ne 'cc-dialog-body')   { return $false }
    if ($children.Count -eq 3) {
        $subClass = & $childClassFirstToken $children[1]
        if ($subClass -ne 'cc-dialog-subheader') { return $false }
    }

    # Header must contain exactly one .cc-dialog-back then one .cc-dialog-title.
    $headerIdx = $children[0]
    $headerCloseIdx = Find-MatchingClose -Tokens $Tokens -StartTagIdx $headerIdx
    if ($headerCloseIdx -le $headerIdx) { return $false }
    $headerChildren = @()
    $cursor = $headerIdx + 1
    while ($cursor -lt $headerCloseIdx) {
        $tt = $Tokens[$cursor]
        if ($tt.Kind -eq 'Text' -and [string]::IsNullOrWhiteSpace($tt.Raw)) { $cursor++; continue }
        if ($tt.Kind -eq 'Comment') { $cursor++; continue }
        if ($tt.Kind -eq 'EndTag') { $cursor++; continue }
        if ($tt.Kind -eq 'PsInterp') { $cursor++; continue }
        if ($tt.Kind -eq 'Entity') { $cursor++; continue }
        if ($tt.Kind -eq 'StartTag' -or $tt.Kind -eq 'SelfClose') {
            $headerChildren += $cursor
            if ($tt.Kind -eq 'SelfClose') { $cursor++; continue }
            $childClose = Find-MatchingClose -Tokens $Tokens -StartTagIdx $cursor
            if ($childClose -lt 0 -or $childClose -ge $headerCloseIdx) {
                $cursor = $headerCloseIdx
            } else {
                $cursor = $childClose + 1
            }
            continue
        }
        $cursor++
    }
    # Header: back first, title second, with an optional single
    # cc-dialog-header-actions cluster last (2 or 3 children).
    if ($headerChildren.Count -lt 2 -or $headerChildren.Count -gt 3) { return $false }
    $backClass  = & $childClassFirstToken $headerChildren[0]
    $titleClass = & $childClassFirstToken $headerChildren[1]
    if ($backClass  -ne 'cc-dialog-back')  { return $false }
    if ($titleClass -ne 'cc-dialog-title') { return $false }
    if ($headerChildren.Count -eq 3) {
        $actionsClass = & $childClassFirstToken $headerChildren[2]
        if ($actionsClass -ne 'cc-dialog-header-actions') { return $false }
    }

    return $true
}

# Test whether the inner .cc-dialog carries the secondary class matching its
# overlay kind (modal -> cc-dialog-modal, slideout -> cc-dialog-slide, slideup
# -> cc-dialog-slideup). Returns $true on match, on unrecognized kind, or when
# the inner .cc-dialog can't be located (that structural fault is the caller's
# concern via Test-OverlayConstructStructure).
function Test-OverlayDialogClass {
    param(
        [Parameter(Mandatory)]$Tokens,
        [Parameter(Mandatory)][int]$OuterTokenIdx,
        [Parameter(Mandatory)][string]$OverlayKind
    )

    # Expected secondary class on .cc-dialog for each overlay kind.
    $expected = switch ($OverlayKind) {
        'modal'    { 'cc-dialog-modal' }
        'slideout' { 'cc-dialog-slide' }
        'slideup'  { 'cc-dialog-slideup' }
        default    { $null }
    }
    if ($null -eq $expected) { return $true }

    if ($OuterTokenIdx -lt 0 -or $OuterTokenIdx -ge $Tokens.Count) { return $true }
    $outerCloseIdx = Find-MatchingClose -Tokens $Tokens -StartTagIdx $OuterTokenIdx
    if ($outerCloseIdx -le $OuterTokenIdx) { return $true }

    # Walk direct children of the outer overlay element looking for the
    # single .cc-dialog child. Mirrors the discovery walk inside
    # Test-OverlayConstructStructure.
    $dialogIdx = -1
    $cursor = $OuterTokenIdx + 1
    while ($cursor -lt $outerCloseIdx) {
        $tt = $Tokens[$cursor]
        if ($tt.Kind -eq 'Text' -and [string]::IsNullOrWhiteSpace($tt.Raw)) { $cursor++; continue }
        if ($tt.Kind -eq 'Comment')  { $cursor++; continue }
        if ($tt.Kind -eq 'EndTag')   { $cursor++; continue }
        if ($tt.Kind -eq 'PsInterp') { $cursor++; continue }
        if ($tt.Kind -eq 'Entity')   { $cursor++; continue }
        if ($tt.Kind -eq 'StartTag' -or $tt.Kind -eq 'SelfClose') {
            $dialogIdx = $cursor
            break
        }
        $cursor++
    }
    if ($dialogIdx -lt 0) { return $true }

    $dialogTok = $Tokens[$dialogIdx]
    if ([string]::IsNullOrWhiteSpace($dialogTok.AttrText)) { return $false }
    $dialogAttrs = Get-AttributesFromToken -AttrText $dialogTok.AttrText
    $dialogClass = Get-AttributeByName -Attrs $dialogAttrs -Name 'class'
    if ($null -eq $dialogClass) { return $false }
    $dialogClassTokens = @($dialogClass.Value.Trim() -split '\s+')

    return ($dialogClassTokens -contains $expected)
}

# Test whether the outer overlay element's data-action-click matches its
# .cc-dialog-close button's, per CC_HTML_Spec Sec. 5.4.4 (backdrop click
# dismisses via the same action as the X). Footer controls (Cancel/Confirm) are
# deliberately excluded -- they carry their own actions, not the close action.
# Returns $true on match or when the elements can't be located (structural fault
# is the caller's concern).
function Test-OverlayBackdropClose {
    param(
        [Parameter(Mandatory)]$Tokens,
        [Parameter(Mandatory)][int]$OuterTokenIdx
    )

    if ($OuterTokenIdx -lt 0 -or $OuterTokenIdx -ge $Tokens.Count) { return $true }
    $outerTok = $Tokens[$OuterTokenIdx]

    # Outer element's data-action-click.
    $outerAction = $null
    if (-not [string]::IsNullOrWhiteSpace($outerTok.AttrText)) {
        $outerAttrs = Get-AttributesFromToken -AttrText $outerTok.AttrText
        $outerActionAttr = Get-AttributeByName -Attrs $outerAttrs -Name 'data-action-click'
        if ($null -ne $outerActionAttr) { $outerAction = $outerActionAttr.Value }
    }

    $outerCloseIdx = Find-MatchingClose -Tokens $Tokens -StartTagIdx $OuterTokenIdx
    if ($outerCloseIdx -le $OuterTokenIdx) { return $true }

    # Locate the single .cc-dialog direct child.
    $dialogIdx = -1
    $cursor = $OuterTokenIdx + 1
    while ($cursor -lt $outerCloseIdx) {
        $tt = $Tokens[$cursor]
        if ($tt.Kind -eq 'Text' -and [string]::IsNullOrWhiteSpace($tt.Raw)) { $cursor++; continue }
        if ($tt.Kind -eq 'Comment')  { $cursor++; continue }
        if ($tt.Kind -eq 'EndTag')   { $cursor++; continue }
        if ($tt.Kind -eq 'PsInterp') { $cursor++; continue }
        if ($tt.Kind -eq 'Entity')   { $cursor++; continue }
        if ($tt.Kind -eq 'StartTag' -or $tt.Kind -eq 'SelfClose') {
            $dialogIdx = $cursor
            break
        }
        $cursor++
    }
    if ($dialogIdx -lt 0) { return $true }

    $dialogCloseIdx = Find-MatchingClose -Tokens $Tokens -StartTagIdx $dialogIdx
    if ($dialogCloseIdx -le $dialogIdx) { return $true }

    # Locate the .cc-dialog-header direct child of .cc-dialog.
    $headerIdx = -1
    $cursor = $dialogIdx + 1
    while ($cursor -lt $dialogCloseIdx) {
        $tt = $Tokens[$cursor]
        if ($tt.Kind -eq 'Text' -and [string]::IsNullOrWhiteSpace($tt.Raw)) { $cursor++; continue }
        if ($tt.Kind -eq 'Comment')  { $cursor++; continue }
        if ($tt.Kind -eq 'EndTag')   { $cursor++; continue }
        if ($tt.Kind -eq 'PsInterp') { $cursor++; continue }
        if ($tt.Kind -eq 'Entity')   { $cursor++; continue }
        if ($tt.Kind -eq 'StartTag' -or $tt.Kind -eq 'SelfClose') {
            $hdrTok = $Tokens[$cursor]
            $hdrFirstClass = $null
            if (-not [string]::IsNullOrWhiteSpace($hdrTok.AttrText)) {
                $hdrAttrs = Get-AttributesFromToken -AttrText $hdrTok.AttrText
                $hdrClass = Get-AttributeByName -Attrs $hdrAttrs -Name 'class'
                if ($null -ne $hdrClass -and -not [string]::IsNullOrEmpty($hdrClass.Value)) {
                    $hdrTokens = @($hdrClass.Value.Trim() -split '\s+')
                    if ($hdrTokens.Count -gt 0) { $hdrFirstClass = $hdrTokens[0] }
                }
            }
            if ($hdrFirstClass -eq 'cc-dialog-header') {
                $headerIdx = $cursor
                break
            }
            if ($tt.Kind -eq 'SelfClose') { $cursor++; continue }
            $childClose = Find-MatchingClose -Tokens $Tokens -StartTagIdx $cursor
            if ($childClose -lt 0 -or $childClose -ge $dialogCloseIdx) {
                $cursor = $dialogCloseIdx
            } else {
                $cursor = $childClose + 1
            }
            continue
        }
        $cursor++
    }
    if ($headerIdx -lt 0) { return $true }

    $headerCloseIdx = Find-MatchingClose -Tokens $Tokens -StartTagIdx $headerIdx
    if ($headerCloseIdx -le $headerIdx) { return $true }

    # Locate the .cc-dialog-close button within the header and read its
    # data-action-click.
    $closeAction = $null
    $closeFound = $false
    $cursor = $headerIdx + 1
    while ($cursor -lt $headerCloseIdx) {
        $tt = $Tokens[$cursor]
        if ($tt.Kind -eq 'StartTag' -or $tt.Kind -eq 'SelfClose') {
            $btnTok = $Tokens[$cursor]
            $btnFirstClass = $null
            $btnAttrs = $null
            if (-not [string]::IsNullOrWhiteSpace($btnTok.AttrText)) {
                $btnAttrs = Get-AttributesFromToken -AttrText $btnTok.AttrText
                $btnClass = Get-AttributeByName -Attrs $btnAttrs -Name 'class'
                if ($null -ne $btnClass -and -not [string]::IsNullOrEmpty($btnClass.Value)) {
                    $btnTokens = @($btnClass.Value.Trim() -split '\s+')
                    if ($btnTokens.Count -gt 0) { $btnFirstClass = $btnTokens[0] }
                }
            }
            if ($btnFirstClass -eq 'cc-dialog-close') {
                $closeFound = $true
                if ($null -ne $btnAttrs) {
                    $closeActionAttr = Get-AttributeByName -Attrs $btnAttrs -Name 'data-action-click'
                    if ($null -ne $closeActionAttr) { $closeAction = $closeActionAttr.Value }
                }
                break
            }
            if ($tt.Kind -eq 'SelfClose') { $cursor++; continue }
            $childClose = Find-MatchingClose -Tokens $Tokens -StartTagIdx $cursor
            if ($childClose -lt 0 -or $childClose -ge $headerCloseIdx) {
                $cursor = $headerCloseIdx
            } else {
                $cursor = $childClose + 1
            }
            continue
        }
        $cursor++
    }
    if (-not $closeFound) { return $true }

    # The rule: outer carries data-action-click and it equals the close
    # button's data-action-click. Missing outer action, or a mismatch, is
    # drift. The close button's own action is validated for resolution
    # elsewhere; here only the equality of the two values matters.
    if ([string]::IsNullOrWhiteSpace($outerAction)) { return $false }
    return ($outerAction -eq $closeAction)
}
# Validate the overlay block after the token walk completes.
function Invoke-OverlayPostWalkValidation {
    param(
        [Parameter(Mandatory)]$Tokens,
        [Parameter(Mandatory)]$OverlayConstructs,
        [Parameter(Mandatory)][int]$FileLine0
    )

    if ($null -eq $OverlayConstructs -or $OverlayConstructs.Count -eq 0) { return }

    # Per-construct structural validation
    foreach ($c in $OverlayConstructs) {
        # Docks (CC_HTML_Spec Sec. 5.4.5) have their own structure and no
        # outer overlay, secondary dialog class, or backdrop-close. Validate
        # them separately and skip the backdrop-overlay checks below.
        if ($c.OverlayKind -eq 'dock') {
            $dockOk = Test-DockConstructStructure -Tokens $Tokens -DockTokenIdx $c.OuterTokenIdx
            if (-not $dockOk) {
                $attached = $false
                if (-not [string]::IsNullOrEmpty($c.IdValue)) {
                    foreach ($r in $script:rows) {
                        if ($r.FileName -eq $script:CurrentFile -and
                            $r.ComponentType -eq 'HTML_ID' -and
                            $r.ComponentName -eq $c.IdValue -and
                            $r.LineStart -eq $c.AbsLine) {
                            Add-DriftCode -Row $r -Code 'MALFORMED_DOCK_STRUCTURE' `
                                -Context "Dock construct '$($c.IdValue)' does not conform to required cc-dialog-dock structure."
                            $attached = $true
                            break
                        }
                    }
                }
                if (-not $attached -and $script:htmlFileRowByFile.ContainsKey($script:CurrentFile)) {
                    Add-DriftCode -Row $script:htmlFileRowByFile[$script:CurrentFile] `
                        -Code 'MALFORMED_DOCK_STRUCTURE' `
                        -Context "Dock element at line $($c.AbsLine) does not conform to required cc-dialog-dock structure."
                }
            }
            continue
        }

        $ok = Test-OverlayConstructStructure -Tokens $Tokens -OuterTokenIdx $c.OuterTokenIdx
        if (-not $ok) {
            $structCode = switch ($c.OverlayKind) {
                'modal'    { 'MALFORMED_MODAL_STRUCTURE' }
                'slideout' { 'MALFORMED_SLIDEOUT_STRUCTURE' }
                'slideup'  { 'MALFORMED_SLIDEUP_STRUCTURE' }
                default    { $null }
            }
            if ($null -ne $structCode) {
                # Attach to the construct's HTML_ID row (when there is one)
                # or to the file's HTML_FILE row as a fallback.
                $attached = $false
                if (-not [string]::IsNullOrEmpty($c.IdValue)) {
                    foreach ($r in $script:rows) {
                        if ($r.FileName -eq $script:CurrentFile -and
                            $r.ComponentType -eq 'HTML_ID' -and
                            $r.ComponentName -eq $c.IdValue -and
                            $r.LineStart -eq $c.AbsLine) {
                            Add-DriftCode -Row $r -Code $structCode `
                                -Context "Overlay construct '$($c.IdValue)' does not conform to required nested .cc-dialog structure."
                            $attached = $true
                            break
                        }
                    }
                }
                if (-not $attached -and $script:htmlFileRowByFile.ContainsKey($script:CurrentFile)) {
                    Add-DriftCode -Row $script:htmlFileRowByFile[$script:CurrentFile] `
                        -Code $structCode `
                        -Context "Overlay outer element at line $($c.AbsLine) does not conform to required nested .cc-dialog structure."
                }
            }
        }
        else {
            # Structural check passed. Validate that the inner .cc-dialog
            # carries the secondary class matching its overlay kind.
            $dialogClassOk = Test-OverlayDialogClass `
                -Tokens $Tokens `
                -OuterTokenIdx $c.OuterTokenIdx `
                -OverlayKind $c.OverlayKind
            if (-not $dialogClassOk) {
                $expectedClass = switch ($c.OverlayKind) {
                    'modal'    { 'cc-dialog-modal' }
                    'slideout' { 'cc-dialog-slide' }
                    'slideup'  { 'cc-dialog-slideup' }
                    default    { $null }
                }
                if ($null -ne $expectedClass) {
                    $attached = $false
                    if (-not [string]::IsNullOrEmpty($c.IdValue)) {
                        foreach ($r in $script:rows) {
                            if ($r.FileName -eq $script:CurrentFile -and
                                $r.ComponentType -eq 'HTML_ID' -and
                                $r.ComponentName -eq $c.IdValue -and
                                $r.LineStart -eq $c.AbsLine) {
                                Add-DriftCode -Row $r -Code 'MISSING_DIALOG_CLASS' `
                                    -Context "Overlay construct '$($c.IdValue)' is missing the expected secondary class '$expectedClass' on its inner .cc-dialog."
                                $attached = $true
                                break
                            }
                        }
                    }
                    if (-not $attached -and $script:htmlFileRowByFile.ContainsKey($script:CurrentFile)) {
                        Add-DriftCode -Row $script:htmlFileRowByFile[$script:CurrentFile] `
                            -Code 'MISSING_DIALOG_CLASS' `
                            -Context "Overlay outer element at line $($c.AbsLine) is missing the expected secondary class '$expectedClass' on its inner .cc-dialog."
                    }
                }
            }

            # Backdrop-close check (CC_HTML_Spec Sec. 5.4.4): the outer overlay
            # element must carry a data-action-click matching its
            # .cc-dialog-close button's close action.
            $backdropOk = Test-OverlayBackdropClose `
                -Tokens $Tokens `
                -OuterTokenIdx $c.OuterTokenIdx
            if (-not $backdropOk) {
                $attached = $false
                if (-not [string]::IsNullOrEmpty($c.IdValue)) {
                    foreach ($r in $script:rows) {
                        if ($r.FileName -eq $script:CurrentFile -and
                            $r.ComponentType -eq 'HTML_ID' -and
                            $r.ComponentName -eq $c.IdValue -and
                            $r.LineStart -eq $c.AbsLine) {
                            Add-DriftCode -Row $r -Code 'MISSING_OVERLAY_BACKDROP_CLOSE' `
                                -Context "Overlay construct '$($c.IdValue)' outer element does not carry a data-action-click matching its .cc-dialog-close button; a backdrop click will not dismiss it."
                            $attached = $true
                            break
                        }
                    }
                }
                if (-not $attached -and $script:htmlFileRowByFile.ContainsKey($script:CurrentFile)) {
                    Add-DriftCode -Row $script:htmlFileRowByFile[$script:CurrentFile] `
                        -Code 'MISSING_OVERLAY_BACKDROP_CLOSE' `
                        -Context "Overlay outer element at line $($c.AbsLine) does not carry a data-action-click matching its .cc-dialog-close button; a backdrop click will not dismiss it."
                }
            }
        }
    }

    # Overlay block contiguity
    # Sort overlay constructs by token index. Build their full token-index
    # ranges (outer StartTag through matching EndTag). Between successive
    # ranges, only formatting whitespace and at most one purpose-shaped
    # comment (the next construct's purpose comment) are permitted.
    $sorted = @($OverlayConstructs | Sort-Object { $_.OuterTokenIdx })
    if ($sorted.Count -lt 2) { return }

    $ranges = @()
    foreach ($c in $sorted) {
        $startIdx = $c.OuterTokenIdx
        $endIdx = Find-MatchingClose -Tokens $Tokens -StartTagIdx $startIdx
        if ($endIdx -lt 0) { $endIdx = $startIdx }
        $ranges += @{ Start = $startIdx; End = $endIdx; Construct = $c }
    }

    for ($r = 0; $r -lt ($ranges.Count - 1); $r++) {
        $gapStart = $ranges[$r].End + 1
        $gapEnd   = $ranges[$r + 1].Start - 1
        if ($gapStart -gt $gapEnd) { continue }

        $hasBreaker = $false
        $purposeCommentCount = 0
        for ($k = $gapStart; $k -le $gapEnd; $k++) {
            $tt = $Tokens[$k]
            if ($tt.Kind -eq 'Text' -and [string]::IsNullOrWhiteSpace($tt.Raw)) { continue }
            if ($tt.Kind -eq 'EndTag') { continue }
            if ($tt.Kind -eq 'Comment') {
                # A single purpose-shaped comment (one that introduces the
                # next construct) is permitted. Anything else breaks
                # contiguity.
                $purposeCommentCount++
                if ($purposeCommentCount -gt 1) {
                    $hasBreaker = $true
                    break
                }
                continue
            }
            # Any StartTag, SelfClose, Text content, Entity, PsInterp, or
            # additional comments break contiguity.
            $hasBreaker = $true
            break
        }

        if ($hasBreaker) {
            foreach ($cToFlag in @($ranges[$r].Construct, $ranges[$r + 1].Construct)) {
                $attached = $false
                if (-not [string]::IsNullOrEmpty($cToFlag.IdValue)) {
                    foreach ($row in $script:rows) {
                        if ($row.FileName -eq $script:CurrentFile -and
                            $row.ComponentType -eq 'HTML_ID' -and
                            $row.ComponentName -eq $cToFlag.IdValue -and
                            $row.LineStart -eq $cToFlag.AbsLine) {
                            Add-DriftCode -Row $row -Code 'OVERLAY_BLOCK_NON_CONTIGUOUS'
                            $attached = $true
                            break
                        }
                    }
                }
                if (-not $attached -and $script:htmlFileRowByFile.ContainsKey($script:CurrentFile)) {
                    Add-DriftCode -Row $script:htmlFileRowByFile[$script:CurrentFile] `
                        -Code 'OVERLAY_BLOCK_NON_CONTIGUOUS' `
                        -Context "Overlay block at line $($cToFlag.AbsLine) is interrupted by non-overlay content."
                }
            }
        }
    }
}

<# ============================================================================
   FUNCTIONS: DUPLICATE ID CHECK
   ----------------------------------------------------------------------------
   Flag id values declared more than once within a single page.
   Prefix: (none)
   ============================================================================ #>
#
# After all rows are emitted for a file, scan its HTML_ID rows and attach
# DUPLICATE_ID_DECLARATION to every duplicate occurrence beyond the first.
function Invoke-DuplicateIdCheck {
    param([Parameter(Mandatory)][string]$FileName)

    $seenIds = @{}
    foreach ($r in $script:rows) {
        if ($r.FileName -ne $FileName) { continue }
        if ($r.ComponentType -ne 'HTML_ID') { continue }
        if ($r.ReferenceType -ne 'DEFINITION') { continue }

        $id = $r.ComponentName
        if (-not $seenIds.ContainsKey($id)) {
            $seenIds[$id] = 1
        } else {
            $seenIds[$id]++
            Add-DriftCode -Row $r -Code 'DUPLICATE_ID_DECLARATION'
        }
    }
}
<# ============================================================================
   FUNCTIONS: ENGINE CARD VALIDATION
   ----------------------------------------------------------------------------
   Validate engine cards against Orchestrator.ProcessRegistry: slug match,
   ordering, and required registration columns.
   Prefix: (none)
   ============================================================================ #>
#
# Validate the page chrome's engine-card block (one cc-card-engine card per
# active scheduled process) against Orchestrator.ProcessRegistry (slug, label,
# route, sort order, run mode). Per-card structural faults consolidate into
# MALFORMED_ENGINE_CARD.
function Invoke-EngineCardValidation {
    param(
        [Parameter(Mandatory)]$Tokens,
        [Parameter(Mandatory)][int]$FileLine0,
        [string[]]$RoutePaths
    )

    if ($null -eq $Tokens) { return }
    if ($null -eq $script:processRegistryRows -or $script:processRegistryRows.Count -eq 0) { return }
    if ($null -eq $RoutePaths -or $RoutePaths.Count -eq 0) { return }

    # Find all engine cards in this file by scanning for cc-card-engine-* IDs.
    $cardsOnPage = @()
    for ($i = 0; $i -lt $Tokens.Count; $i++) {
        $t = $Tokens[$i]
        if ($t.Kind -ne 'StartTag' -and $t.Kind -ne 'SelfClose') { continue }
        if ([string]::IsNullOrWhiteSpace($t.AttrText)) { continue }
        $attrs = Get-AttributesFromToken -AttrText $t.AttrText
        $idAttr = Get-AttributeByName -Attrs $attrs -Name 'id'
        if (-not $idAttr -or [string]::IsNullOrEmpty($idAttr.Value)) { continue }
        if ($idAttr.Value -match '^cc-card-engine-(.+)$') {
            $cardsOnPage += [ordered]@{
                Slug       = $matches[1]
                TokenIdx   = $i
                AbsLine    = $FileLine0 + $t.LineOffset
                IdRowKey   = $idAttr.Value
                TagName    = $t.TagName
                Attributes = $attrs
            }
        }
    }

    if ($cardsOnPage.Count -eq 0) { return }

    foreach ($card in $cardsOnPage) {
        # Find the HTML_ID row for the card so drift can attach to it.
        $cardRow = $null
        foreach ($r in $script:rows) {
            if ($r.FileName -eq $script:CurrentFile -and
                $r.ComponentType -eq 'HTML_ID' -and
                $r.ComponentName -eq $card.IdRowKey -and
                $r.LineStart -eq $card.AbsLine) {
                $cardRow = $r
                break
            }
        }
        if ($null -eq $cardRow) { continue }

        # Card outer-element validation
        # Outer element is a <div> carrying exactly class="cc-card-engine"
        # and id="cc-card-engine-<slug>". Any deviation fires
        # MALFORMED_ENGINE_CARD.
        if ($card.TagName -ne 'div') {
            Add-DriftCode -Row $cardRow -Code 'MALFORMED_ENGINE_CARD' `
                -Context "Card outer element is <$($card.TagName)>; expected <div>."
        }
        $classAttr = Get-AttributeByName -Attrs $card.Attributes -Name 'class'
        if ($null -eq $classAttr -or $classAttr.Value -ne 'cc-card-engine') {
            $actual = if ($null -eq $classAttr) { '<missing>' } else { $classAttr.Value }
            Add-DriftCode -Row $cardRow -Code 'MALFORMED_ENGINE_CARD' `
                -Context "Card class is '$actual'; expected exactly 'cc-card-engine'."
        }
        foreach ($a in $card.Attributes) {
            if ($a.Name -ne 'class' -and $a.Name -ne 'id') {
                Add-DriftCode -Row $cardRow -Code 'MALFORMED_ENGINE_CARD' `
                    -Context "Card carries unexpected attribute '$($a.Name)'."
            }
        }

        # Card body structural validation
        # Three child elements:
        #   1. <span class="cc-engine-label">label text</span>
        #   2. <div  class="cc-engine-bar" id="cc-engine-bar-<slug>"></div>
        #   3. <span class="cc-engine-cd"  id="cc-engine-cd-<slug>"></span>
        $cardEndIdx = Find-MatchingClose -Tokens $Tokens -StartTagIdx $card.TokenIdx
        if ($cardEndIdx -le $card.TokenIdx) {
            Add-DriftCode -Row $cardRow -Code 'MALFORMED_ENGINE_CARD' `
                -Context "Card outer <div> has no matching closing tag."
            continue
        }

        # Collect immediate child StartTag/SelfClose tokens.
        $childIdxs = @()
        $cursor = $card.TokenIdx + 1
        while ($cursor -lt $cardEndIdx) {
            $tt = $Tokens[$cursor]
            if ($tt.Kind -eq 'Text' -and [string]::IsNullOrWhiteSpace($tt.Raw)) { $cursor++; continue }
            if ($tt.Kind -eq 'Comment') { $cursor++; continue }
            if ($tt.Kind -eq 'PsInterp') { $cursor++; continue }
            if ($tt.Kind -eq 'Entity') { $cursor++; continue }
            if ($tt.Kind -eq 'EndTag') { $cursor++; continue }
            if ($tt.Kind -eq 'StartTag' -or $tt.Kind -eq 'SelfClose') {
                $childIdxs += $cursor
                if ($tt.Kind -eq 'SelfClose') { $cursor++; continue }
                $childClose = Find-MatchingClose -Tokens $Tokens -StartTagIdx $cursor
                if ($childClose -lt 0 -or $childClose -ge $cardEndIdx) {
                    $cursor = $cardEndIdx
                } else {
                    $cursor = $childClose + 1
                }
                continue
            }
            if ($tt.Kind -eq 'Text') {
                Add-DriftCode -Row $cardRow -Code 'MALFORMED_ENGINE_CARD' `
                    -Context "Card body contains bare text outside the mandated child elements."
            }
            $cursor++
        }

        if ($childIdxs.Count -ne 3) {
            Add-DriftCode -Row $cardRow -Code 'MALFORMED_ENGINE_CARD' `
                -Context "Card body has $($childIdxs.Count) immediate child element(s); expected exactly 3 (cc-engine-label span, cc-engine-bar div, cc-engine-cd span)."
            continue
        }

        # Child 1: <span class="cc-engine-label">label text</span>
        $labelTok = $Tokens[$childIdxs[0]]
        $labelAttrs = if (-not [string]::IsNullOrWhiteSpace($labelTok.AttrText)) {
            Get-AttributesFromToken -AttrText $labelTok.AttrText
        } else { @() }
        $labelClass = Get-AttributeByName -Attrs $labelAttrs -Name 'class'
        if ($labelTok.TagName -ne 'span') {
            Add-DriftCode -Row $cardRow -Code 'MALFORMED_ENGINE_CARD' `
                -Context "First child is <$($labelTok.TagName)>; expected <span>."
        } elseif ($null -eq $labelClass -or $labelClass.Value -ne 'cc-engine-label') {
            $actual = if ($null -eq $labelClass) { '<missing>' } else { $labelClass.Value }
            Add-DriftCode -Row $cardRow -Code 'MALFORMED_ENGINE_CARD' `
                -Context "First child span class is '$actual'; expected exactly 'cc-engine-label'."
        } else {
            foreach ($a in $labelAttrs) {
                if ($a.Name -ne 'class') {
                    Add-DriftCode -Row $cardRow -Code 'MALFORMED_ENGINE_CARD' `
                        -Context "cc-engine-label span carries unexpected attribute '$($a.Name)'."
                }
            }
            $labelClose = Find-MatchingClose -Tokens $Tokens -StartTagIdx $childIdxs[0]
            if ($labelClose -gt $childIdxs[0]) {
                $sbText = New-Object System.Text.StringBuilder
                $labelHasInterp = $false
                for ($m = $childIdxs[0] + 1; $m -lt $labelClose; $m++) {
                    $bt = $Tokens[$m]
                    if ($bt.Kind -eq 'Text') { [void]$sbText.Append($bt.Raw) }
                    elseif ($bt.Kind -eq 'PsInterp') { $labelHasInterp = $true }
                }
                $labelText = $sbText.ToString().Trim()
                if ($labelHasInterp) {
                    Add-DriftCode -Row $cardRow -Code 'MALFORMED_ENGINE_CARD' `
                        -Context "cc-engine-label span content contains PowerShell interpolation; spec requires static text."
                } elseif ([string]::IsNullOrEmpty($labelText)) {
                    Add-DriftCode -Row $cardRow -Code 'MALFORMED_ENGINE_CARD' `
                        -Context "cc-engine-label span is empty; spec requires label text."
                }
            }
        }

        # Child 2: <div class="cc-engine-bar" id="cc-engine-bar-<slug>"></div>
        $barTok = $Tokens[$childIdxs[1]]
        $barAttrs = if (-not [string]::IsNullOrWhiteSpace($barTok.AttrText)) {
            Get-AttributesFromToken -AttrText $barTok.AttrText
        } else { @() }
        $barClass = Get-AttributeByName -Attrs $barAttrs -Name 'class'
        $barId    = Get-AttributeByName -Attrs $barAttrs -Name 'id'
        $expectedBarId = "cc-engine-bar-$($card.Slug)"
        if ($barTok.TagName -ne 'div') {
            Add-DriftCode -Row $cardRow -Code 'MALFORMED_ENGINE_CARD' `
                -Context "Second child is <$($barTok.TagName)>; expected <div>."
        } else {
            if ($null -eq $barClass -or $barClass.Value -ne 'cc-engine-bar') {
                $actual = if ($null -eq $barClass) { '<missing>' } else { $barClass.Value }
                Add-DriftCode -Row $cardRow -Code 'MALFORMED_ENGINE_CARD' `
                    -Context "cc-engine-bar div class is '$actual'; expected exactly 'cc-engine-bar'."
            }
            if ($null -eq $barId -or $barId.Value -ne $expectedBarId) {
                $actual = if ($null -eq $barId) { '<missing>' } else { $barId.Value }
                Add-DriftCode -Row $cardRow -Code 'MALFORMED_ENGINE_CARD' `
                    -Context "cc-engine-bar div id is '$actual'; expected '$expectedBarId'."
            }
            foreach ($a in $barAttrs) {
                if ($a.Name -ne 'class' -and $a.Name -ne 'id') {
                    Add-DriftCode -Row $cardRow -Code 'MALFORMED_ENGINE_CARD' `
                        -Context "cc-engine-bar div carries unexpected attribute '$($a.Name)'."
                }
            }
            $barClose = Find-MatchingClose -Tokens $Tokens -StartTagIdx $childIdxs[1]
            if ($barClose -gt $childIdxs[1]) {
                for ($m = $childIdxs[1] + 1; $m -lt $barClose; $m++) {
                    $bt = $Tokens[$m]
                    if ($bt.Kind -eq 'Text' -and [string]::IsNullOrWhiteSpace($bt.Raw)) { continue }
                    Add-DriftCode -Row $cardRow -Code 'MALFORMED_ENGINE_CARD' `
                        -Context "cc-engine-bar div contains content; spec requires the element be empty."
                    break
                }
            }
        }

        # Child 3: <span class="cc-engine-cd" id="cc-engine-cd-<slug>"></span>
        $cdTok = $Tokens[$childIdxs[2]]
        $cdAttrs = if (-not [string]::IsNullOrWhiteSpace($cdTok.AttrText)) {
            Get-AttributesFromToken -AttrText $cdTok.AttrText
        } else { @() }
        $cdClass = Get-AttributeByName -Attrs $cdAttrs -Name 'class'
        $cdId    = Get-AttributeByName -Attrs $cdAttrs -Name 'id'
        $expectedCdId = "cc-engine-cd-$($card.Slug)"
        if ($cdTok.TagName -ne 'span') {
            Add-DriftCode -Row $cardRow -Code 'MALFORMED_ENGINE_CARD' `
                -Context "Third child is <$($cdTok.TagName)>; expected <span>."
        } else {
            if ($null -eq $cdClass -or $cdClass.Value -ne 'cc-engine-cd') {
                $actual = if ($null -eq $cdClass) { '<missing>' } else { $cdClass.Value }
                Add-DriftCode -Row $cardRow -Code 'MALFORMED_ENGINE_CARD' `
                    -Context "cc-engine-cd span class is '$actual'; expected exactly 'cc-engine-cd'."
            }
            if ($null -eq $cdId -or $cdId.Value -ne $expectedCdId) {
                $actual = if ($null -eq $cdId) { '<missing>' } else { $cdId.Value }
                Add-DriftCode -Row $cardRow -Code 'MALFORMED_ENGINE_CARD' `
                    -Context "cc-engine-cd span id is '$actual'; expected '$expectedCdId'."
            }
            foreach ($a in $cdAttrs) {
                if ($a.Name -ne 'class' -and $a.Name -ne 'id') {
                    Add-DriftCode -Row $cardRow -Code 'MALFORMED_ENGINE_CARD' `
                        -Context "cc-engine-cd span carries unexpected attribute '$($a.Name)'."
                }
            }
            $cdClose = Find-MatchingClose -Tokens $Tokens -StartTagIdx $childIdxs[2]
            if ($cdClose -gt $childIdxs[2]) {
                for ($m = $childIdxs[2] + 1; $m -lt $cdClose; $m++) {
                    $bt = $Tokens[$m]
                    if ($bt.Kind -eq 'Text' -and $bt.Raw.Length -eq 0) { continue }
                    Add-DriftCode -Row $cardRow -Code 'MALFORMED_ENGINE_CARD' `
                        -Context "cc-engine-cd span contains content; spec requires the element be empty."
                    break
                }
            }
        }

        # Registry cross-reference checks
        $proc = $null
        foreach ($p in $script:processRegistryRows) {
            if ([string]$p.cc_engine_slug -eq $card.Slug) { $proc = $p; break }
        }

        if ($null -eq $proc) {
            Add-DriftCode -Row $cardRow -Code 'ENGINE_SLUG_REGISTRY_MISMATCH' `
                -Context "Card slug '$($card.Slug)' has no matching cc_engine_slug in Orchestrator.ProcessRegistry."
            continue
        }

        # Page route mismatch
        $procPageRoute = [string]$proc.cc_page_route
        if (-not [string]::IsNullOrEmpty($procPageRoute) -and $RoutePaths -notcontains $procPageRoute) {
            Add-DriftCode -Row $cardRow -Code 'ENGINE_CARD_PAGE_MISMATCH' `
                -Context "Card on routes $($RoutePaths -join ', '); ProcessRegistry.cc_page_route is '$procPageRoute'."
        }

        # Registration completeness (every loaded ProcessRegistry row is run_mode = 1).
        $missingFields = @()
        if ([string]::IsNullOrEmpty([string]$proc.cc_engine_slug))  { $missingFields += 'cc_engine_slug' }
        if ([string]::IsNullOrEmpty([string]$proc.cc_engine_label)) { $missingFields += 'cc_engine_label' }
        if ([string]::IsNullOrEmpty([string]$proc.cc_page_route))   { $missingFields += 'cc_page_route' }
        if ($proc.cc_sort_order -is [System.DBNull]) { $missingFields += 'cc_sort_order' }
        if ($missingFields.Count -gt 0) {
            Add-DriftCode -Row $cardRow -Code 'MISSING_ENGINE_CARD_REGISTRATION' `
                -Context "ProcessRegistry row for slug '$($card.Slug)' has NULL in: $($missingFields -join ', ')."
        }

        # Label text mismatch: find the cc-engine-label span inside the card
        # and compare its text to cc_engine_label.
        $cardTokenIdx = $card.TokenIdx
        if ($cardEndIdx -gt $cardTokenIdx) {
            $labelText = $null
            for ($k = $cardTokenIdx + 1; $k -lt $cardEndIdx; $k++) {
                $tt = $Tokens[$k]
                if ($tt.Kind -ne 'StartTag') { continue }
                if ($tt.TagName -ne 'span') { continue }
                if (Test-AttrTextMatches -AttrText $tt.AttrText -Pattern 'class\s*=\s*["'']cc-engine-label["'']') {
                    $spanEnd = Find-MatchingClose -Tokens $Tokens -StartTagIdx $k
                    if ($spanEnd -gt $k) {
                        $sbText = New-Object System.Text.StringBuilder
                        for ($m = $k + 1; $m -lt $spanEnd; $m++) {
                            if ($Tokens[$m].Kind -eq 'Text') {
                                [void]$sbText.Append($Tokens[$m].Raw)
                            }
                        }
                        $labelText = $sbText.ToString().Trim()
                    }
                    break
                }
            }
            if ($null -ne $labelText -and -not [string]::IsNullOrEmpty([string]$proc.cc_engine_label)) {
                $expectedLabel = [string]$proc.cc_engine_label
                if ($labelText -ne $expectedLabel) {
                    Add-DriftCode -Row $cardRow -Code 'ENGINE_LABEL_REGISTRY_MISMATCH' `
                        -Context "Card label text '$labelText' does not match ProcessRegistry.cc_engine_label '$expectedLabel'."
                }
            }
        }
    }

    # Card ordering
    # Cards should appear in cc_sort_order ascending.
    $orderedCards = @($cardsOnPage | Sort-Object { $_.TokenIdx })
    $expectedOrder = @($orderedCards | ForEach-Object {
        $slug = $_.Slug
        $row = $_
        $proc = $null
        foreach ($p in $script:processRegistryRows) {
            if ([string]$p.cc_engine_slug -eq $slug) { $proc = $p; break }
        }
        $sortOrd = if ($proc -and $proc.cc_sort_order -isnot [System.DBNull]) { [int]$proc.cc_sort_order } else { 999999 }
        [ordered]@{ Card = $row; SortOrder = $sortOrd }
    })
    $sortedByDeclared = @($expectedOrder | Sort-Object { $_.SortOrder })
    $orderMismatch = $false
    for ($i = 0; $i -lt $expectedOrder.Count; $i++) {
        if ($expectedOrder[$i].Card.Slug -ne $sortedByDeclared[$i].Card.Slug) {
            $orderMismatch = $true
            break
        }
    }
    if ($orderMismatch -and $script:htmlFileRowByFile.ContainsKey($script:CurrentFile)) {
        Add-DriftCode -Row $script:htmlFileRowByFile[$script:CurrentFile] `
            -Code 'ENGINE_CARD_ORDER_MISMATCH' `
            -Context "Engine cards on page appear in different order than Orchestrator.ProcessRegistry.cc_sort_order."
    }
}
<# ============================================================================
   FUNCTIONS: PAGE CHROME VALIDATION
   ----------------------------------------------------------------------------
   Validate the header bar, refresh info, and engine row chrome structure
   against the mandated markup.
   Prefix: (none)
   ============================================================================ #>

# Validate the header-bar, refresh-info, and engine-row chrome structure against
# the mandated markup, consolidating faults into MALFORMED_HEADER_BAR_STRUCTURE,
# MALFORMED_REFRESH_INFO_STRUCTURE, and MALFORMED_ENGINE_ROW_STRUCTURE. Engine
# card internals are validated separately by Invoke-EngineCardValidation.
function Invoke-PageChromeValidation {
    param(
        [Parameter(Mandatory)]$Tokens
    )

    if ($null -eq $Tokens -or $Tokens.Count -eq 0) { return }
    if (-not $script:htmlFileRowByFile.ContainsKey($script:CurrentFile)) { return }
    $fileRow = $script:htmlFileRowByFile[$script:CurrentFile]

    # Locate the cc-header-bar element
    $headerBarIdx = -1
    for ($i = 0; $i -lt $Tokens.Count; $i++) {
        $t = $Tokens[$i]
        if ($t.Kind -ne 'StartTag') { continue }
        if ($t.TagName -ne 'div') { continue }
        if (Test-AttrTextMatches -AttrText $t.AttrText -Pattern 'class\s*=\s*["'']cc-header-bar["'']') {
            $headerBarIdx = $i
            break
        }
    }
    # Get-PageShellDrift handles missing case
    if ($headerBarIdx -lt 0) { return }

    # Validate cc-header-bar's outer-element attributes.
    $hbAttrs = Get-AttributesFromToken -AttrText $Tokens[$headerBarIdx].AttrText
    $hbClass = Get-AttributeByName -Attrs $hbAttrs -Name 'class'
    if ($null -eq $hbClass -or $hbClass.Value -ne 'cc-header-bar') {
        $actual = if ($null -eq $hbClass) { '<missing>' } else { $hbClass.Value }
        Add-DriftCode -Row $fileRow -Code 'MALFORMED_HEADER_BAR_STRUCTURE' `
            -Context "cc-header-bar class is '$actual'; expected exactly 'cc-header-bar'."
    }
    foreach ($a in $hbAttrs) {
        if ($a.Name -ne 'class') {
            Add-DriftCode -Row $fileRow -Code 'MALFORMED_HEADER_BAR_STRUCTURE' `
                -Context "cc-header-bar carries unexpected attribute '$($a.Name)'."
        }
    }

    $headerBarEndIdx = Find-MatchingClose -Tokens $Tokens -StartTagIdx $headerBarIdx
    if ($headerBarEndIdx -le $headerBarIdx) {
        Add-DriftCode -Row $fileRow -Code 'MALFORMED_HEADER_BAR_STRUCTURE' `
            -Context "cc-header-bar <div> has no matching closing tag."
        return
    }

    # Collect the immediate children of cc-header-bar
    $hbChildren = @()
    $cursor = $headerBarIdx + 1
    while ($cursor -lt $headerBarEndIdx) {
        $tt = $Tokens[$cursor]
        if ($tt.Kind -eq 'Text' -and [string]::IsNullOrWhiteSpace($tt.Raw)) { $cursor++; continue }
        if ($tt.Kind -eq 'Comment') { $cursor++; continue }
        if ($tt.Kind -eq 'EndTag') { $cursor++; continue }
        if ($tt.Kind -eq 'PsInterp') { $cursor++; continue }
        if ($tt.Kind -eq 'Entity') { $cursor++; continue }
        if ($tt.Kind -eq 'StartTag' -or $tt.Kind -eq 'SelfClose') {
            $hbChildren += $cursor
            if ($tt.Kind -eq 'SelfClose') { $cursor++; continue }
            $childClose = Find-MatchingClose -Tokens $Tokens -StartTagIdx $cursor
            if ($childClose -lt 0 -or $childClose -ge $headerBarEndIdx) {
                $cursor = $headerBarEndIdx
            } else {
                $cursor = $childClose + 1
            }
            continue
        }
        $cursor++
    }

    # Validate first child: unattributed <div> containing $headerHtml
    if ($hbChildren.Count -lt 1) {
        Add-DriftCode -Row $fileRow -Code 'MALFORMED_HEADER_BAR_STRUCTURE' `
            -Context "cc-header-bar has no children; expected unattributed <div> wrapping `$headerHtml as the first child."
        return
    }
    $leftIdx = $hbChildren[0]
    $leftTok = $Tokens[$leftIdx]
    if ($leftTok.TagName -ne 'div') {
        Add-DriftCode -Row $fileRow -Code 'MALFORMED_HEADER_BAR_STRUCTURE' `
            -Context "cc-header-bar first child is <$($leftTok.TagName)>; expected <div>."
    } else {
        $leftAttrs = if (-not [string]::IsNullOrWhiteSpace($leftTok.AttrText)) {
            Get-AttributesFromToken -AttrText $leftTok.AttrText
        } else { @() }
        $leftClass = Get-AttributeByName -Attrs $leftAttrs -Name 'class'
        $leftId    = Get-AttributeByName -Attrs $leftAttrs -Name 'id'
        if ($null -ne $leftClass) {
            Add-DriftCode -Row $fileRow -Code 'MALFORMED_HEADER_BAR_STRUCTURE' `
                -Context "cc-header-bar first child <div> carries a class attribute; spec requires the element be unattributed."
        }
        if ($null -ne $leftId) {
            Add-DriftCode -Row $fileRow -Code 'MALFORMED_HEADER_BAR_STRUCTURE' `
                -Context "cc-header-bar first child <div> carries an id attribute; spec requires the element be unattributed."
        }
        $leftClose = Find-MatchingClose -Tokens $Tokens -StartTagIdx $leftIdx
        $hasHeaderInterp = $false
        if ($leftClose -gt $leftIdx) {
            for ($m = $leftIdx + 1; $m -lt $leftClose; $m++) {
                $bt = $Tokens[$m]
                if ($bt.Kind -eq 'PsInterp' -and
                    ($bt.Raw -eq '$headerHtml' -or $bt.Raw -eq '${headerHtml}')) {
                    $hasHeaderInterp = $true
                    break
                }
            }
        }
        if (-not $hasHeaderInterp) {
            Add-DriftCode -Row $fileRow -Code 'MALFORMED_HEADER_BAR_STRUCTURE' `
                -Context "cc-header-bar first child <div> does not contain the `$headerHtml substitution."
        }
    }

    # Validate second child: <div class="cc-header-right">
    if ($hbChildren.Count -lt 2) {
        Add-DriftCode -Row $fileRow -Code 'MALFORMED_HEADER_BAR_STRUCTURE' `
            -Context "cc-header-bar is missing its second child; expected <div class=`"cc-header-right`">."
        return
    }
    if ($hbChildren.Count -gt 2) {
        Add-DriftCode -Row $fileRow -Code 'MALFORMED_HEADER_BAR_STRUCTURE' `
            -Context "cc-header-bar has $($hbChildren.Count) immediate children; expected exactly 2."
    }
    $rightIdx = $hbChildren[1]
    $rightTok = $Tokens[$rightIdx]
    if ($rightTok.TagName -ne 'div') {
        Add-DriftCode -Row $fileRow -Code 'MALFORMED_HEADER_BAR_STRUCTURE' `
            -Context "cc-header-bar second child is <$($rightTok.TagName)>; expected <div>."
        return
    }
    $rightAttrs = if (-not [string]::IsNullOrWhiteSpace($rightTok.AttrText)) {
        Get-AttributesFromToken -AttrText $rightTok.AttrText
    } else { @() }
    $rightClass = Get-AttributeByName -Attrs $rightAttrs -Name 'class'
    if ($null -eq $rightClass -or $rightClass.Value -ne 'cc-header-right') {
        $actual = if ($null -eq $rightClass) { '<missing>' } else { $rightClass.Value }
        Add-DriftCode -Row $fileRow -Code 'MALFORMED_HEADER_BAR_STRUCTURE' `
            -Context "cc-header-bar second child class is '$actual'; expected exactly 'cc-header-right'."
        return
    }
    foreach ($a in $rightAttrs) {
        if ($a.Name -ne 'class') {
            Add-DriftCode -Row $fileRow -Code 'MALFORMED_HEADER_BAR_STRUCTURE' `
                -Context "cc-header-right carries unexpected attribute '$($a.Name)'."
        }
    }

    # Collect children of cc-header-right
    $rightEndIdx = Find-MatchingClose -Tokens $Tokens -StartTagIdx $rightIdx
    if ($rightEndIdx -le $rightIdx) {
        Add-DriftCode -Row $fileRow -Code 'MALFORMED_HEADER_BAR_STRUCTURE' `
            -Context "cc-header-right <div> has no matching closing tag."
        return
    }
    $hrChildren = @()
    $cursor = $rightIdx + 1
    while ($cursor -lt $rightEndIdx) {
        $tt = $Tokens[$cursor]
        if ($tt.Kind -eq 'Text' -and [string]::IsNullOrWhiteSpace($tt.Raw)) { $cursor++; continue }
        if ($tt.Kind -eq 'Comment') { $cursor++; continue }
        if ($tt.Kind -eq 'EndTag') { $cursor++; continue }
        if ($tt.Kind -eq 'PsInterp') { $cursor++; continue }
        if ($tt.Kind -eq 'Entity') { $cursor++; continue }
        if ($tt.Kind -eq 'StartTag' -or $tt.Kind -eq 'SelfClose') {
            $hrChildren += $cursor
            if ($tt.Kind -eq 'SelfClose') { $cursor++; continue }
            $childClose = Find-MatchingClose -Tokens $Tokens -StartTagIdx $cursor
            if ($childClose -lt 0 -or $childClose -ge $rightEndIdx) {
                $cursor = $rightEndIdx
            } else {
                $cursor = $childClose + 1
            }
            continue
        }
        $cursor++
    }

    # Validate first cc-header-right child: cc-refresh-info
    $refreshInfoIdx = -1
    $engineRowIdx = -1
    if ($hrChildren.Count -lt 1) {
        Add-DriftCode -Row $fileRow -Code 'MALFORMED_HEADER_BAR_STRUCTURE' `
            -Context "cc-header-right has no children; expected cc-refresh-info as the first child."
    } else {
        $firstHrTok = $Tokens[$hrChildren[0]]
        $firstHrAttrs = if (-not [string]::IsNullOrWhiteSpace($firstHrTok.AttrText)) {
            Get-AttributesFromToken -AttrText $firstHrTok.AttrText
        } else { @() }
        $firstHrClass = Get-AttributeByName -Attrs $firstHrAttrs -Name 'class'
        if ($firstHrTok.TagName -eq 'div' -and $null -ne $firstHrClass -and $firstHrClass.Value -eq 'cc-refresh-info') {
            $refreshInfoIdx = $hrChildren[0]
        } else {
            $actualClass = if ($null -eq $firstHrClass) { '<missing>' } else { $firstHrClass.Value }
            Add-DriftCode -Row $fileRow -Code 'MALFORMED_HEADER_BAR_STRUCTURE' `
                -Context "cc-header-right first child is <$($firstHrTok.TagName) class='$actualClass'>; expected <div class=`"cc-refresh-info`">."
        }

        if ($hrChildren.Count -ge 2) {
            $secondHrTok = $Tokens[$hrChildren[1]]
            $secondHrAttrs = if (-not [string]::IsNullOrWhiteSpace($secondHrTok.AttrText)) {
                Get-AttributesFromToken -AttrText $secondHrTok.AttrText
            } else { @() }
            $secondHrClass = Get-AttributeByName -Attrs $secondHrAttrs -Name 'class'
            if ($secondHrTok.TagName -eq 'div' -and $null -ne $secondHrClass -and $secondHrClass.Value -eq 'cc-engine-row') {
                $engineRowIdx = $hrChildren[1]
            } else {
                $actualClass = if ($null -eq $secondHrClass) { '<missing>' } else { $secondHrClass.Value }
                Add-DriftCode -Row $fileRow -Code 'MALFORMED_HEADER_BAR_STRUCTURE' `
                    -Context "cc-header-right second child is <$($secondHrTok.TagName) class='$actualClass'>; expected optional <div class=`"cc-engine-row`"> or no further child."
            }
        }

        if ($hrChildren.Count -gt 2) {
            Add-DriftCode -Row $fileRow -Code 'MALFORMED_HEADER_BAR_STRUCTURE' `
                -Context "cc-header-right has $($hrChildren.Count) immediate children; expected at most 2 (cc-refresh-info, optional cc-engine-row)."
        }
    }

    # Validate cc-refresh-info block
    if ($refreshInfoIdx -ge 0) {
        Test-RefreshInfoBlock -Tokens $Tokens -RefreshInfoIdx $refreshInfoIdx -FileRow $fileRow
    }

    # Validate cc-engine-row container
    if ($engineRowIdx -ge 0) {
        Test-EngineRowContainer -Tokens $Tokens -EngineRowIdx $engineRowIdx -FileRow $fileRow
    }
}

# Validate the cc-refresh-info block (live indicator, "Live | Updated:" with
# cc-last-update span, and the cc-page-refresh-btn). Faults fire
# MALFORMED_REFRESH_INFO_STRUCTURE.
function Test-RefreshInfoBlock {
    param(
        [Parameter(Mandatory)]$Tokens,
        [Parameter(Mandatory)][int]$RefreshInfoIdx,
        [Parameter(Mandatory)]$FileRow
    )

    $riTok = $Tokens[$RefreshInfoIdx]
    $riAttrs = if (-not [string]::IsNullOrWhiteSpace($riTok.AttrText)) {
        Get-AttributesFromToken -AttrText $riTok.AttrText
    } else { @() }
    $riClass = Get-AttributeByName -Attrs $riAttrs -Name 'class'
    if ($null -eq $riClass -or $riClass.Value -ne 'cc-refresh-info') {
        $actual = if ($null -eq $riClass) { '<missing>' } else { $riClass.Value }
        Add-DriftCode -Row $FileRow -Code 'MALFORMED_REFRESH_INFO_STRUCTURE' `
            -Context "cc-refresh-info class is '$actual'; expected exactly 'cc-refresh-info'."
    }
    foreach ($a in $riAttrs) {
        if ($a.Name -ne 'class') {
            Add-DriftCode -Row $FileRow -Code 'MALFORMED_REFRESH_INFO_STRUCTURE' `
                -Context "cc-refresh-info carries unexpected attribute '$($a.Name)'."
        }
    }

    $riEndIdx = Find-MatchingClose -Tokens $Tokens -StartTagIdx $RefreshInfoIdx
    if ($riEndIdx -le $RefreshInfoIdx) {
        Add-DriftCode -Row $FileRow -Code 'MALFORMED_REFRESH_INFO_STRUCTURE' `
            -Context "cc-refresh-info <div> has no matching closing tag."
        return
    }

    # Step 1: cc-live-indicator
    $step1Idx = Find-NextSignificantToken -Tokens $Tokens -StartAt ($RefreshInfoIdx + 1)
    $liveIndicatorClose = -1
    if ($step1Idx -lt 0 -or $step1Idx -ge $riEndIdx) {
        Add-DriftCode -Row $FileRow -Code 'MALFORMED_REFRESH_INFO_STRUCTURE' `
            -Context "cc-refresh-info has no children; expected <span class=`"cc-live-indicator`"></span> as the first child."
        return
    }
    $liTok = $Tokens[$step1Idx]
    if ($liTok.Kind -ne 'StartTag' -or $liTok.TagName -ne 'span') {
        Add-DriftCode -Row $FileRow -Code 'MALFORMED_REFRESH_INFO_STRUCTURE' `
            -Context "cc-refresh-info first child is not <span>; expected <span class=`"cc-live-indicator`"></span>."
        return
    }
    $liAttrs = if (-not [string]::IsNullOrWhiteSpace($liTok.AttrText)) {
        Get-AttributesFromToken -AttrText $liTok.AttrText
    } else { @() }
    $liClass = Get-AttributeByName -Attrs $liAttrs -Name 'class'
    if ($null -eq $liClass -or $liClass.Value -ne 'cc-live-indicator') {
        $actual = if ($null -eq $liClass) { '<missing>' } else { $liClass.Value }
        Add-DriftCode -Row $FileRow -Code 'MALFORMED_REFRESH_INFO_STRUCTURE' `
            -Context "Live indicator span class is '$actual'; expected exactly 'cc-live-indicator'."
    }
    foreach ($a in $liAttrs) {
        if ($a.Name -ne 'class') {
            Add-DriftCode -Row $FileRow -Code 'MALFORMED_REFRESH_INFO_STRUCTURE' `
                -Context "Live indicator span carries unexpected attribute '$($a.Name)'."
        }
    }
    $nextAfterLi = $step1Idx + 1
    if ($nextAfterLi -ge $Tokens.Count -or
        $Tokens[$nextAfterLi].Kind -ne 'EndTag' -or
        $Tokens[$nextAfterLi].TagName -ne 'span') {
        Add-DriftCode -Row $FileRow -Code 'MALFORMED_REFRESH_INFO_STRUCTURE' `
            -Context "Live indicator span is not empty; spec requires <span class=`"cc-live-indicator`"></span> with no content between the tags."
        $liveIndicatorClose = Find-MatchingClose -Tokens $Tokens -StartTagIdx $step1Idx
    } else {
        $liveIndicatorClose = $nextAfterLi
    }
    if ($liveIndicatorClose -lt 0) { return }

    # Step 2: <span>Live</span>
    $step2Idx = Find-NextSignificantToken -Tokens $Tokens -StartAt ($liveIndicatorClose + 1)
    if ($step2Idx -lt 0 -or $step2Idx -ge $riEndIdx) {
        Add-DriftCode -Row $FileRow -Code 'MALFORMED_REFRESH_INFO_STRUCTURE' `
            -Context "cc-refresh-info is missing the <span>Live</span> element."
        return
    }
    $liveSpanTok = $Tokens[$step2Idx]
    $liveSpanCloseIdx = -1
    if ($liveSpanTok.Kind -ne 'StartTag' -or $liveSpanTok.TagName -ne 'span') {
        Add-DriftCode -Row $FileRow -Code 'MALFORMED_REFRESH_INFO_STRUCTURE' `
            -Context "Expected <span>Live</span>; found a different element."
        return
    }
    if (-not [string]::IsNullOrWhiteSpace($liveSpanTok.AttrText)) {
        Add-DriftCode -Row $FileRow -Code 'MALFORMED_REFRESH_INFO_STRUCTURE' `
            -Context "The <span> wrapping 'Live' carries attributes; spec requires the element be unattributed."
    }
    $liveSpanCloseIdx = Find-MatchingClose -Tokens $Tokens -StartTagIdx $step2Idx
    if ($liveSpanCloseIdx -le $step2Idx -or $liveSpanCloseIdx -ge $riEndIdx) {
        Add-DriftCode -Row $FileRow -Code 'MALFORMED_REFRESH_INFO_STRUCTURE' `
            -Context "The <span> wrapping 'Live' has no matching closing tag inside cc-refresh-info."
        return
    }
    $liveTextBuilder = New-Object System.Text.StringBuilder
    $liveSpanHasInterp = $false
    for ($m = $step2Idx + 1; $m -lt $liveSpanCloseIdx; $m++) {
        $bt = $Tokens[$m]
        if ($bt.Kind -eq 'Text') { [void]$liveTextBuilder.Append($bt.Raw) }
        elseif ($bt.Kind -eq 'PsInterp') { $liveSpanHasInterp = $true }
        else { $liveSpanHasInterp = $true }
    }
    if ($liveSpanHasInterp) {
        Add-DriftCode -Row $FileRow -Code 'MALFORMED_REFRESH_INFO_STRUCTURE' `
            -Context "The 'Live' span body contains PowerShell interpolation or non-text content; spec requires the literal text 'Live'."
    } elseif ($liveTextBuilder.ToString() -ne 'Live') {
        Add-DriftCode -Row $FileRow -Code 'MALFORMED_REFRESH_INFO_STRUCTURE' `
            -Context "The 'Live' span body is '$($liveTextBuilder.ToString())'; spec requires the literal text 'Live'."
    }

    # Step 3: literal text " | Updated: " between </span> and the next span
    $step3CursorIdx = $liveSpanCloseIdx + 1
    $literalTextBuilder = New-Object System.Text.StringBuilder
    $literalHasInterp = $false
    $cursor = $step3CursorIdx
    while ($cursor -lt $riEndIdx) {
        $bt = $Tokens[$cursor]
        if ($bt.Kind -eq 'Text') {
            [void]$literalTextBuilder.Append($bt.Raw)
            $cursor++
            continue
        }
        if ($bt.Kind -eq 'PsInterp') {
            $literalHasInterp = $true
            $cursor++
            continue
        }
        if ($bt.Kind -eq 'StartTag' -or $bt.Kind -eq 'SelfClose') { break }
        $cursor++
    }
    $step4Idx = $cursor
    if ($literalHasInterp) {
        Add-DriftCode -Row $FileRow -Code 'MALFORMED_REFRESH_INFO_STRUCTURE' `
            -Context "Status line literal text between Live and last-update spans contains PowerShell interpolation; spec requires the literal text ' | Updated: '."
    } else {
        $literalText = $literalTextBuilder.ToString()
        if ($literalText -ne ' | Updated: ') {
            Add-DriftCode -Row $FileRow -Code 'MALFORMED_REFRESH_INFO_STRUCTURE' `
                -Context "Status line literal text between Live and last-update spans is '$literalText'; spec requires exactly ' | Updated: '."
        }
    }

    # Step 4: <span id="cc-last-update" class="cc-last-updated">-</span>
    if ($step4Idx -ge $riEndIdx) {
        Add-DriftCode -Row $FileRow -Code 'MALFORMED_REFRESH_INFO_STRUCTURE' `
            -Context "cc-refresh-info is missing the <span id=`"cc-last-update`" class=`"cc-last-updated`"> element."
        return
    }
    $lastUpdateTok = $Tokens[$step4Idx]
    if ($lastUpdateTok.Kind -ne 'StartTag' -or $lastUpdateTok.TagName -ne 'span') {
        Add-DriftCode -Row $FileRow -Code 'MALFORMED_REFRESH_INFO_STRUCTURE' `
            -Context "Expected <span id=`"cc-last-update`"...>; found a different element."
        return
    }
    $luAttrs = if (-not [string]::IsNullOrWhiteSpace($lastUpdateTok.AttrText)) {
        Get-AttributesFromToken -AttrText $lastUpdateTok.AttrText
    } else { @() }
    $luId    = Get-AttributeByName -Attrs $luAttrs -Name 'id'
    $luClass = Get-AttributeByName -Attrs $luAttrs -Name 'class'
    if ($null -eq $luId -or $luId.Value -ne 'cc-last-update') {
        $actual = if ($null -eq $luId) { '<missing>' } else { $luId.Value }
        Add-DriftCode -Row $FileRow -Code 'MALFORMED_REFRESH_INFO_STRUCTURE' `
            -Context "Last-update span id is '$actual'; expected exactly 'cc-last-update'."
    }
    if ($null -eq $luClass -or $luClass.Value -ne 'cc-last-updated') {
        $actual = if ($null -eq $luClass) { '<missing>' } else { $luClass.Value }
        Add-DriftCode -Row $FileRow -Code 'MALFORMED_REFRESH_INFO_STRUCTURE' `
            -Context "Last-update span class is '$actual'; expected exactly 'cc-last-updated'."
    }
    foreach ($a in $luAttrs) {
        if ($a.Name -ne 'id' -and $a.Name -ne 'class') {
            Add-DriftCode -Row $FileRow -Code 'MALFORMED_REFRESH_INFO_STRUCTURE' `
                -Context "Last-update span carries unexpected attribute '$($a.Name)'."
        }
    }
    $lastUpdateCloseIdx = Find-MatchingClose -Tokens $Tokens -StartTagIdx $step4Idx
    if ($lastUpdateCloseIdx -le $step4Idx -or $lastUpdateCloseIdx -ge $riEndIdx) {
        Add-DriftCode -Row $FileRow -Code 'MALFORMED_REFRESH_INFO_STRUCTURE' `
            -Context "Last-update span has no matching closing tag inside cc-refresh-info."
        return
    }
    $luTextBuilder = New-Object System.Text.StringBuilder
    $luHasInterp = $false
    for ($m = $step4Idx + 1; $m -lt $lastUpdateCloseIdx; $m++) {
        $bt = $Tokens[$m]
        if ($bt.Kind -eq 'Text') { [void]$luTextBuilder.Append($bt.Raw) }
        elseif ($bt.Kind -eq 'PsInterp') { $luHasInterp = $true }
        else { $luHasInterp = $true }
    }
    if ($luHasInterp) {
        Add-DriftCode -Row $FileRow -Code 'MALFORMED_REFRESH_INFO_STRUCTURE' `
            -Context "Last-update span body contains PowerShell interpolation or non-text content; spec requires the literal text '-'."
    } elseif ($luTextBuilder.ToString() -ne '-') {
        Add-DriftCode -Row $FileRow -Code 'MALFORMED_REFRESH_INFO_STRUCTURE' `
            -Context "Last-update span body is '$($luTextBuilder.ToString())'; spec requires the literal text '-'."
    }

    # Step 5: refresh button
    $step5Idx = Find-NextSignificantToken -Tokens $Tokens -StartAt ($lastUpdateCloseIdx + 1)
    if ($step5Idx -lt 0 -or $step5Idx -ge $riEndIdx) {
        Add-DriftCode -Row $FileRow -Code 'MALFORMED_REFRESH_INFO_STRUCTURE' `
            -Context "cc-refresh-info is missing the refresh button."
        return
    }
    $btnTok = $Tokens[$step5Idx]
    if ($btnTok.Kind -ne 'StartTag' -or $btnTok.TagName -ne 'button') {
        Add-DriftCode -Row $FileRow -Code 'MALFORMED_REFRESH_INFO_STRUCTURE' `
            -Context "Expected <button class=`"cc-page-refresh-btn`" ...>; found <$($btnTok.TagName)>."
        return
    }
    $btnAttrs = if (-not [string]::IsNullOrWhiteSpace($btnTok.AttrText)) {
        Get-AttributesFromToken -AttrText $btnTok.AttrText
    } else { @() }
    $btnClass = Get-AttributeByName -Attrs $btnAttrs -Name 'class'
    $btnData  = Get-AttributeByName -Attrs $btnAttrs -Name 'data-action-click'
    $btnTitle = Get-AttributeByName -Attrs $btnAttrs -Name 'title'
    if ($null -eq $btnClass -or $btnClass.Value -ne 'cc-page-refresh-btn') {
        $actual = if ($null -eq $btnClass) { '<missing>' } else { $btnClass.Value }
        Add-DriftCode -Row $FileRow -Code 'MALFORMED_REFRESH_INFO_STRUCTURE' `
            -Context "Refresh button class is '$actual'; expected exactly 'cc-page-refresh-btn'."
    }
    if ($null -eq $btnData -or $btnData.Value -ne 'cc-page-refresh') {
        $actual = if ($null -eq $btnData) { '<missing>' } else { $btnData.Value }
        Add-DriftCode -Row $FileRow -Code 'MALFORMED_REFRESH_INFO_STRUCTURE' `
            -Context "Refresh button data-action-click is '$actual'; expected exactly 'cc-page-refresh'."
    }
    if ($null -eq $btnTitle -or $btnTitle.Value -ne 'Refresh all data') {
        $actual = if ($null -eq $btnTitle) { '<missing>' } else { $btnTitle.Value }
        Add-DriftCode -Row $FileRow -Code 'MALFORMED_REFRESH_INFO_STRUCTURE' `
            -Context "Refresh button title is '$actual'; expected exactly 'Refresh all data'."
    }
    foreach ($a in $btnAttrs) {
        if ($a.Name -ne 'class' -and $a.Name -ne 'data-action-click' -and $a.Name -ne 'title') {
            Add-DriftCode -Row $FileRow -Code 'MALFORMED_REFRESH_INFO_STRUCTURE' `
                -Context "Refresh button carries unexpected attribute '$($a.Name)'."
        }
    }
    $btnCloseIdx = Find-MatchingClose -Tokens $Tokens -StartTagIdx $step5Idx
    if ($btnCloseIdx -le $step5Idx -or $btnCloseIdx -ge $riEndIdx) {
        Add-DriftCode -Row $FileRow -Code 'MALFORMED_REFRESH_INFO_STRUCTURE' `
            -Context "Refresh button has no matching closing tag inside cc-refresh-info."
        return
    }
    $btnEntityFound = $false
    $btnHasOtherContent = $false
    for ($m = $step5Idx + 1; $m -lt $btnCloseIdx; $m++) {
        $bt = $Tokens[$m]
        if ($bt.Kind -eq 'Text' -and [string]::IsNullOrWhiteSpace($bt.Raw)) { continue }
        if ($bt.Kind -eq 'Entity' -and $bt.Raw -eq '&#8635;') { $btnEntityFound = $true; continue }
        $btnHasOtherContent = $true
        break
    }
    if (-not $btnEntityFound -or $btnHasOtherContent) {
        Add-DriftCode -Row $FileRow -Code 'MALFORMED_REFRESH_INFO_STRUCTURE' `
            -Context "Refresh button body is not exactly the entity reference '&#8635;'."
    }

    # After the button, there should be nothing significant remaining
    $afterBtnIdx = Find-NextSignificantToken -Tokens $Tokens -StartAt ($btnCloseIdx + 1)
    if ($afterBtnIdx -ge 0 -and $afterBtnIdx -lt $riEndIdx) {
        Add-DriftCode -Row $FileRow -Code 'MALFORMED_REFRESH_INFO_STRUCTURE' `
            -Context "cc-refresh-info contains content after the refresh button; spec requires the button be the last child."
    }
}

# Test-EngineRowContainer - validate cc-engine-row container shape
# Validates cc-engine-row's outer container is exactly <div class="cc-engine-row">
# with no other attributes, and its only permitted children are engine cards.
# Per-card structure is validated separately by Invoke-EngineCardValidation.
function Test-EngineRowContainer {
    param(
        [Parameter(Mandatory)]$Tokens,
        [Parameter(Mandatory)][int]$EngineRowIdx,
        [Parameter(Mandatory)]$FileRow
    )

    $erTok = $Tokens[$EngineRowIdx]
    $erAttrs = if (-not [string]::IsNullOrWhiteSpace($erTok.AttrText)) {
        Get-AttributesFromToken -AttrText $erTok.AttrText
    } else { @() }
    $erClass = Get-AttributeByName -Attrs $erAttrs -Name 'class'
    if ($null -eq $erClass -or $erClass.Value -ne 'cc-engine-row') {
        $actual = if ($null -eq $erClass) { '<missing>' } else { $erClass.Value }
        Add-DriftCode -Row $FileRow -Code 'MALFORMED_ENGINE_ROW_STRUCTURE' `
            -Context "cc-engine-row class is '$actual'; expected exactly 'cc-engine-row'."
    }
    foreach ($a in $erAttrs) {
        if ($a.Name -ne 'class') {
            Add-DriftCode -Row $FileRow -Code 'MALFORMED_ENGINE_ROW_STRUCTURE' `
                -Context "cc-engine-row carries unexpected attribute '$($a.Name)'."
        }
    }

    $erEndIdx = Find-MatchingClose -Tokens $Tokens -StartTagIdx $EngineRowIdx
    if ($erEndIdx -le $EngineRowIdx) {
        Add-DriftCode -Row $FileRow -Code 'MALFORMED_ENGINE_ROW_STRUCTURE' `
            -Context "cc-engine-row <div> has no matching closing tag."
        return
    }

    # Each immediate child must be a <div> with id="cc-card-engine-<slug>".
    $cursor = $EngineRowIdx + 1
    while ($cursor -lt $erEndIdx) {
        $tt = $Tokens[$cursor]
        if ($tt.Kind -eq 'Text' -and [string]::IsNullOrWhiteSpace($tt.Raw)) { $cursor++; continue }
        if ($tt.Kind -eq 'Comment') { $cursor++; continue }
        if ($tt.Kind -eq 'EndTag') { $cursor++; continue }
        if ($tt.Kind -eq 'PsInterp') { $cursor++; continue }
        if ($tt.Kind -eq 'Entity') { $cursor++; continue }
        if ($tt.Kind -eq 'StartTag' -or $tt.Kind -eq 'SelfClose') {
            $isCard = $false
            if ($tt.TagName -eq 'div' -and -not [string]::IsNullOrWhiteSpace($tt.AttrText)) {
                $childAttrs = Get-AttributesFromToken -AttrText $tt.AttrText
                $childId = Get-AttributeByName -Attrs $childAttrs -Name 'id'
                if ($null -ne $childId -and $childId.Value -match '^cc-card-engine-') {
                    $isCard = $true
                }
            }
            if (-not $isCard) {
                Add-DriftCode -Row $FileRow -Code 'MALFORMED_ENGINE_ROW_STRUCTURE' `
                    -Context "cc-engine-row contains a non-engine-card child: <$($tt.TagName)>."
            }
            if ($tt.Kind -eq 'SelfClose') { $cursor++; continue }
            $childClose = Find-MatchingClose -Tokens $Tokens -StartTagIdx $cursor
            if ($childClose -lt 0 -or $childClose -ge $erEndIdx) {
                $cursor = $erEndIdx
            } else {
                $cursor = $childClose + 1
            }
            continue
        }
        $cursor++
    }
}
<# ============================================================================
   EXECUTION: SCRIPT EXECUTION
   ----------------------------------------------------------------------------
   Discover host files, load registries, walk each file, validate output,
   compute occurrence indices, summarize, and write to the database.
   Prefix: (none)
   ============================================================================ #>

# -- File Discovery --

Write-Log "Discovering HTML-emitting PS files..."

$psFiles = New-Object System.Collections.Generic.List[object]
foreach ($root in $PsScanRoots) {
    if (-not (Test-Path $root.Path)) {
        Write-Log "Scan root not found, skipping: $($root.Path)" 'WARN'
        continue
    }
    $found = @(Get-ChildItem -Path $root.Path -Filter $root.Pattern -Recurse -File |
                 Select-Object -ExpandProperty FullName)
    foreach ($f in $found) {
        [void]$psFiles.Add([ordered]@{ FullPath = $f })
    }
}

if (-not [string]::IsNullOrEmpty($FileFilter)) {
    $filtered = New-Object System.Collections.Generic.List[object]
    foreach ($f in $psFiles) {
        $name = [System.IO.Path]::GetFileName($f.FullPath)
        if ($name -eq $FileFilter -or $name -like $FileFilter) {
            [void]$filtered.Add($f)
        }
    }
    $psFiles = $filtered
    Write-Log ("FileFilter applied: '{0}' -> {1} file(s)" -f $FileFilter, $psFiles.Count)
} else {
    Write-Log ("Discovered {0} PS files to scan" -f $psFiles.Count)
}

# -- Registry Loads --

Write-Log "Loading Object_Registry classification (registry_id, zone, object_type) for Route/API/Module files..."
$script:zoneScopeMap = Get-ObjectRegistryZoneScopeMap `
    -ServerInstance $script:XFActsServerInstance `
    -Database       $script:XFActsDatabase `
    -FileType       @('Route','API','Module')
Write-Log ("  Object_Registry rows loaded: {0}" -f $script:zoneScopeMap.Count)

Write-Log "Loading Component_Registry cc_prefix map for Route/API/Module files..."
$ccPrefixMap = Get-ComponentRegistryPrefixMap `
    -ServerInstance $script:XFActsServerInstance `
    -Database       $script:XFActsDatabase `
    -FileType       @('Route','API','Module')
foreach ($kv in $ccPrefixMap.GetEnumerator()) {
    $script:ccPrefixByFile[$kv.Key] = $kv.Value
    if (-not [string]::IsNullOrEmpty($kv.Value)) {
        [void]$script:knownPagePrefixes.Add($kv.Value)
    }
}
Write-Log ("  cc_prefix entries loaded: {0} ({1} distinct prefixes)" -f $script:ccPrefixByFile.Count, $script:knownPagePrefixes.Count)

$objectRegistryMisses = New-Object 'System.Collections.Generic.HashSet[string]'

# -- Orchestrator ProcessRegistry Load --

# Engine card validation cross-references Orchestrator.ProcessRegistry.
Write-Log "Loading Orchestrator.ProcessRegistry rows for engine card validation..."
try {
    # No is_active column on Orchestrator.ProcessRegistry; the run_mode
    # column carries the active/inactive distinction:
    #   run_mode = 0 -> inactive (not validated)
    #   run_mode = 1 -> active scheduled (appears as an engine card)
    #   run_mode = 2 -> active queue processor (does NOT appear on any CC page)
    # Filter to run_mode = 1 only since queue processors have no Control
    # Center page representation and therefore can't trigger any HTML drift.
    $prQuery = @"
SELECT process_name, cc_engine_slug, cc_engine_label,
       cc_page_route, cc_sort_order, run_mode
FROM Orchestrator.ProcessRegistry
WHERE run_mode = 1
"@
    $prResults = Invoke-Sqlcmd -ServerInstance $script:XFActsServerInstance `
                               -Database       $script:XFActsDatabase `
                               -Query          $prQuery `
                               -QueryTimeout   30 `
                               -ApplicationName $script:XFActsAppName `
                               -ErrorAction Stop `
                               -SuppressProviderContextWarning -TrustServerCertificate
    if ($null -ne $prResults) {
        $script:processRegistryRows = @($prResults)
    }
}
catch {
    Write-Log "ProcessRegistry query failed: $($_.Exception.Message). Engine card validation will be skipped." 'WARN'
}
Write-Log ("  ProcessRegistry rows loaded: {0}" -f $script:processRegistryRows.Count)

# -- Per-File Walk --

Write-Log "Walking PS files..."

foreach ($fileRec in $psFiles) {
    $fullPath = $fileRec.FullPath
    $name     = [System.IO.Path]::GetFileName($fullPath)

    $script:CurrentFile         = $name
    $script:CurrentFullPath     = $fullPath

    Write-Host "  Parsing $name ..." -NoNewline
    $parsed = Invoke-HtmlPsParse -FilePath $fullPath
    if ($null -eq $parsed) {
        Write-Host " FAILED" -ForegroundColor Red
        continue
    }

    # Discover HTML emissions in this file.
    $emissions = @()
    try {
        $emissions = @(Get-HtmlEmissions -Ast $parsed.Ast)
    } catch {
        Write-Host " WALK FAILED" -ForegroundColor Red
        Write-Log ("Emission discovery failed for {0}: {1}" -f $name, $_.Exception.Message) 'WARN'
        continue
    }

    if ($emissions.Count -eq 0) {
        Write-Host " no HTML found, skipped" -ForegroundColor DarkGray
        continue
    }

    Write-Host (" {0} emission(s) found" -f $emissions.Count) -ForegroundColor Green

    # File classification drives shell validation gating and scope. Registry
    # id, zone, and object_type all come from the one combined map. A file
    # absent from the map is a registration gap: stamp '<undefined>' zone and
    # record the file so FILE_NOT_REGISTERED is attached to its anchor row.
    $registeredType = $null
    if ($script:zoneScopeMap.ContainsKey($name)) {
        $info = $script:zoneScopeMap[$name]
        $registeredType = $info.ObjectType
        $script:CurrentFileZone = if ($info.Zone) { $info.Zone } else { '<undefined>' }
    } else {
        $script:CurrentFileZone = '<undefined>'
        [void]$objectRegistryMisses.Add($name)
    }
    $script:CurrentRegisteredType = $registeredType

    $script:CurrentCcPrefix = $null
    if ($script:ccPrefixByFile.ContainsKey($name)) {
        $script:CurrentCcPrefix = $script:ccPrefixByFile[$name]
    }

    $scope = if ($registeredType -eq 'Module') { 'SHARED' } else { 'LOCAL' }
    $dataScope = $scope
    $isHelperEmission = ($registeredType -eq 'Module')

    # Discover Add-PodeRoute -Path declarations.
    $routes = @(Get-PodeRoutes -Ast $parsed.Ast)
    $routePaths = @($routes | ForEach-Object { $_.Path })

    # Emit the file-level anchor row.
    $row = Add-HtmlFileRow `
        -ComponentName $name `
        -Scope         $scope `
        -LineEnd       $parsed.LineCount `
        -RoutePaths    $routePaths

    if (-not $row) { continue }

    # A file absent from Object_Registry surfaces as drift on its anchor row
    # rather than being silently misclassified.
    if ($objectRegistryMisses.Contains($name)) {
        Add-DriftCode -Row $row -Code 'FILE_NOT_REGISTERED'
    }

    $rowsBeforeWalk = $script:rows.Count
    $allOverlayConstructs = New-Object System.Collections.Generic.List[object]

    # Walk each emission separately so token line offsets are correct per
    # emission. Accumulate overlay constructs across the file for the
    # post-walk validators on the merged stream.
    foreach ($em in $emissions) {
        $emTokens = @(ConvertTo-HtmlTokens -Text $em.Text)

        # Helper-emitted argument-attribute values must derive from data
        # the helper received from its caller. Resolve the set of caller-
        # given variable names from the emission's enclosing function.
        $emCallerGivenVars = $null
        if ($null -ne $em.NodeRef) {
            $emFnAst = Get-EnclosingFunctionDefinitionAst -Node $em.NodeRef
            $emCallerGivenVars = Get-CallerGivenVariableNames -FunctionDefinitionAst $emFnAst
        }

        $walkResult = Invoke-HtmlTokenWalk `
            -Tokens           $emTokens `
            -FileLine0        $em.StartLine `
            -ParentFunction   $em.FunctionName `
            -DataScope        $dataScope `
            -IsHelperEmission $isHelperEmission `
            -PagePrefix       $script:CurrentCcPrefix `
            -CallerGivenVars  $emCallerGivenVars
        if ($walkResult.OverlayConstructs.Count -gt 0) {
            foreach ($c in $walkResult.OverlayConstructs) {
                $allOverlayConstructs.Add($c) | Out-Null
            }
        }
    }
    $rowsAfterWalk = $script:rows.Count
    Write-Host ("    -> {0} construct rows" -f ($rowsAfterWalk - $rowsBeforeWalk)) -ForegroundColor DarkCyan

    # Duplicate ID check
    Invoke-DuplicateIdCheck -FileName $name

    # File-wide token-stream validators
    # These run on every file kind (Route, API, Module) because the
    # offending constructs can appear in any HTML emission. Build the
    # concatenated token stream once and reuse it for all validators
    # below that need it.
    $concatTextAll = ''
    foreach ($em in $emissions) {
        $concatTextAll += $em.Text
        if (-not $concatTextAll.EndsWith("`n")) { $concatTextAll += "`n" }
    }
    $tokensAll = @()
    $firstEmissionLine = if ($emissions.Count -gt 0) { $emissions[0].StartLine } else { 1 }
    if (-not [string]::IsNullOrEmpty($concatTextAll)) {
        $tokensAll = @(ConvertTo-HtmlTokens -Text $concatTextAll)
        Test-ActionElementType              -Tokens $tokensAll -FileLine0 $firstEmissionLine
        Test-ArgumentPrefixMatch            -Tokens $tokensAll -FileLine0 $firstEmissionLine
        Test-PlatformDataAttributeClosedSet -Tokens $tokensAll -FileLine0 $firstEmissionLine
    }

    # For Route files, run page-shell validation and engine card validation
    # against the concatenated emission text.
    if ($registeredType -eq 'Route') {
        if ($tokensAll.Count -gt 0) {
            # Page shell drift attaches to HTML_FILE row.
            $shellDrift = Get-PageShellDrift -Tokens $tokensAll
            foreach ($code in $shellDrift) {
                Add-DriftCode -Row $row -Code $code
            }

            # Page chrome structural validation.
            Invoke-PageChromeValidation -Tokens $tokensAll

            # Engine card validation.
            Invoke-EngineCardValidation -Tokens $tokensAll -FileLine0 $firstEmissionLine -RoutePaths $routePaths

            # Overlay structural + contiguity validation runs against the
            # concatenated stream as well.
            Invoke-OverlayPostWalkValidation -Tokens $tokensAll -OverlayConstructs $allOverlayConstructs -FileLine0 $firstEmissionLine

            # New Route-only validators (Delivery 2).
            Test-BodyClassPrefixDiscipline -Tokens $tokensAll -FileRow $row -PagePrefix $script:CurrentCcPrefix
            Test-PageShellOrder            -Tokens $tokensAll -FileRow $row
            Test-PageShellWhitespace       -Tokens $tokensAll -FileRow $row -EmissionCount $emissions.Count
            Test-AttributeOrder            -Tokens $tokensAll -FileRow $row
        }

        # AST-based Route-only validators run on the raw AST, not the
        # token stream.
        Test-RouteVariableAssignments -Ast $parsed.Ast -FileRow $row
        Test-RouteLocalHelperFunctions -Ast $parsed.Ast -FileRow $row
    }
    elseif ($allOverlayConstructs.Count -gt 0) {
        # API / Module files: overlay validation still runs on the
        # concatenated stream (helpers may emit overlay constructs).
        if ($tokensAll.Count -gt 0) {
            Invoke-OverlayPostWalkValidation -Tokens $tokensAll -OverlayConstructs $allOverlayConstructs -FileLine0 $firstEmissionLine
        }
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

Write-Log "Clearing existing HTML rows from Asset_Registry..."
if (-not [string]::IsNullOrEmpty($FileFilter)) {
    $cleared = Invoke-SqlNonQuery -Query "DELETE FROM dbo.Asset_Registry WHERE file_type = 'HTML' AND file_name LIKE @pattern;" `
        -Parameters @{ pattern = $FileFilter }
} else {
    $cleared = Invoke-SqlNonQuery -Query "DELETE FROM dbo.Asset_Registry WHERE file_type = 'HTML';"
}
if (-not $cleared) {
    Write-Log "Failed to clear existing HTML rows. Aborting." 'ERROR'
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
        -ObjectRegistryMap  $script:zoneScopeMap `
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
<#
.SYNOPSIS
    xFACts - Asset Registry HTML Populator

.DESCRIPTION
    Walks every .ps1 and .psm1 file under the Control Center route and
    helper directories, identifies HTML-emitting constructs inside each
    file, and generates Asset_Registry rows describing every catalogable
    HTML construct found in the markup, plus drift codes against
    CC_HTML_Spec.md.

    HTML emission discovery covers three PowerShell patterns:
      * Here-strings (@"..."@ or @'...'@) whose content begins with HTML
      * StringBuilder Append/AppendLine call sequences inside helper
        functions
      * Plain string-literal returns (return "...") containing HTML

    The populator consumes shared infrastructure from
    xFACts-AssetRegistryFunctions.ps1: row construction, drift attachment,
    bulk insert, and registry loads. Per-language logic (PowerShell AST
    walk, HTML emission discovery, HTML tokenizer, attribute parsing,
    per-construct emitters, drift validators) lives here.

    UNLIKE the CSS and JS populators, the HTML populator does NOT use a
    Node helper. CSS and JS files are pure CSS/JS and feed cleanly to
    PostCSS/acorn. HTML lives inside PowerShell strings with $variable
    interpolation, so no general HTML parser would handle the input
    correctly. The populator implements its own HTML tokenizer that
    treats PowerShell interpolation as a first-class concept.

    HTML is embedded inside three Object_Registry-classified file kinds:
      * 'Route'  - .ps1 files registering Pode page routes (full pages)
      * 'API'    - .ps1 files registering Pode API routes (HTML fragments)
      * 'Module' - .psm1 files providing shared helper functions
    The HTML_FILE row's component_name is the bare filename, joined to
    Object_Registry on object_name with object_type IN (Route, API, Module).
    HTML_FILE is HTML's anchor row, parallel to CSS_FILE / JS_FILE in the
    CSS / JS populators; the file_type column (always 'HTML' for rows
    emitted by this populator) disambiguates which kind of file is being
    anchored.

    Component types emitted by this populator:
      * HTML_FILE              - file-level anchor row, one per host file
      * HTML_ID                - every id="..." attribute
      * HTML_DATA_ATTRIBUTE    - every data-* attribute (including
                                 data-action-* dispatch attributes)
      * HTML_EVENT_HANDLER     - every on* attribute (always forbidden
                                 per spec; one row per occurrence with
                                 FORBIDDEN_INLINE_EVENT_HANDLER drift)
      * HTML_TEXT              - text content and user-facing attribute
                                 values (title, placeholder, aria-label,
                                 alt)
      * HTML_ENTITY            - HTML entities (named, numeric, direct
                                 Unicode)
      * HTML_SVG               - SVG outer-element capture
      * HTML_COMMENT           - HTML comments (section dividers, panel
                                 purpose comments, inline annotations)
      * CSS_FILE (USAGE)       - <link rel="stylesheet" href="...">
                                 references
      * JS_FILE (USAGE)        - <script src="..."></script> references
      * CSS_CLASS (USAGE)      - every class name in every class="..."
                                 attribute

    Cross-population USAGE rows resolve scope and source_file against
    existing DEFINITION rows in the catalog at scan time. Per the
    populator pipeline order (CSS -> HTML -> JS -> PS), CSS DEFINITIONs
    always exist when HTML runs; the JS populator's resolution closes
    the loop from the other direction for any HTML-emitted data-action
    references that name page-level JS dispatch entries.

    Run AFTER the CSS populator has loaded all CSS_CLASS DEFINITION rows.

.PARAMETER Execute
    Required to actually delete the HTML rows from Asset_Registry and
    write the new row set. Without this flag, runs in preview mode.

.PARAMETER FileFilter
    Optional file-name filter for processing a single file or subset
    (e.g., -FileFilter 'BusinessServices.ps1' processes only that file).

.NOTES
    File Name : Populate-AssetRegistry-HTML.ps1
    Location  : E:\xFACts-PowerShell
    Version   : Tracked in dbo.System_Metadata (component: Tools.Utilities)
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

Initialize-XFActsScript -ScriptName 'Populate-AssetRegistry-HTML' -Execute:$Execute

$ErrorActionPreference = 'Stop'

# ============================================================================
# CONFIGURATION
# ============================================================================

$CcRoot = 'E:\xFACts-ControlCenter'

# Roots scanned for HTML-emitting PS files. The routes\ directory contains
# both Route files (page handlers) and API files (endpoint handlers), both
# as .ps1; the modules\ directory contains Module files as .psm1. We pick
# up everything from both roots; per-file classification (Route vs API vs
# Module) comes from Object_Registry at processing time, not from path or
# extension.
$PsScanRoots = @(
    @{ Path = "$CcRoot\scripts\routes";  Pattern = '*.ps1'  }
    @{ Path = "$CcRoot\scripts\modules"; Pattern = '*.psm1' }
)

# Closed event set per CC_HTML_Spec.md Section 6.4. Used to validate the
# event name on data-action-<event> attributes (Section 6.5.3). Inline on*
# attributes are forbidden entirely, regardless of event name.
$RecognizedEvents = @('click','change','input','submit','blur','focus','keydown','keyup')

# Shared CSS / JS files. Used by USAGE-side resolvers to assign SHARED
# scope when an HTML reference targets one of these filenames. Anything
# else is treated as LOCAL.
$SharedCssFiles = @('cc-shared.css')
$SharedJsFiles  = @('cc-shared.js','engine-events.js')

# HTML void elements (per HTML5). These elements cannot have content and
# therefore never produce a closing tag. Used by the walker's element-stack
# tracker (CC_HTML_Spec.md Section 8.2.2) to skip pushing void elements as
# parent context - any text appearing 'inside' them is structurally
# impossible, so a void element should never appear as the parent of an
# HTML_TEXT row.
$HtmlVoidElements = @(
    'area','base','br','col','embed','hr','img','input','link',
    'meta','param','source','track','wbr'
)

# ============================================================================
# SPEC CONSTANTS - DRIFT CODE DESCRIPTIONS
# ============================================================================

# Drift code -> human description mapping. Used by Add-DriftCode (helpers)
# to validate codes and to populate drift_text. Aligned with CC_HTML_Spec.md
# Section 15 and the spec amendments adopted at the end of this rewrite
# session (FORBIDDEN_INLINE_STYLE_ATTRIBUTE, OVERLAY_PANEL_NOT_CONTIGUOUS,
# page-error-banner codes, bootloader-era page shell codes).
#
# Organized by spec section number. Codes the spec defines but which are
# detected at query time (not at populator scan time) are still listed so
# the master-table validation passes cleanly when callers attempt to
# attach them.
$DriftDescriptions = [ordered]@{
    # ---- Section 15.1: Page shell codes (attached to HTML_FILE) ----
    'MALFORMED_DOCTYPE'                 = "The HTML document does not open with <!DOCTYPE html> on its own line in the canonical form."
    'MALFORMED_HTML_ROOT'               = "The root <html> element has attributes; attributes are not permitted on the root element."
    'MALFORMED_HEAD'                    = "The <head> element contains constructs other than <title> and <link> (e.g., inline <style>, <meta>, <script>)."
    'FORBIDDEN_HARDCODED_TITLE'         = "The <title> content is a hardcoded string instead of the `$browserTitle PowerShell variable substitution."
    'MISSING_BODY_SECTION_CLASS'        = "The <body> element does not declare a class=`"section-<sectionKey>`" attribute."
    'MISSING_DATA_PAGE'                 = "The <body> element does not declare a data-page=`"<slug>`" attribute required by the bootloader."
    'MISSING_DATA_PREFIX'               = "The <body> element does not declare a data-prefix=`"<prefix>`" attribute required by the bootloader."
    'MISSING_NAV_SUBSTITUTION'          = "The first content inside <body> is not the `$navHtml substitution."
    'MISSING_HEADER_BAR'                = "The page header bar is missing as the first content after `$navHtml."
    'FORBIDDEN_HARDCODED_PAGE_HEADER'   = "The page header content is hardcoded instead of the `$headerHtml PowerShell variable substitution."
    'MISSING_CONNECTION_BANNER'         = "The connection banner placeholder is missing."
    'FORBIDDEN_BANNER_CONTENT'          = "The connection banner placeholder contains content; it must be empty."
    'MISSING_PAGE_ERROR_BANNER'         = "The page-error-banner placeholder required by the bootloader is missing."
    'FORBIDDEN_PAGE_ERROR_BANNER_CONTENT' = "The page-error-banner placeholder contains content; it must be empty."
    'PAGE_ERROR_BANNER_ORDER_VIOLATION' = "The page-error-banner placeholder is not positioned per the page shell ordering rules."
    'MALFORMED_BODY_CLOSE'              = "Content appears between the shared script reference and </body>."

    # ---- Section 15.2: Page chrome codes ----
    'MALFORMED_HEADER_BAR_CONTAINER'    = "The header bar's outer container is not <div class=`"header-bar`">."
    'MALFORMED_HEADER_BAR_LEFT'         = "The first child of header-bar is not the unattributed <div> containing the `$headerHtml substitution."
    'MALFORMED_HEADER_BAR_RIGHT'        = "The second child of header-bar is not <div class=`"header-right`">."
    'MALFORMED_HEADER_RIGHT_CHILDREN'   = "The header-right element contains children other than refresh-info and optional engine-row."
    'MALFORMED_REFRESH_INFO_CONTAINER'  = "The refresh info block's outer container is not <div class=`"refresh-info`">."
    'MALFORMED_LIVE_INDICATOR'          = "The live indicator span is malformed; expected <span class=`"live-indicator`"></span> exactly."
    'MALFORMED_LIVE_STATUS_LINE'        = "The live status line deviates from the mandated 'Live | Updated:' form."
    'MALFORMED_REFRESH_BUTTON'          = "The page refresh button markup deviates from the mandated form (class, data-action-click, title, or entity reference)."
    'DUPLICATE_LAST_UPDATE_ID'          = "The last-update ID appears more than once on the page."
    'MALFORMED_ENGINE_ROW_CONTAINER'    = "The engine row's outer container is not <div class=`"engine-row`">."
    'MALFORMED_ENGINE_ROW_CHILDREN'     = "The engine row contains children other than engine cards."
    'ENGINE_CARD_ORDER_MISMATCH'        = "Engine cards are not in declaration order matching Orchestrator.ProcessRegistry.cc_sort_order."
    'MALFORMED_ENGINE_CARD'             = "An engine card's structure deviates from the mandated four-element block."
    'MALFORMED_ENGINE_CARD_ATTRIBUTES'  = "An engine card's attributes are malformed (class or ID)."
    'MALFORMED_ENGINE_LABEL'            = "An engine label span is malformed (class or text)."
    'MALFORMED_ENGINE_BAR'              = "An engine bar div is malformed (class or ID, or contains content)."
    'MALFORMED_ENGINE_COUNTDOWN'        = "An engine countdown span is malformed (class, ID, or content)."
    'MISSING_ENGINE_CARD_REGISTRATION'  = "An active scheduled process (run_mode = 1) has NULL values in cc_engine_slug, cc_engine_label, cc_page_route, or cc_sort_order."
    'ENGINE_SLUG_REGISTRY_MISMATCH'     = "The slug used in card IDs doesn't match Orchestrator.ProcessRegistry.cc_engine_slug for the corresponding process."
    'ENGINE_LABEL_REGISTRY_MISMATCH'    = "The label text in the engine label span doesn't match Orchestrator.ProcessRegistry.cc_engine_label."
    'ENGINE_CARD_PAGE_MISMATCH'         = "An engine card appears on a page whose route doesn't match Orchestrator.ProcessRegistry.cc_page_route."

    # ---- Section 15.3: Asset reference codes ----
    'MALFORMED_CSS_LINK'                = "A <link> element uses additional attributes beyond rel=`"stylesheet`" and href=`"...`", or has an incorrect form."
    'MALFORMED_PAGE_CSS_REFERENCE'      = "The page-specific CSS reference's href doesn't match /css/<page>.css form."
    'MALFORMED_SHARED_CSS_REFERENCE'    = "The shared CSS reference is not exactly <link rel=`"stylesheet`" href=`"/css/cc-shared.css`">."
    'CSS_REFERENCE_ORDER_VIOLATION'     = "The page-specific CSS reference does not appear before the shared reference."
    'UNEXPECTED_CSS_REFERENCE'          = "A page references more or fewer than two CSS files in <head>."
    'MISSING_SHARED_SCRIPT_TAG'         = "A page does not include the mandatory <script src=`"/js/cc-shared.js`"></script> tag immediately before </body>."
    'UNEXPECTED_SCRIPT_TAG'             = "A page contains <script> tags beyond the single mandatory shared bootloader reference."
    'WRONG_SCRIPT_SOURCE'               = "A <script> element's src attribute is not exactly `"/js/cc-shared.js`"."
    'MALFORMED_JS_SCRIPT'               = "A <script> element uses additional attributes (e.g., defer, async) or has body content."
    'FORBIDDEN_HELPER_ASSET_REFERENCE'  = "A helper module function emits a <link> or <script> element."

    # ---- Section 15.4: ID codes ----
    'CHROME_ID_REUSED_AS_LOCAL'         = "A page-local element is assigned a chrome ID (e.g., id=`"last-update`" on a non-chrome element)."
    'MISSING_PREFIX_ID'                 = "A page-local ID does not begin with the page's cc_prefix followed by a hyphen."
    'CROSS_PAGE_PREFIX_COLLISION'       = "A page-local ID begins with another page's prefix."
    'DUPLICATE_ID_DECLARATION'          = "The same ID value is declared more than once on a page."
    'MALFORMED_ID_VALUE'                = "An ID value contains characters other than lowercase letters, digits, and hyphens."
    'MALFORMED_SLIDEOUT_ID'             = "A slideout overlay or panel ID does not follow <prefix>-slideout-<purpose>-* form."
    'MALFORMED_MODAL_ID'                = "A modal overlay or dialog ID does not follow <prefix>-modal-<purpose>-* form."
    'MALFORMED_SLIDEUP_ID'              = "A slide-up panel backdrop or panel ID does not follow <prefix>-slideup-<purpose>-* form."
    'INCOMPLETE_OVERLAY_PAIR'           = "A slideout, modal, or slide-up panel declares one half of the overlay/panel pair without the other."
    'MISSING_PANEL_PURPOSE_COMMENT'     = "A slideout, modal, or slide-up panel declaration is not preceded by an HTML purpose comment."
    'OVERLAY_PANEL_NOT_CONTIGUOUS'      = "Slideout, modal, and slide-up panel declarations are interleaved with non-overlay content; they must form one contiguous block."
    'FORBIDDEN_HELPER_PAGE_PREFIX_ID'   = "A helper module function emits HTML with a page-prefixed ID."

    # ---- Section 15.5: Class attribute codes ----
    'MALFORMED_CLASS_VALUE_WHITESPACE'  = "A class attribute value contains multiple consecutive spaces, leading/trailing whitespace, or tabs."
    'MALFORMED_CLASS_NAME'              = "A class name contains characters other than lowercase letters, digits, and hyphens."
    'DUPLICATE_CLASS_IN_VALUE'          = "The same class name appears more than once in the same class attribute."
    'CLASS_PREFIX_MISMATCH'             = "A class name doesn't begin with the page's cc_prefix and is not defined in cc-shared.css."
    'INLINE_CLASS_CONCATENATION'        = "A class attribute uses inline interpolation appended to static text (e.g., class=`"nav-link`$accent`")."
    'INLINE_CLASS_PREFIX_MIX'           = "A class attribute uses inline interpolation followed or preceded by static text (e.g., class=`"`$type wide`")."
    'INLINE_CLASS_MULTI_INTERPOLATION'  = "A class attribute uses multiple top-level interpolations without using the array-join pattern."
    'INLINE_CLASS_BRACED_INTERPOLATION' = "A class attribute uses PowerShell `${...} or `$(...) form mixed with static text."

    # ---- Section 15.6: Action attribute (data-action-*) codes ----
    'UNKNOWN_EVENT_TYPE'                = "A data-action-<event> attribute names an event not in the recognized set (click, change, input, submit, blur, focus, keydown, keyup)."
    'MALFORMED_ACTION_VALUE'            = "A data-action-* attribute value contains characters other than lowercase letters, digits, and hyphens."
    'UNRESOLVED_DATA_ACTION'            = "A data-action-* attribute's value does not match any registered dispatch entry (resolved at query time via cross-population JS_DISPATCH_ENTRY lookup)."
    'ORPHANED_ACTION_ARGUMENT'          = "A data-action-<arg-name> attribute appears on an element that has no data-action-<event> attribute."
    'ARGUMENT_NAME_COLLIDES_WITH_EVENT' = "An argument attribute's name matches an event name from the recognized event set, creating ambiguity between argument and event-type attributes."
    'MALFORMED_ACTION_ARGUMENT_NAME'    = "An argument attribute name contains characters other than lowercase letters, digits, and hyphens after the data-action- prefix."
    'FORBIDDEN_INLINE_ACTION_ARGUMENT_INTERPOLATION' = "An argument attribute value mixes static text with PowerShell interpolation."
    'FORBIDDEN_HELPER_PAGE_ACTION'      = "A helper module function emits a page-local (non-cc- prefixed) action value."
    'FORBIDDEN_HELPER_PAGE_ACTION_ARGUMENT' = "A helper module function emits an argument attribute whose interpolated value references state outside the helper's parameters and foreach iterators (e.g., script-scope variables, module-level state)."

    # ---- Section 15.7: data-* attribute codes ----
    'MALFORMED_DATA_ATTRIBUTE_NAME'     = "A data-* attribute name contains characters other than lowercase letters, digits, and hyphens after the data- prefix."
    'FORBIDDEN_INLINE_DATA_INTERPOLATION' = "A data-* attribute value mixes static text with PowerShell interpolation."
    'FORBIDDEN_HELPER_PAGE_DATA_ATTRIBUTE' = "A helper module function emits a data-* attribute that is page-specific."

    # ---- Section 15.8: Text content codes ----
    'MALFORMED_TEXT_INTERPOLATION'      = "Text content contains PowerShell variable interpolation that uses forbidden patterns from class attribute rules."
    'EMPTY_DISPLAY_TEXT'                = "A user-facing attribute (title, placeholder, aria-label, alt) is declared with an empty value."

    # ---- Section 15.9: SVG codes ----
    'MALFORMED_SVG_INTERPOLATION'       = "An SVG element's outer markup contains forbidden interpolation patterns."

    # ---- Section 15.10: Comment codes ----
    'MALFORMED_COMMENT_DASHES'          = "An HTML comment body contains '--' other than the closing -->."
    'FORBIDDEN_COMMENT_INTERPOLATION'   = "An HTML comment contains PowerShell variable interpolation."
    'MALFORMED_COMMENT_UNCLOSED'        = "An HTML comment's opening <!-- does not have a matching closing -->."

    # ---- Section 15.11: Inline asset block codes ----
    'FORBIDDEN_INLINE_STYLE_BLOCK'      = "A <style> block appears in HTML markup. Inline style blocks are forbidden; all styling lives in CSS files."
    'FORBIDDEN_INLINE_SCRIPT_BLOCK'     = "A <script> element contains body content (i.e., is not the asset reference form <script src=`"...`"></script>)."
    'FORBIDDEN_INLINE_STYLE_ATTRIBUTE'  = "An element carries an inline style=`"...`" attribute. Inline style attributes are forbidden; all styling lives in CSS files."

    # ---- Section 15.13: Inline event handler codes (umbrella + shapes) ----
    'FORBIDDEN_INLINE_EVENT_HANDLER'    = "An element carries an inline on* event handler attribute. Inline event handlers are forbidden; use data-action-<event> attributes routed through the bootloader dispatch table."
    'MULTIPLE_HANDLER_STATEMENTS'       = "An event handler attribute contains multiple statements (e.g., onclick=`"doA(); doB()`")."
    'INLINE_HANDLER_EXPRESSION'         = "An event handler attribute contains expressions other than a single function call."
    'MALFORMED_HANDLER_CALL'            = "An event handler's function call has whitespace between the function name and the opening parenthesis."
    'TRAILING_HANDLER_SEMICOLON'        = "An event handler attribute ends with a trailing semicolon."
    'FORBIDDEN_REVEALING_MODULE_CALL'   = "An event handler calls a function via dotted property access (e.g., Module.func())."
    'FORBIDDEN_BUILTIN_METHOD_CALL'     = "An event handler calls a method on a built-in object (e.g., window.location.href = ...)."
    'HANDLER_FUNCTION_NAME_MISMATCH'    = "An event handler's function name is not registered as chrome and does not match the page's prefix."
    'FORBIDDEN_EVENT_METHOD_CALL'       = "An event handler calls a method on the event object (e.g., event.stopPropagation())."
    'FORBIDDEN_HANDLER_CONDITIONAL'     = "An event handler contains conditional logic (e.g., if (event.key === 'Enter') ...)."
    'FORBIDDEN_INLINE_DOM_OPERATION'    = "An event handler performs DOM manipulation inline (e.g., this.classList.toggle(...))."
    'FORBIDDEN_INLINE_ASSIGNMENT'       = "An event handler contains assignment expressions (e.g., this.value = ...)."
    'FORBIDDEN_JAVASCRIPT_PROTOCOL'     = "An event handler uses the javascript: pseudo-protocol."
    'FORBIDDEN_ARGUMENT_EXPRESSION'     = "An event handler argument is an expression other than a literal, this, or this.<property>."
    'MALFORMED_ARGUMENT_QUOTING'        = "A string literal argument uses double quotes (which conflict with the surrounding attribute value's quoting)."
    'MALFORMED_ARGUMENT_LIST'           = "Multiple arguments are not separated by ', ' (comma followed by single space)."
    'FORBIDDEN_HELPER_PAGE_FUNCTION_CALL' = "A helper module function emits an event handler that calls a page-prefixed function."
}
# ============================================================================
# SCRIPT-SCOPE STATE
# ============================================================================

# Row collection and dedupe tracker. The helpers reference $script:dedupeKeys
# directly via Test-AddDedupeKey.
$script:rows       = New-Object System.Collections.Generic.List[object]
$script:dedupeKeys = New-Object 'System.Collections.Generic.HashSet[string]'

# Per-file HTML_FILE row references for cross-pass attachment of page-shell
# drift codes. Page-shell drift codes are file-level concerns (Section 15.1
# notes they attach to the HTML_FILE row, not to extracted construct rows).
$script:htmlFileRowByFile = @{}

# Per-file context used throughout the per-file walk.
$script:CurrentFile         = $null  # bare filename (e.g., 'BusinessServices.ps1')
$script:CurrentFullPath     = $null  # full path
$script:CurrentRegisteredType = $null # 'Route' | 'API' | 'Module' | $null
$script:CurrentCcPrefix     = $null  # cc_prefix for this file's component, or $null

# Cross-population resolution maps. Populated once at startup.
$script:cssClassSharedMap   = @{}
$script:cssClassLocalMap    = @{}
$script:cssFileMap          = @{}
$script:jsFileMap           = @{}

# Per-file classification and cc_prefix lookup maps. Populated once at
# startup from Object_Registry and Component_Registry.
$script:objectTypeByFile    = @{}
$script:ccPrefixByFile      = @{}

# Orchestrator.ProcessRegistry rows for engine card validation. Loaded
# once at startup; the per-file walk queries this list when an engine
# card is encountered.
$script:processRegistryRows = @()

# Per-page known prefixes from Component_Registry, used for cross-page
# prefix collision detection on IDs (Section 4.4).
$script:knownPagePrefixes   = New-Object 'System.Collections.Generic.HashSet[string]'

# ============================================================================
# POWERSHELL AST PARSING
# ============================================================================

# Parse a PowerShell file via the built-in Parser. Returns an object with:
#   .Ast        - System.Management.Automation.Language.ScriptBlockAst
#   .Tokens     - array of System.Management.Automation.Language.Token
#   .ParseErrors- array of ParseError objects (empty when file parses cleanly)
#   .Source     - the raw file contents as a string
#   .LineCount  - total source lines (used for HTML_FILE row's line_end)
#
# Returns $null only on outright file-read failures. Parse errors are NOT
# fatal: the AST is still returned even when errors are present.
function Invoke-PsParse {
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

# ============================================================================
# POWERSHELL AST: CONTEXT HELPERS
# ============================================================================

# Look up the enclosing function name for an AST node by walking its parent
# chain. The PS AST exposes .Parent on every node; we walk upward until we
# hit a FunctionDefinitionAst (regular function), or until we hit a
# ScriptBlockExpressionAst that is the -ScriptBlock argument to Add-PodeRoute
# (route handler), or until we reach the top of the tree.
#
# Returns one of:
#   - 'Get-NavBarHtml' (or any other function name) - inside a function
#   - '<route:/business-services>' (or the route path) - inside Add-PodeRoute
#   - $null - at file scope, outside any function or route
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

# Return the set of variable names (without leading $) that represent
# "caller-given data" inside the supplied function definition AST. Per
# CC_HTML_Spec.md Section 6.6, this set is exactly:
#   - parameter names declared on the function (via param() or attribute)
#   - foreach iterator names declared anywhere within the function's body
#
# Both forms expose data the caller provided: parameters directly, foreach
# iterators as elements of (presumably) a parameter-rooted collection. The
# populator can't trace iterator sources statically, but the structural
# rule treats any foreach iterator declared inside the helper as caller-
# given because that's the contract a well-formed helper enforces.
#
# Returns a HashSet[string] of variable names (case-insensitive). An empty
# set means no parameters and no foreach iterators were found.
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

# Return the bare command name from a CommandAst.
function Get-CommandAstName {
    param([Parameter(Mandatory)][System.Management.Automation.Language.CommandAst]$CommandAst)
    if ($CommandAst.CommandElements.Count -lt 1) { return $null }
    $first = $CommandAst.CommandElements[0]
    if ($first -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
        return $first.Value
    }
    return $first.Extent.Text
}

# Extract the literal string value from a StringConstantExpressionAst or
# ExpandableStringExpressionAst. Returns $null for other expression kinds.
function Get-StringValueFromExpression {
    param($Expr)
    if ($null -eq $Expr) { return $null }
    if ($Expr -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
        return $Expr.Value
    }
    if ($Expr -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
        return $Expr.Value
    }
    return $null
}
# ============================================================================
# POWERSHELL AST: HTML EMISSION DISCOVERY
# ============================================================================

# Three PS patterns emit HTML in the CC codebase:
#
#   1. Here-strings: a single (often very large) here-string assigned to a
#      variable, typically inside a route ScriptBlock. The HTML lives
#      verbatim between the @"..."@ delimiters with PowerShell variable
#      interpolation woven in.
#
#   2. StringBuilder append chains: a helper function instantiates a
#      System.Text.StringBuilder, then calls .AppendLine(...) or .Append(...)
#      repeatedly to build up the HTML piece by piece.
#
#   3. Plain string-literal returns: a helper function returns a string
#      literal containing HTML (e.g., Get-PageScriptTagHtml returns
#      '<script src="/js/cc-shared.js"></script>'). The literal is a
#      regular quoted string, not a here-string, and not built via
#      StringBuilder. Detection: any StringConstantExpressionAst /
#      ExpandableStringExpressionAst whose content passes the HTML sniff,
#      provided it does NOT also qualify as a here-string emission
#      (avoid double-counting).
#
# All three patterns produce a logical "HTML emission" object with:
#   .Text         - the concatenated HTML markup
#   .StartLine    - source line where the emission begins
#   .EndLine      - source line where it ends
#   .FunctionName - enclosing PS function name, or '<route:/path>' for
#                   route ScriptBlocks, or $null for top-level emissions
#   .Pattern      - 'HereString' | 'StringBuilder' | 'StringLiteral'
#   .NodeRef      - the AST node (for diagnostics)

# Content check: does this string look like an HTML emission?
#
# Structural detection: short-circuit on strong HTML-only signals
# (DOCTYPE, <html>, HTML comments, class=, id=) and fall back to a
# structural test for any tag with a matching open/close pair. SQL LIKE
# patterns containing XML-like tokens are rejected because they have no
# matching closer.
#
# XML payloads led by '<?xml' are explicitly rejected. They get cataloged
# by the PS populator as PS_FUNCTION DEFINITION rows for the emitting
# function; the HTML populator's job is HTML markup specifically.
function Test-LooksLikeHtmlEmission {
    param([string]$Text)
    if ($null -eq $Text) { return $false }
    if ($Text.Length -lt 16) { return $false }

    # Explicit rejection: XML payloads (declaration-led). XML emissions
    # belong to the PS populator's catalog of helper functions; the HTML
    # populator does not catalog XML markup. This is an intentional
    # scope boundary, not a silent skip.
    if ($Text -match '^\s*<\?xml\b') { return $false }

    # Strong signals - any one is sufficient.
    if ($Text -match '(?i)<!DOCTYPE\s+html')   { return $true }
    if ($Text -match '(?i)<html\b')            { return $true }
    if ($Text -match '(?im)^\s*<!--')          { return $true }
    if ($Text -match '\bclass\s*=\s*["'']')    { return $true }
    if ($Text -match '\bid\s*=\s*["''][a-z]')  { return $true }
    # The shared script tag and the access-denied page's style block are
    # both legitimate HTML emissions even though they may be short. The
    # structural pair check below catches them.

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

# Walk the AST and collect StringBuilder-style HTML emissions.
#
# Pattern:
#   $sb = [System.Text.StringBuilder]::new()
#   [void]$sb.AppendLine("...")
#   ...
#   return $sb.ToString()
#
# Detection: find every InvokeMemberExpressionAst whose member name is
# AppendLine/Append/AppendFormat and whose Expression is a
# VariableExpressionAst. Group by (enclosing function, variable name).
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

# Walk the AST and collect plain string-literal HTML emissions.
#
# Pattern: a function whose body's return value (or last statement) is a
# regular quoted string literal (single or double quoted, NOT a here-
# string) whose content passes the HTML sniff. Example from xFACts-Helpers.psm1:
#
#   function Get-PageScriptTagHtml {
#       return '<script src="/js/cc-shared.js"></script>'
#   }
#
# Detection: find every StringConstantExpressionAst /
# ExpandableStringExpressionAst with StringConstantType in
# (SingleQuoted, DoubleQuoted, BareWord) - the non-here-string forms.
# Filter to those whose enclosing context is a named function (not a
# route ScriptBlock; route emissions are always here-strings) and whose
# content qualifies as HTML.
#
# Why this matters: without this pattern, Get-PageScriptTagHtml is invisible
# to the catalog, which means the single JS_FILE USAGE row for the shared
# bootloader doesn't get emitted. Helper-emitted HTML is a SHARED-scope
# concern and must show up.
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
        #
        # The check: walk up the parent chain to find a FunctionDefinitionAst.
        # If we hit a ScriptBlockExpressionAst that's an Add-PodeRoute body
        # before finding a function, this is a route-scoped fragment and
        # should be skipped.
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

# ============================================================================
# POWERSHELL AST: ROUTE DISCOVERY
# ============================================================================

# Find every Add-PodeRoute call in a file and return a list of:
#   .Path       - the -Path parameter's literal string value
#   .Method     - the -Method parameter's value (Get default)
#   .ScriptBlock - the ScriptBlockExpressionAst for the handler body
#   .StartLine  - source line of the Add-PodeRoute call
function Get-PodeRoutes {
    param([Parameter(Mandatory)]$Ast)

    $routes = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Ast) { return $routes }

    $allCommands = $Ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.CommandAst]
    }, $true)

    foreach ($cmd in $allCommands) {
        $cmdName = Get-CommandAstName -CommandAst $cmd
        if ($cmdName -ne 'Add-PodeRoute') { continue }

        $path        = $null
        $method      = 'Get'
        $scriptBlock = $null

        $elements = $cmd.CommandElements
        for ($i = 0; $i -lt $elements.Count; $i++) {
            $el = $elements[$i]
            if ($el -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
            $valueExpr = if ($null -ne $el.Argument) {
                $el.Argument
            } elseif ($i + 1 -lt $elements.Count) {
                $elements[$i + 1]
            } else {
                $null
            }
            switch ($el.ParameterName.ToLower()) {
                'path' {
                    $path = Get-StringValueFromExpression -Expr $valueExpr
                }
                'method' {
                    $methodVal = Get-StringValueFromExpression -Expr $valueExpr
                    if (-not [string]::IsNullOrEmpty($methodVal)) { $method = $methodVal }
                }
                'scriptblock' {
                    if ($valueExpr -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
                        $scriptBlock = $valueExpr
                    }
                }
            }
        }

        if ([string]::IsNullOrEmpty($path)) { continue }

        $routes.Add([ordered]@{
            Path        = $path
            Method      = $method
            ScriptBlock = $scriptBlock
            StartLine   = if ($cmd.Extent) { $cmd.Extent.StartLineNumber } else { 0 }
        })
    }

    return $routes
}
# ============================================================================
# HTML TOKENIZER
# ============================================================================
#
# The tokenizer treats PowerShell interpolation as a first-class concept.
# Each $var, ${name}, and $(expr) becomes a separate token of kind
# 'PsInterp' carrying its raw form verbatim. The tokenizer does NOT
# evaluate them: it preserves them so downstream consumers can detect
# specific substitutions like $navHtml or $headerHtml by exact match.
#
# Token kinds produced:
#   Doctype     - <!DOCTYPE html> (any case)
#   StartTag    - <tagname attr=value ...>
#   EndTag      - </tagname>
#   SelfClose   - <tagname attr=value ... />
#   Comment     - <!-- ... -->
#   Text        - run of character data outside any tag
#   PsInterp    - PowerShell interpolation appearing in character data
#                 (interpolations inside attribute values stay inside
#                 the StartTag's .AttrText string for parsing later)
#   Entity      - HTML entity reference (named &nbsp;, numeric &#9881; or
#                 hex &#x2716;)
#
# Tokens carry source-relative position info:
#   .LineOffset  - 0-based line offset from the emission's first line
#   .ColumnStart - 1-based column on that line
#
# StartTag and SelfClose tokens carry .AttrText (the verbatim attribute
# region of the tag, used for later attribute parsing).

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

        # ---- HTML comment: <!-- ... --> ----
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

        # ---- DOCTYPE: <!DOCTYPE html> (case-insensitive sniff) ----
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

        # ---- Closing tag: </name> ----
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

        # ---- Opening tag / self-close: <name attrs...> or <name attrs.../> ----
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

        # ---- HTML entity: &name; &#N; &#xN; ----
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

        # ---- PowerShell interpolation: $var, ${name}, $(...) ----
        # If a $-led interpolation cannot be parsed (no matching closer),
        # the $ is consumed as a single literal text character below.
        # Otherwise the text accumulator's $-detection would break out of
        # text mode on the same character and we'd hit an infinite loop
        # at the outer while.
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

        # ---- Text: anything else, accumulated until next special character ----
        # CRITICAL: the outer while loop reaches here ONLY when none of the
        # specialized branches (Comment / Doctype / EndTag / StartTag / Entity /
        # PsInterp / unparseable-$) matched. If $ch is a special char we
        # failed to parse (e.g., '<' followed by non-letter, or '&' that
        # didn't form a valid entity), we must consume it as plain text or
        # we infinite-loop.
        #
        # Strategy: always consume the first character. Then break only on
        # SUBSEQUENT special characters. This guarantees the outer loop
        # advances by at least one character every iteration.
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
# ============================================================================
# ATTRIBUTE PARSER
# ============================================================================
#
# The tokenizer captures each StartTag/SelfClose token's attribute region
# as a single verbatim string in $token.AttrText. This parser breaks that
# string into structured attribute records so row emitters can address
# individual attributes by name.
#
# Each attribute record has:
#   .Name        - lowercased attribute name (e.g., 'class', 'data-spid')
#   .Value       - value with surrounding quotes stripped (preserves empty)
#   .Quote       - quote char used in source ('"', "'", or null if unquoted)
#   .HasInterp   - true when the value contains PowerShell interpolation
#   .HasPureInterp - true when the value is *only* PS interpolation (e.g.,
#                    id="$someId" with no static letters/digits/hyphens)
#   .RawValue    - verbatim value including surrounding quotes
#
# The parser walks character by character because PowerShell's regex
# engine can't reliably handle attribute values that mix quoted strings
# with PS interpolation containing nested parens.

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

        $i++  # skip '='
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

# ============================================================================
# CLASS-NAME SPLITTING AND VALIDATION
# ============================================================================
#
# Per CC_HTML_Spec.md Section 5.1, a class attribute value contains zero
# or more class names separated by single spaces. Each name maps to one
# CSS_CLASS USAGE row.
#
# Dynamic class values per Section 5.2 use PowerShell interpolation. The
# spec mandates the "array-join" pattern (a single $cssClasses substitution
# that holds the runtime-built class list). The populator drops the
# interpolation tokens before splitting so static class names survive
# extraction.

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

# Validate a class attribute value's interpolation shape per spec Section 5.2.
# Returns an array of drift codes to attach to each CSS_CLASS USAGE row
# emitted from this attribute. The codes are descriptive of the malformation:
#
#   INLINE_CLASS_CONCATENATION   - static text immediately adjacent to $var
#                                  (no whitespace between them)
#   INLINE_CLASS_PREFIX_MIX      - PS interpolation followed/preceded by
#                                  static class name with whitespace
#   INLINE_CLASS_MULTI_INTERPOLATION - multiple top-level interpolations
#                                      (should use array-join)
#   INLINE_CLASS_BRACED_INTERPOLATION - ${...} or $(...) used as part of
#                                       a mixed value
#   MALFORMED_CLASS_VALUE_WHITESPACE - multiple spaces, leading/trailing
#                                      whitespace, tabs
#   DUPLICATE_CLASS_IN_VALUE     - same class name appears twice in value
#   MALFORMED_CLASS_NAME         - class name has chars other than
#                                  lowercase letters, digits, hyphens
function Get-ClassValueDriftCodes {
    param([string]$Value)
    $codes = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrEmpty($Value)) { return @($codes.ToArray()) }

    # Whitespace checks
    if ($Value -match '\t')                      { [void]$codes.Add('MALFORMED_CLASS_VALUE_WHITESPACE') }
    if ($Value -match '^\s' -or $Value -match '\s$') { [void]$codes.Add('MALFORMED_CLASS_VALUE_WHITESPACE') }
    if ($Value -match '\s\s')                    { [void]$codes.Add('MALFORMED_CLASS_VALUE_WHITESPACE') }

    # Interpolation analysis
    $interpMatches = @([regex]::Matches($Value, '(\$\([^)]*\))|(\$\{[^}]*\})|(\$[A-Za-z_][A-Za-z0-9_]*)'))
    $hasInterp = $interpMatches.Count -gt 0

    if ($hasInterp) {
        # Inline concatenation: static text right before/after the interpolation
        # with no whitespace separating them (e.g., class="nav-link$accent").
        if ($Value -match '[A-Za-z0-9\-]\$[A-Za-z_({]') { [void]$codes.Add('INLINE_CLASS_CONCATENATION') }
        if ($Value -match '\)[A-Za-z0-9\-]' -or $Value -match '\}[A-Za-z0-9\-]') {
            [void]$codes.Add('INLINE_CLASS_CONCATENATION')
        }

        # Mixed static-and-dynamic with whitespace boundary (still drift, but a
        # different shape): "$type wide" or "nav-link $color".
        $stripped = $Value
        $stripped = [regex]::Replace($stripped, '\$\([^)]*\)', '')
        $stripped = [regex]::Replace($stripped, '\$\{[^}]*\}', '')
        $stripped = [regex]::Replace($stripped, '\$[A-Za-z_][A-Za-z0-9_]*', '')
        $strippedTokens = @($stripped -split '\s+' | Where-Object { $_ -and $_ -ne '' })
        if ($strippedTokens.Count -gt 0 -and -not $codes.Contains('INLINE_CLASS_CONCATENATION')) {
            # Static tokens coexist with interpolation -> prefix mix
            [void]$codes.Add('INLINE_CLASS_PREFIX_MIX')
        }

        # Multiple top-level interpolations
        if ($interpMatches.Count -gt 1) { [void]$codes.Add('INLINE_CLASS_MULTI_INTERPOLATION') }

        # Braced or paren forms mixed with static text
        foreach ($m in $interpMatches) {
            $raw = $m.Value
            if (($raw.StartsWith('${') -or $raw.StartsWith('$(')) -and $strippedTokens.Count -gt 0) {
                [void]$codes.Add('INLINE_CLASS_BRACED_INTERPOLATION')
                break
            }
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

# ============================================================================
# ID VALIDATION
# ============================================================================
#
# Per CC_HTML_Spec.md Section 4, IDs are either:
#   - Chrome IDs: a small fixed set (last-update, connection-banner,
#     page-error-banner, card-engine-<slug>, engine-bar-<slug>,
#     engine-cd-<slug>). These have known names and may appear on multiple
#     pages.
#   - Page-local IDs: must start with the page's cc_prefix followed by '-'.
#
# Chrome ID set is fixed at the spec level. Engine card IDs have variable
# slugs but match the prefixes 'card-engine-', 'engine-bar-', 'engine-cd-'.

$ChromeIdLiterals = @('last-update','connection-banner','page-error-banner')
$ChromeIdPrefixes = @('card-engine-','engine-bar-','engine-cd-')

# Test whether an ID value is a chrome ID per the spec.
function Test-IsChromeId {
    param([string]$IdValue)
    if ([string]::IsNullOrEmpty($IdValue)) { return $false }
    if ($ChromeIdLiterals -contains $IdValue) { return $true }
    foreach ($p in $ChromeIdPrefixes) {
        if ($IdValue.StartsWith($p)) { return $true }
    }
    return $false
}

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

    $isChrome = Test-IsChromeId -IdValue $IdValue

    if ($isChrome) {
        # Chrome IDs are fine as-is. No prefix check applies.
    } else {
        if ($IsHelperEmission) {
            # Helper module functions emit SHARED HTML. If they produce a
            # page-prefixed ID, that couples shared code to a page.
            if (-not [string]::IsNullOrEmpty($PagePrefix) -and $IdValue.StartsWith("$PagePrefix-")) {
                [void]$codes.Add('FORBIDDEN_HELPER_PAGE_PREFIX_ID')
            }
            # Helper IDs that aren't chrome and don't have a prefix at all
            # are tolerated here; the helper is shared code and may emit
            # bare IDs intentionally.
        } else {
            # Page-local emission: must start with the page's cc_prefix + '-'.
            if ([string]::IsNullOrEmpty($PagePrefix)) {
                # No prefix on file - flag if id doesn't look chrome-like.
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
    }

    return @($codes.ToArray())
}

# ============================================================================
# OVERLAY PANEL DETECTION (slideout / modal / slideup)
# ============================================================================
#
# Per CC_HTML_Spec.md Section 4.3, slideouts/modals/slideups have ID forms:
#   <prefix>-slideout-<purpose>-overlay   pair: <prefix>-slideout-<purpose>
#   <prefix>-modal-<purpose>-overlay      pair: <prefix>-modal-<purpose>-dialog
#   <prefix>-slideup-<purpose>-backdrop   pair: <prefix>-slideup-<purpose>-panel
#
# This function classifies an ID into:
#   .OverlayKind  - 'slideout' | 'modal' | 'slideup' | $null
#   .OverlayRole  - 'overlay' | 'panel' | 'backdrop' | 'dialog' | $null
#   .OverlayKey   - normalized pair key (e.g., '<prefix>-slideout-<purpose>')
#                   used to match overlay halves
#   .DriftCode    - MALFORMED_SLIDEOUT_ID / MALFORMED_MODAL_ID /
#                   MALFORMED_SLIDEUP_ID if the ID looks like one of these
#                   but doesn't fit the pattern

function Get-OverlayIdInfo {
    param([Parameter(Mandatory)][string]$IdValue)

    $info = [ordered]@{
        OverlayKind = $null
        OverlayRole = $null
        OverlayKey  = $null
        DriftCode   = $null
    }

    if ([string]::IsNullOrEmpty($IdValue)) { return $info }

    # Slideout: <prefix>-slideout-<purpose> or <prefix>-slideout-<purpose>-overlay
    if ($IdValue -match '^([a-z]{2,4})-slideout-(.+)$') {
        $info.OverlayKind = 'slideout'
        $remainder = $matches[2]
        if ($remainder -match '^(.+)-overlay$') {
            $info.OverlayRole = 'overlay'
            $info.OverlayKey  = "$($matches[1])-slideout-$($matches[1])"
            # Need to rebuild key with the prefix portion
            $prefix = $IdValue.Substring(0, $IdValue.IndexOf('-slideout-'))
            $purpose = $matches[1]
            $info.OverlayKey = "$prefix-slideout-$purpose"
        } else {
            # The non-overlay half (the panel itself)
            $info.OverlayRole = 'panel'
            $prefix = $IdValue.Substring(0, $IdValue.IndexOf('-slideout-'))
            $info.OverlayKey = "$prefix-slideout-$remainder"
        }
        # Validate slug shape - purpose must be lowercase hyphens
        if ($remainder -notmatch '^[a-z][a-z0-9\-]*$') {
            $info.DriftCode = 'MALFORMED_SLIDEOUT_ID'
        }
        return $info
    }

    # Modal: <prefix>-modal-<purpose>-overlay or <prefix>-modal-<purpose>-dialog
    if ($IdValue -match '^([a-z]{2,4})-modal-(.+)$') {
        $info.OverlayKind = 'modal'
        $remainder = $matches[2]
        $prefix = $IdValue.Substring(0, $IdValue.IndexOf('-modal-'))
        if ($remainder -match '^(.+)-overlay$') {
            $info.OverlayRole = 'overlay'
            $info.OverlayKey = "$prefix-modal-$($matches[1])"
        } elseif ($remainder -match '^(.+)-dialog$') {
            $info.OverlayRole = 'dialog'
            $info.OverlayKey = "$prefix-modal-$($matches[1])"
        } else {
            $info.DriftCode = 'MALFORMED_MODAL_ID'
            $info.OverlayKey = "$prefix-modal-$remainder"
            $info.OverlayRole = 'unknown'
        }
        if ($remainder -notmatch '^[a-z][a-z0-9\-]*$') {
            $info.DriftCode = 'MALFORMED_MODAL_ID'
        }
        return $info
    }

    # Slideup: <prefix>-slideup-<purpose>-backdrop or <prefix>-slideup-<purpose>-panel
    if ($IdValue -match '^([a-z]{2,4})-slideup-(.+)$') {
        $info.OverlayKind = 'slideup'
        $remainder = $matches[2]
        $prefix = $IdValue.Substring(0, $IdValue.IndexOf('-slideup-'))
        if ($remainder -match '^(.+)-backdrop$') {
            $info.OverlayRole = 'backdrop'
            $info.OverlayKey = "$prefix-slideup-$($matches[1])"
        } elseif ($remainder -match '^(.+)-panel$') {
            $info.OverlayRole = 'panel'
            $info.OverlayKey = "$prefix-slideup-$($matches[1])"
        } else {
            $info.DriftCode = 'MALFORMED_SLIDEUP_ID'
            $info.OverlayKey = "$prefix-slideup-$remainder"
            $info.OverlayRole = 'unknown'
        }
        if ($remainder -notmatch '^[a-z][a-z0-9\-]*$') {
            $info.DriftCode = 'MALFORMED_SLIDEUP_ID'
        }
        return $info
    }

    return $info
}
# ============================================================================
# EVENT HANDLER ANALYSIS
# ============================================================================
#
# Inline on* event handlers are forbidden per CC_HTML_Spec.md Section 6.
# The post-bootloader model uses data-action-<event>="<action-name>"
# attributes that the bootloader's dispatch table routes to JS functions.
#
# This populator emits TWO row types from event-related attributes:
#
#   1. HTML_EVENT_HANDLER DEFINITION row for every on* attribute, with
#      the FORBIDDEN_INLINE_EVENT_HANDLER umbrella drift code attached
#      plus any applicable shape-specific codes (multiple statements,
#      conditionals, DOM operations, etc.).
#
#   2. HTML_DATA_ATTRIBUTE DEFINITION row for every data-action-<event>
#      attribute, with variant_type = action name and variant_qualifier_1
#      = event name. The cross-spec dispatch resolution (matching the
#      action name to a JS_DISPATCH_ENTRY DEFINITION row) happens at
#      query time, not in the populator.

# Validate the shape of an event handler value. Returns drift code array.
# These are the per-shape codes from Section 15.13; they accompany the
# umbrella FORBIDDEN_INLINE_EVENT_HANDLER code.
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
            # Split naively on commas (handler args should be simple
            # literals or 'this' references; complex args would already
            # have fired FORBIDDEN_HANDLER_CONDITIONAL or similar).
            # Use $handlerArgs (not $args) because $args is a PowerShell
            # automatic variable holding the enclosing function's
            # unbound arguments; reassigning it has unpredictable
            # behavior depending on PS version.
            $handlerArgs = @($argList -split ',')
            if ($handlerArgs.Count -gt 1) {
                # Reconstruct expected form and compare
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
            # Helper code shouldn't know about page prefixes. If the called
            # function name matches a known page prefix, flag it.
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

# ============================================================================
# DATA-ACTION ATTRIBUTE VALIDATION
# ============================================================================
#
# Per CC_HTML_Spec.md Sections 6.2 and 6.3, data-action-* attributes fall
# into two structurally distinct families:
#
#   data-action-<event>="<action-name>"    (event attribute, Section 6.2)
#     - <event> is in the recognized set from Section 6.4
#     - Emits HTML_DATA_ATTRIBUTE DEFINITION with:
#         variant_type        = action name
#         variant_qualifier_1 = event name
#
#   data-action-<arg-name>="<value>"       (argument attribute, Section 6.3)
#     - <arg-name> is any kebab-case identifier that is NOT in Section 6.4
#     - Only valid when the same element also declares >=1 event attribute
#     - Emits HTML_DATA_ATTRIBUTE DEFINITION with:
#         variant_type        = value
#         variant_qualifier_1 = NULL
#
# Drift codes emitted here:
#   Event-attribute path:
#     UNKNOWN_EVENT_TYPE     - event name not in Section 6.4 set
#     MALFORMED_ACTION_VALUE - value contains chars outside [a-z0-9-]
#   Argument-attribute path:
#     ARGUMENT_NAME_COLLIDES_WITH_EVENT - arg name matches a Section 6.4 event
#     MALFORMED_ACTION_ARGUMENT_NAME    - arg name has chars outside [a-z0-9-]
#     FORBIDDEN_INLINE_ACTION_ARGUMENT_INTERPOLATION
#                                      - value mixes static text + $interp
#     ORPHANED_ACTION_ARGUMENT          - emitted in walker (needs element-
#                                         scope knowledge of other attrs)
#   Helper-emission path (both event and argument):
#     FORBIDDEN_HELPER_PAGE_ACTION
#                  - event-attr action value missing 'cc-' prefix
#     FORBIDDEN_HELPER_PAGE_ACTION_ARGUMENT
#                  - argument value interpolates a variable that is not
#                    a parameter of the enclosing helper function nor a
#                    foreach iterator declared in that function's body
#
# UNRESOLVED_DATA_ACTION fires at post-pipeline query time (cross-spec).

# Classify a data-action-* attribute by suffix:
#   'event'    - suffix is a single recognized event name (data-action-click)
#   'argument' - suffix is a multi-word or non-event kebab name (data-action-batch-id)
#   $null      - not a data-action-* attribute, or malformed beyond classification
function Get-DataActionAttributeKind {
    param([string]$AttrName)
    if ([string]::IsNullOrEmpty($AttrName)) { return $null }
    if ($AttrName -notmatch '^data-action-(.+)$') { return $null }
    $suffix = $matches[1]
    # A single-word suffix matching a recognized event is an event attribute.
    # Everything else (multi-word kebab, single word not in event set) is an
    # argument attribute. UNKNOWN_EVENT_TYPE fires later for single-word
    # suffixes that look event-shaped but are not in the recognized set.
    if ($suffix -match '^[a-z]+$' -and $RecognizedEvents -contains $suffix) {
        return 'event'
    }
    return 'argument'
}

# Legacy compatibility: returns $true for any data-action-* attribute.
function Test-IsDataActionAttribute {
    param([string]$AttrName)
    return $AttrName -match '^data-action-'
}

function Get-EventFromDataActionName {
    param([string]$AttrName)
    if ($AttrName -match '^data-action-([a-z]+)$') {
        return $matches[1]
    }
    return $null
}

# Suffix after 'data-action-' (the <arg-name> or <event> portion).
function Get-DataActionSuffix {
    param([string]$AttrName)
    if ($AttrName -match '^data-action-(.+)$') {
        return $matches[1]
    }
    return $null
}

# Event-attribute validation. Single-word suffixes that aren't in the
# recognized event set fire UNKNOWN_EVENT_TYPE. The action value is
# validated against the kebab-case pattern.
function Get-DataActionEventValidationCodes {
    param(
        [string]$AttrName,
        [string]$Value
    )
    $codes = New-Object System.Collections.Generic.List[string]

    $suffix = Get-DataActionSuffix -AttrName $AttrName
    # Only fire UNKNOWN_EVENT_TYPE for single-word suffixes (multi-word
    # suffixes are argument attributes and don't claim to be events).
    if ($null -ne $suffix -and $suffix -match '^[a-z]+$' -and $RecognizedEvents -notcontains $suffix) {
        [void]$codes.Add('UNKNOWN_EVENT_TYPE')
    }

    if (-not [string]::IsNullOrEmpty($Value)) {
        if ($Value -notmatch '^[a-z][a-z0-9\-]*$') {
            [void]$codes.Add('MALFORMED_ACTION_VALUE')
        }
    }

    return @($codes.ToArray())
}

# Argument-attribute validation. The suffix must be a well-formed kebab
# identifier and must not collide with any recognized event name. Value
# interpolation rules match the data-* family in Section 7.2.
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
        # Arg name must be kebab-case [a-z0-9-]+. A single-word suffix
        # that happens to match an event name is reported as a collision,
        # not as malformed. Multi-word kebab names that contain bad chars
        # fire MALFORMED_ACTION_ARGUMENT_NAME.
        if ($suffix -match '^[a-z]+$' -and $RecognizedEvents -contains $suffix) {
            [void]$codes.Add('ARGUMENT_NAME_COLLIDES_WITH_EVENT')
        } elseif ($suffix -notmatch '^[a-z][a-z0-9\-]*$') {
            [void]$codes.Add('MALFORMED_ACTION_ARGUMENT_NAME')
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

# Extract the root variable names referenced in an attribute value's
# PowerShell interpolations. "Root variable" means the leftmost variable
# in each interpolation expression; for $($section.id.ToString()) the
# root is 'section'. Function calls inside interpolations (e.g.,
# $(Get-Thing)) return no root - the value is treated as referencing
# unknown ambient state, which the helper-emission check flags.
#
# Returns a list of objects:
#   .Root       - root variable name (without leading $), or $null when
#                 the interpolation has no extractable root (function
#                 call, missing variable, etc.)
#   .IsScoped   - $true if the variable uses an explicit scope prefix
#                 (script:, global:, env:, etc.) which is never allowed
#                 inside helper-emitted argument attributes
#   .RawExpr    - the raw text between $( and ) or $ and end-of-name, for
#                 diagnostic context
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
            $info = Parse-RootVariableFromExpression -Expression $expr
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
            $info = Parse-RootVariableFromExpression -Expression $expr
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
            $info = Parse-RootVariableFromExpression -Expression $expr
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

# Parse a PowerShell expression (the content of an interpolation) and
# extract its root variable. Handles:
#   - bare variable:     foo            -> Root = 'foo',         IsScoped = false
#   - scoped variable:   script:foo     -> Root = 'script:foo',  IsScoped = true
#   - property access:   foo.Bar.Baz    -> Root = 'foo',         IsScoped = false
#   - method call:       foo.Bar()      -> Root = 'foo',         IsScoped = false
#   - function call:     Get-Thing      -> Root = $null          (no variable root)
#   - empty:                            -> Root = $null
function Parse-RootVariableFromExpression {
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
    # If the expression starts with a non-identifier character (e.g.,
    # a function call like 'Get-Thing' or arithmetic), Root stays null.
    if ($trimmed -notmatch '^([A-Za-z_][A-Za-z0-9_]*)(:([A-Za-z_][A-Za-z0-9_]*))?') {
        return $info
    }
    $first  = $matches[1]
    $second = if ($matches.Count -ge 4) { $matches[3] } else { $null }

    # PowerShell scope prefixes per get-help about_Scopes.
    $scopePrefixes = @('script','global','local','private','env','function','variable','using')
    if (-not [string]::IsNullOrEmpty($second) -and $scopePrefixes -contains $first.ToLower()) {
        $info.Root = "${first}:${second}"
        $info.IsScoped = $true
        return $info
    }

    # If 'first' looks like a verb-noun function name (contains a hyphen)
    # OR is followed by '(' for a function call without parens
    # (e.g., 'Get-Thing arg1 arg2'), treat as function call.
    # Actually for our purposes, just check if a hyphen appears in 'first'
    # which signals verb-noun: but bare variables can't contain hyphens
    # per PowerShell syntax (you need ${var-name} for that). So if we got
    # here from $name parsing, no hyphen possible. From $() the regex
    # already required [A-Za-z_][A-Za-z0-9_]* which excludes hyphens.
    # So any match here is a real variable name.

    $info.Root = $first
    return $info
}

# Derive the categorical component_name for an HTML_TEXT row per
# CC_HTML_Spec.md Section 8.2.2. Three emission contexts produce three
# categorical-name shapes:
#
#   1. Element body text     -> '<tag>-<first-class-token-after-prefix-strip>'
#                            -> '<tag>-text' if the element has no class
#   2. User-facing attribute -> 'attr-<attrname>' (title, placeholder,
#                               aria-label, alt)
#
# This function handles case 1. Case 2 is emitted directly at the attribute-
# scan call site without going through this function.
#
# Class token derivation rules:
#   - The parent element's first class token (space-separated) participates;
#     additional tokens are ignored
#   - If the first class token starts with '<page-prefix>-', strip that
#     prefix + hyphen before using it. Prefix stripping is hyphen-anchored
#     to avoid false matches: page-prefix 'bsv' strips 'bsv-section' to
#     'section' but does not strip 'bsvfoo-bar' (no hyphen immediately
#     after 'bsv')
#   - If the class value is empty/whitespace/missing entirely, return
#     '<tag>-text'
#
# Parameters:
#   -ParentTag    Name of the parent element (e.g., 'h2', 'div', 'button').
#                 Lowercased; if missing/empty, returns 'unknown-text'
#                 as a defensive fallback - this should never happen for a
#                 well-formed text node, but the catalog needs a value.
#   -ParentClass  Value of the parent's class attribute, or $null/empty
#                 if the parent has no class
#   -PagePrefix   The page's cc_prefix (e.g., 'bid', 'bsv') used for
#                 prefix-stripping, or $null/empty if no prefix is known
#                 (top-level emissions, helper emissions without a
#                 page context)
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

# ============================================================================
# ROW EMITTERS
# ============================================================================

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

# ---------------------------------------------------------------------------
# HTML_FILE anchor row
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# HTML_ID DEFINITION row
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# HTML_DATA_ATTRIBUTE DEFINITION row
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# HTML_EVENT_HANDLER DEFINITION row
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# HTML_TEXT DEFINITION row
# ---------------------------------------------------------------------------
# Per CC_HTML_Spec.md Section 8.2.2, text content and the four user-facing
# attributes (title, placeholder, aria-label, alt) emit HTML_TEXT rows.
#
# component_name carries a categorical label derived from emission context,
# not the literal text. Two shapes:
#   - Element body text:     '<tag>-<class-token-after-prefix-strip>'
#                            (or '<tag>-text' when the parent has no class)
#   - User-facing attribute: 'attr-<attrname>' (attr-title, attr-placeholder,
#                            attr-aria-label, attr-alt)
#
# The literal text content always goes in raw_text. The categorical name
# makes the catalog queryable by structural role
# (WHERE component_name = 'h2-section-title') while raw_text preserves the
# actual displayed string.
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

# ---------------------------------------------------------------------------
# HTML_ENTITY DEFINITION row
# ---------------------------------------------------------------------------
# Per CC_HTML_Spec.md Section 8.3.2, HTML entities catalog with:
#   component_name = the full literal entity reference (e.g., '&nbsp;',
#                    '&#9881;', '&#x2716;')
#   signature      = the spec form name: 'entity_named' or 'entity_numeric'
#                    (both decimal and hex numeric entities map to
#                    entity_numeric per spec language)
# variant_type is unused for HTML_ENTITY rows.
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

# ---------------------------------------------------------------------------
# HTML_SVG DEFINITION row
# ---------------------------------------------------------------------------
# Per spec Section 11, SVG markup is cataloged at the outer element level.
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

# ---------------------------------------------------------------------------
# HTML_COMMENT DEFINITION row
# ---------------------------------------------------------------------------
# Per CC_HTML_Spec.md Section 10.5.1, comments catalog into three kinds:
#   - comment-section-divider: a comment that introduces a structural block
#     (page header, content cards, overlay panels)
#   - comment-panel-purpose: a comment immediately preceding a slideout/
#     modal/slide-up declaration, describing what that panel does
#   - comment-inline: any other comment
# component_name = the kind. raw_text = the comment body.
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

# ---------------------------------------------------------------------------
# CSS_CLASS USAGE row (with cross-population resolution)
# ---------------------------------------------------------------------------
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

    $resolved = Resolve-CssClassScope -ClassName $ClassName

    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|CSS_CLASS|$ClassName|USAGE|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $row = New-HtmlRow `
        -ComponentType      'CSS_CLASS' `
        -ComponentName      $ClassName `
        -ReferenceType      'USAGE' `
        -Scope              $resolved.Scope `
        -SourceFile         $resolved.SourceFile `
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

# ---------------------------------------------------------------------------
# CSS_FILE USAGE row
# ---------------------------------------------------------------------------
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

    $resolved = Resolve-CssFileScope -Href $Href

    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|CSS_FILE|$Href|USAGE|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $row = New-HtmlRow `
        -ComponentType      'CSS_FILE' `
        -ComponentName      $Href `
        -ReferenceType      'USAGE' `
        -Scope              $resolved.Scope `
        -SourceFile         $resolved.SourceFile `
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

# ---------------------------------------------------------------------------
# JS_FILE USAGE row
# ---------------------------------------------------------------------------
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

    $resolved = Resolve-JsFileScope -Src $Src

    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|JS_FILE|$Src|USAGE|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $row = New-HtmlRow `
        -ComponentType      'JS_FILE' `
        -ComponentName      $Src `
        -ReferenceType      'USAGE' `
        -Scope              $resolved.Scope `
        -SourceFile         $resolved.SourceFile `
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

# ============================================================================
# CROSS-POPULATION SCOPE RESOLUTION
# ============================================================================

function Resolve-CssClassScope {
    param([string]$ClassName)

    if ([string]::IsNullOrWhiteSpace($ClassName)) {
        return @{ Scope = 'LOCAL'; SourceFile = '<undefined>' }
    }
    if ($script:cssClassSharedMap.ContainsKey($ClassName)) {
        return @{ Scope = 'SHARED'; SourceFile = $script:cssClassSharedMap[$ClassName] }
    }
    if ($script:cssClassLocalMap.ContainsKey($ClassName)) {
        return @{ Scope = 'LOCAL'; SourceFile = $script:cssClassLocalMap[$ClassName] }
    }
    return @{ Scope = 'LOCAL'; SourceFile = '<undefined>' }
}

function Resolve-CssFileScope {
    param([string]$Href)

    if ([string]::IsNullOrWhiteSpace($Href)) {
        return @{ Scope = 'LOCAL'; SourceFile = '<undefined>' }
    }
    $bare = [System.IO.Path]::GetFileName($Href)
    if ($script:cssFileMap.ContainsKey($bare)) {
        $scope = if ($SharedCssFiles -contains $bare) { 'SHARED' } else { 'LOCAL' }
        return @{ Scope = $scope; SourceFile = $script:cssFileMap[$bare] }
    }
    # Unknown CSS file - default to LOCAL scope and '<undefined>' source.
    $scope = if ($SharedCssFiles -contains $bare) { 'SHARED' } else { 'LOCAL' }
    return @{ Scope = $scope; SourceFile = '<undefined>' }
}

function Resolve-JsFileScope {
    param([string]$Src)

    if ([string]::IsNullOrWhiteSpace($Src)) {
        return @{ Scope = 'LOCAL'; SourceFile = '<undefined>' }
    }
    $bare = [System.IO.Path]::GetFileName($Src)
    if ($script:jsFileMap.ContainsKey($bare)) {
        $scope = if ($SharedJsFiles -contains $bare) { 'SHARED' } else { 'LOCAL' }
        return @{ Scope = $scope; SourceFile = $script:jsFileMap[$bare] }
    }
    $scope = if ($SharedJsFiles -contains $bare) { 'SHARED' } else { 'LOCAL' }
    return @{ Scope = $scope; SourceFile = '<undefined>' }
}
# ============================================================================
# PAGE SHELL VALIDATION
# ============================================================================
#
# Per CC_HTML_Spec.md Section 1, every page route emits HTML matching this
# canonical shape:
#
#   <!DOCTYPE html>
#   <html>
#   <head>
#       <title>$browserTitle</title>
#       <link rel="stylesheet" href="/css/<page>.css">
#       <link rel="stylesheet" href="/css/cc-shared.css">
#   </head>
#   <body class="section-<sectionKey>" data-page="<slug>" data-prefix="<prefix>">
#   $navHtml
#
#       <!-- page header bar -->
#       <!-- connection banner placeholder -->
#       <!-- page error banner placeholder -->
#       <!-- page-specific content -->
#
#       <script src="/js/cc-shared.js"></script>
#   </body>
#   </html>
#
# Page-shell validation runs ONLY on files classified as 'Route'. API
# files emit HTML fragments; Module files emit shared helpers. Neither is
# a complete page.

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
        [void]$codes.Add('MISSING_CONNECTION_BANNER')
        [void]$codes.Add('MISSING_PAGE_ERROR_BANNER')
        [void]$codes.Add('MISSING_SHARED_SCRIPT_TAG')
        return $codes.ToArray()
    }

    # ---- DOCTYPE: exact case canonical form ----
    # Spec amendment: <!DOCTYPE html> exactly (uppercase keyword, lowercase
    # tag name). The "either case acceptable" allowance has been removed.
    $firstSigIdx = Find-NextSignificantToken -Tokens $Tokens -StartAt 0
    if ($firstSigIdx -ge 0 -and $Tokens[$firstSigIdx].Kind -eq 'Doctype') {
        $rawDt = $Tokens[$firstSigIdx].Raw.Trim()
        if ($rawDt -cne '<!DOCTYPE html>') {
            [void]$codes.Add('MALFORMED_DOCTYPE')
        }
    } else {
        [void]$codes.Add('MALFORMED_DOCTYPE')
    }

    # ---- <html> root with no attributes ----
    $htmlStartIdx = Find-TokenIndex -Tokens $Tokens -Kind 'StartTag' `
        -Predicate { param($t) $t.TagName -eq 'html' }
    if ($htmlStartIdx -ge 0) {
        $attrText = $Tokens[$htmlStartIdx].AttrText
        if (-not [string]::IsNullOrWhiteSpace($attrText)) {
            [void]$codes.Add('MALFORMED_HTML_ROOT')
        }
    }

    # ---- <head> contents validation ----
    $headStartIdx = Find-TokenIndex -Tokens $Tokens -Kind 'StartTag' `
        -Predicate { param($t) $t.TagName -eq 'head' }
    $headEndIdx = -1
    if ($headStartIdx -ge 0) {
        $headEndIdx = Find-TokenIndex -Tokens $Tokens -Kind 'EndTag' `
            -Predicate { param($t) $t.TagName -eq 'head' } `
            -StartAt $headStartIdx
    }
    $linkRefs = @()  # ordered list of href values inside <head>
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

    # ---- CSS reference count and order validation ----
    # Per spec: exactly two CSS references in <head>: the page-specific CSS
    # first, then cc-shared.css.
    if ($linkRefs.Count -ne 2) {
        [void]$codes.Add('UNEXPECTED_CSS_REFERENCE')
    } else {
        $first  = [System.IO.Path]::GetFileName($linkRefs[0])
        $second = [System.IO.Path]::GetFileName($linkRefs[1])
        if ($second -ne 'cc-shared.css' -and $first -eq 'cc-shared.css') {
            [void]$codes.Add('CSS_REFERENCE_ORDER_VIOLATION')
        }
    }

    # ---- <body> attributes: section class, data-page, data-prefix ----
    $bodyStartIdx = Find-TokenIndex -Tokens $Tokens -Kind 'StartTag' `
        -Predicate { param($t) $t.TagName -eq 'body' }
    $bodyEndIdx = -1
    if ($bodyStartIdx -ge 0) {
        $bodyEndIdx = Find-TokenIndex -Tokens $Tokens -Kind 'EndTag' `
            -Predicate { param($t) $t.TagName -eq 'body' } `
            -StartAt $bodyStartIdx
        $bodyAttrs = $Tokens[$bodyStartIdx].AttrText
        if (-not (Test-AttrTextMatches -AttrText $bodyAttrs -Pattern 'class\s*=\s*["'']section-[a-z0-9\-_]+["'']')) {
            [void]$codes.Add('MISSING_BODY_SECTION_CLASS')
        }
        if (-not (Test-AttrTextMatches -AttrText $bodyAttrs -Pattern 'data-page\s*=\s*["''][^"'']+["'']')) {
            [void]$codes.Add('MISSING_DATA_PAGE')
        }
        if (-not (Test-AttrTextMatches -AttrText $bodyAttrs -Pattern 'data-prefix\s*=\s*["''][^"'']+["'']')) {
            [void]$codes.Add('MISSING_DATA_PREFIX')
        }
    }

    # ---- First content inside <body> must be $navHtml ----
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

    # ---- Page header bar: first content after $navHtml must be header-bar ----
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
                (Test-AttrTextMatches -AttrText $tt.AttrText -Pattern 'class\s*=\s*["'']header-bar["'']')) {
                $headerBarFound = $true
                $hbStart = $afterNav
                $hbEnd = Find-TokenIndex -Tokens $Tokens -Kind 'EndTag' `
                    -Predicate { param($x) $x.TagName -eq 'div' } -StartAt $hbStart
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

    # ---- Connection banner placeholder ----
    $connectionBanners = @()
    for ($k = 0; $k -lt $Tokens.Count; $k++) {
        $t = $Tokens[$k]
        if ($t.Kind -ne 'StartTag' -and $t.Kind -ne 'SelfClose') { continue }
        if ($t.TagName -ne 'div') { continue }
        if (Test-AttrTextMatches -AttrText $t.AttrText -Pattern 'id\s*=\s*["'']connection-banner["'']') {
            $connectionBanners += $k
        }
    }
    if ($connectionBanners.Count -eq 0) {
        [void]$codes.Add('MISSING_CONNECTION_BANNER')
    } else {
        foreach ($bIdx in $connectionBanners) {
            if ($Tokens[$bIdx].Kind -eq 'SelfClose') { continue }
            $closeIdx = Find-TokenIndex -Tokens $Tokens -Kind 'EndTag' `
                -Predicate { param($x) $x.TagName -eq 'div' } -StartAt $bIdx
            if ($closeIdx -le $bIdx) { continue }
            $hasContent = $false
            for ($k = $bIdx + 1; $k -lt $closeIdx; $k++) {
                $bt = $Tokens[$k]
                if ($bt.Kind -eq 'Text' -and [string]::IsNullOrWhiteSpace($bt.Raw)) { continue }
                $hasContent = $true
                break
            }
            if ($hasContent) {
                [void]$codes.Add('FORBIDDEN_BANNER_CONTENT')
                break
            }
        }
    }

    # ---- Page error banner placeholder ----
    $pageErrorBanners = @()
    for ($k = 0; $k -lt $Tokens.Count; $k++) {
        $t = $Tokens[$k]
        if ($t.Kind -ne 'StartTag' -and $t.Kind -ne 'SelfClose') { continue }
        if ($t.TagName -ne 'div') { continue }
        if (Test-AttrTextMatches -AttrText $t.AttrText -Pattern 'id\s*=\s*["'']page-error-banner["'']') {
            $pageErrorBanners += $k
        }
    }
    if ($pageErrorBanners.Count -eq 0) {
        [void]$codes.Add('MISSING_PAGE_ERROR_BANNER')
    } else {
        foreach ($bIdx in $pageErrorBanners) {
            if ($Tokens[$bIdx].Kind -eq 'SelfClose') { continue }
            $closeIdx = Find-TokenIndex -Tokens $Tokens -Kind 'EndTag' `
                -Predicate { param($x) $x.TagName -eq 'div' } -StartAt $bIdx
            if ($closeIdx -le $bIdx) { continue }
            $hasContent = $false
            for ($k = $bIdx + 1; $k -lt $closeIdx; $k++) {
                $bt = $Tokens[$k]
                if ($bt.Kind -eq 'Text' -and [string]::IsNullOrWhiteSpace($bt.Raw)) { continue }
                $hasContent = $true
                break
            }
            if ($hasContent) {
                [void]$codes.Add('FORBIDDEN_PAGE_ERROR_BANNER_CONTENT')
                break
            }
        }
    }

    # ---- Shared script tag must be last inside <body> ----
    if ($bodyStartIdx -ge 0 -and $bodyEndIdx -gt $bodyStartIdx) {
        $scriptTags = @()
        for ($k = $bodyStartIdx + 1; $k -lt $bodyEndIdx; $k++) {
            $t = $Tokens[$k]
            if (($t.Kind -eq 'StartTag' -or $t.Kind -eq 'SelfClose') -and $t.TagName -eq 'script') {
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
# ============================================================================
# MAIN TOKEN WALKER
# ============================================================================
#
# Walks the tokenized HTML markup for one emission and emits all per-construct
# rows along with their drift codes.
#
# Returns an object whose .OverlayConstructs property holds the list of
# overlay-panel constructs found, used by the post-walk contiguity and
# pair-completeness validators.

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
    # comment token (if any). Used by overlay-panel detection to attach the
    # purpose comment to its panel element.
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

    # Element-context stack for HTML_TEXT categorization
    # (CC_HTML_Spec.md Section 8.2.2). Each entry is an ordered hashtable
    # with Tag (lowercased element name) and ClassValue (the class
    # attribute's raw value, or empty string when absent). The stack tracks
    # the open-element hierarchy so a text emission can peek the top of the
    # stack to derive its categorical component_name (e.g., h2 wrapping
    # "Live Activity" with class="section-title" -> h2-section-title).
    #
    # Stack mechanics:
    #   - StartTag (non-SelfClose, non-void): push current element
    #   - SelfClose: never pushed; emits no children
    #   - Void elements (br, hr, img, input, etc.): never pushed even if
    #     authored as StartTag without trailing slash, because HTML5 says
    #     they cannot have content
    #   - EndTag: pop matching top entry; mismatched closes are tolerated
    #     (silently dropped) since other validators emit MALFORMED_*
    #     codes for those cases
    $elementStack = New-Object System.Collections.Generic.Stack[object]

    # Walk every token.
    for ($i = 0; $i -lt $Tokens.Count; $i++) {
        $t = $Tokens[$i]
        $absLine = $FileLine0 + $t.LineOffset

        # ---- Element stack maintenance: handle EndTag ----
        # Pop the stack when an end-tag matches the top entry. Mismatched
        # end-tags are silently dropped to avoid corrupting the stack -
        # MALFORMED_TAG_* codes from other validators will surface the
        # underlying problem to the user.
        if ($t.Kind -eq 'EndTag') {
            if ($elementStack.Count -gt 0 -and $elementStack.Peek().Tag -eq $t.TagName) {
                [void]$elementStack.Pop()
            }
            continue
        }

        # ---- Comment rows ----
        if ($t.Kind -eq 'Comment') {
            $body = $t.Body
            $bodyTrim = if ($null -ne $body) { $body.Trim() } else { '' }

            # Classify the comment per CC_HTML_Spec.md Section 10.5.1. Kinds:
            #   comment-section-divider  - structural divider banners
            #   comment-panel-purpose    - immediately precedes an overlay
            #                              panel construct (slideout/modal/slideup)
            #   comment-inline           - any other comment
            $kind = 'comment-inline'
            if ($bodyTrim -match '^[=\-_*]{5,}$') {
                $kind = 'comment-section-divider'
            } elseif ($bodyTrim -match '^[A-Z][A-Z\s_]+$' -and $bodyTrim.Length -gt 5) {
                $kind = 'comment-section-divider'
            }

            # Check next significant token: if it's an overlay-panel
            # element, classify as comment-panel-purpose.
            $nextSigIdx = Find-NextSignificantToken -Tokens $Tokens -StartAt ($i + 1)
            if ($nextSigIdx -ge 0) {
                $nt = $Tokens[$nextSigIdx]
                if ($nt.Kind -eq 'StartTag' -or $nt.Kind -eq 'SelfClose') {
                    $nattrs = Get-AttributesFromToken -AttrText $nt.AttrText
                    $nid = Get-AttributeByName -Attrs $nattrs -Name 'id'
                    if ($nid -and -not [string]::IsNullOrEmpty($nid.Value)) {
                        $oinfo = Get-OverlayIdInfo -IdValue $nid.Value
                        if ($null -ne $oinfo.OverlayKind) {
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

        # ---- Entity rows ----
        if ($t.Kind -eq 'Entity') {
            # Map tokenizer Form ('Named' / 'Numeric' / 'Hex') to spec form
            # name ('entity_named' / 'entity_numeric'). Both decimal and hex
            # numeric entities are 'entity_numeric' per CC_HTML_Spec.md Section 8.3.1.
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

        # ---- Text rows ----
        if ($t.Kind -eq 'Text') {
            if (-not [string]::IsNullOrWhiteSpace($t.Raw)) {
                # Categorical name derivation per CC_HTML_Spec.md Section
                # 8.2.2. Peek the element stack for the immediate parent's
                # tag and class. If the stack is empty (text outside any
                # element - structurally implausible but defensively
                # handled), Get-HtmlTextCategoricalName returns
                # 'unknown-text'.
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

        # ---- StartTag / SelfClose tokens ----
        if ($t.Kind -ne 'StartTag' -and $t.Kind -ne 'SelfClose') { continue }

        # Parse attributes once at the top of the StartTag handler so the
        # element-stack push has access to the class value and downstream
        # per-attribute processing can reuse the same parse result.
        $attrs = $null
        if (-not [string]::IsNullOrWhiteSpace($t.AttrText)) {
            $attrs = Get-AttributesFromToken -AttrText $t.AttrText
        }

        # ---- Element stack maintenance: push for non-self-closing,
        # non-void StartTag tokens. SelfClose tokens are skipped entirely
        # because they have no body; void elements (per HTML5) are skipped
        # because they cannot have content even when authored without the
        # self-closing slash. The svg element is also skipped because the
        # walker uses a fast-path (below) that jumps the iterator past
        # </svg> without ever encountering the matching EndTag token, so
        # pushing svg would leave it stuck on the stack permanently. SVG
        # is treated as an opaque outer element for HTML_SVG row emission
        # and is not a meaningful parent context for HTML_TEXT rows. ----
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

        # Inline <style> block forbidden - attach to HTML_FILE row
        if ($t.TagName -eq 'style' -and $t.Kind -eq 'StartTag') {
            if ($script:htmlFileRowByFile.ContainsKey($script:CurrentFile)) {
                Add-DriftCode -Row $script:htmlFileRowByFile[$script:CurrentFile] `
                    -Code 'FORBIDDEN_INLINE_STYLE_BLOCK' `
                    -Context "Inline <style> block at line $absLine"
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

        # Skip downstream per-attribute work for elements with no attributes
        # (the stack push above has already captured the tag for child-text
        # categorization). $attrs was set at the top of the StartTag handler.
        if ($null -eq $attrs -or $attrs.Count -eq 0) { continue }

        $tagName = $t.TagName

        # ---- Asset references: <link rel="stylesheet" ...> ----
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
                if ($src.Value -ne '/js/cc-shared.js') {
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

        # ---- Per-attribute row extraction ----
        # Pre-pass: detect whether this element has any data-action-<event>
        # attribute. The flag is needed for orphan-argument detection
        # (CC_HTML_Spec.md Section 6.3.1): a data-action-<arg-name> attribute
        # on an element without any event attribute is orphaned.
        $elementHasEventAttribute = $false
        foreach ($a in $attrs) {
            if ([string]::IsNullOrEmpty($a.Name)) { continue }
            $kind = Get-DataActionAttributeKind -AttrName $a.Name
            if ($kind -eq 'event') {
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

                    $oinfo = Get-OverlayIdInfo -IdValue $a.Value
                    $purposeText = $null
                    $hasPurpose = $false
                    if ($null -ne $oinfo.OverlayKind) {
                        if ($null -ne $oinfo.DriftCode) { $idCodes += $oinfo.DriftCode }

                        $constructEntry = [ordered]@{
                            TokenIdx           = $i
                            OverlayKind        = $oinfo.OverlayKind
                            OverlayRole        = $oinfo.OverlayRole
                            OverlayKey         = $oinfo.OverlayKey
                            IdValue            = $a.Value
                            AbsLine            = $absLine
                            HasPurposeComment  = $false
                            PurposeCommentText = $null
                        }
                        if ($pendingCommentByTokenIdx.ContainsKey($i)) {
                            $cIdx = $pendingCommentByTokenIdx[$i]
                            $cToken = $Tokens[$cIdx]
                            $cBody = if ($null -ne $cToken.Body) { $cToken.Body.Trim() } else { '' }
                            if (-not [string]::IsNullOrWhiteSpace($cBody)) {
                                $constructEntry.HasPurposeComment = $true
                                $constructEntry.PurposeCommentText = $cBody
                                $hasPurpose = $true
                                $purposeText = $cBody
                            }
                        }
                        $result.OverlayConstructs.Add($constructEntry) | Out-Null

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
                            $isSharedClass = $script:cssClassSharedMap.ContainsKey($cls)
                            if (-not $cls.StartsWith($expectedPrefix) -and -not $isSharedClass) {
                                $perClassCodes += 'CLASS_PREFIX_MISMATCH'
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

                if ($daKind -eq 'event') {
                    # data-action-<event>: variant_type = value, variant_qualifier_1 = event
                    $eventName = Get-EventFromDataActionName -AttrName $a.Name
                    foreach ($c in @(Get-DataActionEventValidationCodes -AttrName $a.Name -Value $val)) {
                        [void]$daCodes.Add($c)
                    }
                    # Helper-emission check: action value must use 'cc-' prefix.
                    # Skip when no value extractable (pure interpolation, malformed).
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
                    # Helper-emission check (CC_HTML_Spec.md Section 6.6):
                    # value must be fully static or interpolations must
                    # reference parameters / foreach iterators of the
                    # enclosing helper function only.
                    if ($IsHelperEmission -and $a.HasInterp -and -not [string]::IsNullOrEmpty($val)) {
                        $roots = @(Get-InterpolationRootVariables -Value $val)
                        $forbidden = $false
                        foreach ($r in $roots) {
                            # Scoped variables (script:, global:, etc.) are
                            # always forbidden - they reach outside the helper.
                            if ($r.IsScoped) { $forbidden = $true; break }
                            # Null root = function call or unrecognizable
                            # expression - treat as ambient state.
                            if ($null -eq $r.Root) { $forbidden = $true; break }
                            # Root variable must be in the caller-given set.
                            if (-not $CallerGivenVars.Contains($r.Root)) {
                                $forbidden = $true; break
                            }
                        }
                        if ($forbidden) {
                            [void]$daCodes.Add('FORBIDDEN_HELPER_PAGE_ACTION_ARGUMENT')
                        }
                    }
                }

                # Row scope is determined by the action value's prefix per
                # CC_HTML_Spec.md Section 6.5, NOT by the source file's scope:
                # cc-prefixed values resolve to the shared dispatch table and
                # are SHARED; everything else (page-local values, argument
                # attribute values) is LOCAL. Event attributes are scoped by
                # their action value's prefix; argument attributes are always
                # LOCAL because their values carry data, not dispatch keys.
                $rowScope = 'LOCAL'
                if ($daKind -eq 'event' -and -not [string]::IsNullOrEmpty($val) -and $val.StartsWith('cc-')) {
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
                if ($IsHelperEmission -and $a.Name -notin @('data-page','data-prefix') -and $a.Name -notlike 'data-action-*') {
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

            # User-facing attribute values - emit as 'attr-<attrname>'
            # per CC_HTML_Spec.md Section 8.2.2. The attribute carries text
            # the end user reads (tooltip, placeholder, screen-reader label,
            # image alt) and is categorized by the attribute name regardless
            # of the element it appears on.
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
# ============================================================================
# OVERLAY-PANEL POST-WALK VALIDATION
# ============================================================================
#
# After the walker collects overlay constructs, run two validators:
#
# 1. Pair completeness: every overlay key should have BOTH halves.
#    Slideout: overlay + panel
#    Modal:    overlay + dialog
#    Slideup:  backdrop + panel
#    Missing one half = INCOMPLETE_OVERLAY_PAIR on every row in the pair.
#
# 2. Contiguity: all overlay-panel constructs should form one contiguous
#    block. If a non-overlay structural element appears between two
#    overlay-panel constructs, fire OVERLAY_PANEL_NOT_CONTIGUOUS on each
#    construct in the broken run.
#
# Pair completeness also propagates the purpose comment text to all
# members of the pair (so the panel and overlay/backdrop/dialog rows
# both carry the same purpose_description).

function Invoke-OverlayPostWalkValidation {
    param(
        [Parameter(Mandatory)]$Tokens,
        [Parameter(Mandatory)]$OverlayConstructs,
        [Parameter(Mandatory)][int]$FileLine0
    )

    if ($null -eq $OverlayConstructs -or $OverlayConstructs.Count -eq 0) { return }

    # ---- Pair completeness and purpose comment propagation ----
    $pairs = @{}
    foreach ($c in $OverlayConstructs) {
        $key = "$($c.OverlayKind)|$($c.OverlayKey)"
        if (-not $pairs.ContainsKey($key)) {
            $pairs[$key] = @{ Kind = $c.OverlayKind; Roles = @{}; Constructs = @() }
        }
        $pairs[$key].Roles[$c.OverlayRole] = $c
        $pairs[$key].Constructs += $c
    }

    foreach ($key in $pairs.Keys) {
        $pair = $pairs[$key]
        $expectedRoles = switch ($pair.Kind) {
            'slideout' { @('overlay','panel') }
            'modal'    { @('overlay','dialog') }
            'slideup'  { @('backdrop','panel') }
            default    { @() }
        }
        $hasAll = $true
        foreach ($r in $expectedRoles) {
            if (-not $pair.Roles.ContainsKey($r)) { $hasAll = $false; break }
        }

        # Find the purpose text from any member of the pair
        $purposeText = $null
        foreach ($c in $pair.Constructs) {
            if (-not [string]::IsNullOrEmpty($c.PurposeCommentText)) {
                $purposeText = $c.PurposeCommentText
                break
            }
        }

        foreach ($c in $pair.Constructs) {
            $matchingRow = $null
            foreach ($r in $script:rows) {
                if ($r.ComponentType -eq 'HTML_ID' -and $r.ComponentName -eq $c.IdValue -and
                    $r.LineStart -eq $c.AbsLine) {
                    $matchingRow = $r
                    break
                }
            }
            if ($null -eq $matchingRow) { continue }

            if (-not $hasAll) {
                Add-DriftCode -Row $matchingRow -Code 'INCOMPLETE_OVERLAY_PAIR'
            }
            if (-not [string]::IsNullOrEmpty($purposeText) -and [string]::IsNullOrEmpty($matchingRow.PurposeDescription)) {
                $matchingRow.PurposeDescription = $purposeText
            }
        }
    }

    # ---- Contiguity check ----
    # Sort overlay constructs by token index. Between successive constructs,
    # check whether any "significant" non-overlay structural element appears.
    # A significant element is a StartTag whose ID (if any) is not an
    # overlay-panel ID. Whitespace text and comments don't break contiguity.
    $sorted = @($OverlayConstructs | Sort-Object { $_.TokenIdx })
    if ($sorted.Count -lt 2) { return }

    # Build a set of token indices that ARE overlay constructs
    $overlayTokenIdxSet = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($c in $sorted) { [void]$overlayTokenIdxSet.Add($c.TokenIdx) }

    # Also collect the token-index ranges of overlay panels (each construct
    # spans from its declaring StartTag to its matching EndTag). Treat the
    # entire span as part of the overlay block so element-content inside a
    # panel doesn't break contiguity.
    $overlayRanges = @()
    foreach ($c in $sorted) {
        $startIdx = $c.TokenIdx
        $startTag = $Tokens[$startIdx]
        $endIdx = $startIdx
        if ($startTag.Kind -eq 'StartTag') {
            $endIdx = Find-TokenIndex -Tokens $Tokens -Kind 'EndTag' `
                -Predicate { param($x) $x.TagName -eq $startTag.TagName } -StartAt $startIdx
            if ($endIdx -lt 0) { $endIdx = $startIdx }
        }
        $overlayRanges += @{ Start = $startIdx; End = $endIdx; Construct = $c }
    }

    # Walk through the gaps between successive overlay ranges. If a
    # significant non-overlay structural element appears in any gap, flag
    # both surrounding constructs.
    for ($r = 0; $r -lt ($overlayRanges.Count - 1); $r++) {
        $gapStart = $overlayRanges[$r].End + 1
        $gapEnd   = $overlayRanges[$r + 1].Start - 1
        if ($gapStart -gt $gapEnd) { continue }

        $hasBreaker = $false
        for ($k = $gapStart; $k -le $gapEnd; $k++) {
            $tt = $Tokens[$k]
            if ($tt.Kind -eq 'Text' -and [string]::IsNullOrWhiteSpace($tt.Raw)) { continue }
            if ($tt.Kind -eq 'Comment') { continue }
            if ($tt.Kind -eq 'EndTag') { continue }
            if ($tt.Kind -eq 'StartTag' -or $tt.Kind -eq 'SelfClose') {
                # If this StartTag is itself part of an overlay panel
                # already in the range list (unlikely; sorted ranges
                # don't overlap), skip. Otherwise it's a breaker.
                $hasBreaker = $true
                break
            }
        }

        if ($hasBreaker) {
            # Flag both the construct ending the run and the one starting
            # the next run.
            foreach ($cToFlag in @($overlayRanges[$r].Construct, $overlayRanges[$r + 1].Construct)) {
                foreach ($row in $script:rows) {
                    if ($row.ComponentType -eq 'HTML_ID' -and $row.ComponentName -eq $cToFlag.IdValue -and
                        $row.LineStart -eq $cToFlag.AbsLine) {
                        Add-DriftCode -Row $row -Code 'OVERLAY_PANEL_NOT_CONTIGUOUS'
                        break
                    }
                }
            }
        }
    }
}

# ============================================================================
# DUPLICATE ID CHECK (per-file)
# ============================================================================
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

    # Also: chrome ID reused as page-local ID. The chrome IDs are a fixed
    # set; if an HTML_ID row's component_name matches a chrome literal but
    # the element doesn't sit in a chrome context, that's the violation.
    # The conservative check: a chrome literal ID declared anywhere AND
    # appearing more than once already fires DUPLICATE_ID_DECLARATION.
    # An additional CHROME_ID_REUSED_AS_LOCAL marker fires when a chrome
    # literal appears on an element that ALSO carries a page-prefixed
    # class - hard to detect without tag-level state. Defer this
    # finer-grained check to a later pass and fire on the simpler
    # "chrome name in a page that isn't using it as chrome" criterion
    # via query.
}

# ============================================================================
# ENGINE CARD VALIDATION
# ============================================================================
#
# Per CC_HTML_Spec.md Section 2.3, the page chrome may contain an engine-row
# block with one engine card per active scheduled process registered to the
# page. Each card has the shape:
#
#   <div class="engine-card" id="card-engine-<slug>">
#     <span class="engine-label">label text</span>
#     <div class="engine-bar" id="engine-bar-<slug>"></div>
#     <span class="engine-countdown" id="engine-cd-<slug>"></span>
#   </div>
#
# Validation cross-references Orchestrator.ProcessRegistry:
#   - cc_engine_slug, cc_engine_label, cc_page_route, cc_sort_order, run_mode
#
# This runs at file level (one set of checks per route file). The route's
# Add-PodeRoute -Path value is cross-checked against ProcessRegistry.cc_page_route
# to ensure cards on this page match processes registered to this page.

function Invoke-EngineCardValidation {
    param(
        [Parameter(Mandatory)]$Tokens,
        [Parameter(Mandatory)][int]$FileLine0,
        [string[]]$RoutePaths
    )

    if ($null -eq $Tokens) { return }
    if ($null -eq $script:processRegistryRows -or $script:processRegistryRows.Count -eq 0) { return }
    if ($null -eq $RoutePaths -or $RoutePaths.Count -eq 0) { return }

    # Find all engine cards in this file by scanning for card-engine-* IDs
    $cardsOnPage = @()
    for ($i = 0; $i -lt $Tokens.Count; $i++) {
        $t = $Tokens[$i]
        if ($t.Kind -ne 'StartTag' -and $t.Kind -ne 'SelfClose') { continue }
        if ([string]::IsNullOrWhiteSpace($t.AttrText)) { continue }
        $attrs = Get-AttributesFromToken -AttrText $t.AttrText
        $idAttr = Get-AttributeByName -Attrs $attrs -Name 'id'
        if (-not $idAttr -or [string]::IsNullOrEmpty($idAttr.Value)) { continue }
        if ($idAttr.Value -match '^card-engine-(.+)$') {
            $cardsOnPage += [ordered]@{
                Slug      = $matches[1]
                TokenIdx  = $i
                AbsLine   = $FileLine0 + $t.LineOffset
                IdRowKey  = $idAttr.Value
            }
        }
    }

    if ($cardsOnPage.Count -eq 0) { return }

    # For each card, look up ProcessRegistry by slug and validate.
    foreach ($card in $cardsOnPage) {
        $proc = $null
        foreach ($p in $script:processRegistryRows) {
            if ([string]$p.cc_engine_slug -eq $card.Slug) { $proc = $p; break }
        }

        # Find the HTML_ID row for the card so drift can attach to it
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

        # Every loaded ProcessRegistry row is run_mode = 1 (active scheduled),
        # so registration completeness check applies unconditionally.
        $missingFields = @()
        if ([string]::IsNullOrEmpty([string]$proc.cc_engine_slug))  { $missingFields += 'cc_engine_slug' }
        if ([string]::IsNullOrEmpty([string]$proc.cc_engine_label)) { $missingFields += 'cc_engine_label' }
        if ([string]::IsNullOrEmpty([string]$proc.cc_page_route))   { $missingFields += 'cc_page_route' }
        if ($proc.cc_sort_order -is [System.DBNull]) { $missingFields += 'cc_sort_order' }
        if ($missingFields.Count -gt 0) {
            Add-DriftCode -Row $cardRow -Code 'MISSING_ENGINE_CARD_REGISTRATION' `
                -Context "ProcessRegistry row for slug '$($card.Slug)' has NULL in: $($missingFields -join ', ')."
        }

        # Label text mismatch: find the engine-label span inside the card
        # and compare its text to cc_engine_label.
        $cardTokenIdx = $card.TokenIdx
        $cardEndIdx = Find-TokenIndex -Tokens $Tokens -Kind 'EndTag' `
            -Predicate { param($x) $x.TagName -eq 'div' } -StartAt $cardTokenIdx
        if ($cardEndIdx -gt $cardTokenIdx) {
            $labelText = $null
            for ($k = $cardTokenIdx + 1; $k -lt $cardEndIdx; $k++) {
                $tt = $Tokens[$k]
                if ($tt.Kind -ne 'StartTag') { continue }
                if ($tt.TagName -ne 'span') { continue }
                if (Test-AttrTextMatches -AttrText $tt.AttrText -Pattern 'class\s*=\s*["'']engine-label["'']') {
                    # Find matching close and capture text content
                    $spanEnd = Find-TokenIndex -Tokens $Tokens -Kind 'EndTag' `
                        -Predicate { param($x) $x.TagName -eq 'span' } -StartAt $k
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

    # Card ordering: cards should appear in cc_sort_order ascending.
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
# ============================================================================
# FILE DISCOVERY
# ============================================================================

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

# ============================================================================
# REGISTRY LOADS
# ============================================================================

Write-Log "Loading Object_Registry mapping for FK resolution..."
$objectRegistryMap = Get-ObjectRegistryMap `
    -ServerInstance $script:XFActsServerInstance `
    -Database       $script:XFActsDatabase `
    -FileType       @('Route','API','Module')
Write-Log ("  Object_Registry rows loaded: {0}" -f $objectRegistryMap.Count)

Write-Log "Loading Object_Registry type classification per file..."
try {
    $typeQuery = @"
SELECT object_name, object_type
FROM dbo.Object_Registry
WHERE object_type IN ('Route','API','Module')
  AND is_active = 1
"@
    $typeResults = Invoke-Sqlcmd -ServerInstance $script:XFActsServerInstance `
                                 -Database       $script:XFActsDatabase `
                                 -Query          $typeQuery `
                                 -QueryTimeout   30 `
                                 -ApplicationName $script:XFActsAppName `
                                 -ErrorAction Stop `
                                 -SuppressProviderContextWarning -TrustServerCertificate
    foreach ($row in $typeResults) {
        $script:objectTypeByFile[$row.object_name] = [string]$row.object_type
    }
}
catch {
    Write-Log "Object_Registry type classification query failed: $($_.Exception.Message)" 'WARN'
}
Write-Log ("  Classified file types loaded: {0}" -f $script:objectTypeByFile.Count)

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

# ============================================================================
# CROSS-POPULATION PRE-LOADS
# ============================================================================

Write-Log "Loading CSS_CLASS DEFINITION rows for scope resolution..."
try {
    $cssClassQuery = @"
SELECT component_name, scope, file_name
FROM dbo.Asset_Registry
WHERE component_type IN ('CSS_CLASS','CSS_VARIANT')
  AND reference_type = 'DEFINITION'
  AND file_type      = 'CSS'
"@
    $cssClassResults = Invoke-Sqlcmd -ServerInstance $script:XFActsServerInstance `
                                     -Database       $script:XFActsDatabase `
                                     -Query          $cssClassQuery `
                                     -QueryTimeout   60 `
                                     -ApplicationName $script:XFActsAppName `
                                     -ErrorAction Stop `
                                     -SuppressProviderContextWarning -TrustServerCertificate
    foreach ($row in $cssClassResults) {
        $cn = [string]$row.component_name
        if ([string]::IsNullOrEmpty($cn)) { continue }
        if ($row.scope -eq 'SHARED') {
            if (-not $script:cssClassSharedMap.ContainsKey($cn)) {
                $script:cssClassSharedMap[$cn] = [string]$row.file_name
            }
        } else {
            if (-not $script:cssClassLocalMap.ContainsKey($cn)) {
                $script:cssClassLocalMap[$cn] = [string]$row.file_name
            }
        }
    }
}
catch {
    Write-Log "CSS_CLASS DEFINITION query failed: $($_.Exception.Message). USAGE rows will resolve to '<undefined>'." 'WARN'
}
Write-Log ("  CSS_CLASS DEFINITIONs loaded: {0} shared, {1} local" -f `
           $script:cssClassSharedMap.Count, $script:cssClassLocalMap.Count)

Write-Log "Loading CSS_FILE rows for asset-reference resolution..."
try {
    $cssFileQuery = @"
SELECT component_name, file_name
FROM dbo.Asset_Registry
WHERE component_type = 'CSS_FILE'
  AND reference_type = 'DEFINITION'
"@
    $cssFileResults = Invoke-Sqlcmd -ServerInstance $script:XFActsServerInstance `
                                    -Database       $script:XFActsDatabase `
                                    -Query          $cssFileQuery `
                                    -QueryTimeout   30 `
                                    -ApplicationName $script:XFActsAppName `
                                    -ErrorAction Stop `
                                    -SuppressProviderContextWarning -TrustServerCertificate
    foreach ($row in $cssFileResults) {
        $cn = [string]$row.component_name
        if (-not [string]::IsNullOrEmpty($cn) -and -not $script:cssFileMap.ContainsKey($cn)) {
            $script:cssFileMap[$cn] = [string]$row.file_name
        }
    }
}
catch {
    Write-Log "CSS_FILE query failed: $($_.Exception.Message)." 'WARN'
}
Write-Log ("  CSS_FILE rows loaded: {0}" -f $script:cssFileMap.Count)

Write-Log "Loading JS_FILE rows for asset-reference resolution..."
try {
    $jsFileQuery = @"
SELECT component_name, file_name
FROM dbo.Asset_Registry
WHERE component_type = 'JS_FILE'
  AND reference_type = 'DEFINITION'
"@
    $jsFileResults = Invoke-Sqlcmd -ServerInstance $script:XFActsServerInstance `
                                   -Database       $script:XFActsDatabase `
                                   -Query          $jsFileQuery `
                                   -QueryTimeout   30 `
                                   -ApplicationName $script:XFActsAppName `
                                   -ErrorAction Stop `
                                   -SuppressProviderContextWarning -TrustServerCertificate
    foreach ($row in $jsFileResults) {
        $cn = [string]$row.component_name
        if (-not [string]::IsNullOrEmpty($cn) -and -not $script:jsFileMap.ContainsKey($cn)) {
            $script:jsFileMap[$cn] = [string]$row.file_name
        }
    }
}
catch {
    Write-Log "JS_FILE query failed: $($_.Exception.Message)." 'WARN'
}
Write-Log ("  JS_FILE rows loaded: {0}" -f $script:jsFileMap.Count)

# ============================================================================
# ORCHESTRATOR PROCESS REGISTRY LOAD
# ============================================================================
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
    # The UNEXPECTED_ENGINE_CARD_REGISTRATION spec code is a registry-side
    # data integrity check (a queue processor row should not have cc-prefixed
    # columns populated) and is handled outside the HTML populator.
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
# ============================================================================
# PER-FILE WALK
# ============================================================================

Write-Log "Walking PS files..."

foreach ($fileRec in $psFiles) {
    $fullPath = $fileRec.FullPath
    $name     = [System.IO.Path]::GetFileName($fullPath)

    $script:CurrentFile         = $name
    $script:CurrentFullPath     = $fullPath

    Write-Host "  Parsing $name ..." -NoNewline
    $parsed = Invoke-PsParse -FilePath $fullPath
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

    # File classification drives shell validation gating and scope.
    $registeredType = $null
    if ($script:objectTypeByFile.ContainsKey($name)) {
        $registeredType = $script:objectTypeByFile[$name]
    }
    $script:CurrentRegisteredType = $registeredType

    $script:CurrentCcPrefix = $null
    if ($script:ccPrefixByFile.ContainsKey($name)) {
        $script:CurrentCcPrefix = $script:ccPrefixByFile[$name]
    }

    $scope = if ($registeredType -eq 'Module') { 'SHARED' } else { 'LOCAL' }
    $dataScope = $scope
    $isHelperEmission = ($registeredType -eq 'Module')

    # Discover Add-PodeRoute -Path declarations (captured on HTML_FILE
    # raw_text; used by engine card page-route validation).
    $routes = @(Get-PodeRoutes -Ast $parsed.Ast)
    $routePaths = @($routes | ForEach-Object { $_.Path })

    # Emit the file-level anchor row.
    $row = Add-HtmlFileRow `
        -ComponentName $name `
        -Scope         $scope `
        -LineEnd       $parsed.LineCount `
        -RoutePaths    $routePaths

    if (-not $row) { continue }

    $rowsBeforeWalk = $script:rows.Count
    $allOverlayConstructs = New-Object System.Collections.Generic.List[object]

    # Walk each emission separately so token line offsets are correct per
    # emission. Accumulate overlay constructs across the file for the
    # post-walk pair/contiguity check on the merged stream.
    foreach ($em in $emissions) {
        $emTokens = @(ConvertTo-HtmlTokens -Text $em.Text)

        # Per CC_HTML_Spec.md Section 6.6, helper-emitted argument-attribute
        # values must derive from data the helper received from its caller.
        # Resolve the set of caller-given variable names (parameters and
        # foreach iterators) from the emission's enclosing function. Route
        # ScriptBlock emissions and top-level emissions have no caller-given
        # set; the empty set means any interpolation will be flagged for
        # helper emissions (which is correct - those aren't helpers anyway,
        # so the helper-emission check never runs on them).
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

    # For Route files, run page-shell validation and engine card validation
    # against the concatenated emission text.
    if ($registeredType -eq 'Route') {
        $concatText = ''
        foreach ($em in $emissions) {
            $concatText += $em.Text
            if (-not $concatText.EndsWith("`n")) { $concatText += "`n" }
        }

        if (-not [string]::IsNullOrEmpty($concatText)) {
            $tokens = @(ConvertTo-HtmlTokens -Text $concatText)

            # Page shell drift. No -Context needed: the drift code's
            # description from DriftDescriptions is sufficient. Adding a
            # generic per-call context here stacks into noise when several
            # shell rules fire on the same row (the drift_text column
            # accumulates one entry per Add-DriftCode call).
            $shellDrift = Get-PageShellDrift -Tokens $tokens
            foreach ($code in $shellDrift) {
                Add-DriftCode -Row $row -Code $code
            }

            # Engine card validation
            $firstEmissionLine = if ($emissions.Count -gt 0) { $emissions[0].StartLine } else { 1 }
            Invoke-EngineCardValidation -Tokens $tokens -FileLine0 $firstEmissionLine -RoutePaths $routePaths

            # Overlay-panel pair + contiguity validation runs against the
            # concatenated stream as well.
            Invoke-OverlayPostWalkValidation -Tokens $tokens -OverlayConstructs $allOverlayConstructs -FileLine0 $firstEmissionLine
        }
    }
    elseif ($allOverlayConstructs.Count -gt 0) {
        # API / Module files: overlay-panel validation still runs on the
        # concatenated stream (helpers may emit overlay panels).
        $concatText = ''
        foreach ($em in $emissions) {
            $concatText += $em.Text
            if (-not $concatText.EndsWith("`n")) { $concatText += "`n" }
        }
        if (-not [string]::IsNullOrEmpty($concatText)) {
            $tokens = @(ConvertTo-HtmlTokens -Text $concatText)
            $firstEmissionLine = if ($emissions.Count -gt 0) { $emissions[0].StartLine } else { 1 }
            Invoke-OverlayPostWalkValidation -Tokens $tokens -OverlayConstructs $allOverlayConstructs -FileLine0 $firstEmissionLine
        }
    }
}

# ============================================================================
# OUTPUT BOUNDARY VALIDATION
# ============================================================================

Test-DriftCodesAgainstMasterTable -Rows $script:rows

# ============================================================================
# OCCURRENCE INDEX COMPUTATION
# ============================================================================

Write-Log "Computing occurrence_index for all rows..."
Set-OccurrenceIndices -Rows $script:rows

# ============================================================================
# SUMMARY OUTPUT
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
# DATABASE WRITE
# ============================================================================

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
        -ObjectRegistryMap  $objectRegistryMap `
        -Misses             $objectRegistryMisses
    Write-Log ("Inserted {0} rows into dbo.Asset_Registry." -f $inserted) 'SUCCESS'
}
catch {
    Write-Log "Bulk insert failed: $($_.Exception.Message)" 'ERROR'
    exit 1
}

# ============================================================================
# OBJECT_REGISTRY MISS REPORT
# ============================================================================

if ($objectRegistryMisses.Count -gt 0) {
    Write-Log ("Object_Registry registration gaps detected for {0} file(s):" -f $objectRegistryMisses.Count) 'WARN'
    foreach ($missing in ($objectRegistryMisses | Sort-Object)) {
        Write-Log ("  MISSING: $missing") 'WARN'
    }
    Write-Log "Add the file(s) above to dbo.Object_Registry to enable FK linkage on subsequent runs." 'WARN'
}

Write-Log "Done."
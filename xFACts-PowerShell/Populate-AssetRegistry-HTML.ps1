<#
.SYNOPSIS
    xFACts - Asset Registry HTML Populator

.DESCRIPTION
    Walks every PowerShell file that emits HTML in the Control Center
    (route files in scripts\routes\ and the helpers module in
    scripts\modules\), parses each file with the built-in PowerShell AST
    parser, extracts every string-literal token that contains HTML markup,
    and emits Asset_Registry rows describing every cataloguable construct
    found.

    This populator consumes shared infrastructure from
    xFACts-AssetRegistryFunctions.ps1: row construction, drift attachment,
    bulk insert, registry loads. HTML-specific logic (PS AST walk to find
    string tokens, regex-based HTML scanner, per-construct emitters, chrome
    validation against Orchestrator.ProcessRegistry) lives here.

    First-iteration build. Coverage of HTML spec sections 1-12 is fully
    represented in the drift code master table. Detection of each
    drift-bearing construct is implemented at varying depth -- the higher-
    frequency constructs (IDs, classes, event handlers, asset references,
    engine cards, text content, comments, entities, SVG) get full
    implementations; the lower-frequency drift codes (FORBIDDEN_HANDLER_*
    micro-variants, MALFORMED_ARGUMENT_QUOTING, etc.) are present in the
    master table and detected by the relevant pass but may need refinement
    after the first run produces real catalog data to triage against.

.PARAMETER Execute
    Required to actually delete the HTML rows from Asset_Registry and
    write the new row set. Without this flag, runs in preview mode.

.NOTES
    File Name : Populate-AssetRegistry-HTML.ps1
    Location  : E:\xFACts-PowerShell
    Version   : Tracked in dbo.System_Metadata (component: ControlCenter.AssetRegistry)

================================================================================
CHANGELOG
================================================================================
2026-05-10  Initial production implementation. Built against CC_HTML_Spec.md
            (locked 2026-05-10). Consumes xFACts-AssetRegistryFunctions.ps1
            for shared infrastructure. PS-AST-driven string-literal
            extraction, regex-based HTML scanner per literal, all 88 drift
            codes per spec section 15 represented in the master drift table.
            Engine card validation against Orchestrator.ProcessRegistry cc_*
            columns (added by Migrate-HtmlPopulatorSchema.sql).
================================================================================
#>

[CmdletBinding()]
param(
    [switch]$Execute
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
$PsScanRoots = @(
    "$CcRoot\scripts\routes"
    "$CcRoot\scripts\modules"
)

# Files identified as helper module sources (HTML helpers, not route files).
# Helper-emitted HTML is SHARED scope; route-emitted HTML is LOCAL scope.
$HelperFiles = @(
    'xFACts-Helpers.psm1'
)

# Functions inside the helpers module that emit HTML (used to scope
# helper-emitted rows correctly when they aren't the access-denied path).
# Detection is by parent function name, not by file alone -- the helpers
# file has non-HTML utility functions too.
$KnownHelperFunctions = @(
    'Get-NavBarHtml'
    'Get-PageHeaderHtml'
    'Get-HomePageSections'
    'Get-AccessDeniedHtml'
)

# Special-case helper: §1.6 grants Get-AccessDeniedHtml an exemption from
# FORBIDDEN_INLINE_STYLE_BLOCK and the page-shell-substitution requirements.
$AccessDeniedHelper = 'Get-AccessDeniedHtml'

# ============================================================================
# SPEC CONSTANTS
# ============================================================================

# Chrome IDs (closed set, CC_HTML_Spec.md §4.1). Adding a new chrome ID
# requires a spec amendment plus a populator update.
$ChromeIds = @(
    'last-update'
    'connection-banner'
)

# Chrome ID prefixes (slug-derived IDs from §2.3). Match any ID of the
# form <prefix>-<slug> where prefix is one of these.
$ChromeIdPrefixes = @(
    'card-engine-'
    'engine-bar-'
    'engine-cd-'
)

# User-facing display-text attributes (§8.1.2). Catalogued as HTML_TEXT
# DEFINITION rows with categorical names attr-<attribute>.
$UserFacingAttrs = @('title', 'placeholder', 'aria-label', 'alt')

# Chrome functions from cc-shared.js / engine-events.js (§6.2.2). Used by
# the event-handler validator to determine HANDLER_FUNCTION_NAME_MISMATCH.
# This is a settled-decisions list; new chrome functions land here when
# they're added to the JS spec.
$ChromeFunctions = @(
    'pageRefresh'
    'closeSlideout'
    'showAlert'
    'showConfirm'
    'engineFetch'
    'connectEngineEvents'
    'initEngineCardClicks'
    'openSlideout'
    'startLivePolling'
    'stopLivePolling'
    'startAutoRefresh'
    'updateTimestamp'
    'onPageRefresh'
    'onPageResumed'
    'onSessionExpired'
    'onEngineProcessCompleted'
)

# Drift code -> human description master. Aligned with CC_HTML_Spec.md
# §15.1 through §15.11 (88 codes total). Codes the populator emits in
# the current pass appear here; codes the spec defines but the v1
# implementation does not yet detect also appear so future extensions
# of the visitor can attach them without re-editing this list.
$DriftDescriptions = [ordered]@{
    # §15.1 Page shell
    'MALFORMED_DOCTYPE'                       = "The HTML document does not open with <!DOCTYPE html> on its own line, or the DOCTYPE token uses mixed case."
    'MALFORMED_HTML_ROOT'                     = "The root <html> element has attributes; attributes are not permitted on the root element."
    'MALFORMED_HEAD'                          = "The <head> element contains constructs other than <title> and <link> (e.g., inline <style>, <meta>, <script>)."
    'FORBIDDEN_HARDCODED_TITLE'               = "The <title> content is a hardcoded string instead of the `$browserTitle PowerShell variable substitution."
    'MISSING_BODY_SECTION_CLASS'              = "The <body> element does not declare a class=`"section-<sectionKey>`" attribute."
    'MISSING_NAV_SUBSTITUTION'                = "The first content inside <body> is not the `$navHtml substitution."
    'MALFORMED_BODY_CLOSE'                    = "Content appears between the JS reference block and </body>."
    'MISSING_HEADER_BAR'                      = "The page header bar is missing as the first content after `$navHtml."
    'FORBIDDEN_HARDCODED_PAGE_HEADER'         = "The page header content is hardcoded instead of the `$headerHtml PowerShell variable substitution."
    'MISSING_CONNECTION_BANNER'               = "The connection banner placeholder is missing."
    'FORBIDDEN_BANNER_CONTENT'                = "The connection banner placeholder contains content (it must be empty)."
    # §15.2 Page chrome
    'MALFORMED_HEADER_BAR_CONTAINER'          = "The header bar's outer container is not <div class=`"header-bar`">."
    'MALFORMED_HEADER_BAR_LEFT'               = "The first child of header-bar is not the unattributed <div> containing the `$headerHtml substitution."
    'MALFORMED_HEADER_BAR_RIGHT'              = "The second child of header-bar is not <div class=`"header-right`">."
    'MALFORMED_HEADER_RIGHT_CHILDREN'         = "The header-right element contains children other than refresh-info and optional engine-row."
    'MALFORMED_REFRESH_INFO_CONTAINER'        = "The refresh info block's outer container is not <div class=`"refresh-info`">."
    'MALFORMED_LIVE_INDICATOR'                = "The live indicator span is malformed; expected <span class=`"live-indicator`"></span> exactly."
    'MALFORMED_LIVE_STATUS_LINE'              = "The live status line deviates from mandated form."
    'MALFORMED_REFRESH_BUTTON'                = "The page refresh button markup deviates from mandated form (class, onclick, title, or entity reference)."
    'DUPLICATE_LAST_UPDATE_ID'                = "The last-update ID appears more than once on the page."
    'MALFORMED_ENGINE_ROW_CONTAINER'          = "The engine row's outer container is not <div class=`"engine-row`">."
    'MALFORMED_ENGINE_ROW_CHILDREN'           = "The engine row contains children other than engine cards."
    'ENGINE_CARD_ORDER_MISMATCH'              = "Engine cards are not in declaration order matching cc_sort_order."
    'MALFORMED_ENGINE_CARD'                   = "An engine card's structure deviates from the mandated four-element block."
    'MALFORMED_ENGINE_CARD_ATTRIBUTES'        = "An engine card's attributes are malformed (class or ID)."
    'MALFORMED_ENGINE_LABEL'                  = "An engine label span is malformed (class or text)."
    'MALFORMED_ENGINE_BAR'                    = "An engine bar div is malformed (class or ID, or contains content)."
    'MALFORMED_ENGINE_COUNTDOWN'              = "An engine countdown span is malformed (class, ID, or content)."
    'MISSING_ENGINE_CARD_REGISTRATION'        = "An active scheduled process (run_mode = 1) has NULL values in cc_engine_slug, cc_engine_label, cc_page_route, or cc_sort_order."
    'UNEXPECTED_ENGINE_CARD_REGISTRATION'     = "A queue processor process (run_mode = 2) has populated values in cc_engine_slug, cc_engine_label, cc_page_route, or cc_sort_order."
    'ENGINE_SLUG_REGISTRY_MISMATCH'           = "The slug used in card IDs doesn't match Orchestrator.ProcessRegistry.cc_engine_slug for the corresponding process."
    'ENGINE_LABEL_REGISTRY_MISMATCH'          = "The label text in the engine label span doesn't match Orchestrator.ProcessRegistry.cc_engine_label."
    'ENGINE_CARD_PAGE_MISMATCH'               = "An engine card appears on a page whose route doesn't match Orchestrator.ProcessRegistry.cc_page_route."
    # §15.3 Asset references
    'MALFORMED_CSS_LINK'                      = "A <link> element uses additional attributes beyond rel=`"stylesheet`" and href, or has an incorrect form."
    'MALFORMED_PAGE_CSS_REFERENCE'            = "The page-specific CSS reference's href doesn't match /css/<page>.css form."
    'MALFORMED_SHARED_CSS_REFERENCE'          = "The shared CSS reference is not exactly <link rel=`"stylesheet`" href=`"/css/cc-shared.css`">."
    'CSS_REFERENCE_ORDER_VIOLATION'           = "The page-specific CSS reference does not appear before the shared reference."
    'UNEXPECTED_CSS_REFERENCE'                = "A page references more or fewer than two CSS files in <head>."
    'MALFORMED_JS_SCRIPT'                     = "A <script> element uses additional attributes (e.g., defer, async) or has body content."
    'MALFORMED_PAGE_JS_REFERENCE'             = "The page-specific JS reference's src doesn't match /js/<page>.js form."
    'MALFORMED_SHARED_JS_REFERENCE'           = "The shared JS reference is not exactly <script src=`"/js/cc-shared.js`"></script>."
    'JS_REFERENCE_ORDER_VIOLATION'            = "The page-specific JS reference does not appear before the shared reference."
    'UNEXPECTED_JS_REFERENCE'                 = "A page references more or fewer than two JS files in <body>."
    'JS_REFERENCE_NOT_LAST'                   = "Content appears between the JS reference block and </body>."
    'FORBIDDEN_HELPER_ASSET_REFERENCE'        = "A helper module function emits a <link> or <script> element."
    # §15.4 IDs
    'CHROME_ID_REUSED_AS_LOCAL'               = "A page-local element is assigned a chrome ID."
    'MISSING_PREFIX_ID'                       = "A page-local ID does not begin with the page's cc_prefix followed by a hyphen."
    'CROSS_PAGE_PREFIX_COLLISION'             = "A page-local ID begins with another page's prefix."
    'DUPLICATE_ID_DECLARATION'                = "The same ID value is declared more than once on a page."
    'MALFORMED_ID_VALUE'                      = "An ID value contains characters other than lowercase letters, digits, and hyphens."
    'MALFORMED_SLIDEOUT_ID'                   = "A slideout overlay or panel ID does not follow <prefix>-slideout-<purpose>-* form."
    'MALFORMED_MODAL_ID'                      = "A modal overlay or dialog ID does not follow <prefix>-modal-<purpose>-* form."
    'MALFORMED_SLIDEUP_ID'                    = "A slide-up panel backdrop or panel ID does not follow <prefix>-slideup-<purpose>-* form."
    'INCOMPLETE_OVERLAY_PAIR'                 = "A slideout, modal, or slide-up panel declares one half of the overlay/panel pair without the other."
    'MISSING_PANEL_PURPOSE_COMMENT'           = "A slideout, modal, or slide-up panel declaration is not preceded by an HTML purpose comment."
    'FORBIDDEN_HELPER_PAGE_PREFIX_ID'         = "A helper module function emits HTML with a page-prefixed ID."
    # §15.5 Class attributes
    'MALFORMED_CLASS_VALUE_WHITESPACE'        = "A class attribute value contains multiple consecutive spaces, leading/trailing whitespace, or tabs."
    'MALFORMED_CLASS_NAME'                    = "A class name contains characters other than lowercase letters, digits, and hyphens."
    'DUPLICATE_CLASS_IN_VALUE'                = "The same class name appears more than once in the same class attribute."
    'CLASS_PREFIX_MISMATCH'                   = "A class name doesn't begin with the page's cc_prefix and is not defined in cc-shared.css."
    'INLINE_CLASS_CONCATENATION'              = "A class attribute uses inline interpolation appended to static text."
    'INLINE_CLASS_PREFIX_MIX'                 = "A class attribute uses inline interpolation followed or preceded by static text."
    'INLINE_CLASS_MULTI_INTERPOLATION'        = "A class attribute uses multiple top-level interpolations without using the array-join pattern."
    'INLINE_CLASS_BRACED_INTERPOLATION'       = "A class attribute uses PowerShell `${...} or `$(...) form mixed with static text."
    # §15.6 Event handlers
    'MULTIPLE_HANDLER_STATEMENTS'             = "An event handler attribute contains multiple statements."
    'INLINE_HANDLER_EXPRESSION'               = "An event handler attribute contains expressions other than a single function call."
    'MALFORMED_HANDLER_CALL'                  = "An event handler's function call has whitespace between the function name and the opening parenthesis."
    'TRAILING_HANDLER_SEMICOLON'              = "An event handler attribute ends with a trailing semicolon."
    'FORBIDDEN_REVEALING_MODULE_CALL'         = "An event handler calls a function via dotted property access."
    'FORBIDDEN_BUILTIN_METHOD_CALL'           = "An event handler calls a method on a built-in object."
    'HANDLER_FUNCTION_NAME_MISMATCH'          = "An event handler's function name is not registered as chrome and does not match the page's prefix."
    'FORBIDDEN_EVENT_METHOD_CALL'             = "An event handler calls a method on the event object."
    'FORBIDDEN_HANDLER_CONDITIONAL'           = "An event handler contains conditional logic."
    'FORBIDDEN_INLINE_DOM_OPERATION'          = "An event handler performs DOM manipulation inline."
    'FORBIDDEN_INLINE_ASSIGNMENT'             = "An event handler contains assignment expressions."
    'FORBIDDEN_JAVASCRIPT_PROTOCOL'           = "An event handler uses the javascript: pseudo-protocol."
    'FORBIDDEN_ARGUMENT_EXPRESSION'           = "An event handler argument is an expression other than a literal, 'this', or 'this.<property>'."
    'MALFORMED_ARGUMENT_QUOTING'              = "A string literal argument uses double quotes."
    'MALFORMED_ARGUMENT_LIST'                 = "Multiple arguments are not separated by ', '."
    'FORBIDDEN_HELPER_PAGE_FUNCTION_CALL'     = "A helper module function emits an event handler that calls a page-prefixed function."
    # §15.7 data-* attributes
    'MALFORMED_DATA_ATTRIBUTE_NAME'           = "A data-* attribute name contains characters other than lowercase letters, digits, and hyphens after the data- prefix."
    'FORBIDDEN_INLINE_DATA_INTERPOLATION'     = "A data-* attribute value mixes static text with PowerShell interpolation."
    'FORBIDDEN_HELPER_PAGE_DATA_ATTRIBUTE'    = "A helper module function emits a data-* attribute that is page-specific."
    # §15.8 Text content
    'MALFORMED_TEXT_INTERPOLATION'            = "Text content contains PowerShell variable interpolation that uses forbidden patterns."
    'EMPTY_DISPLAY_TEXT'                      = "A user-facing attribute is declared with an empty value."
    # §15.9 SVG
    'MALFORMED_SVG_INTERPOLATION'             = "An SVG element's outer markup contains forbidden interpolation patterns."
    # §15.10 Comments
    'MALFORMED_COMMENT_DASHES'                = "An HTML comment body contains -- other than the closing -->."
    'FORBIDDEN_COMMENT_INTERPOLATION'         = "An HTML comment contains PowerShell variable interpolation."
    'MALFORMED_COMMENT_UNCLOSED'              = "An HTML comment's opening <!-- does not have a matching closing -->."
    # §15.11 Inline asset blocks
    'FORBIDDEN_INLINE_STYLE_BLOCK'            = "A <style> block appears in HTML markup outside the §1.6 (access-denied page) and §9.5 (SVG-internal) carve-outs."
    'FORBIDDEN_INLINE_SCRIPT_BLOCK'           = "A <script> element contains body content."
}

# ============================================================================
# SCRIPT-SCOPE STATE
# ============================================================================

$script:rows       = New-Object System.Collections.Generic.List[object]
$script:dedupeKeys = New-Object 'System.Collections.Generic.HashSet[string]'

# Per-file metadata, keyed by short file name. Populated during Pass 2,
# consumed by Pass 3.
$script:fileMeta = @{}

# Per-file context used by HTML scanner and emitters.
$script:CurrentFile          = $null
$script:CurrentFilePath      = $null
$script:CurrentFileIsHelper  = $false
$script:CurrentPageRoute     = $null   # /batch-monitoring, /server-health, etc.
$script:CurrentPagePrefix    = $null   # bch, srh, etc. -- from Component_Registry.cc_prefix
$script:CurrentSectionKey    = $null   # platform, departmental, etc. -- from RBAC_NavRegistry (set lazily)

# Per-string-literal context set by Invoke-ScanHtmlString before scanning.
$script:CurrentParentFunction = $null   # Get-NavBarHtml, the route scriptblock, etc.
$script:CurrentLiteralStartLine = 1     # absolute file line of the literal's opening quote
$script:CurrentIsAccessDenied  = $false # exempt from §1.6 inline-style carve-out

# Engine card registry (loaded once at Pass 1). Two maps for the two
# directions of validation:
#   $script:EngineRegistryByRoute[$route] = list of @{ slug; label; sort_order; process_name }
#   $script:EngineRegistryBySlug["$route|$slug"] = @{ label; sort_order; process_name }
$script:EngineRegistryByRoute = @{}
$script:EngineRegistryBySlug  = @{}

# Per-page engine card emission tracker (cross-file Pass 3 source data).
# $script:EmittedEngineCards[$route] = list of @{ slug; label; line; raw_classes }
$script:EmittedEngineCards = @{}

# Per-page ID declaration tracker (Pass 3 DUPLICATE_ID_DECLARATION).
# $script:DeclaredIds[$route] = hashtable id -> list of rows
$script:DeclaredIds = @{}

# Cross-page prefix collision tracker. Built from Component_Registry.
# $script:AllCcPrefixes = hashtable cc_prefix -> file_name
$script:AllCcPrefixes = @{}

# ============================================================================
# ENGINE CARD REGISTRY LOAD
# ============================================================================

function Initialize-EngineCardRegistry {
    Write-Log "Loading Orchestrator.ProcessRegistry engine card configuration..."

    # Pull the four cc_* columns plus process_name and run_mode for both
    # the per-card validation and the cross-file (Pass 3) consistency check.
    $rows = Get-SqlData -Query @"
SELECT process_name, run_mode,
       cc_engine_slug, cc_engine_label, cc_page_route, cc_sort_order
FROM Orchestrator.ProcessRegistry
"@

    if ($null -eq $rows) {
        Write-Log "  No rows returned from Orchestrator.ProcessRegistry. Engine card validation will be skipped." 'WARN'
        return
    }

    $populated = 0
    foreach ($r in @($rows)) {
        $slug  = if ($r.cc_engine_slug  -is [System.DBNull]) { $null } else { [string]$r.cc_engine_slug }
        $label = if ($r.cc_engine_label -is [System.DBNull]) { $null } else { [string]$r.cc_engine_label }
        $route = if ($r.cc_page_route   -is [System.DBNull]) { $null } else { [string]$r.cc_page_route }
        $sort  = if ($r.cc_sort_order   -is [System.DBNull]) { $null } else { [int]$r.cc_sort_order }
        $rm    = [int]$r.run_mode

        # Validation discipline: run_mode = 1 must have all four populated;
        # run_mode = 2 must have all four NULL. Track but don't act here -- this
        # is a registry-side check surfaced via MISSING_ENGINE_CARD_REGISTRATION /
        # UNEXPECTED_ENGINE_CARD_REGISTRATION on engine card rows later.
        if ($rm -eq 1 -and $slug -and $route) {
            $populated++

            # By-route map: ordered list of cards for the page
            if (-not $script:EngineRegistryByRoute.ContainsKey($route)) {
                $script:EngineRegistryByRoute[$route] = New-Object System.Collections.Generic.List[object]
            }
            [void]$script:EngineRegistryByRoute[$route].Add([ordered]@{
                slug         = $slug
                label        = $label
                sort_order   = $sort
                process_name = [string]$r.process_name
            })

            # By-slug map: O(1) lookup keyed on (route, slug)
            $key = "$route|$slug"
            $script:EngineRegistryBySlug[$key] = [ordered]@{
                label        = $label
                sort_order   = $sort
                process_name = [string]$r.process_name
            }
        }
    }

    # Sort each route's card list by cc_sort_order so cross-file order check
    # has the canonical sequence ready.
    foreach ($route in @($script:EngineRegistryByRoute.Keys)) {
        $sorted = $script:EngineRegistryByRoute[$route] | Sort-Object { [int]$_.sort_order }
        $script:EngineRegistryByRoute[$route] = New-Object System.Collections.Generic.List[object]
        foreach ($entry in @($sorted)) { [void]$script:EngineRegistryByRoute[$route].Add($entry) }
    }

    # Surface the registry-side discipline issues separately. The HTML
    # populator doesn't have an Orchestrator-row to attach drift to, so it
    # just logs the count for operator awareness.
    $regIssues = Get-SqlData -Query @"
SELECT process_name, run_mode,
       cc_engine_slug, cc_engine_label, cc_page_route, cc_sort_order
FROM Orchestrator.ProcessRegistry
WHERE
    (run_mode = 1 AND (cc_engine_slug IS NULL OR cc_engine_label IS NULL OR cc_page_route IS NULL OR cc_sort_order IS NULL))
    OR
    (run_mode = 2 AND (cc_engine_slug IS NOT NULL OR cc_engine_label IS NOT NULL OR cc_page_route IS NOT NULL OR cc_sort_order IS NOT NULL))
"@
    if ($regIssues) {
        $issueCount = @($regIssues).Count
        Write-Log "  Registry-discipline issues across ProcessRegistry: $issueCount row(s)." 'WARN'
        Write-Log "  Use HTML spec Q5 (CC_HTML_Spec.md §16.5) to enumerate. Drift will surface on engine card HTML rows during Pass 3." 'WARN'
    }

    Write-Log ("  Engine card registry loaded: {0} routes, {1} cards populated." -f
               $script:EngineRegistryByRoute.Count, $populated)
}

# ============================================================================
# ROW CONSTRUCTION (HTML-SPECIFIC WRAPPERS)
# ============================================================================

# Wrap New-AssetRegistryRow with the per-file context that every HTML row
# carries (file_name = current PS file, file_type = HTML, parent_function
# from PS AST, parent_object = page route).
function New-HtmlRow {
    param(
        [int]$LineStart = 1,
        [int]$LineEnd = 0,
        [int]$ColumnStart = 0,
        [string]$ComponentType,
        [string]$ComponentName,
        [string]$ReferenceType = 'DEFINITION',
        [string]$Scope,
        [string]$SourceFile,
        [string]$Signature,
        [string]$ParentFunction,
        [string]$RawText,
        [string]$PurposeDescription
    )

    if (-not $SourceFile)     { $SourceFile     = $script:CurrentFile }
    if (-not $ParentFunction) { $ParentFunction = $script:CurrentParentFunction }
    if (-not $Scope) {
        $Scope = if ($script:CurrentFileIsHelper) { 'SHARED' } else { 'LOCAL' }
    }

    return New-AssetRegistryRow `
        -FileName           $script:CurrentFile `
        -FileType           'HTML' `
        -LineStart          $LineStart `
        -LineEnd            $LineEnd `
        -ColumnStart        $ColumnStart `
        -ComponentType      $ComponentType `
        -ComponentName      $ComponentName `
        -ReferenceType      $ReferenceType `
        -Scope              $Scope `
        -SourceFile         $SourceFile `
        -Signature          $Signature `
        -ParentFunction     $ParentFunction `
        -RawText            $RawText `
        -PurposeDescription $PurposeDescription
}

# ============================================================================
# POWERSHELL AST -> STRING LITERAL EXTRACTION
# ============================================================================

# Parse the PS file and return a list of HTML-bearing string-literal records.
# Each record carries:
#   .Text              -- the literal's string content (expandable strings
#                         preserve $foo / `$foo / $($expr) tokens verbatim
#                         because we want to detect them for drift)
#   .LineStart         -- absolute file line where the literal's opening quote sits
#   .ColumnStart       -- column on that line
#   .ParentFunction    -- enclosing FunctionDefinitionAst.Name, or NULL if
#                         the literal lives inside a route scriptblock with
#                         no enclosing function
#   .ParentRoute       -- page route from Add-PodeRoute -Path '...' if the
#                         literal lives inside a Pode route scriptblock; NULL
#                         otherwise. We use this for parent_object enrichment
#                         AND for page-prefix lookup during validation.
#   .IsAccessDenied    -- $true when ParentFunction = 'Get-AccessDeniedHtml'
#                         (triggers §1.6 carve-out exemptions)
function Get-PsHtmlLiterals {
    param([Parameter(Mandatory)] [string]$FilePath)

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($FilePath, [ref]$tokens, [ref]$errors)

    if ($errors -and $errors.Count -gt 0) {
        foreach ($e in $errors) {
            Write-Log ("  PS parse error in {0}: {1} (line {2})" -f
                       (Split-Path -Leaf $FilePath), $e.Message, $e.Extent.StartLineNumber) 'WARN'
        }
    }

    $literals = New-Object System.Collections.Generic.List[object]
    if ($null -eq $ast) { return $literals }

    # Find every string-constant and expandable-string expression in the file.
    # PowerShell distinguishes these AST node types:
    #   StringConstantExpressionAst    -- @'...'@ here-strings and 'single-quoted' strings
    #   ExpandableStringExpressionAst  -- @"..."@ here-strings and "double-quoted" strings
    # Both are subclasses of CommandElementAst and both have .Value.
    $stringAsts = $ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
        $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst]
    }, $true)

    foreach ($strAst in $stringAsts) {
        $text = $strAst.Value
        if ([string]::IsNullOrEmpty($text)) { continue }

        # Only consider strings that contain HTML. A heuristic check: must
        # contain '<' followed by a letter or '!' or '/'. This filters out
        # SQL queries, regex patterns, log messages, etc.
        if (-not ($text -match '<[A-Za-z!/]')) { continue }

        $extent = $strAst.Extent
        $lineStart   = if ($extent) { [int]$extent.StartLineNumber }   else { 1 }
        $columnStart = if ($extent) { [int]$extent.StartColumnNumber } else { 1 }

        # Walk up the parent chain to identify the enclosing function and
        # Pode route, if any.
        $parentFunction = $null
        $parentRoute    = $null
        $isAccessDenied = $false

        $cursor = $strAst.Parent
        while ($null -ne $cursor) {
            if ($null -eq $parentFunction -and
                $cursor -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
                $parentFunction = $cursor.Name
                if ($parentFunction -eq $AccessDeniedHelper) { $isAccessDenied = $true }
            }
            if ($null -eq $parentRoute -and
                $cursor -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
                # Check if this scriptblock is the -ScriptBlock argument of
                # an Add-PodeRoute (or similar) command. The scriptblock's
                # Parent should be a CommandAst whose elements contain
                # -Path '<route>'.
                $cmdCandidate = $cursor.Parent
                if ($cmdCandidate -is [System.Management.Automation.Language.CommandAst]) {
                    $routeFromCmd = Get-PodeRoutePath -CommandAst $cmdCandidate
                    if ($routeFromCmd) { $parentRoute = $routeFromCmd }
                }
            }
            $cursor = $cursor.Parent
        }

        [void]$literals.Add([pscustomobject]@{
            Text           = $text
            LineStart      = $lineStart
            ColumnStart    = $columnStart
            ParentFunction = $parentFunction
            ParentRoute    = $parentRoute
            IsAccessDenied = $isAccessDenied
        })
    }

    return $literals
}

# Extract the -Path value from a CommandAst that looks like
# `Add-PodeRoute -Method Get -Path '/batch-monitoring' -Authentication ...`.
# Returns the path string, or $null if no -Path parameter is present.
function Get-PodeRoutePath {
    param([Parameter(Mandatory)] $CommandAst)

    if ($null -eq $CommandAst.CommandElements) { return $null }

    # The command is structured as a sequence: [command name, -switch, value, -switch, value, ...].
    # We look for a CommandParameterAst whose ParameterName is 'Path', and
    # the very next element is the value (a string AST).
    $elems = @($CommandAst.CommandElements)
    for ($i = 0; $i -lt $elems.Count; $i++) {
        $el = $elems[$i]
        if ($el -is [System.Management.Automation.Language.CommandParameterAst] -and
            $el.ParameterName -eq 'Path') {
            $valueIdx = $i + 1
            if ($valueIdx -lt $elems.Count) {
                $valueEl = $elems[$valueIdx]
                if ($valueEl -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
                    $valueEl -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
                    return $valueEl.Value
                }
            }
        }
    }

    return $null
}

# ============================================================================
# HTML SCANNER -- per string literal text
# ============================================================================

# Regex masters. Patterns are intentionally conservative -- they catch the
# spec-conformant shape plus the dominant non-conformant shapes; rarer
# anti-patterns will surface on second-pass iteration after the first run.
$script:RxIdAttribute      = [regex]'(?i)\bid\s*=\s*(?:"([^"]*)"|''([^'']*)'')'
$script:RxClassAttribute   = [regex]'(?i)\bclass\s*=\s*(?:"([^"]*)"|''([^'']*)'')'
$script:RxDataAttribute    = [regex]'(?i)\b(data-[A-Za-z0-9_-]*)\s*=\s*(?:"([^"]*)"|''([^'']*)'')'
$script:RxEventHandler     = [regex]'(?i)\b(on[a-z]+)\s*=\s*(?:"([^"]*)"|''([^'']*)'')'
$script:RxUserFacingAttr   = [regex]'(?i)\b(title|placeholder|aria-label|alt)\s*=\s*(?:"([^"]*)"|''([^'']*)'')'
$script:RxOpenTag          = [regex]'(?i)<\s*([A-Za-z][A-Za-z0-9]*)\b'
$script:RxLinkTag          = [regex]'(?i)<link\b([^>]*)/?>'
$script:RxScriptTag        = [regex]'(?is)<script\b([^>]*)>(.*?)</script\s*>'
$script:RxStyleTag         = [regex]'(?is)<style\b([^>]*)>(.*?)</style\s*>'
$script:RxHtmlComment      = [regex]'(?s)<!--(.*?)-->'
$script:RxSvgBlock         = [regex]'(?is)<svg\b([^>]*)>(.*?)</svg\s*>'
$script:RxEntityNamed      = [regex]'&([A-Za-z][A-Za-z0-9]+);'
$script:RxEntityNumeric    = [regex]'&#(?:[0-9]+|x[0-9A-Fa-f]+);'
$script:RxDoctype          = [regex]'(?i)<!doctype\s+html\s*>'
$script:RxTextBetweenTags  = [regex]'(?s)>([^<]+)<'
$script:RxPsInterpolation  = [regex]'\$(?:\{[^}]+\}|\([^)]*\)|[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*)'

# Compute the absolute file line of an offset inside a string-literal body,
# given the literal's starting line. PowerShell string literals (especially
# here-strings) span multiple lines; the offset within the .Text content
# maps to "literal start + count of newlines before the offset".
function Get-FileLineForOffset {
    param(
        [Parameter(Mandatory)] [string]$Text,
        [Parameter(Mandatory)] [int]$Offset
    )
    if ($Offset -le 0) { return $script:CurrentLiteralStartLine }
    $upTo = $Text.Substring(0, [Math]::Min($Offset, $Text.Length))
    $newlines = ($upTo -split "`n").Count - 1
    return $script:CurrentLiteralStartLine + $newlines
}

# Quick utility: does a string contain forbidden PS interpolation patterns
# (the same forbidden patterns enumerated in §5.2.3)? Returns the matching
# drift code, or $null if none.
function Test-ForbiddenInterpolation {
    param([string]$Value)
    if ($null -eq $Value) { return $null }

    # Cheap exit if no $ appears.
    if ($Value.IndexOf('$') -lt 0) { return $null }

    # Braced or sub-expr form mixed with static text
    if ($Value -match '\$\{[^}]+\}\S' -or $Value -match '\$\([^)]*\)\S' -or
        $Value -match '\S\$\{' -or $Value -match '\S\$\(') {
        return 'INLINE_CLASS_BRACED_INTERPOLATION'
    }

    # Count top-level interpolations
    $matches = $script:RxPsInterpolation.Matches($Value)
    if ($matches.Count -eq 0) { return $null }

    # If more than one and surrounding context is static text, it's multi-interp
    if ($matches.Count -ge 2) { return 'INLINE_CLASS_MULTI_INTERPOLATION' }

    # Single interpolation: is it the entire attribute value (modulo trim)?
    $first = $matches[0]
    $before = $Value.Substring(0, $first.Index).Trim()
    $after  = $Value.Substring($first.Index + $first.Length).Trim()

    if ($before.Length -eq 0 -and $after.Length -eq 0) {
        return $null   # entire-value interpolation is the spec-compliant form
    }

    # Static text appears next to interpolation -- determine which side
    if ($before.Length -gt 0 -and $after.Length -gt 0) {
        return 'INLINE_CLASS_PREFIX_MIX'
    }
    if ($before.Length -gt 0) { return 'INLINE_CLASS_CONCATENATION' }
    return 'INLINE_CLASS_PREFIX_MIX'   # static text after interpolation only
}

# Quick utility: which "kind" is an ID? Returns one of:
#   'chrome'             -- exact match in $ChromeIds
#   'chrome-engine'      -- matches a $ChromeIdPrefixes prefix
#   'page-local'         -- starts with current page's prefix
#   'cross-page'         -- starts with another known page prefix
#   'unprefixed'         -- doesn't match anything
function Get-IdKind {
    param([string]$IdValue)
    if ($null -eq $IdValue) { return 'unprefixed' }
    if ($ChromeIds -contains $IdValue) { return 'chrome' }
    foreach ($p in $ChromeIdPrefixes) {
        if ($IdValue.StartsWith($p, [System.StringComparison]::Ordinal)) { return 'chrome-engine' }
    }
    if ($script:CurrentPagePrefix) {
        $pfx = "$($script:CurrentPagePrefix)-"
        if ($IdValue.StartsWith($pfx, [System.StringComparison]::Ordinal)) { return 'page-local' }
    }
    foreach ($cand in @($script:AllCcPrefixes.Keys)) {
        if ([string]::IsNullOrEmpty($cand)) { continue }
        if ($cand -eq $script:CurrentPagePrefix) { continue }
        if ($IdValue.StartsWith("$cand-", [System.StringComparison]::Ordinal)) { return 'cross-page' }
    }
    return 'unprefixed'
}

# ============================================================================
# HTML SCANNER -- main entry point per literal
# ============================================================================

# Scan one PS string literal's text for HTML constructs and emit rows.
# The literal-specific context fields ($script:CurrentParentFunction,
# $script:CurrentLiteralStartLine, $script:CurrentIsAccessDenied) must be
# set by the caller before invocation.
function Invoke-ScanHtmlString {
    param(
        [Parameter(Mandatory)] [string]$Text
    )

    if ([string]::IsNullOrEmpty($Text)) { return }

    Add-IdRowsFromText        -Text $Text
    Add-ClassRowsFromText     -Text $Text
    Add-DataAttrRowsFromText  -Text $Text
    Add-EventHandlerRowsFromText -Text $Text
    Add-UserFacingAttrRowsFromText -Text $Text
    Add-CssFileRefsFromText   -Text $Text
    Add-JsFileRefsFromText    -Text $Text
    Add-InlineStyleScriptFromText -Text $Text
    Add-SvgRowsFromText       -Text $Text
    Add-CommentRowsFromText   -Text $Text
    Add-EntityRowsFromText    -Text $Text
    Add-ElementTextRowsFromText -Text $Text
    Add-EngineCardRowsFromText -Text $Text
}

# ----------------------------------------------------------------------------
# ID emitters
# ----------------------------------------------------------------------------

function Add-IdRowsFromText {
    param([Parameter(Mandatory)][string]$Text)

    foreach ($m in $script:RxIdAttribute.Matches($Text)) {
        $idValue = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }
        $line = Get-FileLineForOffset -Text $Text -Offset $m.Index

        $kind = Get-IdKind -IdValue $idValue
        $sig  = "id=`"$idValue`""

        $row = New-HtmlRow `
            -ComponentType 'HTML_ID' `
            -ComponentName $idValue `
            -ReferenceType 'DEFINITION' `
            -LineStart     $line `
            -Signature     $sig `
            -RawText       $m.Value
        $script:rows.Add($row)

        # ---- Drift attribution ----

        # Helper functions must not emit page-prefixed IDs (§4.5)
        if ($script:CurrentFileIsHelper -and $kind -eq 'page-local') {
            Add-DriftCode -Row $row -Code 'FORBIDDEN_HELPER_PAGE_PREFIX_ID'
        }

        # MISSING_PREFIX_ID / CROSS_PAGE_PREFIX_COLLISION are page-context
        # checks. Helpers are exempt; route files with no resolved page
        # prefix (Object_Registry gap) are exempt and surfaced via the
        # miss advisory instead.
        if (-not $script:CurrentFileIsHelper -and $script:CurrentPagePrefix -and $kind -ne 'chrome' -and $kind -ne 'chrome-engine') {
            switch ($kind) {
                'page-local' {
                    # OK; nothing to emit
                }
                'cross-page' {
                    Add-DriftCode -Row $row -Code 'CROSS_PAGE_PREFIX_COLLISION' `
                        -Context "ID '$idValue' begins with another page's prefix. Expected prefix: '$($script:CurrentPagePrefix)'."
                }
                'unprefixed' {
                    Add-DriftCode -Row $row -Code 'MISSING_PREFIX_ID' `
                        -Context "ID '$idValue' does not begin with the page's prefix '$($script:CurrentPagePrefix)-'."
                }
            }
        }

        # MALFORMED_ID_VALUE: id contains forbidden chars
        if ($idValue -notmatch '^[a-z0-9-]+$' -and $kind -ne 'chrome' -and $kind -ne 'chrome-engine') {
            Add-DriftCode -Row $row -Code 'MALFORMED_ID_VALUE' `
                -Context "ID '$idValue' contains characters other than lowercase letters, digits, and hyphens."
        }

        # CHROME_ID_REUSED_AS_LOCAL: A page-local element should not be assigned
        # a chrome ID. Detection here is limited -- we cannot tell from the ID
        # alone whether the assignment is to a chrome element or to a misuse.
        # The chrome ID 'last-update' has a specific markup contract (§2.2);
        # for now we just track all 'last-update' occurrences and let Pass 3
        # flag DUPLICATE_LAST_UPDATE_ID for cases of more than one per page.

        # Track for duplicate-id and last-update detection
        $route = $script:CurrentPageRoute
        if ($route) {
            $routeKey = [string]$route
            if (-not $script:DeclaredIds.ContainsKey($routeKey)) {
                $script:DeclaredIds[$routeKey] = @{}
            }
            $bag = $script:DeclaredIds[$routeKey]
            $idKey = [string]$idValue
            if (-not $bag.ContainsKey($idKey)) {
                $bag[$idKey] = New-Object System.Collections.Generic.List[object]
            }
            [void]$bag[$idKey].Add($row)
        }
    }
}

# ----------------------------------------------------------------------------
# Class attribute emitters
# ----------------------------------------------------------------------------

function Add-ClassRowsFromText {
    param([Parameter(Mandatory)][string]$Text)

    foreach ($m in $script:RxClassAttribute.Matches($Text)) {
        $classValue = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }
        $line = Get-FileLineForOffset -Text $Text -Offset $m.Index
        $rawAttr = $m.Value

        # Detect forbidden interpolation patterns FIRST -- these supersede
        # per-class processing because the static portion is unreliable.
        $interpDrift = Test-ForbiddenInterpolation -Value $classValue
        $hasDynamic  = ($null -ne $interpDrift) -or
                       ($classValue -match '\$[A-Za-z_]')

        # Whitespace anomalies
        $whitespaceBad = ($classValue -match '^\s' -or $classValue -match '\s$' -or
                          $classValue -match '\s{2,}' -or $classValue -match "`t")

        # Strip interpolation tokens before splitting into class names so the
        # static tokens get cataloged correctly. Each removed interpolation
        # becomes "" which split-discards.
        $staticValue = $script:RxPsInterpolation.Replace($classValue, '')
        $tokens = @($staticValue -split '\s+' | Where-Object { $_ -ne '' })

        # Track duplicate-token-within-attribute drift
        $seenTokens = @{}

        foreach ($cls in $tokens) {
            $sig = "class=`"$classValue`""
            $row = New-HtmlRow `
                -ComponentType 'CSS_CLASS' `
                -ComponentName $cls `
                -ReferenceType 'USAGE' `
                -LineStart     $line `
                -Signature     $sig `
                -RawText       $rawAttr
            # HasDynamicContent lives directly on the row hashtable
            $row.HasDynamicContent = $hasDynamic
            $script:rows.Add($row)

            # MALFORMED_CLASS_NAME
            if ($cls -notmatch '^[a-z0-9-]+$') {
                Add-DriftCode -Row $row -Code 'MALFORMED_CLASS_NAME' `
                    -Context "Class '$cls' contains characters other than lowercase letters, digits, and hyphens."
            }

            # DUPLICATE_CLASS_IN_VALUE
            if ($seenTokens.ContainsKey($cls)) {
                Add-DriftCode -Row $row -Code 'DUPLICATE_CLASS_IN_VALUE' `
                    -Context "Class '$cls' appears more than once in this class attribute."
            } else {
                $seenTokens[$cls] = $true
            }

            # MALFORMED_CLASS_VALUE_WHITESPACE
            if ($whitespaceBad) {
                Add-DriftCode -Row $row -Code 'MALFORMED_CLASS_VALUE_WHITESPACE'
            }

            # Forbidden interpolation drift attaches to every row from the
            # same attribute (the spec says the attribute is the violation,
            # but the rows are what we can attach to).
            if ($interpDrift) {
                Add-DriftCode -Row $row -Code $interpDrift
            }
        }
    }
}

# ----------------------------------------------------------------------------
# data-* attribute emitter
# ----------------------------------------------------------------------------

function Add-DataAttrRowsFromText {
    param([Parameter(Mandatory)][string]$Text)

    foreach ($m in $script:RxDataAttribute.Matches($Text)) {
        $attrName = $m.Groups[1].Value
        $value    = if ($m.Groups[2].Success) { $m.Groups[2].Value } else { $m.Groups[3].Value }
        $line     = Get-FileLineForOffset -Text $Text -Offset $m.Index

        $sig = "$attrName=`"$value`""
        $hasDynamic = ($value -match '\$[A-Za-z_{(]')

        $row = New-HtmlRow `
            -ComponentType 'HTML_DATA_ATTRIBUTE' `
            -ComponentName $attrName `
            -ReferenceType 'DEFINITION' `
            -LineStart     $line `
            -Signature     $sig `
            -RawText       $m.Value
        $row.HasDynamicContent = $hasDynamic
        $script:rows.Add($row)

        # MALFORMED_DATA_ATTRIBUTE_NAME -- chars after data- prefix
        $bareName = $attrName.Substring(5)
        if ($bareName -notmatch '^[a-z0-9-]+$') {
            Add-DriftCode -Row $row -Code 'MALFORMED_DATA_ATTRIBUTE_NAME' `
                -Context "Attribute name '$attrName' contains characters other than lowercase letters, digits, and hyphens after the 'data-' prefix."
        }

        # FORBIDDEN_INLINE_DATA_INTERPOLATION
        $interpDrift = Test-ForbiddenInterpolation -Value $value
        if ($interpDrift) {
            Add-DriftCode -Row $row -Code 'FORBIDDEN_INLINE_DATA_INTERPOLATION' `
                -Context "data-* attribute value mixes static text with PowerShell interpolation."
        }

        # FORBIDDEN_HELPER_PAGE_DATA_ATTRIBUTE -- helpers should not emit
        # page-specific data attributes. We cannot tell from the name
        # alone whether it's page-specific, but if the value contains a
        # page-prefix-like literal, that's a strong signal. Skip for v1.
    }
}

# ----------------------------------------------------------------------------
# Event handler emitter
# ----------------------------------------------------------------------------

function Add-EventHandlerRowsFromText {
    param([Parameter(Mandatory)][string]$Text)

    foreach ($m in $script:RxEventHandler.Matches($Text)) {
        $eventName = $m.Groups[1].Value.ToLower()
        $body      = if ($m.Groups[2].Success) { $m.Groups[2].Value } else { $m.Groups[3].Value }
        $line      = Get-FileLineForOffset -Text $Text -Offset $m.Index

        # Skip the canonical refresh button -- its onclick='pageRefresh()' is
        # part of the chrome contract (§2.2) but lives inside id="last-update"
        # row's neighborhood, not as a violation. Still emit the row.

        # Identify the called function. Spec-compliant form is exactly:
        #   funcName(args)
        # No leading whitespace, no trailing semicolon, no conditionals.
        $trimmed = $body.Trim()

        # Detect known anti-patterns first; each gets its own row(s).
        $funcName = $null
        $callMatch = [regex]::Match($trimmed, '^([A-Za-z_$][A-Za-z0-9_$]*)\s*\(')
        if ($callMatch.Success) {
            $funcName = $callMatch.Groups[1].Value
        }

        $sig = "$eventName=`"$body`""
        $componentName = if ($funcName) { $funcName } else { '<unparseable>' }
        $row = New-HtmlRow `
            -ComponentType 'JS_FUNCTION' `
            -ComponentName $componentName `
            -ReferenceType 'USAGE' `
            -LineStart     $line `
            -Signature     $sig `
            -RawText       $m.Value
        $script:rows.Add($row)

        # Drift attribution

        if ($trimmed -match 'javascript\s*:') {
            Add-DriftCode -Row $row -Code 'FORBIDDEN_JAVASCRIPT_PROTOCOL'
        }
        if ($trimmed -match '\bif\s*\(' -or $trimmed -match '\?.*:') {
            Add-DriftCode -Row $row -Code 'FORBIDDEN_HANDLER_CONDITIONAL'
        }
        if ($trimmed -match 'classList\s*\.\s*(?:add|remove|toggle)') {
            Add-DriftCode -Row $row -Code 'FORBIDDEN_INLINE_DOM_OPERATION'
        }
        if ($trimmed -match '=\s*[^=]' -and $trimmed -notmatch '==' -and $trimmed -notmatch '!=' -and $trimmed -notmatch '<=' -and $trimmed -notmatch '>=') {
            # Crude detection -- attribute-internal '=' that isn't part of
            # a comparison. Easy false positives possible; conservative
            # marker for v1.
            if ($trimmed -match '\.\w+\s*=' -or $trimmed -match 'window\.' -or $trimmed -match 'location\s*=') {
                Add-DriftCode -Row $row -Code 'FORBIDDEN_INLINE_ASSIGNMENT'
            }
        }
        if ($trimmed -match 'event\s*\.\s*[A-Za-z]') {
            Add-DriftCode -Row $row -Code 'FORBIDDEN_EVENT_METHOD_CALL'
        }
        if ($trimmed -match ';\s*\S' -and $trimmed -notmatch ';\s*$') {
            Add-DriftCode -Row $row -Code 'MULTIPLE_HANDLER_STATEMENTS'
        }
        if ($trimmed -match ';\s*$') {
            Add-DriftCode -Row $row -Code 'TRAILING_HANDLER_SEMICOLON'
        }
        # MALFORMED_HANDLER_CALL: whitespace between function name and (
        if ($trimmed -match '^[A-Za-z_$][A-Za-z0-9_$]*\s+\(') {
            Add-DriftCode -Row $row -Code 'MALFORMED_HANDLER_CALL'
        }
        # FORBIDDEN_REVEALING_MODULE_CALL: dotted property invocation
        if ($trimmed -match '^[A-Za-z_$][A-Za-z0-9_$]*\.[A-Za-z_]') {
            Add-DriftCode -Row $row -Code 'FORBIDDEN_REVEALING_MODULE_CALL'
        }
        # INLINE_HANDLER_EXPRESSION: trimmed doesn't match func(args)$ form
        if (-not $callMatch.Success) {
            Add-DriftCode -Row $row -Code 'INLINE_HANDLER_EXPRESSION'
        }

        # HANDLER_FUNCTION_NAME_MISMATCH: function name unknown
        if ($funcName) {
            $isChrome = $ChromeFunctions -contains $funcName
            $isPagePrefixed = $false
            if ($script:CurrentPagePrefix) {
                $pfx = "$($script:CurrentPagePrefix)_"
                if ($funcName.StartsWith($pfx, [System.StringComparison]::Ordinal)) { $isPagePrefixed = $true }
            }
            if (-not $isChrome -and -not $isPagePrefixed) {
                Add-DriftCode -Row $row -Code 'HANDLER_FUNCTION_NAME_MISMATCH' `
                    -Context "Function '$funcName' is not a registered chrome function and does not match page prefix '$($script:CurrentPagePrefix)_'."
            }

            # FORBIDDEN_HELPER_PAGE_FUNCTION_CALL: helper functions should
            # not call page-prefixed functions.
            if ($script:CurrentFileIsHelper -and $isPagePrefixed) {
                Add-DriftCode -Row $row -Code 'FORBIDDEN_HELPER_PAGE_FUNCTION_CALL'
            }
        }
    }
}

# ----------------------------------------------------------------------------
# User-facing attribute emitter (title, placeholder, aria-label, alt)
# ----------------------------------------------------------------------------

function Add-UserFacingAttrRowsFromText {
    param([Parameter(Mandatory)][string]$Text)

    foreach ($m in $script:RxUserFacingAttr.Matches($Text)) {
        $attrName = $m.Groups[1].Value.ToLower()
        $value    = if ($m.Groups[2].Success) { $m.Groups[2].Value } else { $m.Groups[3].Value }
        $line     = Get-FileLineForOffset -Text $Text -Offset $m.Index

        $catName = "attr-$attrName"
        $hasDynamic = ($value -match '\$[A-Za-z_{(]')

        $row = New-HtmlRow `
            -ComponentType 'HTML_TEXT' `
            -ComponentName $catName `
            -ReferenceType 'DEFINITION' `
            -LineStart     $line `
            -RawText       $value
        $row.HasDynamicContent = $hasDynamic
        $script:rows.Add($row)

        # EMPTY_DISPLAY_TEXT: declared with empty value
        if ([string]::IsNullOrEmpty($value.Trim())) {
            Add-DriftCode -Row $row -Code 'EMPTY_DISPLAY_TEXT' `
                -Context "Attribute '$attrName' declared with empty value."
        }

        # MALFORMED_TEXT_INTERPOLATION
        $interpDrift = Test-ForbiddenInterpolation -Value $value
        if ($interpDrift) {
            Add-DriftCode -Row $row -Code 'MALFORMED_TEXT_INTERPOLATION' `
                -Context "Attribute value uses forbidden interpolation pattern."
        }
    }
}

# ----------------------------------------------------------------------------
# CSS / JS file references (<link>, <script src>)
# ----------------------------------------------------------------------------

function Add-CssFileRefsFromText {
    param([Parameter(Mandatory)][string]$Text)

    # Find every <link ...> tag. The attribute set has to be exactly
    # rel="stylesheet" and href="/css/<file>". Anything else is drift.
    foreach ($m in $script:RxLinkTag.Matches($Text)) {
        $attrs = $m.Groups[1].Value
        $line  = Get-FileLineForOffset -Text $Text -Offset $m.Index

        $hrefMatch = [regex]::Match($attrs, '(?i)href\s*=\s*(?:"([^"]*)"|''([^'']*)'')')
        $relMatch  = [regex]::Match($attrs, '(?i)rel\s*=\s*(?:"([^"]*)"|''([^'']*)'')')
        $href = if ($hrefMatch.Success) { if ($hrefMatch.Groups[1].Success) { $hrefMatch.Groups[1].Value } else { $hrefMatch.Groups[2].Value } } else { '' }
        $rel  = if ($relMatch.Success)  { if ($relMatch.Groups[1].Success)  { $relMatch.Groups[1].Value  } else { $relMatch.Groups[2].Value  } } else { '' }

        $row = New-HtmlRow `
            -ComponentType 'CSS_FILE' `
            -ComponentName ([System.IO.Path]::GetFileName($href)) `
            -ReferenceType 'USAGE' `
            -LineStart     $line `
            -Signature     $m.Value `
            -RawText       $m.Value
        $script:rows.Add($row)

        # MALFORMED_CSS_LINK: extra attributes besides rel + href
        $allowed = @('rel', 'href')
        $attrTokens = [regex]::Matches($attrs, '(?i)\b([a-z][a-z0-9-]*)\s*=')
        $extra = $false
        foreach ($at in $attrTokens) {
            $nm = $at.Groups[1].Value.ToLower()
            if ($allowed -notcontains $nm) { $extra = $true; break }
        }
        if ($extra) { Add-DriftCode -Row $row -Code 'MALFORMED_CSS_LINK' }

        # MALFORMED_SHARED_CSS_REFERENCE / MALFORMED_PAGE_CSS_REFERENCE
        if ($href -eq '/css/cc-shared.css') {
            # OK
        } elseif ($href -match '^/css/[a-z0-9-]+\.css$') {
            # OK -- page-specific
        } else {
            if ($href -match 'cc-shared') {
                Add-DriftCode -Row $row -Code 'MALFORMED_SHARED_CSS_REFERENCE'
            } else {
                Add-DriftCode -Row $row -Code 'MALFORMED_PAGE_CSS_REFERENCE'
            }
        }

        # Helper-emitted CSS reference is always drift
        if ($script:CurrentFileIsHelper) {
            Add-DriftCode -Row $row -Code 'FORBIDDEN_HELPER_ASSET_REFERENCE'
        }
    }
}

function Add-JsFileRefsFromText {
    param([Parameter(Mandatory)][string]$Text)

    foreach ($m in $script:RxScriptTag.Matches($Text)) {
        $attrs = $m.Groups[1].Value
        $body  = $m.Groups[2].Value
        $line  = Get-FileLineForOffset -Text $Text -Offset $m.Index

        $srcMatch = [regex]::Match($attrs, '(?i)src\s*=\s*(?:"([^"]*)"|''([^'']*)'')')
        $src = if ($srcMatch.Success) { if ($srcMatch.Groups[1].Success) { $srcMatch.Groups[1].Value } else { $srcMatch.Groups[2].Value } } else { '' }

        if ($src) {
            # Asset reference form
            $row = New-HtmlRow `
                -ComponentType 'JS_FILE' `
                -ComponentName ([System.IO.Path]::GetFileName($src)) `
                -ReferenceType 'USAGE' `
                -LineStart     $line `
                -Signature     $m.Value `
                -RawText       $m.Value
            $script:rows.Add($row)

            # MALFORMED_JS_SCRIPT: extra attributes or body content
            $allowed = @('src')
            $attrTokens = [regex]::Matches($attrs, '(?i)\b([a-z][a-z0-9-]*)\s*=')
            $extra = $false
            foreach ($at in $attrTokens) {
                $nm = $at.Groups[1].Value.ToLower()
                if ($allowed -notcontains $nm) { $extra = $true; break }
            }
            if ($extra -or -not [string]::IsNullOrWhiteSpace($body)) {
                Add-DriftCode -Row $row -Code 'MALFORMED_JS_SCRIPT'
            }

            if ($src -eq '/js/cc-shared.js') {
                # OK
            } elseif ($src -match '^/js/[a-z0-9-]+\.js$') {
                # OK
            } else {
                if ($src -match 'cc-shared') {
                    Add-DriftCode -Row $row -Code 'MALFORMED_SHARED_JS_REFERENCE'
                } else {
                    Add-DriftCode -Row $row -Code 'MALFORMED_PAGE_JS_REFERENCE'
                }
            }

            if ($script:CurrentFileIsHelper) {
                Add-DriftCode -Row $row -Code 'FORBIDDEN_HELPER_ASSET_REFERENCE'
            }

        } elseif (-not [string]::IsNullOrWhiteSpace($body)) {
            # Inline <script>...</script> with code body -- §12.12 forbidden
            $rawText = if ($m.Value.Length -gt 500) { $m.Value.Substring(0, 500) + '...' } else { $m.Value }
            $row = New-HtmlRow `
                -ComponentType 'JS_FILE' `
                -ComponentName '<inline>' `
                -ReferenceType 'USAGE' `
                -LineStart     $line `
                -Signature     '<script>...</script>' `
                -RawText       $rawText
            $script:rows.Add($row)
            Add-DriftCode -Row $row -Code 'FORBIDDEN_INLINE_SCRIPT_BLOCK'
        }
    }
}

function Add-InlineStyleScriptFromText {
    param([Parameter(Mandatory)][string]$Text)

    # <style> blocks. The §1.6 carve-out for Get-AccessDeniedHtml suppresses
    # this drift; §9.5 SVG-internal style is handled separately by the SVG
    # emitter (which doesn't recurse into the SVG body).
    if ($script:CurrentIsAccessDenied) { return }

    foreach ($m in $script:RxStyleTag.Matches($Text)) {
        $body = $m.Groups[2].Value
        $line = Get-FileLineForOffset -Text $Text -Offset $m.Index

        # Skip if this <style> is inside an <svg> block (§9.5 carve-out).
        # Cheap check: look backwards in $Text for an <svg> opener that
        # hasn't been closed before this position.
        $before = $Text.Substring(0, $m.Index)
        $svgOpens  = ([regex]'(?i)<svg\b').Matches($before).Count
        $svgCloses = ([regex]'(?i)</svg\s*>').Matches($before).Count
        if ($svgOpens -gt $svgCloses) { continue }

        $rawText = if ($m.Value.Length -gt 500) { $m.Value.Substring(0, 500) + '...' } else { $m.Value }
        $row = New-HtmlRow `
            -ComponentType 'HTML_COMMENT' `
            -ComponentName 'comment-style-block' `
            -ReferenceType 'DEFINITION' `
            -LineStart     $line `
            -Signature     '<style>...</style>' `
            -RawText       $rawText
        $script:rows.Add($row)
        Add-DriftCode -Row $row -Code 'FORBIDDEN_INLINE_STYLE_BLOCK'
    }
}

# ----------------------------------------------------------------------------
# SVG emitter
# ----------------------------------------------------------------------------

function Add-SvgRowsFromText {
    param([Parameter(Mandatory)][string]$Text)

    foreach ($m in $script:RxSvgBlock.Matches($Text)) {
        $attrs = $m.Groups[1].Value
        $body  = $m.Groups[2].Value
        $line  = Get-FileLineForOffset -Text $Text -Offset $m.Index

        # Categorical name from outer class attribute, per §9.3
        $classMatch = [regex]::Match($attrs, '(?i)class\s*=\s*(?:"([^"]*)"|''([^'']*)'')')
        $classes = if ($classMatch.Success) {
            if ($classMatch.Groups[1].Success) { $classMatch.Groups[1].Value } else { $classMatch.Groups[2].Value }
        } else { '' }

        $catName = 'svg-untagged'
        if ($classes) {
            $first = (@($classes -split '\s+'))[0]
            if ($first) {
                # Strip page prefix per §9.3 / §8.2.2
                if ($script:CurrentPagePrefix -and $first.StartsWith("$($script:CurrentPagePrefix)-", [System.StringComparison]::Ordinal)) {
                    $first = $first.Substring($script:CurrentPagePrefix.Length + 1)
                }
                $catName = "svg-$first"
            }
        }

        $rawText = if ($m.Value.Length -gt 2000) { $m.Value.Substring(0, 2000) + '...' } else { $m.Value }
        $hasDynamic = ($m.Value -match '\$[A-Za-z_{(]')

        $row = New-HtmlRow `
            -ComponentType 'HTML_SVG' `
            -ComponentName $catName `
            -ReferenceType 'DEFINITION' `
            -LineStart     $line `
            -RawText       $rawText
        $row.HasDynamicContent = $hasDynamic
        $script:rows.Add($row)

        # MALFORMED_SVG_INTERPOLATION on the outer attrs
        $interpDrift = Test-ForbiddenInterpolation -Value $attrs
        if ($interpDrift) {
            Add-DriftCode -Row $row -Code 'MALFORMED_SVG_INTERPOLATION'
        }
    }
}

# ----------------------------------------------------------------------------
# Comment emitter
# ----------------------------------------------------------------------------

function Add-CommentRowsFromText {
    param([Parameter(Mandatory)][string]$Text)

    foreach ($m in $script:RxHtmlComment.Matches($Text)) {
        $body = $m.Groups[1].Value
        $line = Get-FileLineForOffset -Text $Text -Offset $m.Index

        # Categorical naming per §10.5.1
        $catName = 'comment-inline'
        $bodyStripped = $body.Trim()

        # Section divider: any line in the body is a 76-char '=' rule line
        if ($bodyStripped -match '={5,}') {
            $catName = 'comment-section-divider'
        }

        $hasDynamic = ($body -match '\$[A-Za-z_{(]')

        $rawText = if ($m.Value.Length -gt 500) { $m.Value.Substring(0, 500) + '...' } else { $m.Value }
        $row = New-HtmlRow `
            -ComponentType 'HTML_COMMENT' `
            -ComponentName $catName `
            -ReferenceType 'DEFINITION' `
            -LineStart     $line `
            -RawText       $rawText
        $row.HasDynamicContent = $hasDynamic
        $script:rows.Add($row)

        # MALFORMED_COMMENT_DASHES
        if ($body -match '--') {
            Add-DriftCode -Row $row -Code 'MALFORMED_COMMENT_DASHES'
        }

        # FORBIDDEN_COMMENT_INTERPOLATION
        if ($hasDynamic) {
            Add-DriftCode -Row $row -Code 'FORBIDDEN_COMMENT_INTERPOLATION'
        }
    }

    # MALFORMED_COMMENT_UNCLOSED: rough check, count '<!--' vs '-->'
    $openCount  = ([regex]'<!--').Matches($Text).Count
    $closeCount = ([regex]'-->').Matches($Text).Count
    if ($openCount -gt $closeCount) {
        # Attribute to the file_header row in Pass 3 (we don't have one yet
        # here in the per-literal scope). Store the gap in fileMeta.
        if ($script:fileMeta.ContainsKey($script:CurrentFile)) {
            $script:fileMeta[$script:CurrentFile].UnclosedCommentCount = $openCount - $closeCount
        }
    }
}

# ----------------------------------------------------------------------------
# Entity emitter
# ----------------------------------------------------------------------------

function Add-EntityRowsFromText {
    param([Parameter(Mandatory)][string]$Text)

    foreach ($m in $script:RxEntityNamed.Matches($Text)) {
        $line = Get-FileLineForOffset -Text $Text -Offset $m.Index
        $row = New-HtmlRow `
            -ComponentType 'HTML_ENTITY' `
            -ComponentName $m.Value `
            -ReferenceType 'DEFINITION' `
            -LineStart     $line `
            -Signature     'entity_named' `
            -RawText       $m.Value
        $script:rows.Add($row)
    }

    foreach ($m in $script:RxEntityNumeric.Matches($Text)) {
        $line = Get-FileLineForOffset -Text $Text -Offset $m.Index
        $row = New-HtmlRow `
            -ComponentType 'HTML_ENTITY' `
            -ComponentName $m.Value `
            -ReferenceType 'DEFINITION' `
            -LineStart     $line `
            -Signature     'entity_numeric' `
            -RawText       $m.Value
        $script:rows.Add($row)
    }

    # Direct Unicode (above ASCII 127) -- catch characters that are likely
    # decorative glyphs. Skip if char appears inside a class/id/attribute name
    # context; we only flag if it's in element text content. A regex over the
    # whole text catches them; some false positives possible on file headers
    # with curly-quotes, em-dashes, etc.
    foreach ($m in [regex]::Matches($Text, '[\u00A0-\uFFFF]')) {
        $ch = $m.Value
        # Skip if it's whitespace or a common formatting char
        if ($ch -match '[\s\u00A0]') { continue }
        $line = Get-FileLineForOffset -Text $Text -Offset $m.Index
        $row = New-HtmlRow `
            -ComponentType 'HTML_ENTITY' `
            -ComponentName $ch `
            -ReferenceType 'DEFINITION' `
            -LineStart     $line `
            -Signature     'direct_unicode' `
            -RawText       $ch
        $script:rows.Add($row)
    }
}

# ----------------------------------------------------------------------------
# Element text content emitter
# ----------------------------------------------------------------------------

function Add-ElementTextRowsFromText {
    param([Parameter(Mandatory)][string]$Text)

    # We emit one HTML_TEXT row per non-whitespace text node between a
    # closing > of an opening tag and an opening < of the next tag (or
    # closing tag). The categorical name comes from the immediately
    # preceding opening tag's tag name and (first) class.

    # Walk every "...>(text)<..." segment. We need both the preceding tag
    # to derive the categorical name and the text content itself.
    $segmentRx = [regex]'(?s)<\s*([A-Za-z][A-Za-z0-9]*)\b([^>]*)>([^<]+)<'

    foreach ($m in $segmentRx.Matches($Text)) {
        $tagName    = $m.Groups[1].Value.ToLower()
        $tagAttrs   = $m.Groups[2].Value
        $textBody   = $m.Groups[3].Value

        # Skip whitespace-only text
        $stripped = $textBody.Trim()
        if ([string]::IsNullOrEmpty($stripped)) { continue }

        # Skip text inside <script>, <style>, <svg> blocks -- handled
        # separately (or forbidden).
        if ($tagName -in @('script','style','svg')) { continue }

        # Skip PowerShell substitutions that are the only content. They get
        # HasDynamicContent but no useful row content.
        if ($stripped -match '^\$[A-Za-z_][A-Za-z0-9_]*$') { continue }

        $line = Get-FileLineForOffset -Text $Text -Offset ($m.Index + $m.Length - $textBody.Length - 1)

        # Categorical name per §8.2.2
        $classMatch = [regex]::Match($tagAttrs, '(?i)class\s*=\s*(?:"([^"]*)"|''([^'']*)'')')
        $catName = "$tagName-text"
        if ($classMatch.Success) {
            $clsAttr = if ($classMatch.Groups[1].Success) { $classMatch.Groups[1].Value } else { $classMatch.Groups[2].Value }
            $firstCls = (@($clsAttr -split '\s+'))[0]
            if ($firstCls) {
                if ($script:CurrentPagePrefix -and $firstCls.StartsWith("$($script:CurrentPagePrefix)-", [System.StringComparison]::Ordinal)) {
                    $firstCls = $firstCls.Substring($script:CurrentPagePrefix.Length + 1)
                }
                $catName = "$tagName-$firstCls"
            }
        }

        $hasDynamic = ($stripped -match '\$[A-Za-z_{(]')

        $row = New-HtmlRow `
            -ComponentType 'HTML_TEXT' `
            -ComponentName $catName `
            -ReferenceType 'DEFINITION' `
            -LineStart     $line `
            -RawText       $stripped
        $row.HasDynamicContent = $hasDynamic
        $script:rows.Add($row)

        # MALFORMED_TEXT_INTERPOLATION
        $interpDrift = Test-ForbiddenInterpolation -Value $stripped
        if ($interpDrift) {
            Add-DriftCode -Row $row -Code 'MALFORMED_TEXT_INTERPOLATION'
        }
    }
}

# ----------------------------------------------------------------------------
# Engine card emitter (Pass 2 captures, Pass 3 validates order)
# ----------------------------------------------------------------------------

function Add-EngineCardRowsFromText {
    param([Parameter(Mandatory)][string]$Text)

    # An engine card has id="card-engine-<slug>" inside the markup. We've
    # already emitted HTML_ID rows for those in Add-IdRowsFromText. Here we
    # additionally validate that the slug + label + page route match
    # ProcessRegistry, and track emission order for Pass 3's
    # ENGINE_CARD_ORDER_MISMATCH check.

    $cardRx = [regex]'(?is)<div\s+class\s*=\s*"engine-card"\s+id\s*=\s*"card-engine-([a-z0-9-]+)"\s*>(.*?)</div>\s*<div\s+class\s*=\s*"engine-bar\s+disabled"\s+id\s*=\s*"engine-bar-([a-z0-9-]+)"\s*>'

    # Also accept the labeled three-element block; simpler regex below
    # extracts slug and the label text in one go.
    $labelRx = [regex]'(?is)<div\s+class\s*=\s*"engine-card"\s+id\s*=\s*"card-engine-([a-z0-9-]+)"\s*>\s*<span\s+class\s*=\s*"engine-label"\s*>([^<]+)</span>'

    foreach ($m in $labelRx.Matches($Text)) {
        $slug  = $m.Groups[1].Value
        $label = $m.Groups[2].Value.Trim()
        $line  = Get-FileLineForOffset -Text $Text -Offset $m.Index

        $route = $script:CurrentPageRoute
        if (-not $route) { continue }

        if (-not $script:EmittedEngineCards.ContainsKey($route)) {
            $script:EmittedEngineCards[$route] = New-Object System.Collections.Generic.List[object]
        }
        [void]$script:EmittedEngineCards[$route].Add([ordered]@{
            slug  = $slug
            label = $label
            line  = $line
            file  = $script:CurrentFile
        })

        # Per-card registry validation, attached to the HTML_ID DEFINITION
        # row for the card. Find that row by re-locating it in $script:rows.
        # (We just added it; it's near the tail.) Slightly fragile but
        # acceptable for v1.
        $targetId = "card-engine-$slug"
        $card = $null
        for ($i = $script:rows.Count - 1; $i -ge 0 -and $i -gt ($script:rows.Count - 50); $i--) {
            $r = $script:rows[$i]
            if ($r.ComponentType -eq 'HTML_ID' -and $r.ComponentName -eq $targetId) {
                $card = $r
                break
            }
        }
        if ($null -eq $card) { continue }

        # Registry lookup
        $key = "$route|$slug"
        if (-not $script:EngineRegistryBySlug.ContainsKey($key)) {
            Add-DriftCode -Row $card -Code 'ENGINE_SLUG_REGISTRY_MISMATCH' `
                -Context "Engine card slug '$slug' on page '$route' has no matching Orchestrator.ProcessRegistry row with cc_engine_slug = '$slug' and cc_page_route = '$route'."
            continue
        }

        $registered = $script:EngineRegistryBySlug[$key]
        if ($registered.label -ne $label) {
            Add-DriftCode -Row $card -Code 'ENGINE_LABEL_REGISTRY_MISMATCH' `
                -Context "Engine card label '$label' does not match Orchestrator.ProcessRegistry.cc_engine_label '$($registered.label)'."
        }
    }
}

# ============================================================================
# PASS 1 -- COLLECT SHARED DEFINITIONS FROM HELPER FILES
# ============================================================================

# In v1 we don't pre-collect helper-emitted definitions into a separate map.
# The CSS populator's Pass 1 model (zone-aware shared-class collection)
# doesn't have a direct equivalent in HTML because:
#   - Helper-emitted IDs (chrome IDs from §4.1) are a closed enum, not
#     discovered from the file -- $ChromeIds is the source of truth.
#   - Helper-emitted CSS classes resolve via CSS_CLASS DEFINITION rows
#     already in the catalog (CSS populator ran first).
#   - Helper-emitted JS function calls resolve via JS_FUNCTION DEFINITION
#     rows the JS populator will produce after this run.
# Pass 1's only job in HTML's v1 build is loading the prefix registry and
# engine card registry, which already happens earlier (above).

# ============================================================================
# PASS 2 -- PER-FILE WALK
# ============================================================================

Write-Log "Loading registries..."
$componentPrefixMap = Get-ComponentRegistryPrefixMap `
    -ServerInstance $script:XFActsServerInstance `
    -Database       $script:XFActsDatabase `
    -FileType       'PS'
Write-Log ("  Component_Registry prefix rows loaded: {0}" -f $componentPrefixMap.Count)

# Build cross-page prefix map for collision detection
foreach ($k in @($componentPrefixMap.Keys)) {
    $p = $componentPrefixMap[$k]
    if (-not [string]::IsNullOrEmpty($p)) {
        if (-not $script:AllCcPrefixes.ContainsKey($p)) {
            $script:AllCcPrefixes[$p] = $k
        }
    }
}
Write-Log ("  Distinct cc_prefix values: {0}" -f $script:AllCcPrefixes.Count)

$objectRegistryMap = Get-ObjectRegistryMap `
    -ServerInstance $script:XFActsServerInstance `
    -Database       $script:XFActsDatabase `
    -FileType       'PS'
Write-Log ("  Object_Registry rows loaded: {0}" -f $objectRegistryMap.Count)

$objectRegistryMisses = New-Object 'System.Collections.Generic.HashSet[string]'

# Engine card registry
Initialize-EngineCardRegistry

# Collect files to scan
$PsFiles = New-Object System.Collections.Generic.List[string]
foreach ($root in $PsScanRoots) {
    if (-not (Test-Path $root)) {
        Write-Log "Scan root not found, skipping: $root" 'WARN'
        continue
    }
    # Routes are .ps1; helpers module is .psm1
    $found = @(Get-ChildItem -Path $root -File -Recurse |
                 Where-Object { $_.Extension -in @('.ps1', '.psm1') } |
                 Select-Object -ExpandProperty FullName)
    foreach ($f in $found) { [void]$PsFiles.Add($f) }
}
Write-Log "Discovered $($PsFiles.Count) PS files to scan"

Write-Log "Pass 2: extracting HTML constructs from PS string literals..."

foreach ($file in $PsFiles) {
    $name = [System.IO.Path]::GetFileName($file)
    $isHelper = $HelperFiles -contains $name

    # Per-file context
    $script:CurrentFile         = $name
    $script:CurrentFilePath     = $file
    $script:CurrentFileIsHelper = $isHelper
    $script:fileMeta[$name] = @{
        UnclosedCommentCount = 0
        LiteralCount         = 0
        HtmlLiteralCount     = 0
    }

    # Resolve page prefix from Component_Registry (lookup by file name)
    $script:CurrentPagePrefix = $null
    if ($componentPrefixMap.ContainsKey($name)) {
        $script:CurrentPagePrefix = $componentPrefixMap[$name]
    }

    Write-Host ("  Scanning {0}..." -f $name) -NoNewline -ForegroundColor Cyan

    $startCount = $script:rows.Count
    try {
        $literals = Get-PsHtmlLiterals -FilePath $file
        $script:fileMeta[$name].HtmlLiteralCount = $literals.Count

        # For helpers, parent_function lives on each literal. For route
        # files, the PARENT_ROUTE on each literal IS the page route. We
        # set $script:CurrentPageRoute per literal so the page-context
        # checks (prefix, engine card) resolve correctly.
        foreach ($lit in $literals) {
            $script:CurrentLiteralStartLine = $lit.LineStart
            $script:CurrentParentFunction   = $lit.ParentFunction
            $script:CurrentPageRoute        = $lit.ParentRoute
            $script:CurrentIsAccessDenied   = $lit.IsAccessDenied

            Invoke-ScanHtmlString -Text $lit.Text
        }

        $delta = $script:rows.Count - $startCount
        Write-Host (" ok ({0} rows)" -f $delta) -ForegroundColor Green
    }
    catch {
        Write-Host " FAILED" -ForegroundColor Red
        Write-Log ("  Walk failed on {0}: {1}" -f $name, $_.Exception.Message) 'WARN'
        if ($_.ScriptStackTrace) {
            foreach ($frame in ($_.ScriptStackTrace -split "`r?`n")) {
                if (-not [string]::IsNullOrWhiteSpace($frame)) {
                    Write-Log ("    " + $frame.Trim()) 'WARN'
                }
            }
        }
    }
}

# ============================================================================
# PASS 3 -- CROSS-FILE CHECKS
# ============================================================================

Write-Log "Pass 3: cross-file consistency checks..."

try {
    # --- DUPLICATE_ID_DECLARATION + DUPLICATE_LAST_UPDATE_ID ---
    if ($script:DeclaredIds -and $script:DeclaredIds.Count -gt 0) {
        foreach ($route in @($script:DeclaredIds.Keys)) {
            if (-not $route) { continue }
            $bag = $script:DeclaredIds[$route]
            if (-not $bag) { continue }
            foreach ($idValue in @($bag.Keys)) {
                if (-not $idValue) { continue }
                $idKey = [string]$idValue
                $occurrences = @($bag[$idKey])
                if ($occurrences.Count -lt 2) { continue }

                $driftCode = if ($idKey -eq 'last-update') {
                    'DUPLICATE_LAST_UPDATE_ID'
                } else {
                    'DUPLICATE_ID_DECLARATION'
                }
                foreach ($r in $occurrences) {
                    if ($null -eq $r) { continue }
                    Add-DriftCode -Row $r -Code $driftCode `
                        -Context "ID '$idKey' declared $($occurrences.Count) times on page '$route'."
                }
            }
        }
    }

    # --- ENGINE_CARD_ORDER_MISMATCH ---
    if ($script:EmittedEngineCards -and $script:EmittedEngineCards.Count -gt 0) {
        foreach ($route in @($script:EmittedEngineCards.Keys)) {
            if (-not $route) { continue }
            $emitted = @($script:EmittedEngineCards[$route])
            if ($emitted.Count -lt 2) { continue }

            if (-not $script:EngineRegistryByRoute.ContainsKey($route)) { continue }
            $expected = @($script:EngineRegistryByRoute[$route])
            if ($expected.Count -lt 1) { continue }

            $expectedSlugs = @($expected | ForEach-Object { $_.slug })
            $emittedSlugs  = @($emitted  | ForEach-Object { $_.slug })

            $mismatch = $false
            for ($i = 0; $i -lt $emittedSlugs.Count -and $i -lt $expectedSlugs.Count; $i++) {
                if ($emittedSlugs[$i] -ne $expectedSlugs[$i]) {
                    $mismatch = $true
                    break
                }
            }

            if ($mismatch) {
                foreach ($em in $emitted) {
                    $targetId = "card-engine-$($em.slug)"
                    foreach ($r in $script:rows) {
                        if ($null -eq $r) { continue }
                        if ($r.FileName -eq $em.file -and
                            $r.ComponentType -eq 'HTML_ID' -and
                            $r.ComponentName -eq $targetId) {
                            Add-DriftCode -Row $r -Code 'ENGINE_CARD_ORDER_MISMATCH' `
                                -Context "Emitted order: $($emittedSlugs -join ', '). Expected order from cc_sort_order: $($expectedSlugs -join ', ')."
                            break
                        }
                    }
                }
            }
        }
    }

    Write-Log "  Pass 3 complete."
}
catch {
    Write-Log ("Pass 3 cross-file checks raised an error: {0}" -f $_.Exception.Message) 'WARN'
    if ($_.ScriptStackTrace) {
        foreach ($frame in ($_.ScriptStackTrace -split "`r?`n")) {
            if (-not [string]::IsNullOrWhiteSpace($frame)) {
                Write-Log ("  " + $frame.Trim()) 'WARN'
            }
        }
    }
    Write-Log "Continuing with downstream steps; cross-file drift codes may be missing from output." 'WARN'
}

# ============================================================================
# OUTPUT BOUNDARY VALIDATION
# ============================================================================

Write-Log "Validating drift codes against master table..."
try {
    Test-DriftCodesAgainstMasterTable -Rows $script:rows
    Write-Log "  Drift code validation complete."
}
catch {
    Write-Log ("Drift code validation raised an error: {0}" -f $_.Exception.Message) 'WARN'
    if ($_.ScriptStackTrace) {
        foreach ($frame in ($_.ScriptStackTrace -split "`r?`n")) {
            if (-not [string]::IsNullOrWhiteSpace($frame)) {
                Write-Log ("  " + $frame.Trim()) 'WARN'
            }
        }
    }
}

# ============================================================================
# OCCURRENCE INDEX
# ============================================================================

Write-Log "Computing occurrence_index for all rows..."
try {
    Set-OccurrenceIndices -Rows $script:rows
    Write-Log "  Occurrence indices computed."
}
catch {
    Write-Log ("Occurrence index computation raised an error: {0}" -f $_.Exception.Message) 'WARN'
    if ($_.ScriptStackTrace) {
        foreach ($frame in ($_.ScriptStackTrace -split "`r?`n")) {
            if (-not [string]::IsNullOrWhiteSpace($frame)) {
                Write-Log ("  " + $frame.Trim()) 'WARN'
            }
        }
    }
    Write-Log "Some rows may have occurrence_index = 1 by default; insert will still proceed." 'WARN'
}

# ============================================================================
# SUMMARY OUTPUT
# ============================================================================

Write-Log ("Total rows generated: {0}" -f $script:rows.Count)

if ($script:rows.Count -gt 0) {
    Write-Log ""
    Write-Log "Rows by component_type / reference_type / scope:"
    $script:rows | Group-Object { "$($_.ComponentType) / $($_.ReferenceType) / $($_.Scope)" } |
        Sort-Object Count -Descending |
        Format-Table @{L='Component / Ref / Scope';E='Name'}, Count -AutoSize | Out-String | Write-Host

    $driftedCount = @($script:rows | Where-Object { $_.DriftCodes }).Count
    Write-Log ("Rows with drift codes: {0} of {1} ({2:F1}%)" -f
               $driftedCount, $script:rows.Count, ($driftedCount / [double]$script:rows.Count * 100))

    if ($driftedCount -gt 0) {
        Write-Log ""
        Write-Log "Drift code distribution:"
        $allCodes = New-Object 'System.Collections.Generic.List[string]'
        foreach ($r in $script:rows) {
            if ([string]::IsNullOrEmpty($r.DriftCodes)) { continue }
            foreach ($c in ($r.DriftCodes -split ',\s*')) {
                if (-not [string]::IsNullOrEmpty($c)) { $allCodes.Add($c) }
            }
        }
        $allCodes | Group-Object | Sort-Object Count -Descending |
            Select-Object @{L='Drift Code';E='Name'}, Count |
            Format-Table -AutoSize | Out-String | Write-Host

        Write-Log "Top files by drift row count:"
        $script:rows | Where-Object { $_.DriftCodes } |
            Group-Object { $_.FileName } |
            Sort-Object Count -Descending |
            Select-Object -First 15 @{L='File';E='Name'}, @{L='Drift Rows';E='Count'} |
            Format-Table -AutoSize | Out-String | Write-Host
    }
}

# ============================================================================
# DATABASE WRITE
# ============================================================================

if (-not $Execute) {
    Write-Log "PREVIEW MODE - no rows written to Asset_Registry. Use -Execute to insert." 'WARN'
    return
}

Write-Log "Clearing existing HTML rows from Asset_Registry..."
$cleared = Invoke-SqlNonQuery -Query "DELETE FROM dbo.Asset_Registry WHERE file_type = 'HTML';"
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
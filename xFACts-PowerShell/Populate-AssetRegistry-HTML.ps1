<#
.SYNOPSIS
    xFACts - Asset Registry HTML Populator

.DESCRIPTION
    Walks every .ps1 and .psm1 file under the Control Center route and
    helper directories, identifies HTML-emitting constructs inside each
    file (here-strings whose content begins with HTML, and StringBuilder
    Append/AppendLine call sequences inside helper functions), and
    generates Asset_Registry rows describing every catalogable HTML
    construct found in the markup plus drift codes against CC_HTML_Spec.md.

    This populator consumes shared infrastructure from
    xFACts-AssetRegistryFunctions.ps1: row construction, drift attachment,
    bulk insert, registry loads. Per-language logic (PowerShell AST walk,
    HTML emission discovery, HTML tokenizer, per-construct emitters)
    lives here.

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

    Wave 1 implements:
      * File discovery (Route, API, and Module files)
      * PowerShell AST walking to find HTML-emission constructs and
        their enclosing function context (for parent_function)
      * HTML emission discovery from two PowerShell patterns:
          - Here-strings (@"..."@ or @'...'@) whose content begins with
            HTML (detected by structural sniff, not just "<letter")
          - StringBuilder append-style call sequences (.AppendLine(...))
            grouped by the variable they target inside one function
      * Page route resolution from Add-PodeRoute -Path declarations
        (captured on the HTML_FILE row's raw_text for Wave 4's
        ProcessRegistry cross-checks)
      * HTML tokenizer that recognizes tags, attributes, text nodes,
        comments, and PowerShell interpolation markers
      * One HTML_FILE row per host file with HTML emission
      * Page-shell drift detection per CC_HTML_Spec.md Section 15.1,
        applied ONLY to Route-classified files. API and Module files
        emit HTML fragments rather than complete pages and are exempt
        from page-shell rules per spec Section 1.5.

    Wave 2 (this delivery) extracts attribute-level constructs from the
    HTML markup discovered in Wave 1 and emits one Asset_Registry row
    per construct. Drift codes for these row types are deferred to a
    Wave 2.1 follow-up; the focus here is on confirming row extraction
    is correct before layering validation on top.

    Wave 2 row types emitted:
      * HTML_ID DEFINITION         - every id="..." attribute
      * HTML_DATA_ATTRIBUTE DEF.   - every data-*="..." attribute
      * CSS_FILE USAGE             - every <link rel="stylesheet" href=>
      * JS_FILE USAGE              - every <script src=...>
      * CSS_CLASS USAGE            - every class name inside class="..."
      * JS_FUNCTION USAGE          - every event handler attribute
                                     (onclick=, onchange=, etc.)

    CSS_CLASS USAGE rows resolve scope and source_file against the
    catalog's existing CSS_CLASS DEFINITION rows (emitted by the CSS
    populator). CSS_FILE and JS_FILE USAGE rows resolve similarly
    against CSS_FILE / JS_FILE DEFINITION rows. JS_FUNCTION USAGE rows
    are emitted without scope resolution (the JS populator runs after
    HTML, so JS_FUNCTION DEFINITIONs may not exist yet at HTML-populator
    scan time); the JS populator's USAGE-side resolution handles the
    cross-population linkage from the other direction.

    Waves 3-4 will add:
      * HTML_TEXT, HTML_ENTITY, HTML_SVG, HTML_COMMENT extraction (Wave 3)
      * Orchestrator.ProcessRegistry-driven engine card validation +
        full drift code coverage across all extracted rows (Wave 4)

    Run AFTER the CSS populator has loaded all CSS_CLASS DEFINITION rows
    (required for Wave 2's CSS_CLASS USAGE resolution; harmless in Wave 1
    where no USAGE rows are emitted).

.PARAMETER Execute
    Required to actually delete the HTML rows from Asset_Registry and
    write the new row set. Without this flag, runs in preview mode.

.PARAMETER FileFilter
    Optional file-name filter for processing a single file or subset
    (e.g., -FileFilter 'BusinessServices.ps1' processes only that file).

.NOTES
    File Name : Populate-AssetRegistry-HTML.ps1
    Location  : E:\xFACts-PowerShell
    Version   : Tracked in dbo.System_Metadata (component: ControlCenter.AssetRegistry)

================================================================================
CHANGELOG
================================================================================
2026-05-11  Universal anchor-row refactor: HTML side completion.
            With the CSS and JS populators now emitting pure-anchor
            CSS_FILE / JS_FILE rows (separate from their parsed-header
            FILE_HEADER rows), the HTML populator's asset-reference
            resolver pre-loads were retargeted to match:
            - CSS_FILE pre-load: now queries component_type = 'CSS_FILE'
              (was 'FILE_HEADER' with file_type = 'CSS' as an interim
              measure). file_type filter dropped as redundant.
            - JS_FILE pre-load: now queries component_type = 'JS_FILE'
              (was 'FILE_HEADER' with file_type = 'JS'). Same shape.
            No change to row emissions. HTML_FILE remains the anchor
            row for HTML; HTML does not emit a FILE_HEADER row because
            HTML markup has no file-header construct (the host PS file's
            header will be cataloged by the future PS populator as a
            file_type = 'PS' row).
2026-05-11  Catalog audit and resolver pre-load fixes.

            Background: while investigating CSS_FILE / JS_FILE asset
            reference resolution showing all-unresolved on first run, an
            audit of the cross-populator catalog model revealed that the
            CSS, JS, and HTML populators use inconsistent component_type
            names for their file-level anchor rows. CSS and JS use
            'FILE_HEADER' as a dual-purpose anchor + parsed-header row;
            HTML uses 'HTML_FILE' as a pure anchor (HTML markup has no
            file-header construct to parse).

            A universal anchor-row refactor was discussed and planned
            for a future session - see Asset_Registry_Universal_Anchor_Refactor.md
            in Planning/. The HTML populator's anchor row stays as
            HTML_FILE; the CSS and JS populators will split their
            FILE_HEADER rows into pure-anchor CSS_FILE / JS_FILE rows
            plus parsed-header FILE_HEADER rows in the refactor session.

            Changes delivered in this session:
            - CSS_CLASS pre-load: expanded to component_type IN
              ('CSS_CLASS','CSS_VARIANT') so HTML CSS_CLASS USAGE rows
              resolve against the CSS populator's variant rows
              (specialized selectors with the same base class name).
              Mirrors the JS_FUNCTION pre-load's existing
              ('JS_FUNCTION','JS_FUNCTION_VARIANT') handling.
            - CSS_FILE pre-load: corrected to query component_type =
              'FILE_HEADER' with file_type = 'CSS' (was looking for
              'CSS_FILE' rows that no populator emits today). After the
              universal refactor lands, this query will switch to
              targeting 'CSS_FILE' rows directly.
            - JS_FILE pre-load: corrected to query component_type =
              'FILE_HEADER' with file_type = 'JS' (same issue). Same
              switch-target after the universal refactor.

            No changes to the HTML populator's row emissions in this
            session; the HTML_FILE anchor row continues to be emitted
            with the same shape as Wave 1.1.

2026-05-11  Wave 2: attribute-level row extraction.
            Walks the tokenized HTML markup from Wave 1 and emits one
            Asset_Registry row per catalogable construct.

            New row types:
              * HTML_ID DEFINITION (id="..." on any element)
              * HTML_DATA_ATTRIBUTE DEFINITION (data-* on any element)
              * CSS_FILE USAGE (<link rel="stylesheet" href="...">)
              * JS_FILE USAGE (<script src="..."></script>)
              * CSS_CLASS USAGE (one per class name in class="...")
              * JS_FUNCTION USAGE (one per event handler attribute)

            New infrastructure:
              * Get-AttributesFromToken - parses Wave 1's verbatim
                AttrText string into structured (name, value, quoted)
                attribute records, handling both " and ' quoting and
                attribute values containing PowerShell interpolation.
              * Get-FunctionNameFromHandler - peels the called function
                name from an event handler value like 'foo()' or
                'bar(this, 123)'. Returns null when the handler is too
                malformed to extract a name (Wave 2.1 attaches drift
                codes for those cases).
              * Split-StaticClassTokens - splits a class="..." value
                into individual class names, dropping PowerShell
                interpolation tokens (variables and ${...} / $(...)
                forms) the same way the JS populator does.
              * CSS_CLASS DEFINITION pre-load at populator startup -
                queries every CSS_CLASS DEFINITION row from the
                catalog and buckets by scope (SHARED vs LOCAL) for
                fast USAGE-side resolution.
              * CSS_FILE / JS_FILE DEFINITION pre-loads at populator
                startup - queries every CSS_FILE and JS_FILE row from
                the catalog for asset-reference scope resolution.

            Per CC_HTML_Spec.md Section 13.6, the HTML populator
            resolves USAGE references against existing DEFINITION rows
            at scan time. Out-of-order standalone runs (HTML before
            CSS) produce '<undefined>' source_file values, surfaced
            via Q8 of the spec's compliance queries.

            Wave 2 does NOT yet attach drift codes for the new row
            types. The drift code table $DriftDescriptions still
            includes all 88 codes per spec Section 15 (added in Wave 1)
            so the output-boundary validator passes cleanly. Wave 2.1
            will attach the row-level codes from Sections 15.3-15.7.

            Event handler validation in particular is deferred because
            it requires parsing the handler value beyond just the
            function name - multi-statement detection, conditional
            detection, argument-form validation, and several others
            all need expression-level analysis the row extractor does
            not yet do.
            - HTML_FILE row identity model corrected: one row per host
              file (Route .ps1, API .ps1, or Module .psm1), not one row
              per Add-PodeRoute call inside a file. Component_name is
              the bare host filename. Route paths discovered inside a
              file are captured on the row's raw_text field (pipe-joined
              if multiple) for Wave 4's ProcessRegistry cross-checks.
            - Object_Registry lookup fixed: queries object_type IN
              ('Route','API','Module') instead of the (wrong) 'HTML'
              alias. PS files registered as Routes, APIs, and Modules
              now FK correctly into Object_Registry. The shared helpers
              Get-ObjectRegistryMap and Get-ComponentRegistryPrefixMap
              were expanded simultaneously to accept the new aliases.
            - Page-shell validation now runs ONLY on files classified
              as 'Route' in Object_Registry. API files emit HTML
              fragments and Module files emit shared HTML helpers;
              neither is a complete page per spec Section 1.5, so the
              Section 15.1 page-shell drift codes do not apply. Files
              with HTML emission that are not in Object_Registry still
              get an HTML_FILE row, but no shell validation runs (we
              cannot classify the file without registration).
            - File scope inference: Route and API files are LOCAL
              (page-specific); Module files are SHARED.
            - Test-LooksLikeHtmlEmission rewritten using a structural
              detection model (Option 3). Strong-signal short-circuits
              (DOCTYPE, <html>, HTML comments, class=, id=) admit real
              HTML emissions; an open/close tag-pair check admits any
              fragment with at least one open/close pair of the same
              tag name. The previous '<[A-Za-z/!]' sniff false-positived
              on SQL LIKE patterns containing XML-like tokens (e.g.,
              '%<SystemHealth>%' from sys.dm_os_ring_buffers queries in
              ServerHealth-API.ps1 and IndexMaintenance-API.ps1), which
              produced spurious HTML_FILE rows for those files. The
              structural model rejects them because lone XML tokens in
              SQL strings have no matching closing tag. XML payloads
              led by '<?xml' are explicitly rejected.
2026-05-11  Initial Wave 1 implementation. Fresh build (the test
            populator in WorkingFiles/ is a sketch only and predates
            the locked HTML spec). Consumes xFACts-AssetRegistryFunctions.ps1
            for shared infrastructure. PowerShell AST walking via
            [System.Management.Automation.Language.Parser]::ParseFile()
            to find HTML-emission constructs and their enclosing
            function context. HTML emission discovery from here-strings
            (content-sniff) and StringBuilder append sequences (grouped
            by target variable within a function). Page route resolution
            from Add-PodeRoute -Path declarations. Homegrown HTML
            tokenizer that recognizes tags, attributes, text, comments,
            and PowerShell interpolation. HTML_FILE anchor row emission
            per scanned PS file. Page-shell drift codes per
            CC_HTML_Spec.md Section 15.1 attached to the HTML_FILE row
            of route files. Waves 2-4 deferred for separate deliveries.
================================================================================
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

# ============================================================================
# SPEC CONSTANTS
# ============================================================================

# Drift code -> human description mapping. Used by Add-DriftCode (helpers)
# to validate codes and to populate drift_text. Aligned with CC_HTML_Spec.md
# Section 15.
#
# WAVE 1 SCOPE: this table includes ALL 88 drift codes per the spec's
# Section 15. Codes that are not yet emitted by the populator (Waves 2-4
# territory) are listed anyway so the master-table validation step doesn't
# need to be retouched when those waves land. Codes are organized by spec
# section number matching Section 15.1 through 15.11.
$DriftDescriptions = [ordered]@{
    # ---- Section 15.1: Page shell codes (attached to HTML_FILE) ----
    'MALFORMED_DOCTYPE'                 = "The HTML document does not open with <!DOCTYPE html> on its own line, or the DOCTYPE token uses mixed case."
    'MALFORMED_HTML_ROOT'               = "The root <html> element has attributes; attributes are not permitted on the root element."
    'MALFORMED_HEAD'                    = "The <head> element contains constructs other than <title> and <link> (e.g., inline <style>, <meta>, <script>)."
    'FORBIDDEN_HARDCODED_TITLE'         = "The <title> content is a hardcoded string instead of the `$browserTitle PowerShell variable substitution."
    'MISSING_BODY_SECTION_CLASS'        = "The <body> element does not declare a class=`"section-<sectionKey>`" attribute."
    'MISSING_NAV_SUBSTITUTION'          = "The first content inside <body> is not the `$navHtml substitution."
    'MALFORMED_BODY_CLOSE'              = "Content appears between the JS reference block and </body>."
    'MISSING_HEADER_BAR'                = "The page header bar is missing as the first content after `$navHtml."
    'FORBIDDEN_HARDCODED_PAGE_HEADER'   = "The page header content is hardcoded instead of the `$headerHtml PowerShell variable substitution."
    'MISSING_CONNECTION_BANNER'         = "The connection banner placeholder is missing."
    'FORBIDDEN_BANNER_CONTENT'          = "The connection banner placeholder contains content; it must be empty."

    # ---- Section 15.2: Page chrome codes (Wave 2/4) ----
    'MALFORMED_HEADER_BAR_CONTAINER'    = "The header bar's outer container is not <div class=`"header-bar`">."
    'MALFORMED_HEADER_BAR_LEFT'         = "The first child of header-bar is not the unattributed <div> containing the `$headerHtml substitution."
    'MALFORMED_HEADER_BAR_RIGHT'        = "The second child of header-bar is not <div class=`"header-right`">."
    'MALFORMED_HEADER_RIGHT_CHILDREN'   = "The header-right element contains children other than refresh-info and optional engine-row."
    'MALFORMED_REFRESH_INFO_CONTAINER'  = "The refresh info block's outer container is not <div class=`"refresh-info`">."
    'MALFORMED_LIVE_INDICATOR'          = "The live indicator span is malformed; expected <span class=`"live-indicator`"></span> exactly."
    'MALFORMED_LIVE_STATUS_LINE'        = "The live status line deviates from the mandated 'Live | Updated:' form."
    'MALFORMED_REFRESH_BUTTON'          = "The page refresh button markup deviates from mandated form (class, onclick, title, or entity reference)."
    'DUPLICATE_LAST_UPDATE_ID'          = "The last-update ID appears more than once on the page."
    'MALFORMED_ENGINE_ROW_CONTAINER'    = "The engine row's outer container is not <div class=`"engine-row`">."
    'MALFORMED_ENGINE_ROW_CHILDREN'     = "The engine row contains children other than engine cards."
    'ENGINE_CARD_ORDER_MISMATCH'        = "Engine cards are not in declaration order matching cc_sort_order."
    'MALFORMED_ENGINE_CARD'             = "An engine card's structure deviates from the mandated four-element block."
    'MALFORMED_ENGINE_CARD_ATTRIBUTES'  = "An engine card's attributes are malformed (class or ID)."
    'MALFORMED_ENGINE_LABEL'            = "An engine label span is malformed (class or text)."
    'MALFORMED_ENGINE_BAR'              = "An engine bar div is malformed (class or ID, or contains content)."
    'MALFORMED_ENGINE_COUNTDOWN'        = "An engine countdown span is malformed (class, ID, or content)."
    'MISSING_ENGINE_CARD_REGISTRATION'  = "An active scheduled process (run_mode = 1) has NULL values in cc_engine_slug, cc_engine_label, cc_page_route, or cc_sort_order."
    'UNEXPECTED_ENGINE_CARD_REGISTRATION' = "A queue processor process (run_mode = 2) has populated values in cc_engine_slug, cc_engine_label, cc_page_route, or cc_sort_order."
    'ENGINE_SLUG_REGISTRY_MISMATCH'     = "The slug used in card IDs doesn't match Orchestrator.ProcessRegistry.cc_engine_slug for the corresponding process."
    'ENGINE_LABEL_REGISTRY_MISMATCH'    = "The label text in the engine label span doesn't match Orchestrator.ProcessRegistry.cc_engine_label."
    'ENGINE_CARD_PAGE_MISMATCH'         = "An engine card appears on a page whose route doesn't match Orchestrator.ProcessRegistry.cc_page_route."

    # ---- Section 15.3: Asset reference codes (Wave 2) ----
    'MALFORMED_CSS_LINK'                = "A <link> element uses additional attributes beyond rel=`"stylesheet`" and href=`"...`", or has an incorrect form."
    'MALFORMED_PAGE_CSS_REFERENCE'      = "The page-specific CSS reference's href doesn't match /css/<page>.css form."
    'MALFORMED_SHARED_CSS_REFERENCE'    = "The shared CSS reference is not exactly <link rel=`"stylesheet`" href=`"/css/cc-shared.css`">."
    'CSS_REFERENCE_ORDER_VIOLATION'     = "The page-specific CSS reference does not appear before the shared reference."
    'UNEXPECTED_CSS_REFERENCE'          = "A page references more or fewer than two CSS files in <head>."
    'MALFORMED_JS_SCRIPT'               = "A <script> element uses additional attributes (e.g., defer, async) or has body content."
    'MALFORMED_PAGE_JS_REFERENCE'       = "The page-specific JS reference's src doesn't match /js/<page>.js form."
    'MALFORMED_SHARED_JS_REFERENCE'     = "The shared JS reference is not exactly <script src=`"/js/cc-shared.js`"></script>."
    'JS_REFERENCE_ORDER_VIOLATION'      = "The page-specific JS reference does not appear before the shared reference."
    'UNEXPECTED_JS_REFERENCE'           = "A page references more or fewer than two JS files in <body>."
    'JS_REFERENCE_NOT_LAST'             = "Content appears between the JS reference block and </body>."
    'FORBIDDEN_HELPER_ASSET_REFERENCE'  = "A helper module function emits a <link> or <script> element."

    # ---- Section 15.4: ID codes (Wave 2) ----
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
    'FORBIDDEN_HELPER_PAGE_PREFIX_ID'   = "A helper module function emits HTML with a page-prefixed ID."

    # ---- Section 15.5: Class attribute codes (Wave 2) ----
    'MALFORMED_CLASS_VALUE_WHITESPACE'  = "A class attribute value contains multiple consecutive spaces, leading/trailing whitespace, or tabs."
    'MALFORMED_CLASS_NAME'              = "A class name contains characters other than lowercase letters, digits, and hyphens."
    'DUPLICATE_CLASS_IN_VALUE'          = "The same class name appears more than once in the same class attribute."
    'CLASS_PREFIX_MISMATCH'             = "A class name doesn't begin with the page's cc_prefix and is not defined in cc-shared.css."
    'INLINE_CLASS_CONCATENATION'        = "A class attribute uses inline interpolation appended to static text (e.g., class=`"nav-link`$accent`")."
    'INLINE_CLASS_PREFIX_MIX'           = "A class attribute uses inline interpolation followed or preceded by static text (e.g., class=`"`$type wide`")."
    'INLINE_CLASS_MULTI_INTERPOLATION'  = "A class attribute uses multiple top-level interpolations without using the array-join pattern."
    'INLINE_CLASS_BRACED_INTERPOLATION' = "A class attribute uses PowerShell `${...} or `$(...) form mixed with static text."

    # ---- Section 15.6: Event handler codes (Wave 2) ----
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

    # ---- Section 15.7: data-* attribute codes (Wave 2) ----
    'MALFORMED_DATA_ATTRIBUTE_NAME'     = "A data-* attribute name contains characters other than lowercase letters, digits, and hyphens after the data- prefix."
    'FORBIDDEN_INLINE_DATA_INTERPOLATION' = "A data-* attribute value mixes static text with PowerShell interpolation."
    'FORBIDDEN_HELPER_PAGE_DATA_ATTRIBUTE' = "A helper module function emits a data-* attribute that is page-specific."

    # ---- Section 15.8: Text content codes (Wave 3) ----
    'MALFORMED_TEXT_INTERPOLATION'      = "Text content contains PowerShell variable interpolation that uses forbidden patterns from class attribute rules."
    'EMPTY_DISPLAY_TEXT'                = "A user-facing attribute (title, placeholder, aria-label, alt) is declared with an empty value."

    # ---- Section 15.9: SVG codes (Wave 3) ----
    'MALFORMED_SVG_INTERPOLATION'       = "An SVG element's outer markup contains forbidden interpolation patterns."

    # ---- Section 15.10: Comment codes (Wave 3) ----
    'MALFORMED_COMMENT_DASHES'          = "An HTML comment body contains '--' other than the closing -->."
    'FORBIDDEN_COMMENT_INTERPOLATION'   = "An HTML comment contains PowerShell variable interpolation."
    'MALFORMED_COMMENT_UNCLOSED'        = "An HTML comment's opening <!-- does not have a matching closing -->."

    # ---- Section 15.11: Inline asset block codes ----
    'FORBIDDEN_INLINE_STYLE_BLOCK'      = "A <style> block appears in HTML markup outside the access-denied page and SVG-internal carve-outs."
    'FORBIDDEN_INLINE_SCRIPT_BLOCK'     = "A <script> element contains body content (i.e., is not the asset reference form <script src=`"...`"></script>)."
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
$script:CurrentFile     = $null     # bare filename (e.g., 'BusinessServices.ps1')
$script:CurrentFullPath = $null     # full path (e.g., 'E:\xFACts-ControlCenter\scripts\routes\BusinessServices.ps1')

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
# fatal - the AST is still returned even when errors are present, and most
# CC PS files parse cleanly. Errors are logged as WARN so the operator can
# investigate; row emission for that file continues against the partial AST.
function Invoke-PsParse {
    param([Parameter(Mandatory)][string]$FilePath)

    try {
        $source = Get-Content -Path $FilePath -Raw -Encoding UTF8
        if (-not $source) { $source = '' }

        $tokens = $null
        $parseErrors = $null

        # ParseInput requires [ref] outputs for tokens and errors.
        # Using ParseInput instead of ParseFile lets us pass the source we
        # already have rather than having the parser re-read the file.
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
# POWERSHELL AST: HTML EMISSION DISCOVERY
# ============================================================================

# Two PS patterns emit HTML in the CC codebase:
#
#   1. Here-strings: a single (often very large) here-string assigned to a
#      variable, typically inside a route ScriptBlock. The HTML lives
#      verbatim between the @"..."@ delimiters with PowerShell variable
#      interpolation woven in. Detection: find every StringConstantExpressionAst
#      and ExpandableStringExpressionAst whose StringConstantType indicates
#      a here-string AND whose content begins with HTML markers.
#
#   2. StringBuilder append chains: a helper function instantiates a
#      System.Text.StringBuilder, then calls .AppendLine(...) or .Append(...)
#      repeatedly to build up the HTML piece by piece. Detection: find every
#      InvokeMemberExpressionAst whose member is AppendLine/Append/AppendFormat
#      and whose target is a variable; group these by (enclosing function,
#      target variable name); concatenate the argument string contents
#      preserving line positions of each append.
#
# Both patterns produce a logical "HTML emission" object with:
#   .Text         - the concatenated HTML markup
#   .StartLine    - source line where the emission begins
#   .EndLine      - source line where it ends
#   .FunctionName - enclosing PS function name, or '<route>' for route
#                   ScriptBlocks, or $null for top-level emissions
#   .Pattern      - 'HereString' or 'StringBuilder'
#   .NodeRef      - the AST node (here-string) or the first append call
#                   (StringBuilder); useful for diagnostics
#
# Wave 1 walks the AST once per file collecting both kinds. The two collections
# are merged into a single per-file list in source-line order.

# Look up the enclosing function name for an AST node by walking its parent
# chain. The PS AST exposes .Parent on every node; we walk upward until we
# hit a FunctionDefinitionAst (regular function), or until we hit a
# ScriptBlockExpressionAst that is the -ScriptBlock argument to Add-PodeRoute
# (route handler), or until we reach the top of the tree.
#
# Returns one of:
#   - 'Get-NavBarHtml' (or any other function name) - inside a function
#   - '<route:/business-services>' (or the route path) - inside an Add-PodeRoute scriptblock
#   - $null - at file scope, outside any function or route
function Get-EnclosingPsContext {
    param($Node)
    if ($null -eq $Node) { return $null }

    $cursor = $Node
    while ($null -ne $cursor) {
        # Regular function definition (helper functions in .psm1 files).
        if ($cursor -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
            return $cursor.Name
        }
        # Route ScriptBlock: a ScriptBlockExpressionAst whose parent is a
        # CommandExpressionAst whose parent is a CommandAst whose command
        # name is 'Add-PodeRoute'. We need the -Path parameter value.
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

# If the supplied ScriptBlockExpressionAst is the -ScriptBlock argument to
# an Add-PodeRoute call, return that call's -Path value. Otherwise return
# $null.
#
# Add-PodeRoute call shape:
#   Add-PodeRoute -Method Get -Path '/business-services' -ScriptBlock { ... }
#
# In the AST this is a CommandAst whose CommandElements include both the
# -Path StringConstantExpressionAst and the -ScriptBlock ScriptBlockExpressionAst.
# We climb from the scriptblock up to its enclosing CommandAst, verify the
# command name, then scan siblings for the -Path value.
function Get-AddPodeRoutePathForScriptBlock {
    param([Parameter(Mandatory)][System.Management.Automation.Language.ScriptBlockExpressionAst]$ScriptBlockAst)

    $parent = $ScriptBlockAst.Parent
    if ($null -eq $parent) { return $null }

    # The scriptblock can sit directly as a CommandElement, or be wrapped
    # in a CommandExpressionAst. Walk up to find a CommandAst.
    while ($null -ne $parent -and -not ($parent -is [System.Management.Automation.Language.CommandAst])) {
        $parent = $parent.Parent
        # Don't climb past the scriptblock's own scriptblock body; the
        # CommandAst we want is an immediate (or near-immediate) ancestor.
        if ($parent -is [System.Management.Automation.Language.ScriptBlockAst]) { return $null }
    }
    if ($null -eq $parent) { return $null }

    $cmd = $parent
    if ($cmd.CommandElements.Count -lt 1) { return $null }
    $cmdName = Get-CommandAstName -CommandAst $cmd
    if ($cmdName -ne 'Add-PodeRoute') { return $null }

    # Scan CommandElements for the -Path parameter value. CommandElements
    # is an ordered list where parameters appear as CommandParameterAst
    # immediately followed by their value expression.
    $elements = $cmd.CommandElements
    for ($i = 0; $i -lt $elements.Count; $i++) {
        $el = $elements[$i]
        if ($el -is [System.Management.Automation.Language.CommandParameterAst]) {
            if ($el.ParameterName -ieq 'Path') {
                # Value is either the next element (separated) or the
                # parameter's .Argument property (joined form like -Path:'/foo').
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

# Return the bare command name from a CommandAst. The first CommandElement
# is the command itself; we want its string text without quoting.
function Get-CommandAstName {
    param([Parameter(Mandatory)][System.Management.Automation.Language.CommandAst]$CommandAst)
    if ($CommandAst.CommandElements.Count -lt 1) { return $null }
    $first = $CommandAst.CommandElements[0]
    if ($first -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
        return $first.Value
    }
    # Some commands appear as bareword expressions; fall back to the extent text.
    return $first.Extent.Text
}

# Extract the literal string value from a StringConstantExpressionAst or
# ExpandableStringExpressionAst. Returns the Value property in both cases.
# For other expression kinds returns $null (we only catalog static paths).
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

# Content check: does this string look like an HTML emission?
#
# Wave 1.1 uses Option 3 (structural) instead of "any <letter" sniffing.
# The structural approach short-circuits on strong HTML-only signals
# (DOCTYPE, <html>, HTML comments, class=, id="lowercase...") and falls
# back to a structural test for any tag with a matching open/close pair.
#
# Why this matters: the previous "<[A-Za-z/!]" check matched SQL LIKE
# patterns that contained XML-like tokens like '%<SystemHealth>%' from
# sys.dm_os_ring_buffers queries. Those are SQL strings with one isolated
# <Name> substring and no </Name> counterpart. The structural test
# rejects them because there is no closing tag for any opener.
#
# Real HTML emissions always satisfy either a strong-signal check or the
# open/close pair check, because HTML markup is composed of nested
# elements. SQL strings with one or two XML-like LIKE patterns never have
# matching closers.
#
# An XML declaration ('<?xml version="1.0"?>...') is explicitly rejected
# even if it has open/close pairs - XML payloads should not be cataloged
# as HTML emissions.
function Test-LooksLikeHtmlEmission {
    param([string]$Text)
    if ($null -eq $Text) { return $false }
    if ($Text.Length -lt 16) { return $false }

    # Explicit rejection: XML payloads (declaration-led).
    if ($Text -match '^\s*<\?xml\b') { return $false }

    # Strong signals - any one is sufficient. SQL queries, XML embedded
    # in SQL strings, and JSON payloads essentially never have these.
    if ($Text -match '(?i)<!DOCTYPE\s+html')   { return $true }
    if ($Text -match '(?i)<html\b')            { return $true }
    if ($Text -match '(?im)^\s*<!--')          { return $true }
    if ($Text -match '\bclass\s*=\s*["'']')    { return $true }
    if ($Text -match '\bid\s*=\s*["''][a-z]')  { return $true }

    # Structural signal: at least two tag-like openers AND at least one
    # opening tag has a matching closing tag of the same name somewhere
    # in the string. Real HTML markup always has open/close pairs because
    # elements nest. SQL LIKE patterns and lone XML tokens do not.
    $openTags = [regex]::Matches($Text, '<([a-zA-Z][a-zA-Z0-9]*)\b')
    if ($openTags.Count -lt 2) { return $false }

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

# Walk the AST and collect HereString-style HTML emissions. Returns a list
# of [ordered] hashtables, one per emission.
function Get-HereStringEmissions {
    param(
        [Parameter(Mandatory)]$Ast
    )

    $emissions = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Ast) { return $emissions }

    # FindAll: walk the entire AST tree, predicate $true = match all, $true =
    # also descend into nested ScriptBlocks. We're filtering by node type
    # ourselves in the visit body.
    $allStrings = $Ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
        $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst]
    }, $true)

    foreach ($node in $allStrings) {
        # StringConstantType discriminates string kinds. The two here-string
        # values are 'BareWord'/'SingleQuoted'/'DoubleQuoted'/'SingleQuotedHereString'/'DoubleQuotedHereString'.
        # We only catalog here-strings since regular quoted strings inside PS
        # are too short and incidental to be HTML emissions.
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

# Walk the AST and collect StringBuilder-style HTML emissions. The pattern
# is:
#
#   $sb = [System.Text.StringBuilder]::new()
#   [void]$sb.AppendLine("...")
#   [void]$sb.AppendLine("...")
#   ...
#   return $sb.ToString()
#
# Detection strategy: find every InvokeMemberExpressionAst whose member name
# is AppendLine/Append/AppendFormat and whose Expression is a VariableExpressionAst.
# Group by (enclosing function, variable name). Within each group, sort by
# source line; concatenate argument string contents preserving line offsets
# so the emission's text matches what would be rendered at runtime.
#
# An emission's "function" is required (StringBuilder-built HTML at module
# scope without a function context is unusual and unlikely to be meaningful
# HTML; we skip it). Returns one emission object per (function, variable)
# group whose concatenated text passes the HTML content-sniff.
function Get-StringBuilderEmissions {
    param(
        [Parameter(Mandatory)]$Ast
    )

    $emissions = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Ast) { return $emissions }

    # Find every method-call AST node. PowerShell models obj.Method() as
    # InvokeMemberExpressionAst.
    $allInvokes = $Ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst]
    }, $true)

    # Group calls into per-(function, variable) buckets. The bucket key is
    # "function|variable". Order within a bucket is source-line ascending.
    $buckets = @{}

    foreach ($inv in $allInvokes) {
        # Member name: only StringBuilder-shaped append methods.
        if ($null -eq $inv.Member) { continue }
        $memberName = $null
        if ($inv.Member -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
            $memberName = $inv.Member.Value
        }
        if ([string]::IsNullOrEmpty($memberName)) { continue }
        if ($memberName -notin @('AppendLine','Append','AppendFormat')) { continue }

        # Target expression: must be a variable reference.
        if (-not ($inv.Expression -is [System.Management.Automation.Language.VariableExpressionAst])) { continue }
        $varName = $inv.Expression.VariablePath.UserPath
        if ([string]::IsNullOrEmpty($varName)) { continue }

        # Enclosing function name.
        $context = Get-EnclosingPsContext -Node $inv
        if ([string]::IsNullOrEmpty($context)) { continue }

        # First argument: the string being appended. Only string-expression
        # arguments are catalogable. Non-string arguments (e.g., computed
        # expressions) emit nothing.
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

    # For each bucket, build the emission's concatenated text. Sort by
    # source line so the concatenation order matches runtime emission order.
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

        # Final HTML content-sniff on the concatenated text.
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

# Combined emission discovery: here-strings + StringBuilder, merged in
# source-line order. Returns one list per file.
function Get-HtmlEmissions {
    param(
        [Parameter(Mandatory)]$Ast
    )
    $hereStrings    = @(Get-HereStringEmissions -Ast $Ast)
    $stringBuilders = @(Get-StringBuilderEmissions -Ast $Ast)
    $combined = New-Object System.Collections.Generic.List[object]
    foreach ($e in $hereStrings)    { [void]$combined.Add($e) }
    foreach ($e in $stringBuilders) { [void]$combined.Add($e) }
    # Sort in source order so emissions appear top-to-bottom as they would
    # be read in the source file.
    return @($combined | Sort-Object { $_.StartLine })
}

# ============================================================================
# POWERSHELL AST: ROUTE DISCOVERY
# ============================================================================

# Find every Add-PodeRoute call in a file and return a list of:
#   .Path        - the -Path parameter's literal string value
#   .Method      - the -Method parameter's value (Get/Post/etc.), or 'Get' default
#   .ScriptBlock - the ScriptBlockExpressionAst for the handler body
#   .StartLine   - source line of the Add-PodeRoute call
#
# Used to (1) populate HTML_FILE row's component_name for route files, and
# (2) Wave 4's ProcessRegistry cross-validation that engine cards on a given
# page route match the cc_page_route registered in ProcessRegistry.
function Get-PodeRoutes {
    param(
        [Parameter(Mandatory)]$Ast
    )

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
# Wave 1's tokenizer recognizes the structural shape of an HTML emission at
# a level sufficient to validate page-shell rules. Subsequent waves will
# layer more detail on top of these primitives without rewriting them.
#
# The tokenizer treats PowerShell interpolation tokens as first-class
# atoms:
#   $varName          - simple variable reference
#   $($expr)          - parenthesized expression interpolation
#   ${name}           - braced variable interpolation
# Each becomes a separate token of kind 'PsInterp' carrying its raw form
# verbatim. The tokenizer does NOT evaluate them - it preserves them so
# downstream consumers (Wave 2's class/id extractors, the page-shell
# checker, etc.) can detect specific substitutions like $navHtml or
# $headerHtml by exact match.
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
#                 the StartTag's .Attributes array)
#
# Tokens carry source-relative position info:
#   .LineOffset  - 0-based line offset from the emission's first line
#   .ColumnStart - 1-based column on that line
#
# This is sufficient for Wave 1 (which uses tokens only to walk the page-
# shell shape). Wave 2 will extend tag tokens with attribute records and
# parent-stack tracking; the basic tokenizer API stays stable.

function ConvertTo-HtmlTokens {
    param(
        [Parameter(Mandatory)][string]$Text
    )

    $tokens = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrEmpty($Text)) { return $tokens }

    # Position tracking: $i is the current character index; ($line, $col)
    # track 0-based line offset and 1-based column on that line.
    $i = 0
    $n = $Text.Length
    $line = 0
    $col = 1

    # Helper local: advance position by one character, updating line/col.
    # PowerShell scripts can't define local helpers cleanly inside other
    # functions, so this uses inline logic at each consumption site. The
    # pattern is consistent below.

    # Helper local: extract a substring of length k starting at position p
    # without crashing past end of string.
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
                # Unclosed comment. Token captures everything to end-of-input
                # plus a flag the caller (Wave 3) can read.
                $body = $Text.Substring($i)
                $tokens.Add([ordered]@{
                    Kind        = 'Comment'
                    Raw         = $body
                    Body        = $body.Substring(4)
                    LineOffset  = $startLine
                    ColumnStart = $startCol
                    Unclosed    = $true
                })
                # Advance to end of input.
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
            # Advance over the comment, updating line/col for each character.
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
                # Malformed: missing '>'. Treat everything to end as the doctype.
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
                # Malformed end tag; treat as raw text and keep walking
                # past one character so we don't loop forever.
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
            # Extract bare tag name: strip leading '</' and trailing '>', trim.
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
        # We require an ASCII letter immediately after '<' to qualify as a tag.
        # This prevents things like '< 5' (a literal less-than) from being
        # misread as a malformed tag.
        if ($ch -eq '<' -and ($i + 1) -lt $n -and ($Text[$i + 1] -match '[A-Za-z]')) {
            $startLine = $line
            $startCol  = $col

            # Find end of tag, respecting attribute values that contain '>'
            # inside quoted strings.
            $j = $i + 1
            $inQuote = $null  # null, "'", or '"'
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
                # Unclosed tag; treat as raw text and stop trying to tag-parse.
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

            # Self-close detection: tag body (between the leading '<' and
            # trailing '>') ends with '/' after optional whitespace.
            $inner = $raw.Substring(1, $raw.Length - 2)  # strip '<' and '>'
            $isSelfClose = $inner -match '/\s*$'
            if ($isSelfClose) {
                $inner = $inner.Substring(0, $inner.Length - ($inner.Length - $inner.TrimEnd().Length) - 1).TrimEnd()
            }

            # Extract bare tag name (first whitespace-or-end-delimited token).
            $tagName = $inner
            $wsIdx = $inner.IndexOfAny(@(' ', "`t", "`n", "`r"))
            if ($wsIdx -ge 0) { $tagName = $inner.Substring(0, $wsIdx) }
            $tagName = $tagName.Trim().ToLower()

            # Attribute text region: everything after the tag name. Wave 2
            # will parse this into structured attribute records; Wave 1
            # carries it verbatim on the token so consumers can do regex
            # matches for specific attributes (class, id, etc.).
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

        # ---- PowerShell interpolation: $variableName ----
        # Two forms here: bare-word ($navHtml, $headerHtml) and ${...}.
        # The $(...) form is handled in the more general branch below.
        if ($ch -eq '$' -and ($i + 1) -lt $n) {
            $next = $Text[$i + 1]
            # ${name}
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
                    continue
                }
            }
            # $(...) - paren-balanced
            if ($next -eq '(') {
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
                    continue
                }
            }
            # $bareword
            if ($next -match '[A-Za-z_]') {
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
                continue
            }
            # Lone '$' followed by something else - treat as literal text.
        }

        # ---- Text: anything else, accumulated until next special character ----
        $startLine = $line
        $startCol  = $col
        $textStart = $i
        while ($i -lt $n) {
            $c2 = $Text[$i]
            if ($c2 -eq '<') { break }
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
        # Loop continues without manual increment because the inner while
        # already advanced past every consumed character.
    }

    return $tokens
}

# ============================================================================
# PAGE-SHELL VALIDATION
# ============================================================================
#
# Wave 1's primary catalog output is the HTML_FILE row plus its page-shell
# drift codes. The validation runs only on route files (helpers don't have
# page shells). The function returns a list of drift codes to attach to
# the route's HTML_FILE row.
#
# Validation strategy: walk the token stream once, recognize the structural
# landmarks (DOCTYPE, <html>, <head>, <title>, <link>, <body>, <script>,
# nav substitution, header bar, refresh button, connection banner placeholder,
# end-of-body), and emit drift codes for each landmark that's missing or
# malformed.
#
# Wave 1 covers exactly the Section 15.1 codes:
#   MALFORMED_DOCTYPE, MALFORMED_HTML_ROOT, MALFORMED_HEAD,
#   FORBIDDEN_HARDCODED_TITLE, MISSING_BODY_SECTION_CLASS,
#   MISSING_NAV_SUBSTITUTION, MALFORMED_BODY_CLOSE, MISSING_HEADER_BAR,
#   FORBIDDEN_HARDCODED_PAGE_HEADER, MISSING_CONNECTION_BANNER,
#   FORBIDDEN_BANNER_CONTENT
#
# Section 15.2 (page-chrome codes), 15.3 (asset-reference codes), and the
# remaining sections are Wave 2+ scope. The HTML_FILE row provides the
# attachment site for those future codes.

# Find the first token whose Kind matches and whose predicate returns $true.
# Returns the token index, or -1 if not found.
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

# Return the next "significant" token index from $StartAt, skipping
# whitespace-only Text tokens. Whitespace between structural elements is
# not catalog-meaningful for page-shell validation; tabs/newlines/spaces
# can appear anywhere without forming drift.
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

# Check whether a token's StartTag attribute text contains a specific
# attribute=value match. Used for body's section class, head children, etc.
function Test-AttrTextMatches {
    param(
        [string]$AttrText,
        [string]$Pattern
    )
    if ([string]::IsNullOrEmpty($AttrText)) { return $false }
    return $AttrText -match $Pattern
}

# Get the page-shell drift codes for a route file's tokenized HTML. Returns
# an array of drift-code strings.
function Get-PageShellDrift {
    param(
        [Parameter(Mandatory)]$Tokens
    )

    $codes = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Tokens -or $Tokens.Count -eq 0) {
        # An empty token stream for a route file is unusual but means none
        # of the page-shell landmarks can be located. Emit all
        # required-element codes.
        [void]$codes.Add('MALFORMED_DOCTYPE')
        [void]$codes.Add('MISSING_NAV_SUBSTITUTION')
        [void]$codes.Add('MISSING_HEADER_BAR')
        [void]$codes.Add('MISSING_CONNECTION_BANNER')
        return $codes.ToArray()
    }

    # ---- DOCTYPE ----
    # The first significant token must be a Doctype token whose Raw text is
    # exactly '<!DOCTYPE html>' or '<!doctype html>' (case-uniform). Mixed
    # case ('<!DocType html>') is forbidden per Section 1.2.
    $firstSigIdx = Find-NextSignificantToken -Tokens $Tokens -StartAt 0
    $doctypeIdx = -1
    if ($firstSigIdx -ge 0 -and $Tokens[$firstSigIdx].Kind -eq 'Doctype') {
        $doctypeIdx = $firstSigIdx
        $rawDt = $Tokens[$doctypeIdx].Raw.Trim()
        # Check exact case-uniform form. Strip outer whitespace then test.
        $isAllUpper = ($rawDt -ceq '<!DOCTYPE html>')
        $isAllLower = ($rawDt -ceq '<!doctype html>')
        if (-not ($isAllUpper -or $isAllLower)) {
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
    # Missing <html> is not an explicit Section 15.1 code; if absent, the
    # downstream landmarks will fire their own missing-element codes.

    # ---- <head> contents: exactly <title> + <link> ----
    $headStartIdx = Find-TokenIndex -Tokens $Tokens -Kind 'StartTag' `
        -Predicate { param($t) $t.TagName -eq 'head' }
    $headEndIdx = -1
    if ($headStartIdx -ge 0) {
        $headEndIdx = Find-TokenIndex -Tokens $Tokens -Kind 'EndTag' `
            -Predicate { param($t) $t.TagName -eq 'head' } `
            -StartAt $headStartIdx
    }
    if ($headStartIdx -ge 0 -and $headEndIdx -gt $headStartIdx) {
        $titleStartIdx = -1
        $hasMalformedChild = $false
        $hasHardcodedTitle = $false

        for ($i = $headStartIdx + 1; $i -lt $headEndIdx; $i++) {
            $t = $Tokens[$i]
            if ($t.Kind -eq 'Text' -and [string]::IsNullOrWhiteSpace($t.Raw)) { continue }
            if ($t.Kind -eq 'StartTag') {
                if ($t.TagName -eq 'title') {
                    $titleStartIdx = $i
                    # Look at the next significant token inside <title>.
                    $titleEndIdx = Find-TokenIndex -Tokens $Tokens -Kind 'EndTag' `
                        -Predicate { param($x) $x.TagName -eq 'title' } `
                        -StartAt $i
                    if ($titleEndIdx -gt $i) {
                        # The title body should be exactly a $browserTitle PsInterp.
                        # Anything else is hardcoded title content.
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
                    # Advance past this title block.
                    $i = $titleEndIdx
                    continue
                }
                if ($t.TagName -eq 'link') {
                    # Wave 2 will validate the link attributes; here we just
                    # accept its presence as a valid <head> child.
                    continue
                }
                # Any other element in <head> is malformed (style/meta/script).
                $hasMalformedChild = $true
                continue
            }
            if ($t.Kind -eq 'SelfClose') {
                if ($t.TagName -eq 'link') { continue }
                $hasMalformedChild = $true
                continue
            }
            if ($t.Kind -eq 'Comment') {
                # Comments in <head> are tolerated; Section 15.1 doesn't list
                # a MALFORMED_HEAD code for them.
                continue
            }
            if ($t.Kind -eq 'PsInterp') {
                # PowerShell interpolation directly inside <head> outside any
                # element is not expected; treat as malformed.
                $hasMalformedChild = $true
                continue
            }
        }

        if ($hasMalformedChild) {
            [void]$codes.Add('MALFORMED_HEAD')
        }
        if ($hasHardcodedTitle) {
            [void]$codes.Add('FORBIDDEN_HARDCODED_TITLE')
        }
    }

    # ---- <body class="section-..."> ----
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

    # ---- Page header bar: first content after $navHtml must be <div class="header-bar"> ----
    $headerBarFound = $false
    $hardcodedPageHeader = $false
    if ($bodyStartIdx -ge 0) {
        # Locate the $navHtml token (if present) and step forward from there.
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
                # Check whether $headerHtml appears anywhere inside header-bar's
                # content. The header-bar div should contain exactly one
                # $headerHtml substitution; anything else is hardcoded.
                $hbStart = $afterNav
                $hbEnd = Find-TokenIndex -Tokens $Tokens -Kind 'EndTag' `
                    -Predicate { param($x) $x.TagName -eq 'div' } -StartAt $hbStart
                # The Wave 1 header-content check is shallow: if no
                # $headerHtml PsInterp appears between header-bar's open and
                # its first nested close, fire the hardcoded code. A more
                # precise check (with nested div tracking) lands in Wave 2.
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
    # Find any StartTag where TagName=div and AttrText contains id="connection-banner"
    # AND class="connection-banner". Check whether its body is empty.
    $banners = @()
    for ($k = 0; $k -lt $Tokens.Count; $k++) {
        $t = $Tokens[$k]
        if ($t.Kind -ne 'StartTag') { continue }
        if ($t.TagName -ne 'div') { continue }
        $isBanner = (Test-AttrTextMatches -AttrText $t.AttrText -Pattern 'id\s*=\s*["'']connection-banner["'']')
        if ($isBanner) { $banners += $k }
    }
    if ($banners.Count -eq 0) {
        [void]$codes.Add('MISSING_CONNECTION_BANNER')
    } else {
        # Verify each banner placeholder is empty. The first banner div's
        # matching close tag should follow with no significant content
        # between. If the placeholder is a SelfClose (<div ... />) it's
        # trivially empty.
        foreach ($bIdx in $banners) {
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
                break  # one drift is enough; downstream multi-banner is itself drift
            }
        }
    }

    # ---- JS reference block must be last inside <body> ----
    # Find the last StartTag whose TagName is 'script' inside <body>; verify
    # that nothing other than the script tags themselves appears between
    # that block and </body>. Wave 1's check is coarse: scan from the LAST
    # script tag inside body forward to </body> and flag any significant
    # non-script content.
    if ($bodyStartIdx -ge 0 -and $bodyEndIdx -gt $bodyStartIdx) {
        $lastScriptIdx = -1
        for ($k = $bodyStartIdx + 1; $k -lt $bodyEndIdx; $k++) {
            $t = $Tokens[$k]
            if (($t.Kind -eq 'StartTag' -or $t.Kind -eq 'SelfClose') -and $t.TagName -eq 'script') {
                $lastScriptIdx = $k
            }
        }
        if ($lastScriptIdx -ge 0) {
            # Find the close tag of that last script (if it's a start tag).
            $lastScriptClose = $lastScriptIdx
            if ($Tokens[$lastScriptIdx].Kind -eq 'StartTag') {
                $lastScriptClose = Find-TokenIndex -Tokens $Tokens -Kind 'EndTag' `
                    -Predicate { param($x) $x.TagName -eq 'script' } -StartAt $lastScriptIdx
                if ($lastScriptClose -lt 0) { $lastScriptClose = $lastScriptIdx }
            }
            # Anything significant between $lastScriptClose and $bodyEndIdx is drift.
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
# ATTRIBUTE PARSER (Wave 2)
# ============================================================================
#
# The tokenizer in Wave 1 captures every StartTag/SelfClose token's attribute
# region as a single verbatim string in $token.AttrText. Wave 2 needs to
# break that string into structured attribute records so the row emitters
# can address individual attributes by name (id, class, data-*, on*, href,
# src, title, placeholder, aria-label, alt, etc.).
#
# Each attribute record produced by Get-AttributesFromToken has:
#   .Name        - the attribute name lowercased (e.g., 'class', 'data-spid',
#                  'onclick'). Attribute names are case-insensitive in HTML;
#                  the catalog stores the lowercase form.
#   .Value       - the attribute's value with any surrounding quotes stripped.
#                  When the source uses no quotes (a bare-token value), the
#                  raw token is captured. Empty-string values are preserved
#                  (e.g., title="" comes through as Value=''; that's an
#                  intentional Wave 2.1 drift signal per spec Section 8.6).
#   .Quote       - the quote character used in source ('"', "'", or null
#                  for unquoted values). Useful for drift-code attachment
#                  later (e.g., a class value with single quotes is non-
#                  conventional but not technically drift).
#   .HasInterp   - true when the value contains PowerShell interpolation
#                  tokens ($var, ${name}, or $(expr)). Drives the
#                  has_dynamic_content flag on emitted rows per spec
#                  Section 5.5 and the FORBIDDEN_INLINE_*_INTERPOLATION
#                  drift codes that Wave 2.1 will attach.
#   .RawValue    - the verbatim value as it appeared in source, including
#                  surrounding quotes. Useful for signature fields that
#                  carry the literal attribute as-written.
#
# The parser walks the AttrText character by character because PowerShell's
# regex engine can't reliably handle attribute values that mix quoted strings
# with PowerShell interpolation containing nested parens. The walker tracks
# quote state and PS-interpolation balance so an attribute value like
#   href="$($section.route)"
# is correctly captured as a single value with $(...) preserved inside.

function Get-AttributesFromToken {
    param(
        [Parameter(Mandatory)][string]$AttrText
    )

    $attrs = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrWhiteSpace($AttrText)) { return $attrs }

    $text = $AttrText
    $n = $text.Length
    $i = 0

    while ($i -lt $n) {
        # Skip leading whitespace between attributes
        while ($i -lt $n -and $text[$i] -match '\s') { $i++ }
        if ($i -ge $n) { break }

        # Extract attribute name: letters/digits/hyphen/colon/underscore.
        # Stop at whitespace, '=', or end.
        $nameStart = $i
        while ($i -lt $n) {
            $ch = $text[$i]
            if ($ch -match '\s' -or $ch -eq '=' -or $ch -eq '/' -or $ch -eq '>') { break }
            $i++
        }
        if ($i -eq $nameStart) {
            # No name found - treat the remaining text as junk and stop.
            break
        }
        $attrName = $text.Substring($nameStart, $i - $nameStart).ToLower()

        # Skip whitespace before '=' (or before next attr if value-less)
        while ($i -lt $n -and $text[$i] -match '\s') { $i++ }

        # Value-less attribute (e.g., disabled, checked, readonly).
        # HTML allows these but CC HTML rarely uses them. We capture them
        # with Value = $null and continue.
        if ($i -ge $n -or $text[$i] -ne '=') {
            $attrs.Add([ordered]@{
                Name      = $attrName
                Value     = $null
                Quote     = $null
                HasInterp = $false
                RawValue  = $null
            })
            continue
        }

        # Consume '=' and any whitespace after it
        $i++  # skip '='
        while ($i -lt $n -and $text[$i] -match '\s') { $i++ }
        if ($i -ge $n) {
            $attrs.Add([ordered]@{
                Name      = $attrName
                Value     = ''
                Quote     = $null
                HasInterp = $false
                RawValue  = ''
            })
            break
        }

        # Determine quote style and find the value boundary.
        $quote = $null
        $first = $text[$i]
        if ($first -eq '"' -or $first -eq "'") {
            $quote = $first
            $valStart = $i + 1  # skip opening quote
            $i++
            # Walk to the closing quote, respecting PS interpolation.
            $parenDepth = 0
            $braceDepth = 0
            while ($i -lt $n) {
                $ch = $text[$i]
                # PS $(...) tracking
                if ($ch -eq '$' -and ($i + 1) -lt $n -and $text[$i + 1] -eq '(') {
                    $parenDepth++
                    $i += 2
                    continue
                }
                if ($parenDepth -gt 0 -and $ch -eq '(') { $parenDepth++; $i++; continue }
                if ($parenDepth -gt 0 -and $ch -eq ')') { $parenDepth--; $i++; continue }
                # PS ${...} tracking
                if ($ch -eq '$' -and ($i + 1) -lt $n -and $text[$i + 1] -eq '{') {
                    $braceDepth++
                    $i += 2
                    continue
                }
                if ($braceDepth -gt 0 -and $ch -eq '{') { $braceDepth++; $i++; continue }
                if ($braceDepth -gt 0 -and $ch -eq '}') { $braceDepth--; $i++; continue }
                # Inside PS interpolation, the closing quote does not end the value
                if (($parenDepth -gt 0 -or $braceDepth -gt 0)) { $i++; continue }
                # Closing quote found
                if ($ch -eq $quote) { break }
                $i++
            }
            $valEnd = $i  # position of closing quote (or end of text)
            $value = $text.Substring($valStart, [Math]::Min($valEnd, $n) - $valStart)
            $rawValue = $quote + $value + $(if ($valEnd -lt $n) { $quote } else { '' })
            if ($i -lt $n) { $i++ }  # consume closing quote
        } else {
            # Unquoted value: read until whitespace, '/', or '>'.
            $valStart = $i
            while ($i -lt $n) {
                $ch = $text[$i]
                if ($ch -match '\s' -or $ch -eq '/' -or $ch -eq '>') { break }
                $i++
            }
            $value = $text.Substring($valStart, $i - $valStart)
            $rawValue = $value
        }

        # Detect PowerShell interpolation anywhere in the value
        $hasInterp = ($value -match '\$\(' -or $value -match '\$\{' -or $value -match '\$[A-Za-z_]')

        $attrs.Add([ordered]@{
            Name      = $attrName
            Value     = $value
            Quote     = $quote
            HasInterp = $hasInterp
            RawValue  = $rawValue
        })
    }

    return $attrs
}

# Convenience: return the first attribute matching a name, or $null. Names
# are compared case-insensitively (the parser already lowercases them).
function Get-AttributeByName {
    param(
        [Parameter(Mandatory)]$Attrs,
        [Parameter(Mandatory)][string]$Name
    )
    $lower = $Name.ToLower()
    foreach ($a in $Attrs) {
        if ($a.Name -eq $lower) { return $a }
    }
    return $null
}

# ============================================================================
# CLASS-NAME SPLITTING (Wave 2)
# ============================================================================
#
# Per CC_HTML_Spec.md Section 5.1, a class attribute value contains zero or
# more class names separated by single spaces. The HTML populator emits one
# CSS_CLASS USAGE row per class name in the attribute.
#
# Dynamic class values per Section 5.2 use PowerShell interpolation. The
# spec mandates the "array-join" pattern (a single $cssClasses substitution
# that holds the runtime-built class list). The populator drops the
# interpolation tokens before splitting so static class names survive
# extraction. This mirrors the JS populator's Split-ClassNames helper
# (xFACts-PowerShell/Populate-AssetRegistry-JS.ps1).
#
# Returns the list of static class names found in the value. Returns an
# empty array when the value is null, empty, or contains only interpolation.

function Split-StaticClassTokens {
    param([string]$Value)

    if ([string]::IsNullOrEmpty($Value)) { return @() }

    # Drop PS interpolation tokens before splitting.
    $cleaned = $Value
    $cleaned = [regex]::Replace($cleaned, '\$\([^)]*\)', ' ')   # $(...)
    $cleaned = [regex]::Replace($cleaned, '\$\{[^}]*\}', ' ')   # ${...}
    $cleaned = [regex]::Replace($cleaned, '\$[A-Za-z_][A-Za-z0-9_]*', ' ')  # $var

    # Split on whitespace and drop empties.
    $tokens = @($cleaned -split '\s+' | Where-Object { $_ -and $_ -ne '' })
    return $tokens
}

# ============================================================================
# EVENT HANDLER NAME EXTRACTION (Wave 2)
# ============================================================================
#
# Per CC_HTML_Spec.md Section 6.1, an event handler attribute value contains
# exactly one function call. Wave 2 extracts the called function's name and
# emits one JS_FUNCTION USAGE row per handler attribute.
#
# Wave 2 is permissive: any handler value matching the pattern "name(...)"
# at the start of the value produces a USAGE row. Drift codes for malformed
# handlers (multiple statements, conditional logic, missing parens, etc.)
# are deferred to Wave 2.1, where each kind of malformation gets its own
# code from Section 15.6.
#
# The function name is the first identifier-shaped token followed by an
# opening parenthesis. Whitespace between the name and '(' is permitted
# here (Wave 2.1 will attach MALFORMED_HANDLER_CALL when present).

function Get-FunctionNameFromHandler {
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return $null }

    # Allow optional leading whitespace before the function name.
    if ($Value -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*\(') {
        return $matches[1]
    }
    return $null
}

# Detect dotted-method calls in event handler values (e.g.,
# "Module.func()", "window.location.href = ...", "event.stopPropagation()").
# Wave 2 captures the leftmost-dotted-name as a JS_FUNCTION USAGE row when
# present so the construct is cataloged; Wave 2.1 will attach the
# FORBIDDEN_REVEALING_MODULE_CALL / FORBIDDEN_BUILTIN_METHOD_CALL /
# FORBIDDEN_EVENT_METHOD_CALL drift codes from spec Section 6.

function Get-DottedCallFromHandler {
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return $null }
    if ($Value -match '^\s*([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)+)\s*\(') {
        return $matches[1]
    }
    return $null
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

# Emit the HTML_FILE anchor row for the current file. Exactly one row per
# host file with HTML emission, regardless of how many Add-PodeRoute calls
# the file contains.
#
# HTML_FILE is HTML's file-level anchor row, parallel to CSS_FILE / JS_FILE
# in the CSS / JS populators. HTML does not emit a companion FILE_HEADER
# row because HTML markup has no file-header construct; the host PS file's
# header block will be cataloged separately by the future PS populator
# (file_type = 'PS').
#
# Scope is derived from Object_Registry classification:
#   Route, API -> LOCAL  (page-specific)
#   Module     -> SHARED (shared helpers)
#   <unknown>  -> LOCAL  (conservative default; file isn't registered yet
#                         so we can't tell, but most unregistered files
#                         are likely to be new Route files in progress)
#
# RoutePaths captures every Add-PodeRoute -Path discovered in the file as a
# pipe-joined string on raw_text. This stays attached to the row so Wave 4's
# ProcessRegistry cross-checks have access to the routes a file registers
# without re-walking the AST. For non-Route files (no Add-PodeRoute calls),
# pass an empty array.
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

# ============================================================================
# ROW EMITTERS (Wave 2 - per-construct rows)
# ============================================================================

# Add an HTML_ID DEFINITION row. Per CC_HTML_Spec.md Section 13.2 and 14,
# every id="..." attribute produces one row, with the literal ID value as
# component_name.
#
# Scope on HTML_ID rows is always LOCAL: page-local IDs scope to a single
# page, and chrome IDs (last-update, connection-banner, card-engine-*,
# engine-bar-*, engine-cd-*) exist on multiple pages but each declaration
# is page-local. The catalog distinguishes chrome from page-local via
# component_name pattern matching at query time.

function Add-HtmlIdRow {
    param(
        [Parameter(Mandatory)][string]$IdValue,
        [Parameter(Mandatory)][int]$LineStart,
        [Parameter(Mandatory)][int]$ColumnStart,
        [string]$Signature,
        [string]$ParentFunction,
        [string]$RawText,
        [Nullable[bool]]$HasDynamicContent = $null
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
        -HasDynamicContent  $HasDynamicContent
    $script:rows.Add($row)
    return $row
}

# Add an HTML_DATA_ATTRIBUTE DEFINITION row. Per spec Section 7.3, every
# data-* attribute declaration produces one row, with the full attribute
# name (including the data- prefix) as component_name.
#
# Scope: LOCAL for page-emitted attributes; SHARED for helper-emitted
# attributes per spec Section 7.5. The caller passes the appropriate scope.

function Add-HtmlDataAttributeRow {
    param(
        [Parameter(Mandatory)][string]$AttrName,
        [Parameter(Mandatory)][ValidateSet('LOCAL','SHARED')][string]$Scope,
        [Parameter(Mandatory)][int]$LineStart,
        [Parameter(Mandatory)][int]$ColumnStart,
        [string]$Signature,
        [string]$ParentFunction,
        [string]$RawText,
        [Nullable[bool]]$HasDynamicContent = $null
    )
    if ([string]::IsNullOrWhiteSpace($AttrName)) { return $null }

    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|HTML_DATA_ATTRIBUTE|$AttrName|DEFINITION|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $row = New-HtmlRow `
        -ComponentType      'HTML_DATA_ATTRIBUTE' `
        -ComponentName      $AttrName `
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
    $script:rows.Add($row)
    return $row
}

# Add a CSS_CLASS USAGE row. Per spec Section 5.3, every class name in
# every class="..." attribute produces one row. Scope and source_file
# resolve against the cross-population CSS_CLASS DEFINITION rows loaded
# at populator startup.
#
# component_name = the class name; signature = the full attribute value
# (so cross-class-combination queries are possible per spec Section 5.3).
# has_dynamic_content is true when the source attribute contained any
# PS interpolation tokens, per spec Section 5.5.

function Add-CssClassUsageRow {
    param(
        [Parameter(Mandatory)][string]$ClassName,
        [Parameter(Mandatory)][int]$LineStart,
        [Parameter(Mandatory)][int]$ColumnStart,
        [string]$Signature,
        [string]$ParentFunction,
        [string]$RawText,
        [Nullable[bool]]$HasDynamicContent = $null
    )
    if ([string]::IsNullOrWhiteSpace($ClassName)) { return $null }

    # Cross-population resolution against CSS_CLASS DEFINITION rows.
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
    $script:rows.Add($row)
    return $row
}

# Add a JS_FUNCTION USAGE row from an event handler attribute. Per spec
# Section 6.5, every event handler attribute produces one JS_FUNCTION
# USAGE row identifying the function the handler calls.
#
# component_name = the function name extracted from the handler value;
# signature = the full attribute (e.g., 'onclick="bsv_openSlideout(123)"').
# Scope resolution against existing JS_FUNCTION DEFINITION rows is best-
# effort: per the populator pipeline order (CSS -> HTML -> JS), JS
# DEFINITIONs may not exist yet at HTML scan time. When the JS populator
# runs afterward, it resolves its USAGE rows against HTML's DEFINITION
# rows (HTML_ID, HTML_DATA_ATTRIBUTE), and the resolution direction
# closes the loop.

function Add-JsFunctionUsageRow {
    param(
        [Parameter(Mandatory)][string]$FunctionName,
        [Parameter(Mandatory)][int]$LineStart,
        [Parameter(Mandatory)][int]$ColumnStart,
        [string]$Signature,
        [string]$ParentFunction,
        [string]$RawText,
        [Nullable[bool]]$HasDynamicContent = $null
    )
    if ([string]::IsNullOrWhiteSpace($FunctionName)) { return $null }

    # Cross-population resolution against JS_FUNCTION DEFINITION rows
    # (best-effort; unresolved when JS hasn't run yet).
    $resolved = Resolve-JsFunctionScope -FunctionName $FunctionName

    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|JS_FUNCTION|$FunctionName|USAGE|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $row = New-HtmlRow `
        -ComponentType      'JS_FUNCTION' `
        -ComponentName      $FunctionName `
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
    $script:rows.Add($row)
    return $row
}

# Add a CSS_FILE USAGE row from a <link rel="stylesheet" href="..."> tag.
# Per spec Section 3.1.1, every CSS file reference produces one row.
# Scope resolves against the catalog's CSS_FILE DEFINITION rows
# (currently the CSS populator emits these for every .css file it scans).

function Add-CssFileUsageRow {
    param(
        [Parameter(Mandatory)][string]$Href,
        [Parameter(Mandatory)][int]$LineStart,
        [Parameter(Mandatory)][int]$ColumnStart,
        [string]$Signature,
        [string]$ParentFunction,
        [string]$RawText,
        [Nullable[bool]]$HasDynamicContent = $null
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
    $script:rows.Add($row)
    return $row
}

# Add a JS_FILE USAGE row from a <script src="..."></script> tag.

function Add-JsFileUsageRow {
    param(
        [Parameter(Mandatory)][string]$Src,
        [Parameter(Mandatory)][int]$LineStart,
        [Parameter(Mandatory)][int]$ColumnStart,
        [string]$Signature,
        [string]$ParentFunction,
        [string]$RawText,
        [Nullable[bool]]$HasDynamicContent = $null
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
    $script:rows.Add($row)
    return $row
}

# ============================================================================
# CROSS-POPULATION SCOPE RESOLUTION (Wave 2)
# ============================================================================
#
# Wave 2 USAGE rows resolve their scope and source_file against existing
# DEFINITION rows in the catalog at populator scan time. The resolution
# maps are loaded once at startup (see "REGISTRY LOADS" section below)
# into script-scope hashtables, then queried by the resolver functions
# during the per-file walk.
#
# Each resolver returns a hashtable with .Scope and .SourceFile fields.
# When no matching DEFINITION row exists, Scope = 'LOCAL' and SourceFile
# = '<undefined>' per spec Section 5.6 / 13.6. This matches the JS
# populator's behavior for unresolved CSS class references.

function Resolve-CssClassScope {
    param([Parameter(Mandatory)][string]$ClassName)

    if ($script:cssClassSharedMap.ContainsKey($ClassName)) {
        return @{ Scope = 'SHARED'; SourceFile = $script:cssClassSharedMap[$ClassName] }
    }
    if ($script:cssClassLocalMap.ContainsKey($ClassName)) {
        return @{ Scope = 'LOCAL'; SourceFile = $script:cssClassLocalMap[$ClassName] }
    }
    return @{ Scope = 'LOCAL'; SourceFile = '<undefined>' }
}

function Resolve-JsFunctionScope {
    param([Parameter(Mandatory)][string]$FunctionName)

    if ($script:jsFunctionSharedMap.ContainsKey($FunctionName)) {
        return @{ Scope = 'SHARED'; SourceFile = $script:jsFunctionSharedMap[$FunctionName] }
    }
    if ($script:jsFunctionLocalMap.ContainsKey($FunctionName)) {
        return @{ Scope = 'LOCAL'; SourceFile = $script:jsFunctionLocalMap[$FunctionName] }
    }
    return @{ Scope = 'LOCAL'; SourceFile = '<undefined>' }
}

function Resolve-CssFileScope {
    param([Parameter(Mandatory)][string]$Href)

    # The href is a URL path like '/css/admin.css'; the catalog stores
    # the bare filename ('admin.css'). Strip the leading path before
    # matching.
    $bare = [System.IO.Path]::GetFileName($Href)
    if ($script:cssFileMap.ContainsKey($bare)) {
        # cc-shared.css is the only SHARED CSS file in the catalog model;
        # everything else is LOCAL to a page.
        $scope = if ($bare -eq 'cc-shared.css') { 'SHARED' } else { 'LOCAL' }
        return @{ Scope = $scope; SourceFile = $script:cssFileMap[$bare] }
    }
    return @{ Scope = 'LOCAL'; SourceFile = '<undefined>' }
}

function Resolve-JsFileScope {
    param([Parameter(Mandatory)][string]$Src)

    $bare = [System.IO.Path]::GetFileName($Src)
    if ($script:jsFileMap.ContainsKey($bare)) {
        # cc-shared.js / engine-events.js are SHARED; everything else is LOCAL.
        $scope = if ($bare -in @('cc-shared.js','engine-events.js')) { 'SHARED' } else { 'LOCAL' }
        return @{ Scope = $scope; SourceFile = $script:jsFileMap[$bare] }
    }
    return @{ Scope = 'LOCAL'; SourceFile = '<undefined>' }
}

# ============================================================================
# WAVE 2 - TOKEN STREAM WALKER
# ============================================================================
#
# Walk the tokenized HTML markup for one host file and emit Wave 2 rows
# (HTML_ID, HTML_DATA_ATTRIBUTE, CSS_CLASS USAGE, JS_FUNCTION USAGE,
# CSS_FILE USAGE, JS_FILE USAGE) for every catalogable attribute the
# walker encounters.
#
# This complements the page-shell walker (Get-PageShellDrift). The two
# walkers run independently against the same token stream: Get-PageShellDrift
# extracts file-level structural drift codes, and Invoke-Wave2TokenWalk
# extracts per-construct catalog rows.
#
# Parameters:
#   Tokens         - the tokenized HTML markup
#   FileLine0      - the source line in the host PS file where the
#                    emission begins (LineOffset on each token is added
#                    to this to get the absolute source line)
#   ParentFunction - the enclosing PS function for this emission
#                    (passed through to row.parent_function)
#   DataScope      - 'LOCAL' or 'SHARED'; passed through to HTML_DATA_ATTRIBUTE
#                    rows. Per spec Section 7.5, helper-emitted data-*
#                    attributes are SHARED.
#
# Returns nothing; rows are pushed onto $script:rows as a side effect.

function Invoke-Wave2TokenWalk {
    param(
        [Parameter(Mandatory)]$Tokens,
        [Parameter(Mandatory)][int]$FileLine0,
        [string]$ParentFunction,
        [Parameter(Mandatory)][ValidateSet('LOCAL','SHARED')][string]$DataScope
    )

    if ($null -eq $Tokens -or $Tokens.Count -eq 0) { return }

    foreach ($t in $Tokens) {
        if ($t.Kind -ne 'StartTag' -and $t.Kind -ne 'SelfClose') { continue }
        if ([string]::IsNullOrWhiteSpace($t.AttrText)) {
            # No attributes; tag still matters structurally but emits no Wave 2 rows.
            # Asset references handle <link> / <script> below even with no AttrText
            # (impossible since both require href/src, but we check tagname first
            # before bailing).
            continue
        }

        $attrs = Get-AttributesFromToken -AttrText $t.AttrText
        if ($null -eq $attrs -or $attrs.Count -eq 0) { continue }

        $absLine = $FileLine0 + $t.LineOffset
        $tagName = $t.TagName

        # --- Asset reference rows for <link> and <script src=...> ---
        if ($tagName -eq 'link') {
            $rel  = Get-AttributeByName -Attrs $attrs -Name 'rel'
            $href = Get-AttributeByName -Attrs $attrs -Name 'href'
            # Spec Section 3.1: only <link rel="stylesheet"> elements are
            # asset references catalogued by HTML. Drop other forms; Wave
            # 2.1 will add drift for non-stylesheet <link>s.
            if ($rel -and $href -and $rel.Value -and $rel.Value.Trim().ToLower() -eq 'stylesheet' -and -not [string]::IsNullOrWhiteSpace($href.Value)) {
                Add-CssFileUsageRow `
                    -Href           $href.Value `
                    -LineStart      $absLine `
                    -ColumnStart    $t.ColumnStart `
                    -Signature      $t.Raw `
                    -ParentFunction $ParentFunction `
                    -RawText        $t.Raw `
                    -HasDynamicContent ([Nullable[bool]]$href.HasInterp) | Out-Null
            }
        }
        elseif ($tagName -eq 'script') {
            $src = Get-AttributeByName -Attrs $attrs -Name 'src'
            if ($src -and -not [string]::IsNullOrWhiteSpace($src.Value)) {
                Add-JsFileUsageRow `
                    -Src            $src.Value `
                    -LineStart      $absLine `
                    -ColumnStart    $t.ColumnStart `
                    -Signature      $t.Raw `
                    -ParentFunction $ParentFunction `
                    -RawText        $t.Raw `
                    -HasDynamicContent ([Nullable[bool]]$src.HasInterp) | Out-Null
            }
        }

        # --- Per-attribute row extraction (every element) ---
        foreach ($a in $attrs) {
            if ([string]::IsNullOrEmpty($a.Name)) { continue }

            # id="..." -> HTML_ID DEFINITION
            if ($a.Name -eq 'id') {
                if (-not [string]::IsNullOrWhiteSpace($a.Value)) {
                    # Skip ID values that are purely a PS interpolation token
                    # (e.g., id="$someId"). The literal value isn't known to
                    # the catalog and emitting a row keyed on the variable
                    # name (e.g., '$someId') would be misleading. Wave 2.1
                    # may add drift for this pattern.
                    $isPureInterp = ($a.Value -match '^\s*\$[A-Za-z_({][^"]*\s*$' -and -not ($a.Value -match '[a-z0-9\-]'))
                    if (-not $isPureInterp) {
                        Add-HtmlIdRow `
                            -IdValue         $a.Value `
                            -LineStart       $absLine `
                            -ColumnStart     $t.ColumnStart `
                            -Signature       "id=`"$($a.Value)`"" `
                            -ParentFunction  $ParentFunction `
                            -RawText         "id=`"$($a.Value)`"" `
                            -HasDynamicContent ([Nullable[bool]]$a.HasInterp) | Out-Null
                    }
                }
                continue
            }

            # class="..." -> one CSS_CLASS USAGE row per static class name
            if ($a.Name -eq 'class') {
                if (-not [string]::IsNullOrWhiteSpace($a.Value)) {
                    $tokens2 = Split-StaticClassTokens -Value $a.Value
                    foreach ($cls in $tokens2) {
                        Add-CssClassUsageRow `
                            -ClassName       $cls `
                            -LineStart       $absLine `
                            -ColumnStart     $t.ColumnStart `
                            -Signature       "class=`"$($a.Value)`"" `
                            -ParentFunction  $ParentFunction `
                            -RawText         "class=`"$($a.Value)`"" `
                            -HasDynamicContent ([Nullable[bool]]$a.HasInterp) | Out-Null
                    }
                }
                continue
            }

            # data-* -> HTML_DATA_ATTRIBUTE DEFINITION
            if ($a.Name -like 'data-*') {
                Add-HtmlDataAttributeRow `
                    -AttrName        $a.Name `
                    -Scope           $DataScope `
                    -LineStart       $absLine `
                    -ColumnStart     $t.ColumnStart `
                    -Signature       "$($a.Name)=`"$($a.Value)`"" `
                    -ParentFunction  $ParentFunction `
                    -RawText         "$($a.Name)=`"$($a.Value)`"" `
                    -HasDynamicContent ([Nullable[bool]]$a.HasInterp) | Out-Null
                continue
            }

            # on* (event handlers) -> JS_FUNCTION USAGE
            # Cover any attribute name starting with 'on' followed by lowercase
            # letters: onclick, onchange, onkeydown, onsubmit, oninput, onblur,
            # onfocus, onmouseenter, etc. The HTML standard's full event list
            # is dynamic; this pattern admits all of them.
            if ($a.Name -match '^on[a-z]+$') {
                $fnName = $null
                if (-not [string]::IsNullOrWhiteSpace($a.Value)) {
                    $fnName = Get-FunctionNameFromHandler -Value $a.Value
                    if ([string]::IsNullOrEmpty($fnName)) {
                        # Try dotted-call form ('Module.func()', 'window.location.href = ...').
                        # Captures the leftmost dotted name as a USAGE row so the
                        # construct shows up in the catalog. Wave 2.1 will attach
                        # the FORBIDDEN_REVEALING_MODULE_CALL / FORBIDDEN_BUILTIN_METHOD_CALL
                        # drift code to this row.
                        $fnName = Get-DottedCallFromHandler -Value $a.Value
                    }
                }
                if (-not [string]::IsNullOrEmpty($fnName)) {
                    Add-JsFunctionUsageRow `
                        -FunctionName    $fnName `
                        -LineStart       $absLine `
                        -ColumnStart     $t.ColumnStart `
                        -Signature       "$($a.Name)=`"$($a.Value)`"" `
                        -ParentFunction  $ParentFunction `
                        -RawText         "$($a.Name)=`"$($a.Value)`"" `
                        -HasDynamicContent ([Nullable[bool]]$a.HasInterp) | Out-Null
                }
                continue
            }
        }
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
        [void]$psFiles.Add([ordered]@{
            FullPath = $f
        })
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
# HTML is embedded inside three Object_Registry-classified file kinds (Route,
# API, Module). Wave 1.1 loads Object_Registry rows for all three so the
# bulk insert can populate Asset_Registry.object_registry_id. We also need
# to know each host file's classification (Route vs API vs Module) so we can
# decide whether to run page-shell validation -- which applies only to Route
# files per spec Section 1.5. We get that by querying Object_Registry a
# second time to capture each file's object_type.

Write-Log "Loading Object_Registry mapping for FK resolution..."
$objectRegistryMap = Get-ObjectRegistryMap `
    -ServerInstance $script:XFActsServerInstance `
    -Database       $script:XFActsDatabase `
    -FileType       @('Route','API','Module')
Write-Log ("  Object_Registry rows loaded: {0}" -f $objectRegistryMap.Count)

# Per-file classification map: file_name -> 'Route' | 'API' | 'Module'.
# Drives page-shell validation gating (only Route files get shell checks)
# and scope assignment (Route/API = LOCAL, Module = SHARED). Built from a
# direct query because Get-ObjectRegistryMap returns only registry_id;
# we need the object_type for each row.
Write-Log "Loading Object_Registry type classification per file..."
$objectTypeByFile = @{}
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
        $objectTypeByFile[$row.object_name] = [string]$row.object_type
    }
}
catch {
    Write-Log "Object_Registry type classification query failed: $($_.Exception.Message)" 'WARN'
}
Write-Log ("  Classified file types loaded: {0}" -f $objectTypeByFile.Count)

$objectRegistryMisses = New-Object 'System.Collections.Generic.HashSet[string]'

# ============================================================================
# CROSS-POPULATION PRE-LOADS (Wave 2)
# ============================================================================
# Wave 2 USAGE rows (CSS_CLASS, JS_FUNCTION, CSS_FILE, JS_FILE) resolve
# their scope and source_file values against existing DEFINITION rows in
# the catalog. Load each lookup map once at startup so the per-file walk
# can do O(1) resolution.
#
# Per CC_HTML_Spec.md Section 13.6, the populator pipeline order is
# CSS -> HTML -> JS -> PS. CSS DEFINITION rows always exist when HTML
# runs; JS DEFINITION rows do not (JS runs after HTML). The query for
# JS_FUNCTION DEFINITIONs may return zero rows on first-run / cold-start
# scenarios; that's expected and produces '<undefined>' source_file
# values per spec.

Write-Log "Loading CSS_CLASS DEFINITION rows for scope resolution..."
$script:cssClassSharedMap = @{}
$script:cssClassLocalMap  = @{}
try {
    # Include both CSS_CLASS and CSS_VARIANT rows: a CSS_VARIANT is a
    # specialized selector form (.foo:hover, .foo.bar) that defines styling
    # for the same base class. The base class is the component_name on the
    # variant row, so a class defined only as a variant (e.g., only as
    # .foo:hover with no plain .foo rule) is still a legitimate definition
    # of the base class. This mirrors the JS_FUNCTION pre-load's existing
    # ('JS_FUNCTION','JS_FUNCTION_VARIANT') handling below.
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

Write-Log "Loading JS_FUNCTION DEFINITION rows for scope resolution..."
$script:jsFunctionSharedMap = @{}
$script:jsFunctionLocalMap  = @{}
try {
    $jsFnQuery = @"
SELECT component_name, scope, file_name
FROM dbo.Asset_Registry
WHERE component_type IN ('JS_FUNCTION','JS_FUNCTION_VARIANT')
  AND reference_type = 'DEFINITION'
  AND file_type      = 'JS'
"@
    $jsFnResults = Invoke-Sqlcmd -ServerInstance $script:XFActsServerInstance `
                                 -Database       $script:XFActsDatabase `
                                 -Query          $jsFnQuery `
                                 -QueryTimeout   60 `
                                 -ApplicationName $script:XFActsAppName `
                                 -ErrorAction Stop `
                                 -SuppressProviderContextWarning -TrustServerCertificate
    foreach ($row in $jsFnResults) {
        $cn = [string]$row.component_name
        if ([string]::IsNullOrEmpty($cn)) { continue }
        if ($row.scope -eq 'SHARED') {
            if (-not $script:jsFunctionSharedMap.ContainsKey($cn)) {
                $script:jsFunctionSharedMap[$cn] = [string]$row.file_name
            }
        } else {
            if (-not $script:jsFunctionLocalMap.ContainsKey($cn)) {
                $script:jsFunctionLocalMap[$cn] = [string]$row.file_name
            }
        }
    }
}
catch {
    Write-Log "JS_FUNCTION DEFINITION query failed: $($_.Exception.Message). USAGE rows will resolve to '<undefined>'." 'WARN'
}
Write-Log ("  JS_FUNCTION DEFINITIONs loaded: {0} shared, {1} local" -f `
           $script:jsFunctionSharedMap.Count, $script:jsFunctionLocalMap.Count)

# CSS_FILE and JS_FILE asset reference resolution. The CSS and JS populators
# each emit one CSS_FILE / JS_FILE DEFINITION row per scanned file as their
# pure-anchor row (component_name = bare filename). The HTML populator's
# <link rel="stylesheet" href="..."> and <script src="..."></script>
# references resolve against those rows by matching the bare filename.
#
# Shared vs local: we use the filename convention (cc-shared.css /
# cc-shared.js / engine-events.js are SHARED, everything else LOCAL) rather
# than reading the scope from the row itself. This decouples the resolver
# from the CSS / JS populators' scope conventions - if those change, the
# resolver doesn't need to follow.
Write-Log "Loading CSS_FILE rows for asset-reference resolution..."
$script:cssFileMap = @{}
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
$script:jsFileMap = @{}
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
# PER-FILE WALK
# ============================================================================
# For each PS file, parse the PowerShell AST, discover HTML emissions, and
# emit the HTML_FILE anchor row. For route files, run page-shell validation
# on each route's emission and attach the §15.1 drift codes to the row.

Write-Log "Walking PS files..."

foreach ($fileRec in $psFiles) {
    $fullPath = $fileRec.FullPath
    $name     = [System.IO.Path]::GetFileName($fullPath)

    $script:CurrentFile     = $name
    $script:CurrentFullPath = $fullPath

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
        # Files without HTML emission are simply skipped. PowerShell files
        # exist in the codebase that do non-HTML work (database collectors,
        # orchestrators, helpers that build SQL queries). They have no
        # HTML row representation.
        Write-Host " no HTML found, skipped" -ForegroundColor DarkGray
        continue
    }

    Write-Host (" {0} emission(s) found" -f $emissions.Count) -ForegroundColor Green

    # Classify the file via Object_Registry. The classification drives two
    # things: whether page-shell validation runs (only for Route files),
    # and the HTML_FILE row's scope (Route/API = LOCAL, Module = SHARED).
    # Files not in Object_Registry produce a miss advisory at the end; we
    # default their scope to LOCAL and skip shell validation.
    $registeredType = $null
    if ($objectTypeByFile.ContainsKey($name)) {
        $registeredType = $objectTypeByFile[$name]
    }
    $scope = if ($registeredType -eq 'Module') { 'SHARED' } else { 'LOCAL' }

    # Discover all Add-PodeRoute -Path declarations in the file, regardless
    # of classification. The route paths get captured on the HTML_FILE row's
    # raw_text for Wave 4's ProcessRegistry cross-checks. API files also
    # use Add-PodeRoute; their paths are captured the same way.
    $routes = @(Get-PodeRoutes -Ast $parsed.Ast)
    $routePaths = @($routes | ForEach-Object { $_.Path })

    # Emit exactly one HTML_FILE row for this host file.
    $row = Add-HtmlFileRow `
        -ComponentName $name `
        -Scope         $scope `
        -LineEnd       $parsed.LineCount `
        -RoutePaths    $routePaths

    if (-not $row) { continue }

    # Wave 2 row extraction. Walk EVERY emission in EVERY file regardless
    # of registered type. The token walker emits HTML_ID, HTML_DATA_ATTRIBUTE,
    # CSS_CLASS USAGE, JS_FUNCTION USAGE, CSS_FILE USAGE, and JS_FILE USAGE
    # rows from each emission's tokenized markup. The per-emission walk
    # preserves the source-line context: each token's LineOffset is added
    # to the emission's StartLine to produce the absolute line in the host
    # PS file.
    #
    # The DataScope is derived from the file's classification: Module files
    # emit SHARED data-* attributes (per spec Section 7.5); Routes and APIs
    # emit LOCAL.
    $dataScope = if ($registeredType -eq 'Module') { 'SHARED' } else { 'LOCAL' }
    $rowsBeforeWalk = $script:rows.Count
    foreach ($em in $emissions) {
        # ParentFunction: for route emissions, FunctionName is the marker
        # '<route:/path>'; for module emissions, it's the helper function
        # name. The marker form is preserved on rows because it's still
        # useful context for queries ("which rows came from a route
        # scriptblock vs. a named helper?").
        $emTokens = @(ConvertTo-HtmlTokens -Text $em.Text)
        Invoke-Wave2TokenWalk `
            -Tokens         $emTokens `
            -FileLine0      $em.StartLine `
            -ParentFunction $em.FunctionName `
            -DataScope      $dataScope
    }
    $rowsAfterWalk = $script:rows.Count
    Write-Host ("    -> {0} rows from Wave 2 walk" -f ($rowsAfterWalk - $rowsBeforeWalk)) -ForegroundColor DarkCyan

    # Page-shell validation: ONLY for files classified as Route in
    # Object_Registry. API files emit HTML fragments (slideout markup,
    # partial-update responses) rather than complete pages, and Module
    # files emit shared HTML helpers. Spec Section 1.5 exempts both from
    # the Section 1.1-1.4 page-shell rules. Files not in Object_Registry
    # also get no shell validation since we cannot classify them.
    if ($registeredType -ne 'Route') { continue }

    # For shell validation, concatenate all emissions in source order
    # so the tokenizer sees a single logical page emission. Route files
    # typically have one big here-string per route ScriptBlock; multiple
    # emissions are rare but handled cleanly here. The Wave 2 walk above
    # used per-emission tokenization for accurate line offsets, but shell
    # validation needs the whole-page view to find DOCTYPE, body, etc.
    $concatText = ''
    foreach ($em in $emissions) {
        $concatText += $em.Text
        if (-not $concatText.EndsWith("`n")) { $concatText += "`n" }
    }
    if ([string]::IsNullOrEmpty($concatText)) { continue }

    # Tokenize and run page-shell validation. Drift codes attach to the
    # one HTML_FILE row for this host file.
    $tokens = @(ConvertTo-HtmlTokens -Text $concatText)
    $shellDrift = Get-PageShellDrift -Tokens $tokens
    foreach ($code in $shellDrift) {
        Add-DriftCode -Row $row -Code $code `
            -Context "Page shell rule violated in $name."
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
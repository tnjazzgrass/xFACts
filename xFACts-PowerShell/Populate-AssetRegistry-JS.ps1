<#
.SYNOPSIS
    xFACts - Asset Registry JavaScript Populator

.DESCRIPTION
    Walks every .js file under the Control Center public/js and public/docs/js
    directories, parses each file with Acorn (via the parse-js.js Node helper),
    and generates Asset_Registry rows describing every catalogable component
    found in the file plus drift codes against CC_JS_Spec.md.

    This populator consumes shared infrastructure from
    xFACts-AssetRegistryFunctions.ps1: row construction, drift attachment,
    bulk insert, banner detection / parsing, file-header parsing, section
    list construction, registry loads, and the generic AST visitor walker.
    Per-language logic (acorn comment-shape adapter, variant shape helpers,
    per-row emitters, the visitor scriptblock body, AST parent-context
    helpers, HTML attribute extraction from JS string content) lives here.

    Three categories of rows are emitted:

    Group A - JS as source of HTML:
      * CSS_CLASS USAGE rows for class names found inside template literals,
        string literals, classList.add/remove/toggle calls, className
        assignments, and setAttribute('class', ...) calls.
      * HTML_ID DEFINITION rows for id="..." attributes inside template/string
        literals, el.id = '...' assignments, and setAttribute('id', ...) calls,
        plus HTML_ID USAGE rows for getElementById and querySelector calls
        with a literal '#id' argument.

    Group B - JS structural elements (spec-driven):
      * FILE_HEADER, COMMENT_BANNER, JS_IMPORT, JS_CONSTANT[_VARIANT],
        JS_STATE, JS_FUNCTION[_VARIANT], JS_HOOK[_VARIANT], JS_CLASS,
        JS_METHOD[_VARIANT], JS_TIMER, JS_DISPATCH_ENTRY, JS_FUNCTION
        USAGE rows.

    Group C - JS event bindings and forbidden patterns:
      * JS_EVENT USAGE rows for addEventListener calls and direct
        .on<event> = ... assignments.
      * JS_IIFE / JS_EVAL / JS_DOCUMENT_WRITE / JS_WINDOW_ASSIGNMENT /
        JS_INLINE_STYLE / JS_INLINE_SCRIPT / JS_LINE_COMMENT rows for
        forbidden patterns that have no natural declaration host.

    Run AFTER the CSS populator has loaded all CSS_CLASS DEFINITION rows.

.PARAMETER Execute
    Required to actually delete the JS rows from Asset_Registry and write
    the new row set. Without this flag, runs in preview mode.

.PARAMETER FileFilter
    Optional file-name filter for processing a single file or subset
    (e.g., -FileFilter 'cc-shared.js' processes only that file).

.COMPONENT
    Tools.Utilities

.NOTES
    File Name : Populate-AssetRegistry-JS.ps1
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
    FUNCTIONS: ACORN COMMENT ADAPTER
    FUNCTIONS: FILE HELPERS
    FUNCTIONS: HTML ATTRIBUTE EXTRACTION
    FUNCTIONS: DISPATCH TABLE NAME PARSING
    FUNCTIONS: AST POSITION AND CONTEXT HELPERS
    FUNCTIONS: VARIANT SHAPE HELPERS
    FUNCTIONS: COMMENT INDEX
    FUNCTIONS: AST PARSING
    FUNCTIONS: ZONE-AWARE SHARED MAP ACCESSORS
    FUNCTIONS: JS ROW EMITTERS
    FUNCTIONS: LOCAL DEFINITION COLLECTION
    FUNCTIONS: JS VISITOR
    EXECUTION: SCRIPT EXECUTION
#>

<# ============================================================================
   CHANGELOG: CHANGE HISTORY
   ----------------------------------------------------------------------------
   Date-stamped change history. Each entry is one ISO date line followed by an
   indented description. Entries appear most-recent first.
   Prefix: (none)
   ============================================================================ #>

# 2026-05-31  Converted to the Control Center PowerShell file format spec:
#             block-comment header and section banners, canonical section
#             order, dedicated CHANGELOG section, single EXECUTION section
#             with sub-section markers, and leading purpose comments on
#             script-scope declarations. Made zone, scope, and shell
#             designation table-driven: all three now come from
#             dbo.Object_Registry via Get-ObjectRegistryZoneScopeMap rather
#             than a local path test and hardcoded shared-file lists. Removed
#             Get-JsZone and the shared-file list constants; generalized the
#             shared-name maps to by-zone hashtables. Dropped the separate
#             Get-ObjectRegistryMap call (the zone/scope map now carries
#             registry_id, so the file makes one Object_Registry query); a
#             transitional shim at the bulk-insert call projects registry_id
#             back to the flat map shape the bulk insert still expects. Added
#             FILE_NOT_REGISTERED for files absent from Object_Registry.
# 2026-05-24  CC_JS_Spec alignment. Added INIT_MISPLACED and the
#             INITIALIZATION home-banner requirement for <prefix>_init.
#             Removed the (none) prefix carve-outs for JS.
# 2026-05-14  Bootloader / dispatch / ENGINE_PROCESSES support. Added
#             JS_DISPATCH_ENTRY emission, ENGINE_PROCESSES validation,
#             MISSING_PAGE_INIT, and HTML_ID cross-spec resolution. Page
#             files moved to IMPORTS / CONSTANTS / STATE / FUNCTIONS;
#             cc-shared.js gained a BOOTLOADER section before CHROME.
# 2026-05-11  Added JS_FILE as a pure-anchor row emitted once per scanned
#             file, ahead of FILE_HEADER, as the universal scanned-file row.
# 2026-05-09  Added FORBIDDEN_PER_ELEMENT_LISTENER_LOOP detection for
#             per-element listener attachment via forEach or for-loop bodies.
# 2026-05-07  Adopted the shared visitor walker, section-list builder,
#             file-header parser, registry loads, bulk insert, and
#             occurrence-index helpers. Replaced the catch-all banner code
#             with granular banner-shape codes; added prefix registry
#             validation, revealing-module/IIFE detection with definition
#             suppression, and output-boundary drift-code validation.
# 2026-05-06  Top-level IIFE structural skip.
# 2026-05-05  AST walk resilience; zone awareness (cc vs docs); HTML_ID rows
#             emitted with scope LOCAL.
# 2026-05-04  Spec-aware rewrite. CC_JS_Spec adopted as the structural
#             contract; variant model added.

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

Initialize-XFActsScript -ScriptName 'Populate-AssetRegistry-JS' -Execute:$Execute

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
   Node toolchain paths, the Acorn parser script, and the JS scan roots.
   Zone, scope, and shell designation are not listed here; they come from
   dbo.Object_Registry per file at run time.
   Prefix: (none)
   ============================================================================ #>

# Node executable used to run the Acorn parser.
$NodeExe       = 'C:\Program Files\nodejs\node.exe'
# Node library path made available to the parser subprocess.
$NodeLibsPath  = 'C:\Program Files\nodejs-libs\node_modules'
# The Acorn parser script invoked per file.
$ParseJsScript = "$PSScriptRoot\parse-js.js"

# Control Center root directory.
$CcRoot = 'E:\xFACts-ControlCenter'
# Scan roots covering all JS files in the platform (cc and docs).
$JsScanRoots = @(
    "$CcRoot\public\js"
    "$CcRoot\public\docs\js"
)

# Vendored third-party JS libraries (locally-hosted browser libraries
# committed under public/js/, not authored CC code). Cataloged as a single
# JS_FILE anchor row each but never parsed or walked: the spec does not
# govern third-party minified bundles. The anchor row exists so page
# <script src="/js/<lib>"> USAGE references resolve to a real DEFINITION.
$VendoredJsFiles = @('chart.min.js','chartjs-adapter-date-fns.min.js','xlsx.full.min.js')

<# ============================================================================
   CONSTANTS: SPEC CONSTANTS
   ----------------------------------------------------------------------------
   The recognized section types per file kind, their required order, the
   fixed banner names, the recognized hook and event name sets, and the
   contract identifiers. Shell-file membership is not listed here; it comes
   from dbo.Object_Registry (scope_tier SHELL) per file at run time.
   Prefix: (none)
   ============================================================================ #>

# Section types valid in a page file. A FOUNDATION/BOOTLOADER/CHROME banner
# in a page file produces UNKNOWN_SECTION_TYPE.
$ValidSectionTypes_Page   = @('IMPORTS', 'CONSTANTS', 'STATE', 'FUNCTIONS')
# Section types valid in the shell file. A CONSTANTS/FUNCTIONS banner in the
# shell file produces UNKNOWN_SECTION_TYPE.
$ValidSectionTypes_Shared = @('IMPORTS', 'FOUNDATION', 'STATE', 'BOOTLOADER', 'CHROME')

# Required ordering of section types, keyed by type. Page files run
# IMPORTS -> CONSTANTS -> STATE -> FUNCTIONS; the shell file runs
# IMPORTS -> FOUNDATION -> STATE -> BOOTLOADER -> CHROME. FOUNDATION and
# CONSTANTS share slot 2; FUNCTIONS and CHROME share slot 5. One hashtable
# serves both file kinds.
$SectionTypeOrder = @{
    'IMPORTS'    = 1
    'FOUNDATION' = 2
    'CONSTANTS'  = 2
    'STATE'      = 3
    'BOOTLOADER' = 4
    'FUNCTIONS'  = 5
    'CHROME'     = 5
}

# The fixed banner name for the page lifecycle hooks group (the last banner).
$HooksBannerName = 'PAGE LIFECYCLE HOOKS'

# The five recognized hook function names. Read by exact name from the shell
# file, so they cannot be renamed.
$RecognizedHookNames = @(
    'onPageRefresh',
    'onPageResumed',
    'onSessionExpired',
    'onEngineProcessCompleted',
    'onEngineEventRaw'
)

# Contract identifiers (ENGINE_PROCESSES plus the five hook names): read by
# exact name from the shell file and exempt from PREFIX_MISSING /
# PREFIX_MISMATCH. Misplacement is surfaced by the _MISPLACED drift codes.
$ContractIdentifiers = @('ENGINE_PROCESSES') + $RecognizedHookNames

# Required home banner name for the ENGINE_PROCESSES constant.
$script:EngineProcessesBannerName = 'ENGINE PROCESSES'

# Required home banner name for the page boot function (<prefix>_init), the
# first FUNCTIONS banner in a page file.
$InitBannerName = 'INITIALIZATION'

# Recognized event names for data-action-<event> attributes and the JS-side
# dispatch tables (<prefix>_<event>Actions page-side, shared<Event>Actions
# shell-side). Kept in lockstep with the HTML populator's event list.
$RecognizedEventNames = @(
    'click',
    'change',
    'input',
    'submit',
    'keydown',
    'keyup',
    'focus',
    'blur'
)

<# ============================================================================
   CONSTANTS: DRIFT DESCRIPTIONS
   ----------------------------------------------------------------------------
   Drift code to human-readable description map, kept aligned with the
   CC_JS_Spec drift reference. Add-DriftCode validates against this map and
   uses it to populate drift_text. Cross-file Pass codes are included so
   attachment does not fail the master-table check.
   Prefix: (none)
   ============================================================================ #>

# Drift code to human-readable description map for Add-DriftCode.
$DriftDescriptions = [ordered]@{
    # File header
    'MALFORMED_FILE_HEADER'             = "The file's header block is missing, malformed, or contains required fields out of order."
    'FORBIDDEN_CHANGELOG_BLOCK'         = "The file header contains a CHANGELOG block. CHANGELOG blocks are not allowed in JS file headers."
    'FILE_ORG_MISMATCH'                 = "The FILE ORGANIZATION list in the header does not exactly match the section banner titles in the file body, by content or by order."
    # Section banners
    'MISSING_SECTION_BANNER'            = "A definition appears outside any banner -- no section banner precedes it in the file."
    'BANNER_INLINE_SHAPE'               = "A section banner uses the single-line ===== Title ===== form. The spec requires a multi-line banner with bracketing rule lines, title line, separator, description block, and Prefix line."
    'BANNER_INVALID_RULE_CHAR'          = "A section banner's opening or closing bracketing line is not composed entirely of '=' characters. Both bracket lines must be all '='."
    'BANNER_INVALID_RULE_LENGTH'        = "A section banner's opening or closing bracketing line is composed of '=' characters but is not exactly 76 characters long."
    'BANNER_INVALID_SEPARATOR_CHAR'     = "A section banner's middle separator line is missing or is not composed entirely of '-' characters. The separator must be all '-'."
    'BANNER_INVALID_SEPARATOR_LENGTH'   = "A section banner's middle separator line is not exactly 76 '-' characters long."
    'BANNER_MALFORMED_TITLE_LINE'       = "A section banner has no recognizable title line in the form '<TYPE>: <NAME>'. The TYPE token must be uppercase letters and underscores only."
    'BANNER_MISSING_DESCRIPTION'        = "A section banner has no description content between the separator and the Prefix line. The description is required (1 to 5 sentences explaining what the section contains)."
    'UNKNOWN_SECTION_TYPE'              = "A section banner declares a TYPE not valid for the file kind. Page files allow IMPORTS, CONSTANTS, STATE, FUNCTIONS. cc-shared.js allows IMPORTS, FOUNDATION, STATE, BOOTLOADER, CHROME."
    'SECTION_TYPE_ORDER_VIOLATION'      = "Section types appear out of the required order for the file kind."
    'MISSING_PREFIX_DECLARATION'        = "A section banner is missing the mandatory Prefix line in its description block."
    'MALFORMED_PREFIX_VALUE'            = "A banner's Prefix value is neither a page prefix nor 'cc', or declares multiple comma-separated values."
    'PREFIX_REGISTRY_MISMATCH'          = "A section banner's declared prefix does not match Component_Registry.cc_prefix for the file's component (with the spec's IMPORTS / CONSTANTS / hooks-banner carve-outs honored)."
    'DUPLICATE_FOUNDATION'              = "A FOUNDATION section appears in a JS file that is not the shell file. FOUNDATION sections live only in the shell file (cc-shared.js)."
    'DUPLICATE_BOOTLOADER'              = "A BOOTLOADER section appears in a JS file that is not the shell file. BOOTLOADER sections live only in the shell file (cc-shared.js)."
    'DUPLICATE_CHROME'                  = "A CHROME section appears in a JS file that is not the shell file. CHROME sections live only in the shell file (cc-shared.js)."
    'HOOKS_BANNER_NOT_LAST'             = "A FUNCTIONS: PAGE LIFECYCLE HOOKS banner exists but is not the last banner in the file."
    # Definition-level
    'PREFIX_MISMATCH'                   = "A top-level identifier name does not begin with the prefix declared in its containing section's banner."
    'PREFIX_MISSING'                    = "A top-level identifier does not begin with the file's registered prefix. Component_Registry declares a cc_prefix for the file but the identifier name does not match. Fires independently of banners; surfaces prefix non-conformance in pre-spec files that have no banners yet."
    'MISSING_FUNCTION_COMMENT'          = "A function definition is not preceded by a single block comment."
    'MISSING_CONSTANT_COMMENT'          = "A const declaration in a CONSTANTS or FOUNDATION section is not preceded by a single block comment."
    'MISSING_STATE_COMMENT'             = "A var declaration in a STATE section is not preceded by a single block comment."
    'MISSING_CLASS_COMMENT'             = "A class declaration is not preceded by a single block comment."
    'MISSING_METHOD_COMMENT'            = "A method inside a class body is not preceded by a single block comment."
    'WRONG_DECLARATION_KEYWORD'         = "A var declaration appears in a CONSTANTS or FOUNDATION section, or a const declaration appears in a STATE section."
    'SHADOWS_SHARED_FUNCTION'           = "A page file defines a function whose name matches a cc-shared.js export."
    'UNKNOWN_HOOK_NAME'                 = "A function inside the hooks banner has a name not in the recognized hook set."
    'ENGINE_PROCESSES_MISPLACED'        = "The ENGINE_PROCESSES constant is declared outside its required 'CONSTANTS: ENGINE PROCESSES' banner."
    'HOOK_MISPLACED'                    = "A function whose name matches one of the five recognized hook names is declared outside the 'FUNCTIONS: PAGE LIFECYCLE HOOKS' banner."
    'INIT_MISPLACED'                    = "<prefix>_init is declared outside the 'FUNCTIONS: INITIALIZATION' banner, or the INITIALIZATION banner contains a function other than <prefix>_init, or the INITIALIZATION banner is not the first FUNCTIONS banner in the file."
    'MISSING_PAGE_INIT'                 = "A page file with a registered cc_prefix does not declare a top-level <prefix>_init function. The bootloader requires every page to declare an init function called after the page DOM is ready."
    'MISSING_ENGINE_PROCESSES_DECLARATION' = "Orchestrator.ProcessRegistry has at least one active process (run_mode=1) whose cc_page_route matches this file's page route, but the file does not declare a top-level ENGINE_PROCESSES constant. Page files that participate in the engine-card system must declare ENGINE_PROCESSES."
    'MISSING_ENGINE_CARD_FOR_REGISTERED_PROCESS' = "Orchestrator.ProcessRegistry has an active process (run_mode=1) whose cc_page_route matches this file's page route, but the file's ENGINE_PROCESSES set does not include an entry for that process. Every registered engine-card process for this page must appear in ENGINE_PROCESSES."
    'ENGINE_PROCESS_PAGE_MISMATCH'      = "An ENGINE_PROCESSES entry references a process whose cc_page_route in Orchestrator.ProcessRegistry does not match the current file's page route. Pages may only declare ENGINE_PROCESSES entries for their own page route."
    'ENGINE_SLUG_JS_MISMATCH'           = "An ENGINE_PROCESSES entry's slug value does not match Orchestrator.ProcessRegistry.cc_engine_slug for the corresponding process. The slug declared in JS must match the slug registered in ProcessRegistry."
    'UNRESOLVED_DISPATCH_HANDLER'       = "A dispatch table entry references a handler function name that does not resolve to a function defined in the same file (page-side dispatch) or in cc-shared.js (shared-side dispatch). The handler must exist or the dispatched action will fail at runtime."
    'MALFORMED_ACTION_KEY'              = "A dispatch table key violates the action-value naming rules: page-side keys must be kebab-case (lowercase letters, digits, hyphens) and must NOT start with 'cc-' (which is reserved for shared chrome actions); shared-side keys MUST start with 'cc-'."
    'JS_HTML_ID_MALFORMED'              = "A JS reference to an HTML ID uses a string that contains characters outside the spec's lowercase-letters/digits/hyphens set, or does not begin with the file's registered cc_prefix followed by a hyphen. Page-local IDs must match the <prefix>-<purpose> form."
    # Forbidden patterns
    'FORBIDDEN_LET'                     = "A let declaration appears anywhere in the file."
    'FORBIDDEN_MULTI_DECLARATION'       = "A single statement declares multiple variables. Each declaration gets its own statement."
    'FORBIDDEN_CONDITIONAL_DEFINITION'  = "A top-level function or class is declared inside an if/while/try block."
    'FORBIDDEN_ANONYMOUS_FUNCTION'      = "A function or arrow expression has no name and is not passed as a callback argument."
    'FORBIDDEN_PROPERTY_ASSIGN_EVENT'   = "An event handler is bound via el.on<event> = handler instead of addEventListener."
    'FORBIDDEN_IIFE'                    = "An IIFE appears at file scope. The IIFE pattern is not used in CC JavaScript files."
    'FORBIDDEN_REVEALING_MODULE'        = "A const or var declaration is initialized by an immediately-invoked function expression (the revealing-module pattern). The file's design is structurally non-spec and requires a full rewrite to top-level function declarations."
    'FORBIDDEN_EVAL'                    = "A call to eval(...) appears in the file."
    'FORBIDDEN_DOCUMENT_WRITE'          = "A call to document.write(...) appears in the file."
    'FORBIDDEN_WINDOW_ASSIGNMENT'       = "An assignment to window.<name> appears outside cc-shared.js."
    'FORBIDDEN_INLINE_STYLE_IN_JS'      = "A template literal or string literal contains a <style> element."
    'FORBIDDEN_INLINE_SCRIPT_IN_JS'     = "A template literal or string literal contains a <script> element."
    'FORBIDDEN_INLINE_EVENT_IN_JS'      = "A template literal or string literal contains an inline on<event>=`"...`" attribute. Bind events via addEventListener after rendering."
    'FORBIDDEN_PER_ELEMENT_LISTENER_LOOP' = "An addEventListener call appears inside a forEach callback or a for-loop body, attaching one listener per element. Event delegation is required: a single addEventListener on a stable parent that dispatches by event.target.matches/closest plus data-* attributes."
    'FORBIDDEN_FILE_SCOPE_LINE_COMMENT' = "A // line comment appears at file scope. Line comments are permitted only inside function bodies."
    # Comment / structure
    'FORBIDDEN_COMMENT_STYLE'           = "A comment exists that is not one of the allowed kinds (file header, section banner, purpose comment, sub-section marker)."
    'BLANK_LINE_INSIDE_FUNCTION_BODY_AT_SCOPE' = "More than one consecutive blank line appears inside a function body."
    'EXCESS_BLANK_LINES'                = "More than one blank line appears between top-level constructs."
    # Operational / pipeline (populator-only, not a JS content rule)
    'FILE_NOT_REGISTERED'               = "A .js file on disk is absent from dbo.Object_Registry, so its zone, scope, and shell designation could not be resolved. Register the file to enable classification and FK linkage."
}

<# ============================================================================
   VARIABLES: SCRIPT-SCOPE STATE
   ----------------------------------------------------------------------------
   Mutable script-scope state: the row collection and dedupe tracker, the
   per-file row references consumed by post-walk passes, and the per-file
   context (file name, zone, scope, shell flag, registry prefix, local
   definitions, section list) the visitor and emitters read during the walk.
   Prefix: (none)
   ============================================================================ #>

# Accumulator for all Asset_Registry rows emitted during the run.
$script:rows       = New-Object System.Collections.Generic.List[object]
# Dedupe tracker keyed by row identity, referenced via Test-AddDedupeKey.
$script:dedupeKeys = New-Object 'System.Collections.Generic.HashSet[string]'

# Per-file JS_FILE anchor row references; post-walk passes attach whole-file
# drift codes (EXCESS_BLANK_LINES, FORBIDDEN_COMMENT_STYLE) through this map.
$script:jsFileRowByFile = @{}

# Per-file ENGINE_PROCESSES JS_CONSTANT_VARIANT row, captured by the visitor
# and read by the post-walk validation pass. Reset per file.
$script:CurrentEngineProcessesRow = $null

# Per-file ENGINE_PROCESSES extracted entries (@{ Slug; PageRoute; Line }),
# compared against Orchestrator.ProcessRegistry post-walk. Reset per file.
$script:CurrentEngineProcessesEntries = $null

# Current file name being walked.
$script:CurrentFile               = $null
# True when the current file's Object_Registry scope is SHARED.
$script:CurrentFileIsShared       = $false
# Current file's Object_Registry scope (SHARED / LOCAL / '<undefined>').
$script:CurrentFileScope          = '<undefined>'
# True when the current file is the zone's shell file (scope_tier SHELL).
$script:CurrentFileIsShell        = $false
# Current file's Object_Registry zone.
$script:CurrentFileZone           = 'cc'
# Raw source text of the current file.
$script:CurrentFileSource         = $null
# Local function names defined in the current file.
$script:CurrentLocalFuncs         = $null
# Local constant names defined in the current file.
$script:CurrentLocalConsts        = $null
# Local state-variable names defined in the current file.
$script:CurrentLocalState         = $null
# Local class names defined in the current file.
$script:CurrentLocalClasses       = $null
# Parsed section list for the current file.
$script:CurrentSections           = $null
# Preceding-comment index for the current file.
$script:CurrentCommentIndex       = $null
# Likely timer-handle state-variable names in the current file.
$script:CurrentTimerHandles       = $null
# Current file's registered cc_prefix, or $null when none.
$script:CurrentRegistryPrefix     = $null
# True when the current file has a Component_Registry mapping.
$script:CurrentRegistryHasMapping = $false
# Valid section types for the current file kind (page vs shell).
$script:CurrentValidSectionTypes  = $ValidSectionTypes_Page

# Set true when a forbidden top-level wrapper (IIFE / revealing-module IIFE)
# is found; suppresses subsequent DEFINITION emissions inside the wrapper
# while USAGE and forbidden-pattern rows continue. Reset per file.
$script:CurrentSuppressDefinitions = $false

<# ============================================================================
   FUNCTIONS: ACORN COMMENT ADAPTER
   ----------------------------------------------------------------------------
   Normalizes Acorn's comment objects into the shape the shared file-header
   and section-list helpers expect.
   Prefix: (none)
   ============================================================================ #>

# Convert Acorn comment objects to the normalized shape (.Type / .Text /
# .LineStart / .LineEnd / .ColumnStart / .OriginalNode) expected by the shared
# Get-FileHeaderInfo and New-SectionList. Both Block and Line comments are
# normalized; Line comments are used for FORBIDDEN_FILE_SCOPE_LINE_COMMENT.
function Convert-AcornCommentsToNormalized {
    param($Comments)

    $list = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Comments) { return $list }

    foreach ($c in $Comments) {
        if ($c.type -ne 'Block' -and $c.type -ne 'Line') { continue }
        $line    = if ($c.loc -and $c.loc.start) { [int]$c.loc.start.line } else { 1 }
        $endLine = if ($c.loc -and $c.loc.end)   { [int]$c.loc.end.line   } else { $line }
        $col     = if ($c.loc -and $c.loc.start -and ($c.loc.start.PSObject.Properties.Name -contains 'column')) {
                       ([int]$c.loc.start.column) + 1
                   } else { 1 }

        $list.Add([pscustomobject]@{
            Type         = $c.type
            Text         = $c.value
            LineStart    = $line
            LineEnd      = $endLine
            ColumnStart  = $col
            OriginalNode = $c
        })
    }

    return $list
}

<# ============================================================================
   FUNCTIONS: FILE HELPERS
   ----------------------------------------------------------------------------
   Page-route derivation, raw source extraction by node range, and cheap
   HTML-shape detection over string and template literal content.
   Prefix: (none)
   ============================================================================ #>

# Derive the page route for a JS file: '/' plus the basename minus '.js'
# (e.g. 'batch-monitoring.js' -> '/batch-monitoring'). Used by the
# ENGINE_PROCESSES validation pass, which only calls this for non-shared
# files; shared files have no page route.
function Get-PageRouteForJsFile {
    param([string]$FileName)
    if ([string]::IsNullOrEmpty($FileName)) { return $null }
    if ($FileName -notlike '*.js')          { return $null }
    $base = $FileName -replace '\.js$', ''
    return "/$base"
}

# Pull raw text from the source string by character range. Used to capture
# verbatim source for IIFE bodies, template literals, etc. into raw_text.
function Get-RangeText {
    param([string]$Source, $Node)
    if ($null -eq $Node -or $null -eq $Node.range -or $Node.range.Count -lt 2) { return $null }
    $start = [int]$Node.range[0]
    $end   = [int]$Node.range[1]
    if ($start -lt 0) { $start = 0 }
    if ($end -gt $Source.Length) { $end = $Source.Length }
    if ($end -le $start) { return '' }
    return $Source.Substring($start, $end - $start)
}

# Detect HTML-bearing strings cheaply.
function Test-LooksLikeHtml {
    param([string]$Text)
    if ($null -eq $Text) { return $false }
    if ($Text.Length -lt 4) { return $false }
    if ($Text -match '<\s*\w') { return $true }
    if ($Text -match '\b(class|id)\s*=') { return $true }
    return $false
}

# Return true when the text contains an inline <style> tag.
function Test-LooksLikeInlineStyle {
    param([string]$Text)
    if ($null -eq $Text) { return $false }
    return $Text -match '<\s*style\b'
}

# Return true when the text contains an inline <script> tag.
function Test-LooksLikeInlineScript {
    param([string]$Text)
    if ($null -eq $Text) { return $false }
    return $Text -match '<\s*script\b'
}

# Return true when the text contains an HTML inline event-handler attribute.
function Test-LooksLikeInlineEvent {
    param([string]$Text)
    if ($null -eq $Text) { return $false }
    # Match an HTML inline event handler attribute: whitespace, then 'on'
    # followed by one or more lowercase letters (the event name), optional
    # whitespace, '=', optional whitespace, then an opening quote. The
    # leading whitespace requirement rules out 'data-onload="..."' and
    # similar custom attributes, since '-' is not whitespace.
    return $Text -match '\son[a-z]+\s*=\s*["'']'
}

<# ============================================================================
   FUNCTIONS: HTML ATTRIBUTE EXTRACTION
   ----------------------------------------------------------------------------
   Extracts class="..." and id="..." attribute occurrences from string and
   template literal content, and splits class attribute values into tokens.
   Prefix: (none)
   ============================================================================ #>

# Extract every class="..." and id="..." attribute occurrence from a string.
function Get-HtmlAttributeOccurrences {
    param([string]$Text)
    if ($null -eq $Text) { return @() }

    $results = New-Object System.Collections.Generic.List[object]
    $pattern = '\b(class|id)\s*=\s*(["''])([^"'']*)\2'
    $regexMatches = [regex]::Matches($Text, $pattern)

    foreach ($m in $regexMatches) {
        $attrName = $m.Groups[1].Value.ToLower()
        $value    = $m.Groups[3].Value
        if ([string]::IsNullOrWhiteSpace($value)) { continue }

        $charIndex   = $m.Index
        $textBefore  = $Text.Substring(0, $charIndex)
        $lineOffset  = ($textBefore -split "`n").Count - 1
        $lastNewline = $textBefore.LastIndexOf("`n")
        $columnStart = if ($lastNewline -ge 0) { $charIndex - $lastNewline } else { $charIndex + 1 }

        $results.Add([ordered]@{
            Kind        = $attrName
            Value       = $value
            LineOffset  = $lineOffset
            ColumnStart = $columnStart
        })
    }

    return $results
}

# Split a class="..." value into individual class names, dropping interpolations.
function Split-ClassNames {
    param([string]$Value)
    if ($null -eq $Value) { return @() }
    $cleaned = [regex]::Replace($Value, '\$\{[^}]*\}', ' ')
    $tokens = @($cleaned -split '\s+' | Where-Object {
        $_ -and ($_ -notmatch '\$') -and ($_ -ne '')
    })
    return $tokens
}

<# ============================================================================
   FUNCTIONS: DISPATCH TABLE NAME PARSING
   ----------------------------------------------------------------------------
   Recognizes dispatch-table variable names (<prefix>_<event>Actions page-side,
   shared<Event>Actions shell-side) and extracts the event they bind to.
   Prefix: (none)
   ============================================================================ #>

# Parse a const declarator name to detect whether it names a dispatch table.
# Returns @{ IsDispatchTable = $bool; Side = 'page'|'shared'|$null; EventName = '<event>' or $null }.
# Recognize a dispatch-table variable name and return its side and event.
# Page-side: <prefix>_<event>Actions (e.g. bch_clickActions). Shell-side:
# cc_<event>Actions (e.g. cc_clickActions). <event> is one of the recognized
# event names (click, change, input, submit, keydown, keyup, focus, blur).
# Prefix conformance is enforced by PREFIX_MISSING / PREFIX_MISMATCH on the
# surrounding JS_CONSTANT row, not here.
function Get-DispatchTableInfo {
    param([string]$Name)
    $result = @{ IsDispatchTable = $false; Side = $null; EventName = $null }
    if ([string]::IsNullOrEmpty($Name)) { return $result }

    # Shell-side: cc_<event>Actions. Checked before the page-side pattern so
    # 'cc_clickActions' is not misclassified as a page table with prefix 'cc'.
    if ($Name -cmatch '^cc_([a-z]+)Actions$') {
        $eventName = $matches[1]
        if ($RecognizedEventNames -contains $eventName) {
            $result.IsDispatchTable = $true
            $result.Side            = 'shared'
            $result.EventName       = $eventName
        }
        return $result
    }

    # Page-side: <prefix>_<event>Actions. The prefix is any lowercase identifier;
    # the regular PREFIX_MISMATCH / PREFIX_MISSING checks on the surrounding
    # JS_CONSTANT row enforce prefix conformance against Component_Registry.
    if ($Name -cmatch '^([a-z]+)_([a-z]+)Actions$') {
        $eventName = $matches[2]
        if ($RecognizedEventNames -contains $eventName) {
            $result.IsDispatchTable = $true
            $result.Side            = 'page'
            $result.EventName       = $eventName
        }
    }

    return $result
}

<# ============================================================================
   FUNCTIONS: AST POSITION AND CONTEXT HELPERS
   ----------------------------------------------------------------------------
   Parent-chain inspection, scope and enclosing-construct detection, and the
   AST position helpers the visitor uses to classify and attribute nodes.
   Prefix: (none)
   ============================================================================ #>

# Return the 1-based start line of an AST node, or 1 when unavailable.
function Get-NodeLine {
    param($Node)
    if ($null -eq $Node) { return 1 }
    if ($Node.loc -and $Node.loc.start -and $Node.loc.start.line) { return [int]$Node.loc.start.line }
    return 1
}

# Return the 1-based end line of an AST node, falling back to its start line.
function Get-NodeEndLine {
    param($Node)
    if ($null -eq $Node) { return 1 }
    if ($Node.loc -and $Node.loc.end -and $Node.loc.end.line) { return [int]$Node.loc.end.line }
    return Get-NodeLine -Node $Node
}

# Return the 1-based start column of an AST node, or 1 when unavailable.
function Get-NodeColumn {
    param($Node)
    if ($null -eq $Node) { return 1 }
    if ($Node.loc -and $Node.loc.start -and ($Node.loc.start.PSObject.Properties.Name -contains 'column')) {
        return ([int]$Node.loc.start.column) + 1
    }
    return 1
}

# Walk a CallExpression callee chain ONCE and return its dotted segments in
# leaf-first order (the deepest property is at index 0). Used in conjunction
# with Test-SegmentsMatchEnd: the CallExpression case computes segments
# once per visit, then calls Test-SegmentsMatchEnd for each pattern instead
# of re-walking the callee chain on every check.
#
# Returns $null when the callee shape cannot be matched at all - either it's
# null, contains a computed property access (foo[bar]), or contains a
# non-Identifier property. The caller treats $null as "no match."
#
# The unary comma on the final return is critical. PowerShell's output
# stream enumerates IEnumerable return values, so a bare `return $segments`
# would unroll the List into separate output items, and the caller would
# receive a single string (for 1-segment chains) or an Object[] (for 2+) -
# either of which silently breaks the .Count / [i] contract that
# Test-SegmentsMatchEnd relies on. The comma wraps the list in a 1-element
# tuple so the output stream emits the List as a single object.
function Get-CalleeSegments {
    param($Callee)
    if ($null -eq $Callee) { return $null }

    $segments = New-Object System.Collections.Generic.List[string]
    $cursor = $Callee
    while ($cursor -and $cursor.type -eq 'MemberExpression') {
        if ($cursor.computed) { return $null }
        if (-not $cursor.property -or $cursor.property.type -ne 'Identifier') { return $null }
        [void]$segments.Add($cursor.property.name)
        $cursor = $cursor.object
    }
    if ($cursor -and $cursor.type -eq 'Identifier') {
        [void]$segments.Add($cursor.name)
    }
    return , $segments
}

# Test whether the tail of a pre-walked callee segments list matches a given
# dotted path. The leftmost segment of $Path matches the bottom-most object.
# $Segments must be the value returned from Get-CalleeSegments (leaf-first
# order); the comparison flips the path index to align natural-order $Path
# against leaf-first $Segments.
function Test-SegmentsMatchEnd {
    param($Segments, [string[]]$Path)
    if ($null -eq $Segments) { return $false }
    if ($Segments.Count -lt $Path.Count) { return $false }
    $lastPathIdx = $Path.Count - 1
    for ($i = 0; $i -lt $Path.Count; $i++) {
        if ($Segments[$i] -ne $Path[$lastPathIdx - $i]) { return $false }
    }
    return $true
}

# Determine whether a node's parent chain indicates the node is inside any
# of the conditional / try wrappers that the spec forbids for top-level
# definitions.
function Test-IsConditionallyDefined {
    param([array]$ParentChain)
    foreach ($t in $ParentChain) {
        if ($t -in @('IfStatement','WhileStatement','DoWhileStatement','ForStatement','TryStatement','CatchClause','ConditionalExpression')) {
            return $true
        }
    }
    return $false
}

# Determine if a node is at module top level. ParentChain for a top-level
# statement is exactly @('Program') or @('Program','ExportNamedDeclaration').
function Test-IsTopLevel {
    param([array]$ParentChain)
    $joined = ($ParentChain -join '/')
    return $joined -in @('Program', 'Program/ExportNamedDeclaration')
}

# Returns true if the given line falls within any of the supplied
# function-body ranges. Used to determine whether a // line comment is
# at file scope (outside any function body) for FORBIDDEN_FILE_SCOPE_LINE_COMMENT.
function Test-LineInsideFunction {
    param([int]$Line, $Ranges)
    if ($null -eq $Ranges) { return $false }
    foreach ($r in $Ranges) {
        if ($Line -ge $r.Start -and $Line -le $r.End) { return $true }
    }
    return $false
}

# Returns the maximum run of consecutive truly-blank lines (whitespace-only)
# in the source text strictly between $StartLine and $EndLine (1-based,
# exclusive on both ends). Used by EXCESS_BLANK_LINES and
# BLANK_LINE_INSIDE_FUNCTION_BODY_AT_SCOPE to count actual blank lines
# rather than line-number differences. A comment line counts as content,
# not blank, so a purpose comment preceding the next statement does not
# inflate the blank count.
# StartLine and EndLine are typically the .loc.end.line of one statement
# and the .loc.start.line of the next; the function examines lines
# (StartLine + 1) through (EndLine - 1) in the source text.
function Get-MaxConsecutiveBlankLines {
    param([string]$Source, [int]$StartLine, [int]$EndLine)
    if ([string]::IsNullOrEmpty($Source)) { return 0 }
    if ($EndLine - $StartLine -le 1) { return 0 }

    # Source split into 0-indexed lines. Source line N (1-based) is at
    # index N-1. We examine lines (StartLine + 1) through (EndLine - 1)
    # inclusive in 1-based terms, which is indices StartLine through
    # EndLine - 2 in 0-based terms.
    $lines = $Source -split "`n"
    $firstIdx = $StartLine
    $lastIdx  = $EndLine - 2
    if ($firstIdx -lt 0) { $firstIdx = 0 }
    if ($lastIdx -ge $lines.Count) { $lastIdx = $lines.Count - 1 }

    $maxRun = 0
    $curRun = 0
    for ($i = $firstIdx; $i -le $lastIdx; $i++) {
        $lineText = $lines[$i]
        # Strip trailing \r from CRLF line endings before whitespace check.
        if ($lineText.EndsWith("`r")) { $lineText = $lineText.Substring(0, $lineText.Length - 1) }
        if ([string]::IsNullOrWhiteSpace($lineText)) {
            $curRun++
            if ($curRun -gt $maxRun) { $maxRun = $curRun }
        } else {
            $curRun = 0
        }
    }
    return $maxRun
}

# Returns $true if the current node is inside a per-element listener loop --
# i.e. inside a forEach callback (or map/some/every/find/filter callback,
# all of which are array-iteration callbacks that take a per-element
# function), or inside a for-of / for-in / for loop body. Used by the
# addEventListener detection in the CallExpression visitor case to fire
# FORBIDDEN_PER_ELEMENT_LISTENER_LOOP.
# The walk stops as soon as it crosses into a nested FunctionDeclaration,
# since that means the addEventListener is inside an inner function defined
# inside the loop -- not actually attached to each element by the loop
# itself. FunctionExpression and ArrowFunctionExpression DO NOT stop the
# walk because the loop's callback IS one of those; we want to keep
# climbing past the callback to find its enclosing CallExpression and
# decide whether that's a forEach (or sibling).
function Test-IsInsideElementLoop {
    param([array]$ParentNodes)
    if ($null -eq $ParentNodes -or $ParentNodes.Count -eq 0) { return $false }

    # Names of array-iteration methods whose callback runs once per element.
    # forEach is the dominant case; the others are included because attaching
    # an event listener inside any of them is the same anti-pattern.
    $perElementMethods = @('forEach', 'map', 'filter', 'find', 'some', 'every')

    for ($i = $ParentNodes.Count - 1; $i -ge 0; $i--) {
        $p = $ParentNodes[$i]
        if ($null -eq $p) { continue }
        if (-not ($p.PSObject.Properties.Name -contains 'type')) { continue }

        # Stop the walk at any nested named function -- if addEventListener
        # is inside an inner function defined inside the loop, it's not
        # being attached per-element by the loop itself.
        if ($p.type -eq 'FunctionDeclaration') { return $false }

        # for-of / for-in / for loop bodies. The addEventListener call is
        # inside the loop's BlockStatement body.
        if ($p.type -eq 'ForOfStatement' -or
            $p.type -eq 'ForInStatement' -or
            $p.type -eq 'ForStatement') {
            return $true
        }

        # forEach (and siblings) callback. Pattern: the addEventListener
        # call is inside a FunctionExpression / ArrowFunctionExpression
        # whose immediate parent is a CallExpression whose callee is
        # MemberExpression with property.name in $perElementMethods.
        if ($p.type -eq 'FunctionExpression' -or $p.type -eq 'ArrowFunctionExpression') {
            $grandparentSlot = $i - 1
            if ($grandparentSlot -ge 0) {
                $gp = $ParentNodes[$grandparentSlot]
                if ($gp -and ($gp.PSObject.Properties.Name -contains 'type') -and
                    $gp.type -eq 'CallExpression' -and $gp.callee -and
                    $gp.callee.type -eq 'MemberExpression' -and
                    $gp.callee.property -and $gp.callee.property.type -eq 'Identifier' -and
                    $perElementMethods -contains $gp.callee.property.name) {
                    return $true
                }
            }
        }
    }
    return $false
}

# Find the closest enclosing function/method/class name by walking back
# through the parent-node chain. Returns the function/method declaration's
# name, or $null if no enclosing function context found, or '<anonymous>'
# for unnameable function expressions. Defensive against null parent slots
# in $ParentNodes (rare but possible with malformed-but-parseable input).
function Get-CurrentParentName {
    param([array]$ParentNodes)
    if ($null -eq $ParentNodes -or $ParentNodes.Count -eq 0) { return $null }

    for ($i = $ParentNodes.Count - 1; $i -ge 0; $i--) {
        $p = $ParentNodes[$i]
        if ($null -eq $p) { continue }
        if (-not ($p.PSObject.Properties.Name -contains 'type')) { continue }

        switch ($p.type) {
            'FunctionDeclaration' {
                if ($p.id -and $p.id.name) { return $p.id.name }
                return '<anonymous>'
            }
            'MethodDefinition' {
                if ($p.key -and $p.key.type -eq 'Identifier' -and $p.key.name) { return $p.key.name }
                if ($p.kind -eq 'constructor') { return 'constructor' }
                return '<anonymous>'
            }
            'FunctionExpression'      { return (Get-NameForFunctionExpression -ParentNodes $ParentNodes -ExpressionIndex $i) }
            'ArrowFunctionExpression' { return (Get-NameForFunctionExpression -ParentNodes $ParentNodes -ExpressionIndex $i) }
        }
    }
    return $null
}

# Resolve the effective name of a FunctionExpression / ArrowFunctionExpression
# by inspecting its immediate parent context. For const/var-init or property-
# value contexts (which are the FORBIDDEN_ANONYMOUS_FUNCTION cases), records
# the binding name so USAGE rows nested inside have a meaningful parent_function.
# Defensive against null parent slots.
function Get-NameForFunctionExpression {
    param([array]$ParentNodes, [int]$ExpressionIndex)

    $parentSlot = $ExpressionIndex - 1
    if ($parentSlot -lt 0) { return '<anonymous>' }
    $parent = $ParentNodes[$parentSlot]
    if ($null -eq $parent) { return '<anonymous>' }
    if (-not ($parent.PSObject.Properties.Name -contains 'type')) { return '<anonymous>' }

    switch ($parent.type) {
        'VariableDeclarator' {
            if ($parent.id -and $parent.id.type -eq 'Identifier' -and $parent.id.name) { return $parent.id.name }
            return '<anonymous>'
        }
        'AssignmentExpression' {
            $left = $parent.left
            if ($left -and $left.type -eq 'MemberExpression' -and
                $left.property -and $left.property.type -eq 'Identifier' -and $left.property.name) {
                return $left.property.name
            }
            if ($left -and $left.type -eq 'Identifier' -and $left.name) { return $left.name }
            return '<anonymous>'
        }
        'Property' {
            if ($parent.key -and $parent.key.type -eq 'Identifier' -and $parent.key.name) { return $parent.key.name }
            if ($parent.key -and $parent.key.type -eq 'Literal' -and $parent.key.value) { return [string]$parent.key.value }
            return '<anonymous>'
        }
        'CallExpression' {
            # Function expression as a callback argument -- the spec-allowed
            # context. Use the callee's display name.
            $callee = $parent.callee
            if ($null -eq $callee) { return '<anonymous>' }
            if ($callee.type -eq 'Identifier') { return $callee.name }
            if ($callee.type -eq 'MemberExpression' -and
                $callee.property -and $callee.property.type -eq 'Identifier') {
                return ".$($callee.property.name)"
            }
            return '<anonymous>'
        }
        default { return '<anonymous>' }
    }
}

# Returns the simple name from an Identifier or string Literal node.
function Get-IdentifierName {
    param($Node)
    if ($null -eq $Node) { return $null }
    if ($Node.type -eq 'Identifier') { return $Node.name }
    if ($Node.type -eq 'Literal') { return [string]$Node.value }
    return $null
}

<# ============================================================================
   FUNCTIONS: VARIANT SHAPE HELPERS
   ----------------------------------------------------------------------------
   Each helper inspects an AST node and returns the row's variant shape
   (@{ ComponentType; VariantType; VariantQualifier1; VariantQualifier2 }),
   distinguishing base rows from their async / generator / static / accessor
   variants.
   Prefix: (none)
   ============================================================================ #>

# Return the variant shape for a function node: JS_FUNCTION for a plain
# declaration, JS_FUNCTION_VARIANT (async / generator) otherwise. Function and
# arrow expressions assigned to const/var are handled elsewhere.
function Get-FunctionVariantShape {
    param($Node)
    if ($Node.type -ne 'FunctionDeclaration') {
        return @{ ComponentType = 'JS_FUNCTION'; VariantType = $null; VariantQualifier1 = $null; VariantQualifier2 = $null }
    }
    if ($Node.async -eq $true) {
        return @{ ComponentType = 'JS_FUNCTION_VARIANT'; VariantType = 'async'; VariantQualifier1 = $null; VariantQualifier2 = $null }
    }
    if ($Node.generator -eq $true) {
        return @{ ComponentType = 'JS_FUNCTION_VARIANT'; VariantType = 'generator'; VariantQualifier1 = $null; VariantQualifier2 = $null }
    }
    return @{ ComponentType = 'JS_FUNCTION'; VariantType = $null; VariantQualifier1 = $null; VariantQualifier2 = $null }
}

# JS_HOOK (base, sync) vs JS_HOOK_VARIANT (async).
function Get-HookVariantShape {
    param($Node)
    if ($Node.async -eq $true) {
        return @{ ComponentType = 'JS_HOOK_VARIANT'; VariantType = 'async'; VariantQualifier1 = $null; VariantQualifier2 = $null }
    }
    return @{ ComponentType = 'JS_HOOK'; VariantType = $null; VariantQualifier1 = $null; VariantQualifier2 = $null }
}

# JS_CONSTANT (base, primitive) vs JS_CONSTANT_VARIANT (object/array/regex/expression).
function Get-ConstantVariantShape {
    param($InitNode)
    if ($null -eq $InitNode) {
        return @{ ComponentType = 'JS_CONSTANT'; VariantType = $null; VariantQualifier1 = $null; VariantQualifier2 = $null }
    }

    switch ($InitNode.type) {
        'Literal' {
            if ($InitNode.PSObject.Properties.Name -contains 'regex' -and $null -ne $InitNode.regex) {
                return @{ ComponentType = 'JS_CONSTANT_VARIANT'; VariantType = 'regex'; VariantQualifier1 = $null; VariantQualifier2 = $null }
            }
            return @{ ComponentType = 'JS_CONSTANT'; VariantType = $null; VariantQualifier1 = $null; VariantQualifier2 = $null }
        }
        'TemplateLiteral' {
            if ($InitNode.expressions -and $InitNode.expressions.Count -gt 0) {
                return @{ ComponentType = 'JS_CONSTANT_VARIANT'; VariantType = 'expression'; VariantQualifier1 = $null; VariantQualifier2 = $null }
            }
            return @{ ComponentType = 'JS_CONSTANT'; VariantType = $null; VariantQualifier1 = $null; VariantQualifier2 = $null }
        }
        'UnaryExpression' {
            # Negative literal: -1, -3.14
            if ($InitNode.argument -and $InitNode.argument.type -eq 'Literal') {
                return @{ ComponentType = 'JS_CONSTANT'; VariantType = $null; VariantQualifier1 = $null; VariantQualifier2 = $null }
            }
            return @{ ComponentType = 'JS_CONSTANT_VARIANT'; VariantType = 'expression'; VariantQualifier1 = $null; VariantQualifier2 = $null }
        }
        'Identifier' {
            return @{ ComponentType = 'JS_CONSTANT_VARIANT'; VariantType = 'expression'; VariantQualifier1 = $null; VariantQualifier2 = $null }
        }
        'ObjectExpression' {
            return @{ ComponentType = 'JS_CONSTANT_VARIANT'; VariantType = 'object'; VariantQualifier1 = $null; VariantQualifier2 = $null }
        }
        'ArrayExpression' {
            return @{ ComponentType = 'JS_CONSTANT_VARIANT'; VariantType = 'array'; VariantQualifier1 = $null; VariantQualifier2 = $null }
        }
        default {
            return @{ ComponentType = 'JS_CONSTANT_VARIANT'; VariantType = 'expression'; VariantQualifier1 = $null; VariantQualifier2 = $null }
        }
    }
}

# JS_METHOD (base, regular method) vs JS_METHOD_VARIANT (static/getter/setter/async).
function Get-MethodVariantShape {
    param($Node)
    if ($Node.static -eq $true) {
        return @{ ComponentType = 'JS_METHOD_VARIANT'; VariantType = 'static'; VariantQualifier1 = $null; VariantQualifier2 = $null }
    }
    if ($Node.kind -eq 'get') {
        return @{ ComponentType = 'JS_METHOD_VARIANT'; VariantType = 'getter'; VariantQualifier1 = $null; VariantQualifier2 = $null }
    }
    if ($Node.kind -eq 'set') {
        return @{ ComponentType = 'JS_METHOD_VARIANT'; VariantType = 'setter'; VariantQualifier1 = $null; VariantQualifier2 = $null }
    }
    if ($Node.value -and $Node.value.async -eq $true) {
        return @{ ComponentType = 'JS_METHOD_VARIANT'; VariantType = 'async'; VariantQualifier1 = $null; VariantQualifier2 = $null }
    }
    return @{ ComponentType = 'JS_METHOD'; VariantType = $null; VariantQualifier1 = $null; VariantQualifier2 = $null }
}

# JS_TIMER - always a variant (no base form).
function Get-TimerVariantShape {
    param([string]$CalleeName)
    $vt = if ($CalleeName -eq 'setInterval') { 'interval' } else { 'timeout' }
    return @{ ComponentType = 'JS_TIMER'; VariantType = $vt; VariantQualifier1 = $null; VariantQualifier2 = $null }
}

# JS_IMPORT - always a variant (no base form).
function Get-ImportVariantShape {
    param($Specifier, [string]$SourcePath)
    $vt = switch ($Specifier.type) {
        'ImportDefaultSpecifier'   { 'default' }
        'ImportNamespaceSpecifier' { 'namespace' }
        'ImportSpecifier'          { 'named' }
        default                    { 'named' }
    }
    return @{ ComponentType = 'JS_IMPORT'; VariantType = $vt; VariantQualifier1 = $null; VariantQualifier2 = $SourcePath }
}

# Return the JS_IMPORT row shape for a require() call with the given source path.
function Get-RequireVariantShape {
    param([string]$SourcePath)
    return @{ ComponentType = 'JS_IMPORT'; VariantType = 'require'; VariantQualifier1 = $null; VariantQualifier2 = $SourcePath }
}

<# ============================================================================
   FUNCTIONS: COMMENT INDEX
   ----------------------------------------------------------------------------
   Builds and queries the preceding-comment index used to attach purpose
   comments to the definitions they document.
   Prefix: (none)
   ============================================================================ #>

# Build a per-file index of block comments for fast preceding-comment lookup.
# Used by definition emitters to find the purpose comment immediately above
# each function/const/var/class/method declaration. This is JS-specific
# (CSS uses a different scheme) and stays local; it consumes the normalized
# comment shape from Convert-AcornCommentsToNormalized.
function New-CommentIndex {
    param($NormalizedComments)
    $idx = New-Object System.Collections.Generic.List[object]
    if ($null -eq $NormalizedComments) { return $idx }

    foreach ($c in $NormalizedComments) {
        if ($c.Type -ne 'Block') { continue }
        if ($null -eq $c.LineStart -or $c.LineStart -le 0) { continue }
        $idx.Add([ordered]@{
            StartLine = [int]$c.LineStart
            EndLine   = [int]$c.LineEnd
            Value     = $c.Text
            Used      = $false
        })
    }

    return $idx
}

# Find the block comment immediately preceding a definition node. "Immediately
# preceding" means the comment ends on the line directly above the definition
# (allowing a single blank-line gap), and the comment has not been claimed
# by a closer-following definition.
function Get-PrecedingBlockComment {
    param($CommentIndex, [int]$DefinitionLine)
    if ($null -eq $CommentIndex -or $CommentIndex.Count -eq 0) { return $null }

    $best = $null
    foreach ($c in $CommentIndex) {
        if ($c.Used) { continue }
        $gap = $DefinitionLine - $c.EndLine
        if ($gap -ge 1 -and $gap -le 2) {
            if ($null -eq $best -or $c.EndLine -gt $best.EndLine) {
                $best = $c
            }
        }
    }

    if ($best) {
        $best.Used = $true
        return $best.Value
    }
    return $null
}

<# ============================================================================
   FUNCTIONS: AST PARSING
   ----------------------------------------------------------------------------
   Invokes the Acorn parser subprocess for a single file and returns the parsed
   AST, source text, and comment list, with per-file error capture.
   Prefix: (none)
   ============================================================================ #>

# Run a single.js file through parse-js.js and return the parsed AST,
# comments array, and raw source text. Returns $null on parse failure.
function Invoke-JsParse {
    param([Parameter(Mandatory)][string]$FilePath)

    try {
        $source = Get-Content -Path $FilePath -Raw -Encoding UTF8
        if (-not $source) { $source = '' }

        $output  = $source | & $NodeExe $ParseJsScript 2>&1
        $exitCode = $LASTEXITCODE
        $jsonText = ($output | Out-String)

        $parsed = $null
        try { $parsed = $jsonText | ConvertFrom-Json }
        catch {
            Write-Log "JSON parse failed for ${FilePath}: $($_.Exception.Message)" 'ERROR'
            return $null
        }

        if ($exitCode -ne 0 -or ($parsed.PSObject.Properties.Name -contains 'error' -and $parsed.error)) {
            $msg  = if ($parsed.message) { $parsed.message } else { 'Unknown parser error' }
            $line = if ($parsed.line)    { $parsed.line }    else { '?' }
            $col  = if ($parsed.column)  { $parsed.column }  else { '?' }
            Write-Log "Acorn parse failed for ${FilePath} at line ${line} col ${col}: $msg" 'ERROR'
            return $null
        }

        return @{
            Ast      = $parsed.ast
            Comments = $parsed.comments
            Source   = $source
        }
    }
    catch {
        Write-Log "Exception during parse of ${FilePath}: $($_.Exception.Message)" 'ERROR'
        return $null
    }
}

<# ============================================================================
   FUNCTIONS: ZONE-AWARE SHARED MAP ACCESSORS
   ----------------------------------------------------------------------------
   Return the current file's zone's shared-function set and source-file map,
   plus the prefix / contract-identifier / HTML-ID test helpers the emitters
   use during the walk. References resolve only within the file's own zone.
   Prefix: (none)
   ============================================================================ #>

# Return the current zone's shared-function set, or a fresh empty set when the
# zone has none yet. The leading comma forces single-element array return so an
# empty HashSet does not pipeline-unwrap to $null at the call site.
function Get-ZoneSharedFunctions {
    param()
    $hs = $null
    if ($null -ne $script:sharedFunctionsByZone -and $script:sharedFunctionsByZone.ContainsKey($script:CurrentFileZone)) {
        $hs = $script:sharedFunctionsByZone[$script:CurrentFileZone]
    }
    if ($null -eq $hs) { $hs = New-Object 'System.Collections.Generic.HashSet[string]' }
    return ,$hs
}

# Return the current zone's shared name -> source-file map, or an empty map
# when the zone has none yet.
function Get-ZoneSharedSourceFile {
    param()
    $h = $null
    if ($null -ne $script:sharedSourceFileByZone -and $script:sharedSourceFileByZone.ContainsKey($script:CurrentFileZone)) {
        $h = $script:sharedSourceFileByZone[$script:CurrentFileZone]
    }
    if ($null -eq $h) { $h = @{} }
    return $h
}

# Return $true if the identifier is a contract identifier (ENGINE_PROCESSES
# plus the five hook names), which are read by exact name from the shell file
# and exempt from PREFIX_MISSING / PREFIX_MISMATCH.
function Test-IsContractIdentifier {
    param([string]$IdentifierName)
    if ([string]::IsNullOrEmpty($IdentifierName)) { return $false }
    return ($ContractIdentifiers -contains $IdentifierName)
}

# Return $true when the file has a registered prefix and the identifier does
# not begin with that prefix + underscore. Returns $false for contract
# identifiers, files with no registry mapping or a null prefix, and conforming
# identifiers. Used by the definition emitters to fire PREFIX_MISSING.
function Test-PrefixMissing {
    param([string]$IdentifierName)
    if ([string]::IsNullOrEmpty($IdentifierName)) { return $false }
    if (Test-IsContractIdentifier -IdentifierName $IdentifierName) { return $false }
    if (-not $script:CurrentRegistryHasMapping)   { return $false }
    if ([string]::IsNullOrEmpty($script:CurrentRegistryPrefix)) { return $false }
    $expected = "$($script:CurrentRegistryPrefix)_"
    return -not $IdentifierName.StartsWith($expected)
}

# Return $true when an HTML ID string is malformed: it contains characters
# outside lowercase-letters/digits/hyphens, or (when the file has a registered
# prefix) it begins with neither the page prefix + '-' nor the chrome 'cc-'.
# Used by Add-HtmlIdRow to fire JS_HTML_ID_MALFORMED on USAGE rows.
function Test-HtmlIdMalformed {
    param([string]$IdName)
    if ([string]::IsNullOrEmpty($IdName)) { return $false }
    if ($IdName -cnotmatch '^[a-z0-9-]+$') { return $true }
    if ($IdName.StartsWith('cc-')) { return $false }
    if (-not $script:CurrentRegistryHasMapping)                  { return $false }
    if ([string]::IsNullOrEmpty($script:CurrentRegistryPrefix)) { return $false }
    $expected = "$($script:CurrentRegistryPrefix)-"
    return -not $IdName.StartsWith($expected)
}

# Derive the hook suffix by stripping the file's registered prefix + underscore
# (e.g. 'bkp_onPageRefresh' -> 'onPageRefresh'), so the UNKNOWN_HOOK_NAME and
# HOOK_MISPLACED checks compare against bare hook names. Falls back to the full
# name when the file has no registered prefix.
function Get-HookSuffix {
    param([string]$FunctionName)
    if ([string]::IsNullOrEmpty($FunctionName)) { return $FunctionName }
    if (-not $script:CurrentRegistryHasMapping)                  { return $FunctionName }
    if ([string]::IsNullOrEmpty($script:CurrentRegistryPrefix)) { return $FunctionName }
    $expected = "$($script:CurrentRegistryPrefix)_"
    if ($FunctionName.StartsWith($expected)) {
        return $FunctionName.Substring($expected.Length)
    }
    return $FunctionName
}

# Test whether an identifier is the ENGINE_PROCESSES constant in either the
# bare form ('ENGINE_PROCESSES') or the prefixed form
# ('<prefix>_ENGINE_PROCESSES').
function Test-IsEngineProcessesName {
    param([string]$IdentifierName)
    if ([string]::IsNullOrEmpty($IdentifierName)) { return $false }
    if ($IdentifierName -eq 'ENGINE_PROCESSES') { return $true }
    return $IdentifierName.EndsWith('_ENGINE_PROCESSES')
}

<# ============================================================================
   FUNCTIONS: JS ROW EMITTERS
   ----------------------------------------------------------------------------
   Build and append Asset_Registry rows for every catalogable JS construct:
   the JS_FILE anchor and FILE_HEADER, section banners, definitions, usages,
   dispatch entries, event bindings, and forbidden-pattern rows.
   Prefix: (none)
   ============================================================================ #>

# Wrap New-AssetRegistryRow with the per-file context every JS row carries
# (file_name = current file, file_type = JS, source_section = the section
# the row's line falls inside).
function New-JsRow {
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
        -FileType           'JS' `
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

# Emit the JS_FILE anchor row for the current file. Exactly one row per
# scanned.js file. This is the universal "this file was scanned" anchor,
# parallel to CSS_FILE, HTML_FILE, and (future) PS_FILE. The row carries
# no raw_text, no purpose_description, and no signature - it is purely
# structural. File-overall drift codes (EXCESS_BLANK_LINES,
# FORBIDDEN_COMMENT_STYLE) attach to this row.
function Add-JsFileRow {
    param([int]$LineEnd)

    $key = "$($script:CurrentFile)|1|JS_FILE|$($script:CurrentFile)|DEFINITION|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }
    $row = New-JsRow `
        -ComponentType 'JS_FILE' `
        -ComponentName $script:CurrentFile `
        -LineStart     1 `
        -LineEnd       $LineEnd `
        -ColumnStart   1 `
        -ReferenceType 'DEFINITION' `
        -Scope         $scope `
        -SuppressSectionLookup
    $script:rows.Add($row)
    $script:jsFileRowByFile[$script:CurrentFile] = $row
    return $row
}

# Emit the FILE_HEADER row for the file's leading block comment.
function Add-FileHeaderRow {
    param([int]$LineStart, [int]$LineEnd, [string]$RawText, [string]$PurposeDescription)
    $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }
    $row = New-JsRow `
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
# Banner-level drift codes from Get-BannerInfo (BANNER_INLINE_SHAPE,
# BANNER_INVALID_RULE_*, BANNER_INVALID_SEPARATOR_*, BANNER_MALFORMED_TITLE_LINE,
# BANNER_MISSING_DESCRIPTION, UNKNOWN_SECTION_TYPE, MISSING_PREFIX_DECLARATION)
# come pre-populated on Section.BannerDriftCodes. SECTION_TYPE_ORDER_VIOLATION,
# MALFORMED_PREFIX_VALUE, PREFIX_REGISTRY_MISMATCH, DUPLICATE_FOUNDATION,
# DUPLICATE_CHROME, HOOKS_BANNER_NOT_LAST, and INIT_MISPLACED are added here
# based on cross-section / cross-file / cross-registry information.
function Add-CommentBannerRow {
    param(
        $Section,
        [int] $PreviousSectionTypeOrderIdx = -1,
        [bool] $IsLastBanner = $false,
        [bool] $HooksBannerSeen = $false,
        [bool] $IsFirstFunctionsBanner = $false
    )

    if ($null -eq $Section) { return $null }

    $b = $Section.BannerComment
    $rawSnippet = $null
    if ($b.Text) {
        $crlf = "`r`n"; $lf = "`n"; $cr = "`r"
        $rawSnippet = ($b.Text -replace $crlf, ' ' -replace $lf, ' ' -replace $cr, ' ').Trim()
    }

    $key = "$($script:CurrentFile)|$($Section.BannerStartLine)|COMMENT_BANNER|$($Section.FullTitle)|DEFINITION|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $componentName = if ($Section.BannerName) { $Section.BannerName } else { $Section.FullTitle }
    $scope         = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }

    $row = New-JsRow `
        -ComponentType      'COMMENT_BANNER' `
        -ComponentName      $componentName `
        -LineStart          $Section.BannerStartLine `
        -LineEnd            $Section.BannerEndLine `
        -ColumnStart        1 `
        -ReferenceType      'DEFINITION' `
        -Scope              $scope `
        -Signature          $Section.TypeName `
        -RawText            $rawSnippet `
        -PurposeDescription $Section.Description `
        -SuppressSectionLookup
    $script:rows.Add($row)

    # Per-banner drift carried over from Get-BannerInfo / New-SectionList
    foreach ($code in $Section.BannerDriftCodes) {
        Add-DriftCode -Row $row -Code $code
    }

    # SECTION_TYPE_ORDER_VIOLATION (per-banner)
    # Attach to this banner if its type's slot is less than the high-water mark.
    if ($Section.TypeName -and $script:SectionTypeOrder.ContainsKey($Section.TypeName)) {
        $newIdx = [int]$script:SectionTypeOrder[$Section.TypeName]
        if ($PreviousSectionTypeOrderIdx -ge 0 -and $newIdx -lt $PreviousSectionTypeOrderIdx) {
            Add-DriftCode -Row $row -Code 'SECTION_TYPE_ORDER_VIOLATION'
        }
    }

    # DUPLICATE_FOUNDATION / DUPLICATE_BOOTLOADER / DUPLICATE_CHROME
    # Shell-file enforcement: FOUNDATION, BOOTLOADER, and CHROME may appear
    # only in the shell file. The drift code fires when they appear in any
    # file that is not the shell.
    if ($Section.TypeName -eq 'FOUNDATION' -and -not $script:CurrentFileIsShell) {
        Add-DriftCode -Row $row -Code 'DUPLICATE_FOUNDATION' `
            -Context "FOUNDATION section appears in '$($script:CurrentFile)'; FOUNDATION lives only in the shell file."
    }
    if ($Section.TypeName -eq 'BOOTLOADER' -and -not $script:CurrentFileIsShell) {
        Add-DriftCode -Row $row -Code 'DUPLICATE_BOOTLOADER' `
            -Context "BOOTLOADER section appears in '$($script:CurrentFile)'; BOOTLOADER lives only in the shell file."
    }
    if ($Section.TypeName -eq 'CHROME' -and -not $script:CurrentFileIsShell) {
        Add-DriftCode -Row $row -Code 'DUPLICATE_CHROME' `
            -Context "CHROME section appears in '$($script:CurrentFile)'; CHROME lives only in the shell file."
    }

    # HOOKS_BANNER_NOT_LAST
    # If this banner is the hooks banner and it isn't the last banner in
    # the file, attach the drift code here. The IsLastBanner flag is
    # supplied by the caller from the section list.
    $isHooks = ($Section.TypeName -eq 'FUNCTIONS' -and $Section.BannerName -eq $script:HooksBannerName)
    if ($isHooks -and -not $IsLastBanner) {
        Add-DriftCode -Row $row -Code 'HOOKS_BANNER_NOT_LAST'
    }

    # INIT_MISPLACED (banner side)
    # If this banner is the INITIALIZATION banner and it isn't the first
    # FUNCTIONS banner in the file, attach the drift code here. The
    # IsFirstFunctionsBanner flag is supplied by the caller. The other
    # two firing points for INIT_MISPLACED (init function declared
    # outside this banner; non-init function declared inside this banner)
    # fire on the JS_FUNCTION row in the FunctionDeclaration visitor.
    $isInit = ($Section.TypeName -eq 'FUNCTIONS' -and $Section.BannerName -eq $script:InitBannerName)
    if ($isInit -and -not $IsFirstFunctionsBanner) {
        Add-DriftCode -Row $row -Code 'INIT_MISPLACED' `
            -Context "INITIALIZATION banner is not the first FUNCTIONS banner in the file."
    }

    # MALFORMED_PREFIX_VALUE
    if ($Section.Prefix -and -not (Test-PrefixValueIsValid -Prefix $Section.Prefix)) {
        Add-DriftCode -Row $row -Code 'MALFORMED_PREFIX_VALUE' `
            -Context "Banner declares Prefix '$($Section.Prefix)' which is neither a page prefix nor 'cc'."
    }

    # PREFIX_REGISTRY_MISMATCH
    # - Registry mapping with cc_prefix = X -> banner must declare X.
    # - Registry mapping with cc_prefix = NULL and this is the shell file ->
    #   banner must declare 'cc'.
    # - No registry mapping -> skip; the missing row is reported by the miss
    #   advisory.
    # MALFORMED_PREFIX_VALUE has already fired upstream on values that are
    # neither a page prefix nor cc, so both values here are known well-formed.
    if ($script:CurrentRegistryHasMapping -and $Section.Prefix -and (Test-PrefixValueIsValid -Prefix $Section.Prefix)) {
        # bannerVal is 'cc' or the page prefix; regVal is $null or the page prefix.
        $bannerVal = Get-BannerPrefixValue -Prefix $Section.Prefix
        $regVal    = $script:CurrentRegistryPrefix
        $isShell   = $script:CurrentFileIsShell

        $mismatch = $false
        if ($null -eq $regVal) {
            # No registered page prefix. The shell file must declare 'cc';
            # any other JS file in this state is unexpected.
            if ($isShell) {
                if ($bannerVal -ne 'cc') { $mismatch = $true }
            } else {
                $mismatch = $true
            }
        } else {
            if ($bannerVal -ne $regVal) { $mismatch = $true }
        }

        if ($mismatch) {
            $regDisplay = if ($null -eq $regVal) {
                if ($isShell) { 'cc' } else { '<no prefix registered>' }
            } else { $regVal }
            Add-DriftCode -Row $row -Code 'PREFIX_REGISTRY_MISMATCH' `
                -Context "Banner declares Prefix '$bannerVal' but the expected value for this file is '$regDisplay'."
        }
    }

    return $row
}

# Emit a DEFINITION row for a top-level JS construct and run its prefix checks.
function Add-JsDefinitionRow {
    param(
        [string]$ComponentType,
        [string]$ComponentName,
        [string]$VariantType,
        [string]$VariantQualifier1,
        [string]$VariantQualifier2,
        [int]$LineStart,
        [int]$LineEnd,
        [int]$ColumnStart,
        [string]$Signature,
        [string]$ParentFunction,
        [string]$RawText,
        [string]$PurposeDescription,
        $Section
    )
    if ([string]::IsNullOrEmpty($ComponentName)) { return $null }

    $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }
    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|$ComponentType|$ComponentName|DEFINITION|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $sourceSection = if ($Section) { $Section.FullTitle } else { $null }

    $row = New-JsRow `
        -ComponentType      $ComponentType `
        -ComponentName      $ComponentName `
        -VariantType        $VariantType `
        -VariantQualifier1  $VariantQualifier1 `
        -VariantQualifier2  $VariantQualifier2 `
        -ReferenceType      'DEFINITION' `
        -Scope              $scope `
        -SourceFile         $script:CurrentFile `
        -SourceSection      $sourceSection `
        -Signature          $Signature `
        -ParentFunction     $ParentFunction `
        -RawText            $RawText `
        -PurposeDescription $PurposeDescription `
        -LineStart          $LineStart `
        -LineEnd            $LineEnd `
        -ColumnStart        $ColumnStart `
        -SuppressSectionLookup
    $script:rows.Add($row)
    return $row
}

# Emit a CSS_CLASS USAGE row for a class name referenced from JS.
function Add-ClassUsageRow {
    param(
        [string]$ClassName,
        [int]$LineStart, [int]$ColumnStart,
        [string]$Signature, [string]$ParentFunction, [string]$RawText
    )
    if ([string]::IsNullOrWhiteSpace($ClassName)) { return $null }

    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|CSS_CLASS|$ClassName|USAGE|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $row = New-JsRow `
        -ComponentType  'CSS_CLASS' `
        -ComponentName  $ClassName `
        -ReferenceType  'USAGE' `
        -Scope          '<pending>' `
        -SourceFile     '<pending>' `
        -LineStart      $LineStart `
        -LineEnd        $LineStart `
        -ColumnStart    $ColumnStart `
        -Signature      $Signature `
        -ParentFunction $ParentFunction `
        -RawText        $RawText
    $script:rows.Add($row)
    return $row
}

# Emit an HTML_ID row for an element id defined or referenced from JS.
function Add-HtmlIdRow {
    param(
        [string]$IdName, [string]$ReferenceType,
        [int]$LineStart, [int]$ColumnStart,
        [string]$Signature, [string]$ParentFunction, [string]$RawText
    )
    if ([string]::IsNullOrWhiteSpace($IdName)) { return $null }

    # DEFINITION rows: the JS file is declaring the ID itself, so it is
    # the source of truth (scope='LOCAL', source_file=current JS file).
    # USAGE rows: the JS file is referencing an ID defined elsewhere
    # (typically an HTML route file). The resolve phase fills in scope
    # and source_file by matching against HTML_ID DEFINITION rows.
    if ($ReferenceType -eq 'DEFINITION') {
        $rowScope      = 'LOCAL'
        $rowSourceFile = $script:CurrentFile
    } else {
        $rowScope      = '<pending>'
        $rowSourceFile = '<pending>'
    }

    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|HTML_ID|$IdName|$ReferenceType|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $row = New-JsRow `
        -ComponentType  'HTML_ID' `
        -ComponentName  $IdName `
        -ReferenceType  $ReferenceType `
        -Scope          $rowScope `
        -SourceFile     $rowSourceFile `
        -LineStart      $LineStart `
        -LineEnd        $LineStart `
        -ColumnStart    $ColumnStart `
        -Signature      $Signature `
        -ParentFunction $ParentFunction `
        -RawText        $RawText
    $script:rows.Add($row)

    # JS_HTML_ID_MALFORMED applies to both DEFINITION and USAGE rows --
    # an ill-formed ID written from JS is drift regardless of which side
    # of the catalog it lives on.
    if (Test-HtmlIdMalformed -IdName $IdName) {
        Add-DriftCode -Row $row -Code 'JS_HTML_ID_MALFORMED' `
            -Context "ID '$IdName' contains disallowed characters or does not begin with the file's registered cc_prefix + '-' or the chrome prefix 'cc-'."
    }

    return $row
}

# Emit class and id rows for HTML markup found inside a JS string literal.
function Add-RowsFromHtmlBearingText {
    param([string]$Text, [int]$StartLine, [int]$StartCol, [string]$ParentFunction, [string]$RawText)
    if (-not (Test-LooksLikeHtml -Text $Text)) { return }

    $occurrences = Get-HtmlAttributeOccurrences -Text $Text
    foreach ($occ in $occurrences) {
        $sourceLine = $StartLine + $occ.LineOffset
        $sourceCol  = if ($occ.LineOffset -eq 0) { $StartCol + $occ.ColumnStart - 1 } else { $occ.ColumnStart }

        if ($occ.Kind -eq 'id') {
            if ($occ.Value -match '^\s*\$\{[^}]+\}\s*$') { continue }
            if ($occ.Value -match '^\s*\$\w+\s*$')      { continue }
            Add-HtmlIdRow -IdName $occ.Value -ReferenceType 'DEFINITION' `
                -LineStart $sourceLine -ColumnStart $sourceCol `
                -Signature "id=`"$($occ.Value)`"" `
                -ParentFunction $ParentFunction `
                -RawText "id=`"$($occ.Value)`"" | Out-Null
        } else {
            $classNames = Split-ClassNames -Value $occ.Value
            foreach ($cls in $classNames) {
                Add-ClassUsageRow -ClassName $cls `
                    -LineStart $sourceLine -ColumnStart $sourceCol `
                    -Signature "class=`"$($occ.Value)`"" `
                    -ParentFunction $ParentFunction `
                    -RawText "class=`"$($occ.Value)`"" | Out-Null
            }
        }
    }
}

# Emit a JS_FUNCTION USAGE row for a function-call reference.
function Add-JsFunctionUsageRow {
    param(
        [string]$FunctionName,
        [int]$LineStart, [int]$ColumnStart,
        [string]$Signature, [string]$ParentFunction, [string]$RawText
    )
    if ([string]::IsNullOrEmpty($FunctionName)) { return $null }

    $sharedFns = Get-ZoneSharedFunctions
    $sharedSrc = Get-ZoneSharedSourceFile

    $scope = $null; $sourceFile = $null
    if ($sharedFns.Contains($FunctionName)) {
        $scope = 'SHARED'
        $sourceFile = if ($sharedSrc.ContainsKey($FunctionName)) { $sharedSrc[$FunctionName] } else { '<shared>' }
    }
    elseif ($script:CurrentLocalFuncs -and $script:CurrentLocalFuncs.Contains($FunctionName)) {
        $scope = 'LOCAL'
        $sourceFile = $script:CurrentFile
    }
    else {
        return $null
    }

    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|JS_FUNCTION|$FunctionName|USAGE|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $row = New-JsRow `
        -ComponentType  'JS_FUNCTION' `
        -ComponentName  $FunctionName `
        -ReferenceType  'USAGE' `
        -Scope          $scope `
        -SourceFile     $sourceFile `
        -LineStart      $LineStart `
        -LineEnd        $LineStart `
        -ColumnStart    $ColumnStart `
        -Signature      $Signature `
        -ParentFunction $ParentFunction `
        -RawText        $RawText
    $script:rows.Add($row)
    return $row
}

# Emit a JS_EVENT row for an addEventListener binding.
function Add-JsEventRow {
    param(
        [string]$EventName,
        [int]$LineStart, [int]$ColumnStart,
        [string]$Signature, [string]$ParentFunction, [string]$RawText,
        [bool]$IsForbidden = $false
    )
    if ([string]::IsNullOrWhiteSpace($EventName)) { return $null }

    $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }
    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|JS_EVENT|$EventName|USAGE|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $row = New-JsRow `
        -ComponentType  'JS_EVENT' `
        -ComponentName  $EventName `
        -ReferenceType  'USAGE' `
        -Scope          $scope `
        -SourceFile     $script:CurrentFile `
        -LineStart      $LineStart `
        -LineEnd        $LineStart `
        -ColumnStart    $ColumnStart `
        -Signature      $Signature `
        -ParentFunction $ParentFunction `
        -RawText        $RawText
    $script:rows.Add($row)

    if ($IsForbidden) {
        Add-DriftCode -Row $row -Code 'FORBIDDEN_PROPERTY_ASSIGN_EVENT' `
            -Context "Event '$EventName' bound via property-assign style at line $LineStart; spec requires addEventListener."
    }
    return $row
}

# Forbidden-pattern row emitters. Each pattern with no natural declaration
# host gets its own component_type and a dedicated row at the violation site
# with the corresponding FORBIDDEN_* drift attached.

# Emit a JS_IIFE row for an immediately-invoked function expression.
function Add-JsIifeRow {
    param([int]$LineStart, [int]$LineEnd, [int]$ColumnStart, [string]$Signature, [string]$RawText)
    $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }
    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|JS_IIFE|<iife>|DEFINITION|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $row = New-JsRow `
        -ComponentType 'JS_IIFE' -ComponentName '<iife>' `
        -ReferenceType 'DEFINITION' -Scope $scope -SourceFile $script:CurrentFile `
        -LineStart $LineStart -LineEnd $LineEnd -ColumnStart $ColumnStart `
        -Signature $Signature -RawText $RawText
    $script:rows.Add($row)
    Add-DriftCode -Row $row -Code 'FORBIDDEN_IIFE' -Context "IIFE at file scope, line $LineStart."
    return $row
}

# Emit a JS_EVAL row for an eval() call.
function Add-JsEvalRow {
    param([int]$LineStart, [int]$LineEnd, [int]$ColumnStart, [string]$Signature, [string]$ParentFunction, [string]$RawText)
    $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }
    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|JS_EVAL|<eval>|USAGE|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $row = New-JsRow `
        -ComponentType 'JS_EVAL' -ComponentName '<eval>' `
        -ReferenceType 'USAGE' -Scope $scope -SourceFile $script:CurrentFile `
        -LineStart $LineStart -LineEnd $LineEnd -ColumnStart $ColumnStart `
        -Signature $Signature -ParentFunction $ParentFunction -RawText $RawText
    $script:rows.Add($row)
    Add-DriftCode -Row $row -Code 'FORBIDDEN_EVAL' -Context "eval() called at line $LineStart."
    return $row
}

# Emit a JS_DOCUMENT_WRITE row for a document.write() call.
function Add-JsDocumentWriteRow {
    param([int]$LineStart, [int]$LineEnd, [int]$ColumnStart, [string]$Signature, [string]$ParentFunction, [string]$RawText)
    $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }
    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|JS_DOCUMENT_WRITE|<document.write>|USAGE|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $row = New-JsRow `
        -ComponentType 'JS_DOCUMENT_WRITE' -ComponentName '<document.write>' `
        -ReferenceType 'USAGE' -Scope $scope -SourceFile $script:CurrentFile `
        -LineStart $LineStart -LineEnd $LineEnd -ColumnStart $ColumnStart `
        -Signature $Signature -ParentFunction $ParentFunction -RawText $RawText
    $script:rows.Add($row)
    Add-DriftCode -Row $row -Code 'FORBIDDEN_DOCUMENT_WRITE' -Context "document.write() called at line $LineStart."
    return $row
}

# Emit a JS_WINDOW_ASSIGNMENT row for a window.X = ... assignment.
function Add-JsWindowAssignmentRow {
    param([string]$AssignedName, [int]$LineStart, [int]$LineEnd, [int]$ColumnStart, [string]$Signature, [string]$ParentFunction, [string]$RawText)
    $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }
    $componentName = "window.$AssignedName"
    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|JS_WINDOW_ASSIGNMENT|$componentName|DEFINITION|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $row = New-JsRow `
        -ComponentType 'JS_WINDOW_ASSIGNMENT' -ComponentName $componentName `
        -ReferenceType 'DEFINITION' -Scope $scope -SourceFile $script:CurrentFile `
        -LineStart $LineStart -LineEnd $LineEnd -ColumnStart $ColumnStart `
        -Signature $Signature -ParentFunction $ParentFunction -RawText $RawText
    $script:rows.Add($row)
    Add-DriftCode -Row $row -Code 'FORBIDDEN_WINDOW_ASSIGNMENT' `
        -Context "Assignment to $componentName at line $LineStart; outside cc-shared.js."
    return $row
}

# Emit a JS_INLINE_STYLE row for an inline <style> string.
function Add-JsInlineStyleRow {
    param([int]$LineStart, [int]$LineEnd, [int]$ColumnStart, [string]$Signature, [string]$ParentFunction, [string]$RawText)
    $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }
    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|JS_INLINE_STYLE|<style>|DEFINITION|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $row = New-JsRow `
        -ComponentType 'JS_INLINE_STYLE' -ComponentName '<style>' `
        -ReferenceType 'DEFINITION' -Scope $scope -SourceFile $script:CurrentFile `
        -LineStart $LineStart -LineEnd $LineEnd -ColumnStart $ColumnStart `
        -Signature $Signature -ParentFunction $ParentFunction -RawText $RawText
    $script:rows.Add($row)
    Add-DriftCode -Row $row -Code 'FORBIDDEN_INLINE_STYLE_IN_JS' `
        -Context "Template/string literal contains <style> at line $LineStart."
    return $row
}

# Emit a JS_INLINE_SCRIPT row for an inline <script> string.
function Add-JsInlineScriptRow {
    param([int]$LineStart, [int]$LineEnd, [int]$ColumnStart, [string]$Signature, [string]$ParentFunction, [string]$RawText)
    $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }
    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|JS_INLINE_SCRIPT|<script>|DEFINITION|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $row = New-JsRow `
        -ComponentType 'JS_INLINE_SCRIPT' -ComponentName '<script>' `
        -ReferenceType 'DEFINITION' -Scope $scope -SourceFile $script:CurrentFile `
        -LineStart $LineStart -LineEnd $LineEnd -ColumnStart $ColumnStart `
        -Signature $Signature -ParentFunction $ParentFunction -RawText $RawText
    $script:rows.Add($row)
    Add-DriftCode -Row $row -Code 'FORBIDDEN_INLINE_SCRIPT_IN_JS' `
        -Context "Template/string literal contains <script> at line $LineStart."
    return $row
}

# Emit a JS_INLINE_EVENT row for an inline HTML event-handler string.
function Add-JsInlineEventRow {
    param([int]$LineStart, [int]$LineEnd, [int]$ColumnStart, [string]$Signature, [string]$ParentFunction, [string]$RawText)
    $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }
    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|JS_INLINE_EVENT|<inline-event>|DEFINITION|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $row = New-JsRow `
        -ComponentType 'JS_INLINE_EVENT' -ComponentName '<inline-event>' `
        -ReferenceType 'DEFINITION' -Scope $scope -SourceFile $script:CurrentFile `
        -LineStart $LineStart -LineEnd $LineEnd -ColumnStart $ColumnStart `
        -Signature $Signature -ParentFunction $ParentFunction -RawText $RawText
    $script:rows.Add($row)
    Add-DriftCode -Row $row -Code 'FORBIDDEN_INLINE_EVENT_IN_JS' `
        -Context "Template/string literal contains inline on<event>=... at line $LineStart."
    return $row
}

# Emit a JS_LINE_COMMENT row for a file-scope // comment.
function Add-JsLineCommentRow {
    param([int]$LineStart, [int]$ColumnStart, [string]$RawText)
    $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }
    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|JS_LINE_COMMENT|<line-comment>|DEFINITION|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $row = New-JsRow `
        -ComponentType 'JS_LINE_COMMENT' -ComponentName '<line-comment>' `
        -ReferenceType 'DEFINITION' -Scope $scope -SourceFile $script:CurrentFile `
        -LineStart $LineStart -LineEnd $LineStart -ColumnStart $ColumnStart `
        -Signature $RawText -RawText $RawText `
        -SuppressSectionLookup
    $script:rows.Add($row)
    Add-DriftCode -Row $row -Code 'FORBIDDEN_FILE_SCOPE_LINE_COMMENT' `
        -Context "Line comment at file scope, line $LineStart."
    return $row
}

# Emit JS_DISPATCH_ENTRY rows for each property in a dispatch table's
# ObjectExpression. Column mapping per entry:
#   component_name      = action value (the kebab-case key)
#   variant_qualifier_1 = event name (mirrors HTML data-attribute placement)
#   variant_qualifier_2 = handler function name (the value-side identifier)
#   parent_function     = the dispatch table variable name
#   scope               = LOCAL page-side, SHARED shell-side
# MALFORMED_ACTION_KEY and UNRESOLVED_DISPATCH_HANDLER attach per entry.
function Add-JsDispatchEntryRows {
    param(
        [Parameter(Mandatory)][string]$TableName,
        [Parameter(Mandatory)][string]$EventName,
        [Parameter(Mandatory)][ValidateSet('page','shared')][string]$Side,
        [Parameter(Mandatory)]$ObjectNode
    )
    if ($null -eq $ObjectNode -or $null -eq $ObjectNode.properties) { return }

    $scope = if ($Side -eq 'shared') { 'SHARED' } else { 'LOCAL' }

    foreach ($prop in $ObjectNode.properties) {
        if ($null -eq $prop) { continue }
        if ($prop.type -ne 'Property') { continue }
        if ($prop.computed -eq $true)  { continue }

        # Extract the action key (key must be a string Literal or an
        # Identifier-shaped key; Identifier keys are extremely rare for
        # kebab-case action values so the spec assumes Literal).
        $actionKey = $null
        if ($prop.key.type -eq 'Literal' -and $prop.key.value -is [string]) {
            $actionKey = [string]$prop.key.value
        }
        elseif ($prop.key.type -eq 'Identifier' -and $prop.key.name) {
            # Identifier-shaped key (rare). Still cataloged so drift is visible.
            $actionKey = $prop.key.name
        }
        if ([string]::IsNullOrWhiteSpace($actionKey)) { continue }

        # Extract the handler function name (value side).
        $handlerName = $null
        if ($prop.value.type -eq 'Identifier' -and $prop.value.name) {
            $handlerName = $prop.value.name
        }
        # If the value is something more complex (a function expression
        # inline, a member expression, etc.) leave $handlerName null and
        # let UNRESOLVED_DISPATCH_HANDLER not fire -- but still emit the
        # row so the entry is cataloged.

        $entryLine = Get-NodeLine -Node $prop
        $entryCol  = Get-NodeColumn -Node $prop
        $entryEnd  = Get-NodeEndLine -Node $prop
        $sig       = "'$actionKey': $handlerName"

        $key = "$($script:CurrentFile)|$entryLine|$entryCol|JS_DISPATCH_ENTRY|$actionKey|DEFINITION|"
        if (-not (Test-AddDedupeKey -Key $key)) { continue }

        $section = Get-SectionForLine -Sections $script:CurrentSections -Line $entryLine
        $sourceSection = if ($section) { $section.FullTitle } else { $null }

        $row = New-JsRow `
            -ComponentType      'JS_DISPATCH_ENTRY' `
            -ComponentName      $actionKey `
            -VariantType        $null `
            -VariantQualifier1  $EventName `
            -VariantQualifier2  $handlerName `
            -ReferenceType      'DEFINITION' `
            -Scope              $scope `
            -SourceFile         $script:CurrentFile `
            -SourceSection      $sourceSection `
            -LineStart          $entryLine `
            -LineEnd            $entryEnd `
            -ColumnStart        $entryCol `
            -Signature          $sig `
            -ParentFunction     $TableName `
            -RawText            $sig `
            -SuppressSectionLookup
        $script:rows.Add($row)

        # MALFORMED_ACTION_KEY
        # Kebab-case base check: lowercase letters / digits / hyphens only.
        $kebabOK = ($actionKey -cmatch '^[a-z0-9]+(-[a-z0-9]+)*$')
        $sideOK  = $true
        if ($kebabOK) {
            if ($Side -eq 'page' -and $actionKey -like 'cc-*') {
                $sideOK = $false
            }
            if ($Side -eq 'shared' -and -not ($actionKey -like 'cc-*')) {
                $sideOK = $false
            }
        }
        if (-not $kebabOK -or -not $sideOK) {
            $reason = if (-not $kebabOK) {
                "key '$actionKey' is not kebab-case (lowercase letters, digits, hyphens only)"
            } elseif ($Side -eq 'page') {
                "page-side key '$actionKey' starts with 'cc-' which is reserved for shared chrome actions"
            } else {
                "shared-side key '$actionKey' does not start with 'cc-' (required for shared actions)"
            }
            Add-DriftCode -Row $row -Code 'MALFORMED_ACTION_KEY' -Context $reason
        }

        # UNRESOLVED_DISPATCH_HANDLER
        # Page-side handlers must resolve in the local function set.
        # Shared-side handlers must resolve in the cc-shared.js function set.
        # If $handlerName is null (non-Identifier value), skip the check.
        if (-not [string]::IsNullOrEmpty($handlerName)) {
            $resolved = $false
            if ($Side -eq 'page') {
                if ($script:CurrentLocalFuncs -and $script:CurrentLocalFuncs.Contains($handlerName)) {
                    $resolved = $true
                }
            } else {
                # Shared side: must be in the cc-zone shared functions (the
                # shell file lives in the cc zone).
                $ccSharedFns = if ($script:sharedFunctionsByZone -and $script:sharedFunctionsByZone.ContainsKey('cc')) {
                    $script:sharedFunctionsByZone['cc']
                } else { $null }
                if ($ccSharedFns -and $ccSharedFns.Contains($handlerName)) {
                    $resolved = $true
                }
            }
            if (-not $resolved) {
                $whereLooked = if ($Side -eq 'page') { 'the same file' } else { 'the shell file' }
                Add-DriftCode -Row $row -Code 'UNRESOLVED_DISPATCH_HANDLER' `
                    -Context "Handler '$handlerName' for action '$actionKey' does not resolve in $whereLooked."
            }
        }
    }
}

<# ============================================================================
   FUNCTIONS: LOCAL DEFINITION COLLECTION
   ----------------------------------------------------------------------------
   Collect a file's top-level definitions (functions, constants, state,
   classes) for same-file USAGE resolution, plus the likely timer-handle set.
   Prefix: (none)
   ============================================================================ #>

# Walk the top-level Program body and return sets of Functions / Constants /
# State / Classes, used for same-file USAGE resolution and prefix checks.
function Get-LocalDefinitions {
    param($ProgramBody)

    $funcs   = New-Object 'System.Collections.Generic.HashSet[string]'
    $consts  = New-Object 'System.Collections.Generic.HashSet[string]'
    $states  = New-Object 'System.Collections.Generic.HashSet[string]'
    $classes = New-Object 'System.Collections.Generic.HashSet[string]'

    if ($null -eq $ProgramBody) {
        return @{ Functions = $funcs; Constants = $consts; State = $states; Classes = $classes }
    }

    foreach ($stmt in $ProgramBody) {
        if ($null -eq $stmt) { continue }
        switch ($stmt.type) {
            'FunctionDeclaration' {
                if ($stmt.id -and $stmt.id.name) { [void]$funcs.Add($stmt.id.name) }
            }
            'VariableDeclaration' {
                foreach ($decl in $stmt.declarations) {
                    if (-not $decl.id -or $decl.id.type -ne 'Identifier') { continue }
                    $init = $decl.init
                    if ($init -and ($init.type -eq 'FunctionExpression' -or $init.type -eq 'ArrowFunctionExpression')) {
                        [void]$funcs.Add($decl.id.name)
                    }
                    elseif ($init -and $init.type -eq 'ClassExpression') {
                        [void]$classes.Add($decl.id.name)
                    }
                    elseif ($stmt.kind -eq 'var') {
                        [void]$states.Add($decl.id.name)
                    }
                    else {
                        [void]$consts.Add($decl.id.name)
                    }
                }
            }
            'ClassDeclaration' {
                if ($stmt.id -and $stmt.id.name) { [void]$classes.Add($stmt.id.name) }
            }
        }
    }

    return @{ Functions = $funcs; Constants = $consts; State = $states; Classes = $classes }
}

# Returns a HashSet of state-variable names that are likely timer handles.
# A "candidate" is any module-scope `var` whose initial value is null or
# whose name ends in 'Timer' or 'Interval'.
function Get-TimerHandleCandidates {
    param($ProgramBody)
    $candidates = New-Object 'System.Collections.Generic.HashSet[string]'
    if ($null -eq $ProgramBody) { return $candidates }

    foreach ($stmt in $ProgramBody) {
        if ($null -eq $stmt) { continue }
        if ($stmt.type -ne 'VariableDeclaration') { continue }
        if ($stmt.kind -ne 'var') { continue }
        foreach ($decl in $stmt.declarations) {
            if (-not $decl.id -or $decl.id.type -ne 'Identifier') { continue }
            $declName = $decl.id.name
            $isNullInit = ($null -eq $decl.init) -or
                          ($decl.init.type -eq 'Literal' -and $null -eq $decl.init.value)
            $nameMatches = $declName -match 'Timer$' -or $declName -match 'Interval$'
            if ($isNullInit -or $nameMatches) {
                [void]$candidates.Add($declName)
            }
        }
    }
    return $candidates
}

<# ============================================================================
   FUNCTIONS: JS VISITOR
   ----------------------------------------------------------------------------
   The per-node visitor consumed by Invoke-AstWalk. Receives
   ($Node, $ParentChain, $ParentNodes), reads per-file context from the
   $script:Current* variables, and emits the construct, usage, and
   forbidden-pattern rows for each node. Returning 'SKIP_CHILDREN' stops
   recursion into the current node's children.
   Prefix: (none)
   ============================================================================ #>

# Per-node visitor that emits catalog rows for each AST node during the walk.
function Invoke-JsVisitor {
    param($Node, $ParentChain, $ParentNodes)

    if ($null -eq $Node -or $null -eq $Node.type) { return }

    # NOTE: there is no pre-switch setup. The five legacy preamble values
    # ($line, $endLine, $col, $section, $parentName) are computed lazily
    # inside each switch case that needs them, AFTER any early-rejection
    # checks. This avoids paying the setup tax on the 60-70% of node
    # visits that fall through the switch with no work to do, and on the
    # node visits that match a case but are then rejected by case-level
    # gating (e.g., FunctionDeclaration rejected by Test-IsTopLevel).

    switch ($Node.type) {

        'FunctionDeclaration' {
            if ($script:CurrentSuppressDefinitions) { return }
            if (-not $Node.id -or -not $Node.id.name) { return }
            $isTopLevel    = Test-IsTopLevel -ParentChain $ParentChain
            $isConditional = Test-IsConditionallyDefined -ParentChain $ParentChain
            if (-not $isTopLevel) { return }

            # Per-case setup. This case emits a row, so it needs position
            # info ($line / $endLine / $col) and the containing section.
            # It does NOT use $parentName; top-level functions have no
            # meaningful "parent function" context.
            $line    = Get-NodeLine    -Node $Node
            $endLine = Get-NodeEndLine -Node $Node
            $col     = Get-NodeColumn  -Node $Node
            $section = Get-SectionForLine -Sections $script:CurrentSections -Line $line

            $fnName = $Node.id.name
            $sig = if ($Node.async -eq $true)     { "async function $fnName(" }
                   elseif ($Node.generator -eq $true) { "function* $fnName(" }
                   else                            { "function $fnName(" }
            if ($Node.params) {
                $paramNames = @()
                foreach ($p in $Node.params) {
                    if ($p.type -eq 'Identifier') { $paramNames += $p.name }
                    elseif ($p.type -eq 'AssignmentPattern' -and $p.left.type -eq 'Identifier') { $paramNames += $p.left.name }
                    elseif ($p.type -eq 'RestElement' -and $p.argument.type -eq 'Identifier')   { $paramNames += "...$($p.argument.name)" }
                    else { $paramNames += '?' }
                }
                $sig += ($paramNames -join ', ')
            }
            $sig += ')'

            $isInHooksBanner = ($section -and $section.TypeName -eq 'FUNCTIONS' -and $section.BannerName -eq $script:HooksBannerName)
            $shape = if ($isInHooksBanner) { Get-HookVariantShape -Node $Node } else { Get-FunctionVariantShape -Node $Node }

            $rawComment = Get-PrecedingBlockComment -CommentIndex $script:CurrentCommentIndex -DefinitionLine $line
            $purpose    = ConvertTo-CleanCommentText -CommentText $rawComment

            $row = Add-JsDefinitionRow `
                -ComponentType $shape.ComponentType `
                -ComponentName $fnName `
                -VariantType $shape.VariantType `
                -VariantQualifier1 $shape.VariantQualifier1 `
                -VariantQualifier2 $shape.VariantQualifier2 `
                -LineStart $line -LineEnd $endLine -ColumnStart $col `
                -Signature $sig -ParentFunction $null -RawText $sig `
                -PurposeDescription $purpose -Section $section
            if (-not $row) { return }

            if ($isConditional) {
                Add-DriftCode -Row $row -Code 'FORBIDDEN_CONDITIONAL_DEFINITION' `
                    -Context "Function '$fnName' is declared inside a conditional/loop/try block; spec requires unconditional top-level definitions."
            }

            if ($null -eq $section) {
                Add-DriftCode -Row $row -Code 'MISSING_SECTION_BANNER' -Context "Function '$fnName' appears outside any section banner."
            }
            else {
                $isHook = ($shape.ComponentType -eq 'JS_HOOK' -or $shape.ComponentType -eq 'JS_HOOK_VARIANT')
                $isContractId = Test-IsContractIdentifier -IdentifierName $fnName
                if (-not $isHook -and -not $isContractId -and -not $section.IsPrefixNone) {
                    $expectedPrefix = $section.PrefixValue
                    if (-not [string]::IsNullOrEmpty($expectedPrefix)) {
                        $expected = "$expectedPrefix" + "_"
                        if (-not $fnName.StartsWith($expected)) {
                            Add-DriftCode -Row $row -Code 'PREFIX_MISMATCH' `
                                -Context "Function '$fnName' does not start with section prefix '$expected'."
                        }
                    }
                }
                elseif ($isHook) {
                    #  hook function names carry the page prefix
                    # (e.g., 'bkp_onPageRefresh'); the recognized-hook set
                    # holds bare suffixes ('onPageRefresh'). Strip the
                    # registered prefix plus underscore before matching.
                    # When the file has no registered prefix, fall back to
                    # full-identifier match so non-page files still validate.
                    $hookSuffix = Get-HookSuffix -FunctionName $fnName
                    if ($script:RecognizedHookNames -notcontains $hookSuffix) {
                        Add-DriftCode -Row $row -Code 'UNKNOWN_HOOK_NAME' `
                            -Context "Function '$fnName' is in the PAGE LIFECYCLE HOOKS banner but its suffix '$hookSuffix' is not a recognized hook name."
                    }
                }
            }

            # HOOK_MISPLACED
            # A function whose suffix matches a recognized hook name must be
            # in the FUNCTIONS: PAGE LIFECYCLE HOOKS banner. Anywhere else
            # fires the drift. Like
            # UNKNOWN_HOOK_NAME, the match is by suffix after stripping the
            # registered prefix.
            $hookSuffixForMisplaced = Get-HookSuffix -FunctionName $fnName
            if ($script:RecognizedHookNames -contains $hookSuffixForMisplaced -and -not $isInHooksBanner) {
                $whereLocation = if ($null -eq $section) {
                    'outside any section banner'
                } else {
                    "section '$($section.FullTitle)'"
                }
                Add-DriftCode -Row $row -Code 'HOOK_MISPLACED' `
                    -Context "Hook function '$fnName' is declared in $whereLocation; required home is 'FUNCTIONS: PAGE LIFECYCLE HOOKS'."
            }

            # INIT_MISPLACED (function side)
            # <prefix>_init lives alone in
            # the INITIALIZATION banner. Two function-side firing points:
            # 1. <prefix>_init declared anywhere other than INITIALIZATION
            # 2. Any function other than <prefix>_init declared inside
            # INITIALIZATION
            # The third firing point (INITIALIZATION not the first FUNCTIONS
            # banner) fires on the COMMENT_BANNER row in Add-CommentBannerRow.
            # Files with no registered cc_prefix (cc-shared.js, etc.) skip
            # both checks - there's no init function expected.
            if ($script:CurrentRegistryHasMapping -and
                -not [string]::IsNullOrEmpty($script:CurrentRegistryPrefix) -and
                -not $script:CurrentFileIsShared) {
                $expectedInitName = "$($script:CurrentRegistryPrefix)_init"
                $isInitFn         = ($fnName -eq $expectedInitName)
                $isInInitBanner   = ($section -and
                                     $section.TypeName -eq 'FUNCTIONS' -and
                                     $section.BannerName -eq $script:InitBannerName)

                if ($isInitFn -and -not $isInInitBanner) {
                    $whereLocation = if ($null -eq $section) {
                        'outside any section banner'
                    } else {
                        "section '$($section.FullTitle)'"
                    }
                    Add-DriftCode -Row $row -Code 'INIT_MISPLACED' `
                        -Context "Init function '$fnName' is declared in $whereLocation; required home is 'FUNCTIONS: INITIALIZATION'."
                }
                elseif (-not $isInitFn -and $isInInitBanner) {
                    Add-DriftCode -Row $row -Code 'INIT_MISPLACED' `
                        -Context "Function '$fnName' is declared inside the INITIALIZATION banner; only '$expectedInitName' may live there."
                }
            }

            # PREFIX_MISSING: registered cc_prefix vs identifier name.
            # Independent of banners; complements PREFIX_MISMATCH for pre-spec
            # files that haven't added banners yet. Hooks are exempt (their
            # names are registered hook names, not prefixed identifiers).
            $isHookFn = ($shape.ComponentType -eq 'JS_HOOK' -or $shape.ComponentType -eq 'JS_HOOK_VARIANT')
            if (-not $isHookFn -and (Test-PrefixMissing -IdentifierName $fnName)) {
                Add-DriftCode -Row $row -Code 'PREFIX_MISSING' `
                    -Context "Function '$fnName' does not start with the file's registered prefix '$($script:CurrentRegistryPrefix)_'."
            }

            if ([string]::IsNullOrEmpty($purpose)) {
                Add-DriftCode -Row $row -Code 'MISSING_FUNCTION_COMMENT' -Context "Function '$fnName' has no preceding purpose comment."
            }

            # BLANK_LINE_INSIDE_FUNCTION_BODY_AT_SCOPE: walk the function's
            # body statements and detect more than one consecutive blank
            # line between them. more than one
            # consecutive blank line inside a function body is drift. The
            # rule is intentionally scoped to top-level function
            # declarations only (the rows this case emits); methods inside
            # classes are out of scope. See the JS spec appendix entry for
            # rationale.
            # Detection uses the source text rather than line-number
            # differences so comment lines between statements do not inflate
            # the blank count. A purpose comment immediately preceding a
            # statement should not trigger this drift just because the
            # comment occupies several lines.
            if ($Node.body -and $Node.body.body -and $Node.body.body.Count -ge 2) {
                $bodyStmts = $Node.body.body
                for ($si = 1; $si -lt $bodyStmts.Count; $si++) {
                    $prevStmt = $bodyStmts[$si - 1]
                    $curStmt  = $bodyStmts[$si]
                    $prevEnd  = if ($prevStmt.loc -and $prevStmt.loc.end)   { [int]$prevStmt.loc.end.line   } else { 0 }
                    $curStart = if ($curStmt.loc  -and $curStmt.loc.start) { [int]$curStmt.loc.start.line } else { 0 }
                    if ($prevEnd -gt 0 -and $curStart -gt 0) {
                        $blankRun = Get-MaxConsecutiveBlankLines `
                            -Source    $script:CurrentFileSource `
                            -StartLine $prevEnd `
                            -EndLine   $curStart
                        if ($blankRun -gt 1) {
                            Add-DriftCode -Row $row -Code 'BLANK_LINE_INSIDE_FUNCTION_BODY_AT_SCOPE' `
                                -Context "Function '$fnName' has more than one consecutive blank line between body statements at line $curStart."
                            break
                        }
                    }
                }
            }
        }

        'VariableDeclaration' {
            if ($script:CurrentSuppressDefinitions) { return }
            $isTopLevel = Test-IsTopLevel -ParentChain $ParentChain
            if (-not $isTopLevel) { return }

            # Per-case setup. This case emits rows per declarator using
            # per-declarator $declLine / $declCol values (declarators on
            # one statement may not all sit on the same line), so the
            # case-level $line / $endLine / $col are not needed. Only
            # $section is needed at case scope - it's the same for every
            # declarator in this statement.
            $line    = Get-NodeLine -Node $Node
            $section = Get-SectionForLine -Sections $script:CurrentSections -Line $line

            $isMulti = ($Node.declarations -and $Node.declarations.Count -gt 1)
            $isLet   = ($Node.kind -eq 'let')

            # Revealing-module IIFE detection: const X = (function(){...})();
            # or var X = (function(){...})(); -- the entire file's design is
            # encapsulated in an immediately-invoked factory whose return value
            # is bound to a single name. This pattern is structurally non-spec
            # (functions inside the IIFE cannot be migrated to top-level
            # declarations without rewriting every call site that references
            # them). Catalog the wrapper itself with FORBIDDEN_REVEALING_MODULE
            # drift, then turn on definition suppression so inner function /
            # const / class declarations are NOT emitted as definition rows.
            # The walker still descends so USAGE rows (CSS_CLASS / HTML_ID /
            # JS_FUNCTION usage / JS_EVENT / forbidden-pattern detections)
            # continue to fire -- those references reach DOM / call shared
            # functions at runtime regardless of the wrapper, and the
            # cross-reference catalog needs them.
            if (-not $isMulti -and $Node.declarations.Count -eq 1) {
                $singleDecl = $Node.declarations[0]
                if ($singleDecl -and $singleDecl.id -and $singleDecl.id.type -eq 'Identifier' -and $singleDecl.init) {
                    $rmInit = $singleDecl.init
                    if ($rmInit.type -eq 'CallExpression' -and $rmInit.callee -and
                        ($rmInit.callee.type -eq 'FunctionExpression' -or $rmInit.callee.type -eq 'ArrowFunctionExpression')) {
                        $rmName  = $singleDecl.id.name
                        $rmLine  = Get-NodeLine    -Node $singleDecl
                        $rmCol   = Get-NodeColumn  -Node $singleDecl
                        $rmEnd   = Get-NodeEndLine -Node $Node
                        $rmShape = if ($rmInit.callee.type -eq 'ArrowFunctionExpression') {
                            "$($Node.kind) $rmName = (() => { ... })()"
                        } else {
                            "$($Node.kind) $rmName = (function() { ... })()"
                        }
                        $rmRawSnippet = Get-RangeText -Source $script:CurrentFileSource -Node $Node

                        $rawComment = Get-PrecedingBlockComment -CommentIndex $script:CurrentCommentIndex -DefinitionLine $rmLine
                        $purpose    = ConvertTo-CleanCommentText -CommentText $rawComment

                        # Component type: keep the natural classification
                        # (var-with-IIFE-init = JS_STATE; const-with-IIFE-init
                        # = JS_CONSTANT_VARIANT 'expression'). The drift code
                        # is what flags the wrapper; the component type
                        # remains true to the AST shape.
                        if ($Node.kind -eq 'var') {
                            $rmComponentType = 'JS_STATE'
                            $rmVariantType   = $null
                        } else {
                            $rmComponentType = 'JS_CONSTANT_VARIANT'
                            $rmVariantType   = 'expression'
                        }

                        $row = Add-JsDefinitionRow `
                            -ComponentType $rmComponentType -ComponentName $rmName `
                            -VariantType $rmVariantType -VariantQualifier1 $null -VariantQualifier2 $null `
                            -LineStart $rmLine -LineEnd $rmEnd -ColumnStart $rmCol `
                            -Signature $rmShape -ParentFunction $null -RawText $rmRawSnippet `
                            -PurposeDescription $purpose -Section $section
                        if ($row) {
                            Add-DriftCode -Row $row -Code 'FORBIDDEN_REVEALING_MODULE' `
                                -Context "'$rmName' is initialized by an IIFE; this wraps the file in a non-spec namespace and requires a full rewrite to top-level functions."
                            if ($isLet) {
                                Add-DriftCode -Row $row -Code 'FORBIDDEN_LET' -Context "'$rmName' is declared with 'let'."
                            }
                            if ($null -eq $section) {
                                Add-DriftCode -Row $row -Code 'MISSING_SECTION_BANNER' -Context "'$rmName' appears outside any section banner."
                            }
                            if (Test-PrefixMissing -IdentifierName $rmName) {
                                Add-DriftCode -Row $row -Code 'PREFIX_MISSING' `
                                    -Context "'$rmName' does not start with the file's registered prefix '$($script:CurrentRegistryPrefix)_'."
                            }
                        }
                        # Turn on definition suppression for the rest of this
                        # file. Walker continues descending; USAGE rows still
                        # fire, but inner function / const / class definitions
                        # are skipped.
                        $script:CurrentSuppressDefinitions = $true
                        return
                    }
                }
            }

            foreach ($decl in $Node.declarations) {
                if (-not $decl.id -or $decl.id.type -ne 'Identifier') { continue }
                $declName = $decl.id.name
                $declLine = Get-NodeLine    -Node $decl
                $declCol  = Get-NodeColumn  -Node $decl
                $declEnd  = Get-NodeEndLine -Node $decl
                $init     = $decl.init

                # ClassExpression assigned to const/var -> JS_CLASS row.
                if ($init -and $init.type -eq 'ClassExpression') {
                    $sig = "$($Node.kind) $declName = class"
                    $rawComment = Get-PrecedingBlockComment -CommentIndex $script:CurrentCommentIndex -DefinitionLine $declLine
                    $purpose    = ConvertTo-CleanCommentText -CommentText $rawComment

                    $row = Add-JsDefinitionRow -ComponentType 'JS_CLASS' -ComponentName $declName `
                        -VariantType $null -VariantQualifier1 $null -VariantQualifier2 $null `
                        -LineStart $declLine -LineEnd $declEnd -ColumnStart $declCol `
                        -Signature $sig -ParentFunction $null -RawText $sig `
                        -PurposeDescription $purpose -Section $section
                    if ($row) {
                        if ($isLet)   { Add-DriftCode -Row $row -Code 'FORBIDDEN_LET' -Context "Class '$declName' is declared with 'let'." }
                        if ($isMulti) { Add-DriftCode -Row $row -Code 'FORBIDDEN_MULTI_DECLARATION' }
                        if ([string]::IsNullOrEmpty($purpose)) {
                            Add-DriftCode -Row $row -Code 'MISSING_CLASS_COMMENT' -Context "Class '$declName' has no preceding purpose comment."
                        }
                    }
                    continue
                }

                $isFunctionInit    = ($init -and ($init.type -eq 'FunctionExpression' -or $init.type -eq 'ArrowFunctionExpression'))
                $isConstantSection = ($section -and ($section.TypeName -eq 'CONSTANTS' -or $section.TypeName -eq 'FOUNDATION'))
                $isStateSection    = ($section -and $section.TypeName -eq 'STATE')

                # ENGINE_PROCESSES carve-out.4:
                # the contract identifier (bare 'ENGINE_PROCESSES' or
                # prefixed '<prefix>_ENGINE_PROCESSES') declared with var
                # in a 'CONSTANTS: ENGINE PROCESSES' banner is
                # spec-compliant. The row is emitted as JS_STATE (not
                # JS_CONSTANT_VARIANT) per /, and the keyword
                # carve-out below skips WRONG_DECLARATION_KEYWORD for the
                # same shape. Used by three sites: row-type derivation here,
                # WRONG_DECLARATION_KEYWORD a few lines down, and the
                # ENGINE_PROCESSES capture site further on.
                $isEngineProcessesName = Test-IsEngineProcessesName -IdentifierName $declName
                $isInEngineProcessesBanner = ($section -and
                                              $section.TypeName -eq 'CONSTANTS' -and
                                              $section.BannerName -eq $script:EngineProcessesBannerName)
                $isEngineProcessesCarveOut = ($isEngineProcessesName -and
                                              $Node.kind -eq 'var' -and
                                              $isInEngineProcessesBanner)

                # Component type derivation: ENGINE_PROCESSES carve-out
                # first, then section-context, fall back to keyword.
                $isStateComponent = $false
                if ($isEngineProcessesCarveOut) { $isStateComponent = $true }
                elseif ($isStateSection)        { $isStateComponent = $true }
                elseif ($isConstantSection)     { $isStateComponent = $false }
                elseif ($Node.kind -eq 'var')   { $isStateComponent = $true }
                else                            { $isStateComponent = $false }

                if ($isStateComponent) {
                    $shape = @{ ComponentType = 'JS_STATE'; VariantType = $null; VariantQualifier1 = $null; VariantQualifier2 = $null }
                } else {
                    $shape = Get-ConstantVariantShape -InitNode $init
                }

                $valSig = if ($init -and $init.type -eq 'Literal') { "$($Node.kind) $declName = $($init.raw)" }
                          elseif ($init)                            { "$($Node.kind) $declName = ..." }
                          else                                       { "$($Node.kind) $declName" }

                $rawComment = Get-PrecedingBlockComment -CommentIndex $script:CurrentCommentIndex -DefinitionLine $declLine
                $purpose    = ConvertTo-CleanCommentText -CommentText $rawComment

                $row = Add-JsDefinitionRow `
                    -ComponentType $shape.ComponentType -ComponentName $declName `
                    -VariantType $shape.VariantType `
                    -VariantQualifier1 $shape.VariantQualifier1 `
                    -VariantQualifier2 $shape.VariantQualifier2 `
                    -LineStart $declLine -LineEnd $declEnd -ColumnStart $declCol `
                    -Signature $valSig -ParentFunction $null -RawText $valSig `
                    -PurposeDescription $purpose -Section $section
                if (-not $row) { continue }

                if ($isLet)   { Add-DriftCode -Row $row -Code 'FORBIDDEN_LET' -Context "'$declName' is declared with 'let'." }
                if ($isMulti) { Add-DriftCode -Row $row -Code 'FORBIDDEN_MULTI_DECLARATION' -Context "Multiple declarations on one statement." }

                if ($isFunctionInit) {
                    $shapeWord = if ($init.type -eq 'ArrowFunctionExpression') { 'arrow function' } else { 'function expression' }
                    Add-DriftCode -Row $row -Code 'FORBIDDEN_ANONYMOUS_FUNCTION' `
                        -Context "$declName is assigned a $shapeWord; spec mandates the 'function name() {}' form for function definitions."
                }

                # WRONG_DECLARATION_KEYWORD with ENGINE_PROCESSES carve-out.
                # <prefix>_ENGINE_PROCESSES is the sole permitted
                # 'var' declaration in a CONSTANTS section.
                if ($isEngineProcessesCarveOut) {
                    # Spec-compliant per ; no drift.
                }
                elseif ($isConstantSection -and $Node.kind -ne 'const') {
                    Add-DriftCode -Row $row -Code 'WRONG_DECLARATION_KEYWORD' `
                        -Context "'$declName' uses '$($Node.kind)' in a CONSTANTS-style section; spec requires 'const'."
                }
                elseif ($isStateSection -and $Node.kind -ne 'var') {
                    Add-DriftCode -Row $row -Code 'WRONG_DECLARATION_KEYWORD' `
                        -Context "'$declName' uses '$($Node.kind)' in a STATE section; spec requires 'var'."
                }

                if ([string]::IsNullOrEmpty($purpose)) {
                    if ($isStateComponent) {
                        Add-DriftCode -Row $row -Code 'MISSING_STATE_COMMENT' -Context "State variable '$declName' has no preceding purpose comment."
                    } else {
                        Add-DriftCode -Row $row -Code 'MISSING_CONSTANT_COMMENT' -Context "Constant '$declName' has no preceding purpose comment."
                    }
                }

                if ($null -eq $section) {
                    Add-DriftCode -Row $row -Code 'MISSING_SECTION_BANNER' -Context "'$declName' appears outside any section banner."
                }
                elseif (-not (Test-IsContractIdentifier -IdentifierName $declName) -and -not $section.IsPrefixNone) {
                    $expectedPrefix = $section.PrefixValue
                    if (-not [string]::IsNullOrEmpty($expectedPrefix)) {
                        $expected = "$expectedPrefix" + "_"
                        if (-not $declName.StartsWith($expected)) {
                            Add-DriftCode -Row $row -Code 'PREFIX_MISMATCH' `
                                -Context "'$declName' does not start with section prefix '$expected'."
                        }
                    }
                }

                # PREFIX_MISSING: registered cc_prefix vs identifier name.
                # Independent of banners.
                if (Test-PrefixMissing -IdentifierName $declName) {
                    Add-DriftCode -Row $row -Code 'PREFIX_MISSING' `
                        -Context "'$declName' does not start with the file's registered prefix '$($script:CurrentRegistryPrefix)_'."
                }

                # ENGINE_PROCESSES_MISPLACED
                # The ENGINE_PROCESSES contract identifier (bare or
                # <prefix>_ENGINE_PROCESSES form) must live in the
                # CONSTANTS: ENGINE PROCESSES banner. Anywhere else
                # (STATE banner, different CONSTANTS banner, no banner)
                # fires the drift.
                if ($isEngineProcessesName) {
                    $isInRequiredBanner = ($null -ne $section -and
                                           $section.TypeName -eq 'CONSTANTS' -and
                                           $section.BannerName -eq $script:EngineProcessesBannerName)
                    if (-not $isInRequiredBanner) {
                        $whereLocation = if ($null -eq $section) {
                            'outside any section banner'
                        } else {
                            "section '$($section.FullTitle)'"
                        }
                        Add-DriftCode -Row $row -Code 'ENGINE_PROCESSES_MISPLACED' `
                            -Context "'$declName' is declared in $whereLocation; required home is 'CONSTANTS: ENGINE PROCESSES'."
                    }
                }

                # ENGINE_PROCESSES capture
                # When a top-level ENGINE_PROCESSES declarator is initialized to
                # an ObjectExpression (const or legacy var form), record the row
                # and extract each entry's process_name (key) and slug for
                # post-walk validation. Expected shape:
                # {
                #   'Process-Name': { slug: 'slug-value' },
                #   'Other-Process': { slug: 'other-slug' }
                # }
                # Only the first ENGINE_PROCESSES declaration is captured.
                if ($isEngineProcessesName -and
                    $init -and $init.type -eq 'ObjectExpression' -and
                    $null -eq $script:CurrentEngineProcessesRow) {

                    $script:CurrentEngineProcessesRow     = $row
                    $script:CurrentEngineProcessesEntries = New-Object System.Collections.Generic.List[object]

                    foreach ($entryProp in $init.properties) {
                        if ($null -eq $entryProp -or $entryProp.type -ne 'Property') { continue }
                        if ($entryProp.computed -eq $true) { continue }

                        # The key is the process name (a string literal).
                        $processName = $null
                        if ($entryProp.key.type -eq 'Literal' -and $entryProp.key.value -is [string]) {
                            $processName = [string]$entryProp.key.value
                        }
                        elseif ($entryProp.key.type -eq 'Identifier' -and $entryProp.key.name) {
                            # Identifier-shaped key (rare for process names but
                            # syntactically valid). Captured so downstream
                            # validation can still detect drift.
                            $processName = $entryProp.key.name
                        }
                        if ([string]::IsNullOrEmpty($processName)) { continue }

                        # The value is an ObjectExpression containing the slug.
                        $entrySlug = $null
                        if ($entryProp.value.type -eq 'ObjectExpression') {
                            foreach ($valueProp in $entryProp.value.properties) {
                                if ($null -eq $valueProp -or $valueProp.type -ne 'Property') { continue }
                                if ($valueProp.computed -eq $true) { continue }

                                $valueKeyName = $null
                                if ($valueProp.key.type -eq 'Identifier') {
                                    $valueKeyName = $valueProp.key.name
                                }
                                elseif ($valueProp.key.type -eq 'Literal' -and $valueProp.key.value -is [string]) {
                                    $valueKeyName = [string]$valueProp.key.value
                                }

                                if ($valueKeyName -eq 'slug' -and
                                    $valueProp.value.type -eq 'Literal' -and
                                    $valueProp.value.value -is [string]) {
                                    $entrySlug = [string]$valueProp.value.value
                                }
                            }
                        }

                        $script:CurrentEngineProcessesEntries.Add(@{
                            ProcessName = $processName
                            Slug        = $entrySlug
                            Line        = Get-NodeLine -Node $entryProp
                        })
                    }
                }

                # JS_DISPATCH_ENTRY emission
                # If this declarator names a dispatch table (page-side
                # <prefix>_<event>Actions or shared-side sharedXxxActions in
                # cc-shared.js) and its initializer is an ObjectExpression,
                # emit one JS_DISPATCH_ENTRY row per property in the object.
                # Suppressed when the file is under a forbidden wrapper -- the
                # outer JS_CONSTANT_VARIANT row already exists above and
                # carries the wrapper drift; entry rows underneath a non-spec
                # wrapper would just be noise.
                if (-not $script:CurrentSuppressDefinitions -and
                    $init -and $init.type -eq 'ObjectExpression') {
                    $dispatchInfo = Get-DispatchTableInfo -Name $declName
                    if ($dispatchInfo.IsDispatchTable) {
                        # Shared-side tables are only meaningful in the shell
                        # file. A shared<Event>Actions elsewhere is treated as
                        # a regular const -- no dispatch rows emitted -- since
                        # the file-kind rules already flag the wrong placement.
                        $isSharedInWrongFile = ($dispatchInfo.Side -eq 'shared' -and
                                                -not $script:CurrentFileIsShell)
                        if (-not $isSharedInWrongFile) {
                            Add-JsDispatchEntryRows `
                                -TableName  $declName `
                                -EventName  $dispatchInfo.EventName `
                                -Side       $dispatchInfo.Side `
                                -ObjectNode $init
                        }
                    }
                }
            }
        }

        'ClassDeclaration' {
            if ($script:CurrentSuppressDefinitions) { return }
            $isTopLevel = Test-IsTopLevel -ParentChain $ParentChain
            if (-not $isTopLevel) { return }
            if (-not $Node.id -or -not $Node.id.name) { return }

            # Per-case setup. Emits a row, so position info + section.
            # No $parentName - top-level classes have no parent function.
            $line    = Get-NodeLine    -Node $Node
            $endLine = Get-NodeEndLine -Node $Node
            $col     = Get-NodeColumn  -Node $Node
            $section = Get-SectionForLine -Sections $script:CurrentSections -Line $line

            $clsName = $Node.id.name
            $sig = "class $clsName"
            if ($Node.superClass -and $Node.superClass.name) { $sig += " extends $($Node.superClass.name)" }

            $rawComment = Get-PrecedingBlockComment -CommentIndex $script:CurrentCommentIndex -DefinitionLine $line
            $purpose    = ConvertTo-CleanCommentText -CommentText $rawComment

            $row = Add-JsDefinitionRow -ComponentType 'JS_CLASS' -ComponentName $clsName `
                -VariantType $null -VariantQualifier1 $null -VariantQualifier2 $null `
                -LineStart $line -LineEnd $endLine -ColumnStart $col `
                -Signature $sig -ParentFunction $null -RawText $sig `
                -PurposeDescription $purpose -Section $section
            if (-not $row) { return }

            if ([string]::IsNullOrEmpty($purpose)) {
                Add-DriftCode -Row $row -Code 'MISSING_CLASS_COMMENT' -Context "Class '$clsName' has no preceding purpose comment."
            }
            if ($null -eq $section) {
                Add-DriftCode -Row $row -Code 'MISSING_SECTION_BANNER' -Context "Class '$clsName' appears outside any section banner."
            }
            elseif (-not (Test-IsContractIdentifier -IdentifierName $clsName) -and -not $section.IsPrefixNone) {
                $expectedPrefix = $section.PrefixValue
                if (-not [string]::IsNullOrEmpty($expectedPrefix)) {
                    $expected = "$expectedPrefix" + "_"
                    if (-not $clsName.StartsWith($expected)) {
                        Add-DriftCode -Row $row -Code 'PREFIX_MISMATCH' `
                            -Context "Class '$clsName' does not start with section prefix '$expected'."
                    }
                }
            }

            # PREFIX_MISSING: registered cc_prefix vs identifier name.
            # Independent of banners.
            if (Test-PrefixMissing -IdentifierName $clsName) {
                Add-DriftCode -Row $row -Code 'PREFIX_MISSING' `
                    -Context "Class '$clsName' does not start with the file's registered prefix '$($script:CurrentRegistryPrefix)_'."
            }
        }

        'MethodDefinition' {
            if ($script:CurrentSuppressDefinitions) { return }
            $methodName = $null
            if ($Node.key -and $Node.key.type -eq 'Identifier') {
                $methodName = $Node.key.name
            }
            elseif ($Node.kind -eq 'constructor') {
                $methodName = 'constructor'
            }
            else {
                return
            }

            # Per-case setup. Emits a row, so position info + section.
            # No $parentName at the case level - the parent class name is
            # computed below by walking $ParentNodes for ClassDeclaration /
            # ClassExpression.
            $line    = Get-NodeLine    -Node $Node
            $endLine = Get-NodeEndLine -Node $Node
            $col     = Get-NodeColumn  -Node $Node
            $section = Get-SectionForLine -Sections $script:CurrentSections -Line $line

            $sig = "$methodName(...)"
            if ($Node.kind -eq 'constructor') { $sig = "constructor(...)" }

            $shape = Get-MethodVariantShape -Node $Node

            $className = $null
            for ($i = $ParentNodes.Count - 1; $i -ge 0; $i--) {
                $p = $ParentNodes[$i]
                if ($null -eq $p) { continue }
                if (-not ($p.PSObject.Properties.Name -contains 'type')) { continue }
                if ($p.type -eq 'ClassDeclaration' -or $p.type -eq 'ClassExpression') {
                    if ($p.id -and $p.id.name) { $className = $p.id.name }
                    break
                }
            }

            $rawComment = Get-PrecedingBlockComment -CommentIndex $script:CurrentCommentIndex -DefinitionLine $line
            $purpose    = ConvertTo-CleanCommentText -CommentText $rawComment

            $row = Add-JsDefinitionRow -ComponentType $shape.ComponentType -ComponentName $methodName `
                -VariantType $shape.VariantType `
                -VariantQualifier1 $shape.VariantQualifier1 `
                -VariantQualifier2 $shape.VariantQualifier2 `
                -LineStart $line -LineEnd $endLine -ColumnStart $col `
                -Signature $sig -ParentFunction $className -RawText $sig `
                -PurposeDescription $purpose -Section $section
            if (-not $row) { return }

            if ([string]::IsNullOrEmpty($purpose)) {
                Add-DriftCode -Row $row -Code 'MISSING_METHOD_COMMENT' -Context "Method '$methodName' has no preceding purpose comment."
            }
        }

        'ImportDeclaration' {
            if ($script:CurrentSuppressDefinitions) { return }

            # Per-case setup. Emits a row per specifier; all specifiers in
            # one import statement share the same position and section.
            $line    = Get-NodeLine    -Node $Node
            $endLine = Get-NodeEndLine -Node $Node
            $col     = Get-NodeColumn  -Node $Node
            $section = Get-SectionForLine -Sections $script:CurrentSections -Line $line

            $sourceVal = if ($Node.source -and $Node.source.value) { [string]$Node.source.value } else { '?' }
            foreach ($spec in $Node.specifiers) {
                $importedName = $null
                if ($spec.local -and $spec.local.name) { $importedName = $spec.local.name }
                if ($importedName) {
                    $shape = Get-ImportVariantShape -Specifier $spec -SourcePath $sourceVal
                    Add-JsDefinitionRow -ComponentType $shape.ComponentType -ComponentName $importedName `
                        -VariantType $shape.VariantType `
                        -VariantQualifier1 $shape.VariantQualifier1 `
                        -VariantQualifier2 $shape.VariantQualifier2 `
                        -LineStart $line -LineEnd $endLine -ColumnStart $col `
                        -Signature "import $importedName from '$sourceVal'" `
                        -ParentFunction $null `
                        -RawText "import $importedName from '$sourceVal'" `
                        -PurposeDescription $null -Section $section | Out-Null
                }
            }
        }

        'CallExpression' {
            $callee = $Node.callee
            if ($null -eq $callee) { return }

            # Per-case setup. Emits several row kinds (eval, document.write,
            # function USAGE, addEventListener, require, etc.) - all need
            # position info, $parentName, and a few sites need $section.
            $line       = Get-NodeLine    -Node $Node
            $endLine    = Get-NodeEndLine -Node $Node
            $col        = Get-NodeColumn  -Node $Node
            $section    = Get-SectionForLine -Sections $script:CurrentSections -Line $line
            $parentName = Get-CurrentParentName -ParentNodes $ParentNodes

            # Walk the callee chain ONCE for all the dotted-path checks below.
            # $calleeSegments is leaf-first (Get-CalleeSegments contract) or
            # $null for callees that can't be matched (computed access, etc.).
            # Test-SegmentsMatchEnd handles the $null case as "no match", so
            # the checks below remain syntactically identical to before.
            $calleeSegments = Get-CalleeSegments -Callee $callee

            # eval(...)
            if ($callee.type -eq 'Identifier' -and $callee.name -eq 'eval') {
                Add-JsEvalRow -LineStart $line -LineEnd $endLine -ColumnStart $col `
                    -Signature 'eval(...)' -ParentFunction $parentName -RawText 'eval(...)' | Out-Null
            }

            # document.write(...)
            if (Test-SegmentsMatchEnd -Segments $calleeSegments -Path @('document','write')) {
                Add-JsDocumentWriteRow -LineStart $line -LineEnd $endLine -ColumnStart $col `
                    -Signature 'document.write(...)' -ParentFunction $parentName -RawText 'document.write(...)' | Out-Null
            }

            # Direct function call: foo(...)
            if ($callee.type -eq 'Identifier') {
                $fnName = $callee.name
                Add-JsFunctionUsageRow -FunctionName $fnName `
                    -LineStart $line -ColumnStart $col `
                    -Signature "$fnName(...)" -ParentFunction $parentName -RawText "$fnName(...)" | Out-Null
            }

            # classList.add/remove/toggle('class')
            if ((Test-SegmentsMatchEnd -Segments $calleeSegments -Path @('classList','add'))    -or
                (Test-SegmentsMatchEnd -Segments $calleeSegments -Path @('classList','remove')) -or
                (Test-SegmentsMatchEnd -Segments $calleeSegments -Path @('classList','toggle'))) {
                foreach ($arg in $Node.arguments) {
                    if ($arg.type -eq 'Literal' -and $arg.value -is [string]) {
                        $cls = $arg.value.Trim()
                        if ($cls) {
                            $methodName = $callee.property.name
                            Add-ClassUsageRow -ClassName $cls `
                                -LineStart (Get-NodeLine -Node $arg) `
                                -ColumnStart (Get-NodeColumn -Node $arg) `
                                -Signature "classList.$methodName('$cls')" `
                                -ParentFunction $parentName `
                                -RawText "classList.$methodName('$cls')" | Out-Null
                        }
                    }
                }
            }

            # getElementById('foo')
            if (Test-SegmentsMatchEnd -Segments $calleeSegments -Path @('getElementById')) {
                $arg = $Node.arguments | Select-Object -First 1
                if ($arg -and $arg.type -eq 'Literal' -and $arg.value -is [string]) {
                    $idName = $arg.value
                    Add-HtmlIdRow -IdName $idName -ReferenceType 'USAGE' `
                        -LineStart (Get-NodeLine -Node $arg) `
                        -ColumnStart (Get-NodeColumn -Node $arg) `
                        -Signature "getElementById('$idName')" -ParentFunction $parentName `
                        -RawText "getElementById('$idName')" | Out-Null
                }
            }

            # querySelector / querySelectorAll
            if ((Test-SegmentsMatchEnd -Segments $calleeSegments -Path @('querySelector')) -or
                (Test-SegmentsMatchEnd -Segments $calleeSegments -Path @('querySelectorAll'))) {
                $arg = $Node.arguments | Select-Object -First 1
                if ($arg -and $arg.type -eq 'Literal' -and $arg.value -is [string]) {
                    $selector   = $arg.value
                    $methodName = $callee.property.name
                    $sig = "$methodName('$selector')"

                    $idMatches = [regex]::Matches($selector, '#([\w-]+)')
                    foreach ($im in $idMatches) {
                        Add-HtmlIdRow -IdName $im.Groups[1].Value -ReferenceType 'USAGE' `
                            -LineStart (Get-NodeLine -Node $arg) `
                            -ColumnStart (Get-NodeColumn -Node $arg) `
                            -Signature $sig -ParentFunction $parentName -RawText $sig | Out-Null
                    }
                    $classMatches = [regex]::Matches($selector, '\.([\w-]+)')
                    foreach ($cm in $classMatches) {
                        Add-ClassUsageRow -ClassName $cm.Groups[1].Value `
                            -LineStart (Get-NodeLine -Node $arg) `
                            -ColumnStart (Get-NodeColumn -Node $arg) `
                            -Signature $sig -ParentFunction $parentName -RawText $sig | Out-Null
                    }
                }
            }

            # addEventListener('event', ...)
            if (Test-SegmentsMatchEnd -Segments $calleeSegments -Path @('addEventListener')) {
                $arg = $Node.arguments | Select-Object -First 1
                if ($arg -and $arg.type -eq 'Literal' -and $arg.value -is [string]) {
                    $evName = $arg.value
                    $evRow = Add-JsEventRow -EventName $evName `
                        -LineStart (Get-NodeLine -Node $arg) `
                        -ColumnStart (Get-NodeColumn -Node $arg) `
                        -Signature "addEventListener('$evName', ...)" -ParentFunction $parentName `
                        -RawText "addEventListener('$evName', ...)"

                    # FORBIDDEN_PER_ELEMENT_LISTENER_LOOP.
                    # If this addEventListener call is inside a forEach callback
                    # (or sibling) or inside a for-of/for-in/for loop body, the
                    # listener is being attached one-per-element rather than
                    # via delegation. Attach the drift code to the same
                    # JS_EVENT USAGE row that just fired -- no separate row.
                    if ($evRow -and (Test-IsInsideElementLoop -ParentNodes $ParentNodes)) {
                        Add-DriftCode -Row $evRow -Code 'FORBIDDEN_PER_ELEMENT_LISTENER_LOOP' `
                            -Context "addEventListener('$evName', ...) at line $line is inside a per-element loop; delegation on a stable parent is required."
                    }
                }
            }

            # setAttribute('id'|'class', value)
            if (Test-SegmentsMatchEnd -Segments $calleeSegments -Path @('setAttribute')) {
                $arg1 = $Node.arguments | Select-Object -First 1
                $arg2 = $Node.arguments | Select-Object -First 1 -Skip 1
                if ($arg1 -and $arg1.type -eq 'Literal' -and $arg1.value -is [string] `
                    -and $arg2 -and $arg2.type -eq 'Literal' -and $arg2.value -is [string]) {
                    $attrName = ([string]$arg1.value).ToLower()
                    $attrVal  = [string]$arg2.value

                    if ($attrName -eq 'id' -and -not [string]::IsNullOrWhiteSpace($attrVal)) {
                        Add-HtmlIdRow -IdName $attrVal -ReferenceType 'DEFINITION' `
                            -LineStart (Get-NodeLine -Node $arg2) `
                            -ColumnStart (Get-NodeColumn -Node $arg2) `
                            -Signature "setAttribute('id', '$attrVal')" -ParentFunction $parentName `
                            -RawText "setAttribute('id', '$attrVal')" | Out-Null
                    }
                    elseif ($attrName -eq 'class' -and -not [string]::IsNullOrWhiteSpace($attrVal)) {
                        $classNames = Split-ClassNames -Value $attrVal
                        foreach ($cls in $classNames) {
                            Add-ClassUsageRow -ClassName $cls `
                                -LineStart (Get-NodeLine -Node $arg2) `
                                -ColumnStart (Get-NodeColumn -Node $arg2) `
                                -Signature "setAttribute('class', '$attrVal')" -ParentFunction $parentName `
                                -RawText "setAttribute('class', '$attrVal')" | Out-Null
                        }
                    }
                }
            }

            # require('module')
            if ($callee.type -eq 'Identifier' -and $callee.name -eq 'require') {
                $arg = $Node.arguments | Select-Object -First 1
                if ($arg -and $arg.type -eq 'Literal' -and $arg.value -is [string]) {
                    $modName = $arg.value
                    $shape = Get-RequireVariantShape -SourcePath $modName
                    Add-JsDefinitionRow -ComponentType $shape.ComponentType -ComponentName $modName `
                        -VariantType $shape.VariantType `
                        -VariantQualifier1 $shape.VariantQualifier1 `
                        -VariantQualifier2 $shape.VariantQualifier2 `
                        -LineStart $line -LineEnd $endLine -ColumnStart $col `
                        -Signature "require('$modName')" -ParentFunction $null `
                        -RawText "require('$modName')" -PurposeDescription $null -Section $section | Out-Null
                }
            }
        }

        'TemplateLiteral' {
            # Per-case setup. Emits inline-style / inline-script / inline-event
            # rows and HTML-bearing-text rows; all need position info and
            # $parentName. $section is not used by this case.
            $line       = Get-NodeLine    -Node $Node
            $endLine    = Get-NodeEndLine -Node $Node
            $col        = Get-NodeColumn  -Node $Node
            $parentName = Get-CurrentParentName -ParentNodes $ParentNodes

            $reconstructed = ''
            for ($i = 0; $i -lt $Node.quasis.Count; $i++) {
                $q = $Node.quasis[$i]
                $reconstructed += $q.value.cooked
                if ($i -lt $Node.expressions.Count) { $reconstructed += '${dyn}' }
            }
            $rawSnippet = Get-RangeText -Source $script:CurrentFileSource -Node $Node

            if (Test-LooksLikeInlineStyle -Text $reconstructed) {
                Add-JsInlineStyleRow -LineStart $line -LineEnd $endLine -ColumnStart $col `
                    -Signature 'template literal contains <style>' -ParentFunction $parentName `
                    -RawText $rawSnippet | Out-Null
            }
             if (Test-LooksLikeInlineScript -Text $reconstructed) {
                Add-JsInlineScriptRow -LineStart $line -LineEnd $endLine -ColumnStart $col `
                    -Signature 'template literal contains <script>' -ParentFunction $parentName `
                    -RawText $rawSnippet | Out-Null
            }
            if (Test-LooksLikeInlineEvent -Text $reconstructed) {
                Add-JsInlineEventRow -LineStart $line -LineEnd $endLine -ColumnStart $col `
                    -Signature 'template literal contains inline on<event>=' -ParentFunction $parentName `
                    -RawText $rawSnippet | Out-Null
            }

            if (-not (Test-LooksLikeHtml -Text $reconstructed)) { return }
            Add-RowsFromHtmlBearingText -Text $reconstructed -StartLine $line -StartCol $col `
                -ParentFunction $parentName -RawText $rawSnippet
        }

        'Literal' {
            if ($null -eq $Node.value) { return }
            if (-not ($Node.value -is [string])) { return }

            $strVal = [string]$Node.value

            # Short strings (under 4 chars) cannot possibly contain HTML,
            # an inline <style>/<script> block, or a class/id attribute.
            # The vast majority of literals are short string keys, error
            # message fragments, etc. - this gate skips the regex work
            # AND the per-case setup for them.
            if ($strVal.Length -lt 4) { return }

            # Hoisted gate: Test-LooksLikeHtml is the broadest predicate.
            # If it doesn't fire, neither Test-LooksLikeInlineStyle nor
            # Test-LooksLikeInlineScript can fire either (a string with
            # '<style>' or '<script>' necessarily matches '<\s*\w'). So a
            # single regex check here lets us bail out of ~99% of literal
            # visits with no other work.
            if (-not (Test-LooksLikeHtml -Text $strVal)) { return }

            # Per-case setup. Same emission shape as TemplateLiteral; no
            # $section needed. Setup runs only for HTML-bearing literals.
            $line       = Get-NodeLine    -Node $Node
            $endLine    = Get-NodeEndLine -Node $Node
            $col        = Get-NodeColumn  -Node $Node
            $parentName = Get-CurrentParentName -ParentNodes $ParentNodes

            $rawSnippet = Get-RangeText -Source $script:CurrentFileSource -Node $Node

            if (Test-LooksLikeInlineStyle -Text $strVal) {
                Add-JsInlineStyleRow -LineStart $line -LineEnd $endLine -ColumnStart $col `
                    -Signature 'string literal contains <style>' -ParentFunction $parentName `
                    -RawText $rawSnippet | Out-Null
            }
            if (Test-LooksLikeInlineScript -Text $strVal) {
                Add-JsInlineScriptRow -LineStart $line -LineEnd $endLine -ColumnStart $col `
                    -Signature 'string literal contains <script>' -ParentFunction $parentName `
                    -RawText $rawSnippet | Out-Null
            }

            Add-RowsFromHtmlBearingText -Text $strVal -StartLine $line -StartCol $col `
                -ParentFunction $parentName -RawText $rawSnippet
        }

        'AssignmentExpression' {
            $left  = $Node.left
            $right = $Node.right
            if ($null -eq $left -or $null -eq $right) { return }

            # Per-case setup. Emits window-assignment, timer, and direct-on<event>
            # rows; all need position info and $parentName. $section is not used.
            $line       = Get-NodeLine    -Node $Node
            $endLine    = Get-NodeEndLine -Node $Node
            $col        = Get-NodeColumn  -Node $Node
            $parentName = Get-CurrentParentName -ParentNodes $ParentNodes

            # Pattern 1: window.X = ... (forbidden outside the shell file)
            if ($left.type -eq 'MemberExpression' -and
                -not $left.computed -and
                $left.object -and $left.object.type -eq 'Identifier' -and
                $left.object.name -eq 'window' -and
                $left.property -and $left.property.type -eq 'Identifier') {
                if (-not $script:CurrentFileIsShell) {
                    $assignedName = $left.property.name
                    Add-JsWindowAssignmentRow -AssignedName $assignedName `
                        -LineStart $line -LineEnd $endLine -ColumnStart $col `
                        -Signature "window.$assignedName = ..." -ParentFunction $parentName `
                        -RawText "window.$assignedName = ..." | Out-Null
                }
            }

            # Pattern 2: TimerHandle = setInterval(...) | setTimeout(...)
            if ($left.type -eq 'Identifier' -and
                $right.type -eq 'CallExpression' -and
                $right.callee -and $right.callee.type -eq 'Identifier' -and
                ($right.callee.name -eq 'setInterval' -or $right.callee.name -eq 'setTimeout') -and
                $script:CurrentTimerHandles -and
                $script:CurrentTimerHandles.Contains($left.name)) {

                # JS_TIMER is a definition row -- suppress under a forbidden
                # wrapper. Timers inside a wrapped page get rewritten when the
                # file is rewritten to spec; cataloging them here would imply
                # they have independent named identity in the spec'd version,
                # which they don't.
                if (-not $script:CurrentSuppressDefinitions) {
                    $handleName = $left.name
                    $callKind   = $right.callee.name
                    $sig        = "$handleName = $callKind(...)"
                    $shape      = Get-TimerVariantShape -CalleeName $callKind

                    $secForTimer = Get-SectionForLine -Sections $script:CurrentSections -Line $line
                    $timerSourceSection = if ($secForTimer) { $secForTimer.FullTitle } else { $null }
                    $key = "$($script:CurrentFile)|$line|$col|JS_TIMER|$handleName|DEFINITION|"
                    if (Test-AddDedupeKey -Key $key) {
                        $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }
                        $row = New-JsRow -ComponentType $shape.ComponentType -ComponentName $handleName `
                            -VariantType $shape.VariantType `
                            -VariantQualifier1 $shape.VariantQualifier1 `
                            -VariantQualifier2 $shape.VariantQualifier2 `
                            -ReferenceType 'DEFINITION' -Scope $scope -SourceFile $script:CurrentFile `
                            -SourceSection $timerSourceSection `
                            -LineStart $line -LineEnd $endLine -ColumnStart $col `
                            -Signature $sig -ParentFunction $parentName -RawText $sig `
                            -SuppressSectionLookup
                        $script:rows.Add($row)
                    }
                }
            }

            # Pattern 3: el.className = '...' / el.id = '...' / el.onevent = ...
            if ($left.type -ne 'MemberExpression') { return }
            if ($left.computed) { return }
            if (-not $left.property -or $left.property.type -ne 'Identifier') { return }

            $propName = $left.property.name

            if ($propName -eq 'className' -and $right.type -eq 'Literal' -and $right.value -is [string]) {
                $classNames = Split-ClassNames -Value $right.value
                foreach ($cls in $classNames) {
                    Add-ClassUsageRow -ClassName $cls `
                        -LineStart (Get-NodeLine -Node $right) `
                        -ColumnStart (Get-NodeColumn -Node $right) `
                        -Signature "className = '$($right.value)'" -ParentFunction $parentName `
                        -RawText "className = '$($right.value)'" | Out-Null
                }
            }

            if ($propName -eq 'id' -and $right.type -eq 'Literal' -and $right.value -is [string]) {
                $idVal = [string]$right.value
                if (-not [string]::IsNullOrWhiteSpace($idVal)) {
                    Add-HtmlIdRow -IdName $idVal -ReferenceType 'DEFINITION' `
                        -LineStart (Get-NodeLine -Node $right) `
                        -ColumnStart (Get-NodeColumn -Node $right) `
                        -Signature "id = '$idVal'" -ParentFunction $parentName `
                        -RawText "id = '$idVal'" | Out-Null
                }
            }

            if ($propName -match '^on([a-z]+)$') {
                $evName = $matches[1]
                Add-JsEventRow -EventName $evName `
                    -LineStart $line -ColumnStart $col `
                    -Signature "$propName = ..." -ParentFunction $parentName `
                    -RawText "$propName = ..." -IsForbidden $true | Out-Null
            }
        }

        'ExpressionStatement' {
            $isTopLevel = Test-IsTopLevel -ParentChain $ParentChain
            if (-not $isTopLevel) { return }

            # Per-case setup. Only $line / $endLine / $col are needed -
            # $section / $parentName are not used by this case.
            $line    = Get-NodeLine    -Node $Node
            $endLine = Get-NodeEndLine -Node $Node
            $col     = Get-NodeColumn  -Node $Node

            # Top-level IIFE detection. The IIFE emits a JS_IIFE row carrying
            # its full body in raw_text plus FORBIDDEN_IIFE drift. Definition
            # suppression then turns on so inner function / const / class
            # declarations are NOT cataloged (they have no reachability under
            # the wrapper). USAGE rows continue to fire so the cross-reference
            # catalog stays complete.
            if ($Node.expression -and $Node.expression.type -eq 'CallExpression') {
                $iifeCallee = $Node.expression.callee
                if ($iifeCallee -and ($iifeCallee.type -eq 'FunctionExpression' -or $iifeCallee.type -eq 'ArrowFunctionExpression')) {
                    $sig = if ($iifeCallee.type -eq 'ArrowFunctionExpression') { '(() => { ... })()' } else { '(function() { ... })()' }
                    $rawSnippet = Get-RangeText -Source $script:CurrentFileSource -Node $Node
                    Add-JsIifeRow -LineStart $line -LineEnd $endLine -ColumnStart $col `
                        -Signature $sig -RawText $rawSnippet | Out-Null
                    $script:CurrentSuppressDefinitions = $true
                    return
                }
            }

            # A /* ... */ purpose comment immediately preceding a top-level
            # expression statement that defines named behavior (e.g.,
            # document.addEventListener('DOMContentLoaded', ...)) is an
            # allowed purpose comment. Consume it via Get-PrecedingBlockComment
            # so the FORBIDDEN_COMMENT_STYLE check below treats it as claimed.
            # No row is emitted - the expression statement itself has no
            # natural definition host. The side effect is the comment getting
            # marked Used=true so the stray-comment check skips it.
            [void](Get-PrecedingBlockComment -CommentIndex $script:CurrentCommentIndex -DefinitionLine $line)
        }
    }
}

<# ============================================================================
   EXECUTION: SCRIPT EXECUTION
   ----------------------------------------------------------------------------
   The procedural body: discover files, parse and collect shared definitions
   (Pass 1), preload ProcessRegistry, load the Object_Registry and
   Component_Registry maps, walk each file emitting rows (Pass 2), run the
   cross-file compliance checks (Pass 3), validate drift codes, compute the
   occurrence index, summarize, and write to dbo.Asset_Registry.
   Prefix: (none)
   ============================================================================ #>

# -- Parser Environment --

# Make the Node library path available to the Acorn parser subprocess.
$env:NODE_PATH = $NodeLibsPath

# -- File Discovery --

# Enumerate the .js files to catalog from the scan roots, applying the optional
# file filter and excluding vendored third-party libraries from parsing.
Write-Log "Discovering JS files..."

$JsFiles       = New-Object System.Collections.Generic.List[string]
$VendoredFiles = New-Object System.Collections.Generic.List[string]
foreach ($root in $JsScanRoots) {
    if (-not (Test-Path $root)) {
        Write-Log "Scan root not found, skipping: $root" 'WARN'
        continue
    }
    $allJs = @(Get-ChildItem -Path $root -Filter '*.js' -Recurse -File |
                 Select-Object -ExpandProperty FullName)
    foreach ($f in $allJs) {
        $fName = [System.IO.Path]::GetFileName($f)
        # Vendored libraries: anchor-only, never walked. Checked first so a
        # vendored *.min.js (e.g. xlsx.full.min.js) is captured for anchoring
        # rather than silently dropped by the *.min.js walk-set exclusion.
        if ($VendoredJsFiles -contains $fName) {
            [void]$VendoredFiles.Add($f)
            continue
        }
        # Walk set: authored CC JS only. Minified files that are NOT on the
        # vendored allow-list are excluded entirely (no walk, no anchor).
        if ($fName -notlike '*.min.js') {
            [void]$JsFiles.Add($f)
        }
    }
}

if (-not [string]::IsNullOrEmpty($FileFilter)) {
    $filtered = New-Object System.Collections.Generic.List[string]
    foreach ($f in $JsFiles) {
        $name = [System.IO.Path]::GetFileName($f)
        if ($name -eq $FileFilter -or $name -like $FileFilter) {
            [void]$filtered.Add($f)
        }
    }
    $JsFiles = $filtered
    Write-Log ("FileFilter applied: '{0}' -> {1} file(s)" -f $FileFilter, $JsFiles.Count)
} else {
    Write-Log ("Discovered {0} .js files to scan" -f $JsFiles.Count)
}

# -- Pass 1 - Parse All Files, Collect Shared-Scope Definitions --

Write-Log "Loading Object_Registry zone/scope map..."
$objectZoneScopeMap = Get-ObjectRegistryZoneScopeMap `
    -ServerInstance $script:XFActsServerInstance `
    -Database       $script:XFActsDatabase `
    -FileType       'JS'
Write-Log ("  Object_Registry rows loaded: {0}" -f $objectZoneScopeMap.Count)

# Files found on disk but absent from the zone/scope map.
$objectRegistryMisses = New-Object 'System.Collections.Generic.HashSet[string]'

Write-Log "Pass 1: parse all files, collect SHARED-scope JS definitions (zone-aware)..."

$astCache = @{}

# Zone-scoped shared-name maps, keyed by zone string. A consumer resolves
# USAGE references only against its own zone's maps, so cross-zone names never
# contaminate each other's resolution.
$script:sharedFunctionsByZone  = @{}
$script:sharedConstantsByZone  = @{}
$script:sharedClassesByZone    = @{}
$script:sharedSourceFileByZone = @{}

foreach ($file in $JsFiles) {
    $name = [System.IO.Path]::GetFileName($file)

    Write-Host "  Parsing $name ..." -NoNewline
    $parsed = Invoke-JsParse -FilePath $file
    if ($null -eq $parsed) {
        Write-Host " FAILED" -ForegroundColor Red
        continue
    }
    Write-Host " ok" -ForegroundColor Green
    $astCache[$file] = $parsed

    # Zone and scope come from Object_Registry. A file absent from the map
    # contributes no shared definitions and is flagged in Pass 2.
    if (-not $objectZoneScopeMap.ContainsKey($name)) { continue }
    $zone  = $objectZoneScopeMap[$name].Zone
    $scope = $objectZoneScopeMap[$name].Scope
    if ($scope -ne 'SHARED') { continue }

    if (-not $script:sharedFunctionsByZone.ContainsKey($zone)) {
        $script:sharedFunctionsByZone[$zone]  = New-Object 'System.Collections.Generic.HashSet[string]'
        $script:sharedConstantsByZone[$zone]  = New-Object 'System.Collections.Generic.HashSet[string]'
        $script:sharedClassesByZone[$zone]    = New-Object 'System.Collections.Generic.HashSet[string]'
        $script:sharedSourceFileByZone[$zone] = @{}
    }
    $sharedFunctions  = $script:sharedFunctionsByZone[$zone]
    $sharedConstants  = $script:sharedConstantsByZone[$zone]
    $sharedClasses    = $script:sharedClassesByZone[$zone]
    $sharedSourceFile = $script:sharedSourceFileByZone[$zone]

    $programBody = $parsed.Ast.body
    if ($null -eq $programBody) { continue }

    foreach ($stmt in $programBody) {
        if ($null -eq $stmt) { continue }

        switch ($stmt.type) {
            'FunctionDeclaration' {
                if ($stmt.id -and $stmt.id.name) {
                    [void]$sharedFunctions.Add($stmt.id.name)
                    if (-not $sharedSourceFile.ContainsKey($stmt.id.name)) {
                        $sharedSourceFile[$stmt.id.name] = $name
                    }
                }
            }
            'VariableDeclaration' {
                foreach ($decl in $stmt.declarations) {
                    if (-not $decl.id -or $decl.id.type -ne 'Identifier') { continue }
                    $declName = $decl.id.name
                    $init = $decl.init
                    if ($init -and ($init.type -eq 'FunctionExpression' -or $init.type -eq 'ArrowFunctionExpression')) {
                        [void]$sharedFunctions.Add($declName)
                    }
                    elseif ($init -and $init.type -eq 'ClassExpression') {
                        [void]$sharedClasses.Add($declName)
                    }
                    else {
                        [void]$sharedConstants.Add($declName)
                    }
                    if (-not $sharedSourceFile.ContainsKey($declName)) {
                        $sharedSourceFile[$declName] = $name
                    }
                }
            }
            'ClassDeclaration' {
                if ($stmt.id -and $stmt.id.name) {
                    [void]$sharedClasses.Add($stmt.id.name)
                    if (-not $sharedSourceFile.ContainsKey($stmt.id.name)) {
                        $sharedSourceFile[$stmt.id.name] = $name
                    }
                }
            }
            'IfStatement' {
                # Legacy `if (typeof X !== 'function') { window.X = function()... }`
                # pattern in engine-events.js. Capture the assigned name as a
                # shared function so consumer pages do not trigger
                # SHADOWS_SHARED_FUNCTION on what is, by intent, a shared
                # definition. FORBIDDEN_CONDITIONAL_DEFINITION and
                # FORBIDDEN_WINDOW_ASSIGNMENT still fire on the row.
                $cons = $stmt.consequent
                if ($cons -and $cons.type -eq 'BlockStatement' -and $cons.body) {
                    foreach ($inner in $cons.body) {
                        if ($inner.type -eq 'ExpressionStatement' -and
                            $inner.expression -and
                            $inner.expression.type -eq 'AssignmentExpression' -and
                            $inner.expression.left -and
                            $inner.expression.left.type -eq 'MemberExpression' -and
                            $inner.expression.left.object -and
                            $inner.expression.left.object.type -eq 'Identifier' -and
                            $inner.expression.left.object.name -eq 'window' -and
                            $inner.expression.left.property -and
                            $inner.expression.left.property.type -eq 'Identifier' -and
                            $inner.expression.right -and
                            ($inner.expression.right.type -eq 'FunctionExpression' -or
                             $inner.expression.right.type -eq 'ArrowFunctionExpression')) {
                            $fnName = $inner.expression.left.property.name
                            [void]$sharedFunctions.Add($fnName)
                            if (-not $sharedSourceFile.ContainsKey($fnName)) {
                                $sharedSourceFile[$fnName] = $name
                            }
                        }
                    }
                }
            }
        }
    }
}

foreach ($zone in ($script:sharedFunctionsByZone.Keys | Sort-Object)) {
    Write-Log ("  Zone '{0}' - shared functions: {1}, constants: {2}, classes: {3}" -f `
        $zone,
        $script:sharedFunctionsByZone[$zone].Count,
        $script:sharedConstantsByZone[$zone].Count,
        $script:sharedClassesByZone[$zone].Count)
}

# -- Process Registry Preload --

# ENGINE_PROCESSES validation cross-checks each page file's ENGINE_PROCESSES
# const against the active engine-card processes in Orchestrator.ProcessRegistry
# (run_mode=1; queue processors and inactive processes are excluded). Results
# are grouped by cc_page_route for per-file lookup.
Write-Log "Loading Orchestrator.ProcessRegistry rows for ENGINE_PROCESSES validation..."

$processRegistryRowsRaw = Get-SqlData -Query @"
SELECT process_name, cc_engine_slug, cc_page_route, run_mode
FROM Orchestrator.ProcessRegistry
WHERE run_mode = 1
  AND cc_engine_slug IS NOT NULL
  AND cc_page_route  IS NOT NULL;
"@

# Map: cc_page_route -> List of @{ ProcessName; Slug; PageRoute; RunMode }
$script:processRegistryByPageRoute = @{}
$processRegPreLoadState = 'QUERY_FAILED'
$processRegRowCount     = 0

if ($null -ne $processRegistryRowsRaw) {
    $rowArray = @($processRegistryRowsRaw)
    $processRegRowCount = $rowArray.Count
    if ($rowArray.Count -eq 0) {
        $processRegPreLoadState = 'EMPTY'
    } else {
        $processRegPreLoadState = 'OK'
        foreach ($r in $rowArray) {
            $rec = @{
                ProcessName = [string]$r.process_name
                Slug        = [string]$r.cc_engine_slug
                PageRoute   = [string]$r.cc_page_route
                RunMode     = [int]$r.run_mode
            }
            if (-not $script:processRegistryByPageRoute.ContainsKey($rec.PageRoute)) {
                $script:processRegistryByPageRoute[$rec.PageRoute] = New-Object System.Collections.Generic.List[object]
            }
            $script:processRegistryByPageRoute[$rec.PageRoute].Add($rec)
        }
    }
}

switch ($processRegPreLoadState) {
    'OK' {
        Write-Log ("  ProcessRegistry rows loaded: {0} across {1} page route(s)" -f $processRegRowCount, $script:processRegistryByPageRoute.Count)
    }
    'EMPTY' {
        Write-Log "ProcessRegistry query returned zero active engine-card rows. ENGINE_PROCESSES validation will be skipped." 'WARN'
    }
    'QUERY_FAILED' {
        Write-Log "Could not load ProcessRegistry rows. ENGINE_PROCESSES validation will be skipped." 'WARN'
    }
}

# -- Registry Loads --

Write-Log "Loading Component_Registry prefix map for registry validation..."
$componentPrefixMap = Get-ComponentRegistryPrefixMap `
    -ServerInstance $script:XFActsServerInstance `
    -Database       $script:XFActsDatabase `
    -FileType       'JS'
Write-Log ("  Component_Registry prefix rows loaded: {0}" -f $componentPrefixMap.Count)

# -- Pass 2 - Per-File Walk --

Write-Log "Pass 2: generating Asset_Registry rows..."

foreach ($file in $JsFiles) {
    $name = [System.IO.Path]::GetFileName($file)

    if (-not $astCache.ContainsKey($file)) {
        Write-Log "  Skipping (no parsed AST): $name" 'WARN'
        continue
    }

    $parsed = $astCache[$file]

    # Set per-file context
    # Zone, scope, and shell designation come from Object_Registry. A file
    # absent from the map is stamped '<undefined>' and recorded so Pass 3 can
    # attach FILE_NOT_REGISTERED to its JS_FILE row.
    $script:CurrentFile = $name
    if ($objectZoneScopeMap.ContainsKey($name)) {
        $script:CurrentFileZone    = $objectZoneScopeMap[$name].Zone
        $script:CurrentFileScope   = $objectZoneScopeMap[$name].Scope
        $script:CurrentFileIsShell = ($objectZoneScopeMap[$name].ScopeTier -eq 'SHELL')
    } else {
        $script:CurrentFileZone    = '<undefined>'
        $script:CurrentFileScope   = '<undefined>'
        $script:CurrentFileIsShell = $false
        [void]$objectRegistryMisses.Add($name)
    }
    $script:CurrentFileIsShared = ($script:CurrentFileScope -eq 'SHARED')
    $script:CurrentFileSource   = $parsed.Source

    # Reset definition-suppression flag (it may have been set during the
    # previous file's walk if that file had a forbidden wrapper).
    $script:CurrentSuppressDefinitions = $false

    # Reset per-file ENGINE_PROCESSES capture state, populated by the visitor
    # and read by the post-walk validation pass.
    $script:CurrentEngineProcessesRow     = $null
    $script:CurrentEngineProcessesEntries = New-Object System.Collections.Generic.List[object]

    # Valid section types by file kind: the shell file uses the shared
    # taxonomy (FOUNDATION / BOOTLOADER / CHROME); page files use the
    # page-file taxonomy.
    $script:CurrentValidSectionTypes = if ($script:CurrentFileIsShell) {
        $ValidSectionTypes_Shared
    } else {
        $ValidSectionTypes_Page
    }

    $localDefs = Get-LocalDefinitions -ProgramBody $parsed.Ast.body
    $script:CurrentLocalFuncs   = $localDefs.Functions
    $script:CurrentLocalConsts  = $localDefs.Constants
    $script:CurrentLocalState   = $localDefs.State
    $script:CurrentLocalClasses = $localDefs.Classes
    $script:CurrentTimerHandles = Get-TimerHandleCandidates -ProgramBody $parsed.Ast.body

    $script:CurrentRegistryHasMapping = $componentPrefixMap.ContainsKey($name)
    $script:CurrentRegistryPrefix     = if ($script:CurrentRegistryHasMapping) { $componentPrefixMap[$name] } else { $null }

    # Build normalized comments, comment index, section list
    # The @() casts force consistent array shape so downstream Mandatory
    # parameter bindings see a real (possibly empty) array, never $null.
    $normalizedComments = @(Convert-AcornCommentsToNormalized -Comments $parsed.Comments)
    $script:CurrentCommentIndex = New-CommentIndex -NormalizedComments $normalizedComments

    $fileLineCount = ($parsed.Source -split "`n").Count
    $script:CurrentSections = New-SectionList `
        -Comments         $normalizedComments `
        -FileLineCount    $fileLineCount `
        -ValidSectionTypes $script:CurrentValidSectionTypes

    # Emit JS_FILE anchor row
    # The JS_FILE row precedes FILE_HEADER and serves as the universal
    # file-level anchor. It is purely structural - no content, no drift
    # by default. The orphan-code detection passes (EXCESS_BLANK_LINES,
    # FORBIDDEN_COMMENT_STYLE) attach to this row.
    $jsFileRow = Add-JsFileRow -LineEnd $fileLineCount

    # Emit FILE_HEADER row
    # The FILE_HEADER row is emitted only when a real /* ... */ block at
    # line 1 is found. If no valid header is present, drift attaches to
    # the JS_FILE anchor row instead (same pattern as the PS populator's
    # PS_FILE fallback for MALFORMED_FILE_HEADER).
    $headerInfo = Get-FileHeaderInfo -Comments $normalizedComments

    if ($headerInfo.IsValid) {
        $headerRawText = $null
        foreach ($c in $normalizedComments) {
            if ($c.Type -eq 'Block') {
                $crlf = "`r`n"; $lf = "`n"; $cr = "`r"
                $headerRawText = ($c.Text -replace $crlf, ' ' -replace $lf, ' ' -replace $cr, ' ').Trim()
                break
            }
        }
        $headerRow = Add-FileHeaderRow `
            -LineStart          $headerInfo.StartLine `
            -LineEnd            $headerInfo.EndLine `
            -RawText            $headerRawText `
            -PurposeDescription $headerInfo.Description
        foreach ($code in $headerInfo.DriftCodes) {
            Add-DriftCode -Row $headerRow -Code $code
        }

        # FILE_ORG_MISMATCH on the FILE_HEADER row when the FILE ORGANIZATION
        # list doesn't match the actual section banners verbatim/in-order.
        $matchOK = Test-FileOrgMatchesBanners -FileOrgList $headerInfo.FileOrgList -Sections $script:CurrentSections
        if (-not $matchOK) {
            Add-DriftCode -Row $headerRow -Code 'FILE_ORG_MISMATCH'
        }
    }
    else {
        # No valid /* ... */ block at line 1. No FILE_HEADER row is emitted;
        # the drift attaches to the JS_FILE anchor row instead. Mirrors the
        # PS populator's PS_FILE fallback. Codes returned by
        # Get-FileHeaderInfo for this case are MALFORMED_FILE_HEADER (and
        # potentially FORBIDDEN_CHANGELOG_BLOCK if the block existed but
        # didn't start at line 1).
        if ($null -ne $jsFileRow) {
            foreach ($code in $headerInfo.DriftCodes) {
                Add-DriftCode -Row $jsFileRow -Code $code `
                    -Context "No /* ... */ block found at line 1 of the file."
            }
        }
    }

    # Normalize sections to a real array. New-SectionList returns a
    # List[object] but PowerShell pipeline-unwrapping can collapse a
    # single-element list to a scalar or an empty list to $null when the
    # function's return crosses the call boundary. The @() cast forces a
    # consistent array shape regardless.
    $sectionList = @($script:CurrentSections)

    # Emit COMMENT_BANNER rows from the section list
    # Find the index of the hooks banner (if any) for HOOKS_BANNER_NOT_LAST,
    # and the index of the first FUNCTIONS banner for INIT_MISPLACED.
    $hooksBannerIdx = -1
    $firstFunctionsBannerIdx = -1
    for ($i = 0; $i -lt $sectionList.Count; $i++) {
        $s = $sectionList[$i]
        if ($null -eq $s) { continue }
        if ($s.TypeName -eq 'FUNCTIONS') {
            if ($firstFunctionsBannerIdx -lt 0) {
                $firstFunctionsBannerIdx = $i
            }
            if ($s.BannerName -eq $script:HooksBannerName -and $hooksBannerIdx -lt 0) {
                $hooksBannerIdx = $i
            }
        }
    }

    $previousSectionTypeOrderIdx = -1
    for ($i = 0; $i -lt $sectionList.Count; $i++) {
        $s = $sectionList[$i]
        if ($null -eq $s) { continue }
        $isLastBanner           = ($i -eq ($sectionList.Count - 1))
        $hooksSeenAlready       = ($hooksBannerIdx -ge 0 -and $i -gt $hooksBannerIdx)
        $isFirstFunctionsBanner = ($i -eq $firstFunctionsBannerIdx)

        [void](Add-CommentBannerRow -Section $s `
            -PreviousSectionTypeOrderIdx $previousSectionTypeOrderIdx `
            -IsLastBanner $isLastBanner `
            -HooksBannerSeen $hooksSeenAlready `
            -IsFirstFunctionsBanner $isFirstFunctionsBanner)

        if ($s.TypeName -and $script:SectionTypeOrder.ContainsKey($s.TypeName)) {
            $idx = [int]$script:SectionTypeOrder[$s.TypeName]
            if ($idx -gt $previousSectionTypeOrderIdx) {
                $previousSectionTypeOrderIdx = $idx
            }
        }
    }

    # Walk the AST via the generic visitor
    $startCount = $script:rows.Count
    $scopeLabel = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }
    Write-Host ("  Walking {0} ({1}, zone={2})..." -f $name, $scopeLabel, $script:CurrentFileZone) -ForegroundColor Cyan

    try {
        Invoke-AstWalk -Node $parsed.Ast -Visitor 'Invoke-JsVisitor'
    } catch {
        # Walk failure = populator tooling defect, not source spec drift.
        # Discard partial rows from this file's walk (everything past
        # $startCount); FILE_HEADER and COMMENT_BANNER rows emitted before
        # the walk are kept.
        $partialAdded = $script:rows.Count - $startCount
        if ($partialAdded -gt 0) {
            for ($i = 0; $i -lt $partialAdded; $i++) {
                $script:rows.RemoveAt($script:rows.Count - 1)
            }
        }
        $errLine = if ($_.InvocationInfo) { $_.InvocationInfo.ScriptLineNumber } else { 0 }
        $errLineText = if ($_.InvocationInfo) { $_.InvocationInfo.Line.Trim() } else { '' }
        Write-Log ("AST walk failed on {0}: {1} (populator line {2}: {3})" -f $name, $_.Exception.Message, $errLine, $errLineText) 'WARN'
        if ($_.ScriptStackTrace) {
            Write-Log ("  ScriptStackTrace:") 'WARN'
            foreach ($frameLine in ($_.ScriptStackTrace -split "`r?`n")) {
                if (-not [string]::IsNullOrWhiteSpace($frameLine)) {
                    Write-Log ("    " + $frameLine.Trim()) 'WARN'
                }
            }
        }
        Write-Host ("    -> walk failed; FILE_HEADER + section banner rows kept, content rows discarded ({0} discarded)" -f $partialAdded) -ForegroundColor Yellow
        continue
    }

    # Function-body range collection (used by both stray-comment and line-comment checks)
    # Walk the AST once to collect every function/method body's line range.
    # The result is used by:
    # - FORBIDDEN_COMMENT_STYLE detection below to recognize inline body
    # comments () as a valid kind
    # - FORBIDDEN_FILE_SCOPE_LINE_COMMENT detection further down to test
    # whether each // line comment falls inside any function body
    # Computed once here so both checks share the same ranges.
    $functionRanges = New-Object System.Collections.Generic.List[object]
    $rangeVisitor = {
        param($n, $pc, $pn)
        if ($null -eq $n -or $null -eq $n.type) { return }
        if ($n.type -eq 'FunctionDeclaration' -or
            $n.type -eq 'FunctionExpression' -or
            $n.type -eq 'ArrowFunctionExpression') {
            if ($n.body) {
                $bs = if ($n.body.loc -and $n.body.loc.start) { [int]$n.body.loc.start.line } else { 0 }
                $be = if ($n.body.loc -and $n.body.loc.end)   { [int]$n.body.loc.end.line   } else { $bs }
                if ($bs -gt 0) { $functionRanges.Add(@{ Start = $bs; End = $be }) }
            }
        }
    }
    Invoke-AstWalk -Node $parsed.Ast -Visitor $rangeVisitor

    # FORBIDDEN_COMMENT_STYLE: stray block comments
    # five kinds of block comments are permitted:
    # file header, section banner, purpose comment preceding a definition
    # or top-level expression statement, sub-section marker, and inline
    # body comment (a /*... */ block inside a function body). Any block
    # comment that doesn't match one of these kinds is stray.
    # Detection: walk the normalized comment list. A block comment is
    # claimed if any of these hold:
    # - It's at line 1 (the file header)
    # - It passes Test-IsBannerComment (a section banner)
    # - Its line appears in $script:CurrentCommentIndex with Used=true
    # (it was consumed as a definition's preceding purpose comment by
    # Get-PrecedingBlockComment during the AST walk)
    # - Its trimmed text matches the sub-section marker pattern
    # - Its line falls inside any function body (inline body comment)
    # Line comments are handled separately (see below) and don't enter
    # this check.
    $strayLines = New-Object System.Collections.Generic.List[int]
    foreach ($c in $normalizedComments) {
        if ($c.Type -ne 'Block') { continue }

        # File header at line 1
        if ([int]$c.LineStart -eq 1) { continue }

        # Section banner
        if (Test-IsBannerComment -CommentText $c.Text -ValidSectionTypes $script:CurrentValidSectionTypes) {
            continue
        }

        # Consumed by a definition as its purpose comment
        $consumed = $false
        foreach ($ci in $script:CurrentCommentIndex) {
            if ([int]$ci.StartLine -eq [int]$c.LineStart -and $ci.Used) {
                $consumed = $true
                break
            }
        }
        if ($consumed) { continue }

        # Sub-section marker: /* -- label -- */
        $trimmedText = if ($c.Text) { $c.Text.Trim() } else { '' }
        if ($trimmedText -match '^--.+--$') { continue }

        # Inline body comment: any /*... */ block whose start line falls
        # inside any function body's line range..
        if (Test-LineInsideFunction -Line ([int]$c.LineStart) -Ranges $functionRanges) {
            continue
        }

        # If we got here, it's a stray block comment.
        $strayLines.Add([int]$c.LineStart)
    }
    if ($strayLines.Count -gt 0 -and $jsFileRow) {
        $linesText = ($strayLines | Sort-Object) -join ', '
        Add-DriftCode -Row $jsFileRow -Code 'FORBIDDEN_COMMENT_STYLE' `
            -Context "Stray block comments not matching any of the five allowed kinds (file header, banner, purpose comment, sub-section marker, inline body comment) at line(s): $linesText."
    }

    # File-scope // line comments -> JS_LINE_COMMENT rows
    # acorn returns Line comments alongside Block comments. A line comment
    # outside any function body is a forbidden pattern under.
    # The $functionRanges list was computed earlier in this iteration.

    if ($parsed.Comments) {
        foreach ($c in $parsed.Comments) {
            if ($c.type -ne 'Line') { continue }
            $cLine = if ($c.loc -and $c.loc.start) { [int]$c.loc.start.line } else { 0 }
            $cCol  = if ($c.loc -and $c.loc.start -and ($c.loc.start.PSObject.Properties.Name -contains 'column')) { ([int]$c.loc.start.column) + 1 } else { 1 }
            if ($cLine -le 0) { continue }
            if (-not (Test-LineInsideFunction -Line $cLine -Ranges $functionRanges)) {
                $cRaw = if ($c.value) { "// $($c.value)" } else { '//' }
                Add-JsLineCommentRow -LineStart $cLine -ColumnStart $cCol -RawText $cRaw | Out-Null
            }
        }
    }

    # MISSING_PAGE_INIT
    # Every page file with a registered cc_prefix must declare a top-level
    # <prefix>_init function. The init function can be either a function
    # declaration or a const initialized to an arrow/function expression
    # (both forms enter $CurrentLocalFuncs in Pass 1 / per-file Pass 2).
    # cc-shared.js, engine-events.js, and docs-zone files are exempt.
    if ($script:CurrentRegistryHasMapping -and
        -not [string]::IsNullOrEmpty($script:CurrentRegistryPrefix) -and
        -not $script:CurrentFileIsShared -and
        $jsFileRow) {
        $expectedInitName = "$($script:CurrentRegistryPrefix)_init"
        $hasInit = $script:CurrentLocalFuncs -and $script:CurrentLocalFuncs.Contains($expectedInitName)
        if (-not $hasInit) {
            Add-DriftCode -Row $jsFileRow -Code 'MISSING_PAGE_INIT' `
                -Context "Page file does not declare a top-level '$expectedInitName' function."
        }
    }

    # ENGINE_PROCESSES validation
    # Cross-check the file's ENGINE_PROCESSES declaration against active
    # engine-card processes in Orchestrator.ProcessRegistry, joining on
    # process_name. Per-page entries are looked up by page route; the
    # per-entry mismatch checks also need a global by-process_name view to
    # catch entries that reference a process registered on a different page,
    # so both views are built once before the entry loop. Suppressed when the
    # ProcessRegistry preload returned zero rows.
    if ($script:processRegistryByPageRoute.Count -gt 0 -and
        -not $script:CurrentFileIsShared -and $jsFileRow) {

        $pageRoute = Get-PageRouteForJsFile -FileName $script:CurrentFile
        if (-not [string]::IsNullOrEmpty($pageRoute)) {
            $registryEntriesForThisPage = if ($script:processRegistryByPageRoute.ContainsKey($pageRoute)) {
                $script:processRegistryByPageRoute[$pageRoute]
            } else {
                @()
            }

            # Build a global process_name -> registry record map for the
            # per-entry mismatch checks. Used to detect ENGINE_PROCESS_PAGE_MISMATCH
            # (entry references a process registered for a different page)
            # and ENGINE_SLUG_JS_MISMATCH (entry's slug differs from registry).
            $registryByProcessName = @{}
            foreach ($pageKey in $script:processRegistryByPageRoute.Keys) {
                foreach ($regRow in $script:processRegistryByPageRoute[$pageKey]) {
                    if (-not [string]::IsNullOrEmpty($regRow.ProcessName)) {
                        $registryByProcessName[$regRow.ProcessName] = $regRow
                    }
                }
            }

            # Case 1: registry has processes for this page but the file
            # declared no ENGINE_PROCESSES at all.
            if ($registryEntriesForThisPage.Count -gt 0 -and $null -eq $script:CurrentEngineProcessesRow) {
                $processNames = ($registryEntriesForThisPage | ForEach-Object { $_.ProcessName }) -join ', '
                Add-DriftCode -Row $jsFileRow -Code 'MISSING_ENGINE_PROCESSES_DECLARATION' `
                    -Context "ProcessRegistry has active engine-card process(es) for page route '$pageRoute' ($processNames) but no ENGINE_PROCESSES declaration was found."
            }

            # Case 2: ENGINE_PROCESSES is declared. Validate each entry
            # against ProcessRegistry, and detect any registered process
            # missing from the declaration.
            if ($null -ne $script:CurrentEngineProcessesRow) {
                # Build a set of process names declared in JS for the
                # "missing card" check.
                $declaredProcessNames = New-Object 'System.Collections.Generic.HashSet[string]'
                foreach ($entry in $script:CurrentEngineProcessesEntries) {
                    if (-not [string]::IsNullOrEmpty($entry.ProcessName)) {
                        [void]$declaredProcessNames.Add($entry.ProcessName)
                    }
                }

                # Per-entry validation.
                foreach ($entry in $script:CurrentEngineProcessesEntries) {
                    if ([string]::IsNullOrEmpty($entry.ProcessName)) { continue }

                    $regRow = if ($registryByProcessName.ContainsKey($entry.ProcessName)) {
                        $registryByProcessName[$entry.ProcessName]
                    } else {
                        $null
                    }

                    if ($null -eq $regRow) {
                        # Process not registered as an active engine-card
                        # process anywhere. Surface as a slug mismatch
                        # since the slug declared in JS can't be validated.
                        Add-DriftCode -Row $script:CurrentEngineProcessesRow `
                            -Code 'ENGINE_SLUG_JS_MISMATCH' `
                            -Context "ENGINE_PROCESSES entry '$($entry.ProcessName)' at line $($entry.Line) has no matching active engine-card row in ProcessRegistry; the declared slug '$($entry.Slug)' cannot be validated."
                        continue
                    }

                    # Page mismatch: process exists but is registered for
                    # a different page.
                    if ($regRow.PageRoute -ne $pageRoute) {
                        Add-DriftCode -Row $script:CurrentEngineProcessesRow `
                            -Code 'ENGINE_PROCESS_PAGE_MISMATCH' `
                            -Context "ENGINE_PROCESSES entry '$($entry.ProcessName)' at line $($entry.Line) is registered in ProcessRegistry for page route '$($regRow.PageRoute)' but this file's page route is '$pageRoute'."
                    }

                    # Slug mismatch: process exists, but the slug declared
                    # in JS doesn't match the registered cc_engine_slug.
                    if (-not [string]::IsNullOrEmpty($entry.Slug) -and $entry.Slug -ne $regRow.Slug) {
                        Add-DriftCode -Row $script:CurrentEngineProcessesRow `
                            -Code 'ENGINE_SLUG_JS_MISMATCH' `
                            -Context "ENGINE_PROCESSES entry '$($entry.ProcessName)' at line $($entry.Line) declares slug '$($entry.Slug)' but ProcessRegistry has cc_engine_slug '$($regRow.Slug)'."
                    }
                }

                # Missing-card check: processes registered for this page
                # that aren't in the JS declaration.
                foreach ($regEntry in $registryEntriesForThisPage) {
                    if (-not $declaredProcessNames.Contains($regEntry.ProcessName)) {
                        Add-DriftCode -Row $jsFileRow `
                            -Code 'MISSING_ENGINE_CARD_FOR_REGISTERED_PROCESS' `
                            -Context "ProcessRegistry has process '$($regEntry.ProcessName)' (slug '$($regEntry.Slug)') registered for this page but ENGINE_PROCESSES does not include it."
                    }
                }
            }
        }
    }

    $delta = $script:rows.Count - $startCount
    Write-Host ("    -> {0} rows" -f $delta) -ForegroundColor Green
}

# Vendored library anchor rows
# Vendored third-party libraries are cataloged as a single JS_FILE anchor
# row each and never parsed or walked: the CC JS spec does not govern
# third-party minified bundles. The anchor row lets page <script src>
# USAGE references resolve to a real DEFINITION (no <undefined> source).
# Honors -FileFilter so a single-file run emits just the matching anchor.
$vendoredToAnchor = $VendoredFiles
if (-not [string]::IsNullOrEmpty($FileFilter)) {
    $vendoredToAnchor = New-Object System.Collections.Generic.List[string]
    foreach ($f in $VendoredFiles) {
        $name = [System.IO.Path]::GetFileName($f)
        if ($name -eq $FileFilter -or $name -like $FileFilter) {
            [void]$vendoredToAnchor.Add($f)
        }
    }
}

foreach ($vfile in $vendoredToAnchor) {
    $vName = [System.IO.Path]::GetFileName($vfile)
    $vLineCount = 0
    try {
        $vLineCount = ((Get-Content -Path $vfile -Raw -Encoding UTF8 -ErrorAction Stop) -split "`n").Count
    } catch {
        Write-Log ("Could not read vendored file for line count: {0} ({1})" -f $vName, $_.Exception.Message) 'WARN'
    }
    $script:CurrentFile         = $vName
    $script:CurrentFileIsShared = $true
    $script:CurrentFileZone     = 'cc'
    $anchorRow = Add-JsFileRow -LineEnd $vLineCount
    if ($null -ne $anchorRow) {
        Write-Log ("Vendored library anchored (not walked): {0}" -f $vName)
    }
}

# -- Pass 3 - Cross-File Compliance Checks --

Write-Log "Pass 3: cross-file compliance checks..."

# FILE_NOT_REGISTERED: files absent from the Object_Registry zone/scope map
# were stamped zone/scope '<undefined>' during the walk and recorded in
# $objectRegistryMisses. Attach the code to each such file's JS_FILE anchor
# row so the gap surfaces in drift analysis, not only the miss report.
foreach ($missing in $objectRegistryMisses) {
    if ($script:jsFileRowByFile.ContainsKey($missing)) {
        Add-DriftCode -Row $script:jsFileRowByFile[$missing] -Code 'FILE_NOT_REGISTERED' `
            -Context "File '$missing' has no active Object_Registry row; zone and scope are '<undefined>'."
    }
}

# EXCESS_BLANK_LINES: any file with more than one consecutive blank line
# between top-level statements gets the code on its JS_FILE row. Detection
# uses source text rather than line-number gaps so multi-line comments
# between statements do not inflate the blank count.
foreach ($file in $JsFiles) {
    $name = [System.IO.Path]::GetFileName($file)
    if (-not $astCache.ContainsKey($file)) { continue }
    $cached = $astCache[$file]
    $ast = $cached.Ast
    if ($null -eq $ast.body -or $ast.body.Count -lt 2) { continue }

    $excessFound = $false
    for ($ni = 1; $ni -lt $ast.body.Count; $ni++) {
        $prev = $ast.body[$ni - 1]
        $cur  = $ast.body[$ni]
        $prevEnd  = if ($prev.loc -and $prev.loc.end)   { [int]$prev.loc.end.line   } else { 0 }
        $curStart = if ($cur.loc  -and $cur.loc.start) { [int]$cur.loc.start.line } else { 0 }
        if ($prevEnd -gt 0 -and $curStart -gt 0) {
            $blankRun = Get-MaxConsecutiveBlankLines `
                -Source    $cached.Source `
                -StartLine $prevEnd `
                -EndLine   $curStart
            if ($blankRun -gt 1) {
                $excessFound = $true
                break
            }
        }
    }

    if ($excessFound -and $script:jsFileRowByFile.ContainsKey($name)) {
        Add-DriftCode -Row $script:jsFileRowByFile[$name] -Code 'EXCESS_BLANK_LINES' `
            -Context "More than one consecutive blank line appears between top-level constructs in $name."
    }
}

# Build a filename->zone lookup from Object_Registry for the shadow check.
$jsFileZoneByName = @{}
foreach ($file in $JsFiles) {
    $name = [System.IO.Path]::GetFileName($file)
    if (-not $jsFileZoneByName.ContainsKey($name) -and $objectZoneScopeMap.ContainsKey($name)) {
        $jsFileZoneByName[$name] = $objectZoneScopeMap[$name].Zone
    }
}

# SHADOWS_SHARED_FUNCTION (zone-aware). A page file defining a function whose
# name matches a shared function in the same zone gets the drift code on the
# function row. Cross-zone collisions are unrelated namespaces.
$shadowCandidates = @($script:rows | Where-Object {
    ($_.ComponentType -eq 'JS_FUNCTION' -or $_.ComponentType -eq 'JS_FUNCTION_VARIANT') -and
    $_.ReferenceType -eq 'DEFINITION' -and
    $_.Scope -eq 'LOCAL'
})

foreach ($row in $shadowCandidates) {
    $rowZone = if ($jsFileZoneByName.ContainsKey($row.FileName)) { $jsFileZoneByName[$row.FileName] } else { $null }
    if ([string]::IsNullOrEmpty($rowZone)) { continue }
    $zoneShared = if ($script:sharedFunctionsByZone.ContainsKey($rowZone)) { $script:sharedFunctionsByZone[$rowZone] } else { $null }
    $zoneSharedSrc = if ($script:sharedSourceFileByZone.ContainsKey($rowZone)) { $script:sharedSourceFileByZone[$rowZone] } else { @{} }
    if (-not $zoneShared -or -not $zoneShared.Contains($row.ComponentName)) { continue }
    $shadowSourceFile = if ($zoneSharedSrc.ContainsKey($row.ComponentName)) { $zoneSharedSrc[$row.ComponentName] } else { '<shared>' }
    Add-DriftCode -Row $row -Code 'SHADOWS_SHARED_FUNCTION' `
        -Context "Function '$($row.ComponentName)' shadows the shared definition in '$shadowSourceFile'."
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

Write-Log "Clearing existing JS rows from Asset_Registry..."
if (-not [string]::IsNullOrEmpty($FileFilter)) {
    # When running with FileFilter, only clear rows for matching files.
    $cleared = Invoke-SqlNonQuery -Query "DELETE FROM dbo.Asset_Registry WHERE file_type = 'JS' AND file_name LIKE @pattern;" `
        -Parameters @{ pattern = $FileFilter }
} else {
    $cleared = Invoke-SqlNonQuery -Query "DELETE FROM dbo.Asset_Registry WHERE file_type = 'JS';"
}
if (-not $cleared) {
    Write-Log "Failed to clear existing JS rows. Aborting." 'ERROR'
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
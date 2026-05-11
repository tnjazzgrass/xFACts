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
        JS_METHOD[_VARIANT], JS_TIMER, JS_FUNCTION USAGE rows.

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

.NOTES
    File Name : Populate-AssetRegistry-JS.ps1
    Location  : E:\xFACts-PowerShell
    Version   : Tracked in dbo.System_Metadata (component: ControlCenter.AssetRegistry)

================================================================================
CHANGELOG
================================================================================
2026-05-11  Universal anchor-row refactor. Added JS_FILE as a pure-anchor
            row, emitted once per scanned .js file. The new row sits
            immediately before FILE_HEADER in the per-file emission order
            and serves as the universal "this file was scanned" anchor
            across all populators (CSS, JS, HTML, future PS), matching
            the existing HTML_FILE and CSS_FILE patterns. JS_FILE carries
            no raw_text, no purpose_description, and no signature; it is
            structural only. Scope mirrors the file's shared/local
            classification.
            FILE_HEADER's behavior is unchanged - it continues to be
            emitted with the same content, line range, and drift codes
            (MALFORMED_FILE_HEADER, FORBIDDEN_CHANGELOG_BLOCK,
            FILE_ORG_MISMATCH) as before. The split simply separates
            "the file as a whole" from "the file's header block".
            The orphaned $script:fileHeaderRowByFile script-scope map
            (declared and populated, but never read) was removed. The
            new $script:jsFileRowByFile tracker replaces it; it is
            populated by Add-JsFileRow and will be consumed by the
            orphan drift-code detection passes (EXCESS_BLANK_LINES,
            FORBIDDEN_COMMENT_STYLE, BLANK_LINE_INSIDE_FUNCTION_BODY_AT_SCOPE)
            being wired up in the next deliverable.
2026-05-09  FORBIDDEN_PER_ELEMENT_LISTENER_LOOP detection added per
            CC_JS_Spec.md Section 12 (Event handler binding). Detects
            per-element listener attachment via forEach + addEventListener
            and via addEventListener inside for-of / for-in / for-loop
            bodies -- the patterns Section 12 forbids in favor of event
            delegation. Detection lives in the existing addEventListener
            block in the CallExpression visitor case; the drift code
            attaches to the same JS_EVENT USAGE row that already fires for
            the listener. New helper Test-IsInsideElementLoop walks the
            parent-node chain looking for an enclosing forEach callback or
            for-loop body, stopping at any nested FunctionDeclaration so
            inner functions inside loops don't false-positive their own
            addEventListener calls.
2026-05-07  Alignment refactor + prefix registry validation + permissive
            banner detection. Adopts the visitor-pattern walker, pre-built
            section list, hybrid drift attachment, file-header parsing,
            registry loads, bulk insert, and occurrence-index helpers from
            xFACts-AssetRegistryFunctions.ps1. Removes ~1500 lines of
            local-helper code that moved to the helpers file plus the
            development-only end-of-run verification queries.
            New behavior:
              - Granular banner drift codes (BANNER_INLINE_SHAPE,
                BANNER_INVALID_RULE_CHAR, BANNER_INVALID_RULE_LENGTH,
                BANNER_INVALID_SEPARATOR_CHAR, BANNER_INVALID_SEPARATOR_LENGTH,
                BANNER_MALFORMED_TITLE_LINE, BANNER_MISSING_DESCRIPTION)
                replace the legacy catch-all MALFORMED_SECTION_BANNER.
                Permissive admission of banner-shaped comments captures
                non-conforming banners with appropriate drift; previous
                strict gate silently dropped them.
              - File-kind-specific valid-section-type lists. Page files
                get IMPORTS/CONSTANTS/STATE/INITIALIZATION/FUNCTIONS;
                cc-shared.js gets IMPORTS/FOUNDATION/STATE/CHROME.
                FOUNDATION declared in a page file now produces
                UNKNOWN_SECTION_TYPE on the COMMENT_BANNER row instead
                of being silently accepted.
              - Per-banner SECTION_TYPE_ORDER_VIOLATION attachment on
                the COMMENT_BANNER row that broke the ordering, replacing
                the previous single file-level code on FILE_HEADER.
              - Prefix registry validation (Option B per CC_JS_Spec.md
                Section 5.4): every page-file banner declares the file's
                cc_prefix or (none); the hooks banner, IMPORTS, and
                INITIALIZATION sections are exempt and may declare (none).
                New drift codes MALFORMED_PREFIX_VALUE and
                PREFIX_REGISTRY_MISMATCH attach to the COMMENT_BANNER row.
              - DUPLICATE_FOUNDATION / DUPLICATE_CHROME now fire whenever
                FOUNDATION/CHROME appears outside the anchor file
                (cc-shared.js), not only when more than one file declares
                them. Folds in the prior FOUNDATION_OUTSIDE_SHARED_FILE /
                CHROME_OUTSIDE_SHARED_FILE checks.
              - engine-events.js dropped from the window-assignment
                exemption. window.<name> = ... in engine-events.js now
                produces JS_WINDOW_ASSIGNMENT rows with
                FORBIDDEN_WINDOW_ASSIGNMENT drift; the catalog reflects
                the spec, and the migration to cc-shared.js will close
                these rows. engine-events.js remains in $CcSharedFiles
                for USAGE resolution during migration; the two lists
                are now separate.
              - Output-boundary drift code validation
                (Test-DriftCodesAgainstMasterTable) catches typos and
                stale codes before bulk insert.
              - Revealing-module IIFE detection. The pattern
                'const X = (function(){...})();' (and var equivalent)
                is structurally non-spec; the wrapper namespace is
                incompatible with top-level function declarations and
                the spec's prefix rule. Detected in the
                VariableDeclaration visitor case: the wrapper row gets
                FORBIDDEN_REVEALING_MODULE drift, then definition
                suppression turns on (see next item).
              - Definition-suppression mode for forbidden wrappers.
                Replaces the previous SKIP_CHILDREN approach for both
                top-level IIFE and revealing-module IIFE patterns. When
                a wrapper is detected, $script:CurrentSuppressDefinitions
                is set to $true; the walker continues to descend into
                the wrapper body, but JS_FUNCTION / JS_CONSTANT /
                JS_STATE / JS_CLASS / JS_METHOD / JS_IMPORT / JS_TIMER
                definition rows are not emitted. USAGE rows
                (CSS_CLASS, HTML_ID, JS_FUNCTION, JS_EVENT) and
                forbidden-pattern rows (eval, document.write, window.X,
                inline style/script in literals) continue to fire so
                the cross-reference catalog stays complete -- those
                references reach DOM and call shared functions at
                runtime regardless of the wrapper. Applied identically
                to top-level IIFE files (ddl-erd.js, nav.js etc.) and
                revealing-module files (admin.js, bdl-import.js etc.).
              - PREFIX_MISSING drift code on top-level definitions
                (functions, constants, state vars, classes,
                revealing-module wrappers). Fires when
                Component_Registry has a cc_prefix for the file but
                the identifier name does not begin with that prefix +
                underscore. Independent of banners; closes the gap
                where pre-spec files (no banners yet) were silently
                exempt from prefix scrutiny. Hooks and methods inside
                classes are exempt.
            Retired: MALFORMED_SECTION_BANNER (granular codes replace
            it), FUNCTION_IN_NON_FUNCTION_SECTION (out-of-spec; PREFIX
            and SECTION_BANNER codes carry the meaningful signal),
            DUPLICATE_IMPORTS_BANNER / DUPLICATE_INITIALIZATION_BANNER
            (out-of-spec; the Section 4.1 single-banner-only rule has no
            spec-defined drift code, and duplicate banners are visible
            via two COMMENT_BANNER rows with the same signature).
2026-05-06  Top-level IIFE structural skip implemented; SKIP_CHILDREN
            walker signal added.
2026-05-05  AST walk resilience; per-file try/catch with diagnostic
            capture.
2026-05-05  Zone awareness added (CC vs docs); per-zone shared maps for
            functions, constants, classes, and CSS class resolution.
2026-05-05  HTML_ID rows always emitted with scope='LOCAL' per spec
            Section 17.3.
2026-05-05  Phase 1 fixes: phantom-banner-from-file-header bug,
            $SectionTypeOrder map updated for v1.3 spec, source files
            normalized to ASCII.
2026-05-04  Spec-aware rewrite. CC_JS_Spec.md adopted as authoritative
            structural contract. Variant model added.
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

Initialize-XFActsScript -ScriptName 'Populate-AssetRegistry-JS' -Execute:$Execute

$ErrorActionPreference = 'Stop'

# ============================================================================
# CONFIGURATION
# ============================================================================

$NodeExe       = 'C:\Program Files\nodejs\node.exe'
$NodeLibsPath  = 'C:\Program Files\nodejs-libs\node_modules'
$ParseJsScript = "$PSScriptRoot\parse-js.js"

$CcRoot = 'E:\xFACts-ControlCenter'
$JsScanRoots = @(
    "$CcRoot\public\js"
    "$CcRoot\public\docs\js"
)

# Shared files split by zone. CC consumers resolve USAGE references only
# against $ccShared* maps; docs consumers resolve only against $docsShared*.
# CC zone migration: cc-shared.js is the spec-compliant replacement for
# engine-events.js. Both are listed during the page-by-page migration so
# pages can consume either; engine-events.js comes off after migration
# completes.
$CcSharedFiles = @(
    'cc-shared.js',
    'engine-events.js'
)
$DocsSharedFiles = @(
    'nav.js',
    'docs-controlcenter.js',
    'ddl-erd.js',
    'ddl-loader.js'
)
$SharedFiles = $CcSharedFiles + $DocsSharedFiles

# CSS shared files split per zone, used to bucket the CSS_CLASS DEFINITION
# pre-load into per-zone maps. Kept in sync manually with the CSS populator's
# lists; if they drift, JS-side CSS_CLASS USAGE rows may resolve to
# '<undefined>' even though the class is defined in the catalog.
$CcSharedCssFiles = @(
    'cc-shared.css',
    'engine-events.css'
)
$DocsSharedCssFiles = @(
    'docs-base.css',
    'docs-architecture.css',
    'docs-controlcenter.css',
    'docs-erd.css',
    'docs-hub.css',
    'docs-narrative.css',
    'docs-reference.css'
)

# The single canonical CC-zone shared file. Used for FOUNDATION/CHROME
# anchor-file enforcement and as the only file in which window.<name>
# assignment is permitted. engine-events.js is intentionally NOT on this
# list -- it's a legacy file whose window-assignments are spec violations
# that will be eliminated when pages migrate to cc-shared.js.
$CanonicalSharedFile = 'cc-shared.js'

# Files exempt from the FORBIDDEN_WINDOW_ASSIGNMENT check. Per CC_JS_Spec.md
# Section 14, only cc-shared.js may carry window.<name> = ... assignments. Listed
# separately from $CcSharedFiles because the two lists serve different
# purposes (USAGE resolution vs. spec exemption) and may diverge over time.
$WindowAssignmentExemptFiles = @('cc-shared.js')

$env:NODE_PATH = $NodeLibsPath

# ============================================================================
# SPEC CONSTANTS
# ============================================================================

# Recognized section types per CC_JS_Spec.md Section 4. The two file kinds
# (page files vs cc-shared.js) have different valid-type sets; the helpers'
# Get-BannerInfo accepts a -ValidSectionTypes list, so we pass the
# file-kind-appropriate list per file. A FOUNDATION banner in a page file
# produces UNKNOWN_SECTION_TYPE drift via the helper; a CONSTANTS banner in
# cc-shared.js does the same.
$ValidSectionTypes_Page   = @('IMPORTS', 'CONSTANTS', 'STATE', 'INITIALIZATION', 'FUNCTIONS')
$ValidSectionTypes_Shared = @('IMPORTS', 'FOUNDATION', 'STATE', 'CHROME')

# Required ordering of section types. Page files use:
#   IMPORTS -> CONSTANTS -> STATE -> INITIALIZATION -> FUNCTIONS
# cc-shared.js uses:
#   IMPORTS -> FOUNDATION -> STATE -> CHROME
# FOUNDATION and CONSTANTS share slot 2 (parallel concepts in shared vs.
# page files). CHROME and INITIALIZATION share slot 4 (CHROME = cc-shared.js's
# INITIALIZATION+FUNCTIONS combined, per CC_JS_Spec.md Section 4.2). The hashtable
# accommodates both file kinds without requiring two parallel arrays.
$SectionTypeOrder = @{
    'IMPORTS'        = 1
    'FOUNDATION'     = 2
    'CONSTANTS'      = 2
    'STATE'          = 3
    'INITIALIZATION' = 4
    'CHROME'         = 4
    'FUNCTIONS'      = 5
}

# The fixed banner name for the page lifecycle hooks group. Per Section 8.1, the
# banner declares Prefix: (none); per Section 5.4, this is a sanctioned (none)
# carve-out under the prefix registry validation rule.
$HooksBannerName = 'PAGE LIFECYCLE HOOKS'

# Section types whose banners may legitimately declare Prefix: (none) on a
# page file (per CC_JS_Spec.md Section 5.2). These are the carve-outs the strict
# (Option B) registry validation rule honors.
$PrefixNoneAllowedSectionTypes = @('IMPORTS', 'INITIALIZATION')

# The five recognized hook function names (CC_JS_Spec.md Section 8). API contract
# with cc-shared.js -- these names cannot be renamed.
$RecognizedHookNames = @(
    'onPageRefresh',
    'onPageResumed',
    'onSessionExpired',
    'onEngineProcessCompleted',
    'onEngineEventRaw'
)

# Drift code -> human description mapping. Used by Add-DriftCode (helpers)
# to validate codes and to populate drift_text. Aligned with CC_JS_Spec.md
# Section 18. Codes the spec defines but which are detected in cross-file
# Pass 3 still appear here so attachment doesn't fail on the master-table
# check.
$DriftDescriptions = [ordered]@{
    # File header (Section 18.1)
    'MALFORMED_FILE_HEADER'             = "The file's header block is missing, malformed, or contains required fields out of order."
    'FORBIDDEN_CHANGELOG_BLOCK'         = "The file header contains a CHANGELOG block. CHANGELOG blocks are not allowed in JS file headers."
    'FILE_ORG_MISMATCH'                 = "The FILE ORGANIZATION list in the header does not exactly match the section banner titles in the file body, by content or by order."
    # Section banners (Section 18.2)
    'MISSING_SECTION_BANNER'            = "A definition appears outside any banner -- no section banner precedes it in the file."
    'BANNER_INLINE_SHAPE'               = "A section banner uses the single-line ===== Title ===== form. The spec requires a multi-line banner with bracketing rule lines, title line, separator, description block, and Prefix line."
    'BANNER_INVALID_RULE_CHAR'          = "A section banner's opening or closing bracketing line is not composed entirely of '=' characters. Both bracket lines must be all '='."
    'BANNER_INVALID_RULE_LENGTH'        = "A section banner's opening or closing bracketing line is composed of '=' characters but is not exactly 76 characters long."
    'BANNER_INVALID_SEPARATOR_CHAR'     = "A section banner's middle separator line is missing or is not composed entirely of '-' characters. The separator must be all '-'."
    'BANNER_INVALID_SEPARATOR_LENGTH'   = "A section banner's middle separator line is not exactly 76 '-' characters long."
    'BANNER_MALFORMED_TITLE_LINE'       = "A section banner has no recognizable title line in the form '<TYPE>: <NAME>'. The TYPE token must be uppercase letters and underscores only."
    'BANNER_MISSING_DESCRIPTION'        = "A section banner has no description content between the separator and the Prefix line. The description is required (1 to 5 sentences explaining what the section contains)."
    'UNKNOWN_SECTION_TYPE'              = "A section banner declares a TYPE not valid for the file kind. Page files allow IMPORTS, CONSTANTS, STATE, INITIALIZATION, FUNCTIONS. cc-shared.js allows IMPORTS, FOUNDATION, STATE, CHROME."
    'SECTION_TYPE_ORDER_VIOLATION'      = "Section types appear out of the required order for the file kind."
    'MISSING_PREFIX_DECLARATION'        = "A section banner is missing the mandatory Prefix line in its description block."
    'MALFORMED_PREFIX_VALUE'            = "A section banner's Prefix line declares anything other than a single 3-character lowercase prefix or (none)."
    'PREFIX_REGISTRY_MISMATCH'          = "A section banner's declared prefix does not match Component_Registry.cc_prefix for the file's component (with the spec's IMPORTS / INITIALIZATION / hooks-banner carve-outs honored)."
    'DUPLICATE_FOUNDATION'              = "A FOUNDATION section appears in a JS file other than cc-shared.js (the anchor file). FOUNDATION sections live only in the anchor file."
    'DUPLICATE_CHROME'                  = "A CHROME section appears in a JS file other than cc-shared.js (the anchor file). CHROME sections live only in the anchor file."
    'HOOKS_BANNER_NOT_LAST'             = "A FUNCTIONS: PAGE LIFECYCLE HOOKS banner exists but is not the last banner in the file."
    # Definition-level (Section 18.3)
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
    # Forbidden patterns (Section 18.4)
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
    'FORBIDDEN_PER_ELEMENT_LISTENER_LOOP' = "An addEventListener call appears inside a forEach callback or a for-loop body, attaching one listener per element. Spec Section 12 requires event delegation: a single addEventListener on a stable parent that dispatches by event.target.matches/closest plus data-* attributes."
    'FORBIDDEN_FILE_SCOPE_LINE_COMMENT' = "A // line comment appears at file scope. Line comments are permitted only inside function bodies."
    # Comment / structure (Section 18.5)
    'FORBIDDEN_COMMENT_STYLE'           = "A comment exists that is not one of the allowed kinds (file header, section banner, purpose comment, sub-section marker)."
    'BLANK_LINE_INSIDE_FUNCTION_BODY_AT_SCOPE' = "More than one consecutive blank line appears inside a function body."
    'EXCESS_BLANK_LINES'                = "More than one blank line appears between top-level constructs."
}

# ============================================================================
# SCRIPT-SCOPE STATE
# ============================================================================

# Row collection and dedupe tracker. The helpers reference $script:dedupeKeys
# directly via Test-AddDedupeKey.
$script:rows       = New-Object System.Collections.Generic.List[object]
$script:dedupeKeys = New-Object 'System.Collections.Generic.HashSet[string]'

# Per-file JS_FILE row references. Pass 3 / post-walk code uses this map
# to attach file-overall drift codes (EXCESS_BLANK_LINES,
# FORBIDDEN_COMMENT_STYLE) to each file's JS_FILE anchor row. The JS_FILE
# row is the universal "this file was scanned" anchor and is the natural
# host for whole-file concerns; FILE_HEADER continues to host header-
# block-specific concerns.
$script:jsFileRowByFile = @{}

# Per-file context used by the visitor and emitters during the AST walk.
$script:CurrentFile               = $null
$script:CurrentFileIsShared       = $false
$script:CurrentFileZone           = 'cc'
$script:CurrentFileSource         = $null
$script:CurrentLocalFuncs         = $null
$script:CurrentLocalConsts        = $null
$script:CurrentLocalState         = $null
$script:CurrentLocalClasses       = $null
$script:CurrentSections           = $null
$script:CurrentCommentIndex       = $null
$script:CurrentTimerHandles       = $null
$script:CurrentRegistryPrefix     = $null
$script:CurrentRegistryHasMapping = $false
$script:CurrentValidSectionTypes  = $ValidSectionTypes_Page

# When the visitor encounters a structurally-forbidden top-level wrapper (a
# top-level IIFE or a revealing-module IIFE), it sets this flag to $true.
# All subsequent definition emissions in the file are then suppressed: no
# JS_FUNCTION, JS_CONSTANT, JS_STATE, JS_CLASS, JS_METHOD, or JS_IMPORT rows
# fire from inside the wrapper. USAGE rows (CSS_CLASS, HTML_ID, JS_FUNCTION
# usage, JS_EVENT) and forbidden-pattern rows (eval, document.write, window
# assignment, inline style/script) continue to fire so the cross-reference
# catalog stays complete -- those references reach DOM and call cc-shared
# functions at runtime regardless of the wrapper.
# The wrapper row itself (JS_IIFE or the JS_CONSTANT_VARIANT/JS_STATE that
# binds the IIFE result to a name) is emitted FIRST, then this flag turns
# on. Reset to $false at the top of each per-file iteration.
$script:CurrentSuppressDefinitions = $false

# ============================================================================
# ACORN COMMENT-SHAPE ADAPTER
# ============================================================================

# Convert acorn's comment objects into the normalized shape expected by the
# helpers' Get-FileHeaderInfo and New-SectionList: .Type / .Text / .LineStart /
# .LineEnd. acorn produces .type ('Block' or 'Line'), .value (inner text),
# .loc.start.line, .loc.end.line. The original acorn node is kept as
# .OriginalNode for downstream uses that need the raw column offsets etc.
# Only Block comments are normalized for the section-list / file-header
# pipeline; Line comments are handled separately for FORBIDDEN_FILE_SCOPE_LINE_COMMENT.
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


# ============================================================================
# FILE / ZONE HELPERS
# ============================================================================

# Determine which zone a JS file belongs to. Files under public\docs\js\
# are docs-zone; everything else is cc-zone. Used both during Pass 1 (to
# decide which zone's shared map to populate) and during Pass 2 (to scope
# USAGE resolution).
function Get-JsZone {
    param([string]$FullPath)
    if ($FullPath -match '\\public\\docs\\js\\') { return 'docs' }
    return 'cc'
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

function Test-LooksLikeInlineStyle {
    param([string]$Text)
    if ($null -eq $Text) { return $false }
    return $Text -match '<\s*style\b'
}

function Test-LooksLikeInlineScript {
    param([string]$Text)
    if ($null -eq $Text) { return $false }
    return $Text -match '<\s*script\b'
}

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


# ============================================================================
# HTML ATTRIBUTE EXTRACTION FROM STRING/TEMPLATE CONTENTS
# ============================================================================

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


# ============================================================================
# AST POSITION / CONTEXT HELPERS
# ============================================================================

function Get-NodeLine {
    param($Node)
    if ($null -eq $Node) { return 1 }
    if ($Node.loc -and $Node.loc.start -and $Node.loc.start.line) { return [int]$Node.loc.start.line }
    return 1
}

function Get-NodeEndLine {
    param($Node)
    if ($null -eq $Node) { return 1 }
    if ($Node.loc -and $Node.loc.end -and $Node.loc.end.line) { return [int]$Node.loc.end.line }
    return Get-NodeLine -Node $Node
}

function Get-NodeColumn {
    param($Node)
    if ($null -eq $Node) { return 1 }
    if ($Node.loc -and $Node.loc.start -and ($Node.loc.start.PSObject.Properties.Name -contains 'column')) {
        return ([int]$Node.loc.start.column) + 1
    }
    return 1
}

# Determine whether a CallExpression's callee matches a given dotted path.
# The leftmost segment matches the bottom-most object.
function Test-CalleeMatchesEnd {
    param($Callee, [string[]]$Path)
    if ($null -eq $Callee) { return $false }

    $segments = New-Object System.Collections.Generic.List[string]
    $cursor = $Callee
    while ($cursor -and $cursor.type -eq 'MemberExpression') {
        if ($cursor.computed) { return $false }
        if (-not $cursor.property -or $cursor.property.type -ne 'Identifier') { return $false }
        $segments.Insert(0, $cursor.property.name)
        $cursor = $cursor.object
    }
    if ($cursor -and $cursor.type -eq 'Identifier') {
        $segments.Insert(0, $cursor.name)
    }

    if ($segments.Count -lt $Path.Count) { return $false }

    $tail = $segments.Count - $Path.Count
    for ($i = 0; $i -lt $Path.Count; $i++) {
        if ($segments[$tail + $i] -ne $Path[$i]) { return $false }
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

# Returns $true if the current node is inside a per-element listener loop --
# i.e. inside a forEach callback (or map/some/every/find/filter callback,
# all of which are array-iteration callbacks that take a per-element
# function), or inside a for-of / for-in / for loop body. Used by the
# addEventListener detection in the CallExpression visitor case to fire
# FORBIDDEN_PER_ELEMENT_LISTENER_LOOP per CC_JS_Spec.md Section 12.
#
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

# ============================================================================
# VARIANT SHAPE HELPERS
# ============================================================================
# Each helper inspects an AST node (or context) and returns a hashtable
# describing the row's variant shape:
#   @{ ComponentType; VariantType; VariantQualifier1; VariantQualifier2 }
# Per CC_JS_Spec.md Section 16.5.

# JS_FUNCTION (base) vs JS_FUNCTION_VARIANT (async/generator).
# Only FunctionDeclaration nodes produce JS_FUNCTION rows; function/arrow
# expressions assigned to const/var emit FORBIDDEN_ANONYMOUS_FUNCTION on
# the const/var declaration row instead.
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

function Get-RequireVariantShape {
    param([string]$SourcePath)
    return @{ ComponentType = 'JS_IMPORT'; VariantType = 'require'; VariantQualifier1 = $null; VariantQualifier2 = $SourcePath }
}


# ============================================================================
# COMMENT INDEX (PRECEDING-COMMENT LOOKUP)
# ============================================================================

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

# ============================================================================
# AST PARSING (per-file)
# ============================================================================

# Run a single .js file through parse-js.js and return the parsed AST,
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


# ============================================================================
# FILE DISCOVERY
# ============================================================================

Write-Log "Discovering JS files..."

$JsFiles = New-Object System.Collections.Generic.List[string]
foreach ($root in $JsScanRoots) {
    if (-not (Test-Path $root)) {
        Write-Log "Scan root not found, skipping: $root" 'WARN'
        continue
    }
    $found = @(Get-ChildItem -Path $root -Filter '*.js' -Recurse -File |
                 Where-Object { $_.Name -notlike '*.min.js' } |
                 Select-Object -ExpandProperty FullName)
    foreach ($f in $found) { [void]$JsFiles.Add($f) }
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


# ============================================================================
# PASS 1 - PARSE ALL FILES, COLLECT SHARED-SCOPE DEFINITIONS (zone-aware)
# ============================================================================
# Walk every file once to:
#   1. Cache the parse result for use by Pass 2.
#   2. Collect top-level definitions from $CcSharedFiles + $DocsSharedFiles
#      members into per-zone maps so Pass 2 can resolve USAGE rows to
#      their SHARED source within the consumer's own zone only.

Write-Log "Pass 1: parse all files, collect SHARED-scope JS definitions (zone-aware)..."

$astCache = @{}

# Per-zone shared-name maps. CC consumers resolve only against $ccShared*;
# docs consumers resolve only against $docsShared*. Keeps cross-zone names
# from contaminating each other's USAGE resolution.
$script:ccSharedFunctions    = New-Object 'System.Collections.Generic.HashSet[string]'
$script:ccSharedConstants    = New-Object 'System.Collections.Generic.HashSet[string]'
$script:ccSharedClasses      = New-Object 'System.Collections.Generic.HashSet[string]'
$script:ccSharedSourceFile   = @{}
$script:docsSharedFunctions  = New-Object 'System.Collections.Generic.HashSet[string]'
$script:docsSharedConstants  = New-Object 'System.Collections.Generic.HashSet[string]'
$script:docsSharedClasses    = New-Object 'System.Collections.Generic.HashSet[string]'
$script:docsSharedSourceFile = @{}

foreach ($file in $JsFiles) {
    $name = [System.IO.Path]::GetFileName($file)
    $zone = Get-JsZone -FullPath $file

    Write-Host "  Parsing $name ..." -NoNewline
    $parsed = Invoke-JsParse -FilePath $file
    if ($null -eq $parsed) {
        Write-Host " FAILED" -ForegroundColor Red
        continue
    }
    Write-Host " ok" -ForegroundColor Green
    $astCache[$file] = $parsed

    if ($SharedFiles -notcontains $name) { continue }

    if ($zone -eq 'docs') {
        $sharedFunctions  = $script:docsSharedFunctions
        $sharedConstants  = $script:docsSharedConstants
        $sharedClasses    = $script:docsSharedClasses
        $sharedSourceFile = $script:docsSharedSourceFile
    } else {
        $sharedFunctions  = $script:ccSharedFunctions
        $sharedConstants  = $script:ccSharedConstants
        $sharedClasses    = $script:ccSharedClasses
        $sharedSourceFile = $script:ccSharedSourceFile
    }

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
                # Legacy `if (typeof X !== 'function') { window.X = function() ... }`
                # pattern in engine-events.js. Capture the assigned name as a
                # shared function so consumer pages don't trigger
                # SHADOWS_SHARED_FUNCTION on what is, by intent, a shared
                # definition. The drift code FORBIDDEN_CONDITIONAL_DEFINITION
                # plus FORBIDDEN_WINDOW_ASSIGNMENT will still fire on the row,
                # surfacing the cleanup task.
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

Write-Log ("  CC zone   - shared functions: {0}" -f $script:ccSharedFunctions.Count)
Write-Log ("  CC zone   - shared constants: {0}" -f $script:ccSharedConstants.Count)
Write-Log ("  CC zone   - shared classes:   {0}" -f $script:ccSharedClasses.Count)
Write-Log ("  Docs zone - shared functions: {0}" -f $script:docsSharedFunctions.Count)
Write-Log ("  Docs zone - shared constants: {0}" -f $script:docsSharedConstants.Count)
Write-Log ("  Docs zone - shared classes:   {0}" -f $script:docsSharedClasses.Count)


# ============================================================================
# CSS_CLASS DEFINITION PRELOAD (zone-aware)
# ============================================================================
# CSS_CLASS USAGE rows from the JS populator resolve to either SHARED or
# LOCAL scope by looking up the class name in zone-bucketed maps loaded from
# the catalog. The CSS populator must run first (it produces the DEFINITION
# rows that this query reads). When the query returns zero rows or fails,
# every CSS_CLASS USAGE row stamps as scope='LOCAL' / source_file='<undefined>'.

Write-Log "Loading existing CSS_CLASS DEFINITION rows for scope resolution..."

$cssDefs = Get-SqlData -Query @"
SELECT component_name, scope, file_name
FROM dbo.Asset_Registry
WHERE component_type = 'CSS_CLASS'
  AND reference_type = 'DEFINITION'
  AND file_type = 'CSS';
"@

$script:ccSharedClassMap   = @{}
$script:docsSharedClassMap = @{}
$script:ccLocalClassMap    = @{}
$script:docsLocalClassMap  = @{}
$cssPreLoadState = 'QUERY_FAILED'

if ($null -ne $cssDefs) {
    $defArray = @($cssDefs)
    if ($defArray.Count -eq 0) {
        $cssPreLoadState = 'EMPTY'
    } else {
        $cssPreLoadState = 'OK'
        foreach ($d in $defArray) {
            $cn = $d.component_name
            if ([string]::IsNullOrEmpty($cn)) { continue }
            $fn = $d.file_name
            $isDocs = ($DocsSharedCssFiles -contains $fn) -or ($fn -like 'docs-*')
            if ($d.scope -eq 'SHARED') {
                if ($isDocs) {
                    if (-not $script:docsSharedClassMap.ContainsKey($cn)) { $script:docsSharedClassMap[$cn] = $fn }
                } else {
                    if (-not $script:ccSharedClassMap.ContainsKey($cn))   { $script:ccSharedClassMap[$cn] = $fn }
                }
            } else {
                if ($isDocs) {
                    if (-not $script:docsLocalClassMap.ContainsKey($cn)) { $script:docsLocalClassMap[$cn] = $fn }
                } else {
                    if (-not $script:ccLocalClassMap.ContainsKey($cn))   { $script:ccLocalClassMap[$cn] = $fn }
                }
            }
        }
    }
}

switch ($cssPreLoadState) {
    'OK' {
        Write-Log ("  CC zone   - shared CSS classes:     {0}" -f $script:ccSharedClassMap.Count)
        Write-Log ("  CC zone   - local-only CSS classes: {0}" -f $script:ccLocalClassMap.Count)
        Write-Log ("  Docs zone - shared CSS classes:     {0}" -f $script:docsSharedClassMap.Count)
        Write-Log ("  Docs zone - local-only CSS classes: {0}" -f $script:docsLocalClassMap.Count)
    }
    'EMPTY' {
        Write-Log "CSS_CLASS DEFINITION query returned zero rows. Class scope resolution will mark everything '<undefined>'." 'WARN'
    }
    'QUERY_FAILED' {
        Write-Log "Could not load CSS_CLASS DEFINITION rows. Class scope resolution will mark everything '<undefined>'." 'WARN'
    }
}


# ============================================================================
# REGISTRY LOADS
# ============================================================================

Write-Log "Loading Object_Registry mapping for FK resolution..."
$objectRegistryMap = Get-ObjectRegistryMap `
    -ServerInstance $script:XFActsServerInstance `
    -Database       $script:XFActsDatabase `
    -FileType       'JS'
Write-Log ("  Object_Registry rows loaded: {0}" -f $objectRegistryMap.Count)

Write-Log "Loading Component_Registry prefix map for registry validation..."
$componentPrefixMap = Get-ComponentRegistryPrefixMap `
    -ServerInstance $script:XFActsServerInstance `
    -Database       $script:XFActsDatabase `
    -FileType       'JS'
Write-Log ("  Component_Registry prefix rows loaded: {0}" -f $componentPrefixMap.Count)

$objectRegistryMisses = New-Object 'System.Collections.Generic.HashSet[string]'


# ============================================================================
# ZONE-AWARE SHARED MAP ACCESSORS
# ============================================================================

function Get-ZoneSharedClassMap {
    if ($script:CurrentFileZone -eq 'docs') { return $script:docsSharedClassMap }
    return $script:ccSharedClassMap
}
function Get-ZoneLocalClassMap {
    if ($script:CurrentFileZone -eq 'docs') { return $script:docsLocalClassMap }
    return $script:ccLocalClassMap
}
# Defensive: explicit null-fallback with newly-created empty HashSet.
# Two separate failure modes are guarded:
#   1. PowerShell pipeline-unwrapping a HashSet on function return
#      (especially when empty) can collapse the return value to $null
#      at the call site -- the leading comma operator forces the value
#      into a single-element array which the caller unwraps cleanly.
#   2. Edge cases where the script-scope HashSet itself is $null (rare,
#      but possible under deep recursive scope chains during walker).
#      Falling back to a fresh empty HashSet guarantees the caller can
#      safely call .Contains() without a null-method-call exception.
function Get-ZoneSharedFunctions {
    $hs = if ($script:CurrentFileZone -eq 'docs') { $script:docsSharedFunctions } else { $script:ccSharedFunctions }
    if ($null -eq $hs) { $hs = New-Object 'System.Collections.Generic.HashSet[string]' }
    return ,$hs
}
function Get-ZoneSharedSourceFile {
    $h = if ($script:CurrentFileZone -eq 'docs') { $script:docsSharedSourceFile } else { $script:ccSharedSourceFile }
    if ($null -eq $h) { $h = @{} }
    return $h
}

# Returns $true if the file has a registered cc_prefix and the identifier
# name does NOT begin with that prefix + underscore. Returns $false in any
# of these cases:
#   - The file has no Component_Registry mapping (skip silently; the
#     Object_Registry miss advisory flags missing registration separately)
#   - The file's registered cc_prefix is null (e.g. cc-shared.js, hooks-only
#     pages -- the registry says "no prefix expected")
#   - The identifier name DOES begin with the registered prefix + underscore
# Used by every top-level definition emitter (functions, constants, state,
# classes) to fire PREFIX_MISSING drift on pre-spec files that have no
# banners but whose function/const/etc. names should still match the
# registered prefix.
function Test-PrefixMissing {
    param([string]$IdentifierName)
    if ([string]::IsNullOrEmpty($IdentifierName)) { return $false }
    if (-not $script:CurrentRegistryHasMapping)   { return $false }
    if ([string]::IsNullOrEmpty($script:CurrentRegistryPrefix)) { return $false }
    $expected = "$($script:CurrentRegistryPrefix)_"
    return -not $IdentifierName.StartsWith($expected)
}

# ============================================================================
# JS-SPECIFIC ROW EMITTERS
# ============================================================================

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

# Resolve a CSS class name's scope and source file. DEFINITION rows aren't
# emitted by the JS populator (CSS populator owns those); USAGE rows resolve
# against the consumer's zone shared/local maps.
function Resolve-CssClassUsage {
    param([string]$ClassName)
    $sharedMap = Get-ZoneSharedClassMap
    $localMap  = Get-ZoneLocalClassMap
    if ($sharedMap.ContainsKey($ClassName)) { return @{ Scope = 'SHARED'; SourceFile = $sharedMap[$ClassName] } }
    if ($localMap.ContainsKey($ClassName))  { return @{ Scope = 'LOCAL';  SourceFile = $localMap[$ClassName]  } }
    return @{ Scope = 'LOCAL'; SourceFile = '<undefined>' }
}

# Emit the JS_FILE anchor row for the current file. Exactly one row per
# scanned .js file. This is the universal "this file was scanned" anchor,
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
# DUPLICATE_CHROME, and HOOKS_BANNER_NOT_LAST are added here based on
# cross-section / cross-file / cross-registry information.
function Add-CommentBannerRow {
    param(
        $Section,
        [int] $PreviousSectionTypeOrderIdx = -1,
        [bool] $IsLastBanner = $false,
        [bool] $HooksBannerSeen = $false
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

    # ---- Per-banner drift carried over from Get-BannerInfo / New-SectionList ----
    foreach ($code in $Section.BannerDriftCodes) {
        Add-DriftCode -Row $row -Code $code
    }

    # ---- SECTION_TYPE_ORDER_VIOLATION (per-banner) ----
    # Attach to this banner if its type's slot is less than the high-water mark.
    if ($Section.TypeName -and $script:SectionTypeOrder.ContainsKey($Section.TypeName)) {
        $newIdx = [int]$script:SectionTypeOrder[$Section.TypeName]
        if ($PreviousSectionTypeOrderIdx -ge 0 -and $newIdx -lt $PreviousSectionTypeOrderIdx) {
            Add-DriftCode -Row $row -Code 'SECTION_TYPE_ORDER_VIOLATION'
        }
    }

    # ---- DUPLICATE_FOUNDATION / DUPLICATE_CHROME (anchor-file enforcement) ----
    # Per the 2026-05-07 anchor-file generalization (CC_CSS_Spec.md Section 4.3 mirror,
    # applied to JS): FOUNDATION/CHROME may appear ONLY in cc-shared.js. The
    # drift code fires whenever they appear in any other file, regardless of
    # whether more than one file declares them.
    if ($Section.TypeName -eq 'FOUNDATION' -and $script:CurrentFile -ne $script:CanonicalSharedFile) {
        Add-DriftCode -Row $row -Code 'DUPLICATE_FOUNDATION' `
            -Context "FOUNDATION section appears in '$($script:CurrentFile)'; FOUNDATION lives only in '$($script:CanonicalSharedFile)'."
    }
    if ($Section.TypeName -eq 'CHROME' -and $script:CurrentFile -ne $script:CanonicalSharedFile) {
        Add-DriftCode -Row $row -Code 'DUPLICATE_CHROME' `
            -Context "CHROME section appears in '$($script:CurrentFile)'; CHROME lives only in '$($script:CanonicalSharedFile)'."
    }

    # ---- HOOKS_BANNER_NOT_LAST ----
    # If this banner is the hooks banner and it isn't the last banner in
    # the file, attach the drift code here. The IsLastBanner flag is
    # supplied by the caller from the section list.
    $isHooks = ($Section.TypeName -eq 'FUNCTIONS' -and $Section.BannerName -eq $script:HooksBannerName)
    if ($isHooks -and -not $IsLastBanner) {
        Add-DriftCode -Row $row -Code 'HOOKS_BANNER_NOT_LAST'
    }

    # ---- MALFORMED_PREFIX_VALUE ----
    if ($Section.Prefix -and -not (Test-PrefixValueIsValid -Prefix $Section.Prefix)) {
        Add-DriftCode -Row $row -Code 'MALFORMED_PREFIX_VALUE' `
            -Context "Banner declares Prefix '$($Section.Prefix)' which is neither a 3-char lowercase prefix nor (none)."
    }

    # ---- PREFIX_REGISTRY_MISMATCH (JS strict-with-carve-outs / Option B) ----
    # Per CC_JS_Spec.md Section 5.4:
    #   - File has registry mapping with cc_prefix = NULL  -> banner must be (none).
    #     Any non-(none) value is a mismatch.
    #   - File has registry mapping with cc_prefix = X     -> banner must be X,
    #     EXCEPT for the hooks banner, IMPORTS, and INITIALIZATION sections
    #     which may declare (none) per Section 5.2. A different value is always a mismatch.
    #   - File has no registry mapping at all              -> skip validation;
    #     missing Object_Registry row is reported by the miss advisory.
    if ($script:CurrentRegistryHasMapping -and $Section.Prefix -and (Test-PrefixValueIsValid -Prefix $Section.Prefix)) {
        $bannerVal = Get-BannerPrefixValue -Prefix $Section.Prefix    # '' for (none)
        $isNone    = Test-IsPrefixNone -Prefix $Section.Prefix
        $regVal    = $script:CurrentRegistryPrefix                    # $null or 'xxx'

        # Determine if this section is allowed to declare (none) on a
        # page file (registry value present). Hooks banner OR section
        # type in the spec's carve-out list.
        $noneAllowedHere = $isHooks -or
                           ($Section.TypeName -and $PrefixNoneAllowedSectionTypes -contains $Section.TypeName)

        $mismatch = $false
        if ($null -eq $regVal) {
            # Registry says (none); banner must declare (none) too.
            if (-not $isNone) { $mismatch = $true }
        } else {
            # Registry says X. Banner must declare X unless this section
            # is one of the carve-outs and declares (none).
            if ($isNone) {
                if (-not $noneAllowedHere) { $mismatch = $true }
            } else {
                if ($bannerVal -ne $regVal) { $mismatch = $true }
            }
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

function Add-ClassUsageRow {
    param(
        [string]$ClassName,
        [int]$LineStart, [int]$ColumnStart,
        [string]$Signature, [string]$ParentFunction, [string]$RawText
    )
    if ([string]::IsNullOrWhiteSpace($ClassName)) { return $null }

    $resolved = Resolve-CssClassUsage -ClassName $ClassName

    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|CSS_CLASS|$ClassName|USAGE|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $row = New-JsRow `
        -ComponentType  'CSS_CLASS' `
        -ComponentName  $ClassName `
        -ReferenceType  'USAGE' `
        -Scope          $resolved.Scope `
        -SourceFile     $resolved.SourceFile `
        -LineStart      $LineStart `
        -LineEnd        $LineStart `
        -ColumnStart    $ColumnStart `
        -Signature      $Signature `
        -ParentFunction $ParentFunction `
        -RawText        $RawText
    $script:rows.Add($row)
    return $row
}

function Add-HtmlIdRow {
    param(
        [string]$IdName, [string]$ReferenceType,
        [int]$LineStart, [int]$ColumnStart,
        [string]$Signature, [string]$ParentFunction, [string]$RawText
    )
    if ([string]::IsNullOrWhiteSpace($IdName)) { return $null }

    # Per CC_JS_Spec.md Section 16.3, HTML_ID rows are ALWAYS scope='LOCAL' regardless
    # of whether the host file is shared. IDs are inherently page-specific.
    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|HTML_ID|$IdName|$ReferenceType|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $row = New-JsRow `
        -ComponentType  'HTML_ID' `
        -ComponentName  $IdName `
        -ReferenceType  $ReferenceType `
        -Scope          'LOCAL' `
        -SourceFile     $script:CurrentFile `
        -LineStart      $LineStart `
        -LineEnd        $LineStart `
        -ColumnStart    $ColumnStart `
        -Signature      $Signature `
        -ParentFunction $ParentFunction `
        -RawText        $RawText
    $script:rows.Add($row)
    return $row
}

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


# ============================================================================
# LOCAL DEFINITION COLLECTION (per-file)
# ============================================================================

# Walk the top-level Program body and return sets of:
#   Functions / Constants / State / Classes
# Used for same-file USAGE resolution and prefix-consistency checks.
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

# ============================================================================
# JS VISITOR (consumed by Invoke-AstWalk)
# ============================================================================
# The visitor receives ($Node, $ParentChain, $ParentNodes) on every visit.
# State is read from $script:Current* variables set up by the per-file
# orchestration loop. Returning 'SKIP_CHILDREN' stops the walker from
# recursing into the current node's children -- used for top-level IIFEs.

$JsVisitor = {
    param($Node, $ParentChain, $ParentNodes)

    if ($null -eq $Node -or $null -eq $Node.type) { return }

    $line       = Get-NodeLine    -Node $Node
    $endLine    = Get-NodeEndLine -Node $Node
    $col        = Get-NodeColumn  -Node $Node
    $section    = Get-SectionForLine -Sections $script:CurrentSections -Line $line
    $parentName = Get-CurrentParentName -ParentNodes $ParentNodes

    switch ($Node.type) {

        'FunctionDeclaration' {
            if ($script:CurrentSuppressDefinitions) { return }
            if (-not $Node.id -or -not $Node.id.name) { return }
            $isTopLevel    = Test-IsTopLevel -ParentChain $ParentChain
            $isConditional = Test-IsConditionallyDefined -ParentChain $ParentChain
            if (-not $isTopLevel) { return }

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
                if (-not $isHook -and -not $section.IsPrefixNone) {
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
                    if ($script:RecognizedHookNames -notcontains $fnName) {
                        Add-DriftCode -Row $row -Code 'UNKNOWN_HOOK_NAME' `
                            -Context "Function '$fnName' is in the PAGE LIFECYCLE HOOKS banner but is not a recognized hook name."
                    }
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
            # body statements and detect gaps > 1 line between consecutive
            # statements. Per JS spec Section 19.5, more than one blank line
            # inside a function body is drift. The rule is intentionally
            # scoped to top-level function declarations only (the rows this
            # case emits); methods inside classes are out of scope. See the
            # JS spec appendix entry for rationale.
            #
            # Detection model mirrors EXCESS_BLANK_LINES: compare each
            # statement's start line to the previous statement's end line.
            # A gap of more than 2 means two or more blank lines.
            if ($Node.body -and $Node.body.body -and $Node.body.body.Count -ge 2) {
                $bodyStmts = $Node.body.body
                for ($si = 1; $si -lt $bodyStmts.Count; $si++) {
                    $prevStmt = $bodyStmts[$si - 1]
                    $curStmt  = $bodyStmts[$si]
                    $prevEnd  = if ($prevStmt.loc -and $prevStmt.loc.end)   { [int]$prevStmt.loc.end.line   } else { 0 }
                    $curStart = if ($curStmt.loc  -and $curStmt.loc.start) { [int]$curStmt.loc.start.line } else { 0 }
                    if ($prevEnd -gt 0 -and $curStart -gt 0 -and ($curStart - $prevEnd) -gt 2) {
                        Add-DriftCode -Row $row -Code 'BLANK_LINE_INSIDE_FUNCTION_BODY_AT_SCOPE' `
                            -Context "Function '$fnName' has more than one blank line between body statements at line $curStart."
                        break
                    }
                }
            }
        }

        'VariableDeclaration' {
            if ($script:CurrentSuppressDefinitions) { return }
            $isTopLevel = Test-IsTopLevel -ParentChain $ParentChain
            if (-not $isTopLevel) { return }

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

                # Component type derivation: section-context first, fall back to keyword.
                $isStateComponent = $false
                if ($isStateSection)         { $isStateComponent = $true }
                elseif ($isConstantSection)  { $isStateComponent = $false }
                elseif ($Node.kind -eq 'var'){ $isStateComponent = $true }
                else                         { $isStateComponent = $false }

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

                if ($isConstantSection -and $Node.kind -ne 'const') {
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
                elseif (-not $section.IsPrefixNone) {
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
            }
        }

        'ClassDeclaration' {
            if ($script:CurrentSuppressDefinitions) { return }
            $isTopLevel = Test-IsTopLevel -ParentChain $ParentChain
            if (-not $isTopLevel) { return }
            if (-not $Node.id -or -not $Node.id.name) { return }

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
            elseif (-not $section.IsPrefixNone) {
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

            # eval(...)
            if ($callee.type -eq 'Identifier' -and $callee.name -eq 'eval') {
                Add-JsEvalRow -LineStart $line -LineEnd $endLine -ColumnStart $col `
                    -Signature 'eval(...)' -ParentFunction $parentName -RawText 'eval(...)' | Out-Null
            }

            # document.write(...)
            if (Test-CalleeMatchesEnd -Callee $callee -Path @('document','write')) {
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
            if ((Test-CalleeMatchesEnd -Callee $callee -Path @('classList','add'))    -or
                (Test-CalleeMatchesEnd -Callee $callee -Path @('classList','remove')) -or
                (Test-CalleeMatchesEnd -Callee $callee -Path @('classList','toggle'))) {
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
            if (Test-CalleeMatchesEnd -Callee $callee -Path @('getElementById')) {
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
            if ((Test-CalleeMatchesEnd -Callee $callee -Path @('querySelector')) -or
                (Test-CalleeMatchesEnd -Callee $callee -Path @('querySelectorAll'))) {
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
            if (Test-CalleeMatchesEnd -Callee $callee -Path @('addEventListener')) {
                $arg = $Node.arguments | Select-Object -First 1
                if ($arg -and $arg.type -eq 'Literal' -and $arg.value -is [string]) {
                    $evName = $arg.value
                    $evRow = Add-JsEventRow -EventName $evName `
                        -LineStart (Get-NodeLine -Node $arg) `
                        -ColumnStart (Get-NodeColumn -Node $arg) `
                        -Signature "addEventListener('$evName', ...)" -ParentFunction $parentName `
                        -RawText "addEventListener('$evName', ...)"

                    # FORBIDDEN_PER_ELEMENT_LISTENER_LOOP per CC_JS_Spec.md Section 12.
                    # If this addEventListener call is inside a forEach callback
                    # (or sibling) or inside a for-of/for-in/for loop body, the
                    # listener is being attached one-per-element rather than
                    # via delegation. Attach the drift code to the same
                    # JS_EVENT USAGE row that just fired -- no separate row.
                    if ($evRow -and (Test-IsInsideElementLoop -ParentNodes $ParentNodes)) {
                        Add-DriftCode -Row $evRow -Code 'FORBIDDEN_PER_ELEMENT_LISTENER_LOOP' `
                            -Context "addEventListener('$evName', ...) at line $line is inside a per-element loop; spec Section 12 requires delegation."
                    }
                }
            }

            # setAttribute('id'|'class', value)
            if (Test-CalleeMatchesEnd -Callee $callee -Path @('setAttribute')) {
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

            if (-not (Test-LooksLikeHtml -Text $strVal)) { return }
            Add-RowsFromHtmlBearingText -Text $strVal -StartLine $line -StartCol $col `
                -ParentFunction $parentName -RawText $rawSnippet
        }

        'AssignmentExpression' {
            $left  = $Node.left
            $right = $Node.right
            if ($null -eq $left -or $null -eq $right) { return }

            # Pattern 1: window.X = ... (forbidden outside cc-shared.js)
            if ($left.type -eq 'MemberExpression' -and
                -not $left.computed -and
                $left.object -and $left.object.type -eq 'Identifier' -and
                $left.object.name -eq 'window' -and
                $left.property -and $left.property.type -eq 'Identifier') {
                if ($script:WindowAssignmentExemptFiles -notcontains $script:CurrentFile) {
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
            # Top-level IIFE detection. The IIFE emits a JS_IIFE row carrying
            # its full body in raw_text plus FORBIDDEN_IIFE drift. Definition
            # suppression then turns on so inner function / const / class
            # declarations are NOT cataloged (they have no reachability under
            # the wrapper). USAGE rows continue to fire so the cross-reference
            # catalog stays complete.
            $isTopLevel = Test-IsTopLevel -ParentChain $ParentChain
            if ($isTopLevel -and $Node.expression -and $Node.expression.type -eq 'CallExpression') {
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
        }
    }
}

# ============================================================================
# PASS 2 - PER-FILE WALK
# ============================================================================

Write-Log "Pass 2: generating Asset_Registry rows..."

foreach ($file in $JsFiles) {
    $name = [System.IO.Path]::GetFileName($file)
    $isShared = $SharedFiles -contains $name
    $zone = Get-JsZone -FullPath $file

    if (-not $astCache.ContainsKey($file)) {
        Write-Log "  Skipping (no parsed AST): $name" 'WARN'
        continue
    }

    $parsed = $astCache[$file]

    # ---- Set per-file context ----
    $script:CurrentFile         = $name
    $script:CurrentFileIsShared = $isShared
    $script:CurrentFileZone     = $zone
    $script:CurrentFileSource   = $parsed.Source

    # Reset definition-suppression flag for each new file. The flag may have
    # been turned on during the previous file's walk if that file had a
    # forbidden wrapper.
    $script:CurrentSuppressDefinitions = $false

    # File-kind-specific valid section types. cc-shared.js has its own
    # taxonomy (FOUNDATION / CHROME instead of CONSTANTS / INITIALIZATION /
    # FUNCTIONS); page files use the page-file taxonomy.
    $script:CurrentValidSectionTypes = if ($name -eq $script:CanonicalSharedFile) {
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

    # ---- Build normalized comments, comment index, section list ----
    # Collections returned from functions can pipeline-unwrap to $null
    # (empty) or to a single scalar (single element). The @() casts force
    # consistent array shape so downstream Mandatory parameter bindings
    # see a real (possibly empty) array, never $null.
    $normalizedComments = @(Convert-AcornCommentsToNormalized -Comments $parsed.Comments)
    $script:CurrentCommentIndex = New-CommentIndex -NormalizedComments $normalizedComments

    $fileLineCount = ($parsed.Source -split "`n").Count
    $script:CurrentSections = New-SectionList `
        -Comments         $normalizedComments `
        -FileLineCount    $fileLineCount `
        -ValidSectionTypes $script:CurrentValidSectionTypes

    # ---- Emit JS_FILE anchor row ----
    # The JS_FILE row precedes FILE_HEADER and serves as the universal
    # file-level anchor. It is purely structural - no content, no drift
    # by default. The orphan-code detection passes (EXCESS_BLANK_LINES,
    # FORBIDDEN_COMMENT_STYLE) attach to this row.
    $jsFileRow = Add-JsFileRow -LineEnd $fileLineCount

    # ---- Emit FILE_HEADER row ----
    $headerInfo = Get-FileHeaderInfo -Comments $normalizedComments
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
    if ($headerInfo.IsValid) {
        $matchOK = Test-FileOrgMatchesBanners -FileOrgList $headerInfo.FileOrgList -Sections $script:CurrentSections
        if (-not $matchOK) {
            Add-DriftCode -Row $headerRow -Code 'FILE_ORG_MISMATCH'
        }
    }

    # Normalize sections to a real array. New-SectionList returns a
    # List[object] but PowerShell pipeline-unwrapping can collapse a
    # single-element list to a scalar or an empty list to $null when the
    # function's return crosses the call boundary. The @() cast forces a
    # consistent array shape regardless.
    $sectionList = @($script:CurrentSections)

    # ---- Emit COMMENT_BANNER rows from the section list ----
    # Find the index of the hooks banner (if any) for HOOKS_BANNER_NOT_LAST.
    $hooksBannerIdx = -1
    for ($i = 0; $i -lt $sectionList.Count; $i++) {
        $s = $sectionList[$i]
        if ($null -eq $s) { continue }
        if ($s.TypeName -eq 'FUNCTIONS' -and $s.BannerName -eq $script:HooksBannerName) {
            $hooksBannerIdx = $i
            break
        }
    }

    $previousSectionTypeOrderIdx = -1
    for ($i = 0; $i -lt $sectionList.Count; $i++) {
        $s = $sectionList[$i]
        if ($null -eq $s) { continue }
        $isLastBanner = ($i -eq ($sectionList.Count - 1))
        $hooksSeenAlready = ($hooksBannerIdx -ge 0 -and $i -gt $hooksBannerIdx)

        [void](Add-CommentBannerRow -Section $s `
            -PreviousSectionTypeOrderIdx $previousSectionTypeOrderIdx `
            -IsLastBanner $isLastBanner `
            -HooksBannerSeen $hooksSeenAlready)

        if ($s.TypeName -and $script:SectionTypeOrder.ContainsKey($s.TypeName)) {
            $idx = [int]$script:SectionTypeOrder[$s.TypeName]
            if ($idx -gt $previousSectionTypeOrderIdx) {
                $previousSectionTypeOrderIdx = $idx
            }
        }
    }

    # ---- Walk the AST via the generic visitor ----
    $startCount = $script:rows.Count
    $scopeLabel = if ($isShared) { 'SHARED' } else { 'LOCAL' }
    Write-Host ("  Walking {0} ({1}, zone={2})..." -f $name, $scopeLabel, $zone) -ForegroundColor Cyan

    try {
        Invoke-AstWalk -Node $parsed.Ast -Visitor $JsVisitor
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

    # ---- FORBIDDEN_COMMENT_STYLE: stray block comments ----
    # Per JS spec Section 13, only four kinds of block comments are
    # permitted: file header, section banner, purpose comment preceding
    # a definition, and sub-section marker (/* -- label -- */). Any
    # block comment that doesn't match one of these kinds is stray.
    #
    # Detection: walk the normalized comment list. A block comment is
    # claimed if any of these hold:
    #   - It's at line 1 (the file header)
    #   - It passes Test-IsBannerComment (a section banner)
    #   - Its line appears in $script:CurrentCommentIndex with Used=true
    #     (it was consumed as a definition's preceding purpose comment by
    #     Get-PrecedingBlockComment during the AST walk)
    #   - Its trimmed text matches the sub-section marker pattern
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

        # If we got here, it's a stray block comment.
        $strayLines.Add([int]$c.LineStart)
    }
    if ($strayLines.Count -gt 0 -and $jsFileRow) {
        $linesText = ($strayLines | Sort-Object) -join ', '
        Add-DriftCode -Row $jsFileRow -Code 'FORBIDDEN_COMMENT_STYLE' `
            -Context "Stray block comments not matching any of the four allowed kinds (file header, banner, purpose comment, sub-section marker) at line(s): $linesText."
    }

    # ---- File-scope // line comments -> JS_LINE_COMMENT rows ----
    # acorn returns Line comments alongside Block comments. A line comment
    # outside any function body is a forbidden pattern under Section 12.1.
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

    $delta = $script:rows.Count - $startCount
    Write-Host ("    -> {0} rows" -f $delta) -ForegroundColor Green
}


# ============================================================================
# PASS 3 - CROSS-FILE COMPLIANCE CHECKS
# ============================================================================

Write-Log "Pass 3: cross-file compliance checks..."

# EXCESS_BLANK_LINES: any file with blank-line gaps greater than 2 between
# consecutive top-level statements gets the drift code attached to its
# JS_FILE row. Mirrors the CSS populator's detection model. The check
# uses each top-level node's source range: gap = curStart - prevEnd; gap
# > 2 means 2+ blank lines.
foreach ($file in $JsFiles) {
    $name = [System.IO.Path]::GetFileName($file)
    if (-not $astCache.ContainsKey($file)) { continue }
    $ast = $astCache[$file].Ast
    if ($null -eq $ast.body -or $ast.body.Count -lt 2) { continue }

    $excessFound = $false
    for ($ni = 1; $ni -lt $ast.body.Count; $ni++) {
        $prev = $ast.body[$ni - 1]
        $cur  = $ast.body[$ni]
        $prevEnd  = if ($prev.loc -and $prev.loc.end)   { [int]$prev.loc.end.line   } else { 0 }
        $curStart = if ($cur.loc  -and $cur.loc.start) { [int]$cur.loc.start.line } else { 0 }
        if ($prevEnd -gt 0 -and $curStart -gt 0 -and ($curStart - $prevEnd) -gt 2) {
            $excessFound = $true
            break
        }
    }

    if ($excessFound -and $script:jsFileRowByFile.ContainsKey($name)) {
        Add-DriftCode -Row $script:jsFileRowByFile[$name] -Code 'EXCESS_BLANK_LINES' `
            -Context "More than one blank line appears between top-level constructs in $name."
    }
}

# Build a quick filename->zone lookup for the zone-aware shadow check.
$jsFileZoneByName = @{}
foreach ($file in $JsFiles) {
    $name = [System.IO.Path]::GetFileName($file)
    if (-not $jsFileZoneByName.ContainsKey($name)) {
        $jsFileZoneByName[$name] = (Get-JsZone -FullPath $file)
    }
}

# SHADOWS_SHARED_FUNCTION (zone-aware). A page file defining a function whose
# name matches a shared function in the same zone gets the drift code on
# the function row. Cross-zone collisions are unrelated namespaces.
$shadowCandidates = @($script:rows | Where-Object {
    ($_.ComponentType -eq 'JS_FUNCTION' -or $_.ComponentType -eq 'JS_FUNCTION_VARIANT') -and
    $_.ReferenceType -eq 'DEFINITION' -and
    $_.Scope -eq 'LOCAL'
})

foreach ($row in $shadowCandidates) {
    $rowZone = if ($jsFileZoneByName.ContainsKey($row.FileName)) { $jsFileZoneByName[$row.FileName] } else { 'cc' }
    if ($rowZone -eq 'docs') {
        $zoneShared    = $script:docsSharedFunctions
        $zoneSharedSrc = $script:docsSharedSourceFile
    } else {
        $zoneShared    = $script:ccSharedFunctions
        $zoneSharedSrc = $script:ccSharedSourceFile
    }
    if (-not $zoneShared.Contains($row.ComponentName)) { continue }
    $shadowSourceFile = if ($zoneSharedSrc.ContainsKey($row.ComponentName)) { $zoneSharedSrc[$row.ComponentName] } else { '<shared>' }
    Add-DriftCode -Row $row -Code 'SHADOWS_SHARED_FUNCTION' `
        -Context "Function '$($row.ComponentName)' shadows the shared definition in '$shadowSourceFile'."
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
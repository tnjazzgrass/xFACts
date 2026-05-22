<#
.SYNOPSIS
    xFACts - Asset Registry CSS Populator

.DESCRIPTION
    Walks every .css file under the Control Center public/css and
    public/docs/css directories, parses each file with PostCSS (via the
    parse-css.js Node helper), and generates Asset_Registry rows describing
    every cataloguable component found in the file. Each row carries any
    drift codes the parser detects per CC_CSS_Spec.md.

    This populator consumes shared infrastructure from
    xFACts-AssetRegistryFunctions.ps1: row construction, drift attachment,
    bulk insert, banner detection / parsing, file-header parsing, section
    list construction, registry loads, and the generic AST visitor walker.
    Per-language logic (PostCSS comment-shape adapter, selector decomposition,
    per-row emitters, the visitor scriptblock body) lives here.

.PARAMETER Execute
    Required to actually delete the CSS rows from Asset_Registry and write
    the new row set. Without this flag, runs in preview mode.

.NOTES
    File Name : Populate-AssetRegistry-CSS.ps1
    Location  : E:\xFACts-PowerShell
    Version   : Tracked in dbo.System_Metadata (component: Tools.Utilities)

================================================================================
CHANGELOG
================================================================================
2026-05-22  Spec alignment - class-on-class compounds and prefix discipline.
            Four structural changes to align with the rewritten CC_CSS_Spec.md.
            - Class-on-class compounds emit USAGE rows. Per the spec's
              definition vocabulary (section 6.1: a class definition is a
              single-class rule; section 7.1: a variant is a single class
              plus a pseudo-class), a class-on-class compound rule is
              NOT a definition of either participating class. Each class
              is a class in its own right and must be defined by a
              separate standalone rule somewhere. The compound rule
              USES those classes together to apply combined styling.
              Each class token in a compound now emits a USAGE row, not
              a DEFINITION row. Single-class rules (the standalone base,
              and single-class plus pseudo-class variants) continue to
              emit DEFINITION rows. Descendant compounds already emitted
              USAGE; their behavior is unchanged. variant_type='class'
              and variant_type='compound_pseudo' stop being emitted
              entirely; existing rows with those values drain out on
              the next run. The compound shape is preserved in the
              signature column so downstream queries can identify which
              classes participated.
            - PREFIX_MISMATCH on every class token. The prefix check now
              validates every class token in every compound against the
              section's declared prefix, not just the leftmost. Per the
              new spec section 5 and section 7.1, every class token in
              a compound selector carries its section's declared prefix.
              Selectors like `.cc-engine-bar.disabled` now surface
              PREFIX_MISMATCH on the `disabled` token (it doesn't start
              with the section prefix), restoring the discipline the old
              compound-modifier exemption silently bypassed. The prefix
              check fires on every class participation row regardless of
              reference type - definitions and usages alike.
            - ANCHOR_SECTION_INVALID_PREFIX. The new spec separates the
              anchor-file prefix-validation case from the page-file case.
              FOUNDATION, CHROME, and anchor-file FEEDBACK_OVERLAYS
              sections must declare `cc`; anything else fires
              ANCHOR_SECTION_INVALID_PREFIX. Page-file banners declaring
              the wrong page prefix continue to fire PREFIX_REGISTRY_MISMATCH.
              MALFORMED_PREFIX_VALUE's description was tightened to match
              the new spec wording (no more (none) reference; comma-
              separated values now explicitly called out).
            - UNDEFINED_CLASS_USAGE (new code). Because compound rule
              participation no longer emits DEFINITION rows, a class
              that only appears in compounds has no DEFINITION row in
              the catalog. The spec requires every class to have a
              standalone definition (section 6.1). To surface that
              requirement in the catalog, a new drift code
              UNDEFINED_CLASS_USAGE fires on USAGE rows whose component
              has no corresponding DEFINITION row in the appropriate
              scope. Scope resolution honors the zone-shared maps:
              SHARED-scope USAGE rows are pre-resolved during emission
              and skip the check; LOCAL-scope USAGE rows require a
              same-file DEFINITION. The check runs as the last Pass 3
              step after all per-file rows are collected.
              The new code closes the gap that arose from moving
              compound rules from DEFINITION to USAGE - a properly-
              prefixed-but-undefined modifier class would otherwise
              pass silently because PREFIX_MISMATCH doesn't fire on
              it. UNDEFINED_CLASS_USAGE catches that scenario.
              Comment-presence drift codes (MISSING_PURPOSE_COMMENT,
              MISSING_VARIANT_COMMENT) no longer fire on compound USAGE
              rows. Per spec sections 6.1 and 7.1, those codes apply to
              definitions, not usages. A compound rule itself does not
              require a purpose or variant comment because it is neither
              a base class definition nor a variant per the spec.
            Shared helper changes that participate here:
              - Get-FileOrgList (new). FILE ORGANIZATION list now parsed
                verbatim. Trailing "-- annotation" and numbered "1. "
                prefixes no longer silently stripped. Drift surfaces as
                FILE_ORG_MISMATCH downstream.
              - Get-BannerPrefixValue. Trailing "-- annotation" and
                "(parenthetical)" text on the Prefix line no longer
                silently stripped. Drift surfaces as MALFORMED_PREFIX_VALUE.
              - Test-PrefixValueIsValid. No longer constrains page-prefix
                shape to 3 lowercase letters (the registry's CK constraint
                does that). No longer accepts the (none) sentinel for CSS
                callers; only `cc` or a non-empty single token. PS callers
                opt into (none) acceptance via -AllowNoneSentinel.
2026-05-11  Universal anchor-row refactor. Added CSS_FILE as a pure-anchor
            row, emitted once per scanned .css file. The new row sits
            immediately before FILE_HEADER in the per-file emission order
            and serves as the universal "this file was scanned" anchor
            across all populators (CSS, JS, HTML, future PS), matching
            the existing HTML_FILE pattern. CSS_FILE carries no
            raw_text, no purpose_description, and no signature; it is
            structural only. Scope mirrors the file's shared/local
            classification.
            FILE_HEADER's behavior is unchanged - it continues to be
            emitted with the same content, line range, and drift codes
            (MALFORMED_FILE_HEADER, FORBIDDEN_CHANGELOG_BLOCK,
            FILE_ORG_MISMATCH) as before. The split simply separates
            "the file as a whole" from "the file's header block".
            Two file-overall drift codes that were attaching to
            FILE_HEADER as a convenience now attach to CSS_FILE
            instead, because they describe the whole file rather than
            the header construct:
              EXCESS_BLANK_LINES        - blank-line gaps between
                                          top-level constructs anywhere
                                          in the file
              FORBIDDEN_COMMENT_STYLE   - stray block comments anywhere
                                          in the file that don't match
                                          one of the four allowed kinds
            All other drift codes remain on whichever row they
            attached to before.
2026-05-07  Banner drift granular codes. Aligned with CC_CSS_Spec.md
            Section 3 (one canonical banner form, no alternates). Replaced
            the catch-all MALFORMED_SECTION_BANNER with seven granular
            codes that pinpoint the specific spec rule violated:
              BANNER_INLINE_SHAPE             - single-line ===== Title =====
              BANNER_INVALID_RULE_CHAR        - bracket line not all '='
              BANNER_INVALID_RULE_LENGTH      - bracket '=' line != 76 chars
              BANNER_INVALID_SEPARATOR_CHAR   - separator line not all '-'
              BANNER_INVALID_SEPARATOR_LENGTH - separator line != 76 chars
              BANNER_MALFORMED_TITLE_LINE     - no recognizable TYPE: NAME
              BANNER_MISSING_DESCRIPTION      - empty description block
            UNKNOWN_SECTION_TYPE (existing code) is now also emitted from
            the banner parser when the title line shape is correct but the
            TYPE token is not in the closed enum. MISSING_PREFIX_DECLARATION
            unchanged.
            Test-IsBannerComment is now a permissive detector - any
            banner-shaped comment is admitted as a COMMENT_BANNER row,
            with granular codes describing the spec drift. The previous
            strict gate was rejecting ~260 non-conforming banners outright,
            losing catalog visibility on every unrefactored file.
            Retired: MALFORMED_SECTION_BANNER (granular codes replace it).
2026-05-07  First-run fix pass.
            - Pass 3 codebase-level checks rebuilt on a one-time row index
              built at Pass 3 entry. Replaces O(files x literals x rows)
              and O(files x rows) nested scans with O(rows) build + O(1)
              lookups. Fixes the multi-minute Pass 3 runtime observed on
              the first execution.
            - Visitor's FORBIDDEN_COMPOUND_DECLARATION and
              BLANK_LINE_INSIDE_RULE attachments now iterate only the slice
              of $script:rows captured before the rule's selector emission,
              not the full row list. Eliminates O(rules x rows) per-file
              scans during Pass 2.
2026-05-07  Alignment refactor + prefix registry validation. Adopted the
            visitor-pattern walker, pre-built section list, hybrid drift
            attachment, and file-header parsing helpers from
            xFACts-AssetRegistryFunctions.ps1. Removed running-state section
            tracking, the local helper functions that moved to the helpers
            file, and the development-only verification queries at end of
            run. Added prefix registry validation (MALFORMED_PREFIX_VALUE,
            PREFIX_REGISTRY_MISMATCH) and detection wiring for
            BLANK_LINE_INSIDE_RULE, EXCESS_BLANK_LINES,
            FORBIDDEN_COMPOUND_DECLARATION, FORBIDDEN_COMMENT_STYLE,
            FORBIDDEN_ADJACENT_SIBLING, FORBIDDEN_GENERAL_SIBLING, and
            DRIFT_PX_LITERAL. Renamed FORBIDDEN_CHANGELOG ->
            FORBIDDEN_CHANGELOG_BLOCK and MISSING_PREFIXES_DECLARATION ->
            MISSING_PREFIX_DECLARATION to match CC_CSS_Spec.md.
2026-05-06  Methodology note: JS populator added a SKIP_CHILDREN walker
            signal for top-level IIFEs. CSS had no analog at the time.
2026-05-05  AST walk resilience and FILE_HEADER purpose paragraph extraction.
2026-05-04  G-INIT-4 resolution: complete CSS purpose_description coverage.
2026-05-04  G-INIT-3 resolution: PURPOSE_DESCRIPTION wiring, dropped-column
            cleanup, FILE_HEADER signature now NULL.
2026-05-03  Spec amendment Gap 6: @media permitted in any section.
2026-05-03  FILE_ORG_MISMATCH false-positive bug fix and FILE ORGANIZATION
            list parser updates for un-numbered entries.
2026-05-03  FEEDBACK_OVERLAYS section type added.
2026-05-03  FOUNDATION-section exemptions for reset rules; new drift code
            FORBIDDEN_PSEUDO_ELEMENT_LOCATION; (none) prefix sentinel.
2026-05-03  OQ-CSS-1 resolution: forbid :not() and stacked pseudo-classes.
2026-05-03  Sanity-sweep fix pass.
2026-05-03  Major restructure for CSS file format spec compliance.
2026-05-02  Architectural correction: SharedFiles expanded to all docs/css.
2026-05-02  Initial production implementation.
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

Initialize-XFActsScript -ScriptName 'Populate-AssetRegistry-CSS' -Execute:$Execute

$ErrorActionPreference = 'Stop'

# ============================================================================
# CONFIGURATION
# ============================================================================

$NodeExe        = 'C:\Program Files\nodejs\node.exe'
$NodeLibsPath   = 'C:\Program Files\nodejs-libs\node_modules'
$ParseCssScript = "$PSScriptRoot\parse-css.js"

$CcRoot = 'E:\xFACts-ControlCenter'
$CssScanRoots = @(
    "$CcRoot\public\css"
    "$CcRoot\public\docs\css"
)

# Shared files split by zone. CC consumers resolve USAGE references only
# against $ccShared* maps; docs consumers resolve only against $docsShared*.
# CC zone migration: cc-shared.css is the spec-compliant replacement for
# engine-events.css. Both stay listed during the page-by-page migration.
$CcSharedFiles = @(
    'cc-shared.css',
    'engine-events.css'
)
$DocsSharedFiles = @(
    'docs-base.css',
    'docs-architecture.css',
    'docs-controlcenter.css',
    'docs-erd.css',
    'docs-hub.css',
    'docs-narrative.css',
    'docs-reference.css'
)
$SharedFiles = $CcSharedFiles + $DocsSharedFiles

# Per-component chrome-anchor file (CC_CSS_Spec.md Section 4.2). The anchor
# file is the sole legitimate carrier of FOUNDATION and CHROME sections
# for its component, and the only file whose banners may declare
# Prefix: cc. Used by the ANCHOR_SECTION_INVALID_PREFIX check to validate
# cc banners against the file's identity. Note: $CcSharedFiles above lists
# both cc-shared.css and engine-events.css for USAGE resolution during
# the migration window; only cc-shared.css is the chrome anchor.
# $DocsAnchorCssFile follows when the docs-base.css -> docs-shared.css
# migration begins.
$CcAnchorCssFile   = 'cc-shared.css'
$DocsAnchorCssFile = 'docs-base.css'

$env:NODE_PATH = $NodeLibsPath

# ============================================================================
# SPEC CONSTANTS
# ============================================================================

# The six enumerated section types, in required order (CC_CSS_Spec.md Section 4).
$SectionTypeOrder  = @('FOUNDATION', 'CHROME', 'LAYOUT', 'CONTENT', 'OVERRIDES', 'FEEDBACK_OVERLAYS')
$ValidSectionTypes = $SectionTypeOrder

# Anchor-file-only section types per CC_CSS_Spec.md Section 5.1: these
# section types must declare the chrome prefix `cc` in an anchor file.
# FOUNDATION and CHROME are anchor-file-only by section 4.1 (any other file
# carrying them is DUPLICATE_FOUNDATION / DUPLICATE_CHROME drift).
# FEEDBACK_OVERLAYS may appear in either anchor or page files; when in
# an anchor file it also declares `cc`.
$AnchorSectionTypes = @('FOUNDATION', 'CHROME', 'FEEDBACK_OVERLAYS')

# Drift code -> human description mapping. Used by Add-DriftCode (helpers)
# to validate codes and to populate drift_text. Keep aligned with CC_CSS_Spec.md
# Section 14. Codes the spec defines but which are detected in Pass 3 still
# appear here so attachment doesn't fail on the master-table check.
$DriftDescriptions = [ordered]@{
    # File header
    'MALFORMED_FILE_HEADER'             = "The file's header block is missing, malformed, or contains required fields out of order."
    'FORBIDDEN_CHANGELOG_BLOCK'         = "The file header contains a CHANGELOG block. CHANGELOG blocks are not allowed in CSS file headers."
    'FILE_ORG_MISMATCH'                 = "The FILE ORGANIZATION list in the header does not match the section banner titles verbatim, in order."
    # Section banners
    'MISSING_SECTION_BANNER'            = "A class definition (or other catalogable construct) appears outside any banner -- no section banner precedes it in the file."
    'BANNER_INLINE_SHAPE'               = "A section banner uses the single-line ===== Title ===== form. The spec requires a multi-line banner with bracketing rule lines, title line, separator, description block, and Prefix line."
    'BANNER_INVALID_RULE_CHAR'          = "A section banner's opening or closing bracketing line is not composed entirely of '=' characters. Both bracket lines must be all '='."
    'BANNER_INVALID_RULE_LENGTH'        = "A section banner's opening or closing bracketing line is composed of '=' characters but is not exactly 76 characters long."
    'BANNER_INVALID_SEPARATOR_CHAR'     = "A section banner's middle separator line is missing or is not composed entirely of '-' characters. The separator must be all '-'."
    'BANNER_INVALID_SEPARATOR_LENGTH'   = "A section banner's middle separator line is not exactly 76 '-' characters long."
    'BANNER_MALFORMED_TITLE_LINE'       = "A section banner has no recognizable title line in the form '<TYPE>: <NAME>'. The TYPE token must be uppercase letters and underscores only."
    'BANNER_MISSING_DESCRIPTION'        = "A section banner has no description content between the separator and the Prefix line. The description is required (1 to 5 sentences explaining what the section contains)."
    'UNKNOWN_SECTION_TYPE'              = "A section banner declares a TYPE not in the enumerated list (FOUNDATION, CHROME, LAYOUT, CONTENT, OVERRIDES, FEEDBACK_OVERLAYS)."
    'SECTION_TYPE_ORDER_VIOLATION'      = "Section types appear out of the required order (FOUNDATION -> CHROME -> LAYOUT -> CONTENT -> OVERRIDES -> FEEDBACK_OVERLAYS)."
    'MISSING_PREFIX_DECLARATION'        = "A section banner is missing the mandatory Prefix line in its description block."
    'MALFORMED_PREFIX_VALUE'            = "A section banner declares a Prefix value that is neither a page prefix nor 'cc', or declares multiple comma-separated values."
    'PREFIX_REGISTRY_MISMATCH'          = "A page-file section banner's declared prefix does not match Component_Registry.cc_prefix for the file's component."
    'ANCHOR_SECTION_INVALID_PREFIX'     = "A FOUNDATION, CHROME, or anchor-file FEEDBACK_OVERLAYS section declares a prefix other than 'cc'."
    'DUPLICATE_FOUNDATION'              = "More than one CSS file in the codebase contains a FOUNDATION section."
    'DUPLICATE_CHROME'                  = "More than one CSS file in the codebase contains a CHROME section."
    # Class definitions
    'PREFIX_MISMATCH'                   = "A class name's leftmost token does not begin with the declared prefix. Every class token in a compound selector is checked."
    'MISSING_PURPOSE_COMMENT'           = "A base class definition is not preceded by a single-line purpose comment."
    'MISSING_VARIANT_COMMENT'           = "A class variant does not carry a trailing inline comment after the opening brace."
    'UNDEFINED_CLASS_USAGE'             = "A class is used in a compound or descendant selector but has no standalone definition in scope. Every class participating in a compound or descendant rule must be defined by a separate single-class rule somewhere in the same file (or, for usages of shared classes, in the zone's shared files)."
    # Forbidden selectors
    'FORBIDDEN_ELEMENT_SELECTOR'        = "A rule's selector is an element selector (e.g., body, h1, a). Element-only styling must move to FOUNDATION."
    'FORBIDDEN_UNIVERSAL_SELECTOR'      = "A rule uses the universal selector (*). Reset rules must move to FOUNDATION."
    'FORBIDDEN_ATTRIBUTE_SELECTOR'      = "A rule's selector contains an attribute matcher. Attribute-based styling must be replaced with class-based styling."
    'FORBIDDEN_ID_SELECTOR'             = "A rule's selector includes an #id token. Class-based styling required."
    'FORBIDDEN_GROUP_SELECTOR'          = "A rule's selector contains a comma. Each selector gets its own definition block."
    'FORBIDDEN_DESCENDANT'              = "A rule's selector contains a descendant combinator. Restructure as a separate class definition."
    'FORBIDDEN_CHILD_COMBINATOR'        = "A rule's selector contains a child combinator (>). Restructure as a separate class definition."
    'FORBIDDEN_ADJACENT_SIBLING'        = "A rule's selector contains an adjacent sibling combinator (+). Restructure as a separate class definition."
    'FORBIDDEN_GENERAL_SIBLING'         = "A rule's selector contains a general sibling combinator (~). Restructure as a separate class definition."
    'COMPOUND_DEPTH_3PLUS'              = "A compound selector contains three or more class tokens. Refactor as a single class plus at most one modifier class."
    'PSEUDO_INTERLEAVED'                = "A pseudo-class appears between two class tokens. Pseudo-classes must come last in any compound."
    'FORBIDDEN_NOT_PSEUDO'              = "A selector contains :not(...). Express the negation as an explicit state class instead."
    'FORBIDDEN_STACKED_PSEUDO'          = "A compound selector contains two or more pseudo-classes. Reduce to a single pseudo and express the additional condition as a class modifier."
    'FORBIDDEN_PSEUDO_ELEMENT_LOCATION' = "A pseudo-element selector (e.g., ::before, ::-webkit-scrollbar) appears outside FOUNDATION and is not attached to a class."
    # Forbidden at-rules
    'FORBIDDEN_AT_IMPORT'               = "The file contains an @import rule."
    'FORBIDDEN_AT_FONT_FACE'            = "The file contains an @font-face rule."
    'FORBIDDEN_AT_SUPPORTS'             = "The file contains an @supports rule."
    'FORBIDDEN_KEYFRAMES_LOCATION'      = "An @keyframes definition appears in a section other than FOUNDATION (or in a file with no FOUNDATION)."
    'FORBIDDEN_CUSTOM_PROPERTY_LOCATION'= "A custom property definition appears in a section other than FOUNDATION."
    # Drift annotations
    'DRIFT_HEX_LITERAL'                 = "A hex color literal appears in a class declaration's value where a custom property has been defined for that color."
    'DRIFT_PX_LITERAL'                  = "A pixel literal appears in a class declaration's value where a size token has been defined for that size."
    # Comment / formatting
    'FORBIDDEN_COMMENT_STYLE'           = "A comment exists that is not one of the allowed kinds (file header, section banner, per-class purpose comment, trailing variant comment, sub-section marker)."
    'FORBIDDEN_COMPOUND_DECLARATION'    = "Two or more declarations appear on the same line. Each declaration must be on its own line."
    'BLANK_LINE_INSIDE_RULE'            = "A blank line appears inside a class definition (between the opening { and the closing })."
    'EXCESS_BLANK_LINES'                = "More than one blank line appears between top-level constructs."
}

# ============================================================================
# SCRIPT-SCOPE STATE
# ============================================================================

# Row collection and dedupe tracker. The helpers reference $script:dedupeKeys
# directly (Test-AddDedupeKey).
$script:rows       = New-Object System.Collections.Generic.List[object]
$script:dedupeKeys = New-Object 'System.Collections.Generic.HashSet[string]'

# Per-file metadata accumulated during walk and used by Pass 3.
$script:fileMeta = @{}

# Per-file CSS_FILE row references. Pass 3 uses this map to attach
# file-overall drift codes (EXCESS_BLANK_LINES) to each file's CSS_FILE
# anchor row. The CSS_FILE row is the universal "this file was scanned"
# anchor and is the natural host for whole-file concerns; FILE_HEADER
# continues to host header-block-specific concerns.
$script:cssFileRowByFile = @{}

# Per-file context used by row emitters during the AST walk. Replaces the
# previous running-state model. The section list is the source of truth for
# "what section is this line in"; emitters look it up via Get-SectionForLine.
$script:CurrentFile          = $null
$script:CurrentFileIsShared  = $false
$script:CurrentFileZone      = 'cc'
$script:CurrentFileLineCount = 0
$script:CurrentSections      = $null    # output of New-SectionList
$script:CurrentRegistryPrefix = $null   # cc_prefix value from Component_Registry for this file
$script:CurrentRegistryHasMapping = $false  # whether the file has any Component_Registry row at all
$script:CurrentFileIsAnchor   = $false  # whether the file is the zone's chrome anchor
$script:CurrentNormalizedComments = $null   # output of Convert-PostCssCommentsToNormalized
$script:CurrentUsedCommentLines = $null     # HashSet[int] of comment LineStart values consumed by rules

# ============================================================================
# POSTCSS COMMENT-SHAPE ADAPTER
# ============================================================================

# Walk the PostCSS AST and collect every comment node into the normalized
# comment-object shape that the helpers' Get-FileHeaderInfo and New-SectionList
# expect: .Type / .Text / .LineStart / .LineEnd. PostCSS only produces block
# comments, so .Type is always 'Block'. The original PostCSS node is kept as
# .OriginalNode for downstream uses that need the raw text exactly as written.
# Returns a list sorted by LineStart ascending.
function Convert-PostCssCommentsToNormalized {
    param([Parameter(Mandatory)] $AstRoot)

    $list = New-Object System.Collections.Generic.List[object]
    $stack = New-Object System.Collections.Generic.Stack[object]
    $stack.Push($AstRoot)

    while ($stack.Count -gt 0) {
        $n = $stack.Pop()
        if ($null -eq $n) { continue }

        if ($n.type -eq 'comment') {
            $line    = if ($n.source -and $n.source.start) { [int]$n.source.start.line } else { 1 }
            $endLine = if ($n.source -and $n.source.end)   { [int]$n.source.end.line   } else { $line }
            $col     = if ($n.source -and $n.source.start -and ($n.source.start.PSObject.Properties.Name -contains 'column')) {
                           [int]$n.source.start.column
                       } else { 1 }

            $list.Add([pscustomobject]@{
                Type         = 'Block'
                Text         = $n.text
                LineStart    = $line
                LineEnd      = $endLine
                ColumnStart  = $col
                OriginalNode = $n
            })
        }

        if ($n.nodes) {
            foreach ($child in $n.nodes) { $stack.Push($child) }
        }
    }

    return @($list | Sort-Object LineStart)
}

# ============================================================================
# FILE / ZONE / PARSER HELPERS
# ============================================================================

# Determine which zone a CSS file belongs to. Files under public\docs\css\
# are docs-zone; everything else is cc-zone.
function Get-CssZone {
    param([string]$FullPath)
    if ($FullPath -match '\\public\\docs\\css\\') { return 'docs' }
    return 'cc'
}

# Parse a CSS file via the parse-css.js Node helper. Returns the parsed AST
# wrapper ($parsed.ast holds the tree), or $null on parse failure.
function Invoke-CssParse {
    param([Parameter(Mandatory)][string]$FilePath)

    try {
        $source = Get-Content -Path $FilePath -Raw -Encoding UTF8
        if (-not $source) { $source = '' }

        $output  = $source | & $NodeExe $ParseCssScript 2>&1
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
            Write-Log "PostCSS parse failed for ${FilePath} at line ${line} col ${col}: $msg" 'ERROR'
            return $null
        }

        return $parsed
    }
    catch {
        Write-Log "Exception during parse of ${FilePath}: $($_.Exception.Message)" 'ERROR'
        return $null
    }
}

# Collapse multi-line text to a single line. Used to normalize raw_text and
# similar storage values where line breaks would interfere with display.
function Format-SingleLine {
    param([string]$Text)
    if ($null -eq $Text) { return $null }
    $crlf = "`r`n"; $lf = "`n"; $cr = "`r"
    return ($Text -replace $crlf, ' ' -replace $lf, ' ' -replace $cr, ' ').Trim()
}

# Build the full single-line representation of a CSS rule (selector + decls).
# Used to populate raw_text on CSS_CLASS, CSS_VARIANT, CSS_RULE, and HTML_ID
# rows so downstream queries can compare rule bodies without re-opening source.
function Format-RuleBody {
    param(
        [Parameter(Mandatory)] $RuleNode,
        [Parameter(Mandatory)] [string]$SelectorText
    )

    $decls = @()
    if ($RuleNode.nodes) {
        foreach ($child in $RuleNode.nodes) {
            if ($child.type -eq 'decl') {
                $important = if ($child.important) { ' !important' } else { '' }
                $decls += "$($child.prop): $($child.value)$important;"
            }
        }
    }

    $selectorClean = Format-SingleLine -Text $SelectorText
    if ($decls.Count -gt 0) {
        return "$selectorClean { $($decls -join ' ') }"
    }
    return "$selectorClean { }"
}

# Find every var(--name) reference in a CSS property value.
function Get-VarReferences {
    param([string]$Value)
    if ($null -eq $Value) { return @() }
    $matchSet = [regex]::Matches($Value, 'var\(\s*--([a-zA-Z0-9_-]+)\s*[,)]')
    return @($matchSet | ForEach-Object { $_.Groups[1].Value })
}

# Find every hex color literal in a property value (#abc, #abcdef, #aabbccdd).
function Get-HexLiterals {
    param([string]$Value)
    if ($null -eq $Value) { return @() }
    $matchSet = [regex]::Matches($Value, '#[0-9a-fA-F]{3,8}\b')
    return @($matchSet | ForEach-Object { $_.Value })
}

# Find every pixel literal in a property value (12px, 1.5px, etc.). Used by
# Pass 3 DRIFT_PX_LITERAL detection, mirroring Get-HexLiterals.
function Get-PxLiterals {
    param([string]$Value)
    if ($null -eq $Value) { return @() }
    $matchSet = [regex]::Matches($Value, '\b\d+(?:\.\d+)?px\b')
    return @($matchSet | ForEach-Object { $_.Value })
}

# ============================================================================
# SELECTOR DECOMPOSITION
# ============================================================================

# Walk a selector's children, splitting at combinator boundaries. Returns
# array of compound objects describing what each compound contains: classes,
# ids, pseudo-classes, pseudo-elements, attribute count, tag/universal flags,
# and a pseudo-interleaved flag (true if a pseudo-class appeared before the
# last class token).
function Get-CompoundList {
    param([Parameter(Mandatory)] $SelectorChildren)

    $compounds = New-Object System.Collections.Generic.List[object]

    $newAccumulator = {
        @{
            Classes           = New-Object System.Collections.Generic.List[string]
            Ids               = New-Object System.Collections.Generic.List[string]
            Pseudos           = New-Object System.Collections.Generic.List[string]
            PseudoElements    = New-Object System.Collections.Generic.List[string]
            AttrCount         = 0
            HasTag            = $false
            HasUniversal      = $false
            PseudoInterleaved = $false
            SawPseudo         = $false
            CombinatorBefore  = $null   # combinator that joined this compound to the previous
        }
    }

    $finalize = {
        param($acc)
        [pscustomobject]@{
            Classes           = @($acc.Classes.ToArray())
            Ids               = @($acc.Ids.ToArray())
            Pseudos           = @($acc.Pseudos.ToArray())
            PseudoElements    = @($acc.PseudoElements.ToArray())
            AttrCount         = $acc.AttrCount
            HasTag            = $acc.HasTag
            HasUniversal      = $acc.HasUniversal
            PseudoInterleaved = $acc.PseudoInterleaved
            CombinatorBefore  = $acc.CombinatorBefore
        }
    }

    $current = & $newAccumulator
    $pendingCombinator = $null

    foreach ($node in $SelectorChildren) {
        $t = $node.type
        if ($t -eq 'combinator') {
            [void]$compounds.Add((& $finalize $current))
            $current = & $newAccumulator
            # The combinator value is the literal character: ' ' (descendant),
            # '>', '+', '~'. Capture for the NEXT compound's CombinatorBefore.
            $combVal = if ($node.value) { $node.value.Trim() } else { '' }
            if ([string]::IsNullOrEmpty($combVal)) { $combVal = ' ' }
            $current.CombinatorBefore = $combVal
            continue
        }
        switch ($t) {
            'class' {
                if ($current.SawPseudo) { $current.PseudoInterleaved = $true }
                $current.Classes.Add($node.value)
            }
            'id' {
                $current.Ids.Add($node.value)
            }
            'pseudo' {
                $rawVal = $node.value
                $bare   = if ($rawVal) { $rawVal.TrimStart(':') } else { $null }
                if ($rawVal -and $rawVal.StartsWith('::')) {
                    $current.PseudoElements.Add($bare)
                } else {
                    $current.Pseudos.Add($bare)
                    $current.SawPseudo = $true
                }
            }
            'attribute' { $current.AttrCount++ }
            'tag'       { $current.HasTag = $true }
            'universal' { $current.HasUniversal = $true }
        }
    }
    [void]$compounds.Add((& $finalize $current))

    return ,@($compounds.ToArray())
}

# ============================================================================
# PASS 1 - COLLECT SHARED-SCOPE DEFINITIONS (zone-aware)
# ============================================================================

Write-Log "Pass 1: collecting SHARED-scope CSS definitions (zone-aware)..."

$script:ccSharedClassMap     = @{}
$script:ccSharedVariableMap  = @{}
$script:ccSharedKeyframeMap  = @{}
$script:docsSharedClassMap   = @{}
$script:docsSharedVariableMap = @{}
$script:docsSharedKeyframeMap = @{}
$astCache = @{}

$CssFiles = New-Object System.Collections.Generic.List[string]
foreach ($root in $CssScanRoots) {
    if (-not (Test-Path $root)) {
        Write-Log "Scan root not found, skipping: $root" 'WARN'
        continue
    }
    $found = @(Get-ChildItem -Path $root -Filter '*.css' -Recurse -File |
                 Select-Object -ExpandProperty FullName)
    foreach ($f in $found) { [void]$CssFiles.Add($f) }
}
Write-Log "Discovered $($CssFiles.Count) .css files to scan"

foreach ($file in $CssFiles) {
    $name = [System.IO.Path]::GetFileName($file)
    $zone = Get-CssZone -FullPath $file

    Write-Host "  Parsing $name ..." -NoNewline
    $parsed = Invoke-CssParse -FilePath $file
    if ($null -eq $parsed) {
        Write-Host " FAILED" -ForegroundColor Red
        continue
    }
    Write-Host " ok" -ForegroundColor Green
    $astCache[$file] = $parsed

    if ($SharedFiles -notcontains $name) { continue }

    if ($zone -eq 'docs') {
        $classMap = $script:docsSharedClassMap
        $varMap   = $script:docsSharedVariableMap
        $kfMap    = $script:docsSharedKeyframeMap
    } else {
        $classMap = $script:ccSharedClassMap
        $varMap   = $script:ccSharedVariableMap
        $kfMap    = $script:ccSharedKeyframeMap
    }

    $stack = New-Object System.Collections.Generic.Stack[object]
    $stack.Push($parsed.ast)
    while ($stack.Count -gt 0) {
        $node = $stack.Pop()
        if ($null -eq $node) { continue }

        if ($node.type -eq 'rule' -and $node.selectorTree -and $node.selectorTree.nodes) {
            foreach ($sel in $node.selectorTree.nodes) {
                if ($sel.type -ne 'selector') { continue }
                $compounds = Get-CompoundList -SelectorChildren $sel.nodes
                # Record every class token from every compound as defined
                # in this shared file. Under the new spec each class is a
                # real class in its own right, so a class-on-class compound
                # like .foo.bar registers both `foo` and `bar` (first
                # occurrence wins).
                foreach ($cmp in $compounds) {
                    foreach ($cls in $cmp.Classes) {
                        if (-not $classMap.ContainsKey($cls)) {
                            $classMap[$cls] = $name
                        }
                    }
                }
            }
        }

        if ($node.type -eq 'decl' -and $node.prop -and $node.prop.StartsWith('--')) {
            $varName = $node.prop.Substring(2)
            if (-not $varMap.ContainsKey($varName)) {
                $varMap[$varName] = $name
            }
        }

        if ($node.type -eq 'atrule' -and $node.name -eq 'keyframes' -and $node.params) {
            $kfName = $node.params.Trim()
            if (-not $kfMap.ContainsKey($kfName)) {
                $kfMap[$kfName] = $name
            }
        }

        if ($node.nodes) {
            foreach ($child in $node.nodes) { $stack.Push($child) }
        }
    }
}

Write-Log ("  CC zone   - shared classes:    {0}" -f $script:ccSharedClassMap.Count)
Write-Log ("  CC zone   - shared variables:  {0}" -f $script:ccSharedVariableMap.Count)
Write-Log ("  CC zone   - shared keyframes:  {0}" -f $script:ccSharedKeyframeMap.Count)
Write-Log ("  Docs zone - shared classes:    {0}" -f $script:docsSharedClassMap.Count)
Write-Log ("  Docs zone - shared variables:  {0}" -f $script:docsSharedVariableMap.Count)
Write-Log ("  Docs zone - shared keyframes:  {0}" -f $script:docsSharedKeyframeMap.Count)

# ============================================================================
# REGISTRY LOADS
# ============================================================================

Write-Log "Loading Object_Registry mapping for FK resolution..."
$objectRegistryMap = Get-ObjectRegistryMap `
    -ServerInstance $script:XFActsServerInstance `
    -Database       $script:XFActsDatabase `
    -FileType       'CSS'
Write-Log ("  Object_Registry rows loaded: {0}" -f $objectRegistryMap.Count)

Write-Log "Loading Component_Registry prefix map for registry validation..."
$componentPrefixMap = Get-ComponentRegistryPrefixMap `
    -ServerInstance $script:XFActsServerInstance `
    -Database       $script:XFActsDatabase `
    -FileType       'CSS'
Write-Log ("  Component_Registry prefix rows loaded: {0}" -f $componentPrefixMap.Count)

$objectRegistryMisses = New-Object 'System.Collections.Generic.HashSet[string]'

# ============================================================================
# ZONE-AWARE SHARED MAP ACCESSORS
# ============================================================================

function Get-ZoneSharedClassMap {
    if ($script:CurrentFileZone -eq 'docs') { return $script:docsSharedClassMap }
    return $script:ccSharedClassMap
}
function Get-ZoneSharedVariableMap {
    if ($script:CurrentFileZone -eq 'docs') { return $script:docsSharedVariableMap }
    return $script:ccSharedVariableMap
}
function Get-ZoneSharedKeyframeMap {
    if ($script:CurrentFileZone -eq 'docs') { return $script:docsSharedKeyframeMap }
    return $script:ccSharedKeyframeMap
}

# ============================================================================
# CSS-SPECIFIC ROW EMITTERS
# ============================================================================

# Wrap New-AssetRegistryRow with the per-file context that every CSS row
# carries (file_name = current file, file_type = CSS, source_section = the
# section the row's line falls inside, source_file = current file by default).
# Source-section lookup uses the pre-built section list, replacing the
# previous running-state model.
function New-CssRow {
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

    if (-not $SourceFile)    { $SourceFile = $script:CurrentFile }
    if (-not $SourceSection -and -not $SuppressSectionLookup) {
        $sec = Get-SectionForLine -Sections $script:CurrentSections -Line $LineStart
        if ($sec) { $SourceSection = $sec.FullTitle }
    }

    return New-AssetRegistryRow `
        -FileName           $script:CurrentFile `
        -FileType           'CSS' `
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

# Resolve a class name's scope and source file. DEFINITION rows attribute to
# the current file; USAGE rows resolve against the consumer's zone shared map.
function Resolve-ClassScope {
    param([string]$ClassName)
    $map = Get-ZoneSharedClassMap
    if ($map.ContainsKey($ClassName)) {
        return @{ Scope = 'SHARED'; SourceFile = $map[$ClassName] }
    }
    return @{ Scope = 'LOCAL'; SourceFile = $script:CurrentFile }
}

# Emit the CSS_FILE anchor row for the current file. Exactly one row per
# scanned .css file. This is the universal "this file was scanned" anchor,
# parallel to JS_FILE, HTML_FILE, and (future) PS_FILE. The row carries
# no raw_text, no purpose_description, and no signature - it is purely
# structural. Pass 3 attaches file-overall drift codes (EXCESS_BLANK_LINES)
# to this row.
function Add-CssFileRow {
    param([int]$LineEnd)

    $key = "$($script:CurrentFile)|1|CSS_FILE|$($script:CurrentFile)|DEFINITION|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }
    $row = New-CssRow `
        -ComponentType 'CSS_FILE' `
        -ComponentName $script:CurrentFile `
        -LineStart     1 `
        -LineEnd       $LineEnd `
        -ColumnStart   1 `
        -ReferenceType 'DEFINITION' `
        -Scope         $scope `
        -SuppressSectionLookup
    $script:rows.Add($row)
    $script:cssFileRowByFile[$script:CurrentFile] = $row
    return $row
}

function Add-FileHeaderRow {
    param(
        [int]$LineStart, [int]$LineEnd,
        [string]$RawText, [string]$PurposeDescription
    )
    $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }
    $row = New-CssRow `
        -ComponentType      'FILE_HEADER' `
        -ComponentName      $script:CurrentFile `
        -LineStart          $LineStart `
        -LineEnd            $LineEnd `
        -Scope              $scope `
        -RawText            $RawText `
        -PurposeDescription $PurposeDescription `
        -SuppressSectionLookup
    $script:rows.Add($row)
    return $row
}

function Add-CssRuleRow {
    param(
        [int]$LineStart, [int]$LineEnd, [int]$ColumnStart,
        [string]$Signature, [string]$ParentAtrule, [string]$RawText
    )
    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|CSS_RULE||DEFINITION|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }
    $row = New-CssRow `
        -ComponentType  'CSS_RULE' `
        -LineStart      $LineStart `
        -LineEnd        $LineEnd `
        -ColumnStart    $ColumnStart `
        -ReferenceType  'DEFINITION' `
        -Scope          $scope `
        -Signature      $Signature `
        -ParentFunction $ParentAtrule `
        -RawText        $RawText
    $script:rows.Add($row)
    return $row
}

# Emit a CSS_CLASS or CSS_VARIANT row for a single class token. Under the
# new spec model, each class token in a compound is its own row. When the
# compound carries a pseudo-class, the row is a CSS_VARIANT with
# variant_type=pseudo and the pseudo name in qualifier_2; otherwise it
# is a plain CSS_CLASS row. variant_qualifier_1 is never set under the
# new model - the old "class modifier" qualifier is gone.
function Add-CssClassRow {
    param(
        [Parameter(Mandatory)] [string]$ClassName,
        [string]$PseudoClass,          # bare pseudo name (e.g. 'hover') or $null
        [Parameter(Mandatory)] [string]$ReferenceType,
        [Parameter(Mandatory)] [int]$LineStart,
        [Parameter(Mandatory)] [int]$LineEnd,
        [Parameter(Mandatory)] [int]$ColumnStart,
        [string]$Signature,
        [string]$ParentAtrule,
        [string]$RawText,
        [string]$PurposeDescription,
        [int]$TokenIndex = 0           # ordinal position within the compound (for dedupe key uniqueness)
    )

    if ([string]::IsNullOrWhiteSpace($ClassName)) { return $null }

    $isVariant     = -not [string]::IsNullOrEmpty($PseudoClass)
    $componentType = if ($isVariant) { 'CSS_VARIANT' } else { 'CSS_CLASS' }
    $variantType   = if ($isVariant) { 'pseudo' } else { $null }
    $q2            = if ($isVariant) { $PseudoClass } else { $null }

    $scope = $null
    $sourceFile = $null
    if ($ReferenceType -eq 'DEFINITION') {
        $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }
        $sourceFile = $script:CurrentFile
    } else {
        $resolved = Resolve-ClassScope -ClassName $ClassName
        $scope = $resolved.Scope
        $sourceFile = $resolved.SourceFile
    }

    # Dedupe key includes TokenIndex so two classes in the same compound
    # (e.g. .foo.bar) at the same line / column / variant qualifier do
    # not collide.
    $q2Key = if ($q2) { $q2 } else { '' }
    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|$componentType|$ClassName|$ReferenceType|$TokenIndex|$q2Key"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $row = New-CssRow `
        -ComponentType      $componentType `
        -ComponentName      $ClassName `
        -VariantType        $variantType `
        -VariantQualifier2  $q2 `
        -ReferenceType      $ReferenceType `
        -Scope              $scope `
        -SourceFile         $sourceFile `
        -LineStart          $LineStart `
        -LineEnd            $LineEnd `
        -ColumnStart        $ColumnStart `
        -Signature          $Signature `
        -ParentFunction     $ParentAtrule `
        -RawText            $RawText `
        -PurposeDescription $PurposeDescription
    $script:rows.Add($row)
    return $row
}

function Add-HtmlIdRow {
    param(
        [string]$IdName,
        [string]$ReferenceType,
        [int]$LineStart, [int]$LineEnd, [int]$ColumnStart,
        [string]$Signature, [string]$ParentAtrule, [string]$RawText
    )
    if ([string]::IsNullOrWhiteSpace($IdName)) { return $null }

    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|HTML_ID|$IdName|$ReferenceType|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }
    $row = New-CssRow `
        -ComponentType  'HTML_ID' `
        -ComponentName  $IdName `
        -ReferenceType  $ReferenceType `
        -Scope          $scope `
        -LineStart      $LineStart `
        -LineEnd        $LineEnd `
        -ColumnStart    $ColumnStart `
        -Signature      $Signature `
        -ParentFunction $ParentAtrule `
        -RawText        $RawText
    $script:rows.Add($row)
    return $row
}

function Add-CssVariableRow {
    param(
        [string]$VarName, [string]$ReferenceType,
        [int]$LineStart, [int]$LineEnd, [int]$ColumnStart,
        [string]$Signature, [string]$ParentAtrule, [string]$RawText
    )
    if ([string]::IsNullOrWhiteSpace($VarName)) { return $null }

    $scope = $null; $sourceFile = $null
    if ($ReferenceType -eq 'DEFINITION') {
        $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }
        $sourceFile = $script:CurrentFile
    } else {
        $map = Get-ZoneSharedVariableMap
        if ($map.ContainsKey($VarName)) {
            $scope = 'SHARED'; $sourceFile = $map[$VarName]
        } else {
            $scope = 'LOCAL'; $sourceFile = $script:CurrentFile
        }
    }

    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|CSS_VARIABLE|$VarName|$ReferenceType|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $row = New-CssRow `
        -ComponentType  'CSS_VARIABLE' `
        -ComponentName  $VarName `
        -ReferenceType  $ReferenceType `
        -Scope          $scope `
        -SourceFile     $sourceFile `
        -LineStart      $LineStart `
        -LineEnd        $LineEnd `
        -ColumnStart    $ColumnStart `
        -Signature      $Signature `
        -ParentFunction $ParentAtrule `
        -RawText        $RawText
    $script:rows.Add($row)
    return $row
}

function Add-CssKeyframeRow {
    param(
        [string]$KeyframeName, [string]$ReferenceType,
        [int]$LineStart, [int]$LineEnd, [int]$ColumnStart,
        [string]$Signature, [string]$ParentAtrule, [string]$RawText
    )
    if ([string]::IsNullOrWhiteSpace($KeyframeName)) { return $null }

    $scope = $null; $sourceFile = $null
    if ($ReferenceType -eq 'DEFINITION') {
        $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }
        $sourceFile = $script:CurrentFile
    } else {
        $map = Get-ZoneSharedKeyframeMap
        if ($map.ContainsKey($KeyframeName)) {
            $scope = 'SHARED'; $sourceFile = $map[$KeyframeName]
        } else {
            $scope = 'LOCAL'; $sourceFile = $script:CurrentFile
        }
    }

    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|CSS_KEYFRAME|$KeyframeName|$ReferenceType|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $row = New-CssRow `
        -ComponentType  'CSS_KEYFRAME' `
        -ComponentName  $KeyframeName `
        -ReferenceType  $ReferenceType `
        -Scope          $scope `
        -SourceFile     $sourceFile `
        -LineStart      $LineStart `
        -LineEnd        $LineEnd `
        -ColumnStart    $ColumnStart `
        -Signature      $Signature `
        -ParentFunction $ParentAtrule `
        -RawText        $RawText
    $script:rows.Add($row)
    return $row
}

# Emit a COMMENT_BANNER row from a Section entry produced by New-SectionList.
# Banner-level drift codes from Get-BannerInfo come pre-populated on the
# section's BannerDriftCodes array. SECTION_TYPE_ORDER_VIOLATION,
# MALFORMED_PREFIX_VALUE, PREFIX_REGISTRY_MISMATCH, and
# ANCHOR_SECTION_INVALID_PREFIX are added here based on cross-section /
# cross-registry information.
function Add-CommentBannerRow {
    param([Parameter(Mandatory)] $Section, [Parameter(Mandatory)] [int] $PreviousSectionTypeOrderIdx)

    $b = $Section.BannerComment
    $rawSnippet = Format-SingleLine -Text $b.Text

    $key = "$($script:CurrentFile)|$($Section.BannerStartLine)|COMMENT_BANNER|$($Section.FullTitle)|DEFINITION|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $componentName = if ($Section.BannerName) { $Section.BannerName } else { $Section.FullTitle }
    $scope         = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }

    $row = New-CssRow `
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

    # Carry over per-banner drift accumulated by Get-BannerInfo / New-SectionList.
    foreach ($code in $Section.BannerDriftCodes) {
        Add-DriftCode -Row $row -Code $code
    }

    # SECTION_TYPE_ORDER_VIOLATION: this banner's type appears before the
    # previous banner's type in the canonical order.
    if ($Section.TypeName) {
        $newIdx = [array]::IndexOf($script:SectionTypeOrder, $Section.TypeName)
        if ($newIdx -ge 0 -and $PreviousSectionTypeOrderIdx -ge 0 -and $newIdx -lt $PreviousSectionTypeOrderIdx) {
            Add-DriftCode -Row $row -Code 'SECTION_TYPE_ORDER_VIOLATION'
        }
    }

    # MALFORMED_PREFIX_VALUE: Prefix line declares something that is neither
    # a page prefix nor 'cc', or declares multiple comma-separated values.
    # CSS callers do NOT pass -AllowNoneSentinel, so the (none) sentinel is
    # invalid here per the new spec.
    if ($Section.Prefix -and -not (Test-PrefixValueIsValid -Prefix $Section.Prefix)) {
        Add-DriftCode -Row $row -Code 'MALFORMED_PREFIX_VALUE' `
            -Context "Banner declares Prefix '$($Section.Prefix)' which is neither a page prefix nor 'cc'."
    }

    # Prefix registry validation (CC_CSS_Spec.md Section 5.2).
    # Two distinct failure modes, two distinct drift codes:
    #   ANCHOR_SECTION_INVALID_PREFIX -- section is FOUNDATION/CHROME/
    #     anchor-file FEEDBACK_OVERLAYS but the banner declares a value
    #     other than 'cc'. Applies in anchor files; non-anchor files
    #     carrying FOUNDATION or CHROME already fire DUPLICATE_FOUNDATION
    #     or DUPLICATE_CHROME from Pass 3 and don't double-fire here.
    #   PREFIX_REGISTRY_MISMATCH -- page-file banner declares something
    #     other than the file's registered cc_prefix.
    #
    # Skip both checks if the banner's prefix value is malformed (that's
    # already flagged), if there's no Prefix line at all (already flagged
    # as MISSING_PREFIX_DECLARATION), or if the file has no Component_Registry
    # mapping (no source of truth to compare against; the missing registration
    # surfaces in the miss advisory).
    if ($Section.Prefix -and (Test-PrefixValueIsValid -Prefix $Section.Prefix)) {
        $bannerVal = Get-BannerPrefixValue -Prefix $Section.Prefix
        $isCc      = ($bannerVal -eq 'cc')

        # ANCHOR_SECTION_INVALID_PREFIX: anchor-file-only section type must
        # declare 'cc' in an anchor file. Checked first because it depends
        # only on section type and file identity, not the registry.
        if ($script:CurrentFileIsAnchor -and ($Section.TypeName -in $AnchorSectionTypes)) {
            if (-not $isCc) {
                Add-DriftCode -Row $row -Code 'ANCHOR_SECTION_INVALID_PREFIX' `
                    -Context "Section type '$($Section.TypeName)' in anchor file must declare Prefix 'cc'; banner declares '$bannerVal'."
            }
        }
        elseif ($script:CurrentRegistryHasMapping) {
            # Page-file banner. Must declare the registered page prefix.
            $regVal = $script:CurrentRegistryPrefix
            if (-not [string]::IsNullOrEmpty($regVal)) {
                if ($bannerVal -ne $regVal) {
                    Add-DriftCode -Row $row -Code 'PREFIX_REGISTRY_MISMATCH' `
                        -Context "Page-file banner declares Prefix '$bannerVal' but Component_Registry.cc_prefix for this file is '$regVal'."
                }
            }
            # If regVal is null but the file is not the anchor, this is a
            # registry data gap, not a file drift. The missing registration
            # surfaces in the miss advisory; we cannot validate the file's
            # banner without a source of truth.
        }
    }

    return $row
}

# ============================================================================
# PER-SELECTOR ROW GENERATION
# ============================================================================

# Decompose a selector into compounds (classes / ids / pseudos), then emit
# one or more catalog rows. Under the new spec each class token in every
# compound is a class in its own right and emits its own row. When the
# compound carries a pseudo-class, every class row in that compound becomes
# a CSS_VARIANT (variant_type=pseudo). Forbidden constructs attach the
# appropriate drift codes to each emitted row.
function Add-RowsForSelector {
    param(
        [Parameter(Mandatory)] $SelectorNode,
        [Parameter(Mandatory)] [string] $RuleSelectorText,
        [Parameter(Mandatory)] [int]    $LineStart,
        [Parameter(Mandatory)] [int]    $LineEnd,
        [Parameter(Mandatory)] [int]    $ColumnStart,
        [string] $ParentAtrule = $null,
        [string] $RuleBodyText = $null,
        [bool]   $HasPrecedingComment = $false,
        [bool]   $HasTrailingInlineComment = $false,
        [string] $PrecedingCommentText = $null,
        [string] $TrailingInlineCommentText = $null,
        [bool]   $IsPartOfGroup = $false
    )

    $compounds = Get-CompoundList -SelectorChildren $SelectorNode.nodes
    if ([string]::IsNullOrEmpty($RuleBodyText)) { $RuleBodyText = $RuleSelectorText }

    # Locate the primary compound (first one with a class or id).
    $primaryIdx = -1
    for ($i = 0; $i -lt $compounds.Count; $i++) {
        if ($compounds[$i].Classes.Count -gt 0 -or $compounds[$i].Ids.Count -gt 0) {
            $primaryIdx = $i; break
        }
    }
    $hasMultipleCompounds = ($compounds.Count -gt 1)

    # Look up the active section once per selector.
    $activeSection = Get-SectionForLine -Sections $script:CurrentSections -Line $LineStart
    $inFoundation  = ($activeSection -and $activeSection.TypeName -eq 'FOUNDATION')

    # ---- Selector with no class and no id (element / universal / attribute / pseudo-element only) ----
    if ($primaryIdx -lt 0) {
        $row = Add-CssRuleRow -LineStart $LineStart -LineEnd $LineEnd `
            -ColumnStart $ColumnStart -Signature $RuleSelectorText `
            -ParentAtrule $ParentAtrule -RawText $RuleBodyText
        if ($row) {
            $hasUniversal     = @($compounds | Where-Object { $_.HasUniversal }).Count -gt 0
            $hasAttr          = @($compounds | Where-Object { $_.AttrCount -gt 0 }).Count -gt 0
            $hasTag           = @($compounds | Where-Object { $_.HasTag }).Count -gt 0
            $hasPseudoElement = @($compounds | Where-Object { $_.PseudoElements.Count -gt 0 }).Count -gt 0

            if ($hasUniversal -and -not $inFoundation) { Add-DriftCode -Row $row -Code 'FORBIDDEN_UNIVERSAL_SELECTOR' }
            if ($hasAttr      -and -not $inFoundation) { Add-DriftCode -Row $row -Code 'FORBIDDEN_ATTRIBUTE_SELECTOR' }
            if ($hasTag       -and -not $inFoundation -and -not $hasUniversal -and -not $hasAttr) {
                Add-DriftCode -Row $row -Code 'FORBIDDEN_ELEMENT_SELECTOR'
            }
            if ($hasPseudoElement -and -not $inFoundation) {
                Add-DriftCode -Row $row -Code 'FORBIDDEN_PSEUDO_ELEMENT_LOCATION'
            }
            if ($IsPartOfGroup)        { Add-DriftCode -Row $row -Code 'FORBIDDEN_GROUP_SELECTOR' }
            if ($hasMultipleCompounds) {
                switch ($compounds[1].CombinatorBefore) {
                    '>' { Add-DriftCode -Row $row -Code 'FORBIDDEN_CHILD_COMBINATOR' }
                    '+' { Add-DriftCode -Row $row -Code 'FORBIDDEN_ADJACENT_SIBLING' }
                    '~' { Add-DriftCode -Row $row -Code 'FORBIDDEN_GENERAL_SIBLING' }
                    default { Add-DriftCode -Row $row -Code 'FORBIDDEN_DESCENDANT' }
                }
            }
            if (-not $activeSection)   { Add-DriftCode -Row $row -Code 'MISSING_SECTION_BANNER' }
        }
        return
    }

    $primary = $compounds[$primaryIdx]

    # Classify the rule:
    #   - A single-token rule (one class OR one id in the primary compound,
    #     optionally with a pseudo-class) is a definition per spec sections
    #     6.1 / 7.1. A single class is CSS_CLASS DEFINITION; a single class
    #     plus pseudo-class is CSS_VARIANT DEFINITION; a single id is
    #     HTML_ID DEFINITION (forbidden in CSS, but a definitional shape).
    #   - A compound rule (two or more tokens of any kind: class+class,
    #     class+id, id+id) is NOT a definition of any participating token.
    #     Each participating token is a class/id in its own right and must
    #     be defined by a separate standalone rule somewhere. The compound
    #     rule USES those tokens together to apply combined styling;
    #     the emitted rows are USAGE.
    # "Token" here means a real selector token (class or id). Pseudo-classes
    # and pseudo-elements aren't tokens for this count - they're qualifiers
    # on a token.
    $primaryTokenCount     = $primary.Classes.Count + $primary.Ids.Count
    $primaryIsCompound     = ($primaryTokenCount -ge 2)
    $primaryHasPseudoClass = ($primary.Pseudos.Count -gt 0)

    # variant_type / variant_qualifier_2 are set when the primary compound
    # carries a pseudo-class (whether the rule is a definition or a usage).
    # Stacked pseudos are joined with ':' for the qualifier; the drift code
    # FORBIDDEN_STACKED_PSEUDO is emitted separately when count >= 2.
    $primaryPseudo = if ($primaryHasPseudoClass) { ($primary.Pseudos -join ':') } else { $null }

    # Reference type for primary-compound rows: DEFINITION for single-class
    # rules (base or variant), USAGE for class-on-class compounds.
    $primaryReferenceType = if ($primaryIsCompound) { 'USAGE' } else { 'DEFINITION' }

    # Comment expectations apply only to definition rules:
    #   - Base definition (single-class, no pseudo)     -> preceding purpose comment
    #   - Variant definition (single-class, pseudo)     -> trailing inline comment
    #   - Compound (class-on-class) USAGE               -> no comment expectation
    # Per spec, purpose comments are required for base class definitions
    # (section 6.1) and trailing comments are required for variants
    # (section 7.1). Compound rules are neither, so no comment-presence
    # drift fires on their rows. The "missing standalone definition"
    # signal is surfaced separately by UNDEFINED_CLASS_USAGE in Pass 3.
    $purposeDesc      = $null
    $commentDriftCode = $null
    $hasComment       = $true
    if (-not $primaryIsCompound) {
        if ($primaryHasPseudoClass) {
            $purposeDesc      = $TrailingInlineCommentText
            $commentDriftCode = 'MISSING_VARIANT_COMMENT'
            $hasComment       = $HasTrailingInlineComment
        } else {
            $purposeDesc      = $PrecedingCommentText
            $commentDriftCode = 'MISSING_PURPOSE_COMMENT'
            $hasComment       = $HasPrecedingComment
        }
    }

    # ---- PRIMARY: emit one row per class token ----
    for ($ci = 0; $ci -lt $primary.Classes.Count; $ci++) {
        $className = $primary.Classes[$ci]

        $row = Add-CssClassRow `
            -ClassName          $className `
            -PseudoClass        $primaryPseudo `
            -ReferenceType      $primaryReferenceType `
            -LineStart          $LineStart `
            -LineEnd            $LineEnd `
            -ColumnStart        $ColumnStart `
            -Signature          $RuleSelectorText `
            -ParentAtrule       $ParentAtrule `
            -RawText            $RuleBodyText `
            -PurposeDescription $purposeDesc `
            -TokenIndex         $ci
        if (-not $row) { continue }

        # Per-class drift: prefix check against the section's declared prefix.
        # Applies to every class token in every compound regardless of
        # reference type. A class participating in a rule must satisfy the
        # section's prefix discipline whether the rule defines it or uses it.
        if ($activeSection -and $activeSection.PrefixValue) {
            $pfx = $activeSection.PrefixValue
            $matched = ($className -ceq $pfx) -or
                       ($className.StartsWith("$pfx-", [System.StringComparison]::Ordinal))
            if (-not $matched) {
                Add-DriftCode -Row $row -Code 'PREFIX_MISMATCH' `
                    -Context "Class token '$className' does not begin with the section prefix '$pfx-'."
            }
        }

        # Per-class drift: comment-presence (definition rules only).
        # Compound USAGE rows do not carry comment-presence drift; the spec
        # requires comments on definitions, not on usages.
        if (-not $primaryIsCompound -and -not $hasComment) {
            Add-DriftCode -Row $row -Code $commentDriftCode
        }

        # Compound-shape drift (applied identically to every class row in
        # the primary compound). These reflect properties of the rule's
        # selector shape and apply whether the rule is a definition or a
        # usage.
        if ($primary.Classes.Count -ge 3)    { Add-DriftCode -Row $row -Code 'COMPOUND_DEPTH_3PLUS' }
        if ($primary.PseudoInterleaved)      { Add-DriftCode -Row $row -Code 'PSEUDO_INTERLEAVED' }
        if ($primary.Pseudos.Count -ge 2)    { Add-DriftCode -Row $row -Code 'FORBIDDEN_STACKED_PSEUDO' }
        if ($primary.Pseudos -contains 'not'){ Add-DriftCode -Row $row -Code 'FORBIDDEN_NOT_PSEUDO' }
        if ($primary.Ids.Count -gt 0)        { Add-DriftCode -Row $row -Code 'FORBIDDEN_ID_SELECTOR' }
        if ($primary.AttrCount -gt 0 -and -not $inFoundation) {
            Add-DriftCode -Row $row -Code 'FORBIDDEN_ATTRIBUTE_SELECTOR'
        }
        if ($primary.HasTag -and -not $inFoundation) {
            Add-DriftCode -Row $row -Code 'FORBIDDEN_ELEMENT_SELECTOR'
        }
        # Pseudo-element rules attached to a class are base class definitions
        # per spec section 6.1, so no FORBIDDEN_PSEUDO_ELEMENT_LOCATION fires
        # here. That code only applies to unattached pseudo-elements (handled
        # in the primary-less branch above).

        # Selector-shape drift that comes from group / descendant context.
        if ($IsPartOfGroup) { Add-DriftCode -Row $row -Code 'FORBIDDEN_GROUP_SELECTOR' }
        if ($hasMultipleCompounds) {
            switch ($compounds[$primaryIdx + 1].CombinatorBefore) {
                '>' { Add-DriftCode -Row $row -Code 'FORBIDDEN_CHILD_COMBINATOR' }
                '+' { Add-DriftCode -Row $row -Code 'FORBIDDEN_ADJACENT_SIBLING' }
                '~' { Add-DriftCode -Row $row -Code 'FORBIDDEN_GENERAL_SIBLING' }
                default { Add-DriftCode -Row $row -Code 'FORBIDDEN_DESCENDANT' }
            }
        }

        # Section context drift.
        if (-not $activeSection) {
            Add-DriftCode -Row $row -Code 'MISSING_SECTION_BANNER'
        }
    }

    # ---- PRIMARY: id side (each id emits a single HTML_ID row) ----
    # IDs in compounds inherit the primary reference type: single-token ID
    # rules are HTML_ID DEFINITION; ID participating in a compound (e.g.
    # `#foo.bar`) is HTML_ID USAGE under the same logic that makes the
    # class side USAGE - the compound isn't a definition of either token.
    if ($primary.Ids.Count -gt 0) {
        foreach ($idName in $primary.Ids) {
            $idRow = Add-HtmlIdRow -IdName $idName -ReferenceType $primaryReferenceType `
                -LineStart $LineStart -LineEnd $LineEnd -ColumnStart $ColumnStart `
                -Signature $RuleSelectorText -ParentAtrule $ParentAtrule -RawText $RuleBodyText
            if ($idRow) {
                Add-DriftCode -Row $idRow -Code 'FORBIDDEN_ID_SELECTOR'
                if ($IsPartOfGroup)        { Add-DriftCode -Row $idRow -Code 'FORBIDDEN_GROUP_SELECTOR' }
                if ($hasMultipleCompounds) {
                    switch ($compounds[$primaryIdx + 1].CombinatorBefore) {
                        '>' { Add-DriftCode -Row $idRow -Code 'FORBIDDEN_CHILD_COMBINATOR' }
                        '+' { Add-DriftCode -Row $idRow -Code 'FORBIDDEN_ADJACENT_SIBLING' }
                        '~' { Add-DriftCode -Row $idRow -Code 'FORBIDDEN_GENERAL_SIBLING' }
                        default { Add-DriftCode -Row $idRow -Code 'FORBIDDEN_DESCENDANT' }
                    }
                }
                if (-not $activeSection) { Add-DriftCode -Row $idRow -Code 'MISSING_SECTION_BANNER' }
            }
        }
    }

    # ---- DESCENDANT compounds: one USAGE row per class token, plus id-side ----
    for ($i = $primaryIdx + 1; $i -lt $compounds.Count; $i++) {
        $cmp = $compounds[$i]

        # A descendant compound with a pseudo-class makes its class tokens
        # CSS_VARIANT rows (variant_type=pseudo). No pseudo -> plain CSS_CLASS
        # USAGE rows.
        $descPseudo = if ($cmp.Pseudos.Count -gt 0) { ($cmp.Pseudos -join ':') } else { $null }

        for ($ci = 0; $ci -lt $cmp.Classes.Count; $ci++) {
            $className = $cmp.Classes[$ci]

            $row = Add-CssClassRow `
                -ClassName          $className `
                -PseudoClass        $descPseudo `
                -ReferenceType      'USAGE' `
                -LineStart          $LineStart `
                -LineEnd            $LineEnd `
                -ColumnStart        $ColumnStart `
                -Signature          $RuleSelectorText `
                -ParentAtrule       $ParentAtrule `
                -RawText            $RuleBodyText `
                -TokenIndex         ($i * 100 + $ci)
            if (-not $row) { continue }

            # Combinator-driven drift on the descendant.
            switch ($cmp.CombinatorBefore) {
                '>' { Add-DriftCode -Row $row -Code 'FORBIDDEN_CHILD_COMBINATOR' }
                '+' { Add-DriftCode -Row $row -Code 'FORBIDDEN_ADJACENT_SIBLING' }
                '~' { Add-DriftCode -Row $row -Code 'FORBIDDEN_GENERAL_SIBLING' }
                default { Add-DriftCode -Row $row -Code 'FORBIDDEN_DESCENDANT' }
            }

            # Compound-shape drift inside the descendant compound.
            if ($cmp.Classes.Count -ge 3)    { Add-DriftCode -Row $row -Code 'COMPOUND_DEPTH_3PLUS' }
            if ($cmp.PseudoInterleaved)      { Add-DriftCode -Row $row -Code 'PSEUDO_INTERLEAVED' }
            if ($cmp.Pseudos.Count -ge 2)    { Add-DriftCode -Row $row -Code 'FORBIDDEN_STACKED_PSEUDO' }
            if ($cmp.Pseudos -contains 'not'){ Add-DriftCode -Row $row -Code 'FORBIDDEN_NOT_PSEUDO' }
            if ($cmp.AttrCount -gt 0 -and -not $inFoundation) {
                Add-DriftCode -Row $row -Code 'FORBIDDEN_ATTRIBUTE_SELECTOR'
            }
            if ($cmp.HasTag -and -not $inFoundation) {
                Add-DriftCode -Row $row -Code 'FORBIDDEN_ELEMENT_SELECTOR'
            }
            if ($IsPartOfGroup) { Add-DriftCode -Row $row -Code 'FORBIDDEN_GROUP_SELECTOR' }
        }

        if ($cmp.Ids.Count -gt 0) {
            foreach ($idName in $cmp.Ids) {
                $idRow = Add-HtmlIdRow -IdName $idName -ReferenceType 'USAGE' `
                    -LineStart $LineStart -LineEnd $LineEnd -ColumnStart $ColumnStart `
                    -Signature $RuleSelectorText -ParentAtrule $ParentAtrule -RawText $RuleBodyText
                if ($idRow) {
                    Add-DriftCode -Row $idRow -Code 'FORBIDDEN_ID_SELECTOR'
                    switch ($cmp.CombinatorBefore) {
                        '>' { Add-DriftCode -Row $idRow -Code 'FORBIDDEN_CHILD_COMBINATOR' }
                        '+' { Add-DriftCode -Row $idRow -Code 'FORBIDDEN_ADJACENT_SIBLING' }
                        '~' { Add-DriftCode -Row $idRow -Code 'FORBIDDEN_GENERAL_SIBLING' }
                        default { Add-DriftCode -Row $idRow -Code 'FORBIDDEN_DESCENDANT' }
                    }
                    if ($IsPartOfGroup) { Add-DriftCode -Row $idRow -Code 'FORBIDDEN_GROUP_SELECTOR' }
                }
            }
        }
    }
}

# ============================================================================
# CSS VISITOR (consumed by Invoke-AstWalk)
# ============================================================================

# The visitor receives ($Node, $ParentChain, $ParentNodes) from the helpers'
# generic walker and dispatches by Node.type. Returning 'SKIP_CHILDREN' stops
# the walker from recursing into the current node's children; we use that for
# 'rule' nodes (which we process exhaustively here, including the body decls)
# and for 'comment' nodes (PostCSS comments are leaves).
$CssVisitor = {
    param($Node, $ParentChain, $ParentNodes)

    if ($null -eq $Node)     { return }
    if ($null -eq $Node.type) { return }

    # Determine the immediate parent atrule label for context (e.g. '@media (...)').
    $parentAtrule = $null
    if ($ParentNodes -and $ParentNodes.Count -gt 0) {
        for ($pi = $ParentNodes.Count - 1; $pi -ge 0; $pi--) {
            $pn = $ParentNodes[$pi]
            if ($pn.type -eq 'atrule') {
                $label = "@$($pn.name)"
                if ($pn.params) { $label = "$label $($pn.params)" }
                $parentAtrule = $label.Trim()
                break
            }
        }
    }

    switch ($Node.type) {

        'comment' {
            # COMMENT_BANNER rows are emitted from the section list at file
            # start, not here. Each non-banner comment is a leaf for the walker;
            # we have nothing more to do.
            return 'SKIP_CHILDREN'
        }

        'rule' {
            $line    = if ($Node.source -and $Node.source.start) { [int]$Node.source.start.line } else { 1 }
            $endLine = if ($Node.source -and $Node.source.end)   { [int]$Node.source.end.line   } else { $line }
            $col     = if ($Node.source -and $Node.source.start -and ($Node.source.start.PSObject.Properties.Name -contains 'column')) {
                           [int]$Node.source.start.column
                       } else { 1 }

            # Find the comment immediately preceding this rule (if any) in the
            # normalized comment list, by line position. A "preceding comment"
            # is one whose LineEnd is exactly $line - 1 and which is NOT a banner.
            $hasPrecedingComment = $false
            $precedingCommentText = $null
            foreach ($c in $script:CurrentNormalizedComments) {
                if ($c.LineEnd -eq ($line - 1)) {
                    if (-not (Test-IsBannerComment -CommentText $c.Text -ValidSectionTypes $script:ValidSectionTypes)) {
                        $hasPrecedingComment   = $true
                        $precedingCommentText  = ConvertTo-CleanCommentText -CommentText $c.Text
                        [void]$script:CurrentUsedCommentLines.Add([int]$c.LineStart)
                    }
                    break
                }
            }

            # Detect trailing inline comment (PostCSS represents it as the
            # first child node of the rule, with the same source line as the
            # rule's selector).
            $hasTrailingInlineComment = $false
            $trailingInlineCommentText = $null
            if ($Node.nodes -and $Node.nodes.Count -gt 0) {
                $firstChild = $Node.nodes[0]
                if ($firstChild.type -eq 'comment' -and $firstChild.source -and $firstChild.source.start) {
                    if ([int]$firstChild.source.start.line -eq $line) {
                        $hasTrailingInlineComment = $true
                        $trailingInlineCommentText = ConvertTo-CleanCommentText -CommentText $firstChild.text
                        [void]$script:CurrentUsedCommentLines.Add([int]$firstChild.source.start.line)
                    }
                }
            }

            # Comma-grouped selectors -> flag every constituent
            $isGroup = ($Node.selectors -and @($Node.selectors).Count -gt 1)

            # Build the full rule body once per rule, then thread it through.
            $ruleBodyText = Format-RuleBody -RuleNode $Node -SelectorText $Node.selector

            # Capture the row index before selector emission so we can
            # iterate just this rule's rows when applying rule-scoped drift
            # codes (FORBIDDEN_COMPOUND_DECLARATION, BLANK_LINE_INSIDE_RULE)
            # below. This avoids scanning all of $script:rows per rule.
            $ruleRowsStartIdx = $script:rows.Count

            if ($Node.selectorTree -and $Node.selectorTree.nodes) {
                foreach ($sel in $Node.selectorTree.nodes) {
                    if ($sel.type -ne 'selector') { continue }
                    Add-RowsForSelector -SelectorNode $sel -RuleSelectorText $Node.selector `
                        -LineStart $line -LineEnd $endLine -ColumnStart $col `
                        -ParentAtrule $parentAtrule `
                        -RuleBodyText $ruleBodyText `
                        -HasPrecedingComment $hasPrecedingComment `
                        -HasTrailingInlineComment $hasTrailingInlineComment `
                        -PrecedingCommentText $precedingCommentText `
                        -TrailingInlineCommentText $trailingInlineCommentText `
                        -IsPartOfGroup $isGroup
                }
            }

            # Process the rule's declarations (variables, var() refs, animation
            # keyframe refs, hex/px literal tracking, blank-line / compound-
            # declaration drift). We handle decls here rather than letting the
            # walker recurse, so we can apply rule-scoped checks like
            # BLANK_LINE_INSIDE_RULE.
            $declLines = New-Object System.Collections.Generic.List[int]
            $declSpans = New-Object System.Collections.Generic.List[object]
            if ($Node.nodes) {
                foreach ($child in $Node.nodes) {
                    if ($child.type -eq 'decl') {
                        $dLine = if ($child.source -and $child.source.start) { [int]$child.source.start.line } else { 1 }
                        $dEnd  = if ($child.source -and $child.source.end)   { [int]$child.source.end.line   } else { $dLine }
                        $dCol  = if ($child.source -and $child.source.start -and ($child.source.start.PSObject.Properties.Name -contains 'column')) {
                                     [int]$child.source.start.column
                                 } else { 1 }
                        $declLines.Add($dLine)
                        $declSpans.Add(@{ Start = $dLine; End = $dEnd })

                        # CSS_VARIABLE DEFINITION
                        if ($child.prop -and $child.prop.StartsWith('--')) {
                            $varName = $child.prop.Substring(2)
                            $varRow = Add-CssVariableRow -VarName $varName -ReferenceType 'DEFINITION' `
                                -LineStart $dLine -LineEnd $dLine -ColumnStart $dCol `
                                -Signature $child.value -ParentAtrule $parentAtrule `
                                -RawText "$($child.prop): $($child.value)"
                            if ($varRow) {
                                $sec = Get-SectionForLine -Sections $script:CurrentSections -Line $dLine
                                if ((-not $sec) -or ($sec.TypeName -ne 'FOUNDATION')) {
                                    Add-DriftCode -Row $varRow -Code 'FORBIDDEN_CUSTOM_PROPERTY_LOCATION'
                                }
                            }
                        }

                        # CSS_VARIABLE USAGE
                        $vars = Get-VarReferences -Value $child.value
                        foreach ($v in $vars) {
                            [void](Add-CssVariableRow -VarName $v -ReferenceType 'USAGE' `
                                -LineStart $dLine -LineEnd $dLine -ColumnStart $dCol `
                                -Signature "var(--$v)" -ParentAtrule $parentAtrule `
                                -RawText "$($child.prop): $($child.value)")
                        }

                        # CSS_KEYFRAME USAGE - resolve against consumer's zone
                        if ($child.prop -in @('animation','animation-name')) {
                            $kfMap = Get-ZoneSharedKeyframeMap
                            foreach ($tok in ($child.value -split '\s+|,')) {
                                $t = $tok.Trim()
                                if ($t -and $kfMap.ContainsKey($t)) {
                                    [void](Add-CssKeyframeRow -KeyframeName $t -ReferenceType 'USAGE' `
                                        -LineStart $dLine -LineEnd $dLine -ColumnStart $dCol `
                                        -Signature "$($child.prop): $($child.value)" -ParentAtrule $parentAtrule `
                                        -RawText "$($child.prop): $($child.value)")
                                }
                            }
                        }

                        # Hex literal tracking (Pass 3 attaches DRIFT_HEX_LITERAL)
                        $hexLiterals = Get-HexLiterals -Value $child.value
                        if ($hexLiterals.Count -gt 0) {
                            if (-not $script:fileMeta[$script:CurrentFile].HexLiterals) {
                                $script:fileMeta[$script:CurrentFile].HexLiterals = New-Object System.Collections.Generic.List[object]
                            }
                            foreach ($hex in $hexLiterals) {
                                $script:fileMeta[$script:CurrentFile].HexLiterals.Add(@{
                                    Hex = $hex; Line = $dLine; Column = $dCol
                                    Property = $child.prop; Value = $child.value
                                })
                            }
                        }

                        # Px literal tracking (Pass 3 attaches DRIFT_PX_LITERAL)
                        $pxLiterals = Get-PxLiterals -Value $child.value
                        if ($pxLiterals.Count -gt 0) {
                            if (-not $script:fileMeta[$script:CurrentFile].PxLiterals) {
                                $script:fileMeta[$script:CurrentFile].PxLiterals = New-Object System.Collections.Generic.List[object]
                            }
                            foreach ($px in $pxLiterals) {
                                $script:fileMeta[$script:CurrentFile].PxLiterals.Add(@{
                                    Px = $px; Line = $dLine; Column = $dCol
                                    Property = $child.prop; Value = $child.value
                                })
                            }
                        }
                    }
                }
            }

            # FORBIDDEN_COMPOUND_DECLARATION: two declarations on the same line.
            $declLineCounts = @{}
            foreach ($dl in $declLines) {
                if (-not $declLineCounts.ContainsKey($dl)) { $declLineCounts[$dl] = 0 }
                $declLineCounts[$dl]++
            }
            $hasCompoundDecl = @($declLineCounts.Values | Where-Object { $_ -gt 1 }).Count -gt 0
            if ($hasCompoundDecl) {
                for ($ri = $ruleRowsStartIdx; $ri -lt $script:rows.Count; $ri++) {
                    $r = $script:rows[$ri]
                    if ($r.ComponentType -in @('CSS_CLASS','CSS_VARIANT','CSS_RULE','HTML_ID')) {
                        Add-DriftCode -Row $r -Code 'FORBIDDEN_COMPOUND_DECLARATION'
                    }
                }
            }

            # BLANK_LINE_INSIDE_RULE: a blank line appears inside the rule body.
            $hasBlankInside = $false
            if ($declSpans.Count -gt 0) {
                $sortedSpans = @($declSpans | Sort-Object { $_.Start })

                if ($sortedSpans[0].Start -gt ($line + 1)) {
                    $hasBlankInside = $true
                }
                for ($si = 1; $si -lt $sortedSpans.Count; $si++) {
                    $prevEnd = $sortedSpans[$si - 1].End
                    $curStart = $sortedSpans[$si].Start
                    if ($curStart - $prevEnd -gt 1) {
                        $hasBlankInside = $true
                        break
                    }
                }
                if (-not $hasBlankInside) {
                    $lastEnd = $sortedSpans[$sortedSpans.Count - 1].End
                    if ($endLine - $lastEnd -gt 1) {
                        $hasBlankInside = $true
                    }
                }
            }
            # :root carve-out (CC_CSS_Spec.md Section 10.2): the platform's token
            # catalog is permitted to use blank lines as visual separators
            # between token groups. No other rule body has this exemption.
            $isRootRule = ($Node.selector -and $Node.selector.Trim() -eq ':root')
            if ($hasBlankInside -and -not $isRootRule) {
                for ($ri = $ruleRowsStartIdx; $ri -lt $script:rows.Count; $ri++) {
                    $r = $script:rows[$ri]
                    if ($r.ComponentType -in @('CSS_CLASS','CSS_VARIANT','CSS_RULE','HTML_ID')) {
                        Add-DriftCode -Row $r -Code 'BLANK_LINE_INSIDE_RULE'
                    }
                }
            }

            return 'SKIP_CHILDREN'
        }

        'atrule' {
            $line    = if ($Node.source -and $Node.source.start) { [int]$Node.source.start.line } else { 1 }
            $endLine = if ($Node.source -and $Node.source.end)   { [int]$Node.source.end.line   } else { $line }
            $col     = if ($Node.source -and $Node.source.start -and ($Node.source.start.PSObject.Properties.Name -contains 'column')) {
                           [int]$Node.source.start.column
                       } else { 1 }

            # @keyframes definition
            if ($Node.name -eq 'keyframes') {
                $kfName = if ($Node.params) { $Node.params.Trim() } else { '' }
                $kfRow = Add-CssKeyframeRow -KeyframeName $kfName -ReferenceType 'DEFINITION' `
                    -LineStart $line -LineEnd $endLine -ColumnStart $col `
                    -Signature "@keyframes $kfName" -ParentAtrule $parentAtrule `
                    -RawText "@keyframes $kfName"
                if ($kfRow) {
                    $sec = Get-SectionForLine -Sections $script:CurrentSections -Line $line
                    if ((-not $sec) -or ($sec.TypeName -ne 'FOUNDATION')) {
                        Add-DriftCode -Row $kfRow -Code 'FORBIDDEN_KEYFRAMES_LOCATION'
                    }
                }
                return 'SKIP_CHILDREN'
            }

            # Forbidden at-rules
            if ($Node.name -in @('import','font-face','supports')) {
                $atruleLabel = "@$($Node.name)"
                if ($Node.params) { $atruleLabel = "$atruleLabel $($Node.params)" }
                $atruleLabel = $atruleLabel.Trim()

                $atRow = Add-CssRuleRow -LineStart $line -LineEnd $endLine `
                    -ColumnStart $col -Signature $atruleLabel -ParentAtrule $parentAtrule `
                    -RawText $atruleLabel
                if ($atRow) {
                    switch ($Node.name) {
                        'import'    { Add-DriftCode -Row $atRow -Code 'FORBIDDEN_AT_IMPORT' }
                        'font-face' { Add-DriftCode -Row $atRow -Code 'FORBIDDEN_AT_FONT_FACE' }
                        'supports'  { Add-DriftCode -Row $atRow -Code 'FORBIDDEN_AT_SUPPORTS' }
                    }
                }
                return 'SKIP_CHILDREN'
            }

            # Other at-rules (notably @media): let the walker recurse so child
            # rules are processed in the at-rule's context. The rule handler
            # above looks up parent atrule via $ParentNodes.
            return
        }

        default {
            return
        }
    }
}

# ============================================================================
# PASS 2 - PER-FILE WALK
# ============================================================================

Write-Log "Pass 2: generating Asset_Registry rows..."

foreach ($file in $CssFiles) {
    $name = [System.IO.Path]::GetFileName($file)
    $isShared = $SharedFiles -contains $name
    $zone = Get-CssZone -FullPath $file

    if (-not $astCache.ContainsKey($file)) {
        Write-Log "  Skipping (no parsed AST): $name" 'WARN'
        continue
    }

    $ast = $astCache[$file].ast

    # Set per-file context
    $script:CurrentFile               = $name
    $script:CurrentFileIsShared       = $isShared
    $script:CurrentFileZone           = $zone
    $script:CurrentFileLineCount      = if ($astCache[$file].sourceLength) { [int]$astCache[$file].sourceLength } else { 0 }
    $script:CurrentRegistryHasMapping = $componentPrefixMap.ContainsKey($name)
    $script:CurrentRegistryPrefix     = if ($script:CurrentRegistryHasMapping) { $componentPrefixMap[$name] } else { $null }
    $script:CurrentFileIsAnchor       = ($name -eq $CcAnchorCssFile -or $name -eq $DocsAnchorCssFile)
    $script:CurrentUsedCommentLines   = New-Object 'System.Collections.Generic.HashSet[int]'

    $script:fileMeta[$name] = @{
        FoundationLine = $null
        ChromeLine     = $null
        FileOrgList    = $null
        Sections       = $null
        HexLiterals    = $null
        PxLiterals     = $null
    }

    # Collect comments in the normalized shape, then build the section list.
    $script:CurrentNormalizedComments = Convert-PostCssCommentsToNormalized -AstRoot $ast

    # Compute file line count from AST end position (more reliable than
    # source-length-as-bytes). Use the maximum end-line across all top-level
    # nodes as a proxy. If unavailable, fall back to a large number so the
    # last section's body range extends to end-of-file.
    $maxLine = 0
    if ($ast.nodes) {
        foreach ($n in $ast.nodes) {
            if ($n.source -and $n.source.end -and $n.source.end.line -gt $maxLine) {
                $maxLine = [int]$n.source.end.line
            }
        }
    }
    if ($maxLine -le 0) { $maxLine = 99999 }
    $script:CurrentFileLineCount = $maxLine

    $script:CurrentSections = New-SectionList `
        -Comments         $script:CurrentNormalizedComments `
        -FileLineCount    $script:CurrentFileLineCount `
        -ValidSectionTypes $script:ValidSectionTypes
    $script:fileMeta[$name].Sections = $script:CurrentSections

    # Track FOUNDATION / CHROME presence for Pass 3 cross-file dup checks.
    foreach ($s in $script:CurrentSections) {
        if ($s.TypeName -eq 'FOUNDATION' -and -not $script:fileMeta[$name].FoundationLine) {
            $script:fileMeta[$name].FoundationLine = $s.BannerStartLine
        }
        if ($s.TypeName -eq 'CHROME' -and -not $script:fileMeta[$name].ChromeLine) {
            $script:fileMeta[$name].ChromeLine = $s.BannerStartLine
        }
    }

    $startCount = $script:rows.Count
    $scopeLabel = if ($isShared) { 'SHARED' } else { 'LOCAL' }
    Write-Host ("  Walking {0} ({1}, zone={2})..." -f $name, $scopeLabel, $zone) -ForegroundColor Cyan

    # ---- Emit CSS_FILE anchor row ----
    $cssFileRow = Add-CssFileRow -LineEnd $script:CurrentFileLineCount

    # ---- Emit FILE_HEADER row ----
    $headerInfo = Get-FileHeaderInfo -Comments $script:CurrentNormalizedComments
    $headerRawText = $null
    $firstBlock = $null
    foreach ($c in $script:CurrentNormalizedComments) {
        if ($c.Type -eq 'Block') { $firstBlock = $c; break }
    }
    if ($firstBlock) {
        $headerRawText = Format-SingleLine -Text $firstBlock.Text
        [void]$script:CurrentUsedCommentLines.Add([int]$firstBlock.LineStart)
    }
    $headerRow = Add-FileHeaderRow `
        -LineStart           $headerInfo.StartLine `
        -LineEnd             $headerInfo.EndLine `
        -RawText             $headerRawText `
        -PurposeDescription  $headerInfo.Description
    foreach ($code in $headerInfo.DriftCodes) {
        Add-DriftCode -Row $headerRow -Code $code
    }
    $script:fileMeta[$name].FileOrgList = $headerInfo.FileOrgList

    # ---- Emit COMMENT_BANNER rows from the section list ----
    $previousSectionTypeOrderIdx = -1
    foreach ($s in $script:CurrentSections) {
        [void](Add-CommentBannerRow -Section $s -PreviousSectionTypeOrderIdx $previousSectionTypeOrderIdx)
        if ($s.TypeName) {
            $idx = [array]::IndexOf($script:SectionTypeOrder, $s.TypeName)
            if ($idx -ge 0 -and $idx -gt $previousSectionTypeOrderIdx) {
                $previousSectionTypeOrderIdx = $idx
            }
        }
        # Record banner-comment lines as "used" so they don't count as stray.
        for ($ln = $s.BannerStartLine; $ln -le $s.BannerEndLine; $ln++) {
            [void]$script:CurrentUsedCommentLines.Add($ln)
        }
    }

    # ---- Walk the AST via the generic visitor ----
    $afterHeaderCount = $script:rows.Count
    try {
        Invoke-AstWalk -Node $ast -Visitor $CssVisitor
    } catch {
        $partialAdded = $script:rows.Count - $afterHeaderCount
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

    # ---- FORBIDDEN_COMMENT_STYLE: scan for stray comments ----
    $strayLines = New-Object System.Collections.Generic.List[int]
    foreach ($c in $script:CurrentNormalizedComments) {
        if ($c.Type -ne 'Block') { continue }
        if ($script:CurrentUsedCommentLines.Contains([int]$c.LineStart)) { continue }
        $trimmedText = if ($c.Text) { $c.Text.Trim() } else { '' }
        if ($trimmedText -match '^--.+--$') { continue }
        $strayLines.Add([int]$c.LineStart)
    }
    if ($strayLines.Count -gt 0 -and $cssFileRow) {
        $linesText = ($strayLines | Sort-Object) -join ', '
        Add-DriftCode -Row $cssFileRow -Code 'FORBIDDEN_COMMENT_STYLE' `
            -Context "Stray block comments not matching any of the four allowed kinds (file header, banner, purpose, trailing variant, sub-section marker) at line(s): $linesText."
    }

    $delta = $script:rows.Count - $startCount
    Write-Host ("    -> {0} rows" -f $delta) -ForegroundColor Green
}

# ============================================================================
# PASS 3 - CODEBASE-LEVEL DRIFT CHECKS
# ============================================================================

Write-Log "Pass 3: codebase-level drift checks..."

# --- One-time row indexes ---
$rowsByFile = @{}
$rowsByFileLineType = @{}
foreach ($r in $script:rows) {
    if (-not $rowsByFile.ContainsKey($r.FileName)) {
        $rowsByFile[$r.FileName] = New-Object System.Collections.Generic.List[object]
    }
    $rowsByFile[$r.FileName].Add($r)

    $lineKey = "$($r.FileName)|$($r.LineStart)|$($r.ComponentType)"
    if (-not $rowsByFileLineType.ContainsKey($lineKey)) {
        $rowsByFileLineType[$lineKey] = New-Object System.Collections.Generic.List[object]
    }
    $rowsByFileLineType[$lineKey].Add($r)
}

# --- DUPLICATE_FOUNDATION / DUPLICATE_CHROME ---
$foundationFiles = @($fileMeta.Keys | Where-Object { $fileMeta[$_].FoundationLine })
$chromeFiles     = @($fileMeta.Keys | Where-Object { $fileMeta[$_].ChromeLine })

if ($foundationFiles.Count -gt 1) {
    Write-Log ("  DUPLICATE_FOUNDATION across files: {0}" -f ($foundationFiles -join ', ')) 'WARN'
    foreach ($fname in $foundationFiles) {
        if (-not $rowsByFile.ContainsKey($fname)) { continue }
        foreach ($r in $rowsByFile[$fname]) {
            if ($r.ComponentType -eq 'COMMENT_BANNER' -and $r.Signature -eq 'FOUNDATION') {
                Add-DriftCode -Row $r -Code 'DUPLICATE_FOUNDATION'
            }
        }
    }
}

if ($chromeFiles.Count -gt 1) {
    Write-Log ("  DUPLICATE_CHROME across files: {0}" -f ($chromeFiles -join ', ')) 'WARN'
    foreach ($fname in $chromeFiles) {
        if (-not $rowsByFile.ContainsKey($fname)) { continue }
        foreach ($r in $rowsByFile[$fname]) {
            if ($r.ComponentType -eq 'COMMENT_BANNER' -and $r.Signature -eq 'CHROME') {
                Add-DriftCode -Row $r -Code 'DUPLICATE_CHROME'
            }
        }
    }
}

# --- FILE_ORG_MISMATCH ---
foreach ($fname in $fileMeta.Keys) {
    $meta = $fileMeta[$fname]
    if ($null -eq $meta.FileOrgList) { continue }
    $orgMatches = Test-FileOrgMatchesBanners -FileOrgList $meta.FileOrgList -Sections $meta.Sections
    if (-not $orgMatches -and $rowsByFile.ContainsKey($fname)) {
        foreach ($r in $rowsByFile[$fname]) {
            if ($r.ComponentType -eq 'FILE_HEADER') {
                Add-DriftCode -Row $r -Code 'FILE_ORG_MISMATCH'
                break
            }
        }
    }
}

# --- DRIFT_HEX_LITERAL ---
foreach ($fname in $fileMeta.Keys) {
    $meta = $fileMeta[$fname]
    if ($null -eq $meta.HexLiterals -or $meta.HexLiterals.Count -eq 0) { continue }
    if ($meta.FoundationLine) { continue }

    $sampleFullPath = $CssFiles | Where-Object { [System.IO.Path]::GetFileName($_) -eq $fname } | Select-Object -First 1
    if (-not $sampleFullPath) { continue }
    $sampleZone = Get-CssZone -FullPath $sampleFullPath
    $zoneVarMap = if ($sampleZone -eq 'docs') { $script:docsSharedVariableMap } else { $script:ccSharedVariableMap }
    if ($null -eq $zoneVarMap -or $zoneVarMap.Count -eq 0) { continue }

    foreach ($hex in $meta.HexLiterals) {
        foreach ($ctype in @('CSS_CLASS','CSS_VARIANT')) {
            $key = "$fname|$($hex.Line)|$ctype"
            if ($rowsByFileLineType.ContainsKey($key)) {
                foreach ($r in $rowsByFileLineType[$key]) {
                    Add-DriftCode -Row $r -Code 'DRIFT_HEX_LITERAL'
                }
            }
        }
    }
}

# --- DRIFT_PX_LITERAL ---
foreach ($fname in $fileMeta.Keys) {
    $meta = $fileMeta[$fname]
    if ($null -eq $meta.PxLiterals -or $meta.PxLiterals.Count -eq 0) { continue }
    if ($meta.FoundationLine) { continue }

    $sampleFullPath = $CssFiles | Where-Object { [System.IO.Path]::GetFileName($_) -eq $fname } | Select-Object -First 1
    if (-not $sampleFullPath) { continue }
    $sampleZone = Get-CssZone -FullPath $sampleFullPath
    $zoneVarMap = if ($sampleZone -eq 'docs') { $script:docsSharedVariableMap } else { $script:ccSharedVariableMap }
    if ($null -eq $zoneVarMap -or $zoneVarMap.Count -eq 0) { continue }

    $sizeTokensPresent = @($zoneVarMap.Keys | Where-Object { $_ -like 'size-*' }).Count -gt 0
    if (-not $sizeTokensPresent) { continue }

    foreach ($px in $meta.PxLiterals) {
        foreach ($ctype in @('CSS_CLASS','CSS_VARIANT')) {
            $key = "$fname|$($px.Line)|$ctype"
            if ($rowsByFileLineType.ContainsKey($key)) {
                foreach ($r in $rowsByFileLineType[$key]) {
                    Add-DriftCode -Row $r -Code 'DRIFT_PX_LITERAL'
                }
            }
        }
    }
}

# --- EXCESS_BLANK_LINES ---
foreach ($file in $CssFiles) {
    $name = [System.IO.Path]::GetFileName($file)
    if (-not $astCache.ContainsKey($file)) { continue }
    $ast = $astCache[$file].ast
    if ($null -eq $ast.nodes -or $ast.nodes.Count -lt 2) { continue }

    $excessFound = $false
    for ($ni = 1; $ni -lt $ast.nodes.Count; $ni++) {
        $prev = $ast.nodes[$ni - 1]
        $cur  = $ast.nodes[$ni]
        $prevEnd = if ($prev.source -and $prev.source.end) { [int]$prev.source.end.line } else { 0 }
        $curStart = if ($cur.source -and $cur.source.start) { [int]$cur.source.start.line } else { 0 }
        if ($prevEnd -gt 0 -and $curStart -gt 0 -and ($curStart - $prevEnd) -gt 2) {
            $excessFound = $true
            break
        }
    }

    if ($excessFound -and $rowsByFile.ContainsKey($name)) {
        foreach ($r in $rowsByFile[$name]) {
            if ($r.ComponentType -eq 'CSS_FILE') {
                Add-DriftCode -Row $r -Code 'EXCESS_BLANK_LINES'
                break
            }
        }
    }
}

# --- UNDEFINED_CLASS_USAGE ---
# A class participating in a compound or descendant selector must be defined
# by a separate standalone rule. The populator surfaces a USAGE row for each
# class participation (per spec section 7 amended); if no DEFINITION row
# exists for the class in the appropriate scope, the USAGE is undefined.
#
# Scope rules:
#   - USAGE row with Scope='SHARED' resolved to a shared file during row
#     emission, which means a definition exists in the zone's shared map.
#     No check needed.
#   - USAGE row with Scope='LOCAL' fell through to the current file. We
#     require a CSS_CLASS DEFINITION or CSS_VARIANT DEFINITION row in the
#     same file with the same component_name. Pseudo-element rules attached
#     to a class are CSS_CLASS DEFINITION rows per spec section 6.1 and
#     satisfy this check. A CSS_VARIANT DEFINITION for the same class
#     (e.g. .foo:hover) also satisfies it - the class exists in the file's
#     vocabulary.
#
# Build a per-file definitions map by walking the row collection, then walk
# every USAGE row once more to check.
$definedByFile = @{}
foreach ($r in $script:rows) {
    if ($r.ReferenceType -ne 'DEFINITION') { continue }
    if ($r.ComponentType -notin @('CSS_CLASS','CSS_VARIANT')) { continue }
    if ([string]::IsNullOrEmpty($r.ComponentName)) { continue }
    if (-not $definedByFile.ContainsKey($r.FileName)) {
        $definedByFile[$r.FileName] = New-Object System.Collections.Generic.HashSet[string]
    }
    [void]$definedByFile[$r.FileName].Add($r.ComponentName)
}

foreach ($r in $script:rows) {
    if ($r.ReferenceType -ne 'USAGE') { continue }
    if ($r.ComponentType -notin @('CSS_CLASS','CSS_VARIANT')) { continue }
    if ([string]::IsNullOrEmpty($r.ComponentName)) { continue }
    # Shared-resolved usages already found a definition during emission.
    if ($r.Scope -eq 'SHARED') { continue }
    # Local-scope usages must have a same-file definition.
    $hasDef = $definedByFile.ContainsKey($r.FileName) -and
              $definedByFile[$r.FileName].Contains($r.ComponentName)
    if (-not $hasDef) {
        Add-DriftCode -Row $r -Code 'UNDEFINED_CLASS_USAGE' `
            -Context "Class '$($r.ComponentName)' is used in a compound or descendant selector but has no standalone definition in this file."
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

Write-Log "Clearing existing CSS rows from Asset_Registry..."
$cleared = Invoke-SqlNonQuery -Query "DELETE FROM dbo.Asset_Registry WHERE file_type = 'CSS';"
if (-not $cleared) {
    Write-Log "Failed to clear existing CSS rows. Aborting." 'ERROR'
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
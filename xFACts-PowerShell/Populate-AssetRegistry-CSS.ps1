<#
.SYNOPSIS
    xFACts - Asset Registry CSS Populator

.DESCRIPTION
    Walks every .css file under the Control Center public/css and
    public/docs/css directories, parses each file with PostCSS (via the
    parse-css.js Node helper), and generates Asset_Registry rows describing
    every cataloguable construct found in the file. Each row carries any
    drift codes the parser detects per CC_CSS_Spec.md.

    File zone and scope come from dbo.Object_Registry: a file's zone selects
    the within-zone shared maps its USAGE references resolve against, and a
    scope of SHARED contributes the file's definitions to those maps.

.PARAMETER Execute
    Required to delete the existing CSS rows and write the new row set.
    Without this flag, runs in preview mode.

.COMPONENT
    Tools.Utilities

.NOTES
    File Name : Populate-AssetRegistry-CSS.ps1
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
    CONSTANTS: CSS VISITOR
    VARIABLES: SCRIPT-SCOPE STATE
    FUNCTIONS: FILE AND PARSER HELPERS
    FUNCTIONS: SELECTOR DECOMPOSITION
    FUNCTIONS: ZONE-AWARE SHARED MAP ACCESSORS
    FUNCTIONS: CSS ROW EMITTERS
    FUNCTIONS: PER-SELECTOR ROW GENERATION
    EXECUTION: SCRIPT EXECUTION
#>
<# ============================================================================
   CHANGELOG: CHANGE HISTORY
   ----------------------------------------------------------------------------
   Date-stamped change history. Each entry is one ISO date line followed by an
   indented description. Entries appear most-recent first.
   Prefix: (none)
   ============================================================================ #>

# 2026-05-31  Renamed drift code ANCHOR_SECTION_INVALID_PREFIX to
#             SHELL_SECTION_INVALID_PREFIX and changed "anchor file" wording to
#             "shell file" throughout, matching CC_CSS_Spec.md. "Anchor" is now
#             reserved for the CSS_FILE base row; "shell" denotes the
#             FOUNDATION/CHROME-bearing shared file (scope_tier SHELL).
# 2026-05-31  Dropped the separate Get-ObjectRegistryMap call. The zone/scope
#             map now also carries registry_id, so the file makes one
#             Object_Registry query instead of two. A transitional shim at the
#             bulk-insert call projects registry_id back to the flat map shape
#             the bulk insert still expects.
# 2026-05-30  Converted to the Control Center PowerShell file format spec:
#             block-comment header and section banners, canonical section
#             order, dedicated CHANGELOG section, single EXECUTION section
#             with sub-section markers, and leading purpose comments on
#             script-scope declarations. Made zone and scope table-driven:
#             both now come from dbo.Object_Registry rather than a local
#             path test and hardcoded shared-file lists. Removed Get-CssZone
#             and the shared-file list constants. Added FILE_NOT_REGISTERED
#             for files absent from Object_Registry.
# 2026-05-22  File-level discipline and construct-specific checks added:
#             MISSING_BLANK_LINE_SEPARATOR, EMPTY_SECTION,
#             MISSING_TRAILING_NEWLINE, PSEUDO_ELEMENT_OUT_OF_ORDER,
#             VARIANT_BEFORE_BASE, DUPLICATE_ROOT_BLOCK. Broadened
#             MISSING_PURPOSE_COMMENT to :root, @keyframes, and @media; @media
#             now emits its own row.
# 2026-05-22  Class-on-class compounds emit USAGE rows, not DEFINITION rows;
#             PREFIX_MISMATCH now checks every class token in a compound;
#             added ANCHOR_SECTION_INVALID_PREFIX and UNDEFINED_CLASS_USAGE.
# 2026-05-11  Added CSS_FILE pure-anchor row, emitted once per scanned file
#             ahead of FILE_HEADER. Moved EXCESS_BLANK_LINES and
#             FORBIDDEN_COMMENT_STYLE from FILE_HEADER onto CSS_FILE.
# 2026-05-07  Replaced the catch-all MALFORMED_SECTION_BANNER with seven
#             granular banner-shape codes; UNKNOWN_SECTION_TYPE now also
#             emitted from the banner parser. Banner detection made permissive.
# 2026-05-07  Rebuilt Pass 3 codebase checks on a one-time row index;
#             scoped per-rule attachments to the rule's own row slice.
# 2026-05-07  Adopted the shared visitor-pattern walker, section-list builder,
#             and file-header parser. Added prefix registry validation and
#             several formatting/forbidden-selector checks.
# 2026-05-05  AST walk resilience and FILE_HEADER purpose-paragraph extraction.
# 2026-05-04  Complete purpose_description coverage; FILE_HEADER signature NULL.
# 2026-05-03  @media permitted in any section; FEEDBACK_OVERLAYS section type;
#             FOUNDATION reset exemptions; forbid :not() and stacked pseudos.
# 2026-05-02  Initial production implementation.

<# ============================================================================
   PARAMETERS: SCRIPT PARAMETERS
   ----------------------------------------------------------------------------
   Script-level parameters: the execute switch that gates the database write.
   Prefix: (none)
   ============================================================================ #>

[CmdletBinding()]
param(
    [switch]$Execute
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

Initialize-XFActsScript -ScriptName 'Populate-AssetRegistry-CSS' -Execute:$Execute

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
   Node toolchain paths, the PostCSS parser script, and the CSS scan roots.
   Zone, scope, and shell designation are not listed here; they come from
   dbo.Object_Registry per file at run time.
   Prefix: (none)
   ============================================================================ #>

# Node executable used to run the PostCSS parser.
$NodeExe = 'C:\Program Files\nodejs\node.exe'
# Node library path made available to the parser subprocess.
$NodeLibsPath = 'C:\Program Files\nodejs-libs\node_modules'
# The PostCSS parser script invoked per file.
$ParseCssScript = "$PSScriptRoot\parse-css.js"

# Control Center root directory.
$CcRoot = 'E:\xFACts-ControlCenter'
# Scan roots covering all CSS files in the platform (cc and docs).
$CssScanRoots = @(
    "$CcRoot\public\css"
    "$CcRoot\public\docs\css"
)

<# ============================================================================
   CONSTANTS: SPEC CONSTANTS
   ----------------------------------------------------------------------------
   The recognized section types in required order, and the shell-only section
   types whose banners must declare the chrome prefix in the zone's shell file.
   Prefix: (none)
   ============================================================================ #>

# The five recognized section types, in required order (CC_CSS_Spec.md Section 4).
$SectionTypeOrder = @('FOUNDATION', 'CHROME', 'LAYOUT', 'CONTENT', 'FEEDBACK_OVERLAYS')
# Alias of the ordered list, used where only membership is checked.
$ValidSectionTypes = $SectionTypeOrder

# Section types that must declare the chrome prefix 'cc' when they appear in a
# zone's shell file. FOUNDATION and CHROME live only in the shell file (any
# other file carrying them is DUPLICATE_FOUNDATION / DUPLICATE_CHROME drift);
# FEEDBACK_OVERLAYS may appear in shell or page files, and declares 'cc' when
# in the shell file.
$ShellSectionTypes = @('FOUNDATION', 'CHROME', 'FEEDBACK_OVERLAYS')

<# ============================================================================
   CONSTANTS: DRIFT DESCRIPTIONS
   ----------------------------------------------------------------------------
   Drift code to human-readable description map, kept aligned with the
   CC_CSS_Spec.md drift reference. Add-DriftCode validates against this map
   and uses it to populate drift_text. Pass 3 codes are included so attachment
   does not fail the master-table check.
   Prefix: (none)
   ============================================================================ #>

# Drift code to human-readable description map for Add-DriftCode.
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
    'UNKNOWN_SECTION_TYPE'              = "A section banner declares a TYPE not in the enumerated list (FOUNDATION, CHROME, LAYOUT, CONTENT, FEEDBACK_OVERLAYS)."
    'SECTION_TYPE_ORDER_VIOLATION'      = "Section types appear out of the required order (FOUNDATION -> CHROME -> LAYOUT -> CONTENT -> FEEDBACK_OVERLAYS)."
    'MISSING_PREFIX_DECLARATION'        = "A section banner is missing the mandatory Prefix line in its description block."
    'MALFORMED_PREFIX_VALUE'            = "A section banner declares a Prefix value that is neither a page prefix nor 'cc', or declares multiple comma-separated values."
    'PREFIX_REGISTRY_MISMATCH'          = "A page-file section banner's declared prefix does not match Component_Registry.cc_prefix for the file's component."
    'SHELL_SECTION_INVALID_PREFIX'      = "A FOUNDATION, CHROME, or shell-file FEEDBACK_OVERLAYS section declares a prefix other than 'cc'."
    'DUPLICATE_FOUNDATION'              = "More than one CSS file in the codebase contains a FOUNDATION section."
    'DUPLICATE_CHROME'                  = "More than one CSS file in the codebase contains a CHROME section."
    # Class definitions, variants, and ordering
    'PREFIX_MISMATCH'                   = "A class name's leftmost token does not begin with the declared prefix. Every class token in a compound selector is checked."
    'MISSING_PURPOSE_COMMENT'           = "A class definition, :root block, @keyframes block, or @media block is not preceded by a single-line purpose comment."
    'MISSING_VARIANT_COMMENT'           = "A class variant does not carry a trailing inline comment after the opening brace."
    'UNDEFINED_CLASS_USAGE'             = "A class is used in a compound or descendant selector but has no standalone definition in scope. Every class participating in a compound or descendant rule must be defined by a separate single-class rule somewhere in the same file (or, for usages of shared classes, in the zone's shared files)."
    'PSEUDO_ELEMENT_OUT_OF_ORDER'       = "A pseudo-element rule appears before its base class or after a variant on the same class. The required order is base class -> pseudo-element rules -> pseudo-class variants."
    'VARIANT_BEFORE_BASE'               = "A class variant appears before its base class definition in the file. A variant must follow its base."
    'DUPLICATE_ROOT_BLOCK'              = "A file contains more than one :root block. Exactly one :root block per file is permitted."
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
    # Comment / formatting / file-level
    'FORBIDDEN_COMMENT_STYLE'           = "A comment exists that is not one of the allowed kinds (file header, section banner, per-class purpose comment, trailing variant comment, sub-section marker)."
    'FORBIDDEN_COMPOUND_DECLARATION'    = "Two or more declarations appear on the same line. Each declaration must be on its own line."
    'BLANK_LINE_INSIDE_RULE'            = "A blank line appears inside a class definition (between the opening { and the closing })."
    'EXCESS_BLANK_LINES'                = "More than one blank line appears between top-level constructs."
    'MISSING_BLANK_LINE_SEPARATOR'      = "Two adjacent top-level constructs have no blank line between them. Every two adjacent top-level constructs must be separated by exactly one blank line."
    'EMPTY_SECTION'                     = "A section banner is not followed by any cataloguable construct before the next banner or end-of-file. Empty sections are not permitted."
    'MISSING_TRAILING_NEWLINE'          = "The file does not end with a single trailing newline. The file must end with the last '}' followed by exactly one newline character."
    # Catalog integrity (operational, not a CSS content rule)
    'FILE_NOT_REGISTERED'               = "The file has no active row in Object_Registry, so its zone and scope could not be determined. Every scanned file must be registered; add it to dbo.Object_Registry. Rows from this file carry zone and scope of '<undefined>'."
}

<# ============================================================================
   CONSTANTS: CSS VISITOR
   ----------------------------------------------------------------------------
   The visitor scriptblock consumed by the shared Invoke-AstWalk: dispatches
   each AST node to the row emitters and per-selector generation.
   Prefix: (none)
   ============================================================================ #>

# The visitor receives ($Node, $ParentChain, $ParentNodes) from the helpers'
# generic walker and dispatches by Node.type. Returning 'SKIP_CHILDREN' stops
# the walker from recursing into the current node's children; we use that for
# 'rule' nodes (which we process exhaustively here, including the body decls)
# and for 'comment' nodes (PostCSS comments are leaves).
$script:CssVisitor = {
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
            # normalized comment list. The helper handles banner-shape exclusion
            # and tracks consumed comment lines so they don't later count as
            # stray comments.
            $cmt = Test-HasPrecedingPurposeComment -Line $line
            $hasPrecedingComment  = $cmt.Present
            $precedingCommentText = $cmt.Text

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

            # :root checks (CC_CSS_Spec.md Section 10.2). The :root rule
            # produces a CSS_RULE row via the primary-less branch of
            # Add-RowsForSelector. Per the spec :root must be preceded by a
            # purpose comment and only one :root may exist per file.
            $selectorIsRoot = ($Node.selector -and $Node.selector.Trim() -eq ':root')
            if ($selectorIsRoot) {
                # Locate the CSS_RULE row we just emitted for :root (the
                # first row added during this rule's selector emission).
                $rootRow = $null
                for ($ri = $ruleRowsStartIdx; $ri -lt $script:rows.Count; $ri++) {
                    if ($script:rows[$ri].ComponentType -eq 'CSS_RULE') {
                        $rootRow = $script:rows[$ri]
                        break
                    }
                }
                if ($rootRow) {
                    if (-not $hasPrecedingComment) {
                        Add-DriftCode -Row $rootRow -Code 'MISSING_PURPOSE_COMMENT'
                    }
                    # Per-file :root count tracking. The first :root in a file
                    # is allowed; subsequent ones fire DUPLICATE_ROOT_BLOCK.
                    if (-not $script:fileMeta[$script:CurrentFile].ContainsKey('RootLines')) {
                        $script:fileMeta[$script:CurrentFile].RootLines = New-Object System.Collections.Generic.List[int]
                    }
                    $script:fileMeta[$script:CurrentFile].RootLines.Add($line)
                    if ($script:fileMeta[$script:CurrentFile].RootLines.Count -gt 1) {
                        Add-DriftCode -Row $rootRow -Code 'DUPLICATE_ROOT_BLOCK'
                    }
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
                    # Purpose comment (CC_CSS_Spec.md Section 11). Every
                    # @keyframes block is preceded by a single-line purpose
                    # comment.
                    $kfCmt = Test-HasPrecedingPurposeComment -Line $line
                    if (-not $kfCmt.Present) {
                        Add-DriftCode -Row $kfRow -Code 'MISSING_PURPOSE_COMMENT'
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

            # @media: emit a CSS_RULE row representing the @media block
            # itself, then let the walker recurse so wrapped rules are
            # processed in the at-rule's context. The row is the host for
            # MISSING_PURPOSE_COMMENT (CC_CSS_Spec.md Section 12.1) and any
            # future @media-specific drift codes. Wrapped rules continue to
            # produce their own CSS_CLASS / CSS_VARIANT / CSS_RULE rows
            # independently.
            if ($Node.name -eq 'media') {
                $mediaLabel = "@media"
                if ($Node.params) { $mediaLabel = "$mediaLabel $($Node.params)" }
                $mediaLabel = $mediaLabel.Trim()

                $mediaRow = Add-CssRuleRow -LineStart $line -LineEnd $endLine `
                    -ColumnStart $col -Signature $mediaLabel -ParentAtrule $parentAtrule `
                    -RawText $mediaLabel
                if ($mediaRow) {
                    $mediaCmt = Test-HasPrecedingPurposeComment -Line $line
                    if (-not $mediaCmt.Present) {
                        Add-DriftCode -Row $mediaRow -Code 'MISSING_PURPOSE_COMMENT'
                    }
                }
                return
            }

            # Other at-rules: let the walker recurse so child rules are
            # processed in the at-rule's context. The rule handler above
            # looks up parent atrule via $ParentNodes.
            return
        }

        default {
            return
        }
    }
}

<# ============================================================================
   VARIABLES: SCRIPT-SCOPE STATE
   ----------------------------------------------------------------------------
   Row collection, dedupe tracking, per-file metadata, and the per-file context
   the row emitters read during the AST walk. Zone, scope, and shell designation
   are stamped per file from the Object_Registry map at the start of each file's
   walk.
   Prefix: (none)
   ============================================================================ #>

# Accumulated Asset_Registry rows for the current run.
$script:rows = New-Object System.Collections.Generic.List[object]
# Dedupe tracker referenced directly by Test-AddDedupeKey.
$script:dedupeKeys = New-Object 'System.Collections.Generic.HashSet[string]'

# Per-file metadata accumulated during the walk and used by Pass 3.
$script:fileMeta = @{}

# Per-file CSS_FILE anchor-row references; Pass 3 attaches whole-file drift here.
$script:cssFileRowByFile = @{}

# Object_Registry zone/scope map: object_name -> @{ Zone; Scope; ScopeTier }.
$script:zoneScopeMap = @{}
# Files found on disk but absent from the zone/scope map.
$script:objectRegistryMisses = New-Object 'System.Collections.Generic.HashSet[string]'

# Zone-scoped shared class definitions, keyed by zone string.
$script:sharedClassMapByZone = @{}
# Zone-scoped shared custom-property definitions, keyed by zone string.
$script:sharedVariableMapByZone = @{}
# Zone-scoped shared keyframe definitions, keyed by zone string.
$script:sharedKeyframeMapByZone = @{}

# Name of the file currently being walked.
$script:CurrentFile = $null
# Zone of the current file, from Object_Registry.
$script:CurrentFileZone = '<undefined>'
# Scope of the current file, from Object_Registry.
$script:CurrentFileScope = '<undefined>'
# Whether the current file's scope is SHARED.
$script:CurrentFileIsShared = $false
# Whether the current file is the zone's shell file (scope_tier SHELL).
$script:CurrentFileIsShell = $false
# Line count of the current file, from the AST end position.
$script:CurrentFileLineCount = 0
# Section list for the current file, the source of truth for line-to-section.
$script:CurrentSections = $null
# Component_Registry.cc_prefix for the current file.
$script:CurrentRegistryPrefix = $null
# Whether the current file has any Component_Registry row.
$script:CurrentRegistryHasMapping = $false
# Normalized comment list for the current file.
$script:CurrentNormalizedComments = $null
# Comment lines already consumed by rules, so they do not count as stray.
$script:CurrentUsedCommentLines = $null

<# ============================================================================
   FUNCTIONS: FILE AND PARSER HELPERS
   ----------------------------------------------------------------------------
   PostCSS comment-shape adapter and the file/parser helpers specific to CSS.
   Prefix: (none)
   ============================================================================ #>

# Walk the PostCSS AST and collect every comment into the normalized shape the
# shared Get-FileHeaderInfo and New-SectionList expect (.Type / .Text /
# .LineStart / .LineEnd). PostCSS produces only block comments. Returns a list
# sorted by LineStart ascending.
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

<# ============================================================================
   FUNCTIONS: SELECTOR DECOMPOSITION
   ----------------------------------------------------------------------------
   Selector parsing, compound decomposition, and the preceding-comment lookups
   that the row emitters use to detect purpose comments and variant comments.
   Prefix: (none)
   ============================================================================ #>

# Look up the comment immediately preceding a construct at line $Line, in
# the normalized comment list. Returns $true / $false (presence) plus the
# clean comment text. A "preceding comment" is one whose LineEnd is exactly
# $Line - 1 and which is NOT a banner-shaped comment. Marks the comment's
# line as consumed in $script:CurrentUsedCommentLines so it does not later
# count as a stray comment.
function Test-HasPrecedingPurposeComment {
    param([int]$Line)

    foreach ($c in $script:CurrentNormalizedComments) {
        if ($c.LineEnd -eq ($Line - 1)) {
            if (-not (Test-IsBannerComment -CommentText $c.Text -ValidSectionTypes $script:ValidSectionTypes)) {
                [void]$script:CurrentUsedCommentLines.Add([int]$c.LineStart)
                return @{
                    Present = $true
                    Text    = (ConvertTo-CleanCommentText -CommentText $c.Text)
                }
            }
        }
    }
    return @{ Present = $false; Text = $null }
}

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
            CombinatorBefore  = $null
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

<# ============================================================================
   FUNCTIONS: ZONE-AWARE SHARED MAP ACCESSORS
   ----------------------------------------------------------------------------
   Return the current file's zone-scoped shared maps. A consumer resolves USAGE
   references only against the shared definitions collected from its own zone.
   Maps are keyed by zone string and populated in Pass 1; a zone with no shared
   files yields an empty map.
   Prefix: (none)
   ============================================================================ #>

# Return the inner map for $Zone from a by-zone map, creating an empty inner
# map on first access so callers never receive $null.
function Get-ZoneMap {
    param(
        [Parameter(Mandatory)] [hashtable]$ByZone,
        [Parameter(Mandatory)] [string]$Zone
    )
    if (-not $ByZone.ContainsKey($Zone)) { $ByZone[$Zone] = @{} }
    return $ByZone[$Zone]
}

# Return the current file's zone-scoped shared class map.
function Get-ZoneSharedClassMap {
    param()
    return Get-ZoneMap -ByZone $script:sharedClassMapByZone    -Zone $script:CurrentFileZone
}
# Return the current file's zone-scoped shared variable map.
function Get-ZoneSharedVariableMap {
    param()
    return Get-ZoneMap -ByZone $script:sharedVariableMapByZone -Zone $script:CurrentFileZone
}
# Return the current file's zone-scoped shared keyframe map.
function Get-ZoneSharedKeyframeMap {
    param()
    return Get-ZoneMap -ByZone $script:sharedKeyframeMapByZone -Zone $script:CurrentFileZone
}

<# ============================================================================
   FUNCTIONS: CSS ROW EMITTERS
   ----------------------------------------------------------------------------
   Construct Asset_Registry rows for each cataloguable CSS construct (CSS_FILE,
   FILE_HEADER, section banners, classes, variants, variables, keyframes, and
   usages), attaching drift codes detected during emission.
   Prefix: (none)
   ============================================================================ #>

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

# Emit the FILE_HEADER row for the current file.
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

# Emit a CSS_RULE row (non-class rules: :root, @media, forbidden at-rules).
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
        [string]$PseudoClass,
        [Parameter(Mandatory)] [string]$ReferenceType,
        [Parameter(Mandatory)] [int]$LineStart,
        [Parameter(Mandatory)] [int]$LineEnd,
        [Parameter(Mandatory)] [int]$ColumnStart,
        [string]$Signature,
        [string]$ParentAtrule,
        [string]$RawText,
        [string]$PurposeDescription,
        [int]$TokenIndex = 0
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

# Emit an HTML_ID row for an id selector token.
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

# Emit a CSS_VARIABLE definition or usage row.
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

# Emit a CSS_KEYFRAME definition or usage row.
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
# SHELL_SECTION_INVALID_PREFIX are added here based on cross-section /
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
    #   SHELL_SECTION_INVALID_PREFIX -- section is FOUNDATION/CHROME/
    #     shell-file FEEDBACK_OVERLAYS but the banner declares a value
    #     other than 'cc'. Applies in shell files; non-shell files
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

        # SHELL_SECTION_INVALID_PREFIX: a shell-only section type must declare
        # 'cc' in the zone's shell file. Checked first because it depends only
        # on section type and file identity, not the registry.
        if ($script:CurrentFileIsShell -and ($Section.TypeName -in $ShellSectionTypes)) {
            if (-not $isCc) {
                Add-DriftCode -Row $row -Code 'SHELL_SECTION_INVALID_PREFIX' `
                    -Context "Section type '$($Section.TypeName)' in the shell file must declare Prefix 'cc'; banner declares '$bannerVal'."
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
            # If regVal is null and the file is not the shell, this is a
            # registry data gap, not file drift; it surfaces in the miss report.
        }
    }

    return $row
}

<# ============================================================================
   FUNCTIONS: PER-SELECTOR ROW GENERATION
   ----------------------------------------------------------------------------
   Decompose each rule's selector into compounds and emit the appropriate
   definition or usage rows, applying selector-shape drift checks.
   Prefix: (none)
   ============================================================================ #>

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

    # Selector with no class and no id (element / universal / attribute / pseudo-element only)
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

    # PRIMARY: emit one row per class token
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

    # PRIMARY: id side (each id emits a single HTML_ID row)
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

    # DESCENDANT compounds: one USAGE row per class token, plus id-side
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

<# ============================================================================
   EXECUTION: SCRIPT EXECUTION
   ----------------------------------------------------------------------------
   Loads the Object_Registry zone/scope map, discovers and parses every CSS
   file, collects shared-scope definitions (Pass 1), generates rows per file
   (Pass 2), runs codebase-level drift checks (Pass 3), then validates,
   indexes, summarizes, and writes the rows.
   Prefix: (none)
   ============================================================================ #>

# -- Parser Environment --

# Make the Node library path available to the PostCSS parser subprocess.
$env:NODE_PATH = $NodeLibsPath

# -- Object_Registry Zone/Scope Classification --

Write-Log "Loading Object_Registry zone/scope map..."
$script:zoneScopeMap = Get-ObjectRegistryZoneScopeMap `
    -ServerInstance $script:XFActsServerInstance `
    -Database       $script:XFActsDatabase `
    -FileType       'CSS'
Write-Log ("  Object_Registry zone/scope rows loaded: {0}" -f $script:zoneScopeMap.Count)

# -- File Discovery --

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

# -- Pass 1: Parse and Collect Shared Definitions --

Write-Log "Pass 1: parsing files and collecting SHARED-scope definitions..."
foreach ($file in $CssFiles) {
    $name = [System.IO.Path]::GetFileName($file)

    Write-Host "  Parsing $name ..." -NoNewline
    $parsed = Invoke-CssParse -FilePath $file
    if ($null -eq $parsed) {
        Write-Host " FAILED" -ForegroundColor Red
        continue
    }
    Write-Host " ok" -ForegroundColor Green
    $astCache[$file] = $parsed

    # Only SHARED-scope files contribute definitions to their zone's maps.
    if (-not $script:zoneScopeMap.ContainsKey($name)) { continue }
    $reg = $script:zoneScopeMap[$name]
    if ($reg.Scope -ne 'SHARED') { continue }

    $zone     = $reg.Zone
    $classMap = Get-ZoneMap -ByZone $script:sharedClassMapByZone    -Zone $zone
    $varMap   = Get-ZoneMap -ByZone $script:sharedVariableMapByZone -Zone $zone
    $kfMap    = Get-ZoneMap -ByZone $script:sharedKeyframeMapByZone -Zone $zone

    $stack = New-Object System.Collections.Generic.Stack[object]
    $stack.Push($parsed.ast)
    while ($stack.Count -gt 0) {
        $node = $stack.Pop()
        if ($null -eq $node) { continue }

        if ($node.type -eq 'rule' -and $node.selectorTree -and $node.selectorTree.nodes) {
            foreach ($sel in $node.selectorTree.nodes) {
                if ($sel.type -ne 'selector') { continue }
                $compounds = Get-CompoundList -SelectorChildren $sel.nodes
                # Each class token is a real class in its own right, so a
                # class-on-class compound registers every token (first wins).
                foreach ($cmp in $compounds) {
                    foreach ($cls in $cmp.Classes) {
                        if (-not $classMap.ContainsKey($cls)) { $classMap[$cls] = $name }
                    }
                }
            }
        }

        if ($node.type -eq 'decl' -and $node.prop -and $node.prop.StartsWith('--')) {
            $varName = $node.prop.Substring(2)
            if (-not $varMap.ContainsKey($varName)) { $varMap[$varName] = $name }
        }

        if ($node.type -eq 'atrule' -and $node.name -eq 'keyframes' -and $node.params) {
            $kfName = $node.params.Trim()
            if (-not $kfMap.ContainsKey($kfName)) { $kfMap[$kfName] = $name }
        }

        if ($node.nodes) {
            foreach ($child in $node.nodes) { $stack.Push($child) }
        }
    }
}

foreach ($zone in ($script:sharedClassMapByZone.Keys | Sort-Object)) {
    Write-Log ("  Zone '{0}' - shared classes: {1}, variables: {2}, keyframes: {3}" -f `
        $zone,
        (Get-ZoneMap -ByZone $script:sharedClassMapByZone    -Zone $zone).Count,
        (Get-ZoneMap -ByZone $script:sharedVariableMapByZone -Zone $zone).Count,
        (Get-ZoneMap -ByZone $script:sharedKeyframeMapByZone -Zone $zone).Count)
}

# -- Registry Loads --

Write-Log "Loading Component_Registry prefix map for registry validation..."
$componentPrefixMap = Get-ComponentRegistryPrefixMap `
    -ServerInstance $script:XFActsServerInstance `
    -Database       $script:XFActsDatabase `
    -FileType       'CSS'
Write-Log ("  Component_Registry prefix rows loaded: {0}" -f $componentPrefixMap.Count)

# -- Pass 2: Per-File Walk --

Write-Log "Pass 2: generating Asset_Registry rows..."

foreach ($file in $CssFiles) {
    $name = [System.IO.Path]::GetFileName($file)

    if (-not $astCache.ContainsKey($file)) {
        Write-Log "  Skipping (no parsed AST): $name" 'WARN'
        continue
    }

    $ast = $astCache[$file].ast

    # Zone, scope, and shell designation come from Object_Registry. A file
    # absent from the map is stamped '<undefined>' and recorded so Pass 3 can
    # attach FILE_NOT_REGISTERED to its CSS_FILE row.
    if ($script:zoneScopeMap.ContainsKey($name)) {
        $reg   = $script:zoneScopeMap[$name]
        $zone  = $reg.Zone
        $scope = $reg.Scope
        $tier  = $reg.ScopeTier
    } else {
        $zone  = '<undefined>'
        $scope = '<undefined>'
        $tier  = $null
        [void]$script:objectRegistryMisses.Add($name)
    }

    # Set per-file context
    $script:CurrentFile               = $name
    $script:CurrentFileZone           = $zone
    $script:CurrentFileScope          = $scope
    $script:CurrentFileIsShared       = ($scope -eq 'SHARED')
    $script:CurrentFileIsShell        = ($tier -eq 'SHELL')
    $script:CurrentFileLineCount      = if ($astCache[$file].sourceLength) { [int]$astCache[$file].sourceLength } else { 0 }
    $script:CurrentRegistryHasMapping = $componentPrefixMap.ContainsKey($name)
    $script:CurrentRegistryPrefix     = if ($script:CurrentRegistryHasMapping) { $componentPrefixMap[$name] } else { $null }
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
    $scopeLabel = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }
    Write-Host ("  Walking {0} ({1}, zone={2})..." -f $name, $scopeLabel, $zone) -ForegroundColor Cyan

    # Emit CSS_FILE anchor row
    $cssFileRow = Add-CssFileRow -LineEnd $script:CurrentFileLineCount

    # Emit FILE_HEADER row
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

    # Emit COMMENT_BANNER rows from the section list
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

    # Walk the AST via the generic visitor
    $afterHeaderCount = $script:rows.Count
    try {
        Invoke-AstWalk -Node $ast -Visitor $script:CssVisitor
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

    # FORBIDDEN_COMMENT_STYLE: scan for stray comments
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

# -- Pass 3: Cross-File Compliance Checks --

Write-Log "Pass 3: codebase-level drift checks..."

# -- One-time row indexes --

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

# -- FILE_NOT_REGISTERED --

# Files absent from the Object_Registry zone/scope map were stamped
# zone/scope '<undefined>' during the walk and recorded in
# $script:objectRegistryMisses. Attach the code to each such file's CSS_FILE
# anchor row so the gap surfaces in drift analysis, not only the miss report.
foreach ($missing in $script:objectRegistryMisses) {
    if ($script:cssFileRowByFile.ContainsKey($missing)) {
        Add-DriftCode -Row $script:cssFileRowByFile[$missing] -Code 'FILE_NOT_REGISTERED' `
            -Context "File '$missing' has no active Object_Registry row; zone and scope are '<undefined>'."
    }
}

# -- DUPLICATE_FOUNDATION / DUPLICATE_CHROME --

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

# -- FILE_ORG_MISMATCH --

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

# -- DRIFT_HEX_LITERAL --

foreach ($fname in $fileMeta.Keys) {
    $meta = $fileMeta[$fname]
    if ($null -eq $meta.HexLiterals -or $meta.HexLiterals.Count -eq 0) { continue }
    if ($meta.FoundationLine) { continue }

    if (-not $script:zoneScopeMap.ContainsKey($fname)) { continue }
    $fileZone   = $script:zoneScopeMap[$fname].Zone
    $zoneVarMap = Get-ZoneMap -ByZone $script:sharedVariableMapByZone -Zone $fileZone
    if ($zoneVarMap.Count -eq 0) { continue }

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

# -- DRIFT_PX_LITERAL --

foreach ($fname in $fileMeta.Keys) {
    $meta = $fileMeta[$fname]
    if ($null -eq $meta.PxLiterals -or $meta.PxLiterals.Count -eq 0) { continue }
    if ($meta.FoundationLine) { continue }

    if (-not $script:zoneScopeMap.ContainsKey($fname)) { continue }
    $fileZone   = $script:zoneScopeMap[$fname].Zone
    $zoneVarMap = Get-ZoneMap -ByZone $script:sharedVariableMapByZone -Zone $fileZone
    if ($zoneVarMap.Count -eq 0) { continue }

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

# -- EXCESS_BLANK_LINES and MISSING_BLANK_LINE_SEPARATOR --

# Two complementary checks share the same iteration over adjacent top-level
# constructs. The spec mandates exactly one blank line between every two
# adjacent top-level constructs (CC_CSS_Spec.md Section 13.1):
#   - Zero blank lines (gap == 1 line)              -> MISSING_BLANK_LINE_SEPARATOR
#   - More than one blank line (gap > 2 lines)      -> EXCESS_BLANK_LINES
#
# A purpose comment is part of the construct it introduces, not a standalone
# top-level construct. A non-banner comment immediately preceding a rule,
# at-rule, or :root (with no blank line between them) is bound to that
# construct; the comment + construct form one logical unit for blank-line
# discipline. Banner comments are their own units (banners themselves are
# top-level constructs per the spec).
#
# Implementation: walk $ast.nodes to build a list of logical-unit boundaries
# (UnitStart / UnitEnd pairs), then compare gaps between consecutive units.
foreach ($file in $CssFiles) {
    $name = [System.IO.Path]::GetFileName($file)
    if (-not $astCache.ContainsKey($file)) { continue }
    $ast = $astCache[$file].ast
    if ($null -eq $ast.nodes -or $ast.nodes.Count -lt 2) { continue }

    # Build the list of logical units. Each unit covers either a single
    # standalone construct or a purpose-comment + construct pair.
    $units = New-Object System.Collections.Generic.List[object]
    $ni = 0
    while ($ni -lt $ast.nodes.Count) {
        $n = $ast.nodes[$ni]
        $nStart = if ($n.source -and $n.source.start) { [int]$n.source.start.line } else { 0 }
        $nEnd   = if ($n.source -and $n.source.end)   { [int]$n.source.end.line   } else { $nStart }

        # If this is a non-banner comment and the next sibling sits exactly
        # one line below (no blank line), treat the pair as one unit. The
        # banner check uses Test-IsBannerComment so multi-line banner
        # comments are NOT collapsed with their following content.
        $isComment = ($n.type -eq 'comment')
        $isBanner  = $false
        if ($isComment) {
            $isBanner = Test-IsBannerComment -CommentText $n.text -ValidSectionTypes $script:ValidSectionTypes
        }

        if ($isComment -and -not $isBanner -and ($ni + 1) -lt $ast.nodes.Count) {
            $next = $ast.nodes[$ni + 1]
            $nextStart = if ($next.source -and $next.source.start) { [int]$next.source.start.line } else { 0 }
            $nextEnd   = if ($next.source -and $next.source.end)   { [int]$next.source.end.line   } else { $nextStart }
            if ($nStart -gt 0 -and $nextStart -gt 0 -and ($nextStart - $nEnd) -eq 1) {
                # Purpose comment + construct = one logical unit.
                $units.Add([pscustomobject]@{ UnitStart = $nStart; UnitEnd = $nextEnd })
                $ni += 2
                continue
            }
        }

        # Standalone unit (rule, at-rule, banner, or comment that is not
        # bound to a following construct).
        if ($nStart -gt 0) {
            $units.Add([pscustomobject]@{ UnitStart = $nStart; UnitEnd = $nEnd })
        }
        $ni++
    }

    # Compare gaps between consecutive logical units.
    $excessFound  = $false
    $missingFound = $false
    for ($ui = 1; $ui -lt $units.Count; $ui++) {
        $prevEnd  = $units[$ui - 1].UnitEnd
        $curStart = $units[$ui].UnitStart
        if ($prevEnd -gt 0 -and $curStart -gt 0) {
            $gap = $curStart - $prevEnd
            if ($gap -gt 2) { $excessFound = $true }
            if ($gap -eq 1) { $missingFound = $true }
            if ($excessFound -and $missingFound) { break }
        }
    }

    if (($excessFound -or $missingFound) -and $rowsByFile.ContainsKey($name)) {
        foreach ($r in $rowsByFile[$name]) {
            if ($r.ComponentType -eq 'CSS_FILE') {
                if ($excessFound)  { Add-DriftCode -Row $r -Code 'EXCESS_BLANK_LINES' }
                if ($missingFound) { Add-DriftCode -Row $r -Code 'MISSING_BLANK_LINE_SEPARATOR' }
                break
            }
        }
    }
}

# -- EMPTY_SECTION --

# A section banner must be followed by at least one cataloguable construct
# before the next banner or end-of-file (CC_CSS_Spec.md Section 13.1).
# The section list already records each section's body line range; if no
# row in the file falls within that range (other than the COMMENT_BANNER
# row itself), the section is empty.
foreach ($fname in $fileMeta.Keys) {
    $meta = $fileMeta[$fname]
    if (-not $meta.Sections) { continue }
    if (-not $rowsByFile.ContainsKey($fname)) { continue }

    foreach ($s in $meta.Sections) {
        # The section object's BodyStartLine and BodyEndLine define the
        # range of lines between this banner and the next banner (or
        # end-of-file). Built by New-SectionList.
        $bodyStart = $s.BodyStartLine
        $bodyEnd   = $s.BodyEndLine
        if ($null -eq $bodyStart -or $null -eq $bodyEnd) { continue }
        if ($bodyEnd -lt $bodyStart) { continue }

        $hasContent = $false
        foreach ($r in $rowsByFile[$fname]) {
            if ($r.ComponentType -eq 'COMMENT_BANNER')           { continue }
            if ($r.ComponentType -eq 'CSS_FILE')                 { continue }
            if ($r.ComponentType -eq 'FILE_HEADER')              { continue }
            if ($r.LineStart -ge $bodyStart -and $r.LineStart -le $bodyEnd) {
                $hasContent = $true
                break
            }
        }
        if (-not $hasContent) {
            # Find this section's COMMENT_BANNER row to attach the drift.
            foreach ($r in $rowsByFile[$fname]) {
                if ($r.ComponentType -eq 'COMMENT_BANNER' -and $r.LineStart -eq $s.BannerStartLine) {
                    Add-DriftCode -Row $r -Code 'EMPTY_SECTION'
                    break
                }
            }
        }
    }
}

# -- MISSING_TRAILING_NEWLINE --

# The file must end with `}` followed by exactly one newline (CC_CSS_Spec.md
# Section 13.1). Drift attaches to the CSS_FILE row.
foreach ($file in $CssFiles) {
    $name = [System.IO.Path]::GetFileName($file)
    if (-not $rowsByFile.ContainsKey($name)) { continue }

    try {
        $bytes = [System.IO.File]::ReadAllBytes($file)
        if ($bytes.Length -eq 0) { continue }
        $lastByte = $bytes[$bytes.Length - 1]
        # Accept LF (0x0A) only. CRLF files end with 0x0A as the final byte
        # so this naturally covers both LF and CRLF line endings.
        if ($lastByte -ne 0x0A) {
            foreach ($r in $rowsByFile[$name]) {
                if ($r.ComponentType -eq 'CSS_FILE') {
                    Add-DriftCode -Row $r -Code 'MISSING_TRAILING_NEWLINE'
                    break
                }
            }
        }
    } catch {
        Write-Log "Could not read trailing byte of ${file}: $($_.Exception.Message)" 'WARN'
    }
}

# -- PSEUDO_ELEMENT_OUT_OF_ORDER and VARIANT_BEFORE_BASE --

# Per CC_CSS_Spec.md Section 7.1, for each class:
#   base class definition < pseudo-element rule(s) < pseudo-class variant(s)
# A pseudo-element appearing before its base, or after a variant on the same
# class, is drift. A variant appearing before its base is also drift.
#
# Detection:
#   - "Base class definition" = CSS_CLASS DEFINITION row with variant_type
#     IS NULL AND signature NOT containing '::' (excludes pseudo-element
#     rules which are also CSS_CLASS DEFINITION).
#   - "Pseudo-element rule" = CSS_CLASS DEFINITION row whose signature
#     contains '::'.
#   - "Variant" = CSS_VARIANT DEFINITION row with variant_type='pseudo'.
# All comparisons are within a single file, scoped by component_name.
foreach ($fname in $fileMeta.Keys) {
    if (-not $rowsByFile.ContainsKey($fname)) { continue }

    # Group rows by class component_name, classifying each row's role.
    $classInfo = @{}
    foreach ($r in $rowsByFile[$fname]) {
        if ($r.ReferenceType -ne 'DEFINITION') { continue }
        if ($r.ComponentType -notin @('CSS_CLASS','CSS_VARIANT')) { continue }
        if ([string]::IsNullOrEmpty($r.ComponentName)) { continue }

        $cname = $r.ComponentName
        if (-not $classInfo.ContainsKey($cname)) {
            $classInfo[$cname] = @{
                BaseLine      = $null
                PseudoElements = New-Object System.Collections.Generic.List[object]
                Variants       = New-Object System.Collections.Generic.List[object]
            }
        }

        $sigHasPseudoElement = ($r.Signature -and $r.Signature -match '::')
        if ($r.ComponentType -eq 'CSS_CLASS' -and -not $sigHasPseudoElement) {
            # Base class definition. If multiple, keep the earliest line as
            # the canonical "base" for ordering comparisons.
            if ($null -eq $classInfo[$cname].BaseLine -or $r.LineStart -lt $classInfo[$cname].BaseLine) {
                $classInfo[$cname].BaseLine = $r.LineStart
            }
        } elseif ($r.ComponentType -eq 'CSS_CLASS' -and $sigHasPseudoElement) {
            $classInfo[$cname].PseudoElements.Add($r)
        } elseif ($r.ComponentType -eq 'CSS_VARIANT') {
            $classInfo[$cname].Variants.Add($r)
        }
    }

    foreach ($cname in $classInfo.Keys) {
        $info = $classInfo[$cname]
        $baseLine = $info.BaseLine

        # VARIANT_BEFORE_BASE: any variant whose line is less than the base.
        # If there is no base, the variant is also "before" a non-existent
        # base - UNDEFINED_CLASS_USAGE covers that case via a different
        # signal, so we only fire VARIANT_BEFORE_BASE when a base exists.
        if ($null -ne $baseLine) {
            foreach ($v in $info.Variants) {
                if ($v.LineStart -lt $baseLine) {
                    Add-DriftCode -Row $v -Code 'VARIANT_BEFORE_BASE'
                }
            }
        }

        # PSEUDO_ELEMENT_OUT_OF_ORDER: a pseudo-element row appears
        # (a) before its base, OR
        # (b) after any variant on the same class.
        if ($info.PseudoElements.Count -gt 0) {
            $earliestVariantLine = $null
            foreach ($v in $info.Variants) {
                if ($null -eq $earliestVariantLine -or $v.LineStart -lt $earliestVariantLine) {
                    $earliestVariantLine = $v.LineStart
                }
            }
            foreach ($pe in $info.PseudoElements) {
                $beforeBase = ($null -ne $baseLine -and $pe.LineStart -lt $baseLine)
                $afterVariant = ($null -ne $earliestVariantLine -and $pe.LineStart -gt $earliestVariantLine)
                if ($beforeBase -or $afterVariant) {
                    Add-DriftCode -Row $pe -Code 'PSEUDO_ELEMENT_OUT_OF_ORDER'
                }
            }
        }
    }
}

# -- UNDEFINED_CLASS_USAGE --

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
    # Transitional shim: Invoke-AssetRegistryBulkInsert still takes the FK map
    # as object_name -> registry_id. Project it from the combined zone/scope
    # map (which now carries RegistryId) until the bulk insert is updated to
    # accept the combined shape directly, at which point this shim is removed.
    $objectRegistryMap = @{}
    foreach ($objName in $script:zoneScopeMap.Keys) {
        $objectRegistryMap[$objName] = $script:zoneScopeMap[$objName].RegistryId
    }

    $inserted = Invoke-AssetRegistryBulkInsert `
        -ServerInstance     $script:XFActsServerInstance `
        -Database           $script:XFActsDatabase `
        -Rows               $script:rows `
        -ObjectRegistryMap  $objectRegistryMap `
        -Misses             $script:objectRegistryMisses
    Write-Log ("Inserted {0} rows into dbo.Asset_Registry." -f $inserted) 'SUCCESS'
}
catch {
    Write-Log "Bulk insert failed: $($_.Exception.Message)" 'ERROR'
    exit 1
}

# -- Object_Registry Miss Report --

if ($script:objectRegistryMisses.Count -gt 0) {
    Write-Log ("Object_Registry registration gaps detected for {0} file(s):" -f $script:objectRegistryMisses.Count) 'WARN'
    foreach ($missing in ($script:objectRegistryMisses | Sort-Object)) {
        Write-Log ("  MISSING: $missing") 'WARN'
    }
    Write-Log "Add the file(s) above to dbo.Object_Registry to enable FK linkage on subsequent runs." 'WARN'
}

Write-Log "Done."
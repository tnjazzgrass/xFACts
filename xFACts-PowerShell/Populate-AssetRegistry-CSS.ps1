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
    variant shape helpers, per-row emitters, the visitor scriptblock body)
    lives here.

.PARAMETER Execute
    Required to actually delete the CSS rows from Asset_Registry and write
    the new row set. Without this flag, runs in preview mode.

.NOTES
    File Name : Populate-AssetRegistry-CSS.ps1
    Location  : E:\xFACts-PowerShell
    Version   : Tracked in dbo.System_Metadata (component: ControlCenter.AssetRegistry)

================================================================================
CHANGELOG
================================================================================
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

$env:NODE_PATH = $NodeLibsPath

# ============================================================================
# SPEC CONSTANTS
# ============================================================================

# The six enumerated section types, in required order (CC_CSS_Spec.md Section 4).
$SectionTypeOrder  = @('FOUNDATION', 'CHROME', 'LAYOUT', 'CONTENT', 'OVERRIDES', 'FEEDBACK_OVERLAYS')
$ValidSectionTypes = $SectionTypeOrder

# Drift code -> human description mapping. Used by Add-DriftCode (helpers)
# to validate codes and to populate drift_text. Keep aligned with CC_CSS_Spec.md
# Section 16. Codes the spec defines but which are detected in Pass 3 still
# appear here so attachment doesn't fail on the master-table check.
$DriftDescriptions = [ordered]@{
    # File header
    'MALFORMED_FILE_HEADER'             = "The file's header block is missing, malformed, or contains required fields out of order."
    'FORBIDDEN_CHANGELOG_BLOCK'         = "The file header contains a CHANGELOG block. CHANGELOG blocks are not allowed in CSS file headers."
    'FILE_ORG_MISMATCH'                 = "The FILE ORGANIZATION list in the header does not exactly match the section banner titles in the file body, by content or by order."
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
    'MALFORMED_PREFIX_VALUE'            = "A section banner's Prefix line declares anything other than a single 3-character lowercase prefix or (none)."
    'PREFIX_REGISTRY_MISMATCH'          = "A section banner's declared prefix does not match Component_Registry.cc_prefix for the file's component."
    'DUPLICATE_FOUNDATION'              = "More than one CSS file in the codebase contains a FOUNDATION section."
    'DUPLICATE_CHROME'                  = "More than one CSS file in the codebase contains a CHROME section."
    # Class definitions
    'PREFIX_MISMATCH'                   = "A class name does not begin with the prefix declared in its containing section's banner."
    'MISSING_PURPOSE_COMMENT'           = "A base class definition is not preceded by a single-line purpose comment."
    'MISSING_VARIANT_COMMENT'           = "A class variant does not carry a trailing inline comment after the opening brace."
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
                foreach ($cmp in $compounds) {
                    if ($cmp.Classes.Count -gt 0) {
                        $primaryClass = $cmp.Classes[0]
                        if (-not $classMap.ContainsKey($primaryClass)) {
                            $classMap[$primaryClass] = $name
                        }
                        break
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

function Add-CssClassOrVariantRow {
    param(
        [string]$ComponentName,
        [string]$VariantType,
        [string]$VariantQualifier1,
        [string]$VariantQualifier2,
        [string]$ReferenceType,
        [int]$LineStart, [int]$LineEnd, [int]$ColumnStart,
        [string]$Signature, [string]$ParentAtrule, [string]$RawText,
        [string]$PurposeDescription
    )

    if ([string]::IsNullOrWhiteSpace($ComponentName)) { return $null }

    $componentType = if ($VariantType) { 'CSS_VARIANT' } else { 'CSS_CLASS' }

    $scope = $null
    $sourceFile = $null
    if ($ReferenceType -eq 'DEFINITION') {
        $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }
        $sourceFile = $script:CurrentFile
    } else {
        $resolved = Resolve-ClassScope -ClassName $ComponentName
        $scope = $resolved.Scope
        $sourceFile = $resolved.SourceFile
    }

    $vq1Key = if ($VariantQualifier1) { $VariantQualifier1 } else { '' }
    $vq2Key = if ($VariantQualifier2) { $VariantQualifier2 } else { '' }
    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|$componentType|$ComponentName|$ReferenceType|$vq1Key|$vq2Key"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $row = New-CssRow `
        -ComponentType      $componentType `
        -ComponentName      $ComponentName `
        -VariantType        $VariantType `
        -VariantQualifier1  $VariantQualifier1 `
        -VariantQualifier2  $VariantQualifier2 `
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
# Banner-level drift codes from Get-BannerInfo (BANNER_INLINE_SHAPE,
# BANNER_INVALID_RULE_CHAR, BANNER_INVALID_RULE_LENGTH, BANNER_INVALID_SEPARATOR_CHAR,
# BANNER_INVALID_SEPARATOR_LENGTH, BANNER_MALFORMED_TITLE_LINE, BANNER_MISSING_DESCRIPTION,
# UNKNOWN_SECTION_TYPE, MISSING_PREFIX_DECLARATION) come pre-populated on the
# section's BannerDriftCodes array. SECTION_TYPE_ORDER_VIOLATION,
# MALFORMED_PREFIX_VALUE, and PREFIX_REGISTRY_MISMATCH are added here based on
# cross-section / cross-registry information.
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

    # Carry over per-banner drift accumulated by Get-BannerInfo / New-SectionList
    # (BANNER_INLINE_SHAPE, BANNER_INVALID_RULE_CHAR, BANNER_INVALID_RULE_LENGTH,
    # BANNER_INVALID_SEPARATOR_CHAR, BANNER_INVALID_SEPARATOR_LENGTH,
    # BANNER_MALFORMED_TITLE_LINE, BANNER_MISSING_DESCRIPTION,
    # UNKNOWN_SECTION_TYPE, MISSING_PREFIX_DECLARATION).
    # Get-BannerInfo distinguishes these granularly - the helper emits
    # UNKNOWN_SECTION_TYPE only when the title shape is correct but the
    # TYPE token is not in the enum, and BANNER_MALFORMED_TITLE_LINE when
    # no TYPE: NAME shape exists at all. The populator does not need to
    # re-derive UNKNOWN_SECTION_TYPE from a null TypeName.
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

    # MALFORMED_PREFIX_VALUE: Prefix line declared something that isn't a
    # 3-char lowercase token or (none).
    if ($Section.Prefix -and -not (Test-PrefixValueIsValid -Prefix $Section.Prefix)) {
        Add-DriftCode -Row $row -Code 'MALFORMED_PREFIX_VALUE' `
            -Context "Banner declares Prefix '$($Section.Prefix)' which is neither a 3-char lowercase prefix nor (none)."
    }

    # PREFIX_REGISTRY_MISMATCH (CSS strict / Option B):
    #   - File has registry mapping with cc_prefix = NULL  -> banner must be (none).
    #     Any non-(none) value is a mismatch.
    #   - File has registry mapping with cc_prefix = X     -> banner must be X.
    #     Any other value (including (none)) is a mismatch.
    #   - File has no registry mapping at all              -> we cannot validate.
    #     Skip this check; the file's missing Object_Registry row will be
    #     reported separately by the miss advisory.
    if ($script:CurrentRegistryHasMapping -and $Section.Prefix) {
        # Only check when the prefix value is well-formed; malformed values
        # already carry their own drift code.
        if (Test-PrefixValueIsValid -Prefix $Section.Prefix) {
            $bannerVal = Get-BannerPrefixValue -Prefix $Section.Prefix   # '' for (none)
            $isNone    = Test-IsPrefixNone -Prefix $Section.Prefix
            $regVal    = $script:CurrentRegistryPrefix                    # $null or 'xxx'

            $mismatch = $false
            if ($null -eq $regVal) {
                if (-not $isNone) { $mismatch = $true }
            } else {
                if ($isNone -or $bannerVal -ne $regVal) { $mismatch = $true }
            }

            if ($mismatch) {
                $regDisplay = if ($null -eq $regVal) { '(none)' } else { $regVal }
                $bannerDisplay = if ($isNone) { '(none)' } else { $bannerVal }
                Add-DriftCode -Row $row -Code 'PREFIX_REGISTRY_MISMATCH' `
                    -Context "Banner declares Prefix '$bannerDisplay' but Component_Registry says cc_prefix = '$regDisplay' for this file."
            }
        }
    }

    return $row
}

# ============================================================================
# PER-COMPOUND DRIFT ATTRIBUTION
# ============================================================================

# Apply every per-compound drift check to a row. Single source of truth for
# "what's wrong with this compound", so primary and descendant emission paths
# produce identical drift coverage.
function Add-CompoundDriftCodes {
    param(
        [Parameter(Mandatory)] $Row,
        [Parameter(Mandatory)] $Compound,
        [Parameter(Mandatory)] [int]$ExtraClassCount,
        [bool]$IsPartOfGroup = $false,
        [bool]$InDescendant = $false
    )

    if ($ExtraClassCount -ge 2)        { Add-DriftCode -Row $Row -Code 'COMPOUND_DEPTH_3PLUS' }
    if ($Compound.PseudoInterleaved)   { Add-DriftCode -Row $Row -Code 'PSEUDO_INTERLEAVED' }
    if ($Compound.Pseudos.Count -ge 2) { Add-DriftCode -Row $Row -Code 'FORBIDDEN_STACKED_PSEUDO' }
    if ($Compound.Pseudos -contains 'not') { Add-DriftCode -Row $Row -Code 'FORBIDDEN_NOT_PSEUDO' }
    if ($Compound.Ids.Count -gt 0)     { Add-DriftCode -Row $Row -Code 'FORBIDDEN_ID_SELECTOR' }

    # Element / universal / attribute selectors are forbidden EXCEPT in
    # FOUNDATION sections. Look up the active section for this row's line.
    $sec = Get-SectionForLine -Sections $script:CurrentSections -Line $Row.LineStart
    $inFoundation = ($sec -and $sec.TypeName -eq 'FOUNDATION')

    if ($Compound.AttrCount -gt 0 -and -not $inFoundation) {
        Add-DriftCode -Row $Row -Code 'FORBIDDEN_ATTRIBUTE_SELECTOR'
    }
    if ($Compound.HasTag -and -not $inFoundation) {
        Add-DriftCode -Row $Row -Code 'FORBIDDEN_ELEMENT_SELECTOR'
    }
    if ($IsPartOfGroup) {
        Add-DriftCode -Row $Row -Code 'FORBIDDEN_GROUP_SELECTOR'
    }
    if ($InDescendant) {
        # Distinguish combinator types from CombinatorBefore for finer-grained drift.
        switch ($Compound.CombinatorBefore) {
            '>' { Add-DriftCode -Row $Row -Code 'FORBIDDEN_CHILD_COMBINATOR' }
            '+' { Add-DriftCode -Row $Row -Code 'FORBIDDEN_ADJACENT_SIBLING' }
            '~' { Add-DriftCode -Row $Row -Code 'FORBIDDEN_GENERAL_SIBLING' }
            default { Add-DriftCode -Row $Row -Code 'FORBIDDEN_DESCENDANT' }
        }
    }
}

# Compute (variant_type, variant_qualifier_1, variant_qualifier_2) from a
# compound's class and pseudo collections.
function Get-VariantShape {
    param([Parameter(Mandatory)] $Compound)

    $extraClasses = if ($Compound.Classes.Count -gt 1) { $Compound.Classes[1..($Compound.Classes.Count-1)] } else { @() }
    $extraPseudos = $Compound.Pseudos

    $variantType = $null; $q1 = $null; $q2 = $null

    if ($extraClasses.Count -eq 0 -and $extraPseudos.Count -eq 0) {
        $variantType = $null
    }
    elseif ($extraClasses.Count -ge 1 -and $extraPseudos.Count -eq 0) {
        $variantType = 'class'
        $q1 = ($extraClasses -join '.')
    }
    elseif ($extraClasses.Count -eq 0 -and $extraPseudos.Count -ge 1) {
        $variantType = 'pseudo'
        $q2 = ($extraPseudos -join ':')
    }
    else {
        $variantType = 'compound_pseudo'
        $q1 = ($extraClasses -join '.')
        $q2 = ($extraPseudos -join ':')
    }

    return @{
        VariantType        = $variantType
        VariantQualifier1  = $q1
        VariantQualifier2  = $q2
        ExtraClassCount    = $extraClasses.Count
    }
}

# ============================================================================
# PER-SELECTOR ROW GENERATION
# ============================================================================

# Decompose a selector into compounds (classes / ids / pseudos), then emit
# one or more catalog rows. If any forbidden constructs are present, the
# emitted rows carry the appropriate drift codes.
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
    $inFoundation = ($activeSection -and $activeSection.TypeName -eq 'FOUNDATION')

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
                # Use combinator from the second compound for finer-grained drift.
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

    # ---- PRIMARY: class side ----
    if ($primary.Classes.Count -gt 0) {
        $primaryName = $primary.Classes[0]
        $shape = Get-VariantShape -Compound $primary

        # Variants take the trailing inline comment; bases take the preceding.
        $purposeDesc = if ($shape.VariantType) { $TrailingInlineCommentText } else { $PrecedingCommentText }

        $primaryRow = Add-CssClassOrVariantRow `
            -ComponentName     $primaryName `
            -VariantType       $shape.VariantType `
            -VariantQualifier1 $shape.VariantQualifier1 `
            -VariantQualifier2 $shape.VariantQualifier2 `
            -ReferenceType     'DEFINITION' `
            -LineStart         $LineStart -LineEnd $LineEnd -ColumnStart $ColumnStart `
            -Signature         $RuleSelectorText -ParentAtrule $ParentAtrule -RawText $RuleBodyText `
            -PurposeDescription $purposeDesc

        if ($primaryRow) {
            Add-CompoundDriftCodes -Row $primaryRow -Compound $primary `
                -ExtraClassCount $shape.ExtraClassCount `
                -IsPartOfGroup $IsPartOfGroup -InDescendant $false

            # The primary participates in a descendant-combinator selector when
            # there are additional compounds; flag it with the combinator-aware
            # drift code derived from the next compound's CombinatorBefore.
            if ($hasMultipleCompounds) {
                switch ($compounds[$primaryIdx + 1].CombinatorBefore) {
                    '>' { Add-DriftCode -Row $primaryRow -Code 'FORBIDDEN_CHILD_COMBINATOR' }
                    '+' { Add-DriftCode -Row $primaryRow -Code 'FORBIDDEN_ADJACENT_SIBLING' }
                    '~' { Add-DriftCode -Row $primaryRow -Code 'FORBIDDEN_GENERAL_SIBLING' }
                    default { Add-DriftCode -Row $primaryRow -Code 'FORBIDDEN_DESCENDANT' }
                }
            }

            # Comment-presence drift
            if ($shape.VariantType -and -not $HasTrailingInlineComment) {
                Add-DriftCode -Row $primaryRow -Code 'MISSING_VARIANT_COMMENT'
            }
            elseif (-not $shape.VariantType -and -not $HasPrecedingComment) {
                Add-DriftCode -Row $primaryRow -Code 'MISSING_PURPOSE_COMMENT'
            }

            # Section context drift
            if (-not $activeSection) {
                Add-DriftCode -Row $primaryRow -Code 'MISSING_SECTION_BANNER'
            }
            elseif ($activeSection.PrefixValue) {
                # PREFIX_MISMATCH: when the active section declares a real
                # prefix (not (none)), the class name must start with that
                # prefix followed by '-' (or be exactly the prefix).
                $pfx = $activeSection.PrefixValue
                $matched = ($primaryName -ceq $pfx) -or
                           ($primaryName.StartsWith("$pfx-", [System.StringComparison]::Ordinal))
                if (-not $matched) {
                    Add-DriftCode -Row $primaryRow -Code 'PREFIX_MISMATCH'
                }
            }
        }
    }

    # ---- PRIMARY: id side ----
    if ($primary.Ids.Count -gt 0) {
        foreach ($idName in $primary.Ids) {
            $idRow = Add-HtmlIdRow -IdName $idName -ReferenceType 'DEFINITION' `
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
                if (-not $activeSection)   { Add-DriftCode -Row $idRow -Code 'MISSING_SECTION_BANNER' }
            }
        }
    }

    # ---- DESCENDANT compounds (USAGE rows for class-side, plus id-side) ----
    for ($i = $primaryIdx + 1; $i -lt $compounds.Count; $i++) {
        $cmp = $compounds[$i]

        if ($cmp.Classes.Count -gt 0) {
            $usageName = $cmp.Classes[0]
            $shape = Get-VariantShape -Compound $cmp

            $usageRow = Add-CssClassOrVariantRow `
                -ComponentName     $usageName `
                -VariantType       $shape.VariantType `
                -VariantQualifier1 $shape.VariantQualifier1 `
                -VariantQualifier2 $shape.VariantQualifier2 `
                -ReferenceType     'USAGE' `
                -LineStart         $LineStart -LineEnd $LineEnd -ColumnStart $ColumnStart `
                -Signature         $RuleSelectorText -ParentAtrule $ParentAtrule -RawText $RuleBodyText `
                -PurposeDescription $null

            if ($usageRow) {
                Add-CompoundDriftCodes -Row $usageRow -Compound $cmp `
                    -ExtraClassCount $shape.ExtraClassCount `
                    -IsPartOfGroup $IsPartOfGroup -InDescendant $true
            }
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
            # If any line appears more than once in $declLines, the rule has a
            # compound-declaration violation. Attach to the rule's primary row(s).
            $declLineCounts = @{}
            foreach ($dl in $declLines) {
                if (-not $declLineCounts.ContainsKey($dl)) { $declLineCounts[$dl] = 0 }
                $declLineCounts[$dl]++
            }
            $hasCompoundDecl = @($declLineCounts.Values | Where-Object { $_ -gt 1 }).Count -gt 0
            if ($hasCompoundDecl) {
                # Attach to every row this rule emitted (CSS_CLASS / CSS_VARIANT
                # / CSS_RULE / HTML_ID rows). We iterate just the rule-scoped
                # slice of $script:rows captured before selector emission.
                for ($ri = $ruleRowsStartIdx; $ri -lt $script:rows.Count; $ri++) {
                    $r = $script:rows[$ri]
                    if ($r.ComponentType -in @('CSS_CLASS','CSS_VARIANT','CSS_RULE','HTML_ID')) {
                        Add-DriftCode -Row $r -Code 'FORBIDDEN_COMPOUND_DECLARATION'
                    }
                }
            }

            # BLANK_LINE_INSIDE_RULE: a blank line appears inside the rule body
            # when there's a gap between consecutive decls' source ranges that
            # is more than 1 line, OR when the first decl starts more than 1
            # line after the rule's opening line, OR when the rule's closing
            # line is more than 1 line after the last decl's end.
            # Using each decl's actual end line (not just start line) avoids
            # false positives on multi-line declarations.
            $hasBlankInside = $false
            if ($declSpans.Count -gt 0) {
                # Sort spans by Start in case PostCSS ever delivers them out of order.
                $sortedSpans = @($declSpans | Sort-Object { $_.Start })

                # Gap before first decl: opening line $line, first decl on >= $line + 2 means blank.
                if ($sortedSpans[0].Start -gt ($line + 1)) {
                    $hasBlankInside = $true
                }
                # Gaps between consecutive decls.
                for ($si = 1; $si -lt $sortedSpans.Count; $si++) {
                    $prevEnd = $sortedSpans[$si - 1].End
                    $curStart = $sortedSpans[$si].Start
                    if ($curStart - $prevEnd -gt 1) {
                        $hasBlankInside = $true
                        break
                    }
                }
                # Gap after last decl: closing line $endLine, last decl ending at <= $endLine - 2 means blank.
                if (-not $hasBlankInside) {
                    $lastEnd = $sortedSpans[$sortedSpans.Count - 1].End
                    if ($endLine - $lastEnd -gt 1) {
                        $hasBlankInside = $true
                    }
                }
            }
            if ($hasBlankInside) {
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
            # 'root', 'decl', and any unknown node types fall through to the
            # walker's default recursion. 'decl' nodes are processed inline
            # by their parent rule above (and skipped in the walker's skip
            # list via 'prop','important','value'); decls outside a rule
            # (which would be a parse error in valid CSS) reach this branch
            # but produce no row.
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
    # A stray comment is a block comment that is none of:
    #   - The file header (line 1)
    #   - A section banner (in $script:CurrentSections)
    #   - A sub-section marker (text matches /^\s*--.+--\s*$/)
    #   - Used as a preceding comment for a rule (recorded in CurrentUsedCommentLines)
    #   - Used as a trailing inline comment for a rule (recorded in CurrentUsedCommentLines)
    $strayLines = New-Object System.Collections.Generic.List[int]
    foreach ($c in $script:CurrentNormalizedComments) {
        if ($c.Type -ne 'Block') { continue }
        if ($script:CurrentUsedCommentLines.Contains([int]$c.LineStart)) { continue }
        # Sub-section marker: trim the comment text and check the marker shape.
        $trimmedText = if ($c.Text) { $c.Text.Trim() } else { '' }
        if ($trimmedText -match '^--.+--$') { continue }
        # If we got here, it's a stray block comment.
        $strayLines.Add([int]$c.LineStart)
    }
    if ($strayLines.Count -gt 0 -and $headerRow) {
        $linesText = ($strayLines | Sort-Object) -join ', '
        Add-DriftCode -Row $headerRow -Code 'FORBIDDEN_COMMENT_STYLE' `
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
# Pass 3 was nested-looping $script:rows from inside per-file / per-literal
# loops, producing O(files x literals x rows) iterations. With several
# thousand rows and hundreds of literals per file, that runs into millions
# of comparisons in interpreted PowerShell. Build two indexes once, up
# front, and look up directly. Each section below uses whichever index
# fits its access pattern.
$rowsByFile = @{}             # filename -> List[row]
$rowsByFileLineType = @{}     # "filename|line|componentType" -> List[row]
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
# Heuristic: any hex literal in a non-FOUNDATION-bearing file's class
# declaration is flagged when the consumer's zone has at least one shared
# variable defined. Custom-property values are mostly colors, so this catches
# the meaningful pattern; some false positives possible on non-color hex.
foreach ($fname in $fileMeta.Keys) {
    $meta = $fileMeta[$fname]
    if ($null -eq $meta.HexLiterals -or $meta.HexLiterals.Count -eq 0) { continue }
    if ($meta.FoundationLine) { continue }   # FOUNDATION-bearing file's hex literals are tokens

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
# Same heuristic shape as DRIFT_HEX_LITERAL but filtered against --size-*
# tokens specifically. If the consumer's zone has any size tokens defined,
# every px literal in a non-FOUNDATION-bearing file's class declaration is
# flagged.
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
# Any file with blank lines beyond the single blank that the spec permits
# between top-level constructs gets the code on its FILE_HEADER row.
# We don't have direct access to the source file's lines from the AST, so
# the detection compares each top-level node's start line to the previous
# node's end line; a gap of more than 2 means there are 2+ blank lines
# between them.
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
            if ($r.ComponentType -eq 'FILE_HEADER') {
                Add-DriftCode -Row $r -Code 'EXCESS_BLANK_LINES'
                break
            }
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
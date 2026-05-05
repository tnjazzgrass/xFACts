<#
.SYNOPSIS
    xFACts - Asset Registry JavaScript Populator (spec-aware)

.DESCRIPTION
    Walks every .js file under the Control Center public/js and public/docs/js
    directories, parses each file with Acorn (via parse-js.js Node helper),
    and generates Asset_Registry rows describing every catalogable component
    found in the file plus drift codes against CC_JS_Spec.md.

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
      * FILE_HEADER DEFINITION rows for the file's opening header block
      * COMMENT_BANNER DEFINITION rows for each section banner
      * JS_IMPORT DEFINITION rows for ES module imports / require statements
      * JS_CONSTANT DEFINITION rows for module-scope const declarations
        in CONSTANTS sections
      * JS_STATE DEFINITION rows for module-scope var declarations
        in STATE sections
      * JS_FUNCTION DEFINITION rows for top-level functions in FUNCTIONS
        sections (excluding the PAGE LIFECYCLE HOOKS banner)
      * JS_HOOK DEFINITION rows for functions inside the PAGE LIFECYCLE HOOKS
        banner (onPageRefresh, onPageResumed, onSessionExpired, etc.)
      * JS_CLASS DEFINITION rows for top-level class declarations
      * JS_METHOD DEFINITION rows for methods inside class bodies
      * JS_TIMER DEFINITION rows for setInterval/setTimeout assigned to a
        state-variable handle
      * JS_FUNCTION USAGE rows for calls to same-file or cc-shared.js functions

    Group C - JS event bindings:
      * JS_EVENT USAGE rows for addEventListener calls and direct
        .on<event> = ... assignments

    Spec enforcement (CC_JS_Spec.md):
      * Section type validation (IMPORTS, CONSTANTS, STATE, INITIALIZATION,
        FUNCTIONS for page files; FOUNDATION and CHROME added for cc-shared.js)
      * Section ordering enforcement
      * Banner format validation (TYPE: NAME header + Prefix: declaration)
      * Page-prefix enforcement on top-level identifiers
      * Mandatory preceding comment for every cataloged definition,
        captured into purpose_description
      * Forbidden-pattern detection: let, multi-declarations, IIFE, eval,
        document.write, window.X assignment outside cc-shared.js, inline
        style/script in templates, conditional definitions, file-scope //
        line comments, CHANGELOG blocks
      * Cross-file shadowing detection (page redefines cc-shared.js export)
      * FILE ORGANIZATION list cross-validation against actual banners

    Run AFTER the CSS populator has loaded all CSS_CLASS DEFINITION rows.

.NOTES
    File Name      : Populate-AssetRegistry-JS.ps1
    Location       : E:\xFACts-PowerShell
    Author         : Frost Arnett Applications Team

.PARAMETER Execute
    Required to actually wipe the JS rows from Asset_Registry and write the
    new row set. Without this flag, runs in preview mode: parses every file,
    builds the row set in memory, prints summary statistics, but does NOT
    touch the database.

.PARAMETER FileFilter
    Optional file-name filter for processing a single file or subset
    (e.g., -FileFilter 'cc-shared.js' processes only that file). Without this
    parameter, all .js files in the scan roots are processed.

CHANGELOG
2026-05-04  Spec-aware rewrite. Adopts CC_JS_Spec.md as the authoritative
            structural contract. New row types: JS_STATE, JS_HOOK, JS_TIMER,
            FILE_HEADER. Section-aware drift detection: banner format/order,
            prefix mismatch, missing comments, wrong declaration keyword,
            forbidden patterns. Schema cleanup: removed references to dropped
            columns (state_modifier, component_subtype, parent_object,
            design_notes, related_asset_id, is_active filter on Asset_Registry).
            Comment-text capture into purpose_description for every cataloged
            definition (G-INIT-4 plumbing pattern). FILE ORGANIZATION cross-
            validation against actual banners. Cross-file shadowing detection
            for cc-shared.js exports. Verification queries bundled for
            development; remove when promoting to production.
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

Initialize-XFActsScript -ScriptName 'Populate-AssetRegistry-JS' -Execute:$Execute

$ErrorActionPreference = 'Stop'

# ============================================================================
# CONFIGURATION
# ============================================================================

$NodeExe        = 'C:\Program Files\nodejs\node.exe'
$NodeLibsPath   = 'C:\Program Files\nodejs-libs\node_modules'
$ParseJsScript  = "$PSScriptRoot\parse-js.js"

$CcRoot = 'E:\xFACts-ControlCenter'
$JsScanRoots = @(
    "$CcRoot\public\js"
    "$CcRoot\public\docs\js"
)

# Files whose top-level definitions are visible to multiple consumer files.
# Definitions in these files get scope=SHARED.
#
# Control Center zone:
#   cc-shared.js     - the spec-compliant shared file (post-migration)
#   engine-events.js - the legacy shared file (alias during migration)
#
# Documentation site zone:
#   nav.js, docs-controlcenter.js, ddl-erd.js, ddl-loader.js
#
# During migration, both cc-shared.js and engine-events.js may exist.
# Once the migration completes, engine-events.js is removed from this list
# and from the codebase.
$SharedFiles = @(
    'cc-shared.js',
    'engine-events.js',
    'nav.js',
    'docs-controlcenter.js',
    'ddl-erd.js',
    'ddl-loader.js'
)

# The single canonical CC-zone shared file. Used for FOUNDATION/CHROME
# section uniqueness checks. After migration, this is cc-shared.js. During
# migration, fall back to engine-events.js if cc-shared.js does not yet exist.
$CanonicalSharedFile = 'cc-shared.js'

$env:NODE_PATH = $NodeLibsPath

# Recognized section types per CC_JS_Spec.md
$ValidSectionTypes = @(
    'IMPORTS',
    'FOUNDATION',
    'CHROME',
    'CONSTANTS',
    'STATE',
    'INITIALIZATION',
    'FUNCTIONS'
)

# Required ordering of section types. Lower index = earlier in file.
$SectionTypeOrder = @{
    'IMPORTS'        = 1
    'FOUNDATION'     = 2
    'CHROME'         = 3
    'CONSTANTS'      = 4
    'STATE'          = 5
    'INITIALIZATION' = 6
    'FUNCTIONS'      = 7
}

# Section types limited to single-banner-only (no multiple banners of this
# type allowed in one file).
$SingleBannerTypes = @('IMPORTS', 'INITIALIZATION')

# Section types allowed only in cc-shared.js
$SharedOnlySectionTypes = @('FOUNDATION', 'CHROME')

# The fixed banner name for the page lifecycle hooks group
$HooksBannerName = 'PAGE LIFECYCLE HOOKS'

# The five recognized hook function names. These are the API contract with
# cc-shared.js; the shared module probes for each via typeof check.
$RecognizedHookNames = @(
    'onPageRefresh',
    'onPageResumed',
    'onSessionExpired',
    'onEngineProcessCompleted',
    'onEngineEventRaw'
)
# ============================================================================
# ROW BUILDER STATE
# ============================================================================

$rows       = New-Object System.Collections.Generic.List[object]
$dedupeKeys = New-Object 'System.Collections.Generic.HashSet[string]'

# Per-file drift tracking, keyed by file_name. The FILE_HEADER row carries
# file-level drift codes (MALFORMED_FILE_HEADER, FILE_ORG_MISMATCH,
# FORBIDDEN_CHANGELOG_BLOCK, etc.). Cross-file checks (DUPLICATE_FOUNDATION,
# DUPLICATE_CHROME, SHADOWS_SHARED_FUNCTION) need to attach drift to specific
# rows after Pass 2 completes; we keep references to those rows here.
$fileHeaderRowByFile = @{}

# Track which files declare FOUNDATION or CHROME sections so we can flag
# DUPLICATE_FOUNDATION / DUPLICATE_CHROME if more than one file does so.
$foundationFiles = New-Object System.Collections.Generic.List[string]
$chromeFiles     = New-Object System.Collections.Generic.List[string]

function Test-AddDedupeKey {
    param([string]$Key)
    return $script:dedupeKeys.Add($Key)
}

# Compute occurrence_index for each (file_name, component_name, reference_type)
# tuple. Run as a post-processing pass over the collected rows so we don't
# have to track counters during extraction.
function Set-OccurrenceIndices {
    param([System.Collections.Generic.List[object]]$Rows)

    $counters = @{}
    foreach ($r in $Rows) {
        $key = "$($r.FileName)|$($r.ComponentName)|$($r.ReferenceType)"
        if (-not $counters.ContainsKey($key)) {
            $counters[$key] = 0
        }
        $counters[$key]++
        $r.OccurrenceIndex = $counters[$key]
    }
}

# Standardized row builder. Returns an ordered hashtable with every column
# the bulk-insert DataTable expects.
function New-AssetRow {
    param(
        [string]$FileName,
        [int]$LineStart,
        [int]$LineEnd,
        [int]$ColumnStart,
        [string]$ComponentType,
        [string]$ComponentName,
        [string]$ReferenceType,
        [string]$Scope,
        [string]$SourceFile,
        [string]$SourceSection,
        [string]$Signature,
        [string]$ParentFunction,
        [string]$RawText,
        [string]$PurposeDescription
    )

    return [ordered]@{
        FileName           = $FileName
        FileType           = 'JS'
        LineStart          = $LineStart
        LineEnd            = if ($LineEnd) { $LineEnd } else { $LineStart }
        ColumnStart        = $ColumnStart
        ComponentType      = $ComponentType
        ComponentName      = $ComponentName
        ReferenceType      = $ReferenceType
        Scope              = $Scope
        SourceFile         = $SourceFile
        SourceSection      = $SourceSection
        Signature          = $Signature
        ParentFunction     = $ParentFunction
        RawText            = $RawText
        PurposeDescription = $PurposeDescription
        DriftCodes         = $null
        DriftText          = $null
        OccurrenceIndex    = 1
    }
}

# Append a drift code (and optional descriptive text) to a row. Multiple
# drift codes accumulate as comma-separated values. Both columns stay in
# sync.
function Add-DriftCode {
    param(
        [Parameter(Mandatory)]$Row,
        [Parameter(Mandatory)][string]$Code,
        [string]$Text
    )
    if ([string]::IsNullOrEmpty($Code)) { return }

    if ([string]::IsNullOrEmpty($Row.DriftCodes)) {
        $Row.DriftCodes = $Code
    }
    else {
        # Avoid duplicate codes on the same row
        $existing = $Row.DriftCodes -split ','
        if ($existing -notcontains $Code) {
            $Row.DriftCodes = "$($Row.DriftCodes),$Code"
        }
        else {
            return
        }
    }

    $appendText = if ([string]::IsNullOrWhiteSpace($Text)) { $Code } else { $Text }
    if ([string]::IsNullOrEmpty($Row.DriftText)) {
        $Row.DriftText = $appendText
    }
    else {
        $Row.DriftText = "$($Row.DriftText) | $appendText"
    }
}

# ============================================================================
# TEXT HELPERS
# ============================================================================

# Format a multi-line string as a single-line representation.
function Format-SingleLine {
    param([string]$Text)
    if ($null -eq $Text) { return $null }
    $crlf = "`r`n"; $lf = "`n"; $cr = "`r"
    return ($Text -replace $crlf, ' ' -replace $lf, ' ' -replace $cr, ' ').Trim()
}

# Truncate a string for storage in fixed-width columns.
function Limit-Text {
    param([string]$Text, [int]$Max)
    if ($null -eq $Text) { return $null }
    if ($Text.Length -le $Max) { return $Text }
    return $Text.Substring(0, $Max)
}

# Pull raw text from the source string by character range.
function Get-RangeText {
    param(
        [string]$Source,
        $Node
    )
    if ($null -eq $Node -or $null -eq $Node.range -or $Node.range.Count -lt 2) {
        return $null
    }
    $start = [int]$Node.range[0]
    $end   = [int]$Node.range[1]
    if ($start -lt 0) { $start = 0 }
    if ($end -gt $Source.Length) { $end = $Source.Length }
    if ($end -le $start) { return '' }
    return $Source.Substring($start, $end - $start)
}

# Convert a raw block-comment body into clean purpose_description text.
# Strips the leading and trailing rule lines (sequences of = characters),
# strips per-line leading whitespace and asterisks (JSDoc style), preserves
# multi-line structure, drops blank lines at the boundaries.
# Returns NULL if the cleaned text is empty.
function ConvertTo-CleanCommentText {
    param([string]$CommentText)

    if ($null -eq $CommentText) { return $null }

    $crlf = "`r`n"; $lf = "`n"; $cr = "`r"
    $normalized = $CommentText -replace $crlf, "`n" -replace $cr, "`n"
    $lines = $normalized -split "`n"

    $cleaned = New-Object System.Collections.Generic.List[string]

    foreach ($line in $lines) {
        # Strip leading whitespace and leading * (JSDoc style). Comments come
        # in stripped of their /* and */ delimiters by Acorn.
        $stripped = $line -replace '^\s*\*\s?', '' -replace '^\s+', ''
        $stripped = $stripped.TrimEnd()

        # Drop pure rule lines (5+ equals or dashes only)
        if ($stripped -match '^[=]{5,}\s*$') { continue }
        if ($stripped -match '^[-]{5,}\s*$') { continue }

        $cleaned.Add($stripped)
    }

    # Trim leading and trailing blank lines from the cleaned set
    while ($cleaned.Count -gt 0 -and [string]::IsNullOrWhiteSpace($cleaned[0])) {
        $cleaned.RemoveAt(0)
    }
    while ($cleaned.Count -gt 0 -and [string]::IsNullOrWhiteSpace($cleaned[$cleaned.Count - 1])) {
        $cleaned.RemoveAt($cleaned.Count - 1)
    }

    if ($cleaned.Count -eq 0) { return $null }

    # Drop intermediate blank lines that immediately follow another blank line
    $compact = New-Object System.Collections.Generic.List[string]
    $prevBlank = $false
    foreach ($line in $cleaned) {
        $isBlank = [string]::IsNullOrWhiteSpace($line)
        if ($isBlank -and $prevBlank) { continue }
        $compact.Add($line)
        $prevBlank = $isBlank
    }

    if ($compact.Count -eq 0) { return $null }
    return ($compact -join "`n").Trim()
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

# Detect inline <style> content in template/string literals
function Test-LooksLikeInlineStyle {
    param([string]$Text)
    if ($null -eq $Text) { return $false }
    return $Text -match '<\s*style\b'
}

# Detect inline <script> content in template/string literals
function Test-LooksLikeInlineScript {
    param([string]$Text)
    if ($null -eq $Text) { return $false }
    return $Text -match '<\s*script\b'
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

        $charIndex = $m.Index
        $textBefore = $Text.Substring(0, $charIndex)
        $lineOffset = ($textBefore -split "`n").Count - 1
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
# AST WALKING UTILITIES
# ============================================================================

# Generic AST walker. Visits every node and invokes the visitor scriptblock.
# The visitor receives ($Node, $ParentChain) where ParentChain is an array
# of ancestor node types.
function Invoke-AstWalk {
    param(
        $Node,
        [array]$ParentChain = @(),
        [Parameter(Mandatory)][scriptblock]$Visitor
    )

    if ($null -eq $Node) { return }

    if ($Node -is [System.Array] -or $Node -is [System.Collections.IList]) {
        foreach ($item in $Node) {
            Invoke-AstWalk -Node $item -ParentChain $ParentChain -Visitor $Visitor
        }
        return
    }

    if ($Node -isnot [System.Management.Automation.PSCustomObject]) { return }
    if (-not ($Node.PSObject.Properties.Name -contains 'type')) { return }

    & $Visitor $Node $ParentChain

    $newChain = @($ParentChain + $Node.type)
    foreach ($prop in $Node.PSObject.Properties) {
        $name = $prop.Name
        if ($name -in @('type','start','end','loc','range','raw','value','name',
                        'operator','prefix','flags','pattern','sourceType',
                        'computed','static','async','generator',
                        'kind','shorthand','method','delegate','optional',
                        'tail','cooked','directive','regex')) {
            continue
        }
        $val = $prop.Value
        if ($null -eq $val) { continue }
        if ($val -is [string] -or $val -is [int] -or $val -is [bool] -or $val -is [double]) {
            continue
        }
        Invoke-AstWalk -Node $val -ParentChain $newChain -Visitor $Visitor
    }
}

function Get-NodeLine {
    param($Node)
    if ($null -eq $Node) { return 1 }
    if ($Node.loc -and $Node.loc.start -and $Node.loc.start.line) {
        return [int]$Node.loc.start.line
    }
    return 1
}

function Get-NodeEndLine {
    param($Node)
    if ($null -eq $Node) { return 1 }
    if ($Node.loc -and $Node.loc.end -and $Node.loc.end.line) {
        return [int]$Node.loc.end.line
    }
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
    param(
        $Callee,
        [string[]]$Path
    )
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

# Returns the simple name from an Identifier or string Literal node.
function Get-IdentifierName {
    param($Node)
    if ($null -eq $Node) { return $null }
    if ($Node.type -eq 'Identifier') { return $Node.name }
    if ($Node.type -eq 'Literal') { return [string]$Node.value }
    return $null
}

# Determine whether a node's parent chain indicates the node is inside
# any of the conditional / try wrappers that the spec forbids for
# top-level definitions.
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

# Find the immediately-enclosing function name for a node, if any. ParentChain
# carries types only, so we have to walk the actual AST. For now we accept
# the limitation that we don't have access to the parent nodes during the
# visitor callback - return null. Future enhancement: thread parent-name
# context through the walker.
function Get-EnclosingFunctionName {
    param([array]$ParentChain)
    return $null
}

# ============================================================================
# COMMENT-DEFINITION ASSOCIATION
# ============================================================================

# Build a sorted list of (line, comment) tuples for fast preceding-comment
# lookup. Comments come from the parse-js.js helper as a flat list.
function New-CommentIndex {
    param($Comments)
    $idx = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Comments) { return $idx }

    foreach ($c in $Comments) {
        if ($c.type -ne 'Block') { continue }
        $startLine = if ($c.loc -and $c.loc.start) { [int]$c.loc.start.line } else { 0 }
        $endLine   = if ($c.loc -and $c.loc.end)   { [int]$c.loc.end.line   } else { $startLine }
        if ($startLine -le 0) { continue }

        $idx.Add([ordered]@{
            StartLine = $startLine
            EndLine   = $endLine
            Value     = $c.value
            Used      = $false
        })
    }

    return $idx
}

# Find the block comment immediately preceding a definition node. "Immediately
# preceding" means: the comment ends on the line directly above the definition
# (allowing for one blank line gap), and the comment has not been claimed by
# a closer-following definition.
function Get-PrecedingBlockComment {
    param(
        $CommentIndex,
        [int]$DefinitionLine
    )

    if ($null -eq $CommentIndex -or $CommentIndex.Count -eq 0) { return $null }

    # Search backwards from the definition line for a comment whose end line
    # is at most 1 line above the definition (allowing for one blank line).
    $best = $null
    foreach ($c in $CommentIndex) {
        if ($c.Used) { continue }
        # End line should be 1 or 2 above the definition (gap of 0 or 1 blank line).
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

# Find a section banner comment - a block comment with a recognized TYPE: NAME
# header line. Banner comments are NOT consumed by Get-PrecedingBlockComment;
# they're claimed earlier by the section walk.
function Test-IsBannerComment {
    param([string]$CommentText)
    if ($null -eq $CommentText) { return $false }
    if ($CommentText -notmatch '={5,}') { return $false }

    # Must contain a TYPE: NAME line
    $lines = $CommentText -split "`n"
    foreach ($line in $lines) {
        $stripped = $line -replace '^\s*\*\s?', '' -replace '^\s+', ''
        $stripped = $stripped.Trim()
        if ($stripped -match '^([A-Z_]+)\s*:\s*(.+)$') {
            $type = $matches[1]
            if ($type -in $script:ValidSectionTypes) { return $true }
        }
    }
    return $false
}
# ============================================================================
# BANNER PARSING
# ============================================================================

# Parse a section banner comment into its structural fields. Returns an
# ordered hashtable with TypeName, BannerName, Description, Prefix, IsValid,
# DriftCodes (per-banner format issues to surface on the COMMENT_BANNER row).
#
# Expected banner shape:
#   /* ============================================================================
#      <TYPE>: <NAME>
#      ----------------------------------------------------------------------------
#      <Description: 1 to 5 sentences>
#      Prefix: <prefix>
#      ============================================================================ */
function Get-BannerInfo {
    param([string]$CommentText)

    $info = [ordered]@{
        TypeName    = $null
        BannerName  = $null
        Description = $null
        Prefix      = $null
        IsValid     = $false
        DriftCodes  = @()
    }

    if ($null -eq $CommentText) {
        $info.DriftCodes += 'MALFORMED_SECTION_BANNER'
        return $info
    }

    $crlf = "`r`n"; $lf = "`n"; $cr = "`r"
    $normalized = $CommentText -replace $crlf, "`n" -replace $cr, "`n"
    $rawLines = $normalized -split "`n"

    # Strip per-line leading whitespace and leading * characters
    $lines = @()
    foreach ($l in $rawLines) {
        $stripped = $l -replace '^\s*\*\s?', '' -replace '^\s+', ''
        $lines += $stripped.TrimEnd()
    }

    # Find the title line (TYPE: NAME)
    $titleLineIdx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^([A-Z_]+)\s*:\s*(.+)$') {
            $candidateType = $matches[1]
            if ($candidateType -in $script:ValidSectionTypes) {
                $info.TypeName = $candidateType
                $info.BannerName = $matches[2].Trim()
                $titleLineIdx = $i
                break
            }
        }
    }

    if ($titleLineIdx -lt 0) {
        $info.DriftCodes += 'MALFORMED_SECTION_BANNER'
        return $info
    }

    # Find the Prefix line
    $prefixLineIdx = -1
    for ($i = $titleLineIdx + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^Prefix\s*:\s*(.+)$') {
            $prefixVal = $matches[1].Trim()
            $info.Prefix = $prefixVal
            $prefixLineIdx = $i
            break
        }
    }

    if ($prefixLineIdx -lt 0) {
        $info.DriftCodes += 'MISSING_PREFIX_DECLARATION'
    }

    # Description = lines between separator-rule-after-title and Prefix line
    # (or end of comment if Prefix is missing).
    $descStart = $titleLineIdx + 1
    $descEnd   = if ($prefixLineIdx -ge 0) { $prefixLineIdx - 1 } else { $lines.Count - 1 }

    $descLines = New-Object System.Collections.Generic.List[string]
    for ($i = $descStart; $i -le $descEnd; $i++) {
        $line = $lines[$i]
        # Drop pure-rule lines (--- or ===)
        if ($line -match '^[=]{5,}\s*$') { continue }
        if ($line -match '^[-]{5,}\s*$') { continue }
        $descLines.Add($line)
    }

    # Trim leading and trailing blanks
    while ($descLines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($descLines[0])) {
        $descLines.RemoveAt(0)
    }
    while ($descLines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($descLines[$descLines.Count - 1])) {
        $descLines.RemoveAt($descLines.Count - 1)
    }

    if ($descLines.Count -gt 0) {
        $info.Description = ($descLines -join "`n").Trim()
    }

    if (-not [string]::IsNullOrEmpty($info.TypeName) -and
        -not [string]::IsNullOrEmpty($info.BannerName) -and
        $prefixLineIdx -ge 0) {
        $info.IsValid = $true
    }

    return $info
}

# Determine whether the prefix value declared in a banner is the "no prefix"
# sentinel.
function Test-IsPrefixNone {
    param([string]$Prefix)
    if ($null -eq $Prefix) { return $false }
    $trimmed = $Prefix.Trim().Trim('(',')').Trim().ToLower()
    return $trimmed -eq 'none' -or $trimmed -eq ''
}

# Extract the bare prefix value from a Prefix declaration. Removes any
# trailing comments or annotations. Returns empty string for the (none)
# sentinel.
function Get-BannerPrefixValue {
    param([string]$Prefix)
    if ($null -eq $Prefix) { return '' }
    if (Test-IsPrefixNone -Prefix $Prefix) { return '' }
    # Strip trailing parenthetical comments like "bsv  -- the business services prefix"
    $val = $Prefix -replace '\s+--.*$', ''
    $val = $val -replace '\s*\(.*\)\s*$', ''
    return $val.Trim()
}

# ============================================================================
# FILE HEADER PARSING
# ============================================================================

# Parse the file header block comment. Expects the first AST comment to be
# a block comment in the spec format. Returns an ordered hashtable with
# Description (purpose paragraph), FileOrgList (array of banner titles
# declared in the FILE ORGANIZATION list), HasChangelog (bool for drift),
# IsValid, DriftCodes.
function Get-FileHeaderInfo {
    param($Comments, $ProgramAst)

    $info = [ordered]@{
        Description  = $null
        FileOrgList  = @()
        HasChangelog = $false
        IsValid      = $false
        DriftCodes   = @()
        StartLine    = 1
        EndLine      = 1
    }

    if ($null -eq $Comments -or $Comments.Count -eq 0) {
        $info.DriftCodes += 'MALFORMED_FILE_HEADER'
        return $info
    }

    # The header is the FIRST block comment in the file, and it must precede
    # all other code/banners. Find the first Block comment.
    $headerComment = $null
    foreach ($c in $Comments) {
        if ($c.type -eq 'Block') {
            $headerComment = $c
            break
        }
    }

    if ($null -eq $headerComment) {
        $info.DriftCodes += 'MALFORMED_FILE_HEADER'
        return $info
    }

    # The header must start at line 1
    $headerStart = if ($headerComment.loc -and $headerComment.loc.start) { [int]$headerComment.loc.start.line } else { 0 }
    if ($headerStart -ne 1) {
        $info.DriftCodes += 'MALFORMED_FILE_HEADER'
        return $info
    }

    $info.StartLine = $headerStart
    $info.EndLine   = if ($headerComment.loc -and $headerComment.loc.end) { [int]$headerComment.loc.end.line } else { $headerStart }

    # Parse the header content
    $crlf = "`r`n"; $lf = "`n"; $cr = "`r"
    $normalized = $headerComment.value -replace $crlf, "`n" -replace $cr, "`n"
    $rawLines = $normalized -split "`n"

    $lines = @()
    foreach ($l in $rawLines) {
        $stripped = $l -replace '^\s*\*\s?', '' -replace '^\s+', ''
        $lines += $stripped.TrimEnd()
    }

    # Detect CHANGELOG block (forbidden)
    foreach ($line in $lines) {
        if ($line -match '^CHANGELOG\b' -or $line -match '^\s*CHANGELOG\s*$') {
            $info.HasChangelog = $true
            $info.DriftCodes += 'FORBIDDEN_CHANGELOG_BLOCK'
            break
        }
    }

    # Find FILE ORGANIZATION section
    $fileOrgStart = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^FILE\s+ORGANIZATION\s*$') {
            $fileOrgStart = $i
            break
        }
    }

    if ($fileOrgStart -ge 0) {
        # Skip the separator rule that follows the heading
        $listStart = $fileOrgStart + 1
        # The closing rule of the comment is the boundary
        for ($i = $listStart; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            if ($line -match '^[-]{3,}\s*$') { continue }
            if ($line -match '^[=]{5,}\s*$') { break }
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            # Strip trailing -- comment annotations
            $entry = $line -replace '\s+--.*$', ''
            $entry = $entry.Trim()
            if (-not [string]::IsNullOrEmpty($entry)) {
                $info.FileOrgList += $entry
            }
        }
    }

    # Description = everything between the closing rule under the header's
    # title block and the FILE ORGANIZATION heading. The title block is the
    # first 2 non-rule lines (the file identity + Location + Version + blank
    # arrangement varies, so we just take everything up to FILE ORGANIZATION
    # excluding rule lines and the bookkeeping fields).
    $descLines = New-Object System.Collections.Generic.List[string]
    $stopAt = if ($fileOrgStart -ge 0) { $fileOrgStart } else { $lines.Count }

    for ($i = 0; $i -lt $stopAt; $i++) {
        $line = $lines[$i]
        if ($line -match '^[=]{5,}\s*$') { continue }
        if ($line -match '^[-]{5,}\s*$') { continue }
        if ($line -match '^xFACts Control Center\b') { continue }
        if ($line -match '^Location\s*:') { continue }
        if ($line -match '^Version\s*:') { continue }
        $descLines.Add($line)
    }

    # Trim boundary blanks
    while ($descLines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($descLines[0])) {
        $descLines.RemoveAt(0)
    }
    while ($descLines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($descLines[$descLines.Count - 1])) {
        $descLines.RemoveAt($descLines.Count - 1)
    }

    if ($descLines.Count -gt 0) {
        $info.Description = ($descLines -join "`n").Trim()
    }

    # If we found a parseable title and no other malformed conditions, mark valid
    $hasIdentityLine = $false
    foreach ($line in $lines) {
        if ($line -match '^xFACts Control Center\b') {
            $hasIdentityLine = $true
            break
        }
    }
    if (-not $hasIdentityLine) {
        $info.DriftCodes += 'MALFORMED_FILE_HEADER'
    }
    elseif ($info.DriftCodes -notcontains 'MALFORMED_FILE_HEADER') {
        $info.IsValid = $true
    }

    return $info
}
# ============================================================================
# SECTION WALKING
# ============================================================================
#
# Walks the program body and the comments list together, building a list of
# section instances in source order:
#
#   [{ TypeName, BannerName, Prefix, StartLine, EndLine, BannerComment, BannerLine, ... }, ...]
#
# Plus a per-line index that maps any source line number to the section
# instance it falls within. This lets the row emitter ask "what section is
# line 387 in?" without re-walking.
#
# The section-walk algorithm:
#   1. Find all banner-shaped block comments (Test-IsBannerComment) and
#      sort by StartLine. These mark section starts in source order.
#   2. For each banner i, the section's body spans from the banner's EndLine+1
#      to the next banner's StartLine-1 (or to file end for the last banner).
#   3. Top-level statements that fall inside body[i] belong to section i.
#   4. Statements that appear BEFORE the first banner (other than the file
#      header) are flagged: MISSING_SECTION_BANNER on each affected definition.

function New-SectionList {
    param(
        $Comments,
        $ProgramAst,
        [int]$FileLineCount
    )

    $sections = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Comments) { return $sections }

    # Collect banner comments
    $bannerComments = New-Object System.Collections.Generic.List[object]
    foreach ($c in $Comments) {
        if ($c.type -ne 'Block') { continue }
        if (Test-IsBannerComment -CommentText $c.value) {
            $bannerComments.Add($c)
        }
    }

    # Sort by start line
    $sorted = $bannerComments | Sort-Object { if ($_.loc -and $_.loc.start) { [int]$_.loc.start.line } else { 0 } }

    # Build section instances
    $sortedArr = @($sorted)
    for ($i = 0; $i -lt $sortedArr.Count; $i++) {
        $b = $sortedArr[$i]
        $bStart = if ($b.loc -and $b.loc.start) { [int]$b.loc.start.line } else { 0 }
        $bEnd   = if ($b.loc -and $b.loc.end)   { [int]$b.loc.end.line   } else { $bStart }

        $bodyStart = $bEnd + 1
        $bodyEnd   = if ($i -lt ($sortedArr.Count - 1)) {
            $next = $sortedArr[$i + 1]
            if ($next.loc -and $next.loc.start) { ([int]$next.loc.start.line) - 1 } else { $FileLineCount }
        }
        else {
            $FileLineCount
        }

        $info = Get-BannerInfo -CommentText $b.value

        $sections.Add([ordered]@{
            Index            = $i
            BannerComment    = $b
            BannerStartLine  = $bStart
            BannerEndLine    = $bEnd
            BodyStartLine    = $bodyStart
            BodyEndLine      = $bodyEnd
            TypeName         = $info.TypeName
            BannerName       = $info.BannerName
            Description      = $info.Description
            Prefix           = $info.Prefix
            PrefixValue      = (Get-BannerPrefixValue -Prefix $info.Prefix)
            IsPrefixNone     = (Test-IsPrefixNone -Prefix $info.Prefix)
            IsValid          = $info.IsValid
            BannerDriftCodes = $info.DriftCodes
            FullTitle        = "$($info.TypeName): $($info.BannerName)"
        })
    }

    return $sections
}

# Locate the section instance that contains a given source line.
# Returns $null for lines outside any section (e.g., inside the file header
# or between sections).
function Get-SectionForLine {
    param(
        $Sections,
        [int]$Line
    )
    if ($null -eq $Sections) { return $null }
    foreach ($s in $Sections) {
        if ($Line -ge $s.BodyStartLine -and $Line -le $s.BodyEndLine) {
            return $s
        }
    }
    return $null
}

# Validate the section list against spec rules:
#   - Section types appear in valid order
#   - Single-banner-only types appear at most once
#   - FOUNDATION/CHROME only in cc-shared.js
#   - PAGE LIFECYCLE HOOKS banner is last (if it exists)
#   - All banner type names are recognized
# Returns a list of file-level drift codes (not attached to specific rows -
# the caller decides where to attach them, typically the FILE_HEADER row).
function Test-SectionListCompliance {
    param(
        $Sections,
        [string]$FileName
    )

    $codes = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Sections -or $Sections.Count -eq 0) { return $codes }

    # Type ordering check
    $lastOrder = 0
    $orderViolation = $false
    foreach ($s in $Sections) {
        if ([string]::IsNullOrEmpty($s.TypeName)) { continue }
        $thisOrder = $script:SectionTypeOrder[$s.TypeName]
        if ($null -eq $thisOrder) {
            if (-not $codes.Contains('UNKNOWN_SECTION_TYPE')) { $codes.Add('UNKNOWN_SECTION_TYPE') }
            continue
        }
        if ($thisOrder -lt $lastOrder) {
            $orderViolation = $true
        }
        else {
            $lastOrder = $thisOrder
        }
    }
    if ($orderViolation) { $codes.Add('SECTION_TYPE_ORDER_VIOLATION') }

    # Single-banner-type check
    $typeBucket = @{}
    foreach ($s in $Sections) {
        if ([string]::IsNullOrEmpty($s.TypeName)) { continue }
        if (-not $typeBucket.ContainsKey($s.TypeName)) { $typeBucket[$s.TypeName] = 0 }
        $typeBucket[$s.TypeName]++
    }
    foreach ($t in $script:SingleBannerTypes) {
        if ($typeBucket.ContainsKey($t) -and $typeBucket[$t] -gt 1) {
            $codes.Add("DUPLICATE_$t" + "_BANNER")
        }
    }

    # FOUNDATION / CHROME outside cc-shared.js
    foreach ($s in $Sections) {
        if ($s.TypeName -in $script:SharedOnlySectionTypes) {
            if ($FileName -ne $script:CanonicalSharedFile) {
                $codes.Add("$($s.TypeName)_OUTSIDE_SHARED_FILE")
            }
        }
    }

    # PAGE LIFECYCLE HOOKS banner must be last (if present)
    $hooksIdx = -1
    for ($i = 0; $i -lt $Sections.Count; $i++) {
        if ($Sections[$i].TypeName -eq 'FUNCTIONS' -and
            $Sections[$i].BannerName -eq $script:HooksBannerName) {
            $hooksIdx = $i
            break
        }
    }
    if ($hooksIdx -ge 0 -and $hooksIdx -ne ($Sections.Count - 1)) {
        $codes.Add('HOOKS_BANNER_NOT_LAST')
    }

    return $codes
}

# Cross-validate the FILE ORGANIZATION list in the file header against the
# actual section banner titles, in order. Returns true if they match.
function Test-FileOrgMatchesBanners {
    param(
        [string[]]$FileOrgList,
        $Sections
    )
    if ($null -eq $FileOrgList) { $FileOrgList = @() }
    if ($null -eq $Sections)    { return ($FileOrgList.Count -eq 0) }

    $bannerTitles = @($Sections | ForEach-Object { $_.FullTitle })

    if ($FileOrgList.Count -ne $bannerTitles.Count) { return $false }

    for ($i = 0; $i -lt $FileOrgList.Count; $i++) {
        if ($FileOrgList[$i].Trim() -ne $bannerTitles[$i].Trim()) {
            return $false
        }
    }
    return $true
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

        $output = $source | & $NodeExe $ParseJsScript 2>&1
        $exitCode = $LASTEXITCODE

        $jsonText = ($output | Out-String)
        $parsed = $null
        try {
            $parsed = $jsonText | ConvertFrom-Json
        }
        catch {
            Write-Log "JSON parse failed for ${FilePath}: $($_.Exception.Message)" "ERROR"
            return $null
        }

        if ($exitCode -ne 0 -or ($parsed.PSObject.Properties.Name -contains 'error' -and $parsed.error)) {
            $msg = if ($parsed.message) { $parsed.message } else { 'Unknown parser error' }
            $line = if ($parsed.line) { $parsed.line } else { '?' }
            $col = if ($parsed.column) { $parsed.column } else { '?' }
            Write-Log "Acorn parse failed for ${FilePath} at line ${line} col ${col}: $msg" "ERROR"
            return $null
        }

        return @{
            Ast      = $parsed.ast
            Comments = $parsed.comments
            Source   = $source
        }
    }
    catch {
        Write-Log "Exception during parse of ${FilePath}: $($_.Exception.Message)" "ERROR"
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
        Write-Log "Scan root not found, skipping: $root" "WARN"
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
}
else {
    Write-Log ("Discovered {0} .js files to scan" -f $JsFiles.Count)
}

# ============================================================================
# PASS 1 - PARSE ALL FILES, COLLECT SHARED-SCOPE DEFINITIONS
# ============================================================================
# Walk every file once to:
#   1. Cache the parse result (used by Pass 2)
#   2. Collect top-level definitions from $SharedFiles members so Pass 2
#      can resolve USAGE rows to their SHARED source.
#   3. Track which files declare FOUNDATION or CHROME sections (cross-file
#      uniqueness check happens after Pass 2).

Write-Log "Pass 1: parse all files, collect SHARED-scope JS definitions..."

$astCache = @{}

$sharedFunctions = New-Object 'System.Collections.Generic.HashSet[string]'
$sharedConstants = New-Object 'System.Collections.Generic.HashSet[string]'
$sharedClasses   = New-Object 'System.Collections.Generic.HashSet[string]'
$sharedSourceFile = @{}

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

    # If this is a shared file, collect its top-level definitions
    if ($SharedFiles -notcontains $name) { continue }

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
                # Special case: legacy `if (typeof X !== 'function') { window.X = function() ... }`
                # pattern in engine-events.js. The outer IfStatement's consequent contains
                # an ExpressionStatement whose expression is an AssignmentExpression
                # assigning a function to window.X. Capture the X for shared-function
                # collection so consumer pages don't trigger SHADOWS_SHARED_FUNCTION on
                # what is, by intent, a shared definition. The drift code
                # FORBIDDEN_CONDITIONAL_DEFINITION will still fire on the row itself,
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

Write-Log ("  Shared functions: {0}" -f $sharedFunctions.Count)
Write-Log ("  Shared constants: {0}" -f $sharedConstants.Count)
Write-Log ("  Shared classes:   {0}" -f $sharedClasses.Count)

# ============================================================================
# LOAD CSS_CLASS DEFINITIONS FROM Asset_Registry FOR SCOPE RESOLUTION
# ============================================================================

Write-Log "Loading existing CSS_CLASS DEFINITION rows for scope resolution..."

$cssDefs = Get-SqlData -Query @"
SELECT component_name, scope, file_name
FROM dbo.Asset_Registry
WHERE component_type = 'CSS_CLASS'
  AND reference_type = 'DEFINITION'
  AND file_type = 'CSS';
"@

$sharedClassMap = @{}
$localClassMap  = @{}

if ($null -ne $cssDefs) {
    foreach ($d in @($cssDefs)) {
        $cn = $d.component_name
        if ([string]::IsNullOrEmpty($cn)) { continue }
        if ($d.scope -eq 'SHARED') {
            if (-not $sharedClassMap.ContainsKey($cn)) {
                $sharedClassMap[$cn] = $d.file_name
            }
        }
        else {
            if (-not $localClassMap.ContainsKey($cn)) {
                $localClassMap[$cn] = $d.file_name
            }
        }
    }
}
else {
    Write-Log "Could not load CSS_CLASS DEFINITION rows. Class scope resolution will mark everything '<undefined>'." "WARN"
}

Write-Log ("  Shared CSS classes:     {0}" -f $sharedClassMap.Count)
Write-Log ("  Local-only CSS classes: {0}" -f $localClassMap.Count)

# ============================================================================
# LOAD Object_Registry FOR object_registry_id RESOLUTION
# ============================================================================

Write-Log "Loading Object_Registry mapping for FK resolution..."

$objectRegistryMap = @{}
$registryRows = Get-SqlData -Query @"
SELECT object_name, registry_id
FROM dbo.Object_Registry
WHERE is_active = 1;
"@

if ($null -ne $registryRows) {
    foreach ($r in @($registryRows)) {
        if (-not [string]::IsNullOrEmpty($r.object_name)) {
            if (-not $objectRegistryMap.ContainsKey($r.object_name)) {
                $objectRegistryMap[$r.object_name] = [int]$r.registry_id
            }
        }
    }
    Write-Log ("  Object_Registry rows loaded: {0}" -f $objectRegistryMap.Count)
}
else {
    Write-Log "Could not load Object_Registry rows. All inserted rows will have object_registry_id = NULL." "WARN"
}

$objectRegistryMisses = New-Object 'System.Collections.Generic.HashSet[string]'
# ============================================================================
# PASS 2 - GENERATE ROWS
# ============================================================================
# For each cached AST, walk it once collecting per-file context (top-level
# function/constant/class names for same-file USAGE resolution and prefix
# enforcement), build the section list, build the comment index, then walk
# the AST emitting rows for every catalogable pattern with drift codes
# applied.

Write-Log "Pass 2: generating Asset_Registry rows..."

# ----- Per-file local-definition collection ---------------------------------

function Get-LocalDefinitions {
    <#
    Walks the top-level Program body and returns sets of:
      Functions = top-level function names
      Constants = top-level const names (in any section)
      State     = top-level var names (in any section)
      Classes   = top-level class names
    Used for same-file USAGE resolution and for the prefix consistency check.
    #>
    param($ProgramBody)

    $funcs = New-Object 'System.Collections.Generic.HashSet[string]'
    $consts = New-Object 'System.Collections.Generic.HashSet[string]'
    $states = New-Object 'System.Collections.Generic.HashSet[string]'
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

# ----- State variables that hold timer handles ------------------------------

function Get-TimerHandleCandidates {
    <#
    Returns a HashSet of state-variable names that are likely timer handles.
    A "candidate" is any module-scope `var` declaration whose initial value
    is null, or whose name ends in 'Timer' or 'Interval'. The set is used
    by JS_TIMER detection to recognize when a setInterval/setTimeout result
    is being assigned to a tracked handle.
    #>
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

# ----- Visitor scriptblock state --------------------------------------------
#
# Visitor scriptblocks need access to per-file context. PowerShell scriptblock
# closures capture by reference; we set $script:* state before invoking the
# walker.

$script:CurrentFile           = $null
$script:CurrentFileIsShared   = $false
$script:CurrentFileSource     = $null
$script:CurrentLocalFuncs     = $null
$script:CurrentLocalConsts    = $null
$script:CurrentLocalState     = $null
$script:CurrentLocalClasses   = $null
$script:CurrentSections       = $null
$script:CurrentCommentIndex   = $null
$script:CurrentTimerHandles   = $null
$script:CurrentFileRow        = $null   # the FILE_HEADER row, for file-level drift
$script:CurrentFileSectionInst = $null  # used during nested-class method walks

# ----- Row emitters ---------------------------------------------------------

function Add-ClassUsageRow {
    param(
        [string]$ClassName,
        [int]$LineStart,
        [int]$ColumnStart,
        [string]$Signature,
        [string]$ParentFunction,
        [string]$RawText
    )

    if ([string]::IsNullOrWhiteSpace($ClassName)) { return $null }

    $scope = 'LOCAL'
    $sourceFile = '<undefined>'
    if ($sharedClassMap.ContainsKey($ClassName)) {
        $scope = 'SHARED'
        $sourceFile = $sharedClassMap[$ClassName]
    }
    elseif ($localClassMap.ContainsKey($ClassName)) {
        $scope = 'LOCAL'
        $sourceFile = $localClassMap[$ClassName]
    }

    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|CSS_CLASS|$ClassName|USAGE|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $section = Get-SectionForLine -Sections $script:CurrentSections -Line $LineStart
    $sourceSection = if ($section) { $section.FullTitle } else { $null }

    $row = New-AssetRow -FileName $script:CurrentFile -LineStart $LineStart `
        -LineEnd $LineStart -ColumnStart $ColumnStart `
        -ComponentType 'CSS_CLASS' -ComponentName $ClassName `
        -ReferenceType 'USAGE' `
        -Scope $scope -SourceFile $sourceFile `
        -SourceSection $sourceSection `
        -Signature (Limit-Text $Signature 4000) `
        -ParentFunction $ParentFunction `
        -RawText (Limit-Text $RawText 4000) `
        -PurposeDescription $null
    $script:rows.Add($row)
    return $row
}

function Add-HtmlIdRow {
    param(
        [string]$IdName,
        [string]$ReferenceType,
        [int]$LineStart,
        [int]$ColumnStart,
        [string]$Signature,
        [string]$ParentFunction,
        [string]$RawText
    )

    if ([string]::IsNullOrWhiteSpace($IdName)) { return $null }

    $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }
    $sourceFile = $script:CurrentFile

    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|HTML_ID|$IdName|$ReferenceType|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $section = Get-SectionForLine -Sections $script:CurrentSections -Line $LineStart
    $sourceSection = if ($section) { $section.FullTitle } else { $null }

    $row = New-AssetRow -FileName $script:CurrentFile -LineStart $LineStart `
        -LineEnd $LineStart -ColumnStart $ColumnStart `
        -ComponentType 'HTML_ID' -ComponentName $IdName `
        -ReferenceType $ReferenceType `
        -Scope $scope -SourceFile $sourceFile `
        -SourceSection $sourceSection `
        -Signature (Limit-Text $Signature 4000) `
        -ParentFunction $ParentFunction `
        -RawText (Limit-Text $RawText 4000) `
        -PurposeDescription $null
    $script:rows.Add($row)
    return $row
}

function Add-RowsFromHtmlBearingText {
    param(
        [string]$Text,
        [int]$StartLine,
        [int]$StartCol,
        [string]$ParentFunction,
        [string]$RawText
    )

    if (-not (Test-LooksLikeHtml -Text $Text)) { return }

    $occurrences = Get-HtmlAttributeOccurrences -Text $Text
    foreach ($occ in $occurrences) {
        $sourceLine = $StartLine + $occ.LineOffset
        $sourceCol = if ($occ.LineOffset -eq 0) { $StartCol + $occ.ColumnStart - 1 } else { $occ.ColumnStart }

        if ($occ.Kind -eq 'id') {
            if ($occ.Value -match '^\s*\$\{[^}]+\}\s*$') { continue }
            if ($occ.Value -match '^\s*\$\w+\s*$') { continue }
            Add-HtmlIdRow -IdName $occ.Value -ReferenceType 'DEFINITION' `
                -LineStart $sourceLine -ColumnStart $sourceCol `
                -Signature "id=`"$($occ.Value)`"" `
                -ParentFunction $ParentFunction `
                -RawText "id=`"$($occ.Value)`"" | Out-Null
        }
        else {
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

function Add-JsDefinitionRow {
    param(
        [string]$ComponentType,
        [string]$ComponentName,
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
    $sourceFile = $script:CurrentFile

    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|$ComponentType|$ComponentName|DEFINITION|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $sourceSection = if ($Section) { $Section.FullTitle } else { $null }

    $row = New-AssetRow -FileName $script:CurrentFile -LineStart $LineStart `
        -LineEnd $LineEnd -ColumnStart $ColumnStart `
        -ComponentType $ComponentType -ComponentName $ComponentName `
        -ReferenceType 'DEFINITION' `
        -Scope $scope -SourceFile $sourceFile `
        -SourceSection $sourceSection `
        -Signature (Limit-Text $Signature 4000) `
        -ParentFunction $ParentFunction `
        -RawText (Limit-Text $RawText 4000) `
        -PurposeDescription (Limit-Text $PurposeDescription 4000)
    $script:rows.Add($row)
    return $row
}

function Add-JsFunctionUsageRow {
    param(
        [string]$FunctionName,
        [int]$LineStart,
        [int]$ColumnStart,
        [string]$Signature,
        [string]$ParentFunction,
        [string]$RawText
    )

    if ([string]::IsNullOrEmpty($FunctionName)) { return $null }

    $scope = $null
    $sourceFile = $null

    if ($sharedFunctions.Contains($FunctionName)) {
        $scope = 'SHARED'
        $sourceFile = if ($sharedSourceFile.ContainsKey($FunctionName)) { $sharedSourceFile[$FunctionName] } else { '<shared>' }
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

    $section = Get-SectionForLine -Sections $script:CurrentSections -Line $LineStart
    $sourceSection = if ($section) { $section.FullTitle } else { $null }

    $row = New-AssetRow -FileName $script:CurrentFile -LineStart $LineStart `
        -LineEnd $LineStart -ColumnStart $ColumnStart `
        -ComponentType 'JS_FUNCTION' -ComponentName $FunctionName `
        -ReferenceType 'USAGE' `
        -Scope $scope -SourceFile $sourceFile `
        -SourceSection $sourceSection `
        -Signature (Limit-Text $Signature 4000) `
        -ParentFunction $ParentFunction `
        -RawText (Limit-Text $RawText 4000) `
        -PurposeDescription $null
    $script:rows.Add($row)
    return $row
}

function Add-JsEventRow {
    param(
        [string]$EventName,
        [int]$LineStart,
        [int]$ColumnStart,
        [string]$Signature,
        [string]$ParentFunction,
        [string]$RawText
    )

    if ([string]::IsNullOrWhiteSpace($EventName)) { return $null }

    $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }
    $sourceFile = $script:CurrentFile

    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|JS_EVENT|$EventName|USAGE|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $section = Get-SectionForLine -Sections $script:CurrentSections -Line $LineStart
    $sourceSection = if ($section) { $section.FullTitle } else { $null }

    $row = New-AssetRow -FileName $script:CurrentFile -LineStart $LineStart `
        -LineEnd $LineStart -ColumnStart $ColumnStart `
        -ComponentType 'JS_EVENT' -ComponentName $EventName `
        -ReferenceType 'USAGE' `
        -Scope $scope -SourceFile $sourceFile `
        -SourceSection $sourceSection `
        -Signature (Limit-Text $Signature 4000) `
        -ParentFunction $ParentFunction `
        -RawText (Limit-Text $RawText 4000) `
        -PurposeDescription $null
    $script:rows.Add($row)
    return $row
}
# ============================================================================
# PASS 2 - THE VISITOR
# ============================================================================
# Walks each file's AST emitting rows and applying drift codes inline. The
# visitor receives ($Node, $ParentChain) on every visit. State is read from
# $script:Current* variables set up by the per-file orchestration loop.

$visitor = {
    param($Node, $ParentChain)

    if ($null -eq $Node -or $null -eq $Node.type) { return }

    $line = Get-NodeLine -Node $Node
    $endLine = Get-NodeEndLine -Node $Node
    $col = Get-NodeColumn -Node $Node

    # The section this node lives in
    $section = Get-SectionForLine -Sections $script:CurrentSections -Line $line

    switch ($Node.type) {

        # ------- Group B: JS structural definitions ------------------------

        'FunctionDeclaration' {
            if (-not $Node.id -or -not $Node.id.name) { return }

            # Only catalog top-level function declarations. Nested function
            # declarations are not cataloged but they ARE checked for the
            # forbidden conditional-definition pattern.
            $isTopLevel = Test-IsTopLevel -ParentChain $ParentChain
            $isConditional = Test-IsConditionallyDefined -ParentChain $ParentChain

            if (-not $isTopLevel) {
                # Nested - skip cataloging
                return
            }

            $fnName = $Node.id.name

            # Build signature
            $sig = "function $fnName("
            if ($Node.params) {
                $paramNames = @()
                foreach ($p in $Node.params) {
                    if ($p.type -eq 'Identifier') { $paramNames += $p.name }
                    elseif ($p.type -eq 'AssignmentPattern' -and $p.left.type -eq 'Identifier') { $paramNames += $p.left.name }
                    elseif ($p.type -eq 'RestElement' -and $p.argument.type -eq 'Identifier') { $paramNames += "...$($p.argument.name)" }
                    else { $paramNames += '?' }
                }
                $sig += ($paramNames -join ', ')
            }
            $sig += ')'

            # Determine component type: hooks live in the PAGE LIFECYCLE HOOKS banner
            $isInHooksBanner = ($section -and
                                 $section.TypeName -eq 'FUNCTIONS' -and
                                 $section.BannerName -eq $script:HooksBannerName)
            $componentType = if ($isInHooksBanner) { 'JS_HOOK' } else { 'JS_FUNCTION' }

            # Capture preceding comment for purpose_description
            $rawComment = Get-PrecedingBlockComment -CommentIndex $script:CurrentCommentIndex -DefinitionLine $line
            $purpose = ConvertTo-CleanCommentText -CommentText $rawComment

            $row = Add-JsDefinitionRow -ComponentType $componentType `
                -ComponentName $fnName `
                -LineStart $line -LineEnd $endLine -ColumnStart $col `
                -Signature $sig `
                -ParentFunction $null `
                -RawText $sig `
                -PurposeDescription $purpose `
                -Section $section
            if (-not $row) { return }

            # Drift checks
            if ($isConditional) {
                Add-DriftCode -Row $row -Code 'FORBIDDEN_CONDITIONAL_DEFINITION' `
                    -Text "Function '$fnName' is declared inside a conditional/loop/try block; spec requires unconditional top-level definitions."
            }

            # Section-context checks
            if ($null -eq $section) {
                Add-DriftCode -Row $row -Code 'MISSING_SECTION_BANNER' `
                    -Text "Function '$fnName' appears outside any section banner."
            }
            else {
                # Type-fit check: functions live in FUNCTIONS sections
                if ($section.TypeName -ne 'FUNCTIONS' -and
                    $section.TypeName -ne 'INITIALIZATION' -and
                    $section.TypeName -ne 'CHROME' -and
                    $section.TypeName -ne 'FOUNDATION') {
                    Add-DriftCode -Row $row -Code 'FUNCTION_IN_NON_FUNCTION_SECTION' `
                        -Text "Function '$fnName' lives in '$($section.FullTitle)'; expected a FUNCTIONS section."
                }

                # Prefix check
                if ($componentType -eq 'JS_FUNCTION' -and -not $section.IsPrefixNone) {
                    $expectedPrefix = $section.PrefixValue
                    if (-not [string]::IsNullOrEmpty($expectedPrefix)) {
                        $expected = "$expectedPrefix" + "_"
                        if (-not $fnName.StartsWith($expected)) {
                            Add-DriftCode -Row $row -Code 'PREFIX_MISMATCH' `
                                -Text "Function '$fnName' does not start with the section's prefix '$expected'."
                        }
                    }
                }
                elseif ($componentType -eq 'JS_HOOK') {
                    # Hook names must match the recognized set
                    if ($script:RecognizedHookNames -notcontains $fnName) {
                        Add-DriftCode -Row $row -Code 'UNKNOWN_HOOK_NAME' `
                            -Text "Function '$fnName' is in the PAGE LIFECYCLE HOOKS banner but is not a recognized hook name."
                    }
                }
            }

            # Comment requirement
            if ([string]::IsNullOrEmpty($purpose)) {
                Add-DriftCode -Row $row -Code 'MISSING_FUNCTION_COMMENT' `
                    -Text "Function '$fnName' has no preceding purpose comment."
            }
        }

        'VariableDeclaration' {
            $isTopLevel = Test-IsTopLevel -ParentChain $ParentChain
            if (-not $isTopLevel) { return }

            # Multi-declaration check (var a, b, c)
            if ($Node.declarations -and $Node.declarations.Count -gt 1) {
                # Apply MULTI_DECLARATION drift to the first declaration's row;
                # the row builder will see this via the loop below and tag it.
                $isMulti = $true
            }
            else {
                $isMulti = $false
            }

            # Forbidden 'let'
            if ($Node.kind -eq 'let') {
                $isLet = $true
            }
            else {
                $isLet = $false
            }

            foreach ($decl in $Node.declarations) {
                if (-not $decl.id -or $decl.id.type -ne 'Identifier') { continue }

                $declName = $decl.id.name
                $declLine = Get-NodeLine -Node $decl
                $declCol  = Get-NodeColumn -Node $decl
                $declEnd  = Get-NodeEndLine -Node $decl
                $init     = $decl.init

                # Function/arrow expressions assigned to const/var -> JS_FUNCTION
                if ($init -and ($init.type -eq 'FunctionExpression' -or $init.type -eq 'ArrowFunctionExpression')) {
                    $arrowMarker = if ($init.type -eq 'ArrowFunctionExpression') { ' => ' } else { ' = function' }
                    $sig = "$($Node.kind) $declName$arrowMarker(...)"
                    $rawComment = Get-PrecedingBlockComment -CommentIndex $script:CurrentCommentIndex -DefinitionLine $declLine
                    $purpose = ConvertTo-CleanCommentText -CommentText $rawComment

                    $isInHooksBanner = ($section -and
                                         $section.TypeName -eq 'FUNCTIONS' -and
                                         $section.BannerName -eq $script:HooksBannerName)
                    $componentType = if ($isInHooksBanner) { 'JS_HOOK' } else { 'JS_FUNCTION' }

                    $row = Add-JsDefinitionRow -ComponentType $componentType `
                        -ComponentName $declName `
                        -LineStart $declLine -LineEnd $declEnd -ColumnStart $declCol `
                        -Signature $sig -ParentFunction $null -RawText $sig `
                        -PurposeDescription $purpose `
                        -Section $section
                    if ($row) {
                        if ($isLet)   { Add-DriftCode -Row $row -Code 'FORBIDDEN_LET' -Text "Function '$declName' is declared with 'let'; spec mandates 'const' or 'var'." }
                        if ($isMulti) { Add-DriftCode -Row $row -Code 'FORBIDDEN_MULTI_DECLARATION' -Text "Multiple declarations on a single statement; spec mandates one per statement." }
                        if ([string]::IsNullOrEmpty($purpose)) {
                            Add-DriftCode -Row $row -Code 'MISSING_FUNCTION_COMMENT' -Text "Function '$declName' has no preceding purpose comment."
                        }
                        if ($null -eq $section) {
                            Add-DriftCode -Row $row -Code 'MISSING_SECTION_BANNER' -Text "Function '$declName' appears outside any section banner."
                        }
                        elseif (-not $section.IsPrefixNone -and $componentType -eq 'JS_FUNCTION') {
                            $expectedPrefix = $section.PrefixValue
                            if (-not [string]::IsNullOrEmpty($expectedPrefix)) {
                                $expected = "$expectedPrefix" + "_"
                                if (-not $declName.StartsWith($expected)) {
                                    Add-DriftCode -Row $row -Code 'PREFIX_MISMATCH' `
                                        -Text "Function '$declName' does not start with section prefix '$expected'."
                                }
                            }
                        }
                    }
                    continue
                }

                # Class expressions assigned to const/var -> JS_CLASS
                if ($init -and $init.type -eq 'ClassExpression') {
                    $sig = "$($Node.kind) $declName = class"
                    $rawComment = Get-PrecedingBlockComment -CommentIndex $script:CurrentCommentIndex -DefinitionLine $declLine
                    $purpose = ConvertTo-CleanCommentText -CommentText $rawComment

                    $row = Add-JsDefinitionRow -ComponentType 'JS_CLASS' `
                        -ComponentName $declName `
                        -LineStart $declLine -LineEnd $declEnd -ColumnStart $declCol `
                        -Signature $sig -ParentFunction $null -RawText $sig `
                        -PurposeDescription $purpose `
                        -Section $section
                    if ($row) {
                        if ($isLet)   { Add-DriftCode -Row $row -Code 'FORBIDDEN_LET' -Text "Class '$declName' is declared with 'let'." }
                        if ($isMulti) { Add-DriftCode -Row $row -Code 'FORBIDDEN_MULTI_DECLARATION' }
                        if ([string]::IsNullOrEmpty($purpose)) {
                            Add-DriftCode -Row $row -Code 'MISSING_CLASS_COMMENT' -Text "Class '$declName' has no preceding purpose comment."
                        }
                    }
                    continue
                }

                # Plain const/var -> JS_CONSTANT or JS_STATE based on section + kind
                $isConstantSection = ($section -and ($section.TypeName -eq 'CONSTANTS' -or $section.TypeName -eq 'FOUNDATION'))
                $isStateSection    = ($section -and $section.TypeName -eq 'STATE')

                # Component type derivation: section-context first, fall back to kind
                $componentType = $null
                if ($isConstantSection)   { $componentType = 'JS_CONSTANT' }
                elseif ($isStateSection)  { $componentType = 'JS_STATE'    }
                elseif ($Node.kind -eq 'const') { $componentType = 'JS_CONSTANT' }
                else                       { $componentType = 'JS_STATE'    }

                # Build signature
                $valSig = $null
                if ($init -and $init.type -eq 'Literal') {
                    $valSig = "$($Node.kind) $declName = $($init.raw)"
                }
                elseif ($init) {
                    $valSig = "$($Node.kind) $declName = ..."
                }
                else {
                    $valSig = "$($Node.kind) $declName"
                }

                $rawComment = Get-PrecedingBlockComment -CommentIndex $script:CurrentCommentIndex -DefinitionLine $declLine
                $purpose = ConvertTo-CleanCommentText -CommentText $rawComment

                $row = Add-JsDefinitionRow -ComponentType $componentType `
                    -ComponentName $declName `
                    -LineStart $declLine -LineEnd $declEnd -ColumnStart $declCol `
                    -Signature $valSig -ParentFunction $null -RawText $valSig `
                    -PurposeDescription $purpose `
                    -Section $section
                if (-not $row) { continue }

                # Drift checks
                if ($isLet)   { Add-DriftCode -Row $row -Code 'FORBIDDEN_LET' -Text "'$declName' is declared with 'let'." }
                if ($isMulti) { Add-DriftCode -Row $row -Code 'FORBIDDEN_MULTI_DECLARATION' -Text "Multiple declarations on one statement." }

                # Section + keyword consistency
                if ($isConstantSection -and $Node.kind -ne 'const') {
                    Add-DriftCode -Row $row -Code 'WRONG_DECLARATION_KEYWORD' `
                        -Text "'$declName' uses '$($Node.kind)' in a CONSTANTS-style section; spec requires 'const'."
                }
                elseif ($isStateSection -and $Node.kind -ne 'var') {
                    Add-DriftCode -Row $row -Code 'WRONG_DECLARATION_KEYWORD' `
                        -Text "'$declName' uses '$($Node.kind)' in a STATE section; spec requires 'var'."
                }

                # Comment requirement
                if ([string]::IsNullOrEmpty($purpose)) {
                    if ($componentType -eq 'JS_CONSTANT') {
                        Add-DriftCode -Row $row -Code 'MISSING_CONSTANT_COMMENT' -Text "Constant '$declName' has no preceding purpose comment."
                    }
                    else {
                        Add-DriftCode -Row $row -Code 'MISSING_STATE_COMMENT' -Text "State variable '$declName' has no preceding purpose comment."
                    }
                }

                # Section presence
                if ($null -eq $section) {
                    Add-DriftCode -Row $row -Code 'MISSING_SECTION_BANNER' -Text "'$declName' appears outside any section banner."
                }
                else {
                    # Prefix check
                    if (-not $section.IsPrefixNone) {
                        $expectedPrefix = $section.PrefixValue
                        if (-not [string]::IsNullOrEmpty($expectedPrefix)) {
                            $expected = "$expectedPrefix" + "_"
                            if (-not $declName.StartsWith($expected)) {
                                Add-DriftCode -Row $row -Code 'PREFIX_MISMATCH' `
                                    -Text "'$declName' does not start with section prefix '$expected'."
                            }
                        }
                    }
                }
            }
        }

        'ClassDeclaration' {
            $isTopLevel = Test-IsTopLevel -ParentChain $ParentChain
            if (-not $isTopLevel) { return }
            if (-not $Node.id -or -not $Node.id.name) { return }

            $clsName = $Node.id.name
            $sig = "class $clsName"
            if ($Node.superClass -and $Node.superClass.name) { $sig += " extends $($Node.superClass.name)" }

            $rawComment = Get-PrecedingBlockComment -CommentIndex $script:CurrentCommentIndex -DefinitionLine $line
            $purpose = ConvertTo-CleanCommentText -CommentText $rawComment

            $row = Add-JsDefinitionRow -ComponentType 'JS_CLASS' `
                -ComponentName $clsName `
                -LineStart $line -LineEnd $endLine -ColumnStart $col `
                -Signature $sig -ParentFunction $null -RawText $sig `
                -PurposeDescription $purpose `
                -Section $section
            if (-not $row) { return }

            if ([string]::IsNullOrEmpty($purpose)) {
                Add-DriftCode -Row $row -Code 'MISSING_CLASS_COMMENT' -Text "Class '$clsName' has no preceding purpose comment."
            }
            if ($null -eq $section) {
                Add-DriftCode -Row $row -Code 'MISSING_SECTION_BANNER' -Text "Class '$clsName' appears outside any section banner."
            }
            elseif (-not $section.IsPrefixNone) {
                $expectedPrefix = $section.PrefixValue
                if (-not [string]::IsNullOrEmpty($expectedPrefix)) {
                    $expected = "$expectedPrefix" + "_"
                    if (-not $clsName.StartsWith($expected)) {
                        Add-DriftCode -Row $row -Code 'PREFIX_MISMATCH' `
                            -Text "Class '$clsName' does not start with section prefix '$expected'."
                    }
                }
            }
        }

        'MethodDefinition' {
            if (-not $Node.key -or $Node.key.type -ne 'Identifier') { return }
            $methodName = $Node.key.name
            $sig = "$methodName(...)"
            if ($Node.kind -eq 'constructor') { $sig = "constructor(...)" }

            $rawComment = Get-PrecedingBlockComment -CommentIndex $script:CurrentCommentIndex -DefinitionLine $line
            $purpose = ConvertTo-CleanCommentText -CommentText $rawComment

            $row = Add-JsDefinitionRow -ComponentType 'JS_METHOD' `
                -ComponentName $methodName `
                -LineStart $line -LineEnd $endLine -ColumnStart $col `
                -Signature $sig -ParentFunction $null -RawText $sig `
                -PurposeDescription $purpose `
                -Section $section
            if (-not $row) { return }

            if ([string]::IsNullOrEmpty($purpose)) {
                Add-DriftCode -Row $row -Code 'MISSING_METHOD_COMMENT' -Text "Method '$methodName' has no preceding purpose comment."
            }
        }

        'ImportDeclaration' {
            $sourceVal = if ($Node.source -and $Node.source.value) { $Node.source.value } else { '?' }
            foreach ($spec in $Node.specifiers) {
                $importedName = $null
                if ($spec.local -and $spec.local.name) { $importedName = $spec.local.name }
                if ($importedName) {
                    Add-JsDefinitionRow -ComponentType 'JS_IMPORT' `
                        -ComponentName $importedName `
                        -LineStart $line -LineEnd $endLine -ColumnStart $col `
                        -Signature "import $importedName from '$sourceVal'" `
                        -ParentFunction $null `
                        -RawText "import $importedName from '$sourceVal'" `
                        -PurposeDescription $null `
                        -Section $section | Out-Null
                }
            }
        }

        # ------- Group A & C: CallExpression patterns ---------------------

        'CallExpression' {
            $callee = $Node.callee
            if ($null -eq $callee) { return }

            # Forbidden: eval(...)
            if ($callee.type -eq 'Identifier' -and $callee.name -eq 'eval') {
                # Attach drift to the file header row (file-level drift)
                if ($script:CurrentFileRow) {
                    Add-DriftCode -Row $script:CurrentFileRow -Code 'FORBIDDEN_EVAL' `
                        -Text "eval() called at line $line."
                }
            }

            # Forbidden: document.write(...)
            if (Test-CalleeMatchesEnd -Callee $callee -Path @('document','write')) {
                if ($script:CurrentFileRow) {
                    Add-DriftCode -Row $script:CurrentFileRow -Code 'FORBIDDEN_DOCUMENT_WRITE' `
                        -Text "document.write() called at line $line."
                }
            }

            # Direct function call: foo(...)
            if ($callee.type -eq 'Identifier') {
                $fnName = $callee.name
                $sig = "$fnName(...)"
                Add-JsFunctionUsageRow -FunctionName $fnName `
                    -LineStart $line -ColumnStart $col `
                    -Signature $sig -ParentFunction $null `
                    -RawText $sig | Out-Null
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
                            $sig = "classList.$methodName('$cls')"
                            Add-ClassUsageRow -ClassName $cls `
                                -LineStart (Get-NodeLine -Node $arg) `
                                -ColumnStart (Get-NodeColumn -Node $arg) `
                                -Signature $sig -ParentFunction $null `
                                -RawText $sig | Out-Null
                        }
                    }
                }
            }

            # getElementById('foo')
            if (Test-CalleeMatchesEnd -Callee $callee -Path @('getElementById')) {
                $arg = $Node.arguments | Select-Object -First 1
                if ($arg -and $arg.type -eq 'Literal' -and $arg.value -is [string]) {
                    $idName = $arg.value
                    $sig = "getElementById('$idName')"
                    Add-HtmlIdRow -IdName $idName -ReferenceType 'USAGE' `
                        -LineStart (Get-NodeLine -Node $arg) `
                        -ColumnStart (Get-NodeColumn -Node $arg) `
                        -Signature $sig -ParentFunction $null `
                        -RawText $sig | Out-Null
                }
            }

            # querySelector / querySelectorAll
            if ((Test-CalleeMatchesEnd -Callee $callee -Path @('querySelector')) -or
                (Test-CalleeMatchesEnd -Callee $callee -Path @('querySelectorAll'))) {
                $arg = $Node.arguments | Select-Object -First 1
                if ($arg -and $arg.type -eq 'Literal' -and $arg.value -is [string]) {
                    $selector = $arg.value
                    $methodName = $callee.property.name
                    $sig = "$methodName('$selector')"

                    $idMatches = [regex]::Matches($selector, '#([\w-]+)')
                    foreach ($im in $idMatches) {
                        Add-HtmlIdRow -IdName $im.Groups[1].Value -ReferenceType 'USAGE' `
                            -LineStart (Get-NodeLine -Node $arg) `
                            -ColumnStart (Get-NodeColumn -Node $arg) `
                            -Signature $sig -ParentFunction $null `
                            -RawText $sig | Out-Null
                    }
                    $classMatches = [regex]::Matches($selector, '\.([\w-]+)')
                    foreach ($cm in $classMatches) {
                        Add-ClassUsageRow -ClassName $cm.Groups[1].Value `
                            -LineStart (Get-NodeLine -Node $arg) `
                            -ColumnStart (Get-NodeColumn -Node $arg) `
                            -Signature $sig -ParentFunction $null `
                            -RawText $sig | Out-Null
                    }
                }
            }

            # addEventListener('event', ...)
            if (Test-CalleeMatchesEnd -Callee $callee -Path @('addEventListener')) {
                $arg = $Node.arguments | Select-Object -First 1
                if ($arg -and $arg.type -eq 'Literal' -and $arg.value -is [string]) {
                    $evName = $arg.value
                    $sig = "addEventListener('$evName', ...)"
                    Add-JsEventRow -EventName $evName `
                        -LineStart (Get-NodeLine -Node $arg) `
                        -ColumnStart (Get-NodeColumn -Node $arg) `
                        -Signature $sig -ParentFunction $null `
                        -RawText $sig | Out-Null
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
                        $sig = "setAttribute('id', '$attrVal')"
                        Add-HtmlIdRow -IdName $attrVal -ReferenceType 'DEFINITION' `
                            -LineStart (Get-NodeLine -Node $arg2) `
                            -ColumnStart (Get-NodeColumn -Node $arg2) `
                            -Signature $sig -ParentFunction $null `
                            -RawText $sig | Out-Null
                    }
                    elseif ($attrName -eq 'class' -and -not [string]::IsNullOrWhiteSpace($attrVal)) {
                        $sig = "setAttribute('class', '$attrVal')"
                        $classNames = Split-ClassNames -Value $attrVal
                        foreach ($cls in $classNames) {
                            Add-ClassUsageRow -ClassName $cls `
                                -LineStart (Get-NodeLine -Node $arg2) `
                                -ColumnStart (Get-NodeColumn -Node $arg2) `
                                -Signature $sig -ParentFunction $null `
                                -RawText $sig | Out-Null
                        }
                    }
                }
            }

            # require('module')
            if ($callee.type -eq 'Identifier' -and $callee.name -eq 'require') {
                $arg = $Node.arguments | Select-Object -First 1
                if ($arg -and $arg.type -eq 'Literal' -and $arg.value -is [string]) {
                    $modName = $arg.value
                    $sig = "require('$modName')"
                    Add-JsDefinitionRow -ComponentType 'JS_IMPORT' `
                        -ComponentName $modName `
                        -LineStart $line -LineEnd $endLine -ColumnStart $col `
                        -Signature $sig -ParentFunction $null `
                        -RawText $sig `
                        -PurposeDescription $null `
                        -Section $section | Out-Null
                }
            }
        }

        # ------- Group A: template literals & string literals ----------------

        'TemplateLiteral' {
            $reconstructed = ''
            for ($i = 0; $i -lt $Node.quasis.Count; $i++) {
                $q = $Node.quasis[$i]
                $reconstructed += $q.value.cooked
                if ($i -lt $Node.expressions.Count) {
                    $reconstructed += '${dyn}'
                }
            }

            # Forbidden inline style/script
            if (Test-LooksLikeInlineStyle -Text $reconstructed) {
                if ($script:CurrentFileRow) {
                    Add-DriftCode -Row $script:CurrentFileRow -Code 'FORBIDDEN_INLINE_STYLE_IN_JS' `
                        -Text "Template literal contains <style> at line $line."
                }
            }
            if (Test-LooksLikeInlineScript -Text $reconstructed) {
                if ($script:CurrentFileRow) {
                    Add-DriftCode -Row $script:CurrentFileRow -Code 'FORBIDDEN_INLINE_SCRIPT_IN_JS' `
                        -Text "Template literal contains <script> at line $line."
                }
            }

            if (-not (Test-LooksLikeHtml -Text $reconstructed)) { return }

            $rawSnippet = Get-RangeText -Source $script:CurrentFileSource -Node $Node
            $rawDisplay = Format-SingleLine -Text $rawSnippet

            Add-RowsFromHtmlBearingText -Text $reconstructed `
                -StartLine $line -StartCol $col `
                -ParentFunction $null `
                -RawText $rawDisplay
        }

        'Literal' {
            if ($null -eq $Node.value) { return }
            if (-not ($Node.value -is [string])) { return }
            $strVal = [string]$Node.value

            # Forbidden inline style/script
            if (Test-LooksLikeInlineStyle -Text $strVal) {
                if ($script:CurrentFileRow) {
                    Add-DriftCode -Row $script:CurrentFileRow -Code 'FORBIDDEN_INLINE_STYLE_IN_JS' `
                        -Text "String literal contains <style> at line $line."
                }
            }
            if (Test-LooksLikeInlineScript -Text $strVal) {
                if ($script:CurrentFileRow) {
                    Add-DriftCode -Row $script:CurrentFileRow -Code 'FORBIDDEN_INLINE_SCRIPT_IN_JS' `
                        -Text "String literal contains <script> at line $line."
                }
            }

            if (-not (Test-LooksLikeHtml -Text $strVal)) { return }

            $rawSnippet = Get-RangeText -Source $script:CurrentFileSource -Node $Node
            $rawDisplay = Format-SingleLine -Text $rawSnippet

            Add-RowsFromHtmlBearingText -Text $strVal `
                -StartLine $line -StartCol $col `
                -ParentFunction $null `
                -RawText $rawDisplay
        }

        # ------- Group A & C: assignment patterns -------------------------

        'AssignmentExpression' {
            $left = $Node.left
            $right = $Node.right
            if ($null -eq $left -or $null -eq $right) { return }

            # Pattern 1: window.X = ... (forbidden outside cc-shared.js)
            if ($left.type -eq 'MemberExpression' -and
                -not $left.computed -and
                $left.object -and $left.object.type -eq 'Identifier' -and
                $left.object.name -eq 'window' -and
                $left.property -and $left.property.type -eq 'Identifier') {
                if ($script:CurrentFile -ne $script:CanonicalSharedFile -and
                    $script:CurrentFile -ne 'engine-events.js') {
                    if ($script:CurrentFileRow) {
                        $assignedName = $left.property.name
                        Add-DriftCode -Row $script:CurrentFileRow -Code 'FORBIDDEN_WINDOW_ASSIGNMENT' `
                            -Text "Assignment to window.$assignedName at line $line; outside cc-shared.js."
                    }
                }
            }

            # Pattern 2: TimerHandle = setInterval(...) | setTimeout(...)
            # JS_TIMER row when LHS is an Identifier matching a tracked
            # state-variable handle, and RHS is a CallExpression to
            # setInterval/setTimeout. The assignment can live anywhere
            # (function body or module scope - we catalog the assignment
            # site).
            if ($left.type -eq 'Identifier' -and
                $right.type -eq 'CallExpression' -and
                $right.callee -and $right.callee.type -eq 'Identifier' -and
                ($right.callee.name -eq 'setInterval' -or $right.callee.name -eq 'setTimeout') -and
                $script:CurrentTimerHandles -and
                $script:CurrentTimerHandles.Contains($left.name)) {

                $handleName = $left.name
                $callKind = $right.callee.name
                $sig = "$handleName = $callKind(...)"

                $section = Get-SectionForLine -Sections $script:CurrentSections -Line $line
                $sourceSection = if ($section) { $section.FullTitle } else { $null }

                $key = "$($script:CurrentFile)|$line|$col|JS_TIMER|$handleName|DEFINITION|"
                if (Test-AddDedupeKey -Key $key) {
                    $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }
                    $row = New-AssetRow -FileName $script:CurrentFile -LineStart $line `
                        -LineEnd $endLine -ColumnStart $col `
                        -ComponentType 'JS_TIMER' -ComponentName $handleName `
                        -ReferenceType 'DEFINITION' `
                        -Scope $scope -SourceFile $script:CurrentFile `
                        -SourceSection $sourceSection `
                        -Signature (Limit-Text $sig 4000) `
                        -ParentFunction $null `
                        -RawText (Limit-Text $sig 4000) `
                        -PurposeDescription $null
                    $script:rows.Add($row)
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
                        -Signature "className = '$($right.value)'" `
                        -ParentFunction $null `
                        -RawText "className = '$($right.value)'" | Out-Null
                }
            }

            if ($propName -eq 'id' -and $right.type -eq 'Literal' -and $right.value -is [string]) {
                $idVal = [string]$right.value
                if (-not [string]::IsNullOrWhiteSpace($idVal)) {
                    Add-HtmlIdRow -IdName $idVal -ReferenceType 'DEFINITION' `
                        -LineStart (Get-NodeLine -Node $right) `
                        -ColumnStart (Get-NodeColumn -Node $right) `
                        -Signature "id = '$idVal'" `
                        -ParentFunction $null `
                        -RawText "id = '$idVal'" | Out-Null
                }
            }

            if ($propName -match '^on([a-z]+)$') {
                $evName = $matches[1]
                $sig = "$propName = ..."
                Add-JsEventRow -EventName $evName `
                    -LineStart $line -ColumnStart $col `
                    -Signature $sig -ParentFunction $null `
                    -RawText $sig | Out-Null
            }
        }

        # ------- File-level forbidden patterns at file scope ----------------

        'ExpressionStatement' {
            # Detect IIFE at top level: (function() {...})()
            $isTopLevel = Test-IsTopLevel -ParentChain $ParentChain
            if ($isTopLevel -and $Node.expression -and $Node.expression.type -eq 'CallExpression') {
                $callee = $Node.expression.callee
                if ($callee -and ($callee.type -eq 'FunctionExpression' -or $callee.type -eq 'ArrowFunctionExpression')) {
                    if ($script:CurrentFileRow) {
                        Add-DriftCode -Row $script:CurrentFileRow -Code 'FORBIDDEN_IIFE' `
                            -Text "IIFE at file scope, line $line."
                    }
                }
            }
        }
    }
}
# ============================================================================
# PASS 2 - PER-FILE ORCHESTRATION
# ============================================================================

foreach ($file in $JsFiles) {
    $name = [System.IO.Path]::GetFileName($file)
    $isShared = $SharedFiles -contains $name

    if (-not $astCache.ContainsKey($file)) {
        Write-Log "  Skipping (no parsed AST): $name" "WARN"
        continue
    }

    $parsed = $astCache[$file]

    # Set per-file context for the visitor
    $script:CurrentFile         = $name
    $script:CurrentFileIsShared = $isShared
    $script:CurrentFileSource   = $parsed.Source

    # Build per-file local-definition sets for same-file USAGE resolution
    $localDefs = Get-LocalDefinitions -ProgramBody $parsed.Ast.body
    $script:CurrentLocalFuncs   = $localDefs.Functions
    $script:CurrentLocalConsts  = $localDefs.Constants
    $script:CurrentLocalState   = $localDefs.State
    $script:CurrentLocalClasses = $localDefs.Classes
    $script:CurrentTimerHandles = Get-TimerHandleCandidates -ProgramBody $parsed.Ast.body

    # Build comment index and section list
    $script:CurrentCommentIndex = New-CommentIndex -Comments $parsed.Comments
    $fileLineCount = ($parsed.Source -split "`n").Count
    $script:CurrentSections = New-SectionList -Comments $parsed.Comments `
                                              -ProgramAst $parsed.Ast `
                                              -FileLineCount $fileLineCount

    # ----- Emit FILE_HEADER row -----
    $headerInfo = Get-FileHeaderInfo -Comments $parsed.Comments -ProgramAst $parsed.Ast

    $fileScope = if ($isShared) { 'SHARED' } else { 'LOCAL' }
    $headerRow = New-AssetRow -FileName $name -LineStart $headerInfo.StartLine `
        -LineEnd $headerInfo.EndLine -ColumnStart 1 `
        -ComponentType 'FILE_HEADER' -ComponentName $name `
        -ReferenceType 'DEFINITION' `
        -Scope $fileScope -SourceFile $name `
        -SourceSection $null `
        -Signature $null `
        -ParentFunction $null `
        -RawText $null `
        -PurposeDescription (Limit-Text $headerInfo.Description 4000)
    $rows.Add($headerRow)
    $fileHeaderRowByFile[$name] = $headerRow
    $script:CurrentFileRow = $headerRow

    # File-header drift codes
    foreach ($code in $headerInfo.DriftCodes) {
        Add-DriftCode -Row $headerRow -Code $code
    }

    # FILE ORGANIZATION cross-validation
    if ($headerInfo.IsValid) {
        if (-not (Test-FileOrgMatchesBanners -FileOrgList $headerInfo.FileOrgList -Sections $script:CurrentSections)) {
            Add-DriftCode -Row $headerRow -Code 'FILE_ORG_MISMATCH' `
                -Text "FILE ORGANIZATION list does not match section banners verbatim/in-order."
        }
    }

    # ----- Emit COMMENT_BANNER rows for each section -----
    foreach ($s in $script:CurrentSections) {
        $bannerKey = "$name|$($s.BannerStartLine)|COMMENT_BANNER|$($s.FullTitle)|DEFINITION|"
        if (-not (Test-AddDedupeKey -Key $bannerKey)) { continue }

        $bannerRow = New-AssetRow -FileName $name -LineStart $s.BannerStartLine `
            -LineEnd $s.BannerEndLine -ColumnStart 1 `
            -ComponentType 'COMMENT_BANNER' -ComponentName $s.BannerName `
            -ReferenceType 'DEFINITION' `
            -Scope $fileScope -SourceFile $name `
            -SourceSection $s.FullTitle `
            -Signature $s.TypeName `
            -ParentFunction $null `
            -RawText $null `
            -PurposeDescription (Limit-Text $s.Description 4000)
        $rows.Add($bannerRow)

        # Per-banner drift codes from Get-BannerInfo
        foreach ($code in $s.BannerDriftCodes) {
            Add-DriftCode -Row $bannerRow -Code $code
        }

        # Track FOUNDATION/CHROME files for cross-file uniqueness check
        if ($s.TypeName -eq 'FOUNDATION') {
            if (-not $foundationFiles.Contains($name)) { [void]$foundationFiles.Add($name) }
        }
        if ($s.TypeName -eq 'CHROME') {
            if (-not $chromeFiles.Contains($name)) { [void]$chromeFiles.Add($name) }
        }
    }

    # ----- Section list compliance (file-level codes attached to FILE_HEADER row) -----
    $sectionCodes = Test-SectionListCompliance -Sections $script:CurrentSections -FileName $name
    foreach ($c in $sectionCodes) {
        Add-DriftCode -Row $headerRow -Code $c
    }

    # ----- Walk the AST emitting all other rows -----
    $startCount = $rows.Count
    $scopeLabel = if ($isShared) { 'SHARED' } else { 'LOCAL' }
    Write-Host ("  Walking {0} ({1})..." -f $name, $scopeLabel) -ForegroundColor Cyan

    Invoke-AstWalk -Node $parsed.Ast -Visitor $visitor

    # ----- File-scope // line comments check -----
    # Acorn returns Line comments alongside Block comments. Any Line comment
    # at file-scope is a drift. "File-scope" = not inside a function body;
    # we approximate by checking the comment's line against function body
    # ranges. A precise implementation walks the AST building line-range
    # spans for each FunctionDeclaration / Function/Arrow expression body.
    # For now we use a simpler heuristic: any line comment whose containing
    # line is NOT inside a known function body gets flagged. This may miss
    # some cases or include some (e.g., comments inside assigned object
    # literals at module scope). Worth refining once we see what trips.

    # Build a list of (startLine, endLine) for every function body in the
    # file. Walk the AST one more time gathering them.
    $functionRanges = New-Object System.Collections.Generic.List[object]
    $rangeVisitor = {
        param($n, $pc)
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
            if ($cLine -le 0) { continue }
            if (-not (Test-LineInsideFunction -Line $cLine -Ranges $functionRanges)) {
                Add-DriftCode -Row $headerRow -Code 'FORBIDDEN_FILE_SCOPE_LINE_COMMENT' `
                    -Text "Line comment at file scope, line $cLine."
            }
        }
    }

    $delta = $rows.Count - $startCount
    Write-Host ("    -> {0} rows" -f $delta) -ForegroundColor Green
}

# ============================================================================
# PASS 3 - CROSS-FILE CHECKS
# ============================================================================
# After Pass 2, run codebase-level checks:
#   - DUPLICATE_FOUNDATION: more than one file declared FOUNDATION sections
#   - DUPLICATE_CHROME:     more than one file declared CHROME sections
#   - SHADOWS_SHARED_FUNCTION: a page file defines a function whose name
#     matches a cc-shared.js export

Write-Log "Pass 3: cross-file compliance checks..."

# DUPLICATE_FOUNDATION
if ($foundationFiles.Count -gt 1) {
    foreach ($f in $foundationFiles) {
        if ($fileHeaderRowByFile.ContainsKey($f)) {
            Add-DriftCode -Row $fileHeaderRowByFile[$f] -Code 'DUPLICATE_FOUNDATION' `
                -Text "FOUNDATION sections declared in multiple files: $($foundationFiles -join ', '). Only cc-shared.js should declare FOUNDATION."
        }
    }
}

# DUPLICATE_CHROME
if ($chromeFiles.Count -gt 1) {
    foreach ($f in $chromeFiles) {
        if ($fileHeaderRowByFile.ContainsKey($f)) {
            Add-DriftCode -Row $fileHeaderRowByFile[$f] -Code 'DUPLICATE_CHROME' `
                -Text "CHROME sections declared in multiple files: $($chromeFiles -join ', '). Only cc-shared.js should declare CHROME."
        }
    }
}

# SHADOWS_SHARED_FUNCTION
# Collect every JS_FUNCTION DEFINITION row and check for name collisions
# with cc-shared.js shared functions.
$shadowCandidates = @($rows | Where-Object {
    $_.ComponentType -eq 'JS_FUNCTION' -and
    $_.ReferenceType -eq 'DEFINITION' -and
    $_.Scope -eq 'LOCAL' -and
    $sharedFunctions.Contains($_.ComponentName)
})

foreach ($row in $shadowCandidates) {
    Add-DriftCode -Row $row -Code 'SHADOWS_SHARED_FUNCTION' `
        -Text "Function '$($row.ComponentName)' shadows the shared definition in '$($sharedSourceFile[$row.ComponentName])'."
}
# ============================================================================
# OCCURRENCE INDEX COMPUTATION
# ============================================================================

Write-Log "Computing occurrence_index for all rows..."
Set-OccurrenceIndices -Rows $rows

# ============================================================================
# SUMMARY OUTPUT
# ============================================================================

Write-Log ("Total rows generated: {0}" -f $rows.Count)

if ($rows.Count -gt 0) {
    $rows | Group-Object { "$($_.ComponentType) / $($_.ReferenceType) / $($_.Scope)" } |
        Sort-Object Count -Descending |
        Format-Table @{L='Component / Ref / Scope';E='Name'}, Count -AutoSize
}

# Drift code summary
$driftSummary = @{}
foreach ($r in $rows) {
    if ([string]::IsNullOrEmpty($r.DriftCodes)) { continue }
    foreach ($code in ($r.DriftCodes -split ',')) {
        $code = $code.Trim()
        if ([string]::IsNullOrEmpty($code)) { continue }
        if (-not $driftSummary.ContainsKey($code)) { $driftSummary[$code] = 0 }
        $driftSummary[$code]++
    }
}

if ($driftSummary.Count -gt 0) {
    Write-Log "Drift code summary:"
    $driftSummary.GetEnumerator() | Sort-Object Value -Descending |
        Format-Table @{L='Drift Code';E='Key'}, @{L='Occurrences';E='Value'} -AutoSize
}
else {
    Write-Log "No drift codes found across the row set." "SUCCESS"
}

# ============================================================================
# DATABASE WRITE
# ============================================================================

if (-not $Execute) {
    Write-Log "PREVIEW MODE - no rows written to Asset_Registry. Use -Execute to insert." "WARN"
    return
}

Write-Log "Clearing existing JS rows from Asset_Registry..."
if (-not [string]::IsNullOrEmpty($FileFilter)) {
    # When running with FileFilter, only clear rows for the matching files
    $namePattern = $FileFilter
    $cleared = Invoke-SqlNonQuery -Query "DELETE FROM dbo.Asset_Registry WHERE file_type = 'JS' AND file_name LIKE @pattern;" `
        -Parameters @{ pattern = $namePattern }
}
else {
    $cleared = Invoke-SqlNonQuery -Query "DELETE FROM dbo.Asset_Registry WHERE file_type = 'JS';"
}
if (-not $cleared) {
    Write-Log "Failed to clear existing JS rows. Aborting." "ERROR"
    exit 1
}

if ($rows.Count -eq 0) {
    Write-Log "No rows to insert." "WARN"
    exit 0
}

Write-Log "Bulk-inserting $($rows.Count) rows..."

# Build DataTable matching dbo.Asset_Registry schema (post G-INIT-3 cleanup)
$dt = New-Object System.Data.DataTable
[void]$dt.Columns.Add('file_name',           [string])
[void]$dt.Columns.Add('object_registry_id',  [int])
[void]$dt.Columns.Add('file_type',           [string])
[void]$dt.Columns.Add('line_start',          [int])
[void]$dt.Columns.Add('line_end',            [int])
[void]$dt.Columns.Add('column_start',        [int])
[void]$dt.Columns.Add('component_type',      [string])
[void]$dt.Columns.Add('component_name',      [string])
[void]$dt.Columns.Add('reference_type',      [string])
[void]$dt.Columns.Add('scope',               [string])
[void]$dt.Columns.Add('source_file',         [string])
[void]$dt.Columns.Add('source_section',      [string])
[void]$dt.Columns.Add('signature',           [string])
[void]$dt.Columns.Add('parent_function',     [string])
[void]$dt.Columns.Add('raw_text',            [string])
[void]$dt.Columns.Add('purpose_description', [string])
[void]$dt.Columns.Add('drift_codes',         [string])
[void]$dt.Columns.Add('drift_text',          [string])
[void]$dt.Columns.Add('occurrence_index',    [int])

function Get-NullableValue {
    param($Value, [int]$MaxLen = 0)
    if ($null -eq $Value) { return [System.DBNull]::Value }
    if ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value)) {
        return [System.DBNull]::Value
    }
    if ($MaxLen -gt 0 -and $Value.Length -gt $MaxLen) {
        return $Value.Substring(0, $MaxLen)
    }
    return $Value
}

foreach ($r in $rows) {
    $row = $dt.NewRow()
    $row['file_name'] = $r.FileName

    if ($objectRegistryMap.ContainsKey($r.FileName)) {
        $row['object_registry_id'] = [int]$objectRegistryMap[$r.FileName]
    }
    else {
        $row['object_registry_id'] = [System.DBNull]::Value
        [void]$objectRegistryMisses.Add($r.FileName)
    }

    $row['file_type']           = $r.FileType
    $row['line_start']          = if ($null -eq $r.LineStart)   { 1 } else { [int]$r.LineStart }
    $row['line_end']            = if ($null -eq $r.LineEnd)     { [System.DBNull]::Value } else { [int]$r.LineEnd }
    $row['column_start']        = if ($null -eq $r.ColumnStart) { [System.DBNull]::Value } else { [int]$r.ColumnStart }
    $row['component_type']      = $r.ComponentType
    $row['component_name']      = Get-NullableValue $r.ComponentName 256
    $row['reference_type']      = $r.ReferenceType
    $row['scope']               = $r.Scope
    $row['source_file']         = $r.SourceFile
    $row['source_section']      = Get-NullableValue $r.SourceSection 200
    $row['signature']           = Get-NullableValue $r.Signature
    $row['parent_function']     = Get-NullableValue $r.ParentFunction 200
    $row['raw_text']            = Get-NullableValue $r.RawText
    $row['purpose_description'] = Get-NullableValue $r.PurposeDescription
    $row['drift_codes']         = Get-NullableValue $r.DriftCodes 4000
    $row['drift_text']          = Get-NullableValue $r.DriftText
    $row['occurrence_index']    = if ($null -eq $r.OccurrenceIndex) { 1 } else { [int]$r.OccurrenceIndex }
    $dt.Rows.Add($row)
}

try {
    $connectionString = "Server=$($script:XFActsServerInstance);Database=$($script:XFActsDatabase);Integrated Security=True;TrustServerCertificate=True;Application Name=$($script:XFActsAppName)"
    $conn = New-Object System.Data.SqlClient.SqlConnection $connectionString
    $conn.Open()
    $bcp = New-Object System.Data.SqlClient.SqlBulkCopy($conn)
    $bcp.DestinationTableName = 'dbo.Asset_Registry'
    $bcp.BatchSize = 500
    foreach ($col in $dt.Columns) {
        [void]$bcp.ColumnMappings.Add($col.ColumnName, $col.ColumnName)
    }
    $bcp.WriteToServer($dt)
    $conn.Close()

    Write-Log ("Inserted {0} rows into dbo.Asset_Registry." -f $rows.Count) "SUCCESS"
}
catch {
    Write-Log "Bulk insert failed: $($_.Exception.Message)" "ERROR"
    exit 1
}

# ============================================================================
# VERIFICATION QUERIES
# ============================================================================
# Bundled for development. Remove this entire block when promoting to
# production - it duplicates information available via Object_Registry
# queries against the live data.

Write-Log "Verification: row counts by component_type / reference_type / scope"

$verify1 = Get-SqlData -Query @"
SELECT component_type, reference_type, scope, COUNT(*) AS row_count
FROM dbo.Asset_Registry
WHERE file_type = 'JS'
GROUP BY component_type, reference_type, scope
ORDER BY component_type, reference_type, scope;
"@
if ($verify1) { $verify1 | Format-Table -AutoSize }

Write-Log "Verification: purpose_description coverage by definition type"

$verify2 = Get-SqlData -Query @"
SELECT
    component_type,
    COUNT(*)                                                              AS total_rows,
    SUM(CASE WHEN purpose_description IS NOT NULL THEN 1 ELSE 0 END)      AS with_purpose,
    SUM(CASE WHEN purpose_description IS NULL THEN 1 ELSE 0 END)          AS without_purpose
FROM dbo.Asset_Registry
WHERE file_type      = 'JS'
  AND reference_type = 'DEFINITION'
  AND component_type IN ('JS_FUNCTION', 'JS_HOOK', 'JS_CONSTANT', 'JS_STATE',
                         'JS_CLASS', 'JS_METHOD', 'FILE_HEADER', 'COMMENT_BANNER')
GROUP BY component_type
ORDER BY component_type;
"@
if ($verify2) { $verify2 | Format-Table -AutoSize }

Write-Log "Verification: drift code distribution"

$verify3 = Get-SqlData -Query @"
SELECT TRIM(value) AS code, COUNT(*) AS occurrences
FROM dbo.Asset_Registry
CROSS APPLY STRING_SPLIT(drift_codes, ',')
WHERE file_type   = 'JS'
  AND drift_codes IS NOT NULL
  AND TRIM(value) <> ''
GROUP BY TRIM(value)
ORDER BY occurrences DESC;
"@
if ($verify3) { $verify3 | Format-Table -AutoSize }

Write-Log "Verification: drift summary per file"

$verify4 = Get-SqlData -Query @"
SELECT
    file_name,
    COUNT(*) AS total_rows,
    SUM(CASE WHEN drift_codes IS NOT NULL THEN 1 ELSE 0 END) AS rows_with_drift
FROM dbo.Asset_Registry
WHERE file_type = 'JS'
GROUP BY file_name
ORDER BY rows_with_drift DESC;
"@
if ($verify4) { $verify4 | Format-Table -AutoSize }

# ----- Object_Registry miss report ------------------------------------------

if ($objectRegistryMisses.Count -gt 0) {
    Write-Log ("Object_Registry registration gaps detected for {0} file(s):" -f $objectRegistryMisses.Count) "WARN"
    foreach ($missing in ($objectRegistryMisses | Sort-Object)) {
        Write-Log ("  MISSING: $missing") "WARN"
    }
    Write-Log "Add the file(s) above to dbo.Object_Registry to enable FK linkage on subsequent runs." "WARN"
}

Write-Log "Done."
exit 0
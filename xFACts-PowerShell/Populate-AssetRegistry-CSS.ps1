<#
.SYNOPSIS
    xFACts - Asset Registry CSS Populator

.DESCRIPTION
    Walks every .css file under the Control Center public/css and
    public/docs/css directories, parses each file with PostCSS (via the
    parse-css.js Node helper), and generates Asset_Registry rows describing
    every cataloguable component found in the file.

    The CSS populator emits the following row types per CC_FileFormat_
    Standardization.md Part 3 (CSS Files):

      * FILE_HEADER DEFINITION rows — one per scanned file. Carries
        header-level drift codes and anchors the file in the catalog.

      * CSS_CLASS DEFINITION rows for every base class (no compound class
        modifiers, no pseudo-classes — selector is just .className).

      * CSS_VARIANT DEFINITION rows for every variant of a class:
          - .parent.modifier         -> variant_type='class',
                                        variant_qualifier_1='modifier'
          - .parent:pseudo           -> variant_type='pseudo',
                                        variant_qualifier_2='pseudo'
          - .parent.modifier:pseudo  -> variant_type='compound_pseudo',
                                        variant_qualifier_1='modifier',
                                        variant_qualifier_2='pseudo'
        component_name on every variant row is the parent class's name
        (the leftmost-class rule).

      * CSS_CLASS USAGE rows for descendant classes that appear after a
        combinator (.foo .bar produces a DEFINITION for .foo and a USAGE
        for .bar). Both rows carry FORBIDDEN_DESCENDANT drift since the
        construct is forbidden by the spec; the rows themselves stay in
        the catalog as a record of what's being referenced.

      * CSS_VARIABLE DEFINITION rows for every CSS custom property
        declaration (a property whose name starts with --).

      * CSS_VARIABLE USAGE rows for every var(--name) reference inside any
        property value. Scope resolved against the SHARED variable set.

      * CSS_KEYFRAME DEFINITION rows for every @keyframes at-rule.

      * CSS_KEYFRAME USAGE rows for keyframe references inside the
        animation and animation-name properties. Scope resolved against
        the SHARED keyframe set.

      * CSS_RULE DEFINITION rows for selectors with NO classes anywhere
        (e.g., 'body', 'h1', '*', '::-webkit-scrollbar'). Forbidden by
        the spec; cataloged anyway with appropriate drift codes.

      * HTML_ID DEFINITION rows for every #id selector encountered in CSS.

      * COMMENT_BANNER DEFINITION rows for block comments containing five
        or more consecutive '=' characters and following the section
        banner format.

    The parser annotates rows with drift codes per CC_FileFormat_
    Standardization.md Appendix A. Every row that participates in a spec
    deviation gets the relevant code(s) appended to drift_codes (a
    comma-separated list) and human-readable descriptions appended to
    drift_text. Compliant rows have NULL in both columns.

    Refresh semantics:
      * In standalone execution, the populator deletes only its own slice
        (file_type='CSS') before bulk-inserting. This makes the populator
        independently re-runnable for development without disturbing
        HTML or JS rows.
      * Under the orchestrator, the orchestrator TRUNCATEs the table once
        at the start and the populator's DELETE-WHERE becomes a harmless
        no-op on already-empty data.

.PARAMETER Execute
    Required to actually delete the CSS rows from Asset_Registry and write
    the new row set. Without this flag, runs in preview mode: parses every
    file, builds the row set in memory, prints summary statistics, but
    does NOT touch the database.

.NOTES
    File Name      : Populate-AssetRegistry-CSS.ps1
    Location       : E:\xFACts-PowerShell
    Author         : Frost Arnett Applications Team
    Version        : Tracked in dbo.System_Metadata (component: TBD)

================================================================================
CHANGELOG
================================================================================
2026-05-03  Major restructure for CSS file format spec compliance per
            CC_FileFormat_Standardization.md Part 3:
              (1) Schema migration: drops state_modifier, component_subtype,
                  parent_object, first_parsed_dttm columns from emitted rows.
                  Adds variant_type, variant_qualifier_1, variant_qualifier_2,
                  drift_codes, drift_text.
              (2) Variant emission: CSS_VARIANT rows replace the old
                  state_modifier-on-CSS_CLASS pattern. Three variant shapes
                  (class, pseudo, compound_pseudo) populate qualifier columns
                  per Part 3.6 of the spec.
              (3) FILE_HEADER row emission: one row per scanned file holding
                  the file's header-level drift codes and serving as the
                  catalog anchor for files regardless of content.
              (4) Drift detection: 30+ rule checks producing drift codes per
                  Appendix A. Inline detection in row-builder helpers; codes
                  accumulate per row.
              (5) Codebase-level pass: after per-file parsing, second pass
                  identifies duplicate FOUNDATION, duplicate CHROME, and
                  cross-references hex literals against shared custom
                  properties to flag DRIFT_HEX_LITERAL.
              (6) Bulk-insert DataTable schema updated to match the new
                  Asset_Registry shape.
              Per session-end protocol, this is the first run under the new
              spec; results are expected to surface adjustments to spec or
              parser before iteration locks in.
2026-05-02  Architectural correction: SharedFiles expanded to include all
            seven docs/css files. Previous version treated docs/css files
            as page-specific. Net effect: CSS_CLASS DEFINITION rows for
            docs files flip from LOCAL to SHARED, and downstream USAGE
            resolution now correctly points at the actual docs file that
            defines each consumed component.
2026-05-02  Initial production implementation. Replaces the throwaway test
            populator. Algorithmic core preserved — compound vs descendant
            selector decomposition, multi-selector dedupe, banner-driven
            source_section enrichment, CSS_VARIABLE and CSS_KEYFRAME def/use
            tracking, and CSS_RULE for non-class selectors all carry forward.
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

# Files whose top-level definitions are visible to multiple consumer files.
$SharedFiles = @(
    'engine-events.css',
    'docs-base.css',
    'docs-architecture.css',
    'docs-controlcenter.css',
    'docs-erd.css',
    'docs-hub.css',
    'docs-narrative.css',
    'docs-reference.css'
)

$env:NODE_PATH = $NodeLibsPath

# ============================================================================
# SPEC CONSTANTS
# ============================================================================

# The five enumerated section types, in required order.
$SectionTypeOrder = @('FOUNDATION', 'CHROME', 'LAYOUT', 'CONTENT', 'OVERRIDES')

# Drift code → human description mapping. Used to populate drift_text in
# parallel with drift_codes. Keep in sync with Appendix A of the spec doc.
$DriftDescriptions = [ordered]@{
    # File header
    'MALFORMED_FILE_HEADER'             = "The file's header block is missing, malformed, or contains required fields out of order."
    'FORBIDDEN_CHANGELOG'               = "The file header contains a CHANGELOG block. CHANGELOG blocks are not allowed in CSS file headers."
    'FILE_ORG_MISMATCH'                 = "The FILE ORGANIZATION list in the header does not exactly match the section banner titles in the file body, by content or by order."
    # Section banners
    'MISSING_SECTION_BANNER'            = "A class definition (or other catalogable construct) appears outside any banner — no section banner precedes it in the file."
    'MALFORMED_SECTION_BANNER'          = "A section banner exists but does not follow the strict 5-line format with 78-character rules."
    'UNKNOWN_SECTION_TYPE'              = "A section banner declares a TYPE not in the enumerated list (FOUNDATION, CHROME, LAYOUT, CONTENT, OVERRIDES)."
    'SECTION_TYPE_ORDER_VIOLATION'      = "Section types appear out of the required order (FOUNDATION → CHROME → LAYOUT → CONTENT → OVERRIDES)."
    'MISSING_PREFIXES_DECLARATION'      = "A section banner is missing the mandatory Prefixes: line in its description block."
    'DUPLICATE_FOUNDATION'              = "More than one CSS file in the codebase contains a FOUNDATION section."
    'DUPLICATE_CHROME'                  = "More than one CSS file in the codebase contains a CHROME section."
    # Class definitions
    'PREFIX_MISMATCH'                   = "A class name does not begin with one of the prefixes declared in its containing section's banner."
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
    'FORBIDDEN_SIBLING_COMBINATOR'      = "A rule's selector contains a sibling combinator (+ or ~). Restructure as a separate class definition."
    'COMPOUND_DEPTH_3PLUS'              = "A compound selector contains three or more class tokens. Refactor as a single class plus at most one modifier class."
    'PSEUDO_INTERLEAVED'                = "A pseudo-class appears between two class tokens. Pseudo-classes must come last in any compound."
    # Forbidden at-rules
    'FORBIDDEN_AT_IMPORT'               = "The file contains an @import rule."
    'FORBIDDEN_AT_FONT_FACE'            = "The file contains an @font-face rule."
    'FORBIDDEN_AT_MEDIA'                = "The file contains an @media rule."
    'FORBIDDEN_AT_SUPPORTS'             = "The file contains an @supports rule."
    'FORBIDDEN_KEYFRAMES_LOCATION'      = "An @keyframes definition appears in a section other than FOUNDATION (or in a file with no FOUNDATION)."
    'FORBIDDEN_CUSTOM_PROPERTY_LOCATION'= "A custom property definition appears in a section other than FOUNDATION."
    # Drift annotations
    'DRIFT_HEX_LITERAL'                 = "A hex color literal appears in a class declaration's value where a custom property has been defined for that color."
    # Comment / formatting
    'FORBIDDEN_COMMENT_STYLE'           = "A comment exists that is not one of the allowed kinds (file header, section banner, per-class purpose comment, trailing variant comment, sub-section marker)."
    'FORBIDDEN_COMPOUND_DECLARATION'    = "Two or more declarations appear on the same line. Each declaration must be on its own line."
    'BLANK_LINE_INSIDE_RULE'            = "A blank line appears inside a class definition (between the opening { and the closing })."
    'EXCESS_BLANK_LINES'                = "More than one blank line appears between top-level constructs."
}

# ============================================================================
# ROW BUILDER STATE
# ============================================================================

$rows       = New-Object System.Collections.Generic.List[object]
$dedupeKeys = New-Object 'System.Collections.Generic.HashSet[string]'

function Test-AddDedupeKey {
    param([string]$Key)
    return $script:dedupeKeys.Add($Key)
}

# Per-file state populated during walk and used by Pass 3 for cross-file checks.
# Map: file_name -> @{ FoundationLine; ChromeLine; PrefixesBySection; HexLiterals }
$fileMeta = @{}

# Compute occurrence_index per (file_name, component_name, reference_type,
# variant_type, variant_qualifier_1, variant_qualifier_2) tuple.
function Set-OccurrenceIndices {
    param([System.Collections.Generic.List[object]]$Rows)

    $counters = @{}
    foreach ($r in $Rows) {
        $cn = if ($r.ComponentName) { $r.ComponentName } else { '' }
        $vt = if ($r.VariantType)   { $r.VariantType }   else { '' }
        $q1 = if ($r.VariantQualifier1) { $r.VariantQualifier1 } else { '' }
        $q2 = if ($r.VariantQualifier2) { $r.VariantQualifier2 } else { '' }
        $key = "$($r.FileName)|$cn|$($r.ReferenceType)|$vt|$q1|$q2"
        if (-not $counters.ContainsKey($key)) { $counters[$key] = 0 }
        $counters[$key]++
        $r.OccurrenceIndex = $counters[$key]
    }
}

# ============================================================================
# DRIFT HELPERS
# ============================================================================

# Append a drift code to a row's drift_codes list. Idempotent — adding the
# same code twice is a no-op. Also appends the human description to drift_text.
function Add-Drift {
    param(
        [Parameter(Mandatory)] $Row,
        [Parameter(Mandatory)] [string]$Code
    )
    if (-not $script:DriftDescriptions.Contains($Code)) {
        Write-Log "Add-Drift: unknown drift code '$Code' — refusing to attach." 'WARN'
        return
    }

    $existingCodes = if ($Row.DriftCodes) { @($Row.DriftCodes -split ',\s*') } else { @() }
    if ($existingCodes -contains $Code) { return }

    $existingCodes = @($existingCodes) + $Code
    $Row.DriftCodes = ($existingCodes -join ', ')

    $description = $script:DriftDescriptions[$Code]
    $existingText = if ($Row.DriftText) { $Row.DriftText } else { '' }
    if ($existingText) {
        $Row.DriftText = "$existingText $description"
    }
    else {
        $Row.DriftText = $description
    }
}

# ============================================================================
# PARSER INVOCATION
# ============================================================================

function Invoke-CssParse {
    param([Parameter(Mandatory)][string]$FilePath)

    try {
        $source = Get-Content -Path $FilePath -Raw -Encoding UTF8
        if (-not $source) { $source = '' }

        $output = $source | & $NodeExe $ParseCssScript 2>&1
        $exitCode = $LASTEXITCODE
        $jsonText = ($output | Out-String)

        $parsed = $null
        try { $parsed = $jsonText | ConvertFrom-Json }
        catch {
            Write-Log "JSON parse failed for ${FilePath}: $($_.Exception.Message)" "ERROR"
            return $null
        }

        if ($exitCode -ne 0 -or ($parsed.PSObject.Properties.Name -contains 'error' -and $parsed.error)) {
            $msg = if ($parsed.message) { $parsed.message } else { 'Unknown parser error' }
            $line = if ($parsed.line) { $parsed.line } else { '?' }
            $col = if ($parsed.column) { $parsed.column } else { '?' }
            Write-Log "PostCSS parse failed for ${FilePath} at line ${line} col ${col}: $msg" "ERROR"
            return $null
        }

        return $parsed
    }
    catch {
        Write-Log "Exception during parse of ${FilePath}: $($_.Exception.Message)" "ERROR"
        return $null
    }
}

# ============================================================================
# UTILITY HELPERS
# ============================================================================

function Format-SingleLine {
    param([string]$Text)
    if ($null -eq $Text) { return $null }
    $crlf = "`r`n"; $lf = "`n"; $cr = "`r"
    return ($Text -replace $crlf, ' ' -replace $lf, ' ' -replace $cr, ' ').Trim()
}

# Banner detection: a comment containing a 78-character rule of '=' marks
# a section banner per Part 3.3 of the spec. The banner format is:
#   /* ============= (78 =)
#      <TYPE>: <NAME>
#      ------------- (78 -)
#      <description, 1+ lines>
#      Prefixes: <list>
#      ============= (78 =)
#      */
# Returns a banner descriptor or $null. Descriptor:
#   @{
#     IsBanner       = $true
#     IsMalformed    = bool
#     SectionType    = '...'  (or $null if extraction failed)
#     SectionName    = '...'  (or $null if extraction failed)
#     Description    = '...'
#     Prefixes       = @('p1', 'p2')   ($null if not declared)
#     RawTitle       = "$SectionType: $SectionName"   (banner title, used as source_section)
#   }
function Get-BannerInfo {
    param([string]$CommentText)
    if ($null -eq $CommentText) { return $null }

    # Detect any banner-shaped comment (at least one rule of 5+ '=')
    if ($CommentText -notmatch '={5,}') { return $null }

    # File headers also contain '=' rules but are not banners. Distinguish by
    # presence of header-specific markers — Location: and Version: lines, or
    # the xFACts identity line. If any of these are present, it's a header,
    # not a banner.
    if ($CommentText -match 'Location\s*:\s*[A-Za-z]:[\\/]' -or
        $CommentText -match 'Version\s*:\s*Tracked in dbo\.System_Metadata' -or
        $CommentText -match 'xFACts Control Center\s*-\s*[^=]+\(.+\.[a-z]+\)') {
        return $null
    }

    # Extract the title line and prefixes line by walking the comment lines.
    $lines = $CommentText -split "`n" | ForEach-Object { $_.TrimEnd() }
    $contentLines = @()
    foreach ($ln in $lines) {
        $stripped = $ln.Trim()
        # Skip rule lines (mostly = or - characters)
        if ($stripped -match '^[=\-]{5,}$') { continue }
        if ([string]::IsNullOrWhiteSpace($stripped)) { continue }
        $contentLines += $stripped
    }

    if ($contentLines.Count -eq 0) {
        return @{
            IsBanner    = $true
            IsMalformed = $true
            SectionType = $null
            SectionName = $null
            Description = $null
            Prefixes    = $null
            RawTitle    = $null
        }
    }

    # First content line: should be "<TYPE>: <NAME>"
    $titleLine = $contentLines[0]
    $sectionType = $null
    $sectionName = $null
    $isMalformed = $false

    if ($titleLine -match '^([A-Z_]+)\s*:\s*(.+)$') {
        $sectionType = $matches[1].Trim()
        $sectionName = $matches[2].Trim()
    }
    else {
        # Title doesn't follow TYPE: NAME format — old-style banner
        $sectionType = $null
        $sectionName = $titleLine
        $isMalformed = $true
    }

    # Prefixes: line — last content line that starts with "Prefixes:"
    $prefixes = $null
    foreach ($cl in $contentLines) {
        if ($cl -match '^Prefixes\s*:\s*(.+)$') {
            $prefixList = $matches[1].Trim() -split ',\s*'
            $prefixes = @($prefixList | Where-Object { $_ })
        }
    }

    # Description = content lines other than the title and the prefixes line
    $descLines = @()
    for ($i = 1; $i -lt $contentLines.Count; $i++) {
        if ($contentLines[$i] -notmatch '^Prefixes\s*:') {
            $descLines += $contentLines[$i]
        }
    }

    # Build raw title used for source_section. If we got both type and name,
    # use "TYPE: NAME"; if not, fall back to the whole first line.
    $rawTitle = if ($sectionType -and $sectionName) {
        "${sectionType}: ${sectionName}"
    } else {
        $sectionName
    }

    return @{
        IsBanner    = $true
        IsMalformed = $isMalformed
        SectionType = $sectionType
        SectionName = $sectionName
        Description = ($descLines -join ' ')
        Prefixes    = $prefixes
        RawTitle    = $rawTitle
    }
}

function Get-VarReferences {
    param([string]$Value)
    if ($null -eq $Value) { return @() }
    $regexMatches = [regex]::Matches($Value, 'var\(\s*--([a-zA-Z0-9_-]+)\s*[,)]')
    return @($regexMatches | ForEach-Object { $_.Groups[1].Value })
}

# Find every hex color literal in a property value (#abc, #abcdef, #aabbccdd).
function Get-HexLiterals {
    param([string]$Value)
    if ($null -eq $Value) { return @() }
    $regexMatches = [regex]::Matches($Value, '#[0-9a-fA-F]{3,8}\b')
    return @($regexMatches | ForEach-Object { $_.Value })
}

# ============================================================================
# SELECTOR DECOMPOSITION
# ============================================================================

# Walk a selector's children, splitting at combinator boundaries.
# Returns array of compound objects. Each compound carries:
#   Classes      - class names in source order
#   Ids          - id names
#   Pseudos      - pseudo-class names (ordered by position relative to classes)
#   PseudoElements - pseudo-element names
#   AttrCount    - how many attribute selectors were in this compound
#   HasTag       - whether the compound has an element/tag selector
#   HasUniversal - whether the compound has a *
#   PseudoInterleaved - whether a pseudo appeared before the last class
#                       (.foo:hover.bar pattern; spec-forbidden)
function Get-CompoundList {
    param([Parameter(Mandatory=$true)] $SelectorChildren)

    $compounds = New-Object System.Collections.Generic.List[object]

    # Local helper: build a fresh empty compound accumulator.
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
        }
    }

    # Local helper: snapshot an accumulator into an immutable compound object.
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
        }
    }

    $current = & $newAccumulator

    foreach ($node in $SelectorChildren) {
        $t = $node.type
        if ($t -eq 'combinator') {
            [void]$compounds.Add((& $finalize $current))
            $current = & $newAccumulator
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
                $bare = if ($rawVal) { $rawVal.TrimStart(':') } else { $null }
                if ($rawVal -and $rawVal.StartsWith('::')) {
                    # pseudo-element, e.g. ::-webkit-scrollbar
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
# PASS 1 - COLLECT SHARED-SCOPE DEFINITIONS
# ============================================================================

Write-Log "Pass 1: collecting SHARED-scope CSS definitions..."

$sharedClassMap     = @{}
$sharedVariableMap  = @{}
$sharedKeyframeMap  = @{}
$astCache = @{}

$CssFiles = New-Object System.Collections.Generic.List[string]
foreach ($root in $CssScanRoots) {
    if (-not (Test-Path $root)) {
        Write-Log "Scan root not found, skipping: $root" "WARN"
        continue
    }
    $found = @(Get-ChildItem -Path $root -Filter '*.css' -Recurse -File |
                 Select-Object -ExpandProperty FullName)
    foreach ($f in $found) { [void]$CssFiles.Add($f) }
}
Write-Log "Discovered $($CssFiles.Count) .css files to scan"

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

    if ($SharedFiles -notcontains $name) { continue }

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
                        if (-not $sharedClassMap.ContainsKey($primaryClass)) {
                            $sharedClassMap[$primaryClass] = $name
                        }
                        break
                    }
                }
            }
        }

        if ($node.type -eq 'decl' -and $node.prop -and $node.prop.StartsWith('--')) {
            $varName = $node.prop.Substring(2)
            if (-not $sharedVariableMap.ContainsKey($varName)) {
                $sharedVariableMap[$varName] = $name
            }
        }

        if ($node.type -eq 'atrule' -and $node.name -eq 'keyframes' -and $node.params) {
            $kfName = $node.params.Trim()
            if (-not $sharedKeyframeMap.ContainsKey($kfName)) {
                $sharedKeyframeMap[$kfName] = $name
            }
        }

        if ($node.nodes) {
            foreach ($child in $node.nodes) { $stack.Push($child) }
        }
    }
}

Write-Log ("  Shared classes:    {0}" -f $sharedClassMap.Count)
Write-Log ("  Shared variables:  {0}" -f $sharedVariableMap.Count)
Write-Log ("  Shared keyframes:  {0}" -f $sharedKeyframeMap.Count)

# ============================================================================
# LOAD Object_Registry
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

Write-Log "Pass 2: generating Asset_Registry rows..."

# Per-file context state.
$script:CurrentFile         = $null
$script:CurrentFileIsShared = $false
$script:CurrentBannerInfo   = $null   # full banner descriptor
$script:CurrentBannerOuter  = $null   # banner title (for source_section)
$script:CurrentSectionTypes = $null   # array of section types seen so far in file
$script:CurrentFilePrefixes = $null   # active section's declared prefixes

# ----- Row builders --------------------------------------------------------

function New-RowSkeleton {
    return [pscustomobject]@{
        FileName            = $script:CurrentFile
        FileType            = 'CSS'
        LineStart           = 1
        LineEnd             = $null
        ColumnStart         = $null
        ComponentType       = $null
        ComponentName       = $null
        VariantType         = $null
        VariantQualifier1   = $null
        VariantQualifier2   = $null
        ReferenceType       = 'DEFINITION'
        Scope               = $null
        SourceFile          = $script:CurrentFile
        SourceSection       = $script:CurrentBannerOuter
        Signature           = $null
        ParentFunction      = $null
        RawText             = $null
        DriftCodes          = $null
        DriftText           = $null
        OccurrenceIndex     = 1
    }
}

function Resolve-ClassScope {
    param([string]$ClassName)
    if ($script:sharedClassMap.ContainsKey($ClassName)) {
        return @{ Scope = 'SHARED'; SourceFile = $script:sharedClassMap[$ClassName] }
    }
    return @{ Scope = 'LOCAL'; SourceFile = $script:CurrentFile }
}

function Add-FileHeaderRow {
    param(
        [string]$FileName,
        [int]$LineStart,
        [int]$LineEnd,
        [string]$RawText,
        [string]$PurposeDescription
    )
    $row = New-RowSkeleton
    $row.ComponentType = 'FILE_HEADER'
    $row.ComponentName = $FileName
    $row.LineStart     = $LineStart
    $row.LineEnd       = $LineEnd
    $row.Scope         = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }
    $row.RawText       = $RawText
    $row.Signature     = $PurposeDescription
    $row.SourceSection = $null
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

    $row = New-RowSkeleton
    $row.ComponentType  = 'CSS_RULE'
    $row.LineStart      = $LineStart
    $row.LineEnd        = $LineEnd
    $row.ColumnStart    = $ColumnStart
    $row.Scope          = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }
    $row.Signature      = $Signature
    $row.ParentFunction = $ParentAtrule
    $row.RawText        = $RawText
    $script:rows.Add($row)
    return $row
}

function Add-CssClassOrVariantRow {
    param(
        [string]$ComponentName,
        [string]$VariantType,        # NULL | 'class' | 'pseudo' | 'compound_pseudo'
        [string]$VariantQualifier1,
        [string]$VariantQualifier2,
        [string]$ReferenceType,
        [int]$LineStart, [int]$LineEnd, [int]$ColumnStart,
        [string]$Signature, [string]$ParentAtrule, [string]$RawText
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

    $row = New-RowSkeleton
    $row.ComponentType      = $componentType
    $row.ComponentName      = $ComponentName
    $row.VariantType        = $VariantType
    $row.VariantQualifier1  = $VariantQualifier1
    $row.VariantQualifier2  = $VariantQualifier2
    $row.ReferenceType      = $ReferenceType
    $row.Scope              = $scope
    $row.SourceFile         = $sourceFile
    $row.LineStart          = $LineStart
    $row.LineEnd            = $LineEnd
    $row.ColumnStart        = $ColumnStart
    $row.Signature          = $Signature
    $row.ParentFunction     = $ParentAtrule
    $row.RawText            = $RawText
    $script:rows.Add($row)
    return $row
}

function Add-HtmlIdRow {
    param(
        [string]$IdName,
        [int]$LineStart, [int]$LineEnd, [int]$ColumnStart,
        [string]$Signature, [string]$ParentAtrule, [string]$RawText
    )
    if ([string]::IsNullOrWhiteSpace($IdName)) { return $null }

    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|HTML_ID|$IdName|DEFINITION|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $row = New-RowSkeleton
    $row.ComponentType  = 'HTML_ID'
    $row.ComponentName  = $IdName
    $row.Scope          = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }
    $row.LineStart      = $LineStart
    $row.LineEnd        = $LineEnd
    $row.ColumnStart    = $ColumnStart
    $row.Signature      = $Signature
    $row.ParentFunction = $ParentAtrule
    $row.RawText        = $RawText
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
        if ($script:sharedVariableMap.ContainsKey($VarName)) {
            $scope = 'SHARED'; $sourceFile = $script:sharedVariableMap[$VarName]
        } else {
            $scope = 'LOCAL'; $sourceFile = $script:CurrentFile
        }
    }

    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|CSS_VARIABLE|$VarName|$ReferenceType|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $row = New-RowSkeleton
    $row.ComponentType  = 'CSS_VARIABLE'
    $row.ComponentName  = $VarName
    $row.ReferenceType  = $ReferenceType
    $row.Scope          = $scope
    $row.SourceFile     = $sourceFile
    $row.LineStart      = $LineStart
    $row.LineEnd        = $LineEnd
    $row.ColumnStart    = $ColumnStart
    $row.Signature      = $Signature
    $row.ParentFunction = $ParentAtrule
    $row.RawText        = $RawText
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
        if ($script:sharedKeyframeMap.ContainsKey($KeyframeName)) {
            $scope = 'SHARED'; $sourceFile = $script:sharedKeyframeMap[$KeyframeName]
        } else {
            $scope = 'LOCAL'; $sourceFile = $script:CurrentFile
        }
    }

    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|CSS_KEYFRAME|$KeyframeName|$ReferenceType|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $row = New-RowSkeleton
    $row.ComponentType  = 'CSS_KEYFRAME'
    $row.ComponentName  = $KeyframeName
    $row.ReferenceType  = $ReferenceType
    $row.Scope          = $scope
    $row.SourceFile     = $sourceFile
    $row.LineStart      = $LineStart
    $row.LineEnd        = $LineEnd
    $row.ColumnStart    = $ColumnStart
    $row.Signature      = $Signature
    $row.ParentFunction = $ParentAtrule
    $row.RawText        = $RawText
    $script:rows.Add($row)
    return $row
}

function Add-CommentBannerRow {
    param(
        $BannerInfo,
        [int]$LineStart, [int]$LineEnd, [int]$ColumnStart, [string]$RawText
    )
    if (-not $BannerInfo -or [string]::IsNullOrWhiteSpace($BannerInfo.RawTitle)) { return $null }

    $key = "$($script:CurrentFile)|$LineStart|COMMENT_BANNER|$($BannerInfo.RawTitle)|DEFINITION|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $row = New-RowSkeleton
    $row.ComponentType   = 'COMMENT_BANNER'
    $row.ComponentName   = if ($BannerInfo.SectionName) { $BannerInfo.SectionName } else { $BannerInfo.RawTitle }
    $row.LineStart       = $LineStart
    $row.LineEnd         = $LineEnd
    $row.ColumnStart     = $ColumnStart
    $row.Scope           = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }
    $row.Signature       = $BannerInfo.SectionType   # store TYPE in signature for query convenience
    $row.RawText         = $RawText
    $row.SourceSection   = $null   # banner rows don't carry a parent banner
    $script:rows.Add($row)
    return $row
}

# ----- Per-selector row generation -----------------------------------------

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
        [bool]   $HasPrecedingComment = $false,
        [bool]   $HasTrailingInlineComment = $false,
        [bool]   $IsPartOfGroup = $false
    )

    $compounds = Get-CompoundList -SelectorChildren $SelectorNode.nodes

    $primaryIdx = -1
    for ($i = 0; $i -lt $compounds.Count; $i++) {
        if ($compounds[$i].Classes.Count -gt 0 -or $compounds[$i].Ids.Count -gt 0) {
            $primaryIdx = $i; break
        }
    }

    # Selector with no class and no id → element-only / universal / attribute-only.
    if ($primaryIdx -lt 0) {
        $row = Add-CssRuleRow -LineStart $LineStart -LineEnd $LineEnd `
            -ColumnStart $ColumnStart -Signature $RuleSelectorText `
            -ParentAtrule $ParentAtrule -RawText $RuleSelectorText
        if ($row) {
            # Determine which forbidden category applies
            $hasUniversal = ($compounds | Where-Object { $_.HasUniversal }).Count -gt 0
            $hasAttr      = ($compounds | Where-Object { $_.AttrCount -gt 0 }).Count -gt 0
            $hasTag       = ($compounds | Where-Object { $_.HasTag }).Count -gt 0

            if ($hasUniversal) { Add-Drift -Row $row -Code 'FORBIDDEN_UNIVERSAL_SELECTOR' }
            if ($hasAttr)      { Add-Drift -Row $row -Code 'FORBIDDEN_ATTRIBUTE_SELECTOR' }
            if ($hasTag -and -not $hasUniversal -and -not $hasAttr) {
                Add-Drift -Row $row -Code 'FORBIDDEN_ELEMENT_SELECTOR'
            }
            if ($IsPartOfGroup) { Add-Drift -Row $row -Code 'FORBIDDEN_GROUP_SELECTOR' }
            if ($compounds.Count -gt 1) { Add-Drift -Row $row -Code 'FORBIDDEN_DESCENDANT' }
            # MISSING_SECTION_BANNER if no banner has been seen yet in this file
            if (-not $script:CurrentBannerOuter) {
                Add-Drift -Row $row -Code 'MISSING_SECTION_BANNER'
            }
        }
        return
    }

    $primary = $compounds[$primaryIdx]

    # Decide what the primary row is and what variant qualifiers (if any) to populate
    $primaryRow = $null

    if ($primary.Classes.Count -gt 0) {
        $primaryName = $primary.Classes[0]

        # Determine variant shape based on primary compound's contents
        $variantType        = $null
        $variantQualifier1  = $null
        $variantQualifier2  = $null

        $extraClasses = if ($primary.Classes.Count -gt 1) { $primary.Classes[1..($primary.Classes.Count-1)] } else { @() }
        $extraPseudos = $primary.Pseudos

        if ($extraClasses.Count -eq 0 -and $extraPseudos.Count -eq 0) {
            # Pure base class
            $variantType = $null
        }
        elseif ($extraClasses.Count -ge 1 -and $extraPseudos.Count -eq 0) {
            $variantType = 'class'
            $variantQualifier1 = ($extraClasses -join '.')
        }
        elseif ($extraClasses.Count -eq 0 -and $extraPseudos.Count -ge 1) {
            $variantType = 'pseudo'
            $variantQualifier2 = ($extraPseudos -join ':')
        }
        else {
            $variantType = 'compound_pseudo'
            $variantQualifier1 = ($extraClasses -join '.')
            $variantQualifier2 = ($extraPseudos -join ':')
        }

        $primaryRow = Add-CssClassOrVariantRow `
            -ComponentName $primaryName `
            -VariantType $variantType `
            -VariantQualifier1 $variantQualifier1 `
            -VariantQualifier2 $variantQualifier2 `
            -ReferenceType 'DEFINITION' `
            -LineStart $LineStart -LineEnd $LineEnd -ColumnStart $ColumnStart `
            -Signature $RuleSelectorText -ParentAtrule $ParentAtrule -RawText $RuleSelectorText

        if ($primaryRow) {
            # Drift checks on primary row
            if ($extraClasses.Count -ge 2) {
                Add-Drift -Row $primaryRow -Code 'COMPOUND_DEPTH_3PLUS'
            }
            if ($primary.PseudoInterleaved) {
                Add-Drift -Row $primaryRow -Code 'PSEUDO_INTERLEAVED'
            }
            if ($primary.Ids.Count -gt 0) {
                Add-Drift -Row $primaryRow -Code 'FORBIDDEN_ID_SELECTOR'
            }
            if ($primary.AttrCount -gt 0) {
                Add-Drift -Row $primaryRow -Code 'FORBIDDEN_ATTRIBUTE_SELECTOR'
            }
            if ($primary.HasTag) {
                Add-Drift -Row $primaryRow -Code 'FORBIDDEN_ELEMENT_SELECTOR'
            }
            if ($IsPartOfGroup) {
                Add-Drift -Row $primaryRow -Code 'FORBIDDEN_GROUP_SELECTOR'
            }
            if ($compounds.Count -gt 1) {
                # Descendant / child / sibling - we don't have combinator type
                # surfaced from selector tree at this depth in PostCSS's default
                # output. Treat as descendant for now; future iteration can
                # refine to FORBIDDEN_CHILD_COMBINATOR / FORBIDDEN_SIBLING_COMBINATOR
                # by inspecting the combinator's value in the selector tree.
                Add-Drift -Row $primaryRow -Code 'FORBIDDEN_DESCENDANT'
            }

            # Comment-presence drift
            if ($variantType -and -not $HasTrailingInlineComment) {
                Add-Drift -Row $primaryRow -Code 'MISSING_VARIANT_COMMENT'
            }
            elseif (-not $variantType -and -not $HasPrecedingComment) {
                Add-Drift -Row $primaryRow -Code 'MISSING_PURPOSE_COMMENT'
            }

            # Section context drift
            if (-not $script:CurrentBannerOuter) {
                Add-Drift -Row $primaryRow -Code 'MISSING_SECTION_BANNER'
            }

            # Prefix mismatch: if the active section declared prefixes,
            # the class name must start with one of them followed by '-'
            if ($script:CurrentFilePrefixes -and $script:CurrentFilePrefixes.Count -gt 0) {
                $matched = $false
                foreach ($pfx in $script:CurrentFilePrefixes) {
                    if ($primaryName -ceq $pfx -or $primaryName.StartsWith("$pfx-", [System.StringComparison]::Ordinal)) {
                        $matched = $true; break
                    }
                }
                if (-not $matched) {
                    Add-Drift -Row $primaryRow -Code 'PREFIX_MISMATCH'
                }
            }
        }
    }
    else {
        # Primary compound has only ids — emit HTML_ID with FORBIDDEN_ID_SELECTOR
        $primaryId = $primary.Ids[0]
        $primaryRow = Add-HtmlIdRow -IdName $primaryId `
            -LineStart $LineStart -LineEnd $LineEnd -ColumnStart $ColumnStart `
            -Signature $RuleSelectorText -ParentAtrule $ParentAtrule -RawText $RuleSelectorText
        if ($primaryRow) {
            Add-Drift -Row $primaryRow -Code 'FORBIDDEN_ID_SELECTOR'
            if ($IsPartOfGroup) { Add-Drift -Row $primaryRow -Code 'FORBIDDEN_GROUP_SELECTOR' }
            if (-not $script:CurrentBannerOuter) {
                Add-Drift -Row $primaryRow -Code 'MISSING_SECTION_BANNER'
            }
        }
    }

    # Descendant USAGE rows for compounds after the primary
    for ($i = $primaryIdx + 1; $i -lt $compounds.Count; $i++) {
        $cmp = $compounds[$i]
        if ($cmp.Classes.Count -gt 0) {
            $usageName = $cmp.Classes[0]
            # Variant qualifier extraction same as primary
            $extraClasses = if ($cmp.Classes.Count -gt 1) { $cmp.Classes[1..($cmp.Classes.Count-1)] } else { @() }
            $extraPseudos = $cmp.Pseudos

            $variantType = $null
            $variantQualifier1 = $null
            $variantQualifier2 = $null
            if ($extraClasses.Count -eq 0 -and $extraPseudos.Count -eq 0) {
                $variantType = $null
            }
            elseif ($extraClasses.Count -ge 1 -and $extraPseudos.Count -eq 0) {
                $variantType = 'class'; $variantQualifier1 = ($extraClasses -join '.')
            }
            elseif ($extraClasses.Count -eq 0 -and $extraPseudos.Count -ge 1) {
                $variantType = 'pseudo'; $variantQualifier2 = ($extraPseudos -join ':')
            }
            else {
                $variantType = 'compound_pseudo'
                $variantQualifier1 = ($extraClasses -join '.')
                $variantQualifier2 = ($extraPseudos -join ':')
            }

            $usageRow = Add-CssClassOrVariantRow `
                -ComponentName $usageName `
                -VariantType $variantType `
                -VariantQualifier1 $variantQualifier1 `
                -VariantQualifier2 $variantQualifier2 `
                -ReferenceType 'USAGE' `
                -LineStart $LineStart -LineEnd $LineEnd -ColumnStart $ColumnStart `
                -Signature $RuleSelectorText -ParentAtrule $ParentAtrule -RawText $RuleSelectorText

            if ($usageRow) {
                # Every descendant USAGE row inherits the descendant drift
                Add-Drift -Row $usageRow -Code 'FORBIDDEN_DESCENDANT'
                if ($IsPartOfGroup) { Add-Drift -Row $usageRow -Code 'FORBIDDEN_GROUP_SELECTOR' }
            }
        }
    }
}

# ----- AST recursion --------------------------------------------------------

# Walks the AST. Tracks the previous-sibling node to support detection of
# "preceding comment" (purpose comment) presence for the next rule.
$script:PreviousSibling = $null

function Add-RowsFromAst {
    param(
        [Parameter(Mandatory)] $Node,
        [string] $ParentAtrule = $null
    )

    if ($null -eq $Node) { return }

    if ($Node.type -eq 'comment') {
        $bannerInfo = Get-BannerInfo -CommentText $Node.text
        if ($bannerInfo -and $bannerInfo.IsBanner) {
            $cLine    = if ($Node.source -and $Node.source.start) { [int]$Node.source.start.line } else { 1 }
            $cEndLine = if ($Node.source -and $Node.source.end) { [int]$Node.source.end.line } else { $cLine }
            $cCol     = if ($Node.source -and $Node.source.start -and ($Node.source.start.PSObject.Properties.Name -contains 'column')) {
                            [int]$Node.source.start.column
                        } else { 1 }

            $rawSnippet = Format-SingleLine -Text $Node.text

            $bannerRow = Add-CommentBannerRow -BannerInfo $bannerInfo `
                -LineStart $cLine -LineEnd $cEndLine -ColumnStart $cCol `
                -RawText $rawSnippet

            if ($bannerRow) {
                # Drift checks on the banner row
                if ($bannerInfo.IsMalformed) {
                    Add-Drift -Row $bannerRow -Code 'MALFORMED_SECTION_BANNER'
                }
                if ($bannerInfo.SectionType -and $script:SectionTypeOrder -notcontains $bannerInfo.SectionType) {
                    Add-Drift -Row $bannerRow -Code 'UNKNOWN_SECTION_TYPE'
                }
                if ($null -eq $bannerInfo.Prefixes -or $bannerInfo.Prefixes.Count -eq 0) {
                    Add-Drift -Row $bannerRow -Code 'MISSING_PREFIXES_DECLARATION'
                }
                # Section ordering: section types must be in canonical order
                if ($bannerInfo.SectionType) {
                    $newType = $bannerInfo.SectionType
                    if ($script:CurrentSectionTypes -and $script:CurrentSectionTypes.Count -gt 0) {
                        $lastSeenType = $script:CurrentSectionTypes[-1]
                        $newIdx = [array]::IndexOf($script:SectionTypeOrder, $newType)
                        $lastIdx = [array]::IndexOf($script:SectionTypeOrder, $lastSeenType)
                        if ($newIdx -ge 0 -and $lastIdx -ge 0 -and $newIdx -lt $lastIdx) {
                            Add-Drift -Row $bannerRow -Code 'SECTION_TYPE_ORDER_VIOLATION'
                        }
                    }
                    $script:CurrentSectionTypes += $newType

                    # Track FOUNDATION/CHROME presence for cross-file dup check
                    if ($newType -eq 'FOUNDATION') {
                        $script:fileMeta[$script:CurrentFile].FoundationLine = $cLine
                    }
                    elseif ($newType -eq 'CHROME') {
                        $script:fileMeta[$script:CurrentFile].ChromeLine = $cLine
                    }
                }
            }

            # Update active-banner state for subsequent rows
            $script:CurrentBannerInfo  = $bannerInfo
            $script:CurrentBannerOuter = $bannerInfo.RawTitle
            $script:CurrentFilePrefixes = $bannerInfo.Prefixes

            $script:PreviousSibling = $Node
            return
        }
        # Non-banner comment — just record it as the previous sibling so the
        # next rule's "has preceding comment" check works.
        $script:PreviousSibling = $Node
        return
    }

    if ($Node.type -eq 'rule') {
        $line    = if ($Node.source -and $Node.source.start) { [int]$Node.source.start.line } else { 1 }
        $endLine = if ($Node.source -and $Node.source.end)   { [int]$Node.source.end.line   } else { $line }
        $col     = if ($Node.source -and $Node.source.start -and ($Node.source.start.PSObject.Properties.Name -contains 'column')) {
                       [int]$Node.source.start.column
                   } else { 1 }

        # Did a comment immediately precede this rule?
        $hasPrecedingComment = $false
        if ($script:PreviousSibling -and $script:PreviousSibling.type -eq 'comment') {
            # Distinguish purpose comments from banners: banners have rules of '='
            $bannerCheck = Get-BannerInfo -CommentText $script:PreviousSibling.text
            if (-not $bannerCheck) {
                $hasPrecedingComment = $true
            }
        }

        # Detect trailing inline comment on the same line. For variant detection,
        # we need to know whether the rule has a comment immediately after the
        # opening brace. PostCSS represents this as the first child node of the
        # rule being a comment with the same source line as the rule's selector.
        $hasTrailingInlineComment = $false
        if ($Node.nodes -and $Node.nodes.Count -gt 0) {
            $firstChild = $Node.nodes[0]
            if ($firstChild.type -eq 'comment' -and $firstChild.source -and $firstChild.source.start) {
                if ([int]$firstChild.source.start.line -eq $line) {
                    $hasTrailingInlineComment = $true
                }
            }
        }

        # Comma-grouped selectors → flag every constituent
        $isGroup = $false
        if ($Node.selectors -and $Node.selectors.Count -gt 1) { $isGroup = $true }

        if ($Node.selectorTree -and $Node.selectorTree.nodes) {
            foreach ($sel in $Node.selectorTree.nodes) {
                if ($sel.type -ne 'selector') { continue }
                Add-RowsForSelector -SelectorNode $sel -RuleSelectorText $Node.selector `
                    -LineStart $line -LineEnd $endLine -ColumnStart $col `
                    -ParentAtrule $ParentAtrule `
                    -HasPrecedingComment $hasPrecedingComment `
                    -HasTrailingInlineComment $hasTrailingInlineComment `
                    -IsPartOfGroup $isGroup
            }
        }

        # Walk the rule's body for declarations
        if ($Node.nodes) {
            foreach ($child in $Node.nodes) {
                Add-RowsFromAst -Node $child -ParentAtrule $ParentAtrule
            }
        }
        $script:PreviousSibling = $Node
        return
    }

    if ($Node.type -eq 'decl') {
        $line    = if ($Node.source -and $Node.source.start) { [int]$Node.source.start.line } else { 1 }
        $endLine = if ($Node.source -and $Node.source.end)   { [int]$Node.source.end.line   } else { $line }
        $col     = if ($Node.source -and $Node.source.start -and ($Node.source.start.PSObject.Properties.Name -contains 'column')) {
                       [int]$Node.source.start.column
                   } else { 1 }

        # CSS_VARIABLE DEFINITION
        if ($Node.prop -and $Node.prop.StartsWith('--')) {
            $varName = $Node.prop.Substring(2)
            $varRow = Add-CssVariableRow -VarName $varName -ReferenceType 'DEFINITION' `
                -LineStart $line -LineEnd $endLine -ColumnStart $col `
                -Signature $Node.value -ParentAtrule $ParentAtrule `
                -RawText "$($Node.prop): $($Node.value)"
            if ($varRow) {
                # FORBIDDEN_CUSTOM_PROPERTY_LOCATION if active section is not FOUNDATION
                $activeType = if ($script:CurrentBannerInfo) { $script:CurrentBannerInfo.SectionType } else { $null }
                if ($activeType -ne 'FOUNDATION') {
                    Add-Drift -Row $varRow -Code 'FORBIDDEN_CUSTOM_PROPERTY_LOCATION'
                }
            }
        }

        # CSS_VARIABLE USAGE
        $vars = Get-VarReferences -Value $Node.value
        foreach ($v in $vars) {
            [void](Add-CssVariableRow -VarName $v -ReferenceType 'USAGE' `
                -LineStart $line -LineEnd $endLine -ColumnStart $col `
                -Signature "var(--$v)" -ParentAtrule $ParentAtrule `
                -RawText "$($Node.prop): $($Node.value)")
        }

        # CSS_KEYFRAME USAGE
        if ($Node.prop -in @('animation','animation-name')) {
            foreach ($tok in ($Node.value -split '\s+|,')) {
                $t = $tok.Trim()
                if ($t -and $script:sharedKeyframeMap.ContainsKey($t)) {
                    [void](Add-CssKeyframeRow -KeyframeName $t -ReferenceType 'USAGE' `
                        -LineStart $line -LineEnd $endLine -ColumnStart $col `
                        -Signature "$($Node.prop): $($Node.value)" -ParentAtrule $ParentAtrule `
                        -RawText "$($Node.prop): $($Node.value)")
                }
            }
        }

        # Hex literal tracking — store on file metadata for Pass 3 cross-check
        $hexLiterals = Get-HexLiterals -Value $Node.value
        if ($hexLiterals.Count -gt 0) {
            if (-not $script:fileMeta[$script:CurrentFile].HexLiterals) {
                $script:fileMeta[$script:CurrentFile].HexLiterals = New-Object System.Collections.Generic.List[object]
            }
            foreach ($hex in $hexLiterals) {
                $script:fileMeta[$script:CurrentFile].HexLiterals.Add(@{
                    Hex      = $hex
                    Line     = $line
                    Column   = $col
                    Property = $Node.prop
                    Value    = $Node.value
                })
            }
        }

        $script:PreviousSibling = $Node
        return
    }

    if ($Node.type -eq 'atrule' -and $Node.name -eq 'keyframes') {
        $kfName  = $Node.params.Trim()
        $line    = if ($Node.source -and $Node.source.start) { [int]$Node.source.start.line } else { 1 }
        $endLine = if ($Node.source -and $Node.source.end)   { [int]$Node.source.end.line   } else { $line }
        $col     = if ($Node.source -and $Node.source.start -and ($Node.source.start.PSObject.Properties.Name -contains 'column')) {
                       [int]$Node.source.start.column
                   } else { 1 }

        $kfRow = Add-CssKeyframeRow -KeyframeName $kfName -ReferenceType 'DEFINITION' `
            -LineStart $line -LineEnd $endLine -ColumnStart $col `
            -Signature "@keyframes $kfName" -ParentAtrule $ParentAtrule `
            -RawText "@keyframes $kfName"
        if ($kfRow) {
            $activeType = if ($script:CurrentBannerInfo) { $script:CurrentBannerInfo.SectionType } else { $null }
            if ($activeType -ne 'FOUNDATION') {
                Add-Drift -Row $kfRow -Code 'FORBIDDEN_KEYFRAMES_LOCATION'
            }
        }
        $script:PreviousSibling = $Node
        return
    }

    if ($Node.type -eq 'atrule') {
        $atruleLabel = "@$($Node.name)"
        if ($Node.params) { $atruleLabel = "$atruleLabel $($Node.params)" }
        $atruleLabel = $atruleLabel.Trim()

        # Forbidden at-rules: @import, @font-face, @media, @supports.
        # Emit a CSS_RULE row representing the at-rule (no specific row type
        # for at-rules in our schema) and tag it with the right drift code.
        $line    = if ($Node.source -and $Node.source.start) { [int]$Node.source.start.line } else { 1 }
        $endLine = if ($Node.source -and $Node.source.end)   { [int]$Node.source.end.line   } else { $line }
        $col     = if ($Node.source -and $Node.source.start -and ($Node.source.start.PSObject.Properties.Name -contains 'column')) {
                       [int]$Node.source.start.column
                   } else { 1 }

        if ($Node.name -in @('import','font-face','media','supports')) {
            $atRow = Add-CssRuleRow -LineStart $line -LineEnd $endLine `
                -ColumnStart $col -Signature $atruleLabel -ParentAtrule $ParentAtrule `
                -RawText $atruleLabel
            if ($atRow) {
                switch ($Node.name) {
                    'import'    { Add-Drift -Row $atRow -Code 'FORBIDDEN_AT_IMPORT' }
                    'font-face' { Add-Drift -Row $atRow -Code 'FORBIDDEN_AT_FONT_FACE' }
                    'media'     { Add-Drift -Row $atRow -Code 'FORBIDDEN_AT_MEDIA' }
                    'supports'  { Add-Drift -Row $atRow -Code 'FORBIDDEN_AT_SUPPORTS' }
                }
            }
        }

        # Recurse into children carrying the at-rule label
        if ($Node.nodes) {
            foreach ($child in $Node.nodes) {
                Add-RowsFromAst -Node $child -ParentAtrule $atruleLabel
            }
        }
        $script:PreviousSibling = $Node
        return
    }

    # Root or unknown - recurse
    if ($Node.nodes) {
        foreach ($child in $Node.nodes) {
            Add-RowsFromAst -Node $child -ParentAtrule $ParentAtrule
        }
    }
}

# ----- File header detection -----------------------------------------------

# A spec-compliant file header is the first AST node and is a comment whose
# text contains the Identity / Location / Version / FILE ORGANIZATION fields.
# This function inspects the first node of an AST and emits a FILE_HEADER row,
# attaching drift codes for any header issues.
function Add-FileHeaderForFile {
    param(
        [Parameter(Mandatory)] $AST,
        [Parameter(Mandatory)] [string]$FileName
    )

    $headerRow = $null
    $headerLine = 1
    $headerEnd = 1
    $headerText = $null
    $purposeDescription = $null
    $hasIdentity = $false
    $hasLocation = $false
    $hasVersion  = $false
    $fileOrgList = @()
    $hasChangelog = $false
    $isMalformed = $true   # default to malformed; set false on full match

    if ($AST -and $AST.nodes -and $AST.nodes.Count -gt 0) {
        $first = $AST.nodes[0]
        if ($first.type -eq 'comment') {
            # Make sure this is a header (not a section banner)
            $bannerCheck = Get-BannerInfo -CommentText $first.text
            # If it's a banner, we have NO header. Skip.
            if (-not $bannerCheck -or -not $bannerCheck.IsBanner) {
                $headerLine = if ($first.source -and $first.source.start) { [int]$first.source.start.line } else { 1 }
                $headerEnd  = if ($first.source -and $first.source.end)   { [int]$first.source.end.line   } else { $headerLine }
                $headerText = Format-SingleLine -Text $first.text

                # Inspect content
                if ($first.text -match 'xFACts Control Center\s*-\s*([^()]+)\s*\(([^)]+)\)') {
                    $hasIdentity = $true
                    $purposeDescription = $matches[1].Trim()
                }
                if ($first.text -match 'Location\s*:\s*\S') { $hasLocation = $true }
                if ($first.text -match 'Version\s*:\s*Tracked in dbo\.System_Metadata\s*\(component:\s*\S') { $hasVersion = $true }

                if ($first.text -match 'CHANGELOG') { $hasChangelog = $true }

                # FILE ORGANIZATION list extraction
                $textLines = $first.text -split "`n" | ForEach-Object { $_.TrimEnd() }
                $inFileOrg = $false
                foreach ($line in $textLines) {
                    if ($line -match '^\s*FILE ORGANIZATION\s*$') { $inFileOrg = $true; continue }
                    if ($inFileOrg) {
                        # Skip the rule line
                        if ($line -match '^\s*-+\s*$') { continue }
                        # Stop on first blank line OR closing rule of '='s
                        if ([string]::IsNullOrWhiteSpace($line)) { break }
                        if ($line -match '={5,}') { break }
                        # Match "1. <title>" etc.
                        if ($line -match '^\s*\d+\.\s+(.+?)\s*$') {
                            $fileOrgList += $matches[1].Trim()
                        }
                    }
                }

                if ($hasIdentity -and $hasLocation -and $hasVersion) {
                    $isMalformed = $false
                }
            }
            else {
                # First node was a banner — that means file has no header
                $isMalformed = $true
            }
        }
    }

    $headerRow = Add-FileHeaderRow -FileName $FileName -LineStart $headerLine `
        -LineEnd $headerEnd -RawText $headerText -PurposeDescription $purposeDescription

    if ($headerRow) {
        if ($isMalformed) {
            Add-Drift -Row $headerRow -Code 'MALFORMED_FILE_HEADER'
        }
        if ($hasChangelog) {
            Add-Drift -Row $headerRow -Code 'FORBIDDEN_CHANGELOG'
        }
        # Stash the FILE ORG list on file metadata; Pass 3 will compare to actual banners
        $script:fileMeta[$FileName].FileOrgList = $fileOrgList
    }
    return $headerRow
}

# ----- Per-file orchestration ----------------------------------------------

foreach ($file in $CssFiles) {
    $name = [System.IO.Path]::GetFileName($file)
    $isShared = $SharedFiles -contains $name

    if (-not $astCache.ContainsKey($file)) {
        Write-Log "  Skipping (no parsed AST): $name" "WARN"
        continue
    }

    $script:CurrentFile         = $name
    $script:CurrentFileIsShared = $isShared
    $script:CurrentBannerInfo   = $null
    $script:CurrentBannerOuter  = $null
    $script:CurrentSectionTypes = @()
    $script:CurrentFilePrefixes = $null
    $script:PreviousSibling     = $null
    $script:fileMeta[$name]     = @{
        FoundationLine  = $null
        ChromeLine      = $null
        FileOrgList     = $null
        BannerTitles    = New-Object System.Collections.Generic.List[string]
        HexLiterals     = $null
    }

    $startCount = $rows.Count
    $scopeLabel = if ($isShared) { 'SHARED' } else { 'LOCAL' }
    Write-Host ("  Walking {0} ({1})..." -f $name, $scopeLabel) -ForegroundColor Cyan

    # Emit FILE_HEADER row first
    [void](Add-FileHeaderForFile -AST $astCache[$file].ast -FileName $name)

    # Walk the rest of the AST
    Add-RowsFromAst -Node $astCache[$file].ast

    # Capture banner titles seen in this file (for FILE_ORG_MISMATCH check)
    foreach ($r in $rows) {
        if ($r.FileName -eq $name -and $r.ComponentType -eq 'COMMENT_BANNER') {
            [void]$script:fileMeta[$name].BannerTitles.Add($r.ComponentName)
        }
    }

    $delta = $rows.Count - $startCount
    Write-Host ("    -> {0} rows" -f $delta) -ForegroundColor Green
}

# ============================================================================
# PASS 3 - CODEBASE-LEVEL DRIFT CHECKS
# ============================================================================

Write-Log "Pass 3: codebase-level drift checks..."

# --- DUPLICATE_FOUNDATION / DUPLICATE_CHROME ----------------------------------
$foundationFiles = @($fileMeta.Keys | Where-Object { $fileMeta[$_].FoundationLine })
$chromeFiles     = @($fileMeta.Keys | Where-Object { $fileMeta[$_].ChromeLine })

if ($foundationFiles.Count -gt 1) {
    Write-Log ("  DUPLICATE_FOUNDATION across files: {0}" -f ($foundationFiles -join ', ')) "WARN"
    foreach ($r in $rows) {
        if ($r.ComponentType -eq 'COMMENT_BANNER' -and
            $foundationFiles -contains $r.FileName -and
            $r.Signature -eq 'FOUNDATION') {
            Add-Drift -Row $r -Code 'DUPLICATE_FOUNDATION'
        }
    }
}

if ($chromeFiles.Count -gt 1) {
    Write-Log ("  DUPLICATE_CHROME across files: {0}" -f ($chromeFiles -join ', ')) "WARN"
    foreach ($r in $rows) {
        if ($r.ComponentType -eq 'COMMENT_BANNER' -and
            $chromeFiles -contains $r.FileName -and
            $r.Signature -eq 'CHROME') {
            Add-Drift -Row $r -Code 'DUPLICATE_CHROME'
        }
    }
}

# --- FILE_ORG_MISMATCH --------------------------------------------------------
foreach ($fname in $fileMeta.Keys) {
    $meta = $fileMeta[$fname]
    if ($null -eq $meta.FileOrgList) { continue }
    $declared = @($meta.FileOrgList | ForEach-Object { $_ })
    $actual   = @($meta.BannerTitles | ForEach-Object { $_ })

    $mismatch = $false
    if ($declared.Count -ne $actual.Count) {
        $mismatch = $true
    } else {
        for ($i = 0; $i -lt $declared.Count; $i++) {
            if ($declared[$i] -ne $actual[$i]) { $mismatch = $true; break }
        }
    }
    if ($mismatch) {
        # Attach to the FILE_HEADER row for this file
        foreach ($r in $rows) {
            if ($r.FileName -eq $fname -and $r.ComponentType -eq 'FILE_HEADER') {
                Add-Drift -Row $r -Code 'FILE_ORG_MISMATCH'
                break
            }
        }
    }
}

# --- DRIFT_HEX_LITERAL --------------------------------------------------------
# A hex literal in a non-FOUNDATION file's class declaration triggers drift
# only if a custom property exists for "this color" anywhere shared. We don't
# have a value->property map directly; the practical heuristic is:
# any hex literal in a class declaration when the SHARED variable map has at
# least one custom property defined is a candidate. For now we tag every hex
# literal in a class declaration if the shared variable map is non-empty,
# since the spec says custom properties are mandatory for any value used twice.
# This may produce false positives on values that aren't colors (e.g.,
# hex-encoded scrollbar widths if any) but will catch the meaningful pattern.
if ($sharedVariableMap.Count -gt 0) {
    foreach ($fname in $fileMeta.Keys) {
        $meta = $fileMeta[$fname]
        if ($null -eq $meta.HexLiterals -or $meta.HexLiterals.Count -eq 0) { continue }

        # Skip the file containing FOUNDATION — its hex literals ARE the
        # custom property definitions (or related content)
        if ($meta.FoundationLine) { continue }

        foreach ($hex in $meta.HexLiterals) {
            # Find rows on this file at this line and tag them
            foreach ($r in $rows) {
                if ($r.FileName -eq $fname -and $r.LineStart -eq $hex.Line -and
                    $r.ComponentType -in @('CSS_CLASS', 'CSS_VARIANT')) {
                    Add-Drift -Row $r -Code 'DRIFT_HEX_LITERAL'
                }
            }
        }
    }
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

    $driftedCount = @($rows | Where-Object { $_.DriftCodes }).Count
    Write-Log ("Rows with drift codes: {0} of {1} ({2:F1}%)" -f $driftedCount, $rows.Count, ($driftedCount / [double]$rows.Count * 100))
}

# ============================================================================
# DATABASE WRITE
# ============================================================================

if (-not $Execute) {
    Write-Log "PREVIEW MODE - no rows written to Asset_Registry. Use -Execute to insert." "WARN"
    return
}

Write-Log "Clearing existing CSS rows from Asset_Registry..."
$cleared = Invoke-SqlNonQuery -Query "DELETE FROM dbo.Asset_Registry WHERE file_type = 'CSS';"
if (-not $cleared) {
    Write-Log "Failed to clear existing CSS rows. Aborting." "ERROR"
    exit 1
}

if ($rows.Count -eq 0) {
    Write-Log "No rows to insert." "WARN"
    exit 0
}

Write-Log "Bulk-inserting $($rows.Count) rows..."

# Build DataTable matching the new dbo.Asset_Registry schema
$dt = New-Object System.Data.DataTable
[void]$dt.Columns.Add('file_name',           [string])
[void]$dt.Columns.Add('object_registry_id',  [int])
[void]$dt.Columns.Add('file_type',           [string])
[void]$dt.Columns.Add('line_start',          [int])
[void]$dt.Columns.Add('line_end',            [int])
[void]$dt.Columns.Add('column_start',        [int])
[void]$dt.Columns.Add('component_type',      [string])
[void]$dt.Columns.Add('component_name',      [string])
[void]$dt.Columns.Add('variant_type',        [string])
[void]$dt.Columns.Add('variant_qualifier_1', [string])
[void]$dt.Columns.Add('variant_qualifier_2', [string])
[void]$dt.Columns.Add('reference_type',      [string])
[void]$dt.Columns.Add('scope',               [string])
[void]$dt.Columns.Add('source_file',         [string])
[void]$dt.Columns.Add('source_section',      [string])
[void]$dt.Columns.Add('signature',           [string])
[void]$dt.Columns.Add('parent_function',     [string])
[void]$dt.Columns.Add('raw_text',            [string])
[void]$dt.Columns.Add('purpose_description', [string])
[void]$dt.Columns.Add('design_notes',        [string])
[void]$dt.Columns.Add('related_asset_id',    [int])
[void]$dt.Columns.Add('occurrence_index',    [int])
[void]$dt.Columns.Add('drift_codes',         [string])
[void]$dt.Columns.Add('drift_text',          [string])

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
    } else {
        $row['object_registry_id'] = [System.DBNull]::Value
        [void]$objectRegistryMisses.Add($r.FileName)
    }

    $row['file_type']           = $r.FileType
    $row['line_start']          = if ($null -eq $r.LineStart) { 1 } else { [int]$r.LineStart }
    $row['line_end']            = if ($null -eq $r.LineEnd) { [System.DBNull]::Value } else { [int]$r.LineEnd }
    $row['column_start']        = if ($null -eq $r.ColumnStart) { [System.DBNull]::Value } else { [int]$r.ColumnStart }
    $row['component_type']      = $r.ComponentType
    $row['component_name']      = Get-NullableValue $r.ComponentName 256
    $row['variant_type']        = Get-NullableValue $r.VariantType 30
    $row['variant_qualifier_1'] = Get-NullableValue $r.VariantQualifier1 100
    $row['variant_qualifier_2'] = Get-NullableValue $r.VariantQualifier2 100
    $row['reference_type']      = $r.ReferenceType
    $row['scope']               = $r.Scope
    $row['source_file']         = $r.SourceFile
    $row['source_section']      = Get-NullableValue $r.SourceSection 150
    $row['signature']           = Get-NullableValue $r.Signature
    $row['parent_function']     = Get-NullableValue $r.ParentFunction 200
    $row['raw_text']            = Get-NullableValue $r.RawText
    $row['purpose_description'] = [System.DBNull]::Value
    $row['design_notes']        = [System.DBNull]::Value
    $row['related_asset_id']    = [System.DBNull]::Value
    $row['occurrence_index']    = if ($null -eq $r.OccurrenceIndex) { 1 } else { [int]$r.OccurrenceIndex }
    $row['drift_codes']         = Get-NullableValue $r.DriftCodes 500
    $row['drift_text']          = Get-NullableValue $r.DriftText
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
# VERIFICATION
# ============================================================================

Write-Log "Verification: row counts by component_type / reference_type / scope"

$verify = Get-SqlData -Query @"
SELECT component_type, reference_type, scope, COUNT(*) AS row_count
FROM dbo.Asset_Registry
WHERE file_type = 'CSS'
GROUP BY component_type, reference_type, scope
ORDER BY component_type, reference_type, scope;
"@

if ($verify) { $verify | Format-Table -AutoSize }

Write-Log "Verification: top 20 drift codes by occurrence count"

$driftSummary = Get-SqlData -Query @"
WITH DriftRows AS (
    SELECT TRIM(value) AS code
    FROM dbo.Asset_Registry
    CROSS APPLY STRING_SPLIT(drift_codes, ',')
    WHERE file_type = 'CSS' AND drift_codes IS NOT NULL
)
SELECT TOP 20 code, COUNT(*) AS occurrences
FROM DriftRows
WHERE code <> ''
GROUP BY code
ORDER BY COUNT(*) DESC;
"@

if ($driftSummary) { $driftSummary | Format-Table -AutoSize }

# ----- Object_Registry miss report -----------------------------------------

if ($objectRegistryMisses.Count -gt 0) {
    Write-Log ("Object_Registry registration gaps detected for {0} file(s):" -f $objectRegistryMisses.Count) "WARN"
    foreach ($missing in ($objectRegistryMisses | Sort-Object)) {
        Write-Log ("  MISSING: $missing") "WARN"
    }
    Write-Log "Add the file(s) above to dbo.Object_Registry to enable FK linkage on subsequent runs." "WARN"
}

Write-Log "Done."
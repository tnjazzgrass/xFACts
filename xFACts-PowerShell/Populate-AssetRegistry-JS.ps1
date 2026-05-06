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
2026-05-06  Top-level IIFE handling: file-scope IIFEs are now cataloged
            as a single JS_IIFE row carrying the IIFE source verbatim in
            raw_text plus FORBIDDEN_IIFE drift, and the walker no longer
            descends into the IIFE body. Previously the walker treated an
            IIFE detection as advisory and continued recursing, which
            produced cascade drift on every nested declaration (every
            function inside the IIFE got MISSING_SECTION_BANNER plus
            PREFIX_MISMATCH plus MISSING_FUNCTION_COMMENT) and -- in
            practice on the docs-zone files -- crashed the visitor before
            completing. New mechanism: visitor handlers can return
            'SKIP_CHILDREN' to signal that Invoke-AstWalk should not
            recurse into a node's children. The IIFE handler returns this
            after emitting the JS_IIFE row. Code outside the IIFE (before
            or after at file scope) is still cataloged normally; only the
            IIFE body itself is skipped. Mechanism is general-purpose:
            future structurally-non-conforming patterns can adopt the
            same SKIP_CHILDREN signal if cataloging their interiors would
            produce cascade drift rather than meaningful rows.
2026-05-05  AST walk resilience: each per-file Invoke-AstWalk call is now
            wrapped in try/catch. If the walk throws (latent visitor bug
            triggered by an unusual AST shape, e.g., as observed when
            walking ddl-erd.js), the error is logged, partial rows from
            that file are discarded, and processing continues with the
            next file. The file's FILE_HEADER and COMMENT_BANNER rows are
            preserved (they're emitted before the walk and capture file-
            level structure independent of content extraction). Walk
            failures are populator tooling defects, not spec-compliance
            issues, so no drift code is emitted -- the only signal is
            the WARN log line. Console output for each file's walk now
            includes the zone label, matching the CSS populator's format
            ("Walking <name> (<scope>, zone=<cc|docs>)...").
2026-05-05  Zone awareness added (mirroring the CSS populator's existing
            zone architecture). Three substantive changes:
              (1) ZONE SPLIT. The single global $SharedFiles list is split
                  into $CcSharedFiles (cc-shared.js, engine-events.js) and
                  $DocsSharedFiles (nav.js, docs-controlcenter.js,
                  ddl-erd.js, ddl-loader.js). $SharedFiles is retained as
                  the union for the few places that still need "is this any
                  kind of shared file." New Get-JsZone helper derives zone
                  from filepath (\public\docs\js\ -> docs; otherwise cc),
                  same shape as Get-CssZone.
              (2) PER-ZONE SHARED MAPS. Pass 1's $sharedFunctions /
                  $sharedConstants / $sharedClasses / $sharedSourceFile
                  hashtables are now per-zone: $ccSharedFunctions,
                  $docsSharedFunctions, etc. The CSS pre-load query result
                  is similarly bucketed into $ccSharedClassMap /
                  $docsSharedClassMap / $ccLocalClassMap / $docsLocalClassMap
                  using each row's file_name to determine zone. New
                  $script:CurrentFileZone state, set per-file in Pass 2.
                  Zone-aware accessor functions (Get-ZoneSharedClassMap,
                  Get-ZoneLocalClassMap, Get-ZoneSharedFunctions,
                  Get-ZoneSharedSourceFile) return the zone-appropriate
                  map for the file currently being walked.
              (3) ZONE-AWARE RESOLUTION. Add-ClassUsageRow,
                  Add-JsFunctionUsageRow, and the SHADOWS_SHARED_FUNCTION
                  detection pass all consume the accessors. Net effect: a
                  CC page can no longer wrongly resolve a USAGE row to a
                  docs-zone shared file (or vice versa), and a CC page
                  defining a function whose name happens to match a
                  docs-zone shared name is no longer flagged as shadowing.
            Migration support: cc-shared.js (the spec-compliant new shared
            file) and engine-events.js (the legacy shared file currently in
            use by every page) are both listed in $CcSharedFiles during
            the page-by-page migration period; engine-events.js is removed
            once every page has cut over.
2026-05-05  HTML_ID rows now always emitted with scope='LOCAL' per JS spec
            Section 17.3, regardless of whether the source file is a
            shared file. The previous behavior stamped HTML_ID rows in
            cc-shared.js (and engine-events.js) with scope='SHARED' based
            on $CurrentFileIsShared, which conflicts with the spec's
            "IDs are inherently page-specific" rule. Even when an id
            appears inside a markup template emitted by a shared utility,
            the id itself is a single-page concept.
2026-05-05  Phase 1 bug fixes from the methodology audit:
              (1) BUG A - Phantom banner from file-header misclassification.
                  Test-IsBannerComment was returning true on the file
                  header because the FILE ORGANIZATION list contains lines
                  matching <TYPE>: <NAME> for valid section types. Result:
                  the file header was getting collected as a phantom
                  banner #0, inflating the section list by one and
                  causing FILE_ORG_MISMATCH (counts didn't match) plus
                  spurious MISSING_PREFIX_DECLARATION on the phantom row.
                  Fix: Test-IsBannerComment now disqualifies header-shaped
                  comments via Location:/Version:/xFACts-identity-line
                  guards (matching the CSS populator's existing pattern).
              (2) BUG B - $SectionTypeOrder map predated JS spec v1.3.
                  The map ordered CHROME=3 / STATE=5 (v1.0/v1.1 ordering),
                  but spec v1.3 reorganized cc-shared.js to put STATE
                  before CHROME. Result: every cc-shared.js parse fired a
                  spurious SECTION_TYPE_ORDER_VIOLATION. Fix: updated map
                  to put STATE=3, CHROME=4 (sharing slot with INITIALIZATION
                  since CHROME = cc-shared.js's INITIALIZATION+FUNCTIONS).
                  FOUNDATION and CONSTANTS share slot 2 (parallel concepts
                  in shared vs page files).
              (3) ENCODING. Source file normalized to pure ASCII. Three
                  Windows-1252 em-dashes in comments converted to '--'.
                  PowerShell editors no longer warn about unsupported
                  Unicode characters when saving.
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

# Shared files split by zone. Each zone's consumers resolve USAGE references
# only against their own zone's shared map. CC pages cannot consume docs JS
# (and vice versa); single-pool resolution would produce wrong USAGE
# attribution when names happened to collide across zones.
#
# CC zone migration in progress: cc-shared.js is the spec-compliant
# replacement for engine-events.js. Both are listed during the migration so
# pages can consume either while the page-by-page refactor proceeds. After
# every page has migrated, engine-events.js comes off the list and out of
# the codebase.
#
# Docs zone shared files are nav.js (the docs nav bar) and docs-controlcenter.js
# (the docs Control Center documentation page); the docs zone has no page
# consumers today, but the zone separation is structurally enforced so that
# CC pages don't pick up docs-zone names by accident.
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

# Same shared-CSS-file split, used to bucket CSS_CLASS DEFINITION rows from
# the database pre-load into per-zone maps. The JS populator does not parse
# CSS files itself but needs to know which CSS shared files are CC-zone vs.
# docs-zone so JS-side CSS_CLASS USAGE rows resolve only against their own
# zone's CSS shared classes. Mirrors the CSS populator's $CcSharedFiles /
# $DocsSharedFiles. Kept in sync manually for now; if the lists drift, JS
# consumers may resolve CSS_CLASS USAGE rows to '<undefined>' even though
# the class is defined elsewhere in the catalog.
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
# Page files use:    IMPORTS -> CONSTANTS -> STATE -> INITIALIZATION -> FUNCTIONS
# cc-shared.js uses: IMPORTS -> FOUNDATION -> STATE -> CHROME
# FOUNDATION and CONSTANTS share slot 2 (parallel concepts in shared vs. page files).
# CHROME and INITIALIZATION share slot 4 (CHROME = cc-shared.js's INITIALIZATION+FUNCTIONS
# combined; per JS spec v1.3 Section 4.2).
$SectionTypeOrder = @{
    'IMPORTS'        = 1
    'FOUNDATION'     = 2
    'CONSTANTS'      = 2
    'STATE'          = 3
    'INITIALIZATION' = 4
    'CHROME'         = 4
    'FUNCTIONS'      = 5
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

# Determine which zone a JS file belongs to based on its filepath. Files
# under public\docs\js\ are docs-zone; everything else is cc-zone. Used both
# during Pass 1 (to decide which zone's shared map to populate) and during
# Pass 2 (to scope USAGE resolution).
function Get-JsZone {
    param([string]$FullPath)
    if ($FullPath -match '\\public\\docs\\js\\') { return 'docs' }
    return 'cc'
}

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
        [string]$VariantType,
        [string]$VariantQualifier1,
        [string]$VariantQualifier2,
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
        VariantType        = $VariantType
        VariantQualifier1  = $VariantQualifier1
        VariantQualifier2  = $VariantQualifier2
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
# The visitor receives ($Node, $ParentChain, $ParentNodes) where:
#   - $ParentChain is an array of ancestor node TYPE strings
#   - $ParentNodes is an array of ancestor node references (parallel to chain)
# The parallel $ParentNodes array lets the visitor inspect actual parent
# nodes (e.g. to find which VariableDeclarator a FunctionExpression is the
# init of), enabling parent_function tracking and FORBIDDEN_ANONYMOUS_FUNCTION
# detection.
function Invoke-AstWalk {
    param(
        $Node,
        [array]$ParentChain = @(),
        [array]$ParentNodes = @(),
        [Parameter(Mandatory)][scriptblock]$Visitor
    )

    if ($null -eq $Node) { return }

    if ($Node -is [System.Array] -or $Node -is [System.Collections.IList]) {
        foreach ($item in $Node) {
            Invoke-AstWalk -Node $item -ParentChain $ParentChain -ParentNodes $ParentNodes -Visitor $Visitor
        }
        return
    }

    if ($Node -isnot [System.Management.Automation.PSCustomObject]) { return }
    if (-not ($Node.PSObject.Properties.Name -contains 'type')) { return }

    # Visitor may return 'SKIP_CHILDREN' to signal that the walker should
    # not recurse into this node's children. Used for structurally
    # forbidden constructs (e.g., top-level IIFEs) where per-row
    # cataloging of the body would just produce cascade drift -- one
    # FORBIDDEN_* row at the construct itself is the meaningful catalog
    # entry; the body is captured verbatim in raw_text on that row.
    $visitorResult = & $Visitor $Node $ParentChain $ParentNodes
    if ($null -ne $visitorResult -and ($visitorResult -contains 'SKIP_CHILDREN')) {
        return
    }

    $newChain = @($ParentChain + $Node.type)
    $newNodes = @($ParentNodes + $Node)
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
        Invoke-AstWalk -Node $val -ParentChain $newChain -ParentNodes $newNodes -Visitor $Visitor
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

# Find the closest enclosing function/method/class name by walking back
# through the parent-node chain. Returns:
#   - the function/method declaration's name (FunctionDeclaration.id.name,
#     MethodDefinition.key.name)
#   - for FunctionExpression/ArrowFunctionExpression passed as a CallExpression
#     argument (allowed-callback context), the callee's display name
#   - $null if no enclosing function context found (USAGE is at module scope)
#   - '<anonymous>' for unnameable function expressions (these will also
#     produce FORBIDDEN_ANONYMOUS_FUNCTION drift at the const/var declaration site)
function Get-CurrentParentName {
    param([array]$ParentNodes)

    if ($null -eq $ParentNodes -or $ParentNodes.Count -eq 0) { return $null }

    # Walk backwards through parents looking for the closest container
    for ($i = $ParentNodes.Count - 1; $i -ge 0; $i--) {
        $p = $ParentNodes[$i]
        if ($null -eq $p -or $null -eq $p.type) { continue }

        switch ($p.type) {
            'FunctionDeclaration' {
                if ($p.id -and $p.id.name) { return $p.id.name }
                return '<anonymous>'
            }
            'MethodDefinition' {
                if ($p.key -and $p.key.type -eq 'Identifier' -and $p.key.name) {
                    return $p.key.name
                }
                if ($p.kind -eq 'constructor') { return 'constructor' }
                return '<anonymous>'
            }
            'FunctionExpression' {
                $name = Get-NameForFunctionExpression -ParentNodes $ParentNodes -ExpressionIndex $i
                return $name
            }
            'ArrowFunctionExpression' {
                $name = Get-NameForFunctionExpression -ParentNodes $ParentNodes -ExpressionIndex $i
                return $name
            }
        }
    }

    return $null
}

# Resolve the effective name of a FunctionExpression / ArrowFunctionExpression
# by inspecting its immediate parent context. Under the v1.2 spec, function
# expressions are only spec-allowed as callback arguments -- every other context
# is a FORBIDDEN_ANONYMOUS_FUNCTION violation. This helper is still called
# for the violation cases because USAGE rows nested inside the violating
# expression need *some* parent_function value; we record the const/var name
# (or `<anonymous>` if none) so the catalog row points at the right place.
function Get-NameForFunctionExpression {
    param(
        [array]$ParentNodes,
        [int]$ExpressionIndex
    )

    $parentSlot = $ExpressionIndex - 1
    if ($parentSlot -lt 0) { return '<anonymous>' }
    $parent = $ParentNodes[$parentSlot]
    if ($null -eq $parent) { return '<anonymous>' }

    switch ($parent.type) {
        'VariableDeclarator' {
            if ($parent.id -and $parent.id.type -eq 'Identifier' -and $parent.id.name) {
                return $parent.id.name
            }
            return '<anonymous>'
        }
        'AssignmentExpression' {
            $left = $parent.left
            if ($left -and $left.type -eq 'MemberExpression' -and
                $left.property -and $left.property.type -eq 'Identifier' -and
                $left.property.name) {
                return $left.property.name
            }
            if ($left -and $left.type -eq 'Identifier' -and $left.name) {
                return $left.name
            }
            return '<anonymous>'
        }
        'Property' {
            if ($parent.key -and $parent.key.type -eq 'Identifier' -and $parent.key.name) {
                return $parent.key.name
            }
            if ($parent.key -and $parent.key.type -eq 'Literal' -and $parent.key.value) {
                return [string]$parent.key.value
            }
            return '<anonymous>'
        }
        'CallExpression' {
            # Function expression is being passed as a callback argument --
            # the spec-allowed context. Use the callee's display name.
            $callee = $parent.callee
            if ($null -eq $callee) { return '<anonymous>' }
            if ($callee.type -eq 'Identifier') { return $callee.name }
            if ($callee.type -eq 'MemberExpression' -and
                $callee.property -and $callee.property.type -eq 'Identifier') {
                return ".$($callee.property.name)"
            }
            return '<anonymous>'
        }
        default {
            return '<anonymous>'
        }
    }
}

# Determine whether a FunctionExpression / ArrowFunctionExpression is in a
# spec-allowed position. Under v1.2 there is exactly one allowed context:
# 'callback'  - argument to a CallExpression or NewExpression (Section 14.1)
# Everything else returns 'forbidden'.
function Get-FunctionExpressionContext {
    param(
        [array]$ParentNodes,
        [int]$ExpressionIndex
    )

    $parentSlot = $ExpressionIndex - 1
    if ($parentSlot -lt 0) { return 'forbidden' }
    $parent = $ParentNodes[$parentSlot]
    if ($null -eq $parent) { return 'forbidden' }

    switch ($parent.type) {
        'CallExpression' { return 'callback' }
        'NewExpression'  { return 'callback' }
        default          { return 'forbidden' }
    }
}

# ============================================================================
# VARIANT SHAPE HELPERS
# ============================================================================
# Each helper inspects an AST node (or relevant context) and returns a
# hashtable describing the row's variant shape:
#   @{
#       ComponentType     = 'JS_FUNCTION' | 'JS_FUNCTION_VARIANT' | ...
#       VariantType       = 'arrow' | 'async' | 'object' | $null
#       VariantQualifier1 = (reserved; mostly $null)
#       VariantQualifier2 = (e.g. import source-module-path)
#   }
# Per CC_JS_Spec.md v1.2 Section 17.5.

# JS_FUNCTION (base) vs JS_FUNCTION_VARIANT (async/generator).
# Under v1.2 spec, only FunctionDeclaration nodes produce JS_FUNCTION rows.
# Function/arrow expressions assigned to const/var are forbidden patterns
# (FORBIDDEN_ANONYMOUS_FUNCTION on the const/var declaration row instead).
function Get-FunctionVariantShape {
    param($Node)

    if ($Node.type -ne 'FunctionDeclaration') {
        # Not reached in compliant code; defensive fallback.
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
# Input: $InitNode is the declarator's init expression, possibly $null.
function Get-ConstantVariantShape {
    param($InitNode)

    if ($null -eq $InitNode) {
        return @{ ComponentType = 'JS_CONSTANT'; VariantType = $null; VariantQualifier1 = $null; VariantQualifier2 = $null }
    }

    switch ($InitNode.type) {
        'Literal' {
            # Regex literal carries a non-null `regex` property
            if ($InitNode.PSObject.Properties.Name -contains 'regex' -and $null -ne $InitNode.regex) {
                return @{ ComponentType = 'JS_CONSTANT_VARIANT'; VariantType = 'regex'; VariantQualifier1 = $null; VariantQualifier2 = $null }
            }
            # Primitive literal (string, number, boolean, null)
            return @{ ComponentType = 'JS_CONSTANT'; VariantType = $null; VariantQualifier1 = $null; VariantQualifier2 = $null }
        }
        'TemplateLiteral' {
            # Template literal with no expressions is a string primitive
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
            # const X = SOMEOTHER_CONST - a reference is a computed expression
            return @{ ComponentType = 'JS_CONSTANT_VARIANT'; VariantType = 'expression'; VariantQualifier1 = $null; VariantQualifier2 = $null }
        }
        'ObjectExpression' {
            return @{ ComponentType = 'JS_CONSTANT_VARIANT'; VariantType = 'object'; VariantQualifier1 = $null; VariantQualifier2 = $null }
        }
        'ArrayExpression' {
            return @{ ComponentType = 'JS_CONSTANT_VARIANT'; VariantType = 'array'; VariantQualifier1 = $null; VariantQualifier2 = $null }
        }
        default {
            # CallExpression, BinaryExpression, NewExpression, ConditionalExpression,
            # MemberExpression, FunctionExpression, ArrowFunctionExpression, etc.
            # The function/arrow expression cases also trigger FORBIDDEN_ANONYMOUS_FUNCTION
            # at the call site; the row classification is still 'expression' since
            # that's what the AST actually shows.
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
# Input: $CalleeName is 'setInterval' or 'setTimeout'.
function Get-TimerVariantShape {
    param([string]$CalleeName)

    $vt = if ($CalleeName -eq 'setInterval') { 'interval' } else { 'timeout' }
    return @{ ComponentType = 'JS_TIMER'; VariantType = $vt; VariantQualifier1 = $null; VariantQualifier2 = $null }
}

# JS_IMPORT - always a variant (no base form).
# Inputs: $Specifier is an ImportSpecifier / ImportDefaultSpecifier /
# ImportNamespaceSpecifier; $SourcePath is the source module path string.
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

# JS_IMPORT for require() calls (CommonJS form).
function Get-RequireVariantShape {
    param([string]$SourcePath)
    return @{ ComponentType = 'JS_IMPORT'; VariantType = 'require'; VariantQualifier1 = $null; VariantQualifier2 = $SourcePath }
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

    # File headers also contain '=' rules and a FILE ORGANIZATION list whose
    # entries match the <TYPE>: <NAME> shape. Distinguish by the header-specific
    # markers (Location: with drive prefix, Version: tracked-in-System_Metadata,
    # or the xFACts identity line). If any are present, this is the file header
    # and is not a banner.
    if ($CommentText -match 'Location\s*:\s*[A-Za-z]:[\\/]' -or
        $CommentText -match 'Version\s*:\s*Tracked in dbo\.System_Metadata' -or
        $CommentText -match 'xFACts Control Center\s*-\s*[^=]+\(.+\.[a-z]+\)') {
        return $false
    }

    # Must contain a TYPE: NAME line where TYPE is a recognized section type.
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
# PASS 1 - PARSE ALL FILES, COLLECT SHARED-SCOPE DEFINITIONS (zone-aware)
# ============================================================================
# Walk every file once to:
#   1. Cache the parse result (used by Pass 2)
#   2. Collect top-level definitions from $CcSharedFiles + $DocsSharedFiles
#      members into per-zone maps so Pass 2 can resolve USAGE rows to their
#      SHARED source within the consumer's own zone only.
#   3. Track which files declare FOUNDATION or CHROME sections (cross-file
#      uniqueness check happens after Pass 2).

Write-Log "Pass 1: parse all files, collect SHARED-scope JS definitions (zone-aware)..."

$astCache = @{}

# Per-zone shared-name maps. CC consumers resolve only against $ccShared*;
# docs consumers resolve only against $docsShared*. Same split applied to
# functions, constants, classes, and the source-file lookup that records
# which file each shared name came from.
$ccSharedFunctions   = New-Object 'System.Collections.Generic.HashSet[string]'
$ccSharedConstants   = New-Object 'System.Collections.Generic.HashSet[string]'
$ccSharedClasses     = New-Object 'System.Collections.Generic.HashSet[string]'
$ccSharedSourceFile  = @{}
$docsSharedFunctions = New-Object 'System.Collections.Generic.HashSet[string]'
$docsSharedConstants = New-Object 'System.Collections.Generic.HashSet[string]'
$docsSharedClasses   = New-Object 'System.Collections.Generic.HashSet[string]'
$docsSharedSourceFile = @{}

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

    # If this is a shared file, collect its top-level definitions into the
    # zone-appropriate maps.
    if ($SharedFiles -notcontains $name) { continue }

    if ($zone -eq 'docs') {
        $sharedFunctions  = $docsSharedFunctions
        $sharedConstants  = $docsSharedConstants
        $sharedClasses    = $docsSharedClasses
        $sharedSourceFile = $docsSharedSourceFile
    } else {
        $sharedFunctions  = $ccSharedFunctions
        $sharedConstants  = $ccSharedConstants
        $sharedClasses    = $ccSharedClasses
        $sharedSourceFile = $ccSharedSourceFile
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

Write-Log ("  CC zone   - shared functions: {0}" -f $ccSharedFunctions.Count)
Write-Log ("  CC zone   - shared constants: {0}" -f $ccSharedConstants.Count)
Write-Log ("  CC zone   - shared classes:   {0}" -f $ccSharedClasses.Count)
Write-Log ("  Docs zone - shared functions: {0}" -f $docsSharedFunctions.Count)
Write-Log ("  Docs zone - shared constants: {0}" -f $docsSharedConstants.Count)
Write-Log ("  Docs zone - shared classes:   {0}" -f $docsSharedClasses.Count)

# ============================================================================
# LOAD CSS_CLASS DEFINITIONS FROM Asset_Registry FOR SCOPE RESOLUTION (zone-aware)
# ============================================================================
# Outcome of this load is captured in $cssPreLoadState so the verification
# pass at the end of the run can warn the user when CSS-class scope was
# resolved against an empty or missing source. Possible values:
#   'OK'           - the query returned rows
#   'EMPTY'        - the query succeeded but returned zero rows; this means
#                    the CSS populator hasn't been run yet, and every
#                    CSS_CLASS USAGE row will be stamped scope='LOCAL' /
#                    source_file='<undefined>'
#   'QUERY_FAILED' - the query returned $null (the helper logs the SQL
#                    error separately); same downstream effect as EMPTY.
#
# CSS_CLASS DEFINITION rows are bucketed into per-zone maps based on the
# row's file_name matched against $CcSharedCssFiles / $DocsSharedCssFiles
# (for SHARED rows) or grouped by zone via the file_name's location for
# LOCAL rows. CC-zone JS consumers resolve only against $ccSharedClassMap;
# docs-zone JS consumers resolve only against $docsSharedClassMap.

Write-Log "Loading existing CSS_CLASS DEFINITION rows for scope resolution..."

$cssDefs = Get-SqlData -Query @"
SELECT component_name, scope, file_name
FROM dbo.Asset_Registry
WHERE component_type = 'CSS_CLASS'
  AND reference_type = 'DEFINITION'
  AND file_type = 'CSS';
"@

$ccSharedClassMap   = @{}
$docsSharedClassMap = @{}
$ccLocalClassMap    = @{}
$docsLocalClassMap  = @{}
$cssPreLoadState = 'QUERY_FAILED'

if ($null -ne $cssDefs) {
    $defArray = @($cssDefs)
    if ($defArray.Count -eq 0) {
        $cssPreLoadState = 'EMPTY'
    }
    else {
        $cssPreLoadState = 'OK'
        foreach ($d in $defArray) {
            $cn = $d.component_name
            if ([string]::IsNullOrEmpty($cn)) { continue }
            $fn = $d.file_name
            # Zone bucket: SHARED rows route by their file_name match against the
            # zone's known shared CSS files; LOCAL rows route by file_name's
            # docs-prefix convention (docs-* CSS files are always docs-zone).
            $isDocs = ($DocsSharedCssFiles -contains $fn) -or ($fn -like 'docs-*')
            if ($d.scope -eq 'SHARED') {
                if ($isDocs) {
                    if (-not $docsSharedClassMap.ContainsKey($cn)) {
                        $docsSharedClassMap[$cn] = $fn
                    }
                } else {
                    if (-not $ccSharedClassMap.ContainsKey($cn)) {
                        $ccSharedClassMap[$cn] = $fn
                    }
                }
            }
            else {
                if ($isDocs) {
                    if (-not $docsLocalClassMap.ContainsKey($cn)) {
                        $docsLocalClassMap[$cn] = $fn
                    }
                } else {
                    if (-not $ccLocalClassMap.ContainsKey($cn)) {
                        $ccLocalClassMap[$cn] = $fn
                    }
                }
            }
        }
    }
}

switch ($cssPreLoadState) {
    'OK' {
        Write-Log ("  CC zone   - shared CSS classes:     {0}" -f $ccSharedClassMap.Count)
        Write-Log ("  CC zone   - local-only CSS classes: {0}" -f $ccLocalClassMap.Count)
        Write-Log ("  Docs zone - shared CSS classes:     {0}" -f $docsSharedClassMap.Count)
        Write-Log ("  Docs zone - local-only CSS classes: {0}" -f $docsLocalClassMap.Count)
    }
    'EMPTY' {
        Write-Log "CSS_CLASS DEFINITION query returned zero rows. Class scope resolution will mark everything '<undefined>'." "WARN"
    }
    'QUERY_FAILED' {
        Write-Log "Could not load CSS_CLASS DEFINITION rows. Class scope resolution will mark everything '<undefined>'." "WARN"
    }
}

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
$script:CurrentFileZone       = 'cc'   # 'cc' or 'docs' -- drives shared-map selection for USAGE resolution
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

# ----- Zone-aware shared-map accessors --------------------------------------
#
# These accessors return the shared map appropriate to the current file's
# zone. CC consumers see only $ccShared* maps; docs consumers see only
# $docsShared* maps. This prevents a CC page from accidentally resolving a
# class or function name to a docs-zone shared definition (or vice versa).

function Get-ZoneSharedClassMap {
    if ($script:CurrentFileZone -eq 'docs') { return $script:docsSharedClassMap }
    return $script:ccSharedClassMap
}

function Get-ZoneLocalClassMap {
    if ($script:CurrentFileZone -eq 'docs') { return $script:docsLocalClassMap }
    return $script:ccLocalClassMap
}

function Get-ZoneSharedFunctions {
    if ($script:CurrentFileZone -eq 'docs') { return $script:docsSharedFunctions }
    return $script:ccSharedFunctions
}

function Get-ZoneSharedSourceFile {
    if ($script:CurrentFileZone -eq 'docs') { return $script:docsSharedSourceFile }
    return $script:ccSharedSourceFile
}

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
    $sharedMap = Get-ZoneSharedClassMap
    $localMap  = Get-ZoneLocalClassMap
    if ($sharedMap.ContainsKey($ClassName)) {
        $scope = 'SHARED'
        $sourceFile = $sharedMap[$ClassName]
    }
    elseif ($localMap.ContainsKey($ClassName)) {
        $scope = 'LOCAL'
        $sourceFile = $localMap[$ClassName]
    }

    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|CSS_CLASS|$ClassName|USAGE|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $section = Get-SectionForLine -Sections $script:CurrentSections -Line $LineStart
    $sourceSection = if ($section) { $section.FullTitle } else { $null }

    $row = New-AssetRow -FileName $script:CurrentFile -LineStart $LineStart `
        -LineEnd $LineStart -ColumnStart $ColumnStart `
        -ComponentType 'CSS_CLASS' -ComponentName $ClassName `
        -VariantType $null -VariantQualifier1 $null -VariantQualifier2 $null `
        -ReferenceType 'USAGE' `
        -Scope $scope -SourceFile $sourceFile `
        -SourceSection $sourceSection `
        -Signature $Signature `
        -ParentFunction $ParentFunction `
        -RawText $RawText `
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

    # Per JS spec Section 17.3: HTML_ID rows are ALWAYS LOCAL. IDs are
    # inherently page-specific; the SHARED/LOCAL distinction does not apply
    # to id attributes. Even when the id appears inside cc-shared.js (e.g.,
    # in a markup template emitted by a shared utility), the id itself is
    # still a single-page concept.
    $scope = 'LOCAL'
    $sourceFile = $script:CurrentFile

    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|HTML_ID|$IdName|$ReferenceType|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $section = Get-SectionForLine -Sections $script:CurrentSections -Line $LineStart
    $sourceSection = if ($section) { $section.FullTitle } else { $null }

    $row = New-AssetRow -FileName $script:CurrentFile -LineStart $LineStart `
        -LineEnd $LineStart -ColumnStart $ColumnStart `
        -ComponentType 'HTML_ID' -ComponentName $IdName `
        -VariantType $null -VariantQualifier1 $null -VariantQualifier2 $null `
        -ReferenceType $ReferenceType `
        -Scope $scope -SourceFile $sourceFile `
        -SourceSection $sourceSection `
        -Signature $Signature `
        -ParentFunction $ParentFunction `
        -RawText $RawText `
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
    $sourceFile = $script:CurrentFile

    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|$ComponentType|$ComponentName|DEFINITION|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $sourceSection = if ($Section) { $Section.FullTitle } else { $null }

    $row = New-AssetRow -FileName $script:CurrentFile -LineStart $LineStart `
        -LineEnd $LineEnd -ColumnStart $ColumnStart `
        -ComponentType $ComponentType -ComponentName $ComponentName `
        -VariantType $VariantType -VariantQualifier1 $VariantQualifier1 -VariantQualifier2 $VariantQualifier2 `
        -ReferenceType 'DEFINITION' `
        -Scope $scope -SourceFile $sourceFile `
        -SourceSection $sourceSection `
        -Signature $Signature `
        -ParentFunction $ParentFunction `
        -RawText $RawText `
        -PurposeDescription $PurposeDescription
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

    $sharedFns = Get-ZoneSharedFunctions
    $sharedSrc = Get-ZoneSharedSourceFile
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

    $section = Get-SectionForLine -Sections $script:CurrentSections -Line $LineStart
    $sourceSection = if ($section) { $section.FullTitle } else { $null }

    $row = New-AssetRow -FileName $script:CurrentFile -LineStart $LineStart `
        -LineEnd $LineStart -ColumnStart $ColumnStart `
        -ComponentType 'JS_FUNCTION' -ComponentName $FunctionName `
        -VariantType $null -VariantQualifier1 $null -VariantQualifier2 $null `
        -ReferenceType 'USAGE' `
        -Scope $scope -SourceFile $sourceFile `
        -SourceSection $sourceSection `
        -Signature $Signature `
        -ParentFunction $ParentFunction `
        -RawText $RawText `
        -PurposeDescription $null
    $script:rows.Add($row)
    return $row
}

# JS_EVENT row emitter. Under v1.2 spec, JS_EVENT has no variants -- both
# `addEventListener` and the forbidden `el.onX = handler` style produce
# rows of the same shape. The $IsForbidden flag attaches
# FORBIDDEN_PROPERTY_ASSIGN_EVENT drift when the row originated from the
# property-assign style.
function Add-JsEventRow {
    param(
        [string]$EventName,
        [int]$LineStart,
        [int]$ColumnStart,
        [string]$Signature,
        [string]$ParentFunction,
        [string]$RawText,
        [bool]$IsForbidden = $false
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
        -VariantType $null -VariantQualifier1 $null -VariantQualifier2 $null `
        -ReferenceType 'USAGE' `
        -Scope $scope -SourceFile $sourceFile `
        -SourceSection $sourceSection `
        -Signature $Signature `
        -ParentFunction $ParentFunction `
        -RawText $RawText `
        -PurposeDescription $null
    $script:rows.Add($row)

    if ($IsForbidden) {
        Add-DriftCode -Row $row -Code 'FORBIDDEN_PROPERTY_ASSIGN_EVENT' `
            -Text "Event '$EventName' bound via property-assign style at line $LineStart; spec requires addEventListener."
    }

    return $row
}

# ----- Forbidden-pattern row emitters ---------------------------------------
# Each forbidden pattern that has no natural declaration host gets its own
# component_type and a dedicated row at the violation site, with the
# corresponding FORBIDDEN_* drift attached. Goal: every violation is visible
# in the row set with no aggregation needed.

# Add a JS_IIFE row at an immediately-invoked function expression site.
function Add-JsIifeRow {
    param(
        [int]$LineStart,
        [int]$LineEnd,
        [int]$ColumnStart,
        [string]$Signature,
        [string]$RawText
    )

    $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }
    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|JS_IIFE|<iife>|DEFINITION|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $section = Get-SectionForLine -Sections $script:CurrentSections -Line $LineStart
    $sourceSection = if ($section) { $section.FullTitle } else { $null }

    $row = New-AssetRow -FileName $script:CurrentFile -LineStart $LineStart `
        -LineEnd $LineEnd -ColumnStart $ColumnStart `
        -ComponentType 'JS_IIFE' -ComponentName '<iife>' `
        -VariantType $null -VariantQualifier1 $null -VariantQualifier2 $null `
        -ReferenceType 'DEFINITION' `
        -Scope $scope -SourceFile $script:CurrentFile `
        -SourceSection $sourceSection `
        -Signature $Signature `
        -ParentFunction $null `
        -RawText $RawText `
        -PurposeDescription $null
    $script:rows.Add($row)

    Add-DriftCode -Row $row -Code 'FORBIDDEN_IIFE' `
        -Text "IIFE at file scope, line $LineStart."
    return $row
}

# Add a JS_EVAL row at an eval(...) call site.
function Add-JsEvalRow {
    param(
        [int]$LineStart,
        [int]$LineEnd,
        [int]$ColumnStart,
        [string]$Signature,
        [string]$ParentFunction,
        [string]$RawText
    )

    $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }
    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|JS_EVAL|<eval>|USAGE|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $section = Get-SectionForLine -Sections $script:CurrentSections -Line $LineStart
    $sourceSection = if ($section) { $section.FullTitle } else { $null }

    $row = New-AssetRow -FileName $script:CurrentFile -LineStart $LineStart `
        -LineEnd $LineEnd -ColumnStart $ColumnStart `
        -ComponentType 'JS_EVAL' -ComponentName '<eval>' `
        -VariantType $null -VariantQualifier1 $null -VariantQualifier2 $null `
        -ReferenceType 'USAGE' `
        -Scope $scope -SourceFile $script:CurrentFile `
        -SourceSection $sourceSection `
        -Signature $Signature `
        -ParentFunction $ParentFunction `
        -RawText $RawText `
        -PurposeDescription $null
    $script:rows.Add($row)

    Add-DriftCode -Row $row -Code 'FORBIDDEN_EVAL' `
        -Text "eval() called at line $LineStart."
    return $row
}

# Add a JS_DOCUMENT_WRITE row at a document.write(...) call site.
function Add-JsDocumentWriteRow {
    param(
        [int]$LineStart,
        [int]$LineEnd,
        [int]$ColumnStart,
        [string]$Signature,
        [string]$ParentFunction,
        [string]$RawText
    )

    $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }
    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|JS_DOCUMENT_WRITE|<document.write>|USAGE|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $section = Get-SectionForLine -Sections $script:CurrentSections -Line $LineStart
    $sourceSection = if ($section) { $section.FullTitle } else { $null }

    $row = New-AssetRow -FileName $script:CurrentFile -LineStart $LineStart `
        -LineEnd $LineEnd -ColumnStart $ColumnStart `
        -ComponentType 'JS_DOCUMENT_WRITE' -ComponentName '<document.write>' `
        -VariantType $null -VariantQualifier1 $null -VariantQualifier2 $null `
        -ReferenceType 'USAGE' `
        -Scope $scope -SourceFile $script:CurrentFile `
        -SourceSection $sourceSection `
        -Signature $Signature `
        -ParentFunction $ParentFunction `
        -RawText $RawText `
        -PurposeDescription $null
    $script:rows.Add($row)

    Add-DriftCode -Row $row -Code 'FORBIDDEN_DOCUMENT_WRITE' `
        -Text "document.write() called at line $LineStart."
    return $row
}

# Add a JS_WINDOW_ASSIGNMENT row for `window.<name> = ...` outside cc-shared.js.
function Add-JsWindowAssignmentRow {
    param(
        [string]$AssignedName,
        [int]$LineStart,
        [int]$LineEnd,
        [int]$ColumnStart,
        [string]$Signature,
        [string]$ParentFunction,
        [string]$RawText
    )

    $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }
    $componentName = "window.$AssignedName"
    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|JS_WINDOW_ASSIGNMENT|$componentName|DEFINITION|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $section = Get-SectionForLine -Sections $script:CurrentSections -Line $LineStart
    $sourceSection = if ($section) { $section.FullTitle } else { $null }

    $row = New-AssetRow -FileName $script:CurrentFile -LineStart $LineStart `
        -LineEnd $LineEnd -ColumnStart $ColumnStart `
        -ComponentType 'JS_WINDOW_ASSIGNMENT' -ComponentName $componentName `
        -VariantType $null -VariantQualifier1 $null -VariantQualifier2 $null `
        -ReferenceType 'DEFINITION' `
        -Scope $scope -SourceFile $script:CurrentFile `
        -SourceSection $sourceSection `
        -Signature $Signature `
        -ParentFunction $ParentFunction `
        -RawText $RawText `
        -PurposeDescription $null
    $script:rows.Add($row)

    Add-DriftCode -Row $row -Code 'FORBIDDEN_WINDOW_ASSIGNMENT' `
        -Text "Assignment to $componentName at line $LineStart; outside cc-shared.js."
    return $row
}

# Add a JS_INLINE_STYLE row when a JS template/string literal contains <style>.
function Add-JsInlineStyleRow {
    param(
        [int]$LineStart,
        [int]$LineEnd,
        [int]$ColumnStart,
        [string]$Signature,
        [string]$ParentFunction,
        [string]$RawText
    )

    $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }
    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|JS_INLINE_STYLE|<style>|DEFINITION|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $section = Get-SectionForLine -Sections $script:CurrentSections -Line $LineStart
    $sourceSection = if ($section) { $section.FullTitle } else { $null }

    $row = New-AssetRow -FileName $script:CurrentFile -LineStart $LineStart `
        -LineEnd $LineEnd -ColumnStart $ColumnStart `
        -ComponentType 'JS_INLINE_STYLE' -ComponentName '<style>' `
        -VariantType $null -VariantQualifier1 $null -VariantQualifier2 $null `
        -ReferenceType 'DEFINITION' `
        -Scope $scope -SourceFile $script:CurrentFile `
        -SourceSection $sourceSection `
        -Signature $Signature `
        -ParentFunction $ParentFunction `
        -RawText $RawText `
        -PurposeDescription $null
    $script:rows.Add($row)

    Add-DriftCode -Row $row -Code 'FORBIDDEN_INLINE_STYLE_IN_JS' `
        -Text "Template/string literal contains <style> at line $LineStart."
    return $row
}

# Add a JS_INLINE_SCRIPT row when a JS template/string literal contains <script>.
function Add-JsInlineScriptRow {
    param(
        [int]$LineStart,
        [int]$LineEnd,
        [int]$ColumnStart,
        [string]$Signature,
        [string]$ParentFunction,
        [string]$RawText
    )

    $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }
    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|JS_INLINE_SCRIPT|<script>|DEFINITION|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $section = Get-SectionForLine -Sections $script:CurrentSections -Line $LineStart
    $sourceSection = if ($section) { $section.FullTitle } else { $null }

    $row = New-AssetRow -FileName $script:CurrentFile -LineStart $LineStart `
        -LineEnd $LineEnd -ColumnStart $ColumnStart `
        -ComponentType 'JS_INLINE_SCRIPT' -ComponentName '<script>' `
        -VariantType $null -VariantQualifier1 $null -VariantQualifier2 $null `
        -ReferenceType 'DEFINITION' `
        -Scope $scope -SourceFile $script:CurrentFile `
        -SourceSection $sourceSection `
        -Signature $Signature `
        -ParentFunction $ParentFunction `
        -RawText $RawText `
        -PurposeDescription $null
    $script:rows.Add($row)

    Add-DriftCode -Row $row -Code 'FORBIDDEN_INLINE_SCRIPT_IN_JS' `
        -Text "Template/string literal contains <script> at line $LineStart."
    return $row
}

# Add a JS_LINE_COMMENT row at a file-scope `//` comment site.
function Add-JsLineCommentRow {
    param(
        [int]$LineStart,
        [int]$ColumnStart,
        [string]$RawText
    )

    $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }
    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|JS_LINE_COMMENT|<line-comment>|DEFINITION|"
    if (-not (Test-AddDedupeKey -Key $key)) { return $null }

    $row = New-AssetRow -FileName $script:CurrentFile -LineStart $LineStart `
        -LineEnd $LineStart -ColumnStart $ColumnStart `
        -ComponentType 'JS_LINE_COMMENT' -ComponentName '<line-comment>' `
        -VariantType $null -VariantQualifier1 $null -VariantQualifier2 $null `
        -ReferenceType 'DEFINITION' `
        -Scope $scope -SourceFile $script:CurrentFile `
        -SourceSection $null `
        -Signature $RawText `
        -ParentFunction $null `
        -RawText $RawText `
        -PurposeDescription $null
    $script:rows.Add($row)

    Add-DriftCode -Row $row -Code 'FORBIDDEN_FILE_SCOPE_LINE_COMMENT' `
        -Text "Line comment at file scope, line $LineStart."
    return $row
}
# ============================================================================
# PASS 2 - THE VISITOR
# ============================================================================
# Walks each file's AST emitting rows and applying drift codes inline. The
# visitor receives ($Node, $ParentChain, $ParentNodes) on every visit. State
# is read from $script:Current* variables set up by the per-file orchestration
# loop.

$visitor = {
    param($Node, $ParentChain, $ParentNodes)

    if ($null -eq $Node -or $null -eq $Node.type) { return }

    $line = Get-NodeLine -Node $Node
    $endLine = Get-NodeEndLine -Node $Node
    $col = Get-NodeColumn -Node $Node

    # The section this node lives in
    $section = Get-SectionForLine -Sections $script:CurrentSections -Line $line

    # The closest enclosing function/method/class name for parent_function
    # stamping. $null when the node is at module scope.
    $parentName = Get-CurrentParentName -ParentNodes $ParentNodes

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

            # Build signature - uses async/generator keyword as appropriate
            $sig = if ($Node.async -eq $true) { "async function $fnName(" }
                   elseif ($Node.generator -eq $true) { "function* $fnName(" }
                   else { "function $fnName(" }
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

            # Determine component type and variant: hooks live in the PAGE
            # LIFECYCLE HOOKS banner (use Get-HookVariantShape); functions
            # elsewhere use Get-FunctionVariantShape.
            $isInHooksBanner = ($section -and
                                 $section.TypeName -eq 'FUNCTIONS' -and
                                 $section.BannerName -eq $script:HooksBannerName)
            $shape = if ($isInHooksBanner) {
                Get-HookVariantShape -Node $Node
            } else {
                Get-FunctionVariantShape -Node $Node
            }

            # Capture preceding comment for purpose_description
            $rawComment = Get-PrecedingBlockComment -CommentIndex $script:CurrentCommentIndex -DefinitionLine $line
            $purpose = ConvertTo-CleanCommentText -CommentText $rawComment

            $row = Add-JsDefinitionRow -ComponentType $shape.ComponentType `
                -ComponentName $fnName `
                -VariantType $shape.VariantType `
                -VariantQualifier1 $shape.VariantQualifier1 `
                -VariantQualifier2 $shape.VariantQualifier2 `
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

                # Prefix check (skip for hooks, which use fixed names)
                $isHook = ($shape.ComponentType -eq 'JS_HOOK' -or $shape.ComponentType -eq 'JS_HOOK_VARIANT')
                if (-not $isHook -and -not $section.IsPrefixNone) {
                    $expectedPrefix = $section.PrefixValue
                    if (-not [string]::IsNullOrEmpty($expectedPrefix)) {
                        $expected = "$expectedPrefix" + "_"
                        if (-not $fnName.StartsWith($expected)) {
                            Add-DriftCode -Row $row -Code 'PREFIX_MISMATCH' `
                                -Text "Function '$fnName' does not start with the section's prefix '$expected'."
                        }
                    }
                }
                elseif ($isHook) {
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
            $isMulti = ($Node.declarations -and $Node.declarations.Count -gt 1)

            # Forbidden 'let'
            $isLet = ($Node.kind -eq 'let')

            foreach ($decl in $Node.declarations) {
                if (-not $decl.id -or $decl.id.type -ne 'Identifier') { continue }

                $declName = $decl.id.name
                $declLine = Get-NodeLine -Node $decl
                $declCol  = Get-NodeColumn -Node $decl
                $declEnd  = Get-NodeEndLine -Node $decl
                $init     = $decl.init

                # ClassExpression assigned to const/var -> JS_CLASS row.
                # This is permitted (not flagged) since classes have no
                # base/anonymous distinction analogous to functions.
                if ($init -and $init.type -eq 'ClassExpression') {
                    $sig = "$($Node.kind) $declName = class"
                    $rawComment = Get-PrecedingBlockComment -CommentIndex $script:CurrentCommentIndex -DefinitionLine $declLine
                    $purpose = ConvertTo-CleanCommentText -CommentText $rawComment

                    $row = Add-JsDefinitionRow -ComponentType 'JS_CLASS' `
                        -ComponentName $declName `
                        -VariantType $null -VariantQualifier1 $null -VariantQualifier2 $null `
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

                # All other declarations (including the now-forbidden cases of
                # function/arrow expressions assigned to const/var) classify
                # as JS_CONSTANT/JS_CONSTANT_VARIANT or JS_STATE based on the
                # section type and declaration kind. The shape helper picks
                # variant_type from the init expression's AST shape; for
                # function/arrow expressions this returns 'expression'.
                # Forbidden patterns get drift attached after row emission.
                $isFunctionInit = ($init -and ($init.type -eq 'FunctionExpression' -or $init.type -eq 'ArrowFunctionExpression'))

                $isConstantSection = ($section -and ($section.TypeName -eq 'CONSTANTS' -or $section.TypeName -eq 'FOUNDATION'))
                $isStateSection    = ($section -and $section.TypeName -eq 'STATE')

                # Component type derivation: section-context first, fall back to kind
                $isStateComponent = $false
                if ($isStateSection) {
                    $isStateComponent = $true
                }
                elseif ($isConstantSection) {
                    $isStateComponent = $false
                }
                elseif ($Node.kind -eq 'var') {
                    $isStateComponent = $true
                }
                else {
                    $isStateComponent = $false
                }

                if ($isStateComponent) {
                    $shape = @{ ComponentType = 'JS_STATE'; VariantType = $null; VariantQualifier1 = $null; VariantQualifier2 = $null }
                }
                else {
                    $shape = Get-ConstantVariantShape -InitNode $init
                }

                # Build signature
                $valSig = if ($init -and $init.type -eq 'Literal') {
                    "$($Node.kind) $declName = $($init.raw)"
                }
                elseif ($init) {
                    "$($Node.kind) $declName = ..."
                }
                else {
                    "$($Node.kind) $declName"
                }

                $rawComment = Get-PrecedingBlockComment -CommentIndex $script:CurrentCommentIndex -DefinitionLine $declLine
                $purpose = ConvertTo-CleanCommentText -CommentText $rawComment

                $row = Add-JsDefinitionRow -ComponentType $shape.ComponentType `
                    -ComponentName $declName `
                    -VariantType $shape.VariantType `
                    -VariantQualifier1 $shape.VariantQualifier1 `
                    -VariantQualifier2 $shape.VariantQualifier2 `
                    -LineStart $declLine -LineEnd $declEnd -ColumnStart $declCol `
                    -Signature $valSig -ParentFunction $null -RawText $valSig `
                    -PurposeDescription $purpose `
                    -Section $section
                if (-not $row) { continue }

                # Drift checks
                if ($isLet)   { Add-DriftCode -Row $row -Code 'FORBIDDEN_LET' -Text "'$declName' is declared with 'let'." }
                if ($isMulti) { Add-DriftCode -Row $row -Code 'FORBIDDEN_MULTI_DECLARATION' -Text "Multiple declarations on one statement." }

                # Forbidden function/arrow expression assigned to const/var
                if ($isFunctionInit) {
                    $shapeWord = if ($init.type -eq 'ArrowFunctionExpression') { 'arrow function' } else { 'function expression' }
                    Add-DriftCode -Row $row -Code 'FORBIDDEN_ANONYMOUS_FUNCTION' `
                        -Text "$declName is assigned a $shapeWord; spec mandates the 'function name() {}' form for function definitions."
                }

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
                    if ($isStateComponent) {
                        Add-DriftCode -Row $row -Code 'MISSING_STATE_COMMENT' -Text "State variable '$declName' has no preceding purpose comment."
                    }
                    else {
                        Add-DriftCode -Row $row -Code 'MISSING_CONSTANT_COMMENT' -Text "Constant '$declName' has no preceding purpose comment."
                    }
                }

                # Section presence and prefix
                if ($null -eq $section) {
                    Add-DriftCode -Row $row -Code 'MISSING_SECTION_BANNER' -Text "'$declName' appears outside any section banner."
                }
                else {
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
                -VariantType $null -VariantQualifier1 $null -VariantQualifier2 $null `
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
            if (-not $Node.key -or $Node.key.type -ne 'Identifier') {
                # Constructor or computed key - handle constructor specially
                if ($Node.kind -eq 'constructor') {
                    $methodName = 'constructor'
                }
                else {
                    return
                }
            }
            else {
                $methodName = $Node.key.name
            }
            $sig = "$methodName(...)"
            if ($Node.kind -eq 'constructor') { $sig = "constructor(...)" }

            $shape = Get-MethodVariantShape -Node $Node

            # parent_function for METHOD rows = enclosing class name. Walk
            # back through parent nodes to find the ClassDeclaration/ClassExpression.
            $className = $null
            for ($i = $ParentNodes.Count - 1; $i -ge 0; $i--) {
                $p = $ParentNodes[$i]
                if ($p -and ($p.type -eq 'ClassDeclaration' -or $p.type -eq 'ClassExpression')) {
                    if ($p.id -and $p.id.name) {
                        $className = $p.id.name
                    }
                    break
                }
            }

            $rawComment = Get-PrecedingBlockComment -CommentIndex $script:CurrentCommentIndex -DefinitionLine $line
            $purpose = ConvertTo-CleanCommentText -CommentText $rawComment

            $row = Add-JsDefinitionRow -ComponentType $shape.ComponentType `
                -ComponentName $methodName `
                -VariantType $shape.VariantType `
                -VariantQualifier1 $shape.VariantQualifier1 `
                -VariantQualifier2 $shape.VariantQualifier2 `
                -LineStart $line -LineEnd $endLine -ColumnStart $col `
                -Signature $sig -ParentFunction $className -RawText $sig `
                -PurposeDescription $purpose `
                -Section $section
            if (-not $row) { return }

            if ([string]::IsNullOrEmpty($purpose)) {
                Add-DriftCode -Row $row -Code 'MISSING_METHOD_COMMENT' -Text "Method '$methodName' has no preceding purpose comment."
            }
        }

        'ImportDeclaration' {
            $sourceVal = if ($Node.source -and $Node.source.value) { [string]$Node.source.value } else { '?' }
            foreach ($spec in $Node.specifiers) {
                $importedName = $null
                if ($spec.local -and $spec.local.name) { $importedName = $spec.local.name }
                if ($importedName) {
                    $shape = Get-ImportVariantShape -Specifier $spec -SourcePath $sourceVal
                    Add-JsDefinitionRow -ComponentType $shape.ComponentType `
                        -ComponentName $importedName `
                        -VariantType $shape.VariantType `
                        -VariantQualifier1 $shape.VariantQualifier1 `
                        -VariantQualifier2 $shape.VariantQualifier2 `
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

            # Forbidden: eval(...) -> emit JS_EVAL row at the violation site
            if ($callee.type -eq 'Identifier' -and $callee.name -eq 'eval') {
                $sig = 'eval(...)'
                Add-JsEvalRow -LineStart $line -LineEnd $endLine -ColumnStart $col `
                    -Signature $sig -ParentFunction $parentName `
                    -RawText $sig | Out-Null
            }

            # Forbidden: document.write(...) -> emit JS_DOCUMENT_WRITE row
            if (Test-CalleeMatchesEnd -Callee $callee -Path @('document','write')) {
                $sig = 'document.write(...)'
                Add-JsDocumentWriteRow -LineStart $line -LineEnd $endLine -ColumnStart $col `
                    -Signature $sig -ParentFunction $parentName `
                    -RawText $sig | Out-Null
            }

            # Direct function call: foo(...)
            if ($callee.type -eq 'Identifier') {
                $fnName = $callee.name
                $sig = "$fnName(...)"
                Add-JsFunctionUsageRow -FunctionName $fnName `
                    -LineStart $line -ColumnStart $col `
                    -Signature $sig -ParentFunction $parentName `
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
                                -Signature $sig -ParentFunction $parentName `
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
                        -Signature $sig -ParentFunction $parentName `
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
                            -Signature $sig -ParentFunction $parentName `
                            -RawText $sig | Out-Null
                    }
                    $classMatches = [regex]::Matches($selector, '\.([\w-]+)')
                    foreach ($cm in $classMatches) {
                        Add-ClassUsageRow -ClassName $cm.Groups[1].Value `
                            -LineStart (Get-NodeLine -Node $arg) `
                            -ColumnStart (Get-NodeColumn -Node $arg) `
                            -Signature $sig -ParentFunction $parentName `
                            -RawText $sig | Out-Null
                    }
                }
            }

            # addEventListener('event', ...) -> JS_EVENT row (allowed pattern)
            if (Test-CalleeMatchesEnd -Callee $callee -Path @('addEventListener')) {
                $arg = $Node.arguments | Select-Object -First 1
                if ($arg -and $arg.type -eq 'Literal' -and $arg.value -is [string]) {
                    $evName = $arg.value
                    $sig = "addEventListener('$evName', ...)"
                    Add-JsEventRow -EventName $evName `
                        -LineStart (Get-NodeLine -Node $arg) `
                        -ColumnStart (Get-NodeColumn -Node $arg) `
                        -Signature $sig -ParentFunction $parentName `
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
                            -Signature $sig -ParentFunction $parentName `
                            -RawText $sig | Out-Null
                    }
                    elseif ($attrName -eq 'class' -and -not [string]::IsNullOrWhiteSpace($attrVal)) {
                        $sig = "setAttribute('class', '$attrVal')"
                        $classNames = Split-ClassNames -Value $attrVal
                        foreach ($cls in $classNames) {
                            Add-ClassUsageRow -ClassName $cls `
                                -LineStart (Get-NodeLine -Node $arg2) `
                                -ColumnStart (Get-NodeColumn -Node $arg2) `
                                -Signature $sig -ParentFunction $parentName `
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
                    $shape = Get-RequireVariantShape -SourcePath $modName
                    Add-JsDefinitionRow -ComponentType $shape.ComponentType `
                        -ComponentName $modName `
                        -VariantType $shape.VariantType `
                        -VariantQualifier1 $shape.VariantQualifier1 `
                        -VariantQualifier2 $shape.VariantQualifier2 `
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

            $rawSnippet = Get-RangeText -Source $script:CurrentFileSource -Node $Node

            # Forbidden inline style/script -> emit JS_INLINE_STYLE / JS_INLINE_SCRIPT rows
            if (Test-LooksLikeInlineStyle -Text $reconstructed) {
                Add-JsInlineStyleRow -LineStart $line -LineEnd $endLine -ColumnStart $col `
                    -Signature 'template literal contains <style>' `
                    -ParentFunction $parentName `
                    -RawText $rawSnippet | Out-Null
            }
            if (Test-LooksLikeInlineScript -Text $reconstructed) {
                Add-JsInlineScriptRow -LineStart $line -LineEnd $endLine -ColumnStart $col `
                    -Signature 'template literal contains <script>' `
                    -ParentFunction $parentName `
                    -RawText $rawSnippet | Out-Null
            }

            if (-not (Test-LooksLikeHtml -Text $reconstructed)) { return }

            Add-RowsFromHtmlBearingText -Text $reconstructed `
                -StartLine $line -StartCol $col `
                -ParentFunction $parentName `
                -RawText $rawSnippet
        }

        'Literal' {
            if ($null -eq $Node.value) { return }
            if (-not ($Node.value -is [string])) { return }
            $strVal = [string]$Node.value

            $rawSnippet = Get-RangeText -Source $script:CurrentFileSource -Node $Node

            # Forbidden inline style/script -> emit JS_INLINE_STYLE / JS_INLINE_SCRIPT rows
            if (Test-LooksLikeInlineStyle -Text $strVal) {
                Add-JsInlineStyleRow -LineStart $line -LineEnd $endLine -ColumnStart $col `
                    -Signature 'string literal contains <style>' `
                    -ParentFunction $parentName `
                    -RawText $rawSnippet | Out-Null
            }
            if (Test-LooksLikeInlineScript -Text $strVal) {
                Add-JsInlineScriptRow -LineStart $line -LineEnd $endLine -ColumnStart $col `
                    -Signature 'string literal contains <script>' `
                    -ParentFunction $parentName `
                    -RawText $rawSnippet | Out-Null
            }

            if (-not (Test-LooksLikeHtml -Text $strVal)) { return }

            Add-RowsFromHtmlBearingText -Text $strVal `
                -StartLine $line -StartCol $col `
                -ParentFunction $parentName `
                -RawText $rawSnippet
        }

        # ------- Group A & C: assignment patterns -------------------------

        'AssignmentExpression' {
            $left = $Node.left
            $right = $Node.right
            if ($null -eq $left -or $null -eq $right) { return }

            # Pattern 1: window.X = ... (forbidden outside cc-shared.js) -> emit JS_WINDOW_ASSIGNMENT row
            if ($left.type -eq 'MemberExpression' -and
                -not $left.computed -and
                $left.object -and $left.object.type -eq 'Identifier' -and
                $left.object.name -eq 'window' -and
                $left.property -and $left.property.type -eq 'Identifier') {
                if ($script:CurrentFile -ne $script:CanonicalSharedFile -and
                    $script:CurrentFile -ne 'engine-events.js') {
                    $assignedName = $left.property.name
                    $sig = "window.$assignedName = ..."
                    Add-JsWindowAssignmentRow -AssignedName $assignedName `
                        -LineStart $line -LineEnd $endLine -ColumnStart $col `
                        -Signature $sig -ParentFunction $parentName `
                        -RawText $sig | Out-Null
                }
            }

            # Pattern 2: TimerHandle = setInterval(...) | setTimeout(...)
            # JS_TIMER row when LHS is an Identifier matching a tracked
            # state-variable handle, and RHS is a CallExpression to
            # setInterval/setTimeout. The assignment can live anywhere
            # (function body or module scope - we catalog the assignment site).
            if ($left.type -eq 'Identifier' -and
                $right.type -eq 'CallExpression' -and
                $right.callee -and $right.callee.type -eq 'Identifier' -and
                ($right.callee.name -eq 'setInterval' -or $right.callee.name -eq 'setTimeout') -and
                $script:CurrentTimerHandles -and
                $script:CurrentTimerHandles.Contains($left.name)) {

                $handleName = $left.name
                $callKind = $right.callee.name
                $sig = "$handleName = $callKind(...)"
                $shape = Get-TimerVariantShape -CalleeName $callKind

                $secForTimer = Get-SectionForLine -Sections $script:CurrentSections -Line $line
                $sourceSection = if ($secForTimer) { $secForTimer.FullTitle } else { $null }

                $key = "$($script:CurrentFile)|$line|$col|JS_TIMER|$handleName|DEFINITION|"
                if (Test-AddDedupeKey -Key $key) {
                    $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }
                    $row = New-AssetRow -FileName $script:CurrentFile -LineStart $line `
                        -LineEnd $endLine -ColumnStart $col `
                        -ComponentType $shape.ComponentType -ComponentName $handleName `
                        -VariantType $shape.VariantType `
                        -VariantQualifier1 $shape.VariantQualifier1 `
                        -VariantQualifier2 $shape.VariantQualifier2 `
                        -ReferenceType 'DEFINITION' `
                        -Scope $scope -SourceFile $script:CurrentFile `
                        -SourceSection $sourceSection `
                        -Signature $sig `
                        -ParentFunction $parentName `
                        -RawText $sig `
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
                        -ParentFunction $parentName `
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
                        -ParentFunction $parentName `
                        -RawText "id = '$idVal'" | Out-Null
                }
            }

            # el.on<event> = handler -> JS_EVENT row with FORBIDDEN_PROPERTY_ASSIGN_EVENT drift
            if ($propName -match '^on([a-z]+)$') {
                $evName = $matches[1]
                $sig = "$propName = ..."
                Add-JsEventRow -EventName $evName `
                    -LineStart $line -ColumnStart $col `
                    -Signature $sig -ParentFunction $parentName `
                    -RawText $sig `
                    -IsForbidden $true | Out-Null
            }
        }

        # ------- IIFE detection (file-scope expression statements) ----------

        'ExpressionStatement' {
            # Detect IIFE at top level: (function() {...})() or (() => {...})()
            # Per spec Section 12.x, file-scope IIFEs are forbidden. When one
            # is detected we emit a single JS_IIFE row carrying the entire
            # IIFE source in raw_text, then signal the walker to skip the
            # IIFE body. The body is structurally outside any spec section
            # (no banner above it, no FILE ORGANIZATION list entry covering
            # it) so per-row cataloging of its contents would just produce
            # cascade drift on every nested declaration -- the file-level
            # FORBIDDEN_IIFE drift on the JS_IIFE row is the meaningful
            # signal. Code outside the IIFE (before or after) is still
            # cataloged normally; only the IIFE body itself is skipped.
            $isTopLevel = Test-IsTopLevel -ParentChain $ParentChain
            if ($isTopLevel -and $Node.expression -and $Node.expression.type -eq 'CallExpression') {
                $iifeCallee = $Node.expression.callee
                if ($iifeCallee -and ($iifeCallee.type -eq 'FunctionExpression' -or $iifeCallee.type -eq 'ArrowFunctionExpression')) {
                    $sig = '(function() { ... })()'
                    if ($iifeCallee.type -eq 'ArrowFunctionExpression') { $sig = '(() => { ... })()' }
                    $rawSnippet = Get-RangeText -Source $script:CurrentFileSource -Node $Node
                    Add-JsIifeRow -LineStart $line -LineEnd $endLine -ColumnStart $col `
                        -Signature $sig `
                        -RawText $rawSnippet | Out-Null
                    return 'SKIP_CHILDREN'
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
    $zone = Get-JsZone -FullPath $file

    if (-not $astCache.ContainsKey($file)) {
        Write-Log "  Skipping (no parsed AST): $name" "WARN"
        continue
    }

    $parsed = $astCache[$file]

    # Set per-file context for the visitor
    $script:CurrentFile         = $name
    $script:CurrentFileIsShared = $isShared
    $script:CurrentFileZone     = $zone
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
        -VariantType $null -VariantQualifier1 $null -VariantQualifier2 $null `
        -ReferenceType 'DEFINITION' `
        -Scope $fileScope -SourceFile $name `
        -SourceSection $null `
        -Signature $null `
        -ParentFunction $null `
        -RawText $null `
        -PurposeDescription $headerInfo.Description
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
            -VariantType $null -VariantQualifier1 $null -VariantQualifier2 $null `
            -ReferenceType 'DEFINITION' `
            -Scope $fileScope -SourceFile $name `
            -SourceSection $s.FullTitle `
            -Signature $s.TypeName `
            -ParentFunction $null `
            -RawText $null `
            -PurposeDescription $s.Description
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
    Write-Host ("  Walking {0} ({1}, zone={2})..." -f $name, $scopeLabel, $zone) -ForegroundColor Cyan

    try {
        Invoke-AstWalk -Node $parsed.Ast -Visitor $visitor
    } catch {
        # AST walk failed mid-flight. Discard whatever partial rows the walk
        # added (everything past $startCount) and continue with the next
        # file. The file's FILE_HEADER and COMMENT_BANNER rows were emitted
        # before the walk and stay; they capture the file-level structure
        # even when content extraction failed. The error is logged so the
        # operator can investigate. NOTE: a walk failure is a populator
        # tooling defect, not a spec-compliance issue, so it does not
        # generate a drift code on the row.
        $partialAdded = $rows.Count - $startCount
        if ($partialAdded -gt 0) {
            for ($i = 0; $i -lt $partialAdded; $i++) {
                $rows.RemoveAt($rows.Count - 1)
            }
        }
        # Capture diagnostic context for visitor bug investigation.
        # InvocationInfo points at the outermost call site (often the
        # recursive Invoke-AstWalk), which is unhelpful for a deep recursion.
        # ScriptStackTrace gives the full call chain; the deepest non-walker
        # frame is usually the actual offending line.
        $errLine = if ($_.InvocationInfo) { $_.InvocationInfo.ScriptLineNumber } else { 0 }
        $errLineText = if ($_.InvocationInfo) { $_.InvocationInfo.Line.Trim() } else { '' }
        Write-Log ("AST walk failed on {0}: {1} (populator line {2}: {3})" -f $name, $_.Exception.Message, $errLine, $errLineText) "WARN"
        if ($_.ScriptStackTrace) {
            Write-Log ("  ScriptStackTrace:") "WARN"
            foreach ($frameLine in ($_.ScriptStackTrace -split "`r?`n")) {
                if (-not [string]::IsNullOrWhiteSpace($frameLine)) {
                    Write-Log ("    " + $frameLine.Trim()) "WARN"
                }
            }
        }
        Write-Host ("    -> walk failed; FILE_HEADER and COMMENT_BANNER rows kept, content rows discarded ({0} discarded)" -f $partialAdded) -ForegroundColor Yellow
        continue
    }

    # ----- File-scope // line comments -> JS_LINE_COMMENT rows -----
    # Acorn returns Line comments alongside Block comments. Any line comment
    # at file scope (outside any function body) is a forbidden pattern under
    # spec Section 12.1, and gets a JS_LINE_COMMENT row at its own line with
    # FORBIDDEN_FILE_SCOPE_LINE_COMMENT drift attached. "File-scope" =
    # not inside a function body, approximated by checking the comment's
    # line against the body ranges of every FunctionDeclaration /
    # FunctionExpression / ArrowFunctionExpression in the file.
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

# SHADOWS_SHARED_FUNCTION (zone-aware)
# Collect every function-shaped DEFINITION row and check for name collisions
# with the shared functions in the row's own zone. A CC-zone page only
# shadows when its definition collides with a CC-zone shared function; cross-
# zone collisions (e.g., a CC page defining a function whose name happens to
# match a docs-zone shared function) are unrelated namespaces and not
# shadowing. Under spec v1.2 a function declaration may be classified as
# JS_FUNCTION (sync, no modifiers) or JS_FUNCTION_VARIANT (async, generator).
# Both shapes can shadow a shared name.

# Build a quick filename->zone lookup for the shadow pass.
$jsFileZoneByName = @{}
foreach ($file in $JsFiles) {
    $name = [System.IO.Path]::GetFileName($file)
    if (-not $jsFileZoneByName.ContainsKey($name)) {
        $jsFileZoneByName[$name] = (Get-JsZone -FullPath $file)
    }
}

$shadowCandidates = @($rows | Where-Object {
    ($_.ComponentType -eq 'JS_FUNCTION' -or $_.ComponentType -eq 'JS_FUNCTION_VARIANT') -and
    $_.ReferenceType -eq 'DEFINITION' -and
    $_.Scope -eq 'LOCAL'
})

foreach ($row in $shadowCandidates) {
    $rowZone = if ($jsFileZoneByName.ContainsKey($row.FileName)) { $jsFileZoneByName[$row.FileName] } else { 'cc' }
    if ($rowZone -eq 'docs') {
        $zoneShared    = $docsSharedFunctions
        $zoneSharedSrc = $docsSharedSourceFile
    } else {
        $zoneShared    = $ccSharedFunctions
        $zoneSharedSrc = $ccSharedSourceFile
    }
    if (-not $zoneShared.Contains($row.ComponentName)) { continue }
    $shadowSourceFile = if ($zoneSharedSrc.ContainsKey($row.ComponentName)) { $zoneSharedSrc[$row.ComponentName] } else { '<shared>' }
    Add-DriftCode -Row $row -Code 'SHADOWS_SHARED_FUNCTION' `
        -Text "Function '$($row.ComponentName)' shadows the shared definition in '$shadowSourceFile'."
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

# Build DataTable matching dbo.Asset_Registry schema (post G-INIT-3 cleanup,
# plus the three variant columns added in the file-format initiative).
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
[void]$dt.Columns.Add('drift_codes',         [string])
[void]$dt.Columns.Add('drift_text',          [string])
[void]$dt.Columns.Add('occurrence_index',    [int])

# Convert a value to a DBNull-aware DataTable cell value. Empty/whitespace
# strings collapse to NULL. Length truncation is NOT performed here:
# under the spec v1.2 column-width review the DB columns are sized to
# accommodate the values the parser produces, so any oversized value should
# surface as a SQL error rather than silently lose data.
function Get-NullableValue {
    param($Value)
    if ($null -eq $Value) { return [System.DBNull]::Value }
    if ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value)) {
        return [System.DBNull]::Value
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
    $row['component_name']      = Get-NullableValue $r.ComponentName
    $row['variant_type']        = Get-NullableValue $r.VariantType
    $row['variant_qualifier_1'] = Get-NullableValue $r.VariantQualifier1
    $row['variant_qualifier_2'] = Get-NullableValue $r.VariantQualifier2
    $row['reference_type']      = $r.ReferenceType
    $row['scope']               = $r.Scope
    $row['source_file']         = $r.SourceFile
    $row['source_section']      = Get-NullableValue $r.SourceSection
    $row['signature']           = Get-NullableValue $r.Signature
    $row['parent_function']     = Get-NullableValue $r.ParentFunction
    $row['raw_text']            = Get-NullableValue $r.RawText
    $row['purpose_description'] = Get-NullableValue $r.PurposeDescription
    $row['drift_codes']         = Get-NullableValue $r.DriftCodes
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
  AND component_type IN ('JS_FUNCTION', 'JS_FUNCTION_VARIANT',
                         'JS_HOOK', 'JS_HOOK_VARIANT',
                         'JS_CONSTANT', 'JS_CONSTANT_VARIANT',
                         'JS_STATE',
                         'JS_CLASS',
                         'JS_METHOD', 'JS_METHOD_VARIANT',
                         'FILE_HEADER', 'COMMENT_BANNER')
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

Write-Log "Verification: variant_type distribution across variant-bearing component types"

# Confirms that variant_type is being populated for the four component types
# that carry variants (JS_FUNCTION_VARIANT, JS_HOOK_VARIANT, JS_CONSTANT_VARIANT,
# JS_METHOD_VARIANT) plus the always-variant types (JS_TIMER, JS_IMPORT). Rows
# in these types with variant_type IS NULL indicate a populator bug.
$verify5 = Get-SqlData -Query @"
SELECT
    component_type,
    variant_type,
    COUNT(*) AS row_count
FROM dbo.Asset_Registry
WHERE file_type = 'JS'
  AND component_type IN ('JS_FUNCTION_VARIANT', 'JS_HOOK_VARIANT',
                         'JS_CONSTANT_VARIANT', 'JS_METHOD_VARIANT',
                         'JS_TIMER', 'JS_IMPORT')
GROUP BY component_type, variant_type
ORDER BY component_type, variant_type;
"@
if ($verify5) { $verify5 | Format-Table -AutoSize }

Write-Log "Verification: parent_function coverage across USAGE rows"

# parent_function should be populated for the majority of USAGE rows and
# for METHOD definitions. NULL is expected for module-scope USAGE rows
# (e.g. a getElementById call at file scope). A sudden drop in coverage
# vs. the previous run signals a regression in the parent-name walker.
$verify6 = Get-SqlData -Query @"
SELECT
    component_type,
    reference_type,
    COUNT(*)                                                          AS total_rows,
    SUM(CASE WHEN parent_function IS NOT NULL THEN 1 ELSE 0 END)       AS with_parent,
    SUM(CASE WHEN parent_function IS NULL     THEN 1 ELSE 0 END)       AS without_parent
FROM dbo.Asset_Registry
WHERE file_type = 'JS'
  AND reference_type IN ('USAGE', 'DEFINITION')
  AND component_type IN ('JS_FUNCTION', 'CSS_CLASS', 'HTML_ID', 'JS_EVENT',
                         'JS_METHOD', 'JS_METHOD_VARIANT',
                         'JS_TIMER',
                         'JS_EVAL', 'JS_DOCUMENT_WRITE', 'JS_WINDOW_ASSIGNMENT',
                         'JS_INLINE_STYLE', 'JS_INLINE_SCRIPT')
GROUP BY component_type, reference_type
ORDER BY component_type, reference_type;
"@
if ($verify6) { $verify6 | Format-Table -AutoSize }

Write-Log "Verification: column fill audit (NULL counts per column)"

# Quick sanity check that nothing critical is unexpectedly all-NULL or
# mostly-NULL across the run. Useful for spotting an off-by-one in a
# new emitter (e.g. forgetting to pass parent_function through).
$verify7 = Get-SqlData -Query @"
SELECT
    'component_name'      AS column_name,
    SUM(CASE WHEN component_name      IS NULL THEN 1 ELSE 0 END) AS null_count,
    SUM(CASE WHEN component_name      IS NOT NULL THEN 1 ELSE 0 END) AS notnull_count
FROM dbo.Asset_Registry WHERE file_type = 'JS'
UNION ALL SELECT 'variant_type',        SUM(CASE WHEN variant_type        IS NULL THEN 1 ELSE 0 END), SUM(CASE WHEN variant_type        IS NOT NULL THEN 1 ELSE 0 END) FROM dbo.Asset_Registry WHERE file_type = 'JS'
UNION ALL SELECT 'variant_qualifier_1', SUM(CASE WHEN variant_qualifier_1 IS NULL THEN 1 ELSE 0 END), SUM(CASE WHEN variant_qualifier_1 IS NOT NULL THEN 1 ELSE 0 END) FROM dbo.Asset_Registry WHERE file_type = 'JS'
UNION ALL SELECT 'variant_qualifier_2', SUM(CASE WHEN variant_qualifier_2 IS NULL THEN 1 ELSE 0 END), SUM(CASE WHEN variant_qualifier_2 IS NOT NULL THEN 1 ELSE 0 END) FROM dbo.Asset_Registry WHERE file_type = 'JS'
UNION ALL SELECT 'source_section',      SUM(CASE WHEN source_section      IS NULL THEN 1 ELSE 0 END), SUM(CASE WHEN source_section      IS NOT NULL THEN 1 ELSE 0 END) FROM dbo.Asset_Registry WHERE file_type = 'JS'
UNION ALL SELECT 'signature',           SUM(CASE WHEN signature           IS NULL THEN 1 ELSE 0 END), SUM(CASE WHEN signature           IS NOT NULL THEN 1 ELSE 0 END) FROM dbo.Asset_Registry WHERE file_type = 'JS'
UNION ALL SELECT 'parent_function',     SUM(CASE WHEN parent_function     IS NULL THEN 1 ELSE 0 END), SUM(CASE WHEN parent_function     IS NOT NULL THEN 1 ELSE 0 END) FROM dbo.Asset_Registry WHERE file_type = 'JS'
UNION ALL SELECT 'raw_text',            SUM(CASE WHEN raw_text            IS NULL THEN 1 ELSE 0 END), SUM(CASE WHEN raw_text            IS NOT NULL THEN 1 ELSE 0 END) FROM dbo.Asset_Registry WHERE file_type = 'JS'
UNION ALL SELECT 'purpose_description', SUM(CASE WHEN purpose_description IS NULL THEN 1 ELSE 0 END), SUM(CASE WHEN purpose_description IS NOT NULL THEN 1 ELSE 0 END) FROM dbo.Asset_Registry WHERE file_type = 'JS'
UNION ALL SELECT 'drift_codes',         SUM(CASE WHEN drift_codes         IS NULL THEN 1 ELSE 0 END), SUM(CASE WHEN drift_codes         IS NOT NULL THEN 1 ELSE 0 END) FROM dbo.Asset_Registry WHERE file_type = 'JS'
ORDER BY column_name;
"@
if ($verify7) { $verify7 | Format-Table -AutoSize }

Write-Log "Verification: forbidden-pattern inventory (spec Q6)"

# Per CC_JS_Spec.md v1.2 Section 20.6: every forbidden pattern emits a
# row at the violation site with the corresponding FORBIDDEN_* drift on
# that row. This query inventories those rows by file and pattern type.
# The combined component_type + drift_codes view confirms the dedicated-row
# rule (one row per violation, drift on the row, no aggregation elsewhere).
$verify8 = Get-SqlData -Query @"
SELECT
    file_name,
    component_type,
    drift_codes,
    COUNT(*) AS occurrences
FROM dbo.Asset_Registry
WHERE file_type = 'JS'
  AND component_type IN ('JS_IIFE', 'JS_EVAL', 'JS_DOCUMENT_WRITE',
                         'JS_WINDOW_ASSIGNMENT',
                         'JS_INLINE_STYLE', 'JS_INLINE_SCRIPT',
                         'JS_LINE_COMMENT')
GROUP BY file_name, component_type, drift_codes
ORDER BY file_name, component_type;
"@
if ($verify8) { $verify8 | Format-Table -AutoSize }

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
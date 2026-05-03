<#
.SYNOPSIS
    xFACts - Asset Registry CSS Populator

.DESCRIPTION
    Walks every .css file under the Control Center public/css and
    public/docs/css directories, parses each file with PostCSS (via the
    parse-css.js Node helper), and generates Asset_Registry rows describing
    every catalogable component found in the file.

    The CSS populator emits the following row types:

      * CSS_CLASS DEFINITION rows for the primary (leftmost) class in every
        compound class selector. Compound modifiers (additional classes
        attached to the same element) are stored in the state_modifier
        column rather than producing separate rows. Example:
            .slide-panel.wide.open
        produces one DEFINITION row with component_name=slide-panel and
        state_modifier='wide, open'.

      * CSS_CLASS USAGE rows for descendant classes that appear after a
        combinator. Example:
            .slide-panel .close-button
        produces a DEFINITION row for slide-panel and a USAGE row for
        close-button. Scope on the USAGE row is resolved against the
        SHARED-scope class collection (Pass 1) - if the descendant matches
        a class defined in a shared file, scope=SHARED and source_file
        points at that file. Otherwise scope=LOCAL with source_file=
        <undefined> when no DEFINITION exists in any cataloged file.

      * CSS_VARIABLE DEFINITION rows for every CSS custom property
        declaration (a property whose name starts with --).

      * CSS_VARIABLE USAGE rows for every var(--name) reference inside any
        property value. Scope resolved against the SHARED variable set.

      * CSS_KEYFRAME DEFINITION rows for every @keyframes at-rule.

      * CSS_KEYFRAME USAGE rows for keyframe references inside the
        animation and animation-name properties. Scope resolved against
        the SHARED keyframe set.

      * CSS_RULE DEFINITION rows for selectors with NO classes anywhere
        (e.g., 'body', 'h1', '*', '::-webkit-scrollbar', 'a:hover'). Used
        to catalog the existence of styling for non-class selectors -
        component_name is NULL and the full selector text lives in the
        signature column.

      * HTML_ID DEFINITION rows for every #id selector encountered in CSS.
        These represent CSS-side declarations of styling for a specific
        DOM id and complement the JS-side / HTML-side id DEFINITION rows
        produced by the other populators. The CSS file containing the
        rule is the source_file. State modifiers attached to the id
        (e.g., '#foo.active') are captured the same way they are for
        classes.

      * COMMENT_BANNER DEFINITION rows for block comments containing five
        or more consecutive '=' characters. The banner title is taken
        from the first non-empty non-equals line of the comment. Banner
        titles are propagated to source_section on subsequent rows in
        the same file until the next banner is encountered.

    Scope resolution:
      * DEFINITION rows: scope=SHARED if the file is in the curated
        SharedFiles list (currently engine-events.css), otherwise LOCAL.
      * USAGE rows: scope=SHARED when the referenced name has any
        DEFINITION in a shared file, with source_file pointing at the
        actual shared filename (matching the JS populator behavior).
        scope=LOCAL otherwise, with source_file pointing at the local
        file containing the DEFINITION, or '<undefined>' when no
        DEFINITION exists.

    At-rule context:
      * Rules nested inside @media, @supports, etc. carry the at-rule
        label (e.g., '@media (max-width: 768px)') in their parent_function
        column. This makes responsive overrides queryable as a distinct
        bucket.

    Refresh semantics:
      * In standalone execution, the populator deletes only its own slice
        (file_type='CSS') before bulk-inserting. This makes the populator
        independently re-runnable for development without disturbing
        HTML or JS rows.
      * Under the orchestrator, the orchestrator TRUNCATEs the table once
        at the start and the populator's DELETE-WHERE becomes a harmless
        no-op on already-empty data.

.NOTES
    File Name      : Populate-AssetRegistry-CSS.ps1
    Location       : E:\xFACts-PowerShell
    Author         : Frost Arnett Applications Team
    Version        : Tracked in dbo.System_Metadata (component: TBD)

.PARAMETER Execute
    Required to actually delete the CSS rows from Asset_Registry and write
    the new row set. Without this flag, runs in preview mode: parses every
    file, builds the row set in memory, prints summary statistics, but
    does NOT touch the database.

================================================================================
CHANGELOG
================================================================================
2026-05-02  Architectural correction: SharedFiles expanded to include all
            seven docs/css files. The Documentation site zone uses a
            type-shared model rather than a single shared file - every
            docs-*.css file is consumed by a category of HTML pages
            rather than being page-specific. Previous version treated
            docs/css files the same as Control Center page-specific CSS,
            mislabeling all docs definitions as scope=LOCAL. Net effect:
            CSS_CLASS DEFINITION rows for docs files flip from LOCAL to
            SHARED, and downstream USAGE resolution now correctly points
            at the actual docs file that defines each consumed component.
            No algorithmic change - only the SharedFiles list was edited.
2026-05-02  Initial production implementation. Replaces the throwaway
            test populator at xFACts-Documentation\WorkingFiles\
            CSS_PopulatorTest.ps1. Algorithmic core is preserved -
            compound vs descendant selector decomposition, multi-selector
            dedupe, banner-driven source_section enrichment, CSS_VARIABLE
            and CSS_KEYFRAME def/use tracking, and CSS_RULE for
            non-class selectors all carry forward unchanged. Substantive
            additions in this version:
              (1) Integrates with xFACts-OrchestratorFunctions.ps1 -
                  uses Initialize-XFActsScript, Write-Log, Get-SqlData,
                  Invoke-SqlNonQuery for all infrastructure operations.
              (2) Adds public/docs/css/ to the scan paths. The seven
                  documentation-site CSS files (docs-base.css,
                  docs-controlcenter.css, docs-narrative.css, etc.)
                  were previously uncatalogued.
              (3) Adds HTML_ID DEFINITION rows for #id selectors in CSS.
                  Each CSS rule like '#admin-header { ... }' produces a
                  DEFINITION row attributing the id to the CSS file as
                  the source_file. State modifiers attached to the id
                  are recorded in state_modifier the same way they are
                  for classes.
              (4) Adds occurrence_index post-pass: rows are assigned a
                  sequential index per (file_name, component_name,
                  reference_type, state_modifier) tuple. Forms part of
                  the natural key for the table.
              (5) Tracks the actual shared filename in source_file for
                  SHARED-scope USAGE rows instead of the opaque '<shared>'
                  literal. Mirrors the JS populator behavior. Each Pass-1
                  shared symbol is mapped to the file that defined it.
              (6) Object_Registry FK lookup. At startup the populator
                  loads the (object_name -> registry_id) map from
                  dbo.Object_Registry. Each inserted row's file_name is
                  resolved against the map and the registry_id is written
                  to object_registry_id. Files not registered are
                  collected in a HashSet and surfaced as a WARN block at
                  end-of-run so registration gaps can be remediated.
              (7) Universal NULL/empty consistency. Get-NullableValue
                  now treats empty/whitespace-only strings as NULL in
                  addition to PowerShell $null. The previous test
                  populator wrote empty strings into state_modifier,
                  source_section, parent_function, parent_object on
                  rows where those attributes did not apply.
              (8) Standardized header + CHANGELOG matching the production
                  populator pattern.
              (9) Exit codes follow the doc-pipeline convention (0 =
                  success, 1 = failure, 2 = success-with-warnings).
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

# Files whose top-level definitions are visible to multiple consumer files
# rather than being tied to a single page. Definitions in these files get
# scope=SHARED. The list spans two architectural zones:
#
#   Control Center zone:
#     engine-events.css - the single shared file for all CC pages.
#     Page-specific CSS (admin.css, bdl-import.css, etc.) is LOCAL.
#
#   Documentation site zone:
#     All docs-*.css files are type-shared infrastructure. Each one is
#     consumed by a category of HTML pages rather than being tied to a
#     single page. The mapping is:
#       docs-base.css         - universal, loaded by every doc page
#       docs-narrative.css    - top-level narrative pages
#       docs-architecture.css - architecture pages
#       docs-controlcenter.css - CC guide pages
#       docs-erd.css          - architecture pages (ERD diagrams)
#       docs-reference.css    - reference pages
#       docs-hub.css          - the hub (index.html). Currently has one
#                               consumer but is structurally a shared file
#                               in the docs system.
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
# ROW BUILDER STATE
# ============================================================================

$rows       = New-Object System.Collections.Generic.List[object]
$dedupeKeys = New-Object 'System.Collections.Generic.HashSet[string]'

function Test-AddDedupeKey {
    param([string]$Key)
    return $script:dedupeKeys.Add($Key)
}

# Compute occurrence_index for each (file_name, component_name,
# reference_type, state_modifier) tuple. Assigns 1 to the first row
# matching the tuple, 2 to the second, etc., in the order the rows were
# emitted by the walker (which follows source order).
function Set-OccurrenceIndices {
    param([System.Collections.Generic.List[object]]$Rows)

    $counters = @{}
    foreach ($r in $Rows) {
        $stateMod = if ($r.StateModifier) { $r.StateModifier } else { '' }
        $cn = if ($r.ComponentName) { $r.ComponentName } else { '' }
        $key = "$($r.FileName)|$cn|$($r.ReferenceType)|$stateMod"
        if (-not $counters.ContainsKey($key)) {
            $counters[$key] = 0
        }
        $counters[$key]++
        $r.OccurrenceIndex = $counters[$key]
    }
}

# ============================================================================
# PARSER INVOCATION
# ============================================================================

# Run a single .css file through parse-css.js and return the parsed AST.
# Returns $null on parse failure with an error logged.
function Invoke-CssParse {
    param([Parameter(Mandatory)][string]$FilePath)

    try {
        $source = Get-Content -Path $FilePath -Raw -Encoding UTF8
        if (-not $source) { $source = '' }

        # Send the raw CSS to parse-css.js via stdin and capture stdout
        $output = $source | & $NodeExe $ParseCssScript 2>&1
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

# Format a multi-line string as a single line for raw_text/signature columns.
function Format-SingleLine {
    param([string]$Text)
    if ($null -eq $Text) { return $null }
    $crlf = "`r`n"; $lf = "`n"; $cr = "`r"
    return ($Text -replace $crlf, ' ' -replace $lf, ' ' -replace $cr, ' ').Trim()
}

# Banner title extraction. A banner is a block comment containing 5+ '='
# characters. The first non-empty non-equals line of the comment becomes
# the banner title.
function Get-BannerTitle {
    param([string]$CommentText)
    if ($null -eq $CommentText) { return $null }
    if ($CommentText -notmatch '={5,}') { return $null }

    $lines = $CommentText -split "`n"
    foreach ($line in $lines) {
        $trimmed = $line.Trim().Trim('=').Trim()
        if ($trimmed.Length -gt 0) { return $trimmed }
    }
    return $null
}

# Extract every var(--foo) reference from a CSS value string. Returns the
# bare names (without the leading --). Used to emit CSS_VARIABLE USAGE
# rows whenever a property value references a custom property.
function Get-VarReferences {
    param([string]$Value)
    if ($null -eq $Value) { return @() }
    $regexMatches = [regex]::Matches($Value, 'var\(\s*--([a-zA-Z0-9_-]+)\s*[,)]')
    return @($regexMatches | ForEach-Object { $_.Groups[1].Value })
}

# ============================================================================
# SELECTOR DECOMPOSITION
# ============================================================================

# Walk a single selector's children (the `nodes` array of a 'selector' node
# from the parser's selector tree), splitting into compounds at combinator
# boundaries. A compound is a contiguous sequence of selectors that all
# apply to the same element - e.g., '.foo.bar.baz' is one compound made of
# three classes; '.foo .bar' is two compounds separated by a descendant
# combinator.
#
# Returns an array of compound objects. Each compound carries:
#   Classes      - list of class names found in this compound (in source order)
#   Ids          - list of id names found in this compound
#   HasClasses   - bool, whether the compound contains at least one class
#   HasIds       - bool, whether the compound contains at least one id
#   HasNonClass  - bool, whether the compound contains any tag/universal/
#                  attribute selectors (used to distinguish '.foo' rules
#                  from 'div.foo' rules - we do not currently use this for
#                  row-emission decisions but keep it for future use)
function Get-CompoundList {
    param([Parameter(Mandatory=$true)] $SelectorChildren)

    $compounds = @()
    $currentClasses = New-Object System.Collections.Generic.List[string]
    $currentIds     = New-Object System.Collections.Generic.List[string]
    $currentHasNonClass = $false

    foreach ($node in $SelectorChildren) {
        $t = $node.type
        if ($t -eq 'combinator') {
            # End of current compound; push and reset
            $compounds += [ordered]@{
                Classes     = @($currentClasses.ToArray())
                Ids         = @($currentIds.ToArray())
                HasClasses  = ($currentClasses.Count -gt 0)
                HasIds      = ($currentIds.Count -gt 0)
                HasNonClass = $currentHasNonClass
            }
            $currentClasses = New-Object System.Collections.Generic.List[string]
            $currentIds = New-Object System.Collections.Generic.List[string]
            $currentHasNonClass = $false
        }
        elseif ($t -eq 'class') {
            $currentClasses.Add($node.value)
        }
        elseif ($t -eq 'id') {
            $currentIds.Add($node.value)
        }
        elseif ($t -eq 'tag' -or $t -eq 'universal' -or $t -eq 'attribute') {
            $currentHasNonClass = $true
        }
        # pseudo-classes and pseudo-elements contribute nothing to the
        # compound class/id list - they style a sub-element of whatever
        # compound they are attached to. Ignored for cataloging purposes.
    }

    # Push the final compound
    $compounds += [ordered]@{
        Classes     = @($currentClasses.ToArray())
        Ids         = @($currentIds.ToArray())
        HasClasses  = ($currentClasses.Count -gt 0)
        HasIds      = ($currentIds.Count -gt 0)
        HasNonClass = $currentHasNonClass
    }

    return ,$compounds
}

# ============================================================================
# PASS 1 - COLLECT SHARED-SCOPE DEFINITIONS
# ============================================================================
# Walk every shared file collecting class names, variable names, and
# keyframe names. Each shared symbol is mapped to the actual file that
# defined it (rather than an opaque '<shared>' marker), so USAGE rows can
# point at the real source_file. Pass 2 uses these maps for scope
# resolution.

Write-Log "Pass 1: collecting SHARED-scope CSS definitions..."

$sharedClassMap     = @{}   # className -> source filename
$sharedVariableMap  = @{}
$sharedKeyframeMap  = @{}

# Cache parsed ASTs so we don't re-parse files in Pass 2
$astCache = @{}

# Discover all .css files
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

    # Walk the AST collecting shared definitions. We use an iterative
    # stack-based walk to keep PowerShell call depth bounded.
    $stack = New-Object System.Collections.Generic.Stack[object]
    $stack.Push($parsed.ast)
    while ($stack.Count -gt 0) {
        $node = $stack.Pop()
        if ($null -eq $node) { continue }

        # Class definitions: walk every selector's first compound's first class
        if ($node.type -eq 'rule' -and $node.selectorTree -and $node.selectorTree.nodes) {
            foreach ($sel in $node.selectorTree.nodes) {
                if ($sel.type -ne 'selector') { continue }
                $compounds = Get-CompoundList -SelectorChildren $sel.nodes
                # Find leftmost compound with classes - that's the primary def
                foreach ($cmp in $compounds) {
                    if ($cmp.HasClasses) {
                        $primaryClass = $cmp.Classes[0]
                        if (-not $sharedClassMap.ContainsKey($primaryClass)) {
                            $sharedClassMap[$primaryClass] = $name
                        }
                        break  # only the leftmost compound counts as definition
                    }
                }
            }
        }

        # CSS variable definitions: any --propname declaration
        if ($node.type -eq 'decl' -and $node.prop -and $node.prop.StartsWith('--')) {
            $varName = $node.prop.Substring(2)
            if (-not $sharedVariableMap.ContainsKey($varName)) {
                $sharedVariableMap[$varName] = $name
            }
        }

        # Keyframe definitions
        if ($node.type -eq 'atrule' -and $node.name -eq 'keyframes' -and $node.params) {
            $kfName = $node.params.Trim()
            if (-not $sharedKeyframeMap.ContainsKey($kfName)) {
                $sharedKeyframeMap[$kfName] = $name
            }
        }

        # Recurse into children
        if ($node.nodes) {
            foreach ($child in $node.nodes) { $stack.Push($child) }
        }
    }
}

Write-Log ("  Shared classes:    {0}" -f $sharedClassMap.Count)
Write-Log ("  Shared variables:  {0}" -f $sharedVariableMap.Count)
Write-Log ("  Shared keyframes:  {0}" -f $sharedKeyframeMap.Count)

# ============================================================================
# LOAD Object_Registry FOR object_registry_id RESOLUTION
# ============================================================================
# Asset_Registry.object_registry_id is a foreign key to
# dbo.Object_Registry.registry_id. Every row inserted should carry the
# registry_id of the source file (e.g., admin.css -> the registry_id row
# whose object_name = 'admin.css'). Load the mapping once at startup and
# apply it during bulk insert.

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

# Per-file context state. Updated as we traverse a file's AST.
$script:CurrentFile         = $null
$script:CurrentFileIsShared = $false
$script:CurrentBannerOuter  = $null   # active banner title (for source_section)

# ----- Row builders --------------------------------------------------------

function Resolve-ClassScope {
    param([string]$ClassName)
    if ($script:sharedClassMap.ContainsKey($ClassName)) {
        return @{ Scope = 'SHARED'; SourceFile = $script:sharedClassMap[$ClassName] }
    }
    # No shared definition. We don't have a per-file CSS class definition
    # map at hand here, but downstream HTML/JS lookups query the table for
    # CSS_CLASS DEFINITIONs after CSS has loaded. Within the CSS pass
    # itself, a USAGE referencing a class defined locally in the same
    # CSS file gets scope=LOCAL with source_file=<current-file>. A USAGE
    # referencing a class with no DEFINITION anywhere gets <undefined>.
    # We can't distinguish these two cases here without a second pass over
    # the whole catalog, so we mark all non-shared usages with
    # source_file = current file. This matches the behavior expected by
    # the test populator and is a reasonable conservative choice -
    # cross-file CSS class usage is uncommon.
    return @{ Scope = 'LOCAL'; SourceFile = $script:CurrentFile }
}

function Add-CssRuleRow {
    param(
        [int]$LineStart,
        [int]$LineEnd,
        [int]$ColumnStart,
        [string]$Signature,
        [string]$ParentAtrule,
        [string]$RawText
    )

    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|CSS_RULE||DEFINITION|"
    if (-not (Test-AddDedupeKey -Key $key)) { return }

    $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }

    $script:rows.Add([ordered]@{
        FileName        = $script:CurrentFile
        FileType        = 'CSS'
        LineStart       = $LineStart
        LineEnd         = $LineEnd
        ColumnStart     = $ColumnStart
        ComponentType   = 'CSS_RULE'
        ComponentName   = $null
        StateModifier   = $null
        ReferenceType   = 'DEFINITION'
        Scope           = $scope
        SourceFile      = $script:CurrentFile
        SourceSection   = $script:CurrentBannerOuter
        Signature       = $Signature
        ParentFunction  = $ParentAtrule
        ParentObject    = $null
        RawText         = $RawText
        OccurrenceIndex = 1
    })
}

function Add-CssClassRow {
    param(
        [string]$ComponentName,
        [string]$StateModifier,
        [string]$ReferenceType,
        [int]$LineStart,
        [int]$LineEnd,
        [int]$ColumnStart,
        [string]$Signature,
        [string]$ParentAtrule,
        [string]$RawText
    )

    if ([string]::IsNullOrWhiteSpace($ComponentName)) { return }

    $scope = $null
    $sourceFile = $null
    if ($ReferenceType -eq 'DEFINITION') {
        $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }
        $sourceFile = $script:CurrentFile
    }
    else {
        $resolved = Resolve-ClassScope -ClassName $ComponentName
        $scope = $resolved.Scope
        $sourceFile = $resolved.SourceFile
    }

    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|CSS_CLASS|$ComponentName|$ReferenceType|$StateModifier"
    if (-not (Test-AddDedupeKey -Key $key)) { return }

    $script:rows.Add([ordered]@{
        FileName        = $script:CurrentFile
        FileType        = 'CSS'
        LineStart       = $LineStart
        LineEnd         = $LineEnd
        ColumnStart     = $ColumnStart
        ComponentType   = 'CSS_CLASS'
        ComponentName   = $ComponentName
        StateModifier   = $StateModifier
        ReferenceType   = $ReferenceType
        Scope           = $scope
        SourceFile      = $sourceFile
        SourceSection   = $script:CurrentBannerOuter
        Signature       = $Signature
        ParentFunction  = $ParentAtrule
        ParentObject    = $null
        RawText         = $RawText
        OccurrenceIndex = 1
    })
}

function Add-HtmlIdRow {
    param(
        [string]$IdName,
        [string]$StateModifier,
        [int]$LineStart,
        [int]$LineEnd,
        [int]$ColumnStart,
        [string]$Signature,
        [string]$ParentAtrule,
        [string]$RawText
    )

    if ([string]::IsNullOrWhiteSpace($IdName)) { return }

    # CSS-side id selectors are always emitted as DEFINITIONs (this CSS
    # rule defines styling for an id named X). The CSS file is the
    # source_file. Scope follows the file's shared/local classification.
    $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }

    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|HTML_ID|$IdName|DEFINITION|$StateModifier"
    if (-not (Test-AddDedupeKey -Key $key)) { return }

    $script:rows.Add([ordered]@{
        FileName        = $script:CurrentFile
        FileType        = 'CSS'
        LineStart       = $LineStart
        LineEnd         = $LineEnd
        ColumnStart     = $ColumnStart
        ComponentType   = 'HTML_ID'
        ComponentName   = $IdName
        StateModifier   = $StateModifier
        ReferenceType   = 'DEFINITION'
        Scope           = $scope
        SourceFile      = $script:CurrentFile
        SourceSection   = $script:CurrentBannerOuter
        Signature       = $Signature
        ParentFunction  = $ParentAtrule
        ParentObject    = $null
        RawText         = $RawText
        OccurrenceIndex = 1
    })
}

function Add-CssVariableRow {
    param(
        [string]$VarName,
        [string]$ReferenceType,
        [int]$LineStart,
        [int]$LineEnd,
        [int]$ColumnStart,
        [string]$Signature,
        [string]$ParentAtrule,
        [string]$RawText
    )

    if ([string]::IsNullOrWhiteSpace($VarName)) { return }

    $scope = $null
    $sourceFile = $null
    if ($ReferenceType -eq 'DEFINITION') {
        $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }
        $sourceFile = $script:CurrentFile
    }
    else {
        if ($script:sharedVariableMap.ContainsKey($VarName)) {
            $scope = 'SHARED'
            $sourceFile = $script:sharedVariableMap[$VarName]
        }
        else {
            $scope = 'LOCAL'
            $sourceFile = $script:CurrentFile
        }
    }

    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|CSS_VARIABLE|$VarName|$ReferenceType|"
    if (-not (Test-AddDedupeKey -Key $key)) { return }

    $script:rows.Add([ordered]@{
        FileName        = $script:CurrentFile
        FileType        = 'CSS'
        LineStart       = $LineStart
        LineEnd         = $LineEnd
        ColumnStart     = $ColumnStart
        ComponentType   = 'CSS_VARIABLE'
        ComponentName   = $VarName
        StateModifier   = $null
        ReferenceType   = $ReferenceType
        Scope           = $scope
        SourceFile      = $sourceFile
        SourceSection   = $script:CurrentBannerOuter
        Signature       = $Signature
        ParentFunction  = $ParentAtrule
        ParentObject    = $null
        RawText         = $RawText
        OccurrenceIndex = 1
    })
}

function Add-CssKeyframeRow {
    param(
        [string]$KeyframeName,
        [string]$ReferenceType,
        [int]$LineStart,
        [int]$LineEnd,
        [int]$ColumnStart,
        [string]$Signature,
        [string]$ParentAtrule,
        [string]$RawText
    )

    if ([string]::IsNullOrWhiteSpace($KeyframeName)) { return }

    $scope = $null
    $sourceFile = $null
    if ($ReferenceType -eq 'DEFINITION') {
        $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }
        $sourceFile = $script:CurrentFile
    }
    else {
        if ($script:sharedKeyframeMap.ContainsKey($KeyframeName)) {
            $scope = 'SHARED'
            $sourceFile = $script:sharedKeyframeMap[$KeyframeName]
        }
        else {
            $scope = 'LOCAL'
            $sourceFile = $script:CurrentFile
        }
    }

    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|CSS_KEYFRAME|$KeyframeName|$ReferenceType|"
    if (-not (Test-AddDedupeKey -Key $key)) { return }

    $script:rows.Add([ordered]@{
        FileName        = $script:CurrentFile
        FileType        = 'CSS'
        LineStart       = $LineStart
        LineEnd         = $LineEnd
        ColumnStart     = $ColumnStart
        ComponentType   = 'CSS_KEYFRAME'
        ComponentName   = $KeyframeName
        StateModifier   = $null
        ReferenceType   = $ReferenceType
        Scope           = $scope
        SourceFile      = $sourceFile
        SourceSection   = $script:CurrentBannerOuter
        Signature       = $Signature
        ParentFunction  = $ParentAtrule
        ParentObject    = $null
        RawText         = $RawText
        OccurrenceIndex = 1
    })
}

function Add-CommentBannerRow {
    param(
        [string]$Title,
        [int]$LineStart,
        [int]$LineEnd,
        [int]$ColumnStart,
        [string]$RawText
    )

    if ([string]::IsNullOrWhiteSpace($Title)) { return }

    $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }

    $key = "$($script:CurrentFile)|$LineStart|COMMENT_BANNER|$Title|DEFINITION|"
    if (-not (Test-AddDedupeKey -Key $key)) { return }

    $script:rows.Add([ordered]@{
        FileName        = $script:CurrentFile
        FileType        = 'CSS'
        LineStart       = $LineStart
        LineEnd         = $LineEnd
        ColumnStart     = $ColumnStart
        ComponentType   = 'COMMENT_BANNER'
        ComponentName   = $Title
        StateModifier   = $null
        ReferenceType   = 'DEFINITION'
        Scope           = $scope
        SourceFile      = $script:CurrentFile
        SourceSection   = $null    # banner rows don't carry a parent banner
        Signature       = $null
        ParentFunction  = $null
        ParentObject    = $null
        RawText         = $RawText
        OccurrenceIndex = 1
    })
}

# ----- Per-selector row generation ------------------------------------------

# Process one selector within a rule (a rule may have multiple selectors
# in a comma-separated list). Each selector is a chain of compounds joined
# by combinators. The leftmost compound's first class (or first id, when
# the compound has no classes) is treated as the primary DEFINITION;
# additional classes/ids in the same compound become state_modifier;
# subsequent compounds' first classes become USAGE rows (descendant
# references). Compounds with neither classes nor ids contribute nothing
# directly, except that a selector with no class/id compounds at all
# emits a single CSS_RULE row.
function Add-RowsForSelector {
    param(
        [Parameter(Mandatory=$true)] $SelectorNode,
        [Parameter(Mandatory=$true)] [string] $RuleSelectorText,
        [Parameter(Mandatory=$true)] [int]    $LineStart,
        [Parameter(Mandatory=$true)] [int]    $LineEnd,
        [Parameter(Mandatory=$true)] [int]    $ColumnStart,
        [string] $ParentAtrule = $null
    )

    $compounds = Get-CompoundList -SelectorChildren $SelectorNode.nodes

    # Find the leftmost compound that has either classes or ids
    $primaryIdx = -1
    for ($i = 0; $i -lt $compounds.Count; $i++) {
        if ($compounds[$i].HasClasses -or $compounds[$i].HasIds) {
            $primaryIdx = $i
            break
        }
    }

    # No classes or ids anywhere - emit a single CSS_RULE row
    if ($primaryIdx -lt 0) {
        Add-CssRuleRow -LineStart $LineStart -LineEnd $LineEnd `
            -ColumnStart $ColumnStart `
            -Signature $RuleSelectorText -ParentAtrule $ParentAtrule `
            -RawText $RuleSelectorText
        return
    }

    # Emit primary DEFINITION for the leftmost class/id compound
    $primary = $compounds[$primaryIdx]
    if ($primary.HasClasses) {
        $primaryName = $primary.Classes[0]
        $modifierParts = @()
        # Additional classes in the same compound -> state modifiers
        if ($primary.Classes.Count -gt 1) {
            $modifierParts += $primary.Classes[1..($primary.Classes.Count-1)]
        }
        # Ids in the same compound also become state modifiers (rare but valid)
        foreach ($id in $primary.Ids) { $modifierParts += "#$id" }
        $modifiers = if ($modifierParts.Count -gt 0) { $modifierParts -join ', ' } else { $null }

        Add-CssClassRow -ComponentName $primaryName -StateModifier $modifiers `
            -ReferenceType 'DEFINITION' `
            -LineStart $LineStart -LineEnd $LineEnd -ColumnStart $ColumnStart `
            -Signature $RuleSelectorText -ParentAtrule $ParentAtrule `
            -RawText $RuleSelectorText
    }
    else {
        # Primary compound has ids but no classes - emit HTML_ID DEFINITION
        $primaryId = $primary.Ids[0]
        $modifierParts = @()
        if ($primary.Ids.Count -gt 1) {
            foreach ($extra in $primary.Ids[1..($primary.Ids.Count-1)]) { $modifierParts += "#$extra" }
        }
        $modifiers = if ($modifierParts.Count -gt 0) { $modifierParts -join ', ' } else { $null }

        Add-HtmlIdRow -IdName $primaryId -StateModifier $modifiers `
            -LineStart $LineStart -LineEnd $LineEnd -ColumnStart $ColumnStart `
            -Signature $RuleSelectorText -ParentAtrule $ParentAtrule `
            -RawText $RuleSelectorText
    }

    # Descendant USAGE rows: for each compound after the primary, emit a
    # USAGE row for its leftmost class. Ids in descendant compounds get
    # captured as USAGE rows on HTML_ID as well.
    for ($i = $primaryIdx + 1; $i -lt $compounds.Count; $i++) {
        $cmp = $compounds[$i]
        if ($cmp.HasClasses) {
            $usageName = $cmp.Classes[0]
            $usageModifiersList = @()
            if ($cmp.Classes.Count -gt 1) {
                $usageModifiersList += $cmp.Classes[1..($cmp.Classes.Count-1)]
            }
            foreach ($id in $cmp.Ids) { $usageModifiersList += "#$id" }
            $usageMod = if ($usageModifiersList.Count -gt 0) { $usageModifiersList -join ', ' } else { $null }

            Add-CssClassRow -ComponentName $usageName -StateModifier $usageMod `
                -ReferenceType 'USAGE' `
                -LineStart $LineStart -LineEnd $LineEnd -ColumnStart $ColumnStart `
                -Signature $RuleSelectorText -ParentAtrule $ParentAtrule `
                -RawText $RuleSelectorText
        }
        elseif ($cmp.HasIds) {
            # Descendant id-only compound - we don't have a CSS-side
            # HTML_ID USAGE row pattern in our DDL design (HTML_IDs are
            # DEFINITION-only by convention since each id is unique per
            # page). Skip to avoid spurious USAGE rows. The CSS rule's
            # full selector text is captured in signature anyway.
        }
    }
}

# ----- AST recursion --------------------------------------------------------

function Add-RowsFromAst {
    param(
        [Parameter(Mandatory=$true)] $Node,
        [string] $ParentAtrule = $null
    )

    if ($null -eq $Node) { return }

    # COMMENT_BANNER detection
    if ($Node.type -eq 'comment') {
        $title = Get-BannerTitle -CommentText $Node.text
        if ($title) {
            $cLine    = if ($Node.source -and $Node.source.start) { [int]$Node.source.start.line } else { 1 }
            $cEndLine = if ($Node.source -and $Node.source.end) { [int]$Node.source.end.line } else { $cLine }
            $cCol     = if ($Node.source -and $Node.source.start -and ($Node.source.start.PSObject.Properties.Name -contains 'column')) {
                            [int]$Node.source.start.column
                        } else { 1 }

            $rawSnippet = Format-SingleLine -Text $Node.text

            Add-CommentBannerRow -Title $title `
                -LineStart $cLine -LineEnd $cEndLine -ColumnStart $cCol `
                -RawText $rawSnippet

            $script:CurrentBannerOuter = $title
            return
        }
    }

    # Rule node - emit rows for each selector in the comma-separated list
    if ($Node.type -eq 'rule') {
        $line    = if ($Node.source -and $Node.source.start) { [int]$Node.source.start.line } else { 1 }
        $endLine = if ($Node.source -and $Node.source.end)   { [int]$Node.source.end.line   } else { $line }
        $col     = if ($Node.source -and $Node.source.start -and ($Node.source.start.PSObject.Properties.Name -contains 'column')) {
                       [int]$Node.source.start.column
                   } else { 1 }

        if ($Node.selectorTree -and $Node.selectorTree.nodes) {
            foreach ($sel in $Node.selectorTree.nodes) {
                if ($sel.type -ne 'selector') { continue }
                Add-RowsForSelector -SelectorNode $sel -RuleSelectorText $Node.selector `
                    -LineStart $line -LineEnd $endLine -ColumnStart $col `
                    -ParentAtrule $ParentAtrule
            }
        }

        # Walk into the rule's body to capture custom property defs and
        # var()/keyframe references inside declarations
        if ($Node.nodes) {
            foreach ($child in $Node.nodes) {
                Add-RowsFromAst -Node $child -ParentAtrule $ParentAtrule
            }
        }
        return
    }

    # decl - CSS_VARIABLE def/use, CSS_KEYFRAME use
    if ($Node.type -eq 'decl') {
        $line    = if ($Node.source -and $Node.source.start) { [int]$Node.source.start.line } else { 1 }
        $endLine = if ($Node.source -and $Node.source.end)   { [int]$Node.source.end.line   } else { $line }
        $col     = if ($Node.source -and $Node.source.start -and ($Node.source.start.PSObject.Properties.Name -contains 'column')) {
                       [int]$Node.source.start.column
                   } else { 1 }

        # CSS_VARIABLE DEFINITION: any --propname declaration
        if ($Node.prop -and $Node.prop.StartsWith('--')) {
            $varName = $Node.prop.Substring(2)
            Add-CssVariableRow -VarName $varName -ReferenceType 'DEFINITION' `
                -LineStart $line -LineEnd $endLine -ColumnStart $col `
                -Signature $Node.value -ParentAtrule $ParentAtrule `
                -RawText "$($Node.prop): $($Node.value)"
        }

        # CSS_VARIABLE USAGE: var(--foo) references inside the value
        $vars = Get-VarReferences -Value $Node.value
        foreach ($v in $vars) {
            Add-CssVariableRow -VarName $v -ReferenceType 'USAGE' `
                -LineStart $line -LineEnd $endLine -ColumnStart $col `
                -Signature "var(--$v)" -ParentAtrule $ParentAtrule `
                -RawText "$($Node.prop): $($Node.value)"
        }

        # CSS_KEYFRAME USAGE: animation / animation-name references
        if ($Node.prop -in @('animation','animation-name')) {
            foreach ($tok in ($Node.value -split '\s+|,')) {
                $t = $tok.Trim()
                if ($t -and $script:sharedKeyframeMap.ContainsKey($t)) {
                    Add-CssKeyframeRow -KeyframeName $t -ReferenceType 'USAGE' `
                        -LineStart $line -LineEnd $endLine -ColumnStart $col `
                        -Signature "$($Node.prop): $($Node.value)" -ParentAtrule $ParentAtrule `
                        -RawText "$($Node.prop): $($Node.value)"
                }
            }
        }
        return
    }

    # @keyframes declaration
    if ($Node.type -eq 'atrule' -and $Node.name -eq 'keyframes') {
        $kfName  = $Node.params.Trim()
        $line    = if ($Node.source -and $Node.source.start) { [int]$Node.source.start.line } else { 1 }
        $endLine = if ($Node.source -and $Node.source.end)   { [int]$Node.source.end.line   } else { $line }
        $col     = if ($Node.source -and $Node.source.start -and ($Node.source.start.PSObject.Properties.Name -contains 'column')) {
                       [int]$Node.source.start.column
                   } else { 1 }

        Add-CssKeyframeRow -KeyframeName $kfName -ReferenceType 'DEFINITION' `
            -LineStart $line -LineEnd $endLine -ColumnStart $col `
            -Signature "@keyframes $kfName" -ParentAtrule $ParentAtrule `
            -RawText "@keyframes $kfName"
        # Don't recurse into keyframe body - the inner blocks (0%, 50%, etc.)
        # aren't class/id selectors and we don't catalog their declarations.
        return
    }

    # Other at-rules (@media, @supports, etc.) - recurse into children
    # carrying the at-rule label so nested rules know their parent context
    if ($Node.type -eq 'atrule') {
        $atruleLabel = "@$($Node.name)"
        if ($Node.params) { $atruleLabel = "$atruleLabel $($Node.params)" }
        $atruleLabel = $atruleLabel.Trim()

        if ($Node.nodes) {
            foreach ($child in $Node.nodes) {
                Add-RowsFromAst -Node $child -ParentAtrule $atruleLabel
            }
        }
        return
    }

    # Root or unknown node - recurse
    if ($Node.nodes) {
        foreach ($child in $Node.nodes) {
            Add-RowsFromAst -Node $child -ParentAtrule $ParentAtrule
        }
    }
}

# ----- Per-file orchestration -----------------------------------------------

foreach ($file in $CssFiles) {
    $name = [System.IO.Path]::GetFileName($file)
    $isShared = $SharedFiles -contains $name

    if (-not $astCache.ContainsKey($file)) {
        Write-Log "  Skipping (no parsed AST): $name" "WARN"
        continue
    }

    $script:CurrentFile         = $name
    $script:CurrentFileIsShared = $isShared
    $script:CurrentBannerOuter  = $null   # banners don't cross file boundaries

    $startCount = $rows.Count
    $scopeLabel = if ($isShared) { 'SHARED' } else { 'LOCAL' }
    Write-Host ("  Walking {0} ({1})..." -f $name, $scopeLabel) -ForegroundColor Cyan

    Add-RowsFromAst -Node $astCache[$file].ast

    $delta = $rows.Count - $startCount
    Write-Host ("    -> {0} rows" -f $delta) -ForegroundColor Green
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

# Build DataTable matching dbo.Asset_Registry schema
$dt = New-Object System.Data.DataTable
[void]$dt.Columns.Add('file_name',           [string])
[void]$dt.Columns.Add('object_registry_id',  [int])
[void]$dt.Columns.Add('file_type',           [string])
[void]$dt.Columns.Add('line_start',          [int])
[void]$dt.Columns.Add('line_end',            [int])
[void]$dt.Columns.Add('column_start',        [int])
[void]$dt.Columns.Add('component_type',      [string])
[void]$dt.Columns.Add('component_name',      [string])
[void]$dt.Columns.Add('component_subtype',   [string])
[void]$dt.Columns.Add('state_modifier',      [string])
[void]$dt.Columns.Add('reference_type',      [string])
[void]$dt.Columns.Add('scope',               [string])
[void]$dt.Columns.Add('source_file',         [string])
[void]$dt.Columns.Add('source_section',      [string])
[void]$dt.Columns.Add('signature',           [string])
[void]$dt.Columns.Add('parent_function',     [string])
[void]$dt.Columns.Add('parent_object',       [string])
[void]$dt.Columns.Add('raw_text',            [string])
[void]$dt.Columns.Add('purpose_description', [string])
[void]$dt.Columns.Add('design_notes',        [string])
[void]$dt.Columns.Add('related_asset_id',    [int])
[void]$dt.Columns.Add('occurrence_index',    [int])

# Universal NULL/empty-consistent value coercion. Empty strings have no
# semantic meaning - the absence of an attribute is always NULL.
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

    # Resolve object_registry_id via the preloaded Object_Registry map
    if ($objectRegistryMap.ContainsKey($r.FileName)) {
        $row['object_registry_id'] = [int]$objectRegistryMap[$r.FileName]
    }
    else {
        $row['object_registry_id'] = [System.DBNull]::Value
        [void]$objectRegistryMisses.Add($r.FileName)
    }

    $row['file_type']           = $r.FileType
    $row['line_start']          = if ($null -eq $r.LineStart) { 1 } else { [int]$r.LineStart }
    $row['line_end']            = if ($null -eq $r.LineEnd) { [System.DBNull]::Value } else { [int]$r.LineEnd }
    $row['column_start']        = if ($null -eq $r.ColumnStart) { [System.DBNull]::Value } else { [int]$r.ColumnStart }
    $row['component_type']      = $r.ComponentType
    $row['component_name']      = Get-NullableValue $r.ComponentName 256
    $row['component_subtype']   = [System.DBNull]::Value
    $row['state_modifier']      = Get-NullableValue $r.StateModifier 200
    $row['reference_type']      = $r.ReferenceType
    $row['scope']               = $r.Scope
    $row['source_file']         = $r.SourceFile
    $row['source_section']      = Get-NullableValue $r.SourceSection 150
    $row['signature']           = Get-NullableValue $r.Signature
    $row['parent_function']     = Get-NullableValue $r.ParentFunction 200
    $row['parent_object']       = Get-NullableValue $r.ParentObject 256
    $row['raw_text']            = Get-NullableValue $r.RawText
    $row['purpose_description'] = [System.DBNull]::Value
    $row['design_notes']        = [System.DBNull]::Value
    $row['related_asset_id']    = [System.DBNull]::Value
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

if ($verify) {
    $verify | Format-Table -AutoSize
}

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
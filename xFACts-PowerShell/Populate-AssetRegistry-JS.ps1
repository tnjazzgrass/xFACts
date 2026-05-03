<#
.SYNOPSIS
    xFACts - Asset Registry JavaScript Populator

.DESCRIPTION
    Walks every .js file under the Control Center public/js and public/docs/js
    directories, parses each file with Acorn (via parse-js.js Node helper),
    and generates Asset_Registry rows describing every catalogable component
    found in the file.

    Three categories of rows are emitted:

    Group A - JS as source of HTML (closes the consumption gap left by the
              HTML populator, which only scans .ps1/.psm1 files):
      * CSS_CLASS USAGE rows for class names found inside template literals,
        string literals, classList.add/remove/toggle calls, and className
        assignments.
      * HTML_ID DEFINITION rows for id="..." attributes inside template/string
        literals, plus HTML_ID USAGE rows for getElementById and querySelector
        calls with a literal '#id' argument.

    Group B - JS as its own language (catalogs the structural elements of
              every .js file for refactor confidence and dead-code detection):
      * JS_FUNCTION DEFINITION rows for every named function (declaration,
        expression assigned to const/let/var, arrow function assigned to
        const/let/var).
      * JS_CONSTANT DEFINITION rows for every top-level (module-scope)
        const/let/var declaration that is NOT a function.
      * JS_CLASS DEFINITION rows for every class declaration.
      * JS_METHOD DEFINITION rows for every method defined inside a class body.
      * JS_FUNCTION USAGE rows for calls to (and bare references to) functions
        defined in the SAME file. This catches "I am about to rename function
        X - where do I need to update?" queries without grep.
      * JS_FUNCTION USAGE rows for calls to functions defined in any
        currently-recognized SHARED JS file. SHARED files span two zones:
        the Control Center (engine-events.js) and the Documentation site
        (nav.js, docs-controlcenter.js, ddl-erd.js, ddl-loader.js).
      * JS_IMPORT DEFINITION rows for ES module imports and Node require
        statements (graceful no-op if none are present).
      * COMMENT_BANNER DEFINITION rows for block comments containing five or
        more consecutive '=' characters (mirrors the CSS populator's banner
        detection).

    Group C - JS event handler bindings:
      * JS_EVENT USAGE rows for addEventListener calls and direct
        .on<event> = ... assignments. Captures the event name (click,
        change, submit, etc.) so we can audit which events are wired up
        across the platform.

    Scope resolution:
      * CSS_CLASS USAGE rows: the class name is looked up against existing
        CSS_CLASS DEFINITION rows already loaded by the CSS populator. If
        the class has a SHARED definition somewhere, scope=SHARED and
        source_file points to that shared CSS file. Otherwise scope=LOCAL
        with the local CSS file as source_file (or '<undefined>' if no
        DEFINITION exists in any CSS file).
      * JS_FUNCTION USAGE rows: scope=SHARED with source_file pointing at
        the actual SHARED file that defines the function (engine-events.js
        for CC-zone consumers, nav.js / ddl-erd.js / ddl-loader.js /
        docs-controlcenter.js for docs-zone consumers). Otherwise scope=
        LOCAL and source_file=<containing_file>.
      * All DEFINITION rows: scope=SHARED if the file is in the SharedFiles
        list, otherwise LOCAL.

    Dynamic interpolation handling:
      * Template literals can mix static text with ${...} expressions.
        Static parts are extracted; ${...} is treated as an opaque token
        that breaks the static run. Example: `class="card ${state}"` yields
        a USAGE row for 'card' and skips the dynamic part.
      * Pure-interpolation values like class="${classes}" yield no rows
        because nothing is statically resolvable.

    Files ending in .min.js are skipped (vendor/minified libraries).

    Run AFTER the CSS populator has loaded all CSS_CLASS DEFINITION rows.

.NOTES
    File Name      : Populate-AssetRegistry-JS.ps1
    Location       : E:\xFACts-PowerShell
    Author         : Frost Arnett Applications Team
    Version        : Tracked in dbo.System_Metadata (component: TBD)

.PARAMETER Execute
    Required to actually wipe the JS rows from Asset_Registry and write the
    new row set. Without this flag, runs in preview mode: parses every file,
    builds the row set in memory, prints summary statistics, but does NOT
    touch the database.

================================================================================
CHANGELOG
================================================================================
2026-05-02  Architectural correction: SharedFiles expanded to include the
            four docs/js files. The Documentation site zone uses a
            type-shared model rather than a single shared file - every
            docs/js file is consumed by a category of HTML pages rather
            than being page-specific (nav.js universally, ddl-erd.js for
            arch pages, ddl-loader.js for ref pages, docs-controlcenter.js
            for CC guide pages). Previous version treated docs/js files
            the same as Control Center page-specific JS, mislabeling all
            their definitions as scope=LOCAL. Net effect: definitions in
            those four files flip from LOCAL to SHARED, and downstream
            USAGE resolution correctly points at the actual docs file
            that defines each consumed function/constant. No algorithmic
            change - only the SharedFiles list was edited.
2026-05-02  Multiple fixes from first-run review of generated rows:
            (1) WALKER FIX - Removed 'expression' from the AST walker's
            property skip list. ExpressionStatement.expression is a child
            node, not a leaf flag; skipping it blocked descent into every
            IIFE and most top-level expression statements. ddl-loader.js
            (entirely wrapped in an IIFE) produced 0 rows because of this;
            renderEditForm and dozens of other rendering functions also lost
            their internal rows. The boolean 'expression' flag on
            ArrowFunctionExpression is now filtered out by the existing
            value-type check rather than the explicit skip list.
            (2) IMPERATIVE DOM CAPTURE - Added three new patterns to catch
            DOM construction that does not use template literal HTML:
              * el.id = 'x'                  -> HTML_ID DEFINITION
              * el.setAttribute('id', 'x')   -> HTML_ID DEFINITION
              * el.setAttribute('class', 'x') -> CSS_CLASS USAGE rows
            These complement the existing el.className = 'x' handler.
            (3) NULL CONSISTENCY - Get-NullableValue now treats empty/
            whitespace-only strings as NULL in addition to PowerShell
            $null. The previous behavior wrote 'state_modifier=""' for
            most rows because [ordered]@{} parameter values come through
            as empty strings, never as $null. Empty strings have no
            semantic meaning in this table - the absence of a value is
            always NULL.
            (4) Object_Registry FK RESOLUTION - At startup, load the full
            (object_name -> registry_id) map from dbo.Object_Registry.
            At insert time, look up each row's file_name and write
            registry_id into Asset_Registry.object_registry_id. Files not
            registered are tracked in a HashSet and surfaced in a WARN
            block at end-of-run so registration gaps can be remediated.
2026-05-02  Bug fix: PowerShell parser cannot resolve multi-line if-conditions
            of the form 'if (cmd1 -or cmd2)' when each subexpression is a
            cmdlet call - it interprets the first cmdlet as consuming the
            rest of the line as positional args and never sees the closing
            paren. Fixed by wrapping each Test-CalleeMatchesEnd invocation
            in its own parentheses inside the classList and querySelector
            CallExpression dispatch blocks: 'if ((cmd1) -or (cmd2))'.
2026-05-02  Initial implementation. Comprehensive first-pass extraction
            covering Group A (HTML embedded in JS), Group B (JS structural
            elements), and Group C (event handler bindings). Conservative
            method-call capture - only well-defined patterns (classList.*,
            querySelector*, getElementById, addEventListener, on<event>
            assignments) are recognized. All other method calls and property
            accesses are intentionally excluded as noise. JS_FUNCTION USAGE
            rows are emitted only when the call resolves to a same-file
            function definition or to a function in engine-events.js;
            generic identifier references that don't resolve are silently
            ignored. Skips .min.js files.
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

# Files whose top-level definitions are visible to multiple consumer files
# rather than being tied to a single page. Definitions in these files get
# scope=SHARED. The list spans two architectural zones:
#
#   Control Center zone:
#     engine-events.js - the single shared file for all CC pages.
#     Page-specific JS (admin.js, bdl-import.js, etc.) is LOCAL.
#
#   Documentation site zone:
#     All docs/js files are type-shared infrastructure consumed by
#     categories of HTML pages rather than tied to a single page:
#       nav.js                - universal, loaded by every doc page
#       docs-controlcenter.js - CC guide pages
#       ddl-erd.js            - architecture pages (ERD rendering)
#       ddl-loader.js         - reference pages (DDL JSON loader)
$SharedFiles = @(
    'engine-events.js',
    'nav.js',
    'docs-controlcenter.js',
    'ddl-erd.js',
    'ddl-loader.js'
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

# Compute occurrence_index for each (file_name, component_name, reference_type,
# state_modifier) tuple. The CSS and HTML test populators do not yet do this;
# the production populators must. We assign occurrence_index = 1 for the first
# row matching the tuple, 2 for the second, etc. Computed at the end as a
# post-processing pass over the collected rows so we don't have to track
# counters during extraction.
function Set-OccurrenceIndices {
    param([System.Collections.Generic.List[object]]$Rows)

    $counters = @{}
    foreach ($r in $Rows) {
        $stateMod = if ($r.StateModifier) { $r.StateModifier } else { '' }
        $key = "$($r.FileName)|$($r.ComponentName)|$($r.ReferenceType)|$stateMod"
        if (-not $counters.ContainsKey($key)) {
            $counters[$key] = 0
        }
        $counters[$key]++
        $r.OccurrenceIndex = $counters[$key]
    }
}

# Standardized row builder. Returns an ordered hashtable with every column
# the bulk-insert DataTable expects. ReferenceType, ComponentType, Scope,
# and SourceFile are caller-supplied; everything else has sensible defaults.
function New-AssetRow {
    param(
        [string]$FileName,
        [int]$LineStart,
        [int]$LineEnd,
        [int]$ColumnStart,
        [string]$ComponentType,
        [string]$ComponentName,
        [string]$StateModifier,
        [string]$ReferenceType,
        [string]$Scope,
        [string]$SourceFile,
        [string]$SourceSection,
        [string]$Signature,
        [string]$ParentFunction,
        [string]$ParentObject,
        [string]$RawText
    )

    return [ordered]@{
        FileName        = $FileName
        FileType        = 'JS'
        LineStart       = $LineStart
        LineEnd         = if ($LineEnd) { $LineEnd } else { $LineStart }
        ColumnStart     = $ColumnStart
        ComponentType   = $ComponentType
        ComponentName   = $ComponentName
        StateModifier   = $StateModifier
        ReferenceType   = $ReferenceType
        Scope           = $Scope
        SourceFile      = $SourceFile
        SourceSection   = $SourceSection
        Signature       = $Signature
        ParentFunction  = $ParentFunction
        ParentObject    = $ParentObject
        RawText         = $RawText
        OccurrenceIndex = 1
    }
}

# ============================================================================
# AST PARSING
# ============================================================================

# Run a single .js file through parse-js.js and return the parsed AST plus
# the raw source text (we need the source for extracting raw_text snippets
# from node ranges). Returns $null on parse failure with an error logged.
function Invoke-JsParse {
    param([Parameter(Mandatory)][string]$FilePath)

    try {
        $source = Get-Content -Path $FilePath -Raw -Encoding UTF8
        if (-not $source) { $source = '' }

        # Send source to parse-js.js via stdin and capture the JSON tree
        # from stdout. The helper script writes structured JSON on success
        # and structured-JSON-with-error-flag on failure (exit code 1).
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

        return @{ Ast = $parsed.ast; Comments = $parsed.comments; Source = $source }
    }
    catch {
        Write-Log "Exception during parse of ${FilePath}: $($_.Exception.Message)" "ERROR"
        return $null
    }
}

# Pull raw text from the source string by character range. Acorn nodes carry
# a `range` array [startCharIndex, endCharIndex] when ranges:true is set.
# Used to capture the literal source for raw_text columns and for scanning
# inside template/string literal contents that are easier to regex than to
# re-walk via AST.
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

# Format a multi-line string as a single-line representation for raw_text /
# signature columns. Replaces line breaks with spaces and trims.
function Format-SingleLine {
    param([string]$Text)
    if ($null -eq $Text) { return $null }
    $crlf = "`r`n"; $lf = "`n"; $cr = "`r"
    return ($Text -replace $crlf, ' ' -replace $lf, ' ' -replace $cr, ' ').Trim()
}

# Truncate a string for storage in fixed-width columns when needed. Used for
# signature/state_modifier/etc. raw_text and signature are VARCHAR(MAX) so no
# truncation needed; component_name is 256, state_modifier 200.
function Limit-Text {
    param([string]$Text, [int]$Max)
    if ($null -eq $Text) { return $null }
    if ($Text.Length -le $Max) { return $Text }
    return $Text.Substring(0, $Max)
}

# ============================================================================
# COMMENT BANNER DETECTION (mirrors CSS populator)
# ============================================================================

# A "banner" is a block comment containing five or more consecutive '='
# characters. The first non-empty non-equals line of the comment is taken
# as the banner title. Acorn returns block comments in the comments array
# with type='Block' and value=<comment text without the /* */ delimiters>.
function Get-BannerTitle {
    param([string]$CommentText)
    if ($null -eq $CommentText) { return $null }
    if ($CommentText -notmatch '={5,}') { return $null }

    $lines = $CommentText -split "`n"
    foreach ($line in $lines) {
        $trimmed = $line.Trim().Trim('=').Trim().Trim('*').Trim()
        if ($trimmed.Length -gt 0 -and $trimmed -notmatch '^=+$') {
            return $trimmed
        }
    }
    return $null
}

# ============================================================================
# HTML ATTRIBUTE EXTRACTION FROM STRING/TEMPLATE CONTENTS
# ============================================================================

# Cheap heuristic: skip strings that don't look like they contain HTML before
# running the more expensive regex. Mirrors the HTML populator's approach.
function Test-LooksLikeHtml {
    param([string]$Text)
    if ($null -eq $Text) { return $false }
    if ($Text.Length -lt 4) { return $false }
    if ($Text -match '<\s*\w') { return $true }
    if ($Text -match '\b(class|id)\s*=') { return $true }
    return $false
}

# Extract every class="..." and id="..." attribute occurrence from a string
# of text. Returns records with attribute kind, value, line/column offsets
# inside the input. Mirrors HTML populator's Get-HtmlAttributeOccurrences.
#
# Dynamic interpolations: we no longer skip the whole attribute when ${...}
# appears (the JS template literal equivalent of $foo in PowerShell). Instead
# we extract the static class names and skip the dynamic portions. This is
# the difference from the HTML populator's behavior - more permissive because
# JS template literals routinely mix static and dynamic class names.
function Get-HtmlAttributeOccurrences {
    param([string]$Text)
    if ($null -eq $Text) { return @() }

    $results = New-Object System.Collections.Generic.List[object]

    # Match class="..." | class='...' | id="..." | id='...'
    $pattern = '\b(class|id)\s*=\s*(["''])([^"'']*)\2'
    $regexMatches = [regex]::Matches($Text, $pattern)

    foreach ($m in $regexMatches) {
        $attrName = $m.Groups[1].Value.ToLower()
        $value    = $m.Groups[3].Value

        if ([string]::IsNullOrWhiteSpace($value)) { continue }

        # Compute line offset and column inside the input text
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

# Split a class="..." value into individual class names, dropping pure
# interpolation tokens (${...}) and anything that contains a $ which we
# cannot statically resolve. Mixed values like "card ${state} hidden"
# yield ['card', 'hidden']; pure interpolation like "${classes}" yields [].
function Split-ClassNames {
    param([string]$Value)
    if ($null -eq $Value) { return @() }

    # Replace ${...} blocks with whitespace so they break tokens cleanly
    $cleaned = [regex]::Replace($Value, '\$\{[^}]*\}', ' ')

    $tokens = @($cleaned -split '\s+' | Where-Object {
        $_ -and ($_ -notmatch '\$') -and ($_ -ne '')
    })
    return $tokens
}

# ============================================================================
# AST WALKING UTILITIES
# ============================================================================

# Generic AST walker. Visits every node in the tree and invokes the supplied
# script block once per node. The script block receives ($Node, $ParentChain)
# where ParentChain is an array of ancestor node types from root to immediate
# parent (used to determine context like "is this Identifier inside a
# CallExpression's callee position?").
function Invoke-AstWalk {
    param(
        $Node,
        [array]$ParentChain = @(),
        [Parameter(Mandatory)][scriptblock]$Visitor
    )

    if ($null -eq $Node) { return }

    # Some "nodes" are arrays (e.g., Program.body); flatten and recurse
    if ($Node -is [System.Array] -or $Node -is [System.Collections.IList]) {
        foreach ($item in $Node) {
            Invoke-AstWalk -Node $item -ParentChain $ParentChain -Visitor $Visitor
        }
        return
    }

    # Skip primitives
    if ($Node -isnot [System.Management.Automation.PSCustomObject]) { return }
    if (-not ($Node.PSObject.Properties.Name -contains 'type')) { return }

    # Visit this node
    & $Visitor $Node $ParentChain

    # Recurse into all child properties that are objects/arrays. We use the
    # generic property enumeration approach instead of a hand-coded type
    # switch because it's simpler and Acorn's node shapes are consistent.
    $newChain = @($ParentChain + $Node.type)
    foreach ($prop in $Node.PSObject.Properties) {
        $name = $prop.Name
        # Skip metadata/leaf properties that aren't AST children. NOTE:
        # 'expression' is intentionally NOT in this list - on an
        # ExpressionStatement it is a child node (the wrapped expression),
        # not a leaf flag. Leaving it out lets the walker descend into
        # IIFEs and any other top-level expression statement. The boolean
        # 'expression' property on ArrowFunctionExpression is filtered out
        # below by the value-type check (booleans are skipped automatically).
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

# Get a node's source line number (Acorn loc.start.line is 1-based)
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
        # Acorn column is 0-based; convert to 1-based for human-readable storage
        return ([int]$Node.loc.start.column) + 1
    }
    return 1
}

# Get the simple identifier name from a node that might be an Identifier or
# a Literal (used for things like 'getElementById("foo")' where the argument
# we want is the Literal node's value).
function Get-IdentifierName {
    param($Node)
    if ($null -eq $Node) { return $null }
    if ($Node.type -eq 'Identifier') { return $Node.name }
    if ($Node.type -eq 'Literal') { return [string]$Node.value }
    return $null
}

# Determine whether a CallExpression's callee matches a given dotted path
# (e.g., 'document.getElementById', 'classList.add'). Returns $true if the
# callee is a MemberExpression matching the path, with property names
# matched left-to-right against the dotted segments. The leftmost segment
# is matched as the bottom-most object (so 'classList.add' matches
# anything.classList.add(...)).
function Test-CalleeMatchesEnd {
    param(
        $Callee,
        [string[]]$Path
    )
    if ($null -eq $Callee) { return $false }

    # Walk the MemberExpression chain right-to-left collecting property names
    $segments = New-Object System.Collections.Generic.List[string]
    $cursor = $Callee
    while ($cursor -and $cursor.type -eq 'MemberExpression') {
        if ($cursor.computed) { return $false }   # foo['bar'] - skip
        if (-not $cursor.property -or $cursor.property.type -ne 'Identifier') { return $false }
        $segments.Insert(0, $cursor.property.name)
        $cursor = $cursor.object
    }
    if ($cursor -and $cursor.type -eq 'Identifier') {
        $segments.Insert(0, $cursor.name)
    }

    if ($segments.Count -lt $Path.Count) { return $false }

    # Match the LAST N segments against $Path
    $tail = $segments.Count - $Path.Count
    for ($i = 0; $i -lt $Path.Count; $i++) {
        if ($segments[$tail + $i] -ne $Path[$i]) { return $false }
    }
    return $true
}

# ============================================================================
# PASS 1 - COLLECT SHARED-SCOPE DEFINITIONS
# ============================================================================
# Walk engine-events.js (and any other shared file added to $SharedFiles)
# collecting top-level function names, top-level constant names, and class
# names. These names get scope=SHARED when emitted in Pass 2, and calls to
# them anywhere in the codebase are emitted as USAGE rows resolving to the
# shared file.

Write-Log "Pass 1: collecting SHARED-scope JS definitions..."

$sharedFunctions = New-Object 'System.Collections.Generic.HashSet[string]'
$sharedConstants = New-Object 'System.Collections.Generic.HashSet[string]'
$sharedClasses   = New-Object 'System.Collections.Generic.HashSet[string]'
$sharedSourceFile = @{}   # name -> source file (for source_file column on USAGE rows)

# Cache parsed ASTs so we don't re-parse files in Pass 2
$astCache = @{}

# Discover all .js files (excluding .min.js)
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
Write-Log "Discovered $($JsFiles.Count) .js files to scan"

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

    if ($SharedFiles -notcontains $name) { continue }

    # Walk only the top-level body of the Program node
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
            'ExportNamedDeclaration' {
                # Future-proof for ES modules; treat exported decl identically
                # to its inner declaration. No-op if no .declaration child.
                if ($stmt.declaration) {
                    # Defer to a recursive pass on the inner declaration
                    $inner = $stmt.declaration
                    switch ($inner.type) {
                        'FunctionDeclaration' {
                            if ($inner.id -and $inner.id.name) {
                                [void]$sharedFunctions.Add($inner.id.name)
                                if (-not $sharedSourceFile.ContainsKey($inner.id.name)) {
                                    $sharedSourceFile[$inner.id.name] = $name
                                }
                            }
                        }
                        'VariableDeclaration' {
                            foreach ($decl in $inner.declarations) {
                                if ($decl.id -and $decl.id.type -eq 'Identifier') {
                                    [void]$sharedConstants.Add($decl.id.name)
                                    if (-not $sharedSourceFile.ContainsKey($decl.id.name)) {
                                        $sharedSourceFile[$decl.id.name] = $name
                                    }
                                }
                            }
                        }
                        'ClassDeclaration' {
                            if ($inner.id -and $inner.id.name) {
                                [void]$sharedClasses.Add($inner.id.name)
                                if (-not $sharedSourceFile.ContainsKey($inner.id.name)) {
                                    $sharedSourceFile[$inner.id.name] = $name
                                }
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
# Class names found in HTML/template strings need to be resolved against
# existing CSS_CLASS DEFINITION rows to determine scope (SHARED vs LOCAL)
# and source_file. This requires the CSS populator to have run already.

Write-Log "Loading existing CSS_CLASS DEFINITION rows for scope resolution..."

$cssDefs = Get-SqlData -Query @"
SELECT component_name, scope, file_name
FROM dbo.Asset_Registry
WHERE component_type = 'CSS_CLASS'
  AND reference_type = 'DEFINITION'
  AND file_type = 'CSS'
  AND is_active = 1;
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
    Write-Log "Could not load CSS_CLASS DEFINITION rows (table empty or query failed). Class scope resolution will mark everything '<undefined>'." "WARN"
}

Write-Log ("  Shared CSS classes:     {0}" -f $sharedClassMap.Count)
Write-Log ("  Local-only CSS classes: {0}" -f $localClassMap.Count)

# ============================================================================
# LOAD Object_Registry FOR object_registry_id RESOLUTION
# ============================================================================
# Asset_Registry.object_registry_id is a foreign key to dbo.Object_Registry
# .registry_id. Every row inserted should carry the registry_id of the source
# file (admin.css -> the registry_id row whose object_name = 'admin.css').
# Load the mapping once at startup and apply it in the bulk-insert phase.

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
            # Last-write-wins if duplicates exist; UQ_Object_Registry_object
            # has a unique constraint on (component_name, object_name) so
            # the same object_name can technically appear under multiple
            # components. Hashtable collisions here would indicate a
            # registration anomaly worth surfacing - we'll just take the
            # first one we see.
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

# Track files we attempted to look up but did NOT find. Used at end-of-run
# to surface registration gaps - per Development Guidelines, every CC file
# is supposed to be registered in Object_Registry.
$objectRegistryMisses = New-Object 'System.Collections.Generic.HashSet[string]'

# ============================================================================
# PASS 2 - GENERATE ROWS
# ============================================================================
# For each cached AST, walk it once collecting per-file context (top-level
# function/constant names for same-file USAGE resolution), then walk it
# again emitting rows for every catalogable pattern.

Write-Log "Pass 2: generating Asset_Registry rows..."

# ----- Per-file extraction --------------------------------------------------

function Get-LocalDefinitions {
    <#
    Walks the top-level Program body and returns three sets:
      Functions = top-level function names (declarations + const-assigned
                  function/arrow expressions)
      Constants = top-level non-function const/let/var names
      Classes   = top-level class names
    Used to determine which Identifier references inside the file are
    USAGEs of locally-defined functions.
    #>
    param($ProgramBody)

    $funcs = New-Object 'System.Collections.Generic.HashSet[string]'
    $consts = New-Object 'System.Collections.Generic.HashSet[string]'
    $classes = New-Object 'System.Collections.Generic.HashSet[string]'

    if ($null -eq $ProgramBody) {
        return @{ Functions = $funcs; Constants = $consts; Classes = $classes }
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
                    else {
                        [void]$consts.Add($decl.id.name)
                    }
                }
            }
            'ClassDeclaration' {
                if ($stmt.id -and $stmt.id.name) { [void]$classes.Add($stmt.id.name) }
            }
            'ExportNamedDeclaration' {
                if ($stmt.declaration) {
                    $inner = $stmt.declaration
                    switch ($inner.type) {
                        'FunctionDeclaration' {
                            if ($inner.id -and $inner.id.name) { [void]$funcs.Add($inner.id.name) }
                        }
                        'VariableDeclaration' {
                            foreach ($decl in $inner.declarations) {
                                if ($decl.id -and $decl.id.type -eq 'Identifier') {
                                    [void]$consts.Add($decl.id.name)
                                }
                            }
                        }
                        'ClassDeclaration' {
                            if ($inner.id -and $inner.id.name) { [void]$classes.Add($inner.id.name) }
                        }
                    }
                }
            }
        }
    }

    return @{ Functions = $funcs; Constants = $consts; Classes = $classes }
}

# ----- Per-AST visitors -----------------------------------------------------
#
# Visitor scriptblocks need access to: the current file name, the file's
# shared/local flag, the file's local definitions, the current source text,
# and the running rows/dedupe collections. PowerShell scriptblock closures
# capture by reference; we set $script:* state before invoking the walker.

$script:CurrentFile           = $null
$script:CurrentFileIsShared   = $false
$script:CurrentFileSource     = $null
$script:CurrentLocalFuncs     = $null
$script:CurrentLocalConsts    = $null
$script:CurrentLocalClasses   = $null

# Helper: emit a CSS_CLASS USAGE row for a class name found inside this file.
# Resolves scope/source_file against the CSS_CLASS DEFINITION map loaded
# earlier; falls back to '<undefined>' if no definition exists anywhere.
function Add-ClassUsageRow {
    param(
        [string]$ClassName,
        [int]$LineStart,
        [int]$ColumnStart,
        [string]$Signature,
        [string]$ParentFunction,
        [string]$RawText
    )

    if ([string]::IsNullOrWhiteSpace($ClassName)) { return }

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
    if (-not (Test-AddDedupeKey -Key $key)) { return }

    $row = New-AssetRow -FileName $script:CurrentFile -LineStart $LineStart `
        -LineEnd $LineStart -ColumnStart $ColumnStart `
        -ComponentType 'CSS_CLASS' -ComponentName $ClassName `
        -StateModifier $null -ReferenceType 'USAGE' `
        -Scope $scope -SourceFile $sourceFile `
        -SourceSection $null `
        -Signature (Limit-Text $Signature 4000) `
        -ParentFunction $ParentFunction -ParentObject $null `
        -RawText (Limit-Text $RawText 4000)
    $script:rows.Add($row)
}

# Helper: emit an HTML_ID DEFINITION or USAGE row.
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

    if ([string]::IsNullOrWhiteSpace($IdName)) { return }

    $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }
    $sourceFile = $script:CurrentFile

    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|HTML_ID|$IdName|$ReferenceType|"
    if (-not (Test-AddDedupeKey -Key $key)) { return }

    $row = New-AssetRow -FileName $script:CurrentFile -LineStart $LineStart `
        -LineEnd $LineStart -ColumnStart $ColumnStart `
        -ComponentType 'HTML_ID' -ComponentName $IdName `
        -StateModifier $null -ReferenceType $ReferenceType `
        -Scope $scope -SourceFile $sourceFile `
        -SourceSection $null `
        -Signature (Limit-Text $Signature 4000) `
        -ParentFunction $ParentFunction -ParentObject $null `
        -RawText (Limit-Text $RawText 4000)
    $script:rows.Add($row)
}

# Helper: scan a string of text for HTML class= and id= attributes and
# generate appropriate rows. The Text comes from a template literal or
# string literal whose start position in the file is StartLine/StartCol;
# attribute matches inside the text are translated back to file coordinates.
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
            # Skip pure-interpolation ids (e.g., id="${myId}")
            if ($occ.Value -match '^\s*\$\{[^}]+\}\s*$') { continue }
            # Skip ids that are entirely a single $variable reference too
            if ($occ.Value -match '^\s*\$\w+\s*$') { continue }
            Add-HtmlIdRow -IdName $occ.Value -ReferenceType 'DEFINITION' `
                -LineStart $sourceLine -ColumnStart $sourceCol `
                -Signature "id=`"$($occ.Value)`"" `
                -ParentFunction $ParentFunction `
                -RawText "id=`"$($occ.Value)`""
        }
        else {
            $classNames = Split-ClassNames -Value $occ.Value
            foreach ($cls in $classNames) {
                Add-ClassUsageRow -ClassName $cls `
                    -LineStart $sourceLine -ColumnStart $sourceCol `
                    -Signature "class=`"$($occ.Value)`"" `
                    -ParentFunction $ParentFunction `
                    -RawText "class=`"$($occ.Value)`""
            }
        }
    }
}

# Helper: emit a JS_FUNCTION/JS_CONSTANT/JS_CLASS/JS_METHOD/JS_IMPORT DEFINITION row.
function Add-JsDefinitionRow {
    param(
        [string]$ComponentType,
        [string]$ComponentName,
        [int]$LineStart,
        [int]$LineEnd,
        [int]$ColumnStart,
        [string]$Signature,
        [string]$ParentFunction,
        [string]$ParentObject,
        [string]$RawText
    )

    if ([string]::IsNullOrEmpty($ComponentName)) { return }

    $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }
    $sourceFile = $script:CurrentFile

    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|$ComponentType|$ComponentName|DEFINITION|"
    if (-not (Test-AddDedupeKey -Key $key)) { return }

    $row = New-AssetRow -FileName $script:CurrentFile -LineStart $LineStart `
        -LineEnd $LineEnd -ColumnStart $ColumnStart `
        -ComponentType $ComponentType -ComponentName $ComponentName `
        -StateModifier $null -ReferenceType 'DEFINITION' `
        -Scope $scope -SourceFile $sourceFile `
        -SourceSection $null `
        -Signature (Limit-Text $Signature 4000) `
        -ParentFunction $ParentFunction -ParentObject $ParentObject `
        -RawText (Limit-Text $RawText 4000)
    $script:rows.Add($row)
}

# Helper: emit a JS_FUNCTION USAGE row when a call/reference resolves to
# either a same-file local function or a shared (engine-events) function.
function Add-JsFunctionUsageRow {
    param(
        [string]$FunctionName,
        [int]$LineStart,
        [int]$ColumnStart,
        [string]$Signature,
        [string]$ParentFunction,
        [string]$RawText
    )

    if ([string]::IsNullOrEmpty($FunctionName)) { return }

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
        # Not resolvable to a known function - skip (avoids identifier-name
        # collision noise from local variables, parameters, etc.)
        return
    }

    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|JS_FUNCTION|$FunctionName|USAGE|"
    if (-not (Test-AddDedupeKey -Key $key)) { return }

    $row = New-AssetRow -FileName $script:CurrentFile -LineStart $LineStart `
        -LineEnd $LineStart -ColumnStart $ColumnStart `
        -ComponentType 'JS_FUNCTION' -ComponentName $FunctionName `
        -StateModifier $null -ReferenceType 'USAGE' `
        -Scope $scope -SourceFile $sourceFile `
        -SourceSection $null `
        -Signature (Limit-Text $Signature 4000) `
        -ParentFunction $ParentFunction -ParentObject $null `
        -RawText (Limit-Text $RawText 4000)
    $script:rows.Add($row)
}

# Helper: emit a JS_EVENT USAGE row.
function Add-JsEventRow {
    param(
        [string]$EventName,
        [int]$LineStart,
        [int]$ColumnStart,
        [string]$Signature,
        [string]$ParentFunction,
        [string]$RawText
    )

    if ([string]::IsNullOrWhiteSpace($EventName)) { return }

    $scope = if ($script:CurrentFileIsShared) { 'SHARED' } else { 'LOCAL' }
    $sourceFile = $script:CurrentFile

    $key = "$($script:CurrentFile)|$LineStart|$ColumnStart|JS_EVENT|$EventName|USAGE|"
    if (-not (Test-AddDedupeKey -Key $key)) { return }

    $row = New-AssetRow -FileName $script:CurrentFile -LineStart $LineStart `
        -LineEnd $LineStart -ColumnStart $ColumnStart `
        -ComponentType 'JS_EVENT' -ComponentName $EventName `
        -StateModifier $null -ReferenceType 'USAGE' `
        -Scope $scope -SourceFile $sourceFile `
        -SourceSection $null `
        -Signature (Limit-Text $Signature 4000) `
        -ParentFunction $ParentFunction -ParentObject $null `
        -RawText (Limit-Text $RawText 4000)
    $script:rows.Add($row)
}

# ----- The actual visitor ----------------------------------------------------

$visitor = {
    param($Node, $ParentChain)

    if ($null -eq $Node -or $null -eq $Node.type) { return }

    $line = Get-NodeLine -Node $Node
    $endLine = Get-NodeEndLine -Node $Node
    $col = Get-NodeColumn -Node $Node

    # Determine the immediately-enclosing function name (for parent_function
    # column on rows). Walk the parent chain backwards looking for a function
    # context. ParentChain contains type strings only, so we lose the actual
    # function name - we accept that limitation for v1 and leave parent_function
    # as null. A future enhancement could track function-name context as we
    # descend; not worth the complexity for first pass.
    $parentFn = $null

    switch ($Node.type) {

        # ------- Group B: JS structural definitions ------------------------

        'FunctionDeclaration' {
            if ($Node.id -and $Node.id.name) {
                $sig = "function $($Node.id.name)("
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

                # Only emit DEFINITION at top-level function declarations
                # (parent is Program or ExportNamedDeclaration). Nested
                # function declarations inside other functions are valid JS
                # but rare in CC code; we capture them too for completeness.
                Add-JsDefinitionRow -ComponentType 'JS_FUNCTION' `
                    -ComponentName $Node.id.name `
                    -LineStart $line -LineEnd $endLine -ColumnStart $col `
                    -Signature $sig -ParentFunction $parentFn `
                    -RawText $sig
            }
        }

        'VariableDeclaration' {
            # Only catalog top-level variable declarations. Nested inside a
            # function body or block, these are local scaffolding and we
            # explicitly excluded them.
            $isTopLevel = ($ParentChain -join '/') -in @('Program','Program/ExportNamedDeclaration')
            if (-not $isTopLevel) { return }

            foreach ($decl in $Node.declarations) {
                if (-not $decl.id -or $decl.id.type -ne 'Identifier') { continue }
                $declName = $decl.id.name
                $declLine = Get-NodeLine -Node $decl
                $declCol = Get-NodeColumn -Node $decl
                $declEnd = Get-NodeEndLine -Node $decl
                $init = $decl.init

                if ($init -and ($init.type -eq 'FunctionExpression' -or $init.type -eq 'ArrowFunctionExpression')) {
                    # const foo = function() {} OR const foo = () => {}
                    $arrowMarker = if ($init.type -eq 'ArrowFunctionExpression') { ' => ' } else { ' = function' }
                    $sig = "$($Node.kind) $declName$arrowMarker(...)"
                    Add-JsDefinitionRow -ComponentType 'JS_FUNCTION' `
                        -ComponentName $declName `
                        -LineStart $declLine -LineEnd $declEnd -ColumnStart $declCol `
                        -Signature $sig -ParentFunction $null `
                        -RawText $sig
                }
                elseif ($init -and $init.type -eq 'ClassExpression') {
                    Add-JsDefinitionRow -ComponentType 'JS_CLASS' `
                        -ComponentName $declName `
                        -LineStart $declLine -LineEnd $declEnd -ColumnStart $declCol `
                        -Signature "$($Node.kind) $declName = class" -ParentFunction $null `
                        -RawText "$($Node.kind) $declName = class"
                }
                else {
                    # Plain constant / let / var
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
                    Add-JsDefinitionRow -ComponentType 'JS_CONSTANT' `
                        -ComponentName $declName `
                        -LineStart $declLine -LineEnd $declEnd -ColumnStart $declCol `
                        -Signature $valSig -ParentFunction $null `
                        -RawText $valSig
                }
            }
        }

        'ClassDeclaration' {
            if ($Node.id -and $Node.id.name) {
                $sig = "class $($Node.id.name)"
                if ($Node.superClass -and $Node.superClass.name) { $sig += " extends $($Node.superClass.name)" }
                Add-JsDefinitionRow -ComponentType 'JS_CLASS' `
                    -ComponentName $Node.id.name `
                    -LineStart $line -LineEnd $endLine -ColumnStart $col `
                    -Signature $sig -ParentFunction $null `
                    -RawText $sig
            }
        }

        'MethodDefinition' {
            # Methods inside a class body. The parent class name lives a few
            # frames up the chain; we don't currently capture it as
            # parent_object since ParentChain only carries types. Acceptable
            # gap for v1.
            if ($Node.key -and $Node.key.type -eq 'Identifier') {
                $methodName = $Node.key.name
                $sig = "$methodName(...)"
                if ($Node.kind -eq 'constructor') { $sig = "constructor(...)" }
                Add-JsDefinitionRow -ComponentType 'JS_METHOD' `
                    -ComponentName $methodName `
                    -LineStart $line -LineEnd $endLine -ColumnStart $col `
                    -Signature $sig -ParentFunction $null -ParentObject $null `
                    -RawText $sig
            }
        }

        # ------- Group B: imports/requires (graceful no-op if absent) -----

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
                        -ParentFunction $null -ParentObject $sourceVal `
                        -RawText "import $importedName from '$sourceVal'"
                }
            }
        }

        # ------- Group A & C: CallExpression patterns ---------------------

        'CallExpression' {
            $callee = $Node.callee
            if ($null -eq $callee) { return }

            # ---- Direct function call: foo(...) -----------------------
            if ($callee.type -eq 'Identifier') {
                $fnName = $callee.name
                $sig = "$fnName(...)"
                Add-JsFunctionUsageRow -FunctionName $fnName `
                    -LineStart $line -ColumnStart $col `
                    -Signature $sig -ParentFunction $parentFn `
                    -RawText $sig
            }

            # ---- classList.add('foo') / .remove('bar') / .toggle('baz') --
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
                                -Signature $sig -ParentFunction $parentFn `
                                -RawText $sig
                        }
                    }
                }
            }

            # ---- document.getElementById('foo') ----------------------
            if (Test-CalleeMatchesEnd -Callee $callee -Path @('getElementById')) {
                $arg = $Node.arguments | Select-Object -First 1
                if ($arg -and $arg.type -eq 'Literal' -and $arg.value -is [string]) {
                    $idName = $arg.value
                    $sig = "getElementById('$idName')"
                    Add-HtmlIdRow -IdName $idName -ReferenceType 'USAGE' `
                        -LineStart (Get-NodeLine -Node $arg) `
                        -ColumnStart (Get-NodeColumn -Node $arg) `
                        -Signature $sig -ParentFunction $parentFn `
                        -RawText $sig
                }
            }

            # ---- querySelector('.foo' | '#bar' | 'div.foo' ...) ------
            if ((Test-CalleeMatchesEnd -Callee $callee -Path @('querySelector')) -or
                (Test-CalleeMatchesEnd -Callee $callee -Path @('querySelectorAll'))) {
                $arg = $Node.arguments | Select-Object -First 1
                if ($arg -and $arg.type -eq 'Literal' -and $arg.value -is [string]) {
                    $selector = $arg.value
                    $methodName = $callee.property.name
                    $sig = "$methodName('$selector')"

                    # Extract id references (#foo) and class references (.foo)
                    $idMatches = [regex]::Matches($selector, '#([\w-]+)')
                    foreach ($im in $idMatches) {
                        Add-HtmlIdRow -IdName $im.Groups[1].Value -ReferenceType 'USAGE' `
                            -LineStart (Get-NodeLine -Node $arg) `
                            -ColumnStart (Get-NodeColumn -Node $arg) `
                            -Signature $sig -ParentFunction $parentFn `
                            -RawText $sig
                    }
                    $classMatches = [regex]::Matches($selector, '\.([\w-]+)')
                    foreach ($cm in $classMatches) {
                        Add-ClassUsageRow -ClassName $cm.Groups[1].Value `
                            -LineStart (Get-NodeLine -Node $arg) `
                            -ColumnStart (Get-NodeColumn -Node $arg) `
                            -Signature $sig -ParentFunction $parentFn `
                            -RawText $sig
                    }
                }
            }

            # ---- .addEventListener('click', handler) -----------------
            if (Test-CalleeMatchesEnd -Callee $callee -Path @('addEventListener')) {
                $arg = $Node.arguments | Select-Object -First 1
                if ($arg -and $arg.type -eq 'Literal' -and $arg.value -is [string]) {
                    $evName = $arg.value
                    $sig = "addEventListener('$evName', ...)"
                    Add-JsEventRow -EventName $evName `
                        -LineStart (Get-NodeLine -Node $arg) `
                        -ColumnStart (Get-NodeColumn -Node $arg) `
                        -Signature $sig -ParentFunction $parentFn `
                        -RawText $sig
                }
            }

            # ---- el.setAttribute('id', 'foo') / ('class', 'a b') -----
            # Imperative DOM construction pattern. setAttribute('id', VAL)
            # produces an HTML_ID DEFINITION row; setAttribute('class', VAL)
            # produces CSS_CLASS USAGE rows (one per space-separated class).
            # Other attribute names (data-*, aria-*, type, role, ...) are
            # ignored on this first pass.
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
                            -Signature $sig -ParentFunction $parentFn `
                            -RawText $sig
                    }
                    elseif ($attrName -eq 'class' -and -not [string]::IsNullOrWhiteSpace($attrVal)) {
                        $sig = "setAttribute('class', '$attrVal')"
                        $classNames = Split-ClassNames -Value $attrVal
                        foreach ($cls in $classNames) {
                            Add-ClassUsageRow -ClassName $cls `
                                -LineStart (Get-NodeLine -Node $arg2) `
                                -ColumnStart (Get-NodeColumn -Node $arg2) `
                                -Signature $sig -ParentFunction $parentFn `
                                -RawText $sig
                        }
                    }
                }
            }

            # ---- require('foo') -----------------------------------
            if ($callee.type -eq 'Identifier' -and $callee.name -eq 'require') {
                $arg = $Node.arguments | Select-Object -First 1
                if ($arg -and $arg.type -eq 'Literal' -and $arg.value -is [string]) {
                    $modName = $arg.value
                    $sig = "require('$modName')"
                    Add-JsDefinitionRow -ComponentType 'JS_IMPORT' `
                        -ComponentName $modName `
                        -LineStart $line -LineEnd $endLine -ColumnStart $col `
                        -Signature $sig -ParentFunction $null -ParentObject $modName `
                        -RawText $sig
                }
            }
        }

        # ------- Group A: template literals containing HTML --------------

        'TemplateLiteral' {
            # Quasis are the static text segments; expressions are the ${...}
            # interpolations between them. Reconstruct the full text with
            # ${...} placeholders so HTML attribute regex can find static
            # class names, and Split-ClassNames will drop dynamic parts.
            $reconstructed = ''
            for ($i = 0; $i -lt $Node.quasis.Count; $i++) {
                $q = $Node.quasis[$i]
                $reconstructed += $q.value.cooked
                if ($i -lt $Node.expressions.Count) {
                    $reconstructed += '${dyn}'
                }
            }

            if (-not (Test-LooksLikeHtml -Text $reconstructed)) { return }

            $rawSnippet = Get-RangeText -Source $script:CurrentFileSource -Node $Node
            $rawDisplay = Format-SingleLine -Text $rawSnippet

            Add-RowsFromHtmlBearingText -Text $reconstructed `
                -StartLine $line -StartCol $col `
                -ParentFunction $parentFn `
                -RawText $rawDisplay
        }

        # ------- Group A: string literals containing HTML ----------------

        'Literal' {
            # Skip non-string literals (numbers, booleans, regex, null)
            if ($null -eq $Node.value) { return }
            if (-not ($Node.value -is [string])) { return }

            $strVal = [string]$Node.value
            if (-not (Test-LooksLikeHtml -Text $strVal)) { return }

            $rawSnippet = Get-RangeText -Source $script:CurrentFileSource -Node $Node
            $rawDisplay = Format-SingleLine -Text $rawSnippet

            Add-RowsFromHtmlBearingText -Text $strVal `
                -StartLine $line -StartCol $col `
                -ParentFunction $parentFn `
                -RawText $rawDisplay
        }

        # ------- Group A & C: assignment patterns -------------------------

        'AssignmentExpression' {
            # Patterns of interest here:
            #   1. el.className = 'foo bar'                        (Group A)
            #   2. el.id        = 'edit-status'                    (Group A - imperative DOM)
            #   3. el.onclick   = function() {} | el.onchange = .. (Group C)
            $left = $Node.left
            $right = $Node.right
            if ($null -eq $left -or $null -eq $right) { return }
            if ($left.type -ne 'MemberExpression') { return }
            if ($left.computed) { return }
            if (-not $left.property -or $left.property.type -ne 'Identifier') { return }

            $propName = $left.property.name

            # className = '...' -> CSS_CLASS USAGE rows for each class
            if ($propName -eq 'className' -and $right.type -eq 'Literal' -and $right.value -is [string]) {
                $classNames = Split-ClassNames -Value $right.value
                foreach ($cls in $classNames) {
                    Add-ClassUsageRow -ClassName $cls `
                        -LineStart (Get-NodeLine -Node $right) `
                        -ColumnStart (Get-NodeColumn -Node $right) `
                        -Signature "className = '$($right.value)'" `
                        -ParentFunction $parentFn `
                        -RawText "className = '$($right.value)'"
                }
            }

            # className = `tpl` -> handled via TemplateLiteral visitor above
            # because the template literal node will be visited independently.

            # id = '...' -> HTML_ID DEFINITION row (imperative DOM construction
            # pattern: const el = document.createElement('input'); el.id = 'foo')
            if ($propName -eq 'id' -and $right.type -eq 'Literal' -and $right.value -is [string]) {
                $idVal = [string]$right.value
                if (-not [string]::IsNullOrWhiteSpace($idVal)) {
                    Add-HtmlIdRow -IdName $idVal -ReferenceType 'DEFINITION' `
                        -LineStart (Get-NodeLine -Node $right) `
                        -ColumnStart (Get-NodeColumn -Node $right) `
                        -Signature "id = '$idVal'" `
                        -ParentFunction $parentFn `
                        -RawText "id = '$idVal'"
                }
            }

            # on<event> = ...  -> JS_EVENT USAGE row
            if ($propName -match '^on([a-z]+)$') {
                $evName = $matches[1]
                $sig = "$propName = ..."
                Add-JsEventRow -EventName $evName `
                    -LineStart $line -ColumnStart $col `
                    -Signature $sig -ParentFunction $parentFn `
                    -RawText $sig
            }
        }
    }
}

# ----- Per-file orchestration ------------------------------------------------

foreach ($file in $JsFiles) {
    $name = [System.IO.Path]::GetFileName($file)
    $isShared = $SharedFiles -contains $name

    if (-not $astCache.ContainsKey($file)) {
        Write-Log "  Skipping (no parsed AST): $name" "WARN"
        continue
    }

    $parsed = $astCache[$file]
    $script:CurrentFile         = $name
    $script:CurrentFileIsShared = $isShared
    $script:CurrentFileSource   = $parsed.Source

    # Build per-file local definition sets for same-file USAGE resolution
    $localDefs = Get-LocalDefinitions -ProgramBody $parsed.Ast.body
    $script:CurrentLocalFuncs   = $localDefs.Functions
    $script:CurrentLocalConsts  = $localDefs.Constants
    $script:CurrentLocalClasses = $localDefs.Classes

    $startCount = $rows.Count
    $scopeLabel = if ($isShared) { 'SHARED' } else { 'LOCAL' }
    Write-Host ("  Walking {0} ({1})..." -f $name, $scopeLabel) -ForegroundColor Cyan

    Invoke-AstWalk -Node $parsed.Ast -Visitor $visitor

    # Comment banners (outside the AST proper - they live in the comments array)
    if ($parsed.Comments) {
        foreach ($c in $parsed.Comments) {
            if ($c.type -ne 'Block') { continue }
            $title = Get-BannerTitle -CommentText $c.value
            if (-not $title) { continue }

            $cLine = if ($c.loc -and $c.loc.start -and $c.loc.start.line) { [int]$c.loc.start.line } else { 1 }
            $cEndLine = if ($c.loc -and $c.loc.end -and $c.loc.end.line) { [int]$c.loc.end.line } else { $cLine }
            $cCol = if ($c.loc -and $c.loc.start -and ($c.loc.start.PSObject.Properties.Name -contains 'column')) { ([int]$c.loc.start.column) + 1 } else { 1 }

            $key = "$name|$cLine|COMMENT_BANNER|$title|DEFINITION|"
            if (Test-AddDedupeKey -Key $key) {
                $scope = if ($isShared) { 'SHARED' } else { 'LOCAL' }
                $rawSnippet = Format-SingleLine -Text $c.value
                $row = New-AssetRow -FileName $name -LineStart $cLine -LineEnd $cEndLine -ColumnStart $cCol `
                    -ComponentType 'COMMENT_BANNER' -ComponentName $title `
                    -StateModifier $null -ReferenceType 'DEFINITION' `
                    -Scope $scope -SourceFile $name `
                    -SourceSection $null -Signature $null `
                    -ParentFunction $null -ParentObject $null `
                    -RawText (Limit-Text $rawSnippet 4000)
                $rows.Add($row)
            }
        }
    }

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

Write-Log "Clearing existing JS rows from Asset_Registry..."
$cleared = Invoke-SqlNonQuery -Query "DELETE FROM dbo.Asset_Registry WHERE file_type = 'JS';"
if (-not $cleared) {
    Write-Log "Failed to clear existing JS rows. Aborting." "ERROR"
    exit 1
}

if ($rows.Count -eq 0) {
    Write-Log "No rows to insert." "WARN"
    exit 0
}

Write-Log "Bulk-inserting $($rows.Count) rows..."

# Build DataTable matching dbo.Asset_Registry schema (verified against
# schema used by CSS and HTML test populators)
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

function Get-NullableValue {
    # Returns the input value, OR [System.DBNull]::Value when the value is
    # null OR an empty/whitespace-only string. Optional truncation when
    # MaxLen is supplied. Universal NULL semantics: empty strings have no
    # semantic meaning in this table - "this attribute does not apply"
    # is always NULL, never ''.
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
    $row['file_name']           = $r.FileName

    # Resolve object_registry_id via the preloaded Object_Registry map.
    # Files not registered are tracked for the end-of-run warning.
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
WHERE file_type = 'JS'
GROUP BY component_type, reference_type, scope
ORDER BY component_type, reference_type, scope;
"@

if ($verify) {
    $verify | Format-Table -AutoSize
}

# ----- Object_Registry miss report ------------------------------------------
# Per Development Guidelines, every CC file should be registered in
# dbo.Object_Registry. Files that produced rows but had no Object_Registry
# match are surfaced here so the gap can be remediated. Missing entries
# do not fail the run - rows are still inserted with object_registry_id NULL.

if ($objectRegistryMisses.Count -gt 0) {
    Write-Log ("Object_Registry registration gaps detected for {0} file(s):" -f $objectRegistryMisses.Count) "WARN"
    foreach ($missing in ($objectRegistryMisses | Sort-Object)) {
        Write-Log ("  MISSING: $missing") "WARN"
    }
    Write-Log "Add the file(s) above to dbo.Object_Registry to enable FK linkage on subsequent runs." "WARN"
}

Write-Log "Done."
exit 0
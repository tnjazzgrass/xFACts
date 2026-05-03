<#
.SYNOPSIS
    xFACts - Asset Registry HTML Populator

.DESCRIPTION
    Walks every .ps1 and .psm1 file under the Control Center scripts
    directories (routes and modules), parses each file with the PowerShell
    AST parser, and emits Asset_Registry rows describing every HTML
    component embedded in PowerShell string tokens.

    Unlike CSS and JS which are parsed by language-aware tools (PostCSS,
    Acorn), HTML is embedded in PowerShell strings as raw text. The
    PowerShell parser sees these as opaque string content; the HTML
    populator does its own pattern-matching against the string contents
    to extract HTML attributes.

    The HTML populator emits the following row types:

      * HTML_ID DEFINITION rows for every id="..." attribute in HTML
        markup. PowerShell here-strings often carry an entire HTML page
        worth of structure - one DEFINITION row is emitted per id
        attribute occurrence.

      * CSS_CLASS USAGE rows for every class name found in class="..."
        attributes. Each space-separated class becomes its own row.
        Scope is resolved against existing CSS_CLASS DEFINITION rows
        loaded from Asset_Registry at script start - if the class has a
        SHARED definition somewhere, scope=SHARED and source_file points
        at that shared CSS file. Otherwise scope=LOCAL with source_file
        pointing at the local CSS file that defines it (or '<undefined>'
        when no DEFINITION exists in any cataloged CSS file).

      * COMMENT_BANNER DEFINITION rows for block comments containing
        five or more consecutive '=' characters. The banner title is
        taken from the first non-empty non-equals line of the comment.
        Banner titles are propagated to source_section on subsequent
        rows in the same file until the next banner is encountered.

    Enrichment columns:

      * parent_function - For string tokens located inside a PowerShell
        function definition, the containing function's name is recorded.
        Computed by walking FunctionDefinitionAst nodes once per file
        and building a line-range map.

        IMPORTANT: parent_function is intentionally NULL for HTML rows
        located outside any function definition. In CC route files, most
        HTML lives inside Add-PodeRoute -ScriptBlock { ... } blocks. A
        ScriptBlock is a ScriptBlockExpressionAst, NOT a
        FunctionDefinitionAst, so the AST walk does not classify these
        as function context. This is correct behavior - the natural
        parent for that HTML is the route path (e.g., '/admin'), not a
        function name. Phase 3's PowerShell populator will recognize
        Add-PodeRoute calls and emit API_ROUTE rows; a downstream
        enrichment pass will then populate parent_object on existing
        HTML rows with the route path of the handler they live inside.

      * source_section - The most recently encountered banner title in
        the same file. Banners are detected from contiguous runs of
        '#'-prefixed Comment tokens. PowerShell tokenizes each '#' line
        as a separate Comment token, so the walker accumulates
        consecutive Comment tokens whose lines are sequential and runs
        banner detection on the aggregated text. A banner is recognized
        when the aggregated text contains five or more consecutive '='
        characters; the banner's title is the first non-empty,
        non-equals line in the block.

      * parent_object - Currently NULL for all HTML rows. Reserved for
        future enrichment by the PowerShell populator (Phase 3), which
        will catalog Add-PodeRoute calls and provide the route path
        each HTML row belongs to.

    Scope of files scanned:

      * E:\xFACts-ControlCenter\scripts\routes  (page route handlers)
      * E:\xFACts-ControlCenter\scripts\modules (helper modules)

    PowerShell files outside the Control Center (orchestrator scripts in
    E:\xFACts-PowerShell\) are NOT scanned for HTML extraction - they do
    not emit HTML markup.

    Refresh semantics:

      * In standalone execution, the populator deletes only its own
        slice (file_type='HTML') before bulk-inserting. This makes the
        populator independently re-runnable for development.
      * Under the orchestrator, the orchestrator TRUNCATEs the table
        once at the start and the populator's DELETE-WHERE becomes a
        harmless no-op on already-empty data.

    Heuristic for "is this string actually HTML":

      * Must be at least 8 characters long.
      * Must match either '<\s*\w' (tag-like opening) OR contain
        'class=' or 'id=' attribute syntax.

    This filters out short strings, file paths, and most non-HTML
    content. It is permissive enough that some non-HTML strings
    containing 'class=' or 'id=' substrings (e.g., SQL fragments)
    might be scanned, but the regex extraction step is precise enough
    that no rows are emitted from such false positives.

    Variable interpolation handling:

      Helper modules build HTML through StringBuilder concatenation, with
      heavy use of PowerShell variable interpolation in attribute values.
      Patterns like:

         class="nav-link$accentClass$activeClass"
         class="card $type wide"
         class="$cssClasses"

      ...have static portions we can catalog plus dynamic portions we
      cannot. The populator handles each form differently:

        Fully-static values (no '$') - existing behavior. Class values
        are split on whitespace and yield one fully-resolved row per
        class name.

        Values with both static and dynamic portions - the static
        fragments are extracted by stripping out PowerShell interpolation
        syntax ($var, ${expr}, $($expr)) and examining the residue.
        Each residual fragment that looks like a valid CSS identifier
        becomes a row. Such rows carry state_modifier='<dynamic>' to
        indicate that runtime-applied modifiers were also present but
        could not be statically resolved. So 'class="nav-link$active"'
        emits one CSS_CLASS USAGE row for 'nav-link' with
        state_modifier='<dynamic>'.

        Fully-dynamic values like class="$cssClasses" yield no rows
        because no static identifier remains after stripping.

        For id attributes, the same approach applies but is more
        conservative: a row is emitted only when interpolation reduces
        to exactly ONE static identifier. Patterns like id="row-$rowId"
        leave 'row' as the only static fragment, but 'row' is not
        actually a complete id at runtime; emitting a DEFINITION for
        'row' would be misleading. So the id case requires a single
        fragment that stands alone as a valid identifier.

      The '<dynamic>' sentinel makes these rows queryable as a distinct
      bucket: WHERE state_modifier = '<dynamic>' surfaces every catalog
      entry where there are runtime-applied modifiers that cannot be
      cataloged statically.

    Known limitations:

      The populator extracts what it can resolve statically. Two known
      patterns are not currently extractable and produce reduced row
      counts on files that use them:

        STRING-VARIABLE INDIRECTION. When a class string is built into
        a variable and then injected into HTML through that variable,
        the static class names are invisible at the attribute regex's
        scan point. Example pattern in xFACts-Helpers.psm1:

            $cssClasses = "nav-link$accentClass$activeClass"
            [void]$sb.AppendLine("<a class=`"$cssClasses`">...")

        The variable assignment string contains the class name 'nav-link'
        but is not HTML-shaped, so the LooksLikeHtml heuristic skips it.
        The AppendLine string IS HTML-shaped but its class= value is
        purely $cssClasses — no static fragment to extract. Result: zero
        rows emitted for the 'nav-link' usage at this site even though
        the class is genuinely being applied at runtime.

        This is currently the dominant gap. xFACts-Helpers.psm1 catalogs
        ~25 rows; visual inspection suggests the actual count of distinct
        class usages in the file is several times higher. The cataloger
        cannot close this gap on its own — closing it requires either
        flow analysis (substantial and brittle) or a code convention
        change that keeps class strings as direct attribute values.

        FRAGMENTED ATTRIBUTE CONSTRUCTION. When an attribute value is
        split across multiple concatenated string literals, the regex
        sees an unterminated attribute and skips it. This pattern is
        rare in CC code today but possible.

      The CC File Format Standardization initiative (see
      xFACts-Documentation/Planning/CC_FileFormat_Standardization.md)
      addresses these limitations as a coding-convention issue rather
      than a parser-complexity issue. Files refactored to conform to
      the format spec produce complete extraction. Files that have not
      yet been converted produce reduced row counts on the indirection
      patterns above. The catalog itself becomes a measure of conversion
      progress as files migrate.

      In the meantime, for queries that need to assess "is this class
      used?" without considering the indirection-limited files, filter
      on file_name to exclude module files known to use the pattern,
      or accept under-counting on those specific files.

.NOTES
    File Name      : Populate-AssetRegistry-HTML.ps1
    Location       : E:\xFACts-PowerShell
    Author         : Frost Arnett Applications Team
    Version        : Tracked in dbo.System_Metadata (component: TBD)

.PARAMETER Execute
    Required to actually delete the HTML rows from Asset_Registry and
    write the new row set. Without this flag, runs in preview mode:
    parses every file, builds the row set in memory, prints summary
    statistics, but does NOT touch the database.

================================================================================
CHANGELOG
================================================================================
2026-05-02  Two follow-up fixes from second-run audit:
              (1) NEWLINE TOKEN HANDLING. The token walker was being
                  defeated by the PowerShell tokenizer's interleaving of
                  NewLine tokens between consecutive Comment tokens. Each
                  NewLine triggered a premature flush of the comment
                  block, so multi-line banners ('# ===' divider, '# TITLE',
                  '# ===' divider) were being broken up into single-line
                  blocks - none of which contained enough content for
                  banner detection to fire. Walker now skips NewLine
                  tokens entirely (they neither extend nor terminate a
                  comment block).
              (2) BACKTICK-ESCAPE RESOLUTION. The PowerShell tokenizer
                  hands the source text verbatim, so an attribute written
                  as class=`"foo`" appears in $Token.Text as the literal
                  characters c-l-a-s-s-=-backtick-quote-f-o-o-backtick-
                  quote. Without resolving these escape sequences, the
                  attribute regex (which expects real ASCII quote
                  delimiters) does not match, and rows from helper modules
                  like xFACts-Helpers.psm1 that use backtick-escaped
                  inner quotes go uncatalogued. Get-StringContent now
                  resolves the most common backtick escapes (`", `', `n,
                  `r, `t, ``) on non-here-string content before returning
                  the inner text. (Here-strings do not use backtick
                  escapes - inner quotes are literal.)
2026-05-02  Three corrections from first-run audit:
              (1) BANNER DETECTION FIX. The original implementation called
                  Get-BannerTitle on each individual Comment token, but
                  PowerShell tokenizes '#'-style banners line-by-line
                  (10-line banner = 10 separate Comment tokens, none of
                  which individually contains both an '=' divider AND a
                  title line). Result: zero banner rows generated despite
                  all CC route files having banner-style comments at the
                  top. Walker now accumulates consecutive Comment tokens
                  whose lines are sequential into a single 'comment block'
                  and runs banner detection on the aggregated text. Block
                  flushes when a non-Comment token appears, when a Comment
                  appears with a line gap from the previous, or at
                  end-of-file.
              (2) INTERPOLATION-AWARE EXTRACTION. Originally the regex
                  skipped any class/id value containing '$', which
                  excluded most HTML built by helper modules through
                  StringBuilder concatenation. Get-HtmlAttributeOccurrences
                  now strips PowerShell interpolation syntax ($var,
                  ${expr}, $($expr)) and emits rows for the static
                  fragments that remain. Such rows carry
                  state_modifier='<dynamic>' to distinguish them from
                  fully-static rows. For id attributes the logic is
                  conservative (only emits when exactly one static
                  identifier remains) to avoid spurious rows from
                  patterns like id="row-$rowId".
              (3) DOCSTRING UPDATE. Documents that parent_function is
                  intentionally NULL for HTML rows in route files (HTML
                  inside Add-PodeRoute -ScriptBlock { ... } is at script
                  scope, not inside a FunctionDefinitionAst). The
                  Phase 3 PowerShell populator will populate
                  parent_object with route info via downstream enrichment.
2026-05-02  Initial production implementation. Replaces the throwaway
            test populator at xFACts-Documentation\WorkingFiles\
            HTML_PopulatorTest.ps1. Algorithmic core preserved from
            the test populator: PowerShell AST tokenization, four-kind
            string token coverage (HereStringExpandable, HereStringLiteral,
            StringExpandable, StringLiteral), heuristic HTML detection,
            class/id regex extraction, line-offset arithmetic for
            accurate source line numbers within multi-line strings.
            Substantive additions in this version:
              (1) Integrates with xFACts-OrchestratorFunctions.ps1 -
                  uses Initialize-XFActsScript, Write-Log, Get-SqlData,
                  Invoke-SqlNonQuery for all infrastructure operations.
              (2) parent_function enrichment via AST walk. Each file's
                  FunctionDefinitionAst nodes are walked to build a
                  line-range map; emitted rows are tagged with the
                  containing function name (when applicable).
              (3) source_section enrichment via banner detection. Comment
                  tokens are scanned in source order alongside string
                  tokens. Block comments containing 5+ '=' characters
                  set the active banner title; subsequent rows in the
                  same file carry that title until superseded.
              (4) COMMENT_BANNER DEFINITION rows emitted alongside the
                  source_section enrichment, mirroring the CSS populator's
                  banner cataloging behavior.
              (5) Object_Registry FK resolution. At startup the
                  populator loads Object_Registry rows; each emitted
                  row's file_name is resolved to a registry_id and
                  written to object_registry_id. Files not registered
                  are collected and surfaced as a WARN block at end-of-run.
              (6) Universal NULL/empty consistency. Get-NullableValue
                  treats empty/whitespace-only strings as NULL.
              (7) occurrence_index post-pass. Sequential index per
                  (file_name, component_name, reference_type,
                  state_modifier) tuple.
              (8) SharedFiles list (xFACts-Helpers.psm1 by convention)
                  for scope=SHARED on rows from helper modules whose
                  HTML output is consumed by multiple page handlers.
              (9) Standardized header + CHANGELOG matching the
                  production populator pattern.
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

Initialize-XFActsScript -ScriptName 'Populate-AssetRegistry-HTML' -Execute:$Execute

$ErrorActionPreference = 'Stop'

# ============================================================================
# CONFIGURATION
# ============================================================================

$CcRoot = 'E:\xFACts-ControlCenter'
$Ps1ScanRoots = @(
    "$CcRoot\scripts\routes"
    "$CcRoot\scripts\modules"
)

# Files whose HTML output is consumed by multiple page handlers.
# Definitions and rows from these files get scope=SHARED. Currently
# xFACts-Helpers.psm1 is the only known shared HTML producer - it
# contains helper functions (Get-NavBarHtml, etc.) that build markup
# consumed by every page.
$SharedFiles = @(
    'xFACts-Helpers.psm1'
)

# Token kinds we extract HTML from. The PowerShell tokenizer classifies
# string-bearing tokens into four kinds depending on quoting style:
#   HereStringExpandable - @"..."@  (interpolated, multiline)
#   HereStringLiteral    - @'...'@  (literal, multiline)
#   StringExpandable     - "..."    (interpolated, single line)
#   StringLiteral        - '...'    (literal, single line)
# All four can carry HTML markup in CC route files.
$RelevantStringKinds = @(
    'HereStringExpandable',
    'HereStringLiteral',
    'StringExpandable',
    'StringLiteral'
)

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
# reference_type, state_modifier) tuple. Rows are processed in the
# order the walker emitted them, which matches source order.
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
# LOAD CSS_CLASS DEFINITIONS FOR SCOPE RESOLUTION
# ============================================================================
# When the HTML populator emits a CSS_CLASS USAGE row for a class
# referenced in markup, we look that class up against the CSS_CLASS
# DEFINITION rows already loaded by the CSS populator. This requires
# the CSS populator to have run first (the orchestrator wrapper will
# enforce that ordering).

Write-Log "Loading existing CSS_CLASS DEFINITION rows for scope resolution..."

$sharedClassMap = @{}
$localClassMap  = @{}

$cssDefs = Get-SqlData -Query @"
SELECT component_name, scope, file_name
FROM dbo.Asset_Registry
WHERE component_type = 'CSS_CLASS'
  AND reference_type = 'DEFINITION'
  AND file_type = 'CSS'
  AND is_active = 1;
"@

if ($null -ne $cssDefs) {
    foreach ($d in @($cssDefs)) {
        $name = $d.component_name
        if ([string]::IsNullOrEmpty($name)) { continue }
        if ($d.scope -eq 'SHARED') {
            if (-not $sharedClassMap.ContainsKey($name)) {
                $sharedClassMap[$name] = $d.file_name
            }
        }
        else {
            if (-not $localClassMap.ContainsKey($name)) {
                $localClassMap[$name] = $d.file_name
            }
        }
    }
}

Write-Log ("  Shared CSS classes:     {0}" -f $sharedClassMap.Count)
Write-Log ("  Local-only CSS classes: {0}" -f $localClassMap.Count)

if ($sharedClassMap.Count -eq 0 -and $localClassMap.Count -eq 0) {
    Write-Log "No CSS_CLASS DEFINITION rows found in Asset_Registry. CSS populator may not have run yet. All class USAGEs will resolve to <undefined>." "WARN"
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

    # Strip the comment delimiters first so we don't see '#' as content.
    # PowerShell block comments are <# ... #>; line comments are # ...
    $cleaned = $CommentText
    if ($cleaned.StartsWith('<#')) { $cleaned = $cleaned.Substring(2) }
    if ($cleaned.EndsWith('#>'))   { $cleaned = $cleaned.Substring(0, $cleaned.Length - 2) }

    $lines = $cleaned -split "`n"
    foreach ($line in $lines) {
        $trimmed = $line.Trim().Trim('#').Trim().Trim('=').Trim()
        if ($trimmed.Length -gt 0) { return $trimmed }
    }
    return $null
}

# Cheap heuristic - does this string contain content that looks like HTML?
function Test-LooksLikeHtml {
    param([string]$Text)
    if ($null -eq $Text) { return $false }
    if ($Text.Length -lt 8) { return $false }
    if ($Text -match '<\s*\w') { return $true }
    if ($Text -match '\b(class|id)\s*=') { return $true }
    return $false
}

# Extract individual class and id occurrences from HTML markup text.
# Returns one record per emittable row, with state_modifier already resolved.
#
# Records have shape:
#   @{ Kind='class'|'id'; Name='foo'; StateModifier='<dynamic>'|$null;
#      LineOffset=N; ColumnStart=N }
#
# Interpolation handling:
#   - Fully-static values (no '$') are split on whitespace and yield one
#     record per class name, with StateModifier=$null.
#   - Values containing PowerShell interpolation ($var or ${expr}) are
#     parsed by stripping out the dynamic parts and examining the static
#     fragments that remain. For each static fragment that is a valid
#     CSS identifier, we emit a record with StateModifier='<dynamic>' to
#     indicate that runtime-applied modifiers exist but cannot be
#     statically resolved.
#   - For id attributes with interpolation, we emit at most one record -
#     and only when there is exactly one valid static fragment. This
#     avoids spurious DEFINITION rows from patterns like id="row-$id"
#     where the static prefix is not itself a complete id.
function Get-HtmlAttributeOccurrences {
    param([string]$Text)
    if ($null -eq $Text) { return @() }

    $results = New-Object System.Collections.Generic.List[object]

    # class="..." | class='...' | id="..." | id='...'
    # Attribute name is captured group 1, quote is group 2, value is group 3
    $pattern = '\b(class|id)\s*=\s*(["''])([^"'']*)\2'
    $regexMatches = [regex]::Matches($Text, $pattern)

    foreach ($m in $regexMatches) {
        $attrName = $m.Groups[1].Value.ToLower()
        $value    = $m.Groups[3].Value

        # Skip empty/whitespace values
        if ([string]::IsNullOrWhiteSpace($value)) { continue }

        # Compute line/column offset of the attribute's start position
        $charIndex = $m.Index
        $textBefore = $Text.Substring(0, $charIndex)
        $lineOffset = ($textBefore -split "`n").Count - 1
        $lastNewline = $textBefore.LastIndexOf("`n")
        $columnStart = if ($lastNewline -ge 0) { $charIndex - $lastNewline } else { $charIndex + 1 }

        $hasInterpolation = ($value -match '\$')

        if (-not $hasInterpolation) {
            # Fully static path - existing behavior. Split classes on
            # whitespace, emit one record per class name. Ids emit one
            # record for the whole value.
            if ($attrName -eq 'class') {
                $names = @($value -split '\s+' | Where-Object { $_ })
                foreach ($n in $names) {
                    $results.Add([ordered]@{
                        Kind          = $attrName
                        Name          = $n
                        StateModifier = $null
                        LineOffset    = $lineOffset
                        ColumnStart   = $columnStart
                    })
                }
            }
            else {
                $results.Add([ordered]@{
                    Kind          = $attrName
                    Name          = $value
                    StateModifier = $null
                    LineOffset    = $lineOffset
                    ColumnStart   = $columnStart
                })
            }
            continue
        }

        # Interpolated path. Strip out PowerShell interpolation expressions
        # ($var, ${expr}, $($expr)) leaving only the static fragments. Note
        # the order of patterns matters - ${expr} and $($expr) must be
        # stripped before bare $var because they can contain $ inside.
        $stripped = $value
        # Strip ${...} - simple braced expression
        $stripped = [regex]::Replace($stripped, '\$\{[^}]*\}', ' ')
        # Strip $(...) - parenthesized expression. PowerShell allows nested
        # parens here in principle; the simple non-greedy form catches the
        # common cases without trying to balance brackets.
        $stripped = [regex]::Replace($stripped, '\$\([^)]*\)', ' ')
        # Strip bare $varname (alphanumeric identifier, possibly with
        # property dotted access like $obj.Property)
        $stripped = [regex]::Replace($stripped, '\$[a-zA-Z_][a-zA-Z0-9_.]*', ' ')

        # Whatever remains are the static fragments. Split on whitespace
        # and check each one for being a valid CSS-identifier shape.
        $cssIdentRegex = '^[a-zA-Z_][a-zA-Z0-9_-]*$'
        $staticFragments = @($stripped -split '\s+' |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and ($_ -match $cssIdentRegex) })

        if ($staticFragments.Count -eq 0) { continue }

        if ($attrName -eq 'class') {
            # Each static identifier becomes its own USAGE row with
            # state_modifier='<dynamic>' to mark that runtime modifiers
            # were also present.
            foreach ($frag in $staticFragments) {
                $results.Add([ordered]@{
                    Kind          = $attrName
                    Name          = $frag
                    StateModifier = '<dynamic>'
                    LineOffset    = $lineOffset
                    ColumnStart   = $columnStart
                })
            }
        }
        else {
            # id attribute - only emit when there is exactly ONE static
            # identifier. Patterns like id="row-$rowId" produce a single
            # static fragment 'row' which is misleading (the actual ids at
            # runtime are 'row-1', 'row-2', etc.) - we skip those. Only a
            # bare static id name yields a row, and it's marked dynamic
            # so it's queryable as a special case.
            if ($staticFragments.Count -eq 1) {
                $results.Add([ordered]@{
                    Kind          = $attrName
                    Name          = $staticFragments[0]
                    StateModifier = '<dynamic>'
                    LineOffset    = $lineOffset
                    ColumnStart   = $columnStart
                })
            }
        }
    }

    return $results
}

# Strip the outer wrappers from a string token's raw text and return
# the inner content along with the line number where that content
# actually starts. Here-strings have a leading newline after the @"
# wrapper that we strip and account for.
function Get-StringContent {
    param([Parameter(Mandatory)] $Token)

    $kind     = $Token.Kind
    $rawText  = $Token.Text
    $startLine = $Token.Extent.StartLineNumber
    if (-not $startLine) { $startLine = 1 }

    if ($kind -in @('HereStringExpandable','HereStringLiteral')) {
        $inner = $rawText
        if ($inner.StartsWith('@"') -or $inner.StartsWith("@'")) {
            $inner = $inner.Substring(2)
        }
        if ($inner.EndsWith('"@') -or $inner.EndsWith("'@")) {
            $inner = $inner.Substring(0, $inner.Length - 2)
        }

        # Strip the single newline that follows the @" / @' wrapper.
        # Content effectively starts on the line after the wrapper line.
        $contentStart = $startLine
        if ($inner.StartsWith("`r`n")) {
            $inner = $inner.Substring(2)
            $contentStart = $startLine + 1
        }
        elseif ($inner.StartsWith("`n")) {
            $inner = $inner.Substring(1)
            $contentStart = $startLine + 1
        }

        # Here-strings do NOT use backtick escapes - inner quotes are literal.
        return @{ Inner = $inner; ContentStartLine = $contentStart }
    }

    if ($kind -in @('StringExpandable','StringLiteral')) {
        $inner = $rawText
        if ($inner.Length -ge 2) {
            $first = $inner[0]
            $last = $inner[$inner.Length - 1]
            if (($first -eq '"' -or $first -eq "'") -and ($last -eq '"' -or $last -eq "'")) {
                $inner = $inner.Substring(1, $inner.Length - 2)
            }
        }

        # Resolve PowerShell backtick escape sequences. The tokenizer hands
        # us the source text verbatim, so an attribute like class=`"foo`"
        # appears as the literal characters: c, l, a, s, s, =, `, ", f, o,
        # o, `, ". Without resolution, the attribute regex (which expects
        # the value to be wrapped in real ASCII quote characters) does not
        # match. Resolution converts backtick-escapes to their literal
        # equivalents so attribute extraction can proceed.
        #
        # Order matters slightly: we handle the quote-pairs first, then
        # the whitespace escapes. We do NOT try to resolve every escape -
        # only the ones that affect attribute parsing. Escapes like `0
        # (null), `a (alert), etc., are extremely rare in HTML attribute
        # contexts and are passed through unchanged.
        if ($inner -match '`') {
            $inner = $inner.Replace('`"', '"').Replace("``'", "'")
            # Also handle backtick-n (newline) and backtick-t (tab) which
            # might appear inside a here-string-like usage, though uncommon.
            $inner = $inner.Replace('`n', "`n").Replace('`r', "`r").Replace('`t', "`t")
            # Backtick-backtick is the literal backtick - leaves a single
            # backtick. Apply last to avoid double-substitution.
            $inner = $inner.Replace('``', '`')
        }

        return @{ Inner = $inner; ContentStartLine = $startLine }
    }

    return $null
}

# ============================================================================
# AST WALK - BUILD FUNCTION-CONTEXT MAP
# ============================================================================
# Walk all FunctionDefinitionAst nodes once per file to build a map of
# line number ranges to function names. When emitting a row at a given
# line, we look up the most-specific (innermost) function that contains
# that line and use its name as parent_function.

function Get-FunctionContextMap {
    param([Parameter(Mandatory)] $Ast)

    $map = New-Object System.Collections.Generic.List[object]

    if ($null -eq $Ast) { return ,$map }

    # Find every FunctionDefinitionAst, regardless of nesting depth
    $functionNodes = $Ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $true)

    foreach ($fn in $functionNodes) {
        $map.Add([ordered]@{
            Name      = $fn.Name
            StartLine = $fn.Extent.StartLineNumber
            EndLine   = $fn.Extent.EndLineNumber
            BodyDepth = $fn.Extent.EndLineNumber - $fn.Extent.StartLineNumber
        })
    }

    return ,$map
}

# Look up the innermost function containing the given line number.
# Returns the function name, or $null if the line is at script scope.
# Innermost = the function with the smallest line range that still
# contains the line. This handles nested functions correctly.
function Resolve-FunctionContext {
    param(
        $Map,
        [Parameter(Mandatory)] [int]$Line
    )

    if ($null -eq $Map -or $Map.Count -eq 0) { return $null }

    $best = $null
    $bestRange = [int]::MaxValue

    foreach ($entry in $Map) {
        if ($entry.StartLine -le $Line -and $entry.EndLine -ge $Line) {
            $range = $entry.EndLine - $entry.StartLine
            if ($range -lt $bestRange) {
                $bestRange = $range
                $best = $entry.Name
            }
        }
    }

    return $best
}

# ============================================================================
# ROW BUILDERS
# ============================================================================

function Resolve-CssClassScope {
    param([string]$ClassName)
    if ($script:sharedClassMap.ContainsKey($ClassName)) {
        return @{ Scope = 'SHARED'; SourceFile = $script:sharedClassMap[$ClassName] }
    }
    if ($script:localClassMap.ContainsKey($ClassName)) {
        return @{ Scope = 'LOCAL'; SourceFile = $script:localClassMap[$ClassName] }
    }
    return @{ Scope = 'LOCAL'; SourceFile = '<undefined>' }
}

function Add-HtmlIdRow {
    param(
        [string]$FileName,
        [bool]$FileIsShared,
        [string]$IdValue,
        [string]$StateModifier,
        [int]$LineStart,
        [int]$ColumnStart,
        [string]$ParentFunction,
        [string]$SourceSection
    )

    if ([string]::IsNullOrWhiteSpace($IdValue)) { return }

    $modKey = if ($StateModifier) { $StateModifier } else { '' }
    $key = "$FileName|$LineStart|$ColumnStart|HTML_ID|$IdValue|DEFINITION|$modKey"
    if (-not (Test-AddDedupeKey -Key $key)) { return }

    $scope = if ($FileIsShared) { 'SHARED' } else { 'LOCAL' }
    $signature = "id=`"$IdValue`""

    $script:rows.Add([ordered]@{
        FileName        = $FileName
        FileType        = 'HTML'
        LineStart       = $LineStart
        LineEnd         = $LineStart
        ColumnStart     = $ColumnStart
        ComponentType   = 'HTML_ID'
        ComponentName   = $IdValue
        StateModifier   = $StateModifier
        ReferenceType   = 'DEFINITION'
        Scope           = $scope
        SourceFile      = $FileName
        SourceSection   = $SourceSection
        Signature       = $signature
        ParentFunction  = $ParentFunction
        ParentObject    = $null
        RawText         = $signature
        OccurrenceIndex = 1
    })
}

function Add-CssClassUsageRow {
    param(
        [string]$FileName,
        [string]$ClassName,
        [string]$StateModifier,
        [int]$LineStart,
        [int]$ColumnStart,
        [string]$ParentFunction,
        [string]$SourceSection
    )

    if ([string]::IsNullOrWhiteSpace($ClassName)) { return }

    $modKey = if ($StateModifier) { $StateModifier } else { '' }
    $key = "$FileName|$LineStart|$ColumnStart|CSS_CLASS|$ClassName|USAGE|$modKey"
    if (-not (Test-AddDedupeKey -Key $key)) { return }

    $resolved = Resolve-CssClassScope -ClassName $ClassName
    # Signature shows the class name plus a dynamic indicator when modifiers
    # were not statically resolvable.
    $signature = if ($StateModifier -eq '<dynamic>') {
        "class=`"$ClassName <dynamic>`""
    }
    else {
        "class=`"$ClassName`""
    }

    $script:rows.Add([ordered]@{
        FileName        = $FileName
        FileType        = 'HTML'
        LineStart       = $LineStart
        LineEnd         = $LineStart
        ColumnStart     = $ColumnStart
        ComponentType   = 'CSS_CLASS'
        ComponentName   = $ClassName
        StateModifier   = $StateModifier
        ReferenceType   = 'USAGE'
        Scope           = $resolved.Scope
        SourceFile      = $resolved.SourceFile
        SourceSection   = $SourceSection
        Signature       = $signature
        ParentFunction  = $ParentFunction
        ParentObject    = $null
        RawText         = $signature
        OccurrenceIndex = 1
    })
}

function Add-CommentBannerRow {
    param(
        [string]$FileName,
        [bool]$FileIsShared,
        [string]$Title,
        [int]$LineStart,
        [int]$LineEnd,
        [int]$ColumnStart,
        [string]$RawText,
        [string]$ParentFunction
    )

    if ([string]::IsNullOrWhiteSpace($Title)) { return }

    $key = "$FileName|$LineStart|COMMENT_BANNER|$Title|DEFINITION|"
    if (-not (Test-AddDedupeKey -Key $key)) { return }

    $scope = if ($FileIsShared) { 'SHARED' } else { 'LOCAL' }

    $script:rows.Add([ordered]@{
        FileName        = $FileName
        FileType        = 'HTML'
        LineStart       = $LineStart
        LineEnd         = $LineEnd
        ColumnStart     = $ColumnStart
        ComponentType   = 'COMMENT_BANNER'
        ComponentName   = $Title
        StateModifier   = $null
        ReferenceType   = 'DEFINITION'
        Scope           = $scope
        SourceFile      = $FileName
        SourceSection   = $null   # banners themselves don't carry parent banner
        Signature       = $null
        ParentFunction  = $ParentFunction
        ParentObject    = $null
        RawText         = $RawText
        OccurrenceIndex = 1
    })
}

# ============================================================================
# PER-FILE PROCESSING
# ============================================================================

function Invoke-FileExtraction {
    param(
        [Parameter(Mandatory)] [string]$FilePath,
        [Parameter(Mandatory)] [bool]$IsShared
    )

    $name = [System.IO.Path]::GetFileName($FilePath)
    $startCount = $script:rows.Count

    $tokens = $null
    $errors = $null
    $ast = $null

    try {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $FilePath, [ref]$tokens, [ref]$errors
        )
    }
    catch {
        Write-Log "  Parse failed for ${name}: $($_.Exception.Message)" "ERROR"
        return 0
    }

    if ($null -eq $tokens) {
        Write-Log "  No tokens returned for $name (empty file?)" "WARN"
        return 0
    }

    # Build the function-context map for parent_function enrichment
    $fnMap = Get-FunctionContextMap -Ast $ast

    # Walk tokens in source order. The walker handles two intertwined concerns:
    #
    #   (1) Banner detection. PowerShell's tokenizer emits each line of a
    #       '#'-prefixed comment as its own Comment token. A multi-line
    #       banner like:
    #         # ============================
    #         # SECTION TITLE
    #         # ============================
    #       is therefore three separate tokens, none of which individually
    #       contain both an '=' divider and a title line. To detect the
    #       banner we accumulate consecutive Comment tokens whose lines are
    #       contiguous, then run Get-BannerTitle against the aggregated
    #       text. The aggregated banner produces a single COMMENT_BANNER
    #       row using the first comment's start line as the banner's
    #       location and updates source_section state for subsequent rows.
    #
    #   (2) String content extraction. String-bearing tokens are run
    #       through HTML extraction. Each row gets the active banner title
    #       in source_section.
    #
    # The block-accumulation logic uses Flush-CommentBlock as a local helper
    # closure pattern via repeated inline blocks (PowerShell 5.1 has limited
    # closure semantics; an explicit local function would close over the
    # script:rows variable but not the iteration-local state cleanly).

    $activeBanner = $null
    $commentBlock = New-Object System.Collections.Generic.List[object]

    foreach ($tok in $tokens) {
        $kind = $tok.Kind

        # NewLine tokens are transparent - they appear between consecutive
        # Comment tokens (PowerShell tokenizes # comments line-by-line) and
        # if we treated them as block-terminating non-Comment tokens, we
        # would split a single banner block into many one-line "blocks",
        # none of which contain enough content to match both an '=' divider
        # AND a title line. So NewLine tokens are skipped entirely - they
        # neither extend the current comment block nor trigger a flush.
        if ($kind -eq 'NewLine') { continue }

        # ---- Accumulate or flush the comment block --------------------
        if ($kind -eq 'Comment') {
            # Continue the current block if this comment starts on the
            # line immediately after the previous one ended; otherwise
            # flush and start a new block.
            $continues = $false
            if ($commentBlock.Count -gt 0) {
                $prev = $commentBlock[$commentBlock.Count - 1]
                if (($tok.Extent.StartLineNumber - $prev.Extent.EndLineNumber) -le 1) {
                    $continues = $true
                }
            }

            if (-not $continues -and $commentBlock.Count -gt 0) {
                # Flush the current block as a potential banner
                $aggText = ($commentBlock | ForEach-Object { $_.Text }) -join "`n"
                $title = Get-BannerTitle -CommentText $aggText
                if ($title) {
                    $first = $commentBlock[0]
                    $last  = $commentBlock[$commentBlock.Count - 1]
                    $cLine    = $first.Extent.StartLineNumber
                    $cEndLine = $last.Extent.EndLineNumber
                    $cCol     = $first.Extent.StartColumnNumber
                    if (-not $cCol) { $cCol = 1 }

                    $rawSnippet = Format-SingleLine -Text $aggText
                    $fnAtBanner = Resolve-FunctionContext -Map $fnMap -Line $cLine

                    Add-CommentBannerRow -FileName $name -FileIsShared $IsShared `
                        -Title $title -LineStart $cLine -LineEnd $cEndLine `
                        -ColumnStart $cCol -RawText $rawSnippet `
                        -ParentFunction $fnAtBanner

                    $activeBanner = $title
                }
                $commentBlock = New-Object System.Collections.Generic.List[object]
            }

            $commentBlock.Add($tok)
            continue
        }

        # Non-comment, non-newline token. If a comment block is pending,
        # flush it now.
        if ($commentBlock.Count -gt 0) {
            $aggText = ($commentBlock | ForEach-Object { $_.Text }) -join "`n"
            $title = Get-BannerTitle -CommentText $aggText
            if ($title) {
                $first = $commentBlock[0]
                $last  = $commentBlock[$commentBlock.Count - 1]
                $cLine    = $first.Extent.StartLineNumber
                $cEndLine = $last.Extent.EndLineNumber
                $cCol     = $first.Extent.StartColumnNumber
                if (-not $cCol) { $cCol = 1 }

                $rawSnippet = Format-SingleLine -Text $aggText
                $fnAtBanner = Resolve-FunctionContext -Map $fnMap -Line $cLine

                Add-CommentBannerRow -FileName $name -FileIsShared $IsShared `
                    -Title $title -LineStart $cLine -LineEnd $cEndLine `
                    -ColumnStart $cCol -RawText $rawSnippet `
                    -ParentFunction $fnAtBanner

                $activeBanner = $title
            }
            $commentBlock = New-Object System.Collections.Generic.List[object]
        }

        # ---- String-bearing tokens -> HTML extraction -----------------
        if ($kind -notin $script:RelevantStringKinds) { continue }

        $content = Get-StringContent -Token $tok
        if ($null -eq $content) { continue }
        $inner        = $content.Inner
        $contentStart = $content.ContentStartLine

        if (-not (Test-LooksLikeHtml -Text $inner)) { continue }


        $occurrences = Get-HtmlAttributeOccurrences -Text $inner
        if ($occurrences.Count -eq 0) { continue }

        foreach ($occ in $occurrences) {
            $sourceLine = $contentStart + $occ.LineOffset
            $fnAtRow = Resolve-FunctionContext -Map $fnMap -Line $sourceLine

            if ($occ.Kind -eq 'id') {
                Add-HtmlIdRow -FileName $name -FileIsShared $IsShared `
                    -IdValue $occ.Name -StateModifier $occ.StateModifier `
                    -LineStart $sourceLine -ColumnStart $occ.ColumnStart `
                    -ParentFunction $fnAtRow -SourceSection $activeBanner
            }
            else {
                Add-CssClassUsageRow -FileName $name -ClassName $occ.Name `
                    -StateModifier $occ.StateModifier `
                    -LineStart $sourceLine -ColumnStart $occ.ColumnStart `
                    -ParentFunction $fnAtRow -SourceSection $activeBanner
            }
        }
    }

    # End-of-file flush: if the file ends with a pending comment block,
    # run banner detection on it before returning.
    if ($commentBlock.Count -gt 0) {
        $aggText = ($commentBlock | ForEach-Object { $_.Text }) -join "`n"
        $title = Get-BannerTitle -CommentText $aggText
        if ($title) {
            $first = $commentBlock[0]
            $last  = $commentBlock[$commentBlock.Count - 1]
            $cLine    = $first.Extent.StartLineNumber
            $cEndLine = $last.Extent.EndLineNumber
            $cCol     = $first.Extent.StartColumnNumber
            if (-not $cCol) { $cCol = 1 }

            $rawSnippet = Format-SingleLine -Text $aggText
            $fnAtBanner = Resolve-FunctionContext -Map $fnMap -Line $cLine

            Add-CommentBannerRow -FileName $name -FileIsShared $IsShared `
                -Title $title -LineStart $cLine -LineEnd $cEndLine `
                -ColumnStart $cCol -RawText $rawSnippet `
                -ParentFunction $fnAtBanner
        }
    }

    return ($script:rows.Count - $startCount)
}

# ============================================================================
# DISCOVERY AND WALK
# ============================================================================

Write-Log "Discovering .ps1/.psm1 files in scan roots..."

$Ps1Files = New-Object System.Collections.Generic.List[string]
foreach ($root in $Ps1ScanRoots) {
    if (-not (Test-Path $root)) {
        Write-Log "Scan root not found, skipping: $root" "WARN"
        continue
    }
    $found = @(Get-ChildItem -Path $root -Filter '*.ps1' -Recurse -File |
                 Select-Object -ExpandProperty FullName)
    foreach ($f in $found) { [void]$Ps1Files.Add($f) }

    $foundPsm1 = @(Get-ChildItem -Path $root -Filter '*.psm1' -Recurse -File |
                     Select-Object -ExpandProperty FullName)
    foreach ($f in $foundPsm1) { [void]$Ps1Files.Add($f) }
}
Write-Log "Discovered $($Ps1Files.Count) .ps1/.psm1 files to scan"

Write-Log "Walking files and extracting HTML rows..."

foreach ($file in $Ps1Files) {
    $name = [System.IO.Path]::GetFileName($file)
    $isShared = $SharedFiles -contains $name
    $scopeLabel = if ($isShared) { 'SHARED' } else { 'LOCAL' }

    Write-Host ("  Walking {0} ({1})..." -f $name, $scopeLabel) -ForegroundColor Cyan

    $delta = Invoke-FileExtraction -FilePath $file -IsShared $isShared
    if ($delta -gt 0) {
        Write-Host ("    -> {0} rows" -f $delta) -ForegroundColor Green
    }
    else {
        Write-Host ("    -> 0 rows (no HTML found)") -ForegroundColor DarkGray
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
}

# ============================================================================
# DATABASE WRITE
# ============================================================================

if (-not $Execute) {
    Write-Log "PREVIEW MODE - no rows written to Asset_Registry. Use -Execute to insert." "WARN"
    return
}

Write-Log "Clearing existing HTML rows from Asset_Registry..."
$cleared = Invoke-SqlNonQuery -Query "DELETE FROM dbo.Asset_Registry WHERE file_type = 'HTML';"
if (-not $cleared) {
    Write-Log "Failed to clear existing HTML rows. Aborting." "ERROR"
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
WHERE file_type = 'HTML'
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
<#
.SYNOPSIS
    xFACts - Shared Asset Registry Population Functions

.DESCRIPTION
    xFACts - ControlCenter.AssetRegistry
    Script: xFACts-AssetRegistryFunctions.ps1
    Version: Tracked in dbo.System_Metadata (component: ControlCenter.AssetRegistry)

    Common functions used by the Asset Registry populator family
    (Populate-AssetRegistry-CSS.ps1, Populate-AssetRegistry-HTML.ps1,
    Populate-AssetRegistry-JS.ps1, and the future PS populator).

    Centralizes:
    - Row construction and bulk-insert plumbing
    - Drift code attachment (master-table-validated, with optional context)
    - Banner detection and parsing (parameterized for valid section types)
    - File-header parsing
    - Section list construction and line lookup
    - Object_Registry / Component_Registry loads
    - Comment-text cleanup
    - Generic AST visitor walker

    Per-language logic (visitor scriptblock body, per-row emitters, selector
    decomposition, variant shape helpers, HTML attribute extraction, AST
    parent-context helpers) stays in each populator.

    Comment-shape contract: Get-FileHeaderInfo and New-SectionList accept
    a normalized comment-object shape with these fields:
        .Type      - 'Block' for block comments (the only kind cataloged)
        .Text      - inner text of the comment, with /* */ delimiters stripped
        .LineStart - 1-based source line of the opening delimiter
        .LineEnd   - 1-based source line of the closing delimiter
    The acorn JS AST already produces objects close to this shape (.type,
    .value, .loc.start.line, .loc.end.line); the JS populator wraps each
    comment to the normalized shape before calling these helpers. PostCSS
    produces a different shape (.type='comment', .text, .source.start.line);
    the CSS populator wraps similarly. The wrapping is a one-shot adapter
    in each populator; helpers see only the normalized shape.

    Dot-source AFTER xFACts-OrchestratorFunctions.ps1 at the top of each
    populator:
        . "$PSScriptRoot\xFACts-OrchestratorFunctions.ps1"
        . "$PSScriptRoot\xFACts-AssetRegistryFunctions.ps1"
        Initialize-XFActsScript -ScriptName 'Populate-AssetRegistry-XXX' -Execute:$Execute

    CHANGELOG
    ---------
    2026-05-07  Banner detection split into permissive detector + strict
                validator. Test-IsBannerComment now returns $true for any
                comment whose shape suggests an intended section banner
                (rule lines of '=' or '-', or single-line '===== Title ====='
                form), regardless of whether the title line uses a recognized
                TYPE token. Get-BannerInfo emits granular drift codes per
                spec rule violated rather than the previous catch-all
                MALFORMED_SECTION_BANNER.
                  New codes:
                    BANNER_INLINE_SHAPE
                    BANNER_INVALID_RULE_CHAR
                    BANNER_INVALID_RULE_LENGTH
                    BANNER_INVALID_SEPARATOR_CHAR
                    BANNER_INVALID_SEPARATOR_LENGTH
                    BANNER_MALFORMED_TITLE_LINE
                    BANNER_MISSING_DESCRIPTION
                  UNKNOWN_SECTION_TYPE (existing) now emitted when title
                  line shape is correct but the TYPE token is not in the
                  closed enum. MISSING_PREFIX_DECLARATION unchanged.
                  Retired: MALFORMED_SECTION_BANNER (granular codes
                  replace it). Restores catalog visibility for the ~260
                  non-conforming banners across unrefactored files that
                  the strict gate was rejecting outright.
    2026-05-07  Bug fixes from first run.
                - Get-ObjectRegistryMap and Get-ComponentRegistryPrefixMap
                  now use the authoritative column names from Object_Registry's
                  DDL JSON: object_type (not file_type) and registry_id (not
                  object_registry_id). The populator-facing -FileType param
                  is preserved as a short alias and translated to the spec's
                  full object_type string ('JavaScript' for JS, 'Script' for
                  PS, 'CSS' / 'HTML' for the others).
                - Invoke-AssetRegistryBulkInsert's $Misses parameter now
                  accepts an empty HashSet via [AllowEmptyCollection()] so
                  the bulk insert step works on the first run, before any
                  Object_Registry misses have accumulated.
    2026-05-07  Comment-shape contract formalized. Get-FileHeaderInfo and
                New-SectionList now read normalized .Type/.Text/.LineStart/
                .LineEnd fields rather than acorn's .type/.value/.loc.start.
                Each populator wraps language-specific comment objects into
                the normalized shape before calling these helpers. Added
                'selectorTree' to Invoke-AstWalk's skip list so the walker
                does not descend into PostCSS's decomposed-selector subtree.
    2026-05-06  Initial implementation. Extracted shared logic from
                Populate-AssetRegistry-CSS.ps1 and Populate-AssetRegistry-JS.ps1
                as part of the populator alignment pass. Adopted JS visitor
                pattern, JS pre-built section list model, and a hybrid drift
                attachment model (master-table validation + optional context
                string). Added Get-ComponentRegistryPrefixMap for the
                Component_Registry / cc_prefix join used by the prefix
                registry validation work.

================================================================================
#>


# ============================================================================
# ROW CONSTRUCTION
# ============================================================================

# Standardized Asset_Registry row builder. Returns an ordered hashtable with
# every column the bulk-insert DataTable expects. Callers populate the
# language-specific fields and pass the row through Add-DriftCode and the
# bulk-insert pipeline. FileType is required because the row shape is shared
# across CSS / HTML / JS / PS populators.
function New-AssetRegistryRow {
    param(
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][ValidateSet('CSS','HTML','JS','PS')][string]$FileType,
        [int]$LineStart = 1,
        [int]$LineEnd = 0,
        [int]$ColumnStart = 0,
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
        FileType           = $FileType
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


# ============================================================================
# DEDUPE TRACKING
# ============================================================================

# Test whether a dedupe key is new, adding it to the tracker on first sight.
# Returns $true if the key was added (i.e., the row is new), $false if the key
# was already present (caller should skip emission). The tracker itself lives
# on the calling script as $script:dedupeKeys (HashSet[string]). Callers
# initialize it once at the top of the populator:
#   $script:dedupeKeys = New-Object System.Collections.Generic.HashSet[string]
function Test-AddDedupeKey {
    param([Parameter(Mandatory)][string]$Key)
    return $script:dedupeKeys.Add($Key)
}


# ============================================================================
# DRIFT CODE ATTACHMENT
# ============================================================================

# Attach a drift code to a row using the hybrid model:
#   - Code is validated against the populator's master $script:DriftDescriptions
#     ordered hashtable. Unknown codes are refused with a warning.
#   - drift_codes column accumulates comma-separated codes (deduped).
#   - drift_text column accumulates pipe-separated descriptions. The default
#     description comes from $script:DriftDescriptions[$Code]; callers can
#     override with the optional -Context parameter to add row-specific detail
#     (e.g. "Function 'bkp_loadData' does not start with section prefix 'bkp_'").
#
# Idempotent on the code: attaching the same code twice is a no-op (the
# description is not appended a second time either).
function Add-DriftCode {
    param(
        [Parameter(Mandatory)]$Row,
        [Parameter(Mandatory)][string]$Code,
        [string]$Context
    )

    if ([string]::IsNullOrEmpty($Code)) { return }

    if (-not $script:DriftDescriptions.Contains($Code)) {
        Write-Log "Add-DriftCode: unknown drift code '$Code' -- refusing to attach." 'WARN'
        return
    }

    # Codes column: dedupe before appending
    $existing = if ($Row.DriftCodes) { @($Row.DriftCodes -split ',\s*') } else { @() }
    if ($existing -contains $Code) { return }

    $existing = @($existing) + $Code
    $Row.DriftCodes = ($existing -join ', ')

    # Text column: prefer caller-supplied context, fall back to master description
    $appendText = if ([string]::IsNullOrWhiteSpace($Context)) {
        $script:DriftDescriptions[$Code]
    } else {
        $Context
    }

    if ([string]::IsNullOrEmpty($Row.DriftText)) {
        $Row.DriftText = $appendText
    } else {
        $Row.DriftText = "$($Row.DriftText) | $appendText"
    }
}

# Output-boundary check: scan a row collection for drift codes that are not
# in the master $script:DriftDescriptions table. Catches typos and stale codes
# that would otherwise reach the catalog as unmatched mystery values. Logs a
# WARN with the offending code and file_name. Run this just before the bulk
# insert.
function Test-DriftCodesAgainstMasterTable {
    param([Parameter(Mandatory)]$Rows)

    $unknown = New-Object System.Collections.Generic.HashSet[string]
    foreach ($r in $Rows) {
        if ([string]::IsNullOrEmpty($r.DriftCodes)) { continue }
        foreach ($code in ($r.DriftCodes -split ',\s*')) {
            if ([string]::IsNullOrEmpty($code)) { continue }
            if (-not $script:DriftDescriptions.Contains($code)) {
                $key = "$code|$($r.FileName)"
                if ($unknown.Add($key)) {
                    Write-Log "Drift code '$code' not in master table (file: $($r.FileName))." 'WARN'
                }
            }
        }
    }
}


# ============================================================================
# OCCURRENCE INDEX COMPUTATION
# ============================================================================

# Compute occurrence_index per (file_name, component_name, reference_type,
# variant_type, variant_qualifier_1, variant_qualifier_2) tuple. Run once
# after all per-file rows are collected, before the bulk insert. The fuller
# tuple (including variant columns) is correct for both CSS and JS - JS rows
# without variant columns will have empty strings for those parts of the key,
# which behaves identically to the simpler key.
function Set-OccurrenceIndices {
    param([Parameter(Mandatory)][System.Collections.Generic.List[object]]$Rows)

    $counters = @{}
    foreach ($r in $Rows) {
        $cn = if ($r.ComponentName)      { $r.ComponentName }      else { '' }
        $vt = if ($r.VariantType)        { $r.VariantType }        else { '' }
        $q1 = if ($r.VariantQualifier1)  { $r.VariantQualifier1 }  else { '' }
        $q2 = if ($r.VariantQualifier2)  { $r.VariantQualifier2 }  else { '' }
        $key = "$($r.FileName)|$cn|$($r.ReferenceType)|$vt|$q1|$q2"
        if (-not $counters.ContainsKey($key)) { $counters[$key] = 0 }
        $counters[$key]++
        $r.OccurrenceIndex = $counters[$key]
    }
}


# ============================================================================
# REGISTRY LOADS
# ============================================================================

# Build a (file_name -> registry_id) map from dbo.Object_Registry.
# Filters by object_type and is_active = 1. Used at the bulk-insert step
# to populate Asset_Registry.object_registry_id; misses are tracked
# separately and reported as advisories so the operator knows which files
# to add to Object_Registry.
#
# The -FileType parameter is the populator-facing alias (CSS/HTML/JS/PS).
# Object_Registry classifies files via object_type using the spec's full
# names: 'CSS' for CSS, 'HTML' for HTML, 'JavaScript' for JS, 'Script' for
# PowerShell. The mapping happens here so each populator can pass its
# native short alias.
function Get-ObjectRegistryMap {
    param(
        [Parameter(Mandatory)][string]$ServerInstance,
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][ValidateSet('CSS','HTML','JS','PS')][string]$FileType
    )

    $objectType = switch ($FileType) {
        'CSS'  { 'CSS' }
        'HTML' { 'HTML' }
        'JS'   { 'JavaScript' }
        'PS'   { 'Script' }
    }

    $query = @"
SELECT object_name, registry_id
FROM dbo.Object_Registry
WHERE object_type = '$objectType'
  AND is_active = 1
"@

    $map = @{}
    try {
        $results = Invoke-Sqlcmd -ServerInstance $ServerInstance -Database $Database `
                                 -Query $query -QueryTimeout 30 `
                                 -ApplicationName $script:XFActsAppName `
                                 -ErrorAction Stop `
                                 -SuppressProviderContextWarning -TrustServerCertificate
        foreach ($row in $results) {
            $map[$row.object_name] = [int]$row.registry_id
        }
    }
    catch {
        Write-Log "Get-ObjectRegistryMap query failed: $($_.Exception.Message)" 'WARN'
    }

    return $map
}

# Build a (file_name -> cc_prefix) map by joining dbo.Object_Registry to
# dbo.Component_Registry on component_name, filtered to a single object_type
# (translated from the populator's FileType alias). Files whose component
# has cc_prefix = NULL are included with $null as the value. Files not in
# Object_Registry are absent from the map (callers detect this via .ContainsKey()).
#
# Used by the prefix registry validation work: every page-file banner declares
# a Prefix value, which is validated against this map's value for the file.
# The (none) sentinel is always accepted regardless of the registry value.
function Get-ComponentRegistryPrefixMap {
    param(
        [Parameter(Mandatory)][string]$ServerInstance,
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][ValidateSet('CSS','HTML','JS','PS')][string]$FileType
    )

    $objectType = switch ($FileType) {
        'CSS'  { 'CSS' }
        'HTML' { 'HTML' }
        'JS'   { 'JavaScript' }
        'PS'   { 'Script' }
    }

    $query = @"
SELECT o.object_name, c.cc_prefix
FROM dbo.Object_Registry o
JOIN dbo.Component_Registry c
  ON o.component_name = c.component_name
WHERE o.object_type = '$objectType'
  AND o.is_active = 1
"@

    $map = @{}
    try {
        $results = Invoke-Sqlcmd -ServerInstance $ServerInstance -Database $Database `
                                 -Query $query -QueryTimeout 30 `
                                 -ApplicationName $script:XFActsAppName `
                                 -ErrorAction Stop `
                                 -SuppressProviderContextWarning -TrustServerCertificate
        foreach ($row in $results) {
            $val = if ($row.cc_prefix -is [System.DBNull]) { $null } else { [string]$row.cc_prefix }
            $map[$row.object_name] = $val
        }
    }
    catch {
        Write-Log "Get-ComponentRegistryPrefixMap query failed: $($_.Exception.Message)" 'WARN'
    }

    return $map
}


# ============================================================================
# BULK INSERT
# ============================================================================

# Build the Asset_Registry DataTable from a row collection and bulk-insert it
# into dbo.Asset_Registry via SqlBulkCopy. Returns the inserted row count on
# success. Throws on failure (caller decides whether to exit or continue).
#
# The DataTable schema mirrors dbo.Asset_Registry as of the file-format
# initiative. Cell values pass through Get-NullableValue to convert empty
# strings to DBNull. Files not in Object_Registry get DBNull for
# object_registry_id; the missing file_names are accumulated in the
# -Misses HashSet for the caller to surface as an advisory.
function Invoke-AssetRegistryBulkInsert {
    param(
        [Parameter(Mandatory)][string]$ServerInstance,
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][System.Collections.Generic.List[object]]$Rows,
        [Parameter(Mandatory)]$ObjectRegistryMap,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.HashSet[string]]$Misses
    )

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

    foreach ($r in $Rows) {
        $row = $dt.NewRow()
        $row['file_name'] = $r.FileName

        if ($ObjectRegistryMap.ContainsKey($r.FileName)) {
            $row['object_registry_id'] = [int]$ObjectRegistryMap[$r.FileName]
        } else {
            $row['object_registry_id'] = [System.DBNull]::Value
            [void]$Misses.Add($r.FileName)
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

    $connectionString = "Server=$ServerInstance;Database=$Database;Integrated Security=True;TrustServerCertificate=True;Application Name=$($script:XFActsAppName)"
    $conn = New-Object System.Data.SqlClient.SqlConnection $connectionString
    $conn.Open()
    try {
        $bcp = New-Object System.Data.SqlClient.SqlBulkCopy($conn)
        $bcp.DestinationTableName = 'dbo.Asset_Registry'
        $bcp.BatchSize = 500
        foreach ($col in $dt.Columns) {
            [void]$bcp.ColumnMappings.Add($col.ColumnName, $col.ColumnName)
        }
        $bcp.WriteToServer($dt)
    }
    finally {
        $conn.Close()
    }

    return $Rows.Count
}

# Convert a value to a DBNull-aware DataTable cell value. Empty/whitespace
# strings collapse to NULL. No length truncation: oversized values surface
# as a SQL error, which is the correct behavior under spec v1.2's column-
# width review.
function Get-NullableValue {
    param($Value)
    if ($null -eq $Value) { return [System.DBNull]::Value }
    if ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value)) {
        return [System.DBNull]::Value
    }
    return $Value
}


# ============================================================================
# COMMENT TEXT CLEANUP
# ============================================================================

# Normalize a block-comment payload for storage as purpose_description or
# COMMENT_BANNER raw text. Strips leading whitespace and JSDoc-style leading
# asterisks, drops banner-rule lines (5+ '=' or '-' only), trims boundary
# blanks, and compacts intermediate blank-line runs to single blanks. Returns
# $null for empty/whitespace-only input.
function ConvertTo-CleanCommentText {
    param([string]$CommentText)

    if ($null -eq $CommentText) { return $null }

    $crlf = "`r`n"; $cr = "`r"
    $normalized = $CommentText -replace $crlf, "`n" -replace $cr, "`n"
    $lines = $normalized -split "`n"

    $cleaned = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        $stripped = $line -replace '^\s*\*\s?', '' -replace '^\s+', ''
        $stripped = $stripped.TrimEnd()

        if ($stripped -match '^[=]{5,}\s*$') { continue }
        if ($stripped -match '^[-]{5,}\s*$') { continue }

        $cleaned.Add($stripped)
    }

    while ($cleaned.Count -gt 0 -and [string]::IsNullOrWhiteSpace($cleaned[0])) {
        $cleaned.RemoveAt(0)
    }
    while ($cleaned.Count -gt 0 -and [string]::IsNullOrWhiteSpace($cleaned[$cleaned.Count - 1])) {
        $cleaned.RemoveAt($cleaned.Count - 1)
    }

    if ($cleaned.Count -eq 0) { return $null }

    # Compact runs of blank lines to a single blank
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


# ============================================================================
# BANNER DETECTION & PARSING
# ============================================================================

# Cheap pre-check: does this comment look like a section banner? A banner
# contains at least one rule line of 5+ '=' AND a TYPE: NAME line where TYPE
# is in -ValidSectionTypes. File headers also have rule lines, so they're
# explicitly disqualified by the Location/Version/identity-line guards.
# Used by the section-walker to find banners without paying the cost of full
# parsing.
function Test-IsBannerComment {
    param(
        [string]$CommentText,
        [Parameter(Mandatory)][string[]]$ValidSectionTypes
    )

    if ($null -eq $CommentText) { return $false }

    # Permissive detector: admit anything that LOOKS like an intended
    # section banner. Strict spec validation runs separately in
    # Get-BannerInfo and emits granular drift codes per rule violated.
    # The goal is "any banner-shaped comment becomes a catalog row" so
    # that drift is visible; it is not "only spec-conformant banners
    # become rows".
    #
    # Three accepted shapes:
    #   1. Multi-line block with a rule-line of >=5 '=' characters
    #   2. Multi-line block with a rule-line of >=5 '-' characters
    #      (legacy convention, still appears in some files)
    #   3. Single-line inline form: ===== Title =====
    #      (common in docs-* files; gets flagged downstream)

    # File-header disqualifications (these comment shapes should never
    # be misread as banners regardless of their internal punctuation)
    if ($CommentText -match 'Location\s*:\s*[A-Za-z]:[\\/]' -or
        $CommentText -match 'Version\s*:\s*Tracked in dbo\.System_Metadata' -or
        $CommentText -match 'xFACts Control Center\s*-\s*[^=]+\(.+\.[a-z]+\)') {
        return $false
    }

    $crlf = "`r`n"; $cr = "`r"
    $normalized = $CommentText -replace $crlf, "`n" -replace $cr, "`n"
    $rawLines   = $normalized -split "`n"

    # Strip per-line leading whitespace and JSDoc-style asterisks
    $lines = @()
    foreach ($l in $rawLines) {
        $stripped = $l -replace '^\s*\*\s?', '' -replace '^\s+', ''
        $lines += $stripped.TrimEnd()
    }

    # Filter out leading/trailing blank lines for shape analysis
    $first = 0
    while ($first -lt $lines.Count -and [string]::IsNullOrWhiteSpace($lines[$first])) { $first++ }
    $last  = $lines.Count - 1
    while ($last -ge 0 -and [string]::IsNullOrWhiteSpace($lines[$last])) { $last-- }
    if ($last -lt $first) { return $false }

    $effective = @()
    for ($i = $first; $i -le $last; $i++) { $effective += $lines[$i] }

    # Shape 3: single effective line of inline form ===== Title =====
    if ($effective.Count -eq 1) {
        if ($effective[0] -match '^={3,}\s+\S.*\s+={3,}$') { return $true }
        return $false
    }

    # Shapes 1 & 2: multi-line block with at least one rule-line.
    # A rule-line is a line consisting solely of '=' (>=5) or '-' (>=5).
    foreach ($line in $effective) {
        if ($line -match '^={5,}\s*$') { return $true }
        if ($line -match '^-{5,}\s*$') { return $true }
    }

    return $false
}

# Parse a section banner comment into its structural fields. Returns an
# ordered hashtable:
#   TypeName    - section type (FOUNDATION, CHROME, LAYOUT, etc.) or $null.
#                 Set only when the title line shape is correct AND the
#                 token is in -ValidSectionTypes. Otherwise $null and the
#                 BannerName carries a best-effort fallback.
#   BannerName  - banner display name (everything after the colon on the
#                 title line) or, if the title line is malformed, the
#                 first non-rule non-blank line trimmed of surrounding
#                 whitespace. Pass-through preserves variation in the
#                 source so the catalog highlights inconsistency rather
#                 than hiding it.
#   Description - description block between the separator and the Prefix
#                 line, with banner-rule and separator lines stripped
#   Prefix      - raw value of the "Prefix:" line (before sentinel handling)
#   IsValid     - $true only when every spec rule passes
#   DriftCodes  - array of granular drift codes for spec violations:
#                   BANNER_INLINE_SHAPE             single-line form
#                   BANNER_INVALID_RULE_CHAR        bracket line not all '='
#                   BANNER_INVALID_RULE_LENGTH      bracket '=' line != 76 chars
#                   BANNER_INVALID_SEPARATOR_CHAR   separator line not all '-'
#                   BANNER_INVALID_SEPARATOR_LENGTH separator line != 76 chars
#                   BANNER_MALFORMED_TITLE_LINE     no recognizable TYPE: NAME
#                   UNKNOWN_SECTION_TYPE            TYPE shape OK but not in enum
#                   BANNER_MISSING_DESCRIPTION      empty description block
#                   MISSING_PREFIX_DECLARATION      no Prefix: line found
#
# Per CC_CSS_Spec.md Section 3, the canonical banner form is:
#
#     ============================================================================  (76 '=')
#     <TYPE>: <NAME>
#     ----------------------------------------------------------------------------  (76 '-')
#     <Description: 1 to 5 sentences describing what's in this section.>
#     Prefix: <prefix>
#     ============================================================================  (76 '=')
#
# Description may span multiple physical lines. Effective shape is then
# six structural pieces: top rule, title, separator, description (>=1
# non-blank line), prefix, bottom rule.
#
# Caller is responsible for emitting the codes onto the COMMENT_BANNER row
# via Add-DriftCode in the populator. The validator only describes; it
# does not gate row emission. Test-IsBannerComment is the (permissive)
# admission gate.
#
# Section-type validation uses the caller-supplied -ValidSectionTypes list
# (the closed enum differs per language: CSS has FOUNDATION/CHROME/LAYOUT/
# CONTENT/OVERRIDES/FEEDBACK_OVERLAYS; JS has FOUNDATION/CHROME/IMPORTS/
# CONSTANTS/STATE/INITIALIZATION/FUNCTIONS).
function Get-BannerInfo {
    param(
        [string]$CommentText,
        [Parameter(Mandatory)][string[]]$ValidSectionTypes
    )

    $info = [ordered]@{
        TypeName    = $null
        BannerName  = $null
        Description = $null
        Prefix      = $null
        IsValid     = $false
        DriftCodes  = @()
    }

    if ($null -eq $CommentText) {
        $info.DriftCodes += 'BANNER_MALFORMED_TITLE_LINE'
        return $info
    }

    $crlf = "`r`n"; $cr = "`r"
    $normalized = $CommentText -replace $crlf, "`n" -replace $cr, "`n"
    $rawLines   = $normalized -split "`n"

    # Strip per-line leading whitespace and JSDoc-style asterisks
    $lines = @()
    foreach ($l in $rawLines) {
        $stripped = $l -replace '^\s*\*\s?', '' -replace '^\s+', ''
        $lines += $stripped.TrimEnd()
    }

    # Build effective-lines view: drop leading and trailing blanks for
    # shape analysis. Effective lines are what the spec is written
    # against.
    $first = 0
    while ($first -lt $lines.Count -and [string]::IsNullOrWhiteSpace($lines[$first])) { $first++ }
    $last  = $lines.Count - 1
    while ($last -ge 0 -and [string]::IsNullOrWhiteSpace($lines[$last])) { $last-- }

    $effective = @()
    if ($last -ge $first) {
        for ($i = $first; $i -le $last; $i++) { $effective += $lines[$i] }
    }

    # ---- Validation Pass 1: inline-shape check ----
    # The single-line form (===== Title =====) is invalid by spec - the
    # banner must be multi-line. When detected, we still parse what we
    # can but the catalog row carries the inline-shape drift code.
    $isInlineForm = ($effective.Count -eq 1 -and
                     $effective[0] -match '^={3,}\s+\S.*\s+={3,}$')
    if ($isInlineForm) {
        $info.DriftCodes += 'BANNER_INLINE_SHAPE'
    }

    # ---- Validation Pass 2: bracketing rule lines ----
    # The first and last effective lines must each be exactly 76 '='
    # characters. Two failure modes are distinguished:
    #   BANNER_INVALID_RULE_CHAR   - bracket line is not all '='
    #   BANNER_INVALID_RULE_LENGTH - bracket line is '=' but != 76 chars
    # Inline form has no bracketing rule lines per se and is exempt.
    if (-not $isInlineForm -and $effective.Count -ge 2) {
        $sawNonEqualRuleChar  = $false
        $sawWrongLengthEqRule = $false

        foreach ($bracket in @($effective[0], $effective[$effective.Count - 1])) {
            $trimmed = $bracket -replace '\s+$', ''
            if ($trimmed -match '^=+$') {
                if ($trimmed.Length -ne 76) { $sawWrongLengthEqRule = $true }
            } else {
                $sawNonEqualRuleChar = $true
            }
        }

        if ($sawNonEqualRuleChar)  { $info.DriftCodes += 'BANNER_INVALID_RULE_CHAR' }
        if ($sawWrongLengthEqRule) { $info.DriftCodes += 'BANNER_INVALID_RULE_LENGTH' }
    }

    # ---- Validation Pass 3: title line ----
    # Look for the first line matching ^TOKEN: NAME shape, where TOKEN is
    # all-uppercase letters/underscores (the spec form). Then check
    # whether TOKEN is in the enum.
    $titleLineIdx     = -1
    $unknownTypeFound = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^([A-Z_]+)\s*:\s*(.+)$') {
            $candidateType = $matches[1]
            $candidateName = $matches[2].Trim()
            if ($candidateType -in $ValidSectionTypes) {
                $info.TypeName   = $candidateType
                $info.BannerName = $candidateName
                $titleLineIdx    = $i
                break
            } else {
                # Title-line shape correct but TYPE not in enum.
                # Remember the first such occurrence; keep scanning in
                # case a later line uses a valid TYPE.
                if (-not $unknownTypeFound) {
                    $unknownTypeFound = $true
                    $titleLineIdx     = $i
                    $info.BannerName  = $candidateName
                }
            }
        }
    }

    if ($titleLineIdx -lt 0) {
        # No line at all matched the TYPE: NAME shape. Best-effort
        # fallback for BannerName: first non-rule, non-blank effective
        # line, trimmed.
        $info.DriftCodes += 'BANNER_MALFORMED_TITLE_LINE'
        foreach ($line in $effective) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            if ($line -match '^([=\-\.])\1{4,}\s*$') { continue }
            $info.BannerName = $line.Trim()
            break
        }
    } elseif ($unknownTypeFound -and -not $info.TypeName) {
        $info.DriftCodes += 'UNKNOWN_SECTION_TYPE'
    }

    # ---- Validation Pass 4: Prefix line ----
    # Singular - the post-standardization spec form. Look anywhere in
    # the comment after the title line (or anywhere if no title line
    # was found).
    $prefixLineIdx = -1
    $prefixSearchStart = if ($titleLineIdx -ge 0) { $titleLineIdx + 1 } else { 0 }
    for ($i = $prefixSearchStart; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^Prefix\s*:\s*(.+)$') {
            $info.Prefix   = $matches[1].Trim()
            $prefixLineIdx = $i
            break
        }
    }

    if ($prefixLineIdx -lt 0) {
        $info.DriftCodes += 'MISSING_PREFIX_DECLARATION'
    }

    # ---- Validation Pass 5: separator line ----
    # The spec form has exactly one separator line of 76 '-' characters
    # between the title and the description. We look for the first
    # rule-shaped line in the body region (after title, before prefix
    # if known, else end). If absent or malformed, emit the matching
    # drift code.
    if ($titleLineIdx -ge 0) {
        $sepSearchEnd = if ($prefixLineIdx -ge 0) { $prefixLineIdx - 1 } else { $lines.Count - 1 }
        $sepFound  = $false
        $sepLine   = $null
        for ($i = $titleLineIdx + 1; $i -le $sepSearchEnd; $i++) {
            $candidate = $lines[$i] -replace '\s+$', ''
            # The separator is a pure-symbol rule-shaped line. Match
            # any of '=', '-', '.' as a candidate so we can emit the
            # right granular code.
            if ($candidate -match '^([=\-\.])\1{4,}$') {
                $sepFound = $true
                $sepLine  = $candidate
                break
            }
        }

        if (-not $sepFound) {
            # No separator at all - description block (if any) sits
            # directly under the title with no rule between them.
            $info.DriftCodes += 'BANNER_INVALID_SEPARATOR_CHAR'
        } else {
            if ($sepLine -notmatch '^-+$') {
                $info.DriftCodes += 'BANNER_INVALID_SEPARATOR_CHAR'
            }
            if ($sepLine.Length -ne 76) {
                $info.DriftCodes += 'BANNER_INVALID_SEPARATOR_LENGTH'
            }
        }
    }

    # ---- Description extraction + presence check ----
    # Description sits between the separator (or title, if no separator)
    # and the Prefix line. Strip rule-shaped lines and boundary blanks.
    if ($titleLineIdx -ge 0) {
        $descStart = $titleLineIdx + 1
        $descEnd   = if ($prefixLineIdx -ge 0) { $prefixLineIdx - 1 } else { $lines.Count - 1 }

        $descLines = New-Object System.Collections.Generic.List[string]
        for ($i = $descStart; $i -le $descEnd; $i++) {
            $line = $lines[$i]
            if ($line -match '^[=]{5,}\s*$') { continue }
            if ($line -match '^[-]{5,}\s*$') { continue }
            if ($line -match '^[\.]{5,}\s*$') { continue }
            $descLines.Add($line)
        }

        while ($descLines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($descLines[0])) {
            $descLines.RemoveAt(0)
        }
        while ($descLines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($descLines[$descLines.Count - 1])) {
            $descLines.RemoveAt($descLines.Count - 1)
        }

        if ($descLines.Count -gt 0) {
            $info.Description = ($descLines -join "`n").Trim()
        } else {
            $info.DriftCodes += 'BANNER_MISSING_DESCRIPTION'
        }
    }

    # ---- Validity ----
    # Strict: every check must pass for IsValid = $true.
    if ($info.DriftCodes.Count -eq 0 -and
        -not [string]::IsNullOrEmpty($info.TypeName) -and
        -not [string]::IsNullOrEmpty($info.BannerName)) {
        $info.IsValid = $true
    }

    return $info
}

# Test whether a Prefix declaration is the "(none)" sentinel - a banner that
# explicitly opts out of prefix-matching for its section's contents. Accepts
# (none), (NONE), none, NONE, and the empty string. Whitespace and parens
# are tolerated.
function Test-IsPrefixNone {
    param([string]$Prefix)
    if ($null -eq $Prefix) { return $false }
    $trimmed = $Prefix.Trim().Trim('(',')').Trim().ToLower()
    return ($trimmed -eq 'none' -or $trimmed -eq '')
}

# Extract the bare prefix value from a Prefix declaration. Strips trailing
# annotations like "  -- the business services prefix" and parenthetical
# comments. Returns the empty string for the (none) sentinel; returns the
# trimmed token otherwise. The result is what gets compared against
# Component_Registry.cc_prefix and against identifier prefixes.
function Get-BannerPrefixValue {
    param([string]$Prefix)
    if ($null -eq $Prefix) { return '' }
    if (Test-IsPrefixNone -Prefix $Prefix) { return '' }
    $val = $Prefix -replace '\s+--.*$', ''
    $val = $val -replace '\s*\(.*\)\s*$', ''
    return $val.Trim()
}

# Test whether a banner-declared Prefix value is well-formed. The post-
# standardization spec requires a single 3-character lowercase token (e.g.
# "bkp", "bsv") OR the (none) sentinel. Returns $true if the value is
# acceptable; $false signals MALFORMED_PREFIX_VALUE drift.
function Test-PrefixValueIsValid {
    param([string]$Prefix)
    if ($null -eq $Prefix) { return $false }
    if (Test-IsPrefixNone -Prefix $Prefix) { return $true }
    $val = Get-BannerPrefixValue -Prefix $Prefix
    return ($val -match '^[a-z]{3}$')
}


# ============================================================================
# FILE HEADER PARSING
# ============================================================================

# Parse the file-header block comment (the leading /* ... */ block at line 1).
# Returns an ordered hashtable:
#   Description  - purpose paragraph (everything between the title block and
#                  the FILE ORGANIZATION list, with bookkeeping fields stripped)
#   FileOrgList  - array of banner titles declared in the FILE ORGANIZATION
#                  list, in declaration order
#   HasChangelog - $true if a CHANGELOG block is present (forbidden in source
#                  files; FORBIDDEN_CHANGELOG_BLOCK is added to DriftCodes)
#   IsValid      - $true if the header is well-formed
#   StartLine    - 1-based line where the header starts (always 1 when valid)
#   EndLine      - 1-based line where the header ends
#   DriftCodes   - array of file-header drift codes (MALFORMED_FILE_HEADER,
#                  FORBIDDEN_CHANGELOG_BLOCK)
#
# The -LocationRegex parameter validates the per-language Location: line
# (e.g. '\\public\\css\\' for CSS, '\\public\\js\\' for JS). Currently this
# is captured for future use; the function does not yet emit a drift code
# for a Location mismatch.
#
# Comments contract: each entry in $Comments is expected to expose normalized
# fields:
#   .Type      - 'Block' for block comments
#   .Text      - inner text of the comment (delimiters stripped)
#   .LineStart - 1-based line of the opening delimiter
#   .LineEnd   - 1-based line of the closing delimiter
# Per-language adapters in each populator wrap acorn / PostCSS comment
# objects into this shape before calling.
function Get-FileHeaderInfo {
    param(
        [Parameter(Mandatory)]$Comments,
        [string]$LocationRegex
    )

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

    # First Block comment in the file
    $headerComment = $null
    foreach ($c in $Comments) {
        if ($c.Type -eq 'Block') {
            $headerComment = $c
            break
        }
    }

    if ($null -eq $headerComment) {
        $info.DriftCodes += 'MALFORMED_FILE_HEADER'
        return $info
    }

    # Must start at line 1
    $headerStart = if ($null -ne $headerComment.LineStart) { [int]$headerComment.LineStart } else { 0 }

    if ($headerStart -ne 1) {
        $info.DriftCodes += 'MALFORMED_FILE_HEADER'
        return $info
    }

    $info.StartLine = $headerStart
    $info.EndLine   = if ($null -ne $headerComment.LineEnd) { [int]$headerComment.LineEnd } else { $headerStart }

    # Parse content
    $crlf = "`r`n"; $cr = "`r"
    $normalized = $headerComment.Text -replace $crlf, "`n" -replace $cr, "`n"
    $rawLines = $normalized -split "`n"

    $lines = @()
    foreach ($l in $rawLines) {
        $stripped = $l -replace '^\s*\*\s?', '' -replace '^\s+', ''
        $lines += $stripped.TrimEnd()
    }

    # Detect CHANGELOG (forbidden in source files - changelog lives in System_Metadata)
    foreach ($line in $lines) {
        if ($line -match '^CHANGELOG\b' -or $line -match '^\s*CHANGELOG\s*$') {
            $info.HasChangelog = $true
            $info.DriftCodes += 'FORBIDDEN_CHANGELOG_BLOCK'
            break
        }
    }

    # FILE ORGANIZATION list
    $fileOrgStart = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^FILE\s+ORGANIZATION\s*$') {
            $fileOrgStart = $i
            break
        }
    }

    if ($fileOrgStart -ge 0) {
        $listStart = $fileOrgStart + 1
        for ($i = $listStart; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            if ($line -match '^[-]{3,}\s*$') { continue }
            if ($line -match '^[=]{5,}\s*$') { break }
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            # Strip optional leading "1. " numbered prefix (legacy form)
            $entry = $line -replace '^\s*\d+\.\s+', ''
            # Strip trailing -- annotations
            $entry = $entry -replace '\s+--.*$', ''
            $entry = $entry.Trim()
            if (-not [string]::IsNullOrEmpty($entry)) {
                $info.FileOrgList += $entry
            }
        }
    }

    # Description = everything up to FILE ORGANIZATION, minus rule lines and
    # bookkeeping fields (identity, Location, Version)
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

    while ($descLines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($descLines[0])) {
        $descLines.RemoveAt(0)
    }
    while ($descLines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($descLines[$descLines.Count - 1])) {
        $descLines.RemoveAt($descLines.Count - 1)
    }

    if ($descLines.Count -gt 0) {
        $info.Description = ($descLines -join "`n").Trim()
    }

    # Validate identity line
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
# SECTION LIST (PRE-BUILT, LINE-RANGE INDEXED)
# ============================================================================

# Build a per-file list of section instances, sorted by source order. Each
# instance carries its banner location, body line range, parsed banner fields,
# and a per-section drift codes array. Body line range is banner-end+1 to
# next-banner-start-1 (or to file end for the last banner).
#
# Used by Get-SectionForLine to look up "what section is this line in" without
# re-walking the AST. Replaces the running-state model that the CSS populator
# used previously.
#
# Comments contract: same normalized shape as Get-FileHeaderInfo expects -
# .Type / .Text / .LineStart / .LineEnd. See Get-FileHeaderInfo header
# comment for details.
function New-SectionList {
    param(
        [Parameter(Mandatory)]$Comments,
        [Parameter(Mandatory)][int]$FileLineCount,
        [Parameter(Mandatory)][string[]]$ValidSectionTypes
    )

    $sections = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Comments) { return $sections }

    # Collect banner-shaped block comments
    $bannerComments = New-Object System.Collections.Generic.List[object]
    foreach ($c in $Comments) {
        if ($c.Type -ne 'Block') { continue }
        if (Test-IsBannerComment -CommentText $c.Text -ValidSectionTypes $ValidSectionTypes) {
            $bannerComments.Add($c)
        }
    }

    # Sort by start line
    $sorted = $bannerComments | Sort-Object {
        if ($null -ne $_.LineStart) { [int]$_.LineStart } else { 0 }
    }
    $sortedArr = @($sorted)

    for ($i = 0; $i -lt $sortedArr.Count; $i++) {
        $b = $sortedArr[$i]
        $bStart = if ($null -ne $b.LineStart) { [int]$b.LineStart } else { 0 }
        $bEnd   = if ($null -ne $b.LineEnd)   { [int]$b.LineEnd   } else { $bStart }

        $bodyStart = $bEnd + 1
        $bodyEnd   = if ($i -lt ($sortedArr.Count - 1)) {
            $next = $sortedArr[$i + 1]
            if ($null -ne $next.LineStart) { ([int]$next.LineStart) - 1 } else { $FileLineCount }
        } else {
            $FileLineCount
        }

        $info = Get-BannerInfo -CommentText $b.Text -ValidSectionTypes $ValidSectionTypes

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

# Locate the section instance that contains a given source line. Returns
# $null for lines outside any section (e.g., inside the file header, or
# between banners). Linear scan; section lists are typically <10 entries
# per file so this is fast enough.
function Get-SectionForLine {
    param(
        $Sections,
        [Parameter(Mandatory)][int]$Line
    )
    if ($null -eq $Sections) { return $null }
    foreach ($s in $Sections) {
        if ($Line -ge $s.BodyStartLine -and $Line -le $s.BodyEndLine) {
            return $s
        }
    }
    return $null
}

# Cross-validate the FILE ORGANIZATION list in the file header against the
# actual section banner titles, in order. Returns $true if they match
# exactly (same count, same titles in the same order). Returns $false if
# they diverge - the caller attaches FILE_ORG_MISMATCH to the FILE_HEADER
# row in Pass 2.
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
# AST WALKING (GENERIC VISITOR)
# ============================================================================

# Generic AST visitor walker. Visits every node in the tree depth-first and
# invokes the visitor scriptblock at each one. The visitor receives:
#   $Node        - the current node
#   $ParentChain - array of ancestor node TYPE strings (e.g. 'Program',
#                  'FunctionDeclaration', 'BlockStatement')
#   $ParentNodes - array of ancestor node references (parallel to chain)
#                  - lets the visitor inspect actual parent nodes, not just
#                    types (e.g. to find which VariableDeclarator a
#                    FunctionExpression is the init of).
#
# The visitor may return the string 'SKIP_CHILDREN' to signal that the walker
# should not recurse into this node's children. Used for structurally
# forbidden constructs (top-level IIFEs, etc.) where per-row cataloging of
# the body would just produce cascade drift - one FORBIDDEN_* row at the
# construct itself is the meaningful catalog entry.
#
# Skips primitive properties (start, end, loc, range, raw, etc.) that don't
# contain child nodes. The skip list is conservative and language-agnostic;
# it covers acorn's JS AST shape and PostCSS's CSS AST shape without
# excluding anything that could legitimately contain children. PostCSS
# rule nodes carry a 'selectorTree' property whose inner nodes have 'type'
# fields (selector, class, pseudo, etc.) - the walker skips it because the
# CSS visitor processes rule selectors via $Node.selectorTree.nodes once
# per rule, not by recursing into each selector token.
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

    $visitorResult = & $Visitor $Node $ParentChain $ParentNodes
    if ($null -ne $visitorResult -and ($visitorResult -contains 'SKIP_CHILDREN')) {
        return
    }

    $newChain = @($ParentChain + $Node.type)
    $newNodes = @($ParentNodes + $Node)

    foreach ($prop in $Node.PSObject.Properties) {
        $name = $prop.Name
        # Skip primitive properties and AST bookkeeping fields
        if ($name -in @('type','start','end','loc','range','raw','value','name',
                        'operator','prefix','flags','pattern','sourceType',
                        'computed','static','async','generator',
                        'kind','shorthand','method','delegate','optional',
                        'tail','cooked','directive','regex',
                        'selector','selectors','selectorTree','prop','important','text',
                        'params')) {
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
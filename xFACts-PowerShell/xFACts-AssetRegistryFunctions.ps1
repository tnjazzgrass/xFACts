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

    Dot-source AFTER xFACts-OrchestratorFunctions.ps1 at the top of each
    populator:
        . "$PSScriptRoot\xFACts-OrchestratorFunctions.ps1"
        . "$PSScriptRoot\xFACts-AssetRegistryFunctions.ps1"
        Initialize-XFActsScript -ScriptName 'Populate-AssetRegistry-XXX' -Execute:$Execute

    CHANGELOG
    ---------
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

# Build a (file_name -> object_registry_id) map from dbo.Object_Registry.
# Filters by file_type and is_active = 1. Used at the bulk-insert step to
# populate object_registry_id; misses are tracked separately and reported as
# advisories so the operator knows which files to add to Object_Registry.
function Get-ObjectRegistryMap {
    param(
        [Parameter(Mandatory)][string]$ServerInstance,
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][ValidateSet('CSS','HTML','JS','PS')][string]$FileType
    )

    $query = @"
SELECT object_name, object_registry_id
FROM dbo.Object_Registry
WHERE file_type = '$FileType'
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
            $map[$row.object_name] = [int]$row.object_registry_id
        }
    }
    catch {
        Write-Log "Get-ObjectRegistryMap query failed: $($_.Exception.Message)" 'WARN'
    }

    return $map
}

# Build a (file_name -> cc_prefix) map by joining dbo.Object_Registry to
# dbo.Component_Registry on component_name, filtered to a single file_type.
# Files whose component has cc_prefix = NULL are included with $null as the
# value. Files not in Object_Registry are absent from the map (callers detect
# this via .ContainsKey()).
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

    $query = @"
SELECT o.object_name, c.cc_prefix
FROM dbo.Object_Registry o
JOIN dbo.Component_Registry c
  ON o.component_name = c.component_name
WHERE o.file_type = '$FileType'
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
        [Parameter(Mandatory)][System.Collections.Generic.HashSet[string]]$Misses
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
    if ($CommentText -notmatch '={5,}') { return $false }

    # File-header disqualifications
    if ($CommentText -match 'Location\s*:\s*[A-Za-z]:[\\/]' -or
        $CommentText -match 'Version\s*:\s*Tracked in dbo\.System_Metadata' -or
        $CommentText -match 'xFACts Control Center\s*-\s*[^=]+\(.+\.[a-z]+\)') {
        return $false
    }

    # Must contain a recognized TYPE: NAME line
    $lines = $CommentText -split "`n"
    foreach ($line in $lines) {
        $stripped = $line -replace '^\s*\*\s?', '' -replace '^\s+', ''
        $stripped = $stripped.Trim()
        if ($stripped -match '^([A-Z_]+)\s*:\s*(.+)$') {
            $type = $matches[1]
            if ($type -in $ValidSectionTypes) { return $true }
        }
    }
    return $false
}

# Parse a section banner comment into its structural fields. Returns an
# ordered hashtable:
#   TypeName    - section type (FOUNDATION, CHROME, FUNCTIONS, etc.) or $null
#   BannerName  - banner display name (everything after the colon on the
#                 title line) or $null
#   Description - description block between the title and the Prefix line,
#                 with banner-rule lines and boundary blanks stripped
#   Prefix      - raw value of the "Prefix:" line (before sentinel handling)
#   IsValid     - $true if TypeName, BannerName, and Prefix were all parsed
#   DriftCodes  - array of per-banner drift codes (MALFORMED_SECTION_BANNER,
#                 MISSING_PREFIX_DECLARATION) accumulated during parse
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
        $info.DriftCodes += 'MALFORMED_SECTION_BANNER'
        return $info
    }

    $crlf = "`r`n"; $cr = "`r"
    $normalized = $CommentText -replace $crlf, "`n" -replace $cr, "`n"
    $rawLines = $normalized -split "`n"

    # Strip per-line leading whitespace and JSDoc-style asterisks
    $lines = @()
    foreach ($l in $rawLines) {
        $stripped = $l -replace '^\s*\*\s?', '' -replace '^\s+', ''
        $lines += $stripped.TrimEnd()
    }

    # Find the title line (TYPE: NAME with a recognized TYPE)
    $titleLineIdx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^([A-Z_]+)\s*:\s*(.+)$') {
            $candidateType = $matches[1]
            if ($candidateType -in $ValidSectionTypes) {
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

    # Find the Prefix line (singular - the post-standardization spec form)
    $prefixLineIdx = -1
    for ($i = $titleLineIdx + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^Prefix\s*:\s*(.+)$') {
            $info.Prefix = $matches[1].Trim()
            $prefixLineIdx = $i
            break
        }
    }

    if ($prefixLineIdx -lt 0) {
        $info.DriftCodes += 'MISSING_PREFIX_DECLARATION'
    }

    # Description = lines between title and Prefix (or end of comment),
    # excluding banner-rule lines.
    $descStart = $titleLineIdx + 1
    $descEnd   = if ($prefixLineIdx -ge 0) { $prefixLineIdx - 1 } else { $lines.Count - 1 }

    $descLines = New-Object System.Collections.Generic.List[string]
    for ($i = $descStart; $i -le $descEnd; $i++) {
        $line = $lines[$i]
        if ($line -match '^[=]{5,}\s*$') { continue }
        if ($line -match '^[-]{5,}\s*$') { continue }
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

    if (-not [string]::IsNullOrEmpty($info.TypeName) -and
        -not [string]::IsNullOrEmpty($info.BannerName) -and
        $prefixLineIdx -ge 0) {
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
        if ($c.type -eq 'Block') {
            $headerComment = $c
            break
        }
    }

    if ($null -eq $headerComment) {
        $info.DriftCodes += 'MALFORMED_FILE_HEADER'
        return $info
    }

    # Must start at line 1
    $headerStart = if ($headerComment.loc -and $headerComment.loc.start) {
        [int]$headerComment.loc.start.line
    } else { 0 }

    if ($headerStart -ne 1) {
        $info.DriftCodes += 'MALFORMED_FILE_HEADER'
        return $info
    }

    $info.StartLine = $headerStart
    $info.EndLine   = if ($headerComment.loc -and $headerComment.loc.end) {
        [int]$headerComment.loc.end.line
    } else { $headerStart }

    # Parse content
    $crlf = "`r`n"; $cr = "`r"
    $normalized = $headerComment.value -replace $crlf, "`n" -replace $cr, "`n"
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
            # Strip trailing -- annotations
            $entry = $line -replace '\s+--.*$', ''
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
        if ($c.type -ne 'Block') { continue }
        if (Test-IsBannerComment -CommentText $c.value -ValidSectionTypes $ValidSectionTypes) {
            $bannerComments.Add($c)
        }
    }

    # Sort by start line
    $sorted = $bannerComments | Sort-Object {
        if ($_.loc -and $_.loc.start) { [int]$_.loc.start.line } else { 0 }
    }
    $sortedArr = @($sorted)

    for ($i = 0; $i -lt $sortedArr.Count; $i++) {
        $b = $sortedArr[$i]
        $bStart = if ($b.loc -and $b.loc.start) { [int]$b.loc.start.line } else { 0 }
        $bEnd   = if ($b.loc -and $b.loc.end)   { [int]$b.loc.end.line   } else { $bStart }

        $bodyStart = $bEnd + 1
        $bodyEnd   = if ($i -lt ($sortedArr.Count - 1)) {
            $next = $sortedArr[$i + 1]
            if ($next.loc -and $next.loc.start) { ([int]$next.loc.start.line) - 1 } else { $FileLineCount }
        } else {
            $FileLineCount
        }

        $info = Get-BannerInfo -CommentText $b.value -ValidSectionTypes $ValidSectionTypes

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
# excluding anything that could legitimately contain children.
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
                        'selector','selectors','prop','important','text',
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
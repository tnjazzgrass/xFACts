<#
.SYNOPSIS
    xFACts - Shared Asset Registry Population Functions

.DESCRIPTION
    xFACts - ControlCenter.AssetRegistry
    Script: xFACts-AssetRegistryFunctions.ps1
    Version: Tracked in dbo.System_Metadata (component: ControlCenter.AssetRegistry)

    Common functions used by the Asset Registry populator family
    (Populate-AssetRegistry-CSS.ps1, Populate-AssetRegistry-HTML.ps1,
    Populate-AssetRegistry-JS.ps1, Populate-AssetRegistry-PS.ps1).

    Centralizes:
    - Row construction and bulk-insert plumbing
    - Drift code attachment (master-table-validated, with optional context)
    - Banner detection and parsing (parameterized for valid section types)
    - File-header parsing (CSS/JS shape via Get-FileHeaderInfo,
      PS shape via Get-PSFileHeaderInfo)
    - FILE ORGANIZATION list parsing (Get-FileOrgList - shared across all
      three header parsers)
    - Section list construction and line lookup
    - Object_Registry / Component_Registry loads
    - Comment-text cleanup
    - Generic AST visitor walker (JS/CSS shape) and PS AST helpers

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
    2026-05-22  Populator alignment - shared FILE ORG list parser and strict
                prefix-value validation. Three changes:
                  - New shared helper Get-FileOrgList. Both Get-FileHeaderInfo
                    (CSS / JS) and Get-PSFileHeaderInfo (PS) now delegate
                    FILE ORGANIZATION list extraction to this single helper.
                    The helper enforces verbatim banner-title entries per the
                    new specs (CSS / JS / PS section 2.1): no numbered prefix
                    stripping, no trailing "-- annotation" stripping. Any
                    deviation surfaces as FILE_ORG_MISMATCH on the FILE_HEADER
                    row downstream. One place to change the rule, three
                    populators benefit.
                  - Get-BannerPrefixValue no longer silently strips trailing
                    "-- text" or "(parenthetical)" annotations from the Prefix
                    line. The new specs (CSS / JS section 5) say the Prefix
                    line declares exactly one value; anything else is drift.
                    Stripped accommodations let MALFORMED_PREFIX_VALUE catch
                    real authoring drift instead of hiding it.
                  - Test-PrefixValueIsValid drops the hardcoded 3-character
                    lowercase shape constraint. The new CSS / JS specs do
                    not constrain page-prefix shape; that belongs to the
                    registry's CK constraint. The validator now accepts
                    'cc' or any non-empty token containing no whitespace
                    or commas. New optional -AllowNoneSentinel switch
                    preserves the (none) sentinel for PS callers (the PS
                    spec keeps (none) for shared-library files); CSS / JS
                    callers omit the switch and (none) becomes invalid.
                The shared helpers stay shared; PS-specific behavior is
                opt-in via the switch.
    2026-05-13  Defensive field truncation. Added Get-TruncatedFieldValue
                helper and applied it inside New-AssetRegistryRow to every
                bounded VARCHAR(N) column based on the live dbo.Asset_Registry
                schema (FileName=200, ComponentName=500, VariantType=30,
                VariantQualifier1=100, VariantQualifier2=500, SourceFile=200,
                SourceSection=300, ParentFunction=200). Long values get a
                trailing '...' marker so truncation is visible to anyone
                querying the catalog. Unbounded VARCHAR(MAX) columns
                (Signature, RawText, PurposeDescription, DriftText) are
                left alone - they can carry arbitrary length. Closed-enum
                columns (FileType, ComponentType, ReferenceType, Scope) are
                left alone - they're validated against CK constraints and
                their values come from finite vocabularies. Motivation:
                pre-spec PowerShell files produce malformed banners whose
                BannerName fallback grabs the entire first non-rule line
                (potentially hundreds of characters), and Pode route paths
                could pathologically exceed 500 chars. Both used to fail
                SqlBulkCopy with "invalid column length". Architectural fix
                in the universal row builder protects every populator
                (CSS, HTML, JS, PS) without per-emitter code changes.
    2026-05-13  PS populator support. Added two PS-specific helpers in a
                separate "PS AST AND HEADER HELPERS" section at the end of
                the file:
                  - Get-PSFileHeaderInfo parses the PowerShell comment-based-
                    help block (the .SYNOPSIS / .DESCRIPTION / .PARAMETER /
                    .COMPONENT / .NOTES form) at line 1 of a .ps1/.psm1 file.
                    Sibling to Get-FileHeaderInfo (which is CSS/JS-specific).
                    Emits PS-specific drift codes including FORBIDDEN_CHANGELOG_IN_HEADER,
                    FORBIDDEN_AUTHOR_IN_HEADER, FORBIDDEN_DATE_IN_HEADER,
                    FORBIDDEN_VERSION_IN_HEADER, FORBIDDEN_FUNCTION_INVENTORY,
                    FORBIDDEN_DEPLOYMENT_BLOCK, FORBIDDEN_INLINE_DIVIDER_IN_HEADER.
                    Returns FILE ORGANIZATION list extracted from .NOTES,
                    plus the .COMPONENT value for downstream validation against
                    Component_Registry.
                  - PS AST navigation helpers: Find-PSAstNodes (wrapper
                    around .FindAll() with TopLevelOnly mode), Get-PSAstParentChain
                    (walks .Parent up to root), Get-PSAstNodeLine /
                    Get-PSAstNodeEndLine / Get-PSAstNodeColumn (.Extent-based
                    position extractors), Test-IsTopLevelPSAst (top-of-file
                    statement check), Test-IsConditionallyDefinedPSAst (inside
                    if/while/try check). PS AST is a fundamentally different
                    walking pattern than the JSON-from-subprocess JS/CSS shape
                    that Invoke-AstWalk handles, so a separate helper set
                    rather than trying to make Invoke-AstWalk polymorphic.
                The existing helpers are unchanged. CSS / JS / HTML populator
                behavior is unaffected.
    2026-05-11  Get-ObjectRegistryMap and Get-ComponentRegistryPrefixMap
                -FileType parameter expanded to accept a string array and
                four new alias values: 'Route', 'API', 'Module', 'Config'.
                Query WHERE clause changed from object_type = '<x>' to
                object_type IN (<list>). Enables the HTML populator to
                resolve Asset_Registry FKs against the three object types
                that host HTML in this codebase (Route .ps1, API .ps1,
                Module .psm1) in a single query. Existing single-value
                callers (CSS / HTML / JS / PS) are unaffected -- PowerShell
                accepts a single string where an array is expected.
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
        [string]$PurposeDescription,
        [Nullable[bool]]$HasDynamicContent = $null
    )

    # Bounded string columns get defensively truncated against their declared
    # widths in dbo.Asset_Registry. This protects against SqlBulkCopy
    # "invalid column length" errors when pre-spec source content produces
    # unusually long values (e.g. a malformed banner whose first non-rule
    # line becomes the BannerName fallback, or a deeply-nested route path).
    # Truncated values get '...' appended so the truncation is visible. The
    # unbounded VARCHAR(MAX) columns (Signature, RawText, PurposeDescription,
    # DriftText) are left alone - they can carry arbitrary length.
    #
    # Closed-enum columns (FileType, ComponentType, ReferenceType, Scope)
    # don't need truncation - their values come from finite vocabularies and
    # are validated against CK constraints. They're left alone too.

    return [ordered]@{
        FileName           = (Get-TruncatedFieldValue -Value $FileName          -MaxLength 200)
        FileType           = $FileType
        LineStart          = $LineStart
        LineEnd            = if ($LineEnd) { $LineEnd } else { $LineStart }
        ColumnStart        = $ColumnStart
        ComponentType      = $ComponentType
        ComponentName      = (Get-TruncatedFieldValue -Value $ComponentName     -MaxLength 500)
        VariantType        = (Get-TruncatedFieldValue -Value $VariantType       -MaxLength 30)
        VariantQualifier1  = (Get-TruncatedFieldValue -Value $VariantQualifier1 -MaxLength 100)
        VariantQualifier2  = (Get-TruncatedFieldValue -Value $VariantQualifier2 -MaxLength 500)
        ReferenceType      = $ReferenceType
        Scope              = $Scope
        SourceFile         = (Get-TruncatedFieldValue -Value $SourceFile        -MaxLength 200)
        SourceSection      = (Get-TruncatedFieldValue -Value $SourceSection     -MaxLength 300)
        Signature          = $Signature
        ParentFunction     = (Get-TruncatedFieldValue -Value $ParentFunction    -MaxLength 200)
        RawText            = $RawText
        PurposeDescription = $PurposeDescription
        HasDynamicContent  = $HasDynamicContent
        DriftCodes         = $null
        DriftText          = $null
        OccurrenceIndex    = 1
    }
}

# Truncate a string value to a max length, appending '...' when truncation
# happens. Returns $null for null/empty input. Used by New-AssetRegistryRow
# to keep bounded VARCHAR(N) columns from overflowing during bulk insert.
# Cap-with-marker is preferred to silent truncation because the catalog
# stays usefully searchable on the prefix and the trailing '...' makes the
# truncation visible to anyone querying the data.
function Get-TruncatedFieldValue {
    param(
        [string]$Value,
        [Parameter(Mandatory)][int]$MaxLength
    )
    if ([string]::IsNullOrEmpty($Value)) { return $Value }
    if ($Value.Length -le $MaxLength) { return $Value }
    if ($MaxLength -le 3) { return $Value.Substring(0, $MaxLength) }
    return $Value.Substring(0, $MaxLength - 3) + '...'
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
# The -FileType parameter is the populator-facing alias. It accepts either
# a single value or a string array. Object_Registry classifies files via
# object_type using the spec's full names: 'CSS' for CSS, 'JavaScript' for
# JS, 'HTML' for HTML, 'Script' for standalone PowerShell scripts, 'Route'
# for Pode page route .ps1 files, 'API' for Pode API route .ps1 files,
# 'Module' for .psm1 helper modules, and 'Config' for .psd1 server config
# files. The HTML populator passes @('Route','API','Module') because HTML
# is embedded inside those three file kinds rather than living in standalone
# files. The mapping from alias to spec name happens here so each populator
# can pass its native short alias(es).
function Get-ObjectRegistryMap {
    param(
        [Parameter(Mandatory)][string]$ServerInstance,
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][ValidateSet('CSS','HTML','JS','PS','Route','API','Module','Config')][string[]]$FileType
    )

    $objectTypes = New-Object System.Collections.Generic.List[string]
    foreach ($ft in $FileType) {
        $mapped = switch ($ft) {
            'CSS'    { 'CSS' }
            'HTML'   { 'HTML' }
            'JS'     { 'JavaScript' }
            'PS'     { 'Script' }
            'Route'  { 'Route' }
            'API'    { 'API' }
            'Module' { 'Module' }
            'Config' { 'Config' }
        }
        if (-not $objectTypes.Contains($mapped)) { [void]$objectTypes.Add($mapped) }
    }

    # Build the IN-list with single quotes around each value. All values
    # come from the closed alias set above, so there is no injection risk
    # from the -FileType parameter.
    $inList = ($objectTypes | ForEach-Object { "'$_'" }) -join ', '

    $query = @"
SELECT object_name, registry_id
FROM dbo.Object_Registry
WHERE object_type IN ($inList)
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
# dbo.Component_Registry on component_name, filtered to one or more
# object_types (translated from the populator's FileType alias). Files
# whose component has cc_prefix = NULL are included with $null as the
# value. Files not in Object_Registry are absent from the map (callers
# detect this via .ContainsKey()).
#
# The -FileType parameter accepts either a single value or a string array.
# Same alias-to-object_type mapping as Get-ObjectRegistryMap: CSS, HTML,
# JS, PS, Route, API, Module, Config. The HTML populator passes
# @('Route','API','Module') because HTML is embedded inside those three
# file kinds rather than living in standalone files.
#
# Used by the prefix registry validation work: every page-file banner declares
# a Prefix value, which is validated against this map's value for the file.
# The (none) sentinel is always accepted regardless of the registry value
# (PS callers only; CSS / JS callers do not pass -AllowNoneSentinel to
# Test-PrefixValueIsValid so (none) is invalid there).
function Get-ComponentRegistryPrefixMap {
    param(
        [Parameter(Mandatory)][string]$ServerInstance,
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][ValidateSet('CSS','HTML','JS','PS','Route','API','Module','Config')][string[]]$FileType
    )

    $objectTypes = New-Object System.Collections.Generic.List[string]
    foreach ($ft in $FileType) {
        $mapped = switch ($ft) {
            'CSS'    { 'CSS' }
            'HTML'   { 'HTML' }
            'JS'     { 'JavaScript' }
            'PS'     { 'Script' }
            'Route'  { 'Route' }
            'API'    { 'API' }
            'Module' { 'Module' }
            'Config' { 'Config' }
        }
        if (-not $objectTypes.Contains($mapped)) { [void]$objectTypes.Add($mapped) }
    }

    # Build the IN-list with single quotes around each value. All values
    # come from the closed alias set above, so there is no injection risk
    # from the -FileType parameter.
    $inList = ($objectTypes | ForEach-Object { "'$_'" }) -join ', '

    $query = @"
SELECT o.object_name, c.cc_prefix
FROM dbo.Object_Registry o
JOIN dbo.Component_Registry c
  ON o.component_name = c.component_name
WHERE o.object_type IN ($inList)
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
    [void]$dt.Columns.Add('has_dynamic_content', [bool])
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
        $row['has_dynamic_content'] = if ($null -eq $r.HasDynamicContent) { [System.DBNull]::Value } else { [bool]$r.HasDynamicContent }
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
        if ($lines[$i] -cmatch '^([A-Z_]+)\s*:\s*(.+)$') {
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

# Extract the bare prefix value from a Prefix declaration. Returns the
# trimmed value exactly as written (whitespace boundaries removed) with
# one exception: the (none) sentinel is normalized to the empty string so
# callers can branch on Test-IsPrefixNone without re-tokenizing.
#
# Per the new CSS / JS specs (section 5), the Prefix line declares exactly
# one value. Trailing "-- annotation" text or "(parenthetical)" comments
# are NOT part of the value - they used to be silently stripped here, but
# silent stripping hides authoring drift. Anything beyond the trimmed
# single token falls through to Test-PrefixValueIsValid, which fires
# MALFORMED_PREFIX_VALUE on multi-token or annotated declarations.
function Get-BannerPrefixValue {
    param([string]$Prefix)
    if ($null -eq $Prefix) { return '' }
    if (Test-IsPrefixNone -Prefix $Prefix) { return '' }
    return $Prefix.Trim()
}

# Test whether a banner-declared Prefix value is well-formed. A value is
# well-formed when it is the chrome prefix 'cc' or a page-prefix-shaped
# single token. The validator does not enforce a length or character-set
# constraint on the page-prefix token (the registry's CK constraint on
# Component_Registry.cc_prefix does that); it only enforces that the value
# is a single token with no embedded whitespace, no comma-separated
# alternatives, and no trailing "-- annotation" or "(parenthetical)" text.
#
# When -AllowNoneSentinel is passed, the (none) sentinel is also accepted.
# This switch is for PS callers only; the PS spec keeps (none) for shared-
# library files. CSS and JS callers omit the switch so (none) is invalid
# and surfaces as MALFORMED_PREFIX_VALUE drift per the new specs.
#
# Whether a given well-formed value is correct for the section it appears
# in (page prefix in page-file sections, 'cc' in anchor-file chrome
# sections) is the PREFIX_REGISTRY_MISMATCH / ANCHOR_SECTION_INVALID_PREFIX
# checks' responsibility, not this function's.
function Test-PrefixValueIsValid {
    param(
        [string]$Prefix,
        [switch]$AllowNoneSentinel
    )
    if ($null -eq $Prefix) { return $false }
    if (Test-IsPrefixNone -Prefix $Prefix) {
        return [bool]$AllowNoneSentinel
    }
    $val = Get-BannerPrefixValue -Prefix $Prefix
    # Reject multi-token forms: any embedded whitespace or comma is drift.
    if ($val -match '[\s,]') { return $false }
    if ([string]::IsNullOrEmpty($val)) { return $false }
    if ($val -eq 'cc') { return $true }
    # Page-prefix shape: any non-empty single token survives here. The
    # registry's CK constraint enforces the actual shape (3 lowercase
    # ASCII letters as of 2026-05-22); this validator just enforces
    # single-token-ness.
    return $true
}


# ============================================================================
# FILE ORGANIZATION LIST PARSING (shared across CSS / JS / PS headers)
# ============================================================================

# Parse the FILE ORGANIZATION list out of an array of body lines, starting
# at $StartIndex (the first line AFTER the "FILE ORGANIZATION" header
# line). Returns the array of banner-title entries in declaration order,
# exactly as written - no stripping of numbered prefixes, no stripping of
# trailing "-- annotation" text. The new CSS / JS / PS specs all mandate
# verbatim entries; any deviation surfaces downstream as FILE_ORG_MISMATCH
# on the FILE_HEADER row when the populator cross-validates against the
# actual section banner titles.
#
# Termination rules:
#   - A line of 5+ '=' characters ends the list (closing rule of the file
#     header block).
#   - For CSS / JS, blank lines and 3+ '-' separator lines are skipped
#     (the helpers strip these from the comment body before passing them
#     in, but skipping is harmless if any remain).
#   - For PS, the first blank line after at least one entry ends the list
#     (the .NOTES block is structured differently). Callers that need this
#     behavior pass -StopOnFirstBlankAfterEntry.
#
# This is the single source of truth for the verbatim-entries rule. When
# the rule changes, change it here.
function Get-FileOrgList {
    param(
        # NOTE: $Lines is intentionally NOT marked [Parameter(Mandatory)].
        # PowerShell's mandatory-parameter binder applies the "not empty"
        # rule element-by-element for [string[]] arguments, which rejects
        # any input array containing a blank line - and the header body
        # routinely contains blank lines. AllowEmptyCollection / AllowNull
        # cover the array itself but not its elements; the cleanest fix is
        # to omit Mandatory on the array parameter.
        [string[]]$Lines,
        [int]$StartIndex = 0,
        [switch]$StopOnFirstBlankAfterEntry
    )

    $entries = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Lines -or $Lines.Count -eq 0) { return @() }

    for ($i = $StartIndex; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]

        # Closing rule of the file header block ends the list.
        if ($line -match '^[=]{5,}\s*$') { break }

        # Skip separator lines made of '-' (3+).
        if ($line -match '^[-]{3,}\s*$') { continue }

        if ([string]::IsNullOrWhiteSpace($line)) {
            if ($StopOnFirstBlankAfterEntry -and $entries.Count -gt 0) { break }
            continue
        }

        $entry = $line.Trim()
        if (-not [string]::IsNullOrEmpty($entry)) {
            [void]$entries.Add($entry)
        }
    }

    return @($entries.ToArray())
}


# ============================================================================
# FILE HEADER PARSING (CSS / JS)
# ============================================================================

# Parse the file-header block comment (the leading /* ... */ block at line 1).
# Returns an ordered hashtable:
#   Description  - purpose paragraph (everything between the title block and
#                  the FILE ORGANIZATION list, with bookkeeping fields stripped)
#   FileOrgList  - array of banner titles declared in the FILE ORGANIZATION
#                  list, in declaration order, verbatim. Parsed by the shared
#                  Get-FileOrgList helper - any deviation from the strict
#                  spec form surfaces as FILE_ORG_MISMATCH downstream.
#   HasChangelog - $true if a CHANGELOG block is present (forbidden in source
#                  files; FORBIDDEN_CHANGELOG_BLOCK is added to DriftCodes)
#   IsValid      - $true if the header is well-formed
#   StartLine    - 1-based line where the header starts (always 1 when valid)
#   EndLine      - 1-based line where the header ends
#   DriftCodes   - array of file-header drift codes (MALFORMED_FILE_HEADER,
#                  FORBIDDEN_CHANGELOG_BLOCK)
#
# This function is CSS/JS-specific. The PowerShell file-header format is
# fundamentally different (comment-based-help <# .SYNOPSIS .DESCRIPTION
# #> with CHANGELOG allowed as a dedicated section) and is parsed by the
# sibling function Get-PSFileHeaderInfo further down in this file.
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

    # FILE ORGANIZATION list - delegated to the shared Get-FileOrgList helper.
    $fileOrgStart = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -cmatch '^FILE\s+ORGANIZATION\s*$') {
            $fileOrgStart = $i
            break
        }
    }

    if ($fileOrgStart -ge 0) {
        $info.FileOrgList = Get-FileOrgList -Lines $lines -StartIndex ($fileOrgStart + 1)
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
# AST WALKING (GENERIC VISITOR - JS / CSS SHAPE)
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
# This walker is for the JSON-from-subprocess JS (acorn) and CSS (PostCSS)
# AST shapes - PSCustomObject trees with .type properties on every node.
# It is NOT suitable for the PowerShell native AST (System.Management.
# Automation.Language.Ast objects). The PS populator uses Find-PSAstNodes
# and the other PS AST helpers further down in this file instead.
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


# ============================================================================
# PS AST AND HEADER HELPERS
# ============================================================================
#
# These helpers serve the PowerShell populator (Populate-AssetRegistry-PS.ps1).
# PowerShell's native AST is fundamentally different from the JSON-from-
# subprocess AST shapes that JS (acorn) and CSS (PostCSS) produce:
#
#   - Real .NET objects with .GetType().Name discrimination
#     (FunctionDefinitionAst, ParameterAst, CommandAst, etc.)
#   - Child traversal via .FindAll({ predicate }, $searchNestedScriptBlocks)
#     and .Find() - not by walking PSObject properties
#   - Source positions via .Extent.StartLineNumber, .Extent.EndLineNumber,
#     .Extent.StartColumnNumber - not .loc.start.line / .source.start.line
#   - Parent references via .Parent (always populated by the parser)
#
# Rather than making the generic Invoke-AstWalk polymorphic, the PS populator
# uses these targeted helpers that match the PS-native idiom: Find-PSAstNodes
# wraps .FindAll() with a TopLevelOnly mode, Get-PSAstParentChain walks .Parent
# refs, and the position helpers extract from .Extent with null safety.
#
# Get-PSFileHeaderInfo parses the PowerShell comment-based-help file header
# (<# .SYNOPSIS .DESCRIPTION .PARAMETER .COMPONENT .NOTES #>). It is a
# sibling to Get-FileHeaderInfo (CSS/JS-specific). The two formats are
# different enough that one polymorphic function would be unclear; siblings
# are cleaner. The FILE ORGANIZATION list parsing inside both functions
# delegates to the shared Get-FileOrgList helper so the verbatim-entries
# rule lives in one place.
#
# ============================================================================

# Parse a PowerShell file-header comment-based-help block. Returns an ordered
# hashtable:
#   Synopsis     - .SYNOPSIS content (single line typical)
#   Description  - .DESCRIPTION content (multi-line block)
#   Parameters   - hashtable of @{ name -> description } from .PARAMETER tags
#   Component    - .COMPONENT value (used to validate against Component_Registry)
#   Notes        - .NOTES content (multi-line; contains FILE ORGANIZATION)
#   FileOrgList  - array of banner titles declared in FILE ORGANIZATION inside
#                  .NOTES, in declaration order, verbatim. Parsed by the shared
#                  Get-FileOrgList helper.
#   HasChangelog - $true if a CHANGELOG block is present inside the header
#                  (forbidden; CHANGELOG belongs in a dedicated section
#                  outside the header)
#   IsValid      - $true if the header is well-formed
#   StartLine    - 1-based source line of the opening '<#'
#   EndLine      - 1-based source line of the closing '#>'
#   DriftCodes   - array of file-header drift codes for spec violations:
#                    MALFORMED_FILE_HEADER
#                    FORBIDDEN_CHANGELOG_IN_HEADER
#                    FORBIDDEN_AUTHOR_IN_HEADER
#                    FORBIDDEN_DATE_IN_HEADER
#                    FORBIDDEN_VERSION_IN_HEADER
#                    FORBIDDEN_FUNCTION_INVENTORY
#                    FORBIDDEN_DEPLOYMENT_BLOCK
#                    FORBIDDEN_INLINE_DIVIDER_IN_HEADER
#                    MISSING_COMPONENT_DECLARATION (when -RequireComponent is set
#                       and .COMPONENT is absent)
#
# Per CC_PS_Spec.md Sections 6 and 17.1, the canonical header form is:
#
#     <#
#     .SYNOPSIS
#         <Single-sentence summary.>
#
#     .DESCRIPTION
#         <Multi-paragraph description.>
#
#     .PARAMETER <Name>
#         <Parameter description.>
#
#     .COMPONENT
#         <Component_Registry.component_name>
#
#     .NOTES
#         FILE ORGANIZATION
#             SECTION_TYPE: Section Name
#             SECTION_TYPE: Section Name
#             ...
#     #>
#
# The function tolerates real-world variation (missing .NOTES, FILE
# ORGANIZATION outside .NOTES, etc.) and emits drift codes rather than
# rejecting outright. The caller emits the codes onto the FILE_HEADER row.
#
# -RequireComponent: when $true, missing .COMPONENT adds MISSING_COMPONENT_DECLARATION
# to DriftCodes. Standalone scripts may not need .COMPONENT depending on
# file role; the caller (populator) decides based on the file's role.
function Get-PSFileHeaderInfo {
    param(
        [string]$RawText,
        [int]$StartLine = 1,
        [int]$EndLine   = 1,
        [switch]$RequireComponent
    )

    $info = [ordered]@{
        Synopsis      = $null
        Description   = $null
        Parameters    = @{}
        Component     = $null
        Notes         = $null
        FileOrgList   = @()
        HasChangelog  = $false
        IsValid       = $false
        StartLine     = $StartLine
        EndLine       = $EndLine
        DriftCodes    = @()
    }

    if ([string]::IsNullOrWhiteSpace($RawText)) {
        $info.DriftCodes += 'MALFORMED_FILE_HEADER'
        return $info
    }

    # Strip the <# and #> delimiters if present so we work on the body text.
    # The PS parser hands these back to us either way depending on how the
    # caller extracts the comment-based-help block, so be tolerant.
    $body = $RawText
    $body = $body -replace '^\s*<#\s*', ''
    $body = $body -replace '\s*#>\s*$', ''

    $crlf = "`r`n"; $cr = "`r"
    $normalized = $body -replace $crlf, "`n" -replace $cr, "`n"
    $lines = $normalized -split "`n"

    # ---- Pass 1: locate every .KEYWORD tag and slice the body into tag blocks ----
    # Each tag block is a hashtable @{ Tag = '<NAME>'; Param = '<param-name>';
    # Lines = @( body lines ) }. Tag/Param are uppercased; Lines preserves the
    # original line text (without the .TAG prefix) for the tag's content.
    $tagRegex = '^\s*\.([A-Z]+)(?:\s+(\S.*?))?\s*$'

    $blocks = New-Object System.Collections.Generic.List[object]
    $currentBlock = $null

    foreach ($line in $lines) {
        if ($line -match $tagRegex) {
            $currentBlock = [ordered]@{
                Tag   = $matches[1].ToUpper()
                Param = if ($matches[2]) { $matches[2].Trim() } else { $null }
                Lines = New-Object System.Collections.Generic.List[string]
            }
            $blocks.Add($currentBlock)
        }
        elseif ($null -ne $currentBlock) {
            $currentBlock.Lines.Add($line)
        }
        # Lines before the first tag are header preamble; ignored by spec.
    }

    if ($blocks.Count -eq 0) {
        # No comment-based-help tags at all. Spec requires at least .SYNOPSIS
        # and .DESCRIPTION. Treat as malformed.
        $info.DriftCodes += 'MALFORMED_FILE_HEADER'
    }

    # ---- Pass 2: populate the structured fields from the tag blocks ----
    $sawSynopsis    = $false
    $sawDescription = $false

    foreach ($block in $blocks) {
        switch ($block.Tag) {
            'SYNOPSIS' {
                $sawSynopsis = $true
                $info.Synopsis = (($block.Lines | ForEach-Object { $_.Trim() } |
                                     Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ' ').Trim()
            }
            'DESCRIPTION' {
                $sawDescription = $true
                $info.Description = ConvertTo-CleanCommentText -CommentText ($block.Lines -join "`n")
            }
            'PARAMETER' {
                if (-not [string]::IsNullOrEmpty($block.Param)) {
                    $info.Parameters[$block.Param] = ConvertTo-CleanCommentText -CommentText ($block.Lines -join "`n")
                }
            }
            'COMPONENT' {
                # .COMPONENT value is typically a single token on the same line
                # as the tag OR on the next non-blank line. Prefer the inline
                # form (block.Param); fall back to the first non-blank line of
                # the block's content.
                if (-not [string]::IsNullOrEmpty($block.Param)) {
                    $info.Component = $block.Param.Trim()
                } else {
                    foreach ($l in $block.Lines) {
                        $t = $l.Trim()
                        if (-not [string]::IsNullOrEmpty($t)) {
                            $info.Component = $t
                            break
                        }
                    }
                }
            }
            'NOTES' {
                $info.Notes = ConvertTo-CleanCommentText -CommentText ($block.Lines -join "`n")
            }
        }
    }

    if (-not $sawSynopsis -or -not $sawDescription) {
        if ($info.DriftCodes -notcontains 'MALFORMED_FILE_HEADER') {
            $info.DriftCodes += 'MALFORMED_FILE_HEADER'
        }
    }

    # ---- Pass 3: FILE ORGANIZATION extraction ----
    # Look inside .NOTES content for a "FILE ORGANIZATION" line; the shared
    # Get-FileOrgList helper handles the actual list parsing. The PS form
    # ends on the first blank line after entries (the .NOTES block is
    # structured differently from CSS / JS block comments), so we pass
    # -StopOnFirstBlankAfterEntry.
    if ($info.Notes) {
        $notesLines = $info.Notes -split "`n"
        $fileOrgStart = -1
        for ($i = 0; $i -lt $notesLines.Count; $i++) {
            if ($notesLines[$i] -cmatch '^\s*FILE\s+ORGANIZATION\s*$') {
                $fileOrgStart = $i
                break
            }
        }
        if ($fileOrgStart -ge 0) {
            $info.FileOrgList = Get-FileOrgList -Lines $notesLines `
                -StartIndex ($fileOrgStart + 1) `
                -StopOnFirstBlankAfterEntry
        }
    }

    # ---- Pass 4: forbidden-content scanning of the entire header body ----
    # These checks run against the full body text. Each fires its own drift
    # code; multiple can fire on the same header.
    foreach ($line in $lines) {
        # CHANGELOG keyword inside the header -> drift. CHANGELOG belongs in
        # a dedicated section outside the header.
        if ($line -cmatch '^\s*CHANGELOG\b') {
            $info.HasChangelog = $true
            if ($info.DriftCodes -notcontains 'FORBIDDEN_CHANGELOG_IN_HEADER') {
                $info.DriftCodes += 'FORBIDDEN_CHANGELOG_IN_HEADER'
            }
        }

        # Author/Date/Version bookkeeping lines -> drift. These belong in
        # System_Metadata, not in source headers.
        if ($line -cmatch '^\s*Author\s*:') {
            if ($info.DriftCodes -notcontains 'FORBIDDEN_AUTHOR_IN_HEADER') {
                $info.DriftCodes += 'FORBIDDEN_AUTHOR_IN_HEADER'
            }
        }
        if ($line -cmatch '^\s*Date\s*:') {
            if ($info.DriftCodes -notcontains 'FORBIDDEN_DATE_IN_HEADER') {
                $info.DriftCodes += 'FORBIDDEN_DATE_IN_HEADER'
            }
        }
        if ($line -cmatch '^\s*Version\s*:') {
            # Allow the "Tracked in dbo.System_Metadata" form which other
            # populators use as a documentation hint. Anything else is drift.
            if ($line -notmatch 'Tracked in dbo\.System_Metadata') {
                if ($info.DriftCodes -notcontains 'FORBIDDEN_VERSION_IN_HEADER') {
                    $info.DriftCodes += 'FORBIDDEN_VERSION_IN_HEADER'
                }
            }
        }

        # Function Inventory blocks -> drift. The function list belongs in
        # the FILE ORGANIZATION section, not as a separate enumeration.
        if ($line -cmatch '^\s*FUNCTION\s+INVENTORY\s*$' -or
            $line -cmatch '^\s*Functions?\s*:\s*$') {
            if ($info.DriftCodes -notcontains 'FORBIDDEN_FUNCTION_INVENTORY') {
                $info.DriftCodes += 'FORBIDDEN_FUNCTION_INVENTORY'
            }
        }

        # Deployment / Deploy: blocks -> drift. Deployment info belongs in
        # an external operational runbook, not in the source file header.
        if ($line -cmatch '^\s*Deploy(?:ment)?\s*:') {
            if ($info.DriftCodes -notcontains 'FORBIDDEN_DEPLOYMENT_BLOCK') {
                $info.DriftCodes += 'FORBIDDEN_DEPLOYMENT_BLOCK'
            }
        }

        # Inline divider rules of '=' or '-' INSIDE the header body
        # (separate from the <# / #> delimiters which are the outer
        # comment boundary). Spec uses .NOTES blocks and section banners
        # for separation; inline rules inside the header are drift.
        if ($line -match '^\s*[=]{5,}\s*$' -or $line -match '^\s*[-]{5,}\s*$') {
            if ($info.DriftCodes -notcontains 'FORBIDDEN_INLINE_DIVIDER_IN_HEADER') {
                $info.DriftCodes += 'FORBIDDEN_INLINE_DIVIDER_IN_HEADER'
            }
        }
    }

    # ---- Pass 5: .COMPONENT presence check (optional via -RequireComponent) ----
    if ($RequireComponent -and [string]::IsNullOrEmpty($info.Component)) {
        if ($info.DriftCodes -notcontains 'MISSING_COMPONENT_DECLARATION') {
            $info.DriftCodes += 'MISSING_COMPONENT_DECLARATION'
        }
    }

    # ---- Validity ----
    # Valid only when no drift codes fired AND both .SYNOPSIS and .DESCRIPTION
    # are present. The component check participates only when required.
    $info.IsValid = ($info.DriftCodes.Count -eq 0 -and $sawSynopsis -and $sawDescription)

    return $info
}

# Find AST nodes of a given type in a PowerShell AST. Wrapper around
# Ast.FindAll() with two operating modes:
#
#   Normal mode: returns every descendant node of the requested type,
#       searching into nested scriptblocks. Equivalent to FindAll({...}, $true).
#
#   -TopLevelOnly: returns only nodes that are direct children of the
#       script's top-level statement block. Use this for "top-level
#       functions only" checks (the spec's distinction between cataloged
#       top-level functions and nested helper functions that aren't
#       cataloged at the file level).
#
# The -AstType parameter is a [type] value (e.g.
# [System.Management.Automation.Language.FunctionDefinitionAst]) rather
# than a string, so the function can be called with the .NET type name
# at the call site and we get static type validation.
function Find-PSAstNodes {
    param(
        [Parameter(Mandatory)]$Ast,
        [Parameter(Mandatory)][type]$AstType,
        [switch]$TopLevelOnly
    )

    if ($null -eq $Ast) { return @() }

    if (-not $TopLevelOnly) {
        # Standard FindAll across the entire AST.
        $results = $Ast.FindAll({ param($n) $n -is $AstType }.GetNewClosure(), $true)
        return @($results)
    }

    # Top-level only: inspect the script's EndBlock statements directly.
    # EndBlock is the implicit final block of a script - where top-level
    # statements live in the absence of explicit Begin/Process/End blocks.
    $endBlock = $null
    if ($Ast -is [System.Management.Automation.Language.ScriptBlockAst]) {
        $endBlock = $Ast.EndBlock
    }
    elseif ($Ast.PSObject.Properties.Name -contains 'ScriptBlock' -and
            $Ast.ScriptBlock -is [System.Management.Automation.Language.ScriptBlockAst]) {
        $endBlock = $Ast.ScriptBlock.EndBlock
    }

    if ($null -eq $endBlock -or $null -eq $endBlock.Statements) { return @() }

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($stmt in $endBlock.Statements) {
        if ($stmt -is $AstType) {
            $results.Add($stmt)
        }
    }
    return @($results.ToArray())
}

# Walk an AST node's .Parent chain to the root and return an array of
# ancestor types (System.Type values). Used to test contextual properties:
# whether a node is inside an if/while/try block, inside a function body,
# at top level, etc.
#
# The returned array is ordered root-first (Program at index 0, immediate
# parent at the end), mirroring the JS populator's ParentChain convention.
function Get-PSAstParentChain {
    param([Parameter(Mandatory)]$Node)

    $chain = New-Object System.Collections.Generic.List[type]
    $cursor = $Node.Parent
    while ($null -ne $cursor) {
        $chain.Insert(0, $cursor.GetType())
        $cursor = $cursor.Parent
    }
    return @($chain.ToArray())
}

# 1-based source line where a PS AST node begins. Falls back to 1 when
# .Extent is null (rare but possible with synthesized nodes).
function Get-PSAstNodeLine {
    param([Parameter(Mandatory)]$Node)
    if ($null -eq $Node) { return 1 }
    if ($Node.Extent -and $Node.Extent.StartLineNumber) { return [int]$Node.Extent.StartLineNumber }
    return 1
}

# 1-based source line where a PS AST node ends.
function Get-PSAstNodeEndLine {
    param([Parameter(Mandatory)]$Node)
    if ($null -eq $Node) { return 1 }
    if ($Node.Extent -and $Node.Extent.EndLineNumber) { return [int]$Node.Extent.EndLineNumber }
    return Get-PSAstNodeLine -Node $Node
}

# 1-based column where a PS AST node begins on its starting line.
function Get-PSAstNodeColumn {
    param([Parameter(Mandatory)]$Node)
    if ($null -eq $Node) { return 1 }
    if ($Node.Extent -and $Node.Extent.StartColumnNumber) { return [int]$Node.Extent.StartColumnNumber }
    return 1
}

# Return $true if the node is a direct child of the script's top-level
# statement block (the EndBlock of the root ScriptBlockAst). Used by
# definition emitters to decide whether to emit a top-level row.
#
# Implementation walks .Parent up: a top-level statement's parent is
# directly the EndBlock NamedBlockAst, whose parent is the root
# ScriptBlockAst, whose parent is null.
function Test-IsTopLevelPSAst {
    param([Parameter(Mandatory)]$Node)
    if ($null -eq $Node) { return $false }
    $parent = $Node.Parent
    if ($null -eq $parent) { return $false }
    if ($parent -isnot [System.Management.Automation.Language.NamedBlockAst]) { return $false }
    $grandparent = $parent.Parent
    if ($null -eq $grandparent) { return $false }
    if ($grandparent -isnot [System.Management.Automation.Language.ScriptBlockAst]) { return $false }
    # Top-level only when the grandparent ScriptBlockAst has no parent
    # (it is the root script block of the file, not a nested scriptblock
    # inside a function or a hashtable literal etc.)
    return ($null -eq $grandparent.Parent)
}

# Return $true if the node is inside an if/while/do/for/try/catch block
# anywhere in its ancestry. Used by definition emitters to flag
# FORBIDDEN_CONDITIONAL_DEFINITION drift on functions declared inside
# control-flow blocks.
function Test-IsConditionallyDefinedPSAst {
    param([Parameter(Mandatory)]$Node)
    if ($null -eq $Node) { return $false }

    $forbiddenTypes = @(
        [System.Management.Automation.Language.IfStatementAst]
        [System.Management.Automation.Language.WhileStatementAst]
        [System.Management.Automation.Language.DoWhileStatementAst]
        [System.Management.Automation.Language.DoUntilStatementAst]
        [System.Management.Automation.Language.ForStatementAst]
        [System.Management.Automation.Language.ForEachStatementAst]
        [System.Management.Automation.Language.TryStatementAst]
        [System.Management.Automation.Language.CatchClauseAst]
        [System.Management.Automation.Language.SwitchStatementAst]
    )

    $cursor = $Node.Parent
    while ($null -ne $cursor) {
        foreach ($t in $forbiddenTypes) {
            if ($cursor -is $t) { return $true }
        }
        $cursor = $cursor.Parent
    }
    return $false
}
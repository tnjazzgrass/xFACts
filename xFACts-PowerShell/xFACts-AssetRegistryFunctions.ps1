<#
.SYNOPSIS
    xFACts - Shared Asset Registry Population Functions

.DESCRIPTION
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
        Type      - 'Block' for block comments (the only kind cataloged)
        Text      - inner text of the comment, with delimiters stripped
        LineStart - 1-based source line of the opening delimiter
        LineEnd   - 1-based source line of the closing delimiter
    The acorn JS AST already produces objects close to this shape; the JS
    populator wraps each comment to the normalized shape before calling these
    helpers. PostCSS produces a different shape; the CSS populator wraps
    similarly. The wrapping is a one-shot adapter in each populator; helpers
    see only the normalized shape.

    Dot-source AFTER xFACts-OrchestratorFunctions.ps1 at the top of each
    populator, then call Initialize-XFActsScript.

.COMPONENT
    Tools.Utilities

.NOTES
    File Name : xFACts-AssetRegistryFunctions.ps1
    Location  : E:\xFACts-PowerShell

    FILE ORGANIZATION
    -----------------
    CHANGELOG: CHANGE HISTORY
    FUNCTIONS: ROW CONSTRUCTION
    FUNCTIONS: DEDUPE TRACKING
    FUNCTIONS: DRIFT CODE ATTACHMENT
    FUNCTIONS: OCCURRENCE INDEX COMPUTATION
    FUNCTIONS: REGISTRY LOADS
    FUNCTIONS: BULK INSERT
    FUNCTIONS: COMMENT TEXT CLEANUP
    FUNCTIONS: BANNER DETECTION AND PARSING
    FUNCTIONS: FILE ORGANIZATION LIST PARSING
    FUNCTIONS: FILE HEADER PARSING
    FUNCTIONS: SECTION LIST
    FUNCTIONS: AST WALKING
    FUNCTIONS: PS AST AND HEADER HELPERS
    FUNCTIONS: PS FUNCTION FINGERPRINTING
#>

<# ============================================================================
   CHANGELOG: CHANGE HISTORY
   ----------------------------------------------------------------------------
   Date-stamped change history. Each entry is one ISO date line followed by an
   indented description. Entries appear most-recent first.
   Prefix: (none)
   ============================================================================ #>

# 2026-06-18  Added PS function fingerprinting: a new FUNCTIONS: PS FUNCTION
#             FINGERPRINTING section (Get-PSFunctionFingerprints plus the
#             Get-Sha256Hex, Get-PSFunctionBodyTokens, Get-PSFunctionBodyAnd-
#             ShapeHash, and Get-PSFunctionSkeletonHash helpers) computing the
#             body_hash, shape_hash, and skeleton_hash fingerprints from a
#             function's AST and token stream. New-AssetRegistryRow gains
#             optional BodyHash/ShapeHash/SkeletonHash params (default null),
#             and Invoke-AssetRegistryBulkInsert gains the matching
#             body_hash/shape_hash/skeleton_hash DataTable columns. The CSS,
#             HTML, and JS populators are unaffected: they call New-Asset-
#             RegistryRow without the new params, so their rows carry NULL in
#             the three hash columns until those populators adopt per-type
#             fingerprinting of their own promotable constructs.
# 2026-06-02  Added JS-file page-route resolution support: Get-JsRouteFileMap
#             (js_file_name -> sibling Route file path, via Object_Registry
#             component join) plus the Pode route-extraction helpers
#             Get-PodeRoutes, Get-CommandAstName, Get-StringValueFromExpression,
#             and Get-FirstPodeRoutePathFromFile. The three extraction helpers
#             were lifted from the HTML populator (identical definitions) so
#             both the HTML and JS populators resolve Add-PodeRoute -Path from
#             one shared implementation rather than per-populator copies.
# 2026-05-31  Lifted Format-SingleLine into the shared library (was duplicated
#             identically in the CSS and PS populators). Callers dot-source this
#             file, so the local definitions are removed.
# 2026-05-31  FK flag-day: Invoke-AssetRegistryBulkInsert now takes the combined
#             zone/scope map (file_name -> @{ RegistryId; ... }) and reads
#             .RegistryId for object_registry_id, instead of a flat
#             file_name -> registry_id map. All four populators pass their
#             combined map directly; the transitional projection shims are
#             removed. Get-ObjectRegistryMap was retired (no remaining callers;
#             the combined map fully replaces it).
# 2026-05-31  Get-ObjectRegistryZoneScopeMap now also returns ObjectType
#             (Route / API / Module / CSS / etc.) so the HTML populator can
#             classify each host file from the same single query. Additive;
#             existing callers are unaffected.
# 2026-05-27  Get-PSFileHeaderInfo Pass 4: added a FILE ORGANIZATION block
#             carve-out so a CHANGELOG list entry inside the FILE ORG list is
#             not mistaken for a CHANGELOG block in the header.
# 2026-05-26  Get-PSFileHeaderInfo Pass 4: carve-out for the FILE ORGANIZATION
#             separator (exactly 17 dashes) so it does not fire
#             FORBIDDEN_INLINE_DIVIDER_IN_HEADER.
# 2026-05-25  Performance pass for JS hot paths: binary-search section lookup
#             in Get-SectionForLine, lighter node-type check and untyped
#             -Visitor in Invoke-AstWalk.
# 2026-05-23  Add-DriftCode appends caller Context unconditionally while still
#             deduping the code itself, so multi-occurrence context is no
#             longer lost.
# 2026-05-22  Shared FILE ORG list parser (Get-FileOrgList) and strict
#             prefix-value validation; Get-BannerPrefixValue no longer strips
#             trailing annotations; Test-PrefixValueIsValid drops the fixed
#             three-character shape constraint and accepts 'cc' or any single
#             token, with an optional -AllowNoneSentinel switch for PS callers.
# 2026-05-13  Defensive field truncation (Get-TruncatedFieldValue) applied in
#             New-AssetRegistryRow to bounded VARCHAR columns.
# 2026-05-13  PS populator support: Get-PSFileHeaderInfo plus PS AST navigation
#             helpers in a dedicated section.
# 2026-05-11  Get-ObjectRegistryMap and Get-ComponentRegistryPrefixMap accept a
#             string-array -FileType with Route/API/Module/Config aliases and
#             query object_type IN (<list>).
# 2026-05-07  Banner detection split into a permissive detector plus a strict
#             validator emitting granular banner drift codes; retired
#             MALFORMED_SECTION_BANNER.
# 2026-05-07  Bug fixes from first run: authoritative Object_Registry column
#             names, and AllowEmptyCollection on the bulk-insert Misses param.
# 2026-05-07  Comment-shape contract formalized; populators wrap language
#             comments to the normalized shape before calling shared helpers.
# 2026-05-06  Initial implementation. Extracted shared logic from the CSS and
#             JS populators during the populator alignment pass.

<# ============================================================================
   FUNCTIONS: ROW CONSTRUCTION
   ----------------------------------------------------------------------------
   The standardized Asset_Registry row builder and bounded-field truncation
   helper.
   Prefix: (none)
   ============================================================================ #>

# Standardized Asset_Registry row builder. Returns an ordered hashtable with
# every column the bulk-insert DataTable expects. Callers populate the
# language-specific fields and pass the row through Add-DriftCode and the
# bulk-insert pipeline. FileType is required because the row shape is shared
# across CSS / HTML / JS / PS populators.
function New-AssetRegistryRow {
    param(
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][ValidateSet('CSS','HTML','JS','PS')][string]$FileType,
        [Parameter(Mandatory)][ValidateSet('cc','docs','standalone','exempt','<undefined>')][string]$Zone,
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
        [Nullable[bool]]$HasDynamicContent = $null,
        [string]$BodyHash,
        [string]$ShapeHash,
        [string]$SkeletonHash
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
        Zone               = $Zone
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
        BodyHash           = $BodyHash
        ShapeHash          = $ShapeHash
        SkeletonHash       = $SkeletonHash
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

<# ============================================================================
   FUNCTIONS: DEDUPE TRACKING
   ----------------------------------------------------------------------------
   Dedupe-key tracking shared across populators.
   Prefix: (none)
   ============================================================================ #>

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

<# ============================================================================
   FUNCTIONS: DRIFT CODE ATTACHMENT
   ----------------------------------------------------------------------------
   Attach drift codes to rows with master-table validation and optional
   context.
   Prefix: (none)
   ============================================================================ #>

# Attach a drift code to a row using the hybrid model:
#   - Code is validated against the populator's master $script:DriftDescriptions
#     ordered hashtable. Unknown codes are refused with a warning.
#   - drift_codes column accumulates comma-separated codes (deduped). The
#     code itself never appears twice in the comma list.
#   - drift_text column accumulates pipe-separated descriptions. The default
#     description comes from $script:DriftDescriptions[$Code]; callers can
#     override with the optional -Context parameter to add row-specific detail
#     (e.g. "Function 'bkp_loadData' does not start with section prefix 'bkp_'").
#
# Context-append behavior:
#   - When the caller supplies a -Context string, it is ALWAYS appended to
#     drift_text, even if the same code has already been attached. This
#     captures multiple violation sites for the same code on the same row
#     (e.g., several MALFORMED_ENGINE_CARD sub-issues on one card row,
#     several MALFORMED_PAGE_SHELL_WHITESPACE violations on one file row).
#   - When the caller does NOT supply a -Context, the generic master-table
#     description is appended ONLY on the first attachment of that code.
#     Repeating the generic description would be noise.
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

    # Codes column: dedupe before appending. Same code attached twice does
    # not produce a duplicate in DriftCodes.
    $existing = if ($Row.DriftCodes) { @($Row.DriftCodes -split ',\s*') } else { @() }
    $codeAlreadyAttached = $existing -contains $Code
    if (-not $codeAlreadyAttached) {
        $existing = @($existing) + $Code
        $Row.DriftCodes = ($existing -join ', ')
    }

    # Text column: behavior depends on whether the caller supplied a Context.
    #   - Caller-supplied Context: always append, even if the code is already
    #     attached. This captures multiple violation sites for the same code
    #     on the same row.
    #   - No caller Context: append the master description ONLY when the code
    #     is first attached. Repeating the generic description would be noise.
    if ([string]::IsNullOrWhiteSpace($Context)) {
        if ($codeAlreadyAttached) { return }
        $appendText = $script:DriftDescriptions[$Code]
    } else {
        $appendText = $Context
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

<# ============================================================================
   FUNCTIONS: OCCURRENCE INDEX COMPUTATION
   ----------------------------------------------------------------------------
   Assign per-construct occurrence indices across the collected rows.
   Prefix: (none)
   ============================================================================ #>

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

<# ============================================================================
   FUNCTIONS: REGISTRY LOADS
   ----------------------------------------------------------------------------
   Object_Registry and Component_Registry lookups used for FK resolution,
   zone/scope classification, and prefix validation.
   Prefix: (none)
   ============================================================================ #>

# Build a (file_name -> @{ RegistryId; Zone; Scope; ScopeTier; ObjectType })
# map from dbo.Object_Registry. Filters by object_type and is_active = 1. The
# -FileType parameter is the populator-facing alias (CSS, HTML, JS, PS, Route,
# API, Module, Config), mapped here to the spec's full object_type names.
# Returns the per-file registry_id (for FK linkage on emitted rows) plus the
# zone, scope, and scope_tier classification the populators use to stamp each
# emitted row and to select documentation treatment (scope_tier PLATFORM ->
# full docblocks; SCOPED or unset -> light purpose comment), and the
# object_type (Route / API / Module / CSS / JavaScript / Script / etc.) used by
# the HTML populator to classify each host file. ScopeTier and ObjectType are
# $null when the registry value is
# NULL. A file absent from this map is a registration gap: the calling populator
# stamps '<undefined>' for zone and scope and flags the file so the gap surfaces
# as drift rather than being silently misclassified.
function Get-ObjectRegistryZoneScopeMap {
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

    # All values come from the closed alias set above, so there is no injection
    # risk from the -FileType parameter.
    $inList = ($objectTypes | ForEach-Object { "'$_'" }) -join ', '

    $query = @"
SELECT object_name, registry_id, zone, scope, scope_tier, object_type
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
            $map[$row.object_name] = @{
                RegistryId = [int]$row.registry_id
                Zone       = $row.zone
                Scope      = $row.scope
                ScopeTier  = if ($row.scope_tier  -is [System.DBNull]) { $null } else { $row.scope_tier }
                ObjectType = if ($row.object_type -is [System.DBNull]) { $null } else { $row.object_type }
            }
        }
    }
    catch {
        Write-Log "Get-ObjectRegistryZoneScopeMap query failed: $($_.Exception.Message)" 'WARN'
    }

    return $map
}
# dbo.Component_Registry on component_name, filtered to one or more
# object_types (translated from the populator's FileType alias). Files
# whose component has cc_prefix = NULL are included with $null as the
# value. Files not in Object_Registry are absent from the map (callers
# detect this via .ContainsKey()).
#
# The -FileType parameter accepts either a single value or a string array,
# using the same populator-facing aliases mapped to object_type names: CSS,
# HTML, JS, PS, Route, API, Module, Config. The HTML populator passes
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

# Return a HashSet of all active component_name values from Component_Registry.
# Used by populators to validate a file header's .COMPONENT declaration:
# if the value isn't in this set, INVALID_COMPONENT_VALUE drift fires.
# Returns an empty HashSet on query failure (validation is skipped).
function Get-ComponentRegistryNameSet {
    param(
        [Parameter(Mandatory)][string]$ServerInstance,
        [Parameter(Mandatory)][string]$Database
    )

    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    $query = "SELECT DISTINCT component_name FROM dbo.Component_Registry WHERE is_active = 1"
    try {
        $results = Invoke-Sqlcmd -ServerInstance $ServerInstance -Database $Database `
                                 -Query $query -QueryTimeout 30 `
                                 -ApplicationName $script:XFActsAppName `
                                 -ErrorAction Stop `
                                 -SuppressProviderContextWarning -TrustServerCertificate
        foreach ($row in $results) {
            if (-not [string]::IsNullOrWhiteSpace($row.component_name)) {
                [void]$set.Add([string]$row.component_name)
            }
        }
    }
    catch {
        Write-Log "Get-ComponentRegistryNameSet query failed: $($_.Exception.Message)" 'WARN'
    }

    return $set
}

# Build a (js_file_name -> route_file_path) map from dbo.Object_Registry.
# For every active Control Center JavaScript file, resolve the physical path
# of the Route file (the page .ps1 that registers the Pode page route) that
# belongs to the same component. A CC page is a component whose objects include
# one JavaScript file and one Route file; the route literal itself lives inside
# that Route file's Add-PodeRoute -Path call, so the page route a JS file
# belongs to is derived by locating its sibling Route file and reading that
# call (see Get-FirstPodeRoutePathFromFile). Returns js_file_name -> route_path.
# JS files whose component has no Route object (shared bundles, vendored
# libraries) are simply absent from the map; the caller treats absence as "no
# page route" and skips route-dependent validation. The one-Route-per-component
# invariant holds for every CC page component, so MAX(object_path) collapses the
# (guaranteed single) route row without ambiguity.
function Get-JsRouteFileMap {
    param(
        [Parameter(Mandatory)][string]$ServerInstance,
        [Parameter(Mandatory)][string]$Database
    )

    $query = @"
SELECT js.object_name AS js_file, MAX(r.object_path) AS route_path
FROM dbo.Object_Registry js
JOIN dbo.Object_Registry r
  ON r.component_name = js.component_name
 AND r.object_type    = 'Route'
 AND r.is_active       = 1
WHERE js.object_type = 'JavaScript'
  AND js.is_active    = 1
GROUP BY js.object_name
"@

    $map = @{}
    try {
        $results = Invoke-Sqlcmd -ServerInstance $ServerInstance -Database $Database `
                                 -Query $query -QueryTimeout 30 `
                                 -ApplicationName $script:XFActsAppName `
                                 -ErrorAction Stop `
                                 -SuppressProviderContextWarning -TrustServerCertificate
        foreach ($row in $results) {
            if ($row.route_path -is [System.DBNull]) { continue }
            $map[$row.js_file] = [string]$row.route_path
        }
    }
    catch {
        Write-Log "Get-JsRouteFileMap query failed: $($_.Exception.Message)" 'WARN'
    }

    return $map
}

<# ============================================================================
   FUNCTIONS: BULK INSERT
   ----------------------------------------------------------------------------
   Bulk-insert the collected rows into dbo.Asset_Registry, resolving FKs
   and recording registration misses.
   Prefix: (none)
   ============================================================================ #>

# Build the Asset_Registry DataTable from a row collection and bulk-insert it
# into dbo.Asset_Registry via SqlBulkCopy. Returns the inserted row count on
# success. Throws on failure (caller decides whether to exit or continue).
#
# The DataTable schema mirrors dbo.Asset_Registry as of the file-format
# initiative. Cell values pass through Get-NullableValue to convert empty
# strings to DBNull. ObjectRegistryMap is the combined map from
# Get-ObjectRegistryZoneScopeMap (file_name -> @{ RegistryId; Zone; ... }); the
# .RegistryId of each entry supplies object_registry_id. Files not in
# Object_Registry get DBNull for object_registry_id; the missing file_names are
# accumulated in the -Misses HashSet for the caller to surface as an advisory.
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
    [void]$dt.Columns.Add('zone',                [string])
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
    [void]$dt.Columns.Add('body_hash',           [string])
    [void]$dt.Columns.Add('shape_hash',          [string])
    [void]$dt.Columns.Add('skeleton_hash',       [string])

    foreach ($r in $Rows) {
        $row = $dt.NewRow()
        $row['file_name'] = $r.FileName

        if ($ObjectRegistryMap.ContainsKey($r.FileName)) {
            $row['object_registry_id'] = [int]$ObjectRegistryMap[$r.FileName].RegistryId
        } else {
            $row['object_registry_id'] = [System.DBNull]::Value
            [void]$Misses.Add($r.FileName)
        }

        $row['file_type']           = $r.FileType
        $row['zone']                = $r.Zone
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
        $row['body_hash']           = Get-NullableValue $r.BodyHash
        $row['shape_hash']          = Get-NullableValue $r.ShapeHash
        $row['skeleton_hash']       = Get-NullableValue $r.SkeletonHash
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

<# ============================================================================
   FUNCTIONS: COMMENT TEXT CLEANUP
   ----------------------------------------------------------------------------
   Normalize comment text for storage and the nullable-value helper.
   Prefix: (none)
   ============================================================================ #>

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

# Collapse all newlines (CRLF, LF, or CR) in a string to single spaces and trim
# the result, producing a one-line form suitable for signature storage. Returns
# $null for $null input.
function Format-SingleLine {
    param([string]$Text)
    if ($null -eq $Text) { return $null }
    $crlf = "`r`n"; $lf = "`n"; $cr = "`r"
    return ($Text -replace $crlf, ' ' -replace $lf, ' ' -replace $cr, ' ').Trim()
}

<# ============================================================================
   FUNCTIONS: BANNER DETECTION AND PARSING
   ----------------------------------------------------------------------------
   Permissive banner detector plus the strict validator that emits granular
   banner drift codes.
   Prefix: (none)
   ============================================================================ #>

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
# The canonical banner form is:
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

    # Validation Pass 1: inline-shape check
    # The single-line form (===== Title =====) is invalid by spec - the
    # banner must be multi-line. When detected, we still parse what we
    # can but the catalog row carries the inline-shape drift code.
    $isInlineForm = ($effective.Count -eq 1 -and
                     $effective[0] -match '^={3,}\s+\S.*\s+={3,}$')
    if ($isInlineForm) {
        $info.DriftCodes += 'BANNER_INLINE_SHAPE'
    }

    # Validation Pass 2: bracketing rule lines
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

    # Validation Pass 3: title line
    # Look for the first line matching ^TOKEN: NAME shape, where TOKEN is
    # all-uppercase letters/underscores (the spec form). Then check
    # whether TOKEN is in the enum.
    $titleLineIdx     = -1
    $unknownTypeFound = $false
    $bareTypeFound    = $false
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
        # BANNER_MISSING_NAME: TYPE: with nothing after the colon.
        # Captures the case where the TYPE token is recognizable but the
        # NAME portion is absent. Distinct from BANNER_MALFORMED_TITLE_LINE
        # (no TYPE: shape found at all).
        elseif ($lines[$i] -cmatch '^([A-Z_]+)\s*:\s*$') {
            $candidateType = $matches[1]
            if (-not $bareTypeFound -and $titleLineIdx -lt 0) {
                $bareTypeFound = $true
                $titleLineIdx  = $i
                if ($candidateType -in $ValidSectionTypes) {
                    $info.TypeName = $candidateType
                } else {
                    $unknownTypeFound = $true
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
    } elseif ($bareTypeFound) {
        $info.DriftCodes += 'BANNER_MISSING_NAME'
        if ($unknownTypeFound -and -not $info.TypeName) {
            $info.DriftCodes += 'UNKNOWN_SECTION_TYPE'
        }
    } elseif ($unknownTypeFound -and -not $info.TypeName) {
        $info.DriftCodes += 'UNKNOWN_SECTION_TYPE'
    }

    # Validation Pass 4: Prefix line
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

    # Validation Pass 5: separator line
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

    # Description extraction + presence check
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

    # Validity
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

<# ============================================================================
   FUNCTIONS: FILE ORGANIZATION LIST PARSING
   ----------------------------------------------------------------------------
   Parse the FILE ORGANIZATION list out of a header body; shared across the
   CSS, JS, and PS header parsers.
   Prefix: (none)
   ============================================================================ #>

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

<# ============================================================================
   FUNCTIONS: FILE HEADER PARSING
   ----------------------------------------------------------------------------
   Parse the CSS/JS block-comment file header into its structured fields.
   Prefix: (none)
   ============================================================================ #>

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

<# ============================================================================
   FUNCTIONS: SECTION LIST
   ----------------------------------------------------------------------------
   Build the pre-computed, line-range-indexed section list and the
   line-to-section lookup.
   Prefix: (none)
   ============================================================================ #>

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
    if ($null -eq $Sections -or $Sections.Count -eq 0) { return $null }

    # Binary search: New-SectionList returns sections sorted by BannerStartLine
    # (which is monotonic with BodyStartLine since bodies don't overlap), so
    # we can locate the candidate section in O(log N) instead of O(N). Hot
    # path - called once per row emission, ~10K calls per JS file.
    $lo = 0
    $hi = $Sections.Count - 1
    $found = -1
    while ($lo -le $hi) {
        $mid = [int](($lo + $hi) / 2)
        if ($Line -lt [int]$Sections[$mid].BodyStartLine) {
            $hi = $mid - 1
        } else {
            $found = $mid
            $lo = $mid + 1
        }
    }
    if ($found -lt 0) { return $null }

    $candidate = $Sections[$found]
    if ($Line -le [int]$candidate.BodyEndLine) { return $candidate }
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

<# ============================================================================
   FUNCTIONS: AST WALKING
   ----------------------------------------------------------------------------
   Generic depth-first AST visitor for the JS/CSS parse-tree shape.
   Prefix: (none)
   ============================================================================ #>

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
        # Accepts either a [scriptblock] (legacy) or a [string] holding a
        # function name. Function-name dispatch (called via the call operator
        # `&` with a string) is materially faster than scriptblock invocation
        # in the hot AST-walk path. The two branches are functionally
        # identical from the caller's perspective.
        [Parameter(Mandatory)]$Visitor
    )

    if ($null -eq $Node) { return }

    if ($Node -is [System.Array] -or $Node -is [System.Collections.IList]) {
        foreach ($item in $Node) {
            Invoke-AstWalk -Node $item -ParentChain $ParentChain -ParentNodes $ParentNodes -Visitor $Visitor
        }
        return
    }

    if ($Node -isnot [System.Management.Automation.PSCustomObject]) { return }
    if ($null -eq $Node.type) { return }

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

<# ============================================================================
   FUNCTIONS: PS AST AND HEADER HELPERS
   ----------------------------------------------------------------------------
   PowerShell-specific AST navigation and the PS comment-based-help header
   parser.
   Prefix: (none)
   ============================================================================ #>
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
# The canonical PS header form is:
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

    # Pass 1: locate every .KEYWORD tag and slice the body into tag blocks
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

    # Pass 2: populate the structured fields from the tag blocks
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

    # Pass 3: FILE ORGANIZATION extraction
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

    # Pass 4: forbidden-content scanning of the entire header body
    # These checks run against the full body text. Each fires its own drift
    # code; multiple can fire on the same header.
    #
    # FILE ORGANIZATION block carve-outs: the FILE ORGANIZATION region
    # inside .NOTES is a list of section banner titles, one per line.
    # Two carve-outs apply to scans of this region:
    #   1. Separator carve-out (existing): the line immediately after the
    #      FILE ORGANIZATION label may be exactly 17 '-' characters.
    #      That single line is exempt from the inline-divider check.
    #   2. CHANGELOG list-entry carve-out: list entries inside the FILE
    #      ORGANIZATION block name the section banners verbatim. When the
    #      file has a CHANGELOG section banner titled e.g.
    #      'CHANGELOG: CHANGE HISTORY', the list entry for it also begins
    #      with 'CHANGELOG'. That list entry is NOT a CHANGELOG block
    #      inside the header; it is just naming a section banner.
    #      List entries inside the FILE ORGANIZATION block are exempt
    #      from the CHANGELOG-in-header check.
    #
    # We compute the FILE ORGANIZATION block's start and end line indices
    # once, then use those bounds inside the per-line loop.
    $fileOrgLabelIdx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -cmatch '^\s*FILE\s+ORGANIZATION\s*$') {
            $fileOrgLabelIdx = $i
            break
        }
    }

    # FILE ORGANIZATION block body: starts two lines after the label
    # (skipping the label and the separator line), ends at the first
    # blank line or end of header. When no FILE ORG label was found,
    # both indices stay at -1 and the in-block check always evaluates
    # to false.
    $fileOrgBlockStart = -1
    $fileOrgBlockEnd   = -1
    if ($fileOrgLabelIdx -ge 0) {
        $fileOrgBlockStart = $fileOrgLabelIdx + 2
        for ($j = $fileOrgBlockStart; $j -lt $lines.Count; $j++) {
            if ([string]::IsNullOrWhiteSpace($lines[$j])) {
                $fileOrgBlockEnd = $j - 1
                break
            }
        }
        if ($fileOrgBlockEnd -lt 0) {
            $fileOrgBlockEnd = $lines.Count - 1
        }
    }

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]

        $isInsideFileOrgBlock = (
            $fileOrgBlockStart -ge 0 -and
            $i -ge $fileOrgBlockStart -and
            $i -le $fileOrgBlockEnd
        )

        # CHANGELOG keyword inside the header -> drift. CHANGELOG belongs in
        # a dedicated section outside the header. A list entry inside the
        # FILE ORGANIZATION block that happens to begin with 'CHANGELOG' is
        # not a CHANGELOG block; it is the name of a section banner the
        # file declares, listed verbatim. Skip the check inside FILE ORG.
        if (-not $isInsideFileOrgBlock -and $line -cmatch '^\s*CHANGELOG\b') {
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
        # comment boundary). The header structure uses .NOTES blocks and
        # section banners for separation; inline rules inside the header
        # are drift.
        #
        # One carve-out: the FILE ORGANIZATION separator is exactly one
        # line of exactly 17 '-' characters, positioned immediately after
        # the FILE ORGANIZATION label. The line at ($fileOrgLabelIdx + 1)
        # is exempt only when it matches that exact shape; any other dash
        # count in that position is drift like everywhere else.
        $isAllowedFileOrgSeparator = (
            $fileOrgLabelIdx -ge 0 -and
            $i -eq ($fileOrgLabelIdx + 1) -and
            $line -match '^\s*-{17}\s*$'
        )
        if (-not $isAllowedFileOrgSeparator -and
            ($line -match '^\s*[=]{5,}\s*$' -or $line -match '^\s*[-]{5,}\s*$')) {
            if ($info.DriftCodes -notcontains 'FORBIDDEN_INLINE_DIVIDER_IN_HEADER') {
                $info.DriftCodes += 'FORBIDDEN_INLINE_DIVIDER_IN_HEADER'
            }
        }
    }

    # Pass 4a: forbidden comment-based-help keywords
    # The recognized comment-based-help keywords are .SYNOPSIS,
    # .DESCRIPTION, .PARAMETER, .COMPONENT, and .NOTES. Any other
    # .KEYWORD is FORBIDDEN_HEADER_KEYWORD.
    $allowedHeaderTags = @('SYNOPSIS', 'DESCRIPTION', 'PARAMETER', 'COMPONENT', 'NOTES')
    foreach ($block in $blocks) {
        if ($block.Tag -notin $allowedHeaderTags) {
            if ($info.DriftCodes -notcontains 'FORBIDDEN_HEADER_KEYWORD') {
                $info.DriftCodes += 'FORBIDDEN_HEADER_KEYWORD'
            }
        }
    }

    # Pass 4b: .NOTES field structure validation
    # .NOTES contains exactly three fields in this order: File Name,
    # Location, FILE ORGANIZATION list. Two checks:
    #   MALFORMED_NOTES_FIELD - missing required fields or unexpected fields.
    #   NOTES_FIELD_ORDER_VIOLATION - fields present but out of canonical order.
    if ($info.Notes) {
        $notesLines = $info.Notes -split "`n"
        $sawFileName = $false
        $sawLocation = $false
        $sawFileOrg  = $false
        $fileNameLineIdx = -1
        $locationLineIdx = -1
        $fileOrgLineIdx  = -1
        for ($i = 0; $i -lt $notesLines.Count; $i++) {
            $ln = $notesLines[$i]
            if ($ln -match '^\s*File\s+Name\s*:') {
                $sawFileName = $true
                if ($fileNameLineIdx -lt 0) { $fileNameLineIdx = $i }
            }
            elseif ($ln -match '^\s*Location\s*:') {
                $sawLocation = $true
                if ($locationLineIdx -lt 0) { $locationLineIdx = $i }
            }
            elseif ($ln -cmatch '^\s*FILE\s+ORGANIZATION\s*$') {
                $sawFileOrg = $true
                if ($fileOrgLineIdx -lt 0) { $fileOrgLineIdx = $i }
            }
        }
        if (-not $sawFileName -or -not $sawLocation -or -not $sawFileOrg) {
            if ($info.DriftCodes -notcontains 'MALFORMED_NOTES_FIELD') {
                $info.DriftCodes += 'MALFORMED_NOTES_FIELD'
            }
        }
        else {
            # All three present; check order: File Name < Location < FILE ORGANIZATION.
            if (-not ($fileNameLineIdx -lt $locationLineIdx -and
                      $locationLineIdx -lt $fileOrgLineIdx)) {
                if ($info.DriftCodes -notcontains 'NOTES_FIELD_ORDER_VIOLATION') {
                    $info.DriftCodes += 'NOTES_FIELD_ORDER_VIOLATION'
                }
            }
        }
    }

    # Pass 5: .COMPONENT presence check (optional via -RequireComponent)
    if ($RequireComponent -and [string]::IsNullOrEmpty($info.Component)) {
        if ($info.DriftCodes -notcontains 'MISSING_COMPONENT_DECLARATION') {
            $info.DriftCodes += 'MISSING_COMPONENT_DECLARATION'
        }
    }

    # Validity
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

# Return the bare command name from a CommandAst.
function Get-CommandAstName {
    param([Parameter(Mandatory)][System.Management.Automation.Language.CommandAst]$CommandAst)
    if ($CommandAst.CommandElements.Count -lt 1) { return $null }
    $first = $CommandAst.CommandElements[0]
    if ($first -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
        return $first.Value
    }
    return $first.Extent.Text
}

# Extract the literal string value from a StringConstantExpressionAst or
# ExpandableStringExpressionAst. Returns $null for other expression kinds.
function Get-StringValueFromExpression {
    param($Expr)
    if ($null -eq $Expr) { return $null }
    if ($Expr -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
        return $Expr.Value
    }
    if ($Expr -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
        return $Expr.Value
    }
    return $null
}

# Find every Add-PodeRoute call in an AST and return a list of:
#   .Path        - the -Path parameter's literal string value
#   .Method      - the -Method parameter's value (Get default)
#   .ScriptBlock - the ScriptBlockExpressionAst for the handler body
#   .StartLine   - source line of the Add-PodeRoute call
function Get-PodeRoutes {
    param([Parameter(Mandatory)]$Ast)

    $routes = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Ast) { return $routes }

    $allCommands = $Ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.CommandAst]
    }, $true)

    foreach ($cmd in $allCommands) {
        $cmdName = Get-CommandAstName -CommandAst $cmd
        if ($cmdName -ne 'Add-PodeRoute') { continue }

        $path        = $null
        $method      = 'Get'
        $scriptBlock = $null

        $elements = $cmd.CommandElements
        for ($i = 0; $i -lt $elements.Count; $i++) {
            $el = $elements[$i]
            if ($el -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
            $valueExpr = if ($null -ne $el.Argument) {
                $el.Argument
            } elseif ($i + 1 -lt $elements.Count) {
                $elements[$i + 1]
            } else {
                $null
            }
            switch ($el.ParameterName.ToLower()) {
                'path' {
                    $path = Get-StringValueFromExpression -Expr $valueExpr
                }
                'method' {
                    $methodVal = Get-StringValueFromExpression -Expr $valueExpr
                    if (-not [string]::IsNullOrEmpty($methodVal)) { $method = $methodVal }
                }
                'scriptblock' {
                    if ($valueExpr -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
                        $scriptBlock = $valueExpr
                    }
                }
            }
        }

        if ([string]::IsNullOrEmpty($path)) { continue }

        $routes.Add([ordered]@{
            Path        = $path
            Method      = $method
            ScriptBlock = $scriptBlock
            StartLine   = if ($cmd.Extent) { $cmd.Extent.StartLineNumber } else { 0 }
        })
    }

    return $routes
}

# Parse a .ps1 route file and return the -Path of its first Add-PodeRoute
# call, or $null if the file cannot be parsed or declares no route. Used to
# derive the page route a Control Center JS file belongs to: the JS file's
# sibling Route file (resolved via Get-JsRouteFileMap) is parsed here and its
# registered route path read directly from the Add-PodeRoute call, which is
# the authoritative source for the route (the same value Orchestrator.Process-
# Registry.cc_page_route is keyed on). Page route files register exactly one
# page route, so the first route's path is the page route.
function Get-FirstPodeRoutePathFromFile {
    param([Parameter(Mandatory)][string]$FilePath)

    if ([string]::IsNullOrEmpty($FilePath) -or -not (Test-Path -LiteralPath $FilePath)) {
        return $null
    }

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($FilePath, [ref]$tokens, [ref]$errors)
    if ($null -eq $ast) { return $null }

    $routes = Get-PodeRoutes -Ast $ast
    if ($null -eq $routes -or $routes.Count -eq 0) { return $null }

    return $routes[0].Path
}

<# ============================================================================
   FUNCTIONS: PS FUNCTION FINGERPRINTING
   ----------------------------------------------------------------------------
   Computes the three function-body fingerprints (body_hash, shape_hash,
   skeleton_hash) the catalog uses to surface duplicate, near-duplicate, and
   same-family function definitions without knowing names in advance. All
   three are derived from the function's AST and token stream, not from raw
   text, so meaning-preserving syntax differences (a semicolon versus a
   newline inside a hashtable, $Script: versus $script: scope casing, SQL
   whitespace inside a here-string) normalize away. Caller passes the
   FunctionDefinitionAst and the file's token stream; the populator invokes
   this from its function row emitter.
   Prefix: (none)
   ============================================================================ #>

# Compute a SHA-256 hash of a string and return it as 64 lowercase hex
# characters. Shared by all three fingerprints.
function Get-Sha256Hex {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $digest = $sha.ComputeHash($bytes)
        return -join ($digest | ForEach-Object { $_.ToString('x2') })
    }
    finally {
        $sha.Dispose()
    }
}

# Select the body tokens of a function: the tokens that sit strictly inside
# the function body, excluding the declaration, any attributes, the param()
# block, comments, and structural newlines. The floor is the later of the
# body's opening brace and the param block's closing paren, so [CmdletBinding()]
# and the param block (which sit before the body statements) are excluded; the
# ceiling is the body's closing brace. Comment tokens (the docblock and any
# inline comments) and newline / line-continuation tokens are dropped. Returns
# the filtered token objects in source order.
function Get-PSFunctionBodyTokens {
    param(
        [Parameter(Mandatory)]$FunctionAst,
        [Parameter(Mandatory)]$Tokens
    )

    if ($null -eq $Tokens -or $null -eq $FunctionAst.Body) {
        return @()
    }

    $bodyExtent = $FunctionAst.Body.Extent
    $bodyStartOffset = $bodyExtent.StartOffset
    $bodyEndOffset   = $bodyExtent.EndOffset

    # Exclude through the param block's closing paren when a param block exists,
    # otherwise just past the body's opening brace.
    $paramEndOffset = -1
    if ($FunctionAst.Body.ParamBlock) {
        $paramEndOffset = $FunctionAst.Body.ParamBlock.Extent.EndOffset
    }
    $floor = [Math]::Max($bodyStartOffset + 1, $paramEndOffset)

    $result = New-Object System.Collections.Generic.List[object]
    foreach ($tok in $Tokens) {
        if ($tok.Extent.StartOffset -lt $floor) { continue }
        if ($tok.Extent.EndOffset   -gt $bodyEndOffset) { continue }

        $kind = $tok.Kind.ToString()
        if ($kind -eq 'NewLine' -or $kind -eq 'LineContinuation' -or $kind -eq 'Comment') {
            continue
        }
        # The body's own closing brace is the last token in range; drop it.
        if ($kind -eq 'RCurly' -and $tok.Extent.EndOffset -eq $bodyEndOffset) {
            continue
        }
        $result.Add($tok)
    }
    return @($result.ToArray())
}

# Render the body tokens two ways and hash each:
#   body_hash  - each token's verbatim text, space-joined (exact).
#   shape_hash - string / here-string literals folded to STR, numeric literals
#                folded to N, variable references folded to VAR; all other
#                tokens (command names, member names, operators, keywords,
#                braces) kept verbatim.
# Returns a hashtable with BodyHash and ShapeHash.
function Get-PSFunctionBodyAndShapeHash {
    param(
        [Parameter(Mandatory)]$BodyTokens
    )

    $exactParts = New-Object System.Collections.Generic.List[string]
    $shapeParts = New-Object System.Collections.Generic.List[string]

    foreach ($tok in $BodyTokens) {
        $kind = $tok.Kind.ToString()
        $text = $tok.Text

        $exactParts.Add($text)

        $shapeText = $text
        if ($kind -eq 'Variable' -or $kind -eq 'SplattedVariable') {
            $shapeText = 'VAR'
        }
        elseif ($kind -eq 'Number') {
            $shapeText = 'N'
        }
        elseif ($kind -eq 'StringLiteral' -or $kind -eq 'StringExpandable' -or
                $kind -eq 'HereStringLiteral' -or $kind -eq 'HereStringExpandable') {
            $shapeText = 'STR'
        }
        $shapeParts.Add($shapeText)
    }

    return @{
        BodyHash  = Get-Sha256Hex -Text ($exactParts  -join ' ')
        ShapeHash = Get-Sha256Hex -Text ($shapeParts -join ' ')
    }
}

# Compute the skeleton hash: the sorted set of structural construct types
# present anywhere in the function body, hashed. Deliberately loose - order,
# count, called names, identifiers, and literals are all ignored, so a whole
# family of same-purpose functions lands in one bucket regardless of cosmetic
# or coupling differences. Construct presence is detected by AST node type via
# the shared Find-PSAstNodes (robust against keywords appearing inside strings
# or comments, and subclass-aware). elseif / else fold into the parent If
# presence; for / foreach / while / do-while / do-until all fold into one loop
# ingredient; a bare return with no value is not counted (only return-with-
# value carries structural signal). Returns the hash of the pipe-joined sorted
# ingredient set.
function Get-PSFunctionSkeletonHash {
    param(
        [Parameter(Mandatory)]$FunctionAst
    )

    $body = $FunctionAst.Body
    if ($null -eq $body) {
        return Get-Sha256Hex -Text ''
    }

    $ingredients = New-Object 'System.Collections.Generic.HashSet[string]'

    # Helper: add an ingredient when the body contains any node of the type.
    $addIf = {
        param([type]$AstType, [string]$Label)
        $nodes = Find-PSAstNodes -Ast $body -AstType $AstType
        if (@($nodes).Count -gt 0) { [void]$ingredients.Add($Label) }
    }

    & $addIf ([System.Management.Automation.Language.IfStatementAst])      'if'
    & $addIf ([System.Management.Automation.Language.SwitchStatementAst])  'switch'
    & $addIf ([System.Management.Automation.Language.ForEachStatementAst]) 'loop'
    & $addIf ([System.Management.Automation.Language.ForStatementAst])     'loop'
    & $addIf ([System.Management.Automation.Language.WhileStatementAst])   'loop'
    & $addIf ([System.Management.Automation.Language.DoWhileStatementAst]) 'loop'
    & $addIf ([System.Management.Automation.Language.DoUntilStatementAst]) 'loop'
    & $addIf ([System.Management.Automation.Language.TryStatementAst])     'try'
    & $addIf ([System.Management.Automation.Language.ThrowStatementAst])   'throw'
    & $addIf ([System.Management.Automation.Language.HashtableAst])        'hashtable'
    & $addIf ([System.Management.Automation.Language.ArrayExpressionAst])  'array'
    & $addIf ([System.Management.Automation.Language.ArrayLiteralAst])     'array'

    # pipeline: only a REAL multi-element pipeline ($x | Where | ForEach)
    # counts. The PowerShell AST wraps nearly every statement in a single-
    # element PipelineAst, so matching PipelineAst directly would tag almost
    # every function and carry no signal. Require 2+ pipeline elements.
    $pipelines = Find-PSAstNodes -Ast $body -AstType ([System.Management.Automation.Language.PipelineAst])
    foreach ($p in @($pipelines)) {
        if ($null -ne $p.PipelineElements -and @($p.PipelineElements).Count -ge 2) {
            [void]$ingredients.Add('pipeline'); break
        }
    }

    # return-with-value: a ReturnStatementAst that carries a pipeline (i.e.,
    # 'return $x' / 'return @{...}'), not a bare 'return'.
    $returns = Find-PSAstNodes -Ast $body -AstType ([System.Management.Automation.Language.ReturnStatementAst])
    foreach ($r in @($returns)) {
        if ($null -ne $r.Pipeline) { [void]$ingredients.Add('return'); break }
    }

    $sorted = @($ingredients) | Sort-Object
    return Get-Sha256Hex -Text ($sorted -join '|')
}

# Compute all three fingerprints for a function in a single pass over the body
# tokens and AST. Returns a hashtable with BodyHash, ShapeHash, and
# SkeletonHash. This is the entry point the populator calls; the individual
# helpers above are factored out for clarity, not for separate use.
function Get-PSFunctionFingerprints {
    param(
        [Parameter(Mandatory)]$FunctionAst,
        $Tokens
    )

    $bodyTokens = Get-PSFunctionBodyTokens -FunctionAst $FunctionAst -Tokens $Tokens
    $bs = Get-PSFunctionBodyAndShapeHash -BodyTokens $bodyTokens
    $skeleton = Get-PSFunctionSkeletonHash -FunctionAst $FunctionAst

    return @{
        BodyHash     = $bs.BodyHash
        ShapeHash    = $bs.ShapeHash
        SkeletonHash = $skeleton
    }
}
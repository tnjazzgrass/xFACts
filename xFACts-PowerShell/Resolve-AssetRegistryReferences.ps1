<#
.SYNOPSIS
    xFACts - Asset Registry Cross-Spec Reference Resolver

.DESCRIPTION
    Runs after all four populators (CSS, HTML, JS, PS) complete. Each
    populator emits Asset_Registry USAGE rows for cross-spec references
    with scope = '<pending>' and source_file = '<pending>'. This script
    resolves those pending references by matching USAGE rows against
    DEFINITION rows from files in the same component family
    (Object_Registry.component_name) or in the chrome family
    (ControlCenter.Shared).

    Resolution operates over five edges:
      - HTML -> CSS_CLASS USAGE  (component-scoped)
      - HTML -> CSS_FILE USAGE   (global match by component_name)
      - HTML -> JS_FILE USAGE    (global match by component_name)
      - JS   -> CSS_CLASS USAGE  (component-scoped)
      - JS   -> HTML_ID USAGE    (component-scoped; resolves to HTML or JS)

    Each edge runs in two phases. Phase A matches USAGE rows to DEFINITION
    rows within the resolution scope and fills in source_file and scope.
    Phase B stamps the edge-specific drift code on remaining '<pending>'
    rows, setting both columns to '<undefined>'. A final catch-all phase
    stamps UNRESOLVED_REFERENCE on any cross-spec USAGE row still in
    '<pending>' state.

    Multi-match resolution within a USAGE's scope prefers scope = 'SHARED'
    over 'LOCAL', then file_name ascending. For HTML_ID specifically,
    DEFINITION rows from file_type = 'HTML' win over file_type = 'JS'
    (HTML is the canonical source of truth for ID declarations).

.PARAMETER Execute
    Required to actually run the UPDATE statements against Asset_Registry.
    Without this flag, the script runs in preview mode: per-edge counts
    of rows that would be resolved versus marked unresolved are printed,
    no rows are modified.

.COMPONENT
    Tools.Utilities

.NOTES
    File Name : Resolve-AssetRegistryReferences.ps1
    Location  : E:\xFACts-PowerShell

    FILE ORGANIZATION
    -----------------
    PARAMETERS: SCRIPT PARAMETERS
    IMPORTS: SCRIPT DEPENDENCIES
    INITIALIZATION: SCRIPT INITIALIZATION
    CONSTANTS: EDGE DEFINITIONS
    FUNCTIONS: EDGE EXECUTION
    EXECUTION: SCRIPT EXECUTION
#>

<# ============================================================================
   PARAMETERS: SCRIPT PARAMETERS
   ----------------------------------------------------------------------------
   The single -Execute switch gates database writes. Without -Execute, the
   script runs in preview mode and the catalog is not modified.
   Prefix: (none)
   ============================================================================ #>

[CmdletBinding()]
param(
    [switch]$Execute
)

<# ============================================================================
   IMPORTS: SCRIPT DEPENDENCIES
   ----------------------------------------------------------------------------
   Dot-source xFACts-OrchestratorFunctions.ps1 to bring Initialize-XFActsScript,
   Write-Log, Get-SqlData, and Invoke-SqlNonQuery into scope. The resolver
   relies on these helpers for connection state, logging, and SQL execution.
   Prefix: (none)
   ============================================================================ #>

. "$PSScriptRoot\xFACts-OrchestratorFunctions.ps1"

<# ============================================================================
   INITIALIZATION: SCRIPT INITIALIZATION
   ----------------------------------------------------------------------------
   Connects to the xFACts database via Initialize-XFActsScript and sets strict
   error handling. The connection state (server, database, application name)
   is exposed as script-scope variables that the SQL helpers read implicitly.
   Prefix: (none)
   ============================================================================ #>

# Initialize orchestrator connection state, logging, and execute-mode wiring.
Initialize-XFActsScript -ScriptName 'Resolve-AssetRegistryReferences' -Execute:$Execute

<# ============================================================================
   CONSTANTS: EDGE DEFINITIONS
   ----------------------------------------------------------------------------
   Per-edge resolution metadata: name, drift code, drift text, and the three
   SQL statements (preview count, Phase A resolve, Phase B stamp) for each
   of the five cross-spec USAGE edges. The edge collection drives the
   EXECUTION loop. The final catch-all SQL stamps any cross-spec USAGE row
   still in <pending> state after all edges complete.
   Prefix: (none)
   ============================================================================ #>

# -- Script preferences --

# Halt on non-terminating errors so SQL failures surface immediately.
$script:ErrorActionPreference = 'Stop'

# -- HTML same-file CSS_CLASS edge (self-contained page) --

# Resolves HTML CSS_CLASS USAGE rows against CSS_CLASS DEFINITION rows that
# live in the SAME file (same component_name, same zone, same file_name) and
# originate from HTML content (file_type = 'HTML'). This covers a self-
# contained page that both defines its classes in an inline <style> block and
# uses them in its own markup -- today, only the Get-AccessDeniedHtml carve-out
# page (CC_HTML_Spec section 1.4). The carve-out is enforced upstream in the
# HTML populator (it emits these DEFINITION rows for that one function only),
# so this edge needs no function-specific clause: it can only match rows the
# populator was permitted to emit. This edge runs BEFORE EdgeHtmlCssClass so
# it claims (resolves) these same-file usages first; any usage it does not
# resolve falls through to the general cross-file edge, which remains the sole
# owner of the HTML_CSS_CLASS_UNRESOLVED stamp for this tuple. This edge never
# stamps -- its StampSql is intentionally a no-op.
$script:EdgeHtmlCssClassSelf = @{
    Name      = 'HTML -> CSS_CLASS USAGE (same-file)'
    DriftCode = $null
    DriftText = $null

    PreviewSql = @"
SELECT
    (SELECT COUNT(*)
     FROM dbo.Asset_Registry AS u
     WHERE u.component_type = 'CSS_CLASS'
       AND u.reference_type = 'USAGE'
       AND u.file_type      = 'HTML'
       AND u.scope          = '<pending>'
       AND u.source_file    = '<pending>'
       AND EXISTS (
           SELECT 1
           FROM dbo.Asset_Registry AS d
           WHERE d.component_type = 'CSS_CLASS'
             AND d.reference_type = 'DEFINITION'
             AND d.file_type      = 'HTML'
             AND d.component_name = u.component_name
             AND d.zone           = u.zone
             AND d.file_name      = u.file_name
       )) AS total_pending,
    (SELECT COUNT(*)
     FROM dbo.Asset_Registry AS u
     CROSS APPLY (
         SELECT TOP 1 1 AS hit
         FROM dbo.Asset_Registry AS d
         WHERE d.component_type = 'CSS_CLASS'
           AND d.reference_type = 'DEFINITION'
           AND d.file_type      = 'HTML'
           AND d.component_name = u.component_name
           AND d.zone           = u.zone
           AND d.file_name      = u.file_name
     ) AS m
     WHERE u.component_type = 'CSS_CLASS'
       AND u.reference_type = 'USAGE'
       AND u.file_type      = 'HTML'
       AND u.scope          = '<pending>'
       AND u.source_file    = '<pending>') AS would_resolve;
"@

    ResolveSql = @"
UPDATE u
SET
    u.source_file = best.def_file_name,
    u.scope       = best.def_scope
FROM dbo.Asset_Registry AS u
CROSS APPLY (
    SELECT TOP 1
        d.file_name AS def_file_name,
        d.scope     AS def_scope
    FROM dbo.Asset_Registry AS d
    WHERE d.component_type = 'CSS_CLASS'
      AND d.reference_type = 'DEFINITION'
      AND d.file_type      = 'HTML'
      AND d.component_name = u.component_name
      AND d.zone           = u.zone
      AND d.file_name      = u.file_name
    ORDER BY
        d.file_name
) AS best
WHERE u.component_type = 'CSS_CLASS'
  AND u.reference_type = 'USAGE'
  AND u.file_type      = 'HTML'
  AND u.scope          = '<pending>'
  AND u.source_file    = '<pending>';
"@

    StampSql = $null
}

# -- HTML to CSS_CLASS edge --

# Resolves HTML CSS_CLASS USAGE rows against CSS_CLASS DEFINITION rows from
# the same component or chrome (ControlCenter.Shared). Component scoping
# reflects runtime reality: a page loads only its own page CSS plus chrome.
$script:EdgeHtmlCssClass = @{
    Name      = 'HTML -> CSS_CLASS USAGE'
    DriftCode = 'HTML_CSS_CLASS_UNRESOLVED'
    DriftText = 'CSS class not defined in same component or chrome.'

    PreviewSql = @"
SELECT
    (SELECT COUNT(*)
     FROM dbo.Asset_Registry
     WHERE component_type = 'CSS_CLASS'
       AND reference_type = 'USAGE'
       AND file_type      = 'HTML'
       AND scope          = '<pending>'
       AND source_file    = '<pending>') AS total_pending,
    (SELECT COUNT(*)
     FROM dbo.Asset_Registry AS u
     INNER JOIN dbo.Object_Registry AS obj_u
         ON obj_u.object_name = u.file_name
     CROSS APPLY (
         SELECT TOP 1 1 AS hit
         FROM dbo.Asset_Registry AS d
         INNER JOIN dbo.Object_Registry AS obj_d
             ON obj_d.object_name = d.file_name
         WHERE d.component_type = 'CSS_CLASS'
           AND d.reference_type = 'DEFINITION'
           AND d.file_type      = 'CSS'
           AND d.component_name = u.component_name
           AND d.zone           = u.zone
           AND (obj_d.component_name = obj_u.component_name
                OR obj_d.component_name = 'ControlCenter.Shared')
     ) AS m
     WHERE u.component_type = 'CSS_CLASS'
       AND u.reference_type = 'USAGE'
       AND u.file_type      = 'HTML'
       AND u.scope          = '<pending>'
       AND u.source_file    = '<pending>') AS would_resolve;
"@

    ResolveSql = @"
UPDATE u
SET
    u.source_file = best.def_file_name,
    u.scope       = best.def_scope
FROM dbo.Asset_Registry AS u
INNER JOIN dbo.Object_Registry AS obj_u
    ON obj_u.object_name = u.file_name
CROSS APPLY (
    SELECT TOP 1
        d.file_name AS def_file_name,
        d.scope     AS def_scope
    FROM dbo.Asset_Registry AS d
    INNER JOIN dbo.Object_Registry AS obj_d
        ON obj_d.object_name = d.file_name
    WHERE d.component_type = 'CSS_CLASS'
      AND d.reference_type = 'DEFINITION'
      AND d.file_type      = 'CSS'
      AND d.component_name = u.component_name
      AND d.zone           = u.zone
      AND (obj_d.component_name = obj_u.component_name
           OR obj_d.component_name = 'ControlCenter.Shared')
    ORDER BY
        CASE WHEN d.scope = 'SHARED' THEN 0 ELSE 1 END,
        d.file_name
) AS best
WHERE u.component_type = 'CSS_CLASS'
  AND u.reference_type = 'USAGE'
  AND u.file_type      = 'HTML'
  AND u.scope          = '<pending>'
  AND u.source_file    = '<pending>';
"@

    StampSql = @"
UPDATE dbo.Asset_Registry
SET
    scope       = '<undefined>',
    source_file = '<undefined>',
    drift_codes = CASE
        WHEN drift_codes IS NULL OR drift_codes = ''
            THEN 'HTML_CSS_CLASS_UNRESOLVED'
        ELSE drift_codes + ',HTML_CSS_CLASS_UNRESOLVED'
    END,
    drift_text  = CASE
        WHEN drift_text IS NULL OR drift_text = ''
            THEN 'CSS class not defined in same component or chrome.'
        ELSE drift_text + ' | CSS class not defined in same component or chrome.'
    END
WHERE component_type = 'CSS_CLASS'
  AND reference_type = 'USAGE'
  AND file_type      = 'HTML'
  AND scope          = '<pending>'
  AND source_file    = '<pending>';
"@
}

# -- HTML to CSS_FILE edge --

# Resolves HTML CSS_FILE USAGE rows against CSS_FILE DEFINITION rows by
# exact component_name match within the same zone. CSS files are loaded by
# URL path; their DEFINITION rows are unambiguous file identities, so no
# component scoping is needed.
$script:EdgeHtmlCssFile = @{
    Name      = 'HTML -> CSS_FILE USAGE'
    DriftCode = 'HTML_CSS_FILE_UNRESOLVED'
    DriftText = 'CSS file reference does not match any catalogued CSS file.'

    PreviewSql = @"
SELECT
    (SELECT COUNT(*)
     FROM dbo.Asset_Registry
     WHERE component_type = 'CSS_FILE'
       AND reference_type = 'USAGE'
       AND file_type      = 'HTML'
       AND scope          = '<pending>'
       AND source_file    = '<pending>') AS total_pending,
    (SELECT COUNT(*)
     FROM dbo.Asset_Registry AS u
     INNER JOIN dbo.Asset_Registry AS d
         ON d.component_type = 'CSS_FILE'
        AND d.reference_type = 'DEFINITION'
        AND d.file_type      = 'CSS'
        AND d.component_name = u.component_name
        AND d.zone           = u.zone
     WHERE u.component_type = 'CSS_FILE'
       AND u.reference_type = 'USAGE'
       AND u.file_type      = 'HTML'
       AND u.scope          = '<pending>'
       AND u.source_file    = '<pending>') AS would_resolve;
"@

    ResolveSql = @"
UPDATE u
SET
    u.source_file = d.file_name,
    u.scope       = d.scope
FROM dbo.Asset_Registry AS u
INNER JOIN dbo.Asset_Registry AS d
    ON d.component_type = 'CSS_FILE'
   AND d.reference_type = 'DEFINITION'
   AND d.file_type      = 'CSS'
   AND d.component_name = u.component_name
   AND d.zone           = u.zone
WHERE u.component_type = 'CSS_FILE'
  AND u.reference_type = 'USAGE'
  AND u.file_type      = 'HTML'
  AND u.scope          = '<pending>'
  AND u.source_file    = '<pending>';
"@

    StampSql = @"
UPDATE dbo.Asset_Registry
SET
    scope       = '<undefined>',
    source_file = '<undefined>',
    drift_codes = CASE
        WHEN drift_codes IS NULL OR drift_codes = ''
            THEN 'HTML_CSS_FILE_UNRESOLVED'
        ELSE drift_codes + ',HTML_CSS_FILE_UNRESOLVED'
    END,
    drift_text  = CASE
        WHEN drift_text IS NULL OR drift_text = ''
            THEN 'CSS file reference does not match any catalogued CSS file.'
        ELSE drift_text + ' | CSS file reference does not match any catalogued CSS file.'
    END
WHERE component_type = 'CSS_FILE'
  AND reference_type = 'USAGE'
  AND file_type      = 'HTML'
  AND scope          = '<pending>'
  AND source_file    = '<pending>';
"@
}

# -- HTML to JS_FILE edge --

# Resolves HTML JS_FILE USAGE rows against JS_FILE DEFINITION rows by exact
# component_name match within the same zone. Same global-match pattern as
# CSS_FILE; JS files are also URL-loaded and have unambiguous identities.
$script:EdgeHtmlJsFile = @{
    Name      = 'HTML -> JS_FILE USAGE'
    DriftCode = 'HTML_JS_FILE_UNRESOLVED'
    DriftText = 'JS file reference does not match any catalogued JS file.'

    PreviewSql = @"
SELECT
    (SELECT COUNT(*)
     FROM dbo.Asset_Registry
     WHERE component_type = 'JS_FILE'
       AND reference_type = 'USAGE'
       AND file_type      = 'HTML'
       AND scope          = '<pending>'
       AND source_file    = '<pending>') AS total_pending,
    (SELECT COUNT(*)
     FROM dbo.Asset_Registry AS u
     INNER JOIN dbo.Asset_Registry AS d
         ON d.component_type = 'JS_FILE'
        AND d.reference_type = 'DEFINITION'
        AND d.file_type      = 'JS'
        AND d.component_name = u.component_name
        AND d.zone           = u.zone
     WHERE u.component_type = 'JS_FILE'
       AND u.reference_type = 'USAGE'
       AND u.file_type      = 'HTML'
       AND u.scope          = '<pending>'
       AND u.source_file    = '<pending>') AS would_resolve;
"@

    ResolveSql = @"
UPDATE u
SET
    u.source_file = d.file_name,
    u.scope       = d.scope
FROM dbo.Asset_Registry AS u
INNER JOIN dbo.Asset_Registry AS d
    ON d.component_type = 'JS_FILE'
   AND d.reference_type = 'DEFINITION'
   AND d.file_type      = 'JS'
   AND d.component_name = u.component_name
   AND d.zone           = u.zone
WHERE u.component_type = 'JS_FILE'
  AND u.reference_type = 'USAGE'
  AND u.file_type      = 'HTML'
  AND u.scope          = '<pending>'
  AND u.source_file    = '<pending>';
"@

    StampSql = @"
UPDATE dbo.Asset_Registry
SET
    scope       = '<undefined>',
    source_file = '<undefined>',
    drift_codes = CASE
        WHEN drift_codes IS NULL OR drift_codes = ''
            THEN 'HTML_JS_FILE_UNRESOLVED'
        ELSE drift_codes + ',HTML_JS_FILE_UNRESOLVED'
    END,
    drift_text  = CASE
        WHEN drift_text IS NULL OR drift_text = ''
            THEN 'JS file reference does not match any catalogued JS file.'
        ELSE drift_text + ' | JS file reference does not match any catalogued JS file.'
    END
WHERE component_type = 'JS_FILE'
  AND reference_type = 'USAGE'
  AND file_type      = 'HTML'
  AND scope          = '<pending>'
  AND source_file    = '<pending>';
"@
}

# -- JS to CSS_CLASS edge --

# Resolves JS CSS_CLASS USAGE rows against CSS_CLASS DEFINITION rows from
# the same component or chrome. Same component-scoping logic as the HTML
# edge; a JS file's CSS class references are constrained by which CSS files
# the page actually loads at runtime.
$script:EdgeJsCssClass = @{
    Name      = 'JS -> CSS_CLASS USAGE'
    DriftCode = 'JS_CSS_CLASS_UNRESOLVED'
    DriftText = 'CSS class not defined in same component or chrome.'

    PreviewSql = @"
SELECT
    (SELECT COUNT(*)
     FROM dbo.Asset_Registry
     WHERE component_type = 'CSS_CLASS'
       AND reference_type = 'USAGE'
       AND file_type      = 'JS'
       AND scope          = '<pending>'
       AND source_file    = '<pending>') AS total_pending,
    (SELECT COUNT(*)
     FROM dbo.Asset_Registry AS u
     INNER JOIN dbo.Object_Registry AS obj_u
         ON obj_u.object_name = u.file_name
     CROSS APPLY (
         SELECT TOP 1 1 AS hit
         FROM dbo.Asset_Registry AS d
         INNER JOIN dbo.Object_Registry AS obj_d
             ON obj_d.object_name = d.file_name
         WHERE d.component_type = 'CSS_CLASS'
           AND d.reference_type = 'DEFINITION'
           AND d.file_type      = 'CSS'
           AND d.component_name = u.component_name
           AND d.zone           = u.zone
           AND (obj_d.component_name = obj_u.component_name
                OR obj_d.component_name = 'ControlCenter.Shared')
     ) AS m
     WHERE u.component_type = 'CSS_CLASS'
       AND u.reference_type = 'USAGE'
       AND u.file_type      = 'JS'
       AND u.scope          = '<pending>'
       AND u.source_file    = '<pending>') AS would_resolve;
"@

    ResolveSql = @"
UPDATE u
SET
    u.source_file = best.def_file_name,
    u.scope       = best.def_scope
FROM dbo.Asset_Registry AS u
INNER JOIN dbo.Object_Registry AS obj_u
    ON obj_u.object_name = u.file_name
CROSS APPLY (
    SELECT TOP 1
        d.file_name AS def_file_name,
        d.scope     AS def_scope
    FROM dbo.Asset_Registry AS d
    INNER JOIN dbo.Object_Registry AS obj_d
        ON obj_d.object_name = d.file_name
    WHERE d.component_type = 'CSS_CLASS'
      AND d.reference_type = 'DEFINITION'
      AND d.file_type      = 'CSS'
      AND d.component_name = u.component_name
      AND d.zone           = u.zone
      AND (obj_d.component_name = obj_u.component_name
           OR obj_d.component_name = 'ControlCenter.Shared')
    ORDER BY
        CASE WHEN d.scope = 'SHARED' THEN 0 ELSE 1 END,
        d.file_name
) AS best
WHERE u.component_type = 'CSS_CLASS'
  AND u.reference_type = 'USAGE'
  AND u.file_type      = 'JS'
  AND u.scope          = '<pending>'
  AND u.source_file    = '<pending>';
"@

    StampSql = @"
UPDATE dbo.Asset_Registry
SET
    scope       = '<undefined>',
    source_file = '<undefined>',
    drift_codes = CASE
        WHEN drift_codes IS NULL OR drift_codes = ''
            THEN 'JS_CSS_CLASS_UNRESOLVED'
        ELSE drift_codes + ',JS_CSS_CLASS_UNRESOLVED'
    END,
    drift_text  = CASE
        WHEN drift_text IS NULL OR drift_text = ''
            THEN 'CSS class not defined in same component or chrome.'
        ELSE drift_text + ' | CSS class not defined in same component or chrome.'
    END
WHERE component_type = 'CSS_CLASS'
  AND reference_type = 'USAGE'
  AND file_type      = 'JS'
  AND scope          = '<pending>'
  AND source_file    = '<pending>';
"@
}

# -- JS to HTML_ID edge --

# Resolves JS HTML_ID USAGE rows against HTML_ID DEFINITION rows from the
# same component or chrome. DEFINITION rows can come from either HTML route
# files (canonical) or JS files (setAttribute / el.id assignments). The
# ORDER BY prefers HTML DEFINITION over JS DEFINITION; within file_type,
# SHARED scope wins over LOCAL.
$script:EdgeJsHtmlId = @{
    Name      = 'JS -> HTML_ID USAGE'
    DriftCode = 'JS_HTML_ID_UNRESOLVED'
    DriftText = 'HTML ID not declared in same component or chrome.'

    PreviewSql = @"
SELECT
    (SELECT COUNT(*)
     FROM dbo.Asset_Registry
     WHERE component_type = 'HTML_ID'
       AND reference_type = 'USAGE'
       AND file_type      = 'JS'
       AND scope          = '<pending>'
       AND source_file    = '<pending>') AS total_pending,
    (SELECT COUNT(*)
     FROM dbo.Asset_Registry AS u
     INNER JOIN dbo.Object_Registry AS obj_u
         ON obj_u.object_name = u.file_name
     CROSS APPLY (
         SELECT TOP 1 1 AS hit
         FROM dbo.Asset_Registry AS d
         INNER JOIN dbo.Object_Registry AS obj_d
             ON obj_d.object_name = d.file_name
         WHERE d.component_type = 'HTML_ID'
           AND d.reference_type = 'DEFINITION'
           AND d.file_type      IN ('HTML', 'JS')
           AND d.component_name = u.component_name
           AND d.zone           = u.zone
           AND (obj_d.component_name = obj_u.component_name
                OR obj_d.component_name = 'ControlCenter.Shared')
     ) AS m
     WHERE u.component_type = 'HTML_ID'
       AND u.reference_type = 'USAGE'
       AND u.file_type      = 'JS'
       AND u.scope          = '<pending>'
       AND u.source_file    = '<pending>') AS would_resolve;
"@

    ResolveSql = @"
UPDATE u
SET
    u.source_file = best.def_file_name,
    u.scope       = best.def_scope
FROM dbo.Asset_Registry AS u
INNER JOIN dbo.Object_Registry AS obj_u
    ON obj_u.object_name = u.file_name
CROSS APPLY (
    SELECT TOP 1
        d.file_name AS def_file_name,
        d.scope     AS def_scope
    FROM dbo.Asset_Registry AS d
    INNER JOIN dbo.Object_Registry AS obj_d
        ON obj_d.object_name = d.file_name
    WHERE d.component_type = 'HTML_ID'
      AND d.reference_type = 'DEFINITION'
      AND d.file_type      IN ('HTML', 'JS')
      AND d.component_name = u.component_name
      AND d.zone           = u.zone
      AND (obj_d.component_name = obj_u.component_name
           OR obj_d.component_name = 'ControlCenter.Shared')
    ORDER BY
        CASE WHEN d.file_type = 'HTML' THEN 0 ELSE 1 END,
        CASE WHEN d.scope = 'SHARED' THEN 0 ELSE 1 END,
        d.file_name
) AS best
WHERE u.component_type = 'HTML_ID'
  AND u.reference_type = 'USAGE'
  AND u.file_type      = 'JS'
  AND u.scope          = '<pending>'
  AND u.source_file    = '<pending>';
"@

    StampSql = @"
UPDATE dbo.Asset_Registry
SET
    scope       = '<undefined>',
    source_file = '<undefined>',
    drift_codes = CASE
        WHEN drift_codes IS NULL OR drift_codes = ''
            THEN 'JS_HTML_ID_UNRESOLVED'
        ELSE drift_codes + ',JS_HTML_ID_UNRESOLVED'
    END,
    drift_text  = CASE
        WHEN drift_text IS NULL OR drift_text = ''
            THEN 'HTML ID not declared in same component or chrome.'
        ELSE drift_text + ' | HTML ID not declared in same component or chrome.'
    END
WHERE component_type = 'HTML_ID'
  AND reference_type = 'USAGE'
  AND file_type      = 'JS'
  AND scope          = '<pending>'
  AND source_file    = '<pending>';
"@
}

# -- Edge collection --

# All edges in execution order. For most edges order is irrelevant because
# each operates on a disjoint (component_type, file_type) tuple of USAGE rows.
# The one ordering constraint: EdgeHtmlCssClassSelf must precede
# EdgeHtmlCssClass. Both target the (CSS_CLASS, USAGE, HTML) tuple; the self
# edge resolves the same-file subset first and never stamps, leaving the
# general edge as the sole owner of the HTML_CSS_CLASS_UNRESOLVED stamp for
# any usage the self edge did not resolve.
$script:Edges = @(
    $script:EdgeHtmlCssClassSelf,
    $script:EdgeHtmlCssClass,
    $script:EdgeHtmlCssFile,
    $script:EdgeHtmlJsFile,
    $script:EdgeJsCssClass,
    $script:EdgeJsHtmlId
)

# -- Final catch-all SQL --

# Defensive: any cross-spec USAGE row still in <pending> after all five
# edges ran has fallen through every resolver path. This should not happen
# if the edge list is exhaustive; the catch-all is a safety net that stamps
# UNRESOLVED_REFERENCE so the gap is visible in drift reports.
$script:FinalCatchAllSql = @"
UPDATE dbo.Asset_Registry
SET
    scope       = '<undefined>',
    source_file = '<undefined>',
    drift_codes = CASE
        WHEN drift_codes IS NULL OR drift_codes = ''
            THEN 'UNRESOLVED_REFERENCE'
        ELSE drift_codes + ',UNRESOLVED_REFERENCE'
    END,
    drift_text  = CASE
        WHEN drift_text IS NULL OR drift_text = ''
            THEN 'Cross-spec USAGE row not handled by any resolver edge.'
        ELSE drift_text + ' | Cross-spec USAGE row not handled by any resolver edge.'
    END
WHERE reference_type = 'USAGE'
  AND scope          = '<pending>'
  AND source_file    = '<pending>';
"@

<# ============================================================================
   FUNCTIONS: EDGE EXECUTION
   ----------------------------------------------------------------------------
   Helper functions wrapping the resolution workflow: per-edge preview and
   execute, the pre-run pending-row snapshot, the final catch-all UPDATE,
   and the post-run summary. Each function encapsulates its local SQL
   strings and result variables so the EXECUTION section is a flat sequence
   of function calls.
   Prefix: (none)
   ============================================================================ #>

# Print the would-resolve / would-unresolve counts for a single edge.
function Show-EdgePreview {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Edge
    )
    $result = Get-SqlData -Query $Edge.PreviewSql
    if ($null -eq $result) {
        Write-Log ("  {0}: preview query failed" -f $Edge.Name) 'WARN'
        return
    }

    $total     = [int]$result.total_pending
    $resolve   = [int]$result.would_resolve
    $unresolve = $total - $resolve

    Write-Log ("  {0,-26}  pending={1,-6} would_resolve={2,-6} would_unresolve={3}" -f $Edge.Name, $total, $resolve, $unresolve)
}

# Run Phase A (resolve) and Phase B (stamp misses) for a single edge.
function Invoke-EdgeResolution {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Edge
    )
    $before = Get-SqlData -Query $Edge.PreviewSql
    if ($null -eq $before) {
        Write-Log ("  {0}: pre-resolution count query failed" -f $Edge.Name) 'ERROR'
        return
    }
    $totalPending = [int]$before.total_pending

    if ($totalPending -eq 0) {
        Write-Log ("  {0,-26}  no pending rows" -f $Edge.Name)
        return
    }

    $okA = Invoke-SqlNonQuery -Query $Edge.ResolveSql
    if (-not $okA) {
        Write-Log ("  {0}: Phase A (resolve) failed" -f $Edge.Name) 'ERROR'
        return
    }

    $afterA = Get-SqlData -Query $Edge.PreviewSql
    if ($null -eq $afterA) {
        Write-Log ("  {0}: post-Phase-A count query failed" -f $Edge.Name) 'ERROR'
        return
    }
    $stillPending = [int]$afterA.total_pending
    $resolved     = $totalPending - $stillPending

    $stamped = 0
    if ($stillPending -gt 0 -and $null -ne $Edge.StampSql) {
        $okB = Invoke-SqlNonQuery -Query $Edge.StampSql
        if (-not $okB) {
            Write-Log ("  {0}: Phase B (stamp) failed" -f $Edge.Name) 'ERROR'
            return
        }
        $stamped = $stillPending
    }

    Write-Log ("  {0,-26}  pending={1,-6} resolved={2,-6} unresolved={3}" -f $Edge.Name, $totalPending, $resolved, $stamped)
}

# Print the current cross-spec pending row count per edge bucket.
function Show-PreRunSnapshot {
    [CmdletBinding()]
    param()
    $sql = @"
SELECT
    component_type,
    file_type,
    COUNT(*) AS pending_count
FROM dbo.Asset_Registry
WHERE reference_type = 'USAGE'
  AND scope          = '<pending>'
  AND source_file    = '<pending>'
GROUP BY component_type, file_type
ORDER BY file_type, component_type;
"@

    Write-Log "Cross-spec reference resolution: pre-run state"
    Write-Log "----------------------------------------------"

    $snapshot = Get-SqlData -Query $sql
    if ($null -eq $snapshot) {
        Write-Log "  Pre-run snapshot query failed; aborting." 'ERROR'
        exit 1
    }

    $rows = @($snapshot)
    if ($rows.Count -eq 0) {
        Write-Log "  No cross-spec USAGE rows in <pending> state. Nothing to resolve."
        return
    }

    foreach ($r in $rows) {
        Write-Log ("  {0,-12} (from {1,-4})  pending={2}" -f $r.component_type, $r.file_type, $r.pending_count)
    }
}

# Stamp UNRESOLVED_REFERENCE on any cross-spec USAGE row still pending.
function Invoke-FinalCatchAll {
    [CmdletBinding()]
    param()
    $countSql = @"
SELECT COUNT(*) AS still_pending
FROM dbo.Asset_Registry
WHERE reference_type = 'USAGE'
  AND scope          = '<pending>'
  AND source_file    = '<pending>';
"@

    $countResult = Get-SqlData -Query $countSql
    if ($null -eq $countResult) {
        Write-Log "Final catch-all count query failed." 'ERROR'
        exit 1
    }

    $stillPending = [int]$countResult.still_pending
    if ($stillPending -eq 0) { return }

    Write-Log ""
    Write-Log ("Final catch-all: {0} row(s) still in <pending> after all edges ran" -f $stillPending) 'WARN'
    Write-Log "These rows fell through every edge filter. Investigate after the run." 'WARN'

    $okCatchAll = Invoke-SqlNonQuery -Query $script:FinalCatchAllSql
    if (-not $okCatchAll) {
        Write-Log "Final catch-all UPDATE failed." 'ERROR'
        exit 1
    }

    Write-Log ("Stamped {0} row(s) with UNRESOLVED_REFERENCE." -f $stillPending) 'WARN'
}

# Print the final state of cross-spec USAGE rows after resolution.
function Show-PostRunSummary {
    [CmdletBinding()]
    param()
    Write-Log ""
    Write-Log "Post-run state"
    Write-Log "--------------"

    $sql = @"
SELECT
    file_type,
    component_type,
    scope,
    COUNT(*) AS row_count
FROM dbo.Asset_Registry
WHERE reference_type = 'USAGE'
  AND component_type IN ('CSS_CLASS', 'CSS_FILE', 'JS_FILE', 'HTML_ID')
GROUP BY file_type, component_type, scope
ORDER BY file_type, component_type, scope;
"@

    $summary = Get-SqlData -Query $sql
    if ($null -eq $summary) {
        Write-Log "Post-run summary query failed." 'WARN'
        return
    }

    foreach ($r in @($summary)) {
        Write-Log ("  {0,-4}  {1,-12}  scope={2,-12}  rows={3}" -f $r.file_type, $r.component_type, $r.scope, $r.row_count)
    }
}

<# ============================================================================
   EXECUTION: SCRIPT EXECUTION
   ----------------------------------------------------------------------------
   Procedural entry point. Runs the pre-run snapshot, branches on -Execute
   for preview vs. execute mode, and in execute mode iterates the edge
   collection through Invoke-EdgeResolution before invoking the final
   catch-all and the post-run summary.
   Prefix: (none)
   ============================================================================ #>

Show-PreRunSnapshot

if (-not $Execute) {
    Write-Log ""
    Write-Log "PREVIEW MODE - no rows will be modified. Use -Execute to apply." 'WARN'
    Write-Log ""
    Write-Log "Per-edge preview"
    Write-Log "----------------"
    foreach ($edge in $script:Edges) {
        Show-EdgePreview -Edge $edge
    }
    Write-Log ""
    Write-Log "Done (preview)."
    return
}

Write-Log ""
Write-Log "Per-edge resolution"
Write-Log "-------------------"

foreach ($edge in $script:Edges) {
    Invoke-EdgeResolution -Edge $edge
}

Invoke-FinalCatchAll
Show-PostRunSummary

Write-Log ""
Write-Log "Done."
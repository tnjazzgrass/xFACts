<#
.SYNOPSIS
    Shared documentation-pipeline functions for the xFACts platform.

.DESCRIPTION
    Functions common to the documentation-pipeline scripts (Consolidate-UploadFiles,
    Publish-GitHubRepository, Publish-ConfluenceDocumentation): extraction of user
    SQL object definitions from the catalog, and generation of the Platform Registry
    markdown snapshot from the registry tables. Dot-source this file after
    xFACts-OrchestratorFunctions.ps1 and after Initialize-XFActsScript, since the
    functions here call Get-SqlData and Write-Log from that shared file.

.COMPONENT
    Documentation.Pipeline

.NOTES
    File Name : xFACts-DocPipelineFunctions.ps1
    Location  : E:\xFACts-PowerShell\xFACts-DocPipelineFunctions.ps1

    FILE ORGANIZATION
    -----------------
    CHANGELOG: CHANGE HISTORY
    CONSTANTS: REGISTRY EXPORT DEFINITIONS
    FUNCTIONS: SQL OBJECT EXTRACTION
    FUNCTIONS: REGISTRY EXPORT
#>

<# ============================================================================
   CHANGELOG: CHANGE HISTORY
   ----------------------------------------------------------------------------
   Dated change history for this file, most recent first. Authoritative version
   tracking lives in dbo.System_Metadata (component Documentation.Pipeline);
   this section records what changed and when.
   Prefix: (none)
   ============================================================================ #>

# 2026-06-20  Get-RegistryExportMarkdown now returns a hashtable with Markdown
#             and TableCount instead of a bare markdown string, so callers can
#             report how many registry tables the snapshot covered.
# 2026-06-20  Initial implementation. Lifted Get-SqlObjectDefinitions (user SQL
#             object definition extraction) and Get-RegistryExportMarkdown
#             (Platform Registry markdown generation) out of per-script copies
#             in Consolidate-UploadFiles and Publish-GitHubRepository into one
#             shared scoped helper. The $RegistryExports table set moved here as
#             the single source of which registry tables the snapshot includes.

<# ============================================================================
   CONSTANTS: REGISTRY EXPORT DEFINITIONS
   ----------------------------------------------------------------------------
   The registry tables included in the Platform Registry markdown snapshot. Each
   entry is a Title and the Query whose result set renders as one markdown table
   in the generated document. This list is the single source of which registry
   tables the snapshot covers.
   Prefix: (none)
   ============================================================================ #>

# Registry tables exported to the Platform Registry markdown snapshot, in order.
$script:RegistryExports = @(
    @{
        Title = "Module Registry"
        Query = "SELECT module_name, description FROM dbo.Module_Registry WHERE is_active = 1 ORDER BY module_name"
    },
    @{
        Title = "Component Registry"
        Query = "SELECT module_name, component_name, description, cc_prefix, doc_page_id, doc_title, doc_json_schema, doc_json_categories, doc_cc_slug, doc_sort_order, doc_section_order FROM dbo.Component_Registry WHERE is_active = 1 ORDER BY module_name, component_name"
    },
    @{
        Title = "Object Registry"
        Query = "SELECT component_name, object_name, object_category, object_type, object_path, description FROM dbo.Object_Registry WHERE is_active = 1 ORDER BY component_name, object_category, object_type, object_name"
    },
    @{
        Title = "Nav Registry"
        Query = "SELECT page_route, nav_label, display_title, description, section_key, sort_order, doc_page_id, show_in_nav, show_on_home FROM dbo.RBAC_NavRegistry WHERE is_active = 1 ORDER BY section_key, sort_order, page_route"
    },
    @{
        Title = "Process Registry"
        Query = "SELECT module_name, process_name, description, script_path, procedure_name, execution_mode, dependency_group, interval_seconds, scheduled_time, timeout_seconds, run_mode, allow_concurrent, cc_engine_slug, cc_engine_label, cc_page_route, cc_sort_order FROM Orchestrator.ProcessRegistry ORDER BY dependency_group, module_name, process_name"
    },
    @{
        Title = "Global Configuration"
        Query = "SELECT module_name, category, setting_name, setting_value, data_type, description FROM dbo.GlobalConfig WHERE is_active = 1 ORDER BY module_name, category, setting_name"
    }
)

<# ============================================================================
   FUNCTIONS: SQL OBJECT EXTRACTION
   ----------------------------------------------------------------------------
   Extraction of user-defined SQL object definitions (procedures, triggers,
   functions, views) from the catalog. Returns the raw definition rows so each
   caller can render or persist them however it needs.
   Prefix: (none)
   ============================================================================ #>

# Returns the T-SQL definition of every user SQL module (procs, triggers, functions, views) as raw rows.
function Get-SqlObjectDefinitions {
    param(
        [string]$Instance = $script:XFActsServerInstance,
        [string]$DatabaseName = $script:XFActsDatabase
    )

    $query = @"
SELECT
    s.name AS schema_name,
    o.name AS object_name,
    o.type_desc,
    m.definition
FROM sys.sql_modules m
INNER JOIN sys.objects o ON m.object_id = o.object_id
INNER JOIN sys.schemas s ON o.schema_id = s.schema_id
WHERE s.name NOT IN ('sys', 'INFORMATION_SCHEMA')
  AND o.is_ms_shipped = 0
ORDER BY s.name, o.type_desc, o.name
"@

    return Get-SqlData -Query $query -Instance $Instance -DatabaseName $DatabaseName -Timeout 120 -MaxCharLength 1000000
}

<# ============================================================================
   FUNCTIONS: REGISTRY EXPORT
   ----------------------------------------------------------------------------
   Generation of the Platform Registry markdown snapshot. Runs each registry
   query in $script:RegistryExports, renders each result set as a markdown
   table, and returns the assembled document plus the count of tables that
   rendered, so the caller can both write the snapshot and report how many
   tables it covered.
   Prefix: (none)
   ============================================================================ #>

# Builds the Platform Registry markdown snapshot and returns a hashtable with the Markdown string and the TableCount of tables rendered.
function Get-RegistryExportMarkdown {
    param(
        [string]$Instance = $script:XFActsServerInstance,
        [string]$DatabaseName = $script:XFActsDatabase
    )

    $lines = @()
    $lines += "# xFACts Platform Registry"
    $lines += "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $lines += ""

    $tableCount = 0

    foreach ($export in $script:RegistryExports) {
        try {
            $rows = Get-SqlData -Query $export.Query -Instance $Instance -DatabaseName $DatabaseName -Timeout 60

            $rowCount = @($rows).Count
            if ($rowCount -eq 0) {
                Write-Log "  SKIP  $($export.Title) - no rows"
                continue
            }

            $lines += "## $($export.Title)"
            $lines += ""

            # Column names from the first row, excluding DataRow system properties.
            $columns = $rows[0].PSObject.Properties |
                Where-Object { $_.Name -notin @('RowError', 'RowState', 'Table', 'ItemArray', 'HasErrors') } |
                ForEach-Object { $_.Name }

            $lines += "| " + ($columns -join " | ") + " |"
            $lines += "| " + (($columns | ForEach-Object { "---" }) -join " | ") + " |"

            foreach ($row in $rows) {
                $values = foreach ($col in $columns) {
                    $val = $row.$col
                    if ($null -eq $val -or $val -is [DBNull]) { "" }
                    else { [string]$val -replace '\|', '\|' -replace '\r?\n', ' ' }
                }
                $lines += "| " + ($values -join " | ") + " |"
            }

            $lines += ""
            $tableCount++
            Write-Log "  OK    $($export.Title) - $rowCount rows" "SUCCESS"
        }
        catch {
            Write-Log "  ERROR  $($export.Title) - $($_.Exception.Message)" "ERROR"
        }
    }

    return @{
        Markdown   = ($lines -join "`n")
        TableCount = $tableCount
    }
}
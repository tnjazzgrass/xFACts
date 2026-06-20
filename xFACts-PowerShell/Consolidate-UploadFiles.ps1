<#
.SYNOPSIS
    Consolidates all xFACts platform files into a single upload-ready folder.

.DESCRIPTION
    Collects all platform files from their various server locations into a single
    flat folder for uploading to Claude as project context. Optionally extracts
    user SQL object definitions from the database and includes JSON data files.
    Generates a _manifest.txt with source path mappings so the consumer has
    awareness of the server directory structure. Designed to be run manually or
    triggered from the Control Center Admin page.

.PARAMETER OutputPath
    Root folder for consolidated output. Default: E:\xFACts-Upload

.PARAMETER IncludeJSON
    Include JSON data files from docs/data/ddl/ in the output.

.PARAMETER IncludeSQLObjects
    Extract stored procedure, trigger, and function definitions from the database.

.PARAMETER xFACtsServer
    SQL Server instance for SQL object extraction. Default: AVG-PROD-LSNR

.PARAMETER xFACtsDB
    Database name. Default: xFACts

.PARAMETER Execute
    Required to actually copy files. Without this, runs in preview mode.

.COMPONENT
    Documentation.Pipeline

.NOTES
    File Name : Consolidate-UploadFiles.ps1
    Location  : E:\xFACts-PowerShell\Consolidate-UploadFiles.ps1

    FILE ORGANIZATION
    -----------------
    CHANGELOG: CHANGE HISTORY
    PARAMETERS: SCRIPT PARAMETERS
    IMPORTS: SCRIPT DEPENDENCIES
    INITIALIZATION: SCRIPT INITIALIZATION
    CONSTANTS: PATHS AND SOURCES
    EXECUTION: SCRIPT EXECUTION
#>

<# ============================================================================
   CHANGELOG: CHANGE HISTORY
   ----------------------------------------------------------------------------
   Dated change history for this file, most recent first. Authoritative version
   tracking lives in dbo.System_Metadata (component Documentation.Pipeline);
   this section records what changed and when.
   Prefix: (none)
   ============================================================================ #>

# 2026-06-20  Conformed to the PowerShell file format spec: block-comment header
#             and section banners, dedicated CHANGELOG section, single EXECUTION
#             section, and Write-Console in place of Write-Host. Dot-sources
#             xFACts-OrchestratorFunctions.ps1 and xFACts-DocPipelineFunctions.ps1
#             and runs Initialize-XFActsScript for shared infrastructure. SQL
#             object extraction now calls the shared Get-SqlObjectDefinitions;
#             registry markdown generation now calls the shared
#             Get-RegistryExportMarkdown, which returns the markdown and the
#             count of tables rendered, replacing the per-script copies.
# 2026-03-01  Initial implementation.

<# ============================================================================
   PARAMETERS: SCRIPT PARAMETERS
   ----------------------------------------------------------------------------
   Output location, optional-content switches, the SQL connection target for
   object extraction and registry export, and the execute guard.
   Prefix: (none)
   ============================================================================ #>

[CmdletBinding()]
param(
    [string]$OutputPath = "E:\xFACts-Upload",
    [switch]$IncludeJSON,
    [switch]$IncludeSQLObjects,
    [string]$xFACtsServer = "AVG-PROD-LSNR",
    [string]$xFACtsDB = "xFACts",
    [switch]$Execute
)

<# ============================================================================
   IMPORTS: SCRIPT DEPENDENCIES
   ----------------------------------------------------------------------------
   Dot-sourced shared infrastructure: orchestrator helpers (initialization,
   console output, SQL data access) and the documentation-pipeline helpers (SQL
   object extraction and Platform Registry markdown generation).
   Prefix: (none)
   ============================================================================ #>

. "$PSScriptRoot\xFACts-OrchestratorFunctions.ps1"
. "$PSScriptRoot\xFACts-DocPipelineFunctions.ps1"

<# ============================================================================
   INITIALIZATION: SCRIPT INITIALIZATION
   ----------------------------------------------------------------------------
   One-time shared setup: SQL module loading, application identity, log path,
   default connection target, and the preview-mode guard. The connection target
   is set from the script's xFACtsServer/xFACtsDB parameters so the shared SQL
   helpers address exactly what those parameters specify.
   Prefix: (none)
   ============================================================================ #>

Initialize-XFActsScript -ScriptName 'Consolidate-UploadFiles' -ServerInstance $xFACtsServer -Database $xFACtsDB -Execute:$Execute

<# ============================================================================
   CONSTANTS: PATHS AND SOURCES
   ----------------------------------------------------------------------------
   Server source roots and the base file-source collection map. Each source
   entry defines a directory, a filename filter, and a human-readable category
   used in console output and the generated manifest.
   Prefix: (none)
   ============================================================================ #>

# Root of the orchestrator PowerShell script tree.
$ScriptsRoot = "E:\xFACts-PowerShell"
# Root of the Control Center application and documentation-site tree.
$CCRoot      = "E:\xFACts-ControlCenter"
# Root of the standalone documentation and planning tree.
$DocsRoot    = "E:\xFACts-Documentation"

# Base file-source map: each entry is a directory, a filter, and a category.
$FileSources = @(
    @{ Source = $ScriptsRoot;                       Filter = "*";                       Description = "Orchestrator scripts" }
    @{ Source = "$CCRoot\scripts";                  Filter = "Start-ControlCenter.ps1"; Description = "Control Center entry point" }
    @{ Source = "$CCRoot\scripts\routes";           Filter = "*.ps1";                   Description = "Control Center routes + APIs" }
    @{ Source = "$CCRoot\scripts\modules";          Filter = "*.psm1";                  Description = "Control Center modules" }
    @{ Source = "$CCRoot\public\css";               Filter = "*.css";                   Description = "Control Center CSS" }
    @{ Source = "$CCRoot\public\js";                Filter = "*.js";                    Description = "Control Center JS" }
    @{ Source = "$CCRoot\public\docs\pages";        Filter = "*.html";                  Description = "Narrative pages" }
    @{ Source = "$CCRoot\public\docs\pages\arch";   Filter = "*.html";                  Description = "Architecture pages" }
    @{ Source = "$CCRoot\public\docs\pages\cc";     Filter = "*.html";                  Description = "Control Center guide pages" }
    @{ Source = "$CCRoot\public\docs\pages\guides"; Filter = "*.html";                  Description = "User guide pages" }
    @{ Source = "$CCRoot\public\docs\images\cc";    Filter = "*.png";                   Description = "Control Center guide screenshots" }
    @{ Source = "$CCRoot\public\docs\pages\ref";    Filter = "*.html";                  Description = "Reference pages" }
    @{ Source = "$CCRoot\public\docs\css";          Filter = "*.css";                   Description = "Documentation CSS" }
    @{ Source = "$CCRoot\public\docs\js";           Filter = "*.js";                    Description = "Documentation JS" }
    @{ Source = "$CCRoot\public\docs\data\md\ref";  Filter = "*.md";                    Description = "Module reference documentation (ref-only md exports)" }
    @{ Source = "$DocsRoot\docs";                   Filter = "*.md";                    Description = "Planning documents" }
)

<# ============================================================================
   EXECUTION: SCRIPT EXECUTION
   ----------------------------------------------------------------------------
   Collects files from each source into the output folder, optionally extracts
   SQL object definitions and JSON data files, exports the Platform Registry
   markdown, writes the manifest, and prints a run summary.
   Prefix: (none)
   ============================================================================ #>

# Append the JSON data-file source when requested.
if ($IncludeJSON) {
    $FileSources += @{ Source = "$CCRoot\public\docs\data\ddl"; Filter = "*.json"; Description = "JSON data files" }
}

# Run-local accumulators: per-file origin records, manifest rows, and counters.
$fileOrigins = @()
$manifest    = @()
$totalFiles  = 0
$totalErrors = 0

# Prepare the output folder: clear its contents on execute, creating it if absent.
if ($Execute) {
    if (Test-Path $OutputPath) {
        Get-ChildItem -Path $OutputPath -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Write-Console "  Cleared existing output folder." 'DarkGray'
    }
    else {
        New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
        Write-Console "  Created output folder." 'DarkGray'
    }
}

# -- File collection --

Write-Console "  File Collection" 'Cyan'
Write-Console "  ---------------" 'Cyan'

foreach ($source in $FileSources) {
    $sourcePath  = $source.Source
    $filter      = $source.Filter
    $description = $source.Description

    if (-not (Test-Path $sourcePath)) {
        Write-Console "    SKIP  $description - path not found" 'DarkGray'
        $manifest += [PSCustomObject]@{ Category = $description; Source = $sourcePath; Count = 0; Status = "PATH NOT FOUND" }
        continue
    }

    $files = Get-ChildItem -Path $sourcePath -Filter $filter -File -ErrorAction SilentlyContinue
    $fileCount = @($files).Count

    if ($fileCount -eq 0) {
        Write-Console "    SKIP  $description - no $filter files" 'DarkGray'
        $manifest += [PSCustomObject]@{ Category = $description; Source = $sourcePath; Count = 0; Status = "EMPTY" }
        continue
    }

    if ($Execute) {
        $copyErrors = 0
        foreach ($file in $files) {
            $destFile = Join-Path $OutputPath $file.Name

            if (Test-Path $destFile) {
                Write-Console "    COLLISION  $($file.Name) - already exists from a different source" 'Red'
                $copyErrors++
                $totalErrors++
                continue
            }

            try {
                Copy-Item -Path $file.FullName -Destination $destFile -ErrorAction Stop
                $fileOrigins += [PSCustomObject]@{ FileName = $file.Name; SourcePath = $sourcePath; Category = $description }
            }
            catch {
                Write-Console "    ERROR  $($file.Name) - $($_.Exception.Message)" 'Red'
                $copyErrors++
                $totalErrors++
            }
        }
        $successCount = $fileCount - $copyErrors
        Write-Console "    OK    $description - $successCount files" 'Green'
    }
    else {
        Write-Console "    FOUND $description - $fileCount files" 'White'
        $fileOrigins += foreach ($file in $files) {
            [PSCustomObject]@{ FileName = $file.Name; SourcePath = $sourcePath; Category = $description }
        }
    }

    $totalFiles += $fileCount
    $manifest += [PSCustomObject]@{ Category = $description; Source = $sourcePath; Count = $fileCount; Status = if ($Execute) { "OK" } else { "PREVIEW" } }
}

# -- SQL object extraction (optional) --

if ($IncludeSQLObjects) {
    Write-Console "" 'Gray'
    Write-Console "  SQL Object Extraction" 'Cyan'
    Write-Console "  ---------------------" 'Cyan'

    $sqlObjects = Get-SqlObjectDefinitions
    $sqlCount = @($sqlObjects).Count

    if ($sqlCount -gt 0) {
        if ($Execute) {
            $sqlErrors = 0
            foreach ($obj in $sqlObjects) {
                $fileName = "$($obj.schema_name).$($obj.object_name).sql"
                $destFile = Join-Path $OutputPath $fileName

                try {
                    $obj.definition | Out-File -FilePath $destFile -Encoding UTF8 -ErrorAction Stop
                    $fileOrigins += [PSCustomObject]@{ FileName = $fileName; SourcePath = "$xFACtsServer/$xFACtsDB"; Category = "SQL: $($obj.type_desc)" }
                }
                catch {
                    Write-Console "    ERROR  $fileName - $($_.Exception.Message)" 'Red'
                    $sqlErrors++
                    $totalErrors++
                }
            }
            $successCount = $sqlCount - $sqlErrors
            Write-Console "    OK    SQL objects - $successCount definitions" 'Green'
        }
        else {
            Write-Console "    FOUND SQL objects - $sqlCount definitions" 'White'
            foreach ($obj in $sqlObjects) {
                Write-Console "          $($obj.schema_name).$($obj.object_name) ($($obj.type_desc))" 'DarkGray'
            }
            $fileOrigins += foreach ($obj in $sqlObjects) {
                [PSCustomObject]@{ FileName = "$($obj.schema_name).$($obj.object_name).sql"; SourcePath = "$xFACtsServer/$xFACtsDB"; Category = "SQL: $($obj.type_desc)" }
            }
        }

        $totalFiles += $sqlCount
        $manifest += [PSCustomObject]@{ Category = "SQL object definitions"; Source = "$xFACtsServer/$xFACtsDB"; Count = $sqlCount; Status = if ($Execute) { "OK" } else { "PREVIEW" } }
    }
    else {
        Write-Console "    SKIP  No SQL objects found" 'DarkGray'
    }
}

# -- Reference table export --

Write-Console "" 'Gray'
Write-Console "  Reference Table Export" 'Cyan'
Write-Console "  ----------------------" 'Cyan'

$registryExport = Get-RegistryExportMarkdown

if ($registryExport.TableCount -gt 0) {
    $registryFile = Join-Path $OutputPath "xFACts_Platform_Registry.md"
    if ($Execute) {
        $registryExport.Markdown | Out-File -FilePath $registryFile -Encoding UTF8
        $fileOrigins += [PSCustomObject]@{ FileName = "xFACts_Platform_Registry.md"; SourcePath = "$xFACtsServer/$xFACtsDB"; Category = "Reference table export" }
        $totalFiles++
        Write-Console "    OK    Platform Registry markdown - $($registryExport.TableCount) tables" 'Green'
    }
    else {
        Write-Console "    FOUND Platform Registry markdown - $($registryExport.TableCount) tables" 'White'
    }
    $manifest += [PSCustomObject]@{ Category = "Reference table export"; Source = "$xFACtsServer/$xFACtsDB"; Count = $registryExport.TableCount; Status = if ($Execute) { "OK" } else { "PREVIEW" } }
}

# -- Write manifest --

if ($Execute) {
    $manifestPath = Join-Path $OutputPath "_manifest.txt"
    $manifestContent = @()
    $manifestContent += "xFACts Upload Consolidation Manifest"
    $manifestContent += "===================================="
    $manifestContent += "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $manifestContent += "Server: $env:COMPUTERNAME"
    $manifestContent += "Total files: $totalFiles"
    if ($totalErrors -gt 0) { $manifestContent += "Errors: $totalErrors" }
    $manifestContent += ""

    $manifestContent += "Server Directory Structure"
    $manifestContent += "-------------------------"
    $manifestContent += "E:\xFACts-PowerShell\                          Orchestrator automation scripts"
    $manifestContent += "E:\xFACts-PowerShell\docs\                     Planning documents (Dev Guidelines, Backlog, etc.)"
    $manifestContent += "E:\xFACts-ControlCenter\scripts\               Control Center entry point (Start-ControlCenter.ps1)"
    $manifestContent += "E:\xFACts-ControlCenter\scripts\routes\        Control Center route pages + API files"
    $manifestContent += "E:\xFACts-ControlCenter\scripts\modules\       Control Center shared modules (xFACts-CCShared.psm1)"
    $manifestContent += "E:\xFACts-ControlCenter\public\css\            Control Center page CSS"
    $manifestContent += "E:\xFACts-ControlCenter\public\js\             Control Center page JS"
    $manifestContent += "E:\xFACts-ControlCenter\public\docs\pages\     Documentation narrative pages (HTML)"
    $manifestContent += "E:\xFACts-ControlCenter\public\docs\pages\arch\  Documentation architecture pages (HTML)"
    $manifestContent += "E:\xFACts-ControlCenter\public\docs\pages\ref\   Documentation reference pages (HTML)"
    $manifestContent += "E:\xFACts-ControlCenter\public\docs\pages\guides\ User guide pages (HTML)"
    $manifestContent += "E:\xFACts-ControlCenter\public\docs\css\       Documentation CSS"
    $manifestContent += "E:\xFACts-ControlCenter\public\docs\js\        Documentation JS (nav.js, ddl-loader.js, ddl-erd.js)"
    $manifestContent += "E:\xFACts-ControlCenter\public\docs\data\ddl\  JSON data files (from sp_GenerateDDLReference)"
    $manifestContent += "E:\xFACts-ControlCenter\public\docs\data\md\     Module documentation markdown exports (full, for team use)"
    $manifestContent += "E:\xFACts-ControlCenter\public\docs\data\md\ref\ Reference-only markdown exports (for project knowledge)"
    $manifestContent += ""

    $manifestContent += "Collection Summary"
    $manifestContent += "------------------"
    foreach ($entry in $manifest) {
        $line = "  {0,-45} {1,4} files  [{2}]" -f $entry.Category, $entry.Count, $entry.Status
        $manifestContent += $line
    }
    $manifestContent += ""

    $manifestContent += "File Origins"
    $manifestContent += "------------"
    $currentSource = ""
    foreach ($origin in ($fileOrigins | Sort-Object SourcePath, FileName)) {
        if ($origin.SourcePath -ne $currentSource) {
            $manifestContent += ""
            $manifestContent += "  $($origin.SourcePath)"
            $currentSource = $origin.SourcePath
        }
        $manifestContent += "    $($origin.FileName)"
    }

    $manifestContent | Out-File -FilePath $manifestPath -Encoding UTF8
}

# -- Summary --

Write-Console "" 'Gray'
Write-Console "  Summary" 'Cyan'
Write-Console "  -------" 'Cyan'
Write-Console "    Total: $totalFiles files" 'White'

if ($totalErrors -gt 0) {
    Write-Console "    Errors: $totalErrors" 'Red'
}

if ($Execute) {
    Write-Console "    Output: $OutputPath" 'Green'
}
else {
    Write-Console "    Run with -Execute to consolidate." 'Yellow'
}

Write-Console "" 'Gray'
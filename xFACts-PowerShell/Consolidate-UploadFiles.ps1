<#
.SYNOPSIS
    Consolidates all xFACts platform files into a single upload-ready folder.

.DESCRIPTION
    xFACts - Upload Consolidation
    Script: Consolidate-UploadFiles.ps1

    Collects all platform files from their various server locations into a single
    flat folder for uploading to Claude as project context. Optionally extracts
    stored procedure/trigger/function definitions from the database and includes
    JSON data files.

    Generates a _manifest.txt with source path mappings so Claude has awareness
    of the server directory structure.

    Designed to be run manually or triggered from the Control Center Admin page.

    CHANGELOG
    ---------
    1.0.0  Initial implementation

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

.EXAMPLE
    .\Consolidate-UploadFiles.ps1
    Preview mode - shows what would be collected without copying.

.EXAMPLE
    .\Consolidate-UploadFiles.ps1 -Execute
    Collects all standard files (no JSON, no SQL objects).

.EXAMPLE
    .\Consolidate-UploadFiles.ps1 -Execute -IncludeJSON -IncludeSQLObjects
    Full collection including JSON data files and extracted SQL definitions.
#>

[CmdletBinding()]
param(
    [string]$OutputPath = "E:\xFACts-Upload",
    [switch]$IncludeJSON,
    [switch]$IncludeSQLObjects,
    [string]$xFACtsServer = "AVG-PROD-LSNR",
    [string]$xFACtsDB = "xFACts",
    [switch]$Execute
)

# ============================================================================
# CONFIGURATION
# ============================================================================

$ScriptsRoot = "E:\xFACts-PowerShell"
$CCRoot      = "E:\xFACts-ControlCenter"

# Source mappings: each entry defines what to collect
$FileSources = @(
    @{ Source = $ScriptsRoot;                            Filter = "*.ps1";  Description = "Orchestrator scripts" }
    @{ Source = "$CCRoot\scripts";                        Filter = "Start-ControlCenter.ps1"; Description = "Control Center entry point" }
    @{ Source = "$CCRoot\scripts\routes";                Filter = "*.ps1";  Description = "Control Center routes + APIs" }
    @{ Source = "$CCRoot\scripts\modules";               Filter = "*.psm1"; Description = "Control Center modules" }
    @{ Source = "$CCRoot\public\css";                    Filter = "*.css";  Description = "Control Center CSS" }
    @{ Source = "$CCRoot\public\js";                     Filter = "*.js";   Description = "Control Center JS" }
    @{ Source = "$CCRoot\public\docs\pages";             Filter = "*.html"; Description = "Narrative pages" }
    @{ Source = "$CCRoot\public\docs\pages\arch";        Filter = "*.html"; Description = "Architecture pages" }
    @{ Source = "$CCRoot\public\docs\pages\cc";          Filter = "*.html"; Description = "Control Center guide pages" }
    @{ Source = "$CCRoot\public\docs\images\cc";          Filter = "*.png";  Description = "Control Center guide screenshots" }
    @{ Source = "$CCRoot\public\docs\pages\ref";         Filter = "*.html"; Description = "Reference pages" }
    @{ Source = "$CCRoot\public\docs\css";               Filter = "*.css";  Description = "Documentation CSS" }
    @{ Source = "$CCRoot\public\docs\js";                Filter = "*.js";   Description = "Documentation JS" }
    @{ Source = "$CCRoot\public\docs\data\md\ref";    Filter = "*.md";   Description = "Module reference documentation (ref-only md exports)" }
    @{ Source = "$ScriptsRoot\docs";                     Filter = "*.md";   Description = "Planning documents" }
)

if ($IncludeJSON) {
    $FileSources += @{ Source = "$CCRoot\public\docs\data\ddl"; Filter = "*.json"; Description = "JSON data files" }
}

# ============================================================================
# PREVIEW / EXECUTE GUARD
# ============================================================================

if (-not $Execute) {
    Write-Host ""
    Write-Host "  PREVIEW MODE - No files will be copied. Run with -Execute to consolidate." -ForegroundColor Yellow
    Write-Host ""
}

# ============================================================================
# PREPARE OUTPUT FOLDER
# ============================================================================

if ($Execute) {
    if (Test-Path $OutputPath) {
        # Clear contents without removing the folder itself (allows Explorer to stay open)
        Get-ChildItem -Path $OutputPath -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "  Cleared existing output folder." -ForegroundColor DarkGray
    } else {
        New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
        Write-Host "  Created output folder." -ForegroundColor DarkGray
    }
}

# ============================================================================
# COLLECT FILES
# ============================================================================

# Track source origin for every file (used in manifest)
$fileOrigins = @()
$manifest = @()
$totalFiles = 0
$totalErrors = 0

Write-Host "  File Collection" -ForegroundColor Cyan
Write-Host "  ---------------" -ForegroundColor Cyan

foreach ($source in $FileSources) {
    $sourcePath = $source.Source
    $filter = $source.Filter
    $description = $source.Description

    if (-not (Test-Path $sourcePath)) {
        Write-Host "    SKIP  $description — path not found" -ForegroundColor DarkGray
        $manifest += [PSCustomObject]@{ Category = $description; Source = $sourcePath; Count = 0; Status = "PATH NOT FOUND" }
        continue
    }

    $files = Get-ChildItem -Path $sourcePath -Filter $filter -File -ErrorAction SilentlyContinue
    $fileCount = @($files).Count

    if ($fileCount -eq 0) {
        Write-Host "    SKIP  $description — no $filter files" -ForegroundColor DarkGray
        $manifest += [PSCustomObject]@{ Category = $description; Source = $sourcePath; Count = 0; Status = "EMPTY" }
        continue
    }

    if ($Execute) {
        $copyErrors = 0
        foreach ($file in $files) {
            $destFile = Join-Path $OutputPath $file.Name

            if (Test-Path $destFile) {
                Write-Host "    COLLISION  $($file.Name) — already exists from a different source" -ForegroundColor Red
                $copyErrors++
                $totalErrors++
                continue
            }

            try {
                Copy-Item -Path $file.FullName -Destination $destFile -ErrorAction Stop
                $fileOrigins += [PSCustomObject]@{ FileName = $file.Name; SourcePath = $sourcePath; Category = $description }
            }
            catch {
                Write-Host "    ERROR  $($file.Name) — $($_.Exception.Message)" -ForegroundColor Red
                $copyErrors++
                $totalErrors++
            }
        }
        $successCount = $fileCount - $copyErrors
        Write-Host "    OK    $description — $successCount files" -ForegroundColor Green
    }
    else {
        Write-Host "    FOUND $description — $fileCount files" -ForegroundColor White
        $fileOrigins += foreach ($file in $files) {
            [PSCustomObject]@{ FileName = $file.Name; SourcePath = $sourcePath; Category = $description }
        }
    }

    $totalFiles += $fileCount
    $manifest += [PSCustomObject]@{ Category = $description; Source = $sourcePath; Count = $fileCount; Status = if ($Execute) { "OK" } else { "PREVIEW" } }
}

# ============================================================================
# OPTIONAL: EXTRACT SQL OBJECT DEFINITIONS
# ============================================================================

if ($IncludeSQLObjects) {
    Write-Host ""
    Write-Host "  SQL Object Extraction" -ForegroundColor Cyan
    Write-Host "  ---------------------" -ForegroundColor Cyan

    $sqlModuleLoaded = $false
    try {
        Import-Module SqlServer -ErrorAction Stop
        $sqlModuleLoaded = $true
    }
    catch {
        try {
            Import-Module SQLPS -DisableNameChecking -ErrorAction Stop
            $sqlModuleLoaded = $true
        }
        catch {
            Write-Host "    ERROR  Cannot load SQL module — skipping extraction" -ForegroundColor Red
            $totalErrors++
        }
    }

    if ($sqlModuleLoaded) {
        $sqlQuery = @"
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

        try {
            $sqlObjects = Invoke-Sqlcmd -ServerInstance $xFACtsServer -Database $xFACtsDB `
                -Query $sqlQuery -QueryTimeout 120 -MaxCharLength 1000000 -ErrorAction Stop `
                -ApplicationName "xFACts Consolidate-UploadFiles" -TrustServerCertificate

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
                            Write-Host "    ERROR  $fileName — $($_.Exception.Message)" -ForegroundColor Red
                            $sqlErrors++
                            $totalErrors++
                        }
                    }
                    $successCount = $sqlCount - $sqlErrors
                    Write-Host "    OK    SQL objects — $successCount definitions" -ForegroundColor Green
                }
                else {
                    Write-Host "    FOUND SQL objects — $sqlCount definitions" -ForegroundColor White
                    foreach ($obj in $sqlObjects) {
                        Write-Host "          $($obj.schema_name).$($obj.object_name) ($($obj.type_desc))" -ForegroundColor DarkGray
                    }
                    $fileOrigins += foreach ($obj in $sqlObjects) {
                        [PSCustomObject]@{ FileName = "$($obj.schema_name).$($obj.object_name).sql"; SourcePath = "$xFACtsServer/$xFACtsDB"; Category = "SQL: $($obj.type_desc)" }
                    }
                }

                $totalFiles += $sqlCount
                $manifest += [PSCustomObject]@{ Category = "SQL object definitions"; Source = "$xFACtsServer/$xFACtsDB"; Count = $sqlCount; Status = if ($Execute) { "OK" } else { "PREVIEW" } }
            }
            else {
                Write-Host "    SKIP  No SQL objects found" -ForegroundColor DarkGray
            }
        }
        catch {
            Write-Host "    ERROR  SQL extraction failed: $($_.Exception.Message)" -ForegroundColor Red
            $totalErrors++
        }
    }
}

# ============================================================================
# EXPORT REFERENCE TABLE DATA
# ============================================================================
# Exports designated table contents to a single markdown file for session context.
# Add entries to $TableExports to include additional tables.
# Each entry needs a Query (returning the desired columns) and a Title.
# ============================================================================

$TableExports = @(
    @{
        Title = "Module Registry"
        Query = "SELECT module_name, description FROM dbo.Module_Registry WHERE is_active = 1 ORDER BY module_name"
    },
    @{
        Title = "Component Registry"
        Query = "SELECT module_name, component_name, description, doc_page_id, doc_title, doc_json_schema, doc_json_categories, doc_sort_order, doc_section_order FROM dbo.Component_Registry WHERE is_active = 1 ORDER BY module_name, component_name"
    },
    @{
        Title = "Object Registry"
        Query = "SELECT component_name, object_name, object_category, object_type, object_path, description FROM dbo.Object_Registry WHERE is_active = 1 ORDER BY component_name, object_category, object_type, object_name"
    },
    @{
        Title = "Global Configuration"
        Query = "SELECT module_name, category, setting_name, setting_value, data_type, description FROM dbo.GlobalConfig WHERE is_active = 1 ORDER BY module_name, category, setting_name"
    }
)

Write-Host ""
Write-Host "  Reference Table Export" -ForegroundColor Cyan
Write-Host "  ----------------------" -ForegroundColor Cyan

# Ensure SQL module is available (may already be loaded from SQL extraction above)
$sqlAvailable = $false
try {
    Import-Module SqlServer -ErrorAction Stop
    $sqlAvailable = $true
} catch {
    try {
        Import-Module SQLPS -DisableNameChecking -ErrorAction Stop
        $sqlAvailable = $true
    } catch {
        Write-Host "    ERROR  Cannot load SQL module — skipping table export" -ForegroundColor Red
        $totalErrors++
    }
}

if ($sqlAvailable) {
    $registryContent = @()
    $registryContent += "# xFACts Platform Registry"
    $registryContent += "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $registryContent += ""
    $exportedTables = 0

    foreach ($export in $TableExports) {
        try {
            $rows = Invoke-Sqlcmd -ServerInstance $xFACtsServer -Database $xFACtsDB `
                -Query $export.Query -QueryTimeout 60 -ErrorAction Stop `
                -ApplicationName "xFACts Consolidate-UploadFiles" -TrustServerCertificate

            $rowCount = @($rows).Count
            if ($rowCount -eq 0) {
                Write-Host "    SKIP  $($export.Title) — no rows" -ForegroundColor DarkGray
                continue
            }

            # Build markdown table from query results
            $registryContent += "## $($export.Title)"
            $registryContent += ""

            # Get column names from the first row (exclude RowError/Table/etc. system properties)
            $columns = $rows[0].PSObject.Properties |
                Where-Object { $_.Name -notin @('RowError','RowState','Table','ItemArray','HasErrors') } |
                ForEach-Object { $_.Name }

            # Header row
            $registryContent += "| " + ($columns -join " | ") + " |"
            $registryContent += "| " + (($columns | ForEach-Object { "---" }) -join " | ") + " |"

            # Data rows
            foreach ($row in $rows) {
                $values = foreach ($col in $columns) {
                    $val = $row.$col
                    if ($null -eq $val -or $val -is [DBNull]) { "" }
                    else { [string]$val -replace '\|', '\|' -replace '\r?\n', ' ' }
                }
                $registryContent += "| " + ($values -join " | ") + " |"
            }

            $registryContent += ""
            $exportedTables++

            if ($Execute) {
                Write-Host "    OK    $($export.Title) — $rowCount rows" -ForegroundColor Green
            } else {
                Write-Host "    FOUND $($export.Title) — $rowCount rows" -ForegroundColor White
            }
        }
        catch {
            Write-Host "    ERROR  $($export.Title) — $($_.Exception.Message)" -ForegroundColor Red
            $totalErrors++
        }
    }

    if ($exportedTables -gt 0) {
        $registryFile = Join-Path $OutputPath "xFACts_Platform_Registry.md"
        if ($Execute) {
            $registryContent | Out-File -FilePath $registryFile -Encoding UTF8
            $fileOrigins += [PSCustomObject]@{ FileName = "xFACts_Platform_Registry.md"; SourcePath = "$xFACtsServer/$xFACtsDB"; Category = "Reference table export" }
            $totalFiles++
        }
        $manifest += [PSCustomObject]@{ Category = "Reference table export"; Source = "$xFACtsServer/$xFACtsDB"; Count = $exportedTables; Status = if ($Execute) { "OK" } else { "PREVIEW" } }
    }
}

# ============================================================================
# WRITE MANIFEST
# ============================================================================

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

    # Section 1: Directory structure map
    $manifestContent += "Server Directory Structure"
    $manifestContent += "-------------------------"
    $manifestContent += "E:\xFACts-PowerShell\                          Orchestrator automation scripts"
    $manifestContent += "E:\xFACts-PowerShell\docs\                     Planning documents (Dev Guidelines, Backlog, etc.)"
    $manifestContent += "E:\xFACts-ControlCenter\scripts\               Control Center entry point (Start-ControlCenter.ps1)"
    $manifestContent += "E:\xFACts-ControlCenter\scripts\routes\        Control Center route pages + API files"
    $manifestContent += "E:\xFACts-ControlCenter\scripts\modules\       Control Center shared modules (xFACts-Helpers.psm1)"
    $manifestContent += "E:\xFACts-ControlCenter\public\css\            Control Center page CSS"
    $manifestContent += "E:\xFACts-ControlCenter\public\js\             Control Center page JS"
    $manifestContent += "E:\xFACts-ControlCenter\public\docs\pages\     Documentation narrative pages (HTML)"
    $manifestContent += "E:\xFACts-ControlCenter\public\docs\pages\arch\  Documentation architecture pages (HTML)"
    $manifestContent += "E:\xFACts-ControlCenter\public\docs\pages\ref\   Documentation reference pages (HTML)"
    $manifestContent += "E:\xFACts-ControlCenter\public\docs\css\       Documentation CSS"
    $manifestContent += "E:\xFACts-ControlCenter\public\docs\js\        Documentation JS (nav.js, ddl-loader.js, ddl-erd.js)"
    $manifestContent += "E:\xFACts-ControlCenter\public\docs\data\ddl\  JSON data files (from sp_GenerateDDLReference)"
    $manifestContent += "E:\xFACts-ControlCenter\public\docs\data\md\     Module documentation markdown exports (full, for team use)"
    $manifestContent += "E:\xFACts-ControlCenter\public\docs\data\md\ref\ Reference-only markdown exports (for Claude project knowledge)"
    $manifestContent += ""

    # Section 2: Category summary with counts
    $manifestContent += "Collection Summary"
    $manifestContent += "------------------"
    foreach ($entry in $manifest) {
        $line = "  {0,-45} {1,4} files  [{2}]" -f $entry.Category, $entry.Count, $entry.Status
        $manifestContent += $line
    }
    $manifestContent += ""

    # Section 3: Every file with its source path
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

# ============================================================================
# SUMMARY
# ============================================================================

Write-Host ""
Write-Host "  Summary" -ForegroundColor Cyan
Write-Host "  -------" -ForegroundColor Cyan
Write-Host "    Total: $totalFiles files"

if ($totalErrors -gt 0) {
    Write-Host "    Errors: $totalErrors" -ForegroundColor Red
}

if ($Execute) {
    Write-Host "    Output: $OutputPath" -ForegroundColor Green
}
else {
    Write-Host "    Run with -Execute to consolidate." -ForegroundColor Yellow
}

Write-Host ""
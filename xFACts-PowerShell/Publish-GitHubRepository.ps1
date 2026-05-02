<#
.SYNOPSIS
    xFACts - GitHub Repository Publisher

.DESCRIPTION
    xFACts - GitHub Integration
    Script: Publish-GitHubRepository.ps1
    Version: Tracked in dbo.System_Metadata (component: Engine.SharedInfrastructure)

    Publishes all xFACts platform files to a GitHub repository via the REST API.
    Maintains a complete, current snapshot of the platform: PowerShell scripts,
    Control Center files, documentation, SQL object definitions, and generated
    reference data.

    Designed to run standalone or as a step in the Invoke-DocPipeline.ps1 pipeline.

    WORKFLOW
    --------
    1. Collect file inventory from server source directories
    2. Extract SQL object definitions from the database
    3. Generate Platform Registry markdown from registry tables
    4. Audit collected files against Object_Registry
    5. Fetch current repo state (file listing with SHAs)
    6. Compare local vs remote - identify creates, updates, deletes
    7. Push changes to GitHub via Contents API
    8. Generate and push manifest.json (enriched with module/component)
    9. Report summary

    CHANGELOG
    ---------
    2026-04-04  Segmented manifest into sub-manifests by category.
                Master manifest.json is now a lightweight index with
                links to category sub-manifests (cc-app, cc-docs,
                powershell, sql, documentation).
    2026-04-02  Added Object_Registry audit phase with path validation.
                Manifest entries now include module_name and component_name
                from Object_Registry. Unregistered files logged as warnings.
                Audit exclusions: Planning docs, standalone docs, generated
                DDL JSON, Legacy schema SQL objects.
    2026-04-01  Initial implementation

.PARAMETER Owner
    GitHub repository owner. Default: tnjazzgrass

.PARAMETER Repo
    GitHub repository name. Default: xFACts

.PARAMETER Branch
    Target branch. Default: main

.PARAMETER ServiceName
    Credential service name in dbo.Credentials. Default: GitHub_xFACts

.PARAMETER xFACtsServer
    SQL Server instance for SQL object extraction and registry queries.
    Default: AVG-PROD-LSNR

.PARAMETER xFACtsDB
    Database name. Default: xFACts

.PARAMETER Execute
    Required to actually push changes. Without this, runs in preview mode.

.EXAMPLE
    .\Publish-GitHubRepository.ps1
    Preview mode - shows what would be pushed without making changes.

.EXAMPLE
    .\Publish-GitHubRepository.ps1 -Execute
    Full push to GitHub repository.
#>

[CmdletBinding()]
param(
    [string]$Owner = "tnjazzgrass",
    [string]$Repo = "xFACts",
    [string]$Branch = "main",
    [string]$ServiceName = "GitHub_xFACts",
    [string]$xFACtsServer = "AVG-PROD-LSNR",
    [string]$xFACtsDB = "xFACts",
    [switch]$Execute
)

# ============================================================================
# INITIALIZATION
# ============================================================================

. "$PSScriptRoot\xFACts-OrchestratorFunctions.ps1"
$script:Config = Initialize-XFActsScript -ScriptName 'Publish-GitHubRepository' -Execute:$Execute
if (-not $script:Config -and -not $Execute) {
    # Preview mode - Initialize-XFActsScript displays the warning but returns $null
    # We still want to continue in preview mode, so don't exit
}

# Force TLS 1.2 for GitHub API connectivity
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ============================================================================
# CONFIGURATION - Source Mappings
# ============================================================================
# Each entry maps a server directory to a repository path.
# Filter controls which files are collected from that directory.
# Recurse controls whether subdirectories are included.

$ScriptsRoot = "E:\xFACts-PowerShell"
$CCRoot      = "E:\xFACts-ControlCenter"
$DocsRoot    = "E:\xFACts-Documentation"

$FileSources = @(
    # --- PowerShell scripts (flat) ---
    @{
        ServerPath = $ScriptsRoot
        RepoPath   = "xFACts-PowerShell"
        Filter     = @("*.ps1", "*.js", "*.psm1")
        Recurse    = $false
        Description = "Orchestrator scripts"
    }

    # --- Control Center (full tree) ---
    @{
        ServerPath = "$CCRoot\scripts"
        RepoPath   = "xFACts-ControlCenter/scripts"
        Filter     = @("*.ps1", "*.psm1", "*.psd1")
        Recurse    = $true
        Description = "Control Center scripts, routes, modules"
    }
    @{
        ServerPath = "$CCRoot\public\css"
        RepoPath   = "xFACts-ControlCenter/public/css"
        Filter     = @("*.css")
        Recurse    = $false
        Description = "Control Center CSS"
    }
    @{
        ServerPath = "$CCRoot\public\js"
        RepoPath   = "xFACts-ControlCenter/public/js"
        Filter     = @("*.js")
        Recurse    = $false
        Description = "Control Center JS"
    }
    @{
        ServerPath = "$CCRoot\public\docs\pages"
        RepoPath   = "xFACts-ControlCenter/public/docs/pages"
        Filter     = @("*.html")
        Recurse    = $true
        Description = "Documentation HTML pages (narrative, arch, ref, cc, guides)"
    }
    @{
        ServerPath = "$CCRoot\public\docs\css"
        RepoPath   = "xFACts-ControlCenter/public/docs/css"
        Filter     = @("*.css")
        Recurse    = $false
        Description = "Documentation CSS"
    }
    @{
        ServerPath = "$CCRoot\public\docs\js"
        RepoPath   = "xFACts-ControlCenter/public/docs/js"
        Filter     = @("*.js")
        Recurse    = $false
        Description = "Documentation JS"
    }
    @{
        ServerPath = "$CCRoot\public\docs\data\ddl"
        RepoPath   = "xFACts-ControlCenter/public/docs/data/ddl"
        Filter     = @("*.json")
        Recurse    = $false
        Description = "Schema JSON data files"
    }
    @{
        ServerPath = "$CCRoot\public\docs\images\cc"
        RepoPath   = "xFACts-ControlCenter/public/docs/images/cc"
        Filter     = @("*.png")
        Recurse    = $false
        Description = "CC guide screenshots"
    }

    # --- Documentation (standalone docs and planning) ---
    @{
        ServerPath = "$DocsRoot\docs"
        RepoPath   = "xFACts-Documentation"
        Filter     = @("*.md")
        Recurse    = $false
        Description = "Platform documentation (Guidelines, Backlog)"
    }
    @{
        ServerPath = "$DocsRoot\Planning"
        RepoPath   = "xFACts-Documentation/Planning"
        Filter     = @("*.md")
        Recurse    = $false
        Description = "Planning documents (working docs, roadmaps)"
    }
    @{
        ServerPath = "$DocsRoot\WorkingFiles"
        RepoPath   = "xFACts-Documentation/WorkingFiles"
        Filter     = @("*.*")
        Recurse    = $true
        Description = "Working reference files for active builds"
    }
)

# Track generated file paths so orphan cleanup doesn't delete them
$GeneratedRepoPaths = [System.Collections.Generic.HashSet[string]]::new()
$GeneratedRepoPaths.Add("manifest-cc-app.json")
$GeneratedRepoPaths.Add("manifest-cc-docs.json")
$GeneratedRepoPaths.Add("manifest-powershell.json")
$GeneratedRepoPaths.Add("manifest-sql.json")
$GeneratedRepoPaths.Add("manifest-documentation.json")

# ============================================================================
# GITHUB API FUNCTIONS
# ============================================================================

function Get-GitHubHeaders {
    param([string]$Token)
    return @{
        "Authorization"       = "Bearer $Token"
        "Accept"              = "application/vnd.github+json"
        "User-Agent"          = "xFACts-Publisher/1.0"
        "X-GitHub-Api-Version" = "2022-11-28"
    }
}

function Get-RepoTree {
    <#
    .SYNOPSIS
        Retrieves the full repository file tree with SHAs using the Git Trees API.
        Returns a hashtable of path -> SHA for every file (blob) in the repo.
    #>
    param(
        [string]$Owner,
        [string]$Repo,
        [string]$Branch,
        [hashtable]$Headers
    )

    $uri = "https://api.github.com/repos/$Owner/$Repo/git/trees/${Branch}?recursive=1"

    try {
        $response = Invoke-RestMethod -Uri $uri -Headers $Headers -Method Get -TimeoutSec 30
        $fileMap = @{}

        foreach ($item in $response.tree) {
            if ($item.type -eq "blob") {
                $fileMap[$item.path] = $item.sha
            }
        }

        return $fileMap
    }
    catch {
        Write-Log "Failed to retrieve repo tree: $($_.Exception.Message)" "ERROR"
        return $null
    }
}

function Push-GitHubFile {
    <#
    .SYNOPSIS
        Creates or updates a single file in the repository via the Contents API.
        Requires the file's current SHA for updates (null for creates).
    #>
    param(
        [string]$Owner,
        [string]$Repo,
        [string]$Branch,
        [hashtable]$Headers,
        [string]$RepoPath,
        [byte[]]$ContentBytes,
        [string]$CommitMessage,
        [string]$ExistingSha = $null
    )

    $uri = "https://api.github.com/repos/$Owner/$Repo/contents/$RepoPath"

    $body = @{
        message = $CommitMessage
        content = [Convert]::ToBase64String($ContentBytes)
        branch  = $Branch
    }

    if ($ExistingSha) {
        $body.sha = $ExistingSha
    }

    $jsonBody = $body | ConvertTo-Json -Compress

    try {
        $response = Invoke-RestMethod -Uri $uri -Headers $Headers -Method Put `
            -Body $jsonBody -ContentType "application/json; charset=utf-8" -TimeoutSec 30
        return $response
    }
    catch {
        $statusCode = $null
        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }
        Write-Log "  FAILED  $RepoPath (HTTP $statusCode): $($_.Exception.Message)" "ERROR"
        return $null
    }
}

function Remove-GitHubFile {
    <#
    .SYNOPSIS
        Deletes a file from the repository via the Contents API.
        Requires the file's current SHA.
    #>
    param(
        [string]$Owner,
        [string]$Repo,
        [string]$Branch,
        [hashtable]$Headers,
        [string]$RepoPath,
        [string]$Sha,
        [string]$CommitMessage
    )

    $uri = "https://api.github.com/repos/$Owner/$Repo/contents/$RepoPath"

    $body = @{
        message = $CommitMessage
        sha     = $Sha
        branch  = $Branch
    } | ConvertTo-Json -Compress

    try {
        $response = Invoke-RestMethod -Uri $uri -Headers $Headers -Method Delete `
            -Body $body -ContentType "application/json; charset=utf-8" -TimeoutSec 30
        return $true
    }
    catch {
        Write-Log "  FAILED  DELETE $RepoPath : $($_.Exception.Message)" "ERROR"
        return $false
    }
}

function Get-GitBlobSha {
    <#
    .SYNOPSIS
        Computes the git blob SHA1 hash for file content.
        Git uses: SHA1("blob <size>\0<content>")
        This allows comparing local content to remote SHAs without downloading.
    #>
    param([byte[]]$ContentBytes)

    $header = [System.Text.Encoding]::ASCII.GetBytes("blob $($ContentBytes.Length)`0")
    $fullContent = New-Object byte[] ($header.Length + $ContentBytes.Length)
    [Array]::Copy($header, 0, $fullContent, 0, $header.Length)
    [Array]::Copy($ContentBytes, 0, $fullContent, $header.Length, $ContentBytes.Length)

    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    $hashBytes = $sha1.ComputeHash($fullContent)
    $sha1.Dispose()

    return [BitConverter]::ToString($hashBytes).Replace("-", "").ToLower()
}

# ============================================================================
# PHASE 1: RETRIEVE CREDENTIALS
# ============================================================================

Write-Log "=========================================="
Write-Log "xFACts GitHub Repository Publisher"
Write-Log "=========================================="
Write-Log "Repository: $Owner/$Repo (branch: $Branch)"
Write-Log "Mode: $(if ($Execute) { 'EXECUTE' } else { 'PREVIEW' })"
Write-Log "------------------------------------------"

Write-Log "Retrieving GitHub credentials..."

$creds = Get-ServiceCredentials -ServiceName $ServiceName
if (-not $creds -or -not $creds.PersonalAccessToken) {
    Write-Log "Failed to retrieve GitHub credentials for service '$ServiceName'" "ERROR"
    exit 1
}

$token = $creds.PersonalAccessToken
$headers = Get-GitHubHeaders -Token $token

# Validate connectivity and authentication
try {
    $rateCheck = Invoke-RestMethod -Uri "https://api.github.com/rate_limit" `
        -Headers $headers -Method Get -TimeoutSec 10
    $remaining = $rateCheck.rate.remaining
    $limit = $rateCheck.rate.limit
    Write-Log "API authenticated. Rate limit: $remaining / $limit remaining" "SUCCESS"

    if ($remaining -lt 100) {
        Write-Log "Rate limit is low ($remaining remaining). Large pushes may fail." "WARN"
    }
}
catch {
    Write-Log "GitHub API authentication failed: $($_.Exception.Message)" "ERROR"
    Write-Log "Verify the PAT in dbo.Credentials (ServiceName: $ServiceName)" "ERROR"
    exit 1
}

# ============================================================================
# PHASE 2: COLLECT LOCAL FILES
# ============================================================================

Write-Log ""
Write-Log "Phase 2: Collecting local files"
Write-Log "-------------------------------"

# Hashtable of repoPath -> @{ ContentBytes, Source }
$localFiles = @{}

foreach ($source in $FileSources) {
    $serverPath = $source.ServerPath

    if (-not (Test-Path $serverPath)) {
        Write-Log "  SKIP  $($source.Description) - path not found: $serverPath" "WARN"
        continue
    }

    $fileCount = 0

    foreach ($filter in $source.Filter) {
        $params = @{
            Path        = $serverPath
            Filter      = $filter
            File        = $true
            ErrorAction = 'SilentlyContinue'
        }
        if ($source.Recurse) {
            $params.Recurse = $true
        }

        $files = Get-ChildItem @params

        foreach ($file in $files) {
            # Build repo path: base repo path + relative path from server source
            if ($source.Recurse) {
                $relativePath = $file.FullName.Substring($serverPath.Length).TrimStart('\') -replace '\\', '/'
                $repoPath = "$($source.RepoPath)/$relativePath"
            }
            else {
                $repoPath = "$($source.RepoPath)/$($file.Name)"
            }

            $contentBytes = [System.IO.File]::ReadAllBytes($file.FullName)
            # Strip UTF-8 BOM if present (0xEF, 0xBB, 0xBF)
            if ($contentBytes.Length -ge 3 -and $contentBytes[0] -eq 0xEF -and $contentBytes[1] -eq 0xBB -and $contentBytes[2] -eq 0xBF) {
                $contentBytes = $contentBytes[3..($contentBytes.Length - 1)]
            }
            $localFiles[$repoPath] = @{
                ContentBytes = $contentBytes
                Source       = $file.FullName
            }
            $fileCount++
        }
    }

    Write-Log "  OK    $($source.Description) - $fileCount files" "SUCCESS"
}

Write-Log "  Total files from disk: $($localFiles.Count)"

# ============================================================================
# PHASE 3: EXTRACT SQL OBJECT DEFINITIONS
# ============================================================================

Write-Log ""
Write-Log "Phase 3: Extracting SQL object definitions"
Write-Log "-------------------------------------------"

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

$sqlObjects = Get-SqlData -Query $sqlQuery -Timeout 120 -MaxCharLength 1000000
$sqlCount = 0

if ($sqlObjects) {
    foreach ($obj in @($sqlObjects)) {
        $fileName = "$($obj.schema_name).$($obj.object_name).sql"
        $repoPath = "xFACts-SQL/$fileName"
        $contentBytes = [System.Text.Encoding]::UTF8.GetBytes($obj.definition)

        $localFiles[$repoPath] = @{
            ContentBytes = $contentBytes
            Source       = "SQL:$($obj.schema_name).$($obj.object_name)"
        }
        $GeneratedRepoPaths.Add($repoPath)
        $sqlCount++
    }
    Write-Log "  OK    SQL object definitions - $sqlCount extracted" "SUCCESS"
}
else {
    Write-Log "  WARN  No SQL objects extracted" "WARN"
}

# ============================================================================
# PHASE 4: GENERATE PLATFORM REGISTRY
# ============================================================================

Write-Log ""
Write-Log "Phase 4: Generating Platform Registry"
Write-Log "--------------------------------------"

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

$registryContent = @()
$registryContent += "# xFACts Platform Registry"
$registryContent += "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
$registryContent += ""
$exportedTables = 0

foreach ($export in $TableExports) {
    try {
        $rows = Get-SqlData -Query $export.Query -Timeout 60

        $rowCount = @($rows).Count
        if ($rowCount -eq 0) {
            Write-Log "  SKIP  $($export.Title) - no rows"
            continue
        }

        $registryContent += "## $($export.Title)"
        $registryContent += ""

        # Get column names (exclude system properties from DataRow)
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
        Write-Log "  OK    $($export.Title) - $rowCount rows" "SUCCESS"
    }
    catch {
        Write-Log "  ERROR  $($export.Title) - $($_.Exception.Message)" "ERROR"
    }
}

if ($exportedTables -gt 0) {
    $registryText = $registryContent -join "`n"
    $registryBytes = [System.Text.Encoding]::UTF8.GetBytes($registryText)
    $registryRepoPath = "xFACts-Documentation/xFACts_Platform_Registry.md"

    $localFiles[$registryRepoPath] = @{
        ContentBytes = $registryBytes
        Source       = "Generated:PlatformRegistry"
    }
    $GeneratedRepoPaths.Add($registryRepoPath)
    Write-Log "  OK    Platform Registry - $exportedTables tables exported" "SUCCESS"
}

# ============================================================================
# PHASE 5: AUDIT FILES AGAINST OBJECT_REGISTRY
# ============================================================================
# Query Object_Registry to build a lookup by filename. Validates that every
# file being published has a corresponding registry entry, and that registry
# paths match actual source paths. Also validates SQL objects exist in the
# registry. Results are used in Phase 8 to enrich manifest entries with
# module_name and component_name.

Write-Log ""
Write-Log "Phase 5: Object_Registry audit"
Write-Log "---------------------------------"

$registryQuery = @"
    SELECT 
        r.object_name,
        r.object_path,
        r.object_category,
        r.object_type,
        r.module_name,
        r.component_name
    FROM dbo.Object_Registry r
    WHERE r.is_active = 1
"@

$registryRows = Get-SqlData -Query $registryQuery -Timeout 60

# Build lookup by object_name (filename) -> registry entry
# Some filenames may appear in multiple components (unlikely but possible)
$registryLookup = @{}
if ($registryRows) {
    foreach ($row in @($registryRows)) {
        $name = $row.object_name
        if (-not $registryLookup.ContainsKey($name)) {
            $registryLookup[$name] = @()
        }
        $registryLookup[$name] += @{
            object_path     = if ($row.object_path -is [DBNull]) { $null } else { [string]$row.object_path }
            object_category = [string]$row.object_category
            object_type     = [string]$row.object_type
            module_name     = if ($row.module_name -is [DBNull]) { $null } else { [string]$row.module_name }
            component_name  = if ($row.component_name -is [DBNull]) { $null } else { [string]$row.component_name }
        }
    }
    Write-Log "  Object_Registry: $($registryLookup.Count) unique objects loaded"
}
else {
    Write-Log "  WARN  Could not load Object_Registry" "WARN"
}

# Audit each collected file against the registry
$auditMatched = 0
$auditUnregistered = 0
$auditPathMismatch = 0
$unregisteredFiles = @()
$pathMismatches = @()

# Build a manifest enrichment lookup: repoPath -> { module_name, component_name }
$manifestEnrichment = @{}

foreach ($repoPath in $localFiles.Keys) {
    $entry = $localFiles[$repoPath]
    $fileName = $repoPath.Split('/')[-1]
    $sourcePath = $entry.Source

    # Skip generated files (Platform Registry, manifest) - they aren't registered objects
    if ($sourcePath -like "Generated:*") { continue }

    # Skip files excluded from registry audit by convention
    # Planning/working docs: transient session documents, not platform objects
    if ($repoPath -like "xFACts-Documentation/Planning/*") { continue }
    if ($repoPath -like "xFACts-Documentation/WorkingFiles/*") { continue }
    # Standalone documentation files (Guidelines, Backlog, working docs): reference documents, not module objects
    if ($repoPath -like "xFACts-Documentation/*.md") { continue }
    # Generated DDL JSON data files: output of Generate-DDLReference.ps1, not authored objects
    if ($repoPath -like "xFACts-ControlCenter/public/docs/data/ddl/*.json") { continue }

    # SQL objects: match by schema.objectname pattern
    if ($sourcePath -like "SQL:*") {
        $sqlIdentifier = $sourcePath.Substring(4)  # Remove "SQL:" prefix
        $parts = $sqlIdentifier.Split('.')
        # Skip Legacy schema objects - deprecated, not tracked
        if ($parts.Count -ge 1 -and $parts[0] -eq 'Legacy') { continue }
        if ($parts.Count -eq 2) {
            $schemaName = $parts[0]
            $objectName = $parts[1]
            # Look for the object by its actual name (without schema prefix)
            if ($registryLookup.ContainsKey($objectName)) {
                $regEntry = $registryLookup[$objectName] | Where-Object { $_.object_category -eq 'Database' } | Select-Object -First 1
                if ($regEntry) {
                    $auditMatched++
                    $manifestEnrichment[$repoPath] = @{
                        module_name    = $regEntry.module_name
                        component_name = $regEntry.component_name
                    }
                }
                else {
                    $auditUnregistered++
                    $unregisteredFiles += $repoPath
                }
            }
            # Also try schema.objectname as the lookup key
            elseif ($registryLookup.ContainsKey($sqlIdentifier)) {
                $regEntry = $registryLookup[$sqlIdentifier][0]
                $auditMatched++
                $manifestEnrichment[$repoPath] = @{
                    module_name    = $regEntry.module_name
                    component_name = $regEntry.component_name
                }
            }
            else {
                $auditUnregistered++
                $unregisteredFiles += $repoPath
            }
        }
        continue
    }

    # File-based objects: match by filename
    if ($registryLookup.ContainsKey($fileName)) {
        $regEntry = $registryLookup[$fileName][0]
        $auditMatched++
        $manifestEnrichment[$repoPath] = @{
            module_name    = $regEntry.module_name
            component_name = $regEntry.component_name
        }

        # Path validation: compare registry object_path to actual source path
        if ($regEntry.object_path) {
            $registryPathNormalized = $regEntry.object_path.TrimEnd('\') -replace '/', '\'
            $sourcePathNormalized = $sourcePath.TrimEnd('\') -replace '/', '\'
            if ($registryPathNormalized -ne $sourcePathNormalized) {
                $auditPathMismatch++
                $pathMismatches += @{
                    File         = $fileName
                    RegistryPath = $regEntry.object_path
                    ActualPath   = $sourcePath
                }
            }
        }
    }
    else {
        $auditUnregistered++
        $unregisteredFiles += $repoPath
    }
}

Write-Log "  Matched:      $auditMatched files"

if ($auditUnregistered -gt 0) {
    Write-Log "  Unregistered: $auditUnregistered files" "WARN"
    foreach ($f in $unregisteredFiles) {
        Write-Log "    MISSING  $f" "WARN"
    }
}
else {
    Write-Log "  Unregistered: 0" "SUCCESS"
}

if ($auditPathMismatch -gt 0) {
    Write-Log "  Path mismatches: $auditPathMismatch" "WARN"
    foreach ($m in $pathMismatches) {
        Write-Log "    MISMATCH  $($m.File)" "WARN"
        Write-Log "      Registry: $($m.RegistryPath)" "WARN"
        Write-Log "      Actual:   $($m.ActualPath)" "WARN"
    }
}

# Track whether audit found issues (used for exit code)
$auditHasWarnings = ($auditUnregistered -gt 0 -or $auditPathMismatch -gt 0)

# ============================================================================
# PHASE 6: FETCH REMOTE STATE AND COMPUTE DIFF
# ============================================================================

Write-Log ""
Write-Log "Phase 6: Computing repository diff"
Write-Log "-----------------------------------"

$remoteTree = Get-RepoTree -Owner $Owner -Repo $Repo -Branch $Branch -Headers $headers
if ($null -eq $remoteTree) {
    Write-Log "Failed to retrieve repository tree. Cannot continue." "ERROR"
    exit 1
}

Write-Log "  Remote files: $($remoteTree.Count)"
Write-Log "  Local files:  $($localFiles.Count)"

# Classify each local file as CREATE or UPDATE (by comparing git blob SHA)
$toCreate = @()
$toUpdate = @()
$unchanged = 0

foreach ($repoPath in $localFiles.Keys) {
    $entry = $localFiles[$repoPath]
    $localSha = Get-GitBlobSha -ContentBytes $entry.ContentBytes

    if ($remoteTree.ContainsKey($repoPath)) {
        $remoteSha = $remoteTree[$repoPath]
        if ($localSha -ne $remoteSha) {
            $toUpdate += @{
                RepoPath     = $repoPath
                ContentBytes = $entry.ContentBytes
                ExistingSha  = $remoteSha
                Source       = $entry.Source
            }
        }
        else {
            $unchanged++
        }
    }
    else {
        $toCreate += @{
            RepoPath     = $repoPath
            ContentBytes = $entry.ContentBytes
            Source       = $entry.Source
        }
    }
}

# Identify orphans: files in the repo that are not in the local set
# Only consider files under our managed prefixes
$managedPrefixes = @("xFACts-PowerShell/", "xFACts-ControlCenter/", "xFACts-Documentation/", "xFACts-SQL/")

$toDelete = @()
foreach ($remotePath in $remoteTree.Keys) {
    $isManaged = $false
    foreach ($prefix in $managedPrefixes) {
        if ($remotePath.StartsWith($prefix)) {
            $isManaged = $true
            break
        }
    }

    if (-not $isManaged) { continue }

    if (-not $localFiles.ContainsKey($remotePath)) {
        $toDelete += @{
            RepoPath = $remotePath
            Sha      = $remoteTree[$remotePath]
        }
    }
}

Write-Log ""
Write-Log "  Diff Summary:"
Write-Log "    Create:    $($toCreate.Count) new files"
Write-Log "    Update:    $($toUpdate.Count) changed files"
Write-Log "    Delete:    $($toDelete.Count) orphaned files"
Write-Log "    Unchanged: $unchanged files"

if ($toCreate.Count -eq 0 -and $toUpdate.Count -eq 0 -and $toDelete.Count -eq 0) {
    Write-Log ""
    Write-Log "Repository is already current. Nothing to push." "SUCCESS"
}

# ============================================================================
# PHASE 7: PUSH CHANGES TO GITHUB
# ============================================================================

if ($toCreate.Count -gt 0 -or $toUpdate.Count -gt 0 -or $toDelete.Count -gt 0) {
    Write-Log ""
    Write-Log "Phase 7: Pushing changes to GitHub"
    Write-Log "----------------------------------"

    $pushErrors = 0
    $pushSuccess = 0

    if (-not $Execute) {
        Write-Log ""
        Write-Log "  PREVIEW - Changes that would be made:" "WARN"
        foreach ($item in $toCreate) {
            Write-Log "    CREATE  $($item.RepoPath)"
        }
        foreach ($item in $toUpdate) {
            Write-Log "    UPDATE  $($item.RepoPath)"
        }
        foreach ($item in $toDelete) {
            Write-Log "    DELETE  $($item.RepoPath)"
        }
    }
    else {
        # Process creates
        foreach ($item in $toCreate) {
            $result = Push-GitHubFile -Owner $Owner -Repo $Repo -Branch $Branch -Headers $headers `
                -RepoPath $item.RepoPath -ContentBytes $item.ContentBytes `
                -CommitMessage "Add $($item.RepoPath)"

            if ($result) {
                Write-Log "  CREATE  $($item.RepoPath)" "SUCCESS"
                $pushSuccess++
            }
            else {
                $pushErrors++
            }

            # Brief pause to respect API rate limits
            Start-Sleep -Milliseconds 100
        }

        # Process updates
        foreach ($item in $toUpdate) {
            $result = Push-GitHubFile -Owner $Owner -Repo $Repo -Branch $Branch -Headers $headers `
                -RepoPath $item.RepoPath -ContentBytes $item.ContentBytes `
                -CommitMessage "Update $($item.RepoPath)" `
                -ExistingSha $item.ExistingSha

            if ($result) {
                Write-Log "  UPDATE  $($item.RepoPath)" "SUCCESS"
                $pushSuccess++
            }
            else {
                $pushErrors++
            }

            Start-Sleep -Milliseconds 100
        }

        # Process deletes
        foreach ($item in $toDelete) {
            $result = Remove-GitHubFile -Owner $Owner -Repo $Repo -Branch $Branch -Headers $headers `
                -RepoPath $item.RepoPath -Sha $item.Sha `
                -CommitMessage "Remove orphaned file $($item.RepoPath)"

            if ($result) {
                Write-Log "  DELETE  $($item.RepoPath)" "SUCCESS"
                $pushSuccess++
            }
            else {
                $pushErrors++
            }

            Start-Sleep -Milliseconds 100
        }

        Write-Log ""
        Write-Log "  Push complete: $pushSuccess succeeded, $pushErrors failed"

        if ($pushErrors -gt 0) {
            Write-Log "  Some files failed to push. Check errors above." "WARN"
        }
    }
}

# ============================================================================
# PHASE 8: GENERATE AND PUSH SEGMENTED MANIFESTS
# ============================================================================
# Generates category-specific sub-manifests and a master index manifest.
# The master manifest contains only metadata and URLs to sub-manifests.
# Each sub-manifest contains the actual file entries for its category.
# This prevents fetch truncation as the repository grows.

Write-Log ""
Write-Log "Phase 8: Generating segmented manifests"
Write-Log "---------------------------------------"

$baseRawUrl = "https://raw.githubusercontent.com/$Owner/$Repo/$Branch"
$cacheBuster = (Get-Date).ToUniversalTime().ToString("yyyyMMddHHmmss")
$generatedTimestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

# -- Classify files into sub-manifest categories ----------------------------
# ControlCenter is split into cc-app (routes, CSS, JS) and cc-docs (docs site)

$subManifestBuckets = @{}

foreach ($repoPath in ($localFiles.Keys | Sort-Object)) {
    $subCategory = $null

    if ($repoPath.StartsWith("xFACts-PowerShell/")) {
        $subCategory = "powershell"
    }
    elseif ($repoPath.StartsWith("xFACts-SQL/")) {
        $subCategory = "sql"
    }
    elseif ($repoPath.StartsWith("xFACts-Documentation/")) {
        $subCategory = "documentation"
    }
    elseif ($repoPath.StartsWith("xFACts-ControlCenter/")) {
        # Split CC: anything under public/docs/ goes to cc-docs, everything else to cc-app
        if ($repoPath -like "xFACts-ControlCenter/public/docs/*") {
            $subCategory = "cc-docs"
        }
        else {
            $subCategory = "cc-app"
        }
    }
    else {
        $subCategory = "other"
    }

    if (-not $subManifestBuckets.ContainsKey($subCategory)) {
        $subManifestBuckets[$subCategory] = @()
    }

    $fileEntry = [ordered]@{
        path    = $repoPath
        raw_url = "$baseRawUrl/${repoPath}?v=$cacheBuster"
    }

    # Enrich with module/component from Object_Registry audit
    if ($manifestEnrichment.ContainsKey($repoPath)) {
        $enrichment = $manifestEnrichment[$repoPath]
        $fileEntry.module    = $enrichment.module_name
        $fileEntry.component = $enrichment.component_name
    }

    $subManifestBuckets[$subCategory] += $fileEntry
}

# -- Sub-manifest definitions -----------------------------------------------

$subManifestDefs = @(
    @{ Key = "cc-app";        Filename = "manifest-cc-app.json";        Title = "Control Center Application" }
    @{ Key = "cc-docs";       Filename = "manifest-cc-docs.json";       Title = "Control Center Documentation Site" }
    @{ Key = "powershell";    Filename = "manifest-powershell.json";    Title = "PowerShell Scripts" }
    @{ Key = "sql";           Filename = "manifest-sql.json";           Title = "SQL Object Definitions" }
    @{ Key = "documentation"; Filename = "manifest-documentation.json"; Title = "Documentation and Working Files" }
)

# -- Generate each sub-manifest --------------------------------------------

$subManifestSummaries = @()
$allManifestFiles = @{}  # repoPath -> bytes, for pushing

foreach ($def in $subManifestDefs) {
    $bucketKey = $def.Key
    $filename = $def.Filename
    $files = if ($subManifestBuckets.ContainsKey($bucketKey)) { $subManifestBuckets[$bucketKey] } else { @() }

    $subManifest = [ordered]@{
        generated  = $generatedTimestamp
        category   = $def.Title
        file_count = $files.Count
        files      = @($files)
    }

    $subJson = $subManifest | ConvertTo-Json -Depth 4
    $subBytes = [System.Text.Encoding]::UTF8.GetBytes($subJson)
    $allManifestFiles[$filename] = $subBytes

    $subManifestSummaries += [ordered]@{
        category   = $def.Title
        filename   = $filename
        raw_url    = "$baseRawUrl/${filename}?v=$cacheBuster"
        file_count = $files.Count
    }

    Write-Log "  Sub-manifest: $filename - $($files.Count) files"
}

# Handle any "other" category files (shouldn't normally exist)
if ($subManifestBuckets.ContainsKey("other") -and $subManifestBuckets["other"].Count -gt 0) {
    Write-Log "  WARN  $($subManifestBuckets['other'].Count) files in 'other' category - not in any sub-manifest" "WARN"
}

# -- Generate master manifest (index only) ----------------------------------

$totalFileCount = 0
foreach ($s in $subManifestSummaries) { $totalFileCount += $s.file_count }

$masterManifest = [ordered]@{
    generated    = $generatedTimestamp
    repository   = "https://github.com/$Owner/$Repo"
    base_raw_url = $baseRawUrl
    file_count   = $totalFileCount
    manifests    = @($subManifestSummaries)
}

$masterJson = $masterManifest | ConvertTo-Json -Depth 4
$masterBytes = [System.Text.Encoding]::UTF8.GetBytes($masterJson)
$allManifestFiles["manifest.json"] = $masterBytes

Write-Log "  Master manifest: $($subManifestSummaries.Count) sub-manifests, $totalFileCount total files"

# -- Push all manifests -----------------------------------------------------

if ($Execute) {
    $manifestPushCount = 0
    $manifestSkipCount = 0

    foreach ($manifestPath in $allManifestFiles.Keys) {
        $manifestBytes = $allManifestFiles[$manifestPath]

        # Check if this manifest exists in remote
        $existingSha = $null
        if ($remoteTree -and $remoteTree.ContainsKey($manifestPath)) {
            $existingSha = $remoteTree[$manifestPath]
        }

        # Check if content actually changed
        $localSha = Get-GitBlobSha -ContentBytes $manifestBytes
        $contentChanged = ($null -eq $existingSha) -or ($localSha -ne $existingSha)

        if ($contentChanged) {
            $result = Push-GitHubFile -Owner $Owner -Repo $Repo -Branch $Branch -Headers $headers `
                -RepoPath $manifestPath -ContentBytes $manifestBytes `
                -CommitMessage "Update $manifestPath" `
                -ExistingSha $existingSha

            if ($result) {
                Write-Log "  PUSH  $manifestPath" "SUCCESS"
                $manifestPushCount++
            }
            else {
                Write-Log "  FAILED  $manifestPath" "ERROR"
            }

            Start-Sleep -Milliseconds 100
        }
        else {
            $manifestSkipCount++
        }
    }

    Write-Log "  Manifests: $manifestPushCount pushed, $manifestSkipCount unchanged"
}
else {
    Write-Log "  PREVIEW - Manifests would be pushed:" "WARN"
    foreach ($manifestPath in $allManifestFiles.Keys) {
        Write-Log "    $manifestPath"
    }
}

# ============================================================================
# SUMMARY
# ============================================================================

Write-Log ""
Write-Log "=========================================="
Write-Log "Summary"
Write-Log "=========================================="
Write-Log "  Files scanned:  $($localFiles.Count)"
Write-Log "  SQL objects:    $sqlCount"
Write-Log "  Registry:       $exportedTables tables"
Write-Log "  Audit:          $auditMatched matched, $auditUnregistered unregistered, $auditPathMismatch path mismatches"
Write-Log "  To create:      $($toCreate.Count)"
Write-Log "  To update:      $($toUpdate.Count)"
Write-Log "  To delete:      $($toDelete.Count)"
Write-Log "  Unchanged:      $unchanged"
Write-Log "  Sub-manifests:  $($subManifestSummaries.Count)"

if (-not $Execute) {
    Write-Log ""
    Write-Log "PREVIEW MODE - No changes were made. Run with -Execute to push." "WARN"
}
else {
    Write-Log ""
    if ($auditHasWarnings) {
        Write-Log "GitHub repository push complete (with audit warnings)" "WARN"
        exit 2
    }
    else {
        Write-Log "GitHub repository push complete" "SUCCESS"
    }
}
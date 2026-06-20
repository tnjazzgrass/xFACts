<#
.SYNOPSIS
    Publishes all xFACts platform files to a GitHub repository.

.DESCRIPTION
    Publishes the xFACts platform to a GitHub repository via the REST API,
    maintaining a complete, current snapshot: PowerShell scripts, Control Center
    files, documentation, SQL object definitions, and generated reference data.
    The run collects the file inventory from the server source directories,
    extracts SQL object definitions, generates the Platform Registry markdown,
    audits collected files against Object_Registry, fetches the current repo
    state, computes the create/update/delete diff against it, pushes the changes
    via the Contents API, and generates a segmented set of manifests (a
    lightweight master index plus per-category sub-manifests). Runs standalone
    or as a step in the Invoke-DocPipeline.ps1 pipeline.

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

.COMPONENT
    Documentation.Pipeline

.NOTES
    File Name : Publish-GitHubRepository.ps1
    Location  : E:\xFACts-PowerShell\Publish-GitHubRepository.ps1

    FILE ORGANIZATION
    -----------------
    CHANGELOG: CHANGE HISTORY
    PARAMETERS: SCRIPT PARAMETERS
    IMPORTS: SCRIPT DEPENDENCIES
    INITIALIZATION: SCRIPT INITIALIZATION
    CONSTANTS: PATHS AND SOURCES
    FUNCTIONS: GITHUB REST API
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
#             section, function purpose comments in place of docblocks, and the
#             dot-source moved into the IMPORTS section. Added the
#             xFACts-DocPipelineFunctions.ps1 dependency: SQL object extraction
#             now calls the shared Get-SqlObjectDefinitions and registry markdown
#             generation calls the shared Get-RegistryExportMarkdown, replacing
#             the per-script copies. Removed the dead $script:Config assignment
#             and its preview-mode no-op block; Initialize-XFActsScript now
#             receives the script's server and database parameters.
# 2026-04-04  Segmented manifest into sub-manifests by category. Master
#             manifest.json is now a lightweight index with links to category
#             sub-manifests (cc-app, cc-docs, powershell, sql, documentation).
# 2026-04-02  Added Object_Registry audit phase with path validation. Manifest
#             entries now include module_name and component_name from
#             Object_Registry. Unregistered files logged as warnings. Audit
#             exclusions: Planning docs, standalone docs, generated DDL JSON,
#             Legacy schema SQL objects.
# 2026-04-01  Initial implementation.

<# ============================================================================
   PARAMETERS: SCRIPT PARAMETERS
   ----------------------------------------------------------------------------
   Repository target (owner, repo, branch), the credential service name, the
   SQL connection target for object extraction and registry queries, and the
   execute guard.
   Prefix: (none)
   ============================================================================ #>

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

<# ============================================================================
   IMPORTS: SCRIPT DEPENDENCIES
   ----------------------------------------------------------------------------
   Dot-sourced shared infrastructure: orchestrator helpers (initialization,
   logging, SQL data access, credential retrieval) and the documentation-pipeline
   helpers (SQL object extraction and Platform Registry markdown generation).
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

Initialize-XFActsScript -ScriptName 'Publish-GitHubRepository' -ServerInstance $xFACtsServer -Database $xFACtsDB -Execute:$Execute

<# ============================================================================
   CONSTANTS: PATHS AND SOURCES
   ----------------------------------------------------------------------------
   Server source roots, the server-to-repository file-source map, the managed
   repository path prefixes considered for orphan cleanup, and the sub-manifest
   category definitions used when generating the segmented manifests.
   Prefix: (none)
   ============================================================================ #>

# Root of the orchestrator PowerShell script tree.
$ScriptsRoot = "E:\xFACts-PowerShell"
# Root of the Control Center application and documentation-site tree.
$CCRoot      = "E:\xFACts-ControlCenter"
# Root of the standalone documentation and planning tree.
$DocsRoot    = "E:\xFACts-Documentation"

# Server-to-repository file-source map: each entry maps a server directory to a
# repository path, with a filename filter set and a recurse flag.
$FileSources = @(
    @{
        ServerPath  = $ScriptsRoot
        RepoPath    = "xFACts-PowerShell"
        Filter      = @("*.ps1", "*.js", "*.psm1")
        Recurse     = $false
        Description = "Orchestrator scripts"
    }
    @{
        ServerPath  = "$CCRoot\scripts"
        RepoPath    = "xFACts-ControlCenter/scripts"
        Filter      = @("*.ps1", "*.psm1", "*.psd1")
        Recurse     = $true
        Description = "Control Center scripts, routes, modules"
    }
    @{
        ServerPath  = "$CCRoot\public\css"
        RepoPath    = "xFACts-ControlCenter/public/css"
        Filter      = @("*.css")
        Recurse     = $false
        Description = "Control Center CSS"
    }
    @{
        ServerPath  = "$CCRoot\public\js"
        RepoPath    = "xFACts-ControlCenter/public/js"
        Filter      = @("*.js")
        Recurse     = $false
        Description = "Control Center JS"
    }
    @{
        ServerPath  = "$CCRoot\public\docs\pages"
        RepoPath    = "xFACts-ControlCenter/public/docs/pages"
        Filter      = @("*.html")
        Recurse     = $true
        Description = "Documentation HTML pages (narrative, arch, ref, cc, guides)"
    }
    @{
        ServerPath  = "$CCRoot\public\docs\css"
        RepoPath    = "xFACts-ControlCenter/public/docs/css"
        Filter      = @("*.css")
        Recurse     = $false
        Description = "Documentation CSS"
    }
    @{
        ServerPath  = "$CCRoot\public\docs\js"
        RepoPath    = "xFACts-ControlCenter/public/docs/js"
        Filter      = @("*.js")
        Recurse     = $false
        Description = "Documentation JS"
    }
    @{
        ServerPath  = "$CCRoot\public\docs\data\ddl"
        RepoPath    = "xFACts-ControlCenter/public/docs/data/ddl"
        Filter      = @("*.json")
        Recurse     = $false
        Description = "Schema JSON data files"
    }
    @{
        ServerPath  = "$CCRoot\public\docs\images\cc"
        RepoPath    = "xFACts-ControlCenter/public/docs/images/cc"
        Filter      = @("*.png")
        Recurse     = $false
        Description = "CC guide screenshots"
    }
    @{
        ServerPath  = "$DocsRoot\docs"
        RepoPath    = "xFACts-Documentation"
        Filter      = @("*.md")
        Recurse     = $false
        Description = "Platform documentation (Guidelines, Backlog)"
    }
    @{
        ServerPath  = "$DocsRoot\Planning"
        RepoPath    = "xFACts-Documentation/Planning"
        Filter      = @("*.md")
        Recurse     = $false
        Description = "Planning documents (working docs, roadmaps)"
    }
    @{
        ServerPath  = "$DocsRoot\WorkingFiles"
        RepoPath    = "xFACts-Documentation/WorkingFiles"
        Filter      = @("*.*")
        Recurse     = $true
        Description = "Working reference files for active builds"
    }
)

# Repository path prefixes the publisher manages; only files under these are
# considered for orphan deletion.
$ManagedPrefixes = @("xFACts-PowerShell/", "xFACts-ControlCenter/", "xFACts-Documentation/", "xFACts-SQL/")

# Sub-manifest category definitions: bucket key, output filename, and title.
$SubManifestDefs = @(
    @{ Key = "cc-app";        Filename = "manifest-cc-app.json";        Title = "Control Center Application" }
    @{ Key = "cc-docs";       Filename = "manifest-cc-docs.json";       Title = "Control Center Documentation Site" }
    @{ Key = "powershell";    Filename = "manifest-powershell.json";    Title = "PowerShell Scripts" }
    @{ Key = "sql";           Filename = "manifest-sql.json";           Title = "SQL Object Definitions" }
    @{ Key = "documentation"; Filename = "manifest-documentation.json"; Title = "Documentation and Working Files" }
)

<# ============================================================================
   FUNCTIONS: GITHUB REST API
   ----------------------------------------------------------------------------
   Thin wrappers over the GitHub REST API used by the publish run: request
   header construction, repository tree retrieval, single-file create/update and
   delete via the Contents API, and local git blob SHA computation for change
   detection without downloading remote content.
   Prefix: (none)
   ============================================================================ #>

# Builds the GitHub REST request headers carrying the bearer token and API version.
function Get-GitHubHeaders {
    param([string]$Token)
    return @{
        "Authorization"        = "Bearer $Token"
        "Accept"               = "application/vnd.github+json"
        "User-Agent"           = "xFACts-Publisher/1.0"
        "X-GitHub-Api-Version" = "2022-11-28"
    }
}

# Retrieves the full repository file tree via the Git Trees API as a path -> blob SHA map.
function Get-RepoTree {
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

# Creates or updates a single repository file via the Contents API (SHA required for updates, null for creates).
function Push-GitHubFile {
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

# Deletes a repository file via the Contents API (SHA required).
function Remove-GitHubFile {
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

# Computes the git blob SHA1 of file content (SHA1 of "blob <size>\0<content>") for change detection without downloading.
function Get-GitBlobSha {
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

<# ============================================================================
   EXECUTION: SCRIPT EXECUTION
   ----------------------------------------------------------------------------
   Runs the publish pipeline: retrieve credentials, collect local files, extract
   SQL object definitions, generate the Platform Registry markdown, audit against
   Object_Registry, compute the repository diff, push the create/update/delete
   changes, generate and push the segmented manifests, and report a summary.
   Prefix: (none)
   ============================================================================ #>

# Force TLS 1.2 for GitHub API connectivity.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Generated repository paths that orphan cleanup must not delete (the manifests).
$GeneratedRepoPaths = [System.Collections.Generic.HashSet[string]]::new()
$GeneratedRepoPaths.Add("manifest-cc-app.json")        | Out-Null
$GeneratedRepoPaths.Add("manifest-cc-docs.json")       | Out-Null
$GeneratedRepoPaths.Add("manifest-powershell.json")    | Out-Null
$GeneratedRepoPaths.Add("manifest-sql.json")           | Out-Null
$GeneratedRepoPaths.Add("manifest-documentation.json") | Out-Null

# -- Phase 1: Retrieve credentials --

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

# Validate connectivity and authentication.
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

# -- Phase 2: Collect local files --

Write-Log ""
Write-Log "Phase 2: Collecting local files"
Write-Log "-------------------------------"

# Hashtable of repoPath -> @{ ContentBytes, Source }.
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
            # Build repo path: base repo path plus the relative path from the server source.
            if ($source.Recurse) {
                $relativePath = $file.FullName.Substring($serverPath.Length).TrimStart('\') -replace '\\', '/'
                $repoPath = "$($source.RepoPath)/$relativePath"
            }
            else {
                $repoPath = "$($source.RepoPath)/$($file.Name)"
            }

            $contentBytes = [System.IO.File]::ReadAllBytes($file.FullName)
            # Strip the UTF-8 BOM if present (0xEF, 0xBB, 0xBF).
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

# -- Phase 3: Extract SQL object definitions --

Write-Log ""
Write-Log "Phase 3: Extracting SQL object definitions"
Write-Log "-------------------------------------------"

$sqlObjects = Get-SqlObjectDefinitions
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
        $GeneratedRepoPaths.Add($repoPath) | Out-Null
        $sqlCount++
    }
    Write-Log "  OK    SQL object definitions - $sqlCount extracted" "SUCCESS"
}
else {
    Write-Log "  WARN  No SQL objects extracted" "WARN"
}

# -- Phase 4: Generate Platform Registry --

Write-Log ""
Write-Log "Phase 4: Generating Platform Registry"
Write-Log "--------------------------------------"

$registryExport = Get-RegistryExportMarkdown
$exportedTables = $registryExport.TableCount

if ($exportedTables -gt 0) {
    $registryBytes = [System.Text.Encoding]::UTF8.GetBytes($registryExport.Markdown)
    $registryRepoPath = "xFACts-Documentation/xFACts_Platform_Registry.md"

    $localFiles[$registryRepoPath] = @{
        ContentBytes = $registryBytes
        Source       = "Generated:PlatformRegistry"
    }
    $GeneratedRepoPaths.Add($registryRepoPath) | Out-Null
    Write-Log "  OK    Platform Registry - $exportedTables tables exported" "SUCCESS"
}

# -- Phase 5: Object_Registry audit --

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

# Build a lookup by object_name (filename) -> registry entries. Some filenames
# may appear in multiple components (unlikely but possible).
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

# Audit each collected file against the registry.
$auditMatched = 0
$auditUnregistered = 0
$auditPathMismatch = 0
$unregisteredFiles = @()
$pathMismatches = @()

# Manifest enrichment lookup: repoPath -> { module_name, component_name }.
$manifestEnrichment = @{}

foreach ($repoPath in $localFiles.Keys) {
    $entry = $localFiles[$repoPath]
    $fileName = $repoPath.Split('/')[-1]
    $sourcePath = $entry.Source

    # Skip generated files (Platform Registry, manifests) - not registered objects.
    if ($sourcePath -like "Generated:*") { continue }

    # Skip files excluded from the registry audit by convention.
    # Planning/working docs are transient session documents, not platform objects.
    if ($repoPath -like "xFACts-Documentation/Planning/*") { continue }
    if ($repoPath -like "xFACts-Documentation/WorkingFiles/*") { continue }
    # Standalone documentation files (Guidelines, Backlog) are reference documents, not module objects.
    if ($repoPath -like "xFACts-Documentation/*.md") { continue }
    # Generated DDL JSON data files are output of Generate-DDLReference.ps1, not authored objects.
    if ($repoPath -like "xFACts-ControlCenter/public/docs/data/ddl/*.json") { continue }

    # SQL objects: match by schema.objectname pattern.
    if ($sourcePath -like "SQL:*") {
        # Remove the "SQL:" prefix.
        $sqlIdentifier = $sourcePath.Substring(4)
        $parts = $sqlIdentifier.Split('.')
        # Skip Legacy schema objects - deprecated, not tracked.
        if ($parts.Count -ge 1 -and $parts[0] -eq 'Legacy') { continue }
        if ($parts.Count -eq 2) {
            $schemaName = $parts[0]
            $objectName = $parts[1]
            # Look for the object by its actual name (without schema prefix).
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
            # Also try schema.objectname as the lookup key.
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

    # File-based objects: match by filename.
    if ($registryLookup.ContainsKey($fileName)) {
        $regEntry = $registryLookup[$fileName][0]
        $auditMatched++
        $manifestEnrichment[$repoPath] = @{
            module_name    = $regEntry.module_name
            component_name = $regEntry.component_name
        }

        # Path validation: compare registry object_path to the actual source path.
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

# Track whether the audit found issues (used for the exit code).
$auditHasWarnings = ($auditUnregistered -gt 0 -or $auditPathMismatch -gt 0)

# -- Phase 6: Compute repository diff --

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

# Classify each local file as CREATE or UPDATE by comparing git blob SHA.
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

# Identify orphans: files in the repo not in the local set, under a managed prefix.
$toDelete = @()
foreach ($remotePath in $remoteTree.Keys) {
    $isManaged = $false
    foreach ($prefix in $ManagedPrefixes) {
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

# -- Phase 7: Push changes to GitHub --

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
        # Process creates.
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

            # Brief pause to respect API rate limits.
            Start-Sleep -Milliseconds 100
        }

        # Process updates.
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

        # Process deletes.
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

# -- Phase 8: Generate and push segmented manifests --

Write-Log ""
Write-Log "Phase 8: Generating segmented manifests"
Write-Log "---------------------------------------"

$baseRawUrl = "https://raw.githubusercontent.com/$Owner/$Repo/$Branch"
$cacheBuster = (Get-Date).ToUniversalTime().ToString("yyyyMMddHHmmss")
$generatedTimestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

# Classify files into sub-manifest categories. ControlCenter splits into cc-app
# (routes, CSS, JS) and cc-docs (the documentation site under public/docs).
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

    # Enrich with module/component from the Object_Registry audit.
    if ($manifestEnrichment.ContainsKey($repoPath)) {
        $enrichment = $manifestEnrichment[$repoPath]
        $fileEntry.module    = $enrichment.module_name
        $fileEntry.component = $enrichment.component_name
    }

    $subManifestBuckets[$subCategory] += $fileEntry
}

# Generate each sub-manifest and collect its summary for the master index.
$subManifestSummaries = @()
# repoPath -> bytes, for pushing.
$allManifestFiles = @{}

foreach ($def in $SubManifestDefs) {
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

# Warn about any "other" category files (should not normally exist).
if ($subManifestBuckets.ContainsKey("other") -and $subManifestBuckets["other"].Count -gt 0) {
    Write-Log "  WARN  $($subManifestBuckets['other'].Count) files in 'other' category - not in any sub-manifest" "WARN"
}

# Generate the master manifest (index only).
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

# Push all manifests.
if ($Execute) {
    $manifestPushCount = 0
    $manifestSkipCount = 0

    foreach ($manifestPath in $allManifestFiles.Keys) {
        $manifestBytes = $allManifestFiles[$manifestPath]

        # Resolve the existing SHA, if the manifest is already in the remote.
        $existingSha = $null
        if ($remoteTree -and $remoteTree.ContainsKey($manifestPath)) {
            $existingSha = $remoteTree[$manifestPath]
        }

        # Push only when content actually changed.
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

# -- Summary --

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
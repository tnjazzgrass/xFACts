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
    4. Fetch current repo state (file listing with SHAs)
    5. Compare local vs remote — identify creates, updates, deletes
    6. Push changes to GitHub via Contents API
    7. Generate and push manifest.json
    8. Report summary

    CHANGELOG
    ---------
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
    Preview mode — shows what would be pushed without making changes.

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
    # Preview mode — Initialize-XFActsScript displays the warning but returns $null
    # We still want to continue in preview mode, so don't exit
}

# Force TLS 1.2 for GitHub API connectivity
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ============================================================================
# CONFIGURATION — Source Mappings
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
        Filter     = @("*.ps1", "*.psm1")
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
        Description = "Documentation HTML pages (narrative, arch, ref, cc)"
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
)

# Track generated file paths so orphan cleanup doesn't delete them
$GeneratedRepoPaths = [System.Collections.Generic.List[string]]::new()
$GeneratedRepoPaths.Add("manifest.json")

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
        Write-Log "  SKIP  $($source.Description) — path not found: $serverPath" "WARN"
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
            $localFiles[$repoPath] = @{
                ContentBytes = $contentBytes
                Source       = $file.FullName
            }
            $fileCount++
        }
    }

    Write-Log "  OK    $($source.Description) — $fileCount files" "SUCCESS"
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
    Write-Log "  OK    SQL object definitions — $sqlCount extracted" "SUCCESS"
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
            Write-Log "  SKIP  $($export.Title) — no rows"
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
        Write-Log "  OK    $($export.Title) — $rowCount rows" "SUCCESS"
    }
    catch {
        Write-Log "  ERROR  $($export.Title) — $($_.Exception.Message)" "ERROR"
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
    Write-Log "  OK    Platform Registry — $exportedTables tables exported" "SUCCESS"
}

# ============================================================================
# PHASE 5: FETCH REMOTE STATE AND COMPUTE DIFF
# ============================================================================

Write-Log ""
Write-Log "Phase 5: Computing repository diff"
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
# PHASE 6: PUSH CHANGES TO GITHUB
# ============================================================================

if ($toCreate.Count -gt 0 -or $toUpdate.Count -gt 0 -or $toDelete.Count -gt 0) {
    Write-Log ""
    Write-Log "Phase 6: Pushing changes to GitHub"
    Write-Log "----------------------------------"

    $pushErrors = 0
    $pushSuccess = 0

    if (-not $Execute) {
        Write-Log ""
        Write-Log "  PREVIEW — Changes that would be made:" "WARN"
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
# PHASE 7: GENERATE AND PUSH MANIFEST
# ============================================================================

Write-Log ""
Write-Log "Phase 7: Generating manifest.json"
Write-Log "---------------------------------"

$baseRawUrl = "https://raw.githubusercontent.com/$Owner/$Repo/$Branch"

$manifestFiles = @()
foreach ($repoPath in ($localFiles.Keys | Sort-Object)) {
    $category = if ($repoPath.StartsWith("xFACts-PowerShell/")) { "PowerShell" }
                elseif ($repoPath.StartsWith("xFACts-ControlCenter/")) { "ControlCenter" }
                elseif ($repoPath.StartsWith("xFACts-Documentation/")) { "Documentation" }
                elseif ($repoPath.StartsWith("xFACts-SQL/")) { "SQL" }
                else { "Other" }

    $manifestFiles += [ordered]@{
        path     = $repoPath
        raw_url  = "$baseRawUrl/$repoPath"
        category = $category
    }
}

$manifest = [ordered]@{
    generated    = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    repository   = "https://github.com/$Owner/$Repo"
    base_raw_url = $baseRawUrl
    file_count   = $manifestFiles.Count
    files        = $manifestFiles
}

$manifestJson = $manifest | ConvertTo-Json -Depth 4
$manifestBytes = [System.Text.Encoding]::UTF8.GetBytes($manifestJson)

Write-Log "  Manifest: $($manifestFiles.Count) files cataloged"

if ($Execute) {
    # Check if manifest exists in remote
    $manifestSha = $null
    if ($remoteTree -and $remoteTree.ContainsKey("manifest.json")) {
        $manifestSha = $remoteTree["manifest.json"]
    }

    # Check if content actually changed
    $manifestLocalSha = Get-GitBlobSha -ContentBytes $manifestBytes
    $manifestChanged = ($null -eq $manifestSha) -or ($manifestLocalSha -ne $manifestSha)

    if ($manifestChanged) {
        $result = Push-GitHubFile -Owner $Owner -Repo $Repo -Branch $Branch -Headers $headers `
            -RepoPath "manifest.json" -ContentBytes $manifestBytes `
            -CommitMessage "Update manifest.json — $($manifestFiles.Count) files" `
            -ExistingSha $manifestSha

        if ($result) {
            Write-Log "  Manifest pushed successfully" "SUCCESS"
        }
        else {
            Write-Log "  Manifest push failed" "ERROR"
        }
    }
    else {
        Write-Log "  Manifest unchanged — skipped"
    }
}
else {
    Write-Log "  PREVIEW — Manifest would be pushed with $($manifestFiles.Count) entries" "WARN"
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
Write-Log "  To create:      $($toCreate.Count)"
Write-Log "  To update:      $($toUpdate.Count)"
Write-Log "  To delete:      $($toDelete.Count)"
Write-Log "  Unchanged:      $unchanged"

if (-not $Execute) {
    Write-Log ""
    Write-Log "PREVIEW MODE — No changes were made. Run with -Execute to push." "WARN"
}
else {
    Write-Log ""
    Write-Log "GitHub repository push complete" "SUCCESS"
}
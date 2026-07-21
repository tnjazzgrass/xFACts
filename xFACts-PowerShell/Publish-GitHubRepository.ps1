<#
.SYNOPSIS
    Publishes the xFACts generated artifact tree to a GitHub repository.

.DESCRIPTION
    Publishes the platform's generated content to a GitHub repository via the REST
    API: the SQL object definitions, the DDL JSON, the module markdown, and the
    Platform Registry snapshot. Authored content is no longer published here - it
    now flows GitHub -> live via Deploy-xFACts.ps1, so this script owns only the
    generated tree under xFACts-Generated/. The run collects the generated disk
    sources, extracts SQL object definitions, generates the Platform Registry
    markdown, audits the collected files against Object_Registry, fetches the
    current repo state, computes the create/update/delete diff, and pushes the
    changes via the Contents API. Two safety guards protect the orphan-deletion
    path: a floor guard that aborts when a source directory is missing or
    unreadable, or when an emptied source would orphan-delete live repository
    files, and a deletion-threshold guard that requires an explicit override to
    execute an unusually large delete set. Manifests are rebuilt by the shared
    Publish-RepositoryManifests builder: a standalone run refreshes them at the
    end; -SkipManifests suppresses that (used when the pipeline runs the dedicated
    manifest step); -ManifestsOnly skips all content work and only rebuilds the
    manifests. Runs standalone or as a step in the Invoke-DocPipeline.ps1 pipeline.

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

.PARAMETER DeleteThreshold
    Maximum orphan deletions allowed on an execute run without the
    -AllowMassDeletion override. Default: 25

.PARAMETER AllowMassDeletion
    Authorizes an execute run whose planned deletions exceed DeleteThreshold.
    Preview always shows the full delta regardless of this switch.

.PARAMETER SkipManifests
    Suppresses this run's manifest rebuild. Used by the pipeline when the dedicated
    manifest step runs separately, so manifests build exactly once per full run.

.PARAMETER ManifestsOnly
    Skips all content collection, extraction, audit, diff, and push, and only
    rebuilds and pushes the manifests. The pipeline's dedicated manifest step uses
    this. Cannot be combined with -SkipManifests.

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

# 2026-07-21  Pipeline flip (Task 1). Sync inverted: authored content now flows
#             GitHub -> live via Deploy-xFACts.ps1, so this script publishes only
#             the generated tree. Removed every authored source from $FileSources
#             (leaving the generated ddl and md disk sources plus the SQL dump and
#             Platform Registry it generates), dropped the now-unused $ScriptsRoot,
#             $CCRoot, and $DocsRoot roots, and reduced $ManagedPrefixes to
#             xFACts-Generated/ (the transition-era xFACts-SQL/ entry is gone -
#             cutover is done). Trimmed the Object_Registry audit to the generated
#             set: the authored skip entries and the authored-only path-mismatch
#             check were removed, and the registry lookup and per-path resolution
#             moved to the shared Get-ObjectRegistryLookup / Resolve-ObjectRegistryEntry.
#             Moved the GitHub REST layer (headers, tree, push, delete, blob SHA)
#             into xFACts-DocPipelineFunctions.ps1 so it is shared with the manifest
#             builder. Replaced the internal manifest phase with a call to the
#             shared Publish-RepositoryManifests; added -SkipManifests (suppress the
#             rebuild when the pipeline's manifest step runs) and -ManifestsOnly
#             (rebuild manifests only). Both safety guards remain and now protect
#             the generated prefix.
# 2026-07-21  Phase 2 of the repository restructure. Source map: dropped the empty
#             images/cc and the relocated data/ddl Control Center sources; kept
#             *.js on the PowerShell source - it publishes the authored Node AST
#             helpers parse-js.js and parse-css.js and is annotated so it is not
#             again mistaken for dead; un-flattened authored
#             docs from the repo root to xFACts-Documentation/docs; added the
#             xFACts-Generated tree (ddl JSON and recursive module markdown from
#             E:\xFACts-Generated). The SQL object dump moved from xFACts-SQL to
#             xFACts-Generated/sql and the Platform Registry snapshot from the
#             Documentation root to xFACts-Generated/registry. Managed prefixes
#             gained xFACts-Generated and retain xFACts-SQL for one cutover so the
#             old dump location is orphan-cleaned. Added the orphan-deletion floor
#             guard (a missing or unreadable source aborts before comparison; an
#             emptied source aborts only when it would orphan live repo files) and
#             a deletion-threshold override (-DeleteThreshold/-AllowMassDeletion)
#             gating only the execute path. Manifests re-segmented into powershell,
#             cc-app, cc-docs, documentation, and generated; the master manifest
#             gained a path-prefix routing table and every file entry gained a
#             class of authored or generated. Removed the dead $GeneratedRepoPaths
#             set (orphan protection comes from membership in the collected file
#             set). Legacy schema objects are now excluded at extraction in
#             xFACts-DocPipelineFunctions.ps1 rather than skipped in the audit.
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
   SQL connection target for object extraction and registry queries, the execute
   guard, the orphan-deletion safety controls (deletion threshold and the
   mass-deletion override), and the two manifest-mode switches.
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
    [switch]$Execute,
    [int]$DeleteThreshold = 25,
    [switch]$AllowMassDeletion,
    [switch]$SkipManifests,
    [switch]$ManifestsOnly
)

<# ============================================================================
   IMPORTS: SCRIPT DEPENDENCIES
   ----------------------------------------------------------------------------
   Dot-sourced shared infrastructure: orchestrator helpers (initialization,
   logging, SQL data access, credential retrieval) and the documentation-pipeline
   helpers (SQL object extraction, Platform Registry markdown, the GitHub REST
   layer, the Object_Registry lookup, and the manifest builder).
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
   The generated artifact source root, the server-to-repository file-source map
   for the generated tree, and the managed repository path prefixes considered
   for orphan cleanup. The manifest segment routing table lives in
   xFACts-DocPipelineFunctions.ps1 ($script:ManifestSegments), shared with the
   manifest builder.
   Prefix: (none)
   ============================================================================ #>

# Root of the machine-generated artifact tree (DDL JSON and module markdown).
$GeneratedRoot = "E:\xFACts-Generated"

# Server-to-repository file-source map for the generated tree only. Each entry
# maps a server directory to a repository path, with a filename filter set and a
# recurse flag. The SQL object definitions and the Platform Registry snapshot are
# not disk sources; they are generated into the collected file set during
# EXECUTION. AUTHORED content is NOT published here - it is deployed GitHub -> live
# by Deploy-xFACts.ps1, whose $AuthoredDeployMap is the inverse authored mapping.
# The two tables partition the repository: authored paths belong to Deploy's map,
# generated paths belong here, and every managed repo path belongs to exactly one.
# Keep them in agreement - a path must never appear in both, nor in neither.
$FileSources = @(
    @{
        ServerPath  = "$GeneratedRoot\ddl"
        RepoPath    = "xFACts-Generated/ddl"
        Filter      = @("*.json")
        Recurse     = $false
        Description = "Generated schema DDL JSON"
    }
    @{
        ServerPath  = "$GeneratedRoot\md"
        RepoPath    = "xFACts-Generated/md"
        Filter      = @("*.md")
        Recurse     = $true
        Description = "Generated module markdown"
    }
)

# Repository path prefixes the publisher manages; only files under these are
# considered for orphan deletion. The publisher owns the generated tree only;
# authored prefixes are managed by Deploy-xFACts.ps1 and are never touched here.
$ManagedPrefixes = @("xFACts-Generated/")

<# ============================================================================
   EXECUTION: SCRIPT EXECUTION
   ----------------------------------------------------------------------------
   Runs the publish pipeline: retrieve credentials, and then either rebuild the
   manifests only (-ManifestsOnly), or collect the generated files (with the floor
   guard on missing or unreadable sources), extract SQL object definitions,
   generate the Platform Registry markdown, audit against Object_Registry, compute
   the repository diff, apply the floor and deletion-threshold guards, push the
   create/update/delete changes, and (unless -SkipManifests) rebuild the manifests
   via the shared builder. Reports a summary at the end.
   Prefix: (none)
   ============================================================================ #>

# Force TLS 1.2 for GitHub API connectivity.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Guard the contradictory switch combination up front.
if ($SkipManifests -and $ManifestsOnly) {
    Write-Log "-SkipManifests and -ManifestsOnly are mutually exclusive. Nothing to do." "ERROR"
    exit 1
}

# -- Phase 1: Retrieve credentials --

Write-Log "=========================================="
Write-Log "xFACts GitHub Repository Publisher"
Write-Log "=========================================="
Write-Log "Repository: $Owner/$Repo (branch: $Branch)"
Write-Log "Mode: $(if ($ManifestsOnly) { 'MANIFESTS-ONLY' } elseif ($Execute) { 'EXECUTE' } else { 'PREVIEW' })"
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

# Manifests-only mode: rebuild the manifests from the live repo tree and exit.
if ($ManifestsOnly) {
    $manifestStatus = Publish-RepositoryManifests -Owner $Owner -Repo $Repo -Branch $Branch -Headers $headers -Execute:$Execute

    Write-Log ""
    Write-Log "=========================================="
    Write-Log "Summary (manifests only)"
    Write-Log "=========================================="

    if (-not $manifestStatus.Built) {
        Write-Log "Manifest rebuild failed - repository tree could not be retrieved." "ERROR"
        exit 1
    }

    if (-not $Execute) {
        Write-Log ""
        Write-Log "PREVIEW MODE - No changes were made. Run with -Execute to push." "WARN"
    }
    else {
        Write-Log "  Manifests: $($manifestStatus.Pushed) pushed, $($manifestStatus.Skipped) unchanged, $($manifestStatus.Failed) failed"
        Write-Log ""
        Write-Log "Manifest rebuild complete" "SUCCESS"
    }

    exit 0
}

# -- Phase 2: Collect local files --

Write-Log ""
Write-Log "Phase 2: Collecting local files"
Write-Log "-------------------------------"

# Hashtable of repoPath -> @{ ContentBytes, Source }.
$localFiles = @{}
# Per-source collected file counts, keyed by RepoPath, for the floor guard.
$sourceFileCounts = @{}

foreach ($source in $FileSources) {
    $serverPath = $source.ServerPath

    # Floor guard: a missing or unreadable source directory is an infrastructure
    # fault. Abort before any repository comparison so a vanished or locked
    # folder can never be read as "everything under it was deleted".
    if (-not (Test-Path $serverPath)) {
        Write-Log ""
        Write-Log "ABORT  Source directory not found: $serverPath ($($source.Description))." "ERROR"
        Write-Log "       A missing source is an infrastructure fault, not an empty set." "ERROR"
        Write-Log "       No repository comparison was performed and nothing was changed." "ERROR"
        exit 1
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

        $enumErrors = $null
        $files = Get-ChildItem @params -ErrorVariable enumErrors

        # A readable directory that returns nothing is a valid empty set; a
        # directory that errors and returns nothing is unreadable - abort.
        if ($enumErrors -and @($files).Count -eq 0) {
            Write-Log ""
            Write-Log "ABORT  Source directory unreadable: $serverPath ($($source.Description))." "ERROR"
            Write-Log "       $($enumErrors[0].Exception.Message)" "ERROR"
            Write-Log "       No repository comparison was performed and nothing was changed." "ERROR"
            exit 1
        }

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

    $sourceFileCounts[$source.RepoPath] = $fileCount
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
        $repoPath = "xFACts-Generated/sql/$fileName"
        $contentBytes = [System.Text.Encoding]::UTF8.GetBytes($obj.definition)

        $localFiles[$repoPath] = @{
            ContentBytes = $contentBytes
            Source       = "SQL:$($obj.schema_name).$($obj.object_name)"
        }
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
    $registryRepoPath = "xFACts-Generated/registry/xFACts_Platform_Registry.md"

    $localFiles[$registryRepoPath] = @{
        ContentBytes = $registryBytes
        Source       = "Generated:PlatformRegistry"
    }
    Write-Log "  OK    Platform Registry - $exportedTables tables exported" "SUCCESS"
}

# -- Phase 5: Object_Registry audit --

Write-Log ""
Write-Log "Phase 5: Object_Registry audit"
Write-Log "---------------------------------"

$registryLookup = Get-ObjectRegistryLookup

if ($registryLookup.Count -gt 0) {
    Write-Log "  Object_Registry: $($registryLookup.Count) unique objects loaded"
}
else {
    Write-Log "  WARN  Could not load Object_Registry" "WARN"
}

# Audit each collected file against the registry. The generated DDL JSON, module
# markdown, and Platform Registry snapshot are pipeline output, not catalog
# objects, so they are excluded; the SQL object dump is matched by schema.object.
$auditMatched = 0
$auditUnregistered = 0
$unregisteredFiles = @()

foreach ($repoPath in $localFiles.Keys) {
    $entry = $localFiles[$repoPath]

    if ($entry.Source -like "Generated:*") { continue }
    if ($repoPath -like "xFACts-Generated/ddl/*.json") { continue }
    if ($repoPath -like "xFACts-Generated/md/*") { continue }

    if (Resolve-ObjectRegistryEntry -RepoPath $repoPath -Lookup $registryLookup) {
        $auditMatched++
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

# Track whether the audit found issues (used for the exit code).
$auditHasWarnings = ($auditUnregistered -gt 0)

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

# Floor guard: a configured disk source that exists and is readable but yielded
# zero files is legitimate only when nothing under its repo prefix would be
# orphaned. If an emptied source would orphan-delete live repository files, that
# is a lost-content fault - abort before any delete. An empty source with no
# matching remote files is a valid empty set and only logs a notice.
foreach ($source in $FileSources) {
    if ($sourceFileCounts[$source.RepoPath] -ne 0) { continue }

    $sourcePrefix = "$($source.RepoPath)/"
    $orphanedByEmpty = @($toDelete | Where-Object { $_.RepoPath.StartsWith($sourcePrefix) })

    if ($orphanedByEmpty.Count -gt 0) {
        Write-Log ""
        Write-Log "ABORT  Source '$($source.Description)' ($($source.RepoPath)) yielded zero files," "ERROR"
        Write-Log "       but $($orphanedByEmpty.Count) live repository file(s) under $sourcePrefix would" "ERROR"
        Write-Log "       be orphan-deleted. Refusing to let a source that lost its content wipe the repo." "ERROR"
        Write-Log "       No changes were made." "ERROR"
        exit 1
    }
    else {
        Write-Log "  NOTE  Source '$($source.Description)' ($($source.RepoPath)) is empty; no remote orphans." "WARN"
    }
}

# Deletion-threshold guard: an unusually large delete set requires an explicit
# override to execute. Preview always shows the full delta; only the execute
# path is gated, so a legitimately large cutover is a deliberate, one-time
# -AllowMassDeletion run.
if ($toDelete.Count -gt $DeleteThreshold) {
    Write-Log ""
    Write-Log "  Planned deletions ($($toDelete.Count)) exceed the threshold ($DeleteThreshold)." "WARN"
    if ($Execute -and -not $AllowMassDeletion) {
        Write-Log "ABORT  Refusing to execute $($toDelete.Count) deletions without -AllowMassDeletion." "ERROR"
        Write-Log "       Re-run with -AllowMassDeletion to authorize this delete set. No changes were made." "ERROR"
        exit 1
    }
    elseif ($Execute) {
        Write-Log "  -AllowMassDeletion set: proceeding with $($toDelete.Count) deletions." "WARN"
    }
    else {
        Write-Log "  PREVIEW: executing this delta would require -AllowMassDeletion." "WARN"
    }
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

# -- Phase 8: Rebuild manifests via the shared builder --

if (-not $SkipManifests) {
    $manifestStatus = Publish-RepositoryManifests -Owner $Owner -Repo $Repo -Branch $Branch -Headers $headers -Execute:$Execute
    if (-not $manifestStatus.Built) {
        Write-Log "  Manifest rebuild failed - repository tree could not be retrieved." "WARN"
    }
}
else {
    Write-Log ""
    Write-Log "Manifests: skipped (-SkipManifests); the pipeline manifest step will rebuild them."
}

# -- Summary --

Write-Log ""
Write-Log "=========================================="
Write-Log "Summary"
Write-Log "=========================================="
Write-Log "  Files scanned:  $($localFiles.Count)"
Write-Log "  SQL objects:    $sqlCount"
Write-Log "  Registry:       $exportedTables tables"
Write-Log "  Audit:          $auditMatched matched, $auditUnregistered unregistered"
Write-Log "  To create:      $($toCreate.Count)"
Write-Log "  To update:      $($toUpdate.Count)"
Write-Log "  To delete:      $($toDelete.Count)"
Write-Log "  Unchanged:      $unchanged"

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

<#
.SYNOPSIS
    Deploys authored xFACts content from GitHub into the live server folders.

.DESCRIPTION
    The deploy half of the inverted sync: GitHub is the source of truth for
    authored content, and this script pulls it into a server-side staging clone
    and copies the changed authored files to their live locations. It verifies the
    staging clone (E:\xFACts-Staging by default) exists, is a git working tree, and
    points at the tnjazzgrass/xFACts remote - any verification failure aborts; the
    clone is never created or repaired here. It pulls from GitHub using the
    GitHub_xFACts credential, injecting the token per git invocation so it is never
    persisted to disk, determines which files the pull changed, maps authored
    repository paths to live paths via $AuthoredDeployMap (the inverse of the
    generated map in Publish-GitHubRepository.ps1), and copies the changed authored
    files. Generated repository paths (xFACts-Generated/*, the manifests) are never
    copied. Files deleted in the repository are reported, not deleted live. If
    either orchestrator file changed, those two are held back with a warning that
    they need a manual service-stop deployment, and the run exits 2 while every
    other changed file still deploys. Preview by default; -Execute performs the
    pull merge and the copies.

.PARAMETER Owner
    GitHub repository owner. Default: tnjazzgrass

.PARAMETER Repo
    GitHub repository name. Default: xFACts

.PARAMETER Branch
    Branch to pull. Default: main

.PARAMETER ServiceName
    Credential service name in dbo.Credentials for the GitHub token.
    Default: GitHub_xFACts

.PARAMETER StagingRoot
    The server-side staging clone directory. Verified, never created.
    Default: E:\xFACts-Staging

.PARAMETER xFACtsServer
    SQL Server instance used for credential retrieval. Default: AVG-PROD-LSNR

.PARAMETER xFACtsDB
    Database name. Default: xFACts

.PARAMETER Execute
    Required to fast-forward the staging clone and copy files to live. Without it,
    the run fetches and reports what would deploy, changing nothing live.

.COMPONENT
    Documentation.Pipeline

.NOTES
    File Name : Deploy-xFACts.ps1
    Location  : E:\xFACts-PowerShell\Deploy-xFACts.ps1

    FILE ORGANIZATION
    -----------------
    CHANGELOG: CHANGE HISTORY
    PARAMETERS: SCRIPT PARAMETERS
    IMPORTS: SCRIPT DEPENDENCIES
    INITIALIZATION: SCRIPT INITIALIZATION
    CONSTANTS: PATHS AND MAPPINGS
    FUNCTIONS: GIT OPERATIONS
    FUNCTIONS: DEPLOY MAPPING
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

# 2026-07-21  Initial implementation. Pipeline flip (Task 1): the deploy half of
#             the inverted sync. Verifies the staging clone, pulls authored content
#             from GitHub with a per-invocation (never persisted) token, maps
#             changed authored repository paths to live paths, copies them, reports
#             repository deletions without deleting live, and holds back the two
#             orchestrator files for a manual service-stop deployment (exit 2).

<# ============================================================================
   PARAMETERS: SCRIPT PARAMETERS
   ----------------------------------------------------------------------------
   Repository target (owner, repo, branch), the credential service name, the
   staging clone directory, the SQL connection target for credential retrieval,
   and the execute guard.
   Prefix: (none)
   ============================================================================ #>

[CmdletBinding()]
param(
    [string]$Owner = "tnjazzgrass",
    [string]$Repo = "xFACts",
    [string]$Branch = "main",
    [string]$ServiceName = "GitHub_xFACts",
    [string]$StagingRoot = "E:\xFACts-Staging",
    [string]$xFACtsServer = "AVG-PROD-LSNR",
    [string]$xFACtsDB = "xFACts",
    [switch]$Execute
)

<# ============================================================================
   IMPORTS: SCRIPT DEPENDENCIES
   ----------------------------------------------------------------------------
   Dot-sourced shared infrastructure: orchestrator helpers (initialization,
   logging, SQL data access, credential retrieval). The GitHub token is retrieved
   through Get-ServiceCredentials from this file.
   Prefix: (none)
   ============================================================================ #>

. "$PSScriptRoot\xFACts-OrchestratorFunctions.ps1"

<# ============================================================================
   INITIALIZATION: SCRIPT INITIALIZATION
   ----------------------------------------------------------------------------
   One-time shared setup: SQL module loading, application identity, log path,
   default connection target, and the preview-mode guard. The connection target
   is set from the script's xFACtsServer/xFACtsDB parameters so credential
   retrieval addresses exactly what those parameters specify.
   Prefix: (none)
   ============================================================================ #>

Initialize-XFActsScript -ScriptName 'Deploy-xFACts' -ServerInstance $xFACtsServer -Database $xFACtsDB -Execute:$Execute

<# ============================================================================
   CONSTANTS: PATHS AND MAPPINGS
   ----------------------------------------------------------------------------
   The live server roots, the authored repository-to-live deploy map, and the two
   orchestrator files guarded from automatic deployment. $AuthoredDeployMap is the
   inverse of the generated $FileSources map in Publish-GitHubRepository.ps1: the
   two tables partition the repository, authored paths here and generated paths
   there, and every managed repo path belongs to exactly one. Keep them in
   agreement - a path must never appear in both, nor in neither.
   Prefix: (none)
   ============================================================================ #>

# Root of the orchestrator PowerShell script tree.
$ScriptsRoot = "E:\xFACts-PowerShell"
# Root of the Control Center application and documentation-site tree.
$CCRoot      = "E:\xFACts-ControlCenter"
# Root of the authored documentation and planning tree.
$DocsRoot    = "E:\xFACts-Documentation"

# Authored repository-to-live deploy map. Each entry maps a repository path to a
# live directory, with the filename filter set and the recurse flag that define
# which changed files under that prefix are authored-managed. A changed path that
# falls under a prefix but violates its recurse or filter rule is not deployed.
$AuthoredDeployMap = @(
    @{
        RepoPath = "xFACts-PowerShell"
        LivePath = $ScriptsRoot
        Filter   = @("*.ps1", "*.psm1", "*.js")
        Recurse  = $false
    }
    @{
        RepoPath = "xFACts-ControlCenter/scripts"
        LivePath = "$CCRoot\scripts"
        Filter   = @("*.ps1", "*.psm1", "*.psd1")
        Recurse  = $true
    }
    @{
        RepoPath = "xFACts-ControlCenter/public/css"
        LivePath = "$CCRoot\public\css"
        Filter   = @("*.css")
        Recurse  = $false
    }
    @{
        RepoPath = "xFACts-ControlCenter/public/js"
        LivePath = "$CCRoot\public\js"
        Filter   = @("*.js")
        Recurse  = $false
    }
    @{
        RepoPath = "xFACts-ControlCenter/public/docs/pages"
        LivePath = "$CCRoot\public\docs\pages"
        Filter   = @("*.html")
        Recurse  = $true
    }
    @{
        RepoPath = "xFACts-ControlCenter/public/docs/css"
        LivePath = "$CCRoot\public\docs\css"
        Filter   = @("*.css")
        Recurse  = $false
    }
    @{
        RepoPath = "xFACts-ControlCenter/public/docs/js"
        LivePath = "$CCRoot\public\docs\js"
        Filter   = @("*.js")
        Recurse  = $false
    }
    @{
        RepoPath = "xFACts-Documentation/docs"
        LivePath = "$DocsRoot\docs"
        Filter   = @("*.md")
        Recurse  = $false
    }
    @{
        RepoPath = "xFACts-Documentation/Planning"
        LivePath = "$DocsRoot\Planning"
        Filter   = @("*.md")
        Recurse  = $false
    }
    @{
        RepoPath = "xFACts-Documentation/WorkingFiles"
        LivePath = "$DocsRoot\WorkingFiles"
        Filter   = @("*.*")
        Recurse  = $true
    }
)

# The two orchestrator files that must never auto-deploy; they require a manual
# service-stop deployment because the running orchestrator holds them.
$OrchestratorGuardPaths = @(
    "xFACts-PowerShell/xFACts-OrchestratorFunctions.ps1",
    "xFACts-PowerShell/Start-xFACtsOrchestrator.ps1"
)

<# ============================================================================
   FUNCTIONS: GIT OPERATIONS
   ----------------------------------------------------------------------------
   Git command execution against the staging clone. Invoke-GitStaging runs one
   git command with -C targeting the clone, optionally injecting the GitHub token
   as a per-invocation HTTP auth header so it is never written to git config or
   the remote URL, and returns the exit code and combined output.
   Prefix: (none)
   ============================================================================ #>

# Runs one git command against the staging clone, injecting the token as a per-invocation auth header when supplied; returns exit code and output.
function Invoke-GitStaging {
    param(
        [Parameter(Mandatory)][string]$RepoDir,
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$Token
    )

    $gitArgs = @('-C', $RepoDir)

    if ($Token) {
        # Basic auth with the token as the x-access-token password, injected only
        # for this one invocation via -c; the token is never persisted to disk.
        $b64 = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("x-access-token:$Token"))
        $gitArgs += @('-c', "http.extraHeader=Authorization: Basic $b64")
    }

    $gitArgs += $Arguments

    $output = & git @gitArgs 2>&1
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output   = ($output | Out-String)
    }
}

<# ============================================================================
   FUNCTIONS: DEPLOY MAPPING
   ----------------------------------------------------------------------------
   Classification and mapping of changed repository paths. Test-DeployIgnored
   identifies generated-tree and repository-root paths that deploy never touches;
   Resolve-AuthoredMapping maps an authored repository path to its live target,
   honoring each map entry's recurse and filter rules.
   Prefix: (none)
   ============================================================================ #>

# Returns true for repository paths deploy never copies: the generated tree and repository-root files (manifests, top-level docs).
function Test-DeployIgnored {
    param([string]$RepoPath)

    if ($RepoPath.StartsWith("xFACts-Generated/")) { return $true }
    if (-not $RepoPath.Contains("/")) { return $true }
    return $false
}

# Maps an authored repository path to its live target via the deploy map, or returns null when no entry's prefix, recurse, and filter rules match.
function Resolve-AuthoredMapping {
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][array]$Map
    )

    foreach ($entry in $Map) {
        $prefix = "$($entry.RepoPath)/"
        if (-not $RepoPath.StartsWith($prefix)) { continue }

        $relative = $RepoPath.Substring($prefix.Length)

        # Non-recursive sources publish only top-level files.
        if (-not $entry.Recurse -and $relative.Contains("/")) { continue }

        # Extension filter (unless the source takes everything).
        $extension = [System.IO.Path]::GetExtension($RepoPath)
        $matchesFilter = $false
        foreach ($filter in $entry.Filter) {
            if ($filter -eq "*.*") { $matchesFilter = $true; break }
            if ($extension -ieq $filter.TrimStart('*')) { $matchesFilter = $true; break }
        }
        if (-not $matchesFilter) { continue }

        $liveTarget = Join-Path $entry.LivePath ($relative -replace '/', '\')
        return [pscustomobject]@{
            RepoPath   = $RepoPath
            LiveTarget = $liveTarget
            MapRepoPath = $entry.RepoPath
        }
    }

    return $null
}

<# ============================================================================
   EXECUTION: SCRIPT EXECUTION
   ----------------------------------------------------------------------------
   Verifies git and the staging clone, retrieves the token, fetches from GitHub,
   computes the changed files against the fetched branch, classifies each into
   deploy / ignore / orphan-guard / repository-deletion, fast-forwards and copies
   on -Execute, and reports the pulled commit range, files deployed by folder,
   deletions reported, and guard hits. Exit codes: 0 clean, 2 warnings (guard
   hits, reported deletions, or unmapped authored changes), 1 verification or pull
   failure.
   Prefix: (none)
   ============================================================================ #>

Write-Log "=========================================="
Write-Log "xFACts Authored Content Deploy"
Write-Log "=========================================="
Write-Log "Repository: $Owner/$Repo (branch: $Branch)"
Write-Log "Staging:    $StagingRoot"
Write-Log "Mode: $(if ($Execute) { 'EXECUTE' } else { 'PREVIEW' })"
Write-Log "------------------------------------------"

# -- Verify git availability and the staging clone --

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Log "ABORT  git was not found on PATH. Install Git for Windows on the server." "ERROR"
    exit 1
}

if (-not (Test-Path $StagingRoot)) {
    Write-Log "ABORT  Staging clone not found: $StagingRoot" "ERROR"
    Write-Log "       Create it once manually; this script verifies but never creates it." "ERROR"
    exit 1
}

$workTreeCheck = Invoke-GitStaging -RepoDir $StagingRoot -Arguments @('rev-parse', '--is-inside-work-tree')
if ($workTreeCheck.ExitCode -ne 0 -or $workTreeCheck.Output.Trim() -ne 'true') {
    Write-Log "ABORT  $StagingRoot is not a git working tree." "ERROR"
    exit 1
}

$remoteCheck = Invoke-GitStaging -RepoDir $StagingRoot -Arguments @('remote', 'get-url', 'origin')
if ($remoteCheck.ExitCode -ne 0) {
    Write-Log "ABORT  Could not read the 'origin' remote of $StagingRoot." "ERROR"
    exit 1
}

$remoteNormalized = (($remoteCheck.Output.Trim()) -replace '\.git$', '').TrimEnd('/').ToLower()
if (-not $remoteNormalized.EndsWith("$($Owner.ToLower())/$($Repo.ToLower())")) {
    Write-Log "ABORT  Staging remote does not point at $Owner/$Repo (found: $($remoteCheck.Output.Trim()))." "ERROR"
    exit 1
}

Write-Log "Staging clone verified (working tree, origin -> $Owner/$Repo)." "SUCCESS"

# -- Retrieve the GitHub token --

Write-Log "Retrieving GitHub credentials..."

$creds = Get-ServiceCredentials -ServiceName $ServiceName
if (-not $creds -or -not $creds.PersonalAccessToken) {
    Write-Log "ABORT  Failed to retrieve GitHub credentials for service '$ServiceName'." "ERROR"
    exit 1
}
$token = $creds.PersonalAccessToken

# -- Fetch and compute the changed files --

$beforeResult = Invoke-GitStaging -RepoDir $StagingRoot -Arguments @('rev-parse', 'HEAD')
if ($beforeResult.ExitCode -ne 0) {
    Write-Log "ABORT  Could not read the current HEAD of the staging clone." "ERROR"
    exit 1
}
$beforeSha = $beforeResult.Output.Trim()

Write-Log "Fetching $Owner/$Repo ($Branch) into staging..."
$fetchResult = Invoke-GitStaging -RepoDir $StagingRoot -Arguments @('fetch', 'origin', $Branch) -Token $token
if ($fetchResult.ExitCode -ne 0) {
    Write-Log "ABORT  git fetch failed:" "ERROR"
    Write-Log "       $($fetchResult.Output.Trim())" "ERROR"
    exit 1
}

$afterResult = Invoke-GitStaging -RepoDir $StagingRoot -Arguments @('rev-parse', "origin/$Branch")
if ($afterResult.ExitCode -ne 0) {
    Write-Log "ABORT  Could not resolve origin/$Branch after fetch." "ERROR"
    exit 1
}
$afterSha = $afterResult.Output.Trim()

if ($beforeSha -eq $afterSha) {
    Write-Log ""
    Write-Log "Staging clone is already current ($($beforeSha.Substring(0,7))); nothing to deploy." "SUCCESS"
    exit 0
}

$diffResult = Invoke-GitStaging -RepoDir $StagingRoot -Arguments @('diff', '--name-status', $beforeSha, $afterSha)
if ($diffResult.ExitCode -ne 0) {
    Write-Log "ABORT  git diff failed:" "ERROR"
    Write-Log "       $($diffResult.Output.Trim())" "ERROR"
    exit 1
}

# Parse the name-status diff into changed (add/modify/copy-new/rename-new) and
# deleted (delete/rename-old) repository paths.
$changedPaths = @()
$deletedPaths = @()

foreach ($line in ($diffResult.Output -split "\r?\n")) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $fields = $line -split "`t"
    $status = $fields[0].Substring(0, 1)

    switch ($status) {
        'A' { $changedPaths += $fields[1] }
        'M' { $changedPaths += $fields[1] }
        'C' { if ($fields.Count -ge 3) { $changedPaths += $fields[2] } }
        'R' {
            if ($fields.Count -ge 3) {
                $deletedPaths += $fields[1]
                $changedPaths += $fields[2]
            }
        }
        'D' { $deletedPaths += $fields[1] }
        default { }
    }
}

# -- Classify the changed paths --

$toDeploy = @()
$guardHits = @()
$unmapped = @()
$ignoredCount = 0

foreach ($path in $changedPaths) {
    if ($OrchestratorGuardPaths -contains $path) {
        $guardHits += $path
        continue
    }

    $resolved = Resolve-AuthoredMapping -RepoPath $path -Map $AuthoredDeployMap
    if ($resolved) {
        $toDeploy += $resolved
    }
    elseif (Test-DeployIgnored -RepoPath $path) {
        $ignoredCount++
    }
    else {
        $unmapped += $path
    }
}

# Repository deletions: report authored paths that were removed upstream but are
# still present live. Never delete a live file.
$deletionsReported = @()
foreach ($path in $deletedPaths) {
    $resolved = Resolve-AuthoredMapping -RepoPath $path -Map $AuthoredDeployMap
    if ($resolved -and (Test-Path $resolved.LiveTarget)) {
        $deletionsReported += $resolved.LiveTarget
    }
}

Write-Log ""
Write-Log "Pulled commit range: $($beforeSha.Substring(0,7))..$($afterSha.Substring(0,7))"
Write-Log "  Changed authored files to deploy: $($toDeploy.Count)"
Write-Log "  Generated/root paths ignored:     $ignoredCount"
if ($unmapped.Count -gt 0) {
    Write-Log "  Changed paths under an authored prefix but excluded by recurse/filter: $($unmapped.Count)" "WARN"
    foreach ($u in $unmapped) { Write-Log "    UNMAPPED  $u" "WARN" }
}

# -- Orchestrator guard --

if ($guardHits.Count -gt 0) {
    Write-Log ""
    Write-Log "  ORCHESTRATOR GUARD - the following changed but were NOT deployed:" "WARN"
    foreach ($g in $guardHits) { Write-Log "    HELD  $g" "WARN" }
    Write-Log "  These require a manual service-stop deployment. All other changed files still deploy." "WARN"
}

# -- Fast-forward and copy (execute) or list (preview) --

if (-not $Execute) {
    Write-Log ""
    Write-Log "  PREVIEW - Files that would be deployed:" "WARN"
    foreach ($item in $toDeploy) {
        Write-Log "    DEPLOY  $($item.RepoPath) -> $($item.LiveTarget)"
    }
}
else {
    # Fast-forward the working tree so the copy sources hold the pulled content.
    $mergeResult = Invoke-GitStaging -RepoDir $StagingRoot -Arguments @('merge', '--ff-only', "origin/$Branch")
    if ($mergeResult.ExitCode -ne 0) {
        Write-Log "ABORT  Could not fast-forward the staging clone (it may have diverged):" "ERROR"
        Write-Log "       $($mergeResult.Output.Trim())" "ERROR"
        exit 1
    }

    Write-Log ""
    Write-Log "Deploying changed authored files..."
    $deployErrors = 0
    foreach ($item in $toDeploy) {
        $source = Join-Path $StagingRoot ($item.RepoPath -replace '/', '\')
        $targetDir = Split-Path $item.LiveTarget -Parent

        try {
            if (-not (Test-Path $targetDir)) {
                New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
            }
            Copy-Item -Path $source -Destination $item.LiveTarget -Force -ErrorAction Stop
            Write-Log "  DEPLOY  $($item.RepoPath)" "SUCCESS"
        }
        catch {
            Write-Log "  FAILED  $($item.RepoPath): $($_.Exception.Message)" "ERROR"
            $deployErrors++
        }
    }
    Write-Log "  Deployed: $($toDeploy.Count - $deployErrors) of $($toDeploy.Count)"
    if ($deployErrors -gt 0) {
        Write-Log "  $deployErrors file(s) failed to copy. See errors above." "ERROR"
    }
}

# -- Deletions report --

if ($deletionsReported.Count -gt 0) {
    Write-Log ""
    Write-Log "  Deleted in repo, still present live (not removed automatically):" "WARN"
    foreach ($d in $deletionsReported) {
        Write-Log "    DELETED-IN-REPO  $d" "WARN"
    }
}

# -- Summary --

Write-Log ""
Write-Log "=========================================="
Write-Log "Summary"
Write-Log "=========================================="
Write-Log "  Commit range:   $($beforeSha.Substring(0,7))..$($afterSha.Substring(0,7))"

# Files deployed grouped by their live folder mapping.
$byFolder = $toDeploy | Group-Object -Property MapRepoPath
foreach ($group in $byFolder) {
    Write-Log "  $($group.Name): $($group.Count) file(s)"
}

Write-Log "  Deletions reported: $($deletionsReported.Count)"
Write-Log "  Orchestrator guard hits: $($guardHits.Count)"
Write-Log "  Unmapped authored changes: $($unmapped.Count)"

$hasWarnings = ($guardHits.Count -gt 0) -or ($deletionsReported.Count -gt 0) -or ($unmapped.Count -gt 0)

if (-not $Execute) {
    Write-Log ""
    Write-Log "PREVIEW MODE - No changes were made. Run with -Execute to deploy." "WARN"
    if ($hasWarnings) { exit 2 }
    exit 0
}
else {
    Write-Log ""
    if ($hasWarnings) {
        Write-Log "Deploy complete (with warnings)" "WARN"
        exit 2
    }
    else {
        Write-Log "Deploy complete" "SUCCESS"
        exit 0
    }
}

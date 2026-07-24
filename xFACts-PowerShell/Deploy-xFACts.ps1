<#
.SYNOPSIS
    Deploys authored xFACts content from GitHub into the live server folders.

.DESCRIPTION
    The deploy half of the inverted sync: GitHub is the source of truth for
    authored content, and this script pulls it into a server-side staging clone
    and reconciles the changed authored files into their live locations. It
    verifies the staging clone (E:\xFACts-Staging by default) exists, is a git
    working tree, and points at the tnjazzgrass/xFACts remote - any verification
    failure aborts; the clone is never created or repaired here. It pulls from
    GitHub using the GitHub_xFACts credential, injecting the token per git
    invocation so it is never persisted to disk, determines which files the pull
    changed, and maps authored repository paths to live paths via
    $AuthoredDeployMap (the inverse of the generated map in
    Publish-GitHubRepository.ps1). Generated repository paths (xFACts-Generated/*,
    the manifests) and repository-root files are never touched.

    On -Execute the script copies changed authored files to live and DELETES from
    live both the authored files removed upstream in the repository and the files
    retired in dbo.Object_Registry (is_active = 0) that still exist under a mapped
    authored tree; a retired file is never re-copied even if the repository edited
    it (catalog retirement wins). Deletions outside the mapped authored trees are
    never applied. Every deployed code/asset file is audited against
    dbo.Object_Registry and an unregistered file is warned about, not blocked.

    Deploying or deleting either orchestrator file (the running engine holds them)
    or any Control Center script file (Pode dot-sources routes/APIs and imports the
    shared module at startup) emits a prominent restart-required warning naming the
    service, and the run exits 2; every other file still deploys. Static assets
    (css/js/html/docs) never need a restart. Preview by default; -Execute performs
    the pull merge, the copies, and the deletions.

    Exit codes: 0 deployed cleanly; 2 deployed with warnings (a service restart is
    required - named in the summary - and/or registration/mapping warnings); 1 on
    a verification, pull, or file-operation failure.

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
    Required to fast-forward the staging clone and copy and delete files on live.
    Without it, the run fetches and reports what would deploy and delete, changing
    nothing live.

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
    FUNCTIONS: OBJECT REGISTRY
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

# 2026-07-23  Serve authored docs JSON. Authored *.json under xFACts-Documentation/docs
#             now deploys to $CCRoot\public\docs\data, which the /docs static route
#             serves, so a doc-site page can fetch it at /docs/data/. Previously it
#             went to $DocsRoot\docs, which no static route serves, leaving it
#             unreachable over HTTP. Resolve-AuthoredMapping returns the first
#             matching entry, so a repository path has exactly one live target: the
#             new entry takes *.json and the existing entry now takes *.md only,
#             keeping the two filters disjoint rather than order-dependent. The
#             target directory is created on first copy.
# 2026-07-23  Deploy authored docs JSON. The xFACts-Documentation/docs deploy-map
#             entry now filters *.json alongside *.md, so authored JSON under docs
#             (backlog.json) deploys GitHub -> live; previously .json fell through
#             to the UNMAPPED bucket and was never copied. Non-recursive top-level
#             scope is unchanged, and .json stays out of the Object_Registry audit.
# 2026-07-22  Robust git resolution. git is resolved once at startup - PATH first,
#             then the standard Git for Windows install locations ($GitProbePaths) -
#             and every git call runs through the resolved executable
#             (Invoke-GitStaging -GitExe). Fixes "git was not found on PATH" when the
#             pipeline runs in the Pode service context, which does not reliably carry
#             Git's PATH entry. Aborts only when neither PATH nor the probed locations
#             resolve, naming the probed paths.
# 2026-07-21  Self-sufficient deploy. Deletions are now applied on -Execute:
#             authored files removed upstream and files retired in Object_Registry
#             (is_active = 0) under a mapped authored tree are deleted from live
#             (previewed as DELETE lines, counted in the summary); a retired file is
#             never re-copied (catalog retirement wins). Deployed code/asset files
#             are audited against Object_Registry and unregistered files warned.
#             The orchestrator hold-back is retired: the two orchestrator files
#             deploy like any other, and deploying/deleting them or any Control
#             Center script file emits a restart-required warning naming the service
#             and exits 2 (structured [RESTART-REQUIRED:...] markers the pipeline and
#             Admin modal surface). Exit codes: 0 clean, 2 warnings/restart, 1 fail.
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
   The live server roots, the authored repository-to-live deploy map, the two
   orchestrator files that trigger a restart-required warning when deployed, and
   the Git executable probe locations. $AuthoredDeployMap is the inverse of the
   generated $FileSources map in Publish-GitHubRepository.ps1: the
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
    # Authored docs data, projected cross-root into the served site tree. This is
    # the only entry where the repository path does not predict the live path:
    # every other entry differs from its repository path by root prefix alone, so
    # the live location is readable straight off the repository location. Here it
    # is not - the file is authored under xFACts-Documentation and lands under
    # xFACts-ControlCenter. Deliberate: backlog.json is authored beside the specs
    # whose work it plans, and has to be served from the site tree because
    # $DocsRoot is served by no static route. A second authored-data file needing
    # the same treatment is the trigger to formalize the pattern properly rather
    # than extend the exception a second time.
    @{
        RepoPath = "xFACts-Documentation/docs"
        LivePath = "$CCRoot\public\docs\data"
        Filter   = @("*.json")
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

# The two orchestrator engine files (live paths). The running engine holds these,
# so deploying or deleting either requires an Orchestrator service restart; they
# deploy like any other file but raise the restart-required warning.
$OrchestratorFiles = @(
    (Join-Path $ScriptsRoot "xFACts-OrchestratorFunctions.ps1"),
    (Join-Path $ScriptsRoot "Start-xFACtsOrchestrator.ps1")
)

# Standard Git for Windows install locations, probed in order when git is not on
# PATH. The Pode service context that runs the pipeline does not reliably carry
# Git's PATH entry, so resolution falls back to these before aborting.
$GitProbePaths = @(
    "C:\Program Files\Git\cmd\git.exe",
    "C:\Program Files (x86)\Git\cmd\git.exe"
)

<# ============================================================================
   FUNCTIONS: GIT OPERATIONS
   ----------------------------------------------------------------------------
   Git command execution against the staging clone. Invoke-GitStaging runs one
   command through the resolved git executable with -C targeting the clone,
   optionally injecting the GitHub token as a per-invocation HTTP auth header so it
   is never written to git config or the remote URL, and returns the exit code and
   combined output.
   Prefix: (none)
   ============================================================================ #>

# Runs one command through the resolved git executable against the staging clone, injecting the token as a per-invocation auth header when supplied; returns exit code and output.
function Invoke-GitStaging {
    param(
        [Parameter(Mandatory)][string]$GitExe,
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

    $output = & $GitExe @gitArgs 2>&1
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
   FUNCTIONS: OBJECT REGISTRY
   ----------------------------------------------------------------------------
   Object_Registry access for the two catalog-driven behaviors: the deploy-set
   registration audit (Get-ActiveRegisteredNames) and the retirement
   reconciliation (Get-RetiredLivePaths). Test-PathManagedAuthored gates a
   retirement deletion to files under a mapped authored tree, so a retired row can
   never remove anything outside the surface deploy manages.
   Prefix: (none)
   ============================================================================ #>

# Returns a lookup of active Object_Registry file names (is_active = 1) for the deploy-set registration audit.
function Get-ActiveRegisteredNames {
    param()

    $query = @"
SELECT DISTINCT object_name
FROM dbo.Object_Registry
WHERE is_active = 1
  AND object_category IN ('PowerShell', 'WebAsset', 'Documentation')
"@
    $rows = Get-SqlData -Query $query -Timeout 60

    $set = @{}
    if ($rows) {
        foreach ($row in @($rows)) { $set[[string]$row.object_name] = $true }
    }
    return $set
}

# Returns the live paths of retired Object_Registry file rows (is_active = 0) for retirement reconciliation.
function Get-RetiredLivePaths {
    param()

    $query = @"
SELECT object_path
FROM dbo.Object_Registry
WHERE is_active = 0
  AND object_path IS NOT NULL
  AND object_category IN ('PowerShell', 'WebAsset', 'Documentation')
"@
    $rows = Get-SqlData -Query $query -Timeout 60

    $paths = @()
    if ($rows) {
        foreach ($row in @($rows)) {
            if ($row.object_path -isnot [DBNull] -and $row.object_path) { $paths += [string]$row.object_path }
        }
    }
    return $paths
}

# Returns true when a live path falls under one of the authored deploy map's live roots.
function Test-PathManagedAuthored {
    param(
        [Parameter(Mandatory)][string]$LivePath,
        [Parameter(Mandatory)][array]$Map
    )

    foreach ($entry in $Map) {
        $root = $entry.LivePath.TrimEnd('\') + '\'
        if ($LivePath.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

<# ============================================================================
   EXECUTION: SCRIPT EXECUTION
   ----------------------------------------------------------------------------
   Verifies git and the staging clone, retrieves the token, fetches from GitHub,
   loads the Object_Registry catalog, computes the changed files against the
   fetched branch, classifies each into deploy / delete / ignore / unmapped
   (retired files are skipped from the copy and deleted instead), audits the
   deploy set against the registry, fast-forwards and applies the copies and
   deletions on -Execute, determines whether an Orchestrator or Control Center
   restart is required, and reports the commit range, files deployed by folder,
   deletion count, warnings, and restart markers. Exit codes: 0 clean, 2 warnings
   (restart required, unregistered, retired-skip, or unmapped), 1 verification,
   pull, or file-operation failure.
   Prefix: (none)
   ============================================================================ #>

Write-Log "=========================================="
Write-Log "xFACts Authored Content Deploy"
Write-Log "=========================================="
Write-Log "Repository: $Owner/$Repo (branch: $Branch)"
Write-Log "Staging:    $StagingRoot"
Write-Log "Mode: $(if ($Execute) { 'EXECUTE' } else { 'PREVIEW' })"
Write-Log "------------------------------------------"

# -- Resolve git and verify the staging clone --

# Prefer git on PATH; fall back to the standard install locations when the service
# context does not carry Git's PATH entry. Every git call uses the resolved path.
$gitExe = (Get-Command git -ErrorAction SilentlyContinue).Source
if (-not $gitExe) {
    $gitExe = $GitProbePaths | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $gitExe) {
    Write-Log "ABORT  git was not found on PATH or at the standard install locations." "ERROR"
    Write-Log "       Probed: $($GitProbePaths -join ', ')" "ERROR"
    Write-Log "       Install Git for Windows on the server, or add git to the service PATH." "ERROR"
    exit 1
}
Write-Log "git resolved: $gitExe" "SUCCESS"

if (-not (Test-Path $StagingRoot)) {
    Write-Log "ABORT  Staging clone not found: $StagingRoot" "ERROR"
    Write-Log "       Create it once manually; this script verifies but never creates it." "ERROR"
    exit 1
}

$workTreeCheck = Invoke-GitStaging -GitExe $gitExe -RepoDir $StagingRoot -Arguments @('rev-parse', '--is-inside-work-tree')
if ($workTreeCheck.ExitCode -ne 0 -or $workTreeCheck.Output.Trim() -ne 'true') {
    Write-Log "ABORT  $StagingRoot is not a git working tree." "ERROR"
    exit 1
}

$remoteCheck = Invoke-GitStaging -GitExe $gitExe -RepoDir $StagingRoot -Arguments @('remote', 'get-url', 'origin')
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

$beforeResult = Invoke-GitStaging -GitExe $gitExe -RepoDir $StagingRoot -Arguments @('rev-parse', 'HEAD')
if ($beforeResult.ExitCode -ne 0) {
    Write-Log "ABORT  Could not read the current HEAD of the staging clone." "ERROR"
    exit 1
}
$beforeSha = $beforeResult.Output.Trim()

Write-Log "Fetching $Owner/$Repo ($Branch) into staging..."
$fetchResult = Invoke-GitStaging -GitExe $gitExe -RepoDir $StagingRoot -Arguments @('fetch', 'origin', $Branch) -Token $token
if ($fetchResult.ExitCode -ne 0) {
    Write-Log "ABORT  git fetch failed:" "ERROR"
    Write-Log "       $($fetchResult.Output.Trim())" "ERROR"
    exit 1
}

$afterResult = Invoke-GitStaging -GitExe $gitExe -RepoDir $StagingRoot -Arguments @('rev-parse', "origin/$Branch")
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

$diffResult = Invoke-GitStaging -GitExe $gitExe -RepoDir $StagingRoot -Arguments @('diff', '--name-status', $beforeSha, $afterSha)
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

# -- Load the Object_Registry catalog (registration audit + retirement) --

Write-Log ""
Write-Log "Loading Object_Registry catalog..."
$activeNames  = Get-ActiveRegisteredNames
$retiredPaths = Get-RetiredLivePaths
Write-Log "  Active file rows: $($activeNames.Count)   Retired file rows: $($retiredPaths.Count)"
if ($activeNames.Count -eq 0) {
    Write-Log "  WARN  Object_Registry returned no active file rows; the registration audit will flag every deployed file." "WARN"
}

# Retired live paths as a lookup for the copy-skip check. Catalog retirement wins
# over a repository edit: a retired file is never re-copied, only deleted.
$retiredLiveSet = @{}
foreach ($rp in $retiredPaths) { $retiredLiveSet[$rp.ToLower()] = $true }

# Deployed code/asset file types audited against Object_Registry. Documentation
# markdown and working files are not catalog objects and are not audited.
$auditExtensions = @('.ps1', '.psm1', '.psd1', '.css', '.js', '.html')

# -- Classify the changed paths --

$toDeploy       = @()
$unmapped       = @()
$unregistered   = @()
$retiredSkipped = @()
$ignoredCount   = 0

foreach ($path in $changedPaths) {
    $resolved = Resolve-AuthoredMapping -RepoPath $path -Map $AuthoredDeployMap
    if ($resolved) {
        if ($retiredLiveSet.ContainsKey($resolved.LiveTarget.ToLower())) {
            # Retired in the catalog: skip the copy; the retirement pass deletes it.
            $retiredSkipped += $resolved.RepoPath
            continue
        }
        $toDeploy += $resolved

        # Registration audit: a deployed code/asset file must have an active row.
        $leaf = Split-Path $resolved.LiveTarget -Leaf
        $ext  = [System.IO.Path]::GetExtension($leaf).ToLower()
        if (($auditExtensions -contains $ext) -and -not $activeNames.ContainsKey($leaf)) {
            $unregistered += $path
        }
    }
    elseif (Test-DeployIgnored -RepoPath $path) {
        $ignoredCount++
    }
    else {
        $unmapped += $path
    }
}

# -- Build the deletion set (repository removals + catalog retirements) --

# Live paths to delete, deduped case-insensitively. Only files under a mapped
# authored tree are ever eligible; generated, root, and unmapped paths never
# reach live disk.
$deleteSet = @{}

# Repository deletions: authored paths removed upstream, mapped and present live.
foreach ($path in $deletedPaths) {
    $resolved = Resolve-AuthoredMapping -RepoPath $path -Map $AuthoredDeployMap
    if ($resolved -and (Test-Path $resolved.LiveTarget)) {
        $deleteSet[$resolved.LiveTarget.ToLower()] = $resolved.LiveTarget
    }
}

# Catalog retirements: is_active = 0 rows whose live file is present and sits
# under a mapped authored tree.
foreach ($rp in $retiredPaths) {
    if ((Test-Path $rp) -and (Test-PathManagedAuthored -LivePath $rp -Map $AuthoredDeployMap)) {
        $deleteSet[$rp.ToLower()] = $rp
    }
}

$toDelete = @($deleteSet.Values)

# -- Determine restart scope from the applied change set --

# The two orchestrator engine files and any Control Center script file
# (routes/APIs/modules/config Pode loads at startup) require a service restart
# when deployed or deleted; static assets do not.
$appliedLivePaths = @()
foreach ($item in $toDeploy) { $appliedLivePaths += $item.LiveTarget }
$appliedLivePaths += $toDelete

$ccScriptsRoot = "$CCRoot\scripts\"
$orchestratorRestart = $false
$ccRestart = $false
foreach ($lp in $appliedLivePaths) {
    if ($OrchestratorFiles -contains $lp) { $orchestratorRestart = $true }
    if ($lp.StartsWith($ccScriptsRoot, [System.StringComparison]::OrdinalIgnoreCase)) { $ccRestart = $true }
}

# -- Report what will happen --

Write-Log ""
Write-Log "Pulled commit range: $($beforeSha.Substring(0,7))..$($afterSha.Substring(0,7))"
Write-Log "  Changed authored files to deploy: $($toDeploy.Count)"
Write-Log "  Files to delete (repo removals + retirements): $($toDelete.Count)"
Write-Log "  Generated/root paths ignored:     $ignoredCount"
if ($retiredSkipped.Count -gt 0) {
    Write-Log "  Retired in catalog, not deployed: $($retiredSkipped.Count)" "WARN"
    foreach ($r in $retiredSkipped) { Write-Log "    RETIRED  $r" "WARN" }
}
if ($unmapped.Count -gt 0) {
    Write-Log "  Changed paths under an authored prefix but excluded by recurse/filter: $($unmapped.Count)" "WARN"
    foreach ($u in $unmapped) { Write-Log "    UNMAPPED  $u" "WARN" }
}
if ($unregistered.Count -gt 0) {
    Write-Log "  Deployed files not registered in Object_Registry: $($unregistered.Count)" "WARN"
    foreach ($u in $unregistered) { Write-Log "    UNREGISTERED  $u" "WARN" }
}

# -- Apply (execute) or list (preview) --

$deployErrors = 0
$deleteErrors = 0

if (-not $Execute) {
    Write-Log ""
    Write-Log "  PREVIEW - changes that would be applied:" "WARN"
    foreach ($item in $toDeploy) {
        Write-Log "    DEPLOY  $($item.RepoPath) -> $($item.LiveTarget)"
    }
    foreach ($d in $toDelete) {
        Write-Log "    DELETE  $d"
    }
}
else {
    # Fast-forward the working tree so the copy sources hold the pulled content.
    $mergeResult = Invoke-GitStaging -GitExe $gitExe -RepoDir $StagingRoot -Arguments @('merge', '--ff-only', "origin/$Branch")
    if ($mergeResult.ExitCode -ne 0) {
        Write-Log "ABORT  Could not fast-forward the staging clone (it may have diverged):" "ERROR"
        Write-Log "       $($mergeResult.Output.Trim())" "ERROR"
        exit 1
    }

    Write-Log ""
    Write-Log "Deploying changed authored files..."
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

    # Delete files removed upstream and files retired in the catalog.
    if ($toDelete.Count -gt 0) {
        Write-Log ""
        Write-Log "Deleting removed and retired files..."
        foreach ($d in $toDelete) {
            try {
                Remove-Item -Path $d -Force -ErrorAction Stop
                Write-Log "  DELETE  $d" "SUCCESS"
            }
            catch {
                Write-Log "  FAILED  $d : $($_.Exception.Message)" "ERROR"
                $deleteErrors++
            }
        }
        Write-Log "  Deleted: $($toDelete.Count - $deleteErrors) of $($toDelete.Count)"
    }

    if (($deployErrors + $deleteErrors) -gt 0) {
        Write-Log "  $($deployErrors + $deleteErrors) file operation(s) failed. See errors above." "ERROR"
    }
}

# -- Restart warnings (structured markers the wrapper and Admin modal surface) --

if ($orchestratorRestart) {
    Write-Log ""
    Write-Log "  RESTART REQUIRED: Orchestrator - drain in-flight processes and restart the Orchestrator service for changes to take effect. [RESTART-REQUIRED:Orchestrator]" "WARN"
}
if ($ccRestart) {
    Write-Log ""
    Write-Log "  RESTART REQUIRED: Control Center - restart Control Center (Pode) for changes to take effect. [RESTART-REQUIRED:ControlCenter]" "WARN"
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

Write-Log "  Files deployed:    $($toDeploy.Count)"
Write-Log "  Files deleted:     $($toDelete.Count)"
Write-Log "  Retired (skipped): $($retiredSkipped.Count)"
Write-Log "  Unregistered:      $($unregistered.Count)"
Write-Log "  Unmapped changes:  $($unmapped.Count)"
if ($orchestratorRestart) { Write-Log "  Restart required: Orchestrator service" "WARN" }
if ($ccRestart)           { Write-Log "  Restart required: Control Center (Pode)" "WARN" }

$hasFailures = ($deployErrors -gt 0) -or ($deleteErrors -gt 0)
$hasWarnings = $orchestratorRestart -or $ccRestart -or ($unregistered.Count -gt 0) -or ($unmapped.Count -gt 0) -or ($retiredSkipped.Count -gt 0)

if ($hasFailures) {
    Write-Log ""
    Write-Log "Deploy completed with FAILURES - see errors above." "ERROR"
    exit 1
}

if (-not $Execute) {
    Write-Log ""
    Write-Log "PREVIEW MODE - No changes were made. Run with -Execute to apply." "WARN"
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

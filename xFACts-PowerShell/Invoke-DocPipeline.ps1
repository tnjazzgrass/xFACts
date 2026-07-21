<#
.SYNOPSIS
    xFACts - Documentation Pipeline Wrapper

.DESCRIPTION
    Orchestrates the documentation pipeline in sequence
    (Deploy > Generate DDL > Confluence > Publish GitHub > Manifests), writing
    real-time status to a JSON file that the Control Center Admin page polls for
    progress updates.

    Every step is individually toggleable and defaults on, so a bare run performs
    the full sequence. For backward compatibility with the Admin doc-pipeline API,
    when -StepsJson is supplied it selects the steps by key and the per-step
    switches are ignored.

    Launched by the /api/admin/doc-pipeline endpoint (fire-and-forget).

.PARAMETER StepsJson
    Comma-separated step keys to run (deploy, generate_ddl, publish_confluence,
    publish_github, manifests). When supplied, it selects the steps and the
    per-step switches are ignored. When empty, the per-step switches govern.

.PARAMETER StatusFile
    Path to the status JSON file the Admin page polls.

.PARAMETER Deploy
    Run the Deploy step (deploy authored content GitHub -> live). Default on.

.PARAMETER GenerateDDL
    Run the Generate DDL Reference step. Default on.

.PARAMETER Confluence
    Run the Confluence publish/export step. Default on.

.PARAMETER PublishGitHub
    Run the GitHub publish step (generated content). Default on.

.PARAMETER Manifests
    Run the dedicated manifest rebuild step. Default on. When this step runs in the
    same invocation as PublishGitHub, the GitHub step is told to skip its own
    manifest rebuild so manifests build exactly once.

.PARAMETER PublishToConfluence
    Shapes the Confluence step: publish to the Confluence server.

.PARAMETER ExportMarkdown
    Shapes the Confluence step: export markdown.

.PARAMETER IncludeSQLObjects
    Reserved option passed through by the Admin doc-pipeline API. Inert until that
    endpoint is updated.

.PARAMETER IncludeJSON
    Reserved option passed through by the Admin doc-pipeline API. Inert until that
    endpoint is updated.

.COMPONENT
    Documentation.Pipeline

.NOTES
    File Name : Invoke-DocPipeline.ps1
    Location  : E:\xFACts-PowerShell

    FILE ORGANIZATION
    -----------------
    CHANGELOG: CHANGE HISTORY
    PARAMETERS: SCRIPT PARAMETERS
    CONSTANTS: PIPELINE DEFINITION
    VARIABLES: SCRIPT-SCOPE STATE
    FUNCTIONS: STATUS REPORTING
    EXECUTION: SCRIPT EXECUTION
#>

<# ============================================================================
   CHANGELOG: CHANGE HISTORY
   ----------------------------------------------------------------------------
   Date-stamped change history. Each entry is one ISO date line followed by an
   indented description. Entries appear most-recent first.
   Prefix: (none)
   ============================================================================ #>

# 2026-07-21  Pipeline flip (Task 1). New step order: Deploy > Generate DDL >
#             Confluence > Publish GitHub > Manifests. Added the deploy step
#             (Deploy-xFACts.ps1) and the dedicated manifest step (the publisher in
#             -ManifestsOnly mode). Every step is now individually toggleable via a
#             per-step switch defaulting on, so a bare run performs the full
#             sequence; -StepsJson still selects steps by key for the existing
#             Admin API call, which is preserved unchanged. Manifest-once: when the
#             manifest step is selected alongside the GitHub step, the GitHub step
#             runs with -SkipManifests so manifests build exactly once; when the
#             manifest step is not selected, the GitHub step rebuilds them itself.
# 2026-07-21  Removed the retired consolidate_upload step from the pipeline
#             definition (Consolidate-UploadFiles.ps1 is retired; the script
#             file itself is retained). The -IncludeSQLObjects and -IncludeJSON
#             switches stay declared because the Admin doc-pipeline API still
#             passes them; they are inert until that endpoint is updated.
# 2026-04-02  Bumped output truncation from 2000 to 8000 chars.
#             Added 'warning' status for exit code 2 (success with warnings).
#             Pipeline continues on warning - only halts on failure (non-zero,
#             non-2 exit codes).
# 2026-03-01  Initial implementation
#             Sequential step execution with per-step status JSON updates
#             Stdout/stderr capture with truncation for API response size
#             Pipeline halts on first failure

<# ============================================================================
   PARAMETERS: SCRIPT PARAMETERS
   ----------------------------------------------------------------------------
   The step selector (StepsJson) and per-step toggles, the status-file path, and
   the publish/export options that shape the Confluence step. StepsJson, when
   supplied, overrides the per-step switches for backward compatibility with the
   Admin doc-pipeline API.
   Prefix: (none)
   ============================================================================ #>

[CmdletBinding()]
param(
    [string]$StepsJson,
    [string]$StatusFile = "E:\xFACts-PowerShell\Logs\doc-pipeline-status.json",
    [switch]$Deploy = $true,
    [switch]$GenerateDDL = $true,
    [switch]$Confluence = $true,
    [switch]$PublishGitHub = $true,
    [switch]$Manifests = $true,
    [switch]$PublishToConfluence,
    [switch]$ExportMarkdown,
    [switch]$IncludeSQLObjects,
    [switch]$IncludeJSON
)

<# ============================================================================
   CONSTANTS: PIPELINE DEFINITION
   ----------------------------------------------------------------------------
   The scripts root, the log directory, and the ordered pipeline definition.
   Order matters: steps run in declaration order. The Confluence step's arguments
   are shaped by the publish/export options; the GitHub step's -SkipManifests is
   added at run time when the manifest step is also selected (see EXECUTION), so
   manifests build exactly once.
   Prefix: (none)
   ============================================================================ #>

# Root directory containing the documentation pipeline scripts.
$ScriptsRoot = "E:\xFACts-PowerShell"

# Log directory derived from the status-file path.
$logDir = Split-Path $StatusFile -Parent

# Pipeline definition - order matters.
$pipeline = @(
    @{
        Key    = 'deploy'
        Label  = 'Deploy Authored Content'
        Script = 'Deploy-xFACts.ps1'
        Args   = '-Execute'
    },
    @{
        Key    = 'generate_ddl'
        Label  = 'Generate DDL Reference'
        Script = 'Generate-DDLReference.ps1'
        Args   = '-Execute'
    },
    @{
        Key    = 'publish_confluence'
        Label  = 'Publish to Confluence'
        Script = 'Publish-ConfluenceDocumentation.ps1'
        Args   = if ($PublishToConfluence -and $ExportMarkdown) { '-Execute' }
                 elseif ($ExportMarkdown -and -not $PublishToConfluence) { '-ExportOnly' }
                 elseif ($PublishToConfluence) { '-Execute' }
                 else { '-ExportOnly' }
    },
    @{
        Key    = 'publish_github'
        Label  = 'Publish to GitHub'
        Script = 'Publish-GitHubRepository.ps1'
        Args   = '-Execute'
    },
    @{
        Key    = 'manifests'
        Label  = 'Rebuild Manifests'
        Script = 'Publish-GitHubRepository.ps1'
        Args   = '-Execute -ManifestsOnly'
    }
)

<# ============================================================================
   VARIABLES: SCRIPT-SCOPE STATE
   ----------------------------------------------------------------------------
   Mutable run state: the status structure written to the status file and the
   flag tracking whether any step finished with warnings.
   Prefix: (none)
   ============================================================================ #>

# Initialize status structure.
$status = @{
    started_at = (Get-Date).ToString('o')
    complete   = $false
    success    = $false
    results    = @()
}

# Track whether any step completed with warnings.
$pipelineHasWarnings = $false

<# ============================================================================
   FUNCTIONS: STATUS REPORTING
   ----------------------------------------------------------------------------
   Serializes the current status structure to the status file the Admin page
   polls.
   Prefix: (none)
   ============================================================================ #>

# Serialize the current status structure to the status file.
function Write-Status {
    param()
    $status | ConvertTo-Json -Depth 5 | Out-File -FilePath $StatusFile -Encoding UTF8 -Force
}

<# ============================================================================
   EXECUTION: SCRIPT EXECUTION
   ----------------------------------------------------------------------------
   Resolves which steps run (StepsJson selection when supplied, otherwise the
   per-step switches), ensures the log directory exists, writes the initial
   status, then runs each selected step in order, capturing output and halting on
   failure. The GitHub step is given -SkipManifests when the manifest step also
   runs, so manifests build exactly once.
   Prefix: (none)
   ============================================================================ #>

# When StepsJson is supplied it selects the steps (backward compatibility with the
# Admin API); otherwise the per-step switches do.
$useStepsJson = -not [string]::IsNullOrWhiteSpace($StepsJson)
$requestedSteps = if ($useStepsJson) { ($StepsJson -split ',') | ForEach-Object { $_.Trim() } } else { @() }
$stepSwitches = [ordered]@{
    deploy             = [bool]$Deploy
    generate_ddl       = [bool]$GenerateDDL
    publish_confluence = [bool]$Confluence
    publish_github     = [bool]$PublishGitHub
    manifests          = [bool]$Manifests
}
$selected = @{}
foreach ($key in $stepSwitches.Keys) {
    $selected[$key] = if ($useStepsJson) { $requestedSteps -contains $key } else { $stepSwitches[$key] }
}

# Ensure log directory exists.
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

# Write initial status
Write-Status

foreach ($step in $pipeline) {
    if (-not $selected[$step.Key]) { continue }

    $scriptPath = Join-Path $ScriptsRoot $step.Script

    # Mark step as running
    $status.results += @{
        step      = $step.Key
        label     = $step.Label
        status    = 'running'
        exit_code = $null
        message   = ''
        output    = ''
        error     = ''
    }
    Write-Status

    $stepIndex = $status.results.Count - 1

    if (-not (Test-Path $scriptPath)) {
        $status.results[$stepIndex].status    = 'failed'
        $status.results[$stepIndex].exit_code = -1
        $status.results[$stepIndex].message   = "Script not found: $($step.Script)"
        $status.complete = $true
        $status.success  = $false
        Write-Status
        exit 1
    }

    $outFile = "$env:TEMP\xfacts-doc-$($step.Key)-out.txt"
    $errFile = "$env:TEMP\xfacts-doc-$($step.Key)-err.txt"

    try {
        # Manifest-once: suppress the GitHub step's own manifest rebuild only when
        # the dedicated manifest step also runs this invocation.
        $stepArgs = $step.Args
        if ($step.Key -eq 'publish_github' -and $selected['manifests']) {
            $stepArgs = "$stepArgs -SkipManifests"
        }

        $arguments = "-ExecutionPolicy Bypass -File `"$scriptPath`" $stepArgs"

        $proc = Start-Process -FilePath "powershell.exe" `
            -ArgumentList $arguments `
            -WorkingDirectory $ScriptsRoot `
            -WindowStyle Hidden `
            -Wait `
            -PassThru `
            -RedirectStandardOutput $outFile `
            -RedirectStandardError $errFile

        $exitCode = $proc.ExitCode

        $stdout = if (Test-Path $outFile) {
            Get-Content $outFile -Raw -ErrorAction SilentlyContinue
        } else { '' }

        $stderr = if (Test-Path $errFile) {
            Get-Content $errFile -Raw -ErrorAction SilentlyContinue
        } else { '' }

        # Cleanup temp files
        Remove-Item $outFile -Force -ErrorAction SilentlyContinue
        Remove-Item $errFile -Force -ErrorAction SilentlyContinue

        # Truncate output (keep last 8000 chars)
        $outputSummary = if ($stdout -and $stdout.Length -gt 8000) {
            "...`n" + $stdout.Substring($stdout.Length - 8000)
        } else { $stdout }

        $errorSummary = if ($stderr -and $stderr.Trim()) { $stderr.Trim() } else { '' }

        # Exit code convention: 0 = success, 2 = success with warnings, other = failure
        $stepSuccess = ($exitCode -eq 0 -or $exitCode -eq 2)
        $stepWarning = ($exitCode -eq 2)

        if ($stepWarning) { $pipelineHasWarnings = $true }

        $status.results[$stepIndex].status = if ($stepWarning) { 'warning' }
                                             elseif ($stepSuccess) { 'success' }
                                             else { 'failed' }
        $status.results[$stepIndex].exit_code = $exitCode
        $status.results[$stepIndex].message = if ($stepWarning) {
            "$($step.Label) completed with warnings"
        } elseif ($stepSuccess) {
            "$($step.Label) completed successfully"
        } else {
            "$($step.Label) failed (exit code $exitCode)"
        }
        $status.results[$stepIndex].output = $outputSummary
        $status.results[$stepIndex].error  = $errorSummary

        Write-Status

        # Stop pipeline on failure (warnings continue)
        if (-not $stepSuccess) {
            $status.complete = $true
            $status.success  = $false
            Write-Status
            exit 1
        }
    }
    catch {
        $status.results[$stepIndex].status    = 'failed'
        $status.results[$stepIndex].exit_code = -1
        $status.results[$stepIndex].message   = "Exception: $($_.Exception.Message)"
        $status.results[$stepIndex].error     = $_.Exception.Message
        $status.complete = $true
        $status.success  = $false
        Write-Status
        exit 1
    }
}

# All selected steps completed
$status.complete    = $true
$status.success     = $true
$status.finished_at = (Get-Date).ToString('o')
Write-Status

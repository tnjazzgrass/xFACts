<#
.SYNOPSIS
    xFACts - Documentation Pipeline Wrapper

.DESCRIPTION
    Orchestrates the documentation pipeline in sequence
    (Deploy > Generate DDL > Confluence > Publish GitHub > Manifests), writing
    real-time status to a JSON file that the Control Center Admin page polls for
    progress updates, and narrating each step to the console.

    The pipeline previews by default and acts only when told to. A bare run
    selects all five steps and runs each in its own safe preview (no changes);
    passing -Execute runs them for real. Naming one or more per-step switches
    (for example -Deploy) selects only those steps; naming none selects all.

    For backward compatibility with the Admin doc-pipeline API, when -StepsJson
    is supplied it selects the steps by key, the per-step switches are ignored,
    and the run executes for real (-StepsJson implies -Execute, because the API
    launches real runs). That implication is a temporary bridge to be removed in
    Task 2 once the API passes -Execute explicitly.

    Launched by the /api/admin/doc-pipeline endpoint (fire-and-forget).

.PARAMETER StepsJson
    Comma-separated step keys to run (deploy, generate_ddl, publish_confluence,
    publish_github, manifests). When supplied, it selects the steps, the per-step
    switches are ignored, and the run executes for real (-StepsJson implies
    -Execute). When empty, the per-step switches govern and the run previews
    unless -Execute is passed.

.PARAMETER StatusFile
    Path to the status JSON file the Admin page polls.

.PARAMETER Execute
    Run the pipeline for real. Without it (and without -StepsJson) every selected
    step runs its own safe preview and makes no changes.

.PARAMETER Deploy
    Select the Deploy step (deploy authored content GitHub -> live). If no
    per-step switch is named, all steps run; naming any runs only the named ones.

.PARAMETER GenerateDDL
    Select the Generate DDL Reference step. If no per-step switch is named, all
    steps run; naming any runs only the named ones.

.PARAMETER Confluence
    Select the Confluence publish/export step. If no per-step switch is named,
    all steps run; naming any runs only the named ones.

.PARAMETER PublishGitHub
    Select the GitHub publish step (generated content). If no per-step switch is
    named, all steps run; naming any runs only the named ones.

.PARAMETER Manifests
    Select the dedicated manifest rebuild step. If no per-step switch is named,
    all steps run; naming any runs only the named ones. When this step runs in
    the same invocation as PublishGitHub, the GitHub step is told to skip its own
    manifest rebuild so manifests build exactly once.

.PARAMETER PublishToConfluence
    Shapes the Confluence step in execute mode: publish to the Confluence server.

.PARAMETER ExportMarkdown
    Shapes the Confluence step in execute mode: export markdown.

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
    IMPORTS: SCRIPT DEPENDENCIES
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

# 2026-07-21  Preview-by-default, single-step selection, and mandatory console
#             output. The wrapper now previews unless -Execute is passed: a bare
#             run selects all five steps and runs each in its own safe preview
#             (no -Execute reaches the child), and -Execute runs them for real. A
#             supplied -StepsJson still selects the steps and now implies -Execute
#             for the Admin API (legacy bridge; remove in Task 2 once the API
#             passes -Execute explicitly). Per-step switches no longer default on;
#             naming any (for example -Deploy) runs only the named steps, naming
#             none runs all - so -Deploy alone now selects just deploy. Added a
#             banner, mode line, per-step headers, relayed child output, and a
#             closing summary via the sanctioned Write-Console helpers (new
#             IMPORTS dependency on xFACts-OrchestratorFunctions); the wrapper
#             never exits without output. An empty or unrecognized selection
#             prints what was passed and resolved, names any unknown keys, and
#             exits 1. Fixed the status-JSON output/error fields, which serialized
#             Get-Content's provider metadata object graph under Windows
#             PowerShell; captured text is coerced to a plain string.
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
   The step selector (StepsJson), the run-mode switch (Execute), the per-step
   toggles, the status-file path, and the publish/export options that shape the
   Confluence step. StepsJson, when supplied, overrides the per-step switches and
   implies Execute for backward compatibility with the Admin doc-pipeline API.
   Prefix: (none)
   ============================================================================ #>

[CmdletBinding()]
param(
    [string]$StepsJson,
    [string]$StatusFile = "E:\xFACts-PowerShell\Logs\doc-pipeline-status.json",
    [switch]$Execute,
    [switch]$Deploy,
    [switch]$GenerateDDL,
    [switch]$Confluence,
    [switch]$PublishGitHub,
    [switch]$Manifests,
    [switch]$PublishToConfluence,
    [switch]$ExportMarkdown,
    [switch]$IncludeSQLObjects,
    [switch]$IncludeJSON
)

<# ============================================================================
   IMPORTS: SCRIPT DEPENDENCIES
   ----------------------------------------------------------------------------
   Dot-sources the orchestrator function library for the sanctioned console
   output helpers (Write-Console, Write-ConsoleBanner, Write-ConsoleRule) used to
   narrate the run. Only the console helpers are used; the wrapper keeps no
   durable log of its own, so it does not initialize a script log session.
   Prefix: (none)
   ============================================================================ #>

. "$PSScriptRoot\xFACts-OrchestratorFunctions.ps1"

<# ============================================================================
   CONSTANTS: PIPELINE DEFINITION
   ----------------------------------------------------------------------------
   The scripts root, the log directory, and the ordered pipeline definition.
   Order matters: steps run in declaration order. Each step carries the arguments
   for both preview and execute mode; the resolver in EXECUTION picks one set per
   the run mode. The Confluence step's execute-mode arguments are shaped by the
   publish/export options; the GitHub step's -SkipManifests is added at run time
   when the manifest step is also selected, so manifests build exactly once.
   Prefix: (none)
   ============================================================================ #>

# Root directory containing the documentation pipeline scripts.
$script:ScriptsRoot = "E:\xFACts-PowerShell"

# Log directory derived from the status-file path.
$script:logDir = Split-Path $StatusFile -Parent

# Pipeline definition - order matters. PreviewArgs run each child in its own safe
# preview; ExecuteArgs run it for real.
$script:pipeline = @(
    @{
        Key         = 'deploy'
        Label       = 'Deploy Authored Content'
        Script      = 'Deploy-xFACts.ps1'
        PreviewArgs = ''
        ExecuteArgs = '-Execute'
    },
    @{
        Key         = 'generate_ddl'
        Label       = 'Generate DDL Reference'
        Script      = 'Generate-DDLReference.ps1'
        PreviewArgs = ''
        ExecuteArgs = '-Execute'
    },
    @{
        Key         = 'publish_confluence'
        Label       = 'Publish to Confluence'
        Script      = 'Publish-ConfluenceDocumentation.ps1'
        PreviewArgs = ''
        ExecuteArgs = if ($PublishToConfluence -and $ExportMarkdown) { '-Execute' }
                      elseif ($ExportMarkdown -and -not $PublishToConfluence) { '-ExportOnly' }
                      elseif ($PublishToConfluence) { '-Execute' }
                      else { '-ExportOnly' }
    },
    @{
        Key         = 'publish_github'
        Label       = 'Publish to GitHub'
        Script      = 'Publish-GitHubRepository.ps1'
        PreviewArgs = ''
        ExecuteArgs = '-Execute'
    },
    @{
        Key         = 'manifests'
        Label       = 'Rebuild Manifests'
        Script      = 'Publish-GitHubRepository.ps1'
        PreviewArgs = '-ManifestsOnly'
        ExecuteArgs = '-Execute -ManifestsOnly'
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
$script:status = @{
    started_at = (Get-Date).ToString('o')
    complete   = $false
    success    = $false
    results    = @()
}

# Track whether any step completed with warnings.
$script:pipelineHasWarnings = $false

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
   Resolves the run mode (execute when -Execute or -StepsJson is supplied,
   otherwise preview) and which steps run (StepsJson selection when supplied, a
   named subset of per-step switches when any are named, otherwise all), announces
   both on the console, then runs each selected step in order - narrating each and
   relaying its output - and halting on failure. An empty or unrecognized
   selection prints what it resolved and exits 1; the wrapper never exits without
   output. The GitHub step is given -SkipManifests when the manifest step also
   runs, so manifests build exactly once.
   Prefix: (none)
   ============================================================================ #>

# Resolve run mode. -Execute runs for real. A supplied -StepsJson also implies
# execute for the Admin API's fire-and-forget launch (legacy bridge; remove in
# Task 2 once the API passes -Execute explicitly). Absent both, the run previews.
$useStepsJson = -not [string]::IsNullOrWhiteSpace($StepsJson)
$isExecute = ([bool]$Execute) -or $useStepsJson

# Requested step keys when -StepsJson is supplied (trimmed, blanks dropped).
$requestedSteps = if ($useStepsJson) {
    ($StepsJson -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
} else { @() }

# Per-step switch parameters mapped to their pipeline step keys, in order, and
# their resolved boolean values.
$stepParamMap = [ordered]@{
    Deploy        = 'deploy'
    GenerateDDL   = 'generate_ddl'
    Confluence    = 'publish_confluence'
    PublishGitHub = 'publish_github'
    Manifests     = 'manifests'
}
$switchValues = @{
    Deploy        = [bool]$Deploy
    GenerateDDL   = [bool]$GenerateDDL
    Confluence    = [bool]$Confluence
    PublishGitHub = [bool]$PublishGitHub
    Manifests     = [bool]$Manifests
}

# The set of valid step keys, and which per-step switches the caller named.
$knownKeys = @($stepParamMap.Values)
$boundStepParams = @($stepParamMap.Keys | Where-Object { $PSBoundParameters.ContainsKey($_) })

# Resolve selection: StepsJson keys when supplied; otherwise the named per-step
# switches, or all steps when none are named.
$selected = [ordered]@{}
foreach ($paramName in $stepParamMap.Keys) {
    $key = $stepParamMap[$paramName]
    $selected[$key] =
        if ($useStepsJson) { $requestedSteps -contains $key }
        elseif ($boundStepParams.Count -eq 0) { $true }
        else { $switchValues[$paramName] }
}

# Unrecognized StepsJson keys (not real step keys), for an explicit error.
$unknownKeys = @($requestedSteps | Where-Object { $knownKeys -notcontains $_ })

# The ordered list of steps that will actually run.
$selectedList = @($knownKeys | Where-Object { $selected[$_] })

# Announce the run on the console. The wrapper always prints, in every mode.
Write-ConsoleBanner "xFACts Documentation Pipeline"
if ($isExecute) {
    Write-Console "Mode: EXECUTE - changes will be applied." 'Green'
} else {
    Write-Console "Mode: PREVIEW - no changes will be made. Pass -Execute to run for real." 'Yellow'
}
if ($useStepsJson) {
    Write-Console "Selection: -StepsJson '$StepsJson' (implies -Execute; Task 2 will remove that implication)." 'Gray'
}
Write-Console ("Steps selected: " + $(if ($selectedList.Count) { $selectedList -join ', ' } else { '(none)' })) 'Gray'
if ($unknownKeys.Count) {
    Write-Console ("Unrecognized step keys ignored: " + ($unknownKeys -join ', ')) 'DarkYellow'
}
Write-Console ''

# Ensure log directory exists.
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

# Nothing to do: state what was passed and resolved, then exit nonzero. Never
# fall through to a silent zero-step run.
if ($selectedList.Count -eq 0) {
    Write-Console "Nothing to run: the selection resolved to zero steps." 'Red'
    if ($useStepsJson) {
        Write-Console ("  -StepsJson passed: '$StepsJson'") 'Gray'
        if ($unknownKeys.Count) { Write-Console ("  Unrecognized keys: " + ($unknownKeys -join ', ')) 'Gray' }
        Write-Console ("  Valid step keys: " + ($knownKeys -join ', ')) 'Gray'
    } else {
        Write-Console ("  Per-step switches named: " + $(if ($boundStepParams.Count) { $boundStepParams -join ', ' } else { '(none)' })) 'Gray'
        Write-Console "  None of the named switches resolved to on." 'Gray'
    }
    Write-Console "Exiting without running any step." 'Red'
    $status.complete = $true
    $status.success  = $false
    $status.message  = 'No steps selected - nothing to run.'
    Write-Status
    exit 1
}

# Write initial status
Write-Status

foreach ($step in $pipeline) {
    if (-not $selected[$step.Key]) { continue }

    $scriptPath = Join-Path $ScriptsRoot $step.Script

    Write-ConsoleBanner ("Step: " + $step.Label) 'Cyan' '-'

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
        Write-Console ("Script not found: " + $step.Script + " - halting.") 'Red'
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
        # Pick the arguments for the resolved run mode.
        $stepArgs = if ($isExecute) { $step.ExecuteArgs } else { $step.PreviewArgs }

        # Manifest-once: suppress the GitHub step's own manifest rebuild only when
        # the dedicated manifest step also runs this invocation.
        if ($step.Key -eq 'publish_github' -and $selected['manifests']) {
            $stepArgs = ("$stepArgs -SkipManifests").Trim()
        }

        $arguments = ("-ExecutionPolicy Bypass -File `"$scriptPath`" $stepArgs").Trim()
        Write-Console ("Running: powershell.exe " + $arguments) 'DarkGray'

        $proc = Start-Process -FilePath "powershell.exe" `
            -ArgumentList $arguments `
            -WorkingDirectory $ScriptsRoot `
            -WindowStyle Hidden `
            -Wait `
            -PassThru `
            -RedirectStandardOutput $outFile `
            -RedirectStandardError $errFile

        $exitCode = $proc.ExitCode

        # Capture child output as plain text. Coerce to a bare string so the status
        # JSON holds only the text, not Get-Content's provider metadata
        # (PSPath/PSProvider), which Windows PowerShell would otherwise serialize.
        $stdout = ''
        if (Test-Path $outFile) {
            $rawOut = Get-Content $outFile -Raw -ErrorAction SilentlyContinue
            if ($null -ne $rawOut) { $stdout = $rawOut.ToString() }
        }

        $stderr = ''
        if (Test-Path $errFile) {
            $rawErr = Get-Content $errFile -Raw -ErrorAction SilentlyContinue
            if ($null -ne $rawErr) { $stderr = $rawErr.ToString() }
        }

        # Cleanup temp files
        Remove-Item $outFile -Force -ErrorAction SilentlyContinue
        Remove-Item $errFile -Force -ErrorAction SilentlyContinue

        # Relay the child's output to the console for the interactive operator.
        if ($stdout.Trim()) { Write-Console $stdout }

        # Truncate output (keep last 8000 chars)
        $outputSummary = if ($stdout.Length -gt 8000) {
            "...`n" + $stdout.Substring($stdout.Length - 8000)
        } else { $stdout }

        $errorSummary = if ($stderr.Trim()) { $stderr.Trim() } else { '' }

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

        if ($stepWarning) {
            Write-Console ($step.Label + " completed with warnings (exit $exitCode).") 'DarkYellow'
        } elseif ($stepSuccess) {
            Write-Console ($step.Label + " completed successfully.") 'Green'
        } else {
            Write-Console ($step.Label + " failed (exit $exitCode).") 'Red'
            if ($errorSummary) { Write-Console $errorSummary 'Red' }
        }

        # Stop pipeline on failure (warnings continue)
        if (-not $stepSuccess) {
            Write-Console "Pipeline halted on failure." 'Red'
            $status.complete = $true
            $status.success  = $false
            Write-Status
            exit 1
        }
    }
    catch {
        Write-Console ("Exception running " + $step.Label + ": " + $_.Exception.Message) 'Red'
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

# Closing summary. Always prints, so the run never ends silently.
Write-ConsoleBanner "Pipeline Complete"
if ($pipelineHasWarnings) {
    Write-Console ("All " + $selectedList.Count + " selected step(s) finished; some completed with warnings.") 'DarkYellow'
} else {
    Write-Console ("All " + $selectedList.Count + " selected step(s) completed successfully.") 'Green'
}
if (-not $isExecute) {
    Write-Console "PREVIEW - no changes were made. Re-run with -Execute to apply." 'Yellow'
}

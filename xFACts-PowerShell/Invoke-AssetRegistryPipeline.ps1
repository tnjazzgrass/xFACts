<#
.SYNOPSIS
    xFACts - Asset Registry Pipeline Orchestrator

.DESCRIPTION
    Orchestrates the Asset Registry catalog refresh: the four populators (CSS,
    HTML, JS, PS) followed by the cross-file reference resolver. The four
    populators run in parallel as independent processes; the resolver runs once
    they have all completed. Real-time per-stage status is written to a JSON
    file that the Control Center Admin page polls for progress. Launched by the
    /api/admin/asset-registry-pipeline endpoint as a fire-and-forget process.

.PARAMETER Execute
    Performs the run. Passed through to Initialize-XFActsScript to establish
    the live connection context.

.PARAMETER StepsJson
    Comma-separated list of stage keys to run (css, html, js, ps, resolve).

.PARAMETER FullRun
    Indicates a full pipeline refresh. When set, the orchestrator truncates
    dbo.Asset_Registry once before launching any stage. Selective runs omit the
    switch and rely on each populator's own per-file-type row clear.

.PARAMETER StatusFile
    Path to the status JSON file the Admin page polls.

.COMPONENT
    Tools.Utilities

.NOTES
    File Name : Invoke-AssetRegistryPipeline.ps1
    Location  : E:\xFACts-PowerShell

    FILE ORGANIZATION
    -----------------
    CHANGELOG: CHANGE HISTORY
    PARAMETERS: SCRIPT PARAMETERS
    IMPORTS: SCRIPT DEPENDENCIES
    INITIALIZATION: SCRIPT INITIALIZATION
    CONSTANTS: EXECUTION PREFERENCES
    CONSTANTS: PATHS AND STAGE DEFINITIONS
    VARIABLES: PIPELINE STATE
    FUNCTIONS: STATUS FILE
    FUNCTIONS: STAGE EXECUTION
    EXECUTION: SCRIPT EXECUTION
#>

<# ============================================================================
   CHANGELOG: CHANGE HISTORY
   ----------------------------------------------------------------------------
   Date-stamped change history. Each entry is one ISO date line followed by an
   indented description. Entries appear most-recent first.
   Prefix: (none)
   ============================================================================ #>

# 2026-05-31  Initial implementation. Parallel populator fan-out (CSS, HTML,
#             JS, PS) with a join, followed by the resolver. Per-stage status
#             written to a polled JSON file. Full runs truncate Asset_Registry
#             once before launching; selective runs do not. Pipeline halts
#             before the resolver if any populator hard-fails; a populator
#             warning (exit code 2) does not gate the resolver.

<# ============================================================================
   PARAMETERS: SCRIPT PARAMETERS
   ----------------------------------------------------------------------------
   Selected stage keys, the full-run truncate switch, and the status file path.
   Prefix: (none)
   ============================================================================ #>

[CmdletBinding()]
param(
    [switch]$Execute,
    [string]$StepsJson,
    [switch]$FullRun,
    [string]$StatusFile = 'E:\xFACts-PowerShell\Logs\asset-registry-pipeline-status.json'
)

<# ============================================================================
   IMPORTS: SCRIPT DEPENDENCIES
   ----------------------------------------------------------------------------
   Dot-source the shared orchestrator functions (logging, connection context,
   non-query execution) used by this script.
   Prefix: (none)
   ============================================================================ #>

. "$PSScriptRoot\xFACts-OrchestratorFunctions.ps1"

<# ============================================================================
   INITIALIZATION: SCRIPT INITIALIZATION
   ----------------------------------------------------------------------------
   Establish connection context and logging for the pipeline run.
   Prefix: (none)
   ============================================================================ #>

Initialize-XFActsScript -ScriptName 'Invoke-AssetRegistryPipeline' -Execute:$Execute

<# ============================================================================
   CONSTANTS: EXECUTION PREFERENCES
   ----------------------------------------------------------------------------
   PowerShell preference variables that govern script execution behavior.
   Prefix: (none)
   ============================================================================ #>

# Stop on any error so failures surface immediately rather than continuing
# against partial state.
$script:ErrorActionPreference = 'Stop'

<# ============================================================================
   CONSTANTS: PATHS AND STAGE DEFINITIONS
   ----------------------------------------------------------------------------
   The scripts root and the ordered stage table mapping each selectable stage
   key to its label, script file, and the kind of stage it is (populator or
   resolver).
   Prefix: (none)
   ============================================================================ #>

# Directory holding the populator and resolver scripts.
$script:ScriptsRoot = 'E:\xFACts-PowerShell'

# Stage table. Populators run in parallel; the resolver runs after the join.
# Order here is the display order in the status report.
$script:Stages = @(
    @{ Key = 'css';     Label = 'CSS Populator';      Script = 'Populate-AssetRegistry-CSS.ps1';   Kind = 'populator' }
    @{ Key = 'html';    Label = 'HTML Populator';     Script = 'Populate-AssetRegistry-HTML.ps1';  Kind = 'populator' }
    @{ Key = 'js';      Label = 'JS Populator';       Script = 'Populate-AssetRegistry-JS.ps1';    Kind = 'populator' }
    @{ Key = 'ps';      Label = 'PS Populator';       Script = 'Populate-AssetRegistry-PS.ps1';    Kind = 'populator' }
    @{ Key = 'resolve'; Label = 'Reference Resolver'; Script = 'Resolve-AssetRegistryReferences.ps1'; Kind = 'resolver' }
)

# Maximum characters of captured stdout retained per stage in the status file.
$script:OutputCharLimit = 8000

<# ============================================================================
   VARIABLES: PIPELINE STATE
   ----------------------------------------------------------------------------
   The mutable status object serialized to the status file as the run proceeds.
   Prefix: (none)
   ============================================================================ #>

# Pipeline status object. Serialized to the status file after every change so
# the Admin page poll always sees current per-stage state.
$script:Status = @{
    started_at = (Get-Date).ToString('o')
    complete   = $false
    success    = $false
    full_run   = [bool]$FullRun
    results    = @()
}

<# ============================================================================
   FUNCTIONS: STATUS FILE
   ----------------------------------------------------------------------------
   Serialize the pipeline status object to the polled JSON file, and seed and
   update the per-stage result entries within it.
   Prefix: (none)
   ============================================================================ #>

# Write the current status object to the status file as JSON.
function Write-StatusFile {
    param()
    $script:Status | ConvertTo-Json -Depth 6 | Out-File -FilePath $StatusFile -Encoding UTF8 -Force
}

# Seed a pending result entry for a stage and return its index in the results
# array for later in-place updates.
function Add-StageResult {
    param(
        [Parameter(Mandatory)][hashtable]$Stage
    )
    $script:Status.results += @{
        step      = $Stage.Key
        label     = $Stage.Label
        kind      = $Stage.Kind
        status    = 'running'
        exit_code = $null
        message   = ''
        output    = ''
        error     = ''
    }
    return ($script:Status.results.Count - 1)
}

# Apply a captured process outcome to a stage result entry, normalizing the
# exit code to a status (0 = success, 2 = warning, anything else = failed) and
# truncating captured stdout to the retained-character limit.
function Set-StageOutcome {
    param(
        [Parameter(Mandatory)][int]$Index,
        [Parameter(Mandatory)][int]$ExitCode,
        [string]$StdOut,
        [string]$StdErr
    )

    $isWarning = ($ExitCode -eq 2)
    $isSuccess = ($ExitCode -eq 0 -or $ExitCode -eq 2)

    $outputSummary = if ($StdOut -and $StdOut.Length -gt $script:OutputCharLimit) {
        "...`n" + $StdOut.Substring($StdOut.Length - $script:OutputCharLimit)
    } else {
        $StdOut
    }
    $errorSummary = if ($StdErr -and $StdErr.Trim()) { $StdErr.Trim() } else { '' }

    $label = $script:Status.results[$Index].label
    $script:Status.results[$Index].status    = if ($isWarning) { 'warning' } elseif ($isSuccess) { 'success' } else { 'failed' }
    $script:Status.results[$Index].exit_code = $ExitCode
    $script:Status.results[$Index].message   = if ($isWarning) {
        "$label completed with warnings"
    } elseif ($isSuccess) {
        "$label completed successfully"
    } else {
        "$label failed (exit code $ExitCode)"
    }
    $script:Status.results[$Index].output = $outputSummary
    $script:Status.results[$Index].error  = $errorSummary
}

<# ============================================================================
   FUNCTIONS: STAGE EXECUTION
   ----------------------------------------------------------------------------
   Launch a stage script as its own hidden process with redirected output, and
   collect a finished process: read its captured streams, clean up temp files,
   and record the outcome on the stage's result entry.
   Prefix: (none)
   ============================================================================ #>

# Launch a stage script as a hidden powershell.exe process with stdout/stderr
# redirected to temp files. Returns a tracking object carrying the process, the
# result index, and the temp file paths for later collection.
function Start-StageProcess {
    param(
        [Parameter(Mandatory)][hashtable]$Stage,
        [Parameter(Mandatory)][int]$Index
    )

    $scriptPath = Join-Path $script:ScriptsRoot $Stage.Script
    $outFile = Join-Path $env:TEMP ("xfacts-arp-{0}-out.txt" -f $Stage.Key)
    $errFile = Join-Path $env:TEMP ("xfacts-arp-{0}-err.txt" -f $Stage.Key)

    $arguments = "-ExecutionPolicy Bypass -File `"$scriptPath`" -Execute"
    $proc = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList $arguments `
        -WorkingDirectory $script:ScriptsRoot `
        -WindowStyle Hidden `
        -PassThru `
        -RedirectStandardOutput $outFile `
        -RedirectStandardError $errFile

    return @{
        Stage   = $Stage
        Index   = $Index
        Process = $proc
        OutFile = $outFile
        ErrFile = $errFile
    }
}

# Read a finished stage's captured streams, remove its temp files, and record
# the outcome on its result entry.
function Complete-StageProcess {
    param(
        [Parameter(Mandatory)][hashtable]$Tracker
    )

    $exitCode = $Tracker.Process.ExitCode

    $stdout = if (Test-Path $Tracker.OutFile) {
        Get-Content $Tracker.OutFile -Raw -ErrorAction SilentlyContinue
    } else { '' }
    $stderr = if (Test-Path $Tracker.ErrFile) {
        Get-Content $Tracker.ErrFile -Raw -ErrorAction SilentlyContinue
    } else { '' }

    Remove-Item $Tracker.OutFile -Force -ErrorAction SilentlyContinue
    Remove-Item $Tracker.ErrFile -Force -ErrorAction SilentlyContinue

    Set-StageOutcome -Index $Tracker.Index -ExitCode $exitCode -StdOut $stdout -StdErr $stderr
}

<# ============================================================================
   EXECUTION: SCRIPT EXECUTION
   ----------------------------------------------------------------------------
   Parse the selected stages, truncate on a full run, launch the populators in
   parallel and join, then run the resolver unless a populator hard-failed.
   Finalize and write the status file throughout for the Admin page poll.
   Prefix: (none)
   ============================================================================ #>

# -- Setup --

$selected = @($StepsJson -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

$logDir = Split-Path $StatusFile -Parent
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

Write-StatusFile

# -- Truncate (full run only) --

if ($FullRun) {
    Write-Log 'Full run: truncating dbo.Asset_Registry...'
    $truncated = $false
    try {
        Invoke-SqlNonQuery -Query 'TRUNCATE TABLE dbo.Asset_Registry;' | Out-Null
        $truncated = $true
        Write-Log 'Asset_Registry truncated.' 'SUCCESS'
    }
    catch {
        Write-Log "Truncate failed, attempting DELETE fallback: $($_.Exception.Message)" 'WARN'
        try {
            Invoke-SqlNonQuery -Query 'DELETE FROM dbo.Asset_Registry;' | Out-Null
            $truncated = $true
            Write-Log 'Asset_Registry cleared via DELETE fallback.' 'SUCCESS'
        }
        catch {
            Write-Log "Asset_Registry clear failed: $($_.Exception.Message)" 'ERROR'
        }
    }

    if (-not $truncated) {
        $script:Status.complete    = $true
        $script:Status.success     = $false
        $script:Status.finished_at = (Get-Date).ToString('o')
        $script:Status.results += @{
            step      = 'truncate'
            label     = 'Truncate Asset Registry'
            kind      = 'setup'
            status    = 'failed'
            exit_code = -1
            message   = 'Full-run truncate failed; no stages launched.'
            output    = ''
            error     = 'Both TRUNCATE and DELETE failed. See pipeline log.'
        }
        Write-StatusFile
        Write-Log 'Aborting: could not clear Asset_Registry for full run.' 'ERROR'
        exit 1
    }
}

# -- Launch Populators (parallel) --

$populatorStages = $script:Stages | Where-Object { $_.Kind -eq 'populator' -and $_.Key -in $selected }
$trackers = @()

foreach ($stage in $populatorStages) {
    $scriptPath = Join-Path $script:ScriptsRoot $stage.Script
    $idx = Add-StageResult -Stage $stage

    if (-not (Test-Path $scriptPath)) {
        Set-StageOutcome -Index $idx -ExitCode -1 -StdOut '' -StdErr "Script not found: $($stage.Script)"
        Write-StatusFile
        continue
    }

    Write-Log "Launching $($stage.Label)..."
    $trackers += Start-StageProcess -Stage $stage -Index $idx
}

Write-StatusFile

# -- Join (wait for all populators) --

if ($trackers.Count -gt 0) {
    Write-Log "Waiting for $($trackers.Count) populator(s) to complete..."
    while ($trackers | Where-Object { -not $_.Process.HasExited }) {
        Start-Sleep -Milliseconds 500
    }

    foreach ($tracker in $trackers) {
        Complete-StageProcess -Tracker $tracker
        $r = $script:Status.results[$tracker.Index]
        Write-Log ("  {0}: {1} (exit {2})" -f $r.label, $r.status, $r.exit_code)
    }
    Write-StatusFile
}

# -- Resolver (gated on no populator hard-failure) --

$populatorFailed = [bool]($script:Status.results | Where-Object { $_.kind -eq 'populator' -and $_.status -eq 'failed' })
$resolverStage = $script:Stages | Where-Object { $_.Kind -eq 'resolver' -and $_.Key -in $selected }

if ($resolverStage) {
    if ($populatorFailed) {
        $idx = Add-StageResult -Stage $resolverStage
        $script:Status.results[$idx].status  = 'skipped'
        $script:Status.results[$idx].message = 'Resolver skipped: a populator stage failed.'
        Write-Log 'A populator failed; skipping the resolver.' 'WARN'
        Write-StatusFile
    }
    else {
        $scriptPath = Join-Path $script:ScriptsRoot $resolverStage.Script
        $idx = Add-StageResult -Stage $resolverStage
        Write-StatusFile

        if (-not (Test-Path $scriptPath)) {
            Set-StageOutcome -Index $idx -ExitCode -1 -StdOut '' -StdErr "Script not found: $($resolverStage.Script)"
        }
        else {
            Write-Log "Launching $($resolverStage.Label)..."
            $tracker = Start-StageProcess -Stage $resolverStage -Index $idx
            while (-not $tracker.Process.HasExited) {
                Start-Sleep -Milliseconds 500
            }
            Complete-StageProcess -Tracker $tracker
            $r = $script:Status.results[$idx]
            Write-Log ("  {0}: {1} (exit {2})" -f $r.label, $r.status, $r.exit_code)
        }
        Write-StatusFile
    }
}

# -- Finalize --

$anyFailed = [bool]($script:Status.results | Where-Object { $_.status -eq 'failed' })
$script:Status.complete    = $true
$script:Status.success     = (-not $anyFailed)
$script:Status.finished_at = (Get-Date).ToString('o')
Write-StatusFile

if ($anyFailed) {
    Write-Log 'Pipeline completed with failures.' 'ERROR'
    exit 1
}

Write-Log 'Pipeline completed.' 'SUCCESS'
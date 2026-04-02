<#
.SYNOPSIS
    xFACts - Documentation Pipeline Wrapper

.DESCRIPTION
    Orchestrates documentation scripts in sequence (DDL > Publish > Consolidate),
    writing real-time status to a JSON file that the Control Center Admin page
    polls for progress updates.

    Launched by the /api/admin/doc-pipeline endpoint (fire-and-forget).
    Not intended for direct manual execution.

.NOTES
    File Name  : Invoke-DocPipeline.ps1
    Location   : E:\xFACts-PowerShell
    Version    : 1.0.0

================================================================================
CHANGELOG
================================================================================
1.0.0  Initial implementation
       Sequential step execution with per-step status JSON updates
       Stdout/stderr capture with truncation for API response size
       Pipeline halts on first failure
================================================================================
#>

[CmdletBinding()]
param(
    [string]$StepsJson,
    [string]$StatusFile = "E:\xFACts-PowerShell\Logs\doc-pipeline-status.json",
    [switch]$PublishToConfluence,
    [switch]$ExportMarkdown,
    [switch]$IncludeSQLObjects,
    [switch]$IncludeJSON
)

$ScriptsRoot = "E:\xFACts-PowerShell"

# Parse requested steps (passed as comma-separated string)
$steps = $StepsJson -split ','

# Pipeline definition — order matters
$pipeline = @(
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
        Key    = 'consolidate_upload'
        Label  = 'Consolidate Upload Files'
        Script = 'Consolidate-UploadFiles.ps1'
        Args   = @('-Execute') +
                 $(if ($IncludeSQLObjects) { '-IncludeSQLObjects' } else { @() }) +
                 $(if ($IncludeJSON) { '-IncludeJSON' } else { @() }) -join ' '
    }
)

# Initialize status structure
$status = @{
    started_at = (Get-Date).ToString('o')
    complete   = $false
    success    = $false
    results    = @()
}

# Ensure log directory exists
$logDir = Split-Path $StatusFile -Parent
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

function Write-Status {
    $status | ConvertTo-Json -Depth 5 | Out-File -FilePath $StatusFile -Encoding UTF8 -Force
}

# Write initial status
Write-Status

foreach ($step in $pipeline) {
    if ($step.Key -notin $steps) { continue }

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
        $arguments = "-ExecutionPolicy Bypass -File `"$scriptPath`" $($step.Args)"

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

        # Truncate output (keep last 2000 chars)
        $outputSummary = if ($stdout -and $stdout.Length -gt 2000) {
            "...`n" + $stdout.Substring($stdout.Length - 2000)
        } else { $stdout }

        $errorSummary = if ($stderr -and $stderr.Trim()) { $stderr.Trim() } else { '' }

        $stepSuccess = ($exitCode -eq 0)

        $status.results[$stepIndex].status    = if ($stepSuccess) { 'success' } else { 'failed' }
        $status.results[$stepIndex].exit_code = $exitCode
        $status.results[$stepIndex].message   = if ($stepSuccess) {
            "$($step.Label) completed successfully"
        } else {
            "$($step.Label) failed (exit code $exitCode)"
        }
        $status.results[$stepIndex].output = $outputSummary
        $status.results[$stepIndex].error  = $errorSummary

        Write-Status

        # Stop pipeline on failure
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

# All selected steps completed successfully
$status.complete    = $true
$status.success     = $true
$status.finished_at = (Get-Date).ToString('o')
Write-Status
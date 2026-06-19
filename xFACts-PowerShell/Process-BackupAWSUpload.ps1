<#
.SYNOPSIS
    xFACts - Backup AWS Upload Processing

.DESCRIPTION
    Uploads completed backup files to AWS S3. Queries Backup_FileTracking for
    PENDING AWS uploads and processes each file, uploading from the local path
    via UNC. Resets eligible FAILED files to PENDING for automatic retry and
    fires a Teams alert when retries are exhausted. Runs in parallel with the
    network copy. Without -Execute the script runs in preview mode and makes no
    changes.

.PARAMETER ServerInstance
    SQL Server instance name for the xFACts database (default: AVG-PROD-LSNR).

.PARAMETER Database
    Database name (default: xFACts).

.PARAMETER MaxFiles
    Maximum number of files to process per run (default: 100).

.PARAMETER Execute
    Perform uploads. Without this flag, runs in preview/dry-run mode.

.PARAMETER TaskId
    Orchestrator TaskLog ID for completion callback. Default 0.

.PARAMETER ProcessId
    Orchestrator ProcessRegistry ID for completion callback. Default 0.

.COMPONENT
    ServerOps.Backup

.NOTES
    File Name : Process-BackupAWSUpload.ps1
    Location  : E:\xFACts-PowerShell\Process-BackupAWSUpload.ps1

    FILE ORGANIZATION
    -----------------
    CHANGELOG: CHANGE HISTORY
    PARAMETERS: SCRIPT PARAMETERS
    IMPORTS: SCRIPT DEPENDENCIES
    INITIALIZATION: SCRIPT INITIALIZATION
    FUNCTIONS: S3 UPLOAD
    EXECUTION: SCRIPT EXECUTION
#>

<# ============================================================================
   CHANGELOG: CHANGE HISTORY
   ----------------------------------------------------------------------------
   Dated change history for this script. Most recent first.
   Prefix: (none)
   ============================================================================ #>

# 2026-06-19  Spec conformance and shared-helper adoption
#             Removed local Convert-ToUncPath, Get-PhysicalServerFromPath,
#             Write-ExecutionLog, Update-FileTrackingStatus (now in
#             xFACts-BackupFunctions.ps1 as Convert-bkp_ToUncPath,
#             Get-bkp_PhysicalServerFromPath, Write-bkp_ExecutionLog,
#             Set-bkp_AwsUploadStatus); re-pointed all call sites
#             Kept Invoke-S3Upload local as Invoke-bkp_S3Upload and moved the
#             AWS credential/config environment setup into its body (was set at
#             file scope, and the credentials path was set twice)
#             Replaced the raw Invoke-Sqlcmd listener resolve with Get-SqlData
#             using SERVERPROPERTY('ServerName') for the server-name lookup
#             Replaced the inline Step 2B retry-handling block with a call to the
#             shared Invoke-bkp_RetryFailedFiles
#             Added section banners and IMPORTS for the Backup helper
# 2026-03-16  Retry logic for failed AWS uploads
#             New Step 1B resets eligible FAILED files to PENDING for automatic retry
#             Max retries configurable via GlobalConfig (aws_upload_max_retries)
#             Exhausted retries fire Teams alert via shared Send-TeamsAlert function
# 2026-03-10  Migrated to Initialize-XFActsScript shared infrastructure
#             Removed inline Write-Log, Get-SqlData, Invoke-SqlNonQuery
#             Updated header to component-level versioning format
# 2026-02-03  Orchestrator v2 integration
#             Added -Execute, TaskId/ProcessId, orchestrator callbacks
#             Added file logging, SQLPS/SqlServer compatibility
# 2026-01-23  Master switch and registry alignment
#             Server-level master switch, Backup_DatabaseConfig filtering
# 2026-01-22  Table references updated (Backup_Status, GlobalConfig)
# 2026-01-09  ExecutionLog cleanup
# 2026-01-07  ExecutionSummary support
# 2026-01-06  AG Listener support, batch claim, column cleanup
# 2026-01-05  Initial implementation

<# ============================================================================
   PARAMETERS: SCRIPT PARAMETERS
   ----------------------------------------------------------------------------
   Script-level parameters: the xFACts connection target, the per-run file cap,
   the preview/execute guard, and the orchestrator callback identifiers.
   Prefix: (none)
   ============================================================================ #>

[CmdletBinding()]
param(
    [string]$ServerInstance = "AVG-PROD-LSNR",
    [string]$Database = "xFACts",
    [int]$MaxFiles = 100,
    [switch]$Execute,
    [long]$TaskId = 0,
    [int]$ProcessId = 0
)

<# ============================================================================
   IMPORTS: SCRIPT DEPENDENCIES
   ----------------------------------------------------------------------------
   Shared platform helpers. The orchestrator library is dot-sourced first so its
   Write-Log, Get-SqlData, Invoke-SqlNonQuery, and Send-TeamsAlert resolve; the
   Backup helper library is dot-sourced second and depends on them.
   Prefix: (none)
   ============================================================================ #>

. "$PSScriptRoot\xFACts-OrchestratorFunctions.ps1"
. "$PSScriptRoot\xFACts-BackupFunctions.ps1"

<# ============================================================================
   INITIALIZATION: SCRIPT INITIALIZATION
   ----------------------------------------------------------------------------
   Standardized script startup: SQL module loading, application identity, log
   path, default connection target, and the preview-mode execute guard.
   Prefix: (none)
   ============================================================================ #>

Initialize-XFActsScript -ScriptName 'Process-BackupAWSUpload' `
    -ServerInstance $ServerInstance -Database $Database -Execute:$Execute

<# ============================================================================
   FUNCTIONS: S3 UPLOAD
   ----------------------------------------------------------------------------
   The AWS CLI upload primitive local to this script. Sets the service-account
   AWS credential and config paths, then shells out to aws.exe to copy a single
   file to S3 Glacier and returns the outcome.
   Prefix: bkp
   ============================================================================ #>

# Uploads a file to S3 Glacier via the AWS CLI and returns a result hashtable (Success, ExitCode, Output, Error).
function Invoke-bkp_S3Upload {
    param(
        [string]$SourcePath,
        [string]$S3Destination
    )

    # Point the AWS CLI at the service account's credential and config files
    $env:AWS_SHARED_CREDENTIALS_FILE = "C:\Users\sqlmon\.aws\credentials"
    $env:AWS_CONFIG_FILE = "C:\Users\sqlmon\.aws\config"

    $processInfo = New-Object System.Diagnostics.ProcessStartInfo
    $processInfo.FileName = "C:\Program Files\Amazon\AWSCLIV2\aws.exe"
    $processInfo.Arguments = "s3 cp `"$SourcePath`" `"$S3Destination`" --storage-class GLACIER"
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError = $true
    $processInfo.UseShellExecute = $false
    $processInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $processInfo
    $process.Start() | Out-Null

    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    return @{
        Success = ($process.ExitCode -eq 0)
        ExitCode = $process.ExitCode
        Output = $stdout
        Error = $stderr
    }
}

<# ============================================================================
   EXECUTION: SCRIPT EXECUTION
   ----------------------------------------------------------------------------
   Checks the server-level master switch, loads configuration, verifies the AWS
   CLI, retries eligible failed uploads and alerts on exhausted ones, claims a
   batch of pending files, uploads each to S3, writes per-file execution-log
   detail, and reports the orchestrator callback.
   Prefix: (none)
   ============================================================================ #>

# Capture start time for duration reporting.
$scriptStart = Get-Date
# Process name used for execution-log component tagging.
$processName = "AWS_UPLOAD"

Write-Log "========================================"
Write-Log "xFACts Backup AWS Upload"
Write-Log "========================================"

if (-not $Execute) {
    Write-Log "*** PREVIEW MODE - No changes will be made. Use -Execute to run. ***" "WARN"
}

# -- Step 0: Master switch check --

Write-Log "Checking server-level Backup enable flag..."

$serverCheck = Get-SqlData -Query @"
SELECT COUNT(*) AS enabled_count
FROM dbo.ServerRegistry
WHERE is_active = 1
  AND serverops_backup_enabled = 1
"@

if (-not $serverCheck -or $serverCheck.enabled_count -eq 0) {
    Write-Log "Backup processing is not enabled on any server (serverops_backup_enabled = 0). Exiting." "WARN"
    if ($TaskId -gt 0) {
        Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
            -TaskId $TaskId -ProcessId $ProcessId `
            -Status "SUCCESS" -DurationMs 0 -Output "Backup processing not enabled on any server"
    }
    exit 0
}

Write-Log "  Found $($serverCheck.enabled_count) server(s) with Backup enabled."

# -- Step 1: Configuration --

Write-Log "Loading configuration..."

$configResult = Get-SqlData -Query @"
SELECT setting_name, setting_value
FROM dbo.GlobalConfig
WHERE module_name = 'ServerOps' AND category = 'Backup'
  AND setting_name IN ('aws_bucket_name', 'aws_path_prefix', 'aws_upload_max_retries')
  AND is_active = 1
"@

if ($null -eq $configResult -or @($configResult).Count -lt 2) {
    Write-Log "Failed to load AWS configuration. Exiting." "ERROR"
    if ($TaskId -gt 0) {
        Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
            -TaskId $TaskId -ProcessId $ProcessId `
            -Status "FAILED" -DurationMs 0 -Output "Failed to load AWS configuration"
    }
    exit 1
}

$awsBucket = ($configResult | Where-Object { $_.setting_name -eq 'aws_bucket_name' }).setting_value
$awsPrefix = ($configResult | Where-Object { $_.setting_name -eq 'aws_path_prefix' }).setting_value
# Default: 2 retries (3 total attempts)
$maxRetries = 2
$maxRetriesRow = $configResult | Where-Object { $_.setting_name -eq 'aws_upload_max_retries' }
if ($maxRetriesRow) { $maxRetries = [int]$maxRetriesRow.setting_value }

Write-Log "AWS Bucket: $awsBucket"
Write-Log "AWS Prefix: $awsPrefix"
Write-Log "Max retries: $maxRetries (total attempts: $($maxRetries + 1))"

# -- Step 2: Verify AWS CLI --

Write-Log "Verifying AWS CLI..."

try {
    $awsVersion = & "C:\Program Files\Amazon\AWSCLIV2\aws.exe" --version 2>&1
    Write-Log "AWS CLI: $awsVersion"
}
catch {
    Write-Log "AWS CLI not found or not accessible. Exiting." "ERROR"
    if ($TaskId -gt 0) {
        Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
            -TaskId $TaskId -ProcessId $ProcessId `
            -Status "FAILED" -DurationMs 0 -Output "AWS CLI not found or not accessible"
    }
    exit 1
}

# -- Step 2B: Retry failed files --

Invoke-bkp_RetryFailedFiles -Operation 'AWS_UPLOAD' -MaxRetries $maxRetries -Execute:$Execute

# -- Step 3: Pending files --

Write-Log "Querying pending AWS uploads..."

$pendingFiles = Get-SqlData -Query @"
SELECT TOP ($MaxFiles)
    ft.tracking_id,
    ft.server_id,
    ft.server_name,
    ft.database_name,
    ft.backup_type,
    ft.file_name,
    ft.file_size_bytes,
    ft.local_path
FROM ServerOps.Backup_FileTracking ft
JOIN dbo.DatabaseRegistry dr ON ft.server_id = dr.server_id AND ft.database_name = dr.database_name
JOIN dbo.ServerRegistry sr ON dr.server_id = sr.server_id
JOIN ServerOps.Backup_DatabaseConfig dc ON dr.database_id = dc.database_id
WHERE ft.aws_upload_status = 'PENDING'
  AND sr.is_active = 1
  AND sr.serverops_backup_enabled = 1
  AND dr.is_active = 1
  AND dc.backup_aws_upload_enabled = 1
ORDER BY ft.backup_finish_dttm
"@

if ($null -eq $pendingFiles -or @($pendingFiles).Count -eq 0) {
    Write-Log "No pending AWS uploads found."
    if ($TaskId -gt 0) {
        Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
            -TaskId $TaskId -ProcessId $ProcessId `
            -Status "SUCCESS" -DurationMs 0 -Output "No pending AWS uploads"
    }
    exit 0
}

$fileCount = @($pendingFiles).Count
Write-Log "Found $fileCount file(s) to process."

# -- Step 4B: Claim batch --

# This prevents race conditions if another execution starts while we're processing
$trackingIds = @($pendingFiles | ForEach-Object { $_.tracking_id })
$trackingIdList = $trackingIds -join ','

Write-Log "Claiming batch of $fileCount files (tracking_ids: $trackingIdList)..."

if ($Execute) {
    $claimQuery = @"
UPDATE ServerOps.Backup_FileTracking
SET aws_upload_status = 'IN_PROGRESS'
WHERE tracking_id IN ($trackingIdList)
  AND aws_upload_status = 'PENDING'
"@

    $claimedCount = Invoke-SqlNonQuery -Query $claimQuery
    Write-Log "Claimed $claimedCount file(s) for processing."

    if ($claimedCount -eq 0) {
        Write-Log "No files claimed - another process may have already claimed them." "WARN"
        if ($TaskId -gt 0) {
            Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
                -TaskId $TaskId -ProcessId $ProcessId `
                -Status "SUCCESS" -DurationMs 0 -Output "No files claimed - already claimed by another process"
        }
        exit 0
    }

    if ($claimedCount -lt $fileCount) {
        Write-Log "Only claimed $claimedCount of $fileCount files - some may have been claimed by another process." "WARN"
    }
} else {
    Write-Log "[Preview] Would claim $fileCount files as IN_PROGRESS"
}

# -- Step 4: Process each file --

# Count of files uploaded successfully.
$successCount = 0
# Count of files that failed upload.
$failCount = 0
# Running total of bytes uploaded across all files.
$totalBytesUploaded = 0

foreach ($file in $pendingFiles) {
    $trackingId = $file.tracking_id
    $serverId = $file.server_id
    $serverName = $file.server_name
    $dbName = $file.database_name
    $backupType = $file.backup_type
    $fileName = $file.file_name
    $fileSize = if ($file.file_size_bytes -isnot [DBNull]) { $file.file_size_bytes } else { $null }
    $localPath = $file.local_path

    Write-Log "----------------------------------------"
    Write-Log "Processing: $serverName / $dbName / $fileName"

    $fileStart = Get-Date

    # Determine physical server for source UNC path
    # For AG databases (server_id = 0), parse from filename since admin shares don't work with listener
    if ($serverId -eq 0) {
        $physicalServer = Get-bkp_PhysicalServerFromPath -LocalPath $localPath

        if ($null -eq $physicalServer) {
            # Fallback: Query listener to resolve current primary
            Write-Log "  Could not parse server from filename, resolving via listener..." "WARN"
            $physicalServer = (Get-SqlData -Query "SELECT SERVERPROPERTY('ServerName') AS name" -Instance "AVG-PROD-LSNR").name
        }

        Write-Log "  AG database - physical server: $physicalServer"
        $sourcePath = Convert-bkp_ToUncPath -LocalPath $localPath -ServerName $physicalServer
    } else {
        # Non-AG database - server_name is already the physical server
        $sourcePath = Convert-bkp_ToUncPath -LocalPath $localPath -ServerName $serverName
    }

    # Build S3 destination path: s3://{bucket}/{prefix}/{server}/{database}/{type}/{filename}
    $s3Path = "s3://$awsBucket/$awsPrefix/$serverName/$dbName/$backupType/$fileName"

    Write-Log "  Source: $sourcePath"
    Write-Log "  Destination: $s3Path"

    if ($fileSize) {
        $sizeMB = [math]::Round($fileSize / 1MB, 2)
        $sizeGB = [math]::Round($fileSize / 1GB, 2)
        Write-Log "  Size: $sizeMB MB ($sizeGB GB)"
    }

    if (-not $Execute) {
        Write-Log "  [Preview] Would upload file to S3" "INFO"
        $successCount++
        continue
    }

    # File already marked IN_PROGRESS during batch claim (Step 4B)
    # Now set the actual start timestamp for accurate per-file timing
    $startTimestampQuery = @"
UPDATE ServerOps.Backup_FileTracking
SET aws_upload_started_dttm = GETDATE()
WHERE tracking_id = $trackingId
"@
    Invoke-SqlNonQuery -Query $startTimestampQuery | Out-Null

    # Verify source file exists
    if (-not (Test-Path $sourcePath)) {
        Write-Log "  Source file not found: $sourcePath" "ERROR"

        # Mark as FAILED - file doesn't exist
        Set-bkp_AwsUploadStatus -TrackingId $trackingId -Status 'FAILED' -FinishDttm (Get-Date) | Out-Null

        Write-bkp_ExecutionLog -Component 'AWS_UPLOAD' -ServerName $serverName `
            -DatabaseName $dbName -FileName $fileName -TrackingId $trackingId `
            -Operation "Upload to S3" -Status 'FAILED' `
            -ErrorMessage "Source file not found: $sourcePath" `
            -StartedDttm $fileStart -CompletedDttm (Get-Date)

        $failCount++
        continue
    }

    try {
        # Upload to S3
        Write-Log "  Uploading to S3..."
        $uploadResult = Invoke-bkp_S3Upload -SourcePath $sourcePath -S3Destination $s3Path

        $fileFinish = Get-Date
        $durationMs = [int]($fileFinish - $fileStart).TotalMilliseconds
        $durationSec = [math]::Round($durationMs / 1000, 1)
        $durationMin = [math]::Round($durationMs / 60000, 2)

        if ($uploadResult.Success) {
            # Update status to COMPLETED
            Set-bkp_AwsUploadStatus -TrackingId $trackingId -Status 'COMPLETED' `
                -AwsPath $s3Path -FinishDttm $fileFinish | Out-Null

            # Calculate throughput
            if ($fileSize -and $durationSec -gt 0) {
                $mbPerSec = [math]::Round(($fileSize / 1MB) / $durationSec, 2)
                Write-Log "  SUCCESS: Uploaded in $durationMin min ($mbPerSec MB/s)"
                $totalBytesUploaded += $fileSize
            }
            else {
                Write-Log "  SUCCESS: Uploaded in $durationMin min"
            }

            Write-bkp_ExecutionLog -Component 'AWS_UPLOAD' -ServerName $serverName `
                -DatabaseName $dbName -FileName $fileName -TrackingId $trackingId `
                -Operation "Upload to S3" -Status 'SUCCESS' `
                -DurationMs $durationMs -BytesProcessed $fileSize `
                -StartedDttm $fileStart -CompletedDttm $fileFinish

            $successCount++
        }
        else {
            throw "AWS CLI returned exit code $($uploadResult.ExitCode): $($uploadResult.Error)"
        }
    }
    catch {
        $fileFinish = Get-Date
        $durationMs = [int]($fileFinish - $fileStart).TotalMilliseconds
        $errorMsg = $_.Exception.Message

        Write-Log "  FAILED: $errorMsg" "ERROR"

        # Update status to FAILED
        Set-bkp_AwsUploadStatus -TrackingId $trackingId -Status 'FAILED' -FinishDttm $fileFinish | Out-Null

        Write-bkp_ExecutionLog -Component 'AWS_UPLOAD' -ServerName $serverName `
            -DatabaseName $dbName -FileName $fileName -TrackingId $trackingId `
            -Operation "Upload to S3" -Status 'FAILED' `
            -DurationMs $durationMs -ErrorMessage $errorMsg `
            -StartedDttm $fileStart -CompletedDttm $fileFinish

        $failCount++
    }
}

# -- Step 5: Summary --

$scriptDuration = [int]((Get-Date) - $scriptStart).TotalMilliseconds
$scriptDurationMin = [math]::Round($scriptDuration / 60000, 2)
$finalStatus = if ($failCount -eq 0) { 'SUCCESS' } else { 'PARTIAL' }
$errorSummary = if ($failCount -gt 0) { "$failCount file(s) failed" } else { $null }

Write-Log "========================================"
Write-Log "  AWS Upload Complete$(if (-not $Execute) { ' [PREVIEW - No changes made]' })"
Write-Log "  Files processed: $fileCount"
Write-Log "  Successful: $successCount"
Write-Log "  Failed: $failCount"
Write-Log "  Total uploaded: $([math]::Round($totalBytesUploaded / 1GB, 2)) GB"
Write-Log "  Total duration: $scriptDurationMin min"
Write-Log "========================================"

# Orchestrator callback
if ($TaskId -gt 0) {
    $totalMs = [int]((Get-Date) - $scriptStart).TotalMilliseconds
    $callbackStatus = if ($failCount -eq 0) { 'SUCCESS' } else { 'FAILED' }
    $callbackOutput = "Uploaded $successCount of $fileCount files ($([math]::Round($totalBytesUploaded / 1GB, 2)) GB). Duration: $([math]::Round($totalMs / 60000, 2)) min"
    if ($failCount -gt 0) {
        $callbackOutput += " | $failCount file(s) failed"
    }
    Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
        -TaskId $TaskId -ProcessId $ProcessId `
        -Status $callbackStatus -DurationMs $totalMs -Output $callbackOutput
}

if ($failCount -gt 0) { exit 1 } else { exit 0 }
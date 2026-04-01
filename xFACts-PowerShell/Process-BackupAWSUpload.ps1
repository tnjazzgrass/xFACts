<#
.SYNOPSIS
    xFACts - Backup AWS Upload Processing

.DESCRIPTION
    xFACts - ServerOps.Backup
    Script: Process-BackupAWSUpload.ps1
    Version: Tracked in dbo.System_Metadata (component: ServerOps.Backup)

    Uploads completed backup files to AWS S3.
    Queries Backup_FileTracking for PENDING AWS uploads and processes each file.
    Runs in parallel with network copy - uploads from local path via UNC.

    CHANGELOG
    ---------
    2026-03-16  Retry logic for failed AWS uploads
                New Step 1B resets eligible FAILED files to PENDING for automatic retry
                Max retries configurable via GlobalConfig (aws_upload_max_retries)
                Exhausted retries fire Teams alert via shared Send-TeamsAlert function
    2026-03-10  Migrated to Initialize-XFActsScript shared infrastructure
                Removed inline Write-Log, Get-SqlData, Invoke-SqlNonQuery
                Updated header to component-level versioning format
    2026-02-03  Orchestrator v2 integration
                Added -Execute, TaskId/ProcessId, orchestrator callbacks
                Added file logging, SQLPS/SqlServer compatibility
    2026-01-23  Master switch and registry alignment
                Server-level master switch, Backup_DatabaseConfig filtering
    2026-01-22  Table references updated (Backup_Status, GlobalConfig)
    2026-01-09  ExecutionLog cleanup
    2026-01-07  ExecutionSummary support
    2026-01-06  AG Listener support, batch claim, column cleanup
    2026-01-05  Initial implementation

.PARAMETER ServerInstance
    SQL Server instance name for xFACts database (default: AVG-PROD-LSNR)

.PARAMETER Database
    Database name (default: xFACts)

.PARAMETER MaxFiles
    Maximum number of files to process per run (default: 100)

.PARAMETER Execute
    Perform uploads. Without this flag, runs in preview/dry-run mode.

.PARAMETER TaskId
    Orchestrator TaskLog ID for completion callback. Default 0.

.PARAMETER ProcessId
    Orchestrator ProcessRegistry ID for completion callback. Default 0.

================================================================================
DEPLOYMENT REMINDERS
================================================================================
1. Deploy to E:\xFACts-PowerShell on FA-SQLDBB.
2. xFACts-OrchestratorFunctions.ps1 must be in the same directory.
3. AWS CLI must be installed. AWS credentials in C:\Users\sqlmon\.aws\.
================================================================================
#>

[CmdletBinding()]
param(
    [string]$ServerInstance = "AVG-PROD-LSNR",
    [string]$Database = "xFACts",
    [int]$MaxFiles = 100,
    [switch]$Execute,
    [long]$TaskId = 0,
    [int]$ProcessId = 0
)

# ============================================================================
# STANDARD INITIALIZATION
# ============================================================================

. "$PSScriptRoot\xFACts-OrchestratorFunctions.ps1"

Initialize-XFActsScript -ScriptName 'Process-BackupAWSUpload' `
    -ServerInstance $ServerInstance -Database $Database -Execute:$Execute

$env:AWS_SHARED_CREDENTIALS_FILE = "C:\Users\sqlmon\.aws\credentials"

# ========================================
# FUNCTIONS
# ========================================

function Update-FileTrackingStatus {
    param(
        [long]$TrackingId,
        [string]$Status,
        [string]$AwsPath = $null,
        [datetime]$StartDttm = [datetime]::MinValue,
        [datetime]$FinishDttm = [datetime]::MinValue
    )
    
    $setClauses = @(
        "aws_upload_status = '$Status'"
    )
    
    if ($AwsPath) {
        $awsPathSafe = $AwsPath -replace "'", "''"
        $setClauses += "aws_path = '$awsPathSafe'"
    }
    
    if ($StartDttm -ne [datetime]::MinValue) {
        $setClauses += "aws_upload_started_dttm = '$($StartDttm.ToString("yyyy-MM-dd HH:mm:ss"))'"
    }
    
    if ($FinishDttm -ne [datetime]::MinValue) {
        $setClauses += "aws_upload_completed_dttm = '$($FinishDttm.ToString("yyyy-MM-dd HH:mm:ss"))'"
    }
    
    $query = "UPDATE ServerOps.Backup_FileTracking SET $($setClauses -join ', ') WHERE tracking_id = $TrackingId"
    
    return Invoke-SqlNonQuery -Query $query
}

function Convert-ToUncPath {
    <#
    .SYNOPSIS
        Converts a local path to a UNC admin share path
    .EXAMPLE
        Convert-ToUncPath -LocalPath "X:\BACKUP\file.sqb" -ServerName "DM-PROD-DB"
        Returns: \\DM-PROD-DB\X$\BACKUP\file.sqb
    #>
    param(
        [string]$LocalPath,
        [string]$ServerName
    )
    
    # Check if already a UNC path
    if ($LocalPath -match '^\\\\') {
        return $LocalPath
    }
    
    # Convert drive letter to admin share
    # X:\BACKUP\file.sqb -> \\ServerName\X$\BACKUP\file.sqb
    if ($LocalPath -match '^([A-Za-z]):\\(.*)$') {
        $driveLetter = $Matches[1]
        $remainder = $Matches[2]
        return "\\$ServerName\$driveLetter`$\$remainder"
    }
    
    # Couldn't parse - return as-is
    return $LocalPath
}

function Get-PhysicalServerFromPath {
    <#
    .SYNOPSIS
        Extracts physical server name from a backup filename
        
    .DESCRIPTION
        When Redgate is configured with <SERVER> tag in filename, the physical server
        name is embedded in the filename:
        FULL_DM-PROD-DB_crs5_oltp_20260106_060000.sqb
             ^^^^^^^^^^
        
        Filename pattern: <TYPE>_<SERVER>_<DATABASE>_<TIMESTAMP>.sqb
        
        This function extracts the server name for building source UNC paths
        when the enrollment is under the AG Listener (server_id 0).
        
    .PARAMETER LocalPath
        Full local path to the backup file
        
    .EXAMPLE
        Get-PhysicalServerFromPath -LocalPath "X:\BACKUP\crs5_oltp\FULL\FULL_DM-PROD-DB_crs5_oltp_20260106_060000.sqb"
        Returns: "DM-PROD-DB"
    #>
    param(
        [string]$LocalPath
    )
    
    # Extract just the filename
    $fileName = Split-Path $LocalPath -Leaf
    
    # Expected filename pattern: <TYPE>_<SERVER>_<DATABASE>_<TIMESTAMP>.sqb
    # Examples:
    #   FULL_DM-PROD-DB_crs5_oltp_20260106_060000.sqb
    #   LOG_DM-PROD-REP_DBA_20260106_143000.sqb
    
    # Split by underscore
    $parts = $fileName -split '_'
    
    # parts[0] = TYPE (FULL, DIFF, LOG)
    # parts[1] = SERVER (what we want)
    # parts[2+] = DATABASE and timestamp parts
    
    if ($parts.Count -ge 3) {
        $potentialServer = $parts[1]
        
        # Validate it looks like a server name (contains hyphen, typical naming convention)
        if ($potentialServer -match '^[A-Za-z0-9\-]+$' -and $potentialServer -match '-') {
            return $potentialServer
        }
    }
    
    # Fallback: return $null to indicate we couldn't parse it
    return $null
}

function Write-ExecutionLog {
    param(
        [string]$Component = 'AWS_UPLOAD',
        [string]$ServerName = $null,
        [string]$DatabaseName = $null,
        [string]$FileName = $null,
        [long]$TrackingId = 0,
        [string]$Operation,
        [string]$Status,
        [int]$DurationMs = $null,
        [long]$BytesProcessed = $null,
        [string]$ErrorMessage = $null,
        [string]$ErrorDetails = $null,
        [datetime]$StartedDttm = (Get-Date),
        [datetime]$CompletedDttm = [datetime]::MinValue
    )
    
    $serverVal = if ($ServerName) { "'$($ServerName -replace "'", "''")'" } else { "NULL" }
    $dbVal = if ($DatabaseName) { "'$($DatabaseName -replace "'", "''")'" } else { "NULL" }
    $fileVal = if ($FileName) { "'$($FileName -replace "'", "''")'" } else { "NULL" }
    $trackingVal = if ($TrackingId -gt 0) { $TrackingId } else { "NULL" }
    $durationVal = if ($null -ne $DurationMs) { $DurationMs } else { "NULL" }
    $bytesVal = if ($null -ne $BytesProcessed) { $BytesProcessed } else { "NULL" }
    $errorVal = if ($ErrorMessage) { "'$($ErrorMessage.Substring(0, [Math]::Min($ErrorMessage.Length, 500)) -replace "'", "''")'" } else { "NULL" }
    $errorDetailsVal = if ($ErrorDetails) { "'$($ErrorDetails -replace "'", "''")'" } else { "NULL" }
    $completedVal = if ($CompletedDttm -ne [datetime]::MinValue) { "'$($CompletedDttm.ToString("yyyy-MM-dd HH:mm:ss"))'" } else { "NULL" }
    
    $query = @"
INSERT INTO ServerOps.Backup_ExecutionLog 
    (component, server_name, database_name, file_name, tracking_id, 
     operation, status, duration_ms, bytes_processed, 
     error_message, error_details, started_dttm, completed_dttm)
VALUES 
    ('$Component', $serverVal, $dbVal, $fileVal, $trackingVal,
     '$Operation', '$Status', $durationVal, $bytesVal,
     $errorVal, $errorDetailsVal, '$($StartedDttm.ToString("yyyy-MM-dd HH:mm:ss"))', $completedVal)
"@
    
    Invoke-SqlNonQuery -Query $query | Out-Null
}

function Invoke-S3Upload {
    <#
    .SYNOPSIS
        Uploads a file to S3 using AWS CLI
    .RETURNS
        Hashtable with Success (bool), ExitCode (int), Output (string), Error (string)
    #>
    param(
        [string]$SourcePath,
        [string]$S3Destination
    )
    
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



# ========================================
# MAIN SCRIPT
# ========================================

$scriptStart = Get-Date
$processName = "AWS_UPLOAD"

# Explicitly set AWS credential paths for service account execution
$env:AWS_SHARED_CREDENTIALS_FILE = "C:\Users\sqlmon\.aws\credentials"
$env:AWS_CONFIG_FILE = "C:\Users\sqlmon\.aws\config"

Write-Log "========================================"
Write-Log "xFACts Backup AWS Upload"
Write-Log "========================================"

if (-not $Execute) {
    Write-Log "*** PREVIEW MODE - No changes will be made. Use -Execute to run. ***" "WARN"
}

# ----------------------------------------
# Step 0: Check master switch
# ----------------------------------------
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

# ----------------------------------------
# Step 1: Get config settings
# ----------------------------------------
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
$maxRetries = 2  # Default: 2 retries (3 total attempts)
$maxRetriesRow = $configResult | Where-Object { $_.setting_name -eq 'aws_upload_max_retries' }
if ($maxRetriesRow) { $maxRetries = [int]$maxRetriesRow.setting_value }

Write-Log "AWS Bucket: $awsBucket"
Write-Log "AWS Prefix: $awsPrefix"
Write-Log "Max retries: $maxRetries (total attempts: $($maxRetries + 1))"

# ----------------------------------------
# Step 2: Verify AWS CLI is available
# ----------------------------------------
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

# ----------------------------------------
# Step 2B: Retry failed files
# ----------------------------------------
# Reset eligible FAILED files back to PENDING so the existing processing loop picks them up.
# Files that have exhausted retries are left FAILED and a Teams alert is fired.
Write-Log "Checking for failed files eligible for retry..."

$failedRetryable = Get-SqlData -Query @"
SELECT ft.tracking_id, ft.server_name, ft.database_name, ft.file_name,
       ft.aws_upload_retry_count,
       COALESCE(ft.compressed_size_bytes, ft.file_size_bytes) AS file_size_bytes
FROM ServerOps.Backup_FileTracking ft
JOIN dbo.ServerRegistry sr ON ft.server_id = sr.server_id
WHERE ft.aws_upload_status = 'FAILED'
  AND ft.aws_upload_retry_count < $maxRetries
  AND sr.is_active = 1
  AND sr.serverops_backup_enabled = 1
"@

$failedExhausted = Get-SqlData -Query @"
SELECT ft.tracking_id, ft.server_name, ft.database_name, ft.file_name,
       ft.aws_upload_retry_count,
       COALESCE(ft.compressed_size_bytes, ft.file_size_bytes) AS file_size_bytes
FROM ServerOps.Backup_FileTracking ft
JOIN dbo.ServerRegistry sr ON ft.server_id = sr.server_id
WHERE ft.aws_upload_status = 'FAILED'
  AND ft.aws_upload_retry_count >= $maxRetries
  AND sr.is_active = 1
  AND sr.serverops_backup_enabled = 1
"@

# Reset retryable files to PENDING
if ($null -ne $failedRetryable -and @($failedRetryable).Count -gt 0) {
    $retryCount = @($failedRetryable).Count
    Write-Log "  Found $retryCount file(s) eligible for retry"
    
    foreach ($retryFile in $failedRetryable) {
        $retryId = $retryFile.tracking_id
        $retryAttempt = $retryFile.aws_upload_retry_count + 1
        Write-Log "  Retry $retryAttempt/${maxRetries}: $($retryFile.server_name)/$($retryFile.database_name)/$($retryFile.file_name)"
        
        if ($Execute) {
            Invoke-SqlNonQuery -Query @"
UPDATE ServerOps.Backup_FileTracking
SET aws_upload_status = 'PENDING',
    aws_upload_started_dttm = NULL,
    aws_upload_completed_dttm = NULL,
    aws_upload_retry_count = aws_upload_retry_count + 1
WHERE tracking_id = $retryId
  AND aws_upload_status = 'FAILED'
"@ | Out-Null
        }
        else {
            Write-Log "  [Preview] Would reset tracking_id $retryId to PENDING (retry $retryAttempt)" "INFO"
        }
    }
}
else {
    Write-Log "  No files eligible for retry"
}

# Alert for exhausted files
if ($null -ne $failedExhausted -and @($failedExhausted).Count -gt 0) {
    $exhaustedCount = @($failedExhausted).Count
    Write-Log "  Found $exhaustedCount file(s) with retries exhausted - alerting" "WARN"
    
    foreach ($exhaustedFile in $failedExhausted) {
        $sizeGB = [math]::Round($exhaustedFile.file_size_bytes / 1GB, 2)
        
        Send-TeamsAlert -SourceModule 'ServerOps' -AlertCategory 'CRITICAL' `
            -Title "{{FIRE}} Backup AWS Upload Failed - Retries Exhausted" `
            -Message @"
**Server:** $($exhaustedFile.server_name)
**Database:** $($exhaustedFile.database_name)
**File:** $($exhaustedFile.file_name)
**Size:** $sizeGB GB
**Attempts:** $($exhaustedFile.aws_upload_retry_count + 1) (original + $($exhaustedFile.aws_upload_retry_count) retries)

This file has failed all retry attempts and requires manual investigation.
"@ `
            -TriggerType 'BACKUP_AWS_UPLOAD_EXHAUSTED' `
            -TriggerValue "$($exhaustedFile.tracking_id)"
    }
}

# ----------------------------------------
# Step 3: Get pending files
# ----------------------------------------
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

# ----------------------------------------
# Step 4B: Claim batch - mark all selected files as IN_PROGRESS
# ----------------------------------------
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


# ----------------------------------------
# Step 4: Process each file
# ----------------------------------------
$successCount = 0
$failCount = 0
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
        $physicalServer = Get-PhysicalServerFromPath -LocalPath $localPath
        
        if ($null -eq $physicalServer) {
            # Fallback: Query listener to resolve current primary
            Write-Log "  Could not parse server from filename, resolving via listener..." "WARN"
            $physicalServer = (Invoke-Sqlcmd -ServerInstance "AVG-PROD-LSNR" -Query "SELECT @@SERVERNAME AS name" -ApplicationName $script:XFActsAppName -TrustServerCertificate).name
        }
        
        Write-Log "  AG database - physical server: $physicalServer"
        $sourcePath = Convert-ToUncPath -LocalPath $localPath -ServerName $physicalServer
    } else {
        # Non-AG database - server_name is already the physical server
        $sourcePath = Convert-ToUncPath -LocalPath $localPath -ServerName $serverName
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
        Update-FileTrackingStatus -TrackingId $trackingId -Status 'FAILED' -FinishDttm (Get-Date) | Out-Null
        
        Write-ExecutionLog -Component 'AWS_UPLOAD' -ServerName $serverName `
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
        $uploadResult = Invoke-S3Upload -SourcePath $sourcePath -S3Destination $s3Path
        
        $fileFinish = Get-Date
        $durationMs = [int]($fileFinish - $fileStart).TotalMilliseconds
        $durationSec = [math]::Round($durationMs / 1000, 1)
        $durationMin = [math]::Round($durationMs / 60000, 2)
        
        if ($uploadResult.Success) {
            # Update status to COMPLETED
            Update-FileTrackingStatus -TrackingId $trackingId -Status 'COMPLETED' `
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
            
            Write-ExecutionLog -Component 'AWS_UPLOAD' -ServerName $serverName `
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
        Update-FileTrackingStatus -TrackingId $trackingId -Status 'FAILED' -FinishDttm $fileFinish | Out-Null
        
        Write-ExecutionLog -Component 'AWS_UPLOAD' -ServerName $serverName `
            -DatabaseName $dbName -FileName $fileName -TrackingId $trackingId `
            -Operation "Upload to S3" -Status 'FAILED' `
            -DurationMs $durationMs -ErrorMessage $errorMsg `
            -StartedDttm $fileStart -CompletedDttm $fileFinish
        
        $failCount++
    }
}

# ----------------------------------------
# Step 5: Summary
# ----------------------------------------
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
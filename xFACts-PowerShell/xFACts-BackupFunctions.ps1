<#
.SYNOPSIS
    xFACts - ServerOps.Backup shared backup-pipeline helpers.

.DESCRIPTION
    xFACts - ServerOps.Backup

    Shared function library for the ServerOps.Backup pipeline scripts
    (Collect-BackupStatus.ps1, Process-BackupNetworkCopy.ps1,
    Process-BackupAWSUpload.ps1, and Process-BackupRetention.ps1). Centralizes
    the backup-filename physical-server parsing, the local-to-UNC admin-share
    path conversion, the Backup_ExecutionLog detail writer, and the
    Backup_FileTracking status writes for the AWS-upload and network-copy
    pipelines that the collectors and processors share.

    Consumer contract. These helpers depend on Write-Log, Get-SqlData, and
    Invoke-SqlNonQuery, which are defined in xFACts-OrchestratorFunctions.ps1.
    Dot-source this file AFTER xFACts-OrchestratorFunctions.ps1 in the consuming
    script's IMPORTS section, so those calls resolve.

.COMPONENT
    ServerOps.Backup

.NOTES
    File Name : xFACts-BackupFunctions.ps1
    Location  : E:\xFACts-PowerShell\xFACts-BackupFunctions.ps1

    FILE ORGANIZATION
    -----------------
    CHANGELOG: CHANGE HISTORY
    FUNCTIONS: PATH RESOLUTION
    FUNCTIONS: EXECUTION LOGGING
    FUNCTIONS: FILE TRACKING STATUS
    FUNCTIONS: RETRY HANDLING
#>

<# ============================================================================
   CHANGELOG: CHANGE HISTORY
   ----------------------------------------------------------------------------
   Dated change history for this script. Most recent first.
   Prefix: (none)
   ============================================================================ #>

# 2026-06-19  Added Invoke-bkp_RetryFailedFiles, consolidating the retry-handling
#             block shared by the network-copy and AWS-upload processors: it
#             resets retry-eligible failed files to PENDING and fires the
#             retries-exhausted Teams alert. The -Operation discriminator selects
#             the Backup_FileTracking column family, alert label, and trigger type.
# 2026-06-19  Initial extraction. Backup-filename physical-server parsing, UNC
#             admin-share path conversion, the Backup_ExecutionLog detail writer,
#             and the AWS-upload and network-copy Backup_FileTracking status
#             writes lifted from the four ServerOps.Backup pipeline scripts into
#             a Backup-scoped shared library so the collectors and processors
#             share one definition of each rather than maintaining parallel
#             copies. Convert-bkp_ToUncPath adopts the defensive form (already-UNC
#             short-circuit, null/empty guard, drive-letter conversion, null on no
#             match). Write-bkp_ExecutionLog takes the union of the prior column
#             sets, including the AWS-only error_details column, and preserves a
#             SQL NULL for any unsupplied duration, byte count, error message, or
#             error detail.

<# ============================================================================
   FUNCTIONS: PATH RESOLUTION
   ----------------------------------------------------------------------------
   Resolve the physical server that owns a backup file and translate a local
   backup path into a UNC admin-share path. Both support reaching AG-listener
   enrollments, whose files live on whichever replica produced them.
   Prefix: bkp
   ============================================================================ #>

# Extracts the physical server name embedded in a backup filename for AG databases.
function Get-bkp_PhysicalServerFromPath {
    param(
        [string]$LocalPath
    )

    $fileName = Split-Path $LocalPath -Leaf
    $parts = $fileName -split '_'

    if ($parts.Count -ge 3) {
        $potentialServer = $parts[1]
        if ($potentialServer -match '^[A-Za-z0-9\-]+$' -and $potentialServer -match '-') {
            return $potentialServer
        }
    }

    return $null
}

# Converts a local backup path to a UNC admin-share path, returning null when the path is unusable.
function Convert-bkp_ToUncPath {
    param(
        [string]$LocalPath,
        [string]$ServerName
    )

    if ([string]::IsNullOrWhiteSpace($LocalPath) -or [string]::IsNullOrWhiteSpace($ServerName)) {
        return $null
    }

    if ($LocalPath -match '^\\\\') {
        return $LocalPath
    }

    if ($LocalPath -match '^([A-Za-z]):\\(.*)$') {
        $driveLetter = $Matches[1]
        $remainder = $Matches[2]
        return "\\$ServerName\$driveLetter`$\$remainder"
    }

    return $null
}

<# ============================================================================
   FUNCTIONS: EXECUTION LOGGING
   ----------------------------------------------------------------------------
   Writes one detail row to ServerOps.Backup_ExecutionLog for a single pipeline
   operation. The parameter set is the union of every pipeline's needs; any
   unsupplied duration, byte count, error message, or error detail is written
   as a SQL NULL.
   Prefix: bkp
   ============================================================================ #>

# Writes a detail entry to Backup_ExecutionLog for a single backup pipeline operation.
function Write-bkp_ExecutionLog {
    param(
        [string]$Component,
        [string]$Operation,
        [string]$Status,
        [string]$ServerName = $null,
        [string]$DatabaseName = $null,
        [string]$FileName = $null,
        [long]$TrackingId = 0,
        [object]$DurationMs = $null,
        [object]$BytesProcessed = $null,
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

<# ============================================================================
   FUNCTIONS: FILE TRACKING STATUS
   ----------------------------------------------------------------------------
   Update the per-file status columns in ServerOps.Backup_FileTracking. The AWS
   and network pipelines write to separate column families, so each pipeline has
   its own writer; only the columns supplied are included in the UPDATE.
   Prefix: bkp
   ============================================================================ #>

# Updates the AWS-upload status columns in Backup_FileTracking for one tracked file.
function Set-bkp_AwsUploadStatus {
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

# Updates the network-copy status columns in Backup_FileTracking for one tracked file.
function Set-bkp_NetworkCopyStatus {
    param(
        [long]$TrackingId,
        [string]$Status,
        [string]$NetworkPath = $null,
        [datetime]$StartDttm = [datetime]::MinValue,
        [datetime]$FinishDttm = [datetime]::MinValue,
        [string]$ErrorMessage = $null
    )

    $setClauses = @("network_copy_status = '$Status'")

    if ($NetworkPath) {
        $networkPathSafe = $NetworkPath -replace "'", "''"
        $setClauses += "network_path = '$networkPathSafe'"
    }

    if ($StartDttm -ne [datetime]::MinValue) {
        $setClauses += "network_copy_started_dttm = '$($StartDttm.ToString("yyyy-MM-dd HH:mm:ss"))'"
    }

    if ($FinishDttm -ne [datetime]::MinValue) {
        $setClauses += "network_copy_completed_dttm = '$($FinishDttm.ToString("yyyy-MM-dd HH:mm:ss"))'"
    }

    $query = "UPDATE ServerOps.Backup_FileTracking SET $($setClauses -join ', ') WHERE tracking_id = $TrackingId"

    return Invoke-SqlNonQuery -Query $query
}

<# ============================================================================
   FUNCTIONS: RETRY HANDLING
   ----------------------------------------------------------------------------
   Resets failed pipeline files that are still within their retry budget back to
   PENDING so the normal processing loop picks them up again, and fires a Teams
   alert for files that have exhausted their retries. The network-copy and
   AWS-upload pipelines share this logic over separate Backup_FileTracking column
   families; the -Operation discriminator selects the column family, alert label,
   and trigger type.
   Prefix: bkp
   ============================================================================ #>

# Resets retry-eligible failed files to PENDING and alerts on files that have exhausted their retries.
function Invoke-bkp_RetryFailedFiles {
    param(
        [ValidateSet('NETWORK_COPY', 'AWS_UPLOAD')]
        [string]$Operation,
        [int]$MaxRetries,
        [switch]$Execute
    )

    $opMap = @{
        'NETWORK_COPY' = @{ ColumnPrefix = 'network_copy'; Label = 'Network Copy'; Trigger = 'BACKUP_NETWORK_COPY_EXHAUSTED' }
        'AWS_UPLOAD'   = @{ ColumnPrefix = 'aws_upload';   Label = 'AWS Upload';   Trigger = 'BACKUP_AWS_UPLOAD_EXHAUSTED' }
    }
    $colPrefix = $opMap[$Operation].ColumnPrefix
    $opLabel = $opMap[$Operation].Label
    $triggerType = $opMap[$Operation].Trigger

    Write-Log "Checking for failed files eligible for retry..."

    $failedRetryable = Get-SqlData -Query @"
SELECT ft.tracking_id, ft.server_name, ft.database_name, ft.file_name,
       ft.${colPrefix}_retry_count,
       COALESCE(ft.compressed_size_bytes, ft.file_size_bytes) AS file_size_bytes
FROM ServerOps.Backup_FileTracking ft
JOIN dbo.ServerRegistry sr ON ft.server_id = sr.server_id
WHERE ft.${colPrefix}_status = 'FAILED'
  AND ft.${colPrefix}_retry_count < $MaxRetries
  AND sr.is_active = 1
  AND sr.serverops_backup_enabled = 1
"@

    $failedExhausted = Get-SqlData -Query @"
SELECT ft.tracking_id, ft.server_name, ft.database_name, ft.file_name,
       ft.${colPrefix}_retry_count,
       COALESCE(ft.compressed_size_bytes, ft.file_size_bytes) AS file_size_bytes
FROM ServerOps.Backup_FileTracking ft
JOIN dbo.ServerRegistry sr ON ft.server_id = sr.server_id
WHERE ft.${colPrefix}_status = 'FAILED'
  AND ft.${colPrefix}_retry_count >= $MaxRetries
  AND sr.is_active = 1
  AND sr.serverops_backup_enabled = 1
"@

    # Reset retryable files to PENDING
    if ($null -ne $failedRetryable -and @($failedRetryable).Count -gt 0) {
        $retryCount = @($failedRetryable).Count
        Write-Log "  Found $retryCount file(s) eligible for retry"

        foreach ($retryFile in $failedRetryable) {
            $retryId = $retryFile.tracking_id
            $retryAttempt = $retryFile."${colPrefix}_retry_count" + 1
            Write-Log "  Retry $retryAttempt/${MaxRetries}: $($retryFile.server_name)/$($retryFile.database_name)/$($retryFile.file_name)"

            if ($Execute) {
                Invoke-SqlNonQuery -Query @"
UPDATE ServerOps.Backup_FileTracking
SET ${colPrefix}_status = 'PENDING',
    ${colPrefix}_started_dttm = NULL,
    ${colPrefix}_completed_dttm = NULL,
    ${colPrefix}_retry_count = ${colPrefix}_retry_count + 1
WHERE tracking_id = $retryId
  AND ${colPrefix}_status = 'FAILED'
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
            $attempts = $exhaustedFile."${colPrefix}_retry_count"

            Send-TeamsAlert -SourceModule 'ServerOps' -AlertCategory 'CRITICAL' `
                -Title "{{FIRE}} Backup $opLabel Failed - Retries Exhausted" `
                -Message @"
**Server:** $($exhaustedFile.server_name)
**Database:** $($exhaustedFile.database_name)
**File:** $($exhaustedFile.file_name)
**Size:** $sizeGB GB
**Attempts:** $($attempts + 1) (original + $attempts retries)

This file has failed all retry attempts and requires manual investigation.
"@ `
                -TriggerType $triggerType `
                -TriggerValue "$($exhaustedFile.tracking_id)"
        }
    }
}
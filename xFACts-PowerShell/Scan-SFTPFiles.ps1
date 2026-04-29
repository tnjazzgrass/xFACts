<#
.SYNOPSIS
    xFACts - SFTP File Monitor
    
.DESCRIPTION
    xFACts - FileOps
    Script: Scan-SFTPFiles.ps1
    Version: Tracked in dbo.System_Metadata (component: FileOps)

    Scans configured SFTP locations for expected files, logs detection events,
    and triggers Teams alerts and Jira tickets for escalations.

    CHANGELOG
    ---------
    2026-04-28  Standardized Teams alerting via Send-TeamsAlert shared function
                Renamed local Send-TeamsAlert wrapper to Send-SFTPAlert (eliminates
                  function name collision with shared orchestrator function)
                Replaced EXEC Teams.sp_QueueAlert call with Send-TeamsAlert
                trigger_value now includes EventType (e.g. 'Detected-2026-04-28')
                  to preserve LateDetected behavior under shared dedup
                Call sites updated: Send-TeamsAlert -> Send-SFTPAlert
    2026-03-11  Migrated to Initialize-XFActsScript shared infrastructure
                Removed inline Write-Log, Get-MasterPassphrase, Get-SFTPCredentials
                Replaced credential retrieval with Get-ServiceCredentials
                Removed $SqlServer/$SqlDatabase params from all business functions
                Converted direct Invoke-Sqlcmd calls to shared Get-SqlData/Invoke-SqlNonQuery
                Updated header to component-level versioning format
    2026-02-24  CDA fallback detection for files consumed between scan cycles
                Fix repeated late detection alerts (LateDetected status)
                Deprecated Remove-DisabledConfigStatus (rows preserved for history)
    2026-02-07  Fixed field name mismatches causing production hang
                MonitorStatus MERGE, MonitorLog INSERT, sp_QueueAlert/sp_QueueTicket
                parameter names corrected
    2026-02-06  Bug fix: $Host renamed to $SFTPHost (PS automatic variable conflict)
    2026-02-05  Orchestrator v2 integration
                Added -Execute, -TaskId, -ProcessId parameters
                Master passphrase moved to GlobalConfig
                Relocated to E:\xFACts-PowerShell on FA-SQLDBB
    2026-01-31  Updated to use individual day columns for schedule checking
    2026-01-20  Initial implementation
                Dashboard model refactor (MonitorStatus one row per config)
                Daily reset, LateDetected event type, disabled config cleanup

.PARAMETER ServerInstance
    SQL Server instance name for xFACts database (default: AVG-PROD-LSNR)
    
.PARAMETER Database
    Database name (default: xFACts)

.PARAMETER Execute
    Perform writes. Without this flag, runs in preview/dry-run mode.

.PARAMETER Force
    Bypass any checks and run immediately.

.PARAMETER TaskId
    Orchestrator TaskLog ID passed by the v2 engine at launch. Used for task 
    completion callback. Default 0 (no callback when run manually).

.PARAMETER ProcessId
    Orchestrator ProcessRegistry ID passed by the v2 engine at launch. Used for 
    task completion callback. Default 0 (no callback when run manually).

================================================================================
DEPLOYMENT REMINDERS
================================================================================
1. Deployed to E:\xFACts-PowerShell on FA-SQLDBB.
2. Credentials retrieved via Get-ServiceCredentials (dbo.Credentials + GlobalConfig).
3. WinSCP must be installed on FA-SQLDBB at C:\Program Files (x86)\WinSCP\.
4. The orchestrator service account (FAC\sqlmon) must have:
   - Read/Write access to xFACts database (FileOps schema)
   - INSERT on Teams.AlertQueue (via shared Send-TeamsAlert) and Jira.sp_QueueTicket
================================================================================
#>

[CmdletBinding()]
param(
    [string]$ServerInstance = "AVG-PROD-LSNR",
    [string]$Database = "xFACts",
    [switch]$Execute,
    [switch]$Force,
    [long]$TaskId = 0,
    [int]$ProcessId = 0
)

# ============================================================================
# STANDARD INITIALIZATION
# ============================================================================

. "$PSScriptRoot\xFACts-OrchestratorFunctions.ps1"

Initialize-XFActsScript -ScriptName 'Scan-SFTPFiles' `
    -ServerInstance $ServerInstance -Database $Database -Execute:$Execute

# ============================================================================
# CONFIGURATION
# ============================================================================

# WinSCP .NET assembly path
$WinSCPPath = "C:\Program Files (x86)\WinSCP\WinSCPnet.dll"

# Jira Settings
$JiraProjectKey = "SD"
$JiraIssueType = "Issue"
$JiraCascadingFieldID = "customfield_18401"
$JiraCascadingParent = "File Processing"
$JiraCascadingChild = "Payment File Issue"
$JiraCustomField1_ID = "customfield_10305"
$JiraCustomField1_Value = "FAC INFORMATION TECHNOLOGY"
$JiraCustomField2_ID = "customfield_10009"
$JiraCustomField2_Value = "sd/1b77b626-3ad4-4bee-8727-abc18b68c5fa"
$JiraEmailRecipients = "datahelp@frost-arnett.com"

# Execution tracking
$Script:StartTime = Get-Date
$Script:ConfigsProcessed = 0
$Script:FilesDetected = 0
$Script:Escalations = 0
$Script:Errors = 0

# ============================================================================
# FUNCTIONS
# ============================================================================

function Remove-DisabledConfigStatus {
    # DEPRECATED in v1.5.0 - Status rows are no longer deleted when monitors are
    # disabled. Disabled monitors are simply skipped by Get-ActiveMonitorConfigs.
    # Status history is preserved for dashboard visibility and audit purposes.
    Write-Log "Status row cleanup skipped (deprecated - rows preserved for history)" "INFO"
}

function Get-ActiveMonitorConfigs {
    Write-Log "Retrieving active monitor configurations..." "INFO"
    
    $sqlQuery = @"
DECLARE @CurrentTime TIME = CAST(GETDATE() AS TIME);
DECLARE @CurrentDate DATE = CAST(GETDATE() AS DATE);
DECLARE @DayOfWeek INT = DATEPART(WEEKDAY, GETDATE()); -- 1=Sunday, 7=Saturday

SELECT 
    mc.config_id,
    mc.config_name,
    mc.sftp_path,
    mc.file_pattern,
    mc.check_start_time,
    mc.check_end_time,
    mc.escalation_time,
    mc.default_priority,
    mc.notify_on_detection,
    mc.notify_on_escalation,
    mc.create_jira_on_escalation,
    sc.sftp_host,
    sc.sftp_port,
    sc.credential_service_name,
    ms.last_status,
    ms.last_scanned_dttm
FROM FileOps.MonitorConfig mc
INNER JOIN FileOps.ServerConfig sc ON mc.server_id = sc.server_id
LEFT JOIN FileOps.MonitorStatus ms ON mc.config_id = ms.config_id
WHERE mc.is_enabled = 1
  AND sc.is_enabled = 1
  AND @CurrentTime >= mc.check_start_time
  AND @CurrentTime <= mc.check_end_time
  AND (
    (@DayOfWeek = 1 AND mc.check_sunday = 1) OR
    (@DayOfWeek = 2 AND mc.check_monday = 1) OR
    (@DayOfWeek = 3 AND mc.check_tuesday = 1) OR
    (@DayOfWeek = 4 AND mc.check_wednesday = 1) OR
    (@DayOfWeek = 5 AND mc.check_thursday = 1) OR
    (@DayOfWeek = 6 AND mc.check_friday = 1) OR
    (@DayOfWeek = 7 AND mc.check_saturday = 1)
  )
ORDER BY sc.credential_service_name, mc.config_name;
"@
    
    try {
        $configs = @(Get-SqlData -Query $sqlQuery)
        Write-Log "Found $($configs.Count) active configuration(s) to check" "INFO"
        return $configs
    } catch {
        Write-Log "Failed to retrieve configurations: $($_.Exception.Message)" "ERROR"
        throw
    }
}

function Update-MonitorStatus {
    param(
        [int]$ConfigId,
        [string]$ConfigName,
        [string]$SftpPath,
        [string]$Status,
        [string]$FileName = $null
    )

    if (-not $Execute) {
        Write-Log "[PREVIEW] Would update MonitorStatus: $ConfigName = $Status" "INFO"
        return
    }
    
    $fileNameValue = if ($FileName) { "'$FileName'" } else { "NULL" }
    $detectedDttm = if ($Status -eq 'Detected' -or $Status -eq 'Escalated') { "GETDATE()" } else { "NULL" }
    
    $sqlQuery = @"
MERGE FileOps.MonitorStatus AS target
USING (SELECT $ConfigId AS config_id) AS source
ON target.config_id = source.config_id
WHEN MATCHED THEN
    UPDATE SET 
        last_status = '$Status',
        last_scanned_dttm = GETDATE(),
        file_detected_name = COALESCE($fileNameValue, file_detected_name),
        file_detected_dttm = COALESCE($detectedDttm, file_detected_dttm)
WHEN NOT MATCHED THEN
INSERT (config_id, config_name, sftp_path, last_status, last_scanned_dttm, file_detected_name, file_detected_dttm)
VALUES ($ConfigId, '$($ConfigName.Replace("'", "''"))', '$($SftpPath.Replace("'", "''"))', '$Status', GETDATE(), $fileNameValue, $detectedDttm);
"@
    
    try {
        Invoke-SqlNonQuery -Query $sqlQuery | Out-Null
        Write-Log "MonitorStatus updated: $ConfigName = $Status" "SUCCESS"
    } catch {
        Write-Log "Failed to update MonitorStatus: $($_.Exception.Message)" "ERROR"
        $Script:Errors++
    }
}

function Update-LastScannedOnly {
    param(
        [int]$ConfigId
    )

    if (-not $Execute) {
        return  # Silent in preview - this is just timestamp updates
    }
    
    $sqlQuery = @"
UPDATE FileOps.MonitorStatus
SET last_scanned_dttm = GETDATE()
WHERE config_id = $ConfigId;
"@
    
    try {
        Invoke-SqlNonQuery -Query $sqlQuery | Out-Null
    } catch {
        Write-Log "Failed to update last_scanned_dttm: $($_.Exception.Message)" "ERROR"
    }
}

function Reset-MonitorStatus {
    param(
        [int]$ConfigId,
        [string]$ConfigName,
        [string]$SftpPath
    )

    if (-not $Execute) {
        Write-Log "[PREVIEW] Would reset MonitorStatus for new day: $ConfigName" "INFO"
        return
    }
    
    $sqlQuery = @"
MERGE FileOps.MonitorStatus AS target
USING (SELECT $ConfigId AS config_id) AS source
ON target.config_id = source.config_id
WHEN MATCHED THEN
    UPDATE SET 
        last_status = 'Monitoring',
        last_scanned_dttm = GETDATE(),
        file_detected_name = NULL,
        file_detected_dttm = NULL
WHEN NOT MATCHED THEN
    INSERT (config_id, config_name, sftp_path, last_status, last_scanned_dttm)
    VALUES ($ConfigId, '$($ConfigName.Replace("'", "''"))', '$($SftpPath.Replace("'", "''"))', 'Monitoring', GETDATE());
"@
    
    try {
        Invoke-SqlNonQuery -Query $sqlQuery | Out-Null
        Write-Log "MonitorStatus reset for new day: $ConfigName" "INFO"
    } catch {
        Write-Log "Failed to reset MonitorStatus: $($_.Exception.Message)" "ERROR"
    }
}

function Add-MonitorLog {
    param(
        [int]$ConfigId,
        [string]$ConfigName,
        [string]$SftpPath,
        [string]$EventType,
        [string]$FileName = $null,
        [bool]$TeamsQueued = $false,
        [bool]$JiraQueued = $false
    )

    if (-not $Execute) {
        Write-Log "[PREVIEW] Would add MonitorLog: $ConfigName - $EventType" "INFO"
        return
    }
    
    $fileNameValue = if ($FileName) { "'$FileName'" } else { "NULL" }
    
    $sqlQuery = @"
INSERT INTO FileOps.MonitorLog (config_id, config_name, sftp_path, log_date, event_type, file_detected_name, event_dttm, teams_alert_queued, jira_ticket_queued)
VALUES ($ConfigId, '$($ConfigName.Replace("'", "''"))', '$($SftpPath.Replace("'", "''"))', CAST(GETDATE() AS DATE), '$EventType', $fileNameValue, GETDATE(), $([int]$TeamsQueued), $([int]$JiraQueued));
"@
    
    try {
        Invoke-SqlNonQuery -Query $sqlQuery | Out-Null
        Write-Log "MonitorLog entry added: $ConfigName - $EventType" "SUCCESS"
    } catch {
        Write-Log "Failed to add MonitorLog entry: $($_.Exception.Message)" "ERROR"
    }
}

function Send-SFTPAlert {
    <#
    .SYNOPSIS
        Wrapper around shared Send-TeamsAlert that builds SFTP-specific title and
        message for each EventType, then queues via the shared function.

    .DESCRIPTION
        Preserves the script's preview-mode convention (every write path bails on
        -not $Execute with a [PREVIEW] log line). Severity and content are derived
        from EventType. trigger_value embeds EventType so that Detected, Escalated,
        and LateDetected events for the same ConfigName on the same day each have
        distinct dedup keys (required because the shared Send-TeamsAlert performs
        mandatory dedup against Teams.RequestLog).
    #>
    param(
        [string]$ConfigName,
        [string]$EventType,
        [string]$FileName = $null,
        [string]$SftpPath = $null,
        [bool]$IsLateDetection = $false
    )

    if (-not $Execute) {
        Write-Log "[PREVIEW] Would queue Teams alert: $EventType for $ConfigName" "INFO"
        return
    }

    $today = Get-Date -Format "MM/dd/yyyy"

    $category = if ($EventType -eq 'Escalated') { 'WARNING' } else { 'INFO' }
    $color    = if ($EventType -eq 'Escalated') { 'warning' } else { 'good' }

    $title = switch ($EventType) {
        'Detected'     { "xFACts: File Detected - $ConfigName - $today" }
        'LateDetected' { "xFACts: File Detected (Late) - $ConfigName - $today" }
        'Escalated'    { "xFACts: File Not Detected - $ConfigName - $today" }
        default        { "xFACts: File Monitor - $ConfigName - $today" }
    }

    $message = switch ($EventType) {
        'Detected'     { "File detected: $FileName`nPath: $SftpPath" }
        'LateDetected' { "File detected after escalation: $FileName`nPath: $SftpPath" }
        'Escalated'    { "Expected file not detected by escalation time.`nPath: $SftpPath" }
        default        { "Event: $EventType`nPath: $SftpPath" }
    }

    Send-TeamsAlert -SourceModule 'FileOps' -AlertCategory $category `
        -Title $title -Message $message -Color $color `
        -TriggerType $ConfigName `
        -TriggerValue "$EventType-$(Get-Date -Format 'yyyy-MM-dd')" | Out-Null
}

function Send-JiraTicket {
    param(
        [string]$ConfigName,
        [string]$SftpPath,
        [string]$FilePattern,
        [string]$EscalationTime,
        [string]$Priority
    )

    if (-not $Execute) {
        Write-Log "[PREVIEW] Would queue Jira ticket: $ConfigName" "INFO"
        $Script:Escalations++  # Still count for summary
        return
    }
    
    $today = Get-Date -Format "MM/dd/yyyy"
    $summary = "Critical Payment Process Check - $ConfigName - $today"
    
    $description = @"
*File Monitor Escalation*

Expected file not detected by escalation deadline.

*Configuration:* $ConfigName
*SFTP Path:* $SftpPath
*File Pattern:* $FilePattern
*Escalation Time:* $EscalationTime

Please investigate the source system and ensure the file is delivered.
"@
    
    # Calculate due date based on priority
    $dueDays = switch ($Priority) {
        'Highest' { 1 }
        'High'    { 2 }
        'Medium'  { 3 }
        'Low'     { 5 }
        'Lowest'  { 7 }
        default   { 3 }
    }
    $dueDate = (Get-Date).AddDays($dueDays).ToString("yyyy-MM-dd")

    $sqlQuery = @"
EXEC Jira.sp_QueueTicket
    @SourceModule = 'FileOps',
    @ProjectKey = '$JiraProjectKey',
    @Summary = '$($summary.Replace("'", "''"))',
    @Description = '$($description.Replace("'", "''"))',
    @IssueType = '$JiraIssueType',
    @Priority = '$Priority',
    @DueDate = '$dueDate',
    @EmailRecipients = '$JiraEmailRecipients',
    @CascadingField_ID = '$JiraCascadingFieldID',
    @CascadingField_ParentValue = '$JiraCascadingParent',
    @CascadingField_ChildValue = '$JiraCascadingChild',
    @CustomField_ID = '$JiraCustomField1_ID',
    @CustomField_Value = '$JiraCustomField1_Value',
    @CustomField2_ID = '$JiraCustomField2_ID',
    @CustomField2_Value = '$JiraCustomField2_Value';
"@
    
    try {
        Invoke-SqlNonQuery -Query $sqlQuery | Out-Null
        Write-Log "Jira ticket queued: $summary" "SUCCESS"
        $Script:Escalations++
    } catch {
        Write-Log "Failed to queue Jira ticket: $($_.Exception.Message)" "ERROR"
    }
}

function Scan-SFTPDirectory {
    param(
        [string]$SFTPHost,
        [int]$Port,
        [string]$Username,
        [string]$Password,
        [string]$Path,
        [string]$Pattern
    )
    
    try {
        $sessionOptions = New-Object WinSCP.SessionOptions -Property @{
            Protocol = [WinSCP.Protocol]::Sftp
            HostName = $SFTPHost
            PortNumber = $Port
            UserName = $Username
            Password = $Password
            GiveUpSecurityAndAcceptAnySshHostKey = $true
        }
        
        $session = New-Object WinSCP.Session
        
        try {
            $session.Open($sessionOptions)
            
            $directoryInfo = $session.ListDirectory($Path)
            
            # Convert file pattern to regex
            $regexPattern = "^" + [regex]::Escape($Pattern).Replace("\*", ".*").Replace("\?", ".") + "$"
            
            foreach ($file in $directoryInfo.Files) {
                if ($file.Name -match $regexPattern -and -not $file.IsDirectory) {
                    return @{
                        Found = $true
                        FileName = $file.Name
                        FileSize = $file.Length
                        ModifiedTime = $file.LastWriteTime
                    }
                }
            }
            
            return @{ Found = $false }
            
        } finally {
            $session.Dispose()
        }
        
    } catch {
        Write-Log "SFTP scan failed: $($_.Exception.Message)" "ERROR"
        return @{ Found = $false; Error = $_.Exception.Message }
    }
}

function Search-ClientDataArchive {
    <#
    .SYNOPSIS
        Fallback detection: searches the Client Data Archive for a file that may
        have been consumed from SFTP between scan cycles.
    .DESCRIPTION
        Iterates Inbound and Outbound directories under the CDA base path, checking
        only today's date-stamped subfolders ({client}\{yyyy}\{MM}\{dd}) for a
        matching file pattern. Typically completes in 1-2 seconds.
    #>
    param(
        [string]$CDABasePath,
        [string]$FilePattern
    )
    
    if ([string]::IsNullOrEmpty($CDABasePath)) {
        return @{ Found = $false; FileName = $null }
    }
    
    try {
        $todayPath = Get-Date -Format "yyyy\\MM\\dd"
        
        foreach ($direction in @("Inbound", "Outbound")) {
            $directionPath = Join-Path $CDABasePath $direction
            if (-not (Test-Path $directionPath)) { continue }
            
            $clientFolders = Get-ChildItem $directionPath -Directory -ErrorAction SilentlyContinue
            foreach ($clientFolder in $clientFolders) {
                $datePath = Join-Path $clientFolder.FullName $todayPath
                if (Test-Path $datePath) {
                    $match = Get-ChildItem $datePath -Filter $FilePattern -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($match) {
                        return @{ Found = $true; FileName = $match.Name }
                    }
                }
            }
        }
        
        return @{ Found = $false; FileName = $null }
    } catch {
        Write-Log "CDA fallback search error: $($_.Exception.Message)" "WARN"
        return @{ Found = $false; FileName = $null }
    }
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

try {
    Write-Log "========== SFTP File Monitor Started ==========" "INFO"
    
    # Load WinSCP assembly
    if (-not (Test-Path $WinSCPPath)) {
        throw "WinSCP assembly not found at $WinSCPPath"
    }
    Add-Type -Path $WinSCPPath
    Write-Log "WinSCP assembly loaded" "SUCCESS"
    
    # Get CDA fallback path from GlobalConfig (optional - null disables fallback)
    $cdaResult = Get-SqlData -Query @"
SELECT setting_value
FROM dbo.GlobalConfig
WHERE module_name = 'FileOps'
  AND category = 'Detection'
  AND setting_name = 'cda_base_path'
  AND is_active = 1;
"@
    $CDABasePath = if ($cdaResult -and -not [string]::IsNullOrEmpty($cdaResult.setting_value)) { $cdaResult.setting_value } else { $null }
    if ($CDABasePath) {
        Write-Log "CDA fallback enabled: $CDABasePath" "INFO"
    } else {
        Write-Log "CDA fallback not configured - skipping archive checks" "INFO"
    }
    
    # Clean up disabled config status rows
    Remove-DisabledConfigStatus
    
    # Get active configurations
    $configs = Get-ActiveMonitorConfigs
    
    if ($configs.Count -eq 0) {
        Write-Log "No active configurations to process" "INFO"
    } else {
        # Group by credential service for efficient connection reuse
        $configGroups = $configs | Group-Object -Property credential_service_name
        
        foreach ($group in $configGroups) {
            $serviceName = $group.Name
            Write-Log "Processing server group: $serviceName" "INFO"
            
            # Get credentials for this server group via shared credential retrieval
            $creds = Get-ServiceCredentials -ServiceName $serviceName
            
            foreach ($config in $group.Group) {
                $Script:ConfigsProcessed++
                Write-Log "Processing: $($config.config_name)" "INFO"
                
                $currentDate = Get-Date -Format "yyyy-MM-dd"
                $currentTime = Get-Date
                
                # Check if this is a new monitoring window (last scan was from previous day)
                $lastScannedDate = if ($config.last_scanned_dttm -and $config.last_scanned_dttm -isnot [DBNull]) { 
                    (Get-Date $config.last_scanned_dttm).ToString("yyyy-MM-dd") 
                } else { 
                    $null 
                }
                
                if ($lastScannedDate -and $lastScannedDate -ne $currentDate) {
                    # New day - reset status
                    Reset-MonitorStatus `
                    -ConfigId $config.config_id -ConfigName $config.config_name `
                    -SftpPath $config.sftp_path
                    $currentStatus = 'Monitoring'
                } else {
                    $currentStatus = if ($config.last_status -and $config.last_status -isnot [DBNull]) { $config.last_status } else { 'Monitoring' }
                }
                
                # If already detected today, just update timestamp and skip
                if ($currentStatus -eq 'Detected' -or $currentStatus -eq 'LateDetected') {
                    Update-LastScannedOnly -ConfigId $config.config_id
                    Write-Log "Already detected today for $($config.config_name) - skipping scan" "INFO"
                    continue
                }
                
                # Calculate today's escalation time
                $todayEscalation = Get-Date -Hour ([TimeSpan]::Parse($config.escalation_time).Hours) `
                    -Minute ([TimeSpan]::Parse($config.escalation_time).Minutes) -Second 0
                
                # Scan SFTP
                Write-Log "Scanning $($config.sftp_host):$($config.sftp_path) for pattern '$($config.file_pattern)'..." "INFO"
                
                $scanResult = Scan-SFTPDirectory -SFTPHost $config.sftp_host -Port $config.sftp_port `
                    -Username $creds.Username -Password $creds.Password `
                    -Path $config.sftp_path -Pattern $config.file_pattern
                
                if ($scanResult.Error) {
                    $Script:Errors++
                    Write-Log "Scan error for $($config.config_name): $($scanResult.Error)" "WARN"
                }
                
                # CDA fallback: if SFTP scan didn't find the file, check archive
                if (-not $scanResult.Found -and $CDABasePath) {
                    Write-Log "File not on SFTP - checking Client Data Archive fallback..." "INFO"
                    $cdaCheck = Search-ClientDataArchive -CDABasePath $CDABasePath -FilePattern $config.file_pattern
                    if ($cdaCheck.Found) {
                        Write-Log "CDA fallback hit: $($cdaCheck.FileName) found in archive" "SUCCESS"
                        $scanResult = @{ Found = $true; FileName = $cdaCheck.FileName; Error = $null }
                    }
                }
               
                if ($scanResult.Found) {
                    $Script:FilesDetected++
                    Write-Log "File detected: $($scanResult.FileName)" "SUCCESS"
                    
                    if ($currentStatus -eq 'Escalated') {
                        # Late detection - file arrived after escalation
                        Update-MonitorStatus `
                            -ConfigId $config.config_id -ConfigName $config.config_name `
                            -SftpPath $config.sftp_path -Status 'LateDetected' -FileName $scanResult.FileName
                        
                        # Late detections always notify (important to know file finally arrived)
                        $teamsQueued = $config.notify_on_detection -or $config.notify_on_escalation
                        
                        Add-MonitorLog `
                            -ConfigId $config.config_id -ConfigName $config.config_name `
                            -SftpPath $config.sftp_path -EventType 'LateDetected' `
                            -FileName $scanResult.FileName -TeamsQueued $teamsQueued -JiraQueued $false
                        
                        if ($teamsQueued) {
                            Send-SFTPAlert `
                                -ConfigName $config.config_name -EventType 'LateDetected' `
                                -FileName $scanResult.FileName -SftpPath $config.sftp_path `
                                -IsLateDetection $true
                        }
                        
                        Write-Log "Late detection logged for $($config.config_name)" "WARN"
                    } else {
                        # Normal detection
                        Update-MonitorStatus `
                            -ConfigId $config.config_id -ConfigName $config.config_name `
                            -SftpPath $config.sftp_path -Status 'Detected' -FileName $scanResult.FileName
                        
                        $teamsQueued = [bool]$config.notify_on_detection
                        
                        Add-MonitorLog `
                            -ConfigId $config.config_id -ConfigName $config.config_name `
                            -SftpPath $config.sftp_path -EventType 'Detected' `
                            -FileName $scanResult.FileName -TeamsQueued $teamsQueued -JiraQueued $false
                        
                        if ($teamsQueued) {
                            Send-SFTPAlert `
                                -ConfigName $config.config_name -EventType 'Detected' `
                                -FileName $scanResult.FileName -SftpPath $config.sftp_path `
                                -IsLateDetection $false
                        }
                    }
                    
                } elseif ($currentTime -ge $todayEscalation -and $currentStatus -ne 'Escalated') {
                    # Past escalation time, file not found, not already escalated
                    Update-MonitorStatus `
                        -ConfigId $config.config_id -ConfigName $config.config_name `
                        -SftpPath $config.sftp_path -Status 'Escalated'
                    
                    $teamsQueued = [bool]$config.notify_on_escalation
                    $jiraQueued = [bool]$config.create_jira_on_escalation
                    
                    Add-MonitorLog `
                        -ConfigId $config.config_id -ConfigName $config.config_name `
                        -SftpPath $config.sftp_path -EventType 'Escalated' `
                        -TeamsQueued $teamsQueued -JiraQueued $jiraQueued
                    
                    if ($teamsQueued) {
                        Send-SFTPAlert `
                            -ConfigName $config.config_name -EventType 'Escalated' `
                            -SftpPath $config.sftp_path
                    }
                    
                    if ($jiraQueued) {
                        Send-JiraTicket `
                            -ConfigName $config.config_name -SftpPath $config.sftp_path `
                            -FilePattern $config.file_pattern `
                            -EscalationTime $todayEscalation.ToString('yyyy-MM-dd HH:mm:ss') `
                            -Priority $config.default_priority
                    }
                    
                } else {
                    # No state change, just update last_scanned_dttm
                    Update-LastScannedOnly -ConfigId $config.config_id
                    Write-Log "No action needed for $($config.config_name) - still monitoring" "INFO"
                }
            }
        }
    }
    
    $duration = (Get-Date) - $Script:StartTime
    
    Write-Log "========== SFTP File Monitor Completed ==========" "SUCCESS"
    Write-Log "  Configs processed: $($Script:ConfigsProcessed)" "INFO"
    Write-Log "  Files detected: $($Script:FilesDetected)" "INFO"
    Write-Log "  Escalations: $($Script:Escalations)" "INFO"
    Write-Log "  Errors: $($Script:Errors)" "INFO"
    Write-Log "  Duration: $([int]$duration.TotalMilliseconds) ms" "INFO"
    
        if (-not $Execute) {
            Write-Host ""
            Write-Host "  *** PREVIEW MODE - No changes were made ***" -ForegroundColor Yellow
            Write-Host "  Run with -Execute to perform actual updates" -ForegroundColor Yellow
        }
    
        # Orchestrator callback
        if ($TaskId -gt 0) {
        $totalMs = [int]$duration.TotalMilliseconds
        $outputMsg = "Configs: $($Script:ConfigsProcessed), Detected: $($Script:FilesDetected), Escalated: $($Script:Escalations)"
        Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
            -TaskId $TaskId -ProcessId $ProcessId `
            -Status "SUCCESS" -DurationMs $totalMs `
            -Output $outputMsg
    }
    
    exit 0
    
} catch {
    Write-Log "Fatal error: $($_.Exception.Message)" "ERROR"
    
    # Report failure to orchestrator
    if ($TaskId -gt 0) {
        $totalMs = [int]((Get-Date) - $Script:StartTime).TotalMilliseconds
        Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
            -TaskId $TaskId -ProcessId $ProcessId `
            -Status "FAILED" -DurationMs $totalMs `
            -ErrorMessage $_.Exception.Message
    }
    
    exit 1
}
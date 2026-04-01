<#
.SYNOPSIS
    xFACts - Shared Orchestrator & Script Infrastructure Functions

.DESCRIPTION
    Common functions used by all scripts running under the xFACts platform:
    - Script initialization (SQL module, logging, execute guard, application identity)
    - Standardized logging (console + file)
    - SQL data access with automatic application name tagging
    - Task completion callback (updates TaskLog and ProcessRegistry)
    - Teams alert queuing with mandatory deduplication
    
    Dot-source this file at the top of all xFACts scripts:
    . "$PSScriptRoot\xFACts-OrchestratorFunctions.ps1"

.NOTES
    File Name      : xFACts-OrchestratorFunctions.ps1
    Location       : E:\xFACts-PowerShell
    Author         : Frost Arnett Applications Team
    Version        : Tracked in dbo.System_Metadata (component: Engine.Orchestrator)

================================================================================
CHANGELOG
================================================================================
2026-03-16  Added Send-TeamsAlert shared function for Teams alert queuing with
            mandatory dedup against Teams.RequestLog. Replaces inline INSERT
            pattern used by individual scripts. No opt-out for dedup — callers
            needing repeating alerts must pass unique TriggerValue each time.
2026-03-10  Added -MaxCharLength parameter to Get-SqlData and Invoke-SqlNonQuery.
            Optional; when specified, passed through to Invoke-Sqlcmd. Required
            for scripts processing large XML/text (XE sessions, DMVs, replication).
            Refactored both functions to use splatting for cleaner parameter passing.
2026-03-08  Added Get-ServiceCredentials for standalone credential retrieval
            using two-tier decryption via Get-SqlData. Replaces per-script
            inline credential functions (Jira, SFTP, etc.).
            Bug fix: Renamed -Db parameter to -DatabaseName in Get-SqlData
            and Invoke-SqlNonQuery. -Db conflicts with PowerShell's built-in
            -Debug alias when callers use [CmdletBinding()].
2.2.0  Engine event scheduling metadata
       - Send-EngineEvent: added IntervalSeconds, ScheduledTime,
         RunMode parameters. Included in PROCESS_COMPLETED payload
         so engine-events.js uses live scheduling values for
         countdown timers instead of hardcoded defaults.
       - Complete-OrchestratorTask: expanded ProcessRegistry metadata
         query to include interval_seconds, scheduled_time, run_mode.
         Passes scheduling fields through to Send-EngineEvent.
2.1.0  Real-time engine event push
       - Added Send-EngineEvent function: fire-and-forget HTTP POST to
         Control Center internal WebSocket endpoint (localhost:8085)
       - Added PROCESS_COMPLETED event push in Complete-OrchestratorTask
         for FIRE_AND_FORGET processes. Looks up process_name and
         module_name from ProcessRegistry by process_id
2.0.0  Shared script infrastructure
       Added Initialize-XFActsScript for standardized startup
       Added Write-Log for console + file logging
       Added Get-SqlData for read queries with application identity
       Added Invoke-SqlNonQuery for write queries with application identity
       SQL module loading moved into Initialize-XFActsScript
       Execute guard messaging standardized
       All SQL calls automatically tagged with script name for DMV attribution
1.1.0  Concurrent execution support
       Changed ProcessRegistry update from is_running = 0 to running_count
         decrement with floor protection at zero
1.0.0  Initial implementation
       Complete-OrchestratorTask callback function for fire-and-forget scripts
================================================================================
#>

# ============================================================================
# SCRIPT-LEVEL CONTEXT (set by Initialize-XFActsScript)
# ============================================================================

# These variables are populated by Initialize-XFActsScript and used by all
# shared functions. They live at the dot-sourced script scope so they're
# accessible throughout the calling script.
$script:XFActsScriptName    = $null   # e.g., 'Collect-BackupStatus'
$script:XFActsAppName       = $null   # e.g., 'xFACts Collect-BackupStatus'
$script:XFActsLogFile       = $null   # e.g., 'E:\xFACts-PowerShell\Logs\Collect-BackupStatus_20260220.log'
$script:XFActsServerInstance = $null  # Default SQL Server instance
$script:XFActsDatabase      = $null   # Default database
$script:XFActsExecute       = $false  # Whether -Execute was specified

# ============================================================================
# SCRIPT INITIALIZATION
# ============================================================================

function Initialize-XFActsScript {
    <#
    .SYNOPSIS
        Standardized initialization for all xFACts scripts.

    .DESCRIPTION
        Performs all common startup tasks that every xFACts script requires:
        1. Loads the SqlServer module (falls back to SQLPS if unavailable)
        2. Sets working directory to script root (SQLPS changes to SQLSERVER:\)
        3. Configures application identity for DMV/XE attribution
        4. Sets up log file path
        5. Stores default connection parameters for Get-SqlData / Invoke-SqlNonQuery
        6. Displays Execute guard message if running in preview mode

        Call this once at the top of every script, immediately after dot-sourcing.

    .PARAMETER ScriptName
        Name of the calling script without .ps1 extension.
        Used for: application name tagging, log file naming, console output.

    .PARAMETER ServerInstance
        Default SQL Server instance for database calls. Individual calls
        can override via -Instance parameter.

    .PARAMETER Database
        Default database name. Individual calls can override via -DatabaseName parameter.

    .PARAMETER Execute
        Pass the script's -Execute switch value. When $false (default),
        displays a standardized preview mode warning.

    .EXAMPLE
        . "$PSScriptRoot\xFACts-OrchestratorFunctions.ps1"
        Initialize-XFActsScript -ScriptName 'Collect-BackupStatus' -Execute:$Execute

    .EXAMPLE
        . "$PSScriptRoot\xFACts-OrchestratorFunctions.ps1"
        Initialize-XFActsScript -ScriptName 'My-NewScript' `
            -ServerInstance 'CUSTOM-INSTANCE' -Database 'OtherDB' -Execute:$Execute
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ScriptName,

        [string]$ServerInstance = "AVG-PROD-LSNR",
        [string]$Database = "xFACts",
        [bool]$Execute = $false
    )

    # Store context for shared functions
    $script:XFActsScriptName     = $ScriptName
    $script:XFActsAppName        = "xFACts $ScriptName"
    $script:XFActsLogFile        = "$PSScriptRoot\Logs\${ScriptName}_$(Get-Date -Format 'yyyyMMdd').log"
    $script:XFActsServerInstance = $ServerInstance
    $script:XFActsDatabase       = $Database
    $script:XFActsExecute        = $Execute

    # -----------------------------------------------------------------
    # SQL Module Loading
    # -----------------------------------------------------------------
    $sqlModuleLoaded = $false

    try {
        Import-Module SqlServer -ErrorAction Stop
        $sqlModuleLoaded = $true
    }
    catch {
        try {
            Push-Location
            $WarningPreference = 'SilentlyContinue'
            Import-Module SQLPS -DisableNameChecking -ErrorAction Stop
            $WarningPreference = 'Continue'
            Pop-Location
            $sqlModuleLoaded = $true
        }
        catch {
            Pop-Location -ErrorAction SilentlyContinue
        }
    }

    if (-not $sqlModuleLoaded) {
        Write-Host "ERROR: No SQL module could be loaded (tried SqlServer and SQLPS)." -ForegroundColor Red
        Write-Host "Install SqlServer module with: Install-Module SqlServer" -ForegroundColor Yellow
        exit 1
    }

    # Ensure we're on a filesystem provider (SQLPS changes to SQLSERVER:\)
    Set-Location $PSScriptRoot

    # -----------------------------------------------------------------
    # Execute Guard
    # -----------------------------------------------------------------
    if (-not $Execute) {
        Write-Host "*** PREVIEW MODE - No changes will be made. Use -Execute to run. ***" -ForegroundColor Yellow
    }
}

# ============================================================================
# LOGGING
# ============================================================================

function Write-Log {
    <#
    .SYNOPSIS
        Writes a timestamped log entry to console and log file.

    .DESCRIPTION
        Standard logging function for all xFACts scripts. Writes to both
        the console (color-coded by level) and the daily log file set up
        by Initialize-XFActsScript.

        Log directory is created automatically if it doesn't exist.

    .PARAMETER Message
        The log message text.

    .PARAMETER Level
        Severity level: INFO (default), WARN, ERROR, SUCCESS, DEBUG.

    .EXAMPLE
        Write-Log "Starting collection"
        Write-Log "Failed to connect" "ERROR"
        Write-Log "Processed 15 records" "SUCCESS"
    #>
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"

    $color = switch ($Level) {
        "ERROR"   { "Red" }
        "WARN"    { "Yellow" }
        "SUCCESS" { "Green" }
        "DEBUG"   { "DarkGray" }
        default   { "White" }
    }
    Write-Host $logMessage -ForegroundColor $color

    if ($script:XFActsLogFile) {
        $logDir = Split-Path $script:XFActsLogFile -Parent
        if (-not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        Add-Content -Path $script:XFActsLogFile -Value $logMessage -ErrorAction SilentlyContinue
    }
}

# ============================================================================
# SQL DATA ACCESS
# ============================================================================

function Get-SqlData {
    <#
    .SYNOPSIS
        Executes a SQL query and returns the result set.

    .DESCRIPTION
        Wrapper around Invoke-Sqlcmd for read queries. Automatically applies:
        - Application name from Initialize-XFActsScript context (for DMV/XE attribution)
        - Default server instance and database (overridable per call)
        - Configurable query timeout (default 300 seconds)
        - Error logging via Write-Log
        - Standard Invoke-Sqlcmd flags (-SuppressProviderContextWarning, -TrustServerCertificate)

        Returns the result set on success, $null on failure.

    .PARAMETER Query
        The SQL query to execute.

    .PARAMETER Instance
        SQL Server instance. Defaults to the value set in Initialize-XFActsScript.

    .PARAMETER DatabaseName
        Database name. Defaults to the value set in Initialize-XFActsScript.

    .PARAMETER Timeout
        Query timeout in seconds. Default: 300.

    .PARAMETER MaxCharLength
        Maximum character length for string columns. When specified, passed to
        Invoke-Sqlcmd -MaxCharLength. Required for queries returning large XML
        or text data (XE sessions, DMV XML plans, replication XML, etc.).
        When omitted, Invoke-Sqlcmd uses its default (4000).

    .EXAMPLE
        $results = Get-SqlData -Query "SELECT * FROM dbo.ServerRegistry WHERE is_monitored = 1"

    .EXAMPLE
        # Override instance for cross-server query
        $remoteData = Get-SqlData -Query "SELECT ..." -Instance "OTHER-SERVER" -DatabaseName "msdb" -Timeout 60

    .EXAMPLE
        # Large text/XML data
        $xeData = Get-SqlData -Query "SELECT target_data FROM sys.dm_xe_session_targets" -MaxCharLength 2147483647
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Query,

        [string]$Instance = $script:XFActsServerInstance,
        [string]$DatabaseName = $script:XFActsDatabase,
        [int]$Timeout = 300,
        [int]$MaxCharLength = 0
    )

    try {
        $params = @{
            ServerInstance               = $Instance
            Database                     = $DatabaseName
            Query                        = $Query
            QueryTimeout                 = $Timeout
            ApplicationName              = $script:XFActsAppName
            ErrorAction                  = 'Stop'
            SuppressProviderContextWarning = $true
            TrustServerCertificate       = $true
        }

        if ($MaxCharLength -gt 0) {
            $params['MaxCharLength'] = $MaxCharLength
        }

        Invoke-Sqlcmd @params
    }
    catch {
        Write-Log "SQL Query failed on ${Instance}/${DatabaseName}: $($_.Exception.Message)" "ERROR"
        return $null
    }
}

function Invoke-SqlNonQuery {
    <#
    .SYNOPSIS
        Executes a SQL statement that does not return a result set.

    .DESCRIPTION
        Wrapper around Invoke-Sqlcmd for INSERT, UPDATE, DELETE, and other
        non-query operations. Automatically applies the same connection
        defaults and application identity as Get-SqlData.

        Returns $true on success, $false on failure.

    .PARAMETER Query
        The SQL statement to execute.

    .PARAMETER Instance
        SQL Server instance. Defaults to the value set in Initialize-XFActsScript.

    .PARAMETER DatabaseName
        Database name. Defaults to the value set in Initialize-XFActsScript.

    .PARAMETER Timeout
        Query timeout in seconds. Default: 300.

    .PARAMETER MaxCharLength
        Maximum character length for string columns. When specified, passed to
        Invoke-Sqlcmd -MaxCharLength. Typically not needed for non-query
        operations but included for parity with Get-SqlData.

    .EXAMPLE
        $ok = Invoke-SqlNonQuery -Query "UPDATE dbo.SomeTable SET status = 'DONE' WHERE id = 1"
        if (-not $ok) { Write-Log "Update failed" "ERROR" }

    .EXAMPLE
        # Short timeout for quick operations
        Invoke-SqlNonQuery -Query "INSERT INTO ..." -Timeout 30
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Query,

        [string]$Instance = $script:XFActsServerInstance,
        [string]$DatabaseName = $script:XFActsDatabase,
        [int]$Timeout = 300,
        [int]$MaxCharLength = 0
    )

    try {
        $params = @{
            ServerInstance               = $Instance
            Database                     = $DatabaseName
            Query                        = $Query
            QueryTimeout                 = $Timeout
            ApplicationName              = $script:XFActsAppName
            ErrorAction                  = 'Stop'
            SuppressProviderContextWarning = $true
            TrustServerCertificate       = $true
        }

        if ($MaxCharLength -gt 0) {
            $params['MaxCharLength'] = $MaxCharLength
        }

        Invoke-Sqlcmd @params
        return $true
    }
    catch {
        Write-Log "SQL Execute failed on ${Instance}/${DatabaseName}: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

# ============================================================================
# CREDENTIAL RETRIEVAL
# ============================================================================

function Get-ServiceCredentials {
    <#
    .SYNOPSIS
        Retrieves decrypted credentials for an external service from dbo.Credentials.

    .DESCRIPTION
        Implements the two-tier decryption model used across the xFACts platform:
        1. Master passphrase retrieved from GlobalConfig (Shared.Credentials.master_passphrase)
        2. Master passphrase decrypts the service-level passphrase
        3. Service passphrase decrypts all credential values for the service

        Returns a hashtable of ConfigKey = DecryptedValue pairs, excluding the
        Passphrase key itself.

        Designed for use in standalone collector/processor scripts that dot-source
        xFACts-OrchestratorFunctions.ps1. Requires Initialize-XFActsScript to have
        been called first (uses Get-SqlData for database access).

        This is the standard credential retrieval pattern for all standalone scripts.
        The equivalent function in xFACts-Helpers.psm1 serves the same purpose for
        Pode-hosted Control Center routes.

    .PARAMETER ServiceName
        The service identifier in dbo.Credentials (e.g., 'JBossManagement', 'Jira', 'SFTP').

    .PARAMETER Environment
        Environment filter. Defaults to 'PROD'.

    .RETURNS
        Hashtable of decrypted ConfigKey = value pairs.
        Example: @{ JBossUser = 'admin'; JBossPassword = 'secret123' }

    .EXAMPLE
        $creds = Get-ServiceCredentials -ServiceName 'JBossManagement'
        $username = $creds.JBossUser
        $password = $creds.JBossPassword

    .EXAMPLE
        $sftpCreds = Get-ServiceCredentials -ServiceName 'SFTP_Vendor'
        $sftpCreds.Username  # decrypted username
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ServiceName,

        [string]$Environment = 'PROD'
    )

    # Step 1: Retrieve master passphrase from GlobalConfig
    $masterResult = Get-SqlData -Query @"
SELECT setting_value
FROM dbo.GlobalConfig
WHERE module_name = 'Shared'
  AND category = 'Credentials'
  AND setting_name = 'master_passphrase'
  AND is_active = 1
"@

    if ($null -eq $masterResult -or [string]::IsNullOrEmpty($masterResult.setting_value)) {
        Write-Log "Master passphrase not found in GlobalConfig (Shared.Credentials.master_passphrase)" "ERROR"
        return $null
    }

    $masterPass = $masterResult.setting_value

    # Step 2: Decrypt service passphrase, then decrypt all config keys
    # Passphrases are concatenated into the query (not parameterized) because
    # DECRYPTBYPASSPHRASE requires literal string values. This mirrors the
    # proven pattern across all xFACts credential retrieval.
    $escapedMasterPass = $masterPass -replace "'", "''"
    $escapedServiceName = $ServiceName -replace "'", "''"
    $escapedEnvironment = $Environment -replace "'", "''"

    $decryptQuery = @"
DECLARE @MasterPassphrase VARCHAR(100) = '$escapedMasterPass';
DECLARE @ServicePassphrase VARCHAR(100);

SELECT @ServicePassphrase = CAST(DECRYPTBYPASSPHRASE(@MasterPassphrase, ConfigValue) AS VARCHAR(100))
FROM dbo.Credentials
WHERE Environment = '$escapedEnvironment'
  AND ServiceName = '$escapedServiceName'
  AND ConfigKey = 'Passphrase';

IF @ServicePassphrase IS NULL
BEGIN
    RAISERROR('Service passphrase not found or decryption failed for service: %s', 16, 1, '$escapedServiceName');
    RETURN;
END

SELECT
    ConfigKey,
    CAST(DECRYPTBYPASSPHRASE(@ServicePassphrase, ConfigValue) AS VARCHAR(500)) AS DecryptedValue
FROM dbo.Credentials
WHERE Environment = '$escapedEnvironment'
  AND ServiceName = '$escapedServiceName'
  AND ConfigKey <> 'Passphrase';
"@

    $results = Get-SqlData -Query $decryptQuery
    if ($null -eq $results) {
        Write-Log "No credentials found for service '$ServiceName' in environment '$Environment'" "ERROR"
        return $null
    }

    # Build hashtable of key/value pairs
    $credentials = @{}
    foreach ($row in @($results)) {
        if ([string]::IsNullOrEmpty($row.DecryptedValue)) {
            Write-Log "Decryption failed for ${ServiceName}.$($row.ConfigKey) - check passphrase chain" "ERROR"
            return $null
        }
        $credentials[$row.ConfigKey] = $row.DecryptedValue
    }

    Write-Log "Credentials retrieved for service '$ServiceName' ($($credentials.Count) keys)" "SUCCESS"
    return $credentials
}

# ============================================================================
# TASK COMPLETION CALLBACK
# ============================================================================

function Complete-OrchestratorTask {
    <#
    .SYNOPSIS
        Updates Orchestrator TaskLog and ProcessRegistry with final execution status.
        Called by fire-and-forget scripts at the end of their execution.

    .DESCRIPTION
        When the Orchestrator engine launches a script in FIRE_AND_FORGET mode,
        it passes a TaskId and ProcessId. The script calls this function before
        exiting to report its completion status back to the orchestrator tables.

        Updates two tables:
        - Orchestrator.TaskLog: end_dttm, duration_ms, task_status, output/error
        - Orchestrator.ProcessRegistry: running_count decremented, last_execution_status, last_duration_ms

        If the function fails (database connectivity issue, etc.), it writes to 
        the console but does not throw - the script should not fail because of 
        a callback error.

    .PARAMETER ServerInstance
        SQL Server instance. Optional -- defaults to the value set by Initialize-XFActsScript.
        Retained for backward compatibility with existing scripts.

    .PARAMETER Database
        Database name. Optional -- defaults to the value set by Initialize-XFActsScript.
        Retained for backward compatibility with existing scripts.

    .PARAMETER TaskId
        TaskLog ID passed by the orchestrator engine at launch.

    .PARAMETER ProcessId
        ProcessRegistry ID for this process.

    .PARAMETER Status
        Final execution status: SUCCESS, FAILED, POLLING, or NOT_STARTED.

    .PARAMETER DurationMs
        Total execution duration in milliseconds.

    .PARAMETER Output
        Optional stdout summary (truncated to 4000 chars).

    .PARAMETER ErrorMessage
        Optional stderr or error detail (truncated to 4000 chars).

    .EXAMPLE
        # New pattern (after Initialize-XFActsScript):
        if ($TaskId -and $TaskId -gt 0) {
            Complete-OrchestratorTask -TaskId $TaskId -ProcessId $ProcessId `
                -Status "SUCCESS" -DurationMs $totalMs `
                -Output "Processed 15 records"
        }

    .EXAMPLE
        # Legacy pattern (still supported):
        if ($TaskId -and $TaskId -gt 0) {
            Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
                -TaskId $TaskId -ProcessId $ProcessId `
                -Status "SUCCESS" -DurationMs $totalMs
        }
    #>
    param(
        [string]$ServerInstance,
        [string]$Database,

        [Parameter(Mandatory)]
        [long]$TaskId,

        [Parameter(Mandatory)]
        [int]$ProcessId,

        [Parameter(Mandatory)]
        [ValidateSet("SUCCESS","FAILED","POLLING","NOT_STARTED")]
        [string]$Status,

        [Parameter(Mandatory)]
        [int]$DurationMs,

        [string]$Output = "",
        [string]$ErrorMessage = ""
    )

    try {
        # Resolve connection: explicit param > Initialize context > hardcoded default
        $instance = if ($ServerInstance) { $ServerInstance } elseif ($script:XFActsServerInstance) { $script:XFActsServerInstance } else { "AVG-PROD-LSNR" }
        $db       = if ($Database) { $Database } elseif ($script:XFActsDatabase) { $script:XFActsDatabase } else { "xFACts" }
        $appName  = if ($script:XFActsAppName) { $script:XFActsAppName } else { "xFACts OrchestratorFunctions" }

        # Sanitize and truncate strings for SQL
        $outputSafe = ($Output -replace "'", "''")
        if ($outputSafe.Length -gt 4000) { $outputSafe = $outputSafe.Substring(0, 4000) }
        
        $errorSafe = ($ErrorMessage -replace "'", "''")
        if ($errorSafe.Length -gt 4000) { $errorSafe = $errorSafe.Substring(0, 4000) }

        $exitCode = if ($Status -eq "SUCCESS") { 0 } else { 1 }

        # Build optional clauses
        $outputClause = if ($Output) { ", output_summary = '$outputSafe'" } else { "" }
        $errorClause = if ($ErrorMessage) { ", error_output = '$errorSafe'" } else { "" }

        # Update TaskLog with final status
        $taskQuery = @"
            UPDATE Orchestrator.TaskLog
            SET end_dttm = GETDATE(),
                duration_ms = $DurationMs,
                task_status = '$Status',
                exit_code = $exitCode
                $outputClause
                $errorClause
            WHERE task_id = $TaskId
"@
        Invoke-Sqlcmd -ServerInstance $instance -Database $db `
            -Query $taskQuery -QueryTimeout 15 -ApplicationName $appName `
            -ErrorAction Stop -TrustServerCertificate

        # Update ProcessRegistry - decrement running count and record result
        # Only update status fields when this is the last active instance.
        # This keeps the engine card blue while any instance is still running.
        $successDateClause = if ($Status -eq "SUCCESS") {
            ", last_successful_date = CASE WHEN running_count <= 1 THEN CAST(GETDATE() AS DATE) ELSE last_successful_date END"
        } else { "" }

        $regQuery = @"
            UPDATE Orchestrator.ProcessRegistry
            SET running_count = CASE WHEN running_count > 0 THEN running_count - 1 ELSE 0 END,
                last_execution_status = CASE 
                    WHEN running_count <= 1 THEN '$Status'
                    ELSE last_execution_status
                END,
                last_duration_ms = CASE 
                    WHEN running_count <= 1 THEN $DurationMs
                    ELSE last_duration_ms
                END,
                modified_dttm = GETDATE(),
                modified_by = SUSER_SNAME()
                $successDateClause
            OUTPUT DELETED.running_count AS prev_count, 
            INSERTED.running_count AS new_count
            WHERE process_id = $ProcessId
"@
        $regResult = Invoke-Sqlcmd -ServerInstance $instance -Database $db `
            -Query $regQuery -QueryTimeout 15 -ApplicationName $appName `
            -ErrorAction Stop -TrustServerCertificate

        # Only push COMPLETED event when the last instance finishes.
        # While other instances are still active, the engine card stays blue/RUNNING.
        $prevCount = if ($regResult) { $regResult.prev_count } else { 0 }
        $newCount = if ($regResult) { $regResult.new_count } else { 0 }

        # Skip if orchestrator already decremented (WAIT mode) -- prev was already 0
        # Send only when we're the last instance to finish -- new reaches 0
        if ($prevCount -gt 0 -and $newCount -eq 0) {
            $procMeta = Invoke-Sqlcmd -ServerInstance $instance -Database $db `
                -Query "SELECT process_name, module_name, interval_seconds, CONVERT(VARCHAR(8), scheduled_time, 108) AS scheduled_time, run_mode FROM Orchestrator.ProcessRegistry WHERE process_id = $ProcessId" `
                -QueryTimeout 10 -ApplicationName $appName `
                -ErrorAction Stop -TrustServerCertificate

            if ($procMeta) {
                $schedTime = if ($procMeta.scheduled_time -and $procMeta.scheduled_time -ne [DBNull]::Value) { 
                    $procMeta.scheduled_time 
                } else { "" }

                Send-EngineEvent -EventType "PROCESS_COMPLETED" `
                    -ProcessId $ProcessId `
                    -ProcessName $procMeta.process_name `
                    -ModuleName $procMeta.module_name `
                    -TaskId $TaskId `
                    -Status $Status `
                    -DurationMs $DurationMs `
                    -ExitCode $exitCode `
                    -OutputSummary $Output `
                    -IntervalSeconds $procMeta.interval_seconds `
                    -ScheduledTime $schedTime `
                    -RunMode $procMeta.run_mode
            }
        }
    }
    catch {
        # Log but do not throw - callback failure should not crash the calling script
        Write-Host "[WARN] Orchestrator callback failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Send-EngineEvent {
    <#
    .SYNOPSIS
        Posts an engine event to the Control Center for real-time WebSocket broadcast.

    .DESCRIPTION
        Fire-and-forget HTTP POST to the Control Center's internal engine-event
        endpoint. The CC stores the event in shared state and broadcasts it to
        all connected browsers via WebSocket.

        This function must NEVER throw or block. If the Control Center is
        unreachable, the event is silently dropped. The orchestrator engine
        and managed scripts must never be dependent on the Control Center.

    .PARAMETER EventType
        PROCESS_STARTED or PROCESS_COMPLETED.

    .PARAMETER ProcessId
        ProcessRegistry process_id.

    .PARAMETER ProcessName
        ProcessRegistry process_name.

    .PARAMETER ModuleName
        ProcessRegistry module_name.

    .PARAMETER TaskId
        TaskLog task_id for this execution.

    .PARAMETER Status
        Execution status (for COMPLETED events): SUCCESS, FAILED, TIMEOUT, LAUNCHED.

    .PARAMETER DurationMs
        Execution duration in milliseconds (for COMPLETED events).

    .PARAMETER ExitCode
        Process exit code (for COMPLETED events).

    .PARAMETER OutputSummary
        Truncated stdout summary (for COMPLETED events).
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet("PROCESS_STARTED","PROCESS_COMPLETED")]
        [string]$EventType,

        [Parameter(Mandatory)]
        [int]$ProcessId,

        [Parameter(Mandatory)]
        [string]$ProcessName,

        [Parameter(Mandatory)]
        [string]$ModuleName,

        [long]$TaskId = 0,
        [string]$Status = "",
        [int]$DurationMs = 0,
        [int]$ExitCode = 0,
        [string]$OutputSummary = "",
        [int]$IntervalSeconds = 0,
        [string]$ScheduledTime = "",
        [int]$RunMode = 1
    )

    try {
        $payload = @{
            eventType     = $EventType
            processId     = $ProcessId
            processName   = $ProcessName
            moduleName    = $ModuleName
            taskId        = $TaskId
            timestamp     = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
            status        = $Status
            durationMs    = $DurationMs
            exitCode      = $ExitCode
            outputSummary = $OutputSummary
            intervalSeconds = $IntervalSeconds
            scheduledTime   = $ScheduledTime
            runMode         = $RunMode
        } | ConvertTo-Json -Compress

        Invoke-WebRequest -Uri 'http://localhost:8085/api/internal/engine-event' `
            -Method Post `
            -Body $payload `
            -ContentType 'application/json' `
            -UseBasicParsing `
            -TimeoutSec 3 | Out-Null
    }
    catch {
        # Silent drop - Control Center availability must never affect engine operations
    }
}

function Send-TeamsAlert {
    <#
    .SYNOPSIS
        Queues a Teams alert with mandatory deduplication.

    .DESCRIPTION
        Inserts a row into Teams.AlertQueue for delivery by Process-TeamsAlertQueue.
        Always checks Teams.RequestLog for an existing successfully-sent alert with 
        the same TriggerType + TriggerValue before inserting. If a match is found,
        the alert is skipped and a log message is written.

        Dedup is mandatory — there is no opt-out. Callers that need a repeating 
        alert should pass a unique TriggerValue each time (e.g., include a timestamp 
        or cycle identifier).

    .PARAMETER SourceModule
        The owning module (e.g., 'ServerOps', 'BatchOps').

    .PARAMETER AlertCategory
        Severity level: 'CRITICAL', 'WARNING', or 'INFO'.

    .PARAMETER Title
        Alert card title. Supports Teams markdown (e.g., {{FIRE}} for emoji).

    .PARAMETER Message
        Alert card body. Supports Teams markdown formatting.

    .PARAMETER Color
        Teams card accent color. Default: 'attention' (red/orange).
        Options: 'default', 'dark', 'light', 'accent', 'good', 'warning', 'attention'.

    .PARAMETER TriggerType
        Dedup key part 1: identifies the alert condition (e.g., 'NETWORK_COPY_EXHAUSTED').

    .PARAMETER TriggerValue
        Dedup key part 2: identifies the specific instance (e.g., tracking_id, batch_id).

    .OUTPUTS
        [bool] $true if alert was queued, $false if skipped (dedup) or failed.

    .EXAMPLE
        Send-TeamsAlert -SourceModule 'ServerOps' -AlertCategory 'CRITICAL' `
            -Title '{{FIRE}} Backup Network Copy Failed' `
            -Message "**File:** bigdb_full.sqb`n**Error:** Network timeout after 3 attempts" `
            -TriggerType 'NETWORK_COPY_EXHAUSTED' -TriggerValue '572438'
    #>
    param(
        [Parameter(Mandatory)]
        [string]$SourceModule,

        [Parameter(Mandatory)]
        [ValidateSet("CRITICAL","WARNING","INFO")]
        [string]$AlertCategory,

        [Parameter(Mandatory)]
        [string]$Title,

        [Parameter(Mandatory)]
        [string]$Message,

        [string]$Color = 'attention',

        [Parameter(Mandatory)]
        [string]$TriggerType,

        [Parameter(Mandatory)]
        [string]$TriggerValue
    )

    try {
        # Dedup check: has this alert already been successfully sent?
        $triggerTypeSafe = $TriggerType -replace "'", "''"
        $triggerValueSafe = $TriggerValue -replace "'", "''"

        $dedupResult = Get-SqlData -Query @"
SELECT TOP 1 1 AS alert_exists
FROM Teams.RequestLog
WHERE trigger_type = '$triggerTypeSafe'
  AND trigger_value = '$triggerValueSafe'
  AND status_code = 200
"@

        if ($dedupResult) {
            Write-Log "  Teams alert skipped (dedup): $TriggerType/$TriggerValue" "INFO"
            return $false
        }

        # Queue the alert
        $titleSafe = $Title -replace "'", "''"
        $messageSafe = $Message -replace "'", "''"

        $insertQuery = @"
INSERT INTO Teams.AlertQueue (
    source_module, alert_category, title, message, color,
    trigger_type, trigger_value, status, created_dttm
)
VALUES (
    '$SourceModule', '$AlertCategory', N'$titleSafe',
    N'$messageSafe', '$Color',
    '$triggerTypeSafe', '$triggerValueSafe',
    'Pending', GETDATE()
)
"@

        $result = Invoke-SqlNonQuery -Query $insertQuery
        if ($result) {
            Write-Log "  Teams alert queued: $TriggerType/$TriggerValue" "SUCCESS"
            return $true
        }
        else {
            Write-Log "  Teams alert queue INSERT failed: $TriggerType/$TriggerValue" "ERROR"
            return $false
        }
    }
    catch {
        Write-Log "  Teams alert failed: $($_.Exception.Message)" "ERROR"
        return $false
    }
}
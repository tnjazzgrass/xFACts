<#
.SYNOPSIS
    Shared orchestrator and script-infrastructure functions for the xFACts platform.

.DESCRIPTION
    Common functions dot-sourced by every script running under the xFACts
    platform: standardized script initialization, durable and ephemeral
    logging, SQL data access with automatic application-name tagging,
    credential retrieval, the orchestrator task-completion callback, real-time
    engine-event push, and Teams alert queuing with mandatory deduplication.
    Dot-source this file at the top of a script with
    . "$PSScriptRoot\xFACts-OrchestratorFunctions.ps1" and then call
    Initialize-XFActsScript before any other shared function.

.COMPONENT
    Engine.Orchestrator

.NOTES
    File Name : xFACts-OrchestratorFunctions.ps1
    Location  : E:\xFACts-PowerShell\xFACts-OrchestratorFunctions.ps1

    FILE ORGANIZATION
    -----------------
    CHANGELOG: CHANGE HISTORY
    VARIABLES: SCRIPT CONTEXT
    FUNCTIONS: SCRIPT INITIALIZATION
    FUNCTIONS: LOGGING AND CONSOLE OUTPUT
    FUNCTIONS: SQL DATA ACCESS
    FUNCTIONS: AVAILABILITY GROUP
    FUNCTIONS: CREDENTIAL RETRIEVAL
    FUNCTIONS: TASK COMPLETION CALLBACK
    FUNCTIONS: ENGINE EVENT PUSH
    FUNCTIONS: TEAMS ALERTING
#>

<# ============================================================================
   CHANGELOG: CHANGE HISTORY
   ----------------------------------------------------------------------------
   Dated change history for this file, most recent first. Authoritative
   version tracking lives in dbo.System_Metadata (component
   Engine.Orchestrator); this section records what changed and when.
   Prefix: (none)
   ============================================================================ #>

# 2026-06-19  Added Get-SourceData (FUNCTIONS: SQL DATA ACCESS), the shared
#             source-database read wrapper. Takes -ReadServer and -SourceDB
#             explicitly rather than reading caller script-scope state. Lifted
#             from a per-script local copy in Monitor-JobFlow; the BS-review
#             collectors still carry their own copies pending their refactors.
#             Added Get-SqlInstanceName (FUNCTIONS: SQL DATA ACCESS), the
#             server-plus-optional-instance connection-target builder. Lifted
#             from a per-script local copy in Collect-BackupStatus into one
#             shared definition; the ServerHealth-zone collectors still carry
#             their own copies pending their refactors.
# 2026-06-18  Added Get-AGReplicaRoles (FUNCTIONS: AVAILABILITY GROUP), the
#             parameterized resolver of an availability group's current
#             PRIMARY and SECONDARY replica servers. Lifted from eight
#             duplicate per-component copies (BatchOps, BS-review, JobFlow,
#             DBCC) into one shared definition; takes -AGName explicitly
#             rather than reading a caller's script-scoped Config.
# 2026-06-15  Added the sanctioned console-output helper family - Write-Console,
#             Write-ConsoleBanner, Write-ConsoleRule - the blessed replacement
#             for Write-Host (ephemeral, colored, operator-facing console
#             output) alongside the durable Write-Log lane.
# 2026-04-28  Added optional -CardJson parameter to Send-TeamsAlert for Adaptive
#             Card payloads. Title/Message/Color remain required for the
#             plain-text audit trail and fallback. Mandatory dedup against
#             Teams.RequestLog preserved.
# 2026-04-23  Added optional -MaxBinaryLength parameter to Get-SqlData and
#             Invoke-SqlNonQuery, parallel to -MaxCharLength. Passes through to
#             Invoke-Sqlcmd when specified; required for VARBINARY(MAX) reads
#             exceeding the 1024-byte default, which otherwise truncate silently.
# 2026-03-17  Added Send-TeamsAlert shared function for Teams alert queuing with
#             mandatory dedup against Teams.RequestLog. Replaces the inline
#             INSERT pattern; available to all dot-sourced scripts.
# 2026-03-10  Added optional -MaxCharLength parameter to Get-SqlData and
#             Invoke-SqlNonQuery and refactored both to splatting. Engine-event
#             timestamps now emitted UTC with Z suffix for timezone-agnostic
#             countdown calculations.
# 2026-02-27  Concurrent-execution handling in Complete-OrchestratorTask:
#             ProcessRegistry status updates only when running_count reaches
#             zero, preventing premature SUCCESS on parallel fire-and-forget
#             processes.
# 2026-02-25  Added Send-EngineEvent: fire-and-forget HTTP POST to the Control
#             Center internal engine-event endpoint. Pushed on process launch,
#             WAIT completion, and fire-and-forget callback completion.
# 2026-02-20  Shared script infrastructure: Initialize-XFActsScript (SQL module
#             loading, application identity, log path, Execute guard), Write-Log,
#             Get-SqlData, Invoke-SqlNonQuery. Complete-OrchestratorTask
#             refactored for context-based connection defaults with
#             backward-compatible explicit parameters.
# 2026-02-04  Complete-OrchestratorTask updated to decrement running_count with
#             floor protection at zero, replacing the is_running reset, for
#             concurrent execution tracking.
# 2026-02-03  Initial implementation: Complete-OrchestratorTask callback for
#             fire-and-forget scripts.

<# ============================================================================
   VARIABLES: SCRIPT CONTEXT
   ----------------------------------------------------------------------------
   Script-scope context populated by Initialize-XFActsScript and read by the
   shared functions throughout the dot-sourcing script: script name,
   application identity, log-file path, default connection target, and the
   Execute-mode flag.
   Prefix: (none)
   ============================================================================ #>

# Calling script name without extension, e.g. 'Collect-BackupStatus'.
$script:XFActsScriptName     = $null
# Application name for DMV/XE attribution, e.g. 'xFACts Collect-BackupStatus'.
$script:XFActsAppName        = $null
# Daily log-file path for this script, set from the script name and date.
$script:XFActsLogFile        = $null
# Default SQL Server instance for Get-SqlData / Invoke-SqlNonQuery calls.
$script:XFActsServerInstance = $null
# Default database for Get-SqlData / Invoke-SqlNonQuery calls.
$script:XFActsDatabase       = $null
# Whether the calling script was launched with -Execute (vs preview mode).
$script:XFActsExecute        = $false

<# ============================================================================
   FUNCTIONS: SCRIPT INITIALIZATION
   ----------------------------------------------------------------------------
   Standardized startup for every xFACts script: SQL module loading, working
   directory, application identity, log path, default connection target, and
   the preview-mode execute guard. Called once immediately after dot-sourcing.
   Prefix: (none)
   ============================================================================ #>

function Initialize-XFActsScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ScriptName,

        [string]$ServerInstance = "AVG-PROD-LSNR",
        [string]$Database = "xFACts",
        [bool]$Execute = $false
    )

    <#
    .SYNOPSIS
        Standardized initialization for all xFACts scripts.

    .DESCRIPTION
        Performs the common startup tasks every xFACts script requires: loads
        the SqlServer module (falling back to SQLPS), sets the working directory
        to the script root, configures the application identity used for DMV/XE
        attribution, sets up the daily log-file path, stores the default
        connection parameters used by Get-SqlData and Invoke-SqlNonQuery, and
        displays the preview-mode guard message when -Execute was not supplied.
        Call this once at the top of every script, immediately after
        dot-sourcing this file.

    .PARAMETER ScriptName
        Name of the calling script without the .ps1 extension. Used for
        application-name tagging, log-file naming, and console output.

    .PARAMETER ServerInstance
        Default SQL Server instance for database calls. Individual calls can
        override it via their own -Instance parameter.

    .PARAMETER Database
        Default database name. Individual calls can override it via their own
        -DatabaseName parameter.

    .PARAMETER Execute
        The calling script's -Execute switch value. When false (the default),
        a standardized preview-mode warning is displayed.
    #>

    $script:XFActsScriptName     = $ScriptName
    $script:XFActsAppName        = "xFACts $ScriptName"
    $script:XFActsLogFile        = "$PSScriptRoot\Logs\${ScriptName}_$(Get-Date -Format 'yyyyMMdd').log"
    $script:XFActsServerInstance = $ServerInstance
    $script:XFActsDatabase       = $Database
    $script:XFActsExecute        = $Execute

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
        Write-Console "ERROR: No SQL module could be loaded (tried SqlServer and SQLPS)." 'Red'
        Write-Console "Install SqlServer module with: Install-Module SqlServer" 'Yellow'
        exit 1
    }

    # Ensure we're on a filesystem provider (SQLPS changes to SQLSERVER:\).
    Set-Location $PSScriptRoot

    if (-not $Execute) {
        Write-Console "*** PREVIEW MODE - No changes will be made. Use -Execute to run. ***" 'Yellow'
    }
}

<# ============================================================================
   FUNCTIONS: LOGGING AND CONSOLE OUTPUT
   ----------------------------------------------------------------------------
   Durable and ephemeral operator output. Write-Log writes the timestamped,
   level-tagged record to console and the daily log file. The Write-Console
   family is the sanctioned, ephemeral console lane and the only permitted
   home for Write-Host on the platform.
   Prefix: (none)
   ============================================================================ #>

function Write-Log {
    [CmdletBinding()]
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    <#
    .SYNOPSIS
        Writes a timestamped log entry to the console and the daily log file.

    .DESCRIPTION
        The durable logging lane for all xFACts scripts. Writes a timestamped,
        level-tagged line to the console (color-coded by level via Write-Console)
        and appends the same line to the daily log file configured by
        Initialize-XFActsScript. The log directory is created automatically if
        it does not yet exist.

    .PARAMETER Message
        The log message text.

    .PARAMETER Level
        Severity level: INFO (default), WARN, ERROR, SUCCESS, or DEBUG.
    #>

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"

    $color = switch ($Level) {
        "ERROR"   { "Red" }
        "WARN"    { "Yellow" }
        "SUCCESS" { "Green" }
        "DEBUG"   { "DarkGray" }
        default   { "White" }
    }
    Write-Console $logMessage $color

    if ($script:XFActsLogFile) {
        $logDir = Split-Path $script:XFActsLogFile -Parent
        if (-not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        Add-Content -Path $script:XFActsLogFile -Value $logMessage -ErrorAction SilentlyContinue
    }
}

function Write-Console {
    [CmdletBinding()]
    param(
        [string]$Message = '',
        [string]$Color = 'Gray',
        [switch]$NoNewline
    )

    <#
    .SYNOPSIS
        Writes a line to the console. Sanctioned replacement for Write-Host.

    .DESCRIPTION
        A faithful Write-Host stand-in for operator-facing console narration in
        manually-run scripts. Unlike Write-Log it does not timestamp, tag a
        level, or write to the log file - it is purely ephemeral console output.
        Use Write-Log for anything that belongs in the durable record.

    .PARAMETER Message
        The text to print. Defaults to empty (a blank spacer line).

    .PARAMETER Color
        Console foreground color. Defaults to Gray.

    .PARAMETER NoNewline
        Suppresses the trailing newline so a later call continues the same line
        (used for "Parsing X ..." then " ok" on one line).
    #>

    if ($NoNewline) {
        Write-Host $Message -ForegroundColor $Color -NoNewline
    }
    else {
        Write-Host $Message -ForegroundColor $Color
    }
}

function Write-ConsoleBanner {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Label,
        [string]$Color = 'Cyan',
        [ValidateSet('=', '-')]
        [string]$RuleChar = '='
    )

    <#
    .SYNOPSIS
        Writes a standard framed banner block to the console.

    .DESCRIPTION
        Emits the platform-standard console banner used to announce a phase or
        step during a manually-run script: a rule line, an indented label, a
        matching rule line, and a trailing blank. The frame is fixed here so
        every banner looks identical; callers supply the label and optionally a
        color and rule character. The default '=' rule denotes a major phase;
        passing '-' denotes a minor step, preserving a visual hierarchy. Rule
        width matches the structural section-banner width used platform-wide.

    .PARAMETER Label
        The banner text (e.g., "Session Summary").

    .PARAMETER Color
        Console foreground color for the whole block. Defaults to Cyan.

    .PARAMETER RuleChar
        The character used for the top and bottom rule lines. Defaults to '='
        (major phase). Pass '-' for a minor step divider.
    #>

    $rule = $RuleChar * 76
    Write-Console ''              $Color
    Write-Console $rule           $Color
    Write-Console ("  " + $Label) $Color
    Write-Console $rule           $Color
    Write-Console ''              $Color
}

function Write-ConsoleRule {
    [CmdletBinding()]
    param(
        [string]$Color = 'DarkGray'
    )

    <#
    .SYNOPSIS
        Writes a single horizontal rule line to the console.

    .DESCRIPTION
        Emits one platform-standard separator rule, used to divide sections of
        console output where a full banner would be too heavy. Width matches
        Write-ConsoleBanner for visual consistency.

    .PARAMETER Color
        Console foreground color. Defaults to DarkGray.
    #>

    Write-Console ('-' * 76) $Color
}

<# ============================================================================
   FUNCTIONS: SQL DATA ACCESS
   ----------------------------------------------------------------------------
   Read and non-query SQL access wrapping Invoke-Sqlcmd. Both apply the
   script's application identity for DMV/XE attribution, default to the
   connection target set by Initialize-XFActsScript, and support large
   character and binary result columns.
   Prefix: (none)
   ============================================================================ #>

function Get-SqlInstanceName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ServerName,

        [string]$InstanceName
    )

    <#
    .SYNOPSIS
        Builds a SQL Server instance connection target from a server name and optional instance name.

    .DESCRIPTION
        Composes the instance connection string used to reach a specific SQL
        Server: returns the bare server name for a default instance, or the
        Server\Instance form when a named instance is supplied. A blank or
        whitespace-only instance name is treated as a default instance. Used by
        scripts that iterate registered servers and must address each instance
        by its connection target.

    .PARAMETER ServerName
        The SQL Server host name.

    .PARAMETER InstanceName
        The named-instance name, or empty/whitespace for a default instance.
    #>

    if ([string]::IsNullOrWhiteSpace($InstanceName)) {
        return $ServerName
    }
    else {
        return "$ServerName\$InstanceName"
    }
}

function Get-SourceData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Query,

        [Parameter(Mandatory)]
        [string]$ReadServer,

        [Parameter(Mandatory)]
        [string]$SourceDB,

        [int]$Timeout = 60
    )

    <#
    .SYNOPSIS
        Executes a read query against a source database on a specific replica server.

    .DESCRIPTION
        Wrapper around Invoke-Sqlcmd for read queries against a source database
        (e.g., crs5_oltp) on an explicitly supplied replica server, used by the
        collect/monitor scripts that read Debt Manager data from a chosen AG
        replica rather than the default xFACts connection target. Applies the
        script's application identity for DMV/XE attribution and the standard
        Invoke-Sqlcmd flags (-SuppressProviderContextWarning,
        -TrustServerCertificate). Returns the result set on success and $null on
        failure, logging the error. The read server and source database are
        passed explicitly so the function carries no dependency on caller
        script-scope state.

    .PARAMETER Query
        The SQL query to execute.

    .PARAMETER ReadServer
        The SQL Server instance to read from, typically the AG replica resolved
        by Get-AGReplicaRoles for the caller's configured SourceReplica role.

    .PARAMETER SourceDB
        The source database name to query (e.g., crs5_oltp).

    .PARAMETER Timeout
        Query timeout in seconds. Default: 60.
    #>

    if (-not $ReadServer) {
        Write-Log "ReadServer not configured - cannot query source" "ERROR"
        return $null
    }

    try {
        Invoke-Sqlcmd -ServerInstance $ReadServer -Database $SourceDB -Query $Query `
            -QueryTimeout $Timeout -ApplicationName $script:XFActsAppName `
            -ErrorAction Stop -SuppressProviderContextWarning -TrustServerCertificate
    }
    catch {
        Write-Log "Source query failed on ${ReadServer}: $($_.Exception.Message)" "ERROR"
        return $null
    }
}

function Get-SqlData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Query,

        [string]$Instance = $script:XFActsServerInstance,
        [string]$DatabaseName = $script:XFActsDatabase,
        [int]$Timeout = 300,
        [int]$MaxCharLength = 0,
        [int]$MaxBinaryLength = 0,
        [hashtable]$Parameters = @{}
    )

    <#
    .SYNOPSIS
        Executes a SQL query and returns the result set.

    .DESCRIPTION
        Wrapper around Invoke-Sqlcmd for read queries. Automatically applies the
        application name from Initialize-XFActsScript context, the default
        server instance and database (overridable per call), a configurable
        query timeout, and the standard Invoke-Sqlcmd flags
        (-SuppressProviderContextWarning, -TrustServerCertificate). Returns the
        result set on success and $null on failure, logging the error.

    .PARAMETER Query
        The SQL query to execute.

    .PARAMETER Instance
        SQL Server instance. Defaults to the value set in Initialize-XFActsScript.

    .PARAMETER DatabaseName
        Database name. Defaults to the value set in Initialize-XFActsScript.

    .PARAMETER Timeout
        Query timeout in seconds. Default: 300.

    .PARAMETER MaxCharLength
        Maximum character length for string columns. When greater than zero,
        passed to Invoke-Sqlcmd -MaxCharLength. Required for queries returning
        large XML or text data (XE sessions, DMV XML plans, replication XML).
        When omitted, Invoke-Sqlcmd uses its default of 4000.

    .PARAMETER MaxBinaryLength
        Maximum byte length for VARBINARY columns. When greater than zero,
        passed to Invoke-Sqlcmd -MaxBinaryLength. Required for queries returning
        large binary blobs (Sterling b2bi compressed XML, etc.). When omitted,
        Invoke-Sqlcmd uses its default of 1024, which silently truncates larger
        blobs mid-stream. Always specify this for any VARBINARY(MAX) column.

    .PARAMETER Parameters
        Hashtable of SQL parameter values for parameterized queries. When
        non-empty, the query runs through a System.Data.SqlClient.SqlCommand
        and each hashtable entry binds as a typed @parameter (the key is
        prefixed with @, $null becomes DBNull), so values are bound by the
        driver instead of being concatenated into the query text. When omitted,
        the query runs through Invoke-Sqlcmd with no parameter bindings. Note:
        MaxCharLength and MaxBinaryLength apply only to the non-parameterized
        path; the parameterized path honors Timeout via CommandTimeout.
    #>

    # Parameterized path: bind values as real SqlCommand parameters.
    if ($Parameters.Count -gt 0) {
        $connStr = "Server=$Instance;Database=$DatabaseName;Integrated Security=True;TrustServerCertificate=True;Application Name=$($script:XFActsAppName)"
        $connection = $null
        try {
            $connection = New-Object System.Data.SqlClient.SqlConnection($connStr)
            $connection.Open()

            $command = $connection.CreateCommand()
            $command.CommandText = $Query
            $command.CommandTimeout = $Timeout
            foreach ($key in $Parameters.Keys) {
                $value = $Parameters[$key]
                if ($null -eq $value) { $value = [System.DBNull]::Value }
                $command.Parameters.AddWithValue("@$key", $value) | Out-Null
            }

            $table = New-Object System.Data.DataTable
            $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($command)
            $adapter.Fill($table) | Out-Null
            return $table.Rows
        }
        catch {
            Write-Log "SQL Query failed on ${Instance}/${DatabaseName}: $($_.Exception.Message)" "ERROR"
            return $null
        }
        finally {
            if ($connection -and $connection.State -eq 'Open') { $connection.Close() }
        }
    }

    # Non-parameterized path: unchanged Invoke-Sqlcmd behavior.
    try {
        # Optional result-size limits, included only when explicitly requested.
        $optional = @{}
        if ($MaxCharLength -gt 0) {
            $optional['MaxCharLength'] = $MaxCharLength
        }
        if ($MaxBinaryLength -gt 0) {
            $optional['MaxBinaryLength'] = $MaxBinaryLength
        }

        Invoke-Sqlcmd -ServerInstance $Instance -Database $DatabaseName -Query $Query `
            -QueryTimeout $Timeout -ApplicationName $script:XFActsAppName `
            -ErrorAction Stop -SuppressProviderContextWarning -TrustServerCertificate `
            @optional
    }
    catch {
        Write-Log "SQL Query failed on ${Instance}/${DatabaseName}: $($_.Exception.Message)" "ERROR"
        return $null
    }
}

function Invoke-SqlNonQuery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Query,

        [string]$Instance = $script:XFActsServerInstance,
        [string]$DatabaseName = $script:XFActsDatabase,
        [int]$Timeout = 300,
        [int]$MaxCharLength = 0,
        [int]$MaxBinaryLength = 0,
        [hashtable]$Parameters = @{}
    )

    <#
    .SYNOPSIS
        Executes a SQL statement that does not return a result set.

    .DESCRIPTION
        Wrapper around Invoke-Sqlcmd for INSERT, UPDATE, DELETE, and other
        non-query operations. Applies the same connection defaults and
        application identity as Get-SqlData. Returns $true on success and
        $false on failure, logging the error.

    .PARAMETER Query
        The SQL statement to execute.

    .PARAMETER Instance
        SQL Server instance. Defaults to the value set in Initialize-XFActsScript.

    .PARAMETER DatabaseName
        Database name. Defaults to the value set in Initialize-XFActsScript.

    .PARAMETER Timeout
        Query timeout in seconds. Default: 300.

    .PARAMETER MaxCharLength
        Maximum character length for string columns. When greater than zero,
        passed to Invoke-Sqlcmd -MaxCharLength. Typically not needed for
        non-query operations but included for parity with Get-SqlData.

    .PARAMETER MaxBinaryLength
        Maximum byte length for VARBINARY columns. When greater than zero,
        passed to Invoke-Sqlcmd -MaxBinaryLength. Typically not needed for
        non-query operations but included for parity with Get-SqlData.

    .PARAMETER Parameters
        Hashtable of SQL parameter values for parameterized statements. When
        non-empty, the statement runs through a System.Data.SqlClient.SqlCommand
        and each hashtable entry binds as a typed @parameter (the key is
        prefixed with @, $null becomes DBNull), so values are bound by the
        driver instead of being concatenated into the statement text. When
        omitted, the statement runs through Invoke-Sqlcmd with no parameter
        bindings. Note: MaxCharLength and MaxBinaryLength apply only to the
        non-parameterized path; the parameterized path honors Timeout via
        CommandTimeout.
    #>

    # Parameterized path: bind values as real SqlCommand parameters.
    if ($Parameters.Count -gt 0) {
        $connStr = "Server=$Instance;Database=$DatabaseName;Integrated Security=True;TrustServerCertificate=True;Application Name=$($script:XFActsAppName)"
        $connection = $null
        try {
            $connection = New-Object System.Data.SqlClient.SqlConnection($connStr)
            $connection.Open()

            $command = $connection.CreateCommand()
            $command.CommandText = $Query
            $command.CommandTimeout = $Timeout
            foreach ($key in $Parameters.Keys) {
                $value = $Parameters[$key]
                if ($null -eq $value) { $value = [System.DBNull]::Value }
                $command.Parameters.AddWithValue("@$key", $value) | Out-Null
            }

            $command.ExecuteNonQuery() | Out-Null
            return $true
        }
        catch {
            Write-Log "SQL Execute failed on ${Instance}/${DatabaseName}: $($_.Exception.Message)" "ERROR"
            return $false
        }
        finally {
            if ($connection -and $connection.State -eq 'Open') { $connection.Close() }
        }
    }

    # Non-parameterized path: unchanged Invoke-Sqlcmd behavior.
    try {
        # Optional result-size limits, included only when explicitly requested.
        $optional = @{}
        if ($MaxCharLength -gt 0) {
            $optional['MaxCharLength'] = $MaxCharLength
        }
        if ($MaxBinaryLength -gt 0) {
            $optional['MaxBinaryLength'] = $MaxBinaryLength
        }

        Invoke-Sqlcmd -ServerInstance $Instance -Database $DatabaseName -Query $Query `
            -QueryTimeout $Timeout -ApplicationName $script:XFActsAppName `
            -ErrorAction Stop -SuppressProviderContextWarning -TrustServerCertificate `
            @optional
        return $true
    }
    catch {
        Write-Log "SQL Execute failed on ${Instance}/${DatabaseName}: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

<# ============================================================================
   FUNCTIONS: AVAILABILITY GROUP
   ----------------------------------------------------------------------------
   Availability-group topology resolution shared across every component that
   must target a specific replica. Get-AGReplicaRoles queries the AG DMVs for
   the named group and returns the current PRIMARY and SECONDARY replica
   server names, so callers can pick a read or write target by role rather
   than by hardcoded server name.
   Prefix: (none)
   ============================================================================ #>

function Get-AGReplicaRoles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$AGName
    )

    <#
    .SYNOPSIS
        Resolves the current PRIMARY and SECONDARY replica servers for an availability group.

    .DESCRIPTION
        Queries the Always On availability-group dynamic management views for
        the named group and returns a hashtable with PRIMARY and SECONDARY
        keys holding the corresponding replica server names. Used by any
        component that selects a read or write target by replica role rather
        than a hardcoded server name. Returns $null when the AGName is empty
        or the replica-state query fails, logging the reason; a role with no
        matching replica is left $null in the returned hashtable.

    .PARAMETER AGName
        Name of the availability group to resolve, as it appears in
        sys.availability_groups.name.
    #>

    if (-not $AGName) {
        Write-Log "AGName not configured - cannot query replica states" "ERROR"
        return $null
    }

    $query = @"
        SELECT
            ar.replica_server_name,
            ars.role_desc
        FROM sys.dm_hadr_availability_replica_states ars
        INNER JOIN sys.availability_replicas ar
            ON ars.replica_id = ar.replica_id
        INNER JOIN sys.availability_groups ag
            ON ar.group_id = ag.group_id
        WHERE ag.name = '$AGName'
"@

    $results = Get-SqlData -Query $query

    if (-not $results) {
        Write-Log "Failed to query AG replica states for $AGName" "ERROR"
        return $null
    }

    $roles = @{
        PRIMARY   = $null
        SECONDARY = $null
    }

    foreach ($row in $results) {
        if ($row.role_desc -eq 'PRIMARY') {
            $roles.PRIMARY = $row.replica_server_name
        }
        elseif ($row.role_desc -eq 'SECONDARY') {
            $roles.SECONDARY = $row.replica_server_name
        }
    }

    return $roles
}

<# ============================================================================
   FUNCTIONS: CREDENTIAL RETRIEVAL
   ----------------------------------------------------------------------------
   Two-tier credential decryption for standalone scripts: the GlobalConfig
   master passphrase decrypts a service passphrase, which in turn decrypts
   the service's credential values. Returns a hashtable of decrypted
   config-key/value pairs.
   Prefix: (none)
   ============================================================================ #>

function Get-ServiceCredentials {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ServiceName,

        [string]$Environment = 'PROD'
    )

    <#
    .SYNOPSIS
        Retrieves decrypted credentials for an external service from dbo.Credentials.

    .DESCRIPTION
        Implements the two-tier decryption model used across the xFACts
        platform: the master passphrase is retrieved from GlobalConfig
        (Shared.Credentials.master_passphrase), the master passphrase decrypts
        the service-level passphrase, and the service passphrase decrypts all
        credential values for the service. Returns a hashtable of
        ConfigKey = DecryptedValue pairs, excluding the Passphrase key itself.
        Designed for standalone scripts that dot-source this file; requires
        Initialize-XFActsScript to have run first, since it uses Get-SqlData.

    .PARAMETER ServiceName
        The service identifier in dbo.Credentials (e.g., 'JBossManagement',
        'Jira', 'SFTP').

    .PARAMETER Environment
        Environment filter. Defaults to 'PROD'.
    #>

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

<# ============================================================================
   FUNCTIONS: TASK COMPLETION CALLBACK
   ----------------------------------------------------------------------------
   The fire-and-forget completion callback. Updates Orchestrator.TaskLog and
   Orchestrator.ProcessRegistry with final status, decrements the running
   count with floor protection, and pushes a PROCESS_COMPLETED engine event
   only when the last concurrent instance finishes.
   Prefix: (none)
   ============================================================================ #>

function Complete-OrchestratorTask {
    [CmdletBinding()]
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

    <#
    .SYNOPSIS
        Reports fire-and-forget completion status to the orchestrator tables.

    .DESCRIPTION
        When the orchestrator launches a script in FIRE_AND_FORGET mode it
        passes a TaskId and ProcessId. The script calls this function before
        exiting to report its completion status. Updates Orchestrator.TaskLog
        (end time, duration, status, exit code, optional output/error) and
        Orchestrator.ProcessRegistry (running_count decremented with floor
        protection; status fields updated only when this is the last active
        instance, keeping the engine card RUNNING while any instance remains).
        When the last instance finishes, pushes a PROCESS_COMPLETED engine
        event. Callback failures are logged but never thrown, so a callback
        error cannot crash the calling script.

    .PARAMETER ServerInstance
        SQL Server instance. Optional; defaults to the value set by
        Initialize-XFActsScript. Retained for backward compatibility.

    .PARAMETER Database
        Database name. Optional; defaults to the value set by
        Initialize-XFActsScript. Retained for backward compatibility.

    .PARAMETER TaskId
        TaskLog id passed by the orchestrator engine at launch.

    .PARAMETER ProcessId
        ProcessRegistry id for this process.

    .PARAMETER Status
        Final execution status: SUCCESS, FAILED, POLLING, or NOT_STARTED.

    .PARAMETER DurationMs
        Total execution duration in milliseconds.

    .PARAMETER Output
        Optional stdout summary (truncated to 4000 characters).

    .PARAMETER ErrorMessage
        Optional stderr or error detail (truncated to 4000 characters).
    #>

    try {
        # Resolve connection: explicit param, then Initialize context, then hardcoded default.
        $instance = if ($ServerInstance) { $ServerInstance } elseif ($script:XFActsServerInstance) { $script:XFActsServerInstance } else { "AVG-PROD-LSNR" }
        $db       = if ($Database) { $Database } elseif ($script:XFActsDatabase) { $script:XFActsDatabase } else { "xFACts" }
        $appName  = if ($script:XFActsAppName) { $script:XFActsAppName } else { "xFACts OrchestratorFunctions" }

        # Sanitize and truncate strings for SQL.
        $outputSafe = ($Output -replace "'", "''")
        if ($outputSafe.Length -gt 4000) { $outputSafe = $outputSafe.Substring(0, 4000) }

        $errorSafe = ($ErrorMessage -replace "'", "''")
        if ($errorSafe.Length -gt 4000) { $errorSafe = $errorSafe.Substring(0, 4000) }

        $exitCode = if ($Status -eq "SUCCESS") { 0 } else { 1 }

        # Build optional clauses.
        $outputClause = if ($Output) { ", output_summary = '$outputSafe'" } else { "" }
        $errorClause = if ($ErrorMessage) { ", error_output = '$errorSafe'" } else { "" }

        # Update TaskLog with final status.
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

        # Update ProcessRegistry: decrement running count and record result.
        # Status fields update only when this is the last active instance, which
        # keeps the engine card blue/RUNNING while any instance is still running.
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

        # Push the COMPLETED event only when the last instance finishes. While
        # other instances are still active, the engine card stays blue/RUNNING.
        $prevCount = if ($regResult) { $regResult.prev_count } else { 0 }
        $newCount = if ($regResult) { $regResult.new_count } else { 0 }

        # Skip if the orchestrator already decremented (WAIT mode) - prev was
        # already 0. Send only when we are the last instance to finish - new
        # reaches 0.
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
        # Log but do not throw - a callback failure must not crash the calling script.
        Write-Console "[WARN] Orchestrator callback failed: $($_.Exception.Message)" 'Yellow'
    }
}

<# ============================================================================
   FUNCTIONS: ENGINE EVENT PUSH
   ----------------------------------------------------------------------------
   Real-time engine-event delivery to the Control Center. A fire-and-forget
   HTTP POST to the internal engine-event endpoint that the CC broadcasts to
   connected browsers over WebSocket. Never throws or blocks: if the CC is
   unreachable the event is silently dropped.
   Prefix: (none)
   ============================================================================ #>

function Send-EngineEvent {
    [CmdletBinding()]
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

    <#
    .SYNOPSIS
        Posts an engine event to the Control Center for real-time broadcast.

    .DESCRIPTION
        Fire-and-forget HTTP POST to the Control Center's internal engine-event
        endpoint. The CC stores the event in shared state and broadcasts it to
        all connected browsers over WebSocket. This function must never throw or
        block: if the Control Center is unreachable the event is silently
        dropped, because the orchestrator engine and managed scripts must never
        depend on Control Center availability.

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
        Execution status for COMPLETED events: SUCCESS, FAILED, TIMEOUT, LAUNCHED.

    .PARAMETER DurationMs
        Execution duration in milliseconds, for COMPLETED events.

    .PARAMETER ExitCode
        Process exit code, for COMPLETED events.

    .PARAMETER OutputSummary
        Truncated stdout summary, for COMPLETED events.

    .PARAMETER IntervalSeconds
        Process schedule interval in seconds, included so the CC countdown uses
        live scheduling values rather than hardcoded defaults.

    .PARAMETER ScheduledTime
        Process scheduled time-of-day string, included for CC countdown display.

    .PARAMETER RunMode
        Process run_mode (0=Disabled, 1=Scheduled, 2=Queue-driven).
    #>

    try {
        $payload = @{
            eventType       = $EventType
            processId       = $ProcessId
            processName     = $ProcessName
            moduleName      = $ModuleName
            taskId          = $TaskId
            timestamp       = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
            status          = $Status
            durationMs      = $DurationMs
            exitCode        = $ExitCode
            outputSummary   = $OutputSummary
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
        # Silent drop - Control Center availability must never affect engine operations.
    }
}

<# ============================================================================
   FUNCTIONS: TEAMS ALERTING
   ----------------------------------------------------------------------------
   Teams alert queuing with mandatory deduplication. Inserts into
   Teams.AlertQueue for delivery, always checking Teams.RequestLog for an
   already-sent alert with the same trigger first. Supports plain-text and
   Adaptive Card payloads.
   Prefix: (none)
   ============================================================================ #>

function Send-TeamsAlert {
    [CmdletBinding()]
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
        [string]$TriggerValue,

        [string]$CardJson = $null
    )

    <#
    .SYNOPSIS
        Queues a Teams alert with mandatory deduplication.

    .DESCRIPTION
        Inserts a row into Teams.AlertQueue for delivery by
        Process-TeamsAlertQueue. Always checks Teams.RequestLog for an existing
        successfully-sent alert with the same TriggerType and TriggerValue
        before inserting; on a match the alert is skipped and a log message is
        written. Dedup is mandatory with no opt-out, so callers needing a
        repeating alert must pass a unique TriggerValue each time. Supports both
        plain-text alerts and rich Adaptive Card payloads via the optional
        -CardJson parameter; Title, Message, and Color remain required even when
        a card is supplied, populating the audit trail and the plain-text
        fallback. Returns $true if the alert was queued and $false if it was
        skipped (dedup) or failed.

    .PARAMETER SourceModule
        The owning module (e.g., 'ServerOps', 'BatchOps').

    .PARAMETER AlertCategory
        Severity level: CRITICAL, WARNING, or INFO.

    .PARAMETER Title
        Alert card title. Supports Teams markdown.

    .PARAMETER Message
        Alert card body. Supports Teams markdown formatting.

    .PARAMETER Color
        Teams card accent color. Default: 'attention'. Options: default, dark,
        light, accent, good, warning, attention.

    .PARAMETER TriggerType
        Dedup key part one: identifies the alert condition
        (e.g., 'NETWORK_COPY_EXHAUSTED').

    .PARAMETER TriggerValue
        Dedup key part two: identifies the specific instance
        (e.g., tracking_id, batch_id).

    .PARAMETER CardJson
        Optional Adaptive Card JSON payload for rich card rendering. When
        supplied, written to Teams.AlertQueue.card_json; Title, Message, and
        Color still populate the audit trail and plain-text fallback.
    #>

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

        # Queue the alert.
        $titleSafe = $Title -replace "'", "''"
        $messageSafe = $Message -replace "'", "''"

        # Build the INSERT, including the card_json column only when supplied.
        if ([string]::IsNullOrEmpty($CardJson)) {
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
        }
        else {
            $cardJsonSafe = $CardJson -replace "'", "''"
            $insertQuery = @"
INSERT INTO Teams.AlertQueue (
    source_module, alert_category, title, message, color, card_json,
    trigger_type, trigger_value, status, created_dttm
)
VALUES (
    '$SourceModule', '$AlertCategory', N'$titleSafe',
    N'$messageSafe', '$Color', N'$cardJsonSafe',
    '$triggerTypeSafe', '$triggerValueSafe',
    'Pending', GETDATE()
)
"@
        }

        $result = Invoke-SqlNonQuery -Query $insertQuery
        if ($result) {
            $cardSuffix = if ($CardJson) { " (with card)" } else { "" }
            Write-Log "  Teams alert queued: $TriggerType/$TriggerValue$cardSuffix" "SUCCESS"
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
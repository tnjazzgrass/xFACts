<#
.SYNOPSIS
    xFACts - Extended Events Collection
    
.DESCRIPTION
    xFACts - ServerOps.ServerHealth
    Script: Collect-XEEvents.ps1
    Version: Tracked in dbo.System_Metadata (component: ServerOps.ServerHealth)

    Collects Extended Events from all registered servers and imports them into xFACts.
    
    Supported sessions:
    - xFACts_LongQueries -> Activity_XE_LRQ
    - xFACts_BlockedProcess -> Activity_XE_BlockedProcess
    - xFACts_Deadlock -> Activity_XE_Deadlock
    - xFACts_LS_Inbound -> Activity_XE_LinkedServerIn (aggregated by session/sql_text)
    - xFACts_LS_Outbound -> Activity_XE_LinkedServerOut (aggregated by session/sql_text)
    - xFACts_Tracking -> Activity_XE_xFACts (self-impact tracking)
    - system_health -> Activity_XE_SystemHealth (Microsoft built-in)
    - AlwaysOn_health -> Activity_XE_AGHealth (AG servers only)
    
    Uses incremental collection via file_offset tracking to avoid re-reading
    events that have already been processed.
    
    Linked Server sessions use aggregated collection - events are grouped by
    session_id and sql_text to reduce row counts while preserving all detail.

    NOTE: This script uses -MaxCharLength 2147483647 on the XE file target read
    queries (sys.fn_xe_file_target_read_file) because event_data contains full
    XML event payloads that can be very large. Other queries in this script
    (file path lookups, config reads, inserts) use default MaxCharLength.

    CHANGELOG
    ---------
    2026-03-11  Migrated to Initialize-XFActsScript shared infrastructure
                Removed inline Write-Log, Get-SqlData, Invoke-SqlNonQuery
                Updated -DB parameter refs to -DatabaseName for cross-server calls
                Added explicit -MaxCharLength on XE file target read queries
                Updated header to component-level versioning format
    2026-02-19  Added xFACts_Tracking session collection
                New Parse-xFACtsEvent and Insert-xFACtsEvent functions
                Captures all completed xFACts queries for impact analysis
    2026-02-05  Orchestrator v2 integration
                Added -Execute safeguard, TaskId/ProcessId, orchestrator callback
                Relocated to E:\xFACts-PowerShell on FA-SQLDBB
    2026-01-23  Refactoring standardization
                Added master switch check (serverops_activity_enabled)
                ServerOps.ServerRegistry -> dbo.ServerRegistry
                ServerOps.Activity_Config -> dbo.GlobalConfig
                Renamed Activity_XE_LS_Inbound/Outbound -> LinkedServerIn/Out
    2026-01-18  Added LS Inbound/Outbound session collection (aggregated)
                Aggregate by session_id + sql_text to reduce rows
    2026-01-04  Fixed Insert-SystemHealthEvent to match actual table schema
                Fixed Parse-DeadlockEvent for multi-victim deadlocks
                Added victim_count and deadlock_category to deadlock parsing
    2026-01-03  Added system_health session collection (Microsoft built-in)
                Skips QUERY_PROCESSING diagnostic events (too large to parse)
    2026-01-02  Added AlwaysOn_health collection (AG servers only)
                Added first_file_offset column for batch boundary alerting
    2026-01-01  Initial implementation
                LRQ, BlockedProcess, Deadlock session collection
                Incremental collection via file_offset tracking

.PARAMETER ServerInstance
    SQL Server instance name for xFACts database (default: AVG-PROD-LSNR)
    
.PARAMETER Database
    Database name (default: xFACts)
    
.PARAMETER Execute
    Perform writes. Without this flag, the script exits immediately.
    No preview mode — this is a high-frequency collector with no dry-run path.

.PARAMETER Force
    Bypass any checks and run immediately

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
2. The service account running this script must have SQL access to all 
   monitored servers.
3. XE sessions must be deployed and running on target servers.
4. xFACts-OrchestratorFunctions.ps1 must be in the same directory.
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

Initialize-XFActsScript -ScriptName 'Collect-XEEvents' `
    -ServerInstance $ServerInstance -Database $Database -Execute:$Execute

# Hard exit without -Execute — no preview mode for this collector
if (-not $Execute) {
    exit 0
}

# ========================================
# SESSION DEFINITIONS
# ========================================
# Each session we collect from, with its target table

$XESessions = @(
    @{
        Name = "xFACts_LongQueries"
        TargetTable = "Activity_XE_LRQ"
        ParseFunction = "Parse-LRQEvent"
        InsertFunction = "Insert-LRQEvent"
    },
    @{
        Name = "xFACts_BlockedProcess"
        TargetTable = "Activity_XE_BlockedProcess"
        ParseFunction = "Parse-BlockedProcessEvent"
        InsertFunction = "Insert-BlockedProcessEvent"
    },
    @{
        Name = "xFACts_Deadlock"
        TargetTable = "Activity_XE_Deadlock"
        ParseFunction = "Parse-DeadlockEvent"
        InsertFunction = "Insert-DeadlockEvent"
    },
    @{
        Name = "xFACts_LS_Inbound"
        TargetTable = "Activity_XE_LinkedServerIn"
        ParseFunction = "Parse-LSInboundEvent"
        InsertFunction = "Insert-LSInboundEventAggregated"
        IsAggregated = $true
    },
    @{
        Name = "xFACts_LS_Outbound"
        TargetTable = "Activity_XE_LinkedServerOut"
        ParseFunction = "Parse-LSOutboundEvent"
        InsertFunction = "Insert-LSOutboundEventAggregated"
        IsAggregated = $true
    },
    @{
        Name = "xFACts_Tracking"
        TargetTable = "Activity_XE_xFACts"
        ParseFunction = "Parse-xFACtsEvent"
        InsertFunction = "Insert-xFACtsEvent"
    },
    @{
        Name = "system_health"
        TargetTable = "Activity_XE_SystemHealth"
        ParseFunction = "Parse-SystemHealthEvent"
        InsertFunction = "Insert-SystemHealthEvent"
        IsBuiltIn = $true
    }
)

# ========================================
# FUNCTIONS
# ========================================

function Get-SqlInstanceName {
    param(
        [string]$ServerName,
        [string]$InstanceName
    )
    
    if ([string]::IsNullOrWhiteSpace($InstanceName)) {
        return $ServerName
    }
    else {
        return "$ServerName\$InstanceName"
    }
}

function Get-XEFilePath {
    param(
        [string]$Instance,
        [string]$SessionName
    )
    
    # Query the XE session to get the actual file path
    $query = @"
SELECT 
    CAST(target_data AS XML).value('(EventFileTarget/File/@name)[1]', 'varchar(500)') AS file_path
FROM sys.dm_xe_session_targets st
JOIN sys.dm_xe_sessions s ON st.event_session_address = s.address
WHERE s.name = '$SessionName'
  AND st.target_name = 'event_file'
"@
    
    $result = Get-SqlData -Query $query -Instance $Instance -DatabaseName "master"
    
    if ($null -ne $result -and $result.file_path) {
        # Convert specific file path to wildcard pattern
        $filePath = $result.file_path
        $directory = [System.IO.Path]::GetDirectoryName($filePath)
        $pattern = "$directory\$SessionName*.xel"
        return $pattern
    }
    
    return $null
}

function Get-XmlNodeText {
    <#
    .SYNOPSIS
        Safely extracts text value from an XML node, handling both simple text and CDATA
    #>
    param($Node)
    
    if ($null -eq $Node) {
        return $null
    }
    
    # If it's already a string, return it
    if ($Node -is [string]) {
        return $Node
    }
    
    # If it's an XmlElement, get the InnerText
    if ($Node -is [System.Xml.XmlElement]) {
        return $Node.InnerText
    }
    
    # Try to get #text property
    if ($Node.'#text') {
        return $Node.'#text'
    }
    
    # Last resort - convert to string
    return $Node.ToString()
}

function Get-ConfigValue {
    <#
    .SYNOPSIS
        Retrieves a configuration value from dbo.GlobalConfig
    #>
    param([string]$SettingName)
    
    $query = "SELECT setting_value FROM dbo.GlobalConfig WHERE module_name = 'ServerOps' AND category = 'Activity_XE' AND setting_name = '$SettingName' AND is_active = 1"
    $result = Get-SqlData -Query $query
    
    if ($null -ne $result) {
        return $result.setting_value
    }
    return $null
}

# ========================================
# LRQ FUNCTIONS (Long Running Queries)
# ========================================

function Parse-LRQEvent {
    <#
    .SYNOPSIS
        Parses an XE LongQueries event XML into a hashtable of values
    #>
    param([string]$EventXml)
    
    try {
        $xml = [xml]$EventXml
        $event = $xml.event
        
        $parsed = @{
            event_timestamp = [DateTime]::Parse($event.timestamp)
            event_type = $event.name
            
            # Data elements (metrics)
            duration_ms = $null
            cpu_time_ms = $null
            logical_reads = $null
            physical_reads = $null
            writes = $null
            row_count = $null
            
            # Action elements (context)
            database_name = $null
            username = $null
            client_hostname = $null
            client_app_name = $null
            session_id = $null
            sql_text = $null
            query_hash = $null
            query_plan_hash = $null
        }
        
        # Parse data elements
        foreach ($data in $event.data) {
            # Use SelectSingleNode to get the <value> child element
            $valueNode = $data.SelectSingleNode("value")
            $textValue = if ($valueNode) { $valueNode.InnerText } else { $null }
            
            switch ($data.name) {
                "duration" { 
                    if ($textValue) {
                        $parsed.duration_ms = [math]::Round([long]$textValue / 1000, 0)
                    }
                }
                "cpu_time" { 
                    if ($textValue) {
                        $parsed.cpu_time_ms = [math]::Round([long]$textValue / 1000, 0)
                    }
                }
                "logical_reads" { 
                    if ($textValue) { $parsed.logical_reads = [long]$textValue }
                }
                "physical_reads" { 
                    if ($textValue) { $parsed.physical_reads = [long]$textValue }
                }
                "writes" { 
                    if ($textValue) { $parsed.writes = [long]$textValue }
                }
                "row_count" { 
                    if ($textValue) { $parsed.row_count = [long]$textValue }
                }
            }
        }
        
        # Parse action elements
        foreach ($action in $event.action) {
            # Use SelectSingleNode to get the <value> child element
            $valueNode = $action.SelectSingleNode("value")
            $textValue = if ($valueNode) { $valueNode.InnerText } else { $null }
            
            switch ($action.name) {
                "database_name" { $parsed.database_name = $textValue }
                "username" { $parsed.username = $textValue }
                "client_hostname" { $parsed.client_hostname = $textValue }
                "client_app_name" { $parsed.client_app_name = $textValue }
                "session_id" { 
                    if ($textValue) { $parsed.session_id = [int]$textValue }
                }
                "sql_text" { $parsed.sql_text = $textValue }
                "query_hash" { 
                    if ($textValue -and $textValue -ne "0") { 
                        $parsed.query_hash = $textValue 
                    }
                }
                "query_plan_hash" { 
                    if ($textValue -and $textValue -ne "0") { 
                        $parsed.query_plan_hash = $textValue 
                    }
                }
            }
        }
        
        return $parsed
    }
    catch {
        Write-Log "    Failed to parse LRQ event: $_" "WARN"
        return $null
    }
}

function Insert-LRQEvent {
    param(
        [int]$ServerId,
        [string]$ServerName,
        [string]$SessionName,
        [hashtable]$Event,
        [string]$SourceFile,
        [long]$SourceOffset
    )
    
    # Escape single quotes for SQL
    $dbName = if ($Event.database_name) { $Event.database_name -replace "'", "''" } else { $null }
    $userName = if ($Event.username) { $Event.username -replace "'", "''" } else { $null }
    $clientHost = if ($Event.client_hostname) { $Event.client_hostname -replace "'", "''" } else { $null }
    $clientApp = if ($Event.client_app_name) { $Event.client_app_name -replace "'", "''" } else { $null }
    $sqlText = if ($Event.sql_text) { $Event.sql_text -replace "'", "''" } else { $null }
    $sourceFileSafe = if ($SourceFile) { $SourceFile -replace "'", "''" } else { $null }
    $serverNameSafe = $ServerName -replace "'", "''"
    
    $query = @"
INSERT INTO ServerOps.Activity_XE_LRQ (
    server_id, server_name, event_timestamp, event_type, session_name,
    database_name, username, client_hostname, client_app_name, session_id,
    duration_ms, cpu_time_ms, logical_reads, physical_reads, writes, row_count,
    sql_text, source_file, source_offset
)
VALUES (
    $ServerId,
    '$serverNameSafe',
    '$($Event.event_timestamp.ToString("yyyy-MM-dd HH:mm:ss.fff"))',
    '$($Event.event_type)',
    '$SessionName',
    $(if ($dbName) { "'$dbName'" } else { "NULL" }),
    $(if ($userName) { "'$userName'" } else { "NULL" }),
    $(if ($clientHost) { "'$clientHost'" } else { "NULL" }),
    $(if ($clientApp) { "'$clientApp'" } else { "NULL" }),
    $(if ($Event.session_id) { $Event.session_id } else { "NULL" }),
    $($Event.duration_ms),
    $(if ($Event.cpu_time_ms) { $Event.cpu_time_ms } else { "NULL" }),
    $(if ($Event.logical_reads) { $Event.logical_reads } else { "NULL" }),
    $(if ($Event.physical_reads) { $Event.physical_reads } else { "NULL" }),
    $(if ($Event.writes) { $Event.writes } else { "NULL" }),
    $(if ($Event.row_count) { $Event.row_count } else { "NULL" }),
    $(if ($sqlText) { "'$sqlText'" } else { "NULL" }),
    $(if ($sourceFileSafe) { "'$sourceFileSafe'" } else { "NULL" }),
    $SourceOffset
)
"@
    
    return Invoke-SqlNonQuery -Query $query
}

# ========================================
# BLOCKED PROCESS FUNCTIONS
# ========================================

function Parse-BlockedProcessEvent {
    <#
    .SYNOPSIS
        Parses an XE blocked_process_report event XML into a hashtable of values
    #>
    param([string]$EventXml)
    
    try {
        $xml = [xml]$EventXml
        $event = $xml.event
        
        $parsed = @{
            event_timestamp = [DateTime]::Parse($event.timestamp)
            event_type = $event.name
            
            # Blocked process (victim)
            blocked_spid = $null
            blocked_database = $null
            blocked_login = $null
            blocked_client_app = $null
            blocked_host_name = $null
            blocked_wait_time_ms = $null
            blocked_wait_type = $null
            blocked_wait_resource = $null
            blocked_query_text = $null
            
            # Blocking process (culprit)
            blocked_by_spid = $null
            blocked_by_database = $null
            blocked_by_login = $null
            blocked_by_client_app = $null
            blocked_by_host_name = $null
            blocked_by_status = $null
            blocked_by_query_text = $null
            
            # Raw XML
            raw_event_xml = $EventXml
        }
        
        # Find the blocked_process data element which contains both sides
        foreach ($data in $event.data) {
            switch ($data.name) {
                "blocked_process" {
                    # Use SelectSingleNode to get the <value> child element
                    # Structure: <value><blocked-process-report><blocked-process><process>...
                    #                                          <blocking-process><process>...
                    $valueNode = $data.SelectSingleNode("value")
                    
                    if ($valueNode) {
                        $report = $valueNode.'blocked-process-report'
                        
                        if ($report) {
                            # Parse blocked process (victim)
                            $blockedProc = $report.'blocked-process'.process
                            if ($blockedProc) {
                                $parsed.blocked_spid = if ($blockedProc.spid) { [int]$blockedProc.spid } else { $null }
                                $parsed.blocked_database = $blockedProc.currentdbname
                                $parsed.blocked_login = $blockedProc.loginname
                                $parsed.blocked_client_app = $blockedProc.clientapp
                                $parsed.blocked_host_name = $blockedProc.hostname
                                $parsed.blocked_wait_resource = $blockedProc.waitresource
                                $parsed.blocked_wait_type = $blockedProc.lockMode
                                
                                if ($blockedProc.waittime) {
                                    $parsed.blocked_wait_time_ms = [long]$blockedProc.waittime
                                }
                                
                                if ($blockedProc.inputbuf) {
                                    $parsed.blocked_query_text = $blockedProc.inputbuf.Trim()
                                }
                            }
                            
                            # Parse blocking process (culprit)
                            $blockingProc = $report.'blocking-process'.process
                            if ($blockingProc) {
                                $parsed.blocked_by_spid = if ($blockingProc.spid) { [int]$blockingProc.spid } else { $null }
                                $parsed.blocked_by_database = $blockingProc.currentdbname
                                $parsed.blocked_by_login = $blockingProc.loginname
                                $parsed.blocked_by_client_app = $blockingProc.clientapp
                                $parsed.blocked_by_host_name = $blockingProc.hostname
                                $parsed.blocked_by_status = $blockingProc.status
                                
                                if ($blockingProc.inputbuf) {
                                    $parsed.blocked_by_query_text = $blockingProc.inputbuf.Trim()
                                }
                            }
                        }
                    }
                }
                "database_name" {
                    # Use as fallback if not parsed from blocked process
                    if (-not $parsed.blocked_database) {
                        $valueNode = $data.SelectSingleNode("value")
                        if ($valueNode) {
                            $parsed.blocked_database = $valueNode.InnerText
                        }
                    }
                }
            }
        }
        
        return $parsed
    }
    catch {
        Write-Log "    Failed to parse BlockedProcess event: $_" "WARN"
        return $null
    }
}

function Insert-BlockedProcessEvent {
    param(
        [int]$ServerId,
        [string]$ServerName,
        [string]$SessionName,
        [hashtable]$Event,
        [string]$SourceFile,
        [long]$SourceOffset,
        [bool]$RetainRawXml
    )
    
    # Escape single quotes for SQL
    $serverNameSafe = $ServerName -replace "'", "''"
    $blockedDb = if ($Event.blocked_database) { $Event.blocked_database -replace "'", "''" } else { $null }
    $blockedLogin = if ($Event.blocked_login) { $Event.blocked_login -replace "'", "''" } else { $null }
    $blockedApp = if ($Event.blocked_client_app) { $Event.blocked_client_app -replace "'", "''" } else { $null }
    $blockedHost = if ($Event.blocked_host_name) { $Event.blocked_host_name -replace "'", "''" } else { $null }
    $blockedWaitType = if ($Event.blocked_wait_type) { $Event.blocked_wait_type -replace "'", "''" } else { $null }
    $blockedWaitResource = if ($Event.blocked_wait_resource) { $Event.blocked_wait_resource -replace "'", "''" } else { $null }
    $blockedQuery = if ($Event.blocked_query_text) { $Event.blocked_query_text -replace "'", "''" } else { $null }
    
    $blockedByDb = if ($Event.blocked_by_database) { $Event.blocked_by_database -replace "'", "''" } else { $null }
    $blockedByLogin = if ($Event.blocked_by_login) { $Event.blocked_by_login -replace "'", "''" } else { $null }
    $blockedByApp = if ($Event.blocked_by_client_app) { $Event.blocked_by_client_app -replace "'", "''" } else { $null }
    $blockedByHost = if ($Event.blocked_by_host_name) { $Event.blocked_by_host_name -replace "'", "''" } else { $null }
    $blockedByStatus = if ($Event.blocked_by_status) { $Event.blocked_by_status -replace "'", "''" } else { $null }
    $blockedByQuery = if ($Event.blocked_by_query_text) { $Event.blocked_by_query_text -replace "'", "''" } else { $null }
    
    $sourceFileSafe = if ($SourceFile) { $SourceFile -replace "'", "''" } else { $null }
    
    # Handle raw XML based on config flag
    $rawXmlValue = "NULL"
    if ($RetainRawXml -and $Event.raw_event_xml) {
        $rawXmlSafe = $Event.raw_event_xml -replace "'", "''"
        $rawXmlValue = "'$rawXmlSafe'"
    }
    
    $query = @"
INSERT INTO ServerOps.Activity_XE_BlockedProcess (
    server_id, server_name, event_timestamp, event_type, session_name,
    blocked_spid, blocked_database, blocked_login, blocked_client_app, blocked_host_name,
    blocked_wait_time_ms, blocked_wait_type, blocked_wait_resource, blocked_query_text,
    blocked_by_spid, blocked_by_database, blocked_by_login, blocked_by_client_app, blocked_by_host_name,
    blocked_by_status, blocked_by_query_text,
    raw_event_xml, source_file, source_offset
)
VALUES (
    $ServerId,
    '$serverNameSafe',
    '$($Event.event_timestamp.ToString("yyyy-MM-dd HH:mm:ss.fff"))',
    '$($Event.event_type)',
    '$SessionName',
    $(if ($Event.blocked_spid) { $Event.blocked_spid } else { "NULL" }),
    $(if ($blockedDb) { "'$blockedDb'" } else { "NULL" }),
    $(if ($blockedLogin) { "'$blockedLogin'" } else { "NULL" }),
    $(if ($blockedApp) { "'$blockedApp'" } else { "NULL" }),
    $(if ($blockedHost) { "'$blockedHost'" } else { "NULL" }),
    $(if ($Event.blocked_wait_time_ms) { $Event.blocked_wait_time_ms } else { "NULL" }),
    $(if ($blockedWaitType) { "'$blockedWaitType'" } else { "NULL" }),
    $(if ($blockedWaitResource) { "'$blockedWaitResource'" } else { "NULL" }),
    $(if ($blockedQuery) { "'$blockedQuery'" } else { "NULL" }),
    $(if ($Event.blocked_by_spid) { $Event.blocked_by_spid } else { "NULL" }),
    $(if ($blockedByDb) { "'$blockedByDb'" } else { "NULL" }),
    $(if ($blockedByLogin) { "'$blockedByLogin'" } else { "NULL" }),
    $(if ($blockedByApp) { "'$blockedByApp'" } else { "NULL" }),
    $(if ($blockedByHost) { "'$blockedByHost'" } else { "NULL" }),
    $(if ($blockedByStatus) { "'$blockedByStatus'" } else { "NULL" }),
    $(if ($blockedByQuery) { "'$blockedByQuery'" } else { "NULL" }),
    $rawXmlValue,
    $(if ($sourceFileSafe) { "'$sourceFileSafe'" } else { "NULL" }),
    $SourceOffset
)
"@
    
    return Invoke-SqlNonQuery -Query $query
}

# ========================================
# DEADLOCK FUNCTIONS (v1.6 improvements)
# ========================================

function Parse-DeadlockEvent {
    <#
    .SYNOPSIS
        Parses an XE xml_deadlock_report event XML into a hashtable of values.
        Handles multi-victim deadlocks (e.g., intra-query parallelism).
    #>
    param([string]$EventXml)
    
    try {
        $xml = [xml]$EventXml
        $event = $xml.event
        
        $parsed = @{
            event_timestamp = [DateTime]::Parse($event.timestamp)
            event_type = $event.name
            
            # Victim (killed process) - first victim if multiple
            victim_spid = $null
            victim_database = $null
            victim_login = $null
            victim_client_app = $null
            victim_host_name = $null
            victim_query_text = $null
            
            # Survivor (winning process) - first non-victim
            survivor_spid = $null
            survivor_database = $null
            survivor_login = $null
            survivor_client_app = $null
            survivor_host_name = $null
            survivor_query_text = $null
            
            # Counts and classification
            process_count = 0
            victim_count = 0
            deadlock_category = 'STANDARD'
            
            raw_deadlock_xml = $null
        }
        
        # Get the deadlock report XML using SelectSingleNode for robust navigation
        foreach ($data in $event.data) {
            if ($data.name -eq "xml_report") {
                $valueNode = $data.SelectSingleNode("value")
                
                if ($null -eq $valueNode) {
                    Write-Log "    Deadlock parse: No value node found" "WARN"
                    continue
                }
                
                # Get the deadlock element using SelectSingleNode
                $deadlock = $valueNode.SelectSingleNode("deadlock")
                
                if ($null -eq $deadlock) {
                    Write-Log "    Deadlock parse: No deadlock element found" "WARN"
                    continue
                }
                
                # Store raw deadlock XML (just the deadlock portion)
                $parsed.raw_deadlock_xml = $deadlock.OuterXml
                
                # Collect all victim process IDs into an array
                $victimIds = @()
                $victimList = $deadlock.SelectSingleNode("victim-list")
                if ($victimList) {
                    $victimProcessNodes = $victimList.SelectNodes("victimProcess")
                    foreach ($victimNode in $victimProcessNodes) {
                        $vid = $victimNode.GetAttribute("id")
                        if ($vid) {
                            $victimIds += $vid
                        }
                    }
                }
                
                $parsed.victim_count = $victimIds.Count
                $parsed.deadlock_category = if ($victimIds.Count -gt 1) { 'COMPLEX' } else { 'STANDARD' }
                
                # Parse process list
                $processes = @()
                $processList = $deadlock.SelectSingleNode("process-list")
                if ($processList) {
                    $processNodes = $processList.SelectNodes("process")
                    foreach ($procNode in $processNodes) {
                        $processes += $procNode
                    }
                }
                
                $parsed.process_count = $processes.Count
                
                # Track if we've captured first victim and first survivor
                $firstVictimCaptured = $false
                $firstSurvivorCaptured = $false
                
                foreach ($proc in $processes) {
                    $procId = $proc.GetAttribute("id")
                    $isVictim = $victimIds -contains $procId
                    
                    # Extract process details
                    $spid = $null
                    $spidAttr = $proc.GetAttribute("spid")
                    if ($spidAttr) { 
                        try { $spid = [int]$spidAttr } catch { $spid = $null }
                    }
                    
                    $database = $proc.GetAttribute("currentdbname")
                    $login = $proc.GetAttribute("loginname")
                    $clientApp = $proc.GetAttribute("clientapp")
                    $hostName = $proc.GetAttribute("hostname")
                    
                    $queryText = $null
                    $inputBuf = $proc.SelectSingleNode("inputbuf")
                    if ($inputBuf) {
                        $queryText = $inputBuf.InnerText.Trim()
                    }
                    
                    if ($isVictim -and -not $firstVictimCaptured) {
                        # Capture first victim
                        $parsed.victim_spid = $spid
                        $parsed.victim_database = $database
                        $parsed.victim_login = $login
                        $parsed.victim_client_app = $clientApp
                        $parsed.victim_host_name = $hostName
                        $parsed.victim_query_text = $queryText
                        $firstVictimCaptured = $true
                    }
                    elseif (-not $isVictim -and -not $firstSurvivorCaptured) {
                        # Capture first survivor (non-victim)
                        $parsed.survivor_spid = $spid
                        $parsed.survivor_database = $database
                        $parsed.survivor_login = $login
                        $parsed.survivor_client_app = $clientApp
                        $parsed.survivor_host_name = $hostName
                        $parsed.survivor_query_text = $queryText
                        $firstSurvivorCaptured = $true
                    }
                    
                    # Exit early if we have both
                    if ($firstVictimCaptured -and $firstSurvivorCaptured) {
                        break
                    }
                }
            }
        }
        
        return $parsed
    }
    catch {
        Write-Log "    Failed to parse Deadlock event: $_" "WARN"
        return $null
    }
}

function Insert-DeadlockEvent {
    param(
        [int]$ServerId,
        [string]$ServerName,
        [string]$SessionName,
        [hashtable]$Event,
        [string]$SourceFile,
        [long]$SourceOffset
    )
    
    # Escape single quotes for SQL
    $serverNameSafe = $ServerName -replace "'", "''"
    
    $victimDb = if ($Event.victim_database) { $Event.victim_database -replace "'", "''" } else { $null }
    $victimLogin = if ($Event.victim_login) { $Event.victim_login -replace "'", "''" } else { $null }
    $victimApp = if ($Event.victim_client_app) { $Event.victim_client_app -replace "'", "''" } else { $null }
    $victimHost = if ($Event.victim_host_name) { $Event.victim_host_name -replace "'", "''" } else { $null }
    $victimQuery = if ($Event.victim_query_text) { $Event.victim_query_text -replace "'", "''" } else { $null }
    
    $survivorDb = if ($Event.survivor_database) { $Event.survivor_database -replace "'", "''" } else { $null }
    $survivorLogin = if ($Event.survivor_login) { $Event.survivor_login -replace "'", "''" } else { $null }
    $survivorApp = if ($Event.survivor_client_app) { $Event.survivor_client_app -replace "'", "''" } else { $null }
    $survivorHost = if ($Event.survivor_host_name) { $Event.survivor_host_name -replace "'", "''" } else { $null }
    $survivorQuery = if ($Event.survivor_query_text) { $Event.survivor_query_text -replace "'", "''" } else { $null }
    
    $sourceFileSafe = if ($SourceFile) { $SourceFile -replace "'", "''" } else { $null }
    $deadlockCategory = if ($Event.deadlock_category) { $Event.deadlock_category } else { 'STANDARD' }
    
    # Raw XML
    $rawXmlValue = "NULL"
    if ($Event.raw_deadlock_xml) {
        $rawXmlSafe = $Event.raw_deadlock_xml -replace "'", "''"
        $rawXmlValue = "'$rawXmlSafe'"
    }
    
    $query = @"
INSERT INTO ServerOps.Activity_XE_Deadlock (
    server_id, server_name, event_timestamp, event_type, session_name,
    victim_spid, victim_database, victim_login, victim_client_app, victim_host_name, victim_query_text,
    survivor_spid, survivor_database, survivor_login, survivor_client_app, survivor_host_name, survivor_query_text,
    process_count, victim_count, deadlock_category, raw_deadlock_xml, source_file, source_offset
)
VALUES (
    $ServerId,
    '$serverNameSafe',
    '$($Event.event_timestamp.ToString("yyyy-MM-dd HH:mm:ss.fff"))',
    '$($Event.event_type)',
    '$SessionName',
    $(if ($Event.victim_spid) { $Event.victim_spid } else { "NULL" }),
    $(if ($victimDb) { "'$victimDb'" } else { "NULL" }),
    $(if ($victimLogin) { "'$victimLogin'" } else { "NULL" }),
    $(if ($victimApp) { "'$victimApp'" } else { "NULL" }),
    $(if ($victimHost) { "'$victimHost'" } else { "NULL" }),
    $(if ($victimQuery) { "'$victimQuery'" } else { "NULL" }),
    $(if ($Event.survivor_spid) { $Event.survivor_spid } else { "NULL" }),
    $(if ($survivorDb) { "'$survivorDb'" } else { "NULL" }),
    $(if ($survivorLogin) { "'$survivorLogin'" } else { "NULL" }),
    $(if ($survivorApp) { "'$survivorApp'" } else { "NULL" }),
    $(if ($survivorHost) { "'$survivorHost'" } else { "NULL" }),
    $(if ($survivorQuery) { "'$survivorQuery'" } else { "NULL" }),
    $(if ($Event.process_count) { $Event.process_count } else { "NULL" }),
    $(if ($Event.victim_count) { $Event.victim_count } else { 1 }),
    '$deadlockCategory',
    $rawXmlValue,
    $(if ($sourceFileSafe) { "'$sourceFileSafe'" } else { "NULL" }),
    $SourceOffset
)
"@
    
    return Invoke-SqlNonQuery -Query $query
}

# ========================================
# LS INBOUND FUNCTIONS (Linked Server Inbound)
# ========================================

function Parse-LSInboundEvent {
    <#
    .SYNOPSIS
        Parses an XE LS_Inbound event XML into a hashtable of values
    #>
    param([string]$EventXml)
    
    try {
        $xml = [xml]$EventXml
        $event = $xml.event
        
        $parsed = @{
            event_timestamp = [DateTime]::Parse($event.timestamp)
            event_type = $event.name
            
            # Data elements (metrics)
            duration_ms = 0
            cpu_time_ms = $null
            logical_reads = $null
            physical_reads = $null
            writes = $null
            row_count = $null
            
            # Action elements (context)
            database_name = $null
            username = $null
            nt_username = $null
            client_hostname = $null
            client_app_name = $null
            client_pid = $null
            session_id = $null
            sql_text = $null
            query_hash = $null
            query_plan_hash = $null
        }
        
        # Parse data elements
        foreach ($data in $event.data) {
            $valueNode = $data.SelectSingleNode("value")
            $textValue = if ($valueNode) { $valueNode.InnerText } else { $null }
            
            switch ($data.name) {
                "duration" { 
                    if ($textValue) {
                        $parsed.duration_ms = [math]::Round([long]$textValue / 1000, 0)
                    }
                }
                "cpu_time" { 
                    if ($textValue) {
                        $parsed.cpu_time_ms = [math]::Round([long]$textValue / 1000, 0)
                    }
                }
                "logical_reads" { 
                    if ($textValue) { $parsed.logical_reads = [long]$textValue }
                }
                "physical_reads" { 
                    if ($textValue) { $parsed.physical_reads = [long]$textValue }
                }
                "writes" { 
                    if ($textValue) { $parsed.writes = [long]$textValue }
                }
                "row_count" { 
                    if ($textValue) { $parsed.row_count = [long]$textValue }
                }
            }
        }
        
        # Parse action elements
        foreach ($action in $event.action) {
            $valueNode = $action.SelectSingleNode("value")
            $textValue = if ($valueNode) { $valueNode.InnerText } else { $null }
            
            switch ($action.name) {
                "database_name" { $parsed.database_name = $textValue }
                "username" { $parsed.username = $textValue }
                "nt_username" { $parsed.nt_username = $textValue }
                "client_hostname" { $parsed.client_hostname = $textValue }
                "client_app_name" { $parsed.client_app_name = $textValue }
                "client_pid" { 
                    if ($textValue) { $parsed.client_pid = [int]$textValue }
                }
                "session_id" { 
                    if ($textValue) { $parsed.session_id = [int]$textValue }
                }
                "sql_text" { $parsed.sql_text = $textValue }
                "query_hash" { 
                    if ($textValue -and $textValue -ne "0") { 
                        $parsed.query_hash = $textValue 
                    }
                }
                "query_plan_hash" { 
                    if ($textValue -and $textValue -ne "0") { 
                        $parsed.query_plan_hash = $textValue 
                    }
                }
            }
        }
        
        return $parsed
    }
    catch {
        Write-Log "    Failed to parse LS_Inbound event: $_" "WARN"
        return $null
    }
}

function Insert-LSInboundEventAggregated {
    <#
    .SYNOPSIS
        Inserts aggregated LS_Inbound events (one row per session_id + sql_text combination)
    #>
    param(
        [int]$ServerId,
        [string]$ServerName,
        [string]$SessionName,
        [hashtable]$AggregatedEvent
    )
    
    # Escape single quotes for SQL
    $dbName = if ($AggregatedEvent.database_name) { $AggregatedEvent.database_name -replace "'", "''" } else { $null }
    $userName = if ($AggregatedEvent.username) { $AggregatedEvent.username -replace "'", "''" } else { $null }
    $ntUserName = if ($AggregatedEvent.nt_username) { $AggregatedEvent.nt_username -replace "'", "''" } else { $null }
    $clientHost = if ($AggregatedEvent.client_hostname) { $AggregatedEvent.client_hostname -replace "'", "''" } else { $null }
    $clientApp = if ($AggregatedEvent.client_app_name) { $AggregatedEvent.client_app_name -replace "'", "''" } else { $null }
    $sqlText = if ($AggregatedEvent.sql_text) { $AggregatedEvent.sql_text -replace "'", "''" } else { $null }
    $serverNameSafe = $ServerName -replace "'", "''"
    $queryHash = if ($AggregatedEvent.query_hash) { $AggregatedEvent.query_hash } else { $null }
    $queryPlanHash = if ($AggregatedEvent.query_plan_hash) { $AggregatedEvent.query_plan_hash } else { $null }
    
    $query = @"
INSERT INTO ServerOps.Activity_XE_LinkedServerIn (
    server_id, server_name, session_id, client_pid, client_hostname, client_app_name,
    database_name, username, nt_username, sql_text, query_hash, query_plan_hash,
    execution_count, first_event_timestamp, last_event_timestamp,
    total_duration_ms, max_duration_ms, total_cpu_time_ms, total_logical_reads,
    total_physical_reads, total_writes, total_row_count, session_name
)
VALUES (
    $ServerId,
    '$serverNameSafe',
    $(if ($AggregatedEvent.session_id) { $AggregatedEvent.session_id } else { "NULL" }),
    $(if ($AggregatedEvent.client_pid) { $AggregatedEvent.client_pid } else { "NULL" }),
    $(if ($clientHost) { "'$clientHost'" } else { "NULL" }),
    $(if ($clientApp) { "'$clientApp'" } else { "NULL" }),
    $(if ($dbName) { "'$dbName'" } else { "NULL" }),
    $(if ($userName) { "'$userName'" } else { "NULL" }),
    $(if ($ntUserName) { "'$ntUserName'" } else { "NULL" }),
    $(if ($sqlText) { "'$sqlText'" } else { "NULL" }),
    $(if ($queryHash) { "'$queryHash'" } else { "NULL" }),
    $(if ($queryPlanHash) { "'$queryPlanHash'" } else { "NULL" }),
    $($AggregatedEvent.execution_count),
    '$($AggregatedEvent.first_event_timestamp.ToString("yyyy-MM-dd HH:mm:ss.fff"))',
    '$($AggregatedEvent.last_event_timestamp.ToString("yyyy-MM-dd HH:mm:ss.fff"))',
    $($AggregatedEvent.total_duration_ms),
    $($AggregatedEvent.max_duration_ms),
    $(if ($AggregatedEvent.total_cpu_time_ms) { $AggregatedEvent.total_cpu_time_ms } else { "NULL" }),
    $(if ($AggregatedEvent.total_logical_reads) { $AggregatedEvent.total_logical_reads } else { "NULL" }),
    $(if ($AggregatedEvent.total_physical_reads) { $AggregatedEvent.total_physical_reads } else { "NULL" }),
    $(if ($AggregatedEvent.total_writes) { $AggregatedEvent.total_writes } else { "NULL" }),
    $(if ($AggregatedEvent.total_row_count) { $AggregatedEvent.total_row_count } else { "NULL" }),
    '$SessionName'
)
"@
    
    return Invoke-SqlNonQuery -Query $query
}

# ========================================
# LS OUTBOUND FUNCTIONS (Linked Server Outbound)
# ========================================

function Parse-LSOutboundEvent {
    <#
    .SYNOPSIS
        Parses an XE LS_Outbound event XML into a hashtable of values
    #>
    param([string]$EventXml)
    
    try {
        $xml = [xml]$EventXml
        $event = $xml.event
        
        $parsed = @{
            event_timestamp = [DateTime]::Parse($event.timestamp)
            event_type = $event.name
            
            # Data elements (metrics)
            duration_ms = 0
            cpu_time_ms = $null
            logical_reads = $null
            physical_reads = $null
            writes = $null
            row_count = $null
            
            # Action elements (context)
            database_name = $null
            username = $null
            nt_username = $null
            client_hostname = $null
            client_app_name = $null
            client_pid = $null
            session_id = $null
            sql_text = $null
            query_hash = $null
            query_plan_hash = $null
        }
        
        # Parse data elements
        foreach ($data in $event.data) {
            $valueNode = $data.SelectSingleNode("value")
            $textValue = if ($valueNode) { $valueNode.InnerText } else { $null }
            
            switch ($data.name) {
                "duration" { 
                    if ($textValue) {
                        $parsed.duration_ms = [math]::Round([long]$textValue / 1000, 0)
                    }
                }
                "cpu_time" { 
                    if ($textValue) {
                        $parsed.cpu_time_ms = [math]::Round([long]$textValue / 1000, 0)
                    }
                }
                "logical_reads" { 
                    if ($textValue) { $parsed.logical_reads = [long]$textValue }
                }
                "physical_reads" { 
                    if ($textValue) { $parsed.physical_reads = [long]$textValue }
                }
                "writes" { 
                    if ($textValue) { $parsed.writes = [long]$textValue }
                }
                "row_count" { 
                    if ($textValue) { $parsed.row_count = [long]$textValue }
                }
            }
        }
        
        # Parse action elements
        foreach ($action in $event.action) {
            $valueNode = $action.SelectSingleNode("value")
            $textValue = if ($valueNode) { $valueNode.InnerText } else { $null }
            
            switch ($action.name) {
                "database_name" { $parsed.database_name = $textValue }
                "username" { $parsed.username = $textValue }
                "nt_username" { $parsed.nt_username = $textValue }
                "client_hostname" { $parsed.client_hostname = $textValue }
                "client_app_name" { $parsed.client_app_name = $textValue }
                "client_pid" { 
                    if ($textValue) { $parsed.client_pid = [int]$textValue }
                }
                "session_id" { 
                    if ($textValue) { $parsed.session_id = [int]$textValue }
                }
                "sql_text" { $parsed.sql_text = $textValue }
                "query_hash" { 
                    if ($textValue -and $textValue -ne "0") { 
                        $parsed.query_hash = $textValue 
                    }
                }
                "query_plan_hash" { 
                    if ($textValue -and $textValue -ne "0") { 
                        $parsed.query_plan_hash = $textValue 
                    }
                }
            }
        }
        
        return $parsed
    }
    catch {
        Write-Log "    Failed to parse LS_Outbound event: $_" "WARN"
        return $null
    }
}

function Insert-LSOutboundEventAggregated {
    <#
    .SYNOPSIS
        Inserts aggregated LS_Outbound events (one row per session_id + sql_text combination)
    #>
    param(
        [int]$ServerId,
        [string]$ServerName,
        [string]$SessionName,
        [hashtable]$AggregatedEvent
    )
    
    # Escape single quotes for SQL
    $dbName = if ($AggregatedEvent.database_name) { $AggregatedEvent.database_name -replace "'", "''" } else { $null }
    $userName = if ($AggregatedEvent.username) { $AggregatedEvent.username -replace "'", "''" } else { $null }
    $ntUserName = if ($AggregatedEvent.nt_username) { $AggregatedEvent.nt_username -replace "'", "''" } else { $null }
    $clientHost = if ($AggregatedEvent.client_hostname) { $AggregatedEvent.client_hostname -replace "'", "''" } else { $null }
    $clientApp = if ($AggregatedEvent.client_app_name) { $AggregatedEvent.client_app_name -replace "'", "''" } else { $null }
    $sqlText = if ($AggregatedEvent.sql_text) { $AggregatedEvent.sql_text -replace "'", "''" } else { $null }
    $serverNameSafe = $ServerName -replace "'", "''"
    $queryHash = if ($AggregatedEvent.query_hash) { $AggregatedEvent.query_hash } else { $null }
    $queryPlanHash = if ($AggregatedEvent.query_plan_hash) { $AggregatedEvent.query_plan_hash } else { $null }
    
    $query = @"
INSERT INTO ServerOps.Activity_XE_LinkedServerOut (
    server_id, server_name, session_id, client_pid, client_hostname, client_app_name,
    database_name, username, nt_username, sql_text, query_hash, query_plan_hash,
    execution_count, first_event_timestamp, last_event_timestamp,
    total_duration_ms, max_duration_ms, total_cpu_time_ms, total_logical_reads,
    total_physical_reads, total_writes, total_row_count, session_name
)
VALUES (
    $ServerId,
    '$serverNameSafe',
    $(if ($AggregatedEvent.session_id) { $AggregatedEvent.session_id } else { "NULL" }),
    $(if ($AggregatedEvent.client_pid) { $AggregatedEvent.client_pid } else { "NULL" }),
    $(if ($clientHost) { "'$clientHost'" } else { "NULL" }),
    $(if ($clientApp) { "'$clientApp'" } else { "NULL" }),
    $(if ($dbName) { "'$dbName'" } else { "NULL" }),
    $(if ($userName) { "'$userName'" } else { "NULL" }),
    $(if ($ntUserName) { "'$ntUserName'" } else { "NULL" }),
    $(if ($sqlText) { "'$sqlText'" } else { "NULL" }),
    $(if ($queryHash) { "'$queryHash'" } else { "NULL" }),
    $(if ($queryPlanHash) { "'$queryPlanHash'" } else { "NULL" }),
    $($AggregatedEvent.execution_count),
    '$($AggregatedEvent.first_event_timestamp.ToString("yyyy-MM-dd HH:mm:ss.fff"))',
    '$($AggregatedEvent.last_event_timestamp.ToString("yyyy-MM-dd HH:mm:ss.fff"))',
    $($AggregatedEvent.total_duration_ms),
    $($AggregatedEvent.max_duration_ms),
    $(if ($AggregatedEvent.total_cpu_time_ms) { $AggregatedEvent.total_cpu_time_ms } else { "NULL" }),
    $(if ($AggregatedEvent.total_logical_reads) { $AggregatedEvent.total_logical_reads } else { "NULL" }),
    $(if ($AggregatedEvent.total_physical_reads) { $AggregatedEvent.total_physical_reads } else { "NULL" }),
    $(if ($AggregatedEvent.total_writes) { $AggregatedEvent.total_writes } else { "NULL" }),
    $(if ($AggregatedEvent.total_row_count) { $AggregatedEvent.total_row_count } else { "NULL" }),
    '$SessionName'
)
"@
    
    return Invoke-SqlNonQuery -Query $query
}

# ========================================
# LS AGGREGATION HELPER FUNCTION
# ========================================

function Aggregate-LSEvents {
    <#
    .SYNOPSIS
        Aggregates parsed LS events by session_id + sql_text combination
    .DESCRIPTION
        Takes an array of parsed events and groups them, returning aggregated records
    #>
    param(
        [array]$ParsedEvents
    )
    
    $aggregated = @{}
    
    foreach ($event in $ParsedEvents) {
        # Create a composite key from session_id and sql_text
        $sessionId = if ($event.session_id) { $event.session_id } else { "NULL" }
        $sqlText = if ($event.sql_text) { $event.sql_text } else { "(NULL)" }
        $key = "$sessionId|$sqlText"
        
        if (-not $aggregated.ContainsKey($key)) {
            # Initialize aggregation record
            $aggregated[$key] = @{
                session_id = $event.session_id
                client_pid = $event.client_pid
                client_hostname = $event.client_hostname
                client_app_name = $event.client_app_name
                database_name = $event.database_name
                username = $event.username
                nt_username = $event.nt_username
                sql_text = $event.sql_text
                query_hash = $event.query_hash
                query_plan_hash = $event.query_plan_hash
                execution_count = 0
                first_event_timestamp = $event.event_timestamp
                last_event_timestamp = $event.event_timestamp
                total_duration_ms = 0
                max_duration_ms = 0
                total_cpu_time_ms = $null
                total_logical_reads = $null
                total_physical_reads = $null
                total_writes = $null
                total_row_count = $null
            }
        }
        
        $agg = $aggregated[$key]
        
        # Increment execution count
        $agg.execution_count++
        
        # Update timestamps
        if ($event.event_timestamp -lt $agg.first_event_timestamp) {
            $agg.first_event_timestamp = $event.event_timestamp
        }
        if ($event.event_timestamp -gt $agg.last_event_timestamp) {
            $agg.last_event_timestamp = $event.event_timestamp
        }
        
        # Aggregate duration
        $duration = if ($event.duration_ms) { $event.duration_ms } else { 0 }
        $agg.total_duration_ms += $duration
        if ($duration -gt $agg.max_duration_ms) {
            $agg.max_duration_ms = $duration
        }
        
        # Aggregate other metrics (sum, handling nulls)
        if ($event.cpu_time_ms) {
            if ($null -eq $agg.total_cpu_time_ms) { $agg.total_cpu_time_ms = 0 }
            $agg.total_cpu_time_ms += $event.cpu_time_ms
        }
        if ($event.logical_reads) {
            if ($null -eq $agg.total_logical_reads) { $agg.total_logical_reads = 0 }
            $agg.total_logical_reads += $event.logical_reads
        }
        if ($event.physical_reads) {
            if ($null -eq $agg.total_physical_reads) { $agg.total_physical_reads = 0 }
            $agg.total_physical_reads += $event.physical_reads
        }
        if ($event.writes) {
            if ($null -eq $agg.total_writes) { $agg.total_writes = 0 }
            $agg.total_writes += $event.writes
        }
        if ($event.row_count) {
            if ($null -eq $agg.total_row_count) { $agg.total_row_count = 0 }
            $agg.total_row_count += $event.row_count
        }
    }
    
    return $aggregated.Values
}

# ========================================
# xFACts SELF-MONITORING FUNCTIONS
# ========================================

function Parse-xFACtsEvent {
    <#
    .SYNOPSIS
        Parses an XE xFACts_Tracking event XML into a hashtable.
        Same structure as LRQ but no duration threshold filtering.
    #>
    param([string]$EventXml)
    
    try {
        $xml = [xml]$EventXml
        $event = $xml.event
        
        $parsed = @{
            event_timestamp = [DateTime]::Parse($event.timestamp)
            event_type = $event.name
            
            # Data elements (metrics)
            duration_ms = $null
            cpu_time_ms = $null
            logical_reads = $null
            physical_reads = $null
            writes = $null
            row_count = $null
            
            # Action elements (context)
            database_name = $null
            username = $null
            client_app_name = $null
            session_id = $null
            sql_text = $null
        }
        
        # Parse data elements
        foreach ($data in $event.data) {
            $valueNode = $data.SelectSingleNode("value")
            $textValue = if ($valueNode) { $valueNode.InnerText } else { $null }
            
            switch ($data.name) {
                "duration" { 
                    if ($textValue) {
                        $parsed.duration_ms = [math]::Round([long]$textValue / 1000, 0)
                    }
                }
                "cpu_time" { 
                    if ($textValue) {
                        $parsed.cpu_time_ms = [math]::Round([long]$textValue / 1000, 0)
                    }
                }
                "logical_reads" { 
                    if ($textValue) { $parsed.logical_reads = [long]$textValue }
                }
                "physical_reads" { 
                    if ($textValue) { $parsed.physical_reads = [long]$textValue }
                }
                "writes" { 
                    if ($textValue) { $parsed.writes = [long]$textValue }
                }
                "row_count" { 
                    if ($textValue) { $parsed.row_count = [long]$textValue }
                }
            }
        }
        
        # Parse action elements
        foreach ($action in $event.action) {
            $valueNode = $action.SelectSingleNode("value")
            $textValue = if ($valueNode) { $valueNode.InnerText } else { $null }
            
            switch ($action.name) {
                "database_name" { $parsed.database_name = $textValue }
                "username" { $parsed.username = $textValue }
                "client_app_name" { $parsed.client_app_name = $textValue }
                "session_id" { 
                    if ($textValue) { $parsed.session_id = [int]$textValue }
                }
                "sql_text" { $parsed.sql_text = $textValue }
            }
        }
        
        return $parsed
    }
    catch {
        Write-Log "    Failed to parse xFACts tracking event: $_" "WARN"
        return $null
    }
}

function Insert-xFACtsEvent {
    param(
        [int]$ServerId,
        [string]$ServerName,
        [string]$SessionName,
        [hashtable]$Event,
        [string]$SourceFile,
        [long]$SourceOffset
    )
    
    $dbName = if ($Event.database_name) { $Event.database_name -replace "'", "''" } else { $null }
    $userName = if ($Event.username) { $Event.username -replace "'", "''" } else { $null }
    $clientApp = if ($Event.client_app_name) { $Event.client_app_name -replace "'", "''" } else { $null }
    $sqlText = if ($Event.sql_text) { $Event.sql_text -replace "'", "''" } else { $null }
    $sourceFileSafe = if ($SourceFile) { $SourceFile -replace "'", "''" } else { $null }
    $serverNameSafe = $ServerName -replace "'", "''"
    
    $query = @"
INSERT INTO ServerOps.Activity_XE_xFACts (
    server_id, server_name, event_timestamp, event_type, session_name,
    database_name, username, client_app_name, session_id,
    duration_ms, cpu_time_ms, logical_reads, physical_reads, writes, row_count,
    sql_text, source_file, source_offset
)
VALUES (
    $ServerId,
    '$serverNameSafe',
    '$($Event.event_timestamp.ToString("yyyy-MM-dd HH:mm:ss.fff"))',
    '$($Event.event_type)',
    '$SessionName',
    $(if ($dbName) { "'$dbName'" } else { "NULL" }),
    $(if ($userName) { "'$userName'" } else { "NULL" }),
    $(if ($clientApp) { "'$clientApp'" } else { "NULL" }),
    $(if ($Event.session_id) { $Event.session_id } else { "NULL" }),
    $($Event.duration_ms),
    $(if ($Event.cpu_time_ms) { $Event.cpu_time_ms } else { "NULL" }),
    $(if ($Event.logical_reads) { $Event.logical_reads } else { "NULL" }),
    $(if ($Event.physical_reads) { $Event.physical_reads } else { "NULL" }),
    $(if ($Event.writes) { $Event.writes } else { "NULL" }),
    $(if ($Event.row_count) { $Event.row_count } else { "NULL" }),
    $(if ($sqlText) { "'$sqlText'" } else { "NULL" }),
    $(if ($sourceFileSafe) { "'$sourceFileSafe'" } else { "NULL" }),
    $SourceOffset
)
"@
    
    return Invoke-SqlNonQuery -Query $query
}

# ========================================
# SYSTEM HEALTH FUNCTIONS (v1.5 - working)
# ========================================

function Get-SystemHealthFilePath {
    <#
    .SYNOPSIS
        Gets the file path for system_health XE session on a given server.
        Unlike xFACts sessions, system_health uses the default SQL Server Log folder.
    #>
    param(
        [string]$Instance
    )
    
    $query = @"
SELECT 
    CAST(target_data AS XML).value('(EventFileTarget/File/@name)[1]', 'varchar(500)') AS file_path
FROM sys.dm_xe_session_targets st
JOIN sys.dm_xe_sessions s ON st.event_session_address = s.address
WHERE s.name = 'system_health'
  AND st.target_name = 'event_file'
"@
    
    $result = Get-SqlData -Query $query -Instance $Instance -DatabaseName "master"
    
    if ($null -ne $result -and $result.file_path) {
        $filePath = $result.file_path
        $directory = [System.IO.Path]::GetDirectoryName($filePath)
        $pattern = "$directory\system_health*.xel"
        return $pattern
    }
    
    return $null
}

function Parse-SystemHealthEvent {
    <#
    .SYNOPSIS
        Parses a system_health XE event XML into a hashtable of values.
        Handles all event types: security_error, connectivity, wait_info, 
        scheduler_monitor, sp_server_diagnostics, xml_deadlock_report, etc.
    #>
    param([string]$EventXml)
    
    # Early extraction of event name for skip logic
    $eventName = if ($EventXml -match 'event name="([^"]+)"') { $matches[1] } else { "unknown" }
    
    # Skip QUERY_PROCESSING diagnostic events - XML is too large to parse reliably
    if ($eventName -eq 'sp_server_diagnostics_component_result' -and $EventXml -match 'QUERY_PROCESSING') {
        return $null
    }
    
    try {
        $xml = [xml]$EventXml
        $event = $xml.event
        
        $parsed = @{
            event_timestamp = [DateTime]::Parse($event.timestamp)
            event_type = $event.name
            
            # Session/Error Context
            session_id = $null
            error_code = $null
            calling_api_name = $null
            
            # Connectivity
            client_hostname = $null
            client_app_name = $null
            os_error = $null
            login_time_ms = $null
            
            # Wait Stats
            wait_type = $null
            duration_ms = $null
            signal_duration_ms = $null
            
            # Diagnostics
            component_type = $null
            component_state = $null
            
            # Raw XML (always stored for system_health)
            raw_event_xml = $EventXml
        }
        
        # Parse based on event type
        switch ($event.name) {
            "security_error_ring_buffer_recorded" {
                foreach ($data in $event.data) {
                    $valueNode = $data.SelectSingleNode("value")
                    $textValue = if ($valueNode) { $valueNode.InnerText } else { $null }
                    
                    switch ($data.name) {
                        "session_id" { 
                            if ($textValue) { $parsed.session_id = [int]$textValue }
                        }
                        "error_code" { 
                            if ($textValue) { $parsed.error_code = [int]$textValue }
                        }
                        "calling_api_name" { 
                            $parsed.calling_api_name = $textValue 
                        }
                    }
                }
            }
            
            "connectivity_ring_buffer_recorded" {
                foreach ($data in $event.data) {
                    $valueNode = $data.SelectSingleNode("value")
                    $textValue = if ($valueNode) { $valueNode.InnerText } else { $null }
                    
                    switch ($data.name) {
                        "error_code" { 
                            if ($textValue) { $parsed.error_code = [int]$textValue }
                        }
                        "os_error" { 
                            if ($textValue) { $parsed.os_error = [int]$textValue }
                        }
                        "client_hostname" { 
                            $parsed.client_hostname = $textValue 
                        }
                        "client_app_name" { 
                            $parsed.client_app_name = $textValue 
                        }
                        "total_login_time_ms" { 
                            if ($textValue) { $parsed.login_time_ms = [int]$textValue }
                        }
                    }
                }
            }
            
            { $_ -in "wait_info", "wait_info_external" } {
                foreach ($data in $event.data) {
                    $valueNode = $data.SelectSingleNode("value")
                    $textNode = $data.SelectSingleNode("text")
                    $textValue = if ($valueNode) { $valueNode.InnerText } else { $null }
                    $textDesc = if ($textNode) { $textNode.InnerText } else { $null }
                    
                    switch ($data.name) {
                        "wait_type" { 
                            $parsed.wait_type = if ($textDesc) { $textDesc } else { $textValue }
                        }
                        "duration" { 
                            if ($textValue) { $parsed.duration_ms = [long]$textValue }
                        }
                        "signal_duration" { 
                            if ($textValue) { $parsed.signal_duration_ms = [long]$textValue }
                        }
                        "session_id" { 
                            if ($textValue) { $parsed.session_id = [int]$textValue }
                        }
                    }
                }
            }
            
            "scheduler_monitor_system_health_ring_buffer_recorded" {
                # Complex nested data - just capture event type, raw XML has details
            }
            
            "sp_server_diagnostics_component_result" {
                foreach ($data in $event.data) {
                    $valueNode = $data.SelectSingleNode("value")
                    $textNode = $data.SelectSingleNode("text")
                    $textValue = if ($valueNode) { $valueNode.InnerText } else { $null }
                    $textDesc = if ($textNode) { $textNode.InnerText } else { $null }
                    
                    switch ($data.name) {
                        "component" { 
                            $parsed.component_type = if ($textDesc) { $textDesc } else { $textValue }
                        }
                        "state" { 
                            $parsed.component_state = if ($textDesc) { $textDesc } else { $textValue }
                        }
                        "duration" { 
                            if ($textValue) { $parsed.duration_ms = [long]$textValue }
                        }
                    }
                }
            }
            
            "xml_deadlock_report" {
                # Deadlock XML is in the data - raw XML preserved
            }
            
            "memory_broker_ring_buffer_recorded" {
                # Memory events - raw XML has details
            }
            
            default {
                # Unknown event type - still capture with raw XML
            }
        }
        
        return $parsed
    }
    catch {
        return $null
    }
}

function Insert-SystemHealthEvent {
    param(
        [int]$ServerId,
        [string]$ServerName,
        [string]$SessionName,
        [hashtable]$Event,
        [string]$SourceFile,
        [long]$SourceOffset
    )
    
    $serverNameSafe = $ServerName -replace "'", "''"
    $callingApi = if ($Event.calling_api_name) { $Event.calling_api_name -replace "'", "''" } else { $null }
    $clientHost = if ($Event.client_hostname) { $Event.client_hostname -replace "'", "''" } else { $null }
    $clientApp = if ($Event.client_app_name) { $Event.client_app_name -replace "'", "''" } else { $null }
    $waitType = if ($Event.wait_type) { $Event.wait_type -replace "'", "''" } else { $null }
    $compType = if ($Event.component_type) { $Event.component_type -replace "'", "''" } else { $null }
    $compState = if ($Event.component_state) { $Event.component_state -replace "'", "''" } else { $null }
    $sourceFileSafe = if ($SourceFile) { $SourceFile -replace "'", "''" } else { $null }
    
    $rawXmlSafe = $Event.raw_event_xml -replace "'", "''"
    
    $query = @"
INSERT INTO ServerOps.Activity_XE_SystemHealth (
    server_id, server_name, event_timestamp, event_type,
    session_id, error_code, calling_api_name,
    client_hostname, client_app_name, os_error, login_time_ms,
    wait_type, duration_ms, signal_duration_ms,
    component_type, component_state,
    raw_event_xml, source_file, source_offset
)
VALUES (
    $ServerId,
    '$serverNameSafe',
    '$($Event.event_timestamp.ToString("yyyy-MM-dd HH:mm:ss.fff"))',
    '$($Event.event_type)',
    $(if ($Event.session_id) { $Event.session_id } else { "NULL" }),
    $(if ($Event.error_code) { $Event.error_code } else { "NULL" }),
    $(if ($callingApi) { "'$callingApi'" } else { "NULL" }),
    $(if ($clientHost) { "'$clientHost'" } else { "NULL" }),
    $(if ($clientApp) { "'$clientApp'" } else { "NULL" }),
    $(if ($Event.os_error) { $Event.os_error } else { "NULL" }),
    $(if ($Event.login_time_ms) { $Event.login_time_ms } else { "NULL" }),
    $(if ($waitType) { "'$waitType'" } else { "NULL" }),
    $(if ($Event.duration_ms) { $Event.duration_ms } else { "NULL" }),
    $(if ($Event.signal_duration_ms) { $Event.signal_duration_ms } else { "NULL" }),
    $(if ($compType) { "'$compType'" } else { "NULL" }),
    $(if ($compState) { "'$compState'" } else { "NULL" }),
    '$rawXmlSafe',
    $(if ($sourceFileSafe) { "'$sourceFileSafe'" } else { "NULL" }),
    $SourceOffset
)
"@
    
    return Invoke-SqlNonQuery -Query $query
}

# ========================================
# AG HEALTH FUNCTIONS (AlwaysOn_health)
# ========================================

function Parse-AGHealthEvent {
    <#
    .SYNOPSIS
        Parses an AlwaysOn_health XE event XML into a hashtable of values.
        Handles multiple event types: state changes, errors, DDL operations.
    #>
    param([string]$EventXml)
    
    try {
        $xml = [xml]$EventXml
        $event = $xml.event
        
        $parsed = @{
            event_timestamp = [DateTime]::Parse($event.timestamp)
            event_type = $event.name
            
            # State change fields
            previous_state = $null
            current_state = $null
            
            # AG/Replica/Database context
            availability_group_name = $null
            availability_replica_name = $null
            database_name = $null
            
            # Error fields
            error_number = $null
            error_severity = $null
            error_message = $null
            
            # DDL fields
            ddl_action = $null
            ddl_phase = $null
            ddl_statement = $null
            
            # Raw XML
            raw_event_xml = $EventXml
        }
        
        # Parse data elements based on event type
        foreach ($data in $event.data) {
            $valueNode = $data.SelectSingleNode("value")
            $textNode = $data.SelectSingleNode("text")
            $textValue = if ($valueNode) { $valueNode.InnerText } else { $null }
            $textDesc = if ($textNode) { $textNode.InnerText } else { $null }
            
            switch ($data.name) {
                # State change events
                "previous_state" { 
                    $parsed.previous_state = if ($textDesc) { $textDesc } else { $textValue }
                }
                "current_state" { 
                    $parsed.current_state = if ($textDesc) { $textDesc } else { $textValue }
                }
                
                # AG/Replica context
                "availability_group_name" { $parsed.availability_group_name = $textValue }
                "availability_replica_name" { $parsed.availability_replica_name = $textValue }
                "database_name" { $parsed.database_name = $textValue }
                
                # Error events
                "error_number" { 
                    if ($textValue) { 
                        $parsed.error_number = [long]$textValue 
                    }
                }
                "severity" { 
                    if ($textValue) { 
                        $parsed.error_severity = [int]$textValue 
                    }
                }
                "message" { $parsed.error_message = $textValue }
                
                # DDL events
                "ddl_action" { 
                    $parsed.ddl_action = if ($textDesc) { $textDesc } else { $textValue }
                }
                "ddl_phase" { 
                    $parsed.ddl_phase = if ($textDesc) { $textDesc } else { $textValue }
                }
                "statement" { $parsed.ddl_statement = $textValue }
            }
        }
        
        return $parsed
    }
    catch {
        Write-Log "    Failed to parse AGHealth event: $_" "WARN"
        return $null
    }
}

function Insert-AGHealthEvent {
    param(
        [int]$ServerId,
        [string]$ServerName,
        [string]$SessionName,
        [hashtable]$Event,
        [string]$SourceFile,
        [long]$SourceOffset,
        [bool]$RetainRawXml
    )
    
    # Escape single quotes for SQL
    $serverNameSafe = $ServerName -replace "'", "''"
    $prevState = if ($Event.previous_state) { $Event.previous_state -replace "'", "''" } else { $null }
    $currState = if ($Event.current_state) { $Event.current_state -replace "'", "''" } else { $null }
    $agName = if ($Event.availability_group_name) { $Event.availability_group_name -replace "'", "''" } else { $null }
    $replicaName = if ($Event.availability_replica_name) { $Event.availability_replica_name -replace "'", "''" } else { $null }
    $dbName = if ($Event.database_name) { $Event.database_name -replace "'", "''" } else { $null }
    $errMsg = if ($Event.error_message) { $Event.error_message -replace "'", "''" } else { $null }
    $ddlAction = if ($Event.ddl_action) { $Event.ddl_action -replace "'", "''" } else { $null }
    $ddlPhase = if ($Event.ddl_phase) { $Event.ddl_phase -replace "'", "''" } else { $null }
    $ddlStmt = if ($Event.ddl_statement) { $Event.ddl_statement -replace "'", "''" } else { $null }
    $sourceFileSafe = if ($SourceFile) { $SourceFile -replace "'", "''" } else { $null }
    
    # Handle raw XML based on config flag
    $rawXmlValue = "NULL"
    if ($RetainRawXml -and $Event.raw_event_xml) {
        $rawXmlSafe = $Event.raw_event_xml -replace "'", "''"
        $rawXmlValue = "'$rawXmlSafe'"
    }
    
    $query = @"
INSERT INTO ServerOps.Activity_XE_AGHealth (
    server_id, server_name, event_timestamp, event_type, session_name,
    previous_state, current_state,
    availability_group_name, availability_replica_name, database_name,
    error_number, error_severity, error_message,
    ddl_action, ddl_phase, ddl_statement,
    raw_event_xml, source_file, source_offset
)
VALUES (
    $ServerId,
    '$serverNameSafe',
    '$($Event.event_timestamp.ToString("yyyy-MM-dd HH:mm:ss.fff"))',
    '$($Event.event_type)',
    '$SessionName',
    $(if ($prevState) { "'$prevState'" } else { "NULL" }),
    $(if ($currState) { "'$currState'" } else { "NULL" }),
    $(if ($agName) { "'$agName'" } else { "NULL" }),
    $(if ($replicaName) { "'$replicaName'" } else { "NULL" }),
    $(if ($dbName) { "'$dbName'" } else { "NULL" }),
    $(if ($Event.error_number) { $Event.error_number } else { "NULL" }),
    $(if ($Event.error_severity) { $Event.error_severity } else { "NULL" }),
    $(if ($errMsg) { "'$errMsg'" } else { "NULL" }),
    $(if ($ddlAction) { "'$ddlAction'" } else { "NULL" }),
    $(if ($ddlPhase) { "'$ddlPhase'" } else { "NULL" }),
    $(if ($ddlStmt) { "'$ddlStmt'" } else { "NULL" }),
    $rawXmlValue,
    $(if ($sourceFileSafe) { "'$sourceFileSafe'" } else { "NULL" }),
    $SourceOffset
)
"@
    
    return Invoke-SqlNonQuery -Query $query
}

# ========================================
# MAIN SCRIPT
# ========================================

$scriptStart = Get-Date

Write-Log "========================================"
Write-Log "xFACts XE Event Collection"
Write-Log "========================================"

# ----------------------------------------
# Step 0: Check master switch
# ----------------------------------------
Write-Log "Checking server-level Activity enable flag..."

$serverCheck = Get-SqlData -Query @"
SELECT COUNT(*) AS enabled_count
FROM dbo.ServerRegistry
WHERE is_active = 1
  AND serverops_activity_enabled = 1
  AND server_type = 'SQL_SERVER'
"@

if (-not $serverCheck -or $serverCheck.enabled_count -eq 0) {
    Write-Log "Activity monitoring is not enabled on any server (serverops_activity_enabled = 0). Exiting." "WARN"
    exit 0
}

Write-Log "  Found $($serverCheck.enabled_count) server(s) with Activity monitoring enabled."

# ----------------------------------------
# Step 1: Get configuration values
# ----------------------------------------
$retainBlockedProcessXml = (Get-ConfigValue -SettingName "blocked_process_retain_raw_xml") -eq "1"
$retainAGHealthXml = (Get-ConfigValue -SettingName "aghealth_retain_raw_xml") -eq "1"
Write-Log "Config: blocked_process_retain_raw_xml = $retainBlockedProcessXml"
Write-Log "Config: aghealth_retain_raw_xml = $retainAGHealthXml"

# ----------------------------------------
# Step 2: Get list of servers to collect from
# ----------------------------------------
Write-Log "Retrieving server list..."

$servers = Get-SqlData -Query @"
SELECT 
    sr.server_id, 
    sr.server_name, 
    sr.instance_name,
    sr.server_type
FROM dbo.ServerRegistry sr
WHERE sr.is_active = 1 
  AND sr.serverops_activity_enabled = 1
  AND sr.server_type = 'SQL_SERVER'
ORDER BY sr.server_id
"@

if ($null -eq $servers -or @($servers).Count -eq 0) {
    Write-Log "No active servers configured for activity monitoring. Exiting." "WARN"
    exit 0
}

$serverCount = @($servers).Count
Write-Log "Found $serverCount server(s) to collect from."

# ----------------------------------------
# Step 3: Collect xFACts XE sessions from each server
# ----------------------------------------
$totalEvents = 0
$successCount = 0
$failedServers = @()

foreach ($server in $servers) {
    $serverName = $server.server_name
    $serverId = $server.server_id
    $serverNameSafe = $serverName -replace "'", "''"
    $instanceName = if ($server.instance_name -isnot [DBNull]) { $server.instance_name } else { $null }
    
    $sqlInstance = Get-SqlInstanceName -ServerName $serverName -InstanceName $instanceName
    
    Write-Log "----------------------------------------"
    Write-Log "Server: $serverName (ID: $serverId)"
    
    $serverSuccess = $true
    
    # Process each XE session for this server
    foreach ($session in $XESessions) {
        $sessionName = $session.Name
        $targetTable = $session.TargetTable
        $isAggregated = if ($session.IsAggregated) { $true } else { $false }
        
        Write-Log "  Session: $sessionName$(if ($isAggregated) { ' (aggregated)' } else { '' })"
        
        # Get last collection state for this server/session
        $stateQuery = @"
SELECT last_file_name, last_file_offset
FROM ServerOps.Activity_XE_CollectionState
WHERE server_id = $serverId AND session_name = '$sessionName'
"@
        $state = Get-SqlData -Query $stateQuery
        $lastFileName = if ($state -and $state.last_file_name -isnot [DBNull]) { $state.last_file_name } else { $null }
        $lastOffset = if ($state -and $state.last_file_offset -isnot [DBNull]) { $state.last_file_offset } else { $null }
        
        # Get the XE file path pattern
        # system_health uses a different function since it's a built-in session
        if ($sessionName -eq "system_health") {
            $filePath = Get-SystemHealthFilePath -Instance $sqlInstance
        }
        else {
            $filePath = Get-XEFilePath -Instance $sqlInstance -SessionName $sessionName
        }
        
        if ($null -eq $filePath) {
            Write-Log "    Could not determine XE file path - session may not be running" "WARN"
            
            # Update state as failed
            $updateQuery = @"
MERGE ServerOps.Activity_XE_CollectionState AS target
USING (SELECT $serverId AS server_id, '$sessionName' AS session_name) AS source
ON target.server_id = source.server_id AND target.session_name = source.session_name
WHEN MATCHED THEN
    UPDATE SET 
        last_collection_dttm = GETDATE(),
        last_collection_status = 'FAILED',
        events_collected = 0,
        modified_dttm = GETDATE(),
        modified_by = 'Collect-XEEvents.ps1'
WHEN NOT MATCHED THEN
    INSERT (server_id, server_name, session_name, last_collection_dttm, last_collection_status, events_collected)
    VALUES (source.server_id, '$serverNameSafe', source.session_name, GETDATE(), 'FAILED', 0);
"@
            Invoke-SqlNonQuery -Query $updateQuery | Out-Null
            continue
        }
        
        Write-Log "    File pattern: $filePath"
        Write-Log "    Last offset: $(if ($lastOffset) { $lastOffset } else { 'None (initial collection)' })"
        
        # Build query to read XE events
        if ($lastFileName -and $lastOffset) {
            $xeQuery = @"
SELECT 
    event_data,
    file_name,
    file_offset
FROM sys.fn_xe_file_target_read_file('$filePath', NULL, '$lastFileName', $lastOffset)
ORDER BY file_name, file_offset
"@
        }
        else {
            $xeQuery = @"
SELECT 
    event_data,
    file_name,
    file_offset
FROM sys.fn_xe_file_target_read_file('$filePath', NULL, NULL, NULL)
ORDER BY file_name, file_offset
"@
        }
        
        try {
            $events = Get-SqlData -Query $xeQuery -Instance $sqlInstance -DatabaseName "master" -MaxCharLength 2147483647
            
            if ($null -eq $events -or @($events).Count -eq 0) {
                Write-Log "    No new events found"
                
                # Update collection state
                $updateQuery = @"
MERGE ServerOps.Activity_XE_CollectionState AS target
USING (SELECT $serverId AS server_id, '$sessionName' AS session_name) AS source
ON target.server_id = source.server_id AND target.session_name = source.session_name
WHEN MATCHED THEN
    UPDATE SET 
        last_collection_dttm = GETDATE(),
        last_collection_status = 'NO_DATA',
        events_collected = 0,
        modified_dttm = GETDATE(),
        modified_by = 'Collect-XEEvents.ps1'
WHEN NOT MATCHED THEN
    INSERT (server_id, server_name, session_name, last_collection_dttm, last_collection_status, events_collected)
    VALUES (source.server_id, '$serverNameSafe', source.session_name, GETDATE(), 'NO_DATA', 0);
"@
                Invoke-SqlNonQuery -Query $updateQuery | Out-Null
                continue
            }
            
            $eventCount = @($events).Count
            Write-Log "    Found $eventCount event(s) to process"
            
            $sessionEvents = 0
            $parseErrors = 0
            $lastFile = $null
            $lastOff = $null
            
            # For aggregated sessions, collect all parsed events first
            if ($isAggregated) {
                $parsedEvents = @()
                
                foreach ($event in $events) {
                    $eventData = $event.event_data
                    $fileName = $event.file_name
                    $fileOffset = $event.file_offset
                    
                    # Always track position
                    $lastFile = $fileName
                    $lastOff = $fileOffset
                    
                    # Parse event
                    $parsed = $null
                    switch ($sessionName) {
                        "xFACts_LS_Inbound" {
                            $parsed = Parse-LSInboundEvent -EventXml $eventData
                        }
                        "xFACts_LS_Outbound" {
                            $parsed = Parse-LSOutboundEvent -EventXml $eventData
                        }
                    }
                    
                    if ($null -ne $parsed) {
                        $parsedEvents += $parsed
                    }
                    else {
                        $parseErrors++
                    }
                }
                
                # Aggregate and insert
                if ($parsedEvents.Count -gt 0) {
                    $aggregatedRecords = Aggregate-LSEvents -ParsedEvents $parsedEvents
                    
                    foreach ($aggRecord in $aggregatedRecords) {
                        $result = $false
                        switch ($sessionName) {
                            "xFACts_LS_Inbound" {
                                $result = Insert-LSInboundEventAggregated -ServerId $serverId -ServerName $serverName -SessionName $sessionName -AggregatedEvent $aggRecord
                            }
                            "xFACts_LS_Outbound" {
                                $result = Insert-LSOutboundEventAggregated -ServerId $serverId -ServerName $serverName -SessionName $sessionName -AggregatedEvent $aggRecord
                            }
                        }
                        if ($result) {
                            $sessionEvents++
                        }
                    }
                    
                    Write-Log "    Aggregated $eventCount events into $sessionEvents record(s)"
                }
            }
            else {
                # Non-aggregated: process one at a time (existing behavior)
                foreach ($event in $events) {
                    $eventData = $event.event_data
                    $fileName = $event.file_name
                    $fileOffset = $event.file_offset
                    
                    # Always track position
                    $lastFile = $fileName
                    $lastOff = $fileOffset
                    
                    # Parse and insert based on session type
                    $result = $false
                    
                    switch ($sessionName) {
                        "xFACts_LongQueries" {
                            $parsed = Parse-LRQEvent -EventXml $eventData
                            if ($null -ne $parsed) {
                                $result = Insert-LRQEvent -ServerId $serverId -ServerName $serverName -SessionName $sessionName -Event $parsed -SourceFile $fileName -SourceOffset $fileOffset
                            }
                        }
                        "xFACts_BlockedProcess" {
                            $parsed = Parse-BlockedProcessEvent -EventXml $eventData
                            if ($null -ne $parsed) {
                                $result = Insert-BlockedProcessEvent -ServerId $serverId -ServerName $serverName -SessionName $sessionName -Event $parsed -SourceFile $fileName -SourceOffset $fileOffset -RetainRawXml $retainBlockedProcessXml
                            }
                        }
                        "xFACts_Deadlock" {
                            $parsed = Parse-DeadlockEvent -EventXml $eventData
                            if ($null -ne $parsed) {
                                $result = Insert-DeadlockEvent -ServerId $serverId -ServerName $serverName -SessionName $sessionName -Event $parsed -SourceFile $fileName -SourceOffset $fileOffset
                            }
                        }
                        "system_health" {
                            $parsed = Parse-SystemHealthEvent -EventXml $eventData
                            if ($null -ne $parsed) {
                                $result = Insert-SystemHealthEvent -ServerId $serverId -ServerName $serverName -SessionName $sessionName -Event $parsed -SourceFile $fileName -SourceOffset $fileOffset
                            }
                        }
                        "xFACts_Tracking" {
                            $parsed = Parse-xFACtsEvent -EventXml $eventData
                            if ($null -ne $parsed) {
                                $result = Insert-xFACtsEvent -ServerId $serverId -ServerName $serverName -SessionName $sessionName -Event $parsed -SourceFile $fileName -SourceOffset $fileOffset
                            }
                        }
                    }
                    
                    if ($result) {
                        $sessionEvents++
                    }
                    elseif ($null -eq $parsed) {
                        $parseErrors++
                    }
                }
                
                Write-Log "    Inserted $sessionEvents event(s)"
            }
            
            if ($parseErrors -gt 0) {
                Write-Log "    Skipped $parseErrors event(s) due to parse errors" "WARN"
            }
            $totalEvents += $sessionEvents
            
            # Update collection state
            if ($lastFile -and $lastOff) {
                $lastFileSafe = $lastFile -replace "'", "''"
                $updateQuery = @"
MERGE ServerOps.Activity_XE_CollectionState AS target
USING (SELECT $serverId AS server_id, '$sessionName' AS session_name) AS source
ON target.server_id = source.server_id AND target.session_name = source.session_name
WHEN MATCHED THEN
    UPDATE SET 
        first_file_offset = $(if ($lastOffset) { $lastOffset } else { 0 }),
        last_file_name = '$lastFileSafe',
        last_file_offset = $lastOff,
        last_collection_dttm = GETDATE(),
        last_collection_status = 'SUCCESS',
        events_collected = $sessionEvents,
        modified_dttm = GETDATE(),
        modified_by = 'Collect-XEEvents.ps1'
WHEN NOT MATCHED THEN
    INSERT (server_id, server_name, session_name, first_file_offset, last_file_name, last_file_offset, last_collection_dttm, last_collection_status, events_collected)
    VALUES (source.server_id, '$serverNameSafe', source.session_name, 0, '$lastFileSafe', $lastOff, GETDATE(), 'SUCCESS', $sessionEvents);
"@
                Invoke-SqlNonQuery -Query $updateQuery | Out-Null
            }
        }
        catch {
            Write-Log "    FAILED: $($_.Exception.Message)" "ERROR"
            $serverSuccess = $false
            
            # Update collection state with failure
            $updateQuery = @"
MERGE ServerOps.Activity_XE_CollectionState AS target
USING (SELECT $serverId AS server_id, '$sessionName' AS session_name) AS source
ON target.server_id = source.server_id AND target.session_name = source.session_name
WHEN MATCHED THEN
    UPDATE SET 
        last_collection_dttm = GETDATE(),
        last_collection_status = 'FAILED',
        events_collected = 0,
        modified_dttm = GETDATE(),
        modified_by = 'Collect-XEEvents.ps1'
WHEN NOT MATCHED THEN
    INSERT (server_id, server_name, session_name, last_collection_dttm, last_collection_status, events_collected)
    VALUES (source.server_id, '$serverNameSafe', source.session_name, GETDATE(), 'FAILED', 0);
"@
            Invoke-SqlNonQuery -Query $updateQuery | Out-Null
        }
    }
    
    if ($serverSuccess) {
        $successCount++
    }
    else {
        $failedServers += $serverName
    }
}

# ----------------------------------------
# Step 4: Collect AlwaysOn_health from AG servers
# ----------------------------------------
Write-Log "----------------------------------------"
Write-Log "System Session Collection: AlwaysOn_health"
Write-Log "----------------------------------------"

# Get AG servers only (DM-PROD-DB, DM-PROD-REP)
$agServers = Get-SqlData -Query @"
SELECT 
    sr.server_id, 
    sr.server_name, 
    sr.instance_name
FROM dbo.ServerRegistry sr
WHERE sr.is_active = 1 
  AND sr.server_name IN ('DM-PROD-DB', 'DM-PROD-REP')
ORDER BY sr.server_id
"@

if ($null -eq $agServers -or @($agServers).Count -eq 0) {
    Write-Log "No AG servers found for AlwaysOn_health collection." "WARN"
}
else {
    $sessionName = "AlwaysOn_health"
    
    foreach ($server in $agServers) {
        $serverName = $server.server_name
        $serverId = $server.server_id
        $serverNameSafe = $serverName -replace "'", "''"
        $instanceName = if ($server.instance_name -isnot [DBNull]) { $server.instance_name } else { $null }
        
        $sqlInstance = Get-SqlInstanceName -ServerName $serverName -InstanceName $instanceName
        
        Write-Log "Server: $serverName (ID: $serverId)"
        Write-Log "  Session: $sessionName"
        
        # Get last collection state for this server/session
        $stateQuery = @"
SELECT last_file_name, last_file_offset
FROM ServerOps.Activity_XE_CollectionState
WHERE server_id = $serverId AND session_name = '$sessionName'
"@
        $state = Get-SqlData -Query $stateQuery
        $lastFileName = if ($state -and $state.last_file_name -isnot [DBNull]) { $state.last_file_name } else { $null }
        $lastOffset = if ($state -and $state.last_file_offset -isnot [DBNull]) { $state.last_file_offset } else { $null }
        
        # AlwaysOn_health uses default LOG directory - get the file path
        $filePath = Get-XEFilePath -Instance $sqlInstance -SessionName $sessionName
        
        if ($null -eq $filePath) {
            Write-Log "    Could not determine XE file path - session may not be running" "WARN"
            
            # Update state as failed
            $updateQuery = @"
MERGE ServerOps.Activity_XE_CollectionState AS target
USING (SELECT $serverId AS server_id, '$sessionName' AS session_name) AS source
ON target.server_id = source.server_id AND target.session_name = source.session_name
WHEN MATCHED THEN
    UPDATE SET 
        last_collection_dttm = GETDATE(),
        last_collection_status = 'FAILED',
        events_collected = 0,
        modified_dttm = GETDATE(),
        modified_by = 'Collect-XEEvents.ps1'
WHEN NOT MATCHED THEN
    INSERT (server_id, server_name, session_name, last_collection_dttm, last_collection_status, events_collected)
    VALUES (source.server_id, '$serverNameSafe', source.session_name, GETDATE(), 'FAILED', 0);
"@
            Invoke-SqlNonQuery -Query $updateQuery | Out-Null
            continue
        }
        
        Write-Log "    File pattern: $filePath"
        Write-Log "    Last offset: $(if ($lastOffset) { $lastOffset } else { 'None (initial collection)' })"
        
        # Build query to read XE events
        if ($lastFileName -and $lastOffset) {
            $xeQuery = @"
SELECT 
    event_data,
    file_name,
    file_offset
FROM sys.fn_xe_file_target_read_file('$filePath', NULL, '$lastFileName', $lastOffset)
ORDER BY file_name, file_offset
"@
        }
        else {
            $xeQuery = @"
SELECT 
    event_data,
    file_name,
    file_offset
FROM sys.fn_xe_file_target_read_file('$filePath', NULL, NULL, NULL)
ORDER BY file_name, file_offset
"@
        }
        
        try {
            $events = Get-SqlData -Query $xeQuery -Instance $sqlInstance -DatabaseName "master" -MaxCharLength 2147483647
            
            if ($null -eq $events -or @($events).Count -eq 0) {
                Write-Log "    No new events found"
                
                # Update collection state
                $updateQuery = @"
MERGE ServerOps.Activity_XE_CollectionState AS target
USING (SELECT $serverId AS server_id, '$sessionName' AS session_name) AS source
ON target.server_id = source.server_id AND target.session_name = source.session_name
WHEN MATCHED THEN
    UPDATE SET 
        last_collection_dttm = GETDATE(),
        last_collection_status = 'NO_DATA',
        events_collected = 0,
        modified_dttm = GETDATE(),
        modified_by = 'Collect-XEEvents.ps1'
WHEN NOT MATCHED THEN
    INSERT (server_id, server_name, session_name, last_collection_dttm, last_collection_status, events_collected)
    VALUES (source.server_id, '$serverNameSafe', source.session_name, GETDATE(), 'NO_DATA', 0);
"@
                Invoke-SqlNonQuery -Query $updateQuery | Out-Null
                continue
            }
            
            $eventCount = @($events).Count
            Write-Log "    Found $eventCount event(s) to process"
            
            $sessionEvents = 0
            $parseErrors = 0
            $lastFile = $null
            $lastOff = $null
            
            foreach ($event in $events) {
                $eventData = $event.event_data
                $fileName = $event.file_name
                $fileOffset = $event.file_offset
                
                # Always track position
                $lastFile = $fileName
                $lastOff = $fileOffset
                
                # Parse and insert AGHealth event
                $parsed = Parse-AGHealthEvent -EventXml $eventData
                if ($null -ne $parsed) {
                    $result = Insert-AGHealthEvent -ServerId $serverId -ServerName $serverName -SessionName $sessionName -Event $parsed -SourceFile $fileName -SourceOffset $fileOffset -RetainRawXml $retainAGHealthXml
                    if ($result) {
                        $sessionEvents++
                    }
                }
                else {
                    $parseErrors++
                }
            }
            
            Write-Log "    Inserted $sessionEvents event(s)"
            if ($parseErrors -gt 0) {
                Write-Log "    Skipped $parseErrors event(s) due to parse errors" "WARN"
            }
            $totalEvents += $sessionEvents
            
            # Update collection state
            if ($lastFile -and $lastOff) {
                $lastFileSafe = $lastFile -replace "'", "''"
                $updateQuery = @"
MERGE ServerOps.Activity_XE_CollectionState AS target
USING (SELECT $serverId AS server_id, '$sessionName' AS session_name) AS source
ON target.server_id = source.server_id AND target.session_name = source.session_name
WHEN MATCHED THEN
    UPDATE SET 
        first_file_offset = $(if ($lastOffset) { $lastOffset } else { 0 }),
        last_file_name = '$lastFileSafe',
        last_file_offset = $lastOff,
        last_collection_dttm = GETDATE(),
        last_collection_status = 'SUCCESS',
        events_collected = $sessionEvents,
        modified_dttm = GETDATE(),
        modified_by = 'Collect-XEEvents.ps1'
WHEN NOT MATCHED THEN
    INSERT (server_id, server_name, session_name, first_file_offset, last_file_name, last_file_offset, last_collection_dttm, last_collection_status, events_collected)
    VALUES (source.server_id, '$serverNameSafe', source.session_name, 0, '$lastFileSafe', $lastOff, GETDATE(), 'SUCCESS', $sessionEvents);
"@
                Invoke-SqlNonQuery -Query $updateQuery | Out-Null
            }
        }
        catch {
            Write-Log "    FAILED: $($_.Exception.Message)" "ERROR"
            
            # Update collection state with failure
            $updateQuery = @"
MERGE ServerOps.Activity_XE_CollectionState AS target
USING (SELECT $serverId AS server_id, '$sessionName' AS session_name) AS source
ON target.server_id = source.server_id AND target.session_name = source.session_name
WHEN MATCHED THEN
    UPDATE SET 
        last_collection_dttm = GETDATE(),
        last_collection_status = 'FAILED',
        events_collected = 0,
        modified_dttm = GETDATE(),
        modified_by = 'Collect-XEEvents.ps1'
WHEN NOT MATCHED THEN
    INSERT (server_id, server_name, session_name, last_collection_dttm, last_collection_status, events_collected)
    VALUES (source.server_id, '$serverNameSafe', source.session_name, GETDATE(), 'FAILED', 0);
"@
            Invoke-SqlNonQuery -Query $updateQuery | Out-Null
        }
    }
}

# ----------------------------------------
# Summary
# ----------------------------------------
Write-Log "========================================"
Write-Log "Collection Complete"
Write-Log "  Servers attempted: $serverCount"
Write-Log "  Servers fully successful: $successCount"
Write-Log "  Servers with failures: $($failedServers.Count)"
Write-Log "  Total events collected: $totalEvents"
Write-Log "========================================"

if ($failedServers.Count -gt 0) {
    Write-Log "Servers with failures: $($failedServers -join ', ')" "WARN"
}

# ----------------------------------------
# Orchestrator Callback
# ----------------------------------------
if ($TaskId -gt 0) {
    $totalMs = [int]((New-TimeSpan -Start $scriptStart -End (Get-Date)).TotalMilliseconds)
    $outputMsg = "Servers: $successCount/$serverCount, Events: $totalEvents"
    Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
        -TaskId $TaskId -ProcessId $ProcessId `
        -Status "SUCCESS" -DurationMs $totalMs `
        -Output $outputMsg
}

exit 0
<#
.SYNOPSIS
    xFACts - Replication Health Collection

.DESCRIPTION
    xFACts - ServerOps.Replication
    Script: Collect-ReplicationHealth.ps1
    Version: Tracked in dbo.System_Metadata (component: ServerOps.Replication)

    Collects replication health metrics from the distribution database on 
    DM-PROD-DB and imports them into xFACts Replication monitoring tables.

    Collection layers:
    - Registry sync: discovers publications/subscribers from distribution DB
    - Agent health + queue depth + throughput: per-agent snapshots each cycle
    - Event detection: state change detection via comparison to previous snapshot
    - Tracer tokens: end-to-end latency measurement (configurable interval)

    Source data comes from:
    - distribution.dbo.MSdistribution_agents (agent catalog)
    - distribution.dbo.MSdistribution_history (agent health + throughput)
    - distribution.dbo.MSlogreader_agents / MSlogreader_history (Log Reader)
    - distribution.dbo.MSsubscriber_info (registered subscriber names)
    - distribution.dbo.MSpublications (publication metadata)
    - distribution.dbo.sp_replmonitorsubscriptionpendingcmds (queue depth)
    - crs5_oltp.dbo.sp_posttracertoken / sp_helptracertokenhistory (tracer tokens)

    NOTE: The previous inline Get-SqlData/Invoke-SqlNonQuery defined
    MaxCharLength 2147483647 as a blanket default. The shared functions omit
    MaxCharLength by default. This is intentional — all queries in this script
    return numeric/short-string data (agent metadata, run status, queue depths,
    latency values). XML stats blocks in agent_message are replaced with a
    summary string since that data is redundant with the structured throughput
    columns on the same row.

    CHANGELOG
    ---------
    2026-03-11  Migrated to Initialize-XFActsScript shared infrastructure
                Removed inline Write-Log, Get-SqlData, Invoke-SqlNonQuery
                Updated -DB parameter refs to -DatabaseName for cross-server calls
                Updated header to component-level versioning format
                Removed agent_message 512-char truncation cap (column widened to 1000)
    2026-02-18  Initial implementation
                Registry discovery from distribution database
                Agent health + queue depth + throughput collection
                Log Reader agent collection
                Event detection via state change comparison
                Tracer token posting and result collection
                BIDATA build correlation for event tagging
                Orchestrator v2 FIRE_AND_FORGET integration

.PARAMETER ServerInstance
    SQL Server instance name for xFACts database (default: AVG-PROD-LSNR)

.PARAMETER Database
    Database name (default: xFACts)

.PARAMETER DistributorInstance
    SQL Server instance hosting the distribution database (default: DM-PROD-DB)

.PARAMETER PublisherDB
    Published database name (default: crs5_oltp)

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
2. The service account running this script must have SQL access to DM-PROD-DB
   (distribution database) and to the publisher database (crs5_oltp).
3. xFACts-OrchestratorFunctions.ps1 must be in the same directory.
================================================================================
#>

[CmdletBinding()]
param(
    [string]$ServerInstance = "AVG-PROD-LSNR",
    [string]$Database = "xFACts",
    [string]$DistributorInstance = "DM-PROD-DB",
    [string]$PublisherDB = "crs5_oltp",
    [switch]$Execute,
    [switch]$Force,
    [long]$TaskId = 0,
    [int]$ProcessId = 0
)

# ============================================================================
# STANDARD INITIALIZATION
# ============================================================================

. "$PSScriptRoot\xFACts-OrchestratorFunctions.ps1"

Initialize-XFActsScript -ScriptName 'Collect-ReplicationHealth' `
    -ServerInstance $ServerInstance -Database $Database -Execute:$Execute

# Hard exit without -Execute — no preview mode for this collector
if (-not $Execute) {
    exit 0
}

$scriptStart = Get-Date

# ========================================
# FUNCTIONS
# ========================================

function Get-ConfigValue {
    param([string]$SettingName)
    
    $query = "SELECT setting_value FROM dbo.GlobalConfig WHERE module_name = 'ServerOps' AND category = 'Replication' AND setting_name = '$SettingName' AND is_active = 1"
    $result = Get-SqlData -Query $query
    
    if ($null -ne $result) {
        return $result.setting_value
    }
    return $null
}

function Get-RunStatusDesc {
    param([int]$RunStatus)
    
    switch ($RunStatus) {
        1 { return "Started" }
        2 { return "Running" }
        3 { return "Idle" }
        4 { return "Retrying" }
        5 { return "Failed" }
        6 { return "Stopped" }
        default { return "Unknown" }
    }
}

function Safe-SqlString {
    param([string]$Value, [int]$MaxLength = 0)
    
    if ($null -eq $Value -or $Value -is [DBNull]) { return "NULL" }
    
    $cleaned = $Value -replace "'", "''"
    if ($MaxLength -gt 0 -and $cleaned.Length -gt $MaxLength) {
        $cleaned = $cleaned.Substring(0, $MaxLength)
    }
    return "'$cleaned'"
}

function Safe-SqlInt {
    param($Value)
    
    if ($null -eq $Value -or $Value -is [DBNull]) { return "NULL" }
    return [int]$Value
}

function Safe-SqlFloat {
    param($Value)
    
    if ($null -eq $Value -or $Value -is [DBNull]) { return "NULL" }
    return [float]$Value
}

function Safe-SqlSmallInt {
    param($Value)
    
    if ($null -eq $Value -or $Value -is [DBNull]) { return "NULL" }
    return [int]$Value
}

function Safe-SqlDateTime {
    param($Value)
    
    if ($null -eq $Value -or $Value -is [DBNull]) { return "NULL" }
    return "'" + ([datetime]$Value).ToString("yyyy-MM-dd HH:mm:ss.fff") + "'"
}

Write-Log "========================================"
Write-Log "Replication Health Collection Starting"
Write-Log "  xFACts: $ServerInstance / $Database"
Write-Log "  Distributor: $DistributorInstance"
Write-Log "  Publisher DB: $PublisherDB"
Write-Log "========================================"

# ========================================
# STEP 1: REGISTRY DISCOVERY
# ========================================
Write-Log "Step 1: Registry Discovery"

# --- 1a: Query distribution database for current publications ---
# Subscriber names are resolved via MSsubscriber_info using prefix matching against
# the agent name string, because MSdistribution_agents.subscriber_id maps to linked
# server aliases in master.sys.servers which may differ from the registered subscriber name.
$discoveryQuery = @"
SELECT 
    a.id AS agent_id,
    a.name AS agent_name,
    a.publisher_db,
    a.publication,
    a.subscriber_id,
    a.subscriber_db,
    a.subscription_type,
    CASE a.subscription_type 
        WHEN 0 THEN 'Push' 
        WHEN 1 THEN 'Pull' 
    END AS subscription_type_desc,
    p.publisher_id,
    p.publication_id,
    p.publication_type,
    CASE p.publication_type 
        WHEN 0 THEN 'Transactional' 
        WHEN 1 THEN 'Snapshot' 
        WHEN 2 THEN 'Merge' 
    END AS publication_type_desc,
    si.subscriber AS subscriber_name
FROM distribution.dbo.MSdistribution_agents a
INNER JOIN distribution.dbo.MSpublications p 
    ON p.publication = a.publication 
    AND p.publisher_db = a.publisher_db
INNER JOIN distribution.dbo.MSsubscriber_info si
    ON a.name LIKE '%' + LEFT(si.subscriber, CHARINDEX('.', si.subscriber + '.') - 1) + '%'
WHERE a.subscriber_db NOT LIKE '%virtual%'
"@

$distributionAgents = Get-SqlData -Query $discoveryQuery -Instance $DistributorInstance -DatabaseName "distribution"

if ($null -eq $distributionAgents) {
    Write-Log "Failed to query distribution database. Exiting." "ERROR"
    if ($TaskId -gt 0) {
        $totalMs = [int]((New-TimeSpan -Start $scriptStart -End (Get-Date)).TotalMilliseconds)
        Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
            -TaskId $TaskId -ProcessId $ProcessId `
            -Status "FAILED" -DurationMs $totalMs `
            -ErrorMessage "Failed to query distribution database"
    }
    exit 1
}

# --- 1b: Query for Log Reader agents ---
$logReaderQuery = @"
SELECT 
    a.id AS agent_id,
    a.name AS agent_name,
    a.publisher_db
FROM distribution.dbo.MSlogreader_agents a
"@
$logReaderAgents = Get-SqlData -Query $logReaderQuery -Instance $DistributorInstance -DatabaseName "distribution"

# --- 1c: Load existing registry ---
$registryQuery = @"
SELECT 
    publication_registry_id,
    publication_name,
    subscriber_name,
    subscriber_db,
    agent_type,
    agent_id,
    is_dropped
FROM ServerOps.Replication_PublicationRegistry
"@
$existingRegistry = Get-SqlData -Query $registryQuery

# Build lookup by natural key
$registryLookup = @{}
if ($null -ne $existingRegistry) {
    foreach ($reg in @($existingRegistry)) {
        $key = "$($reg.publication_name)|$($reg.subscriber_name)|$($reg.subscriber_db)|$($reg.agent_type)"
        $registryLookup[$key] = $reg
    }
}

# --- 1d: Sync distribution agents to registry ---
$newCount = 0
$updateCount = 0
$agentCount = 0

if ($null -ne $distributionAgents) {
    $agentList = @($distributionAgents)
    
    foreach ($agent in $agentList) {
        $agentCount++
        $subscriberName = $agent.subscriber_name
        
        $key = "$($agent.publication)|$subscriberName|$($agent.subscriber_db)|Distribution"
        
        if ($registryLookup.ContainsKey($key)) {
            # Update existing entry
            $regId = $registryLookup[$key].publication_registry_id
            $wasDropped = $registryLookup[$key].is_dropped
            
            $updateQuery = @"
UPDATE ServerOps.Replication_PublicationRegistry
SET agent_id = $(Safe-SqlInt $agent.agent_id),
    agent_name = $(Safe-SqlString $agent.agent_name 100),
    publisher_id = $(Safe-SqlSmallInt $agent.publisher_id),
    publication_id = $(Safe-SqlInt $agent.publication_id),
    publication_type = $(Safe-SqlInt $agent.publication_type),
    publication_type_desc = $(Safe-SqlString $agent.publication_type_desc 20),
    subscriber_id = $(Safe-SqlSmallInt $agent.subscriber_id),
    subscription_type = $(Safe-SqlInt $agent.subscription_type),
    subscription_type_desc = $(Safe-SqlString $agent.subscription_type_desc 10),
    is_dropped = 0,
    dropped_detected_dttm = NULL,
    modified_dttm = GETDATE()
WHERE publication_registry_id = $regId
"@
            Invoke-SqlNonQuery -Query $updateQuery | Out-Null
            $updateCount++
            
            if ($wasDropped -eq $true) {
                Write-Log "  Reactivated: $($agent.publication) -> $subscriberName (was dropped)" "SUCCESS"
            }
        }
        else {
            # Insert new entry
            $insertQuery = @"
INSERT INTO ServerOps.Replication_PublicationRegistry (
    publisher_id, publisher_db, publication_id, publication_name,
    publication_type, publication_type_desc,
    subscriber_id, subscriber_name, subscriber_db,
    subscription_type, subscription_type_desc,
    agent_name, agent_id, agent_type
) VALUES (
    $(Safe-SqlSmallInt $agent.publisher_id),
    $(Safe-SqlString $agent.publisher_db 128),
    $(Safe-SqlInt $agent.publication_id),
    $(Safe-SqlString $agent.publication 128),
    $(Safe-SqlInt $agent.publication_type),
    $(Safe-SqlString $agent.publication_type_desc 20),
    $(Safe-SqlSmallInt $agent.subscriber_id),
    $(Safe-SqlString $subscriberName 128),
    $(Safe-SqlString $agent.subscriber_db 128),
    $(Safe-SqlInt $agent.subscription_type),
    $(Safe-SqlString $agent.subscription_type_desc 10),
    $(Safe-SqlString $agent.agent_name 100),
    $(Safe-SqlInt $agent.agent_id),
    'Distribution'
)
"@
            Invoke-SqlNonQuery -Query $insertQuery | Out-Null
            $newCount++
            Write-Log "  Discovered: $($agent.publication) -> $subscriberName ($($agent.subscription_type_desc))" "SUCCESS"
        }
    }
}

# --- 1e: Sync Log Reader agents to registry ---
if ($null -ne $logReaderAgents) {
    $lrList = @($logReaderAgents)
    
    foreach ($lr in $lrList) {
        # Log Reader uses publisher_db as both publication_name and subscriber fields (it doesn't have subscribers)
        $key = "$($lr.publisher_db)|$($lr.publisher_db)|$($lr.publisher_db)|LogReader"
        
        if ($registryLookup.ContainsKey($key)) {
            $regId = $registryLookup[$key].publication_registry_id
            
            $updateQuery = @"
UPDATE ServerOps.Replication_PublicationRegistry
SET agent_id = $(Safe-SqlInt $lr.agent_id),
    agent_name = $(Safe-SqlString $lr.agent_name 100),
    is_dropped = 0,
    dropped_detected_dttm = NULL,
    modified_dttm = GETDATE()
WHERE publication_registry_id = $regId
"@
            Invoke-SqlNonQuery -Query $updateQuery | Out-Null
            $updateCount++
        }
        else {
            $insertQuery = @"
INSERT INTO ServerOps.Replication_PublicationRegistry (
    publisher_db, publication_name,
    subscriber_name, subscriber_db,
    subscription_type, subscription_type_desc,
    agent_name, agent_id, agent_type
) VALUES (
    $(Safe-SqlString $lr.publisher_db 128),
    $(Safe-SqlString $lr.publisher_db 128),
    $(Safe-SqlString $lr.publisher_db 128),
    $(Safe-SqlString $lr.publisher_db 128),
    0, 'Push',
    $(Safe-SqlString $lr.agent_name 100),
    $(Safe-SqlInt $lr.agent_id),
    'LogReader'
)
"@
            Invoke-SqlNonQuery -Query $insertQuery | Out-Null
            $newCount++
            Write-Log "  Discovered Log Reader: $($lr.publisher_db)" "SUCCESS"
        }
    }
}

# --- 1f: Detect dropped publications ---
# Reload registry after sync
$registryQuery = @"
SELECT 
    publication_registry_id,
    publication_name,
    subscriber_name,
    subscriber_db,
    agent_type,
    agent_id,
    is_dropped
FROM ServerOps.Replication_PublicationRegistry
WHERE is_dropped = 0
"@
$currentRegistry = Get-SqlData -Query $registryQuery

if ($null -ne $currentRegistry) {
    $currentList = @($currentRegistry)
    
    # Build set of discovered agent_ids
    $discoveredAgentIds = @{}
    if ($null -ne $distributionAgents) {
        foreach ($a in @($distributionAgents)) { $discoveredAgentIds[$a.agent_id] = $true }
    }
    if ($null -ne $logReaderAgents) {
        foreach ($lr in @($logReaderAgents)) { $discoveredAgentIds[$lr.agent_id] = $true }
    }
    
    foreach ($reg in $currentList) {
        if ($null -ne $reg.agent_id -and $reg.agent_id -isnot [DBNull] -and -not $discoveredAgentIds.ContainsKey($reg.agent_id)) {
            $dropQuery = @"
UPDATE ServerOps.Replication_PublicationRegistry
SET is_dropped = 1,
    dropped_detected_dttm = GETDATE(),
    modified_dttm = GETDATE()
WHERE publication_registry_id = $($reg.publication_registry_id)
"@
            Invoke-SqlNonQuery -Query $dropQuery | Out-Null
            Write-Log "  Marked dropped: $($reg.publication_name) ($($reg.agent_type))" "WARN"
        }
    }
}

Write-Log "  Discovery complete: $newCount new, $updateCount updated"

# ========================================
# STEP 2: LOAD ACTIVE REGISTRY
# ========================================
# Reload full registry for use in subsequent steps
$activeRegistryQuery = @"
SELECT 
    publication_registry_id,
    publication_name,
    publisher_db,
    subscriber_name,
    subscriber_db,
    subscription_type,
    subscription_type_desc,
    agent_name,
    agent_id,
    agent_type,
    is_monitored,
    tracer_tokens_enabled
FROM ServerOps.Replication_PublicationRegistry
WHERE is_dropped = 0 AND is_monitored = 1
"@
$activeRegistry = Get-SqlData -Query $activeRegistryQuery

if ($null -eq $activeRegistry -or @($activeRegistry).Count -eq 0) {
    Write-Log "No active monitored publications found. Exiting." "WARN"
    if ($TaskId -gt 0) {
        $totalMs = [int]((New-TimeSpan -Start $scriptStart -End (Get-Date)).TotalMilliseconds)
        Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
            -TaskId $TaskId -ProcessId $ProcessId `
            -Status "SUCCESS" -DurationMs $totalMs `
            -Output "No active publications to monitor"
    }
    exit 0
}

$activeList = @($activeRegistry)
Write-Log "Step 2: Loaded $($activeList.Count) active registry entries"

# ========================================
# STEP 3: COLLECT AGENT HEALTH + THROUGHPUT
# ========================================
Write-Log "Step 3: Agent Health + Throughput Collection"

# Load previous snapshot for event detection (Step 4)
$previousSnapshotQuery = @"
SELECT 
    publication_registry_id,
    run_status,
    agent_message
FROM ServerOps.Replication_AgentHistory
WHERE collected_dttm = (
    SELECT MAX(collected_dttm) FROM ServerOps.Replication_AgentHistory
)
"@
$previousSnapshots = Get-SqlData -Query $previousSnapshotQuery

$previousLookup = @{}
if ($null -ne $previousSnapshots) {
    foreach ($ps in @($previousSnapshots)) {
        $previousLookup[$ps.publication_registry_id] = $ps
    }
}

$snapshotCount = 0
$eventCount = 0
$collectedDttm = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")

foreach ($reg in $activeList) {
    $regId = $reg.publication_registry_id
    $agentId = $reg.agent_id
    $agentType = $reg.agent_type
    
    # --- 3a: Get agent health + throughput from history table ---
    $historyTable = if ($agentType -eq 'LogReader') { 'MSlogreader_history' } else { 'MSdistribution_history' }
    
    $healthQuery = @"
SELECT TOP 1 
    runstatus,
    comments,
    [time],
    error_id,
    delivery_rate,
    delivered_transactions,
    delivered_commands,
    average_commands,
    delivery_latency
FROM distribution.dbo.$historyTable
WHERE agent_id = $agentId
ORDER BY [time] DESC
"@
    
    $health = Get-SqlData -Query $healthQuery -Instance $DistributorInstance -DatabaseName "distribution"
    
    if ($null -eq $health) {
        Write-Log "  No history found for $($reg.publication_name) ($agentType)" "WARN"
        continue
    }
    
    # --- 3b: Get queue depth (Distribution agents only) ---
    $pendingCmdCount = "NULL"
    $estimatedProcessingSeconds = "NULL"
    
    if ($agentType -eq 'Distribution') {
        $pendingQuery = @"
EXEC distribution.dbo.sp_replmonitorsubscriptionpendingcmds
    @publisher = '$DistributorInstance',
    @publisher_db = '$($reg.publisher_db)',
    @publication = '$($reg.publication_name)',
    @subscriber = '$($reg.subscriber_name -replace "'", "''")',
    @subscriber_db = '$($reg.subscriber_db)',
    @subscription_type = $($reg.subscription_type)
"@
        
        $pending = Get-SqlData -Query $pendingQuery -Instance $DistributorInstance -DatabaseName "distribution"
        
        if ($null -ne $pending) {
            $pendingCmdCount = Safe-SqlInt $pending.pendingcmdcount
            $estimatedProcessingSeconds = Safe-SqlInt $pending.estimatedprocesstime
        }
    }
    
    # --- 3c: Prepare agent message for storage ---
    $agentMessage = if ($null -ne $health.comments -and $health.comments -isnot [DBNull]) {
        $msg = $health.comments.ToString()
        # Skip XML stats blocks - redundant with structured throughput columns
        if ($msg.StartsWith('<stats')) {
            'Performance stats (XML)'
        }
        else {
            $msg
        }
    } else { $null }
    
    # --- 3d: Insert snapshot ---
    $insertHistoryQuery = @"
INSERT INTO ServerOps.Replication_AgentHistory (
    publication_registry_id, run_status, agent_message, agent_action_dttm,
    error_id, pending_command_count, estimated_processing_seconds,
    delivery_rate, delivered_transactions, delivered_commands,
    average_commands, delivery_latency, collected_dttm
) VALUES (
    $regId,
    $(Safe-SqlInt $health.runstatus),
    $(Safe-SqlString $agentMessage),
    $(Safe-SqlDateTime $health.time),
    $(Safe-SqlInt $health.error_id),
    $pendingCmdCount,
    $estimatedProcessingSeconds,
    $(Safe-SqlFloat $health.delivery_rate),
    $(Safe-SqlInt $health.delivered_transactions),
    $(Safe-SqlInt $health.delivered_commands),
    $(Safe-SqlInt $health.average_commands),
    $(Safe-SqlInt $health.delivery_latency),
    '$collectedDttm'
)
"@
    
    Invoke-SqlNonQuery -Query $insertHistoryQuery | Out-Null
    $snapshotCount++
    
    # ========================================
    # STEP 4: EVENT DETECTION (inline per agent)
    # ========================================
    $currentRunStatus = [int]$health.runstatus
    $currentRunStatusDesc = Get-RunStatusDesc $currentRunStatus
    
    # Check for "successfully stopped" message with misleading runstatus = 2
    $isStoppedMessage = ($null -ne $agentMessage -and $agentMessage -like '*process was successfully stopped*')
    if ($isStoppedMessage -and $currentRunStatus -eq 2) {
        $currentRunStatus = 6
        $currentRunStatusDesc = "Stopped"
    }
    
    $previousRunStatus = $null
    if ($previousLookup.ContainsKey($regId)) {
        $previousRunStatus = [int]$previousLookup[$regId].run_status
        
        # Also check previous for the stopped message quirk
        $prevMsg = $previousLookup[$regId].agent_message
        if ($null -ne $prevMsg -and $prevMsg -isnot [DBNull] -and $prevMsg -like '*process was successfully stopped*' -and $previousRunStatus -eq 2) {
            $previousRunStatus = 6
        }
    }
    
    # Detect state change
    if ($null -ne $previousRunStatus -and $currentRunStatus -ne $previousRunStatus) {
        $previousRunStatusDesc = Get-RunStatusDesc $previousRunStatus
        
        # Determine event type
        $eventType = 'STATE_CHANGE'
        if ($currentRunStatus -in @(1, 2, 3) -and $previousRunStatus -in @(5, 6)) {
            $eventType = 'AGENT_START'
        }
        elseif ($currentRunStatus -in @(5, 6) -and $previousRunStatus -in @(1, 2, 3)) {
            $eventType = 'AGENT_STOP'
        }
        elseif ($currentRunStatus -eq 4) {
            $eventType = 'RETRY'
        }
        
        # Check BIDATA build correlation
        $correlationSource = "NULL"
        if ($eventType -in @('AGENT_STOP', 'STATE_CHANGE') -and $currentRunStatus -in @(5, 6)) {
            $bidataCheck = Get-SqlData -Query @"
SELECT TOP 1 status 
FROM BIDATA.BuildExecution 
WHERE build_date = CAST(GETDATE() AS DATE) 
  AND status = 'IN_PROGRESS'
ORDER BY build_id DESC
"@
            if ($null -ne $bidataCheck) {
                $correlationSource = "'BIDATA_BUILD'"
            }
        }
        
        # Capture error detail if applicable
        $errorDetail = "NULL"
        $errorId = Safe-SqlInt $health.error_id
        if ($errorId -ne "NULL" -and $errorId -gt 0) {
            $errorQuery = @"
SELECT TOP 1 error_text 
FROM distribution.dbo.MSrepl_errors 
WHERE id = $errorId
"@
            $errorResult = Get-SqlData -Query $errorQuery -Instance $DistributorInstance -DatabaseName "distribution"
            if ($null -ne $errorResult -and $null -ne $errorResult.error_text -and $errorResult.error_text -isnot [DBNull]) {
                $errorDetail = Safe-SqlString ($errorResult.error_text.ToString()) 1000
            }
        }
        
        $insertEventQuery = @"
INSERT INTO ServerOps.Replication_EventLog (
    publication_registry_id, event_type, event_dttm,
    previous_state, previous_state_desc,
    current_state, current_state_desc,
    event_message, error_id, error_detail,
    correlation_source, collected_dttm
) VALUES (
    $regId,
    '$eventType',
    $(Safe-SqlDateTime $health.time),
    $previousRunStatus,
    '$previousRunStatusDesc',
    $currentRunStatus,
    '$currentRunStatusDesc',
    $(Safe-SqlString $agentMessage),
    $errorId,
    $errorDetail,
    $correlationSource,
    '$collectedDttm'
)
"@
        Invoke-SqlNonQuery -Query $insertEventQuery | Out-Null
        $eventCount++
        
        $correlationTag = if ($correlationSource -ne "NULL") { " [BIDATA_BUILD]" } else { "" }
        Write-Log "  Event: $($reg.publication_name) ($agentType) $previousRunStatusDesc -> $currentRunStatusDesc$correlationTag"
    }
    
    # Check for errors even without state change
    if ($null -eq $previousRunStatus -or $currentRunStatus -eq $previousRunStatus) {
        $errorId = Safe-SqlInt $health.error_id
        if ($errorId -ne "NULL" -and [int]$errorId -gt 0) {
            $errorDetail = "NULL"
            $errorQuery = @"
SELECT TOP 1 error_text 
FROM distribution.dbo.MSrepl_errors 
WHERE id = $errorId
"@
            $errorResult = Get-SqlData -Query $errorQuery -Instance $DistributorInstance -DatabaseName "distribution"
            if ($null -ne $errorResult -and $null -ne $errorResult.error_text -and $errorResult.error_text -isnot [DBNull]) {
                $errorDetail = Safe-SqlString ($errorResult.error_text.ToString()) 1000
            }
            
            $insertErrorEventQuery = @"
INSERT INTO ServerOps.Replication_EventLog (
    publication_registry_id, event_type, event_dttm,
    current_state, current_state_desc,
    event_message, error_id, error_detail,
    collected_dttm
) VALUES (
    $regId,
    'ERROR',
    $(Safe-SqlDateTime $health.time),
    $currentRunStatus,
    '$currentRunStatusDesc',
    $(Safe-SqlString $agentMessage),
    $errorId,
    $errorDetail,
    '$collectedDttm'
)
"@
            Invoke-SqlNonQuery -Query $insertErrorEventQuery | Out-Null
            $eventCount++
            Write-Log "  Error event: $($reg.publication_name) ($agentType) error_id=$errorId" "WARN"
        }
    }
}

Write-Log "  Snapshots: $snapshotCount, Events: $eventCount"

# ========================================
# STEP 5: TRACER TOKENS (conditional)
# ========================================
$tracerIntervalMinutes = [int](Get-ConfigValue 'replication_tracer_interval_minutes')
if ($null -eq $tracerIntervalMinutes -or $tracerIntervalMinutes -le 0) { $tracerIntervalMinutes = 5 }

$tracerWaitSeconds = [int](Get-ConfigValue 'replication_tracer_wait_seconds')
if ($null -eq $tracerWaitSeconds -or $tracerWaitSeconds -le 0) { $tracerWaitSeconds = 15 }

# Check when the last tracer token was collected
$lastTracerQuery = "SELECT MAX(collected_dttm) AS last_tracer FROM ServerOps.Replication_LatencyHistory"
$lastTracer = Get-SqlData -Query $lastTracerQuery

$runTracers = $true
if ($null -ne $lastTracer -and $null -ne $lastTracer.last_tracer -and $lastTracer.last_tracer -isnot [DBNull]) {
    $minutesSinceLastTracer = (New-TimeSpan -Start $lastTracer.last_tracer -End (Get-Date)).TotalMinutes
    if ($minutesSinceLastTracer -lt $tracerIntervalMinutes) {
        $runTracers = $false
        Write-Log "Step 5: Tracer tokens - skipped ($([math]::Round($minutesSinceLastTracer, 1)) min since last, interval is $tracerIntervalMinutes min)"
    }
}

if ($runTracers) {
    Write-Log "Step 5: Tracer Token Collection"
    
    # Get distinct publications with tracer tokens enabled (Distribution agents only)
    $tracerPublications = $activeList | Where-Object { 
        $_.agent_type -eq 'Distribution' -and $_.tracer_tokens_enabled -eq $true 
    } | Select-Object -Property publication_name, publisher_db -Unique
    
    $tokenCount = 0
    
    foreach ($pub in $tracerPublications) {
        # Post tracer token
        $postTokenQuery = @"
DECLARE @token_id INT;
EXEC sys.sp_posttracertoken 
    @publication = '$($pub.publication_name)',
    @tracer_token_id = @token_id OUTPUT;
SELECT @token_id AS tracer_token_id;
"@
        
        $tokenResult = Get-SqlData -Query $postTokenQuery -Instance $DistributorInstance -DatabaseName $pub.publisher_db
        
        if ($null -eq $tokenResult) {
            Write-Log "  Failed to post tracer token for $($pub.publication_name)" "WARN"
            continue
        }
        
        $tokenId = $tokenResult.tracer_token_id
        Write-Log "  Posted token $tokenId for $($pub.publication_name), waiting ${tracerWaitSeconds}s..."
        
        # Wait for token to propagate
        Start-Sleep -Seconds $tracerWaitSeconds
        
        # Collect results
        $historyQuery = @"
EXEC sys.sp_helptracertokenhistory 
    @publication = '$($pub.publication_name)',
    @tracer_id = $tokenId
"@
        
        $tokenHistory = Get-SqlData -Query $historyQuery -Instance $DistributorInstance -DatabaseName $pub.publisher_db
        
        if ($null -ne $tokenHistory) {
            foreach ($th in @($tokenHistory)) {
                # Find the matching registry entry for this subscriber
                $matchingReg = $activeList | Where-Object {
                    $_.agent_type -eq 'Distribution' -and 
                    $_.publication_name -eq $pub.publication_name
                }
                
                # If multiple subscribers, match by distributor_to_subscriber latency presence
                foreach ($mr in @($matchingReg)) {
                    $insertLatencyQuery = @"
INSERT INTO ServerOps.Replication_LatencyHistory (
    publication_registry_id, tracer_token_id,
    publisher_commit_dttm, distributor_commit_dttm, subscriber_commit_dttm,
    publisher_to_distributor_ms, distributor_to_subscriber_ms, total_latency_ms,
    collected_dttm
) VALUES (
    $($mr.publication_registry_id),
    $tokenId,
    $(Safe-SqlDateTime $th.publisher_commit),
    $(Safe-SqlDateTime $th.distributor_commit),
    $(Safe-SqlDateTime $th.subscriber_commit),
    $(Safe-SqlInt $th.distributor_latency),
    $(Safe-SqlInt $th.subscriber_latency),
    $(Safe-SqlInt $th.overall_latency),
    '$collectedDttm'
)
"@
                    Invoke-SqlNonQuery -Query $insertLatencyQuery | Out-Null
                    $tokenCount++
                }
            }
        }
        
        # Cleanup tracer token from distribution database
        $cleanupQuery = @"
EXEC sys.sp_deletetracertokenhistory 
    @publication = '$($pub.publication_name)',
    @tracer_id = $tokenId
"@
        Invoke-SqlNonQuery -Query $cleanupQuery -Instance $DistributorInstance -DatabaseName $pub.publisher_db | Out-Null
    }
    
    Write-Log "  Tracer tokens collected: $tokenCount"
}

# ========================================
# SUMMARY AND CALLBACK
# ========================================
Write-Log "========================================"
Write-Log "Collection Complete"
Write-Log "  Snapshots: $snapshotCount"
Write-Log "  Events: $eventCount"
Write-Log "  Duration: $([math]::Round((New-TimeSpan -Start $scriptStart -End (Get-Date)).TotalSeconds, 1))s"
Write-Log "========================================"

# Orchestrator callback
if ($TaskId -gt 0) {
    $totalMs = [int]((New-TimeSpan -Start $scriptStart -End (Get-Date)).TotalMilliseconds)
    $outputMsg = "Agents: $snapshotCount, Events: $eventCount"
    Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
        -TaskId $TaskId -ProcessId $ProcessId `
        -Status "SUCCESS" -DurationMs $totalMs `
        -Output $outputMsg
}

exit 0
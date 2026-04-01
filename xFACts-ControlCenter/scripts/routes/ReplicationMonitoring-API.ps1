# ============================================================================
# xFACts Control Center - Replication Monitoring API Endpoints
# Location: E:\xFACts-ControlCenter\scripts\routes\ReplicationMonitoring-API.ps1
# Version: Tracked in dbo.System_Metadata (component: ServerOps.Replication)
#
# API endpoints for the Replication Monitoring page.
# ============================================================================

# ============================================================================
# API: Current Agent Status
# Returns latest snapshot per agent with registry context
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/replication/agent-status' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $query = @"
SELECT 
    r.publication_registry_id,
    r.publication_name,
    r.publisher_db,
    r.subscriber_name,
    r.subscriber_db,
    r.subscription_type_desc,
    r.agent_type,
    r.agent_name,
    r.is_monitored,
    r.tracer_tokens_enabled,
    h.run_status,
    h.agent_message,
    CONVERT(VARCHAR(23), h.agent_action_dttm, 126) AS agent_action_dttm,
    h.pending_command_count,
    h.estimated_processing_seconds,
    h.delivery_rate,
    h.delivered_commands,
    h.delivery_latency,
    CONVERT(VARCHAR(23), h.collected_dttm, 126) AS collected_dttm,
    lat.total_latency_ms AS latest_latency_ms,
    CONVERT(VARCHAR(23), lat.collected_dttm, 126) AS latest_latency_dttm
FROM ServerOps.Replication_PublicationRegistry r
OUTER APPLY (
    SELECT TOP 1 *
    FROM ServerOps.Replication_AgentHistory ah
    WHERE ah.publication_registry_id = r.publication_registry_id
    ORDER BY ah.collected_dttm DESC
) h
OUTER APPLY (
    SELECT TOP 1 total_latency_ms, collected_dttm
    FROM ServerOps.Replication_LatencyHistory lh
    WHERE lh.publication_registry_id = r.publication_registry_id
    ORDER BY lh.collected_dttm DESC
) lat
WHERE r.is_dropped = 0
ORDER BY r.agent_type, r.publication_name
"@
        $results = Invoke-XFActsQuery -Query $query
        Write-PodeJsonResponse -Value $results
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ============================================================================
# API: Queue Depth History
# Returns pending_command_count over time for Distribution agents
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/replication/queue-history' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $minutes = $WebEvent.Query['minutes']
        if (-not $minutes) { $minutes = 60 }
        
        $query = @"
SELECT 
    r.publication_name,
    h.pending_command_count,
    CONVERT(VARCHAR(23), h.collected_dttm, 126) AS collected_dttm
FROM ServerOps.Replication_AgentHistory h
INNER JOIN ServerOps.Replication_PublicationRegistry r 
    ON h.publication_registry_id = r.publication_registry_id
WHERE r.agent_type = 'Distribution'
  AND r.is_dropped = 0
  AND h.collected_dttm >= DATEADD(MINUTE, -$minutes, GETDATE())
ORDER BY h.collected_dttm ASC, r.publication_name
"@
        $results = Invoke-XFActsQuery -Query $query
        Write-PodeJsonResponse -Value $results
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ============================================================================
# API: Latency History
# Returns tracer token latency over time
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/replication/latency-history' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $minutes = $WebEvent.Query['minutes']
        if (-not $minutes) { $minutes = 60 }
        
        $query = @"
SELECT 
    r.publication_name,
    r.subscriber_name,
    l.total_latency_ms,
    l.publisher_to_distributor_ms,
    l.distributor_to_subscriber_ms,
    CONVERT(VARCHAR(23), l.collected_dttm, 126) AS collected_dttm
FROM ServerOps.Replication_LatencyHistory l
INNER JOIN ServerOps.Replication_PublicationRegistry r 
    ON l.publication_registry_id = r.publication_registry_id
WHERE r.is_dropped = 0
  AND l.collected_dttm >= DATEADD(MINUTE, -$minutes, GETDATE())
ORDER BY l.collected_dttm ASC, r.publication_name
"@
        $results = Invoke-XFActsQuery -Query $query
        Write-PodeJsonResponse -Value $results
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ============================================================================
# API: Throughput History
# Returns delivery_rate over time for all agents
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/replication/throughput-history' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $minutes = $WebEvent.Query['minutes']
        if (-not $minutes) { $minutes = 60 }
        
        $query = @"
SELECT 
    r.publication_name,
    r.agent_type,
    h.delivery_rate,
    CONVERT(VARCHAR(23), h.collected_dttm, 126) AS collected_dttm
FROM ServerOps.Replication_AgentHistory h
INNER JOIN ServerOps.Replication_PublicationRegistry r 
    ON h.publication_registry_id = r.publication_registry_id
WHERE r.is_dropped = 0
  AND h.collected_dttm >= DATEADD(MINUTE, -$minutes, GETDATE())
ORDER BY h.collected_dttm ASC, r.agent_type, r.publication_name
"@
        $results = Invoke-XFActsQuery -Query $query
        Write-PodeJsonResponse -Value $results
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ============================================================================
# API: Event Log
# Returns all events for a given date, optionally filtered by publication_registry_id
# Supports correlation mode: ?correlated=1 returns all events with correlation_source across all dates
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/replication/events' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $correlated = $WebEvent.Query['correlated']
        $date = $WebEvent.Query['date']
        if (-not $date) { $date = (Get-Date).ToString('yyyy-MM-dd') }
        
        $agentFilter = $WebEvent.Query['agent']
        
        if ($correlated -eq '1') {
            # Correlation mode: all events with correlation_source, no date filter
            $whereClause = "WHERE e.correlation_source IS NOT NULL"
        }
        else {
            $whereClause = "WHERE CAST(e.event_dttm AS DATE) = @date"
        }
        
        if ($agentFilter -and $agentFilter -ne 'ALL') {
            $whereClause += " AND e.publication_registry_id = @agent"
        }
        
        $query = @"
SELECT 
    e.event_id,
    e.publication_registry_id,
    r.publication_name,
    r.subscriber_name,
    r.agent_type,
    e.event_type,
    CONVERT(VARCHAR(23), e.event_dttm, 126) AS event_dttm,
    e.previous_state,
    e.previous_state_desc,
    e.current_state,
    e.current_state_desc,
    e.event_message,
    e.error_id,
    e.error_detail,
    e.correlation_source,
    CONVERT(VARCHAR(23), e.collected_dttm, 126) AS collected_dttm
FROM ServerOps.Replication_EventLog e
INNER JOIN ServerOps.Replication_PublicationRegistry r 
    ON e.publication_registry_id = r.publication_registry_id
$whereClause
ORDER BY e.event_dttm DESC
"@
        $params = @{}
        if ($correlated -ne '1') {
            $params.date = $date
        }
        if ($agentFilter -and $agentFilter -ne 'ALL') {
            $params.agent = [int]$agentFilter
        }
        
        $results = Invoke-XFActsQuery -Query $query -Parameters $params
        
        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            events = $results
            date = if ($correlated -eq '1') { 'all' } else { $date }
            correlated = ($correlated -eq '1')
            total = @($results).Count
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ============================================================================
# API: Thresholds
# Returns current GlobalConfig thresholds for replication
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/replication/thresholds' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $query = @"
SELECT setting_name, setting_value, data_type
FROM dbo.GlobalConfig
WHERE module_name = 'ServerOps' 
  AND category = 'Replication'
  AND is_active = 1
"@
        $results = Invoke-XFActsQuery -Query $query
        
        $thresholds = @{}
        foreach ($row in $results) {
            $thresholds[$row.setting_name] = $row.setting_value
        }
        
        Write-PodeJsonResponse -Value $thresholds
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}
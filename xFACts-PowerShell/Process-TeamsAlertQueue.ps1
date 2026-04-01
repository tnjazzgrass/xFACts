<#
.SYNOPSIS
    xFACts - Teams Alert Queue Processor
    
.DESCRIPTION
    xFACts - Teams
    Script: Process-TeamsAlertQueue.ps1
    Version: Tracked in dbo.System_Metadata (component: Teams)

    Reads pending alerts from xFACts.Teams.AlertQueue, formats Adaptive Cards,
    routes to appropriate webhooks based on subscriptions, and logs results to
    RequestLog.

    CHANGELOG
    ---------
    2026-03-11  Migrated to Initialize-XFActsScript shared infrastructure
                Removed inline Write-Log
                Converted 4 direct Invoke-Sqlcmd calls to shared Get-SqlData/Invoke-SqlNonQuery
                Updated header to component-level versioning format
    2026-02-21  Replaced reinsert retry with inline retry loop
                2-second delay between attempts eliminates orphaned Pending rows
                Removed teams_retry_delay_minutes dependency
    2026-02-10  Automatic retry for failed webhook deliveries
                Configurable max attempts via GlobalConfig
                Original failed rows preserved with error_message for audit trail
    2026-02-08  Added emoji placeholder resolution to legacy Send-TeamsAlert path
                ColumnSet layout with right-aligned emoji when placeholder in title
                Added UTF-8 encoding to legacy card POST
    2026-02-06  Orchestrator v2 integration
                Added -Execute safeguard, TaskId/ProcessId, SQLPS fallback
                Relocated to E:\xFACts-PowerShell
                Added pre-built Adaptive Card support via card_json column
                Added -MaxCharLength 65535 for card_json retrieval
                Added emoji placeholder resolution at send time for PS 5.1
                Added markdown support with line break handling
    2025-12-17  Subscription-based channel routing
    2025-12-16  Initial implementation
                Queue-based Teams webhook delivery with Adaptive Card formatting

.PARAMETER ServerInstance
    SQL Server instance name (default: AVG-PROD-LSNR)
    
.PARAMETER Database
    Database name (default: xFACts)

.PARAMETER Execute
    Perform actual webhook calls. Without this flag, runs in preview mode.

.PARAMETER TaskId
    Orchestrator TaskLog ID passed by the v2 engine at launch. Used for task 
    completion callback. Default 0 (no callback when run manually).

.PARAMETER ProcessId
    Orchestrator ProcessRegistry ID passed by the v2 engine at launch. Used for 
    task completion callback. Default 0 (no callback when run manually).

================================================================================
DEPLOYMENT REMINDERS
================================================================================
1. Deploy to E:\xFACts-PowerShell on FA-SQLDBB.
2. xFACts-OrchestratorFunctions.ps1 must be in the same directory.
================================================================================
#>

[CmdletBinding()]
param(
    [string]$ServerInstance = "AVG-PROD-LSNR",
    [string]$Database = "xFACts",
    [switch]$Execute,
    [long]$TaskId = 0,
    [int]$ProcessId = 0
)

# ============================================================================
# STANDARD INITIALIZATION
# ============================================================================

. "$PSScriptRoot\xFACts-OrchestratorFunctions.ps1"

Initialize-XFActsScript -ScriptName 'Process-TeamsAlertQueue' `
    -ServerInstance $ServerInstance -Database $Database -Execute:$Execute

# Force TLS 1.2 for Teams webhook
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ============================================================================
# FUNCTIONS
# ============================================================================

function Send-TeamsAlert {
    param(
        [string]$WebhookUrl,
        [string]$Title,
        [string]$Message,
        [string]$Color,
        [string]$SourceModule,
        [string]$AlertCategory
    )
    
    # Map color names to Adaptive Card colors
    $colorMap = @{
        'attention' = 'attention'
        'warning'   = 'warning'
        'good'      = 'good'
        'default'   = 'default'
    }
    
    $cardColor = if ($colorMap.ContainsKey($Color)) { $colorMap[$Color] } else { 'default' }
    
    # Resolve emoji placeholders in message
    $Message = $Message.Replace('{{FIRE}}', [char]::ConvertFromUtf32(0x1F525))
    $Message = $Message.Replace('{{WARN}}', "$([char]::ConvertFromUtf32(0x26A0))$([char]::ConvertFromUtf32(0xFE0F))")
    $Message = $Message.Replace('{{CHECK}}', "$([char]::ConvertFromUtf32(0x2705))")
    
    # Build title header - ColumnSet with right-aligned emoji if placeholder present
    if ($Title -match '\{\{(FIRE|WARN|CHECK)\}\}') {
        # Extract the placeholder and resolve it
        $emojiPlaceholder = $Matches[0]
        $emojiChar = switch ($Matches[1]) {
            'FIRE'  { [char]::ConvertFromUtf32(0x1F525) }
            'WARN'  { "$([char]::ConvertFromUtf32(0x26A0))$([char]::ConvertFromUtf32(0xFE0F))" }
            'CHECK' { "$([char]::ConvertFromUtf32(0x2705))" }
        }
        $cleanTitle = $Title.Replace($emojiPlaceholder, '').Trim()
        
        $titleElement = @{
            type = "ColumnSet"
            columns = @(
                @{
                    type = "Column"
                    width = "stretch"
                    items = @(
                        @{
                            type = "TextBlock"
                            text = $cleanTitle
                            weight = "bolder"
                            size = "medium"
                            wrap = $true
                        }
                    )
                    verticalContentAlignment = "center"
                }
                @{
                    type = "Column"
                    width = "auto"
                    items = @(
                        @{
                            type = "TextBlock"
                            text = $emojiChar
                            size = "large"
                        }
                    )
                    verticalContentAlignment = "center"
                }
            )
        }
    }
    else {
        # Original single TextBlock - no emoji
        $titleElement = @{
            type = "TextBlock"
            text = $Title
            weight = "bolder"
            size = "medium"
            wrap = $true
        }
    }
    
    # Build Adaptive Card payload
    $card = @{
        type = "message"
        attachments = @(
            @{
                contentType = "application/vnd.microsoft.card.adaptive"
                content = @{
                    '$schema' = "http://adaptivecards.io/schemas/adaptive-card.json"
                    type = "AdaptiveCard"
                    version = "1.4"
                    body = @(
                        @{
                            type = "Container"
                            style = $cardColor
                            items = @(
                                $titleElement
                            )
                            bleed = $true
                        }
                        @{
                            type = "TextBlock"
                            text = $Message
                            wrap = $true
                            markdown = $true
                        }
                        @{
                            type = "FactSet"
                            facts = @(
                                @{
                                    title = "Source"
                                    value = $SourceModule
                                }
                                @{
                                    title = "Category"
                                    value = $AlertCategory
                                }
                                @{
                                    title = "Time"
                                    value = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                                }
                            )
                        }
                    )
                }
            }
        )
    }
    
    $json = $card | ConvertTo-Json -Depth 20
    
    try {
        $utf8Body = [System.Text.Encoding]::UTF8.GetBytes($json)
        $response = Invoke-RestMethod -Uri $WebhookUrl -Method Post -Body $utf8Body -ContentType 'application/json; charset=utf-8' -UseBasicParsing
        return @{ Success = $true; StatusCode = 200; Response = "OK" }
    }
    catch {
        $statusCode = 0
        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }
        return @{ Success = $false; StatusCode = $statusCode; Response = $_.Exception.Message }
    }
}

function Send-PrebuiltCard {
    param(
        [string]$WebhookUrl,
        [string]$CardJson
    )
    
    # Replace emoji placeholders - PowerShell 5.1's ConvertTo-Json
    # mangles multi-byte Unicode, so placeholders are stored and
    # resolved at send time
    $CardJson = $CardJson.Replace('{{FIRE}}', [char]::ConvertFromUtf32(0x1F525))
    $CardJson = $CardJson.Replace('{{WARN}}', "$([char]::ConvertFromUtf32(0x26A0))$([char]::ConvertFromUtf32(0xFE0F))")
    $CardJson = $CardJson.Replace('{{CHECK}}', "$([char]::ConvertFromUtf32(0x2705))")
    
    try {
        $utf8Body = [System.Text.Encoding]::UTF8.GetBytes($CardJson)
        $response = Invoke-RestMethod -Uri $webhookUrl -Method Post -Body $utf8Body -ContentType 'application/json; charset=utf-8' -UseBasicParsing
        return @{ Success = $true; StatusCode = 200; Response = "OK" }
    }
    catch {
        $statusCode = 0
        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }
        return @{ Success = $false; StatusCode = $statusCode; Response = $_.Exception.Message }
    }
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

$exitCode = 0
$scriptStart = Get-Date
$processedCount = 0
$successCount = 0
$failedCount = 0
$retriedCount = 0

try {
    Write-Log "========================================" "INFO"
    Write-Log "Teams Alert Queue Processor" "INFO"
    Write-Log "========================================" "INFO"
    Write-Log "Server: $ServerInstance" "INFO"
    Write-Log "Database: $Database" "INFO"
    
    # Load retry configuration from GlobalConfig
    $configQuery = @"
        SELECT setting_name, setting_value 
        FROM dbo.GlobalConfig 
        WHERE module_name = 'Teams' 
          AND setting_name = 'teams_retry_max_attempts'
          AND is_active = 1
"@
    $configRows = Get-SqlData -Query $configQuery
    
    $maxRetries = 3  # default
    
    if ($configRows) {
        foreach ($row in @($configRows)) {
            if ($row.setting_name -eq 'teams_retry_max_attempts') { $maxRetries = [int]$row.setting_value }
        }
    }
    Write-Log "Retry config: max_attempts=$maxRetries, delay=2s between attempts" "INFO"
    
    # Get pending alerts with their webhook destinations
    $pendingQuery = @"
        SELECT DISTINCT 
               q.queue_id, q.source_module, q.alert_category, q.title, q.message, q.color,
               q.card_json, q.trigger_type, q.trigger_value, q.created_dttm, q.retry_count,
               w.webhook_name, w.webhook_url
        FROM Teams.AlertQueue q
        INNER JOIN Teams.WebhookSubscription s ON 
            s.source_module = q.source_module
            AND (s.alert_category IS NULL OR s.alert_category = q.alert_category)
            AND (s.trigger_type IS NULL OR s.trigger_type = q.trigger_type)
            AND s.is_active = 1
        INNER JOIN Teams.WebhookConfig w ON s.config_id = w.config_id AND w.is_active = 1
        WHERE q.status = 'Pending'
        ORDER BY q.created_dttm
"@
    
    $pendingAlerts = Get-SqlData -Query $pendingQuery -MaxCharLength 65535
    
    if (-not $pendingAlerts -or $pendingAlerts.Count -eq 0) {
        Write-Host "Processed: 0, Sent: 0, Failed: 0"
        if ($TaskId -gt 0) {
            Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
                -TaskId $TaskId -ProcessId $ProcessId `
                -Status "SUCCESS" -DurationMs 0 `
                -Output "No pending alerts to process"
        }
        exit 0
    }
    
    Write-Log "Found $($pendingAlerts.Count) alert/webhook combination(s) to process" "INFO"
    
    # Track unique queue_ids we've processed
    $processedQueueIds = @{}
    
    foreach ($alert in $pendingAlerts) {
        $processedCount++
        Write-Log "Processing: $($alert.title) -> $($alert.webhook_name)" "INFO"
        
        if ($Execute) {
            # Check for pre-built Adaptive Card JSON
            $hasCardJson = $alert.card_json -and $alert.card_json -isnot [DBNull] -and $alert.card_json.Trim().Length -gt 0
            
            # Inline retry loop
            $attempt = 0
            $result = $null
            
            while ($attempt -lt $maxRetries) {
                $attempt++
                
                if ($attempt -gt 1) {
                    Write-Log "  Retry attempt $attempt/$maxRetries after 2s delay" "WARN"
                    Start-Sleep -Seconds 2
                }
                
                if ($hasCardJson) {
                    Write-Log "  Using pre-built card JSON$(if ($attempt -eq 1) { '' } else { ' (attempt ' + $attempt + ')' })" "DEBUG"
                    $result = Send-PrebuiltCard -WebhookUrl $alert.webhook_url `
                                                -CardJson $alert.card_json
                }
                else {
                    # Legacy path: build card from title/message/color
                    $formattedMessage = $alert.message -replace "`r`n", "  `r`n" -replace "(?<!`r)`n", "  `n"
                    $result = Send-TeamsAlert -WebhookUrl $alert.webhook_url `
                                               -Title $alert.title `
                                               -Message $formattedMessage `
                                               -Color $alert.color `
                                               -SourceModule $alert.source_module `
                                               -AlertCategory $alert.alert_category
                }
                
                # Log each attempt to RequestLog
                $safeTitle = $alert.title -replace "'", "''"
                $triggerType = if ($alert.trigger_type) { "'$($alert.trigger_type)'" } else { "NULL" }
                $triggerValue = if ($alert.trigger_value) { "'$($alert.trigger_value)'" } else { "NULL" }
                $responseText = if ($result.Response) { "'$($result.Response -replace "'", "''")'" } else { "NULL" }
                
                $logQuery = @"
                    INSERT INTO Teams.RequestLog (queue_id, source_module, alert_category, webhook_name, title, status_code, response_text, trigger_type, trigger_value)
                    VALUES ($($alert.queue_id), '$($alert.source_module)', '$($alert.alert_category)', '$($alert.webhook_name)', '$safeTitle', $($result.StatusCode), $responseText, $triggerType, $triggerValue)
"@
                Invoke-SqlNonQuery -Query $logQuery | Out-Null
                
                if ($result.Success) {
                    break  # Success - exit retry loop
                }
                
                Write-Log "  Attempt $attempt/$maxRetries FAILED: $($result.Response)" "ERROR"
            }
            
            # Determine final outcome
            if ($result.Success) {
                $status = 'Success'
                $successCount++
                if ($attempt -gt 1) {
                    $retriedCount++
                    Write-Log "  SUCCESS -> $($alert.webhook_name) (after $attempt attempts)" "SUCCESS"
                }
                else {
                    Write-Log "  SUCCESS -> $($alert.webhook_name)" "SUCCESS"
                }
            }
            else {
                $status = 'Failed'
                $failedCount++
                Write-Log "  PERMANENTLY FAILED -> $($alert.webhook_name) after $attempt attempts" "ERROR"
            }
            
            # Update queue status (only once per queue_id, use last result)
            if (-not $processedQueueIds.ContainsKey($alert.queue_id)) {
                $processedQueueIds[$alert.queue_id] = $true
            }
            
            $errorMsg = if ($status -eq 'Failed') { $result.Response -replace "'", "''" } else { "" }
            
            $updateQuery = @"
                UPDATE Teams.AlertQueue 
                SET status = '$status', 
                    processed_dttm = GETDATE(), 
                    error_message = $(if ($status -eq 'Failed') { "'$errorMsg'" } else { "NULL" }),
                    retry_count = $($attempt - 1)
                WHERE queue_id = $($alert.queue_id)
"@
            Invoke-SqlNonQuery -Query $updateQuery | Out-Null
        }
        else {
            # Preview mode
            Write-Log "  [PREVIEW] Would send to: $($alert.webhook_name)" "DEBUG"
            $successCount++
        }
    }
    
    Write-Log "========================================" "INFO"
    Write-Log "Processing Complete" "INFO"
    Write-Log "  Processed: $processedCount" "INFO"
    Write-Log "  Sent: $successCount" "SUCCESS"
    Write-Log "  Failed: $failedCount" $(if ($failedCount -gt 0) { "WARN" } else { "INFO" })
    if ($retriedCount -gt 0) {
        Write-Log "  Succeeded after retry: $retriedCount" "WARN"
    }
    Write-Log "========================================" "INFO"
    
    # Output summary for orchestrator
    Write-Host "Processed: $processedCount, Sent: $successCount, Failed: $failedCount, Retried: $retriedCount"
    
    if ($failedCount -gt 0) {
        $exitCode = 1
    }
}
catch {
    Write-Log "CRITICAL ERROR: $($_.Exception.Message)" "ERROR"
    Write-Log "Stack Trace: $($_.ScriptStackTrace)" "ERROR"
    Write-Host "ERROR: $($_.Exception.Message)"
    $exitCode = 1
}

if ($TaskId -gt 0) {
    $totalMs = [int]((New-TimeSpan -Start $scriptStart -End (Get-Date)).TotalMilliseconds)
    $status = if ($exitCode -eq 0) { "SUCCESS" } else { "FAILED" }
    Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
        -TaskId $TaskId -ProcessId $ProcessId `
        -Status $status -DurationMs $totalMs `
        -Output "Processed: $processedCount, Sent: $successCount, Failed: $failedCount, Retried: $retriedCount"
}
exit $exitCode
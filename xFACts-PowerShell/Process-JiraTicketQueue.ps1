<#
.SYNOPSIS
    xFACts - Jira Ticket Queue Processor
    
.DESCRIPTION
    xFACts - Jira
    Script: Process-JiraTicketQueue.ps1
    Version: Tracked in dbo.System_Metadata (component: Jira)

    Reads pending tickets from xFACts.Jira.TicketQueue, creates them in Jira via 
    REST API, updates queue status, retrieves assignee, and handles email fallback 
    on failure.

    CHANGELOG
    ---------
    2026-03-11  Migrated to Initialize-XFActsScript shared infrastructure
                Removed inline Write-Log, Get-MasterPassphrase, Get-JiraCredentials
                Replaced credential retrieval with Get-ServiceCredentials
                Removed $SqlServer/$SqlDatabase params from business functions
                Converted Get-PendingTickets to shared Get-SqlData
                Updated header to component-level versioning format
    2026-02-06  SqlServer module compatibility and Negotiate auth fix
                Replaced SqlDataAdapter with Invoke-Sqlcmd in Get-PendingTickets
                Added Invoke-JiraAPI helper using HttpWebRequest
    2026-02-01  Orchestrator v2 integration
                Added -Execute safeguard, TaskId/ProcessId, SQLPS fallback
                Master passphrase now from GlobalConfig (not hardcoded)
                Relocated to E:\xFACts-PowerShell
    2025-12-14  Initial implementation
                Queue-based Jira REST API ticket creation
                Migration from DBA to xFACts database

.PARAMETER ServerInstance
    SQL Server instance name (default: AVG-PROD-LSNR)
    
.PARAMETER Database
    Database name (default: xFACts)
    
.PARAMETER MaxRetries
    Maximum retry attempts for failed tickets (default: 3)
    
.PARAMETER BatchSize
    Maximum tickets to process per run (default: 50)

.PARAMETER Execute
    Perform actual Jira API calls. Without this flag, runs in preview mode.

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
2. Credentials retrieved via Get-ServiceCredentials (dbo.Credentials + GlobalConfig).
3. xFACts-OrchestratorFunctions.ps1 must be in the same directory.
================================================================================
#>

[CmdletBinding()]
param(
    [string]$ServerInstance = "AVG-PROD-LSNR",
    [string]$Database = "xFACts",
    [int]$MaxRetries = 3,
    [int]$BatchSize = 50,
    [switch]$Execute,
    [long]$TaskId = 0,
    [int]$ProcessId = 0
)

# ============================================================================
# STANDARD INITIALIZATION
# ============================================================================

. "$PSScriptRoot\xFACts-OrchestratorFunctions.ps1"

Initialize-XFActsScript -ScriptName 'Process-JiraTicketQueue' `
    -ServerInstance $ServerInstance -Database $Database -Execute:$Execute

# Force TLS 1.2 for Jira API
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Email settings for fallback
$DatabaseMailProfile = "ALERT!"

# ============================================================================
# FUNCTIONS
# ============================================================================

function Get-PendingTickets {
    param(
        [int]$MaxRetries,
        [int]$BatchSize
    )
    
    $sqlQuery = "SELECT TOP $BatchSize
    QueueID,
    SourceModule,
    ProjectKey,
    Summary,
    TicketDescription,
    IssueType,
    TicketPriority,
    Assignee,
    CascadingField_ID,
    CascadingField_ParentValue,
    CascadingField_ChildValue,
    CustomField_ID,
    CustomField_Value,
    CustomField2_ID,
    CustomField2_Value,
    CustomField3_ID,
    CustomField3_Value,
    DueDate,
    TriggerType,
    TriggerValue,
    EmailRecipients,
    RetryCount
FROM Jira.TicketQueue
WHERE TicketStatus = 'Pending'
  AND (RetryCount < $MaxRetries OR RetryCount IS NULL)
ORDER BY RequestedDate ASC"

    try {
        return Get-SqlData -Query $sqlQuery
    } catch {
        Write-Log "Failed to query pending tickets: $($_.Exception.Message)" "ERROR"
        throw
    }
}

function Invoke-JiraAPI {
    <#
    .SYNOPSIS
        Makes HTTP requests to Jira using HttpWebRequest to bypass Negotiate auth.
        Invoke-RestMethod/Invoke-WebRequest fail when Jira returns WWW-Authenticate: Negotiate
        because PowerShell attempts Windows integrated auth instead of using the Basic header.
    #>
    param(
        [string]$Uri,
        [string]$Method = "GET",
        [hashtable]$Headers,
        [string]$Body = $null
    )
    
    $request = [System.Net.HttpWebRequest]::Create($Uri)
    $request.Method = $Method
    $request.PreAuthenticate = $true
    $request.ContentType = "application/json; charset=utf-8"
    $request.Accept = "application/json"
    
    foreach ($key in $Headers.Keys) {
        if ($key -eq 'Content-Type') { continue }
        $request.Headers.Add($key, $Headers[$key])
    }
    
    if ($Body) {
        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
        $request.ContentLength = $bodyBytes.Length
        $stream = $request.GetRequestStream()
        $stream.Write($bodyBytes, 0, $bodyBytes.Length)
        $stream.Close()
    }
    
    try {
        $response = $request.GetResponse()
        $reader = New-Object System.IO.StreamReader($response.GetResponseStream())
        $content = $reader.ReadToEnd()
        $reader.Close()
        $statusCode = [int]$response.StatusCode
        $response.Close()
        
        return @{
            Success = $true
            StatusCode = $statusCode
            Content = $content
        }
    }
    catch [System.Net.WebException] {
        $resp = $_.Exception.Response
        $statusCode = if ($resp) { [int]$resp.StatusCode } else { 0 }
        $content = ""
        if ($resp) {
            try {
                $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
                $content = $reader.ReadToEnd()
                $reader.Close()
            } catch { }
        }
        
        return @{
            Success = $false
            StatusCode = $statusCode
            Content = $content
            ErrorMessage = $_.Exception.Message
        }
    }
}

function New-JiraTicket {
    param(
        [hashtable]$Credentials,
        [System.Data.DataRow]$Ticket
    )
    
    $base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$($Credentials.JiraUser):$($Credentials.JiraPassword)"))
    
    $headers = @{
        'Authorization' = "Basic $base64Auth"
        'Content-Type'  = 'application/json'
    }
    
    # Build the basic ticket payload
    $ticketBody = @{
        fields = @{
            project = @{ key = $Ticket.ProjectKey }
            summary = $Ticket.Summary
            description = $Ticket.TicketDescription
            issuetype = @{ name = $Ticket.IssueType }
            priority = @{ name = $Ticket.TicketPriority }
        }
    }
    
    # Add optional assignee
    if (-not [string]::IsNullOrEmpty($Ticket.Assignee)) {
        $ticketBody.fields.assignee = @{ name = $Ticket.Assignee }
    }
    
    # Add optional due date
    if ($Ticket.DueDate -ne [DBNull]::Value) {
        $ticketBody.fields.duedate = $Ticket.DueDate.ToString("yyyy-MM-dd")
    }
    
    # Add cascading field if specified
    if (-not [string]::IsNullOrEmpty($Ticket.CascadingField_ID)) {
        $ticketBody.fields[$Ticket.CascadingField_ID] = @{
            value = $Ticket.CascadingField_ParentValue
        }
        if (-not [string]::IsNullOrEmpty($Ticket.CascadingField_ChildValue)) {
            $ticketBody.fields[$Ticket.CascadingField_ID].child = @{
                value = $Ticket.CascadingField_ChildValue
            }
        }
    }
    
    # Add custom fields if specified
    if (-not [string]::IsNullOrEmpty($Ticket.CustomField_ID)) {
        $ticketBody.fields[$Ticket.CustomField_ID] = $Ticket.CustomField_Value
    }
    if (-not [string]::IsNullOrEmpty($Ticket.CustomField2_ID)) {
        $ticketBody.fields[$Ticket.CustomField2_ID] = $Ticket.CustomField2_Value
    }
    if (-not [string]::IsNullOrEmpty($Ticket.CustomField3_ID)) {
        $ticketBody.fields[$Ticket.CustomField3_ID] = $Ticket.CustomField3_Value
    }
    
    $jsonBody = $ticketBody | ConvertTo-Json -Depth 10
    
 $createResult = Invoke-JiraAPI -Uri "$($Credentials.JiraURL)/rest/api/2/issue" `
        -Method POST -Headers $headers -Body $jsonBody
    
    if ($createResult.Success) {
        $responseData = $createResult.Content | ConvertFrom-Json
        $ticketKey = $responseData.key
        
        # Try to get the assignee from the created ticket
        $assignee = $null
        $detailResult = Invoke-JiraAPI -Uri "$($Credentials.JiraURL)/rest/api/2/issue/$ticketKey" `
            -Method GET -Headers $headers
        if ($detailResult.Success) {
            $detailData = $detailResult.Content | ConvertFrom-Json
            if ($detailData.fields.assignee) {
                $assignee = $detailData.fields.assignee.displayName
            }
        }
        
        return @{
            Success = $true
            StatusCode = $createResult.StatusCode
            ResponseBody = $createResult.Content
            Assignee = $assignee
        }
    }
    else {
        return @{
            Success = $false
            StatusCode = $createResult.StatusCode
            ResponseBody = $createResult.Content
            Assignee = $null
        }
    }
}

function Update-QueueStatus {
    param(
        [int]$QueueID,
        [string]$Status,
        [string]$TicketKey = $null,
        [int]$StatusCode = 0,
        [string]$ResponseMessage = $null,
        [int]$RetryCount = 0
    )
    
    $ticketKeyValue = if ($TicketKey) { "'$TicketKey'" } else { "NULL" }
    $responseValue = if ($ResponseMessage) { "'$($ResponseMessage -replace "'", "''")'" } else { "NULL" }
    
    $sqlQuery = @"
UPDATE Jira.TicketQueue
SET TicketStatus = '$Status',
    TicketKey = $ticketKeyValue,
    StatusCode = $StatusCode,
    ResponseMessage = $responseValue,
    ProcessedDate = GETDATE(),
    RetryCount = $RetryCount,
    LastRetryDate = GETDATE()
WHERE QueueID = $QueueID
"@
    
    try {
        $connectionString = "Server=$($script:XFActsServerInstance);Database=$($script:XFActsDatabase);Integrated Security=True;Application Name=$($script:XFActsAppName)"
        $connection = New-Object System.Data.SqlClient.SqlConnection($connectionString)
        $connection.Open()
        
        $command = $connection.CreateCommand()
        $command.CommandText = $sqlQuery
        $command.ExecuteNonQuery() | Out-Null
        
        $connection.Close()
    } catch {
        Write-Log "Failed to update queue status: $($_.Exception.Message)" "WARN"
    }
}

function Send-EmailFallback {
    param(
        [object]$Ticket,
        [string]$ErrorMessage
    )
    
    if ([string]::IsNullOrEmpty($Ticket.EmailRecipients)) {
        Write-Log "No email recipients configured for QueueID $($Ticket.QueueID)" "WARN"
        return $false
    }
    
    $subject = "Jira Ticket Creation Failed: $($Ticket.Summary)"
    $body = @"
A Jira ticket could not be created automatically.

Project: $($Ticket.ProjectKey)
Summary: $($Ticket.Summary)
Source: $($Ticket.SourceModule)

Error: $ErrorMessage

Original Description:
$($Ticket.TicketDescription)

Please create this ticket manually.
"@
    
    $sqlQuery = @"
EXEC msdb.dbo.sp_send_dbmail
    @profile_name = '$DatabaseMailProfile',
    @recipients = '$($Ticket.EmailRecipients)',
    @subject = @Subject,
    @body = @Body
"@
    
    try {
        $connectionString = "Server=$($script:XFActsServerInstance);Database=$($script:XFActsDatabase);Integrated Security=True;Application Name=$($script:XFActsAppName)"
        $connection = New-Object System.Data.SqlClient.SqlConnection($connectionString)
        $connection.Open()
        
        $command = $connection.CreateCommand()
        $command.CommandText = $sqlQuery
        $command.Parameters.AddWithValue("@Subject", $subject) | Out-Null
        $command.Parameters.AddWithValue("@Body", $body) | Out-Null
        
        $command.ExecuteNonQuery() | Out-Null
        $connection.Close()
        
        Write-Log "Email fallback sent for QueueID $($Ticket.QueueID)" "SUCCESS"
        return $true
        
    } catch {
        Write-Log "Failed to send email fallback for QueueID $($Ticket.QueueID): $($_.Exception.Message)" "ERROR"
        return $false
    }
}

function Write-LogAPIRequest {
    param(
        [int]$QueueID,
        [string]$SourceModule,
        [string]$TriggerType,
        [string]$TriggerValue,
        [string]$ProjectKey,
        [string]$Summary,
        [string]$TicketKey,
        [int]$StatusCode,
        [string]$ResponseMessage,
        [string]$Assignee = $null
    )
    
    $sqlQuery = @"
INSERT INTO Jira.RequestLog (
    SourceModule,
    ServiceName,
    RequestType,
    ProjectKey,
    Summary,
    TicketKey,
    StatusCode,
    ResponseMessage,
    CreatedDate,
    CreatedBy,
    Trigger_Type,
    Trigger_Value,
    Jira_Assignee
)
VALUES (
    @SourceModule,
    'Jira',
    @TriggerType,
    @ProjectKey,
    @Summary,
    @TicketKey,
    @StatusCode,
    @ResponseMessage,
    GETDATE(),
    'PowerShell_Queue_Processor',
    @TriggerType,
    @TriggerValue,
    @Assignee
);
"@
    
    try {
        $connectionString = "Server=$($script:XFActsServerInstance);Database=$($script:XFActsDatabase);Integrated Security=True;Application Name=$($script:XFActsAppName)"
        $connection = New-Object System.Data.SqlClient.SqlConnection($connectionString)
        $connection.Open()
        
        $command = $connection.CreateCommand()
        $command.CommandText = $sqlQuery
        $command.Parameters.AddWithValue("@SourceModule", $(if ($SourceModule) { $SourceModule } else { "Unknown" })) | Out-Null
        $command.Parameters.AddWithValue("@TriggerType", $(if ($TriggerType) { $TriggerType } else { "UNKNOWN" })) | Out-Null
        $command.Parameters.AddWithValue("@ProjectKey", $(if ($ProjectKey) { $ProjectKey } else { [System.DBNull]::Value })) | Out-Null
        $command.Parameters.AddWithValue("@Summary", $(if ($Summary) { $Summary } else { [System.DBNull]::Value })) | Out-Null
        $command.Parameters.AddWithValue("@TriggerValue", $(if ($TriggerValue) { $TriggerValue } else { [System.DBNull]::Value })) | Out-Null
        $command.Parameters.AddWithValue("@TicketKey", $(if ($TicketKey) { $TicketKey } else { [System.DBNull]::Value })) | Out-Null
        $command.Parameters.AddWithValue("@StatusCode", $StatusCode) | Out-Null
        $command.Parameters.AddWithValue("@ResponseMessage", $(if ($ResponseMessage) { $ResponseMessage } else { [System.DBNull]::Value })) | Out-Null
        $command.Parameters.AddWithValue("@Assignee", $(if ($Assignee) { $Assignee } else { [System.DBNull]::Value })) | Out-Null
        
        $command.ExecuteNonQuery() | Out-Null
        $connection.Close()
        
    } catch {
        Write-Log "Failed to write to Jira.RequestLog: $($_.Exception.Message)" "WARN"
    }
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

$exitCode = 0
$scriptStart = Get-Date
$processedCount = 0
$successCount = 0
$failureCount = 0
$emailCount = 0

try {
    Write-Log "========================================" "INFO"
    Write-Log "Jira Ticket Queue Processor" "INFO"
    Write-Log "========================================" "INFO"
    Write-Log "Server: $ServerInstance" "INFO"
    Write-Log "Database: $Database" "INFO"
    Write-Log "Max Retries: $MaxRetries" "INFO"
    Write-Log "Batch Size: $BatchSize" "INFO"
    Write-Log "" "INFO"
    
    # Preview mode check
    if (-not $Execute) {
        Write-Log "PREVIEW MODE - No Jira API calls will be made. Run with -Execute to create tickets." "WARN"
        
        # Still show what would be processed
        Write-Log "Checking for pending tickets..." "INFO"
        $tickets = Get-PendingTickets -MaxRetries $MaxRetries -BatchSize $BatchSize
        
        $ticketList = @($tickets)
        if ($tickets -eq $null -or $ticketList.Count -eq 0) {
            Write-Log "No pending tickets found" "INFO"
        }
        else {
            Write-Log "Found $($ticketList.Count) pending ticket(s) that would be processed:" "INFO"
            foreach ($ticket in $ticketList) {
                Write-Log "  [PREVIEW] QueueID $($ticket.QueueID) [$($ticket.SourceModule)]: $($ticket.Summary)" "INFO"
            }
        }
        
        Write-Host "Processed: 0, Created: 0, Failed: 0, Emails: 0"
        if ($TaskId -gt 0) {
            Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
                -TaskId $TaskId -ProcessId $ProcessId `
                -Status "SUCCESS" -DurationMs 0 `
                -Output "Preview mode - no tickets processed"
        }
        exit 0
    }
    
    # Get Jira credentials via shared credential retrieval
    Write-Log "Retrieving Jira credentials..." "INFO"
    $credentials = Get-ServiceCredentials -ServiceName 'Jira'
    
    Write-Log "Checking for pending tickets..." "INFO"
    $tickets = Get-PendingTickets -MaxRetries $MaxRetries -BatchSize $BatchSize
    
    $ticketList = @($tickets)
    if ($tickets -eq $null -or $ticketList.Count -eq 0) {
        Write-Log "No pending tickets found" "INFO"
        Write-Log "========================================" "INFO"
        Write-Host "Processed: 0, Created: 0, Failed: 0, Emails: 0"
        if ($TaskId -gt 0) {
            Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
                -TaskId $TaskId -ProcessId $ProcessId `
                -Status "SUCCESS" -DurationMs 0 `
                -Output "No pending tickets to process"
        }
        exit 0
    }
    
    Write-Log "Found $($ticketList.Count) pending ticket(s) to process" "INFO"
    Write-Log "" "INFO"
    
    foreach ($ticket in $ticketList) {
        $processedCount++
        Write-Log "Processing QueueID $($ticket.QueueID) [$($ticket.SourceModule)]: $($ticket.Summary)" "INFO"
        
        $result = New-JiraTicket -Credentials $credentials -Ticket $ticket
        
        if ($result.Success) {
            $responseData = $result.ResponseBody | ConvertFrom-Json
            $ticketKey = $responseData.key
            
            Write-Log "  SUCCESS - Ticket created: $ticketKey" "SUCCESS"
            
            if ($result.Assignee) {
                Write-Log "  Assigned to: $($result.Assignee)" "INFO"
            } else {
                Write-Log "  No assignee set" "WARN"
            }
            
            Update-QueueStatus `
                -QueueID $ticket.QueueID -Status 'Success' -TicketKey $ticketKey `
                -StatusCode $result.StatusCode -ResponseMessage $result.ResponseBody `
                -RetryCount $ticket.RetryCount
            
            Write-LogAPIRequest `
                -QueueID $ticket.QueueID -SourceModule $ticket.SourceModule `
                -TriggerType $ticket.TriggerType -TriggerValue $ticket.TriggerValue `
                -ProjectKey $ticket.ProjectKey -Summary $ticket.Summary `
                -TicketKey $ticketKey -StatusCode $result.StatusCode `
                -ResponseMessage "Success" -Assignee $result.Assignee
            
            $successCount++
            
        } else {
            Write-Log "  FAILED - Status Code: $($result.StatusCode)" "ERROR"
            Write-Log "  Error: $($result.ResponseBody)" "ERROR"
            
            $newRetryCount = $ticket.RetryCount + 1
            
            if ($newRetryCount -ge $MaxRetries) {
                Write-Log "  Max retries reached ($MaxRetries), sending email fallback" "WARN"
                
                $emailSent = Send-EmailFallback `
                    -Ticket $ticket -ErrorMessage $result.ResponseBody
                
                $finalStatus = if ($emailSent) { 'EmailSent' } else { 'Failed' }
                
                Update-QueueStatus `
                    -QueueID $ticket.QueueID -Status $finalStatus `
                    -StatusCode $result.StatusCode -ResponseMessage $result.ResponseBody `
                    -RetryCount $newRetryCount
                
                if ($emailSent) { $emailCount++ }
                
            } else {
                Write-Log "  Will retry (attempt $newRetryCount of $MaxRetries)" "WARN"
                
                Update-QueueStatus `
                    -QueueID $ticket.QueueID -Status 'Failed' `
                    -StatusCode $result.StatusCode -ResponseMessage $result.ResponseBody `
                    -RetryCount $newRetryCount
            }
            
            Write-LogAPIRequest `
                -QueueID $ticket.QueueID -SourceModule $ticket.SourceModule `
                -TriggerType $ticket.TriggerType -TriggerValue $ticket.TriggerValue `
                -ProjectKey $ticket.ProjectKey -Summary $ticket.Summary `
                -TicketKey $null -StatusCode $result.StatusCode `
                -ResponseMessage $result.ResponseBody -Assignee $null
            
            $failureCount++
        }
        
        Write-Log "" "INFO"
    }
    
    Write-Log "========================================" "INFO"
    Write-Log "Processing Complete" "INFO"
    Write-Log "  Tickets Processed: $processedCount" "INFO"
    Write-Log "  Successful: $successCount" "SUCCESS"
    Write-Log "  Failed: $failureCount" $(if ($failureCount -gt 0) { "WARN" } else { "INFO" })
    Write-Log "  Emails Sent: $emailCount" "INFO"
    Write-Log "========================================" "INFO"
    
    # Output summary for orchestrator
    Write-Host "Processed: $processedCount, Created: $successCount, Failed: $failureCount, Emails: $emailCount"
    
    if ($failureCount -gt 0) {
        $exitCode = 1
    }
    
} catch {
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
            -Output "Processed: $processedCount, Created: $successCount, Failed: $failureCount, Emails: $emailCount"
    }
    exit $exitCode
# ============================================================================
# xFACts Control Center - Business Intelligence API Routes
# Location: E:\xFACts-ControlCenter\scripts\routes\BusinessIntelligence-API.ps1
# 
# API endpoints for the Business Intelligence departmental dashboard.
# 
# Notice Recon endpoints query the Notice_Recon AG database via secondary
# replica using Invoke-AGReadQuery.
#
# Endpoints:
#   GET  /api/business-intelligence/notice-recon        - Today's execution summary
#   GET  /api/business-intelligence/notice-recon-steps  - Step detail for an execution
#
# Version: Tracked in dbo.System_Metadata (component: DeptOps.BusinessIntelligence)
# ============================================================================

# ============================================================================
# NOTICE RECON - AG secondary reads against Notice_Recon database
# ============================================================================

# GET /api/business-intelligence/notice-recon
# Returns today's process execution summary (one row per process)
Add-PodeRoute -Method Get -Path '/api/business-intelligence/notice-recon' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $results = Invoke-AGReadQuery -Database 'Notice_Recon' -Query @"
            SELECT 
                Execution_ID,
                Process_Name,
                Execution_Start_Time,
                Execution_End_Time,
                Execution_Duration_Seconds,
                Execution_Status,
                Total_Records_Processed,
                Records_Inserted_Document,
                Records_Inserted_Account,
                Records_Updated_DM,
                New_Notice_Types_Detected,
                Error_Message
            FROM dbo.Process_Execution_Log
            WHERE CAST(Execution_Start_Time AS DATE) = CAST(GETDATE() AS DATE)
            ORDER BY Execution_Start_Time
"@

        $executions = @()
        foreach ($row in $results) {
            $executions += @{
                execution_id             = $row.Execution_ID
                process_name             = $row.Process_Name
                start_time               = if ($row.Execution_Start_Time -is [DBNull]) { $null } else { $row.Execution_Start_Time.ToString("yyyy-MM-ddTHH:mm:ss") }
                end_time                 = if ($row.Execution_End_Time -is [DBNull]) { $null } else { $row.Execution_End_Time.ToString("yyyy-MM-ddTHH:mm:ss") }
                duration_seconds         = if ($row.Execution_Duration_Seconds -is [DBNull]) { $null } else { [int]$row.Execution_Duration_Seconds }
                status                   = if ($row.Execution_Status -is [DBNull]) { 'Unknown' } else { $row.Execution_Status }
                total_records            = if ($row.Total_Records_Processed -is [DBNull]) { 0 } else { [int]$row.Total_Records_Processed }
                records_document         = if ($row.Records_Inserted_Document -is [DBNull]) { 0 } else { [int]$row.Records_Inserted_Document }
                records_account          = if ($row.Records_Inserted_Account -is [DBNull]) { 0 } else { [int]$row.Records_Inserted_Account }
                records_updated_dm       = if ($row.Records_Updated_DM -is [DBNull]) { 0 } else { [int]$row.Records_Updated_DM }
                new_notice_types         = if ($row.New_Notice_Types_Detected -is [DBNull]) { 0 } else { [int]$row.New_Notice_Types_Detected }
                error_message            = if ($row.Error_Message -is [DBNull]) { $null } else { $row.Error_Message }
            }
        }

        Write-PodeJsonResponse -Value @{ executions = $executions }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# GET /api/business-intelligence/notice-recon-steps?execution_id={id}
# Returns step-level detail for a specific execution
Add-PodeRoute -Method Get -Path '/api/business-intelligence/notice-recon-steps' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $executionId = $WebEvent.Query['execution_id']
        if (-not $executionId) {
            Write-PodeJsonResponse -Value @{ error = 'Missing execution_id parameter' } -StatusCode 400
            return
        }

        $results = Invoke-AGReadQuery -Database 'Notice_Recon' -Query @"
            SELECT 
                Step_Number,
                Step_Name,
                Step_Start_Time,
                Step_End_Time,
                Step_Duration_Seconds,
                Step_Status,
                Rows_Affected,
                Step_Message,
                Error_Message,
                Step_Type_Code
            FROM dbo.Process_Step_Log
            WHERE Execution_ID = @execId
            ORDER BY Step_Number
"@ -Parameters @{ execId = [int]$executionId }

        $steps = @()
        foreach ($row in $results) {
            $steps += @{
                step_number      = [int]$row.Step_Number
                step_name        = $row.Step_Name
                start_time       = if ($row.Step_Start_Time -is [DBNull]) { $null } else { $row.Step_Start_Time.ToString("yyyy-MM-ddTHH:mm:ss") }
                end_time         = if ($row.Step_End_Time -is [DBNull]) { $null } else { $row.Step_End_Time.ToString("yyyy-MM-ddTHH:mm:ss") }
                duration_seconds = if ($row.Step_Duration_Seconds -is [DBNull]) { 0 } else { [int]$row.Step_Duration_Seconds }
                status           = if ($row.Step_Status -is [DBNull]) { 'Unknown' } else { $row.Step_Status }
                rows_affected    = if ($row.Rows_Affected -is [DBNull]) { $null } else { [int]$row.Rows_Affected }
                message          = if ($row.Step_Message -is [DBNull]) { $null } else { $row.Step_Message }
                error_message    = if ($row.Error_Message -is [DBNull]) { $null } else { $row.Error_Message }
                type_code        = if ($row.Step_Type_Code -is [DBNull]) { $null } else { $row.Step_Type_Code }
            }
        }

        Write-PodeJsonResponse -Value @{ steps = $steps }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}
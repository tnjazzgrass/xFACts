<#
.SYNOPSIS
    xFACts - DmOps shared consumer-deletion engine.

.DESCRIPTION
    xFACts - DmOps

    Shared function library for the DmOps consumer-deletion scripts
    (Execute-DmConsumerArchive.ps1 and Execute-DmShellPurge.ps1). Centralizes
    the persistent-connection management, chunked snapshot-isolation DELETE and
    UPDATE primitives, per-table operation wrappers with the preview/execute
    split, and the stop-on-failure step wrappers that both scripts share.

    Consumer contract. The operation wrappers call Write-dmo_BatchDetail and
    accumulate into the script-level counters $script:dmo_TablesProcessed,
    $script:dmo_TablesSkipped, $script:dmo_TablesFailed, and
    $script:dmo_TotalDeleted. Write-dmo_BatchDetail writes to the audit table
    named in $script:dmo_BatchDetailTable and reads the current batch id from
    $script:dmo_CurrentBatchId. The connection primitives operate on the
    script-level handle $script:dmo_TargetConnection, and the chunked DML reads
    the chunk size from $script:dmo_BatchChunkSize. Each consuming script
    declares those script-level names, setting $script:dmo_BatchDetailTable to
    its own per-script audit detail table.

    Load order. Dot-source this file AFTER xFACts-OrchestratorFunctions.ps1 in
    the consuming script's IMPORTS section, so Write-Log and the console helpers
    resolve.

.COMPONENT
    DmOps

.NOTES
    File Name : xFACts-DmOpsFunctions.ps1
    Location  : E:\xFACts-PowerShell\xFACts-DmOpsFunctions.ps1

    FILE ORGANIZATION
    -----------------
    CHANGELOG: CHANGE HISTORY
    FUNCTIONS: CONNECTION MANAGEMENT
    FUNCTIONS: SQL PRIMITIVES
    FUNCTIONS: BATCH LOGGING
    FUNCTIONS: OPERATION WRAPPERS
    FUNCTIONS: STEP WRAPPERS
    FUNCTIONS: SCHEDULE AND CONTROL
#>

<# ============================================================================
   CHANGELOG: CHANGE HISTORY
   ----------------------------------------------------------------------------
   Dated change history for this script. Most recent first.
   Prefix: (none)
   ============================================================================ #>

# 2026-06-18  Added FUNCTIONS: SCHEDULE AND CONTROL with Test-dmo_AbortFlag and
#             Get-dmo_ScheduleMode, parameterized shared replacements for the
#             per-consumer schedule-mode and abort-flag checks that previously
#             lived as Archive/Shell-specific copies in the two execute scripts.
#             Test-dmo_AbortFlag takes -Category and -SettingName; Get-dmo_ScheduleMode
#             takes -ScheduleTable. Behavior preserved exactly; only the varying
#             table name and GlobalConfig category/setting are now parameters.
# 2026-06-16  Added Write-dmo_BatchDetail (FUNCTIONS: BATCH LOGGING) as a shared
#             audit writer. The operation wrappers previously called a copy
#             defined locally in each consuming script; that inverted dependency
#             left the shared call unresolved against any cataloged definition.
#             The writer now lives here and targets the table named in
#             $script:dmo_BatchDetailTable, which each consumer sets to its own
#             audit detail table.
#             Initial extraction. Connection management, chunked SQL primitives,
#             operation wrappers, and step wrappers lifted unchanged from
#             Execute-DmConsumerArchive.ps1 into a DmOps-scoped shared library so
#             Execute-DmConsumerArchive.ps1 and Execute-DmShellPurge.ps1 share one
#             definition of each rather than maintaining parallel copies.

<# ============================================================================
   FUNCTIONS: CONNECTION MANAGEMENT
   ----------------------------------------------------------------------------
   Open and close the persistent SqlConnection to the crs5_oltp target
   instance. Both operate on the script-level $script:dmo_TargetConnection
   handle declared by the consuming script.
   Prefix: dmo
   ============================================================================ #>

# Opens the persistent SqlConnection to the crs5_oltp target instance.
function Open-dmo_TargetConnection {
    param()

    try {
        $connString = "Server=$($script:dmo_TargetServer);Database=crs5_oltp;Integrated Security=True;Application Name=$($script:XFActsAppName);Connect Timeout=30"
        $script:dmo_TargetConnection = New-Object System.Data.SqlClient.SqlConnection($connString)
        $script:dmo_TargetConnection.Open()
        Write-Log "  Persistent connection opened to $($script:dmo_TargetServer)/crs5_oltp" "SUCCESS"
        return $true
    }
    catch {
        Write-Log "Failed to open connection to $($script:dmo_TargetServer): $($_.Exception.Message)" "ERROR"
        return $false
    }
}

# Closes the persistent crs5_oltp target connection if open.
function Close-dmo_TargetConnection {
    param()

    if ($script:dmo_TargetConnection -and $script:dmo_TargetConnection.State -eq 'Open') {
        $script:dmo_TargetConnection.Close()
        $script:dmo_TargetConnection.Dispose()
        $script:dmo_TargetConnection = $null
        Write-Log "  Persistent connection closed" "INFO"
    }
}

<# ============================================================================
   FUNCTIONS: SQL PRIMITIVES
   ----------------------------------------------------------------------------
   Low-level query, delete, and update primitives that run against the
   persistent crs5_oltp connection with snapshot isolation, deadlock retry,
   and chunking. Chunk size is read from $script:dmo_BatchChunkSize.
   Prefix: dmo
   ============================================================================ #>

# Runs a read query against the persistent crs5_oltp connection and returns a DataTable.
function Invoke-dmo_TargetQuery {
    param(
        [Parameter(Mandatory)]
        [string]$Query,
        [int]$Timeout = 300
    )

    $cmd = $script:dmo_TargetConnection.CreateCommand()
    $cmd.CommandText = $Query
    $cmd.CommandTimeout = $Timeout

    $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
    $dataTable = New-Object System.Data.DataTable

    try {
        [void]$adapter.Fill($dataTable)
        return ,$dataTable
    }
    catch {
        throw $_
    }
    finally {
        $cmd.Dispose()
        $adapter.Dispose()
    }
}

# Executes a chunked DELETE against crs5_oltp with snapshot isolation and deadlock retry.
function Invoke-dmo_TargetDelete {
    param(
        [Parameter(Mandatory)]
        [string]$DeleteSQL,
        [int]$Timeout = 600,
        [int]$MaxRetries = 10,
        [int]$RetryDelaySeconds = 5
    )

    $totalRowsDeleted = 0
    $chunkNumber = 0

    $chunkedSQL = $DeleteSQL -replace '(?i)^DELETE\s+(FROM\s+)', "DELETE TOP ($($script:dmo_BatchChunkSize)) `$1"
    $chunkedSQL = $chunkedSQL -replace '(?i)^DELETE\s+(\w+)\s+(FROM\s+)', "DELETE TOP ($($script:dmo_BatchChunkSize)) `$1 `$2"

    while ($true) {
        $chunkNumber++
        $retryCount = 0
        $chunkDeleted = -1

        while ($retryCount -lt $MaxRetries) {
            $cmd = $script:dmo_TargetConnection.CreateCommand()
            $cmd.CommandTimeout = $Timeout

            try {
                $cmd.CommandText = @"
SET DEADLOCK_PRIORITY LOW;
SET TRANSACTION ISOLATION LEVEL SNAPSHOT;
$chunkedSQL
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
"@
                $chunkDeleted = $cmd.ExecuteNonQuery()
                break
            }
            catch {
                $errNum = 0
                $innerEx = $_.Exception
                while ($innerEx.InnerException) { $innerEx = $innerEx.InnerException }
                if ($innerEx -is [System.Data.SqlClient.SqlException]) {
                    $errNum = $innerEx.Number
                }

                if ($errNum -in @(1204, 1205, 1222, 3960)) {
                    $retryCount++
                    if ($retryCount -ge $MaxRetries) {
                        Write-Log "      Retry limit ($MaxRetries) exceeded on chunk $chunkNumber" "ERROR"
                        throw $_
                    }
                    Write-Log "      Retryable error ($errNum), attempt $retryCount/$MaxRetries - waiting ${RetryDelaySeconds}s..." "WARN"
                    Start-Sleep -Seconds $RetryDelaySeconds

                    try {
                        $resetCmd = $script:dmo_TargetConnection.CreateCommand()
                        $resetCmd.CommandText = "SET TRANSACTION ISOLATION LEVEL READ COMMITTED;"
                        $resetCmd.ExecuteNonQuery() | Out-Null
                        $resetCmd.Dispose()
                    } catch { }
                }
                else {
                    throw $_
                }
            }
            finally {
                $cmd.Dispose()
            }
        }

        if ($chunkDeleted -le 0) { break }

        $totalRowsDeleted += $chunkDeleted

        if ($chunkDeleted -lt $script:dmo_BatchChunkSize) { break }

        Start-Sleep -Milliseconds 100
    }

    return $totalRowsDeleted
}

# Executes a chunked UPDATE against crs5_oltp with snapshot isolation and deadlock retry.
function Invoke-dmo_TargetUpdate {
    param(
        [Parameter(Mandatory)]
        [string]$UpdateSQL,
        [int]$Timeout = 600,
        [int]$MaxRetries = 10,
        [int]$RetryDelaySeconds = 5
    )

    $totalRowsUpdated = 0
    $chunkNumber = 0

    $chunkedSQL = $UpdateSQL -replace '(?i)^UPDATE\s+', "UPDATE TOP ($($script:dmo_BatchChunkSize)) "

    while ($true) {
        $chunkNumber++
        $retryCount = 0
        $chunkUpdated = -1

        while ($retryCount -lt $MaxRetries) {
            $cmd = $script:dmo_TargetConnection.CreateCommand()
            $cmd.CommandTimeout = $Timeout

            try {
                $cmd.CommandText = @"
SET DEADLOCK_PRIORITY LOW;
SET TRANSACTION ISOLATION LEVEL SNAPSHOT;
$chunkedSQL
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
"@
                $chunkUpdated = $cmd.ExecuteNonQuery()
                break
            }
            catch {
                $errNum = 0
                $innerEx = $_.Exception
                while ($innerEx.InnerException) { $innerEx = $innerEx.InnerException }
                if ($innerEx -is [System.Data.SqlClient.SqlException]) {
                    $errNum = $innerEx.Number
                }

                if ($errNum -in @(1204, 1205, 1222, 3960)) {
                    $retryCount++
                    if ($retryCount -ge $MaxRetries) {
                        Write-Log "      Retry limit ($MaxRetries) exceeded on chunk $chunkNumber" "ERROR"
                        throw $_
                    }
                    Write-Log "      Retryable error ($errNum), attempt $retryCount/$MaxRetries - waiting ${RetryDelaySeconds}s..." "WARN"
                    Start-Sleep -Seconds $RetryDelaySeconds

                    try {
                        $resetCmd = $script:dmo_TargetConnection.CreateCommand()
                        $resetCmd.CommandText = "SET TRANSACTION ISOLATION LEVEL READ COMMITTED;"
                        $resetCmd.ExecuteNonQuery() | Out-Null
                        $resetCmd.Dispose()
                    } catch { }
                }
                else {
                    throw $_
                }
            }
            finally {
                $cmd.Dispose()
            }
        }

        if ($chunkUpdated -le 0) { break }

        $totalRowsUpdated += $chunkUpdated

        if ($chunkUpdated -lt $script:dmo_BatchChunkSize) { break }

        Start-Sleep -Milliseconds 100
    }

    return $totalRowsUpdated
}

<# ============================================================================
   FUNCTIONS: BATCH LOGGING
   ----------------------------------------------------------------------------
   Audit-trail writer for the per-table per-pass operation detail. Writes to
   the table named in $script:dmo_BatchDetailTable using the batch id in
   $script:dmo_CurrentBatchId. Early-returns in preview mode, emitting no
   database write.
   Prefix: dmo
   ============================================================================ #>

# Inserts one operation-detail row recording a single table/pass operation into the consumer's $script:dmo_BatchDetailTable.
function Write-dmo_BatchDetail {
    param(
        [string]$DeleteOrder,
        [string]$TableName,
        [string]$PassDescription,
        [long]$RowsAffected,
        [int]$DurationMs,
        [string]$Status,
        [string]$ErrorMessage = $null
    )

    if (-not $script:XFActsExecute) { return }
    if (-not $script:dmo_CurrentBatchId) { return }

    $escapedPass = if ($PassDescription) { "'$($PassDescription.Replace("'", "''"))'" } else { "NULL" }
    $escapedError = if ($ErrorMessage) { "'$($ErrorMessage.Replace("'", "''").Substring(0, [Math]::Min($ErrorMessage.Length, 2000)))'" } else { "NULL" }
    $durationClause = if ($DurationMs -ge 0) { "$DurationMs" } else { "NULL" }

    try {
        Invoke-SqlNonQuery -Query @"
            INSERT INTO $($script:dmo_BatchDetailTable)
                (batch_id, delete_order, table_name, pass_description, rows_affected, duration_ms, status, error_message)
            VALUES
                ($($script:dmo_CurrentBatchId), '$DeleteOrder', '$TableName', $escapedPass, $RowsAffected, $durationClause, '$Status', $escapedError)
"@ -Timeout 30 | Out-Null
    }
    catch {
        Write-Log "  Failed to write batch detail: $($_.Exception.Message)" "WARN"
    }
}

<# ============================================================================
   FUNCTIONS: OPERATION WRAPPERS
   ----------------------------------------------------------------------------
   Per-table delete and update operations with logging, error handling, and
   the preview/execute split. Each accumulates into the consumer's
   $script:dmo_Tables* counters and calls Write-dmo_BatchDetail.
   Prefix: dmo
   ============================================================================ #>

# Executes a single-table delete with counting in preview and chunked deletion in execute mode.
function Invoke-dmo_TableDelete {
    param(
        [Parameter(Mandatory)]
        $Order,
        [Parameter(Mandatory)]
        [string]$TableName,
        [Parameter(Mandatory)]
        [string]$WhereClause,
        [string]$PassDescription = "",
        [bool]$PreviewOnly = $true
    )

    $passLabel = if ($PassDescription) { " ($PassDescription)" } else { "" }
    $fullTable = "crs5_oltp.dbo.$TableName"

    if ($PreviewOnly) {
        try {
            $countResult = Invoke-dmo_TargetQuery -Query "SELECT COUNT(*) AS row_count FROM $fullTable WHERE $WhereClause" -Timeout 300
            $previewCount = [long]$countResult.Rows[0].row_count
            if ($previewCount -eq 0) {
                Write-Log "  [$Order] $TableName$passLabel - no rows, skipping" "DEBUG"
                $script:dmo_TablesSkipped++
                Write-dmo_BatchDetail -DeleteOrder "$Order" -TableName $TableName -PassDescription $PassDescription `
                    -RowsAffected 0 -DurationMs 0 -Status 'Skipped'
            } else {
                Write-Log "  [$Order] $TableName$passLabel - would delete $previewCount rows" "INFO"
                $script:dmo_TotalDeleted += $previewCount
                $script:dmo_TablesProcessed++
                Write-dmo_BatchDetail -DeleteOrder "$Order" -TableName $TableName -PassDescription $PassDescription `
                    -RowsAffected $previewCount -DurationMs 0 -Status 'Success'
            }
            return $true
        }
        catch {
            Write-Log "  [$Order] $TableName$passLabel - count failed: $($_.Exception.Message)" "WARN"
            $script:dmo_TablesFailed++
            Write-dmo_BatchDetail -DeleteOrder "$Order" -TableName $TableName -PassDescription $PassDescription `
                -RowsAffected 0 -DurationMs 0 -Status 'Failed' -ErrorMessage $_.Exception.Message
            return $false
        }
    }
    else {
        $deleteSQL = "DELETE FROM $fullTable WHERE $WhereClause"
        $deleteStart = Get-Date

        try {
            $rowsDeleted = Invoke-dmo_TargetDelete -DeleteSQL $deleteSQL
            $durationMs = [int]((Get-Date) - $deleteStart).TotalMilliseconds
            if ($rowsDeleted -eq 0) {
                Write-Log "  [$Order] $TableName$passLabel - no rows, skipping" "DEBUG"
                $script:dmo_TablesSkipped++
                Write-dmo_BatchDetail -DeleteOrder "$Order" -TableName $TableName -PassDescription $PassDescription `
                    -RowsAffected 0 -DurationMs $durationMs -Status 'Skipped'
            } else {
                Write-Log "  [$Order] $TableName$passLabel - deleted $rowsDeleted rows (${durationMs}ms)" "SUCCESS"
                $script:dmo_TotalDeleted += $rowsDeleted
                $script:dmo_TablesProcessed++
                Write-dmo_BatchDetail -DeleteOrder "$Order" -TableName $TableName -PassDescription $PassDescription `
                    -RowsAffected $rowsDeleted -DurationMs $durationMs -Status 'Success'
            }
            return $true
        }
        catch {
            $durationMs = [int]((Get-Date) - $deleteStart).TotalMilliseconds
            Write-Log "  [$Order] $TableName$passLabel - FAILED (${durationMs}ms): $($_.Exception.Message)" "ERROR"
            $script:dmo_TablesFailed++
            Write-dmo_BatchDetail -DeleteOrder "$Order" -TableName $TableName -PassDescription $PassDescription `
                -RowsAffected 0 -DurationMs $durationMs -Status 'Failed' -ErrorMessage $_.Exception.Message
            return $false
        }
    }
}

# Executes a DELETE-with-JOIN operation with counting in preview and chunked deletion in execute mode.
function Invoke-dmo_JoinTableDelete {
    param(
        [Parameter(Mandatory)]
        $Order,
        [Parameter(Mandatory)]
        [string]$TableName,
        [Parameter(Mandatory)]
        [string]$DeleteStatement,
        [string]$CountQuery,
        [string]$PassDescription = "",
        [bool]$PreviewOnly = $true
    )

    $passLabel = if ($PassDescription) { " ($PassDescription)" } else { "" }

    if ($PreviewOnly) {
        try {
            $countResult = Invoke-dmo_TargetQuery -Query $CountQuery -Timeout 300
            $previewCount = [long]$countResult.Rows[0].row_count
            if ($previewCount -eq 0) {
                Write-Log "  [$Order] $TableName$passLabel - no rows, skipping" "DEBUG"
                $script:dmo_TablesSkipped++
                Write-dmo_BatchDetail -DeleteOrder "$Order" -TableName $TableName -PassDescription $PassDescription `
                    -RowsAffected 0 -DurationMs 0 -Status 'Skipped'
            } else {
                Write-Log "  [$Order] $TableName$passLabel - would delete $previewCount rows" "INFO"
                $script:dmo_TotalDeleted += $previewCount
                $script:dmo_TablesProcessed++
                Write-dmo_BatchDetail -DeleteOrder "$Order" -TableName $TableName -PassDescription $PassDescription `
                    -RowsAffected $previewCount -DurationMs 0 -Status 'Success'
            }
            return $true
        }
        catch {
            Write-Log "  [$Order] $TableName$passLabel - count failed: $($_.Exception.Message)" "WARN"
            $script:dmo_TablesFailed++
            Write-dmo_BatchDetail -DeleteOrder "$Order" -TableName $TableName -PassDescription $PassDescription `
                -RowsAffected 0 -DurationMs 0 -Status 'Failed' -ErrorMessage $_.Exception.Message
            return $false
        }
    }
    else {
        $deleteStart = Get-Date
        try {
            $rowsDeleted = Invoke-dmo_TargetDelete -DeleteSQL $DeleteStatement
            $durationMs = [int]((Get-Date) - $deleteStart).TotalMilliseconds
            if ($rowsDeleted -eq 0) {
                Write-Log "  [$Order] $TableName$passLabel - no rows, skipping" "DEBUG"
                $script:dmo_TablesSkipped++
                Write-dmo_BatchDetail -DeleteOrder "$Order" -TableName $TableName -PassDescription $PassDescription `
                    -RowsAffected 0 -DurationMs $durationMs -Status 'Skipped'
            } else {
                Write-Log "  [$Order] $TableName$passLabel - deleted $rowsDeleted rows (${durationMs}ms)" "SUCCESS"
                $script:dmo_TotalDeleted += $rowsDeleted
                $script:dmo_TablesProcessed++
                Write-dmo_BatchDetail -DeleteOrder "$Order" -TableName $TableName -PassDescription $PassDescription `
                    -RowsAffected $rowsDeleted -DurationMs $durationMs -Status 'Success'
            }
            return $true
        }
        catch {
            $durationMs = [int]((Get-Date) - $deleteStart).TotalMilliseconds
            Write-Log "  [$Order] $TableName$passLabel - FAILED (${durationMs}ms): $($_.Exception.Message)" "ERROR"
            $script:dmo_TablesFailed++
            Write-dmo_BatchDetail -DeleteOrder "$Order" -TableName $TableName -PassDescription $PassDescription `
                -RowsAffected 0 -DurationMs $durationMs -Status 'Failed' -ErrorMessage $_.Exception.Message
            return $false
        }
    }
}

# Executes a single-table update with counting in preview and chunked update in execute mode.
function Invoke-dmo_TableUpdate {
    param(
        [Parameter(Mandatory)]
        $Order,
        [Parameter(Mandatory)]
        [string]$TableName,
        [Parameter(Mandatory)]
        [string]$UpdateStatement,
        [string]$CountQuery,
        [string]$PassDescription = "",
        [bool]$PreviewOnly = $true
    )

    $passLabel = if ($PassDescription) { " ($PassDescription)" } else { "" }

    if ($PreviewOnly) {
        try {
            $countResult = Invoke-dmo_TargetQuery -Query $CountQuery -Timeout 300
            $previewCount = [long]$countResult.Rows[0].row_count
            if ($previewCount -eq 0) {
                Write-Log "  [$Order] $TableName$passLabel - no rows, skipping" "DEBUG"
                $script:dmo_TablesSkipped++
                Write-dmo_BatchDetail -DeleteOrder "$Order" -TableName $TableName -PassDescription $PassDescription `
                    -RowsAffected 0 -DurationMs 0 -Status 'Skipped'
            } else {
                Write-Log "  [$Order] $TableName$passLabel - would update $previewCount rows" "INFO"
                $script:dmo_TablesProcessed++
                Write-dmo_BatchDetail -DeleteOrder "$Order" -TableName $TableName -PassDescription $PassDescription `
                    -RowsAffected $previewCount -DurationMs 0 -Status 'Success'
            }
            return $true
        }
        catch {
            Write-Log "  [$Order] $TableName$passLabel - count failed: $($_.Exception.Message)" "WARN"
            $script:dmo_TablesFailed++
            Write-dmo_BatchDetail -DeleteOrder "$Order" -TableName $TableName -PassDescription $PassDescription `
                -RowsAffected 0 -DurationMs 0 -Status 'Failed' -ErrorMessage $_.Exception.Message
            return $false
        }
    }
    else {
        $updateStart = Get-Date
        try {
            $rowsUpdated = Invoke-dmo_TargetUpdate -UpdateSQL $UpdateStatement
            $durationMs = [int]((Get-Date) - $updateStart).TotalMilliseconds
            if ($rowsUpdated -eq 0) {
                Write-Log "  [$Order] $TableName$passLabel - no rows, skipping" "DEBUG"
                $script:dmo_TablesSkipped++
                Write-dmo_BatchDetail -DeleteOrder "$Order" -TableName $TableName -PassDescription $PassDescription `
                    -RowsAffected 0 -DurationMs $durationMs -Status 'Skipped'
            } else {
                Write-Log "  [$Order] $TableName$passLabel - updated $rowsUpdated rows (${durationMs}ms)" "SUCCESS"
                $script:dmo_TablesProcessed++
                Write-dmo_BatchDetail -DeleteOrder "$Order" -TableName $TableName -PassDescription $PassDescription `
                    -RowsAffected $rowsUpdated -DurationMs $durationMs -Status 'Success'
            }
            return $true
        }
        catch {
            $durationMs = [int]((Get-Date) - $updateStart).TotalMilliseconds
            Write-Log "  [$Order] $TableName$passLabel - FAILED (${durationMs}ms): $($_.Exception.Message)" "ERROR"
            $script:dmo_TablesFailed++
            Write-dmo_BatchDetail -DeleteOrder "$Order" -TableName $TableName -PassDescription $PassDescription `
                -RowsAffected 0 -DurationMs $durationMs -Status 'Failed' -ErrorMessage $_.Exception.Message
            return $false
        }
    }
}

<# ============================================================================
   FUNCTIONS: STEP WRAPPERS
   ----------------------------------------------------------------------------
   Thin wrappers over the operation functions that set the consumer's
   $script:dmo_StopProcessing flag on failure so the batch halts safely at
   the first error.
   Prefix: dmo
   ============================================================================ #>

# Wraps Invoke-dmo_TableDelete, setting the stop flag on failure.
function Step-dmo_Delete {
    param([hashtable]$Params)
    if ($script:dmo_StopProcessing) { return }
    $ok = Invoke-dmo_TableDelete @Params -PreviewOnly (-not $script:XFActsExecute)
    if (-not $ok) {
        Write-Log "  STOPPING - cannot safely continue after failure at order $($Params.Order)" "ERROR"
        $script:dmo_StopProcessing = $true
    }
}

# Wraps Invoke-dmo_JoinTableDelete, setting the stop flag on failure.
function Step-dmo_JoinDelete {
    param([hashtable]$Params)
    if ($script:dmo_StopProcessing) { return }
    $ok = Invoke-dmo_JoinTableDelete @Params -PreviewOnly (-not $script:XFActsExecute)
    if (-not $ok) {
        Write-Log "  STOPPING - cannot safely continue after failure at order $($Params.Order)" "ERROR"
        $script:dmo_StopProcessing = $true
    }
}

# Wraps Invoke-dmo_TableUpdate, setting the stop flag on failure.
function Step-dmo_Update {
    param([hashtable]$Params)
    if ($script:dmo_StopProcessing) { return }
    $ok = Invoke-dmo_TableUpdate @Params -PreviewOnly (-not $script:XFActsExecute)
    if (-not $ok) {
        Write-Log "  STOPPING - cannot safely continue after failure at order $($Params.Order)" "ERROR"
        $script:dmo_StopProcessing = $true
    }
}

<# ============================================================================
   FUNCTIONS: SCHEDULE AND CONTROL
   ----------------------------------------------------------------------------
   Read-only control-plane checks consulted before and between batches: the
   per-hour schedule mode from a DmOps schedule table and the GlobalConfig
   emergency-abort flag. Both fail safe (treat errors as blocked / not-aborted)
   so a transient read failure never silently runs unscheduled work.
   Prefix: dmo
   ============================================================================ #>

# Returns the current hour's integer schedule mode from the given DmOps schedule table.
function Get-dmo_ScheduleMode {
    param(
        [Parameter(Mandatory)]
        [string]$ScheduleTable
    )

    $currentHour = (Get-Date).Hour
    $hrCol = "hr{0:D2}" -f $currentHour

    try {
        $result = Get-SqlData -Query @"
            SELECT $hrCol AS schedule_mode
            FROM $ScheduleTable
            WHERE day_of_week = DATEPART(dw, GETDATE())
"@
        if ($result) {
            return [int]$result.schedule_mode
        }
        Write-Log "  No schedule row found for today - treating as blocked" "WARN"
        return 0
    }
    catch {
        Write-Log "  Failed to read schedule: $($_.Exception.Message) - treating as blocked" "WARN"
        return 0
    }
}

# Returns true when the named GlobalConfig abort flag is set for the given category.
function Test-dmo_AbortFlag {
    param(
        [Parameter(Mandatory)]
        [string]$Category,
        [Parameter(Mandatory)]
        [string]$SettingName
    )

    try {
        $result = Get-SqlData -Query @"
            SELECT setting_value FROM dbo.GlobalConfig
            WHERE module_name = 'DmOps' AND category = '$Category'
              AND setting_name = '$SettingName' AND is_active = 1
"@
        if ($result -and $result.setting_value -eq '1') {
            return $true
        }
        return $false
    }
    catch {
        Write-Log "  Failed to check abort flag - proceeding cautiously" "WARN"
        return $false
    }
}
# DmOps Phase 2: Collector Script Build Plan

**Date:** March 8, 2026  
**Status:** Ready to build. Firewall access confirmed. Tables deployed.

---

## Overview

Complete rewrite of `Collect-DmHealthMetrics.ps1` to expand from HTTP/CIM-only collection to include JBoss Management API metrics, per-queue JMS stats, and configuration change detection. One script, one ProcessRegistry entry (already exists), 60-second cycle, writing to three tables.

---

## Collection Sequence Per Cycle

Each cycle performs these steps in order for each DmOps-enabled APP_SERVER in ServerRegistry:

1. **HTTP health check** (existing) — `Invoke-WebRequest` to DM splash page per server
2. **CIM metrics** (existing) — one CIM session per server for service state (Win32_Service for DebtManager-Host), JBoss process metrics (Win32_Process, largest java.exe by WorkingSetSize), uptime (Win32_OperatingSystem)
3. **Management API — health composite** (new) — one composite REST call per server to the domain controller fetching: server state, JVM memory (heap used/max, non-heap used), JVM threads (current/peak), Undertow HTTP stats (request count, error count, bytes sent, processing time, max processing time), IO worker queue size, transactions (committed, inflight, timed out, rollbacks, aborted, heuristics), main datasource pool stats (active, in-use, idle, wait, max-used, timed-out, avg-get-time, max-wait-time)
4. **Management API — queue composite** (new) — one composite REST call per server fetching stats for all active queues (~18 queues): message_count, delivering_count, consumer_count, messages_added
5. **Management API — config check** (new) — one composite REST call per server fetching config values. Compared against last known values cached in script memory. Only writes to App_ConfigHistory on change or first run.
6. **Database writes** — one INSERT per server to App_Snapshot (all health metrics in one row), ~54 INSERTs total to App_QueueSnapshot (~18 queues × 3 servers), 0-N INSERTs to App_ConfigHistory (only on detected change)

**Total per cycle: ~1-2 seconds, 9 API calls to JBoss, 3 HTTP checks, 3 CIM sessions, ~60 database inserts.**

---

## Technical Details

### Management API Access

- **Endpoint:** `http://dm-prod-app:9990/management` (domain controller — fans out to APP2/APP3 internally)
- **Authentication:** JBossManagement service credentials from `dbo.Credentials` via `Get-ServiceCredentials -ServiceName 'JBossManagement'`
- **Domain controller identification:** ServerRegistry `is_domain_controller = 1` flag
- **JSON format:** Hand-built JSON strings required — PowerShell 5.1 `ConvertTo-Json` does not reliably serialize the nested array-of-objects address format JBoss requires
- **Composite operations:** Multiple reads batched into a single `"operation": "composite"` POST with a `"steps"` array. Returns all results in one response. ~65ms per composite call per server.

### Address Path Format (per server)

Server instance naming: `{hostname}-inst1` (e.g., `dm-prod-app2-inst1`)

Each composite step requires an address array targeting the specific server instance:
```json
{"host":"dm-prod-app2"},{"server":"dm-prod-app2-inst1"}
```

### Health Composite — Steps Per Server

| Step | Address Path (after server) | Metric |
|---|---|---|
| Server state | (none — read-attribute on server) | `server-state` attribute |
| JVM Memory | `core-service=platform-mbean`, `type=memory` | heap-memory-usage, non-heap-memory-usage |
| JVM Threads | `core-service=platform-mbean`, `type=threading` | thread-count, peak-thread-count |
| Datasource Pool | `subsystem=datasources`, `data-source=dataSource`, `statistics=pool` | ActiveCount, InUseCount, IdleCount, WaitCount, MaxUsedCount, TimedOut, AverageGetTime, MaxWaitTime |
| Undertow HTTP | `subsystem=undertow`, `server=default-server`, `http-listener=http` | request-count, error-count, bytes-sent, processing-time, max-processing-time |
| Transactions | `subsystem=transactions` | number-of-committed-transactions, number-of-inflight-transactions, number-of-timed-out-transactions, number-of-application-rollbacks, number-of-aborted-transactions, number-of-heuristics |
| IO Worker | `subsystem=io`, `worker=default` | queue-size |

### Queue Composite — Active Queue List

Collected from all three servers every cycle. List based on discovery session (queues with messages-added > 0 on any server):

| Queue Name | Business Function |
|---|---|
| `requestQueue` | General request dispatch |
| `jobBatchQueue` | Batch job execution |
| `fixedFeeEventQueue` | Internal event processing (high volume, correlates with user activity) |
| `documentOutputRequestQueue` | Document generation |
| `consumerAccountCBRPurgeQueue` | Account CBR purge |
| `consumerCacheRequestQueue` | Consumer cache requests |
| `bdlImportPostProcessorQueue` | BDL import post-processing |
| `bdlImportStagedDataQueue` | BDL import staging |
| `scheduleAndSettlementUpdateQueue` | Schedule/settlement updates |
| `paymentsImportPartitionQueue` | Payment imports |
| `paymentsPostingPartitionQueue` | Payment posting |
| `nbUploadQueue` | NB uploads |
| `nbReleaseQueue` | NB release processing |
| `nbPostReleaseQueue` | NB post-release processing |
| `brokenPaymentSchedulePartitionQueue` | Payment schedule fixes |
| `accountInterestAndBalanceUpdateQueue` | Account interest/balance updates |
| `scheduledRequestQueue` | Scheduled request dispatch |
| `fpRequestQueue` | FP request processing |

### Config Settings to Track in App_ConfigHistory

Checked every cycle, written only on change or first capture:

| Setting Name | API Path (after server) | Property |
|---|---|---|
| `worker_max_threads` | `subsystem=io`, `worker=default` | `task-max-threads` |
| `io_thread_count` | `subsystem=io`, `worker=default` | `io-threads` |
| `datasource_min_pool` | profile-level: `subsystem=datasources`, `data-source=dataSource` | `min-pool-size` |
| `datasource_max_pool` | profile-level: `subsystem=datasources`, `data-source=dataSource` | `max-pool-size` |
| `jvm_heap_max_mb` | `core-service=platform-mbean`, `type=memory` | `heap-memory-usage.max` (convert bytes to MB) |
| `transaction_timeout` | `subsystem=transactions` | `default-timeout` |
| `messaging_min_pool` | `subsystem=messaging-activemq`, `server=default`, `pooled-connection-factory=hornetq-ra` | `min-pool-size` |
| `messaging_max_pool` | `subsystem=messaging-activemq`, `server=default`, `pooled-connection-factory=hornetq-ra` | `max-pool-size` |
| `messaging_thread_pool` | `subsystem=messaging-activemq`, `server=default`, `pooled-connection-factory=hornetq-ra` | `thread-pool-max-size` |

**Note:** Some config values (datasource pool sizes, messaging factory settings) may need to be read from the profile level rather than the server instance level. The health composite reads runtime stats from the server instance; the config check may need a separate address path targeting `profile=full-ha` for configured values vs runtime values.

---

## Error Handling

- HTTP, CIM, and Management API are all independent try/catch blocks
- If Management API is unreachable, HTTP and CIM data still collected and inserted (API columns stay NULL)
- If a queue composite fails, the health snapshot still gets written
- If config check fails, health and queue data still gets written
- Partial snapshot on failure pattern carries forward from Phase 1
- Management API timeout controlled by `api_timeout_seconds` GlobalConfig setting (default 30s)

---

## GlobalConfig Addition Needed

| Module | Category | Setting | Value | Type | Description |
|---|---|---|---|---|---|
| DmOps | App | `api_timeout_seconds` | 30 | INT | Timeout in seconds for JBoss Management API REST calls |

---

## Tables Written

| Table | Rows Per Cycle | Content |
|---|---|---|
| `DmOps.App_Snapshot` | 3 (one per server) | All health metrics — HTTP, CIM, and Management API combined |
| `DmOps.App_QueueSnapshot` | ~54 (18 queues × 3 servers) | Per-queue JMS stats |
| `DmOps.App_ConfigHistory` | 0 (typically) or N (on change/first run) | Config change detection |

---

## Deployment Steps

1. Add `api_timeout_seconds` GlobalConfig entry
2. Deploy updated `Collect-DmHealthMetrics.ps1` to `E:\xFACts-PowerShell\`
3. Re-enable the ProcessRegistry entry
4. Verify data flowing into all three tables
5. Verify App_Snapshot API columns populating (not NULL)
6. Verify App_QueueSnapshot rows appearing (~54 per cycle)
7. Verify App_ConfigHistory baseline rows created on first cycle (~27 rows: 9 settings × 3 servers)

---

## Not In Scope (Future Phases)

- Alerting logic (threshold evaluation, Teams notifications)
- Control Center page expansion (displaying new metrics)
- Retention cleanup process
- Script Object_Metadata update (documentation)
- Dynamic active queue discovery (currently hardcoded list)

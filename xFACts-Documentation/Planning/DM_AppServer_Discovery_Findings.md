# DM Application Server Monitoring — Discovery Findings

**Date:** March 7, 2026  
**Session:** Initial discovery and capability testing  
**Participants:** Dirk, Claude

---

## Executive Summary

Comprehensive discovery testing of the three Debt Manager application servers (dm-prod-app, dm-prod-app2, dm-prod-app3) revealed extensive monitoring capabilities across multiple layers: HTTP health, OS-level process metrics, JBoss management API, JVM internals, JMS queues, database connection pools, and web server statistics. The JBoss management API — accessible from the domain controller on APP — provides a single point of access to all three servers' application-level metrics, making it the richest data source available.

Key finding: JMS queues operate independently per server (not clustered), confirming that workload segmentation between the three servers is effective but also means a server freeze isolates all work queued to that server.

---

## Environment Overview

| Server | Role | Services | Notes |
|---|---|---|---|
| dm-prod-app | Domain Controller + Jobs | DebtManager-Controller, DebtManager-Host | JBoss management console host. Designated for system processes and scheduled jobs. |
| dm-prod-app2 | Primary User Server | DebtManager-Host | Where all collectors/agents connect via SharePoint link. Server that periodically freezes. |
| dm-prod-app3 | ETL + Content Server | DebtManager-Host | Shared content (file uploads, rules engine). Designated for ETL and data loading. |

**JBoss Version:** JBoss EAP 7.1.5.GA (ActiveMQ Artemis 1.5.5 for messaging)  
**Java Version:** OpenJDK 1.8.0.222  
**JVM Configuration:** -Xms2048M -Xmx4096M (2-4 GB heap per server)  
**Actual JVM Heap (committed):** 8 GB (APP2)  
**Domain Mode:** Yes — APP is the domain controller managing all three hosts  
**Server Instance Naming:** {hostname}-inst1 (e.g., dm-prod-app2-inst1)  
**OS:** Windows Server 2016 Standard

---

## Monitoring Capabilities Confirmed

### Layer 1: HTTP Health Check (External — from FA-SQLDBB)

**Method:** `Invoke-WebRequest` to splash page  
**URL Pattern:** `http://{server}.fac.local/CRSServicesWeb/`  
**Response (healthy):** HTTP 200, 5713 bytes  
**Frequency:** Every 60 seconds recommended  
**Detection:** Timeout or non-200 response = server unresponsive

All three servers tested successfully. This is the primary freeze detection mechanism — direct, unambiguous, fast.

### Layer 2: OS-Level Process Metrics (CIM/WMI — from FA-SQLDBB)

**Method:** `Get-CimInstance` remote queries  
**Access:** Confirmed via FAC\sqlmon service account  

Available metrics:
- Server uptime (Win32_OperatingSystem.LastBootUpTime)
- Service state (Win32_Service — DebtManager-Controller, DebtManager-Host)
- Process tree: Service wrapper → cmd.exe → java.exe (3 tiers)
- JBoss JVM process metrics (the large grandchild java.exe):
  - Working Set memory (~9-10 GB per server)
  - Thread count (~870-1050 per server)
  - Handle count (~12,000+ per server)

**Process Tree Structure (per server):**
```
DebtManager-Host (wrapper, ~6 MB, ~7 threads)
  └── cmd.exe → START_DM_Host_Controller.bat
       └── java.exe (~60-145 MB, ~33 threads) — JBoss bootstrap
            ├── java.exe (~900-1150 MB, ~60 threads) — Management/messaging layer
            └── java.exe (~9-10 GB, ~870-1050 threads) — Main JBoss application server
```

APP additionally has DebtManager-Controller with a similar but smaller tree.

**Controller vs Host Process Investigation (March 7, 2026):** CIM process comparison on APP showed one large java.exe (9836 MB) and four smaller ones (1183, 1083, 82, 62 MB). The Controller does not have its own large java.exe — it's a lightweight management layer. No value in capturing Controller process metrics separately. DebtManager-Host is the only service monitored for CIM process metrics.

### Layer 3: JBoss Management API (from APP localhost, pending remote access)

**Method:** REST API via HTTP POST to `http://localhost:9990/management`  
**Authentication:** ManagementRealm (username/password)  
**Scope:** Domain-wide — single endpoint on APP queries all three servers  
**Access from FA-SQLDBB:** Blocked. host.xml bind address changed to 0.0.0.0 and JBoss restarted on March 7, 2026. Firewall rule between FA-SQLDBB and APP on port 9990 is pending — request sent to network team.

#### 3a: Server State
- Server state per host/instance (running, stopped, restart-required)
- Per-server runtime queries for all subsystems

#### 3b: JVM Memory (per server)
- Heap: used, committed, max (APP2: 3.5 GB used / 8 GB max at idle)
- Non-heap (metaspace/code cache): used, committed, max
- Objects pending finalization

#### 3c: JVM Threads (per server)
- Current thread count (APP2: 831)
- Peak thread count (APP2: 986)
- Total threads started since boot (APP2: 25,536)
- Daemon thread count
- Thread CPU time monitoring (enabled)
- Thread contention monitoring (available but disabled)

#### 3d: Datasources / Database Connection Pools

**7 datasource pools configured on each server:**

| Datasource | Database | Min Pool | Max Pool | Purpose |
|---|---|---|---|---|
| dataSource | crs5_oltp | 300 | 1000 | Main application pool |
| authenticatedb | crs5_oltp | 1 | 15 | Authentication |
| rulesDS | dm_rules | 1 | 40 | Rules engine |
| reportDS | crs5_oltp | 1 | 40 | Reports |
| archiveDataSource | dm_archive | 1 | 10 | Archive database |
| quartzDataSource | crs5_oltp | 1 | 10 | Quartz job scheduler |
| quartzManagedDataSource | crs5_oltp | 1 | 10 | Quartz managed |

All pools connect via `avg-prod-lsnr` (AG listener). The main `dataSource` pool prefills 300 connections per server at startup — 900 baseline connections to crs5_oltp across all three servers.

**Pool statistics available (when enabled):** ActiveCount, AvailableCount, InUseCount, IdleCount, WaitCount, MaxUsedCount, TimedOut, AverageGetTime, MaxWaitTime, AverageBlockingTime, CreatedCount, DestroyedCount, plus full XA transaction timing.

**Status:** Statistics were disabled by default. **Enabled at profile level during discovery session** — applies to all three servers, all datasources. No restart required. **Confirmed persistent through JBoss restart on March 7, 2026.**

#### 3e: Undertow (Web Server) Statistics

**Status:** **Enabled at profile level during discovery session. Confirmed persistent through restart.**

Available metrics (per HTTP listener):
- request-count (confirmed working — 54 requests on APP2 during testing)
- bytes-received, bytes-sent
- error-count
- processing-time
- max-processing-time

#### 3f: Transaction Statistics

**Status:** **Enabled at profile level during discovery session. Confirmed persistent through restart.**

Available metrics:
- number-of-committed-transactions
- number-of-inflight-transactions
- number-of-timed-out-transactions
- number-of-application-rollbacks
- number-of-resource-rollbacks
- number-of-aborted-transactions
- number-of-heuristics
- average-commit-time
- default-timeout (currently 900 seconds / 15 minutes)

#### 3g: JMS Queues (ActiveMQ Artemis)

**50+ JMS queues per server** with live runtime metrics available without statistics being enabled.

Per-queue metrics:
- message-count (pending messages — key health indicator)
- delivering-count (messages currently being delivered)
- consumer-count (active consumers — 0 = dead queue)
- messages-added (cumulative throughput since restart)
- scheduled-count (future-delivery messages)
- paused (true/false)

**Critical Discovery: Queues are independent per server, NOT clustered.**

Cluster configuration exists (`my-cluster` with multicast discovery) but topology shows `nodes=1 members=1` on APP2. Cross-server comparison confirmed independent operation:

| Queue: jobBatchQueue | APP | APP2 | APP3 |
|---|---|---|---|
| messages-added | 3,561 | 1,185 | 5,029 |
| message-count (pending) | 0 | 0 | 2,012 |
| delivering-count | 0 | 0 | 1,520 |
| consumers | 5 | 5 | 5 |

Implication: When APP2 freezes, all messages in its queues stop processing. Other servers cannot pick up the work.

**Busiest queues (APP2, messages-added since last restart):**

| Queue | Messages | Consumers | Business Function |
|---|---|---|---|
| fixedFeeEventQueue | 145,524 | 5 | Internal event processing (see note below) |
| consumerAccountCBRPurgeQueue | 1,570 | 5 | Account CBR purge |
| bdlImportPostProcessorQueue | 1,422 | 6 | BDL import post-processing |
| scheduleAndSettlementUpdateQueue | 1,246 | 4 | Schedule/settlement updates |
| jobBatchQueue | 1,185 | 5 | Job batch execution |
| requestQueue | 285 | 72 | General request dispatch |
| paymentsPostingPartitionQueue | 85 | 9 | Payment posting |

**fixedFeeEventQueue volume anomaly:** Despite the name suggesting fixed fee billing events (a low-volume business function), this queue has processed 145K messages on APP2 alone — more than double APP (60K) and six times APP3 (23K). All messages process successfully (zero pending, zero DLQ). The volume correlates strongly with user activity (APP2 has the most users). This is likely an internal application event mechanism that fires on high-frequency user actions (account interactions, balance checks, etc.) rather than literal fixed fee billing. The name may be misleading. No DLQ or ExpiryQueue messages were found across any server.

**Cross-server queue comparison (selected queues, messages-added/pending):**

| Queue | APP | APP2 | APP3 |
|---|---|---|---|
| requestQueue | 438/0 | 289/0 | 767/0 |
| jobBatchQueue | 3,566/0 | 1,185/0 | 5,029/1,885 |
| scheduledRequestQueue | 8/0 | 1/0 | 3/0 |
| nbReleaseQueue | 0/0 | 28/0 | 283/0 |
| nbPostReleaseQueue | 0/0 | 33/0 | 359/0 |
| paymentsPostingPartitionQueue | 14/0 | 85/0 | 139/1 |
| fixedFeeEventQueue | 60,863/0 | 145,524/0 | 23,199/0 |
| bdlImportPostProcessorQueue | 1,263/0 | 1,422/0 | 153/0 |

**Workload distribution observations:**
- Job flows (overnight scheduled) run primarily on APP and APP3, matching the Task Scheduler distribution strategy
- User-driven activity (fee events, cache requests) concentrates on APP2 where users connect
- Batch processing (NB release, payments) goes to whichever server initiates it
- The API call in each Task Scheduler script determines which server owns the entire flow — work does not migrate between servers
- When a server freezes, all messages in its queues stop processing. Other servers cannot pick up the work.

**Messaging configuration notes:**
- Thread pool max size: 30 (scheduled: 5)
- Message counter history: 10 days
- Max delivery attempts: 10 (then to DLQ)
- Dead letter queue: jms.queue.DLQ
- Expiry queue: jms.queue.ExpiryQueue
- Pooled connection factory (hornetq-ra): min 200, max 500 connections
- HA policy: shared-store-master

#### 3h: EJB Subsystem

**Bean instance pools configured:**
- slsb-strict-max-pool (stateless session beans)
- mdb-strict-max-pool (message-driven beans)

**Caching:** Clustered SFSB cache using Infinispan  
**Statistics:** Disabled by default. Can be enabled at profile level.

---

## Configuration Changes Made During Discovery Session

| Change | Scope | Method | Restart Required | Reversible | Persisted Through Restart |
|---|---|---|---|---|---|
| Datasource statistics enabled | Profile (full-ha) — all 7 datasources on all 3 servers | Management API write-attribute | No | Yes — set to false | **Yes — confirmed March 7, 2026** |
| Undertow statistics enabled | Profile (full-ha) — all 3 servers | Management API write-attribute | No | Yes — set to false | **Yes — confirmed** |
| Transaction statistics enabled | Profile (full-ha) — all 3 servers | Management API write-attribute | No | Yes — set to false | **Yes — confirmed** |
| EJB statistics enabled | Profile (full-ha) — all 3 servers | Management API write-attribute | No | Yes — set to false | **Yes — confirmed** |
| Messaging statistics enabled | Profile (full-ha) — all 3 servers | Management API write-attribute | No | Yes — set to false | **Yes — confirmed** |

**Statistics persistence:** All statistics settings survived the JBoss service restart on March 7, 2026. No periodic re-enable check is needed in the collector script.

## Configuration Changes Applied During Build Session (March 7, 2026)

| Change | Scope | Method | Restart Required | Status |
|---|---|---|---|---|
| Management bind address: 127.0.0.1 → 0.0.0.0 | APP only (host.xml line 71) | Manual XML edit with inline comment | Yes (JBoss restart) | **Applied and restarted.** Remote access blocked by firewall — pending network team (Shawn). |

---

## Notable Configuration Findings

### EJB Pool Sizing (Potential Bottleneck)

Both EJB bean instance pools are configured at default values:

| Pool | Max Size | Timeout | Purpose |
|---|---|---|---|
| slsb-strict-max-pool | 20 | 5 minutes | Stateless session beans — handles all user requests |
| mdb-strict-max-pool | 20 | 5 minutes | Message-driven beans — JMS queue consumers |

**Concern:** 20 max instances for stateless session beans is the JBoss default, intended for lightweight or development use. With 100+ concurrent users on APP2, this pool may regularly saturate during peak hours. When all 20 instances are in use, new requests wait (up to 5 minutes) before getting an instance — during which users experience the app "freezing" or "hanging."

**Context:** The database connection pool (dataSource) is configured for min 300 / max 1000 connections, suggesting someone recognized the need for high database concurrency. But the EJB pool at 20 creates a funnel — 1000 available database connections behind a gate that only allows 20 requests through at a time.

**Next step:** EJB statistics are now enabled. Monitor pool utilization — peak in-use count, wait counts, and whether the pool is a bottleneck. If confirmed, increasing `max-pool-size` (to 100-200) via the management API is a straightforward change. The right number depends on observed peak demand and downstream capacity (database connections, JVM memory, thread count).

### Connection Pool Configuration

The main `dataSource` pool prefills 300 connections per server at startup (pool-prefill: true). With 3 servers, that's 900 baseline connections to crs5_oltp from JBoss alone, before any user activity. The max of 1000 per server allows up to 3000 total. This is worth monitoring against what the database actually sees in Server Health connection counts.

---

## Architecture Decision: Data Collection Approach

**Decided:** Direct collection from FA-SQLDBB via the JBoss management API on APP (port 9990), once firewall access is granted. Two-script architecture with separate orchestrator schedules.

**Why this works:**
- APP is the domain controller — one API endpoint provides access to all three servers
- Same architecture as every other xFACts collector (single script on FA-SQLDBB, writes to xFACts via AG listener)
- No proxy scripts, no middleware, no additional infrastructure
- JBoss management API credentials stored in dbo.Credentials (service: JBossManagement) using the existing two-tier encryption pattern

**Credential storage:**
- Service: `JBossManagement`
- ConfigKeys: `JBossUser`, `JBossPassword`
- Encrypted with the standard two-tier passphrase model
- Retrieved at runtime via `Get-ServiceCredentials -ServiceName 'JBossManagement'`
- **Implemented March 7, 2026**

---

## What Has Been Built

### Discovery Session (Session 1)

DM App Server Toggle on the Admin page:

- Platform Management card with modal for switching the SharePoint Debt Manager navigation link between APP/APP2/APP3
- Palo Alto firewall rule integration (enable/disable APP/APP3 access)
- SharePoint REST API navigation node update
- Two-tier encrypted credentials for SharePoint and PaloAlto services
- Get-ServiceCredentials function in xFACts-Helpers.psm1
- server.psd1 Pode request timeout configuration
- Development Guidelines Section 2.6 rewrite (versioning workflow)

### DmOps Module Build (Session 2 — March 7, 2026)

**Phase 1 — Foundation and Health Metrics Collection:**

Database:
- `DmOps` schema created
- Module_Registry, Component_Registry (DmOps.AppServer), System_Metadata baseline (1.0.0)
- `DmOps.App_Snapshot` table — append-only health metrics per server per cycle (HTTP responsiveness, CIM service state, JBoss process metrics, server uptime)
- ServerRegistry: added `dmops_enabled`, `is_domain_controller` columns, `APP_SERVER` server_type, three DM app server rows
- GlobalConfig: 4 entries (http_base_path, http_timeout_seconds, alerting_enabled, snapshot_retention_days) under module DmOps, category App
- JBossManagement credentials in dbo.Credentials (JBossUser, JBossPassword)
- Object_Registry entries for all objects
- Object_Metadata baselines and enrichment (table + script: data_flow, design_notes, relationship_notes)

PowerShell:
- `Collect-DmHealthMetrics.ps1` — collects HTTP responsiveness (Invoke-WebRequest), CIM service state (Win32_Service for DebtManager-Host), JBoss process metrics (Win32_Process, largest java.exe by working set), and server uptime (Win32_OperatingSystem). One row per server per cycle to App_Snapshot. FIRE_AND_FORGET orchestrator integration.
- Registered in ProcessRegistry, running on 60-second interval, collecting successfully.

Control Center:
- `DmMonitoring.ps1` (route), `DmMonitoring-API.ps1` (API), `dm-monitoring.css`, `dm-monitoring.js`
- Page at `/dm-monitoring` — three-column server card layout showing live metrics from all three servers
- Engine indicator card ("HEALTH") connected to orchestrator via WebSocket
- API endpoint `GET /api/dm-monitoring/status` returns latest App_Snapshot per server
- GlobalConfig refresh interval (`refresh_dm_monitoring_seconds`)

Documentation:
- `dmops-ref.html` reference page rendering from DmOps.json via ddl-loader.js

**Baseline data observations (first collection):**
- All three servers responding: HTTP 200, 5713 bytes, 11-19ms response times
- All DebtManager-Host services Running/Auto
- JBoss process metrics: 9836-10057 MB memory, 874-913 threads, 12328-12629 handles
- APP and APP3 uptime ~502 hours (21 days), APP2 uptime ~258 hours (11 days — consistent with more frequent restarts due to freezes)

---

## Proposed Monitoring Scope

### Tier 1: Collect Every Cycle — IMPLEMENTED

| Metric | Source | Purpose | Status |
|---|---|---|---|
| HTTP responsiveness (all 3 servers) | Direct HTTP GET | Primary freeze detection | **Collecting** |
| HTTP response time | Same call | Early warning / performance trending | **Collecting** |
| DebtManager service state | CIM Win32_Service | Service up/down detection | **Collecting** |
| JBoss process metrics (memory, threads, handles) | CIM Win32_Process | OS-level trending | **Collecting** |
| Server uptime | CIM Win32_OperatingSystem | Reboot detection | **Collecting** |

### Tier 2: Collect Every Cycle (via Management API) — PENDING FIREWALL

| Metric | Source | Purpose |
|---|---|---|
| Server state | Management API | running/stopped/restart-required per server |
| JVM heap used/max | Management API | Memory pressure detection |
| JVM thread count | Management API | Thread exhaustion detection |
| JMS queue message-count (pending) | Management API | Queue backlog detection |
| JMS queue consumer-count | Management API | Dead consumer detection |
| Datasource InUseCount/ActiveCount | Management API | Connection pool saturation |
| Datasource WaitCount | Management API | Connection pool contention |

### Tier 3: Collect Less Frequently (via Management API) — PENDING FIREWALL

| Metric | Source | Purpose |
|---|---|---|
| Full JMS queue stats (all queues) | Management API | Queue throughput trending |
| Undertow request-count, error-count | Management API | Web server throughput/errors |
| Transaction counts (commit, rollback, timeout) | Management API | Transaction health |
| Datasource full pool stats | Management API | Connection pool trending |

### Alert Conditions (candidates — not yet implemented)

| Condition | Severity | Action |
|---|---|---|
| HTTP responsiveness fails consecutive times | Critical | Teams alert |
| JMS queue message-count > threshold | Warning | Teams alert |
| JMS queue consumer-count = 0 | Warning | Teams alert |
| Datasource WaitCount > 0 sustained | Warning | Teams alert |
| JVM heap > 90% of max | Warning | Teams alert |
| JVM thread count exceeds peak baseline | Warning | Teams alert |
| Transaction timeout count increasing | Warning | Teams alert |
| Undertow error-count spike | Warning | Teams alert |

**Note:** Auto-remediation (restart JBoss + toggle SharePoint) has been removed from scope. The DM App Server Toggle on the Admin page is the manual intervention mechanism. May be revisited in the future.

---

## Open Items

| Item | Status | Notes |
|---|---|---|
| Firewall rule: FA-SQLDBB → dm-prod-app port 9990 | **Pending — request sent to Shawn** | Required for Management API access from FA-SQLDBB. host.xml bind address already changed to 0.0.0.0. |
| Phase 2: Management API metrics tables | Pending firewall | Table design for JVM, datasource, JMS, transaction, undertow, EJB metrics. Collect-DmMetrics.ps1 script. |
| Phase 2: Control Center page expansion | Pending firewall | Add Management API metrics sections to DM Monitoring page. |
| EJB statistics enable | **Done** | Enabled at profile level during discovery session. Confirmed persistent through restart. |
| Messaging statistics enable | **Done** | Enabled at profile level during discovery session. Confirmed persistent through restart. |
| Statistics persistence verification | **Done** | All statistics settings confirmed persistent through JBoss restart on March 7, 2026. |
| Module/schema naming decision | **Done** | Schema: DmOps. Module: DmOps. Component: DmOps.AppServer. Table prefix: App_. |
| JBoss Management credentials | **Done** | JBossManagement service in dbo.Credentials with JBossUser and JBossPassword ConfigKeys. |
| host.xml bind address change | **Done — blocked by firewall** | Changed 127.0.0.1 → 0.0.0.0 on APP (host.xml line 71). JBoss restarted. Remote access blocked by firewall rule. |
| App_Snapshot common queries enrichment | Deferred | Evaluate once collection has been running and operational patterns emerge. |
| DM App Server Toggle migration | Deferred | Move from Admin page Platform Management to DM Monitoring page. Admin-level function with Power User grant. |
| JMS cluster state investigation | Open | Queues confirmed operating independently per server. Determine if this is intentional design or a configuration gap. |
| fixedFeeEventQueue volume investigation | Open | 145K messages on APP2 — likely an internal event mechanism with a misleading name. |
| Connection pool sizing review | Open | 300 min / 1000 max × 3 servers = 900-3000 connections to crs5_oltp from JBoss. |
| Job flow API launch behavior | Clarified | Task Scheduler scripts fire REST API calls to specific servers. Work stays on the initiating server. |
